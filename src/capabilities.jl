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
# Layer 1 (Kernel): the table names only the abstract backend types and `BackendCapabilityError`.
# A backend's rows are methods on its ABSTRACT type here, never in a driver extension — the
# `Backend.jl` ownership rule. The rows are documented in `docs/src/backends.md`, and
# `test/unit/test_capability_table.jl` fails when the page and the table disagree.
#
# Not in the table, deliberately: a feature that depends on a SERVER VERSION (window functions on
# SQLite < 3.25, schema management on PostgreSQL < 13 — probed at run time, `Dialect` and
# `Migrations`), a feature supported only in part (`ToChar` formats, `Extract` parts, casts SQLite
# spells differently), a difference in MEANING (a decimal SQLite stores as a double), and a gap in
# PormG rather than in an engine (explicit window frames, which SQLite has and PormG does not render
# there yet).

# feature => what it is, in words a refusal can say after "needs".
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
  @eval _has_feature(::Type{<:PormGPostgres}, ::Val{$(QuoteNode(f))}) = true
end

"""
    _supports(conn, feature::Symbol) -> Bool

Whether the backend `conn` has `feature`, one of the rows of `_BACKEND_FEATURES`. An unknown feature
name is a programming error and throws.
"""
function _supports(conn::PormGBackend, feature::Symbol)::Bool
  feature in _FEATURE_NAMES || throw(InvalidValueError("unknown backend feature `$(feature)`"))
  return _has_feature(typeof(conn), Val(feature))
end

# The engines PormG ships, by the name a message uses. A backend added later adds its row here and
# its `_has_feature` methods above; the refusals then offer it wherever it has the feature.
const _BACKENDS = ("PostgreSQL" => PormGPostgres, "SQLite" => PormGSQLite)
_backend_name(conn) = begin
  i = findfirst(p -> conn isa last(p), _BACKENDS)
  i === nothing ? string(nameof(typeof(conn))) : first(_BACKENDS[i])
end
# The engines that have `feature`, by name — what a refusal offers instead.
_supporting_backends(feature::Symbol) = [name for (name, T) in _BACKENDS if _has_feature(T, Val(feature))]

"""
    _capability_error(conn, feature, what; why = nothing) -> BackendCapabilityError

The refusal for `what` (the call or declaration, as the user wrote it) on a backend without
`feature`: it names the feature, the backend at hand, and the backends that have it. `why` adds the
backend-specific reason, when there is one worth saying. RETURNS the exception; the call site throws
it (the funnel convention).
"""
function _capability_error(conn, feature::Symbol, what::AbstractString;
                           why::Union{AbstractString,Nothing} = nothing)::BackendCapabilityError
  backend = _backend_name(conn)
  # Reached on a backend that HAS the feature: a call shape no renderer there takes, not a missing
  # feature — saying the backend lacks what the table says it has would be false.
  conn isa PormGBackend && _has_feature(typeof(conn), Val(feature)) &&
    return BackendCapabilityError("$(what) was called with arguments no $(backend) renderer takes; " *
                                  "$(backend) has $(_feature_description(feature)).")
  others = _supporting_backends(feature)
  msg = "$(what) needs $(_feature_description(feature)), which $(backend) does not support"
  msg *= isempty(others) ? "." : " (supported on $(join(others, ", ")))."
  why === nothing || (msg *= " " * why)
  return BackendCapabilityError(msg)
end

"""`_require_feature(conn, feature, what; why)` — throws `_capability_error(...)` unless `conn` has `feature`."""
_require_feature(conn::PormGBackend, feature::Symbol, what::AbstractString; why = nothing)::Nothing =
  _supports(conn, feature) ? nothing : throw(_capability_error(conn, feature, what; why = why))
