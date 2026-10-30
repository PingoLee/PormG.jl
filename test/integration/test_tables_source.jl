"""
A query as a Tables.jl source (#1344 phase 1): `DataFrame(query)` reads the frame it read before.

Until #1344, `query |> DataFrame` went through a PormG method on `DataFrames.DataFrame`. Phase 1 deletes it
and makes the query a Tables.jl source, so the generic `DataFrame(table)` constructor reads it, as do
`CSV.write` and any other sink. Consuming code has many `|> DataFrame` calls, so the bar is identical
output, not similar output: the same column names, the same element types (a `Date` and not SQLite's
text, #564/#582) and the same values.

THE ORACLE IS A RECORDING, NOT THE CODE UNDER TEST. `fixtures/tables_source_expected.jl` was written by
this file on the commit BEFORE the change, on every engine and on both PostgreSQL drivers, with
`PORMG_TSRC_RECORD=1`. After the change the file must reproduce it byte for byte. A red run is a
difference in what a user's frame holds, to be read row by row; it is never a reason to re-record. The
same rule as the #1113 matrix (`test_expression_kind_matrix.jl`).

The queries order by key and never by text: PostgreSQL's collation and SQLite's BINARY sort text
differently. Each covers a path the #564 parser table treats differently: plain columns, the wildcard
projection (which registers both a field's name and its `db_column`), joined columns, expression aliases,
an aggregate, a DECIMAL, an INTERVAL (#581), and an empty result (the column set with no rows).

Run (each engine, and both PostgreSQL drivers):
  julia -t auto --project=test/integration test/integration/test_tables_source.jl
  PORMG_POSTGRES_DRIVER=Postgres julia -t auto --project=test/integration test/integration/test_tables_source.jl
  PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_tables_source.jl
  PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_tables_source.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# The fixture key: the engine, and on PostgreSQL the driver too. The two drivers decode values themselves
# (Postgres.jl reads a one-unit INTERVAL as a bare `Second`, #581), so each records its own frame. Read off
# the pool's type, as `test_value_repr_property.jl` does: `postgres_driver:` in `connection.yml` takes
# precedence over the environment variable.
function _tsrc_backend_key()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    key = engine_key()
    key === :postgres || return string(key)
    return pool isa PormG.ConnectionPool.PostgresConnectionPool{:postgres} ? "postgres_postgresjl" : "postgres_libpq"
end

const _TSRC_QUERIES = [
    # Plain columns, one of each temporal kind. `date` is a DATE, `time` a TIME, `start_at` a TIMESTAMP.
    "race_columns" => () -> M.Race.objects.filter("raceid__@lte" => 3).
        values("raceid", "year", "name", "date", "time", "start_at").order_by("raceid"),
    # The wildcard: no `values`, so every field of the model, recorded under its name and `db_column`.
    "driver_wildcard" => () -> M.Driver.objects.filter("driverid__@lte" => 3).order_by("driverid"),
    # Joined columns: a date across a foreign key, a FLOAT, a nullable INTERVAL.
    "result_joined" => () -> M.Result.objects.filter("raceid" => 18).
        values("resultid", "driverid__surname", "raceid__date", "points", "fastestlaptime", "fastestlapspeed").
        order_by("resultid").limit(4),
    # Expression aliases over the temporal columns, and an integer expression.
    "race_aliases" => () -> M.Race.objects.filter("raceid__@lte" => 3).
        values("raceid", "d" => F("date"), "t" => F("time"), "s" => F("start_at"), "next_year" => F("year") + 1).
        order_by("raceid"),
    # An aggregate: a count, a sum of a FLOAT, the latest DATE of a group.
    "result_aggregate" => () -> M.Result.objects.filter("raceid__year" => 2009).
        values("driverid", "n" => Count("resultid"), "total" => Sum("points"), "last_race" => Max("raceid__date")).
        order_by("driverid").limit(4),
    # A DECIMAL column.
    "constructor_results_decimal" => () -> M.Constructor_results.objects.filter("raceid" => 18).
        values("constructorresultsid", "points").order_by("constructorresultsid").limit(3),
    # INTERVALs (#581): a lap time, and a whole-second pit stop Postgres.jl decodes as a bare `Second`.
    "lap_interval" => () -> M.Lap_times.objects.filter("raceid" => 1, "driverid" => 1, "lap__@lte" => 3).
        values("lap", "time", "milliseconds").order_by("lap"),
    "pit_interval" => () -> M.Pit_stops.objects.filter("raceid" => 879, "driverid" => 4).
        values("stop", "time", "duration").order_by("stop"),
    # No rows: the frame still has its columns, with the types the engine reports for an empty result.
    "race_empty" => () -> M.Race.objects.filter("raceid" => -1).values("raceid", "date", "time", "start_at"),
]

# One line per column: its name, its element type, and every value. `repr` keeps a `Date` and the string
# "2009-03-29" apart, and an `Int32` and an `Int64`.
function _tsrc_snapshot(df::DataFrame)
    io = IOBuffer()
    println(io, "rows=", DataFrames.nrow(df))
    for name in names(df)
        col = df[!, name]
        println(io, name, " :: ", eltype(col), " = ", repr(collect(col)))
    end
    return String(take!(io))
end

const _TSRC_FIXTURE = joinpath(@__DIR__, "fixtures", "tables_source_expected.jl")

if get(ENV, "PORMG_TSRC_RECORD", "") == "1"
    backend = _tsrc_backend_key()
    recorded = isfile(_TSRC_FIXTURE) ? copy(include(_TSRC_FIXTURE)) : Dict{String,String}()
    for (label, build) in _TSRC_QUERIES
        recorded["$(backend)/$(label)"] = _tsrc_snapshot(build() |> DataFrame)
    end
    mkpath(dirname(_TSRC_FIXTURE))
    open(_TSRC_FIXTURE, "w") do io
        println(io, "# GENERATED by test/integration/test_tables_source.jl with PORMG_TSRC_RECORD=1 — do not edit by hand.")
        println(io, "# Recorded BEFORE #1344 phase 1, against PormG's own `DataFrames.DataFrame(::SQLObjectHandler)`.")
        println(io, "Dict{String,String}(")
        for key in sort(collect(keys(recorded)))
            println(io, "    ", repr(key), " => ", repr(recorded[key]), ",")
        end
        println(io, ")")
    end
    @info "test_tables_source: recorded $(length(_TSRC_QUERIES)) frames for $(backend)" fixture = _TSRC_FIXTURE
end

@testset "A query is a Tables.jl source: DataFrame(query) reads the recorded frame (#1344)" begin
    # Each testset: `DataFrame(query)` on the live engine, against the frame the same query read
    # before #1344, when it went through PormG's own `DataFrame` method. Expected: the same column
    # names, element types and values, the empty result included. Why it matters: `|> DataFrame` is
    # the most-used way to read a query, and nothing else checks what its frame holds on every engine.
    expected = include(_TSRC_FIXTURE)
    backend = _tsrc_backend_key()
    for (label, build) in _TSRC_QUERIES
        @testset "$(label) on $(backend)" begin
            key = "$(backend)/$(label)"
            @test haskey(expected, key)   # a backend with no recording fails here, never borrows one
            haskey(expected, key) && @test _tsrc_snapshot(build() |> DataFrame) == expected[key]
        end
    end
end
