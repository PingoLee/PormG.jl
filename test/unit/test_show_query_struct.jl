# =============================================================================
# `show_query = :struct` — the struct a typed read needs, as source text (#1632)
#
# Every read terminal can render, instead of SQL, the struct `list(T)` accepts for that query: the
# `using` lines its types need, a header naming the engine, and one field per projected column, typed
# from the value-representation table's slot 4 (`julia_type`) and nullable unless the build proves the
# column never NULL. PormG returns TEXT and never evaluates it; the caller pastes it.
#
# Three things are pinned here:
#   (a) the round trip: the text, evaluated in a fresh module holding only `using PormG`, defines a type
#       `list(T)` reads the same rows into as `list()` returns — for a matrix of F1-shaped queries;
#   (b) the text itself, per matrix query, against a reviewed fixture, so a change in what users paste
#       is a diff to read (`PORMG_SQS_RECORD=1` rewrites it; read the diff, never regenerate to pass);
#   (c) the edges: a column PormG cannot type is a `# TODO` line, never `Any`; a keyword alias is
#       `var"…"`; a terminal that returns no rows refuses the mode.
#
# Hermetic: an in-memory SQLite database with an inline model module. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_show_query_struct.jl

using Test
using Dates
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Dialect, Models, QueryBuildError
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
import PormG.QueryBuilder: Sum, Count, Cast, Coalesce

const _SQS_KEY = normpath(joinpath(@__DIR__, "pormg1632_struct"))
const _SQS_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_SQS_KEY] = Configuration.Settings(
    connections = _SQS_POOL, change_data = true, db_def_folder = _SQS_KEY)

# F1-shaped. `Result.constructorid` is a nullable ForeignKey, so a path through it is a LEFT join; the
# driver carries one column of each kind the table types (a date, two datetimes, a decimal, a boolean, a
# JSON document) and several nullable ones.
PormG.@models_module Struct1632 "pormg1632_struct" begin
    Constructor = Models.Model(
        constructorid = Models.IDField(),
        name          = Models.CharField(max_length = 40))
    Driver = Models.Model(
        driverid    = Models.IDField(),
        surname     = Models.CharField(max_length = 40),
        code        = Models.CharField(max_length = 3, null = true),
        number      = Models.IntegerField(null = true),
        dob         = Models.DateField(),
        active      = Models.BooleanField(),
        salary      = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
        signed_at   = Models.DateTimeField(null = true),
        retired_at  = Models.DateTimeField(type = "TIMESTAMP", null = true),
        profile     = Models.JSONField(null = true))
    Result = Models.Model(
        resultid      = Models.IDField(),
        driverid      = Models.ForeignKey(Driver, on_delete = "CASCADE"),
        constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", null = true),
        points        = Models.FloatField(),
        position      = Models.IntegerField(null = true))
end
import .Struct1632 as SQS1632   # not `SQ`: `test_redact_secret.jl` declares that in the shared `Main`

for m in (SQS1632.Constructor, SQS1632.Driver, SQS1632.Result)
    fetch(_SQS_POOL, Dialect.create_table(_SQS_POOL, m))
end
SQS1632.Constructor.objects.create("constructorid" => 1, "name" => "McLaren")
SQS1632.Driver.objects.create("driverid" => 1, "surname" => "Senna", "code" => "SEN", "number" => 12,
    "dob" => Date(1960, 3, 21), "active" => true, "salary" => "1000.50",
    "signed_at" => DateTime(1988, 1, 1, 9, 30), "retired_at" => nothing, "profile" => Dict("titles" => 3))
SQS1632.Driver.objects.create("driverid" => 2, "surname" => "Prost", "code" => nothing, "number" => nothing,
    "dob" => Date(1955, 2, 24), "active" => false, "salary" => nothing,
    "signed_at" => nothing, "retired_at" => DateTime(1993, 12, 1), "profile" => nothing)
SQS1632.Result.objects.create("resultid" => 1, "driverid" => 1, "constructorid" => 1, "points" => 9.0, "position" => 1)
SQS1632.Result.objects.create("resultid" => 2, "driverid" => 2, "constructorid" => 1, "points" => 6.0, "position" => 2)
SQS1632.Result.objects.create("resultid" => 3, "driverid" => 1, "constructorid" => nothing, "points" => 0.0, "position" => nothing)

# A typed read's own projection: `list(T, show_query = :struct)` writes the struct the query needs for
# `fieldnames(T)`, which shows where `T`'s declarations differ from what the read accepts (`Int32` here).
struct SqsDeclaredRow
    resultid::Int32
    points::Float64
end

# An offline PostgreSQL key (#1442): queries render, nothing runs. For the PostgreSQL-only kinds.
PormG.Configuration.register_offline("sqs1632_pg"; adapter = :postgres)
const _SQS_PG_RESULT = let mod = Module(:Sqs1632Pg)
    Core.eval(mod, :(import PormG.Models))
    Core.eval(mod, :(Constructor = Models.Model("sqs1632_constructor", constructorid = Models.IDField(),
                                                laps = Models.ArrayField(Models.IntegerField()))))
    Core.eval(mod, :(Result = Models.Model("sqs1632_result", resultid = Models.IDField(),
                                           tags = Models.ArrayField(Models.IntegerField()),
                                           constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE"))))
    Base.invokelatest(PormG.Models.set_models, mod, "sqs1632_pg")
    Base.invokelatest(getfield, mod, :Result)
end

# The matrix: each entry builds a FRESH handler, since a test runs the query three times.
function _sqs_cte_query()
    q = SQS1632.Result.objects
    q.with("tot" => SQS1632.Result.objects.values("driverid", "n" => Count("resultid")),
           join_field = "driverid" => "driverid")
    return q.values("resultid", "races" => PormG.CTE("tot", "n")).order_by("resultid")
end
const _SQS_MATRIX = [
    "wildcard" =>
        () -> SQS1632.Driver.objects.order_by("driverid"),
    "plain columns" =>
        () -> SQS1632.Driver.objects.values("driverid", "surname", "code", "number", "dob", "active", "salary",
                                       "signed_at", "retired_at").order_by("driverid"),
    "joined through a nullable ForeignKey" =>
        () -> SQS1632.Result.objects.values("resultid", "surname" => "driverid__surname",
                                       "team" => "constructorid__name").order_by("resultid"),
    # The ON predicate keeps only Senna's row on the driver side, so Prost's result reads a NULL surname
    # through the LEFT join: the round trip fails here if the `Union` is missing.
    "explicit LEFT join" =>
        () -> SQS1632.Result.objects.on("driverid", "surname" => "Senna"; join_type = "LEFT").
                 values("resultid", "surname" => "driverid__surname").order_by("resultid"),
    "computed" =>
        () -> SQS1632.Result.objects.values("driverid", "pts" => Sum("points"), "n" => Count("resultid"),
                                       "pos" => Cast("position", "text"),
                                       "pos0" => Coalesce("position", 0)).order_by("driverid"),
    "aggregate over no rows" =>
        () -> SQS1632.Result.objects.filter("points__@gt" => 1000).values("pts" => Sum("points"), "n" => Count("resultid")),
    "CTE column" =>
        _sqs_cte_query,
    "typed read's own projection" =>
        () -> SQS1632.Result.objects.order_by("resultid"),
]
_sqs_text(name, mk) = name == "typed read's own projection" ?
    mk().list(SqsDeclaredRow, show_query = :struct) : mk().list(show_query = :struct)

# Evaluate the text in a fresh module that has nothing but `using PormG`: the `using` lines the text
# writes must be all it needs. Returns the struct type it defines.
function _sqs_eval(text::String)
    m = Module(gensym(:Sqs1632))
    Core.eval(m, :(using PormG))
    include_string(m, text)
    name = match(r"^struct (\S+)$"m, text)
    @assert name !== nothing
    return Base.invokelatest(getglobal, m, Symbol(name[1]))
end

_sqs_same(a, b) = (a === nothing || a === missing) ? (b === nothing || b === missing) : a == b

const _SQS_FIXTURE = joinpath(@__DIR__, "fixtures", "show_query_struct_expected.txt")
_sqs_section(name, text) = "### " * name * "\n" * text
function _sqs_read_fixture()
    out = Dict{String,String}()
    isfile(_SQS_FIXTURE) || return out
    body = replace(read(_SQS_FIXTURE, String), "\r\n" => "\n")   # Windows CI checks out CRLF
    for chunk in split(body, r"^### "m)[2:end]
        name, text = split(chunk, "\n"; limit = 2)
        out[String(name)] = String(text)
    end
    return out
end

if get(ENV, "PORMG_SQS_RECORD", "") == "1"
    open(_SQS_FIXTURE, "w") do io
        for (name, mk) in _SQS_MATRIX
            print(io, _sqs_section(name, _sqs_text(name, mk)))
        end
    end
    @info "show_query = :struct fixture rewritten" _SQS_FIXTURE
end

@testset "show_query = :struct (#1632)" begin

    # The round trip, per matrix query. Expected: the text evaluates in a module holding only
    # `using PormG`, and `list(T)` returns as many rows as `list()`, each field equal to the column's
    # value (NULL as `nothing`). It matters because this is the feature's whole promise: a suggestion
    # `list(T)` accepts by construction, a nullable column, a LEFT-joined one and an aggregate over no
    # rows included. A `Union` the build missed fails here on the NULL row the fixture seeds.
    @testset "round trip: $(name)" for (name, mk) in _SQS_MATRIX
        T = _sqs_eval(_sqs_text(name, mk))
        typed = Base.invokelatest(() -> mk().list(T))
        rows = name == "typed read's own projection" ?
            mk().values("resultid", "points").list(:dict) : mk().list(:dict)
        @test typed isa Vector{T}
        @test length(typed) == length(rows) > 0
        for (t, r) in zip(typed, rows), f in fieldnames(T)
            @test _sqs_same(getfield(t, f), r[f])
        end
    end

    # The emitted text, per matrix query, against the reviewed fixture. Expected: byte-equal to
    # `fixtures/show_query_struct_expected.txt` — e.g. for the nullable join,
    # `team::Union{Nothing, String}  # constructorid__name: CharField on Constructor; LEFT JOIN: …`. It
    # matters because the text is what users and agents paste: a change to a type, a comment or a
    # `using` line must arrive as a diff someone reads, not as a surprise in a pasted struct.
    @testset "the text matches the reviewed fixture" begin
        expected = _sqs_read_fixture()
        @test !isempty(expected)
        for (name, mk) in _SQS_MATRIX
            @test get(expected, name, nothing) == _sqs_text(name, mk)
        end
    end

    # What the text says, read directly, so the fixture is not the only witness. Expected: the
    # `using` lines are exactly those the types need (`Dates` for `Date`, `Decimals` for `Decimal`,
    # `TimeZones` for `ZonedDateTime`), the header names SQLite, an `IntegerField` is `Int64`, the
    # TIMESTAMP datetime is marked engine-specific (PostgreSQL reads a `DateTime`), and a typed read's
    # `Int32` declaration is answered with the `Int64` the read accepts on every engine.
    @testset "using lines, header, declarations" begin
        plain = _sqs_text("plain columns", _SQS_MATRIX[2].second)
        @test startswith(plain, "using Dates\nusing Decimals\nusing TimeZones\n\n# show_query = :struct, rendered for SQLite")
        @test occursin("\nstruct DriverRow\n", plain)
        @test occursin(r"number::Union\{Nothing, Int64\}\s+# IntegerField; null = true", plain)
        @test occursin(r"dob::Date\s+# DateField\n", plain)
        @test occursin(r"salary::Union\{Nothing, Decimal\}", plain)
        @test occursin(r"retired_at::Union\{Nothing, ZonedDateTime\}.*this is SQLite's type: another engine reads it as another", plain)
        @test !occursin(r"signed_at::.*this is SQLite's type", plain)   # a timestamptz is a ZonedDateTime everywhere
        joined = _sqs_text("joined through a nullable ForeignKey", _SQS_MATRIX[3].second)
        @test !occursin("using ", joined)                 # only `Base` types: no import line
        @test occursin(r"surname::String\s+# driverid__surname: CharField on Driver\n", joined)
        @test occursin("team::Union{Nothing, String}", joined)
        # The explicit LEFT join's matrix query really reads a NULL (Prost's result, outside the ON
        # predicate), so its round trip exercises the `Union` rather than only writing it.
        left = _SQS_MATRIX[4].second
        @test any(r -> r[:surname] === missing || r[:surname] === nothing, left().list(:dict))
        declared = _sqs_text("typed read's own projection", last(_SQS_MATRIX).second)
        @test occursin(r"resultid::Int64\s+# IDField", declared)
    end

    # A column whose type PormG cannot name, a JSON key's value (its type is the data's). Expected:
    # `# TODO k: PormG cannot name one type for this column on SQLite. Cast it …` in place of a field,
    # and no `Any` anywhere in the text. It matters because `list(T)` refuses an abstract field,
    # so an `Any` would only fail later with a worse message; a TODO line makes the read refuse the
    # column by name ("projects column(s) k that … has no field for") until the reader declares it.
    @testset "a column PormG cannot type is a # TODO line, never Any" begin
        text = SQS1632.Driver.objects.values("driverid", "k" => "profile__titles").list(show_query = :struct)
        @test occursin("    # TODO k: PormG cannot name one type for this column on SQLite. Cast it", text)
        @test !occursin("Any", text)
        @test occursin(r"driverid::Int64", text)
    end

    # A projection name that is not a Julia identifier on its own. A `values()` alias is a plain SQL
    # identifier, so that is a keyword. Expected: `var"end"::…` and `var"begin"::…`, and the struct still
    # round-trips (the field is named `end`, which `list(T)` matches). It matters because a struct that
    # does not parse is worse than none.
    @testset "a keyword alias is written var\"…\"" begin
        mk = () -> SQS1632.Result.objects.values("resultid", "end" => "position", "begin" => "points").order_by("resultid")
        text = mk().list(show_query = :struct)
        @test occursin("    var\"end\"::Union{Nothing, Int64}", text)
        @test occursin("    var\"begin\"::Float64", text)
        T = _sqs_eval(text)
        @test fieldnames(T) == (:resultid, :end, :begin)
        @test length(Base.invokelatest(() -> mk().list(T))) == 3
    end

    # The terminals that return no rows. Expected: each raises `QueryBuildError` with the message that
    # names the row terminals ("… list(), first(), last(), get(), earliest(), latest() and query_list()")
    # — `count()`, its column form, `aggregate()`, `exists()` and `delete()` — and the invalid-mode
    # message lists `:struct`. The MESSAGE is asserted, not the type alone: before this mode existed
    # `:struct` raised `QueryBuildError` as an invalid mode, so a type check passes without the feature.
    # It matters because a struct for a count would be a type nothing can read into.
    @testset "terminals that return no rows refuse :struct" begin
        rows_msg = "list(), first(), last(), get(), earliest(), latest() and query_list()"
        refusal(f) = (e = try f(); nothing catch err; err end; e isa QueryBuildError ? sprint(showerror, e) : "")
        @test occursin(rows_msg, refusal(() -> SQS1632.Result.objects.count(show_query = :struct)))
        @test occursin(rows_msg, refusal(() -> SQS1632.Result.objects.count("position", show_query = :struct)))
        @test occursin(rows_msg, refusal(() -> SQS1632.Result.objects.aggregate("t" => Sum("points"), show_query = :struct)))
        @test occursin(rows_msg, refusal(() -> SQS1632.Result.objects.exists(show_query = :struct)))
        @test occursin(rows_msg, refusal(() -> SQS1632.Result.objects.filter("resultid" => 1).delete(show_query = :struct)))
        bad = try SQS1632.Result.objects.list(show_query = :nope); nothing catch err; err end
        @test occursin(":struct", sprint(showerror, bad))
    end

    # `values("*")`, alone or beside another column. Expected: `QueryBuildError` saying a typed read
    # cannot project `values("*")`. It matters because `list(T)` refuses that projection, so a struct for
    # it would be one no typed read can use — the round trip would fail by construction.
    @testset "values(\"*\") refuses :struct, as list(T) refuses it" begin
        for q in (SQS1632.Driver.objects.values("*"), SQS1632.Result.objects.values("*", "team" => "constructorid__name"))
            e = try q.list(show_query = :struct); nothing catch err; err end
            @test e isa QueryBuildError && occursin("a typed read cannot project values(\"*\")", sprint(showerror, e))
        end
    end

    # A value inside a column, on PostgreSQL (an offline key: the text is rendered, nothing runs).
    # Expected: an array element is `Union{Nothing, Int64}` with the comment "a value inside a column;
    # NULL when it is absent", although the element field is not `null = true` — on the base table
    # (`tags__0`) and through a non-null ForeignKey's INNER join (`constructorid__laps__0`), where the
    # join alone would prove nothing NULL. It matters
    # because PostgreSQL returns NULL for an out-of-range subscript, so a bare `Int64` would refuse every
    # row with a short array. The PostgreSQL array column itself is a TODO line: its type is
    # `Vector{T}` or `Vector{Union{Missing,T}}` by row (slot 4's stated exception).
    @testset "an array element is nullable; the array is a TODO line (PostgreSQL)" begin
        text = _SQS_PG_RESULT.objects.values("resultid", "t0" => "tags__0", "tags",
                                             "l0" => "constructorid__laps__0").list(show_query = :struct)
        @test occursin(r"l0::Union\{Nothing, Int64\}\s+# constructorid__laps__0: a value inside a column", text)
        @test startswith(text, "# show_query = :struct, rendered for PostgreSQL")
        @test occursin(r"t0::Union\{Nothing, Int64\}\s+# tags__0: a value inside a column; NULL when it is absent", text)
        @test occursin("    # TODO tags: PormG cannot name one type for this column on PostgreSQL", text)
        @test occursin(r"resultid::Int64", text)
    end

    # The other read terminals reach the same arm with no case of their own. Expected: `first()`,
    # `get()` and `query_list()` return the text `list()` does for the same query. It matters because
    # the mode is a `show_query` value, which every read terminal already takes.
    @testset "every read terminal returns the same text" begin
        mk = _SQS_MATRIX[3].second
        text = mk().list(show_query = :struct)
        @test mk().first(show_query = :struct) == text
        @test PormG.QueryBuilder.query_list(mk(), show_query = :struct) == text
        @test SQS1632.Driver.objects.get("driverid" => 1, show_query = :struct) ==
              SQS1632.Driver.objects.filter("driverid" => 1).list(show_query = :struct)
    end
end
