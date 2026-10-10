## A function whose result is not boolean, used as a When condition, raises (#942)

- **Version**: Unreleased
- **PormG ref**: #942 ; `src/querybuilder/functions.jl` (`When(::SQLTypeFunction)`), `src/querybuilder/build_helpers.jl` (`_function_condition_kind`, `_render_function_body`)
- **Recorded**: 2026-10-05
- **Severity**: breaking (narrow). Before this change, a function used as a `When` condition rendered as written whatever its result type. Now, when its result type is known not to be boolean, it raises `QueryBuildError` on both engines.

### What changed

`When(...)` accepted any function as its condition and rendered it unchanged, as
`CASE WHEN <function> THEN …`. #931 closed the same gap for arithmetic `F` expressions, but a
function never reached that check:

| call | PostgreSQL before | SQLite before | after, both engines |
|---|---|---|---|
| `When(Lower("surname"), then = 1)` | error: argument of CASE/WHEN must be type boolean | text read as a number, so `'senna'` is 0 and false, and every row took the default | raises `QueryBuildError` when `When` is built |
| `When(Length("surname"), then = 1)` | same error | any non-empty name read as true | raises when `When` is built |
| `When(Sum("points"))`, `When(Rank(over = w))`, `When(Cast(x, "integer"))` | same error | the number read for truthiness | raises when `When` is built |
| `When(Coalesce("grid", 0))`, `When(Max("points"))` | same error | the number read for truthiness | raises when the query is built, once the operand's column is known |

A function whose result is boolean behaves exactly as before:

- `Cast(x, "boolean")`
- any function with `output_field = "boolean"`
- a `Coalesce`/`Max`/… over a `BooleanField`

A comparison over a function, `When(Lower("surname") == "senna")`, is not a function condition, and
it is unaffected too.

A function whose result type PormG cannot name is **not** checked, and still renders as written: `Lag`/`Lead` over a column, or a `Case` with no `output_field`.

### Who this affects

Apps that used a function's value as a truth value. That only ever ran on SQLite, and there it
usually read text as false. A `When` with a `"column" => value` condition is unaffected.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
used as a condition — a condition must be boolean
```

Then look for `When` called with a function as its first argument, qualified or not
(`FN.When(FN.Lower(…))`). The pattern also lists comparisons such as
`When(Lower("x") == "senna")` and `When(Q(…))` conditions, which are fine as they are. A call split across
lines escapes the pattern, so the test run above is the complete check:

```bash
grep -rnE 'When\(\s*[A-Za-z_.]*[A-Z][A-Za-z]*\(' --include='*.jl' <your-app>/src
```

### Migrate your app

Write out the comparison that SQLite was making implicitly: a value is true when it is non-zero.

```julia
# ✗ before: on SQLite, a text value read as a number (usually false); on PostgreSQL, an error
M.Result.objects.values("driverid__surname",
    "senna" => Case([When(Lower("driverid__surname"), then = 1)], default = 0))
M.Result.objects.values("driverid__surname",
    "named" => Case([When(Length("driverid__surname"), then = 1)], default = 0))

# ✓ after: the comparison spelled out
M.Result.objects.values("driverid__surname",
    "senna" => Case([When(Lower("driverid__surname") == "senna", then = 1)], default = 0))
M.Result.objects.values("driverid__surname",
    "named" => Case([When(Length("driverid__surname") > 0, then = 1)], default = 0))
```
