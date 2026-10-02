
function _show_query_result(mode::Symbol, sql::String, connection::Union{Nothing, PormGPostgres, PormGSQLite}, model::Union{PormGModel, String}, operation::Symbol;
                          parameters::Union{Nothing, AbstractPormGParam} = nothing)
  
  if mode === :none
    return nothing # Zero-allocation mode for benchmarking the builder
  elseif mode === :sql
    return sql # Simplicity: just the SQL string (fast benchmarking)
  elseif mode === :execute
    # Safety check: this function shouldn't be called with :execute,
    # but we return SQL just in case to avoid a crash.
    return sql
  end

  # Resolve model name
  model_name = model isa PormGModel ? model.name : String(model)

  # For formats requiring parameters, prepare the list
  params_list = if parameters === nothing
    []
  elseif hasproperty(parameters, :parameters)
    parameters.parameters
  else
    # Fallback for AbstractPormGParam if it doesn't have .parameters field
    []
  end
  
  if mode === :params
    return params_list
  elseif mode === :dict || mode === :inspection
    # Rich metadata format used by inspect_query() or advanced debugging
    dialect = connection isa PormGPostgres ? :postgresql : :sqlite
    bucketing = connection isa PormGPostgres ? :numbered : :positional
    
    bucket_breakdown = Dict{Symbol, Vector{Any}}()
    if parameters isa PormGSQLiteParam
       bucket_breakdown = Dict(
        :cte => parameters.cte_params,
        :select => parameters.select_params,
        :update => parameters.update_params,
        :join => parameters.join_params,
        :where => parameters.where_params,
        :group => parameters.group_params,
        :having => parameters.having_params,
        :order => parameters.order_params
      )
    end

    return Dict(
        :sql_text => sql, 
        :parameters => params_list,
        :dialect => dialect,
        :model => model_name,
        :operation => operation,
        :bucketing => bucketing,
        :parameter_count => length(params_list),
        :parameter_buckets => bucket_breakdown
    )
  else
    throw(QueryBuildError("Invalid show_query mode: $mode. Must be one of: :sql, :dict, :inspection, :params, :none"))
  end
end

"""
    inspect_query(q::SQLObjectHandler) -> Dict

Comprehensive query inspection API that provides full metadata about a query without executing it.
Returns a rich dictionary with SQL, parameters, dialect information, and structural metadata.

This is the explicit API for query inspection - use this when you want to examine a query's structure
and generated SQL without ambiguity.

# Arguments
- `q::SQLObjectHandler`: The query object to inspect
- `operation::Union{Nothing, Symbol} = nothing`: Optional operation override (:select, :insert, :update, :delete).
  If not provided, the operation is detected automatically based on the query structure.

# Returns
- `Dict`: A dictionary containing:
  - `:sql_text` (String): The generated SQL query
  - `:parameters` (Vector): The parameterized values in bucket order
  - `:dialect` (Symbol): The database dialect (`:postgresql` or `:sqlite`)
  - `:model` (String): The model/table name
  - `:operation` (Symbol): The query operation type (`:select`, `:insert`, `:update`, `:delete`).
    A cascading `:delete` returns a Vector of steps; on PostgreSQL that Vector starts with one
    `:lock` step (`SELECT … FOR UPDATE`) per parent model (#770)
  - `:bucketing` (Symbol): The parameter bucketing strategy (`:numbered` for PostgreSQL, `:positional` for SQLite)
  - `:parameter_count` (Int): Number of parameters
  - `:parameter_buckets` (Dict): Breakdown of parameters by bucket (for positional strategies)

# Example
```julia
q = M.Driver.objects
q.filter("nationality" => "British")
q.order_by("surname")

inspection = q |> inspect_query()
# Dict with:
# :sql_text => "SELECT ... WHERE drivers.nationality = \$1 ORDER BY ..."
# :parameters => ["British"]
# :dialect => :postgresql
# :model => "drivers"
# :operation => :select
# :bucketing => :numbered
```
"""
function inspect_query(q::SQLObjectHandler; connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, operation::Union{Nothing, Symbol} = nothing)
  # #43: inspection must not mutate the caller. The dry-runs below (query/insert/update)
  # write back onto the handler they build — q.object.parameters, the transient CTE "model"
  # into q.object.ctes, and update()'s auto-now fields into q.object.insert. Build on a copy
  # so inspect_query() matches the execution read path (query_list), which already copies.
  q = deepcopy(q)

  # Force builder to run without execution
  # We reuse the internal query building logic
  settings, conn, conn_key = get_settings(q, connection=connection)
  
  # 1. Operation detection heuristic
  if operation === nothing
    if !isempty(q.object.insert)
      # If it has data in the 'insert' field, it's either an INSERT or an UPDATE.
      # UPDATE typically has filters (WHERE), INSERT typically does not.
      operation = isempty(q.object.filter) ? :insert : :update
    else
      # Default to :select (safe, most common)
      # Note: :delete is ambiguous with :select if only filters are present,
      # so it must be explicitly requested via inspect_query(operation=:delete)
      operation = :select
    end
  end
  
  # 2. Delegate to appropriate dry-run
  if operation === :select
      return query(q, show_query=:inspection, connection=conn)
  elseif operation === :insert
      return insert(q.object, show_query=:inspection, connection=conn)
  elseif operation === :update
      return update(q.object, show_query=:inspection, connection=conn)
  elseif operation === :delete
      res = delete(q, show_query=:inspection, connection=conn)
      # delete() returns (total_deleted, counter_dict) when executing.
      # In inspection mode it returns a single Dict (simple delete) or a
      # Vector of Dicts (cascaded delete with SET_NULL / SET_DEFAULT / CASCADE
      # steps).  Return the result as-is so callers can inspect every step.
      return res isa Tuple ? res[2] : res
  else
      throw(QueryBuildError("Unsupported or unknown operation for inspection: $operation"))
  end
end
inspect_query(; kwargs...) = (objct) -> inspect_query(objct; kwargs...)

function query(q::SQLObjectHandler; 
  table_alias::Union{Nothing, SQLTableAlias} = nothing,
  connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing,
  parameters::Union{Nothing, AbstractPormGParam} = nothing,
  cte::Union{Nothing, CTEDict} = nothing,
  outer::Union{Nothing, SQLInstruction} = nothing,
  show_query::Symbol = :execute,
  # #432: opt-in for a nested render that will re-emit its own parameters as one clause-ordered run
  # (see `detach_nested_run!`). A subquery normally suppresses context switching so it cannot clobber
  # the parent's active bucket — but that also means its values are filed under the PARENT's clause
  # rather than their own, which is exactly the information the run needs to sort itself into text
  # order. `query()` restores the ambient bucket itself below (the `is_subquery` branch), so a
  # caller passing this does NOT need to — and none of them does. Do not delete that restore on the
  # assumption the caller handles it: the failure would be silent and SQLite-only.
  own_contexts::Bool = false
  )

  @pormg_debug false

  # Create a shared table alias counter for both CTEs and main query
  table_alias === nothing && (table_alias = SQLTbAlias())
  
  settings, connection, conn_key = get_settings(q, connection=connection)

  # Track if this is a subquery
  is_subquery = parameters !== nothing
  # #432: `own_contexts` keeps the shared collector (PostgreSQL still needs one sequential `$N`
  # counter) while letting the inner build file its values under its OWN clauses.
  set_own_contexts = own_contexts || !is_subquery

  # IMPORTANT: Create the shared parameters object BEFORE building CTEs
  # This ensures all CTEs and the main query use sequential parameter numbering
  if parameters === nothing
    parameters = get_parameter(connection)
  end

  # Save current context for backends that use positional buckets (SQLite)
  # This is crucial for nested subqueries to avoid clobbering the parent's bucket.
  old_context = parameters isa PormGSQLiteParam ? parameters.current_context : nothing

  # Build WITH clause - passes the SAME parameters object
  # CTE context is set inside build_cte_clause
  !is_subquery && set_context!(parameters, :cte)
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)  

  @pormg_debug false

  # Main query uses the SAME parameters object (will continue numbering from where CTEs left off)
  # Context switching for select/where/join happens inside build()
  # Subqueries skip context switching to inherit the parent's current bucket.
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters, set_contexts=set_own_contexts, outer=outer)
  
  # Prevent SELECT * across JOINs which causes DataFrame column collisions downstream.
  # Only enforce during actual execution (:execute) — inspection/dry-run modes (:dict, :sql,
  # :inspection, etc.) must be allowed to build joined queries without .values() so that
  # inspect_query() and show_query=:dict work on un-projected joined queries.
  if isempty(q.object.values) && !isempty(instruction.join) && show_query === :execute
    throw(QueryBuildError("PormG: Joined queries must explicitly select fields using .values(...) to prevent duplicate column names. Tip: Use .values(\"*\", \"joined_model__field_name\") to select all main table fields alongside specific joined fields."))
  end

  # Restore the context for parent query if this was a subquery
  if is_subquery && old_context !== nothing
    set_context!(parameters, old_context)
  end
  if cte !== nothing
    @pormg_debug false
    _build_cte_custom_model(cte, instruction)
  end
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)  
  
  io = IOBuffer()
  print(io, with_clause)
  print(io, "SELECT\n    ")
  if q.object.distinct
    print(io, "DISTINCT ")
  end
  print(io, _query_select(instruction.select, instruction.connection))
  print(io, "\nFROM ", safe_table_name, " as ", safe_alias, "\n")
  
  for j in instruction.join
    print(io, j, "\n")
  end

  if !isempty(instruction._where)
    print(io, "WHERE ")
    for (i, w) in enumerate(instruction._where)
      i > 1 && print(io, " AND \n   ")
      print(io, w)
    end
    print(io, "\n")
  end
  
  if instruction.aggregate && !isempty(instruction.group)
    print(io, "GROUP BY ")
    for (i, g) in enumerate(instruction.group)
      i > 1 && print(io, ", ")
      print(io, g)
    end
    print(io, " \n")
  end
  
  if !isempty(instruction.having)
    print(io, "HAVING ")
    for (i, h) in enumerate(instruction.having)
      i > 1 && print(io, " AND \n   ")
      print(io, h)
    end
    print(io, "\n")
  end
  
  if !isempty(instruction.order)
    print(io, "ORDER BY ")
    for (i, o) in enumerate(instruction.order)
      i > 1 && print(io, ", \n  ")
      print(io, o)
    end
    print(io, "\n")
  end
  
  if q.object.limit !== 0
    print(io, "LIMIT ", q.object.limit, " \n")
  end
  
  if q.object.offset !== 0
    print(io, "OFFSET ", q.object.offset, " \n")
  end

  # #26: row-level locking clause (FOR UPDATE …) must follow ORDER BY / LIMIT / OFFSET. No-op on
  # SQLite (Dialect.for_update_clause renders "" there). PostgreSQL rejects FOR UPDATE with
  # DISTINCT, so fail early with a friendly message rather than a raw DB error.
  let fu = q.object.for_update
    if fu !== nothing
      # PostgreSQL rejects FOR UPDATE + DISTINCT; fail early with a friendly message. SQLite is
      # exempt — there the lock renders "" (pure no-op), so select_for_update never raises (#26).
      if q.object.distinct && instruction.connection isa PormGPostgres
        throw(QueryBuildError("select_for_update() cannot be combined with distinct() — a locking read must return concrete rows."))
      end
      print(io, Dialect.for_update_clause(fu.nowait, fu.skip_locked, fu.no_key, instruction.connection))
    end
  end

  resposta = String(take!(io))

  # #44: warn once per CTE that is CROSS JOINed (no join_field) yet is never constrained by a
  # WHERE/HAVING predicate — that is an unintended Cartesian product. The correlation is expected
  # to come from a `filter("main_col" => F("<cte>__col"))` (which renders in WHERE). No false
  # positive on the intended usage, where the alias appears in the WHERE fragment.
  if any(rj -> rj isa CrossJoin, instruction.row_join)
    predicate_text = string(
      isempty(instruction._where) ? "" : join(instruction._where, " AND "),
      isempty(instruction.having) ? "" : join(instruction.having, " AND "),
    )
    for rj in instruction.row_join
      rj isa CrossJoin || continue
      cte_alias = rj.alias_b
      if !occursin("\"$(cte_alias)\"", predicate_text)
        @warn _emsg("PormG: CTE \e[31m$(rj.b)\e[0m is CROSS JOINed with no correlating filter — this is a Cartesian product. Add a correlation such as \e[32mfilter(\"main_col\" => F(\"$(rj.b)__col\"))\e[0m, or pass \e[32mjoin_field=\e[0m to .with().")
      end
    end
  end

  # Store the final parameters object with all CTEs + main query parameters
  q.object.parameters = instruction.parameters
  # #564 — and what each result column IS, for the read path. Written back beside `parameters` for
  # the same reason: both are per-build artifacts the caller needs after the build has finished.
  q.object.projection_kinds = instruction.projection_kinds

  if show_query !== :execute
    return _show_query_result(show_query, resposta, instruction.connection, q.object.model.name, :select;
                            parameters=instruction.parameters)
  end
  # #26: a locked read executed OUTSIDE a transaction on PostgreSQL is a footgun — the lock is
  # taken then immediately released at autocommit. Fail loudly (Django's TransactionManagementError
  # analog). Guarded on the execute path only, so inspect_query/show_query still render FOR UPDATE
  # without a live transaction. SQLite never locks (clause rendered ""), so it is exempt.
  # The transaction must be on the pool this read runs on (#831): a transaction open on another
  # database does not hold this lock. Inside one, `build`'s `ensure_transaction_scope` already
  # refuses a read routed to a pool with no transaction (#838), so what reaches here unguarded is
  # a read with no transaction open anywhere.
  if q.object.for_update !== nothing && instruction.connection isa PormGPostgres &&
     transaction_connection_for(instruction.connection) === nothing
    throw(QueryBuildError("select_for_update() must run inside a transaction (run_in_transaction/atomic) on PostgreSQL; otherwise the row lock is released immediately at autocommit."))
  end
  return resposta
end
"""
    show_query(q::SQLObjectHandler, mode::Symbol = :sql)

Render a `SELECT` query without executing it. The default `:sql` mode returns just the SQL string,
which makes it the quickest way to see what a chain builds.

| `mode` | Returns |
|--------|---------|
| `:sql` | `String` — the generated SQL |
| `:params` | `Vector` — the parameterized values, in bucket order |
| `:dict` / `:inspection` | `Dict` — the full metadata shape of [`inspect_query`](@ref) |
| `:none` | `nothing` — builds and discards, for benchmarking the builder |

```julia
query = M.Driver.objects.filter("nationality" => "British").values("forename", "surname")

println(show_query(query))              # SELECT "Tb"."forename" … WHERE "Tb"."nationality" = \$1
params = show_query(query, :params)     # ["British"]
```

Inspection builds on a `deepcopy`, so it never mutates the query you pass (#43) — the same chain
can be inspected and then executed.

For `INSERT`/`UPDATE`/`DELETE`, pass `show_query=` to the terminal method itself
(`query.delete(show_query = :sql)`); this function always renders a `SELECT`. Use
[`inspect_query`](@ref) when you want the metadata `Dict` with an explicit operation override.
"""
show_query(q::SQLObjectHandler, mode::Symbol = :sql) = query(deepcopy(q); show_query=mode)

# ---
# Count or check if exists
#

function _count(oq::SQLObjectHandler; column::Union{Nothing, AbstractString} = nothing, distinct::Bool = false,
                  table_alias::Union{Nothing, SQLTableAlias} = nothing, show_query::Symbol = :execute)
  # Column form: COUNT([DISTINCT] column). Reuse the Count() aggregate so column
  # resolution, joins and dialect rendering are shared with values(Count(...)); we
  # return the scalar rather than a row. COUNT(DISTINCT col) is valid SQL (unlike
  # COUNT(DISTINCT *)), so no subquery is needed for this form.
  if column !== nothing
    cq = deepcopy(oq)
    cq.object.order = []
    cq.object.distinct = false      # DISTINCT belongs to COUNT(col), not the row set
    cq.object.limit = 0
    cq.object.offset = 0
    # No `__` in the alias: `_values!` refuses one (#757). The result is read positionally below.
    _values!(cq.object, Any["pormg_count" => Count(String(column); distinct = distinct)])
    show_query !== :execute && return query(cq; table_alias = table_alias, show_query = show_query)
    rows = list(cq, Val(:dict))
    return isempty(rows) ? 0 : Base.first(values(Base.first(rows)))
  end

  # Resolve settings
  settings, connection, conn_key = get_settings(oq)
  
  q = deepcopy(oq) # Create a copy of the SQLObjectHandler to avoid modifying the original object  
  q.object.order = []# clear order_by
  q.object.values = [] # clear values

  # Create shared table alias and parameters BEFORE building CTEs
  # so CTE parameters are numbered first (critical for positional backends).
  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters = get_parameter(connection)

  # Build WITH clause first — CTE params land in :cte bucket before main params.
  set_context!(parameters, :cte)
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

  # Main query continues from where CTE numbering left off.
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  
  # Shared FROM / JOIN / WHERE / GROUP BY body for both count forms.
  body = """FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    $(instruction.aggregate ? "GROUP BY $(join(instruction.group, ", ")) \n" : "")
    """
  if distinct || q.object.distinct
    # COUNT(DISTINCT *) is invalid SQL in both PostgreSQL and SQLite. To count the rows a
    # DISTINCT select would return, wrap `SELECT DISTINCT *` in an outer COUNT(*) so that
    # count() == length(distinct list()). Any CTEs stay at the top level and remain in
    # scope for the subquery; parameter order/count is unchanged by the wrapping.
    resposta = """$(with_clause)SELECT COUNT(*) FROM (
    SELECT DISTINCT *
    $body) as "__pormg_distinct_count"
    """
  else
    resposta = """$(with_clause)SELECT
      COUNT(*)
    $body"""
  end
  # Inspection short-circuit: return SQL/metadata without hitting the database.
  if show_query !== :execute
    return _show_query_result(show_query, resposta, instruction.connection, q.object.model.name, :select;
                            parameters=instruction.parameters)
  end
  query_result = fetch(settings, resposta, instruction.parameters)
  # PostgreSQL returns a LibPQ.Result that supports scalar [row, col] indexing.
  # SQLite returns a materialized rowtable (Vector{<:NamedTuple}); a Vector *also* has a
  # (Int, Int) getindex method (trailing-singleton dimension), so exclude vectors explicitly
  # and take the Tables path, which extracts the scalar from the single COUNT row.
  if !(query_result isa AbstractVector) &&
     (query_result isa AbstractMatrix || hasmethod(getindex, Tuple{typeof(query_result), Int, Int}))
    return query_result[1, 1]
  else
    row = Tables.rowtable(query_result) |> Base.first
    return Base.first(values(row))
  end
end

# Whole-queryset aggregation (#208). Django's aggregate(): compute one or more aggregate scalars
# over the ENTIRE queryset (no GROUP BY) and return them as a single-row NamedTuple keyed by alias.
# Built on the same column-form path as _count() — inject the aggregate projections via values(),
# read the single row back — but generalized to multiple aggregates and a dot-accessible result.
function _aggregate(oq::SQLObjectHandler; pairs, show_query::Symbol = :execute)
  isempty(pairs) &&
    throw(QueryBuildError("aggregate() requires at least one \"alias\" => AggregateFunction(...) pair, e.g. aggregate(\"total\" => Sum(\"points\"))."))
  # aggregate() is whole-queryset only. If the caller already projected grouping columns via
  # values(), that is a DIFFERENT operation (grouped aggregation) — refuse rather than silently
  # discard their grouping. Steer them to values(...) + list() for the grouped form.
  isempty(oq.object.values) ||
    throw(QueryBuildError("aggregate() computes a single whole-queryset result and cannot combine with values() grouping columns. Use values(...) + list() for grouped aggregation, or call aggregate() on an unprojected queryset."))

  aliases = Symbol[]
  for p in pairs
    (p isa Pair && p.first isa AbstractString) ||
      throw(QueryBuildError("aggregate() arguments must be \"alias\" => AggregateFunction(...) pairs; got $(typeof(p))."))
    val = p.second
    (val isa SQLTypeFunction && hasproperty(val, :aggregate) && getproperty(val, :aggregate) === true) ||
      throw(QueryBuildError("aggregate() value for \"$(p.first)\" must be an aggregate function (Sum/Avg/Count/Max/Min); got $(typeof(val)). For per-row expressions use values(...)."))
    push!(aliases, Symbol(p.first))
  end

  cq = deepcopy(oq)
  cq.object.order = []
  cq.object.limit = 0
  cq.object.offset = 0
  cq.object.distinct = false
  # Inject the aggregate projections through the shared values() path (column resolution, joins and
  # dialect rendering stay identical to values(Sum(...))). With ONLY aggregates projected, no
  # non-aggregate column is present, so the builder emits no GROUP BY (same as _count).
  _values!(cq.object, collect(Any, pairs))

  if show_query !== :execute
    return query(cq; show_query=show_query)
  end

  rows = list(cq, Val(:dict))
  # A SQL aggregate over an empty set still returns one row (COUNT→0, others→NULL); guard anyway.
  row = isempty(rows) ? Dict{Symbol,Any}() : Base.first(rows)
  return NamedTuple{Tuple(aliases)}(Tuple(get(row, a, nothing) for a in aliases))
end

function _exists(oq::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing, show_query::Symbol = :execute)
  try
    # Resolve settings
    settings, connection, conn_key = get_settings(oq)
    
    q = deepcopy(oq) # Create a copy of the SQLObjectHandler to avoid modifying the original object
    q.object.order = [] # clear order_by
    q.object.values = [] # clear values

    # Create shared table alias and parameters BEFORE building CTEs
    # so CTE parameters are numbered first (critical for positional backends).
    table_alias === nothing && (table_alias = SQLTbAlias())
    parameters = get_parameter(connection)

    # Build WITH clause first — CTE params land in :cte bucket before main params.
    set_context!(parameters, :cte)
    with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

    # Main query continues from where CTE numbering left off.
    instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
    limit_clause = "LIMIT 1"
    offset_clause = q.object.offset > 0 ? "OFFSET $(q.object.offset)" : ""
    
    # Quote table name and alias to prevent SQL injection
    safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
    safe_alias = quote_identifier(instruction.alias, instruction.connection)
    
    sql = """
    $(with_clause)SELECT 1
    FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(isempty(instruction._where) ? "" : "WHERE " * join(instruction._where, " AND \n   "))
    $(instruction.aggregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", "))" : "")
    $limit_clause
    $offset_clause
    """
    # Inspection short-circuit: return SQL/metadata without hitting the database.
    if show_query !== :execute
      return _show_query_result(show_query, sql, instruction.connection, q.object.model.name, :select;
                              parameters=instruction.parameters)
    end
    @pormg_debug false
    result = fetch(settings, sql, instruction.parameters) |> Tables.rowtable
    @pormg_debug false
    return length(result) > 0
  catch e
    @pormg_debug false
    # Log for observability, then rethrow unconditionally.
    # Silently returning false would mask connection failures, SQL errors, and
    # permission errors as "does not exist", which is incorrect and dangerous.
    # The only legitimate false return is from `length(result) > 0` above.
    # Names the fluent method the caller typed, not the `_exists` helper behind it — the same
    # reason the helpers are `_`-prefixed at all (#281): an internal spelling in a log line sends
    # the reader looking for something that appears nowhere in their code. Structured form per
    # AGENTS.md; `(e, catch_backtrace())` rather than a bare `e` because only the tuple form logs a
    # backtrace, matching the sibling catch in object_manager.jl.
    @error "Error in exists()" model=oq.object.model.name exception=(e, catch_backtrace())
    rethrow(e)
  end
end

# #800 — the read parser a model FIELD's values need on this connection, or `nothing`. The per-field
# twin of `_projection_parsers`: a row a write hands back carries no projection record, but its
# columns are the model's own, so the field says what each one is. `_pg_bulk_returned!` shares it.
function _field_value_parser(f::PormGField, connection)::Union{Function,Nothing}
  kind = field_canonical_kind(f)
  return kind === nothing ? nothing : value_parser(kind, connection)
end

# Build a Dict{Symbol,Any} from a result row, mapping physical column names back to the
# declared field names so callers always see field-name keys even when a field maps to a
# differently-named column via db_column (#50). No-op shape on the common path.
#
# #800: and parse each field's value through the #564 read table, as `list()` does for the same
# column. This is the row `create()` / `update_or_create` / `get_or_create` hand back (`RETURNING *`
# on PostgreSQL, the `SELECT *` read-back on SQLite), and before this it arrived exactly as the driver
# delivered it — text for every temporal column on SQLite, a bare `Period` for a one-component
# INTERVAL on Postgres.jl — so re-reading the row through a query changed its types. A key that is
# not a field (`__pormg_created`) is left alone.
function _row_to_field_keyed_dict(row, model::PormGModel, connection)::Dict{Symbol,Any}
  dict = if !Models.model_has_db_column(model)
    Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row))
  else
    rev = Dict{String,Symbol}(Models.field_db_column(f, string(k)) => Symbol(k) for (k, f) in model.fields)
    Dict{Symbol,Any}(get(rev, string(k), Symbol(k)) => v for (k, v) in pairs(row))
  end
  for (fname, f) in model.fields
    key = Symbol(fname)
    haskey(dict, key) || continue
    parser = _field_value_parser(f, connection)
    parser === nothing || (dict[key] = parser(dict[key]))
  end
  return dict
end

# Shared row-level INSERT marshalling, extracted from insert() (#30) so insert() and
# _update_or_create() build the identical VALUES body from one place. Fills each missing field
# (default → auto_now/auto_now_add → UUID → skip-if-null-or-pk → else error), reserves a SQLite id
# when the transaction pre-allocated one, then validates every field and collects the quoted physical
# columns and bound params. MUTATES `real_obj.insert` (fills) and `parameters` (binds). Returns
# (quoted_field_columns, param_values, pk_exist, pk_field). The change_data guard stays with the
# caller so it fires before any fill.
function _prepare_row_insert!(real_obj, model::PormGModel, settings, connection, parameters)
  fields = model.field_names

  # check if the fields are in objct.insert
  for field in fields
    if !haskey(real_obj.insert, field)
      # check if field allow null or if exist a default value
      if model.fields[field].default !== nothing
        real_obj.insert[field] = model.fields[field].default
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formatter(now(TimeZone(settings.time_zone)))
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formatter(today())
      elseif model.fields[field].type == "UUID" && model.fields[field].auto_add
        real_obj.insert[field] = model.fields[field].formatter(UUIDs.uuid4())
      elseif model.fields[field].null || model.fields[field].primary_key
        continue
      else
        throw(InvalidValueError("Error in insert, the field \e[4m\e[31m$(field)\e[0m not allow null"))
      end
    end
  end

  # SQLite reservation handling: if this transaction already pre-allocated ids for the
  # table, consume the next id explicitly instead of relying on AUTOINCREMENT.
  if connection isa PormGSQLite
    auto_pk_fields = [field for field in fields if _is_auto_generated_bulk_primary_key(model.fields[field])]
    if length(auto_pk_fields) == 1
      pk_name = auto_pk_fields[1]
      reserved_max = get_sqlite_reserved_primary_key_max(model, pk_name, connection)
      if reserved_max !== nothing && !haskey(real_obj.insert, pk_name)
        reserved_id = _allocate_sqlite_ids(model, connection, pk_name, 1, settings)[1]
        real_obj.insert[pk_name] = reserved_id
      end
    end
  end

  quoted_field_columns = []
  param_values = []
  pk_exist::Bool = false
  pk_field::Vector{String} = []
  for field in keys(real_obj.insert)
    # Validation checks
    validate_field_data(model, field, real_obj.insert[field], "insert"; allow_primary_key = true)
    Models.is_many_to_many_field(model.fields[field]) && throw(QueryBuildError("ManyToManyField $(model.name).$(field) cannot be written in create(); use $(model.name).$(field)(source_id).add(target_id) after creating the source row"))

    # check if the field is a primary key
    model.fields[field].primary_key && (pk_exist = true; push!(pk_field, field))

     # Add safely quoted physical column (db_column when set) to columns list (#50)
    push!(quoted_field_columns, safe_column_identifier(Models.field_db_column(model.fields[field], field), connection))

    # Format and add value to parameters — one value, never a collection (#712)
    formatted = _format_single(model.fields[field], field, real_obj.insert[field], "insert")
    push!(param_values, add_parameter!(parameters, formatted))

  end

  return quoted_field_columns, param_values, pk_exist, pk_field
end

function insert(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, show_query::Symbol = :execute)
real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
  ensure_transaction_scope(model, connection)
  
  # Collect column names and parameter values
  parameters = get_parameter(connection)
  # For INSERT, all params go into :select bucket (VALUES clause is the only positioned section)
  set_context!(parameters, :select)

  # check if is allowed to insert
  !settings.change_data && throw(_write_not_allowed("insert", conn_key))

  # Fill defaults/auto_now/auto_now_add/UUID, reserve SQLite ids, validate, and collect the quoted
  # physical columns + bound VALUES params. Shared with _update_or_create (#30) so both build the
  # identical INSERT body from one place.
  quoted_field_columns, param_values, _, _ =
    _prepare_row_insert!(real_obj, model, settings, connection, parameters)

  # construct the SQL statement
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  sql = """
  INSERT INTO $(safe_table_name) (
    $(join(quoted_field_columns, ", "))
  ) VALUES (
    $(join(param_values, ", "))
  )
  """

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model.name, :insert; 
                            parameters=parameters)
  end

  # Execute safely. create()/insert() return a PormGRow (#166) — the same object get()/first()/
  # list()/update_or_create() return — so a created row supports dot-access and create → mutate →
  # .save(). `_row_to_field_keyed_dict` still builds the Dict; we wrap it. RETURNING */SELECT *
  # include every column (incl. the pk), so the row is .save()-able; `_dirty` starts empty.
  if connection isa PormGPostgres
    result = fetch(settings, sql * " RETURNING *;", parameters)
    # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
    # write supplied an explicit primary key.
    return PormGRow(_row_to_field_keyed_dict(Tables.rowtable(result) |> Base.first, model, connection), model)
  elseif connection isa PormGSQLite
    # SQLite: deliberately avoid `INSERT ... RETURNING *`. RETURNING can hang
    # indefinitely inside SQLite/libsqlite3 for some table shapes (observed: an
    # AUTOINCREMENT primary key that migrations left in a non-first column
    # position). The previous broad `catch` masked that hang/error by re-running a
    # plain INSERT, which then tripped a spurious UNIQUE violation because the
    # first INSERT had already written the row. Instead: run a plain INSERT, then
    # read the full inserted row back with a SELECT on the SAME connection
    # (last_insert_rowid() is per-connection session state). Reading the whole row
    # keeps the returned row consistent with the Postgres `RETURNING *` path —
    # all columns present, including nullable ones the caller did not set.
    #
    # The empty-rows fallback (read-back returned nothing, which should not happen after a
    # successful INSERT) builds the dict from real_obj.insert only, so it may omit an unreserved
    # AUTOINCREMENT pk, and its values are the caller's inputs, not parsed reads (#800 types only a
    # row the database handed back). The wrapped PormGRow is still returned; if that degenerate row is later
    # mutated and .save()d, save() throws a clear "required key" error — no regression over the
    # previous incomplete-Dict return.
    do_insert = () -> begin
      fetch(settings, sql, parameters)
      rows = fetch(settings,
        "SELECT * FROM $(safe_table_name) WHERE rowid = last_insert_rowid();") |> Tables.rowtable
      isempty(rows) ?
        Dict{Symbol, Any}(Symbol(k) => v for (k, v) in pairs(real_obj.insert)) :
        _row_to_field_keyed_dict(rows[1], model, connection)
    end

    # INSERT and the row read-back must run on one connection (last_insert_rowid()
    # is per-connection). Reuse the active transaction if there is one; otherwise
    # pin a connection for the pair.
    result_dict = transaction_connection_for(settings) !== nothing ?
      do_insert() : run_in_transaction(do_insert, settings)

    # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
    # write supplied an explicit primary key.
    return PormGRow(result_dict, model)
  else
    throw(_unsupported_conn("insert()", connection))
  end

end

# Row-level upsert (#30) behind `objects.update_or_create`. Builds the same INSERT body as insert()
# via _prepare_row_insert!, appends `ON CONFLICT (target) DO UPDATE SET set…` (reusing #123's
# Dialect.on_conflict_clause), and returns `(PormGRow, created::Bool)`.
#
# `target_fields` (the lookup keys) and `set_fields` (defaults + auto_now) are LOGICAL field names,
# resolved to quoted physical columns here (like bulk_insert). Caller (_update_or_create!) has
# already merged lookup+defaults into real_obj.insert and validated the fields.
#
# created detection per backend:
#   PostgreSQL — single atomic `... RETURNING *, (xmax = 0) AS "__pormg_created"`; xmax = 0 ⇒ inserted.
#   SQLite     — RETURNING is avoided (see insert()) and last_insert_rowid() is unreliable on DO
#                UPDATE, so: pre-check existence by the target, run the upsert, read the row back by
#                the target — all on one pinned connection under BEGIN IMMEDIATE + the writer lock,
#                which serializes writers so `existed` is race-free.
function _update_or_create(objct::SQLObject; target_fields::Vector{String},
    set_fields::Vector{String}, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model

  settings, connection, conn_key = get_settings(objct)
  ensure_transaction_scope(model, connection)

  parameters = get_parameter(connection)
  set_context!(parameters, :select)

  !settings.change_data && throw(_write_not_allowed("update_or_create", conn_key))

  quoted_field_columns, param_values, _, _ =
    _prepare_row_insert!(real_obj, model, settings, connection, parameters)

  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)

  # Logical → quoted physical (db_column-aware), exactly as bulk_insert renders its clause.
  qtarget = String[safe_column_identifier(Models.model_column(model, f), connection) for f in target_fields]
  qset    = String[safe_column_identifier(Models.model_column(model, f), connection) for f in set_fields]
  clause  = Dialect.on_conflict_clause(:update, qtarget, qset, connection)

  sql = """
  INSERT INTO $(safe_table_name) (
    $(join(quoted_field_columns, ", "))
  ) VALUES (
    $(join(param_values, ", "))
  )
  $(clause)
  """

  if connection isa PormGPostgres
    # Atomic upsert; `(xmax = 0)` distinguishes the inserted vs updated tuple version.
    exec_sql = sql * " RETURNING *, (xmax = 0) AS \"__pormg_created\";"
    if show_query !== :execute
      return _show_query_result(show_query, exec_sql, connection, model.name, :insert; parameters=parameters)
    end
    result = fetch(settings, exec_sql, parameters)
    dict = _row_to_field_keyed_dict(Tables.rowtable(result) |> Base.first, model, connection)
    # Strip the sentinel so it isn't a phantom field; fail safe (false) if it is ever absent.
    created_raw = pop!(dict, Symbol("__pormg_created"), false)
    created = created_raw === true || created_raw == 1   # always a Bool (xmax = 0 → PG boolean)
    # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
    # write supplied an explicit primary key.
    return (PormGRow(dict, model), created)

  elseif connection isa PormGSQLite
    if show_query !== :execute
      # Honest to what executes: INSERT + ON CONFLICT, no RETURNING (created detection is out-of-band).
      return _show_query_result(show_query, sql, connection, model.name, :insert; parameters=parameters)
    end

    # Conflict-target WHERE on the physical target columns. The placeholder is a positional `?`
    # (this branch is SQLite-only), so the WHERE text is stable and is built once; the pre-check and
    # read-back each bind a FRESH parameter object (no cross-fetch reuse). The bound values are the
    # formatted lookup values — matching exactly what the INSERT bound.
    target_where = join(
      ["$(safe_column_identifier(Models.model_column(model, f), connection)) = ?" for f in target_fields],
      " AND ")
    precheck_sql = "SELECT 1 FROM $(safe_table_name) WHERE $(target_where) LIMIT 1;"
    readback_sql = "SELECT * FROM $(safe_table_name) WHERE $(target_where) LIMIT 1;"
    make_target_params = () -> begin
      tp = get_parameter(connection)
      set_context!(tp, :where)
      for f in target_fields
        add_parameter!(tp, real_obj.insert[f] |> model.fields[f].formatter)
      end
      tp
    end

    do_upsert = () -> begin
      existed = !isempty(fetch(settings, precheck_sql, make_target_params()) |> Tables.rowtable)
      fetch(settings, sql, parameters)
      rows = fetch(settings, readback_sql, make_target_params()) |> Tables.rowtable
      dict = isempty(rows) ?
        Dict{Symbol, Any}(Symbol(k) => v for (k, v) in pairs(real_obj.insert)) :
        _row_to_field_keyed_dict(rows[1], model, connection)
      (dict, !existed)
    end

    # Pre-check + upsert + read-back must share one connection under one BEGIN IMMEDIATE.
    dict, created = transaction_connection_for(settings) !== nothing ?
      do_upsert() : run_in_transaction(do_upsert, settings)

    # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
    # write supplied an explicit primary key.
    return (PormGRow(dict, model), created)
  else
    throw(_unsupported_conn("update_or_create()", connection))
  end
end

# A missing unique constraint on the ON CONFLICT target surfaces as a driver error at execution
# ("no unique or exclusion constraint matching the ON CONFLICT specification" on PostgreSQL; "ON
# CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint" on SQLite). Re-raise it as an
# actionable PormGError — this is the one place a Django user is surprised, because Django's
# get_or_create does SELECT-then-INSERT and needs no unique constraint (#208).
function _rethrow_conflict_target_error(e, model::PormGModel, target_fields::Vector{String})
  msg = sprint(showerror, e)
  low = lowercase(msg)
  if occursin("on conflict", low) && (occursin("unique", low) || occursin("exclusion", low) ||
      occursin("does not match", low) || occursin("no primary key", low))
    throw(QueryBuildError(
      "get_or_create on $(model.name) requires a UNIQUE constraint on the lookup field(s) " *
      "(\e[4m\e[31m$(join(target_fields, ", "))\e[0m) — they are the ON CONFLICT target. Add a unique " *
      "constraint/index on them, or for non-unique lookups use filter(...).first() then create(...)."))
  end
  rethrow(e)
end

# get_or_create's get() by the conflict target, unexecuted: through the fluent builder for
# dialect-correct binding, and inside a transaction on the pinned connection (same pattern as save()).
#
# A `JSONField` collection is handed to `filter()` already serialized (#717). `filter()` refuses a
# bare vector with no operator at parse time, where it has no model to tell a JSON column from a
# text one (#596's constraint), so `get_or_create("payload" => ["a", "b"])` failed before any SQL.
# As a string it takes the scalar arm and binds the exact text the miss INSERT binds, so the hit read
# matches by the same column equality as the ON CONFLICT target (and `update_or_create`): `jsonb`
# equality on PostgreSQL, the serialized text on SQLite.
function _get_or_create_lookup(model::PormGModel, target_fields::Vector{String}, target_values::AbstractDict)
  q = object(model)
  for f in target_fields
    v = target_values[f]
    if v isa _CollectionValue && _is_json_field(model.fields[f])
      v = Models.format_json_sql(v)
    end
    q.filter(f => v)
  end
  return q
end

# Django-style get_or_create (#208): match-or-insert with NO update on a hit. This is Django's own
# algorithm — get() FIRST, and only on a miss build+run the INSERT — so that columns beyond the
# lookup (NOT NULL fields with no default) are required ONLY when a row is actually created, never
# on a plain hit. `ON CONFLICT (target) DO NOTHING` on the create path is the concurrency guard: if
# a competing writer inserts the same key between our SELECT and INSERT, the insert is skipped (no
# duplicate-key crash) and we re-read the winner. Returns `(PormGRow, created::Bool)`. The lookup
# must be a UNIQUE constraint for the create path to be safe — `_rethrow_conflict_target_error`
# turns the missing-constraint driver error into an actionable message.
function _get_or_create(objct::SQLObject; target_fields::Vector{String}, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model

  settings, connection, conn_key = get_settings(objct)
  ensure_transaction_scope(model, connection)
  !settings.change_data && throw(_write_not_allowed("get_or_create", conn_key))

  # Capture the raw lookup values BEFORE any INSERT marshalling mutates real_obj.insert.
  target_values = Dict{String,Any}(f => real_obj.insert[f] for f in target_fields)

  # A collection lookup value would be refused by the INSERT on a miss, but a hit never builds one:
  # `fetch_by_target` hands it to `filter()`, which raises `FilterError` instead. Refuse it here, the
  # same way on both paths (#712). A `JSONField` collection formats to one string, so it passes, and
  # `_get_or_create_lookup` matches it by that string (#717). A non-collection value is left entirely
  # to the paths below.
  for f in target_fields
    v = target_values[f]
    v isa _CollectionValue || continue
    validate_field_data(model, f, v, "get_or_create"; allow_primary_key = true)
    _format_single(model.fields[f], f, v, "get_or_create")
  end

  fetch_by_target = () -> _get_or_create_lookup(model, target_fields, target_values).first()

  # Build the `INSERT ... ON CONFLICT (target) DO NOTHING` a MISS would run. `_prepare_row_insert!`
  # validates/fills the row and requires every NOT NULL column — so this fires (create-time) only
  # when we actually insert.
  build_insert = (parameters) -> begin
    set_context!(parameters, :select)
    quoted_field_columns, param_values, _, _ =
      _prepare_row_insert!(real_obj, model, settings, connection, parameters)
    safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
    qtarget = String[safe_column_identifier(Models.model_column(model, f), connection) for f in target_fields]
    clause  = Dialect.on_conflict_clause(:nothing, qtarget, String[], connection)
    """
    INSERT INTO $(safe_table_name) (
      $(join(quoted_field_columns, ", "))
    ) VALUES (
      $(join(param_values, ", "))
    )
    $(clause)"""
  end

  if show_query !== :execute
    # Honest to what a miss executes: the INSERT + ON CONFLICT DO NOTHING (the get() + read-back are
    # out-of-band SELECTs). Mirrors _update_or_create's inspect contract.
    parameters = get_parameter(connection)
    insert_sql = build_insert(parameters)
    return _show_query_result(show_query, insert_sql, connection, model.name, :insert; parameters = parameters)
  end

  do_goc = () -> begin
    # Hit → return the existing row WITHOUT building an INSERT (no NOT NULL columns needed).
    existing = fetch_by_target()
    existing !== nothing && return (existing, false)

    # Miss → create, guarded by ON CONFLICT DO NOTHING against a concurrent insert of the same key.
    parameters = get_parameter(connection)
    insert_sql = build_insert(parameters)

    if connection isa PormGPostgres
      exec_sql = insert_sql * " RETURNING *;"
      result = try
        fetch(settings, exec_sql, parameters)
      catch e
        _rethrow_conflict_target_error(e, model, target_fields)
      end
      rows = Tables.rowtable(result)
      if !isempty(rows)
        dict = _row_to_field_keyed_dict(Base.first(rows), model, connection)
        # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if
        # this write supplied an explicit primary key.
        return (PormGRow(dict, model), true)
      end
      # Lost the insert race → the row exists now; return the winner, created == false.
      raced = fetch_by_target()
      raced === nothing &&
        throw(QueryBuildError("get_or_create: ON CONFLICT DO NOTHING skipped the insert but the existing $(model.name) row could not be read back."))
      return (raced, false)

    elseif connection isa PormGSQLite
      try
        fetch(settings, insert_sql, parameters)         # INSERT ... ON CONFLICT DO NOTHING
      catch e
        _rethrow_conflict_target_error(e, model, target_fields)
      end
      row = fetch_by_target()
      row === nothing &&
        throw(QueryBuildError("get_or_create: insert reported success but the $(model.name) row could not be read back."))
      # Under the serialized write lock (the transaction below) no writer can interleave between the
      # miss-check and this insert, so a fetched-nothing-then-insert is always a real creation.
      # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
      # write supplied an explicit primary key.
      return (row, true)
    else
      throw(_unsupported_conn("get_or_create()", connection))
    end
  end

  # SQLite: serialize get + insert + read-back so `created` is correct and the create race-guard
  # holds. PostgreSQL's ON CONFLICT is atomic on its own; running inside an ambient tx is fine.
  if connection isa PormGSQLite
    return transaction_connection_for(settings) !== nothing ? do_goc() : run_in_transaction(do_goc, settings)
  end
  return do_goc()
end

# Escape a value for interpolation inside a single-quoted SQL literal (#59). `db_table` is
# user-supplied and deliberately not shape-validated, so an embedded `'` would otherwise close the
# literal early. A no-op for every name that does not contain one.
_sql_literal(value::AbstractString)::String = replace(String(value), "'" => "''")

# `_quote_ident_raw` moved to `sanitization.jl` with #394, where it now shares one definition of the
# escape rule with `safe_table_identifier` / `safe_column_identifier`. It stays escape-only for the
# reason it always was (#59): the identifiers reaching it come from the database catalog or from a
# model's own `db_table`, neither of which is free-form user input.
#
# Load-bearing for the unowned-sequence fallback (#344): `setval`'s first argument is `regclass`, so
# PostgreSQL re-parses it as an identifier and CASE-FOLDS any unquoted part. A catalog row reading
# `public | Db_Table_id_seq` interpolated bare becomes `public.db_table_id_seq`, which does not
# exist. `pg_get_serial_sequence` returns its answer already quoted, which is why the owned path
# never needed this.

# A model's physical table as a SQL *string literal* holding a *quoted identifier* — `'"Db_Table"'`.
# The shape both `pg_get_serial_sequence` and `to_regclass` need: each takes TEXT that it re-parses
# as an identifier, so an unquoted mixed-case name folds to lowercase and resolves to nothing (#59).
# Correct for an all-lowercase name too. The two escapes are disjoint — `_quote_ident_raw` only
# touches `"`, `_sql_literal` only `'` — so composing them cannot double-process.
_table_ident_literal(model::PormGModel)::String =
  _sql_literal(_quote_ident_raw(Models.model_table_name(model)))

function _get_owned_sequence_name(connection::PormGPostgres, model::PormGModel, field::String; ignore_tx::Bool = false)
  table_literal = _table_ident_literal(model)
  sequence_df = fetch(
    connection,
    "SELECT pg_get_serial_sequence('$(table_literal)', '$(_sql_literal(field))');";
    ignore_tx=ignore_tx,
  ) |> DataFrames.DataFrame

  if size(sequence_df, 1) == 0 || !("pg_get_serial_sequence" in names(sequence_df))
    return nothing
  end

  sequence_name = sequence_df[1, :pg_get_serial_sequence]
  return ismissing(sequence_name) || isnothing(sequence_name) ? nothing : sequence_name
end

function _update_sequence(model::PormGModel, connection::PormGPostgres, pk_field::Vector{String}, settings::PormGSettings; ignore_tx::Bool = false)
  @pormg_debug true

  # There is deliberately NO configuration gate here (#344) — do not add one back.
  #
  # `!(settings.change_db || settings.django_prefix !== nothing) && return nothing` used to sit on
  # this line, and it was a second guard for an outcome the call sites already decide. A PostgreSQL
  # sequence can only drift when the INSERT supplied an explicit primary key, and every caller
  # already tests exactly that: `pk_exist` (set in `_prepare_row_insert!` only when the insert dict
  # contains a pk field), or — in `execution_bulk.jl`'s recovery path — a duplicate-key error that
  # actually happened. So the old line could never prevent a wasted sync, only suppress a needed one.
  #
  # What it suppressed: every connection with `change_db: false` (the documented production posture)
  # and every connection built by `register_connection`, which defaults both flags off. Those
  # silently accumulated sequence drift, and the bulk duplicate-key self-heal — resync, then retry
  # the same INSERT — re-ran an unrepaired statement and failed identically.
  #
  # `settings` is still read below — but only to ask whether we are inside the caller's
  # transaction when a repair fails, never to decide whether to attempt one.
  for field in pk_field
    # Resolve the PK field to its physical column (db_column when set) — #50.
    col = Models.model_column(model, field)
    sequence_name = nothing

    # The WHOLE body is guarded, not just `setval` (#344). The two catalog reads below run on every
    # explicit-pk insert now that the gate is gone, and they can fail the same ways `setval` can —
    # a pool timeout on the extra acquisition, a connection dropped between the INSERT and the
    # resync. Outside a transaction those would otherwise raise *after* the row was durably
    # committed, which is the exact "successful create() looks failed" outcome this design avoids.
    try
      sequence_name = _get_owned_sequence_name(connection, model, col; ignore_tx=ignore_tx)

      if isnothing(sequence_name)
        # Fallback for a PK column with no OWNED sequence — a Django-managed table, or a natural
        # key. Matched on PostgreSQL's conventional `<table>_<column>_seq` and restricted to the
        # search path.
        #
        # NOT `LIKE '<table>%'`, which is what this used to be: that matches any sequence sharing
        # the prefix — `f1_driver` and `f1_driverstanding` both answer `LIKE 'f1_driver%'` — and the
        # result was unordered with row 1 taken blind, so a resync could `setval` a NEIGHBOURING
        # table's sequence to this table's MAX(pk). With `is_called=false` the victim table then
        # hands out a colliding id on its next insert. Removing the gate above made that path
        # reachable on every connection, so it is tightened here rather than left to widen.
        #
        # NOT lowercased (#59): PostgreSQL names the implicit sequence for a quoted `"Db_Table"` as
        # `Db_Table_id_seq`, and the comparison is case-sensitive — folding would match nothing.
        # Constrained to the TABLE'S OWN namespace, not merely to some schema on the search path.
        # A membership test (`schemaname = ANY(current_schemas(…))`) is not equivalent, and the gap
        # is the same corruption in schema form: with `search_path = tenant, public`, a
        # `tenant.drivers` whose own sequence is absent would match `public.drivers_id_seq` — which
        # belongs to `public.drivers` — and the `setval` below would set it from
        # `MAX(tenant.drivers.id)`, because the table in that statement is referenced unqualified.
        #
        # `to_regclass` resolves by exactly the same search_path rule as that unqualified reference,
        # so pinning the sequence to its `relnamespace` makes the two agree by construction — as
        # strict as the table, not stricter. It also yields at most one row (`relname` is unique per
        # namespace), so no ordering or tiebreak is needed. `to_regclass` returns NULL rather than
        # raising for a missing relation, so a vanished table degrades to zero rows and the
        # `continue` below.
        conventional = string(Models.model_table_name(model), "_", col, "_seq")
        seqs_df = fetch(
          connection,
          "SELECT n.nspname AS schemaname, c.relname AS sequencename " *
          "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " *
          "WHERE c.relkind = 'S' AND c.relname = '$(_sql_literal(conventional))' " *
          "AND c.relnamespace = (SELECT relnamespace FROM pg_class WHERE oid = to_regclass('$(_table_ident_literal(model))'))";
          ignore_tx=ignore_tx,
        ) |> DataFrames.DataFrame

        if size(seqs_df, 1) == 0
          # Not an error: a natural-key PK legitimately has no sequence, and `pk_exist` fires for
          # those too, so @debug rather than @warn keeps ordinary inserts quiet.
          #
          # `expected=` is what makes the other case diagnosable. PostgreSQL truncates a generated
          # object name at 63 bytes, so a table+column pair longer than that owns a sequence whose
          # real name is shorter than `conventional` and will not be found here. Logging the name we
          # searched for is the difference between a puzzling non-sync and an obvious one.
          @debug "No sequence to resync for this primary key" table=Models.model_table_name(model) column=col expected=conventional
          continue
        end
        # Quoted, not interpolated bare: `setval` takes regclass and case-folds unquoted parts, so
        # `public.Db_Table_id_seq` would be looked up as `public.db_table_id_seq` and fail.
        sequence_name = string(_quote_ident_raw(seqs_df[1, :schemaname]), ".",
                               _quote_ident_raw(seqs_df[1, :sequencename]))
      end

      safe_field_name = safe_column_identifier(col, connection)
      safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
      fetch(
        connection,
        "SELECT setval('$(_sql_literal(sequence_name))', COALESCE((SELECT MAX($safe_field_name) FROM $safe_table_name), 0) + 1, false)";
        ignore_tx=ignore_tx,
      )
    catch e
      # A cancellation is never ours to swallow. `e isa InterruptException` would NOT catch it:
      # every driver failure crosses `_as_database_error`, which wraps the interrupt in a
      # `StatementError`. `_await_abandoned` sees through that wrapper.
      #
      # This MUST stay ahead of the allowlist below, and the order is not stylistic: a cancellation
      # arrives as `StatementError(…, InterruptException())`, which IS a `DatabaseError`, so an
      # allowlist running first would swallow every Ctrl-C on this path.
      _await_abandoned(e) && rethrow()

      # Swallow ONLY what this block set out to tolerate: a failure of the database round-trip
      # itself. Widening the `try` to the whole loop body also brought `quote_identifier` and
      # `safe_table_identifier` inside it, and those are PormG's fail-closed identifier guards —
      # they raise `InvalidValueError`, which is a `PormGError` but NOT a `DatabaseError`. Reporting
      # a rejected `db_column` as "sequence resync failed, check your GRANTs" would bury the real
      # error and break the fail-closed contract.
      #
      # An allowlist, not "rethrow non-DatabaseError PormGErrors": `PoolTimeoutError <: PoolError`
      # is also outside the `DatabaseError` branch and IS one we mean to tolerate. `PoolError` is
      # the one family that reaches here un-wrapped, because `acquire_connection` runs outside
      # `fetch`'s own try and so never crosses `_as_database_error`.
      #
      # Anything raised on THIS task — a bug in this function, PormG's fail-closed identifier
      # guards — propagates. Note the limit of that claim: a failure raised inside the driver task
      # is wrapped into a `DatabaseError` before it arrives, so it is tolerated regardless of what
      # it originally was. That is the intended reading of "the round-trip failed".
      !(e isa DatabaseError || e isa PoolError) && rethrow()

      # Inside a transaction this failure is NOT recoverable and must propagate. PostgreSQL poisons
      # a transaction the moment any statement in it errors: every later statement returns "current
      # transaction is aborted, commands ignored until end of transaction block", and the COMMIT is
      # answered with ROLLBACK. Swallowing would hand the caller a PormGRow for a row that is
      # already doomed, which is strictly worse than raising.
      #
      # This is the common path for the bulk writers: `bulk_insert` and `bulk_copy` ALWAYS run
      # inside a transaction (`execution_bulk.jl:1004`, `:1176` — ambient, or their own
      # `run_in_transaction`). On PostgreSQL the row-level writers are the opposite: `insert`,
      # `_update_or_create` and `_get_or_create` deliberately run transaction-free (`ON CONFLICT` is
      # atomic on its own, `execution.jl:924-928`), so they take the warn path unless the caller
      # opened an `atomic` block.
      #
      # `!ignore_tx` is currently always true — no call site overrides the kwarg — but the condition
      # belongs with the check: `ignore_tx=true` makes `fetch` take a separate pooled connection,
      # which leaves the caller's transaction untouched and the failure genuinely recoverable.
      if !ignore_tx && transaction_connection_for(settings) !== nothing
        rethrow()
      end

      # Outside a transaction the INSERT was its own committed statement, so the row is durable and
      # only the NEXT auto-generated key is at risk. Report and carry on.
      #
      # The message names the LIKELY cause without asserting it: a role holding USAGE but not UPDATE
      # on the sequence hits this every time (PostgreSQL requires UPDATE for `setval` while
      # `nextval` accepts either, so such a role inserts rows fine and can never resync) — but a
      # pool timeout or a dropped connection lands here too, and sending that operator to GRANT
      # would be a wild goose chase. `exception=e` carries the truth.
      @warn "Sequence resync failed — the next auto-generated primary key may collide. If the cause is a permission error, the role needs UPDATE on the sequence." model=model.name table=Models.model_table_name(model) column=col sequence=something(sequence_name, "unresolved") exception=e
    end
  end
end

# SQLite creates `sqlite_sequence` lazily, the first time the database creates an AUTOINCREMENT
# table, so a database with none has no table to read or write (#674). PormG's own DDL always emits
# AUTOINCREMENT; a legacy or imported schema often does not. Without the table there is no counter to
# keep in step: SQLite assigns the next rowid as `MAX(rowid) + 1`. Asked on every call rather than
# cached, because an AUTOINCREMENT table created later in the session brings the table into being.
function _sqlite_has_sequence_table(settings::PormGSettings)::Bool
  df = fetch(settings, "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence';") |> DataFrames.DataFrame
  return DataFrames.nrow(df) > 0
end

# sqlite_sequence.name has no UNIQUE constraint, so `INSERT OR REPLACE` appends a duplicate row
# instead of overwriting. Upsert by hand: UPDATE the existing row (collapsing any duplicates a prior
# buggy run left, all to the same value), then INSERT only if no row exists yet. `table_literal` is
# the physical table name with single quotes already doubled.
function _sqlite_sequence_upsert!(settings::PormGSettings, table_literal::AbstractString, value::Int64)
  fetch(settings, "UPDATE sqlite_sequence SET seq = $(value) WHERE name = '$(table_literal)';")
  fetch(settings, "INSERT INTO sqlite_sequence (name, seq) SELECT '$(table_literal)', $(value) " *
                  "WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = '$(table_literal)');")
  return nothing
end

function _update_sequence(model::PormGModel, connection::PormGSQLite, pk_field::Vector{String}, settings::PormGSettings)
  _sqlite_has_sequence_table(settings) || return nothing   # no AUTOINCREMENT table, nothing to resync (#674)
  for field in pk_field
    safe_field_name = safe_column_identifier(Models.model_column(model, field), connection)  # db_column (#50)
    safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
    # Matched against `sqlite_sequence.name`, which holds the table's ACTUAL name — so it must be
    # the resolved physical name (db_table when set, #59), not a fold of the logical one.
    safe_table_literal = replace(Models.model_table_name(model), "'" => "''")
    max_id_query = "SELECT MAX($(safe_field_name)) as m FROM $(safe_table_name);"
    # Execute query and convert to DataFrame to safely access the result
    df = fetch(connection, max_id_query) |> DataFrames.DataFrame
    
    if size(df, 1) > 0
      max_id = df[1, :m]
      if !ismissing(max_id) && !isnothing(max_id)
        # MAX(pk) is normally an Int64, but coerce defensively: a Float ("5.0") must still
        # resolve to its integer seq value instead of being silently skipped
        # (tryparse(Int64, "5.0") === nothing). A non-numeric value yields `nothing` → skipped.
        parsed_id = max_id isa Real ? floor(Int64, max_id) : tryparse(Int64, string(max_id))
        parsed_id !== nothing && _sqlite_sequence_upsert!(settings, safe_table_literal, parsed_id)
      end
    end
  end
end

# `_is_date_field(::String, ::SQLInstruction)` used to live here. Both of its callers were the
# integer-days special cases #568 deleted, so it went with them — and with it the #563 collision, in
# which two functions named `_is_date_field` carried DIFFERENT semantics: this one answered `true`
# for TIMESTAMP, while `sanitization.jl`'s `_is_date_field(f_meta)` answers `true` only for a plain
# DATE. That pair is what produced the integer-days half of #527 in the first place, and removing it
# is what CLOSED #563: that issue asked for the two predicates to have names distinguishing "any
# temporal column" from "calendar-date column", and there is no longer a pair to distinguish. The
# survivor reads unambiguously precisely because it has no confusable sibling left.
#
# What replaces it: `_operand_column_kind`, which answers with a `CanonicalType` rather than a Bool
# and is shape-polymorphic (a String, a `JoinedReference` or a nested `FExpression`), so there is one
# answer to "what temporal kind is this?" in this file instead of two predicates that agreed by luck.

function _set_update_query(v::SQLTypeFunction, instruc::SQLInstruction)
  return _get_select_query(v, instruc)
end

# --- Date arithmetic with explicit Julia duration types (#25) ------------------------------------
# Unit → SQL keyword maps. These are closed whitelists: the unit symbols come only from
# `_decompose_period`, never from user text, so the interpolated keyword can never carry injection.
const _PG_INTERVAL_KW     = Dict(:year => "years", :month => "months", :week => "weeks",
                                 :day => "days", :hour => "hours", :minute => "mins")  # :second → "secs"
const _SQLITE_INTERVAL_UNIT = Dict(:year => "years", :month => "months", :day => "days",
                                   :hour => "hours", :minute => "minutes", :second => "seconds")  # :week → converted to :day

# Concrete date/time type of a plain field reference, or `nothing` if the field is not a
# DATE/TIMESTAMP column or cannot be resolved. Sibling of `_is_date_field`; the migration-style
# `tab_field_cache` lookup only resolves a dotted join key AFTER that join has rendered.
function _date_field_type(field_name::String, instruc::SQLInstruction)::Union{String, Nothing}
  model = instruc.object.model
  if haskey(model.fields, field_name)
    t = model.fields[field_name].type
    return t in ("DATE", "TIMESTAMPTZ", "TIMESTAMP") ? t : nothing
  else
    memoized = memo_field(instruc, memo_key(:base, field_name))   # #474: base-model namespace
    if memoized !== nothing
      return memoized.type in ("DATE", "TIMESTAMPTZ", "TIMESTAMP") ? memoized.type : nothing
    end
  end
  return nothing
end

# Whether a plain field reference resolves at all (so soft validation only fires when a field is
# known to be a non-date column, never when its type is simply unknown — best-effort, fail-open).
function _field_type_known(field_name::String, instruc::SQLInstruction)::Bool
  return haskey(instruc.object.model.fields, field_name) ||
         memo_field(instruc, memo_key(:base, field_name)) !== nothing
end

# #494 — the DATE/TIMESTAMP type of a comparison's LEFT side, or `nothing` when there is no column
# to ask.
#
# `F("path")` puts a `String` in `field_name` and `Joined(alias, col)` puts the handle there. A
# nested expression — `F("dob") + Year(18)` — puts an `FExpression` there, and it is NOT
# unanswerable: the column one level down is the column the comparison is against, so recursing to
# find it is what keeps the representation following the COLUMN rather than the literal's own Julia
# type.
#
# That recursion is load-bearing, not tidiness. Without it `F("dob") + Year(0) == DateTime(1985,1,7)`
# on a `DateField` bound the canonical UTC string while `date(...)` rendered `'1985-01-07'` — no
# match, zero rows, no error. Exactly the silent failure the operand arm exists to prevent, one hop
# away from where it was being prevented. `_render_date_period_arithmetic` calls this same function
# to choose SQLite's `date()` vs `datetime()` wrapper, so the wrapper and the bound representation
# agree about which column the expression is rooted in.
#
# What this does NOT claim is that arithmetic preserves the column's KIND at render time. It does
# not: a sub-day duration on a `DateField` renders `datetime("seen", '+2 hours')` on SQLite, whose
# output matches neither the calendar-date form nor the canonical timestamp form. That is a
# render-side representation gap of its own — pre-existing, reachable without any of #494 (a plain
# `F(ts) + Day(1) == F(other_ts)` has it too), and tracked separately. Answering with the rooted
# column is the right answer to THIS question; it is not a claim that the rest of that path is sound.
#
# A `CTE(...)` cannot be a LEFT operand — no comparison method takes one on that side — so it has no
# arm. Nor does an `FObject`, and the honest reason is that nothing needs one: no comparison overload
# accepts a bare `FObject` on the left at all (`Max("seen") == Date(…)` falls through to `Base.==`),
# so the only route in is one hop down — `(Sum("points") - 10) == Date(…)` — where falling back to
# the operand's own type is correct. A `__@` transform does not arrive here as an `FObject` either:
# `F("seen__@year")` puts the whole path in `field_name` as a STRING, and `_date_field_type` already
# declines it.
#
# The joined arm reads the memo rather than the model: `_get_select_query(::JoinedReference)` writes
# the resolved `PormGField` under `memo_key(ref)` (`build_helpers.jl`), and the caller renders the
# left side BEFORE the operand, so the entry is always there by the time this runs. Without it a
# `Joined` comparison fell back to the operand's own type while the `F` twin consulted the column —
# the two families binding different bytes for the same query, which is the asymmetry #494 exists to
# close.
#
# #508 phase 2 removed this walk's `depth > 16` cap. It existed for one stated reason — `FExpression`
# was mutable, so a hand-built cycle (`g.field_name = g`) was one assignment away, in either of the
# two orderings the deleted comment enumerated. `FExpression` is a `struct` now and `field_name` can
# only be set at construction, so a self-cycle is unrepresentable rather than merely unlikely. That
# is the same reason #457 added no cap for the operator route it closed, applied one level up.
#
# Deleting it is a correctness fix and not only cleanup: the cap returned `nothing`, and `nothing`
# here means "not a date column" — so a legitimately 17-deep expression did not fail, it silently
# selected the wrong literal representation for the bound operand. #494's whole point is that an `F`
# comparison and an ordinary `filter(...)` pair bind the same bytes; the cap could break exactly that.
#
# #536 generalized the walk from "the DATE/TIMESTAMP type of the column" to "the column's FIELD",
# because the literal arm needs the column's FORMATTER, not only its temporal kind: a `Float64`
# against a `FloatField` must bind `format_number_sql`'s string, a `UUID` against a `UUIDField`
# `format_uuid_sql`'s — the same choice the pair path makes at `_get_filter_query(::SQLTypeOper)`
# (build_helpers.jl) by reading `model.fields[...]`. The String arm is `_date_field_type`'s own
# two-step lookup (model fields, then the base-namespace memo the left-side render populated).
function _operand_column_field(field_name, instruc::SQLInstruction)::Union{PormGField,Nothing}
  if field_name isa String
    model = instruc.object.model
    haskey(model.fields, field_name) && return model.fields[field_name]
    return memo_field(instruc, memo_key(:base, field_name))   # #474: base-model namespace
  end
  field_name isa JoinedReference && return memo_field(instruc, memo_key(field_name))
  field_name isa FExpression && return _operand_column_field(field_name.field_name, instruc)
  return nothing
end

# #564 — the rooted column's canonical kind, replacing `_operand_column_type`'s type STRING. The
# strings were the symptom the representation table exists to remove: every consumer re-derived the
# same DATE-vs-TIMESTAMP decision from them, and each copy was a place the two could disagree.
#
# NARROWED to the two kinds that take date arithmetic, exactly as the string version was. `CTime` and
# `CInterval` are temporal representations but never the LEFT of `± duration`.
#
# This is a CONSUMER-SIDE narrowing, and it is not the only thing enforcing the rule. Since the
# projection path needs the column's TRUE kind, `_render_left_typed` hands the unnarrowed answer to
# the temporal renderer, so a `CTime` left is refused by two independent things: the soft validation
# in `_render_date_period_arithmetic` (the String case), and `sql_canonicalize`'s generic arm, which
# THROWS rather than silently dropping modifiers whose parameters are already bound. Neither is a
# formality — `test_f_date_operands.jl`'s "#564: a TIME column is not whole-day arithmetic" testset
# fails if this narrowing is removed.
function _operand_column_kind(field_name, instruc::SQLInstruction)::TemporalKind
  kind = _projection_column_kind(field_name, instruc)
  return (kind isa CDate || kind isa CDateTime) ? kind : nothing
end

# The same lookup, UNNARROWED — the kind a column's values are stored as, whatever it is.
#
# Two functions rather than one because they answer two different questions, and conflating them
# changes behaviour in both directions. ARITHMETIC must see only DATE and TIMESTAMP: a `TimeField`
# or a `DurationField` is a temporal REPRESENTATION but never the left of `± duration`, and
# `_render_date_period_arithmetic`'s soft validation refuses one — widening `_operand_column_kind`
# would let `F(t) + 7` render `date(t, '+7 days')` instead of throwing. A PROJECTION must see all
# four: a `TimeField` column read back as a `String` on SQLite while PostgreSQL delivered a `Time`
# is precisely the defect this closes.
#
# One lookup, two policies, each named for its job — not two implementations of one rule.
function _projection_column_kind(field_name, instruc::SQLInstruction)::TemporalKind
  f = _operand_column_field(field_name, instruc)
  f === nothing && return nothing
  return field_canonical_kind(f)
end

# #536 — the operators whose right-hand literal is bound through the rooted column's formatter.
# Arithmetic (`+ - * / << >>` …) is deliberately NOT in this set: those operands keep the raw,
# SQL-typed bind (`integer_column / 2.0` must not be inferred back to integer on PostgreSQL), and
# the Integer arm's date-arithmetic wrapper depends on receiving the bare value.
const _COMPARISON_OPERATIONS = ("=", "!=", ">", "<", ">=", "<=")

# #494 — the representation a `Date`/`DateTime` literal binds as on the RIGHT of an `F(...)` /
# `Joined(...)` comparison.
#
# The LEFT column decides, and `_set_update_query_operand` already receives it as `field_name`, so
# the choice is made the way the plain-filter path makes it: by the field, not by the value.
# `_operand_column_type` above answers for both families, and its answer selects the MODEL LAYER's
# own formatter rather than a second copy of the rules — `format_date_sql` for a DATE column,
# `format_timezone_sql` for a TIMESTAMP/TIMESTAMPTZ one (the canonical UTC string #79 defined, so
# SQLite's lexicographic TEXT comparison agrees with PostgreSQL's instant comparison). Reusing those
# is the whole point: an `F` comparison and an ordinary `filter(...)` pair against the same column
# now bind the same bytes.
#
# A `Date` against a TIMESTAMP column is promoted to midnight first, because `format_timezone_sql`
# has no `::Date` method — and midnight is what SQL itself means by a date literal compared to a
# timestamp, so the promotion is exact rather than a guess.
#
# When the left side is a nested expression or an unresolvable path there is no column to ask, so
# the operand's own type decides. Still a formatted string, never a raw bind.
# #533 added `ZonedDateTime`. The body needed no new arm: `Models.format_date_sql` and
# `Models.format_timezone_sql` each already carry a `::ZonedDateTime` method, and the two branches
# below pick between them by the COLUMN's type, not the value's — which is the whole point of #494.
# So a `ZonedDateTime` against a TIMESTAMP column binds the canonical UTC string (#79), byte-identical
# to what the ordinary `filter("ts" => zdt)` pair spelling binds.
# #564: `left_kind` is the kind the LEFT SIDE evaluates to, carried out of its own render rather than
# reconstructed here. That replaces the `_f_arith_result_kind` chain walk this used to perform.
#
# #527's promotion is now a property of the value it receives: `F("dob") + Hour(6)` on a `DateField`
# evaluates to a timestamp — `date + interval` is a `timestamp` in SQL:2003 and PostgreSQL, and Django
# resolves the same combination to a `DateTimeField` — so the literal must bind the canonical form,
# not the column's calendar date. Bound to the column's date form, the comparison was unsatisfiable on
# BOTH engines and returned zero rows with no error. The promotion still fires only on a sub-day
# component (`_shift_result_kind`), so the pinned truncation contract for whole-day arithmetic
# (`F("dob") + Day(1) == DateTime(...)` binds the calendar date, exactly as the pair spelling does) is
# untouched.
#
# Which formatter a kind gets is NOT decided here — `value_formatter` is the single declaration both
# this binder and the field itself derive from (#564), so an `F` comparison and an ordinary
# `filter(...)` pair against the same column bind the same bytes by construction rather than because
# two ladders happen to agree.
function _format_date_operand(operand::Union{Dates.Date,Dates.DateTime,TimeZones.ZonedDateTime}, field_name, instruc::SQLInstruction;
                              left_kind::TemporalKind = nothing)
  kind = left_kind === nothing ? _operand_column_kind(field_name, instruc) : left_kind
  # Only a DATE/TIMESTAMP left decides a date literal's representation. A `TimeField` left reaching
  # here means the caller compared a date against a time column, where the column has nothing useful
  # to say — the operand's own type decides, as it did before the render carried a kind.
  kind isa Union{CDate,CDateTime} || (kind = nothing)
  formatter = kind === nothing ? nothing : value_formatter(kind, instruc.connection)
  # No column to ask (a nested expression rooted in a function, an unresolvable path): the operand's
  # own type decides. Still a formatted string, never a raw bind.
  formatter === nothing &&
    return operand isa Dates.Date ? Models.format_date_sql(operand) : Models.format_timezone_sql(operand)
  # A `Date` against a TIMESTAMP column is promoted to midnight first, because `format_timezone_sql`
  # has no `::Date` method — and midnight is what SQL itself means by a date literal compared to a
  # timestamp, so the promotion is exact rather than a guess.
  kind isa CDateTime && operand isa Dates.Date && return formatter(Dates.DateTime(operand))
  return formatter(operand)
end

# Decompose a Period/CompoundPeriod into an ordered [(unit, magnitude)] list (largest → smallest),
# folding sub-second components into a single fractional `:second`. Zero-valued components are
# dropped. Month/Year are kept as calendar units (SQL renders them natively) rather than rejected
# the way `_duration_to_nanoseconds` does — nanosecond conversion is ambiguous, SQL interval math is not.
function _decompose_period(period::Union{Dates.Period, Dates.CompoundPeriod})
  cp = period isa Dates.CompoundPeriod ? period : Dates.CompoundPeriod(period)
  acc = Dict{Symbol, Int}()
  frac_nanos = Int64(0)
  for p in Dates.periods(cp)
    val = Dates.value(p)
    if     p isa Year        ; acc[:year]   = get(acc, :year, 0)   + val
    elseif p isa Quarter     ; acc[:month]  = get(acc, :month, 0)  + 3 * val
    elseif p isa Month       ; acc[:month]  = get(acc, :month, 0)  + val
    elseif p isa Week        ; acc[:week]   = get(acc, :week, 0)   + val
    elseif p isa Day         ; acc[:day]    = get(acc, :day, 0)    + val
    elseif p isa Hour        ; acc[:hour]   = get(acc, :hour, 0)   + val
    elseif p isa Minute      ; acc[:minute] = get(acc, :minute, 0) + val
    elseif p isa Second      ; acc[:second] = get(acc, :second, 0) + val
    elseif p isa Millisecond ; frac_nanos += Int64(val) * 1_000_000
    elseif p isa Microsecond ; frac_nanos += Int64(val) * 1_000
    elseif p isa Nanosecond  ; frac_nanos += Int64(val)
    else
      throw(InvalidValueError("Unsupported duration component $(typeof(p)) in F-expression date arithmetic"))
    end
  end
  comps = Tuple{Symbol, Real}[]
  for u in (:year, :month, :week, :day, :hour, :minute)
    haskey(acc, u) && acc[u] != 0 && push!(comps, (u, acc[u]))
  end
  whole_sec = get(acc, :second, 0)
  if frac_nanos != 0
    push!(comps, (:second, whole_sec + frac_nanos / 1e9))
  elseif whole_sec != 0
    push!(comps, (:second, whole_sec))
  end
  return comps
end

# #564 — the kind an expression evaluates to, given the kind its LEFT SIDE evaluates to and the
# duration components applied to it. One rule, one line, no walk.
#
# It replaces `_f_arith_result_kind`, a type inferencer written as a RETROACTIVE walk: because the
# render returned a bare `String`, anything downstream that needed the type had to reconstruct it
# afterwards, either by re-walking the AST or by sniffing the rendered text. The walk's three
# documented subtleties were all consequences of that, and the typed render gets each for free:
#
#   1. "It walks the CHAIN, not just the top link" — the inner node's kind is now CARRIED out of the
#      inner render and read from the tuple, so there is no chain left to walk.
#   2. "It asks `_decompose_period`, not `typeof(operand)`" — still true, and now structural: this
#      function takes `comps`, so it cannot be spelled any other way.
#   3. The zero-length link (`F(ts) + Day(0) + Day(1)`) — the identity short-circuit returns
#      `(left_sql, kind)`, so the kind survives a link that emits no text at all. That is what makes
#      the textual backstop unnecessary rather than merely redundant; see the deletion note below.
#
# Django calls the kind an expression evaluates to its `output_field`, and every `Expression` carries
# one — this is that idea, narrowed to the temporal path.
#
# The promotion is the SQL one: a sub-day duration on a DATE column yields a TIMESTAMP. `date +
# interval` is a `timestamp` in SQL:2003 and in PostgreSQL; Django registers `DateField +
# DurationField -> DateTimeField` in `_connector_combinations` and SQLAlchemy resolves
# `Date + Interval -> DateTime`. Without it `F("dob") + Hour(6) == DateTime(...)` bound the column's
# calendar-date form against a timestamp-valued left side and returned zero rows — on BOTH engines,
# silently.
#
# NARROWER than Django on purpose: Django promotes `DateField + Duration` unconditionally, including
# whole days. PormG has a pinned, deliberate contract that a `DateTime` literal against a DATE column
# truncates to its calendar date exactly as the `filter("dob__@gte" => …)` pair spelling does, and
# promoting on `Day(1)` would overturn it. Promoting only when the expression itself produced a
# time-of-day changes nothing that already has a correct answer.
#
# #572 settled the one consequence this left open. PostgreSQL's own `date + interval` is a timestamp
# even for whole days, so the PROJECTED type split by engine until the PostgreSQL render was cast
# back to `date` — `sql_canonicalize(::CDate, ::PormGPostgres)`, which `_render_temporal_shift`
# consults with the kind this function returns. The rule here is therefore the rule both engines
# project, not only the one PormG binds by.
_shift_result_kind(::Nothing, comps) = nothing
_shift_result_kind(kind::CDate, comps) =
  any(c -> c[1] in (:hour, :minute, :second), comps) ? CDateTime(false) : kind
_shift_result_kind(kind::CanonicalType, comps) = kind

# #801 — the other half of the same table: the kind `a - b` evaluates to when BOTH sides are temporal.
# `_shift_result_kind` names `temporal ± duration`; this names `temporal - temporal`. Without it the
# difference fell into the generic infix arm, which renders a bare `-` and types it `nothing` — and on
# SQLite a DATE is TEXT, so `-` subtracts each side's leading numeric prefix: `'2009-04-28' -
# '2009-03-29'` is `2009 - 2009 = 0`. A plausible integer, no error, on the engine with the bug only.
#
#   DATE - DATE  → `CInt32`: a whole number of days. PostgreSQL's own `date - date` is an `integer`,
#                  so its SQL is unchanged and SQLite is rendered to agree with it.
#   anything with a TIMESTAMP side (a sub-day-promoted DATE included) → `CInterval`, PostgreSQL's
#                  `timestamp - timestamp`. Typed so the #581 read-back pin applies to it.
#   anything else → `nothing`: not a temporal difference, rendered exactly as before.
#
# NOT Django's answer, deliberately: Django's `TemporalSubtraction` gives a `DurationField` for
# `DateField - DateField`. An integer is what PostgreSQL already returns, and it keeps `gap > 30`
# a numeric comparison on both engines — a duration on SQLite is TEXT and compares as TEXT.
_difference_result_kind(::CDate, ::CDate) = CInt32()
_difference_result_kind(::Union{CDate,CDateTime}, ::Union{CDate,CDateTime}) = CInterval()
_difference_result_kind(_, _) = nothing

# The LEFT side of an expression, rendered AND typed.
#
# RENDERS BEFORE IT TYPES, and the order is load-bearing rather than incidental: resolving the left
# populates `instruc.tab_field_cache` for a dotted join key (`F("driverid__dob")`), which is the only
# way `_projection_column_kind` can answer for one. Type first and every joined temporal column silently
# becomes `nothing` — on PostgreSQL that is `timestamptz + bigint`, a hard error; on SQLite it is a
# `date()` truncation nobody sees.
function _render_left_typed(value::Any, operation::String, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  value isa FExpression && return _render_expr_typed(value, instruc)
  sql = _set_update_query_left(value, operation, instruc)
  return sql, _side_kind(value, instruc)
end

# #814 — the kind of an ALREADY-RENDERED side that is not itself an expression: a column, a
# transformed path, or a function. The column lookup answers for a column, and only for one. A
# transform (`"date__@date"`) or a function (`Max("date")`) answered `nothing` there, so
# `F("date") - Max("date")` fell to a bare `-`, which on SQLite subtracts the YEARS of two TEXT
# dates, silently. Both now ask the projection path's own resolver (`build_query.jl`), the one that
# already types `.values("m" => Max("date"))` for the read path, so a side is typed in arithmetic
# exactly as it is when projected on its own: `Max`/`Min` keep their operand's kind, `@date` is a
# date, and a function PormG does not type (`Sum`, `@year`) stays `nothing`.
#
# The order rule is the caller's: render first, then call this.
_side_kind(value::Any, instruc::SQLInstruction) = _projection_column_kind(value, instruc)
_side_kind(value::String, instruc::SQLInstruction) =
  occursin("__@", value) ? _operand_kind(value, instruc) : _projection_column_kind(value, instruc)
_side_kind(value::SQLTypeFunction, instruc::SQLInstruction) = _function_projection_kind(value, instruc)

# #882 — AN INTEGER COLUMN BESIDE A DATE IS A WHOLE NUMBER OF DAYS. An integer literal already is
# (#568), and so is a `DATE - DATE` count (#814); an integer COLUMN was untyped, because
# `field_canonical_kind` answers `nothing` for an `IntegerField`. So `F("seen") - F("points")` shifted
# the date by `points` days on PostgreSQL, and on SQLite subtracted `points` from the YEAR, silently.
#
# Typed HERE, for date arithmetic only, and not in `field_canonical_kind`: that table also drives the
# read path, the CTE kind records and the #536 comparison binder, and an integer column has no
# representation for any of them to undo. `CInt64` for a `BigIntegerField`, because PostgreSQL has
# `date ± integer` but no `date ± bigint`, so that count is cast (`_day_count_sql`).
#
# A bare column only — `F("points") * 2` is arithmetic over one, and a ForeignKey or an ID is an
# integer that is not a quantity of anything. Both stay untyped, and an untyped side combined with a
# date is refused on SQLite (`_refuse_untyped_date_operand`).
function _day_count_column_kind(side, kind::_RenderKind, instruc::SQLInstruction)::_RenderKind
  kind === nothing && _is_bare_column(side) || return kind
  f = _operand_column_field(side, instruc)
  f isa Models.sIntegerField && return CInt32()
  f isa Models.sBigIntegerField && return CInt64()
  return nothing
end
_is_bare_column(s::String) = !occursin("__@", s)
_is_bare_column(::JoinedReference) = true
_is_bare_column(x::FExpression) = x.operation === nothing && _is_bare_column(x.field_name)
_is_bare_column(::Any) = false

# A day count's SQL as a day shift reads it. Only a `BIGINT` count on PostgreSQL changes.
_day_count_sql(sql::AbstractString, kind::TemporalKind, instruc::SQLInstruction) =
  kind isa CInt64 && instruc.connection isa PormGPostgres ? "CAST($(sql) AS integer)" : sql

# #882 — `date ± x` where `x` is none of the kinds a date combines with: a text column, `Sum(...)`,
# `F("points") * 2`, a float. SQLite stores a date as TEXT, so `+`/`-` there added the date's YEAR to
# the number, silently. Refused on SQLite. PostgreSQL has no such operator either and fails when the
# statement runs; its SQL is left as it was.
function _refuse_untyped_date_operand(operation::AbstractString, instruc::SQLInstruction)
  instruc.connection isa PormGSQLite || return nothing
  throw(QueryBuildError("`$(operation)` between a date and a value PormG cannot type is not supported on " *
                        "SQLite, where a date is text and `$(operation)` would use only its year. Add a " *
                        "whole number of days (an IntegerField, F(\"date\") + 7) or a duration " *
                        "(F(\"date\") + Day(7))."))
end

# #564/#568 — THE ONE TEMPORAL RENDERER. It takes an ALREADY-RENDERED left side and the kind that
# left evaluates to, which is what lets the duration spelling and the bare-integer spelling share it:
# each resolves its own operand into `comps` and then renders identically.
#
# Taking the left pre-rendered is not a convenience, it is the fix for an ordering hazard. Rendering
# the left is what populates `instruc.tab_field_cache` for a dotted join key (`F("driverid__dob")`),
# and nothing can resolve that key's kind until it has. A caller that decided "is this temporal?"
# BEFORE rendering would see `nothing` for every joined temporal column and fall through to plain
# arithmetic — `timestamptz + bigint` on PostgreSQL, a silent `date()` truncation on SQLite. Making
# the rendered left a PARAMETER means a caller cannot ask the question in the wrong order.
function _render_temporal_shift(left_side::AbstractString, kind::TemporalKind, operation::String,
                                comps, instruc::SQLInstruction)::String
  if instruc.connection isa PormGPostgres
    parts = String[]
    for (unit, value) in comps
      if unit === :second
        ph = add_parameter!(instruc, Float64(value); sql_type = "double precision")
        push!(parts, "secs => $ph")
      else
        ph = add_parameter!(instruc, Int(value); sql_type = "integer")
        push!(parts, "$(_PG_INTERVAL_KW[unit]) => $ph")
      end
    end
    isempty(parts) && return left_side  # zero-length interval → identity
    # #572 — rendered into the representation the RESULT kind is stored in, exactly as the SQLite
    # branch below is. For a whole-day shift on a DATE that is a `::date` cast (PostgreSQL's own
    # `date + interval` is a timestamp); for everything else the table's PostgreSQL arm is the
    # identity. `kind` is the result kind, so a sub-day shift on a DATE is never cast. An untyped
    # left (`nothing`) renders as it always did — no cast chosen on a guess.
    shifted = "($(left_side) $(operation) make_interval($(join(parts, ", "))))"
    kind === nothing && return shifted
    return sql_canonicalize(kind, instruc.connection, shifted)

  elseif instruc.connection isa PormGSQLite
    op_factor = operation == "-" ? -1 : 1
    mods = String[]
    for (unit, value) in comps
      # SQLite has no 'weeks' modifier — express weeks as days.
      u, mag = unit === :week ? (:day, value * 7) : (unit, value)
      signed = op_factor * mag
      sign   = signed < 0 ? "-" : "+"
      ph     = add_parameter!(instruc, abs(signed))
      push!(mods, "'$sign' || $ph || ' $(_SQLITE_INTERVAL_UNIT[u])'")
    end
    # Zero-length interval → identity, matching the PostgreSQL branch (never wrap, so a timestamp
    # column is not truncated by a stray date() on a no-op interval). The KIND still travels out of
    # the caller, which is what makes the deleted backstop below unnecessary: `F(ts) + Day(0) + Day(1)`
    # emits no text here for the inner link, and the outer call is told `CDateTime` anyway.
    isempty(mods) && return left_side

    # #564 — the wrapper is no longer chosen by an `if` at this site. `sql_canonicalize` is asked to
    # render the expression into the form THIS kind's values are stored in, and the table owns which
    # form that is: the canonical `strftime` mask for a timestamp (#527 — SQLite's own `datetime()`
    # emits `YYYY-MM-DD HH:MM:SS`, which can never equal, and always sorts below, the
    # `YYYY-MM-DDTHH:MM:SS.sss+00:00` a `DateTimeField` stores), `date(...)` for a DATE column, whose
    # output already equals `format_date_sql`'s.
    #
    # ── THE TEXTUAL BACKSTOP IS GONE (#564) ──────────────────────────────────────────────────────
    # This site used to read
    #
    #     use_datetime = <resolver> === :timestamp || occursin(<the canonical mask>, left_side)
    #
    # — a sniff of the RENDERED TEXT, kept because the resolver could not see through a zero-length
    # link. It is deleted on two independent grounds, both required:
    #
    #   * STRUCTURAL — the kind is now carried out of the left render instead of reconstructed from
    #     it, and the identity short-circuit above propagates it, so the one shape the backstop
    #     existed for is handled by construction.
    #   * MEASURED — both branches were instrumented and run over four corpora (a purpose-built
    #     256-shape sweep, the full unit suite, the hermetic property test, and the full `db_sl`
    #     integration suite): 519 renders, of which `text ∧ ¬kind` occurred **0** times. The sniff
    #     never once decided an outcome the resolver had not already decided.
    #
    # `test/unit/test_value_repr_table.jl` scans `src/querybuilder/` for the mask so it cannot return.
    #
    # `nothing` means a left side this build cannot type. `date(...)` is what that case rendered
    # before, and it stays that, rather than being promoted on a guess.
    kind === nothing && return "date($(left_side), $(join(mods, ", ")))"
    return sql_canonicalize(kind, instruc.connection, left_side, mods)
  else
    throw(_unsupported_conn("date/interval arithmetic", instruc.connection))
  end
end

# #801 — THE DIFFERENCE OF TWO TEMPORAL SIDES, `kind` being `_difference_result_kind`'s answer.
#
# PostgreSQL types both columns, so its `-` is already the right operator; the text is the one the
# generic infix arm always emitted. SQLite's `-` on two TEXT dates is the difference of the YEARS, so
# the day count goes through `julianday`, which reads both `date(...)`'s output and the canonical UTC
# text a `DateTimeField` stores, and propagates NULL. The difference of two midnights is a whole
# number, so the `CAST` is exact — it only turns SQLite's REAL into the integer PostgreSQL returns.
#
# #814 — a TIMESTAMP difference is an interval. PostgreSQL's `-` already is one.
#
# #881 — on SQLite it is the INTEGER number of milliseconds between the two instants, kind
# `_IntervalMs`, and it stays that number while the expression around it is built, so `d > Hour(1)`,
# `d + d` and `F("date") + d` are arithmetic on a number. It becomes the interval TEXT a `DurationField`
# stores there (`[-]HH:MM:SS[.f]`, which `value_parser(::CInterval, ::PormGSQLite)` reads back as the
# `Dates.CompoundPeriod` PostgreSQL's `interval` reads back as, the #581 pin) only once, where its SQL
# leaves the expression tree (`_finalize_render`). Under #814 it was that text from the start, so
# ordering compared text (`"100:00:00" < "99:00:00"`) and arithmetic added the leading hours; both
# were refused on SQLite.
#
# Milliseconds, because that is the precision a stored timestamp carries (the #79 mask); `round`
# absorbs `julianday`'s binary fraction. Each side appears exactly once, so each of its parameters is
# bound once. NULL on either side is NULL, as on PostgreSQL.
function _render_temporal_difference(left_side::AbstractString, right_side::AbstractString,
                                     kind::CanonicalType, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  if instruc.connection isa PormGPostgres
    return "($(left_side) - $(right_side))", kind
  elseif instruc.connection isa PormGSQLite
    kind isa CInt32 && return "CAST(julianday($(left_side)) - julianday($(right_side)) AS INTEGER)", kind
    return "CAST(round((julianday($(left_side)) - julianday($(right_side))) * 86400000) AS INTEGER)", _IntervalMs()
  else
    throw(_unsupported_conn("date difference", instruc.connection))
  end
end

# #881 — where a rendered expression LEAVES the tree (`_set_update_query`, the projection in
# `build_query.jl`), an interval held in milliseconds becomes the stored text, read back as `CInterval`.
# Every other kind is already what its SQL evaluates to.
_finalize_render(sql::AbstractString, kind::TemporalKind, ::SQLInstruction) = (String(sql), kind)
_finalize_render(sql::AbstractString, ::_IntervalMs, ::SQLInstruction) =
  (Dialect._sqlite_interval_text(sql), CInterval())

# The text of a side, for the places that compare or combine it as text rather than as a number.
_as_interval_text(sql::AbstractString, kind::_RenderKind) =
  kind isa _IntervalMs ? Dialect._sqlite_interval_text(sql) : String(sql)

_is_interval_kind(kind::_RenderKind) = kind isa Union{CInterval,_IntervalMs}

# #881 — a side as SQLite milliseconds, or `nothing` when it has no such form. An `_IntervalMs` side
# is one already. A `DurationField` column is its stored text, parsed in SQL; the column reference is
# repeated by the parse, which is safe because a column binds no parameter. Any other interval — an
# extremum over a duration column (`Max("lap")`), a `Coalesce` — is text whose SQL may carry
# parameters, and has no millisecond form here.
function _interval_ms_sql(sql::AbstractString, side, kind::_RenderKind)::Union{String,Nothing}
  kind isa _IntervalMs && return String(sql)
  kind isa CInterval && _is_bare_column(side) && return Dialect._sqlite_interval_ms(sql)
  return nothing
end

# #881 — a duration literal as the milliseconds it binds against an `_IntervalMs` side, rounded half
# away from zero as the difference is. A month or a year has no fixed length, so it has no millisecond
# count (PostgreSQL's `interval` keeps months apart for the same reason).
function _duration_ms(p)::Int64
  period = p isa Interval ? p.period : p
  ns = try
    Models._duration_to_nanoseconds(period)
  catch e
    e isa InvalidValueError || rethrow()
    throw(QueryBuildError("A duration of months or years ($(period)) has no fixed length, so it cannot be " *
                          "combined with a timestamp difference on SQLite. Use weeks, days or a time: " *
                          "Day(30), Hour(1)."))
  end
  q, r = divrem(ns, 1_000_000)
  return 2 * abs(r) >= 1_000_000 ? q + sign(ns) : q
end

# #814 — a WINDOW function cannot be inside a SQLite interval. The interval becomes text in a correlated
# scalar subquery (`Dialect._sqlite_interval_text`), and a window is evaluated over the rows of the
# SELECT it appears in, which there is exactly one: `LAG(x) OVER (…)` there is NULL on every row and
# `FIRST_VALUE(x)` is `x`, silently (measured on SQLite 3.45). An aggregate is safe — SQLite attributes
# an aggregate over outer columns to the outer query — so only a window is refused. Its value can
# still be used on SQLite once it is a column: project it in a CTE or a subquery first.
_has_window_function(::WindowFunction) = true
_has_window_function(x::FExpression) = _has_window_function(x.field_name) || _has_window_function(x.operand)
# `kwargs` too: `When(…; then = Lag(…))` keeps its branch value there, not in `column`.
_has_window_function(x::FObject) = _has_window_function(x.column) || any(_has_window_function, values(x.kwargs))
_has_window_function(x::SQLField) = _has_window_function(x.field)
_has_window_function(x::AbstractVector) = any(_has_window_function, x)
_has_window_function(::Any) = false

function _refuse_window_in_interval(left, right, instruc::SQLInstruction)
  instruc.connection isa PormGSQLite && (_has_window_function(left) || _has_window_function(right)) || return nothing
  throw(QueryBuildError("A window function (Lag, Lead, FirstValue, …) cannot be a side of a timestamp " *
                        "difference, or of arithmetic on one, on SQLite: the interval is turned into text in " *
                        "a subquery, where the window sees one row. Project the window value in a CTE first " *
                        "and use the column."))
end

const _ARITHMETIC_OPERATIONS = ("+", "-", "*", "/")

# #814 — the operators whose answer depends on ORDER, as opposed to equality.
const _ORDERING_OPERATIONS = (">", "<", ">=", "<=")

# #881 — what SQLite still cannot do with an interval, each because the matching PostgreSQL
# expression has no operator either (`interval + integer`, `interval * interval`, `integer / interval`
# fail when the statement runs) or because the side has no millisecond form (`_interval_ms_sql`).
# Refused at build time on SQLite, where it would otherwise compute on text or on a number, silently.
_sqlite_interval_error(what::AbstractString) =
  QueryBuildError("$(what) is not supported on SQLite. An interval there is a timestamp difference, a " *
                  "DurationField column or a duration (Hour(1)); it combines with another interval " *
                  "(+, -, comparisons), with a number (* and /), or with a date (date + interval).")

# #801 — the RIGHT side of a binary expression, rendered AND typed, for the one caller that must know
# what the right evaluates to: a `-` over a temporal left. Rendered exactly once — a second render
# would bind its parameters a second time.
#
# Only the operands `F(...) - x` can carry reach here (`Integer`, `Float64`, `String`, `FExpression`,
# a function — the `Base.:-` overloads in `types.jl`). A nested expression reports the kind it
# EVALUATES to, not its rooted column's: `F("date") - (F("date") + Hour(6))` is a timestamp
# difference. A `String` that names a field is the `F(...)` it stands for, which is the route
# `_set_update_query_operand` already takes. Everything else — a function, a text literal, a number —
# has no kind this build can know, and answers `nothing`.
#
# #814 widened what has a kind: a function is typed as the projection path types it (`_side_kind`),
# and a date literal (`F("date") - Date(2009, 3, 1)`) by its own Julia type — bound in the
# representation of THAT kind, since the difference reads both sides as the instants they are. On
# PostgreSQL it carries the cast that names it, because `date - $1` has three candidate operators
# (`date - date`, `date - integer`, `date - interval`) and an uncast parameter is ambiguous among them.
function _render_operand_typed(operand::Any, field_name::Any, operation::String, instruc::SQLInstruction;
                               left_kind::TemporalKind = nothing)::Tuple{String,_RenderKind}
  operand isa FExpression && return _render_expr_typed(operand, instruc)
  if operand isa String && _is_field_path(operand, instruc)
    return _render_expr_typed(FExpression(field_name = operand, function_name = "F", column = operand), instruc)
  end
  if operand isa _TemporalLiteral
    kind = literal_canonical_kind(operand)
    # A timestamp literal binds the canonical UTC text (`…+00:00`). Against a `timestamp` column (no
    # time zone) it is cast to that type, whose input ignores the offset and keeps the UTC wall time
    # the column itself stores; everything else casts to `timestamptz`, which reads the offset.
    sql_type = !(instruc.connection isa PormGPostgres) ? nothing :
               kind isa CDate ? "date" :
               left_kind == CDateTime(false) ? "timestamp" : "timestamptz"
    return add_parameter!(instruc, value_formatter(kind, instruc.connection)(operand); sql_type = sql_type), kind
  end
  sql = _set_update_query_operand(operand, field_name, operation, instruc; left_kind = left_kind)
  return sql, operand isa SQLTypeFunction ? _side_kind(operand, instruc) : nothing
end

# A `String` operand names a FIELD when it is a path or one of the model's own fields; otherwise it
# is a text literal. The rule `_set_update_query_operand`'s String arm applies.
_is_field_path(s::String, instruc::SQLInstruction) = contains(s, "__") || s in instruc.object.model.field_names

# #814 — A DAY COUNT COMBINED WITH A DATE: `date ± count` and `count + date`, where the count is a
# `DATE - DATE` difference (`CInt32`). PostgreSQL has `date ± integer` and `integer + date` as whole-
# day shifts, and SQLite added the date's YEAR to the integer, silently. Rendered as the shift
# PostgreSQL means, on both, and typed as the DATE side's kind.
#
# PostgreSQL: native for a DATE; a timestamp has no `+ integer`, so the count becomes
# `make_interval(days => …)`. SQLite: through the julian-day NUMBER, `julianday(d) ± n`, then back to
# the side's stored text. The number keeps the TEXT ORDER of the two sides as written, which is the
# order their parameters were bound in. A modifier (`date(d, n || ' days')`) cannot do that for
# `count + date`, since the count would print after the date it was bound before. SQLite rounds a
# julian number to the millisecond when it formats it, which is a stored timestamp's own precision.
function _render_day_count_shift(date_side::AbstractString, date_kind::Union{CDate,CDateTime},
                                 count_side::AbstractString, operation::String, date_first::Bool,
                                 instruc::SQLInstruction)::String
  if instruc.connection isa PormGPostgres
    days = date_kind isa CDate ? count_side : "make_interval(days => $(count_side))"
    return date_first ? "($(date_side) $(operation) $(days))" : "($(days) + $(date_side))"
  elseif instruc.connection isa PormGSQLite
    jd = date_first ? "julianday($(date_side)) $(operation) ($(count_side))" :
                      "($(count_side)) + julianday($(date_side))"
    return date_kind isa CDate ? "date($(jd))" : sql_canonicalize(date_kind, instruc.connection, jd)
  else
    throw(_unsupported_conn("date shift by a day count", instruc.connection))
  end
end

# #814/#881 — a date or timestamp shifted by an INTERVAL value (a `DurationField`, or the difference
# of two timestamps) rather than by a duration literal. PostgreSQL's `timestamp ± interval` is native
# and its SQL is left alone. SQLite stores both as text, where `+` added the year to the hours,
# silently; #814 refused it. #881 shifts the julian-day number by the interval's milliseconds, through
# the day-count shift above, so the date may be on either side and its text order is kept.
#
# PostgreSQL's `date ± interval` is a `timestamp`, so a DATE side becomes `CDateTime(false)`; a
# timestamp keeps its own kind. Typed on both engines, so both read the result back the same way.
function _render_interval_shift(date_side::AbstractString, date_kind::Union{CDate,CDateTime},
                                interval_side::AbstractString, interval_node, interval_kind::_RenderKind,
                                operation::String, date_first::Bool, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  kind = date_kind isa CDate ? CDateTime(false) : date_kind
  if instruc.connection isa PormGSQLite
    ms = _interval_ms_sql(interval_side, interval_node, interval_kind)
    ms === nothing &&
      throw(_sqlite_interval_error("Shifting a date by an interval that is not a timestamp difference or a " *
                                   "DurationField column"))
    return _render_day_count_shift(date_side, kind, "($(ms)) / 86400000.0", operation, date_first, instruc), kind
  end
  sql = date_first ? "($(date_side) $(operation) $(interval_side))" : "($(interval_side) + $(date_side))"
  return sql, kind
end

# A side a duration can be multiplied or divided by: a number, or a value PormG does not type.
_is_number_kind(kind::_RenderKind) = kind === nothing || kind isa Union{CInt32,CInt64,CDecimal}

# #881 — EVERYTHING AN INTERVAL ON THE LEFT COMBINES WITH, on both engines: a timestamp difference
# (`_IntervalMs` on SQLite, `CInterval` on PostgreSQL), arithmetic on one, or a `DurationField` column
# (`CInterval` on both). `± duration` never reaches here (`_render_date_period_arithmetic` owns it).
#
# PostgreSQL renders the SQL it always rendered; what changes there is the KIND. Interval arithmetic
# is typed `CInterval`, so `(d + d) > Hour(1)` binds the duration as an interval, as `d > Hour(1)`
# does, and a projected `d + d` reads back as a `Dates.CompoundPeriod`. SQLite computes on
# milliseconds (`_interval_ms_sql`) and refuses what has no millisecond form, or no operator on
# PostgreSQL either.
#
# One rule keeps the old text comparison: a `DurationField` column against a literal or another
# column compares its stored text, as before #881. Only an `_IntervalMs` side makes it a number.
function _render_interval_left(v::FExpression, left_side::String, left_kind::_RenderKind,
                               instruc::SQLInstruction)::Tuple{String,_RenderKind}
  op = v.operation
  sqlite = instruc.connection isa PormGSQLite
  bind_kind = left_kind isa _IntervalMs ? CInterval() : left_kind   # what the binder may see
  expr_right = v.operand isa FExpression || (v.operand isa String && _is_field_path(v.operand, instruc))

  if op in _COMPARISON_OPERATIONS
    if expr_right
      right_side, right_kind = _render_operand_typed(v.operand, v.field_name, op, instruc; left_kind = bind_kind)
      if sqlite && (left_kind isa _IntervalMs || right_kind isa _IntervalMs)
        lms = _interval_ms_sql(left_side, v.field_name, left_kind)
        rms = _interval_ms_sql(right_side, v.operand, right_kind)
        lms !== nothing && rms !== nothing && return "($(lms) $(op) $(rms))", nothing
        op in _ORDERING_OPERATIONS &&
          throw(_sqlite_interval_error("Ordering (`$(op)`) an interval against a value with no millisecond form"))
      end
      return "($(_as_interval_text(left_side, left_kind)) $(op) $(_as_interval_text(right_side, right_kind)))", nothing
    end
    if sqlite && left_kind isa _IntervalMs
      if v.operand isa Union{Dates.Period,Dates.CompoundPeriod}
        return "($(left_side) $(op) $(add_parameter!(instruc, _duration_ms(v.operand))))", nothing
      end
      op in _ORDERING_OPERATIONS &&
        throw(_sqlite_interval_error("Ordering (`$(op)`) an interval against $(typeof(v.operand))"))
      # Equality against any other literal compares the text, exactly as before #881, and the binder
      # raises what it always raised for a literal that is not a duration.
      left_side = _as_interval_text(left_side, left_kind)
    end
    return "($(left_side) $(op) $(_set_update_query_operand(v.operand, v.field_name, op, instruc; left_kind = bind_kind)))", nothing
  end

  if op in _ARITHMETIC_OPERATIONS
    right_side, right_kind = _render_operand_typed(v.operand, v.field_name, op, instruc; left_kind = bind_kind)
    if op in ("+", "-")
      if right_kind isa Union{CDate,CDateTime}
        op == "-" &&
          throw(QueryBuildError("A duration minus a date has no meaning. To move a date back, subtract from " *
                                "the date instead: F(\"date\") - (F(\"date\") - F(\"dob\")), or " *
                                "F(\"date\") - Day(30)."))
        return _render_interval_shift(right_side, right_kind, left_side, v.field_name, left_kind, "+", false, instruc)
      end
      if _is_interval_kind(right_kind)
        sqlite || return "($(left_side) $(op) $(right_side))", CInterval()
        lms = _interval_ms_sql(left_side, v.field_name, left_kind)
        rms = _interval_ms_sql(right_side, v.operand, right_kind)
        (lms === nothing || rms === nothing) &&
          throw(_sqlite_interval_error("`$(op)` with an interval that is not a timestamp difference or a DurationField column"))
        _refuse_window_in_interval(v.field_name, v.operand, instruc)
        return "($(lms) $(op) $(rms))", _IntervalMs()
      end
      sqlite && throw(_sqlite_interval_error("`$(op)` between an interval and a number"))
      return "($(left_side) $(op) $(right_side))", nothing
    end
    # `*` and `/`, by a number only. A text literal is not one.
    if _is_number_kind(right_kind) && !(v.operand isa String && !_is_field_path(v.operand, instruc))
      sqlite || return "($(left_side) $(op) $(right_side))", CInterval()
      lms = _interval_ms_sql(left_side, v.field_name, left_kind)
      lms === nothing &&
        throw(_sqlite_interval_error("`$(op)` on an interval that is not a timestamp difference or a DurationField column"))
      _refuse_window_in_interval(v.field_name, v.operand, instruc)
      product = op == "*" ? "($(lms)) * ($(right_side))" : "($(lms)) * 1.0 / ($(right_side))"
      return "CAST(round($(product)) AS INTEGER)", _IntervalMs()
    end
    sqlite && throw(_sqlite_interval_error("`$(op)` between an interval and $(right_kind === nothing ? "text" : "a date or an interval")"))
    return "($(left_side) $(op) $(right_side))", nothing
  end

  # Any other operator (bitwise, …) has no interval meaning; the interval is its text, as before #881.
  left_side = _as_interval_text(left_side, left_kind)
  return "($(left_side) $(op) $(_set_update_query_operand(v.operand, v.field_name, op, instruc; left_kind = bind_kind)))", nothing
end

# #881 — an interval on the RIGHT of a left that is neither a date nor an interval. Only a number
# times an interval is one (`F("points") * d`, and `2 * d`, which is `d * 2`). On SQLite, ordering a
# number against a `DurationField` column still compares the stored text, as before #881; every other
# shape has no PostgreSQL operator either and is refused there.
function _render_interval_right(v::FExpression, left_side::String, left_kind::_RenderKind,
                                right_side::String, right_kind::_RenderKind,
                                instruc::SQLInstruction)::Tuple{String,_RenderKind}
  op = v.operation
  sqlite = instruc.connection isa PormGSQLite
  if op == "*" && _is_number_kind(left_kind)
    sqlite || return "($(left_side) * $(right_side))", CInterval()
    rms = _interval_ms_sql(right_side, v.operand, right_kind)
    rms === nothing &&
      throw(_sqlite_interval_error("`*` on an interval that is not a timestamp difference or a DurationField column"))
    _refuse_window_in_interval(v.field_name, v.operand, instruc)
    return "CAST(round(($(left_side)) * ($(rms))) AS INTEGER)", _IntervalMs()
  end
  if sqlite
    right_kind isa CInterval && op in _ORDERING_OPERATIONS && return "($(left_side) $(op) $(right_side))", nothing
    throw(_sqlite_interval_error("`$(op)` with an interval on the right of a value that is not one"))
  end
  return "($(left_side) $(op) $(right_side))", nothing
end

# #801: arithmetic that has no meaning between two temporal values. PostgreSQL has no `date + date`
# operator and fails at execution; SQLite adds the two years and returns a number. Refused at build
# time on both, so the engines agree on the answer — an error — and neither is silent.
const _TEMPORAL_PAIR_REFUSED_OPERATIONS = ("+", "*", "/")

# The DURATION spelling (#25): `F(date) ± <a Dates period or an Interval>`.
function _render_date_period_arithmetic(v::FExpression, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  period = v.operand isa Interval ? v.operand.period : v.operand
  comps  = _decompose_period(period)

  # Resolve the left side FIRST — see `_render_temporal_shift`'s note on why the order is the fix.
  left_side, left_kind = _render_left_typed(v.field_name, v.operation, instruc)
  # #881: `d ± Hour(1)` on a SQLite interval is millisecond arithmetic. A zero-length duration is the
  # identity and binds nothing, as `_render_temporal_shift` does on both engines.
  if left_kind isa _IntervalMs
    isempty(comps) && return left_side, left_kind
    return "($(left_side) $(v.operation) $(add_parameter!(instruc, _duration_ms(period))))", left_kind
  end
  kind = _shift_result_kind(left_kind, comps)

  # Soft validation (#25, best-effort): a duration only makes sense on a date/time column. Only
  # throw when the field is known AND known to be non-date; stay silent for unresolved/nested lefts.
  if v.field_name isa String && _field_type_known(v.field_name, instruc) &&
     _date_field_type(v.field_name, instruc) === nothing
    throw(InvalidValueError("F(\"$(v.field_name)\") ± a duration requires a DATE/TIMESTAMP field; \"$(v.field_name)\" is not a date/time column"))
  end

  return _render_temporal_shift(left_side, kind, v.operation, comps, instruc), kind
end

# `left_kind` (#564): the kind the LEFT side evaluates to, when the caller has it. Only the temporal
# literal arm reads it — the `xor` call sites legitimately have no temporal left and pass nothing.
function _set_update_query_operand(operand::Any, field_name::Any, operation::String, instruc::SQLInstruction;
                                   left_kind::TemporalKind = nothing)
  if isa(operand, FExpression)
    return _set_update_query(operand, instruc)
  elseif isa(operand, SQLTypeFunction)
    return _get_select_query(operand, instruc)
  elseif isa(operand, Union{SQLTypeCTE,SQLTypeJoined})
    # #444/#481: a CTE or joined-copy handle is a COLUMN reference, exactly like the
    # `F("<cte>__col")` / `F("d.col")` spelling each replaces.
    # Without this arm it falls through to the `add_parameter!` at the bottom of this chain and
    # binds as a VALUE — `F("note") == CTE("ev","code")` rendered `"R1"."note" = ?` with no join
    # emitted at all, which is valid SQL comparing a column against a stringified handle.
    return _get_select_query(operand, instruc)
  elseif isa(operand, Union{Dates.Date,Dates.DateTime,TimeZones.ZonedDateTime})
    # #494 — a date/timestamp literal on the right of an `F(...)` / `Joined(...)` comparison.
    # #533 added `ZonedDateTime`: it is the third temporal type the `format_*_sql` family binds, and
    # the one #530 reported. Widening `_CompareOperand` without extending THIS arm would have bound
    # it raw — which is the failure this arm's own comment describes, on a new type.
    #
    # Ahead of the generic `add_parameter!` at the bottom for the same reason the #25 duration gate
    # sits ahead of the infix branch: reaching it would bind the RAW Julia value, and
    # `add_parameter!` normalizes nothing. On PostgreSQL that survives (the driver adapts a `Date`),
    # but on SQLite a date column holds the TEXT its field formatter produced — `"2020-01-01"`, or
    # the canonical UTC string for a timestamp — so a raw bind compares against a different
    # representation and returns the wrong rows with no error at all. Silent, not loud, which is why
    # this arm is not optional.
    #
    # So the literal takes the SAME route a plain filter value takes (`_get_filter_query(::SQLTypeOper)`,
    # build_helpers.jl): run it through the field's formatter, then bind the formatted string with no
    # explicit cast, letting PostgreSQL infer the type from the comparison context exactly as an
    # ordinary `filter("date" => Date(...))` already does.
    # #576: this arm formats through `_format_date_operand` rather than `_format_filter_value`, so
    # it is not one of the thirteen — but it is a read-path formatter call one arm above the one
    # that WAS guarded, and leaving it out would make the "every formatter call on the read path
    # reaches one re-raise" claim false. No leak is reachable today (the operand union here is
    # `Date`/`DateTime`/`ZonedDateTime` and each has a concrete method), so this is the same
    # free-guard case as the two arms below it.
    # The label is DERIVED, not asserted: `_format_date_operand` picks `format_timezone_sql` for a
    # TIMESTAMP column and `format_date_sql` for a DATE one, so a hardcoded "date" would give the
    # wrong answer to "what rejected this" on exactly the timestamp path this guard exists for.
    # Computed inside the `catch`, so the happy path pays nothing for it.
    formatted_date = try
      _format_date_operand(operand, field_name, instruc; left_kind = left_kind)
    catch e
      _kind = left_kind === nothing ? _operand_column_kind(field_name, instruc) : left_kind
      _rethrow_as_filter_error(e, field_name,
                               _kind isa CDateTime ? _formatter_type_label(Models.format_timezone_sql) :
                                                     _formatter_type_label(Models.format_date_sql),
                               operand)
    end
    return add_parameter!(instruc, formatted_date)
  elseif operation in _COMPARISON_OPERATIONS &&
         isa(operand, Union{Integer,Float16,Float32,Float64,Base.UUID,Dates.Time,Dates.Period,Dates.CompoundPeriod})
    # #536 — every other `_CompareLiteral` scalar on the right of a COMPARISON, bound the way the
    # pair spelling binds it: through the rooted column's formatter, with no explicit SQL type. The
    # column decides, not the value's Julia type — `F("points") == true` on an IntegerField binds
    # `1` (`format_number_sql(::Bool)`), on a BooleanField `true` (`format_bool_sql`), and a `Float64`
    # binds `format_number_sql`'s `"1.5"` string rather than the raw `1.5` this used to fall through
    # to. On PostgreSQL the raw bind survived (the driver adapts it); on SQLite a column whose
    # formatter produces TEXT compared against a different representation and matched nothing, with
    # no error — which is why this arm sits ahead of the typed binds below.
    #
    # `Bool <: Integer`, so `true`/`false` arrive here too. Ahead of the Integer arm on purpose: that
    # arm is the ARITHMETIC one (date offsets, bitwise shifts), and only comparisons take this route.
    #
    # No column to ask (a nested expression rooted in a function, an unresolvable path): fall back to
    # the value's own formatter family — still a formatted value, never a raw bind — mirroring what
    # `_format_date_operand` does one arm up.
    f = _operand_column_field(field_name, instruc)
    column_formatter = f === nothing ? nothing : f.formatter
    # #801: the rooted column decides only while the left still EVALUATES to that column's kind.
    # `F("date") - F("dob")` is rooted at a DateField and evaluates to a day count, so
    # `(F("date") - F("dob")) > 30` bound `format_date_sql(30)` — an `InvalidValueError` on both
    # engines. When the kinds differ, the LEFT's kind decides through the #564 table: a day count has
    # no formatter there, so the literal falls to its own family below; a sub-day-promoted date is a
    # timestamp, so `(F("date") + Hour(6)) > 5` still refuses the `5` instead of binding an integer
    # SQLite would compare against TEXT (always true, silently). A left the build could not type
    # (`nothing`) keeps the root, as it always has: `(F("date") * 2) > 5` binds exactly as before.
    if left_kind !== nothing && f !== nothing && left_kind != field_canonical_kind(f)
      column_formatter = value_formatter(left_kind, instruc.connection)
    end
    # #814: an interval left with NO rooted column — `Max(ts) - Min(ts)`, a window difference — has
    # no column formatter to override, so it falls to the literal's own family below, and a duration
    # reached `format_number_sql(::Hour)`, a raw `MethodError`. The left's kind names the formatter.
    left_kind isa CInterval && f === nothing && (column_formatter = value_formatter(left_kind, instruc.connection))
    # #814: a duration and an interval belong together, in both directions. The kind that decides is
    # the left's, else the rooted column's — on SQLite only while the left IS that column. Untyped
    # arithmetic over a DurationField (`F("lap") * 2`) is an interval on PostgreSQL (`interval * 2`),
    # but on SQLite it is a NUMBER, and a duration bound against it would compare number with text.
    #   * A duration against anything else has no formatter that can bind it (`format_number_sql`
    #     has no `::Hour` method, a raw `MethodError`), and no meaning: `F("points") > Hour(1)`.
    #   * A `Time` against an interval reached `format_duration_sql`, which refuses it with a message
    #     about durations that never says why a `Time` is not one.
    rooted_kind = f === nothing ? nothing : field_canonical_kind(f)
    root_decides = !(field_name isa FExpression && field_name.operation !== nothing) ||
                   instruc.connection isa PormGPostgres
    decided_kind = left_kind !== nothing ? left_kind : root_decides ? rooted_kind : nothing
    if operand isa Union{Dates.Period,Dates.CompoundPeriod} && !(decided_kind isa CInterval)
      throw(QueryBuildError("A duration ($(operand)) compares only against an interval — a DurationField, " *
                            "or the difference of two timestamps. To compare dates, shift one instead: " *
                            "F(\"date\") + Day(30) > F(\"other_date\")."))
    elseif operand isa Dates.Time && (decided_kind isa CInterval || rooted_kind isa CInterval)
      throw(QueryBuildError("A Time ($(operand)) is a time of day, not a duration, so it does not compare " *
                            "against an interval. Write the duration instead: Hour(1), Minute(90), " *
                            "Hour(1) + Minute(30)."))
    end
    formatter = column_formatter !== nothing ? column_formatter :
                operand isa Base.UUID ? Models.format_uuid_sql :
                operand isa Dates.Time ? Models.format_text_sql :
                Models.format_number_sql
    # The BYTES are the pair path's; the SQL-text cast is not, and deliberately so — but only where
    # the cast agrees with the column. A numeric literal against a NUMERIC column (its formatter is
    # `format_number_sql`), or against no resolvable column, keeps the explicit PostgreSQL cast the
    # raw arms always gave it (`$1::bigint`, `$1::double precision`, pinned by `test_operators.jl`'s
    # bitwise examples): it is what lets `F("number") > 2.5` compare an integer column against a
    # double, where an uncast `$1` would be inferred as integer from the column and PostgreSQL would
    # reject "2.5". Everything else binds UNCAST, like a pair, so PostgreSQL types the parameter from
    # the column: a `Bool` (its formatted value is the column's — `1` on an IntegerField, `true` on a
    # BooleanField), a UUID or a Time, and a numeric literal against a text or boolean column —
    # `F("flag") == 1` binds `true` and must not carry `::bigint` (review of #536 measured the cast
    # following the LITERAL there: `"flag" = $1::bigint` with `true` bound, a PostgreSQL error).
    numeric_column = column_formatter === nothing || column_formatter === Models.format_number_sql
    sql_type = numeric_column && operand isa Union{Integer,Float16,Float32,Float64} && !(operand isa Bool) ?
               _infer_parameter_sql_type(operand, instruc) : nothing
    # #576: this arm was unguarded, and the issue listed it as SUSPECTED. Guarded since, and the guard
    # became load-bearing with #860: `format_text_sql` now refuses anything it cannot render as text
    # with `InvalidValueError`, so `F("surname") == 1.5` (a float or a UUID against a text column)
    # reaches it and reports a `FilterError`. The pairs this arm can still form against
    # `format_number_sql` (`::UUID`, `::Time`) have no method, so they raise `MethodError`, which
    # `_rethrow_as_filter_error` rethrows untouched by design.
    #
    # `field_name` is in scope, but `f` may be `nothing` (a nested expression, an unresolvable
    # path) — there the formatter came from the OPERAND's own type above, so the type label comes
    # from the formatter rather than from a column that was never found. The same when the left's
    # kind overrode the column's (#801): the column's `type` would name a formatter not used.
    return add_parameter!(instruc,
      _guarded_format(formatter, operand, operation, field_name,
                      f !== nothing && formatter === f.formatter ? f.type : _formatter_type_label(formatter));
      sql_type=sql_type)
  elseif isa(operand, String)
    # Check if it's a field reference
    if contains(operand, "__") || operand in instruc.object.model.field_names
      return _set_update_query(FExpression(field_name = operand, function_name = "F", column = operand), instruc)
    else
      # Keep scalar literals parameterized with an explicit SQL type on PostgreSQL so
      # expressions like integer_column / 2.0 don't get inferred back to integer.
      return add_parameter!(instruc, operand; sql_type=_infer_parameter_sql_type(operand, instruc))
    end
  elseif isa(operand, Integer)
    # SECURITY: parameterize the integer (bitwise shifts and ordinary arithmetic).
    #
    # #568 — the date arm that used to live here is GONE. It bound the placeholder FIRST and only
    # then asked whether the left was a date column, so on PostgreSQL a nested left arrived already
    # bound as `$n::bigint` and produced `timestamp with time zone + bigint`, which has no operator.
    # Whole days are now normalized into `Day(n)` by `_set_update_query_typed` BEFORE this function
    # is reached, so an integer that survives to here is genuinely arithmetic, never a duration.
    sql_type = (operation in ["<<", ">>"]) ? "integer" : _infer_parameter_sql_type(operand, instruc)
    return add_parameter!(instruc, operand; sql_type=sql_type)
  else
    # SECURITY: Use parameterized query for other numeric values
    return add_parameter!(instruc, operand; sql_type=_infer_parameter_sql_type(operand, instruc))
  end
end

function _set_update_query_left(value::Any, operation::String, instruc::SQLInstruction)
  if value isa String
    return _get_filter_query(value, instruc)
  elseif value isa Integer
    sql_type = (operation in ["<<", ">>"]) ? "integer" : _infer_parameter_sql_type(value, instruc)
    return add_parameter!(instruc, value; sql_type=sql_type)
  elseif value isa FExpression
    return _set_update_query(value, instruc)
  elseif value isa SQLTypeFunction
    return _get_select_query(value, instruc)
  else
    return _set_update_query(value, instruc)
  end
end

# #444: a bare CTE handle as an UPDATE SET value. Resolving it through the ordinary column path is
# what makes `update()`'s no-WITH-clause refusal (#433) fire with its own accurate message instead of
# a `MethodError` from the field formatter.
_set_update_query(v::CTEReference, instruc::SQLInstruction) = _get_select_query(v, instruc)

# #481: the same for a joined-copy handle. This is also the recursion target that renders the LEFT
# side of `Joined("d","x") == F("y")`, since `_set_update_query(::FExpression)` forwards a
# non-String `field_name` here.
_set_update_query(v::JoinedReference, instruc::SQLInstruction) = _get_select_query(v, instruc)

# #564 — the temporal path renders AND types, in one pass.
#
# `_set_update_query` keeps its `String` contract for every caller (`_get_select_query(::SQLTypeF)`
# in `build_helpers.jl`, through which SELECT, WHERE-side `F` comparisons and UPDATE SET all funnel;
# the insert path; the recursive operand and left-side calls). Only this file's own temporal
# recursion reads the second element, so nothing downstream had to change.
#
# EVERY ARM MUST RETURN A KIND EXPLICITLY. A missed arm returns `nothing`, and `nothing` degrades to
# `date(...)` on SQLite — which is the #527 truncation, silently. There is no arm where "it does not
# matter": where the result is genuinely not temporal, `nothing` is the ANSWER, not the default.
_set_update_query(v::FExpression, instruc::SQLInstruction) = first(_set_update_query_typed(v, instruc))

# #881 — the two doors out of the renderer (`_set_update_query` above, the projection in
# `build_query.jl`) see only kinds a reader or a binder can act on: an interval the renderer held in
# milliseconds leaves as its stored text, typed `CInterval`. Inside, `_render_expr_typed` and its
# helpers pass `_IntervalMs` along, so an interval stays a number for as long as it is being computed.
_set_update_query_typed(v::FExpression, instruc::SQLInstruction)::Tuple{String,TemporalKind} =
  _finalize_render(_render_expr_typed(v, instruc)..., instruc)

function _render_expr_typed(v::FExpression, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  if v.operation === nothing
    # Resolve the field using existing logic for joins and modifiers
    if v.field_name isa String
      # Render before typing: resolving the path is what populates the memo the kind lookup reads.
      # The column's TRUE kind, not the arithmetic-narrowed one: a bare `F(col)` projection over a
      # `TimeField` or a `DurationField` has a representation the read path must undo. Each CONSUMER
      # states which kinds it can act on, rather than the producer pre-narrowing for all of them.
      sql = _get_filter_query(v.field_name, instruc)
      return sql, _side_kind(v.field_name, instruc)
    elseif v.field_name isa Integer
      # A bare integer is a value, not a column — no representation to carry.
      return add_parameter!(instruc, v.field_name; sql_type=_infer_parameter_sql_type(v.field_name, instruc)), nothing
    else
      # Recursive call for nested expressions
      return _render_left_typed(v.field_name, "", instruc)
    end
  elseif v.operation == "~"
    # Unary NOT operator. Bitwise, never temporal.
    left_side = _set_update_query_left(v.field_name, v.operation, instruc)
    return "~($(left_side))", nothing
  elseif v.operation == "xor"
    # Bitwise, never temporal — on either engine.
    if instruc.connection isa PormGPostgres
      left_side = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)
      return "($(left_side) # $(right_side))", nothing
    elseif instruc.connection isa PormGSQLite
      # Positional Parameter Alignment: render each side twice to duplicate any embedded parameters
      left_side1 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side1 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      left_side2 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side2 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      return "((($(left_side1)) | ($(right_side1))) - (($(left_side2)) & ($(right_side2))))", nothing
    else
      throw(_unsupported_conn("xor update expression", instruc.connection))
    end
  elseif v.operation in ("+", "-") && v.operand isa Union{Dates.Period, Dates.CompoundPeriod, Interval}
    # Date arithmetic with an explicit Julia duration type (#25). Handled ahead of the generic
    # infix branch: a Period operand must NOT reach `_set_update_query_operand`, which would try to
    # bind it as a raw SQL parameter.
    return _render_date_period_arithmetic(v, instruc)
  else
    # Field with operation - handle nesting and date arithmetic properly.
    #
    # RENDER THE LEFT FIRST, THEN ASK WHAT IT IS. That order is the whole of #568's fix and is not
    # negotiable: rendering is what populates `instruc.tab_field_cache` for a dotted join key, so
    # `F("driverid__dob") + 30` can only be typed afterwards. Deciding first types every joined
    # temporal column as `nothing` and silently drops it to plain arithmetic.
    left_side, left_kind = _render_left_typed(v.field_name, v.operation, instruc)

    # #568 — A BARE INTEGER ON ± OVER A TEMPORAL LEFT IS WHOLE DAYS, rendered by the one temporal
    # renderer rather than by a second implementation. Ahead of the operand bind below, because that
    # bind is what used to break PostgreSQL: it stamped `$n::bigint` on the parameter before anything
    # asked whether the left was temporal, and `timestamp with time zone + bigint` has no operator.
    #
    # The two implementations this replaces both gated on `v.field_name isa String`, while the
    # DURATION path gates on the OPERAND's type. That asymmetry was the whole of #568: a duration
    # composes over nesting and an integer did not, so `(F(c) + 7) + 3` fell through to plain numeric
    # addition — a silent `2012` on SQLite (TEXT with NUMERIC affinity), a hard error on PostgreSQL.
    # `F(c) + 7` alone was correct on both since #527; only the nested spelling failed, and only
    # because of where the test was written.
    #
    # Normalized at RENDER time, not at construction time (`types.jl`'s `+`/`-` overloads), for two
    # reasons that are not close calls:
    #   * there is no type information at construction — `F("points") + 10` and `F("dob") + 10` are
    #     the same node shape, so an unconditional rewrite would send integer-column arithmetic into
    #     the date renderer and trip its soft validation on every one of them;
    #   * `FExpression` is a `struct` and the `F` docstring promises a caller may bind and reuse a
    #     node, so `x = F("dob") + 7` must still report `operand == 7`. The node stays faithful to
    #     what the user wrote; only the rendering is unified.
    #
    # `!(v.operand isa Bool)` because `Bool <: Integer` in Julia: without it `F("ts") + true` would
    # become `Day(true)` rather than staying the arithmetic the user wrote. `Dates.Day(n)` is exact —
    # a bare integer on a date column has meant whole days since #25 — and `_decompose_period` folds
    # `Day(0)` to an empty list, so `F(c) + 0` short-circuits to the identity and binds nothing.
    # `CDate`/`CDateTime` explicitly, because the left's kind is now the column's TRUE one: a
    # `TimeField` or a `DurationField` is a temporal representation but never the left of a day
    # shift, and must keep falling through to ordinary arithmetic exactly as it did before #568.
    if left_kind isa Union{CDate,CDateTime} && v.operation in ("+", "-") &&
       v.operand isa Integer && !(v.operand isa Bool)
      comps = _decompose_period(Dates.Day(v.operand))
      kind  = _shift_result_kind(left_kind, comps)   # whole days never promote; stated, not assumed
      return _render_temporal_shift(left_side, kind, v.operation, comps, instruc), kind
    end

    # #801 — ARITHMETIC OVER A TEMPORAL LEFT asks what the RIGHT evaluates to as well. A comparison
    # never takes this branch (`F("date") > F("dob")` is the ordinary case and stays below), nor does
    # a non-temporal left, so every other expression renders byte-for-byte as it did.
    if left_kind isa Union{CDate,CDateTime} && v.operation in ("-", _TEMPORAL_PAIR_REFUSED_OPERATIONS...)
      # #814: a TEXT literal on the right is refused on both engines. It bound as text: PostgreSQL has
      # no `date - text` and failed at execution, and SQLite subtracted the leading years of the two
      # strings, silently. The literal it meant is a `Date`, which is typed and bound as one.
      if v.operand isa String && !_is_field_path(v.operand, instruc)
        throw(QueryBuildError("`F(...) $(v.operation) \"$(v.operand)\"`: a String on the right of date " *
                              "arithmetic is text, not a date. Pass a date instead — " *
                              "F(\"date\") - Date(2009, 3, 1) — or a field name, F(\"date\") - \"dob\"."))
      end
      right_side, right_kind = _render_operand_typed(v.operand, v.field_name, v.operation, instruc;
                                                     left_kind = left_kind)
      # #882: an integer column on the right is a day count, typed once it has rendered.
      v.operation in ("+", "-") && (right_kind = _day_count_column_kind(v.operand, right_kind, instruc))
      if right_kind isa Union{CDate,CDateTime}
        if v.operation == "-"
          kind = _difference_result_kind(left_kind, right_kind)
          kind isa CInterval && _refuse_window_in_interval(v.field_name, v.operand, instruc)
          return _render_temporal_difference(left_side, right_side, kind, instruc)
        end
        throw(QueryBuildError("`$(v.operation)` between two date/timestamp values has no meaning; only " *
                              "`-` does (a whole number of days between two dates). To shift a date, " *
                              "add a duration instead: F(\"date\") + Day(30)."))
      end
      # #814: `date ± count` is a whole-day shift. #881: `date ± interval` is a shift by the interval.
      if v.operation in ("+", "-")
        if right_kind isa Union{CInt32,CInt64}
          return _render_day_count_shift(left_side, left_kind, _day_count_sql(right_side, right_kind, instruc),
                                         v.operation, true, instruc), left_kind
        end
        _is_interval_kind(right_kind) &&
          return _render_interval_shift(left_side, left_kind, right_side, v.operand, right_kind,
                                        v.operation, true, instruc)
        # #882: anything else beside a date used only the date's year on SQLite.
        _refuse_untyped_date_operand(v.operation, instruc)
      end
      # `*` and `/`: a date times an interval has no meaning on either engine; on SQLite the
      # interval would be milliseconds, so it is refused there rather than multiplied.
      right_kind isa _IntervalMs && throw(_sqlite_interval_error("`$(v.operation)` between a date and an interval"))
      return "($(left_side) $(v.operation) $(right_side))", nothing
    end

    # #881 — AN INTERVAL ON THE LEFT: a timestamp difference, arithmetic on one, or a `DurationField`
    # column. Everything it can be combined with is decided in one place, on both engines.
    _is_interval_kind(left_kind) && return _render_interval_left(v, left_side, left_kind, instruc)

    # #814 — the same pairing with the DATE on the right. `count + date` is the shift `date + count`.
    # A count MINUS a date has no meaning: PostgreSQL has no `integer - date` and failed at execution,
    # and SQLite subtracted a year. Refused on both. A count with a non-temporal right renders exactly
    # as before. (An interval on the left was decided above, by `_render_interval_left`.)
    #
    # #882: an integer column on the left is a count too (`F("points") + F("seen")`). Typed for this
    # branch only; the right still renders against the left's own kind, so an integer column with a
    # non-temporal right binds exactly as it did.
    count_kind = v.operation in ("+", "-") ? _day_count_column_kind(v.field_name, left_kind, instruc) : left_kind
    if count_kind isa Union{CInt32,CInt64} && v.operation in ("+", "-")
      right_side, right_kind = _render_operand_typed(v.operand, v.field_name, v.operation, instruc;
                                                     left_kind = left_kind)
      # #881: PostgreSQL has no `integer ± interval` and fails when the statement runs.
      _is_interval_kind(right_kind) && instruc.connection isa PormGSQLite &&
        throw(_sqlite_interval_error("`$(v.operation)` between a number and an interval"))
      if right_kind isa Union{CDate,CDateTime}
        v.operation == "-" &&
          throw(QueryBuildError("A day count minus a date has no meaning. To move a date back, subtract " *
                                "from the date instead: F(\"date\") - (F(\"date\") - F(\"dob\")), or " *
                                "F(\"date\") - Day(30)."))
        return _render_day_count_shift(right_side, right_kind, _day_count_sql(left_side, count_kind, instruc),
                                       "+", false, instruc), right_kind
      end
      return "($(left_side) $(v.operation) $(right_side))", nothing
    end

    # #814: a date literal subtracted from something that is not a date PormG can type — a number, a
    # text column, a function it does not type (`Sum`, `Coalesce` over mixed kinds). Bound as a date
    # and rendered as a bare `-`, it would subtract a year on SQLite and fail on PostgreSQL; refused
    # instead, naming the sides that are typed. `-` only: a date literal is also a COMPARISON operand
    # (#494), and `F("seen") > Date(…)` arrives here too.
    if v.operation == "-" && v.operand isa _TemporalLiteral
      throw(QueryBuildError("Subtracting a date ($(v.operand)) needs a date or timestamp on the left: a " *
                            "DateField or DateTimeField, a shift of one (F(\"date\") + Day(1)), " *
                            "Max/Min of one, or a `__@date` path. The left side here is none of those."))
    end

    # Ordering and arithmetic with an EXPRESSION on the right of a left that is neither a date nor an
    # interval (both were decided above). The right is typed for this one question and rendered
    # exactly once: `_render_operand_typed` is the call `_set_update_query_operand` makes for an
    # expression operand, and a field-path String is the `F(...)` it names, so the text is the same.
    if v.operation in _ORDERING_OPERATIONS || v.operation in _ARITHMETIC_OPERATIONS
      if v.operand isa FExpression || (v.operand isa String && _is_field_path(v.operand, instruc))
        right_side, right_kind = _render_operand_typed(v.operand, v.field_name, v.operation, instruc)
        # #881: an interval on the right (`F("points") * d`, `F("points") > d`).
        _is_interval_kind(right_kind) &&
          return _render_interval_right(v, left_side, left_kind, right_side, right_kind, instruc)
        # #882: a date on the right of `+`/`-` whose left PormG cannot type (a text column, `Sum(...)`,
        # `F("points") * 2`). Every typed left was handled above, so this left is not a count.
        v.operation in ("+", "-") && right_kind isa Union{CDate,CDateTime} &&
          _refuse_untyped_date_operand(v.operation, instruc)
        return "($(left_side) $(v.operation) $(right_side))", nothing
      end
    end

    # #564: the left's kind travels to the binder, so the representation the literal binds and the
    # one the wrapper renders come from the same value rather than from two resolvers that agree.
    right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc; left_kind = left_kind)

    return "($(left_side) $(v.operation) $(right_side))", nothing
  end
end

function _build_from_tables(row_join::Vector{JoinRow}, connection::Union{PormGPostgres, PormGSQLite})
  tables = String[]
  for row in row_join
    # #394: no try/catch. This used to `@error` and CONTINUE, which dropped a table from a correlated
    # FROM list and left the surviving aliases unconstrained — a wrong query emitted as a warning.
    # Everything that can raise here is a defect, not a tolerable condition: an `InvalidValueError`
    # means an INTERNALLY generated alias is not an identifier, and it has to surface. (A row with a
    # missing slot used to be the other case; since #487 a `JoinRow` cannot be constructed without
    # its relation and alias, so that one is unrepresentable rather than caught.)
    b = safe_table_identifier(row.b, connection)
    alias_b = quote_identifier(row.alias_b, connection)
    push!(tables, "$b AS $alias_b")
  end
  return join(unique(tables), ", ")
end

function _get_join_condition_list(row_join::Vector{JoinRow}, connection)
  # #45: this correlated UPDATE-FROM / DELETE-USING path only builds equi-anchors and ignores
  # on_conditions, so an anchor-less cjoin_on join would be emitted WITHOUT its ON (silently wrong).
  # The common update/delete path scopes rows via a subquery that DOES render cjoin_on correctly;
  # only this correlated path is unsupported — fail loudly rather than drop the join condition.
  for row in row_join
    if row isa AnchorlessJoin
      throw(QueryBuildError("cjoin_on is not supported in a correlated UPDATE-FROM/DELETE-USING (setting a " *
                    "column from a joined table); scope the mutation with a filter/subquery instead."))
    end
    # #394: the same rule, for a CTE. `update()` emits no `WITH` prefix — `build_cte_clause` is
    # reached only from the three READ paths — so a row_join entry naming a CTE renders
    # `FROM "<cte>" AS "Tb_N"` against a relation this statement never declares. That is as true of a
    # KEYED CTE as of a CROSS-joined one, which is why the check is on the entry being a CTE rather
    # than on the shape of its keys — `_joins_cte` is true for both kinds. The cross-joined case has
    # no key columns at all (its dict row carried SENTINEL empty strings, which used to raise inside
    # the loop below and be swallowed by a `catch` that dropped the ON condition entirely). Both fail
    # here now, before any SQL is built.
    if _joins_cte(row)
      throw(QueryBuildError("A CTE cannot be joined in a correlated UPDATE ... FROM: the statement emits " *
                    "no WITH clause, so the CTE it references is never declared. Scope the mutation with " *
                    "a filter or a subquery instead."))
    end
  end
  conditions = String[]
  for row in row_join
    # #394: no try/catch either — the guards above refuse to drop an ON clause, and until now the
    # loop below dropped one anyway on any failure, with nothing but an `@error`. An UPDATE ... FROM
    # or DELETE ... USING missing its ON condition matches every row of the joined table, so this is
    # the one place a swallowed identifier error corrupts data rather than returning wrong rows.
    # Everything reaching here is a `ModelJoin`: both anchor-less shapes and both CTE shapes are
    # refused above, and a `ModelJoin` cannot exist without its alias/key set (#487).
    row = row::ModelJoin
    alias_a = quote_identifier(row.alias_a, connection)
    key_a = safe_column_identifier(row.key_a, connection)
    alias_b = quote_identifier(row.alias_b, connection)
    key_b = safe_column_identifier(row.key_b, connection)
    push!(conditions, "$alias_a.$key_a = $alias_b.$key_b")
  end
  return conditions
end

function _build_join_conditions(row_join::Vector{JoinRow}, connection::Union{PormGPostgres, PormGSQLite})
  return _get_join_condition_list(row_join, connection)
end

function _set_clause_uses_join_aliases(set_clause::String,
  row_join::Vector{JoinRow},
  connection::Union{PormGPostgres, PormGSQLite})::Bool
  for row in row_join
    alias_b = quote_identifier(row.alias_b, connection)
    occursin("$alias_b.", set_clause) && return true
  end
  return false
end

# ─────────────────────────────────────────────────────────────────────────────
# The mutation fence (#765)
#
# Every UPDATE/DELETE that scopes rows through a query renders that query's predicates HERE, against
# the statement's own target alias — `UPDATE "t" AS "Tb" … WHERE <this>`, `DELETE FROM "t" AS "Tb"
# WHERE <this>` — never ONLY as `"pk" IN (SELECT "Tb"."pk" FROM "t" AS "Tb" WHERE …)`. (A joined
# statement keeps that IN as its index-driven selection, ANDed with this — `_target_pk_selection`.)
#
# The distinction is invisible in a quiet database and decisive in a busy one. Under PostgreSQL READ
# COMMITTED a statement that waits on a row lock re-checks the row's NEW version against its quals
# (EvalPlanQual) — but a self-subquery over the target is an independent scan of that table, read on
# the statement's snapshot, so its predicates are never re-evaluated. A filter written as a fence
# (`.filter("id" => k, "status__@in" => terminal).delete()`, a compare-and-delete) was therefore
# ignored whenever a concurrent UPDATE committed while the DELETE waited: the row went even though
# its new version matched nothing. Reproduced through Nitro.jl#379, on PostgreSQL 16.
#
# Two shapes, one rule — every predicate reaches the target through the OUTER alias:
#
#   - no joins → the WHERE conjuncts, verbatim. They are already written against "Tb".
#   - joins    → `EXISTS (SELECT 1 FROM (SELECT 1) AS "__pormg_anchor" <joins> WHERE <conjuncts>)`.
#     The joins' ON clauses reference the outer "Tb", which makes the subplan CORRELATED — PostgreSQL
#     re-evaluates it against the new row version, where it never re-runs an uncorrelated one.
#
# Why the one-row anchor rather than `FROM <first joined table>` with its ON moved into WHERE (the
# flattening `UPDATE … FROM` does): the joins are LEFT JOINs, and flattening turns them inner. A row
# with no parent must still produce its null-extended row, or `"parent__col__@isnull" => true` stops
# matching exactly the rows it exists for. With the anchor the join tree is the text the read builder
# rendered, so the row set is the one `pk IN (…)` selected, and both engines run it as is.
#
# One rewrite keeps that equivalence exact: RIGHT → INNER and FULL → LEFT. The chain is left-deep and
# rooted at the target, so a RIGHT/FULL hop null-extends the TARGET side — rows `pk IN (SELECT
# "Tb"."pk" …)` always dropped (a NULL pk is in no set), which is precisely INNER/LEFT. Verbatim, the
# anchor stands where the target stood and a RIGHT JOIN keeps every right-side row, so the EXISTS is
# true for every target row once one match exists anywhere — a silent widening of the write; and a
# FULL JOIN whose ON names only the outer row is not hash/merge-joinable, which PostgreSQL refuses.
#
# A joined fence is NOT used alone where it can be avoided — see `_target_pk_selection`.
#
# SQLite is not exposed to the race (writers are serialized), but runs the identical text: the fix is
# a shape, not a PostgreSQL branch, so there is no divergence to document.
#
# Parameters: the text order is JOIN-ON then WHERE, which is `_BUCKET_ORDER`'s order, so a statement
# built by `build()` flattens in text order with no extra step. A caller splicing several of these
# into one statement (the deletion collector) wraps each in the #432 nested-run mark/detach.
#
# GROUP BY / HAVING have no place in a row predicate. Both terminals refuse the shapes that produce
# them before building (`_reject_unsafe_mutation_shape`, `delete()`'s guards), so reaching one here is
# an internal error — raised rather than dropped, because dropping HAVING widens the statement.
#
# An empty result means "no predicate": the caller must omit the WHERE, not print `WHERE ` or
# `WHERE ()`.
# ─────────────────────────────────────────────────────────────────────────────
const _TARGET_ANCHOR_ALIAS = "__pormg_anchor"

function _target_predicate(instruction::SQLInstruction)::String
  # `group` alone is not the signal: every projection is pushed into it, and it only PRINTS under
  # `aggregate` (the read renderer's own condition).
  (isempty(instruction.having) && !(instruction.aggregate && !isempty(instruction.group))) || error(_emsg(
    "PormG internal error: a mutation's row predicate carries GROUP BY / HAVING, which the " *
    "UPDATE/DELETE guards should have refused — this should not happen; please report it."))

  conjuncts = join(instruction._where, " AND ")
  isempty(instruction.row_join) && return conjuncts

  io = IOBuffer()
  print(io, "EXISTS (SELECT 1 FROM (SELECT 1) AS ", quote_identifier(_TARGET_ANCHOR_ALIAS, instruction.connection))
  for j in instruction.join
    # Every rendered join opens with ` <how> JOIN ` (build_row_join_sql_text); see the header.
    print(io, "\n  ", replace(j, r"^ RIGHT JOIN " => " INNER JOIN ", r"^ FULL JOIN " => " LEFT JOIN "))
  end
  isempty(conjuncts) || print(io, "\n  WHERE ", conjuncts)
  print(io, ")")
  return String(take!(io))
end

# ─────────────────────────────────────────────────────────────────────────────
# The selection half of a JOINED mutation (#765)
#
# A joined fence alone costs a full scan. PostgreSQL cannot flatten an EXISTS whose correlation sits
# in a JOIN's ON (only a top-level-WHERE correlation is pulled up into a semi-join), so it stays a
# per-row SubPlan — and with every conjunct inside it, the outer statement has nothing indexable:
# `M.Result.objects.filter("resultid" => 1, "driverid__nationality" => "British").update(…)` scanned
# the whole table where the pre-#765 `pk IN (SELECT …)` semi-joined through the primary-key index.
#
# So a joined statement carries BOTH: `"Tb"."pk" IN (<this>) AND EXISTS (<the fence>)`. The IN is the
# pre-#765 selection, planned exactly as before; the EXISTS is what PostgreSQL re-checks on the new
# row version, and it only runs for rows the IN let through. On the snapshot the two agree, so the
# conjunction selects what either did; after a concurrent change, the EXISTS decides.
#
# The two halves come from TWO builds of the same query into one parameter collector — each value is
# bound twice, once per half, in text order — never from one build printed twice: a second print of
# one build's text would reuse its markers, and on SQLite a positional marker is consumed once.
#
# `nothing` for a keyless model: there is no pk to select through, so it takes the fence alone.
# ─────────────────────────────────────────────────────────────────────────────
function _target_pk_selection(instruction::SQLInstruction)::Union{Nothing,String}
  model = instruction.object.model
  pk_field_sym = get_model_pk_field(model)
  pk_field_sym === nothing && return nothing

  connection = instruction.connection
  safe_alias = quote_identifier(instruction.alias, connection)
  quoted_pk = safe_column_identifier(Models.model_column(model, String(pk_field_sym)), connection)  # db_column (#50)
  return _key_selection(instruction, safe_alias, safe_alias, quoted_pk)
end

# `<outer_alias>.<column> IN (SELECT DISTINCT <source_alias>.<column> FROM <target> as <alias> <joins>
# WHERE <conjuncts>)`: the query's row set, projected onto one column of one of its aliases. Every
# argument arrives quoted. The joins print verbatim, so the row set is exactly the one the read builder
# rendered, LEFT JOINs included.
function _key_selection(instruction::SQLInstruction, outer_alias::String, source_alias::String, column::String)::String
  connection = instruction.connection
  io = IOBuffer()
  print(io, outer_alias, ".", column, " IN (SELECT DISTINCT ", source_alias, ".", column)
  print(io, "\n  FROM ", safe_table_identifier(Models.model_table_name(instruction.object.model), connection),
    " as ", quote_identifier(instruction.alias, connection))
  for j in instruction.join
    print(io, "\n  ", j)
  end
  isempty(instruction._where) || print(io, "\n  WHERE ", join(instruction._where, " AND "))
  print(io, ")")
  return String(take!(io))
end

# The rows of one joined table that a joined query reads, as a predicate on `outer_alias`, an alias
# of that same table: `<outer_alias>.<key_b> IN (SELECT DISTINCT <alias_b>.<key_b> …)`. It is keyed on
# the hop's own join column, so it names every row the join can pair with, whichever side is the
# "one": the referenced pk on a forward hop, and every child on a reverse or many-to-many hop. The
# deletion collector locks these rows so a joined root filter cannot change mid-cascade (#771).
function _joined_key_selection(instruction::SQLInstruction, row::ModelJoin, outer_alias::String)::String
  connection = instruction.connection
  return _key_selection(instruction, outer_alias, quote_identifier(row.alias_b, connection),
    safe_column_identifier(row.key_b, connection))   # key_b is physical on a ModelJoin (#394)
end

# The row predicate of one arm the deletion collector splices into a shared statement: the fence
# alone when the query has no joins (or no primary key), `<pk selection> AND <fence>` otherwise.
# `build_one()` builds a FRESH copy of the query into `parameters`; it is called once, or twice for a
# joined arm. Each build is wrapped in the #432 mark/detach and re-emitted under `:where` in text
# order, so several arms can share one collector.
#
# `update()` does not come through here: its statement is built once at top level before the guards
# run, so it reuses THAT build as the selection half and builds only the fence a second time —
# the top-level buckets (`:join`, `:where`) already flatten in the IN's text order.
function _mutation_predicate(build_one::Function, parameters)::String
  mark = nested_parameter_mark(parameters)
  first_build = build_one()
  first_run = detach_nested_run!(parameters, mark)
  selection = isempty(first_build.row_join) ? nothing : _target_pk_selection(first_build)

  if selection === nothing
    set_context!(parameters, :where)
    reattach_parameters!(parameters, first_run)
    return _target_predicate(first_build)
  end

  mark = nested_parameter_mark(parameters)
  fence_build = build_one()
  fence_run = detach_nested_run!(parameters, mark)
  set_context!(parameters, :where)
  reattach_parameters!(parameters, first_run)   # the IN, first in the text
  reattach_parameters!(parameters, fence_run)   # then the EXISTS
  return selection * "\n  AND " * _target_predicate(fence_build)
end

# Shape guards shared by `update()` and `bulk_update()` (#665): the query state an `UPDATE`
# statement cannot express. Each one is refused rather than dropped, because dropping it widens
# the statement past what the caller built — `query.limit(5).update(...)` would mutate every
# matching row, not five. `op` names the terminal in the message; `update()`'s wording is pinned.
function _reject_unsafe_mutation_shape(q::SQLObject, op::String)
  # limit(), offset(), and order_by(): standard SQL UPDATE does not support these clauses. To
  # update a bounded set of rows, filter by primary key explicitly or compose a subquery.
  if q.limit > 0 || q.offset > 0 || !isempty(q.order)
    throw(UnsafeMutationError(
      "Cannot call $op on a query that has limit(), offset(), or order_by() set. " *
      "Standard SQL UPDATE does not support these clauses, and silently dropping them " *
      "risks updating more rows than intended. " *
      "Filter by primary key explicitly or compose a subquery to update a bounded set."
    ))
  end

  if q.distinct
    throw(UnsafeMutationError(
      "Cannot call $op on a query with distinct(). " *
      "DISTINCT collapses the result set, which would cause UPDATE to target " *
      "different rows than intended. Remove distinct() or filter by primary key."
    ))
  end

  if any(v -> isa(v, SQLTypeField) && isa(v.field, Union{SQLTypeFunction, SQLTypeF}) && v.field.aggregate, q.values)
    throw(UnsafeMutationError(
      "Cannot call $op on a query with group_by() / annotate aggregations. " *
      "GROUP BY collapses rows, making the UPDATE target ambiguous. " *
      "Remove the aggregation or filter by primary key."
    ))
  end

  # #668: a filter that resolves through a `values()` projection. The terminals build without the
  # projection (an UPDATE has none), so such a filter cannot mean what it meant on a read: a plain
  # alias key routed to HAVING was dropped (the #74 shape), and a key that also names a model field
  # (`values("points" => F("points") - 100)`) silently filtered the raw column instead.
  alias = _first_projection_alias_filter(q)
  alias === nothing || throw(UnsafeMutationError(
    "Cannot call $op with a filter on the values() alias \"$(alias)\". An UPDATE has no " *
    "projection, so the filter cannot resolve through it — PormG would have to drop it or apply it " *
    "to a different expression. Filter on the underlying field, or resolve the rows first and " *
    "pass .filter(\"pk__@in\" => ids)."
  ))
  return nothing
end

# The names a filter key resolves through the projection memo instead of the model (#668). A read
# looks a filter column up by `memo_key` — as the HAVING alias in `get_filter_query`, and as the
# memoized left-hand side in `_get_filter_query(::SQLTypeField)`, nested in `Q`/`Qor` or not. Only
# base-rooted names are reachable from a filter key, and a plain path projected under its own name
# (`values("points")`) renders the column itself, so dropping it changes nothing.
function _projection_filter_names(q::SQLObject)::Set{String}
  names = Set{String}()
  for v in q.values
    if v isa SQLTypeText   # `Value(x)`: memoized under its output name (`get_select_query`)
      name = _projection_output_name(v)
      name === nothing || push!(names, name)
    elseif v isa SQLField
      key = memo_key(v)
      (key === nothing || key[1] !== :base) && continue
      (v.field isa String && v.field == key[2]) && continue
      push!(names, key[2])
    end
  end
  return names
end

function _first_projection_alias_filter(q::SQLObject)::Union{Nothing,String}
  names = _projection_filter_names(q)
  isempty(names) && return nothing
  for f in q.filter
    hit = _projection_alias_in_filter(f, names)
    hit === nothing || return hit
  end
  return nothing
end

# Recursive in the shape of `_guard_no_aggregate_predicate` (build_query.jl), with its depth cap.
function _projection_alias_in_filter(f, names::Set{String}, depth::Int = 0)::Union{Nothing,String}
  depth > 32 && return nothing
  if f isa SQLTypeOper
    col = f.column
    (col isa SQLTypeField && col.field isa String && col.field in names) && return col.field
  elseif f isa Union{SQLTypeQ,SQLTypeQor}
    for g in (f isa SQLTypeQ ? f.filters : f.or)
      hit = _projection_alias_in_filter(g, names, depth + 1)
      hit === nothing || return hit
    end
  end
  return nothing
end

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model

  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
  ensure_transaction_scope(model, connection)

  # Check if is allowed to update
  !settings.change_data && throw(_write_not_allowed("update", conn_key))

  _reject_unsafe_mutation_shape(real_obj, "update()")

  # #668: an UPDATE has no projection, so the statement is built from a private copy with `values()`
  # emptied — the #665 shape `bulk_update` uses. Built as-is, a binding projection (`Value(5)`,
  # `F("points") * 2`) filed its operands into the `:select` bucket, which flattens ahead of SET and
  # WHERE: a positional misbind on SQLite (wrong value, wrong rows, no error), and bound-but-unused
  # `$N` on PostgreSQL. Aggregates and alias filters were refused above, so emptying drops nothing.
  work = deepcopy(real_obj)
  empty!(work.values)
  # `get_alias` is a counter: a second build on the SAME alias object would name its target "R1",
  # not "Tb". A joined update builds twice (#765 — selection, then fence), so the fence gets an
  # untouched copy of whatever the caller passed; `nothing` makes a fresh one either way.
  fence_alias = deepcopy(table_alias)
  instruction = build(work, table_alias=table_alias, connection=connection)

  # Don't allow to update a field without filter
  instruction._where |> isempty && throw(UnsafeMutationError("update() requires a filter — refusing to update every row. Add .filter(...) before .update(...)."))
  
  parameters = instruction.parameters
  fields = model.field_names

  # Check if the fields need to be updated automatically
  for field in fields
    if !haskey(objct.insert, field)
      if model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formatter(now(TimeZone(settings.time_zone)))
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formatter(today())
      end
    end
  end

  # Handle F expressions in SET clause
  # Switch context to :update for SET clause params (SET appears before WHERE/JOIN in SQL)
  set_context!(parameters, :update)
  set_clause_parts = String[]
  for field in keys(objct.insert)    
    # Validation checks
    validate_field_data(model, field, objct.insert[field], "update"; allow_primary_key = false)
    Models.is_many_to_many_field(model.fields[field]) && throw(QueryBuildError("ManyToManyField $(model.name).$(field) cannot be written in update(); use the many-to-many manager add, remove, clear, or set methods"))
    
    quoted_field = safe_column_identifier(Models.field_db_column(model.fields[field], field), connection)  # db_column (#50)

    # #444: a `CTE(...)` handle joins this branch rather than the value branch below. It is
    # unambiguously a COLUMN reference — never a literal — so binding it as a value was never right;
    # it reached `field.formatter` and died with a bare `MethodError` (outside the #231 taxonomy).
    # Routed here, it resolves as a column and `update()`'s own "this statement emits no WITH
    # clause" refusal (#433) fires with the accurate message, which is exactly what the pre-#444
    # `F("<cte>__col")` spelling produced.
    # #481: a `Joined(...)` handle is admitted here so it does NOT reach the field formatter as a
    # bare MethodError — and is then refused with an accurate message. Setting a column FROM a
    # joined copy is the correlated UPDATE-FROM path, which this statement shape cannot express
    # (it scopes rows through a subquery); that remains #174's fourth deferred edge.
    if isa(objct.insert[field], SQLTypeJoined)
      throw(QueryBuildError(
        "update(\"$(field)\" => Joined(\"$(objct.insert[field].alias)\", \"$(objct.insert[field].path)\")) is not supported: " *
        "the common update path scopes rows with a subquery, so a cjoin_on joined copy is not " *
        "visible to SET. Setting a column FROM a joined table needs the correlated UPDATE ... FROM " *
        "path, which is not implemented (#174)."))
    end
    if isa(objct.insert[field], SQLTypeF) || isa(objct.insert[field], SQLTypeFunction) ||
       isa(objct.insert[field], SQLTypeCTE)
      f_value = _set_update_query(objct.insert[field], instruction)
      push!(set_clause_parts, "$(quoted_field) = $(f_value)")
    else
      formatted_value = _format_single(model.fields[field], field, objct.insert[field], "update")
      placeholder = add_parameter!(parameters, formatted_value)
      push!(set_clause_parts, "$(quoted_field) = $(placeholder)")
    end
  end
   
  set_clause = join(set_clause_parts, ", ")   

  # Build secure UPDATE SQL with JOIN support
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  safe_alias = quote_identifier(instruction.alias, connection)

  has_joins = !isempty(instruction.row_join)
  sql = ""
  
  if has_joins
    if connection isa PormGPostgres || connection isa PormGSQLite
      # The SET-clause loop above can reach _build_row_join (e.g. update("x" => F("fk__col"))), so
      # row_join may have grown AFTER build() rendered instruction.join — the same late-discovery
      # hazard #404 fixed in build(). Exactly one UPDATE branch reads the stale instruction.join:
      # `_target_predicate`, which prints it into the EXISTS. This check is what excludes it — a
      # SET-discovered join necessarily puts its alias in set_clause, so the check returns true and
      # the UPDATE … FROM branch below rebuilds FROM/ON from instruction.row_join instead. Do NOT
      # drop this guard on the theory that the UPDATE path ignores instruction.join — it does not.
      # (#404's own trigger cannot reach here regardless: update() refuses a query carrying
      # order_by() in `_reject_unsafe_mutation_shape`.)
      set_uses_join_aliases = _set_clause_uses_join_aliases(set_clause, instruction.row_join, connection)

      if !set_uses_join_aliases && isempty(real_obj.ctes)
        # #765: `"Tb"."pk" IN (SELECT DISTINCT …) AND EXISTS (<fence>)`. The IN alone was the
        # pre-#765 shape, and PostgreSQL never re-checks it when the UPDATE waits on a row lock, so a
        # filter used as a fence was ignored; the correlated EXISTS is what it re-checks. The IN stays
        # as the index-driven selection (`_target_pk_selection`). The top-level build above is its
        # half — its `:join`/`:where` values flatten in the IN's text order — and the fence is a SECOND
        # build, lifted as one run behind them. A keyless model has no pk to select through and takes
        # the fence alone, bound through the top-level buckets directly (it used to take UPDATE …
        # FROM, which flattened its LEFT JOINs to inner and dropped `.on()` conditions).
        selection = _target_pk_selection(instruction)
        predicate = if selection === nothing
          _target_predicate(instruction)
        else
          fence_work = deepcopy(real_obj)
          empty!(fence_work.values)
          mark = nested_parameter_mark(parameters)
          fence = build(fence_work, table_alias=fence_alias, connection=connection, parameters=parameters)
          fence_run = detach_nested_run!(parameters, mark)
          set_context!(parameters, :where)
          reattach_parameters!(parameters, fence_run)
          selection * "\n  AND " * _target_predicate(fence)
        end
        sql = """
        UPDATE $(safe_table_name) AS $(safe_alias)
        SET $(set_clause)
        WHERE $(predicate)
        """
      else
        # PostgreSQL & SQLite 3.33+ support UPDATE FROM syntax
        from_clause = _build_from_tables(instruction.row_join, connection)
        join_conditions = _build_join_conditions(instruction.row_join, connection)
        
        # Merge structural joins and logical filters, then deduplicate
        final_where = unique([join_conditions; instruction._where])
        
        sql = """
        UPDATE $(safe_table_name) AS $(safe_alias)
        SET $(set_clause)
        FROM $(from_clause)
        WHERE $(join(final_where, " AND "))
        """
      end
    else
      @error "Error in update: Unsupported database type for JOIN operations" connection_type=typeof(connection)
      throw(_unsupported_conn("update() with JOINs", connection))
    end
  else
    # No joins - simple UPDATE
    sql = """
    UPDATE $(safe_table_name) AS $(safe_alias)
    SET $(set_clause)
    WHERE $(join(instruction._where, " AND \n   "))
    """
  end

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model.name, :update; 
                            parameters=parameters)
  end

  # @pormg_debug

  # return nothing

  # Execute with parameters and return affected row count (Django matched-rows semantics).
  try
    if connection isa PormGPostgres
      # The driver result exposes a matched-row count; backend_num_affected_rows
      # delegates to LibPQ.num_affected_rows in the PostgreSQL extension.
      result = fetch(settings, sql, parameters)
      return backend_num_affected_rows(connection, result)
    elseif connection isa PormGSQLite
      # SQLite changes() must run on the same connection as the UPDATE.
      # If we are already inside a transaction context, fetch() reuses the
      # pinned connection so a subsequent SELECT changes() is safe.
      tx_conn = transaction_connection_for(settings)
      if tx_conn !== nothing
        fetch(settings, sql, parameters)
        changes_result = fetch(settings, "SELECT changes()")
        rows = changes_result |> DataFrames.DataFrame
        return Int(rows[1, 1])
      else
        # No active transaction — wrap in run_in_transaction to pin the
        # connection for both the UPDATE and SELECT changes().
        return run_in_transaction(settings) do
          fetch(settings, sql, parameters)
          changes_result = fetch(settings, "SELECT changes()")
          rows = changes_result |> DataFrames.DataFrame
          return Int(rows[1, 1])
        end
      end
    else
      throw(_unsupported_conn("update()", connection))
    end
  catch e
    @error "Error executing UPDATE query" exception=(e, catch_backtrace()) sql=sql
    rethrow(e)
  end
end


# #564 — the shared body of `query_list`, returning the BUILT handler alongside the result.
#
# `query()` writes its per-build artifacts — `parameters`, and now `projection_kinds` — onto the copy
# it was handed, and that copy is local to this function. `query_list` therefore had no way to hand
# the kind map to `_list_raw`, which holds the ORIGINAL handler: the map went out of scope the
# moment the result came back. Splitting the body is what closes that, and it changes nothing about
# `query_list` itself, whose signature and behaviour are untouched.
#
# #612: the docstring that used to sit above this comment belongs to `query_list`, not to
# this helper — its example ends `query |> DataFrame`. The split left it stranded here, so
# BOTH functions were undocumented: this one by accident, `query_list` by omission.
function _execute_select(objct::SQLObjectHandler)
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  # #43: build on a copy so the read path never mutates the caller's handler.
  # query() writes back q.object.parameters and materializes the per-build CTE
  # "model" into q.object.ctes; doing that on `objct` would give .list()/.first()
  # a hidden write side effect and make .copy() aliasing corrupt re-execution.
  # deepcopy(SQLObjectQuery) now clones CTE state independently (see _copy_ctes),
  # so the copy is fully isolated. Mirrors _count/_exists/get, which already copy.
  q = deepcopy(objct)
  sql = query(q, connection=connection, show_query=:execute)
  return fetch(settings, sql, q.object.parameters), q, connection
end

"""
Fetches a list of records from the database for the given `SQLObjectHandler`.

# Returns
- The result of the database query as returned by `fetch`.

# Example
```julia
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values("driverid__forename", "constructorid__name", "laps" => Count("laps"))
query.order_by("-laps")
df = query |> DataFrame
```
"""
function query_list(objct::SQLObjectHandler; show_query::Symbol = :execute)
  if show_query !== :execute
    settings, connection, conn_key = get_settings(objct)
    q = deepcopy(objct)
    return query(q, connection=connection, show_query=show_query)
  end
  return first(_execute_select(objct))
end

"""
Creates a DataFrame directly from a SQLObjectHandler query.

This extends the DataFrame constructor to work directly with PormG query objects. Since #582 it
applies the same read-side value coercion as `list()`: a temporal column or expression alias
holds `ZonedDateTime` / `Date` / `Time` / `CompoundPeriod` values on both engines, not the
driver's raw text on SQLite. PostgreSQL DataFrames are unchanged — the driver already delivers
typed values there. To keep the engine's own text on purpose, project it as text: `ToChar(...)`
or `Cast(F(col), "TEXT")`.

# Arguments
- `objct::SQLObjectHandler`: The SQL object handler containing the query

# Returns
- `DataFrames.DataFrame`: The query results as a DataFrame

# Example
```julia
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values("driverid__forename", "constructorid__name", "laps")
df = query |> DataFrame  # Direct conversion to DataFrame
```
"""
function DataFrames.DataFrame(objct::SQLObjectHandler)
  # #582 — this used to be `query_list(objct) |> DataFrame`, which bypassed the #564 coercion
  # `_list_raw` applies, so `list()` and `DataFrame(query)` disagreed on the type of every temporal
  # column on SQLite. Same executed build, same parser table, column-wise instead of row-wise.
  result, built, connection = _execute_select(objct)
  df = DataFrames.DataFrame(result)
  parsers = _projection_parsers(built, connection)
  parsers === nothing && return df          # nothing to coerce — PostgreSQL unless an INTERVAL is projected (#581)
  for (name, parser) in parsers
    # The wildcard recorder registers both a field's name and its `db_column`, and only one of them
    # is in any given result — same guard as `_list_raw`'s `haskey`. `map` widens the column from
    # `Union{Missing,String}` to `Union{Missing,T}`; the parsers pass `missing` through untouched.
    hasproperty(df, name) && (df[!, name] = map(parser, df[!, name]))
  end
  return df
end

# #564 / #582 — which result-row columns need a read-side parser on THIS connection, or `nothing`
# when none does. The one selection both row terminals (`_list_raw`) and the tabular terminal
# (`DataFrame`) consult, so the two cannot disagree about what is coerced.
#
# The build records the canonical kind of each projection (`projection_kinds`), and the
# representation table (`value_repr.jl`) says which parser undoes that kind on this backend. Django
# resolves its own read coercion the same way — off `expression.output_field`, never off the
# alias's spelling. There is no `connection isa PormGSQLite` test here: the backend dimension
# belongs to the table, so a third backend becomes table entries rather than a branch. On
# PostgreSQL every `value_parser` but INTERVAL's answers `nothing` (#581 pins that one type across
# drivers), so a query projecting no INTERVAL returns `nothing` after one dispatch per projection.
function _projection_parsers(built::SQLObjectHandler, connection)::Union{Nothing,Dict{Symbol,Function}}
  parsers = nothing
  for (name, kind) in built.object.projection_kinds
    parser = value_parser(kind, connection)
    parser === nothing && continue
    parsers === nothing && (parsers = Dict{Symbol,Function}())
    parsers[name] = parser
  end
  return parsers
end

function _list_raw(objct::SQLObjectHandler)
  result, built, connection = _execute_select(objct)

  # `Dict{Symbol,Any}` EXPLICITLY, and it is an ENABLING change rather than a style choice. The
  # un-annotated comprehension this replaces NARROWS: a projection whose columns are all TEXT infers
  # `Dict{Symbol,String}`, and `setindex!`ing a `ZonedDateTime` into one throws. That narrowing is
  # the entire reason the old code rebuilt every `Dict` from scratch to coerce a single column.
  # Annotating it is what makes in-place coercion possible — and it makes `list(:dict)` finally
  # return what its own docstring promises.
  rows = [Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row)) for row in Tables.rowtable(result)]

  # #564 — COERCE BY WHAT EACH PROJECTION EVALUATES TO, not by whether its alias happens to name a
  # plain column.
  #
  # What this replaces (`_sqlite_datetime_aliases`) had four gates, ALL of which had to pass: the
  # projection had to be an `SQLTypeField`, its `.field` had to be a plain `String`, that string had
  # to contain no `__`, and the field had to be an `sDateTimeField`. So the coercion set was exactly
  # "bare, unjoined, primary-model `DateTimeField` columns" — every expression alias, every joined
  # column, and every `DateField`/`TimeField`/`DurationField` fell outside it and came back as raw
  # text, while PostgreSQL's driver delivered typed values for all of them.
  #
  # The parser selection lives in `_projection_parsers` (above), shared with `DataFrame(query)`
  # since #582 so the row and tabular terminals coerce the same columns.
  parsers = _projection_parsers(built, connection)
  parsers === nothing && return rows

  for row in rows, (name, parser) in parsers
    # A key the row does not carry is skipped rather than added: the wildcard recorder registers
    # both a field's name and its `db_column`, and only one of them is in any given result.
    haskey(row, name) && (row[name] = parser(row[name]))
  end
  return rows
end

"""Return model-aware `PormGRow` objects. Default format."""
function list(objct::SQLObjectHandler, ::Val{:row}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  model = objct.object.model
  return [PormGRow(row, model) for row in _list_raw(objct)]
end

"""Return plain `Dict{Symbol,Any}` rows for framework integrations that need real dictionaries."""
function list(objct::SQLObjectHandler, ::Val{:dict}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  return _list_raw(objct)
end

# #564 — a temporal value is serialized as the TEXT its own formatter writes, not by whatever
# `JSON.json` makes of the Julia type.
#
# `Date`, `Time` and `ZonedDateTime` all have a `JSON` representation that happens to be right, but
# `Dates.CompoundPeriod` does not: `JSON.json` has no method for it and falls back to struct
# reflection, which emits `{"periods":[{"value":1},{"value":49}]}` — **the units are gone**, and no
# consumer can reconstruct a duration from that. On PostgreSQL that has always been the shape (LibPQ
# delivers a `CompoundPeriod`); on SQLite it became reachable when #564 started coercing
# `DurationField`. Parity with a lossy shape is not the parity this table is for.
#
# So the JSON arm asks the same owner every other representation question goes through. For the three
# kinds that already serialized correctly this is a no-op that now HOLDS rather than coincides.
# FAIL-OPEN, like every parser in this table, and for a sharper reason here: `format_duration_sql`
# REFUSES a month or year component ("Months and years are ambiguous"), because `DurationField`
# deliberately does not store one. But this function dispatches on the Julia VALUE, not on a column
# kind — so a PostgreSQL `interval` holding `'1 month'`, from a column PormG did not write or a
# database it introspected, reaches it. Formatting unconditionally would turn a working
# `list(:json)` into a hard error, which is a worse regression than the lossy shape this fixes.
#
# So: format what the formatter accepts, hand back anything else untouched. The `JSON` fallback for
# an unformattable period is still poor, but it is what shipped before and it is not an exception.
_json_value(v) = v
function _json_value(v::Union{Dates.Period, Dates.CompoundPeriod})
  try
    return Models.format_duration_sql(v)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    return v
  end
end

# #644 — a `DecimalField` serializes as its EXACT decimal digits, emitted as a JSON number.
#
# The issue reported `{"s":0,"c":12345,"q":-2}` from struct reflection. That is NOT what happens, and
# the truth is worse in one direction and much narrower in another. `Decimals.Decimal <: AbstractFloat`,
# so `JSON` takes its number path and routes the value through a `Float64`:
#
#   exact 12345678901234567.89  ->  1.2345678901234568e16   (the last digits are wrong)
#   exact 5                     ->  5.0
#
# So a `DecimalField(10, 2)` — the constructor default, and every width up to ~16 significant digits —
# is CORRECT today; the defect appears only past what a `Float64` holds. That is exactly the drift
# `DecimalField` exists to prevent (`docs/src/index.md` promises it), so it is still silent wrong
# data — just not by the mechanism, nor at the width, the issue describes.
#
# At the declared `[compat] JSON = "1"` FLOOR it is not lossy but fatal: measured, JSON 1.0.0 raises
# `MethodError: no method matching +(::Nothing, ::Int64)` on any `Decimal`, so `list(:json)` over a
# PostgreSQL `DecimalField` cannot run at all there; 1.1.0 onward emits the lossy number. CI's
# `floor-resolve` job resolves that floor, and this arm is what makes it honest: every path a real
# value can take now hands `JSON` a `JSONText` or a `String`, both of which render at 1.0.0. Only the
# degenerate paths below — the formatter returning a non-string, or throwing — still pass the `Decimal`
# through, and neither is reachable from a driver. That distinction is not academic: the first version
# of this arm returned the `Decimal` on the rejected-text path too, and `floor-resolve` went red.
#
# `JSON.JSONText`, not a string: it splices the digits UNQUOTED, so the column stays a JSON NUMBER on
# both engines — SQLite's NUMERIC affinity hands back an `Int64`/`Float64`, which already serialized as
# a number, and a string here would have changed the column's JSON TYPE on PostgreSQL only. Django's
# `DjangoJSONEncoder` and DRF's `COERCE_DECIMAL_TO_STRING` both choose a string, which is exact
# end-to-end but obliges every consumer to parse; the maintainer chose the number on that trade (#644).
#
# Be precise about what that buys, because the first version of this comment over-claimed it: on its
# own, this arm made the two engines agree on the JSON *type*, not on the TEXT. Julia prints a
# `Float64` at or above 1e6 in exponent form, so from a million up SQLite emitted `1.23456789e6` where
# PostgreSQL emitted `1234567.89`. #648 closed that for every column PormG creates: SQLite reads a
# `DecimalField` of at most 15 digits back as a `Decimal` too (`Dialect._parse_sqlite_decimal`), so
# both engines reach this arm and emit the same text. What still arrives as a `Float64` — a wider
# column created outside PormG, an aggregate or arithmetic result, a `create()` row — keeps SQLite's
# rendering. `docs/src/read/index.md` states the boundary user-facing.
#
# GUARDED, because `JSONText` is a raw splice with no escaping: text that is not a JSON number would
# produce an INVALID DOCUMENT, strictly worse than the lossy value this fixes.
#
# The guard is not hypothetical across the declared `Decimals = "0.4, 0.5"` range, because the two
# majors do not print the same text. 0.4.1 renders positionally via `Base.print`; 0.5.x renders via
# `Base.string` -> `scientific_notation`, which uses exponent form whenever the exponent is positive.
# Measured: 0.4.1 prints `Decimal(0, 1, -20)` as `0.00000000000000000001` where 0.5.0 prints `1E-20`.
# Both are valid JSON numbers, which is the point — the pattern is the JSON spec's own number
# production rather than "whatever Decimals printed when this was written".
#
# The SHAPE is therefore version-dependent even though the VALUE is not, and the difference is not
# confined to extremes: `parse` normalises, so PostgreSQL's `"10.00"` from a `NUMERIC(10,2)` arrives as
# `Decimal(0, 1, 1)` — exponent 1 — which 0.4.1 prints `10` and 0.5.x would print `1E+1`. Numerically
# equal, valid JSON either way, and unreachable today because every LibPQ release pins `Decimals 0.4`
# (see `test/unit/test_compat_guards.jl`), and the `Decimal` SQLite yields since #648 is built with a
# non-positive exponent on purpose (`Decimal(0, 10, 0)`, which prints `10` on both). Worth knowing
# before anyone widens that pin: the engines would still agree with each other, but the emitted text
# would change. `Project.toml` cannot carry this note — CompatHelper strips comments — so it is here.
#
# FAIL-OPEN like the arm above: anything the guard rejects, and any throw, hands back the untouched
# value, which serializes exactly as it did before.
# `\A` and `\z`, NOT `^` and `$`. PCRE's `$` matches before a trailing newline, so the `^…$` spelling
# accepts `"1\n"` — verified. That particular string splices to `{"v":1\n}`, which is still valid JSON
# (a newline is whitespace there), and `Decimals` cannot produce it anyway, so this is not a live
# hole. It is tightened regardless: this guard's entire job is to answer "is this PROVABLY valid JSON
# number text", and a pattern that accepts a string it was not meant to accept cannot answer that.
# `[0-9]` rather than `\d`, and this one is LOAD-BEARING rather than stylistic — do not "simplify" it.
# Julia compiles regexes with PCRE's UCP flag, so `\d` is UNICODE-aware here: measured,
# `occursin(r"\A\d+\z", "١٢٣")` is `true`. With `\d` the pattern would accept `"1٢"` — the ASCII `[1-9]`
# satisfies the lead and `\d*` swallows the Arabic-Indic digit — and splice it raw as a JSON number,
# which is exactly the invalid document this guard exists to prevent. `[0-9]` rejects it.
const _JSON_NUMBER_RE = r"\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?\z"

# The rejected-text fallback is the decimal's TEXT, not the `Decimal` — and CI's `floor-resolve` job is
# what established that it has to be. Handing the value back unchanged looks like the obvious fail-open
# and is the opposite of one at the declared floor: JSON 1.0.0 raises
# `MethodError: no method matching +(::Nothing, ::Int64)` on any `Decimal`, so the "safe" path was a
# HARD ERROR there — precisely the regression the #564 arm above refuses to introduce. The text is
# exact, always renders, and renders at every version in the range; it is a JSON string rather than a
# number only for a value whose text is not a JSON number in the first place, so there is no consistency
# being given up. Unreachable from a driver either way (`parse` normalises), which is why only a
# constructed value and a CI job resolving the floor could find it.
#
# The two remaining `return v` paths — no text at all, because the formatter returned a non-string or
# threw — keep the pre-#644 behavior, since there is nothing better to hand over than what shipped.
function _json_value(v::Decimals.Decimal)
  try
    txt = Models.format_number_sql(v)
    txt isa AbstractString || return v
    return occursin(_JSON_NUMBER_RE, txt) ? JSON.JSONText(txt) : String(txt)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    return v
  end
end

# The ONE row -> JSON shape, and the only place it is written. Two emitters call it: `list(:json)`
# below, on a raw `_list_raw` dict, and the `lower` hook further down, on a `PormGRow`'s `_data`.
#
# One function rather than the same comprehension in both, because "the same JSON either way" is the
# contract and a restated rule drifts silently while still type-checking (the #474 defect shape).
_json_row(data::Dict{Symbol, Any}) = Dict(String(k) => _json_value(v) for (k, v) in data)

"""Return a JSON string without allocating `PormGRow` wrappers."""
function list(objct::SQLObjectHandler, ::Val{:json}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  return JSON.json([_json_row(row) for row in _list_raw(objct)])
end

# #641 — a `PormGRow` handed to `JSON.json` used to serialize the SCHEMA, not the row.
#
# JSON.jl has no method for `PormGRow`, so it reflects over all three slots and walks into
# `_model::PormGModel` — the model graph, which is a dense, cyclic DAG (`Model_Type.fields` ->
# `sForeignKey.to` -> `Model_Type.related_objects` -> `ReverseRelation.model_resolved` -> ...). The
# writer breaks true cycles with an ANCESTOR stack, so it terminates, but it memoizes nothing: every
# distinct PATH through the graph is serialized again. That is exponential in the schema's density,
# and it is the whole bug — a 26-character row measured 1,843,565 characters and 5.3s of CPU on the
# 14-model F1 fixture, and an application schema OOM-killed the process at 28.5 GB.
#
# Exactly the defect `src/display.jl` (#534) fixed for `Base.show`, one hop over: same graph, same
# absence of a method, serialization instead of display. And like that fix it is cheap, because ONE
# method on the type a user actually hands to a serializer bounds the whole thing.
#
# `getfield(r, :_data)`, never `r.x` — display.jl's rule 3, for the same reason: `PormGRow` overloads
# `getproperty`, so property access would run the many-to-many / lazy-traversal dispatch from inside
# a serializer.
#
# `::JSON.JSONStyle` (the abstract parent of the read and write styles) and `StructUtils` both exist
# from JSON 1.0.0, which JSON exports — so this holds at the declared `JSON = "1"` floor and needs no
# new dependency.
JSON.StructUtils.lower(::JSON.JSONStyle, r::PormGRow) = _json_row(getfield(r, :_data))

function list(objct::SQLObjectHandler, ::Val{F}; kwargs...) where F
  throw(QueryBuildError("Unknown list format :$F. Expected :row, :dict, or :json."))
end

list(objct::SQLObjectHandler, format::Symbol; kwargs...) = list(objct, Val(format); kwargs...)
list(objct::SQLObjectHandler; kwargs...) = list(objct, Val(:row); kwargs...)

"""
    first(objct::SQLObjectHandler; show_query::Symbol = :execute)

Return the first `PormGRow` matching the current query, or `nothing` if no records match.

Like every read terminal (`count`, `exists`, `list`, `get`), `first` executes on an
internal copy of the handler — the `limit(1)` it needs is applied to that copy, never
to `objct`. The handler is reusable afterwards, including for `.update()`:

```julia
q = M.Driver.objects
q.filter("nationality" => "British")
driver = q.first()                      # q is unchanged — no limit leaks in
q.update("nationality" => "English")    # still valid on the same handler
```
"""
function first(objct::SQLObjectHandler; show_query::Symbol = :execute)
  # #199: copy-first like count/exists/list — limit(1) must not leak into the caller's handler
  q = deepcopy(objct)
  q.limit(1)
  res = list(q, show_query=show_query)
  if show_query !== :execute
    return res
  end
  return isempty(res) ? nothing : res[1]
end
# NOTE (#200): the curried `first(; kwargs...) = (objct) -> first(objct; kwargs...)` form
# was removed — a zero-positional method on Base.first with no PormG type is type piracy.
# `q.first(...)`, `first(q; kw...)` and `q |> first` are unaffected. See the piracy guard in
# test/unit/test_public_exports.jl. (`delete`/`inspect_query` keep their curried forms — those
# functions are package-owned, so a kwargs-only method on them is not piracy.)

# Reverse a single ORDER BY term by CONSTRUCTING the reversed one — the reverse of an ORDER BY
# yields the last row (#208). Flip ASC↔DESC, and any EXPLICIT nulls placement (an unset `nothing`
# stays default so the renderer keeps its orientation-derived NULLS placement). #540: `SQLOrder` is
# an immutable struct, so this cannot write into the caller's term — which is the point: the term
# is a value the caller may still hold, and `last()` works on a copy of the handler anyway.
# Non-SQLOrder ordering terms are returned as-is (best effort).
function _invert_order(o::SQLOrder)::SQLOrder
  # One conditional, NOT two flips in sequence: :first→:last followed by :last→:first is a no-op.
  nulls = o.nulls === :first ? :last : o.nulls === :last ? :first : o.nulls
  return SQLOrder(o.field, o.order, o.orientation == "DESC" ? "ASC" : "DESC", o._as, nulls)
end
_invert_order(o) = o

"""
    last(objct::SQLObjectHandler; show_query::Symbol = :execute)

Return the last `PormGRow` matching the current query, or `nothing` if no records match.

The mirror of [`first`](@ref): it inverts the query's ordering and takes one row. When an
`order_by(...)` is set, `last()` returns the row that `first()` would return under the reversed
ordering. When **no** ordering is set, it falls back to **primary-key descending**, so `last()`
is always well-defined (matching Django). Like every read terminal, it runs on an internal copy —
the inverted ordering and `limit(1)` never leak into the caller's handler.
"""
function last(objct::SQLObjectHandler; show_query::Symbol = :execute)
  # #199: copy-first like first/count/list — the ordering flip and limit(1) apply to the copy only.
  q = deepcopy(objct)
  if isempty(q.object.order)
    # No ordering: fall back to primary-key DESC so last() is meaningful (Django parity).
    model = q.object.model
    pk_sym = try
      Models.get_model_pk_field(model)
    catch e
      # get_model_pk_field throws ModelDefinitionError on a composite pk (#239; was
      # ArgumentError). Re-home it as an actionable QueryBuildError.
      e isa ModelDefinitionError || rethrow(e)
      throw(QueryBuildError("last() with no order_by() needs a single-column primary key to order by, but $(model.name) has none — add an explicit order_by(...)."))
    end
    pk_sym === nothing &&
      throw(QueryBuildError("last() with no order_by() needs a single-column primary key to order by, but $(model.name) has none — add an explicit order_by(...)."))
    q.order_by("-" * String(pk_sym))
  else
    # Reverse the existing ordering; the reversed ORDER BY's first row is the original's last.
    # #540: rebuild the copy's own order list from constructed terms — nothing is written into an
    # `SQLOrder`, which is a `struct` now.
    map!(_invert_order, q.object.order, q.object.order)
  end
  q.limit(1)
  res = list(q, show_query=show_query)
  if show_query !== :execute
    return res
  end
  return isempty(res) ? nothing : res[1]
end

# Shared body for earliest()/latest(): apply the (already-oriented) ordering fields, take one row,
# and raise DoesNotExist on an empty queryset (Django parity — these behave like get(), not first()).
function _extreme(objct::SQLObjectHandler, order_fields, opname::String; show_query::Symbol)
  q = deepcopy(objct)
  q.order_by(order_fields...)
  q.limit(1)
  if show_query !== :execute
    return list(q, show_query=show_query)
  end
  rows = list(q)
  if isempty(rows)
    model_name = q.object.model.name
    filter_repr = isempty(q.object.filter) ? "(none)" : join(_get_filter_repr.(q.object.filter), ", ")
    throw(DoesNotExist(model_name, "$(opname): $(filter_repr)"))
  end
  return rows[1]
end

# Flip a single order token's direction for latest() (the ASC↔DESC inverse of what the user wrote):
# "field" → "-field" (DESC), "-field" → "field" (ASC). Matches Django's latest("-f") == earliest("f").
_invert_order_token(f::AbstractString) = startswith(f, "-") ? String(f[2:end]) : "-" * String(f)
_invert_order_token(f) = throw(QueryBuildError("earliest()/latest() fields must be field-name Strings (\"-field\" for the opposite direction); got $(typeof(f))."))

"""
    earliest(objct::SQLObjectHandler, fields...; show_query = :execute) -> PormGRow

Return the earliest row ordered by `fields` (ascending; a `"-field"` flips that term to
descending). Requires at least one field and raises `DoesNotExist` when no rows match — the
extreme-row counterpart of [`get`](@ref), matching Django's `earliest()`.
"""
function earliest(objct::SQLObjectHandler, fields...; show_query::Symbol = :execute)
  isempty(fields) &&
    throw(QueryBuildError("earliest() requires at least one field to order by, e.g. earliest(\"dob\")."))
  return _extreme(objct, fields, "earliest"; show_query=show_query)
end

"""
    latest(objct::SQLObjectHandler, fields...; show_query = :execute) -> PormGRow

Return the latest row ordered by `fields` (descending; a `"-field"` flips that term to
ascending). Requires at least one field and raises `DoesNotExist` when no rows match. Django's
`latest()`; `latest("f") == earliest("-f")`.
"""
function latest(objct::SQLObjectHandler, fields...; show_query::Symbol = :execute)
  isempty(fields) &&
    throw(QueryBuildError("latest() requires at least one field to order by, e.g. latest(\"dob\")."))
  return _extreme(objct, _invert_order_token.(fields), "latest"; show_query=show_query)
end

function _get_filter_repr(filter::SQLTypeOper)::String
  column = filter.column isa SQLTypeField ? filter.column.field : filter.column
  return "$(column) $(filter.operator) $(filter.values)"
end

function _get_filter_repr(filter::SQLTypeQ)::String
  return "(" * join(_get_filter_repr.(filter.filters), " AND ") * ")"
end

function _get_filter_repr(filter::SQLTypeQor)::String
  return "(" * join(_get_filter_repr.(getfield(filter, :or)), " OR ") * ")"
end

_get_filter_repr(filter) = sprint(show, filter)

"""
    get(objct::SQLObjectHandler, filters...; show_query=:execute) -> PormGRow

Return exactly one row matching the query filters.

Filters can be passed inline or applied with `.filter()` before calling `.get()`:

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")
driver = M.Driver.objects.filter("driverref" => "hamilton").get()
```

Raises `DoesNotExist` when no rows match and `MultipleObjectsReturned` when more
than one row matches.

Like every read terminal, `get` executes on an internal copy of the handler: inline
filters do **not** persist on `objct`, so the handler can be reused afterwards with
its original filter list intact.
"""
function get(objct::SQLObjectHandler, filters...; show_query::Symbol = :execute)
  # #199: copy-first — inline filters and the limit(2) probe apply to the copy only,
  # so they never leak into the caller's handler.
  q = deepcopy(objct)
  !isempty(filters) && _filter!(q.object, filters)
  q = q.limit(2)

  if show_query !== :execute
    return query_list(q, show_query=show_query)
  end

  rows = list(q)
  model_name = q.object.model.name
  filter_repr = isempty(q.object.filter) ? "(none)" : join(_get_filter_repr.(q.object.filter), ", ")

  isempty(rows) && throw(DoesNotExist(model_name, filter_repr))
  length(rows) > 1 && throw(MultipleObjectsReturned(model_name, length(rows), filter_repr))

  return rows[1]
end

function _row_update_pairs(updates::Dict{String,Any})
  return [field => updates[field] for field in sort(collect(keys(updates)))]
end

function _row_related_model(model::PormGModel, fk_meta::Models.sRelationalColumn)::PormGModel
  fk_meta.to isa PormGModel && return fk_meta.to

  model._module !== nothing || throw(QueryBuildError("Cannot resolve related model $(fk_meta.to) for $(model.name); model module is not initialized."))
  related = Base.invokelatest(getfield, model._module, Symbol(fk_meta.to))
  related isa PormGModel && return related
  throw(QueryBuildError("Related model $(fk_meta.to) for $(model.name) is not a PormG model."))
end

function _row_require_data_key(data::Dict{Symbol,Any}, key::Symbol, context::String)
  haskey(data, key) && return data[key]
  throw(QueryBuildError("Cannot save() $(context): row data does not include required key '$(key)'. Select it before mutating and saving the row."))
end

"""
    save(row::PormGRow; show_query=:execute) -> PormGRow | Vector

Persist dirty fields assigned on a `PormGRow`.

Direct fields update the row's own table. Projected fields like
`driverid__forename` update the related table identified by the `driverid`
foreign key value already present on the row.
"""
function save(row::PormGRow; show_query::Symbol = :execute)
  dirty = getfield(row, :_dirty)
  isempty(dirty) && return row

  data = getfield(row, :_data)
  model = getfield(row, :_model)

  pk_sym = try
    Models.get_model_pk_field(model)
  catch e
    # `get_model_pk_field` throws `ModelDefinitionError` on a composite pk (#239 migrated the
    # Models error contract; it was `ArgumentError` under #231). The re-thrown save() error below
    # stays a QueryBuildError — the caller's mistake is the save(), not the model definition.
    e isa ModelDefinitionError || rethrow(e)
    throw(QueryBuildError("save() requires exactly one primary key field; $(model.name) is not supported."))
  end
  pk_sym === nothing && throw(QueryBuildError("save() requires exactly one primary key field; $(model.name) is not supported."))

  own_updates = Dict{String,Any}()
  fk_updates = Dict{Symbol,Dict{String,Any}}()
  touched_fk_fields = Set{Symbol}()

  for dirty_sym in dirty
    normalized = _normalize_row_symbol(dirty_sym)
    normalized_string = String(normalized)
    separator = findfirst("__", normalized_string)

    if separator === nothing
      own_updates[normalized_string] = data[normalized]
      if haskey(model.fields, normalized_string) && model.fields[normalized_string] isa Models.sRelationalColumn
        push!(touched_fk_fields, normalized)
      end
    else
      fk_sym = Symbol(normalized_string[1:first(separator)-1])
      column = normalized_string[last(separator)+1:end]
      fk_bucket = get!(fk_updates, fk_sym, Dict{String,Any}())
      fk_bucket[column] = data[normalized]
    end
  end

  conflict = intersect(touched_fk_fields, Set(keys(fk_updates)))
  isempty(conflict) || throw(QueryBuildError(
    "Cannot save() a row after mutating both FK field(s) $(collect(conflict)) and projected '__' fields under the same prefix. Save the FK change separately first."
  ))

  settings, _, _ = get_settings(object(model))

  function planned_updates(show_mode::Symbol)
    inspections = Any[]

    if !isempty(own_updates)
      pk_value = _row_require_data_key(data, pk_sym, "own-table updates for $(model.name)")
      own_pairs = _row_update_pairs(own_updates)
      push!(inspections, object(model).filter(String(pk_sym) => pk_value).update(own_pairs...; show_query=show_mode))
    end

    for fk_sym in sort(collect(keys(fk_updates)); by=String)
      fk_meta = model.fields[String(fk_sym)]::Models.sRelationalColumn
      if fk_meta.pk_field === nothing
        throw(QueryBuildError(
          "save() cannot update projected fields under '$(fk_sym)' because the FK's " *
          "target primary key has not been resolved. Call set_models() to initialize " *
          "the model before using save() with projected FK fields."
        ))
      end
      fk_value = _row_require_data_key(data, fk_sym, "projected updates under '$(fk_sym)' for $(model.name)")
      related_model = _row_related_model(model, fk_meta)
      fk_pairs = _row_update_pairs(fk_updates[fk_sym])
      related_query = object(related_model)
      related_query.filter(String(fk_meta.pk_field) => fk_value)
      push!(inspections, related_query.update(fk_pairs...; show_query=show_mode))
    end

    return inspections
  end

  if show_query !== :execute
    return planned_updates(show_query)
  end

  run_in_transaction(settings) do
    planned_updates(:execute)
  end

  empty!(dirty)
  return row
end

"""
    delete(row::PormGRow; show_query=:execute) -> (total::Int, Dict{String,Integer})

Delete this fetched row from its table, cascading through the **same** `DeletionCollector` as
`Model.objects.filter(...).delete()` — so `on_delete` behaviour (CASCADE / SET_NULL / PROTECT)
is identical whether you delete one fetched row or a filtered set. Returns the
`(total_deleted, per-model counts)` tuple of the underlying queryset delete.

The row is located by its primary key, which must have been projected onto the row (it is, for
rows from `list()`/`first()`/`get()`). The in-memory `row` is not mutated — its data becomes
stale after the delete.
"""
function delete(row::PormGRow; show_query::Symbol = :execute)
  model = getfield(row, :_model)
  pk_sym = try
    Models.get_model_pk_field(model)
  catch e
    # get_model_pk_field throws ModelDefinitionError on a composite pk (#239; mirrors save()/pk()).
    e isa ModelDefinitionError || rethrow(e)
    throw(QueryBuildError("delete() requires exactly one primary key field; $(model.name) is not supported."))
  end
  pk_sym === nothing &&
    throw(QueryBuildError("delete() requires exactly one primary key field; $(model.name) is not supported."))

  data = getfield(row, :_data)
  haskey(data, pk_sym) ||
    throw(QueryBuildError("Cannot delete() this $(model.name) row: its primary-key column '$(pk_sym)' was not projected. Select it before deleting the row."))

  # Route the single pk through the queryset delete — one collector/cascade path, no drift (#208).
  return object(model).filter(String(pk_sym) => data[pk_sym]).delete(show_query=show_query)
end
