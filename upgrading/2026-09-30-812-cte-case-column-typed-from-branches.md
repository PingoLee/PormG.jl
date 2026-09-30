## A CTE column projected from `Case` is typed from its branches, and raises when they disagree (#812)

- **Version**: Unreleased
- **PormG ref**: #812 ; `src/querybuilder/ctes.jl`
- **Recorded**: 2026-09-30
- **Severity**: behavior change (narrow). A silently wrong result on SQLite is fixed. A `Case` whose type PormG cannot determine now raises at build time instead of being typed as text.

### What changed

A CTE body that projects a `Case` gives the outer query a column, and that column's type decides
how a value compared with it is bound. PormG used to type it from the Julia type of each branch
value. Any branch that was an expression (`then = F("points")`, `then = Rank(…)`) became
`CharField`. So did `Case`'s own default, the string `"NULL"`. `output_field=` was ignored. A single
bare `Case(When(…))` and `When(…, otherwise = …)` had their `then` value skipped altogether.

The column is now typed the way Django's `output_field` resolution works:

- `output_field=` wins when it is given.
- Otherwise each branch is resolved:
  - A plain value takes its Julia type (`true` is a boolean, no longer an integer).
  - `F("points")` takes the field it names.
  - A window or aggregate takes the type it has anywhere else in a CTE body.
  - `NULL` branches are skipped.
- The branches must agree. Integers and floats still mix, giving a float.
- A function that declares its type (`Coalesce(…, output_field = …)`, `Cast(x, type)`) can now be
  projected in a CTE body. Before, it raised "not a recognized function".

| before | after |
|---|---|
| `Case([When(…, then = F("points"))], default = 0)` was typed text; `c__col__@gt => 7` bound `"7"`, and **SQLite returned no rows** | typed as `points`' field; `7` binds as a number and the rows come back |
| `Case([When(…, then = 1)])` (default `"NULL"`) was typed text | typed integer |
| `Case(When(…, then = 1.5), default = 0)` was typed integer | typed float |
| `Case([When(…, then = 1)], default = "none")` was typed text | raises `QueryBuildError` naming both types |
| every branch `NULL`, or a branch such as `Lower(…)` whose type PormG does not infer, was typed text | raises `QueryBuildError` |
| on **SQLite**, `Case(…; output_field = DateField())` in a CTE body was typed text | raises `QueryBuildError`: SQLite's `CAST(… AS DATE)` returns a number (`2020`), not a date. Project the date column itself |

### Who this affects

- Apps on **SQLite** filtering on a CTE `Case` column whose branch is an expression, or that has
  no `default`. That filter returned no rows, or wrong ones, with no error.
- Apps whose CTE body projects a `Case` with text and numbers mixed, only `NULL` branches, or a
  branch PormG cannot type. These now raise when the query is built.

Measured before the change: the consuming apps have **0** `Case` calls inside a CTE body, so none
needs an edit.

### How to find the calls to migrate

```bash
grep -rnE '\.with\(' --include='*.jl' <your-app>/src
```

For each hit, check whether the CTE body's `values(...)` holds a `Case` or `When`. The error names
the CTE column at build time, so a test run surfaces the rest.

### Migrate your app

Name the type with `output_field`. It also casts the SQL value, so every row holds that type:

```julia
# ✗ before — text beside a number: typed text silently, now a QueryBuildError
body.values("resultid", "finish" => Case([When("positionorder" => 1, then = 1)], default = "none"))

# ✓ after — name the type the column holds
body.values("resultid", "finish" => Case([When("positionorder" => 1, then = "1")], default = "none",
                                         output_field = CharField()))
```
