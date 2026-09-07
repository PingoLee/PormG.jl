# =============================================================================
# The relation-alias namespace (#474)
# =============================================================================
#
# #444 gave a CTE's COLUMNS their own namespace, and its load-bearing test is a coexistence proof:
# "both references in ONE query, both resolving … the thing a construction-time collision guard
# could never provide". #474 finishes that split on the two keyspaces #444 did not reach, and this
# file is the same kind of proof one level up.
#
#   1. `custom_join` / `row_path` — `_build_row_join` set `join_path = field[1]`, which for a
#      `CTE("b2", "sku")` reference IS the CTE name, and then looked that name up in the BASE
#      model's join-config registry and claimed it in `row_path`. A `.with()` label equal to a
#      `cjoin` path, a `cjoin_on` alias or an `on()` path therefore handed the CTE's join that
#      entry's join_type and predicates, and suppressed the user's own join. #447 GUARDED that;
#      #474 makes it unrepresentable, so the guard, its twelve-shape table and its accepted false
#      positive are all gone.
#
#   2. `instruct.cache` / `tab_field_cache` — keyed by `SQLField._as`, and #444 fixed a CTE
#      reference's `_as` at `"<cte>__<path>"` deliberately, byte-for-byte, so result columns kept
#      working. That is exactly the spelling a field path produces. This half was reachable with NO
#      `custom_join` anywhere, so #447's guard never saw it: on `origin/main`,
#      `.with("parent" => cte)` plus `filter("parent__sku" => "S")` filtered the CTE's column and
#      left the ForeignKey's join unused in the statement. The memos are now keyed by `MemoKey`
#      (`(root, name)`, where `root` is `:base` / `:cte` / `:joined`) and `SQLField.root` carries the
#      namespace half, so the two cannot share an entry while `_as` keeps the output spelling #444
#      pinned.
#
# Everything renders through mock connections — no live database.
#
# Sibling coverage:
#   - `test_cte_reference.jl`   → the #444 handle itself, and #431's field/CTE coexistence.
#   - `test_order_by_joins.jl`  → #424's control, #435/#448/#449. Its #424 producer table was
#                                 removed here: all three producers now render, and this file is
#                                 where they are pinned.
#   - `test_cte_ergonomics.jl`  → #44 CROSS-joined CTE correlation.

using Test
using PormG
using PormG.Models

# Dedicated config key + mock types: `runtests.jl` includes ~50 files into one `Main`, so a shared
# key would let another file's settings decide this file's dialect.
struct RanMockSQLite <: PormG.PormGSQLite end
struct RanMockPostgres <: PormG.PormGPostgres end
const _RAN_SL = RanMockSQLite()
const _RAN_PG = RanMockPostgres()
PormG.backend_sqlite_version(::RanMockSQLite) = 3045000

PormG.config["ran_mock"] = PormG.Configuration.Settings(
  connections = _RAN_SL, change_data = true, db_def_folder = "ran_mock",
)

# `set_models` is REQUIRED, not stylistic: `_build_row_join` reads
# `instruct.object.model._module::Module`, and a bare `Model(...)` leaves `_module === nothing`.
module RanModels
import PormG
import PormG.Models

Ran_grand = Models.Model("ran_grand",
  id   = Models.IDField(),
  code = Models.CharField(),
  # A JSON column so a CTE projection and a ForeignKey path can both produce `"<name>__payload"`.
  # `tab_field_cache` is what tells the JSONB operators their target is JSON, and it is one of the
  # caches #474 namespaces — a reader left on the old key fails closed on the first shape below and
  # licenses a jsonb operator against the wrong column on the second.
  payload = Models.JSONField(null = true),
)

Ran_parent = Models.Model("ran_parent",
  id  = Models.IDField(),
  # `db_column` on purpose: it is what tells a CTE column (`"sku"`, a projection alias) apart from
  # the ForeignKey path's physical column (`"product_sku"`) in a rendered assertion. Without it both
  # sides spell the same thing and the cache-namespace tests below would pass on the wrong branch.
  sku = Models.CharField(db_column = "product_sku"),
)

Ran_child = Models.Model("ran_child",
  id     = Models.IDField(),
  # NULLABLE — `_determine_join_type` answers "LEFT".
  parent = Models.ForeignKey(Ran_parent, on_delete = "CASCADE", related_name = "ran_kids", null = true),
  # NOT NULL — `_determine_join_type` answers "INNER". This is the pair that makes `on()`'s former
  # silent "LEFT" default visible as a row-count change rather than a cosmetic one.
  owner  = Models.ForeignKey(Ran_parent, on_delete = "CASCADE", related_name = "ran_owned", null = false),
  note   = Models.CharField(null = true),
  grand  = Models.ForeignKey(Ran_grand, on_delete = "CASCADE", related_name = "ran_gkids", null = true),
)

PormG.Models.set_models(@__MODULE__, "ran_mock")
end

const RAN = RanModels
import PormG.QueryBuilder: F, inspect_query, Joined
using PormG: CTE

_ran_sql(q; conn = _RAN_SL) = inspect_query(q; connection = conn)[:sql_text]
_ran_no_ansi(s::AbstractString) = replace(s, r"\e\[[0-9;]*m" => "")
# Every `_grand()` / `_parent_cte()` call builds a FRESH handler: `.with(...)` deepcopies its query,
# but reusing one across shapes would still share the builder state a previous render mutated.
_ran_grand()  = begin c = RAN.Ran_grand.objects;  c.values("id", "code"); c end
_ran_json()   = begin c = RAN.Ran_grand.objects;  c.values("id", "payload"); c end
# A CTE whose `payload` column is a CharField — `code` projected under that alias. It is what makes
# the mirror case below discriminate between the two namespaces rather than merely exercise them.
_ran_char_payload() = begin c = RAN.Ran_grand.objects; c.values("id", "payload" => "code"); c end
_ran_parent() = begin c = RAN.Ran_parent.objects; c.values("id", "sku");  c end

# ─────────────────────────────────────────────────────────────────────────────
# Relation-alias namespace: a CTE name may equal a join key, and both are emitted
# The four shapes below are the exact producers #447 and #424 refused. Each must now render BOTH
# relations — the CTE under its own generated alias, the user's join under its own — with the CTE
# keeping the join_type it declared and the user's join keeping its own predicates. That last part
# is what a refusal could never demonstrate, and it is the whole reason this is a coexistence proof
# rather than a re-worded guard.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a CTE name and a join key may coexist (#474)" begin
  for (backend, conn) in (("PostgreSQL", _RAN_PG), ("SQLite", _RAN_SL))
    @testset "$backend" begin

      # ── a cjoin_on ALIAS equal to a KEYED CTE's name — #447 as filed ──────
      # Pre-#474 this raised "The join key b2 collides with the name of a CTE joined by this query".
      # The CTE is joined as `"b2" AS "R1_1"` (its alias is GENERATED) while the cjoin_on introduces
      # the range variable `b2` itself, so only one relation in the statement is named `b2` and the
      # two never actually competed in SQL — the collision was entirely internal.
      q1 = RAN.Ran_child.objects
      q1.with("b2" => _ran_grand(), join_field = "parent" => "id", join_type = "INNER")
      q1.cjoin_on("Ran_parent", alias = "b2", on = [Joined("b2", "sku") == F("note")])
      q1.values("note", "cte_code" => CTE("b2", "code"))
      sql1 = _ran_sql(q1; conn = conn)

      # The CTE's join, under the join_type IT declared. Pre-fix this line was the failure: the
      # colliding entry's type won, so a declared INNER silently became the other entry's LEFT.
      @test occursin("INNER JOIN \"b2\" AS \"R1_1\" ON \"R1\".\"parent\" = \"R1_1\".\"id\"", sql1)
      # The cjoin_on's own join, with its own ON clause. Pre-fix it lost its table entirely.
      @test occursin("JOIN \"ran_parent\" AS \"b2\" ON (\"b2\".\"product_sku\" = \"R1\".\"note\")", sql1)
      # Two relations, two aliases, no third join invented from the collision.
      @test count("JOIN", sql1) == 2

      # ── a cjoin PATH equal to a KEYED CTE's name ──────────────────────────
      # `parent` is a ForeignKey of Ran_child AND the CTE's label. #431 already made those two
      # coexist as FIELD PATHS; this is the same coexistence for the JOIN KEY.
      q2 = RAN.Ran_child.objects
      q2.with("parent" => _ran_grand(), join_field = "parent" => "id", join_type = "INNER")
      q2.cjoin("parent" => "Ran_parent", filters = ["sku" => "S"], warn = false)
      q2.values("note", "cte_code" => CTE("parent", "code"))
      sql2 = _ran_sql(q2; conn = conn)

      @test occursin("INNER JOIN \"parent\" AS \"R1_1\" ON \"R1\".\"parent\" = \"R1_1\".\"id\"", sql2)
      # The cjoin's predicate resolves against the cjoin's OWN alias and physical column. Rendering
      # it against the CTE (`"R1_1"."code"`) is the shape this file's second half is about, and it
      # is asserted negatively here as well because both halves meet in exactly this query.
      @test occursin("JOIN \"ran_parent\" AS \"R1_2\" ON \"R1\".\"parent\" = \"R1_2\".\"id\" AND \"R1_2\".\"product_sku\" = ", sql2)
      @test count("JOIN", sql2) == 2

      # ── a cjoin PATH with NO filters, against an UNKEYED CTE ──────────────
      # #447's accepted false positive: a degenerate no-op cjoin was refused although nothing would
      # have broken. It is not "accepted" any more — it renders, and the CROSS-joined CTE and the
      # cjoin's own LEFT JOIN are both present.
      q3 = RAN.Ran_child.objects
      q3.with("parent" => _ran_grand())
      q3.cjoin("parent" => "Ran_parent", warn = false)
      q3.values("note", "cte_code" => CTE("parent", "code"))
      sql3 = _ran_sql(q3; conn = conn)

      @test occursin("CROSS JOIN \"parent\" AS \"R1_1\"", sql3)
      @test occursin("LEFT JOIN \"ran_parent\" AS \"R1_2\" ON \"R1\".\"parent\" = \"R1_2\".\"id\"", sql3)
      # A CROSS entry has no ON clause to carry anything — the #424 invariant, restated positively.
      @test !occursin(r"CROSS JOIN[^\n]*ON", sql3)

      # ── an on() PATH equal to a KEYED CTE's name ──────────────────────────
      # `on()` decorates a join something else materializes, so here it decorates the ForeignKey's
      # join — NOT the CTE's. Pre-fix the CTE inherited `on()`'s join_type and its predicate was
      # rewritten onto a second, mis-correlated join with the value bound twice.
      #
      # #492: the CTE is `pcte` here, not `parent`. Reaching the ForeignKey needs the string path
      # `"parent__sku"`, and a CTE that shadows the FK's name now makes that path a hard error — so
      # the two could not appear in one query. What this case is about (on() decorates the FK's
      # join, the CTE keeps its own join_type) is unchanged by the rename; the shadowed spelling is
      # covered by its own refusal case below.
      q4 = RAN.Ran_child.objects
      q4.with("pcte" => _ran_grand(), join_field = "parent" => "id", join_type = "INNER")
      q4.on("parent", "sku" => "S")
      q4.values("note", "parent__sku", "cte_code" => CTE("pcte", "code"))
      insp4 = inspect_query(q4; connection = conn)
      sql4 = insp4[:sql_text]

      @test occursin("INNER JOIN \"pcte\" AS", sql4)                         # the CTE keeps INNER
      @test occursin("\"product_sku\" = ", sql4)                             # on()'s predicate landed
      @test count("JOIN", sql4) == 2                                          # no phantom third join
      # The value is bound ONCE. Pre-fix the rewritten predicate materialized a second join and the
      # parameter appeared twice — the silent-wrong-rows half of #447, invisible in a shape check.
      @test count(x -> x == "S", insp4[:parameters]) == 1
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Memo namespace: a CTE reference and a field path spelled alike keep separate entries
# `instruct.cache` and `tab_field_cache` are keyed by `_as`, and a CTE handle's `_as` is
# `"<cte>__<path>"` — identical to the field path `"<fk>__<col>"`. Whichever expression rendered
# first claimed the entry, and every later reader got it. Reachable with no `custom_join` at all,
# which is why #447's guard never covered it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a handle and a like-named field path keep separate memo entries (#474/#481)" begin
  for (backend, conn) in (("PostgreSQL", _RAN_PG), ("SQLite", _RAN_SL))
    @testset "$backend" begin

      # The control first, so the expected column name is established by something that cannot be
      # affected by a handle: with no CTE and no alias in the query, `parent__sku` is the
      # ForeignKey's physical `product_sku`.
      ctrl = RAN.Ran_child.objects
      ctrl.values("note", "parent__sku")
      ctrl.filter("parent__sku" => "S")
      ctrl_sql = _ran_sql(ctrl; conn = conn)
      @test occursin("\"product_sku\" = ", ctrl_sql)
      @test !occursin("\"sku\" = ", ctrl_sql)

      # ── the shape the memo namespace exists for, in the `:joined` half ────
      #
      # #492 moved this proof one namespace over, and the reason is worth stating: the original was
      # `CTE("parent","sku")` projected alongside a `"parent__sku"` FILTER, both spelling
      # `"parent__sku"` as their memo name. That query is now REFUSED (a CTE may not shadow a model
      # field for the string spelling), so the `:cte`-vs-`:base` collision is unrepresentable and
      # cannot be tested — the refusal case below is what replaces it.
      #
      # A `cjoin_on` ALIAS is different: #484 gave it its own namespace reachable only through
      # `Joined(alias, path)`, so a `__` string can never mean an alias and there is nothing for
      # #492 to refuse. The collision therefore stays live here, and it is the SAME defect — two
      # expressions whose `_as` is byte-identical, discriminated only by the namespace half of the
      # `MemoKey`. Whichever rendered first used to claim the entry for both.
      q = RAN.Ran_child.objects
      q.cjoin_on("Ran_parent", alias = "parent", on = [Joined("parent", "id") == F("parent")])
      q.values("note", "j" => Joined("parent", "sku"))
      q.filter("parent__sku" => "S")
      sql = _ran_sql(q; conn = conn)

      # The FILTER must name the ForeignKey's own join, exactly as the control does...
      @test occursin("\"product_sku\" = ", sql)
      # ...and the PROJECTION must come from the aliased copy `parent`. Asserting only the first
      # half would pass for a fix that simply stopped the alias from caching at all.
      @test occursin("\"parent\".\"product_sku\" as \"j\"", sql)
      @test occursin("JOIN \"ran_parent\" AS \"parent\"", sql)   # the aliased copy
      @test count("JOIN", sql) == 2                                  # and the ForeignKey's own

      # ── the mirror: field path first, handle after ────────────────────────
      # Pinned so the fix cannot be "swap which one wins", which moves the bug rather than removes it.
      q2 = RAN.Ran_child.objects
      q2.cjoin_on("Ran_parent", alias = "parent", on = [Joined("parent", "id") == F("parent")])
      q2.values("note", "parent__sku")
      q2.filter(Joined("parent", "sku") => "S")
      sql2 = _ran_sql(q2; conn = conn)
      @test occursin("\"product_sku\" as \"parent__sku\"", sql2)   # projection = the ForeignKey
      @test occursin("\"parent\".\"product_sku\" = ", sql2)        # filter = the aliased copy
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #492: the `:cte`-vs-`:base` collision this file was written for is now REFUSED, not resolved
# The memo namespace still exists and is still load-bearing — `test_joined_reference.jl` proves the
# `:cte`/`:joined` half with two handles, and the testset above proves `:joined`/`:base`. What
# changed is that a CTE may no longer shadow a MODEL name for the string spelling, so the original
# reproduction is unrepresentable rather than merely fixed. Pinning the refusal keeps the shape
# under test instead of letting it vanish from the file that owns it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#492: a CTE shadowing a ForeignKey refuses the shared string path" begin
  for (backend, conn) in (("PostgreSQL", _RAN_PG), ("SQLite", _RAN_SL))
    err = try
      q = RAN.Ran_child.objects
      q.with("parent" => _ran_parent(), join_field = "parent" => "id")
      q.values("note", "c" => CTE("parent", "sku"))
      q.filter("parent__sku" => "S")
      _ran_sql(q; conn = conn)
      nothing
    catch e; e end
    @test err isa PormG.AmbiguousFieldError
    msg = _ran_no_ansi(err.msg)
    @test occursin("CTE(\"parent\", \"sku\")", msg)
    @test occursin("#492", msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# join_type validation: "CROSS" is refused, and .with()'s join_type is validated at all
# Every consumer of `_normalize_join_type` feeds `row_join["how"]`, and Phase 2 emits
# `"<how> JOIN <table> AS <alias> ON <clause>"` unconditionally — so an accepted "CROSS" could only
# ever build `CROSS JOIN … ON …`, which both engines reject. `.with()`'s join_type reached that slot
# with NO validation on any part of its path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "join_type is validated on every writer, and CROSS is refused (#474)" begin

  # The four accepted spellings, and the normalization `_normalize_join_type` has always done but
  # which nothing asserted: it had zero direct tests before #474.
  @testset "accepted spellings and normalization" begin
    for (given, expected) in (("INNER", "INNER"), ("left", "LEFT"), ("  Right  ", "RIGHT"), ("full", "FULL"))
      q = RAN.Ran_child.objects
      q.on("owner", "sku" => "S", join_type = given)
      @test q.object.custom_join["owner"].join_type == expected
      q.values("note", "owner__sku")
      @test occursin("$(expected) JOIN \"ran_parent\"", _ran_sql(q))
    end
  end

  # ── "CROSS" refused at each of the three writers ──────────────────────────
  # One removal from `valid_joins` covers all of them, which is the point of fixing it there rather
  # than on the `cjoin_on` path the issue named: `on()` and `.with()` reached the same invalid SQL.
  @testset "CROSS is refused wherever a join_type is accepted" begin
    producers = [
      ("cjoin_on", () -> begin
        q = RAN.Ran_child.objects
        q.cjoin_on("Ran_parent", alias = "b2", on = [Joined("b2", "sku") == F("note")], join_type = "CROSS")
        q.values("note"); q
      end),
      ("on()", () -> begin
        q = RAN.Ran_child.objects
        q.on("parent", "sku" => "S", join_type = "CROSS")
        q.values("note", "parent__sku"); q
      end),
      ("with()", () -> begin
        q = RAN.Ran_child.objects
        q.with("gg" => _ran_grand(), join_field = "parent" => "id", join_type = "CROSS")
        q.values("note", "c" => CTE("gg", "code")); q
      end),
    ]
    for (label, build) in producers
      @testset "$label" begin
        err = try
          inspect_query(build(); connection = _RAN_SL); nothing
        catch e
          e
        end
        @test err isa PormG.QueryBuildError
        msg = _ran_no_ansi(sprint(showerror, err))
        @test occursin("Invalid join type", msg)
        # Names the supported cross product, and names the REFERENCE — since #444 a `.with(...)`
        # on its own emits no join at all, so pointing only at the declaration would produce N rows
        # instead of N×M. #448's message made exactly that mistake before it was measured.
        @test occursin("CTE(", msg)
        @test occursin("CROSS JOIN", msg)
      end
    end
  end

  # ── .with()'s join_type was interpolated into SQL unvalidated ─────────────
  # `_preset_cte_fields` stored the string verbatim, `_build_row_join` copied it into
  # `row_join["how"]`, and Phase 2 interpolated it. Measured on origin/main, this rendered
  # `LEFT OUTER JOIN ran_grand AS injected ON 1=1 -- JOIN "gg" AS "R1_1" ON …` — the caller's text
  # placed ahead of the CTE's own JOIN, unquoted.
  @testset "an arbitrary .with(join_type=) string cannot reach the SQL" begin
    q = RAN.Ran_child.objects
    err = try
      q.with("gg" => _ran_grand(), join_field = "parent" => "id",
             join_type = "LEFT OUTER JOIN ran_grand AS injected ON 1=1 --")
      nothing
    catch e
      e
    end
    # Refused at DECLARATION, next to `_with`'s two identifier checks — not at render, so the error
    # names the call the user wrote.
    @test err isa PormG.QueryBuildError
    @test occursin("Invalid join type", _ran_no_ansi(sprint(showerror, err)))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# on() adds predicates without changing the join type
# `on()` used to write `join_type = "LEFT"` whenever the caller named none, and
# `_get_join_type_override` reads that key as an OVERRIDE — so adding a predicate to a NOT NULL
# ForeignKey's join silently turned its INNER into a LEFT. Different rows, no error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "on() does not invent a join_type (#474)" begin

  # The oracle is neither the test nor `on()`: `_determine_join_type` types a relation from
  # `field.how`, else `field.null ? "LEFT" : "INNER"`. So the same path WITHOUT `on()` is the
  # correct answer, and the two must agree.
  @testset "a NOT NULL ForeignKey keeps INNER" begin
    base = RAN.Ran_child.objects
    base.values("note", "owner__sku")
    @test occursin("INNER JOIN \"ran_parent\"", _ran_sql(base))

    q = RAN.Ran_child.objects
    q.on("owner", "sku" => "S")
    q.values("note", "owner__sku")
    sql = _ran_sql(q)
    @test occursin("INNER JOIN \"ran_parent\"", sql)     # pre-fix: LEFT JOIN
    @test occursin("\"product_sku\" = ", sql)            # ...and the predicate still lands
    # The override is `nothing`, not a computed value: deciding the type HERE would have to
    # reproduce `_determine_join_type`'s `previus_how` LEFT-propagation for deep paths, which this
    # call site cannot see. Not overriding is what leaves that knowledge where it lives.
    # (#484 typed the entry: what was an absent `"join_type"` key is now a `nothing` field.)
    @test q.object.custom_join["owner"].join_type === nothing
  end

  @testset "a nullable ForeignKey keeps LEFT" begin
    q = RAN.Ran_child.objects
    q.on("parent", "sku" => "S")
    q.values("note", "parent__sku")
    @test occursin("LEFT JOIN \"ran_parent\"", _ran_sql(q))
  end

  @testset "an explicit join_type still wins" begin
    q = RAN.Ran_child.objects
    q.on("owner", "sku" => "S", join_type = "LEFT")
    q.values("note", "owner__sku")
    @test occursin("LEFT JOIN \"ran_parent\"", _ran_sql(q))
    @test q.object.custom_join["owner"].join_type == "LEFT"
  end

  @testset "a later on() inherits the first call's explicit join_type" begin
    q = RAN.Ran_child.objects
    q.on("owner", "sku" => "S", join_type = "LEFT")
    q.on("owner", "id__@gt" => 3)          # no join_type: must not reset it to anything
    q.values("note", "owner__sku")
    sql = _ran_sql(q)
    @test occursin("LEFT JOIN \"ran_parent\"", sql)
    @test q.object.custom_join["owner"].join_type == "LEFT"
    @test length(q.object.custom_join["owner"].filters) == 2
  end

  # `on()` still needs SOMETHING to do. Unchanged by #474, pinned here because the refusal now
  # carries the whole weight of "a join_type-only call is legal": with the default gone, an
  # argument-less `on()` has no other observable effect.
  @testset "on() with neither predicates nor a join_type is still refused" begin
    q = RAN.Ran_child.objects
    err = try
      q.on("owner")
      nothing
    catch e
      e
    end
    @test err isa PormG.QueryBuildError
    @test occursin("at least one ON predicate", _ran_no_ansi(sprint(showerror, err)))
  end

  # A join_type-only `on()` is the other half of that refusal: no predicates, but an override.
  @testset "a join_type-only on() overrides without adding predicates" begin
    q = RAN.Ran_child.objects
    q.on("parent", join_type = "INNER")
    q.values("note", "parent__sku")
    @test occursin("INNER JOIN \"ran_parent\"", _ran_sql(q))
    @test isempty(q.object.custom_join["parent"].filters)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Every cache reader agrees with the writer
# The namespace split is only worth anything if writers and readers use the SAME key. A reader left
# on `_as` is not a loud failure: it misses an entry the writer just made (fail-closed), or — worse —
# hits the OTHER namespace's entry and reads a field belonging to a different column. Both were live
# in `_resolve_json_operator_field`, which is the one `tab_field_cache` reader that decides whether
# a JSONB operator's target is a JSON column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a JSONB operator resolves its target through the namespaced memo (#474)" begin
  # PostgreSQL only: the `@has_key` family is PG-only by design and SQLite raises for it.

  # Control first — the same operator over a plain ForeignKey JSON path, which fixes the shape the
  # CTE case must match.
  ctrl = RAN.Ran_child.objects
  ctrl.values("note")
  ctrl.filter("grand__payload__@has_key" => "driver")
  @test occursin("\"payload\" ? ", _ran_sql(ctrl; conn = _RAN_PG))

  # The regression: the CTE's terminal field is cached under the namespaced key, so a reader still
  # keyed by `_as` could not find it and refused a shape that renders.
  q = RAN.Ran_child.objects
  q.with("gj" => _ran_json(), join_field = "grand" => "id", join_type = "INNER")
  q.values("note")
  q.filter(CTE("gj", "payload__@has_key") => "driver")
  sql = _ran_sql(q; conn = _RAN_PG)
  @test occursin("INNER JOIN \"gj\" AS", sql)
  @test occursin("\"payload\" ? ", sql)

  # ...and the mirror, which is the one that would have been SILENT. It needed TWO things, and #492
  # removed the first:
  #
  #   1. the CTE named `grand`, the SAME as the ForeignKey field, so both namespaces produce the
  #      memo name `"grand__payload"`. That combination is now a hard error the moment a `__` string
  #      names the shadowed path, so the ORDERING half — FK path claims the memo, CTE reads it back
  #      — is unrepresentable and is asserted as a refusal below rather than as a render;
  #   2. the CTE's `payload` being a DIFFERENT TYPE from the ForeignKey target's —
  #      `_ran_char_payload()` projects the CharField `code` under that alias, while
  #      `Ran_grand.payload` is the JSONField. That half survives, and it is what still proves the
  #      operator is validated against the column the CALLER named rather than a same-named one.
  #
  # Measured on `origin/main` with BOTH in place — that is, on the shape `q3` below now builds, not
  # on `q2`: it rendered `WHERE "R1_1"."payload" ? $1` against the FOREIGN KEY's join, while the CTE
  # named `grand` was declared and never joined — the `?` JSONB operator licensed by the other
  # namespace's field. `q2` keeps only half of it and is now a #474 guard (the operator validated
  # against the CTE's own text column); `q3` carries the ordering half, as a refusal.
  q2 = RAN.Ran_child.objects
  q2.with("grand" => _ran_char_payload(), join_field = "grand" => "id", join_type = "INNER")
  err = try
    q2.filter(CTE("grand", "payload__@has_key") => "driver")
    _ran_sql(q2; conn = _RAN_PG)
    nothing
  catch e
    e
  end
  # Refused, because the CTE's OWN `payload` is text — the operator is validated against the column
  # the caller named. Note the CTE still SHADOWS a ForeignKey here: that is legal on its own, and
  # only becomes an error when a `__` string tries to select the shadowed path.
  @test err isa PormG.FilterError
  @test occursin("is not JSON", _ran_no_ansi(sprint(showerror, err)))

  # The ordering half, as far as it can now be taken: adding the FK's string path to the SAME query
  # is what #492 refuses, and the refusal must arrive before any JSON validation can misfire.
  q3 = RAN.Ran_child.objects
  q3.with("grand" => _ran_char_payload(), join_field = "grand" => "id", join_type = "INNER")
  q3.values("note", "fk" => "grand__payload")
  err3 = try
    q3.filter(CTE("grand", "payload__@has_key") => "driver")
    _ran_sql(q3; conn = _RAN_PG)
    nothing
  catch e
    e
  end
  @test err3 isa PormG.AmbiguousFieldError
  @test occursin("#492", _ran_no_ansi(err3.msg))
end

# ─────────────────────────────────────────────────────────────────────────────
# join_type on an UNKEYED CTE: "CROSS" is the truth, not an error
# `join_type` is read only by the keyed arm of `_build_row_join`; an unkeyed CTE is CROSS-joined by
# construction. Refusing "CROSS" there would answer the caller with an error recommending the exact
# call they just wrote. Everything else is still validated on both arms.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unkeyed CTE accepts join_type = \"CROSS\" and still refuses nonsense (#474)" begin
  q = RAN.Ran_child.objects
  q.with("nn" => _ran_grand(), join_type = "CROSS")     # no join_field
  q.values("note", "c" => CTE("nn", "code"))
  sql = _ran_sql(q)
  @test occursin("CROSS JOIN \"nn\" AS", sql)
  @test !occursin(r"CROSS JOIN[^\n]*ON", sql)

  # A KEYED CTE still refuses it — that one really would render `CROSS JOIN ... ON ...`.
  err = try
    RAN.Ran_child.objects.with("kk" => _ran_grand(), join_field = "grand" => "id", join_type = "CROSS")
    nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError

  # And an unkeyed CTE does NOT become a hole for arbitrary text.
  err2 = try
    RAN.Ran_child.objects.with("nn2" => _ran_grand(), join_type = "LEFT JOIN evil ON 1=1 --")
    nothing
  catch e
    e
  end
  @test err2 isa PormG.QueryBuildError
  @test occursin("Invalid join type", _ran_no_ansi(sprint(showerror, err2)))
end

# ─────────────────────────────────────────────────────────────────────────────
# The memo namespace is internal and must not surface in user-facing text
# `instruct.cache` is keyed by `MemoKey`, so the unknown-field message's "declared aliases" list has
# to report the NAME half. Offering the key itself would print a tuple; offering an internally
# decorated string (the prefix design that preceded `MemoKey`) would print a spelling no caller can
# type. Either way the caller must get back only what they could have written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the unknown-field message never suggests an internal memo key (#474)" begin
  q = RAN.Ran_child.objects
  q.with("pp" => _ran_parent(), join_field = "parent" => "id")
  q.values("note", "c" => CTE("pp", "sku"))
  err = try
    q.filter("nope" => 1)
    inspect_query(q; connection = _RAN_SL)
    nothing
  catch e
    e
  end
  @test err isa PormG.UnknownFieldError
  msg = _ran_no_ansi(sprint(showerror, err))
  @test !occursin("cte:", msg)        # no internal decoration
  @test !occursin("(:cte,", msg)      # ...and no raw MemoKey either
  @test !occursin("(:base,", msg)
  @test !occursin("(:joined,", msg)
  @test occursin("pp__sku", msg)      # the spelling the caller CAN reach, still offered
end

# ─────────────────────────────────────────────────────────────────────────────
# A cjoin_on ALIAS may equal a ForeignKey field name, and BOTH joins are emitted (#484)
# The third instance of the family above, and the one that needed no CTE at all. `cjoin_on` keyed
# its config by USER ALIAS into the very map `cjoin` / `on()` key by JOIN PATH, so when a query both
# declared `cjoin_on(alias = "owner")` and traversed the ForeignKey `owner`, `_build_row_join` asked
# that map for the FK hop's config, was handed the ALIAS's, and folded it in: the alias's predicates
# AND-appended to the FK's ON clause, its `join_type` adopted, its own join never emitted — leaving
# `"owner"` a range variable the statement never declares. PostgreSQL: "missing FROM-clause entry".
#
# #484 splits the two namespaces into two typed maps (`custom_join` / `alias_join`), which makes the
# collision UNREPRESENTABLE rather than guarded — the direction #444/#474 established, and what the
# `Joined` docstring shipped by #481 already promised. Refusing it (#479's move) would have been
# wrong here: the two relations render under DIFFERENT SQL aliases — `Tb_1` generated for the
# ForeignKey, `owner` declared by the caller — so SQL never had a conflict. The collision was ours.
#
# `owner` is the NOT NULL ForeignKey (INNER) and every `cjoin_on` below asks for LEFT. That pairing
# is deliberate: under the defect the alias's join type was ADOPTED by the ForeignKey's join, so the
# symptom shows as an INNER→LEFT flip on a join the caller never named — a row-count change — and
# not merely as an appended predicate that a reader might dismiss as cosmetic.
# ─────────────────────────────────────────────────────────────────────────────

# The range variables a statement DECLARES: the FROM alias plus every `JOIN … AS "x"`. Deliberately
# not `as "x"` in general — that spelling also ends every SELECT output column, and counting those
# as declared relations would let the undeclared-range-variable check below pass on a qualifier that
# merely happens to match a result-column name.
function _ran_declared_relations(sql::AbstractString)
  out = Set{String}()
  for m in eachmatch(r"FROM\s+\"[^\"]+\"\s+as\s+\"([^\"]+)\"", sql)
    push!(out, m.captures[1])
  end
  for m in eachmatch(r"JOIN\s+\"[^\"]+\"\s+AS\s+\"([^\"]+)\"", sql)
    push!(out, m.captures[1])
  end
  return out
end
# Every `"x".` qualifier appearing anywhere in the statement.
_ran_qualifiers(sql::AbstractString) = Set(m.captures[1] for m in eachmatch(r"\"([^\"]+)\"\.", sql))
# The one emitted line that declares `alias`, trimmed — for byte-comparing a join across queries.
_ran_join_line(sql::AbstractString, alias::AbstractString) =
  strip(only(filter(l -> occursin("AS \"$(alias)\"", l), split(sql, "\n"))))

@testset "a cjoin_on alias may equal a ForeignKey field name (#484)" begin
  for (backend, conn) in (("PostgreSQL", _RAN_PG), ("SQLite", _RAN_SL))
    @testset "$backend" begin

      # ── the issue as filed: two joins, each with its own alias and its own ON ──
      q = RAN.Ran_child.objects
      q.cjoin_on("Ran_parent", alias = "owner", join_type = "LEFT",
                 on = [Joined("owner", "id") == F("owner")])
      q.values("note", "fk" => "owner__sku")
      sql = _ran_sql(q; conn = conn)

      # Two joins, not one. Pre-fix this was 1 — the alias's join was never emitted.
      @test count("JOIN", sql) == 2
      # The ForeignKey's own join: generated alias, INNER (from `null = false`), and NO `AND` —
      # the alias's predicate did not ride into it.
      @test occursin("INNER JOIN \"ran_parent\" AS \"Tb_1\" ON \"Tb\".\"owner\" = \"Tb_1\".\"id\"", sql)
      @test !occursin("AND", _ran_join_line(sql, "Tb_1"))
      # The cjoin_on's own join: the alias it declared, the join type IT asked for, its own ON.
      @test occursin("LEFT JOIN \"ran_parent\" AS \"owner\" ON (\"owner\".\"id\" = \"Tb\".\"owner\")", sql)

      # ── differential control (the #444/#474 coexistence-proof pattern) ────────
      # The SAME query without the cjoin_on must render the ForeignKey's join line BYTE-IDENTICALLY.
      # This is what catches the absorption and the INNER→LEFT flip in one assertion, without
      # restating the expected text: the FK join is not the cjoin_on's business at all.
      qc = RAN.Ran_child.objects
      qc.values("note", "fk" => "owner__sku")
      sql_control = _ran_sql(qc; conn = conn)
      @test _ran_join_line(sql, "Tb_1") == _ran_join_line(sql_control, "Tb_1")
      @test count("JOIN", sql_control) == 1

      # ── no statement names a range variable it does not declare ──────────────
      # The issue's third acceptance bullet, as a generic check rather than a spelling: pre-fix,
      # `owner` appeared as a qualifier with no `AS "owner"` anywhere to declare it.
      @test issubset(_ran_qualifiers(sql), _ran_declared_relations(sql))

      # ── the two reference namespaces stay disjoint (#481 memo tags) ──────────
      # `Joined("owner", "sku")` and the field path `"owner__sku"` both spell `owner__sku` as an
      # output name, and both resolve to the physical column `product_sku`.
      #
      # The two `occursin` assertions below are NOT the discriminating ones and are not left here
      # under the impression that they are: measured against unmodified origin/main, BOTH already
      # rendered exactly these strings — #481's memo namespaces were never the broken half. What
      # was broken is that `"owner"` named nothing, so the projection referenced an undeclared
      # relation. They are kept as the readable statement of what each handle resolves to; the
      # claim that the two land on DIFFERENT relations is carried by the join assertions after
      # them, which do fail pre-fix.
      qj = RAN.Ran_child.objects
      qj.cjoin_on("Ran_parent", alias = "owner", join_type = "LEFT",
                  on = [Joined("owner", "id") == F("owner")])
      qj.values("note", "fk" => "owner__sku", "al" => Joined("owner", "sku"))
      sql_j = _ran_sql(qj; conn = conn)
      @test occursin("\"Tb_1\".\"product_sku\" as \"fk\"", sql_j)
      @test occursin("\"owner\".\"product_sku\" as \"al\"", sql_j)
      # Both qualifiers name a relation this statement actually declares, and there are two of them.
      # Split rather than `&&`-ed on purpose: only the second is red pre-fix, and a conjunction
      # reports `false` without saying which half, which would point a future reader at the wrong one.
      @test count("JOIN", sql_j) == 2
      @test occursin("AS \"Tb_1\"", sql_j)
      @test occursin("AS \"owner\"", sql_j)
      @test issubset(_ran_qualifiers(sql_j), _ran_declared_relations(sql_j))

      # ── declaration order does not matter, and on() decorates the RELATION ───
      # `on("owner", …)` targets the join path; `cjoin_on(alias = "owner")` targets its own copy.
      # Before #484 the second-declared one either merged into the first (`on()` after `cjoin_on`)
      # or was refused outright ("Join path 'owner' already exists"), so the two orders disagreed.
      qab = RAN.Ran_child.objects
      qab.on("owner", "sku" => "S")
      qab.cjoin_on("Ran_parent", alias = "owner", join_type = "LEFT",
                   on = [Joined("owner", "id") == F("owner")])
      qab.values("note", "fk" => "owner__sku")

      qba = RAN.Ran_child.objects
      qba.cjoin_on("Ran_parent", alias = "owner", join_type = "LEFT",
                   on = [Joined("owner", "id") == F("owner")])
      qba.on("owner", "sku" => "S")
      qba.values("note", "fk" => "owner__sku")

      sql_ab = _ran_sql(qab; conn = conn)
      @test sql_ab == _ran_sql(qba; conn = conn)
      # The on() predicate landed on the ForeignKey's join…
      @test occursin("\"Tb_1\".\"product_sku\" = ", _ran_join_line(sql_ab, "Tb_1"))
      # …and the alias's ON is exactly what the caller wrote, no more.
      @test _ran_join_line(sql_ab, "owner") ==
            "LEFT JOIN \"ran_parent\" AS \"owner\" ON (\"owner\".\"id\" = \"Tb\".\"owner\")"
      # White-box: one predicate in each namespace, neither borrowing from the other.
      @test length(qab.object.custom_join["owner"].filters) == 1
      @test length(qab.object.alias_join["owner"].filters) == 1
      @test length(qba.object.custom_join["owner"].filters) == 1
      @test length(qba.object.alias_join["owner"].filters) == 1

      # ── the sibling shape `_cjoin` used to refuse ────────────────────────────
      # `cjoin("owner" => …)` after `cjoin_on(alias = "owner")` raised "Join path 'owner' already
      # exists" — naming a join path the caller had never declared. Now the two simply coexist.
      qcj = RAN.Ran_child.objects
      qcj.cjoin_on("Ran_parent", alias = "owner", join_type = "LEFT",
                   on = [Joined("owner", "id") == F("owner")])
      qcj.cjoin("owner" => "Ran_parent", warn = false)
      qcj.values("note", "fk" => "owner__sku")
      sql_cj = _ran_sql(qcj; conn = conn)
      @test count("JOIN", sql_cj) == 2
      @test issubset(_ran_qualifiers(sql_cj), _ran_declared_relations(sql_cj))
    end
  end

  # ── bound parameters stay aligned across both backends ────────────────────
  # A literal inside the alias's ON clause plus one in WHERE. PostgreSQL numbers placeholders as it
  # binds, so walking its `$N` markers left to right through its parameter vector gives the true
  # TEXT order; SQLite's flat vector must equal that (the QueryBuilder skill's oracle).
  #
  # A FORWARD guard, not a regression test — stated plainly because the obvious framing is wrong.
  # This passes on unmodified origin/main too: pre-fix the alias's literal was already in the join
  # bucket, folded into the ForeignKey's ON clause, so #484 moved which JOIN carries it, not which
  # bucket. What is new is that the same statement now emits two join fragments instead of one, and
  # #421/#432 are the record of what that costs when text order and binding order drift apart.
  _mk484() = begin
    qq = RAN.Ran_child.objects
    qq.cjoin_on("Ran_parent", alias = "owner", join_type = "LEFT",
                on = [Joined("owner", "id") == F("owner"), "note" => "n1"])
    qq.filter("note" => "w1")
    qq.values("note", "fk" => "owner__sku")
    qq
  end
  pg = inspect_query(_mk484(); connection = _RAN_PG)
  sl = inspect_query(_mk484(); connection = _RAN_SL)
  idx = [parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", pg[:sql_text])]
  text_order = [pg[:parameters][i] for i in idx]
  @test text_order == ["n1", "w1"]          # the join's literal renders before WHERE's
  @test sl[:parameters] == text_order       # SQLite's flattened vector agrees
end
