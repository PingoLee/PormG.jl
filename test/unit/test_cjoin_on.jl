# ==============================================================================
# UNIT TESTS: cjoin_on — anchor-less full-control custom joins (#45)
#
# cjoin_on lets a query express a JOIN whose ON clause is ENTIRELY user-defined:
# arbitrary boolean (top-level OR), field-to-field comparisons across BOTH sides
# (self-joins), and SQL functions (year-extraction) in the ON — without raw SQL.
#
# Reference convention inside `on`:  bare F("col") = base/main table;
# F("<alias>.col") = the joined copy declared by cjoin_on.
#
# DB-free: mock connections subtype PormGPostgres/PormGSQLite; assertions inspect
# the rendered SQL + parameter buckets via show_query=:dict (same pattern as
# test_many_to_many.jl). PostgreSQL and SQLite modules exist so the dialect-specific
# function rendering (EXTRACT vs strftime) is checked on both.
# ==============================================================================

using Test
using PormG
import PormG.QueryBuilder: F, Q, Qor, Joined

struct CJoinOnMockPG <: PormG.PormGPostgres end
struct CJoinOnMockSL <: PormG.PormGSQLite end

PormG.config["cjoinon_pg"] = PormG.Configuration.Settings(
  connections = CJoinOnMockPG(), change_data = true, db_def_folder = "cjoinon_pg")
PormG.config["cjoinon_sl"] = PormG.Configuration.Settings(
  connections = CJoinOnMockSL(), change_data = true, db_def_folder = "cjoinon_sl")

# Identical F1-flavored models under each backend so query rendering can be checked per-dialect.
module CJoinOnPGModels
import PormG
import PormG.Models
Lap = Models.Model("laps",
  id = Models.IDField(),
  raceid = Models.IntegerField(),
  driverid = Models.IntegerField(),
  lap = Models.IntegerField(),
  position = Models.IntegerField(null = true),
  dt = Models.DateField(null = true),
)
Circuit = Models.Model("circuits",
  id = Models.IDField(),
  raceid = Models.IntegerField(),
  name = Models.CharField(),
)
PormG.Models.set_models(@__MODULE__, "cjoinon_pg")
end

module CJoinOnSLModels
import PormG
import PormG.Models
Lap = Models.Model("laps",
  id = Models.IDField(),
  raceid = Models.IntegerField(),
  driverid = Models.IntegerField(),
  lap = Models.IntegerField(),
  position = Models.IntegerField(null = true),
  dt = Models.DateField(null = true),
)
Circuit = Models.Model("circuits",
  id = Models.IDField(),
  raceid = Models.IntegerField(),
  name = Models.CharField(),
)
PormG.Models.set_models(@__MODULE__, "cjoinon_sl")
end

const PG = CJoinOnPGModels
const SL = CJoinOnSLModels

@testset "Anchor-less self-join: no equi-anchor, top-level OR, cross-side F (SQLite)" begin
  q = SL.Lap.objects
  q.cjoin_on("Lap", alias = "b2", on = [
    Qor(
      Joined("b2", "raceid") == F("raceid"),
      Q(Joined("b2", "driverid") == F("driverid"), Joined("b2", "lap") == F("lap")),
    ),
  ], join_type = "INNER")
  q.values("id")
  insp = q.list(show_query = :dict)
  sql = insp[:sql_text]

  # Self-join: laps AS "b2" joined to the base laps AS "Tb".
  @test occursin("INNER JOIN \"laps\" AS \"b2\" ON", sql)
  # No equi-anchor was injected (the ON is only the user's OR expression).
  @test !occursin("\"Tb\".\"id\" = \"b2\"", sql)
  # Top-level OR of groups, cross-side (b2 = joined copy, Tb = base/main).
  @test occursin("\"b2\".\"raceid\" = \"Tb\".\"raceid\"", sql)
  @test occursin(" OR ", sql)
  @test occursin("\"b2\".\"driverid\" = \"Tb\".\"driverid\"", sql)
  @test occursin("\"b2\".\"lap\" = \"Tb\".\"lap\"", sql)
  # Field-to-field comparisons bind no parameters.
  @test isempty(insp[:parameters])
end

@testset "Two cjoin_on to the SAME target model both survive (no dedup collision)" begin
  # Anchor-less entries share key_a/key_b, and _insert_join's dedup ignores alias_b — so both joins
  # to the same table must be distinguished (by the unique alias) or one is silently dropped.
  q = SL.Lap.objects
  q.cjoin_on("Lap", alias = "b2", on = [Joined("b2", "raceid") == F("raceid")])
  q.cjoin_on("Lap", alias = "b3", on = [Joined("b3", "driverid") == F("driverid")])
  q.values("id")
  sql = q.list(show_query = :dict)[:sql_text]
  @test occursin("AS \"b2\" ON", sql)
  @test occursin("AS \"b3\" ON", sql)
end

@testset "Non-self join to a different model + INNER default" begin
  q = SL.Lap.objects
  # No join_type ⇒ defaults to INNER; join a different table, correlate on a base column.
  q.cjoin_on("Circuit", alias = "c", on = [Joined("c", "raceid") == F("raceid")])
  q.values("id")
  sql = q.list(show_query = :dict)[:sql_text]
  @test occursin("INNER JOIN \"circuits\" AS \"c\" ON", sql)
  @test occursin("\"c\".\"raceid\" = \"Tb\".\"raceid\"", sql)
end

@testset "Bound parameter in ON routes to the :join bucket, before WHERE" begin
  q = SL.Lap.objects
  # A base-side operator predicate (bare `lap` = main table) binds a value inside the ON. Combined
  # with cross-side F, it proves ON params land in the :join bucket, ahead of WHERE params.
  q.cjoin_on("Lap", alias = "b2", on = [
    Q(Joined("b2", "raceid") == F("raceid"), "lap__@gte" => 3),
  ])
  q.filter("driverid" => 44)
  q.values("id")
  insp = q.list(show_query = :dict)
  # The ON's bound value (3) precedes the WHERE's (44): join bucket flattens before where.
  @test insp[:parameters] == [3, 44]
  @test occursin("\"Tb\".\"lap\"", insp[:sql_text])
end

@testset "SQL function (year) in ON — SQLite strftime" begin
  q = SL.Lap.objects
  q.cjoin_on("Lap", alias = "b2", on = [Joined("b2", "dt__@year") == F("dt__@year")])
  q.values("id")
  sql = q.list(show_query = :dict)[:sql_text]
  @test occursin("strftime('%Y', \"b2\".\"dt\")", sql)
  @test occursin("strftime('%Y', \"Tb\".\"dt\")", sql)
end

@testset "SQL function (year) in ON — PostgreSQL EXTRACT (dialect divergence)" begin
  q = PG.Lap.objects
  q.cjoin_on("Lap", alias = "b2", on = [Joined("b2", "dt__@year") == F("dt__@year")])
  q.values("id")
  sql = q.list(show_query = :dict)[:sql_text]
  @test occursin("EXTRACT(YEAR FROM \"b2\".\"dt\")", sql)
  @test occursin("EXTRACT(YEAR FROM \"Tb\".\"dt\")", sql)
end

@testset "Validation" begin
  # Unknown target model.
  @test_throws PormGError SL.Lap.objects.cjoin_on("Nope", alias = "b2", on = [Joined("b2", "raceid") == F("raceid")])
  # Duplicate alias.
  @test_throws PormGError begin
    q = SL.Lap.objects
    q.cjoin_on("Lap", alias = "b2", on = [Joined("b2", "raceid") == F("raceid")])
    q.cjoin_on("Circuit", alias = "b2", on = [Joined("b2", "raceid") == F("raceid")])
  end
  # Invalid alias identifier (fail-closed).
  @test_throws PormGError SL.Lap.objects.cjoin_on("Lap", alias = "b2; DROP", on = [Joined("b2", "raceid") == F("raceid")])
  # Empty ON list.
  @test_throws PormGError SL.Lap.objects.cjoin_on("Lap", alias = "b2", on = [])
  # Unknown column on the aliased model surfaces at render time.
  @test_throws PormGError begin
    q = SL.Lap.objects
    q.cjoin_on("Lap", alias = "b2", on = [Joined("b2", "nonexistent") == F("raceid")])
    q.values("id")
    q.list(show_query = :sql)
  end
end

@testset "cjoin_on works in the common update path (subquery-scoped)" begin
  # A plain update filters rows via a subquery (WHERE pk IN (SELECT … JOIN …)); that subquery renders
  # the cjoin_on join correctly (anchor-less), so ON conditions are NOT dropped.
  q = PG.Lap.objects
  q.cjoin_on("Lap", alias = "b2", on = [Joined("b2", "raceid") == F("raceid")])
  q.filter("driverid" => 1)
  sql = q.update("position" => 0, show_query = :sql)
  @test occursin("INNER JOIN \"laps\" AS \"b2\" ON (\"b2\".\"raceid\" = \"Tb\".\"raceid\")", sql)
end
