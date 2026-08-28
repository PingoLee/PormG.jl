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
delete, and it is now unrepresentable: each fragment carries its own key.

**What the `cjoin` shape does and does NOT cover.** It gives the plan two DISTINCT sentinels, one
rendered in a JOIN `ON` and one in a `WHERE`, so the assertions here are about text order rather
than about a single repeated string — the plain-root reproduction binds `"DELME"` four times, where
any permutation reads as correct. Keep it for that.

It does **not** discriminate #432's mark/detach wrap in `delete_objects`, and this file must not
imply otherwise. Measured: strip the wrap and every plan below renders identical SQL and an
identical flattened value vector. The only difference is in `:parameter_buckets` on the `dmp_a`
statement, where the root's `ON` value sits in `:join` unwrapped and in `:where` wrapped.

The reason is NOT that nothing binds at a fragment's own top-level `:join` — `dmp_a` does, and an
earlier draft of this paragraph claimed otherwise. It is that no statement ever gets TWO
join-binding fragments. Cascade fragments are built as
`child.objects.filter("<fk>__@in" => parent).values(<key>)` and carry no join; the root queryset
can carry one but is always alone in its statement, and a lone fragment's `:join`-before-`:where`
flatten already matches its text order. The wrap is insurance against a future fragment shape, not
something these testsets prove.

Both backends run. PostgreSQL's `\$N` travels with the text by construction, which is why every bug
in this family has been SQLite-only — but the COUNT half fails on both, and did here.
"""
# julia --project=. test/unit/test_delete_multipath_alignment.jl

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
  idx = findfirst(s -> s[:model] == name, steps)
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
        @test length(steps) == 4
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
  root_step = _dmp_step(steps, "dmp_a")
  assert_marker_count(root_step, :sqlite)
  assert_bound_in_text_order(root_step, ["ONVAL", "WHEREVAL"])
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

    # For every top-level `<col> IN (SELECT <alias>.<col2>`, the outer column and the projected
    # column must be the same. This is what fails on the old code: measured, it produced exactly ONE
    # top-level arm — `"owner" IN (SELECT "Tb"."owner" …)` — wrapping a nested OR whose second arm
    # was `"Tb"."owner" IN (SELECT "R3"."backup" …)`. The mismatch lives at that INNER level; what
    # this assertion detects is the arm COUNT collapsing from two to one, which is the same defect
    # seen from outside.
    #
    # Anchored on `WHERE`/`OR` so it matches only the TOP-LEVEL fragments. Each fragment nests its
    # own `"Tb"."<fk>" IN (SELECT "R1"."id" …)`, where the columns differ legitimately — that is the
    # cascade FK pointing at the parent's primary key, not the arm's addressing column. A pattern
    # without the anchor matches those too and reads their correct asymmetry as the bug.
    pairs = [(m.captures[1], m.captures[2]) for m in
             eachmatch(r"(?:WHERE|OR) \"(\w+)\" IN \(SELECT\s+\"\w+\"\.\"(\w+)\"", sql)]

    # Two arms, one per foreign key, each addressed by ITS OWN key.
    #
    # Both assertions are anchored deliberately. A bare `occursin("\"owner\" IN (", sql)` passes
    # against the OLD code — the wrong-keyed statement still contains `"Tb"."owner" IN (` in its
    # inner nesting — so it would have looked like coverage while asserting nothing. Measured: the
    # unfixed render satisfies it.
    @test length(pairs) == 2
    @test Set(first.(pairs)) == Set(["owner", "backup"])
    for (outer_col, projected_col) in pairs
      @test outer_col == projected_col
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Multi-path cascade: the OR form, not an extra subquery level
# The removed branch wrapped the same OR inside another `pk IN (SELECT pk FROM t WHERE …)`. The
# fragments express it directly, so the statement is one level SHALLOWER. Pinned because the OR form
# is what makes each arm carry its own key, and a future "tidy-up" that reinstates the wrapper would
# reintroduce the shared-key assumption with it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a multi-path delete ORs its fragments rather than nesting them (#452)" begin
  step = _dmp_step(_dmp_steps(_dmp_plain_root, _DMP_SL), "dmp_b")
  sql = step[:sql_text]

  # Top-level shape: DELETE FROM <t> WHERE <col> IN (…) OR <col> IN (…)
  @test occursin(r"^DELETE FROM \"dmp_b\" WHERE \"id\" IN \(SELECT"s, sql)
  @test occursin(r"\)\s*OR \"id\" IN \(SELECT"s, sql)

  # Depth: two fragments, each `SELECT id FROM dmp_b WHERE fk IN (SELECT id FROM dmp_a …)` — two
  # SELECTs per arm, four in total. The wrapper the old branch added made it five.
  @test count("SELECT", sql) == 4
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
    @test length(steps) == 2                      # dmp_c, then the dmp_b root
    for step in steps
      assert_marker_count(step, kind)
    end

    root_step = _dmp_step(steps, "dmp_b")
    @test root_step[:parameters] == [7]
    @test occursin("DELETE FROM \"dmp_b\" WHERE \"id\" IN (SELECT", root_step[:sql_text])
    # One fragment means no OR — the join is over a single element, as it always was.
    @test !occursin(" OR ", root_step[:sql_text])
  end
end
