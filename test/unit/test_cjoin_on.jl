# ==============================================================================
# UNIT TESTS: cjoin_on — anchor-less full-control custom joins (#45)
#
# cjoin_on lets a query express a JOIN whose ON clause is ENTIRELY user-defined:
# arbitrary boolean (top-level OR), field-to-field comparisons across BOTH sides
# (self-joins), and SQL functions (year-extraction) in the ON — without raw SQL.
#
# Reference convention inside `on`:  bare F("col") = base/main table;
# Joined("<alias>", "col") = the joined copy declared by cjoin_on (#481).
#
# The target is a model OBJECT or its name (#488): the two spellings share one implementation and
# render identically, which the #488 testsets at the bottom pin.
#
# DB-free: mock connections subtype PormGPostgres/PormGSQLite; assertions inspect
# the rendered SQL + parameter buckets via show_query=:dict (same pattern as
# test_many_to_many.jl). PostgreSQL and SQLite modules exist so the dialect-specific
# function rendering (EXTRACT vs strftime) is checked on both.
# ==============================================================================

using Test
using PormG
import PormG.QueryBuilder: F, Q, Qor, Joined, Exists, OuterRef
import PormG.Functions: Count, Max

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

# ─────────────────────────────────────────────────────────────────────────────
# #174: the #74 fan-out guard sees a cjoin_on join
# A self-join on `raceid` pairs each lap with every lap of its race, so COUNT over a base column counts
# each base row once per match. The row is to-many unless its ON clause proves otherwise
# (`_cjoin_on_to_many`, pinned shape by shape in `test_join_rows.jl`); a pk self-join proves it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the fan-out guard refuses a base aggregate over a to-many cjoin_on (#174) — $(M === PG ? "PG" : "SL")" for M in (PG, SL)
  _render(agg; on = [Joined("b2", "raceid") == F("raceid")]) = begin
    q = M.Lap.objects
    q.cjoin_on("Lap", alias = "b2", on = on)
    q.values("driverid", "n" => agg)
    q.list(show_query = :sql)
  end
  err = try
    _render(Count("id"))
    nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError
  msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
  @test occursin("fan-out guard (#74)", msg)
  @test occursin("cjoin_on alias(es) \"b2\"", msg)

  # The guard's existing exemptions hold for this row kind too, and a proven key is not refused.
  @test occursin("COUNT(DISTINCT", _render(Count("id", distinct = true)))
  @test occursin("COUNT(\"b2\".\"id\")", _render(Count(Joined("b2", "id"))))   # the many side's own column
  @test occursin("MAX(", _render(Max("id")))
  @test occursin("COUNT(\"Tb\".\"id\")", _render(Count("id"); on = [Joined("b2", "id") == F("id")]))
end

# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on target as a model OBJECT (#488): identical rendering to the name form
# The String arm resolves the name and delegates to the object arm, so the two spellings must
# produce byte-identical SQL and the same parameter vector on both dialects. Asserted as equality
# of the two renders, not against a literal — a drift between the arms is the defect this pins.
# ─────────────────────────────────────────────────────────────────────────────
@testset "model-object target renders identically to the model-name form (#488)" begin
  for (label, M) in (("SQLite", SL), ("PostgreSQL", PG))
    @testset "$label" begin
      by_name = M.Lap.objects
      by_name.cjoin_on("Circuit", alias = "c", join_type = "LEFT",
                       on = [Q(Joined("c", "raceid") == F("raceid"), "lap__@gte" => 3)])
      by_name.filter("driverid" => 44)
      by_name.values("id", "track" => Joined("c", "name"))

      by_obj = M.Lap.objects
      by_obj.cjoin_on(M.Circuit, alias = "c", join_type = "LEFT",
                      on = [Q(Joined("c", "raceid") == F("raceid"), "lap__@gte" => 3)])
      by_obj.filter("driverid" => 44)
      by_obj.values("id", "track" => Joined("c", "name"))

      a = by_name.list(show_query = :dict)
      b = by_obj.list(show_query = :dict)
      @test a[:sql_text] == b[:sql_text]
      @test a[:parameters] == b[:parameters]
      # And the shared render is the anchor-less LEFT join. The ON parameter precedes WHERE's in
      # SQLite's flattened vector; PostgreSQL binds joins last and lets `$N` travel with the text,
      # so only the SQLite vector has a fixed order to pin (see "Bound parameter in ON" above).
      @test occursin("LEFT JOIN \"circuits\" AS \"c\" ON", b[:sql_text])
      label == "SQLite" && @test b[:parameters] == [3, 44]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Self-join with the model object (#488) goes through the same alias reservation (#480)
# `q.cjoin_on(M.Lap, …)` on a `Lap` query is the documented self-join spelling now. The joined copy
# renders under the user alias, its columns project through `Joined`, and the base relation's own
# alias is still refused — `_build_cjoin_on_row_join`'s holder check does not care how the target
# was spelled.
# ─────────────────────────────────────────────────────────────────────────────
@testset "self-join with the model object passes the #480 alias reservation (#488)" begin
  q = SL.Lap.objects
  q.cjoin_on(SL.Lap, alias = "b2", on = [Joined("b2", "raceid") == F("raceid")])
  q.values("id", "other" => Joined("b2", "lap"))
  sql = q.list(show_query = :dict)[:sql_text]
  @test occursin("INNER JOIN \"laps\" AS \"b2\" ON (\"b2\".\"raceid\" = \"Tb\".\"raceid\")", sql)
  @test occursin("\"b2\".\"lap\" as \"other\"", sql)

  # The base relation's alias is a range variable the statement already has: refused at build.
  err = try
    q2 = SL.Lap.objects
    q2.cjoin_on(SL.Lap, alias = "Tb", on = [Joined("Tb", "raceid") == F("raceid")])
    q2.values("id")
    q2.list(show_query = :sql)
    nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError
  @test occursin("two range variables cannot share a name", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# A model object registered on ANOTHER connection is refused (#488) — at build time
# The name form can only ever resolve inside the query's own module, but an object can come from
# anywhere. The connection a statement runs on is the `.db("key")` override, else the base model's
# registration — never the target's — so a foreign target would render a table in a different
# database. The check runs when the query is BUILT, because `.db()` may follow the `cjoin_on` call.
# Discriminating pair: the same foreign target is REFUSED without `.db()` and ACCEPTED once `.db()`
# routes the query to the target's connection; the inverse (`.db()` away from a same-module target)
# is refused. An UNREGISTERED model object is not judged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a model object registered on another connection is refused at build (#488)" begin
  # Declaring is fine — nothing is known about the final connection yet.
  q = SL.Lap.objects
  q.cjoin_on(PG.Circuit, alias = "c", on = [Joined("c", "raceid") == F("raceid")])
  q.values("id")
  err = try
    q.list(show_query = :sql)
    nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError
  msg = sprint(showerror, err)
  @test occursin("cjoinon_pg", msg) && occursin("cjoinon_sl", msg)
  @test occursin("cannot cross connections", msg)

  # `.db()` routes the query to the target's connection: accepted, and rendered in THAT dialect
  # (PostgreSQL `$1`, not SQLite `?`), which is exactly why the model's own registration cannot be
  # the rule.
  routed = SL.Lap.objects
  routed.db("cjoinon_pg")
  routed.cjoin_on(PG.Circuit, alias = "c", on = [Q(Joined("c", "raceid") == F("raceid"), "lap__@gte" => 3)])
  routed.values("id")
  sql = routed.list(show_query = :sql)
  @test occursin("INNER JOIN \"circuits\" AS \"c\" ON", sql)
  @test occursin("\$1", sql) && !occursin("?", sql)

  # The inverse: `.db()` away from a same-module target is refused.
  away = SL.Lap.objects
  away.db("cjoinon_pg")
  away.cjoin_on(SL.Circuit, alias = "c", on = [Joined("c", "raceid") == F("raceid")])
  away.values("id")
  away_err = try
    away.list(show_query = :sql)
    nothing
  catch e
    e
  end
  @test away_err isa PormG.QueryBuildError
  @test occursin("cannot cross connections", sprint(showerror, away_err))

  # Unregistered (`connect_key === nothing`): accepted and rendered under its own table name.
  loose = PormG.Models.Model("loose_circuits", id = PormG.Models.IDField(), raceid = PormG.Models.IntegerField())
  q2 = SL.Lap.objects
  q2.cjoin_on(loose, alias = "lc", on = [Joined("lc", "raceid") == F("raceid")])
  q2.values("id")
  @test occursin("INNER JOIN \"loose_circuits\" AS \"lc\" ON", q2.list(show_query = :sql))
end

# Relations for #992: `Result → Driver` forward, `Driver.results` reverse, `Driver.sponsors` ManyToMany.
module CJoinOnRelModels
import PormG
import PormG.Models
Sponsor = Models.Model("sponsor",
  sponsorid = Models.IDField(),
  name = Models.CharField(),
)
Driver = Models.Model("driver",
  driverid = Models.IDField(),
  code = Models.CharField(),
  number = Models.IntegerField(),
  sponsors = Models.ManyToManyField(Sponsor, related_name = "drivers"),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  grid = Models.IntegerField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "cjoinon_sl")
end

const REL = CJoinOnRelModels
_cjoin_on_rel_err(f) = try f(); nothing catch e; e end
_cjoin_on_rel_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on: a to-many path in an ON condition is refused, in every spelling (#992)
# A path a cjoin_on condition names is joined onto the base row before the alias. A reverse or
# ManyToMany hop would repeat each base row once per related row, under any join type and with no
# aggregate for #74's guard to see. The matrix pins the pair-key spelling; this pins `F(...)` and an
# `OuterRef` in an `Exists`, and that the rewrite the message suggests renders.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a reverse or ManyToMany path in a cjoin_on condition is refused (#992)" begin
  anchor = Joined("d2", "driverid") == F("driverid")
  build(cond) = () -> begin
    q = REL.Result.objects
    q.cjoin_on("Driver", alias = "d2", join_type = "LEFT", on = [anchor, cond])
    q.values("resultid")
    q.list(show_query = :sql)
  end

  # A reverse hop on the right of a comparison, spelled as an F.
  err = _cjoin_on_rel_err(build(Joined("d2", "number") == F("driverid__results__grid")))
  @test err isa PormG.FilterError
  msg = _cjoin_on_rel_msg(err)
  @test occursin("F(\"driverid__results__grid\") in the ON clause of cjoin_on alias d2", msg)
  @test occursin("crosses the reverse relation 'driverid__results'", msg)
  @test occursin("per related 'result' row", msg)
  @test occursin("Exists(M.<Related>.objects.filter(", msg)
  # Not a bare `.filter(...)`: a to-many path there joins and repeats rows the same way.
  @test occursin("pass that Exists(...) to .filter(...) instead", msg)
  @test occursin("#992", msg)

  # A ManyToMany hop reached through an OuterRef in a correlated subquery: the outer path is joined
  # onto the base row the same way, so it is refused the same way.
  err = _cjoin_on_rel_err(build(Q(Exists(REL.Sponsor.objects.filter("name" => OuterRef("driverid__sponsors__name"))))))
  @test err isa PormG.FilterError
  @test occursin("crosses the ManyToMany relation 'driverid__sponsors'", _cjoin_on_rel_msg(err))

  # The rewrite: the existence test correlated explicitly. It renders, and the only join to `Result`
  # is inside the subquery — the base row is joined to `d2` alone.
  ok = build(Exists(REL.Result.objects.filter("driverid" => OuterRef("driverid"), "grid" => 1)))()
  @test occursin("LEFT JOIN \"driver\" AS \"d2\"", ok)
  @test occursin("EXISTS", ok)
  @test count("JOIN", ok) == 1

  # The message's other remedy: the same Exists in `.filter(...)` restricts the base rows, with no join.
  where = REL.Result.objects
  where.filter(Exists(REL.Result.objects.filter("driverid" => OuterRef("driverid"), "grid" => 1)))
  where.values("resultid")
  where_sql = where.list(show_query = :sql)
  @test occursin("EXISTS", where_sql)
  @test !occursin("JOIN", where_sql)

  # A forward path is to-one, and still builds before the alias (#982).
  fwd = build("driverid__code" => "X")()
  @test occursin("LEFT JOIN \"driver\" AS \"d2\"", fwd)
end
