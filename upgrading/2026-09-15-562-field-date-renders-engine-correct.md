## `field__@date` renders one engine-correct expression on both spellings (#562)

- **Version**: 0.6.0
- **PormG ref**: #562 ; `src/Dialect.jl`, `src/querybuilder/functions.jl`, `src/querybuilder/build_helpers.jl`
- **Recorded**: 2026-09-15
- **Severity**: behavior change — the SQL and the returned type of `__@date` change on both engines.

### What changed

`PormGtransform` was resolved by two independent ladders. The string spelling
(`values("created_at__@date")`, `filter("created_at__@date" => …)`) resolved the transform name into
`QueryBuilder`'s own constructors; the `F(...)` and update-expression spelling resolved the *same*
table entry into `Dialect` and string-concatenated the result. They emitted different SQL for the
same transform on the same column, and for `@date` one of them was wrong:

- **SQLite** — the `F` spelling rendered `CAST(col AS DATE)`. `DATE` is a declared type name carrying
  none of SQLite's affinity keywords, so NUMERIC affinity turned `'2026-04-07T21:30:23.741+00:00'`
  into the integer `2026`. Projected, `F("created_at__@date")` returned the **year**; compared, it
  matched nothing. Silent in both directions.
- **PostgreSQL** — the `F` spelling rendered `(col)::date` (a `date`), the string spelling
  `to_char(col, 'YYYY-MM-DD')` (text). Same value, two types, depending on which spelling you used.

There is one ladder now, and `@date` is a named function the dialect renders per engine:
`(col)::date` on PostgreSQL, `strftime('%Y-%m-%d', col)` on SQLite. Both spellings agree everywhere.

The other four transforms in use (`@year`, `@month`, `@day`, `@yyyy_mm`) already agreed through
either ladder and render exactly as before.

### How to find the calls to migrate

```bash
grep -rn '__@date' --include='*.jl' .
```

Only **PostgreSQL** callers of the *string* spelling need a change: that projection used to return
`String` and now returns `Dates.Date`. SQLite callers of the string spelling are unaffected. Callers
of the `F` spelling were reading a wrong value on SQLite and an inconsistent type on PostgreSQL;
they need no edit, but their results change.

### Migrate your app

```julia
# ✗ before — on PostgreSQL this projection was text, so code parsed or compared it as a string
row = M.Race.objects.values("d" => "date__@date").list()[1]
row[:d] == "1991-03-10"          # String on PostgreSQL, String on SQLite

# ✓ after — PostgreSQL delivers a Date; compare against a Date, or stringify at the edge
row = M.Race.objects.values("d" => "date__@date").list()[1]
row[:d] == Dates.Date(1991, 3, 10)      # PostgreSQL
string(row[:d]) == "1991-03-10"         # works on both engines
```

An unknown transform suffix reached through `F("col__@nope")` now raises `FilterError` — the same
type the string spelling has always raised, listing the valid functions and operators — where it
used to raise a bare `QueryBuildError`. Code catching the specific subtype needs the wider
`PormGError` or the new type.
