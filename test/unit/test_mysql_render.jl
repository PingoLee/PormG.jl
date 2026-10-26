# ============================================================
# test/unit/test_mysql_render.jl
#
# The MySQL query builder (#1130, phase 2a: plain-column reads), on mock connections.
#
# CONTRACT being tested:
#   A fluent read builds on a MySQL connection. Its parameters are collected the way every positional
#   engine collects them (`?` markers, one bucket per clause, flattened in clause order), so the Nth
#   value is the one whose marker is Nth in the text, which PostgreSQL's `$N` numbering states
#   independently. The values a MySQL collector holds are the ones MySQL.jl binds: a list is one `?`
#   per element, a UUID is its text, a binary payload its bytes, and an ArrayField value is refused.
#
# DB-free: mock connections only. The same reads run against a live MySQL in
# `test/integration/test_mysql_reads.jl` (PORMG_DB=db_my).
#
# Run: julia --project=test/integration test/unit/test_mysql_render.jl
# ============================================================

using Test
using PormG
using PormG.Models
using Dates, UUIDs, Decimals, TimeZones
import MySQL   # loads PormGMySQLExt, whose statement routing is tested at the end
import PormG.QueryBuilder: Sum, Avg, Count, Max, Min, Joined, F, CTE

include(joinpath(@__DIR__, "helper_marker_alignment.jl"))

const _MR_QB = PormG.QueryBuilder

struct MrMockMySQL <: PormG.PormGMySQL end
struct MrMockPostgres <: PormG.PormGPostgres end
struct MrMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::MrMockSQLite) = 3045000   # the capability table's version rows ask for it

for (key, conn) in (("mr_my", MrMockMySQL()), ("mr_pg", MrMockPostgres()), ("mr_sl", MrMockSQLite()))
  PormG.config[key] = PormG.Configuration.Settings(connections = conn, change_data = true, db_def_folder = key)
end

# One model set per engine, identical: the F1 subset the shapes below name
# (`test/integration/db_2/models.jl`), with the same field types and keys.
for (modname, key) in ((:MrMyModels, "mr_my"), (:MrPGModels, "mr_pg"), (:MrSLModels, "mr_sl"))
  @eval module $modname
  import PormG
  import PormG.Models
  Race = Models.Model(
    raceid = Models.IDField(),
    year = Models.IntegerField(),
    name = Models.CharField(),
    date = Models.DateField(),
  )
  Driver = Models.Model(
    driverid = Models.IDField(),
    forename = Models.CharField(),
    surname = Models.CharField(),
    nationality = Models.CharField(),
    dob = Models.DateField(),
  )
  Result = Models.Model(
    resultid = Models.IDField(),
    raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
    driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "RESTRICT"),
    grid = Models.IntegerField(),
    position = Models.IntegerField(null = true),
    points = Models.FloatField(),
    laps = Models.IntegerField(),
    fastestlaptime = Models.DurationField(null = true),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

# Two modules on their own MySQL key: `Lap`'s ForeignKey targets a model the base module does not
# define, so the NULL key over a shadowed alias must find `driver`'s columns through the relation.
PormG.config["mr_my_cross"] = PormG.Configuration.Settings(connections = MrMockMySQL(), change_data = true,
                                                           db_def_folder = "mr_my_cross")
module MrMyCrossA
import PormG
import PormG.Models
Team = Models.Model(teamid = Models.IDField(), name = Models.CharField(), country = Models.CharField())
Driver = Models.Model(driverid = Models.IDField(), surname = Models.CharField(), nationality = Models.CharField(),
  teamid = Models.ForeignKey(Team, pk_field = "teamid", on_delete = "RESTRICT", null = true))
PormG.Models.set_models(@__MODULE__, "mr_my_cross")
end
module MrMyCrossB
import PormG
import PormG.Models
import ..MrMyCrossA
Lap = Models.Model(lapid = Models.IDField(),
  driverid = Models.ForeignKey(MrMyCrossA.Driver, pk_field = "driverid", on_delete = "RESTRICT", related_name = "laps"),
  position = Models.IntegerField(null = true))
PormG.Models.set_models(@__MODULE__, "mr_my_cross")
end

const _MR_MY = MrMyModels
const _MR_PG = MrPGModels
const _MR_SL = MrSLModels

_mr_inspect(q) = _MR_QB.inspect_query(q)

# ─────────────────────────────────────────────────────────────────────────────
# MySQL collector: the positional buckets, flattened in clause order
# A MySQL build binds in phase order (WHERE before the joins) and renders in clause order, so its
# collector must reorder exactly as SQLite's does. Expected: the values come back in
# `_BUCKET_ORDER`, whatever order they were bound in, and a copy's buckets are its own.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL collector: the positional buckets, flattened in clause order" begin
  params = _MR_QB.get_parameter(MrMockMySQL())
  @test params isa _MR_QB.MySQLParameterizedQuery
  @test params isa PormG.PormGPositionalParam && !(params isa PormG.PormGSQLiteParam)
  # Bound out of clause order, as a build binds them.
  for ctx in (:where, :having, :join, :order, :update, :select, :limit, :group, :cte)
    _MR_QB.set_context!(params, ctx)
    @test _MR_QB.add_parameter!(params, "$(ctx)_val") == "?"
  end
  @test params.parameters == ["$(ctx)_val" for ctx in _MR_QB._BUCKET_ORDER]
  @test params.parameter_count == length(_MR_QB._BUCKET_ORDER)
  # `with_bucket` restores the bucket it found, on a positional MySQL collector as on SQLite.
  _MR_QB.set_context!(params, :where)
  _MR_QB.with_bucket(() -> _MR_QB.add_parameter!(params, "nested"), params, :having)
  @test params.current_context === :where && params.having_params == ["having_val", "nested"]
  # A fork and a deepcopy hold their own buckets of the same concrete type.
  fork = _MR_QB._fork_parameters(params)
  copied = deepcopy(params)
  @test fork isa _MR_QB.MySQLParameterizedQuery && copied isa _MR_QB.MySQLParameterizedQuery
  push!(fork.where_params, "fork_only")
  push!(copied.where_params, "copy_only")
  @test params.where_params == ["where_val"]
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL collector: values as MySQL.jl binds them
# MySQL has no array binding and no array or UUID type. Expected: a list renders `?, ?, ?` with one
# value each, a UUID binds as its 36-character text (the `CHAR(36)` it is stored as, #1270), a binary
# payload as its bytes, a Decimal as its exact text under a `CAST(? AS DECIMAL(p,s))` marker, a duration as the
# microseconds a `DurationField` stores (#1130; MySQL.jl binds no `Period`), and an ArrayField value
# raises BackendCapabilityError rather than binding as text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL collector: values as MySQL.jl binds them" begin
  params = _MR_QB.get_parameter(MrMockMySQL())
  @test _MR_QB.add_parameter!(params, [1, 2, 3]) == "?, ?, ?"
  u = UUID("123e4567-e89b-12d3-a456-426614174000")
  @test _MR_QB.add_parameter!(params, u) == "?"
  # Bytes state their type: in a derived table's row beside text, a bare `?` was utf8mb4 (1366, #1130 phase 5).
  @test _MR_QB.add_parameter!(params, PormG.PormGBytes(UInt8[0x00, 0xff])) == "CAST(? AS BINARY)"
  @test _MR_QB.add_parameter!(_MR_QB.get_parameter(MrMockMySQL()), [PormG.PormGBytes(UInt8[0x01]), PormG.PormGBytes(UInt8[0x02])]) ==
        "CAST(? AS BINARY), CAST(? AS BINARY)"
  @test _MR_QB.add_parameter!(params, Decimal(0, 255, -1)) == "CAST(? AS DECIMAL(3,1))"   # #1130 2c-1: its own DECIMAL
  @test params.parameters == Any[1, 2, 3, "123e4567-e89b-12d3-a456-426614174000", UInt8[0x00, 0xff], Decimal(0, 255, -1)]
  _MR_QB.add_parameter!(params, Hour(1))
  _MR_QB.add_parameter!(params, Minute(1) + Second(20) + Millisecond(500))
  _MR_QB.add_parameter!(params, Nanosecond(1_500))   # half a microsecond rounds away from zero
  @test params.parameters[end-2:end] == Any[3_600_000_000, 80_500_000, 2]
  # A pattern value gets the same wildcards as on every engine.
  _MR_QB.add_parameter!(params, "Senna"; contains = true, operator = "contains")
  @test params.parameters[end] == "%Senna%"
  @test_throws PormG.BackendCapabilityError _MR_QB.add_parameter!(params, PormG.PormGArrayLiteral("{1,2}"))
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL read: the parameters bind in the text order PostgreSQL's numbering states
# The cross-backend differential (`_pg_text_order`): PostgreSQL's `$N` travels with the text, so
# walking it gives the order every positional marker must bind in. Expected: for each shape the MySQL
# vector equals that walk and SQLite's vector, and the marker count equals the value count.
# ─────────────────────────────────────────────────────────────────────────────
const _MR_ALIGN_SHAPES = [
  "a filter across a join, projected and ordered" => M ->
    M.Result.objects.filter("driverid__surname" => "Senna", "grid__@lte" => 3).
      values("points", "driverid__surname").order_by("-points"),
  "a list membership beside a range" => M ->
    M.Result.objects.filter("grid__@in" => [1, 2, 3], "laps__@gte" => 50),
  "Qor of a joined filter and a plain one" => M ->
    M.Result.objects.filter(Qor("driverid__nationality" => "Brazilian", "raceid__year" => 1991)),
  "a subquery membership" => M ->
    M.Result.objects.filter("driverid__@in" =>
      M.Driver.objects.filter("nationality" => "British").values("driverid")),
  # The shape that binds out of text order: the WHERE value is bound before the join's ON value,
  # whose text comes first. Only the buckets put them back.
  "a join condition beside a filter" => M -> begin
    q = M.Result.objects.filter("grid__@lte" => 3).values("points", "driverid__surname")
    q.on("driverid", "nationality" => "Brazilian")
    q
  end,
]

@testset "MySQL read: parameters bind in the text order PostgreSQL states" begin
  for (label, build) in _MR_ALIGN_SHAPES
    my = _mr_inspect(build(_MR_MY))
    pg = _mr_inspect(build(_MR_PG))
    sl = _mr_inspect(build(_MR_SL))
    @test (label, my[:dialect], my[:bucketing]) == (label, :mysql, :positional)
    @test (label, my[:parameters]) == (label, _pg_text_order(pg))
    @test (label, my[:parameters]) == (label, sl[:parameters])
    @test (label, count(==('?'), my[:sql_text])) == (label, length(my[:parameters]))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL quoting: backticks on both axes, with each axis's own rule
# MySQL reads `"x"` as a string unless the session sets ANSI_QUOTES, which PormG never depends on
# (#1271). Expected: an alias is backticked and still validated fail-closed (#394), a physical table or
# column is backticked and only escaped (a backtick doubled, a double quote kept as a character), and
# PostgreSQL / SQLite keep their double quotes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL quoting: backticks on both axes, with each axis's own rule" begin
  my, pg, sl = MrMockMySQL(), MrMockPostgres(), MrMockSQLite()
  @test _MR_QB.quote_identifier("Tb_1", my) == "`Tb_1`"
  @test_throws PormG.InvalidValueError _MR_QB.quote_identifier("Tb`; DROP", my)
  @test _MR_QB.safe_table_identifier("weird`table", my) == "`weird``table`"
  @test _MR_QB.safe_column_identifier("a\"b", my) == "`a\"b`"
  @test _MR_QB.quote_identifier("Tb_1", pg) == "\"Tb_1\"" && _MR_QB.quote_identifier("Tb_1", sl) == "\"Tb_1\""
  @test _MR_QB.safe_table_identifier("weird\"table", sl) == "\"weird\"\"table\""
  # #74's fan-out guard reads the alias back out of a rendered column, in either quoting.
  @test _MR_QB._extract_leading_alias("`Tb_1`.`points`") == "Tb_1"
  @test _MR_QB._extract_leading_alias("`T``b`.*") == "T`b"
  @test _MR_QB._extract_leading_alias("\"Tb_1\".\"points\"") == "Tb_1"
  @test _MR_QB._extract_leading_alias("`Tb_1`.`points` + 1") === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL read: no identifier is double-quoted anywhere in the statement
# The silent case is an ORDER BY on a projection alias: `ORDER BY "points"` orders every row by the
# same constant string on MySQL. Expected: for each shape — joins, an alias ordering, the count and
# exists forms with their derived-table aliases, EXISTS, a CTE, `cjoin_on`, `on()` — the SQL holds no
# `"` at all, and the ordering names the alias in backticks.
# ─────────────────────────────────────────────────────────────────────────────
const _MR_QUOTE_SHAPES = [
  "a join, projected, ordered by an alias" => M ->
    _mr_inspect(M.Result.objects.filter("driverid__surname" => "Senna").
      values("pts" => "points", "driverid__surname").order_by("-pts"))[:sql_text],
  "count()" => M -> M.Result.objects.filter("grid__@gt" => 3).count(show_query = :sql),
  "distinct().count(), a derived table" => M ->
    M.Result.objects.filter("grid__@gt" => 3).distinct().count(show_query = :sql),
  "a projected count, a derived table" => M ->
    M.Result.objects.values("driverid").distinct().count(show_query = :sql),
  "exists()" => M -> M.Result.objects.filter("grid__@gt" => 3).exists(show_query = :sql),
  "Exists(…) with OuterRef" => M ->
    _mr_inspect(M.Driver.objects.filter(Exists(M.Result.objects.filter(
      "driverid" => OuterRef("driverid"), "grid" => 1))))[:sql_text],
  "a CTE joined on a key" => M -> begin
    q = M.Result.objects
    q.with("br" => M.Driver.objects.filter("nationality" => "Brazilian").values("driverid", "surname"),
           join_field = "driverid" => "driverid")
    _mr_inspect(q.values("points", "br_surname" => CTE("br", "surname")))[:sql_text]
  end,
  "a CTE joined on a path through a ForeignKey" => M -> begin
    q = M.Result.objects
    q.with("dl" => M.Driver.objects.values("driverid", "surname"), join_field = "driverid__surname" => "surname")
    _mr_inspect(q.values("points", "dl_id" => CTE("dl", "driverid")))[:sql_text]
  end,
  "cjoin_on" => M -> begin
    q = M.Result.objects.values("points", "d_surname" => Joined("d", "surname"))
    q.cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid")])
    _mr_inspect(q)[:sql_text]
  end,
  "on() with a condition" => M -> begin
    q = M.Result.objects.values("points", "driverid__surname")
    q.on("driverid", "nationality" => "Brazilian")
    _mr_inspect(q)[:sql_text]
  end,
]

@testset "MySQL read: no identifier is double-quoted anywhere in the statement" begin
  for (label, render) in _MR_QUOTE_SHAPES
    sql = render(_MR_MY)
    @test (label, occursin('"', sql)) == (label, false)
    @test (label, occursin('`', sql)) == (label, true)
  end
  ordered = _MR_QUOTE_SHAPES[1].second(_MR_MY)
  @test occursin("ORDER BY (`pts` IS NULL) DESC, `pts` DESC", ordered)
  @test occursin("FROM `result` as `Tb`", ordered) && occursin("INNER JOIN `driver` AS `Tb_1`", ordered)
  # The derived-table aliases are quoted the engine's way, on every engine.
  @test occursin("as `__pormg_distinct_count`", _MR_QUOTE_SHAPES[3].second(_MR_MY))
  @test occursin("as \"__pormg_distinct_count\"", _MR_QUOTE_SHAPES[3].second(_MR_PG))
  # A CTE joined on a path joins on the joined driver's own column (#1130 phase 5b): the alias was the
  # cached selector with `"` stripped, which left MySQL's backticks in it and failed the alias check.
  by_path = Dict(_MR_QUOTE_SHAPES)["a CTE joined on a path through a ForeignKey"]
  @test occursin("LEFT JOIN `dl` AS `R1_2` ON `R1_1`.`surname` = `R1_2`.`surname`", by_path(_MR_MY))
  @test occursin("LEFT JOIN \"dl\" AS \"R1_2\" ON \"R1_1\".\"surname\" = \"R1_2\".\"surname\"", by_path(_MR_PG))
end

# ─────────────────────────────────────────────────────────────────────────────
# distinct().count() across a join: the model's rows, on every engine
# An unprojected `distinct()` counts the model's rows, as Django's does. Its derived table used to be
# `SELECT DISTINCT *`, which takes the joined table's columns too, so across a to-many join every
# (driver, result) pair was distinct: the F1 data's drivers with a pole counted 1136, not 110, on
# PostgreSQL and SQLite alike, and on MySQL two `driverid` columns in a derived table are error 1060.
# Expected: the inner select is the base alias's columns only, on each engine, joins and all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "distinct().count() across a to-many join counts the model's rows, on every engine" begin
  for (M, q) in ((_MR_PG, '"'), (_MR_SL, '"'), (_MR_MY, '`'))
    sql = M.Driver.objects.filter("result__grid" => 1).distinct().count(show_query = :sql)
    @test occursin("SELECT COUNT(*) FROM (\nSELECT DISTINCT $(q)Tb$(q).*\nFROM $(q)driver$(q) as $(q)Tb$(q)\n", sql)
    @test occursin("JOIN $(q)result$(q) AS $(q)Tb_1$(q)", sql)
    @test !occursin("DISTINCT *", sql)
    # `exists()` past an offset skips the same rows: the model's, not one per related row.
    probe = M.Driver.objects.filter("result__grid" => 1).distinct().offset(110).exists(show_query = :sql)
    @test startswith(probe, "SELECT DISTINCT $(q)Tb$(q).*\nFROM $(q)driver$(q) as $(q)Tb$(q)")
    @test startswith(M.Driver.objects.filter("result__grid" => 1).distinct().exists(show_query = :sql), "SELECT 1\n")
    # ... and so does `Exists(...)`, through the derived table it probes a kept projection with.
    ex = _mr_inspect(M.Race.objects.filter(Exists(M.Driver.objects.filter("result__grid" => 1).distinct().offset(110))))[:sql_text]
    @test occursin(Regex("EXISTS \\(SELECT 1 FROM \\(SELECT DISTINCT $(q)\\w+$(q)\\.\\*\\n"), ex)
    @test occursin("as $(q)__pormg_exists$(q)\nLIMIT 1 OFFSET", ex)
    @test occursin("EXISTS (SELECT 1\n", _mr_inspect(M.Race.objects.filter(Exists(M.Driver.objects.filter("result__grid" => 1).distinct())))[:sql_text])
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL pattern lookups: LIKE keeps case, the i* lookups fold with LOWER
# #1265: a column PormG creates compares code points, so `LIKE` keeps case; MySQL has no ILIKE, and a
# `_ci` collation would also drop accents, so the case-insensitive lookups fold both sides with LOWER.
# MySQL reads `\` in a literal as an escape, so the escape clause is `ESCAPE '\\'`. Expected: the SQL
# below, the escaped value bound, and the PostgreSQL-only lookups refused with MySQL named.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL pattern lookups: LIKE keeps case, the i* lookups fold with LOWER" begin
  where_of(pair) = (i = _mr_inspect(_MR_MY.Driver.objects.filter(pair)); (i[:sql_text], i[:parameters]))
  sql, params = where_of("surname__@contains" => "en%n")
  @test occursin("WHERE `Tb`.`surname` LIKE ? ESCAPE '\\\\'", sql) && params == ["%en\\%n%"]
  sql, params = where_of("surname__@icontains" => "SEN")
  @test occursin("WHERE LOWER(`Tb`.`surname`) LIKE LOWER(?) ESCAPE '\\\\'", sql) && params == ["%SEN%"]
  sql, _ = where_of("surname__@istartswith" => "se")
  @test occursin("LOWER(`Tb`.`surname`) LIKE LOWER(?)", sql)
  sql, _ = where_of("surname__@nendswith" => "na")
  @test occursin("`Tb`.`surname` NOT LIKE ? ESCAPE '\\\\'", sql)
  sql, _ = where_of("surname__@niendswith" => "NA")
  @test occursin("LOWER(`Tb`.`surname`) NOT LIKE LOWER(?)", sql)
  # #634: case-insensitive equality binds its value verbatim, so a `%` is a character, not a wildcard.
  sql, params = where_of("surname__@iexact" => "SEN%NA")
  @test occursin("WHERE LOWER(`Tb`.`surname`) = LOWER(?)", sql) && params == ["SEN%NA"]
  sql, _ = where_of("surname__@niexact" => "senna")
  @test occursin("LOWER(`Tb`.`surname`) <> LOWER(?)", sql)
  # The lookups the capability table says MySQL lacks are refused, naming MySQL.
  for pair in ("surname__@iunaccent_contains" => "raik", "surname__@regex" => "^S")
    err = try; _mr_inspect(_MR_MY.Driver.objects.filter(pair)); nothing; catch e; e; end
    @test err isa PormG.BackendCapabilityError && occursin("which MySQL does not support", sprint(showerror, err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL LIMIT / OFFSET: bound values, and the no-limit spelling an OFFSET needs
# MySQL has no standalone OFFSET and no negative "no limit" (#1271): an offset alone renders
# `LIMIT 18446744073709551615 OFFSET ?`, the largest BIGINT UNSIGNED. Expected: that tail, the user's
# values bound last (`:limit`), and `first()` / a sliced `count()` building on the same tail.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL LIMIT / OFFSET: bound values, and the no-limit spelling" begin
  i = _mr_inspect(_MR_MY.Result.objects.filter("grid__@gt" => 3).values("points").offset(5))
  @test occursin("LIMIT 18446744073709551615 \nOFFSET ?", i[:sql_text]) && i[:parameters] == Any[3, 5]
  i = _mr_inspect(_MR_MY.Result.objects.values("points").limit(10).offset(20))
  @test occursin("LIMIT ? \nOFFSET ?", i[:sql_text]) && i[:parameters] == Any[10, 20]
  @test occursin("LIMIT ?", _MR_MY.Result.objects.order_by("points").first(show_query = :sql))
  sliced = _MR_MY.Result.objects.filter("grid__@gt" => 3).limit(5).count(show_query = :sql)
  @test occursin("LIMIT ?", sliced) && occursin("as `__pormg_sliced_count`", sliced)
  # The other engines keep their own tails.
  @test occursin("LIMIT -1", _mr_inspect(_MR_SL.Result.objects.values("points").offset(5))[:sql_text])
  @test !occursin("LIMIT", _mr_inspect(_MR_PG.Result.objects.values("points").offset(5))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL select_for_update: InnoDB row locks, and no_key refused
# #1269: `FOR UPDATE [OF …] [NOWAIT | SKIP LOCKED]` as on PostgreSQL. MySQL has no lock that leaves
# foreign-key checks free, so `no_key = true` raises BackendCapabilityError (`:no_key_locks`) instead
# of silently taking the stronger lock. Expected: the clauses below; PostgreSQL still renders
# `FOR NO KEY UPDATE`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL select_for_update: InnoDB row locks, and no_key refused" begin
  lock_sql(M; kw...) = _mr_inspect(M.Result.objects.filter("grid" => 1).select_for_update(; kw...))[:sql_text]
  @test occursin("FOR UPDATE", lock_sql(_MR_MY))
  @test occursin("FOR UPDATE NOWAIT", lock_sql(_MR_MY; nowait = true))
  @test occursin("FOR UPDATE SKIP LOCKED", lock_sql(_MR_MY; skip_locked = true))
  err = try; lock_sql(_MR_MY; no_key = true); nothing; catch e; e; end
  @test err isa PormG.BackendCapabilityError
  @test occursin("select_for_update(no_key = true)", sprint(showerror, err)) &&
        occursin("which MySQL does not support (supported on PostgreSQL)", sprint(showerror, err))
  @test occursin("FOR NO KEY UPDATE", lock_sql(_MR_PG; no_key = true))
  @test PormG._supports(MrMockPostgres(), :no_key_locks) && !PormG._supports(MrMockMySQL(), :no_key_locks)
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL aggregates: a sum of integers is turned back into the integer it means
# MySQL's SUM over an integer column is a DECIMAL (`SUM(INT)` and `SUM(BIGINT)` alike); the sum of
# integers means an integer (Django's `Sum` of an integer field), so it renders
# `(SUM(x) DIV 1)` (a `BIGINT`, which raises past its range where a cast would clamp), and the type walk
# names the same `CInt64`. Expected: the `DIV` on integer operands only, in the SELECT and in a HAVING
# that filters on it; AVG/COUNT/MAX/MIN bare; the PostgreSQL and SQLite renders unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL aggregates: a sum of integers is turned back into the integer it means" begin
  sel(M, f) = _mr_inspect(M.Result.objects.values("driverid", "agg" => f))[:sql_text]
  @test occursin("(SUM(`Tb`.`grid`) DIV 1) as `agg`", sel(_MR_MY, Sum("grid")))
  @test occursin("(SUM(DISTINCT `Tb`.`laps`) DIV 1)", sel(_MR_MY, Sum("laps"; distinct = true)))
  @test occursin("SUM(`Tb`.`points`) as `agg`", sel(_MR_MY, Sum("points")))
  @test !occursin("DIV", sel(_MR_MY, Sum("points")))
  @test occursin("AVG(`Tb`.`grid`) as `agg`", sel(_MR_MY, Avg("grid")))
  @test occursin("COUNT(DISTINCT `Tb`.`grid`)", sel(_MR_MY, Count("grid"; distinct = true)))
  @test occursin("MAX(`Tb`.`points`)", sel(_MR_MY, Max("points"))) && occursin("MIN(`Tb`.`grid`)", sel(_MR_MY, Min("grid")))
  having = _mr_inspect(_MR_MY.Result.objects.values("driverid", "total" => Sum("grid")).filter("total__@gt" => 10))
  @test occursin("HAVING (SUM(`Tb`.`grid`) DIV 1) > ?", having[:sql_text]) && having[:parameters] == Any[10]
  # The other engines never see the MySQL flag.
  @test occursin("SUM(\"Tb\".\"grid\") as \"agg\"", sel(_MR_PG, Sum("grid"))) && !occursin("DIV", sel(_MR_PG, Sum("grid")))
  @test occursin("SUM(\"Tb\".\"grid\") as \"agg\"", sel(_MR_SL, Sum("grid")))
  # What MySQL computes, per operand, as the type walk reads it.
  my = MrMockMySQL()
  @test _MR_QB._computed_kind(Val(:SUM), :promoting, PormG.CInt32(), my) == PormG.CInt64()
  @test _MR_QB._computed_kind(Val(:SUM), :promoting, PormG.CFloat64(), my) == PormG.CFloat64()
  @test _MR_QB._computed_kind(Val(:AVG), :numeric, PormG.CInt64(), my) == PormG.CDecimal(nothing, nothing)
  @test _MR_QB._computed_kind(Val(:AVG), :numeric, PormG.CDate(), my) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL NULL placement: always the sort key, never a silent native order
# MySQL has no NULLS FIRST / NULLS LAST, so every term is emulated (`_emulates_nulls_order`). A term
# that binds a value would have to be printed twice to be emulated, and the shared renderer prints it
# bare there — MySQL's own NULL order — so MySQL refuses it instead (`:nulls_order`). Expected: the
# key on a plain term, the key with a separate flag render, the refusal on a bare bound term, and the
# clause renderer still calling the shared function the MySQL method extends.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL NULL placement: always the sort key, never a silent native order" begin
  my = MrMockMySQL()
  @test _MR_QB._order_term_sql("`Tb`.`position`", "DESC", :first, my) ==
        "(`Tb`.`position` IS NULL) DESC, `Tb`.`position` DESC"
  @test _MR_QB._order_term_sql("(`Tb`.`grid` + ?)", "ASC", :last, my; null_flag = "(`Tb`.`grid` + ?)") ==
        "((`Tb`.`grid` + ?) IS NULL) ASC, (`Tb`.`grid` + ?) ASC"
  err = try; _MR_QB._order_term_sql("(`Tb`.`grid` + ?)", "ASC", :last, my); nothing; catch e; e; end
  @test err isa PormG.BackendCapabilityError && occursin("Ordering by an expression that binds a value", sprint(showerror, err))
  # PostgreSQL keeps the native clause; the MySQL method is only MySQL's.
  @test _MR_QB._order_term_sql("\"Tb\".\"grid\"", "ASC", :last, MrMockPostgres()) == "\"Tb\".\"grid\" ASC NULLS LAST"
  # The clause renderer (`build_select.jl`, which this method does not live in) still calls the shared
  # function, so a rename there cannot route MySQL past the refusal.
  build_select = read(joinpath(@__DIR__, "..", "..", "src", "querybuilder", "build_select.jl"), String)
  @test occursin("_order_term_sql(order_expr, orientation, placement, instruc.connection", build_select)
  @test occursin("ORDER BY (`Tb`.`position` IS NULL) DESC, `position` DESC",
                 _mr_inspect(_MR_MY.Result.objects.values("position").order_by("-position"))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL NULL placement: an alias a FROM column also names is keyed on the projection
# Inside `(alias IS NULL)` MySQL reads a name as a FROM column before a result alias (measured on 8.4),
# so `values("laps" => "position").order_by("-laps")` would test the never-NULL `laps` column and sort
# the NULL positions last, silently. Expected: the key is the projection's own SQL wherever a table the
# query reads has a column of that name (the base table, a joined model, a CTE, a `cjoin_on` table, a
# join an `order_by` path or an `on()` adds after ORDER BY, a model of another module) and for every kind
# of projection (a column, an aggregate, a window, a bound expression, a `Value`), re-binding the
# projection's values where the key prints; the alias otherwise; PostgreSQL and SQLite 3.45 unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL NULL placement: an alias a FROM column also names is keyed on the projection" begin
  order_of(q) = (s = rstrip(_mr_inspect(q)[:sql_text]); s[first(findlast("\nORDER BY ", s))+1:end])
  key(q) = (s = order_of(q); s[length("ORDER BY ")+1:first(findfirst(" IS NULL)", s))-1])
  @test order_of(_MR_MY.Result.objects.values("laps" => "position").order_by("-laps")) ==
        "ORDER BY (`Tb`.`position` IS NULL) DESC, `laps` DESC"
  # A projection that IS the column of its name is keyed on it too: a joined table's column of the same
  # name would make the bare name ambiguous (MySQL error 1052).
  @test order_of(_MR_MY.Result.objects.values("position").order_by("-position")) ==
        "ORDER BY (`Tb`.`position` IS NULL) DESC, `position` DESC"
  # A name no table has keeps the alias, as before.
  @test order_of(_MR_MY.Result.objects.values("pos2" => "position").order_by("-pos2")) ==
        "ORDER BY (`pos2` IS NULL) DESC, `pos2` DESC"
  @test key(_MR_MY.Result.objects.values("driverid", "total" => Sum("laps")).order_by("total")) == "(`total`"
  # A joined model's column: `name` is the race's.
  @test key(_MR_MY.Result.objects.values("name" => "position", "raceid__year").order_by("name")) == "(`Tb`.`position`"
  # A join added AFTER this term: by a later `order_by` path, and by `on()`, which `build` materializes
  # after ORDER BY.
  @test key(_MR_MY.Result.objects.values("surname" => "position").order_by("-surname", "driverid__nationality")) ==
        "(`Tb`.`position`"
  q = _MR_MY.Result.objects.values("surname" => "position", "resultid")
  q.on("driverid", "nationality" => "Brazilian")
  @test key(q.order_by("-surname")) == "(`Tb`.`position`"
  # A CTE's projection, and a `cjoin_on` table's column.
  q = _MR_MY.Result.objects
  q.with("br" => _MR_MY.Driver.objects.values("driverid", "surname"), join_field = "driverid" => "driverid")
  @test key(q.values("surname" => "position", "br_driver" => CTE("br", "driverid")).order_by("-surname")) == "(`R1`.`position`"
  q = _MR_MY.Result.objects.values("surname" => "position", "d_name" => Joined("d", "forename"))
  q.cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid")])
  @test key(q.order_by("-surname")) == "(`Tb`.`position`"
  # Declared but not joined (nothing projects it), the CTE is not in FROM, so its names shadow nothing.
  q = _MR_MY.Result.objects
  q.with("br" => _MR_MY.Driver.objects.values("driverid", "surname"), join_field = "driverid" => "driverid")
  @test key(q.values("surname" => "position", "resultid").order_by("-surname")) == "(`surname`"
  # A joined model defined in another module is found through the relation, forward and reverse.
  @test key(MrMyCrossB.Lap.objects.values("surname" => "position", "driverid__nationality").order_by("-surname")) ==
        "(`Tb`.`position`"
  @test key(MrMyCrossB.Lap.objects.values("pos2" => "position", "driverid__nationality").order_by("-pos2")) == "(`pos2`"
  @test key(MrMyCrossA.Driver.objects.values("position" => "surname", "laps__lapid").order_by("-position")) ==
        "(`Tb`.`surname`"
  # Each hop of a later path counts, not only its last (`surname` is the driver's, two hops from `lap`);
  # its last segment is a column even when it is a ForeignKey, so `driverid__teamid` joins no team and
  # the team's `country` shadows nothing.
  @test key(MrMyCrossB.Lap.objects.values("surname" => "position").order_by("-surname", "driverid__teamid__name")) ==
        "(`Tb`.`position`"
  @test key(MrMyCrossB.Lap.objects.values("country" => "position").order_by("-country", "driverid__teamid")) == "(`country`"
  # A relation path a `cjoin_on` ON clause names is joined after ORDER BY too: `year` is the race's.
  q = _MR_MY.Result.objects.values("year" => "position", "resultid")
  q.cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid"), Joined("d", "dob") == F("raceid__date")])
  @test key(q.order_by("-year")) == "(`Tb`.`position`"
  # A `cjoin_on` path's last segment is a column too: `driverid__teamid` joins no team, so `country`
  # shadows nothing.
  q = MrMyCrossB.Lap.objects.values("country" => "position")
  q.cjoin_on("Lap", alias = "l2", on = [Joined("l2", "lapid") == F("lapid"), Joined("l2", "position") == F("driverid__teamid")])
  @test key(q.order_by("-country")) == "(`country`"
  # A CTE a later term orders by is joined when that term renders: `br` has a `surname`.
  for later in ("br__surname", CTE("br", "surname"))
    q = _MR_MY.Result.objects
    q.with("br" => _MR_MY.Driver.objects.values("driverid", "surname"), join_field = "driverid" => "driverid")
    @test key(q.values("surname" => "position", "resultid").order_by("-surname", later)) == "(`R1`.`position`"
  end
  # … or reads it inside a window or a `Case` condition.
  QB = _MR_QB
  for later in (QB.SQLOrder(QB.SQLField(QB.Rank(over = QB.WindowOver(order_by = ["br__surname"])), "rk")),
                QB.SQLOrder(QB.SQLField(QB.Rank(over = QB.WindowOver(partition_by = [CTE("br", "surname")])), "rk")),
                QB.SQLOrder(QB.SQLField(QB.Case([QB.When(CTE("br", "surname") => F("grid"), then = F("grid"))],
                                                default = F("laps")), "c")),
                # A `When` condition keeps its path as written.
                QB.SQLOrder(QB.SQLField(QB.Case([QB.When("br__surname" => F("grid"), then = F("grid"))],
                                                default = F("laps")), "c")),
                QB.SQLOrder(QB.SQLField(QB.Case([QB.When(QB.Q(CTE("br", "surname") => F("grid")), then = F("grid"))],
                                                default = F("laps")), "c")),
                QB.SQLOrder(QB.SQLField(QB.Case([QB.When(QB.Qor(CTE("br", "surname") => F("grid"), "grid" => F("laps")),
                                                         then = F("grid"))], default = F("laps")), "c")),
                # … on the value side of a condition too.
                QB.SQLOrder(QB.SQLField(QB.Case([QB.When("grid" => CTE("br", "surname"), then = F("grid"))],
                                                default = F("laps")), "c")))
    q = _MR_MY.Result.objects
    q.with("br" => _MR_MY.Driver.objects.values("driverid", "surname"), join_field = "driverid" => "driverid")
    @test key(q.values("surname" => "position", "resultid").order_by("-surname", later)) == "(`R1`.`position`"
  end
  # Whatever that look-ahead misses is refused once every join exists, never run: a term that kept its
  # alias in the key is rechecked against the finished statement's tables. A later term that joins the
  # driver through a nested query's `OuterRef` is one; ordered first, it has joined it in time.
  ex = QB.SQLOrder(QB.SQLField(QB.Exists(_MR_MY.Driver.objects.filter("driverid" => QB.OuterRef("driverid"),
                                                                       "surname" => QB.OuterRef("driverid__surname"))), "ex"))
  err = try; _mr_inspect(_MR_MY.Result.objects.values("surname" => "position").order_by("-surname", ex)); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError && occursin("has a column with that name", sprint(showerror, err))
  @test endswith(order_of(_MR_MY.Result.objects.values("surname" => "position").order_by(ex, "-surname")),
                 "(`Tb`.`position` IS NULL) DESC, `surname` DESC")
  q = _MR_MY.Result.objects.values("pos2" => "position").order_by("-pos2")
  instruc = QB.build(q.object)
  @test instruc.alias_null_keys == ["pos2"]
  @test QB._refuse_late_shadowed_null_key(q.object, instruc) === nothing
  push!(instruc.alias_null_keys, "laps")
  err = try; QB._refuse_late_shadowed_null_key(q.object, instruc); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError && occursin("has a column with that name", sprint(showerror, err)) &&
        occursin("MySQL", sprint(showerror, err))
  # A term that names the projection by its path (`order_by("date__@year")` over `"name" => "date__@year"`).
  @test key(_MR_MY.Race.objects.values("name" => "date__@year").order_by("-date__@year")) == "(EXTRACT(YEAR FROM `Tb`.`date`)"
  # Every kind of projection: an aggregate, a window.
  @test key(_MR_MY.Result.objects.values("driverid", "laps" => Max("position")).order_by("laps")) == "(MAX(`Tb`.`position`)"
  @test key(_MR_MY.Result.objects.values("resultid", "laps" => _MR_QB.Rank(over = _MR_QB.WindowOver(order_by = ["-points"]))).order_by("laps")) ==
        "(CAST(RANK() OVER (ORDER BY `Tb`.`points` DESC) AS SIGNED)"
  # A projection that binds: the key binds its values again, where its markers print (SELECT 101,
  # WHERE 202, ORDER BY 101), and a `Value` the same.
  insp = _mr_inspect(_MR_MY.Result.objects.filter("grid__@gt" => 202).values("laps" => F("grid") + 101).order_by("-laps"))
  @test endswith(rstrip(insp[:sql_text]), "ORDER BY ((`Tb`.`grid` + ?) IS NULL) DESC, `laps` DESC")
  assert_marker_count(insp, :sqlite)
  assert_bound_in_text_order(insp, Any[101, 202, 101])
  insp = _mr_inspect(_MR_MY.Result.objects.values("resultid", "grid" => _MR_QB.Value(303), "g2" => F("grid") + 404).order_by("g2", "grid"))
  @test endswith(rstrip(insp[:sql_text]), "ORDER BY (`g2` IS NULL) ASC, `g2` ASC, \n  (? IS NULL) ASC, `grid` ASC")
  assert_bound_in_text_order(insp, Any[303, 404, 303])
  # PostgreSQL places NULLs natively, and SQLite 3.45 does too: no key, the alias as before.
  @test occursin("ORDER BY \"laps\" DESC NULLS FIRST", _mr_inspect(_MR_PG.Result.objects.values("laps" => "position").order_by("-laps"))[:sql_text])
  @test occursin("ORDER BY \"laps\" DESC NULLS FIRST", _mr_inspect(_MR_SL.Result.objects.values("laps" => "position").order_by("-laps"))[:sql_text])
  # MySQL is one of the engines every execution path renders (#1130 phase 5d): the internal fallback names
  # it among the pools it expects, and it no longer has an arm that calls a path a later phase's.
  msg = sprint(showerror, _MR_QB._unsupported_conn("date/interval arithmetic", nothing))
  @test occursin("expected a PostgreSQL, SQLite or MySQL connection pool", msg)
  @test MrMockMySQL() isa PormG._SQLEngine
  @test !occursin("later phase", sprint(showerror, _MR_QB._unsupported_conn("op", MrMockMySQL())))
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL DurationField filters: the column is its microseconds, and so is every value it meets (#1130)
# A `DurationField` is a BIGINT of microseconds on MySQL. Expected: an equality, a membership, an
# ordering and a range bind each duration as its microseconds — never the `HH:MM:SS` text, which MySQL
# would compare as the number its leading digits spell, silently; a duration string is parsed as the
# field parses it; `IS NULL` binds nothing; a value that is no duration raises what the field's
# formatter raises on every engine.
# Expected SQL: `WHERE `Tb`.`fastestlaptime` = ?` with `[80000000]`, `IN (?, ?)`, `BETWEEN ? AND ?`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL DurationField filters: the column is its microseconds, and so is every value" begin
  where_of(pair) = (r = _mr_inspect(_MR_MY.Result.objects.filter(pair));
                    (strip(split(r[:sql_text], "WHERE")[end]), r[:parameters]))
  @test where_of("fastestlaptime" => Second(80)) == ("`Tb`.`fastestlaptime` = ?", Any[80_000_000])
  @test where_of("fastestlaptime" => "00:01:20.5") == ("`Tb`.`fastestlaptime` = ?", Any[80_500_000])
  @test where_of("fastestlaptime__@ne" => Second(80)) == ("`Tb`.`fastestlaptime` != ?", Any[80_000_000])
  @test where_of("fastestlaptime__@in" => [Second(80), Second(90)]) ==
        ("`Tb`.`fastestlaptime` IN (?, ?)", Any[80_000_000, 90_000_000])
  @test where_of("fastestlaptime__@gt" => Minute(1)) == ("`Tb`.`fastestlaptime` > ?", Any[60_000_000])
  @test where_of("fastestlaptime__@range" => [Minute(1), Minute(2)]) ==
        ("`Tb`.`fastestlaptime` BETWEEN ? AND ?", Any[60_000_000, 120_000_000])
  @test where_of("fastestlaptime__@isnull" => true) == ("`Tb`.`fastestlaptime` IS NULL", Any[])
  # Against another interval: the two integers.
  @test where_of("fastestlaptime__@gt" => F("fastestlaptime") * 2) ==
        ("`Tb`.`fastestlaptime` > CAST(ROUND((`Tb`.`fastestlaptime`) * (?)) AS SIGNED)", Any[2])
  # No duration: the field's own refusal, as on SQLite.
  @test_throws PormG.InvalidValueError _mr_inspect(_MR_MY.Result.objects.filter("fastestlaptime" => 5))
  @test_throws PormG.InvalidValueError _mr_inspect(_MR_SL.Result.objects.filter("fastestlaptime" => 5))
  # SQLite keeps the stored text for an equality (#891) and its milliseconds for an ordering (#894).
  sl = _mr_inspect(_MR_SL.Result.objects.filter("fastestlaptime" => Second(80)))
  @test sl[:parameters] == Any["00:01:20"]
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL read parsers: what MySQL.jl delivers, turned into what the kind means
# #1270: the wire has no boolean (a `TINYINT(1)` reads as `Int8`, a comparison as `Int64`); a
# DATETIME has no zone and the session is UTC; `AVG` over an integer is a DECIMAL that means a float
# (#1121); a `DurationField` is a BIGINT of microseconds (#1130); and MySQL computes `NULLIF` over a
# DATE, a DATETIME or a TIME as text (measured on 8.4, phase 5b). Expected: those parsed — the interval
# into the `CompoundPeriod` SQLite reads, in the same units; the temporal text into the `Date`,
# `DateTime` or `Time` MySQL.jl decodes the column as, a `Time` to the microsecond — every parser
# fail-open on a value it does not recognize (a value MySQL.jl decoded passes unchanged), and no parser
# for text or an integer.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL read parsers: what MySQL.jl delivers, turned into what the kind means" begin
  my = MrMockMySQL()
  parse_bool = PormG.value_parser(PormG.CBool(), my)
  @test parse_bool(Int8(1)) === true && parse_bool(Int8(0)) === false && parse_bool(Int64(1)) === true
  @test parse_bool(missing) === missing && parse_bool(Int8(2)) === Int8(2)
  parse_ts = PormG.value_parser(PormG.CDateTime(true), my)
  @test parse_ts(DateTime(1991, 3, 10, 14, 0, 0, 125)) == ZonedDateTime(DateTime(1991, 3, 10, 14, 0, 0, 125), tz"UTC")
  @test parse_ts(missing) === missing
  @test parse_ts("1991-03-10 14:00:00.125") == ZonedDateTime(DateTime(1991, 3, 10, 14, 0, 0, 125), tz"UTC")
  # MySQL's temporal text, as `NULLIF` over each type returns it, back into the decoded type.
  parse_naive = PormG.value_parser(PormG.CDateTime(false), my)
  @test parse_naive("1991-03-10 14:00:00.125") === DateTime(1991, 3, 10, 14, 0, 0, 125)
  @test parse_naive("1991-03-10 14:00:00") === DateTime(1991, 3, 10, 14)
  @test parse_naive(DateTime(1991, 3, 10)) === DateTime(1991, 3, 10)
  @test parse_naive("1991-03-10 14:00:00.000001") == "1991-03-10 14:00:00.000001"   # below a DateTime's millisecond
  @test parse_naive("1991-02-30 14:00:00") == "1991-02-30 14:00:00" && parse_naive("x") == "x"
  parse_date = PormG.value_parser(PormG.CDate(), my)
  @test parse_date("2009-03-29") === Date(2009, 3, 29) && parse_date(Date(2009, 3, 29)) === Date(2009, 3, 29)
  @test parse_date("2009-03-29 10:00:00") == "2009-03-29 10:00:00" && parse_date(missing) === missing
  parse_time = PormG.value_parser(PormG.CTime(), my)
  @test parse_time("10:30:00.000000") === Time(10, 30)
  @test parse_time("23:59:59.999999") === Time(23, 59, 59, 999, 999)
  @test parse_time("10:30:00") === Time(10, 30) && parse_time(Time(10, 30)) === Time(10, 30)
  @test parse_time("25:00:00") == "25:00:00" && parse_time("-01:00:00") == "-01:00:00"
  parse_float = PormG.value_parser(PormG.CFloat64(), my)
  @test parse_float(Decimal(0, 16666666666666666666666666666667, -31)) === 1.6666666666666667
  @test parse_float(2.5) === 2.5
  parse_interval = PormG.value_parser(PormG.CInterval(), my)
  parse_sqlite_interval = PormG.value_parser(PormG.CInterval(), MrMockSQLite())
  # The same duration reads back as the same value, component by component, on both engines.
  for (us, text) in ((80_500_000, "00:01:20.5"), (-5_400_500_000, "-01:30:00.5"), (360_000_000_001, "100:00:00.000001"),
                     (0, "00:00:00"))
    @test (us, parse_interval(us).periods) == (us, parse_sqlite_interval(text).periods)
  end
  # A computed one (`SUM`, `/`) is a DECIMAL: rounded to the microsecond, half away from zero.
  @test parse_interval(Decimal(0, 805, 5)) == parse_interval(80_500_000)
  @test parse_interval(Decimal(0, 25, -1)) == parse_interval(3) && parse_interval(Decimal(1, 25, -1)) == parse_interval(-3)
  @test parse_interval(missing) === missing && parse_interval("00:01:20") == "00:01:20"
  for kind in (PormG.CText(), PormG.CInt64())
    @test (kind, PormG.value_parser(kind, my)) == (kind, nothing)
  end
  # #1110: a declared decimal's parser applies its width; a value that fits passes unchanged.
  @test PormG.value_parser(PormG.CDecimal(10, 2), my)(Decimal(0, 123456, -2)) == Decimal(0, 123456, -2)
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL division: the operator states which division the operands mean (#1130 phase 2b)
# MySQL's `/` keeps the fraction whatever its operands (`7 / 2` is `3.5`), so the walk's kinds pick
# the operator. Expected: `DIV` between two integer sides (columns, literals, an integer `Sum`), `/`
# beside a float or a decimal side, and a refusal on MySQL for a side the walk cannot type (a text
# column), naming the casts that state the meaning; PostgreSQL's `/` unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL division: DIV between integers, / beside a fraction, refused when untyped" begin
  sel(M, f) = _mr_inspect(M.Result.objects.values("h" => f))[:sql_text]
  @test occursin("(`Tb`.`grid` DIV ?) as `h`", sel(_MR_MY, F("grid") / 2))
  @test occursin("(`Tb`.`laps` DIV `Tb`.`grid`) as `h`", sel(_MR_MY, F("laps") / F("grid")))
  @test occursin("((SUM(`Tb`.`grid`) DIV 1) DIV ?)", _mr_inspect(_MR_MY.Result.objects.values("driverid", "h" => Sum("grid") / 2))[:sql_text])
  # A float side keeps the fraction, as the meaning says (`F("points") / 4` is `1.5` for 6 points).
  @test occursin("(`Tb`.`points` / ?) as `h`", sel(_MR_MY, F("points") / 4))
  @test occursin("(`Tb`.`grid` / ?) as `h`", sel(_MR_MY, F("grid") / 2.0))
  # PostgreSQL's integer `/` is already integer division: no DIV there.
  @test occursin("(\"Tb\".\"grid\" / \$1::bigint) as \"h\"", sel(_MR_PG, F("grid") / 2))
  # A side the walk cannot type: MySQL has no operator for "whichever division the type at run time
  # means", so it refuses, naming both casts. A text column along a relation is such a side.
  err = try; sel(_MR_MY, F("driverid__forename") / 2); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError
  msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
  @test occursin("MySQL's / always keeps the fraction, so PormG refuses it on MySQL", msg)
  @test occursin("Cast(x, IntegerField())", msg) && occursin("Cast(x, \"numeric\")", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL casts: each type name maps to the CAST target that holds its meaning (#1130 phase 2b)
# MySQL's CAST takes a closed set of targets, so a PormG type name is mapped, never passed through.
# Expected: text → CHAR, integers → SIGNED, a bare numeric → DECIMAL(65,30) (MySQL's bare DECIMAL is
# DECIMAL(10,0)), a sized one kept, real → FLOAT (single precision), the doubles → DOUBLE, timestamps
# → DATETIME(3), time → TIME(6), uuid → CHAR(36); arrays and network types refused through the
# capability table, and a name with no faithful target (boolean, interval, bytea, a user type)
# refused before any SQL. Why: an unmapped name reaching the server is either a syntax error or a
# cast to some other type than the one written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL casts: each type name maps to the CAST target that holds its meaning" begin
  my = MrMockMySQL()
  t(x) = PormG.Dialect.cast_type_sql(x, my)
  @test [t(x) for x in ("text", "varchar", "varchar(20)", "character varying(5)", "TEXT", "VARCHAR")] ==
        ["CHAR", "CHAR", "CHAR(20)", "CHAR(5)", "CHAR", "CHAR"]
  # PostgreSQL's unsized `char` is `char(1)`: one character, not the whole value.
  @test [t(x) for x in ("char", "character", "char(3)")] == ["CHAR(1)", "CHAR(1)", "CHAR(3)"]
  @test [t(x) for x in ("integer", "int", "int4", "smallint", "bigint", "int8", "INTEGER UNSIGNED")] == fill("SIGNED", 7)
  # A sized numeric is computed at the widest precision with its own scale (#1110: the read applies `p`).
  @test [t(x) for x in ("numeric", "decimal", "dec", "numeric(10,2)", "numeric(5)")] ==
        ["DECIMAL(65,30)", "DECIMAL(65,30)", "DECIMAL(65,30)", "DECIMAL(65,2)", "DECIMAL(65,0)"]
  @test [t(x) for x in ("real", "float4", "float", "float8", "double precision", "float(24)", "float(53)")] ==
        ["FLOAT", "FLOAT", "DOUBLE", "DOUBLE", "DOUBLE", "FLOAT(24)", "FLOAT(53)"]
  @test [t(x) for x in ("date", "timestamp", "timestamptz", "TIMESTAMPTZ", "timestamp with time zone",
                        "timestamp(3) with time zone", "timestamp(0)", "time", "time(3)")] ==
        ["DATE", "DATETIME(3)", "DATETIME(3)", "DATETIME(3)", "DATETIME(3)", "DATETIME(3)", "DATETIME(0)", "TIME(6)", "TIME(3)"]
  @test [t(x) for x in ("json", "jsonb", "uuid")] == ["JSON", "JSON", "CHAR(36)"]
  # A feature MySQL lacks is the capability table's refusal.
  @test_throws PormG.BackendCapabilityError t("integer[]")
  @test_throws PormG.BackendCapabilityError t("inet")
  # No faithful target: refused before any SQL, never passed through.
  for x in ("boolean", "bool", "interval", "bytea", "BLOB", "time with time zone", "mood", "integer(4)", "uuid(3)")
    err = try; t(x); nothing; catch e; e; end
    @test (x, err isa PormG.UnsupportedConnectionError) == (x, true)
    @test occursin("is not rendered for MySQL yet", sprint(showerror, err))
  end
  # The rendered cast, through the public `Cast`.
  sel(f) = _mr_inspect(_MR_MY.Result.objects.values("c" => f))[:sql_text]
  @test occursin("CAST(`Tb`.`grid` AS CHAR) as `c`", sel(PormG.QueryBuilder.Cast("grid", "text")))
  @test occursin("CAST(`Tb`.`points` AS DECIMAL(65,2)) as `c`", sel(PormG.QueryBuilder.Cast("points", "numeric(10,2)")))
  # #1110: a sized numeric is computed at MySQL's widest DECIMAL with its scale, so a value too wide for
  # `p` is not clamped (`DECIMAL(2,0)` makes 100 into 99), and the read applies `p`. Past 65, as written.
  @test occursin("CAST(`Tb`.`grid` AS DECIMAL(65,0)) as `c`", sel(PormG.QueryBuilder.Cast("grid", "numeric(2,0)")))
  @test occursin("CAST(`Tb`.`grid` AS DECIMAL(65,0)) as `c`", sel(PormG.QueryBuilder.Cast("grid", "numeric(7)")))
  @test occursin("CAST(`Tb`.`grid` AS DECIMAL(70,2)) as `c`", sel(PormG.QueryBuilder.Cast("grid", "numeric(70,2)")))
  # A precision no Int holds is left as written too, never a bare OverflowError (MySQL refuses it).
  @test PormG.Dialect.cast_type_sql("numeric(99999999999999999999,2)", MrMockMySQL()) == "DECIMAL(99999999999999999999,2)"
  parse_2_0 = PormG.value_parser(PormG.Kernel.CDecimal(2, 0), MrMockMySQL(), "c")
  @test parse_2_0(Decimal(0, 99, 0)) == Decimal(0, 99, 0) && ismissing(parse_2_0(missing))
  overflow = try; parse_2_0(Decimal(0, 100, 0)); nothing; catch e; e; end
  @test overflow isa PormG.StatementError && overflow.sqlstate == "22003" && overflow.adapter == "MySQL"
  @test occursin("numeric(2, 0)", sprint(showerror, overflow)) && !occursin("100", sprint(showerror, overflow))   # #971
  parse_4_2 = PormG.value_parser(PormG.Kernel.CDecimal(4, 2), MrMockMySQL(), "c")
  @test parse_4_2(Decimal(1, 9999, -2)) == Decimal(1, 9999, -2)                       # -99.99 fits
  @test (try; parse_4_2(Decimal(0, 10000, -2)); false; catch e; e isa PormG.StatementError; end)   # 100.00 does not
  # The departures still refuse first: a date's cast to a number is MySQL's departure (#1260).
  err = try; sel(PormG.QueryBuilder.Cast("raceid__date", "integer")); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError && occursin("MySQL computes its digits read as one number", sprint(showerror, err))
  # A temporal value cast to a single-precision float is no number either (#1260): MySQL keeps #1215's
  # single precision, so the operand rule must still run (review of #1130 2b: it returned early, and
  # `CAST(date AS FLOAT)` read back `20090329`).
  for target in ("real", "float4", "float(10)")
    err = try; sel(PormG.QueryBuilder.Cast("raceid__date", target)); nothing; catch e; e; end
    @test (target, err isa PormG.QueryBuildError) == (target, true)
    @test occursin("MySQL computes its digits read as one number", sprint(showerror, err))
  end
  @test occursin("CAST(`Tb`.`points` AS FLOAT)", sel(PormG.QueryBuilder.Cast("points", "real")))
  # A uuid cast compares as text on MySQL, as on SQLite: the engine fact the walk reads.
  @test PormG.QueryBuilder._cast_renders_text(PormG.Models.UUIDField(), my)
  @test !PormG.QueryBuilder._cast_renders_text(PormG.Models.IntegerField(), my)
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL Concat: CONCAT_WS('', …), never `||` (#1130 phase 2b, #1271)
# `||` is a logical OR on MySQL (`'a' || 'b'` is `0`), so a `Concat` never writes it. Expected:
# `CONCAT_WS('', a, b)`, which skips a NULL operand as PostgreSQL's `CONCAT` does (the public meaning,
# #1006), for one operand as for several; `CONCAT(a, b)` under `propagate_null` (the `@yyyy_q` label),
# where a NULL operand means a NULL result; a float operand still refused on MySQL as on every engine
# (explicit intent: a float's text is each engine's own). Why: a `||` reaching MySQL is a silent 0 or 1, not an error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL Concat: CONCAT_WS('', …), never ||" begin
  my = MrMockMySQL()
  @test PormG.Dialect.CONCAT(Any["`a`", "`b`"], Dict{String,Any}(), my) == "CONCAT_WS('',\n`a`,\n`b`)"
  @test PormG.Dialect.CONCAT(Any["`a`"], Dict{String,Any}(), my) == "CONCAT_WS('',\n`a`)"
  @test PormG.Dialect.CONCAT(Any["`a`", "`b`"], Dict{String,Any}("propagate_null" => true), my) == "CONCAT(`a`,\n`b`)"
  # Through the public `Concat`, over two text paths.
  sql = _mr_inspect(_MR_MY.Result.objects.values("c" => PormG.QueryBuilder.Concat("driverid__forename", "driverid__surname")))[:sql_text]
  @test occursin("CONCAT_WS('',", sql) && !occursin("||", sql)
  # A float operand is explicit intent on every engine (its text is each engine's own): MySQL refuses it too.
  err = try; _mr_inspect(_MR_MY.Result.objects.values("c" => PormG.QueryBuilder.Concat("driverid__surname", "points"))); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError && occursin("Cast(", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL date arithmetic: INTERVAL shifts and DATEDIFF, in the text order the binds follow (#1130 2b)
# MySQL's `+`/`-` on a date read it as the number its digits spell, so date arithmetic renders MySQL's
# own: a duration as one `± INTERVAL ? <unit>` per component (years first, as PostgreSQL's
# `make_interval` applies them), a day count as `± INTERVAL (n) DAY` (and `INTERVAL (n) DAY + date`
# when the count comes first, so its binds stay in text order), a date difference as `DATEDIFF`.
# Expected: those spellings, the bound values in text order, an untyped operand refused naming the
# typed spellings, and PostgreSQL's SQL unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL date arithmetic: INTERVAL shifts and DATEDIFF, in text order" begin
  q(f) = _mr_inspect(_MR_MY.Race.objects.values("v" => f))
  r = q(F("date") + Day(3))
  @test occursin("(`Tb`.`date` + INTERVAL ? DAY) as `v`", r[:sql_text]) && r[:parameters] == Any[3]
  # Years and months are ONE month count, as `make_interval` adds them: a year and then a month would
  # clamp at a month end first (`2008-02-29` + 1y + 1m: `2009-03-28`, where PostgreSQL says `2009-03-29`).
  r = q(F("date") - (Year(1) + Month(2)))
  @test occursin("(`Tb`.`date` - INTERVAL ? MONTH) as `v`", r[:sql_text]) && r[:parameters] == Any[14]
  r = q(F("date") + (Year(1) - Month(1) + Day(2)))
  @test occursin("((`Tb`.`date` + INTERVAL ? MONTH) + INTERVAL ? DAY)", r[:sql_text]) && r[:parameters] == Any[11, 2]
  # A year count too large for a month count raises rather than wrapping into a small shift.
  @test_throws OverflowError q(F("date") + Year(typemax(Int) ÷ 12 + 1))
  # A sub-second duration binds its seconds as a Float64, whose fraction MySQL keeps.
  r = _mr_inspect(_MR_MY.Race.objects.values("v" => F("date") + Millisecond(1500)))
  @test occursin("(`Tb`.`date` + INTERVAL ? SECOND)", r[:sql_text]) && r[:parameters] == Any[1.5]
  # A bare integer is a whole number of days; an integer column is a day count, either side.
  @test occursin("(`Tb`.`date` + INTERVAL ? DAY)", q(F("date") + 7)[:sql_text])
  @test occursin("(`Tb`.`date` + INTERVAL (`Tb`.`year`) DAY)", q(F("date") + F("year"))[:sql_text])
  @test occursin("(INTERVAL (`Tb`.`year`) DAY + `Tb`.`date`)", q(F("year") + F("date"))[:sql_text])
  @test occursin("DATEDIFF(`Tb`.`date`, `Tb`.`date`) as `v`", q(F("date") - F("date"))[:sql_text])
  # The binds follow the text: a filter value bound after the shift's own.
  r = _mr_inspect(_MR_MY.Race.objects.filter("year__@gt" => 1990).values("v" => F("date") + Day(3)))
  @test r[:parameters] == Any[3, 1990]
  # An operand PormG cannot type: MySQL's `+` would read the date's digits (`20090329 + 1`).
  err = try; q(F("date") + Sum("year")); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError
  @test occursin("MySQL, where `+` reads a date as the number its digits spell", sprint(showerror, err))
  # PostgreSQL's spelling is unchanged.
  @test occursin("make_interval(days => \$1::integer)", _mr_inspect(_MR_PG.Race.objects.values("v" => F("date") + Day(3)))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL intervals: a DurationField is its microseconds, and every interval computes in them (#1130)
# MySQL has no interval type; a `DurationField` is a BIGINT of microseconds there (Django's choice), so
# the integer SQLite converts its `HH:MM:SS` text into is MySQL's stored value itself: a column is used
# as it is, a computed interval leaves the expression as it is, and a duration literal binds its count.
# Expected SQL, each pinned below:
#   timestamp difference  `(-TIMESTAMPDIFF(MICROSECOND, l, r))` — `l` first, so its binds come first;
#   date ± interval       `(date ± INTERVAL (d) MICROSECOND)`, `(INTERVAL (d) MICROSECOND + date)`;
#   interval × number     `CAST(ROUND((d) * (?)) AS SIGNED)`, and `AVG` the same, half away from zero.
# What has no meaning — an interval plus a number, times an interval, a number compared with one —
# is refused before any SQL, naming MySQL, as SQLite refuses it naming SQLite.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL intervals: a DurationField is its microseconds, and every interval computes in them" begin
  sql(build) = (r = _mr_inspect(build()); (r[:sql_text], r[:parameters]))
  proj(build) = (r = sql(build); (strip(split(split(r[1], "SELECT")[end], " as `v`")[1]), r[2]))
  R = _MR_MY.Result
  @test proj(() -> R.objects.values("v" => F("fastestlaptime"))) == ("`Tb`.`fastestlaptime`", Any[])
  @test proj(() -> R.objects.values("v" => Sum("fastestlaptime"))) == ("SUM(`Tb`.`fastestlaptime`)", Any[])
  @test proj(() -> R.objects.values("v" => Max("fastestlaptime"))) == ("MAX(`Tb`.`fastestlaptime`)", Any[])
  @test proj(() -> R.objects.values("v" => Avg("fastestlaptime"))) ==
        ("CAST(ROUND(AVG(`Tb`.`fastestlaptime`)) AS SIGNED)", Any[])
  @test proj(() -> R.objects.values("v" => F("fastestlaptime") * 2)) ==
        ("CAST(ROUND((`Tb`.`fastestlaptime`) * (?)) AS SIGNED)", Any[2])
  @test proj(() -> R.objects.values("v" => F("fastestlaptime") / 2)) ==
        ("CAST(ROUND((`Tb`.`fastestlaptime`) * 1.0 / (?)) AS SIGNED)", Any[2])
  @test proj(() -> R.objects.values("v" => F("fastestlaptime") + F("fastestlaptime"))) ==
        ("(`Tb`.`fastestlaptime` + `Tb`.`fastestlaptime`)", Any[])
  # A date shifted by an interval, on either side; a timestamp difference, its left side binding first.
  @test proj(() -> R.objects.values("v" => F("raceid__date") + F("fastestlaptime"))) ==
        ("(`Tb_1`.`date` + INTERVAL (`Tb`.`fastestlaptime`) MICROSECOND)", Any[])
  @test proj(() -> R.objects.values("v" => F("raceid__date") - F("fastestlaptime"))) ==
        ("(`Tb_1`.`date` - INTERVAL (`Tb`.`fastestlaptime`) MICROSECOND)", Any[])
  @test proj(() -> R.objects.values("v" => F("fastestlaptime") + F("raceid__date"))) ==
        ("(INTERVAL (`Tb`.`fastestlaptime`) MICROSECOND + `Tb_1`.`date`)", Any[])
  diff = (F("raceid__date") + Hour(6)) - F("driverid__dob")
  @test proj(() -> R.objects.values("v" => diff)) ==
        ("(-TIMESTAMPDIFF(MICROSECOND, (`Tb_1`.`date` + INTERVAL ? HOUR), `Tb_2`.`dob`))", Any[6])
  @test _MR_QB._temporal_difference_sql(MrMockMySQL(), "`a`", "`b`", PormG.CInt32()) == ("DATEDIFF(`a`, `b`)", PormG.CInt32())
  # Compared with a duration: its microseconds, for an equality too (the stored value is the number).
  @test occursin("WHERE ((-TIMESTAMPDIFF(MICROSECOND, (`Tb_1`.`date` + INTERVAL ? HOUR), `Tb_2`.`dob`)) = ?)",
                 sql(() -> R.objects.filter(diff == Hour(1)))[1])
  @test sql(() -> R.objects.filter(diff == Hour(1)))[2] == Any[6, 3_600_000_000]
  @test occursin("WHERE (`Tb`.`fastestlaptime` = ?)", sql(() -> R.objects.filter(F("fastestlaptime") == Second(80)))[1])
  @test sql(() -> R.objects.filter(F("fastestlaptime") == "00:01:20"))[2] == Any[80_000_000]
  @test sql(() -> R.objects.filter(F("fastestlaptime") > Hour(1)))[2] == Any[3_600_000_000]
  # An ordering is the column itself; so is an alias's, and an ordering filter on one.
  @test occursin("ORDER BY (`Tb`.`fastestlaptime` IS NULL) ASC, `Tb`.`fastestlaptime` ASC",
                 sql(() -> R.objects.values("resultid").order_by("fastestlaptime"))[1])
  q = R.objects; q.values("v" => F("fastestlaptime")); q.filter("v__@gt" => Hour(1))
  @test occursin("WHERE `Tb`.`fastestlaptime` > ?", sql(() -> q)[1]) && sql(() -> q)[2] == Any[3_600_000_000]
  # A duration literal binds its microseconds, inside a function and as a projection (#1316's alias).
  @test proj(() -> R.objects.values("v" => Max(PormG.QueryBuilder.Value(Hour(1))))) == ("MAX(?)", Any[3_600_000_000])
  q = R.objects; q.values("v" => PormG.QueryBuilder.Value(Hour(100))); q.filter("v__@gt" => Hour(99))
  @test sql(() -> q)[2] == Any[360_000_000_000, 360_000_000_000, 356_400_000_000]
  # No meaning: refused before any SQL, naming MySQL.
  refused(build) = (e = try; _mr_inspect(build()); nothing; catch err; err; end;
                    e isa PormG.QueryBuildError && occursin("is not supported on MySQL", sprint(showerror, e)))
  @test refused(() -> R.objects.values("v" => F("fastestlaptime") + 1))
  @test refused(() -> R.objects.values("v" => F("fastestlaptime") * F("fastestlaptime")))
  @test refused(() -> R.objects.values("v" => F("points") + F("fastestlaptime")))
  @test refused(() -> R.objects.values("v" => F("grid") + F("fastestlaptime")))
  @test refused(() -> R.objects.values("v" => PormG.QueryBuilder.Abs("fastestlaptime")))
  # A number compared with an interval: SQLite compares the stored text (its #881 rule); MySQL would
  # compare a count with microseconds, so it refuses an ordering and an equality alike.
  @test refused(() -> R.objects.filter(F("grid") > F("fastestlaptime")))
  @test refused(() -> R.objects.filter(F("grid") == F("fastestlaptime")))
  @test refused(() -> R.objects.filter(F("grid") != F("fastestlaptime")))
  @test occursin("(`Tb`.`grid` = `Tb`.`fastestlaptime`)" |> x -> replace(x, '`' => '"'),
                 sql(() -> _MR_SL.Result.objects.filter(F("grid") == F("fastestlaptime")))[1])
  # ... and with the interval on the left, through an expression, a filter pair either way round, a
  # `Subquery`, and an interval alias: every path that compares two expressions (review of #1130).
  sub = (s = _MR_MY.Result.objects; s.filter("resultid" => PormG.OuterRef("resultid")); s.values("t" => F("fastestlaptime")); s)
  subn = (s = _MR_MY.Result.objects; s.filter("resultid" => PormG.OuterRef("resultid")); s.values("t" => F("grid")); s)
  for (label, build) in (
      "interval == number" => () -> R.objects.filter(F("fastestlaptime") == F("grid")),
      "interval > float" => () -> R.objects.filter(F("fastestlaptime") > F("points")),
      "computed == number" => () -> R.objects.filter((F("fastestlaptime") * 2) == F("grid")),
      "pair interval => number" => () -> R.objects.filter("fastestlaptime" => F("grid")),
      "pair interval @gt number" => () -> R.objects.filter("fastestlaptime__@gt" => F("grid")),
      "pair number => interval" => () -> R.objects.filter("grid" => F("fastestlaptime")),
      "pair number @gt interval" => () -> R.objects.filter("grid__@gt" => F("fastestlaptime")),
      "pair number => Subquery(interval)" => () -> R.objects.filter("grid" => PormG.Subquery(sub)),
      "interval alias @gt number" => () -> (q = R.objects; q.values("v" => F("fastestlaptime")); q.filter("v__@gt" => F("grid")); q),
      "pair interval @gt function" => () -> R.objects.filter("fastestlaptime__@gt" => PormG.QueryBuilder.Cast("grid", "integer")),
      "pair interval @gt Subquery(number)" => () -> R.objects.filter("fastestlaptime__@gt" => PormG.Subquery(subn)),
      "interval == Subquery(number)" => () -> R.objects.filter(F("fastestlaptime") == PormG.Subquery(subn)),
      "number == Subquery(interval)" => () -> R.objects.filter(F("grid") == PormG.Subquery(sub)),
      "number > Subquery(interval)" => () -> R.objects.filter(F("grid") > PormG.Subquery(sub)),
      "interval @in queryset of numbers" => () -> R.objects.filter("fastestlaptime__@in" => _MR_MY.Result.objects.values("grid")),
      "number @in queryset of intervals" => () -> R.objects.filter("grid__@in" => _MR_MY.Result.objects.values("fastestlaptime")),
      "interval alias @gt Subquery(number)" => () -> (q = R.objects; q.values("v" => F("fastestlaptime")); q.filter("v__@gt" => PormG.Subquery(subn)); q),
      "computed interval > 5" => () -> R.objects.filter((F("fastestlaptime") * 2) > 5),
      "interval alias @in queryset of numbers" =>
        () -> (q = R.objects; q.values("v" => F("fastestlaptime") * 2); q.filter("v__@in" => _MR_MY.Result.objects.values("grid")); q),
      "Sum alias @in queryset of numbers" =>
        () -> (q = R.objects; q.values("driverid", "s" => Sum("fastestlaptime")); q.filter("s__@in" => _MR_MY.Result.objects.values("grid")); q),
      "number alias @nin queryset of intervals" =>
        () -> (q = R.objects; q.values("v" => F("grid")); q.filter("v__@nin" => _MR_MY.Result.objects.values("fastestlaptime")); q))
    @test (label, refused(build)) == (label, true)
  end
  # Two intervals still compare, and SQLite keeps its own rules for the same pair.
  @test sql(() -> R.objects.filter("fastestlaptime" => F("fastestlaptime")))[1] |> x -> occursin("`Tb`.`fastestlaptime` = `Tb`.`fastestlaptime`", x)
  @test occursin("`Tb`.`fastestlaptime` > (SELECT", sql(() -> R.objects.filter("fastestlaptime__@gt" => PormG.Subquery(sub)))[1])
  @test !refused(() -> _MR_SL.Result.objects.filter("fastestlaptime" => F("grid")))
  # Interval against an interval builds through each of those paths.
  @test occursin("`Tb`.`fastestlaptime` IN (SELECT", sql(() -> R.objects.filter("fastestlaptime__@in" => _MR_MY.Result.objects.values("fastestlaptime")))[1])
  # ... an interval alias in a queryset of intervals, a `Sum` alias in HAVING too ...
  @test occursin("IN (SELECT", sql(() -> (q = R.objects; q.values("v" => F("fastestlaptime") * 2);
                                          q.filter("v__@in" => _MR_MY.Result.objects.values("fastestlaptime")); q))[1])
  @test occursin("HAVING SUM(`Tb`.`fastestlaptime`) IN (SELECT",
                 sql(() -> (q = R.objects; q.values("driverid", "s" => Sum("fastestlaptime"));
                            q.filter("s__@in" => _MR_MY.Result.objects.values("fastestlaptime")); q))[1])
  # ... and a queryset whose column its build cannot type (a NULL literal) is left to the server.
  @test occursin("IN (SELECT", sql(() -> R.objects.filter("fastestlaptime__@in" =>
                                       _MR_MY.Result.objects.values("t" => PormG.QueryBuilder.Value(nothing))))[1])
  @test occursin("(`Tb`.`fastestlaptime` = (SELECT", sql(() -> R.objects.filter(F("fastestlaptime") == PormG.Subquery(sub)))[1])
  @test occursin("`Tb`.`fastestlaptime` > (SELECT",
                 sql(() -> (q = R.objects; q.values("v" => F("fastestlaptime")); q.filter("v__@gt" => PormG.Subquery(sub)); q))[1])
  # A duration string against a computed interval binds its count; one that is no duration raises, as
  # the duration formatter does, rather than a text compared with a number (`'00:01:00'` is `0` there).
  @test sql(() -> R.objects.filter((F("fastestlaptime") * 2) == "00:01:00"))[2] == Any[2, 60_000_000]
  @test refused(() -> R.objects.filter((F("fastestlaptime") * 2) == "a minute"))
  # A duration literal's alias compared with a number: refused as any other interval alias is.
  e = try; _mr_inspect((q = R.objects; q.values("v" => PormG.QueryBuilder.Value(Hour(100))); q.filter("v__@gt" => 10); q))
      nothing; catch err; err; end
  @test e isa PormG.InvalidValueError && occursin("projection alias", sprint(showerror, e))
  # A cast to text prints the `HH:MM:SS` text PormG writes, not the stored count (`80500000`), read once
  # through a derived table; a number is untouched.
  cast = PormG.QueryBuilder.Cast
  @test occursin("CAST($(PormG.Dialect._mysql_interval_text("`Tb`.`fastestlaptime`")) AS CHAR) as `v`",
                 sql(() -> R.objects.values("v" => cast("fastestlaptime", "text")))[1])
  @test occursin("FROM (SELECT CAST(ROUND((`Tb`.`fastestlaptime`) * (?)) AS SIGNED) AS `_pormg_us`)",
                 sql(() -> R.objects.values("v" => cast(F("fastestlaptime") * 2, "varchar(20)")))[1])
  @test proj(() -> R.objects.values("v" => cast("grid", "text"))) == ("CAST(`Tb`.`grid` AS CHAR)", Any[])
  # Every target MySQL holds as text, and JSON (which then fails at the server, as PostgreSQL's does).
  @test occursin("`_pormg_us`) AS `_pormg_d`) AS CHAR(36)) as `v`", sql(() -> R.objects.values("v" => cast("fastestlaptime", "uuid")))[1])
  @test occursin("`_pormg_us`) AS `_pormg_d`) AS JSON) as `v`", sql(() -> R.objects.values("v" => cast("fastestlaptime", "json")))[1])
  # A date, a time or a timestamp cast would read the count's digits: refused on MySQL.
  for t in ("date", "time", "timestamp", "timestamptz")
    e = try; _mr_inspect(R.objects.values("v" => cast("fastestlaptime", t))); nothing; catch err; err; end
    @test (t, e isa PormG.QueryBuildError && occursin("of an interval is not supported on MySQL", sprint(showerror, e))) == (t, true)
  end
  # The per-engine edges: MySQL's are the identity; SQLite's are its own Dialect helpers, unchanged.
  @test _MR_QB._interval_text_as_ms("`c`", MrMockMySQL()) == "`c`"
  @test _MR_QB._interval_ms_as_text("?", MrMockMySQL()) == "?"
  @test _MR_QB._interval_text_as_ms("`c`", MrMockSQLite()) == PormG.Dialect._sqlite_interval_ms("`c`")
  @test _MR_QB._interval_ms_as_text("?", MrMockSQLite()) == PormG.Dialect._sqlite_interval_text("?")
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL bitwise operators: signed 64-bit results, an arithmetic right shift, and xor (#1130 phase 5b)
# MySQL computes `&`, `|`, `<<`, `>>`, `~` and `^` on BIGINT UNSIGNED (measured on 8.4: `~5` is
# 18446744073709551610, `-8 >> 1` is 9223372036854775804), where PostgreSQL and SQLite compute signed
# 64-bit integers (-6, -4). Expected SQL: each result `CAST(… AS SIGNED)`; `>>` as
# `FLOOR(CAST(a AS DECIMAL(20, 0)) / (1 << b))`, which names `a` once, so each value binds once in text
# order; `xor` as `^`, in a projection and an UPDATE alike. PostgreSQL and SQLite render as before.
# Why: the unsigned results were silent wrong values, and `xor` was refused on MySQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL bitwise operators: signed results, an arithmetic right shift, and xor" begin
  R = _MR_MY.Result
  proj(e) = (r = _mr_inspect(R.objects.values("v" => e));
             (strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `v`")[1], r"\s+" => " ")), r[:parameters]))
  @test proj(F("grid") & 4) == ("CAST((`Tb`.`grid` & ?) AS SIGNED)", Any[4])
  @test proj(F("grid") | F("laps")) == ("CAST((`Tb`.`grid` | `Tb`.`laps`) AS SIGNED)", Any[])
  @test proj(~F("grid")) == ("CAST(~(`Tb`.`grid`) AS SIGNED)", Any[])
  @test proj(F("grid") << 2) == ("CAST((`Tb`.`grid` << ?) AS SIGNED)", Any[2])
  @test proj(F("grid") >> 2) == ("CAST(FLOOR(CAST(`Tb`.`grid` AS DECIMAL(20, 0)) / (1 << ?)) AS SIGNED)", Any[2])
  @test proj(xor(F("grid"), 3)) == ("CAST((`Tb`.`grid` ^ ?) AS SIGNED)", Any[3])
  # Nested: the inner result is signed before the outer operator reads it, and the values bind in order.
  @test proj((F("grid") & 12) >> 1) ==
        ("CAST(FLOOR(CAST(CAST((`Tb`.`grid` & ?) AS SIGNED) AS DECIMAL(20, 0)) / (1 << ?)) AS SIGNED)", Any[12, 1])
  upd = R.objects.filter("grid" => 1).update("laps" => xor(F("laps"), 6); show_query = :dict)
  @test upd[:sql_text] == "UPDATE `result` AS `Tb`\nSET `laps` = CAST((`Tb`.`laps` ^ ?) AS SIGNED)\nWHERE `Tb`.`grid` = ?\n"
  @test upd[:parameters] == Any[6, 1]
  # PostgreSQL and SQLite are unchanged: `#` and SQLite's `(a | b) - (a & b)`, each side bound twice.
  pg = _mr_inspect(_MR_PG.Result.objects.values("v" => xor(F("grid"), 3)))
  @test occursin("(\"Tb\".\"grid\" # \$1::bigint)", pg[:sql_text])
  sl = _mr_inspect(_MR_SL.Result.objects.values("v" => xor(F("grid"), 3)))
  @test occursin("(((\"Tb\".\"grid\") | (?)) - ((\"Tb\".\"grid\") & (?)))", sl[:sql_text]) && sl[:parameters] == Any[3, 3]
  @test occursin("(\"Tb\".\"grid\" >> ?)", _mr_inspect(_MR_SL.Result.objects.values("v" => F("grid") >> 2))[:sql_text])
  @test occursin("~(\"Tb\".\"grid\")", _mr_inspect(_MR_PG.Result.objects.values("v" => ~F("grid")))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL conditionals: Case/When, Coalesce, Greatest/Least and NullIf (#1130 phase 2c-1)
# MySQL has each of them natively. Expected SQL: `COALESCE(a, ?)`; `GREATEST(COALESCE(a, b),
# COALESCE(b, a))` (MySQL's GREATEST/LEAST return NULL on any NULL, so the operands are the #844
# rotations, and never SQLite's `MAX`/`MIN`, which are aggregates on MySQL); `NULLIF(a, ?)` with no
# cast back (MySQL keeps `a`'s type, measured); `CASE WHEN c THEN ? ELSE ? END` binding in text order;
# a declared `output_field` is `CAST(… AS T)`.
# Why: before phase 2c-1 each raised a `MethodError` on MySQL; SQLite's `MAX`/`MIN` would be aggregates
# there, and a cast back over `NULLIF` would be a second, needless conversion.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL conditionals: Case/When, Coalesce, Greatest/Least and NullIf render MySQL's own SQL" begin
  QB = PormG.QueryBuilder
  R = _MR_MY.Result
  proj(build) = (r = _mr_inspect(build()); (strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `v`")[1], r"\s+" => " ")),
                                             r[:parameters]))
  @test proj(() -> R.objects.values("v" => QB.Coalesce("position", 0))) == ("COALESCE(`Tb`.`position`, ?)", Any[0])
  @test proj(() -> R.objects.values("v" => QB.Greatest("grid", "laps"))) ==
        ("GREATEST(COALESCE(`Tb`.`grid`, `Tb`.`laps`), COALESCE(`Tb`.`laps`, `Tb`.`grid`))", Any[])
  @test proj(() -> R.objects.values("v" => QB.Least("grid", "position"))) ==
        ("LEAST(COALESCE(`Tb`.`grid`, `Tb`.`position`), COALESCE(`Tb`.`position`, `Tb`.`grid`))", Any[])
  @test proj(() -> R.objects.values("v" => QB.NullIf("grid", 1.5))) == ("NULLIF(`Tb`.`grid`, ?)", Any[1.5])
  @test proj(() -> R.objects.values("v" => QB.Case(QB.When("grid__@gt" => 5, then = "back"), default = "front"))) ==
        ("CASE WHEN `Tb`.`grid` > ? THEN ? ELSE ? END", Any[5, "back", "front"])
  @test proj(() -> R.objects.values("v" => QB.Coalesce("position", 0; output_field = "numeric(10,2)"))) ==
        ("CAST(COALESCE(`Tb`.`position`, ?) AS DECIMAL(65,2))", Any[0])
  @test proj(() -> R.objects.values("v" => QB.Case(QB.When("grid__@gt" => 5, then = 1), default = 0; output_field = "text"))) ==
        ("CAST(CASE WHEN `Tb`.`grid` > ? THEN ? ELSE ? END AS CHAR)", Any[5, 1, 0])
  # SQLite keeps its `MAX`, PostgreSQL its native NULL-skipping GREATEST: unchanged.
  @test occursin("MAX(COALESCE(", _mr_inspect(_MR_SL.Result.objects.values("v" => QB.Greatest("grid", "laps")))[:sql_text])
  @test occursin("GREATEST(\"Tb\".\"grid\", \"Tb\".\"laps\")", _mr_inspect(_MR_PG.Result.objects.values("v" => QB.Greatest("grid", "laps")))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL declared types a plain CAST would misread (#1130 phase 2c-1)
# MySQL stores an interval as its microseconds and casts to no boolean type, so the engine that departs
# decides on itself. Expected: an interval to text reads the `HH:MM:SS` text (`_mysql_interval_text`)
# for `Coalesce` as for `Cast`; to an interval it is the count itself; to a date it is refused; a
# boolean target over booleans or integers is `((x) <> 0)` and over anything else refused; an interval
# beside another type is refused, declared or not (`Coalesce("fastestlaptime", 0)` read the duration as
# its count); a NULL operand is no value of another type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL declared types: intervals and booleans decided on MySQL" begin
  QB = PormG.QueryBuilder
  R = _MR_MY.Result
  sql(build) = (r = _mr_inspect(build()); (replace(r[:sql_text], r"\s+" => " "), r[:parameters]))
  refused(build, needle) = (e = try; _mr_inspect(build()); nothing; catch err; err; end;
                            e isa PormG.QueryBuildError && occursin(needle, sprint(showerror, e)))
  hour = QB.Value(Hour(1))
  text = sql(() -> R.objects.values("v" => QB.Coalesce("fastestlaptime", hour; output_field = "text")))
  @test occursin("CAST($(PormG.Dialect._mysql_interval_text("COALESCE(`Tb`.`fastestlaptime`, ?)")) AS CHAR)", text[1])
  @test text[2] == Any[3_600_000_000]
  @test occursin("SELECT COALESCE(`Tb`.`fastestlaptime`, ?) as `v`",
                 sql(() -> R.objects.values("v" => QB.Coalesce("fastestlaptime", hour; output_field = "interval")))[1])
  @test occursin("SELECT `Tb`.`fastestlaptime` as `v`", sql(() -> R.objects.values("v" => QB.Cast("fastestlaptime", "interval")))[1])
  @test refused(() -> R.objects.values("v" => QB.Coalesce("fastestlaptime", hour; output_field = "date")),
                "of an interval is not supported on MySQL")
  @test refused(() -> R.objects.values("v" => QB.Coalesce("fastestlaptime", 0; output_field = "text")),
                "over an interval and a value of another type is not supported on MySQL")
  # Each names the function the caller wrote, not `Greatest`'s inner rotation.
  for (fn, build) in ("Greatest" => () -> R.objects.values("v" => QB.Greatest("fastestlaptime", 0)),
                      "Least" => () -> R.objects.values("v" => QB.Least("fastestlaptime", 0)),
                      "NullIf" => () -> R.objects.values("v" => QB.NullIf("fastestlaptime", 0)))
    @test (fn, refused(build, "$(fn)(…) over an interval and a value of another type")) == (fn, true)
  end
  # `Greatest` over durations, declared text: the `HH:MM:SS` text of the greatest, never its count.
  gt = sql(() -> R.objects.values("v" => QB.Greatest("fastestlaptime", hour; output_field = "text")))[1]
  @test occursin("CAST($(PormG.Dialect._mysql_interval_text("GREATEST(COALESCE(`Tb`.`fastestlaptime`, ?), COALESCE(?, `Tb`.`fastestlaptime`))")) AS CHAR)", gt)
  for (label, build) in ("Coalesce(d, 0)" => () -> R.objects.values("v" => QB.Coalesce("fastestlaptime", 0)),
                         "Greatest(d, 0)" => () -> R.objects.values("v" => QB.Greatest("fastestlaptime", 0)),
                         "NullIf(d, 0)" => () -> R.objects.values("v" => QB.NullIf("fastestlaptime", 0)),
                         "Case(d | 0)" => () -> R.objects.values("v" => QB.Case(QB.When("grid__@gt" => 5,
                                                   then = F("fastestlaptime")), default = 0)))
    @test (label, refused(build, "over an interval and a value of another type is not supported on MySQL")) == (label, true)
  end
  # A duration beside a duration, or beside NULL, builds; SQLite keeps its own answer for the mixed one.
  @test occursin("COALESCE(`Tb`.`fastestlaptime`, ?)",
                 sql(() -> R.objects.values("v" => QB.Coalesce("fastestlaptime", QB.Value(Second(0)))))[1])
  @test occursin("NULLIF(`Tb`.`fastestlaptime`, ?)", sql(() -> R.objects.values("v" => QB.NullIf("fastestlaptime", hour)))[1])
  @test occursin("ELSE NULL", sql(() -> R.objects.values("v" => QB.Case(QB.When("grid__@gt" => 5,
                                    then = F("fastestlaptime")))))[1])
  @test !refused(() -> _MR_SL.Result.objects.values("v" => QB.Coalesce("fastestlaptime", 0)), "")
  @test occursin("SELECT ((CASE WHEN `Tb`.`grid` > ? THEN ? ELSE ? END) <> 0) as `v`",
                 sql(() -> R.objects.values("v" => QB.Case(QB.When("grid__@gt" => 5, then = 2), default = 0; output_field = "boolean")))[1])
  # Over a boolean value too, and a NULL operand is no other type.
  @test occursin("((?) <> 0) as `v`", sql(() -> R.objects.values("v" => QB.Cast(QB.Value(true), "boolean")))[1])
  @test occursin("((COALESCE(`Tb`.`grid`, NULL)) <> 0)",
                 sql(() -> R.objects.values("v" => QB.Coalesce("grid", QB.Value(nothing); output_field = "boolean")))[1])
  @test refused(() -> R.objects.values("v" => QB.Cast("fastestlaptime", "boolean")), "of an interval is not supported on MySQL")
  @test occursin("((`Tb`.`grid`) <> 0) as `v`", sql(() -> R.objects.values("v" => QB.Cast("grid", "boolean")))[1])
  for (label, then, default) in (("text", "y", "n"), ("float", 1.5, 0.0))
    @test (label, refused(() -> R.objects.values("v" => QB.Case(QB.When("grid__@gt" => 5, then = then), default = default;
                                                                output_field = "boolean")),
                          "is not supported on MySQL over a value that is not a boolean or an integer")) == (label, true)
  end
  # PostgreSQL and SQLite render their own casts, unchanged.
  @test occursin("::boolean", _mr_inspect(_MR_PG.Result.objects.values("v" => QB.Cast("grid", "boolean")))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL Decimal binds state their DECIMAL (#1130 phase 2c-1)
# The extension binds a `Decimals.Decimal` as its exact text, which MySQL types as a string: a `CASE`
# with such a branch read back text and ordered as text (measured: `'10.00' < '5.50'`). Expected: the
# marker is `CAST(? AS DECIMAL(p,s))` at the value's own precision and scale; every other value keeps
# `?`; a value past MySQL's DECIMAL (65 digits, a scale of 30) is refused rather than bound as text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL Decimal binds state their DECIMAL" begin
  QB = PormG.QueryBuilder
  ph = QB._mysql_placeholder
  @test ph(parse(Decimal, "5.50")) == "CAST(? AS DECIMAL(2,1))"
  @test ph(parse(Decimal, "-123.45")) == "CAST(? AS DECIMAL(5,2))"
  @test ph(parse(Decimal, "0.005")) == "CAST(? AS DECIMAL(3,3))"
  @test ph(Decimal(0, 12, 1)) == "CAST(? AS DECIMAL(3,0))"
  @test ph(Decimal(0, 0, 0)) == "CAST(? AS DECIMAL(1,0))"
  @test_throws PormG.QueryBuildError ph(Decimal(0, big(10)^70, 0))
  @test_throws PormG.QueryBuildError ph(Decimal(0, big(10)^65, 0))   # 66 digits: one past the limit
  @test ph(Decimal(0, big(10)^64, 0)) == "CAST(? AS DECIMAL(65,0))"  # 65 digits: the limit itself
  @test_throws PormG.QueryBuildError ph(Decimal(0, 1, -31))
  @test ph(5) == "?" && ph(2.5) == "?" && ph("5.50") == "?"
  r = _mr_inspect(_MR_MY.Result.objects.values("v" => QB.Case(QB.When("grid__@gt" => 5, then = parse(Decimal, "10.25")),
                                                               default = parse(Decimal, "5.5"))))
  @test occursin("THEN CAST(? AS DECIMAL(4,2)) ELSE CAST(? AS DECIMAL(2,1)) END", replace(r[:sql_text], r"\s+" => " "))
  @test r[:parameters] == Any[5, parse(Decimal, "10.25"), parse(Decimal, "5.5")]
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL math: each function is MySQL's own (#1130 phase 2c-2)
# Measured on 8.4: `ABS`/`FLOOR`/`CEIL`/`ROUND` keep an integer exactly (a `BIGINT` past 2^53 too) and
# `ROUND` takes a negative precision (`ROUND(125, -1)` is 130). Expected: `ABS(x)`, `FLOOR(x)`, `CEIL(x)`,
# `SQRT(x)`, `EXP(x)`, `LN(x)`, `POWER(a, ?)`, `MOD(a, ?)` bare; `Round` over an integer `ROUND(x)` with
# its places dropped, or `ROUND(x, ?)` for a negative precision, which builds on MySQL and stays refused
# on SQLite (`BackendCapabilityError`).
# Why: before phase 2c-2 each raised a `MethodError` on MySQL; PostgreSQL's `::numeric` casts would be
# needless there, since MySQL computes each over an integer as an integer.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL math: each function is MySQL's own, an integer kept" begin
  QB = PormG.QueryBuilder
  R = _MR_MY.Result
  proj(build) = (r = _mr_inspect(build()); (strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `v`")[1], r"\s+" => " ")),
                                             r[:parameters]))
  @test proj(() -> R.objects.values("v" => QB.Abs("grid"))) == ("ABS(`Tb`.`grid`)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Floor("points"))) == ("FLOOR(`Tb`.`points`)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Ceil("grid"))) == ("CEIL(`Tb`.`grid`)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Sqrt("grid"))) == ("SQRT(`Tb`.`grid`)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Exp("points"))) == ("EXP(`Tb`.`points`)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Ln("points"))) == ("LN(`Tb`.`points`)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Power("grid", 2))) == ("POWER(`Tb`.`grid`, ?)", Any[2])
  @test proj(() -> R.objects.values("v" => QB.Mod("grid", 3))) == ("MOD(`Tb`.`grid`, ?)", Any[3])
  @test proj(() -> R.objects.values("v" => QB.Round("grid", 2))) == ("ROUND(`Tb`.`grid`)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Round("grid", -1))) == ("ROUND(`Tb`.`grid`, ?)", Any[-1])
  # An integer value that comes from parameters is typed by the function it stands in (`ABS(?)`,
  # `ABS(COALESCE(?, ?))` and `ABS(CASE WHEN `x` > ? THEN ? ELSE ? END)` are a DOUBLE, `ROUND(?)` a
  # DECIMAL, measured), so an integer operand is stated as one with `+ 0` (a `BIGINT UNSIGNED` stays
  # one, where `CAST(? AS SIGNED)` wraps). A bare column, and a float operand, are left as they are.
  @test proj(() -> R.objects.values("v" => QB.Round(QB.Value(125), -1))) == ("ROUND((? + 0), ?)", Any[125, -1])
  @test proj(() -> R.objects.values("v" => QB.Abs(QB.Value(-5)))) == ("ABS((? + 0))", Any[-5])
  @test proj(() -> R.objects.values("v" => QB.Floor(QB.Value(5)))) == ("FLOOR((? + 0))", Any[5])
  @test proj(() -> R.objects.values("v" => QB.Abs(QB.Coalesce(QB.Value(-5), QB.Value(1))))) == ("ABS((COALESCE(?, ?) + 0))", Any[-5, 1])
  @test proj(() -> R.objects.values("v" => QB.Ceil(QB.Greatest(QB.Value(5), QB.Value(6))))) ==
        ("CEIL((GREATEST(COALESCE(?, ?), COALESCE(?, ?)) + 0))", Any[5, 6, 6, 5])
  @test proj(() -> R.objects.values("v" => QB.Abs(QB.Value(-2.5)))) == ("ABS(?)", Any[-2.5])
  @test proj(() -> R.objects.values("v" => QB.Abs(QB.Case(QB.When("grid__@gt" => 5, then = QB.Value(5)), default = QB.Value(1))))) ==
        ("ABS((CASE WHEN `Tb`.`grid` > ? THEN ? ELSE ? END + 0))", Any[5, 5, 1])
  @test proj(() -> R.objects.values("v" => QB.Abs(QB.Coalesce("position", 0)))) == ("ABS((COALESCE(`Tb`.`position`, ?) + 0))", Any[0])
  # `Mod` means a float (Django's `NumericOutputFieldMixin`), and MySQL's `MOD(<int>, <double>)` is a
  # DOUBLE: never typed an integer, so a quotient keeps its fraction and a `Round` over it is cast.
  @test proj(() -> R.objects.values("v" => QB.Mod("grid", 3) / 2)) == ("(MOD(`Tb`.`grid`, ?) / ?)", Any[3, 2])
  @test proj(() -> R.objects.values("v" => QB.Round(QB.Mod("grid", "points"), 1))) ==
        ("ROUND(CAST(MOD(`Tb`.`grid`, `Tb`.`points`) AS DECIMAL(65,30)), ?)", Any[1])
  @test PormG._supports(MrMockMySQL(), :negative_round_precision)
  e = try; _mr_inspect(_MR_SL.Result.objects.values("v" => QB.Round("grid", -1))); nothing; catch err; err; end
  @test e isa PormG.BackendCapabilityError
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL Round rounds a DECIMAL, half away from zero (#1130 phase 2c-2)
# MySQL's `ROUND` rounds a DOUBLE half to even (measured: `ROUND(2.5E0)` is 2, `ROUND(1.25E0, 1)` is 1.2)
# and a DECIMAL half away from zero (2.5 → 3), which is what `Round` means. Expected: over a float, a
# float literal or an operand the walk names as a float (`Sqrt`), `ROUND(CAST(x AS DECIMAL(65,30)), ?)`;
# over a known decimal (a cast, a `Sum` of one, a `Decimal` literal) and an integer, MySQL's `ROUND` as
# it is; PostgreSQL's and SQLite's renders unchanged.
# Why: a plain `ROUND` over a float would answer 2 where PostgreSQL and SQLite answer 3.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL Round rounds a DECIMAL, half away from zero" begin
  QB = PormG.QueryBuilder
  R = _MR_MY.Result
  dec() = QB.Cast("grid", "numeric(10,2)")
  proj(build) = (r = _mr_inspect(build()); (strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `v`")[1], r"\s+" => " ")),
                                             r[:parameters]))
  @test proj(() -> R.objects.values("v" => QB.Round("points", 1))) == ("ROUND(CAST(`Tb`.`points` AS DECIMAL(65,30)), ?)", Any[1])
  @test proj(() -> R.objects.values("v" => QB.Round("points"))) == ("ROUND(CAST(`Tb`.`points` AS DECIMAL(65,30)), ?)", Any[0])
  @test proj(() -> R.objects.values("v" => QB.Round(QB.Value(2.5)))) == ("ROUND(CAST(? AS DECIMAL(65,30)), ?)", Any[2.5, 0])
  @test proj(() -> R.objects.values("v" => QB.Round("points", -1))) == ("ROUND(CAST(`Tb`.`points` AS DECIMAL(65,30)), ?)", Any[-1])
  @test proj(() -> R.objects.values("v" => QB.Round(QB.Sqrt(dec()), 2))) ==
        ("ROUND(CAST(SQRT(CAST(`Tb`.`grid` AS DECIMAL(65,2))) AS DECIMAL(65,30)), ?)", Any[2])
  @test proj(() -> R.objects.values("v" => QB.Round(dec(), 1))) == ("ROUND(CAST(`Tb`.`grid` AS DECIMAL(65,2)), ?)", Any[1])
  @test proj(() -> R.objects.values("v" => QB.Round(QB.Sum(dec()), 1))) == ("ROUND(SUM(CAST(`Tb`.`grid` AS DECIMAL(65,2))), ?)", Any[1])
  @test proj(() -> R.objects.values("v" => QB.Round(QB.Value(parse(Decimal, "2.5"))))) ==
        ("ROUND(CAST(? AS DECIMAL(2,1)), ?)", Any[parse(Decimal, "2.5"), 0])
  @test occursin("ROUND((\"Tb\".\"points\")::numeric, \$1::integer)",
                 _mr_inspect(_MR_PG.Result.objects.values("v" => QB.Round("points", 1)))[:sql_text])
  @test occursin("ROUND(\"Tb\".\"points\", ?)", _mr_inspect(_MR_SL.Result.objects.values("v" => QB.Round("points", 1)))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL math: the type MySQL computes, and the one each read means (#1130 phase 2c-2)
# Measured on 8.4: `SQRT`/`EXP`/`LN`/`POWER` are a DOUBLE over any operand; `FLOOR`/`CEIL` a BIGINT over
# an integer and over a decimal; `ABS` keeps an `INT`; `ROUND` of a DECIMAL (cast or not) is a DECIMAL;
# `MOD` keeps both operands' type, which the first alone cannot name, so it is the float it means.
# Expected: `_computed_kind` names each, and a width-less decimal
# (a computed number that means a decimal, #1121) reads through the 15-significant-digit parser, so a
# DOUBLE `Sqrt` over a decimal and a BIGINT `Floor` over one both read as a `Decimal`; a declared width
# gets no parser, since MySQL applies it.
# Why: without the parser `Sqrt(<decimal>)` read back as a `Float64` and `Floor(<decimal>)` as an `Int64`
# on MySQL only, where PostgreSQL and SQLite read a `Decimal`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL math: computed kinds and the width-less decimal read" begin
  QB = PormG.QueryBuilder
  my = MrMockMySQL()
  ck(fn, rule, k) = QB._computed_kind(Val(fn), rule, k, my)
  wl = PormG.CDecimal(nothing, nothing)
  @test ck(:SQRT, :numeric, PormG.CDecimal(10, 2)) == PormG.CFloat64()
  @test ck(:POWER, :numeric, PormG.CInt32()) == PormG.CFloat64()
  @test ck(:FLOOR, :promoting, PormG.CInt32()) == PormG.CInt64()
  @test ck(:FLOOR, :promoting, PormG.CDecimal(10, 2)) == wl
  @test ck(:CEIL, :promoting, PormG.CFloat64()) == PormG.CFloat64()
  @test ck(:ABS, :promoting, PormG.CInt32()) == PormG.CInt32()
  for k in (PormG.CInt32(), PormG.CDecimal(10, 2), PormG.CFloat64())   # `MOD(<int>, <double>)` is a DOUBLE
    @test (k, ck(:MOD, :numeric, k)) == (k, PormG.CFloat64())
  end
  @test ck(:ROUND, :numeric, PormG.CInt64()) == PormG.CInt64()
  @test ck(:ROUND, :numeric, PormG.CFloat64()) == wl
  parse_dec = PormG.value_parser(wl, my)
  @test parse_dec(1.5968719422671311) == parse(Decimal, "1.59687194226713")
  @test parse_dec(6.5024999999999995) == parse(Decimal, "6.5025")
  @test parse_dec(-3) == Decimal(1, 3, 0)
  d = parse(Decimal, "2.55")
  @test parse_dec(d) === d && parse_dec(missing) === missing
  # A declared width is applied, not turned into 15 digits: a value that fits is the value itself.
  @test PormG.value_parser(PormG.CDecimal(10, 2), my)(d) === d
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL date parts: each part with MySQL's own functions (#1130 phase 2c-3a)
# Measured on 8.4, each matching Julia's `Dates` on every day 1999-12-20 … 2031-01-10: `WEEK(x, 3)` is
# the ISO week, `YEARWEEK(x, 3) DIV 100` its year, `WEEKDAY(x) + 1` the ISO day, `DAYOFWEEK(x) - 1`
# PostgreSQL's DOW and `DAYOFWEEK(x)` Django's `@week_day`. Expected: those spellings; EPOCH as
# `TIMESTAMPDIFF` from 1970 over a date or a timestamp (`UNIX_TIMESTAMP` answers 0 before 1970) and the
# count over 10^6 over a duration; MICROSECONDS/MILLISECONDS from `SECOND_MICROSECOND`; every part
# rendering its operand once; CENTURY and EPOCH over a time refused with `BackendCapabilityError`.
# Why: before phase 2c-3a every date part was a `MethodError` on MySQL; MySQL's default `WEEK(x)` mode
# is no ISO week, and `UNIX_TIMESTAMP` would read every date of birth before 1970 as 0.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL date parts: each part with MySQL's own functions" begin
  QB = PormG.QueryBuilder
  RA = _MR_MY.Race
  proj(build, alias = "v") = (r = _mr_inspect(build());
    strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `$(alias)`")[1], r"\s+" => " ")))
  ex(part) = proj(() -> RA.objects.values("v" => QB.Extract("date", part)))
  @test ex("year") == "EXTRACT(YEAR FROM `Tb`.`date`)"
  @test ex("week") == "WEEK(`Tb`.`date`, 3)"
  @test ex("isoyear") == "(YEARWEEK(`Tb`.`date`, 3) DIV 100)"
  @test ex("isodow") == "(WEEKDAY(`Tb`.`date`) + 1)"
  @test ex("dow") == "(DAYOFWEEK(`Tb`.`date`) - 1)"
  @test ex("doy") == "DAYOFYEAR(`Tb`.`date`)"
  @test ex("quarter") == "QUARTER(`Tb`.`date`)"
  @test ex("epoch") == "(TIMESTAMPDIFF(MICROSECOND, '1970-01-01 00:00:00', `Tb`.`date`) / 1000000)"
  ts() = QB.Cast("date", "timestamp")
  @test proj(() -> RA.objects.values("v" => QB.Extract(ts(), "second"))) == "EXTRACT(SECOND FROM CAST(`Tb`.`date` AS DATETIME(3)))"
  @test proj(() -> RA.objects.values("v" => QB.Extract(ts(), "microseconds"))) ==
        "CAST(EXTRACT(SECOND_MICROSECOND FROM CAST(`Tb`.`date` AS DATETIME(3))) AS DECIMAL(65,0))"
  @test proj(() -> RA.objects.values("v" => QB.Extract(ts(), "milliseconds"))) ==
        "(EXTRACT(SECOND_MICROSECOND FROM CAST(`Tb`.`date` AS DATETIME(3))) / 1000)"
  @test proj(() -> _MR_MY.Result.objects.values("v" => QB.Extract("fastestlaptime", "epoch"))) == "(`Tb`.`fastestlaptime` / 1000000)"
  # The operand's kind comes from the type walk, so an expression is spelled by its type too: a
  # duration expression is its microseconds, and a `Coalesce` of timestamps a timestamp.
  @test proj(() -> _MR_MY.Result.objects.values("v" => QB.Extract(F("fastestlaptime") * 2, "epoch"))) ==
        "(CAST(ROUND((`Tb`.`fastestlaptime`) * (?)) AS SIGNED) / 1000000)"
  @test proj(() -> RA.objects.values("v" => QB.Extract(QB.Coalesce(ts(), ts()), "epoch"))) ==
        "(TIMESTAMPDIFF(MICROSECOND, '1970-01-01 00:00:00', COALESCE(CAST(`Tb`.`date` AS DATETIME(3)), CAST(`Tb`.`date` AS DATETIME(3)))) / 1000000)"
  # The transforms: `@week_day` is Django's 1 = Sunday, which MySQL's `DAYOFWEEK` already is.
  @test proj(() -> RA.objects.values("v" => "date__@week_day")) == "DAYOFWEEK(`Tb`.`date`)"
  @test proj(() -> RA.objects.values("v" => "date__@quadrimester")) == "(((MONTH(`Tb`.`date`) - 1) DIV 4) + 1)"
  @test proj(() -> RA.objects.values("v" => "date__@date")) == "CAST(`Tb`.`date` AS DATE)"
  @test proj(() -> RA.objects.values("v" => "date__@month")) == "EXTRACT(MONTH FROM `Tb`.`date`)"
  # What MySQL has no spelling of: a zone (a UTC DATETIME stores none), the invented arithmetic, and
  # EPOCH over a time, which `TIMESTAMPDIFF` reads as another value once bound.
  capability(build) = (e = try; _mr_inspect(build()); nothing; catch err; err; end;
                       e isa PormG.BackendCapabilityError ? sprint(showerror, e) : e)
  @test occursin("Unsupported extract part for MySQL: century", capability(() -> RA.objects.values("v" => QB.Extract("date", "century"))))
  @test occursin("Unsupported extract part for MySQL: julian", capability(() -> RA.objects.values("v" => QB.Extract("date", "julian"))))
  @test occursin("epoch of a time", capability(() -> RA.objects.values("v" => QB.Extract(QB.Cast("date", "time"), "epoch"))))
  @test !occursin("Cast(x", capability(() -> RA.objects.values("v" => QB.Extract(QB.Cast("date", "time"), "epoch"))))
  # A date part of a time expression reads TODAY's date on MySQL (measured: `EXTRACT(YEAR FROM TIME
  # '10:00')` is this year): refused there, where PostgreSQL refuses a time's date part too. Its time
  # parts are the time's own.
  date_of_time(build) = (e = try; _mr_inspect(build()); nothing; catch err; err; end;
                         e isa PormG.QueryBuildError && occursin("over a time is not supported on MySQL", sprint(showerror, e)))
  tm() = QB.Cast("date", "time")
  for part in ("year", "dow", "week", "quarter", "doy")
    @test (part, date_of_time(() -> RA.objects.values("v" => QB.Extract(tm(), part)))) == (part, true)
  end
  # The transforms that read a date: each refused over a time expression.
  for (name, node) in ("@week_day" => QB.WEEK_DAY, "@quarter" => QB.QUARTER, "@quadrimester" => QB.QUADRIMESTER,
                       "@date" => QB.DATE)
    @test (name, date_of_time(() -> RA.objects.values("v" => node(tm())))) == (name, true)
  end
  @test date_of_time(() -> RA.objects.values("v" => QB.ToChar(tm(), "YYYY-MM-DD")))
  # A key with a date component — a year, a month, a day — is refused; a minute (`MI`, `%i`) is not.
  for key in ("DD/MM/YYYY", "MM", "DD", "YYYY")
    @test (key, date_of_time(() -> RA.objects.values("v" => QB.ToChar(tm(), key)))) == (key, true)
  end
  @test proj(() -> RA.objects.values("v" => QB.ToChar(tm(), "MI"))) == "DATE_FORMAT(CAST(`Tb`.`date` AS TIME(6)), '%i')"
  @test proj(() -> RA.objects.values("v" => QB.ToChar(tm(), "HH:MI"))) == "DATE_FORMAT(CAST(`Tb`.`date` AS TIME(6)), '%H:%i')"
  @test proj(() -> RA.objects.values("v" => QB.Extract(tm(), "hour"))) == "EXTRACT(HOUR FROM CAST(`Tb`.`date` AS TIME(6)))"
  # A part is an integer, so a quotient over one divides as integers (`DIV`, phase 2b), where an
  # untyped side would be refused.
  @test proj(() -> RA.objects.values("v" => F("date__@quarter") / 2)) == "(QUARTER(`Tb`.`date`) DIV ?)"
  @test proj(() -> RA.objects.values("v" => F("date__@year") / 2)) == "(EXTRACT(YEAR FROM `Tb`.`date`) DIV ?)"
  # PostgreSQL and SQLite render their own, unchanged.
  @test occursin("EXTRACT(EPOCH FROM \"Tb\".\"date\")", _mr_inspect(_MR_PG.Race.objects.values("v" => QB.Extract("date", "epoch")))[:sql_text])
  @test occursin("Unsupported extract part for SQLite: epoch", capability(() -> _MR_SL.Race.objects.values("v" => QB.Extract("date", "epoch"))))
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL ToChar: each format key through DATE_FORMAT (#1130 phase 2c-3a)
# `date_format_map` names one spelling per engine, and every key renders the same text everywhere.
# Expected: `DATE_FORMAT(x, '<mysql spelling>')`; a `.SSS` key cut to its own length from `%f`'s six
# digits, rendering the operand once; an unknown format refused with `BackendCapabilityError` naming
# MySQL, as on SQLite; a duration refused with `QueryBuildError`, naming `Cast(x, "text")`.
# Why: MySQL's `DATE_FORMAT` has no three-digit fraction, and a duration is a count of microseconds
# there, which `DATE_FORMAT` reads as no date.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL ToChar: each format key through DATE_FORMAT" begin
  QB = PormG.QueryBuilder
  RA = _MR_MY.Race
  proj(build) = (r = _mr_inspect(build());
    strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `v`")[1], r"\s+" => " ")))
  tc(fmt) = proj(() -> RA.objects.values("v" => QB.ToChar("date", fmt)))
  @test tc("YYYY-MM") == "DATE_FORMAT(`Tb`.`date`, '%Y-%m')"
  @test tc("YYYY-MM-DD HH:MI:SS") == "DATE_FORMAT(`Tb`.`date`, '%Y-%m-%d %H:%i:%s')"
  @test tc("YYYY-MM-DDTHH:MI:SS.SSS") == "LEFT(DATE_FORMAT(`Tb`.`date`, '%Y-%m-%dT%H:%i:%s.%f'), 23)"
  @test tc("HH:MI:SS.SSS") == "LEFT(DATE_FORMAT(`Tb`.`date`, '%H:%i:%s.%f'), 12)"
  # Every key renders its own spelling, and a `.SSS` key is cut to its own length: the text a key
  # stands for is exactly as long as the key (`Dates.format` of a fixed instant, the oracle).
  stamp = DateTime(2009, 3, 29, 6, 5, 4, 125)
  jmask(k) = replace(k, "YYYY" => "yyyy", "MM" => "mm", "DD" => "dd", "MI" => "MM", ".SSS" => ".sss")
  for (key, entry) in PormG.date_format_map
    sql = tc(key)
    want = Base.endswith(key, ".SSS") ? "LEFT(DATE_FORMAT(`Tb`.`date`, '$(entry.mysql)'), $(length(key)))" :
                                        "DATE_FORMAT(`Tb`.`date`, '$(entry.mysql)')"
    @test (key, sql) == (key, want)
    @test (key, length(Dates.format(stamp, jmask(key)))) == (key, length(key))
  end
  e = try; _mr_inspect(RA.objects.values("v" => QB.ToChar("date", "Day"))); nothing; catch err; err; end
  @test e isa PormG.BackendCapabilityError && occursin("ToChar: format \"Day\" is not supported on MySQL", sprint(showerror, e))
  e = try; _mr_inspect(_MR_MY.Result.objects.values("v" => QB.ToChar("fastestlaptime", "HH:MI:SS"))); nothing; catch err; err; end
  @test e isa PormG.QueryBuildError && occursin("ToChar over an interval is not supported on MySQL", sprint(showerror, e))
  # SQLite and PostgreSQL keep theirs.
  @test occursin("strftime('%Y-%m', \"Tb\".\"date\")", _mr_inspect(_MR_SL.Race.objects.values("v" => QB.ToChar("date", "YYYY-MM")))[:sql_text])
  @test occursin("to_char(\"Tb\".\"date\", 'YYYY-MM')", _mr_inspect(_MR_PG.Race.objects.values("v" => QB.ToChar("date", "YYYY-MM")))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL text functions (#1130 phase 2c-3b)
# Measured on 8.4: `LENGTH` counts bytes (`Räikkönen` is 11) and `CHAR_LENGTH` characters (9);
# `LOWER`/`UPPER`/`TRIM`/`REPLACE` and `LPAD`/`RPAD` (cut, repeated fill) answer as PostgreSQL's,
# except that an empty fill pads to `''` where PostgreSQL returns the string cut to the length.
# Expected: `CHAR_LENGTH(x)` for `Length`; the shared spellings for the others; an empty literal fill
# rendered `CONCAT(LEFT(x, ?), ?)`, the cut with the fill's marker kept in place, so the values bind
# in text order; a non-empty fill `LPAD(x, ?, ?)`.
# Why: before phase 2c-3b each was a `MethodError` on MySQL, and `LENGTH` there would count bytes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL text functions: MySQL's own, Length in characters" begin
  QB = PormG.QueryBuilder
  D = _MR_MY.Driver
  proj(build) = (r = _mr_inspect(build()); (strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `v`")[1], r"\s+" => " ")),
                                             r[:parameters]))
  @test proj(() -> D.objects.values("v" => QB.Length("surname"))) == ("CHAR_LENGTH(`Tb`.`surname`)", Any[])
  @test proj(() -> D.objects.values("v" => QB.Upper("surname"))) == ("UPPER(`Tb`.`surname`)", Any[])
  @test proj(() -> D.objects.values("v" => QB.Lower("surname"))) == ("LOWER(`Tb`.`surname`)", Any[])
  @test proj(() -> D.objects.values("v" => QB.Trim("surname"))) == ("TRIM(`Tb`.`surname`)", Any[])
  @test proj(() -> D.objects.values("v" => QB.RTrim("surname"))) == ("RTRIM(`Tb`.`surname`)", Any[])
  @test proj(() -> D.objects.values("v" => QB.Replace("surname", "enn", "X"))) == ("REPLACE(`Tb`.`surname`, ?, ?)", Any["enn", "X"])
  @test proj(() -> D.objects.values("v" => QB.LPad("surname", 10, "*"))) == ("LPAD(`Tb`.`surname`, ?, ?)", Any[10, "*"])
  @test proj(() -> D.objects.values("v" => QB.RPad("surname", 10, "ab"))) == ("RPAD(`Tb`.`surname`, ?, ?)", Any[10, "ab"])
  # An empty fill pads nothing: the cut alone, its marker still bound where it prints.
  @test proj(() -> D.objects.values("v" => QB.LPad("surname", 3, ""))) == ("CONCAT(LEFT(`Tb`.`surname`, ?), ?)", Any[3, ""])
  @test proj(() -> D.objects.values("v" => QB.RPad("surname", 3, ""))) == ("CONCAT(LEFT(`Tb`.`surname`, ?), ?)", Any[3, ""])
  # PostgreSQL and SQLite keep theirs, an empty fill included.
  @test occursin("LENGTH(\"Tb\".\"surname\")", _mr_inspect(_MR_PG.Driver.objects.values("v" => QB.Length("surname")))[:sql_text])
  @test occursin("pormg_lpad(\"Tb\".\"surname\", ?, ?)", _mr_inspect(_MR_SL.Driver.objects.values("v" => QB.LPad("surname", 3, "")))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL window functions and frames (#1130 phase 2c-3b)
# Measured on 8.4: `ROW_NUMBER`/`RANK`/`DENSE_RANK` are a `BIGINT UNSIGNED` (a `UInt64` through
# MySQL.jl); `LAG`/`LEAD` take a bound offset and default; ROWS and RANGE frames work, GROUPS and
# EXCLUDE raise error 1235. Expected: the ranking functions `CAST(… AS SIGNED)`, an `Int64` as on the
# other engines; the others bare, binding offset then default in text order; ROWS/RANGE frames as
# written; GROUPS and EXCLUDE refused with `BackendCapabilityError` through their capability rows,
# which PostgreSQL has.
# Why: before phase 2c-3b each was a `MethodError` on MySQL, and a GROUPS frame would have reached
# the server as a syntax error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL window functions: signed ranks, ROWS/RANGE frames, GROUPS/EXCLUDE refused" begin
  QB = PormG.QueryBuilder
  R = _MR_MY.Result
  by(; kw...) = QB.WindowOver(; order_by = ["resultid"], kw...)
  proj(build) = (r = _mr_inspect(build()); (strip(replace(split(split(r[:sql_text], "SELECT"; limit = 2)[2], " as `v`")[1], r"\s+" => " ")),
                                             r[:parameters]))
  @test proj(() -> R.objects.values("v" => QB.RowNumber(over = by()))) ==
        ("CAST(ROW_NUMBER() OVER (ORDER BY `Tb`.`resultid` ASC) AS SIGNED)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Rank(over = QB.WindowOver(order_by = ["-points"])))) ==
        ("CAST(RANK() OVER (ORDER BY `Tb`.`points` DESC) AS SIGNED)", Any[])
  @test proj(() -> R.objects.values("v" => QB.DenseRank(over = by()))) ==
        ("CAST(DENSE_RANK() OVER (ORDER BY `Tb`.`resultid` ASC) AS SIGNED)", Any[])
  @test proj(() -> R.objects.values("v" => QB.Lag("grid"; offset = 2, default = -1, over = by()))) ==
        ("LAG(`Tb`.`grid`, ?, ?) OVER (ORDER BY `Tb`.`resultid` ASC)", Any[2, -1])
  @test proj(() -> R.objects.values("v" => QB.Lead("grid"; over = by()))) == ("LEAD(`Tb`.`grid`, ?) OVER (ORDER BY `Tb`.`resultid` ASC)", Any[1])
  @test proj(() -> R.objects.values("v" => QB.FirstValue("grid"; over = by()))) == ("FIRST_VALUE(`Tb`.`grid`) OVER (ORDER BY `Tb`.`resultid` ASC)", Any[])
  @test proj(() -> R.objects.values("v" => QB.NthValue("grid", 2; over = by()))) == ("NTH_VALUE(`Tb`.`grid`, 2) OVER (ORDER BY `Tb`.`resultid` ASC)", Any[])
  @test proj(() -> R.objects.values("v" => QB.LastValue("grid"; over = by(frame = "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW")))) ==
        ("LAST_VALUE(`Tb`.`grid`) OVER (ORDER BY `Tb`.`resultid` ASC ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)", Any[])
  @test proj(() -> R.objects.values("v" => QB.LastValue("grid"; over = by(frame = "RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW")))) ==
        ("LAST_VALUE(`Tb`.`grid`) OVER (ORDER BY `Tb`.`resultid` ASC RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)", Any[])
  # An interval offset in MySQL's grammar: unquoted, singular, and milliseconds counted in microseconds
  # (MySQL has no MILLISECOND unit); PostgreSQL keeps its quoted interval.
  rng(frame) = proj(() -> R.objects.values("v" => QB.LastValue("grid"; over = by(frame = frame))))[1]
  @test occursin("RANGE BETWEEN INTERVAL 7 DAY PRECEDING AND CURRENT ROW)", rng("RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW"))
  @test occursin("RANGE BETWEEN INTERVAL 1 WEEK PRECEDING AND INTERVAL 5000 MICROSECOND FOLLOWING)",
                 rng("RANGE BETWEEN INTERVAL '1 week' PRECEDING AND INTERVAL '5 milliseconds' FOLLOWING"))
  # The count never wraps: past the 64-bit range it stays the number written, for the server to refuse.
  @test occursin("INTERVAL 9300000000000000000 MICROSECOND PRECEDING",
                 rng("RANGE BETWEEN INTERVAL '9300000000000000 milliseconds' PRECEDING AND CURRENT ROW"))
  @test occursin("RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW",
                 _mr_inspect(_MR_PG.Result.objects.values("v" => QB.LastValue("grid"; over = by(frame = "RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW"))))[:sql_text])
  @test PormG._supports(MrMockMySQL(), :window_functions)
  refused(frame) = (e = try; _mr_inspect(R.objects.values("v" => QB.LastValue("grid"; over = by(frame = frame)))); nothing; catch err; err; end;
                    e isa PormG.BackendCapabilityError ? sprint(showerror, e) : e)
  @test occursin("a `GROUPS` window frame, which MySQL does not support (supported on PostgreSQL)",
                 refused("GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW"))
  @test occursin("an `EXCLUDE` clause in a window frame, which MySQL does not support (supported on PostgreSQL)",
                 refused("ROWS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW"))
  # PostgreSQL renders both; SQLite still refuses every explicit frame, first.
  @test occursin("GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES",
                 _mr_inspect(_MR_PG.Result.objects.values("v" => QB.LastValue("grid"; over = by(frame = "GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES"))))[:sql_text])
  e = try; _mr_inspect(_MR_SL.Result.objects.values("v" => QB.LastValue("grid"; over = by(frame = "GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW")))); nothing; catch err; err; end
  @test e isa PormG.BackendCapabilityError && occursin("PormG does not render explicit window frames on SQLite yet", sprint(showerror, e))
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL extension: which statements are prepared to read their columns' character sets (#1130 phase 2c-3b)
# A statement that returns rows is prepared, so its text and bytes decode by charset; any other keeps
# the text protocol. Expected: SELECT/WITH/SHOW/`(` match after any whitespace and leading comments;
# a statement that returns no rows never matches, however much whitespace or how many comments open
# it, and a comment never stretches past its own `*/`.
# Why: a backtracking skip loop threw "match limit exceeded" on a non-row statement after ~24
# spaces, and matched `/* c */ INSERT … /* cols */ (…)` by reading the comment to the second `*/`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL extension: row-returning statements, whatever opens them" begin
  ext = Base.get_extension(PormG, :PormGMySQLExt)
  @test ext !== nothing
  R = ext._RETURNS_ROWS
  for sql in ("SELECT 1", "  select 1", "(SELECT 1) UNION (SELECT 2)", "WITH x AS (SELECT 1) SELECT * FROM x",
              "SHOW WARNINGS", "/* a note */ -- and a line\nSELECT 1", "--\tx\r\nSELECT 1", "#c\nSELECT 1",
              " "^5000 * "SELECT 1")
    @test (first(sql, 40), occursin(R, sql)) == (first(sql, 40), true)
  end
  for sql in (" "^30 * "INSERT INTO t VALUES (1)", "\n" * "    "^6 * "UPDATE t SET a = 1", "\n"^25 * "START TRANSACTION",
              "/* c */ INSERT INTO t /* cols */ (a, b) VALUES (1, 2)", "/* c */ DELETE FROM t -- x */ SELECT",
              "/* c */ INSERT INTO t VALUES ('*/ SELECT')", "/* SELECT */ INSERT INTO t VALUES (1)",
              "-- x\nINSERT INTO t VALUES (1)", "/* unterminated SELECT", "INSERT INTO t SELECT 1",
              repeat("/* c */ ", 2000) * "INSERT INTO t VALUES (1)")
    @test (first(sql, 40), occursin(R, sql)) == (first(sql, 40), false)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL single-row writes: the INSERT, its read-back key, UPDATE and the joined forms (#1130 phase 3a)
# MySQL has no RETURNING, so `create` runs the INSERT and reads the row back on the same connection.
# Expected: the INSERT text; the read-back keyed on the id the INSERT's OK packet reports for an
# AUTO_INCREMENT pk (never `LAST_INSERT_ID()`, which keeps an older id after a supplied one), and on the
# bound value for any other pk; `nothing` with no key. A simple UPDATE as on every engine; a joined
# filter's selection read through a derived table (MySQL error 1093 otherwise); a SET that reads a joined
# table in MySQL's multi-table form with the SET qualified. PostgreSQL and SQLite render as before.
# ─────────────────────────────────────────────────────────────────────────────
struct MrInsertResult; id::Int; end
PormG.backend_last_insert_id(::MrMockMySQL, r::MrInsertResult) = r.id

@testset "MySQL single-row writes: INSERT, the read-back key, UPDATE and its joined forms" begin
  my = MrMockMySQL()
  ins = _MR_MY.Driver.objects.create("forename" => "Ayrton", "surname" => "Senna", "nationality" => "Brazilian",
                                     "dob" => Date(1960, 3, 21); show_query = :dict)
  # The column order follows the row's fields; the shape does not.
  @test startswith(ins[:sql_text], "INSERT INTO `driver` (\n  ") && endswith(ins[:sql_text], ") VALUES (\n  ?, ?, ?, ?\n)\n")
  @test !occursin("RETURNING", ins[:sql_text]) && ins[:parameter_count] == 4
  # The read-back: an AUTO_INCREMENT pk by the OK packet's id, a generated or supplied one alike.
  rb = _MR_QB._inserted_row_query(my, _MR_MY.Driver, Dict{String,Any}(), MrInsertResult(42), "`driver`")
  @test rb[1] == "SELECT * FROM `driver` WHERE `driverid` = ?" && rb[2].select_params == Any[] && rb[2].where_params == Any[42]
  # The stored id first: the packet's id is what the row holds.
  rb = _MR_QB._inserted_row_query(my, _MR_MY.Driver, Dict{String,Any}("driverid" => 7), MrInsertResult(501), "`driver`")
  @test rb[2].where_params == Any[501]
  # A supplied 0 is stored as 0 (the session's NO_AUTO_VALUE_ON_ZERO), the packet reports 0, and the key
  # is read back by the value bound.
  rb = _MR_QB._inserted_row_query(my, _MR_MY.Driver, Dict{String,Any}("driverid" => 0), MrInsertResult(0), "`driver`")
  @test rb[2].where_params == Any[0]
  # A table without AUTO_INCREMENT reports 0: the supplied key is read back by the value bound.
  rb = _MR_QB._inserted_row_query(my, _MR_MY.Driver, Dict{String,Any}("driverid" => 500), MrInsertResult(0), "`driver`")
  @test rb[2].where_params == Any[500]
  @test _MR_QB._inserted_row_query(my, _MR_MY.Driver, Dict{String,Any}(), MrInsertResult(0), "`driver`") === nothing
  # SQLite keeps its rowid read-back; PostgreSQL's RETURNING carries the row.
  @test _MR_QB._inserted_row_query(MrMockSQLite(), _MR_SL.Driver, Dict{String,Any}(), nothing, "\"driver\"") ==
        ("SELECT * FROM \"driver\" WHERE rowid = last_insert_rowid();", nothing)
  @test _MR_QB._inserted_row_query(MrMockPostgres(), _MR_PG.Driver, Dict{String,Any}(), nothing, "\"driver\"") === nothing
  @test occursin("RETURNING *", _MR_PG.Driver.objects.create("forename" => "A", "surname" => "B", "nationality" => "C",
                                                              "dob" => Date(1960, 1, 1); show_query = :sql))

  upd = _MR_MY.Result.objects.filter("grid" => 1).update("laps" => 5; show_query = :dict)
  @test upd[:sql_text] == "UPDATE `result` AS `Tb`\nSET `laps` = ?\nWHERE `Tb`.`grid` = ?\n" && upd[:parameters] == Any[5, 1]
  # A joined filter: the selection through a derived table, then the fence; markers in text order.
  upd = _MR_MY.Result.objects.filter("driverid__nationality" => "British").update("laps" => 5; show_query = :dict)
  @test occursin("WHERE `Tb`.`resultid` IN (SELECT * FROM (SELECT DISTINCT `Tb`.`resultid`\n  FROM `result` as `Tb`", upd[:sql_text])
  @test occursin(") AS `__pormg_keys`)\n  AND EXISTS (SELECT 1 FROM (SELECT 1) AS `__pormg_anchor`", upd[:sql_text])
  assert_marker_count(upd, :sqlite)
  @test upd[:parameters] == Any[5, "British", "British"]
  # PostgreSQL and SQLite read the subquery as written.
  for models in (_MR_PG, _MR_SL)
    sql = models.Result.objects.filter("driverid__nationality" => "British").update("laps" => 5; show_query = :sql)
    @test occursin("IN (SELECT DISTINCT \"Tb\".\"resultid\"", sql) && !occursin("__pormg_keys", sql)
  end
  # A SET that reads a joined table: MySQL's multi-table UPDATE, the SET qualified.
  upd = _MR_MY.Result.objects.filter("grid" => 3).update("laps" => F("raceid__year"); show_query = :dict)
  @test upd[:sql_text] == "UPDATE `result` AS `Tb`, `race` AS `Tb_1`\nSET `Tb`.`laps` = `Tb_1`.`year`\n" *
                          "WHERE `Tb`.`raceid` = `Tb_1`.`raceid` AND `Tb`.`grid` = ?\n"
  @test occursin("FROM \"race\" AS \"Tb_1\"",
                 _MR_PG.Result.objects.filter("grid" => 3).update("laps" => F("raceid__year"); show_query = :sql))
  # A membership subquery in a mutation is read through a derived table (1093 otherwise), unless it
  # reads the outer row; a read is unchanged, and so are PostgreSQL and SQLite.
  members = _MR_MY.Result.objects.filter("grid" => 1).values("resultid")
  upd = _MR_MY.Result.objects.filter("resultid__@in" => members).update("laps" => 5; show_query = :sql)
  @test occursin("`Tb`.`resultid` IN (SELECT * FROM (SELECT", upd) && occursin(") AS `__pormg_members`)", upd)
  @test !occursin("__pormg_members", _mr_inspect(_MR_MY.Result.objects.filter("resultid__@in" => members))[:sql_text])
  @test !occursin("__pormg_members", _MR_PG.Result.objects.filter("resultid__@in" => _MR_PG.Result.objects.filter("grid" => 1).
                    values("resultid")).update("laps" => 5; show_query = :sql))
  # … and in a delete: the root's own statement and a cascade step take the same path (`_build_entry`).
  del = _MR_MY.Result.objects.filter("resultid__@in" => members).delete(show_query = :sql)
  @test occursin("IN (SELECT * FROM (SELECT", del) && occursin(") AS `__pormg_members`)", del)
  @test !occursin("__pormg_members", _MR_PG.Result.objects.filter("resultid__@in" =>
                    _MR_PG.Result.objects.filter("grid" => 1).values("resultid")).delete(show_query = :sql))
  correlated = _MR_MY.Driver.objects.filter("driverid" => _MR_QB.OuterRef("driverid")).values("driverid")
  upd = _MR_MY.Result.objects.filter("driverid__@in" => correlated).update("laps" => 5; show_query = :sql)
  @test !occursin("__pormg_members", upd)
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL assigns an UPDATE's SET items in order: a SET that reads a column it also writes is refused
# Every SET item means the row as it was. MySQL's single-table UPDATE reads an item already assigned at
# its new value (measured on 8.4: a swap writes one value into both), and the order of its multi-table
# form is unspecified. Expected: a swap, and an item reading a column written earlier, raise
# QueryBuildError on MySQL naming both fields; an item reading its own column, or a column written
# later in a single-table SET, builds; the multi-table form refuses any other written column; PostgreSQL
# and SQLite build every shape.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL assigns SET items in order: a SET reading a column it writes is refused" begin
  refused(f) = try; f(); nothing; catch e; e; end
  q() = _MR_MY.Result.objects.filter("grid" => 1)
  # The order follows the fields; a swap reads an earlier item either way round.
  e = refused(() -> q().update("laps" => F("grid"), "grid" => F("laps"); show_query = :sql))
  @test e isa PormG.QueryBuildError && occursin("assigns an UPDATE's SET items in order", sprint(showerror, e)) &&
        occursin("MySQL", sprint(showerror, e))
  @test q().update("laps" => F("laps") + 1; show_query = :sql) isa String
  @test q().update("laps" => F("laps") + 1, "grid" => 2; show_query = :sql) isa String
  # An item reading a column written LATER reads the old value in the single-table form: it builds.
  @test q().update("laps" => F("grid"), "grid" => 2; show_query = :sql) isa String
  # Multi-table: any other written column, whichever comes first.
  e = refused(() -> q().update("laps" => F("raceid__year"), "grid" => F("laps"); show_query = :sql))
  @test e isa PormG.QueryBuildError
  e = refused(() -> q().update("laps" => F("grid"), "grid" => F("raceid__year"); show_query = :sql))
  @test e isa PormG.QueryBuildError && occursin("update(\"laps\" => …) reads `grid`", sprint(showerror, e))
  for models in (_MR_PG, _MR_SL)
    @test models.Result.objects.filter("grid" => 1).update("laps" => F("grid"), "grid" => F("laps"); show_query = :sql) isa String
  end
  @test !_MR_QB._assigns_set_in_order(MrMockPostgres()) && _MR_QB._assigns_set_in_order(MrMockMySQL())
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL has no deferred foreign keys: the shapes that need them are refused, naming it (#1272)
# InnoDB checks a foreign key at each statement. Expected: a delete whose rows' foreign keys form a
# cycle raises the QueryBuildError it raises on every engine; `without_foreign_keys` is refused on a
# MySQL pool before any transaction opens, naming `deferred_foreign_keys`; the capability row answers
# per engine; a cascade locks its parents first.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL has no deferred foreign keys: cycles and without_foreign_keys are refused" begin
  # A cycle is refused on every engine, MySQL included: PormG has no order for it anywhere.
  deps = Dict{PormG.PormGModel,Set{PormG.PormGModel}}(_MR_MY.Result => Set([_MR_MY.Result]))
  err = try; _MR_QB.topological_sort(deps); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError && occursin("Circular dependency", sprint(showerror, err))
  # Children first when there is no cycle.
  deps = Dict{PormG.PormGModel,Set{PormG.PormGModel}}(_MR_MY.Result => Set([_MR_MY.Race, _MR_MY.Driver]))
  order = _MR_QB.topological_sort(deps)
  @test first(order) === _MR_MY.Result && Set(order[2:end]) == Set([_MR_MY.Race, _MR_MY.Driver])
  err = try; PormG.ConnectionPool.without_foreign_keys(() -> error("ran"), MrMockMySQL()); nothing; catch e; e; end
  @test err isa PormG.BackendCapabilityError && occursin("without_foreign_keys", sprint(showerror, err))
  @test !PormG.Kernel._supports(MrMockMySQL(), :deferred_foreign_keys)
  # Its writers are not serialized, so a cascade locks its parents first, as on PostgreSQL (#770).
  @test _MR_QB._locks_cascade_parents(MrMockMySQL()) && !_MR_QB._locks_cascade_parents(MrMockSQLite())
  @test PormG.Kernel._supports(MrMockPostgres(), :deferred_foreign_keys) && PormG.Kernel._supports(MrMockSQLite(), :deferred_foreign_keys)
end

# Upsert models on their own keys (#1267): unique keys of every kind a row can conflict on.
for (modname, key, conn) in ((:MrMyUp, "mr_my_up", MrMockMySQL()), (:MrPGUp, "mr_pg_up", MrMockPostgres()),
                             (:MrSLUp, "mr_sl_up", MrMockSQLite()))
  PormG.config[key] = PormG.Configuration.Settings(connections = conn, change_data = true, db_def_folder = key)
  @eval module $modname
  import PormG
  import PormG.Models
  # Two unique keys besides the pk; NOT NULL, so a row always supplies both.
  Circuit = Models.Model("circuit", circuitid = Models.IDField(), circuitref = Models.CharField(unique = true),
                         name = Models.CharField(unique = true), location = Models.CharField(null = true))
  # A nullable unique key: a row that leaves it NULL cannot conflict on it.
  Constructor = Models.Model("constructor", constructorid = Models.IDField(),
                             constructorref = Models.CharField(unique = true),
                             code = Models.CharField(null = true, unique = true),
                             nationality = Models.CharField(null = true))
  # A primary key without AUTO_INCREMENT.
  Status = Models.Model("status", code = Models.CharField(primary_key = true, max_length = 10),
                        label = Models.CharField())
  # A composite UniqueConstraint with a nullable member.
  Standing = Models.Model("standing"; standingid = Models.IDField(), raceid = Models.IntegerField(),
                          driverid = Models.IntegerField(null = true), points = Models.FloatField(),
                          constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"))])
  # A functional UniqueConstraint: SQL text PormG cannot evaluate against a row.
  Season = Models.Model("season"; seasonid = Models.IDField(), year = Models.IntegerField(unique = true),
                        url = Models.CharField(),
                        constraints = [Models.UniqueConstraint(expressions = ("lower(url)",), name = "season_url_ci")])
  # A UUID primary key PormG mints when the row leaves it out.
  Token = Models.Model("token", token = Models.UUIDField(primary_key = true, auto_add = true),
                       label = Models.CharField(unique = true), note = Models.CharField(null = true))
  # A unique field a Julia default fills.
  Grid = Models.Model("grid", gridid = Models.IDField(), ref = Models.CharField(unique = true),
                      slot = Models.IntegerField(unique = true, default = 1), note = Models.CharField(null = true))
  # A unique field under `db_column`, and one the database fills (`db_default`).
  Pit = Models.Model("pit", pitid = Models.IDField(), ref = Models.CharField(unique = true),
                     code = Models.CharField(unique = true, null = true, db_column = "pit_code"),
                     stamp = Models.DateTimeField(unique = true, null = true, db_default = "CURRENT_TIMESTAMP"),
                     note = Models.CharField(null = true))
  # A OneToOneField (unique by default) and a unique ForeignKey, both nullable.
  Seat = Models.Model("seat", seatid = Models.IDField(), ref = Models.CharField(unique = true),
                      circuit = Models.OneToOneField(Circuit, pk_field = "circuitid", null = true),
                      owner = Models.ForeignKey(Circuit, pk_field = "circuitid", unique = true, null = true,
                                                related_name = "owned_seats"),
                      note = Models.CharField(null = true))
  # A partial UniqueConstraint.
  Entry = Models.Model("entry"; entryid = Models.IDField(), ref = Models.CharField(unique = true),
                       alias = Models.CharField(null = true), note = Models.CharField(null = true),
                       constraints = [Models.UniqueConstraint(fields = ("alias",), condition = "alias <> ''",
                                                              name = "entry_alias_uq")])
  # A constraint over the lookup and one more field, and a non-pk UUID PormG mints.
  Badge = Models.Model("badge"; badgeid = Models.IDField(), ref = Models.CharField(unique = true),
                       raceid = Models.IntegerField(null = true),
                       ticket = Models.UUIDField(unique = true, auto_add = true), note = Models.CharField(null = true),
                       constraints = [Models.UniqueConstraint(fields = ("ref", "raceid"))])
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL update_or_create: ON DUPLICATE KEY UPDATE only when the lookup is the one key the row can hit
# MySQL's ON DUPLICATE KEY UPDATE names no target and updates whichever row a unique key matched
# (#1267: measured, a conflict on `code` rewrote another driver). Expected SQL:
# `INSERT … AS `__pormg_new` ON DUPLICATE KEY UPDATE c = `__pormg_new`.c`. A lookup that is not a unique
# key of the model raises QueryBuildError; another key the row can conflict on (supplied and not NULL,
# a supplied primary key, any functional or partial constraint) raises BackendCapabilityError naming
# `upsert_conflict_target` and that key. A NULL member, an omitted auto id or a minted UUID cannot
# conflict, so those rows build. PostgreSQL and SQLite name their target and build every shape.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL update_or_create: ON DUPLICATE KEY UPDATE only when the lookup is the only key it can hit" begin
  caught(f) = try; f(); nothing; catch e; e; end
  uoc(m, lookup...; defaults, q = :sql) = m.objects.update_or_create(lookup...; defaults = defaults, show_query = q)
  d = uoc(MrMyUp.Constructor, "constructorref" => "mclaren"; defaults = ["nationality" => "British"], q = :dict)
  @test occursin(")\nAS `__pormg_new` ON DUPLICATE KEY UPDATE `nationality` = `__pormg_new`.`nationality`", d[:sql_text])
  @test !occursin("ON CONFLICT", d[:sql_text]) && !occursin("RETURNING", d[:sql_text])
  @test d[:parameters] == Any["mclaren", "British"]
  # The nullable unique `code`: left out, it is NULL and cannot conflict; supplied, it can.
  e = caught(() -> uoc(MrMyUp.Constructor, "constructorref" => "mclaren"; defaults = ["code" => "MCL"]))
  @test e isa PormG.BackendCapabilityError
  msg = sprint(showerror, e)
  @test occursin("update_or_create on constructor", msg) && occursin("(code)", msg) && occursin("MySQL", msg) &&
        occursin("names the unique key it updates on", msg)
  # … and written as `nothing`, it is NULL as well.
  @test occursin("ON DUPLICATE KEY UPDATE `code` = `__pormg_new`.`code`", uoc(MrMyUp.Constructor,
          "constructorref" => "mclaren"; defaults = Pair{String,Any}["code" => nothing, "nationality" => "British"]))
  # A supplied auto id is a key the row can conflict on; an omitted one is a new value.
  e = caught(() -> uoc(MrMyUp.Constructor, "constructorref" => "mclaren"; defaults = ["constructorid" => 5]))
  @test e isa PormG.BackendCapabilityError && occursin("(constructorid)", sprint(showerror, e))
  # Two NOT NULL unique keys: whichever is the lookup, the row supplies the other.
  e = caught(() -> uoc(MrMyUp.Circuit, "circuitref" => "monza"; defaults = ["name" => "Monza"]))
  @test e isa PormG.BackendCapabilityError && occursin("(name)", sprint(showerror, e)) &&
        !occursin("(circuitref)", sprint(showerror, e))
  # A composite constraint conflicts only when every member is set.
  @test occursin("ON DUPLICATE KEY UPDATE `raceid` = `__pormg_new`.`raceid`",
                 uoc(MrMyUp.Standing, "standingid" => 7; defaults = Pair{String,Any}["raceid" => 1, "points" => 2.0]))
  e = caught(() -> uoc(MrMyUp.Standing, "standingid" => 7; defaults = Pair{String,Any}["raceid" => 1, "driverid" => 3, "points" => 2.0]))
  @test e isa PormG.BackendCapabilityError && occursin("(raceid, driverid)", sprint(showerror, e))
  @test occursin("ON DUPLICATE KEY UPDATE `points` = `__pormg_new`.`points`",
                 uoc(MrMyUp.Standing, "raceid" => 1, "driverid" => 3; defaults = ["points" => 2.0]))
  @test occursin("ON DUPLICATE KEY UPDATE `points` = `__pormg_new`.`points`",   # a set, not a sequence
                 uoc(MrMyUp.Standing, "driverid" => 3, "raceid" => 1; defaults = ["points" => 2.0]))
  # A functional constraint always counts: PormG cannot evaluate `lower(url)` against the row.
  e = caught(() -> uoc(MrMyUp.Season, "year" => 1988; defaults = ["url" => "u"]))
  @test e isa PormG.BackendCapabilityError && occursin("a functional or partial UniqueConstraint", sprint(showerror, e))
  # A UUID pk PormG mints is a new value; one the caller supplies is a key the row can conflict on.
  @test occursin("ON DUPLICATE KEY UPDATE `note`", uoc(MrMyUp.Token, "label" => "a"; defaults = ["note" => "n"]))
  e = caught(() -> uoc(MrMyUp.Token, "label" => "a"; defaults = ["token" => UUIDs.uuid4(), "note" => "n"]))
  @test e isa PormG.BackendCapabilityError && occursin("(token)", sprint(showerror, e))
  # A primary key without AUTO_INCREMENT is the lookup itself.
  @test occursin("ON DUPLICATE KEY UPDATE `label`", uoc(MrMyUp.Status, "code" => "F"; defaults = ["label" => "Finished"]))
  # A lookup that is not a unique key: the row could not be found by it.
  for (m, lookup, defaults) in ((MrMyUp.Status, ("label" => "x",), ["code" => "F"]),
                                (MrMyUp.Standing, ("raceid" => 1,), ["points" => 2.0]),
                                (MrMyUp.Season, ("url" => "u",), ["year" => 1988]))
    e = caught(() -> uoc(m, lookup...; defaults = defaults))
    @test e isa PormG.QueryBuildError && occursin("to be a unique key of the model", sprint(showerror, e))
  end
  # PostgreSQL and SQLite name the target, so every shape above builds there.
  for models in (MrPGUp, MrSLUp)
    @test occursin("ON CONFLICT (\"circuitref\") DO UPDATE SET \"name\" = EXCLUDED.\"name\"",
                   uoc(models.Circuit, "circuitref" => "monza"; defaults = ["name" => "Monza"]))
    @test uoc(models.Constructor, "constructorref" => "mclaren"; defaults = ["code" => "MCL"]) isa String
    @test uoc(models.Season, "year" => 1988; defaults = ["url" => "u"]) isa String
  end
  @test !PormG.Kernel._supports(MrMockMySQL(), :upsert_conflict_target)
  @test PormG.Kernel._supports(MrMockPostgres(), :upsert_conflict_target) && PormG.Kernel._supports(MrMockSQLite(), :upsert_conflict_target)
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL update_or_create's `created`: read from the statement's own report
# Measured on 8.4 under `found_rows`: an insert counts 1, a duplicate it changed 2, an unchanged one 1;
# the OK packet's id is the inserted row's AUTO_INCREMENT value, the matched row's on a changed
# duplicate, 0 on an unchanged one. Expected: with an AUTO_INCREMENT pk, created only for (1, id ≠ 0);
# without one (the id is always 0), created when the pre-check found no row and the count is not 2.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL update_or_create: created from the count and the OK packet's id" begin
  created = _MR_QB._odku_created
  @test created(true, false, 1, 42)       # an insert
  @test !created(true, false, 2, 42)      # a duplicate it changed (the id is the matched row's)
  @test !created(true, false, 1, 0)       # a duplicate already holding the values
  @test !created(false, true, 1, 0)       # no AUTO_INCREMENT: the pre-check found the row
  @test created(false, false, 1, 0)       # … found none, and nothing was changed twice
  @test !created(false, false, 2, 0)      # … found none, but another session's row was updated
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL get_or_create: a miss is a plain INSERT the lookup's unique index guards
# get_or_create never updates a row, so another key the row can conflict on is MySQL's IntegrityError,
# as on PostgreSQL, not a refusal. Expected SQL on a miss: `INSERT INTO … VALUES (…)` with no ON
# CONFLICT and no ON DUPLICATE KEY. A lookup that is not a unique key of the model raises
# QueryBuildError on the miss path. PostgreSQL and SQLite keep `ON CONFLICT (lookup) DO NOTHING`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL get_or_create: a plain INSERT, the lookup a unique key of the model" begin
  goc(m, lookup...; defaults = Pair[]) = m.objects.get_or_create(lookup...; defaults = defaults, show_query = :sql)
  sql = goc(MrMyUp.Circuit, "circuitref" => "monza"; defaults = ["name" => "Monza"])
  @test endswith(sql, ") VALUES (\n  ?, ?\n)\n") && !occursin("ON CONFLICT", sql) && !occursin("DUPLICATE", sql)
  @test occursin("ON CONFLICT (\"circuitref\") DO NOTHING", goc(MrPGUp.Circuit, "circuitref" => "monza"; defaults = ["name" => "Monza"]))
  @test occursin("ON CONFLICT (\"circuitref\") DO NOTHING", goc(MrSLUp.Circuit, "circuitref" => "monza"; defaults = ["name" => "Monza"]))
  e = try; goc(MrMyUp.Status, "label" => "x"; defaults = ["code" => "F"]); nothing; catch err; err; end
  @test e isa PormG.QueryBuildError && occursin("get_or_create on status requires its lookup field(s) (label)", sprint(showerror, e))
  @test goc(MrMyUp.Standing, "raceid" => 1, "driverid" => 2; defaults = ["points" => 1.0]) isa String
  @test !_MR_QB._serializes_get_or_create(MrMockMySQL())
  # The re-read after a duplicate and the upsert's read-back are locking reads, and FOR SHARE: the
  # failed INSERT or the ODKU already holds that lock, and FOR UPDATE deadlocked two sessions that
  # lost the same race (measured, 1213). The pre-checks are plain reads.
  row = (; insert = Dict{String,Any}("circuitref" => "monza"))
  sql, params = _MR_QB._select_by_target("SELECT *", row, MrMyUp.Circuit, ["circuitref"], "`circuit`", MrMockMySQL(); lock = true)
  @test sql == "SELECT * FROM `circuit` WHERE `circuitref` = ? LIMIT 1 FOR SHARE;" && params.where_params == Any["monza"]
  @test _MR_QB._select_by_target("SELECT 1", row, MrMyUp.Circuit, ["circuitref"], "`circuit`", MrMockMySQL())[1] ==
        "SELECT 1 FROM `circuit` WHERE `circuitref` = ? LIMIT 1;"
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL update_or_create: every kind of unique key a row can conflict on is counted
# A key the check misses is the silent wrong-row update #1267 is about. Expected: a unique field a
# Julia default fills, one under `db_column` (named by its field), one a database default fills even
# when the row leaves it out, a OneToOneField, a unique ForeignKey, a partial UniqueConstraint, and
# the `(owner, related)` index of an auto many-to-many join table each raise BackendCapabilityError
# naming the key; a partial constraint is no lookup (QueryBuildError, "plain"). A key over the lookup
# and more, and a UUID PormG mints, cannot hit another row, so those build. PostgreSQL and SQLite
# build every shape.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL update_or_create: every kind of unique key a row can conflict on is counted" begin
  caught(f) = try; f(); nothing; catch e; e; end
  uoc(m, lookup...; defaults) = m.objects.update_or_create(lookup...; defaults = defaults, show_query = :sql)
  refused(e, needle) = e isa PormG.BackendCapabilityError && occursin(needle, sprint(showerror, e))
  @test refused(caught(() -> uoc(MrMyUp.Grid, "ref" => "a"; defaults = ["note" => "n"])), "(slot)")
  e = caught(() -> uoc(MrMyUp.Pit, "ref" => "a"; defaults = Pair{String,Any}["code" => "P1", "note" => "n"]))
  @test refused(e, "(code)") && refused(e, "(stamp)")
  e = caught(() -> uoc(MrMyUp.Pit, "ref" => "a"; defaults = ["note" => "n"]))
  @test refused(e, "(stamp)") && !occursin("(code)", sprint(showerror, e))
  @test occursin("ON DUPLICATE KEY UPDATE `note`", uoc(MrMyUp.Seat, "ref" => "a"; defaults = ["note" => "n"]))
  @test refused(caught(() -> uoc(MrMyUp.Seat, "ref" => "a"; defaults = Pair{String,Any}["circuit" => 1, "note" => "n"])), "(circuit)")
  @test refused(caught(() -> uoc(MrMyUp.Seat, "ref" => "a"; defaults = Pair{String,Any}["owner" => 1, "note" => "n"])), "(owner)")
  @test refused(caught(() -> uoc(MrMyUp.Entry, "ref" => "a"; defaults = ["note" => "n"])), "a functional or partial UniqueConstraint")
  e = caught(() -> uoc(MrMyUp.Entry, "alias" => "x"; defaults = ["ref" => "r", "note" => "n"]))
  @test e isa PormG.QueryBuildError && occursin("a plain (not partial or functional) UniqueConstraint", sprint(showerror, e))
  @test occursin("ON DUPLICATE KEY UPDATE `raceid`",
                 uoc(MrMyUp.Badge, "ref" => "a"; defaults = Pair{String,Any}["raceid" => 1, "note" => "n"]))
  @test refused(caught(() -> uoc(MrMyUp.Badge, "ref" => "a"; defaults = Pair{String,Any}["ticket" => UUIDs.uuid4(), "note" => "n"])),
                "(ticket)")
  # An auto many-to-many join table: its index is not a declared constraint, and still a key.
  join = Models.Model("car_driver"; id = Models.IDField(), car_id = Models.IntegerField(), driver_id = Models.IntegerField())
  join.cache["many_to_many_auto"] = Dict{String, Any}("field" => "drivers", "owner_column" => "car_id",
                                                      "related_column" => "driver_id",
                                                      "unique_index" => "car_driver_car_id_driver_id_uniq")
  @test (fields = ["car_id", "driver_id"], kind = :constraint) in _MR_QB._unique_keys(join)
  row = Dict{String,Any}("id" => 1, "car_id" => 2, "driver_id" => 3)
  @test refused(caught(() -> _MR_QB._refuse_unnamed_upsert_target("update_or_create", join, ["id"], row,
                                                                   Set(keys(row)), MrMockMySQL())), "(car_id, driver_id)")
  @test _MR_QB._refuse_unnamed_upsert_target("get_or_create", join, ["driver_id", "car_id"], row, Set(keys(row)),
                                             MrMockMySQL()) === nothing
  for models in (MrPGUp, MrSLUp)
    @test uoc(models.Pit, "ref" => "a"; defaults = Pair{String,Any}["code" => "P1", "note" => "n"]) isa String
    @test uoc(models.Entry, "alias" => "x"; defaults = ["ref" => "r", "note" => "n"]) isa String
  end
end

import DataFrames

# ─────────────────────────────────────────────────────────────────────────────
# MySQL bulk_insert: VALUES rows, the 65535-parameter cap, and ON DUPLICATE KEY UPDATE per action
# MySQL binds one `?` per cell, as SQLite, up to a prepared statement's 65535 parameters. Expected SQL:
# `INSERT INTO t (cols)\nVALUES (?, ?), (?, ?)\n`; DO NOTHING `ON DUPLICATE KEY UPDATE c = t.c` on the
# first inserted column that is not AUTO_INCREMENT (assigning that column fails with error 1869 when a
# new key repeats in one statement, measured); DO UPDATE the 3b row alias; a ONE-row DO NOTHING with no
# clause at all, since MySQL reports no count for one row and a duplicate key is counted as the skip.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL bulk_insert: VALUES rows, the parameter cap, and ON DUPLICATE KEY UPDATE per action" begin
  bulk(m, df; kw...) = _MR_QB.bulk_insert(m, df; show_query = :sql, kw...)
  df = DataFrames.DataFrame(constructorref = ["mclaren", "brabham", "ligier"], nationality = ["British", "British", "French"])
  @test bulk(MrMyUp.Constructor, df) == "INSERT INTO `constructor` (`constructorref`, `nationality`)\nVALUES (?, ?), (?, ?), (?, ?)\n"
  d = _MR_QB.bulk_insert(MrMyUp.Constructor, df; show_query = :dict)
  @test d[:parameters] == Any["mclaren", "British", "brabham", "British", "ligier", "French"]
  @test length(bulk(MrMyUp.Constructor, df; chunk_size = 2)) == 2
  @test _MR_QB._backend_parameter_limit(MrMockMySQL()) == 65535   # the protocol's; a real pool answers MySQL.jl's 4096 (test_mysql_ext.jl)
  @test _MR_QB._bulk_chunk_rows(MrMockMySQL(), 100_000, 2, 0, :bulk_insert) == 32767
  @test !_MR_QB._bulk_binds_column_arrays(MrMockMySQL()) && !_MR_QB._overrides_generated_identity(MrMockMySQL())
  # DO NOTHING writes nothing, on a column that is not AUTO_INCREMENT even when the id comes first.
  @test endswith(bulk(MrMyUp.Constructor, df; on_conflict = :nothing),
                 "\nON DUPLICATE KEY UPDATE `constructorref` = `constructor`.`constructorref`\n")
  withid = DataFrames.DataFrame(constructorid = [1, 2], constructorref = ["mclaren", "brabham"])
  @test endswith(bulk(MrMyUp.Constructor, withid; on_conflict = :nothing),
                 "ON DUPLICATE KEY UPDATE `constructorref` = `constructor`.`constructorref`\n")
  # One row: no clause; the duplicate key is the skip.
  @test bulk(MrMyUp.Constructor, df[1:1, :]; on_conflict = :nothing) ==
        "INSERT INTO `constructor` (`constructorref`, `nationality`)\nVALUES (?, ?)\n"
  @test _MR_QB._counts_skips_from_report(MrMockMySQL()) && !_MR_QB._counts_skips_from_report(MrMockSQLite())
  upsert = (action = :update, target = ["constructorref"], set = ["nationality"])
  @test endswith(bulk(MrMyUp.Constructor, df; on_conflict = upsert),
                 "\nAS `__pormg_new` ON DUPLICATE KEY UPDATE `nationality` = `__pormg_new`.`nationality`\n")
  @test endswith(bulk(MrMyUp.Constructor, df[1:1, :]; on_conflict = upsert),
                 "AS `__pormg_new` ON DUPLICATE KEY UPDATE `nationality` = `__pormg_new`.`nationality`\n")
  # PostgreSQL and SQLite keep ON CONFLICT, a one-row chunk included.
  @test endswith(_MR_QB.bulk_insert(MrSLUp.Constructor, df[1:1, :]; on_conflict = :nothing, show_query = :sql),
                 "ON CONFLICT DO NOTHING\n")
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL bulk_insert(on_conflict = …): the target must be the one unique key the rows can hit
# #1267, per call: a column holds a value when it is inserted and not NULL in every row, or the
# database fills it; an auto pk left out and a UUID PormG fills are new. Expected: a targeted DO
# NOTHING or a DO UPDATE whose rows can also conflict on another key raises BackendCapabilityError
# (`upsert_conflict_target`) naming it; a target that is not a unique key raises QueryBuildError; an
# untargeted `:nothing` (skip on any key, exactly MySQL's meaning) always builds; PostgreSQL and SQLite
# build every shape.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL bulk_insert(on_conflict = …): the target is the one unique key the rows can hit" begin
  bulk(m, df; kw...) = _MR_QB.bulk_insert(m, df; show_query = :sql, kw...)
  caught(f) = try; f(); nothing; catch e; e; end
  refused(e, needle) = e isa PormG.BackendCapabilityError && occursin(needle, sprint(showerror, e))
  upsert = (action = :update, target = ["constructorref"], set = ["nationality"])
  skip = (action = :nothing, target = ["constructorref"])
  coded = DataFrames.DataFrame(constructorref = ["mclaren", "brabham"], code = ["MCL", missing], nationality = ["B", "B"])
  e = caught(() -> bulk(MrMyUp.Constructor, coded; on_conflict = upsert))
  @test refused(e, "(code)") && occursin("bulk_insert(on_conflict = …) on constructor", sprint(showerror, e)) &&
        occursin("would update the row that key matches", sprint(showerror, e))
  e = caught(() -> bulk(MrMyUp.Constructor, coded; on_conflict = skip))
  @test refused(e, "(code)") && occursin("would skip a row that conflicts on that key", sprint(showerror, e))
  @test occursin("ON DUPLICATE KEY UPDATE", bulk(MrMyUp.Constructor, coded; on_conflict = :nothing))
  # A column NULL in every row cannot conflict.
  nulls = DataFrames.DataFrame(constructorref = ["mclaren", "brabham"], code = [missing, missing], nationality = ["B", "B"])
  @test occursin("ON DUPLICATE KEY UPDATE `nationality`", bulk(MrMyUp.Constructor, nulls; on_conflict = upsert))
  # A supplied auto id can conflict; an omitted one, or a UUID PormG fills, is new.
  withid = DataFrames.DataFrame(constructorid = [1, 2], constructorref = ["mclaren", "brabham"], nationality = ["B", "B"])
  @test refused(caught(() -> bulk(MrMyUp.Constructor, withid; on_conflict = upsert)), "(constructorid)")
  tokens = DataFrames.DataFrame(label = ["a", "b"], note = ["x", "y"])
  @test occursin("ON DUPLICATE KEY UPDATE `note`",
                 bulk(MrMyUp.Token, tokens; on_conflict = (action = :update, target = ["label"], set = ["note"])))
  supplied = DataFrames.DataFrame(token = [UUIDs.uuid4(), UUIDs.uuid4()], label = ["a", "b"], note = ["x", "y"])
  @test refused(caught(() -> bulk(MrMyUp.Token, supplied; on_conflict = (action = :update, target = ["label"], set = ["note"]))),
                "(token)")
  # A unique column the database fills (`db_default`) can conflict though the frame leaves it out.
  pits = DataFrames.DataFrame(ref = ["a", "b"], note = ["x", "y"])
  @test refused(caught(() -> bulk(MrMyUp.Pit, pits; on_conflict = (action = :update, target = ["ref"], set = ["note"]))),
                "(stamp)")
  e = caught(() -> bulk(MrMyUp.Status, DataFrames.DataFrame(code = ["F"], label = ["x"]);
                        on_conflict = (action = :nothing, target = ["label"])))
  @test e isa PormG.QueryBuildError && occursin("requires its on_conflict target (label) to be a unique key", sprint(showerror, e))
  for models in (MrPGUp, MrSLUp)
    @test occursin("ON CONFLICT (\"constructorref\") DO UPDATE", bulk(models.Constructor, coded; on_conflict = upsert))
    @test occursin("ON CONFLICT (\"constructorref\") DO NOTHING", bulk(models.Constructor, coded; on_conflict = skip))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL has no key to pre-allocate: returning = … with a server-generated pk, and allocate_primary_keys
# #1266: MySQL has no sequence, AUTO_INCREMENT cannot be drawn ahead of the INSERT, and a multi-row
# INSERT's ids are not promised consecutive. Expected: `returning` for an auto pk the frame does not
# carry, with no on_conflict target, and `allocate_primary_keys`, raise BackendCapabilityError naming
# `preallocated_keys` and the shapes that work; a supplied pk or a target builds; PostgreSQL and SQLite
# keep the pre-allocation (a dry run allocates nothing there).
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL bulk_insert(returning = …) and allocate_primary_keys: no key to pre-allocate" begin
  caught(f) = try; f(); nothing; catch e; e; end
  df = DataFrames.DataFrame(constructorref = ["mclaren", "brabham"], nationality = ["B", "B"])
  e = caught(() -> _MR_QB.bulk_insert(MrMyUp.Constructor, df; returning = ["constructorid"], show_query = :sql))
  @test e isa PormG.BackendCapabilityError
  msg = sprint(showerror, e)
  @test occursin("drawing auto-increment keys before the rows are written", msg) && occursin("MySQL", msg) &&
        occursin("Supply the primary key column", msg) && occursin("on_conflict", msg)
  @test _MR_QB.bulk_insert(MrMyUp.Constructor, df; returning = ["constructorid"], show_query = :sql,
                           on_conflict = (action = :nothing, target = ["constructorref"])) isa String
  withid = DataFrames.DataFrame(constructorid = [1, 2], constructorref = ["mclaren", "brabham"], nationality = ["B", "B"])
  @test _MR_QB.bulk_insert(MrMyUp.Constructor, withid; returning = ["nationality"], show_query = :sql) isa String
  e = caught(() -> _MR_QB.allocate_primary_keys(MrMyUp.Constructor, df))
  @test e isa PormG.BackendCapabilityError && occursin("allocating constructor's primary keys", sprint(showerror, e))
  @test !PormG.Kernel._supports(MrMockMySQL(), :preallocated_keys)
  @test PormG.Kernel._supports(MrMockPostgres(), :preallocated_keys) && PormG.Kernel._supports(MrMockSQLite(), :preallocated_keys)
  for models in (MrPGUp, MrSLUp)
    @test _MR_QB.bulk_insert(models.Constructor, df; returning = ["constructorid"], show_query = :sql) isa String
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL bulk_update: a multi-table UPDATE over a VALUES ROW derived table; the many-to-many add
# MySQL has no UPDATE … FROM. Expected SQL: `UPDATE t AS `Tb`, (VALUES ROW(?, ?), …) AS source (cols)
# SET `Tb`.col = source.col WHERE `Tb`.key = source.key`, every SET target qualified (a bare one is
# ambiguous there, error 1052, measured); a `filters=` membership subquery over the same table inside a
# derived table (error 1093 otherwise); the parameters in text order. PostgreSQL and SQLite render as
# before. The many-to-many `add` takes PostgreSQL's idempotent NOT EXISTS shape.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL bulk_update: a multi-table UPDATE over a VALUES ROW derived table" begin
  df = DataFrames.DataFrame(constructorid = [1, 2], nationality = ["British", missing])
  d = _MR_QB.bulk_update(MrMyUp.Constructor, df; show_query = :dict)
  @test d[:sql_text] == "UPDATE `constructor` AS `Tb`, (VALUES ROW(?, ?), ROW(?, ?)) AS source (`constructorid`, `nationality`)\n" *
                        "SET `Tb`.`nationality` = source.`nationality`\n" *
                        "WHERE `Tb`.`constructorid` = source.`constructorid`\n"
  @test isequal(d[:parameters], Any[1, "British", 2, missing])
  @test _MR_QB._values_row_prefix(MrMockMySQL()) == "ROW" && _MR_QB._values_row_prefix(MrMockSQLite()) == ""
  # A membership subquery on the table being written is read through a derived table (error 1093
  # otherwise); its value binds after the rows, as it renders.
  members = MrMyUp.Constructor.objects.filter("code" => "MCL").values("constructorid")
  d = _MR_QB.bulk_update(MrMyUp.Constructor, df; filters = ["constructorid__@in" => members], show_query = :dict)
  @test occursin("WHERE `Tb`.`constructorid` = source.`constructorid` AND \n   `Tb`.`constructorid` IN (SELECT * FROM (SELECT", d[:sql_text])
  @test occursin(") AS `__pormg_members`)", d[:sql_text]) && isequal(d[:parameters], Any[1, "British", 2, missing, "MCL"])
  # PostgreSQL and SQLite render as before: an unqualified SET target, and no derived table.
  pg = _MR_QB.bulk_update(MrPGUp.Constructor, df; show_query = :sql,
                          filters = ["constructorid__@in" => MrPGUp.Constructor.objects.filter("code" => "MCL").values("constructorid")])
  @test startswith(pg, "UPDATE \"constructor\" AS \"Tb\"\nSET \"nationality\" = source.\"nationality\"\nFROM unnest(")
  @test !occursin("__pormg_members", pg)
  @test _MR_QB.bulk_update(MrSLUp.Constructor, df; show_query = :sql) ==
        "WITH source(\"constructorid\", \"nationality\") AS (\n  VALUES (?, ?), (?, ?)\n)\nUPDATE \"constructor\"\n" *
        "SET \"nationality\" = source.\"nationality\"\nFROM source\nWHERE \"constructor\".\"constructorid\" = source.\"constructorid\"\n"
  # The many-to-many `add`: PostgreSQL's NOT EXISTS shape on MySQL too, SQLite's INSERT OR IGNORE.
  my_add = which(_MR_QB._m2m_add!, Tuple{MrMockMySQL, Any, Any, Any, Any, Any, Any})
  @test my_add === which(_MR_QB._m2m_add!, Tuple{MrMockPostgres, Any, Any, Any, Any, Any, Any})
  @test my_add !== which(_MR_QB._m2m_add!, Tuple{MrMockSQLite, Any, Any, Any, Any, Any, Any})
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL DurationField writes bind the microseconds a filter binds (#1348)
# A `DurationField` is a BIGINT of microseconds on MySQL (#1130 phase 2b). Expected: `create`, `update`,
# `bulk_insert` and `bulk_update` bind `Millisecond(83456)` as `83456000`, never the `"00:01:23.456"`
# text MySQL rejects (1265); a duration string the field parses binds the same number; a value that is
# no duration raises the field's own refusal; SQLite keeps the text it stores.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL DurationField writes: every write path binds the microseconds (#1348)" begin
  v = Millisecond(83456)
  us = 83_456_000
  row(t) = ("raceid" => 1, "driverid" => 1, "grid" => 1, "points" => 0.0, "laps" => 50, "fastestlaptime" => t)
  texts(params) = filter(p -> p isa AbstractString && occursin(':', p), params)
  ins = _MR_MY.Result.objects.create(row(v)...; show_query = :dict)
  @test us in ins[:parameters] && isempty(texts(ins[:parameters]))
  @test us in _MR_MY.Result.objects.create(row("1:23.456")...; show_query = :dict)[:parameters]
  @test _MR_MY.Result.objects.filter("resultid" => 1).update("fastestlaptime" => v; show_query = :dict)[:parameters] ==
        Any[us, 1]
  df = DataFrames.DataFrame(raceid = [1], driverid = [1], grid = [1], points = [0.0], laps = [50], fastestlaptime = [v])
  bi = _MR_QB.bulk_insert(_MR_MY.Result, df; show_query = :dict)[:parameters]
  @test us in bi && isempty(texts(bi))
  @test _MR_QB.bulk_update(_MR_MY.Result, DataFrames.DataFrame(resultid = [1], fastestlaptime = [v]); show_query = :dict)[:parameters] ==
        Any[1, us]
  @test_throws PormG.InvalidValueError _MR_MY.Result.objects.filter("resultid" => 1).update("fastestlaptime" => 5; show_query = :dict)
  # `validate_value` formats as `create` does, for the engine the model is bound to.
  @test PormG.validate_value(_MR_MY.Result, "fastestlaptime", v) == us
  @test PormG.validate_value(_MR_SL.Result, "fastestlaptime", v) == "00:01:23.456"
  # SQLite stores the text, and keeps binding it.
  @test "00:01:23.456" in _MR_SL.Result.objects.filter("resultid" => 1).update("fastestlaptime" => v; show_query = :dict)[:parameters]
  @test "00:01:23.456" in _MR_QB.bulk_insert(_MR_SL.Result, df; show_query = :dict)[:parameters]
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL's report of a multi-row INSERT, and its duplicate-key errors
# The OK packet's text after a multi-row INSERT is `Records: N  Duplicates: D  Warnings: W` (measured),
# in the session's `lc_messages` language and always in that order, so it is read by position; a
# one-row INSERT has none. A duplicate on a unique key is errno 1062/1022/1586/1169; a foreign-key
# failure or any other constraint is not, though every one of them carries SQLSTATE 23000.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL extension: a multi-row INSERT's report, and a duplicate key by its number" begin
  ext = Base.get_extension(PormG, :PormGMySQLExt)
  @test ext._insert_report("Records: 4  Duplicates: 2  Warnings: 0") == (records = 4, duplicates = 2)
  @test ext._insert_report("Records: 3  Duplicates: 0  Warnings: 1") == (records = 3, duplicates = 0)
  @test ext._insert_report("") === nothing
  # Measured on 8.4 under `lc_messages` pt_BR, de_DE and ja_JP.
  @test ext._insert_report("Registros: 2 - Duplicados: 1 - Avisos: 0") == (records = 2, duplicates = 1)
  @test ext._insert_report("Datensätze: 2  Duplikate: 1  Warnungen: 0") == (records = 2, duplicates = 1)
  @test ext._insert_report("レコード数: 2  重複数: 1  警告: 0") == (records = 2, duplicates = 1)
  integrity(errno) = PormG.IntegrityError("MySQL", MySQL.Protocol.Error(errno, "x", "23000"); sqlstate = "23000")
  @test all(ext._is_duplicate_key ∘ integrity, (1062, 1022, 1586, 1169))
  @test !ext._is_duplicate_key(integrity(1452)) && !ext._is_duplicate_key(integrity(1048))
  @test !ext._is_duplicate_key(PormG.StatementError("MySQL", MySQL.Protocol.Error(1062, "x", "23000")))
end
