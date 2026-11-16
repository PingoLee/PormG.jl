# ============================================================
# test/unit/test_server_write_trim_1614.jl
#
# CONTRACT being tested:
#   The typed forms the single-row write reads a MySQL or Postgres.jl result through (#1599 layer 7, #1614) return
#   what the forms they replaced returned, and raise what they raised:
#     - the field-keyed decode of a driver result (`_FieldRowDecoder` called on a `Postgres.Result` or a
#       `MySQLResult`, the extensions' methods) is `_row_to_field_keyed_dict` over `Tables.rowtable(result)`, the
#       read `create`'s RETURNING arm made, row for row;
#     - the row count of a driver result (`_RowCounter`, the extensions' methods) is `length(Tables.rowtable(result))`;
#     - `_models_to_lock` (a loop over typed models now) returns the models its comprehension returned, in order.
#   Each was written so a `juliac --trim` image can run it; the old form is the oracle.
#
# Hermetic: no database. The results are built from their fields, as test_postgres_ext.jl and test_mysql_ext.jl
# build them; the pools are never connected.
#
# Run: julia --project=test/integration test/unit/test_server_write_trim_1614.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates

const _SWT_QB = PormG.QueryBuilder
const _SWT_M = PormG.Models
const _SWT_Tables = _SWT_QB.Tables   # through PormG: Tables is not a direct test dependency
const _SWT_PG = Base.get_extension(PormG, :PormGPostgresExt)
const _SWT_MY = Base.get_extension(PormG, :PormGMySQLExt)

_swt_outcome(f) = try
  (:ok, f())
catch e
  (:err, typeof(e), sprint(showerror, e))
end

# The F1 race, with a `db_column` field (the row is keyed by the field's name, not the column's) and the three
# auto-filled kinds the fixture writes.
_swt_model() = _SWT_M.Model("swt_race",
  raceid = _SWT_M.IDField(), year = _SWT_M.IntegerField(), round = _SWT_M.IntegerField(null = true),
  circuitid = _SWT_M.IntegerField(db_column = "circuit_ref"), name = _SWT_M.CharField(), date = _SWT_M.DateField(),
  created_at = _SWT_M.DateTimeField(), updated_on = _SWT_M.DateField(), token = _SWT_M.UUIDField(),
  points = _SWT_M.DecimalField(max_digits = 5, decimal_places = 1, null = true))

const _SWT_NAMES = [:raceid, :year, :round, :circuit_ref, :name, :date, :created_at, :updated_on, :token, :points, :extra]

function _swt_pg_result(rows::Vector{Vector{Any}})
  names = _SWT_NAMES
  # Each column's type from the template rows (a real result's types come from its OIDs, never `Union{}`).
  tmpl = _swt_rows_pg()
  types = Type[reduce((a, b) -> Union{a, b}, unique(typeof(row[j]) for row in tmpl); init = Union{}) for j in eachindex(names)]
  lookup = Dict(n => j for (j, n) in enumerate(names))
  return _SWT_PG.Postgres.Result(names, types,
    [_SWT_PG.Postgres.ResultRow(Any[row...], names, types, lookup, i) for (i, row) in enumerate(rows)],
    "SELECT $(length(rows))", length(rows))
end

function _swt_my_result(rows::Vector{Vector{Any}})
  cols = AbstractVector[identity.([row[j] for row in rows]) for j in eachindex(_SWT_NAMES)]
  return _SWT_MY.MySQLResult(copy(_SWT_NAMES), cols, length(rows), 0, UInt64(0), "")
end

const _SWT_TZ = _SWT_M.TimeZones
_swt_rows_pg() = [
  Any[Int64(1), Int32(2009), Int32(6), Int64(1), "Monaco Grand Prix", Date(2009, 5, 24),
      _SWT_TZ.ZonedDateTime(DateTime(2009, 5, 24, 14), _SWT_TZ.TimeZone("UTC")), Date(2026, 11, 15),
      "550e8400-e29b-41d4-a716-446655440000", _SWT_M.Decimals.Decimal(0, 255, -1), "x"],
  Any[Int64(2), Int32(2010), missing, Int64(1), "Monaco Grand Prix", Date(2010, 5, 16),
      _SWT_TZ.ZonedDateTime(DateTime(2010, 5, 16, 14), _SWT_TZ.TimeZone("UTC")), Date(2026, 11, 15),
      "650e8400-e29b-41d4-a716-446655440000", missing, missing],
]
# MySQL's cells as MySQL.jl delivers them: the timestamp as a `DateTime`, the decimal as its text.
_swt_rows_my() = [
  Any[Int64(1), Int32(2009), Int32(6), Int64(1), "Monaco Grand Prix", Date(2009, 5, 24), DateTime(2009, 5, 24, 14),
      Date(2026, 11, 15), "550e8400-e29b-41d4-a716-446655440000", "25.5", "x"],
  Any[Int64(2), Int32(2010), missing, Int64(1), "Monaco Grand Prix", Date(2010, 5, 16), DateTime(2010, 5, 16, 14),
      Date(2026, 11, 15), "650e8400-e29b-41d4-a716-446655440000", missing, missing],
]

# What: the field-keyed decode and the row count of a Postgres.jl and a MySQL result, against the read `create`
#   made: `_row_to_field_keyed_dict` over `Tables.rowtable(result)`, and `length(Tables.rowtable(result))`. Over
#   two rows (NULLs, a `db_column` field, a column that is no field's, a decimal, a timestamp), one row, no rows,
#   and a decimal wider than its field.
# Expected: the same keys, values and value types row for row; the same count; for the wide decimal, the same
#   outcome either way (whatever the read parser does with it).
# Why: the extensions' methods read each cell at its type so a trimmed image can run them (the server entries'
#   `create` and `delete` stopped at `Tables.rowtable`); under the JIT they must be invisible.
@testset "a server result decodes into the row create read before (#1599 layer 7, #1614)" begin
  model = _swt_model()
  for (label, pool, mk, rows) in (
      ("Postgres.jl", PormG.ConnectionPool.PostgresConnectionPool("host=x dbname=y"; driver = :postgres), _swt_pg_result, _swt_rows_pg()),
      ("MySQL", PormG.ConnectionPool.MySQLConnectionPool("host='x'"), _swt_my_result, _swt_rows_my()))
    dec = _SWT_QB._FieldRowDecoder(model, pool)
    old(res) = [_SWT_QB._row_to_field_keyed_dict(r, model, pool) for r in _SWT_Tables.rowtable(res)]
    norm(o) = o[1] === :ok ? (:ok, [Dict(k => (typeof(v), v) for (k, v) in d) for d in o[2]]) : o
    for rs in (rows, rows[1:1], Vector{Any}[])
      isempty(rs) && label == "MySQL" && continue   # an empty MySQLResult has no column types to build
      res = mk(rs)
      @test (label, length(rs), isequal(norm(_swt_outcome(() -> dec(res))), norm(_swt_outcome(() -> old(res))))) ==
            (label, length(rs), true)
      @test _SWT_QB._RowCounter()(res) == length(_SWT_Tables.rowtable(res))
    end
    # A decimal wider than the field (5, 1): the parser refuses it, the same way through both reads.
    wide = deepcopy(rows[1:1])
    wide[1][10] = label == "MySQL" ? "123456.5" : _SWT_M.Decimals.Decimal(0, 1234565, -1)
    res = mk(wide)
    a, b = norm(_swt_outcome(() -> dec(res))), norm(_swt_outcome(() -> old(res)))
    @test (label, isequal(a, b)) == (label, true)
  end
end

# The lock order as the old comprehension computed it.
_swt_old_lock_order(c) = PormG.PormGModel[m for m in reverse(c.sorted_models) if m in begin
    emitters = Set{PormG.PormGModel}(keys(c.objects))
    for affected in values(c.field_updates); union!(emitters, keys(affected)); end
    parents = Set{PormG.PormGModel}()
    for child in emitters; union!(parents, get(c.dependencies, child, Set{PormG.PormGModel}())); end
    parents
  end && haskey(c.objects, m)]

# What: `_models_to_lock` against its old comprehension, over collectors with no parent, one parent, a parent only
#   a SET_NULL update reaches, and parents not in `objects`.
# Expected: the same models in the same order.
# Why: it is now a loop with each model at its type, so a trimmed image can run delete's lock planning on MySQL
#   and PostgreSQL (the server entries' `delete` stopped at the comprehension's filter closure).
@testset "delete's lock order is the order it was (#1599 layer 7, #1614)" begin
  key = "swt_lock"
  PormG.config[key] = PormG.Configuration.Settings(connections = PormG.ConnectionPool.MySQLConnectionPool("host='x'"))
  try
    mk(name) = _SWT_M.Model(name, id = _SWT_M.IDField())
    circuit, race, result, status = mk("swt_circuit"), mk("swt_race2"), mk("swt_result"), mk("swt_status")
    entry = Dict{Symbol, Union{String, PormG.SQLObjectHandler}}(:key => "1")
    cases = Any[]
    c = _SWT_QB.DeletionCollector(race, PormG.config[key])                       # one model, no parent
    c.objects[race] = [entry]; c.sorted_models = PormG.PormGModel[race]; push!(cases, c)
    c = _SWT_QB.DeletionCollector(circuit, PormG.config[key])                    # circuit <- race <- result
    for m in (circuit, race, result); c.objects[m] = [entry]; end
    c.dependencies[race] = Set{PormG.PormGModel}([circuit]); c.dependencies[result] = Set{PormG.PormGModel}([race])
    c.sorted_models = PormG.PormGModel[result, race, circuit]; push!(cases, c)
    c = _SWT_QB.DeletionCollector(circuit, PormG.config[key])                    # a parent only a SET_NULL reaches
    c.objects[circuit] = [entry]; c.objects[status] = [entry]
    c.field_updates[("statusid", nothing)] = Dict{PormG.PormGModel, Vector{Dict{Symbol, Union{String, PormG.SQLObjectHandler}}}}(result => [entry])
    c.dependencies[result] = Set{PormG.PormGModel}([status])
    c.sorted_models = PormG.PormGModel[result, status, circuit]; push!(cases, c)
    c = _SWT_QB.DeletionCollector(race, PormG.config[key])                       # a parent with no objects
    c.objects[race] = [entry]; c.dependencies[race] = Set{PormG.PormGModel}([circuit])
    c.sorted_models = PormG.PormGModel[race, circuit]; push!(cases, c)
    for (i, c) in enumerate(cases)
      @test (i, _SWT_QB._models_to_lock(c)) == (i, _swt_old_lock_order(c))
    end
  finally
    delete!(PormG.config, key)
  end
end
