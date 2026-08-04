# I want recreate the Django models in Julia
module Models
using Dates, TimeZones
using Base64
using UUIDs
import JSON
import PormG: PormGField, PormGModel, reserved_words, Migration
import PormG: DATETIME_FORMAT
import PormG: _emsg  # shared TTY-aware error-message strip helper (Kernel)
# Semantic error taxonomy (#239). Models raises TWO different categories, and the split is by
# *when* the failure happens, not by which file the helper lives in:
#   ModelDefinitionError — defining a model/schema (Model, add_field!, UniqueConstraint,
#                          set_models, FK/M2M resolution).
#   InvalidValueError    — coercing a VALUE (the format_*_sql family), reached from
#                          querybuilder/sanitization.jl on the insert/update path.
#   FieldValidationError — `validate_default`, which despite living here is called only from
#                          field constructors in src/models/fields.jl to check a `default=` kwarg.
import PormG: ModelDefinitionError, InvalidValueError, FieldValidationError
import PormG: PormGSettings, config, Configuration
import PormG: CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, DO_NOTHING, PROTECT
using Printf
using Decimals


import PormG: @pormg_debug

# ---
# `public` (Julia 1.11+) — the field constructors are this module's user-facing API (#289).
#
# `Models` exports NOTHING (`names(Models) == [:Models]`) and that is deliberate: users write
# `Models.CharField(...)` qualified, as every page of `docs/src/fields.md` shows. But un-exported is
# not the same as private, and two things were reading it that way:
#   - `docs/src/api.md`'s `@autodocs` uses `Private = false`, and Documenter decides via
#     `Base.ispublic(mod, name)` against THIS module — so without these declarations every field
#     constructor silently disappears from the API reference.
#   - `names(Models)` and tooling reported the module as having no API at all.
# `public` fixes both without changing what a bare `using` brings into scope.
#
# Everything else here (`add_field!`, `ensure_model_initialized`, `validate_default`,
# `normalize_sqlite_datetime_string`, …) is genuinely internal and deliberately omitted.
public AutoField, BigIntegerField, BinaryField, BooleanField, CharField, DateField, DateTimeField,
  DecimalField, DurationField, EmailField, FileField, FloatField, ForeignKey, IDField, ImageField,
  IntegerField, JSONField, ManyToManyField, OneToOneField, PasswordField, PositiveIntegerField,
  PositiveSmallIntegerField, SlugField, TextField, TimeField, URLField, UUIDField

# The module's ENTRY POINTS (#295), declared separately because they are a different category from
# the field constructors above: a field is a column, these define and register the model itself.
#
# The trap worth naming, since it costs nothing to fall into: under #289's rule a docstring alone
# publishes NOTHING. `Model` is the first call in essentially every example in `docs/src`, and
# writing its docstring without this line would leave it invisible on the API reference exactly as
# before. The two steps move together — and so does the frozen set in
# `test/unit/test_docstring_coverage.jl`, which fails if this line and that literal disagree.
#
# `Model_Type` is deliberately NOT here. It is documented (users hold one as `M.Driver`) but never
# named: it appears zero times in `docs/src`, and the vocabulary users are given for "a model" is
# the abstract `PormGModel`. Publishing the concrete name would invite code to depend on it.
public Model, UniqueConstraint, set_models


#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Core Types
#═══════════════════════════════════════════════════════════════════════════════
"""
    Model_Type <: PormGModel

The concrete model object — what [`Model`](@ref) returns and what `M.Driver` is. It is the only
concrete subtype of `PormGModel`, and it is reached by *holding* one, not by naming it: build models
with `Model(...)` rather than calling this constructor.

Construction fills `name`, `fields` and `field_names`; the remaining slots are populated later by
[`set_models`](@ref) (directly or through `@import_models`), which is why a model used before
registration has `connect_key === nothing` and no reverse relations.

| Slot | Filled by | Holds |
|---|---|---|
| `name` | `Model(...)`, or `set_models` from the Julia binding | The table name — verbatim from the positional argument, or lowercased when derived from the binding |
| `fields` | `Model(...)` | Declared field name → `PormGField`, including many-to-many fields |
| `field_names` | `Model(...)` | The subset that owns a real column — many-to-many fields are excluded |
| `related_objects` | `set_models` | Reverse accessors installed by foreign keys pointing *at* this model |
| `_module` / `connect_key` | `set_models` | The defining module and the connection key it registered under |
| `cache` | `set_models`, `Model(constraints = …)` | Derived metadata: many-to-many relations, declared unique constraints |

`deepcopy` **shares** rather than clones (`deepcopy(model) === model`): a model is resolved schema
state treated as an immutable shared reference, and recursion would otherwise descend into
`_module::Module` and throw. The query builder relies on this — copying a query copies its state but
keeps the same model.

`verbose_name` is inert: no `Model` method accepts it, and nothing consumes it — it is only ever
copied from one model to another. It does not reach the DDL and does not appear in generated model
files.

See also [`Model`](@ref), [`set_models`](@ref), [`UniqueConstraint`](@ref).
"""
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
  # #65: resolved model objects for the two sides, populated wherever a relation is built
  # (`_relation_from_many_to_many` for the forward relation, swapped in the reverse one). This
  # completes the "resolve every lazy reference once" guarantee for M2M — the query builder still
  # re-resolves by binding today; consuming these slots to retire that reflection is #68/#41.
  owner_model_resolved::Union{PormGModel, Nothing} = nothing
  related_model_resolved::Union{PormGModel, Nothing} = nothing
end
# A Model_Type is resolved schema state — its `fields`, `_module`, and `related_objects` are built once
# by `set_models` and treated as an immutable, SHARED reference everywhere (the query builder copies query
# state but shares the model verbatim: `SQLObjectQuery` deepcopy sets `model=obj.model`). Deep-copying a
# model is never wanted and, worse, throws: the moment recursion reaches a relation field's resolved
# `.to` (another Model_Type) it descends into `_module::Module` → "deepcopy of Modules not supported".
# Override the recursion hook to SHARE — return the same model, registered in `stackdict` so its identity
# is stable across the surrounding copy. So `deepcopy(model) === model`, and any container/field that
# holds a model shares it rather than cloning the schema graph. Mirrors the `ManyToManyRelation` override
# below (#65) and resolves the module-traversal throw (#157).
Base.deepcopy_internal(m::Model_Type, stackdict::IdDict) = get!(stackdict, m, m)

# #65: a ManyToManyRelation now carries resolved model objects (owner/related). Those are shared,
# derived state — `set_models` repopulates them — so deep-copying them would needlessly clone the
# whole related-model graph (a Model_Type's `related_objects` holds these relations). Copy the
# value-type String/Bool fields; SHARE the two resolved-model references — consistent with the
# `Model_Type` share hook above (#157) and the targeted override for SQLiteParameterizedQuery.
function Base.deepcopy_internal(r::ManyToManyRelation, stackdict::IdDict)
  haskey(stackdict, r) && return stackdict[r]
  new = ManyToManyRelation(
    field_name=r.field_name,
    through_model=r.through_model,
    owner_model=r.owner_model,
    owner_binding=r.owner_binding,
    owner_pk=r.owner_pk,
    owner_column=r.owner_column,
    related_model=r.related_model,
    related_binding=r.related_binding,
    related_pk=r.related_pk,
    related_column=r.related_column,
    inverse_accessor=r.inverse_accessor,
    reverse=r.reverse,
    owner_model_resolved=r.owner_model_resolved,
    related_model_resolved=r.related_model_resolved,
  )
  stackdict[r] = new
  return new
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
    throw(ModelDefinitionError("The model $(model.name) has more than one primary key field: $(join(fields, ", "))"))
  end
end

function get_model_name(model::PormGModel, settings::PormGSettings, symbol::Bool=true)::Union{String, Symbol}
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
#
# NOTE: keep this comment ABOVE the docstring. A comment between a docstring and the definition it
# documents silently detaches it — `@doc` binds to the next expression, and the comment is not one,
# so the string becomes a no-op and `?set_models` answers nothing. Nothing catches that: the package
# still precompiles, and `checkdocs = :public` only verifies that docstrings which EXIST reach the
# manual. It cost a debugging round in #295.
"""
    set_models(_module::Module, path::String) -> nothing

Register every model defined in `_module` against the database configuration folder `path`, and
resolve the relationships between them. This is the manual model-loading path; prefer
`PormG.@import_models` (or `PormG.@models_module` for inline definitions), which call it for you and
also handle precompilation and Revise reloads.

Until a model is registered it is inert: it has no connection and no reverse relations. Building a
query still appears to work — `M.Driver.objects.filter(...)` returns a handler — but rendering or
executing it raises `InvalidConfigurationError`.

Registration does four things:

1. **Names the unnamed.** A model declared without a positional table name carries `name == ""`; it
   is filled in here from the Julia binding, lowercased (`Race = Model(...)` → table `race`).
2. **Binds the connection.** `path` is matched against the configured folders to find the connection
   key. A folder that is not loaded yet is loaded implicitly — which also fixes the environment, so
   call `PormG.Configuration.load(path; env = ...)` first when you need a specific one, and expect
   `MissingConfigurationError` from that implicit load if `path` holds no `connection.yml`.
3. **Resolves relationships.** Each `ForeignKey`/`OneToOneField` target is resolved (a target given
   as a model-name `String` is replaced by the model object), `pk_field` defaults are applied, and
   the reverse accessor is installed on the target. With two foreign keys to the same model, an
   omitted `related_name` is auto-derived and logged. `ManyToManyField`s get their join-table
   metadata built and cached.
4. **Rejects contradictions.** `on_delete = SET_NULL` on a `null = false` field, or `SET_DEFAULT`
   with no `default`, raises `ModelDefinitionError` here — at declaration, rather than later as a
   mangled `UPDATE`. An unresolvable foreign-key target and a duplicate `related_name` raise the
   same type.

Calling it again is safe and is the supported way to pick up edits: reverse relations and
many-to-many caches are cleared before being rebuilt, so a reload cannot accumulate duplicates.

# Examples
```julia
module f1_models
import PormG.Models

Circuit = Models.Model(
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 100),
)

Race = Models.Model(
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"),
)

Models.set_models(@__MODULE__, "db")   # tables `circuit` / `race`; Circuit gains a `race` accessor
end
```

See also [`Model`](@ref), `PormG.@import_models`, `PormG.@models_module`.
"""
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
  
  settings::PormGSettings = Configuration.get_settings(connect_key)

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
        # #65: single-sourced FK/O2O resolution + pk_field defaulting, shared with the migration
        # prelude via `resolve_fk_target!`. strict=true throws on an unresolvable target, so the
        # returned value is always a resolved model here; it drives the reverse-relation wiring below.
        field_to::PormGModel = resolve_fk_target!(field, field_name, model.name, _module; strict=true)
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
            throw(ModelDefinitionError("The related_name $(field.related_name) in the model $(model.name) is already defined"))
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
              throw(ModelDefinitionError("The related_name $(field.related_name) in the model $(model.name) is already defined"))
            else
              field_to.related_objects[field.related_name] = (field_name |> Symbol, field.pk_field |> Symbol, model_name, get_model_pk_field(model) |> Symbol)
            end
          end
        end        
        
        # check on_delete — a schema that contradicts itself is rejected at registration (#287).
        # These were `@error` logs until #287: they named the problem and then let the broken model
        # through, so the contradiction resurfaced later as a mangled UPDATE or a database-level
        # constraint violation. The delete collector keeps its own copies of both guards for models
        # that never pass through `set_models`; this is the layer that catches them at declaration.
        if field.on_delete == SET_NULL && field.null == false
          throw(ModelDefinitionError("The field \e[4m\e[31m$(field_name)\e[0m in the model \e[4m\e[31m$(model.name)\e[0m declares on_delete SET_NULL but has null=false — the schema contradicts itself. Declare the field with null=true or use a different on_delete."))
        end
        if field.on_delete == SET_DEFAULT && field.default === nothing
          throw(ModelDefinitionError("The field \e[4m\e[31m$(field_name)\e[0m in the model \e[4m\e[31m$(model.name)\e[0m declares on_delete SET_DEFAULT but has no default — the schema contradicts itself. Give the field a default= or use a different on_delete."))
        end
                 
      elseif is_many_to_many_field(field)
        _register_many_to_many_relation!(_module, settings, model, field_name, field)
      end
    end
  end
 
  return nothing
end

"""
    _infer_self_heal_key(model::PormGModel, models_in_mod, config) -> String | Nothing

Decide which connection key to self-heal `model` to by inference, or `nothing` when the
choice would be ambiguous. SAFE-BY-DEFAULT: with more than one connection configured we
refuse to guess — a wrong guess silently routes queries to the wrong database (e.g. binding
`db`-models to `db_portalsus`). We infer a key only when there is exactly one connection AND
`model` is actually one of the models defined in its module (`models_in_mod`).

Pure by construction (no globals, no `set_models` side effects), so the "≥2 connections ⇒
refuse" invariant is unit-testable in isolation. Callers pass `get_all_models(mod)` as
`models_in_mod` and the global `config`.
"""
function _infer_self_heal_key(model::PormGModel, models_in_mod, config)
    length(config) == 1 || return nothing                     # >1 connection → never guess
    any(m === model for m in models_in_mod) || return nothing # model not defined in this module
    return first(keys(config))
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

    # 2b. If the model has _module set (survives precompilation), re-register it from the
    #     module's OWN recorded source path (__pormg_init_path__, injected by
    #     @import_models/@models_module). That path is authoritative — it binds the module
    #     to the connection it was actually defined for. We must NOT guess by scanning
    #     `config`: in a multi-connection setup the first entry iterated could be the wrong
    #     database, silently routing queries there (e.g. binding `db`-models to `db_portalsus`).
    if !isnothing(model._module)
        mod = model._module
        if isdefined(mod, :__pormg_init_path__)
            try
                set_models(mod, getfield(mod, :__pormg_init_path__))
                if !isnothing(model.connect_key) && haskey(config, model.connect_key)
                    @info "Self-healing: Re-registered $(model.name) from module $(mod) source path"
                    return true
                end
            catch
            end
        end
        # Fallback: infer the key from `config`, but only when unambiguous. The decision
        # (refuse to guess with >1 connection) lives in `_infer_self_heal_key` so it can be
        # tested in isolation; here we just act on its verdict.
        if isnothing(model.connect_key)
            try
                inferred = _infer_self_heal_key(model, get_all_models(mod), config)
                if inferred !== nothing
                    set_models(mod, config[inferred].db_def_folder)
                    if !isnothing(model.connect_key) && haskey(config, model.connect_key)
                        return true
                    end
                end
            catch
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

# Normalize a field name: strip ONE leading underscore (the escape hatch for SQL
# reserved words / `id`, e.g. `_end` -> `end`) and validate. The declared case is
# PRESERVED (#57): a field declared `driverId` keeps that case as its identity and
# its column name, so PormG can faithfully target mixed-case/uppercase DB columns.
# Table/model names still lowercase — see `format_model_name` below.
function format_fild_name(name::String)::String
  isempty(name) && return name
  name[1] == '_' && (name = name[2:end])
  isempty(name) && return name
  if occursin(r"__|@|^_", name)
    throw(ModelDefinitionError("The field name $name contains __ or @ or starts with _; this is not allowed"))
  end
  return name
end
function format_fild_name(name::Nothing)::Nothing
  return nothing
end
format_fild_name(name::Symbol)::String = name |> String |> format_fild_name

# Table/model names are LOWERCASED (frozen schema convention, #33) — independent of
# field-name case preservation (#57). Reuses `format_fild_name`'s leading-underscore
# strip + validation, then lowercases the result.
function format_model_name(name::String)::String
  return lowercase(format_fild_name(name))
end
function format_model_name(name::Symbol)::String
  return name |> String |> format_model_name  
end
function format_model_name(name::PormGModel)::String
  return name.name |> format_model_name
end

# Physical SQL column for a field given its declared identity `name` (#50). Returns
# `db_column` when the field carries a non-empty one, else the field name. The
# default (column == field name) keeps every existing schema unchanged; only fields
# that explicitly set `db_column` map to a differently-named column. `hasproperty`
# keeps this safe for any field type — including synthetic/introspected fields that
# do not carry a `db_column` member.
function field_db_column(field::PormGField, name::AbstractString)::String
  if hasproperty(field, :db_column)
    dbc = getproperty(field, :db_column)
    dbc isa AbstractString && !isempty(dbc) && return String(dbc)
  end
  return String(name)
end
field_db_column(field::PormGField, name::Symbol)::String = field_db_column(field, String(name))

# Referenced (parent) physical column for a ForeignKey (#50). `pk_field` names a
# field on the target model; resolve it to that field's `db_column` when the target
# model is in scope (the normal query/migration path, where `to` is a resolved
# PormGModel). The verbatim fallback is CORRECT for introspected models: their `to`
# is a String and their `pk_field` is already the physical column, with no
# `db_column` on the reconstructed field.
function fk_target_column(field::PormGField)::String
  pk = field.pk_field === nothing ? "id" : String(field.pk_field)
  tgt = field.to
  (tgt isa PormGModel && haskey(tgt.fields, pk)) && return field_db_column(tgt.fields[pk], pk)
  return pk
end

# Resolve a string FK/O2O target to its model object within `mod` (#62). Returns the
# resolved `PormGModel`, a model passed through untouched, or `nothing` when the name is
# not a model binding (caller picks strictness). `fk_target_column` can only honor a
# referenced parent's `db_column` once `field.to` is a resolved model, so both model-load
# lifecycles (runtime `set_models`, the migration prelude) write the resolution back via
# this helper. The catch is narrowed to `UndefVarError` (the "not defined" case) so a
# genuine bug surfaces instead of being swallowed.
function _resolve_target_model(to, mod::Module)::Union{PormGModel, Nothing}
  to isa PormGModel && return to
  m = try
    getfield(mod, Symbol(to))
  catch e
    e isa UndefVarError ? nothing : rethrow()
  end
  return m isa PormGModel ? m : nothing
end

"""
    resolve_fk_target!(field, field_name, model_name, lookup; strict) -> Union{PormGModel, Nothing}

Single source (#65) of the FK/O2O "resolve target → write-back `field.to` → default `pk_field`" step that
both model-load lifecycles share — the runtime path (`set_models`) and the migration prelude
(`_load_current_models` → `_resolve_fk_targets_and_pk!`). Side-effect-free with respect to globals: it
mutates only `field.to`/`field.pk_field`, never `REGISTERED_MODULES`, `Configuration`, or reverse relations.

`strict=true` (runtime) throws `ArgumentError` on an unresolvable target; `strict=false` (migrations) is
best-effort — it leaves `field.to` a string, emits a `@debug`, and returns `nothing`, which skips the
`pk_field` default (so an unresolved field keeps both its string `.to` and a `nothing` `.pk_field`, matching
the pre-#65 migration behavior). The statement order is load-bearing: the strict throw fires *before* the
write-back so the message still names the originally-declared target string.

`field` is left untyped because `sForeignKey`/`sOneToOneField` are defined later in the load order (in
`models/fields.jl`); both call sites already guard with `field isa sForeignKey || field isa sOneToOneField`,
so only FK/O2O fields (which carry `.to`/`.pk_field`) ever reach here.
"""
function resolve_fk_target!(field, field_name::AbstractString,
                            model_name::AbstractString, lookup::Module; strict::Bool)::Union{PormGModel, Nothing}
  resolved = _resolve_target_model(field.to, lookup)
  if resolved === nothing
    strict && throw(ModelDefinitionError("The model $(field.to) in the field $field_name in the model $model_name is not defined"))
    @debug "makemigrations: FK target $(field.to) of field $field_name in model $model_name is not a model binding in the models module; leaving as a string"
    return nothing
  end
  # #62: persist the resolved target so `fk_target_column` honors a referenced parent's db_column for
  # string-declared FKs too. Idempotent on reload (a resolved `.to` resolves to itself).
  field.to = resolved
  if field.pk_field === nothing
    pk_sym = get_model_pk_field(resolved)
    pk_sym !== nothing && (field.pk_field = string(pk_sym))
  end
  return resolved
end

# Resolve a field-name string to its physical column within `model` (db_column when
# the named field carries one), verbatim when the name is not a field of `model`. For
# call sites that hold only a model + a field-name string — e.g. reverse-relation join
# keys assembled from `related_objects` tuples (#50). A strict no-op without db_column.
function model_column(model::PormGModel, name::AbstractString)::String
  haskey(model.fields, name) ? field_db_column(model.fields[name], name) : String(name)
end

# True when any field of `model` declares a non-empty db_column (#50). Lets write paths
# skip the physical-column → field-name result remap on the common path (no db_column).
function model_has_db_column(model::PormGModel)::Bool
  for (_, f) in model.fields
    if hasproperty(f, :db_column)
      dbc = getproperty(f, :db_column)
      dbc isa AbstractString && !isempty(dbc) && return true
    end
  end
  return false
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Model-level constraints (composite uniqueness · #19)
#═══════════════════════════════════════════════════════════════════════════════
# A model-level UNIQUE spanning one or more columns — Django's `unique_together`,
# spelled here as named `UniqueConstraint` objects (the Django 2.2+/SQLAlchemy form).
# Declared via the `constraints=` kwarg on `Model(...)`; materialized by the migration
# planner as a `CREATE UNIQUE INDEX` (portable, byte-identical on PostgreSQL and SQLite),
# reusing the exact primitive the auto ManyToManyField join-table index already uses.
# `name === nothing` ⇒ the planner derives `<table>_<cols>_uniq` (mirrors the M2M
# auto-index naming convention). This is NOT a `PormGField` — it carries no column of
# its own; it references existing fields by name.
"""
    UniqueConstraint(; fields, name = nothing)

Require a combination of columns to be unique together — Django's `Meta.unique_together`, spelled as
a named constraint object. Pass it to [`Model`](@ref) through `constraints =`; a single-column rule
is the field option `unique = true` instead.

`fields` names fields **on this model** — one name, or an iterable of them. Foreign keys are
referenced by their field name and resolved to the physical column (honoring `db_column`), and the
declared case is preserved, so name each field exactly as it was declared.

`name` is the index name. Omitted, the migration planner derives `<table>_<cols>_uniq`, matching the
automatic many-to-many index convention. Pass an explicit one when the derived name would exceed
PostgreSQL's 63-byte identifier limit, which Postgres silently truncates — truncation can collide two
constraints into one index.

Invalid declarations raise `ModelDefinitionError` as early as they can be detected: no fields, a
repeated field, or a blank `name` fails here in the constructor; a field that does not exist on the
model, a `ManyToManyField` (it owns no column), or two constraints sharing a name fail when the
model is built.

!!! note "Materialized when the table is created"
    Each constraint becomes a `CREATE UNIQUE INDEX` — identical on PostgreSQL and SQLite — emitted
    when its table is **first created**. Adding or removing one on a table that already exists is
    not yet detected by `makemigrations`; it needs composite-index introspection PormG does not have
    (tracked as a follow-up). Declare composite uniqueness with the model, or add the index by hand.

# Examples
```julia
Constructor_engine = Models.Model("constructor_engines",
  id                  = Models.IDField(),
  constructorid       = Models.ForeignKey(Constructor, pk_field = "constructorid", on_delete = "CASCADE"),
  year                = Models.IntegerField(),
  engine_manufacturer = Models.CharField(max_length = 50),
  constraints = [
    Models.UniqueConstraint(fields = ("constructorid", "year"), name = "uniq_constructor_year"),
  ],
)
```

which migrates to:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS "uniq_constructor_year"
  ON "constructor_engines" ("constructorid", "year");
```

See also [`Model`](@ref).
"""
struct UniqueConstraint
  fields::Vector{String}
  name::Union{String, Nothing}
end
function UniqueConstraint(; fields, name::Union{AbstractString, Nothing} = nothing)
  cols = _normalize_constraint_fields(fields)
  isempty(cols) && throw(ModelDefinitionError("UniqueConstraint requires at least one field"))
  length(unique(cols)) == length(cols) ||
    throw(ModelDefinitionError("UniqueConstraint has duplicate fields: $(cols)"))
  # A blank name would render as an empty (invalid) index identifier; require nothing (auto-derive)
  # or a real name.
  name !== nothing && isempty(strip(name)) &&
    throw(ModelDefinitionError("UniqueConstraint name must be non-empty (pass name=nothing to auto-derive)"))
  return UniqueConstraint(cols, name === nothing ? nothing : String(name))
end

# Accept a single field name (Symbol/String) or an iterable of them; normalize each via
# `format_fild_name` so declared names match the model's field-dict keys (#57 is
# case-sensitive). A lone String must NOT be iterated char-by-char — the scalar method
# below is more specific and wins dispatch for Symbol/AbstractString.
_normalize_constraint_fields(f::Union{Symbol, AbstractString})::Vector{String} = String[format_fild_name(String(f))]
function _normalize_constraint_fields(f)::Vector{String}
  out = String[]
  for x in f
    (x isa Symbol || x isa AbstractString) ||
      throw(ModelDefinitionError("UniqueConstraint fields must be Symbol or String, got $(typeof(x))"))
    push!(out, format_fild_name(String(x)))
  end
  return out
end

# Coerce the `constraints=` argument (a single UniqueConstraint, an iterable of them, or
# nothing) into a concrete Vector. Anything that is not a UniqueConstraint is an error.
_as_constraint_vector(::Nothing)::Vector{UniqueConstraint} = UniqueConstraint[]
_as_constraint_vector(c::UniqueConstraint)::Vector{UniqueConstraint} = UniqueConstraint[c]
function _as_constraint_vector(cs)::Vector{UniqueConstraint}
  out = UniqueConstraint[]
  for c in cs
    c isa UniqueConstraint ||
      throw(ModelDefinitionError("`constraints` must contain UniqueConstraint objects, got $(typeof(c))"))
    push!(out, c)
  end
  return out
end

# Validate declared UniqueConstraints against the built model and stash them in the
# general-purpose `cache` (the same mechanism the ManyToManyField auto-index uses, so
# `deepcopy`/`strip_many_to_many_fields` carry them for free — no new struct field, no
# `deepcopy` positional-enumeration edit). Each referenced field must exist on the model
# and be a concrete column (not a ManyToManyField, which has no column of its own).
function _apply_unique_constraints!(model::Model_Type, constraints)::Model_Type
  list = _as_constraint_vector(constraints)
  isempty(list) && return model
  seen_names = Set{String}()
  for c in list
    for fname in c.fields
      haskey(model.fields, fname) || throw(ModelDefinitionError(
        "UniqueConstraint references unknown field '$(fname)' on model '$(model.name)'. " *
        "Declared fields: $(sort(collect(keys(model.fields))))"))
      is_many_to_many_field(model.fields[fname]) && throw(ModelDefinitionError(
        "UniqueConstraint field '$(fname)' on model '$(model.name)' is a ManyToManyField; " *
        "composite uniqueness must reference concrete columns"))
    end
    # Two constraints sharing an explicit name collide into one index (the plan keys on the name);
    # reject it here for a clear, early error instead of a silent drop at planning time.
    if c.name !== nothing
      c.name in seen_names && throw(ModelDefinitionError(
        "Duplicate UniqueConstraint name '$(c.name)' on model '$(model.name)'; " *
        "constraint names must be unique within a model"))
      push!(seen_names, c.name)
    end
  end
  model.cache["unique_constraints"] = Dict{String, Any}("constraints" => list)
  return model
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Model Constructors
#═══════════════════════════════════════════════════════════════════════════════
"""
    Model(; constraints = nothing, fields...)
    Model(name; constraints = nothing, fields...)

Define a model — one database table, described by its fields. Returns a `Model_Type`: the object the
query builder starts from, as in `M.Driver.objects`.

Every keyword other than `constraints` declares a field: `field_name = FieldType(...)`, where the
field types are the constructors in this module ([`IDField`](@ref), [`CharField`](@ref),
[`ForeignKey`](@ref), …). Declaring a keyword whose value is not a field raises
`ModelDefinitionError` — see the note below, which is the usual reason that happens.

The **table name** comes from the positional string when given, and otherwise from the Julia binding
the model is assigned to, filled in when [`set_models`](@ref) (or `@import_models`) registers the
module. Both forms are idiomatic and `Race = Model(...)` and `Race = Model("race", ...)` name the
same table, because a binding-derived name is lowercased as it is filled in. Reach for the
positional form when the binding name is not the table name you want.

!!! warning "Give the positional name in lowercase"
    A positional name is stored **verbatim**, and the two code paths that consume it disagree about
    case: `makemigrations` lowercases it, while the query builder quotes it as declared. So
    `Model("Driver_Profile", …)` migrates a table named `driver_profile`, and then every
    `SELECT`/`INSERT`/`UPDATE` it builds addresses `"Driver_Profile"` — a table that does not exist
    on a backend where a quoted identifier is case-sensitive, as it is on PostgreSQL.

    Mapping a model to a fixed mixed-case table is
    [issue #59](https://github.com/PingoLee/PormG.jl/issues/59); until it lands, declare table names
    in lowercase.

**Field names keep the case you declare** and are case-sensitive in queries, so a legacy `driverId`
column is addressed as `driverId`. One leading underscore is stripped as the escape hatch for names
that are Julia keywords or SQL reserved words (`_end = ...` declares the column `end`); a name
containing `__` is rejected, since that is the lookup separator.

A `ManyToManyField` is stored on the model but owns no column of its own, so it is absent from
`field_names` and from the created table.

`constraints` takes [`UniqueConstraint`](@ref) objects — one, or a collection — for uniqueness
spanning more than one column. It is the **only** model-level option.

!!! note "PormG has no Django `Meta` block"
    There is no model-level `db_table`, `ordering`, or `verbose_name`. Each of those is a keyword
    like any other, so it is read as a field declaration and raises:

    ```julia
    Models.Model("race", ordering = ["-year"], raceid = Models.IDField())
    # ModelDefinitionError: All fields must be of type PormGField, exemple: …
    ```

    Instead: order at query time with `order_by()` — there is no per-model default sort; pin the
    table name with the positional argument, subject to the lowercase warning above; and set
    `verbose_name` per field, where it is accepted, rather than per model.

# Examples
```julia
Circuit = Models.Model(                       # table `circuit`, inferred from the binding
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 100),
  country   = Models.CharField(max_length = 50),
)

Race = Models.Model(
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"),
  date      = Models.DateField(),
  time      = Models.TimeField(null = true),
  constraints = [                             # no two races share a (year, round)
    Models.UniqueConstraint(fields = ("year", "round"), name = "race_year_round_uniq"),
  ],
)
```

See also [`set_models`](@ref), [`UniqueConstraint`](@ref), [`ForeignKey`](@ref).
"""
function Model(name::AbstractString; constraints = nothing, fields...)
  # Peel `constraints` off BEFORE the `fields...` slurp — otherwise it would flow into the
  # `NTuple{Pair{Symbol}}` method below and trip its `isa PormGField` check (#19). Generated
  # model files (Model_to_str) reload through this kwargs form, so this is the round-trip seam.
  model = Model(name, Tuple(pairs(fields)))
  return _apply_unique_constraints!(model, constraints)
end

# Constructor a function that adds a field to the model the number of fields is not limited to the number of fields, the fields are added to the fields dictionary but the name of the field is the key
function Model(name::AbstractString, fields::NTuple{N, <:Pair{Symbol}}) where N
  fields_dict::Dict{String, PormGField} = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    field_name = field[1] |> String |> format_fild_name
    if !(field[2] isa PormGField)
      throw(ModelDefinitionError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field[2]
    !is_many_to_many_field(field[2]) && push!(field_names, field_name)
  end
  # println(fields_dict)
  return Model_Type(name=name, fields=fields_dict, field_names=field_names)
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
      throw(ModelDefinitionError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field
    !is_many_to_many_field(field) && push!(field_names, field_name)
  end
  return Model_Type(name=name, fields=fields_dict, field_names=field_names)
end
function Model(name::String)
  example_usage = "\e[32musers = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())\e[0m"
  throw(ModelDefinitionError("You need to add fields to the model, example: $example_usage"))
end
function Model(; constraints = nothing, fields...)
  # No-positional-name form (the idiomatic style — the table name is inferred from the binding
  # via set_models). `constraints=` must work here too, so peel it before the `fields...` slurp
  # exactly like the named form above.
  model = Model("", Tuple(pairs(fields)))
  return _apply_unique_constraints!(model, constraints)
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
      throw(ModelDefinitionError(
        "ManyToManyField $(model.name).$(field_name) requires the model to be registered via " *
        "set_models() or @import_models before add_field! can register reverse accessors."
      ))
    end
    if model.connect_key === nothing || !haskey(config, model.connect_key)
      throw(ModelDefinitionError(
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
    Model_to_str(model::Union{Model_Type, PormGModel}, settings::PormGSettings; contants_julia::Vector{String}=reserved_words)::String
- `model::Union{Model_Type, PormGModel}`: The model object to convert.
- `settings::PormGSettings`: Connection settings; supplies `django_prefix` and the target output folder.
- `contants_julia::Vector{String}=reserved_words`: A vector of reserved words in Julia.

# Returns
- `String`: The string representation of the model object. A field whose rendering fails is
  omitted from the constructor call and surfaced instead as a `# PormG: field '<name>' … could
  not be rendered …` comment line prepended above the model definition (#70), plus a structured
  `@warn` — never dropped silently. If *every* field fails to render (so the constructor call
  would be fieldless), the whole model definition is emitted **commented out** with a
  `# PormG: model '<name>' had no renderable fields …` marker instead of a throwing
  `Models.Model("<name>")` call, so the generated file still `include`s cleanly (#134).

# Examples
```julia
users = Models.Model("users", 
  name = Models.CharField(), 
  email = Models.CharField(), 
  age = Models.IntegerField()
)
```
"""
function Model_to_str(model::Union{Model_Type, PormGModel}, settings::PormGSettings; contants_julia::Vector{String}=reserved_words)::String
  fields::String = ""
  render_failures::Vector{String} = String[]
  django_prefix::Bool = settings.django_prefix === nothing ? false : true
  # Iterate fields by name for deterministic output. Use `sort(collect(...))` rather than
  # `sort(::Dict)` (via `pairs(...) |> sort`), which is deprecated and emits a Warn-level
  # depwarn — that surfaces under CI's depwarn-enabled `Pkg.test` run and trips the #70
  # render-failure test's "healthy model → no warn" assertion.
  for (field_name, field) in sort(collect(model.fields); by = first)
    occursin(r"__|@|^_", field_name) && throw(ModelDefinitionError("The field name $field_name in the model $model contains __ or @ or starts with _"))
    db_field_name::String = field_name  # real column name, before reserved-word prefixing — diagnostics must show this one
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
      # Never drop a field silently (#70). Program-state errors surface loudly (#69 guard);
      # anything else logs and emits a visible marker comment in the generated output —
      # the inspectdb/schema-dump convention: the artifact itself shows the gap.
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      @warn "Model_to_str: field render failed — emitting marker comment" model=model.name field=db_field_name field_type=struct_name exception=e
      push!(render_failures, "# PormG: field '$(db_field_name)' ($(struct_name)) could not be rendered: $(replace(sprint(showerror, e), "\n" => " ")) — field omitted.")
    end
  end
  # Composite uniqueness (#19): emit model-level UniqueConstraints so inspectdb/import output
  # round-trips through the `constraints=` kwarg on Model(...). Only when ≥1 field rendered —
  # an all-failed model (fields == "") stays commented-out below, constraints included.
  if fields != "" && haskey(model.cache, "unique_constraints")
    ucs = get(model.cache["unique_constraints"], "constraints", UniqueConstraint[])
    if !isempty(ucs)
      rendered = String[]
      for c in ucs
        cols = join(("\"$(f)\"" for f in c.fields), ", ")
        namepart = c.name === nothing ? "" : ", name = \"$(c.name)\""
        # Trailing comma keeps a single-field tuple valid Julia: ("a",)
        push!(rendered, "Models.UniqueConstraint(fields = ($(cols),)$(namepart))")
      end
      fields *= ",\n  constraints = [$(join(rendered, ", "))]"
    end
  end
  model_name_abs = django_prefix ? string(settings.django_prefix, "_", model.name |> lowercase) : model.name |> lowercase
  model_var_name = uppercasefirst(model.name)
  # Marker comments sit directly above the model definition in the generated file (#70).
  marker = isempty(render_failures) ? "" : join(render_failures, "\n") * "\n"
  if fields == ""
    # Every field failed to render (or the model has none): a bare `Models.Model("name")` call throws
    # ArgumentError at include time (the single-arg constructor requires ≥1 field), which would abort
    # loading the ENTIRE generated module (#134). Comment the definition out — with an explanatory
    # marker — so the file still loads and the user sees exactly which model to fix by hand. Mirrors
    # Rails' SchemaDumper, which comments out a table it can't dump so schema.rb stays loadable.
    note = "# PormG: model '$(model_name_abs)' had no renderable fields — definition commented out."
    result = """$(marker)$(note)\n# $(model_var_name) = Models.Model("$(model_name_abs)")"""
  else
    result = """$(marker)$(model_var_name) = Models.Model("$(model_name_abs)"$fields)"""
  end
  @info(result)

  return result
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
    # #62: `.to` may now be a resolved PormGModel (set_models / migration prelude write
    # back the model). Emit its generated variable name — `uppercasefirst(model.name)`,
    # matching `Model_to_str` above — so a model-`.to` serializes identically to the
    # string a user would have declared. (The only live caller, the import flow, always
    # has a string `.to`; this branch is defensive, locked by a round-trip test.)
    sfield == :to && (v = getfield(field, sfield); to = v isa PormGModel ? uppercasefirst(v.name) : v; continue)
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

  throw(InvalidValueError("DurationField only supports week/day/time-based periods. Months and years are ambiguous for SQL intervals."))
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
  match_result === nothing && throw(InvalidValueError("The duration $value is invalid"))

  sign, seconds_str, fraction = match_result.captures
  fraction = fraction === nothing ? "" : ".$(rstrip(fraction, '0'))"
  fraction = fraction == "." ? "" : fraction
  return "$(sign === "-" ? "-" : "")00:00:$(lpad(seconds_str, 2, '0'))$(fraction)"
end

function _normalize_duration_string(value::AbstractString)::String
  stripped = strip(value)
  isempty(stripped) && throw(InvalidValueError("The duration cannot be empty"))

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

  throw(InvalidValueError("The duration $value is invalid. Accepted formats: HH:MM:SS(.sss), M:SS(.sss), or SS(.sss)."))
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
  throw(InvalidValueError("The duration must be a Period, CompoundPeriod, or a string in HH:MM:SS(.sss), M:SS(.sss), or SS(.sss) format"))
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
  occursin(_UUID_REGEX, s) || throw(InvalidValueError("Invalid UUID format: '$s'. Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
  return lowercase(s)
end

function format_uuid_sql(value)
  throw(InvalidValueError("The value must be a UUID or a string in the format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
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
    throw(InvalidValueError("Invalid JSON string: $(sprint(showerror, e))"))
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
  throw(InvalidValueError("JSONField value must be a valid JSON string, Dict, Vector, NamedTuple, or scalar. Got: $(typeof(value))"))
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
  isempty(value) && throw(InvalidValueError("The value is empty and cannot be used as a number"))

  if occursin(r"^[+-]?\d+,\d+$", value)
    throw(InvalidValueError("Does you want to use ',' as decimal separator? Please use '.' instead."))
  end

  # try integer first
  if (i = tryparse(Int64, value)) !== nothing
    return value
  # then float
  elseif (f = tryparse(Float64, value)) !== nothing
    isfinite(f) || throw(InvalidValueError("Non-finite numeric values are not supported. Please use a finite numeric value instead."))
    return value
  else
    throw(InvalidValueError("The value '$value' is not a valid number"))
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
        throw(InvalidValueError("The value must be 0, 1, true or false"))
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
        throw(InvalidValueError("The date $value is invalid: $(sprint(showerror, e))"))
    end
  else
    throw(InvalidValueError("The date $value is invalid"))
  end  
end
function format_date_sql(value)
  throw(InvalidValueError("The date must be a Date, DateTime, ZonedDateTime or a string in the format YYYY-MM-DD"))
end


# Precompiled once (issue #79): the datetime canonicalizer runs per row on bulk string
# inserts/filters, so avoid rebuilding the DateFormat / UTC zone on every call (the read
# path already uses a compile-time `dateformat"..."` macro — this keeps the write path parity).
const _DATETIME_DATEFORMAT = DateFormat(DATETIME_FORMAT)
const _DATETIME_UTC_TZ = TimeZone("UTC")

# Canonical UTC ISO-8601 form for DateTimeField values (issue #79): every equivalent
# instant collapses to ONE string (`yyyy-mm-ddTHH:MM:SS.sss+00:00`, = DATETIME_FORMAT),
# so SQLite's lexicographic TEXT comparison agrees with PostgreSQL's timestamptz instant
# comparison. Mirrors Django USE_TZ / Rails / SQLAlchemy. Idempotent.
_canonicalize_datetime_utc(value::ZonedDateTime)::String =
  Dates.format(astimezone(value, _DATETIME_UTC_TZ), _DATETIME_DATEFORMAT)

function format_timezone_sql(value::String; format::String=DATETIME_FORMAT)
  return validate_timezone(value, format)
end
function format_timezone_sql(value::Union{Missing, Nothing})
    return missing
end
function format_timezone_sql(value::ZonedDateTime)
  return _canonicalize_datetime_utc(value)
end
function format_timezone_sql(value::DateTime)
  # A naive DateTime is interpreted as UTC (matches Django USE_TZ default).
  return _canonicalize_datetime_utc(ZonedDateTime(value, _DATETIME_UTC_TZ))
end
function format_timezone_sql(value::DateTime, timezone::String)
  # Returns a ZonedDateTime (NOT a canonical string) — the migration planner re-feeds it
  # through the 1-arg ::ZonedDateTime method, which canonicalizes. Never used as a bind value directly.
  return ZonedDateTime(value, TimeZone(timezone))
end

function format_yyyy_mm(value::String)
  if occursin(r"^\d{4}-\d{2}$", value)
    return value
  else
    throw(InvalidValueError("The value $value is invalid, it must be in the format YYYY-MM"))
  end  
end
function format_yyyy_mm(value::Integer)
  value = string(value)
  if length(value) == 6
    # Format as YYYY-MM
    return string(value[1:4], "-", value[5:6])
  else
    throw(InvalidValueError("The value $value must be a 6-digit integer in the format YYYYMM or a string in the format YYYY-MM"))
  end
end
function format_yyyy_mm(value)
  throw(InvalidValueError("The value must be a String or Integer in the format YYYY-MM or YYYYMM"))
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
    catch e
      # A StackOverflowError / InterruptException signals corrupted or interrupted program state,
      # not an ordinary attribute mismatch — rethrow those so they surface loudly instead of being
      # masked as "changed". (A StackOverflowError here would be a symptom of the getproperty
      # recursion, issue #108, and must not be swallowed.)
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      # Otherwise fail SAFE, not open (issue #69). A schema-diff must never default to "equal" on an
      # unexpected comparison error: reporting "equal" means "no change", so a real field change
      # whose comparison throws would be silently dropped and no migration generated. Treat the
      # field as CHANGED (return false) so a migration is emitted, and log structured context
      # instead of swallowing. Worst case is an extra, visible migration — never a missed one.
      @warn "Model field comparison raised; treating field as changed so a migration is generated" field=field_name new_field_type=typeof(new_field) old_field_type=typeof(old_field) exception=e
      return false
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
  # Compare the referenced column by its RESOLVED physical name (fk_target_column), so a
  # field-name pk_field on the code side matches the introspected physical column when the
  # parent's pk field is renamed via db_column (#50). With no db_column this equals the
  # field name, so behavior is unchanged for existing schemas.
  if normalized_new_to == normalized_old_to && fk_target_column(new_field) == fk_target_column(old_field)
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

# #27: type predicate for JSON/JSONB columns, mirroring is_many_to_many_field. Used by the
# querybuilder to (a) treat a non-terminal JSON field path as a value extraction (data__key)
# rather than a join hop, and (b) gate the JSON containment operators (@>, ?, ?|, ?&).
is_json_field(::PormGField)::Bool = false
is_json_field(::sJSONField)::Bool = true

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
  throw(ModelDefinitionError("The model $(model_ref) referenced by a ManyToManyField is not defined"))
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
  throw(ModelDefinitionError("The model $(model_ref) referenced by a ManyToManyField is not defined"))
end

function _many_to_many_table_name(source_model::PormGModel, field_name::String, field::sManyToManyField, settings::PormGSettings)::String
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
  isempty(matches) && throw(ModelDefinitionError("The explicit through model $(through_model.name) has no foreign key to $(target_model.name) for the many-to-many $(role) side"))
  throw(ModelDefinitionError("The explicit through model $(through_model.name) has multiple foreign keys to $(target_model.name); set $(role)_field explicitly"))
end

function _relation_from_many_to_many(
  owner_model::PormGModel,
  owner_binding::String,
  field_name::String,
  field::sManyToManyField,
  related_model::PormGModel,
  related_binding::String,
  settings::PormGSettings;
  _module::Union{Module, Nothing}=nothing,
  model_map::Union{Nothing, Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}}=nothing,
)
  owner_pk_sym = get_model_pk_field(owner_model)
  related_pk_sym = get_model_pk_field(related_model)
  owner_pk_sym === nothing && throw(ModelDefinitionError("ManyToManyField $(owner_model.name).$(field_name) requires the source model to define a single primary key"))
  related_pk_sym === nothing && throw(ModelDefinitionError("ManyToManyField $(owner_model.name).$(field_name) requires the target model to define a single primary key"))

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
      throw(ModelDefinitionError("Cannot resolve explicit through model $(field.through) for $(owner_model.name).$(field_name)"))
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
    # #65: persist the already-resolved model objects (both sides arrive here resolved from either
    # load lifecycle) so the relation is a fully-resolved reference, not just strings.
    owner_model_resolved=owner_model,
    related_model_resolved=related_model,
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
    # #65: swap the resolved sides to match the swapped string fields above.
    owner_model_resolved=relation.related_model_resolved,
    related_model_resolved=relation.owner_model_resolved,
  )
end

function _cache_many_to_many_relation!(model::PormGModel, accessor::String, relation::ManyToManyRelation)
  cache = get!(model.cache, "many_to_many", Dict{String, Any}())
  cache[accessor] = relation
  return relation
end

function _register_many_to_many_relation!(_module::Module, settings::PormGSettings, model::PormGModel, field_name::String, field::sManyToManyField)::Nothing
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
  haskey(related_model.related_objects, reverse_accessor) && throw(ModelDefinitionError("The related_name $(reverse_accessor) in the model $(model.name) is already defined"))
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
  throw(ModelDefinitionError("The accessor $(accessor) is not a ManyToMany relation on model $(model.name)"))
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

function synthesize_many_to_many_through_models(current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, settings::PormGSettings)
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
          throw(ModelDefinitionError(
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
      throw(FieldValidationError("Invalid default value for $field_name. Expected type: $expected_type, got: $(typeof(default)). Please provide a value of type $expected_type."))
    end
  end
end

function validate_timezone(value::String, format::String)
  # Canonicalize any datetime string to one UTC ISO-8601 form (issue #79) so SQLite's
  # lexicographic TEXT comparison matches PostgreSQL. Accepts a `Z`/`±HH:MM` offset or a
  # naive value, a `T` or single-space separator, and 0-n sub-second digits; converts the
  # instant to UTC and formats as DATETIME_FORMAT (`yyyy-mm-ddTHH:MM:SS.sss+00:00`).
  s = replace(strip(value), ' ' => 'T', count = 1)
  # Julia's DateTime is millisecond-precision: truncate any sub-millisecond digits (e.g.
  # Python's microsecond `isoformat()`) so naive and offset spellings of the same instant
  # agree — the offset branch's normalize also truncates, so keep the naive branch aligned.
  s = replace(s, r"(\.\d{3})\d+" => s"\1")
  if occursin(r"(?:Z|[+-]\d{2}:\d{2})$", s)
    # Reject impossible offsets (issue #79 review): TimeZones silently normalizes e.g. `+25:00`
    # or `+00:60` into a shifted instant instead of erroring. An offset hour > 23 or minute > 59
    # cannot denote a real instant, so treat it as invalid (Z has no digits and is skipped).
    local off = match(r"[+-](\d{2}):(\d{2})$", s)
    if off !== nothing && (parse(Int, off[1]) > 23 || parse(Int, off[2]) > 59)
      throw(InvalidValueError("Invalid UTC offset (out of range) in datetime value: $value"))
    end
    # Offset-bearing: pad sub-seconds to exactly 3 digits (normalize_sqlite_datetime_string),
    # then parse — the `zzzz` token consumes both `Z` and `±HH:MM`.
    try
      zdt = ZonedDateTime(normalize_sqlite_datetime_string(s), _DATETIME_DATEFORMAT)
      return _canonicalize_datetime_utc(zdt)
    catch
      throw(InvalidValueError("Invalid timezone format. Expected format: $format, got: $value"))
    end
  else
    # Naive (no offset) is assumed UTC; Julia's default ISO parser handles `.s`/no-subsecond.
    try
      return _canonicalize_datetime_utc(ZonedDateTime(DateTime(s), _DATETIME_UTC_TZ))
    catch
      throw(InvalidValueError("Invalid timezone format. Expected format: $format, got: $value"))
    end
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