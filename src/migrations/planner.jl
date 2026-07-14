# ==============================================================================
# MIGRATION PLANNER
# Logic for diffing current code models against database state and generating
# migration plans (makemigrations).
# ==============================================================================

# ---
# Internal Helpers
# ---

function _hash_field_name(model_name::Symbol, field_name::Union{String, Symbol}; apend_number::Int64=5)::String
  _hash = randstring(8) 
  name = "$(model_name)_$field_name"
  if sizeof(name) + 8 + apend_number > 63
    max_prefix_length = max(1, 63 - length(_hash) - apend_number)
    if sizeof(name) > max_prefix_length
      safe_name = ""
      for c in name
        if sizeof(safe_name) + sizeof(c) <= max_prefix_length
          safe_name *= c
        else
          break
        end
      end
      name = safe_name
    end
  end
  return "$(name)_$_hash" |> lowercase
end

function _configure_order_dict_migration_plan(migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, key::String, value::String)
  value == "" && return
  if !haskey(migration_plan, model_name)
    migration_plan[model_name] = OrderedDict{String, String}(key => value)
  else
    migration_plan[model_name][key] = value
  end
end

# #82: wrap a SQLite table-rebuild block so it re-creates the table's existing secondary indexes (the
# rebuild's DROP TABLE drops them) and gates on `PRAGMA foreign_key_check(<table>)`. The CREATE INDEX DDL
# is taken verbatim from sqlite_master, so names / uniqueness / partial clauses are preserved exactly.
# No-op for PostgreSQL (real ALTER COLUMN, no rebuild) or an empty block — callers invoke it
# unconditionally so every rebuild path (field alteration AND add-NOT-NULL-with-default) is covered the
# same way. The check is SCOPED to the rebuilt table (not the whole DB) so an unrelated pre-existing orphan
# elsewhere can't fail this migration; the rename preserves the table name + PKs, so children of this table
# stay valid and need no check.
function _sqlite_rebuild_preserving_indexes(conn, table_name::String, rebuild_sql::AbstractString;
                                            surviving_columns::Union{Nothing,Set{String}} = nothing,
                                            column_renames::Dict{String,String} = Dict{String,String}())::String
  (!(conn isa PormGSQLite) || isempty(rebuild_sql)) && return String(rebuild_sql)
  # #116: when the rebuild removes columns (FK-field deletion), pass the rebuilt table's columns so an
  # index on a just-dropped column isn't re-created ("no such column"). `nothing` (the default) preserves
  # every live index, i.e. the pre-#116 behavior for pure alterations where no column disappears.
  # #150: `column_renames` (old ⇒ new physical name) maps a renamed column so its live index survives the
  # filter and is re-created under the new name; empty (the default) for every non-rename rebuild.
  idx_ddls = get_secondary_index_ddls(conn, table_name; surviving_columns = surviving_columns, column_renames = column_renames)
  safe_tbl = replace(table_name, "\"" => "\"\"")
  return join(String[String(rebuild_sql); idx_ddls; "PRAGMA foreign_key_check(\"$(safe_tbl)\");"], "\n")
end

# Physical column names (db_column when set, else field name) of a model's rebuilt table — the exact set
# `alter_field(::PormGSQLite, model, …)` writes into the new CREATE TABLE / INSERT (see Dialect.jl). Passed
# as `surviving_columns` to `_sqlite_rebuild_preserving_indexes` so index preservation stays column-aware
# across a rebuild that drops a column (#116).
_model_physical_columns(model::PormGModel)::Set{String} =
  Set(Models.field_db_column(f, string(k)) for (k, f) in model.fields)

# #150: true when the FK definition differs between the old and the desired field — the signal that a
# renamed FK field also needs a SQLite table rebuild (RENAME COLUMN alone keeps the old FK clause). Covers
# an FK being added/removed by the rename (incl. a db_constraint true⇄false flip) and, when both sides are
# live FKs, a change of target model, target column, or on_delete. Reuses the same FK comparison the
# alteration path uses (`Models._compare_field_foreign_key` / `Models.fk_target_column`).
function _fk_definition_changed(new_field::PormGField, old_field::PormGField)::Bool
  new_fk = hasfield(typeof(new_field), :to) && new_field.db_constraint
  old_fk = hasfield(typeof(old_field), :to) && old_field.db_constraint
  new_fk != old_fk && return true
  (new_fk && old_fk) || return false
  return !Models._compare_field_foreign_key(new_field, old_field) ||
         Models.fk_target_column(new_field) != Models.fk_target_column(old_field) ||
         (hasfield(typeof(new_field), :on_delete) && hasfield(typeof(old_field), :on_delete) &&
          new_field.on_delete != old_field.on_delete)
end

function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_field::Union{PormGField, Nothing}, old_field::PormGField)::Nothing
  if hasfield(old_field |> typeof, :to) && old_field.db_constraint && (new_field === nothing || !hasfield(new_field |> typeof, :to) || !new_field.db_constraint)
    if conn isa PormGSQLite
      # SQLite has no `ALTER TABLE DROP CONSTRAINT`; an FK can only be removed by rebuilding the
      # table. On the field-alteration path this is a no-op ON PURPOSE: `_alter_table_fields`
      # already emits a full table rebuild (Dialect.alter_field wrapped by
      # _sqlite_rebuild_preserving_indexes) from the DESIRED model, and that rebuild simply omits
      # the FOREIGN KEY clause when the desired field dropped it — so the constraint is already
      # gone, data + indexes are preserved, and no separate FK-drop DDL exists to emit. (#83)
      # NOTE: field DELETION (drop_field → DROP COLUMN) and column RENAME do NOT get a rebuild, so
      # removing an FK *there* is still unsupported on SQLite — tracked separately.
      return nothing
    end
    
    constraint_name = get_constraints_fk(conn, model_name, field_name)
    if constraint_name === nothing
      return nothing
    end
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove foreign key: $field_name", 
    Dialect.drop_foreign_key(conn, model_name, constraint_name))
  end
  return nothing
end
function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol, new_field::Union{PormGField, Nothing}, old_field::PormGField)
  _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name |> string, new_field, old_field)
end

function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String; index_name::Union{String, Nothing} = nothing)::Nothing
  if index_name === nothing
    index_name = get_constraints_index(conn, model_name, field_name)
  end
  
  if index_name === nothing
    return nothing
  end
  # PostgreSQL: a UNIQUE constraint creates a backing index with the same name.
  # DROP INDEX fails when the index backs a constraint, so drop the constraint first.
  if conn isa PormGPostgres
    table_name = format_model_name(model_name)
    drop_sql = """ALTER TABLE \"$table_name\" DROP CONSTRAINT IF EXISTS \"$index_name\";\nDROP INDEX IF EXISTS \"$index_name\";"""
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name", drop_sql)
  else
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name",
    Dialect.drop_index(conn, index_name))
  end
  return nothing    
end
function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol; index_name::Union{String, Nothing} = nothing)
  _drop_index(conn, migration_plan, model_name, field_name |> string, index_name=index_name)
end

function _add_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_field::PormGField, old_field::PormGField, name::String)::Nothing
  # to alterations
  if hasfield(new_field |> typeof, :to) && new_field.db_constraint && (!hasfield(old_field |> typeof, :to) || !old_field.db_constraint)
    if conn isa PormGSQLite
       @warn "Adding foreign keys to existing SQLite tables requires recreation. This is not fully automated yet."
       return nothing
    end
    constraint_name = "$(name)_fk" |> lowercase
    # Local FK column and referenced parent column both honor db_column (#50).
    resolved_pk = Models.fk_target_column(new_field)
    local_col = Models.field_db_column(new_field, string(field_name))
    on_delete_sql = hasfield(typeof(new_field), :on_delete) ? Dialect._foreign_key_on_delete_sql(new_field.on_delete) : nothing
    _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name",
    Dialect.add_foreign_key(conn, model_name, "\"$constraint_name\"", "\"$local_col\"",  "\"$(new_field.to |> format_model_name)\"", "\"$resolved_pk\"", on_delete=on_delete_sql))
  end
  return nothing
end

function _add_constrains(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::Union{String, Symbol}, field::PormGField, name::String)::Nothing
  Models.is_many_to_many_field(field) && return nothing

  # to new fields
  # If the new field is a foreign key
  if hasfield(field |> typeof, :to) && field.db_constraint
    if conn isa PormGPostgres
      constraint_name = name * "_fk" |> lowercase
      # Local FK column and referenced parent column both honor db_column (#50).
      resolved_pk = Models.fk_target_column(field)
      local_col = Models.field_db_column(field, string(field_name))
      on_delete_sql = hasfield(typeof(field), :on_delete) ? Dialect._foreign_key_on_delete_sql(field.on_delete) : nothing
      _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name",
      Dialect.add_foreign_key(conn, model.name, "\"$constraint_name\"", "\"$local_col\"",  "\"$(field.to |> format_model_name)\"", "\"$resolved_pk\"", on_delete=on_delete_sql))
    # For SQLite, FKs are added in CREATE TABLE, so if we are adding a field to an existing table, 
    # we might need recreation if it's a FK.
    end
  end

  # If the new field is also indexed (index targets the physical column, db_column #50)
  if !field.primary_key && field.db_index
    index_name = name * "_idx" |> lowercase
    index_col = Models.field_db_column(field, string(field_name))
    _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name",
    Dialect.create_index(conn, "\"$index_name\"", "\"$(model.name |> lowercase)\"", ["\"$index_col\""]))
  end
  nothing
end

function _add_many_to_many_auto_constraints(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel)::Nothing
  haskey(model.cache, "many_to_many_auto") || return nothing

  metadata = model.cache["many_to_many_auto"]
  owner_column = metadata["owner_column"]::String
  related_column = metadata["related_column"]::String
  unique_index = metadata["unique_index"]::String
  _configure_order_dict_migration_plan(
    migration_plan,
    model_name,
    "Create many-to-many unique index",
    Dialect.create_unique_index(conn, "\"$unique_index\"", "\"$(model.name |> lowercase)\"", ["\"$owner_column\"", "\"$related_column\""])
  )
  return nothing
end

function _add_new_table(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel)::Nothing
  _configure_order_dict_migration_plan(migration_plan, model_name, "New model", Dialect.create_table(conn, model))
  for (field_name, field) in model.fields       
    name = _hash_field_name(model_name, field_name)      
    _add_constrains(conn, migration_plan, model_name, model, field_name, field, name)      
  end
  _add_many_to_many_auto_constraints(conn, migration_plan, model_name, model)
  return nothing
end

function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::String; temporary_default_value::Any = nothing)::Nothing
  field = model.fields[field_name]
  Models.is_many_to_many_field(field) && return nothing
  name = _hash_field_name(model_name, field_name)
  _configure_order_dict_migration_plan(migration_plan, model_name, "Add field: $field_name", Dialect.add_field(conn, model_name, field_name, field, temporary_default = temporary_default_value))
  _add_constrains(conn, migration_plan, model_name, model, field_name, field, name)
  if temporary_default_value !== nothing
    # SQLite requires a full table recreation to drop the temporary default.
    # Use the same stable "Alter table:" key so multiple datetime fields being
    # added at once don't produce duplicate recreation statements.
    alter_key = conn isa PormGSQLite ? "Alter table: $model_name" : "Alter field: $field_name"
    # Delete existing recreation entry so re-insertion moves it to the END of
    # the OrderedDict — after ALL ADD COLUMNs.  Without this, the recreation
    # keeps its original position and later ADD COLUMNs hit "duplicate column".
    if conn isa PormGSQLite && haskey(migration_plan, model_name) && haskey(migration_plan[model_name], alter_key)
      delete!(migration_plan[model_name], alter_key)
    end
    # #82: this add-NOT-NULL-with-default path also rebuilds the table on SQLite, so it must preserve the
    # existing secondary indexes too (no-op on PostgreSQL).
    _configure_order_dict_migration_plan(migration_plan, model_name, alter_key,
      _sqlite_rebuild_preserving_indexes(conn, model.name |> lowercase,
        Dialect.alter_field(conn, model, field_name, field, nothing, [:default]);
        surviving_columns = _model_physical_columns(model)))
  end
  return nothing
end
function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::Symbol; temporary_default_value::Any = nothing)::Nothing
  _add_new_field(conn, migration_plan, model_name, model, field_name |> string, temporary_default_value=temporary_default_value)
end

function _alter_table_fields(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, settings::SQLConn; interactive::Bool = true)::Nothing
  # @pormg_debug model_name == :new_join_position
  if Models.are_model_fields_equal(current_schema[model_name][:model], model)
    # println("Model $model_name are equal")
  else        
    # Compare fields
    @pormg_debug false
    # Convert keys(model.fields) to an array of stripped strings and keep mapping to original key
    model_fields_map = Dict(String(strip(key, '"')) => String(key) for key in keys(model.fields))
    stripped_model_fields = Set(keys(model_fields_map))

    # Do the same for current_schema model fields, but key by the PHYSICAL column name
    # (db_column when set, else the field name) so the code side aligns with the
    # column-keyed introspected DB side — otherwise a field whose db_column differs from
    # its name would churn as a spurious DROP + ADD (#50). The value stays the real
    # field-name key for accessing model.fields.
    current_fields_map = Dict(Models.field_db_column(field, String(strip(String(key), '"'))) => String(key) for (key, field) in current_schema[model_name][:model].fields)
    stripped_current_fields = Set(keys(current_fields_map))

    # check the field are not in current_schema (deletion)
    colect_deletion::Vector{Symbol} = []
    for field_name in stripped_model_fields
      if !(field_name in stripped_current_fields)
        push!(colect_deletion, Symbol(field_name))
      end
    end

    colect_addition::Vector{Symbol} = []
    for field_name in stripped_current_fields
      if !(field_name in stripped_model_fields)
        push!(colect_addition, Symbol(field_name))
      end
    end    
    
    @pormg_debug false
    # Pass maps to resolve fields so original keys can be used for accessing model.fields
    _resolve_table_fields(conn, model_name, model, current_schema[model_name][:model], colect_deletion, colect_addition, migration_plan, settings, model_fields_map, current_fields_map, interactive=interactive)
      
    for field_name_stripped in stripped_current_fields
      original_code_key = current_fields_map[field_name_stripped]
      if haskey(model_fields_map, field_name_stripped)
        original_db_key = model_fields_map[field_name_stripped]
        
        field = current_schema[model_name][:model].fields[original_code_key]
        old_field = model.fields[original_db_key]

        # check if the field is diferent
        colect_not_equal::Vector{Symbol} = []
        if old_field |> typeof == field |> typeof                          
          # Check if all attributes are equal                
          for attr in fieldnames(typeof(field))
            new_var = getfield(field, attr)
            old_var = getfield(old_field, attr)
            if new_var != old_var                  
              attr == :to && Models._compare_field_foreign_key(field, old_field) && continue
              # pk_field is compared by RESOLVED referenced column: a field-name pk_field on
              # the code side matches the introspected physical column when the parent pk is
              # renamed via db_column (#50). No-op when the referenced column isn't renamed.
              attr == :pk_field && Models.fk_target_column(field) == Models.fk_target_column(old_field) && continue
              # :db_column never alters the live schema by itself — the column identity is
              # already proven equal by the matched (column-keyed) field, and the introspected
              # side carries db_column=nothing (#50).
              attr in [:blank, :on_delete, :related_name, :verbose_name, :editable, :how, :formater, :db_column] && continue
              push!(colect_not_equal, attr)
            end
          end
        else
          # check is db_constraint is false in field
          if field |> typeof == Models.sForeignKey && !field.db_constraint &&  old_field |> typeof == Models.sBigIntegerField
            continue
          else
            push!(colect_not_equal, :type)
          end
        end
        
        # if field_name == "time"
        #   @pormg_debug
        # end
        
        isempty(colect_not_equal) && continue                       

        # Check if is needed remove the foreign key
        name::String = _hash_field_name(model_name, field_name_stripped)
        
        _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name_stripped, field, old_field)
        
        # For SQLite every field alteration requires a full table recreation. Use a
        # single stable key ("Alter table: <model>") so repeated calls for the same
        # table overwrite each other, producing exactly one recreation statement
        # instead of one per changed field.
        alter_key = conn isa PormGSQLite ? "Alter table: $model_name" : "Alter field: $field_name_stripped"
        # #82: on SQLite this preserves the table's secondary indexes across the rebuild and gates on
        # foreign_key_check (no-op on PostgreSQL). See _sqlite_rebuild_preserving_indexes.
        alter_sql = _sqlite_rebuild_preserving_indexes(conn, model.name |> lowercase,
          Dialect.alter_field(conn, current_schema[model_name][:model], field_name_stripped, field, old_field, colect_not_equal);
          surviving_columns = _model_physical_columns(current_schema[model_name][:model]))
        _configure_order_dict_migration_plan(migration_plan, model_name, alter_key, alter_sql)

        # Check if the field is a foreign key
        _add_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name_stripped, field, old_field, name)
        
        # Check if the field is also indexed
        if !field.primary_key && field.db_index && !model.fields[original_db_key].db_index
          @pormg_debug false
          # #82: SQLite introspection can't see db_index, so this branch always fires for an indexed
          # field; and the table rebuild (alter_field) already re-emits every existing index. Skip the
          # redundant CREATE INDEX when one already exists in the live DB, or it would duplicate the
          # rebuilt index (random suffix defeats IF NOT EXISTS). Genuinely-new indexes still get created.
          if !(conn isa PormGSQLite && get_constraints_index(conn, model_name, field_name_stripped) !== nothing)
            index_name = "$(name)_idx"
            _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name_stripped",
            Dialect.create_index(conn, "\"$index_name\"", "\"$(model.name |> lowercase)\"", ["\"$field_name_stripped\""]))
          end
        end

        # Check if is need to remove the index
        if !field.primary_key && old_field.db_index && !field.db_index
          @pormg_debug
          index_name = model.cache["index"][original_db_key]
          _drop_index(conn, migration_plan, model_name, field_name_stripped, index_name=index_name)
          # _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name_stripped", 
          # Dialect.drop_index(conn, "\"$index_name\""))
        end
      end
    end    
  end     
end

function _resolve_table_fields(
                                conn::Union{PormGPostgres, PormGSQLite}, 
                                model_name::Symbol, 
                                model::PormGModel, 
                                current_model::PormGModel, 
                                colect_deletion::Vector{Symbol}, 
                                colect_addition::Vector{Symbol}, 
                                migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                                settings::SQLConn,
                                model_fields_map::Dict{String, String},
                                current_fields_map::Dict{String, String};
                                interactive::Bool = true
                              )::Nothing
  # Check by rename field  
  while !isempty(colect_addition)
    field_name_sym = colect_addition[1]
    field_name = field_name_sym |> string       
    colect_numbered, list_to_question = _colect_numbered_fields(colect_deletion)
    if colect_deletion |> isempty
      # `field_name` here is the physical column; pass the real field key so _add_new_field's
      # model.fields lookup resolves (the DDL re-derives the db_column from the field) (#50).
      _add_new_field(conn, migration_plan, model_name, current_model, current_fields_map[field_name], temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings))
    else       
      response = "no"
      if interactive
        print(_emsg("Is the field \"\e[4m\e[31m$field_name\e[0m\" from table \"\e[4m\e[34m$model_name\e[0m\" the same as one of the following fields: \e[4m\e[33m$list_to_question\e[0m? If yes, please enter the corresponding number; otherwise, type 'no':"))
        response = readline()
        response = strip(lowercase(response))
      end
      
      if response in ["no", "n"]
        # `field_name` is the physical column; pass the real field key (see above) (#50).
        _add_new_field(conn, migration_plan, model_name, current_model, current_fields_map[field_name], temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings))
      else
        old_field_sym::Union{Symbol,Nothing} = nothing
        try
          response_idx = parse(Int, response)
          old_field_sym = colect_numbered[response_idx]          
        catch e
          throw("Invalid number, please try makemigrations again")
          return
        end
        old_field_name = old_field_sym |> string
        new_field = current_model.fields[current_fields_map[field_name]]
        old_field = model.fields[model_fields_map[old_field_name]]
        if conn isa PormGSQLite && _fk_definition_changed(new_field, old_field)
          # #150: on SQLite the FK clause lives inside CREATE TABLE and `RENAME COLUMN` keeps the OLD clause,
          # so a rename whose FK definition ALSO changes needs the same model-based table rebuild the
          # alteration (#83) and deletion (#116) paths use. RENAME COLUMN is emitted FIRST so the rebuild's
          # INSERT..SELECT — which copies by the NEW physical name — finds the column; the rebuild then
          # re-creates the table from `current_model` with the new FK clause, preserving the secondary
          # indexes (renamed via `column_renames`) under the stable "Alter table:" key. A plain FK rename
          # (no FK change) takes the cheap path below — SQLite updates the FK's local column reference
          # natively. Co-occurring field DELETIONS on this table are handled: the deletion loop below defers
          # to this rebuild (which already drops every removed column). Residual limitation: a co-occurring
          # field ALTERATION re-emits "Alter table:" WITHOUT column_renames (the renamed column's index may
          # be dropped), and a second rename/addition on the same table is unsupported (the rebuild copies by
          # `current_model`'s names, which the other change hasn't applied to the old table yet) — both rare,
          # and both fail safely (the runner transaction rolls back). Tracked as a #150 follow-up.
          old_phys = Models.field_db_column(old_field, old_field_name)
          _configure_order_dict_migration_plan(migration_plan, model_name, "Rename field: $field_name",
          Dialect.rename_field(conn, model_name, old_field_name, field_name))
          _configure_order_dict_migration_plan(migration_plan, model_name, "Alter table: $model_name",
          _sqlite_rebuild_preserving_indexes(conn, current_model.name |> lowercase,
            Dialect.alter_field(conn, current_model, field_name, new_field, old_field, Symbol[]);
            surviving_columns = _model_physical_columns(current_model),
            column_renames = Dict(old_phys => field_name)))
        else
          _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, old_field_name, new_field, old_field)
          !new_field.primary_key && _drop_index(conn, migration_plan, model_name, old_field_name)
          _configure_order_dict_migration_plan(migration_plan, model_name, "Rename field: $field_name",
          Dialect.rename_field(conn, model_name, old_field_name, field_name))
          _add_constrains(conn, migration_plan, model_name, current_model, field_name, new_field, _hash_field_name(model_name, field_name))
        end
        # Update model.fields to reflect rename to avoid double processing if needed
        model.fields[model_fields_map[old_field_name]] = model.fields[model_fields_map[old_field_name]] # effectively stays same but we can update key if we want to sync
        # remove the old field from colect_deletion
        filter!(x -> x != old_field_sym, colect_deletion)
      end
    end      
    filter!(x -> x != field_name_sym, colect_addition)
  end
  # #150: a rename-with-FK-change may already have scheduled a full SQLite rebuild for this model (keyed
  # "Alter table: $model_name"). That rebuild is generated from `current_model`, which omits EVERY deleted
  # field, so it already drops this table's remaining deletions. Running the per-column deletion handling
  # below as well would emit `DROP COLUMN "<other>"` for a column the rebuild already removed ("no such
  # column"), so defer to the rebuild when it is present (SQLite only; PostgreSQL uses plain DROP COLUMN).
  sqlite_rename_rebuild = conn isa PormGSQLite && haskey(migration_plan, model_name) &&
    haskey(migration_plan[model_name], "Alter table: $model_name")
  if !isempty(colect_deletion) && !sqlite_rename_rebuild
    # #116: On SQLite an FK column can't be removed with `ALTER TABLE DROP COLUMN` (SQLite forbids it and
    # has no `ALTER TABLE DROP CONSTRAINT`), so deleting an FK field needs a full table rebuild. The rebuild
    # is generated from `current_model`, which already omits EVERY deleted field, so ONE rebuild drops all of
    # this table's deleted columns (and their FKs/indexes) at once. Therefore if ANY deleted field forces a
    # rebuild, route the WHOLE table's deletions through it and skip the per-column DROP COLUMNs — emitting
    # both would race: the rebuild removes the column, then a separate `DROP COLUMN "<other>"` for a
    # sibling deletion fails "no such column" (order-dependent on the deletion set's iteration).
    fk_delete_idx = nothing
    if conn isa PormGSQLite
      fk_delete_idx = findfirst(colect_deletion) do fsym
        f = model.fields[model_fields_map[string(fsym)]]
        hasfield(typeof(f), :to) && f.db_constraint
      end
    end
    if fk_delete_idx !== nothing
      # `alter_field(::PormGSQLite, model, …)` rebuilds the table purely from `model.fields`; its
      # field_name/new_field/old_field/colect_not_equal arguments are unused for the SQLite recreation, so a
      # representative deleted field is passed only to satisfy the shared signature. `surviving_columns` keeps
      # the dropped columns' indexes off the preserved set (see _sqlite_rebuild_preserving_indexes). The
      # stable "Alter table:" key means a co-occurring alteration/add-default collapses into this one
      # idempotent recreation from the same desired model.
      rebuild_field = model.fields[model_fields_map[string(colect_deletion[fk_delete_idx])]]
      _configure_order_dict_migration_plan(migration_plan, model_name, "Alter table: $model_name",
        _sqlite_rebuild_preserving_indexes(conn, current_model.name |> lowercase,
          Dialect.alter_field(conn, current_model, string(colect_deletion[fk_delete_idx]), rebuild_field, rebuild_field, Symbol[]);
          surviving_columns = _model_physical_columns(current_model)))
    else
      # PostgreSQL, or SQLite with no FK-column deletions: plain DROP COLUMN works (the FK drop runs first on
      # PostgreSQL; the index is pre-dropped so SQLite can drop an ordinary column).
      for field_name_sym in colect_deletion
        field_name = field_name_sym |> string
        old_field = model.fields[model_fields_map[field_name]]
        _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name, nothing, old_field)
        _drop_index(conn, migration_plan, model_name, field_name)
        _configure_order_dict_migration_plan(migration_plan, model_name, "Remove field: $field_name",
        Dialect.drop_field(conn, model_name, field_name))
      end
    end
  end
  # `_configure_order_dict_migration_plan` returns the created OrderedDict when it makes a fresh table
  # entry; the FK-rebuild branch above ends on that call, so return `nothing` explicitly to satisfy this
  # function's `::Nothing` contract (otherwise Julia tries to `convert(Nothing, OrderedDict)` and errors).
  return nothing
end

function _colect_numbered_fields(colect::Vector{Symbol})
  # Number the rename candidates in a deterministic (name-sorted) order so the prompt — and the index the
  # user answers with — is stable across runs regardless of the underlying set-iteration order. Sorting a
  # copy leaves the caller's `colect_deletion` untouched (it's still needed for the later `filter!`).
  colect = sort(colect, by = string)
  colect_numbered = Dict{Int64, Symbol}()
  for (index, field_name) in enumerate(colect)
    colect_numbered[index] = field_name
  end
  return colect_numbered, join([string(index, " - ", colect_numbered[index]) for index in sort(collect(keys(colect_numbered)))], ", ")
end
function _get_temporary_default_value(field::PormGField, settings::SQLConn)
  if field |> typeof == Models.sDateTimeField
    return field.formater(now(), settings.time_zone) |> field.formater
  elseif field |> typeof == Models.sDateField
    return field.formater(today())    
  else
    return nothing
  end
end


# ---
# Public API (makemigrations)
# ---

# Compare model definitions to the current database schema
function get_migration_plan(models::Vector{PormGModel}, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, conn, settings::SQLConn; interactive::Bool = true)
# models is olds models

migration_plan = OrderedDict{Symbol, OrderedDict{String, String}}()
futher_processing = Dict{Symbol, Dict{Symbol, Any}}()
current_schema = Models.synthesize_many_to_many_through_models(current_schema, settings)

# models is empty set all models to migration_plan
if isempty(models)
  for (model_name, model) in current_schema
    _add_new_table(conn, migration_plan, model_name, model[:model])
  end
  return migration_plan  
end

@pormg_debug false

for model in models # models is olds models
  model_name = model.name |> Symbol
  # model_name = lowercase(string(model.name)) |> Symbol
  @pormg_debug false
  if haskey(current_schema, model_name)
    current_schema[model_name][:exist] = true
    _alter_table_fields(conn, migration_plan, model_name, model, current_schema, settings, interactive=interactive)
  else
    if !haskey(futher_processing, :drop_table)
      futher_processing[:drop_table] = Dict{Symbol, Any}(model_name => Dict{String, Any}("model" => model, "exist" => false))
    else
      futher_processing[:drop_table][model_name] = Dict{String, Any}("model" => model, "exist" => false)
    end
  end
end

@pormg_debug false

# Check for models in the current schema that are not in the models
for (model_name, model) in current_schema
  if model[:exist] == false
    if haskey(futher_processing, :drop_table) # TODO: i need test this
      
      response = "yes"
      if interactive
        print("The table $model_name is a new table? (yes/no): ")
        response = readline()
        response = strip(lowercase(response))
      end

      if response in ["yes", "y"]
        _add_new_table(conn, migration_plan, model_name, model[:model])
      elseif response in ["no", "n"]
        dict_rename = Dict{Int64, Symbol}()
        for (index, (m_name, m_info)) in enumerate(futher_processing[:drop_table])
          !m_info["exist"] && (dict_rename[index] = m_name )           
        end         
        if isempty(dict_rename)
          _add_new_table(conn, migration_plan, model_name, model[:model])
        else 
          list_to_question = join([string(index, " - ", dict_rename[index]) for index in keys(dict_rename)], ", ")
          
          response = "no"
          if interactive
            print("Please choice what is the older name from table $model_name: $list_to_question (choice a number) or type 'no': ")
            response = readline()
            response = strip(lowercase(response))
          end

          if response in ["no", "n"]
            _add_new_table(conn, migration_plan, model_name, model[:model])
          else
            try
              res_idx = parse(Int, response)
              old_model_name = dict_rename[res_idx]
              # first i need to alter the fields from old table named in postgres
              _alter_table_fields(conn, migration_plan, old_model_name, futher_processing[:drop_table][old_model_name]["model"], current_schema, settings, interactive=interactive)
              _configure_order_dict_migration_plan(migration_plan, model_name, "Rename table", Dialect.rename_table(conn, model_name, old_model_name |> string))
              futher_processing[:drop_table][old_model_name]["exist"] = true
            catch e
              throw("Invalid number, please try makemigrations again")
            end
          end
        end         
      end    
    else 
      _add_new_table(conn, migration_plan, model_name, model[:model])    
    end
  end
 
end

@pormg_debug false

# at last check all models in futher_processing to drop
if haskey(futher_processing, :drop_table)
  for (model_name, model_info) in futher_processing[:drop_table]
    if model_info["exist"] == false
      _configure_order_dict_migration_plan(migration_plan, model_name, "Drop table", Dialect.drop_table(conn, model_name))
    end
  end
end

# println(migration_plan)


return migration_plan
end

# Main function to simulate makemigrations
function makemigrations(connection::PormGPostgres, settings::SQLConn; path::String = "db/models.jl", interactive::Bool = true)
if !settings.change_db
  @warn("Schema changes are disabled (`change_db: false`). Set `change_db: true` in your db/connection.yml under the active environment to allow migrations.")
  return
end
@pormg_debug false
models_array::Vector{PormGModel} = []
try
  models_array = convert_schema_to_models(connection)
catch e
  error_message = sprint(showerror, e)
  if occursin("Table definition not found", error_message)
    @info("The database is empty, that is migrate all tables") # TODO, impruve this message
  else
    println("Error: ", e)
    @error("Error: ", e)
    return
  end
end

# get module from the path (load + resolve FK targets + default pk_field — #62)
current_models = _load_current_models(path)

@pormg_debug false

migration_plan = get_migration_plan(models_array, current_models, connection, settings, interactive=interactive)

@pormg_debug false

# store migration_plan as pending_migrations.jl file
if migration_plan |> isempty
  @info(_emsg("\e[32mYour database schema is already up-to-date. No migrations are pending.\e[0m"))    
else     
  path = joinpath(settings.db_def_folder, "migrations")
  if !ispath(path)
    mkdir(path)
  end
  generate_migration_plan("pending_migrations.jl", migration_plan, path)
  @warn("The migration plan has been saved to '$(settings.db_def_folder)/migrations/pending_migrations.jl'. Review the plan before applying the migrations.")
  @info(_emsg("\e[32mMigration plan generated successfully. Run 'PormG.Migrations.migrate($( settings.db_def_folder == "db" ? "" : string("\"", settings.db_def_folder, "\"")))' to apply the migrations.\e[0m"))
end

end

function makemigrations(connection::PormGSQLite, settings::SQLConn; path::String = "db/models.jl", interactive::Bool = true)
  if !settings.change_db
    @warn("Schema changes are disabled (`change_db: false`). Set `change_db: true` in your db/connection.yml under the active environment to allow migrations.")
    return
  end
  
  models_array::Vector{PormGModel} = []
  try
    models_array = convert_schema_to_models(connection)
  catch e
    @error("Error converting schema to models: ", e)
    return
  end

  # get module from the path (load + resolve FK targets + default pk_field — #62)
  current_models = _load_current_models(path)

  migration_plan = get_migration_plan(models_array, current_models, connection, settings, interactive=interactive)

  # store migration_plan as pending_migrations.jl file
  if migration_plan |> isempty
    @info(_emsg("\e[32mYour database schema is already up-to-date. No migrations are pending.\e[0m"))    
  else     
    path = joinpath(settings.db_def_folder, "migrations")
    if !ispath(path)
      mkdir(path)
    end
    generate_migration_plan("pending_migrations.jl", migration_plan, path)
    @warn("The migration plan has been saved to '$(settings.db_def_folder)/migrations/pending_migrations.jl'. Review the plan before applying the migrations.")
    @info(_emsg("\e[32mMigration plan generated successfully. Run 'PormG.Migrations.migrate($( settings.db_def_folder == "db" ? "" : string("\"", settings.db_def_folder, "\"")))' to apply the migrations.\e[0m"))
  end
end

function makemigrations(db::String; config::Dict{String,SQLConn} = config, interactive::Bool = true)
settings = Configuration.get_settings(db)
path = joinpath(db, settings.model_file)
isfile(path) || error("The file $(path) does not exists")
makemigrations(settings.connections, settings, path=path, interactive=interactive)
end

function get_all_models(mod::Module)::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}
# Get all models from a module
models = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()
for name in names(mod, all = true)
  if isdefined(mod, name)
    obj = getfield(mod, name)
    if isa(obj, PormGModel)
      if obj.name == ""
        obj.name = name |> string |> format_model_name
      end
      models[name |> string |> lowercase |> Symbol] = Dict{Symbol, Union{Bool, PormGModel}}(:model => obj, :exist => false) # TODO: change model.name to lowercase in all project
    end
  end
end
return models
end

# #62/#65: Shared makemigrations prelude — load the code models for a schema diff, then
# resolve string FK/O2O targets to model objects and default `pk_field`. The planner
# loads models into a throwaway module via `Base.include` and never runs `set_models`
# (deliberately, to keep diffing free of `set_models`' global side effects), so the
# resolution `set_models` does at runtime must be reproduced here — otherwise a
# string-declared FK, or any FK with an omitted `pk_field`, would not honor a referenced
# parent's `db_column` in the generated DDL. #65: that resolution is now single-sourced —
# both this prelude and `set_models` call `Models.resolve_fk_target!`, so the two load
# lifecycles can no longer drift. Both backends call this.
function _load_current_models(path::String)::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}
  temp_module = Module(:TemporaryModels)
  Base.include(temp_module, path)
  models_module = Base.invokelatest(getfield, temp_module, :models)
  current_models = Base.invokelatest(get_all_models, models_module)
  Base.invokelatest(_resolve_fk_targets_and_pk!, current_models, models_module)
  return current_models
end

# Resolve each code model's FK/O2O targets against `models_module` (write-back) and default a
# missing `pk_field`, by delegating each field to the shared `Models.resolve_fk_target!` (#65).
# Best-effort (strict=false): an unresolvable string target is left as-is (e.g. a cross-module
# reference whose verbatim fallback is already correct) with a `@debug`, never breaking the run.
# The runtime path's strict throw lives in `set_models`, so typos surface loudly there first.
function _resolve_fk_targets_and_pk!(current_models::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, models_module::Module)::Nothing
  for (_, entry) in current_models
    model = entry[:model]
    model isa PormGModel || continue
    for (field_name, field) in pairs(model.fields)
      (field isa Models.sForeignKey || field isa Models.sOneToOneField) || continue
      # #65: delegate to the single shared resolver. Best-effort (strict=false): an unresolvable
      # string target is left as-is with a @debug (its verbatim db-column fallback stays correct),
      # and the pk_field default is skipped — identical to the pre-#65 migration behavior.
      Models.resolve_fk_target!(field, string(field_name), model.name, models_module; strict=false)
    end
  end
  return nothing
end
