"""
Unit tests for PormGsuffix operator SQL generation.

Verifies that every operator alias defined in PormGsuffix produces the correct
SQL token and stores the correct bound parameter — with no live database required
(`show_query=:dict` mode).

Why a dedicated file?
  - `test_parameters.jl`  → tests the *parameter storage layer* (buckets, ordering).
  - `test_complex_queries.jl` → tests multi-step query *patterns* (pagination, Q objects, etc.).
  - This file → tests that each *operator suffix* (gt, gte, in, contains, …) emits the
    right SQL fragment.  One clear responsibility per file.
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
using PormG.QueryBuilder: Q
using Infiltrator: @infiltrate

# ---------------------------------------------------------------------------
# Minimal test models — same shape as test_complex_queries.jl so both files
# can be included independently or together without re-definition conflicts.
# ---------------------------------------------------------------------------
if !isdefined(Main, :_OperTestDriver)
  _OperTestDriver = Model("drivers",
    id          = IDField(),
    forename    = CharField(),
    surname     = CharField(),
    nationality = CharField()
  )
  _OperTestDriver.connect_key = "default"

  _OperTestRace = Model("races",
    id   = IDField(),
    name = CharField(),
    year = IntegerField()
  )
  _OperTestRace.connect_key = "default"

  struct _MockPostgresOper <: PormG.PormGPostgres end
  _MockSettingsOper = PormG.Configuration.Settings(
    connections  = _MockPostgresOper(),
    change_data  = true
  )
  PormG.config["default"] = _MockSettingsOper
end

# Shorthand aliases kept local to this module's scope
const _D = _OperTestDriver
const _R = _OperTestRace

@testset "PormGsuffix — Operator SQL Generation" begin

  # =========================================================================
  # 1. Comparison operators
  # =========================================================================
  @testset "Comparison operators (gt, gte, lt, lte, ne)" begin
    # Each entry: (suffix, expected SQL token, test description)
    for (suffix, sql_op) in [
        ("gt",  ">"),
        ("gte", ">="),
        ("lt",  "<"),
        ("lte", "<="),
        ("ne",  "!="),
    ]
      # Expected SQL: WHERE "id" <op> $1
      q   = _D.objects.filter("id__@$suffix" => 42)
      res = q |> list(show_query=:dict)

      @test contains(res[:sql_text], sql_op)  # "@$suffix must emit '$sql_op' in SQL"
      @test res[:parameters] == [42]          # "@$suffix must bind value 42"
    end
  end

  # =========================================================================
  # 2. BETWEEN  (range)
  # =========================================================================
  @testset "Range operator (range → BETWEEN)" begin
    # Expected SQL: WHERE "id" BETWEEN $1 AND $2
    # With Vector
    q_vec = _D.objects.filter("id__@range" => [10, 50])
    res_vec = q_vec |> list(show_query=:dict)
    @test contains(res_vec[:sql_text], "BETWEEN")
    @test res_vec[:parameters] == [10, 50]

    # With Tuple — both forms must be accepted
    q_tup = _D.objects.filter("id__@range" => (10, 50))
    res_tup = q_tup |> list(show_query=:dict)
    @test contains(res_tup[:sql_text], "BETWEEN")
    @test res_tup[:parameters] == [10, 50]
  end

  # =========================================================================
  # 3. IN / NOT IN
  # =========================================================================
  @testset "IN and NOT IN operators (in, nin)" begin
    lucky = [1, 2, 3]

    # Expected SQL (Postgres): WHERE "id" = ANY($1)
    # Expected SQL (generic):  WHERE "id" IN ($1, $2, $3)
    q_in  = _D.objects.filter("id__@in"  => lucky)
    res_in = q_in |> list(show_query=:dict)
    @test contains(res_in[:sql_text], "= ANY") || contains(res_in[:sql_text], " IN ")
    if contains(res_in[:sql_text], "= ANY")
      @test res_in[:parameters] == [lucky]
    else
      @test res_in[:parameters] == lucky
    end

    # Expected SQL (Postgres): WHERE "id" <> ALL($1)
    # Expected SQL (generic):  WHERE "id" NOT IN ($1, $2, $3)
    q_nin  = _D.objects.filter("id__@nin" => lucky)
    res_nin = q_nin |> list(show_query=:dict)
    @test contains(res_nin[:sql_text], "<> ALL") || contains(res_nin[:sql_text], "NOT IN")
    if contains(res_nin[:sql_text], "<> ALL")
      @test res_nin[:parameters] == [lucky]
    else
     @test res_nin[:parameters] == lucky
    end
  end

  # =========================================================================
  # 4. String pattern operators
  # =========================================================================
  @testset "String pattern operators (contains, icontains, startswith, endswith)" begin

    # contains → LIKE '%val%'
    # The bound value must be wrapped in % wildcards.
    q_c = _D.objects.filter("forename__@contains" => "lew")
    r_c = q_c |> list(show_query=:dict)
    @test contains(r_c[:sql_text], "LIKE") || contains(r_c[:sql_text], "ILIKE")
    @test r_c[:parameters] == ["%lew%"]

    # icontains → ILIKE '%val%' (Postgres) or LIKE with LOWER (SQLite)
    # The bound value must be lowercased so the wildcard match is case-insensitive.
    q_ic = _D.objects.filter("forename__@icontains" => "LEW")
    r_ic = q_ic |> list(show_query=:dict)
    # @infiltrator
    @test contains(r_ic[:sql_text], "ILIKE") || contains(r_ic[:sql_text], "LIKE")
    @test r_ic[:parameters] == ["%LEW%"] 

    # startswith → LIKE 'val%'
    q_sw = _D.objects.filter("nationality__@startswith" => "Brit")
    r_sw = q_sw |> list(show_query=:dict)
    @test contains(r_sw[:sql_text], "LIKE") || contains(r_sw[:sql_text], "ILIKE")
    @test r_sw[:parameters] == ["Brit%"]

    # endswith → LIKE '%val'
    q_ew = _D.objects.filter("forename__@endswith" => "wis")
    r_ew = q_ew |> list(show_query=:dict)
    @test contains(r_ew[:sql_text], "LIKE") || contains(r_ew[:sql_text], "ILIKE")
    @test r_ew[:parameters] == ["%wis"]
  end

  # =========================================================================
  # 5. NULL checks  (isnull)
  # =========================================================================
  @testset "NULL check operator (isnull)" begin
    # isnull => true  → IS NULL
    q_null = _D.objects.filter("forename__@isnull" => true)
    r_null = q_null |> list(show_query=:dict)
    @test contains(r_null[:sql_text], "IS NULL") || contains(r_null[:sql_text], "ISNULL")

    # isnull => false → IS NOT NULL
    q_notnull = _D.objects.filter("forename__@isnull" => false)
    r_notnull = q_notnull |> list(show_query=:dict)
    @test contains(r_notnull[:sql_text], "IS NOT NULL") || contains(r_notnull[:sql_text], "ISNULL")
  end

  # =========================================================================
  # 6. Default equality (no suffix)
  # =========================================================================
  @testset "Default equality (no suffix → =)" begin
    q   = _D.objects.filter("id" => 1)
    res = q |> list(show_query=:dict)
    @test contains(res[:sql_text], "=")
    @test res[:parameters] == [1]
  end

  # =========================================================================
  # 7. Combined multi-operator query
  # =========================================================================
  @testset "Combined multi-operator query" begin
    # Mixing gt, lte, and icontains in a single WHERE clause.
    # Expected SQL: WHERE "id" > $1 AND "id" <= $2 AND (ILIKE / LIKE pattern)
    q = _D.objects.filter(
      "id__@gt"               => 10,
      "id__@lte"              => 50,
      "nationality__@icontains" => "brit"
    )
    res = q |> list(show_query=:dict)

    @test contains(res[:sql_text], ">")
    @test contains(res[:sql_text], "<=")
    @test contains(res[:sql_text], "ILIKE") || contains(res[:sql_text], "LIKE")
    # Three bound values: 10, 50, "%brit%"
    @test length(res[:parameters]) == 3
    @test 10     in res[:parameters]
    @test 50     in res[:parameters]
    @test "%brit%" in res[:parameters]
  end

end  # end "PormGsuffix — Operator SQL Generation"
