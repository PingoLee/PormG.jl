## A filter's own value checks raise `InvalidValueError`, not `FilterError` (#988)

- **Version**: Unreleased
- **PormG ref**: #988 ; `src/querybuilder/filter_operators.jl` (`_year_bucket_bounds`, `_yyyy_mm_bucket_bounds`, `_check_year_bound`, `_render_network_operator`, `_json_numeric_rhs`)
- **Recorded**: 2026-10-09
- **Severity**: breaking (narrow). Five value checks that a lookup makes itself raise `InvalidValueError` instead of `FilterError`, located on the field the way a formatter refusal is.

### What changed

#971 made a value that a field's formatter refuses in a `filter()` raise `InvalidValueError`, as on a
write. It kept `FilterError` for value checks that the **lookup** makes rather than the field, so
the error type depended on which function refused the value, not on what the caller got wrong.
There is now one rule: **a value that would be bound as a parameter is refused with
`InvalidValueError`; an argument that shapes the SQL is refused with `FilterError`.**

| `filter(…)` | before | after (`e.kind`) |
|---|---|---|
| `"date__@year" => 99999` (outside 1–9999) | `FilterError` | `InvalidValueError` (`:range`) |
| `"date__@year" => 1991.5`, `=> true`, `=> "abc"` | `FilterError` | `InvalidValueError` (`:range`, `:type`, `:format`) |
| `"date__@yyyy_mm" => "1991-13"` (not a calendar month) | `FilterError` | `InvalidValueError` (`:range`) |
| `"client_ip__@family" => 5`, `"garage_lan__@prefixlen" => 129` | `FilterError` | `InvalidValueError` (`:range`; `:type` for a non-integer or a `Bool`) |
| `"metadata__wins__@gte" => "many"` (a numeric JSON comparison) | `FilterError` | `InvalidValueError` (`:format`; `:range` for a number that overflows) |
| `"date__@year__@foo" => 1991`, `"date__@isnull" => "yes"`, a list where one value belongs | `FilterError` | `FilterError` (unchanged — these shape the SQL) |

The messages name the lookup and what it accepts, never the value (#971), and `e.field` /
`e.field_type` carry the location: the column for `@year`, `@yyyy_mm`, `@family` and `@prefixlen`,
and the JSON path (`metadata__wins`, with no `field_type`) for a JSON comparison.

The `@year` and `@yyyy_mm` checks run where the comparison is rewritten into a date range — `=`,
`>`, `>=`, `<`, `<=` on a `DateField` (*Scope of the rewrite* in `read/functions_and_dates.md`). This
entry changes their type, not where they run.

```
before: The year is out of the range a date bound can express (1-9999).
after:  Error in filter, field `date` (DATE): The year is out of the range a date bound can express (1-9999)

before: Error in filter 'client_ip__@family': the @family lookup takes 4 or 6, got another Int64.
after:  Error in filter, field `client_ip` (INET): The @family lookup takes 4 or 6
```

### Who this affects

Code that catches `FilterError` around a `filter()` using `__@year`, `__@yyyy_mm`, `__@family`,
`__@prefixlen` or a `>`/`>=`/`<`/`<=` comparison on a JSON path, to report a bad user-supplied value;
and code that matches those messages by text.

### How to find the calls to migrate

```bash
grep -rnP 'FilterError|__@year|__@yyyy_mm|@family|@prefixlen|date bound can express|calendar month|numeric JSON comparison' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — a bad year was a FilterError, unlike a bad date
try
    M.Race.objects.filter("date__@year" => params["season"]).list()
catch e
    e isa FilterError && return json(Dict("error" => error_message(e)), status = 400)
    rethrow()
end

# ✓ after — every refused value is an InvalidValueError, whichever check refused it
try
    M.Race.objects.filter("date__@year" => params["season"]).list()
catch e
    e isa InvalidValueError && return json(Dict("error" => error_message(e)), status = 400)
    rethrow()
end
```
