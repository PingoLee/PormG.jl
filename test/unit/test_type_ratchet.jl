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
# Three patterns:
#   1. struct fields typed `Any` or left abstract — read by reflection, since a text scan cannot tell
#      whether `x::PormGField` or an alias is abstract;
#   2. `getfield(<x>, Symbol(…))` — a binding looked up by a name at run time (line scan);
#   3. `format::Dict{String,Any}` parameters — the Dialect functions' untyped option bag (line scan).
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
  "src/Configuration.jl" => 4,
  "src/ConnectionPool.jl" => 9,
  "src/Models.jl" => 5,
  "src/column_ir.jl" => 4,
  "src/exceptions.jl" => 3,
  "src/migrations/column_spec.jl" => 1,
  "src/migrations/importers.jl" => 2,
  "src/models/fields.jl" => 68,
  "src/querybuilder/many_to_many.jl" => 4,
  "src/querybuilder/parameters.jl" => 1,
  "src/querybuilder/types.jl" => 36,
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
  # #1346 baseline (19 sites); 20 since #1333.
  "src/Models.jl" => 2,                          # a relation's target model by binding name (#211)
  "src/migrations/importers.jl" => 3,            # a field constructor by its name, from introspection
  "src/models/fields.jl" => 2,                   # a field type's default instance by its name; a field
                                                 # type's accepted keywords by a name that arrives as a
                                                 # string (#1333: the importers, the refusal message)
  "src/querybuilder/build_helpers.jl" => 1,      # a lookup transform by name
  "src/querybuilder/execution_write.jl" => 1,    # a foreign key's target model by binding name (#211)
  "src/querybuilder/filter_nodes.jl" => 1,       # Dialect operator by name
  "src/querybuilder/filter_operators.jl" => 3,   # Dialect operators by name
  "src/querybuilder/join_conditions.jl" => 5,    # a related model by binding name (#211)
  "src/querybuilder/select_nodes.jl" => 2,       # Dialect function by name
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
const _TR_FORMAT_DICT_REVIEWED = Dict{String,Int}(
  "src/Dialect.jl" => 119,   # #1346 baseline
)

@testset "#1346: format::Dict{String,Any} parameters match the reviewed counts" begin
  _tr_check("format::Dict{String,Any} parameters", _tr_scan(_TR_FORMAT_DICT), _TR_FORMAT_DICT_REVIEWED)
  @test occursin(_TR_FORMAT_DICT, "function SUM(x::String, format::Dict{String,Any}, conn::PormGSQLite)")
  @test occursin(_TR_FORMAT_DICT, "AVG(x, format::Dict{String, Any}, conn)")
  @test !occursin(_TR_FORMAT_DICT, "kwargs::Dict{String,Any}")
end
