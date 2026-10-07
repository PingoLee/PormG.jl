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
#     `tools.jl`'s one Julia-level keep (and `Utils.jl`'s macro keep), no `docs/src` page
#     promising `ArgumentError`, the retired `_argerr` alias stays retired, and every funnel call
#     site throws its result.
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

A name on this query means **two** things at once, so it has no single meaning and PormG refuses to
guess. Two cases raise it:

- a `__` path's first segment names both a declared CTE and a model field, reverse accessor,
  many-to-many field, JSONField or `cjoin`/`on()` join path (#492). The message prints the
  `CTE("<name>", "<path>")` spelling that selects the CTE side;
- a `filter(...)` key names both a model field and a projection alias of the same name that
  projects something other than that column, e.g. `values("points" => Sum("points"))` followed by
  `filter("points" => …)` (#703). The message prints the rename that resolves it.

Deliberately its own type rather than an [`UnknownFieldError`](@ref): the name is known *twice*, not
unknown, and the remedy differs. A consuming app's typo handler should not also fire when a schema
change makes an existing name collide.
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
    InvalidValueError(reason, kind; op, model, field, field_type, row) <: PormGError

A value was refused: it failed coercion/type validation on a filter, insert or update, an
identifier failed the fail-closed safety check, or an interval/duration literal could not be
parsed. Raised by the `Models.format_*_sql` coercion helpers, which every write and filter path
calls (#239).

**A refusal never contains the value it refused** (#971): a bound value can be a password or any
other secret, and an app may hand `e.msg` to an HTTP client. The message names where it happened —
the operation, the field, the row of a bulk write — and why, and the value stays out of it.

Fields, beyond the rendered `msg`:
- `kind::Symbol` — what was wrong, as data: `:type` (a value of the wrong type), `:format` (text
  that does not parse), `:range` (parses, but out of bounds), `:nul` (a NUL character, #951),
  `:json_nul` (a NUL inside a JSON document, #954), `:other` for everything else.
- `reason::String` — the formatter's explanation, without any field or row.
- `op`, `model`, `field`, `field_type`, `row` — where it happened, `nothing` until a funnel knows.
  A formatter raises with the reason alone; the funnel that knows the field and row attaches them
  once (`with_location`).
"""
struct InvalidValueError <: PormGError
  msg::String
  kind::Symbol
  reason::String
  op::Union{Nothing, String}
  model::Union{Nothing, String}
  field::Union{Nothing, String}
  field_type::Union{Nothing, String}
  row::Union{Nothing, Int}

  InvalidValueError(msg::AbstractString) =
    (m = _emsg(msg); new(m, :other, m, nothing, nothing, nothing, nothing, nothing))
  function InvalidValueError(reason::AbstractString, kind::Symbol;
                             op = nothing, model = nothing, field = nothing,
                             field_type = nothing, row::Union{Nothing, Integer} = nothing)
    r = _emsg(reason)
    o, m, f, t = _opt_string(op), _opt_string(model), _opt_string(field), _opt_string(field_type)
    n = row === nothing ? nothing : Int(row)
    new(_render_refusal(r, o, m, f, t, n), kind, r, o, m, f, t, n)
  end
end

_opt_string(x) = x === nothing ? nothing : String(string(x))

# The one place a refusal's text is assembled (#971). The refused value is not an input to it, so
# no message built here can carry one:
#   Error in <op>[, row <n>][ for model <M>][, field `<f>`][ (<type>)]: <reason>
function _render_refusal(reason::String, op, model, field, field_type, row)
  op === nothing && model === nothing && field === nothing && row === nothing && return reason
  io = IOBuffer()
  print(io, "Error in ", op === nothing ? "a value" : op)
  row === nothing || print(io, ", row ", row)
  model === nothing || print(io, " for model ", model)
  field === nothing || print(io, ", field `", field, "`")
  field_type === nothing || print(io, " (", field_type, ")")
  print(io, ": ", reason)
  return String(take!(io))
end

"""
    with_location(e::InvalidValueError; op, model, field, field_type, row) -> InvalidValueError

`e` with its location filled in and its message rendered again. A part `e` already carries is kept
— the funnel nearest the value knows it best — so a refusal that passes through two funnels (a
single-cell format inside a bulk writer) is located once, and the second adds only the row (#971).
"""
with_location(e::InvalidValueError; op = nothing, model = nothing, field = nothing,
              field_type = nothing, row = nothing) =
  InvalidValueError(e.reason, e.kind;
                    op = something(e.op, op, Some(nothing)),
                    model = something(e.model, model, Some(nothing)),
                    field = something(e.field, field, Some(nothing)),
                    field_type = something(e.field_type, field_type, Some(nothing)),
                    row = something(e.row, row, Some(nothing)))

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
`iunaccent_*`, the `regex` family), full-text search on SQLite (the `@search` lookup and the
`Search*` functions, #31), an explicit window `frame=` on SQLite, `bulk_copy` on SQLite,
`with_advisory_lock(...; on_missing_lock = :error)` on SQLite, a `DecimalField` wider than the 15
digits SQLite stores exactly (raised by `makemigrations`, #648), or a SQLite library older than a
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
[`error_message`](@ref). The reason the database gave is carried **as data** (#987), each field
`nothing` when the driver does not report it:

| Field | What | Reported by |
|---|---|---|
| `sqlstate` | The five-character SQLSTATE, e.g. `"23505"` | both PostgreSQL drivers |
| `constraint` | The constraint that refused the row | both PostgreSQL drivers |
| `table`, `column` | The table and column the server named | both PostgreSQL drivers |
| `message` | The server's primary message — `nothing` for SQLSTATE class `22`, whose message quotes the input | every driver |

**The rendered text never carries a value** — `error_message`, `showerror` and `string` alike — so
it is safe to return to a client. The database's DETAIL, HINT and `LINE n:` excerpt quote the row,
so they live only in the driver's own exception, kept in `.cause` for a caller that logs it to a
trusted sink.

```julia
try
    M.Driver.objects.create("code" => "SEN")
catch e
    e isa IntegrityError && e.sqlstate == "23505" && return conflict(error_message(e))
    e isa OperationalError && return retry()
    rethrow()
end
```

Connect-time failure is *not* here: it never reached a statement, and has been
`ConnectionPool.PoolConnectError` under [`PoolError`](@ref) since #261.
"""
abstract type DatabaseError <: PormGError end

"""
    IntegrityError(adapter, cause; sqlstate, constraint, table, column, message) <: DatabaseError <: PormGError

A constraint rejected the statement — `UNIQUE`, `FOREIGN KEY`, `NOT NULL`, `CHECK`, or an exclusion
constraint. This is the one database failure applications routinely *handle* rather than propagate,
which is why it is its own type.

`adapter` is `"PostgreSQL"` or `"SQLite"`; `cause` is the driver's own exception, with the full text
the server sent. On PostgreSQL this is derived from SQLSTATE class `23`, so it is exact; on SQLite it
comes from SQLite's own literal constraint messages. The other fields are the reason as data — see
[`DatabaseError`](@ref).
"""
struct IntegrityError <: DatabaseError
  adapter::String                      # "PostgreSQL" | "SQLite"
  cause                                # driver exception (untyped: a driver may throw a non-Exception)
  sqlstate::Union{String, Nothing}
  constraint::Union{String, Nothing}
  table::Union{String, Nothing}
  column::Union{String, Nothing}
  message::Union{String, Nothing}      # the SAFE primary message — see the constructors below
end

"""
    OperationalError(adapter, cause; sqlstate, constraint, table, column, message) <: DatabaseError <: PormGError

The database could not complete the statement for a reason outside the statement itself, and
retrying may succeed — the connection dropped mid-query, a deadlock was detected, a serialization
failure occurred, or a lock could not be acquired in time.

`catch OperationalError` is the retry signal. PormG raises it for `with_advisory_lock` acquisition
timeouts too: contention is a runtime condition, not misuse. The fields are those of
[`DatabaseError`](@ref).
"""
struct OperationalError <: DatabaseError
  adapter::String
  cause
  sqlstate::Union{String, Nothing}
  constraint::Union{String, Nothing}
  table::Union{String, Nothing}
  column::Union{String, Nothing}
  message::Union{String, Nothing}
end

"""
    StatementError(adapter, cause; sqlstate, constraint, table, column, message) <: DatabaseError <: PormGError

A statement failed to execute — invalid SQL, an unknown table or column, a type the backend would
not accept, or insufficient privileges. Also the landing type for any failure on the database path
that could not be classified, so `catch DatabaseError` never has a hole.

Usually a bug to fix rather than a condition to handle. The driver's exception is in `.cause` and the
fields are those of [`DatabaseError`](@ref); the SQL text is deliberately **not** stored, because it
can embed user data (the `@error … sql=…` log sites already surface the statement where that is
appropriate).

The wording says *could not execute*, not *the database rejected this*, on purpose. Being the
unclassified fallback means a PormG-internal fault on the statement path can land here too — the
SQLite worker's malformed-payload invariant, for one — and claiming the server refused something it
never saw would send a reader hunting for a SQL bug that does not exist.
"""
struct StatementError <: DatabaseError
  adapter::String
  cause
  sqlstate::Union{String, Nothing}
  constraint::Union{String, Nothing}
  table::Union{String, Nothing}
  column::Union{String, Nothing}
  message::Union{String, Nothing}
end

# The 2-argument form every raise site used before #987 still works: the reason fields default to
# `nothing`. `ConnectionPool._as_database_error` fills them from `backend_error_fields`.
#
# `message` holds the SAFE primary message, never the raw one: the extensions leave it `nothing` for
# a class-22 SQLSTATE (`invalid input syntax for type uuid: "<value>"`), so an app reading `e.message`
# cannot trip over the value either. A `String` cause is PormG's own text — no driver throws one;
# advisory-lock contention passes a String, after `PoolConnectError`'s precedent — so it doubles as
# the message unless one is given.
_default_message(cause) = cause isa AbstractString ? String(cause) : nothing

IntegrityError(adapter, cause; sqlstate = nothing, constraint = nothing, table = nothing,
               column = nothing, message = _default_message(cause)) =
  IntegrityError(adapter, cause, sqlstate, constraint, table, column, message)
OperationalError(adapter, cause; sqlstate = nothing, constraint = nothing, table = nothing,
                 column = nothing, message = _default_message(cause)) =
  OperationalError(adapter, cause, sqlstate, constraint, table, column, message)
StatementError(adapter, cause; sqlstate = nothing, constraint = nothing, table = nothing,
               column = nothing, message = _default_message(cause)) =
  StatementError(adapter, cause, sqlstate, constraint, table, column, message)

# The sentence each subtype opens with — what happened, in the error's own words.
_database_error_head(e::IntegrityError) =
  "IntegrityError: $(e.adapter) rejected the statement — a constraint was violated"
_database_error_head(e::OperationalError) =
  "OperationalError: the $(e.adapter) operation could not complete and may succeed on retry"
_database_error_head(e::StatementError) =
  "StatementError: the $(e.adapter) statement could not be executed"

# A driver exception named by its type alone, never its text: `PQResultError{C23, E23505}` reads
# `PQResultError` — the SQLSTATE says the rest.
_cause_type_name(cause) = string(nameof(typeof(cause)))

# One rendering for every channel (#987, option B): `showerror`, and through it `error_message` and
# `@error … exception = e`. It is built ONLY from the fields — the driver's text is never read here —
# so no DETAIL, HINT, `LINE n:` excerpt or class-22 message can reach it, whatever the driver sent.
function Base.showerror(io::IO, e::DatabaseError)
  print(io, _database_error_head(e))
  facts = String[]
  e.sqlstate   === nothing || push!(facts, "SQLSTATE $(e.sqlstate)")
  e.constraint === nothing || push!(facts, "constraint \"$(e.constraint)\"")
  e.table      === nothing || push!(facts, "table \"$(e.table)\"")
  e.column     === nothing || push!(facts, "column \"$(e.column)\"")
  isempty(facts) || print(io, " (", join(facts, ", "), ")")
  if e.message !== nothing
    print(io, ": ", e.message)
  elseif e.sqlstate !== nothing && Base.startswith(e.sqlstate, "22")
    print(io, ". The server's message quotes the input, so it is not shown")
  elseif !(e.cause isa AbstractString)
    print(io, ": ", _cause_type_name(e.cause))   # the driver gave no reason PormG can read
  end
  e.cause isa AbstractString || print(io, " (the driver's full text is in `.cause`)")
  return nothing
end

# The 2-arg `show` too: `"$e"`, `string(e)` and `repr(e)` go through it, and the default method
# prints every field — the raw `cause` included, which on LibPQ is the whole server message.
# `PoolConnectError` has the same method for the same reason. The cause appears as its type.
function Base.show(io::IO, e::DatabaseError)
  print(io, nameof(typeof(e)), "(", repr(e.adapter), ", ",
        e.cause isa AbstractString ? repr(e.cause) : "<$(_cause_type_name(e.cause))>")
  sep = "; "
  for f in (:sqlstate, :constraint, :table, :column, :message)
    v = getfield(e, f)
    v === nothing && continue
    print(io, sep, f, " = ", repr(v))
    sep = ", "
  end
  print(io, ")")
end

"""
    TransactionError(msg) <: PormGError

The transaction API was used in a way that cannot work — `atomic(durable=true)` or
[`without_foreign_keys`](@ref PormG.ConnectionPool.without_foreign_keys) nested inside an open
transaction on the same database, or an operation on a model bound to one connection attempted
while a transaction is open on another.

Not a [`DatabaseError`](@ref): nothing was sent, and the database is not involved. Every case is
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
what the upgrade log's own #239 migration recipe did.
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

Umbrella for configuration failures — the connection setup, and the install PormG runs from —
`catch` it to get every case below. Like [`FieldAccessError`](@ref), this is an abstract mid-node
rather than a throwable type, so the pre-existing `MissingConfigurationError` can live *inside*
the bucket instead of beside it. `catch ConfigurationError` must not have holes; that class of
surprise is the reason this taxonomy exists.

Subtypes: [`InvalidConfigurationError`](@ref), [`WritesDisabledError`](@ref) (the `change_data:
false` write switch — its remedy is a config edit), and `Configuration.MissingConfigurationError`
(a missing folder/`connection.yml`, or a selected environment with no matching block).
"""
abstract type ConfigurationError <: PormGError end

"""
    InvalidConfigurationError(msg) <: ConfigurationError <: PormGError

The configuration — or the install it runs from — is unusable or inconsistent: an unsupported
adapter, an unknown connection key, a malformed `extensions` setting, an unsupported PostgreSQL
extension, a model not bound to a connection (or bound to an entry whose pool was never built), a
missing driver package (`using LibPQ` / `using SQLite` forgotten), an attempt to overwrite a
static connection, or a missing or empty `upgrading/` log bundled with the install
(`upgrade_guide`, #639).
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
plan, an invalid answer to an interactive `makemigrations` prompt, or a migration-engine step that
cannot proceed (no pending plan, an unparseable introspected DDL statement, a missing model file).
The importer-pointed-at-the-wrong-backend case is [`BackendCapabilityError`](@ref).
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
