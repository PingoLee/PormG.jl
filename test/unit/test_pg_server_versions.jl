"""
Unit coverage for PostgreSQL schema introspection on servers older than 11 (#1162).

`inspectdb` and `import_models_from_postgres` are the classic way to read a legacy database whose
version the application does not choose. Every catalog column the readers name that is newer than
9.6 is read only where it exists; below its version an exact "absent" value stands in, because the
feature it describes does not exist there either (`_PG_CATALOG_COLUMNS`):

| Column | From | Below it |
|---|---|---|
| `pg_index.indnkeyatts` | 11 | `indnatts`: no `INCLUDE`, every column is a key column |
| `pg_attribute.attidentity` | 10 | `''`: no identity column |
| `pg_class.relispartition` | 10 | `false`: no declarative partition |
| `pg_attribute.attgenerated` | 12 | `''`: no generated column (#1146) |

A migration plan still needs 11 (`_require_pg_plan_floor`): the read alone was lowered, not what the
planner writes. Pinned with mock servers that refuse a statement naming a column their version lacks,
as a real one does. No database.

julia --project=test/integration test/unit/test_pg_server_versions.jl
"""

using Test
using PormG
using PormG: Migrations, Models
import PormG.ConnectionPool: fetch
using DataFrames
using JSON
using Logging

# A PostgreSQL server at `server_version_num` `v`. It answers the version probe, records every other
# statement, and — like the server — refuses one that names a catalog column its version does not have
# (a reference `alias.column`, not the word: the statements' own SQL comments mention the columns).
# The schema dump answers one table, `driver`, built the way that server builds it: its key is an
# identity column where identity columns exist, and a `serial` (`DEFAULT nextval(…)`) below 10. So
# what the reader makes of the key depends on the fragment the version chose, not on the mock.
struct PgAt1162 <: PormG.PormGPostgres
  v::Int
  sql::Vector{String}
  probes::Base.RefValue{Int}   # how many times the version was asked
end
PgAt1162(v::Int) = PgAt1162(v, String[], Ref(0))
fetch(m::PgAt1162, sql::String; kwargs...) = _pg1162_answer(m, sql)
fetch(m::PgAt1162, sql::String, ::AbstractVector; kwargs...) = _pg1162_answer(m, sql)

const PG1162_SINCE = (indnkeyatts = 110000, attidentity = 100000, relispartition = 100000, attgenerated = 120000)
_names_column(sql, col) = occursin(Regex("\\b[a-z]+\\.$(col)\\b"), sql)

function _pg1162_answer(m::PgAt1162, sql::String)
  occursin("server_version_num", sql) && (m.probes[] += 1; return DataFrame(v = [m.v]))
  push!(m.sql, sql)
  for (col, since) in pairs(PG1162_SINCE)
    m.v < since && _names_column(sql, col) && error("column $(col) does not exist")
  end
  occursin("json_build_object", sql) && occursin("'identity'", sql) || return DataFrame()
  identity = occursin("'identity', a.attidentity::text", sql)
  identity || occursin("'identity', ''::text", sql) || error("unrecognised identity fragment")
  col(name, type; default = nothing, identity = "") = Dict{String, Any}(
    "name" => name, "type" => type, "notnull" => true, "default" => default, "comment" => nothing,
    "identity" => identity, "generated" => "", "unique" => false,
    "non_negative_check" => false, "byte_limit" => nothing)
  key = identity ? col("driverid", "bigint"; identity = "d") :
                   col("driverid", "bigint"; default = "nextval('driver_driverid_seq'::regclass)")
  cols = [key, col("surname", "character varying(100)")]
  return DataFrame(table_schema = ["public"], table_name = ["driver"], columns = [JSON.json(cols)],
                   primary_keys = [JSON.json(["driverid"])], foreign_keys = [missing], indexes = [missing])
end

_pg1162_err(f) = try f(); nothing catch e; e end
_pg1162_plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# Every PostgreSQL statement schema introspection builds, on one server.
function _pg1162_read_all(m::PgAt1162)
  with_logger(NullLogger()) do
    live = Migrations.read_live_schema(m)
    models = Migrations.convert_schema_to_models(PgAt1162(m.v))   # `inspectdb`'s form
    Migrations.read_live_views(m)
    Migrations._get_live_table_names(m)
    Migrations._pg_invalid_indexes(m)
    return live, models
  end
end

const PG1162_VERSIONS = (90600, 100000, 110000, 120000, 130000)

@testset "PostgreSQL server versions below 11 (#1162)" begin
  # ─────────────────────────────────────────────────────────────────────────────
  # Introspection builds from 9.6, naming each catalog column only where it exists
  # Every reader — the schema dump, the composite-index and CHECK readers, the views read, status()'s
  # table list and check()'s invalid-index probe — runs on each mock server; one naming a column the
  # server lacks raises, as PostgreSQL does. At and above a column's version the statement names it
  # (`i.indnkeyatts`, `a.attidentity`, `c.relispartition`, `a.attgenerated`); below it, the stand-in.
  # Mutation gate: lower any `since` in `_PG_CATALOG_COLUMNS` and that column reaches an older mock,
  # which raises; raise one and the "names it from its version" assertion fails.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "every reader builds on 9.6, 10, 11, 12 and 13; a column appears from its version" begin
    for v in PG1162_VERSIONS
      @testset "server_version_num $v" begin
        m = PgAt1162(v)
        e = _pg1162_err(() -> _pg1162_read_all(m))
        @test e === nothing
        sql = join(m.sql, "\n")
        # One question per reader call: `read_live_schema` asks once for its three statements.
        r = PgAt1162(v)
        with_logger(NullLogger()) do
          Migrations.read_live_schema(r)
        end
        @test r.probes[] == 1 && length(r.sql) == 3
        for (col, since) in pairs(PG1162_SINCE)
          @test _names_column(sql, col) == (v >= since)
        end
        # The stand-ins, where the columns are absent.
        v < 110000 && @test occursin("ON k.ord <= i.indnatts", sql) && occursin("(i.indnatts <> i.indnatts) AS has_include", sql)
        v < 100000 && @test occursin("'identity', ''::text", sql) && occursin("AND NOT false", sql)
        v < 120000 && @test occursin("'generated', ''::text", sql)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The absent features read as absent
  # Below 10 there is no identity column: the mock's key is a `serial`, the statement asked `''` for
  # its identity, and the reader takes it as no identity — an `IDField` whose sequence default is
  # PostgreSQL's, not an identity. From 10 the same table reads as BY DEFAULT identity. Mutation gate:
  # the stand-in made `'d'` reads every 9.6 key as an identity column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an identity column is read from 10; below it the key reads as not an identity" begin
    for v in PG1162_VERSIONS
      live, models = _pg1162_read_all(PgAt1162(v))
      key = only(live).columns["driverid"]
      @test (key.identity !== nothing) == (v >= 100000)
      @test only(models).fields["driverid"] isa Models.sIDField
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # From 11, the statements are the ones the 11 floor built
  # 12 and 13 name every column, so their statements are the same text; 11 differs from them only in
  # `attgenerated`, the #1146 gate. (The branch was also diffed byte for byte against the statements
  # `main` built before #1162, at 11, 12 and 16.) Mutation gate: a stand-in leaking above its version
  # changes the 12 text.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the statements at 11, 12 and 13 are the ones every column version builds" begin
    texts = Dict(v => (m = PgAt1162(v); _pg1162_read_all(m); m.sql) for v in (110000, 120000, 130000))
    @test texts[120000] == texts[130000]
    @test length(texts[110000]) == length(texts[120000])
    @test [replace(s, "'generated', ''::text" => "'generated', a.attgenerated::text") for s in texts[110000]] == texts[120000]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The floors, by name: introspection 9.6, a plan 11
  # Below 9.6 the requirement is named before any schema statement runs (the server version reads as
  # "9.5"). A plan — makemigrations, migrate's precondition read, check's :schema_drift — needs 11, as
  # it did before #1162 lowered the read: the DDL the planner writes (identity columns, INCLUDE) is not
  # checked below 11. Mutation gate: delete any of the three `_require_pg_plan_floor` calls and its
  # case reads the schema on 10 instead of refusing.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "9.5 is refused by name, before the schema query" begin
    m = PgAt1162(90524)
    e = _pg1162_err(() -> Migrations.read_live_schema(m))
    @test e isa PormG.BackendCapabilityError
    msg = _pg1162_plain(e)
    @test occursin("needs PostgreSQL 9.6 or newer", msg) && occursin("this server is 9.5 (server_version_num 90524)", msg)
    @test occursin("Queries and writes are not affected", msg)
    @test isempty(m.sql)
    @test Migrations._pg_version_text(90600) == "9.6" && Migrations._pg_version_text(100022) == "10" &&
          Migrations._pg_version_text(130004) == "13"
  end

  @testset "a plan needs PostgreSQL 11: makemigrations, migrate's read and check's :schema_drift" begin
    for v in (90600, 100000)
      e = _pg1162_err(() -> Migrations._require_pg_plan_floor(PgAt1162(v)))
      @test e isa PormG.BackendCapabilityError
      msg = _pg1162_plain(e)
      @test occursin("needs PostgreSQL 11 or newer", msg) &&
            occursin("this server is $(Migrations._pg_version_text(v)) (server_version_num $v)", msg)
      @test occursin("needs 9.6", msg)
    end
    @test Migrations._require_pg_plan_floor(PgAt1162(110000)) === nothing
    @test Migrations._require_pg_plan_floor(nothing) === nothing   # every other backend

    dir = mktempdir()
    try
      cd(dir) do
        folder = "db1162"
        mkpath(folder)
        models_path = joinpath(dir, folder, "models.jl")
        write(models_path, "module models\nimport PormG.Models\n" *
                           "Driver = Models.Model(\n    driverid = Models.IDField(),\n" *
                           "    surname = Models.CharField(max_length = 100)\n)\nend\n")
        function settings_for(conn)
          s = PormG.Configuration.Settings(connections = conn, db_def_folder = folder)
          s.change_db = true
          return s
        end
        # makemigrations on 10 refuses before reading the schema, and writes nothing.
        m = PgAt1162(100000)
        e = _pg1162_err(() -> with_logger(NullLogger()) do
          Migrations.makemigrations(m, settings_for(m); path = models_path, interactive = false)
        end)
        @test e isa PormG.BackendCapabilityError && occursin("needs PostgreSQL 11", _pg1162_plain(e))
        @test isempty(m.sql)
        @test !isfile(joinpath(folder, "migrations", "pending_migrations.jl"))
        # migrate's precondition read is a plan's read too.
        m = PgAt1162(100000)
        e = _pg1162_err(() -> Migrations._schema_precondition_drift(m, settings_for(m), Dict("driver" => "x")))
        @test e isa PormG.BackendCapabilityError && occursin("needs PostgreSQL 11", _pg1162_plain(e))
        @test isempty(m.sql)
        # check: the plan-building class is refused on 10, the reading classes answer on 9.6.
        m = PgAt1162(100000)
        e = _pg1162_err(() -> Migrations.check(m, settings_for(m); kinds = [:schema_drift], models_file = models_path))
        @test e isa PormG.BackendCapabilityError && occursin("needs PostgreSQL 11", _pg1162_plain(e))
        @test isempty(m.sql)
        m = PgAt1162(90600)
        result = with_logger(NullLogger()) do
          Migrations.check(m, settings_for(m); kinds = [:expression_default, :invalid_index])
        end
        @test isempty(result.findings)
        @test !isempty(m.sql)
      end
    finally
      rm(dir; recursive = true, force = true)
    end
  end
end
