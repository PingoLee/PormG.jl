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
# payload as its bytes, a Decimal unchanged (the extension binds its exact text), and an ArrayField
# value raises BackendCapabilityError rather than binding as text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL collector: values as MySQL.jl binds them" begin
  params = _MR_QB.get_parameter(MrMockMySQL())
  @test _MR_QB.add_parameter!(params, [1, 2, 3]) == "?, ?, ?"
  u = UUID("123e4567-e89b-12d3-a456-426614174000")
  @test _MR_QB.add_parameter!(params, u) == "?"
  @test _MR_QB.add_parameter!(params, PormG.PormGBytes(UInt8[0x00, 0xff])) == "?"
  @test _MR_QB.add_parameter!(params, Decimal(0, 255, -1)) == "?"
  @test params.parameters == Any[1, 2, 3, "123e4567-e89b-12d3-a456-426614174000", UInt8[0x00, 0xff], Decimal(0, 255, -1)]
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
# MySQL DurationField filters: refused until its storage is decided
# What a `DurationField` stores on MySQL is the migrations phase's decision, so an equality or a
# membership would bind the `HH:MM:SS` text and the server would answer by whatever the column holds.
# Expected: every comparison, a membership and a range on a duration column raise
# UnsupportedConnectionError naming the filter, before any SQL; `IS NULL` builds; PostgreSQL and SQLite
# build the same filters.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL DurationField filters: refused until its storage is decided" begin
  refused(q) = try; _mr_inspect(q); false; catch e
    e isa PormG.UnsupportedConnectionError && occursin("A DurationField filter is not rendered for MySQL yet", sprint(showerror, e))
  end
  for pair in ("fastestlaptime" => Second(80), "fastestlaptime__@ne" => Second(80),
               "fastestlaptime__@in" => [Second(80), Second(90)], "fastestlaptime__@gt" => Minute(1),
               "fastestlaptime__@range" => [Minute(1), Minute(2)])
    @test (pair.first, refused(_MR_MY.Result.objects.filter(pair))) == (pair.first, true)
    @test (pair.first, refused(_MR_PG.Result.objects.filter(pair))) == (pair.first, false)
    @test (pair.first, refused(_MR_SL.Result.objects.filter(pair))) == (pair.first, false)
  end
  @test occursin("IS NULL", _mr_inspect(_MR_MY.Result.objects.filter("fastestlaptime__@isnull" => true))[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL read parsers: what MySQL.jl delivers, turned into what the kind means
# #1270: the wire has no boolean (a `TINYINT(1)` reads as `Int8`, a comparison as `Int64`); a
# DATETIME has no zone and the session is UTC; `AVG` over an integer is a DECIMAL that means a float
# (#1121). Expected: those three parsed, every parser fail-open on a value it does not recognize, and
# no parser for the kinds MySQL.jl already delivers typed (a date, a time, a naive datetime, a decimal
# column) or that have no MySQL storage yet (an interval).
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
  for kind in (PormG.CDate(), PormG.CTime(), PormG.CInterval(), PormG.CDecimal(10, 2), PormG.CText(), PormG.CInt64())
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
  r = q(F("date") - (Year(1) + Month(2)))
  @test occursin("((`Tb`.`date` - INTERVAL ? YEAR) - INTERVAL ? MONTH)", r[:sql_text]) && r[:parameters] == Any[1, 2]
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
# MySQL intervals: every edge of the millisecond form refuses before any SQL (#1130 phase 2b)
# MySQL computes an interval in milliseconds, as SQLite does (`_interval_as_ms`), but its millisecond
# SQL is the follow-up to phase 2b and a DurationField's storage is phase 4's. Expected: a timestamp
# difference, a DurationField in an ordering, an aggregate or arithmetic, and a date shifted by one,
# each raise UnsupportedConnectionError before any SQL (never SQLite's millisecond SQL, which MySQL
# rejects at the server); a projected DurationField still renders its column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL intervals: every edge of the millisecond form refuses before any SQL" begin
  refused(build) = (e = try; _mr_inspect(build()); nothing; catch err; err; end;
                    e isa PormG.UnsupportedConnectionError && occursin("is not rendered for MySQL yet", sprint(showerror, e)))
  # A timestamp difference is an interval: refused at its render (the mock models have no timestamp).
  @test_throws PormG.UnsupportedConnectionError _MR_QB._temporal_difference_sql(MrMockMySQL(), "`a`", "`b`", PormG.CInterval())
  @test _MR_QB._temporal_difference_sql(MrMockMySQL(), "`a`", "`b`", PormG.CInt32()) == ("DATEDIFF(`a`, `b`)", PormG.CInt32())
  @test refused(() -> _MR_MY.Result.objects.values("resultid").order_by("fastestlaptime"))
  @test refused(() -> _MR_MY.Result.objects.values("v" => Sum("fastestlaptime")))
  @test refused(() -> _MR_MY.Result.objects.values("v" => F("fastestlaptime") * 2))
  @test refused(() -> _MR_MY.Result.objects.values("v" => F("raceid__date") + F("fastestlaptime")))
  @test occursin("`Tb`.`fastestlaptime` as `v`", _mr_inspect(_MR_MY.Result.objects.values("v" => F("fastestlaptime")))[:sql_text])
  # The per-engine edges: SQLite's are its own Dialect helpers, unchanged.
  @test _MR_QB._interval_text_as_ms("`c`", MrMockSQLite()) == PormG.Dialect._sqlite_interval_ms("`c`")
  @test _MR_QB._interval_ms_as_text("?", MrMockSQLite()) == PormG.Dialect._sqlite_interval_text("?")
  @test_throws PormG.UnsupportedConnectionError _MR_QB._interval_text_as_ms("`c`", MrMockMySQL())
end
