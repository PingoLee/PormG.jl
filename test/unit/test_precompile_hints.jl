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
# serialized. The workload's `finally` keeps it inert: it clears the registration record in the
# module's model set (#1607: key, root and this machine's deleted temp folder), empties the set's
# lists (it holds the models themselves, #1606) and resets the three model bindings to `nothing`, so
# no Model object is saved. Dropping any of them keeps every other test green, because the image is
# only read here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite extension image carries no workload state" begin
  ext = Base.get_extension(PormG, :PormGSQLiteExt)
  @test ext !== nothing
  if ext !== nothing
    pm = ext._PrecompileModels
    record = PormG.Models._model_set(pm)
    @test record isa PormG.Models.ModelSet
    @test record.key === nothing && record.load_root === nothing && record.folder === nothing
    @test isempty(record.models) && isempty(record.bindings)
    @test !isdefined(pm, :__pormg_init_path__) && !isdefined(pm, :__pormg_binding__)
    for n in (:Driver, :Constructor, :Result)
      @test isdefined(pm, n) && getglobal(pm, n) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormG's own workload: the offline PostgreSQL step leaves nothing in the cache image
# Step 6 of src/precompile.jl registers two offline keys (the entry `register_offline` builds, on a
# LibPQ pool and on a Postgres.jl pool) and models in `PormG._PrecompilePgLibPQ` / `_PrecompilePgPostgres`,
# submodules that ARE serialized (#1702). Its `finally` removes both keys from `config`, clears each
# module's registration record and model set (#1607, #1606) and resets the model bindings to
# `nothing`. An entry left behind would ship a key named `__pormg_precompile_pg_*` in every
# application's `config`, and a model left behind would ship a Model object bound to a key that no
# longer exists; neither shows in any other test, because the image is only read here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormG image carries no offline PostgreSQL workload state (#1702)" begin
  # A key left in `config` does not survive to here: `Configuration.__init__` drops every entry an
  # image carries, and warns. The warning, printed when a fresh process loads PormG, is the trace a
  # leaked key leaves, so that is what is checked (reading `PormG.config` here passed with the
  # workload's `delete!` removed).
  err = IOBuffer()
  cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e "using PormG"`
  @test success(pipeline(cmd; stderr = err))
  @test !occursin("PormG dropped the connections", String(take!(err)))
  for pm in (PormG._PrecompilePgLibPQ, PormG._PrecompilePgPostgres)
    record = PormG.Models._model_set(pm)
    @test record isa PormG.Models.ModelSet
    @test record.key === nothing && record.load_root === nothing && record.folder === nothing
    @test isempty(record.models) && isempty(record.bindings)
    for n in (:Driver, :Constructor, :Result)
      @test isdefined(pm, n) && getglobal(pm, n) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormG's own workload: step 3 and step 6 run without a catch-all
# Step 3's `show_query` sat in `try … catch e end` and had been failing on every build: its
# `"points__gte"` filter predates the `__@` operator spelling, so it warmed only the error path
# (#348's shape, found while measuring #1702). Without the `try`, a throwing step fails PormG's
# precompile, which every test reports. This pins that no catch-all comes back around them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormG workload: the query-building steps are not wrapped in a catch-all (#1702)" begin
  i3 = findfirst("# 3. Precompile Query Building", _PRECOMPILE_SRC)
  i5 = findfirst("# 5. Precompile Dict{Symbol,String}", _PRECOMPILE_SRC)
  @test i3 !== nothing && i5 !== nothing
  if i3 !== nothing && i5 !== nothing
    step3 = _PRECOMPILE_SRC[first(i3):first(i5)]
    @test !occursin(r"^\s*catch\b"m, step3)
  end
  i6 = findfirst("# 6. The terminals on an offline PostgreSQL key", _PRECOMPILE_SRC)
  @test i6 !== nothing
  if i6 !== nothing
    step6 = _PRECOMPILE_SRC[first(i6):end]
    # Its one `try` is the cleanup's `try … finally`; no `catch` swallows a failed render.
    @test !occursin(r"^\s*catch\b"m, split(step6, "# ── Snoop-generated precompile hints")[1])
  end
end
