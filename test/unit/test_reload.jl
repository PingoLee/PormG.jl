using Test
using PormG

if !haskey(ENV, "PORMG_ENV")
    ENV["PORMG_ENV"] = "test"
end

function _write_reload_sqlite_connection(path::String)
    open(path, "w") do f
        write(f,
            "env: test\n" *
            "test:\n" *
            "  adapter: SQLite\n" *
            "  database: \":memory:\"\n" *
            "  config:\n" *
            "    change_db: true\n" *
            "    change_data: true\n"
        )
    end
end

function _toml_escape_string(value::String)
    escaped = replace(value, "\\" => "\\\\")
    return replace(escaped, "\"" => "\\\"")
end

# Project.toml for a scratch package. PormG always rides via `[sources]`, so the child resolves
# THIS checkout rather than a registry copy; `deps` are `name => uuid` pairs.
function _write_scratch_project(pkg_root::String, pkg_name::String, uuid::String,
                                deps::Vector{Pair{String,String}})
    pormg_root = normpath(joinpath(@__DIR__, "..", ".."))
    dep_lines = join(("$(name) = \"$(dep_uuid)\"" for (name, dep_uuid) in deps), "\n")
    open(joinpath(pkg_root, "Project.toml"), "w") do f
        write(f,
            "name = \"$(pkg_name)\"\n" *
            "uuid = \"$(uuid)\"\n" *
            "version = \"0.1.0\"\n\n" *
            "[deps]\n$(dep_lines)\n\n" *
            "[sources]\nPormG = {path = \"$(_toml_escape_string(pormg_root))\"}\n")
    end
end

# The manifest the running tests resolved: the `Pkg.test` sandbox's, or `test/integration`'s. `nothing`
# only for an invocation with no environment carrying one, in which case the child resolves on its own.
function _parent_manifest_path()
    for env in Base.load_path()
        isfile(env) || continue
        manifest = Base.project_file_manifest_path(env)
        manifest === nothing || return manifest
    end
    return nothing
end

# #1060: the child resolves what the parent resolved. Left to itself, the scratch package's
# `Pkg.instantiate` resolves NEWEST-allowed versions, so on CI's floor-resolve job (a floor-pinned
# parent) it precompiled a second ~40-package tree cold and the 300 s budget ran out before the test
# body did — while testing nothing at the floor. Seeding the parent's manifest and `Pkg.resolve()`
# (UPLEVEL_FIXED: seeded versions stay, only what the parent lacks, e.g. Revise, is added) reuses the
# warm cache and makes the subprocess run at the versions under test. Relative `path` entries are
# made absolute: test/integration records PormG as "../..", which dangles in a temp dir. `Pkg.TOML`,
# not `TOML`: under `Pkg.test` the child can load only what its project lists. Prints two markers;
# MANIFEST_DRIFT is empty when every seeded package kept its version.
const _CHILD_SEED_AND_INSTANTIATE = """
seed_path = ARGS[2]
seeded = Dict{String,String}()
if !isempty(seed_path)
    manifest = Pkg.TOML.parsefile(seed_path)
    for (name, entries) in manifest["deps"], entry in entries
        haskey(entry, "path") && (entry["path"] = normpath(joinpath(dirname(seed_path), entry["path"])))
        haskey(entry, "version") && (seeded[name] = entry["version"])
    end
    open(io -> Pkg.TOML.print(io, manifest), "Manifest.toml", "w")
    Pkg.resolve()
end
Pkg.instantiate(; update_registry=false)
resolved = Dict(info.name => string(info.version) for info in values(Pkg.dependencies()) if info.version !== nothing)
println("MANIFEST_SEEDED:", !isempty(seed_path))
println("MANIFEST_DRIFT:", join(sort([name for (name, v) in seeded if get(resolved, name, v) != v]), ","))
"""

# Run `script` in a fresh Julia with the scratch project active. stdout and stderr are merged so a
# marker and the error that explains it land in one transcript. Returns (ok, output, timed_out).
function _run_child_julia(pkg_root::String, script::String; timeout::Float64 = 300.0)
    seed_manifest = something(_parent_manifest_path(), "")
    cmd = `$(Base.julia_cmd()) --project=$(pkg_root) -e $script $pkg_root $seed_manifest`
    output_buffer = PipeBuffer()
    process = run(pipeline(ignorestatus(cmd), stdout=output_buffer, stderr=output_buffer), wait=false)
    wait_status = Base.timedwait(() -> !process_running(process), timeout)

    if wait_status == :timed_out
        kill(process)
        wait(process)
        return (false, String(take!(output_buffer)), true)
    end

    wait(process)
    return (process.exitcode == 0, String(take!(output_buffer)), false)
end

function _run_import_models_package_regression()
    mktempdir() do temp_root
        # This temporary package mirrors the failure mode reported by the user:
        # the package source lives under src/, but the imported model module
        # lives outside src/ and is loaded via `../db_sch/sch_models.jl`.
        #
        # On the broken implementation this path triggered one of three outcomes:
        # 1. Revise silently skipped the include and `sch_models` stayed undefined.
        # 2. The Revise extension mutated PormG.Utils during precompilation and
        #    Julia aborted with the closed-module incremental compilation error.
        # 3. Revise file watchers stayed open and precompilation hung.
        pkg_name = "TempReloadPkg"
        pkg_root = joinpath(temp_root, pkg_name)
        src_dir = joinpath(pkg_root, "src")
        db_dir = joinpath(pkg_root, "db")
        db_sch_dir = joinpath(pkg_root, "db_sch")
        mkpath(src_dir)
        mkpath(db_dir)
        mkpath(db_sch_dir)

        _write_scratch_project(pkg_root, pkg_name, "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
                               ["Pkg"    => "44cfe95a-1eb2-52ea-b672-e2afdf69b78f",
                                "PormG"  => "7d8d7541-4d3d-4580-80a2-17064efb0993",
                                "Revise" => "295af30f-e4ad-537b-8983-00126c2a3abe"])

        _write_reload_sqlite_connection(joinpath(db_dir, "connection.yml"))
        _write_reload_sqlite_connection(joinpath(db_sch_dir, "connection.yml"))

        open(joinpath(db_sch_dir, "sch_models.jl"), "w") do f
            write(f, """
            module sch_models
                import PormG.Models

                SchThing = Models.Model(\"sch_thing\",
                    id = Models.IDField(),
                    name = Models.CharField()
                )
            end
            """)
        end

        open(joinpath(src_dir, "$(pkg_name).jl"), "w") do f
            write(f, """
            module $(pkg_name)
            using PormG

            const PKG_ROOT = normpath(joinpath(@__DIR__, ".."))

            PormG.Configuration.load(joinpath(PKG_ROOT, \"db\"))
            PormG.Configuration.load(joinpath(PKG_ROOT, \"db_sch\"))

            PormG.@import_models \"../db_sch/sch_models.jl\" sch_models
            import .sch_models as SM

            const MODEL_OK = isdefined(SM, :SchThing) && basename(SM.SchThing.connect_key) == \"db_sch\"
            end
            """)
        end

        script = """
        using Pkg
        cd(ARGS[1])
        ENV[\"JULIA_PKG_PRECOMPILE_AUTO\"] = \"0\"
        $(_CHILD_SEED_AND_INSTANTIATE)
        using Revise
        using TempReloadPkg
        println(\"SUBPROCESS_OK:\", TempReloadPkg.MODEL_OK)
        """

        return _run_child_julia(pkg_root, script)
    end
end

const _BOOT_APP_UUID = "b7f4e2a1-3c5d-4e6f-8a9b-1c2d3e4f5a6b"

# #552: a scratch package that follows the documented boot pattern to the letter, precompiled and
# then loaded in a fresh process. The child prints what the RESTORED image says, one marker per
# line, so a failing assertion names the wrong value rather than a bare `false`.
function _run_boot_pattern_regression()
    mktempdir() do temp_root
        pkg_name = "ScratchBootApp"
        pkg_root = joinpath(temp_root, pkg_name)
        src_dir = joinpath(pkg_root, "src")
        db_dir = joinpath(pkg_root, "db")
        mkpath(src_dir)
        mkpath(db_dir)

        # No Revise, so the child pays for one precompile, not two. `Pkg` IS listed, although it is a
        # stdlib: under `Pkg.test` the child inherits a sandboxed load path with no default
        # environment and no `@stdlib`, so the child script's `using Pkg` resolves only through
        # this project. A developer's shell masks that (CI caught it on PR #621).
        _write_scratch_project(pkg_root, pkg_name, _BOOT_APP_UUID,
                               ["Pkg"   => "44cfe95a-1eb2-52ea-b672-e2afdf69b78f",
                                "PormG" => "7d8d7541-4d3d-4580-80a2-17064efb0993"])

        # Three environments so each wrong answer names its source: `test` is what the parent
        # process's PORMG_ENV would select through the implicit load, `staging` is what the file's
        # `default_env:` would when PORMG_ENV is unset (this file forces it to `test`, so `test` is
        # the live decoy here). The application asks for `dev`, and only `dev` is right.
        write(joinpath(db_dir, "connection.yml"),
            "default_env: staging\n" *
            join(("$(env):\n  adapter: SQLite\n  database: \":memory:\"\n"
                  for env in ("dev", "test", "staging"))))

        write(joinpath(db_dir, "models.jl"), """
        module models
            import PormG.Models

            Lap = Models.Model("lap",
                id = Models.IDField(),
                ms = Models.IntegerField()
            )
        end
        """)

        # The pattern from docs/src/configuration/advanced.md ("Loading before `@import_models` is
        # not enough for a package"), verbatim in shape: configuration loaded in the module body
        # AND from `__init__`, `@import_models` between them, an explicit `env`. The two pids are
        # witnesses that the body ran in the precompile worker and `__init__` in the loading process.
        write(joinpath(src_dir, "$(pkg_name).jl"), """
        module $(pkg_name)
        using PormG

        const APP_ROOT = normpath(joinpath(@__DIR__, ".."))
        const DB_DIRS  = ["db"]
        const BODY_PID = Base.Libc.getpid()
        const INIT_PID = Ref(0)

        # An explicit env: neither the inherited PORMG_ENV nor the file's default_env: decides.
        # `root`, not a `cd(APP_ROOT)` wrapper (#857): the keys stay short from any working directory.
        _load_configs() = PormG.Configuration.load_many(DB_DIRS; root = APP_ROOT, env = "dev")

        _load_configs()                       # precompile: bakes the short key into the image
        PormG.@import_models "../db/models.jl" models

        function __init__()
            INIT_PID[] = Base.Libc.getpid()
            _load_configs()                   # runtime: the image's configuration did not survive
        end

        end
        """)

        # Every value is read AFTER `using`, in the child, so the restored image answers. A `const`
        # computed in the module body would answer for the precompile worker instead — that is
        # exactly what `TempReloadPkg.MODEL_OK` above does, and why it cannot pin this.
        script = """
        using Pkg
        cd(ARGS[1])
        ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
        $(_CHILD_SEED_AND_INSTANTIATE)
        pkgid = Base.PkgId(Base.UUID("$(_BOOT_APP_UUID)"), "$(pkg_name)")
        println("BOOT_PRECOMPILED_BEFORE:", Base.isprecompiled(pkgid))
        # Leave the package root before `using`, so neither the precompile worker (it inherits this
        # working directory) nor `__init__` can find `db/` relative to `pwd()`: only `root` can (#857).
        cd(mktempdir())
        using $(pkg_name)
        cfg = $(pkg_name).PormG.config
        println("BOOT_PRECOMPILED_AFTER:", Base.isprecompiled(pkgid))
        println("BOOT_BODY_RAN_ELSEWHERE:", $(pkg_name).BODY_PID != Base.Libc.getpid())
        println("BOOT_INIT_RAN_HERE:", $(pkg_name).INIT_PID[] == Base.Libc.getpid())
        println("BOOT_MODELS_HAS_INIT:", isdefined($(pkg_name).models, :__init__))
        println("BOOT_CONNECT_KEY:", $(pkg_name).models.Lap.connect_key)
        println("BOOT_CONFIG_KEYS:", join(sort(collect(keys(cfg))), ","))
        println("BOOT_APP_ENV:", haskey(cfg, "db") ? cfg["db"].app_env : "<no db key>")
        """

        return _run_child_julia(pkg_root, script)
    end
end

@testset "Manual Model Reload (reload_module_contents!)" begin
    fixture_dir = joinpath(@__DIR__, "db_r")
    mkpath(fixture_dir)
    _write_reload_sqlite_connection(joinpath(fixture_dir, "connection.yml"))

    tmp_model_file = joinpath(fixture_dir, "tmp_reload_models.jl")

    write(tmp_model_file, """
    module reload_models
        import PormG.Models

        ReloadTest = Models.Model(\"reload_test\",
            id = Models.IDField(),
            name = Models.CharField()
        )
    end
    """)

    @info "Importing initial model..."
    PormG.@import_models "db_r/tmp_reload_models.jl" reload_models
    import .reload_models as RM

    # #552: `Utils.ensure_models_init!` injects an `__init__` into the models submodule. It is
    # not observed to run in a restored image, so this pins only that the injection still
    # happens; the boot-pattern testset below is what would notice if it started to fire.
    @test isdefined(RM, :__init__)

    @test isdefined(RM, :ReloadTest)
    @test RM.ReloadTest.name == "reload_test"
    @test haskey(RM.ReloadTest.fields, "name")
    @test !haskey(RM.ReloadTest.fields, "new_field")
    @test basename(RM.ReloadTest.connect_key) == "db_r"

    @info "Modifying model file..."
    sleep(0.5)
    write(tmp_model_file, """
    module reload_models
        import PormG.Models

        ReloadTest = Models.Model(\"reload_test\",
            id = Models.IDField(),
            name = Models.CharField(),
            new_field = Models.IntegerField(default=10)
        )
    end
    """)
    sleep(0.5)

    if isdefined(Main, :Revise)
        @info "Triggering Revise.revise()..."
        Revise.revise()
    end

    if !haskey(RM.ReloadTest.fields, "new_field")
        @warn "Revise did not pick up file change, using manual reload_module_contents! fallback"
        PormG.Utils.reload_module_contents!(RM, tmp_model_file)
        PormG.Models.set_models(RM, dirname(tmp_model_file))
    end

    @test haskey(RM.ReloadTest.fields, "new_field")
    @test RM.ReloadTest.fields["new_field"].default == 10
    @test haskey(RM.ReloadTest.fields, "name")
    @test basename(RM.ReloadTest.connect_key) == "db_r"

    rm(tmp_model_file)
end

@testset "@import_models Package Regression" begin
    ok, output, timed_out = _run_import_models_package_regression()
    output = replace(output, "\r\n" => "\n")

    @test !timed_out
    @test ok
    @test occursin("SUBPROCESS_OK:true", output)
    # #1060: the child ran at the parent's resolved versions. Discriminating only where the two
    # would differ (CI's floor-resolve job); on a newest-version parent both sides agree anyway.
    @test occursin("MANIFEST_SEEDED:true\n", output)
    @test occursin("MANIFEST_DRIFT:\n", output)
    @test !occursin("Evaluation into the closed module", output)
    @test !occursin("UndefVarError: `sch_models` not defined", output)
    @test !occursin("world prior to its definition world", output)
    @test !occursin("waiting for IO to finish", output)
end

# ─────────────────────────────────────────────────────────────────────────────
# Boot pattern: the documented body-plus-__init__ recipe survives precompilation (#552)
# docs/src/configuration/advanced.md promises that loading configuration in the module body AND
# in `__init__`, with `@import_models` between them, leaves a model bound to the SHORT key with the
# application's own environment. That holds only because the `__init__` `@import_models` injects
# into the models submodule is not run when the image is restored; if it ever were, it would fire
# before the parent's `__init__` with `config` still empty, and `set_models` would implicit-load —
# absolute key, environment from PORMG_ENV/`default_env:` — the #550 incident, silently. Nothing
# guarded that promise. This runs the recipe in a scratch package, precompiles it, and reads the
# answer back from a fresh process.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Documented boot pattern survives precompilation (#552)" begin
    ok, output, timed_out = _run_boot_pattern_regression()
    output = replace(output, "\r\n" => "\n")

    @test !timed_out
    @test ok
    @test occursin("MANIFEST_SEEDED:true\n", output)
    @test occursin("MANIFEST_DRIFT:\n", output)

    # The image was really restored here: the body ran in the precompile worker (a different pid),
    # `__init__` ran in this process, and the cache exists afterwards. Without these three a green
    # run could be the module body executing in-process, which is not what the docs promise.
    @test occursin("BOOT_PRECOMPILED_AFTER:true\n", output)
    @test occursin("BOOT_BODY_RAN_ELSEWHERE:true\n", output)
    @test occursin("BOOT_INIT_RAN_HERE:true\n", output)

    # The injection still happens. It is inert today; this is loud if a Julia release changes that.
    @test occursin("BOOT_MODELS_HAS_INIT:true\n", output)

    # The short key, not the absolute path the implicit load would mint. The trailing newline is
    # load-bearing: an absolute path ending in `db` must not satisfy this.
    @test occursin("BOOT_CONNECT_KEY:db\n", output)
    @test occursin("BOOT_CONFIG_KEYS:db\n", output)

    # The application's environment. `test` would mean the parent's PORMG_ENV leaked through the
    # implicit load; `staging` would mean the file's `default_env:` did.
    @test occursin("BOOT_APP_ENV:dev\n", output)
    @test !occursin("BOOT_APP_ENV:test", output)
    @test !occursin("BOOT_APP_ENV:staging", output)

    # Second witness. If the submodule `__init__` ever fired first, the parent's `__init__` would
    # then MIGRATE the implicit entry to "db"/dev, so the key and env markers above would still
    # read right — only `connect_key` (a plain field, no self-heal on read) would betray it. The
    # implicit load also warns, and that warning is in the merged transcript.
    @test !occursin("loaded implicitly", output)
end
