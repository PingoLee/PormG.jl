# ============================================================
# test/unit/test_driver_internals.jl
#
# Every driver name and field the four extensions read that the driver does not mark as API (#1494).
#
# CONTRACT being tested:
#   A driver release that renames or removes something an extension in `ext/` reads fails THIS file,
#   on CI's main job and on `floor-resolve`, rather than the first statement a user runs. `[compat]`
#   takes each driver by caret (`Postgres = "2.2.2"`, `MySQL = "2"`, …), so Pkg resolves any later
#   minor release on its own, and the integration files that exercise these reads run on no CI job.
#
#   Two kinds of read, pinned two ways:
#   • A qualified name (`LibPQ.libpq_c.PQcancel`). The scan below parses each extension and fails on
#     one that is neither `public` in its driver nor pinned here, so the list cannot fall behind the
#     code; it fails on a pin the code no longer reads as well, so it cannot rot either.
#   • A field (`conn.statement_cache_maxsize`). Julia has no `public` for a field, and the source does
#     not say a value's type, so no scan can find these: they are the hand audit of #1494, pinned with
#     `fieldnames`. A new field read in `ext/` gets a row here by review.
#
#   `status` records the #1494 classification. `:documented` is a name the driver's own docs describe
#   that it marks neither `export` nor `public` — Julia cannot tell it from an internal one, so it is
#   pinned all the same. `:internal` is everything else: a C binding, a generated SQLSTATE class, an
#   undocumented field. No extension falls back at run time when one disappears (decided on #1494):
#   a fallback would hide the driver change the extension should be reviewed against.
#
# Hermetic: the drivers are loaded, nothing connects.
# ============================================================

using Test
using PormG
using InteractiveUtils: subtypes

include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _DRIVER_MODULES = Dict{Symbol,Module}(:Postgres => Postgres, :LibPQ => LibPQ, :SQLite => SQLite,
                                            :MySQL => MySQL)
const _EXTENSION_DRIVERS = ("PormGPostgresExt" => :Postgres, "PormGLibPQExt" => :LibPQ,
                            "PormGSQLiteExt" => :SQLite, "PormGMySQLExt" => :MySQL)

const _NamePin = @NamedTuple{name::String, status::Symbol, reader::String}
const _FieldPin = @NamedTuple{type::Type, fields::Vector{Symbol}, status::Symbol, reader::String}

# ── Qualified names neither exported nor `public` in their driver ───────────────────────────────────
# Postgres.jl declares `public` for every name its extension reads, so it has no row: the scan checks
# those through `Base.ispublic`.
const PINNED_NAMES = _NamePin[
  # LibPQ.jl
  (name = "LibPQ.Connection",                   status = :documented, reader = "PormG.backend_execute, backend_is_alive, backend_cancel_query!, …"),
  (name = "LibPQ.Result",                       status = :documented, reader = "_raise_if_failed, _server_named_failure, _copy_completed"),
  (name = "LibPQ.AsyncResult",                  status = :documented, reader = "_CheckedAsyncResult"),
  (name = "LibPQ.CopyIn",                       status = :documented, reader = "PormG.backend_copy_in!"),
  (name = "LibPQ.ConnectionOption",             status = :documented, reader = "_preflight_conninfo"),
  (name = "LibPQ.conninfo",                     status = :documented, reader = "_preflight_conninfo (its `Ptr` method: PINNED_METHODS)"),
  (name = "LibPQ.error_field",                  status = :internal,   reader = "_raise_if_failed, _server_named_failure"),
  (name = "LibPQ.lock",                         status = :internal,   reader = "PormG.backend_is_alive, _drain_postgres_connection! (`Base.lock`: PINNED_METHODS)"),
  (name = "LibPQ.Errors.LibPQException",        status = :documented, reader = "PormG.backend_classify_error, backend_is_retry_safe"),
  (name = "LibPQ.Errors.JLResultError",         status = :documented, reader = "PormG.backend_copy_in!"),
  (name = "LibPQ.Errors.JLConnectionError",     status = :documented, reader = "PormG.backend_is_connection_error"),
  (name = "LibPQ.Errors.PQConnectionError",     status = :documented, reader = "PormG.backend_classify_error, backend_is_retry_safe, backend_copy_in!, _drain_postgres_connection!"),
  (name = "LibPQ.Errors.PQResultError",         status = :documented, reader = "PormG.backend_classify_error, backend_error_fields, backend_is_connection_error, _raise_if_failed"),
  (name = "LibPQ.Errors.error_class",           status = :internal,   reader = "PormG.backend_classify_error"),
  (name = "LibPQ.Errors.error_code",            status = :internal,   reader = "PormG.backend_error_fields"),
  (name = "LibPQ.Errors.UnknownError",          status = :internal,   reader = "PormG.backend_is_connection_error"),
  (name = "LibPQ.Errors.QueryCanceled",         status = :internal,   reader = "PormG.backend_is_cancellation"),
  (name = "LibPQ.Errors.CUN",                   status = :internal,   reader = "PormG.backend_error_fields, backend_is_connection_error, _result_error_fields"),
  (name = "LibPQ.Errors.C08",                   status = :internal,   reader = "_PG_OPERATIONAL_CLASSES (PormG.backend_classify_error)"),
  (name = "LibPQ.Errors.C23",                   status = :internal,   reader = "PormG.backend_classify_error"),
  (name = "LibPQ.Errors.C40",                   status = :internal,   reader = "_PG_OPERATIONAL_CLASSES (PormG.backend_classify_error)"),
  (name = "LibPQ.Errors.C53",                   status = :internal,   reader = "_PG_OPERATIONAL_CLASSES (PormG.backend_classify_error)"),
  (name = "LibPQ.Errors.C55",                   status = :internal,   reader = "_PG_OPERATIONAL_CLASSES (PormG.backend_classify_error)"),
  (name = "LibPQ.Errors.C57",                   status = :internal,   reader = "_PG_OPERATIONAL_CLASSES (PormG.backend_classify_error)"),
  (name = "LibPQ.Errors.AdminShutdown",         status = :internal,   reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.CannotConnectNow",      status = :internal,   reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.ConnectionDoesNotExist", status = :internal,  reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.ConnectionException",   status = :internal,   reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.ConnectionFailure",     status = :internal,   reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.CrashShutdown",         status = :internal,   reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.IdleSessionTimeout",    status = :internal,   reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.SqlclientUnableToEstablishSqlconnection",       status = :internal, reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.Errors.SqlserverRejectedEstablishmentOfSqlconnection", status = :internal, reader = "_PG_LOST_CONNECTION_ERRORS (PormG.backend_is_connection_error)"),
  (name = "LibPQ.libpq_c.CONNECTION_OK",        status = :internal,   reader = "PormG.backend_is_alive, backend_copy_in!"),
  (name = "LibPQ.libpq_c.PGRES_BAD_RESPONSE",   status = :internal,   reader = "_FAILED_RESULT_STATUSES (_raise_if_failed)"),
  (name = "LibPQ.libpq_c.PGRES_FATAL_ERROR",    status = :internal,   reader = "_FAILED_RESULT_STATUSES (_raise_if_failed)"),
  (name = "LibPQ.libpq_c.PGRES_COMMAND_OK",     status = :internal,   reader = "_copy_completed"),
  (name = "LibPQ.libpq_c.PG_DIAG_SQLSTATE",     status = :internal,   reader = "_server_named_failure"),
  (name = "LibPQ.libpq_c.PG_DIAG_MESSAGE_PRIMARY", status = :internal, reader = "_result_error_fields"),
  (name = "LibPQ.libpq_c.PG_DIAG_TABLE_NAME",   status = :internal,   reader = "_result_error_fields"),
  (name = "LibPQ.libpq_c.PG_DIAG_COLUMN_NAME",  status = :internal,   reader = "_result_error_fields"),
  (name = "LibPQ.libpq_c.PG_DIAG_CONSTRAINT_NAME", status = :internal, reader = "_result_error_fields"),
  (name = "LibPQ.libpq_c.PQcancel",             status = :internal,   reader = "PormG.backend_cancel_query!"),
  (name = "LibPQ.libpq_c.PQgetCancel",          status = :internal,   reader = "PormG.backend_cancel_query!"),
  (name = "LibPQ.libpq_c.PQfreeCancel",         status = :internal,   reader = "PormG.backend_cancel_query!"),
  (name = "LibPQ.libpq_c.PQconsumeInput",       status = :internal,   reader = "PormG.backend_is_alive, _drain_postgres_connection!"),
  (name = "LibPQ.libpq_c.PQisBusy",             status = :internal,   reader = "_drain_postgres_connection!"),
  (name = "LibPQ.libpq_c.PQgetResult",          status = :internal,   reader = "_drain_postgres_connection!"),
  (name = "LibPQ.libpq_c.PQclear",              status = :internal,   reader = "_drain_postgres_connection!"),
  (name = "LibPQ.libpq_c.PQcmdStatus",          status = :internal,   reader = "_copy_completed"),
  (name = "LibPQ.libpq_c.PQconninfoParse",      status = :internal,   reader = "_preflight_conninfo"),
  (name = "LibPQ.libpq_c.PQconninfoFree",       status = :internal,   reader = "_preflight_conninfo"),
  (name = "LibPQ.libpq_c.PQfreemem",            status = :internal,   reader = "_preflight_conninfo"),
  # SQLite.jl
  (name = "SQLite.DB",                          status = :documented, reader = "PormG.backend_execute, _create_sqlite_connection, …"),
  (name = "SQLite.Stmt",                        status = :documented, reader = "_sqlite_execute_materialized"),
  (name = "SQLite.execute",                     status = :documented, reader = "PormG.backend_is_alive, _create_sqlite_connection"),
  (name = "SQLite.register",                    status = :documented, reader = "_create_sqlite_connection"),
  (name = "SQLite.C.sqlite3_interrupt",         status = :internal,   reader = "PormG.backend_cancel_query!"),
  (name = "SQLite.C.sqlite3_libversion_number", status = :internal,   reader = "PormG.backend_sqlite_version"),
  # MySQL.jl
  (name = "MySQL.Connection",                   status = :documented, reader = "PormG.backend_execute, _open_connection, _run, …"),
  (name = "MySQL.connection_id",                status = :documented, reader = "PormG.backend_cancel_query!"),
  (name = "MySQL.ping",                         status = :documented, reader = "PormG.backend_drain_connection!"),
  (name = "MySQL.server_kind",                  status = :documented, reader = "_check_server"),
  (name = "MySQL.server_version",               status = :documented, reader = "_check_server"),
  (name = "MySQL.DataBytes",                    status = :documented, reader = "_read_value"),
  (name = "MySQL.DataString",                   status = :documented, reader = "_read_value"),
  (name = "MySQL.DataDecimals.AbstractDecimal", status = :internal,   reader = "_read_value"),
  (name = "MySQL.MySQLError",                   status = :documented, reader = "PormG.backend_classify_error"),
  (name = "MySQL.Protocol.ServerError",         status = :documented, reader = "PormG.backend_classify_error, backend_error_fields, _run, _is_lost_connection, …"),
  (name = "MySQL.Protocol.AuthError",           status = :documented, reader = "PormG.backend_classify_error, backend_is_permanent_connect_error"),
  (name = "MySQL.Protocol.UnsupportedAuthError", status = :documented, reader = "PormG.backend_classify_error, backend_is_permanent_connect_error"),
  (name = "MySQL.Protocol.TLSNegotiationError", status = :documented, reader = "PormG.backend_classify_error"),
  (name = "MySQL.Protocol.ProtocolError",       status = :documented, reader = "_is_lost_connection"),
  (name = "MySQL.Protocol.TimeoutError",        status = :documented, reader = "_is_lost_connection"),
  (name = "MySQL.Protocol.Limits",              status = :documented, reader = "PormG.backend_mysql_parameter_limit"),
]

# ── Fields — the hand audit; no scan can see these ─────────────────────────────────────────────────
const PINNED_FIELDS = _FieldPin[
  # Postgres.jl. #1479 (PR #1489) reads the first two on every statement: a rename turns each one
  # into a `FieldError`. `statement_cache_maxsize` is documented as a connection keyword, not a field.
  (type = Postgres.Connection, fields = [:statement_cache_maxsize, :server_in_transaction, :lock],
   status = :internal, reader = "_execute"),
  # Named by the DSN preflight; `_URL_AT_OK_FIELDS` and `_CONNECT_TIME_VALUES` name the last five by
  # field, so a rename would refuse (or stop refusing) a string by accident. The fields mirror the
  # documented keywords, but the struct documents only its keyword constructor.
  (type = Postgres.ConnectionParams, fields = [:host, :options, :reconnect, :gssencmode, :sslmode, :user,
                                               :password, :application_name],
   status = :internal, reader = "_checked_params, _with_session_options"),
  (type = Postgres.Error, fields = [:code, :message, :table, :column, :constraint], status = :documented,
   reader = "PormG.backend_classify_error, backend_error_fields, _is_lost_connection, …"),
  (type = Postgres.Error, fields = [:routine], status = :internal, reader = "_is_stale_cached_statement"),
  (type = Postgres.PostgresInterfaceError, fields = [:msg], status = :internal,
   reader = "_is_lost_connection, PormG.backend_is_retry_safe"),
  # LibPQ.jl
  (type = LibPQ.Connection, fields = [:conn], status = :internal,
   reader = "PormG.backend_is_alive, backend_cancel_query!, _drain_postgres_connection!"),
  (type = LibPQ.Result, fields = [:result], status = :internal, reader = "_copy_completed"),
  (type = LibPQ.ConnectionOption, fields = [:keyword, :val], status = :internal, reader = "_preflight_conninfo"),
  (type = LibPQ.Errors.PQConnectionError, fields = [:msg], status = :internal, reader = "PormG.backend_is_retry_safe"),
  (type = LibPQ.Errors.PQResultError, fields = [:msg], status = :internal, reader = "PormG.backend_error_fields"),
  # SQLite.jl
  (type = SQLite.DB, fields = [:handle, :lock], status = :internal, reader = "PormG.backend_cancel_query!, _release_leaked_db_lock!"),
  (type = SQLite.SQLiteException, fields = [:msg], status = :internal,
   reader = "PormG.backend_classify_error, backend_error_fields"),
  # MySQL.jl. `_ok_info` returns "" when the cursor has no `ok` field; the pin is what keeps that
  # branch from hiding a rename.
  (type = MySQL.Cursor, fields = [:rows_affected], status = :documented, reader = "_materialize"),
  (type = MySQL.Cursor, fields = [:ok], status = :internal, reader = "_ok_info"),
  (type = MySQL.Protocol.OKPacket, fields = [:info], status = :internal, reader = "_ok_info"),
  (type = MySQL.Statement, fields = [:columns], status = :internal, reader = "_run"),
  (type = MySQL.Protocol.ColumnDef, fields = [:charset, :type], status = :internal, reader = "_is_binary_column"),
  (type = MySQL.Protocol.Limits, fields = [:max_columns], status = :documented,
   reader = "PormG.backend_mysql_parameter_limit"),
]

# ── Methods — where the name alone proves nothing ──────────────────────────────────────────────────
# `LibPQ.lock` IS `Base.lock` (LibPQ adds a method), and `conninfo` is documented only for its
# `Connection` and `String` methods, so `isdefined` would stay green with the method PormG calls gone.
# Every pinned name that resolves to a Base or Core function must have a row here (checked below).
const _MethodPin = @NamedTuple{f::Any, sig::Type, status::Symbol, reader::String}
const PINNED_METHODS = _MethodPin[
  (f = Base.lock, sig = Tuple{LibPQ.Connection}, status = :internal,
   reader = "PormG.backend_is_alive, _drain_postgres_connection! (through `lock(f, conn)`)"),
  (f = Base.unlock, sig = Tuple{LibPQ.Connection}, status = :internal,
   reader = "PormG.backend_is_alive, _drain_postgres_connection! (through `lock(f, conn)`)"),
  (f = LibPQ.conninfo, sig = Tuple{Ptr{LibPQ.libpq_c.PQconninfoOption}}, status = :internal,
   reader = "_preflight_conninfo, on every LibPQ connect"),
  (f = LibPQ.Errors.PQConnectionError, sig = Tuple{LibPQ.Connection}, status = :internal,
   reader = "_drain_postgres_connection!"),
]

# ── The socket layer under Postgres.jl and MySQL.jl ────────────────────────────────────────────────
# Both extensions' `_is_lost_connection` recognise a dead socket from Reseau, the drivers' transport,
# without depending on it: `NetClosingError` by its type's NAME, and the wrapped failure through
# `hasproperty(e, :err)` (`OpError`) and `hasproperty(e, :cause)` (`TLSError`). A rename there would
# not raise: a lost connection would quietly stop being renewed. So the names are pinned here,
# against the Reseau the drivers load.
const _RESEAU = Base.PkgId(Base.UUID("802f3686-a58f-41ce-bb0c-3c43c75bba36"), "Reseau")
const RESEAU_PINS = (
  (path = (:IOPoll, :NetClosingError), fields = Symbol[]),
  (path = (:HostResolvers, :OpError), fields = [:err]),
  (path = (:TLS, :TLSError), fields = [:cause]),
)

# ── The drivers' own text ──────────────────────────────────────────────────────────────────────────
# Each extension matches its driver's message for a connection the driver already closed, as a
# prefix (`_CLOSED_CONNECTION_PREFIX`, reader `_is_lost_connection`). The driver's source must still
# say it, or a closed connection stops being renewed.
const DRIVER_TEXT_PINS = (
  (ext = :PormGPostgresExt, driver = :Postgres),
  (ext = :PormGMySQLExt, driver = :MySQL),
)

# `ServerError` is abstract, and the extension reads `errno`, `sqlstate` and `msg` off whichever
# concrete error arrives, so every subtype must carry them.
const SERVER_ERROR_FIELDS = (:errno, :sqlstate, :msg)

# ── The scan ────────────────────────────────────────────────────────────────────────────────────────
# `A.B.C` as ["A", "B", "C"], or nothing when the expression is not a plain qualified name.
function _qualified_chain(ex)::Union{Nothing,Vector{String}}
  ex isa Symbol && return [String(ex)]
  if ex isa Expr && ex.head === :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
    head = _qualified_chain(ex.args[1])
    head === nothing && return nothing
    return push!(head, String(ex.args[2].value))
  end
  return nothing
end

function _collect_driver_refs!(out::Set{String}, ex, driver::String)
  ex isa Expr || return out
  if ex.head === :.
    chain = _qualified_chain(ex)
    if chain !== nothing && length(chain) > 1 && first(chain) == driver
      push!(out, join(chain, "."))
      return out
    end
  elseif ex.head in (:import, :using)
    # `import MySQL: DBInterface` names `MySQL.DBInterface` as surely as the dotted form does.
    for arg in ex.args
      arg isa Expr && arg.head === :(:) || continue
      from = String.(arg.args[1].args)   # the `import` path, `Expr(:., :MySQL)`, as its segments
      (isempty(from) || first(from) != driver) && continue
      for item in arg.args[2:end]
        push!(out, join(vcat(from, String.(item.args)), "."))
      end
    end
    return out
  end
  foreach(a -> _collect_driver_refs!(out, a, driver), ex.args)
  return out
end

# Comments and strings are not in the parse tree, so prose such as "Postgres.jl" never counts.
_driver_refs(src::String, driver::Symbol)::Set{String} =
  _collect_driver_refs!(Set{String}(), Meta.parseall(src), String(driver))

# Resolve `Driver.A.B` step by step: `(defined, public)`, public only when every step is.
function _resolve(name::String)::@NamedTuple{defined::Bool, public::Bool}
  parts = Symbol.(split(name, "."))
  m = _DRIVER_MODULES[first(parts)]
  public = true
  for p in parts[2:end]
    (m isa Module && isdefined(m, p)) || return (defined = false, public = false)
    public &= Base.ispublic(m, p)
    m = getfield(m, p)
  end
  return (defined = true, public = public)
end

const _PINNED_NAME_SET = Set(p.name for p in PINNED_NAMES)

# ─────────────────────────────────────────────────────────────────────────────
# The three reads #1479 added to every Postgres.jl statement, stated as the issue states them, apart
# from the table below so a failure names the one PR #1489 depends on. `clear_statement_cache!` is
# `public`, so the scan covers it too; the two fields only this file can see.
# Expected: all three present on every Postgres.jl in `[compat]` (2.2.2 through 2.4.0 today).
# Why: a 2.x that renames one fails every statement with a `FieldError`, and the integration test that
# exercises them runs on no CI job.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: the Postgres.jl statement-cache reads of #1479 exist" begin
  @test :statement_cache_maxsize in fieldnames(Postgres.Connection)
  @test :server_in_transaction in fieldnames(Postgres.Connection)
  @test isdefined(Postgres, :clear_statement_cache!)
end

# ─────────────────────────────────────────────────────────────────────────────
# Every pinned name still resolves in its driver, and every pinned field is still on its type.
# Expected: no missing name, no missing field (the failure message names the pin and its reader).
# Why: this is the rename check itself; the scan below only keeps the list complete.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: every pinned driver name and field still exists" begin
  @test allunique(p.name for p in PINNED_NAMES)
  @test all(p -> p.status in (:documented, :internal), PINNED_NAMES)
  for p in PINNED_NAMES
    @test _resolve(p.name).defined || error("$(p.name) is gone from its driver; read by $(p.reader)")
  end
  for p in PINNED_FIELDS, f in p.fields
    @test f in fieldnames(p.type) || error("$(p.type).$(f) is gone from its driver; read by $(p.reader)")
  end
  concrete = subtypes(MySQL.Protocol.ServerError)
  @test !isempty(concrete)
  for T in concrete, f in SERVER_ERROR_FIELDS
    @test f in fieldnames(T) || error("$(T).$(f) is gone; read by PormG.backend_classify_error, backend_error_fields")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `_with_session_options` rebuilds a `Postgres.ConnectionParams` positionally from its own fields
# (`fieldnames` in order, `options` replaced), which needs the default positional constructor.
# Expected: a method taking exactly the field types.
# Why: an inner constructor added upstream would make every Postgres.jl connect a `MethodError`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: Postgres.ConnectionParams keeps its positional constructor" begin
  @test hasmethod(Postgres.ConnectionParams, Tuple{fieldtypes(Postgres.ConnectionParams)...})
end

# ─────────────────────────────────────────────────────────────────────────────
# The methods PormG calls where the name is not the driver's own (`LibPQ.lock === Base.lock`) or
# where only other methods of it are documented (`LibPQ.conninfo`).
# Expected: each signature has a method; and no pinned name resolves to a Base/Core function that
# lacks a method pin, since `isdefined` on it proves nothing about the driver.
# Why: LibPQ dropping `lock(::Connection)` would leave `LibPQ.lock` defined while
#      `backend_is_alive` raised a `MethodError` (review of #1494).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: the driver methods PormG calls exist, not only their names" begin
  for p in PINNED_METHODS
    @test hasmethod(p.f, p.sig) || error("$(p.f)($(p.sig)) is gone; read by $(p.reader)")
  end
  method_pinned = Set{Any}(p.f for p in PINNED_METHODS)
  for p in PINNED_NAMES
    parts = Symbol.(split(p.name, "."))
    v = foldl(getfield, parts[2:end]; init = _DRIVER_MODULES[first(parts)])
    v isa Function && parentmodule(v) in (Base, Core) || continue
    @test v in method_pinned || error("$(p.name) is $(parentmodule(v)).$(nameof(v)): pin its method in PINNED_METHODS")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Reseau, the transport under Postgres.jl and MySQL.jl, by the names `_is_lost_connection` matches.
# Expected: `IOPoll.NetClosingError` exists, `HostResolvers.OpError` has `err`, `TLS.TLSError` has
# `cause`. Why: those reads are by name and by `hasproperty`, so a rename would never raise — lost
# connections would just stop being renewed, and no other test sees the real types.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: the socket-layer names _is_lost_connection matches still exist" begin
  reseau = get(Base.loaded_modules, _RESEAU, nothing)
  @test reseau isa Module
  for p in RESEAU_PINS
    m = reseau
    for s in p.path
      @test isdefined(m, s) || error("Reseau.$(join(p.path, ".")) is gone; read by _is_lost_connection")
      m = getfield(m, s)
    end
    for f in p.fields
      @test f in fieldnames(m) || error("Reseau.$(join(p.path, ".")).$(f) is gone; read by _is_lost_connection")
    end
  end
  @test nameof(getfield(getfield(reseau, :IOPoll), :NetClosingError)) === :NetClosingError
end

# ─────────────────────────────────────────────────────────────────────────────
# The closed-connection text each extension matches is still in its driver's source.
# Expected: `_CLOSED_CONNECTION_PREFIX` of PormGPostgresExt found under Postgres.jl's `src/`, and
# PormGMySQLExt's under MySQL.jl's. Why: the match is on the driver's own wording; reworded upstream,
# a closed connection is classified `:unknown` and never renewed, silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: the driver text the extensions match is still the driver's" begin
  for p in DRIVER_TEXT_PINS
    prefix = Base.get_extension(PormG, p.ext)._CLOSED_CONNECTION_PREFIX
    src_dir = joinpath(pkgdir(_DRIVER_MODULES[p.driver]), "src")
    found = any(walkdir(src_dir)) do (dir, _, files)
      any(f -> endswith(f, ".jl") && occursin(prefix, read(joinpath(dir, f), String)), files)
    end
    @test found || error("$(p.driver).jl no longer says \"$(prefix)\"; matched by $(p.ext)._is_lost_connection")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Each extension, parsed: every qualified driver name it reads is `public` in the driver or pinned
# above, and every pin is still read by some extension.
# Expected: no unpinned non-public name, no stale pin.
# Why: without it a new internal read lands unpinned, and the pin list rots as reads go away.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: every non-public driver name an extension reads is pinned" begin
  ext_dir = joinpath(pkgdir(PormG), "ext")
  seen = Set{String}()
  for (file, driver) in _EXTENSION_DRIVERS
    refs = _driver_refs(read(joinpath(ext_dir, file * ".jl"), String), driver)
    @test !isempty(refs)
    union!(seen, refs)
    for r in sort!(collect(refs))
      res = _resolve(r)
      @test res.defined || error("$(file) reads $(r), which its driver does not define")
      @test res.public || r in _PINNED_NAME_SET ||
        error("$(file) reads $(r), which is not public in its driver: pin it in PINNED_NAMES")
    end
  end
  for p in PINNED_NAMES
    @test p.name in seen || error("$(p.name) is pinned but no extension reads it: drop the pin")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The scanner on a known snippet: a qualified name in code, in an `import … :` list, nested inside a
# call, and the same text in a comment and a string.
# Expected: the three code references, nothing from the comment or the string.
# Why: a scanner that misses a form passes the guard above vacuously; one that reads prose would
#      demand pins for "Postgres.jl" in every comment.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1494: the scan reads code, never comments or strings" begin
  snippet = """
  import Postgres: DBInterface
  # Postgres.from_a_comment
  f(conn) = Postgres.Inner.read_me(conn.field) * "Postgres.from_a_string"
  g(x) = x isa Postgres.SomeError
  """
  @test _driver_refs(snippet, :Postgres) ==
        Set(["Postgres.DBInterface", "Postgres.Inner.read_me", "Postgres.SomeError"])
  @test isempty(_driver_refs(snippet, :LibPQ))
  @test !_resolve("Postgres.no_such_name_1494").defined
end
