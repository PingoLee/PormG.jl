# =============================================================================
# CTE names vs physical tables (#479), and cjoin_on aliases vs generated aliases (#480)
# =============================================================================
#
# Two leftovers of the #474 review, both about a name a query-time alias may NOT take:
#
#   #479 — SQL keeps a statement's CTE names and its table names in ONE namespace, and the CTE wins:
#          an unqualified `JOIN "d_parent"` reads a CTE called `d_parent` (PostgreSQL's SELECT
#          reference: "the WITH query hides any real table of the same name"; measured on SQLite,
#          where a CTE body reading its own name is additionally a `circular reference` error).
#          PormG generates its joins unqualified from `db_table`, so such a CTE silently redirected
#          every generated join to that table. Before this change the two join rows also collided
#          in `_insert_join`'s dedup tuple, so only ONE join was emitted and `CTE(name, col)` read
#          the physical column. "Emit both joins" is not a fix — both would read the CTE — so the
#          name is refused at the `.with()` call, against every table PormG can render from the
#          models it knows: every registered module's models, and their many-to-many join tables.
#
#   #480 — `_get_alias_name` picked the next free `<base>_<n>` from the joins materialized SO FAR,
#          and a `cjoin_on` row is materialized LAST, writing the user's alias verbatim. So
#          `cjoin_on(alias = "R1_1")` and a generated `R1_1` ended up as two range variables of one
#          name. The generator now reserves every declared `cjoin_on` alias, and materialization
#          refuses an alias the statement already holds (the base relation's own alias, which no
#          generator ever avoids).
#
# Everything renders through mock connections — no live database.
#
# Sibling coverage:
#   - `test_cte_ergonomics.jl`          → two references to ONE unkeyed CTE still dedup to a single
#                                          CROSS JOIN — the dedup tuple is untouched here.
#   - `test_relation_alias_namespace.jl` → #474: a CTE name MAY equal a join key; the generated
#                                          aliases it pins (`R1_1`, `R1_2`) are unchanged by #480.
#   - `test_cjoin_on.jl`                 → the #45 surface, including duplicate-alias refusal
#                                          between two user aliases.
#
# julia --project=. test/unit/test_cte_table_name_and_alias_reservation.jl

using Test
using PormG
using PormG.Models

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct CtsMockSQLite <: PormG.PormGSQLite end
struct CtsMockPostgres <: PormG.PormGPostgres end
const _CTS_SL = CtsMockSQLite()
const _CTS_PG = CtsMockPostgres()
PormG.backend_sqlite_version(::CtsMockSQLite) = 3045000

PormG.config["cts_mock"] = PormG.Configuration.Settings(
  connections = _CTS_SL, change_data = true, db_def_folder = "cts_mock",
)
# A SECOND registration path: two model files registered under two `db_def_folder`s against one
# database is a legal shape (two apps in one process), and #479's walk is scoped by path.
PormG.config["cts_mock_b"] = PormG.Configuration.Settings(
  connections = _CTS_SL, change_data = true, db_def_folder = "cts_mock_b",
)

# `set_models` is REQUIRED: `_build_row_join` reads `instruct.object.model._module::Module`, and
# #479's check walks that module for every `db_table` it can reach.
module CtsModels
import PormG
import PormG.Models

Cts_grand = Models.Model("cts_grand",
  id   = Models.IDField(),
  code = Models.CharField(),
)

Cts_parent = Models.Model("cts_parent",
  id  = Models.IDField(),
  # `db_column` on purpose: it is what tells the ForeignKey path's physical column
  # (`"product_sku"`) apart from a CTE projection alias (`"sku"`) in a rendered assertion.
  sku = Models.CharField(db_column = "product_sku"),
)

Cts_child = Models.Model("cts_child",
  id     = Models.IDField(),
  # NULLABLE — `_determine_join_type` answers "LEFT", which is what the control below pins next
  # to the CTE's declared INNER.
  parent = Models.ForeignKey(Cts_parent, on_delete = "CASCADE", related_name = "cts_kids", null = true),
  grand  = Models.ForeignKey(Cts_grand, on_delete = "CASCADE", related_name = "cts_gkids", null = true),
  note   = Models.CharField(null = true),
)

# Never joined by any shape in this file — it exists to pin that #479 refuses by TABLE NAME, not by
# what the statement happens to join.
Cts_orphan = Models.Model("cts_orphan",
  id = Models.IDField(),
)

# A many-to-many pair: the auto-synthesized THROUGH table has no model binding of its own, so the
# #479 check has to read it off the relation (a review probe rendered the collapse through it).
Cts_tag = Models.Model("cts_tag",
  id   = Models.IDField(),
  name = Models.CharField(),
)

Cts_item = Models.Model("cts_item",
  id   = Models.IDField(),
  tags = Models.ManyToManyField(Cts_tag, related_name = "cts_items"),
)

PormG.Models.set_models(@__MODULE__, "cts_mock")
end

# A ForeignKey target in a DIFFERENT module from the query's model. The issue's collapse rendered
# through exactly this in review when only the query's own module was walked; the check now covers
# every module registered under the query module's path, plus the modules of each base model's
# direct relation targets whatever path they registered under.
module CtsOther
import PormG
import PormG.Models

Cts_other_parent = Models.Model("cts_other_parent",
  id  = Models.IDField(),
  sku = Models.CharField(),
)

PormG.Models.set_models(@__MODULE__, "cts_mock")
end

module CtsCross
import PormG
import PormG.Models
import ..CtsOther

Cts_cross_child = Models.Model("cts_cross_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(CtsOther.Cts_other_parent, on_delete = "CASCADE", related_name = "cts_cross_kids", null = true),
  note   = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "cts_mock")
end

# A ForeignKey target registered under ANOTHER path. The path-scoped walk cannot see it; only the
# direct-relation-target clause does. Review probe: with the CTE body from the child's own module,
# this shape rendered the collapse before that clause existed.
module CtsFarDb
import PormG
import PormG.Models

Cts_far_parent = Models.Model("cts_far_parent",
  id  = Models.IDField(),
  sku = Models.CharField(),
)

PormG.Models.set_models(@__MODULE__, "cts_mock_b")
end

module CtsFarChild
import PormG
import PormG.Models
import ..CtsFarDb

Cts_far_child = Models.Model("cts_far_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(CtsFarDb.Cts_far_parent, on_delete = "CASCADE", related_name = "cts_far_kids", null = true),
  note   = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "cts_mock")
end

const CTS = CtsModels
import PormG.QueryBuilder: F, inspect_query, Joined
using PormG: CTE

_cts_sql(q; conn = _CTS_SL) = inspect_query(q; connection = conn)[:sql_text]
_cts_no_ansi(s::AbstractString) = replace(s, r"\e\[[0-9;]*m" => "")
# Fresh handlers per shape: `.with(...)` deepcopies its query, but reusing one across shapes would
# still share the builder state a previous render mutated.
_cts_parent() = begin c = CTS.Cts_parent.objects; c.values("id", "sku"); c end
_cts_grand()  = begin c = CTS.Cts_grand.objects;  c.values("id", "code"); c end

# Capture the exception a thunk raises (or `nothing`), so a message can be asserted on.
function _cts_catch(f)
  try
    f()
    nothing
  catch e
    e
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #479: a CTE may not be named after a physical table — refused at the .with() call
# The refusal is backend-independent (no SQL is rendered), so these run once. What each pins is
# WHERE the error lands (the declaration, not a later render) and WHAT it names (the CTE, and the
# model whose `db_table` it would shadow).
# ─────────────────────────────────────────────────────────────────────────────
@testset "a CTE may not be named after a physical table (#479)" begin

  @testset "the issue's shape: the db_table of a relation the query joins" begin
    # Before #479 this built ONE join — the ForeignKey's LEFT, not the CTE's declared INNER — and
    # `CTE("cts_parent", "sku")` read `"R1_1"."product_sku"`, the physical column.
    q = CTS.Cts_child.objects
    err = _cts_catch() do
      q.with("cts_parent" => _cts_parent(), join_field = "parent" => "id", join_type = "INNER")
    end
    @test err isa PormG.QueryBuildError
    msg = _cts_no_ansi(sprint(showerror, err))
    @test occursin("CTE name \"cts_parent\"", msg)     # the name the caller wrote
    @test occursin("physical table", msg)              # ...and why it is refused
    @test occursin("db_table \"cts_parent\"", msg)     # the table it would shadow
    # The body IS the shadowed table here, so the SQLite circular-reference note applies.
    @test occursin("circular reference", msg)
    # Nothing was declared: the refusal happened before the CTE was stored.
    @test isempty(q.object.ctes)
  end

  @testset "the issue's true shape: the CTE body is UNRELATED to the table it shadows" begin
    # The case above is caught by the body's own base model. This one is not: the body reads
    # `cts_grand`, and only the walk over the module's models can know `cts_parent` is a table —
    # which is the ForeignKey join the statement generates for `parent__sku`.
    err = _cts_catch() do
      CTS.Cts_child.objects.with("cts_parent" => _cts_grand(), join_field = "parent" => "id")
    end
    @test err isa PormG.QueryBuildError
    msg = _cts_no_ansi(sprint(showerror, err))
    @test occursin("db_table \"cts_parent\"", msg)
    @test !occursin("circular reference", msg)         # the body does not read itself here
  end

  @testset "the base relation's own table" begin
    # `FROM "cts_child"` would itself read the CTE — the same rule, one hop closer.
    err = _cts_catch() do
      CTS.Cts_child.objects.with("cts_child" => _cts_parent())
    end
    @test err isa PormG.QueryBuildError
    @test occursin("db_table \"cts_child\"", _cts_no_ansi(sprint(showerror, err)))
  end

  @testset "a many-to-many through table" begin
    # The join table `_insert_many_to_many_joins` renders has no model binding; its name lives on
    # the relation. Read it from there rather than hard-coding the derived spelling.
    through = PormG.Models.get_many_to_many_relation(CTS.Cts_item, "tags").through_table
    err = _cts_catch() do
      CTS.Cts_item.objects.with(through => CTS.Cts_tag.objects.values("id", "name"))
    end
    @test err isa PormG.QueryBuildError
    msg = _cts_no_ansi(sprint(showerror, err))
    @test occursin("many-to-many through table", msg)
    @test occursin("cts_item.tags", msg)               # names the owning model and field
  end

  @testset "a ForeignKey target in another module" begin
    # `Cts_cross_child.parent` points at `CtsOther.Cts_other_parent`. The body is deliberately the
    # child itself — unrelated to the shadowed table — so neither base model can catch this; only
    # the walk over the other REGISTERED module can know `cts_other_parent` is a table. (A body of
    # `Cts_other_parent` would pass through the body's-own-model check and prove nothing.)
    err = _cts_catch() do
      CtsCross.Cts_cross_child.objects.with("cts_other_parent" =>
        CtsCross.Cts_cross_child.objects.values("id", "note"), join_field = "parent" => "id")
    end
    @test err isa PormG.QueryBuildError
    @test occursin("db_table \"cts_other_parent\"", _cts_no_ansi(sprint(showerror, err)))
  end

  @testset "a ForeignKey target registered under another path" begin
    # `Cts_far_child` (path `cts_mock`) points at `CtsFarDb.Cts_far_parent` (path `cts_mock_b`).
    # The path-scoped module walk excludes `CtsFarDb`; the body is the child itself, so neither
    # base model is the target. Only the direct-relation-target clause can refuse this.
    err = _cts_catch() do
      CtsFarChild.Cts_far_child.objects.with("cts_far_parent" =>
        CtsFarChild.Cts_far_child.objects.values("id", "note"), join_field = "parent" => "id")
    end
    @test err isa PormG.QueryBuildError
    @test occursin("db_table \"cts_far_parent\"", _cts_no_ansi(sprint(showerror, err)))
    # ...while a table that exists ONLY under the other path, unrelated to this child, stays free:
    # nothing in this statement's namespace can shadow it.
    q = CTS.Cts_child.objects
    q.with("cts_far_parent" => _cts_grand())
    @test haskey(q.object.ctes, "cts_far_parent")
  end

  @testset "a many-to-many through table, reached from the REVERSE side" begin
    # Rooted on the tag, whose `related_objects` holds the reverse `ManyToManyRelation`; the owner
    # is not a candidate ahead of it here, so this is the reverse loop's only exercise. The body is
    # the query's own model, which is NOT the shadowed relation — so the SQLite note must not fire.
    through = PormG.Models.get_many_to_many_relation(CTS.Cts_item, "tags").through_table
    err = _cts_catch() do
      CTS.Cts_tag.objects.with(through => CTS.Cts_tag.objects.values("id", "name"))
    end
    @test err isa PormG.QueryBuildError
    msg = _cts_no_ansi(sprint(showerror, err))
    @test occursin("many-to-many through table", msg)
    @test occursin("cts_tag.cts_items", msg)           # the reverse accessor, on the reverse owner
    @test !occursin("circular reference", msg)
  end

  @testset "a table the statement never joins is refused too (deliberate)" begin
    # The joined set is only known at render; a name the module reserves for a table is refused
    # regardless. Nothing is lost — pick another CTE name — and the check stays on the line the
    # user wrote instead of moving to a later `list()`.
    err = _cts_catch() do
      CTS.Cts_child.objects.with("cts_orphan" => _cts_grand())
    end
    @test err isa PormG.QueryBuildError
  end

  for (backend, conn) in (("PostgreSQL", _CTS_PG), ("SQLite", _CTS_SL))
    @testset "the rule is the TABLE name, not the model binding ($backend)" begin
      # `Cts_parent` is the Julia binding; the table is `cts_parent`. Quoted identifiers are
      # case-sensitive on both engines, so `"Cts_parent"` and `"cts_parent"` are two names — and a
      # CTE under the binding's spelling shadows nothing.
      q = CTS.Cts_child.objects
      q.with("Cts_parent" => _cts_parent(), join_field = "parent" => "id", join_type = "INNER")
      q.values("note", "cte_sku" => CTE("Cts_parent", "sku"))
      sql = _cts_sql(q; conn = conn)
      @test occursin("INNER JOIN \"Cts_parent\" AS \"R1_1\" ON \"R1\".\"parent\" = \"R1_1\".\"id\"", sql)
    end
  end

  # ── control: the coexistence the issue asked for, under a name that is not a table ──────
  # Two joins, each with its own alias and its own declared join_type; the ForeignKey path reads
  # the physical column and the CTE handle reads the CTE's projection. This is what "two joins"
  # legitimately looks like — and what a dedup-only fix would have faked with two reads of the CTE.
  for (backend, conn) in (("PostgreSQL", _CTS_PG), ("SQLite", _CTS_SL))
    @testset "control on $backend: a non-table name renders both joins, each reading its own relation" begin
      q = CTS.Cts_child.objects
      q.with("other" => _cts_parent(), join_field = "parent" => "id", join_type = "INNER")
      q.values("note", "fk_sku" => "parent__sku", "cte_sku" => CTE("other", "sku"))
      sql = _cts_sql(q; conn = conn)
      # The ForeignKey's join: nullable, so LEFT, and it reads the PHYSICAL column.
      @test occursin("LEFT JOIN \"cts_parent\" AS \"R1_1\" ON \"R1\".\"parent\" = \"R1_1\".\"id\"", sql)
      @test occursin("\"R1_1\".\"product_sku\" as \"fk_sku\"", sql)
      # The CTE's join: the INNER it declared, and it reads the CTE's projection alias.
      @test occursin("INNER JOIN \"other\" AS \"R1_2\" ON \"R1\".\"parent\" = \"R1_2\".\"id\"", sql)
      @test occursin("\"R1_2\".\"sku\" as \"cte_sku\"", sql)
      @test count("JOIN", sql) == 2
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #480: a cjoin_on alias cannot impersonate a generated alias
# Each shape declares a user alias spelled exactly like the alias PormG would have generated for
# the join it materializes FIRST. Before #480 both landed in the statement under one name. Now the
# generated join steps to the next free name, and the user's alias appears exactly once.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a cjoin_on alias cannot impersonate a generated alias (#480)" begin
  for (backend, conn) in (("PostgreSQL", _CTS_PG), ("SQLite", _CTS_SL))
    @testset "$backend" begin

      @testset "the issue's shape: an unkeyed CTE and alias = \"R1_1\"" begin
        # The CTE is declared and referenced BEFORE the cjoin_on — the order that lost before, since
        # the CTE's alias was chosen while no cjoin_on row existed to be avoided.
        q = CTS.Cts_child.objects
        q.with("evs" => _cts_grand())
        q.filter("grand" => CTE("evs", "id"))               # correlate the CROSS JOIN (#44)
        q.values("note", "c" => CTE("evs", "code"))
        q.cjoin_on("Cts_parent", alias = "R1_1", on = [Joined("R1_1", "sku") == F("note")])
        sql = _cts_sql(q; conn = conn)
        # The CTE stepped around the declared alias...
        @test occursin("CROSS JOIN \"evs\" AS \"R1_2\"", sql)
        @test occursin("\"R1_2\".\"code\" as \"c\"", sql)
        # ...and the user's alias is one range variable, with its own ON clause.
        @test occursin("INNER JOIN \"cts_parent\" AS \"R1_1\" ON (\"R1_1\".\"product_sku\" = \"R1\".\"note\")", sql)
        @test count("AS \"R1_1\"", sql) == 1
      end

      @testset "a keyed CTE, cjoin_on declared FIRST" begin
        # Declaration order does not matter: `custom_join` is complete before `build()` starts, so
        # the reservation holds whichever side the caller wrote first.
        q = CTS.Cts_child.objects
        q.cjoin_on("Cts_parent", alias = "R1_1", on = [Joined("R1_1", "sku") == F("note")])
        q.with("evs" => _cts_grand(), join_field = "grand" => "id", join_type = "INNER")
        q.values("note", "c" => CTE("evs", "code"))
        sql = _cts_sql(q; conn = conn)
        @test occursin("INNER JOIN \"evs\" AS \"R1_2\" ON \"R1\".\"grand\" = \"R1_2\".\"id\"", sql)
        @test occursin("\"R1_2\".\"code\" as \"c\"", sql)
        @test count("AS \"R1_1\"", sql) == 1
      end

      @testset "an ordinary ForeignKey join, no CTE at all" begin
        # The issue notes it reproduces with two ordinary joins as easily as with a CTE. Without a
        # CTE the base alias is `Tb`, so the ForeignKey join would have been `Tb_1`.
        q = CTS.Cts_child.objects
        q.values("note", "parent__sku")
        q.cjoin_on("Cts_grand", alias = "Tb_1", on = [Joined("Tb_1", "code") == F("note")])
        sql = _cts_sql(q; conn = conn)
        @test occursin("LEFT JOIN \"cts_parent\" AS \"Tb_2\" ON \"Tb\".\"parent\" = \"Tb_2\".\"id\"", sql)
        @test occursin("\"Tb_2\".\"product_sku\" as \"parent__sku\"", sql)
        @test occursin("INNER JOIN \"cts_grand\" AS \"Tb_1\" ON (\"Tb_1\".\"code\" = \"Tb\".\"note\")", sql)
        @test count("AS \"Tb_1\"", sql) == 1
      end

      @testset "the base relation's own alias is refused" begin
        # `_get_alias_name` never generates the base alias, so reservation cannot step around it —
        # this is the fail-closed backstop in `_build_cjoin_on_row_join`. The base alias depends on
        # the build context (`Tb` for a plain statement, `R1` once a CTE is declared), so both are
        # exercised and the assertion is on the message, not the spelling.
        plain = CTS.Cts_child.objects
        plain.values("note")
        plain.cjoin_on("Cts_grand", alias = "Tb", on = [Joined("Tb", "code") == F("note")])
        err = _cts_catch(() -> _cts_sql(plain; conn = conn))
        @test err isa PormG.QueryBuildError
        @test occursin("already the alias of \"cts_child\"", _cts_no_ansi(sprint(showerror, err)))

        with_cte = CTS.Cts_child.objects
        with_cte.with("evs" => _cts_grand(), join_field = "grand" => "id")
        with_cte.values("note", "c" => CTE("evs", "code"))
        with_cte.cjoin_on("Cts_parent", alias = "R1", on = [Joined("R1", "sku") == F("note")])
        err2 = _cts_catch(() -> _cts_sql(with_cte; conn = conn))
        @test err2 isa PormG.QueryBuildError
        @test occursin("already the alias of \"cts_child\"", _cts_no_ansi(sprint(showerror, err2)))
      end

      @testset "a generated-looking spelling that collides with nothing still renders" begin
        # The rule is about an actual collision, not a reserved spelling: with no CTE declared the
        # base alias is `Tb`, so `R1` is simply a free name.
        q = CTS.Cts_child.objects
        q.values("note")
        q.cjoin_on("Cts_grand", alias = "R1", on = [Joined("R1", "code") == F("note")])
        sql = _cts_sql(q; conn = conn)
        @test occursin("INNER JOIN \"cts_grand\" AS \"R1\" ON (\"R1\".\"code\" = \"Tb\".\"note\")", sql)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The module walk tolerates a constant imported from two modules (#479, Models.jl)
# A models module carrying a name `Base.binding_module` cannot resolve. `TwinA` and `TwinB` both
# export a constant of the same VALUE (`===`-equal integers): Julia 1.12 files that as an implicit
# constant import with no single ultimate binding, and `Base.binding_module(mod, :cts_twin)` throws
# "Constant binding was imported from multiple modules". Both module walkers in `Models` called it
# bare, which only ever mattered inside `set_models` on a clean module — until #479 made `.with()`
# walk the query's module on every call, where the full unit suite's `Main` carries such a name.
# The walk must skip the name (it cannot be a model), not die on it.
#
# Deliberately LAST in the file: on a tree without the guard, `set_models` below throws at include
# time, so everything above still runs and reports per testset, and only this block goes red.
# ─────────────────────────────────────────────────────────────────────────────
module CtsPolluted
import PormG
import PormG.Models
module TwinA; export cts_twin; const cts_twin = 1; end
module TwinB; export cts_twin; const cts_twin = 1; end
using .TwinA, .TwinB

Cts_polluted_parent = Models.Model("cts_polluted_parent",
  id  = Models.IDField(),
  sku = Models.CharField(),
)

Cts_polluted_child = Models.Model("cts_polluted_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Cts_polluted_parent, on_delete = "CASCADE", related_name = "cts_polluted_kids", null = true),
  note   = Models.CharField(null = true),
)

# `set_models` runs the sibling walker (`_collect_models_and_bindings`); before the guard this line
# was the first thing to throw.
PormG.Models.set_models(@__MODULE__, "cts_mock")
end

@testset "the module walk tolerates a constant imported from two modules (#479)" begin
  # The premise: this binding really is unresolvable on the Julia this suite runs on. If a future
  # Julia stops throwing here, the guard in `Models._binding_owner_or_nothing` becomes dead code
  # and this line is what says so.
  @test_throws ErrorException Base.binding_module(CtsPolluted, :cts_twin)
  # `get_all_models` — the walker `_with` calls — skips the name instead of dying on it, and still
  # finds both models.
  found = PormG.Models.get_all_models(CtsPolluted)
  @test length(found) == 2
  # And the two #479 outcomes hold on a model rooted in that module: a free name declares...
  q = CtsPolluted.Cts_polluted_child.objects
  q.with("best" => CtsPolluted.Cts_polluted_parent.objects.values("id", "sku"),
         join_field = "parent" => "id")
  @test haskey(q.object.ctes, "best")
  # ...and a table name is refused, which proves the walk reached the sibling model.
  err = _cts_catch() do
    CtsPolluted.Cts_polluted_child.objects.with("cts_polluted_parent" =>
      CtsPolluted.Cts_polluted_parent.objects.values("id", "sku"))
  end
  @test err isa PormG.QueryBuildError
end
