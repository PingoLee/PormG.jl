using Test
using UUIDs: uuid4
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

function _run_import_models_package_regression()
    pormg_root = normpath(joinpath(@__DIR__, "..", ".."))

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

        open(joinpath(pkg_root, "Project.toml"), "w") do f
            write(f, """
            name = \"$(pkg_name)\"
            uuid = \"$(uuid4())\"
            version = \"0.1.0\"

            [deps]
            PormG = \"7d8d7541-4d3d-4580-80a2-17064efb0993\"
            Revise = \"295af30f-e4ad-537b-8983-00126c2a3abe\"

            [sources]
            PormG = {path = \"$(_toml_escape_string(pormg_root))\"}
            """)
        end

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
        Pkg.instantiate(; update_registry=false)
        using Revise
        using TempReloadPkg
        println(\"SUBPROCESS_OK:\", TempReloadPkg.MODEL_OK)
        """

        cmd = `$(Base.julia_cmd()) --project=$(pkg_root) -e $script $pkg_root`
        output_buffer = PipeBuffer()
        process = run(pipeline(ignorestatus(cmd), stdout=output_buffer, stderr=output_buffer), wait=false)
        wait_status = Base.timedwait(() -> !process_running(process), 300.0)

        if wait_status == :timed_out
            kill(process)
            wait(process)
            return (false, String(take!(output_buffer)), true)
        end

        wait(process)
        return (process.exitcode == 0, String(take!(output_buffer)), false)
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

    @test !timed_out
    @test ok
    @test occursin("SUBPROCESS_OK:true", output)
    @test !occursin("Evaluation into the closed module", output)
    @test !occursin("UndefVarError: `sch_models` not defined", output)
    @test !occursin("world prior to its definition world", output)
    @test !occursin("waiting for IO to finish", output)
end