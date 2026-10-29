"""
Unit coverage for projections wider than the old 60-slot SELECT buffer (#1335).

`InstructionObject.select` used to default to `Array{SQLTypeField,1}(undef, 60)`, and
`get_select_query` writes `instruc.select[i]` for the i-th `values()` entry. Nothing grew it, so the
61st projection threw while the SQL was being built, on every backend:

    BoundsError: attempt to access 60-element Vector{PormG.Kernel.SQLTypeField} at index [61]

A `values()` that lists every column of a wide reporting row is an ordinary shape, and its width
grows with the view that reads it. The buffer is now sized to the projection list at the top of
`get_select_query`, which keeps the positional `select[i] ↔ values[i]` mapping the readers rely on.

Hermetic: mock PostgreSQL and SQLite connections, no database.
"""
# julia --project=test/integration test/unit/test_wide_projection.jl

using Test
using PormG
using PormG.Models

struct WpMockSQLite <: PormG.PormGSQLite end
struct WpMockPostgres <: PormG.PormGPostgres end
const _WP_SL = WpMockSQLite()
const _WP_PG = WpMockPostgres()
PormG.backend_sqlite_version(::WpMockSQLite) = 3045000

PormG.config["wp_mock"] = PormG.Configuration.Settings(
  connections = _WP_SL,
  change_data = true,
  db_def_folder = "wp_mock",
)

module WpModels
import PormG
import PormG.Models

# The F1 `results` table, narrowed to what the projections read.
Wp_result = Models.Model("wp_result",
  resultid      = Models.IDField(),
  points        = Models.FloatField(null = true),
  positionorder = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "wp_mock")
end

const WP = WpModels
const QB = PormG.QueryBuilder
import PormG.QueryBuilder: inspect_query, CTE, Count

const _WP_BACKENDS = (("PostgreSQL", _WP_PG), ("SQLite", _WP_SL))

# `n` projections of one column, each under its own alias `p1` … `pn`.
_wide(n) = ["p$i" => "points" for i in 1:n]

# The position of every `as "p<i>"` in the SQL, in alias order; `nothing` for an alias that is missing.
_alias_positions(sql, n) = [(r = findfirst("as \"p$i\"", sql); r === nothing ? nothing : first(r)) for i in 1:n]

# ─────────────────────────────────────────────────────────────────────────────
# The issue's acceptance shape: 61 (one past the old cap) and 500 projections.
# Expected SQL: `SELECT "Tb"."points" as "p1", …, "Tb"."points" as "p<n>" FROM "wp_result" AS "Tb"`,
# exactly `n` aliased terms, in declaration order. Before #1335 the build threw `BoundsError` at
# index [61]. The order check matters as much as the count: rows are read back by position on some
# paths, so a buffer that kept every term but reordered them would be a silent misread.
# ─────────────────────────────────────────────────────────────────────────────
@testset "values() wider than 60 renders every alias in declaration order (#1335)" begin
  for (backend, conn) in _WP_BACKENDS, n in (60, 61, 500)
    @testset "$backend, $n projections" begin
      q = WP.Wp_result.objects
      q.values(_wide(n)...)
      sql = inspect_query(q; connection = conn)[:sql_text]
      pos = _alias_positions(sql, n)
      @test all(!isnothing, pos)
      @test issorted(pos) && allunique(pos)   # strictly increasing
      @test count("as \"p", sql) == n
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The readers of the SELECT buffer, past slot 60. ORDER BY resolves an alias by walking the buffer
# (`get_order_query`), DISTINCT walks it again, and a CTE's projection is read back by position when
# the outer query references its columns. Expected: each renders, and the 61st alias is the one
# named — `ORDER BY "p61"`, `SELECT DISTINCT`, and the outer query correlating on the CTE's
# `resultid`. Any of these could have kept a 60-slot assumption of its own.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the buffer's readers see projections past slot 60 (#1335)" begin
  for (backend, conn) in _WP_BACKENDS
    @testset "$backend: order_by on the 61st alias" begin
      q = WP.Wp_result.objects
      q.values(_wide(61)...)
      q.order_by("-p61")
      sql = inspect_query(q; connection = conn)[:sql_text]
      @test occursin(r"ORDER BY[^\n]*\"p61\" DESC", sql)
    end

    # Under DISTINCT, an ORDER BY term that is not an alias is checked against the projection's
    # expressions by walking the buffer (#76). The column is projected only at slot 61, so the walk
    # must reach it; the unprojected `resultid` is the control that proves the walk ran.
    @testset "$backend: distinct, ordered by a column projected at slot 61" begin
      wide_distinct() = (q = WP.Wp_result.objects; q.values(_wide(60)..., "p61" => "positionorder"); q.distinct(); q)
      q = wide_distinct()
      q.order_by("positionorder")
      sql = inspect_query(q; connection = conn)[:sql_text]
      @test occursin(r"SELECT\s+DISTINCT", sql)
      @test occursin(r"ORDER BY[^\n]*\"positionorder\"", sql)
      q = wide_distinct()
      q.order_by("resultid")
      @test_throws PormG.QueryBuildError inspect_query(q; connection = conn)
    end

    # The outer query reads the CTE's columns from the projection its body built, so a column past
    # slot 60 of the body is only resolvable if the body's buffer held it.
    @testset "$backend: the outer query reads the 62nd column of a CTE body" begin
      inner = WP.Wp_result.objects
      inner.values("resultid", _wide(61)...)
      q = WP.Wp_result.objects
      q.with("wide" => inner)
      q.filter("resultid" => CTE("wide", "resultid"))
      q.values("resultid", "late" => CTE("wide", "p61"))
      sql = inspect_query(q; connection = conn)[:sql_text]
      @test occursin("WITH \"wide\" AS", sql)
      @test count("as \"p", sql) == 61
      @test occursin(r"\.\"p61\" as \"late\"", sql)   # the CTE's column, under the outer alias
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The terminals that print a kept projection themselves rather than through `list()`: `count()` over a
# `distinct()` projection counts it from a derived table, `SELECT COUNT(*) FROM (SELECT DISTINCT …)`,
# and `exists()` over an aggregating projection probes `SELECT … GROUP BY 1, …, 60 LIMIT 1`. Both
# print the SELECT buffer, so both must carry the 61st term. These terminals take the configured
# connection, which here is the SQLite mock; the buffer they print is the same on every backend.
# ─────────────────────────────────────────────────────────────────────────────
@testset "count() and exists() print a projection wider than 60 (#1335)" begin
  q = WP.Wp_result.objects
  q.values(_wide(61)...)
  q.distinct()
  sql = q.count(show_query = :sql)
  @test occursin(r"SELECT COUNT\(\*\) FROM \(\s*SELECT\s+DISTINCT", sql)
  @test count("as \"p", sql) == 61
  @test occursin("as \"p61\"", sql)

  q = WP.Wp_result.objects
  q.values(["p$i" => "positionorder" for i in 1:60]..., "n" => Count("resultid"))
  sql = q.exists(show_query = :sql)
  @test count("as \"p", sql) == 60
  @test occursin(r"COUNT\([^)]*\) as \"n\"", sql)   # the 61st term, the aggregate
  @test occursin(r"GROUP BY 1, [0-9, ]*\b60\b", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# No `values()` at all. Expected SQL: `SELECT "Tb".* FROM …` — the projection is the whole row. The
# old buffer's unassigned slot 1 was how `_query_select` knew to print `*`; an empty buffer must
# say the same thing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no values() still renders the whole row (#1335)" begin
  for (backend, conn) in _WP_BACKENDS
    sql = inspect_query(WP.Wp_result.objects; connection = conn)[:sql_text]
    @test occursin(r"SELECT\s+(\"Tb\"\.)?\*", sql)
    instruc = QB.build(WP.Wp_result.objects.object; connection = conn)
    @test isempty(instruc.select)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The buffer is the projection: after a build it holds exactly one assigned slot per `values()`
# entry. This is what rules out a fixed buffer of ANY size, not only one smaller than the
# projection — raising the constant to 256 would pass the tests above and fail this one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the SELECT buffer is sized to the projection list (#1335)" begin
  for (backend, conn) in _WP_BACKENDS, n in (1, 3, 61)
    q = WP.Wp_result.objects
    q.values(_wide(n)...)
    instruc = QB.build(q.object; connection = conn)
    @test length(instruc.select) == n
    @test all(i -> isassigned(instruc.select, i), eachindex(instruc.select))
  end
end
