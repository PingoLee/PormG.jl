# I want recreate the Django models in Julia
module Models
using PormG: PormGField, PormGModel

export Model, Model_to_str, CharField, IntegerField, ForeignKey, BigIntegerField, BooleanField, DateField, DateTimeField, DecimalField, EmailField, FloatField, ImageField, TextField, TimeField, IDField, BigIntegerField

@kwdef mutable struct Model_Type <: PormGModel
  name::AbstractString
  verbose_name::Union{String, Nothing} = nothing
  fields::Dict{Symbol, PormGField}  
end

# Constructor a function that adds a field to the model the number of fields is not limited to the number of fields, the fields are added to the fields dictionary but the name of the field is the key
function Model(name::AbstractString; fields...) 
  fields_dict = Dict{Symbol, PormGField}()
  print(fields)
  for (field_name, field) in pairs(fields)
    if !(field isa PormGField)
      throw(ArgumentError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field
  end
  # println(fields_dict)
  return Model_Type(name=name, fields=fields_dict)
end
function Model(name::AbstractString, dict::Dict{Symbol, PormGField})
  return Model_Type(name=name, fields=dict)
end
function Model(name::AbstractString, fields::Dict{Symbol, Any})
  fields_dict = Dict{Symbol, PormGField}()
  for (field_name, field) in pairs(fields)
    if !(field isa PormGField)
      throw(ArgumentError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field
  end
  return Model_Type(name=name, fields=fields_dict)
end
function Model(name::String)
  example_usage = "\e[32musers = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())\e[0m"
  throw(ArgumentError("You need to add fields to the model, example: $example_usage"))
end
function Model()
  example_usage = "\e[32musers = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())\e[0m"
  throw(ArgumentError("You need to add a name and fields to the model, example: $example_usage"))
end

# Generate the string representation of the model
# users = Models.Model("users", 
#   name = Models.CharField(), 
#   email = Models.CharField(), 
#   age = Models.IntegerField()
# )
function Model_to_str(model::Union{Model_Type, PormGModel})::String
  fields::String = ""
  for (field_name, field) in pairs(model.fields) |> sort
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

end

function BigIntegerField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sBigIntegerField(verbose_name=verbose_name, name=name, primary_key=false, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable)  
end

@kwdef mutable struct sForeignKey <: PormGField
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = true
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

end

function ForeignKey(to::Union{String, PormGModel}; verbose_name=nothing, name=nothing, primary_key=true, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false, pk_field=nothing, on_delete=nothing, on_update=nothing, deferrable=false)
  return sForeignKey(verbose_name=verbose_name, name=name, primary_key=primary_key, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable, to=to, pk_field=pk_field, on_delete=on_delete, on_update=on_update, deferrable=deferrable)  
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