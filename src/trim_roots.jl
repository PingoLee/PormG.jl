# ── Layer 4: the roots a `juliac --trim` build of an app needs (#1599) ─────────────────────────────
# One public call, `trim_entrypoints(P...)`, made at the top level of an app's entry file. It names the methods a
# trimmed image reaches only through a run-time call, and roots each with `Base.Experimental.entrypoint`, which keeps a
# method in the image (a `precompile` statement does not) and does nothing under the JIT. Three sources, each kept where
# its knowledge lives:
#   - the query render's run-time re-entries into a nested node (`QueryBuilder._trim_render_roots(P)`, #1826);
#   - the upstream methods a JLL built with LazyJLLWrappers needs at start (`_trim_upstream_roots`, below);
#   - the methods a driver's own dependencies need (`backend_trim_roots(P)`, one method per extension).

# A JLL built with LazyJLLWrappers (Libiconv_jll 1.18.1, which every PormG app loads through YAML → StringEncodings)
# sets each product path in its `__init__` with `string(...)` over an untyped lazy value. A trimmed image had no code
# for it, and the binary stopped before `main` at `InitError(:Libiconv_jll, MissingCodeError(string(::LazyLibraryPath)))`
# (#1826). `LazyArtifactDir` is rooted only when a dependency has loaded LazyJLLWrappers: an older JLL build does not.
const _LAZY_JLL_WRAPPERS = Base.PkgId(Base.UUID("21706172-204c-4d4f-5420-656854206f44"), "LazyJLLWrappers")

function _trim_upstream_roots()
  roots = Tuple{Any,Tuple}[(string, (Base.Libc.Libdl.LazyLibraryPath,))]
  mod = get(Base.loaded_modules, _LAZY_JLL_WRAPPERS, nothing)
  mod === nothing || push!(roots, (string, (getglobal(mod, :LazyArtifactDir),)))
  return roots
end

# Every `(f, argtypes)` a trimmed build on the pool types `Ps` roots, each once.
function _trim_roots(Ps::Type...)
  roots = Tuple{Any,Tuple}[]
  for P in Ps
    P <: _SQLEngine || throw(ArgumentError("trim_entrypoints: $(P) is not a PormG connection pool type. Pass the " *
      "type of the pool the app registers, e.g. `PormG.ConnectionPool.SQLiteConnectionPool`."))
    append!(roots, QueryBuilder._trim_render_roots(P))
    append!(roots, backend_trim_roots(P))
  end
  append!(roots, _trim_upstream_roots())
  return unique!(roots)
end

"""
    trim_entrypoints(P::Type...) -> Nothing

Root, for a `juliac --trim` build, every method PormG reaches only through a run-time call on a pool of type `P`:
the query render's re-entries into a nested node (a function's operand, a subquery, a CTE body, a window), the
methods a driver's own dependencies need (SCRAM authentication's `Base64` methods for Postgres.jl), and the
upstream methods a JLL built with LazyJLLWrappers needs at start, rooted only when one is loaded. Pass one pool
type per engine the app registers:

```julia
# f1app.jl, the entry juliac builds
using PormG, SQLite
PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)

function (@main)(args::Vector{String})::Cint
    # … register the connection, run the queries …
    return 0
end
```

Call it at the **top level** of the entry file: a trimmed build keeps what the entry's top level roots, not what a
package's module body does. Under the JIT it does nothing (`Base.Experimental.entrypoint` records a root only while
an image is being written), so the same entry file runs unchanged with `julia`.

The pool types are `PormG.ConnectionPool.SQLiteConnectionPool`, `PormG.ConnectionPool.MySQLConnectionPool` and
`PormG.ConnectionPool.PostgresConnectionPool{:postgres}` (Postgres.jl). A driver whose dependencies need a root of
their own contributes it through its extension (`PormG.backend_trim_roots`), so an app never adds a second call.
Load the driver before calling it. Throws `ArgumentError` for a type that is not a PormG pool.

See the Static Compilation guide (`docs/src/static_compilation.md`).
"""
function trim_entrypoints(Ps::Type...)::Nothing
  for (f, argtypes) in _trim_roots(Ps...)
    Base.Experimental.entrypoint(f, argtypes)
  end
  return nothing
end
