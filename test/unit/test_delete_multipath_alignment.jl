"""
Unit coverage for multi-path cascade deletes (#452).

`delete_objects` built one `WHERE` fragment per cascade path, and then — when a model was reachable
by MORE than one path — discarded all of them, rebuilt the same subqueries through a `Qor`, and
rendered that into the SAME parameter collector. The fragments' values stayed behind with no markers
pointing at them, so the statement carried twice as many bound values as it had placeholders.

That is the `#421 / #432 / #441` invariant reached by a fourth route:

    on a positional backend, the number of markers a statement renders must equal the number of
    values bound, and the Nth value must be the one whose marker is Nth IN THE TEXT.

Measured before the fix (mock connections, no database):

    Dmp_a filtered "code" => "DELME", two CASCADE FKs from Dmp_b
    dmp_b     markers = 2   parameters = 4   ["DELME", "DELME", "DELME", "DELME"]
    dmp_a     markers = 1   parameters = 1   ["DELME"]

Both backends produced the mismatch. SQLite refuses the surplus at execution
(`SQLiteException("values should be provided for all query placeholders")`), so a multi-path cascade
delete never worked at all — it was a loud failure, not a silent wrong delete.

The discarded branch carried a SECOND defect, which is why it was removed rather than patched: it
addressed every arm with `keys[1][:key]`. Entries for one model do NOT necessarily share a resolved
key — `resolve_delete_key` falls back to the referencing FIELD name when the model has no primary
key — so a keyless child reached by two foreign keys compared ONE column against the OTHER
column's values. Measured on this file's own `Dmp_k`: `"owner" IN (SELECT … "backup" …)`. Which of
the two keys wins is `related_objects` Dict order, so the direction flips between model sets — an
earlier fixture produced the mirror image. That arbitrariness is the point, and it is why the
assertion below is structural rather than a literal-string match. That one WAS a silent wrong
delete, and it is now unrepresentable: since #765 each arm is a predicate on the target's own foreign
key (`"Tb"."owner" IN (SELECT "R1"."id" …)`), so there is no key left to share.

**What the `cjoin` shape does and does NOT cover.** It gives the plan two DISTINCT sentinels, one
rendered in a JOIN `ON` and one in a `WHERE`, so the assertions here are about text order rather
than about a single repeated string — the plain-root reproduction binds `"DELME"` four times, where
any permutation reads as correct. Keep it for that.

Until #765 it did **not** discriminate #432's mark/detach wrap: no statement ever got TWO
join-binding fragments. Cascade fragments are built as
`child.objects.filter("<fk>__@in" => parent).values(<key>)` and carry no join, and the root queryset
was always alone in its statement, where a lone fragment's `:join`-before-`:where` flatten already
matches its text order.

Since #765 the `dmp_a` root statement IS the discriminating case. A joined root renders as
`"Tb"."id" IN (<selection>) AND EXISTS (<fence>)` — two builds of the same query, each binding its
`ON` value then its `WHERE` value. Unwrapped, `:join` flattens both `ON` values first
(`ONVAL, ONVAL, WHEREVAL, WHEREVAL` against a text order of `ONVAL, WHEREVAL, ONVAL, WHEREVAL`), so
the `dmp_a` text-order assertion below must fail without it (measured on the same shape in
`test_mutation_fence_shape.jl`, by stripping the wrap from `_mutation_predicate`). The cascade
statements still cannot tell.

Both backends run. PostgreSQL's `\$N` travels with the text by construction, which is why every bug
in this family has been SQLite-only — but the COUNT half fails on both, and did here.
"""
# julia --project=test/integration test/unit/test_delete_multipath_alignment.jl

using Test
using PormG
using PormG.Models

include("helper_marker_alignment.jl")

struct DmpMockSQLite <: PormG.PormGSQLite end
struct DmpMockPostgres <: PormG.PormGPostgres end
const _DMP_SL = DmpMockSQLite()
const _DMP_PG = DmpMockPostgres()
PormG.backend_sqlite_version(::DmpMockSQLite) = 3045000

PormG.config["dmp_mock"] = PormG.Configuration.Settings(
  connections = _DMP_SL,
  change_data = true,
  db_def_folder = "dmp_mock",
)

module DmpModels
import PormG
import PormG.Models

# Grandparent of the root, reachable only through a cjoin. Its `on_delete` is DO_NOTHING so it
# contributes a parameterized JOIN to the root query WITHOUT adding a cascade path of its own.
Dmp_root = Models.Model("dmp_root",
  id  = Models.IDField(),
  tag = Models.CharField(),
)

Dmp_a = Models.Model("dmp_a",
  id   = Models.IDField(),
  code = Models.CharField(),
  root = Models.ForeignKey(Dmp_root, on_delete = "DO_NOTHING", related_name = "dmp_as", null = true),
)

# TWO CASCADE foreign keys to the same parent — the shape that puts two entries in
# `collector.objects[Dmp_b]` and therefore takes the multi-path path in `delete_objects`.
Dmp_b = Models.Model("dmp_b",
  id     = Models.IDField(),
  owner  = Models.ForeignKey(Dmp_a, on_delete = "CASCADE", related_name = "owned",   null = true),
  backup = Models.ForeignKey(Dmp_a, on_delete = "CASCADE", related_name = "backups", null = true),
)

# Third level: reached recursively through BOTH of Dmp_b's entries, so it is multi-path too.
Dmp_c = Models.Model("dmp_c",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Dmp_b, on_delete = "CASCADE", related_name = "kids", null = true),
)

# Keyless twin of Dmp_b: no IDField, so `resolve_delete_key` falls back to the FK field name and the
# two entries resolve DIFFERENT keys. This is the fixture for the wrong-key defect.
Dmp_k = Models.Model("dmp_k",
  owner  = Models.ForeignKey(Dmp_a, on_delete = "CASCADE", related_name = "k_owned",   null = true),
  backup = Models.ForeignKey(Dmp_a, on_delete = "CASCADE", related_name = "k_backups", null = true),
  label  = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "dmp_mock")
end

const DMP = DmpModels
const _DMP_BACKENDS = (("PostgreSQL", _DMP_PG, :postgres), ("SQLite", _DMP_SL, :sqlite))

"""Every statement `delete()` emits for `build_q`, as a Vector of inspection Dicts."""
function _dmp_steps(build_q, conn)
  res = build_q().delete(show_query = :dict, connection = conn)
  return res isa Vector ? res : [res]
end

"""The step whose `:model` is `name`. Fails loudly rather than returning `nothing`."""
function _dmp_step(steps, name::String)
  # The WRITE step: a #770 `:lock` step for the same model (PostgreSQL) is skipped.
  idx = findfirst(s -> s[:model] == name && s[:operation] != :lock, steps)
  @assert idx !== nothing "no step for $(name); got $([s[:model] for s in steps])"
  return steps[idx]
end

# A root queryset with a plain single-value filter. Every value in the plan descends from it.
_dmp_plain_root() = begin
  q = DMP.Dmp_a.objects
  q.filter("code" => "DELME")
  q
end

# The same root, plus a parameterized JOIN. Two DISTINCT sentinels, one landing in `:join` and one in
# `:where`, are what make a misbind visible at all — see the file docstring.
_dmp_joined_root() = begin
  q = DMP.Dmp_a.objects
  q.filter("code" => "WHEREVAL")
  q.cjoin("root" => "Dmp_root", filters = ["tag" => "ONVAL"], warn = false)
  q
end

# ─────────────────────────────────────────────────────────────────────────────
# Multi-path cascade: every emitted statement binds exactly as many values as it renders markers
# This is #452's acceptance criterion, and the half that failed on BOTH backends. Asserted over
# every step of the plan rather than the offending one, so a future cascade change that reintroduces
# the defect on a different statement is caught here too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every delete() statement binds one value per marker (#452)" begin
  for (label, build_q) in (("plain root filter", _dmp_plain_root),
                           ("root with a parameterized JOIN", _dmp_joined_root))
    @testset "$label" begin
      for (backend, conn, kind) in _DMP_BACKENDS
        steps = _dmp_steps(build_q, conn)
        # dmp_b and dmp_k are multi-path (two CASCADE FKs each); dmp_c is multi-path through the
        # recursion; dmp_a is the single-key root. All four must hold.
        @test count(s -> s[:operation] != :lock, steps) == 4
        # #770: on PostgreSQL the two parents (dmp_a, then dmp_b) are locked first, through the same
        # multi-arm predicates — so the marker loop below covers the lock statements too.
        @test [s[:model] for s in steps if s[:operation] == :lock] == (kind === :postgres ? ["dmp_a", "dmp_b"] : String[])
        for step in steps
          assert_marker_count(step, kind)
        end
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Multi-path cascade: SQLite binds in TEXT order, not in bucket order
# #432's half of the invariant, asserted on a plan carrying two DISTINCT sentinels so that a
# permutation cannot read as correct. This is a property test, not a wrap test: see the file
# docstring — removing `delete_objects`' mark/detach wrap leaves these vectors unchanged, because
# the root query's ON value arrives already flattened into `:where` through the read builder's own
# `__@in` splice. What it does pin is that the fragment loop preserves that order across TWO
# fragments sharing one collector, which is the arrangement #452 introduced.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a multi-path delete binds in text order on SQLite (#452 / #432)" begin
  steps = _dmp_steps(_dmp_joined_root, _DMP_SL)

  # Two fragments, each contributing its subquery's ON value then its WHERE value.
  for model in ("dmp_b", "dmp_k")
    step = _dmp_step(steps, model)
    assert_marker_count(step, :sqlite)
    assert_bound_in_text_order(step, ["ONVAL", "WHEREVAL", "ONVAL", "WHEREVAL"])
    # The whole run lands in one bucket — but do not credit this file's wrap for it. What puts
    # these values in `:where` is the read builder's own `__@in` splice inside each fragment, which
    # lifts the nested root query's `ON` value before the delete-level splice ever sees it.
    #
    # Measured against the unfixed `delete_objects`, the two lines below differ: `isempty(:join)`
    # passes there (the values were already all in `:where`), while the `:where ==` equality fails,
    # because the unfixed statement bound EIGHT values for four markers. So the first line is a
    # shape pin with no discriminating power and the second is a real regression guard. Kept
    # together because the pair states the property; labelled so neither is mistaken for the other.
    @test step[:parameter_buckets][:where] == ["ONVAL", "WHEREVAL", "ONVAL", "WHEREVAL"]
    @test isempty(step[:parameter_buckets][:join])
  end

  # The single-key root statement is the control: its ON value used to sit in `:join` and its WHERE
  # value in `:where`, which flattened to the same vector. Pin the FLATTENED vector, not the bucket —
  # the wrap moves the value between buckets on purpose and that is not a behaviour change.
  #
  # Since #765 the joined root is `"Tb"."id" IN (<selection>) AND EXISTS (<fence>)`: two builds, each
  # binding its ON then its WHERE value. Unwrapped, `:join` would flatten both ON values first.
  root_step = _dmp_step(steps, "dmp_a")
  assert_marker_count(root_step, :sqlite)
  assert_bound_in_text_order(root_step, ["ONVAL", "WHEREVAL", "ONVAL", "WHEREVAL"])
end

# ─────────────────────────────────────────────────────────────────────────────
# Multi-path cascade on a KEYLESS model: each arm is addressed by its own resolved key
# The removed branch used `keys[1][:key]` for every arm. A keyless child reached by two FKs resolves
# a different key per entry, so ONE column got compared against the OTHER column's values — a silent
# WRONG DELETE, once the parameter mismatch above no longer stopped the statement from executing.
# Measured on this fixture: `"owner" IN (SELECT … "backup" …)`. Which key wins is `related_objects`
# Dict order and flips between model sets, so the assertion is structural rather than a literal
# match: each arm's outer column must equal the column its OWN subquery projects.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a keyless multi-path delete addresses each arm by its own key (#452)" begin
  for (backend, conn, kind) in _DMP_BACKENDS
    step = _dmp_step(_dmp_steps(_dmp_plain_root, conn), "dmp_k")
    sql = step[:sql_text]

    # Each top-level arm is `("Tb"."<fk>" IN (SELECT "R1"."id" …))`: the target's OWN foreign key
    # compared against the parent's primary key. Since #765 an arm no longer goes through the entry's
    # resolved key at all — it reads its column straight off the target — which is what makes the
    # wrong-key shape unrepresentable rather than merely avoided. What this still detects is the arm
    # COUNT collapsing from two to one (the pre-#452 render produced exactly ONE top-level arm
    # wrapping a nested OR), and an arm reading the wrong side of the relation.
    #
    # Anchored on `WHERE`/`OR` plus the target alias so it matches only the TOP-LEVEL arms; the
    # nested subqueries are aliased `R1`, `R2`, ….
    pairs = [(m.captures[1], m.captures[2]) for m in
             eachmatch(r"(?:WHERE|OR) \(\"Tb\"\.\"(\w+)\" IN \(SELECT\s+\"\w+\"\.\"(\w+)\"", sql)]

    # Two arms, one per foreign key.
    #
    # Both assertions are anchored deliberately. A bare `occursin("\"owner\" IN (", sql)` passed
    # against the pre-#452 code — the wrong-keyed statement still contained `"Tb"."owner" IN (` in
    # its inner nesting — so it would look like coverage while asserting nothing.
    @test length(pairs) == 2
    @test Set(first.(pairs)) == Set(["owner", "backup"])
    for (fk_col, projected_col) in pairs
      @test projected_col == "id"   # the FK is compared against the PARENT's key, never the other FK
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Multi-path cascade: the OR form, not an extra subquery level
# The #452-removed branch wrapped the same OR inside another `pk IN (SELECT pk FROM t WHERE …)`, and
# until #765 each arm was itself such a wrapper. Pinned because the flat OR of target predicates is
# what makes each arm read its own column AND what PostgreSQL re-checks under a row lock; a future
# "tidy-up" that reinstates a `pk IN (SELECT …)` wrapper reintroduces both defects at once.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a multi-path delete ORs its fragments rather than nesting them (#452 / #765)" begin
  step = _dmp_step(_dmp_steps(_dmp_plain_root, _DMP_SL), "dmp_b")
  sql = step[:sql_text]

  # Top-level shape: DELETE FROM <t> AS "Tb" WHERE ("Tb".<fk> IN (…)) OR ("Tb".<fk> IN (…))
  @test occursin(r"^DELETE FROM \"dmp_b\" AS \"Tb\" WHERE \(\"Tb\"\.\"\w+\" IN \(SELECT"s, sql)
  @test occursin(r"\)\s*OR \(\"Tb\"\.\"\w+\" IN \(SELECT"s, sql)

  # Depth: two arms, each `"Tb"."<fk>" IN (SELECT id FROM dmp_a …)` — ONE SELECT per arm, two in
  # total. The pre-#765 per-arm self-subquery made it four; the #452-removed wrapper, five.
  @test count("SELECT", sql) == 2
end

# ─────────────────────────────────────────────────────────────────────────────
# Single-path deletes are untouched (#452 control)
# The fix routes BOTH branches through the same fragment loop. If it disturbed the ordinary
# single-key case these would move — and the single-key case is every delete the suite already
# covers, so a regression there is far more expensive than the bug being fixed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "single-path deletes are unchanged (#452 control)" begin
  # Dmp_c has exactly one inbound CASCADE FK path when the delete starts at Dmp_b.
  build_q = () -> begin
    q = DMP.Dmp_b.objects
    q.filter("id" => 7)
    q
  end

  for (backend, conn, kind) in _DMP_BACKENDS
    steps = _dmp_steps(build_q, conn)
    # dmp_c, then the dmp_b root — after, on PostgreSQL, the #770 lock on dmp_b.
    @test [(s[:operation], s[:model]) for s in steps] ==
      vcat(kind === :postgres ? [(:lock, "dmp_b")] : Tuple{Symbol, String}[], [(:delete, "dmp_c"), (:delete, "dmp_b")])
    for step in steps
      assert_marker_count(step, kind)
    end

    root_step = _dmp_step(steps, "dmp_b")
    @test root_step[:parameters] == [7]
    # The user's own filter, on the target row (#765) — not `"id" IN (SELECT "Tb"."id" …)`.
    @test startswith(root_step[:sql_text], "DELETE FROM \"dmp_b\" AS \"Tb\" WHERE \"Tb\".\"id\" = ")
    # One fragment means no OR — the join is over a single element, as it always was.
    @test !occursin(" OR ", root_step[:sql_text])
  end
end
