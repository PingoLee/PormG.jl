"""
`set_models` warns about a model bound by a plain global (#1664).

A models file that binds a model with a plain global (`Race = Models.Model(…)`) is accepted, but
every `M.Race` read is untyped: a dynamic call under the JIT, an error under `juliac --trim`. The
Generator writes a typed global (`Race::Models.ModelType = …`, #1650, #1672); a file written by hand,
or generated before, keeps the plain form, and nothing told the author. Registration now does, once,
and only for a binding whose type the compiler cannot know: the warning suggests the typed global,
and a typed global and a `const` binding both pass without a word.

Cadence: one `@warn` per registration that finds bindings not reported before, naming the first and
counting the rest, with `maxlog = 1` (the console shows it once per session). A process-wide seen set
keeps a second registration of the same module silent even under a fresh `TestLogger`, whose `maxlog`
count starts at zero; that is what the second-call testset below pins.

No SQL is involved anywhere in this file: registration renders nothing. Hermetic — a mock backend
and `Module` objects built in place, no database, no folder.

    julia --project=test/integration test/unit/test_plain_model_binding_warning.jl
"""

using Test
using Logging
using PormG
using PormG.Models

struct PmbMockPostgres <: PormG.PormGPostgres end

PormG.config["pmb_mock"] = PormG.Configuration.Settings(
  connections = PmbMockPostgres(),
  change_data = true,
  db_def_folder = "pmb_mock"
)

# Bindings created by `Core.eval` live in a newer world than this function, so `set_models` is
# reached through `invokelatest`, the seam `@import_models` uses (#211).
function _pmb_module(name::Symbol, decls::Expr)
  mod = Module(name)
  Core.eval(mod, :(import PormG; import PormG.Models))
  # `:toplevel`, not the `quote` block as is: a nested `module` must sit at top level (testset 5).
  Core.eval(mod, Expr(:toplevel, decls.args...))
  return mod
end

# The warnings one `set_models` logs, through a fresh `TestLogger` (its own `maxlog` counts).
function _pmb_warnings(mod::Module)
  logs, _ = Test.collect_test_logs(min_level = Logging.Warn) do
    Base.invokelatest(Models.set_models, mod, "pmb_mock")
  end
  return [string(r.message) for r in logs if r.level >= Logging.Warn]
end

_pmb_is_plain_warning(msg::AbstractString) = occursin("is a plain global", msg)

# ─────────────────────────────────────────────────────────────────────────────
# 1. A plain module warns once, naming the first binding and counting the rest.
#
# Two plain models, one warning: the record names `Driver` (first in `names` order) and says one more
# binding is plain. Before #1664 this registration logged nothing at Warn.
# ─────────────────────────────────────────────────────────────────────────────
const PMB_PLAIN = _pmb_module(:PmbPlainModels, quote
  Driver = Models.Model("pmb_driver", driverid = Models.IDField(), surname = Models.CharField())
  Result = Models.Model("pmb_result",
    resultid = Models.IDField(),
    driverid = Models.ForeignKey(Driver, pk_field = "driverid", related_name = "pmb_results"))
end)

@testset "a plain-bound models module logs exactly one warning naming the binding (#1664)" begin
  warnings = _pmb_warnings(PMB_PLAIN)
  @test length(warnings) == 1
  msg = only(warnings)
  @test _pmb_is_plain_warning(msg)
  @test occursin("`$(PMB_PLAIN).Driver` is a plain global", msg)
  @test occursin("bind it with `Driver::Models.ModelType = Models.Model(…)`", msg)   # #1672
  @test occursin("a `const` binding is accepted too", msg)
  @test occursin("1 more model binding registered here is plain too", msg)
  @test occursin("upgrade_guide(from = v\"0.9\")", msg)
  # The non-public call this check rests on (`Base.ispublic(Core, :get_binding_type)` is false in
  # Julia 1.13): a plain binding reads `Any`. Its typed-global counterpart is asserted below.
  @test Core.get_binding_type(PMB_PLAIN, :Driver) === Any
  # Registration still succeeded: the model is bound and wired.
  @test Models.connection_key(PMB_PLAIN.Driver) == "pmb_mock"
  @test haskey(PMB_PLAIN.Driver.related_objects, "pmb_results")
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. A second registration of the same module is silent.
#
# A reload or the self-heal registers a module again; the warning was already given for these
# bindings. `maxlog` alone cannot keep this silent: this block's `TestLogger` is fresh. The seen set
# does. Dropping it makes this testset fail.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a second set_models over the same plain module logs no warning (#1664)" begin
  @test isempty(_pmb_warnings(PMB_PLAIN))
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. A `const` module is silent.
#
# `const` is still accepted (#1672): the binding's type is its value's. Its binding type still reads
# `Any`, so only the `isconst` arm keeps it out; dropping that arm fails this one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a const-bound models module logs no warning (#1664)" begin
  mod = _pmb_module(:PmbConstModels, quote
    const Driver = Models.Model("pmbc_driver", driverid = Models.IDField(), surname = Models.CharField())
    const Result = Models.Model("pmbc_result",
      resultid = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "driverid", related_name = "pmbc_results"))
  end)
  @test isconst(mod, :Driver)
  @test Core.get_binding_type(mod, :Driver) === Any
  @test isempty(_pmb_warnings(mod))
  @test Models.connection_key(mod.Driver) == "pmb_mock"
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. A typed global is silent.
#
# `Driver::Models.ModelType = …` fixes the binding's type, not its value, so the read is typed; it
# is the form #1663 measured and #1672 adopted, the one the warning suggests. `isconst` is false
# here, so only the binding-type arm keeps it out; dropping that arm fails this one. The direct
# `Core.get_binding_type` assertion pins the non-public call for the Julia this suite runs on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a typed-global models module logs no warning (#1664)" begin
  mod = _pmb_module(:PmbTypedModels, quote
    Driver::Models.ModelType = Models.Model("pmbt_driver",
      driverid = Models.IDField(), surname = Models.CharField())
    Result::Models.ModelType = Models.Model("pmbt_result",
      resultid = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "driverid", related_name = "pmbt_results"))
  end)
  @test !isconst(mod, :Driver)
  @test Core.get_binding_type(mod, :Driver) === Models.ModelType
  @test isempty(_pmb_warnings(mod))
  @test Models.connection_key(mod.Driver) == "pmb_mock"
end

# ─────────────────────────────────────────────────────────────────────────────
# 5. An imported plain model is reported under the module that owns it.
#
# `isconst` and `Core.get_binding_type` follow an import to the owner's binding, which is the one to
# fix. The warning names the owner, and registering the owner afterwards is silent: the seen set is
# keyed by the owning module, so the same binding is never reported twice.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an imported plain model is reported once, under its owning module (#1664)" begin
  mod = _pmb_module(:PmbImporterModels, quote
    module PmbOwnerModels
      import PormG.Models
      Circuit = Models.Model("pmbo_circuit", circuitid = Models.IDField(), name = Models.CharField())
    end
    import .PmbOwnerModels: Circuit
  end)
  owner = mod.PmbOwnerModels
  warnings = _pmb_warnings(mod)
  @test length(warnings) == 1
  @test occursin("`$(owner).Circuit` is a plain global", only(warnings))
  @test !occursin("more model binding", only(warnings))
  @test isempty(_pmb_warnings(owner))
end

# ─────────────────────────────────────────────────────────────────────────────
# 6. The warning carries names, never a value.
#
# A table name, a field name and a field `default` are user data a log may not echo (the #971 rule
# for refusals, applied to this warning). Each carries a unique marker; none reaches the text, while
# the module and the binding do.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the plain-binding warning names the module and binding, never a value (#1664)" begin
  mod = _pmb_module(:PmbValueModels, quote
    Driver = Models.Model("pmbvtable1664",
      driverid = Models.IDField(),
      pmbvfield1664 = Models.CharField(default = "PMBVDEFAULT1664"))
  end)
  msg = only(_pmb_warnings(mod))
  @test occursin("`$(mod).Driver`", msg)
  for marker in ("pmbvtable1664", "pmbvfield1664", "PMBVDEFAULT1664")
    @test !occursin(marker, msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 7. The check is skipped while generating output.
#
# No unit test can run inside a precompile worker, so this one reads the source. The SQLite
# extension's precompile workload registers plain models on purpose (`ext/PormGSQLiteExt.jl`); without
# the `jl_generating_output` arm, `Pkg.precompile` prints this warning for
# `PormGSQLiteExt._PrecompileModels` (measured while working on #1664). A package's models are
# registered again at run time, where the author sees the warning.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the plain-binding check is skipped while precompiling (#1664)" begin
  src = replace(read(joinpath(pkgdir(PormG), "src", "Models.jl"), String), "\r\n" => "\n")
  m = match(r"\nfunction _warn_plain_model_bindings\(.*?\n  return nothing\nend\n"s, src)
  @test m !== nothing
  @test occursin("ccall(:jl_generating_output, Cint, ()) == 0 || return nothing", m.match)
end
