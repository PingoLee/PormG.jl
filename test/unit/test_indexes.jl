"""
UNIT TESTS: Composite (multi-column, non-unique) indexes via Models.Index (#347)

Django's `Meta.indexes`, spelled as model-level `Models.Index` objects passed through the
`indexes=` kwarg on `Model(...)`. Verifies, WITHOUT a live database:

  1. Index construction, field normalization, and model-level validation — including the
     two-field minimum, which is a correctness rule and not a style choice.
  2. The migration planner emits a plain CREATE INDEX at table creation (add-only, mirroring
     UniqueConstraint), byte-identical on the PostgreSQL and SQLite mocks.
  3. An Index and a UniqueConstraint cannot claim the same index name.
  4. Model_to_str round-trips the declaration through the `indexes=` kwarg, including the
     renamed-field and unrendered-field guards it shares with the constraints emitter.
  5. `_attach_composite_indexes!` (the introspection seam) skips rather than throws.
  6. The Django importer maps `Meta.indexes` / `Meta.index_together`, translating a
     single-column entry to `db_index` and reporting what it refuses.

The SQLite introspection READER (`_sqlite_composite_indexes`) is covered in
`test/unit/test_sqlite_index_filter.jl`, which already owns the hermetic temp-database
pattern; everything here is DB-free, using mock backends that subtype
PormGPostgres/PormGSQLite exactly as test_unique_constraints.jl does.
"""

using Test
using PormG
using PormG.Models
using PormG.Migrations

import PormG: PormGModel
import PormG.Migrations: _attach_composite_indexes!

# ── DB-free mock backends ─────────────────────────────────────────────────────
struct IXMockPostgres <: PormG.PormGPostgres end
struct IXMockSQLite   <: PormG.PormGSQLite end

PormG.config["ix_mock_pg"] = PormG.Configuration.Settings(
  connections = IXMockPostgres(), change_data = true, db_def_folder = "ix_mock_pg")
PormG.config["ix_mock_sl"] = PormG.Configuration.Settings(
  connections = IXMockSQLite(), change_data = true, db_def_folder = "ix_mock_sl")

# ── Models carrying composite-index declarations ──────────────────────────────
module IndexUnitModels
import PormG
import PormG.Models

# Two plain columns, auto-derived index name (<table>_<cols>_idx). Many rows share a
# (raceid, lap) pair — one per driver — so this is an index, not a uniqueness rule.
Lap_time = Models.Model("lap_times",
  id       = Models.IDField(),
  raceid   = Models.IntegerField(),
  lap      = Models.IntegerField(),
  position = Models.IntegerField(),
  indexes  = [Models.Index(fields = ("raceid", "lap"))],
)

# Explicit index name + a db_column-mapped field: the index must target the PHYSICAL column
# (race_ref), not the field name (race) — proves #50 resolution on this path too.
Grid_slot = Models.Model("grid_slots",
  id       = Models.IDField(),
  race     = Models.IntegerField(db_column = "race_ref"),
  position = Models.IntegerField(),
  indexes  = [Models.Index(fields = ("race", "position"), name = "grid_slot_lookup")],
)

PormG.Models.set_models(@__MODULE__, "ix_mock_pg")
end
const IXM = IndexUnitModels

# Helper: build a fresh-schema plan (every model :exist => false) for a backend mock.
function _ix_plan(conn)
  settings = PormG.Configuration.Settings(connections = conn, change_data = true)
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :lap_time  => Dict{Symbol, Union{Bool, PormGModel}}(:model => IXM.Lap_time,  :exist => false),
    :grid_slot => Dict{Symbol, Union{Bool, PormGModel}}(:model => IXM.Grid_slot, :exist => false),
  )
  return Migrations.get_migration_plan(PormGModel[], current_schema, conn, settings, interactive = false)
end

# Evaluate a generated model declaration in a throwaway module and hand back the model.
function _ix_reload(src::AbstractString)
  mod = Module()
  Core.eval(mod, :(import PormG.Models))
  return Core.eval(mod, Meta.parse(src))
end

# ─────────────────────────────────────────────────────────────────────────────
# Models.Index: construction, normalization and model-level validation
# The constructor rejects what is knowable from its arguments alone; everything that
# needs the model (unknown field, ManyToManyField, duplicate name) is rejected when the
# model is built. The two-field minimum is the load-bearing one — see the block below it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Index construction & validation" begin
  # Field normalization: Tuple and Vector, Symbol and String, all accepted; name optional.
  @test Models.Index(fields = ("a", "b")).fields == ["a", "b"]
  @test Models.Index(fields = [:x, :y], name = "my_idx").fields == ["x", "y"]
  @test Models.Index(fields = [:x, :y], name = "my_idx").name == "my_idx"
  @test Models.Index(fields = ("a", "b")).name === nothing

  # Declared ORDER is preserved verbatim — an index over (b, a) is not the index over (a, b),
  # and a reader that sorted or set-ified the columns would silently build the wrong one.
  @test Models.Index(fields = ("b", "a")).fields == ["b", "a"]

  # Duplicate fields are rejected.
  @test_throws PormG.ModelDefinitionError Models.Index(fields = ("a", "a"))

  # A blank name would render as an empty (invalid) index identifier — rejected.
  @test_throws PormG.ModelDefinitionError Models.Index(fields = ("a", "b"), name = "")
  @test_throws PormG.ModelDefinitionError Models.Index(fields = ("a", "b"), name = "   ")

  # A non-name member is rejected, and the message must name Index — the normalizer is SHARED
  # with UniqueConstraint, so a wrong label sends the reader to the wrong declaration.
  err = try; Models.Index(fields = ("a", 7)); catch e; e; end
  @test err isa PormG.ModelDefinitionError
  @test occursin("Index fields must be Symbol or String", sprint(showerror, err))

  # Applied to a model → validated + stashed in cache. The key is "composite_indexes", NOT
  # "indexes": `cache["index"]` is introspection's per-field column⇒index-name map (#325).
  m = Models.Model("widget_idx",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    indexes = [Models.Index(fields = ("a", "b"))],
  )
  @test haskey(m.cache, "composite_indexes")
  @test length(m.cache["composite_indexes"]["indexes"]) == 1
  @test m.cache["composite_indexes"]["indexes"][1].fields == ["a", "b"]

  # A model with no indexes has no cache entry (no churn on the common path).
  plain = Models.Model("plain_idx", id = Models.IDField(), a = Models.IntegerField())
  @test !haskey(plain.cache, "composite_indexes")

  # The idiomatic NO-positional-name form (table inferred from the binding via set_models) must
  # also accept indexes= — it uses a distinct Model(; ...) method, so the peel is duplicated.
  noname = Models.Model(
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    indexes = [Models.Index(fields = ("a", "b"))],
  )
  @test haskey(noname.cache, "composite_indexes")
  @test noname.cache["composite_indexes"]["indexes"][1].fields == ["a", "b"]

  # `constraints=` and `indexes=` are independent options and must not eat each other.
  both = Models.Model("both_idx",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("a", "b"), name = "both_uq")],
    indexes = [Models.Index(fields = ("b", "a"), name = "both_ix")],
  )
  @test both.cache["unique_constraints"]["constraints"][1].name == "both_uq"
  @test both.cache["composite_indexes"]["indexes"][1].name == "both_ix"

  # Referencing an unknown field is rejected, naming the offender.
  @test_throws PormG.ModelDefinitionError Models.Model("bad_unknown_idx",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    indexes = [Models.Index(fields = ("a", "nope"))],
  )

  # Referencing a ManyToManyField (no concrete column) is rejected.
  Tag = Models.Model("ix_tags", id = Models.IDField(), label = Models.CharField())
  @test_throws PormG.ModelDefinitionError Models.Model("bad_m2m_idx",
    id = Models.IDField(),
    a = Models.IntegerField(),
    tags = Models.ManyToManyField(Tag),
    indexes = [Models.Index(fields = ("a", "tags"))],
  )

  # Two indexes sharing an explicit name collide into one index — rejected when the model builds.
  @test_throws PormG.ModelDefinitionError Models.Model("bad_dupname_idx",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    c = Models.IntegerField(),
    indexes = [
      Models.Index(fields = ("a", "b"), name = "dup"),
      Models.Index(fields = ("a", "c"), name = "dup"),
    ],
  )
end

# ─────────────────────────────────────────────────────────────────────────────
# Models.Index: a single-column index is REFUSED, and why
# A one-column CREATE INDEX is byte-identical whether `db_index = true` or an Index
# emitted it, and introspection has no marker to tell them apart — so a one-field Index
# would read back as `db_index`, compare unequal to its own declaration forever, and make
# makemigrations propose DROPPING the index on every run. Rejecting it at declaration is
# what keeps the two primitives a partition rather than an overlap.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Index requires two or more fields" begin
  @test_throws PormG.ModelDefinitionError Models.Index(fields = ("solo",))
  @test_throws PormG.ModelDefinitionError Models.Index(fields = ["solo"])
  # A bare name (not wrapped) normalizes to a one-element vector and is refused the same way —
  # NOT iterated char-by-char, which would wrongly succeed with fields == ["s","o","l","o"].
  @test_throws PormG.ModelDefinitionError Models.Index(fields = "solo")
  @test_throws PormG.ModelDefinitionError Models.Index(fields = :solo)
  # No fields at all.
  @test_throws PormG.ModelDefinitionError Models.Index(fields = ())

  # The message must point at the replacement, or the reader has no way forward.
  err = try; Models.Index(fields = ("solo",)); catch e; e; end
  @test occursin("db_index", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# `indexes` is a model-level option, so a COLUMN of that name is unreachable
# Adding "indexes" to MODEL_OPTION_KWARGS means the kwarg is peeled before the field
# slurp. A consuming app that declared a column called `indexes` must now pin it with
# db_column — and it has to FAIL LOUDLY, naming the fix, rather than as a bare MethodError
# from iterating a field struct.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a field named `indexes` is refused with an actionable error" begin
  err = try
    Models.Model("collides_with_option", id = Models.IDField(), indexes = Models.CharField(max_length = 10))
  catch e; e; end
  @test err isa PormG.ModelDefinitionError
  @test occursin("db_column", sprint(showerror, err))

  # The same guard on the older sibling option, which had the same MethodError hole.
  err2 = try
    Models.Model("collides_with_option2", id = Models.IDField(), constraints = Models.CharField(max_length = 10))
  catch e; e; end
  @test err2 isa PormG.ModelDefinitionError
  @test occursin("db_column", sprint(showerror, err2))

  # And the documented escape hatch actually works: the column exists under another identity.
  ok = Models.Model("collides_ok",
    id = Models.IDField(),
    index_spec = Models.CharField(max_length = 10, db_column = "indexes"),
  )
  @test Models.field_db_column(ok.fields["index_spec"], "index_spec") == "indexes"
end

# ─────────────────────────────────────────────────────────────────────────────
# Planner: CREATE INDEX emitted at table creation (PostgreSQL)
# The composite index is materialized with its table, the same lifecycle as the
# ManyToManyField auto-index and UniqueConstraint. Auto-derived name is <table>_<cols>_idx;
# an explicit name is honored verbatim; a db_column-mapped field indexes the PHYSICAL column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Planner emits CREATE INDEX at table creation (PostgreSQL)" begin
  plan = _ix_plan(IXMockPostgres())

  sql = join(values(plan[:lap_time]), "\n")
  @test occursin("CREATE TABLE", sql)
  @test occursin("CREATE INDEX IF NOT EXISTS \"lap_times_raceid_lap_idx\"", sql)   # <table>_<cols>_idx
  @test occursin("(\"raceid\", \"lap\")", sql)                                     # declared ORDER
  # It is an INDEX, not a constraint: nothing on this table may render as UNIQUE, or the
  # declaration would start rejecting rows the model never said were unique.
  @test !occursin("CREATE UNIQUE INDEX", sql)

  sql2 = join(values(plan[:grid_slot]), "\n")
  @test occursin("CREATE INDEX IF NOT EXISTS \"grid_slot_lookup\"", sql2)          # explicit name
  @test occursin("(\"race_ref\", \"position\")", sql2)                             # physical column (#50)
  @test !occursin("\"race\",", sql2)                                               # never the field name
end

# ─────────────────────────────────────────────────────────────────────────────
# Planner: SQLite renders the identical statement
# create_index has one body per backend and they are the same string, so a composite index
# is portable by construction. Asserting it keeps the two from drifting apart silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Planner emits CREATE INDEX at table creation (SQLite)" begin
  plan = _ix_plan(IXMockSQLite())
  sql = join(values(plan[:lap_time]), "\n")
  @test occursin("CREATE INDEX IF NOT EXISTS \"lap_times_raceid_lap_idx\"", sql)
  @test occursin("(\"raceid\", \"lap\")", sql)
  @test !occursin("CREATE UNIQUE INDEX", sql)

  # The composite index step is byte-identical across backends.
  pg = _ix_plan(IXMockPostgres())
  @test plan[:lap_time]["Create index: lap_times_raceid_lap_idx"] ==
        pg[:lap_time]["Create index: lap_times_raceid_lap_idx"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Planner: index names must be unique across BOTH model-level primitives
# The plan's step labels differ ("Create index: x" vs "Create unique constraint: x"), so a
# name shared by an Index and a UniqueConstraint would NOT collide in the plan OrderedDict —
# it would reach the database as two CREATE statements for one identifier and fail there,
# mid-migration. `_add_new_table` shares one name registry between the two emitters.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Planner rejects an Index and a UniqueConstraint sharing a name" begin
  clash = Models.Model("clash_tbl",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    c = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("a", "b"), name = "shared_name")],
    indexes = [Models.Index(fields = ("a", "c"), name = "shared_name")],
  )
  settings = PormG.Configuration.Settings(connections = IXMockPostgres(), change_data = true)
  schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :clash => Dict{Symbol, Union{Bool, PormGModel}}(:model => clash, :exist => false),
  )
  @test_throws PormG.InvalidMigrationError Migrations.get_migration_plan(
    PormGModel[], schema, IXMockPostgres(), settings, interactive = false)

  # Two indexes over the same columns derive the same auto name — same failure, no explicit
  # name involved, which is the case a name-only check would miss.
  derived = Models.Model("clash_derived",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
  )
  derived.cache["composite_indexes"] = Dict{String, Any}("indexes" => [
    Models.Index(fields = ("a", "b")), Models.Index(fields = ("a", "b")),
  ])
  schema2 = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :clash_derived => Dict{Symbol, Union{Bool, PormGModel}}(:model => derived, :exist => false),
  )
  @test_throws PormG.InvalidMigrationError Migrations.get_migration_plan(
    PormGModel[], schema2, IXMockPostgres(), settings, interactive = false)

  # A UniqueConstraint and an Index over the SAME columns do NOT clash: the derived suffixes
  # differ (_uniq vs _idx). Proves the shared registry did not become over-eager.
  peaceful = Models.Model("peaceful_tbl",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("a", "b"))],
    indexes = [Models.Index(fields = ("a", "b"))],
  )
  schema3 = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :peaceful => Dict{Symbol, Union{Bool, PormGModel}}(:model => peaceful, :exist => false),
  )
  plan = Migrations.get_migration_plan(PormGModel[], schema3, IXMockPostgres(), settings, interactive = false)
  sql = join(values(plan[:peaceful]), "\n")
  @test occursin("peaceful_tbl_a_b_uniq", sql)
  @test occursin("peaceful_tbl_a_b_idx", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# Model_to_str: the declaration round-trips through the `indexes=` kwarg
# inspectdb and the Django importer both render through Model_to_str, so an index that
# does not survive the render is an index the generated models file silently loses.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Model_to_str round-trips indexes through the indexes= kwarg" begin
  m = Models.Model("standings_idx",
    id = Models.IDField(),
    season = Models.IntegerField(),
    round  = Models.IntegerField(),
    indexes = [Models.Index(fields = ("season", "round"), name = "standings_lookup")],
  )
  str = Models.Model_to_str(m)
  @test occursin("indexes = [Models.Index(fields = (\"season\", \"round\",)", str)
  @test occursin("name = \"standings_lookup\"", str)

  # Evaluate the generated declaration and confirm it reconstructs the index — this is the
  # guard for the "sync Model_to_str when kwargs are added" rule.
  reconstructed = _ix_reload(str)
  @test haskey(reconstructed.cache, "composite_indexes")
  ri = reconstructed.cache["composite_indexes"]["indexes"][1]
  @test ri.fields == ["season", "round"]
  @test ri.name == "standings_lookup"

  # Both model-level options in one declaration still reload as two independent cache entries.
  mixed = Models.Model("mixed_idx",
    id = Models.IDField(),
    a = Models.IntegerField(),
    b = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("a", "b"), name = "mixed_uq")],
    indexes = [Models.Index(fields = ("b", "a"))],
  )
  rt = _ix_reload(Models.Model_to_str(mixed))
  @test rt.cache["unique_constraints"]["constraints"][1].name == "mixed_uq"
  @test rt.cache["composite_indexes"]["indexes"][1].fields == ["b", "a"]   # order survives
end

# ─────────────────────────────────────────────────────────────────────────────
# Model_to_str: an index follows a renamed field, and is dropped when one cannot render
# The field loop re-spells a column that is not a legal Julia identifier (#317) and can drop
# a field outright (#70). An index still naming the original key would produce a file that
# raises "Index references unknown field" on reload — i.e. a models file that does not load.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Model_to_str translates a renamed field and drops an unrenderable index" begin
  # `end` is a Julia keyword, so the field is emitted under a sanitized identifier with the real
  # column pinned by db_column. The index must follow it to the NEW identifier.
  renamed = Models.Model("mts_ixrename", Dict{String, PormG.PormGField}(
    "id" => Models.IDField(), "end" => Models.IntegerField(), "year" => Models.IntegerField(),
  ))
  renamed.cache["composite_indexes"] = Dict{String, Any}("indexes" => [
    Models.Index(fields = ("end", "year"), name = "ix_end_year"),
  ])
  generated = Models.Model_to_str(renamed)
  @test !occursin("Models.Index(fields = (\"end\",", generated)   # the raw keyword never appears
  reloaded = _ix_reload(generated)
  @test length(reloaded.cache["composite_indexes"]["indexes"]) == 1
  # Whatever identifier the sanitizer chose, it must be one the reloaded model actually has.
  @test all(f -> haskey(reloaded.fields, f), reloaded.cache["composite_indexes"]["indexes"][1].fields)

  # A ManyToManyField whose key is not a legal identity cannot be re-spelled (it carries no
  # db_column, and its name feeds the derived join-table name), so the render loop drops it with a
  # marker. An index naming that field must be dropped too — emitting it would produce a file whose
  # reload raises "Index references unknown field". Two warns: one for the field, one for the index.
  dropped = Models.Model("mts_ixdrop", Dict{String, PormG.PormGField}(
    "id" => Models.IDField(), "year" => Models.IntegerField(), "round" => Models.IntegerField(),
    "_teams" => Models.ManyToManyField("Team"),
  ))
  dropped.cache["composite_indexes"] = Dict{String, Any}("indexes" => [
    Models.Index(fields = ("_teams", "year")),
    Models.Index(fields = ("year", "round"), name = "ix_year_round"),
  ])
  generated2 = @test_logs (:warn,) (:warn,) match_mode=:any Models.Model_to_str(dropped)
  @test occursin("# PormG: Index over (_teams, year) could not be rendered", generated2)
  @test !occursin("fields = (\"_teams\"", generated2)
  @test occursin("name = \"ix_year_round\"", generated2)          # the healthy one still ships
  reloaded2 = _ix_reload(generated2)
  @test length(reloaded2.cache["composite_indexes"]["indexes"]) == 1
  @test reloaded2.cache["composite_indexes"]["indexes"][1].fields == ["year", "round"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Introspection seam: `_attach_composite_indexes!` skips, it never throws
# It is deliberately NOT routed through `_apply_indexes!` — that is the declaration guard,
# and a throw here would abort the introspection of an entire table over one odd index. Two
# real shapes force a skip: a column the field reader did not produce, and a column name the
# field-name validator rejects (`a__b` is the lookup separator; `@` the operator marker).
# ─────────────────────────────────────────────────────────────────────────────
@testset "_attach_composite_indexes! degrades instead of aborting the table" begin
  base() = Models.Model("live_tbl", Dict{String, PormG.PormGField}(
    "id" => Models.IDField(), "a" => Models.IntegerField(), "b" => Models.IntegerField(),
  ))

  # Healthy: attached under the same cache key a declaration writes.
  ok = _attach_composite_indexes!(base(), ["ix_ab" => ["a", "b"]])
  @test ok.cache["composite_indexes"]["indexes"][1].fields == ["a", "b"]
  @test ok.cache["composite_indexes"]["indexes"][1].name == "ix_ab"

  # A column the model does not carry → skipped, no cache entry, no exception.
  missing_col = _attach_composite_indexes!(base(), ["ix_ax" => ["a", "gone"]])
  @test !haskey(missing_col.cache, "composite_indexes")

  # An unrepresentable column NAME → skipped, and the healthy sibling still lands.
  odd = Models.Model("live_odd", Dict{String, PormG.PormGField}(
    "id" => Models.IDField(), "a" => Models.IntegerField(), "b" => Models.IntegerField(),
    "a__b" => Models.IntegerField(),
  ))
  mixed = _attach_composite_indexes!(odd, ["ix_bad" => ["a__b", "a"], "ix_good" => ["a", "b"]])
  @test length(mixed.cache["composite_indexes"]["indexes"]) == 1
  @test mixed.cache["composite_indexes"]["indexes"][1].name == "ix_good"

  # Nothing to attach leaves the cache untouched — a table with no composite index must be
  # byte-identical to how it introspected before this existed.
  none = _attach_composite_indexes!(base(), Pair{String, Vector{String}}[])
  @test !haskey(none.cache, "composite_indexes")
end

# ─────────────────────────────────────────────────────────────────────────────
# Django importer: Meta.indexes and Meta.index_together
# The one Django option covers two PormG spellings — a multi-column entry becomes a
# Models.Index, a single-column one becomes `db_index = true` (the same DDL, and the only
# spelling that survives a round trip). FK fields gain an `_id` suffix at import, so the
# declared Django name has to be resolved exactly as it is for unique_together.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer maps Meta.indexes and Meta.index_together" begin
  django = """
  class Lap(models.Model):
      race = models.ForeignKey(Race, on_delete=models.CASCADE)
      lap = models.IntegerField()
      apelido = models.CharField(max_length=30)

      class Meta:
          indexes = [
              models.Index(fields=['race', 'lap'], name='lap_race_lap_idx'),
              models.Index(fields=['apelido']),
          ]
          index_together = (('lap', 'apelido'),)
  """
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(
    db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "ix_import_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "ix_import_unit.jl"), String)
    # Multi-column, FK resolved to the imported `race_id` column, explicit name carried through.
    @test occursin("Models.Index(fields = (\"race_id\", \"lap\",), name = \"lap_race_lap_idx\")", generated)
    # index_together, which has no names, derives one at migration time.
    @test occursin("Models.Index(fields = (\"lap\", \"apelido\",))", generated)
    # The single-column entry became db_index on the field, NOT a one-field Index.
    @test occursin("apelido = Models.CharField(max_length=30, db_index=true)", generated)
    @test !occursin("Models.Index(fields = (\"apelido\",))", generated)
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django importer: what it refuses, it REPORTS
# Every rejection lands as a `# PormG:` comment in the generated file, not only as a console
# warning that scrolls away. Each entry is judged on its own, so one refused index must not
# take its siblings with it — the assertion that the healthy one still ships is the guard.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reports the Meta.indexes it cannot express" begin
  django = """
  class Servidor(models.Model):
      cpf = models.CharField(max_length=11)
      ativo = models.BooleanField(default=True)
      apelido = models.CharField(max_length=30)

      class Meta:
          indexes = [
              models.Index(fields=['cpf', 'apelido'], name='ok_idx'),
              models.Index(fields=['-cpf', 'apelido'], name='desc_idx'),
              models.Index(Lower('apelido'), name='expr_idx'),
              GinIndex(fields=['cpf', 'apelido'], name='gin_idx'),
              models.Index(fields=['cpf', 'ativo'], condition=Q(ativo=True), name='partial_idx'),
          ]
  """
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(
    db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "ix_reject_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "ix_reject_unit.jl"), String)

    # The one PormG can express survives, and it is the ONLY Index emitted.
    @test occursin("Models.Index(fields = (\"cpf\", \"apelido\",), name = \"ok_idx\")", generated)
    @test count("Models.Index(", generated) == 1

    # Each refusal is named in the file, with the reason that makes it a refusal.
    @test occursin("DESCENDING column", generated)
    @test occursin("positional expression", generated)
    @test occursin("GinIndex has no PormG equivalent", generated)
    @test occursin("`condition=` changes what the index means", generated)
    # Four dropped indexes, four markers — a blanket "report something" would pass a count of 1.
    @test count("an index on 'Servidor' was dropped", generated) == 4
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django importer: four shapes that used to take the WHOLE import down, or land silently
# All four are legal Django that a real project writes. Each was found by an independent review of
# this change and is a regression guard, not a hypothetical: the first two aborted the import with
# no models file at all, the third produced a file that loads but can never be migrated, and the
# fourth generated a schema where one table quietly never gets its index.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer survives the legal-but-awkward Meta.indexes shapes" begin
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(
    db_def_folder = config_key, django_prefix = nothing)
  gen(src, file) = (import_models_from_django(src; db = config_key, file = file, force_replace = true);
                    read(joinpath(config_key, file), String))
  try
    # (1) An index on the PRIMARY KEY. `sIDField` is the one IMMUTABLE field struct AND it carries
    #     `db_index`, so the single-column translation's `hasproperty` guard passed and the
    #     assignment raised a raw `setfield!` ErrorException that nothing caught — one such line
    #     aborted the entire import. A primary key is already indexed, so this is redundant, not
    #     lost: it must be skipped in silence, and the model must still be generated.
    pk = gen("""
    class Volta(models.Model):
        lap = models.IntegerField()
        class Meta:
            indexes = [models.Index(fields=['id'])]
    """, "ix_pk.jl")
    @test occursin("Volta = Models.Model(\"volta\"", pk)
    @test !occursin("Models.Index(", pk)
    @test !occursin("was dropped", pk)      # redundant, not lost — reporting it would be noise

    pk2 = gen("""
    class Volta1b(models.Model):
        lap = models.IntegerField()
        class Meta:
            index_together = (('id',),)
    """, "ix_pk2.jl")
    @test occursin("Volta1b = Models.Model(\"volta1b\"", pk2)   # the index_together path too

    # (2) An `index_together` group whose members collapse to ONE imported column. Both spellings of
    #     a foreign key resolve to `race_id`, so the Index constructor rejects the duplicate — and
    #     the throw escaped, because this path lacked the per-entry try/catch its `Meta.indexes`
    #     sibling has. The model must survive, with the bad group reported.
    dup = gen("""
    class Volta2(models.Model):
        lap = models.IntegerField()
        race = models.ForeignKey(Race, on_delete=models.CASCADE)
        class Meta:
            index_together = (('race','race_id'),)
    """, "ix_dupfield.jl")
    @test occursin("Volta2 = Models.Model(\"volta2\"", dup)
    @test occursin("an index on 'Volta2' was dropped", dup)
    @test occursin("Index has duplicate fields", dup)
    @test !occursin("Models.Index(", dup)

    # (3) `Meta.indexes` and `Meta.index_together` declaring the SAME index — the exact intermediate
    #     state Django's own index_together → indexes deprecation migration produces. Two identical
    #     unnamed declarations derive ONE index name, and the planner then refuses the whole model
    #     with advice ("give each a distinct name") that cannot be followed. The generated file
    #     loaded and was unmigratable; the duplicate must collapse at import time instead.
    both = gen("""
    class Volta3(models.Model):
        lap = models.IntegerField()
        apelido = models.CharField(max_length=10)
        class Meta:
            indexes = [models.Index(fields=['lap','apelido'])]
            index_together = (('lap','apelido'),)
    """, "ix_dupdecl.jl")
    @test count("Models.Index(", both) == 1
    @test occursin("a duplicate index over (lap, apelido) on 'Volta3' was dropped", both)
    # …and it is genuinely migratable now, which is the property that was broken. Evaluating the
    # WHOLE generated file (not a regex-extracted slice) is deliberate: it also proves the file
    # parses and loads, markers and all. The generated file IS a module named after the output
    # file, and its bindings are newer than this frame's world age, so they are read through
    # `Core.eval` rather than `getfield`.
    sandbox = Module()
    Core.eval(sandbox, Meta.parse(both))
    v3 = Core.eval(sandbox, :(ix_dupdecl.Volta3))
    settings = PormG.Configuration.Settings(connections = IXMockPostgres(), change_data = true)
    schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :volta3 => Dict{Symbol, Union{Bool, PormGModel}}(:model => v3, :exist => false))
    plan = Migrations.get_migration_plan(PormGModel[], schema, IXMockPostgres(), settings, interactive = false)
    @test occursin("CREATE INDEX", join(values(plan[:volta3]), "\n"))

    # (4) An abstract base's NAMED index, inherited by two children. Django installs the base's whole
    #     Meta on every child declaring none of its own, so both tables asked for one index name —
    #     and because the DDL is `CREATE INDEX IF NOT EXISTS`, the second table's index was a SILENT
    #     no-op. Keep the index on both, surrender the duplicated name, and say so.
    inherited = gen("""
    class Base(models.Model):
        criado = models.IntegerField()
        ativo = models.BooleanField(default=True)
        class Meta:
            abstract = True
            indexes = [models.Index(fields=['criado','ativo'], name='base_criado_ativo')]

    class Piloto(Base):
        nome = models.CharField(max_length=10)

    class Equipe(Base):
        sede = models.CharField(max_length=10)
    """, "ix_inherited.jl")
    @test count("Models.Index(", inherited) == 2                       # both children keep an index
    @test count("name = \"base_criado_ativo\"", inherited) == 1        # …but only one keeps the name
    @test occursin("LOST its name 'base_criado_ativo'", inherited)

    # (5) The same duplicate-declaration collapse on the UNIQUE side. `unique_together` repeating a
    #     group is a plain copy-paste in a real models.py, and two identical constraints derive ONE
    #     index name — the same unmigratable-file outcome as (3), but losing a uniqueness GUARANTEE
    #     rather than a performance hint, so it matters more.
    dup_uq = gen("""
    class Volta5(models.Model):
        lap = models.IntegerField()
        apelido = models.CharField(max_length=10)
        class Meta:
            unique_together = (('lap','apelido'), ('lap','apelido'))
    """, "uq_dupdecl.jl")
    @test count("Models.UniqueConstraint(", dup_uq) == 1
    @test occursin("a duplicate constraint over (lap, apelido) on 'Volta5' was dropped", dup_uq)
    uq_sandbox = Module()
    Core.eval(uq_sandbox, Meta.parse(dup_uq))
    v5 = Core.eval(uq_sandbox, :(uq_dupdecl.Volta5))
    uq_settings = PormG.Configuration.Settings(connections = IXMockPostgres(), change_data = true)
    uq_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :volta5 => Dict{Symbol, Union{Bool, PormGModel}}(:model => v5, :exist => false))
    uq_plan = Migrations.get_migration_plan(PormGModel[], uq_schema, IXMockPostgres(), uq_settings, interactive = false)
    @test occursin("CREATE UNIQUE INDEX", join(values(uq_plan[:volta5]), "\n"))

    # (6) A UniqueConstraint name reused across models loses the name, not the guarantee — the same
    #     rule as (4), on the side where a silently-skipped CREATE UNIQUE INDEX is a data-integrity
    #     hole rather than a missing index.
    shared_uq = gen("""
    class BaseU(models.Model):
        a = models.IntegerField()
        b = models.IntegerField()
        class Meta:
            abstract = True
            constraints = [models.UniqueConstraint(fields=['a','b'], name='base_ab_uq')]

    class Um(BaseU):
        x = models.IntegerField()

    class Dois(BaseU):
        y = models.IntegerField()
    """, "uq_inherited.jl")
    @test count("Models.UniqueConstraint(", shared_uq) == 2            # both children keep the rule
    @test count("name = \"base_ab_uq\"", shared_uq) == 1               # …only one keeps the name
    @test occursin("LOST its name 'base_ab_uq'", shared_uq)
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
end
