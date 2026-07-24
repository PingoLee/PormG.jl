# ============================================================
# test/unit/test_order_by_nulls.jl
#
# ORDER BY NULL-placement normalization (#75).
#
# CONTRACT being tested:
#   Top-level ORDER BY must emit an explicit NULL-placement clause on BOTH backends so a
#   nullable sort key returns the same rows on PostgreSQL and SQLite. The canonical default
#   matches PostgreSQL (NULL sorts as the largest value): ASC → NULLS LAST, DESC → NULLS FIRST.
#   A per-term override — SQLOrder(field; nulls=:first|:last) — forces placement. On SQLite
#   builds older than 3.30.0 (no NULLS syntax) the term degrades to the portable
#   `(expr IS NULL)` prefix that sorts identically.
#
# These are deterministic SQL-shape / pure-function tests: no live database. Reverting the fix
# (bare `expr ASC|DESC` push) drops the `NULLS …` suffix, so every default/override assertion
# below fails — the mutation gate.
# ============================================================

using Test
using PormG
using PormG.Models: Model, IDField, CharField, IntegerField
using PormG.QueryBuilder: SQLField, SQLOrder

# Internal helpers live in the QueryBuilder submodule (build_query.jl), unexported.
const _nulls_placement = PormG.QueryBuilder._nulls_placement
const _order_term_sql  = PormG.QueryBuilder._order_term_sql

# ── Mock backends ───────────────────────────────────────────────────────────────────────────
# A mock PostgreSQL marker for full-render tests (no DB round-trip), mirroring the pattern in
# test_inspect_query.jl. Two mock SQLite markers pin the version-gated rendering branch: one
# reports a modern library (native NULLS syntax), one an old one (portable fallback). We add
# `backend_sqlite_version` methods on our own mock types so the branch is provable without an
# actual old SQLite build.
struct MockPG_OrderNulls <: PormG.PormGPostgres end
struct MockNewSQLite_OrderNulls <: PormG.PormGSQLite end
struct MockOldSQLite_OrderNulls <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::MockNewSQLite_OrderNulls) = 3039000   # 3.39.0 → native NULLS
PormG.backend_sqlite_version(::MockOldSQLite_OrderNulls) = 3029000   # 3.29.0 → portable fallback

DriverNullsModel = Model("drivers_nulls",
  id = IDField(),
  surname = CharField(),
  nationality = CharField(null=true),   # nullable → the #75 divergence surface
)
DriverNullsModel.connect_key = "order_nulls_pg"
PormG.config["order_nulls_pg"] = PormG.Configuration.Settings(
  connections = MockPG_OrderNulls(),
  change_data = true,
)

@testset "ORDER BY NULL-placement normalization (#75)" begin

  # ─────────────────────────────────────────────────────────────────────────
  # Pure placement resolution: canonical default is PostgreSQL's (ASC→last, DESC→first),
  # and an explicit override wins regardless of orientation.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "_nulls_placement resolves the canonical default and overrides" begin
    @test _nulls_placement("ASC",  nothing) === :last     # ASC default → NULLS LAST
    @test _nulls_placement("DESC", nothing) === :first    # DESC default → NULLS FIRST
    @test _nulls_placement("asc",  nothing) === :last     # case-insensitive
    @test _nulls_placement("DESC", :last)   === :last     # override beats the DESC default
    @test _nulls_placement("ASC",  :first)  === :first    # override beats the ASC default

    # Garbage placement must fail loudly and name the valid options — not silently default.
    err = try
      _nulls_placement("ASC", :bogus)
      nothing
    catch e
      e
    end
    @test err isa PormGError
    @test occursin(":first", string(err))
    @test occursin(":last", string(err))
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Per-backend term rendering. PG and modern SQLite emit native NULLS syntax; the SQLite
  # < 3.30 build emits the portable `(expr IS NULL)` prefix that sorts the same way.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "_order_term_sql renders native NULLS and the old-SQLite fallback" begin
    pg  = MockPG_OrderNulls()
    sln = MockNewSQLite_OrderNulls()
    slo = MockOldSQLite_OrderNulls()

    # Native NULLS syntax (PostgreSQL + SQLite ≥ 3.30).
    @test _order_term_sql("col", "ASC",  :last,  pg)  == "col ASC NULLS LAST"
    @test _order_term_sql("col", "DESC", :first, pg)  == "col DESC NULLS FIRST"
    @test _order_term_sql("col", "ASC",  :last,  sln) == "col ASC NULLS LAST"
    @test _order_term_sql("col", "DESC", :first, sln) == "col DESC NULLS FIRST"

    # Portable fallback (SQLite < 3.30): NULLS LAST → non-nulls (flag 0) first → flag ASC;
    # NULLS FIRST → nulls (flag 1) first → flag DESC. The base orientation trails.
    @test _order_term_sql("col", "ASC",  :last,  slo) == "(col IS NULL) ASC, col ASC"
    @test _order_term_sql("col", "DESC", :first, slo) == "(col IS NULL) DESC, col DESC"

    # Bind-safety guard: the fallback references `expr` twice, so a placeholder-carrying order term
    # must NOT be duplicated (that would bind once but reference twice → parameter misalignment).
    # For such a term on old SQLite, emit the plain term — no null-flag prefix, no NULLS syntax.
    @test _order_term_sql("col = ?", "ASC", :last, slo) == "col = ? ASC"
    # The native path still appends NULLS even with a placeholder (no duplication there → safe).
    @test _order_term_sql("col = ?", "ASC", :last, sln) == "col = ? ASC NULLS LAST"
  end

  # ─────────────────────────────────────────────────────────────────────────
  # End-to-end SQL shape through the public order_by API on a mock PostgreSQL connection.
  # This gates the wiring in get_order_query, not just the helpers.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "order_by() emits NULLS placement in rendered SQL" begin
    # Default ascending → NULLS LAST.
    q_asc = DriverNullsModel.objects
    q_asc.order_by("nationality")
    sql_asc = q_asc.list(show_query=:sql)
    @test occursin("ORDER BY", sql_asc)
    @test occursin("ASC NULLS LAST", sql_asc)

    # Default descending (leading '-') → NULLS FIRST.
    q_desc = DriverNullsModel.objects
    q_desc.order_by("-nationality")
    sql_desc = q_desc.list(show_query=:sql)
    @test occursin("DESC NULLS FIRST", sql_desc)

    # Override via SQLOrder object: ascending but nulls forced to the front.
    q_ovr = DriverNullsModel.objects
    q_ovr.order_by(SQLOrder(SQLField("nationality", "nationality"); orientation="ASC", nulls=:first))
    sql_ovr = q_ovr.list(show_query=:sql)
    @test occursin("ASC NULLS FIRST", sql_ovr)

    # Override the other direction: descending but nulls forced to the end.
    q_ovr2 = DriverNullsModel.objects
    q_ovr2.order_by(SQLOrder(SQLField("nationality", "nationality"); orientation="DESC", nulls=:last))
    sql_ovr2 = q_ovr2.list(show_query=:sql)
    @test occursin("DESC NULLS LAST", sql_ovr2)
  end
end
