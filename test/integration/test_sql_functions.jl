# test/integration/test_sql_functions.jl
# This test file validates SQL functions (aggregates, string, math, logic) and filter modifiers.
# Each test set explains the expected SQL and the logic being tested.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
import Decimals   # #1044: a Decimal literal operand
import TimeZones  # #955: the UTC instant behind a `start_at`, and its São Paulo wall clock

@testset "Aggregate Functions" begin
    # Logic: Test basic aggregates (Sum, Avg, Count, Max, Min).
    # Why: Core ORM functionality for data analysis.
    q = M.Result.objects
    q.values(
        "total_results" => Count("resultid"),
        "max_points"    => Max("points"),
        "min_points"    => Min("points"),
        "sum_points"    => Sum("points"),
        "avg_points"    => Avg("points")
    )
    q.filter("raceid" => 1) # Australian GP
    df = q |> DataFrame

    q |> show_query  # For debugging
    
    @test df[1, :total_results] > 0
    @test df[1, :max_points] >= 10.0
    @test df[1, :sum_points] > 0
end

@testset "Function Calls" begin
    # Logic: Test functions that require explicit function syntax (string, logic, extremes).
    # Why: These functions provide more control and clarity.
    q = M.Driver.objects
    q.values(
        "driverid",
        "forename",
        "lower_name"   => Lower("forename"),
        "upper_name"   => Upper("surname"),
        "name_len"     => Length("forename"),
        "trimmed_code" => Trim("code"),
        "ltrimmed"     => LTrim(Value("  test")),
        "rtrimmed"     => RTrim(Value("test  ")),
        "replace_val"  => Replace("nationality", "British", "UK"),
        "coalesce_val" => Coalesce(Value(nothing), "forename", Value("N/A")),
        "nullif_val"   => NullIf("forename", Value("Lewis")),
        "round_val"    => Round(Value(10.556), 3),   # #1044: a literal that fits its places
        "round_def"    => Round(Value(10.5)),
        "abs_val"      => Abs(Value(-10.5)),
        "max_val"      => Greatest("driverid", Value(100), Value(50)),
        "min_val"      => Least("driverid", Value(10))
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :lower_name] == "lewis"
    @test df[1, :upper_name] == "HAMILTON"
    @test df[1, :name_len] == 5
    @test df[1, :trimmed_code] == "HAM"
    @test df[1, :ltrimmed] == "test"
    @test df[1, :rtrimmed] == "test"
    @test df[1, :replace_val] == "UK"
    @test df[1, :coalesce_val] == "Lewis"
    @test df[1, :nullif_val] === missing || df[1, :nullif_val] === nothing
    @test Float64(df[1, :round_val]) == 10.556
    @test df[1, :round_def] == 11.0 # SQLite ROUND(10.5) is 11.0
    @test df[1, :abs_val] == 10.5
    @test df[1, :max_val] == 100
    @test df[1, :min_val] == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# LPad/RPad: string padding on a real engine (#122)
# PostgreSQL renders its own LPAD/RPAD; SQLite calls the `pormg_lpad`/`pormg_rpad` functions the
# extension registers on every connection, so this is the run that proves the registration reaches
# a pooled connection. Then the issue's statement: zero-fill an integer into a text column with one
# UPDATE, inside a transaction that is rolled back so the shared fixture keeps "HAM".
# ─────────────────────────────────────────────────────────────────────────────
struct _Lpad122Rollback <: Exception end   # top level: Julia rejects a `struct` inside `@testset`
@testset "LPad/RPad (#122)" begin
    q = M.Driver.objects
    q.filter("driverid__@in" => [1, 20])
    q.values("driverid",
             "car"  => LPad(Cast("number", "text"), 3, "0"),   # 44 → "044", 5 → "005"
             "code" => RPad("code", 5, "."),                    # "HAM" → "HAM.."
             "cut"  => LPad("surname", 3, "*"),                 # longer than 3: cut to "Ham"
             "pad"  => LPad("code", 7, "xy"))                   # a fill that repeats and is cut
    q.order_by("driverid")
    rows = q.list(:dict)
    @test [r[:car] for r in rows] == ["044", "005"]
    @test rows[1][:code] == "HAM.."
    @test rows[1][:cut] == "Ham"
    @test rows[1][:pad] == "xyxyHAM"

    # The update, rolled back by the sentinel thrown at the end of the block.
    try
        PormG.run_in_transaction(PORMG_DB_FOLDER) do
            M.Driver.objects.filter("driverid" => 1).update("code" => LPad(Cast("number", "text"), 3, "0"))
            @test only(M.Driver.objects.filter("driverid" => 1).values("code").list(:dict))[:code] == "044"
            throw(_Lpad122Rollback())
        end
    catch e
        e isa _Lpad122Rollback || rethrow()
    end
    @test only(M.Driver.objects.filter("driverid" => 1).values("code").list(:dict))[:code] == "HAM"
end

@testset "Range Filter Modifier" begin
    # Logic: Test the "__range" modifier which translates to SQL "BETWEEN".
    # Expected SQL: SELECT ... FROM ... WHERE "driverid" BETWEEN 1 AND 5
    # Why: Essential for filtering results within a specific span (dates or IDs).
    
    # Test with Vector
    q1 = M.Driver.objects.filter("driverid__@range" => [1, 5]).order_by("driverid")
    df1 = q1 |> DataFrame
    @test size(df1, 1) == 5
    @test df1[1, :driverid] == 1
    @test df1[5, :driverid] == 5

    # Test with Tuple
    q2 = M.Driver.objects.filter("driverid__@range" => (10, 15)).order_by("driverid")
    df2 = q2 |> DataFrame
    @test size(df2, 1) == 6
    @test df2[1, :driverid] == 10
end

@testset "Greatest and Least" begin
    # Logic: Test variadic functions that pick extremes from multiple columns/values.
    # Why: In Julia, Vector invariance requires special handling in the ORM's type system.
    q = M.Driver.objects
    q.values(
        "driver_id" => "driverid",
        "max_val" => Greatest("driverid", Value(100), Value(50)),
        "min_val" => Least("driverid", Value(100), Value(50))
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    @test df[1, :max_val] == 100
    @test df[1, :min_val] == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Greatest/Least skip a NULL argument on both engines (#844)
# PostgreSQL's GREATEST/LEAST ignore NULLs; SQLite rendered MAX(a, b)/MIN(a, b), which return NULL
# when any argument is NULL. Race 1000 (2018 Hungarian GP) has a `date` and no practice dates, so
# it was `missing` on SQLite and the race date on PostgreSQL. Race 1100 has every date and is the
# control: no NULL, so the answer was always the same. Both practice dates NULL gives NULL.
# The values read back as `Date` on both engines (#824).
# ─────────────────────────────────────────────────────────────────────────────
@testset "Greatest/Least skip NULL arguments (#844)" begin
    rows = M.Race.objects.filter("raceid__@in" => [1000, 1100]).values(
        "raceid",
        "g"  => Greatest("date", "fp1_date"),
        "l"  => Least("date", "fp1_date"),
        "g3" => Greatest("fp1_date", "date", "fp2_date"),
        "gn" => Greatest("fp1_date", "fp2_date")
    ).order_by("raceid").list(:dict)

    hungary, australia = rows
    # The issue's case: the NULL `fp1_date` is skipped, so both functions give the race date.
    @test isequal(hungary[:g], Date(2018, 7, 29))
    @test isequal(hungary[:l], Date(2018, 7, 29))
    # Three operands, two of them NULL, and the NULLs lead: still the race date.
    @test isequal(hungary[:g3], Date(2018, 7, 29))
    # Every argument NULL: NULL, as on PostgreSQL.
    @test ismissing(hungary[:gn])

    # The control: race 1100 has a Friday practice (31 March 2023) and a Sunday race (2 April).
    @test australia[:g] == Date(2023, 4, 2)
    @test australia[:l] == Date(2023, 3, 31)
    @test australia[:gn] == Date(2023, 3, 31)
end

# ─────────────────────────────────────────────────────────────────────────────
# A transform in a function's string operand (#843)
# `Coalesce("fp1_date", "start_at__@date")` used to crash the build ("does not have a 'how'
# property"): the string operand was wrapped so the `@date` transform was never resolved. Race 1000
# has no `fp1_date`, so Coalesce falls through to the start timestamp's date. `Mod` over `@year`
# is the numeric transform in the same seam: 2018 mod 4.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Transform in a function's string operand (#843)" begin
    row = M.Race.objects.filter("raceid" => 1000).values(
        "c" => Coalesce("fp1_date", "start_at__@date"),
        "m" => Mod("start_at__@year", 4)
    ).list(:dict) |> only
    @test row[:c] == Date(2018, 7, 29)
    @test row[:m] == 2
end

# ─────────────────────────────────────────────────────────────────────────────
# A transform in a function, in every position a function can sit (#863)
# The same `start_at__@…` operands as #843, outside `values(...)`: a filter's right-hand side, a
# Case branch, F arithmetic and a window partition each crashed the build before #863. Expected
# values come from the plain columns of race 1000 (2018 German GP: no `fp1_date`), not from the
# expressions under test.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Transform in a function, every position (#863)" begin
    plain = M.Race.objects.filter("raceid" => 1000).values("raceid", "date", "start_at").list(:dict) |> only
    start_year = year(plain[:start_at])

    # A filter's right-hand side: race date against Coalesce(fp1_date, start_at's date).
    got = M.Race.objects.filter("raceid" => 1000, "date" => Coalesce("fp1_date", "start_at__@date")).
        values("raceid").list(:dict)
    @test [r[:raceid] for r in got] == (plain[:date] == Date(plain[:start_at]) ? [1000] : Int[])
    @test !isempty(got)

    row = M.Race.objects.filter("raceid" => 1000).values(
        # A Case branch, F arithmetic and a window partition over the same transform.
        "case_m" => Case([When("raceid" => 1000, then = Mod("start_at__@year", 4))], default = -1),
        "plus" => F("raceid") + Coalesce("start_at__@year", 0),
        "rk" => Rank(over = WindowOver(partition_by = [Coalesce("start_at__@year", 0)], order_by = ["raceid"]))
    ).list(:dict) |> only
    @test row[:case_m] == mod(start_year, 4)
    @test row[:plus] == 1000 + start_year
    @test row[:rk] == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Literals that SQLite used to bind as a serialized BLOB (#721)
# A date literal, a narrow integer and a projected `Value(Date)` must behave identically on both
# engines. Before #721 a date literal was refused as a function operand (#705's stop-gap, since
# `Value` bound it as a serialized BLOB on SQLite), and the `Int16` filter bound a BLOB that matched
# no seeded (INTEGER) row. The projection
# case is parity only: SQLite.jl deserialized the BLOB back into a `Date`, so it guards the typed
# read-back, not the original bug. Expected values are computed in Julia from the plain column.
# `Date(string(x)[1:10])` absorbs the one intended difference: a function result is a `Date` on
# PostgreSQL and ISO text on SQLite.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Date and narrow-integer literals (#721)" begin
    cutoff = Date(2020, 8, 1)
    plain = M.Race.objects
    plain.filter("year" => 2020)
    plain.values("raceid", "date")
    plain.order_by("raceid")
    races = plain.list()
    @test !isempty(races)

    # Greatest over a date column and a date literal: the later of the two, per race.
    q = M.Race.objects
    q.filter("year" => 2020)
    q.values("raceid", "later" => Greatest("date", cutoff))
    q.order_by("raceid")
    got = [Date(string(r[:later])[1:10]) for r in q.list()]
    @test got == [max(Date(string(r[:date])[1:10]), cutoff) for r in races]
    # Not a vacuous comparison: the season straddles the cutoff, so both arms are taken.
    @test any(r -> Date(string(r[:date])[1:10]) < cutoff, races)
    @test any(r -> Date(string(r[:date])[1:10]) > cutoff, races)

    # A narrow-integer filter finds the same rows as the Int64 one.
    q16 = M.Race.objects
    q16.filter("year" => Int16(2020))
    q16.values("raceid")
    q16.order_by("raceid")
    @test [r[:raceid] for r in q16.list()] == [r[:raceid] for r in races]

    # A projected date literal reads back as a `Date` on both engines.
    qv = M.Race.objects
    qv.filter("raceid" => races[1][:raceid])
    qv.values("raceid", "d" => Value(cutoff))
    row = only(qv.list())
    @test row[:d] == cutoff
    @test row[:d] isa Date
end

@testset "Mathematical Functions" begin
    # Logic: Validates math operations like floor, ceil, power, and sqrt.
    # Why: For PostgreSQL, we must ensure inputs are cast to ::numeric to match function signatures.
    q = M.Driver.objects
    q.values(
        "floor_val" => Floor(Value(10.7)),
        "ceil_val"  => Ceil(Value(10.2)),
        # #1044: a `numeric` function rounds to places differently per engine, so to a whole number.
        "sqrt_val"  => Round(Sqrt(Value(16.0))),
        "power_val" => Power(Value(2), Value(3)),
        "mod_val"   => Mod(Value(10), Value(3)),
        "abs_val"   => Abs(Value(-5.5)),
        "exp_val"   => Exp(Value(1.0)),
        "ln_val"    => Round(Ln(Value(2.71828)))
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :floor_val] == 10.0
    @test df[1, :ceil_val] == 11.0
    @test df[1, :sqrt_val] == 4.0
    @test df[1, :power_val] == 8.0
    @test df[1, :mod_val] == 1.0
    @test df[1, :abs_val] == 5.5
    @test Float64(df[1, :exp_val]) ≈ ℯ atol=1e-9
    @test df[1, :ln_val] == 1.0
end

@testset "Conditional & Case Functions" begin
    # Logic: Test Case/When logic for conditional SQL expressions.
    # Why: Allows complex logic to be executed on the database side.
    q = M.Driver.objects
    q.values(
        "driverid",
        "category" => Case([
            When(("driverid__@lte" => 5), then = Value("Top 5")),
            When(("driverid__@range" => [6, 10]), then = Value("6-10"))
        ], default = Value("Other"))
    )
    q.filter("driverid__@lte" => 15)
    q.order_by("driverid")
    df = q |> DataFrame

    insp = q |> inspect_query
    # @info insp[:sql_text]
    if insp[:dialect] == :sqlite
        @test insp[:parameters] == Any[5, "Top 5", 6, 10, "6-10", "Other", 15]
    end
    
    @test df[1, :category] == "Top 5"
    @test df[6, :category] == "6-10"
    @test df[11, :category] == "Other"
end

@testset "Casting & Concatenation" begin
    # Logic: Test explicit type casting and string concatenation.
    # Why: Useful for formatting output data for reports.
    q = M.Driver.objects
    q.values(
        "full_info" => Concat([
            "forename", 
            Value(" "), 
            "surname", 
            Value(" ("), 
            Cast("driverid", "text"), 
            Value(")")
        ])
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :full_info] == "Lewis Hamilton (1)"
end

# ─────────────────────────────────────────────────────────────────────────────
# Text alias filtered by a number: the race id as a text code (#851)
# `Concat` is text on both engines. A number compared with it binds as text ("7"); SQLite used to
# bind it native, and `('' || 7) = 7` is false there — no affinity on either side — so the filter
# returned no rows where PostgreSQL returned the race. Both spellings go through the alias path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A number filter on a text alias matches on both engines (#851)" begin
    for pred in ("race_code" => 7, Q("race_code" => 7))
        q = M.Race.objects
        q.values("raceid", "name", "race_code" => Concat(["raceid", Value("")]))
        q.filter(pred)
        df = q |> DataFrame
        # Exactly the 2009 Turkish Grand Prix — raceid 7 — on both engines.
        @test nrow(df) == 1
        @test df[1, :raceid] == 7
        @test df[1, :race_code] == "7"
    end
end

@testset "Extraction & ToChar" begin
    # Logic: Test explicit Extract and ToChar functions.
    # Why: Provides more control over date/time formatting than standard modifiers.
    q = M.Driver.objects
    q.values(
        "extracted_year"  => Extract("dob", "YEAR"),
        "formatted_date" => ToChar("dob", "DD/MM/YYYY")
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :extracted_year] == 1985
    @test df[1, :formatted_date] == "07/01/1985"
end

@testset "Advanced Nesting & Combined Functions" begin
    # Logic: Test nesting multiple functions (e.g., Lower(Trim(...))).
    # Why: Ensures the QueryBuilder can recursively process function objects.
    q = M.Driver.objects
    q.values(
        "driverid",
        "nested_val" => Lower(Trim(Upper(Value("  Lewis  ")))),
        "math_nest"  => Round(Sqrt(Abs(Value(-16.0))), 0)
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :nested_val] == "lewis"
    @test df[1, :math_nest] == 4.0
end

@testset "Special Date Functions (Quarter/Quadrimester)" begin
    # Logic: Test the period transforms in both of their shapes.
    # Why: #579 split one name into two meanings. `@quarter` / `@quadrimester` extract the period
    # NUMBER (1-4, 1-3) through a single per-engine dialect function; `@yyyy_q` / `@yyyy_quad`
    # carry the year-qualified label, which is the complex Case/When/Concat expansion both names
    # used to render. Both shapes are pinned here because the split is exactly the kind of change a
    # projection-only test cannot see — the old label form rendered fine and could never be
    # filtered on.
    q = M.Driver.objects
    q.values(
        "driverid",
        "q_num"     => "dob__@quarter",
        "quad_num"  => "dob__@quadrimester",
        "q_label"   => "dob__@yyyy_q",
        "quad_label"=> "dob__@yyyy_quad"
    )
    q.filter("surname" => "Hamilton")
    df = q |> DataFrame

    # Hamilton born 1985-01-07 -> quarter 1, quadrimester 1.
    @test df[1, :q_num] == 1
    @test df[1, :quad_num] == 1
    @test df[1, :q_label] == "1985-Q1"
    @test df[1, :quad_label] == "1985-Q1" # `@yyyy_quad` also uses -Q; the labels are ambiguous alone

    # A driver born in April separates the two, which the January case cannot: month 4 is quarter 2
    # but quadrimester 1. Without a row like this the two transforms are indistinguishable and a
    # renderer that answered `@quadrimester` for both would pass.
    q2 = M.Driver.objects
    q2.values("driverid", "q_num" => "dob__@quarter", "quad_num" => "dob__@quadrimester",
              "q_label" => "dob__@yyyy_q", "quad_label" => "dob__@yyyy_quad")
    q2.filter("dob__@month" => 4)
    df2 = q2 |> DataFrame
    @test nrow(df2) > 0
    @test all(df2.q_num .== 2)
    @test all(df2.quad_num .== 1)
    @test all(endswith.(df2.q_label, "-Q2"))
    @test all(endswith.(df2.quad_label, "-Q1"))

    # #579: the documented filter spelling. It rendered valid SQL, bound the parameter, and
    # returned NOTHING — the label expression could never equal an integer. Asserted against an
    # independently computed count so "it returns rows now" cannot pass with the wrong rows.
    q3 = M.Driver.objects
    q3.filter("dob__@quarter" => 1)
    q3.values("driverid")
    n_filtered = nrow(q3 |> DataFrame)
    all_dob = (M.Driver.objects.values("dob") |> DataFrame).dob
    n_expected = count(x -> !ismissing(x) && Dates.month(Dates.Date(string(x)[1:10])) <= 3, all_dob)
    @test n_filtered == n_expected
    @test n_filtered > 0

    # …and a value no quarter can express is refused rather than matching nothing. The REFUSAL is
    # what #579 asserts here and it is unchanged; only the type moved. #576 converted
    # `format_quarter_sql`'s `InvalidValueError` to `FilterError` on a read; #971 moved it back, so a
    # refused value raises `InvalidValueError` on a filter as on a write, located on the transform.
    @test_throws PormG.InvalidValueError M.Driver.objects.filter("dob__@quarter" => 7).values("driverid").list()
    @test_throws PormG.InvalidValueError M.Driver.objects.filter("dob__@quarter" => "abc").values("driverid").list()

    # #586: the label as a FILTER key. The predicate path rendered the label's CONCAT/CASE
    # expansion twice and kept both sets of parameters, so this statement bound nineteen values for
    # ten placeholders and the driver refused it on both engines. Asserted against an independently
    # computed set — the drivers born in Q1 of Hamilton's year — so it cannot pass with wrong rows.
    q6 = M.Driver.objects
    q6.values("driverid", "surname")
    q6.filter("dob__@yyyy_q" => "1985-Q1")
    df6 = q6 |> DataFrame
    expected_q1_1985 = sort([r.driverid for r in eachrow(M.Driver.objects.values("driverid", "dob") |> DataFrame)
                             if !ismissing(r.dob) && (d = Dates.Date(string(r.dob)[1:10]); Dates.year(d) == 1985 && Dates.month(d) <= 3)])
    @test sort(df6.driverid) == expected_q1_1985
    @test "Hamilton" in df6.surname

    q7 = M.Driver.objects
    q7.values("driverid")
    q7.filter("dob__@yyyy_quad" => "1985-Q1")
    df7 = q7 |> DataFrame
    expected_quad1_1985 = sort([r.driverid for r in eachrow(M.Driver.objects.values("driverid", "dob") |> DataFrame)
                                if !ismissing(r.dob) && (d = Dates.Date(string(r.dob)[1:10]); Dates.year(d) == 1985 && Dates.month(d) <= 4)])
    @test sort(df7.driverid) == expected_quad1_1985
    @test length(expected_quad1_1985) >= length(expected_q1_1985)

    # …and membership over two labels is the union of the two quarters.
    q8 = M.Driver.objects
    q8.values("driverid")
    q8.filter("dob__@yyyy_q__@in" => ["1985-Q1", "1985-Q2"])
    df8 = q8 |> DataFrame
    expected_h1_1985 = sort([r.driverid for r in eachrow(M.Driver.objects.values("driverid", "dob") |> DataFrame)
                             if !ismissing(r.dob) && (d = Dates.Date(string(r.dob)[1:10]); Dates.year(d) == 1985 && Dates.month(d) <= 6)])
    @test sort(df8.driverid) == expected_h1_1985

    # #587: ORDER BY on the label with a WHERE value present. The label binds nine operands, and
    # before #587 SQLite filed them in a bucket that flattened BEFORE the WHERE value while the
    # ORDER BY text printed after it — the predicate compared against the label's separator, the
    # label received the predicate's value, and the statement returned the wrong rows (usually
    # none) with no error. Asserted against the unordered query's row set, so "it returns rows
    # now" cannot pass with the wrong ones, and against the label order of the rows it returns.
    q4 = M.Driver.objects
    q4.values("driverid", "q_label" => "dob__@yyyy_q")
    q4.filter("dob__@month" => 4)
    q4.order_by("dob__@yyyy_q")          # projected under ANOTHER name: not an alias hit
    df4 = q4 |> DataFrame
    @test nrow(df4) == nrow(df2)
    @test sort(df4.driverid) == sort(df2.driverid)
    @test issorted(df4.q_label)
    @test all(endswith.(df4.q_label, "-Q2"))

    # The unprojected spelling, descending, with the WHERE value bound through a joined path — a
    # second value the misbind would have displaced.
    q5 = M.Driver.objects
    q5.values("driverid", "dob")
    q5.filter("dob__@month" => 4)
    q5.order_by("-dob__@yyyy_q")
    df5 = q5 |> DataFrame
    @test sort(df5.driverid) == sort(df2.driverid)
    years5 = [Dates.year(Dates.Date(string(x)[1:10])) for x in df5.dob]
    @test issorted(years5; rev = true)
end

@testset "Date Functions & Modifiers" begin
    # Logic: Test date extraction features (Year, Month, Day) using "__@modifier" syntax.
    # Expected SQL: SELECT EXTRACT(YEAR FROM "dob") FROM "drivers" ...
    # Why: Native lookup-style syntax for date parts is a core PormG feature.
    
    # Test values extraction
    q = M.Driver.objects
    q.values(
        "driverid",
        "forename",
        "birth_year"  => "dob__@year",
        "birth_month" => "dob__@month",
        "birth_day"   => "dob__@day"
    )
    q.filter("surname" => "Hamilton")
    df = q |> DataFrame
    
    @test df[1, :birth_year] == 1985
    @test df[1, :birth_month] == 1
    @test df[1, :birth_day] == 7

    # Test complex date modifiers (the year-qualified quarter LABEL, which is the Case/When/Concat
    # expansion — `@quarter` itself is the plain period number since #579).
    q_complex = M.Driver.objects.values("driverid", "q" => "dob__@yyyy_q")
    q_complex.filter("surname" => "Hamilton")
    df_complex = q_complex |> DataFrame
    @test df_complex[1, :q] == "1985-Q1"

    # Test filter modifiers
    q2 = M.Driver.objects.filter("dob__@year" => 1985, "dob__@month" => 1)
    df2 = q2 |> DataFrame
    @test any(x -> x.surname == "Hamilton", eachrow(df2))
end

@testset "Null Checks (ISNULL)" begin
    # Logic: Test the @isnull operator for both TRUE and FALSE.
    # Why: Essential for finding records with missing or present data.
    
    # Check for non-null (nationality should not be null for most drivers)
    count_not_null = M.Driver.objects.filter("nationality__@isnull" => false).count()
    @test count_not_null > 800
    
    # Check for null (some drivers might not have a 'code' in the dataset)
    count_null = M.Driver.objects.filter("code__@isnull" => true).count()
    @test count_null >= 0 # Just verify it doesn't crash
end

@testset "Complex reporting scenarios" begin
    # Cleanup and setup
    # M.Result is the central table linking Drivers, Constructors and Races
    
    @testset "Case/When with nested F arithmetic and Q objects" begin
        # Scenario: Find results where the race happened more than 30 days after driver's DOB
        # but less than 200000 days (arbitrary example for testing arithmetic)
        
        # Note: In F1 dataset, races and drivers have a big gap, so 30 days is always true.
        # We just want to check if the SQL generates correctly and executes.
        
        # `"raceid__year"`, the race's year through the ForeignKey — not `"raceid__@year"`, the
        # `@year` transform applied to the integer key column. The transform spelling used to be
        # rendered as this very column by accident: its memo key (`raceid__year`) collided with the
        # projection below, and the filter path reused the projection's rendered text. #586 stopped
        # a filter reusing a memoized expression that binds or transforms, so the transform now
        # renders what it says — `EXTRACT(YEAR FROM "raceid")`, which PostgreSQL rejects on an
        # integer and SQLite evaluates to NULL, silently matching nothing.
        query = M.Result.objects.filter("raceid__year" => 2024,
           Q(
               F("raceid__date") > F("driverid__dob") + 30,
               F("raceid__date") <= F("driverid__dob") + 10957 # Using large number to match some data
            )
        );
        
        query.values(
            "raceid__year",
            "driverid__surname",
            "driverid__dob",
            "is_within_range" => Sum(
                Case(
                    When(
                        Q(
                            F("raceid__date") > F("driverid__dob") + 30,
                            F("raceid__date") <= F("driverid__dob") + 10957
                        ),
                        then=1
                    ),
                    default=0
                )
            )
        );
        
        query.order_by("-raceid__year", "driverid__surname");
        query.limit(10);
        
        # # Test generation
        # sql = query |> show_query
        # @test contains(sql, "CASE")
        # @test contains(sql, ">")
        # @test contains(sql, "<=")
        # @test contains(sql, "interval") # Our F logic uses interval for date arithmetic
        
        # Test execution
        # query |> show_query  # For debugging
        df = query |> DataFrame
        @test size(df, 1) == 10
        @test "is_within_range" in names(df)
        alonso_data = df[df.driverid__surname .== "Alonso", :]
        @test isempty(alonso_data) # More then 30 years old, should not match
        albon_data = df[df.driverid__surname .== "Albon", :]
        @test !isempty(albon_data) # More then 30 years old, should not match
        @test albon_data.is_within_range[1] == 24
    end

    @testset "Qor with __isnull and explicit values in When" begin
        # Scenario: Count results where status is either null or 1
        query = M.Result.objects
        query.values(
            "raceid__year",
            "statusid",
            "special_count" => Sum(
                Case(
                    When(
                        Qor(
                            "statusid" => 2,
                            "statusid" => 1
                        ),
                        then=1
                    ),
                    default=0
                )
            )
        )
        query.order_by("-raceid__year", "statusid")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) == 5
        @test "special_count" in names(df)
        @test df[1, :special_count] == 287
        @test df[2, :special_count] == 2
        @test df[3, :special_count] == 0
        

    end

    @testset "When with __@in operator" begin
        # Scenario: Filter by a list of IDs inside a Case/When
        lucky_positions = [1, 2, 3]
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "podiums" => Sum(
                Case(
                    When("positionorder__@in" => lucky_positions, then=1),
                    default=0
                )
            )
        )
        query.order_by("-podiums")
        query.limit(5)

        insp = query |> inspect_query
        @info insp[:sql_text]
        
        df = query |> DataFrame
        @test size(df, 1) == 5
        @test "podiums" in names(df)
        @test df[1, :podiums] == 202
        @test df[1, :driverid__surname] == "Hamilton"
    end

    @testset "When with simple Pair (non-Q syntax)" begin
        # Scenario: Use When with a direct Pair instead of wrapping in Q()
        # Expected SQL: ... WHEN "driverid" = 1 THEN 1 ELSE 0 END ...
        # Why: Verify that single conditions work without Q wrapper
        query = M.Result.objects
        query.values(
            "driverid",
            "is_hamilton" => Sum(
                Case(
                    When("driverid" => 1, then=1),
                    default=0
                )
            )
        )
        query.order_by("driverid")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "is_hamilton" in names(df)
        # Hamilton (driverid=1) should have is_hamilton > 0
        @test df[1, :is_hamilton] == 356
    end

    @testset "When with operator modifier syntax" begin
        # Scenario: Use When with operator modifiers (__@gt, __@lte, etc.)
        # Expected SQL: ... WHEN "points" > 10 THEN 1 ELSE 0 END ...
        # Why: Verify that string-based operator syntax works in When conditions
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "high_points_count" => Sum(
                Case(
                    When("points__@gt" => 10, then=1),
                    default=0
                )
            )
        )
        query.order_by("-high_points_count")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "high_points_count" in names(df)
        @test df[1, :high_points_count] > 0
    end

    @testset "When with date modifiers in filter" begin
        # Scenario: Use date extraction modifiers (__@year, __@month) in When conditions
        # Expected SQL: ... WHEN EXTRACT(YEAR FROM "date") = 2024 THEN 1 ELSE 0 END ...
        # Why: Verify that date functions work inside When
        query = M.Result.objects
        query.values(
            "raceid__year",
            "races_2024" => Sum(
                Case(
                    When("raceid__date__@year" => 2024, then=1),
                    default=0
                )
            )
        )
        query.order_by("-races_2024")
        query.limit(3)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "races_2024" in names(df)
        @test df[1, :races_2024] > 0
    end

    @testset "Nested Case inside Case" begin
        # Scenario: Complex conditional logic with nested Case statements for numeric results
        # Expected SQL: CASE WHEN ... THEN ... ELSE CASE WHEN ... THEN ... END END
        # Why: Verify that Case functions can be nested for hierarchical logic
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "complex_points" => Sum(
                Case(
                    [
                        When("points__@gt" => 15, then=3),
                        When("points__@gt" => 10, then=2),
                        When("points__@gt" => 0, then=1)
                    ],
                    default=0
                )
            )
        )
        query.order_by("driverid__surname")
        query.limit(3)
        
        df = query |> DataFrame
        @test size(df, 1) == 3
        @test "complex_points" in names(df)
    end

    @testset "Complex Qor with combined Q logic" begin
        # Scenario: Combine multiple Q objects inside Qor for sophisticated filtering
        # Expected SQL: ... OR (cond1 AND cond2) OR (cond3 AND cond4) ...
        # Why: Verify that Qor can handle combined AND conditions
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "raceid__year",
            "special_results" => Sum(
                Case(
                    When(
                        Qor(
                            Q("points__@gt" => 15, "positionorder__@lte" => 3),  # High points AND podium
                            Q("points" => 0, "statusid" => 3)  # Zero points or specific status
                        ),
                        then=1
                    ),
                    default=0
                )
            )
        )
        query.order_by("-special_results")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "special_results" in names(df)
    end

    @testset "When with chained join in filter" begin
        # Scenario: Use deep join path (__model__field) inside When condition
        # Expected SQL: ... WHEN "circuit"."country" = 'Monaco' THEN 1 ELSE 0 END ...
        # Why: Verify that multi-level joins work in When conditions
        query = M.Result.objects
        query.values(
            "raceid__circuitid__name",
            "raceid__circuitid__country",
            "monaco_races" => Sum(
                Case(
                    When("raceid__circuitid__country" => "Monaco", then=1),
                    default=0
                )
            )
        )
        query.order_by("-monaco_races", "raceid__circuitid__name")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "monaco_races" in names(df)
        # Check if Monaco appears in results
        @test any(df.raceid__circuitid__country .== "Monaco")
        @test df[df.raceid__circuitid__country .== "Monaco", :monaco_races][1] > 0
    end

    @testset "Multiple When clauses with different operator types" begin
        # Scenario: Use various operators (@lte, @range, @isnull, __in) in different When clauses
        # Expected SQL: Multiple WHEN clauses with different operator styles - must return numeric type
        # Why: Verify that all operator types work interchangeably in When
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "result_classification" => Sum(
                Case(
                    [
                        When("positionorder__@lte" => 3, then=3),  # Podium
                        When("positionorder__@range" => [4, 10], then=2),  # Points
                        When("statusid__@isnull" => false, then=1)  # Classified
                    ],
                    default=0
                )
            )
        )
        query.order_by("driverid__surname")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) == 5
        @test "result_classification" in names(df)
    end

    # @testset "Case with only default (no When clauses)" begin
    #     # Scenario: Use Case with just a default value (edge case)
    #     # Expected SQL: This should still generate valid SQL, even without WHEN
    #     # Why: Verify edge case handling and robustness
    #     query = M.Driver.objects
    #     query.values(
    #         "driverid",
    #         "forename",
    #         "constant_value" => Case([], default=Value("No Condition"))
    #     )
    #     query.filter("driverid__@lte" => 5)
        
    #     df = query |> DataFrame
    #     @test size(df, 1) == 5
    #     @test "constant_value" in names(df)
    #     @test all(df.constant_value .== "No Condition")
    # end

    @testset "When with F expression using comparison operators" begin
        # Scenario: Test F expressions with comparison operators in filter() context
        # Expected SQL: ... WHEN (F logic) THEN ... - demonstrating that F works inside filter
        # Why: Verify that F expressions are used for field-to-field comparisons, while string operators (__@) are for field-to-value
        query = M.Result.objects
        query.filter(
            Q(
                F("raceid__date") > F("driverid__dob") + 10950,  # Field-to-field comparison (F is here)
                "points__@gte" => 15  # Field-to-value uses string operators
            )
        )
        query.values(
            "driverid__surname",
            "raceid__year",
            "points",
            "points_gte_15" => Sum(
                Case(
                    When("points__@gte" => 15, then=1),  # String operator in When
                    default=0
                )
            )
        )
        query.order_by("driverid__surname")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) <= 5
        @test "points_gte_15" in names(df)
        @test all(df.points_gte_15 .>= 0)
    end

    @testset "Distinct Aggregates" begin
        # Logic: Test the 'distinct' parameter in aggregate functions.
        # Why: Ensures we can count unique values (e.g., how many unique constructors won).
        q = M.Result.objects
        q.values(
            "total_wins" => Count("resultid"),
            "unique_constructors" => Count("constructorid", distinct=true)
        )
        q.filter("positionorder" => 1) # Only winners
        df = q |> DataFrame
        
        # In history, multiple winners exist, but fewer constructors than total races won
        @test df[1, :total_wins] > df[1, :unique_constructors]
        @test df[1, :unique_constructors] > 10 # More than 10 brands won in F1 history
    end

    @testset "Having Clause (Aggregate Filtering)" begin
        # Logic: Test filtering results based on aggregated values.
        # Why: Essential for queries like "Teams with more than 100 wins".
        q = M.Result.objects
        q.values(
            "constructorid__name",
            "win_count" => Count("resultid")
        )
        q.filter("positionorder" => 1)
        # The filter on "win_count" should be automatically moved to HAVING because "win_count" 
        # is an alias for an aggregate in the SELECT clause.
        q.filter("win_count__@gt" => 100) 
        
        df = q |> DataFrame
        
        # Giants like Ferrari, McLaren, Williams, Mercedes, Red Bull should be here
        @test size(df, 1) >= 5 
        @test all(df.win_count .> 100)
        @test "Ferrari" in df.constructorid__name
    end

    @testset "Advanced F-Expression Math" begin
        # Logic: Test subtraction, multiplication, and division in F expressions.
        # Why: These common arithmetic operations must be correctly translated to SQL.
        q = M.Result.objects.values(
            "resultid",
            "points",
            "grid",
            "p_minus_one" => F("points") - 1,
            "p_times_two" => F("points") * 2,
            "p_div_two"   => F("points") / 2.0,
            "composite"   => (F("points") + F("grid")) / 2
        );
        q.filter("points__@gt" => 20);
        q.limit(5);
        df = q |> DataFrame
        
        @test size(df, 1) == 5
        @test df[1, :p_minus_one] == df[1, :points] - 1
        @test df[1, :p_times_two] == df[1, :points] * 2
        @test df[1, :p_div_two]   == df[1, :points] / 2.0
        @test df[1, :composite]   == (df[1, :points] + df[1, :grid]) / 2
    end

    @testset "Variadic Greatest/Least" begin
        # Logic: Test that Greatest/Least can handle more than 2-3 arguments.
        # Why: Verified variadic support in the type system.
        q = M.Driver.objects
        q.values(
            "max_of_many" => Greatest(Value(1), Value(5), Value(10), Value(2), Value(8)),
            "min_of_many" => Least(Value(100), Value(50), Value(25), Value(75), Value(10))
        )
        q.filter("driverid" => 1)
        df = q |> DataFrame
        
        @test df[1, :max_of_many] == 10
        @test df[1, :min_of_many] == 10
    end
end

@testset "PormGsuffix Operator Integration Tests" begin
    # Logic: Iterate through all operators defined in PormGsuffix and execute them against the database.
    # Why: End-to-end validation that each operator generates correct SQL and returns expected results.
    # Disclaimer: These are integration tests using the F1 dataset; results depend on the data.

    @testset "Comparison Operators (gt, gte, lt, lte, ne)" begin
        # Test: driverid > 100 (gt)
        q_gt = M.Driver.objects.filter("driverid__@gt" => 100).values("driverid").distinct().order_by("driverid")
        df_gt = q_gt |> DataFrame
        @test all(df_gt.driverid .> 100)
        @test size(df_gt, 1) == 761

        # Test: driverid >= 100 (gte)
        q_gte = M.Driver.objects.filter("driverid__@gte" => 100).values("driverid").distinct().order_by("driverid")
        df_gte = q_gte |> DataFrame
        @test all(df_gte.driverid .>= 100)
        @test size(df_gte, 1) == 762

        # Test: driverid < 50 (lt)
        q_lt = M.Driver.objects.filter("driverid__@lt" => 50).values("driverid").distinct().order_by("driverid")
        df_lt = q_lt |> DataFrame
        @test all(df_lt.driverid .< 50)

        # Test: driverid <= 50 (lte)
        q_lte = M.Driver.objects.filter("driverid__@lte" => 50).values("driverid").distinct().order_by("driverid")
        df_lte = q_lte |> DataFrame
        @test all(df_lte.driverid .<= 50)
        @test size(df_lte, 1) == 50

        # Test: driverid != 1 (ne)
        q_ne = M.Driver.objects.filter("driverid__@ne" => 1).values("driverid").distinct().order_by("driverid")
        df_ne = q_ne |> DataFrame
        @test all(df_ne.driverid .!= 1)
    end

    @testset "DISTINCT + ORDER BY must project the sort key (#76)" begin
        # A DISTINCT query that orders by a column outside its projection is rejected by PostgreSQL
        # (and the SQL standard) but runs with a nondeterministic DISTINCT/order interaction on
        # SQLite. PormG raises on both backends so the behavior is identical whichever backend this
        # suite runs against. See issue #76.

        # Misaligned: distinct driverids ordered by surname (not projected) -> raises everywhere.
        @test_throws PormGError begin
            M.Driver.objects.values("driverid").distinct().order_by("surname") |> DataFrame
        end

        # The error is actionable and discriminating (names the column + the DISTINCT context) —
        # not a bare @test_throws that any ArgumentError would satisfy.
        err = try
            M.Driver.objects.values("driverid").distinct().order_by("surname") |> DataFrame
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        @test occursin("surname", msg)
        @test occursin("DISTINCT", msg)

        # The guard does not over-fire: aligned forms still execute end to end.
        #   - the order key IS the projected column
        df_aligned = M.Driver.objects.values("driverid").distinct().order_by("driverid") |> DataFrame
        @test issorted(df_aligned.driverid)
        #   - the sort key is included in a multi-column projection. driverid is the PK, so distinct
        #     (driverid, surname) is exactly one row per driver — the same 861 the fixture seeds.
        #     (Row *order* is left to the backend collation — asserting it here with Julia's codepoint
        #     `issorted` would spuriously fail on accented/mixed-case surnames; NULL/collation ordering
        #     is covered by the #75 tests. What matters for #76 is that the guard did not over-fire.)
        df_both = M.Driver.objects.values("driverid", "surname").distinct().order_by("surname") |> DataFrame
        @test nrow(df_both) == 861
        @test Set(names(df_both)) == Set(["driverid", "surname"])
    end

    @testset "Range Operator (range / BETWEEN)" begin
        # Test: driverid BETWEEN 50 AND 100
        q_range = M.Driver.objects.filter("driverid__@range" => [50, 100]).order_by("driverid").values("driverid")
        df_range = q_range |> DataFrame
        @test all(df_range.driverid .>= 50 .&& df_range.driverid .<= 100)
        @test size(df_range, 1) == 51
    end

    @testset "IN and NOT IN Operators (in, nin)" begin
        # Test: driverid IN (1, 2, 3)  (in)
        lucky_ids = [1, 2, 3]
        q_in = M.Driver.objects.filter("driverid__@in" => lucky_ids).order_by("driverid").values("driverid")
        df_in = q_in |> DataFrame
        @test size(df_in, 1) == 3
        @test df_in[1, :driverid] == 1
        @test df_in[2, :driverid] == 2
        @test df_in[3, :driverid] == 3

        # Test: driverid NOT IN (1, 2, 3)  (nin)
        q_nin = M.Driver.objects.filter("driverid__@nin" => lucky_ids).order_by("driverid").values("driverid")
        df_nin = q_nin |> DataFrame
        @test all(df_nin.driverid .∉ Ref(lucky_ids))
        @test size(df_nin, 1) > 0
    end

    @testset "String Match Operators (contains, icontains, startswith, endswith)" begin
        # Test: surname LIKE '%ilton%' (contains)
        q_contains = M.Driver.objects.filter("surname__@contains" => "ilton").values("surname")
        df_contains = q_contains |> DataFrame
        @test all(occursin.("ilton", df_contains.surname))

        # Test: surname ILIKE '%HAM%' (case-insensitive contains)
        q_icontains = M.Driver.objects.filter("surname__@icontains" => "HAM").values("surname")
        df_icontains = q_icontains |> DataFrame
        @test all(occursin.("HAM", uppercase.(df_icontains.surname)))

        # Test: nationality LIKE 'British%' (startswith)
        q_startswith = M.Driver.objects.filter("nationality__@startswith" => "British").values("nationality")
        df_startswith = q_startswith |> DataFrame
        if size(df_startswith, 1) > 0
            @test all(startswith.(df_startswith.nationality, "British"))
        end

        # Test: code LIKE '%AM' (endswith)
        q_endswith = M.Driver.objects.filter("code__@endswith" => "AM").values("code")
        df_endswith = q_endswith |> DataFrame
        @test all(endswith.(df_endswith.code, "AM"))
    end

    @testset "NULL Check Operator (isnull)" begin
        # Test: code IS NOT NULL  (isnull => false)
        q_not_null = M.Driver.objects.filter("code__@isnull" => false).values("code")
        df_not_null = q_not_null |> DataFrame
        @test all(.!(ismissing.(df_not_null.code)) .& (df_not_null.code .!= ""))

        # Test: code IS NULL  (isnull => true)
        q_null = M.Driver.objects.filter("code__@isnull" => true)
        df_null = q_null |> DataFrame
        # Some drivers may not have a code; if the query returns results, verify they're null
        if size(df_null, 1) > 0
            # At least some should be missing or empty
            @test any(ismissing.(df_null.code))
        end
    end

    @testset "Exact Equality (default operator without suffix)" begin
        # Test: driverid = 1  (implicit = operator)
        q_exact = M.Driver.objects.filter("driverid" => 1).values("driverid", "forename")
        df_exact = q_exact |> DataFrame
        @test size(df_exact, 1) == 1
        @test df_exact[1, :driverid] == 1
        @test df_exact[1, :forename] == "Lewis"
    end

    @testset "Combined operator filtering (multiple filters)" begin
        # Test: Multiple operators in a single query
        q_multi = M.Driver.objects.filter(
            "driverid__@gt" => 10,
            "driverid__@lte" => 50,
            "nationality__@icontains" => "British"
        ).values("driverid", "nationality").order_by("driverid")
        df_multi = q_multi |> DataFrame
        @test all(df_multi.driverid .> 10 .&& df_multi.driverid .<= 50)
        if size(df_multi, 1) > 0
            @test all(contains.(uppercase.(df_multi.nationality), "BRITISH"))
        end
    end
end

@testset "SQL Functions wrapping F() arithmetic expressions" begin
    # This test set covers the feature gap where FExpression (SQLTypeF) could not be
    # used as the column argument of SQL functions like Round, Abs, Floor, Ceil, etc.
    #
    # Root cause fixed: FObject.column union type now includes SQLTypeF so any arithmetic
    # expression produced by F() operators is accepted as a function argument.
    #
    # Pattern being tested: Round(F("field") * scalar, precision)
    #                        Abs(F("field") - scalar)
    #                        Floor / Ceil wrapping F arithmetic
    #                        Aggregate function wrapping FExpression (e.g. Round(Sum("x") / Count("y"), n))
    #                        Nesting: Round(Abs(F("field") - scalar), precision)

    @testset "Round wrapping F arithmetic" begin
        # Scenario: Project a rounded 10% bonus on race points.
        # Expected SQL shape: ROUND((T."points" * ?), ?)
        # The raw arithmetic value F("points") * 1.1 and its rounded counterpart are
        # both projected so we can verify the relationship in Julia.
        q = M.Result.objects
        q.values(
            "resultid",
            "points",
            "raw_bonus"    => F("points") * 1.1,
            "round_bonus0" => Round(F("points") * 1.1)
        )
        q.filter("points__@gt" => 0.0)
        q.order_by("resultid")
        q.limit(10)

        insp = q |> inspect_query
        # @info insp[:sql_text]

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "round_bonus0" in names(df)

        # To a whole number, half away from zero as both engines' `round` is.
        @test all(eachrow(df)) do row
            isapprox(Float64(row.round_bonus0), round(row.raw_bonus, RoundNearestTiesAway); atol=1e-6)
        end
        # To two places it is refused (#1044): PostgreSQL rounds the decimal form of a float and
        # SQLite the double. Until #1044 this case was compared against Julia's half-to-even
        # rounding, and passed only because no row lands on a tie.
        err = try
            q2 = M.Result.objects; q2.values("x" => Round(F("points") * 1.1, 2)); q2 |> DataFrame
            nothing
        catch e
            e
        end
        @test err isa PormG.QueryBuildError && occursin("#1044", sprint(showerror, err))
    end

    @testset "Abs wrapping F arithmetic" begin
        # Scenario: Compute absolute deviation from 10 points for every scored result.
        # Expected SQL shape: ABS((T."points" - ?))
        q = M.Result.objects
        q.values(
            "resultid",
            "points",
            "deviation" => Abs(F("points") - 10.0)
        )
        q.filter("points__@gt" => 0.0)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "deviation" in names(df)

        @test all(eachrow(df)) do row
            isapprox(Float64(row.deviation), abs(row.points - 10.0); atol=1e-6)
        end
    end

    @testset "Floor and Ceil wrapping F arithmetic" begin
        # Scenario: Floor / Ceil the halved grid position so we can bucket drivers per lap.
        # Expected SQL shape: FLOOR((T."grid" / ?))  and  CEIL((T."grid" / ?))
        q = M.Result.objects
        q.values(
            "resultid",
            "grid",
            "floor_half" => Floor(F("grid") / 2.0),
            "ceil_half"  => Ceil(F("grid") / 2.0)
        )
        q.filter("grid__@gt" => 0)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "floor_half" in names(df)
        @test "ceil_half"  in names(df)

        @test all(eachrow(df)) do row
            Float64(row.floor_half) == floor(row.grid / 2.0) &&
            Float64(row.ceil_half)  == ceil(row.grid / 2.0)
        end
    end

    @testset "Aggregate expression wrapped in Round" begin
        # Scenario: Average points per result, rounded to a whole number (to places, a fractional
        # value rounds differently per engine and is refused, #1044).
        # Sum("points") / Count("resultid") produces an FExpression (field_name=FObject, ...),
        # and Round(that_expression) must accept it via the fixed FObject.column type.
        #
        # Expected SQL shape: ROUND((SUM(T."points") / COUNT(T."resultid")), ?)
        q = M.Driver_standings.objects
        q.values(
            "driverid",
            "total_points"  => Sum("points"),
            "total_entries" => Count("driverstandingsid"),
            "avg_pts_round" => Round(Sum("points") / Count("driverstandingsid"))
        )
        q.filter("raceid__year" => 2021)
        q.order_by("-total_points")
        q.limit(5)

        df = q |> DataFrame
        @test size(df, 1) == 5
        @test "avg_pts_round" in names(df)

        @test all(eachrow(df)) do row
            expected = round(Float64(row.total_points) / row.total_entries, RoundNearestTiesAway)
            isapprox(Float64(row.avg_pts_round), expected; atol=1e-6)
        end
    end

    @testset "Nested: Round wrapping Abs wrapping F arithmetic" begin
        # Scenario: Compound nesting — first take the absolute deviation from 12.5, then round it.
        # This validates that FExpression flows through multiple layers of FObject.column.
        # Expected SQL shape: ROUND(ABS((T."points" - ?)), ?)
        q = M.Result.objects
        q.values(
            "resultid",
            "points",
            "rounded_dev" => Round(Abs(F("points") - 12.5))   # to places it is refused (#1044)
        )
        q.filter("points__@gt" => 0.0)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "rounded_dev" in names(df)

        @test all(eachrow(df)) do row
            expected = round(abs(row.points - 12.5), RoundNearestTiesAway)
            isapprox(Float64(row.rounded_dev), expected; atol=1e-6)
        end
    end

    @testset "F expression as column of Lower / Upper (string coercion path)" begin
        # Scenario: Lower / Upper must also accept FExpression for completeness, even though
        # calling string functions on numeric fields is not typical usage. We verify the
        # type acceptance by wrapping a Cast-produced expression.
        # Expected SQL shape: LOWER(CAST((T."driverid")::text AS text))  (PostgreSQL)
        #                      LOWER(CAST(T."driverid" AS text))          (SQLite)
        q = M.Driver.objects
        q.values(
            "driverid",
            "lower_cast" => Lower(Cast(F("driverid"), "text"))
        )
        q.filter("driverid__@lte" => 3)
        q.order_by("driverid")

        df = q |> DataFrame
        @test size(df, 1) == 3
        @test "lower_cast" in names(df)
        # driverid 1, 2, 3 cast to text and lowercased
        @test df[1, :lower_cast] == "1"
        @test df[2, :lower_cast] == "2"
        @test df[3, :lower_cast] == "3"
    end

    @testset "Joined-path SQLField inputs remain accepted by helpers" begin
        # Scenario: helper constructors should still accept SQLField carrying joined paths,
        # not just direct field names or F expressions. This protects against narrowing the
        # helper signatures beyond what the query builder already knows how to render.
        q = M.Result.objects
        q.values(
            "resultid",
            "surname_raw" => "driverid__surname",
            "code_raw" => "driverid__code",
            "year_raw" => "raceid__year",
            "surname_lower" => Lower(PormG.QueryBuilder.SQLField("driverid__surname")),
            "code_trimmed" => Trim(PormG.QueryBuilder.SQLField("driverid__code")),
            "year_text" => Cast(PormG.QueryBuilder.SQLField("raceid__year"), "text")
        )
        q.filter("driverid__code__@isnull" => false)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "surname_lower" in names(df)
        @test "code_trimmed" in names(df)
        @test "year_text" in names(df)

        @test all(eachrow(df)) do row
            row.surname_lower == lowercase(row.surname_raw) &&
            row.code_trimmed == strip(row.code_raw) &&
            row.year_text == string(row.year_raw)
        end
    end

    @testset "Extract and ToChar accept SQLField and F inputs" begin
        # Scenario: Extract/ToChar should be consistent with the other helper constructors
        # and accept both SQLField(joined path) and F(date_field) inputs.
        q = M.Result.objects
        q.values(
            "resultid",
            "race_date_raw" => "raceid__date",
            "race_year_from_field" => Extract(PormG.QueryBuilder.SQLField("raceid__date"), "YEAR"),
            "race_date_fmt_field" => ToChar(PormG.QueryBuilder.SQLField("raceid__date"), "YYYY-MM-DD"),
            "race_year_from_f" => Extract(F("raceid__date"), "YEAR"),
            "race_date_fmt_f" => ToChar(F("raceid__date"), "YYYY-MM-DD")
        )
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10

        @test all(eachrow(df)) do row
            date_str = string(row.race_date_raw)[1:10]
            expected_year = parse(Int, date_str[1:4])
            row.race_year_from_field == expected_year &&
            row.race_year_from_f == expected_year &&
            row.race_date_fmt_field == date_str &&
            row.race_date_fmt_f == date_str
        end
    end
end

@testset "#74 Aggregate fan-out guard" begin
    # Logic: COUNT/SUM/AVG over a column a to-many join (reverse FK / M2M) row-multiplies must RAISE the
    #        #74 guard *specifically* (cause-checked, not just any ArgumentError); aggregating the
    #        to-many table's OWN column under a single to-many returns the CORRECT recomputed value;
    #        MAX/MIN and distinct=true are exempt; two to-many joins (n>=2), M2M, and un-attributable
    #        expressions raise; a plain aggregate is correct and unaffected.
    # Why: a base/parent column aggregated under a to-many join returns a confidently-wrong number
    #      (verified 36x inflation on driver_standings). Fail-loud guard for issue #74.

    # Returns the thrown error (or nothing). is_fanout confirms it is the #74 guard, so an unrelated
    # ArgumentError (e.g. a bad field path) cannot masquerade as a passing raise.
    fanout_err(f) = try; f(); nothing; catch e; e; end
    is_fanout(e)  = e isa PormGError && occursin("fan-out", e.msg)

    did = 1  # F1 dataset: driver 1 (Hamilton) has many driver_standings rows.

    # CASE B — base-table pk under a to-many join → inflated → raise (cause-checked).
    qB = M.Driver.objects
    qB.values("nationality", "n" => Count("driverid"))
    qB.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> (qB |> DataFrame)))

    # SUM / AVG over a BASE column under a to-many must also raise — the guard is not COUNT-only.
    qSum = M.Driver.objects
    qSum.values("nationality", "s" => Sum("number"))     # `number` is a base Driver column
    qSum.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> inspect_query(qSum)))

    qAvg = M.Driver.objects
    qAvg.values("nationality", "a" => Avg("number"))
    qAvg.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> inspect_query(qAvg)))

    # CASE A — aggregate the to-many table's OWN column (single to-many) → allowed AND correct.
    qA = M.Driver.objects
    qA.values("driverid", "n" => Count("driver_standings__driverstandingsid"))
    qA.filter("driverid" => did)
    dfA = qA |> DataFrame
    expectedA = M.Driver_standings.objects.filter("driverid" => did).count()
    @test expectedA > 0                                  # guard against a vacuous 0 == 0
    @test nrow(dfA) == 1 && dfA[1, :n] == expectedA       # recomputed value, not just "it ran"

    # CASE A' — related column AND a filter on the SAME relation must NOT raise, and stay correct. The
    #           join is built twice (cache + real); the guard derives from the deduped row_join.
    qAp = M.Driver.objects
    qAp.values("driverid", "n" => Count("driver_standings__driverstandingsid"))
    qAp.filter("driverid" => did, "driver_standings__position__@gte" => 1)
    dfAp = qAp |> DataFrame
    expectedAp = M.Driver_standings.objects.filter("driverid" => did, "position__@gte" => 1).count()
    @test (nrow(dfAp) == 1 ? dfAp[1, :n] : 0) == expectedAp

    # MAX over a to-many column is immune to duplication → allowed AND equals the true max.
    qMax = M.Driver.objects
    qMax.values("driverid", "m" => Max("driver_standings__points"))
    qMax.filter("driverid" => did)
    pts = (M.Driver_standings.objects.filter("driverid" => did).values("points") |> DataFrame).points
    @test (qMax |> DataFrame)[1, :m] == maximum(pts)

    # MIN is exempt too (symmetric to MAX) → allowed AND equals the true min.
    qMin = M.Driver.objects
    qMin.values("driverid", "m" => Min("driver_standings__points"))
    qMin.filter("driverid" => did)
    @test (qMin |> DataFrame)[1, :m] == minimum(pts)

    # distinct=true → renders COUNT(DISTINCT …) and counts the single grouped driver once.
    qDist = M.Driver.objects
    qDist.values("driverid", "n" => Count("driverid", distinct=true))
    qDist.filter("driverid" => did, "driver_standings__position__@gte" => 1)
    @test occursin("COUNT(DISTINCT", inspect_query(qDist)[:sql_text])   # cause: opt-in rendered
    @test (qDist |> DataFrame)[1, :n] == 1

    # COUNT(*) under a to-many join → inflated → raise (cause-checked).
    qStar = M.Driver.objects
    qStar.values("nationality", "n" => Count("*"))
    qStar.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> (qStar |> DataFrame)))

    # n >= 2 — aggregating ONE many-side column while a SECOND to-many relation is also joined still
    #          inflates (the grains multiply), so even the many-side aggregate must raise.
    qN2 = M.Driver.objects
    qN2.values("driverid", "n" => Count("driver_standings__driverstandingsid"))
    qN2.filter("lap_times__lap__@gte" => 1)              # second reverse to-many relation
    @test is_fanout(fanout_err(() -> inspect_query(qN2)))

    # Many-to-many — counting the BASE row while joining an M2M relation inflates → raise; counting the
    # M2M-related table's own column (single to-many) is allowed. Build-level (needs no M2M data).
    qM2M = M.M2m_driver_endorsement_scratch.objects
    qM2M.values("driverref", "n" => Count("id"))
    qM2M.filter("sponsors__name__@icontains" => "x")
    @test is_fanout(fanout_err(() -> inspect_query(qM2M)))

    qM2Mok = M.M2m_driver_endorsement_scratch.objects
    qM2Mok.values("driverref", "n" => Count("sponsors__id"))
    @test fanout_err(() -> inspect_query(qM2Mok)) === nothing   # related-col M2M aggregate is fine

    # Ambiguous — an aggregate over a multi-column expression cannot be attributed to one table, so the
    # guard conservatively raises under a to-many rather than risk a silent wrong number.
    qAmb = M.Driver.objects
    qAmb.values("nationality", "s" => Sum(F("driver_standings__points") + F("driver_standings__wins")))
    qAmb.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> inspect_query(qAmb)))

    # Forward FK (to-one) join present → NOT a fan-out → guard must allow. This is the key
    # discrimination: a to-one join must never be marked to-many. Counts stay correct.
    qFk = M.Result.objects
    qFk.values("constructorid__name", "n" => Count("resultid"))
    qFk.filter("raceid" => 1)
    @test fanout_err(() -> inspect_query(qFk)) === nothing            # to-one join does not trip the guard
    dfFk = qFk |> DataFrame
    @test sum(dfFk.n) == M.Result.objects.filter("raceid" => 1).count()  # per-constructor counts sum to the race total

    # No to-many join (plain aggregate) → unaffected AND correct.
    qPlain = M.Result.objects
    qPlain.values("raceid", "n" => Count("resultid"))
    qPlain.filter("raceid" => 1)
    @test (qPlain |> DataFrame)[1, :n] == M.Result.objects.filter("raceid" => 1).count()
end


# ─────────────────────────────────────────────────────────────────────────────
# #696: Cast / output_field type names on a real engine
# The type name is validated and rebuilt before it reaches the SQL, so every accepted spelling must
# still execute and return the right values on both engines — a modifier (`numeric(10,2)`), a
# multi-word name (`double precision`), a field object, and `Case`'s `default=` bind cast. A hostile
# string is refused before any SQL is sent.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#696: Cast and output_field type names execute on both engines" begin
    q = M.Result.objects
    q.values(
        "resultid",
        "points",
        # #1040: a float cast to a scaled numeric is refused (PostgreSQL rounds to the scale, SQLite
        # keeps every digit); a whole number has nothing to round, so the modifier still executes.
        "p_2dp" => Cast(Round("points"), "numeric(10,2)"),
        "p_dbl" => Cast("points", "double precision"),
        # #1028: a float cast to an integer is refused; `Round` first reads the same on both engines.
        "p_int" => Cast(Round("points"), PormG.Models.IntegerField()),
        "is_win" => Case([When("positionorder" => 1, then = 1)]; default = 0,
                         output_field = PormG.Models.IntegerField()),
    )
    q.filter("raceid" => 1)
    q.order_by("resultid")
    df = q |> DataFrame
    @test size(df, 1) == M.Result.objects.filter("raceid" => 1).count()
    # The cast values agree with the stored float; the integer is the float rounded half away from
    # zero, on both engines (#1028).
    @test all(Float64(r.p_2dp) == round(r.points, RoundNearestTiesAway) for r in eachrow(df))
    @test all(isapprox(Float64(r.p_dbl), r.points) for r in eachrow(df))
    @test all(Int(r.p_int) == round(Int, r.points, RoundNearestTiesAway) for r in eachrow(df))
    # Exactly one winner in race 1: the CASE and its bind-cast default both executed.
    @test sum(Int.(df.is_win)) == 1

    # Refused while the expression is built — nothing reaches the database.
    @test_throws PormG.InvalidValueError Cast("points", "int); DROP TABLE result; --")
    @test_throws PormG.InvalidValueError Coalesce("points", Value(0); output_field = "integer OR TRUE")
end

# ─────────────────────────────────────────────────────────────────────────────
# #808: a column in a CASE branch executes — a conditional SUM over real 2009 results.
# `then = F("points")` renders the branch as the column (nothing bound), so the SUM is each driver's
# points in the races they won; it is cross-checked against a plain `Sum` over the winning rows, which
# involves no CASE at all. The `then = F("points") * 2` twin binds its `2` between the WHEN value and
# the ELSE value — SQLite binds positionally, so a misfiled value would change every total.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: then = F(...) in a conditional aggregate executes" begin
    q = M.Result.objects
    q.filter("raceid__year" => 2009)
    q.values(
        "driverid__surname",
        "win_pts"    => Sum(Case([When("positionorder" => 1, then = F("points"))], default = 0)),
        "win_pts_x2" => Sum(Case([When("positionorder" => 1, then = F("points") * 2)], default = 0)),
    )
    got = Dict(r[:driverid__surname] => (Float64(r[:win_pts]), Float64(r[:win_pts_x2])) for r in q.list())

    # Independent answer: the same totals from the winning rows alone.
    chk = M.Result.objects
    chk.filter("raceid__year" => 2009, "positionorder" => 1)
    chk.values("driverid__surname", "pts" => Sum("points"))
    expected = Dict(r[:driverid__surname] => Float64(r[:pts]) for r in chk.list())

    @test !isempty(expected)
    @test all(got[k] == (v, 2v) for (k, v) in expected)
    # Every driver without a win went through the ELSE branch only.
    @test all(v == (0.0, 0.0) for (k, v) in got if !haskey(expected, k))
end

@testset "Aggregates over a BooleanField (#953)" begin
    # Logic: `Max`/`Min` over a boolean answer "any true" / "all true" on both engines — `BOOL_OR` /
    # `BOOL_AND` on PostgreSQL, which has no max(boolean), and `MAX`/`MIN` over SQLite's 0/1 — and
    # read back as a `Bool`. `Sum`/`Avg` are refused at build on both engines.
    # Why: before #953 both rendered `MAX(col)`, which PostgreSQL rejected when it ran, while SQLite
    # answered; the same query worked on one engine only.
    # Its own rows, under a marker, so the shared New_join_position fixture (test_cjoin.jl) is untouched.
    rows = ("s183-a" => [true, true], "s183-b" => [true, false, missing], "s183-c" => [false, false])
    purge() = (q = M.New_join_position.objects; q.filter("description__@startswith" => "s183-"); q.exists() && q.delete())
    purge()
    try
        for (label, flags) in rows, flag in flags
            M.New_join_position.objects.create("description" => label, "boolean_field" => flag)
        end
        q = M.New_join_position.objects
        q.filter("description__@startswith" => "s183-")
        q.values(
            "description",
            "any_b"   => Max("boolean_field"),
            "all_b"   => Min("boolean_field"),
            "n_true"  => Sum(When("boolean_field" => true, then = 1, otherwise = 0)),
            "share"   => Avg(When("boolean_field" => true, then = 1, otherwise = 0)),
            "any_c"   => Case([When(Max("boolean_field"), then = 1)], default = 0),
        )
        got = Dict(r[:description] => r for r in q.list())
        @test Set(keys(got)) == Set(first.(rows))
        # Independent answer: Julia's own any/all over the non-NULL flags each group was given.
        for (label, flags) in rows
            vals = collect(skipmissing(flags))
            @test got[label][:any_b] === any(vals)
            @test got[label][:all_b] === all(vals)
            # The documented spellings for a sum and a mean: a NULL flag counts as not true.
            @test got[label][:n_true] == count(vals)
            @test Float64(got[label][:share]) ≈ count(vals) / length(flags)
            @test got[label][:any_c] == (any(vals) ? 1 : 0)
        end

        # The alias filters in HAVING, against the same aggregate.
        h = M.New_join_position.objects
        h.filter("description__@startswith" => "s183-")
        h.values("description", "any_b" => Max("boolean_field"))
        h.filter("any_b" => true)
        @test Set(r[:description] for r in h.list()) == Set(["s183-a", "s183-b"])

        for agg in (Sum("boolean_field"), Avg("boolean_field"))
            r = M.New_join_position.objects
            r.filter("description__@startswith" => "s183-")
            r.values("description", "x" => agg)
            err = @test_throws PormG.QueryBuildError r.list()
            @test occursin("over a boolean is not supported", sprint(showerror, err.value))
        end
    finally
        purge()
    end
end

@testset "Boolean-valued expressions read back as a Bool (#965)" begin
    # Logic: a BooleanField column, and every expression the build types as a boolean, reads back as
    # a `Bool` on both engines: the column itself (`values`, a wildcard read, `DataFrame`, the row
    # `create` returns), a comparison, `Cast(…, "boolean")`, `Coalesce`, `Lag` over a boolean, a `Case`
    # of Bool branches, and `Coalesce(Max(flag), false)` per group. `Max` of a boolean `Case` renders
    # `BOOL_OR` on PostgreSQL.
    # Why: before #965 only #953's `Max`/`Min` carried the boolean kind, so SQLite returned the 0/1 it
    # stores, even for the plain column, while PostgreSQL returned a `Bool`; and `Max` of a boolean
    # `Case` failed on PostgreSQL as `max(boolean)`. Each assertion is `===` or an `isa Bool`, so a
    # 0/1 fails it.
    # Its own rows, under a marker, so the shared New_join_position fixture (test_cjoin.jl) is untouched.
    # `result` is 0/1/NULL only: SQLite's CAST AS BOOLEAN keeps any other integer as it is.
    rows = (("s189-a", true, 1), ("s189-a", false, 0), ("s189-b", missing, 1), ("s189-b", false, missing))
    purge() = (q = M.New_join_position.objects; q.filter("description__@startswith" => "s189-"); q.exists() && q.delete())
    purge()
    try
        created = [M.New_join_position.objects.create("description" => label, "boolean_field" => flag, "result" => result)
                   for (label, flag, result) in rows]
        # The row `create` hands back is read through the same table.
        @test [c[:boolean_field] for c in created] isa Vector{<:Union{Bool,Missing}}
        @test isequal([c[:boolean_field] for c in created], [r[2] for r in rows])

        # The column itself, against the flags written: projected, wildcard, and as a DataFrame column.
        written = [r[2] for r in rows]
        base = () -> (b = M.New_join_position.objects; b.filter("description__@startswith" => "s189-"); b.order_by("id"); b)
        p = base(); p.values("boolean_field")
        @test all(r -> r[:boolean_field] === missing || r[:boolean_field] isa Bool, p.list())
        @test isequal([r[:boolean_field] for r in p.list()], written)
        @test isequal([r[:boolean_field] for r in base().list()], written)
        @test all(r -> r[:boolean_field] === missing || r[:boolean_field] isa Bool, base().list())
        @test all(v -> v === missing || v isa Bool, (base() |> DataFrame).boolean_field)
        bool_case = () -> Case([When("result" => 1, then = true)], default = false)
        q = M.New_join_position.objects
        q.filter("description__@startswith" => "s189-")
        q.values(
            "id", "boolean_field", "result",
            "positive" => F("result") > 0,
            "cast"     => Cast("result", "boolean"),
            "flag_or"  => Coalesce("boolean_field", false),
            "previous" => Lag("boolean_field", over = WindowOver(order_by = ["id"])),
            "case_b"   => bool_case(),
        )
        q.order_by("id")
        got = q.list()
        @test length(got) == length(rows)
        # Independent answer: Julia's own value of each expression over the row's stored columns.
        for (i, r) in enumerate(got)
            res, flag = r[:result], r[:boolean_field]
            @test r[:positive] === (ismissing(res) ? missing : res > 0)
            @test r[:cast] === (ismissing(res) ? missing : res != 0)
            @test flag === written[i]
            @test r[:flag_or] === coalesce(written[i], false)
            @test r[:previous] === (i == 1 ? missing : written[i - 1])
            @test r[:case_b] === coalesce(res == 1, false)
        end

        g = M.New_join_position.objects
        g.filter("description__@startswith" => "s189-")
        g.values("description", "any_b" => Coalesce(Max("boolean_field"), false), "any_case" => Max(bool_case()))
        grouped = Dict(r[:description] => r for r in g.list())
        @test grouped["s189-a"][:any_b] === true
        @test grouped["s189-b"][:any_b] === false
        @test grouped["s189-a"][:any_case] === true
        @test grouped["s189-b"][:any_case] === true

        # A projected `Exists(...)`: does the row's group hold a true flag?
        flagged = M.New_join_position.objects
        flagged.filter("description" => PormG.QueryBuilder.OuterRef("description"), "boolean_field" => true)
        e = base()
        e.values("description", "has_true" => PormG.QueryBuilder.Exists(flagged))
        @test [(r[:description], r[:has_true]) for r in e.list()] ==
              [(label, label == "s189-a") for (label, _, _) in rows]
        @test all(r -> r[:has_true] isa Bool, e.list())

        # A sum of a boolean `Case` is refused at build on both engines, as #953 refuses `Sum(flag)`.
        s = M.New_join_position.objects
        s.filter("description__@startswith" => "s189-")
        s.values("description", "n" => Sum(bool_case()))
        err = @test_throws PormG.QueryBuildError s.list()
        @test occursin("over a boolean is not supported", sprint(showerror, err.value))
    finally
        purge()
    end
end

@testset "A column projected after a When on it keeps its read type (#979)" begin
    # Logic: a column projected after a `Case(When(<same column> …))` projection reads back with the
    # type it has projected alone: a `BooleanField` as a `Bool`, a `DateField` as a `Date`, on the
    # base model and across a foreign key.
    # Why: the `When` condition renders the bare column into the projection memo under the column's
    # own name, and the projection reused that entry without recording a read kind, so SQLite handed
    # back the stored value: 0/1 for the flag, the date's text. `isa Bool` / `isa Date` fail on either.
    # Its own rows, under a marker, so the shared New_join_position fixture (test_cjoin.jl) is untouched.
    rows = (("s190-979", true), ("s190-979", false), ("s190-979", missing))
    purge() = (q = M.New_join_position.objects; q.filter("description" => "s190-979"); q.exists() && q.delete())
    purge()
    try
        for (label, flag) in rows
            M.New_join_position.objects.create("description" => label, "boolean_field" => flag)
        end
        q = M.New_join_position.objects
        q.filter("description" => "s190-979")
        q.values("c" => Case([When("boolean_field" => true, then = 1)], default = 0), "boolean_field")
        q.order_by("id")
        got = q.list()
        # `===` per row, not `isequal` over the vectors: `isequal(1, true)` holds, so a 0/1 would pass.
        @test length(got) == length(rows)
        for (r, (_, flag)) in zip(got, rows)
            @test r[:boolean_field] === flag
        end
        @test [r[:c] for r in got] == [1, 0, 0]
    finally
        purge()
    end

    # The F1 fixture, read-only: race 1000 is the 2018 Hungarian GP, race 1100 the 2023 Australian GP.
    hungary = Date(2018, 7, 29)
    r = M.Race.objects
    r.filter("raceid__@in" => [1000, 1100])
    r.values("raceid", "c" => Case([When("date" => hungary, then = 1)], default = 0), "date")
    r.order_by("raceid")
    races = r.list()
    @test all(x -> x[:date] isa Date, races)
    @test [x[:date] for x in races] == [hungary, Date(2023, 4, 2)]
    @test [x[:c] for x in races] == [1, 0]

    j = M.Result.objects
    j.filter("raceid__@in" => [1000, 1100])
    j.values("resultid", "c" => Case([When("raceid__date" => hungary, then = 1)], default = 0), "raceid__date")
    j.order_by("resultid")
    joined = j.list()
    @test !isempty(joined)
    @test all(x -> x[:raceid__date] isa Date, joined)
    @test all(x -> x[:c] == (x[:raceid__date] == hungary ? 1 : 0), joined)
    # The same column projected alone, which always rendered and so was always typed.
    alone = M.Result.objects
    alone.filter("raceid__@in" => [1000, 1100])
    alone.values("resultid", "raceid__date")
    alone.order_by("resultid")
    @test [x[:raceid__date] for x in joined] == [x[:raceid__date] for x in alone.list()]
end

@testset "#972: @isnull and @range after a transform execute on both engines" begin
    # `"date__@year__@isnull"` and `"date__@year__@range"` were refused as "ISNULL / BETWEEN is not a
    # supported operator" before the build reached the database; they render the transform's own
    # `IS [NOT] NULL` / `BETWEEN` now. The unit suite pins the SQL; this runs it, against expected
    # counts that do not come from the transform.
    #
    # `sprint_date` is NULL on every race without a sprint, so a date part of it is NULL on exactly
    # those rows — the bare column's own `@isnull` is the independent count. The guard below keeps
    # that from passing vacuously on a fixture with no NULLs.
    @test M.Race.objects.filter("sprint_date__@isnull" => true).count() > 0
    @test M.Race.objects.filter("sprint_date__@isnull" => false).count() > 0
    @test M.Race.objects.filter("start_at__@isnull" => true).count() > 0
    @test M.Race.objects.filter("start_at__@isnull" => false).count() > 0
    for polarity in (true, false)
        bare = M.Race.objects.filter("sprint_date__@isnull" => polarity).count()
        @test M.Race.objects.filter("sprint_date__@year__@isnull" => polarity).count() == bare
        @test M.Race.objects.filter("sprint_date__@yyyy_mm__@isnull" => polarity).count() == bare
        @test M.Race.objects.filter("start_at__@hour__@isnull" => polarity).count() ==
              M.Race.objects.filter("start_at__@isnull" => polarity).count()
        # #997: the two labels too, refused until their PostgreSQL arm stopped reading `'-Q'`.
        @test M.Race.objects.filter("sprint_date__@yyyy_q__@isnull" => polarity).count() == bare
        @test M.Race.objects.filter("sprint_date__@yyyy_quad__@isnull" => polarity).count() == bare
    end

    # The range, against the years counted in Julia from the dates themselves. The date's text is
    # read rather than its type, so the count does not depend on what each engine hands back.
    years = [parse(Int, first(string(r[:date]), 4)) for r in M.Race.objects.values("date").list()]
    in_90s = count(y -> 1990 <= y <= 1999, years)
    @test in_90s > 0
    @test M.Race.objects.filter("date__@year__@range" => [1990, 1999]).count() == in_90s
    @test M.Race.objects.filter("date__@year__@nrange" => [1990, 1999]).count() == length(years) - in_90s
end

@testset "#955: transforms read a timestamp in UTC on both engines" begin
    # The contract: `@hour`, `@date` and `@day` over a `DateTimeField` are the UTC hour, date and day,
    # on both engines. SQLite stores the UTC text; PostgreSQL reads a `timestamptz` in the session
    # time zone, which both drivers open as UTC. The expectations come from the instant itself, read
    # back and converted in Julia, not from another transform.
    to_utc(z) = z isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(z, TimeZones.tz"UTC")) : DateTime(z)
    q = M.Race.objects
    q.filter("start_at__@isnull" => false)
    q.values("raceid", "start_at", "h" => "start_at__@hour", "d" => "start_at__@date", "dy" => "start_at__@day")
    q.order_by("raceid")
    rows = q.list(:dict)
    @test length(rows) > 100
    for r in rows
        utc = to_utc(r[:start_at])
        @test r[:h] == hour(utc)
        @test string(r[:d]) == string(Date(utc))
        @test r[:dy] == day(utc)
    end

    # PostgreSQL only: the session really is UTC, and overriding it is what moves the answer — the
    # divergence the docs warn about. `SET LOCAL` in a transaction pins every statement to the one
    # connection the zone was set on and resets at COMMIT, so nothing leaks back into the pool
    # (the #114 pattern in `test_bulk_copy.jl`).
    settings = PormG.config[PORMG_DB_FOLDER]
    if settings.connections isa PormG.PormGPostgres
        session_zone() = (PormG.ConnectionPool.fetch(settings,
            "SELECT current_setting('TimeZone') AS tz;") |> DataFrame)[1, :tz]
        @test session_zone() == "UTC"
        r = first(rows)
        local_hour = hour(TimeZones.astimezone(TimeZones.ZonedDateTime(to_utc(r[:start_at]), TimeZones.tz"UTC"),
                                               TimeZones.tz"America/Sao_Paulo"))
        @test local_hour != r[:h]   # the probe can tell the two zones apart
        PormG.run_in_transaction(settings) do
            PormG.ConnectionPool.fetch(settings, "SET LOCAL TIME ZONE 'America/Sao_Paulo';")
            @test session_zone() == "America/Sao_Paulo"
            hq = M.Race.objects
            hq.filter("raceid" => r[:raceid])
            hq.values("h" => "start_at__@hour")
            @test only(hq.list(:dict))[:h] == local_hour
        end
        @test session_zone() == "UTC"
    end
end

@testset "#997: @yyyy_q / @yyyy_quad read NULL for a NULL date on both engines" begin
    # PostgreSQL's `CONCAT` skipped the NULL year and month and returned `"-Q"` for a race without a
    # sprint, where SQLite returned NULL. The expected labels are computed in Julia from the date's
    # own text, so a renderer that returned `"-Q"`, or the wrong period, fails here.
    q = M.Race.objects
    q.values("raceid", "sprint_date", "q" => "sprint_date__@yyyy_q", "quad" => "sprint_date__@yyyy_quad")
    df = q |> DataFrame
    @test any(ismissing, df.sprint_date)
    @test !all(ismissing, df.sprint_date)
    expected(date, months) = ismissing(date) ? missing :
        (d = Dates.Date(string(date)[1:10]); "$(Dates.year(d))-Q$(cld(Dates.month(d), months))")
    wrong = [r.raceid for r in eachrow(df) if
             !isequal(r.q, expected(r.sprint_date, 3)) || !isequal(r.quad, expected(r.sprint_date, 4))]
    @test isempty(wrong)
end

@testset "#1006: Concat skips a NULL operand on both engines" begin
    # PostgreSQL's `CONCAT` skipped a NULL operand and SQLite's `||` made the whole result NULL, so a
    # driver with no `number` read "# Senna" on one engine and `missing` on the other. Both skip it
    # now, as Django does. The expected text is built in Julia from the columns themselves, so the
    # same assertion holds on both engines.
    q = M.Driver.objects
    q.values("driverid", "number", "surname",
             "label" => Concat(Value("#"), "number", Value(" "), "surname"),
             "alone" => Concat(["number"]),
             "car" => Case(When("number__@isnull" => false, then = Concat(Value("#"), "number"))))
    df = q |> DataFrame
    @test any(ismissing, df.number)
    @test !all(ismissing, df.number)
    num(n) = ismissing(n) ? "" : string(n)
    wrong = [r.driverid for r in eachrow(df) if !isequal(r.label, "#" * num(r.number) * " " * r.surname)]
    @test isempty(wrong)
    # One operand is text too, never a number and never NULL: SQLite has no `||` to convert it.
    @test all(v -> v isa AbstractString, df.alone)
    @test isempty([r.driverid for r in eachrow(df) if !isequal(r.alone, num(r.number))])
    # The documented way back to a NULL: a `Case` with no matching branch.
    wrong_car = [r.driverid for r in eachrow(df) if
                 !isequal(r.car, ismissing(r.number) ? missing : "#" * num(r.number))]
    @test isempty(wrong_car)
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: a boolean, float or decimal operand is refused on both engines (#1027)
# PostgreSQL's CONCAT writes `t` / `25` / `3.00` where SQLite's `||` writes `1` / `25.0` / `3`, so
# `Concat("driverref", "-", "points")` read 'hamilton-10' on one engine and 'hamilton-10.0' on the
# other. The #1006 test above uses `Driver.number`, an integer — the one numeric type where the engines
# agree. Here a FloatField (`Result.points`) and a BooleanField (`New_join_position.boolean_field`)
# are refused against the live schema, and the documented escape for a yes/no reads the same text on
# both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: Concat refuses a Bool, Float or Decimal operand on both engines" begin
    # The refusal itself, not any `QueryBuildError`: a renamed field would raise one too.
    refusal(f) = try f(); nothing catch e; e end
    is_1027(e) = e isa PormG.QueryBuildError && occursin("#1027", sprint(showerror, e))
    # A float column, through a join as the docs write it.
    q = M.Result.objects
    q.values("x" => Concat("driverid__driverref", Value("-"), "points"))
    @test is_1027(refusal(() -> q |> DataFrame))
    # A boolean column.
    q = M.New_join_position.objects
    q.values("x" => Concat("description", Value(": "), "boolean_field"))
    @test is_1027(refusal(() -> q |> DataFrame))
    # A float literal is refused before any query exists.
    @test is_1027(refusal(() -> Concat("driverref", Value("-"), 1.5)))

    # The escape: a `Case` names the two texts, so the value is the same string on both engines. The
    # expected text is computed in Julia from the projected points column.
    q = M.Result.objects
    q.filter("raceid" => 18)
    q.values("resultid", "driverid__driverref", "points",
             "outcome" => Concat("driverid__driverref", Value(": "),
                                 Case(When("points__@gt" => 0, then = Value("scored")), default = "no points")))
    df = q |> DataFrame
    @test nrow(df) > 0
    @test any(>(0), df.points) && any(==(0), df.points)   # both branches are exercised
    wrong = [r.resultid for r in eachrow(df) if
             r.outcome != r.driverid__driverref * ": " * (r.points > 0 ? "scored" : "no points")]
    @test isempty(wrong)
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast to text or an integer, and Concat's timestamp / interval / JSON operands, on both engines (#1028)
# Measured on PostgreSQL 16.15 and SQLite 3.45.1: `Cast(points, CharField())` is '10' on one and
# '10.0' on the other, `Cast(1.5, IntegerField())` 2 and 1, and `Concat("|", start_at)` writes
# '2009-03-29 06:00:00+00' against '2009-03-29T06:00:00.000+00:00'. Each is refused against the live
# schema, as is a CTE column built from `Sum`. The documented escapes — `Round`/`Floor`/`Ceil` before an
# integer cast, `ToChar` for a timestamp — read the same value on both engines, checked against Julia.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1028: divergent casts and Concat operands are refused on both engines" begin
    refusal(f) = try f(); nothing catch e; e end
    is_1028(e) = e isa PormG.QueryBuildError && occursin("#1028", sprint(showerror, e))
    proj(model, expr) = () -> (q = model.objects; q.filter(model === M.Result ? ("raceid" => 18) : ("raceid" => 1));
                               q.values("x" => expr); q |> DataFrame)
    # A float column cast to text and to an integer, directly and through an output_field.
    @test is_1028(refusal(proj(M.Result, Cast("points", PormG.Models.CharField()))))
    @test is_1028(refusal(proj(M.Result, Concat("driverid__driverref", Value("-"), Cast("points", PormG.Models.CharField())))))
    @test is_1028(refusal(proj(M.Result, Cast("points", PormG.Models.IntegerField()))))
    @test is_1028(refusal(proj(M.Result, Greatest("points", 0; output_field = "integer"))))
    # A timestamp and an interval operand of Concat, and a JSON document (refused at render, so no
    # scratch row is needed).
    @test is_1028(refusal(proj(M.Race, Concat(Value("|"), "start_at"))))
    @test is_1028(refusal(() -> (q = M.Lap_times.objects; q.filter("raceid" => 841); q.values("x" => Concat(Value("|"), "time")); q |> DataFrame)))
    @test is_1028(refusal(() -> (q = M.Field_validation_scratch.objects; q.values("x" => Concat(Value("|"), "payload")); q |> DataFrame)))
    # A CTE column built from `Sum("points")`, which the CTE types as an integer.
    q = M.Driver.objects
    body = M.Result.objects
    body.values("driverid", "total" => Sum("points"))
    q.with("c" => body, join_field = "driverid" => "driverid")
    q.values("x" => Concat("driverref", Value("-"), CTE("c", "total")))
    err = refusal(() -> q |> DataFrame)
    @test err isa PormG.QueryBuildError && occursin("the CTE column `CTE(\"c\", \"total\")`", sprint(showerror, err))

    # The integer escape: every rounding function reads what Julia computes, over rows with a fraction.
    q = M.Result.objects
    q.filter("raceid__@lte" => 50)
    q.values("resultid", "points",
             "r" => Cast(Round("points"), PormG.Models.IntegerField()),
             "f" => Cast(Floor("points"), PormG.Models.IntegerField()),
             "c" => Cast(Ceil("points"), PormG.Models.IntegerField()))
    df = q |> DataFrame
    @test any(p -> !isinteger(p), df.points)   # the fractional rows are exercised
    wrong = [r.resultid for r in eachrow(df) if
             (r.r, r.f, r.c) != (round(Int, r.points, RoundNearestTiesAway), floor(Int, r.points), ceil(Int, r.points))]
    @test isempty(wrong)
    # The timestamp escape: race 1's start, named in a format both engines write.
    df = proj(M.Race, Concat(Value("|"), ToChar("start_at", "YYYY-MM-DD HH:MI:SS")))()
    @test df[1, :x] == "|2009-03-29 06:00:00"
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast to a scaled numeric, on both engines (#1040)
# Measured on PostgreSQL 16.15 and SQLite 3.45.1: `Cast(points, "numeric(10,0)")` is 2 for 1.5 on one
# and 1.5 on the other. The refusal fires against the live schema on both engines; the escapes — an
# unscaled `numeric`, and a whole number before a scaled cast — read the value Julia computes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1040: a cast to numeric(p, s) PostgreSQL would round is refused on both engines" begin
    refusal(f) = try f(); nothing catch e; e end
    is_1040(e) = e isa PormG.QueryBuildError && occursin("#1040", sprint(showerror, e))
    proj(expr) = () -> (q = M.Result.objects; q.filter("raceid" => 2); q.values("x" => expr); q |> DataFrame)
    @test is_1040(refusal(proj(Cast("points", "numeric(10,0)"))))
    @test is_1040(refusal(proj(Cast("points", "numeric(10,2)"))))
    # #1044 refuses `Round("points", 2)` itself, before the cast reads it.
    @test occursin("#1044", sprint(showerror, refusal(proj(Cast(Round("points", 2), "numeric(10,2)")))))
    @test is_1040(refusal(proj(Coalesce("points", 0; output_field = "numeric(10,1)"))))
    @test is_1040(refusal(() -> (q = M.Driver.objects; q.filter("driverid" => 1); q.values("x" => Cast("driverref", "numeric(10,2)")); q |> DataFrame)))

    # The escapes, over race 2 (the 2009 Malaysian GP, half points): the fractional rows are exercised.
    q = M.Result.objects
    q.filter("raceid" => 2)
    q.values("resultid", "points",
             "plain" => Cast("points", "numeric"),
             "whole" => Cast(Round("points"), "numeric(10,0)"),
             "floor" => Cast(Floor("points"), "numeric(10,2)"))
    df = q |> DataFrame
    @test any(p -> !isinteger(p), df.points)
    wrong = [r.resultid for r in eachrow(df) if
             (Float64(r.plain), Float64(r.whole), Float64(r.floor)) !=
             (r.points, round(r.points, RoundNearestTiesAway), floor(r.points))]
    @test isempty(wrong)
end

# ─────────────────────────────────────────────────────────────────────────────
# A float literal that fits the scale, on both engines (#1050)
# `1.5`, `0.1` and `2.25` have at most two places, so `numeric(10,2)` has nothing to round: both
# engines read the literal's own value (a `Decimal` on PostgreSQL, a `Float64` on SQLite). One with
# more places is still refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1050: a float literal within the scale reads the same value on both engines" begin
    q = M.Driver.objects
    q.filter("driverid" => 1)
    q.values("a" => Cast(Value(1.5), "numeric(10,2)"),
             "b" => Cast(Value(0.1), "numeric(10,2)"),
             "c" => Coalesce(Value(2.25), Value(0.0); output_field = "numeric(10,2)"))
    df = q |> DataFrame
    @test (Float64(df[1, :a]), Float64(df[1, :b]), Float64(df[1, :c])) == (1.5, 0.1, 2.25)
    err = try
        q = M.Driver.objects; q.filter("driverid" => 1); q.values("x" => Cast(Value(2.675), "numeric(10,2)")); q |> DataFrame
        nothing
    catch e
        e
    end
    @test err isa PormG.QueryBuildError && occursin("a Float64 literal with 3 decimal places", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# Round(x, d) over a value with more than d places, on both engines (#1044)
# Measured on PostgreSQL 16.15 and SQLite 3.45.1: `Round(2.675, 2)` is 2.68 on one and 2.67 on the
# other, and a numeric(10,3) value the same, because SQLite holds a REAL. A value with at most d places
# (a two-place DecimalField at d = 2) and a whole number read the same; a negative d is refused when
# the expression is built.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1044: Round(x, d) is refused where the engines would round differently" begin
    refusal(f) = try f(); nothing catch e; e end
    is_1044(e) = e isa PormG.QueryBuildError && occursin("#1044", sprint(showerror, e))
    proj(m, expr) = () -> (q = m.objects; q.filter("raceid" => 2); q.values("x" => expr); q |> DataFrame)
    @test is_1044(refusal(proj(M.Result, Round("points", 2))))
    @test is_1044(refusal(proj(M.Result, Round("points", 1))))
    @test is_1044(refusal(proj(M.Result, Round(Avg("points"), 1))))
    @test is_1044(refusal(proj(M.Constructor_standings, Round("points", 1))))   # two places, rounded to one
    @test is_1044(refusal(proj(M.Result, Round(Cast(Value(Decimals.Decimal(0, 2675, -3)), "numeric(10,3)"), 2))))
    @test is_1044(refusal(() -> (q = M.Result.objects; q.filter("raceid" => 2, "points__@gte" => Round("points", 2)); q |> DataFrame)))
    @test refusal(() -> Round("number", -1)) isa PormG.InvalidValueError

    # What passes reads the same value on both: a two-place DecimalField at two places, an integer
    # column, and a literal that fits.
    q = M.Constructor_standings.objects
    q.filter("raceid" => 2)
    q.values("points", "wins", "r" => Round("points", 2), "w" => Round("wins", 1),
             "c" => Cast(Round("points", 2), "numeric(10,2)"))   # the docs' example: at most 2 places
    df = q |> DataFrame
    @test nrow(df) > 0
    @test all(r -> Float64(r.r) == Float64(r.points), eachrow(df))
    @test all(r -> Float64(r.c) == Float64(r.points), eachrow(df))
    @test all(r -> Float64(r.w) == Float64(r.wins), eachrow(df))
    df = proj(M.Result, Round(Value(1.5), 2))()
    @test Float64(df[1, :x]) == 1.5
end
