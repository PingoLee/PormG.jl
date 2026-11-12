# ==============================================================================
# Concrete types and fewer allocations: a ratchet (#1346)
#
# Untyped code costs a dynamic dispatch and an allocation on every call, and it is what a static
# compiler (`juliac --trim`) cannot follow. PormG does not chase that as a project: code that is added
# or refactored moves toward concrete types and never away from them (CONTRIBUTING.md → *Conventions
# the suite enforces*). This file holds the reviewed count of each pattern that remains, per file.
#
# A count that RISES fails: type the new code instead (the rule names the alternative for each
# pattern below), and if the pattern is still the right shape, raise the count with a word on why. A
# count that FALLS fails too, so the improvement is recorded: lower the number in the same change.
# Either way the failure prints the sites of each file whose count moved.
#
# Four patterns:
#   1. struct fields typed `Any` or left abstract — read by reflection, since a text scan cannot tell
#      whether `x::PormGField` or an alias is abstract;
#   2. `getfield(<x>, Symbol(…))` — a binding looked up by a name at run time (line scan);
#   3. `format::Dict{String,Any}` parameters — the Dialect functions' untyped option bag (line scan);
#   4. `Core.Box` — a captured variable a closure reassigns (lowered code, #1697).
# A line scan skips whole-line comments only; a site in a trailing comment or a docstring code block
# counts, and is reworded rather than reviewed.
#
# Run: julia --project=test/integration test/unit/test_type_ratchet.jl
# ==============================================================================

using Test
using PormG
# The `ext/` structs exist only once their driver is loaded; the suite loads all four (runtests.jl).
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _TR_ROOT = pkgdir(PormG)

# Every `.jl` file under src/ and ext/, keyed by its path from the package root with '/' (Windows too).
function _tr_files()
  out = Pair{String,String}[]
  for top in ("src", "ext"), (dir, _, files) in walkdir(joinpath(_TR_ROOT, top)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(dir, f)
    push!(out, replace(relpath(path, _TR_ROOT), '\\' => '/') => path)
  end
  return sort!(out)
end

# Per file, the lines matching `pattern` (one entry per match, so two on a line are two). A comment
# line is not a site.
function _tr_scan(pattern::Regex)
  found = Dict{String,Vector{String}}()
  for (key, path) in _tr_files()
    hits = String[]
    open(path) do io
      for (i, l) in enumerate(eachline(io))
        startswith(lstrip(l), "#") && continue
        for _ in eachmatch(pattern, l)
          push!(hits, "$(i): $(strip(l))")
        end
      end
    end
    isempty(hits) || (found[key] = hits)
  end
  return found
end

# Exact equality per file, with the sites printed for a file whose count moved.
function _tr_check(what::String, found::Dict{String,Vector{String}}, reviewed::Dict{String,Int})
  for key in sort!(collect(union(keys(found), keys(reviewed))))
    got, want = length(get(found, key, String[])), get(reviewed, key, 0)
    if got > want
      @info "$(what) in $(key): $(got), reviewed $(want). Type the new code (CONTRIBUTING.md → " *
            "Conventions the suite enforces), or raise the reviewed count with a word on why." sites = get(found, key, String[])
    elseif got < want
      @info "$(what) in $(key): $(got), reviewed $(want). An improvement: lower the reviewed count " *
            "to $(got) in this change, so it is recorded." sites = get(found, key, String[])
    end
    @test (key, got) == (key, want)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 1. Struct fields typed `Any` or left abstract
# Every read of such a field is a dynamic dispatch, and a value stored in it is boxed; a static
# compiler cannot compile through it. A field is typed concretely, a small `Union` of concrete types
# (`Union{Nothing,String}`), or a type parameter of its struct. `Ref{T}` is abstract — a mutable box
# is `Base.RefValue{T}`. `Function` is abstract too: a stored callable is a type parameter
# (`struct S{F<:Function}; f::F; end`) when it has to be fast. A container of `Any` (`Vector{Any}`,
# `Dict{String,Any}`) is a concrete field and is not counted here.
# ─────────────────────────────────────────────────────────────────────────────
const _TR_FIELDS_REVIEWED = Dict{String,Int}(
  # #1346 baseline (141 fields). The largest share is every field struct's `formatter::Function` and
  # its `to`/`related_name` unions in models/fields.jl, and the query builder's slots typed by the
  # abstract `SQLType*` families in querybuilder/types.jl.
  "ext/PormGLibPQExt.jl" => 3,
  "src/AdvisoryLock.jl" => 1,
  "src/Configuration.jl" => 2,
  "src/ConnectionPool.jl" => 9,
  "src/Kernel.jl" => 2,                 # #1622: `Settings` moved here from Configuration.jl with its two
                                        # open fields, `connections` (any pool, test stand-ins included)
                                        # and the `before_connect` callable
  "src/Models.jl" => 4,                 # #1604: `ModelType.name::String` (was `AbstractString`)
  "src/column_ir.jl" => 4,
  "src/exceptions.jl" => 3,
  "src/migrations/column_spec.jl" => 1,
  "src/migrations/importers.jl" => 2,
  "src/models/fields.jl" => 65,         # #1599 layer 3: `sArrayField.base_field`, `ArrayFormatter.base`
                                        # and `.kind` closed (`ArrayElementField`, `_ArrayElementKind`)
  "src/querybuilder/many_to_many.jl" => 2,   # #1615: ManyToManyManager.owner_model/related_model
  "src/querybuilder/types.jl" => 28,    # #1698: the two `parameters` slots and `InstructionObject.object` closed (+1: `PgParameterizedQuery.parameters` moved in from parameters.jl); #1593: SQLTbAlias.count::Int; #1615: ObjectHandler.object, SQLObjectQuery.model/limit/offset, PormGRow._model
)

# :ok, :any or :abstract for one declared field type.
function _tr_classify(@nospecialize(T))
  T isa TypeVar && return :ok                       # the struct's own parameter
  T === Any && return :any
  T isa Union && return all(u -> _tr_classify(u) === :ok, Base.uniontypes(T)) ? :ok : :abstract
  T isa DataType || return :abstract                # a UnionAll left open
  isconcretetype(T) && return :ok
  if Base.has_free_typevars(T)                      # `Vector{T}` is concrete once T is; `Ref{T}` never is
    w = Base.unwrap_unionall(T.name.wrapper)
    (isabstracttype(w) || T.name === Base.typename(Tuple) || T.name === Base.typename(NamedTuple)) &&
      return :abstract
    return :ok
  end
  return :abstract
end

function _tr_modules!(acc::Vector{Module}, m::Module)
  m in acc && return acc
  push!(acc, m)
  for n in names(m; all = true)
    isdefined(m, n) || continue
    x = getglobal(m, n)
    x isa Module && x !== m && parentmodule(x) === m && _tr_modules!(acc, x)
  end
  return acc
end

# Each `ext/` file is its own extension module; one that is not loaded would read as a clean file.
# `PormGReviseExt` is not here: the suite does not load Revise, and it defines no struct.
const _TR_EXTENSIONS = (:PormGLibPQExt, :PormGPostgresExt, :PormGSQLiteExt, :PormGMySQLExt)

# The struct types PormG and its loaded extensions define (a compiler-generated `#…` closure type and a
# field-less type have nothing to count).
function _tr_struct_types()
  mods = _tr_modules!(Module[], PormG)
  for e in _TR_EXTENSIONS
    ext = Base.get_extension(PormG, e)
    ext === nothing || _tr_modules!(mods, ext)
  end
  types = Set{DataType}()
  for m in mods, n in names(m; all = true)
    startswith(String(n), "#") && continue
    isdefined(m, n) || continue
    x = getglobal(m, n)
    x isa Type || continue
    d = Base.unwrap_unionall(x)
    (d isa DataType && parentmodule(d) === m && isstructtype(d) && !isabstracttype(d) && fieldcount(d) > 0) ||
      continue
    push!(types, d)
  end
  return types
end

# Struct name → the files that define a struct of that name, by text: a reflected type does not
# record where it was defined.
const _TR_STRUCT_DEF = r"^\s*(?:(?:Base\.)?@kwdef\s+)?(?:mutable\s+)?struct\s+([A-Za-z_]\w*)"
function _tr_struct_index()
  index = Dict{String,Vector{String}}()
  for (key, path) in _tr_files()
    open(path) do io
      for l in eachline(io)
        m = match(_TR_STRUCT_DEF, l)
        m === nothing || push!(get!(index, String(m[1]), String[]), key)
      end
    end
  end
  return index
end

# The file of `d`: its one textual definition, or, for a name defined in two files, the one its
# methods were defined in. `nothing` for a struct generated by `@eval` — reported by name.
function _tr_struct_file(d::DataType, index)
  files = unique(get(index, String(nameof(d)), String[]))
  length(files) == 1 && return only(files)
  method_files = [replace(String(m.file), '\\' => '/') for m in methods(d.name.wrapper)]
  hits = filter(f -> any(mf -> endswith(mf, f), method_files), files)
  return length(hits) == 1 ? only(hits) : nothing
end

@testset "#1346: struct fields typed Any or left abstract match the reviewed counts" begin
  for e in _TR_EXTENSIONS
    @test Base.get_extension(PormG, e) !== nothing
  end
  index = _tr_struct_index()
  found = Dict{String,Vector{String}}()
  unplaced = String[]
  for d in _tr_struct_types()
    sites = String[]
    for (fname, ftype) in zip(fieldnames(d), fieldtypes(d))
      kind = _tr_classify(ftype)
      kind === :ok || push!(sites, "$(nameof(d)).$(fname)::$(ftype) ($(kind))")
    end
    isempty(sites) && continue
    file = _tr_struct_file(d, index)
    file === nothing && (push!(unplaced, "$(parentmodule(d)).$(nameof(d))"); continue)
    append!(get!(found, file, String[]), sites)
  end
  foreach(sort!, values(found))
  # A struct whose fields count but whose definition the text index cannot place (an `@eval`-built
  # one) would drop out of every file's count; name it so it gets a home.
  isempty(unplaced) || @info "structs with counted fields but no `struct` line in src/ or ext/" unplaced
  @test isempty(unplaced)
  _tr_check("struct fields typed Any or left abstract", found, _TR_FIELDS_REVIEWED)

  # The classifier sees what it is for — or a clean count proves nothing.
  @test _tr_classify(Any) === :any
  @test _tr_classify(Int) === :ok
  @test _tr_classify(Union{Nothing,String}) === :ok
  @test _tr_classify(Union{Nothing,AbstractString}) === :abstract
  @test _tr_classify(Ref{Int}) === :abstract
  @test _tr_classify(Base.RefValue{Int}) === :ok
  @test _tr_classify(Function) === :abstract
  @test _tr_classify(Vector{Any}) === :ok
  let T = TypeVar(:T)
    @test _tr_classify(T) === :ok
    @test _tr_classify(Vector{T}) === :ok
    @test _tr_classify(Ref{T}) === :abstract
  end
  @test _tr_classify(Tuple{Vararg{String}}) === :abstract
  @test _tr_classify(Vector) === :abstract
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. `getfield(<x>, Symbol(…))`: a binding looked up by a name at run time
# Inference cannot say what comes back, so everything downstream dispatches dynamically, and a static
# compiler cannot see which function is reached. A choice between behaviors dispatches on a type (or
# on a value type, `Val(:op)`, resolved once at the edge). Today's sites are Dialect operators and
# functions called by name, a model's related model resolved by its binding name (run-time model
# loading, #211), the importers building a field by its constructor's name, and a transform or a
# field's default looked up in its own module. `getproperty`/`getglobal` and the
# `invokelatest(getfield, m, Symbol(…))` form count the same. A backtick before the call is a
# docstring's code span, not a call.
# ─────────────────────────────────────────────────────────────────────────────
const _TR_GETFIELD = r"(?<!`)\bget(?:field|property|global)\b(?:\(|\s*,)\s*[@\w.]+\s*,\s*Symbol\("
const _TR_GETFIELD_REVIEWED = Dict{String,Int}(
  # #1346 baseline (19 sites); 20 since #1333; 19 since #1332; 16 since #1601 (a relation's target
  # is resolved at registration, never looked up by binding name).
  "src/migrations/importers.jl" => 3,            # a field constructor by its name, from introspection
  "src/models/fields.jl" => 2,                   # a field type's default instance by its name; a field
                                                 # type's accepted keywords by a name that arrives as a
                                                 # string (#1333: the importers, the refusal message)
  # #1611: the querybuilder's operator, function and transform lookups are branches generated at
  # definition time from their name lists, and a related model by its binding goes through
  # `Models._resolve_target_model` (`_bound_model`, join_conditions.jl). execution_write.jl's one site,
  # `_row_related_model`, was removed by the model-graph work (#1601): the query path reads the model
  # registration recorded.
)

@testset "#1346: getfield(<x>, Symbol(…)) sites match the reviewed counts" begin
  _tr_check("getfield(<x>, Symbol(…)) sites", _tr_scan(_TR_GETFIELD), _TR_GETFIELD_REVIEWED)
  @test occursin(_TR_GETFIELD, "  return getfield(Dialect, Symbol(op))(conn, column, ph)")
  @test occursin(_TR_GETFIELD, "foreign = getfield(q.model._module, Symbol(field_to))")
  @test occursin(_TR_GETFIELD, "resp = getfield(@__MODULE__, Symbol(name))(x)")
  @test occursin(_TR_GETFIELD, "related = Base.invokelatest(getfield, model._module, Symbol(to))")
  @test occursin(_TR_GETFIELD, "f = getglobal(Dialect, Symbol(op))")
  @test !occursin(_TR_GETFIELD, "six hand-rolled `getfield(mod, Symbol(field.to))` sites")
  @test !occursin(_TR_GETFIELD, "getfield(row, :name)")
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. `format::Dict{String,Any}` parameters
# The Dialect functions take their options as an untyped bag: every read is a hash lookup whose value
# type is unknown, and a misspelled key is a silent default rather than a MethodError. A new function
# takes typed arguments, a `NamedTuple` or a struct — not a new `Dict{String,Any}`. Counted across
# src/ and ext/, so one added outside Dialect.jl counts too. Keyed on the parameter name `format`,
# the pattern #1346 names: a line scan cannot tell another `x::Dict{String,Any}` parameter from a
# struct field or a type assertion of that type, so the rule covers those in review, not here.
# ─────────────────────────────────────────────────────────────────────────────
const _TR_FORMAT_DICT = r"\bformat::Dict\{String,\s*Any\}"
# #1610: zero. Every Dialect function takes its options as `Dialect.FnOptions`, one typed slot per key,
# built once from the query builder's resolved bag (`QueryBuilder._function_sql`). Any new one fails.
const _TR_FORMAT_DICT_REVIEWED = Dict{String,Int}()

@testset "#1346: format::Dict{String,Any} parameters match the reviewed counts" begin
  _tr_check("format::Dict{String,Any} parameters", _tr_scan(_TR_FORMAT_DICT), _TR_FORMAT_DICT_REVIEWED)
  @test occursin(_TR_FORMAT_DICT, "function SUM(x::String, format::Dict{String,Any}, conn::PormGSQLite)")
  @test occursin(_TR_FORMAT_DICT, "AVG(x, format::Dict{String, Any}, conn)")
  @test !occursin(_TR_FORMAT_DICT, "kwargs::Dict{String,Any}")
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. `Core.Box`: a captured variable that is reassigned (#1697)
# A closure that captures a local and reassigns it (`n = 0; lock(l) do … n += 1 end`), or a local
# reassigned after a closure captured it, makes the variable a `Core.Box`: an `Any` to every use, a
# dynamic call under the JIT, and in a `juliac --trim` image a verifier row or a run-time compile that
# fails (round 4 of #1600: `_close_pool_slots!`'s `in_use` aborted the Nitro pools probe's
# `close_pool!`). The variable a closure updates lives inside the closure and comes back as its value
# (`a, b = lock(l) do … return a, b end`), or the closure's own local gets its own name. Read from the
# lowered code of every method defined in a file, closures and keyword bodies included, with the
# detector test_terminal_pool_barrier.jl uses (helper_core_box.jl). src/querybuilder/ is counted
# there, per file, so it is left out here. A file whose methods are not loaded is not seen:
# ext/PormGReviseExt.jl (the suite does not load Revise) is reviewed by hand.
# ─────────────────────────────────────────────────────────────────────────────
include(joinpath(@__DIR__, "helper_core_box.jl"))

const _TR_BOX_REVIEWED = Dict{String,Int}(
  # #1697: src/ConnectionPool.jl 5 → 0 (`_close_pool_slots!`'s `in_use`, both `release_connection`s'
  # `retired`, both `_acquire_connection!`s' waiter `w`) and src/models/fields.jl 1 → 0 (`_int_kwarg`'s
  # `value`). The rest are older and counted, not fixed.
  "src/Dialect.jl" => 1,                       # alter_field's keyword body
  "src/Generator.jl" => 1,                     # create_db_folder_and_yml
  "src/migrations/column_spec.jl" => 1,        # field_from_spec
  "src/migrations/importers.jl" => 16,
  "src/migrations/introspection.jl" => 2,
  "src/migrations/planner.jl" => 2,
  "src/migrations/runner.jl" => 3,
  "src/models/pg_array.jl" => 1,               # parse_pg_array_literal
)

# src/ and ext/, except src/querybuilder/ (test_terminal_pool_barrier.jl counts it per file).
function _tr_in_scope(file::String)
  startswith(file, _TR_ROOT) || return false   # most of the method table: Base, stdlibs, packages
  key = _tr_key(file)
  return (startswith(key, "src/") || startswith(key, "ext/")) && !startswith(key, "src/querybuilder/")
end
_tr_key(file) = replace(relpath(file, _TR_ROOT), '\\' => '/')

@testset "#1697: Core.Box constructions match the reviewed counts" begin
  sites = core_box_sites(_tr_in_scope, _tr_key)
  _tr_check("Core.Box constructions (captured variables reassigned)", sites, _TR_BOX_REVIEWED)
  # The files #1697 cleared: named, so a new box there reads as what it is.
  @test get(sites, "src/ConnectionPool.jl", String[]) == String[]
  @test get(sites, "src/models/fields.jl", String[]) == String[]
  # The detector finds a box, and only where there is one, so a clean count proves something.
  @test core_boxes(Base.uncompressed_ast(only(methods(_core_box_boxing)))) == 1
  @test core_boxes(Base.uncompressed_ast(only(methods(_core_box_not_boxing)))) == 0
  # The extensions are loaded, or their files would read as clean.
  for e in _TR_EXTENSIONS
    @test Base.get_extension(PormG, e) !== nothing
  end
end
