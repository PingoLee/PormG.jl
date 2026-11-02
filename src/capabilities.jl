# #1129 — the per-backend CAPABILITY TABLE: which optional features each backend has.
#
# A feature a backend lacks is refused (`BackendCapabilityError`), never emulated. Before this table
# each refusal was a hand-written message at its own site, written against one engine pair ("requires
# PostgreSQL", "Use bulk_insert for SQLite") and dispatched on `PormGSQLite`, so a third backend
# reached a `MethodError`, a different error type, or no refusal at all. Here a feature is a row, a
# backend says yes with one method, and every refusal names the feature, the backend at hand, and the
# backends that DO support it — read from this table, so the sentence stays true when a backend is
# added. The prior art is Django's `DatabaseFeatures` (`supports_*` flags per backend).
#
# #1163: a row can also say FROM WHICH SERVER VERSION a backend has the feature (`_feature_since`):
# window functions on SQLite from 3.25, a generated column on PostgreSQL from 12, and so on. Every
# server-version question PormG asks reads one of these rows, whether its answer is a refusal (the
# introspection floor, a plan statement the server cannot run) or an exact fallback (a catalog column
# read as absent on a server that predates it, the `pg_input_is_valid` pre-check). The version is the
# server's own number — `server_version_num` on PostgreSQL (`130004` for 13.4), the packed library
# version on SQLite (`3045000` for 3.45.0) — and `_server_version(conn)` asks it.
#
# Layer 1 (Kernel): the table names only the abstract backend types and `BackendCapabilityError`.
# A backend's rows are methods on its ABSTRACT type here, never in a driver extension — the
# `Backend.jl` ownership rule. The rows are documented in `docs/src/backends.md`, and
# `test/unit/test_capability_table.jl` fails when the page and the table disagree.
#
# Not in the table, deliberately: a feature supported only in part (`ToChar` formats, `Extract`
# parts, casts SQLite spells differently), a difference in MEANING (a decimal SQLite stores as a
# double), a gap in PormG rather than in an engine (explicit window frames, which SQLite has and
# PormG does not render there yet), and a QUANTITY that depends on a version (SQLite's bind-parameter
# limit, 999 before 3.32 and 32766 from it: a number, not a yes or no).

# feature => what it is, in words a refusal can say after "needs" (or "for", on a version gap).
const _BACKEND_FEATURES = (
  :jsonb_operators   => "JSONB containment and key operators (`@>`, `?`, `?|`, `?&`)",
  :arrays            => "array types (`ArrayField`, `integer[]`)",
  :network_types     => "network address types (`inet`, `cidr`)",
  :full_text_search  => "full-text search (`tsvector`, `tsquery`)",
  :regex             => "POSIX regular-expression matching (`~`, `~*`)",
  :unaccent          => "the `unaccent` extension",
  :index_methods     => "index options beyond a plain b-tree (an access method, operator classes, `INCLUDE` columns)",
  :explain_options   => "an `EXPLAIN` option beyond the plain plan (`ANALYZE`, `BUFFERS`, `VERBOSE`)",
  :copy              => "`COPY` bulk loading",
  :advisory_locks    => "advisory locks",
  # #1269: a row lock that still lets another transaction check a foreign key against the row.
  :no_key_locks      => "a row lock weaker than `FOR UPDATE` that leaves foreign-key checks free (`FOR NO KEY UPDATE`)",
  # #1167: SQLite's `ROUND` has no negative precision — it reads one as 0, so `Round(125, -1)` would
  # answer `125.0` where it means `130`. Django's `Round` refuses it on SQLite the same way.
  :negative_round_precision => "rounding to a negative number of places (`Round(x, -1)`: tens, hundreds, …)",
  # #1553: a month or a year has no fixed length, so it is an interval VALUE only where an interval keeps
  # months apart (PostgreSQL's `interval`). SQLite and MySQL compute an interval as a number of
  # milliseconds or microseconds, which no month count converts to. A shift (`F("date") + Month(1)`) is
  # not this: every engine moves a date by a month.
  :calendar_intervals => "an interval type that keeps months and years apart (a `Month` or `Year` as an interval value)",
  # #1163: the rows below depend on the server version on at least one backend.
  :window_functions       => "window functions (`OVER (…)`)",
  # #1130 phase 2c-3b: two frame forms a backend can lack while it renders ROWS and RANGE frames.
  :window_groups_frame    => "a `GROUPS` window frame",
  :window_frame_exclusion => "an `EXCLUDE` clause in a window frame",
  # #1272: PostgreSQL's foreign keys are `DEFERRABLE INITIALLY DEFERRED`, SQLite's are deferred by the
  # `PRAGMA defer_foreign_keys` PormG sets in its transactions; InnoDB checks one at the statement.
  :deferred_foreign_keys  => "foreign keys checked at COMMIT rather than at each statement",
  # #1267: `ON CONFLICT (target)` names the unique key an upsert updates on; MySQL's `ON DUPLICATE KEY
  # UPDATE` names none and fires on a conflict with any of the table's unique keys.
  :upsert_conflict_target => "an upsert that names the unique key it updates on (`ON CONFLICT (target)`)",
  # #1266: PostgreSQL draws ids from the pk's sequence, SQLite reserves them in `sqlite_sequence`;
  # MySQL's AUTO_INCREMENT cannot be drawn ahead of the INSERT.
  :preallocated_keys      => "drawing auto-increment keys before the rows are written",
  # #1268: PostgreSQL's DDL is transactional, and SQLite's runs inside `BEGIN IMMEDIATE`; each MySQL DDL
  # statement commits on its own (atomic alone on 8.0+, but a plan of several is not).
  :transactional_ddl      => "transactional DDL (a migration plan's statements in one transaction, applied whole or not at all)",
  # MySQL has no partial index (`CREATE INDEX … WHERE`).
  :partial_indexes        => "a partial index (an index with a `WHERE` condition)",
  # MySQL indexes a `LONGTEXT`, `LONGBLOB` or `JSON` column only by a prefix of it (errors 1170, 3152).
  :unbounded_text_indexes => "an index or key over a whole column of unbounded text, bytes or JSON",
  # #737: PostgreSQL's `SET LOCAL statement_timeout` on the migration transaction; SQLite accepts the option
  # and ignores it, as every timeout. MySQL bounds no DDL statement's run time.
  :statement_timeouts     => "`migrate`'s `statement_timeout`, a bound on how long one plan statement may run (accepted and ignored on SQLite)",
  :nulls_order            => "`NULLS FIRST` / `NULLS LAST` in `ORDER BY`",
  # #1422 (#1271): an outer join that keeps the rows of the joined table. SQLite has both from 3.39.0;
  # MySQL has `RIGHT JOIN` and no `FULL JOIN`.
  :right_joins            => "a `RIGHT OUTER JOIN`",
  :full_joins             => "a `FULL OUTER JOIN`",
  :table_list             => "a catalog that labels virtual and shadow tables (`pragma_table_list`)",
  :schema_introspection   => "reading the schema from the system catalog",
  :migration_plans        => "the DDL a migration plan holds (identity columns, `INCLUDE` index columns)",
  :identity_columns       => "identity columns (`GENERATED … AS IDENTITY`)",
  :declarative_partitions => "declarative partitioning (`PARTITION BY`)",
  :include_columns        => "non-key index columns (`INCLUDE`)",
  # #1358: PormG's one generated field, not the SQL construct: MySQL and SQLite have `GENERATED ALWAYS AS
  # (…) STORED` too, but neither has the `tsvector` it computes. PostgreSQL's version row (12) is the
  # construct's, which is why a hand-written plan step that uses it is read against this row too.
  :generated_columns      => "a generated search vector (`SearchVectorField(generated_from = …)`, a `tsvector` column `GENERATED ALWAYS AS (…) STORED`)",
  :drop_expression        => "removing a column's generation expression (`ALTER COLUMN … DROP EXPRESSION`)",
  :input_validity         => "testing a value against a type's input function (`pg_input_is_valid`)",
  # #1264: a server PormG is verified against. Every backend has it; a backend with a version row
  # refuses an older server once, when a connection opens, rather than serving it SQL no one ran there.
  :supported_server       => "a server version PormG is verified against",
)
const _FEATURE_NAMES = Tuple(first.(_BACKEND_FEATURES))

_feature_description(feature::Symbol)::String = begin
  i = findfirst(p -> first(p) === feature, _BACKEND_FEATURES)
  i === nothing && throw(InvalidValueError("unknown backend feature `$(feature)`"))
  last(_BACKEND_FEATURES[i])
end

# The table, over backend TYPES (the engine types are abstract, so they have no instance to ask). A
# backend has a feature only when a method below says so: the fallback is `false`, so a new backend
# starts with none and gains each one deliberately.
_has_feature(::Type{<:PormGBackend}, ::Val) = false
for f in _FEATURE_NAMES
  f === :table_list && continue   # SQLite's own catalog; PostgreSQL has no virtual tables to label
  @eval _has_feature(::Type{<:PormGPostgres}, ::Val{$(QuoteNode(f))}) = true
end
for f in (:window_functions, :nulls_order, :table_list, :schema_introspection, :migration_plans,
          :supported_server, :deferred_foreign_keys, :upsert_conflict_target, :preallocated_keys,
          :transactional_ddl, :partial_indexes, :unbounded_text_indexes, :statement_timeouts,
          :right_joins, :full_joins)
  @eval _has_feature(::Type{<:PormGSQLite}, ::Val{$(QuoteNode(f))}) = true
end
# MySQL (#1130) gained each row in the phase that delivered it. Phase 1 delivered the
# connection: the server floor (#1264) and `GET_LOCK` advisory locks (#1269). Phase 2c-2: `ROUND`
# takes a negative precision (`ROUND(125, -1)` is 130, measured on 8.4). Phase 2c-3b: window functions
# (MySQL 8.0, below the floor), with ROWS and RANGE frames; GROUPS and EXCLUDE raise error 1235 there.
# Phase 4a: migrations on a schema created from nothing — reading the schema from `information_schema`
# and a migration plan's DDL, both from the 8.4 floor, with no version row of their own. `RIGHT JOIN`
# (#1422): MySQL has it and has no `FULL JOIN`, so `join_type = "FULL"` is refused there.
for f in (:supported_server, :advisory_locks, :negative_round_precision, :window_functions,
          :schema_introspection, :migration_plans, :right_joins)
  @eval _has_feature(::Type{<:PormGMySQL}, ::Val{$(QuoteNode(f))}) = true
end

# The version rows (#1163): the oldest server that has the feature, on a backend that has it at all.
# `nothing` — the fallback — is "every version PormG runs on". A version here is what the backend
# itself added, not a choice of PormG's, except for the two floors, which are what PormG checks:
# introspection reads only catalog columns 9.6 has (or reads a newer one only where it exists, through
# the rows below it), and a plan's DDL is checked against 11 and newer.
_feature_since(::Type{<:PormGBackend}, ::Val)::Union{Int, Nothing} = nothing
_feature_since(::Type{<:PormGSQLite}, ::Val{:window_functions}) = 3_025_000        # SQLite 3.25.0
_feature_since(::Type{<:PormGSQLite}, ::Val{:nulls_order}) = 3_030_000             # 3.30.0 (#75)
_feature_since(::Type{<:PormGSQLite}, ::Val{:table_list}) = 3_037_000              # 3.37.0 (#730)
_feature_since(::Type{<:PormGSQLite}, ::Val{:right_joins}) = 3_039_000             # 3.39.0 (#1422)
_feature_since(::Type{<:PormGSQLite}, ::Val{:full_joins}) = 3_039_000              # 3.39.0 (#1422)
_feature_since(::Type{<:PormGPostgres}, ::Val{:schema_introspection}) = 90_600     # 9.6 (#1162)
_feature_since(::Type{<:PormGPostgres}, ::Val{:migration_plans}) = 110_000         # 11 (#1162)
_feature_since(::Type{<:PormGPostgres}, ::Val{:identity_columns}) = 100_000        # 10
_feature_since(::Type{<:PormGPostgres}, ::Val{:declarative_partitions}) = 100_000  # 10
_feature_since(::Type{<:PormGPostgres}, ::Val{:include_columns}) = 110_000         # 11
_feature_since(::Type{<:PormGPostgres}, ::Val{:generated_columns}) = 120_000       # 12 (#1032)
_feature_since(::Type{<:PormGPostgres}, ::Val{:drop_expression}) = 130_000         # 13 (#1108)
_feature_since(::Type{<:PormGPostgres}, ::Val{:input_validity}) = 160_000          # 16 (#828)
_feature_since(::Type{<:PormGMySQL}, ::Val{:supported_server}) = 80_400            # MySQL 8.4 (#1264)

"""
    _server_version(conn) -> Int

The server version `conn` runs, in its backend's own number: `server_version_num` on PostgreSQL, the
packed library version on SQLite, `major * 10000 + minor * 100 + patch` on MySQL (`80411` for 8.4.11,
the number `mysql_get_server_version` reports). Asked by `_supports` for a version row. A backend's
method lives where it can ask: SQLite's and MySQL's beside `backend_sqlite_version` /
`backend_mysql_version` (`Backend.jl`), PostgreSQL's beside the schema readers (`Migrations`), which
ask it most. Not cached: a pool outlives a server upgrade, and a
stale version would read a newer server's schema with an older one's stand-ins. A caller with several
questions asks once and passes `server_version`.
"""
function _server_version end

# A server version as a message says it. PostgreSQL: one number from 10 on (`110000` is 11), two below
# (`90600` is 9.6). SQLite: the three-part library version (`3025000` is 3.25.0).
_version_text(::Type{<:PormGPostgres}, v::Integer)::String =
  v >= 100_000 ? string(v ÷ 10_000) : "$(v ÷ 10_000).$((v ÷ 100) % 100)"
_version_text(::Type{<:PormGSQLite}, v::Integer)::String = "$(v ÷ 1_000_000).$((v ÷ 1_000) % 1_000).$(v % 1_000)"
# MySQL: `80400` is 8.4 — a row names the release line; a server's patch is in `_version_at_hand`.
_version_text(::Type{<:PormGMySQL}, v::Integer)::String =
  v % 100 == 0 ? "$(v ÷ 10_000).$((v ÷ 100) % 100)" : "$(v ÷ 10_000).$((v ÷ 100) % 100).$(v % 100)"
# What this server is, in a refusal: the backend's name for the thing that has a version, and the raw
# number where the backend has one users look up.
_version_at_hand(T::Type{<:PormGPostgres}, v::Integer)::String =
  "this server is $(_version_text(T, v)) (server_version_num $(v))"
_version_at_hand(T::Type{<:PormGSQLite}, v::Integer)::String =
  "the SQLite library PormG loads is $(_version_text(T, v))"
_version_at_hand(::Type{<:PormGMySQL}, v::Integer)::String =
  "this server is $(v ÷ 10_000).$((v ÷ 100) % 100).$(v % 100)"
# The same clause asked of the connection, which is what a refusal holds (#1467). By default the type
# says it all. A connection whose version comes from somewhere other than its server or library adds
# a method: a `register_offline` SQLite key renders for the version it stated, and its method beside
# #1452's `_server_version` in `ConnectionPool.jl` says so, since Kernel cannot name that pool.
_version_at_hand(conn::PormGBackend, v::Integer)::String = _version_at_hand(typeof(conn), v)

"""
    _feature_at(T, feature, server_version) -> Bool

Whether backend type `T` has `feature` at `server_version`: the table's answer for a known version,
with no connection to ask. `_supports` is this with the version asked of the connection.
"""
function _feature_at(T::Type{<:PormGBackend}, feature::Symbol, server_version::Integer)::Bool
  feature in _FEATURE_NAMES || throw(InvalidValueError("unknown backend feature `$(feature)`"))
  _has_feature(T, Val(feature)) || return false
  since = _feature_since(T, Val(feature))
  return since === nothing || server_version >= since
end

"""
    _supports(conn, feature::Symbol; server_version = nothing) -> Bool

Whether the backend `conn` has `feature`, one of the rows of `_BACKEND_FEATURES`. For a version row,
the server is asked its version (`_server_version`) unless `server_version` gives it. An unknown
feature name is a programming error and throws.
"""
function _supports(conn::PormGBackend, feature::Symbol; server_version::Union{Integer, Nothing} = nothing)::Bool
  feature in _FEATURE_NAMES || throw(InvalidValueError("unknown backend feature `$(feature)`"))
  T = typeof(conn)
  _has_feature(T, Val(feature)) || return false
  _feature_since(T, Val(feature)) === nothing && return true
  return _feature_at(T, feature, (server_version === nothing ? _server_version(conn) : server_version))
end

# The engines PormG ships, by the name a message uses. A backend added later adds its row here and
# its `_has_feature` methods above; the refusals then offer it wherever it has the feature.
#
# MySQL's row came with phase 2b (#1130), the phase that decides what an expression MEANS there: every
# `_MEANING_DEPARTURES` row places each backend listed here (`test/unit/test_meaning_departures.jl`),
# and `docs/src/backends.md` carries a column for each.
const _BACKENDS = ("PostgreSQL" => PormGPostgres, "SQLite" => PormGSQLite, "MySQL" => PormGMySQL)
_backend_name(conn) = begin
  i = findfirst(p -> conn isa last(p), _BACKENDS)
  i === nothing ? string(nameof(typeof(conn))) : first(_BACKENDS[i])
end
# The engine as a key — the `NamedTuple` key a pinned `db_default` is spelled under. One method per
# engine and NO fallback (#1129 item 2): a new backend gets a `MethodError` here rather than SQLite's
# key, which `db_default_sql`'s `conn isa PormGPostgres ? :postgres : :sqlite` handed it silently.
# Not a capability — an engine FACT, kept here because Dialect and Migrations both use it.
_engine_key(::PormGPostgres) = :postgres
_engine_key(::PormGSQLite) = :sqlite
_engine_key(::PormGMySQL) = :mysql
# The engines that have `feature`, by name — what a refusal offers instead.
_supporting_backends(feature::Symbol) = [name for (name, T) in _BACKENDS if _has_feature(T, Val(feature))]

"""
    _capability_error(conn, feature, what; why = nothing, server_version = nothing) -> BackendCapabilityError

The refusal for `what` (the call or declaration, as the user wrote it) on a backend without
`feature`: it names the feature, the backend at hand, and the backends that have it. On a backend
that has the feature from a version its server is older than (#1163), it names that version and the
server's instead — `server_version` is the one already asked, or the server is asked here. `why` adds
the backend-specific reason, when there is one worth saying. RETURNS the exception; the call site
throws it (the funnel convention).
"""
function _capability_error(conn, feature::Symbol, what::AbstractString;
                           why::Union{AbstractString,Nothing} = nothing,
                           server_version::Union{Integer,Nothing} = nothing)::BackendCapabilityError
  backend = _backend_name(conn)
  if conn isa PormGBackend && _has_feature(typeof(conn), Val(feature))
    T = typeof(conn)
    since = _feature_since(T, Val(feature))
    v = since === nothing ? nothing : (server_version === nothing ? _server_version(conn) : server_version)
    if v !== nothing && v < since
      msg = "$(what) needs $(backend) $(_version_text(T, since)) or newer, for $(_feature_description(feature)); " *
            "$(_version_at_hand(conn, v))."
      why === nothing || (msg *= " " * why)
      return BackendCapabilityError(msg)
    end
    # Reached on a backend that HAS the feature: a call shape no renderer there takes, not a missing
    # feature — saying the backend lacks what the table says it has would be false.
    return BackendCapabilityError("$(what) was called with arguments no $(backend) renderer takes; " *
                                  "$(backend) has $(_feature_description(feature)).")
  end
  others = _supporting_backends(feature)
  msg = "$(what) needs $(_feature_description(feature)), which $(backend) does not support"
  msg *= isempty(others) ? "." : " (supported on $(join(others, ", ")))."
  why === nothing || (msg *= " " * why)
  return BackendCapabilityError(msg)
end

"""
    _require_feature(conn, feature, what; why, server_version) -> Nothing

Throws `_capability_error(...)` unless `conn` has `feature` — at its server's version, for a version row.
"""
function _require_feature(conn::PormGBackend, feature::Symbol, what::AbstractString;
                          why = nothing, server_version::Union{Integer,Nothing} = nothing)::Nothing
  v = server_version
  if v === nothing && _has_feature(typeof(conn), Val(feature)) && _feature_since(typeof(conn), Val(feature)) !== nothing
    v = _server_version(conn)   # asked once, for the check and the message
  end
  _supports(conn, feature; server_version = v) ? nothing :
    throw(_capability_error(conn, feature, what; why = why, server_version = v))
end
