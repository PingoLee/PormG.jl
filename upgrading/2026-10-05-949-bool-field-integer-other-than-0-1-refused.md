## An integer other than 0 or 1 given to a `BooleanField` raises (#949)

- **Version**: Unreleased
- **PormG ref**: #949 ; `src/Models.jl` (`format_bool_sql(::Integer)`), `src/querybuilder/build_query.jl` (`_expression_formatter(::FExpression)`)
- **Recorded**: 2026-10-05
- **Severity**: breaking (narrow). Any integer but 1 used to be written and filtered as `false`. It now raises `InvalidValueError` on a write and `FilterError` in a filter.

### What changed

`format_bool_sql` is the formatter of every `BooleanField`. Its guard against an integer other than
0/1, `value in [0, 1] == false`, is a chained comparison that never fired, so every integer except 1
became `false`, silently and on both engines:

| call | before, both engines | after, both engines |
|---|---|---|
| `filter("is_active" => 5)` | matched the `false` rows | raises `FilterError` |
| `update("is_active" => 2)`, `create(…)`, `bulk_insert`, `bulk_update` | wrote `false` | raises `InvalidValueError` |
| `ArrayField(BooleanField())` given `[true, 2]` | wrote `{t,f}` | raises `InvalidValueError` |
| `values("ahead" => F("lap") > F("points"))` then `filter("ahead" => 5)` | bound `5` as written | raises `FilterError` |

`0`, `1`, `true`, `false` and `missing` behave exactly as before. The last row comes from the same
change: a projected comparison is now typed as a boolean, so its alias filter goes through the same
formatter. `filter("ahead" => 1)` now binds `true` on PostgreSQL where it bound the integer.

### Who this affects

Apps that hand a `BooleanField` an integer from data rather than a `Bool`: an import or a feed that
codes a flag numerically, a form value parsed with `parse(Int, …)`, or a DataFrame column of codes
going to `bulk_insert` / `bulk_update`. The common trap is a source that codes
`1` = yes, `2` = no, `9` = unknown. The `2` happened to be stored as the right answer (`false`), and
the `9` was stored as `false` too, which was wrong. The consuming apps have **0** literal call sites
(measured 2026-10-05), but the value is runtime data, so no grep can count the rest.

### How to find the calls to migrate

Run the app's tests and the imports. Every remaining write raises with this message:

```
A boolean value must be true, false, 0 or 1. Got the integer
```

and every remaining filter with:

```
field is the type BOOLEAN. Please check the value:
```

Then check where integer codes reach a boolean column:

```bash
grep -rn 'BooleanField(' --include='*.jl' <your-app>/src
```

### Migrate your app

Map the code to the flag explicitly, and decide what an unknown code means; PormG no longer decides
it for you.

```julia
# A race-entry feed codes its rookie flag 1 = yes, 2 = no, 9 = unknown; `is_rookie = BooleanField(null = true)`.

# ✗ before: 2 and 9 were both stored as false
M.Race_entry.objects.create("raceid" => race, "is_rookie" => row.rookie_code)

# ✓ after: the meaning of each code, spelled out
rookie = row.rookie_code == 1 ? true : row.rookie_code == 2 ? false : missing   # 9 → NULL
M.Race_entry.objects.create("raceid" => race, "is_rookie" => rookie)
```
