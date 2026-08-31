"""
Unit coverage for the deletion collector's TRAVERSAL (#459), and for the two defects that mapping it
turned up.

Three separate failures, all in `process_collector!` / `find_related_objects!` / `handle_on_delete!`
and none of them visible from the statements a small fixture emits — which is why the fixtures here
are deliberately larger and deeper than `test_delete_multipath_alignment.jl`'s.

**1. The traversal walked a container it was inserting into.** `process_collector!` iterated
`collector.objects` while `find_related_objects!` -> `handle_on_delete!` ->
`add_objects_to_collector!` inserted new models into it. Julia neither raises nor snapshots on that,
so the loop reached entries it had just created and re-walked them with their COMPLETE key vector,
pushing a duplicate entry into every child, which then re-walked theirs.

Measured before the fix on this file's 14-link CASCADE chain, mock connections:

    dct_c01   entries = 1        dct_c14   entries = 14
    dct_c02   entries = 2        total     entries = 105   (14 are correct)

    dct_c14   fragments = 14   markers = 67   params = 67   (1 fragment, 1 value is correct)

A second run of the same fixture gave 87, not 105: the count is `Dict` hash order, which is the
complaint. It is NOT merely wasteful — the last statement of a 14-link chain binds 67 values and ORs
14 subqueries for a plan that needs one of each, and the blow-up compounds with depth.

Which direction the nondeterminism can hurt is worth stating, because it decides the fix. SKIPPING an
entry is harmless: every model in `collector.objects` beyond the root was put there by the recursion,
which descends into it at insertion time. RE-VISITING is the live defect. So the fix is to snapshot
the seed set — NOT the `visited::Set{PormGModel}` the issue proposed, which would refuse the second
descent into a legitimately multi-path model and leave that path's grandchildren uncollected.

**2. A multi-path `SET_NULL` / `SET_DEFAULT` kept only one path.** `collector.field_updates` ASSIGNED
where `collector.objects` appends, so a child of a multi-path parent had its first scoping query
overwritten by its second. Measured on `root -CASCADE(owner|backup)-> mid -SET_NULL-> leaf`: the
emitted UPDATE scoped through `"owner"` only, and which of the two survived was `related_objects`
Dict order. Rows reached by the other path kept a foreign key to `mid` rows the same delete then
removed. This is the `keys[1][:key]` defect #452 removed from `delete_objects`, reached by the
SET_NULL path instead.

**3. A cyclic cascade overflowed the stack.** Two models with `on_delete = CASCADE` each way made
`find_related_objects!` descend forever. Measured: `StackOverflowError` after ~5s, preceded by
Julia's own "detected a stack overflow; program state may be corrupted" — inside the delete
transaction, on a runtime the warning says is no longer trustworthy. It now raises `QueryBuildError`
naming the models it walked.

Mock pools skip the `_exists` probe (`should_check_related_existence`), so every fixture here
traverses its complete declared graph with no database and no pruning.
"""
# julia --project=. test/unit/test_delete_collector_traversal.jl

using Test
using PormG
using PormG.Models

include("helper_marker_alignment.jl")

struct DctMockSQLite <: PormG.PormGSQLite end
struct DctMockPostgres <: PormG.PormGPostgres end
const _DCT_SL = DctMockSQLite()
const _DCT_PG = DctMockPostgres()
PormG.backend_sqlite_version(::DctMockSQLite) = 3045000

PormG.config["dct_mock"] = PormG.Configuration.Settings(
  connections = _DCT_SL,
  change_data = true,
  db_def_folder = "dct_mock",
)

# A linear CASCADE chain, one foreign key per link. Generated rather than written out: 14 near
# identical model declarations would bury the only thing that matters about this fixture, which is
# its LENGTH. It has to be long enough that models inserted mid-traversal land in `Dict` slots the
# outer loop has not passed yet — measured, a 3-link chain is clean and a 5-link chain already
# collects 11 entries for 5 models. `let` keeps `prev` out of the module's bindings; `set_models`
# scans them, and a second name for the same model registers its reverse accessors twice.
module DctChain
import PormG
import PormG.Models

const CHAIN_N = 14

Dct_c01 = Models.Model("dct_c01", id = Models.IDField(), code = Models.CharField())
let prev = Dct_c01
  for i in 2:CHAIN_N
    tag = lpad(i, 2, '0')
    m = Models.Model("dct_c$(tag)",
      id     = Models.IDField(),
      parent = Models.ForeignKey(prev, on_delete = "CASCADE", related_name = "kids_$(tag)", null = true),
    )
    Core.eval(@__MODULE__, :($(Symbol("Dct_c$(tag)")) = $m))
    prev = m
  end
end

PormG.Models.set_models(@__MODULE__, "dct_mock")
end

# root -> mid by TWO cascade paths, then one SET_NULL child and one SET_DEFAULT child of that
# multi-path parent. `handle_on_delete!` reaches each leaf once per path to `mid`, with a different
# scoping query each time — the shape `collector.objects` has always handled by appending and
# `collector.field_updates` used to handle by overwriting.
module DctDiamond
import PormG
import PormG.Models

# Grandparent reachable only through a cjoin. `DO_NOTHING` has no branch in `handle_on_delete!`, so
# it contributes a parameterized JOIN to the root query WITHOUT adding a cascade path — the same
# trick `test_delete_multipath_alignment.jl`'s `Dmp_root` plays, and the only way to give the plan
# two DISTINCT sentinels.
Dct_top = Models.Model("dct_top", id = Models.IDField(), tag = Models.CharField())

Dct_root = Models.Model("dct_root",
  id   = Models.IDField(),
  code = Models.CharField(),
  top  = Models.ForeignKey(Dct_top, on_delete = "DO_NOTHING", related_name = "dct_roots", null = true),
)

Dct_mid = Models.Model("dct_mid",
  id     = Models.IDField(),
  owner  = Models.ForeignKey(Dct_root, on_delete = "CASCADE", related_name = "owned",   null = true),
  backup = Models.ForeignKey(Dct_root, on_delete = "CASCADE", related_name = "backups", null = true),
)

Dct_leaf = Models.Model("dct_leaf",
  id  = Models.IDField(),
  mid = Models.ForeignKey(Dct_mid, on_delete = "SET_NULL", related_name = "leaves", null = true),
)

Dct_dleaf = Models.Model("dct_dleaf",
  id  = Models.IDField(),
  mid = Models.ForeignKey(Dct_mid, on_delete = "SET_DEFAULT", related_name = "dleaves", null = true, default = 0),
)

PormG.Models.set_models(@__MODULE__, "dct_mock")
end

# A two-model foreign-key cycle, both sides CASCADE. `set_models` accepts it — there is no cycle
# check at registration, and `topological_sort`'s "Circular dependency detected" fires only AFTER the
# walk it never survives. The forward reference is by NAME because Julia cannot name `Dct_y` yet.
module DctCycle
import PormG
import PormG.Models

Dct_x = Models.Model("dct_x",
  id   = Models.IDField(),
  code = Models.CharField(),
  y    = Models.ForeignKey("Dct_y", on_delete = "CASCADE", related_name = "xs", null = true),
)

Dct_y = Models.Model("dct_y",
  id = Models.IDField(),
  x  = Models.ForeignKey(Dct_x, on_delete = "CASCADE", related_name = "ys", null = true),
)

PormG.Models.set_models(@__MODULE__, "dct_mock")
end

const _DCT_BACKENDS = (("PostgreSQL", _DCT_PG, :postgres), ("SQLite", _DCT_SL, :sqlite))

"""Every statement `delete()` emits for `q`, as a Vector of inspection Dicts."""
function _dct_steps(q, conn)
  res = q.delete(show_query = :dict, connection = conn)
  return res isa Vector ? res : [res]
end

"""The step whose `:model` is `name`. Fails loudly rather than returning `nothing`."""
function _dct_step(steps, name::String)
  idx = findfirst(s -> s[:model] == name, steps)
  @assert idx !== nothing "no step for $(name); got $([s[:model] for s in steps])"
  return steps[idx]
end

"""
Top-level `col IN (SELECT …)` fragments in `sql`, as the columns they address.

Anchored on `WHERE`/`OR` so nested subqueries do not count — the same structural form
`test_delete_multipath_alignment.jl` uses, because a bare `occursin` cannot tell one fragment from
fourteen.
"""
_dct_fragments(sql::AbstractString) =
  [m.captures[1] for m in eachmatch(r"(?:WHERE|OR)\s+\"(\w+)\" IN \(SELECT", sql)]

# ─────────────────────────────────────────────────────────────────────────────
# Deletion collector traversal: a long cascade chain collects each model exactly once
# One CASCADE foreign key per link means one cascade path per model, so every statement must carry
# exactly one `IN (SELECT …)` fragment and bind exactly one value. Before #459 the outer loop in
# `process_collector!` re-walked models the recursion had already descended into, and the chain's
# last statement rendered 14 fragments against 67 bound values.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a long cascade chain collects each model exactly once (#459)" begin
  for (label, conn, backend) in _DCT_BACKENDS
    @testset "$(label)" begin
      q = DctChain.Dct_c01.objects
      q.filter("code" => "DELME")
      steps = _dct_steps(q, conn)

      # One statement per link, no more and no fewer.
      @test length(steps) == DctChain.CHAIN_N
      @test Set(s[:model] for s in steps) ==
            Set("dct_c" * lpad(i, 2, '0') for i in 1:DctChain.CHAIN_N)

      for s in steps
        @test s[:operation] == :delete
        # THE assertion. Pre-fix this runs 1, 2, 3 … 14 across the chain.
        @test length(_dct_fragments(s[:sql_text])) == 1
        # One fragment scopes through one root filter, so exactly one value is bound.
        @test s[:parameters] == ["DELME"]
        assert_marker_count(s, backend)
      end

      # Stated as a total as well: the redundant arms bound ~380 values across the plan pre-fix, and
      # a per-statement assertion alone would let a regression hide in whichever statement happens to
      # be checked last.
      @test sum(length(s[:parameters]) for s in steps) == DctChain.CHAIN_N
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Deletion collector traversal: SET_NULL and SET_DEFAULT cover every path to a multi-path parent
# `dct_mid` is reachable from `dct_root` by two CASCADE foreign keys, so its SET_NULL and SET_DEFAULT
# children are each resolved twice, with a different scoping query each time. Both must survive into
# the emitted UPDATE as ORed fragments; `collector.field_updates` used to keep only the last one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a multi-path SET_NULL / SET_DEFAULT covers every cascade path (#459)" begin
  for (label, conn, backend) in _DCT_BACKENDS
    @testset "$(label)" begin
      q = DctDiamond.Dct_root.objects
      q.filter("code" => "DELME")
      steps = _dct_steps(q, conn)

      # Statement count is unchanged by the fix: one UPDATE per (field, value, model), plus the two
      # DELETEs. Fragments moved, statements did not.
      @test length(steps) == 4

      for name in ("dct_leaf", "dct_dleaf")
        step = _dct_step(steps, name)
        @test step[:operation] == :update
        # Two paths to `dct_mid` => two ORed fragments. Pre-fix: one.
        @test length(_dct_fragments(step[:sql_text])) == 2
        # Both fragments address the child's own primary key; what differs is which `dct_mid` column
        # each one traverses. Naming both is what makes a DROPPED path visible — a fragment count on
        # its own would pass if the same path were emitted twice.
        @test occursin("\"R1\".\"owner\" IN", step[:sql_text])
        @test occursin("\"R1\".\"backup\" IN", step[:sql_text])
        @test length(step[:parameters]) == 2
        assert_marker_count(step, backend)
      end

      # The SET clause still renders each field's own value, not a shared one.
      @test occursin("SET \"mid\" = NULL", _dct_step(steps, "dct_leaf")[:sql_text])
      @test occursin("SET \"mid\" = 0", _dct_step(steps, "dct_dleaf")[:sql_text])

      # Control: the parent's own DELETE was already multi-path before this fix (#452), and must be
      # unchanged by it.
      mid = _dct_step(steps, "dct_mid")
      @test mid[:operation] == :delete
      @test length(_dct_fragments(mid[:sql_text])) == 2
      assert_marker_count(mid, backend)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Deletion collector traversal: the multi-fragment UPDATE binds in text order on SQLite
# `update_field` is a NEW renderer as of #459, and the testset above cannot discriminate its value
# vector at all: with one root filter every fragment binds the same string, so any permutation reads
# as correct. A `cjoin` on the root gives the plan two DISTINCT sentinels, one rendered in a JOIN
# `ON` and one in a `WHERE`, so a lost or reordered value becomes visible.
#
# Be precise about what this does and does not pin, because the obvious label is wrong.
#
# It does NOT pin `update_field`'s #432 mark/detach wrap. MEASURED by removing those three lines and
# re-running: all nine assertions still pass. The `ON` value is already in the `:where` bucket before
# the wrap runs, lifted by the read builder's own `__@in` splice — the identical finding
# `test_delete_multipath_alignment.jl` records for `delete_objects`, and the reason `isempty(:join)`
# below is a shape pin rather than a regression guard. Keep the wrap anyway, for the reason that file
# gives: it makes alignment a property of the code instead of a property of today's fragment shapes.
#
# It DOES pin: that each fragment renders once into one collector (double-rendering — #452's actual
# defect, reached through this renderer — gives 8 values against 4 markers), that neither path is
# dropped (a drop gives 2), and that the cjoin's `ON` value survives into every fragment. A swap OF
# the two fragments stays invisible, since both carry the same root query.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a multi-path SET_NULL binds in text order on SQLite (#459 / #432)" begin
  # SQLite only: PostgreSQL's `$N` travels with the text by construction, which is why every bug in
  # this family has been SQLite-only.
  q = DctDiamond.Dct_root.objects
  q.filter("code" => "WHEREVAL")
  q.cjoin("top" => "Dct_top", filters = ["tag" => "ONVAL"], warn = false)
  steps = _dct_steps(q, _DCT_SL)

  for name in ("dct_leaf", "dct_dleaf")
    step = _dct_step(steps, name)
    @test length(_dct_fragments(step[:sql_text])) == 2
    # Two fragments, each lifting its own join-then-where run to its marker position.
    assert_bound_in_text_order(step, ["ONVAL", "WHEREVAL", "ONVAL", "WHEREVAL"])
    assert_marker_count(step, :sqlite)
    # Shape pin, not a regression guard — see the header. The cjoin's ON value reaches `:where`
    # through the read builder's `__@in` splice, so this passes with or without `update_field`'s
    # own wrap. Recorded so nobody reads it as proof the wrap works.
    @test isempty(step[:parameter_buckets][:join])
  end

  # The parent DELETE is the #452 renderer on the same root — unchanged, and the control that says
  # the two renderers agree.
  mid = _dct_step(steps, "dct_mid")
  assert_bound_in_text_order(mid, ["ONVAL", "WHEREVAL", "ONVAL", "WHEREVAL"])
end

# ─────────────────────────────────────────────────────────────────────────────
# Deletion collector traversal: a foreign-key cycle raises instead of overflowing the stack
# `dct_x` and `dct_y` reference each other with CASCADE both ways, which `set_models` accepts. The
# collector descended forever on it; the depth guard turns that into a QueryBuildError that rolls the
# delete back cleanly and names the models it walked.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a cyclic cascade raises rather than overflowing the stack (#459)" begin
  q = DctCycle.Dct_x.objects
  q.filter("code" => "DELME")

  err = try
    q.delete(show_query = :dict, connection = _DCT_SL)
    nothing
  catch e
    e
  end

  @test err isa QueryBuildError
  # The message has to be actionable: which models, and what to do about them. Escapes are stripped
  # because `_emsg` keeps them when the session has color, which is how error-text assertions pass
  # locally and fail on CI.
  msg = replace(error_message(err), r"\e\[[0-9;]*m" => "")
  @test occursin("cascade exceeded", msg)
  @test occursin("dct_x", msg)
  @test occursin("dct_y", msg)
  @test occursin("on_delete", msg)
end
