"""
Unit coverage for CTE ergonomics (#44): referencing a CTE's columns with `F()` in the main
query WITHOUT a `join_field`.

When `.with("r91" => sub)` is given no `join_field`, the CTE is emitted but not keyed to the
main table. Referencing one of its columns via `CTE("r91", "col")` then CROSS JOINs the CTE and the
`F()` filter supplies the correlation verbatim in WHERE — WYSIWYG. This is the natural,
Django-flavored way to correlate a main query with a CTE (`filter("raceid" => CTE("r91", "raceid"))`).

What is pinned here (deterministic, DB-free — rendered via `inspect_query`, both dialects):
  - No-`join_field` + `F()` correlation → a `CROSS JOIN` (no ON) and the correlation lands in
    WHERE; CTE parameters precede WHERE parameters (positional bucket order).
  - Regression: an explicit `join_field` still emits the keyed `INNER/LEFT JOIN … ON …` and NO
    `CROSS JOIN` — the existing CTE path is untouched.
  - Two references to the same CTE dedup onto a single `CROSS JOIN`.
  - An uncorrelated CROSS reference (referenced but never filtered) emits the Cartesian-product
    `@warn`; the correlated example does not.

Sibling coverage:
  - `test_cte.jl` (integration) → the same feature against the real F1 dataset, both backends.
  - `test_alignment_sqlite.jl` → CTE parameter-bucket ordering with a keyed `join_field`.
"""

using Test
using PormG
using PormG.Models
import Logging

# Mock connections under dedicated keys so this file cannot contaminate (or be contaminated by)
# other unit files sharing Main in runtests.jl. Only the connection TYPE matters — dispatch
# selects SQLite `?`/`date()` vs PostgreSQL `$N` rendering.
struct CteErgoMockSQLite <: PormG.PormGSQLite end
struct CteErgoMockPostgres <: PormG.PormGPostgres end
const _CTE_SL = CteErgoMockSQLite()
const _CTE_PG = CteErgoMockPostgres()

PormG.config["cte_ergo_mock"] = PormG.Configuration.Settings(
  connections = _CTE_SL,
  change_data = true,
  db_def_folder = "cte_ergo_mock",
)

# Inline F1-flavored models (NOT a re-include of db_sl/models.jl — a second include would
# redefine module `models` in the shared Main scope). `raceid` on the result table is a real FK
# to the race table, mirroring the canonical schema so `CTE("r91", "raceid")` correlates a real
# main-table column against the CTE's projected `raceid`.
module CteErgoModels
import PormG
import PormG.Models

Cte_race = Models.Model("cte_race",
  raceid = Models.IDField(),
  year = Models.IntegerField(),
  name = Models.CharField(),
)

Cte_result = Models.Model("cte_result",
  resultid = Models.IDField(),
  raceid = Models.ForeignKey(Cte_race, pk_field = "raceid", on_delete = "CASCADE"),
  positionorder = Models.IntegerField(),
)

PormG.Models.set_models(@__MODULE__, "cte_ergo_mock")
end

const CE = CteErgoModels
import PormG.QueryBuilder: F, inspect_query

# The 1991-races CTE reused across cases: SELECT raceid FROM cte_race WHERE year = 1991.
_races_91() = CE.Cte_race.objects.filter("year" => 1991).values("raceid")

@testset "CTE ergonomics — F() reference without join_field (#44)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # CROSS JOIN + WHERE correlation (SQLite): the issue's exact shape
  # `.with("r91" => races_91).filter("raceid" => CTE("r91", "raceid"), "positionorder" => 1)`
  # must emit a CROSS JOIN (no ON) and render the F() correlation verbatim in WHERE. CTE
  # parameter (1991) must precede the WHERE parameter (1) in the positional buckets.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite: no join_field → CROSS JOIN + WHERE correlation" begin
    q = CE.Cte_result.objects
    q.with("r91" => _races_91())
    q.filter("raceid" => CTE("r91", "raceid"), "positionorder" => 1)
    q.values("resultid", "positionorder")

    insp = inspect_query(q)          # default connection = mock SQLite
    sql = insp[:sql_text]

    # A CROSS JOIN to the CTE is emitted ...
    @test occursin("CROSS JOIN \"r91\"", sql)
    # ... and there is NO keyed `JOIN "r91" … ON` (alias-agnostic — a wrong keyed join under any
    # alias must fail), and the CROSS line itself carries no ON.
    @test !occursin(r"JOIN \"r91\"[^\n]*\bON\b", sql)     # no keyed ON to the CTE, any alias
    @test !occursin(r"CROSS JOIN[^\n]*ON", sql)           # the CROSS line itself has no ON

    # The F() correlation renders in WHERE with BOTH operands pinned: the main alias on the left,
    # the CROSS alias on the right (not a keyed ON, not a bare unqualified column).
    @test occursin(r"WHERE[^\n]*\"R1\"\.\"raceid\" = \"R1_1\"\.\"raceid\"", sql)

    # Positional buckets: CTE filter (1991) before the WHERE filter (1).
    buckets = insp[:parameter_buckets]
    @test buckets[:cte] == [1991]
    @test buckets[:where] == [1]
    @test buckets[:join] == []             # a CROSS JOIN contributes no ON parameters
    @test insp[:parameters] == [1991, 1]   # flat order: cte then where
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Cross-dialect parity (PostgreSQL): same query, `$N` placeholders, same join shape
  # The PG override must render the identical CROSS JOIN + WHERE correlation, differing only
  # in placeholder syntax ($1, $2) — locking that the feature is not SQLite-specific.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL: no join_field → CROSS JOIN + WHERE correlation" begin
    q = CE.Cte_result.objects
    q.with("r91" => _races_91())
    q.filter("raceid" => CTE("r91", "raceid"), "positionorder" => 1)
    q.values("resultid", "positionorder")

    insp = inspect_query(q; connection = _CTE_PG)
    sql = insp[:sql_text]

    @test occursin("CROSS JOIN \"r91\"", sql)
    @test !occursin(r"CROSS JOIN[^\n]*ON", sql)
    @test occursin(r"WHERE[^\n]*\"R1\"\.\"raceid\" = \"R1_1\"\.\"raceid\"", sql)
    # PostgreSQL uses linear $N placeholders; pin POSITION-to-placeholder (not mere presence):
    # the CTE filter must bind $1 and the main WHERE filter $2 — CTE params are numbered first.
    @test occursin(r"\"year\"\s*=\s*\$1", sql)            # CTE predicate binds $1
    @test occursin(r"\"positionorder\"\s*=\s*\$2", sql)   # main WHERE binds $2
    @test insp[:parameters] == [1991, 1]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Regression: an explicit join_field still emits the keyed JOIN … ON (never a CROSS JOIN)
  # The #44 CROSS path is gated on `join_field === nothing`; supplying a join_field must keep
  # the pre-existing INNER/LEFT JOIN ON behavior byte-for-byte.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "explicit join_field keeps the keyed JOIN … ON (no CROSS)" begin
    q = CE.Cte_result.objects
    q.with("r91" => _races_91(), join_field = "raceid" => "raceid")
    q.filter("positionorder" => 1)
    q.values("resultid", CTE("r91", "raceid"))

    sql = inspect_query(q)[:sql_text]

    @test occursin("JOIN \"r91\" AS \"R1_1\" ON \"R1\".\"raceid\" = \"R1_1\".\"raceid\"", sql)
    @test !occursin("CROSS JOIN", sql)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Dedup: two references to the same CTE collapse to one CROSS JOIN
  # `_insert_join` dedups on (a, b, key_a, key_b, alias_a); the empty-string key sentinels make
  # repeated references (`r91__raceid`, `r91__year`) resolve to a single CROSS JOIN entry.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "two references to the same CTE dedup to one CROSS JOIN" begin
    q = CE.Cte_result.objects
    q.with("r91" => CE.Cte_race.objects.filter("year" => 1991).values("raceid", "year"))
    q.filter("raceid" => CTE("r91", "raceid"))
    q.values("resultid", CTE("r91", "raceid"), CTE("r91", "year"))

    sql = inspect_query(q)[:sql_text]

    # Exactly one CROSS JOIN of "r91", even though two of its columns are referenced.
    @test length(collect(eachmatch(r"CROSS JOIN \"r91\"", sql))) == 1
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Cartesian-product guard: an uncorrelated CROSS reference warns; a correlated one does not
  # Referencing `r91__raceid` in values() with NO constraining filter is a Cartesian product —
  # PormG @warns and names the CTE. The correlated example (filter present) must stay silent.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "uncorrelated CROSS join warns; correlated stays silent" begin
    # Uncorrelated: reference the CTE column but never filter on it → warn.
    warn_q = () -> begin
      q = CE.Cte_result.objects
      q.with("r91" => _races_91())
      q.values("resultid", CTE("r91", "raceid"))
      inspect_query(q)
    end
    @test_logs (:warn, r"CROSS JOINed with no correlating filter") warn_q()

    # Correlated: the F() filter constrains the CTE → no warning of any kind.
    quiet_q = () -> begin
      q = CE.Cte_result.objects
      q.with("r91" => _races_91())
      q.filter("raceid" => CTE("r91", "raceid"))
      q.values("resultid")
      inspect_query(q)
    end
    @test_logs quiet_q()
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Over-long CTE path errors cleanly — never a cryptic KeyError("how")
  # A CTE column is terminal: `CTE("r91", "raceid__year")` cannot traverse past `raceid`. The CROSS
  # branch seeds a "how" sentinel so this reaches the same "not a foreign key" failure as the
  # keyed path — a raw KeyError("how") (the pre-fix behavior) would fail the second assertion.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "over-long CTE path errors cleanly, not KeyError" begin
    q = CE.Cte_result.objects
    q.with("r91" => _races_91())
    q.filter("raceid" => CTE("r91", "raceid__year"))   # one segment too deep — raceid is terminal
    q.values("resultid")

    err = try inspect_query(q); nothing catch e; e end
    @test err !== nothing          # it must error — a CTE column cannot be traversed further
    @test !(err isa KeyError)      # and NOT the cryptic KeyError("how") the fix removed
  end

end
