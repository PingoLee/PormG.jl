## A refused value raises `InvalidValueError` in a filter too, and no refusal prints the value (#971)

- **Version**: Unreleased
- **PormG ref**: #971 ; `src/exceptions.jl` (`InvalidValueError`, `with_location`), `src/querybuilder/build_helpers.jl` (`_locate_filter_refusal`), `src/querybuilder/sanitization.jl`, `src/querybuilder/execution_bulk.jl`, `src/Models.jl`
- **Recorded**: 2026-10-06
- **Severity**: breaking (narrow). A filter value the field's formatter refuses raises `InvalidValueError`, not `FilterError`. Every refusal message changed wording, and none contains the refused value any more.

### What changed

**1. The type on the filter path.** A value a field cannot take — text in a number column, a
malformed UUID or date, an integer other than 0/1 on a boolean — raises `InvalidValueError` in a
`filter()` as it already did on a write. It used to be re-raised as `FilterError`. `FilterError`
stays for what is wrong with the filter itself: an unknown lookup, an operator misused, a list where
one value belongs, a `@family` / `@year` value outside its range.

| `M.Result.objects.filter(…)` | before | after |
|---|---|---|
| `"points" => "fast"` (a `FloatField`) | `FilterError` | `InvalidValueError` |
| `"race__date" => "2026-13-45"` | `FilterError` | `InvalidValueError` |
| `"driverid__driverref" => 1.0` (a `CharField`) | `FilterError` | `InvalidValueError` |
| a projection alias: `values("best" => Max("points")).filter("best" => "fast")` | `FilterError` | `InvalidValueError` |
| `"points__@foo" => 1` (an unknown lookup) | `FilterError` | `FilterError` (unchanged) |

**2. No refusal prints the value.** A bound value can be a password or a token, and an app may
return `e.msg` to an HTTP client. Messages now name where the value was refused and why:

```
before: The points field is the type FLOAT. Please check the value: s3cr3t
after:  Error in filter, field `points` (FLOAT): The value is not a valid number

before: Error in bulk processing, the field points (col: points) in row 2 has a value that can't be formatted: s3cr3t (The value 's3cr3t' is not a valid number)
after:  Error in bulk_insert, row 2 for model result, field `points`: The value is not a valid number (from column points).

before: Error in insert for model result, field "grid": expected Int64 or an integer string, got String (value="s3cr3t")
after:  Error in insert for model result, field `grid`: expected Int64 or an integer string, got String
```

**3. The reason is data.** `InvalidValueError` keeps its `msg`, and gains `kind` (`:type`,
`:format`, `:range`, `:nul`, `:json_nul`, `:other`), `reason`, and the location `op`, `model`,
`field`, `field_type`, `row` (`nothing` where unknown). Branch on `e.kind` or `e.field` rather
than on the message text. `InvalidValueError("…")` still builds one from a message alone.

### Who this affects

Code that catches `FilterError` around a `filter()` to report a bad user-supplied value, and code
that matches refusal messages by text. Measured before the change: no consuming app catches
`FilterError` or matches either old message; one returns `e.msg` from any caught exception in an
HTTP 400 body, which is exactly the leak this closes.

### How to find the calls to migrate

```bash
grep -rnP 'FilterError|Please check the value|can.t be formatted|value=' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — a bad filter value was a FilterError, and the message carried it
try
    M.Result.objects.filter("points" => params["points"]).list()
catch e
    e isa FilterError && return json(Dict("error" => e.msg), status = 400)
    rethrow()
end

# ✓ after — a refused value is an InvalidValueError, located as data
try
    M.Result.objects.filter("points" => params["points"]).list()
catch e
    e isa InvalidValueError && return json(Dict("error" => "invalid $(e.field)"), status = 400)
    e isa FilterError && return json(Dict("error" => error_message(e)), status = 400)
    rethrow()
end
```
