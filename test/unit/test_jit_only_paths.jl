"""
Hot reload and run-time `include` are JIT-only, and a running application never reaches them (#1608).

A trimmed binary cannot load new code, so what parses or evaluates code must stay off the path a
running application takes: registration (`set_models`), the self-heal (`ensure_model_initialized`)
and the query builder. Where it lives (#1599's inventory, 2026-11-06):

| site | reached from | kind |
|---|---|---|
| `Utils.reload_module_contents!` (`Meta.parseall`, `Core.eval`) | `PormGReviseExt`'s callback only | dev: Revise |
| `@import_models`' `Base.include(Models._with_model_set, …)` | the macro expansion's first top-level statement | load time, never later |
| `import_models(path; into)`'s `Base.include` | a REPL or a script that calls it | dev |
| the migration planner's `Base.include` (`_load_current_models`) | `makemigrations`, `check` | dev/ops, #1603 |
| `Generator`'s `Meta.parse` | `generate_models_from_db`, the importers | dev |

These tests pin the boundary by source: `Models.jl` holds no `Core.eval`, `Meta.parse` or run-time
`include`; `Utils.jl` holds them only in the reload helper and the macro's quoted expansion; and the
expansion's `include` is its own top-level statement, not code a registration function runs.

No SQL, no database.

    julia --project=test/integration test/unit/test_jit_only_paths.jl
"""

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _JIT_ROOT = pkgdir(PormG)

# The code lines of a file: whole-line comments and docstring/string blocks (between `\"\"\"` lines)
# dropped, so a docstring's example is not a call.
function _jit_code_lines(path::AbstractString)
  out = Tuple{Int, String}[]
  in_str = false
  for (i, l) in enumerate(eachline(path))
    n = count("\"\"\"", l)
    if in_str
      isodd(n) && (in_str = false)
      continue
    end
    if isodd(n)
      in_str = true
      continue
    end
    startswith(lstrip(l), "#") && continue
    push!(out, (i, l))
  end
  return out
end

_jit_hits(path, pat::Regex) = [(i, strip(l)) for (i, l) in _jit_code_lines(path) if occursin(pat, l)]

# ─────────────────────────────────────────────────────────────────────────────
# Models.jl evaluates no code
# What it tests: `src/Models.jl` (registration, the self-heal, the model graph) has no `Core.eval`,
#   no `Meta.parse`/`parseall`, no `invokelatest(Core.eval` and no `include(` but its three field-file
#   includes at the top level.
# Why it matters: #1607 removed the two `Core.eval` writes into a closed module that a trimmed binary
#   could not run (and a catch-all hid); this keeps one from coming back on the registration path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Models.jl evaluates and includes no code at run time (#1607, #1608)" begin
  models = joinpath(_JIT_ROOT, "src", "Models.jl")
  @test isempty(_jit_hits(models, r"Core\.eval\b|Meta\.parse"))
  includes = _jit_hits(models, r"\binclude\(")
  @test [l for (_, l) in includes] ==
        ["include(\"models/network_address.jl\")", "include(\"models/pg_array.jl\")",
         "include(\"models/fields.jl\")"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Utils.jl: the reload helper and the macro expansion only
# What it tests: in `src/Utils.jl`, `Core.eval` and `Meta.parse` appear only inside
#   `reload_module_contents!`, and `Base.include` only inside `macro import_models`; no `includet`
#   hook remains, and `set_revise_hooks!` takes only `add_revise_callback`.
# Why it matters: the reload is reached only from the Revise extension; nothing a registration runs
#   includes a file.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Utils.jl: eval in the reload helper, include in the macro expansion only (#1608)" begin
  utils = joinpath(_JIT_ROOT, "src", "Utils.jl")
  lines = readlines(utils)
  span(start_pat) = begin
    a = findfirst(l -> occursin(start_pat, l), lines)
    b = findnext(l -> l == "end", lines, a)
    a:b
  end
  reload_span = span(r"^function reload_module_contents!")
  macro_span = span(r"^macro import_models")
  for (i, _) in _jit_hits(utils, r"Core\.eval\b|Meta\.parse")
    @test i in reload_span
  end
  include_lines = [i for (i, _) in _jit_hits(utils, r"\binclude\(")]
  @test !isempty(include_lines)
  @test all(i -> i in macro_span, include_lines)
  @test isempty(_jit_hits(utils, r"includet"))
  kws = Base.kwarg_decl(only(methods(PormG.Utils.set_revise_hooks!)))
  @test kws == [:add_revise_callback]
end

# ─────────────────────────────────────────────────────────────────────────────
# The macro's include is its own top-level statement
# What it tests: `@import_models "db/models.jl" models` expands to a `:toplevel` expression whose first
#   statement is the `Base.include(Models._with_model_set, …)` call and whose second calls
#   `Utils._post_import_setup`; the include is not inside it, and neither `_post_import_setup` nor
#   `_setup_imported_models!` includes a file.
# Why it matters: the include runs where the macro is expanded — a module body at precompile, or a
#   script's top level — and never later, from a registration or an `__init__`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "@import_models includes at its expansion's top level only (#1608)" begin
  ex = macroexpand(Main, :(PormG.@import_models "db/models.jl" models))
  @test ex isa Expr && ex.head === :toplevel && length(ex.args) == 2
  # Each statement is wrapped in macro hygiene (`hygienic-scope`); the call is its first argument.
  unwrap(e) = e isa Expr && e.head === Symbol("hygienic-scope") ? e.args[1] : e
  first_stmt, second_stmt = unwrap.(ex.args)
  @test first_stmt.head === :call && first_stmt.args[1] == :(Base.include)
  @test first_stmt.args[2] == GlobalRef(PormG.Models, :_with_model_set)
  @test second_stmt.head === :call && second_stmt.args[1] == GlobalRef(PormG.Utils, :_post_import_setup)
  utils = joinpath(_JIT_ROOT, "src", "Utils.jl")
  lines = readlines(utils)
  for fname in ("_post_import_setup", "_setup_imported_models!")
    a = findfirst(l -> startswith(l, "function $(fname)("), lines)
    b = findnext(l -> l == "end", lines, a)
    @test !any(l -> occursin(r"\binclude\(|Core\.eval", l), lines[a:b])
  end
end
