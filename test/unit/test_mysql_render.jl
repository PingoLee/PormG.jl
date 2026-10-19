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
using Dates, UUIDs, Decimals
import PormG.QueryBuilder: Sum, Avg, Count, Max, Min

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
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
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
# MySQL aggregates: a sum of integers is cast back to the integer it means
# MySQL's SUM over an integer column is a DECIMAL (`SUM(INT)` and `SUM(BIGINT)` alike); the sum of
# integers means an integer (Django's `Sum` of an integer field), so it renders
# `CAST(SUM(x) AS SIGNED)`, and the type walk names the same `CInt64`. Expected: the cast on integer
# operands only, in the SELECT and in a HAVING that filters on it; AVG/COUNT/MAX/MIN bare; the
# PostgreSQL and SQLite renders unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MySQL aggregates: a sum of integers is cast back to the integer it means" begin
  sel(M, f) = _mr_inspect(M.Result.objects.values("driverid", "agg" => f))[:sql_text]
  @test occursin("CAST(SUM(`Tb`.`grid`) AS SIGNED) as `agg`", sel(_MR_MY, Sum("grid")))
  @test occursin("CAST(SUM(DISTINCT `Tb`.`laps`) AS SIGNED)", sel(_MR_MY, Sum("laps"; distinct = true)))
  @test occursin("SUM(`Tb`.`points`) as `agg`", sel(_MR_MY, Sum("points")))
  @test !occursin("CAST", sel(_MR_MY, Sum("points")))
  @test occursin("AVG(`Tb`.`grid`) as `agg`", sel(_MR_MY, Avg("grid")))
  @test occursin("COUNT(DISTINCT `Tb`.`grid`)", sel(_MR_MY, Count("grid"; distinct = true)))
  @test occursin("MAX(`Tb`.`points`)", sel(_MR_MY, Max("points"))) && occursin("MIN(`Tb`.`grid`)", sel(_MR_MY, Min("grid")))
  having = _mr_inspect(_MR_MY.Result.objects.values("driverid", "total" => Sum("grid")).filter("total__@gt" => 10))
  @test occursin("HAVING CAST(SUM(`Tb`.`grid`) AS SIGNED) > ?", having[:sql_text]) && having[:parameters] == Any[10]
  # The other engines never see the MySQL flag.
  @test occursin("SUM(\"Tb\".\"grid\") as \"agg\"", sel(_MR_PG, Sum("grid"))) && !occursin("CAST", sel(_MR_PG, Sum("grid")))
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
  build_select = read(joinpath(pkgdir(PormG), "src", "querybuilder", "build_select.jl"), String)
  @test occursin("_order_term_sql(order_expr, orientation, placement, instruc.connection", build_select)
  @test occursin("ORDER BY (`position` IS NULL) DESC, `position` DESC",
                 _mr_inspect(_MR_MY.Result.objects.values("position").order_by("-position"))[:sql_text])
end
