if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import PormG.QueryBuilder: Sum, Count, Avg, Max

# ─────────────────────────────────────────────────────────────────────────────
# `show_query = :struct` read back on the engine at hand (#1632)
#
# The unit file (`test/unit/test_show_query_struct.jl`) proves the round trip on SQLite `:memory:`.
# The types the struct declares come from the value-representation table's slot 4 (`julia_type`),
# which states one cell per backend, and only a real driver can say whether PostgreSQL's (or MySQL's)
# cells are what it delivers. So the same round trip runs here, on the seeded F1 fixture: the text is
# evaluated in a fresh module holding only `using PormG`, and `list(T)` must read the same rows as
# `list(:dict)`. On `db_2` it runs once per PostgreSQL driver (LibPQ, and Postgres.jl with
# `PORMG_POSTGRES_DRIVER=Postgres`), since the two decode results in separate extensions.
# ─────────────────────────────────────────────────────────────────────────────

function _sqs_it_eval(text::String)
    m = Module(gensym(:SqsIt1632))
    Core.eval(m, :(using PormG))
    include_string(m, text)
    name = match(r"^struct (\S+)$"m, text)
    @assert name !== nothing
    return Base.invokelatest(getglobal, m, Symbol(name[1]))
end
_sqs_it_same(a, b) = (a === nothing || a === missing) ? (b === nothing || b === missing) : a == b

const _SQS_IT_MATRIX = [
    # A wildcard over a model holding an integer, text, a date, a time and a timestamp.
    "wildcard" => () -> M.Race.objects.filter("year" => 2008).order_by("round"),
    # Joined columns, a float, a nullable integer and a duration.
    "joined and nullable" => () -> M.Result.objects.
        filter("raceid__year" => 2008, "driverid__driverref" => "hamilton").
        values("resultid", "surname" => "driverid__surname", "race" => "raceid__name",
               "date" => "raceid__date", "points", "position", "fastestlaptime").
        order_by("resultid"),
    # An explicit LEFT join (#1367) whose ON predicate keeps only Hamilton on the driver side, so every
    # other result of the race reads a NULL surname: the `Union` is exercised, not only written.
    "explicit LEFT join" => () -> M.Result.objects.on("driverid", "driverref" => "hamilton"; join_type = "LEFT").
        filter("raceid__year" => 2008, "raceid__round" => 1).
        values("resultid", "surname" => "driverid__surname").order_by("resultid"),
    # A `DecimalField`: a `Decimal` on every engine (a driver's `numeric`, SQLite's exact parser).
    "decimal" => () -> M.Constructor_results.objects.filter("raceid__year" => 2008).
        values("constructorresultsid", "points", "team" => "constructorid__name").order_by("constructorresultsid"),
    # Aggregates: a float sum, a count, an integer mean (a float on every engine) and a duration max.
    "computed" => () -> M.Result.objects.filter("raceid__year" => 2008).
        values("driverid", "pts" => Sum("points"), "n" => Count("resultid"), "grid" => Avg("grid"),
               "best" => Max("fastestlaptime")).
        order_by("driverid"),
    # An aggregate over no rows: SUM is NULL, COUNT is 0.
    "aggregate over no rows" => () -> M.Result.objects.filter("raceid__year" => 1800).
        values("pts" => Sum("points"), "n" => Count("resultid")),
]

# Expected: for every query, `list(T)` with `T` evaluated from the `:struct` text returns as many rows
# as `list(:dict)` (and at least one), each field equal to its column, NULL as `nothing`. It matters
# because PostgreSQL's driver hands back other widths and types than SQLite (an `Int32` integer, a
# `numeric` average, a typed interval): a `julia_type` cell that names the wrong type fails here, and
# nowhere else in the suite.
@testset "show_query = :struct round trip on the engine at hand (#1632)" begin
    @testset "$(name)" for (name, mk) in _SQS_IT_MATRIX
        text = mk().list(show_query = :struct)
        T = _sqs_it_eval(text)
        typed = Base.invokelatest(() -> mk().list(T))
        rows = mk().list(:dict)
        @test typed isa Vector{T}
        @test length(typed) == length(rows) > 0
        for (t, r) in zip(typed, rows), f in fieldnames(T)
            @test _sqs_it_same(getfield(t, f), r[f])
        end
        # No `# TODO` for an F1 query: every column here has a kind and a type on every engine.
        @test !occursin("# TODO", text)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The kinds F1 has no column for: boolean, UUID and JSON (#1634)
#
# The F1 models hold no boolean, UUID or JSON column, so the matrix above never reads one back. This
# file's own models do: a car (an F1 entry's flags, its token and its telemetry) and the laps that
# reference it. Both tables are made with `ensure_table!` on this file's own configuration key over the
# suite's pool, and dropped before and after (child first). The laps read the car's columns through an
# inner join and through an explicit LEFT join that keeps only one car, so the non-null `classified`
# and `token` read NULL on the other cars' laps.
# ─────────────────────────────────────────────────────────────────────────────

module Sqs1634Models
import PormG.Models
Car = Models.Model("sqs1634_car",
  id = Models.IDField(),
  ref = Models.CharField(max_length = 32),
  classified = Models.BooleanField(),
  pitted = Models.BooleanField(null = true),
  token = Models.UUIDField(),
  telemetry = Models.JSONField(null = true))
Lap = Models.Model("sqs1634_lap",
  id = Models.IDField(),
  lap = Models.IntegerField(),
  car = Models.ForeignKey(Car, pk_field = "id", on_delete = "CASCADE", related_name = "laps"))
end

const _SQS1634_KEY = "sqs1634"
const _SQS1634_COLUMNS = ("classified" => "car__classified", "pitted" => "car__pitted",
                          "token" => "car__token", "telemetry" => "car__telemetry")

const _SQS1634_MATRIX = [
    # SELECT every column of sqs1634_car ORDER BY id.
    "wildcard" => () -> Sqs1634Models.Car.objects.order_by("id"),
    # SELECT id, pitted, token, telemetry FROM sqs1634_car ORDER BY id.
    "values subset" => () -> Sqs1634Models.Car.objects.values("id", "pitted", "token", "telemetry").order_by("id"),
    # SELECT lap.id, car.classified, … FROM sqs1634_lap INNER JOIN sqs1634_car ON … ORDER BY lap.id.
    "inner join" => () -> Sqs1634Models.Lap.objects.values("id", _SQS1634_COLUMNS...).order_by("id"),
    # … LEFT JOIN sqs1634_car ON lap.car = car.id AND car.ref = 'mclaren': NULL on the other laps.
    "explicit LEFT join" => () -> Sqs1634Models.Lap.objects.on("car", "ref" => "mclaren"; join_type = "LEFT").
        values("id", _SQS1634_COLUMNS...).order_by("id"),
]

# The type each of the four columns declares, NULL aside, and whether the query can read it NULL: a
# `null = true` field always, the two non-null ones only on the outer side of the LEFT join.
_sqs1634_type(col::Symbol) = col in (:classified, :pitted) ? Bool : String
_sqs1634_nullable(name::String, col::Symbol) = col in (:pitted, :telemetry) || name == "explicit LEFT join"

# What: for each query, the `:struct` text names `Bool` for both boolean columns and `String` for the
#   UUID and the JSON column, `Union{Nothing, …}` exactly where the column can be NULL, and `list(T)`
#   reads the same rows as `list(:dict)`, a NULL as `nothing`. The rows hold a `false`, a NULL
#   `pitted`, a NULL `telemetry`, and (through the LEFT join) a NULL `classified` and `token`.
# SQL: the four SELECTs above, over `sqs1634_car` and `sqs1634_lap`.
# Why: each engine stores these kinds its own way (PostgreSQL `boolean`/`uuid`/`jsonb`, SQLite an
#   integer and text, MySQL `TINYINT(1)`/`CHAR(36)`/`JSON`), and `julia_type` states one cell per
#   engine. Only a read through the real driver proves the cell is the type it delivers: a wrong cell
#   compiles and then fails the first row of `list(T)`.
@testset "show_query = :struct over boolean, UUID and JSON columns on $(PORMG_DB_FOLDER) (#1634)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.config[_SQS1634_KEY] = PormG.Configuration.Settings(connections = pool, change_data = true,
                                                              change_db = true, db_def_folder = _SQS1634_KEY)
    Base.invokelatest(PormG.Models.set_models, Sqs1634Models, _SQS1634_KEY)
    K = Sqs1634Models
    drop_scratch_tables!(pool, "sqs1634_lap", "sqs1634_car")
    try
        @test PormG.Migrations.ensure_table!(K.Car, _SQS1634_KEY) === :created
        @test PormG.Migrations.ensure_table!(K.Lap, _SQS1634_KEY) === :created
        cars = [
            ("mclaren",  true,  true,    "0b1f6d2e-5c3a-4e8f-9a7b-1c2d3e4f5a6b", Dict("lap" => 12, "tyres" => Dict("compound" => "soft"))),
            ("ferrari",  false, nothing, "7e8f9a0b-1c2d-4e3f-8a5b-6c7d8e9f0a1b", nothing),
            ("williams", true,  false,   "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f", Dict("lap" => 3, "drs" => true)),
        ]
        ids = Int[]
        for (ref, classified, pitted, token, telemetry) in cars
            row = K.Car.objects.create("ref" => ref, "classified" => classified, "pitted" => pitted,
                                       "token" => token, "telemetry" => telemetry)
            push!(ids, Int(row[:id]))
        end
        for (lap, i) in ((1, 1), (1, 2), (2, 1), (1, 3), (2, 3))
            K.Lap.objects.create("lap" => lap, "car" => ids[i])
        end

        @testset "$(name)" for (name, mk) in _SQS1634_MATRIX
            text = mk().list(show_query = :struct)
            rows = mk().list(:dict)
            T = _sqs_it_eval(text)
            for col in (:classified, :pitted, :token, :telemetry)
                col in fieldnames(T) || continue
                F = fieldtype(T, col)
                @test Base.nonnothingtype(F) === _sqs1634_type(col)
                @test (F !== Base.nonnothingtype(F)) == _sqs1634_nullable(name, col)
            end
            typed = Base.invokelatest(() -> mk().list(T))
            @test typed isa Vector{T}
            @test length(typed) == length(rows) > 0
            for (t, r) in zip(typed, rows), f in fieldnames(T)
                @test _sqs_it_same(getfield(t, f), r[f])
            end
            @test !occursin("# TODO", text)
        end

        # Guard the guard: the rows hold the values the header names, so the `Union` arms and a `false`
        # are read, not only written.
        left = K.Lap.objects.on("car", "ref" => "mclaren"; join_type = "LEFT").
            values("id", _SQS1634_COLUMNS...).order_by("id").list(:dict)
        @test count(r -> r[:token] === nothing || r[:token] === missing, left) == 3
        plain = K.Car.objects.values("classified", "pitted", "telemetry").order_by("id").list(:dict)
        @test any(r -> r[:classified] == false, plain)
        @test any(r -> r[:pitted] === nothing || r[:pitted] === missing, plain)
        @test any(r -> r[:telemetry] === nothing || r[:telemetry] === missing, plain)
    finally
        drop_scratch_tables!(pool, "sqs1634_lap", "sqs1634_car")
        delete!(PormG.config, _SQS1634_KEY)
    end
end
