## Every read path now raises `FilterError` for a value it cannot coerce (#576)

- **Version**: Unreleased
- **Recorded**: 2026-09-20
- **PormG ref**: #576; `src/querybuilder/build_helpers.jl` (`_guarded_format`,
  `_render_sargable_date_range`, the `SQLTypeFunction` branches, the #474 memo arm),
  `src/querybuilder/build_query.jl` (`_resolve_having_filter_value`, `_having_alias_formatter`),
  `src/querybuilder/execution.jl`
- **Severity**: behavior change — error type on the read path, plus one path that was simply broken

### What changed

#411 converted the scalar and membership filter branches from `InvalidValueError` to `FilterError`,
and #467 converted `@range` / `@nrange`. Twelve of the thirteen formatter call sites on the read
path were still outside that guard, so the same mistake reported the *write* path's type depending
only on which spelling you used. All of them now report `FilterError`:

```julia
# before -> InvalidValueError                       after -> FilterError
M.Result.objects.filter("driverid__dob" => "nope")                         # ANY joined path
M.Result.objects.filter("driverid__dob__@contains" => "x")                 # …incl. a lookup on one
M.Result.objects.values("constructorid", "tot" => Sum("points")).filter("tot__@gt" => "abc")  # alias
M.Race.objects.values("year", "mx" => Max("date")).filter("mx__@gt" => "nope")     # MAX/MIN alias
M.Race.objects.filter("date__@month" => "abc")                             # transform suffix
M.Race.objects.filter("date__@quarter" => 9)                               # period out of range
M.Race.objects.filter("date__@date" => "not-a-date")                       # sargable rewrite
M.Race.objects.filter("date__@yyyy_mm" => "nonsense")                      # sargable rewrite
```

**The first two are the ones most likely to be in your code**, and #576 did not list them: it
marked the joined-path site "suspected, no reproducing input found". Any foreign-key traversal
reaches it, because `"driverid__dob"` is not a key of the queried model's own fields.

The last two were not listed either: on a plain `DateField` the sargable rewrite short-circuits
*ahead* of the transform ladder, so it — not the ladder — is what formats those values.

A wrong-typed value that produces a `MethodError` rather than an `InvalidValueError` is unchanged
and still surfaces as `MethodError`; the guard converts one type, not everything.

### Also fixed: a non-aggregate projection alias was broken for well-typed values

`_resolve_having_filter_value` only recognised `SQLTypeFunction` projections, so everything else
fell through to `IntegerField`'s formatter:

```julia
q = M.Race.objects
q.values("raceid", "d2" => F("date"))
q.filter("d2" => Date(2026, 6, 15))
# before -> InvalidValueError: The value '2026-06-15' is not a valid number
# after  -> binds "2026-06-15" through the DateField formatter
```

**This one changes bound values, not just error types, so read it even if you catch nothing.** The
alias now formats through its own column's formatter, so for any non-numeric column the parameter
changes — and these cases never raised, so nothing announced them:

| alias projects a column of type | filter value | before | after |
|---|---|---|---|
| `CharField` / `TextField` | `5` | binds `5` | binds `"5"` |
| `BooleanField` | `1` | binds `1` | binds `true` |
| `DateField` / `DateTimeField` | `Date(2026, 6, 15)` | **raised** | binds `"2026-06-15"` |
| any numeric field | `7` | binds `7` | binds `7` — unchanged |

On SQLite this is the difference between matching and not: a TEXT column compared against the
integer `5` finds nothing, while `'5'` finds the row. The new value is the one the ordinary
`filter("name" => 5)` spelling has always bound, so the alias now agrees with the plain filter
instead of disagreeing with it — but if you built around the old behavior, that is where to look.

An alias over *arithmetic* (`F("points") + 1`) or over a joined path deliberately keeps the old
`IntegerField` fallback, because neither one's result type is the column's.

### What you need to do

If you catch `InvalidValueError` around a **read**, change it to `FilterError`, or catch
`PormGError` for both. Writes are untouched: `create`, `update` and the bulk writers still raise
`InvalidValueError`, which is what its docstring scopes it to.

```bash
grep -rnE 'InvalidValueError' <your app>/ | grep -viE 'insert|update|bulk|create|save'
```

This supersedes the "**The conversion is still not complete**" note on #467's 0.6.0 entry, which
named three shapes and told you to keep the handlers around them. The list above is the full one.
