## `list` / `DataFrame` — SQLite reads a `DecimalField` back as a `Decimals.Decimal`, like PostgreSQL (#648)

- **Version**: Unreleased
- **Recorded**: 2026-09-26
- **PormG ref**: #648; `src/value_repr.jl` (`field_canonical_kind`, `value_parser(::CDecimal, ::PormGSQLite)`), `src/Dialect.jl` (`_parse_sqlite_decimal`)
- **Severity**: behavior change — SQLite only; a column's Julia type changes

### What changed

SQLite stores a `DecimalField` value as an `Int64` (a whole value) or a `Float64` (a fractional one),
and PormG used to hand back exactly that. One declared column could therefore read as two Julia types,
neither of them PostgreSQL's `Decimals.Decimal`. And from a million up, `list(:json)` rendered the
`Float64` in exponent form: `{"price":1.23456789e6}` where PostgreSQL emits `{"price":1234567.89}`.

A `DecimalField` of at most 15 digits now reads back on SQLite as the `Decimals.Decimal` that was
written. That covers every column PormG creates there: the companion entry makes it refuse a wider
one. It applies to `list()`, `list(:dict)`, `list(:json)`, `DataFrame(query)`, `get()` / `first()`,
and the `values("*")` wildcard, and `list(:json)` now emits PostgreSQL's text.

The rebuild is exact: SQLite keeps 15 significant digits, so the stored number identifies the written
decimal. Nothing is rounded to fit. A cell that does not fit the declaration comes back unchanged.

Three values keep the old types on SQLite:

- an **aggregate or arithmetic** result over the column (`Sum("price")`, `F("price") * 2`), which
  SQLite computes through a double;
- a row returned by **`create()`**, `get_or_create` or `update_or_create`, which skips the read parsers
  as it does for temporal columns;
- a column **wider than 15 digits** that PormG did not create, whose cells SQLite may already have
  rounded.

PostgreSQL is unchanged.

### How to find the calls to migrate

Look for SQLite read sites that assume the old types on a decimal column:

```bash
grep -rnE 'isa (Float64|Int64|Int|Integer|AbstractFloat)\b|::(Float64|Int64)\b' --include=*.jl .
grep -rnE 'JSON\.json\(.*list\(:dict\)' --include=*.jl .
```

Keep the hits that read a `DecimalField` (`grep -rn 'DecimalField' --include=*.jl .` lists them), and
check any stored JSON snapshots for exponent-form decimals such as `1.23456789e6`.

### Migrate your app

```julia
row = M.Constructor_results.objects.filter("constructorresultsid" => 1).values("points").list() |> first

# ✗ before — on SQLite `points` was an Int64 or a Float64, depending on the value
row[:points] isa Float64 && round(row[:points]; digits = 2)
row[:points] == 99.99                         # a Float64 comparison

# ✓ after — a Decimals.Decimal on both engines
Float64(row[:points])                         # when a float is really what you need
row[:points] == parse(Decimals.Decimal, "99.99")
```

Comparing a `Decimal` to a `Float64` literal is fragile on both engines. On Decimals 0.5 it compares
the literal's exact binary value, so `99.99` never matches. Compare against a `Decimal` instead. For
JSON, use `list(:json)`. Handing `list(:dict)` to `JSON.json` renders a whole `Decimal` as `14.0`.
