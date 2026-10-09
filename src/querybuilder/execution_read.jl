# Executing a read (#130): `query` and the statement it prints, `count` / `exists` / `aggregate`,
# `inspect_query`, and the row-returning terminals — `list`, `query_list`, `DataFrame`, `first` /
# `last` / `earliest` / `latest` and `get`. Writes are in `execution_write.jl`, bulk writes in
# `execution_bulk.jl`, and rendering an `F(...)` expression in `expression_render.jl`.

function _show_query_result(mode::Symbol, sql::String, connection::Union{Nothing, PormGPostgres, PormGSQLite}, model::Union{PormGModel, String}, operation::Symbol;
                          parameters::Union{Nothing, AbstractPormGParam} = nothing)
  
  if mode === :none
    return nothing # Zero-allocation mode for benchmarking the builder
  elseif mode === :sql
    return sql # Simplicity: just the SQL string (fast benchmarking)
  elseif mode === :pretty
    return _format_sql(sql) # #48: one clause per line, for logs and the REPL; whitespace only
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
      # Every slot `_BUCKET_ORDER` names, so a bucket added there is reported here without a second
      # list. This was a hand-written copy, and #46's `:limit` would have been missing from it.
      for ctx in _BUCKET_ORDER
        bucket_breakdown[ctx] = _bucket_for(parameters, ctx)
      end
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
    throw(QueryBuildError("Invalid show_query mode: $mode. Must be one of: :sql, :pretty, :dict, :inspection, :params, :none"))
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

# #46: the LIMIT / OFFSET tail of a SELECT, bound like every other user value. Both bind under
# `:limit`, the last bucket in `_BUCKET_ORDER`, because their text is the last that carries a marker —
# and in a nested render (a `Subquery`, an `__@in` list, a CTE body) the caller lifts the run out in
# that same clause order, so an inner LIMIT lands inside its parent's run, not at the statement's
# tail. A `nothing` limit is "no LIMIT" and binds nothing; `0` binds, and is zero rows — SQL's and
# Django's meaning (#1049; it used to be the no-limit sentinel and returned every row). An offset of
# `0` binds nothing because OFFSET 0 is a no-op anyway.
function _limit_offset_sql(limit::Union{Nothing,Integer}, offset::Integer, parameters::AbstractPormGParam,
                           connection::Union{PormGPostgres,PormGSQLite})::String
  (limit === nothing && offset == 0) && return ""
  return with_bucket(parameters, :limit) do
    limit_sql = limit === nothing ? nothing : add_parameter!(parameters, limit)
    offset_sql = offset == 0 ? nothing : add_parameter!(parameters, offset)
    Dialect.limit_offset_clause(limit_sql, offset_sql, connection)
  end
end

# #169: `select_for_update(of = …)` targets → the QUOTED FROM-clause aliases `FOR UPDATE OF` names.
#
# Runs after `build()`, because only then does every join the targets may name exist, and on BOTH
# engines — SQLite renders no lock, but a target that cannot resolve is a bug in the caller's code,
# and the development engine is where it should surface. A name is only ever a lookup key: what is
# rendered is the alias the build generated (or a `cjoin_on` alias `_validate_identifier` accepted at
# declaration), so no caller text reaches the SQL.
#
# Three kinds of target, each in its own namespace — `"self"`, a relation path, a `cjoin_on` alias.
# A name in more than one is refused rather than ranked (#492): the alias namespace exists precisely
# because an alias may be spelled like a relation (#484), and guessing which was meant would lock
# the wrong table silently. A relation the query never joins is refused too, not joined on the spot:
# a reverse relation joined only to be locked would multiply the rows the read returns.
function _lock_target_aliases(instruction::SQLInstruction, names::Vector{String})::Vector{String}
  obj = instruction.object
  by_path = something(instruction.join_alias_by_path, Dict{String,String}())
  _refuse_lock_targets_beside_right_joins(instruction)
  aliases = String[]
  for name in names
    segments = split(name, "__")
    canonical = _canonical_join_path(obj, name)
    # Every segment must be a relation: `driverid__surname` canonicalizes to `driverid`, which would
    # otherwise lock the driver while the caller named a column.
    is_path = !isempty(canonical) && length(split(canonical, "__")) == length(segments)
    is_alias = haskey(obj.alias_join, name)
    is_self = name == "self"
    if count((is_self, is_path, is_alias)) > 1
      meanings = String[]
      is_self && push!(meanings, "the base model's own target")
      is_path && push!(meanings, "a relation path on $(obj.model.name)")
      is_alias && push!(meanings, "a cjoin_on alias")
      # The only remedy PormG can offer is renaming the alias; a model relation literally named
      # "self" has no spelling in `of` at all, and saying so beats advice that does not apply.
      remedy = is_alias ? "Rename the cjoin_on alias." :
        "A relation named \"self\" cannot be told apart from the base model in `of`."
      throw(AmbiguousFieldError(
        "select_for_update(of = …): \"$(name)\" is ambiguous — it names $(join(meanings, " and ")), " *
        "so PormG will not choose which table to lock. $(remedy)"))
    end
    alias = if is_self
      instruction.alias
    elseif is_alias
      name
    elseif is_path && haskey(by_path, canonical)
      by_path[canonical]
    else
      # Only what would be accepted: a LEFT-joined path or alias would be refused the moment the
      # caller took the suggestion.
      lockable(a) = (i = findfirst(r -> r.alias_b == a, instruction.row_join);
                     i === nothing || !hasproperty(instruction.row_join[i], :how) ||
                     uppercase(instruction.row_join[i].how) != "LEFT")
      choices = vcat(["self"], sort!([p for (p, a) in by_path if lockable(a)]),
                     [a for a in keys(obj.alias_join) if lockable(a)])
      what = is_path ? "is a relation on $(obj.model.name) that this query does not join" :
                       "is not a relation path or cjoin_on alias of this query"
      throw(QueryBuildError(
        "select_for_update(of = …): \"$(name)\" $(what). A lock target must name a table the query " *
        "already reads. Choices: $(join(choices, ", "))."))
    end
    _refuse_nullable_lock_target(instruction, name, alias)
    alias in aliases || push!(aliases, alias)
  end
  return [quote_identifier(a, instruction.connection) for a in aliases]
end

# PostgreSQL refuses `FOR UPDATE OF` the nullable side of an outer join. A nullable foreign key and
# every hop after one render LEFT (`build_joins.jl`), so this is ordinary input, not an edge case —
# refused here, on both engines, so it fails during development on SQLite too.
function _refuse_nullable_lock_target(instruction::SQLInstruction, name::String, alias::String)
  i = findfirst(r -> r.alias_b == alias, instruction.row_join)
  i === nothing && return nothing   # the base relation, which no join row describes
  row = instruction.row_join[i]
  hasproperty(row, :how) || return nothing
  # FULL never reaches here: `_refuse_lock_targets_beside_right_joins` refused the statement first.
  uppercase(row.how) == "LEFT" || return nothing
  throw(QueryBuildError(
    "select_for_update(of = …): \"$(name)\" is joined $(uppercase(row.how)) — a nullable foreign " *
    "key, a hop after one, or an explicit join_type — and PostgreSQL cannot lock the nullable side " *
    "of an outer join. Leave it out of `of` — of = (\"self\",) locks the base rows alone — or lock " *
    "that table with a query of its own."))
end

# A RIGHT or FULL join puts what is joined BEFORE it on the nullable side — the base table included —
# which a per-row check cannot see: the target's own row may be INNER. Which tables that reaches
# depends on emission order, which `cjoin_on` dependencies and ON-clause relocation reorder after
# the rows are built, so `of` is refused for the whole statement rather than guessed at per target.
# That also refuses a target PostgreSQL would accept (the right side of a lone RIGHT join): the
# cost of not tracking the order, and a loud one.
function _refuse_lock_targets_beside_right_joins(instruction::SQLInstruction)
  for row in instruction.row_join
    hasproperty(row, :how) || continue
    how = uppercase(row.how)
    how in ("RIGHT", "FULL") || continue
    throw(QueryBuildError(
      "select_for_update(of = …) cannot be used on a query with a $(how) JOIN (to \"$(row.b)\"): it " *
      "puts the tables joined before it, the base table included, on the nullable side of an outer " *
      "join, which PostgreSQL cannot lock. Use INNER or LEFT joins, or lock the rows with a query " *
      "of their own."))
  end
  return nothing
end

function query(q::SQLObjectHandler; 
  table_alias::Union{Nothing, SQLTableAlias} = nothing,
  connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing,
  parameters::Union{Nothing, AbstractPormGParam} = nothing,
  cte::Union{Nothing, CTEDict} = nothing,
  outer::Union{Nothing, SQLInstruction} = nothing,
  show_query::Symbol = :execute,
  # #929: called with the inner build's instruction right after `build()`, while its memos still hold
  # what the render resolved — the one window in which a nested render can ask about its own
  # projection. `_render_scalar_subquery` reads the projected column's formatter through it.
  built::Union{Nothing,Function} = nothing
  )

  @pormg_debug false

  # Create a shared table alias counter for both CTEs and main query
  table_alias === nothing && (table_alias = SQLTbAlias())
  
  settings, connection, conn_key = get_settings(q, connection=connection)

  # Track if this is a subquery. A nested render passes the shared collector (PostgreSQL needs one
  # sequential `$N` counter); its build still files values under its OWN clauses, and `build()`
  # restores the ambient bucket on return (#936, #939), so the caller lifts them as one clause-ordered
  # run (#432, `detach_nested_run!`). That restore used to be a save/restore here, beside an
  # `own_contexts` opt-in; `with_bucket` made both structural.
  is_subquery = parameters !== nothing

  # IMPORTANT: Create the shared parameters object BEFORE building CTEs
  # This ensures all CTEs and the main query use sequential parameter numbering
  if parameters === nothing
    parameters = get_parameter(connection)
  end

  # Build WITH clause - passes the SAME parameters object
  # CTE context is set inside build_cte_clause
  !is_subquery && set_context!(parameters, :cte)
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)  

  @pormg_debug false

  # Main query uses the SAME parameters object (will continue numbering from where CTEs left off)
  # Context switching for select/where/join happens inside build()
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters, outer=outer)
  built === nothing || built(instruction)
  
  # Prevent SELECT * across JOINs which causes DataFrame column collisions downstream.
  # Only enforce during actual execution (:execute) — inspection/dry-run modes (:dict, :sql,
  # :inspection, etc.) must be allowed to build joined queries without .values() so that
  # inspect_query() and show_query=:dict work on un-projected joined queries.
  if isempty(q.object.values) && !isempty(instruction.join) && show_query === :execute
    throw(QueryBuildError("PormG: Joined queries must explicitly select fields using .values(...) to prevent duplicate column names. Tip: Use .values(\"*\", \"joined_model__field_name\") to select all main table fields alongside specific joined fields."))
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
  
  print(io, _limit_offset_sql(q.object.limit, q.object.offset, parameters, instruction.connection))

  # #26: row-level locking clause (FOR UPDATE …) must follow ORDER BY / LIMIT / OFFSET. No-op on
  # SQLite (Dialect.for_update_clause renders "" there). PostgreSQL rejects FOR UPDATE with
  # DISTINCT, so fail early with a friendly message rather than a raw DB error.
  let fu = q.object.for_update
    if fu !== nothing
      # PostgreSQL rejects FOR UPDATE + DISTINCT; fail early with a friendly message. SQLite is
      # exempt — there the lock renders "" (pure no-op), so DISTINCT does not raise (#26). An `of`
      # target that does not resolve raises on both engines (#169): that is a bug in the call, not
      # a lock the engine lacks.
      if q.object.distinct && instruction.connection isa PormGPostgres
        throw(QueryBuildError("select_for_update() cannot be combined with distinct() — a locking read must return concrete rows."))
      end
      of_aliases = isempty(fu.of) ? String[] : _lock_target_aliases(instruction, fu.of)
      print(io, Dialect.for_update_clause(fu.nowait, fu.skip_locked, fu.no_key, of_aliases, instruction.connection))
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
| `:pretty` | `String` — the same SQL reflowed one clause per line; only whitespace changes |
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

# #1053: the caller's slice, as the read terminals see it. A terminal runs on a copy, and before
# #1053 each one overwrote the copy's `limit` with its own probe size or cleared it, so
# `q.limit(0).exists()` answered `true` for the rows `q.limit(0).list()` does not return. The same
# predicate `update()`/`delete()` refuse a sliced handler on.
_is_sliced(object::SQLObject)::Bool = object.limit !== nothing || object.offset > 0

# The limit a terminal probing `k` rows applies on top of the caller's — Django's
# `set_limits(high=k)`: the smaller of the two, with the caller's offset left where it is.
_probe_limit(limit::Union{Nothing,Integer}, k::Integer)::Integer = limit === nothing ? k : min(limit, k)

# #1066: does the `values()` projection decide which rows `list()` returns? `count()`, `exists()` and
# `Exists(...)` clear the projection before they build, which is safe for a plain column list: it
# returns one row per matching row either way. Two projections change the row set, and clearing them
# made the terminal disagree with `list()`:
# - a DISTINCT one collapses duplicates of the projected columns, not of `*` (`count()` counted
#   `SELECT DISTINCT *`, and an offset `exists()` skipped rows `list()` collapses);
# - an aggregating one returns a row per group (`count()` counted the rows, and a HAVING filter on the
#   alias raised `UnknownFieldError` because the alias was gone).
# Asked before the build, from `_contains_agg` (the predicate `get_select_query` sets the aggregate
# flag from), because a kept projection binds its values under `:select` and must then be printed. `distinct` is
# the caller's choice: `exists()` without an offset gets the same answer from the non-distinct rows.
#
# #1082: except an aggregate with no GROUP BY and no HAVING (`values("t" => Count("id"))`). It is one
# row whatever matched — `COUNT` over no rows is 0, not zero rows — so keeping it made `Exists(sub)`
# always true. `Exists(sub)` clears such a projection (`clear_degenerate`), as Django's `Exists` clears
# the SELECT and keeps grouping and HAVING, so it asks whether any row matched. A HAVING (a filter on
# the alias) makes the row optional, so that projection is kept; `_refuse_degenerate_probe` catches a
# shape this cannot predict.
#
# #1100: the terminals do not clear it. Answering for the matched rows made `count()` return N where
# `list()` returns one row, and 1 once a true HAVING was added — two kinds of answer in one query
# family. They keep it, build it, and `_refuse_constant_terminal` refuses what builds as that one row,
# so `count() == length(list())` holds with no exception and `exists() == (count() > 0)` still does:
# both raise. Building first also makes a projection `list()` refuses (#798's mixed grouping) raise
# the same error from them.
#
# #1074: and a projection a filter names by alias is kept too, whatever it projects. The filter
# resolves the alias through the projection (`get_filter_query` → the projection memo), so clearing
# it raised `UnknownFieldError` for `values("pts1" => F("points") + 1).filter("pts1__@gt" => 2)`,
# which `list()` runs. Kept, each alias takes `list()`'s route: a row alias renders in WHERE, an
# aggregate one in HAVING, and a window one reaches #685's refusal. Re-rendering a row alias in WHERE
# without the projection (Django inlines it the same way) gives the same rows with leaner SQL, but
# alias resolution needs the memo entry only the printed SELECT creates. Keeping it was chosen for
# cost and safety, not on concept.
_projection_shapes_rows(object::SQLObject; distinct::Bool, clear_degenerate::Bool = true)::Bool =
  !isempty(object.values) && !(clear_degenerate && _degenerate_aggregate(object)) &&
  (distinct || _contains_agg(object.values) || _filters_name_alias(object))

# #1082: does any filter name a projection by its output name? Asked of the declaration, before the
# build, with the filter path's own two tests:
# - a plain key that names no model field (`_alias_filter_key`): an alias, or an unknown name. An alias
#   is the only way into HAVING — #537 refuses an aggregate written in a filter;
# - a model key that a projection also names without being that column (#703's
#   `_guard_field_alias_collision`): `values("points" => Sum("points")).filter("points__@gt" => 5)`.
#   That guard reads the projection list, so a cleared projection let the key silently mean the
#   column; kept, the build refuses it as `list()` does (review of #1082).
# `Exists(...)` in a filter is its own query.
function _filters_name_alias(object::SQLObject)::Bool
  instruc = _declaration_instruction(object)
  hit = false
  for f in object.filter
    f isa ExistsObject && continue
    _each_condition_leaf(f) do leaf
      hit && return nothing
      key = _plain_filter_key(leaf.column)
      if key !== nothing && !(key in object.model.field_names)
        hit = true
      elseif (mkey = _model_filter_key(leaf.column, instruc)) !== nothing
        hit = any(p -> _projection_output_name(p) == mkey && !_projects_column(p, mkey), object.values)
      end
      return nothing
    end
    hit && return true
  end
  return false
end

# An instruction over the declaration alone, for the pre-build questions above and below: `_resolved_agg`,
# `_model_filter_key` and `_projected_source` read only `object` (its values, filters and model). Nothing
# is built with it, so nothing binds.
_declaration_instruction(object::SQLObject) =
  InstructionObject(text = "", table_alias = SQLTbAlias(), alias = "Tb", object = object)

# #1082: is the projection an aggregate that the build will neither group nor filter with HAVING?
# Each entry's part in GROUP BY is `_group_role`'s answer, the one `get_select_query` builds from
# (#1099): degenerate when every entry is an aggregate or adds no term, and at least one aggregates.
# A window is not answered (its OVER terms can be grouped), nor any filter on an alias (a HAVING, or a
# literal's WHERE). Each unanswered shape keeps the projection, and `_refuse_degenerate_probe` refuses
# it if the build turns out ungrouped after all.
#
# `order_by()` terms are the one part still decided here, conservatively: `get_order_query` tells a
# projected term from one it groups by matching the RENDERED projection and the memo, which do not
# exist before the build. A term is taken as projected only when its name is an entry's output name,
# a literal's included; any other term keeps the projection. The drift guard in
# `test_fluent_parity_208.jl` compares this answer with the built instruction's.
function _degenerate_aggregate(object::SQLObject)::Bool
  isempty(object.values) && return false
  _filters_name_alias(object) && return false
  instruc = _declaration_instruction(object)
  names = String[]
  any_agg = false
  for v in object.values
    role = _group_role(v, instruc)
    role === :group && return false
    # A window's OVER terms can be grouped, and an aggregate can be a window too (`Rank(…) + Sum(…)`,
    # #756), so this is asked apart from the role.
    role !== :none && _resolved_window(v.field, instruc) && return false
    any_agg |= role === :aggregate
    name = v.custom_as !== nothing ? v.custom_as : v._as
    name === nothing || push!(names, String(name))
  end
  any_agg || return false
  return all(o -> o.field._as !== nothing && String(o.field._as) in names, object.order)
end

# A kept projection that built as an aggregate with no GROUP BY and no HAVING: exactly one row whatever
# matched, so any answer about its rows is a constant.
_builds_one_row(instruction::SQLInstruction, keep_values::Bool)::Bool =
  keep_values && instruction.aggregate && isempty(instruction.group) && isempty(instruction.having)

# #1082: the check behind `_degenerate_aggregate`, for `Exists(...)`, which clears the shape it
# predicts. One it could not predict that still builds as one row is refused rather than answered.
function _refuse_degenerate_probe(instruction::SQLInstruction, keep_values::Bool, terminal::AbstractString)
  _builds_one_row(instruction, keep_values) || return nothing
  throw(QueryBuildError(
    "$(terminal) cannot answer for this query: its values() projection aggregates with no GROUP BY " *
    "and no HAVING, so it is exactly one row whatever matched, and the answer would be a constant. " *
    "Drop the aggregate from values() to ask about the matched rows, or filter on its alias to keep " *
    "only the row that passes (#1082)."))
end

# #1100: `count()` and `exists()` keep that projection and refuse it, whether or not it was predicted:
# its only honest answer is the constant `list()` gives, one row.
function _refuse_constant_terminal(instruction::SQLInstruction, keep_values::Bool, terminal::AbstractString)
  _builds_one_row(instruction, keep_values) || return nothing
  ask = terminal == "count()" ? "count the matched rows" : "ask whether any row matched"
  throw(QueryBuildError(
    "$(terminal) cannot answer for this query: its values() projection is an aggregate with no GROUP BY " *
    "and no HAVING, so it is exactly one row whatever matched (list() returns that one row, or none under " *
    "a slice), and the " *
    "answer would be a constant. To $(ask), drop the aggregate from values(); to keep the aggregate row " *
    "only when it passes a condition, filter on its alias; to read the aggregate's value, use " *
    ".aggregate(\"n\" => Count(...)) instead (#1100)."))
end

# #1066: an aggregating projection keeps its ordering too. An `order_by()` on a column it does not
# project is a GROUP BY term as well (`get_order_query`), so clearing it merged groups `list()` keeps
# apart. A kept ordering is printed, because its values bind under `:order`; elsewhere it is cleared.
_keeps_order(object::SQLObject, keep_values::Bool)::Bool = keep_values && _contains_agg(object.values)

# What an existence probe selects: `1`, or the kept projection — `DISTINCT` when the query is — whose
# GROUP BY names projection positions. Shared by `exists()` and `Exists(...)`.
_exists_projection(object::SQLObject, instruction::SQLInstruction, keep::Bool)::String =
  keep ? string(object.distinct ? "DISTINCT " : "", _query_select(instruction.select, instruction.connection)) : "1"

# The terminals that cannot honor a slice refuse it instead of ignoring it. `last()`, `earliest()` and
# `latest()` reorder the rows, which changes which rows the slice holds — Django refuses them too.
# `count(column)` and `aggregate()` refuse it by design (#1066): Django's `aggregate()` (its spelling of
# both) computes over the slice through a derived table, but here the same result is one call away —
# aggregate the query before slicing it — so the derived table is not worth building.
function _refuse_sliced(object::SQLObject, terminal::AbstractString, why::AbstractString)
  _is_sliced(object) || return nothing
  throw(QueryBuildError(
    "$(terminal) cannot run on a query with limit() or offset() set: $(why). " *
    "Call it on the query before slicing it, or clear the slice with limit(nothing).offset(0) first."))
end

function _count(oq::SQLObjectHandler; column::Union{Nothing, AbstractString} = nothing, distinct::Bool = false,
                  table_alias::Union{Nothing, SQLTableAlias} = nothing, show_query::Symbol = :execute)
  # Column form: COUNT([DISTINCT] column). Reuse the Count() aggregate so column
  # resolution, joins and dialect rendering are shared with values(Count(...)); we
  # return the scalar rather than a row. COUNT(DISTINCT col) is valid SQL (unlike
  # COUNT(DISTINCT *)), so no subquery is needed for this form.
  if column !== nothing
    _refuse_sliced(oq.object, "count(column)", "the column is counted over every matching row, not over the slice")
    cq = deepcopy(oq)
    cq.object.order = []
    cq.object.distinct = false      # DISTINCT belongs to COUNT(col), not the row set
    cq.object.limit = nothing
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
  # #1066: the projection is kept when it decides which rows `list()` returns — see
  # `_projection_shapes_rows`. Otherwise it is cleared, and a plain `values(...)` counts as before.
  is_distinct = distinct || q.object.distinct
  keep_values = _projection_shapes_rows(q.object; distinct = is_distinct, clear_degenerate = false)
  _keeps_order(q.object, keep_values) || (q.object.order = []) # clear order_by
  keep_values || (q.object.values = [])

  # Create shared table alias and parameters BEFORE building CTEs
  # so CTE parameters are numbered first (critical for positional backends).
  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters = get_parameter(connection)

  # Build WITH clause first — CTE params land in :cte bucket before main params.
  set_context!(parameters, :cte)
  with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

  # Main query continues from where CTE numbering left off.
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
  _refuse_constant_terminal(instruction, keep_values, "count()")
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  
  # Shared FROM / JOIN / WHERE / GROUP BY / HAVING body for every count form. GROUP BY and HAVING
  # are only ever filled for a kept, aggregating projection (#1066); the guard matches `query()`'s, as
  # a whole-table aggregate (`values("n" => Count("id"))`) groups by nothing.
  body = """FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    $(instruction.aggregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", ")) \n" : "")$(isempty(instruction.having) ? "" : "HAVING $(join(instruction.having, " AND \n   "))\n")$(isempty(instruction.order) ? "" : "ORDER BY $(join(instruction.order, ", "))\n")
    """
  if is_distinct || keep_values
    # COUNT(DISTINCT *) is invalid SQL in both PostgreSQL and SQLite, and a grouped projection has one
    # row per group, not per matching row. Either way the rows `list()` would return are counted from
    # a derived table, so count() == length(list()). With no values() the projection is `*`, so an
    # unprojected `distinct()` renders `SELECT DISTINCT *` as it always did. Its GROUP BY names
    # projection positions, which is why the projection is printed rather than replaced by `1`.
    # Any CTEs stay at the top level and remain in scope for the subquery; the projection's values bind
    # under `:select`, ahead of the WHERE ones, which is where its text sits.
    # #1074: a projection kept because a filter names its alias counts the same way, named for what it is.
    # #1053: a slice applies after DISTINCT and GROUP BY, so its tail goes inside the subquery. Its
    # markers are the last in the text and bind under `:limit`, the last bucket, so the order holds on
    # both engines.
    resposta = """$(with_clause)SELECT COUNT(*) FROM (
    SELECT $(is_distinct ? "DISTINCT " : "")$(_query_select(instruction.select, instruction.connection))
    $body$(_limit_offset_sql(q.object.limit, q.object.offset, parameters, instruction.connection))) as $(is_distinct ? "\"__pormg_distinct_count\"" : instruction.aggregate ? "\"__pormg_grouped_count\"" : "\"__pormg_projected_count\"")
    """
  elseif _is_sliced(q.object)
    # #1053: count the rows the slice returns, as Django's `qs[:5].count()` does. The ordering was
    # cleared above, and that is safe: how many rows a slice holds does not depend on which they are.
    resposta = """$(with_clause)SELECT COUNT(*) FROM (
    SELECT 1
    $body$(_limit_offset_sql(q.object.limit, q.object.offset, parameters, instruction.connection))) as "__pormg_sliced_count"
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
  _refuse_sliced(oq.object, "aggregate()", "the aggregate is computed over every matching row, not over the slice")

  cq = deepcopy(oq)
  cq.object.order = []
  cq.object.limit = nothing
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
    # #1066: a kept projection is probed as `list()` would run it — see `_projection_shapes_rows`.
    keep_values = _projection_shapes_rows(q.object; distinct = q.object.distinct && q.object.offset > 0, clear_degenerate = false)
    _keeps_order(q.object, keep_values) || (q.object.order = []) # clear order_by
    keep_values || (q.object.values = [])

    # Create shared table alias and parameters BEFORE building CTEs
    # so CTE parameters are numbered first (critical for positional backends).
    table_alias === nothing && (table_alias = SQLTbAlias())
    parameters = get_parameter(connection)

    # Build WITH clause first — CTE params land in :cte bucket before main params.
    set_context!(parameters, :cte)
    with_clause = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

    # Main query continues from where CTE numbering left off.
    instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters)
    _refuse_constant_terminal(instruction, keep_values, "exists()")
    # `LIMIT 1` is this query's own shape, not a user value, so it stays literal; the OFFSET the
    # caller set binds (#46). A non-positive offset was always dropped here, and still is.
    # #1053: a caller's `limit(0)` makes it `LIMIT 0` — the probe is the smaller of the two, so it is
    # one of two literals the code chooses, never the caller's value interpolated.
    limit_clause = _probe_limit(q.object.limit, 1) == 0 ? "LIMIT 0" : "LIMIT 1"
    offset_clause = q.object.offset > 0 ?
      with_bucket(() -> "OFFSET " * add_parameter!(parameters, q.object.offset), parameters, :limit) : ""
    
    # Quote table name and alias to prevent SQL injection
    safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
    safe_alias = quote_identifier(instruction.alias, instruction.connection)
    
    sql = """
    $(with_clause)SELECT $(_exists_projection(q.object, instruction, keep_values))
    FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(isempty(instruction._where) ? "" : "WHERE " * join(instruction._where, " AND \n   "))
    $(instruction.aggregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", "))" : "")$(isempty(instruction.having) ? "" : "\nHAVING " * join(instruction.having, " AND \n   "))$(isempty(instruction.order) ? "" : "\nORDER BY " * join(instruction.order, ", "))
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

A slice the caller set is honored: `first` takes the first row of the slice, so
`q.limit(0).first()` is `nothing` and `q.offset(10).first()` is the eleventh row (#1053).

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
  q.limit(_probe_limit(q.object.limit, 1))   # #1053: within the caller's slice, not instead of it
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

On a query with `limit()` or `offset()` set, `last` raises `QueryBuildError`, as Django's does:
reversing the ordering changes which rows the slice holds (#1053).
"""
function last(objct::SQLObjectHandler; show_query::Symbol = :execute)
  _refuse_sliced(objct.object, "last()", "it reverses the ordering, which changes which rows the slice holds")
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
  _refuse_sliced(objct.object, "$(opname)()", "it replaces the ordering, which changes which rows the slice holds")
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
extreme-row counterpart of [`get`](@ref), matching Django's `earliest()`. On a query with
`limit()` or `offset()` set it raises `QueryBuildError`, as Django's does (#1053).
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
`latest()`; `latest("f") == earliest("-f")`. A sliced query raises `QueryBuildError`, as for
[`earliest`](@ref).
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

A slice the caller set is honored: `get` looks for its one row inside the slice, so
`q.limit(0).get()` raises `DoesNotExist` (#1053). Inline filters join the `WHERE`
clause before the slice applies, the same as a `filter()` call after `limit()`.
"""
function get(objct::SQLObjectHandler, filters...; show_query::Symbol = :execute)
  # #199: copy-first — inline filters and the limit(2) probe apply to the copy only,
  # so they never leak into the caller's handler.
  q = deepcopy(objct)
  !isempty(filters) && _filter!(q.object, filters)
  q = q.limit(_probe_limit(q.object.limit, 2))   # #1053: within the caller's slice, not instead of it

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
