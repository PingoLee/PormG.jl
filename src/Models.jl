# I want recreate the Django models in Julia
module Models
using PormG: Field, Model

export CharField, IntegerField, ForeignKey, Model

@Base.kwdef mutable struct Model_Type <: Model
  name::String
  verbose_name::Union{String, Nothing} = nothing
  fields::Dict{Symbol, Field}  
end

# Constructor a function that adds a field to the model the number of fields is not limited to the number of fields, the fields are added to the fields dictionary but the name of the field is the key
function Model(name::String; fields...)
  fields_dict = Dict{Symbol, Field}()
  print(fields)
  for (field_name, field) in pairs(fields)
    if !(field isa Field)
      throw(ArgumentError("All fields must be of type Field, exemple: users = Models.Model(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field
  end
  # println(fields_dict)
  return Model_Type(name=name, fields=fields_dict)
end
function Model(name::String)
  example_usage = "\e[32musers = Models.Model(\"users\", name = Models.CharField(), age = Models.IntegerField())\e[0m"
  throw(ArgumentError("You need to add fields to the model, example: $example_usage"))
end
function Model()
  example_usage = "\e[32musers = Models.Model(\"users\", name = Models.CharField(), age = Models.IntegerField())\e[0m"
  throw(ArgumentError("You need to add a name and fields to the model, example: $example_usage"))
end


@Base.kwdef mutable struct sCharField <: Field
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

@Base.kwdef mutable struct sIntegerField <: Field
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

@Base.kwdef mutable struct sForeignKey <: Field
  verbose_name::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  primary_key::Bool = true
  unique::Bool = false
  blank::Bool = false
  null::Bool = false
  db_index::Bool = false
  default::Union{Int64, Nothing} = nothing
  editable::Bool = false
  to::Union{String, Model, Nothing} = nothing
  on_delete::Union{String, Nothing} = nothing

end

function ForeignKey(to::Union{String, Model}, on_delete::String; verbose_name=nothing, name=nothing, unique=false, blank=false, null=false, db_index=false, default=nothing, editable=false)
  return sForeignKey(verbose_name=verbose_name, name=name, unique=unique, blank=blank, null=null, db_index=db_index, default=default, editable=editable, to=to, on_delete=on_delete)  
end

  
end