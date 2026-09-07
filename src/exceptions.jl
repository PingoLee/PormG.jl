# ── Semantic error taxonomy (#231, #239) ────────────────────────────────────
# Every PormG misuse throws a subtype of `PormGError` so a consuming app catches a TYPE, not a
# message substring. This extends the #197 lineage (throw real Exceptions, not raw Strings).
# The subtypes are deliberately **NOT** `<: ArgumentError` — a clean pre-publish break.
#
# This file is included by `Kernel` (layer 1), not by `QueryBuilder`. #231 originally put the
# subtypes in `src/querybuilder/exceptions.jl` (now `error_funnels.jl`), included at step 11 of
# PormG.jl's chain, which meant `Models`, `Configuration`, `ConnectionPool` and `Dialect` — all
# included earlier — could not name a single one of them. Defining the taxonomy in layer 1 is what
# lets #239 retype those subsystems at all. The message-composing funnels (`_unsupported_conn`,
# `_write_not_allowed`) stay behind in `src/querybuilder/error_funnels.jl`, next to their call sites.
#
# `_emsg` (defined above in Kernel) strips ANSI escape codes whenever Julia is not in color mode,
# so coloured error tokens render in the REPL and as plain text in every non-TTY sink (CI output,
# file logs, `sprint(showerror, e)`). Each subtype's inner constructor applies `_emsg` at
# construction, so `.msg` is clean off-TTY (several tests read `err.msg`).

# ## Adding a type to this taxonomy? Three guards enforce its contract
#
# They live with their subsystems rather than in one file, so this is the index:
#
#   • `test/unit/test_kernel_layering.jl` — the placement rule: a concrete subtype either lives in
#     `Kernel`, or has a DEDICATED Kernel-owned abstract umbrella above it (the root does not
#     count). Walks `subtypes(PormGError)` rather than the export list, so it also sees the types
#     reachable only by qualified name — a new subtype is covered without touching the test.
#   • `test/unit/test_docs_error_type_drift.jl` — no `throw(ArgumentError(` in `src/` outside
#     `tools.jl`'s two Julia-level keeps, no `docs/src` page promising `ArgumentError`, the retired
#     `_argerr` alias stays retired, and every funnel call site throws its result.
#   • `test/unit/test_error_taxonomy.jl` — hierarchy shape, the clean break from `ArgumentError`,
#     and `error_message` coverage for every concrete member.
#
# Also update `docs/src/api.md`'s taxonomy table and the frozen export list in
# `test/unit/test_public_exports.jl`; both are asserted, so they fail loudly rather than drift.
#
# One trap the guards do NOT catch cleanly: a subtype built from structured fields (no `msg`) must
# be added to the hand-written skip lists in `test_error_taxonomy.jl`'s `error_message` testset, or
# it fails there as an opaque `MethodError` on `T("boom")` rather than as a readable assertion.

# ── Query-builder errors (#231) ─────────────────────────────────────────────

"""
    FieldAccessError <: PormGError  (abstract)

Umbrella for field/accessor lookup failures — `catch` it to get
[`UnknownFieldError`](@ref) ("no such field"), [`AmbiguousFieldError`](@ref)
("that name has two meanings here") and [`LazyTraversalError`](@ref)
("unsupported lazy traversal").
"""
abstract type FieldAccessError <: PormGError end

"""
    UnknownFieldError(msg) <: FieldAccessError <: PormGError

A field, alias, column, or `__` lookup path does not exist on the model or the projected row.
"""
struct UnknownFieldError <: FieldAccessError
  msg::String
  UnknownFieldError(msg::AbstractString) = new(_emsg(msg))
end

"""
    AmbiguousFieldError(msg) <: FieldAccessError <: PormGError

A `__` path's first segment names **two** things on this query at once — a declared CTE and a
model field, reverse accessor, many-to-many field, JSONField or `cjoin`/`on()` join path — so it has
no single meaning and PormG refuses to guess (#492).

Deliberately its own type rather than an [`UnknownFieldError`](@ref): the name is known *twice*, not
unknown, and the remedy differs. A consuming app's typo handler should not also fire when a schema
change makes an existing CTE name collide. The message names both readings and prints the
`CTE("<name>", "<path>")` spelling that selects the CTE side.
"""
struct AmbiguousFieldError <: FieldAccessError
  msg::String
  AmbiguousFieldError(msg::AbstractString) = new(_emsg(msg))
end

"""
    LazyTraversalError(msg) <: FieldAccessError <: PormGError

An unprojected `ForeignKey` was read off a fetched row. PormG has no lazy FK traversal; the
message steers the caller to up-front `values(...)` projection (#204).
"""
struct LazyTraversalError <: FieldAccessError
  msg::String
  LazyTraversalError(msg::AbstractString) = new(_emsg(msg))
end

"""
    FilterError(msg) <: PormGError

An invalid filter argument/shape, or an operator misused on a JSON/subquery column.
"""
struct FilterError <: PormGError
  msg::String
  FilterError(msg::AbstractString) = new(_emsg(msg))
end

"""
    QueryBuildError(msg) <: PormGError

Structural/API misuse while building a query — joins, CTEs, projection, ordering, window and
bulk configuration, and the like. The default bucket for query-builder misuse that isn't one of
the sharper categories below.
"""
struct QueryBuildError <: PormGError
  msg::String
  QueryBuildError(msg::AbstractString) = new(_emsg(msg))
end

"""
    UnsafeMutationError(msg) <: PormGError

An UPDATE or DELETE was requested without a filter (or in another unsafe shape) and refused.
"""
struct UnsafeMutationError <: PormGError
  msg::String
  UnsafeMutationError(msg::AbstractString) = new(_emsg(msg))
end

"""
    InvalidValueError(msg) <: PormGError

A value failed coercion/type validation on insert/update, an identifier failed the fail-closed
safety check, or an interval/duration literal could not be parsed. Also raised by the
`Models.format_*_sql` coercion helpers, which the insert/update path calls (#239).
"""
struct InvalidValueError <: PormGError
  msg::String
  InvalidValueError(msg::AbstractString) = new(_emsg(msg))
end

"""
    UnsupportedConnectionError(msg) <: PormGError

A connection object that is neither a PostgreSQL nor a SQLite pool reached an execution path —
a PormG internal dispatch bug; the message asks the user to report it. The catchable replacement
for the internal `ErrorException` from #197.

Narrowed in the pre-publish naming pass: it previously also covered backend capability limits
(now [`BackendCapabilityError`](@ref)) and models not bound to a connection (now
[`InvalidConfigurationError`](@ref), whose docstring always claimed that case) — three disjoint
remedies distinguishable only by message text, which is the failure mode this taxonomy exists to
remove.
"""
struct UnsupportedConnectionError <: PormGError
  msg::String
  UnsupportedConnectionError(msg::AbstractString) = new(_emsg(msg))
end

"""
    BackendCapabilityError(msg) <: PormGError

The active backend cannot do this — a PostgreSQL-only lookup on SQLite (JSONB containment,
`iunaccent_*`), an explicit window `frame=` on SQLite, `bulk_copy` on SQLite,
`with_advisory_lock(...; on_missing_lock = :error)` on SQLite, or a SQLite library older than a
feature requires. The query is well-formed and the configuration is fine; the remedy is to change
the request or the backend — each message names the specific way out. Split out of
`UnsupportedConnectionError` in the pre-publish naming pass — capability limits are a user-facing
contract, not an internal error.
"""
struct BackendCapabilityError <: PormGError
  msg::String
  BackendCapabilityError(msg::AbstractString) = new(_emsg(msg))
end

"""
    ProtectedError(msg) <: PormGError

A `delete()` was refused because other rows reference the target through a `ForeignKey` declared
with `on_delete = PROTECT` (or `RESTRICT`). Nothing about the call is malformed — the *data*
forbids it, and the remedy is to delete or reassign the referencing rows first. Mirrors Django's
`ProtectedError`/`RestrictedError`; previously filed under the long-tail `QueryBuildError`, which
made this case indistinguishable from a malformed delete.
"""
struct ProtectedError <: PormGError
  msg::String
  ProtectedError(msg::AbstractString) = new(_emsg(msg))
end

# get() cardinality errors — reparented from `Exception` to `PormGError` (#231) so
# `catch PormGError` catches them too. They keep their structured fields and field-built
# `showerror` (below), which is why they don't use the uniform `msg::String` shape.
"""
    DoesNotExist <: PormGError

`get()` matched zero rows. Carries `model_name` and the rendered `filters` (structured — no `msg`
field; read it with [`error_message`](@ref)). Often normal control flow: catch it to implement
get-or-create-style logic.
"""
struct DoesNotExist <: PormGError
  model_name::String
  filters::String
end

"""
    MultipleObjectsReturned <: PormGError

`get()` matched more than one row — usually a data-integrity surprise rather than control flow.
Carries `model_name`, the offending `count`, and the rendered `filters` (structured — no `msg`
field; read it with [`error_message`](@ref)).
"""
struct MultipleObjectsReturned <: PormGError
  model_name::String
  count::Int
  filters::String
end

"""
    PoolError <: PormGError

Abstract umbrella for connection-pool failures — `catch PoolError` to handle both saturation and
connect failure without naming each. Subtypes: `ConnectionPool.PoolTimeoutError` (no connection
became available in time) and `ConnectionPool.PoolConnectError` (the backend refused or dropped
the connection).

Both concrete types keep their structured fields (`adapter`, `pool_size`, `attempts`, …) and their
own `showerror`, so they do not use the uniform `msg::String` shape — read them with
[`error_message`](@ref).

The umbrella lives here rather than in `ConnectionPool` on purpose (#261). The taxonomy's rule is
that a concrete subtype either lives in `Kernel` or has a *dedicated* Kernel-owned abstract
umbrella above it — the root `PormGError` does not count, or the rule would be vacuous. The pool
errors were the only pair satisfying neither, which is the same mid-include-chain trap that made
#239 need the `Kernel` extraction (#255). `Configuration` is included *before* `ConnectionPool`
and already reasons about pool failure, so it could not have named those types.
"""
abstract type PoolError <: PormGError end

# ── Database errors (#268) ──────────────────────────────────────────────────
#
# The boundary this taxonomy could not previously describe: everything above is *misuse of PormG*,
# raised before a statement leaves the process. These four are the other half — the database
# accepted a connection, ran something, and said no.
#
# Before #268 those failures propagated as the driver's own exception types, so an app that wanted
# to handle a UNIQUE violation had to `catch SQLite.SQLiteException` / `LibPQ.Errors.*` — taking a
# hard dependency on the driver package purely to *name* the type, which fights the weakdep design
# that keeps LibPQ/SQLite optional. Every mature ORM wraps here (Django's PEP-249 tree,
# SQLAlchemy's `DBAPIError.orig`, ActiveRecord's `translate_exception`, Diesel's
# `DatabaseErrorKind`), always with the original reachable; PormG now does too, via `.cause`.
#
# Classification is per-adapter and lives in the extensions (`backend_classify_error`), because
# telling a UNIQUE violation from a syntax error needs driver knowledge and core must never name a
# driver type. The two backends are not equally precise, on purpose — see `backend_classify_error`
# in `src/Backend.jl` and the two extension bodies.

"""
    DatabaseError <: PormGError  (abstract)

Umbrella for failures raised *by the database itself*, once a statement has reached it — as opposed
to the rest of the taxonomy, which reports misuse of PormG before anything is sent.
`catch DatabaseError` covers every case below without naming a driver package.

Subtypes: [`IntegrityError`](@ref) (a constraint said no), [`OperationalError`](@ref) (transient —
the connection dropped, a deadlock, a lock timeout), and [`StatementError`](@ref) (the statement
itself was rejected, plus anything the backend could not classify).

All three are built from structured fields rather than a `msg::String`, so read them with
[`error_message`](@ref). Each keeps the driver's own exception in `.cause`, so SQLSTATE-level
detail stays available to callers that want it:

```julia
try
    M.Driver.objects.create("code" => "SEN")
catch e
    e isa IntegrityError  && return conflict(error_message(e))
    e isa OperationalError && return retry()
    rethrow()
end
```

Connect-time failure is *not* here: it never reached a statement, and has been
`ConnectionPool.PoolConnectError` under [`PoolError`](@ref) since #261.
"""
abstract type DatabaseError <: PormGError end

# Render a wrapped driver failure for human consumption.
#
# Driver exceptions are not required to be `Exception` subtypes (same defensive reasoning as
# `PoolConnectError.cause`), so both shapes are handled.
#
# The `msg` branch exists because the two drivers are not equally well-behaved. LibPQ defines
# `Base.showerror` for its exceptions, so `sprint(showerror, …)` renders "UniqueViolation: ERROR:
# duplicate key …" — exactly what we want. SQLite.jl defines none, so Julia falls back to
# `showerror(io, ::Exception) = show(io, ex)` and the cause renders as the struct literal
# `SQLiteException("UNIQUE constraint failed: t.c")` — type name and quoting as noise inside our own
# sentence. Comparing against `show` detects that fallback exactly (it is the same method), so a
# driver that bothers to define `showerror` keeps its richer rendering and one that doesn't
# contributes its bare message.
function _cause_text(cause)
  cause isa Exception || return string(cause)
  rendered = sprint(showerror, cause)
  if hasproperty(cause, :msg) && rendered == sprint(show, cause)
    return string(getproperty(cause, :msg))
  end
  return rendered
end

"""
    IntegrityError(adapter, cause) <: DatabaseError <: PormGError

A constraint rejected the statement — `UNIQUE`, `FOREIGN KEY`, `NOT NULL`, `CHECK`, or an exclusion
constraint. This is the one database failure applications routinely *handle* rather than propagate,
which is why it is its own type.

`adapter` is `"PostgreSQL"` or `"SQLite"`; `cause` is the driver's own exception. On PostgreSQL this
is derived from SQLSTATE class `23`, so it is exact; on SQLite it comes from SQLite's own literal
constraint messages.
"""
struct IntegrityError <: DatabaseError
  adapter::String        # "PostgreSQL" | "SQLite"
  cause                  # underlying driver exception (untyped: a driver may throw a non-Exception)
end

Base.showerror(io::IO, e::IntegrityError) = print(io,
  "IntegrityError: ", e.adapter, " rejected the statement — a constraint was violated: ",
  _cause_text(e.cause))

"""
    OperationalError(adapter, cause) <: DatabaseError <: PormGError

The database could not complete the statement for a reason outside the statement itself, and
retrying may succeed — the connection dropped mid-query, a deadlock was detected, a serialization
failure occurred, or a lock could not be acquired in time.

`catch OperationalError` is the retry signal. PormG raises it for `with_advisory_lock` acquisition
timeouts too: contention is a runtime condition, not misuse.
"""
struct OperationalError <: DatabaseError
  adapter::String
  cause
end

Base.showerror(io::IO, e::OperationalError) = print(io,
  "OperationalError: the ", e.adapter, " operation could not complete and may succeed on retry: ",
  _cause_text(e.cause))

"""
    StatementError(adapter, cause) <: DatabaseError <: PormGError

A statement failed to execute — invalid SQL, an unknown table or column, a type the backend would
not accept, or insufficient privileges. Also the landing type for any failure on the database path
that could not be classified, so `catch DatabaseError` never has a hole.

Usually a bug to fix rather than a condition to handle. The driver's exception is in `.cause`; the
SQL text is deliberately **not** stored, because it can embed user data (the `@error … sql=…` log
sites already surface the statement where that is appropriate).

The wording says *could not execute*, not *the database rejected this*, on purpose. Being the
unclassified fallback means a PormG-internal fault on the statement path can land here too — the
SQLite worker's malformed-payload invariant, for one — and claiming the server refused something it
never saw would send a reader hunting for a SQL bug that does not exist.
"""
struct StatementError <: DatabaseError
  adapter::String
  cause
end

Base.showerror(io::IO, e::StatementError) = print(io,
  "StatementError: the ", e.adapter, " statement could not be executed: ", _cause_text(e.cause))

"""
    TransactionError(msg) <: PormGError

The transaction API was used in a way that cannot work — `atomic(durable=true)` nested inside an
open transaction, or an operation on a model bound to one connection attempted while a transaction
is open on another.

Not a [`DatabaseError`](@ref): nothing was sent, and the database is not involved. Both cases are
caught before any statement is issued. A deadlock or a rollback the *server* forces is an
[`OperationalError`](@ref) instead.

Introduced in #268 so the two checks stop reporting as unrelated types (`QueryBuildError` said
"query shape" for what is a transaction-nesting mistake; `InvalidConfigurationError` said "your
config is wrong" when the config was fine and the call pattern was not).
"""
struct TransactionError <: PormGError
  msg::String
  TransactionError(msg::AbstractString) = new(_emsg(msg))
end

# ── Schema, configuration and migration errors (#239) ───────────────────────

"""
    DefinitionError <: PormGError  (abstract)

Umbrella for model-definition-time failures — `catch DefinitionError` covers both a bad field
constructor argument ([`FieldValidationError`](@ref)) and a bad model/schema shape
([`ModelDefinitionError`](@ref)). They almost always surface together: one `include("models.jl")`
can raise either, and a handler that names only one silently misses the other — which is exactly
what `UPGRADING.md`'s own #239 migration recipe did.
"""
abstract type DefinitionError <: PormGError end

"""
    FieldValidationError(msg) <: DefinitionError <: PormGError

A field constructor was given an invalid argument — a kwarg of the wrong type, a `max_length`
outside its permitted range, a `default` that does not satisfy the field's own contract, a
`choices` shape that does not parse, or a field type that cannot serve as a primary key.

Raised while *defining* a model. Contrast [`InvalidValueError`](@ref), which is raised while
coercing a *value* on the insert/update path.
"""
struct FieldValidationError <: DefinitionError
  msg::String
  FieldValidationError(msg::AbstractString) = new(_emsg(msg))
end

"""
    ModelDefinitionError(msg) <: DefinitionError <: PormGError

A model or schema definition is invalid — more than one primary key, a duplicate `related_name`,
a reverse accessor that shadows a field or contains `__` / `@`, an illegal field
name, a `UniqueConstraint` that names an unknown or many-to-many field, an unresolvable
`ForeignKey` / `ManyToManyField` target, or a `Model(...)` call given something that is not a
`PormGField`.
"""
struct ModelDefinitionError <: DefinitionError
  msg::String
  ModelDefinitionError(msg::AbstractString) = new(_emsg(msg))
end

"""
    ConfigurationError <: PormGError  (abstract)

Umbrella for connection-configuration failures — `catch` it to get every case below. Like
[`FieldAccessError`](@ref), this is an abstract mid-node rather than a throwable type, so the
pre-existing `MissingConfigurationError` can live *inside* the bucket instead of
beside it. `catch ConfigurationError` must not have holes; that class of surprise is the reason
this taxonomy exists.

Subtypes: [`InvalidConfigurationError`](@ref), [`WritesDisabledError`](@ref) (the `change_data:
false` write switch — its remedy is a config edit), and `Configuration.MissingConfigurationError`
(a missing folder/`connection.yml`, or a selected environment with no matching block).
"""
abstract type ConfigurationError <: PormGError end

"""
    InvalidConfigurationError(msg) <: ConfigurationError <: PormGError

Connection configuration is present but unusable or inconsistent — an unsupported adapter, an
unknown connection key, a malformed `extensions` setting, an unsupported PostgreSQL extension,
a model not bound to a connection (or bound to an entry whose pool was never built), a missing
driver package (`using LibPQ` / `using SQLite` forgotten), or an attempt to overwrite a static
connection.
"""
struct InvalidConfigurationError <: ConfigurationError
  msg::String
  InvalidConfigurationError(msg::AbstractString) = new(_emsg(msg))
end

"""
    WritesDisabledError(msg) <: ConfigurationError <: PormGError

The connection is not permitted to insert/update/delete — its settings carry `change_data: false`.
The remedy is a configuration edit (`connection.yml`), which is why this lives under
[`ConfigurationError`](@ref). Renamed from `PermissionError` in the pre-publish naming pass: that
name read as OS/file permissions to some audiences and database GRANTs to others, while the actual
meaning is PormG's own write switch.
"""
struct WritesDisabledError <: ConfigurationError
  msg::String
  WritesDisabledError(msg::AbstractString) = new(_emsg(msg))
end

"""
    MigrationError <: PormGError  (abstract)

Umbrella for migration-engine failures — `catch` it to get every case below, including a refused
destructive plan.

Subtypes: [`InvalidMigrationError`](@ref), and `Migrations.DestructiveMigrationError` (a
destructive plan applied non-interactively without `destructive=true`).
"""
abstract type MigrationError <: PormGError end

"""
    InvalidMigrationError(msg) <: MigrationError <: PormGError

The migration engine refused or could not complete an operation — a duplicate index name in a
plan, an invalid answer to an interactive `makemigrations` prompt, an unimplemented
`migrate_to(version)` path, or a migration-engine step that cannot proceed (no pending plan,
an unparseable introspected DDL statement, a missing model file). The importer-pointed-at-the-
wrong-backend case is [`BackendCapabilityError`](@ref).
"""
struct InvalidMigrationError <: MigrationError
  msg::String
  InvalidMigrationError(msg::AbstractString) = new(_emsg(msg))
end

# ── showerror ───────────────────────────────────────────────────────────────
# One `showerror` covers every `msg`-carrying subtype. DoesNotExist / MultipleObjectsReturned
# override with their field-built messages (a more specific method wins on dispatch); so do the
# reparented types that carry their own structured fields (PoolTimeoutError, PoolConnectError,
# MissingConfigurationError, DestructiveMigrationError) and the three DatabaseError subtypes, each
# next to its definition.
Base.showerror(io::IO, e::PormGError) = print(io, e.msg)

"""
    error_message(e::PormGError) -> String

The text of any PormG error, as a `String`.

Use this instead of `e.msg`. Seven subtypes are built from structured fields and have **no `msg`
field at all** — `DoesNotExist`, `MultipleObjectsReturned`, `ConnectionPool.PoolTimeoutError`,
`ConnectionPool.PoolConnectError`, and the three [`DatabaseError`](@ref) subtypes
(`IntegrityError`, `OperationalError`, `StatementError`) — so `e.msg` throws a `FieldError` on
exactly the errors a caller is least likely to have tested against (#261, #268).

```julia
try
    M.Result.objects.values("bad alias!" => "points").list()
catch e
    e isa PormGError || rethrow()
    @error "PormG rejected the query" msg=error_message(e) type=typeof(e)
end
```

Defined via `showerror`, which every subtype implements, so it stays correct for subtypes added
later without needing a new method. For subtypes that use the generic `showerror` above, the result
is exactly `e.msg` (it prints that field verbatim, and `_emsg` has already normalized any ANSI at
construction). Subtypes with their own `showerror` return that richer rendering instead — e.g.
`Configuration.MissingConfigurationError` and `Migrations.DestructiveMigrationError`
both carry a `msg` yet prefix it with the error name, so `error_message` is a superset of `.msg`,
never a subset.
"""
error_message(e::PormGError)::String = sprint(showerror, e)

Base.showerror(io::IO, e::DoesNotExist) =
  print(io, "$(e.model_name).DoesNotExist: No record found matching filters: $(e.filters)")

Base.showerror(io::IO, e::MultipleObjectsReturned) =
  print(io, "$(e.model_name).MultipleObjectsReturned: Expected 1 record, got $(e.count) for filters: $(e.filters)")
