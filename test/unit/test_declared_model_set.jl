"""
A models module declares its model set; registration never scans the module's names (#1602).

Registration used to find a module's models by walking `names(mod; all = true, imported = true)` and
again with `usings = true` (#354), reading every name and keeping what was a model: reflection a
`juliac --trim` binary cannot follow (#1599 round 3, row 8), and action at a distance. A module now
carries `__pormg_models__::ModelSet`, written by `Models.@models Circuit Race` (the Generator writes
it) or added by `@import_models` / `import_models` / `@models_module` from the file's top-level
`X = Models.Model(…)` assignments. One parser, `_declared_model_bindings`, serves every writer.

No SQL anywhere: registration renders nothing. Hermetic — a mock backend, `Module` objects and files
in a temporary directory, no database.

    julia --project=test/integration test/unit/test_declared_model_set.jl
"""

using Test
using Logging
using PormG
import PormG.Models
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

struct DmsMockPostgres <: PormG.PormGPostgres end
PormG.config["dms_mock"] = PormG.Configuration.Settings(
  connections = DmsMockPostgres(), change_data = true, db_def_folder = "dms_mock")

_dms_body(src::AbstractString) = Meta.parse("module X\n" * src * "\nend").args[3]

# ─────────────────────────────────────────────────────────────────────────────
# The parser: which assignments are models
# What it tests: `_declared_model_bindings` lists a binding for each top-level `X = Model(…)`,
#   `X::T = Model(…)`, `const X = Model(…)` and `X = ModelType(…)`, under any qualification of
#   `Model`, in order, with `begin … end` blocks walked; a non-model assignment, a function body and a
#   nested module are not. Expected: [:Circuit, :Race, :Driver, :Status, :Lap]. No SQL.
# Why it matters: every writer of the set (the macros, the reload, the planner, the Generator) uses
#   this one parser, so what it misses is what none of them registers.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the parser lists each top-level model assignment, in order (#1602)" begin
  body = _dms_body("""
    import PormG.Models
    Circuit::Models.ModelType = Models.Model(circuitid = Models.IDField())
    Race = PormG.Models.Model("race", raceid = Models.IDField())
    const Driver = Model(driverid = Models.IDField())
    begin
      Status = Models.Model(statusid = Models.IDField())
    end
    Lap = Models.ModelType(name = "lap", fields = PormG.OrderedCollections.OrderedDict{String, PormG.PormGField}())
    CHAIN_N = 14
    helper() = (Hidden = Models.Model(id = Models.IDField()))
    module Inner
      Nested = Models.Model(id = Models.IDField())
    end
  """)
  @test Models._declared_model_bindings(body) == [:Circuit, :Race, :Driver, :Status, :Lap]
end

# ─────────────────────────────────────────────────────────────────────────────
# `@models` writes the set; `_with_model_set` adds one only when it is missing
# What it tests: `@models` expands to a `ModelSet` of the listed bindings and refuses a non-name or a
#   repeated name with an `ArgumentError` (Julia-level macro misuse). `_with_model_set` appends a
#   derived `@models` to a module that writes none, leaves a module that writes one as it is, and
#   warns when that module's list leaves out a top-level model assignment. No SQL.
# Why it matters: an explicit declaration is authoritative; the warning is the one signal that an edit
#   added a model and forgot the list.
# ─────────────────────────────────────────────────────────────────────────────
@testset "@models writes the set; _with_model_set adds one only when it is missing (#1602)" begin
  mod = Module(:DmsMacro)
  Core.eval(mod, :(import PormG.Models))
  Core.eval(mod, :(Models.@models Circuit Race))
  set = Models._model_set(mod)
  @test set isa Models.ModelSet
  @test set.bindings == [:Circuit, :Race]
  # Macro expansion wraps the error in a `LoadError`; the `ArgumentError` is its `error`.
  for bad in (:(Models.@models Circuit "race"), :(Models.@models Circuit Circuit))
    err = try Core.eval(mod, bad); nothing catch e; e end
    @test err isa LoadError && err.error isa ArgumentError
  end

  derived = Models._with_model_set(Meta.parse("module A\nC = Models.Model(id = 1)\nend"))
  @test Models._declares_model_set(derived.args[3])
  last_stmt = derived.args[3].args[end]
  @test last_stmt.head === :macrocall && last_stmt.args[3:end] == [:C]

  explicit = Meta.parse("module B\nC = Models.Model(id = 1)\nD = Models.Model(id = 2)\nModels.@models C\nend")
  @test_logs (:warn, r"assigns `D` with `Models.Model\(…\)` but its `Models.@models` line does not list it") (
    @test Models._with_model_set(explicit) === explicit)
  @test Models._with_model_set(:(x = 1)) == :(x = 1)
end

# ─────────────────────────────────────────────────────────────────────────────
# Registration reads the set, and refuses a module without one
# What it tests: `set_models` on a module that declares `Circuit` and `Race` binds both and fills
#   `Model(; …)`'s empty name from the declared binding; `get_all_models` returns the declared models
#   in declaration order; a module with no declaration raises `ModelDefinitionError` naming the module
#   and `Models.@models`; a declared binding that is unbound or not a model is refused by name.
#   `get_all_models` of an undeclared module is empty. No SQL.
# Why it matters: the refusal is what replaces the scan — an undeclared module is told what to add
#   instead of having its models guessed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "registration reads the declared set and refuses a module without one (#1602)" begin
  mod = Module(:DmsDeclared)
  Core.eval(mod, quote
    import PormG.Models
    Circuit::Models.ModelType = Models.Model(circuitid = Models.IDField(), name = Models.CharField())
    Race::Models.ModelType = Models.Model(raceid = Models.IDField(),
      circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"))
  end)
  Core.eval(mod, :(Models.@models Race Circuit))
  Base.invokelatest(Models.set_models, mod, "dms_mock")
  circuit = Base.invokelatest(getfield, mod, :Circuit)
  @test circuit.name == "circuit"
  @test Models.connection_key(circuit) == "dms_mock"
  @test Models.get_all_models(mod; symbol = true) == [:Race, :Circuit]

  bare = Module(:DmsUndeclared)
  Core.eval(bare, :(import PormG.Models; Circuit = Models.Model(circuitid = Models.IDField())))
  err = try Base.invokelatest(Models.set_models, bare, "dms_mock"); nothing catch e; e end
  @test err isa PormG.ModelDefinitionError
  @test occursin("DmsUndeclared", err.msg) && occursin("Models.@models", err.msg)
  @test isempty(Models.get_all_models(bare))

  unbound = Module(:DmsUnbound)
  Core.eval(unbound, :(import PormG.Models))
  Core.eval(unbound, :(Models.@models Ghost))
  err = try Base.invokelatest(Models.set_models, unbound, "dms_mock"); nothing catch e; e end
  @test err isa PormG.ModelDefinitionError && occursin("`Ghost`", err.msg)

  notmodel = Module(:DmsNotModel)
  Core.eval(notmodel, :(import PormG.Models; Laps = 58))
  Core.eval(notmodel, :(Models.@models Laps))
  err = try Base.invokelatest(Models.set_models, notmodel, "dms_mock"); nothing catch e; e end
  @test err isa PormG.ModelDefinitionError && occursin("`Laps` holds a Int64", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# A file without a declaration: `import_models` adds it; `include` + `set_models` refuses
# What it tests: the same file, written with no `Models.@models` line, registers through
#   `import_models` (which includes it with `_with_model_set`) and is refused through plain
#   `include` + `set_models`; with the line, plain `include` registers. No SQL.
# Why it matters: the package boot (`include` in the module body, `set_models` in `__init__`) has no
#   macro to add the set, so the file must carry it, and the refusal says so.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a file without a declaration registers through import_models, not through include (#1602)" begin
  dir = mktempdir()
  folder = joinpath(dir, "dms_db")
  mkpath(folder)
  file = joinpath(folder, "dms_models.jl")
  src(decl) = """
  module dms_models
  import PormG.Models
  Circuit::Models.ModelType = Models.Model("dms_circuit", circuitid = Models.IDField())
  $(decl)
  end
  """
  write(file, src(""))
  PormG.config[folder] = PormG.Configuration.Settings(
    connections = DmsMockPostgres(), change_data = true, db_def_folder = folder)
  try
    imported = PormG.import_models(file; into = Module(:DmsImportInto))
    # `invokelatest`: the module was included by a call inside this testset, so its bindings are
    # newer than this world (#1607: the set is read in the caller's world).
    @test Base.invokelatest(Models.get_all_models, imported; symbol = true) == [:Circuit]
    @test Models.connection_key(Base.invokelatest(getfield, imported, :Circuit)) == folder

    plain = Base.include(Module(:DmsPlainInto), file)
    err = try Base.invokelatest(Models.set_models, plain, folder); nothing catch e; e end
    @test err isa PormG.ModelDefinitionError

    write(file, src("Models.@models Circuit"))
    declared = Base.include(Module(:DmsDeclaredInto), file)
    Base.invokelatest(Models.set_models, declared, folder)
    @test Models.connection_key(Base.invokelatest(getfield, declared, :Circuit)) == folder
  finally
    pop!(PormG.config, folder, nothing)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The migration planner reads the same set
# What it tests: `Migrations._load_current_models` on a file with no declaration keys the model on its
#   table (`dms_plan_circuit`) — the set `_with_model_set` added; a non-model global in the file is not
#   a model. No SQL.
# Why it matters: `makemigrations` and `check` load the models file without `set_models`; they must
#   see the same models registration does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the migration planner reads the declared set (#1602)" begin
  dir = mktempdir()
  file = joinpath(dir, "models.jl")
  write(file, """
  module models
  import PormG.Models
  Circuit::Models.ModelType = Models.Model("dms_plan_circuit", circuitid = Models.IDField())
  NOT_A_MODEL = 3
  end
  """)
  schema = PormG.Migrations._load_current_models(file)
  @test collect(keys(schema)) == [:dms_plan_circuit]
end

# ─────────────────────────────────────────────────────────────────────────────
# The Generator writes the declaration
# What it tests: `Generator._model_set_line` writes `Models.@models A B` on one line when it fits in 100
#   columns and the parenthesized, wrapped form otherwise, and both parse back to the same list. No SQL.
# Why it matters: a generated file is registered by plain `include` in a package; without the line it
#   would be refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the Generator writes the declaration, wrapped when long (#1602)" begin
  short = PormG.Generator._model_set_line([:Circuit, :Race])
  @test short == "Models.@models Circuit Race"
  many = [Symbol("Model_number_", i) for i in 1:20]
  long = PormG.Generator._model_set_line(many)
  @test startswith(long, "Models.@models(\n") && endswith(long, "\n)")
  @test all(l -> length(l) <= 100, split(long, '\n'))
  parsed = Meta.parse(long)
  @test parsed.args[3:end] == many
  @test PormG.Generator._model_set_line(Symbol[]) == "Models.@models"
end
