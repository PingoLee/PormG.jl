## `Concat` over arithmetic on a `Case` with a float branch is refused, as the `Case` alone is (#1551)

- **Version**: Unreleased
- **PormG ref**: #1551 ; `src/querybuilder/projection_types.jl` (`_textless_walk_leaf`, `_textless_number`)
- **Recorded**: 2026-11-01
- **Severity**: behavior change. On every engine, `Concat` over arithmetic on a `Case` that has a float or a decimal branch and no `output_field` now raises `QueryBuildError` when the query is built; it used to build. On SQLite, a cast of such arithmetic to an integer or to a zero-scale `numeric` raises `QueryBuildError` too.

### What changed

A `Case` with no `output_field` has one of its branch values on each row. When a branch is a float or
a decimal, the value has that number's text, and each engine writes it in its own form. So `Concat`
refuses such a `Case` as an operand (#1027, #1187): the query does not say which text it means.

The same `Case` inside arithmetic was not classified, so it got past that refusal:

| expression (`cs = Case(When("grid" => 1, then = 1.5), default = 0)`) | before | now |
|---|---|---|
| `Concat(Value("P"), cs)` | `QueryBuildError` (#1027) | `QueryBuildError` (#1027), unchanged |
| `Concat(Value("P"), cs + 1)`, `cs * 2`, `1 + cs` | built on PostgreSQL, SQLite and MySQL | `QueryBuildError` (#1027): "arithmetic over `CASE(…)` over a Float64 literal is not text" |
| the same over a `Case` with a `DecimalField` branch that has places (`then = F("points")` on `Constructor_results`) | built | `QueryBuildError` (#1027) |

The casts that read the same classification check the arithmetic as they check the `Case` alone. On
SQLite, where the cast computes a different value from what it means, they now raise:

| expression (`cs = Case(When("grid" => 1, then = 1.5), default = 0)`, `cp` the same with `then = F("points")` on `Constructor_results`) | before, on SQLite | now, on SQLite |
|---|---|---|
| `Cast(cp + 1, IntegerField())` | built, and truncated where PostgreSQL rounds | `QueryBuildError` (#1028) |
| `Cast(cs + 1, "numeric(10,0)")`, `Cast(cp + 1, "numeric(10,0)")` | built, and kept every digit where PostgreSQL rounds to the scale | `QueryBuildError` (#1040) |

PostgreSQL and MySQL compute what these casts mean, and they still build there. `Cast(cs + 1,
IntegerField())` was already refused on SQLite; only its message names the `Case` now.

A `Case` whose branches are all whole (integers, or a zero-scale `DecimalField`) still builds inside
arithmetic, cast or not, and so does a `Case` with an `output_field`.

### Who this affects

Code that concatenates text with arithmetic over an undeclared `Case` that has a float or decimal
branch: on every engine the query built and wrote that engine's own text of the number (PostgreSQL's
`numeric` or `float8`, SQLite's REAL, MySQL's `DECIMAL` or `DOUBLE`). And, on SQLite, code that casts
such arithmetic to an integer or a zero-scale `numeric`, which computed a different value there.

### How to find the calls to migrate

```bash
grep -rnE 'Concat\(' --include=*.jl src/ | grep -E 'Case\('
```

For each hit, check whether an operand is arithmetic (`+`, `-`, `*`, `/`) over a `Case` with a float
or decimal branch and no `output_field`.

### Migrate your app

Say which text you mean: cast the value to text, or declare the `Case`'s type and cast that.

```julia
cs = Case(When("grid" => 1, then = 1.5), default = 0)
# ✗ before: built, and wrote each engine's own text of the number
q = M.Result.objects
q.values("label" => Concat(Value("P"), cs + 1))
# ✓ after: the text you mean, the same call on every engine
q.values("label" => Concat(Value("P"), Cast(cs + 1, "text")))
# or round it to the number you mean first
q.values("label" => Concat(Value("P"), Cast(Round(cs + 1), IntegerField())))
# SQLite, a cast: say how to round, which every engine computes alike
q.values("n" => Cast(Round(cs + 1), IntegerField()))
```
