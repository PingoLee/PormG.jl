"""
  get_select_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the values of the object and generates the SELECT query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the values to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the SELECT query will be added.
"""
function get_select_query(values::Vector{Union{SQLTypeText,SQLTypeField}}, instruc::SQLInstruction)
  for i in eachindex(values) # linear indexing
    v_copy = deepcopy(values[i])

    # SQLText (from Value(x)) is a literal value, not a column reference.
    # Handle it separately: parameterize via _get_select_query(::SQLText) 
    # and use custom_as as the alias.
    if isa(v_copy, SQLTypeText)
      resolved = _get_select_query(v_copy, instruc)
      # Wrap into an SQLField for consistent SELECT rendering
      alias = v_copy.custom_as !== nothing ? v_copy.custom_as : v_copy._as
      instruc.select[i] = SQLField(resolved, alias)
      if alias !== nothing
        instruc.cache[alias] = instruc.select[i]
      end
      continue
    end

    if isa(v_copy.field, Union{SQLTypeFunction, SQLTypeF})
      if _is_window_expr(v_copy.field)
        nothing
      elseif v_copy.field.aggregate == false
        push!(instruc.group, i |> string)
      else
        instruc.aggregate = true
      end
    elseif isa(v_copy.field, Union{SubqueryObject, ExistsObject})
      # #92: a projected scalar subquery / EXISTS is a per-row expression — neither a groupable
      # column nor an outer aggregate. It must NOT be pushed into GROUP BY (in a mixed projection
      # with a real aggregate, that would otherwise emit the subquery's positional index into GROUP BY).
      nothing
    else
      push!(instruc.group, i |> string)
    end

    if haskey(instruc.cache, v_copy._as)
      instruc.select[i] = instruc.cache[v_copy._as]  # TODO That is necessary in get_select_query
    else
      @pormg_debug false
      v_copy.field = _get_select_query(v_copy.field, instruc, _as=v_copy._as)
      instruc.select[i] = v_copy
      if v_copy._as === nothing
        throw(QueryBuildError("Field requires an alias: \e[4m\e[31m$(v_copy.field)\e[0m must have a name using the format \e[4m\e[32m\"field_name\" => $(v_copy.field)\e[0m or use \e[4m\e[32mSQLField($(v_copy.field), \"alias_name\")\e[0m"))
      end
      instruc.cache[v_copy._as] = instruc.select[i]
    end
  end

  # #194 (interim, coarse): a projected correlated Subquery/Exists alongside a grouped projection is
  # dangerous when the OuterRef column is not in the GROUP BY — PostgreSQL raises a GroupingError, but
  # SQLite silently evaluates the subquery against an ARBITRARY row of each group (a plausible-looking
  # wrong number). We cannot yet resolve which outer columns the inner OuterRefs reference (tracked in
  # #194 for a precise fail-loud guard), so warn on the combination itself. False positive when the
  # correlation column IS grouped — the message says so. `values` holds the originals (the loop deep-
  # copies), so the SubqueryObject/ExistsObject fields are still inspectable here.
  if instruc.aggregate && !isempty(instruc.group) &&
     any(v -> v isa SQLTypeField && isa(v.field, Union{SubqueryObject,ExistsObject}), values)
    @warn(_emsg(
      "Subquery/Exists projected alongside a grouped aggregate: if the inner OuterRef column is not " *
      "in the GROUP BY, SQLite silently returns an arbitrary row's value per group and PostgreSQL " *
      "raises a GroupingError. Ensure the correlated column is part of the grouped projection " *
      "(then this warning is a false positive — precise guard tracked in #194)."))
  end
end

# NULLS FIRST/LAST syntax landed in SQLite 3.30.0; older builds need the portable
# `(expr IS NULL)` prefix instead (#75).
const SQLITE_NULLS_ORDER_MIN_VERSION = 3030000

# Resolve NULL placement for one ORDER BY term (#75). The canonical default matches PostgreSQL
# (NULL sorts as the largest value): ASC → :last, DESC → :first — so ordering a nullable column
# returns the same rows on both backends. An explicit SQLOrder(...; nulls=:first|:last) overrides it.
function _nulls_placement(orientation::AbstractString, nulls::Union{Symbol,Nothing})
  nulls === :first && return :first
  nulls === :last  && return :last
  nulls === nothing || throw(QueryBuildError("Invalid nulls placement $(repr(nulls)); use :first or :last"))
  return uppercase(strip(String(orientation))) == "DESC" ? :first : :last
end

# Render one ORDER BY term with explicit NULL placement, portable across backends (#75).
function _order_term_sql(expr, orientation::AbstractString, placement::Symbol, conn)
  if conn isa PormGSQLite && backend_sqlite_version(conn) < SQLITE_NULLS_ORDER_MIN_VERSION
    # SQLite < 3.30 has no NULLS syntax → emulate placement by sorting on the null-flag first.
    # NULLS FIRST means nulls (flag 1) come first → DESC on the flag; NULLS LAST → ASC on the flag.
    # This references `expr` twice. A resolved ORDER BY column/alias is a bare identifier, but a
    # function-valued order term could render a positional `?` placeholder; duplicating that would
    # bind the value once yet reference it twice → parameter misalignment. Guard against it: only
    # emulate when `expr` is placeholder-free. For the rare parameterized order term on this ancient
    # SQLite, emit the plain term (native NULL placement) — normalization is skipped, never corrupted.
    if occursin('?', string(expr))
      return string(expr, " ", orientation)
    end
    flag_dir = placement === :first ? "DESC" : "ASC"
    return string("(", expr, " IS NULL) ", flag_dir, ", ", expr, " ", orientation)
  end
  return string(expr, " ", orientation, " ", placement === :first ? "NULLS FIRST" : "NULLS LAST")
end

function get_order_query(object::SQLObject, instruc::SQLInstruction)
  for v in object.order
    found_in_select = false
    v_field_copy = deepcopy(v.field)

    # Check if the ORDER BY target matches a selected alias. Only those aliases can be
    # referenced directly in ORDER BY. Cached join paths created while resolving CTE join_field
    # entries must reuse their resolved SQL selector instead of quoting the raw lookup string.
    for value in object.values
      if isa(value, SQLTypeFunction) && value.field.aggregate == true
        continue
      end

      selected_alias = value.custom_as !== nothing ? value.custom_as : value._as
      if selected_alias == v_field_copy._as
        found_in_select = true
        break
      end
    end

    if haskey(instruc.cache, v_field_copy._as)
      if found_in_select
        # Use the alias name instead of the expression to avoid double parameterization.
        # Most databases (PG, SQLite, MySQL) support aliases in ORDER BY.
        v_field_copy.field = quote_identifier(v_field_copy._as, instruc.connection)
      else
        v_field_copy.field = instruc.cache[v_field_copy._as].field
      end
    else
      v_field_copy.field = _get_select_query(v_field_copy.field, instruc)
    end
    # Re-validate at render: SQLOrder is mutable, so a post-construction reassignment could
    # bypass the constructor whitelist (#77) — same render-time guard the window path has.
    orientation = _normalize_order_orientation(v.orientation)
    placement = _nulls_placement(orientation, v.nulls)
    push!(instruc.order, _order_term_sql(v_field_copy.field, orientation, placement, instruc.connection))
    instruc.cache[v_field_copy._as] = v_field_copy

    if !found_in_select
      # #76: Under DISTINCT, an ORDER BY term that is not part of the projection is rejected by
      # PostgreSQL and the SQL standard (SQL Server / Oracle / DB2 / default-mode MySQL all reject
      # it), while SQLite silently runs it with a nondeterministic DISTINCT/order interaction. Refuse
      # it on both backends so the two stay aligned. Match on the resolved SQL *expression*
      # (v_field_copy.field was resolved just above), not the base column: PG rejects `ORDER BY
      # DATE(x)` even when `x` is projected, yet accepts an aliased column (`SELECT x AS y ... ORDER
      # BY x`) — expression membership captures both. Skip when there is no explicit projection
      # (`SELECT DISTINCT *`) or the projection carries a `*` wildcard that already covers the column.
      if object.distinct && !isempty(object.values) && !any(_is_wildcard_projection, object.values)
        order_expr = string(v_field_copy.field)
        in_projection = false
        for i in eachindex(instruc.select)
          isassigned(instruc.select, i) || continue
          if string(instruc.select[i].field) == order_expr
            in_projection = true
            break
          end
        end
        if !in_projection
          # Keep the suggestion generic (`.values(...)`) rather than echoing v_field_copy._as: for a
          # transform order term the alias is the internal name (e.g. "created_at__date"), which is NOT
          # valid input syntax to paste back (the user wrote "created_at__@date"), so a specific token
          # would mislead. The offending term is still named in the diagnosis.
          throw(QueryBuildError(
            "DISTINCT query cannot ORDER BY \e[4m\e[31m$(v_field_copy._as)\e[0m: it is not in the " *
            "SELECT DISTINCT projection. PostgreSQL (and the SQL standard) rejects this; SQLite " *
            "would return rows in a nondeterministic order. Add the ordering column or expression " *
            "to \e[4m\e[32m.values(...)\e[0m so it is projected, or drop " *
            "\e[4m\e[32m.distinct()\e[0m and order by an aggregate if you meant one row per key."))
        end
      end
      push!(instruc.group, v_field_copy.field)
    end

  end
  return nothing
end

function _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc::SQLInstruction)
  if instruc.connection isa PormGSQLite && raw_value isa Union{Number,Bool}
    return raw_value
  end
  return formatted_value
end

function _resolve_having_filter_value(alias::String, raw_value, instruc::SQLInstruction)
  if haskey(instruc.tab_field_cache, alias)
    formatted_value = instruc.tab_field_cache[alias].formatter(raw_value)
    return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
  end

  for selected_value in instruc.object.values
    selected_alias = selected_value.custom_as !== nothing ? selected_value.custom_as : selected_value._as
    selected_alias == alias || continue

    if isa(selected_value, SQLTypeField) && isa(selected_value.field, SQLTypeFunction)
      sql_function = selected_value.field

      if sql_function.formatter !== nothing
        formatted_value = sql_function.formatter(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif sql_function.function_name == "AVG"
        formatted_value = Models.format_number_sql(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif haskey(PormGTypeField, sql_function.function_name)
        formatted_value = getfield(Models, PormGTypeField[sql_function.function_name])(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif sql_function.function_name in ["SUM", "COUNT"]
        formatted_value = Models.format_number_sql(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif sql_function.function_name in ["MAX", "MIN"] && sql_function.column isa String && haskey(instruc.object.model.fields, sql_function.column)
        formatted_value = instruc.object.model.fields[sql_function.column].formatter(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      end
    end
  end

  formatted_value = IntegerField().formatter(raw_value)
  return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
end

"""
  get_filter_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the filter of the object and generates the WHERE query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the filter to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the WHERE query will be added.
"""
function get_filter_query(object::SQLObject, instruc::SQLInstruction)::Nothing
  # [isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? push!(instruc._where, _get_filter_query(v, instruc)) : throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper") for v in object.filter]
  @pormg_debug false
  for v in object.filter
    if isa(v, ExistsObject)
      push!(instruc._where, _get_filter_query(v, instruc))
    elseif isa(v, SQLTypeOper)
      @pormg_debug false
      if isa(v.column, SQLTypeField) && isa(v.column.field, String) && !contains(v.column.field, "__") && !(v.column.field in instruc.object.model.field_names)
        # @pormg_debug false
        field = try
          instruc.cache[v.column._as].field
        catch e
          # @pormg_debug
          rethrow(e)
        end
        # Switch to having context for positional parameters
        set_context!(instruc, :having)
        placeholder = add_parameter!(instruc, _resolve_having_filter_value(v.column._as, v.values, instruc))
        push!(instruc.having, "$(field) $(v.operator) $(placeholder)")
        set_context!(instruc, :where)
        continue
      end
      push!(instruc._where, _get_filter_query(v, instruc))
    elseif isa(v, Union{SQLTypeQor,SQLTypeQ,SQLTypeF})
      push!(instruc._where, _get_filter_query(v, instruc))
    else
      throw(FilterError("Invalid filter entry: $(v) (::$(typeof(v))) is not a Q, Qor, or operator expression."))
    end
  end
  return nothing
end

function build_row_join_sql_text(instruc::SQLInstruction)
  @pormg_debug false

  # --- Phase 1: pre-resolve ON conditions -----------------------------------
  # Filter resolution for deep paths (e.g. "raceid__circuitid__country") may
  # create additional join entries in instruc.row_join via _build_row_join.
  # By pre-resolving with an index-based loop we process newly created entries
  # in order and store the generated SQL fragments for Phase 2.
  n_before = length(instruc.row_join)
  on_clause_extras = Dict{Int, Vector{String}}()
  i = 1
  while i <= length(instruc.row_join)
    value = instruc.row_join[i]
    set_context!(instruc, :join)

    if haskey(value, "on_conditions") && value["on_conditions"] !== nothing
      on_conditions = value["on_conditions"]::Vector{FilterType}
      alias_a_quoted = quote_identifier(value["alias_a"], instruc.connection)
      original_alias = instruc.alias
      extras = String[]

      no_anchor = get(value, "no_anchor", "") == "1"
      for condition in on_conditions
        condition_sql = _get_filter_query(condition, instruc)
        # #45: anchor-less cjoin_on conditions already carry explicit aliases (bare F = base alias,
        # F("b2.col") = the joined copy), so skip the single-side base-alias remap the FK path needs.
        if !no_anchor
          condition_sql = replace(condition_sql, "\"$(original_alias)\"." => "$alias_a_quoted.")
        end
        push!(extras, condition_sql)
      end

      instruc.alias = original_alias
      on_clause_extras[i] = extras
    end
    i += 1
  end

  # --- Phase 1b: relocate forward-referencing ON extras ----------------------
  # When ON extras for join `idx` reference the alias of a join `dep_idx` that
  # was *created* during Phase 1 (i.e. dep_idx > n_before), it means the ON
  # condition uses a deep path (e.g. raceid__circuitid__country) that chains
  # through the current join's target table.  Emitting those extras on `idx`
  # would forward-reference `dep_idx` (whose JOIN clause hasn't appeared yet).
  #
  # Fix: move such extras to `dep_idx`'s ON clause, which is the join whose
  # alias is referenced.  The base ON of `dep_idx` already references `idx`'s
  # alias_b (the parent), so ordering is satisfied: idx emits first, dep_idx
  # emits second with the relocated extras.
  for idx in 1:n_before
    haskey(on_clause_extras, idx) || continue
    extras = on_clause_extras[idx]
    relocated = falses(length(extras))

    for dep_idx in (n_before+1):length(instruc.row_join)
      dep_alias = instruc.row_join[dep_idx]["alias_b"]
      for (ei, extra) in enumerate(extras)
        if !relocated[ei] && occursin("\"$(dep_alias)\"", extra)
          # Move this extra to dep_idx's ON clause
          if !haskey(on_clause_extras, dep_idx)
            on_clause_extras[dep_idx] = String[]
          end
          push!(on_clause_extras[dep_idx], extra)
          relocated[ei] = true
        end
      end
    end

    # Keep only the non-relocated extras on the original join
    if any(relocated)
      on_clause_extras[idx] = extras[.!relocated]
      isempty(on_clause_extras[idx]) && delete!(on_clause_extras, idx)
    end
  end

  # --- Phase 2: emit JOIN SQL text in original order -------------------------
  for (idx, value) in enumerate(instruc.row_join)
    set_context!(instruc, :join)
    b_quoted = safe_table_identifier(value["b"], instruc.connection)
    alias_b_quoted = quote_identifier(value["alias_b"], instruc.connection)

    # #44: a CROSS-joined CTE (no join_field) carries sentinel empty key columns and has no ON —
    # the correlation is supplied by the main query's F() filter(s) in WHERE. Emit it and move on
    # before touching key_a/key_b (empty strings would fail identifier validation).
    if get(value, "cross", nothing) !== nothing
      push!(instruc.join, """ CROSS JOIN $b_quoted AS $alias_b_quoted """)
      continue
    end

    if get(value, "no_anchor", "") == "1"
      # #45: anchor-less join — the ON clause is entirely the user's resolved extras (no equi-anchor).
      extras = get(on_clause_extras, idx, String[])
      isempty(extras) && throw(QueryBuildError("cjoin_on produced no ON conditions for alias '$(value["alias_b"])'."))
      on_clause = join(extras, " AND ")
    else
      alias_a_quoted = quote_identifier(value["alias_a"], instruc.connection)
      key_a_quoted = quote_identifier(value["key_a"], instruc.connection)
      key_b_quoted = quote_identifier(value["key_b"], instruc.connection)

      # Build base ON clause
      on_clause = "$alias_a_quoted.$key_a_quoted = $alias_b_quoted.$key_b_quoted"

      # Append pre-resolved ON condition fragments
      if haskey(on_clause_extras, idx)
        for extra in on_clause_extras[idx]
          on_clause *= " AND $extra"
        end
      end
    end

    push!(instruc.join, """ $(value["how"]) JOIN $b_quoted AS $alias_b_quoted ON $on_clause """)
  end
end

function build(object::SQLObject;
  table_alias::Union{Nothing,SQLTableAlias}=nothing,
  connection::Union{Nothing,PormGPostgres,PormGSQLite}=nothing,
  parameters::Union{Nothing,AbstractPormGParam}=nothing,
  set_contexts::Bool=true,
  outer::Union{Nothing,SQLInstruction}=nothing)
  ensure_model_transaction_scope(object.model)

  settings, connection, conn_key = get_settings(object, connection=connection)

  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters === nothing && (parameters = get_parameter(connection))
  @pormg_debug false
  instruct = InstructionObject(text="",
    object=object,
    table_alias=table_alias === nothing ? SQLTbAlias() : table_alias,
    alias=get_alias(table_alias),
    connection=connection,
    # `_django_app_label` rather than a bare `=== nothing` check (#345): an empty prefix is the
    # absence of one, and this must agree with `Model_to_str`/`get_model_name` or the two disagree
    # about the same connection. With `django_prefix: ''` the old spelling produced `django == "_"`,
    # so the reverse-join table fallback below prefixed every unpinned table with an underscore.
    django=(_app_label = Models._django_app_label(settings); _app_label === nothing ? nothing : _app_label * "_"), # TODO, remover
    parameters=parameters,
    outer=outer,
  )

  # Switch context for each SQL section so positional-parameter backends
  # (SQLite) push values into the correct bucket.
  # Subqueries skip this to inherit the parent's current bucket.
  set_contexts && set_context!(instruct, :select)
  get_select_query(object.values, instruct)

  set_contexts && set_context!(instruct, :where)
  get_filter_query(object, instruct)

  # Materialize explicit custom joins that weren't discovered by traversal.
  # This ensures cjoin filters are applied even in UPDATE/DELETE without explicit field paths.
  # We check against instruct.row_path to avoid redundant materialization (forcing them twice).
  for c_j in object.custom_join
    config = c_j |> Base.last
    if c_j |> Base.first ∉ instruct.row_path && config isa Dict{String,Any} && haskey(config, "field") && config["field"] isa PormGField
      array = split(c_j |> Base.first, "__")
      push!(array, config["field"].pk_field)
      _build_row_join(array, instruct)
    end
  end

  # #45: materialize anchor-less cjoin_on entries. They carry no FK "field", so the loop above skips
  # them; build their row_join directly (no equi-anchor, explicit alias, user-supplied ON).
  for c_j in object.custom_join
    config = c_j |> Base.last
    if (c_j |> Base.first) ∉ instruct.row_path && config isa Dict{String,Any} && get(config, "no_anchor", false) == true
      _build_cjoin_on_row_join(config, c_j |> Base.first, instruct)
    end
  end

  set_contexts && set_context!(instruct, :join)
  build_row_join_sql_text(instruct)

  get_order_query(object, instruct)  # ORDER BY has no parameters

  _check_aggregate_fanout(instruct)  # #74: refuse silently-inflated aggregates over to-many joins

  return instruct
end

# #74 fan-out guard ------------------------------------------------------------------------------
# A to-many join (reverse FK / many-to-many) repeats base-table rows, so COUNT/SUM/AVG over a column
# from a row-multiplied table silently inflates the result. We refuse those at build time rather than
# return a confidently-wrong number. The legitimate case — aggregating the to-many table's OWN column
# (the sole many-side) — is preserved. MAX/MIN are immune; `distinct=true` is an explicit opt-in.
function _check_aggregate_fanout(instruct::SQLInstruction)
  isempty(instruct.agg_sources) && return nothing
  # Derive the many-side aliases from the *deduped* row_join. A join can be built more than once
  # (e.g. _cache_join pre-builds a filter join, then it is built again for real); _insert_join keeps
  # only one entry, so deriving here counts each actual to-many join exactly once.
  many = Set{String}()
  for r in instruct.row_join
    get(r, "to_many", "") == "1" && push!(many, string(r["alias_b"]))
  end
  isempty(many) && return nothing
  n = length(many)
  for a in instruct.agg_sources
    a.distinct && continue
    ambiguous = a.alias == "\0AMBIGUOUS"
    # Safe only when the aggregate targets the sole to-many table's own column.
    (!ambiguous && a.alias in many && n == 1) && continue
    throw(QueryBuildError(_fanout_error_msg(a, many, ambiguous)))
  end
  return nothing
end

function _fanout_error_msg(a, many, ambiguous::Bool)
  paths = join(sort!(collect(many)), ", ")
  reason = ambiguous ?
    "the aggregated expression spans more than one source, so it cannot be proven safe under a row-multiplying (to-many) join" :
    "it aggregates a column from a table that a to-many join row-multiplies"
  string(
    "PormG fan-out guard (#74): the aggregate \e[4m\e[31m", a.label, "\e[0m is inflated because ", reason, ".\n",
    "  A to-many join (reverse foreign key or many-to-many) repeats base-table rows, so ", a.func,
    " would count/sum each base row once per related row.\n",
    "  To-many table alias(es) in this query: \e[33m", paths, "\e[0m.\n",
    "  Fix one of:\n",
    "    \e[32m1.\e[0m Aggregate the RELATED table's own column instead (e.g. count related rows: Count(\"reverse_relation__id\")).\n",
    "    \e[32m2.\e[0m Pass \e[32mdistinct=true\e[0m to the aggregate if de-duplicated counting is what you want.\n",
    "    \e[32m3.\e[0m Compute the aggregate in a correlated \e[32mSubquery(...)\e[0m projected in values() " *
    "(correlate the inner query with \e[32mOuterRef(...)\e[0m) so the base rows are not multiplied.\n")
end
