## `makemigrations` — refuses a `DecimalField` wider than 15 digits on SQLite (#648)

- **Version**: Unreleased
- **Recorded**: 2026-09-25
- **PormG ref**: #648; `src/Dialect.jl` (`_refuse_inexact_sqlite_decimal`, `field_to_column(::PormGSQLite)`, `SQLITE_EXACT_DECIMAL_DIGITS`)
- **Severity**: breaking — SQLite only; a models file that used to plan now raises `BackendCapabilityError`

### What changed

SQLite has no exact decimal type. A `DECIMAL(p, s)` column gets `NUMERIC` affinity, which stores each
value as an `Int64` or a `Float64` as it is written, and a `Float64` keeps only fifteen significant
digits exactly. PormG used to create a `DecimalField(max_digits = 20, …)` column on SQLite anyway, and
SQLite then rounded or truncated wide values with no error: `1.000000000000000000001` stored as the
integer `1`.

`makemigrations` now raises `BackendCapabilityError` when it would **create or re-create** a SQLite
column for a `DecimalField` with `max_digits > 15`, and writes no pending plan. That covers:

- a new model;
- a new field;
- **any** SQLite table rebuild. A rebuild re-creates every column, so a change to *another* column of a
  table that still declares a wide decimal is refused too.

An existing wide column that nothing rebuilds is left alone. It keeps SQLite's lossy conversion, and
reads back as before. PostgreSQL is unchanged at any width: its `numeric` is exact.

A `pending_migrations.jl` written **before** upgrading is not re-checked, because `migrate` applies the
stored SQL without re-rendering it. Re-run `makemigrations` before applying one.

### How to find the calls to migrate

Run `makemigrations` against each SQLite database. The refusal names the column, and its message
contains `SQLite has no exact decimal type`. To find the declarations ahead of time, look for
`max_digits` of 16 or more in models that run on an `adapter: sqlite` connection:

```bash
grep -rnE 'max_digits *= *"?(1[6-9]|[2-9][0-9]|[1-9][0-9]{2,})\b' --include=*.jl .
grep -rnE 'DecimalField\( *(1[6-9]|[2-9][0-9]|[1-9][0-9]{2,}) *,' --include=*.jl .
```

The first finds the keyword spelling, including a declaration split over several lines. The second
finds the positional one.

### Migrate your app

```julia
# ✗ before — SQLite created DECIMAL(20, 2) and rounded values past 15 digits as they were written
Invoice = Models.Model(
    id     = Models.IDField(),
    amount = Models.DecimalField(max_digits = 20, decimal_places = 2),
)

# ✓ after — at most 15 digits on SQLite. If the table already exists, the narrowing is itself a
#   table rebuild, so apply it with destructive = true.
Invoice = Models.Model(
    id     = Models.IDField(),
    amount = Models.DecimalField(max_digits = 15, decimal_places = 2),
)
# PormG.Migrations.makemigrations("db"); PormG.Migrations.migrate("db", destructive = true)
```

If the values genuinely need more than fifteen digits, move that database to PostgreSQL. SQLite cannot
store them.
