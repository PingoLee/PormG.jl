using Test
using PormG
import Logging

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

# ── #365: connection.yml unrecognised config keys + typo suggestions ──────────────────────────
# An unrecognised key in a `config:` block must emit a structured `@warn` naming the key and the
# environment. Plausible typos receive a `did_you_mean` nearest candidate; distant garbage does not.
# Internal `Settings` fields (app_env, db_def_folder, etc.) are excluded from the allowlist.
@testset "unrecognised config keys emit warnings with suggestions (#365)" begin
    @testset "typo in config key suggests nearest valid key" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            open(joinpath(db_dir, "connection.yml"), "w") do f
                write(f,
                    "dev:\n" *
                    "  adapter: SQLite\n" *
                    "  database: \":memory:\"\n" *
                    "  config:\n" *
                    "    change_data: true\n" *
                    "    djago_prefix: dash\n" *
                    "    chnge_db: true\n" *
                    "    timezone: 'UTC'\n"
                )
            end

            logs, _ = Test.collect_test_logs() do
                PormG.Configuration.load(db_dir; env="dev")
            end

            warns = filter(l -> l.level == Logging.Warn && occursin("unrecognised config key", l.message), logs)
            @test length(warns) == 3

            warn_map = Dict(String(Dict(w.kwargs)[:key]) => Dict(w.kwargs) for w in warns)
            @test haskey(warn_map, "djago_prefix")
            @test warn_map["djago_prefix"][:env] == "dev"
            @test warn_map["djago_prefix"][:did_you_mean] == "django_prefix"

            @test haskey(warn_map, "chnge_db")
            @test warn_map["chnge_db"][:env] == "dev"
            @test warn_map["chnge_db"][:did_you_mean] == "change_db"

            @test haskey(warn_map, "timezone")
            @test warn_map["timezone"][:env] == "dev"
            @test warn_map["timezone"][:did_you_mean] == "time_zone"

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "garbage key emits warning without did_you_mean" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            open(joinpath(db_dir, "connection.yml"), "w") do f
                write(f,
                    "dev:\n" *
                    "  adapter: SQLite\n" *
                    "  database: \":memory:\"\n" *
                    "  config:\n" *
                    "    completely_unknown_key: 123\n"
                )
            end

            logs, _ = Test.collect_test_logs() do
                PormG.Configuration.load(db_dir; env="dev")
            end

            warns = filter(l -> l.level == Logging.Warn && occursin("unrecognised config key", l.message), logs)
            @test length(warns) == 1
            w = first(warns)
            kw = Dict(w.kwargs)
            @test kw[:key] == "completely_unknown_key"
            @test kw[:env] == "dev"
            @test !haskey(kw, :did_you_mean)

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "internal Settings fields cannot be set from config: and are warned" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            open(joinpath(db_dir, "connection.yml"), "w") do f
                write(f,
                    "dev:\n" *
                    "  adapter: SQLite\n" *
                    "  database: \":memory:\"\n" *
                    "  config:\n" *
                    "    app_env: hacked_env\n" *
                    "    db_def_folder: /tmp/fake\n" *
                    "    connections: null\n"
                )
            end

            logs, _ = Test.collect_test_logs() do
                PormG.Configuration.load(db_dir; env="dev")
            end

            warns = filter(l -> l.level == Logging.Warn && occursin("unrecognised config key", l.message), logs)
            @test length(warns) == 3

            s = PormG.Configuration.get_settings(db_dir)
            @test s.app_env == "dev"
            @test s.db_def_folder == db_dir
            @test s.connections !== nothing

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "all valid config: keys are accepted with no warning" begin
        mktempdir() do temp_root
            db_dir = joinpath(temp_root, "db"); mkpath(db_dir)
            open(joinpath(db_dir, "connection.yml"), "w") do f
                write(f,
                    "dev:\n" *
                    "  adapter: SQLite\n" *
                    "  database: \":memory:\"\n" *
                    "  config:\n" *
                    "    change_db: true\n" *
                    "    change_data: true\n" *
                    "    django_prefix: myapp\n" *
                    "    time_zone: 'America/Sao_Paulo'\n" *
                    "    log_queries: false\n" *
                    "    log_level: 'warn'\n" *
                    "    log_to_file: false\n" *
                    "    model_file: 'custom_models.jl'\n"
                )
            end

            logs, _ = Test.collect_test_logs() do
                PormG.Configuration.load(db_dir; env="dev")
            end

            unrec_warns = filter(l -> l.level == Logging.Warn && occursin("unrecognised config key", l.message), logs)
            @test isempty(unrec_warns)

            s = PormG.Configuration.get_settings(db_dir)
            @test s.change_db == true
            @test s.change_data == true
            @test s.django_prefix == "myapp"
            @test s.time_zone == "America/Sao_Paulo"
            @test s.log_queries == false
            @test s.log_level == Logging.Warn
            @test s.log_to_file == false
            @test s.model_file == "custom_models.jl"

            _cleanup_configuration_test_keys([db_dir])
        end
    end
end

# ── #348: unrecognised connection.yml keys outside the `config:` block ────────────────────────
# #365 covered `config:`; every key directly under an environment block was still dropped in
# silence. `user:` (libpq's spelling of `username:`) is the flagship case — libpq then falls back
# to the OS user and the failure surfaces as an unrelated auth error. Misplacement between the two
# levels gets its own message, because writing `change_data:` at the environment level was
# previously documented as expected behaviour.

# One filter for the whole warning family — every message carries the prefix on purpose, so the
# "a valid file emits none of them" guard below cannot be fooled by a reworded message.
_yml_warns(logs) = filter(l -> l.level == Logging.Warn && occursin("connection.yml:", l.message), logs)

# Index the records (not just their kwargs) by `key=`, so a case can assert on the message too.
_by_key(warns) = Dict(String(Dict(w.kwargs)[:key]) => w
                      for w in warns if haskey(Dict(w.kwargs), :key))

_kw(record) = Dict(record.kwargs)

function _write_348_yml(db_dir::String, body::String)
    mkpath(db_dir)
    open(joinpath(db_dir, "connection.yml"), "w") do f
        write(f, body)
    end
    return db_dir
end

function _load_348(db_dir::String)
    logs, _ = Test.collect_test_logs() do
        PormG.Configuration.load(db_dir; env="dev")
    end
    return _yml_warns(logs)
end

@testset "unrecognised connection.yml keys emit warnings (#348)" begin

    @testset "other tools' spellings resolve through the alias table" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  user: pormg_user\n" *
                "  pool: 10\n")

            warns = _load_348(db_dir)
            by_key = _by_key(warns)

            @test length(warns) == 2

            @test haskey(by_key, "user")
            @test _kw(by_key["user"])[:env] == "dev"
            @test _kw(by_key["user"])[:did_you_mean] == "username"
            @test occursin("unrecognised connection key", by_key["user"].message)

            # The mutation gate for "the alias table is consulted BEFORE `_suggest_name`":
            # `_levenshtein("pool", "port") == 2` and `2*2 <= 4`, so edit distance alone resolves
            # `pool:` to `port` — telling the user to rename their pool setting to a TCP port.
            @test haskey(by_key, "pool")
            @test _kw(by_key["pool"])[:did_you_mean] == "pool_size"
            @test _kw(by_key["pool"])[:did_you_mean] != "port"

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "a real typo still resolves by edit distance" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  sslmod: require\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test _kw(warns[1])[:did_you_mean] == "sslmode"

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "an invented key warns without a suggestion" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  completely_unknown_setting: 1\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test occursin("unrecognised connection key", warns[1].message)
            @test !haskey(_kw(warns[1]), :did_you_mean)

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "a config: key at the environment level says where it belongs" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  change_data: true\n" *
                "  timezone: 'America/Sao_Paulo'\n")

            warns = _load_348(db_dir)
            by_key = _by_key(warns)

            @test length(warns) == 2
            for w in warns
                @test occursin("belongs under the environment's `config:` block", w.message)
            end

            # Exact member of VALID_CONFIG_KEYS: misplaced, not misspelled.
            @test _kw(by_key["change_data"])[:move_to] == "config"
            @test !haskey(_kw(by_key["change_data"]), :did_you_mean)

            # Misplaced *and* misspelled: the config-key fallback fires only after the environment
            # block's own vocabulary comes up empty.
            @test _kw(by_key["timezone"])[:move_to] == "config"
            @test _kw(by_key["timezone"])[:did_you_mean] == "time_zone"

            # The setting really was discarded — this is the claim the docs used to make.
            @test PormG.Configuration.get_settings(db_dir).change_data == false

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "an environment key under config: says where it belongs" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  config:\n" *
                "    change_data: true\n" *
                "    pool_size: 10\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test occursin("belongs directly under the environment block", warns[1].message)
            @test _kw(warns[1])[:key] == "pool_size"
            @test _kw(warns[1])[:move_to] == "environment"
            @test _kw(warns[1])[:env] == "dev"

            # This direction must NOT fall back to `_suggest_name`, so a misplaced key is never
            # also reported as an unrecognised one.
            @test isempty(filter(l -> occursin("unrecognised config key", l.message), warns))

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "settings outside any environment block are reported" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "adapter: SQLite\n" *
                "defaultenv: dev\n" *
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n")

            warns = _load_348(db_dir)
            by_key = _by_key(warns)

            @test length(warns) == 2

            @test occursin("outside any environment block", by_key["adapter"].message)
            @test _kw(by_key["adapter"])[:move_to] == "environment"

            @test occursin("unrecognised top-level key", by_key["defaultenv"].message)
            @test _kw(by_key["defaultenv"])[:did_you_mean] == "default_env"

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "an empty environment block is not mistaken for a stray key" begin
        mktempdir() do temp_root
            # `prod:` with no body parses to `nothing`, not a Dict — it is a block, just an empty
            # one, and flagging it would fire on ordinary multi-environment files.
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "default_env: dev\n" *
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "prod:\n")

            @test isempty(_load_348(db_dir))

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "options: block is validated against its one supported key" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  options:\n" *
                "    sqlite_split_read_write: true\n")

            @test isempty(_load_348(db_dir))
            _cleanup_configuration_test_keys([db_dir])
        end

        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  options:\n" *
                "    foo: 1\n" *
                "    pool_size: 10\n")

            warns = _load_348(db_dir)
            by_key = _by_key(warns)

            @test length(warns) == 2
            @test occursin("unrecognised `options:` key", by_key["foo"].message)
            @test occursin("does not belong under `options:`", by_key["pool_size"].message)
            @test _kw(by_key["pool_size"])[:move_to] == "environment"

            _cleanup_configuration_test_keys([db_dir])
        end

        # A `config:` setting nested under `options:` must be sent to `config:`, not to the
        # environment block — which would only earn it a second warning telling it to move again.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  options:\n" *
                "    change_data: true\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test _kw(warns[1])[:key] == "change_data"
            @test _kw(warns[1])[:move_to] == "config"

            _cleanup_configuration_test_keys([db_dir])
        end

        # `options:` that is not a mapping was replaced by an empty Dict in silence — the same
        # asymmetry `config:` used to have.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  options: nope\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test occursin("`options:` must be a block of settings", warns[1].message)

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "url: is reported as inert on SQLite" begin
        # `url:` is read only by the PostgreSQL branch. Under SQLite it was dropped and the pool
        # fell back to an in-memory database that vanishes at exit — the #348 failure exactly.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  url: 'sqlite:///data.db'\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test occursin("`url:` is ignored on SQLite", warns[1].message)
            @test _kw(warns[1])[:env] == "dev"

            # The silent fallback the warning is about.
            @test PormG.Configuration.get_settings(db_dir).connections.connection_string == ":memory:"

            _cleanup_configuration_test_keys([db_dir])
        end

        # …and it stays quiet on PostgreSQL, where `url:` IS honoured. This is the discriminating
        # half: without it, deleting the `adapter == "SQLite"` guard leaves the suite green while
        # every legitimate PostgreSQL `url:` config starts warning.
        #
        # `read_db_connection_data` emits the warning without building a pool, so this needs no
        # live PostgreSQL — `load` would try to construct one.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: PostgreSQL\n" *
                "  url: 'postgres://user@host/db'\n")

            settings = PormG.Configuration.Settings(app_env="dev", db_def_folder=db_dir)
            logs, _ = Test.collect_test_logs() do
                PormG.Configuration.read_db_connection_data(db_dir, settings)
            end
            @test isempty(_yml_warns(logs))
        end

        # A blank `url:` is "not set", on either adapter.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  url: ''\n" *
                "  database: 'real.sqlite'\n")

            @test isempty(_load_348(db_dir))
            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "a blank url: does not discard the PostgreSQL credentials beside it" begin
        # `url: ''` used to satisfy the pool builder's `!== nothing` gate, producing an EMPTY DSN:
        # every credential in the block was dropped and libpq fell back to PGHOST/PGUSER or the
        # local socket as the OS user — the flagship #348 failure, from a config that looks
        # complete. The validator and the pool builder must agree on what "unset" means.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: PostgreSQL\n" *
                "  url: ''\n" *
                "  host: 127.0.0.1\n" *
                "  port: 5499\n" *
                "  database: pormg_348\n" *
                "  username: pormg_user\n" *
                "  password: pormg_pass\n")

            settings = PormG.Configuration.Settings(app_env="dev", db_def_folder=db_dir)
            settings.db_config_settings =
                PormG.Configuration.read_db_connection_data(db_dir, settings)

            # Build only the DSN, not a connection: assert on what the pool would be handed.
            PormG.Configuration._build_connection_pool!(settings, db_dir)
            dsn = settings.connections.connection_string

            @test !isempty(dsn)
            @test occursin("dbname=pormg_348", dsn)
            @test occursin("user=pormg_user", dsn)
            @test occursin("host=127.0.0.1", dsn)

            PormG.Configuration.close_pool!(settings.connections)
        end
    end

    @testset "a config: block that is not a mapping is reported, not skipped" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  config: true\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test occursin("`config:` must be a block of settings", warns[1].message)
            @test _kw(warns[1])[:env] == "dev"

            @test PormG.Configuration.get_settings(db_dir).change_data == false

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "log_level: values" begin
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  config:\n" *
                "    log_level: 'verbose'\n")

            warns = _load_348(db_dir)

            @test length(warns) == 1
            @test occursin("unrecognised `log_level:` value", warns[1].message)
            @test PormG.Configuration.get_settings(db_dir).log_level == Logging.Debug

            _cleanup_configuration_test_keys([db_dir])
        end

        # Substring matching is deliberate and must survive the Dict -> ordered-tuple change.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  config:\n" *
                "    log_level: 'warning'\n")

            @test isempty(_load_348(db_dir))
            @test PormG.Configuration.get_settings(db_dir).log_level == Logging.Warn

            _cleanup_configuration_test_keys([db_dir])
        end

        # A value containing two level names must resolve deterministically: the matcher walks
        # LOG_LEVEL_NAMES in order and stops at the FIRST hit. The `Dict` + no-`break` loop this
        # replaced took the LAST match in an unspecified iteration order.
        #
        # `info_warn` is the value that discriminates. It must be `Info` (first in declared order);
        # last-match-wins yields `Warn`. A value like `debug_or_error` proves nothing — it happens
        # to come back `Debug` under both.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n" *
                "  config:\n" *
                "    log_level: 'info_warn'\n")

            @test isempty(_load_348(db_dir))
            @test PormG.Configuration.get_settings(db_dir).log_level == Logging.Info

            _cleanup_configuration_test_keys([db_dir])
        end

        # Order-independent statement of the same contract, so a reordering of the tuple is caught
        # even where a two-name value happens to agree.
        @test first(PormG.Configuration.LOG_LEVEL_NAMES)[1] == "debug"
        @test [n for (n, _) in PormG.Configuration.LOG_LEVEL_NAMES] ==
              ["debug", "info", "warn", "error"]
    end

    @testset "the legacy env: key keeps its own warning and gains no second one" begin
        # `env:` is inert (#205) and already warns with a migration nudge. The file-level scan must
        # skip it, or every stale config — including the repo's own db_2/db_sl fixtures — would
        # also be told `env` is an unrecognised top-level key.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "env: dev\n" *
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  database: \":memory:\"\n")

            logs, _ = Test.collect_test_logs() do
                PormG.Configuration.load(db_dir; env="dev")
            end

            @test isempty(filter(l -> occursin("unrecognised top-level key", l.message),
                                 _yml_warns(logs)))
            # The #205 warning itself must survive.
            @test !isempty(filter(l -> l.level == Logging.Warn &&
                                       occursin("legacy top-level `env:` key", l.message), logs))

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "an unusable environment block fails loudly" begin
        # Missing `adapter:` used to reach `_build_connection_pool!` and raise a bare
        # KeyError("adapter") several frames from the file that lacked it.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  database: \":memory:\"\n")

            err = try
                PormG.Configuration.load(db_dir; env="dev"); nothing
            catch e
                e
            end
            @test err isa PormG.InvalidConfigurationError
            @test occursin("dev", sprint(showerror, err))
            @test occursin("adapter", sprint(showerror, err))

            _cleanup_configuration_test_keys([db_dir])
        end

        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "dev:\n" *
                "  adapter: '  '\n" *
                "  database: \":memory:\"\n")

            # Assert the message, not just the type: a blank adapter reaches
            # `_build_connection_pool!` and raises InvalidConfigurationError("Unsupported adapter:")
            # on its own, so a bare @test_throws stays green with this guard deleted.
            err = try
                PormG.Configuration.load(db_dir; env="dev"); nothing
            catch e
                e
            end
            @test err isa PormG.InvalidConfigurationError
            @test occursin("has no `adapter:`", sprint(showerror, err))

            _cleanup_configuration_test_keys([db_dir])
        end

        # An environment name whose value is a scalar used to die with a raw MethodError from
        # `haskey(::String, ::String)`.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"), "dev: somestring\n")

            logs, _ = Test.collect_test_logs() do
                try
                    PormG.Configuration.load(db_dir; env="dev")
                catch
                end
            end

            err = try
                PormG.Configuration.load(db_dir; env="dev"); nothing
            catch e
                e
            end
            @test err isa PormG.InvalidConfigurationError
            @test occursin("not a block of settings", sprint(showerror, err))

            # …and it must not ALSO be reported as an unknown top-level key. `dev` is a recognised
            # environment name; the file-level scan cannot tell a malformed block from a stray
            # setting, so it defers to the precise error above for the active environment.
            @test isempty(filter(l -> occursin("unrecognised top-level key", l.message),
                                 _yml_warns(logs)))

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "a fully valid file emits no key warnings at all" begin
        # The false-positive guard: every member of VALID_CONNECTION_KEYS and VALID_CONFIG_KEYS in
        # one file. The PostgreSQL-only keys are inert under `adapter: SQLite` — they are read only
        # in the PG branch of `_build_connection_pool!` — which is what lets one file cover both.
        mktempdir() do temp_root
            db_dir = _write_348_yml(joinpath(temp_root, "db"),
                "default_env: dev\n" *
                "dev:\n" *
                "  adapter: SQLite\n" *
                "  url: ''\n" *
                "  database: \":memory:\"\n" *
                "  host: 'pormg348.sqlite'\n" *
                "  hostaddr: ''\n" *
                "  port: 5432\n" *
                "  username: pormg_user\n" *
                "  password: pormg_pass\n" *
                "  passfile: ''\n" *
                "  connect_timeout: 5\n" *
                "  client_encoding: UTF8\n" *
                "  sslmode: prefer\n" *
                "  sslrootcert: ''\n" *
                "  sslcert: ''\n" *
                "  sslkey: ''\n" *
                "  pool_size: 2\n" *
                "  pool_timeout: 30\n" *
                "  idle_timeout: 0\n" *
                "  max_lifetime: 0\n" *
                "  leak_detection_threshold: 0\n" *
                "  fail_fast_on_connect: true\n" *
                "  sqlite_split_read_write: false\n" *
                "  extensions: []\n" *
                "  options:\n" *
                "    sqlite_split_read_write: false\n" *
                "  config:\n" *
                "    change_db: true\n" *
                "    change_data: true\n" *
                "    django_prefix: myapp\n" *
                "    time_zone: 'UTC'\n" *
                "    log_queries: false\n" *
                "    log_level: 'warn'\n" *
                "    log_to_file: false\n" *
                "    model_file: 'custom_models.jl'\n")

            @test isempty(_load_348(db_dir))

            # The guard only means something if the file it approves also still loads correctly.
            s = PormG.Configuration.get_settings(db_dir)
            @test s.change_data == true
            @test s.django_prefix == "myapp"
            @test s.log_level == Logging.Warn

            _cleanup_configuration_test_keys([db_dir])
        end
    end

    @testset "the allowlists and the alias table stay self-consistent" begin
        conn = Set(PormG.Configuration.VALID_CONNECTION_KEYS)

        # `config:` and `options:` are the nested blocks; both must be allowlisted or the loader
        # would warn about the very keys it reads.
        @test "config" in conn
        @test "options" in conn
        @test issubset(Set(PormG.Configuration.VALID_OPTION_KEYS), conn)

        # The two levels are disjoint vocabularies — an overlap would make the misplacement
        # branches unreachable and ambiguous.
        @test isempty(intersect(conn, Set(PormG.Configuration.VALID_CONFIG_KEYS)))

        # Every alias must point at a key the loader actually reads, and must not shadow one.
        for (alias, target) in PormG.Configuration.CONNECTION_KEY_ALIASES
            @test target in conn
            @test !(alias in conn)
            @test alias == lowercase(alias)   # looked up case-folded
        end
    end

    @testset "register_connection is not touched by the yaml validators" begin
        mktempdir() do temp_root
            key = "pormg_348_dynamic"
            logs, _ = Test.collect_test_logs() do
                PormG.Configuration.register_connection(key, joinpath(temp_root, "dyn.sqlite");
                                                        adapter="SQLite")
            end
            @test isempty(_yml_warns(logs))
            PormG.Configuration.unregister_connection(key)
        end
    end

    @testset "validators are callable directly, without a file" begin
        logs, _ = Test.collect_test_logs() do
            PormG.Configuration._warn_unknown_env_keys(
                Dict("adapter" => "SQLite", "user" => "x", "pool" => 3), "dev")
        end
        warns = _yml_warns(logs)
        by_key = _by_key(warns)

        @test length(warns) == 2
        @test _kw(by_key["user"])[:did_you_mean] == "username"
        @test _kw(by_key["pool"])[:did_you_mean] == "pool_size"
    end

    @testset "every allowlisted key is documented" begin
        # The allowlist is now the specification of what `connection.yml` accepts, so a key added
        # to it without a line in the docs is a key users cannot discover. Before #348 this had
        # already happened to `url`, `sqlite_split_read_write`, `options`, `hostaddr`, `passfile`,
        # `connect_timeout`, `client_encoding` and all four `ssl*` keys — none appeared anywhere
        # in `docs/`.
        docs_dir = normpath(joinpath(@__DIR__, "..", "..", "docs", "src", "configuration"))
        @test isdir(docs_dir)

        # `.md` is not pinned to LF in `.gitattributes`, so a Windows checkout yields CRLF (#216).
        corpus = join([replace(read(joinpath(root, f), String), "\r\n" => "\n")
                       for (root, _, files) in walkdir(docs_dir)
                       for f in files if endswith(f, ".md")], "\n")

        # A bare `occursin(k, corpus)` would be green theater: "url" matches any hyperlink, "port"
        # matches "important", "options" matches ordinary prose. A `"$k:"` arm is barely better —
        # "port:" is satisfied by "support:". Require the key as a markdown code span, which is how
        # the reference table and every prose mention spell it.
        _documented(k) = occursin("`$k`", corpus)

        # Self-check: the matcher must be able to fail, or the loop below proves nothing. The
        # second decoy is the substring case a looser matcher would wave through.
        @test !_documented("definitely_not_a_real_key")
        @test !_documented("por")

        for k in (PormG.Configuration.VALID_CONNECTION_KEYS...,
                  PormG.Configuration.VALID_CONFIG_KEYS...,
                  PormG.Configuration.VALID_OPTION_KEYS...)
            @test _documented(k)
        end
    end
end
