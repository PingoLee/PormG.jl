# Guards for PormG's precompilation: the directives in src/precompile.jl, and the SQLite
# extension's end-to-end workload (the end of ext/PormGSQLiteExt.jl).
#
# Both halves fail QUIETLY without this file. `Base.precompile` returns `false` on a signature that
# no longer matches rather than throwing, so a stale directive costs nothing at build time and
# simply stops warming anything. And an extension whose workload throws is not a build error
# either: Julia logs the failure, skips the extension, and `using PormG, SQLite` carries on — every
# SQLite call then raises "requires SQLite", far from the cause.
#
# Hermetic: reads source files via `pkgdir`, calls `precompile` at runtime, needs no database.

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _PRECOMPILE_SRC = read(joinpath(pkgdir(PormG), "src", "precompile.jl"), String)

# ─────────────────────────────────────────────────────────────────────────────
# Precompile hints: no directive names an anonymous closure by its generated number
# `Symbol("#106#107")` is the compiler's name for "the 53rd closure in this module", so it shifts
# whenever a closure is added above it. src/precompile.jl carried six of these behind an `isdefined`
# guard; by the time they were removed three no longer existed and the fourth named a different
# closure — 5.35 s of claimed warm-up that had silently become nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Precompile hints: no numbered-closure directives" begin
  files = [joinpath(pkgdir(PormG), "src", "precompile.jl");
           filter(endswith(".jl"), readdir(joinpath(pkgdir(PormG), "ext"); join = true))]
  for f in files
    # `var"#…"` is the other spelling of the same generated name. Comment lines are skipped: the
    # history note in src/precompile.jl quotes the shape it replaced.
    offenders = [l for l in eachline(f)
                 if !startswith(lstrip(l), "#") && occursin(r"Symbol\(\"#\d|var\"#\d", l)]
    @test isempty(offenders) || (@info "numbered-closure directive" file = basename(f) offenders; false)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Precompile hints: every `Base.precompile(Tuple{…})` directive still matches a method
# Each directive is re-evaluated at runtime, in the same `let QB = QueryBuilder` scope the file
# uses, and must return `true`. A rename, a narrowed argument type, or a moved method makes it
# return `false` — which is the whole failure, since nothing at precompile time reports it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Precompile hints: every Tuple directive still matches" begin
  directives = [m[1] for m in eachmatch(r"^\s*(Base\.precompile\(Tuple\{.*\}\))"m, _PRECOMPILE_SRC)]
  # Not vacuous: the count must equal every `Base.precompile(Tuple` in the file, so a directive
  # reformatted across lines (which the regex above would skip) fails here instead of vanishing.
  @test length(directives) == count("Base.precompile(Tuple", _PRECOMPILE_SRC)
  @test !isempty(directives)
  for d in directives
    ok = Core.eval(PormG, :(let QB = QueryBuilder; $(Meta.parse(d)); end))
    @test ok || (@info "stale precompile directive" d; false)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Precompile hints: the keyword-method body-function directives still resolve
# The `add_parameter!` / `_determine_join_type` directives look the body function up with
# `try Base.bodyfunction(which(…)) catch; missing end` and skip when it is `missing`, so a changed
# positional signature turns them off with no message. Each lookup must succeed, and each
# `precompile(fbody, …)` it guards must return `true`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Precompile hints: body-function directives still resolve" begin
  lookups = [m[1] for m in eachmatch(r"try (Base\.bodyfunction\(which\(.*\)\)\)) catch", _PRECOMPILE_SRC)]
  @test length(lookups) == count("Base.bodyfunction(", _PRECOMPILE_SRC)
  @test !isempty(lookups)
  # Walk the file in order: each `precompile(fbody, …)` belongs to the lookup above it.
  fbody = nothing
  checked = 0
  for line in eachline(IOBuffer(_PRECOMPILE_SRC))
    if (m = match(r"try (Base\.bodyfunction\(which\(.*\)\)\)) catch", line)) !== nothing
      # `which` throws on a signature with no method; that is the stale case, reported as a failure.
      fbody = try Core.eval(PormG, :(let QB = QueryBuilder; $(Meta.parse(m[1])); end)) catch; nothing end
      @test fbody !== nothing || (@info "body function not found" lookup = m[1]; false)
    elseif (m = match(r"precompile\(fbody, (\(.*\))\)\s*$", line)) !== nothing
      types = Core.eval(PormG, :(let QB = QueryBuilder; $(Meta.parse(m[1])); end))
      @test fbody !== nothing && precompile(fbody, types)
      checked += 1
    end
  end
  @test checked == count("precompile(fbody,", _PRECOMPILE_SRC)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite extension: loaded, which a throwing precompile workload would prevent
# The workload at the end of ext/PormGSQLiteExt.jl executes real queries at precompile time, and
# PrecompileTools lets a throwing step propagate. Julia's response is to log the error and not load
# the extension, so the direct symptom is this lookup returning `nothing`. Asserting it here names
# the cause; without it the suite reports a wall of unrelated "requires SQLite" errors instead.
# One-directional: it also passes when the workload never ran (PrecompileTools'
# `precompile_workloads = false` preference, `--compiled-modules=no`), neither of which CI sets.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite extension loaded (a throwing precompile workload would block it)" begin
  @test Base.get_extension(PormG, :PormGSQLiteExt) !== nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite extension: the workload leaves nothing machine-specific in the cache image
# The workload registers its models in `PormGSQLiteExt._PrecompileModels`, a submodule that IS
# serialized. Two things keep it inert: its `__pormg_init_path__` marker is pre-declared as "" (so
# `set_models` does not inject this machine's deleted temp folder), and the `finally` resets the
# three model bindings to `nothing` (so no Model object is saved). Dropping either keeps every other
# test green, because the image is only read here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite extension image carries no workload state" begin
  ext = Base.get_extension(PormG, :PormGSQLiteExt)
  @test ext !== nothing
  if ext !== nothing
    pm = ext._PrecompileModels
    @test pm.__pormg_init_path__ == ""
    for n in (:Driver, :Constructor, :Result)
      @test isdefined(pm, n) && getglobal(pm, n) === nothing
    end
  end
end
