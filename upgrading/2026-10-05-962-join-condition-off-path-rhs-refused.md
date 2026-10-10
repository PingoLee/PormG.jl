## `on()` / `cjoin(filters = …)` — a right side naming a relation off the join path raises (#962)

- **Version**: Unreleased
- **PormG ref**: #962 ; `src/querybuilder/ctes.jl` (`_refuse_off_path_join_rhs!`)
- **Recorded**: 2026-10-05
- **Severity**: breaking (narrow). A join condition whose right side named another relation used to render, attached to whichever join came later in `FROM`. It now raises `FilterError` when the query is built, on both engines.

### What changed

A condition in `on(path, …)` or `cjoin(filters = …)` compares the joined row with the base row, or
with a table earlier on the same path. A right-side `F` that reaches any **other** relation was
accepted, and the predicate was then attached to whichever join the renderer emitted later. Which
join that was depended on the order of `values()`:

| query | before | after |
|---|---|---|
| `on("constructorid", "nationality" => F("driverid__nationality"))`, `values()` builds the constructor first | the predicate sits in the driver's `INNER JOIN`, so a mismatch drops the whole row | raises `FilterError` |
| the same, `values()` builds the driver first | the predicate sits in the constructor's `LEFT JOIN`, so a mismatch nulls the constructor columns | raises `FilterError` |

Every spelling behaves the same way: a bare pair, `Q(...)`, `Qor(...)`, `OP(...)`, `F(...) == F(...)`,
a column inside a function or a `Case` branch on the right, the `OuterRef` of a `Subquery(...)`, and
the right side of a comparison nested in the left side (a `When` condition). These right sides still render exactly as before:
- the base row (`F("number")`)
- the joined row through its own path (`F("driverid__number")` on `on("driverid", …)`)
- a table earlier on a deep hop (`F("driverid__number")` on `on("driverid__results", …)`)
- a JSON key path on the base row
- a plain string value, which is a bound literal

`cjoin_on(...)` is not affected.

### Who this affects

Apps with a join condition that compares two sibling relations.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
a relation outside the join path
```

To find the candidates by hand, list the join conditions with a path-qualified `F` or `OuterRef` on
the right. The pattern matches `q.on(` as well as an `on(` that a trailing-dot chain starts on its
own line. A condition split across lines still escapes it, so the test run above is the complete
check:

```bash
grep -rnE '(^|[.[:space:]])(on|cjoin)\(.*(F|OuterRef)\("[A-Za-z0-9_]+__' --include='*.jl' <your-app>/src
```

### Migrate your app

Compare the two relations in `.filter(...)`. That is a `WHERE` predicate, so it keeps only the rows
where both sides match. For a `LEFT JOIN` this is the strict reading; the old placement could only
ever give that reading in one `values()` order.

```julia
# ✗ before: which join's ON clause holds the predicate depends on values() order
M.Result.objects.
    on("constructorid", "nationality" => F("driverid__nationality")).
    values("resultid", "constructorid__name")

# ✓ after: results where the constructor and the driver share a nationality
M.Result.objects.
    filter(F("constructorid__nationality") == F("driverid__nationality")).
    values("resultid", "constructorid__name")
```
