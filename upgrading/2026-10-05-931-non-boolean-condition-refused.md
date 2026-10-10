## An arithmetic or bitwise expression used as a condition raises (#931)

- **Version**: Unreleased
- **PormG ref**: #931 ; `src/querybuilder/build_helpers.jl` (`_check_filter_node(::FExpression)`)
- **Recorded**: 2026-10-05
- **Severity**: breaking (narrow). A non-boolean `F` expression in a condition used to render as written. It now raises `QueryBuildError` when the condition is built, on both engines.

### What changed

Wherever PormG expects a condition — `filter(...)`, `Q(...)` / `Qor(...)` and `push!` onto them,
a `When(...)` branch, `on(...)` / `cjoin(filters = …)` / `cjoin_on(on = …)` — an `F` expression
whose top-level operation is arithmetic (`+ - * /`) or bitwise (`& | xor << >> ~`) was rendered
unchanged:

| call | PostgreSQL before | SQLite before | after, both engines |
|---|---|---|---|
| `When(F("laps") + 1, then = 1)` | error: argument of CASE/WHEN must be type boolean | non-zero reads as true | raises `QueryBuildError` |
| `filter(F("points") & 4)` | error: argument of WHERE must be type boolean | non-zero reads as true | raises `QueryBuildError` |
| `filter(~F("is_active"))` | error: operator does not exist: ~ boolean | bitwise NOT of 0/1, always true | raises `QueryBuildError` |

So the same query returned rows on SQLite and failed on PostgreSQL. A bare boolean column
(`filter(F("is_active"))`, `When(F("is_active"), then = 1)`) and any comparison
(`(F("laps") + 1) > 0`) behave exactly as before, and arithmetic is still a value everywhere a
value goes: a projection, `then`, the right of a comparison.

### Who this affects

Apps that used a number as a truth value, which only ever worked on SQLite.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
used as a condition — a condition must be boolean
```

Then check the conditions built from an expression — an `F(...)`, or arithmetic over a function
such as `Count("id") - 1` — in every condition position, including the join spellings. A call split
across lines escapes the pattern, so the test run above is the complete check:

```bash
grep -rnE '(When|Q|Qor|filter|on|cjoin|cjoin_on|push!)\(.*(F\(|[A-Z][a-z]+\([^)]*\)\s*[-+*/&|])' --include='*.jl' <your-app>/src
```

### Migrate your app

Write the comparison SQLite was reading implicitly: non-zero is true.

```julia
# ✗ before: on SQLite, true wherever the value is non-zero; on PostgreSQL, an error
M.Result.objects.values("driverid__surname",
    "late" => Case([When(F("laps") - 50, then = 1)], default = 0))
M.Result.objects.filter(F("grid") & 1)

# ✓ after: the comparison spelled out
M.Result.objects.values("driverid__surname",
    "late" => Case([When((F("laps") - 50) != 0, then = 1)], default = 0))
M.Result.objects.filter((F("grid") & 1) != 0)

# ✓ a negated BooleanField (here a hypothetical `is_active`) is compared, not negated with ~
query.filter(F("is_active") == false)   # a model declaring is_active = BooleanField()
```
