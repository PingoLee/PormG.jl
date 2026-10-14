## `Case` / `When` with `then = nothing` (or `missing`) renders the literal `NULL` (#808)

- **Version**: 0.8.0
- **PormG ref**: #808 ; `src/querybuilder/select_nodes.jl` (`_is_null_literal`, the CASE/WHEN keyword loop)
- **Recorded**: 2026-10-11
- **Severity**: behavior change in the rendered SQL and the parameter vector only. Results are
  unchanged for `nothing`; `missing` used to produce SQL no engine parses.

### What changed

| Expression | before | after |
|---|---|---|
| `Case([When("grid" => 1, then = nothing)], default = 0)` | `CASE WHEN "grid" = $1 THEN $2 ELSE $3 END`, parameters `[1, nothing, 0]` | `CASE WHEN "grid" = $1 THEN NULL ELSE $2 END`, parameters `[1, 0]` |
| `then = missing`, `default = missing`, `otherwise = missing` | `THEN missing` / `ELSE missing`, which no engine parses | `THEN NULL` / `ELSE NULL` |

Every later `$N` in the statement shifts down by one for each `nothing` branch.

### Who this affects

Golden-SQL tests that pin the text or the parameter vector of a `Case` with a `nothing` branch.

### How to find the calls to migrate

```bash
grep -rnE '(then|default|otherwise) *= *(nothing|missing)' --include=*.jl test/
```

### Migrate your app

```julia
q = M.Result.objects.values("p" => Case([When("positionorder" => 1, then = nothing)], default = 0))

# ✗ before
@test inspect_query(q)[:parameters] == Any[1, nothing, 0]

# ✓ after
@test inspect_query(q)[:parameters] == Any[1, 0]
```
