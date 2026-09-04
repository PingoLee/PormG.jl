"""
Unit coverage for join-config copy isolation (#112, restated for the typed maps of #484).

`deepcopy(::SQLObjectQuery)` shallow-copied `custom_join` (`copy(obj.custom_join)`), so a
query and its `.copy()` shared the inner per-join `Dict` objects by reference. `on()`
mutated that inner dict in place (`existing["filters"] = …`, `existing["join_type"] = …`),
so extending an existing join path on a copy rewrote the ORIGINAL's join definition. The
fix was `_copy_custom_join`, which rebuilt a fresh inner dict per join path.

#484 replaced that helper with `_copy_path_joins` / `_copy_alias_joins`, one per namespace:
the entries are now immutable structs (`PathJoin` / `AliasJoin`) in two typed maps
(`custom_join` keyed by join PATH, `alias_join` keyed by `cjoin_on` ALIAS), and every writer
replaces the whole entry rather than editing one. That closes the route the bug actually took.

It is NOT sufficient on its own, which is worth recording because it looks sufficient: an
immutable struct is only as immutable as what it points at, and `filters` is a `Vector`.
Copying the outer maps alone left a query and its `.copy()` sharing those vectors — measured,
`empty!` on the copy's list stripped the original's ON predicates and changed its rendered SQL.
So the copy rebuilds each entry with a fresh vector, and the last testset here asserts exactly
that, in the one form the public writers cannot reach.

The `PormGField` (and, for `cjoin_on`, the `PormGModel`) inside an entry stays shared by
reference: it holds a Model_Type → Module that `deepcopy` cannot traverse — the very reason
the original copy was shallow. So does each `FilterType` element inside the vector; writers
replace the vector, never an element.

Deterministic and DB-free: a mock PostgreSQL connection + inline F1-flavored models; SQL
is rendered via `show_query = :sql`, which short-circuits before any fetch.
"""

using Test
using PormG
using PormG.Models

# Mock connection under a dedicated key so this file cannot contaminate (or be
# contaminated by) other unit files sharing Main in runtests.jl.
struct CustomJoinCopyMockPostgres <: PormG.PormGPostgres end

PormG.config["cjc_mock"] = PormG.Configuration.Settings(
  connections = CustomJoinCopyMockPostgres(),
  change_data = true,
  db_def_folder = "cjc_mock",
)

# Inline F1-flavored models (NOT a re-include of db_sl/models.jl — a second include would
# redefine module `models` in the shared Main scope). Result.driverid is a real FK so
# `on("driverid", …)` resolves its join target without a prior cjoin. Bindings match the
# table names modulo case (Cjc_driver ↔ "cjc_driver") because cjoin validates the join
# target BOTH against the FK's model name (case-insensitive) and as a module binding.
module CustomJoinCopyModels
import PormG
import PormG.Models

Cjc_driver = Models.Model("cjc_driver",
  driverid = Models.IDField(),
  surname = Models.CharField(),
  nationality = Models.CharField(),
)

Cjc_results = Models.Model("cjc_results",
  id = Models.IDField(),
  driverid = Models.ForeignKey(Cjc_driver, pk_field = "driverid", on_delete = "RESTRICT"),
  points = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "cjc_mock")
end

const CJC = CustomJoinCopyModels

@testset "join-config copy isolation (#112, typed entries #484)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Copy independence: on()-seeded path (the issue's reproduction)
  # A copy must own a fresh OUTER map, and extending the SAME join path via on() on the
  # copy must not alter the original's filters or join_type. The two queries must render
  # different SQL while the original's SQL stays stable.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "on() on a copy does not mutate the original" begin
    q = CJC.Cjc_results.objects
    # Select through the join path — a custom join only renders its JOIN/ON clause when
    # the path is actually traversed, and AC3 needs the ON predicates visible in SQL.
    q.values("id", "driverid__surname")
    q.on("driverid", "driverid__nationality" => "British")
    q2 = q.copy()

    # AC1: a fresh OUTER map — the aliasing signal that survives #484. Pre-#112 this was
    # the same object, so `q2.custom_join["x"] = …` was a write to `q`.
    @test q2.object.custom_join !== q.object.custom_join
    # …and a fresh entry per path, holding a fresh filters VECTOR. The entry being immutable is not
    # sufficient on its own: `filters` is a `Vector`, so an entry shared by reference would let a
    # `push!` on the copy's predicate list rewrite the original's ON clause — measured, and the
    # reason `deepcopy` rebuilds each entry instead of just copying the outer map.
    @test q2.object.custom_join["driverid"] !== q.object.custom_join["driverid"]
    @test q2.object.custom_join["driverid"].filters !== q.object.custom_join["driverid"].filters

    # Snapshot the original before touching the copy: rendered SQL, the filters
    # vector OBJECT (to prove on() never wrote through it), and its length.
    sql_before   = q.list(show_query = :sql)
    orig_filters = q.object.custom_join["driverid"].filters
    orig_n       = length(orig_filters)

    # AC2: extend the SAME path on the copy — with a different predicate AND an
    # explicit join_type override, so both halves of what on() writes are exercised.
    q2.on("driverid", "driverid__nationality" => "Brazilian", join_type = "INNER")

    # Original untouched: same vector object, same length, and NO join_type at all — the copy
    # carries the extension alone.
    #
    # #474 moved this assertion. It read `["join_type"] == "LEFT"`, pinning the default `on()`
    # invented when the caller named none; that default is gone, because it silently overrode the
    # join type PormG derives from the relation itself (measured: the same NOT NULL ForeignKey path
    # renders `INNER JOIN` on its own and rendered `LEFT JOIN` the moment an `on()` predicate was
    # added). The absence assertion proves this testset's actual claim — that the copy's explicit
    # `join_type = "INNER"` did not leak into the original — strictly more tightly than the old one:
    # under the aliasing bug it would fail the same way, and it cannot be satisfied by a coincidence
    # of two defaults agreeing. (#484 spells "absent" as a `nothing` field rather than a missing key.)
    @test q.object.custom_join["driverid"].filters === orig_filters
    @test length(q.object.custom_join["driverid"].filters) == orig_n
    @test q.object.custom_join["driverid"].join_type === nothing
    @test length(q2.object.custom_join["driverid"].filters) == orig_n + 1
    @test q2.object.custom_join["driverid"].join_type == "INNER"

    # AC3: the copy renders its own SQL, and neither building nor rendering the copy
    # changed what the original renders.
    sql_copy  = q2.list(show_query = :sql)
    sql_after = q.list(show_query = :sql)
    @test sql_copy != sql_before   # copy diverged (extra ON predicate, INNER join)
    @test sql_after == sql_before  # original unchanged by the copy's build
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Copy independence: cjoin()-seeded path (the "field" sharing contract)
  # cjoin() seeds the entry with filters AND a `field` PormGField. The `field` is
  # DELIBERATELY shared by reference (it holds a Module deepcopy can't traverse), and
  # on() must carry it FORWARD onto the entry it replaces — dropping it would silently
  # unlink the custom join. This pins both, so a future over-eager deep copy (or a
  # forgetful rewrite of `_on`) fails loudly here.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "cjoin-seeded copy: shared field ref, carried through on()" begin
    q = CJC.Cjc_results.objects
    # warn=false: driverid is a real FK, so cjoin would otherwise warn about the
    # auto-discovered pk link (same suppression as test_alignment_sqlite.jl).
    q.cjoin("driverid" => "Cjc_driver", filters = ["nationality" => "British"], warn = false)
    q2 = q.copy()

    # Fresh outer map, fresh entry, fresh filters vector — and the field metadata shared by
    # reference, which is the contract this testset exists to pin.
    @test q2.object.custom_join !== q.object.custom_join
    @test q2.object.custom_join["driverid"] !== q.object.custom_join["driverid"]
    @test q2.object.custom_join["driverid"].filters !== q.object.custom_join["driverid"].filters
    @test q2.object.custom_join["driverid"].field === q.object.custom_join["driverid"].field

    orig_filters = q.object.custom_join["driverid"].filters
    orig_n       = length(orig_filters)

    # Extend the cjoin-seeded path on the copy via on(): adds a predicate and sets a
    # join_type — which cjoin never sets (it folds its own into `field.how`), so any leak
    # into the original is visible as a value where `nothing` belongs.
    q2.on("driverid", "driverid__surname" => "Senna", join_type = "INNER")

    @test q.object.custom_join["driverid"].filters === orig_filters
    @test length(q.object.custom_join["driverid"].filters) == orig_n
    @test q.object.custom_join["driverid"].join_type === nothing
    @test length(q2.object.custom_join["driverid"].filters) == orig_n + 1
    @test q2.object.custom_join["driverid"].join_type == "INNER"
    # The link survives the replacement, and is still the ORIGINAL's field object.
    @test q2.object.custom_join["driverid"].field === q.object.custom_join["driverid"].field
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #484: the alias namespace copies under the same contract
  # `alias_join` is the second map and gets the same treatment — a fresh outer map, a fresh entry
  # per alias, a fresh filters vector, and the target model shared by reference. A `cjoin_on`
  # DECLARED on the copy must not appear on the original, which is the write `_cjoin_on` makes to
  # the outer map.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "cjoin_on on a copy does not reach the original (#484)" begin
    q = CJC.Cjc_results.objects
    q.values("id")
    q.cjoin_on("Cjc_driver", alias = "d1", on = [Joined("d1", "driverid") == F("driverid")])
    q2 = q.copy()

    @test q2.object.alias_join !== q.object.alias_join
    @test q2.object.alias_join["d1"] !== q.object.alias_join["d1"]
    @test q2.object.alias_join["d1"].filters !== q.object.alias_join["d1"].filters
    # The target model is resolved at declaration and shared by reference, same reason as
    # `field` above: it carries a Module `deepcopy` cannot traverse.
    @test q2.object.alias_join["d1"].target === q.object.alias_join["d1"].target

    sql_before = q.list(show_query = :sql)

    # Declare a SECOND joined copy on q2 only.
    q2.cjoin_on("Cjc_driver", alias = "d2", on = [Joined("d2", "driverid") == F("driverid")])

    @test !haskey(q.object.alias_join, "d2")
    @test haskey(q2.object.alias_join, "d2")
    @test length(q.object.alias_join) == 1
    @test length(q2.object.alias_join) == 2

    # …and the original still renders exactly one joined copy.
    sql_after = q.list(show_query = :sql)
    @test sql_after == sql_before
    @test occursin("AS \"d1\"", sql_after)
    @test !occursin("AS \"d2\"", sql_after)
    @test occursin("AS \"d2\"", q2.list(show_query = :sql))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The invariant, stated directly: editing a copy's predicate list IN PLACE
  # The testsets above prove isolation through OBJECT IDENTITY — distinct maps, distinct entries,
  # distinct vectors. This one proves the CONSEQUENCE instead: it reaches into the stored vectors
  # the way `test_order_by_joins.jl` already does white-box, and then measures the original's
  # predicate counts and its rendered SQL.
  #
  # Both are needed, and this is the one that survives. An identity assertion is only as good as the
  # reader's belief about what identity implies — it was `===` here for one draft, on the theory
  # that immutable entries made sharing safe — whereas "the original still renders what it rendered"
  # cannot be argued with. If a later rewrite drops the `!==` lines above, this testset still fails.
  #
  # A real hazard, not a hypothetical: with `deepcopy` copying only the outer maps (the shape this
  # change carried until review), `empty!` here stripped the ORIGINAL's ON predicates too and its
  # rendered SQL changed. Both namespaces, because both hold a `Vector`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an in-place edit of a copy's predicate list cannot reach the original (#112)" begin
    q = CJC.Cjc_results.objects
    q.values("id", "driverid__surname")
    q.on("driverid", "driverid__nationality" => "British")
    q.cjoin_on("Cjc_driver", alias = "d1", on = [Joined("d1", "driverid") == F("driverid")])
    q2 = q.copy()

    sql_before  = q.list(show_query = :sql)
    path_n      = length(q.object.custom_join["driverid"].filters)
    alias_n     = length(q.object.alias_join["d1"].filters)
    # Guards against a vacuous 0 == 0 below. Neither can fail today — `_on` refuses an empty
    # predicate list with no join_type and `_cjoin_on` refuses an empty `on` — so they are a
    # tripwire for a future change to what is stored, not discriminating assertions themselves.
    @test path_n == 1
    @test alias_n == 1

    empty!(q2.object.custom_join["driverid"].filters)
    empty!(q2.object.alias_join["d1"].filters)

    @test length(q.object.custom_join["driverid"].filters) == path_n
    @test length(q.object.alias_join["d1"].filters) == alias_n
    @test q.list(show_query = :sql) == sql_before
  end
end
