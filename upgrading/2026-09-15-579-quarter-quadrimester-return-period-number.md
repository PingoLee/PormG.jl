## `@quarter` / `@quadrimester` return the period number; the label moves to `@yyyy_q` / `@yyyy_quad` (#579)

- **Version**: 0.6.0
- **PormG ref**: #579 ; `src/constants.jl`, `src/querybuilder/functions.jl`, `src/Models.jl`
- **Recorded**: 2026-09-15
- **Severity**: breaking — a `values()` projection of `__@quarter` changes type, and a previously
  accepted filter value is now rejected.

### What changed

`@quarter` rendered `CONCAT(year, '-Q', CASE …)`, so it denoted the **string** `"1985-Q1"`. Every
documentation table said "Extract quarter (1-4)" and showed `"date__@quarter" => 1` as the filter
spelling, and that filter could never match: it compared a string expression to an integer. It
returned zero rows, silently, with no value able to make it match — and a wrong-typed value such as
`=> "abc"` was bound without complaint. `@quadrimester` had the same shape.

The two meanings are now two names, which is what Django does (`ExtractQuarter` is registered as the
`__quarter` lookup and returns an `IntegerField`; `TruncQuarter` is deliberately *not* registered as a
transform) and what SQL itself does (`EXTRACT(QUARTER FROM x)` versus `date_trunc('quarter', x)`):

- `@quarter` → the quarter **number**, `1`–`4`. `@quadrimester` → `1`–`3`.
- `@yyyy_q` / `@yyyy_quad` → the year-qualified **label**, `"1985-Q1"`, rendered by the same
  `Concat`/`Case` expansion as before, byte for byte.

Both number transforms now validate their comparison value: a non-number, or a number outside the
period's range, raises `InvalidValueError` instead of building SQL that matches nothing.

### How to find the calls to migrate

```bash
grep -rn '__@quarter\|__@quadrimester' --include='*.jl' .
```

Every hit is either a **projection** — `values("q" => "date__@quarter")`, which used to yield
`"1985-Q1"` and now yields `1` — or a **filter**, which used to match nothing and now works. Reading
the surrounding code tells you which shape was intended: a grouping key or a label in a report wants
`@yyyy_q`; "rows in Q1" wants `@quarter` and was broken before.

### Migrate your app

```julia
# ✗ before — the projection was a label, and the documented filter matched nothing
query.values("driverid", "q" => "dob__@quarter")     # "1985-Q1"
M.Driver.objects.filter("dob__@quarter" => 1)        # always empty

# ✓ after — pick the shape you meant
query.values("driverid", "q" => "dob__@yyyy_q")      # "1985-Q1"  (the label, unchanged)
query.values("driverid", "q" => "dob__@quarter")     # 1          (the number)
M.Driver.objects.filter("dob__@quarter" => 1)        # Q1 of every year — now selects rows
```

Note that `@yyyy_quad` renders `"1985-Q1"` as well: it shares the `-Q` separator with `@yyyy_q`, so
the two labels cannot be told apart from the value alone. That predates this change, which moved the
expansion without altering it.
