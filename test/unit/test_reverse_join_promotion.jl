"""
Unit coverage for #1367: a to-many hop that an OR arm or an `__@isnull => true` test reaches is a
`LEFT JOIN`, so the parent with no row across the relation still matches.

A reverse hop took its join type from the CHILD's foreign key: a NOT NULL key gave an `INNER JOIN`. That
key says whether a child can lack a parent, never whether a parent can lack children, and the INNER join
dropped every childless parent before the WHERE clause ran. Two shapes returned too few rows:

  - `filter("results__id__@isnull" => true)`, the anti-join, matched no parent at all;
  - `filter(Qor("name" => "Spa", "results__grid" => 1))` missed Spa, a race with no result, although
    its own column matches the first arm.

A ManyToMany hop was INNER whatever the shape, so it had the same two defects. Now a reverse or a
ManyToMany hop that such a leaf reaches is promoted to LEFT at the end of the join build, and the hops
after it follow (a LEFT parent makes a LEFT child, as at build). A plain AND filter keeps its INNER join,
and a join type stated with `on(path, join_type = …)` is kept as stated. Django promotes the same joins
(`Query.promote_joins`).

The SQL is read on SQLite and PostgreSQL mocks; the rows are executed on a temp SQLite file. The defect is
in the join type, decided before rendering, so it is the same on every engine.
"""
# julia --project=test/integration -e 'include("test/load_drivers.jl"); include("test/unit/test_reverse_join_promotion.jl")'

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, Q, Qor, Case, When
using PormG.Functions: Max
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

struct RjMockSQLite <: PormG.PormGSQLite end
struct RjMockPostgres <: PormG.PormGPostgres end
PormG.backend_sqlite_version(::RjMockSQLite) = 3045000

const _RJ_DIR  = mktempdir()
const _RJ_POOL = SQLiteConnectionPool(joinpath(_RJ_DIR, "rj1367.sqlite"); pool_size = 1)
PormG.config["rj1367_sqlite"] = PormG.Configuration.Settings(
  connections = _RJ_POOL, db_def_folder = "rj1367_sqlite", change_data = true)

# The F1 shape in miniature. From a race: `results` is a reverse relation over a NOT NULL key (the case
# the issue names), `report` a reverse OneToOne, `sponsors` a ManyToMany. A result reaches its driver
# through a NOT NULL forward key, the hop that must follow a promoted reverse one.
module RjModels
import PormG
import PormG.Models
Rj_driver  = Models.Model("rj_driver", id = Models.IDField(), code = Models.CharField())
Rj_sponsor = Models.Model("rj_sponsor", id = Models.IDField(), name = Models.CharField())
Rj_race = Models.Model("rj_race",
  id       = Models.IDField(),
  name     = Models.CharField(),
  sponsors = Models.ManyToManyField(Rj_sponsor, related_name = "races"),
)
Rj_result = Models.Model("rj_result",
  id     = Models.IDField(),
  race   = Models.ForeignKey(Rj_race, on_delete = "CASCADE", related_name = "results"),
  driver = Models.ForeignKey(Rj_driver, on_delete = "CASCADE", related_name = "results"),
  grid   = Models.IntegerField(),
)
Rj_report = Models.Model("rj_report",
  id   = Models.IDField(),
  race = Models.OneToOneField(Rj_race, on_delete = "CASCADE", related_name = "report"),
  body = Models.CharField(),
)
PormG.Models.set_models(@__MODULE__, "rj1367_sqlite")
end

const RJ = RjModels

function _rj_reset!()
  for t in ("rj_report", "rj_result", "rj_race_sponsors", "rj_race", "rj_sponsor", "rj_driver")
    fetch(_RJ_POOL, "DROP TABLE IF EXISTS $(t);")
  end
  fetch(_RJ_POOL, "CREATE TABLE rj_driver (id INTEGER PRIMARY KEY, code TEXT NOT NULL);")
  fetch(_RJ_POOL, "CREATE TABLE rj_sponsor (id INTEGER PRIMARY KEY, name TEXT NOT NULL);")
  fetch(_RJ_POOL, "CREATE TABLE rj_race (id INTEGER PRIMARY KEY, name TEXT NOT NULL);")
  fetch(_RJ_POOL, "CREATE TABLE rj_race_sponsors (id INTEGER PRIMARY KEY, rj_race_id INTEGER NOT NULL REFERENCES rj_race (id), rj_sponsor_id INTEGER NOT NULL REFERENCES rj_sponsor (id));")
  fetch(_RJ_POOL, "CREATE TABLE rj_result (id INTEGER PRIMARY KEY, race INTEGER NOT NULL REFERENCES rj_race (id), driver INTEGER NOT NULL REFERENCES rj_driver (id), grid INTEGER NOT NULL);")
  fetch(_RJ_POOL, "CREATE TABLE rj_report (id INTEGER PRIMARY KEY, race INTEGER NOT NULL UNIQUE REFERENCES rj_race (id), body TEXT NOT NULL);")
  # Races 1 and 2 have results, a report and a sponsor. Race 3, Spa, has none of the three: it is the
  # parent every OR arm and every anti-join below must still see.
  fetch(_RJ_POOL, "INSERT INTO rj_driver (id, code) VALUES (1, 'SEN'), (2, 'PRO');")
  fetch(_RJ_POOL, "INSERT INTO rj_sponsor (id, name) VALUES (1, 'Acme');")
  fetch(_RJ_POOL, "INSERT INTO rj_race (id, name) VALUES (1, 'Monaco'), (2, 'Monza'), (3, 'Spa');")
  fetch(_RJ_POOL, "INSERT INTO rj_race_sponsors (rj_race_id, rj_sponsor_id) VALUES (1, 1), (2, 1);")
  fetch(_RJ_POOL, "INSERT INTO rj_result (id, race, driver, grid) VALUES (10, 1, 1, 1), (11, 1, 2, 5), (20, 2, 2, 5);")
  fetch(_RJ_POOL, "INSERT INTO rj_report (id, race, body) VALUES (100, 1, 'wet'), (200, 2, 'dry');")
  return nothing
end

# A race query shaped by `f`, reading the distinct race ids: `distinct()` is what lets a filter cross a
# to-many relation at all (#1002), and it is the shape a caller writes for these filters.
function _rj_races(f)
  q = RJ.Rj_race.objects
  f(q)
  q.values("id").distinct().order_by("id")
  return q
end
_rj_ids(f) = [r[:id] for r in _rj_races(f).list()]
# The statement on a mock engine, with runs of whitespace collapsed (the join text carries doubled
# spaces). Only the join clause is asserted, so the rest of the statement stays free to change.
_rj_sql(f, conn) = replace(inspect_query(_rj_races(f); connection = conn)[:sql_text], r"\s+" => " ")
const _RJ_ENGINES = (("SQLite", RjMockSQLite()), ("PostgreSQL", RjMockPostgres()))

try
_rj_reset!()

# ─────────────────────────────────────────────────────────────────────────────
# The issue's repro: `__@isnull => true` through a reverse relation over a NOT NULL key
# Expected `LEFT JOIN "rj_result"`; before #1367 it was `INNER JOIN "rj_result"`, which keeps only the
# races that HAVE a result and so can never see a NULL result id: the anti-join matched nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "__@isnull => true through a reverse relation matches the parent with no child (#1367)" begin
  f = q -> q.filter("results__id__@isnull" => true)
  for (engine, conn) in _RJ_ENGINES
    @test occursin("LEFT JOIN \"rj_result\" AS \"Tb_1\"", _rj_sql(f, conn))
  end
  @test _rj_ids(f) == [3]                           # Spa, the race with no result
end

# ─────────────────────────────────────────────────────────────────────────────
# An OR of an own-column arm and an arm across the reverse relation
# Expected `LEFT JOIN "rj_result"`: Spa matches `name = 'Spa'` and has no result. Before #1367 the INNER
# join dropped Spa before the OR was evaluated, so only Monaco (grid 1) came back.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a Qor arm across a reverse relation keeps the parent the other arm matches (#1367)" begin
  f = q -> q.filter(Qor("name" => "Spa", "results__grid" => 1))
  for (engine, conn) in _RJ_ENGINES
    @test occursin("LEFT JOIN \"rj_result\" AS \"Tb_1\"", _rj_sql(f, conn))
  end
  @test _rj_ids(f) == [1, 3]
end

# The same OR nested in a Q: the arm is still an OR arm, wherever the OR sits.
@testset "a Qor nested in a Q promotes the reverse join it reaches (#1367)" begin
  f = q -> q.filter(Q("id__@gte" => 2, Qor("name" => "Spa", "results__grid" => 5)))
  @test occursin("LEFT JOIN \"rj_result\"", _rj_sql(f, RjMockSQLite()))
  @test _rj_ids(f) == [2, 3]
end

# ─────────────────────────────────────────────────────────────────────────────
# The same OR inside a `When`, inside a WHERE filter
# `filter(Case([When(Qor(…), then = 1)], default = 0) == 1)` renders the OR through the expression walk,
# not the WHERE walk, and asks the same question of Spa. Expected `LEFT JOIN "rj_result"` and Spa back;
# found in review of #1367, where only the WHERE walk's OR was promoted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a Qor inside a When in a WHERE filter promotes the reverse join (#1367)" begin
  f = q -> q.filter(Case([When(Qor("name" => "Spa", "results__grid" => 1), then = 1)], default = 0) == 1)
  for (engine, conn) in _RJ_ENGINES
    @test occursin("LEFT JOIN \"rj_result\" AS \"Tb_1\"", _rj_sql(f, conn))
  end
  @test _rj_ids(f) == [1, 3]
end

# Control: the same `When(Qor(…))` in a PROJECTION reads the rows the query already has, and filters
# none, so the join the projection builds keeps its derived type.
@testset "a Qor inside a When in values() keeps the projection's INNER join (#1367)" begin
  q = RJ.Rj_race.objects
  q.values("id", "pole_or_spa" => Case([When(Qor("name" => "Spa", "results__grid" => 1), then = 1)], default = 0))
  sql = replace(inspect_query(q; connection = RjMockSQLite())[:sql_text], r"\s+" => " ")
  @test occursin("INNER JOIN \"rj_result\" AS \"Tb_1\"", sql)
  @test !occursin("LEFT JOIN", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# Control: HAVING on an aggregate alias promotes nothing
# HAVING filters the groups the query already has; it never decides which rows a join drops. A HAVING
# predicate on `n` renders the alias's aggregate afresh, and the aggregate's argument — a `When` over a
# Qor, or over `__@isnull => true` — renders at row phase inside the filter walk. Found in the delta
# review of #1367: that turned the projection's join LEFT, so adding `filter("n__@gt" => 0)` made Spa a
# group and returned it. Expected: the projection's `INNER JOIN "rj_result"`, with or without HAVING.
# ─────────────────────────────────────────────────────────────────────────────
@testset "HAVING on an aggregate alias over a Qor or __@isnull => true keeps the INNER join (#1367)" begin
  whens = (When(Qor("name" => "Spa", "results__grid" => 1), then = 1), When("results__id__@isnull" => true, then = 1))
  grouped(w) = () -> begin
    q = RJ.Rj_race.objects
    q.values("id", "n" => Max(Case([w], default = 0))).filter("n__@gt" => 0).order_by("id")
    q
  end
  for w in whens, (engine, conn) in _RJ_ENGINES
    sql = replace(inspect_query(grouped(w)(); connection = conn)[:sql_text], r"\s+" => " ")
    @test occursin("INNER JOIN \"rj_result\" AS \"Tb_1\"", sql)
    @test occursin("HAVING", sql)
    @test !occursin("LEFT JOIN", sql)
  end
  # Only Monaco has a pole result; Spa has no result, so it forms no group.
  @test [r[:id] for r in grouped(whens[1])().list()] == [1]
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: the shapes that need no childless parent keep their INNER join
# A plain reverse filter and `__@isnull => false` can only match a parent that has a child, so the issue
# asks for their plan to stay as it was. These are green before and after the fix; they fail if the
# promotion leaks past the OR arm and the anti-join.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a plain reverse filter and __@isnull => false stay INNER (#1367)" begin
  plain = q -> q.filter("results__grid" => 5)
  notnull = q -> q.filter("results__id__@isnull" => false)
  for (engine, conn) in _RJ_ENGINES, f in (plain, notnull)
    sql = _rj_sql(f, conn)
    @test occursin("INNER JOIN \"rj_result\" AS \"Tb_1\"", sql)
    @test !occursin("LEFT JOIN", sql)
  end
  @test _rj_ids(plain) == [1, 2]
  @test _rj_ids(notnull) == [1, 2]
end

# ─────────────────────────────────────────────────────────────────────────────
# A forward hop past a promoted reverse hop follows it to LEFT
# `results__driver__code`: the reverse hop to rj_result is promoted, and the NOT NULL forward hop to
# rj_driver after it must be LEFT too — an INNER join on a NULL-extended result row would drop Spa again.
# This is the rule a LEFT parent already gives its child at build (`_determine_join_type`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "a forward hop after a promoted reverse hop is LEFT too (#1367)" begin
  f = q -> q.filter(Qor("name" => "Spa", "results__driver__code" => "SEN"))
  for (engine, conn) in _RJ_ENGINES
    sql = _rj_sql(f, conn)
    @test occursin("LEFT JOIN \"rj_result\" AS \"Tb_1\"", sql)
    @test occursin("LEFT JOIN \"rj_driver\" AS \"Tb_2\"", sql)
  end
  @test _rj_ids(f) == [1, 3]
end

# ─────────────────────────────────────────────────────────────────────────────
# The OR arm reads a path the projection already joined
# The projection builds the reverse join first, and the filter then reuses its memoized column without
# building a hop. The promotion must still reach that join: `LEFT JOIN "rj_result"`, and Spa comes back
# with a missing grid.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a Qor arm on a projected reverse path promotes the projection's join (#1367)" begin
  build = () -> begin
    q = RJ.Rj_race.objects
    q.filter(Qor("name" => "Spa", "results__grid" => 1)).values("id", "results__grid").order_by("id")
    q
  end
  for (engine, conn) in _RJ_ENGINES
    sql = replace(inspect_query(build(); connection = conn)[:sql_text], r"\s+" => " ")
    @test occursin("LEFT JOIN \"rj_result\" AS \"Tb_1\"", sql)
  end
  rows = build().list()
  @test [r[:id] for r in rows] == [1, 3]
  @test rows[1][:results__grid] == 1
  @test rows[2][:results__grid] === missing || rows[2][:results__grid] === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# ManyToMany: both rows of the hop (the through table and the related table) become LEFT
# A ManyToMany hop was INNER whatever the shape. Spa has no sponsor, so the anti-join must find it, and
# the OR must keep it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a ManyToMany hop under __@isnull => true or a Qor arm is LEFT (#1367)" begin
  isnull = q -> q.filter("sponsors__id__@isnull" => true)
  either = q -> q.filter(Qor("name" => "Spa", "sponsors__name" => "Acme"))
  for (engine, conn) in _RJ_ENGINES, f in (isnull, either)
    sql = _rj_sql(f, conn)
    @test occursin("LEFT JOIN \"rj_race_sponsors\" AS \"Tb_1\"", sql)
    @test occursin("LEFT JOIN \"rj_sponsor\" AS \"Tb_2\"", sql)
  end
  @test _rj_ids(isnull) == [3]
  @test _rj_ids(either) == [1, 2, 3]
  # Control: a plain ManyToMany filter keeps both INNER joins.
  plain = _rj_sql(q -> q.filter("sponsors__name" => "Acme"), RjMockSQLite())
  @test occursin("INNER JOIN \"rj_race_sponsors\"", plain) && occursin("INNER JOIN \"rj_sponsor\"", plain)
end

# ─────────────────────────────────────────────────────────────────────────────
# A reverse OneToOne is to-one, and a parent can still lack it
# `report` is unique on the child, so it never repeats a race (#1002), but Spa has no report: the OR and
# the anti-join need the LEFT join exactly as a to-many reverse relation does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a reverse OneToOne under __@isnull => true or a Qor arm is LEFT (#1367)" begin
  isnull = q -> q.filter("report__id__@isnull" => true)
  either = q -> q.filter(Qor("name" => "Spa", "report__body" => "wet"))
  for (engine, conn) in _RJ_ENGINES, f in (isnull, either)
    @test occursin("LEFT JOIN \"rj_report\" AS \"Tb_1\"", _rj_sql(f, conn))
  end
  @test _rj_ids(isnull) == [3]
  @test _rj_ids(either) == [1, 3]
end

# ─────────────────────────────────────────────────────────────────────────────
# A join type the query states is kept
# `on("results", join_type = "INNER")` says which join the caller wants; the promotion derives a type and
# never overrides a stated one. Spa is dropped, as the stated INNER join says.
# ─────────────────────────────────────────────────────────────────────────────
@testset "on(path, join_type = \"INNER\") keeps the stated join under a Qor arm (#1367)" begin
  f = q -> (q.on("results", join_type = "INNER"); q.filter(Qor("name" => "Spa", "results__grid" => 1)))
  for (engine, conn) in _RJ_ENGINES
    sql = _rj_sql(f, conn)
    @test occursin("INNER JOIN \"rj_result\" AS \"Tb_1\"", sql)
    @test !occursin("LEFT JOIN", sql)
  end
  @test _rj_ids(f) == [1]
end

# ─────────────────────────────────────────────────────────────────────────────
# A row lock without `of` beside a promoted join is refused, as beside any LEFT join (#1106)
# PostgreSQL cannot lock the nullable side of an outer join, and a lock without `of` locks every table the
# statement reads. The promoted join is a LEFT join like a nullable key's, so the same refusal names it,
# on every engine; `of = ("self",)` locks the races alone and builds. The reverse OneToOne keeps the
# query free of the #1002 to-many refusal, which would fire first.
# ─────────────────────────────────────────────────────────────────────────────
@testset "select_for_update() beside a promoted join is refused; of = (\"self\",) builds (#1367)" begin
  q = RJ.Rj_race.objects
  q.filter(Qor("name" => "Spa", "report__body" => "wet")).values("id").select_for_update()
  err = try
    q.list(show_query = :sql); nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError
  @test occursin("is joined LEFT", sprint(showerror, err))
  @test occursin("an OR arm or `__@isnull => true` reads", sprint(showerror, err))

  q = RJ.Rj_race.objects
  q.filter(Qor("name" => "Spa", "report__body" => "wet")).values("id").select_for_update(of = ("self",))
  @test occursin("LEFT JOIN \"rj_report\"", q.list(show_query = :sql))
end

# ─────────────────────────────────────────────────────────────────────────────
# A write reaches the rows the read now matches
# `update()` acts on the rows its filter matches through the same build, so before #1367 an anti-join
# update touched no row. Now it renames Spa and only Spa.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update() through __@isnull => true across a reverse relation reaches the childless parent (#1367)" begin
  q = RJ.Rj_race.objects
  q.filter("results__id__@isnull" => true)
  q.update("name" => "Spa-Francorchamps")
  names = [r[:name] for r in RJ.Rj_race.objects.values("name").order_by("id").list()]
  @test names == ["Monaco", "Monza", "Spa-Francorchamps"]
  _rj_reset!()
end

# `delete()` builds its key read through the same filter, so the anti-join deletes Spa — and only Spa:
# before #1367 it matched no race and deleted nothing.
@testset "delete() through __@isnull => true across a reverse relation deletes the childless parent (#1367)" begin
  q = RJ.Rj_race.objects
  q.filter("results__id__@isnull" => true)
  total, counts = q.delete()
  @test counts["rj_race"] == 1
  @test [r[:id] for r in RJ.Rj_race.objects.values("id").order_by("id").list()] == [1, 2]
  @test length(RJ.Rj_result.objects.values("id").list()) == 3      # races 1 and 2 keep their results
  _rj_reset!()
end

finally
  delete!(PormG.config, "rj1367_sqlite")
  # Release the SQLite handle so the temp dir can be removed on Windows (WAL keeps it open).
  PormG.ConnectionPool.close_pool!(_RJ_POOL)
end
