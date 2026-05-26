# I want recreate the Django models in Julia
module Models
using Dates, TimeZones
using Base64
using UUIDs
import JSON
import PormG: PormGField, PormGModel, reserved_words, Migration
import PormG: DATETIME_FORMAT
import PormG: SQLConn, config, Configuration
import PormG: CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, SET, DO_NOTHING, PROTECT
# import PormG: make_password, check_password, password_needs_upgrade, DEFAULT_PBKDF2_ITERATIONS
using Printf
import Base.deepcopy
using Decimals


import PormG: @pormg_debug


#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Core Types
#═══════════════════════════════════════════════════════════════════════════════
@kwdef mutable struct Model_Type <: PormGModel
  name::AbstractString
  verbose_name::Union{String, Nothing} = nothing
  fields::Dict{String, PormGField}
  field_names::Vector{String} = [] # needed to create sql queries with joins
  related_objects::Dict{String, Any} = Dict{String, Any}() # needed to create sql queries with joins
  _module::Union{Module, Nothing} = nothing # needed to create sql queries with joins
  connect_key::Union{String, Nothing} = nothing # needed to get the connection
  cache::Dict{String, Dict{String, Any}} = Dict{String, Dict{String, Any}}()
end

@kwdef struct ManyToManyRelation
  field_name::String
  through_model::String
  owner_model::String
  owner_binding::String
  owner_pk::String
  owner_column::String
  related_model::String
  related_binding::String
  related_pk::String
  related_column::String
  inverse_accessor::String
  reverse::Bool = false
end
function deepcopy(model::Model_Type)
  try
    return Model_Type(
      model.name,
      model.verbose_name,
      deepcopy(model.fields),
      deepcopy(model.field_names),
      deepcopy(model.related_objects),
      model._module,
      model.connect_key,
      deepcopy(model.cache)
    )
  catch e
    @error("Failed to deepcopy Model_Type: $(e)")
    rethrow(e)
  end
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Management/Reflection
#═══════════════════════════════════════════════════════════════════════════════

const REGISTERED_MODULES = Dict{Module, String}()

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
    # Use invokelatest to avoid World Age issues in Julia 1.12+
    attr = try
        Base.invokelatest(getfield, modules, name)
    catch
        nothing
    end
    if isa(attr, PormGModel)
      if attr.name == ""
        attr.name = name |> format_model_name
      end
      push!(model_names, symbol ? name : attr)
    end
  end
  return model_names
end

function capitalize_symbol(s::Symbol)
  str = string(s)
  if isempty(str)
    return s
  end
  return Symbol(uppercase(str[1]) * str[2:end])
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

function get_model_name(model::PormGModel, settings::SQLConn, symbol::Bool=true)::Union{String, Symbol}
  value::Union{String, Symbol, Nothing} = nothing
  if settings.django_prefix !== nothing
    django_prefix = """$(settings.django_prefix)_"""
    value = replace(model.name, django_prefix => "") |> lowercase
  else
    value = model.name |> lowercase
  end
  if symbol
    return value |> Symbol
  else
    return value
  end
end

# TODO add related_name (like django validation) to check if the field is a ForeignKey and the related_name model is defined when models has more than one foreign key to the same model
function set_models(_module::Module, path::String)::Nothing
  @pormg_debug false
  models = get_all_models(_module)  

  # Register for lazy loading / self-healing
  REGISTERED_MODULES[_module] = path
  
  # Try to inject a fallback constant into the module so it survives precompilation
  # This allows Models.ensure_model_initialized to recover even if REGISTERED_MODULES is lost.
  try
    if !isdefined(_module, :__pormg_init_path__)
        # We use Core.eval to define a constant in the module
        Base.invokelatest(Core.eval, _module, :(const __pormg_init_path__ = $path))
    end
  catch e
    # Ignore errors if the module is closed or already has it
  end

  abs_path = abspath(path)

  # Find if this path is already loaded under any key
  connect_key = nothing
  for (k, v) in config
    v_path_abs = abspath(v.db_def_folder)
    if v_path_abs == abs_path || v.db_def_folder == path || basename(v.db_def_folder) == basename(path)
        connect_key = k
        break
    end
  end

  @pormg_debug false
  if isnothing(connect_key)
    # Try to load using the path as the primary key
    Configuration.load(path)
    connect_key = path
  end
  
  settings::SQLConn = Configuration.get_settings(connect_key)

  # set the original module in models and clear related objects for idempotency
  for model in models
    model._module = _module
    empty!(model.related_objects)
    haskey(model.cache, "many_to_many") && delete!(model.cache, "many_to_many")
  end
  # Validate like django related_name, if the model has more than one foreign key to the same model the related_name must be defined
  for model in models
    dict_tables_c = Dict{String, Int}()
    dict_tables_fiels = Dict{String, Vector{String}}()
    model.connect_key = connect_key
    # @pormg_debug model.name == "dash_tab_cvat" 
    # println(model.name)
    for (field_name, field) in pairs(model.fields)
      if field isa sForeignKey || field isa sOneToOneField
        field_to::Union{PormGModel, Nothing} = nothing
        try
          field_to = field.to isa PormGModel ? field.to : getfield(_module, field.to |> Symbol)
        catch
          throw(ArgumentError("The model $(field.to) in the field $field_name in the model $(model.name) is not defined"))
        end
        # println("field_to_", field_to.name)
        if field.pk_field === nothing
          pk_sym = get_model_pk_field(field_to)
          if pk_sym !== nothing
            field.pk_field = string(pk_sym)
          end
        end
        if haskey(dict_tables_c, field_to.name)
          dict_tables_c[field_to.name] += 1
          push!(dict_tables_fiels[field_to.name], field_name)
        else
          dict_tables_c[field_to.name] = 1
          dict_tables_fiels[field_to.name] = [field_name]
        end
        if dict_tables_c[field_to.name] > 1
          @pormg_debug false
          if field.related_name === nothing 
            field.related_name = string(get_model_name(model, settings), "_", field_name) |> lowercase
            @info("The field $field_name in the model $(model.name) is a ForeignKey and the related_name is not defined, so the related_name was set to $(field.related_name)")
          end
          if haskey(field_to.related_objects, field.related_name)
            throw(ArgumentError("The related_name $(field.related_name) in the model $(model.name) is already defined"))
          else
            field_to.related_objects[field.related_name] = (field_name |> Symbol, field.pk_field |> Symbol, get_model_name(model, settings), get_model_pk_field(model) |> Symbol)
          end
        elseif dict_tables_c[field_to.name] == 1
          @pormg_debug false
          model_name = get_model_name(model, settings)
          if field.related_name === nothing            
            field_to.related_objects[model_name |> string] = (field_name |> Symbol, field.pk_field |> Symbol, model_name |> Symbol, get_model_pk_field(model) |> Symbol)
          else
            if haskey(field_to.related_objects, field.related_name)
              throw(ArgumentError("The related_name $(field.related_name) in the model $(model.name) is already defined"))
            else
              field_to.related_objects[field.related_name] = (field_name |> Symbol, field.pk_field |> Symbol, model_name, get_model_pk_field(model) |> Symbol)
            end
          end
        end        
        
        # check on_delete
        if field.on_delete == SET_NULL && field.null == false
          @error("The field $field_name in the model $(model.name) has on_delete SET_NULL and null false, this is not allowed")
        end
        if field.on_delete == SET_DEFAULT && field.default === nothing
          @error("The field $field_name in the model $(model.name) has on_delete SET_DEFAULT and default nothing, this is not allowed")
        end
                 
      elseif is_many_to_many_field(field)
        _register_many_to_many_relation!(_module, settings, model, field_name, field)
      end
    end
  end
 
  return nothing
end

"""
    ensure_model_initialized(model::PormGModel)

Checks if a model has been initialized (i.e., has a connect_key that exists in `config`).
If not, attempts self-healing by:
1. Remapping stale path-based keys to current session alias keys
2. Re-registering via REGISTERED_MODULES
3. Scanning loaded modules for __pormg_init_path__ markers
4. Using the model's own `_module` reference (survives precompilation)
"""
function ensure_model_initialized(model::PormGModel)
    # Fast path: already properly initialized
    if !isnothing(model.connect_key) && haskey(config, model.connect_key)
        return true
    end

    # Case 1: Key exists but is not in config (likely a path mismatch after precompilation)
    if !isnothing(model.connect_key) && !haskey(config, model.connect_key)
        abs_key = abspath(model.connect_key)
        for (k, v) in config
            if abspath(v.db_def_folder) == abs_key || basename(v.db_def_folder) == basename(model.connect_key)
                @info "Self-healing: Remapping connect_key '$(model.connect_key)' → '$k'"
                model.connect_key = k
                return true
            end
        end
    end

    # Case 2: Uninitialized or lost registration
    @pormg_debug false
    
    # 2a. Check explicitly registered modules
    for (mod, path) in REGISTERED_MODULES
        models_in_mod = get_all_models(mod)
        for m in models_in_mod
            if m === model
                @info "Self-healing: Initializing model $(model.name) from registered module $(mod)"
                set_models(mod, path)
                return true
            end
        end
    end

    # 2b. If the model has _module set (survives precompilation), try to re-register it directly.
    #     The module's __init__ may not have fired yet, or may have failed because config wasn't loaded.
    if !isnothing(model._module) && !isempty(config)
        mod = model._module
        # Try to find the matching config entry by checking db_def_folder patterns
        for (k, v) in config
            try
                # Get all models in the module to check if model belongs to it
                models_in_mod = get_all_models(mod)
                if any(m === model for m in models_in_mod)
                    @info "Self-healing: Re-registering module $(mod) with key '$k'"
                    set_models(mod, v.db_def_folder)
                    if !isnothing(model.connect_key) && haskey(config, model.connect_key)
                        return true
                    end
                end
            catch
                continue
            end
        end
    end

    # 2c. Scan loaded packages for __pormg_init_path__ markers (injected by @models_module)
    for (pkgid, mod) in Base.loaded_modules
        if isdefined(mod, :__pormg_init_path__)
            path = getfield(mod, :__pormg_init_path__)
            @info "Self-healing: Recovered registration for $(mod) from __pormg_init_path__"
            try
                set_models(mod, path)
            catch
                continue
            end
            models_in_mod = get_all_models(mod)
            if any(m === model for m in models_in_mod)
                return true
            end
        end
    end

    return false
end

function format_fild_name(name::String)::String
  isempty(name) && return name
  name[1] == '_' && (name = name[2:end])   
  isempty(name) && return name
  name = lowercase(name)
  if occursin(r"__|@|^_", name)
    throw(ArgumentError("The field name $name contains __ or @ or starts with _; this is not allowed"))
  end 
  return name
end
function format_fild_name(name::Nothing)::Nothing
  return nothing
end
format_fild_name(name::Symbol)::String = name |> String |> format_fild_name

function format_model_name(name::String)::String  
  return format_fild_name(name)  
end
function format_model_name(name::Symbol)::String
  return name |> String |> format_model_name  
end
function format_model_name(name::PormGModel)::String
  return name.name |> format_model_name
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Model Constructors
#═══════════════════════════════════════════════════════════════════════════════
# Constructor a function that adds a field to the model the number of fields is not limited to the number of fields, the fields are added to the fields dictionary but the name of the field is the key
function Model(name::AbstractString, fields::NTuple{N, <:Pair{Symbol}}) where N
  fields_dict::Dict{String, PormGField} = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    field_name = field[1] |> String |> format_fild_name
    if !(field[2] isa PormGField)
      throw(ArgumentError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field[2]
    !is_many_to_many_field(field[2]) && push!(field_names, field_name)
  end
  # println(fields_dict)
  return Model_Type(name=name, fields=fields_dict, field_names=field_names)
end
function Model(name::AbstractString; fields...)
  
  return Model(name,  Tuple(pairs(fields)))
end
function Model(name::AbstractString, dict::Dict{String, PormGField})
  field_names::Vector{String} = []
  for (field_name, field) in pairs(dict)    
    !is_many_to_many_field(field) && push!(field_names, field_name |> format_fild_name)
  end
  return Model_Type(name=name, fields=dict, field_names=field_names)
end
function Model(name::AbstractString, fields::Dict{Symbol, Any})
  fields_dict = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    @pormg_debug false
    field_name = field_name |> String |> format_fild_name
    if !(field isa PormGField)
      throw(ArgumentError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field
    !is_many_to_many_field(field) && push!(field_names, field_name)
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
    add_field!(model::PormGModel, field_name::Union{String, Symbol}, field::PormGField)

Dynamically adds a field to an existing model. If the field is a ManyToManyField,
it also registers reverse accessors and caches join metadata (requires the model to
be initialized via `set_models()` / `@import_models` with a configured connection).
"""
function add_field!(model::PormGModel, field_name::Union{String, Symbol}, field::PormGField)
  field_name = format_fild_name(field_name isa Symbol ? String(field_name) : field_name)

  if is_many_to_many_field(field)
    ensure_model_initialized(model)
    if model._module === nothing
      throw(ArgumentError(
        "ManyToManyField $(model.name).$(field_name) requires the model to be registered via " *
        "set_models() or @import_models before add_field! can register reverse accessors."
      ))
    end
    if model.connect_key === nothing || !haskey(config, model.connect_key)
      throw(ArgumentError(
        "ManyToManyField $(model.name).$(field_name) requires a database connection. " *
        "Call set_models() with a configured connection before add_field!."
      ))
    end
    model.fields[field_name] = field
    _register_many_to_many_relation!(model._module, config[model.connect_key], model, field_name, field)
    return nothing
  end

  model.fields[field_name] = field
  push!(model.field_names, field_name)
  return nothing
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Serialization
#═══════════════════════════════════════════════════════════════════════════════

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
function Model_to_str(model::Union{Model_Type, PormGModel}, settings::SQLConn; contants_julia::Vector{String}=reserved_words)::String
  fields::String = ""
  django_prefix::Bool = settings.django_prefix === nothing ? false : true
  for (field_name, field) in pairs(model.fields) |> sort
    occursin(r"__|@|^_", field_name) && throw(ArgumentError("The field name $field_name in the model $model contains __ or @ or starts with _"))
    field_name in contants_julia && (field_name = "_$field_name")
    struct_name::Symbol = nameof(typeof(field)) |> string |> x -> x[2:end] |> Symbol    
    sets::Vector{String} = []
    try
      fields = if struct_name in [:ForeignKey, :OneToOneField]
        _model_to_str_foreign_key(field_name, field, struct_name, sets, fields)
      elseif struct_name == :ManyToManyField
        _model_to_str_many_to_many(field_name, field, sets, fields)
      else
        _model_to_str_general(field_name, field, struct_name, sets, fields)
      end
    catch e
      # @pormg_debug
    end
  end
  model_name_abs = django_prefix ? string(settings.django_prefix, "_", model.name |> lowercase) : model.name |> lowercase
  model_var_name = uppercasefirst(model.name)
  @info("""$(model_var_name) = Models.Model("$(model_name_abs)"$fields)""")

  return """$(model_var_name) = Models.Model("$(model_name_abs)"$fields)"""
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

function _model_to_str_many_to_many(field_name, field, sets, fields)
  to = field.to isa PormGModel ? field.to.name : field.to
  field.through !== nothing && push!(sets, "through=$(format_string(field.through isa PormGModel ? field.through.name : field.through))")
  field.related_name !== nothing && push!(sets, "related_name=$(format_string(field.related_name))")
  field.db_table !== nothing && push!(sets, "db_table=$(format_string(field.db_table))")
  field.source_field !== nothing && push!(sets, "source_field=$(format_string(field.source_field))")
  field.target_field !== nothing && push!(sets, "target_field=$(format_string(field.target_field))")
  field.verbose_name !== nothing && push!(sets, "verbose_name=$(format_string(field.verbose_name))")
  fields *= ",\n  $field_name = Models.ManyToManyField(\"$to\"$(isempty(sets) ? "" : ", " * join(sets, ", ")))"
  return fields
end

# ---
# Tools to manage models
#

function foreign_keys_in_model(model::PormGModel)
  fks = Dict{String, Any}()
  for (fname, field) in model.fields
    if hasfield(typeof(field), :to) && !is_many_to_many_field(field)   # detects ForeignKey / OneToOneField
      fks[fname] = field
    end
  end
  return fks
end


#═══════════════════════════════════════════════════════════════════════════════
# SECTION: SQL Formatters
#═══════════════════════════════════════════════════════════════════════════════


function format_text_sql(value::Union{Int, Date, DateTime, ZonedDateTime})
    return string(value)        
end
function format_text_sql(value::Union{Missing, Nothing})
    return missing
end
function format_text_sql(value::Bool)
  return value
    # return value ? "'true'" : "'false'"
end
function format_text_sql(value::AbstractString)
  return value
    # return string("'", replace(value, "'" => "`"), "'")    
end
function format_text_sql(value::AbstractArray)
  arrayref::Vector{String} = []
  for v in value
    push!(arrayref, v |> format_text_sql)
  end
  @pormg_debug false
  # return string("(", join(arrayref, ","), ")")
  return arrayref
end
function format_text_sql(value::Time)
  return string(value)
end  

function _duration_to_nanoseconds(value::Period)::Int64
  if value isa Week
    return Int64(Dates.value(value)) * 7 * 24 * 60 * 60 * 1_000_000_000
  elseif value isa Day
    return Int64(Dates.value(value)) * 24 * 60 * 60 * 1_000_000_000
  elseif value isa Hour
    return Int64(Dates.value(value)) * 60 * 60 * 1_000_000_000
  elseif value isa Minute
    return Int64(Dates.value(value)) * 60 * 1_000_000_000
  elseif value isa Second
    return Int64(Dates.value(value)) * 1_000_000_000
  elseif value isa Millisecond
    return Int64(Dates.value(value)) * 1_000_000
  elseif value isa Microsecond
    return Int64(Dates.value(value)) * 1_000
  elseif value isa Nanosecond
    return Int64(Dates.value(value))
  end

  throw(ArgumentError("DurationField only supports week/day/time-based periods. Months and years are ambiguous for SQL intervals."))
end

function _duration_to_nanoseconds(value::Dates.CompoundPeriod)::Int64
  total = Int64(0)
  for period in Dates.periods(value)
    total += _duration_to_nanoseconds(period)
  end
  return total
end

function _duration_from_seconds_string(value::AbstractString)::String
  match_result = match(r"^([+-]?)(\d+)(?:\.(\d+))?$", value)
  match_result === nothing && throw(ArgumentError("The duration $value is invalid"))

  sign, seconds_str, fraction = match_result.captures
  fraction = fraction === nothing ? "" : ".$(rstrip(fraction, '0'))"
  fraction = fraction == "." ? "" : fraction
  return "$(sign === "-" ? "-" : "")00:00:$(lpad(seconds_str, 2, '0'))$(fraction)"
end

function _normalize_duration_string(value::AbstractString)::String
  stripped = strip(value)
  isempty(stripped) && throw(ArgumentError("The duration cannot be empty"))

  if (match_result = match(r"^([+-]?)(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$", stripped)) !== nothing
    sign, hours, minutes, seconds, fraction = match_result.captures
    fraction = fraction === nothing ? "" : ".$(rstrip(fraction, '0'))"
    fraction = fraction == "." ? "" : fraction
    return "$(sign === "-" ? "-" : "")$(hours):$(minutes):$(seconds)$(fraction)"
  elseif (match_result = match(r"^([+-]?)(\d+):(\d{2})(?:\.(\d+))?$", stripped)) !== nothing
    sign, minutes, seconds, fraction = match_result.captures
    fraction = fraction === nothing ? "" : ".$(rstrip(fraction, '0'))"
    fraction = fraction == "." ? "" : fraction
    return "$(sign === "-" ? "-" : "")00:$(lpad(minutes, 2, '0')):$(seconds)$(fraction)"
  elseif occursin(r"^[+-]?\d+(?:\.\d+)?$", stripped)
    return _duration_from_seconds_string(stripped)
  end

  throw(ArgumentError("The duration $value is invalid. Accepted formats: HH:MM:SS(.sss), M:SS(.sss), or SS(.sss)."))
end

function _duration_nanoseconds_to_string(total_nanoseconds::Int64)::String
  sign = total_nanoseconds < 0 ? "-" : ""
  remaining = abs(total_nanoseconds)

  hours, remaining = divrem(remaining, 3_600_000_000_000)
  minutes, remaining = divrem(remaining, 60_000_000_000)
  seconds, nanoseconds = divrem(remaining, 1_000_000_000)

  fraction = ""
  if nanoseconds != 0
    fraction = "." * rstrip(lpad(string(nanoseconds), 9, '0'), '0')
  end

  return "$(sign)$(lpad(string(hours), 2, '0')):$(lpad(string(minutes), 2, '0')):$(lpad(string(seconds), 2, '0'))$(fraction)"
end

function format_duration_sql(value::Union{Missing, Nothing})
  return missing
end

function format_duration_sql(value::AbstractString)
  return _normalize_duration_string(value)
end

function format_duration_sql(value::Period)
  return _duration_nanoseconds_to_string(_duration_to_nanoseconds(value))
end

function format_duration_sql(value::Dates.CompoundPeriod)
  return _duration_nanoseconds_to_string(_duration_to_nanoseconds(value))
end

function format_duration_sql(value)
  throw(ArgumentError("The duration must be a Period, CompoundPeriod, or a string in HH:MM:SS(.sss), M:SS(.sss), or SS(.sss) format"))
end

# ─────────────────────────────────────────────────────────────────────────────
# UUID formatting
# ─────────────────────────────────────────────────────────────────────────────

const _UUID_REGEX = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

function format_uuid_sql(value::UUID)
  return string(value)
end

function format_uuid_sql(value::Union{Missing, Nothing})
  return missing
end

function format_uuid_sql(value::AbstractString)
  s = strip(string(value))
  occursin(_UUID_REGEX, s) || throw(ArgumentError("Invalid UUID format: '$s'. Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
  return lowercase(s)
end

function format_uuid_sql(value)
  throw(ArgumentError("The value must be a UUID or a string in the format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
end

# ─────────────────────────────────────────────────────────────────────────────
# JSON formatting
# ─────────────────────────────────────────────────────────────────────────────

function format_json_sql(value::Union{Missing, Nothing})
  return missing
end

function format_json_sql(value::AbstractString)
  try
    JSON.parse(value)
  catch e
    throw(ArgumentError("Invalid JSON string: $(sprint(showerror, e))"))
  end
  return value
end

function format_json_sql(value::Union{AbstractDict, AbstractVector, NamedTuple})
  return JSON.json(value)
end

function format_json_sql(value::Union{Bool, Integer, AbstractFloat})
  return JSON.json(value)
end

function format_json_sql(value)
  throw(ArgumentError("JSONField value must be a valid JSON string, Dict, Vector, NamedTuple, or scalar. Got: $(typeof(value))"))
end

function format_number_sql(value::Bool)
  # Bool <: Integer in Julia, so without this overload `true` would be returned as-is
  # and LibPQ would serialize it as 'true', which PostgreSQL rejects for integer columns.
  return Int(value)  # true → 1, false → 0
end
function format_number_sql(value::Integer)
  return value
    # return string(value)    
end
function format_number_sql(value::Union{Missing, Nothing})
    return missing
end
function format_number_sql(value::Union{Float16, Float32, Float64}) # TODO: @sprintf is necessary?
  # Use @sprintf to avoid scientific notation and ensure full precision
  return @sprintf("%.17g", value)
end
function format_number_sql(value::AbstractString)
  value = value |> string |> strip
  isempty(value) && throw(ArgumentError("The value is empty and cannot be used as a number"))

  if occursin(r"^[+-]?\d+,\d+$", value)
    throw(ArgumentError("Does you want to use ',' as decimal separator? Please use '.' instead."))
  end

  # try integer first
  if (i = tryparse(Int64, value)) !== nothing
    return value
  # then float
  elseif (f = tryparse(Float64, value)) !== nothing
    isfinite(f) || throw(ArgumentError("Non-finite numeric values are not supported. Please use a finite numeric value instead."))
    return value
  else
    throw(ArgumentError("The value '$value' is not a valid number"))
  end
end
function format_number_sql(value::AbstractArray)
  arrayref::Vector{Union{String, Integer, Missing}} = []
  for v in value
    # Ensure nested strings (like SubString) are converted to String or Integer as required by the Union
    res = v |> format_number_sql
    push!(arrayref, res isa AbstractString ? string(res) : res)
  end
  # return string("(", join(arrayref, ","), ")")
  return arrayref
end
function format_number_sql(value::Decimals.Decimal)
  try
    return string(value)
  catch e
    @error("Failed to format Decimals.Decimal value: $(e)", value=value)
    throw(e)
  end
end

function format_bool_sql(value::Integer)
    if value in [0, 1] == false
        throw(ArgumentError("The value must be 0, 1, true or false"))
    end
    return value == 1 ? true : false
end
function format_bool_sql(value::Union{Missing, Nothing})
    return missing
end
function format_bool_sql(value::Bool)
    return value
end

function format_date_sql(value::Date)
    # return string("'", value, "'")    
  return value |> string
end
function format_date_sql(value::Union{Missing, Nothing})
    return missing
end
function format_date_sql(value::DateTime)
  # return string("'", value |> Dates.Date, "'")
  return value |> Dates.Date |> string
end
function format_date_sql(value::ZonedDateTime)
  # return string("'", value |> Dates.Date, "'")
  return value |> Dates.Date |> string
end
function format_date_sql(value::AbstractString)
  if occursin(r"^\d{4}-\d{2}-\d{2}$", value)
    try
        # Validate that it's a real calendar date (e.g. not 2023-02-29)
        Date(value)
        return value
    catch e
        throw(ArgumentError("The date $value is invalid: $(sprint(showerror, e))"))
    end
  else
    throw(ArgumentError("The date $value is invalid"))
  end  
end
function format_date_sql(value)
  throw(ArgumentError("The date must be a Date, DateTime, ZonedDateTime or a string in the format YYYY-MM-DD"))
end


function format_timezone_sql(value::String; format::String=DATETIME_FORMAT)
  return validate_timezone(value, format)
end
function format_timezone_sql(value::Union{Missing, Nothing})
    return missing
end
function format_timezone_sql(value::ZonedDateTime)
    # return string("'", value, "'")    
  return value |> string
end
function format_timezone_sql(value::DateTime)
  return format_timezone_sql(value, "UTC") |> string
end
function format_timezone_sql(value::DateTime, timezone::String)
  # function used just in create 
  return ZonedDateTime(value, TimeZone(timezone))
end

function format_yyyy_mm(value::String)
  if occursin(r"^\d{4}-\d{2}$", value)
    return value
  else
    throw(ArgumentError("The value $value is invalid, it must be in the format YYYY-MM"))
  end  
end
function format_yyyy_mm(value::Integer)
  value = string(value)
  if length(value) == 6
    # Format as YYYY-MM
    return string(value[1:4], "-", value[5:6])
  else
    throw(ArgumentError("The value $value must be a 6-digit integer in the format YYYYMM or a string in the format YYYY-MM"))
  end
end
function format_yyyy_mm(value)
  throw(ArgumentError("The value must be a String or Integer in the format YYYY-MM or YYYYMM"))
end    

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Comparison Tools
#═══════════════════════════════════════════════════════════════════════════════

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

  if length(new_fields) != length(old_fields)
    return false
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
    try
      if !(field_name in fieldnames(typeof(old_field)))
        return false
      elseif field_name == :to && _compare_field_foreign_key(new_field, old_field)
        continue
      elseif field_name == :on_delete
        continue  # Skip comparison for :on_delete attribute
      elseif getfield(new_field, field_name) != getfield(old_field, field_name)
        return false
      end
    catch
      @pormg_debug false
    end
  end
  return true
end
function _compare_model_field(new_field::Dict{String, PormGField}, old_field::Dict{String, PormGField})
  return _compare_model_field(new_field |> _compare_model_fields_prepare_fields, old_field |> _compare_model_fields_prepare_fields)
end

function _compare_field_foreign_key(new_field::PormGField, old_field::PormGField)::Bool
  new_to = new_field.to isa PormGModel ? new_field.to.name : new_field.to
  old_to = old_field.to isa PormGModel ? old_field.to.name : old_field.to
  normalized_new_to = isnothing(new_to) ? nothing : format_model_name(string(new_to))
  normalized_old_to = isnothing(old_to) ? nothing : format_model_name(string(old_to))
  normalized_new_pk = isnothing(new_field.pk_field) ? nothing : format_fild_name(string(new_field.pk_field))
  normalized_old_pk = isnothing(old_field.pk_field) ? nothing : format_fild_name(string(old_field.pk_field))
  if normalized_new_to == normalized_old_to && normalized_new_pk == normalized_old_pk
    return true
  end
  return false
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Fields
#═══════════════════════════════════════════════════════════════════════════════

include("models/fields.jl")

is_many_to_many_field(::PormGField)::Bool = false
is_many_to_many_field(::sManyToManyField)::Bool = true

function _model_reference_name(model_ref::Union{String, PormGModel})::String
  return model_ref isa PormGModel ? model_ref.name : String(model_ref)
end

function _same_model_reference(a::Union{String, PormGModel}, b::PormGModel)::Bool
  return format_model_name(_model_reference_name(a)) == format_model_name(b.name)
end

function _find_model_binding_name(_module::Module, model::PormGModel)::String
  for name in names(_module; all=true, imported=true)
    attr = try
      Base.invokelatest(getfield, _module, name)
    catch
      nothing
    end
    attr === model && return String(name)
  end
  return uppercasefirst(String(model.name))
end

_resolve_model_reference(_module::Module, model_ref::PormGModel)::PormGModel = model_ref

function _resolve_model_reference(_module::Module, model_ref::String)::PormGModel
  try
    return Base.invokelatest(getfield, _module, Symbol(model_ref))
  catch
    target_name = format_model_name(model_ref)
    for model in get_all_models(_module)
      format_model_name(model.name) == target_name && return model
    end
  end
  throw(ArgumentError("The model $(model_ref) referenced by a ManyToManyField is not defined"))
end

_resolve_model_reference(models::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, model_ref::PormGModel)::PormGModel = model_ref

function _resolve_model_reference(models::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, model_ref::String)::PormGModel
  target_name = format_model_name(model_ref)
  for (binding_name, info) in models
    model = info[:model]
    if format_model_name(String(binding_name)) == target_name || format_model_name(model.name) == target_name
      return model
    end
  end
  throw(ArgumentError("The model $(model_ref) referenced by a ManyToManyField is not defined"))
end

function _many_to_many_table_name(source_model::PormGModel, field_name::String, field::sManyToManyField, settings::SQLConn)::String
  field.db_table !== nothing && return field.db_table
  source_name = get_model_name(source_model, settings, false)
  return format_model_name("$(source_name)_$(field_name)")
end

function _many_to_many_column_name(model::PormGModel, pk_field::String)::String
  return format_fild_name("$(format_model_name(model.name))_$(pk_field)")
end

function _infer_through_field(through_model::PormGModel, target_model::PormGModel, role::String)::String
  matches = String[]
  for (field_name, field) in through_model.fields
    if (field isa sForeignKey || field isa sOneToOneField) && _same_model_reference(field.to, target_model)
      push!(matches, field_name)
    end
  end

  length(matches) == 1 && return matches[1]
  isempty(matches) && throw(ArgumentError("The explicit through model $(through_model.name) has no foreign key to $(target_model.name) for the many-to-many $(role) side"))
  throw(ArgumentError("The explicit through model $(through_model.name) has multiple foreign keys to $(target_model.name); set $(role)_field explicitly"))
end

function _relation_from_many_to_many(
  owner_model::PormGModel,
  owner_binding::String,
  field_name::String,
  field::sManyToManyField,
  related_model::PormGModel,
  related_binding::String,
  settings::SQLConn;
  _module::Union{Module, Nothing}=nothing,
  model_map::Union{Nothing, Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}}=nothing,
)
  owner_pk_sym = get_model_pk_field(owner_model)
  related_pk_sym = get_model_pk_field(related_model)
  owner_pk_sym === nothing && throw(ArgumentError("ManyToManyField $(owner_model.name).$(field_name) requires the source model to define a single primary key"))
  related_pk_sym === nothing && throw(ArgumentError("ManyToManyField $(owner_model.name).$(field_name) requires the target model to define a single primary key"))

  owner_pk = String(owner_pk_sym)
  related_pk = String(related_pk_sym)
  through_model_name = _many_to_many_table_name(owner_model, field_name, field, settings)
  owner_column = field.source_field === nothing ? _many_to_many_column_name(owner_model, owner_pk) : field.source_field
  related_column = field.target_field === nothing ? _many_to_many_column_name(related_model, related_pk) : field.target_field

  if field.through !== nothing
    through_model = if field.through isa PormGModel
      field.through
    elseif _module !== nothing
      _resolve_model_reference(_module, field.through)
    elseif model_map !== nothing
      _resolve_model_reference(model_map, field.through)
    else
      throw(ArgumentError("Cannot resolve explicit through model $(field.through) for $(owner_model.name).$(field_name)"))
    end

    through_model_name = through_model.name
    owner_column = field.source_field === nothing ? _infer_through_field(through_model, owner_model, "source") : field.source_field
    related_column = field.target_field === nothing ? _infer_through_field(through_model, related_model, "target") : field.target_field
    owner_fk = through_model.fields[owner_column]
    related_fk = through_model.fields[related_column]
    owner_pk = owner_fk.pk_field === nothing ? owner_pk : String(owner_fk.pk_field)
    related_pk = related_fk.pk_field === nothing ? related_pk : String(related_fk.pk_field)
  end

  inverse_accessor = field.related_name === nothing ? get_model_name(owner_model, settings, false) : field.related_name
  return ManyToManyRelation(
    field_name=field_name,
    through_model=through_model_name,
    owner_model=owner_model.name,
    owner_binding=owner_binding,
    owner_pk=owner_pk,
    owner_column=owner_column,
    related_model=related_model.name,
    related_binding=related_binding,
    related_pk=related_pk,
    related_column=related_column,
    inverse_accessor=inverse_accessor,
    reverse=false,
  )
end

function _reverse_many_to_many_relation(relation::ManyToManyRelation, reverse_accessor::String)::ManyToManyRelation
  return ManyToManyRelation(
    field_name=reverse_accessor,
    through_model=relation.through_model,
    owner_model=relation.related_model,
    owner_binding=relation.related_binding,
    owner_pk=relation.related_pk,
    owner_column=relation.related_column,
    related_model=relation.owner_model,
    related_binding=relation.owner_binding,
    related_pk=relation.owner_pk,
    related_column=relation.owner_column,
    inverse_accessor=relation.field_name,
    reverse=true,
  )
end

function _cache_many_to_many_relation!(model::PormGModel, accessor::String, relation::ManyToManyRelation)
  cache = get!(model.cache, "many_to_many", Dict{String, Any}())
  cache[accessor] = relation
  return relation
end

function _register_many_to_many_relation!(_module::Module, settings::SQLConn, model::PormGModel, field_name::String, field::sManyToManyField)::Nothing
  related_model = _resolve_model_reference(_module, field.to)
  relation = _relation_from_many_to_many(
    model,
    _find_model_binding_name(_module, model),
    field_name,
    field,
    related_model,
    _find_model_binding_name(_module, related_model),
    settings,
    _module=_module,
  )
  _cache_many_to_many_relation!(model, field_name, relation)

  reverse_accessor = relation.inverse_accessor
  haskey(related_model.related_objects, reverse_accessor) && throw(ArgumentError("The related_name $(reverse_accessor) in the model $(model.name) is already defined"))
  related_model.related_objects[reverse_accessor] = _reverse_many_to_many_relation(relation, reverse_accessor)
  field.related_name === nothing && (field.related_name = reverse_accessor)
  return nothing
end

function has_many_to_many_accessor(model::PormGModel, accessor::String)::Bool
  if haskey(model.cache, "many_to_many") && haskey(model.cache["many_to_many"], accessor)
    return true
  end
  return haskey(model.related_objects, accessor) && model.related_objects[accessor] isa ManyToManyRelation
end

function get_many_to_many_relation(model::PormGModel, accessor::String)::ManyToManyRelation
  if haskey(model.cache, "many_to_many") && haskey(model.cache["many_to_many"], accessor)
    return model.cache["many_to_many"][accessor]::ManyToManyRelation
  elseif haskey(model.related_objects, accessor) && model.related_objects[accessor] isa ManyToManyRelation
    return model.related_objects[accessor]::ManyToManyRelation
  end
  throw(ArgumentError("The accessor $(accessor) is not a ManyToMany relation on model $(model.name)"))
end

function strip_many_to_many_fields(model::PormGModel)::PormGModel
  physical_fields = Dict{String, PormGField}()
  for (field_name, field) in model.fields
    is_many_to_many_field(field) && continue
    physical_fields[field_name] = field
  end

  physical_field_names = [field_name for field_name in model.field_names if haskey(physical_fields, field_name)]
  return Model_Type(
    name=model.name,
    verbose_name=model.verbose_name,
    fields=physical_fields,
    field_names=physical_field_names,
    related_objects=copy(model.related_objects),
    _module=model._module,
    connect_key=model.connect_key,
    cache=copy(model.cache),
  )
end

function synthesize_many_to_many_through_models(current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, settings::SQLConn)
  expanded = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()

  for (model_name, model_info) in current_schema
    expanded[model_name] = Dict{Symbol, Union{Bool, PormGModel}}(
      :model => strip_many_to_many_fields(model_info[:model]),
      :exist => model_info[:exist],
    )
  end

  for (model_name, model_info) in current_schema
    source_model = model_info[:model]
    owner_binding = uppercasefirst(String(model_name))
    for (field_name, field) in source_model.fields
      is_many_to_many_field(field) || continue
      field.through === nothing || continue

      target_model = _resolve_model_reference(current_schema, field.to)
      related_binding = uppercasefirst(format_model_name(target_model.name))
      relation = _relation_from_many_to_many(source_model, owner_binding, field_name, field, target_model, related_binding, settings, model_map=current_schema)
      through_fields = Dict{Symbol, Any}(
        :id => IDField(),
        Symbol(relation.owner_column) => ForeignKey(source_model, pk_field=relation.owner_pk, on_delete=CASCADE),
        Symbol(relation.related_column) => ForeignKey(target_model, pk_field=relation.related_pk, on_delete=CASCADE),
      )
      through_model = Model(relation.through_model, through_fields)
      through_model.cache["many_to_many_auto"] = Dict{String, Any}(
        "owner_column" => relation.owner_column,
        "related_column" => relation.related_column,
        "unique_index" => "$(relation.through_model)_$(relation.owner_column)_$(relation.related_column)_uniq",
      )
      through_key = Symbol(relation.through_model)
      if haskey(expanded, through_key)
        existing = expanded[through_key][:model]
        existing_auto = existing.cache !== nothing ? get(existing.cache, "many_to_many_auto", nothing) : nothing
        if existing_auto === nothing ||
           get(existing_auto, "owner_column", nothing) != relation.owner_column ||
           get(existing_auto, "related_column", nothing) != relation.related_column
          throw(ArgumentError(
            "Auto-generated through table $(relation.through_model) for $(source_model.name).$(field_name) " *
            "collides with an existing model or another ManyToManyField. " *
            "Define an explicit `through=` model or override `db_table=` to disambiguate."))
        end
      end
      expanded[through_key] = Dict{Symbol, Union{Bool, PormGModel}}(:model => through_model, :exist => false)
    end
  end

  return expanded
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Auxiliar Functions
#═══════════════════════════════════════════════════════════════════════════════

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
function format2int64(x::AbstractString)::Int64
  return parse(Int64, x |> string) 
end
function format2int64(x::Decimals.Decimal)::Int64
  return Int64(x)
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
      @pormg_debug false
      throw(ArgumentError("Invalid default value for $field_name. Expected type: $expected_type, got: $(typeof(default)). Please provide a value of type $expected_type."))
    end
  end
end

function validate_timezone(value::String, format::String) # TODO: maeby is unnecesary, i think that is better to use validate_default aproach
  # If it looks like a full ZonedDateTime string with timezone info, return it as-is
  # to avoid double-formatting or truncation.
  if occursin(r"(?:Z|[+-]\d{2}:\d{2})$", value)
      return value
  end
  try
    return DateTime(value, format) |> string
  catch e
    throw(ArgumentError("Invalid timezone format. Expected format: $format, got: $value"))
  end
end

"""
    normalize_sqlite_datetime_string(s::AbstractString) -> String

Normalise a raw SQLite datetime string so it can be parsed by a strict ISO 8601
formatter (`dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzz"`):

- Pads sub-second digits to exactly 3 (milliseconds).
- Truncates sub-second digits longer than 3.
- Injects `.000` when no sub-second component is present.
- Returns the string unchanged when it does not match any expected pattern.
"""
function normalize_sqlite_datetime_string(s::AbstractString)
    m = match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.(\d+)(Z|[+-]\d{2}:\d{2})$", s)
    if m !== nothing
        base_dt, ms, tz = m.captures
        if length(ms) < 3
            ms = rpad(ms, 3, '0')
        elseif length(ms) > 3
            ms = ms[1:3]
        end
        return "$(base_dt).$(ms)$(tz)"
    end
    m_no_ms = match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(Z|[+-]\d{2}:\d{2})$", s)
    if m_no_ms !== nothing
        base_dt, tz = m_no_ms.captures
        return "$(base_dt).000$(tz)"
    end
    return s
end

end