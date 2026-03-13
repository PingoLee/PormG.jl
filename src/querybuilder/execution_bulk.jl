# ---
# Execute bulk insert and update
#

# ---
# Helpers for bulk operations
#

function _normalize_bulk_columns(columns)
  _columns::Vector{Union{String, Pair{String, String}}} = []
  if columns === nothing
  elseif columns isa AbstractString
    push!(_columns, columns)
  elseif columns isa Pair{String, String}
    push!(_columns, columns)
  elseif columns isa Vector
    for column in columns
      if column isa AbstractString
        push!(_columns, column)
      elseif column isa Pair{String, String}
        push!(_columns, column)
      else
        throw(ArgumentError("Invalid column specification: $column"))
      end
    end
  else
    throw(ArgumentError("Invalid columns argument: $columns"))
  end
  return _columns
end

function _normalize_bulk_filters(filters)
  _filters::Vector{Union{String, Pair{String, <:Any}}} = []
  if filters === nothing
  elseif filters isa AbstractString
    push!(_filters, filters)
  elseif filters isa Pair{String, <:Any}
    push!(_filters, filters)
  elseif filters isa Vector
    for f in filters
      if f isa Union{String, Pair{String, <:Any}}
        push!(_filters, f)
      else
        throw(ArgumentError("Invalid filter specification: $f"))
      end
    end
  else
    throw(ArgumentError("Invalid filters argument: $filters"))
  end
  return _filters
end

function _prepare_bulk_df!(df::DataFrames.DataFrame, model::PormGModel,
                          normalized_columns::Vector, operation::Symbol,
                          settings=nothing)
  fields = model.field_names
  fields_df::Vector{String} = []
  mapping = Dict{String, String}() # model_field => df_column

  function resolve_fill_value(f_meta, operation::Symbol, settings)
    if f_meta.default !== nothing
      return true, f_meta.default
    elseif f_meta.type == "TIMESTAMPTZ"
      if operation in [:insert, :copy] && (f_meta.auto_now_add || f_meta.auto_now)
        value = settings === nothing ? now() : f_meta.formater(now(), settings.time_zone)
        return true, value
      elseif operation == :update && f_meta.auto_now
        value = settings === nothing ? now() : f_meta.formater(now(), settings.time_zone)
        return true, value
      end
    elseif f_meta.type == "DATE"
      if operation in [:insert, :copy] && (f_meta.auto_now_add || f_meta.auto_now)
        return true, today()
      elseif operation == :update && f_meta.auto_now
        return true, today()
      end
    end

    return false, nothing
  end
  
  # 1. Identify mappings and check required columns
  if !isempty(normalized_columns)
    for column in normalized_columns
      if column isa Pair
        # column.first is DF col, column.second is model field
        if !(column.first in names(df))
          @error("""Error in bulk_$operation, the column \e[4m\e[31m$(column.first)\e[0m not found in the DataFrame, the dataframe has the columns: \e[4m\e[32m$(names(df))\e[0m""")
        end
        mapping[column.second] = column.first
        push!(fields_df, column.second)
      else
        # If it's a string, try to find it in the DF
        if column in names(df)
          mapping[column] = column
          push!(fields_df, column)
        else
          # Try case-insensitive matching if not found exactly
          found = false
          for col in names(df)
            if col |> lowercase == column |> lowercase
              mapping[column] = col
              push!(fields_df, column)
              found = true
              break
            end
          end
          # If still not found, it might be an auto-populated field we add later
          if !found
            push!(fields_df, column)
          end
        end
      end
    end
  else
    # Auto-detect based on DF column names matching model fields
    for col_name in names(df)
      fld_ = col_name |> lowercase
      if fld_ in fields
        mapping[fld_] = col_name
        push!(fields_df, fld_)
      end
    end    
  end

  # 2. Defaults, auto-population and basic constraints
  pk_exist = false
  pk_field = String[]
  
  for field in fields
    f_meta = model.fields[field]
    
    if in(field, fields_df)
      if haskey(mapping, field)
        # Field exists in mapping (and DF). Check if we should fill nulls with defaults.
        col_name = mapping[field]
        should_apply_default, fill_value = resolve_fill_value(f_meta, operation, settings)

        if should_apply_default
          # Mutate the column to replace missing/nothing with default
          # We only do this if it's already there or if we really need it
          df[!, col_name] = map(x -> x |> ismissing || x |> isnothing ? fill_value : x, df[!, col_name])
        end

        # Normalize types for specific fields (e.g. IntegerField, BigInt, IDField)
        if f_meta.type in ["INTEGER", "BIGINT"]
          col_eltype = eltype(df[!, col_name])
          if !(col_eltype <: Integer || col_eltype == Union{Int64, Missing} || col_eltype == Union{Int64, Nothing, Missing})
            df[!, col_name] = map(x -> begin
              if x |> ismissing || x |> isnothing
                return x
              elseif x isa AbstractString
                return tryparse(Int64, x) # Let it stay as is if it fails, validate_field_data will catch it
              elseif x isa Float64 || x isa Float32 || x isa Float16
                if isinteger(x)
                  return Int64(x)
                else
                  # If it is not an integer (e.g. 1.5), we shouldn't force it to integer
                  return x
                end
              else
                return x
              end
            end, df[!, col_name])
          end
        elseif f_meta.type == "DOUBLE PRECISION"
          col_eltype = eltype(df[!, col_name])
          if !(col_eltype <: AbstractFloat || col_eltype == Union{Float64, Missing} || col_eltype == Union{Float64, Nothing, Missing})
            df[!, col_name] = map(x -> begin
              if x |> ismissing || x |> isnothing
                return x
              elseif x isa AbstractString
                return tryparse(Float64, x)
              elseif x isa Integer
                return Float64(x)
              else
                return x
              end
            end, df[!, col_name])
          end
        end
      else
        # Field is in fields_df (requested) but not in mapping (missing in DF)
        # Check if we can auto-populate it
        should_auto_populate, fill_value = resolve_fill_value(f_meta, operation, settings)

        if should_auto_populate
          # Add new column to DF and update mapping
          # Use first mapped column as a length reference
          ref_col = isempty(mapping) ? 1 : mapping[collect(keys(mapping))[1]]
          df[!, field] = map(x -> fill_value, df[!, ref_col])
          mapping[field] = field
        elseif f_meta.primary_key
          # It's a PK, we'll collect it later
        elseif !f_meta.null && operation in [:insert, :copy]
          throw(ArgumentError("Error in bulk_$operation, the field \e[4m\e[31m$(field)\e[0m does not allow null and has no default value"))
        end
      end

      if f_meta.primary_key
        pk_exist = true
        push!(pk_field, field)
      end
    else
      # Field not in fields_df. See if we should auto-populate it anyway (e.g. updated_at)
      should_auto_populate, fill_value = resolve_fill_value(f_meta, operation, settings)

      if should_auto_populate
        ref_col = isempty(mapping) ? 1 : mapping[collect(keys(mapping))[1]]
        df[!, field] = map(x -> fill_value, df[!, ref_col])
        mapping[field] = field
        push!(fields_df, field)
      elseif f_meta.primary_key
        push!(pk_field, field)
      end
    end
  end
  
  # Final sanity check for fields_df existence in model
  for field in fields_df
    in(field, fields) || throw("Error in bulk_$operation, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m")
  end

  # Return fields_df cleaned up (unique and existing in mapping)
  final_fields = [f for f in fields_df if haskey(mapping, f)] |> unique

  return mapping, final_fields, pk_exist, pk_field
end


"""
Inserts multiple rows into the database in bulk from a DataFrame.

  #### Arguments
  - `objct::SQLObjectHandler`: The SQL object handler to use for the operation.
  - `df_o::DataFrames.DataFrame`: The DataFrame containing the data to be inserted.
  - `columns`: Optional. Specifies the columns to insert and their mappings. Can be `nothing`, a `String`, a `Pair{String, String}`, or a `Vector` of these. If `nothing`, all columns from the DataFrame are used.
  - `chunk_size::Integer`: Optional. The number of rows to insert in each batch (default: 1000).
  - `show_query::Bool`: Optional. If true, prints the generated SQL query (default: false).
  - `copy::Bool`: Optional. If true, creates a copy of the DataFrame before processing (default: false).

  #### Examples
  ```julia
  include("models.jl")
  import models as mdl

  # Basic usage
  query = mdl.User |> object
  df = DataFrame(name=["Alice", "Bob"], age=[30, 25])
  bulk_insert(query, df)

  # With column mapping and excluding unwanted variables
  query = mdl.Boook |> object
  df = DataFrame(title=["Book A", "Book B"], author_name=["Alice", "Bob"], year=[2020, 2021], ignore_me=["x", "y"])
  # Map DataFrame column "author_name" to model field "author"
  # Exclude "ignore_me" by not including it in the columns argument
  bulk_insert(query, df, columns=["title", "year", "author_name" => "author"])
  # the df will be modified to only include the columns "title", "year", and "author_name" (renamed to "author").

  # If you want to copy the DataFrame before processing, set `copy=true`:
  bulk_insert(query, df, columns=["title", "year", "author_name" => "author"], copy=true)
    
  ```
"""
function bulk_insert(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; 
    columns = nothing, 
    chunk_size::Integer = 1000,
    show_query::Symbol = :execute,
    copy::Bool = true
  ) 
  model = objct.object.model
  ensure_model_transaction_scope(model)

  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  django_prefix = settings.django_prefix === nothing ? false : true

  

  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in bulk_insert, the connection \e[4m\e[31m$conn_key\e[0m not allowed to insert"))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_insert, the DataFrame is empty")
    return nothing
  end

  df = copy ? deepcopy(df_o) : df_o 

  # Prepare columns and DataFrame using centralized helpers
  _columns = _normalize_bulk_columns(columns)
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, _columns, :insert, settings)

  # Build a list of row value strings by applying each model field formatter.
  results = []
  insert_loop = () -> begin
    rows = String[]
    count::Integer = 0
    total::Integer = size(df, 1)
    # Security: Create parameterized query
    parameters = get_parameter(connection)
    # For INSERT, all params go into :select bucket (VALUES clause)
    set_context!(parameters, :select)
    param_placeholders::Vector{String} = String[]
    for (index, row) in enumerate(eachrow(df))
      values = String[]
      try
        # Validation checks consistent with single insert()
        for field in fields_df
          validate_field_data(model, field, row[mapping[field]], "bulk_insert"; allow_primary_key = true)
        end

        param_placeholders = [add_parameter!(parameters, model.fields[field].formater(row[mapping[field]])) for field in fields_df]
        # param_placeholders = add_parameter!(parameters, values)
      catch e
        _depuration_values_bulk_insert(fields_df, mapping, model, row, index, django_prefix)
        throw("Error in bulk_update, the row $(index) has a problem: $(e)")
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == chunk_size || index == total
        # @infiltrate
        res = _bulk_insert(model, connection, fields_df, rows, pk_exist, pk_field, settings, django_prefix, show_query, parameters)
        push!(results, res)
        count = 0
        rows = String[]
        parameters = get_parameter(connection)
        set_context!(parameters, :select)
        param_placeholders = String[]
      end
    end
  end

  if show_query !== :execute || transaction_connection_for(settings) !== nothing
    insert_loop()
  else
    run_in_transaction(insert_loop, settings)
  end

  if show_query !== :execute
    return length(results) == 1 ? results[1] : results
  end

  return nothing
  
end
bulk_insert(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_insert(model |> object, df; kwargs...)
bulk_insert(df::DataFrames.DataFrame; kwargs...) = (objct) -> bulk_insert(objct, df; kwargs...)
bulk_insert(objct::SQLObjectHandler; kwargs...) = (df) -> bulk_insert(objct, df; kwargs...)

"""
    bulk_copy(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; kwargs...)

Performs a high-speed bulk insert operation using PostgreSQL's `COPY` protocol.
This is significantly faster than `bulk_insert` for large datasets.

# Arguments
- `objct::SQLObjectHandler`: The database handler object (e.g., `M.Model`).
- `df_o::DataFrames.DataFrame`: The DataFrame containing the data to be inserted.
- `columns`: (Optional) Specifies which columns to insert. Can be a `String`, a `Pair{String, String}`, or a `Vector` of these.
- `copy::Bool = true`: If `true`, creates a copy of the DataFrame before processing.
- `show_query::Bool = false`: If `true`, prints the `COPY` command (note: data stream is not printed).

# Example
```julia
bulk_copy(M.Driver, df)
```
"""
function bulk_copy(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; 
    columns = nothing, 
    show_query::Symbol = :execute,
    copy::Bool = true
  ) 
  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  !(connection isa PormGPostgres) && throw(ArgumentError("bulk_copy is only supported for PostgreSQL. Use bulk_insert for SQLite."))

  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in bulk_copy, the connection \e[4m\e[31m$conn_key\e[0m not allowed to insert"))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_copy, the DataFrame is empty")
    return nothing
  end

  df = copy ? deepcopy(df_o) : df_o 

  # Prepare columns and DataFrame using centralized helpers
  _columns = _normalize_bulk_columns(columns)
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, _columns, :copy, settings)

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(string(model.name), connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields_df]
  
  # Construct the COPY command (using CSV format for safety)
  sql = "COPY $(safe_table_name) ($(join(quoted_fields, ", "))) FROM STDIN WITH (FORMAT CSV, HEADER FALSE)"
  
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, Symbol("bulk_copy"))
  end

  # Process in chunks
  chunk_size = 10000
  total_rows = size(df, 1)
  
  try
    for i in 1:chunk_size:total_rows
      end_idx = min(i + chunk_size - 1, total_rows)
      
      # Select columns based on mapping and ensure they are in the correct order for the COPY command
      df_chunk = df[i:end_idx, [mapping[f] for f in fields_df]]
      # Rename columns in the chunk to match model field names (for CSV writer)
      DataFrames.rename!(df_chunk, [mapping[f] => f for f in fields_df])
      
      # Use CSV to format the data safely as a block
      io = IOBuffer()
      CSV.write(io, df_chunk; header=false)
      csv_data = String(take!(io))
      
      fetch_copy(settings, sql, [csv_data])
    end
    
    # Update sequence if PK was provided
    pk_exist && _update_sequence(model, connection, pk_field, settings)
  catch e
    @error "Error in bulk_copy" exception=e sql=sql
    rethrow(e)
  end

  return nothing
  
end
bulk_copy(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_copy(model |> object, df; kwargs...)

function _depuration_values_bulk_insert(fields::Vector{String}, mapping::Dict{String, String}, model::PormGModel, row::DataFrames.DataFrameRow, index::Integer, django_prefix::Bool)
  for field in fields
    # Check if field exists in the mapping and row
    col_name = get(mapping, field, field)
    if !(col_name in names(row))
      continue
    end
    try
      model.fields[field].formater(row[col_name])
    catch e
      throw(ArgumentError("Error in bulk processing, the field \e[4m\e[31m$(field)\e[0m (col: $(col_name)) in row \e[4m\e[31m$(index)\e[0m has a value that can't be formatted: \e[4m\e[31m$(row[col_name])\e[0m"))
    end
  end  
end

function _bulk_insert(model::PormGModel, connection::Union{PormGPostgres, PormGSQLite}, 
  fields::Vector{String}, rows::Vector{String}, 
  pk_exist::Bool, pk_field::Vector{String}, settings::SQLConn, 
  django_prefix::Bool, show_query::Symbol, parameters:: AbstractPormGParam)

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(string(model.name), connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields]
  
  # Construct the bulk insert SQL.
  sql = """
  INSERT INTO $(safe_table_name) ($(join(quoted_fields, ", ")))
  VALUES $(join(rows, ", "))
  """

  # Execute the query or just show it
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :insert, parameters=parameters)
  else
    # Execute the query for the given connection type.
    if connection isa PormGPostgres
      try
        fetch(settings, sql, parameters)
      catch e
        if occursin("duplicate key value violates unique constraint", e |> string)
          _update_sequence(model, connection, pk_field, settings, ignore_tx=true)
          throw("Error in bulk_insert, the row has a duplicate key value; try again")
        elseif occursin("violates foreign key constraint", e |> string)
          throw("Error in bulk_insert, the row has a foreign key constraint")
        else
          throw(e)
        end
      end
    elseif connection isa PormGSQLite
      # Use fetch() to properly acquire/release a connection from the pool
      # and pass the parameterized query with correct bucket ordering
      fetch(settings, sql, parameters)
    else
      throw("Unsupported connection type")
    end

    pk_exist && _update_sequence(model, connection, pk_field, settings)
  end
end


"""
Performs a bulk update operation on a database table using the provided `DataFrame` and a query object.

# Arguments
- `objct::SQLObjectHandler`: The database handler object.
- `df::DataFrames.DataFrame`: The DataFrame containing the data to be used for the update.
- `columns`: (Optional) Specifies which columns to update. Can be a `String`, a `Pair{String, String}`, or a `Vector` of these. If `nothing`, no columns are specified.
- `filters`: (Optional) Specifies the filters to apply for the update. Can be a `String`, a `Pair{String, T}` where `T` is `String`, `Integer`, `Bool`, `Date`, or `DateTime`, or a `Vector` of these. If `nothing`, no filters are applied.
- `show_query::Bool`: (Optional) If `true`, prints the generated SQL query. Defaults to `false`.
- `chunk_size::Integer`: (Optional) Number of rows to process per chunk. Defaults to `1000`.
- `copy::Bool`: (Optional) If `true`, creates a copy of the DataFrame before processing. Defaults to `true`. Set to `false` to modify the original DataFrame and improve performance, but this may lead to unintended side effects when the operation is performed in asynchronous contexts.

# Example
```julia
# Update the columns of the DataFrame df if df contains the primary key of the table
bulk_update(objct, df)
# Update the name and dof columns for the security_id in the DataFrame df
bulk_update(objct, df, columns=["security_id", "name", "dof"], filters=["security_id"])
```
"""
function bulk_update(objct::SQLObjectHandler, df::DataFrames.DataFrame; 
    columns=nothing, 
    filters=nothing, 
    show_query::Symbol=:execute, 
    chunk_size::Integer=1000,
    copy::Bool=true)

  _columns = _normalize_bulk_columns(columns)
  _filters = _normalize_bulk_filters(filters)

  _bulk_update(objct, df, _columns, _filters, show_query, chunk_size, copy)
  
end
bulk_update(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_update(model |> object, df; kwargs...)
bulk_update(df::DataFrames.DataFrame; kwargs...) = (objct) -> bulk_update(objct, df; kwargs...)
bulk_update(objct::SQLObjectHandler; kwargs...) = (df) -> bulk_update(objct, df; kwargs...)

function _bulk_update(objct::SQLObjectHandler, df_o::DataFrames.DataFrame,
  columns::Vector{Union{String, Pair{String, String}}},
  filters::Vector{Union{String, Pair{String, <:Any}}},
  show_query::Symbol,
  chunk_size::Integer=1000,
  copy::Bool=true)

  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  # check if is allowed to insert
  !settings.change_data && throw(ArgumentError("Error in bulk_update, the connection \e[4m\e[31m$conn_key\e[0m not allowed to update"))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_update, the DataFrame is empty")
    return nothing
  end

  df = copy ? deepcopy(df_o) : df_o 

  # Prepare columns and DataFrame using centralized helpers
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, columns, :update, settings)

  # colect the filters
  pks = [field for field in keys(model.fields) if model.fields[field].primary_key]
  dinanic_filters::Vector{String} = []
  static_filters::Vector{Pair{String, Any}} = []
  if !isempty(filters)
    for filter in filters
      if filter isa Pair && filter.second isa String && filter.first in names(df) && filter.second in model.field_names
        # Dynamic filter with mapping: df_col => table_field
        push!(dinanic_filters, filter.second)
        mapping[filter.second] = filter.first
        push!(fields_df, filter.second)
      elseif filter isa Pair
        # Static filter: table_field => value
        push!(static_filters, filter)
      else
        push!(dinanic_filters, filter)
        if !(filter in fields_df)
          # Ensure filter column is mapped even if not in update 'columns'
          if filter in names(df)
            mapping[filter] = filter
            push!(fields_df, filter)
          else
            # Try case-insensitive matching for filters too
            found = false
            for col in names(df)
              if col |> lowercase == filter |> lowercase
                mapping[filter] = col
                push!(fields_df, filter)
                found = true
                break
              end
            end
            found || throw(ArgumentError("Filter column '$(filter)' not found in DataFrame"))
          end
        end
      end
    end
  else
    dinanic_filters = pks    
    # Ensure all PKs are in the mapping
    for pk in pks
        if !haskey(mapping, pk)
            found = false
            for col in names(df)
                if col |> lowercase == pk |> lowercase
                    mapping[pk] = col
                    push!(fields_df, pk)
                    found = true
                    break
                end
            end
            found || throw(ArgumentError("Primary key column '$(pk)' required for bulk_update not found in DataFrame"))
        end
    end
  end  

  objct.object.filter = [] # clear the filters
  if size(static_filters, 1) > 0
    for filter in static_filters
      objct.filter(filter)
    end    
  end
  instruction = build(objct.object, connection=connection) 

  # Build a list of row value strings by applying each model field formatter.
  rows = String[]
  # deny_fields = vcat(pks, dinanic_filters, [filter.first for filter in static_filters]) |> unique # colect all keys that are not allowed/need to update
  deny_fields = vcat(dinanic_filters, [filter.first for filter in static_filters]) |> unique # colect all keys that are not allowed/need to update
  # set_columns = join([ "$(field) = source.$(field)::$(model.fields[field].type |> lowercase)" for field in fields_df if !(field in deny_fields) ], ", ")

  # Security: Build safe SET clause with quoted identifiers
  safe_set_parts = []
  for field in fields_df
    if !(field in deny_fields)
      # @infiltrate
      quoted_field = quote_identifier(field, connection)
      quoted_source_field = quote_identifier(field, connection)
      field_type = model.fields[field].type |> lowercase
      if connection isa PormGPostgres
        push!(safe_set_parts, "$quoted_field = source.$quoted_source_field::$field_type")
      else
        push!(safe_set_parts, "$quoted_field = source.$quoted_source_field")
      end
    end
  end
  safe_set_clause = join(safe_set_parts, ", ")

  # Security: Create parameterized query
  parameters_initial =  deepcopy(instruction.parameters)
  joined_columns = unique(vcat(fields_df, dinanic_filters))

  results = []
  update_loop = () -> begin
    count::Integer = 0
    total::Integer = size(df, 1)
    rows = String[]
    # For bulk update VALUES, use :select context
    set_context!(instruction.parameters, :select)
    param_placeholders::Vector{String} = String[]
    for (index, row) in enumerate(eachrow(df))
      try
        # Validation checks consistent with single update()
        for field in fields_df
            # Skip fields used as filters or primary keys (they aren't being updated)
            field in deny_fields && continue
            
            # Centralized validation using mapping
            validate_field_data(model, field, row[mapping[field]], "bulk_update"; allow_primary_key = false)
        end

        param_placeholders = [add_parameter!(instruction.parameters, model.fields[field].formater(row[mapping[field]])) for field in joined_columns]
      catch e
        _depuration_values_bulk_insert(fields_df, mapping, model, row, index, settings.django_prefix !== nothing)
        rethrow(e)
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == chunk_size || index == total      
        res = _bulk_update(model, settings, connection, joined_columns, rows, safe_set_clause, dinanic_filters, show_query, instruction)
        push!(results, res)
        count = 0
        rows = String[]
        instruction.parameters = deepcopy(parameters_initial) # reset parameters to initial state
        set_context!(instruction.parameters, :select) # restore context for next chunk
        param_placeholders = String[]
      end
    end
  end

  has_active_tx = transaction_connection_for(settings) !== nothing
  if show_query !== :execute || !(connection isa PormGPostgres) || has_active_tx
    update_loop()
  else
    run_in_transaction(update_loop, settings)
  end

  if show_query !== :execute
    return length(results) == 1 ? results[1] : results
  end

  return nothing
  
end

function _bulk_update(model::PormGModel,
  settings::SQLConn,
  connection::Union{PormGPostgres, PormGSQLite}, 
  fields::Vector{String}, 
  rows::Vector{String}, 
  safe_set_clause::String, 
  dinanic_filters::Vector{String}, 
  show_query::Symbol,
  instruction::Union{SQLInstruction, Nothing})

  @infiltrate false
  if instruction !== nothing && instruction.join |> length > 0
    throw("Error in bulk_update, the join is not allowed in bulk_update")
  end

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(model.name, connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields]

  # Security: Build safe WHERE conditions with quoted identifiers
  safe_where_conditions::Vector{String} = []
  for filter in dinanic_filters
    quoted_tb_field = quote_identifier(filter, connection)
    quoted_source_field = quote_identifier(filter, connection)
    field_type = model.fields[filter].type |> lowercase
    if connection isa PormGPostgres
      push!(safe_where_conditions, "\"Tb\".$quoted_tb_field = source.$quoted_source_field::$field_type")
    else
      push!(safe_where_conditions, "\"Tb\".$quoted_tb_field = source.$quoted_source_field")
    end
  end
  # # Construct the bulk update SQL.
  # _where::Vector{String} = []
  # for filter in dinanic_filters
  #   push!(_where, "Tb.$(filter) = source.$(filter)::$(model.fields[filter].type |> lowercase)")
  # end
  if instruction !== nothing    
    for filter in instruction._where
      push!(safe_where_conditions, filter)
    end
  end

  if connection isa PormGPostgres
    sql = """
    UPDATE $safe_table_name AS "Tb"
    SET $(safe_set_clause)
    FROM (VALUES $(join([join(split(row, ", "), ", ") for row in rows], ","))) AS source ($(join(quoted_fields, ",")))
    WHERE $(join(safe_where_conditions, " AND \n   "))
    """
  else # SQLite
    # SQLite 3.33+ supports UPDATE FROM. We use a CTE to define the source clearly.
    sql = """
    WITH source($(join(quoted_fields, ", "))) AS (
      VALUES $(join(rows, ", "))
    )
    UPDATE $safe_table_name
    SET $(safe_set_clause)
    FROM source
    WHERE $(join(replace.(safe_where_conditions, "\"Tb\"." => "$safe_table_name."), " AND "))
    """
  end

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :update, parameters=instruction.parameters)
  else 
    # Execute the query for the given connection type.
    fetch(connection, sql, instruction.parameters)
  end  
end