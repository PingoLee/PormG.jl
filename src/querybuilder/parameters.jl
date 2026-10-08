# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL Implementation – numbered parameters ($1, $2 …)
#
# Stores a single linear vector of values and a counter.
# The `current_context` field exists for interface compatibility but is ignored
# because PostgreSQL uses numbered placeholders whose order is irrelevant.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct PgParameterizedQuery <: PormGPostgresParam
  sql::String
  parameters::Union{AbstractVector,Tuple}
  parameter_count::Int

  PgParameterizedQuery(sql::String, parameters::Union{AbstractVector,Tuple}, parameter_count::Int) = new(sql, parameters, parameter_count)
end
get_parameter(connection::PormGPostgres) = PgParameterizedQuery("", Any[], 0)

function _postgres_parameter_cast(::Nothing)
  return ""
end

function _postgres_parameter_cast(sql_type::AbstractString)
  isempty(sql_type) && return ""
  return "::$(sql_type)"
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Implementation – Contextual Bucket Strategy
#
# SQLite uses purely positional parameters (?).  Because code execution order
# (filters first, then joins) does not match final SQL string order (JOINs
# appear before WHERE), we cannot simply append to a single vector.
#
# Instead we maintain one vector per SQL section ("bucket").  As the query
# builder processes each section it enters `with_bucket` to switch the active
# bucket, which restores the previous one on exit (#936, #939); `set_context!`
# is for a statement entry point starting a fresh collector.  `add_parameter!`
# pushes into the *active* bucket and always returns "?".  After all sections
# are built, `get_final_parameters` concatenates the buckets in standard SQL
# clause order so that the positional `?` markers line up with their values.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct SQLiteParameterizedQuery <: PormGSQLiteParam
  sql::String
  # Separate buckets for each SQL section — one per clause that can carry a `?`, in no particular
  # order here; `_BUCKET_ORDER` below is the clause order and the only list that must match the
  # statement text.
  cte_params::Vector{Any}
  select_params::Vector{Any}
  update_params::Vector{Any}
  join_params::Vector{Any}
  where_params::Vector{Any}
  # #587: GROUP BY and ORDER BY had no bucket, so an ordering expression that binds — the
  # `@yyyy_q` / `@yyyy_quad` labels expand to a CONCAT/CASE with nine operands — was filed under
  # `:join`, which flattens BEFORE `:where` while its text renders AFTER it. Every other parameter
  # in the statement shifted by the size of the expression, the counts still agreed, and SQLite
  # returned the wrong rows without an error. `:group` exists because `get_order_query` copies an
  # unprojected ordering expression into GROUP BY verbatim, `?` and all, and GROUP BY prints
  # BEFORE HAVING — so the same values are needed twice, in two clause positions.
  group_params::Vector{Any}
  having_params::Vector{Any}
  order_params::Vector{Any}
  # #46: LIMIT and OFFSET, bound like every other user value. Last, because their text is: the only
  # thing printed after them is the `FOR UPDATE` lock clause, which binds nothing.
  limit_params::Vector{Any}
  # Active bucket selector
  current_context::Symbol

  function SQLiteParameterizedQuery(sql::String="", current_context::Symbol=:where)
    new(sql, Any[], Any[], Any[], Any[], Any[], Any[], Any[], Any[], Any[], current_context)
  end
end
get_parameter(connection::PormGSQLite) = SQLiteParameterizedQuery()

# ─────────────────────────────────────────────────────────────────────────────
# Bucket accessor helper – returns the vector for the current context
# ─────────────────────────────────────────────────────────────────────────────
function _current_bucket(sq::SQLiteParameterizedQuery)::Vector{Any}
  ctx = sq.current_context
  ctx === :cte && return sq.cte_params
  ctx === :select && return sq.select_params
  ctx === :update && return sq.update_params
  ctx === :join && return sq.join_params
  ctx === :where && return sq.where_params
  ctx === :group && return sq.group_params
  ctx === :having && return sq.having_params
  ctx === :order && return sq.order_params
  ctx === :limit && return sq.limit_params
  # Fallback – warn about unknown context and route to :where so nothing silently breaks
  @warn "Unknown parameter context $(repr(ctx)), falling back to :where" ctx
  return sq.where_params
end

# ─────────────────────────────────────────────────────────────────────────────
# set_context!  – switch the active bucket before processing each SQL section
# ─────────────────────────────────────────────────────────────────────────────
"""
    set_context!(params::AbstractPormGParam, context::Symbol)

Switch the active parameter bucket for positional-parameter backends (SQLite).
Valid contexts: `:cte`, `:select`, `:update`, `:join`, `:where`, `:group`, `:having`, `:order`,
`:limit`.

For numbered-parameter backends (PostgreSQL) this is a no-op.
"""
set_context!(::PormGPostgresParam, ::Symbol) = nothing   # no-op for Postgres
function set_context!(sq::PormGSQLiteParam, context::Symbol)
  sq.current_context = context
  return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# _apply_like_wildcards  – add wildcards based on operator type
# ─────────────────────────────────────────────────────────────────────────────
"""
    _apply_like_wildcards(value::Any, operator::String)::Any

Apply appropriate LIKE wildcards based on the operator, which is what each of the three operator
sets in `src/constants.jl` names (#604 — the membership lists used to be spelled out here, and
`istartswith`/`iendswith` were in none of them despite having complete Dialect renderers):

- `LIKE_CONTAINS_OPERATORS`: `%value%`
- `LIKE_PREFIX_OPERATORS`: `value%`
- `LIKE_SUFFIX_OPERATORS`: `%value`
- Anything else: the value is returned untouched — no wildcards and, note, no escaping either.

That last branch is unreachable on the live path and is a fallback, not a supported case: the only
caller passes `contains = v.operator in LIKE_WILDCARD_OPERATORS`, and those three sets partition
`LIKE_WILDCARD_OPERATORS` exactly. So `VERBATIM_PATTERN_OPERATORS` — `iexact` / `niexact` (#634),
`iunaccent_exact` / `niunaccent_exact` and the regex four (#635) — never arrive here at all: they
are excluded one level up, which is what keeps their `=` / `<>` / `~` comparison using the value
verbatim.

The negated pattern operators (#207) decorate the value identically to their positive twin — only
the Dialect renderer differs (NOT LIKE vs LIKE), so the wildcard placement is the same. Same for the
case-insensitive twins (#604): folding happens in SQL, so `istartswith` decorates like `startswith`.
"""
function _apply_like_wildcards(value::Any, operator::String)::Any
  escaped = escape_like_pattern(string(value))
  if operator in LIKE_CONTAINS_OPERATORS
    return string("%", escaped, "%")
  elseif operator in LIKE_PREFIX_OPERATORS
    return string(escaped, "%")
  elseif operator in LIKE_SUFFIX_OPERATORS
    return string("%", escaped)
  else
    return value
  end
end
# Convenience: operate on the instruction object directly
set_context!(instruc::SQLInstruction, context::Symbol) = instruc.parameters !== nothing ? set_context!(instruc.parameters, context) : nothing

"""
    with_bucket(f, params_or_instruc, context::Symbol)

Run `f()` with `context` as the active positional bucket, then restore the bucket that was active
before — on return and on throw, so a render that throws never leaves its clause behind for the next
one (#936, #939). The only way a build path changes the bucket: `set_context!` is reserved for a
statement entry point starting a FRESH collector, and `test/unit/test_render_scope.jl` pins both.

A restore, never a reset. A writer that resets to a constant (`finally set_context!(x, :where)`) is
right only while nothing nests: once a render inside a render returns, the outer one resumes in the
constant's clause, and every value it binds after that lands in the wrong bucket — silently, and
only on SQLite, because PostgreSQL numbers `\$N` at render. It is `with_scope`'s rule for
`RenderScope`, applied to the second piece of render state.

The bucket stays on the COLLECTOR, not in `RenderScope`: one collector is shared by the outer build
and every nested one, while a scope belongs to one instruction. And several statement paths bind
with no instruction at all (the CTE clause, bulk, many-to-many, delete). A no-op on PostgreSQL.
"""
with_bucket(f, ::PormGPostgresParam, ::Symbol) = f()
function with_bucket(f, sq::PormGSQLiteParam, context::Symbol)
  prev = sq.current_context
  sq.current_context = context
  try
    return f()
  finally
    sq.current_context = prev
  end
end
with_bucket(f, instruc::SQLInstruction, context::Symbol) =
  instruc.parameters === nothing ? f() : with_bucket(f, instruc.parameters, context)

# ─────────────────────────────────────────────────────────────────────────────
# Positional parameter marks
#
# `parameter_mark` records the ACTIVE bucket and its length, so a caller can read back the values a
# render bound (`bound_since`); `reattach_parameters!` appends a run lifted out elsewhere (#432's
# nested runs). The mark holds the bucket VECTOR, not the context symbol: a render that switched
# context and failed to restore it then reads nothing, rather than an unrelated run.
#
# #421 used a third verb here, `detach_parameters!`, to lift a join condition's values out while its
# SQL fragment waited to be relocated onto another join. #982 deleted it with the relocation: a
# condition now renders where its join is emitted, so its values bind in text order without moving.
#
# All no-ops on numbered backends. PostgreSQL's `$N` numbering already travels with the text.
# ─────────────────────────────────────────────────────────────────────────────
const ParameterMark = Tuple{Union{Nothing,Vector{Any}},Int}

_positional_bucket(::PormGPostgresParam) = nothing
_positional_bucket(sq::PormGSQLiteParam) = _current_bucket(sq)
_positional_bucket(instruc::SQLInstruction) =
  instruc.parameters === nothing ? nothing : _positional_bucket(instruc.parameters)

function parameter_mark(instruc::SQLInstruction)::ParameterMark
  bucket = _positional_bucket(instruc)
  return (bucket, bucket === nothing ? 0 : length(bucket))
end

function reattach_parameters!(instruc::SQLInstruction, values::Vector{Any})
  isempty(values) && return nothing
  bucket = _positional_bucket(instruc)
  bucket === nothing || append!(bucket, values)
  return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Nested-render runs (#432)
#
# #421's mark above watches ONE bucket. That is right for a fragment that stays inside a single
# clause, and wrong for a NESTED RENDER — an `Exists(...)`, a projected `Subquery(...)`, an `__@in`
# subquery — whose inner build walks its own clauses and therefore pushes into SEVERAL buckets while
# its text is spliced into ONE of the parent's.
#
# Two independent things go wrong there, and both are fixed by the same move:
#
#   1. **Wrong bucket.** The inner build's ON values land in the OUTER `:join` bucket (its
#      `build_row_join_sql_text` switched to `:join` unconditionally, defeating the `set_contexts`
#      gate `build()` had then), while their `?` renders inside the outer WHERE. `:join` flattens
#      before `:where`, so they overtake values whose text precedes them.
#   2. **Wrong ORDER, even within one bucket.** A build BINDS in phase order (select → where → …
#      → joins last) but RENDERS in clause order (joins before where). At top level the buckets
#      absorb that difference — that is what they are for. A nested run has no such reordering
#      unless we give it one: simply restoring the ambient bucket yields binding order, which for
#      `Exists(inner-with-ON)` is `WHEREVAL, ONVAL` against a text order of `ONVAL, WHEREVAL`.
#
# So: mark every bucket, let the inner build scatter, then lift everything it added and re-emit it
# as ONE contiguous run in the parent's active bucket, concatenated in CLAUSE order. That gives the
# fragment the same phase→clause reordering a top-level statement gets, and pins the whole run at
# the parent's marker position.
#
# All no-ops on numbered backends: PostgreSQL's `$N` travels with the text, which is why every bug
# in this family has been SQLite-only.
# ─────────────────────────────────────────────────────────────────────────────

# Clause order. `get_final_parameters` flattens from this same tuple, so there is ONE list to edit
# when a bucket is added — the maintenance checklist in the QueryBuilder skill points here.
#
# `:group` and `:order` (#587) sit where their text does — GROUP BY between WHERE and HAVING,
# ORDER BY after HAVING. `:limit` (#46) holds LIMIT then OFFSET, which print after ORDER BY. The
# statement renderer in `execution_read.jl` (`query`) prints in exactly this order.
const _BUCKET_ORDER = (:cte, :select, :update, :join, :where, :group, :having, :order, :limit)

# Deliberately mirrors `_current_bucket`'s fallback rather than defining its own: an unrecognized
# context must land in the same bucket and warn the same way from both helpers, or a future bucket
# added to one and not the other diverges silently.
function _bucket_for(sq::PormGSQLiteParam, ctx::Symbol)::Vector{Any}
  ctx === :cte && return sq.cte_params
  ctx === :select && return sq.select_params
  ctx === :update && return sq.update_params
  ctx === :join && return sq.join_params
  ctx === :where && return sq.where_params
  ctx === :group && return sq.group_params
  ctx === :having && return sq.having_params
  ctx === :order && return sq.order_params
  ctx === :limit && return sq.limit_params
  @warn "Unknown parameter context $(repr(ctx)), falling back to :where" ctx
  return sq.where_params
end

const _N_BUCKETS = length(_BUCKET_ORDER)
const NestedMark = Union{Nothing,NTuple{_N_BUCKETS,Int}}

"""
    nested_parameter_mark(instruc) -> NestedMark

Record the length of every positional bucket. `nothing` on a numbered backend.
"""
function nested_parameter_mark(sq)::NestedMark
  sq isa PormGSQLiteParam || return nothing
  return ntuple(i -> length(_bucket_for(sq, _BUCKET_ORDER[i])), _N_BUCKETS)
end
nested_parameter_mark(instruc::SQLInstruction)::NestedMark = nested_parameter_mark(instruc.parameters)

"""
    detach_nested_run!(instruc, mark) -> Vector{Any}

Lift everything bound since `mark` out of every bucket, returning it concatenated in clause order —
the order those values' markers actually render in.
"""
function detach_nested_run!(sq, mark::NestedMark)::Vector{Any}
  mark === nothing && return Any[]
  sq isa PormGSQLiteParam || return Any[]
  run = Any[]
  for (i, ctx) in enumerate(_BUCKET_ORDER)
    bucket = _bucket_for(sq, ctx)
    len = mark[i]
    length(bucket) <= len && continue
    append!(run, bucket[len+1:end])
    deleteat!(bucket, len+1:length(bucket))
  end
  return run
end
detach_nested_run!(instruc::SQLInstruction, mark::NestedMark)::Vector{Any} =
  detach_nested_run!(instruc.parameters, mark)

# Append a lifted run to whatever bucket is active on `sq`. The `SQLInstruction` form below is the
# common one; this bare-collector form exists because `build_cte_clause` holds only the parameter
# object — it renders a CTE body before any instruction for the outer statement exists.
function reattach_parameters!(sq::AbstractPormGParam, values::Vector{Any})
  isempty(values) && return nothing
  sq isa PormGSQLiteParam || return nothing
  append!(_current_bucket(sq), values)
  return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Duplicating a run into a second clause (#587)
#
# One rendered fragment can be PRINTED in two clauses: `get_order_query` pushes an unprojected
# ordering expression into GROUP BY as well as ORDER BY, so under an aggregate the same `?`s appear
# twice in the text. On a positional backend that is two bindings, one per clause position — the
# values bound while rendering the term (read back through a `parameter_mark`) are appended again
# under the second clause's bucket. A no-op on numbered backends: PostgreSQL prints the same `$N`
# in both places and binds it once.
# ─────────────────────────────────────────────────────────────────────────────
function bound_since(mark::ParameterMark)::Vector{Any}
  bucket, len = mark
  (bucket === nothing || length(bucket) <= len) && return Any[]
  return bucket[len+1:end]
end

copy_parameters_to!(::PormGPostgresParam, ::Symbol, ::Vector{Any}) = nothing
function copy_parameters_to!(sq::PormGSQLiteParam, ctx::Symbol, values::Vector{Any})
  isempty(values) && return nothing
  append!(_bucket_for(sq, ctx), values)
  return nothing
end
copy_parameters_to!(instruc::SQLInstruction, ctx::Symbol, values::Vector{Any}) =
  instruc.parameters === nothing ? nothing : copy_parameters_to!(instruc.parameters, ctx, values)

# ─────────────────────────────────────────────────────────────────────────────
# add_parameter!  – push a value and return the placeholder string
# ─────────────────────────────────────────────────────────────────────────────

# The PostgreSQL wire form of one binary payload, shared by the scalar and the array collector
# (#296, #466): LibPQ binds every parameter in text format, so the bytes travel as PostgreSQL's hex
# input syntax and `byteain` decodes them server-side. Inside an array literal LibPQ quotes the
# element and doubles its backslash (`{"\\x0102"}`), which the array parser undoes before handing
# each element to `byteain` — so the same text serves both positions.
_pg_bytea_text(value::PormGBytes)::String = "\\x" * bytes2hex(value.bytes)

# --- PostgreSQL ---
function add_parameter!(pq::PormGPostgresParam, value::AbstractArray; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)
  contains && (throw(FilterError("Contains option is not supported for array parameters")))
  pq.parameter_count += 1
  # #466: a membership list over a BinaryField arrives as `PormGBytes` elements (the formatter maps
  # per element, #411), and LibPQ's array renderer would `show` the wrapper into the literal. Unwrap
  # to the scalar arm's hex text; `= ANY($N)` infers `bytea[]` from the column. Any other list is
  # pushed untouched, element type included.
  if any(v -> v isa PormGBytes, value)
    value = Any[v isa PormGBytes ? _pg_bytea_text(v) : v for v in value]
  end
  push!(pq.parameters, value)
  return "\$$(pq.parameter_count)$(_postgres_parameter_cast(sql_type))"
end
function add_parameter!(pq::PormGPostgresParam, value; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  if contains
    value = _apply_like_wildcards(value, operator)
  end
  pq.parameter_count += 1
  push!(pq.parameters, value)
  return "\$$(pq.parameter_count)$(_postgres_parameter_cast(sql_type))"  # PostgreSQL style
end

# --- SQLite – Contextual Bucket Strategy ---
function add_parameter!(sq::PormGSQLiteParam, value::AbstractArray; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)
  contains && (throw(FilterError("Contains option is not supported for array parameters")))
  # Expand array into multiple positional parameters for SQLite. #466: a `PormGBytes` element
  # is unwrapped to its bytes, exactly as the scalar arm below does — SQLite.jl's `bind!(::Any)`
  # fallback would otherwise Julia-serialize the wrapper into a BLOB that matches nothing. Every
  # other element goes through `sqlite_bind_value` for the same reason (#721).
  placeholders = join(fill("?", length(value)), ", ")
  for v in value
    push!(_current_bucket(sq), v isa PormGBytes ? v.bytes : sqlite_bind_value(v))
  end
  return placeholders
end
function add_parameter!(sq::PormGSQLiteParam, value; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  if contains
    value = _apply_like_wildcards(value, operator)
  end
  # #721: the one place a SQLite value is bound, so the one place it is made bindable. A value the
  # column formatter already turned into text passes through; a raw literal (`Value(x)`, a function
  # kwarg, an integer `format_number_sql` returns as is) is converted or refused here, never handed
  # to SQLite.jl's serializing fallback. `value_repr.jl` owns the table.
  push!(_current_bucket(sq), sqlite_bind_value(value))
  return "?"  # SQLite positional style
end

# --- Binary payloads (#296) ---
# A `PormGBytes` is one opaque blob, never a list of values, so these must beat the
# `::AbstractArray` methods above — and they do, since `PormGBytes` is not an array at all.
# Without them a binary value takes the array path and is silently mangled on both backends;
# see the `PormGBytes` docstring in `Kernel.jl` for what each one does wrong.
#
# LibPQ binds every parameter in text format and offers no binary-parameter API, so the wire
# form here is PostgreSQL's hex input syntax (`\x0102`). The server infers `bytea` from the
# target column, `byteain` hex-decodes it, and the bytes land intact — including `0x00`, which
# could never survive as a raw String parameter because LibPQ passes a NUL-terminated C string.
function add_parameter!(pq::PormGPostgresParam, value::PormGBytes; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  contains && throw(FilterError("Contains option is not supported for binary parameters"))
  pq.parameter_count += 1
  push!(pq.parameters, _pg_bytea_text(value))
  return "\$$(pq.parameter_count)$(_postgres_parameter_cast(sql_type))"
end

# SQLite binds a `Vector{UInt8}` natively via sqlite3_bind_blob, so the bytes pass through
# unwrapped. Unwrapping here is load-bearing: SQLite.jl's `bind!(::Any)` fallback silently
# *Julia-serializes* an unrecognized value into a BLOB rather than raising, so a `PormGBytes`
# that reached the driver would be stored as a serialized Julia object.
function add_parameter!(sq::PormGSQLiteParam, value::PormGBytes; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  contains && throw(FilterError("Contains option is not supported for binary parameters"))
  push!(_current_bucket(sq), value.bytes)
  return "?"
end

# --- Array values (#28) ---
# An `ArrayField` value arrives as its PostgreSQL literal (`Models.ArrayFormatter`), and binds as that
# one text parameter. No cast: every position a column value binds at (`=`, INSERT VALUES, UPDATE SET)
# gives the server the column's type, on both drivers, so the literal is read as that array type. A
# `PormGArrayLiteral` is not an `AbstractArray`, so it never reaches the list arms above, which would
# turn it into an `= ANY(…)` membership list.
function add_parameter!(pq::PormGPostgresParam, value::PormGArrayLiteral; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  contains && throw(FilterError("A pattern lookup does not apply to an array column; compare the whole array, or test its elements with a containment lookup."))
  pq.parameter_count += 1
  push!(pq.parameters, value.literal)
  return "\$$(pq.parameter_count)$(_postgres_parameter_cast(sql_type))"
end
# SQLite has no array type: `field_to_column` refuses an `ArrayField` there, so a value can only reach
# this arm through a model whose table PormG did not create. Refused rather than bound as text, the
# general rule for a specialized type on SQLite.
function add_parameter!(sq::PormGSQLiteParam, value::PormGArrayLiteral; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  throw(BackendCapabilityError("An ArrayField value cannot be bound on SQLite: SQLite has no array type, and PormG does not emulate one. Run this model on PostgreSQL."))
end

# #903: a scalar `Sockets.IPAddr` literal — `Value(ip"…")`, a `Value` operand, a `Case` branch — binds
# as the text PostgreSQL prints for it (`format_inet_sql`: `::ffff:10.0.0.1`, not `Sockets`'
# `::ffff:a00:1`), the text every network filter and write already binds. The `::inet` cast comes from
# `_infer_parameter_sql_type`. (A `Value` holding a VECTOR of addresses takes the array arm above,
# raw.) SQLite has no network type, so there `sqlite_bind_value` refuses it.
function add_parameter!(pq::PormGPostgresParam, value::Sockets.IPAddr; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  return add_parameter!(pq, Models.format_inet_sql(value); contains=contains, operator=operator, sql_type=sql_type)
end

# --- SQLInstruction convenience (works for both backends) ---
add_parameter!(instruc::SQLInstruction, value::Any; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing) = add_parameter!(instruc.parameters, value; contains=contains, operator=operator, sql_type=sql_type)

# ─────────────────────────────────────────────────────────────────────────────
# get_final_parameters – return the parameters in correct SQL clause order
# ─────────────────────────────────────────────────────────────────────────────
"""
    get_final_parameters(p::AbstractPormGParam) -> Vector{Any}

Return all collected parameter values in the order expected by the final SQL string.

- **PostgreSQL**: returns the single linear vector (order already matches `\$N` numbering).
- **SQLite**: concatenates buckets in standard SQL clause order, single-sourced from
  `_BUCKET_ORDER`: `cte → select → update → join → where → group → having → order → limit`
  so that each positional `?` aligns with its value.
"""
get_final_parameters(p::PormGPostgresParam)::Vector{Any} = p.parameters isa Vector{Any} ? p.parameters : collect(p.parameters)

function get_final_parameters(p::PormGSQLiteParam)::Vector{Any}
  # Driven from `_BUCKET_ORDER` rather than a second hand-written list. #432 added a consumer of
  # that same order (`detach_nested_run!`, which sorts a nested render's values into the order their
  # markers appear), and two copies of a clause order that must agree is exactly the drift a new
  # bucket would introduce silently.
  #
  # `sizehint!` then `append!`, NOT `reduce(vcat, …)` and not a bare `append!` loop. Both of those
  # re-copy while the result grows — reduce once per bucket, the bare loop on each geometric
  # reallocation. This is a property getter (`Base.getproperty(…, :parameters)`) read on every
  # execution path, so the cost lands per query.
  #
  # Measured warm — cold, every variant reads as ~200ms and the differences vanish into compilation
  # noise, which is how a bogus "44x" figure was produced once. At 50_000 bound parameters
  # (reachable: `filter("id__@in" => 1:50_000)` binds exactly that), 50 calls: this ~6.8ms,
  # hardcoded vcat ~7.7ms, reduce(vcat) ~16ms, bare append! loop ~33ms. At a REALISTIC 17 params
  # over 200_000 calls it is ~0.30µs/call against hardcoded's ~0.14µs — about 2x worse per call, and
  # 0.15µs next to a database round trip is not worth a second copy of the clause order.
  total = 0
  for ctx in _BUCKET_ORDER
    total += length(_bucket_for(p, ctx))
  end
  out = Any[]
  sizehint!(out, total)
  for ctx in _BUCKET_ORDER
    append!(out, _bucket_for(p, ctx))
  end
  return out
end

# Legacy compatibility: `.parameters` property access for SQLite
# Many places in the codebase access `params.parameters` directly.
# For SQLite with buckets, we provide this via `get_final_parameters`.
# We define a custom `getproperty` so that `sq.parameters` returns the
# concatenated vector in correct SQL order.
function Base.getproperty(sq::SQLiteParameterizedQuery, name::Symbol)
  if name === :parameters
    return get_final_parameters(sq)
  elseif name === :parameter_count
    # Computed property: sum of all bucket lengths — driven from `_BUCKET_ORDER` so a bucket added
    # there is counted here without a second hand-written list (#587 added two).
    total = 0
    for ctx in _BUCKET_ORDER
      total += length(_bucket_for(sq, ctx))
    end
    return total
  else
    return getfield(sq, name)
  end
end

function Base.hasproperty(::SQLiteParameterizedQuery, name::Symbol)
  return name in (:sql, :cte_params, :select_params, :update_params, :join_params, :where_params,
                  :group_params, :having_params, :order_params, :limit_params, :current_context, :parameter_count, :parameters)
end

# ─────────────────────────────────────────────────────────────────────────────
# _fork_parameters – a fresh collector that starts from an existing one's bindings (#73)
#
# `bulk_update` re-runs one statement per chunk, and every chunk must carry the same fixed prefix:
# the static-filter WHERE values `build()` bound, which on PostgreSQL also pins the `$1…$k` numbering
# already baked into `instruction._where`. The loop used to accumulate each chunk's rows into the
# built collector and rewind it with `deepcopy` of a snapshot at every chunk boundary — a rewind a
# row that threw mid-chunk never reached. A fork instead leaves the source untouched by construction:
# only the containers are new, and the bound VALUES are shared, because nothing mutates a value once
# `add_parameter!` has pushed it. That also keeps a large `__@in` filter list from being deep-copied
# once per chunk.
# ─────────────────────────────────────────────────────────────────────────────
_fork_parameters(pq::PgParameterizedQuery) =
  PgParameterizedQuery(pq.sql, collect(Any, pq.parameters), pq.parameter_count)

function _fork_parameters(sq::SQLiteParameterizedQuery)
  fork = SQLiteParameterizedQuery(sq.sql, sq.current_context)
  # Every slot `_BUCKET_ORDER` names, so a bucket added there is forked here without a second list.
  for ctx in _BUCKET_ORDER
    slot = Symbol(ctx, :_params)
    setfield!(fork, slot, copy(getfield(sq, slot)))
  end
  return fork
end

# Deep copy support – `deepcopy` of a query or an instruction reaches the collector through the
# generic walk; `test_parameters.jl` pins that the copy's buckets are independent.
function Base.deepcopy_internal(sq::SQLiteParameterizedQuery, stackdict::IdDict)
  haskey(stackdict, sq) && return stackdict[sq]::SQLiteParameterizedQuery
  new_sq = SQLiteParameterizedQuery(sq.sql, sq.current_context)
  # Copy each bucket — every slot `_BUCKET_ORDER` names, so a bucket added there is copied here.
  for ctx in _BUCKET_ORDER
    slot = Symbol(ctx, :_params)
    setfield!(new_sq, slot, Base.deepcopy_internal(getfield(sq, slot), stackdict))
  end
  # parameter_count is now computed from bucket lengths — no need to copy
  stackdict[sq] = new_sq
  return new_sq
end
