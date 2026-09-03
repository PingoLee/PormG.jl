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
import PormG.QueryBuilder: F, inspect_query
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
      q1.cjoin_on("Ran_parent", alias = "b2", on = [F("b2.sku") == F("note")])
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
      q4 = RAN.Ran_child.objects
      q4.with("parent" => _ran_grand(), join_field = "parent" => "id", join_type = "INNER")
      q4.on("parent", "sku" => "S")
      q4.values("note", "parent__sku", "cte_code" => CTE("parent", "code"))
      insp4 = inspect_query(q4; connection = conn)
      sql4 = insp4[:sql_text]

      @test occursin("INNER JOIN \"parent\" AS", sql4)                       # the CTE keeps INNER
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
@testset "a CTE column and a like-named field path keep separate memo entries (#474)" begin
  for (backend, conn) in (("PostgreSQL", _RAN_PG), ("SQLite", _RAN_SL))
    @testset "$backend" begin

      # The control first, so the expected column name is established by something that cannot be
      # affected by a CTE: with no CTE in the query, `parent__sku` is the ForeignKey's physical
      # `product_sku`.
      ctrl = RAN.Ran_child.objects
      ctrl.values("note", "parent__sku")
      ctrl.filter("parent__sku" => "S")
      ctrl_sql = _ran_sql(ctrl; conn = conn)
      @test occursin("\"product_sku\" = ", ctrl_sql)
      @test !occursin("\"sku\" = ", ctrl_sql)

      # ── the measured defect: CTE projected first, field path filtered after ──
      # On origin/main this rendered `WHERE "R1_1"."sku" = ?` — the CTE's projection alias — while
      # the ForeignKey's join sat in the statement unused. Both spellings claim `"parent__sku"`.
      q = RAN.Ran_child.objects
      q.with("parent" => _ran_parent(), join_field = "parent" => "id")
      q.values("note", "c" => CTE("parent", "sku"))
      q.filter("parent__sku" => "S")
      sql = _ran_sql(q; conn = conn)

      # The FILTER must name the ForeignKey's physical column, exactly as the control does.
      @test occursin("\"product_sku\" = ", sql)
      # ...and the PROJECTION must still name the CTE's alias. Asserting only the first half would
      # pass for a fix that simply stopped the CTE from caching at all.
      @test occursin("\"sku\" as \"c\"", sql)
      @test occursin("JOIN \"parent\" AS", sql)          # the CTE is joined
      @test occursin("JOIN \"ran_parent\" AS", sql)      # so is the ForeignKey

      # ── the mirror: field path first, CTE reference after ─────────────────
      # This ordering was CORRECT on main — the field path claimed the memo first. It is pinned so
      # the fix cannot be "swap which one wins", which would move the bug rather than remove it.
      q2 = RAN.Ran_child.objects
      q2.with("parent" => _ran_parent(), join_field = "parent" => "id")
      q2.values("note", "parent__sku")
      q2.filter(CTE("parent", "sku") => "S")
      sql2 = _ran_sql(q2; conn = conn)
      @test occursin("\"product_sku\" as \"parent__sku\"", sql2)   # projection = the ForeignKey
      @test occursin("\"sku\" = ", sql2)                            # filter = the CTE's alias

      # ── order_by reads the same memo ──────────────────────────────────────
      q3 = RAN.Ran_child.objects
      q3.with("parent" => _ran_parent(), join_field = "parent" => "id")
      q3.values("note", "c" => CTE("parent", "sku"))
      q3.order_by("parent__sku")
      sql3 = _ran_sql(q3; conn = conn)
      @test occursin("ORDER BY", sql3)
      # The ordered column is the ForeignKey's, not the CTE's projection alias.
      @test occursin("product_sku", split(sql3, "ORDER BY")[2])
    end
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
      @test q.object.custom_join["owner"]["join_type"] == expected
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
        q.cjoin_on("Ran_parent", alias = "b2", on = [F("b2.sku") == F("note")], join_type = "CROSS")
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
    # The key is absent, not set to a computed value: deciding the type HERE would have to
    # reproduce `_determine_join_type`'s `previus_how` LEFT-propagation for deep paths, which this
    # call site cannot see. Not overriding is what leaves that knowledge where it lives.
    @test !haskey(q.object.custom_join["owner"], "join_type")
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
    @test q.object.custom_join["owner"]["join_type"] == "LEFT"
  end

  @testset "a later on() inherits the first call's explicit join_type" begin
    q = RAN.Ran_child.objects
    q.on("owner", "sku" => "S", join_type = "LEFT")
    q.on("owner", "id__@gt" => 3)          # no join_type: must not reset it to anything
    q.values("note", "owner__sku")
    sql = _ran_sql(q)
    @test occursin("LEFT JOIN \"ran_parent\"", sql)
    @test q.object.custom_join["owner"]["join_type"] == "LEFT"
    @test length(q.object.custom_join["owner"]["filters"]) == 2
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
    @test isempty(q.object.custom_join["parent"]["filters"])
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

  # ...and the mirror, which is the one that would have been SILENT. TWO things make it
  # discriminate, and BOTH are required — a version of this test missing either passes on
  # `origin/main` and proves nothing:
  #
  #   1. the CTE is named `grand`, the SAME as the ForeignKey field, so both namespaces produce the
  #      memo name `"grand__payload"`. Name it anything else and the strings differ, so even a
  #      shared keyspace resolves each correctly;
  #   2. the CTE's `payload` is a DIFFERENT TYPE from the ForeignKey target's — `_ran_char_payload()`
  #      projects the CharField `code` under that alias, while `Ran_grand.payload` is the JSONField.
  #      With both JSON, an un-namespaced reader returns a JSONField either way and validation passes
  #      either way.
  #
  # Measured on `origin/main` with both in place: this renders `WHERE "R1_1"."payload" ? $1` against
  # the FOREIGN KEY's join, while the CTE named `grand` is declared and never joined — the `?` JSONB
  # operator licensed by the other namespace's field.
  q2 = RAN.Ran_child.objects
  q2.with("grand" => _ran_char_payload(), join_field = "grand" => "id", join_type = "INNER")
  q2.values("note", "fk" => "grand__payload")     # the FK path claims `grand__payload` first
  err = try
    q2.filter(CTE("grand", "payload__@has_key") => "driver")
    _ran_sql(q2; conn = _RAN_PG)
    nothing
  catch e
    e
  end
  # Refused, because the CTE's OWN `payload` is text — which is the whole point: the operator is now
  # validated against the column the caller named, not the one that happened to claim the memo.
  @test err isa PormG.FilterError
  @test occursin("is not JSON", _ran_no_ansi(sprint(showerror, err)))
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
