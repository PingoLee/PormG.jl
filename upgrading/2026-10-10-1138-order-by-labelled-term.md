## `order_by(SQLOrder(SQLField(x, label)))` orders by `x`, even when `label` names a projection (#1138)

- **Version**: Unreleased
- **PormG ref**: #1138 ; `src/querybuilder/build_select.jl` (`_is_labelled_term`, `get_order_query`), `src/querybuilder/execution_read.jl` (`_degenerate_aggregate`)
- **Recorded**: 2026-10-10
- **Severity**: behavior change. An `SQLOrder(SQLField(x, label))` term whose `label` differs from `x`, such as an expression term or a path written under another name, now sorts by `x` where it used to sort by the `values()` projection named `label`. A term that reads a column outside its aggregate now raises the #798 `QueryBuildError` where it used to build. Under `distinct()` on PostgreSQL, a term that repeats a projected expression which binds a value raises the #76 `QueryBuildError` where it used to build.

### What changed

An expression reaches `order_by` as `SQLOrder(SQLField(expr, label))`. ORDER BY never prints the
label, but PormG used to compare it with the `values()` output names. When the two matched, the term
sorted by that projection and its own expression never reached the statement:

| term, beside `values("constructorid", "best" => Max("points"))` | before | after |
|---|---|---|
| `SQLField(F("constructorid") + Max("points"), "best")` | `ORDER BY "best"` | `ORDER BY ("Tb"."constructorid" + MAX("Tb"."points"))` |
| `SQLField(Count("resultid"), "best")` | `ORDER BY "best"` (by best score) | `ORDER BY COUNT("Tb"."resultid")` |
| `SQLField(Max("points"), "best")` | `ORDER BY "best"` | `ORDER BY MAX("Tb"."points")`: same rows |
| `SQLField("grid", "best")` | `ORDER BY "best"` | `ORDER BY "Tb"."grid"`, and `grid` joins `GROUP BY` as with `order_by("grid")` |
| `SQLField(F("grid") + Max("points"), "best")` | `ORDER BY "best"` | `QueryBuildError`: the #798 guard, because `grid` is not grouped |

A term that repeats a projected expression which binds a value, such as `F("points") * 2` beside
`"x" => F("points") * 2`, binds it a second time. Under `distinct()`, PostgreSQL numbers the second
value `$2` against the projection's `$1`, so the term is not in the DISTINCT list and the query raises
`QueryBuildError`. PostgreSQL itself rejects that statement. SQLite runs it. `order_by("x")` builds on
both engines.

A path projection under a chosen name matched the same way. Beside `values("best" => "points")` or
`values("y" => "grid")`, a term labelled `"best"` or `"grid"` sorted by `points` or `grid`. A labelled
term was also cached under its label, so a later string term of that name sorted by the labelled
term instead. In `order_by(SQLOrder(SQLField(F("points") * 2, "grid")), "grid")`, the second term
now sorts by the `grid` column.

Unchanged: string terms, which are `order_by("best")`, `order_by("-best")` and `SQLOrder("best")`;
`SQLField(f, f)` with the same path twice; transform terms (`order_by("date__@year")`); `CTE(…)` and
`Joined(…)` handles. These still match their projection.

### How to find the calls to migrate

```bash
grep -rnE 'SQLField\(' --include=*.jl src/ test/ | grep -E 'SQLOrder|order_by'
```

Read each hit whose second argument differs from its first. Check whether the label is also an output
name in the same query's `values()`. A multi-line `SQLOrder(...)` needs reading by hand.

### Migrate your app

To order by the projection, name it as a string. To order by the expression, keep the term: it
now does what it says.

```julia
# ✗ before — sorted by best score through the label; it now sorts by the count, as written
M.Result.objects.values("constructorid", "best" => Max("points")).
    order_by(SQLOrder(SQLField(Count("resultid"), "best"); orientation = "DESC"))

# ✓ after — the projection, by its name
M.Result.objects.values("constructorid", "best" => Max("points")).order_by("-best")
```
