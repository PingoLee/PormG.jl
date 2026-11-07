"""
A models module declares its model set; registration never scans the module's names (#1602).

Registration used to find a module's models by walking `names(mod; all = true, imported = true)` and
again with `usings = true` (#354), reading every name and keeping what was a model: reflection a
`juliac --trim` binary cannot follow (#1599 round 3, row 8), and action at a distance. A module now
carries `MODEL_SET::ModelSet`, written by `Models.@models Circuit Race` (the Generator writes
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
  Core.eval(mod, :(Circuit = Models.Model(circuitid = Models.IDField())))
  Core.eval(mod, :(Race = Models.Model(raceid = Models.IDField())))
  Core.eval(mod, :(Models.@models Circuit Race))
  set = Base.invokelatest(Models._model_set, mod)
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
#   and `Models.@models`; a declared binding that is unbound fails at the `@models` line (it captures
#   the models, #1606) and one that holds no model is refused there by name.
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
  # The set captures the models when its line runs (#1606), so an unbound binding fails right there.
  err = try Core.eval(unbound, :(Models.@models Ghost)); nothing catch e; e end
  @test err isa UndefVarError && err.var === :Ghost

  notmodel = Module(:DmsNotModel)
  Core.eval(notmodel, :(import PormG.Models; Laps = 58))
  err = try Core.eval(notmodel, :(Models.@models Laps)); nothing catch e; e end
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

# ─────────────────────────────────────────────────────────────────────────────
# Review fixes: where the generated declaration lands, and a nested explicit one
# What it tests: (a) an older generated file that ends with `Models.set_models(@__MODULE__, …)` in its
#   own body loads through `import_models`: the generated declaration is inserted right after the last
#   model, before that call, so the call sees the set; (b) an explicit `@models` inside a top-level
#   `begin … end` block, or under a docstring, counts as the module's declaration, so none is
#   generated over it and nothing it lists is reported as left out; (c) one inside an `if` does not
#   count, since it may not run: the line is generated, so the planner sees both models of a file
#   whose `if` branch is not taken. No SQL.
# Why it matters: (a) loaded before #1602 and must not start failing mid-include; (b) a generated
#   declaration would merge every top-level model into the user's list, overriding a deliberate
#   omission; (c) a declaration counted but never run leaves no set, which the planner would read as
#   declaring nothing — every table planned as a drop.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the generated declaration goes after the models; a nested one counts (#1602)" begin
  dir = mktempdir()
  folder = joinpath(dir, "dms_legacy")
  mkpath(folder)
  file = joinpath(folder, "legacy_models.jl")
  write(file, """
  module legacy_models
  import PormG.Models
  Circuit::Models.ModelType = Models.Model("dms_legacy_circuit", circuitid = Models.IDField())
  Models.set_models(@__MODULE__, @__DIR__)
  end
  """)
  PormG.config[folder] = PormG.Configuration.Settings(
    connections = DmsMockPostgres(), change_data = true, db_def_folder = folder)
  try
    mod = PormG.import_models(file; into = Module(:DmsLegacyInto))
    @test Models.connection_key(Base.invokelatest(getfield, mod, :Circuit)) == folder
  finally
    pop!(PormG.config, folder, nothing)
  end

  nested = Meta.parse("""
  module N
  import PormG.Models
  begin
    A = Models.Model(id = Models.IDField())
    Models.@models A B
  end
  end""")
  @test Models._declares_model_set(nested.args[3])
  @test (@test_logs min_level = Logging.Warn Models._with_model_set(nested)) === nested   # no warning

  documented = Meta.parse("module models\nimport PormG.Models\nCircuit = Models.Model(circuitid = Models.IDField())\n" *
                          "\"\"\"The F1 model set.\"\"\"\nModels.@models Circuit\nend")
  @test Models._declares_model_set(documented.args[3])
  @test (@test_logs min_level = Logging.Warn Models._with_model_set(documented)) === documented

  # (c) An `@models` in an `if` branch that is not taken: the generated line still lists both models.
  plan_dir = mktempdir()
  plan_file = joinpath(plan_dir, "models.jl")
  write(plan_file, """
  module models
  import PormG.Models
  Circuit::Models.ModelType = Models.Model("dms_if_circuit", circuitid = Models.IDField())
  Race::Models.ModelType = Models.Model("dms_if_race", raceid = Models.IDField())
  if get(ENV, "DMS_NEVER_SET_F1", "") == "1"
    Models.@models Circuit
  end
  end
  """)
  @test !Models._declares_model_set(Meta.parse(read(plan_file, String)).args[3])
  @test sort(collect(keys(PormG.Migrations._load_current_models(plan_file)))) == [:dms_if_circuit, :dms_if_race]
end

# ─────────────────────────────────────────────────────────────────────────────
# A documented model and a `global` model are read by the generated declaration
# What it tests: `_declared_model_bindings` reads `"""doc""" X = Model(…)` (a `Core.@doc` macrocall
#   around the assignment), `global X = Model(…)` and `global X::T = Model(…)`. For each shape, a file
#   whose two models (`Circuit`, `Race`) are written that way and that has no `Models.@models` line:
#   `@import_models` registers both; `Migrations._load_current_models` keys both tables
#   (`dms_shape_circuit`, `dms_shape_race`); and the Revise reload (`Utils.reload_module_contents!`) of
#   a module first loaded with `Circuit` alone puts the added `Race` in its set. No SQL.
# Why it matters: the generated line used to skip both shapes in silence, and a model left out of the
#   set is one `makemigrations` plans to drop.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a documented or global model is in the generated set (#1602)" begin
  body = _dms_body("""
    import PormG.Models
    \"\"\"A circuit.\"\"\"
    Circuit::Models.ModelType = Models.Model(circuitid = Models.IDField())
    global Race = Models.Model(raceid = Models.IDField())
    global Lap::Models.ModelType = Models.Model(lapid = Models.IDField())
    \"\"\"A pit stop.\"\"\"
    const Pit = Models.Model(pitid = Models.IDField())
    @doc "A driver." Driver = Models.Model(driverid = Models.IDField())
  """)
  @test Models._declared_model_bindings(body) == [:Circuit, :Race, :Lap, :Pit, :Driver]


  shapes = Dict(
    :doc => (b, t) -> "\"\"\"The $(t) table.\"\"\"\n$(b)::Models.ModelType = Models.Model(\"$(t)\", id = Models.IDField())",
    :global => (b, t) -> "global $(b) = Models.Model(\"$(t)\", id = Models.IDField())")
  for (shape, model) in shapes
    dir = mktempdir()
    folder = joinpath(dir, "dms_shape_$(shape)")
    mkpath(folder)
    file = joinpath(folder, "shape_models.jl")
    write_models(ms...) = write(file, "module models\nimport PormG.Models\n" * join(ms, "\n") * "\nend\n")
    write_models(model(:Circuit, "dms_shape_circuit"), model(:Race, "dms_shape_race"))
    PormG.config[folder] = PormG.Configuration.Settings(
      connections = DmsMockPostgres(), change_data = true, db_def_folder = folder)
    try
      host = Module(Symbol("DmsShapeHost_", shape))
      Core.eval(host, :(using PormG))
      Core.eval(host, :(PormG.@import_models $file models))   # the planner reads a module named `models`
      mod = Base.invokelatest(getfield, host, :models)
      @test Base.invokelatest(Models.get_all_models, mod; symbol = true) == [:Circuit, :Race]
      @test Models.connection_key(Base.invokelatest(getfield, mod, :Race)) == folder

      @test sort(collect(keys(PormG.Migrations._load_current_models(file)))) ==
            [:dms_shape_circuit, :dms_shape_race]

      write_models(model(:Circuit, "dms_shape_circuit"))
      reloaded = PormG.import_models(file; into = Module(Symbol("DmsShapeReload_", shape)))
      @test Base.invokelatest(Models.get_all_models, reloaded; symbol = true) == [:Circuit]
      write_models(model(:Circuit, "dms_shape_circuit"), model(:Race, "dms_shape_race"))
      @test PormG.Utils.reload_module_contents!(reloaded, file)
      @test Base.invokelatest(Models._model_set, reloaded).bindings == [:Circuit, :Race]
    finally
      pop!(PormG.config, folder, nothing)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A model the generated declaration cannot name is refused, not left out
# What it tests: an `@import_models` file with no `Models.@models` line whose only model is built in a
#   `for` loop raises `ModelDefinitionError` naming the module (`dms_loop_models`), the call
#   (`Models.Model(…)`), its line and the line to write (`Models.@models`); so does one whose second
#   model comes from a helper function (the line would list `Circuit` alone), a file whose module
#   `include`s another file, one that `Core.eval`s a quoted model assignment, and an
#   `@models_module` block with a loop. The Generator's commented
#   template (`create_models_jl`), which has no model call at all, still loads with the bare
#   `Models.@models` and an empty set. No SQL.
# Why it matters: a generated line that silently leaves a model out is one `makemigrations` reads as
#   "this table is no longer declared" and plans to drop.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a model the generated declaration cannot name is refused (#1602)" begin
  unwrap(e) = e isa LoadError ? unwrap(e.error) : e
  dir = mktempdir()
  folder = joinpath(dir, "dms_loop")
  mkpath(folder)
  PormG.config[folder] = PormG.Configuration.Settings(
    connections = DmsMockPostgres(), change_data = true, db_def_folder = folder)
  try
    file = joinpath(folder, "dms_loop_models.jl")
    write(file, """
    module dms_loop_models
    import PormG.Models
    for t in ("dms_loop_circuit",)
      global Circuit = Models.Model(t, circuitid = Models.IDField())
    end
    end
    """)
    host = Module(:DmsLoopHost)
    Core.eval(host, :(using PormG))
    err = unwrap(try Core.eval(host, :(PormG.@import_models $file dms_loop_models)); nothing catch e; e end)
    @test err isa PormG.ModelDefinitionError
    @test occursin("`dms_loop_models`", err.msg) && occursin("`Models.Model(…)`", err.msg)
    @test occursin("line 4 of dms_loop_models.jl", err.msg) && occursin("Write the line yourself", err.msg)
    @test occursin("`Models.@models Circuit Race`", err.msg)   # nothing named: an example list
    @test !isdefined(host, :dms_loop_models)                    # refused before the module ran

    write(file, """
    module dms_loop_models
    import PormG.Models
    Circuit = Models.Model("dms_loop_circuit", circuitid = Models.IDField())
    make_race() = Models.Model("dms_loop_race", raceid = Models.IDField())
    Race = make_race()
    end
    """)
    err = unwrap(try PormG.import_models(file; into = Module(:DmsHelperInto)); nothing catch e; e end)
    @test err isa PormG.ModelDefinitionError && occursin("`Models.@models Circuit …`", err.msg)

    # A body that includes another file: its models are invisible to the parser.
    write(joinpath(folder, "dms_more_models.jl"),
          "Race = Models.Model(\"dms_loop_race\", raceid = Models.IDField())\n")
    write(file, """
    module dms_loop_models
    import PormG.Models
    Circuit = Models.Model("dms_loop_circuit", circuitid = Models.IDField())
    include("dms_more_models.jl")
    end
    """)
    err = unwrap(try PormG.import_models(file; into = Module(:DmsIncludeInto)); nothing catch e; e end)
    @test err isa PormG.ModelDefinitionError && occursin("includes another file with `include(…)`", err.msg)

    block = :(PormG.@models_module DmsLoopBlock $folder begin
      for t in ("dms_block_circuit",)
        global Circuit = Models.Model(t, circuitid = Models.IDField())
      end
    end)
    block_host = Module(:DmsBlockHost)
    Core.eval(block_host, :(using PormG))
    err = unwrap(try Core.eval(block_host, block); nothing catch e; e end)
    @test err isa PormG.ModelDefinitionError && occursin("`DmsLoopBlock`", err.msg)

    # Quoted code is walked: a `Core.eval` of a quoted model assignment is a model the line cannot name.
    write(file, """
    module dms_loop_models
    import PormG.Models
    Circuit = Models.Model("dms_loop_circuit", circuitid = Models.IDField())
    Core.eval(@__MODULE__, :(Race = Models.Model("dms_loop_race", raceid = Models.IDField())))
    end
    """)
    err = unwrap(try PormG.import_models(file; into = Module(:DmsQuoteInto)); nothing catch e; e end)
    @test err isa PormG.ModelDefinitionError && occursin("line 4 of dms_loop_models.jl", err.msg)

    # The Generator's template: comments only, no model call — the bare line, an empty set.
    PormG.Generator.create_models_jl(folder, "template_models.jl")
    template = PormG.import_models(joinpath(folder, "template_models.jl"); into = Module(:DmsTemplateInto))
    @test isempty(Base.invokelatest(Models._model_set, template).bindings)
  finally
    pop!(PormG.config, folder, nothing)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Several `Models.@models` lines merge into one set
# What it tests: a file whose module writes `Models.@models Circuit` and then `Models.@models Race`,
#   loaded with plain `include` + `set_models` and with `import_models`, registers both (`MODEL_SET`
#   lists `[:Circuit, :Race]`, `get_all_models` returns both); the line run again in a live module adds
#   the newly listed model to the same set object, keeps its registration record, and the next
#   `set_models` registers it. The Revise reload (`Utils.reload_module_contents!`) instead REPLACES the
#   set: an edit that removes `Race` leaves `[:Circuit]`, a reload of the two-line file merges both
#   again, and a reload whose first line fails keeps the old set for the later line to merge into.
#   No SQL.
# Why it matters: the last line used to replace the set in silence, so the first line's models were not
#   registered and `makemigrations` planned their tables as dropped; and the left-out warning, which
#   unions the lines, did not fire.
# ─────────────────────────────────────────────────────────────────────────────
@testset "several Models.@models lines merge into one set (#1602)" begin
  dir = mktempdir()
  folder = joinpath(dir, "dms_two")
  mkpath(folder)
  file = joinpath(folder, "dms_two_lines.jl")
  two_lines = """
  module dms_two_lines
  import PormG.Models
  Circuit = Models.Model("dms_two_circuit", circuitid = Models.IDField())
  Models.@models Circuit
  Race = Models.Model("dms_two_race", raceid = Models.IDField())
  Models.@models Race
  end
  """
  write(file, two_lines)
  PormG.config[folder] = PormG.Configuration.Settings(
    connections = DmsMockPostgres(), change_data = true, db_def_folder = folder)
  try
    plain = Base.include(Module(:DmsTwoPlain), file)
    Base.invokelatest(Models.set_models, plain, folder)
    imported = PormG.import_models(file; into = Module(:DmsTwoImport))
    for mod in (plain, imported)
      @test Base.invokelatest(Models._model_set, mod).bindings == [:Circuit, :Race]
      @test Base.invokelatest(Models.get_all_models, mod; symbol = true) == [:Circuit, :Race]
      @test Models.connection_key(Base.invokelatest(getfield, mod, :Race)) == folder
    end

    # Run again in a live module: the same set object gains the model and keeps its record.
    set = Base.invokelatest(Models._model_set, plain)
    Core.eval(plain, :(Pit = Models.Model("dms_two_pit", pitid = Models.IDField())))
    Core.eval(plain, :(Models.@models Circuit Pit))
    @test Base.invokelatest(Models._model_set, plain) === set
    @test set.bindings == [:Circuit, :Race, :Pit] && set.key == folder
    Base.invokelatest(Models.set_models, plain, folder)                 # the merged model registers
    @test Models.connection_key(Base.invokelatest(getfield, plain, :Pit)) == folder

    # The reload replaces the set: a model the edit removed leaves it.
    write(file, """
    module dms_two_lines
    import PormG.Models
    Circuit = Models.Model("dms_two_circuit", circuitid = Models.IDField())
    Models.@models Circuit
    end
    """)
    loaded = imported
    @test PormG.Utils.reload_module_contents!(loaded, file)
    @test Base.invokelatest(Models._model_set, loaded).bindings == [:Circuit]
    write(file, two_lines)
    @test PormG.Utils.reload_module_contents!(loaded, file)
    @test Base.invokelatest(Models._model_set, loaded).bindings == [:Circuit, :Race]

    # A reload whose first line fails (it names a model whose definition has a typo) keeps the old set
    # and merges the later line into it, rather than the later line replacing it with `Race` alone.
    write(file, """
    module dms_two_lines
    import PormG.Models
    Circuit = Models.Model("dms_two_circuit", circuitid = Models.IDField())
    Lap = Models.Model("dms_two_lap", lapid = Models.IDFeild())
    Models.@models Circuit Lap
    Race = Models.Model("dms_two_race", raceid = Models.IDField())
    Models.@models Race
    end
    """)
    @test_logs (:warn, r"reloaded models file failed") match_mode = :any (
      @test PormG.Utils.reload_module_contents!(loaded, file))
    @test Base.invokelatest(Models._model_set, loaded).bindings == [:Circuit, :Race]
  finally
    pop!(PormG.config, folder, nothing)
  end
  @test isempty(Models._RELOADING)
end

# ─────────────────────────────────────────────────────────────────────────────
# A documented module gets the generated declaration like a plain one
# What it tests: a file whose module has a docstring (`"""F1 models."""` above `module models`, which
#   parses as a `Core.@doc` call around the `module`) and no `Models.@models` line: `@import_models`
#   registers its `Circuit`; `Migrations._load_current_models` keys `dms_doc_circuit`; the Revise reload
#   finds the module and puts an added `Race` in its set. No SQL.
# Why it matters: `_with_model_set` only looked at a bare `module` expression, so a documented module got
#   no declaration and was refused at registration, or, through the planner, read as declaring nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a documented module gets the generated declaration (#1602)" begin
  dir = mktempdir()
  folder = joinpath(dir, "dms_doc_module")
  mkpath(folder)
  file = joinpath(folder, "models.jl")
  write_models(ms...) = write(file, "\"\"\"F1 models.\"\"\"\nmodule models\nimport PormG.Models\n" *
                                    join(ms, "\n") * "\nend\n")
  circuit = "Circuit::Models.ModelType = Models.Model(\"dms_doc_circuit\", circuitid = Models.IDField())"
  race = "Race::Models.ModelType = Models.Model(\"dms_doc_race\", raceid = Models.IDField())"
  write_models(circuit)
  PormG.config[folder] = PormG.Configuration.Settings(
    connections = DmsMockPostgres(), change_data = true, db_def_folder = folder)
  try
    host = Module(:DmsDocModuleHost)
    Core.eval(host, :(using PormG))
    Core.eval(host, :(PormG.@import_models $file models))
    mod = Base.invokelatest(getfield, host, :models)
    @test Base.invokelatest(Models.get_all_models, mod; symbol = true) == [:Circuit]
    @test Models.connection_key(Base.invokelatest(getfield, mod, :Circuit)) == folder
    @test collect(keys(PormG.Migrations._load_current_models(file))) == [:dms_doc_circuit]

    write_models(circuit, race)
    @test PormG.Utils.reload_module_contents!(mod, file)
    @test Base.invokelatest(Models._model_set, mod).bindings == [:Circuit, :Race]
  finally
    pop!(PormG.config, folder, nothing)
  end
end
