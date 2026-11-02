## `using PormG` no longer loads `DataFrames` or `CSV`: add the one your app uses (#1344)

- **Version**: Unreleased
- **PormG ref**: #1344 (phase 6) ; `Project.toml`, `src/PormG.jl`, `src/QueryBuilder.jl`
- **Recorded**: 2026-11-01
- **Severity**: breaking, only for code that reached `DataFrames` or `CSV` through PormG's modules. Every PormG call returns what it returned before.

### What changed

`DataFrames` and `CSV` are no longer dependencies of PormG. The earlier phases of #1344 took every
use of them out of PormG: a query is a [Tables.jl](https://github.com/JuliaData/Tables.jl) table, the
bulk writers take any Tables.jl table and answer through its own `Tables.materializer` (a `DataFrame`
for a `DataFrame`), and `bulk_copy` writes
PostgreSQL's `COPY` text itself. This phase removes the two `[deps]` entries, so an app that loads
PormG no longer loads either package or the 26 others only they pulled in.

| | before | now |
|---|---|---|
| `using PormG` | loads `DataFrames` and `CSV` | loads neither |
| packages in PormG's own dependency closure | 80 | 52 |
| `Base.@time_imports using PormG`, summed (Julia 1.13, Linux, warm depot) | ≈ 945 ms | ≈ 530 ms |
| `julia -e 'using PormG'`, wall clock, same machine | ≈ 1.3 s | ≈ 0.83 s |
| `query \|> DataFrame`, `bulk_insert(…, df)`, `CSV.write(io, query)` (after `using DataFrames` / `using CSV`) | works | works, unchanged |
| `PormG.DataFrames`, `PormG.QueryBuilder.DataFrames`, `PormG.QueryBuilder.CSV` | the packages' modules | ``UndefVarError`` |
| `import PormG: DataFrames`, `using PormG.QueryBuilder: CSV` | imports the package's module | a `WARNING: Imported binding … was undeclared at import time`, then the same `UndefVarError` on first use |

### Who this affects

Only code that names either package through PormG's modules
(`PormG.QueryBuilder.DataFrames.DataFrame(…)`, `import PormG: DataFrames`). Julia already required an app to list a package in its
own `Project.toml` before `using DataFrames` could load it, so an app that writes `using DataFrames`
(or `using CSV`) already lists it and needs nothing.

### How to find the calls to migrate

```bash
grep -rnE '(PormG|QueryBuilder)\.(DataFrames|CSV)\b' --include=*.jl .
# the import form, `import PormG: DataFrames` / `using PormG.QueryBuilder: CSV`:
grep -rnE '(import|using) PormG(\.QueryBuilder)?:.*\b(DataFrames|CSV)\b' --include=*.jl .
# and every alias of a PormG module, whose `<alias>.DataFrames` the first line does not see:
grep -rnE '=\s*PormG(\.QueryBuilder)?\s*($|[;#])|PormG(\.QueryBuilder)? as' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: borrowing PormG's copy
df = PormG.QueryBuilder.DataFrames.DataFrame(driverid = [1, 2], surname = ["Senna", "Prost"])

# ✓ after: your app's own dependency
#   pkg> add DataFrames
using DataFrames
df = DataFrame(driverid = [1, 2], surname = ["Senna", "Prost"])
```
