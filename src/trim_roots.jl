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
  mod === nothing || !isdefined(mod, :LazyArtifactDir) || push!(roots, (string, (getglobal(mod, :LazyArtifactDir),)))
  return roots
end

# The refusal for a pool type `trim_entrypoints` cannot root for, or `nothing`: a type that is not a PormG pool, one that
# is not concrete (`PostgresConnectionPool` without its driver, an engine's abstract type), whose roots would be for a
# pool no call ever has, and one whose driver is not loaded (its extension names the handle type), whose own roots
# (Postgres.jl's SCRAM methods) would be missing. Each would build, then stop at `Core.MissingCodeError` at run time.
function _trim_pool_refusal(@nospecialize(P::Type))::Union{Nothing, String}
  P <: _SQLEngine || return string(P, " is not a PormG connection pool type")
  isconcretetype(P) || return string(P, " is not a concrete pool type; name the one the app registers, e.g. ",
                                     "`PormG.ConnectionPool.PostgresConnectionPool{:postgres}` for Postgres.jl")
  backend_handle_type(P) === Any && return string("the driver of ", P, " is not loaded; `using` the driver (SQLite, ",
                                                  "MySQL, Postgres) comes before this call")
  return nothing
end

function _check_trim_pools(Ps::Tuple)
  isempty(Ps) && throw(ArgumentError("trim_entrypoints: pass the type of each pool the app registers, e.g. " *
                                     "`PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)`."))
  for P in Ps
    reason = _trim_pool_refusal(P)
    reason === nothing || throw(ArgumentError(string("trim_entrypoints: ", reason, ".")))
  end
  return nothing
end

# Every `(f, argtypes)` a trimmed build on the pool types `Ps` roots, each once.
function _trim_roots(Ps::Type...)
  _check_trim_pools(Ps)
  roots = Tuple{Any,Tuple}[]
  for P in Ps
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
package's module body does. Under the JIT it checks its arguments and returns: nothing is rooted or computed
(`Base.Experimental.entrypoint` records a root only while an image is being written), so the same entry file runs
unchanged with `julia`.

The pool types are `PormG.ConnectionPool.SQLiteConnectionPool`, `PormG.ConnectionPool.MySQLConnectionPool` and
`PormG.ConnectionPool.PostgresConnectionPool{:postgres}` (Postgres.jl). A driver whose dependencies need a root of
their own contributes it through its extension (`PormG.backend_trim_roots`), so an app never adds a second call.
Load the driver before calling it. Throws `ArgumentError`, under the JIT as well, when no type is given or a type is
not a concrete PormG pool type whose driver is loaded: each of those would build and then stop at
`Core.MissingCodeError` at run time.

See the Static Compilation guide (`docs/src/static_compilation.md`).
"""
function trim_entrypoints(Ps::Type...)::Nothing
  _check_trim_pools(Ps)
  # Under the JIT, return before computing anything: `Base.Experimental.entrypoint` records a root only while an image
  # is being written (the same predicate), and computing the roots runs inference (about 2 s on a first call).
  ccall(:jl_generating_output, Cint, ()) == 0 && return nothing
  for (f, argtypes) in _trim_roots(Ps...)
    Base.Experimental.entrypoint(f, argtypes)
  end
  return nothing
end
