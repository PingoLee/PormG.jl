## `db_default` — a literal value is refused; declare it as `default` (#1033)

- **Version**: Unreleased
- **PormG ref**: #1033 ; `src/models/fields.jl` (`_refuse_literal_db_default`), `src/column_ir.jl` (`_db_default_read_back`)
- **Recorded**: 2026-10-08
- **Severity**: breaking. A `db_default` whose text is a constant raises `FieldValidationError` when the field is built, where it used to be accepted.

### What changed

A `db_default` pinned to an engine was checked only for being well-formed, so a constant was
accepted: `(postgres = "0",)`, `(postgres = "'open'",)`, `(postgres = "'10.0.0.1'::inet",)`,
`(sqlite = "1",)`. The database stores a constant as a value, and the schema reader reads it back as
one. The declaration compiled to an expression and the live column to a literal, and the migration
diff keeps those apart on purpose (#475). So such a column never matched its own declaration:

- every `makemigrations` planned the same `ALTER COLUMN … SET DEFAULT` on PostgreSQL, and a full
  table rebuild on SQLite;
- `migrate()` never reported "nothing pending";
- `Migrations.check` reported the column on every run.

The field constructor now refuses such a text. It asks the schema reader's own cleaner what the
catalog would read back, so the refusal covers exactly what used to churn: a number, `true`/`false`,
`NULL`, a quoted string with or without a cast or parentheses, a SQLite `X'…'` blob or `1`/`0` on a
`BooleanField`, and on PostgreSQL `CAST(<constant> AS <type>)`, a typed literal (`DATE '…'`,
`INTERVAL '1' DAY`) and a signed number (`- 1`), which its catalog stores as constants too. An expression (`now()`, `0 + 0`, `ARRAY[]::integer[]`) is
unchanged.

One catalog spelling is now read as the constant it is. PostgreSQL stores `DEFAULT -1::integer` as
the operator `(- 1)`, and `inspectdb` used to write it as `db_default = (postgres = "- 1",)`. It now
writes `default = -1`, which converges. Regenerate a models file that carries such a line, or
replace the line by hand; loading the old line raises the refusal above. `inspectdb` never wrote
any other constant as a `db_default`.

### Who this affects

Models that declare a constant as a `db_default`. Measured on 2026-10-08: **0** `db_default` call
sites in the consuming apps' Julia code.

### How to find the calls to migrate

```bash
grep -rnP -A2 'db_default\s*=' --include=*.jl . | grep -P '\b(postgres|sqlite)\s*=\s*"\(?\s*(['\''0-9+.-]|true|false|NULL|CAST\s*\(|[A-Za-z_."]+(\s*\(\d+\))?\s+'\'')'
```

The `-A2` follows a `db_default = (` that continues on the next lines. It also lists expressions
that merely start with a constant (`0 + 0`, `'a' || b`), which are unaffected. Loading the
models is the definitive check: the refusal names the field type, the engine and the text, suggests
the `default = …` to write instead, and cites #1033.

### Migrate your app

Write the constant as `default`. It renders the same `DEFAULT` clause, and it reads back unchanged:

```julia
# ✗ before — accepted, then replanned by every makemigrations
laps     = Models.IntegerField(db_default = (postgres = "0",))
status   = Models.CharField(db_default = (postgres = "'Finished'", sqlite = "'Finished'"))
race_day = Models.DateField(db_default = (postgres = "DATE '2024-03-02'",))

# ✓ after
laps     = Models.IntegerField(default = 0)
status   = Models.CharField(default = "Finished")
race_day = Models.DateField(default = "2024-03-02")
```

For `NULL`, remove the `db_default` (or pass `postgres = nothing`). A `SearchVectorField` takes no
`default` at all, so its column cannot carry a constant database default: give it an expression, or
no default.
