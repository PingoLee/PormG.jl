"""
Unit coverage for `deepcopy` of a relation-bearing Model_Type (#157).

`deepcopy(model)` used to CLONE the model's containers while sharing `_module`, but the custom
top-level method never intercepted a model reached *nested* during recursion. So the moment a
relation field's resolved `.to` (another Model_Type) was deep-copied — e.g. via `deepcopy(model.fields)`
— it fell to the GENERIC `deepcopy_internal(::Model_Type)`, descended into `_module::Module`, and threw
`"deepcopy of Modules not supported"`. Every realistic model has an FK/O2O/M2M, so this was latent but real.

The fix (`Base.deepcopy_internal(::Model_Type, ::IdDict)` in src/Models.jl) treats a Model_Type as the
immutable, SHARED schema reference the rest of the codebase already assumes (`SQLObjectQuery` deepcopy
shares `model` verbatim): the recursion hook returns the same model. So `deepcopy(model) === model`, and
any container/field that holds a model shares it instead of cloning the schema graph into a Module it
can't traverse.

Deterministic and DB-free: a mock PostgreSQL connection + an inline F1-flavored model whose FK `.to` is a
resolved Model_Type carrying `_module` (the exact throwing input). `sForeignKey`, `ManyToManyField` and
`OneToOneField` all hold `.to::PormGModel`, so the FK case exercises the shared mechanism for all three.
"""

using Test
using PormG
using PormG.Models

# Dedicated config key so this file can't contaminate / be contaminated by other unit files in Main.
struct ModelDeepcopyMockPostgres <: PormG.PormGPostgres end

PormG.config["mdc_mock"] = PormG.Configuration.Settings(
  connections = ModelDeepcopyMockPostgres(),
  change_data = true,
  db_def_folder = "mdc_mock",
)

# Inline models in their own module so `set_models` binds `_module` and resolves the FK `.to` to the
# Mdc_driver Model_Type — reproducing the "a field's .to is a model carrying a Module" hazard.
module ModelDeepcopyModels
import PormG
import PormG.Models

Mdc_driver = Models.Model("mdc_driver",
  driverid = Models.IDField(),
  surname = Models.CharField(),
)

Mdc_results = Models.Model("mdc_results",
  id = Models.IDField(),
  driverid = Models.ForeignKey(Mdc_driver, pk_field = "driverid", on_delete = "RESTRICT"),
  points = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "mdc_mock")
end

const MDC = ModelDeepcopyModels

@testset "deepcopy of a relation-bearing Model_Type (#157)" begin
  results = MDC.Mdc_results
  driver  = MDC.Mdc_driver

  # Precondition: the setup actually reproduces the throwing shape — the FK `.to` is a resolved
  # Model_Type carrying a bound `_module` (otherwise the test would pass vacuously).
  fk = results.fields["driverid"]
  @test fk.to isa PormG.PormGModel
  @test fk.to === driver
  @test results._module !== nothing

  # ── The core regression: deep-copying the model no longer throws, and shares it ──
  # Pre-fix `deepcopy(model)` cloned containers; now a Model_Type is an immutable shared reference.
  model_copy = deepcopy(results)
  @test model_copy === results                 # shared, not cloned (the new contract)
  @test model_copy._module === results._module # never a fresh/traversed Module

  # ── The exact failing path: recursion that reaches a field's resolved `.to` model ──
  # `deepcopy(model.fields)` is what the old method did internally; pre-fix it threw
  # "deepcopy of Modules not supported" on the FK's `.to._module`. It must now succeed and SHARE the
  # nested target model rather than clone the schema graph. (Revert the share hook → this throws.)
  fields_copy = deepcopy(results.fields)
  # FIELDS are still deep-copied — the share hook dispatches on the concrete Model_Type only, so a field
  # (a sibling of PormGModel since #186) stays cloneable and copy-isolation, #43/#112, holds…
  @test fields_copy["driverid"] !== results.fields["driverid"]
  # …while the resolved target model reached through the cloned field is SHARED (Module never traversed).
  @test fields_copy["driverid"].to === driver

  # ── A model reached nested inside an arbitrary container is shared, not cloned ──
  bag = deepcopy(Dict("m" => driver, "fk" => fk))
  @test bag["m"] === driver                    # container recursion shares the model…
  @test bag["fk"].to === driver                # …and the model reached via a field's `.to`
end
