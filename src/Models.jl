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
  related_objects::Dict{String, Tuple{Symbol, Symbol, Symbol, Symbol}} = Dict{String, Tuple{Symbol, Symbol, Symbol, Symbol}}() # needed to create sql queries with joins
  _module::Union{Module, Nothing} = nothing # needed to create sql queries with joins
  connect_key::Union{String, Nothing} = nothing # needed to get the connection
  cache::Dict{String, Dict{String, Any}} = Dict{String, Dict{String, Any}}()
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
    push!(field_names, field_name)
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
    push!(field_names, field_name |> format_fild_name)
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
      fields = struct_name in [:ForeignKey, :OneToOneField] ? _model_to_str_foreign_key(field_name, field, struct_name, sets, fields) : _model_to_str_general(field_name, field, struct_name, sets, fields)
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

# ---
# Tools to manage models
#

function foreign_keys_in_model(model::PormGModel)
  fks = Dict{String, Any}()
  for (fname, field) in model.fields
    if hasfield(typeof(field), :to)   # detects ForeignKey / OneToOneField
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
  try
    return DateTime(value, format) |> string
  catch e
    throw(ArgumentError("Invalid timezone format. Expected format: $format, got: $value"))
  end
end

end