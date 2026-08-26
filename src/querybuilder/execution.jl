
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
        :having => parameters.having_params
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
  - `:operation` (Symbol): The query operation type (`:select`, `:insert`, `:update`, `:delete`)
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
  if any(rj -> get(rj, "cross", nothing) !== nothing, instruction.row_join)
    predicate_text = string(
      isempty(instruction._where) ? "" : join(instruction._where, " AND "),
      isempty(instruction.having) ? "" : join(instruction.having, " AND "),
    )
    for rj in instruction.row_join
      get(rj, "cross", nothing) === nothing && continue
      cte_alias = rj["alias_b"]::String
      if !occursin("\"$(cte_alias)\"", predicate_text)
        @warn _emsg("PormG: CTE \e[31m$(rj["b"])\e[0m is CROSS JOINed with no correlating filter — this is a Cartesian product. Add a correlation such as \e[32mfilter(\"main_col\" => F(\"$(rj["b"])__col\"))\e[0m, or pass \e[32mjoin_field=\e[0m to .with().")
      end
    end
  end

  # Store the final parameters object with all CTEs + main query parameters
  q.object.parameters = instruction.parameters

  if show_query !== :execute
    return _show_query_result(show_query, resposta, instruction.connection, q.object.model.name, :select;
                            parameters=instruction.parameters)
  end
  # #26: a locked read executed OUTSIDE a transaction on PostgreSQL is a footgun — the lock is
  # taken then immediately released at autocommit. Fail loudly (Django's TransactionManagementError
  # analog). Guarded on the execute path only, so inspect_query/show_query still render FOR UPDATE
  # without a live transaction. SQLite never locks (clause rendered ""), so it is exempt.
  if q.object.for_update !== nothing && instruction.connection isa PormGPostgres && !in_transaction_context()
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
    _values!(cq.object, Any["__pormg_count" => Count(String(column); distinct = distinct)])
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

# Build a Dict{Symbol,Any} from a result row, mapping physical column names back to the
# declared field names so callers always see field-name keys even when a field maps to a
# differently-named column via db_column (#50). No-op shape on the common path.
function _row_to_field_keyed_dict(row, model::PormGModel)::Dict{Symbol,Any}
  if !Models.model_has_db_column(model)
    return Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row))
  end
  rev = Dict{String,Symbol}(Models.field_db_column(f, string(k)) => Symbol(k) for (k, f) in model.fields)
  return Dict{Symbol,Any}(get(rev, string(k), Symbol(k)) => v for (k, v) in pairs(row))
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
      reserved_max = get_sqlite_reserved_primary_key_max(model, pk_name)
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

    # Format and add value to parameters
    push!(param_values, add_parameter!(parameters, real_obj.insert[field] |> model.fields[field].formatter))

  end

  return quoted_field_columns, param_values, pk_exist, pk_field
end

function insert(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, show_query::Symbol = :execute)
real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
  
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
    return PormGRow(_row_to_field_keyed_dict(Tables.rowtable(result) |> Base.first, model), model)
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
    # AUTOINCREMENT pk. The wrapped PormGRow is still returned; if that degenerate row is later
    # mutated and .save()d, save() throws a clear "required key" error — no regression over the
    # previous incomplete-Dict return.
    do_insert = () -> begin
      fetch(settings, sql, parameters)
      rows = fetch(settings,
        "SELECT * FROM $(safe_table_name) WHERE rowid = last_insert_rowid();") |> Tables.rowtable
      isempty(rows) ?
        Dict{Symbol, Any}(Symbol(k) => v for (k, v) in pairs(real_obj.insert)) :
        _row_to_field_keyed_dict(rows[1], model)
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
  ensure_model_transaction_scope(model)

  settings, connection, conn_key = get_settings(objct)

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
    dict = _row_to_field_keyed_dict(Tables.rowtable(result) |> Base.first, model)
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
        _row_to_field_keyed_dict(rows[1], model)
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
  ensure_model_transaction_scope(model)

  settings, connection, conn_key = get_settings(objct)
  !settings.change_data && throw(_write_not_allowed("get_or_create", conn_key))

  # Capture the raw lookup values BEFORE any INSERT marshalling mutates real_obj.insert.
  target_values = Dict{String,Any}(f => real_obj.insert[f] for f in target_fields)

  # get() by the conflict target through the fluent builder — dialect-correct binding for free, and
  # inside a transaction it uses the pinned connection (same pattern as save()).
  fetch_by_target = () -> begin
    q = object(model)
    for f in target_fields
      q.filter(f => target_values[f])
    end
    q.first()
  end

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
        dict = _row_to_field_keyed_dict(Base.first(rows), model)
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

function _update_sequence(model::PormGModel, connection::PormGSQLite, pk_field::Vector{String}, settings::PormGSettings)
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
        if parsed_id !== nothing
          # sqlite_sequence.name has no UNIQUE constraint, so `INSERT OR REPLACE` appends a
          # duplicate row instead of overwriting. Upsert by hand: UPDATE the existing row
          # (collapsing any duplicates a prior buggy run left, all to the same value), then
          # INSERT only if no row exists yet.
          fetch(settings, "UPDATE sqlite_sequence SET seq = $(parsed_id) WHERE name = '$(safe_table_literal)';")
          fetch(settings, "INSERT INTO sqlite_sequence (name, seq) SELECT '$(safe_table_literal)', $(parsed_id) " *
                          "WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = '$(safe_table_literal)');")
        end
      end
    end
  end
end

# TODO: Implement a function to handle the update with multiple dispatch
# Helper function to check if a field is a date field
function _is_date_field(field_name::String, instruc::SQLInstruction)
  model = instruc.object.model
  # @pormg_debug
  if haskey(model.fields, field_name)
    field_type = model.fields[field_name].type
    return field_type in ["DATE", "TIMESTAMPTZ", "TIMESTAMP"]
  elseif haskey(instruc.tab_field_cache, field_name)
    field_type = instruc.tab_field_cache[field_name].type
    return field_type in ["DATE", "TIMESTAMPTZ", "TIMESTAMP"]
  end 
  return false
end

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
  elseif haskey(instruc.tab_field_cache, field_name)
    t = instruc.tab_field_cache[field_name].type
    return t in ("DATE", "TIMESTAMPTZ", "TIMESTAMP") ? t : nothing
  end
  return nothing
end

# Whether a plain field reference resolves at all (so soft validation only fires when a field is
# known to be a non-date column, never when its type is simply unknown — best-effort, fail-open).
function _field_type_known(field_name::String, instruc::SQLInstruction)::Bool
  return haskey(instruc.object.model.fields, field_name) || haskey(instruc.tab_field_cache, field_name)
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

# Render `F(date) ± <duration>` per dialect. PostgreSQL emits a single `make_interval(...)` with
# explicitly-typed placeholders; SQLite emits one `date()`/`datetime()` modifier per component.
function _render_date_period_arithmetic(v::FExpression, instruc::SQLInstruction)
  period = v.operand isa Interval ? v.operand.period : v.operand
  comps  = _decompose_period(period)

  # Resolve the left side FIRST — rendering it populates `instruc.tab_field_cache` for dotted join
  # keys, which the SQLite wrapper choice (date vs datetime) below depends on.
  left_side = _set_update_query_left(v.field_name, v.operation, instruc)

  # Soft validation (#25, best-effort): a duration only makes sense on a date/time column. Only
  # throw when the field is known AND known to be non-date; stay silent for unresolved/nested lefts.
  if v.field_name isa String && _field_type_known(v.field_name, instruc) &&
     _date_field_type(v.field_name, instruc) === nothing
    throw(InvalidValueError("F(\"$(v.field_name)\") ± a duration requires a DATE/TIMESTAMP field; \"$(v.field_name)\" is not a date/time column"))
  end

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
    return "($(left_side) $(v.operation) make_interval($(join(parts, ", "))))"

  elseif instruc.connection isa PormGSQLite
    ftype   = v.field_name isa String ? _date_field_type(v.field_name, instruc) : nothing
    subday  = any(c -> c[1] in (:hour, :minute, :second), comps)
    # Choose datetime() when a sub-day unit is present, the column is a timestamp, OR the left side
    # is ALREADY a datetime() expression (a chained `F(ts) + Day(1) + Day(2)`: the outer call sees a
    # nested FExpression as field_name so `ftype` is unknown — without this, wrapping the inner
    # datetime() in date() would silently truncate the time-of-day, diverging from PostgreSQL).
    use_datetime = subday || ftype in ("TIMESTAMP", "TIMESTAMPTZ") || occursin("datetime(", left_side)
    wrapper = use_datetime ? "datetime" : "date"
    op_factor = v.operation == "-" ? -1 : 1
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
    # column is not truncated by a stray date() on a no-op interval).
    isempty(mods) && return left_side
    return "$wrapper($(left_side), $(join(mods, ", ")))"
  else
    throw(_unsupported_conn("date/interval arithmetic", instruc.connection))
  end
end

function _set_update_query_operand(operand::Any, field_name::Any, operation::String, instruc::SQLInstruction)
  if isa(operand, FExpression)
    return _set_update_query(operand, instruc)
  elseif isa(operand, SQLTypeFunction)
    return _get_select_query(operand, instruc)
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
    # SECURITY: Handle integer operands for date arithmetic and bitwise shifts
    sql_type = (operation in ["<<", ">>"]) ? "integer" : _infer_parameter_sql_type(operand, instruc)
    placeholder = add_parameter!(instruc, operand; sql_type=sql_type)
    if operation in ["+", "-"] && (field_name isa String && _is_date_field(field_name, instruc))
      if instruc.connection isa PormGSQLite
        # SQLite handles date arithmetic via functions, but for the infix expression
        # we just return the placeholder and handle the wrapper in the final return
        return placeholder
      else
        # Convert integer days to interval for date arithmetic (PostgreSQL)
        return "($placeholder || ' days')::interval"
      end
    else
      return placeholder
    end
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

function _set_update_query(v::FExpression, instruc::SQLInstruction)
  if v.operation === nothing
    # Resolve the field using existing logic for joins and modifiers
    if v.field_name isa String
      return _get_filter_query(v.field_name, instruc)
    elseif v.field_name isa Integer
      return add_parameter!(instruc, v.field_name; sql_type=_infer_parameter_sql_type(v.field_name, instruc))
    else
      # Recursive call for nested expressions
      return _set_update_query(v.field_name, instruc)
    end
  elseif v.operation == "~"
    # Unary NOT operator
    left_side = _set_update_query_left(v.field_name, v.operation, instruc)
    return "~($(left_side))"
  elseif v.operation == "xor"
    if instruc.connection isa PormGPostgres
      left_side = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)
      return "($(left_side) # $(right_side))"
    elseif instruc.connection isa PormGSQLite
      # Positional Parameter Alignment: render each side twice to duplicate any embedded parameters
      left_side1 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side1 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      left_side2 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side2 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      return "((($(left_side1)) | ($(right_side1))) - (($(left_side2)) & ($(right_side2))))"
    else
      throw(_unsupported_conn("xor update expression", instruc.connection))
    end
  elseif v.operation in ("+", "-") && v.operand isa Union{Dates.Period, Dates.CompoundPeriod, Interval}
    # Date arithmetic with an explicit Julia duration type (#25). Handled ahead of the generic
    # infix branch: a Period operand must NOT reach `_set_update_query_operand`, which would try to
    # bind it as a raw SQL parameter.
    return _render_date_period_arithmetic(v, instruc)
  else
    # Field with operation - handle nesting and date arithmetic properly
    left_side = _set_update_query_left(v.field_name, v.operation, instruc)

    # @pormg_debug
    right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)
    
    if instruc.connection isa PormGSQLite && v.operation in ["+", "-"] && (v.field_name isa String && _is_date_field(v.field_name, instruc))
      op_sign = v.operation == "+" ? "+" : "-"
      return "date($(left_side), '$(op_sign)' || $(right_side) || ' days')"
    end

    return "($(left_side) $(v.operation) $(right_side))"
  end
end

function _build_from_tables(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection::Union{PormGPostgres, PormGSQLite})
  tables = String[]
  for join_dict in row_join
    # #394: no try/catch. This used to `@error` and CONTINUE, which dropped a table from a correlated
    # FROM list and left the surviving aliases unconstrained — a wrong query emitted as a warning.
    # Everything that can raise here is a defect, not a tolerable condition: a `KeyError` means the
    # row_join is malformed, and an `InvalidValueError` means an INTERNALLY generated alias is not an
    # identifier. Both have to surface.
    b = safe_table_identifier(join_dict["b"], connection)
    alias_b = quote_identifier(join_dict["alias_b"], connection)
    push!(tables, "$b AS $alias_b")
  end
  return join(unique(tables), ", ")
end

function _get_join_condition_list(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection)
  # #45: this correlated UPDATE-FROM / DELETE-USING path only builds equi-anchors and ignores
  # on_conditions, so an anchor-less cjoin_on join would be emitted WITHOUT its ON (silently wrong).
  # The common update/delete path scopes rows via a subquery that DOES render cjoin_on correctly;
  # only this correlated path is unsupported — fail loudly rather than drop the join condition.
  for join_dict in row_join
    if get(join_dict, "no_anchor", "") == "1"
      throw(QueryBuildError("cjoin_on is not supported in a correlated UPDATE-FROM/DELETE-USING (setting a " *
                    "column from a joined table); scope the mutation with a filter/subquery instead."))
    end
    # #394: the same rule, for a CTE. `update()` emits no `WITH` prefix — `build_cte_clause` is
    # reached only from the three READ paths — so a row_join entry naming a CTE renders
    # `FROM "<cte>" AS "Tb_N"` against a relation this statement never declares. That is as true of a
    # KEYED CTE as of a CROSS-joined one, which is why the check is on the entry being a CTE rather
    # than on the shape of its keys. The cross-joined case additionally carries SENTINEL empty key
    # columns; those used to raise inside the loop below and be swallowed by a `catch` that dropped
    # the ON condition entirely. Both fail here now, before any SQL is built.
    if get(join_dict, "cte", nothing) !== nothing || get(join_dict, "cross", nothing) !== nothing
      throw(QueryBuildError("A CTE cannot be joined in a correlated UPDATE ... FROM: the statement emits " *
                    "no WITH clause, so the CTE it references is never declared. Scope the mutation with " *
                    "a filter or a subquery instead."))
    end
  end
  conditions = String[]
  for join_dict in row_join
    # #394: no try/catch either — the guards above refuse to drop an ON clause, and until now the
    # loop below dropped one anyway on any failure, with nothing but an `@error`. An UPDATE ... FROM
    # or DELETE ... USING missing its ON condition matches every row of the joined table, so this is
    # the one place a swallowed identifier error corrupts data rather than returning wrong rows.
    # Everything reaching here is well-formed: both anchor-less shapes are refused above, and every
    # `row_join` producer writes the alias/key set together with a PormG-generated `alias_b`.
    alias_a = quote_identifier(join_dict["alias_a"], connection)
    key_a = safe_column_identifier(join_dict["key_a"], connection)
    alias_b = quote_identifier(join_dict["alias_b"], connection)
    key_b = safe_column_identifier(join_dict["key_b"], connection)
    push!(conditions, "$alias_a.$key_a = $alias_b.$key_b")
  end
  return conditions
end

function _build_join_conditions(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, connection::Union{PormGPostgres, PormGSQLite})
  return _get_join_condition_list(row_join, connection)
end

function _set_clause_uses_join_aliases(set_clause::String,
  row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}},
  connection::Union{PormGPostgres, PormGSQLite})::Bool
  for join_dict in row_join
    alias_b = quote_identifier(join_dict["alias_b"], connection)
    occursin("$alias_b.", set_clause) && return true
  end
  return false
end

function _build_update_target_pk_subquery(instruction::SQLInstruction)::Union{String, Nothing}
  pk_field_sym = get_model_pk_field(instruction.object.model)
  pk_field_sym === nothing && return nothing

  safe_table_name = safe_table_identifier(Models.model_table_name(instruction.object.model), instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  quoted_pk = safe_column_identifier(Models.model_column(instruction.object.model, String(pk_field_sym)), instruction.connection)  # db_column (#50)

  io = IOBuffer()
  print(io, "SELECT DISTINCT ", safe_alias, ".", quoted_pk)
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

  return String(take!(io))
end

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model
  ensure_model_transaction_scope(model)

  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)

  # Check if is allowed to update
  !settings.change_data && throw(_write_not_allowed("update", conn_key))

  # Guard: limit(), offset(), and order_by() cannot be combined with update().
  # Standard SQL UPDATE does not support these clauses. Silently dropping them
  # risks updating far more rows than the user intended (e.g., query.limit(5).update(...)
  # would mutate ALL matching rows, not just 5). To update a bounded set of rows,
  # filter by primary key explicitly or compose a subquery.
  if real_obj.limit > 0 || real_obj.offset > 0 || !isempty(real_obj.order)
    throw(UnsafeMutationError(
      "Cannot call update() on a query that has limit(), offset(), or order_by() set. " *
      "Standard SQL UPDATE does not support these clauses, and silently dropping them " *
      "risks updating more rows than intended. " *
      "Filter by primary key explicitly or compose a subquery to update a bounded set."
    ))
  end

  if real_obj.distinct
    throw(UnsafeMutationError(
      "Cannot call update() on a query with distinct(). " *
      "DISTINCT collapses the result set, which would cause UPDATE to target " *
      "different rows than intended. Remove distinct() or filter by primary key."
    ))
  end

  if any(v -> isa(v, SQLTypeField) && isa(v.field, Union{SQLTypeFunction, SQLTypeF}) && v.field.aggregate, real_obj.values)
    throw(UnsafeMutationError(
      "Cannot call update() on a query with group_by() / annotate aggregations. " *
      "GROUP BY collapses rows, making the UPDATE target ambiguous. " *
      "Remove the aggregation or filter by primary key."
    ))
  end

  instruction = build(real_obj, table_alias=table_alias, connection=connection) 

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

    if isa(objct.insert[field], SQLTypeF) || isa(objct.insert[field], SQLTypeFunction)
      f_value = _set_update_query(objct.insert[field], instruction)
      push!(set_clause_parts, "$(quoted_field) = $(f_value)")
    else
      formatted_value = objct.insert[field] |> model.fields[field].formatter
      placeholder = add_parameter!(parameters, formatted_value)
      push!(set_clause_parts, "$(quoted_field) = $(placeholder)")
    end
  end
   
  set_clause = join(set_clause_parts, ", ")   

  # Build secure UPDATE SQL with JOIN support
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  safe_alias = quote_identifier(instruction.alias, connection)
  pk_field_sym = get_model_pk_field(model)
  
  has_joins = !isempty(instruction.row_join)
  sql = ""
  
  if has_joins
    if connection isa PormGPostgres || connection isa PormGSQLite
      # The SET-clause loop above can reach _build_row_join (e.g. update("x" => F("fk__col"))), so
      # row_join may have grown AFTER build() rendered instruction.join — the same late-discovery
      # hazard #404 fixed in build(). Exactly one UPDATE branch reads the stale instruction.join:
      # _build_update_target_pk_subquery, which prints it at :1492. This check is what excludes it —
      # a SET-discovered join necessarily puts its alias in set_clause, so the check returns true,
      # pk_subquery stays nothing, and the UPDATE … FROM branch below rebuilds FROM/ON from
      # instruction.row_join instead. Do NOT drop this guard on the theory that the UPDATE path
      # ignores instruction.join — it does not. (#404's own trigger cannot reach here regardless:
      # update() refuses a query carrying order_by() at :1542.)
      set_uses_join_aliases = _set_clause_uses_join_aliases(set_clause, instruction.row_join, connection)
      pk_subquery = (!set_uses_join_aliases && isempty(real_obj.ctes)) ? _build_update_target_pk_subquery(instruction) : nothing

      if pk_subquery !== nothing && pk_field_sym !== nothing
        quoted_pk = safe_column_identifier(Models.model_column(model, String(pk_field_sym)), connection)  # db_column (#50)
        sql = """
        UPDATE $(safe_table_name) AS $(safe_alias)
        SET $(set_clause)
        WHERE $(safe_alias).$(quoted_pk) IN (
        $(pk_subquery)
        )
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
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  # #43: build on a copy so the read path never mutates the caller's handler.
  # query() writes back q.object.parameters and materializes the per-build CTE
  # "model" into q.object.ctes; doing that on `objct` would give .list()/.first()
  # a hidden write side effect and make .copy() aliasing corrupt re-execution.
  # deepcopy(SQLObjectQuery) now clones CTE state independently (see _copy_ctes),
  # so the copy is fully isolated. Mirrors _count/_exists/get, which already copy.
  q = deepcopy(objct)
  sql = query(q, connection=connection, show_query=show_query)
  if show_query !== :execute
     return sql
  end
  return fetch(settings, sql, q.object.parameters)
end

"""
Creates a DataFrame directly from a SQLObjectHandler query.

This extends the DataFrame constructor to work directly with PormG query objects,

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
  return query_list(objct) |> DataFrames.DataFrame
end


"""
    _sqlite_datetime_aliases(objct::SQLObjectHandler) → Set{Symbol}

Return the set of result-row column keys that map to a `DateTimeField` on the primary
model.  Only direct (non-joined) field projections are resolved; joined columns
(containing `__`) are skipped so no cross-model traversal is needed.

Used on the SQLite backend to normalise string datetime values in `list()` results into
proper Julia temporal types, giving the same contract as the PostgreSQL backend.
"""
function _sqlite_datetime_aliases(objct::SQLObjectHandler)::Set{Symbol}
    model = objct.object.model
    col_set = Set{Symbol}()

    if isempty(objct.object.values)
        # No .values() projection — all direct model fields appear in the result
        for (fname, fmeta) in model.fields
            fmeta isa Models.sDateTimeField && push!(col_set, Symbol(fname))
        end
    else
        for v in objct.object.values
            v isa SQLTypeField || continue
            # The effective alias is how the column appears in the result dict
            effective_alias = v.custom_as !== nothing ? v.custom_as : (v._as !== nothing ? v._as : (v.field isa String ? v.field : nothing))
            effective_alias === nothing && continue
            # The field reference must be a plain string to look up in model.fields.
            # Expressions or function objects are skipped.
            field_ref = v.field isa String ? v.field : nothing
            field_ref === nothing && continue
            # Skip joined columns — their source model is not tracked here
            occursin("__", field_ref) && continue
            if haskey(model.fields, field_ref) && model.fields[field_ref] isa Models.sDateTimeField
                push!(col_set, Symbol(effective_alias))
            end
        end
    end
    return col_set
end

"""
    _parse_sqlite_datetime(v) → Union{ZonedDateTime, DateTime, typeof(v)}

Parse a raw string value read from a SQLite DATETIME column into a Julia temporal type.

SQLite stores datetime values as TEXT.  PormG serialises `DateTimeField` values (including
`auto_now` / `auto_now_add`) as canonical UTC ISO-8601 strings, e.g. `"2026-04-07T21:30:23.741+00:00"`
(issue #79). This function converts those strings back into proper Julia types so that the SQLite backend
returns the same high-level types as the PostgreSQL backend (which returns `ZonedDateTime`
natively via LibPQ).

- Strings containing a timezone offset → `ZonedDateTime`
- Naive ISO 8601 strings → `DateTime`
- Non-string values or unparseable strings → returned unchanged
"""
function _parse_sqlite_datetime(v::Any)
    v isa AbstractString || return v
    normalized = Models.normalize_sqlite_datetime_string(v)
    # Try timezone-aware form first (e.g. "2026-04-07T18:30:23.741-03:00")
    try; return ZonedDateTime(normalized, dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzz"); catch; end
    # Fall back to naive datetime (e.g. "2026-04-07T21:30:23")
    try; return DateTime(v[1:min(19, length(v))], dateformat"yyyy-mm-ddTHH:MM:SS"); catch; end
    return v
end
function _list_raw(objct::SQLObjectHandler)
  result = query_list(objct)
  rows = Tables.rowtable(result) |> collect |> x -> [Dict(Symbol(k) => v for (k, v) in pairs(row)) for row in x]
  # SQLite returns DATETIME columns as raw strings. Normalise columns that correspond to a
  # DateTimeField in the primary model into ZonedDateTime / DateTime so the return type
  # matches what the PostgreSQL backend produces natively.
  _, connection, _ = get_settings(objct)
  if connection isa PormGSQLite
    dt_cols = _sqlite_datetime_aliases(objct)
    if !isempty(dt_cols)
      rows = [Dict(k => (k in dt_cols && v isa AbstractString ? _parse_sqlite_datetime(v) : v)
                   for (k, v) in row) for row in rows]
    end
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

"""Return a JSON string without allocating `PormGRow` wrappers."""
function list(objct::SQLObjectHandler, ::Val{:json}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  return JSON.json([Dict(String(k) => v for (k, v) in row) for row in _list_raw(objct)])
end

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

# Reverse a single ORDER BY term in place — the reverse of an ORDER BY yields the last row (#208).
# Flip ASC↔DESC, and any EXPLICIT nulls placement (an unset `nothing` stays default so the
# renderer keeps its orientation-derived NULLS placement). Non-SQLOrder ordering terms are left
# as-is (best effort).
function _invert_order!(o::SQLOrder)
  o.orientation = o.orientation == "DESC" ? "ASC" : "DESC"
  # if/elseif, NOT two `&&` statements: sequential flips would swap :first→:last→:first (no-op).
  if o.nulls === :first
    o.nulls = :last
  elseif o.nulls === :last
    o.nulls = :first
  end
  return o
end
_invert_order!(o) = o

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
    for o in q.object.order
      _invert_order!(o)
    end
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
