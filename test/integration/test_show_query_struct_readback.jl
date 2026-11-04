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
