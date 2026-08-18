# I want recreate the Django models in Julia
module Models
using Dates, TimeZones
using Base64
using UUIDs
import JSON
import PormG: PormGField, PormGModel, reserved_words, MODEL_OPTION_KWARGS, Migration
# Physical-table-name resolution (#59) — defined in Kernel so layer-2 Configuration can reach it too.
import PormG: model_table_name, model_has_db_table
import PormG: DATETIME_FORMAT
import PormG: PormGBytes  # binary-payload wrapper the parameter collectors bind as one blob (#296)
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
public Model, UniqueConstraint, Index, set_models


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
| `name` | `Model(...)`, or `set_models` from the Julia binding | The table name. For a model you *declare* it is always lowercase — a positional name is rejected unless already lowercase (#300), a binding-derived one is lowercased as it is filled in. A model built by `inspectdb` introspection or the Django importer instead keeps the name read from its source, mixed case and all |
| `fields` | `Model(...)` | Declared field name → `PormGField`, including many-to-many fields |
| `field_names` | `Model(...)` | The subset that owns a real column — many-to-many fields are excluded |
| `related_objects` | `set_models` | Reverse accessors installed by relations pointing *at* this model: accessor name → a `ReverseRelation` (a foreign key on another model) or a `ManyToManyRelation` (a many-to-many, reversed). Each carries the resolved child model, so a reverse join never re-derives a Julia binding from a name (#343) |
| `_module` / `connect_key` | `set_models` | The defining module and the connection key it registered under |
| `cache` | `set_models`, `Model(constraints = …, indexes = …)` | Derived metadata: many-to-many relations, declared unique constraints, declared composite indexes |

`deepcopy` **shares** rather than clones (`deepcopy(model) === model`): a model is resolved schema
state treated as an immutable shared reference, and recursion would otherwise descend into
`_module::Module` and throw. The query builder relies on this — copying a query copies its state but
keeps the same model.

See also [`Model`](@ref), [`set_models`](@ref), [`UniqueConstraint`](@ref), [`Index`](@ref).
"""
@kwdef mutable struct Model_Type <: PormGModel
  name::AbstractString
  db_table::Union{String, Nothing} = nothing # explicit physical table name override (#59)
  fields::Dict{String, PormGField}
  field_names::Vector{String} = [] # needed to create sql queries with joins
  related_objects::Dict{String, Any} = Dict{String, Any}() # needed to create sql queries with joins
  _module::Union{Module, Nothing} = nothing # needed to create sql queries with joins
  connect_key::Union{String, Nothing} = nothing # needed to get the connection
  cache::Dict{String, Dict{String, Any}} = Dict{String, Dict{String, Any}}()
end

@kwdef struct ManyToManyRelation
  field_name::String
  # The PHYSICAL join table (#363) — `db_table` when the through model declares one, else the
  # derived/logical spelling. It was named `through_model` and carried the through model's LOGICAL
  # name on the explicit-`through=` branch, while all but one of its readers rendered it as a table:
  # `safe_table_identifier` in the four manager mutators, and both through-table slots in
  # `_insert_many_to_many_joins`. So an explicit through model with a `db_table` (every model from a
  # prefixed or multi-app Django import, #345/#346) made every read and write address a table that
  # does not exist. The name is now the contract: this slot is a table, never a model key. The one
  # reader that wanted a model reads `through_model_resolved` below instead.
  through_table::String
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
  # The explicit `through=` model, resolved (#363). Unlike the two slots above it has a live reader:
  # `QueryBuilder._m2m_has_extra_fields` needs the through model's FIELDS to decide whether the
  # direct mutators are allowed, and it used to recover them by re-resolving `through_model` as a
  # binding/logical name. That reflection is what made the slot's two meanings load-bearing at once;
  # recording the model the way #343 records `ReverseRelation.model_resolved` retires it.
  #
  # `nothing` here is a discriminated-union TAG — "there is no through model, the join table is
  # synthesized" — not the "resolution failed" nullability #343 argues against. That distinction is
  # what keeps the `=== nothing` branch out of the consumers: a synthesized join table is `id` + the
  # two FKs by construction (`synthesize_many_to_many_through_models`), so `nothing` answers the
  # extra-fields question outright rather than sending the caller back to a module scan. The tag is
  # exact: the slot is set on precisely the branch that resolves `field.through`, and that branch
  # throws when the reference cannot be resolved.
  #
  # REQUIRED on purpose, unlike its two neighbours — they default because #65 bolted them onto an
  # existing struct with no readers, whereas this one is the discriminant. A silent default would
  # let a future constructor mean "auto-generated" by omission, which is the fail-open hole #363
  # closed wearing a different hat.
  through_model_resolved::Union{PormGModel, Nothing}
end

# What `related_objects` stores for a REVERSE FOREIGN KEY accessor — the sibling of
# `ManyToManyRelation` above, and the other half of that Dict's value domain.
#
# It replaces a bare 4-tuple (#343). The tuple's third slot was the child's LOGICAL name, written
# through `get_model_name`, which lowercases unconditionally — so every consumer had to guess the
# Julia binding back with `uppercasefirst`, and that spelling can only ever be `Xxxxx`. A binding
# with an internal capital (`Dim_CNES`, `CustomUser`, `Cust_adminHOD`) was therefore unreachable in
# reverse, by ANY string function: since #300 the positional name is validated lowercase, so the
# information was not merely folded, it was never stored. Ten of 668 models across the consuming
# apps were affected, including a central dimension table.
#
# `model_resolved` is the fix: the child model is RECORDED at registration, where `set_models`
# already holds it as the loop variable, and READ at query time. It is deliberately NOT nullable —
# there is exactly one producer and it always has the model, so a nullable slot would only invite a
# `=== nothing` fallback back into the consumers, which is the bug wearing a hat.
#
# `binding` has no reader in `src/` today, and that is a deliberate exception to the rule that killed
# the old 4th slot below. The difference is recoverability: `child_pk` is derivable from the model at
# any time, whereas the binding is derivable from NOTHING once registration ends — that is the whole
# content of #343. It is the reverse-side counterpart to `ManyToManyRelation`'s
# `owner_binding`/`related_binding`, and it is the spelling a diagnostic or a code generator has to
# print for a user to be able to type it (`M.Dim_CNES`). Dropping it would re-create the hole.
#
# The old tuple's 4th slot (the child's own pk) is gone: nothing in `src/` ever read it, and it is
# now derivable as `get_model_pk_field(rel.model_resolved)`. Storing a derived value nothing reads is
# how the 3rd slot rotted in the first place.
@kwdef struct ReverseRelation
  fk_field::Symbol            # the FK column on the CHILD model
  target_pk::Symbol           # the column on the PARENT (this Dict's owner) that the FK references
  model_name::Symbol          # the CHILD's LOGICAL name: django_prefix-stripped and lowercased
  binding::Symbol             # the CHILD's Julia binding in `_module` — the #343 fix
  model_resolved::PormGModel  # the CHILD model itself
end

# Single constructor for the three `set_models` branches (>=2 FKs to one target, 1 FK with an
# implicit accessor, 1 FK with an explicit `related_name`). They differ only in the Dict KEY they
# store under; the relation itself is identical, and before #343 that identity was three copies of
# one tuple literal. `Symbol(field.pk_field)` reproduces the old `field.pk_field |> Symbol` exactly,
# including the `:nothing` degenerate for a pk_field `resolve_fk_target!` could not default.
_reverse_relation(child::PormGModel, model_name::Symbol, binding::Symbol,
                  fk_field_name::AbstractString, field::PormGField) =
  ReverseRelation(
    fk_field       = Symbol(fk_field_name),
    target_pk      = Symbol(field.pk_field),
    model_name     = model_name,
    binding        = binding,
    model_resolved = child,
  )

# A Model_Type is resolved schema state — its `fields`, `_module`, and `related_objects` are built once
# by `set_models` and treated as an immutable, SHARED reference everywhere (the query builder copies query
# state but shares the model verbatim: `SQLObjectQuery` deepcopy sets `model=obj.model`). Deep-copying a
# model is never wanted and, worse, throws: the moment recursion reaches a relation field's resolved
# `.to` (another Model_Type) it descends into `_module::Module` → "deepcopy of Modules not supported".
# Override the recursion hook to SHARE — return the same model, registered in `stackdict` so its identity
# is stable across the surrounding copy. So `deepcopy(model) === model`, and any container/field that
# holds a model shares it rather than cloning the schema graph. Resolves the module-traversal throw (#157).
#
# This one hook is also what makes BOTH relation structs above deep-copy correctly, with no override
# of their own: they are immutable, every other field is a Symbol/String/Bool, and their resolved-model
# slots land here and are shared. So Base's default rebuilds a relation whose every field is `===` the
# original's — and `===` on an immutable is field-wise egality, hence `deepcopy(rel) === rel`.
# #65 shipped a hand-written `deepcopy_internal(::ManyToManyRelation, …)` that did this by hand; #157
# added the hook below, which superseded it, and #343 removed it. Do not reintroduce one for a new
# relation struct without first checking whether the default already does the job.
Base.deepcopy_internal(m::Model_Type, stackdict::IdDict) = get!(stackdict, m, m)

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
  seen_names = Set{Symbol}()
  for name in names(modules; all=true, imported=true)
    push!(seen_names, name)
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
  # #354: Miss-path second pass for `using`-scoped models (invisible to `imported=true`).
  for name in names(modules; all=true, imported=true, usings=true)
    Base.binding_module(modules, name) === Base && continue
    name in seen_names && continue
    attr = try
        Base.invokelatest(getfield, modules, name)
    catch
        nothing
    end
    if isa(attr, PormGModel)
      symbol && (name in model_names) && continue
      !symbol && any(m === attr for m in model_names) && continue
      if attr.name == ""
        attr.name = name |> format_model_name
      end
      push!(model_names, symbol ? name : attr)
    end
  end
  return model_names
end

# Two passes, two outputs: the model vector `set_models` iterates, and the model → binding map it
# records into `ReverseRelation.binding` (#343).
#
# Split from `get_all_models` rather than folded into its `symbol` kwarg, which returns the Symbol
# XOR the model and so can never express the PAIRING. Kept separate from `_find_model_binding_name`
# too, deliberately: that helper is an O(N) identity scan, and calling it once per foreign key across
# a real app's ~670 models is ~450k `invokelatest` calls per `set_models`. Here the binding is simply
# not thrown away in the first place.
#
# Airtight by construction: every `push!(models, ...)` is paired with a `get!(bindings, ...)` in
# both passes, so every model in `models` is a key of `bindings`. The second pass (#354) catches
# `using`-scoped models invisible to `imported=true`, filtered by `Base.binding_module` to avoid
# sweeping in ~1100 implicit `Base` names.
#
# `get!` keeps the FIRST binding when one model object is bound under several names, matching
# `_find_model_binding_name`; `names` returns sorted symbols, so that choice is deterministic.
function _collect_models_and_bindings(modules::Module)
  models = PormGModel[]
  bindings = IdDict{PormGModel, Symbol}()
  seen_names = Set{Symbol}()
  for name in names(modules; all=true, imported=true)
    push!(seen_names, name)
    # Use invokelatest to avoid World Age issues in Julia 1.12+
    attr = try
        Base.invokelatest(getfield, modules, name)
    catch
        nothing
    end
    isa(attr, PormGModel) || continue
    # Same binding-derived name fill as `get_all_models` — load-bearing for `Model(; fields...)`,
    # which leaves `name` empty and relies on registration to derive it from the binding.
    if attr.name == ""
      attr.name = name |> format_model_name
    end
    push!(models, attr)
    get!(bindings, attr, name)
  end
  # #354: Miss-path second pass for `using`-scoped models (invisible to `imported=true`).
  # Filtered by `Base.binding_module` to exclude implicit `using Base` names.
  for name in names(modules; all=true, imported=true, usings=true)
    Base.binding_module(modules, name) === Base && continue
    name in seen_names && continue
    attr = try
        Base.invokelatest(getfield, modules, name)
    catch
        nothing
    end
    isa(attr, PormGModel) || continue
    haskey(bindings, attr) && continue
    if attr.name == ""
      attr.name = name |> format_model_name
    end
    push!(models, attr)
    get!(bindings, attr, name)
  end
  return models, bindings
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

# The connection's Django app label, or `nothing` when there is none (#345). An EMPTY string is not a
# prefix — it is the absence of one, spelled badly. The distinction matters because `Settings` is
# populated generically from `connection.yml`'s `config:` block (`hasfield(Settings, Symbol(k))` ->
# `setfield!`), so `django_prefix: ''` reaches this field, and every consumer composes
# `"$(prefix)_"`. Treating `""` as set derives `_dim_uf` for a table named `dim_uf`, and strips a
# bare `"_"` from every logical name. Before #345 the first of those was at least loud — the
# generated `Model("_dim_uf", …)` was rejected at include time by the leading-underscore guard — but
# with the prefix moved into `db_table` the file loads and every query silently reads `_dim_uf`.
function _django_app_label(settings::PormGSettings)::Union{Nothing, String}
  prefix = settings.django_prefix
  (prefix === nothing || isempty(prefix)) && return nothing
  return String(prefix)
end

function get_model_name(model::PormGModel, settings::PormGSettings, symbol::Bool=true)::Union{String, Symbol}
  value::Union{String, Symbol, Nothing} = nothing
  app_label = _django_app_label(settings)
  if app_label !== nothing
    django_prefix = """$(app_label)_"""
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

# ── Registration-time contradiction collector (#303) ────────────────────────────────────────
# A field declaration can contradict itself in ways only registration can see, and a database
# introspected into models can carry several at once — #292 taught PostgreSQL introspection to
# emit `on_delete` for the first time, so a legacy schema now arrives with every one of its
# SET_NULL/SET_DEFAULT mismatches intact. Both shapes are legal DDL on both backends (the
# referential action is only enforced at delete time), so they really do coexist in the wild.
# Throwing on the first turned N problems into N generate → set_models → fix one column →
# regenerate cycles, for problems that were all visible on the first pass. So `set_models`
# ACCUMULATES and raises once, with the whole list.
#
# The struct is deliberately rule-agnostic: WHERE (model, field), WHAT (`problem`), and the
# REMEDY (`fix`). It knows nothing about `on_delete`. Adding a rule is one `push!` — the struct,
# the sort key and the renderer are all untouched. It is a struct rather than a vector of
# pre-rendered sentences because a frozen sentence has no sort key and no format seam: changing
# the layout, or letting a future `check_models()`-style API consume the data, would become a
# shotgun edit across every rule.
#
# The one shape not covered is a MODEL-level rule (e.g. the multiple-primary-key check in
# `get_model_pk_field`): it would need a `field == ""` convention plus a one-line ternary in the
# renderer. Not built now — that check is raised from a different function and would be a larger
# change regardless.
struct ModelContradiction
  model::String    # model.name — where the offending field lives
  field::String    # the offending field's declared name
  problem::String  # "declares on_delete SET_NULL but has null=false"    (may carry ANSI)
  fix::String      # "Declare the field with null=true, or use ..."      (may carry ANSI)
end

# Per-field contradiction rules. Runs for every FK/O2O field `set_models` walks; each rule that
# fires appends one `ModelContradiction`. NOTHING throws here — that is the point: the walk always
# reaches the next field and the next model. Today the two rules are mutually exclusive (`on_delete`
# holds one sentinel), so a field yields at most one entry; the collector does not assume that, so a
# future rule family can add a second entry for the same field without changing this signature.
#
# `field` is left untyped for the same reason `resolve_fk_target!`'s is: `sForeignKey` and
# `sOneToOneField` are defined later in the load order (`models/fields.jl`). The only call site
# already guards with `field isa sForeignKey || field isa sOneToOneField`.
#
# `src/querybuilder/deletion.jl` keeps its own copies of both rules, for models that never pass
# through registration. Those stay per-field and IMMEDIATE on purpose — read the comment there
# before considering a merge.
function _collect_field_contradictions!(out::Vector{ModelContradiction},
                                        model::PormGModel, field_name::AbstractString, field)
  # SET_NULL needs a column that can hold NULL. Until #287 this was an `@error` log: it named the
  # problem, let the broken model through, and the contradiction resurfaced later as a mangled
  # UPDATE or a database-level constraint violation.
  if field.on_delete == SET_NULL && field.null == false
    push!(out, ModelContradiction(model.name, field_name,
      "declares on_delete SET_NULL but has null=false",
      "Declare the field with \e[1mnull=true\e[0m, or use a different on_delete."))
  end
  # The mirror image: SET_DEFAULT needs something to set. With no default, `field.default` flows
  # into update_field as a bare NULL, so SET_DEFAULT silently behaved as SET_NULL and then died
  # on the column's NOT NULL constraint.
  if field.on_delete == SET_DEFAULT && field.default === nothing
    push!(out, ModelContradiction(model.name, field_name,
      "declares on_delete SET_DEFAULT but has no default",
      "Give the field a \e[1mdefault=\e[0m, or use a different on_delete."))
  end
  return out
end

"""
    _render_contradictions(cs::Vector{ModelContradiction}, mod::Module) -> String

Compose every collected contradiction into ONE error message (#303). Returns the `String`; the
call site wraps it in `ModelDefinitionError` so the thrown type is named where it is thrown (see
`src/querybuilder/error_funnels.jl` — a helper that only maps a message to a type is an alias,
not an abstraction).

**Ordering is fixed here, not by the caller.** `set_models` walks `pairs(model.fields)`, which is
`Dict` hash order and carries no meaning, so entries are sorted by `(model, field, problem)`
before rendering. The third key is forward-looking rather than load-bearing today: `(model, field)`
is already unique, because the two current rules are mutually exclusive on one field — but it keeps
the order *total*, so a future rule family that can fire alongside them stays byte-stable without
revisiting this. `model.field_names` is deliberately NOT the order — it defaults to empty on a
hand-built `Model_Type` and is itself hash-ordered from the `Model(name, ::Dict)` constructors, so
it is a meaningful order only sometimes. `sort` (not `sort!`) because this runs on the error path and must not reorder a vector
the caller — or a debugger stopped at the throw — still holds.

The line prefix stays ANSI-free on purpose: `showerror` prints `.msg` verbatim and `.msg` keeps
its escapes in color mode, so an escape wedged into the prefix would break anything matching on
line structure.

Pure — no globals, no side effects — so the ordering guarantee is unit-testable by handing it
contradictions in deliberately wrong order (`test/unit/test_alignment_sqlite.jl`). That test is
the only thing that fails if the sort is dropped: `Dict` iteration is deterministic for a fixed
insertion sequence, so going through `set_models` would not reliably notice.
"""
function _render_contradictions(cs::Vector{ModelContradiction}, mod::Module)::String
  ordered = sort(cs; by = c -> (c.model, c.field, c.problem))
  n = length(ordered)
  header = n == 1 ?
    "set_models($(nameof(mod))) rejected the models: 1 contradictory field declaration." :
    "set_models($(nameof(mod))) rejected the models: $(n) contradictory field declarations — " *
    "every one found is listed below, so they can be fixed in a single pass."
  return header * join("\n  → \e[4m\e[31m$(c.model).$(c.field)\e[0m $(c.problem) — " *
                       "the schema contradicts itself. $(c.fix)" for c in ordered)
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
   mangled `UPDATE`. **Every** such contradiction in the module is collected and reported in that
   one error, naming each offending model, field and fix, so a legacy schema carrying several of
   them is diagnosed in a single pass instead of one registration per field (#303). Only these two
   are aggregated: every *other* registration error — an unresolvable foreign-key or many-to-many
   target, a duplicate `related_name`, a model without exactly one primary key, an unusable
   explicit `through` model — raises the same type but still on the first occurrence, and preempts
   the aggregated report when present.

   Because the aggregated throw comes after every model is wired, a **swallowed** failure leaves a
   fully-wired, queryable graph. The `__init__` that `@import_models` and `@models_module` inject,
   and the Revise reload callback, all `catch` — though the first load of either macro still
   surfaces the error. `delete()` keeps its own copy of both checks, and that is what still raises
   for a contradiction the caller never saw.

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
  # #343: one walk yields the models AND their Julia bindings. The binding cannot be recovered later
  # from a model — `name` is validated lowercase (#300) — so it is captured here or it is lost.
  models, bindings = _collect_models_and_bindings(_module)

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
  # #303: self-contradicting field declarations are ACCUMULATED across every model and every
  # field, then raised once below. See `_render_contradictions` for the ordering contract.
  contradictions = ModelContradiction[]

  # Validate like django related_name, if the model has more than one foreign key to the same model the related_name must be defined
  for model in models
    dict_tables_c = Dict{String, Int}()
    dict_tables_fiels = Dict{String, Vector{String}}()
    model.connect_key = connect_key
    # Hoisted: both describe the CHILD (`model`) and are identical for every FK it declares. The
    # logical name was recomputed per field before #343, inconsistently — sometimes inline, sometimes
    # into a local of the same name.
    model_name = get_model_name(model, settings)::Symbol
    model_binding = bindings[model]
    # @pormg_debug model.name == "dash_tab_cvat"
    # println(model.name)
    for (field_name, field) in pairs(model.fields)
      if field isa sForeignKey || field isa sOneToOneField
        # #65: single-sourced FK/O2O resolution + pk_field defaulting, shared with the migration
        # prelude via `resolve_fk_target!`. strict=true throws on an unresolvable target, so the
        # returned value is always a resolved model here; it drives the reverse-relation wiring below.
        #
        # This one stays IMMEDIATE and out of #303's collector, permanently. Structurally, the
        # return drives every line of wiring below it, so collecting would mean strict=false plus a
        # `continue` that silently skips it — and it would change how the runtime path uses a helper
        # SHARED with the migration prelude (`planner.jl` calls it strict=false). Semantically, a
        # missing referent is not a contradiction between two settings on one field: the model graph
        # cannot be built at all, so walking on produces cascading noise, not more signal.
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
            field.related_name = string(model_name, "_", field_name) |> lowercase
            @info("The field $field_name in the model $(model.name) is a ForeignKey and the related_name is not defined, so the related_name was set to $(field.related_name)")
          end
          if haskey(field_to.related_objects, field.related_name)
            throw(ModelDefinitionError("The related_name $(field.related_name) in the model $(model.name) is already defined"))
          else
            field_to.related_objects[field.related_name] = _reverse_relation(model, model_name, model_binding, field_name, field)
          end
        elseif dict_tables_c[field_to.name] == 1
          @pormg_debug false
          if field.related_name === nothing
            field_to.related_objects[model_name |> string] = _reverse_relation(model, model_name, model_binding, field_name, field)
          else
            if haskey(field_to.related_objects, field.related_name)
              throw(ModelDefinitionError("The related_name $(field.related_name) in the model $(model.name) is already defined"))
            else
              field_to.related_objects[field.related_name] = _reverse_relation(model, model_name, model_binding, field_name, field)
            end
          end
        end
        
        # check on_delete — a schema that contradicts itself is rejected at registration (#287).
        # These were `@error` logs until #287: they named the problem and then let the broken model
        # through, so the contradiction resurfaced later as a mangled UPDATE or a database-level
        # constraint violation. The delete collector keeps its own copies of both guards for models
        # that never pass through `set_models`; this is the layer that catches them at declaration.
        #
        # #303 COLLECTS instead of throwing, so ONE run reports every contradiction in the module.
        # Nothing after this line depends on the result — the reverse-relation wiring above is
        # already done — so a field that fails here still leaves the model graph in exactly the
        # state a clean run would produce.
        _collect_field_contradictions!(contradictions, model, field_name, field)

      elseif is_many_to_many_field(field)
        _register_many_to_many_relation!(_module, settings, model, field_name, field)
      end
    end
  end

  # Registration FAILS — informatively, not downgraded to a warning (#303). Deferring the throw to
  # here means every model is wired before it fires, which is strictly more wiring than the
  # pre-#303 mid-loop abort did. That is safe: the wiring performed is exactly what a SUCCESSFUL
  # run performs (no half-state a success would not also produce), and every `set_models` call
  # `empty!`s `related_objects` and drops the many-to-many cache before rebuilding (see the loop
  # above), so a re-run cannot accumulate.
  #
  # One consequence worth knowing, because it is uniform now rather than order-dependent: every
  # model comes out of a run that fails HERE with a valid `connect_key`, so
  # `ensure_model_initialized`'s fast path reports it initialized. Pre-#303 that depended on whether
  # the model happened to be walked before the throwing one — i.e. on Dict/`names` order. (A run
  # that fails at one of the earlier in-loop throws still leaves the models after it unbound.)
  # So a caller that swallows this throw — the `__init__` injected by `@import_models` /
  # `@models_module`, or the Revise reload callback — is left with a fully-wired, queryable graph
  # rather than a partly-wired one, and `deletion.jl`'s own copies of these two guards are what
  # still catch the contradiction at delete time.
  isempty(contradictions) ||
    throw(ModelDefinitionError(_render_contradictions(contradictions, _module)))

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

# Validate a field-name REFERENCE and return it verbatim. The declared case is PRESERVED (#57): a
# field declared `driverId` keeps that case as its identity and its column name, so PormG can
# faithfully target mixed-case/uppercase DB columns. Table/model names still lowercase — see
# `format_model_name` below.
#
# It used to strip ONE leading underscore, the escape hatch that let a column whose name is a Julia
# keyword be declared as a kwarg (`_end = CharField()` -> column `end`). #317 retired that: `db_column`
# (#50) states the same thing explicitly, and the strip had already cost two bugs (#306, and the
# `Model_to_str` output that would not reload, patched in #316).
#
# This function is now a pure pass-through validator, and the rejection of a leading underscore
# deliberately does NOT live here. Every caller other than the declaration paths is a REFERENCE to an
# existing field key — `pk_field` (`src/models/fields.jl`), `UniqueConstraint` fields,
# ManyToMany `source_field`/`target_field`, and `_normalize_row_symbol` on the row-read path
# (`src/querybuilder/types.jl`). A model built from a `Dict` (the `inspectdb` / Django-importer paths)
# may legitimately be keyed `_id`, and every one of those references must resolve to it. Throwing here
# would also surface a `ModelDefinitionError` out of `row._id`, which is a read, not a definition.
# The declaration guard is `_validate_declared_field_name` below.
#
# `__` and `@` are still rejected: `__` is the lookup separator (`driverid__surname`) and `@` the
# operator marker, so a field spelled with either is unqueryable regardless of the hatch.
function format_fild_name(name::String)::String
  isempty(name) && return name
  if occursin(r"__|@", name)
    throw(ModelDefinitionError("The field name $name contains __ or @; this is not allowed"))
  end
  return name
end
function format_fild_name(name::Nothing)::Nothing
  return nothing
end
format_fild_name(name::Symbol)::String = name |> String |> format_fild_name

# Table/model names are LOWERCASED (frozen schema convention, #33) — independent of field-name case
# preservation (#57). A pure fold, nothing more.
#
# It used to be `lowercase ∘ format_fild_name`, inheriting the leading-underscore strip — which is
# exactly what split #306: `Model("_order", …)` created table `_order` while a `ForeignKey` targeting
# it rendered `REFERENCES "order"`. With the strip gone (#317) both sides render `_order` and the
# split is unreachable. It also carries NO validation: every caller runs at render/compare time on a
# name that may have been read out of a live database (`fk_target_table` for an unresolved String
# target, the model-reference comparisons, the ManyToMany table/accessor derivations, and the two
# `get_all_models` implementations that fill a blank name from the Julia binding). Shape policy lives
# at declaration time, in `_validate_positional_model_name` below.
function format_model_name(name::String)::String
  return lowercase(name)
end
function format_model_name(name::Symbol)::String
  return name |> String |> format_model_name  
end
function format_model_name(name::PormGModel)::String
  return name.name |> format_model_name
end

# A POSITIONAL model name must already be lowercase (#300) and must not start with '_' (#306). It is
# the one identifier in a `Model(...)` call that nothing normalizes: the two callers that FILL
# `Model_Type.name` run it through `format_model_name` but guard on `attr.name == ""`, so they only
# ever reach a binding-derived name (`src/Models.jl` `get_all_models`, `src/migrations/planner.jl`
# `get_all_models`), which `format_model_name` lowercases as it fills it. Field names get their own
# declaration-time gate, `_validate_declared_field_name` below.
#
# Left unchecked, a mixed-case name SPLITS the schema — `makemigrations` lowercases it into the DDL
# while the query builder quotes it as declared — so the model migrates one table and then queries
# another: silent on SQLite, fatal on PostgreSQL (#300).
#
# A LEADING UNDERSCORE is rejected too (#306), now on its own footing. It was originally rejected
# because it split the schema the same way: `format_model_name` stripped one underscore when rendering
# an FK `REFERENCES` target while `create_table` wrote the stored name verbatim, so `Model("_order", …)`
# created `_order` and referenced `order`. #317 retired that strip, so both sides now render `_order`
# and THAT split is unreachable. The rejection stands as policy, not as a bug guard: a PormG model name
# is a lowercase LOGICAL identifier, and a leading underscore is not a shape PormG generates — exactly
# the same reasoning as the case rule above. A physical table that does have one is named with
# `db_table` (#59), which carries it verbatim.
#
# Scope: this checks CASE and a LEADING UNDERSCORE only. It is NOT `format_model_name`, which is now a
# pure `lowercase` fold applied to STORED names at render time, and it applies no other
# identifier-shape validation — a reserved word or a name with a space still renders invalid bare DDL.
#
# Reject rather than fold, in both cases — even now that `db_table` (#59) exists as the escape valve.
# Folding here would still discard a stated intent silently; `db_table` is how that intent gets
# expressed instead: `Model("driver_races", db_table = "Driver_Races", …)`.
#
# `hint` is computed underscore-aware, and stripping is `lstrip(…, '_')` (ALL leading underscores, not
# one), so whichever check fires first the suggested spelling already passes both. It can come out
# EMPTY — `"_"`, `"___"` — and an unusable `"Declare it as ''."` is worse than no suggestion, so both
# messages omit that clause when `hint` is empty (found on independent review of #306; the underlying
# names changed but the message-accuracy requirement did not).
function _validate_positional_model_name(name::AbstractString)::Nothing
  hint = lstrip(lowercase(name), '_')
  declare_as = isempty(hint) ? "" : " Declare it as '$(hint)'."
  if name != lowercase(name)
    throw(ModelDefinitionError(
      "The model name '$(name)' must be lowercase; PormG lowercases table names when generating DDL " *
      "but quotes them as declared in queries, so this model would migrate the table " *
      "'$(lowercase(name))' and then query '$(name)'.$(declare_as) " *
      "Mapping a model to a fixed mixed-case table: pass db_table = '$(name)' instead."))
  end
  if startswith(name, "_")
    throw(ModelDefinitionError(
      "The model name '$(name)' starts with '_'; a PormG model name is a lowercase logical " *
      "identifier and never carries one.$(declare_as) If the physical table really is named " *
      "'$(name)', pin it explicitly: Models.Model(\"$(isempty(hint) ? "table" : hint)\", " *
      "db_table = \"$(name)\", …). A leading underscore used to be the escape hatch for FIELD names " *
      "colliding with a Julia keyword; that was retired in #317 in favour of db_column, and it never " *
      "applied to model names — a positional name is a plain string, never a Julia kwarg key."))
  end
  return nothing
end

# A DECLARED field name — one written as a Julia keyword argument in a `Model(...)` call, or passed to
# `add_field!` — must not start with '_' (#317). Scope-disciplined exactly like
# `_validate_positional_model_name` above: it checks a leading underscore and NOTHING else. Shape
# validation is deliberately absent, mirroring `db_column`'s own precedent (`_apply_db_table!`), so
# `var"end" = CharField()` — Julia's native non-standard identifier — keeps working.
#
# Deliberately NOT applied to the two `Dict`-taking `Model` methods, for the same reason
# `_validate_positional_model_name` is not: those are how `inspectdb` introspection and the Django
# importer build a model from names read out of a live database or a Python class, where `_id` is a
# legitimate physical column and must pass through untouched.
#
# The message names BOTH readings, because `_end` was genuinely ambiguous under the old hatch — a
# reader cannot tell whether the author meant the column `end` or the column `_end`, and picking one
# silently is how the hatch cost its bugs.
function _validate_declared_field_name(name::AbstractString, model_name::AbstractString)::Nothing
  startswith(name, "_") || return nothing
  bare  = lstrip(name, '_')
  ident = isempty(bare) ? "col" : (bare in reserved_words || bare in MODEL_OPTION_KWARGS ? "$(bare)_" : bare)
  on    = isempty(model_name) ? "" : " on model '$(model_name)'"
  throw(ModelDefinitionError(
    "The field name '$(name)'$(on) starts with '_'. One leading underscore used to be the escape " *
    "hatch for a column whose name is a Julia keyword — `_end = CharField()` declared the column " *
    "`end` — retired in #317 because db_column (#50) states the same thing explicitly and composes " *
    "with db_table (#59). Declare the column you meant:\n" *
    "  • for the column '$(bare)': $(ident) = Models.CharField(db_column = \"$(bare)\")\n" *
    "  • for a column literally named '$(name)': $(ident) = Models.CharField(db_column = \"$(name)\")"))
end

# Pick a legal, collision-free Julia identifier for `column` when generating a model file
# (`Model_to_str`, #317). The real column is pinned by the caller with `db_column`, so this only has to
# produce something that (a) parses as a keyword-argument name, (b) is not peeled as a model option,
# and (c) is unique within the model.
#
# `taken` accumulates names already emitted for this model; `raw_keys` is the model's FULL key set,
# captured BEFORE the loop — without it a sanitized name could steal a column that appears later in
# the sorted iteration (`_id` -> `id` when the model also has a real `id`).
#
# Step 4 appends a DIGIT, never another '_': `end_` + `_` is `end__`, which `format_fild_name` rejects
# as the lookup separator.
function _julia_field_identifier(column::AbstractString,
                                 reserved::Vector{String},
                                 taken::Set{String},
                                 raw_keys::Set{String})::String
  col = String(column)
  # Fast path: a column that is ALREADY a legal declaration keeps its own name, so the common case
  # emits no `db_column` at all. "Legal" here is exactly what the kwargs constructor accepts —
  # `format_fild_name`'s `__`/`@` rejection and `_validate_declared_field_name`'s leading underscore,
  # plus what Julia itself will parse as a keyword-argument name.
  legal = Base.isidentifier(col) && !startswith(col, "_") && !occursin("__", col) &&
          !(col in reserved) && !(col in MODEL_OPTION_KWARGS)
  base = if legal
    col
  else
    b = lstrip(col, '_')
    # Collapse each RUN of non-identifier characters to a single '_' — a one-for-one substitution
    # would turn `a@@b` into `a__b`. Unicode letters and digits are kept: Julia identifiers allow
    # them, so `posição` needs no mangling.
    b = replace(b, r"[^\p{L}\p{Nd}_]+" => "_")
    # `__` is the lookup separator, so it is illegal in a DECLARED name even though it is a perfectly
    # good Julia identifier — squeeze runs of '_' after the substitution above, which can itself
    # create them.
    b = replace(b, r"_{2,}" => "_")
    b = strip(b, '_')
    # A Julia identifier cannot START with a digit, and `2fast_` would still be illegal — prefix,
    # don't suffix.
    (isempty(b) || occursin(r"^\p{Nd}", b)) && (b = "col_$(b)")
    b = rstrip(b, '_')
    isempty(b) ? "col" : String(b)
  end
  # `Base.isidentifier` accepts keywords (`isidentifier("end")` is `true`), so the reserved-word and
  # model-option checks are separate from it, not covered by it.
  ident = (base in reserved || base in MODEL_OPTION_KWARGS) ? "$(base)_" : base
  # Belt and braces for anything the filters above did not anticipate; `col` is always legal.
  Base.isidentifier(ident) || (base = "col"; ident = "col")
  # `ident != col` guards the no-op case: a name that needed no sanitizing keeps its own key, it just
  # must not collide with something already emitted.
  suffix = 2
  while ident in taken || (ident != col && ident in raw_keys)
    ident = "$(base)$(suffix)"
    suffix += 1
  end
  return ident
end

# Disambiguate `ident` against names already claimed elsewhere in the same generated file (#338),
# appending a digit — never another underscore, matching `_julia_field_identifier`'s convention.
# Unlike that function, this has no `raw_keys`-style second concern: a generated file has exactly
# one binding and one positional name per model, not a set of columns a rename must not steal from.
function _dedupe_taken(ident::String, taken::Set{String})::String
  base = ident
  suffix = 2
  while ident in taken
    ident = "$(base)$(suffix)"
    suffix += 1
  end
  return ident
end

"""
    _model_binding_name(name, contants_julia) -> String

The Julia BINDING `Model_to_str` will emit for a model called `name` — derivation only, with no
dedup and no registration. Extracted (#346) because the Django importer has to know the binding of
every class **before** it renders the first one: a cross-app `ForeignKey("core.Pessoa")` is rewritten
to the target's binding, and the target may be rendered later in the same file. Two expressions
computing this would be exactly the drift the `isidentifier` guard below exists to prevent, so there
is one, and both callers use it.

The binding must be a legal Julia identifier. `uppercasefirst` alone is not enough once the name can
come from a live table: `inspectdb` on `2fast` or `driver profile` produced source that does not
parse. Fall back to the field sanitizer only when it is not already legal.

The `isidentifier` guard is load-bearing, not an optimization. A child's `ForeignKey` `.to` names the
parent's BINDING and `_resolve_target_model` resolves it by BINDING LOOKUP alone — no name or table
fallback — so the binding and `.to` must be the same expression. Sanitizing unconditionally silently
broke that for every name `uppercasefirst` already made legal: `end` -> `End_` vs `.to = "End"`,
`db_table` -> `Db_table_` vs `Db_table`, `_order` -> `Order` vs `_order`.

Since #360 the introspection sites (`src/migrations/introspection.jl`) call THIS function rather than
bare `uppercasefirst`, so both sides agree for hostile names too, and the importers' pass 1
(`_plan_inspectdb_bindings!`) then rewrites `.to` to the target's final, collision-deduped binding.

A binding is a variable name, so neither the keyword list nor the model options apply to it —
`uppercasefirst` alone escapes every Julia keyword, since they are all lowercase.

`isidentifier` is necessary but NOT sufficient: `Base.isidentifier("_")` is `true`, yet an
ALL-underscore identifier is write-only in Julia — `_ = Model(…)` assigns and then `getfield(mod, :_)`
raises `UndefVarError`. A table named `_` would generate a file that loads and leaves the model
permanently invisible to every binding-based lookup, with no error anywhere. `_order` is fine; only a
name with nothing left after `lstrip` is not.
"""
function _model_binding_name(name::AbstractString, contants_julia::Vector{String}=reserved_words)::String
  plain = uppercasefirst(String(name))
  return (Base.isidentifier(plain) && !isempty(lstrip(plain, '_'))) ? plain :
    uppercasefirst(_julia_field_identifier(String(name), contants_julia, Set{String}(), Set{String}()))
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

# `model_table_name` / `model_has_db_table` (#59) — the table-level mirror of `field_db_column`
# above — live in `Kernel` and are imported at the top of this module, because layer-2
# `Configuration` needs them and is included before `Models`. See Kernel.jl for the definitions.

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

# Referenced (parent) physical TABLE for a ForeignKey (#59) — the table-level sibling of
# fk_target_column above. A resolved PormGModel target goes through model_table_name (so it
# honors the target's db_table); a still-unresolved String target falls back to
# format_model_name, matching fk_target_column's own verbatim-fallback shape for that case.
function fk_target_table(field::PormGField)::String
  tgt = field.to
  return tgt isa PormGModel ? model_table_name(tgt) : format_model_name(tgt)
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
# keys read off a `ReverseRelation` (#50). A strict no-op without db_column.
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
#
# `label` names the declaring type in the error message; `Index` (#347) shares this helper with
# `UniqueConstraint`, and a message that named the wrong one would send the reader to the wrong
# declaration.
_normalize_constraint_fields(f::Union{Symbol, AbstractString}, label::AbstractString = "UniqueConstraint")::Vector{String} = String[format_fild_name(String(f))]
function _normalize_constraint_fields(f, label::AbstractString = "UniqueConstraint")::Vector{String}
  out = String[]
  for x in f
    (x isa Symbol || x isa AbstractString) ||
      throw(ModelDefinitionError("$(label) fields must be Symbol or String, got $(typeof(x))"))
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
  # A non-iterable value is `constraints = Models.CharField()` — a column named `constraints`, eaten
  # by the option peel. Name the option and the fix instead of raising a bare `MethodError:
  # no method matching iterate(::sCharField)` (#347; the `indexes` sibling below carries the same).
  applicable(iterate, cs) || throw(ModelDefinitionError(
    "`constraints` must be a UniqueConstraint or a collection of them, got $(typeof(cs)). " *
    "`constraints` is a model-level option, so a COLUMN of that name must be pinned with " *
    "db_column: other_name = Models.CharField(db_column = \"constraints\")"))
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
# SECTION: Model-level indexes (composite, non-unique · #347)
#═══════════════════════════════════════════════════════════════════════════════
# A plain INDEX spanning one or more columns — Django's `Meta.indexes`. Declared via the
# `indexes=` kwarg on `Model(...)`; materialized by the migration planner as a `CREATE INDEX`
# (identical on PostgreSQL and SQLite), reusing the very `Dialect.create_index` primitive the
# per-field `db_index=true` path already calls — that one simply never passes more than one
# column. `name === nothing` ⇒ the planner derives `<table>_<cols>_idx`, the plain sibling of
# `UniqueConstraint`'s `<table>_<cols>_uniq`. Like `UniqueConstraint` this is NOT a `PormGField`:
# it carries no column of its own, it references existing fields by name.
"""
    Index(; fields, name = nothing)

Index a combination of columns — Django's `Meta.indexes`. Pass it to [`Model`](@ref) through
`indexes =`.

An `Index` is a read-performance declaration, not a rule: it constrains nothing. For a composite
uniqueness *guarantee* use [`UniqueConstraint`](@ref), which is a `CREATE UNIQUE INDEX` and rejects
duplicate rows.

`fields` names **two or more** fields on this model. **The order is significant**: an index over
`("raceid", "lap")` serves a lookup by `raceid`, or by `raceid` *and* `lap` together, but not one by
`lap` alone. Foreign keys are referenced by their field name and resolved to the physical column
(honoring `db_column`), and the declared case is preserved, so name each field exactly as it was
declared.

!!! warning "One column is `db_index = true`, not a one-field `Index`"
    A single-column `Index` is rejected. It is not a missing feature — it is unrepresentable *in
    both directions*: a one-column `CREATE INDEX` is byte-identical whether `db_index = true` or an
    `Index` emitted it, so introspection reads it back as `db_index` (there is no marker to
    distinguish them, unlike `UniqueConstraint`, which SQLite tags `origin = 'u'` vs `'c'`). A model
    declaring a one-field `Index` would therefore compare unequal to its own live table forever, and
    `makemigrations` would propose **dropping** the index on every run. Declare
    `db_index = true` on the field instead.

`name` is the index name. Omitted, the migration planner derives `<table>_<cols>_idx`, the plain
sibling of the composite-unique convention. Pass an explicit one when the derived name would exceed
PostgreSQL's 63-byte identifier limit, which Postgres truncates with only a `NOTICE` — truncation can
collide two indexes into one.

Invalid declarations raise `ModelDefinitionError` as early as they can be detected: fewer than two
fields, a repeated field, or a blank `name` fails here in the constructor; a field that does not
exist on the model, a `ManyToManyField` (it owns no column), or two indexes sharing a name fail when
the model is built. An index whose name collides with a `UniqueConstraint`'s on the same table fails
at migration planning, where both names are known.

!!! note "Materialized when the table is created"
    Each index becomes a `CREATE INDEX` — identical on PostgreSQL and SQLite — emitted when its
    table is **first created**. Adding or removing one on a table that already exists is not yet
    detected by `makemigrations`, the same limitation [`UniqueConstraint`](@ref) carries. Introspection
    *does* read composite indexes back, so `inspectdb` on an existing database reproduces them.
    Declare an index with the model, or add it by hand on an existing table.

# Examples
```julia
Lap_times = Models.Model("lap_times",
  raceid   = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "RESTRICT"),
  lap      = Models.IntegerField(),
  position = Models.IntegerField(),
  indexes = [
    Models.Index(fields = ("raceid", "lap"), name = "lap_times_race_lap_idx"),
  ],
)
```

which migrates to:

```sql
CREATE INDEX IF NOT EXISTS "lap_times_race_lap_idx"
  ON "lap_times" ("raceid", "lap");
```

See also [`Model`](@ref), [`UniqueConstraint`](@ref).
"""
struct Index
  fields::Vector{String}
  name::Union{String, Nothing}
end
function Index(; fields, name::Union{AbstractString, Nothing} = nothing)
  cols = _normalize_constraint_fields(fields, "Index")
  # ≥2 is a hard rule, not a stylistic one — see the docstring's warning. A one-column CREATE INDEX
  # is indistinguishable from `db_index = true` on read-back, so a single-field Index would make
  # `makemigrations` propose dropping its own index on every run.
  length(cols) < 2 && throw(ModelDefinitionError(
    "Index requires at least two fields, got $(isempty(cols) ? "none" : repr(cols)); " *
    "a single-column index is the field option db_index = true"))
  length(unique(cols)) == length(cols) ||
    throw(ModelDefinitionError("Index has duplicate fields: $(cols)"))
  # A blank name would render as an empty (invalid) index identifier; require nothing (auto-derive)
  # or a real name.
  name !== nothing && isempty(strip(name)) &&
    throw(ModelDefinitionError("Index name must be non-empty (pass name=nothing to auto-derive)"))
  return Index(cols, name === nothing ? nothing : String(name))
end

# Coerce the `indexes=` argument (a single Index, an iterable of them, or nothing) into a
# concrete Vector. Anything that is not an Index is an error — which is also what a consuming app
# that declared a COLUMN named `indexes` now hits, loudly, instead of having its field silently
# swallowed by the option peel (see MODEL_OPTION_KWARGS in src/constants.jl).
_as_index_vector(::Nothing)::Vector{Index} = Index[]
_as_index_vector(i::Index)::Vector{Index} = Index[i]
function _as_index_vector(is)::Vector{Index}
  out = Index[]
  # A non-iterable value is the `indexes = Models.CharField()` case — a column named `indexes`,
  # which the option peel swallowed. Without this the loop below raises a bare
  # `MethodError: no method matching iterate(::sCharField)`, which names neither the option nor the
  # fix. Same shape as `_as_constraint_vector`'s guard.
  applicable(iterate, is) || throw(ModelDefinitionError(
    "`indexes` must be an Index or a collection of them, got $(typeof(is)). " *
    "`indexes` is a model-level option, so a COLUMN of that name must be pinned with " *
    "db_column: other_name = Models.CharField(db_column = \"indexes\")"))
  for i in is
    i isa Index ||
      throw(ModelDefinitionError("`indexes` must contain Index objects, got $(typeof(i))"))
    push!(out, i)
  end
  return out
end

# Validate declared Indexes against the built model and stash them in `cache`, exactly as
# `_apply_unique_constraints!` does one section up — so `deepcopy`/`strip_many_to_many_fields`
# carry them for free.
#
# The cache key is "composite_indexes", NOT "indexes": `cache["index"]` is already taken by
# introspection's physical-column ⇒ index-name map for per-field `db_index` (#325), and two keys
# one letter apart, holding unrelated shapes, is a trap. The INNER key is "indexes", mirroring
# `unique_constraints`'s inner "constraints".
function _apply_indexes!(model::Model_Type, indexes)::Model_Type
  list = _as_index_vector(indexes)
  isempty(list) && return model
  seen_names = Set{String}()
  for ix in list
    for fname in ix.fields
      haskey(model.fields, fname) || throw(ModelDefinitionError(
        "Index references unknown field '$(fname)' on model '$(model.name)'. " *
        "Declared fields: $(sort(collect(keys(model.fields))))"))
      is_many_to_many_field(model.fields[fname]) && throw(ModelDefinitionError(
        "Index field '$(fname)' on model '$(model.name)' is a ManyToManyField; " *
        "an index must reference concrete columns"))
    end
    # Two indexes sharing an explicit name collide into one index (the plan keys on the name);
    # reject it here for a clear, early error instead of a silent drop at planning time.
    if ix.name !== nothing
      ix.name in seen_names && throw(ModelDefinitionError(
        "Duplicate Index name '$(ix.name)' on model '$(model.name)'; " *
        "index names must be unique within a model"))
      push!(seen_names, ix.name)
    end
  end
  model.cache["composite_indexes"] = Dict{String, Any}("indexes" => list)
  return model
end

# Store an explicit physical table name override (#59). Mirrors db_column's precedent
# (field_db_column, below): type-check + empty-string-as-unset only, no identifier-shape
# validation, no forced case fold — the whole point is to carry an arbitrary legacy spelling
# (including mixed case) through DDL/queries/migrations verbatim. `nothing` (the default) is a
# no-op, so a model that never sets `db_table` behaves exactly as before this option existed.
function _apply_db_table!(model::Model_Type, db_table)::Model_Type
  db_table === nothing && return model
  db_table isa AbstractString || throw(ModelDefinitionError(
    "The 'db_table' option on model '$(model.name)' must be a String or nothing, got $(typeof(db_table))"))
  isempty(db_table) && return model
  model.db_table = String(db_table)
  return model
end

#═══════════════════════════════════════════════════════════════════════════════
# SECTION: Model Constructors
#═══════════════════════════════════════════════════════════════════════════════
"""
    Model(; constraints = nothing, db_table = nothing, indexes = nothing, fields...)
    Model(name; constraints = nothing, db_table = nothing, indexes = nothing, fields...)

Define a model — one database table, described by its fields. Returns a `Model_Type`: the object the
query builder starts from, as in `M.Driver.objects`.

Every keyword other than `constraints`/`db_table`/`indexes` declares a field: `field_name = FieldType(...)`,
where the field types are the constructors in this module ([`IDField`](@ref), [`CharField`](@ref),
[`ForeignKey`](@ref), …). Declaring a keyword whose value is not a field raises
`ModelDefinitionError` — see the note below, which is the usual reason that happens.

The **table name** comes from the positional string when given, and otherwise from the Julia binding
the model is assigned to, filled in when [`set_models`](@ref) (or `@import_models`) registers the
module. Both forms are idiomatic and `Race = Model(...)` and `Race = Model("race", ...)` name the
same table, because a binding-derived name is lowercased as it is filled in. Reach for the
positional form when the binding name is not the table name you want — and `db_table` (below) when
even that isn't enough, because the physical table isn't a valid PormG model name at all.

!!! warning "A positional name must be lowercase and may not start with '_'"
    `Model("Driver_Profile", …)` raises `ModelDefinitionError`. A positional name is stored
    **verbatim**, and the two groups of consumers disagree about case: `makemigrations` lowercases it
    into the DDL, while the query builder quotes it as declared. Left unchecked, that model migrated
    a table named `driver_profile` and then addressed `"Driver_Profile"` in every
    `SELECT`/`INSERT`/`UPDATE` — a table that does not exist on a backend where a quoted identifier
    is case-sensitive, as it is on PostgreSQL. Rejecting the name at declaration (#300) turns that
    silent production failure into an error you get at load time.

    `Model("_order", …)` raises the same error, for the same reason: a model name is a lowercase
    **logical** identifier, and an underscore-prefixed name is not a shape PormG generates. (It
    arrived as #306, when `format_model_name` stripped a leading underscore for a foreign key's
    `REFERENCES` target while `create_table` wrote the stored name as-is, so the model created
    `_order` and referenced `order`. #317 retired that strip, so the split is gone and the rejection
    is now convention rather than a bug guard.)

    Mapping a model to a fixed table whose name those rules reject — arbitrary case, a leading
    underscore — is `db_table` (below). The positional name stays the lowercase logical identifier
    either way.

**Field names keep the case you declare** and are case-sensitive in queries, so a legacy `driverId`
column is addressed as `driverId`. A name containing `__` is rejected, since that is the lookup
separator, and so is a name starting with `_`:

```julia
Models.Model("lap", _end = Models.DateTimeField())
# ModelDefinitionError: The field name '_end' … starts with '_'. …
```

That leading underscore used to be an escape hatch PormG silently stripped — `_end = CharField()`
declared the column `end` — for a column whose name Julia will not accept as a keyword argument.
Retired in #317: `db_column` (#50) says the same thing explicitly, and composes with `db_table`.

```julia
end_ = Models.DateTimeField(db_column = "end")   # field `end_` → column "end"
id2  = Models.CharField(db_column = "_id")       # field `id2`  → column "_id"
```

Julia's own `var"…"` syntax also works for a plain field name — `var"end" = CharField()` declares
the field `end` directly — but it does **not** escape a *model-option* collision (see the warning
below), so `db_column` is the spelling that covers every case.

A `ManyToManyField` is stored on the model but owns no column of its own, so it is absent from
`field_names` and from the created table.

`constraints` takes [`UniqueConstraint`](@ref) objects — one, or a collection — for uniqueness
spanning more than one column. `db_table` (#59) pins an explicit physical table name, **preserved
verbatim** — no case fold, no validation beyond "is it a non-empty String" — overriding the name
otherwise derived from the positional argument or the binding. It is authoritative everywhere a table
identifier is rendered: DDL, `SELECT`/`INSERT`/`UPDATE`/`DELETE`, `JOIN`, foreign-key `REFERENCES`
targets, and migration diffing. Unset (the default), a model behaves exactly as it did before this
option existed. This is the table-level sibling of [`CharField`](@ref)'s `db_column` (#50):

```julia
# The logical name stays lowercase; db_table carries the exact legacy spelling.
DriverRaces = Models.Model("driver_races", db_table = "Driver_Races_Legacy",
  id = Models.IDField(),
)
```

`indexes` (#347) takes [`Index`](@ref) objects — one, or a collection — for a read-performance index
spanning more than one column, Django's `Meta.indexes`. A single-column index stays the field option
`db_index = true`.

`constraints`, `db_table` and `indexes` are the **only** model-level options.

!!! warning "`constraints`, `db_table` and `indexes` are not field names"
    All three are peeled off before the field keywords, so `db_table = CharField()` declares the
    *option* (and raises, since a field is not a String) rather than a column called `db_table`. To
    declare a column with one of those names, pin it with `db_column`:

    ```julia
    table_kind = Models.CharField(db_column = "db_table")
    ```

    `var"db_table" = CharField()` does **not** help: it parses to the keyword-argument name
    `:db_table`, and the peel keys on that name however it was spelled. `db_column` is the only
    spelling that genuinely declares the column. A *table* named `db_table` needs nothing special —
    `Model("db_table", …)` is fine.

!!! note "PormG has no Django `Meta` block"
    There is no model-level `ordering` or `verbose_name` — `db_table` (above) is the one model-level
    physical-naming option. Any other keyword is read as a field declaration and raises:

    ```julia
    Models.Model("race", ordering = ["-year"], raceid = Models.IDField())
    # ModelDefinitionError: All fields must be of type PormGField, exemple: …
    ```

    Instead: order at query time with `order_by()` — there is no per-model default sort; and set
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

Lap_times = Models.Model(
  raceid   = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "RESTRICT"),
  lap      = Models.IntegerField(),
  position = Models.IntegerField(),
  indexes = [                                 # many rows per (race, lap) — an index, not a rule
    Models.Index(fields = ("raceid", "lap"), name = "lap_times_race_lap_idx"),
  ],
)

# Porting a legacy schema PormG doesn't control: the live table is `Constructor_Standings`.
ConstructorStandings = Models.Model("constructor_standings",
  db_table = "Constructor_Standings",
  id = Models.IDField(),
)
```

See also [`set_models`](@ref), [`UniqueConstraint`](@ref), [`Index`](@ref), [`ForeignKey`](@ref).
"""
function Model(name::AbstractString; constraints = nothing, db_table = nothing, indexes = nothing, fields...)
  # Peel `constraints`/`db_table`/`indexes` off BEFORE the `fields...` slurp — otherwise any of them
  # would flow into the `NTuple{Pair{Symbol}}` method below and trip its `isa PormGField` check (#19,
  # #347).
  # Generated model files (Model_to_str) reload through this kwargs form, so this is the
  # round-trip seam.
  model = Model(name, Tuple(pairs(fields)))
  model = _apply_db_table!(model, db_table)
  model = _apply_unique_constraints!(model, constraints)
  return _apply_indexes!(model, indexes)
end

# Constructor a function that adds a field to the model the number of fields is not limited to the number of fields, the fields are added to the fields dictionary but the name of the field is the key
function Model(name::AbstractString, fields::NTuple{N, <:Pair{Symbol}}) where N
  # #300. An EMPTY name is the no-positional form: `set_models` (or the migration loader) fills it
  # from the Julia binding later, lowercasing through `format_model_name`, so there is nothing to
  # check here. A non-empty name came from the user positionally and is never normalized anywhere —
  # this is its only gate. Checked before the field loop so a bad name reports before field errors.
  #
  # Deliberately NOT on the two `Dict`-taking `Model` methods below: those are how `inspectdb`
  # introspection and the Django importer build a model from a name they read out of a live database
  # or a Python class, where mixed case is legitimate and must pass through untouched. The same
  # split applies to the FIELD-name guard on the loop below (#317).
  isempty(name) || _validate_positional_model_name(name)
  fields_dict::Dict{String, PormGField} = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    # This is the KWARGS declaration path — the only place a field name is a Julia identifier the
    # user typed, and therefore the only place the retired leading-underscore hatch could have been
    # meant (#317). Checked before the `isa PormGField` test so a bad NAME reports before a bad
    # value, matching the positional-name gate above.
    field_name = field[1] |> String
    _validate_declared_field_name(field_name, name)
    field_name = format_fild_name(field_name)
    if !(field[2] isa PormGField)
      throw(ModelDefinitionError("All fields must be of type PormGField, exemple: users = Models.PormGModel(\"users\", name = Models.CharField(), age = Models.IntegerField())"))
    end
    fields_dict[field_name] = field[2]
    !is_many_to_many_field(field[2]) && push!(field_names, field_name)
  end
  # println(fields_dict)
  return Model_Type(name=name, fields=fields_dict, field_names=field_names)
end
# `inspectdb` path. No name normalization or validation at all (#317): the keys ARE live column names,
# and `field_names` must agree with them key-for-key. It previously ran `format_fild_name` here while
# storing `dict` verbatim, so a `_end` column registered `fields["_end"]` alongside
# `field_names == ["end"]` — a split — and an `a__b` column aborted the whole import from inside this
# loop, before `Model_to_str` ever got a chance to render it.
function Model(name::AbstractString, dict::Dict{String, PormGField})
  field_names::Vector{String} = []
  for (field_name, field) in pairs(dict)
    !is_many_to_many_field(field) && push!(field_names, field_name)
  end
  return Model_Type(name=name, fields=dict, field_names=field_names)
end
# Django-importer path. Same exemption as the `Dict{String,…}` method above (#317) — the keys are
# Python class attributes read from a live model; a Django `_foo = models.CharField()` used to import
# as the column `foo`, which was simply wrong.
function Model(name::AbstractString, fields::Dict{Symbol, Any})
  fields_dict = Dict{String, PormGField}()
  field_names::Vector{String} = []
  for (field_name, field) in pairs(fields)
    @pormg_debug false
    field_name = field_name |> String
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
function Model(; constraints = nothing, db_table = nothing, indexes = nothing, fields...)
  # No-positional-name form (the idiomatic style — the table name is inferred from the binding
  # via set_models). `constraints=`/`db_table=`/`indexes=` must work here too, so peel them before
  # the `fields...` slurp exactly like the named form above.
  model = Model("", Tuple(pairs(fields)))
  model = _apply_db_table!(model, db_table)
  model = _apply_unique_constraints!(model, constraints)
  return _apply_indexes!(model, indexes)
end

"""
    add_field!(model::PormGModel, field_name::Union{String, Symbol}, field::PormGField)

Dynamically adds a field to an existing model. If the field is a ManyToManyField,
it also registers reverse accessors and caches join metadata (requires the model to
be initialized via `set_models()` / `@import_models` with a configured connection).

`field_name` follows the same rules as a field declared in a `Model(...)` call: `__` and `@` are
rejected, and a **leading underscore** raises [`ModelDefinitionError`](@ref) (#317) — pass
`db_column` on the field to target a column whose name is a Julia keyword or literally begins with
an underscore.
"""
function add_field!(model::PormGModel, field_name::Union{String, Symbol}, field::PormGField)
  # A DECLARATION path, not a reference: this is public API that takes a name the user wrote, so it
  # gets the same leading-underscore guard as the kwargs constructor (#317). Without it,
  # `add_field!(m, :_end, f)` would silently flip from the column `end` to the column `_end`.
  field_name = field_name isa Symbol ? String(field_name) : String(field_name)
  _validate_declared_field_name(field_name, model.name)
  field_name = format_fild_name(field_name)

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

This function is a pure renderer: everything it emits is derived from `model` alone. It takes **no**
connection `Settings` (#346). It used to, for one reason — a `django_prefix` was composed into
`db_table` here (#345) — and that could not survive multi-app import, where the app label is per
model and one `Settings` field cannot hold three of them. The Django importer now applies the
physical table with `_apply_db_table!` before calling this, so there is exactly one place that
derives `<app label>_<class>` instead of two that had to agree.

# Arguments
    Model_to_str(model::Union{Model_Type, PormGModel}; contants_julia::Vector{String}=reserved_words, name_is_physical_table::Bool=false, taken_bindings::Set{String}=Set{String}(), taken_names::Set{String}=Set{String}(), binding::Union{String, Nothing}=nothing)::String
- `model::Union{Model_Type, PormGModel}`: The model object to convert.
- `contants_julia::Vector{String}=reserved_words`: identifiers the *generated* field name must avoid —
  the words that cannot be a Julia keyword-argument name. A column named after one of them (or after a
  model option, or otherwise not a legal identifier) is emitted under a sanitized name with the real
  column pinned as `db_column` (#317).
- `name_is_physical_table::Bool=false`: whether `model.name` is a **live table name** rather than a
  logical identifier. `true` for database introspection (`inspectdb`), where a name that is not
  already lowercase must be pinned as `db_table` so the generated declaration addresses the table it
  was read from (#59) — the positional slot is lowercased and would otherwise name a different table.
  `false` for the Django importer, whose `model.name` is a **Python class name**: there the physical
  table genuinely is the lowercased form, and pinning the class spelling would invent a table that
  does not exist. The two are indistinguishable from the name alone, so the caller states which it has.
- `taken_bindings::Set{String}=Set{String}()`: Julia bindings already claimed elsewhere in the SAME
  generated file (#338) — mutated in place: this call's resolved binding is added before returning.
  Two tables whose names would otherwise render the same binding (e.g. `driver profile` and
  `driver_profile`) get the second suffixed with a digit instead of silently shadowing the first at
  `include` time. A caller rendering more than one model into one file must share ONE set across every
  call; the default fresh set reproduces the old, uncollision-checked behavior for a single call.
  (Named `taken_bindings`, not `taken` — the latter is already a local inside this function for
  per-field identifier dedup; a same-named kwarg would silently shadow it.)
- `taken_names::Set{String}=Set{String}()`: same idea, for the positional name (the first string
  argument to `Model(...)`) rather than the binding. When dedup changes the name AND nothing already
  pins `db_table`, the pre-dedup name is pinned as `db_table` so the model still addresses the right
  table — see the implementation comment at the positional-name computation below.
- `binding::Union{String, Nothing}=nothing`: the Julia binding to emit, when the caller already knows
  it (#360). `nothing` (the default) derives it from `model.name` as before. The inspectdb importers
  pass one because they must resolve every model's FINAL binding *before* rendering the first model,
  to rewrite each `ForeignKey`'s `.to` to it — `_resolve_target_model` resolves `.to` by binding
  lookup alone, so a `.to` naming a pre-dedup spelling silently reaches the wrong sibling. Supplying
  it keeps that a SINGLE derivation; `taken_bindings` still applies as a collision backstop.

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
function Model_to_str(model::Union{Model_Type, PormGModel}; contants_julia::Vector{String}=reserved_words, name_is_physical_table::Bool=false, taken_bindings::Set{String}=Set{String}(), taken_names::Set{String}=Set{String}(), binding::Union{String, Nothing}=nothing)::String
  fields::String = ""
  render_failures::Vector{String} = String[]
  # Iterate fields by name for deterministic output. Use `sort(collect(...))` rather than
  # `sort(::Dict)` (via `pairs(...) |> sort`), which is deprecated and emits a Warn-level
  # depwarn — that surfaces under CI's depwarn-enabled `Pkg.test` run and trips the #70
  # render-failure test's "healthy model → no warn" assertion.
  # Captured BEFORE the loop: a sanitized identifier must not steal a column that appears LATER in
  # the sorted iteration (`_id` -> `id` on a model that also has a real `id`). `taken` accumulates
  # what has already been emitted.
  raw_keys::Set{String} = Set(String(k) for k in keys(model.fields))
  taken::Set{String} = Set{String}()
  # column -> emitted identifier, for every field this loop RENAMES. `UniqueConstraint(fields = …)`
  # below names fields by their key, so it has to be translated through this or the generated file
  # declares a constraint over a field it no longer contains.
  renamed::Dict{String, String} = Dict{String, String}()
  # Columns that actually REACHED the output. A field can be dropped two ways — the #70 render-failure
  # `catch` below, and the ManyToManyField `continue` — and a constraint naming a dropped field is the
  # same unloadable-file failure as a constraint naming a renamed one.
  rendered::Set{String} = Set{String}()
  for (field_name, field) in sort(collect(model.fields); by = first)
    db_field_name::String = field_name  # real column name, before sanitizing — diagnostics must show this one
    struct_name::Symbol = nameof(typeof(field)) |> string |> x -> x[2:end] |> Symbol
    sets::Vector{String} = []
    # Pick a legal Julia identity for the field and pin the real column with `db_column` (#317).
    # This replaces the old `field_name = "_$field_name"` reserved-word prefix — the leading-underscore
    # hatch that `Model(...)` no longer accepts, so re-adding it here generated files that would not
    # reload — and the outright `throw` on a `__`/`@`/`^_` key, which aborted the ENTIRE import on one
    # such column instead of rendering it.
    field_name = _julia_field_identifier(db_field_name, contants_julia, taken, raw_keys)
    push!(taken, field_name)
    if field_name != db_field_name
      renamed[db_field_name] = field_name
      if struct_name == :ManyToManyField
        # `sManyToManyField` carries no `db_column`, AND its field name feeds the derived join-table
        # name (`_many_to_many_table_name`), so a rename here is lossy and unrecorded. Route it
        # through the #70 render-failure path instead of silently renaming a relation. Practically
        # unreachable: an M2M field only exists on a code-declared model, where the declaration guard
        # already rejects an illegal key.
        @warn "Model_to_str: ManyToManyField name is not a legal Julia identifier — emitting marker comment" model=model.name field=db_field_name
        push!(render_failures, "# PormG: field '$(db_field_name)' (ManyToManyField) could not be rendered: a ManyToManyField has no db_column, so its name cannot be remapped to a legal Julia identifier — rename the relation by hand. — field omitted.")
        continue
      elseif field_db_column(field, db_field_name) == db_field_name
        # Anti-clobber: only when the KEY is what states the column. A field that already carries an
        # explicit `db_column` has it emitted from the struct diff by `_model_to_str_general` below,
        # and this rename must touch the Julia-side identity only.
        push!(sets, "db_column=$(format_string(db_field_name))")
      end
    end
    try
      fields = if struct_name in [:ForeignKey, :OneToOneField]
        _model_to_str_foreign_key(field_name, field, struct_name, sets, fields)
      elseif struct_name == :ManyToManyField
        _model_to_str_many_to_many(field_name, field, sets, fields)
      else
        _model_to_str_general(field_name, field, struct_name, sets, fields)
      end
      push!(rendered, db_field_name)
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
      rendered_constraints = String[]
      for c in ucs
        cfields = String[String(f) for f in c.fields]
        # A constraint over a field that never reached the output cannot be declared: on reload
        # `_apply_unique_constraints!` raises "UniqueConstraint references unknown field 'boom'" and
        # the whole generated file fails. Drop it with a visible marker rather than emit a file that
        # does not load — the #70 convention, applied one level up (#317).
        missing_fields = filter(f -> !(f in rendered), cfields)
        if !isempty(missing_fields)
          @warn "Model_to_str: UniqueConstraint references a field that did not render — emitting marker comment" model=model.name fields=cfields missing=missing_fields
          push!(render_failures, "# PormG: UniqueConstraint over ($(join(cfields, ", "))) could not be rendered: field(s) $(join(missing_fields, ", ")) did not render — constraint omitted.")
          continue
        end
        # A constraint names its fields by KEY, and the loop above may have renamed some of those
        # keys to legal Julia identifiers (#317). Translate through `renamed` — a constraint over the
        # old key would be rejected the same way. Identity fallback for anything not renamed, which
        # is the common case.
        cols = join((format_string(get(renamed, f, f)) for f in cfields), ", ")
        namepart = c.name === nothing ? "" : ", name = $(format_string(String(c.name)))"
        # Trailing comma keeps a single-field tuple valid Julia: ("a",)
        push!(rendered_constraints, "Models.UniqueConstraint(fields = ($(cols),)$(namepart))")
      end
      isempty(rendered_constraints) ||
        (fields *= ",\n  constraints = [$(join(rendered_constraints, ", "))]")
    end
  end
  # Composite indexes (#347): the exact sibling of the block above, for the `indexes=` kwarg. Emitted
  # AFTER `constraints` so the generated kwarg order is deterministic, and gated the same way — an
  # all-failed model stays commented-out below, indexes included. Reuses `rendered` (a field that
  # never reached the output) and `renamed` (a field the loop above re-spelled to a legal Julia
  # identifier) for the same two reasons the constraints block does: either one would otherwise emit
  # a declaration `_apply_indexes!` rejects on reload, so the generated file would not load.
  if fields != "" && haskey(model.cache, "composite_indexes")
    ixs = get(model.cache["composite_indexes"], "indexes", Index[])
    if !isempty(ixs)
      rendered_indexes = String[]
      for ix in ixs
        ifields = String[String(f) for f in ix.fields]
        missing_fields = filter(f -> !(f in rendered), ifields)
        if !isempty(missing_fields)
          @warn "Model_to_str: Index references a field that did not render — emitting marker comment" model=model.name fields=ifields missing=missing_fields
          push!(render_failures, "# PormG: Index over ($(join(ifields, ", "))) could not be rendered: field(s) $(join(missing_fields, ", ")) did not render — index omitted.")
          continue
        end
        cols = join((format_string(get(renamed, f, f)) for f in ifields), ", ")
        namepart = ix.name === nothing ? "" : ", name = $(format_string(String(ix.name)))"
        # Trailing comma keeps a single-field tuple valid Julia: ("a",)
        push!(rendered_indexes, "Models.Index(fields = ($(cols),)$(namepart))")
      end
      isempty(rendered_indexes) ||
        (fields *= ",\n  indexes = [$(join(rendered_indexes, ", "))]")
    end
  end
  # #360: a caller that had to know this binding BEFORE rendering (the inspectdb importers, which
  # rewrite every FK `.to` to its target's final binding in a pass 1) passes the string it already
  # computed rather than letting this function re-derive it. ONE derivation, not two — the drift
  # `_model_binding_name`'s docstring warns about would here mean an FK silently addressing a
  # different model, which is the whole point of the issue.
  model_var_name = binding === nothing ? _model_binding_name(String(model.name), contants_julia) : binding
  # #338: two tables can independently arrive at the same binding above — via either branch of
  # `_model_binding_name`, since its fast path deliberately bypasses the sanitizer's own dedup.
  # Applied uniformly, AFTER either path, against the caller's shared `taken_bindings`: the second
  # model in a batch gets a digit suffix instead of silently overwriting the first model's Julia
  # global when the generated file is `include`d.
  _pre_dedupe_binding = model_var_name
  model_var_name = _dedupe_taken(model_var_name, taken_bindings)
  push!(taken_bindings, model_var_name)
  # A caller-supplied binding was already deduped against the same seed in the same order, so this
  # is unreachable by construction — but if it ever fires, the `.to` strings that pass 1 wrote are
  # now stale and point at the wrong model. Warn rather than throw: the file is still loadable, and
  # a throw here would abort an entire import over a defect in PormG, not in the user's schema.
  binding === nothing || model_var_name == _pre_dedupe_binding ||
    @warn "Model_to_str: caller-supplied binding collided and was renamed; foreign keys aimed at this model may now resolve elsewhere" model=model.name wanted=_pre_dedupe_binding renamed_to=model_var_name
  # Round-trip the physical table name as `db_table=` (#59). Two sources, one kwarg:
  #
  #  1. An explicit `db_table` on the model — emitted verbatim so a reload reproduces it. This is
  #     also how a **Django app label** reaches the output (#345/#346): the importer resolves
  #     `Meta.db_table` or `<app label>_<lowercased class>` and calls `_apply_db_table!` before
  #     rendering. It used to be derived HERE from `settings.django_prefix`, which could not survive
  #     multi-app import — one `Settings` field cannot hold `core`, `access` and `imports` at once —
  #     and meanwhile the importer had to mirror this function's precedence to pin M2M join tables.
  #     One derivation, in the only place that knows the label per model.
  #  2. An INTROSPECTED name (`name_is_physical_table`) that the positional slot would not reproduce:
  #     not already lowercase, or leading-underscore. On that path `model.name` IS the live table
  #     name, so before `db_table` existed `inspectdb` on `Driver_Profile` generated
  #     `Model("driver_profile", …)` — a declaration pointing at a *different* table (the #300 split,
  #     arrived at from the other end), and on `_order` it generated a file that would not even load
  #     (the #306 guard). Pinning the original spelling fixes both.
  #
  # The caller must SAY which it has: the Django importer's `model.name` is a Python CLASS name, not
  # a table name — its physical table genuinely IS the lowercased form — so inferring "not lowercase
  # ⇒ physical" from the string would make it pin a table that does not exist.
  #
  # `model_has_db_table`/`model_table_name` rather than `model.db_table`: the signature accepts any
  # `PormGModel`, and only `Model_Type` is guaranteed to carry the field.
  pin_introspected = name_is_physical_table &&
                     (model.name != lowercase(model.name) || startswith(model.name, "_"))
  # An explicit `db_table` is ABSOLUTE, exactly as in Django, so it stays first.
  db_table_abs = if model_has_db_table(model)
    model_table_name(model)
  elseif pin_introspected
    String(model.name)
  else
    nothing
  end
  db_table_part = db_table_abs === nothing ? "" : ", db_table = $(format_string(db_table_abs))"
  # The positional slot drops leading underscores ONLY when the real table is being pinned as
  # `db_table` above — the two are one decision, not two. Stripping without pinning is precisely the
  # "generated declaration silently addresses a different table" defect the `name_is_physical_table`
  # gate exists to prevent: an unprefixed Django import of `_InternalThing` maps to table
  # `_internalthing`, so emitting `internalthing` there would be wrong.
  #
  # The condition is `db_table_abs !== nothing` rather than `pin_introspected` (#345). Those agreed
  # while the introspection pin was the only pin; they no longer do, and the difference is a file
  # that does not load. `_validate_positional_model_name` rejects a leading underscore REGARDLESS of
  # `db_table`, so with the app prefix now living in `db_table`, `class _Internal` under prefix
  # `dash` would emit `Model("_internal", db_table = "dash__internal")` and throw at include time —
  # where before #345 it emitted the (loadable) `Model("dash__internal")`. Keying on the pin instead
  # restores that, and closes the same hole for an explicit `Meta.db_table`, which had it all along.
  #
  # An ALL-underscore table (`_`, `___`) strips to the empty string, which as a positional name
  # silently means "derive from the binding". Emitting the unstripped `_` instead is no better — the
  # #306 guard rejects it, so the generated file did not load. Since this branch is only reached when
  # `db_table` is pinning the real name anyway, the positional slot is free to take a placeholder that
  # the guard accepts (#317).
  #
  # The positional slot is the LOGICAL handle and nothing else (#345). It is `lowercase(model.name)`,
  # which for the Django importer is `lowercase(<class name>)` — Django's own derivation
  # (`model.__name__.lower()`), so `Dim_uf` -> "dim_uf" and `ImportBatch` -> "importbatch" both agree
  # with the app's real table minus its prefix. The prefix itself is pinned as `db_table` above.
  _pins_table = db_table_abs !== nothing
  _lowered = model.name |> lowercase
  _stripped_name = _pins_table ? lstrip(_lowered, '_') : _lowered
  model_name_abs = if !isempty(_stripped_name)
    String(_stripped_name)
  elseif _pins_table
    # `db_table` carries the truth; this is only the logical handle, so any name the guard accepts
    # will do. The sanitizer yields `col` for an all-underscore name.
    lowercase(_julia_field_identifier(_lowered, contants_julia, Set{String}(), Set{String}()))
  else
    _lowered
  end
  # #338: two tables can independently arrive at the same POSITIONAL name too — not just the
  # all-underscore case above, but also e.g. `Driver` (pin_introspected, db_table already pinned)
  # and `driver` (not pin_introspected, db_table_abs still `nothing` above) both lowering to
  # "driver". Dedup against the caller's shared `taken_names` same as the binding above — but unlike
  # the binding, this string can BE the physical table (`model_table_name` falls back to it whenever
  # `db_table` is unset), so a dedup that invents "driver2" with nothing pinning "driver" would leave
  # the model loading cleanly while querying a table that does not exist — worse than the shadowing
  # bug this issue is about. So: when dedup actually changes the string AND nothing already pinned
  # the table (`db_table_abs === nothing`), pin the PRE-dedup name explicitly, the same way
  # `pin_introspected` already pins one for a leading-underscore/mixed-case name above.
  #
  # #345 adds a third way `db_table_abs` is already non-`nothing` here, and the guard handles it
  # unchanged: under a Django app prefix the physical table is pinned for every model, so a dedup
  # renames only the handle. Two classes that collide on `lowercase(name)` then both point at the one
  # table the prefix derives — which is correct, and is a project Django itself rejects
  # ("Conflicting 'x' models in application"), so there is nothing to disambiguate toward.
  _pre_dedupe_name_abs = model_name_abs
  model_name_abs = _dedupe_taken(model_name_abs, taken_names)
  push!(taken_names, model_name_abs)
  if model_name_abs != _pre_dedupe_name_abs && db_table_abs === nothing
    db_table_abs = _pre_dedupe_name_abs
    db_table_part = ", db_table = $(format_string(db_table_abs))"
  end
  # Marker comments sit directly above the model definition in the generated file (#70).
  marker = isempty(render_failures) ? "" : join(render_failures, "\n") * "\n"
  if fields == ""
    # Every field failed to render (or the model has none): a bare `Models.Model("name")` call throws
    # ArgumentError at include time (the single-arg constructor requires ≥1 field), which would abort
    # loading the ENTIRE generated module (#134). Comment the definition out — with an explanatory
    # marker — so the file still loads and the user sees exactly which model to fix by hand. Mirrors
    # Rails' SchemaDumper, which comments out a table it can't dump so schema.rb stays loadable.
    note = "# PormG: model '$(model_name_abs)' had no renderable fields — definition commented out."
    result = """$(marker)$(note)\n# $(model_var_name) = Models.Model($(format_string(model_name_abs))$db_table_part)"""
  else
    result = """$(marker)$(model_var_name) = Models.Model($(format_string(model_name_abs))$db_table_part$fields)"""
  end
  @info(result)

  return result
end
# True when `Model_to_str` already pinned `db_column` for this field because it had to rename the
# field's Julia identity (#317). The struct diff below must then NOT emit its own — Julia rejects a
# repeated keyword argument at PARSE time, so a duplicate produces a file that will not even load.
# Only reachable for a field carrying `db_column = ""` (empty is "unset" to `field_db_column`, but
# differs from the `nothing` default the diff compares against), and the pinned value is the truthful
# one in that case.
_db_column_already_pinned(sets)::Bool = any(s -> startswith(s, "db_column="), sets)

function _model_to_str_general(field_name, field, struct_name, sets, fields)
  stadard_field = getfield(@__MODULE__, struct_name)()
  pinned = _db_column_already_pinned(sets)
  for sfield in fieldnames(typeof(field))
    pinned && sfield === :db_column && continue
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
  pinned = _db_column_already_pinned(sets)
  for sfield in fieldnames(typeof(field))
    pinned && sfield === :db_column && continue
    # #360: `to_table` is an introspection-only breadcrumb — the physical parent table, recorded so
    # the importers can rewrite `.to` to the target's final binding in a pass 1 BEFORE rendering. By
    # the time we get here that rewrite has happened and `to` below is already correct, so the slot
    # has nothing left to say. It is skipped rather than emitted because `ForeignKey`/`OneToOneField`
    # accept no such kwarg — `_common_kwargs` would `@warn "Unexpected parameter"` and drop it on
    # every reload of the generated file, which is noise describing a value nothing consumes.
    sfield === :to_table && continue
    # #62: `.to` may now be a resolved PormGModel (set_models / migration prelude write
    # back the model). Emit its generated variable name via `_model_binding_name` — the SAME
    # expression `Model_to_str` uses for the binding itself, and the two MUST agree because
    # `_resolve_target_model` resolves a String `.to` by binding lookup alone. So a model-`.to`
    # serializes identically to the string a user would have declared. (The only live caller, the
    # import flow, always has a string `.to`; this branch is defensive, locked by a round-trip test.)
    # It was bare `uppercasefirst` until #360 — which agrees for a name that is already a legal
    # identifier, but emits an unresolvable `.to` for one that is not: a model named `driver profile`
    # binds as `Driver_profile` and serialized as `"Driver profile"`.
    sfield == :to && (v = getfield(field, sfield); to = v isa PormGModel ? _model_binding_name(v.name) : v; continue)
    if getfield(field, sfield) != getfield(ForeignKey(""), sfield)
      push!(sets, """$sfield=$(getfield(field, sfield) |> format_string)""")
    end
  end
  # `format_string`, not raw interpolation: `to` is a live parent TABLE name on the inspectdb path,
  # so a `"` or `$` in it would emit source that does not parse (#317).
  fields *= ",\n  $field_name = Models.$struct_name($(format_string(String(to))), $(join(sets, ", ")))"
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
  # `format_string` for the same reason as the ForeignKey site above (#317).
  fields *= ",\n  $field_name = Models.ManyToManyField($(format_string(String(to)))$(isempty(sets) ? "" : ", " * join(sets, ", ")))"
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

"""
    format_binary_sql(value) -> PormGBytes

Coerce a `BinaryField` value into the [`PormGBytes`](@ref) wrapper the parameter collectors bind
as a single blob (#296).

Accepts raw bytes (`Vector{UInt8}`, and any other `AbstractVector{UInt8}` such as the
`Base.CodeUnits` returned by `codeunits`) and an `AbstractString`, which is stored as its
**UTF-8 code units**. The string form is what keeps a column that used to be `TEXT` writable
without an app edit, and it matches the `convert_to(col, 'UTF8')` cast the PostgreSQL migration
uses — so text written before and after the migration lands as the same bytes.

Deliberately *not* routed through `format_text_sql`: its `AbstractArray` method maps itself over
the elements, which throws on `UInt8`, and `ImageField`/`FileField` share `BinaryField`'s `"BLOB"`
type string while storing paths as text.

Raises `InvalidValueError` for anything else — this is the insert/update path, so a bad *value*
is the caller's mistake. Contrast the `BinaryField(default = …)` constructor, which raises
`FieldValidationError` because there the mistake is in the model *definition*.
"""
function format_binary_sql(value::AbstractVector{UInt8})
  return PormGBytes(collect(UInt8, value))
end
function format_binary_sql(value::PormGBytes)
  return value
end
function format_binary_sql(value::AbstractString)
  return PormGBytes(collect(UInt8, codeunits(value)))
end
function format_binary_sql(value::Union{Missing, Nothing})
  return missing
end
function format_binary_sql(value)
  throw(InvalidValueError("A BinaryField value must be raw bytes (`Vector{UInt8}`) or a String, which is stored as its UTF-8 code units. Got: $(typeof(value)). For a hex or Base64 string, decode it first — e.g. `hex2bytes(s)` or `base64decode(s)`."))
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
      elseif field_name == :to_table
        # #360: an introspection-only breadcrumb, asymmetric by construction — introspection sets the
        # live parent table, the models-file side is always `nothing` because `Model_to_str` never
        # emits it. It expresses no schema, so comparing it would report EVERY foreign key as changed.
        # This function is the fast-path early-out for `_alter_table_fields`; the detailed diff below
        # it filters the same attribute via `planner._NON_SCHEMA_FIELD_ATTRS`. Both are needed —
        # without this one the cheap "nothing changed" answer is never reachable for a model with FKs.
        continue
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

# The PHYSICAL table an FK points at, when the field can actually state one (#360): `to_table` on an
# introspected field, the resolved target's `model_table_name` on a declared one. `nothing` when it
# cannot — a still-String `.to`, which names a binding and cannot be turned back into a table.
#
# This exists because the live-vs-declared FK comparison used to recover the table from `.to` by
# LOWERCASING it, which only works while `.to` is exactly `uppercasefirst(<table>)`. That held only
# by accident: it is false for any table name `uppercasefirst` does not already make a legal
# identifier (`driver profile` binds as `Driver_profile`, which lowercases to `driver_profile` — a
# different table), and false for a mixed-case table (`Driver_Profile` lowercases to
# `driver_profile`) even before #360. Comparing the physical names directly removes the guesswork.
#
# `hasproperty`, not a type check: this is reached for any field carrying a `.to`, which includes
# `sManyToManyField` (no `to_table` slot — it falls through to the resolved-model branch). That path
# then behaves exactly as before, including the pre-existing `fk_target_column` `FieldError` an M2M
# pair raises, which `_compare_model_field` catches and treats as "changed" (#69 fail-safe).
function _fk_reference_table(field::PormGField)::Union{String, Nothing}
  if hasproperty(field, :to_table)
    tbl = getproperty(field, :to_table)
    tbl isa AbstractString && !isempty(tbl) && return String(tbl)
  end
  to = field.to
  to isa PormGModel && return model_table_name(to)
  return nothing
end

function _compare_field_foreign_key(new_field::PormGField, old_field::PormGField)::Bool
  # #360: when BOTH sides can name their physical TABLE, that is the comparison — no assumption
  # about how `.to` was spelled. Only when one of them cannot (an unresolved String target) does this
  # fall back to the logical-name comparison below.
  #
  # Still compared CASE-INSENSITIVELY, exactly as the logical-name path below always has been
  # (`format_model_name` is a plain `lowercase`). SQLite identifiers are case-insensitive and
  # `PRAGMA foreign_key_list` reports the parent AS SPELLED IN THE `REFERENCES` CLAUSE, so
  # `REFERENCES DRIVER(id)` against a table declared `driver` is legal and lands here as "DRIVER"
  # against "driver". Comparing exactly would propose an alteration for that key on every
  # `makemigrations` — a full table rebuild on SQLite.
  #
  # The cost is that two tables differing only in case are conflated, which on PostgreSQL (where
  # identifiers ARE case-sensitive) can be two real tables. Undecidable here: this function receives
  # no connection. The planner does, so that is where a conditional fold would belong.
  #
  # Note this moved the comparison from the LOGICAL axis to the PHYSICAL one, which is a change in
  # its own right, not just a change of normalization: two parents with different logical names whose
  # tables differ only in case used to compare unequal on the names alone and now fold together.
  new_table = _fk_reference_table(new_field)
  old_table = _fk_reference_table(old_field)
  if new_table !== nothing && old_table !== nothing
    return lowercase(new_table) == lowercase(old_table) &&
           fk_target_column(new_field) == fk_target_column(old_field)
  end
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

# Recover a model's Julia binding by identity. Used by the many-to-many registration path, which
# stores the two bindings on the relation; the reverse-FK path gets its binding straight from
# `_collect_models_and_bindings` instead, which is a great deal cheaper than one scan per relation.
#
# Two-pass structure (fixed in #354): the fast path scans `names(_module; all=true, imported=true)`,
# which lists locally-defined and explicitly `import`ed bindings. The miss path scans with
# `usings=true`, which additionally lists bindings introduced by `using`. The miss path uses
# identity matching (`attr === model`) as its filter, so no `binding_module` guard is needed.
#
# The `uppercasefirst` fallback is retained as a last resort for the edge case where a model object
# exists but is not bound under any name in the module (both scans exhausted). DO NOT delete it:
# #343 tried that and broke registration silently, because both `set_models` callers that matter
# (the injected `__init__` in `Utils.jl` and the Revise callback) swallow exceptions.
#
# The reverse-FK path depends on none of this: `set_models` records its binding directly from
# `_collect_models_and_bindings`. This helper is many-to-many-only.
function _find_model_binding_name(_module::Module, model::PormGModel)::String
  # Fast path: explicit imports and locally-defined names.
  for name in names(_module; all=true, imported=true)
    attr = try
      Base.invokelatest(getfield, _module, name)
    catch
      nothing
    end
    attr === model && return String(name)
  end
  # Miss path (#354): `using`-scoped names are invisible to `imported=true` but reachable by identity.
  for name in names(_module; all=true, imported=true, usings=true)
    attr = try
      Base.invokelatest(getfield, _module, name)
    catch
      nothing
    end
    attr === model && return String(name)
  end
  # Final fallback: guess from the model's logical name. Works only for Xxxxx-style bindings;
  # kept for backward compatibility.
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

# `prefix` exists for the SELF-REFERENTIAL case (#364) and is empty everywhere else. It prefixes the
# whole derived name rather than being spliced in, so `from_`/`to_` land where Django puts them and
# the stem stays byte-identical to the ordinary derivation.
function _many_to_many_column_name(model::PormGModel, pk_field::String; prefix::String = "")::String
  return format_fild_name("$(prefix)$(format_model_name(model.name))_$(pk_field)")
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
  # The auto path already yields a PHYSICAL table: `_many_to_many_table_name` returns `field.db_table`
  # verbatim when the field pins one, and the synthesized name otherwise (#59/#345).
  through_table_name = _many_to_many_table_name(owner_model, field_name, field, settings)
  through_resolved = nothing
  # #364: a SELF-referential relation derives the same string for both ends, because both ends are
  # the same model. That is not a cosmetic clash — `synthesize_many_to_many_through_models` builds
  # the through model from a `Dict{Symbol, Any}` keyed on these two names, so the duplicate key
  # resolves last-wins and the join table is created with ONE endpoint column instead of two.
  # Silently: no error, and a table that cannot represent the relation it exists for.
  #
  # Django's rule for this case differs from its normal one for exactly that reason — one table
  # cannot carry the same column twice — so it names the ends `from_<model>_id` / `to_<model>_id`.
  # PormG keeps its own `<model>_<pk>` stem rather than Django's hardcoded `_id`, so a model keyed on
  # `codigo` gets `from_driver_codigo`; for the usual `id` pk the two spellings coincide.
  #
  # Gated on NEITHER side being pinned, not per-side. `ManyToManyField("Driver", source_field =
  # "mentor_id")` on a self-relation already yields the valid pair `mentor_id` / `driver_id` today —
  # deriving `to_driver_id` for the unpinned half would rewrite a working schema. Explicit wins here
  # as it does everywhere else; the residue (a pin that collides with the derived half) is caught by
  # the guard below rather than by silently overriding what the user wrote.
  self_relation = field.through === nothing && _same_model_reference(owner_model, related_model)
  if self_relation && field.source_field === nothing && field.target_field === nothing
    owner_column = _many_to_many_column_name(owner_model, owner_pk; prefix = "from_")
    related_column = _many_to_many_column_name(related_model, related_pk; prefix = "to_")
  else
    owner_column = field.source_field === nothing ? _many_to_many_column_name(owner_model, owner_pk) : field.source_field
    related_column = field.target_field === nothing ? _many_to_many_column_name(related_model, related_pk) : field.target_field
  end

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

    # The through model's PHYSICAL table (#363), not its logical `.name`. Same rule — and the same
    # reason — as the related side in `_insert_many_to_many_joins`: the logical name is what
    # IDENTIFIES the model, but this slot is rendered as a table. Reading `.name` here is what made
    # every join and every mutator address `membership` where the real table is `racing_membership`.
    # The model itself is recorded below, so nothing has to recover it from this string.
    through_table_name = model_table_name(through_model)
    through_resolved = through_model
    owner_column = field.source_field === nothing ? _infer_through_field(through_model, owner_model, "source") : field.source_field
    related_column = field.target_field === nothing ? _infer_through_field(through_model, related_model, "target") : field.target_field
    owner_fk = through_model.fields[owner_column]
    related_fk = through_model.fields[related_column]
    owner_pk = owner_fk.pk_field === nothing ? owner_pk : String(owner_fk.pk_field)
    related_pk = related_fk.pk_field === nothing ? related_pk : String(related_fk.pk_field)
  end

  # #364, fail-closed. Everything downstream — the synthesized through model's field `Dict`, the
  # unique index, both join legs, the manager mutators — assumes these two name DIFFERENT columns.
  # The derivation above can no longer produce a pair that violates it, so what is left is what a
  # user wrote: both sides pinned to one name, or one side pinned to the string the other derives.
  # Placed after the `through` block so it covers the explicit path too, where `source_field` /
  # `target_field` bypass `_infer_through_field` entirely.
  owner_column == related_column && throw(ModelDefinitionError(
    "ManyToManyField $(owner_model.name).$(field_name) resolves both join columns to \e[31m$(owner_column)\e[0m; " *
    "one join table cannot carry the same column twice. Set source_field and target_field to distinct names."))

  inverse_accessor = field.related_name === nothing ? get_model_name(owner_model, settings, false) : field.related_name
  return ManyToManyRelation(
    field_name=field_name,
    through_table=through_table_name,
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
    # `nothing` on the auto path — see the slot's comment on `ManyToManyRelation` (#363).
    through_model_resolved=through_resolved,
  )
end

function _reverse_many_to_many_relation(relation::ManyToManyRelation, reverse_accessor::String)::ManyToManyRelation
  return ManyToManyRelation(
    field_name=reverse_accessor,
    through_table=relation.through_table,
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
    # NOT swapped (#363): there is one join table and it sits between the two sides, so it is the
    # same model read from either direction — unlike every slot above, which names one side.
    through_model_resolved=relation.through_model_resolved,
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
  # #364: on a SELF-relation both accessors land on the SAME model but in two DIFFERENT dicts — the
  # forward one in `model.cache["many_to_many"]` (written just above), the reverse one in
  # `related_objects` — so the `haskey` check below is blind to a collision between them. And the
  # readers resolve the cache FIRST (`has_many_to_many_accessor` / `get_many_to_many_relation`), so
  # an equal name leaves the reverse relation permanently shadowed by the forward one. That is not a
  # dead accessor: the manager's `_m2m_query` filters on `inverse_accessor`, so every `.all()` would
  # traverse the join table backwards and silently answer the opposite question.
  #
  # Checked against `model.fields` rather than just `field_name` because the join builder resolves a
  # field before a reverse accessor (`_build_row_join`), so ANY field name shadows it the same way.
  # A non-self relation cannot reach this — its two accessors live on different models, which is why
  # the `haskey` guard alone was sufficient before a self-relation could be built at all.
  if _same_model_reference(related_model, model) && haskey(model.fields, reverse_accessor)
    # The default accessor is the bare model name, so this fires on models that never wrote a
    # `related_name` at all — say where the name came from rather than pointing at an option the
    # user cannot find in their own source.
    origin = field.related_name === nothing ? " (derived from the model name, because related_name is unset)" : ""
    throw(ModelDefinitionError(
      "ManyToManyField $(model.name).$(field_name) is self-referential, so its reverse accessor " *
      "\e[31m$(reverse_accessor)\e[0m$(origin) collides with a field of the same name on that model " *
      "and would be silently unreachable. Give the reverse end a distinct related_name."))
  end
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
    # MUST be carried (#59). This rebuilds a Model_Type field by field, so an omitted slot silently
    # @kwdef-defaults — and every model reaching the migration planner passes through here
    # (`synthesize_many_to_many_through_models`). Dropping `db_table` left the plan keyed by the
    # physical name while the model it renders from had reverted to the logical one, so
    # `CREATE TABLE` and the FK `REFERENCES` disagreed — the exact split this option closes — and a
    # second `makemigrations` proposed dropping the live table.
    #
    # Gated on `model_has_db_table` rather than reading `model.db_table`: the signature accepts any
    # `PormGModel`, and a bare `model_table_name` would wrongly PIN the logical name onto every model
    # that declares no override.
    db_table=(model_has_db_table(model) ? model_table_name(model) : nothing),
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
    # These two labels are NOT real Julia bindings, and nothing here reads them as such: on this
    # lifecycle the relation is a transient carrier for the through-table SHAPE only — the five slots
    # consumed below are `through_table`, `owner_column`, `related_column`, `owner_pk`, `related_pk`,
    # and the relation is then discarded rather than stored on a model. So `_resolve_m2m_side_model`
    # never sees these, and their spelling cannot reach a `getfield`.
    #
    # #343 note, so the next reader does not "fix" this into the trap in reverse: the identity scan
    # `_find_model_binding_name` uses is UNAVAILABLE here. `_load_current_models` (planner.jl) builds
    # the schema by `Base.include`ing the model file into a throwaway module and deliberately never
    # runs `set_models`, so `source_model._module` is `nothing` on the makemigrations path. Deriving
    # from the model's LOGICAL name is therefore the only option — and it is a harmless one, because
    # these slots are write-only here. Retiring them properly is #68/#41.
    #
    # Derive from the LOGICAL name, not the dict key: the key is the resolved PHYSICAL table name
    # (#59) and would carry a `db_table` spelling into a Julia-side label. Identical output for every
    # model without `db_table`, since the key is that same logical name lowercased.
    owner_binding = uppercasefirst(format_model_name(source_model.name))
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
      # `through_table` is the physical name on both branches of `_relation_from_many_to_many`, but
      # this loop only ever reaches the AUTO one (`field.through === nothing || continue` above), so
      # the synthesized model's own name IS its table and the planner's physical keying holds (#363).
      through_model = Model(relation.through_table, through_fields)
      through_model.cache["many_to_many_auto"] = Dict{String, Any}(
        "owner_column" => relation.owner_column,
        "related_column" => relation.related_column,
        "unique_index" => "$(relation.through_table)_$(relation.owner_column)_$(relation.related_column)_uniq",
      )
      through_key = Symbol(relation.through_table)
      if haskey(expanded, through_key)
        existing = expanded[through_key][:model]
        existing_auto = existing.cache !== nothing ? get(existing.cache, "many_to_many_auto", nothing) : nothing
        if existing_auto === nothing ||
           get(existing_auto, "owner_column", nothing) != relation.owner_column ||
           get(existing_auto, "related_column", nothing) != relation.related_column
          throw(ModelDefinitionError(
            "Auto-generated through table $(relation.through_table) for $(source_model.name).$(field_name) " *
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

Format the input `x` as a Julia source literal if it is a `String`, otherwise return `x` as is.

Used to render generated model files (`Model_to_str`). The value is `escape_string`d because the
strings reaching it are no longer all pre-validated identifiers: since #317 an arbitrary live column
name can arrive here as a `db_column = "…"` value, and `db_table = "…"` (#59) has always been able to.
A column named `say "hi"` would otherwise emit source that does not parse.

The `esc` argument REPLACES `escape_string`'s default rather than adding to it, so it must list `"`
as well as `\$`. Both are needed: an unescaped `"` closes the literal early, and an unescaped `\$`
emits source that parses but silently *interpolates* — `cost\$usd` would become the value of `usd`
rather than the column name. (A backslash is escaped unconditionally, `esc` or not.)
"""
function format_string(x)
  if x isa String
    return "\"$(escape_string(x, "\$\""))\""
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