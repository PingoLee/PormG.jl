# I want recreate the Django models in Julia
module Models
using Dates, TimeZones
import PormG: PormGField, PormGModel, reserved_words, Migration
import PormG: DATETIME_FORMAT

import PormG.Infiltrator: @infiltrate

export Model, Model_to_str, CharField, IntegerField, ForeignKey, BigIntegerField, BooleanField, DateField, DateTimeField, DecimalField, EmailField, FloatField, ImageField, TextField, TimeField, IDField, BigIntegerField, OneToOneField, AutoField

@kwdef mutable struct Model_Type <: PormGModel
  name::AbstractString
  verbose_name::Union{String, Nothing} = nothing
  fields::Dict{String, PormGField}
  field_names::Vector{String} = [] # needed to create sql queries with joins
  reverse_fields::Dict{String, Tuple{Symbol, Symbol, Symbol, Symbol}} = Dict{String, Tuple{Symbol, Symbol, Symbol, Symbol}}() # needed to create sql queries with joins
  _module::Union{Module, Nothing} = nothing # needed to create sql queries with joins
  connect_key::Union{String, Nothing} = nothing # needed to get the connection
  cache::Dict{String, Dict{String, Any}} = Dict{String, Dict{String, Any}}()
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
      if attr.name == ""
        attr.name = name |> format_model_name
      end
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
function set_models(_module::Module, path::String)::Nothing
  models = get_all_models(_module)  
  connect_key = split(path, "/")[end]

  # set the original module in models
  for model in models
    model._module = _module
  end
  # Validate like django related_name, if the model has more than one foreign key to the same model the related_name must be defined
  for model in models
    dict_tables_c = Dict{String, Int}()
    dict_tables_fiels = Dict{String, Vector{String}}()
    model.connect_key = connect_key
    # println(model.name)
    for (field_name, field) in pairs(model.fields)
      if field isa sForeignKey
        field_to = getfield(_module, field.to |> Symbol)
        if field_to isa PormGModel
          # println("field_to_", field_to.name)
          if haskey(dict_tables_c, field_to.name)
            dict_tables_c[field_to.name] += 1
            push!(dict_tables_fiels[field_to.name], field_name)
          else
            dict_tables_c[field_to.name] = 1
            dict_tables_fiels[field_to.name] = [field_name]
          end
          if dict_tables_c[field_to.name] > 1
            if field.related_name === nothing 
              field.related_name = string(model.name, "_", field_name) |> lowercase
              @warn("The field $field_name in the model $(model.name) is a ForeignKey and the related_name is not defined, so the related_name was set to $(field.related_name)")
            end
            if haskey(field_to.reverse_fields, field.related_name)
              throw(ArgumentError("The related_name $(field.related_name) in the model $(model.name) is already defined"))
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

function format_fild_name(name::String)::String
  name[1] == '_' && (name = name[2:end])   
  name = lowercase(name)
  if occursin(r"__|@|^_", name)
    throw(ArgumentError("The field name $name contains __ or @ or starts with _; this is not allowed"))
  end 
  return name
end

function format_model_name(name::String)::String  
  return format_fild_name(name)  
end
function format_model_name(name::Symbol)::String
  return name |> String |> format_model_name  
end

# Constructor a function that adds a field to the model the number of fields is not limited to the number of fields, the fields are added to the fields dictionary but the name of the field is the key
function Model(name::AbstractString, fields::NTuple{N, Pair{Symbol, T}}) where N where T <: Any
  fields_dict::Dict{String, PormGField} = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    field_name = field[1] |> String |> format_fild_name
    if !(field[2] isa PormGField)
      throw(ArgumentError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field[2]
    push!(field_names, field_name)
  end
  # println(fields_dict)
  return Model_Type(name=name, fields=fields_dict, field_names=field_names)
end
function Model(name::AbstractString; fields...)   
  return Model(name, fields)
end
function Model(name::AbstractString, dict::Dict{String, PormGField})
  field_names::Vector{String} = []
  for (field_name, field) in pairs(dict)    
    push!(field_names, field_name |> format_fild_name)
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
function Model(; fields...)
  return Model("", fields |> Tuple)
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


# ---
# Formaters
#

function format_text_sql(value::Union{Int, Date, DateTime, ZonedDateTime})
    return string("'", value, "'")        
end
function format_text_sql(value::Union{Missing, Nothing})
    return "null"
end
function format_text_sql(value::Bool)
    return value ? "'true'" : "'false'"
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

function format_date_sql(value::Date)
    return string("'", value, "'")    
end
function format_date_sql(value::Union{Missing, Nothing})
    return "null"
end
function format_date_sql(value::DateTime)
  return string("'", value |> Dates.Date, "'")
end
function format_date_sql(value::ZonedDateTime)
  return string("'", value |> Dates.Date, "'")
end
function format_date_sql(value::AbstractString)
  if occursin(r"^\d{4}-\d{2}-\d{2}$", value)
    return string("'", value, "'")
  else
    throw(ArgumentError("The date $value is invalid"))
  end  
end
function format_date_sql()
  throw(ArgumentError("The date must be a Date, DateTime, ZonedDateTime or a string in the format YYYY-MM-DD"))
end


function format_timezone_sql(value::String; format::String=DATETIME_FORMAT)
  return validate_timezone(value, format) ? string("'", value, "'") : throw(ArgumentError("The timezone $value is invalid"))  
end
function format_timezone_sql(value::Union{Missing, Nothing})
    return "null"
end
function format_timezone_sql(value::ZonedDateTime)
    return string("'", value, "'")    
end
function format_timezone_sql(value::DateTime, timezone::String)
  # function used just in create 
  return ZonedDateTime(value, TimeZone(timezone))
end

    

# ---
# Tools to comparisons
#
"""
  are_model_fields_equal(new_model::PormGModel, old_model::PormGModel) :: Bool

Compares the fields of two `PormGModel` instances to determine if they are equal.
"""
function are_model_fields_equal(new_model::PormGModel, old_model::PormGModel)::Bool
  new_fields = new_model.fields |> _compare_model_fields_prepare_fields
  old_fields = old_model.fields |> _compare_model_fields_prepare_fields

  for (field_name, field) in new_fields
    if haskey(old_fields, field_name)
      old_fields[field_name]["exists"] = true
      _compare_model_field(field["field"], old_fields[field_name]["field"]) || return false     
    else
      return false
    end
  end
  return true
end
function _compare_model_fields_prepare_fields(fields::Dict{String, PormGField})
  fields_dict = Dict{String, Dict{String, Union{Bool, PormGField}}}()
  for (field_name, field) in pairs(fields)
    fields_dict[field_name] = Dict{String, Union{Bool, PormGField}}()
    fields_dict[field_name]["exists"] = false
    fields_dict[field_name]["field"] = field
  end
  return fields_dict  
end
function _compare_model_field(new_field::PormGField, old_field::PormGField)::Bool
  # Check if all fields are equal
  if length(fieldnames(typeof(new_field))) != length(fieldnames(typeof(old_field)))
    return false
  end
  for field_name in fieldnames(typeof(new_field))
    # Check if field exists in old_field
    if !(field_name in fieldnames(typeof(old_field)))
      return false
    elseif field_name == :to && lowercase(getfield(new_field, field_name)) == lowercase(getfield(old_field, field_name))
      continue
    elseif field_name == :on_delete
      continue  # Skip comparison for :on_delete attribute
    elseif getfield(new_field, field_name) != getfield(old_field, field_name)
      return false
    end
  end
  return true
end
function _compare_model_field(new_field::Dict{String, PormGField}, old_field::Dict{String, PormGField})
  return _compare_model_field(new_field |> _compare_model_fields_prepare_fields, old_field |> _compare_model_fields_prepare_fields)
end


# ---
# Fields
#

mutable struct sIDField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  auto_increment::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formater::Function
  generated::Bool  # New field to indicate GENERATED ... AS IDENTITY
  generated_always::Bool # New field to indicate GENERATED ALWAYS AS IDENTITY
end

function IDField(; verbose_name=nothing, primary_key=true, auto_increment=true, unique=true, blank=false, null=false, db_index=true, default=nothing, editable=false, generated=true, generated_always=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate other parameters
  !(primary_key isa Bool) && throw(ArgumentError("The 'primary_key' must be a Boolean"))
  !(auto_increment isa Bool) && throw(ArgumentError("The 'auto_increment' must be a Boolean"))
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  !(generated isa Bool) && throw(ArgumentError("The 'generated' must be a Boolean"))
  !(generated_always isa Bool) && throw(ArgumentError("The 'generated_always' must be a Boolean"))
  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "IDField", format2int64)
  # Return the field instance
  return sIDField(
    verbose_name, primary_key, auto_increment, unique, blank, null, db_index, default, editable, "BIGINT", format_number_sql, generated, generated_always
  )
end

@kwdef mutable struct sForeignKey <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = true
  default::Union{Int64, Nothing} = nothing
  editable::Bool = false
  to::Union{String, PormGModel, Nothing} = nothing
  pk_field::Union{String, Symbol, Nothing} = nothing
  on_delete::Union{String, Nothing} = nothing
  on_update::Union{String, Nothing} = nothing
  deferrable::Bool = true
  how::Union{String, Nothing} = nothing # INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN used in _build_row_join
  related_name::Union{String, Nothing} = nothing
  type::String = "BIGINT"
  formater::Function = format_number_sql
  db_constraint::Bool = true
  initially_deferred::Bool = true
end

function ForeignKey(to::Union{String, PormGModel}; verbose_name=nothing, primary_key=false, unique=false, blank=false, null=false, db_index=true, default=nothing, editable=false, pk_field=nothing, on_delete=nothing, on_update=nothing, deferrable=false, initially_deferred=false, how=nothing, related_name=nothing, db_constraint=true)
  # println(on_delete |> typeof)
  # Validate 'to' parameter
  !(to isa Union{String, PormGModel}) && throw(ArgumentError("The 'to' parameter must be a String or PormGModel"))
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate other parameters
  !(primary_key isa Bool) && throw(ArgumentError("The 'primary_key' must be a Boolean"))
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  !(deferrable isa Bool) && throw(ArgumentError("The 'deferrable' must be a Boolean"))
  !(initially_deferred isa Bool) && throw(ArgumentError("The 'initially_deferred' must be a Boolean"))
  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "ForeignKey", format2int64)
  # Validate optional string parameters
  !(pk_field isa Union{Nothing, AbstractString, Symbol}) && throw(ArgumentError("The 'pk_field' must be a String, Symbol, or nothing"))
  !(on_delete isa Union{Nothing, AbstractString}) && throw(ArgumentError("The 'on_delete' must be a String or nothing"))
  !(on_update isa Union{Nothing, AbstractString}) && throw(ArgumentError("The 'on_update' must be a String or nothing"))
  !(how isa Union{Nothing, AbstractString}) && throw(ArgumentError("The 'how' must be a String or nothing"))
  !(related_name isa Union{Nothing, AbstractString}) && throw(ArgumentError("The 'related_name' must be a String or nothing"))
  !(db_constraint isa Bool) && throw(ArgumentError("The 'db_constraint' must be a Boolean"))
  # resolve db_index
  db_index = db_index || !db_constraint
  # Return the field instance
  return sForeignKey(
    verbose_name=verbose_name, primary_key=primary_key, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable, to=to, pk_field=pk_field,
    on_delete=on_delete, on_update=on_update, deferrable=deferrable, how=how, related_name=related_name, db_constraint=db_constraint, initially_deferred=initially_deferred
  )  
end


@kwdef mutable struct sOneToOneField <: PormGField
  # Same fields as sForeignKey but with unique=true by default
  unique::Bool = true
  verbose_name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Int64, Nothing} = nothing
  editable::Bool = false
  to::Union{String, PormGModel, Nothing} = nothing
  pk_field::Union{String, Symbol, Nothing} = nothing
  on_delete::Union{String, Nothing} = nothing
  on_update::Union{String, Nothing} = nothing
  deferrable::Bool = true
  how::Union{String, Nothing} = nothing # INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN used in _build_row_join
  related_name::Union{String, Nothing} = nothing
  type::String = "BIGINT"
  formater::Function = format_number_sql
  db_constraint::Bool = true
  initially_deferred::Bool = true
end

function OneToOneField(to::Union{String, PormGModel}; verbose_name=nothing, primary_key=false, unique=true, blank=false, null=false, db_index=false, default=nothing, editable=false, pk_field=nothing, on_delete=nothing, on_update=nothing, deferrable=false, initially_deferred=false, how=nothing, related_name=nothing, db_constraint=true)
  # Similar validation as in ForeignKey
  # Validate 'to' parameter
  !(to isa Union{String, PormGModel}) && throw(ArgumentError("The 'to' parameter must be a String or PormGModel"))
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate other parameters
  !(primary_key isa Bool) && throw(ArgumentError("The 'primary_key' must be a Boolean"))
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  !(deferrable isa Bool) && throw(ArgumentError("The 'deferrable' must be a Boolean"))
  !(initially_deferred isa Bool) && throw(ArgumentError("The 'initially_deferred' must be a Boolean"))
  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "OneToOneField", format2int64)
  # Validate optional string parameters
  !(pk_field isa Union{Nothing, String, Symbol}) && throw(ArgumentError("The 'pk_field' must be a String, Symbol, or nothing"))
  !(on_delete isa Union{Nothing, AbstractString}) && throw(ArgumentError("The 'on_delete' must be a String or nothing"))
  !(on_update isa Union{Nothing, AbstractString}) && throw(ArgumentError("The 'on_update' must be a String or nothing"))
  !(how isa Union{Nothing, String}) && throw(ArgumentError("The 'how' must be a String or nothing"))
  !(related_name isa Union{Nothing, String}) && throw(ArgumentError("The 'related_name' must be a String or nothing"))
  !(db_constraint isa Bool) && throw(ArgumentError("The 'db_constraint' must be a Boolean"))
  # resolve db_index
  db_index = db_index || !db_constraint
  # Return the field instance
  return sOneToOneField(
    verbose_name=verbose_name, primary_key=primary_key, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable, to=to, pk_field=pk_field,
    on_delete=on_delete, on_update=on_update, deferrable=deferrable, how=how, related_name=related_name, db_constraint=db_constraint, initially_deferred=initially_deferred
  )
end

mutable struct sAutoField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  auto_increment::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formater::Function
end

function AutoField(; verbose_name=nothing, primary_key=true, auto_increment=true, unique=true, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate other parameters
  !(primary_key isa Bool) && throw(ArgumentError("The 'primary_key' must be a Boolean"))
  !(auto_increment isa Bool) && throw(ArgumentError("The 'auto_increment' must be a Boolean"))
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "AutoField", format2int64)
  # Return the field instance

  return sAutoField(verbose_name, primary_key, auto_increment, unique, blank, null, db_index, default, editable, "INTEGER", format_number_sql)
end

mutable struct sCharField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  max_length::Int
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formater::Function
  choices::Union{NTuple{N, Tuple{AbstractString, AbstractString}}, Nothing} where N
end


function parse_choices(choices_str::String)
  # Parse a string into a tuple of tuples
  # println(choices_str)
  choices = ()
  pattern = r"\(([^()]+)\)"
  for m in eachmatch(pattern, choices_str)
    inner = m.captures[1]
    values = split(inner, ",")
    if length(values) == 2
      key = strip(values[1]) |> string
      value = strip(values[2]) |> string
      choices = (choices..., (key, value))
    else
      throw(ArgumentError("Invalid choices format"))
    end
  end
  return choices
end

function CharField(; verbose_name=nothing, max_length=250, unique=false, blank=false, null=false, db_index=false, db_column=nothing, default=nothing, choices=nothing, editable=true)  
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The verbose_name must be a String or nothing"))
  max_length isa AbstractString && (max_length = parse(Int, max_length))
  max_length isa Int || throw(ArgumentError("The max_length must be an integer"))
  max_length > 255 && throw(ArgumentError("The max_length must be less than or equal to 255"))
  max_length < 1 && throw(ArgumentError("The max_length must be greater than 1"))
  default isa Int && (default = string(default))
  if !(default isa Nothing) && !(default isa AbstractString) 
    throw(ArgumentError("The default value must be a string, but got $(default) ($(typeof(default)))"))
  end
  if !(default isa Nothing) && length(default) > max_length
    throw(ArgumentError("The default value exceeds the max_length, but got $(length(default)) and max_length is $(max_length)"))
  end
  !(unique isa Bool) && throw(ArgumentError("The unique must be a boolean"))
  !(blank isa Bool) && throw(ArgumentError("The blank must be a boolean"))
  !(null isa Bool) && throw(ArgumentError("The null must be a boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The db_index must be a boolean"))
  !(db_column isa Union{Nothing, String}) && throw(ArgumentError("The db_column must be a string or nothing"))
  !(editable isa Bool) && throw(ArgumentError("The editable must be a boolean"))  
  if choices isa AbstractString
    choices = parse_choices(choices)
  elseif !(choices isa Union{Nothing, NTuple{N, Tuple{AbstractString, AbstractString}} where N })
    println(choices)
    println(choices |> typeof)
    throw(ArgumentError("The 'choices' must be a String or Tuple{Tuple{String,String}}, but got $(choices) ($(typeof(choices)))"))
  end
  if choices !== nothing
    for choice in choices
      if !(choice[1] isa AbstractString)
        throw(ArgumentError("Choice values must be strings"))
      end
      if length(choice[1]) > max_length
        throw(ArgumentError("Choices cannot exceed max_length"))
      end
    end
    if default !== nothing
      valid_defaults = choices isa Vector{String} ? choices : [c[1] for c in choices]
      if !(default in valid_defaults)
        throw(ArgumentError("The default value must be one of the choices"))
      end
    end
  end
  return sCharField(verbose_name, false, max_length, unique, blank, null, db_index, db_column, default, editable, "VARCHAR", format_text_sql, choices)
end


@kwdef mutable struct sIntegerField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function IntegerField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The verbose_name must be a String or nothing"))
  
  # Validate default using validate_default
  default = validate_default(default, Union{Int64, Nothing}, "IntegerField", format2int64)
  
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' parameter must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' parameter must be a Booleadn"))
  !(null isa Bool) && throw(ArgumentError("The 'null' parameter must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' parameter must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' parameter must be a Boolean"))
  
  return sIntegerField(
    verbose_name=verbose_name,
    primary_key=false,
    unique=unique,
    blank=blank,
    null=null,
    db_index=db_index,
    default=default,
    editable=editable
  )  
end

@kwdef mutable struct sBigIntegerField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function BigIntegerField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The verbose_name must be a String or nothing"))
  
  # Validate default using validate_default
  default = validate_default(default, Union{Int64, Nothing}, "BigIntegerField", format2int64)
  
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' parameter must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' parameter must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' parameter must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' parameter must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' parameter must be a Boolean"))
  
  return sBigIntegerField(
    verbose_name=verbose_name,
    primary_key=false,
    unique=unique,
    blank=blank,
    null=null,
    db_index=db_index,
    default=default,
    editable=editable
  )  
end

@kwdef mutable struct sBooleanField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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


function BooleanField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{Bool, Nothing}, "BooleanField", x -> parse(Bool, string(x)))
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Return the field instance
  return sBooleanField(
    verbose_name=verbose_name, primary_key=false, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable
  )  
end

@kwdef mutable struct sDateField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  auto_now::Bool = false
  auto_now_add::Bool = false
  type::String = "DATE"
  formater::Function = format_date_sql
end

function DateField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false, auto_now=false, auto_now_add=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The verbose_name must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{Date, Nothing}, "DateField", format_date_sql)
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  !(auto_now isa Bool) && throw(ArgumentError("The 'auto_now' must be a Boolean"))
  !(auto_now_add isa Bool) && throw(ArgumentError("The 'auto_now_add' must be a Boolean"))
  # Return the field instance
  return sDateField(
    verbose_name=verbose_name, primary_key=false, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable, auto_now=auto_now, auto_now_add=auto_now_add
  )  
end

@kwdef mutable struct sDateTimeField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  auto_now::Bool = false
  auto_now_add::Bool = false
  type::String = "TIMESTAMPTZ"
  formater::Function = format_timezone_sql 
end

function DateTimeField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false, auto_now=false, auto_now_add=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The verbose_name must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{DateTime, Nothing}, "DateTimeField", x -> DateTime(x))
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  !(auto_now isa Bool) && throw(ArgumentError("The 'auto_now' must be a Boolean"))
  !(auto_now_add isa Bool) && throw(ArgumentError("The 'auto_now_add' must be a Boolean"))
  # Return the field instance
  return sDateTimeField(
    verbose_name=verbose_name, primary_key=false, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable, auto_now=auto_now, auto_now_add=auto_now_add
  )  
end

@kwdef mutable struct sDecimalField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function DecimalField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false, max_digits=10, decimal_places=2)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The verbose_name must be a String or nothing"))
  
  # Validate default using validate_default
  default = validate_default(default, Union{Float64, Nothing}, "DecimalField", format2float64)
  max_digits = validate_default(max_digits, Int, "DecimalField", format2int64)
  decimal_places = validate_default(decimal_places, Int, "DecimalField", format2int64)
  
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' parameter must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' parameter must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' parameter must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' parameter must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' parameter must be a Boolean"))
  
  return sDecimalField(
    verbose_name=verbose_name,
    primary_key=false,
    unique=unique,
    blank=blank,
    null=null,
    db_index=db_index,
    default=default,
    editable=editable,
    max_digits=max_digits,
    decimal_places=decimal_places
  )
end

@kwdef mutable struct sEmailField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function EmailField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{String, Nothing}, "EmailField", x -> parse(String, x))
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Return the field instance
  return sEmailField(
    verbose_name=verbose_name, primary_key=false, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable
  )  
end

@kwdef mutable struct sFloatField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function FloatField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The verbose_name must be a String or nothing"))
  
  # Validate default using validate_default
  default = validate_default(default, Union{Float64, String, Int64, Nothing}, "FloatField", parse)
  
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' parameter must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' parameter must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' parameter must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' parameter must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' parameter must be a Boolean"))
  
  return sFloatField(
    verbose_name=verbose_name,
    primary_key=false,
    unique=unique,
    blank=blank,
    null=null,
    db_index=db_index,
    default=default,
    editable=editable
  )  
end

@kwdef mutable struct sImageField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function ImageField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{String, Nothing}, "ImageField", x -> parse(String, x))
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Return the field instance
  return sImageField(
    verbose_name=verbose_name, primary_key=false, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable
  )  
end

@kwdef mutable struct sTextField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function TextField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{String, Nothing}, "TextField", x -> parse(String, x))
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Return the field instance
  return sTextField(
    verbose_name=verbose_name, primary_key=false, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable
  )  
end

@kwdef mutable struct sTimeField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
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

function TimeField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{Time, Nothing}, "TimeField", x -> Time(x))
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Return the field instance
  return sTimeField(
    verbose_name=verbose_name, primary_key=false, unique=unique, blank=blank, null=null,
    db_index=db_index, default=default, editable=editable
  )  
end

@kwdef mutable struct sBinaryField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{String, Nothing} = nothing
  editable::Bool = false
  type::String = "BLOB"
  formater::Function = format_text_sql
  max_length::Union{Int, Nothing} = nothing
end

function BinaryField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false, max_length=nothing)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{Vector{UInt8}, Nothing}, "BinaryField", x -> Base64.decode(x))
  if max_length isa AbstractString
    if occursin(r"\d+", max_length)
      max_length = validate_default(max_length, Int, "BinaryField", format2int64)
    else
      max_length = nothing
    end
  end
  if !(max_length isa Union{Nothing, Int})
    throw(ArgumentError("The 'max_length' must be an integer or nothing"))
  elseif max_length isa Int && max_length <= 0
    throw(ArgumentError("The 'max_length' must be a positive integer"))
  end
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Return the field instance
  return sBinaryField(
    verbose_name=verbose_name,
    unique=unique,
    blank=blank,
    null=null,
    db_index=db_index,
    default=default,
    editable=editable,
    max_length=max_length
  )
end

@kwdef mutable struct sDurationField <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  primary_key::Bool = false
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Period, Nothing} = nothing
  editable::Bool = false
  type::String = "INTERVAL"
  formater::Function = format_text_sql
end

function DurationField(; verbose_name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  # Validate verbose_name
  !(verbose_name isa Union{Nothing, String}) && throw(ArgumentError("The 'verbose_name' must be a String or nothing"))
  # Validate default
  default = validate_default(default, Union{Period, Nothing}, "DurationField", x -> parse(Period, string(x)))
  # Validate other parameters
  !(unique isa Bool) && throw(ArgumentError("The 'unique' must be a Boolean"))
  !(blank isa Bool) && throw(ArgumentError("The 'blank' must be a Boolean"))
  !(null isa Bool) && throw(ArgumentError("The 'null' must be a Boolean"))
  !(db_index isa Bool) && throw(ArgumentError("The 'db_index' must be a Boolean"))
  !(editable isa Bool) && throw(ArgumentError("The 'editable' must be a Boolean"))
  # Return the field instance
  return sDurationField(
    verbose_name=verbose_name,
    unique=unique,
    blank=blank,
    null=null,
    db_index=db_index,
    default=default,
    editable=editable
  )
end

# axiliar function

"""
    format_string(x)

Format the input `x` as a string if it is of type `String`, otherwise return `x` as is.
"""
function format_string(x)
  @infiltrate
  if x isa String
    return "\"$x\""
  else
    return x
  end
end

# convert string to Int64
function format2int64(x::AbstractString)::Int64
  return parse(Int64, x |> string) 
end
# convert string to Float64
function format2float64(x::Union{Int, AbstractString})::Float64
  return parse(Float64, x |> string) 
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
      return converter(default)
    catch e
      throw(ArgumentError("Invalid default value for $field_name. Expected type: $expected_type, got: $(typeof(default)). Please provide a value of type $expected_type."))
    end
  end
end

function validate_timezone(value::String, format::String) # TODO: maeby is unnecesary, i think that is better to use validate_default aproach
  try
    return DateTime(value, format) |> string
  catch e
    throw(ArgumentError("Invalid timezone format. Expected format: $format, got: $value"))
  end
end


# ---
# Define function to manage on_delete
#

function on_delete(action::Symbol, model::PormGModel)
    if action == :CASCADE
        cascade(model)
    elseif action == :SET_NULL
        # Implement logic to set foreign key fields to null
    elseif action == :RESTRICT
        # Implement logic to prevent deleting if there are related objects
    else
        # DO_NOTHING or other custom behaviors
    end
end

function cascade(model::PormGModel)
    # Here, implement the actual cascade logic for related objects
end

end