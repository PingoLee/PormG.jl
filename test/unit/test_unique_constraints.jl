# ==============================================================================
# UNIT TESTS: Composite uniqueness via named UniqueConstraint (#19)
#
# `unique_together`, spelled as Django-2.2+/SQLAlchemy-style named `UniqueConstraint`
# objects on a model. Verifies, WITHOUT a live database:
#   1. UniqueConstraint construction, field normalization, and model-level validation.
#   2. The migration planner emits a CREATE UNIQUE INDEX at table creation (add-only,
#      mirroring the ManyToManyField auto-index), on BOTH PostgreSQL and SQLite mocks.
#   3. Model_to_str round-trips the declaration through the `constraints=` kwarg.
#   4. The Django importer maps `Meta.unique_together` to a UniqueConstraint.
#
# DB-free: mock backends subtype PormGPostgres/PormGSQLite; the planner is driven via
# get_migration_plan and the rendered SQL text is asserted with occursin — the same
# pattern as test_many_to_many.jl.
# ==============================================================================

using Test
using PormG
using PormG.Models
using PormG.Migrations

import PormG: PormGModel

# ── DB-free mock backends ─────────────────────────────────────────────────────
struct UCMockPostgres <: PormG.PormGPostgres end
struct UCMockSQLite   <: PormG.PormGSQLite end

PormG.config["uc_mock_pg"] = PormG.Configuration.Settings(
  connections = UCMockPostgres(), change_data = true, db_def_folder = "uc_mock_pg")
PormG.config["uc_mock_sl"] = PormG.Configuration.Settings(
  connections = UCMockSQLite(), change_data = true, db_def_folder = "uc_mock_sl")

# ── Models carrying composite-uniqueness declarations ─────────────────────────
module UniqueConstraintUnitModels
import PormG
import PormG.Models

# Two plain columns, auto-derived index name (<table>_<cols>_uniq).
Season_entry = Models.Model("season_entries",
  id = Models.IDField(),
  season = Models.IntegerField(),
  round  = Models.IntegerField(),
  constraints = [Models.UniqueConstraint(fields = ("season", "round"))],
)

# Explicit index name + a db_column-mapped field: the index must target the PHYSICAL
# column (race_ref), not the field name (race) — proves #50 resolution.
Grid_slot = Models.Model("grid_slots",
  id = Models.IDField(),
  race = Models.IntegerField(db_column = "race_ref"),
  position = Models.IntegerField(),
  constraints = [Models.UniqueConstraint(fields = ("race", "position"), name = "grid_slot_unique")],
)

PormG.Models.set_models(@__MODULE__, "uc_mock_pg")
end
const UM = UniqueConstraintUnitModels

# Helper: build a fresh-schema plan (every model :exist => false) for a backend mock.
function _uc_plan(conn)
  settings = PormG.Configuration.Settings(connections = conn, change_data = true)
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :season_entry => Dict{Symbol, Union{Bool, PormGModel}}(:model => UM.Season_entry, :exist => false),
    :grid_slot    => Dict{Symbol, Union{Bool, PormGModel}}(:model => UM.Grid_slot,    :exist => false),
  )
  return Migrations.get_migration_plan(PormGModel[], current_schema, conn, settings, interactive = false)
end

@testset "UniqueConstraint construction & validation" begin
  # Field normalization: Symbol/String/Tuple/Vector all accepted; name optional.
  @test Models.UniqueConstraint(fields = ("a", "b")).fields == ["a", "b"]
  @test Models.UniqueConstraint(fields = [:x, :y], name = "my_uniq").fields == ["x", "y"]
  @test Models.UniqueConstraint(fields = [:x, :y], name = "my_uniq").name == "my_uniq"
  @test Models.UniqueConstraint(fields = ("a", "b")).name === nothing
  # A single field name (not wrapped) is accepted and NOT iterated char-by-char.
  @test Models.UniqueConstraint(fields = "solo").fields == ["solo"]
  @test Models.UniqueConstraint(fields = :solo).fields == ["solo"]

  # Duplicate fields are rejected.
  @test_throws ArgumentError Models.UniqueConstraint(fields = ("a", "a"))

  # A blank name would render as an empty (invalid) index identifier — rejected.
  @test_throws ArgumentError Models.UniqueConstraint(fields = ("a", "b"), name = "")
  @test_throws ArgumentError Models.UniqueConstraint(fields = ("a", "b"), name = "   ")

  # Applied to a model → validated + stashed in cache (the M2M metadata mechanism).
  m = Models.Model("widgets",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("a", "b"))],
  )
  @test haskey(m.cache, "unique_constraints")
  @test length(m.cache["unique_constraints"]["constraints"]) == 1
  @test m.cache["unique_constraints"]["constraints"][1].fields == ["a", "b"]

  # A model with no constraints has no cache entry (no churn on the common path).
  plain = Models.Model("plain", id = Models.IDField(), a = Models.IntegerField())
  @test !haskey(plain.cache, "unique_constraints")

  # The idiomatic NO-positional-name form (table inferred from the binding via set_models) must
  # also accept constraints= — it uses a distinct Model(; ...) method.
  noname = Models.Model(
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("a", "b"))],
  )
  @test haskey(noname.cache, "unique_constraints")
  @test noname.cache["unique_constraints"]["constraints"][1].fields == ["a", "b"]

  # Referencing an unknown field is rejected, naming the offender.
  @test_throws ArgumentError Models.Model("bad_unknown",
    id = Models.IDField(),
    a = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("a", "nope"))],
  )

  # Referencing a ManyToManyField (no concrete column) is rejected.
  Tag = Models.Model("uc_tags", id = Models.IDField(), label = Models.CharField())
  @test_throws ArgumentError Models.Model("bad_m2m",
    id = Models.IDField(),
    tags = Models.ManyToManyField(Tag),
    constraints = [Models.UniqueConstraint(fields = ("tags",))],
  )

  # Two constraints sharing an explicit name collide into one index — rejected at construction.
  @test_throws ArgumentError Models.Model("bad_dupname",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    c = Models.IntegerField(),
    constraints = [
      Models.UniqueConstraint(fields = ("a", "b"), name = "dup"),
      Models.UniqueConstraint(fields = ("a", "c"), name = "dup"),
    ],
  )
end

@testset "Planner rejects colliding derived index names" begin
  # Two constraints over the same columns derive the same auto name; the planner must fail
  # loudly rather than silently overwrite one in the plan OrderedDict.
  module_collide = Models.Model("collide_tbl",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    constraints = [
      Models.UniqueConstraint(fields = ("a", "b")),
      Models.UniqueConstraint(fields = ("a", "b")),
    ],
  )
  settings = PormG.Configuration.Settings(connections = UCMockPostgres(), change_data = true)
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :collide => Dict{Symbol, Union{Bool, PormGModel}}(:model => module_collide, :exist => false),
  )
  @test_throws ArgumentError Migrations.get_migration_plan(
    PormGModel[], current_schema, UCMockPostgres(), settings, interactive = false)
end

@testset "Planner emits CREATE UNIQUE INDEX at table creation (PostgreSQL)" begin
  plan = _uc_plan(UCMockPostgres())

  # Auto-named composite index over the two declared columns.
  sql = join(values(plan[:season_entry]), "\n")
  @test occursin("CREATE TABLE", sql)
  @test occursin("CREATE UNIQUE INDEX", sql)
  @test occursin("season_entries_season_round_uniq", sql)  # <table>_<cols>_uniq
  @test occursin("\"season\"", sql)
  @test occursin("\"round\"", sql)

  # Explicit name honored verbatim; db_column-mapped field targets the PHYSICAL column.
  sql2 = join(values(plan[:grid_slot]), "\n")
  @test occursin("CREATE UNIQUE INDEX", sql2)
  @test occursin("grid_slot_unique", sql2)   # explicit name, not derived
  @test occursin("\"race_ref\"", sql2)        # physical column (#50), not "race"
  @test occursin("\"position\"", sql2)
end

@testset "Planner emits CREATE UNIQUE INDEX at table creation (SQLite)" begin
  # PG/SQLite alignment: create_unique_index renders identically on both backends.
  plan = _uc_plan(UCMockSQLite())
  sql = join(values(plan[:season_entry]), "\n")
  @test occursin("CREATE UNIQUE INDEX", sql)
  @test occursin("season_entries_season_round_uniq", sql)
  @test occursin("\"season\"", sql)
  @test occursin("\"round\"", sql)
end

@testset "Model_to_str round-trips constraints through the constraints= kwarg" begin
  rt_settings = PormG.Configuration.Settings(db_def_folder = "uc_rt", django_prefix = nothing)
  m = Models.Model("standings",
    id = Models.IDField(),
    season = Models.IntegerField(),
    round  = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("season", "round"), name = "standings_uniq")],
  )
  str = Models.Model_to_str(m, rt_settings)
  @test occursin("constraints = [Models.UniqueConstraint(fields = (\"season\", \"round\",)", str)
  @test occursin("name = \"standings_uniq\"", str)

  # Evaluate the generated declaration and confirm it reconstructs the constraint —
  # this guards the "sync Model_to_str when kwargs are added" round-trip rule.
  rt_mod = Module()
  Core.eval(rt_mod, :(import PormG.Models))
  reconstructed = Core.eval(rt_mod, Meta.parse(str))
  @test haskey(reconstructed.cache, "unique_constraints")
  rc = reconstructed.cache["unique_constraints"]["constraints"][1]
  @test rc.fields == ["season", "round"]
  @test rc.name == "standings_uniq"
end

@testset "Django importer maps Meta.unique_together" begin
  # FK fields gain an `_id` suffix at import, so Django `item`/`fabricante` become
  # PormG `item_id`/`fabricante_id`; the importer must resolve the declared names.
  django = """
  class Dim_item_fab(models.Model):
      item = models.ForeignKey(Dim_item, on_delete=models.CASCADE)
      fabricante = models.ForeignKey(Dim_fab, on_delete=models.CASCADE)
      validade = models.IntegerField(null=True, blank=True)

      class Meta:
          unique_together = ('item', 'fabricante')
  """

  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(
    db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "uc_import_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "uc_import_unit.jl"), String)
    @test occursin("constraints = [Models.UniqueConstraint(fields = (\"item_id\", \"fabricante_id\",))", generated)
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
end

@testset "Django importer is lenient with a malformed unique_together" begin
  # A duplicate-field unique_together makes the UniqueConstraint constructor throw; the importer
  # must warn and skip it, still generating the model (never aborting the whole import).
  django = """
  class Widget(models.Model):
      color = models.CharField(max_length=20)
      size = models.IntegerField()

      class Meta:
          unique_together = ('color', 'color')
  """
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(
    db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "uc_bad_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "uc_bad_unit.jl"), String)
    @test occursin("Widget = Models.Model(\"widget\"", generated)   # model still generated
    @test !occursin("UniqueConstraint", generated)                   # bad constraint skipped
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
end
