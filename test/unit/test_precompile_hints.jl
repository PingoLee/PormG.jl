# Guards for PormG's precompilation: the directives in src/precompile.jl, the SQLite extension's
# end-to-end workload (the end of ext/PormGSQLiteExt.jl), and the PostgreSQL extensions' offline
# terminal workload (`_offline_postgres_workload` in src/precompile.jl, run by PormGPostgresExt and
# PormGLibPQExt, #1732).
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
    for n in (:Driver, :Constructor, :Race, :Result)
      @test isdefined(pm, n) && getglobal(pm, n) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormG's own workload leaves no connection in the cache image
# The workload registers "precompile", "db" and "db_myapp" in `config` and removes them at the end. A
# key left in `config` does not survive to here: `Configuration.__init__` drops every entry an image
# carries, and warns. The warning, printed when a fresh process loads PormG, is the trace a leaked key
# leaves, so that is what is checked (reading `PormG.config` here passed with a `delete!` removed).
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormG image carries no workload connection" begin
  err = IOBuffer()
  cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e "using PormG"`
  @test success(pipeline(cmd; stderr = err))
  @test !occursin("PormG dropped the connections", String(take!(err)))
end

# ─────────────────────────────────────────────────────────────────────────────
# The PostgreSQL extensions: their workload ran, and left nothing in their images (#1732)
# `PormGPostgresExt` and `PormGLibPQExt` each call `PormG._offline_postgres_workload` from their
# workload, with an offline key and their submodule `_PrecompileModels`, which IS serialized. A
# throwing step blocks the extension from loading, quietly (`using Postgres` still succeeds), so the
# lookup is the check. The `finally` clears the module's registration record and model set (#1607,
# #1606) and resets the model bindings to `nothing`; a model left behind would ship a Model object
# bound to a key that no longer exists, which no other test reads.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL extension $name loaded, and its image carries no workload state (#1732)" for name in
    (:PormGPostgresExt, :PormGLibPQExt)
  ext = Base.get_extension(PormG, name)
  @test ext !== nothing
  if ext !== nothing
    pm = ext._PrecompileModels
    record = PormG.Models._model_set(pm)
    @test record isa PormG.Models.ModelSet
    @test record.key === nothing && record.load_root === nothing && record.folder === nothing
    @test isempty(record.models) && isempty(record.bindings)
    for n in (:Driver, :Constructor, :Race, :Result)
      @test isdefined(pm, n) && getglobal(pm, n) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The PostgreSQL terminal workload stays out of PormG's own workload (#1732)
# Run from PormG's workload (#1712's step 6), it compiled before any driver loaded, and `using
# Postgres` / `using LibPQ` invalidated it: a Nitro app's first `list` cost 17.9 s, tagged
# `# recompile`. It belongs to the extensions' workloads, which compile after the driver.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormG workload does not run the PostgreSQL terminal workload (#1732)" begin
  # Nothing in src/ calls it: the one occurrence of the call spelling is its own definition.
  calls = String[]
  for (root, _, files) in walkdir(joinpath(pkgdir(PormG), "src")), f in files
    endswith(f, ".jl") || continue
    for (n, line) in enumerate(eachline(joinpath(root, f)))
      occursin("_offline_postgres_workload(", line) && push!(calls, "$(f):$(n): $(strip(line))")
    end
  end
  @test length(calls) == 1 && occursin("function _offline_postgres_workload(", only(calls))
  for ext in ("PormGPostgresExt.jl", "PormGLibPQExt.jl")
    src = read(joinpath(pkgdir(PormG), "ext", ext), String)
    @test occursin("PormG._offline_postgres_workload(_PrecompileModels", src)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormG's workload: step 3 and the PostgreSQL terminal workload run without a catch-all
# Step 3's `show_query` sat in `try … catch e end` and had been failing on every build: its
# `"points__gte"` filter predates the `__@` operator spelling, so it warmed only the error path
# (#348's shape, found while measuring #1702). Without the `try`, a throwing step fails the
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
  i6 = findfirst("function _offline_postgres_workload", _PRECOMPILE_SRC)
  @test i6 !== nothing
  if i6 !== nothing
    body = split(_PRECOMPILE_SRC[first(i6):end], "# ── Snoop-generated precompile hints")[1]
    # Its one `try` is the cleanup's `try … finally`; no `catch` swallows a failed render.
    @test !occursin(r"^\s*catch\b"m, body)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A PostgreSQL session's first calls run on the driver extension's image (#1732)
# A fresh process loads PormG and one PostgreSQL driver, binds F1 models it declares itself (not the
# workload's) to an offline key on that driver's pool, and makes the first calls #1732 measured, under
# `--trace-compile`, which prints every method compiled at run time and tags `# recompile` on one
# whose cached code was invalidated. None of these may appear:
#   - `list` and `validate_field_data(…, ::String, …)`, tagged `# recompile` when the terminal
#     workload ran in PormG's image and `using Postgres` invalidated it (17.9 s and 0.5 s in a Nitro
#     app's boot);
#   - `get_or_create(…; defaults::Vector{Pair{String,Any}})`, the form a caller makes when it builds
#     `defaults` at run time, and `validate_field_data(…, ::DateTime, …)`, a `DateTimeField` value:
#     no workload compiled either (3.7 s and 0.5 s);
#   - any query-builder method tagged `# recompile`: a LibPQ session's `update`/`delete` recompiled
#     `_render_filter_oper` and `_get_filter_query` until `_open_connection` called `LibPQ.Connection`
#     through an inference barrier (ext/PormGLibPQExt.jl says why).
# Against the code before #1732 the first four are printed, on both drivers.
#
# Skipped under code coverage, which is how CI runs `Pkg.test()` (julia-runtest's `coverage`
# default): a process tracking PormG's coverage does not run the package images' native code, so
# everything is compiled at run time and every line is printed whatever the workloads did. It is also
# red where workloads do not run (PrecompileTools' `precompile_workloads = false` preference,
# `--compiled-modules=no`). It runs in a local `Pkg.test()` without coverage and when this file is
# run on its own.
# ─────────────────────────────────────────────────────────────────────────────
const _FIRST_CALLS_1732 = raw"""
using PormG, __PKG__
const M = Module(:FirstCalls1732)
Core.eval(M, quote
  import PormG.Models
  Circuit::Models.ModelType = Models.Model("circuit", circuitid = Models.IDField(),
    circuitref = Models.CharField(max_length = 255), name = Models.CharField(max_length = 255),
    country = Models.CharField(max_length = 255))
  Race::Models.ModelType = Models.Model("race", raceid = Models.IDField(), year = Models.IntegerField(),
    name = Models.CharField(max_length = 255), start_at = Models.DateTimeField(null = true),
    circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"))
  $(PormG.Models._model_set_declaration([:Circuit, :Race]))
end)
const C = PormG.Configuration
PormG.config["first_calls_1732"] = C.Settings(app_env = C.DEV, db_def_folder = "first_calls_1732",
  db_config_settings = C._offline_config_settings(:postgres, nothing), change_data = true,
  connections = PormG.ConnectionPool.PostgresConnectionPool(C._OFFLINE_CONNECTION; pool_size = 1, driver = :__DRIVER__))
Base.invokelatest(PormG.Models.set_models, M, "first_calls_1732")
const Circuit = Base.invokelatest(getglobal, M, :Circuit)
const Race = Base.invokelatest(getglobal, M, :Race)
defaults = Pair{String, Any}["name" => "Spa-Francorchamps", "country" => "Belgium"]
Base.invokelatest(Circuit.objects.get_or_create, "circuitref" => "spa"; defaults = defaults, show_query = :sql)
Base.invokelatest(Circuit.objects.get_or_create, "circuitid" => 13;
  defaults = vcat(defaults, Pair{String, Any}["circuitref" => "spa"]), show_query = :sql)
Base.invokelatest(() -> Race.objects.create("raceid" => 1, "year" => 2008, "name" => "Australian Grand Prix",
  "start_at" => PormG.Dates.DateTime(2008, 3, 16, 5, 30), "circuitid" => 1; show_query = :sql))
Base.invokelatest(() -> Race.objects.filter("year__@gte" => 2020, "circuitid__country" => "Italy").
  values("raceid", "name", "circuitid__name").list(; show_query = :sql))
Base.invokelatest(() -> Race.objects.filter("raceid" => 1).update("name" => "Gran Premio d'Italia"; show_query = :sql))
Base.invokelatest(() -> Circuit.objects.filter("circuitid" => 13).delete(; show_query = :sql))
"""

@testset "$pkg session: first calls compile nothing the workload covers (#1732)" for (pkg, driver) in
    (("Postgres", "postgres"), ("LibPQ", "libpq"))
  if Base.JLOptions().code_coverage != 0
    @test_skip "the trace needs the package images' native code, which coverage turns off"
  else
    script = tempname() * ".jl"
    write(script, replace(_FIRST_CALLS_1732, "__PKG__" => pkg, "__DRIVER__" => driver))
    err = IOBuffer()
    cmd = `$(Base.julia_cmd()) --startup-file=no --trace-compile=stderr --project=$(Base.active_project()) $script`
    ok = success(pipeline(cmd; stdout = devnull, stderr = err))
    rm(script; force = true)
    @test ok
    trace = filter(l -> occursin("precompile(", l), split(String(take!(err)), '\n'))
    compiled(pat) = filter(l -> occursin(pat, l), trace)
    # Printed on a failure, so the red run names the methods that were compiled.
    @test compiled(r"typeof\(PormG\.QueryBuilder\.list\)") == String[]
    @test compiled(r"typeof\(PormG\.QueryBuilder\.validate_field_data\)") == String[]
    # The callee is the `get_or_create` chain method, not `invokelatest`'s own keyword sorter.
    @test compiled(r"NamedTuple\{\(:defaults, :show_query\), Tuple\{Array\{Pair\{String, Any\}, 1\}, Symbol\}\}, PormG\.") == String[]
    @test compiled(r"_where_node!") == String[]
    # No query-builder method recompiled. `update` and `delete` are compiled inside the calls above, not
    # as roots of their own; what a LibPQ session printed for them, until `_open_connection`'s inference
    # barrier, was `_render_filter_oper` and `_get_filter_query` tagged `# recompile`.
    @test filter(l -> occursin("# recompile", l), compiled(r"PormG\.QueryBuilder\.")) == String[]
  end
end
