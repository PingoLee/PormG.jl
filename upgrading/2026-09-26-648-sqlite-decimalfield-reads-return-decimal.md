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

A `DecimalField` declared with at most 15 digits now reads back on SQLite as the `Decimals.Decimal`
that was written. That covers every column PormG creates there: the companion entry makes it refuse a
wider one. It applies whenever the column itself is projected: a field path, a bare `F("price")`, or
the model's `*`. That holds through `list()`, `list(:dict)`, `list(:json)`, `DataFrame(query)`,
`get()` / `first()` and `get_or_create`. `list(:json)` now emits PostgreSQL's text.

The rebuild is exact: SQLite keeps 15 significant digits, so the stored number identifies the written
decimal. Nothing is rounded to fit. A cell that does not fit the declaration comes back unchanged.

These keep the old types on SQLite:

- an **expression** over the column: an aggregate, arithmetic or SQL function (`Sum("price")`,
  `F("price") * 2`), a `Joined(...)` / `CTE(...)` reference, a subquery. These arrive as the number
  SQLite holds or computed.
- a row returned by **`create()`** or **`update_or_create`**, which skips the read parsers as it does
  for temporal columns.
- a value that does **not fit the declaration**, such as the unrounded double an `F`-arithmetic
  `update(...)` leaves on SQLite. PostgreSQL rounds it to the column's scale, so on SQLite such a
  column can mix `Decimal` and `Float64` rows.
- a field declared **wider than 15 digits**, whose cells SQLite may already have rounded.

PostgreSQL is unchanged.

### How to find the calls to migrate

Look for SQLite read sites that assume the old types on a decimal column:

```bash
grep -rnE 'isa (Float64|Int64|Int|Integer)\b|::(Float64|Int64)\b' --include=*.jl .
grep -rnE 'JSON\.json\(.*list\(:dict\)' --include=*.jl .
grep -rnE '\b(unique|groupby|innerjoin|leftjoin|Set)\(' --include=*.jl .   # hashing, on 0.4.1
```

Keep the hits that read a `DecimalField` (`grep -rn 'DecimalField' --include=*.jl .` lists them), and
check any stored JSON snapshots for exponent-form decimals such as `1.23456789e6`. An `isa
AbstractFloat` check needs no change: `Decimal <: AbstractFloat`.

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

Code that used to receive a `Float64` meets `Decimals.Decimal`'s own limits. PostgreSQL code already
lives with these, and which ones apply depends on the Decimals version your environment resolves: an
app that also carries LibPQ gets 0.4.1, a SQLite-only one gets 0.5.x.

- **Hashing, on 0.4.1.** `hash` has no `Decimal` method there, so `unique`, `Set`, `Dict` keys, and
  DataFrames `groupby` / `innerjoin` on the column throw `MethodError`. Convert first, or key on the
  text: `Float64.(df.price)`, or `passmissing(Float64).(df.price)` (from Missings.jl) for a nullable
  column, since `Float64(missing)` throws.
- **Comparing with a `Float64` literal.**
  - On 0.5, the comparison uses the literal's exact binary value, so `row[:price] == 99.99` is `false`.
  - On 0.4.1, a fractional literal of a million or more (`== 1234567.89`, or arithmetic with it)
    throws `ArgumentError`.
  - Compare against a `Decimal` instead.
- **JSON.** Use `list(:json)`. Handing `list(:dict)` to `JSON.json` renders a whole `Decimal` as
  `14.0`.
