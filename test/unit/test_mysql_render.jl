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
