# ============================================================
# test/unit/test_cascade_delete_trim_1694.jl
#
# CONTRACT being tested:
#   The typed forms a cascading delete now goes through in a trimmed image (#1599 layer 7, #1694) answer what the
#   forms they replaced answered, value for value, and raise what those raised:
#     - `_relation_on_delete` against `field.on_delete`, for every field type PormG defines (a field with no action
#       raises the same error);
#     - `_cascade_writes` (the child read at `ModelType`, the action by `_relation_on_delete`, compared with `===`)
#       against a copy of the old code, over parents with every kind of reverse relation;
#     - `_orders_deletes` against a copy of the old code, for every action;
#     - the key read's rows (`_key_vector_rows`, `_narrowed_keys`) against `_key_vector` over the same column read
#       through `Tables.columntable`: the same keys and the same vector type;
#     - `_root_key_chunks` (now at the keys' vector type) against a copy of the old code, on every engine's bind
#       limit: the same chunks with the same values and element types;
#   What a cascading delete runs end to end is pinned by the delete suites on every engine
#   (test/integration/test_deletes.jl) and the key read's equivalence on every engine
#   (test/integration/test_cascade_keys_equivalence_1694.jl).
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_cascade_delete_trim_1694.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.Models

const _CD_QB = PormG.QueryBuilder

struct CdMockSQLite <: PormG.PormGSQLite end
struct CdMockOldSQLite <: PormG.PormGSQLite end
struct CdMockPostgres <: PormG.PormGPostgres end
struct CdMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::CdMockSQLite) = 3045000
PormG.backend_sqlite_version(::CdMockOldSQLite) = 3031000
PormG.backend_mysql_parameter_limit(::CdMockMySQL) = 4096
PormG.config["cd_mock"] = PormG.Configuration.Settings(connections = CdMockSQLite(), change_data = true,
                                                       db_def_folder = "cd_mock")

# One parent per kind of reverse relation, and one with several: a race's children in the F1 shape.
module CdModels
import PormG
import PormG.Models
Cd_driver = Models.Model("cd_driver", driverid = Models.IDField(), surname = Models.CharField())
Cd_race_cascade = Models.Model("cd_race_cascade", raceid = Models.IDField())
Cd_race_set_null = Models.Model("cd_race_set_null", raceid = Models.IDField())
Cd_race_set_default = Models.Model("cd_race_set_default", raceid = Models.IDField())
Cd_race_protect = Models.Model("cd_race_protect", raceid = Models.IDField())
Cd_race_do_nothing = Models.Model("cd_race_do_nothing", raceid = Models.IDField())
Cd_race_unset = Models.Model("cd_race_unset", raceid = Models.IDField())
Cd_race_one_to_one = Models.Model("cd_race_one_to_one", raceid = Models.IDField())
Cd_race_m2m = Models.Model("cd_race_m2m", raceid = Models.IDField(),
  drivers = Models.ManyToManyField(Cd_driver, related_name = "m2m_races"))
Cd_race_lonely = Models.Model("cd_race_lonely", raceid = Models.IDField())
Cd_race_mixed = Models.Model("cd_race_mixed", raceid = Models.IDField())
Cd_pit_stop = Models.Model("cd_pit_stop", pitstopid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_cascade, on_delete = "CASCADE", related_name = "pit_stops"))
Cd_debut = Models.Model("cd_debut", debutid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_set_null, on_delete = "SET_NULL", null = true, related_name = "debuts"))
Cd_default = Models.Model("cd_default", defaultid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_set_default, on_delete = "SET_DEFAULT", default = 1, related_name = "defaults"))
Cd_flag = Models.Model("cd_flag", flagid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_protect, on_delete = "PROTECT", related_name = "flags"))
Cd_note = Models.Model("cd_note", noteid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_do_nothing, on_delete = "DO_NOTHING", related_name = "notes"))
Cd_tag = Models.Model("cd_tag", tagid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_unset, related_name = "tags"))
Cd_summary = Models.Model("cd_summary", summaryid = Models.IDField(),
  race = Models.OneToOneField(Cd_race_one_to_one, on_delete = "CASCADE", related_name = "summary"))
Cd_mixed_flag = Models.Model("cd_mixed_flag", flagid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_mixed, on_delete = "PROTECT", related_name = "mixed_flags"))
Cd_mixed_lap = Models.Model("cd_mixed_lap", lapid = Models.IDField(),
  race = Models.ForeignKey(Cd_race_mixed, on_delete = "CASCADE", related_name = "mixed_laps"))
Models.@models Cd_driver Cd_race_cascade Cd_race_set_null Cd_race_set_default Cd_race_protect Cd_race_do_nothing Cd_race_unset Cd_race_one_to_one Cd_race_m2m Cd_race_lonely Cd_race_mixed Cd_pit_stop Cd_debut Cd_default Cd_flag Cd_note Cd_tag Cd_summary Cd_mixed_flag Cd_mixed_lap
PormG.Models.set_models(@__MODULE__, "cd_mock")
end
const CD = CdModels

# ── The old code, as it was before #1599 layer 7 ─────────────────────────────────────────────────────────────────────

function _old_cascade_writes(model)::Bool
  for related_value in values(model.related_objects)
    related_value isa PormG.Models.ManyToManyRelation && continue
    rel = related_value::PormG.Models.ReverseRelation
    rel.model_resolved.fields[String(rel.fk_field)].on_delete in (_CD_QB.CASCADE, _CD_QB.SET_NULL, _CD_QB.SET_DEFAULT) && return true
  end
  return false
end

_old_orders_deletes(field)::Bool = !(field.on_delete === _CD_QB.SET_NULL || field.on_delete === _CD_QB.SET_DEFAULT)

function _old_root_key_chunks(connection, keys::AbstractVector)::Vector{AbstractVector}
  (isempty(keys) || _CD_QB._binds_list_as_array(connection)) && return AbstractVector[keys]
  size = max(1, fld(_CD_QB._backend_parameter_limit(connection), _CD_QB.ROOT_KEY_PATH_BUDGET))
  return AbstractVector[collect(chunk) for chunk in Iterators.partition(keys, size)]
end

# The value a call returns, or the type of the error it raises.
_outcome(f) = try
  (:value, f())
catch e
  (:error, typeof(e))
end

# One field of every type PormG defines.
const _CD_FIELDS = Any[
  Models.IDField(), Models.ForeignKey(CD.Cd_race_cascade, on_delete = "CASCADE"),
  Models.ForeignKey(CD.Cd_race_cascade, on_delete = "SET_NULL", null = true),
  Models.ForeignKey(CD.Cd_race_cascade, on_delete = "PROTECT"), Models.ForeignKey(CD.Cd_race_cascade),
  Models.ManyToManyField(CD.Cd_driver), Models.OneToOneField(CD.Cd_race_cascade, on_delete = "CASCADE"),
  Models.OneToOneField(CD.Cd_race_cascade), Models.CharField(), Models.IntegerField(),
  Models.PositiveSmallIntegerField(), Models.PositiveIntegerField(), Models.BigIntegerField(), Models.BooleanField(),
  Models.DateField(), Models.DateTimeField(), Models.DecimalField(), Models.EmailField(), Models.PasswordField(),
  Models.FloatField(), Models.ImageField(), Models.TextField(), Models.TimeField(), Models.BinaryField(),
  Models.DurationField(), Models.UUIDField(), Models.GenericIPAddressField(), Models.CIDRField(),
  Models.SearchVectorField(), Models.URLField(), Models.SlugField(), Models.JSONField(),
  Models.ArrayField(Models.IntegerField()),
]

@testset "A field's on_delete is read at its type as it was read on the union (#1599 layer 7)" begin
  # Expected SQL: none. Why: `_relation_on_delete` replaced `field.on_delete` on the field union, which a trimmed image
  # could not dispatch; it must give the same action for a relation and raise the same error for any other field.
  @test Set(typeof.(_CD_FIELDS)) == Set(Base.uniontypes(Models.AnyField))
  for f in _CD_FIELDS
    @test (typeof(f), _outcome(() -> _CD_QB._relation_on_delete(f))) == (typeof(f), _outcome(() -> f.on_delete))
  end
end

@testset "_cascade_writes answers what it answered (#1599 layer 7)" begin
  # Expected SQL: none. Why: the key step runs when this says true (#1342, #1370); the child is now read at
  # `ModelType` and the action compared with `===`, which must not change the answer for any kind of reverse relation.
  parents = [(CD.Cd_race_cascade, true), (CD.Cd_race_set_null, true), (CD.Cd_race_set_default, true),
             (CD.Cd_race_protect, false), (CD.Cd_race_do_nothing, false), (CD.Cd_race_unset, false),
             (CD.Cd_race_one_to_one, true), (CD.Cd_race_m2m, false), (CD.Cd_race_lonely, false),
             (CD.Cd_race_mixed, true), (CD.Cd_driver, false)]
  for (m, expected) in parents
    @test (m.name, _CD_QB._cascade_writes(m)) == (m.name, _old_cascade_writes(m))
    @test (m.name, _CD_QB._cascade_writes(m)) == (m.name, expected)
  end
end

@testset "_orders_deletes answers what it answered (#1599 layer 7)" begin
  # Expected SQL: none. Why: it decides which reverse relations order the DELETEs (#1374); the action is now read at
  # the field's type.
  for m in (CD.Cd_pit_stop, CD.Cd_debut, CD.Cd_default, CD.Cd_flag, CD.Cd_note, CD.Cd_tag, CD.Cd_summary)
    f = m.fields["race"]
    @test (m.name, _CD_QB._orders_deletes(f)) == (m.name, _old_orders_deletes(f))
  end
end

@testset "The decoded key rows give the keys Tables.columntable gave (#1599 layer 7)" begin
  # Expected SQL: none (the rows are built here, as each read delivers them). Why: on PormG's own pools the root's
  # keys are now read through the untyped read's decoder, one `Dict` per row, where they were read through
  # `Tables.columntable` over the result; the keys, and the vector type `"<pk>__@in"` receives, must be the same.
  cases = [
    "Int64 keys" => Any[3, 1, 2],
    "Int32 keys" => Any[Int32(7), Int32(9)],
    "String keys" => Any["monaco", "interlagos"],
    "keys with a NULL" => Any[1, missing, 2],
    "only NULLs" => Any[missing, missing],
    "UUID keys" => Any[Base.UUID(1), Base.UUID(2)],
    "one key" => Any[42],
    "no rows" => Any[],
  ]
  for (label, cells) in cases
    rows = Dict{Symbol, Any}[Dict{Symbol, Any}(:raceid => c) for c in cells]
    T = isempty(cells) ? Int : mapreduce(typeof, promote_type, cells)
    columns = (raceid = T[c for c in cells],)
    old = _CD_QB._key_vector(columns)
    new = _CD_QB._key_vector_rows(rows)
    @test (label, typeof(new)) == (label, typeof(old))
    @test (label, isequal(new, old)) == (label, true)
  end
end

@testset "_root_key_chunks gives the chunks it gave, at the keys' type (#1599 layer 7)" begin
  # Expected SQL: none. Why: the chunks are each a plan of the cascade within the engine's bind limit (#1342); they are
  # now `Vector{T}` where they were `AbstractVector`, with the same values in the same order.
  for engine in (CdMockSQLite(), CdMockOldSQLite(), CdMockPostgres(), CdMockMySQL())
    for keys in (Int[], [1], collect(1:5000), Int32.(1:3000), ["k$(i)" for i in 1:1200])
      old = _old_root_key_chunks(engine, keys)
      new = _CD_QB._root_key_chunks(engine, keys)
      @test (typeof(engine), length(new)) == (typeof(engine), length(old))
      @test all(a == b && typeof(a) === typeof(b) for (a, b) in zip(new, old))
      @test new isa Vector{Vector{eltype(keys)}}
    end
  end
end

# ── The collector's walk, as it was before #1599 layer 7 ─────────────────────────────────────────────────────────────
# The old functions call each other (the old graph), and everything they did not change in the current module.

function _old_process_collector!(collector)
  seeds = collect(collector.objects)
  for (model, keys) in seeds
    _old_find_related_objects!(collector, model::Models.ModelType, copy(keys))
  end
  _old_collect_fast_deletes!(collector)
  collector.sorted_models = _CD_QB.topological_sort(collector.delete_order)
end

function _old_collect_fast_deletes!(collector)
  models_with_dependents = Set{PormG.PormGModel}()
  for (model, dependencies) in collector.dependencies
    if !isempty(dependencies)
      push!(models_with_dependents, model::Models.ModelType)
      union!(models_with_dependents, dependencies)
    end
  end
  for (model, keys) in collector.objects
    if !((model::Models.ModelType) in models_with_dependents)
      collector.fast_deletes[model::Models.ModelType] = keys
    end
  end
end

function _old_find_related_objects!(collector, model, dict)
  push!(collector.traversal_path, model)
  try
    _old__find_related_objects!(collector, model, dict)
  finally
    pop!(collector.traversal_path)
  end
end

function _old__find_related_objects!(collector, model, dict)
  if length(collector.traversal_path) > _CD_QB.MAX_CASCADE_DEPTH
    tail = join([m.name for m in collector.traversal_path[max(1, end - 9):end]], " -> ")
    throw(PormG.QueryBuildError(
      "Error in delete: the cascade exceeded $(_CD_QB.MAX_CASCADE_DEPTH) levels while collecting dependents of " *
      "\e[4m\e[31m$(collector.model.name)\e[0m. The last models walked were " *
      "\e[4m\e[31m$(tail)\e[0m. Usually a foreign-key cycle: two models declared " *
      "\e[4m\e[32mon_delete = CASCADE\e[0m at each other, or self-referencing rows that form a " *
      "loop, make the collector descend without end — break the cycle, or give one side a " *
      "different on_delete and remove its rows first. If the chain above is genuinely acyclic, it " *
      "is simply deeper than \e[4m\e[32mMAX_CASCADE_DEPTH\e[0m, the fixed ceiling in " *
      "src/querybuilder/deletion.jl; delete it in stages, from the far end inward."
    ))
  end
  for (related_name, related_value) in model.related_objects
    related_value isa PormG.Models.ManyToManyRelation && continue
    rel = related_value::PormG.Models.ReverseRelation
    field_name = rel.fk_field
    related_model = rel.model_resolved
    collector.skip_self_cascade && model === collector.model && related_model === model &&
      related_model.fields[String(field_name)].on_delete === _CD_QB.CASCADE && continue
    _query = related_model |> _CD_QB.object;
    if size(dict, 1) == 1
      _query.filter("$(field_name)__@in" => dict[1][:objct]);
    else
      or_object = _CD_QB.Qor("$(field_name)__@in" => dict[1][:objct])
      for (index, dict_) in enumerate(dict)
        index == 1 && continue
        push!(or_object, "$(field_name)__@in" => dict_[:objct])
      end
      _query.filter(or_object)
    end
    should_check_existence = collector.show_query === :execute || _CD_QB.should_check_related_existence(collector)
    should_check_existence && (_query |> !_CD_QB._exists) && continue
    field = related_model.fields[String(field_name)]
    push!(get!(() -> Set{PormG.PormGModel}(), collector.dependencies, related_model), model)
    order = get!(() -> Set{PormG.PormGModel}(), collector.delete_order, related_model)
    _old_orders_deletes(field) && push!(order, model)
    _keys = _CD_QB._collector_entry(_CD_QB.resolve_delete_key(related_model; fallback=string(field_name)), _query)
    _old_handle_on_delete!(collector, field_name, field, model, _keys, related_model)
  end
end

function _old_handle_on_delete!(collector, field_name, field, model, keys, related_model)
  Q = _CD_QB
  if field.on_delete == Q.CASCADE
    _keys = _old_prepare_related_query(keys, related_model, field_name)
    Q.add_objects_to_collector!(collector, related_model, _keys[:key], _keys[:objct])
    _old_find_related_objects!(collector, related_model, [_keys])
  elseif field.on_delete in [Q.PROTECT, Q.RESTRICT]
    constraint_type = field.on_delete == Q.PROTECT ? "PROTECT" : "RESTRICT"
    throw(PormG.ProtectedError("Cannot delete \e[4m\e[31m$(model.name)\e[0m because it is referenced by \e[4m\e[31m$(related_model.name).$(field_name)\e[0m with ON DELETE \e[4m\e[31m$(constraint_type)\e[0m constraint"))
  elseif field.on_delete == Q.SET_NULL
    if !field.null
      throw(PormG.ModelDefinitionError("Error in delete: ON DELETE SET_NULL is declared on \e[4m\e[31m$(field_name)\e[0m, but the field has null=false — the schema contradicts itself. Declare the FK with null=true or use a different on_delete."))
    end
    if !haskey(collector.field_updates, (field_name |> string, nothing))
      collector.field_updates[(field_name |> string, nothing)] = Dict{PormG.PormGModel, Vector{Dict{Symbol, Union{String, PormG.SQLObjectHandler}}}}()
    end
    _old_push_field_update!(collector, (field_name |> string, nothing), related_model, keys, field_name)
  elseif field.on_delete == Q.SET_DEFAULT
    if field.default === nothing
      throw(PormG.ModelDefinitionError("Error in delete: ON DELETE SET_DEFAULT is declared on \e[4m\e[31m$(field_name)\e[0m, but the field has no default — the schema contradicts itself. Give the FK a default= or use a different on_delete."))
    end
    default_value = field.default
    if !haskey(collector.field_updates, (field_name |> string, default_value))
      collector.field_updates[(field_name |> string, default_value)] = Dict{PormG.PormGModel, Vector{Dict{Symbol, Union{String, PormG.SQLObjectHandler}}}}()
    end
    _old_push_field_update!(collector, (field_name |> string, default_value), related_model, keys, field_name)
  end
end

function _old_prepare_related_query(keys, related_model, field_name)
  delete_key = _CD_QB.resolve_delete_key(related_model; fallback=string(field_name))
  _query = _CD_QB._terminal_copy(keys[:objct])
  delete_key != _CD_QB.DIRECT_DELETE_KEY_SENTINEL && _query.values(delete_key)
  return _CD_QB._collector_entry(delete_key, _query)
end

function _old_push_field_update!(collector, bucket, related_model, keys, field_name)
  per_model = collector.field_updates[bucket]
  entries = get!(() -> Vector{Dict{Symbol, Union{String, PormG.SQLObjectHandler}}}(), per_model, related_model)
  push!(entries, _old_prepare_related_query(keys, related_model, field_name))
  return entries
end

function _old_models_to_lock(collector)
  emitters = Set{PormG.PormGModel}(keys(collector.objects))
  for affected in values(collector.field_updates)
    union!(emitters, keys(affected))
  end
  parents = Set{PormG.PormGModel}()
  for child in emitters
    union!(parents, get(collector.dependencies, child::Models.ModelType, Set{PormG.PormGModel}()))
  end
  out = PormG.PormGModel[]
  for m in reverse(collector.sorted_models)
    model = m::Models.ModelType
    (model in parents && haskey(collector.objects, model)) && push!(out, model)
  end
  return out
end

# A collector as text: every entry's key and the SQL its query renders, per model, in a fixed order.
_cd_sql(h) = h isa String ? h : string(_CD_QB.query(h; show_query = :sql))
_cd_entries(v) = [(e[:key], _cd_sql(e[:objct])) for e in v]
_cd_names(s) = sort([m.name for m in s])
function _cd_describe(c)
  return (
    objects = sort([(m.name, _cd_entries(v)) for (m, v) in c.objects]),
    dependencies = sort([(m.name, _cd_names(s)) for (m, s) in c.dependencies]),
    delete_order = sort([(m.name, _cd_names(s)) for (m, s) in c.delete_order]),
    field_updates = sort([(repr(k), sort([(m.name, _cd_entries(v)) for (m, v) in d])) for (k, d) in c.field_updates]),
    fast_deletes = sort([(m.name, _cd_entries(v)) for (m, v) in c.fast_deletes]),
    sorted_models = [m.name for m in c.sorted_models],
    models_to_lock = [m.name for m in _CD_QB._models_to_lock(c)],
  )
end

# The plan `delete()` makes for `root`, by the given walk, or the error it raises.
function _cd_plan(process!, model, root)
  settings = PormG.config["cd_mock"]
  c = _CD_QB.DeletionCollector(model, settings, :sql, false)
  return _outcome(() -> (_CD_QB.add_objects_to_collector!(c, root, model); process!(c); _cd_describe(c)))
end

@testset "The cascade's plan is the plan it was (#1599 layer 7)" begin
  # Expected SQL: none run (a mock pool, so no existence probe): each collected statement's query rendered. Why: the
  # collector's walk now reads each child at `ModelType`, each field at its type and each entry's query at
  # `ObjectHandler`; the models, the queries that scope their statements, the SET_NULL / SET_DEFAULT buckets, the
  # order, the fast deletes and the locks must be what they were, and a PROTECT must raise as it did.
  roots = [CD.Cd_race_cascade, CD.Cd_race_set_null, CD.Cd_race_set_default, CD.Cd_race_protect, CD.Cd_race_do_nothing,
           CD.Cd_race_unset, CD.Cd_race_one_to_one, CD.Cd_race_m2m, CD.Cd_race_lonely, CD.Cd_race_mixed]
  for m in roots, root_filter in (("raceid" => 1), ("raceid__@in" => [1, 2, 3]))
    old = _cd_plan(_old_process_collector!, m, m.objects.filter(root_filter))
    new = _cd_plan(_CD_QB.process_collector!, m, m.objects.filter(root_filter))
    @test (m.name, new) == (m.name, old)
  end
  # The locks are compared on a plan built by the current walk, since `_models_to_lock` reads only its result.
  for m in roots
    c = _CD_QB.DeletionCollector(m, PormG.config["cd_mock"], :sql, false)
    r = _outcome(() -> (_CD_QB.add_objects_to_collector!(c, m.objects.filter("raceid" => 1), m); _CD_QB.process_collector!(c)))
    r[1] === :error && continue
    @test (m.name, [x.name for x in _CD_QB._models_to_lock(c)]) == (m.name, [x.name for x in _old_models_to_lock(c)])
  end
end
