# ==============================================================================
# Backend interface — the seam between core and the SQL-driver extensions.
#
# `LibPQ` and `SQLite` are weak dependencies (see Project.toml `[weakdeps]`). Core
# must never name a concrete driver type (`LibPQ.Connection`, `SQLite.DB`), so every
# operation that touches the driver goes through one of the generic functions below.
# The driver bodies live in `ext/PormGLibPQExt.jl` / `ext/PormGSQLiteExt.jl` and are
# loaded only when the user runs `using LibPQ` / `using SQLite`.
#
# Dispatch is keyed on the pool MARKER type (`PormGPostgres` / `PormGSQLite`), which
# is defined in core. A concrete pool (`PostgresConnectionPool <: PormGPostgres <:
# PormGBackend`) selects the extension method when the driver is loaded; otherwise the
# varargs fallback fires with a friendly "load the driver" error.
#
# Type discipline: core stores connections untyped (`Any`); each extension method
# pins the concrete driver type in its own signature (e.g.
# `backend_execute(::PormGSQLite, ::SQLite.DB, sql, params)`), so the body
# re-specializes fully. The only untyped step is the single dispatch at the call
# boundary, once per DB round-trip — negligible against I/O.
# ==============================================================================

const _PG_DRIVER_HINT = "PormG: the PostgreSQL backend requires LibPQ. Run `using LibPQ` " *
                        "(or `using PormG, LibPQ`) so the PostgreSQL extension loads."
const _SQLITE_DRIVER_HINT = "PormG: the SQLite backend requires SQLite. Run `using SQLite` " *
                            "(or `using PormG, SQLite`) so the SQLite extension loads."
const _MYSQL_DRIVER_HINT = "PormG: the MySQL backend requires MySQL. Run `using MySQL` " *
                           "(or `using PormG, MySQL`) so the MySQL extension loads."

# PostgreSQL has more than one candidate driver (#785), so the driver is a property of the POOL —
# `PostgresConnectionPool{D}` in ConnectionPool.jl — not only of the `PormGPostgres` marker. Several
# generics below carry no driver-typed argument (`backend_connect(pool)`,
# `backend_is_connection_error(pool, e)`, `backend_num_rows(pool, result)`, …), so two extensions
# that both typed those methods on the marker would overwrite each other, and whichever loaded last
# would serve every pool. An extension other than LibPQ's types its methods on its own
# `PostgresConnectionPool{D}` AND on its own connection, result and error types: the pool argument
# alone is not enough, because LibPQ's methods also type their second argument
# (`conn::LibPQ.Connection`, `e::LibPQ.Errors.LibPQException`), and an untyped one there is
# ambiguous with them once both extensions are loaded.
#
# Keyed by driver; the value is the package the user must load for it.
const _PG_DRIVER_PACKAGES = (libpq = "LibPQ", postgres = "Postgres")

# #1232: the weakdep extension that implements each driver — `:sqlite`, `:mysql` and the keys of
# `_PG_DRIVER_PACKAGES`. `Configuration.load` asks before it replaces anything, so a missing
# `using LibPQ` fails at boot instead of on the first query.
const _DRIVER_EXTENSIONS = (sqlite = :PormGSQLiteExt, libpq = :PormGLibPQExt, postgres = :PormGPostgresExt,
                            mysql = :PormGMySQLExt)

"""
    postgres_driver(pool::PormGPostgres) -> Symbol

The PostgreSQL driver `pool` is configured for: a key of `_PG_DRIVER_PACKAGES`. Every
`PormGPostgres` other than `PostgresConnectionPool{D}` — the unit suite's mock pools included —
answers `:libpq`, the only driver before #785.
"""
function postgres_driver end
postgres_driver(::PormGPostgres) = :libpq

# The missing-driver message for a PostgreSQL pool. A LibPQ pool keeps `_PG_DRIVER_HINT` byte for
# byte (docs/src/index.md quotes it).
_pg_driver_hint(pool::PormGPostgres)::String = _pg_driver_hint(postgres_driver(pool))

function _pg_driver_hint(driver::Symbol)::String
  driver === :libpq && return _PG_DRIVER_HINT
  # `get`, not indexing: this runs inside a fallback that must raise InvalidConfigurationError, and
  # a mock pool may answer a driver no real pool can have.
  package = get(_PG_DRIVER_PACKAGES, driver, string(driver))
  return "PormG: this PostgreSQL pool is configured for the $(package).jl driver. Run `using $(package)` " *
         "(or `using PormG, $(package)`) so its PostgreSQL extension loads."
end

# #1232: a driver (`_DRIVER_EXTENSIONS`' keys) → the message naming the package to load for it.
_driver_hint(driver::Symbol)::String =
  driver === :sqlite ? _SQLITE_DRIVER_HINT : driver === :mysql ? _MYSQL_DRIVER_HINT : _pg_driver_hint(driver)

# Backend generics. Real methods are added by the driver extensions; the fallbacks
# below fire when the matching driver has not been loaded.
#
#   backend_connect(pool; read_only=false)            -> open a physical connection
#   backend_renew_connection(pool, conn; read_only)   -> reset or recreate a dead connection
#   backend_is_alive(pool, conn)                       -> Bool liveness probe
#   backend_ping(pool, conn, timeout_seconds)          -> nothing, or raises: a server round trip, bounded (#1548, #1618; below)
#   backend_execute(pool, conn, sql, params)           -> SYNC execute (SQLite worker; PG parity)
#   backend_execute_async(pool, conn, sql, params)     -> async handle (PG: LibPQ.AsyncResult)
#   backend_is_connection_error(pool, e)               -> Bool: is `e` a dropped-connection error
#   backend_is_retry_safe(pool, e)                     -> Bool: did the statement provably never run (#1042; below, not in the loop)
#   backend_is_cancellation(e)                         -> Bool: was the statement cancelled (#1277; below, not in the loop)
#   backend_is_permanent_connect_error(pool, e)        -> Bool: is `e` a permanent connect failure (auth/cantopen) vs transient
#   backend_cancel_query!(pool, conn)                  -> best-effort: stop the statement running on `conn` (#315)
#   backend_drain_connection!(pool, conn)              -> Bool: is `conn` back to a clean, reusable state (#315)
#   backend_num_affected_rows(pool, result)            -> Int matched-row count (PG)
#   backend_num_rows(pool, result)                     -> Int row count (PG)
#   backend_last_insert_id(pool, result)               -> Int the AUTO_INCREMENT value an INSERT wrote (MySQL; #1266)
#   backend_insert_report(pool, result)                -> (records, duplicates) a multi-row INSERT reported, or nothing (MySQL; #1267)
#   backend_is_duplicate_key(pool, e)                  -> Bool: is the IntegrityError `e` a duplicate on a unique key (MySQL; #1267)
#   backend_copy_in!(pool, conn, sql, data_itr)        -> Int rows copied: PostgreSQL COPY FROM STDIN (#670)
#   backend_handle_type(P)                              -> the driver handle type a pool of type `P` holds (#1683; below, not in the loop)
#   backend_sqlite_version(pool)                        -> Int SQLite library version number
#   backend_mysql_version(pool)                         -> Int MySQL server version (`80411` for 8.4.11)
#   backend_mysql_parameter_limit(pool)                 -> Int parameters one prepared statement binds (below, not in the loop)
#   backend_postgres_parameter_limit(pool)              -> Int parameters one PostgreSQL statement binds (below, not in the loop)
#
# `backend_cancel_query!` and `backend_drain_connection!` are the abandoned-await pair (#315) —
# named rather than positioned, because this list grows. A Ctrl-C leaves the driver mid-operation, and
# neither state — libpq's unconsumed result, SQLite's worker still stepping — is visible to
# `backend_is_alive`, so the pool cannot tell a poisoned connection from a healthy one. They are in
# the loop below on purpose: the throwing "load the driver" fallback is a perfectly good answer for
# `ConnectionPool._recover_abandoned_connection!`, which catches both and treats a throw as
# "not clean" → renew or discard.
for fn in (:backend_connect, :backend_renew_connection, :backend_is_alive,
           :backend_execute, :backend_execute_async, :backend_is_connection_error,
           :backend_is_permanent_connect_error,
           :backend_cancel_query!, :backend_drain_connection!,
           :backend_num_affected_rows, :backend_num_rows, :backend_last_insert_id, :backend_copy_in!,
           :backend_insert_report, :backend_is_duplicate_key,
           :backend_sqlite_version, :backend_mysql_version)
  @eval begin
    function $fn end
    # InvalidConfigurationError, not ErrorException: forgetting `using LibPQ`/`using SQLite` is a
    # setup mistake the docs' `catch PormGError` recipe must cover (audit finding — this fires from
    # ALL backend generics, i.e. the first thing a consumer hits with a missing driver).
    $fn(pool::PormGPostgres, args...; kwargs...) = throw(InvalidConfigurationError(_pg_driver_hint(pool)))
    $fn(pool::PormGSQLite, args...; kwargs...) = throw(InvalidConfigurationError(_SQLITE_DRIVER_HINT))
    $fn(pool::PormGMySQL, args...; kwargs...) = throw(InvalidConfigurationError(_MYSQL_DRIVER_HINT))
  end
end

# #1163: the version the capability table's SQLite rows are read against (window functions from 3.25,
# …) is the library's. PostgreSQL's method asks the server, so it lives with its probe in `Migrations`.
Kernel._server_version(pool::PormGSQLite)::Int = backend_sqlite_version(pool)
# MySQL's is the server's, as announced in its greeting; the extension asks a pooled connection.
Kernel._server_version(pool::PormGMySQL)::Int = backend_mysql_version(pool)

# #1605: the typed read's execute. `decode` is the query builder's row decoder (a callable returning
# `Vector{T}`), handed down so the rows are decoded where the driver's result is concrete, never across a
# call typed `Any`. Only SQLite's worker calls it (PostgreSQL and MySQL decode in `fetch`, after the
# statement's `try`). The fallback decodes the materialized result `backend_execute` returns, through
# `decode_on_worker`, so a row-building error is recorded rather than thrown inside the worker's `try`,
# where it would come back wrapped as the statement's `StatementError`; it serves an SQLite-family pool
# whose handle is not an `SQLite.DB` (a test's stand-in). The SQLite extension adds a method to decode
# without materializing (it steps its statement straight into `T`) and records the same way. Not in the
# loop above: a missing driver raises from `backend_execute`.
function backend_execute_rows end
backend_execute_rows(pool::PormGBackend, conn, sql::String, params, decode) =
  decode_on_worker(decode, backend_execute(pool, conn, sql, params))
# The worker's half: decode a materialized result. The query builder's decoder records an error it
# raises instead of throwing it (`QueryBuilder._RowDecoder`); any other decoder is called as it is.
decode_on_worker(decode, result) = decode(result)
# `fetch`'s half, outside its `try`: the query builder's decoder raises an error the worker recorded,
# so it reaches the caller unwrapped. Any other value is the rows.
decoded_on_worker(decode, result) = result

# #1548: a server round trip on an idle connection, asked at checkout only for a slot idle past the pool's
# `validate_after_idle`. Returns `nothing`, or raises when the connection is unusable. A separate hook
# rather than an argument on `backend_is_alive`, so the probe every checkout runs stays local and free.
# Not in the loop above, and no fallback: only a backend with the `idle_validation` capability (MySQL)
# takes a threshold, so core never asks another backend, and one that gains the row must say how it
# pings instead of inheriting a guess. `timeout_seconds` is what is left of the checkout's deadline
# (#1618): a ping that has no answer by then raises, and core renews the slot as for any failed ping. A
# network path that drops packets without a reset would otherwise hold the checkout for the kernel's
# TCP retransmissions, minutes on Linux.
function backend_ping end

# The most parameters one MySQL prepared statement binds (#84, #1130). The protocol counts them in two
# bytes (COM_STMT_PREPARE), which is this fallback's answer and what a pool without its driver renders
# by (`show_query`). The MySQL extension answers its driver's own limit, which is lower: MySQL.jl refuses
# a statement past it before sending it. Not in the loop above: rendering never needs the driver.
function backend_mysql_parameter_limit end
backend_mysql_parameter_limit(::PormGMySQL)::Int = 65535

# The most parameters one PostgreSQL statement binds, per driver (#1447). The protocol counts them in an
# unsigned 2-byte field of the Bind message, 65535, which is what libpq binds: this fallback's answer, so the
# LibPQ extension needs no method, and a mock pool or a pool without its driver renders by it. The Postgres.jl
# extension answers its driver's own, lower limit. Not in the loop above: rendering never needs the driver.
function backend_postgres_parameter_limit end
backend_postgres_parameter_limit(::PormGPostgres)::Int = 65535

# The task a driver extension runs one statement in, for a `backend_execute_async` whose driver has no
# asynchronous call of its own (Postgres.jl, MySQL.jl). It is in the caller's threadpool (#1577): a
# statement from an `:interactive` task (a heartbeat, a lease renewal) runs on `:interactive`, and one
# from a `:default` task on `:default`. A bare `Threads.@spawn` put every statement on `:default`, so with
# every `:default` thread computing, an interactive caller's statement waited for one to free (one lookup
# in 6 s instead of 60). LibPQ needs no task here: `LibPQ.async_execute` runs on the caller's thread.
# `:samepool` sends a caller on a foreign thread to `:default`.
# Under plain `julia`, `-t N` and `-t auto` the interactive thread is thread 1, which takes `Ctrl+C`, so
# a statement awaited by the main task or the REPL now takes the interrupt inside its driver. Postgres.jl
# then closes the connection, and the driver's `cancel_query!` still cancels the statement by the
# backend's key (Postgres.jl 2.6, JuliaDatabases/Postgres.jl#45).
# A verb, so it stays in `PormG` with the extensions' generics; `test/unit/test_statement_threadpool.jl`
# fails on a `Threads.@spawn` written in `ext/`.
_statement_task(f::F) where {F} = Threads.@spawn :samepool f()

"""
    backend_handle_type(P::Type) -> Type

The driver's connection handle type that a pool of type `P` holds in its slots: `SQLite.DB`,
`LibPQ.Connection`, `Postgres.Connection`, `MySQL.Connection`. `Any` until the extension that serves
`P` says otherwise, so a pool whose driver is not loaded (an offline entry, a unit test's stand-in) is
unaffected.

A pool keeps its handles in `Vector{Any}` slots, because core never names a driver type. Every call that
hands a slot's handle to the driver therefore passes an `Any`: one dispatch per call under the JIT, and
in a `juliac --trim` image a call nothing was compiled for (#1683). `ConnectionPool._with_handle` tests
the handle against this type once and makes the call at the concrete type. Called with a constant `P`,
it folds to a constant, so the test is one type check.

Not in the missing-driver loop above: the answer for a pool with no driver is a type, not a refusal.
Each extension adds one method, keyed on the pool type it serves (`_Pool`, its alias for that type):

    PormG.backend_handle_type(::Type{_Pool}) = MySQL.Connection
"""
backend_handle_type(@nospecialize(P::Type)) = Any

"""
    backend_classify_error(pool, e) -> Symbol

Classify a failure raised by the database into one of the [`DatabaseError`](@ref) kinds:
`:integrity`, `:operational`, `:statement`, or `:unknown`. `ConnectionPool._as_database_error` maps
the symbol to a type; `:unknown` lands on `StatementError` so the umbrella never has a hole.

Deliberately **not** part of the missing-driver loop above: those fallbacks `throw`, and a
classifier that throws while an error is already propagating would replace the real failure with a
setup hint. This one always returns.

The default below is driver-agnostic — it can only recognize the case core already had a generic
for. Extensions refine it, and they dispatch on the **driver exception type**, not just the pool
marker:

    PormG.backend_classify_error(pool::PormGSQLite, e::SQLite.SQLiteException) = …

That is load-bearing. An extension method typed on the abstract marker alone shadows this default
for *every* pool of that flavor, including the behavioral mock pools the unit suite builds — which
throw plain `ErrorException`s and rely on their own `backend_is_connection_error` overrides. So an
extension only claims errors it actually understands. (PormG has been bitten by exactly this
shadowing before; see the note in `test/unit/test_error_taxonomy.jl`.)

**How an extension claims them (#1696).** The exception reaches this from a `catch`, typed `Any`. A
method per driver exception type made every call a dispatch on the exception's run-time type, and a
`juliac --trim` image had compiled nothing for it: a failing statement raised a `MethodError` in
place of the database error. So an extension defines **one** method for its pool type, takes the
exception `@nospecialize`, tests the types it understands with `isa`, and hands anything else to
`_default_classify_error`, the body of the default below. The call is then one compiled target
per pool type, and an error the extension does not understand gets exactly the default's answer:

    function PormG.backend_classify_error(pool::PormGSQLite, @nospecialize(e))
      e isa SQLite.SQLiteException || return PormG._default_classify_error(pool, e)
      …
    end

Precision differs by backend, on purpose:

  * **PostgreSQL** — exact. LibPQ parameterizes its exception type on the SQLSTATE
    (`PQResultError{Class, Code}`), so the extension reads the class directly. No string matching.
  * **SQLite** — message-based. `SQLiteException` carries only `msg`. The extended result code
    (`sqlite3_extended_errcode`) exists but is unusable here: it reads live per-connection state,
    and the transaction seams issue `ROLLBACK` on that same connection before rethrowing, which
    resets it. So the extension matches SQLite's own literal constraint strings — the same approach
    ActiveRecord's SQLite3 adapter takes.
"""
function backend_classify_error end

backend_classify_error(pool::PormGBackend, @nospecialize(e)) = _default_classify_error(pool, e)

# The default answer, as a plain function an extension's method falls through to for an exception it
# does not understand (see the docstring above).
function _default_classify_error(pool::PormGBackend, @nospecialize(e))
  # `backend_is_connection_error` hits the throwing fallback above when no driver is loaded, and a
  # pool mock may not define it at all. Never let classification throw: the caller is mid-`catch`,
  # and the original failure is preserved on `.cause` regardless of how we label it.
  try
    return backend_is_connection_error(pool, e) ? :operational : :unknown
  catch classify_failure
    # Everything except a cancellation. Swallowing Ctrl-C here would make a hung query
    # uninterruptible, which is worse than an unclassified error.
    classify_failure isa InterruptException && rethrow()
    return :unknown
  end
end

"""
    backend_is_retry_safe(pool, e) -> Bool

Did the statement that raised the lost connection `e` provably **never run** on the server? `fetch`
asks this only after `backend_is_connection_error` has said the connection is lost, and it
re-runs the statement only when this also says `true` (#1042).

The two questions are separate because they have different bars. *Lost* only has to mean the session
is gone, which is enough to renew the slot and retire the idle ones. *Never ran* is what a retry
needs, because a statement whose socket went away after the server received it may already have
committed, and a second run would apply an autocommit write twice. A driver answers `true` only for
the server saying so in a SQLSTATE (the backend is gone and the statement was not executed) or for
a failure raised before anything was written to the socket. A codeless "the socket went away"
answers `false`, whatever the phrase.

Like [`backend_classify_error`](@ref), an extension defines one method for its pool type that takes
the exception `@nospecialize` and falls through to `_default_retry_safe` for the types it does not
know (#1696).

Not in the missing-driver loop above, for `backend_classify_error`'s reason: `fetch` calls it
mid-`catch`, and a throw would replace the failure being reported. The default answers `false` —
no retry — so a driver or mock pool that never defines it is safe. Extensions add methods typed on
their exception types (with `isa`), falling through to the default for any other, so none changes
this default's answer for the unit suite's mock pools:

    function PormG.backend_is_retry_safe(pool::PormGPostgres, @nospecialize(e))
      e isa LibPQ.Errors.LibPQException || return PormG._default_retry_safe(pool, e)
      …
    end
"""
function backend_is_retry_safe end

backend_is_retry_safe(pool::PormGBackend, @nospecialize(e)) = _default_retry_safe(pool, e)

function _default_retry_safe(pool::PormGBackend, @nospecialize(e))
  # A multi-result failure: one coded "never ran" among them is the server's own answer. A loop, not
  # `any(closure, e.exceptions)`: over the `Vector{Any}` the closure call is a dynamic one (#1714).
  if e isa CompositeException
    for inner in e.exceptions
      backend_is_retry_safe(pool, inner) && return true
    end
  end
  return false
end

"""
    backend_is_cancellation(e) -> Bool

Does the driver exception `e` say the statement was **cancelled** — stopped on request, while the
session stays alive? A timeout the session set (`statement_timeout`, `max_execution_time`), an
explicit cancel, and PormG's own cancel of an abandoned await (#315) all count. Neither retry runs a
cancelled statement again, since that would defeat the cancel: [`with_read_retry`](@ref) asks this,
and so does `fetch`'s lost-connection retry (#1277).

Each engine answers in its own terms, so core never compares one engine's code: SQLSTATE `57014` on
both PostgreSQL drivers, error numbers 1317 (`KILL QUERY`) and 3024 (`max_execution_time`) on MySQL.

Keyed on the **exception type alone**, as `backend_error_fields` is: `with_read_retry` has no pool in
hand, and with no pool argument no extension method can shadow this default for the unit suite's mock
pools. Not in the missing-driver loop above, for `backend_classify_error`'s reason: it is asked
mid-`catch`, and a throw would replace the failure being reported. The default answers `false`.
Extensions add one method per driver exception type:

    PormG.backend_is_cancellation(e::LibPQ.Errors.QueryCanceled) = true
"""
function backend_is_cancellation end

function backend_is_cancellation(e)
  e isa CompositeException && return any(backend_is_cancellation, e.exceptions)
  return false
end

"""
    backend_error_fields(e) -> NamedTuple{(:sqlstate, :constraint, :table, :column, :message)}

The reason a driver exception carries, **as data** (#987): the fields a [`DatabaseError`](@ref) is
built with, each `nothing` when the driver does not report it. `ConnectionPool._as_database_error`
calls it for every failure it wraps, so the error's rendered text can be built from these fields
alone and never from the driver's text — which carries DETAIL, HINT and the `LINE n:` excerpt,
i.e. the row (prior art: psycopg's `e.diag`).

Keyed on the **exception type alone**, unlike the other `backend_*` generics: the type says which
driver raised it, and with no pool argument no extension method can shadow the default for the unit
suite's mock pools (the hazard `backend_classify_error` documents). Extensions add one method per
driver exception type:

    PormG.backend_error_fields(e::SQLite.SQLiteException) = …

What each driver can report differs, on purpose — the Postgres.jl `Error` has every field, LibPQ's
exception keeps only its text, and SQLite names no SQLSTATE. LibPQ still reports every field: its
extension reads them off the failed result before closing it and hands them to
`_as_database_error` itself (#1000), so its method here is only the fallback for a `PQResultError`
that arrives without its result. Like `backend_classify_error`, it never throws: the caller is
mid-`catch`.
"""
function backend_error_fields end

# The record every reader returns (#1714): the five fields a `DatabaseError` stores, each
# `Union{Nothing,String}`. One concrete type for every driver, so the error's constructors are static
# calls; build it with `_error_record`, which converts what a driver hands in (LibPQ's `SubString`s).
const _ErrorFields = NamedTuple{(:sqlstate, :constraint, :table, :column, :message), NTuple{5, Union{Nothing, String}}}
_field_text(::Nothing) = nothing
_field_text(s::String) = s
_field_text(s::SubString{String}) = String(s)
_field_text(@nospecialize(x)) = convert(Union{Nothing, String}, x)
_error_record(sqlstate, constraint, table, column, message)::_ErrorFields =
  _ErrorFields((_field_text(sqlstate), _field_text(constraint), _field_text(table), _field_text(column),
                _field_text(message)))

const _NO_ERROR_FIELDS = _error_record(nothing, nothing, nothing, nothing, nothing)

# ── An exception the driver does not own (#1714) ─────────────────────────────
#
# A classifier receives the failure from a `catch`, typed `Any` (#1696). Each extension narrows the
# exceptions it owns with `isa` and reads their fields at known types, so those make no dynamic call.
# Anything else (another driver's exception, a Base error, a test's own) is still classified the way it
# always was: by the text `string` gives it, or by the exception a wrapper keeps in `.cause`/`.err`.
# Those two readings are dynamic by nature (`string` on an untyped value, a field looked up by name), so
# they live here, in one place, behind `@noinline`: a classifier calls them only for an exception it does
# not own, and a trimmed image meets a dynamic call there and nowhere else in the classifiers.
@noinline _unowned_string(@nospecialize(x))::String = string(x)
@noinline _unowned_error_text(@nospecialize(e))::String = _phrase_text(_unowned_string(e))

# The lower-cased text an ASCII phrase test reads (#1714), which never throws: `lowercase` raises
# `InvalidCharError` on a malformed character (a server message in a LATIN1 locale, say), and that
# would replace the failure being classified. A malformed character becomes U+FFFD first; no phrase is
# anything but ASCII, so no match changes. (`string(e)` used to hide this: `repr` escapes those bytes.)
_phrase_text(s::String)::String =
  lowercase(map(c -> (Base.ismalformed(c) || Base.isoverlong(c)) ? '\ufffd' : c, s))
@noinline function _unowned_inner(@nospecialize(e))::Union{Nothing, Exception}
  for field in (:cause, :err)
    inner = hasproperty(e, field) ? getproperty(e, field) : nothing
    inner isa Exception && return inner
  end
  return nothing
end

backend_error_fields(e) = _NO_ERROR_FIELDS

"""
    backend_error_fields(pool, e) -> NamedTuple

The same fields, asked with the pool in hand: what `ConnectionPool._as_database_error` calls (#1696).
The exception comes from a `catch`, typed `Any`, and the one-argument form dispatches on its type,
which a `juliac --trim` image had compiled nothing for. Two extensions can be loaded together (LibPQ
and Postgres.jl), so neither can take over the one-argument form for an untyped exception; keyed on
the pool, each owns its own. An extension defines it for its CONCRETE pool type (never a marker, so a
stand-in pool is not claimed), takes the exception `@nospecialize`, and answers its own exception
types, `_NO_ERROR_FIELDS` otherwise. The default, for every other pool (the unit suite's stand-ins), is
the one-argument form, so a stand-in's fields are read exactly as before.
"""
backend_error_fields(pool::PormGBackend, @nospecialize(e)) = backend_error_fields(e)

# The server's primary message, or `nothing` when it is not safe to show. SQLSTATE class 22 (data
# exception) is the class whose message PostgreSQL builds FROM THE INPUT —
# `invalid input syntax for type uuid: "<value>"`, `value "<value>" is out of range for type integer`.
# Every other class names objects (a constraint, a column, a type), not values; the value is in the
# DETAIL, which no field carries. Decided here once, for both PostgreSQL extensions.
_safe_server_message(sqlstate, message) =
  (message === nothing || isempty(message) || (sqlstate !== nothing && Base.startswith(sqlstate, "22"))) ?
    nothing : String(message)
