# ---
# Execute bulk insert and update
#

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
    show_query::Bool = false,
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

  # Process columns argument
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

  # colect name of the fields
  fields = model.field_names
  fields_df::Vector{String} = []
  if !isempty(_columns)   
    if length(_columns) > 0
      for column in _columns
        if column isa Pair
          if !(column.first in df |> names)
            @error("""Error in bulk_insert, the column \e[4m\e[31m$(column.first)\e[0m not found in the DataFrame, the dataframe has the columns: \e[4m\e[32m$(names(df))\e[0m""")
          end
          if column.second in df |> names
            DataFrames.select!(df, DataFrames.Not(column.second |> Symbol))
          end
          DataFrames.rename!(df, column.first => column.second)
          push!(fields_df, column.second)
        else
          push!(fields_df, column)
        end
      end
    end
  else
    for field in names(df)
      fld_ = field |> lowercase
      if fld_ in fields
        push!(fields_df, fld_)
      end
      if fld_ != field
        DataFrames.rename!(df, field => fld_)
      end
    end    
  end  

  # check if missing fields in fields_df are not null or dont have a default value
  pk_exist::Bool = false
  pk_field::Vector{String} = []
  @infiltrate false
  for field in fields
    if in(field, fields_df)
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif !model.fields[field].null
        if any(ismissing, df[!, field]) || any(isnothing, df[!, field])
          throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))
        end
      elseif model.fields[field].primary_key
        pk_exist = true
      end
    else
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> model.fields[field].default, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].primary_key
        @infiltrate false
        push!(pk_field, field)
        continue
      elseif !model.fields[field].null
        throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))      
      end
    end   
  end 

  @infiltrate false
  
  # check if the fields_df are not in fields
  for field in fields_df
    in(field, fields) || throw("""Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m""")
  end
   
  # Build a list of row value strings by applying each model field formatter.
  insert_loop = () -> begin
    rows = String[]
    count::Integer = 0
    total::Integer = size(df, 1)
    # Security: Create parameterized query
    parameters = get_parameter(connection)
    param_placeholders::Vector{String} = String[]
    for (index, row) in enumerate(eachrow(df))
      values = String[]
      try
        param_placeholders = [add_parameter!(parameters, model.fields[field].formater(row[field])) for field in fields_df]
        # param_placeholders = add_parameter!(parameters, values)
      catch e
        @infiltrate false
        _depuration_values_bulk_insert(fields_df, model, row, index, django_prefix)
        throw("Error in bulk_update, the row $(index) has a problem: $(e)")
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == chunk_size || index == total
        # @infiltrate
        _bulk_insert(model, connection, fields_df, rows, pk_exist, pk_field, settings, django_prefix, show_query, parameters)
        count = 0
        rows = String[]
        parameters = get_parameter(connection)
        param_placeholders = String[]
      end
    end
  end

  if show_query || !(connection isa PormGPostgres) || transaction_connection_for(settings) !== nothing
    insert_loop()
  else
    run_in_transaction(insert_loop, settings)
  end

  return nothing
  
end
bulk_insert(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_insert(model |> object, df; kwargs...)

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
    show_query::Bool = false,
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

  # Process columns argument
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

  # colect name of the fields
  fields = model.field_names
  fields_df::Vector{String} = []
  if !isempty(_columns)   
    if length(_columns) > 0
      for column in _columns
        if column isa Pair
          if !(column.first in df |> names)
            @error("""Error in bulk_copy, the column \e[4m\e[31m$(column.first)\e[0m not found in the DataFrame, the dataframe has the columns: \e[4m\e[32m$(names(df))\e[0m""")
          end
          if column.second in df |> names
            DataFrames.select!(df, DataFrames.Not(column.second |> Symbol))
          end
          DataFrames.rename!(df, column.first => column.second)
          push!(fields_df, column.second)
        else
          push!(fields_df, column)
        end
      end
    end
  else
    for field in names(df)
      fld_ = field |> lowercase
      if fld_ in fields
        push!(fields_df, fld_)
      end
      if fld_ != field
        DataFrames.rename!(df, field => fld_)
      end
    end    
  end  

  # check if missing fields in fields_df are not null or dont have a default value
  pk_exist::Bool = false
  pk_field::Vector{String} = []
  for field in fields
    if in(field, fields_df)
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, field])
      elseif !model.fields[field].null
        if any(ismissing, df[!, field]) || any(isnothing, df[!, field])
          throw(ArgumentError("Error in bulk_copy, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))
        end
      elseif model.fields[field].primary_key
        pk_exist = true
      end
    else
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> model.fields[field].default, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        df[!, field] = map(x -> x |> ismissing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].primary_key
        push!(pk_field, field)
        continue
      elseif !model.fields[field].null
        throw(ArgumentError("Error in bulk_copy, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))      
      end
    end   
  end 

  # check if the fields_df are not in fields
  for field in fields_df
    in(field, fields) || throw("""Error in bulk_copy, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m""")
  end

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(string(model.name), connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields_df]
  
  # Construct the COPY command (using CSV format for safety)
  sql = "COPY $(safe_table_name) ($(join(quoted_fields, ", "))) FROM STDIN WITH (FORMAT CSV, HEADER FALSE)"
  
  if show_query
    @info "SQL Query (COPY)" query=sql task_id=string(current_task())
  end

  # Process in chunks
  chunk_size = 10000
  total_rows = size(df, 1)
  
  try
    for i in 1:chunk_size:total_rows
      end_idx = min(i + chunk_size - 1, total_rows)
      df_chunk = df[i:end_idx, fields_df]
      
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

function _depuration_values_bulk_insert(fields::Vector{String}, model::PormGModel, row::DataFrames.DataFrameRow, index::Integer, django_prefix::Bool)
  for field in fields
    # Check if field exists in the row before trying to format it
    if !(field in names(row))
      return nothing
    end
    try
      model.fields[field].formater(row[field])
    catch e
      throw(ArgumentError("Error in bulk_insert, the field \e[4m\e[31m$(field)\e[0m in row \e[4m\e[31m$(index)\e[0m has a value that can't be formatted: \e[4m\e[31m$(row[field])\e[0m"))
    end
  end  
end

function _bulk_insert(model::PormGModel, connection::PormGPostgres, 
  fields::Vector{String}, rows::Vector{String}, 
  pk_exist::Bool, pk_field::Vector{String}, settings::SQLConn, 
  django_prefix::Bool, show_query::Bool, parameters:: PormGPostgresParam)

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(string(model.name), connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields]
  
  # Construct the bulk insert SQL.
  sql = """
  INSERT INTO $(safe_table_name) ($(join(quoted_fields, ", ")))
  VALUES $(join(rows, ", "))
  """

  # Execute the query or just show it
  if show_query
    params_list = (parameters === nothing) ? [] : (hasproperty(parameters, :parameters) ? parameters.parameters : parameters)
    @info "SQL Query" query=sql params=params_list |> string task_id=string(current_task())
  else
    # Execute the query for the given connection type.
    if connection isa PormGPostgres
      try
        fetch(settings, sql, parameters)
      catch e
        @infiltrate false
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
      SQLite.execute(connection, sql)
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
    columns=nothing, # what columns to update
    filters=nothing, # what columns to do the filter
    show_query::Bool=false, 
    chunk_size::Integer=1000,
    copy::Bool=true)

  _columns::Vector{Union{String, Pair{String, String}}} = []
  _filters::Vector{Union{String, Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}}} = []
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
        throw("Error in bulk_update, the columns must be a String or a Pair{String, String}")
      end
    end
  else
    throw("Error in bulk_update, the columns must be a String or a Pair{String, String}")
  end

  if filters === nothing
  elseif filters isa AbstractString
    push!(_filters, filters)
  elseif filter isa Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}
    push!(_filters, filters)
  elseif filters isa Vector
    for filter in filters
      if filter isa AbstractString
        push!(_filters, filter)
      elseif filter isa Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}
        push!(_filters, filter)
      else
        throw("Error in bulk_update, the filters must be a String or a Pair{String, T} where T<:Union{String, NumIntegerber, Bool, Date, DateTime}")
      end
    end
  else
    throw("Error in bulk_update, the filters must be a String or a Pair{String, T} where T<:Union{String, Integer, Bool, Date, DateTime}")
  end

  _bulk_update(objct, df, _columns, _filters, show_query, chunk_size, copy)
  
end
bulk_update(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_update(model |> object, df; kwargs...)

function _bulk_update(objct::SQLObjectHandler, df_o::DataFrames.DataFrame,
  columns::Vector{Union{String, Pair{String, String}}},
  filters::Vector{Union{String, Pair{String, <:Union{String, Integer, Bool, Date, DateTime}}}},
  show_query::Bool,
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

  # colect name of the fields
  fields = model.field_names
  fields_df::Vector{String} = []
  if !isempty(columns)   
    if length(columns) > 0
      for column in columns
        if column isa Pair
          if !(column.first in df |> names)
            @error("""Error in bulk_update, the column \e[4m\e[31m$(column.first)\e[0m not found in the DataFrame, the dataframe has the columns: \e[4m\e[32m$(names(df))\e[0m""")
          end
          if column.second in df |> names
            DataFrames.select!(df, DataFrames.Not(column.second |> Symbol))
          end
          DataFrames.rename!(df, column.first => column.second)
          push!(fields_df, column.second)
        else
          push!(fields_df, column)
        end
      end
    end
  else
    for field in names(df)
      fld_ = field |> lowercase
      if fld_ in fields
        push!(fields_df, fld_)
      end
      if fld_ != field
        DataFrames.rename!(df, field => fld_)
      end
    end    
  end  

  # check if missing fields in fields_df are updated automatically
  pk_exist::Bool = false
  pk_field::Vector{String} = []
  for field in fields
    if in(field, fields_df)
      if model.fields[field].default !== nothing
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "TIMESTAMPTZ" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, field])
      elseif model.fields[field].type == "DATE" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, field])
      elseif !model.fields[field].null
        if any(ismissing, df[!, field]) || any(isnothing, df[!, field])
          throw(ArgumentError("Error in bulk_update, the field \e[4m\e[31m$(field)\e[0m not allow null but contains missing/nothing values"))
        end
      elseif model.fields[field].primary_key
        pk_exist = true
        push!(pk_field, field)
      end
    else
      if model.fields[field].type == "TIMESTAMPTZ" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)
      elseif model.fields[field].type == "DATE" && model.fields[field].auto_now
        df[!, field] = map(x -> x |> ismissing || x |> isnothing ? model.fields[field].default : x, df[!, fields_df[1]])
        push!(fields_df, field)     
      end
    end   
  end  

  # colect the filters
  pks = [field for field in keys(model.fields) if model.fields[field].primary_key]
  dinanic_filters::Vector{String} = []
  static_filters::Vector{Pair{String, Any}} = []
  if !isempty(filters)
    for filter in filters
      if filter isa Pair
        push!(static_filters, filter)
      else
        push!(dinanic_filters, filter)
        filter in fields_df || push!(fields_df, filter)
      end
    end
  else
    dinanic_filters = pks    
  end  

  objct.object.filter = [] # clear the filters
  if size(static_filters, 1) > 0
    for filter in static_filters
      objct.filter(filter)
    end    
  end
  instruction = build(objct.object, connection=connection) 

  @infiltrate false

  # check if the fields_df are not in fields
  for field in fields_df
    in(field, fields) || @error("""Error in bulk_update, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m""")
  end

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
      push!(safe_set_parts, "$quoted_field = source.$quoted_source_field::$field_type")
    end
  end
  safe_set_clause = join(safe_set_parts, ", ")

  @infiltrate false
  # Security: Create parameterized query
  parameters_initial =  deepcopy(instruction.parameters)
  joined_columns = unique(vcat(fields_df, dinanic_filters))

  update_loop = () -> begin
    count::Integer = 0
    total::Integer = size(df, 1)
    rows = String[]
    param_placeholders::Vector{String} = String[]
    for (index, row) in enumerate(eachrow(df))
      try
        param_placeholders = [add_parameter!(instruction.parameters, model.fields[field].formater(row[field])) for field in joined_columns]
      catch e
        _depuration_values_bulk_insert(fields_df, model, row, index, settings.django_prefix !== nothing)
        throw("Error in bulk_update, the row $(index) has a problem: $(e)")
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == chunk_size || index == total      
        _bulk_update(model, settings, connection, joined_columns, rows, safe_set_clause, dinanic_filters, show_query, instruction)
        count = 0
        rows = String[]
        instruction.parameters = deepcopy(parameters_initial) # reset parameters to initial state
        param_placeholders = String[]
      end
    end
  end

  has_active_tx = transaction_connection_for(settings) !== nothing
  if show_query || !(connection isa PormGPostgres) || has_active_tx
    update_loop()
  else
    run_in_transaction(update_loop, settings)
  end

  return nothing
  
end

function _bulk_update(model::PormGModel,
  settings::SQLConn,
  connection::PormGPostgres, 
  fields::Vector{String}, 
  rows::Vector{String}, 
  safe_set_clause::String, 
  dinanic_filters::Vector{String}, 
  show_query::Bool,
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
    push!(safe_where_conditions, "\"Tb\".$quoted_tb_field = source.$quoted_source_field::$field_type")
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

  sql = """
  UPDATE $safe_table_name AS "Tb"
  SET $(safe_set_clause)
  FROM (VALUES $(join([join(split(row, ", "), ", ") for row in rows], ","))) AS source ($(join(quoted_fields, ",")))
  WHERE $(join(safe_where_conditions, " AND \n   "))
  """

  @infiltrate false

  if show_query 
    params_list = instruction !== nothing && instruction.parameters !== nothing && hasproperty(instruction.parameters, :parameters) ? instruction.parameters.parameters : []
    @info "SQL Query" query=sql params=params_list |> string task_id=string(current_task())
  else 
    # Execute the query for the given connection type.
    # @infiltrate false
    fetch(connection, sql, instruction.parameters)
  end  
end