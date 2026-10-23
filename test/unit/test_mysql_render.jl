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
# define, so the shadowed-alias guard must find `driver`'s columns through the relation.
PormG.config["mr_my_cross"] = PormG.Configuration.Settings(connections = MrMockMySQL(), change_data = true,
                                                           db_def_folder = "mr_my_cross")
module MrMyCrossA
import PormG
import PormG.Models
Driver = Models.Model(driverid = Models.IDField(), surname = Models.CharField(), nationality = Models.CharField())
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
  @test _MR_QB.add_parameter!(params, PormG.PormGBytes(UInt8[0x00, 0xff])) == "?"
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
  @test occursin("ORDER BY (`position` IS NULL) DESC, `position` DESC",
                 _mr_inspect(_MR_MY.Result.objects.values("position").order_by("-position"))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL NULL placement: an alias that is also a FROM column's name is refused
# Inside `(alias IS NULL)` MySQL reads a name as a FROM column before a result alias (measured on
# 8.4), so `values("laps" => "position").order_by("-laps")` would test the never-NULL `laps` column and
# sort the NULL positions last, silently. Expected: that refused with QueryBuildError before any SQL,
# on a joined table's column too; a rename no column shares, an aggregate alias, and a projection
# that IS the column of its name build; PostgreSQL and SQLite build the shadowing shape as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL NULL placement: an alias that is also a FROM column's name is refused" begin
  refused(q) = try; _mr_inspect(q); false; catch e; e isa PormG.QueryBuildError && occursin("has a column with that name", sprint(showerror, e)); end
  @test refused(_MR_MY.Result.objects.values("laps" => "position").order_by("-laps"))
  # `surname` is a column of the joined `driver` table, not of `result`.
  @test refused(_MR_MY.Result.objects.values("surname" => "raceid__name", "driverid__nationality").order_by("surname"))
  # These name no other column, or are that column under its own name: they build.
  @test !refused(_MR_MY.Result.objects.values("pos2" => "position").order_by("-pos2"))
  @test !refused(_MR_MY.Result.objects.values("driverid", "total" => Sum("laps")).order_by("total"))
  @test !refused(_MR_MY.Result.objects.values("position").order_by("-position"))
  @test !refused(_MR_MY.Result.objects.values("surname" => "driverid__surname").order_by("surname"))
  @test !refused(_MR_MY.Result.objects.values("laps" => "position").order_by("resultid"))
  # A CTE's projection and a `cjoin_on` table's column shadow the same way.
  q = _MR_MY.Result.objects
  q.with("br" => _MR_MY.Driver.objects.values("driverid", "surname"), join_field = "driverid" => "driverid")
  @test refused(q.values("surname" => "position", "br_driver" => CTE("br", "driverid")).order_by("-surname"))
  # Declared but not joined (nothing projects it), the CTE is not in FROM, so its names collide with nothing.
  q = _MR_MY.Result.objects
  q.with("br" => _MR_MY.Driver.objects.values("driverid", "surname"), join_field = "driverid" => "driverid")
  @test !refused(q.values("surname" => "position", "resultid").order_by("-surname"))
  q = _MR_MY.Result.objects.values("surname" => "position", "d_name" => Joined("d", "forename"))
  q.cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid")])
  @test refused(q.order_by("-surname"))
  # A joined model defined in another module is found through the relation itself.
  @test refused(MrMyCrossB.Lap.objects.values("surname" => "position", "driverid__nationality").order_by("-surname"))
  @test !refused(MrMyCrossB.Lap.objects.values("pos2" => "position", "driverid__nationality").order_by("-pos2"))
  # … and through a reverse relation: `lap`, defined in the other module, has the `position` column.
  @test refused(MrMyCrossA.Driver.objects.values("position" => "surname", "laps__lapid").order_by("-position"))
  # The other engines build the shadowing shape: PostgreSQL places NULLs natively, and SQLite only
  # emulates below 3.30.
  @test !refused(_MR_PG.Result.objects.values("laps" => "position").order_by("-laps"))
  @test !refused(_MR_SL.Result.objects.values("laps" => "position").order_by("-laps"))
  # A path MySQL does not render yet says so, rather than reporting a PormG bug.
  msg = sprint(showerror, _MR_QB._unsupported_conn("date/interval arithmetic", MrMockMySQL()))
  @test occursin("not rendered for MySQL yet", msg) && !occursin("PormG bug", msg)
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
# (#1121); a `DurationField` is a BIGINT of microseconds (#1130). Expected: those four parsed — the
# interval into the `CompoundPeriod` SQLite reads, in the same units — every parser fail-open on a value
# it does not recognize, and no parser for the kinds MySQL.jl already delivers typed (a date, a time, a
# naive datetime, a decimal column).
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL read parsers: what MySQL.jl delivers, turned into what the kind means" begin
  my = MrMockMySQL()
  parse_bool = PormG.value_parser(PormG.CBool(), my)
  @test parse_bool(Int8(1)) === true && parse_bool(Int8(0)) === false && parse_bool(Int64(1)) === true
  @test parse_bool(missing) === missing && parse_bool(Int8(2)) === Int8(2)
  parse_ts = PormG.value_parser(PormG.CDateTime(true), my)
  @test parse_ts(DateTime(1991, 3, 10, 14, 0, 0, 125)) == ZonedDateTime(DateTime(1991, 3, 10, 14, 0, 0, 125), tz"UTC")
  @test parse_ts(missing) === missing
  @test PormG.value_parser(PormG.CDateTime(false), my) === nothing
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
  for kind in (PormG.CDate(), PormG.CTime(), PormG.CDecimal(10, 2), PormG.CText(), PormG.CInt64())
    @test (kind, PormG.value_parser(kind, my)) == (kind, nothing)
  end
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
  @test [t(x) for x in ("numeric", "decimal", "dec", "numeric(10,2)", "numeric(5)")] ==
        ["DECIMAL(65,30)", "DECIMAL(65,30)", "DECIMAL(65,30)", "DECIMAL(10,2)", "DECIMAL(5)"]
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
  @test occursin("CAST(`Tb`.`points` AS DECIMAL(10,2)) as `c`", sel(PormG.QueryBuilder.Cast("points", "numeric(10,2)")))
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
        ("CAST(COALESCE(`Tb`.`position`, ?) AS DECIMAL(10,2))", Any[0])
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
        ("ROUND(CAST(SQRT(CAST(`Tb`.`grid` AS DECIMAL(10,2))) AS DECIMAL(65,30)), ?)", Any[2])
  @test proj(() -> R.objects.values("v" => QB.Round(dec(), 1))) == ("ROUND(CAST(`Tb`.`grid` AS DECIMAL(10,2)), ?)", Any[1])
  @test proj(() -> R.objects.values("v" => QB.Round(QB.Sum(dec()), 1))) == ("ROUND(SUM(CAST(`Tb`.`grid` AS DECIMAL(10,2))), ?)", Any[1])
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
  @test PormG.value_parser(PormG.CDecimal(10, 2), my) === nothing
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
