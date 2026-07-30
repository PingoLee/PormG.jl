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
    @test_throws PormG.InvalidConfigurationError PormG.Configuration._configured_extensions(settings)
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
            # #268 audit: a hook refusing the connection is a connect-time failure — typed
            # PoolConnectError so `catch PoolError` covers it (this is the Nitro extension seam).
            err = @test_throws PormG.PoolConnectError PormG.ConnectionPool.reconnect_db(pool, conn)
            @test err.value isa PormG.PoolError
            @test occursin("before_connect hook", PormG.error_message(err.value))

            _cleanup_configuration_test_keys([db_dir])
        end
    finally
        PormG.Configuration._BEFORE_CONNECT_HOOK[] = previous_hook
    end
end

# Config-wiring for idle-reaping / max-lifetime (#125): pins that the two user entry points —
# `connection.yml` top-level keys and `register_connection` kwargs — actually reach
# `ConnectionPool.enable_reaping!` and register the pool. DB-free: pools construct lazily (no
# connection is opened here), so we assert on the registry, never on live reaping.
@testset "reaping config wiring reaches enable_reaping! (#125)" begin
    _reap = PormG.ConnectionPool._POOL_MONITOR

    # (1) connection.yml path via _build_connection_pool!: top-level idle_timeout/max_lifetime keys.
    mktempdir() do temp_root
        db_dir = joinpath(temp_root, "db")
        mkpath(db_dir)
        open(joinpath(db_dir, "connection.yml"), "w") do f
            write(f,
                "test:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  idle_timeout: 45\n" *
                "  max_lifetime: 900\n" *
                "  config:\n" *
                "    change_db: true\n" *
                "    change_data: true\n")
        end

        PormG.Configuration.load(db_dir; env="test")
        pool = PormG.Configuration.get_settings(db_dir).connections
        st = get(_reap, pool, nothing)
        @test st !== nothing                       # yaml keys opted the pool in
        @test st.config.idle_timeout == 45.0
        @test st.config.max_lifetime == 900.0
        @test PormG.ConnectionPool._MONITOR_ANY[]     # global flag flipped on

        delete!(_reap, pool)
        _cleanup_configuration_test_keys([db_dir])
    end

    # (2) register_connection kwargs opt the dynamic pool in.
    key_on = "reap_on_$(getpid())"
    try
        PormG.Configuration.register_connection(key_on, ":memory:";
            adapter="SQLite", idle_timeout=60, max_lifetime=1800)
        pool = PormG.config[key_on].connections
        st = get(_reap, pool, nothing)
        @test st !== nothing
        @test st.config.idle_timeout == 60.0 && st.config.max_lifetime == 1800.0
        delete!(_reap, pool)
    finally
        _cleanup_configuration_test_keys([key_on])
    end

    # (3) no reaping kwargs / keys → the pool is NOT registered (default off).
    key_off = "reap_off_$(getpid())"
    try
        PormG.Configuration.register_connection(key_off, ":memory:"; adapter="SQLite")
        pool = PormG.config[key_off].connections
        @test !haskey(_reap, pool)                 # absent = zero behavior change
    finally
        _cleanup_configuration_test_keys([key_off])
    end
end

# Config-wiring for the acquire timeout (#126): both user entry points — `connection.yml pool_timeout`
# and `register_connection(...; pool_timeout=…)` — set the pool's `pool_timeout` field (the default that
# `acquire_connection` reads). DB-free: pools construct lazily, so assert the field directly.
@testset "pool_timeout config wiring sets the pool default (#126)" begin
    # Anchor the centralized default (#179): any future change to the const is a deliberate, visible edit.
    @test PormG.DEFAULT_POOL_TIMEOUT == 30.0

    # (1) connection.yml path via _build_connection_pool!.
    mktempdir() do temp_root
        db_dir = joinpath(temp_root, "db")
        mkpath(db_dir)
        open(joinpath(db_dir, "connection.yml"), "w") do f
            write(f,
                "test:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  pool_timeout: 7\n" *
                "  config:\n" *
                "    change_db: true\n" *
                "    change_data: true\n")
        end

        PormG.Configuration.load(db_dir; env="test")
        pool = PormG.Configuration.get_settings(db_dir).connections
        @test pool.pool_timeout == 7.0             # yaml key set the pool default
        _cleanup_configuration_test_keys([db_dir])
    end

    # (2) register_connection kwarg sets the dynamic pool's default.
    key_set = "ptimeout_set_$(getpid())"
    try
        PormG.Configuration.register_connection(key_set, ":memory:"; adapter="SQLite", pool_timeout=8)
        @test PormG.config[key_set].connections.pool_timeout == 8.0
    finally
        _cleanup_configuration_test_keys([key_set])
    end

    # (3) absent key → the historical 30 s default (back-compat).
    key_def = "ptimeout_def_$(getpid())"
    try
        PormG.Configuration.register_connection(key_def, ":memory:"; adapter="SQLite")
        @test PormG.config[key_def].connections.pool_timeout == PormG.DEFAULT_POOL_TIMEOUT
    finally
        _cleanup_configuration_test_keys([key_def])
    end

    # (4) a <= 0 value falls back to the 30 s default (footgun guard).
    key_neg = "ptimeout_neg_$(getpid())"
    try
        PormG.Configuration.register_connection(key_neg, ":memory:"; adapter="SQLite", pool_timeout=-1)
        @test PormG.config[key_neg].connections.pool_timeout == PormG.DEFAULT_POOL_TIMEOUT
    finally
        _cleanup_configuration_test_keys([key_neg])
    end
end

# Config-wiring for connect fast-fail (#72): both user entry points — `connection.yml fail_fast_on_connect`
# and `register_connection(...; fail_fast_on_connect=…)` — set the pool's `fail_fast_on_connect` field
# (read by `acquire_connection` to decide whether to fast-fail a permanent connect error). DB-free.
@testset "fail_fast_on_connect config wiring sets the pool default (#72)" begin
    # (1) connection.yml false overrides the on-by-default.
    mktempdir() do temp_root
        db_dir = joinpath(temp_root, "db")
        mkpath(db_dir)
        open(joinpath(db_dir, "connection.yml"), "w") do f
            write(f,
                "test:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  fail_fast_on_connect: false\n" *
                "  config:\n" *
                "    change_db: true\n" *
                "    change_data: true\n")
        end

        PormG.Configuration.load(db_dir; env="test")
        pool = PormG.Configuration.get_settings(db_dir).connections
        @test pool.fail_fast_on_connect == false      # yaml key flipped the default off
        _cleanup_configuration_test_keys([db_dir])
    end

    # (2) register_connection kwarg sets the dynamic pool's flag.
    key_off = "ffc_off_$(getpid())"
    try
        PormG.Configuration.register_connection(key_off, ":memory:"; adapter="SQLite", fail_fast_on_connect=false)
        @test PormG.config[key_off].connections.fail_fast_on_connect == false
    finally
        _cleanup_configuration_test_keys([key_off])
    end

    # (3) absent key → on by default (the new, better behavior; zero-config).
    key_def = "ffc_def_$(getpid())"
    try
        PormG.Configuration.register_connection(key_def, ":memory:"; adapter="SQLite")
        @test PormG.config[key_def].connections.fail_fast_on_connect == true
    finally
        _cleanup_configuration_test_keys([key_def])
    end
end

# Config-wiring for leak detection (#127): both entry points reach `enable_leak_detection!`, which
# registers a PoolMonitorState carrying the leak_threshold. DB-free: assert on the shared registry.
@testset "leak_detection_threshold config wiring (#127)" begin
    _mon = PormG.ConnectionPool._POOL_MONITOR

    # (1) connection.yml path via _build_connection_pool!.
    mktempdir() do temp_root
        db_dir = joinpath(temp_root, "db")
        mkpath(db_dir)
        open(joinpath(db_dir, "connection.yml"), "w") do f
            write(f,
                "test:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  leak_detection_threshold: 12\n" *
                "  config:\n" *
                "    change_db: true\n" *
                "    change_data: true\n")
        end
        PormG.Configuration.load(db_dir; env="test")
        pool = PormG.Configuration.get_settings(db_dir).connections
        st = get(_mon, pool, nothing)
        @test st !== nothing
        @test st.leak_threshold == 12.0
        @test PormG.ConnectionPool._MONITOR_ANY[]
        delete!(_mon, pool)
        _cleanup_configuration_test_keys([db_dir])
    end

    # (2) register_connection kwarg opts the dynamic pool in.
    key_on = "leak_on_$(getpid())"
    try
        PormG.Configuration.register_connection(key_on, ":memory:"; adapter="SQLite", leak_detection_threshold=20)
        pool = PormG.config[key_on].connections
        st = get(_mon, pool, nothing)
        @test st !== nothing && st.leak_threshold == 20.0
        delete!(_mon, pool)
    finally
        _cleanup_configuration_test_keys([key_on])
    end

    # (3) absent / 0 → not registered (default off).
    key_off = "leak_off_$(getpid())"
    try
        PormG.Configuration.register_connection(key_off, ":memory:"; adapter="SQLite")
        @test !haskey(_mon, PormG.config[key_off].connections)
    finally
        _cleanup_configuration_test_keys([key_off])
    end
end

# ── #205: connection.yml env selection + fail-loud load ────────────────────────────────────────
# Pins the config-loading onboarding fixes: `default_env:` is honored as the lowest-priority
# environment selector, the legacy `env:` key is inert but warns, `load` throws (rather than
# silently scaffolding + returning `nothing`) on a missing folder/yml with an opt-in `scaffold=true`,
# and a missing env block reports the available ones. All DB-free (SQLite `:memory:`), isolated via
# `mktempdir` + `_cleanup_configuration_test_keys`.
@testset "config env selection + fail-loud load (#205)" begin
    MDCE = PormG.Configuration.MissingConfigurationError

    # dev (read-only) + prod (writable) blocks, so the selected env is identifiable by change_data.
    _dev_prod_blocks =
        "dev:\n  adapter: SQLite\n  database: \":memory:\"\n  config:\n    change_db: false\n    change_data: false\n" *
        "prod:\n  adapter: SQLite\n  database: \":memory:\"\n  config:\n    change_db: true\n    change_data: true\n"

    @testset "default_env: honored as the lowest-priority default" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            write(joinpath(db_dir, "connection.yml"), "default_env: prod\n" * _dev_prod_blocks)

            # No `env=` and no PORMG_ENV → the file's `default_env: prod` beats the built-in `dev`.
            withenv("PORMG_ENV" => nothing) do
                PormG.Configuration.load(db_dir)
            end
            s = PormG.Configuration.get_settings(db_dir)
            @test s.app_env == "prod"
            @test s.change_data == true

            # An explicit `env=` outranks `default_env:` → back to the dev block.
            withenv("PORMG_ENV" => nothing) do
                PormG.Configuration.load(db_dir; env="dev")
            end
            s2 = PormG.Configuration.get_settings(db_dir)
            @test s2.app_env == "dev"
            @test s2.change_data == false

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "PORMG_ENV outranks default_env:" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            write(joinpath(db_dir, "connection.yml"), "default_env: prod\n" * _dev_prod_blocks)

            # The middle precedence rung: ENV["PORMG_ENV"] beats the file's default_env: prod.
            withenv("PORMG_ENV" => "dev") do
                PormG.Configuration.load(db_dir)
            end
            s = PormG.Configuration.get_settings(db_dir)
            @test s.app_env == "dev"
            @test s.change_data == false

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "legacy env: key is inert and warns" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            # A bare `env: prod` must NOT select prod; with no PORMG_ENV/kwarg the env falls to the
            # built-in `dev`, and a one-time deprecation warning fires.
            write(joinpath(db_dir, "connection.yml"), "env: prod\n" * _dev_prod_blocks)

            withenv("PORMG_ENV" => nothing) do
                @test_logs (:warn,) match_mode=:any PormG.Configuration.load(db_dir)
            end
            s = PormG.Configuration.get_settings(db_dir)
            @test s.app_env == "dev"          # bare `env: prod` ignored
            @test s.change_data == false      # dev block

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "load throws on a missing folder/yml (no silent scaffold)" begin
        mktempdir() do temp_root
            missing_dir = joinpath(temp_root, "nope")
            @test_throws MDCE PormG.Configuration.load(missing_dir)
            @test !isdir(missing_dir)                       # nothing scaffolded behind our back

            empty_dir = joinpath(temp_root, "empty"); mkpath(empty_dir)
            @test_throws MDCE PormG.Configuration.load(empty_dir)    # folder exists, no yml

            # Opt-in scaffolding writes a skeleton (with default_env:, no legacy env:) and returns.
            scaffold_dir = joinpath(temp_root, "scaffolded")
            PormG.Configuration.load(scaffold_dir; scaffold=true)
            yml = read(joinpath(scaffold_dir, "connection.yml"), String)
            @test occursin("default_env:", yml)
            @test !occursin(r"^env:"m, yml)                 # no bare legacy key
        end
    end

    @testset "missing env block lists the available blocks" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            _write_configuration_test_connection(joinpath(db_dir, "connection.yml"))  # dev + test

            err = nothing
            try
                PormG.Configuration.load(db_dir; env="staging")
            catch e
                err = e
            end
            @test err isa MDCE
            @test occursin("staging", err.msg)
            @test occursin("dev", err.msg) && occursin("test", err.msg)

            _cleanup_configuration_test_keys([db_dir])
        end
    end
end
