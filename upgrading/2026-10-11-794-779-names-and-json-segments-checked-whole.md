## An alias or JSON key ending in a newline, and a JSON path segment of non-ASCII digits, are refused (#794, #779)

- **Version**: 0.8.0
- **PormG ref**: #794, #779 ; `src/querybuilder/sanitization.jl` (`SAFE_IDENTIFIER_PATTERN`, `SAFE_JSON_KEY_PATTERN`), `src/Dialect.jl` (`_is_json_array_index`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. Two name shapes that were accepted now raise `InvalidValueError`;
  one JSON path segment renders as an array index instead of a key.

### What changed

The patterns that check a query alias and a JSON path segment were anchored with `^…$`. In the
regex engine Julia uses, `$` also matches just before a final newline, so a name ending in `"\n"`
passed. They are now anchored on the whole string. Separately, the JSON path code had two
different tests for "is this segment an array index", and they disagreed:

| Call | before | after |
|---|---|---|
| `values("driver\n" => "surname")` — and a `.with(…)` CTE name, a `cjoin_on` alias, a filter alias with a trailing newline | accepted; the newline went into the SQL alias | `InvalidValueError` naming the alias with its `\n` visible |
| `filter("payload__name\n" => 1)` (a JSON key segment ending in a newline) | accepted, interpolated into the JSON path | `InvalidValueError` |
| A JSON segment of non-ASCII digits (`"payload__١٢"`) | accepted by the check, rendered as a **key** | `InvalidValueError`: neither an index nor a safe key |
| A JSON segment of ASCII digits too long for `Int` (`"payload__99999999999999999999"`) | accepted by the check, rendered as a **key** | rendered as an array **index**, as every shorter digit segment is |

### Who this affects

Code that builds an alias, CTE name or JSON path from text that can end in a newline (a line read
from a file or a request without `chomp`), or that addresses JSON with non-ASCII digit segments or
very long digit segments.

### How to find the calls to migrate

The names usually come from data, not literals. Find where aliases or JSON paths are built from
variables:

```bash
grep -rnE '(values|filter|with|cjoin_on)\( *[a-z_]+ *=>' --include=*.jl .
```

### Migrate your app

```julia
key = readline(io; keep = true)   # "pts\n"

# ✗ before — the newline went into the alias
M.Result.objects.values(key => "points")

# ✓ after — strip it first
M.Result.objects.values(chomp(key) => "points")
```
