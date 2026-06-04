using Test
using PormG

if !haskey(ENV, "PORMG_ENV")
    ENV["PORMG_ENV"] = "test"
end

function _write_configuration_test_connection(path::String)
    open(path, "w") do f
        write(f,
            "dev:\n" *
            "  adapter: SQLite\n" *
            "  database: \":memory:\"\n" *
            "  config:\n" *
            "    change_db: false\n" *
            "    change_data: false\n" *
            "test:\n" *
            "  adapter: SQLite\n" *
            "  database: \":memory:\"\n" *
            "  config:\n" *
            "    change_db: true\n" *
            "    change_data: true\n"
        )
    end
end

function _cleanup_configuration_test_keys(keys::Vector{String})
    for key in keys
        try
            PormG.Configuration.close_pool!(key)
        catch
        end
        pop!(PormG.config, key, nothing)
    end
    return nothing
end

@testset "configured extensions normalize YAML values" begin
    settings = PormG.Configuration.Settings()
    settings.db_config_settings = Dict{String, Any}("extensions" => ["unaccent", " UnAccent ", ""])
    @test PormG.Configuration._configured_extensions(settings) == ["unaccent"]

    settings.db_config_settings = Dict{String, Any}("extensions" => "unaccent")
    @test PormG.Configuration._configured_extensions(settings) == ["unaccent"]

    settings.db_config_settings = Dict{String, Any}("extensions" => Dict("name" => "unaccent"))
    @test_throws ArgumentError PormG.Configuration._configured_extensions(settings)
end

@testset "Explicit env reload keeps Settings synchronized" begin
    mktempdir() do temp_root
        db_dir = joinpath(temp_root, "db")
        mkpath(db_dir)
        _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))

        # First load under one environment.
        PormG.Configuration.load(db_dir; env="dev")
        dev_settings = PormG.Configuration.get_settings(db_dir)
        @test dev_settings.app_env == "dev"
        @test dev_settings.change_db == false
        @test dev_settings.change_data == false

        # Reload under a different environment and verify that the Settings object
        # reflects the new environment instead of keeping stale values.
        PormG.Configuration.load(db_dir; env="test")
        test_settings = PormG.Configuration.get_settings(db_dir)
        @test test_settings.app_env == "test"
        @test test_settings.change_db == true
        @test test_settings.change_data == true

        _cleanup_configuration_test_keys([db_dir])
    end
end

@testset "load_many and is_loaded support multi-folder bootstrap" begin
    mktempdir() do temp_root
        db_dir = joinpath(temp_root, "db")
        db_sch_dir = joinpath(temp_root, "db_sch")
        mkpath(db_dir)
        mkpath(db_sch_dir)
        _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))
        _write_configuration_test_connection(joinpath(db_sch_dir, "connection.yml"))

        # This mirrors the server use case: choose a set of static folders once
        # and let PormG bootstrap them under the selected environment.
        loaded = PormG.Configuration.load_many([db_dir, db_sch_dir]; env="test")
        @test loaded == [db_dir, db_sch_dir]

        @test PormG.Configuration.is_loaded(db_dir)
        @test PormG.Configuration.is_loaded(abspath(db_sch_dir))
        @test !PormG.Configuration.is_loaded(joinpath(temp_root, "missing_db"))

        _cleanup_configuration_test_keys([db_dir, db_sch_dir])
    end
end

@testset "ping and status distinguish loaded from reachable" begin
    mktempdir() do temp_root
        db_dir = joinpath(temp_root, "db")
        mkpath(db_dir)
        _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))

        # An unloaded key should report a clean negative status instead of throwing.
        missing = PormG.Configuration.status(joinpath(temp_root, "not_loaded"))
        @test missing.loaded == false
        @test missing.reachable == false
        @test missing.adapter === nothing

        # A loaded SQLite in-memory configuration should be reachable.
        PormG.Configuration.load(db_dir; env="test")
        @test PormG.Configuration.ping(db_dir)

        loaded = PormG.Configuration.status(db_dir)
        @test loaded.loaded == true
        @test loaded.reachable == true
        @test loaded.adapter == "SQLite"
        @test loaded.app_env == "test"
        @test loaded.dynamic == false

        _cleanup_configuration_test_keys([db_dir])
    end
end

@testset "before_connect hook runs when registered" begin
    previous_hook = PormG.Configuration._BEFORE_CONNECT_HOOK[]
    hook_calls = Ref(0)

    try
        PormG.Configuration.set_before_connect_hook() do key, settings
            hook_calls[] += 1
            @test key !== ""
            return true
        end

        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db")
            mkpath(db_dir)
            _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))

            PormG.Configuration.load(db_dir; env="test")
            @test PormG.Configuration.ping(db_dir)
            @test hook_calls[] >= 1

            _cleanup_configuration_test_keys([db_dir])
        end
    finally
        PormG.Configuration._BEFORE_CONNECT_HOOK[] = previous_hook
    end
end

@testset "before_connect hook can block connections" begin
    previous_hook = PormG.Configuration._BEFORE_CONNECT_HOOK[]

    try
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db")
            mkpath(db_dir)
            _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))

            PormG.Configuration._BEFORE_CONNECT_HOOK[] = nothing
            PormG.Configuration.load(db_dir; env="test")
            @test PormG.Configuration.ping(db_dir)

            PormG.Configuration.close_pool!(db_dir)
            PormG.Configuration.set_before_connect_hook((key, settings) -> false)
            @test PormG.Configuration.ping(db_dir) == false

            _cleanup_configuration_test_keys([db_dir])
        end
    finally
        PormG.Configuration._BEFORE_CONNECT_HOOK[] = previous_hook
    end
end

@testset "before_connect hook runs before reconnect" begin
    previous_hook = PormG.Configuration._BEFORE_CONNECT_HOOK[]
    hook_calls = Ref(0)

    try
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db")
            mkpath(db_dir)
            _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))

            PormG.Configuration._BEFORE_CONNECT_HOOK[] = nothing
            PormG.Configuration.load(db_dir; env="test")
            pool = PormG.Configuration.get_settings(db_dir).connections
            conn = PormG.ConnectionPool.acquire_connection(pool; mode=:read)

            PormG.Configuration.set_before_connect_hook() do key, settings
                hook_calls[] += 1
                @test key == db_dir
                return true
            end

            new_conn = PormG.ConnectionPool.reconnect_db(pool, conn)
            @test new_conn !== nothing
            @test hook_calls[] == 1

            PormG.ConnectionPool.release_connection(pool, new_conn)
            _cleanup_configuration_test_keys([db_dir])
        end
    finally
        PormG.Configuration._BEFORE_CONNECT_HOOK[] = previous_hook
    end
end

@testset "before_connect hook can block reconnect" begin
    previous_hook = PormG.Configuration._BEFORE_CONNECT_HOOK[]

    try
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db")
            mkpath(db_dir)
            _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))

            PormG.Configuration._BEFORE_CONNECT_HOOK[] = nothing
            PormG.Configuration.load(db_dir; env="test")
            pool = PormG.Configuration.get_settings(db_dir).connections
            conn = PormG.ConnectionPool.acquire_connection(pool; mode=:read)

            PormG.Configuration.set_before_connect_hook((key, settings) -> false)
            @test_throws ErrorException PormG.ConnectionPool.reconnect_db(pool, conn)

            _cleanup_configuration_test_keys([db_dir])
        end
    finally
        PormG.Configuration._BEFORE_CONNECT_HOOK[] = previous_hook
    end
end
