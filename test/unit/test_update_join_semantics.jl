# ============================================================
# test/unit/test_update_join_semantics.jl
#
# Which join an `update()` statement runs, and where a join type is refused (#1430, #1431).
#
# CONTRACT being tested:
#   An `update()` whose SET reads a joined column renders a correlated `UPDATE … FROM` (MySQL: the
#   multi-table `UPDATE`), which joins in its WHERE clause and so acts as an INNER join. A LEFT or FULL
#   path join there would skip the rows it was declared to keep, so it is refused on every engine
#   (#1430): explicit intent, the caller names whether a row with no match is skipped (an INNER join)
#   or written NULL (a `Subquery`). A RIGHT join keeps only rows the target is NULL in, which no UPDATE
#   writes, so it runs as the INNER join it means here.
#   A RIGHT or FULL join is a capability row (#1422), refused where the statement prints the join type.
#   `update()` prints it only in a keyed model's key selection: a keyless model's fence rewrites it to
#   INNER/LEFT, so that update builds on a backend without the feature (#1431).
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
struct UjMockSQLite338 <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::UjMockSQLite) = 3045000   # the capability table's version rows ask for it
PormG.backend_sqlite_version(::UjMockSQLite338) = 3038000   # before RIGHT and FULL JOIN (3.39.0)

for (key, conn) in (("uj_pg", UjMockPostgres()), ("uj_sl", UjMockSQLite()), ("uj_my", UjMockMySQL()),
                    ("uj_sl338", UjMockSQLite338()))
  PormG.config[key] = PormG.Configuration.Settings(connections = conn, change_data = true, db_def_folder = key)
end

# One model set per engine, identical: an F1 subset. `Driver.teamid` is a nullable ForeignKey, so a
# path through it joins LEFT by default; `Result.driverid` is not, so it joins INNER. `Pit_stop` has no
# primary key, so a joined update of it takes the EXISTS fence alone.
for (modname, key) in ((:UjPGModels, "uj_pg"), (:UjSLModels, "uj_sl"), (:UjMYModels, "uj_my"),
                       (:UjSL338Models, "uj_sl338"))
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
  Pit_stop = Models.Model("pit_stop",
    driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "pit_stops"),
    milliseconds = Models.IntegerField(),
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
# update(): an explicit FULL join is refused in UPDATE … FROM, a RIGHT one runs as INNER (#1430)
# A declared join type is flattened the same way. FULL keeps a result with no driver, so flattened it
# skips that row: refused, naming the FULL join without the nullable-ForeignKey note. RIGHT keeps only
# a driver with no result, a row the target side is NULL in, which no UPDATE writes, so it updates
# exactly the rows INNER does: it builds, the FROM list carrying no join type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): an explicit FULL join is refused in UPDATE … FROM, a RIGHT one runs as INNER (#1430)" begin
  for (engine, M) in _UJ_ENGINES
    q = M.Result.objects
    q.on("driverid", join_type = "FULL")
    q.filter("resultid" => 1)
    err = _uj_err(() -> q.update("number" => F("driverid__number"), show_query = :sql))
    @test err isa PormG.QueryBuildError
    msg = _uj_msg(err)
    @test occursin("The FULL join to \"driver\"", msg)
    @test !occursin("nullable ForeignKey", msg)

    q = M.Result.objects
    q.on("driverid", join_type = "RIGHT")
    q.filter("resultid" => 1)
    sql = q.update("number" => F("driverid__number"), show_query = :sql)
    @test occursin("driver", sql) && !occursin("RIGHT", sql) && !occursin("EXISTS", sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# update(): an OuterRef path in a SET Subquery adds an INNER outer join, so UPDATE … FROM (#1430, #1414)
# `Subquery(Driver.filter("code" => OuterRef("driverid__code"))…)` joins `driver` on the OUTER statement
# while SET renders. `Result.driverid` is not nullable, so that join is INNER and the statement builds
# as UPDATE … FROM (MySQL: the multi-table UPDATE). This is the shape #1414's set-reads record exists
# for, kept here on a non-null key now that a nullable one is refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): an OuterRef path in a SET Subquery adds an INNER outer join, so UPDATE … FROM (#1430, #1414)" begin
  for (engine, M) in _UJ_ENGINES
    s = M.Driver.objects
    s.filter("code" => OuterRef("driverid__code"))
    s.values("number")
    s.limit(1)
    sql = M.Result.objects.filter("resultid" => 1).update("number" => Subquery(s), show_query = :sql)
    @test !occursin("EXISTS", sql) && !occursin("IN (SELECT", sql)
    @test occursin(engine == "MySQL" ? "`result` AS `Tb`, `driver` AS `Tb_1`" : "FROM \"driver\" AS \"Tb_1\"", sql)
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

# The backends without a feature, and which of the two join types each lacks.
const _UJ_LACKING = (("SQLite 3.38", UjSL338Models, ("RIGHT", "FULL")), ("MySQL", UjMYModels, ("FULL",)))

# ─────────────────────────────────────────────────────────────────────────────
# update(): a keyless model's fence never prints RIGHT or FULL, so it builds without them (#1431)
# A keyless model's constant-SET update takes `EXISTS (SELECT 1 FROM (SELECT 1) AS "__pormg_anchor" …)`,
# which rewrites RIGHT to INNER and FULL to LEFT, so the engine is never asked for an outer join.
# #1422 refused it on SQLite < 3.39.0 and MySQL anyway. Expected: it builds there, its SQL carrying the
# rewritten join and not the declared one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): a keyless model's fence never prints RIGHT or FULL, so it builds without them (#1431)" begin
  for (engine, M, lacking) in _UJ_LACKING, how in lacking
    q = M.Pit_stop.objects
    q.on("driverid", join_type = how)
    q.filter("driverid__code" => "HAM")
    sql = q.update("milliseconds" => 0, show_query = :sql)
    @test occursin("__pormg_anchor", sql)
    @test occursin(how == "RIGHT" ? "INNER JOIN" : "LEFT JOIN", sql)
    @test !occursin("$(how) JOIN", sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# update(): a keyed model's key selection prints the join type, so it is still refused (#1431)
# `"Tb"."resultid" IN (SELECT DISTINCT … <how> JOIN …)` prints the join as declared, so the backend
# must have it: `BackendCapabilityError` on SQLite < 3.39.0 and MySQL, before any SQL. The same holds
# for a `delete()`, whose key selection prints it too. MySQL has RIGHT JOIN, so there it builds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): a keyed model's key selection prints the join type, so it is still refused (#1431)" begin
  for (engine, M, lacking) in _UJ_LACKING, how in lacking
    q = M.Result.objects
    q.on("driverid", join_type = how)
    q.filter("driverid__code" => "HAM")
    err = _uj_err(() -> q.update("number" => 0, show_query = :sql))
    @test err isa PormG.BackendCapabilityError
    @test occursin("join_type = \"$(how)\"", _uj_msg(err))

    q = M.Result.objects
    q.on("driverid", join_type = how)
    q.filter("driverid__code" => "HAM")
    @test _uj_err(() -> q.delete(show_query = :sql)) isa PormG.BackendCapabilityError
  end
  q = UjMYModels.Result.objects
  q.on("driverid", join_type = "RIGHT")
  q.filter("driverid__code" => "HAM")
  @test occursin("RIGHT JOIN", q.update("number" => 0, show_query = :sql))
end

# ─────────────────────────────────────────────────────────────────────────────
# update(): a joined SET never asks for RIGHT or FULL: FULL is refused for its meaning, RIGHT builds (#1431)
# UPDATE … FROM joins through its FROM list and WHERE, so it never prints a join type. A FULL join there
# is refused on every engine (#1430), so on a backend without FULL the caller learns that, not that a
# newer library would help: upgrading would only move the error. A RIGHT join runs as the INNER join it
# means here, so it builds on SQLite 3.38. Expected: `QueryBuildError` that is not a
# `BackendCapabilityError` for FULL; SQL with no RIGHT JOIN for RIGHT.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update(): a joined SET never asks for RIGHT or FULL: FULL is refused for its meaning, RIGHT builds (#1431)" begin
  for (engine, M, lacking) in _UJ_LACKING, how in lacking
    q = M.Result.objects
    q.on("driverid", join_type = how)
    q.filter("resultid" => 1)
    if how == "RIGHT"
      @test !occursin("RIGHT", q.update("number" => F("driverid__number"), show_query = :sql))
      continue
    end
    err = _uj_err(() -> q.update("number" => F("driverid__number"), show_query = :sql))
    @test err isa PormG.QueryBuildError
    @test !(err isa PormG.BackendCapabilityError)
    @test occursin("The $(how) join to \"driver\"", _uj_msg(err))
  end
end
