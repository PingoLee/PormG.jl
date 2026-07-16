
"build a row to join"
function _determine_join_type(field::PormGField; previus_how::Union{String, Nothing} = nothing, second_fild_name::Union{String, Nothing}=nothing)
  if previus_how !== nothing && previus_how == "LEFT"
    # if the previous join was a LEFT JOIN, the current join must be a LEFT JOIN
    return "LEFT"
  end
  
  @pormg_debug false
  if !hasproperty(field, :how)
    if second_fild_name !== nothing
      _check_if_field_is_a_operator(second_fild_name)
    end
    throw(ArgumentError("The field '$(field)' does not have a 'how' property"))
  elseif field.how !== nothing && !isempty(field.how)
    return _normalize_join_type(field.how)
  end
  
  return field.null ? "LEFT" : "INNER"
end

"""
    _cache_join(field::String, instruct::SQLInstruction)

Checks if a join path `field` is already in the cache. If not, and it's a join path (contains `__`), 
it attempts to build the join and cache it. Returns `true` if the field is in cache 
(either before or after the attempt), `false` otherwise.
"""
function _cache_join(field::String, instruct::SQLInstruction)
  haskey(instruct.cache, field) && return true
  
  if contains(field, "__")
    try
      # Build the join and get the SQL selector (e.g., "Tb.column")
      sql_selector = _build_row_join(split(field, "__") |> Vector{String}, instruct)
      
      # Populate the cache so it can be used immediately
      instruct.cache[field] = SQLField(sql_selector, field)
      return true
    catch e
      return false
    end
  end
  return false
end

# #45 — materialize a `cjoin_on` entry into a row_join WITHOUT the FK-driven anchor path. The ON
# clause is entirely user-provided (config["filters"]); no `main.key_a = joined.key_b` equi-anchor
# is emitted (build_row_join_sql_text skips it when "no_anchor" == "1"). key_a/key_b are never
# rendered for an anchor-less entry, but `_insert_join`'s dedup keys on (a, b, key_a, key_b, alias_a)
# and NOT alias_b — so we set key_a to the unique user alias, otherwise two cjoin_on joins to the
# same target model would collide and one would be silently dropped.
function _build_cjoin_on_row_join(config::Dict{String,Any}, join_path::String, instruct::SQLInstruction)::Nothing
  target_model = getfield(instruct.object.model._module, Symbol(config["target_model"]::String))::PormGModel
  user_alias = config["user_alias"]::String
  row_join = Dict{String,Union{String,Vector{FilterType}}}(
    "a"         => instruct.object.model.name,
    "alias_a"   => instruct.alias,
    "b"         => target_model.name,
    "alias_b"   => user_alias,
    "key_a"     => user_alias,   # dedup discriminator (never rendered for no_anchor)
    "key_b"     => "",
    "how"       => (get(config, "join_type", "INNER"))::String,
    "no_anchor" => "1",
  )
  filters = get(config, "filters", nothing)
  if filters isa Vector{FilterType} && !isempty(filters)
    row_join["on_conditions"] = filters
  end
  _insert_join(instruct.row_join, row_join, instruct.row_path, join_path)
  return nothing
end

function _build_row_join(field::Vector{SubString{String}}, instruct::SQLInstruction; as::Bool=true)
  # convert the field to a vector of string
  vector = String.(field)
  _build_row_join(vector, instruct, as=as)  
end

function _resolve_django_join_field(model::PormGModel, field_name::String, instruct::SQLInstruction)::String
  instruct.django === nothing && return field_name

  # Single O(1) dict lookup replaces the previous O(n) vector scan + dict access.
  field = get(model.fields, field_name, nothing)

  if field !== nothing
    # The field exists directly. Reject the explicit "_id" FK form (callers must use the short form).
    if endswith(field_name, "_id") && hasfield(typeof(field), :to)
      short_name = field_name[1:end-3]
      throw(ArgumentError("In Django-style join paths use '$(short_name)__...' instead of '$(field_name)__...'."))
    end
    return field_name
  end

  # Short-form resolution: "driver" → "driver_id" when a FK with that name exists.
  # This only applies to snake_case FK convention (e.g. driver_id).
  # camelCase FKs (e.g. driverid) must be referenced by their full field name.
  fk_field = get(model.fields, field_name * "_id", nothing)
  if fk_field !== nothing && hasfield(typeof(fk_field), :to)
    return field_name * "_id"
  end

  return field_name
end

# Resolve one side of an M2M relation (owner or related) to its PormGModel within `_module`:
# by binding first, then by formatted model name. Lets the join builder read each side's
# `db_column` for its PK (#64) — the relation stores only string names/bindings.
function _resolve_m2m_side_model(_module::Module, binding::String, model_name::String, field_name::String)::PormGModel
  bsym = Symbol(binding)
  if isdefined(_module, bsym)
    candidate = Base.invokelatest(getfield, _module, bsym)
    candidate isa PormGModel && return candidate
  end

  target_name = Models.format_model_name(model_name)
  for model in Models.get_all_models(_module)
    Models.format_model_name(model.name) == target_name && return model
  end

  throw(ArgumentError("The many-to-many model $(binding) for accessor $(field_name) is not defined"))
end

function _resolve_many_to_many_related_model(_module::Module, relation::Models.ManyToManyRelation)::PormGModel
  return _resolve_m2m_side_model(_module, relation.related_binding, relation.related_model, relation.field_name)
end

function _insert_many_to_many_joins(
  relation::Models.ManyToManyRelation,
  instruct::SQLInstruction,
  parent_table::String,
  parent_alias::String,
  join_path::String;
  previus_how::Union{String, Nothing}=nothing,
)
  join_type = previus_how == "LEFT" ? "LEFT" : "INNER"

  # #64: the PARENT-side join keys (owner_pk / related_pk) are field NAMES; resolve each to
  # its physical column via the owning model's db_column. The through-table columns
  # (owner_column / related_column) are the through table's own (auto-generated) columns and
  # stay as-is. `model_column` is a strict no-op when the PK has no db_column.
  _module = instruct.object.model._module::Module
  owner_model = _resolve_m2m_side_model(_module, relation.owner_binding, relation.owner_model, relation.field_name)
  related_model = _resolve_m2m_side_model(_module, relation.related_binding, relation.related_model, relation.field_name)

  through_row = sizehint!(Dict{String, Union{String, Vector{FilterType}}}(), 8)
  through_row["a"] = parent_table
  through_row["alias_a"] = parent_alias
  through_row["key_a"] = Models.model_column(owner_model, relation.owner_pk)
  through_row["b"] = relation.through_model
  through_row["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
  through_row["key_b"] = relation.owner_column
  through_row["how"] = join_type

  through_alias = _insert_join(instruct.row_join, through_row, instruct.row_path, "$(join_path)__through")

  related_row = sizehint!(Dict{String, Union{String, Vector{FilterType}}}(), 8)
  related_row["a"] = relation.through_model
  related_row["alias_a"] = through_alias
  related_row["key_a"] = relation.related_column
  related_row["b"] = relation.related_model
  related_row["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
  related_row["key_b"] = Models.model_column(related_model, relation.related_pk)
  related_row["how"] = join_type

  return _insert_join(instruct.row_join, related_row, instruct.row_path, join_path)
end

function _row_join_for_alias(row_join::Vector{Dict{String, Union{String, Vector{FilterType}}}}, alias::String)
  for row in row_join
    row["alias_b"] == alias && return row
  end
  throw(ArgumentError("Internal error: join alias $(alias) was not found in row_join"))
end

# Shared helper used at the four sites in `_build_row_join` where a many-to-many
# (forward or reverse) hop must be expanded into the through-table + related-table
# join pair. Returns the alias of the related-table join, the row dict for that
# join, the resolved related PormGModel, and (when applicable) the trailing
# `last_field` reference.
function _apply_many_to_many_branch(
  relation::Models.ManyToManyRelation,
  instruct::SQLInstruction,
  parent_table::String,
  parent_alias::String,
  join_path::String,
  vector::Vector{String};
  previus_how::Union{String, Nothing}=nothing,
  reverse::Bool=false,
)
  foreing_table_module = instruct.object.model._module::Module
  foreign_model = _resolve_many_to_many_related_model(foreing_table_module, relation)
  if length(vector) == 1
    msg = reverse ? "many-to-many reverse field" : "many-to-many field"
    throw("Error in _build_row_join, the column $(vector[1]) is a $(msg), you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
  end
  last_field = size(vector, 1) == 2 ? foreign_model.fields[vector[2]] : nothing
  tb_alias = _insert_many_to_many_joins(relation, instruct, parent_table, parent_alias, join_path, previus_how=previus_how)
  row_join = _row_join_for_alias(instruct.row_join, tb_alias)
  # #74: the related table reached through a many-to-many is the "many-side". Flag the (deduped)
  # row_join entry so the fan-out guard can refuse silently-inflated aggregates over base columns.
  row_join["to_many"] = "1"
  return (tb_alias, row_join, foreign_model, last_field)
end

# #27: validate JSON path key segments fail-closed. A segment is either a non-negative integer
# (JSON array index) or a safe identifier (SAFE_IDENTIFIER_PATTERN — the same contract as SQL
# identifiers). Anything else (spaces, dots, quotes, braces, empty) is rejected, so the validated
# segments are safe to interpolate into the path literal. Returns the segments unchanged.
function _validate_json_key_segments(segments::Vector{String})::Vector{String}
  for seg in segments
    if occursin(r"^\d+$", seg) || occursin(SAFE_IDENTIFIER_PATTERN, seg)
      continue
    end
    throw(_argerr("Invalid JSON key segment \e[31m$(seg)\e[0m in a JSON path lookup. Segments must be a non-negative integer (array index) or a simple key (letters, digits, underscore). Keys with spaces, dots, or quotes are not addressable via the `__` path syntax."))
  end
  return segments
end

# #27: render a JSON path lookup (e.g. `payload__driver`, `payload__0__name`) as a TEXT extraction
# on the resolved column. The base field is a non-terminal JSONField, so the trailing segments are
# a value path, not join hops. Records the resolved path in json_lookup_cache (so the filter-render
# branch binds the RHS as plain text) and tab_field_cache (so downstream sees the base field type).
function _render_json_lookup(instruct::SQLInstruction, alias::String, json_field::PormGField,
    field_name::String, key_segments::Vector{String}, full_field::Vector{String})::String
  segs = _validate_json_key_segments(key_segments)
  col = string(quote_identifier(alias, instruct.connection), ".",
               quote_identifier(Models.field_db_column(json_field, field_name), instruct.connection))
  path = join(full_field, "__")
  instruct.json_lookup_cache[path] = (json_field, segs)
  instruct.tab_field_cache[path] = json_field
  return Dialect._json_extract_expr(instruct.connection, col, segs)
end

function _build_row_join(field::Vector{String}, instruct::SQLInstruction; as::Bool=true)
  vector = copy(field)
  foreign_table_name::Union{String, PormGModel, Nothing} = nothing
  foreing_table_module::Module = instruct.object.model._module::Module
  row_join = sizehint!(Dict{String, Union{String, Vector{FilterType}}}(), 8)
 
  @pormg_debug false

  first_column = _resolve_django_join_field(instruct.object.model, vector[1], instruct)
  last_field::Union{Nothing, PormGField} = nothing
  join_path = field[1]
  m2m_inserted = false

  # #27: a non-terminal JSON base field is a value extraction (`payload__key`, `payload__0__name`),
  # not a join hop. Fire before the CTE/FK cascade — otherwise `payload` enters the forward-FK
  # branch and crashes in `_determine_join_type` (a JSONField has no `.how`). A TERMINAL JSON field
  # (length == 1) is left to resolve as a plain jsonb column (the target of the containment operators).
  if haskey(instruct.object.model.fields, first_column) &&
     Models.is_json_field(instruct.object.model.fields[first_column]) &&
     length(vector) > 1
    return _render_json_lookup(instruct, instruct.alias,
      instruct.object.model.fields[first_column], first_column, String.(vector[2:end]), field)
  end

  # Check if first_column references a CTE table
  if haskey(instruct.object.ctes, vector[1])
    @pormg_debug false
    cte_name = vector[1]
    cte_dict = instruct.object.ctes[cte_name]
    if !haskey(cte_dict, "model")
      throw(ArgumentError("Internal error: CTE $(cte_name) has not been materialized yet"))
    end
    cte_model = cte_dict["model"]::PormGModel
    
    length(vector) == 1 && throw("Error, CTE reference '$(cte_name)' must include a field name. Example: '$(cte_name)__field_name'")

    # Get the join field configuration from the CTE
    jf = cte_dict["join_field"]

    if jf === nothing
      # #44: no join_field → the CTE is CROSS JOINed and the correlation is supplied by the
      # main query's `F("<cte>__col")` filter(s), which render verbatim in WHERE. `join_type`
      # does not apply to a CROSS JOIN (INNER-like by nature).
      if !haskey(cte_model.fields, vector[2])
        available = join(collect(keys(cte_model.fields)), ", ")
        throw(ArgumentError("CTE field '$(vector[2])' not found in '$(cte_name)'; available fields: $(available)"))
      end
      row_join["a"] = instruct.object.model.name
      row_join["alias_a"] = instruct.alias
      row_join["b"] = cte_name  # CTE name becomes the table name
      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
      # "how" is never emitted for a CROSS entry (build_row_join_sql_text short-circuits on the
      # "cross" marker), but the deep-path loop below reads `row_join["how"]` as `prev_how`; set
      # it so an over-long path like `F("r91__col__more")` fails with the same "not a foreign key"
      # message as the keyed path instead of a cryptic KeyError.
      row_join["how"] = "CROSS"
      # Sentinel key columns: `_insert_join`'s dedup reads key_a/key_b directly (KeyError
      # otherwise), and the CROSS branch of `build_row_join_sql_text` skips them. Equal empty
      # strings also dedup repeat references to the same CTE (e.g. r91__raceid, r91__round)
      # onto a single CROSS JOIN.
      row_join["key_a"] = ""
      row_join["key_b"] = ""
      row_join["cross"] = "1"
    else
      join_field_pair = jf::Pair{String, String}
      main_table_key = join_field_pair.first    # e.g., "driverid" from main table
      cte_table_key = join_field_pair.second    # e.g., "driverid" from CTE
      @pormg_debug false

      if !haskey(cte_model.fields, cte_table_key)
        available = join(collect(keys(cte_model.fields)), ", ")
        throw(ArgumentError("CTE join_field column '$(cte_table_key)' not found in $(cte_name); available fields: $(available)"))
      end


      if (main_table_key in instruct.object.model.field_names)
        row_join["alias_a"] = instruct.alias
        # #64: resolve the main-model join field to its physical column (db_column).
        row_join["key_a"] = Models.model_column(instruct.object.model, main_table_key)
      elseif haskey(instruct.cache, main_table_key) || _cache_join(main_table_key, instruct)
        cache_item = instruct.cache[main_table_key]
        v_split = split(cache_item.field |> x -> replace(x,  '"' => ""), ".")
        row_join["alias_a"] = v_split[1] |> string
        row_join["key_a"] = v_split[2] |> string
      else
        throw(ArgumentError("Main table join_field column '$(main_table_key)' not found in $(instruct.object.model.name); available fields: $(join(instruct.object.model.field_names, ", "))"))
      end

      # Set up the join with the CTE
      row_join["a"] = instruct.object.model.name

      row_join["b"] = cte_name  # CTE name becomes the table name
      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
      row_join["how"] = cte_dict["join_type"]::String

      # #64: the CTE side stays the FIELD NAME — a CTE is a derived table whose columns are
      # the values() projection ALIASES (`"pk_code" AS "code"`), so the join references the
      # alias "code", not the physical column. Only the main-table side (key_a above) is a
      # real physical column and is db_column-resolved.
      row_join["key_b"] = cte_table_key
    end

    @pormg_debug false

    foreign_table_name = cte_model
    last_field = cte_model.fields[vector[2]]
   
  elseif haskey(instruct.object.model.fields, first_column) && Models.is_many_to_many_field(instruct.object.model.fields[first_column])
    relation = Models.get_many_to_many_relation(instruct.object.model, first_column)
    tb_alias, row_join, foreign_model, last_field = _apply_many_to_many_branch(
      relation, instruct, instruct.object.model.name, instruct.alias, join_path, vector
    )
    foreign_table_name = foreign_model
    m2m_inserted = true
  elseif first_column in instruct.object.model.field_names || _get_join_field(instruct.object, join_path) !== nothing
    row_join["a"] = instruct.object.model.name
    row_join["alias_a"] = instruct.alias
    # @pormg_debug
    first_field = _get_join_field(instruct.object, join_path) !== nothing ? _get_join_field(instruct.object, join_path) : instruct.object.model.fields[first_column]
    # @pormg_debug
    row_join["how"] = _determine_join_type(first_field, second_fild_name= size(vector, 1) > 1 ? vector[2] : nothing)
    foreign_table_name = first_field.to
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(first_column) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.name
      size(vector, 1) == 2 && (last_field = foreign_table_name.fields[vector[2]])
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      size(vector, 1) == 2 && (last_field = getfield(foreing_table_module, foreign_table_name |> Symbol).fields[vector[2]])
    end
    # @pormg_debug
    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    # Local FK column and referenced parent column both honor db_column (#50).
    row_join["key_b"] = Models.fk_target_column(first_field)
    row_join["key_a"] = Models.field_db_column(first_field, first_column)
  elseif haskey(instruct.object.model.related_objects, vector[1])
    related_object = instruct.object.model.related_objects[vector[1]]
    if related_object isa Models.ManyToManyRelation
      relation = related_object::Models.ManyToManyRelation
      tb_alias, row_join, foreign_model, last_field = _apply_many_to_many_branch(
        relation, instruct, instruct.object.model.name, instruct.alias, join_path, vector; reverse=true
      )
      foreign_table_name = foreign_model
      m2m_inserted = true
    else
    # @pormg_debug false
    s_model = Symbol(uppercasefirst(string(instruct.object.model.related_objects[vector[1]][3])))
    reverse_model = getfield(foreing_table_module, s_model)
    length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
    # !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
    row_join["a"] = instruct.object.model.name
    row_join["alias_a"] = instruct.alias
    join_field = reverse_model.fields[instruct.object.model.related_objects[vector[1]][1] |> String]
    row_join["how"] = _determine_join_type(join_field, second_fild_name= vector[2])
    size(vector, 1) == 2 && (last_field = reverse_model.fields[vector[2]])
    foreign_table_name = instruct.object.model.related_objects[vector[1]][3] |> String
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.name
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
    end

    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    # Reverse join: key_a is the parent's referenced column, key_b the child's FK
    # column; both honor db_column (resolved in their own model, no-op without it) (#50).
    row_join["key_a"] = Models.model_column(instruct.object.model, instruct.object.model.related_objects[vector[1]][2] |> String)
    row_join["key_b"] = Models.model_column(reverse_model, instruct.object.model.related_objects[vector[1]][1] |> String)
    # #74: a reverse foreign key (one-to-many) makes the child table the many-side.
    row_join["to_many"] = "1"
    foreign_table_name = s_model |> string
    @pormg_debug false
    end
  else
    @pormg_debug false
    throw(_argerr("the column \e[4m\e[31m$(vector[1])\e[0m not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m, that contains the fields: \e[4m\e[32m$(join(instruct.object.model.field_names, ", "))\e[0m and the related objects: \e[4m\e[32m$(join(keys(instruct.object.model.related_objects), ", "))\e[0m"))
  end

  if !m2m_inserted
    join_type_override = _get_join_type_override(instruct.object, join_path)
    join_type_override !== nothing && (row_join["how"] = join_type_override)

    join_filters = _get_join_filters(instruct.object, join_path)
    if join_filters !== nothing && !isempty(join_filters)
      @pormg_debug false
      row_join["on_conditions"] = join_filters
    end

    tb_alias = _insert_join(instruct.row_join, row_join, instruct.row_path, join_path) 
  end
  
  vector = vector[2:end]  

  @pormg_debug false
  
  while size(vector, 1) > 1
    # get new object
    @pormg_debug false
    join_path = join(field[1:length(field)-length(vector) + 1], "__")
    new_object = foreign_table_name isa PormGModel ? foreign_table_name : getfield(foreing_table_module, foreign_table_name |> Symbol)
    first_column = _resolve_django_join_field(new_object, vector[1], instruct)

    # #27: a non-terminal JSON field reached through FK joins (e.g. `fk__payload__key`) is a value
    # extraction on the joined table's alias, not a further hop. size(vector) > 1 here, so the
    # trailing segments are a JSON path.
    if haskey(new_object.fields, first_column) && Models.is_json_field(new_object.fields[first_column])
      return _render_json_lookup(instruct, tb_alias, new_object.fields[first_column], first_column, String.(vector[2:end]), field)
    end

    # Create a new Dict for this join to avoid mutating previously inserted joins
    prev_how = row_join["how"]
    prev_b = row_join["b"]
    row_join = sizehint!(Dict{String, Union{String, Vector{FilterType}}}(), 8)

    # Track whether the reverse-join branch already advanced vector
    _reverse_advanced = false
    _m2m_inserted = false

    if haskey(new_object.fields, first_column) && Models.is_many_to_many_field(new_object.fields[first_column])
      relation = Models.get_many_to_many_relation(new_object, first_column)
      tb_alias, row_join, foreign_model, last_field = _apply_many_to_many_branch(
        relation, instruct, prev_b, tb_alias, join_path, vector; previus_how=prev_how
      )
      foreign_table_name = foreign_model
      _m2m_inserted = true
    elseif first_column in new_object.field_names
      first_field = new_object.fields[first_column]
      !hasfield(typeof(first_field), :to) && throw("Error in _build_row_join, the column $(first_column) is a field from $(new_object.name), but this field has not a foreign key")
      row_join["a"] = prev_b
      row_join["alias_a"] = tb_alias      
      row_join["how"] = _determine_join_type(new_object.fields[first_column], previus_how=prev_how, second_fild_name= size(vector, 1) > 1 ? vector[2] : nothing)
      foreign_table_name = new_object.fields[first_column].to
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(vector[2]) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join["b"] = foreign_table_name.name
        size(vector, 1) == 2 && (last_field = foreign_table_name.fields[vector[2]])
      else
        row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
        size(vector, 1) == 2 && (last_field = getfield(foreing_table_module, foreign_table_name |> Symbol).fields[vector[2]])
      end
      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias) # TODO chage by row_join and test the speed
      # Local FK column and referenced parent column both honor db_column (#50).
      row_join["key_b"] = Models.fk_target_column(first_field)
      row_join["key_a"] = Models.field_db_column(first_field, first_column)
    elseif haskey(new_object.related_objects, vector[1])
      related_object = new_object.related_objects[vector[1]]
      if related_object isa Models.ManyToManyRelation
        relation = related_object::Models.ManyToManyRelation
        tb_alias, row_join, foreign_model, last_field = _apply_many_to_many_branch(
          relation, instruct, prev_b, tb_alias, join_path, vector; previus_how=prev_how, reverse=true
        )
        foreign_table_name = foreign_model
        _m2m_inserted = true
      else
      s_model = Symbol(uppercasefirst(string(new_object.related_objects[vector[1]][3])))
      reverse_model = getfield(foreing_table_module, s_model)
      length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
      !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
      row_join["a"] = prev_b
      row_join["alias_a"] = tb_alias
      join_field = reverse_model.fields[new_object.related_objects[vector[1]][1] |> String]
      row_join["how"] = _determine_join_type(join_field, previus_how=prev_how, second_fild_name= vector[2])
      size(vector, 1) == 2 && (last_field = reverse_model.fields[vector[2]])
      foreign_table_name = new_object.related_objects[vector[1]][3] |> String
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join["b"] =  foreign_table_name.name
      else
        row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      end

      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
      # Reverse join: key_a is the parent's referenced column, key_b the child's FK
      # column; both honor db_column (resolved in their own model, no-op without it) (#50).
      row_join["key_a"] = Models.model_column(new_object, new_object.related_objects[vector[1]][2] |> String)
      row_join["key_b"] = Models.model_column(reverse_model, new_object.related_objects[vector[1]][1] |> String)
      # #74: a reverse foreign key (one-to-many) makes the child table the many-side.
      row_join["to_many"] = "1"
      foreign_table_name = s_model |> string
      vector = vector[2:end]
      _reverse_advanced = true
      end

    else
      throw("Error in _build_row_join, the column $(vector[1]) not found in $(new_object.name)")
    end

    @pormg_debug false   
    if !_m2m_inserted
      join_type_override = _get_join_type_override(instruct.object, join_path)
      join_type_override !== nothing && (row_join["how"] = join_type_override)

      join_filters = _get_join_filters(instruct.object, join_path)
      if join_filters !== nothing && !isempty(join_filters)
        row_join["on_conditions"] = join_filters
      end
      
      tb_alias = _insert_join(instruct.row_join, row_join, instruct.row_path, join_path)
    end

    # Only advance vector for forward-FK joins; reverse joins already advanced above
    if !_reverse_advanced
      vector = vector[2:end]
    end

  end

  # tb_alias is the last table alias in the join ex. tb_1
  # last_column is the last column in the join ex. last_login
  # vector is the full path to the column ex. user__last_login__date (including functions (except the suffix))

  # @pormg_debug

  # println("$(join(field, "__"))")
  # functions must be processed here
  instruct.tab_field_cache["$(join(field, "__"))"] = last_field
  return string(quote_identifier(tb_alias, instruct.connection), ".", _solve_field(vector[end], foreing_table_module, foreign_table_name, instruct))
  
end