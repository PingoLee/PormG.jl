"""
Unit coverage for custom_join copy isolation (#112) — the build-time sibling of #43.

`deepcopy(::SQLObjectQuery)` shallow-copied `custom_join` (`copy(obj.custom_join)`), so a
query and its `.copy()` shared the inner per-join `Dict` objects by reference. `on()`
mutates that inner dict in place (`existing["filters"] = …`, `existing["join_type"] = …`),
so extending an existing join path on a copy rewrote the ORIGINAL's join definition.

The fix (`_copy_custom_join` in src/querybuilder/types.jl, mirroring #43's `_copy_ctes`)
rebuilds a fresh inner dict per join path and copies the "filters" vector, while the
"field" `PormGField` stays shared by reference — it holds a Model_Type → Module that
`deepcopy` cannot traverse (the very reason the original copy was shallow).

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

@testset "custom_join copy isolation (#112)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Copy independence: on()-seeded path (the issue's reproduction)
  # A copy must own fresh inner per-join dicts; extending the SAME join path via on()
  # on the copy must not alter the original's filters or join_type, and the two
  # queries must render different SQL while the original's SQL stays stable.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "on() on a copy does not mutate the original" begin
    q = CJC.Cjc_results.objects
    # Select through the join path — a custom join only renders its JOIN/ON clause when
    # the path is actually traversed, and AC3 needs the ON predicates visible in SQL.
    q.values("id", "driverid__surname")
    q.on("driverid", "driverid__nationality" => "British")
    q2 = q.copy()

    # AC1: distinct outer AND inner dicts — the aliasing signal. Pre-fix, the outer
    # dict was fresh but the inner dict was the SAME object on both queries.
    @test q2.object.custom_join !== q.object.custom_join
    @test q2.object.custom_join["driverid"] !== q.object.custom_join["driverid"]

    # Snapshot the original before touching the copy: rendered SQL, the filters
    # vector OBJECT (to prove on() never wrote through it), and its length.
    sql_before   = q.list(show_query = :sql)
    orig_filters = q.object.custom_join["driverid"]["filters"]
    orig_n       = length(orig_filters)

    # AC2: extend the SAME path on the copy — with a different predicate AND an
    # explicit join_type override, so both in-place writes of on() are exercised.
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
    # of two defaults agreeing.
    @test q.object.custom_join["driverid"]["filters"] === orig_filters
    @test length(q.object.custom_join["driverid"]["filters"]) == orig_n
    @test !haskey(q.object.custom_join["driverid"], "join_type")
    @test length(q2.object.custom_join["driverid"]["filters"]) == orig_n + 1
    @test q2.object.custom_join["driverid"]["join_type"] == "INNER"

    # AC3: the copy renders its own SQL, and neither building nor rendering the copy
    # changed what the original renders.
    sql_copy  = q2.list(show_query = :sql)
    sql_after = q.list(show_query = :sql)
    @test sql_copy != sql_before   # copy diverged (extra ON predicate, INNER join)
    @test sql_after == sql_before  # original unchanged by the copy's build
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Copy independence: cjoin()-seeded path (the "field" sharing contract)
  # cjoin() seeds the inner dict with "filters" AND a "field" PormGField. The copy
  # must own a fresh inner dict and a fresh filters vector, but the "field" is
  # DELIBERATELY shared by reference (it holds a Module deepcopy can't traverse) —
  # this pins that contract so a future over-eager deep copy fails loudly here.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "cjoin-seeded copy: fresh dicts, shared field ref" begin
    q = CJC.Cjc_results.objects
    # warn=false: driverid is a real FK, so cjoin would otherwise warn about the
    # auto-discovered pk link (same suppression as test_alignment_sqlite.jl).
    q.cjoin("driverid" => "Cjc_driver", filters = ["nationality" => "British"], warn = false)
    q2 = q.copy()

    # Fresh containers: inner dict and filters vector are distinct objects…
    @test q2.object.custom_join["driverid"] !== q.object.custom_join["driverid"]
    @test q2.object.custom_join["driverid"]["filters"] !== q.object.custom_join["driverid"]["filters"]
    # …while the un-deepcopy-able field metadata is intentionally the same reference.
    @test q2.object.custom_join["driverid"]["field"] === q.object.custom_join["driverid"]["field"]

    orig_n = length(q.object.custom_join["driverid"]["filters"])

    # Extend the cjoin-seeded path on the copy via on(): adds a predicate and writes
    # "join_type" — a key cjoin never sets, so any leak into the original is visible
    # as a brand-new key, not just a changed value.
    q2.on("driverid", "driverid__surname" => "Senna", join_type = "INNER")

    @test length(q.object.custom_join["driverid"]["filters"]) == orig_n
    @test !haskey(q.object.custom_join["driverid"], "join_type")
    @test length(q2.object.custom_join["driverid"]["filters"]) == orig_n + 1
    @test q2.object.custom_join["driverid"]["join_type"] == "INNER"
  end
end
