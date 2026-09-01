using Pkg
# The integration suite needs the LibPQ/SQLite driver extensions loaded. The package env cannot
# carry them — they are `[weakdeps]` by design (#34) and `Manifest.toml` is gitignored, so a
# checkout has no installed copy to `Base.require`. `test/integration/Project.toml` is the
# environment that does carry them; it resolves PormG through `[sources]`, so a fresh clone needs
# only `Pkg.instantiate()`.
#
# This used to be an unconditional `Pkg.activate(".")`, which silently discarded whatever the
# caller passed to `--project=` and forced the driver-less package env — making the suite
# unrunnable regardless of how it was invoked. Now the package env and "no project" both redirect
# here, while an explicit third-party environment is left alone.
let _pkg_env = normpath(joinpath(@__DIR__, "..", "..", "Project.toml")),
    _int_env = normpath(joinpath(@__DIR__, "Project.toml")),
    _active  = Base.active_project()

    if _active === nothing || normpath(_active) in (_pkg_env, _int_env)
        Pkg.activate(@__DIR__)
    end
end
ENV["PORMG_ENV"] = "dev"

using Revise
using PormG
# SQL function library (Sum, Count, Lower, Greatest, Floor, Extract, Abs, Concat, …) is
# namespaced under PormG.Functions since #35 (no longer flooded into Main by `using PormG`).
# Bring the whole library into scope so the integration tests can use the bare constructors —
# this models the documented `using PormG, PormG.Functions` pattern (docs/src/api.md).
using PormG.Functions
# Activate the LibPQ/SQLite weakdep extensions (#34) before any DB work — without these
# every backend operation raises the "load the driver" error. Robust across env types;
# see test/load_drivers.jl.
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using DataFrames
using CSV
using Test#, SafeTestsets
using Dates
using JSON
using UUIDs
using Base.Threads: Atomic, atomic_add!

# Optional Infiltrator support — re-wires @pormg_debug to real breakpoints when available.
# Infiltrator is a test-only dep (see [extras] in Project.toml); it is never loaded in production.
if !isinteractive()
    # Non-interactive (CI / Pkg.test): keep @pormg_debug as a no-op — do nothing.
elseif !isnothing(get(ENV, "PORMG_INFILTRATOR", nothing))
    try
        @eval using Infiltrator
        PormG.eval(:(macro pormg_debug(ex); :(Infiltrator.@infiltrate($(esc(ex)))); end))
        @info "Infiltrator loaded — @pormg_debug is live"
    catch e
        @warn "Could not load Infiltrator" exception=e
    end
end

import PormG: with_transaction, Models, Dialect
import PormG.Configuration: with_tx_context, get_tx_connection
import PormG.ConnectionPool: fetch_async, await_result
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, F, page, Max, Min, Value, Round
import PormG.QueryBuilder: quote_identifier, safe_table_identifier, safe_column_identifier, escape_like_pattern

cd(@__DIR__)  # Ensure we're in the test/integration directory

# Select database folder from environment variable, falling back to db_2 (PostgreSQL)
const PORMG_DB_FOLDER = get(ENV, "PORMG_DB", "db_2")

# Load configurations once
PormG.Configuration.load(PORMG_DB_FOLDER)

# #37: the async integration suite (`-t auto`, heavy fan-out) saturates a small PostgreSQL pool
# against a possibly-remote DB. Size the pool to the run's concurrency for this run only
# (env-overridable) and rebuild so the initial slots are pre-sized instead of grown via the
# expansion path. We cannot use `db_2/connection.yml` (git-ignored), so this is the code-level
# equivalent of bumping the pool in the test environment. Keep PORMG_TEST_POOL_SIZE modest:
# with the ×10 ceiling a value of 20 means a max of 200 connections — far above the suite's real
# peak (~20-30) but a high value could exhaust the PostgreSQL server's max_connections.
let s = PormG.config[PORMG_DB_FOLDER]
    if s.connections isa PormG.PormGPostgres
        pool_n = parse(Int, get(ENV, "PORMG_TEST_POOL_SIZE", "20"))
        if pool_n != s.connections.pool_size
            s.db_config_settings["pool_size"] = pool_n
            PormG.Configuration.close_pool!(s.connections)   # close the size-3 pool; config[key] still → s
            PormG.Configuration._build_connection_pool!(s, PORMG_DB_FOLDER)
        end
    end
end

# ── Suite mutual exclusion: one integration run at a time (PORMG_TEST_LOCK) ────────────────────
# The suite is destructive and assumes it is the only writer — it bootstraps schema, clears tables
# and reseeds fixtures. Two runs interleaving those phases on `pormg_teste` produce failures that
# read as real regressions; that is the most expensive diagnostic tax this repo has documented
# (pormg-test-troubleshooting → *False regression from two sessions/worktrees sharing one live
# database*). A PostgreSQL session-level advisory lock makes the second run QUEUE instead.
#
# It lives here, not in runtests.jl, on purpose: all 40 integration entry points include this file
# (`if !isdefined(Main, :PormG) …`), and a single `test_*.jl` run is the normal target per
# AGENTS.md — exactly the case a runtests.jl-only guard would leave unguarded.
#
# Why a dedicated pool instead of `PormG.with_advisory_lock`: that helper is scoped — it takes a
# closure and releases on exit — and a prelude cannot wrap the includes that come after it. The
# lock is pinned to its own 1-slot pool held for the life of the PROCESS instead. It must not ride
# on the suite pool, which hands out a different connection per `fetch`, because a session-level
# lock exists only on the connection that took it.
#
# PostgreSQL releases session-level advisory locks when the connection drops, so a normal exit, a
# Ctrl-C and a hard crash all release it: there is no stale-lock state to reap, ever. That
# self-healing is the reason to prefer this over a lock file or a lock table.
#
# The lock also covers the disposable migration database transitively: a queued session is stopped
# here, before it can reach `db_test_migration_pg` and reset it under the run that is in progress.
#
#   PORMG_TEST_LOCK=0            skip the lock (concurrent runs will interleave; you own the result)
#   PORMG_TEST_LOCK_WAIT=<secs>  how long to queue before giving up (default 900)
#
# SQLite is exempt: `f1.sqlite` is per-worktree (scripts/worktree_setup.sh), and
# `with_advisory_lock` is a documented no-op on `PormGSQLite` anyway. Advisory locks are scoped per
# database (verified on this server), so the key needs no database qualifier; `test_advisorylock.jl`
# keys are UUID-suffixed and cannot collide with it.
const _SUITE_LOCK_KEY  = "pormg::integration-suite"
# Process-lifetime by design: the lock lives on this pool's single connection, so anything that
# closed or dropped it would silently hand the database to a second run mid-suite.
const _SUITE_LOCK_POOL = Ref{Any}(nothing)

"""
    release_suite_lock!()

Drop this session's integration-suite lock early. Only needed in an INTERACTIVE session
(`julia -i … common_setup.jl`), where the process outlives the run and would otherwise hold the
database until you quit. A batch run needs nothing — process exit releases it.
"""
function release_suite_lock!()
  p = _SUITE_LOCK_POOL[]
  p === nothing && return nothing
  try; PormG.Configuration.close_pool!(p); catch; end   # closing the connection IS the release
  _SUITE_LOCK_POOL[] = nothing
  return nothing
end

if get(ENV, "PORMG_TEST_LOCK", "1") ∉ ("0", "false", "off") &&
   PormG.config[PORMG_DB_FOLDER].connections isa PormG.PormGPostgres
  let s = PormG.config[PORMG_DB_FOLDER]
    dbname = string(s.db_config_settings["database"])
    wait_s = parse(Float64, get(ENV, "PORMG_TEST_LOCK_WAIT", "900"))

    cfg = copy(s.db_config_settings)
    cfg["pool_size"] = 1
    delete!(cfg, "url")   # a `url:` entry would win over the discrete params
    lock_settings = PormG.Configuration.Settings(app_env = s.app_env, db_config_settings = cfg)
    PormG.Configuration._build_connection_pool!(lock_settings, "pormg_test::suite_lock")
    lock_pool = lock_settings.connections
    _SUITE_LOCK_POOL[] = lock_pool

    # Label the connection so a WAITING session can say who holds the lock. `application_name` is
    # not in VALID_CONNECTION_KEYS, so it is set on the live connection rather than via the DSN.
    # `set_config` rather than `SET`: the tag embeds PORMG_DB_FOLDER (an env var), and `SET` cannot
    # bind its value — this keeps the house rule that nothing outside the source is interpolated
    # into SQL. `is_local = false` makes it session-scoped, matching the lock's lifetime.
    tag = "pormg-suite:$(PORMG_DB_FOLDER):pid$(getpid())"
    try
      tq = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
      tph = PormG.QueryBuilder.add_parameter!(tq, tag)
      PormG.ConnectionPool.fetch(lock_pool,
        "SELECT set_config('application_name', $(tph), false);"; params=tq)
    catch
    end

    # Parameterized, matching `AdvisoryLock.ADVISORY_KEY_EXPR` so both derive the same bigint from
    # a key string. Built once and reused — `fetch` only reads the bound values.
    kq  = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
    kph = PormG.QueryBuilder.add_parameter!(kq, _SUITE_LOCK_KEY)
    key_expr = "(( 'x' || substr(md5($(kph)), 1, 16))::bit(64))::bigint"

    # Poll rather than block. `pg_advisory_lock` would wait server-side with no progress output and
    # no way to name the holder — a queued session would be indistinguishable from a hung one. Same
    # reason `with_advisory_lock` offers `strategy=:poll`.
    holders() = try
      who = DataFrame(PormG.ConnectionPool.fetch(lock_pool, """
        SELECT string_agg(DISTINCT a.application_name, ', ') AS who
        FROM pg_locks l JOIN pg_stat_activity a USING (pid)
        WHERE l.locktype = 'advisory' AND l.granted
          AND a.pid <> pg_backend_pid()
          AND a.application_name LIKE 'pormg-suite:%';""")).who[1]
      who === missing ? "unknown (another role's backend is not visible to this user)" : who
    catch
      "unknown (pg_stat_activity is restricted for this role)"
    end

    deadline    = time() + wait_s
    last_report = 0.0
    while true
      got = DataFrame(PormG.ConnectionPool.fetch(lock_pool,
              "SELECT pg_try_advisory_lock($(key_expr)) AS ok;"; params=kq)).ok[1]
      got && break

      if time() > deadline
        release_suite_lock!()
        error("Timed out after $(wait_s)s waiting for the integration-suite lock on database " *
              "\"$(dbname)\" — another run is holding it ($(holders())). Wait for it to finish, " *
              "raise PORMG_TEST_LOCK_WAIT, or set PORMG_TEST_LOCK=0 to run anyway (destructive: " *
              "the two runs will interleave schema and fixture phases).")
      end

      if time() - last_report > 30
        @info "Queued — another integration run holds database \"$(dbname)\"" holder=holders() waited_s=round(Int, wait_s - (deadline - time())) giving_up_in_s=round(Int, deadline - time())
        last_report = time()
      end
      sleep(2)
    end
  end
end

# Load the models and expose the alias `M`
# Using the new @import_models macro which handles registration automatically
if PORMG_DB_FOLDER == "db_sl"
    PormG.@import_models "db_sl/models.jl" models
else
    PormG.@import_models "db_2/models.jl" models
end
import .models as M


# Identificar o adapter carregado para o log
adapter_name = haskey(PormG.config, PORMG_DB_FOLDER) ?
               PormG.config[PORMG_DB_FOLDER].db_config_settings["adapter"] :
               "Unknown"

@info "🚀 Starting PormG integration tests" folder = PORMG_DB_FOLDER adapter = adapter_name

# ── Quiet the integration-suite log noise ────────────────────────────────────
# The migration-heavy integration tests emit dozens of *expected* log lines — migration-plan
# progress (@info), the "migration plan has been saved — review before applying" @warn (fires
# once per makemigrations, ~40×/run), "No tables found", empty-DataFrame bulk warnings — that
# bury the actual test results. Route logging through a filter that:
#   • drops @info / @debug (all the migration progress chatter), and
#   • drops the known, high-volume, EXPECTED migration/introspection warnings,
# while keeping @error and any UNEXPECTED @warn so real problems still surface.
#
# Tests that assert on logs install their own logger via `@test_logs` / `with_logger(...)` for
# their own scope, which overrides this global logger — so they are unaffected. Set
# `PORMG_TEST_VERBOSE=1` to keep the full, unfiltered log stream (e.g. when debugging).
import Logging

struct QuietIntegrationLogger <: Logging.AbstractLogger
    sink::Logging.AbstractLogger
end

# Substrings of expected, repetitive warnings the migration-heavy suite emits by the dozens.
const _EXPECTED_LOG_NOISE = (
    "The migration plan has been saved",   # migrations/planner.jl — one per makemigrations
    "No tables found in the database",     # migrations/introspection.jl, importers.jl
    "the DataFrame is empty",              # bulk_insert / bulk_update / bulk_copy empty-DF guards
)

Logging.min_enabled_level(l::QuietIntegrationLogger) = Logging.min_enabled_level(l.sink)
Logging.shouldlog(l::QuietIntegrationLogger, args...) = Logging.shouldlog(l.sink, args...)
Logging.catch_exceptions(l::QuietIntegrationLogger) = Logging.catch_exceptions(l.sink)
function Logging.handle_message(l::QuietIntegrationLogger, level, message, args...; kwargs...)
    # Drop the known expected warnings; @info/@debug are already filtered by the sink's Warn floor.
    if level == Logging.Warn && any(p -> occursin(p, string(message)), _EXPECTED_LOG_NOISE)
        return nothing
    end
    return Logging.handle_message(l.sink, level, message, args...; kwargs...)
end

if get(ENV, "PORMG_TEST_VERBOSE", "0") ∉ ("1", "true")
    # Sink at :Warn drops @info/@debug natively; the wrapper drops the expected-noise warnings.
    Logging.global_logger(QuietIntegrationLogger(Logging.ConsoleLogger(stderr, Logging.Warn)))
end


# $env:PORMG_DB="db_sl"; 
# export PORMG_DB=db_sl
# Sqlite doesn't work well with -t auto, so we can run it without threads for now
# julia -t auto --project=. -i test/integration/common_setup.jl
# julia -t auto --project=. test/integration/test_database_setup.jl
# julia -t auto --project=. test/integration/test_migration_bootstrap.jl
# julia -t auto --project=. test/integration/test_many_to_many.jl
# julia -t auto --project=. test/integration/runtests.jl
# $env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
# 2>&1 | Tee-Object -FilePath "test_sf_out.txt"
#
# Concurrent sessions queue on the per-database advisory lock above — nothing to set, and the
# waiting session logs who holds it every 30s.
#   $env:PORMG_TEST_LOCK_WAIT="1800"   # queue longer than the 900s default
#   $env:PORMG_TEST_LOCK="0"           # opt out (destructive: the runs will interleave)
#   release_suite_lock!()              # interactive sessions only, to free the DB before quitting
