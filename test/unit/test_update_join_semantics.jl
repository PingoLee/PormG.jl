# ============================================================
# test/unit/test_update_join_semantics.jl
#
# Which join an `update()` statement runs, and where a join type is refused (#1430, #1431).
#
# CONTRACT being tested:
#   An `update()` whose SET reads a joined column renders a correlated `UPDATE … FROM` (MySQL: the
#   multi-table `UPDATE`), which joins in its WHERE clause and so acts as an INNER join. A LEFT, RIGHT
#   or FULL path join there would skip the rows it was declared to keep, so it is refused on every
#   engine (#1430): explicit intent, the caller names whether a row with no match is skipped (an INNER
#   join) or written NULL (a `Subquery`).
#
# DB-free: mock connections, SQL read through `show_query = :sql`.
#
# Run: julia --project=test/integration test/unit/test_update_join_semantics.jl
# ============================================================

using Test
using PormG
using PormG.Models
import PormG.QueryBuilder: F, Subquery, OuterRef

struct UjMockPostgres <: PormG.PormGPostgres end
struct UjMockSQLite <: PormG.PormGSQLite end
struct UjMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::UjMockSQLite) = 3045000   # the capability table's version rows ask for it

for (key, conn) in (("uj_pg", UjMockPostgres()), ("uj_sl", UjMockSQLite()), ("uj_my", UjMockMySQL()))
  PormG.config[key] = PormG.Configuration.Settings(connections = conn, change_data = true, db_def_folder = key)
end

# One model set per engine, identical: an F1 subset. `Driver.teamid` is a nullable ForeignKey, so a
# path through it joins LEFT by default; `Result.driverid` is not, so it joins INNER.
for (modname, key) in ((:UjPGModels, "uj_pg"), (:UjSLModels, "uj_sl"), (:UjMYModels, "uj_my"))
  @eval module $modname
  import PormG
  import PormG.Models
  Team = Models.Model("team",
    teamid = Models.IDField(),
    name = Models.CharField(),
  )
  Driver = Models.Model("driver",
    driverid = Models.IDField(),
    code = Models.CharField(),
    number = Models.IntegerField(),
    teamid = Models.ForeignKey(Team, on_delete = "SET_NULL", null = true, related_name = "drivers"),
  )
  Result = Models.Model("result",
    resultid = Models.IDField(),
    code = Models.CharField(),
    number = Models.IntegerField(),
    driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

const _UJ_ENGINES = (("PostgreSQL", UjPGModels), ("SQLite", UjSLModels), ("MySQL", UjMYModels))

_uj_err(f) = try; f(); nothing; catch e; e; end
_uj_msg(e) = e isa Exception ? sprint(showerror, e) : ""

# ─────────────────────────────────────────────────────────────────────────────
# update(): a SET read through a nullable ForeignKey is refused on every engine (#1430)
# `F("driverid__teamid__name")` joins `team` LEFT (the key is nullable). UPDATE … FROM would put that
# join's anchor in WHERE, so a result whose driver has no team was not updated, where the LEFT join
# reads its team name as NULL — silently, on every engine. Expected: `QueryBuildError` naming the LEFT
# join and both explicit spellings, before any SQL, on PostgreSQL, SQLite and MySQL alike.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): a SET read through a nullable ForeignKey is refused on every engine (#1430)" begin
  for (engine, M) in _UJ_ENGINES
    err = _uj_err(() -> M.Result.objects.filter("resultid" => 1).
      update("code" => F("driverid__teamid__name"), show_query = :sql))
    @test err isa PormG.QueryBuildError
    msg = _uj_msg(err)
    @test occursin("The LEFT join to \"team\"", msg)
    @test occursin("skip the rows with no match", msg)
    @test occursin("A path through a nullable ForeignKey is joined LEFT", msg)
    # Both remedies are named: an INNER join skips the unmatched rows, a Subquery writes NULL there.
    @test occursin("on(\"<path>\", join_type = \"INNER\")", msg)
    @test occursin("Subquery(", msg) && occursin("OuterRef(", msg)
    @test occursin("#1430", msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# update(): a filter's LEFT join is refused beside a joined SET too (#1430)
# The statement flattens every path join, not only the one SET reads. `name__@isnull => true` is the
# anti-join a flattened (inner) team join cannot match, so the update matched no row at all. Expected:
# `QueryBuildError` naming the team join, on every engine.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): a filter's LEFT join is refused beside a joined SET too (#1430)" begin
  for (engine, M) in _UJ_ENGINES
    err = _uj_err(() -> M.Result.objects.filter("driverid__teamid__name__@isnull" => true).
      update("number" => F("driverid__number"), show_query = :sql))
    @test err isa PormG.QueryBuildError
    @test occursin("The LEFT join to \"team\"", _uj_msg(err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# update(): an explicit RIGHT join is refused in UPDATE … FROM (#1430)
# A declared join type is flattened the same way. RIGHT is a feature of all three engines here, so the
# refusal is the meaning one, and it names the RIGHT join without the nullable-ForeignKey note.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): an explicit RIGHT join is refused in UPDATE … FROM (#1430)" begin
  for (engine, M) in _UJ_ENGINES
    q = M.Result.objects
    q.on("driverid", join_type = "RIGHT")
    q.filter("resultid" => 1)
    err = _uj_err(() -> q.update("number" => F("driverid__number"), show_query = :sql))
    @test err isa PormG.QueryBuildError
    msg = _uj_msg(err)
    @test occursin("The RIGHT join to \"driver\"", msg)
    @test !occursin("nullable ForeignKey", msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# update(): the two spellings the refusal names both build (#1430)
# `on(path, join_type = "INNER")` makes the team join INNER, so UPDATE … FROM means what it says: only
# the results whose driver has a team. A scalar `Subquery` over the same path keeps every row and
# writes NULL where there is no team: no FROM list, the LEFT join inside the subquery. A SET through
# a non-null key (INNER by default) is the control: it still renders UPDATE … FROM.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): the two spellings the refusal names both build (#1430)" begin
  for (engine, M) in _UJ_ENGINES
    q = M.Result.objects
    q.on("driverid__teamid", join_type = "INNER")
    q.filter("resultid" => 1)
    sql = q.update("code" => F("driverid__teamid__name"), show_query = :sql)
    @test occursin("SET ", sql) && occursin("team", sql)
    @test !occursin("EXISTS", sql)   # UPDATE … FROM, not the fence

    sub = Subquery(M.Driver.objects.filter("driverid" => OuterRef("driverid")).values("teamid__name"))
    sql = M.Result.objects.filter("resultid" => 1).update("code" => sub, show_query = :sql)
    @test occursin("LEFT JOIN", sql)              # the subquery keeps its LEFT join
    @test !occursin(r"\)\s*FROM"s, sql)           # no FROM list on the UPDATE itself

    sql = M.Result.objects.filter("resultid" => 1).update("number" => F("driverid__number"), show_query = :sql)
    @test occursin("driver", sql) && !occursin("EXISTS", sql)
  end
end
