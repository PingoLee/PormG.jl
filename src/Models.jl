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
    stadard_field = getfield(@__MODULE__, struct_name)()
    sets::Vector{String} = []
    for sfield in fieldnames(typeof(field))
      if getfield(field, sfield) != getfield(stadard_field, sfield)
        push!(sets, """$sfield=$(getfield(field, sfield))""")
      end
    end
    if struct_name == :IDField
      fields = ",\n  $field_name = Models.$struct_name($(join(sets, ", ")))" * fields
    else 
      fields *= ",\n  $field_name = Models.$struct_name($(join(sets, ", ")))"
    end
  end
  @info("""$(model.name) = Models.Model("$(model.name)"$fields)""")

  return """$(model.name) = Models.Model("$(model.name)"$fields)"""
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
  on_delete::Union{String, Nothing} = nothing

end

function ForeignKey(to::Union{String, PormGModel}, on_delete::String; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sForeignKey(verbose_name=verbose_name, name=name, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable, to=to, on_delete=on_delete)  
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
  default::Union{Float64, Nothing} = nothing
  editable::Bool = false
end

function FloatField(; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
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


  
end