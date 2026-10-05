"""
UNIT TESTS: Composite (multi-column, non-unique) indexes via Models.Index (#347)

Django's `Meta.indexes`, spelled as model-level `Models.Index` objects passed through the
`indexes=` kwarg on `Model(...)`. Verifies, WITHOUT a live database:

  1. Index construction, field normalization, and model-level validation — including the
     two-field minimum, which is a correctness rule and not a style choice.
  2. The migration planner emits a plain CREATE INDEX at table creation, byte-identical on
     the PostgreSQL and SQLite mocks. (The diff on an EXISTING table — #161 — is
     test_composite_diff.jl.)
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
import PormG.Migrations: _attach_composite_indexes!, LiveComposite

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
# Models.Index: method, opclasses and descending columns (#29)
# Each rejection is a statement PostgreSQL would refuse at `migrate`, or a declaration the
# planner could not tell apart from another — so it fails at the constructor, where the
# developer wrote it. The two-field rule relaxes for exactly the indexes that cannot be read
# back as `db_index`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Index method, opclasses and descending columns (#29)" begin
  ix = Models.Index(fields = ("raceid", "-points"), name = "result_race_points_idx")
  @test ix.fields == ["raceid", "points"]          # the `-` is a direction, not part of the name
  @test ix.descending == [false, true]
  @test ix.method == "btree"
  @test ix.opclasses == [nothing, nothing]

  # A Symbol method and an upper-case one both normalize; the default stays b-tree.
  @test Models.Index(fields = ("data",), method = :brin).method == "brin"
  @test Models.Index(fields = ("data",), method = "GIN").method == "gin"
  @test Models.Index(fields = ("a", "b")).method == "btree"

  # opclasses: one per field, `nothing` keeps a column's default class, and a lone string is one entry.
  g = Models.Index(fields = ("surname",), opclasses = "varchar_pattern_ops", name = "s_pat")
  @test g.opclasses == ["varchar_pattern_ops"]
  m = Models.Index(fields = ("a", "b"), opclasses = (nothing, "int4_ops"), name = "ab_ops")
  @test m.opclasses == [nothing, "int4_ops"]

  # The two-field rule relaxes only for an index `db_index` cannot read back: a direction, a method
  # or an operator class. A plain one-field index is still refused (see the testset below).
  @test Models.Index(fields = ("-points",)).fields == ["points"]
  @test Models.Index(fields = ("tags",), method = "gin").fields == ["tags"]
  @test Models.Index(fields = ("surname",), opclasses = ("text_pattern_ops",), name = "x").fields == ["surname"]

  err(f) = try; f(); nothing; catch e; e; end
  msg(f) = (e = err(f); e isa PormG.ModelDefinitionError ? sprint(showerror, e) : "NOT A ModelDefinitionError: $(e)")

  # "lap" and "-lap" are the same column twice.
  @test occursin("duplicate", msg(() -> Models.Index(fields = ("lap", "-lap"))))
  # A bare `-` and a double one are not field names.
  @test occursin("not a field name", msg(() -> Models.Index(fields = ("-", "a"))))
  @test occursin("not a field name", msg(() -> Models.Index(fields = ("--a", "b"))))
  # An access method PormG does not know — an extension's, or a typo.
  @test occursin("bloom", msg(() -> Models.Index(fields = ("a", "b"), method = "bloom")))
  # PostgreSQL orders only b-tree indexes.
  @test occursin("does not support a descending column", msg(() -> Models.Index(fields = ("-a",), method = "gin")))
  # hash and spgist index one column.
  @test occursin("single column", msg(() -> Models.Index(fields = ("a", "b"), method = "hash")))
  @test occursin("single column", msg(() -> Models.Index(fields = ("a", "b"), method = :spgist)))
  # opclasses: the wrong length, an uppercase or schema-qualified class (rendered bare, so this is
  # also the injection guard), something that is not a name at all — and one without a name=.
  @test occursin("one per field", msg(() -> Models.Index(fields = ("a", "b"), opclasses = ("int4_ops",), name = "n")))
  @test occursin("not an operator class name", msg(() -> Models.Index(fields = ("a",), opclasses = ("Int4_Ops",), name = "n")))
  @test occursin("not an operator class name", msg(() -> Models.Index(fields = ("a",), opclasses = ("public.x",), name = "n")))
  @test occursin("not an operator class name", msg(() -> Models.Index(fields = ("a",), opclasses = ("x; DROP TABLE t",), name = "n")))
  @test occursin("not an operator class name", msg(() -> Models.Index(fields = ("a",), opclasses = (1,), name = "n")))
  @test occursin("explicit name=", msg(() -> Models.Index(fields = ("a",), opclasses = ("int4_ops",))))
  # A plain one-field index still points at db_index.
  @test occursin("db_index", msg(() -> Models.Index(fields = ("a",))))
  @test occursin("db_index", msg(() -> Models.Index(fields = ("a",), opclasses = (nothing,))))
end

# ─────────────────────────────────────────────────────────────────────────────
# Planner: an advanced index renders its method, directions and classes, and its marker (#29)
# The marker is the ownership record: only an advanced index carrying it is ever planned away.
# On PostgreSQL it is the index's COMMENT, in the same step as the CREATE; on SQLite an SQL
# comment closing the column list, where `sqlite_master` keeps it. A plain index renders
# exactly as before, marker-free — the golden corpus pins that byte for byte.
# ─────────────────────────────────────────────────────────────────────────────
module IndexAdvancedModels
import PormG
import PormG.Models

Result_ix = Models.Model("result_ix",
  id       = Models.IDField(),
  raceid   = Models.IntegerField(),
  points   = Models.FloatField(),
  indexes  = [Models.Index(fields = ("raceid", "-points"))],
)
Driver_ix = Models.Model("driver_ix",
  id       = Models.IDField(),
  surname  = Models.CharField(max_length = 60),
  dob      = Models.DateField(),
  indexes  = [
    Models.Index(fields = ("surname",), opclasses = ("varchar_pattern_ops",), name = "driver_ix_surname_pattern"),
    Models.Index(fields = ("dob",), method = "brin"),
  ],
)
PormG.Models.set_models(@__MODULE__, "ix_mock_pg")
end
const IXA = IndexAdvancedModels

function _ix_plan_one(conn, key::Symbol, model)
  settings = PormG.Configuration.Settings(connections = conn, change_data = true)
  schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    key => Dict{Symbol, Union{Bool, PormGModel}}(:model => model, :exist => false))
  return Migrations.get_migration_plan(PormGModel[], schema, conn, settings, interactive = false)
end

@testset "Planner renders an advanced index with its marker (#29)" begin
  pg = _ix_plan_one(IXMockPostgres(), :result_ix, IXA.Result_ix)
  @test pg[:result_ix]["Create index: result_ix_raceid_points_desc_idx"] ==
        "CREATE INDEX \"result_ix_raceid_points_desc_idx\" ON \"result_ix\" (\"raceid\", \"points\" DESC);\n" *
        "COMMENT ON INDEX \"result_ix_raceid_points_desc_idx\" IS 'pormg:index';"

  pgd = _ix_plan_one(IXMockPostgres(), :driver_ix, IXA.Driver_ix)
  @test pgd[:driver_ix]["Create index: driver_ix_surname_pattern"] ==
        "CREATE INDEX \"driver_ix_surname_pattern\" ON \"driver_ix\" (\"surname\" varchar_pattern_ops);\n" *
        "COMMENT ON INDEX \"driver_ix_surname_pattern\" IS 'pormg:index';"
  @test pgd[:driver_ix]["Create index: driver_ix_dob_brin_idx"] ==
        "CREATE INDEX \"driver_ix_dob_brin_idx\" ON \"driver_ix\" USING brin (\"dob\");\n" *
        "COMMENT ON INDEX \"driver_ix_dob_brin_idx\" IS 'pormg:index';"

  # SQLite: the direction is core; the marker closes the column list.
  sl = _ix_plan_one(IXMockSQLite(), :result_ix, IXA.Result_ix)
  @test sl[:result_ix]["Create index: result_ix_raceid_points_desc_idx"] ==
        "CREATE INDEX \"result_ix_raceid_points_desc_idx\" ON \"result_ix\" (\"raceid\", \"points\" DESC /* pormg:index */);"

  # A plain index is unchanged on both engines — no marker, no USING.
  plain = _ix_plan(IXMockPostgres())
  @test plain[:lap_time]["Create index: lap_times_raceid_lap_idx"] ==
        "CREATE INDEX \"lap_times_raceid_lap_idx\" ON \"lap_times\" (\"raceid\", \"lap\");"

  # The opclass comes before DESC — PostgreSQL's per-column order.
  @test PormG.Dialect.create_index(IXMockPostgres(), "\"i\"", "\"t\"", ["\"a\""]; if_not_exists = false,
          descending = [true], opclasses = ["text_pattern_ops"]) ==
        "CREATE INDEX \"i\" ON \"t\" (\"a\" text_pattern_ops DESC);"
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a method or an operator class is refused at BOTH sites (#29, the #648 pattern)
# The planner refuses the declaration before anything is diffed, because a declaration that
# matches nothing live renders nothing — the renderer alone would let the model run on SQLite
# as if it had the index it declared. The renderer refuses too, for a hand-built caller.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite refuses a method or an opclass at the planner and the renderer (#29)" begin
  e = try; _ix_plan_one(IXMockSQLite(), :driver_ix, IXA.Driver_ix); nothing; catch x; x; end
  @test e isa PormG.BackendCapabilityError
  @test occursin("PostgreSQL-only", sprint(showerror, e))
  @test occursin("driver_ix", sprint(showerror, e))

  e_m = try; PormG.Dialect.create_index(IXMockSQLite(), "\"i\"", "\"t\"", ["\"a\""]; method = "gin"); nothing; catch x; x; end
  @test e_m isa PormG.BackendCapabilityError && occursin("access method \"gin\"", sprint(showerror, e_m))
  e_o = try; PormG.Dialect.create_index(IXMockSQLite(), "\"i\"", "\"t\"", ["\"a\""]; opclasses = ["text_pattern_ops"]); nothing; catch x; x; end
  @test e_o isa PormG.BackendCapabilityError && occursin("no operator classes", sprint(showerror, e_o))
  # A descending column is NOT refused — SQLite orders an index the same way.
  @test occursin("DESC", PormG.Dialect.create_index(IXMockSQLite(), "\"i\"", "\"t\"", ["\"a\""]; descending = [true]))
  # The renderer's own guard against a hand-built caller: an opclass and a method are rendered bare.
  @test_throws PormG.InvalidValueError PormG.Dialect.create_index(IXMockPostgres(), "\"i\"", "\"t\"", ["\"a\""];
                                                                opclasses = ["x); DROP TABLE t; --"])
  @test_throws PormG.InvalidValueError PormG.Dialect.create_index(IXMockPostgres(), "\"i\"", "\"t\"", ["\"a\""];
                                                                method = "btree; DROP TABLE t")
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
  # No IF NOT EXISTS (#161): a name some other object holds must fail loudly, not no-op.
  @test occursin("CREATE INDEX \"lap_times_raceid_lap_idx\"", sql)                 # <table>_<cols>_idx
  @test occursin("(\"raceid\", \"lap\")", sql)                                     # declared ORDER
  # It is an INDEX, not a constraint: nothing on this table may render as UNIQUE, or the
  # declaration would start rejecting rows the model never said were unique.
  @test !occursin("CREATE UNIQUE INDEX", sql)

  sql2 = join(values(plan[:grid_slot]), "\n")
  @test occursin("CREATE INDEX \"grid_slot_lookup\"", sql2)                        # explicit name
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
  @test occursin("CREATE INDEX \"lap_times_raceid_lap_idx\"", sql)
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
# mid-migration. `_check_composite_names` keeps one registry for the whole plan (#161).
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
# Models.Index: expressions and condition (#29 part 2)
# Django's rules, on SQL text: fields OR expressions, a name for either text, no opclasses beside
# expressions (the text carries its own), hash/spgist over one member however it is spelled. The
# text is checked for exactly what would change the CREATE INDEX it lands in — a comment, an
# unterminated quote, a top-level `;` or `,` — so each expression is one member. A partial index is
# a different index from `db_index`, so it may have one field.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Index expressions and condition (#29 part 2)" begin
  f = Models.Index(expressions = ("lower(surname)",), name = "driver_surname_lower_idx")
  @test f.expressions == ["lower(surname)"] && isempty(f.fields) && f.condition === nothing
  @test f.descending == Bool[] && f.opclasses == Union{String, Nothing}[]
  @test Models._index_is_advanced(f) && Models._index_holds_text(f)
  # A lone string is one expression; surrounding whitespace is trimmed.
  @test Models.Index(expressions = "  lower(surname) ", name = "x").expressions == ["lower(surname)"]
  # A comma INSIDE parentheses or a literal is one member.
  @test Models.Index(expressions = ("coalesce(code, 'n,a')",), name = "x").expressions == ["coalesce(code, 'n,a')"]
  p = Models.Index(fields = ("raceid", "-points"), condition = "position IS NOT NULL", name = "result_finishers_idx")
  @test (p.fields, p.descending, p.condition) == (["raceid", "points"], [false, true], "position IS NOT NULL")
  # One field is enough for a partial index: `db_index` cannot read it back.
  @test Models.Index(fields = ("raceid",), condition = "grid > 0", name = "x").fields == ["raceid"]
  # Both texts at once, under another method.
  g = Models.Index(expressions = ("to_tsvector('simple', surname)",), condition = "dob IS NOT NULL",
                   method = "gin", name = "driver_search_idx")
  @test (g.method, g.condition) == ("gin", "dob IS NOT NULL")

  # The helpers carry the text: shape (the importer's duplicate collapse) and rename keep it.
  @test Models._index_shape(f) != Models._index_shape(Models.Index(expressions = ("upper(surname)",), name = "y"))
  @test Models._index_shape(p) != Models._index_shape(Models.Index(fields = ("raceid", "-points"), condition = "grid > 0", name = "y"))
  r = Models._index_renamed(g, "renamed")
  @test (r.name, r.expressions, r.condition, r.method) == ("renamed", g.expressions, g.condition, "gin")
  @test Models._index_renamed(p, "q").condition == "position IS NOT NULL"
  @test Models._index_label(f) == "expressions (lower(surname))" && Models._index_label(p) == "(raceid, points)"

  err(f) = try; f(); nothing; catch e; e; end
  msg(f) = (e = err(f); e isa PormG.ModelDefinitionError ? sprint(showerror, e) : "NOT A ModelDefinitionError: $(e)")
  @test occursin("not both", msg(() -> Models.Index(fields = ("a",), expressions = ("abs(b)",), name = "x")))
  # Expressions naming only columns are a column index — `inspectdb` would read it back as `fields`,
  # or at one column as nothing at all. Mixed with a real expression, or with a condition, they stay.
  @test occursin("name only columns", msg(() -> Models.Index(expressions = ("grid",), name = "x")))
  @test occursin("name only columns", msg(() -> Models.Index(expressions = ("raceid", "\"grid\""), name = "x")))
  @test Models.Index(expressions = ("raceid", "abs(grid)"), name = "x").expressions == ["raceid", "abs(grid)"]
  @test Models.Index(expressions = ("grid",), condition = "grid > 0", name = "x").condition == "grid > 0"
  @test Models.Index(expressions = ("grid DESC",), name = "x").expressions == ["grid DESC"]
  @test occursin("requires fields or expressions", msg(() -> Models.Index(name = "x")))
  @test occursin("explicit name=", msg(() -> Models.Index(expressions = ("lower(a)",))))
  @test occursin("explicit name=", msg(() -> Models.Index(fields = ("a", "b"), condition = "a > 0")))
  @test occursin("inside the expression text", msg(() -> Models.Index(expressions = ("lower(a)",), opclasses = ("text_ops",), name = "x")))
  @test occursin("single member", msg(() -> Models.Index(expressions = ("lower(a)", "b"), method = "hash", name = "x")))
  @test occursin("at least one expression", msg(() -> Models.Index(expressions = String[], name = "x")))
  @test occursin("must be SQL strings", msg(() -> Models.Index(expressions = (:a,), name = "x")))
  @test occursin("must be an SQL string", msg(() -> Models.Index(fields = ("a", "b"), condition = :a, name = "x")))
  @test occursin("must not be blank", msg(() -> Models.Index(fields = ("a", "b"), condition = "  ", name = "x")))
  @test occursin("must not be blank", msg(() -> Models.Index(expressions = ("",), name = "x")))
  # What would change the statement the text is rendered into.
  for bad in ("a, b", "lower(a); DROP TABLE driver", "lower(a) -- tail", "lower(a) /* c */", "lower('a)")
    @test occursin("not well-formed SQL", msg(() -> Models.Index(expressions = (bad,), name = "x")))
  end
  @test occursin("not well-formed SQL", msg(() -> Models.Index(fields = ("a", "b"), condition = "a > 0; DROP TABLE t", name = "x")))
  # #934: quoting whose end only one engine can find, through the same validator.
  @test occursin("not well-formed SQL", msg(() -> Models.Index(fields = ("a", "b"), condition = "a <> \$\$;\$\$", name = "x")))
  @test occursin("not well-formed SQL", msg(() -> Models.Index(expressions = ("lower(`a`)",), name = "x")))
  # A model that declares two text indexes under one name is refused when it is built.
  @test_throws PormG.ModelDefinitionError Models.Model("dup_text_ix", id = Models.IDField(), a = Models.IntegerField(),
    indexes = [Models.Index(expressions = ("abs(a)",), name = "same"), Models.Index(fields = ("a",), condition = "a > 0", name = "same")])
end

# ─────────────────────────────────────────────────────────────────────────────
# The hashed marker of an index's SQL text (#29 part 2)
# The marker is persisted in the database and compared in another process, maybe by another
# PormG version, so its value is pinned, not merely checked for shape. Canonical text ignores what
# cannot change the index — outer whitespace and a wrapping pair of parentheses — and the encoding is
# length-prefixed, so a comma inside one expression never reads as two, and a condition never reads
# as a last expression.
# Mutation gate: drop the length prefix (join with ",") and the two collision pairs hash alike.
# ─────────────────────────────────────────────────────────────────────────────
@testset "The hashed marker of an index's SQL text (#29 part 2)" begin
  @test PormG.index_text_marker(["lower(surname)"], nothing) == "pormg:index:" * PormG.index_text_hash(["lower(surname)"], nothing)
  @test PormG.index_text_hash(["lower(surname)"], nothing) == "599190475f20d2a4"
  @test occursin(PormG.INDEX_MARKER_RE, PormG.index_text_marker(["lower(surname)"], "dob IS NOT NULL"))
  @test PormG.canonical_index_text(["lower(surname)"], "position IS NOT NULL") == "e14:lower(surname)w20:position IS NOT NULL"
  # What does not change the index does not change the hash.
  @test PormG.index_text_hash([" lower(surname) "], "(position IS NOT NULL)") ==
        PormG.index_text_hash(["lower(surname)"], "position IS NOT NULL")
  # What does, does — including the split between members, and between members and the condition.
  @test PormG.index_text_hash(["a, b"], nothing) != PormG.index_text_hash(["a", "b"], nothing)
  @test PormG.index_text_hash(["a"], "b") != PormG.index_text_hash(["a", "b"], nothing)
  @test PormG.index_text_hash(["a"], nothing) != PormG.index_text_hash(String[], "a")
  @test PormG.index_text_hash(["lower(surname)"], nothing) != PormG.index_text_hash(["LOWER(surname)"], nothing)
end

# ─────────────────────────────────────────────────────────────────────────────
# Planner and renderer: expressions and a WHERE, under the hashed marker (#29 part 2)
# The text is rendered verbatim — it is DDL, which takes no bind parameters — after the renderer
# re-checks it, as its own guard against a hand-built caller.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Renderer: expressions and a WHERE, under the hashed marker (#29 part 2)" begin
  pg, sl = IXMockPostgres(), IXMockSQLite()
  m = PormG.index_text_marker(["lower(surname)"], "dob IS NOT NULL")
  @test PormG.Dialect.create_index(pg, "\"i\"", "\"driver\"", String[]; if_not_exists = false,
          expressions = ["lower(surname)"], condition = "dob IS NOT NULL", marker = m) ==
        "CREATE INDEX \"i\" ON \"driver\" (lower(surname)) WHERE dob IS NOT NULL;\nCOMMENT ON INDEX \"i\" IS '$(m)';"
  @test PormG.Dialect.create_index(sl, "\"i\"", "\"driver\"", String[]; if_not_exists = false,
          expressions = ["lower(surname)"], condition = "dob IS NOT NULL", marker = m) ==
        "CREATE INDEX \"i\" ON \"driver\" (lower(surname) /* $(m) */) WHERE dob IS NOT NULL;"
  # Columns with a condition: the members render as before, the WHERE after the list.
  @test PormG.Dialect.create_index(pg, "\"i\"", "\"result\"", ["\"raceid\"", "\"points\""]; if_not_exists = false,
          descending = [false, true], condition = "position IS NOT NULL") ==
        "CREATE INDEX \"i\" ON \"result\" (\"raceid\", \"points\" DESC) WHERE position IS NOT NULL;"
  # The renderer's own guard.
  guard(f) = (e = try; f(); nothing; catch x; x; end; e isa PormG.InvalidValueError ? sprint(showerror, e) : "NOT AN InvalidValueError: $(e)")
  @test occursin("columns or expressions, not both",
                 guard(() -> PormG.Dialect.create_index(pg, "\"i\"", "\"t\"", ["\"a\""]; expressions = ["b"])))
  @test occursin("index expression \"a; DROP TABLE t\" is not well-formed SQL",
                 guard(() -> PormG.Dialect.create_index(pg, "\"i\"", "\"t\"", String[]; expressions = ["a; DROP TABLE t"])))
  @test occursin("index condition \"a > 0 -- x\" is not well-formed SQL",
                 guard(() -> PormG.Dialect.create_index(sl, "\"i\"", "\"t\"", ["\"a\""]; condition = "a > 0 -- x")))
  # SQLite still refuses a method beside text.
  @test_throws PormG.BackendCapabilityError PormG.Dialect.create_index(sl, "\"i\"", "\"t\"", String[];
          expressions = ["lower(a)"], method = "gin")
end

@testset "Model_to_str round-trips expression and partial indexes (#29 part 2)" begin
  m = Models.Model("driver_rt",
    id      = Models.IDField(),
    surname = Models.CharField(max_length = 60),
    code    = Models.CharField(max_length = 3, null = true),
    indexes = [
      Models.Index(expressions = ("lower(surname)", "surname COLLATE \"C\""), name = "rt_lower"),
      Models.Index(fields = ("surname", "-code"), condition = "code <> '\$\$'", name = "rt_partial"),
      Models.Index(expressions = ("to_tsvector('simple', surname)",), method = "gin", condition = "code IS NOT NULL", name = "rt_gin"),
    ],
  )
  str = Models.Model_to_str(m)
  @test occursin("Models.Index(expressions = (\"lower(surname)\", \"surname COLLATE \\\"C\\\"\",), name = \"rt_lower\")", str)
  @test occursin("Models.Index(fields = (\"surname\", \"-code\",), name = \"rt_partial\", condition = \"code <> '\\\$\\\$'\")", str)
  @test occursin("name = \"rt_gin\", method = \"gin\", condition = \"code IS NOT NULL\")", str)
  r = _ix_reload(str).cache["composite_indexes"]["indexes"]
  @test [Models._index_shape(ix) for ix in r] == [Models._index_shape(ix) for ix in m.cache["composite_indexes"]["indexes"]]
  @test [ix.name for ix in r] == ["rt_lower", "rt_partial", "rt_gin"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Model_to_str: the declaration round-trips through the `indexes=` kwarg
# inspectdb and the Django importer both render through Model_to_str, so an index that
# does not survive the render is an index the generated models file silently loses.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Model_to_str round-trips an advanced index (#29)" begin
  m = Models.Model("result_rt",
    id      = Models.IDField(),
    raceid  = Models.IntegerField(),
    points  = Models.FloatField(),
    surname = Models.CharField(max_length = 60),
    indexes = [
      Models.Index(fields = ("raceid", "-points")),
      Models.Index(fields = ("surname",), method = "gin", opclasses = ("gin_trgm_ops",), name = "rt_trgm"),
      Models.Index(fields = ("raceid", "surname"), opclasses = (nothing, "varchar_pattern_ops"), name = "rt_mixed"),
    ],
  )
  str = Models.Model_to_str(m)
  @test occursin("Models.Index(fields = (\"raceid\", \"-points\",))", str)
  @test occursin("Models.Index(fields = (\"surname\",), name = \"rt_trgm\", method = \"gin\", opclasses = (\"gin_trgm_ops\",))", str)
  @test occursin("Models.Index(fields = (\"raceid\", \"surname\",), name = \"rt_mixed\", opclasses = (nothing, \"varchar_pattern_ops\",))", str)
  r = _ix_reload(str).cache["composite_indexes"]["indexes"]
  @test [Models._index_shape(ix) for ix in r] == [Models._index_shape(ix) for ix in m.cache["composite_indexes"]["indexes"]]
  @test [ix.name for ix in r] == [nothing, "rt_trgm", "rt_mixed"]
end

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
  # A plain (non-unique, bare) index as the readers report it.
  plain(name, cols) = LiveComposite(name, cols, false, false)

  # Healthy: attached under the same cache key a declaration writes.
  ok = _attach_composite_indexes!(base(), [plain("ix_ab", ["a", "b"])])
  @test ok.cache["composite_indexes"]["indexes"][1].fields == ["a", "b"]
  @test ok.cache["composite_indexes"]["indexes"][1].name == "ix_ab"
  @test !haskey(ok.cache, "unique_constraints")   # a plain index is not a constraint

  # A column the model does not carry → skipped, no cache entry, no exception.
  missing_col = _attach_composite_indexes!(base(), [plain("ix_ax", ["a", "gone"])])
  @test !haskey(missing_col.cache, "composite_indexes")

  # An unrepresentable column NAME → skipped, and the healthy sibling still lands.
  odd = Models.Model("live_odd", Dict{String, PormG.PormGField}(
    "id" => Models.IDField(), "a" => Models.IntegerField(), "b" => Models.IntegerField(),
    "a__b" => Models.IntegerField(),
  ))
  mixed = _attach_composite_indexes!(odd, [plain("ix_bad", ["a__b", "a"]), plain("ix_good", ["a", "b"])])
  @test length(mixed.cache["composite_indexes"]["indexes"]) == 1
  @test mixed.cache["composite_indexes"]["indexes"][1].name == "ix_good"

  # Nothing to attach leaves the cache untouched — a table with no composite index must be
  # byte-identical to how it introspected before this existed.
  none = _attach_composite_indexes!(base(), LiveComposite[])
  @test !haskey(none.cache, "composite_indexes")
end

# ─────────────────────────────────────────────────────────────────────────────
# _attach_composite_indexes!: an advanced index is written as declared (#29) — FOUND IN REVIEW
# A DESC or GIN index comes back with its `-` and its method; a non-default class by name. And one
# shape needs its DEFAULT class named too: PormG created `Index(fields = ("a",), opclasses =
# ("int4_ops",), name = …)` marked, but every class in it is the default, so it reads back PLAIN —
# and a plain one-field Index is refused. Before the fix the generated model declared nothing, and
# its first plan dropped the index as an undeclared plain composite PormG owns.
# Mutation gate: drop the default-class arm in `_attach_composite_indexes!` and `ix_a_named` is
# skipped, so the cache holds two indexes, not three.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_attach_composite_indexes! writes an advanced index as declared (#29)" begin
  base() = Models.Model("live_adv", Dict{String, PormG.PormGField}(
    "id" => Models.IDField(), "a" => Models.IntegerField(), "b" => Models.IntegerField(),
  ))
  adv(name, cols; method = "btree", desc = fill(false, length(cols)), opc = Union{String, Nothing}["int4_ops" for _ in cols],
      dflt = fill(true, length(cols)), marker = nothing) =
    LiveComposite(name, cols, false, false, method, desc, opc, dflt, marker, marker)
  m = _attach_composite_indexes!(base(), [
    adv("ix_desc", ["a", "b"]; desc = [false, true]),
    adv("ix_gin", ["a"]; method = "gin", opc = Union{String, Nothing}["array_ops"], dflt = [false]),
    adv("ix_a_named", ["a"]; marker = "pormg:index"),
  ])
  ixs = Dict(ix.name => ix for ix in m.cache["composite_indexes"]["indexes"])
  @test sort(collect(keys(ixs))) == ["ix_a_named", "ix_desc", "ix_gin"]
  @test (ixs["ix_desc"].fields, ixs["ix_desc"].descending) == (["a", "b"], [false, true])
  @test (ixs["ix_gin"].method, ixs["ix_gin"].opclasses) == ("gin", ["array_ops"])
  @test ixs["ix_a_named"].opclasses == ["int4_ops"]
  # Ownership rides along for the advanced ones; the marked plain one is PormG's either way.
  @test m.cache["composite_index_owners"]["ix_desc"] == (nothing, nothing)
  @test !haskey(m.cache["composite_index_owners"], "ix_a_named")
  # …and the declaration it writes matches the live index it came from, so the plan converges.
  d = only(x for x in PormG.Migrations.declared_composites(m) if x.name == "ix_a_named")
  @test PormG.Migrations.composite_shape_matches(adv("ix_a_named", ["a"]; marker = "pormg:index"), d)
end

# ─────────────────────────────────────────────────────────────────────────────
# Introspection seam, unique half (#161): a unique composite comes back as a UniqueConstraint
# Before #161 no reader produced one, so an inspectdb'd models file declared no composite
# uniqueness at all — and once makemigrations drops undeclared composites, that file's first
# migration would delete them. Both backings (a bare CREATE UNIQUE INDEX and a table-level
# UNIQUE clause) land in the SAME cache key a declaration writes, and SQLite's reserved
# `sqlite_autoindex_*` name is never written into a models file.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_attach_composite_indexes! routes a unique composite to UniqueConstraint (#161)" begin
  m = Models.Model("live_uq", Dict{String, PormG.PormGField}(
    "id" => Models.IDField(), "a" => Models.IntegerField(), "b" => Models.IntegerField(),
    "c" => Models.IntegerField(),
  ))
  _attach_composite_indexes!(m, [
    LiveComposite("ux_ab", ["a", "b"], true, false),                  # bare CREATE UNIQUE INDEX
    LiveComposite("sqlite_autoindex_live_uq_1", ["b", "c"], true, true),   # SQLite UNIQUE (b, c)
    LiveComposite("pg_uq_c", ["c"], true, false),                     # a one-field UniqueConstraint
    LiveComposite("ix_ca", ["c", "a"], false, false),                 # and a plain index beside them
  ])
  ucs = m.cache["unique_constraints"]["constraints"]
  @test [uc.fields for uc in ucs] == [["a", "b"], ["b", "c"], ["c"]]   # reader order kept
  @test ucs[1].name == "ux_ab"          # a real name is the live one, so re-migration reproduces it
  @test ucs[2].name === nothing         # the reserved autoindex name is NOT carried
  @test ucs[3].name == "pg_uq_c"
  # The plain index still lands in its own key — one kind never swallows the other.
  @test [ix.name for ix in m.cache["composite_indexes"]["indexes"]] == ["ix_ca"]
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
  # Since #29 a descending column, `opclasses=` and the `django.contrib.postgres` index classes
  # translate, and since #29 part 2 a `Lower`/`Upper`/`F` expression and a `condition=` the
  # CheckConstraint translator reads; what is left refused is what changes the index into one PormG
  # cannot declare.
  django = """
  class Servidor(models.Model):
      cpf = models.CharField(max_length=11)
      ativo = models.BooleanField(default=True)
      apelido = models.CharField(max_length=30)

      class Meta:
          indexes = [
              models.Index(fields=['cpf', 'apelido'], name='ok_idx'),
              models.Index(Collate('apelido', 'C'), name='expr_idx'),
              models.Index(fields=['cpf', 'ativo'], condition=Q(apelido__startswith='A'), name='partial_idx'),
              models.Index(Lower('apelido'), name='lower_idx'),
              models.Index(Lower('apelido'), name='lower_idx'),
              models.Index('cpf', Lower('apelido').desc(), name='str_idx'),
              models.Index(F('cpf'), F('ativo').desc(), name='f_idx'),
              models.Index(fields=['cpf', 'ativo'], condition=Q(ativo=True), name='ativo_idx'),
              models.Index(Lower('apelido'), fields=['cpf'], name='mixed_idx'),
              models.Index(Lower('cpf'), name='%(class)s_cpf_lower'),
              models.Index(Lower('apelido')),
              BloomIndex(fields=['cpf', 'apelido'], name='bloom_idx'),
              GinIndex(fields=['apelido'], fastupdate=False, name='slow_gin_idx'),
              models.Index(fields=['cpf'], include=['apelido'], name='covering_idx'),
          ]
  """
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(
    db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "ix_reject_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "ix_reject_unit.jl"), String)

    # The three PormG can express survive, and they are the ONLY Indexes emitted: the functional
    # one in Django's own spelling, the partial one's Q() through the CheckConstraint translator.
    @test occursin("Models.Index(fields = (\"cpf\", \"apelido\",), name = \"ok_idx\")", generated)
    @test occursin("Models.Index(expressions = (\"LOWER(\\\"apelido\\\")\",), name = \"lower_idx\")", generated)
    @test occursin("Models.Index(fields = (\"cpf\", \"ativo\",), name = \"ativo_idx\", condition = \"\\\"ativo\\\"\")", generated)
    # A bare positional string is Django's shorthand for F().
    @test occursin("Models.Index(expressions = (\"\\\"cpf\\\"\", \"LOWER(\\\"apelido\\\") DESC\",), name = \"str_idx\")", generated)
    # Members that are only fields — `F()` or a bare string — are a column index: `fields`, exactly.
    @test occursin("Models.Index(fields = (\"cpf\", \"-ativo\",), name = \"f_idx\")", generated)
    @test count(r"Models\.Index\((fields|expressions) = \(", generated) == 5   # declarations, not the hint in a marker
    # Each translated text index carries a note: its SQL is Django's, which a database Django already
    # built may store rewritten — so makemigrations may refuse it there and print the adopting text.
    # One per index that LANDED: the repeated `lower_idx` collapses, and so does its note.
    @test count("carries Django's SQL", generated) == 3
    @test count("index 'lower_idx' on 'Servidor' is functional", generated) == 1
    @test occursin("# PormG: index 'ativo_idx' on 'Servidor' is partial and carries Django's SQL", generated)

    # Each refusal is named in the file, with the reason that makes it a refusal.
    @test occursin("its expression `Collate('apelido', 'C')` is not translated", generated)
    @test occursin("Models.Index(expressions = …)", generated)
    @test occursin("its `condition=` is not translated", generated)
    @test occursin("it mixes expressions with `fields=`", generated)
    @test occursin("a functional index needs a `name=`", generated)
    @test occursin("its name uses a %(…)s placeholder", generated)
    @test occursin("BloomIndex has no PormG equivalent", generated)
    @test occursin("`fastupdate=` changes what the index means", generated)
    @test occursin("`include=` changes what the index means", generated)
    # Eight dropped indexes, eight markers — a blanket "report something" would pass a count of 1.
    @test count("an index on 'Servidor' was dropped", generated) == 8
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django importer: the PostgreSQL index classes, `opclasses=` and a descending column (#29)
# These were refused before #29, each as "PormG cannot express it". Each now lands as the
# `Models.Index` that creates the same index — and a one-field entry stays an `Index` unless it is
# plain, because only a plain one-column index is `db_index`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer translates GinIndex, opclasses= and -field (#29)" begin
  django = """
  class Piloto(models.Model):
      sobrenome = models.CharField(max_length=60)
      pontos = models.FloatField()
      corrida = models.IntegerField()
      data = models.DateField()

      class Meta:
          indexes = [
              models.Index(fields=['corrida', '-pontos'], name='piloto_corrida_pontos_idx'),
              models.Index(fields=['-pontos']),
              GinIndex(fields=['sobrenome'], name='piloto_sobrenome_gin', opclasses=['gin_trgm_ops']),
              BrinIndex(fields=['data'], name='piloto_data_brin'),
              HashIndex(fields=['sobrenome'], name='piloto_sobrenome_hash'),
              models.Index(fields=['sobrenome'], name='piloto_sobrenome_pattern',
                           opclasses=['varchar_pattern_ops']),
              models.Index(fields=['corrida']),
          ]
          index_together = [('-corrida', 'pontos')]
  """
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(
    db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "ix_pg_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "ix_pg_unit.jl"), String)

    @test occursin("Models.Index(fields = (\"corrida\", \"-pontos\",), name = \"piloto_corrida_pontos_idx\")", generated)
    @test occursin("Models.Index(fields = (\"-pontos\",))", generated)
    @test occursin("Models.Index(fields = (\"sobrenome\",), name = \"piloto_sobrenome_gin\", method = \"gin\", " *
                   "opclasses = (\"gin_trgm_ops\",))", generated)
    @test occursin("Models.Index(fields = (\"data\",), name = \"piloto_data_brin\", method = \"brin\")", generated)
    @test occursin("Models.Index(fields = (\"sobrenome\",), name = \"piloto_sobrenome_hash\", method = \"hash\")", generated)
    @test occursin("Models.Index(fields = (\"sobrenome\",), name = \"piloto_sobrenome_pattern\", " *
                   "opclasses = (\"varchar_pattern_ops\",))", generated)
    @test count("Models.Index(", generated) == 6
    # The one plain single-field entry is still the field's db_index.
    @test occursin(r"corrida\s*=\s*Models\.IntegerField\(db_index\s*=\s*true", generated)
    # `index_together` has no descending spelling in PormG's sense; it stays refused.
    @test occursin("DESCENDING column, which index_together cannot declare", generated)
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

# ─────────────────────────────────────────────────────────────────────────────
# Django importer: no line break from the imported source reaches a `# PormG:` marker (#29 part 2)
# A marker is a `#` comment in the generated models file, so a line break inside it ends the comment
# and the rest of the text runs as code when the file is loaded. A functional index's translated SQL
# names its `db_column`, which arrives from the imported `models.py` with `\n` decoded — and the
# duplicate-index, apply-failure and name-claim markers interpolate that SQL. Two guards: a column
# with a control character is not translated (the index is dropped and reported), and every marker
# is written as one line whatever a site put into it.
# Three guards, each enough on its own here: the `iscntrl` refusal, `_one_line` at the interpolating
# sites, and `_marker_line` at the join. Mutation gate: drop the `iscntrl` refusal and the
# control-character report vanishes (the index is then translated); make `_marker_line` the identity
# and its direct assertion fails.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer: no line break from the source reaches a marker (#29 part 2)" begin
  django = """
  class Driver(models.Model):
      surname = models.CharField(max_length=50, db_column="surname\\nrun(`touch /tmp/pormg_pwned`)\\n#")
      forename = models.CharField(max_length=50)

      class Meta:
          indexes = [
              models.Index(Lower("surname"), name="drv_lower"),
              models.Index(Lower("surname"), name="drv_lower"),
          ]
  """
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "ix_inject_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "ix_inject_unit.jl"), String)
    @test !any(l -> startswith(lstrip(l), "run("), split(generated, '\n'))
    @test occursin("the column of `surname` carries a control character", generated)
    @test !occursin("name = \"drv_lower\")", generated)   # no declaration landed
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
  # The structural guard on its own: whatever a site interpolated, a marker is one line.
  @test PormG.Migrations._marker_line("# PormG: x\nrun(`id`)\r\n# y z") == "# PormG: x run(`id`) # y z"
end

# ─────────────────────────────────────────────────────────────────────────────
# Django importer: a functional index whose name another model claimed is dropped once (#29 part 2)
# An index name is unique per database, so the importer surrenders a reused name and lets PormG
# derive one — but a functional or partial index cannot take a derived name (`Models.Index` requires
# one). The second claimant is therefore dropped, with ONE marker that says why; before, it got the
# "kept its columns but LOST its name" marker and a constructor refusal, which contradicted each other.
# Mutation gate: delete the early `continue` in the claim loop and the "LOST its name" marker returns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer: a claimed name drops a functional index once (#29 part 2)" begin
  django = """
  class Driver(models.Model):
      surname = models.CharField(max_length=50)
      class Meta:
          indexes = [models.Index(Lower("surname"), name="shared_lower")]

  class Constructor(models.Model):
      surname = models.CharField(max_length=50)
      class Meta:
          indexes = [models.Index(Lower("surname"), name="shared_lower")]
  """
  config_key = mktempdir()
  PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key, django_prefix = nothing)
  try
    import_models_from_django(django; db = config_key, file = "ix_claim_unit.jl", force_replace = true)
    generated = read(joinpath(config_key, "ix_claim_unit.jl"), String)
    @test count("name = \"shared_lower\")", generated) == 1
    @test count("is claimed by another declaration in this import", generated) == 1
    @test !occursin("LOST its name", generated)
    @test count("carries Django's SQL", generated) == 1      # the note rides only on the one that landed
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
  end
end
