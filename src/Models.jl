# I want recreate the Django models in Julia
module Models
using Dates
using TimeZones
using PormG: PormGField, PormGModel, reserved_words

export Model, Model_to_str, CharField, IntegerField, ForeignKey, BigIntegerField, BooleanField, DateField, DateTimeField, DecimalField, EmailField, FloatField, ImageField, TextField, TimeField, IDField, BigIntegerField

@kwdef mutable struct Model_Type <: PormGModel
  name::AbstractString
  verbose_name::Union{String, Nothing} = nothing
  fields::Dict{String, PormGField}
  field_names::Vector{String} = [] # needed to create sql queries with joins
  reverse_fields::Dict{String, Tuple{Symbol, Symbol, Symbol, Symbol}} = Dict{String, Tuple{Symbol, Symbol, Symbol, Symbol}}() # needed to create sql queries with joins
  _module::Union{Module, Nothing} = nothing # needed to create sql queries with joins
end

"""
Returns a vector containing all the models defined in the given module.

# Arguments
    get_all_models(modules::Module; symbol::Bool=false)::Vector{Union{Symbol, PormGModel}}
- `modules::Module`: The module to search for models.
- `symbol::Bool=false`: If `true`, returns the model names as symbols. If `false`, returns the model instances.

# Returns
A vector containing all the models defined in the module.
"""
function get_all_models(modules::Module; symbol::Bool=false)::Vector{Union{Symbol, PormGModel}}
  model_names = []
  for name in names(modules; all=true, imported=true)
    # Check if the attribute is an instance of Model_Type
    attr = getfield(modules, name)
    if isa(attr, PormGModel)
        push!(model_names, symbol ? name : attr)
    end
  end
  return model_names
end

function get_model_pk_field(model::PormGModel)::Union{Symbol, Nothing}
  fields::Vector{Symbol} = []
  for (field_name, field) in pairs(model.fields)
    if field.primary_key
      push!(fields, field_name |> Symbol)
    end
  end
  if length(fields) == 1
    return fields[1]
  elseif length(fields) == 0
    return nothing  
  else
    throw(ArgumentError("The model $(model.name) has more than one primary key field: $(join(fields, ", "))"))
  end
end

# TODO add related_name (like django validation) to check if the field is a ForeignKey and the related_name model is defined when models has more than one foreign key to the same model
function set_models(_module::Module)::Nothing
  models = get_all_models(_module)
  # set the original module in models
  for model in models
    model._module = _module
  end
  # Validate like django related_name, if the model has more than one foreign key to the same model the related_name must be defined
  for model in models
    dict_tables_c = Dict{String, Int}()
    dict_tables_fiels = Dict{String, Vector{String}}()
    reverse_fields = Dict{String, Tuple{Symbol, Symbol, Symbol}}()
    println(model.name)
    for (field_name, field) in pairs(model.fields)
      if field isa sForeignKey
        field_to = getfield(_module, field.to |> Symbol)
        if field_to isa PormGModel
          println("field_to_", field_to.name)
          if haskey(dict_tables_c, field_to.name)
            dict_tables_c[field_to.name] += 1
            push!(dict_tables_fiels[field_to.name], field_name)
          else
            dict_tables_c[field_to.name] = 1
            dict_tables_fiels[field_to.name] = [field_name]
          end
          if dict_tables_c[field_to.name] > 1
            if field.related_name === nothing 
              throw(ArgumentError("The field $field_name in the model $model is a ForeignKey and the related_name is not defined"))
            elseif haskey(field_to.reverse_fields, field.related_name)
              throw(ArgumentError("The related_name $field.related_name in the model $model is already defined"))
            else
              field_to.reverse_fields[field.related_name] = (field_name |> Symbol, field.pk_field |> Symbol, model.name |> Symbol, get_model_pk_field(model) |> Symbol)
            end
          elseif dict_tables_c[field_to.name] == 1
            if field.related_name === nothing
              field_to.reverse_fields[model.name] = (field_name |> Symbol, field.pk_field |> Symbol, model.name |> Symbol, get_model_pk_field(model) |> Symbol)
            else
              if haskey(field_to.reverse_fields, field.related_name)
                throw(ArgumentError("The related_name $field.related_name in the model $model is already defined"))
              else
                field_to.reverse_fields[field.related_name] = (field_name |> Symbol, field.pk_field |> Symbol, model.name |> Symbol, get_model_pk_field(model) |> Symbol)
              end
            end
          end        
        end 
      end
    end
  end
 
  return nothing
end

function get_all_fields(obj)
  fields = fieldnames(typeof(obj))
  field_values = Dict{Symbol, Any}()
  for field in fields
      field_values[field] = getfield(obj, field)
  end
  return field_values
end

function format_fild_name(name::String)::String
  name[1] == '_' && (name = name[2:end])    
  return name
end

# Constructor a function that adds a field to the model the number of fields is not limited to the number of fields, the fields are added to the fields dictionary but the name of the field is the key
function Model(name::AbstractString; fields...) 
  fields_dict::Dict{String, PormGField} = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    field_name = field_name |> String |> format_fild_name
    if !(field isa PormGField)
      throw(ArgumentError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field
    push!(field_names, field_name)
  end
  # println(fields_dict)
  return Model_Type(name=name, fields=fields_dict, field_names=field_names)
end
function Model(name::AbstractString, dict::Dict{Symbol, PormGField})
  field_names::Vector{String} = []
  for (field_name, field) in pairs(dict)    
    push!(field_names, field_name)
  end
  return Model_Type(name=name, fields=dict, field_names=field_names)
end
function Model(name::AbstractString, fields::Dict{Symbol, Any})
  fields_dict = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    field_name = field_name |> String |> format_fild_name
    if !(field isa PormGField)
      throw(ArgumentError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field
    push!(field_names, field_name)
  end
  return Model_Type(name=name, fields=fields_dict, field_names=field_names)
end
function Model(name::String)
  example_usage = "\e[32musers = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())\e[0m"
  throw(ArgumentError("You need to add fields to the model, example: $example_usage"))
end
function Model()
  example_usage = "\e[32musers = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())\e[0m"
  throw(ArgumentError("You need to add a name and fields to the model, example: $example_usage"))
end

"""
Converts a model object to a string representation to create the model.

# Arguments
    Model_to_str(model::Union{Model_Type, PormGModel}; contants_julia::Vector{String}=reserved_words)::String
- `model::Union{Model_Type, PormGModel}`: The model object to convert.
- `contants_julia::Vector{String}=reserved_words`: A vector of reserved words in Julia.

# Returns
- `String`: The string representation of the model object.

# Examples
```julia
users = Models.Model("users", 
  name = Models.CharField(), 
  email = Models.CharField(), 
  age = Models.IntegerField()
)
```
"""
function Model_to_str(model::Union{Model_Type, PormGModel}; contants_julia::Vector{String}=reserved_words)::String
  fields::String = ""
  for (field_name, field) in pairs(model.fields) |> sort
    occursin(r"__|@|^_", field_name) && throw(ArgumentError("The field name $field_name in the model $model contains __ or @ or starts with _"))
    field_name in contants_julia && (field_name = "_$field_name")
    struct_name::Symbol = nameof(typeof(field)) |> string |> x -> x[2:end] |> Symbol    
    sets::Vector{String} = []
    fields = struct_name == :ForeignKey ? _model_to_str_foreign_key(field_name, field, struct_name, sets, fields) : _model_to_str_general(field_name, field, struct_name, sets, fields)
  end
  @info("""$(model.name) = Models.Model("$(model.name)"$fields)""")

  return """$(model.name) = Models.Model("$(model.name)"$fields)"""
end
function _model_to_str_general(field_name, field, struct_name, sets, fields)
  stadard_field = getfield(@__MODULE__, struct_name)()
  for sfield in fieldnames(typeof(field))
    if getfield(field, sfield) != getfield(stadard_field, sfield)
      push!(sets, """$sfield=$(getfield(field, sfield) |> format_string)""")
    end
  end
  if struct_name == :IDField
    fields = ",\n  $field_name = Models.$struct_name($(join(sets, ", ")))" * fields
  else 
    fields *= ",\n  $field_name = Models.$struct_name($(join(sets, ", ")))"
  end
  return fields
end
function _model_to_str_foreign_key(field_name, field, struct_name, sets, fields)
  to::String = "" 
  for sfield in fieldnames(typeof(field))
    sfield == :to && (to = getfield(field, sfield); continue)
    if getfield(field, sfield) != getfield(ForeignKey(""), sfield)
      push!(sets, """$sfield=$(getfield(field, sfield) |> format_string)""")
    end
  end
  fields *= ",\n  $field_name = Models.$struct_name(\"$to\", $(join(sets, ", ")))"
  return fields
  
end

# function map_field_to_sql_type(db::SQLite.DB, field::PormGField)
#   # properties
#   # verbose_name::Union{String, Nothing} = nothing
#   # name::Union{String, Nothing} = nothing
#   # primary_key::Bool = false
#   # max_length::Int = 250
#   # unique::Bool = false
#   # blank::Bool = false
#   # null::Bool = false
#   # db_index::Bool = false
#   # default::Union{String, Nothing} = nothing
#   # editable::Bool = false
#   sql_type = ""
#   # Check if the field is a CharField and not a primary key
#   if field isa sCharField && !field.primary_key
#     # Check the max_length attribute of the field
#     if hasproperty(field, :max_length) && field.max_length <= 255
#       # If max_length is defined and less than or equal to 255, use VARCHAR
#       sql_type = "VARCHAR($(field.max_length))"
#     else
#       # If max_length is not defined or greater than 255, default to TEXT
#       sql_type = "TEXT"
#     end
#   elseif field.primary_key
#     # Handle primary key case, assuming it's an integer
#     sql_type = "INTEGER PRIMARY KEY AUTOINCREMENT"
#   end
#   # Add more conditions for other field types and attributes as needed

#   # Check if the field is nullable
#   if hasproperty(field, :null) && !field.null
#     sql_type *= " NULL"
#   else
#     sql_type *= " NOT NULL"
#   end

#   return sql_type
# end

#
# Formaters
#

function format_text_sql(value::Union{Int, Date, DateTime, ZonedDateTime})
    return string("'", value, "'")        
end
function format_text_sql(value::Union{Missing, Nothing})
    return "null"
end
function format_text_sql(value::Bool)
    return value ? "true" : "false"
end
function format_text_sql(value::AbstractString)
    return string("'", replace(value, "'" => "`"), "'")    
end

function format_number_sql(value::Integer)
    return string(value)    
end
function format_number_sql(value::Union{Missing, Nothing})
    return "null"
end
function format_number_sql(value::Union{Float16, Float32, Float64})
    return string("'", value, "'")    
end
function format_number_sql(value::AbstractString)
    return parse(Float64, value) |> string   
end

function format_bool_sql(value::Integer)
    if value in [0, 1] == false
        throw(ArgumentError("The value must be 0, 1, true or false"))
    end
    return value == 1 ? "true" : "false"
end
function format_bool_sql(value::Union{Missing, Nothing})
    return "null"
end
function format_bool_sql(value::Bool)
    return value ? "true" : "false"
end

@kwdef mutable struct SIDField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = true
  auto_increment::Bool = true
  unique::Bool = true
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Int64, Nothing} = nothing
  editable::Bool = false
  type::String = "INTEGER"
  formater::Function = format_number_sql
end

function IDField(; verbose_name=nothing, name=nothing, primary_key=true, auto_increment=true, unique=true, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return SIDField(verbose_name=verbose_name, name=name, primary_key=primary_key, auto_increment=auto_increment, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end


@kwdef mutable struct sCharField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  max_length::Int = 250
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "VARCHAR"
  formater::Function = format_text_sql
end

function CharField(; verbose_name=nothing, name=nothing, max_length=250, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sCharField(verbose_name=verbose_name, name=name, max_length=max_length, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sIntegerField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Int64, Nothing} = nothing
  editable::Bool = false
  type::String = "INTEGER"
  formater::Function = format_number_sql
end

function IntegerField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  default = validate_default(default, Union{Int64, Nothing}, "IntegerField", format2int64)
  return sIntegerField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sBigIntegerField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Int64, Nothing} = nothing
  editable::Bool = false
  type::String = "BIGINT"
  formater::Function = format_number_sql
end

function BigIntegerField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sBigIntegerField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sForeignKey <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Int64, Nothing} = nothing
  editable::Bool = false
  to::Union{String, PormGModel, Nothing} = nothing
  pk_field::Union{String, Symbol, Nothing} = nothing
  on_delete::Union{String, Nothing} = nothing
  on_update::Union{String, Nothing} = nothing
  deferrable::Bool = false
  how::Union{String, Nothing} = nothing # INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN used in _build_row_join
  related_name::Union{String, Nothing} = nothing
  type::String = "BIGINT"
  formater::Function = format_number_sql
end

function ForeignKey(to::Union{String, PormGModel}; verbose_name=nothing, name=nothing, primary_key=false, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false, pk_field=nothing, on_delete=nothing, on_update=nothing, deferrable=false, how=nothing, related_name=nothing)
  # TODO: validate the to parameter how, on_delete, on_update and others
  return sForeignKey(verbose_name=verbose_name, name=name, primary_key=primary_key, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable, to=to, pk_field=pk_field, on_delete=on_delete, on_update=on_update, deferrable=deferrable, how=how, related_name=related_name)  
end
@kwdef mutable struct sBooleanField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Bool, Nothing} = nothing
  editable::Bool = false
  type::String = "BOOLEAN"
  formater::Function = format_bool_sql
end

function BooleanField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sBooleanField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sDateField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "DATE"
  formater::Function = format_text_sql
end

function DateField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sDateField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end


@kwdef mutable struct sDateTimeField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "DATETIME"
  formater::Function = format_text_sql
end

function DateTimeField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sDateTimeField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sDecimalField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Float64, Nothing} = nothing
  editable::Bool = false
  max_digits::Int = 10
  decimal_places::Int = 2
  type::String = "DECIMAL"
  formater::Function = format_number_sql
end

function DecimalField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false, max_digits=10, decimal_places=2)
  return sDecimalField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable, max_digits=max_digits, decimal_places=decimal_places)
end

@kwdef mutable struct sEmailField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "VARCHAR"
  formater::Function = format_text_sql
end

function EmailField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sEmailField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sFloatField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Float64, String, Int64, Nothing} = nothing
  editable::Bool = false
  type::String = "FLOAT"
  formater::Function = format_number_sql
end

function FloatField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  default  = validate_default(default, Union{Float64, String, Int64, Nothing}, "FloatField", parse)
  return sFloatField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sImageField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "BLOB"
  formater::Function = format_text_sql
end

function ImageField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sImageField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sTextField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "TEXT"
  formater::Function = format_text_sql
end

function TextField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sTextField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sTimeField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "TIME"
  formater::Function = format_text_sql
end

function TimeField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sTimeField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sBinaryField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "BLOB"
  formater::Function = format_text_sql
end

function BinaryField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sBinaryField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end


# axiliar function

"""
    format_string(x)

Format the input `x` as a string if it is of type `String`, otherwise return `x` as is.
"""
function format_string(x)
  if x isa String
    return "\"$x\""
  else
    return x
  end
end

# convert string to Int64
function format2int64(x::String)::Int64
  return parse(Int64, x) 
end


"""
  validate_default(default, expected_type::Type, field_name::String, converter::Function)

Validate the default value for a field based on the expected type.

# Arguments
- `default`: The default value to be validated.
- `expected_type::Type`: The expected type for the default value.
- `field_name::String`: The name of the field being validated.
- `converter::Function`: A function used to convert the default value if it is not of the expected type.

# Returns
- If the default value is of the expected type, it is returned as is.
- If the default value can be converted to the expected type using the provided converter function, the converted value is returned.
- If the default value is neither of the expected type nor convertible to it, an `ArgumentError` is thrown.
"""
function validate_default(default, expected_type::Type, field_name::String, converter::Function)
  if (default isa expected_type)
    return default
  else
    try
      converter(default)
    catch e
      throw(ArgumentError("Invalid default value for $field_name. Expected type: $expected_type, got: $(typeof(default)). Please provide a value of type $expected_type."))
    end
  end
end



  
end