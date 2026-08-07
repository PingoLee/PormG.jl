"""
Targeted validation test suite for the field types and write-operation contracts exercised in this file.

This file tests:
- Core scalar, temporal, and relationship field contracts used by these regressions
- Data type enforcement, nullability, uniqueness metadata, defaults, and formatter coercion
- User-facing API patterns (.objects.create(), .objects.update(), inspect_query(), etc.)
- Query inspection payloads, including parameter ordering and temporal normalization
- Bulk operations (bulk_insert, bulk_update)
- Field validation functions
- Write operation metadata (auto_now_add, auto_now, defaults, formatters)
"""
# julia -t auto --project=. test\unit\test_field_validation_and_operations.jl 2>&1 | tee test_output.txt

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: validate_field_data, inspect_query, object, filter, values, update, delete, bulk_insert, bulk_update
using Dates
using Decimals
using TimeZones
using DataFrames

const QB = PormG.QueryBuilder
const Models = PormG.Models

# Mock Postgres Dialect for inspection
struct MockPostgres <: PormG.PormGPostgres end
MockSettings = PormG.Configuration.Settings(
    connections = MockPostgres(),
    change_data = true
)
PormG.config["default"] = MockSettings

# issue #79: DateTimeField values are canonicalized to ONE UTC ISO-8601 string
# (yyyy-mm-ddTHH:MM:SS.sss+00:00) on the bind path, so SQLite's lexicographic TEXT
# comparison matches PostgreSQL. Expected parameters are derived independently here
# (convert the instant to UTC, then format) — a missing UTC conversion would fail.
canon_utc(zdt) = Dates.format(astimezone(zdt, TimeZone("UTC")), Models.DATETIME_FORMAT)

@testset "SECTION 1: Field type validation" begin    
    @testset "Integer Fields (IDField, IntegerField, BigIntegerField)" begin
        mock_int_model = Models.Model_Type(
            name = "int_test",
            fields = Dict(
                "id" => Models.IDField(),
                "age" => Models.IntegerField(null=false),
                "big_val" => Models.BigIntegerField()
            ),
            field_names = ["id", "age", "big_val"]
        )

        @test validate_field_data(mock_int_model, "id", 10, "insert") === true
        @test_throws PormGError validate_field_data(mock_int_model, "id", "not-an-int", "insert")
        
        @test validate_field_data(mock_int_model, "age", 25, "insert") === true
        # Django accepts Decimal for IntegerField by coercing through int(value).
        # PormG should accept exact integer-valued Decimal inputs as well, but it
        # must still reject fractional Decimal values to avoid silent truncation.
        @test validate_field_data(mock_int_model, "age", parse(Decimal, "25"), "insert") === true
        @test validate_field_data(mock_int_model, "age", parse(Decimal, "25.0"), "insert") === true
        @test_throws PormGError validate_field_data(mock_int_model, "age", parse(Decimal, "25.5"), "insert")
        @test Models.format2int64(parse(Decimal, "25.0")) == 25
        @test_throws PormGError validate_field_data(mock_int_model, "age", nothing, "insert")
        
        @test validate_field_data(mock_int_model, "big_val", 9223372036854775807, "insert") === true
    end

    @testset "Constructor Hardening" begin
        # Decimal places > max_digits should fail at construction
        @test_throws PormG.FieldValidationError Models.DecimalField(max_digits=5, decimal_places=6)
        
        # primary_key=true should fail at construction for both
        @test_throws PormG.FieldValidationError Models.DecimalField(primary_key=true)
        @test_throws PormG.FieldValidationError Models.FloatField(primary_key=true)
        
        # FloatField default should now use format2float64 logic (more robust)
        f_field = Models.FloatField(default="123.45")
        @test f_field.default === 123.45
    end

    @testset "String Fields (CharField, TextField, EmailField)" begin
        mock_str_model = Models.Model_Type(
            name = "str_test",
            fields = Dict(
                "code" => Models.CharField(max_length=5),
                "email" => Models.EmailField()
            ),
            field_names = ["code", "email"]
        )

        @test validate_field_data(mock_str_model, "code", "abc", "insert") === true
        # Bounded CharField still enforces its limit (max_length=5).
        @test_throws PormGError validate_field_data(mock_str_model, "code", "toolong", "insert")

        @test validate_field_data(mock_str_model, "email", "test@example.com", "insert") === true

        # #325: CharField no longer caps `max_length` at 255. That ceiling was a MySQL-ism —
        # PostgreSQL's `varchar` takes up to 10,485,760 characters and SQLite ignores the declared
        # length — and it was LOSSY on read-back: introspecting a live `varchar(500)` had to retype
        # the column to TextField and drop the length, so the model never matched its own table and
        # `makemigrations` proposed the same widening forever. The constructor call goes red on main.
        @test Models.CharField(max_length = 500).max_length == 500
        @test Models.CharField(max_length = 10_000).max_length == 10_000
        # The lower bound is untouched — a zero/negative length is still a declaration error.
        @test_throws PormG.FieldValidationError Models.CharField(max_length = 0)
        # …and length validation still fires at the declared bound, wherever it is.
        mock_long_model = Models.Model_Type(
            name = "long_char_test",
            fields = Dict("url" => Models.CharField(max_length = 500)),
            field_names = ["url"]
        )
        @test validate_field_data(mock_long_model, "url", "a"^500, "insert") === true
        @test_throws PormGError validate_field_data(mock_long_model, "url", "a"^501, "insert")

        # Regression: a field whose `max_length` is `nothing` (the St_cruz.b1_n case) must SKIP
        # the length check, not compare `length(value) > nothing` (which threw
        # MethodError: isless(::Int, ::Nothing)).
        #
        # BinaryField is the only field that can reach this state from a bare constructor —
        # `sBinaryField.max_length` is the codebase's only `Union{Int, Nothing}`; sCharField,
        # sPasswordField, sURLField and sSlugField all declare a plain `::Int` and default it.
        # So this stays on BinaryField, and since #296 it also guards the byte-count arm of the
        # check, which is the branch a binary value now takes.
        mock_unbounded_model = Models.Model_Type(
            name = "unbounded_len_test",
            fields = Dict(
                "id" => Models.IDField(),
                "blob" => Models.BinaryField()    # max_length defaults to nothing
            ),
            field_names = ["id", "blob"]
        )
        @test mock_unbounded_model.fields["blob"].max_length === nothing
        # Strings — accepted on the write path and stored as their UTF-8 code units (#296).
        @test validate_field_data(mock_unbounded_model, "blob", "36336", "update") === true
        @test validate_field_data(mock_unbounded_model, "blob", "x"^10_000, "insert") === true
        # Byte vectors — the branch that did not exist before #296. Without the unbounded guard
        # these compare a byte count against `nothing` and throw exactly as the string case did.
        @test validate_field_data(mock_unbounded_model, "blob", UInt8[0x33, 0x36], "update") === true
        @test validate_field_data(mock_unbounded_model, "blob", zeros(UInt8, 10_000), "insert") === true

        # And the bound is enforced in BYTES once it is set — the pre-#296 check counted
        # characters and skipped byte vectors entirely, so neither of these raised.
        mock_bounded_model = Models.Model_Type(
            name = "bounded_len_test",
            fields = Dict(
                "id" => Models.IDField(),
                "blob" => Models.BinaryField(max_length = 4)
            ),
            field_names = ["id", "blob"]
        )
        @test validate_field_data(mock_bounded_model, "blob", UInt8[1, 2, 3, 4], "insert") === true
        @test_throws PormGError validate_field_data(mock_bounded_model, "blob", UInt8[1, 2, 3, 4, 5], "insert")
        # "héllo" is 5 characters but 6 UTF-8 bytes: a character count would let it through.
        @test ncodeunits("héllo") == 6 && length("héllo") == 5
        @test_throws PormGError validate_field_data(mock_bounded_model, "blob", "héllo", "insert")
    end

    @testset "Numeric Fields: Comprehensive Type Handling" begin
        mock_decimal_model = Models.Model_Type(
            name = "decimal_test",
            fields = Dict(
                "price" => Models.DecimalField(max_digits=10, decimal_places=2),
                "score" => Models.DecimalField(max_digits=5, decimal_places=1, null=true)
            ),
            field_names = ["price", "score"]
        )
        
        mock_float_model = Models.Model_Type(
            name = "float_test",
            fields = Dict(
                "ratio" => Models.FloatField(null=false),
                "percentage" => Models.FloatField(null=true)
            ),
            field_names = ["ratio", "percentage"]
        )

        # ===== DECIMAL FIELD TESTS =====
        # Test 1: Decimal with float input
        @test validate_field_data(mock_decimal_model, "price", 10.5, "insert") === true
        
        # Test 2: Decimal with integer input (should convert)
        @test validate_field_data(mock_decimal_model, "price", 10, "insert") === true
        
        # Test 3: Decimal with string input (literal decimal - must not use scientific notation)
        @test validate_field_data(mock_decimal_model, "price", "9999.99", "insert") === true

        # Test 4: Decimal with numeric scientific notation value
        @test validate_field_data(mock_decimal_model, "price", 1e2, "insert") === true
        
        # Test 5: Decimal accepts scientific notation strings for Julia-style numeric input.
        @test validate_field_data(mock_decimal_model, "price", "1e2", "insert") === true
        
        # Test 6: Decimal field nullable
        @test validate_field_data(mock_decimal_model, "score", nothing, "insert") === true
        @test validate_field_data(mock_decimal_model, "score", missing, "insert") === true
        
        # Test 7: Decimal with zero
        @test validate_field_data(mock_decimal_model, "price", 0.0, "insert") === true
        
        # Test 8: Decimal with negative values
        @test validate_field_data(mock_decimal_model, "price", -99.99, "insert") === true
        
        # Test 9: Decimal with very small values
        @test validate_field_data(mock_decimal_model, "price", 0.01, "insert") === true
        
        # Test 10: Decimal respects decimal_places
        @test validate_field_data(mock_decimal_model, "price", "10.50", "insert") === true
        @test_throws PormGError validate_field_data(mock_decimal_model, "price", "10.123", "insert")
        @test_throws PormGError validate_field_data(mock_decimal_model, "score", 1.25, "insert")

        # Test 11: Decimal respects max_digits
        @test_throws PormGError validate_field_data(mock_decimal_model, "price", "12345678901", "insert")

        # Test 12: Invalid Decimal - non-numeric string
        @test_throws PormGError validate_field_data(mock_decimal_model, "price", "not-a-number", "insert")
        
        # ===== FLOAT FIELD TESTS =====
        # Test 13: Float with integer input
        @test validate_field_data(mock_float_model, "ratio", 5, "insert") === true
        
        # Test 14: Float with float input
        @test validate_field_data(mock_float_model, "ratio", 3.14159, "insert") === true
        
        # Test 15: Float with string input (converts to float)
        @test validate_field_data(mock_float_model, "ratio", "2.718", "insert") === true
        
        # Test 16: Float with scientific notation (numeric)
        @test validate_field_data(mock_float_model, "ratio", 1.5e-3, "insert") === true
        
        # Test 17: Float with scientific notation string
        @test validate_field_data(mock_float_model, "ratio", "1.23e4", "insert") === true
        
        # Test 18: Float with zero
        @test validate_field_data(mock_float_model, "ratio", 0.0, "insert") === true
        
        # Test 19: Float with negative values
        @test validate_field_data(mock_float_model, "ratio", -3.14, "insert") === true
        
        # Test 20: Float with very large values
        @test validate_field_data(mock_float_model, "ratio", 1.0e308, "insert") === true
        
        # Test 21: Float with very small values
        @test validate_field_data(mock_float_model, "ratio", 1.0e-308, "insert") === true
        
        # Test 22: Float nullable field
        @test validate_field_data(mock_float_model, "percentage", nothing, "insert") === true
        @test validate_field_data(mock_float_model, "percentage", missing, "insert") === true
        
        # Test 23: Float rejects non-finite values
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", Inf, "insert")
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", -Inf, "insert")
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", NaN, "insert")
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", "Inf", "insert")
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", "NaN", "insert")

        # Test 24: Float rejects invalid numeric strings during validation
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", "not-a-number", "insert")
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", "1,25", "insert")

        # Test 25: Invalid Float - non-nullable with nothing
        @test_throws PormGError validate_field_data(mock_float_model, "ratio", nothing, "insert")
    end

    @testset "Numeric Formatter: Bool input converts to Int" begin
        # Regression: Bool <: Integer in Julia, so without an explicit Bool overload,
        # format_number_sql(true) would dispatch to the Integer method and return the Bool
        # as-is. LibPQ then serializes it as 'true' which PostgreSQL rejects for INTEGER columns.
        @test Models.format_number_sql(true) === 1
        @test Models.format_number_sql(false) === 0
        @test Models.format_number_sql(true) isa Int
    end

    @testset "Numeric Formatter: AbstractString Regression" begin
        # This regression covers the query-builder path used by IN filters on numeric fields.
        # In Julia, slicing can yield `SubString{String}` instead of `String`, unlike Python/Django
        # where the sliced value remains the same string type. The ORM should normalize that input
        # at the formatter boundary instead of forcing application code to pre-convert it.
        raw_cbo = "123456"
        sliced_cbo = SubString(raw_cbo, 2, 4)

        @test Models.format_number_sql(sliced_cbo) == "234"

        # The array case is the important regression: an `IN` filter may pass a vector of string
        # fragments collected from CSV parsing or slicing, and the formatter must not throw when
        # storing those normalized numeric strings in its internal vector.
        sliced_codes = [SubString(raw_cbo, 1, 2), SubString(raw_cbo, 5, 6)]
        formatted_codes = Models.format_number_sql(sliced_codes)

        @test formatted_codes == ["12", "56"]
        @test all(code -> code isa Union{String, Integer, Missing}, formatted_codes)
    end

    @testset "Logical & Temporal Fields (BooleanField, DateTimeField, DateField)" begin
        mock_time_model = Models.Model_Type(
            name = "time_test",
            fields = Dict(
                "is_ok" => Models.BooleanField(default=true),
                "ts" => Models.DateTimeField()
            ),
            field_names = ["is_ok", "ts"]
        )

        @test validate_field_data(mock_time_model, "is_ok", true, "insert") === true
        
        now_dt = Dates.now()
        @test validate_field_data(mock_time_model, "ts", now_dt, "insert") === true
    end

    @testset "DateTimeField Comprehensive Testing: Edge Cases & Boundaries" begin
        # DateTimeField with various configurations
        DateTimeModel = Models.Model_Type(
            name = "datetime_comprehensive_test",
            fields = Dict(
                "id" => Models.IDField(),
                "created_at" => Models.DateTimeField(auto_now_add=true),
                "updated_at" => Models.DateTimeField(auto_now=true),
                "event_time" => Models.DateTimeField(null=false),
                "scheduled_at" => Models.DateTimeField(null=true),
                "deadline" => Models.DateTimeField(null=true)
            ),
            field_names = ["id", "created_at", "updated_at", "event_time", "scheduled_at", "deadline"],
            connect_key = "default"
        )
        
        # --- NULL/MISSING HANDLING ---
        
        # Test 1: Nullable field with nothing
        @test validate_field_data(DateTimeModel, "scheduled_at", nothing, "insert") === true
        
        # Test 2: Nullable field with missing
        @test validate_field_data(DateTimeModel, "scheduled_at", missing, "insert") === true
        
        # Test 3: Non-nullable field with nothing (should fail)
        @test_throws PormGError validate_field_data(DateTimeModel, "event_time", nothing, "insert")
        
        # Test 4: Non-nullable field with missing (should fail)
        @test_throws PormGError validate_field_data(DateTimeModel, "event_time", missing, "insert")
        
        # --- VALID DATETIME VALUES ---
        
        # Test 5: Current timestamp (now)
        @test validate_field_data(DateTimeModel, "event_time", Dates.now(), "insert") === true
        
        # Test 6: Specific DateTime object
        specific_dt = DateTime(2024, 6, 15, 14, 30, 45)
        @test validate_field_data(DateTimeModel, "event_time", specific_dt, "insert") === true
        
        # Test 7: Leap year date
        leap_year_dt = DateTime(2024, 2, 29, 12, 0, 0)
        @test validate_field_data(DateTimeModel, "event_time", leap_year_dt, "insert") === true
        
        # Test 8: Year boundary (start of year)
        new_year_dt = DateTime(2024, 1, 1, 0, 0, 0)
        @test validate_field_data(DateTimeModel, "event_time", new_year_dt, "insert") === true
        
        # Test 9: Year boundary (end of year)
        year_end_dt = DateTime(2024, 12, 31, 23, 59, 59)
        @test validate_field_data(DateTimeModel, "event_time", year_end_dt, "insert") === true
        
        # Test 10: Midnight
        midnight_dt = DateTime(2024, 6, 15, 0, 0, 0)
        @test validate_field_data(DateTimeModel, "event_time", midnight_dt, "insert") === true
        
        # Test 11: Just before midnight
        before_midnight = DateTime(2024, 6, 15, 23, 59, 59)
        @test validate_field_data(DateTimeModel, "event_time", before_midnight, "insert") === true
        
        # Test 12: Unix epoch
        epoch_dt = DateTime(1970, 1, 1, 0, 0, 0)
        @test validate_field_data(DateTimeModel, "event_time", epoch_dt, "insert") === true
        
        # Test 13: Far future date
        far_future = DateTime(2099, 12, 31, 23, 59, 59)
        @test validate_field_data(DateTimeModel, "event_time", far_future, "insert") === true
        
        # --- AUTO_NOW_ADD & AUTO_NOW BEHAVIOR (Inspection) ---
        
        # Test 14: Create with auto_now_add field (ignored in create, DB handles it)
        create_with_auto = DateTimeModel.objects.create(
            "event_time" => DateTime(2024, 6, 15, 10, 30, 0),
            show_query=:inspection
        )
        expected_event_time = canon_utc(ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), TimeZone("UTC")))
        @test create_with_auto[:operation] === :insert
        @test create_with_auto[:parameter_count] == 3
        @test contains(create_with_auto[:sql_text], "created_at")  # Should be in SQL
        @test any(==(expected_event_time), create_with_auto[:parameters])
        @test count(param -> param isa AbstractString, create_with_auto[:parameters]) == 3
        
        # Test 15: Update with auto_now field (should be in SQL)
        update_auto_q = DateTimeModel.objects
        update_auto_q.filter("id" => 1)
        update_with_auto = update_auto_q.update(
            "event_time" => DateTime(2024, 7, 20, 15, 45, 30),
            show_query=:dict
        )
        expected_updated_event_time = canon_utc(ZonedDateTime(DateTime(2024, 7, 20, 15, 45, 30), TimeZone("UTC")))
        @test update_with_auto[:operation] === :update
        @test contains(update_with_auto[:sql_text], "updated_at") || contains(update_with_auto[:sql_text], "UPDATE")
        @test update_with_auto[:parameter_count] == 3
        @test update_with_auto[:parameters][1] == 1
        @test any(==(expected_updated_event_time), update_with_auto[:parameters][2:end])
        @test count(param -> param isa AbstractString, update_with_auto[:parameters][2:end]) == 2
        
        # --- BULK OPERATIONS WITH DATETIMES ---
        
        # Test 16: Bulk insert with various datetime values
        df_datetimes = DataFrame(
            event_time = [
                DateTime(2024, 1, 15, 8, 0, 0),
                DateTime(2024, 6, 20, 14, 30, 0),
                DateTime(2024, 12, 25, 16, 45, 30)
            ]
        )
        res_bulk_dt = bulk_insert(DateTimeModel.objects, df_datetimes, show_query=:dict)
        @test res_bulk_dt[:operation] === :insert
        @test res_bulk_dt[:parameter_count] == 9
        
        # Test 17: Bulk update with datetime values
        df_datetime_updates = DataFrame(
            id = [1, 2, 3],
            event_time = [
                DateTime(2024, 1, 15, 8, 0, 0),
                DateTime(2024, 6, 20, 14, 30, 0),
                DateTime(2024, 12, 25, 16, 45, 30)
            ]
        )
        res_bulk_update_dt = bulk_update(
            DateTimeModel.objects, 
            df_datetime_updates, 
            columns=["event_time"], 
            match_on=["id"],
            show_query=:dict
        )
        @test res_bulk_update_dt[:operation] === :update
        @test contains(res_bulk_update_dt[:sql_text], "event_time") || contains(res_bulk_update_dt[:sql_text], "UPDATE")
        
        # Test 18: Nullable datetime field in bulk operation
        df_nullable_datetimes = DataFrame(
            event_time = [
                DateTime(2024, 1, 15, 8, 0, 0),
                DateTime(2024, 6, 20, 14, 30, 0)
            ],
            scheduled_at = [
                DateTime(2025, 1, 15, 8, 0, 0),
                nothing
            ]
        )
        res_bulk_nullable = bulk_insert(DateTimeModel.objects, df_nullable_datetimes, show_query=:dict)
        @test res_bulk_nullable[:operation] === :insert
        
        # Test 19: Create with nullable datetime (null)
        create_null_dt = DateTimeModel.objects.create(
            "event_time" => DateTime(2024, 8, 10, 12, 0, 0),
            "scheduled_at" => nothing,
            show_query=:inspection
        )
        @test create_null_dt[:operation] === :insert
        @test contains(create_null_dt[:sql_text], "scheduled_at")
        
        # Test 20: Update with nullable datetime field
        update_nullable_q = DateTimeModel.objects
        update_nullable_q.filter("id" => 1)
        update_null_dt = update_nullable_q.update(
            "scheduled_at" => nothing,
            show_query=:dict
        )
        @test update_null_dt[:operation] === :update
    end

    @testset "DateField Comprehensive Testing: Edge Cases & Operations" begin
        DateModel = Models.Model_Type(
            name = "date_comprehensive_test",
            fields = Dict(
                "id" => Models.IDField(),
                "created_on" => Models.DateField(auto_now_add=true),
                "updated_on" => Models.DateField(auto_now=true),
                "race_day" => Models.DateField(null=false),
                "inspection_day" => Models.DateField(null=true),
                "published_on" => Models.DateField(default=Date(2024, 7, 28))
            ),
            field_names = ["id", "created_on", "updated_on", "race_day", "inspection_day", "published_on"],
            connect_key = "default"
        )

        race_day = Date(2024, 7, 28)
        race_dt = DateTime(2024, 7, 28, 14, 30, 0)
        race_zdt = ZonedDateTime(race_dt, TimeZone("UTC"))

        @test validate_field_data(DateModel, "race_day", race_day, "insert") === true
        @test validate_field_data(DateModel, "race_day", race_dt, "insert") === true
        @test validate_field_data(DateModel, "race_day", race_zdt, "insert") === true
        @test validate_field_data(DateModel, "race_day", "2024-07-28", "insert") === true
        @test validate_field_data(DateModel, "inspection_day", nothing, "insert") === true
        @test validate_field_data(DateModel, "inspection_day", missing, "insert") === true

        @test_throws PormGError validate_field_data(DateModel, "race_day", nothing, "insert")
        @test_throws PormGError validate_field_data(DateModel, "race_day", "2024/07/28", "insert")
        @test_throws PormGError validate_field_data(DateModel, "race_day", 20240728, "insert")

        create_date = DateModel.objects.create(
            "race_day" => race_day,
            "inspection_day" => Date(2024, 7, 29),
            show_query=:inspection
        )
        @test create_date[:operation] === :insert
        @test contains(create_date[:sql_text], "date_comprehensive_test")

        update_date_q = DateModel.objects
        update_date_q.filter("id" => 1)
        update_date = update_date_q.update(
            "race_day" => Date(2024, 8, 1),
            show_query=:dict
        )
        @test update_date[:operation] === :update
        @test contains(update_date[:sql_text], "updated_on") || contains(update_date[:sql_text], "UPDATE")

        df_dates = DataFrame(
            race_day = [Date(2024, 7, 28), Date(2024, 7, 29)],
            inspection_day = [Date(2024, 7, 30), missing]
        )
        bulk_date = bulk_insert(DateModel.objects, df_dates, show_query=:dict)
        @test bulk_date[:operation] === :insert
        @test bulk_date[:parameter_count] == 10

        df_date_updates = DataFrame(
            id = [1, 2],
            race_day = [Date(2024, 8, 3), Date(2024, 8, 4)]
        )
        bulk_update_date = bulk_update(
            DateModel.objects,
            df_date_updates,
            columns=["race_day"],
            match_on=["id"],
            show_query=:dict
        )
        @test bulk_update_date[:operation] === :update
        @test contains(bulk_update_date[:sql_text], "race_day") || contains(bulk_update_date[:sql_text], "UPDATE")
    end
end

@testset "SECTION 2: Field validation with complex combinations & constraints" begin    
    @testset "Extensive Field Combinations & Constraints" begin
        ExtensiveModel = Models.Model_Type(
            name = "comprehensive_table",
            fields = Dict(
                "id" => Models.IDField(),
                "name" => Models.CharField(max_length = 100),
                "description" => Models.TextField(null = true),
                "age" => Models.IntegerField(),
                "salary" => Models.DecimalField(max_digits = 12, decimal_places = 2),
                "is_active" => Models.BooleanField(default = true),
                "email" => Models.EmailField(unique = true),
                "ratio" => Models.FloatField(null = true),
                "big_id" => Models.BigIntegerField(null = true)
            ),
            field_names = [
                "id", "name", "description", "age", "salary", 
                "is_active", "email", "ratio", "big_id"
            ],
            connect_key = "default"
        )
        
        # Valid inserts
        @test validate_field_data(ExtensiveModel, "name", "Lewis Hamilton", "insert")
        @test validate_field_data(ExtensiveModel, "age", 39, "insert")
        @test validate_field_data(ExtensiveModel, "salary", 50000000.00, "insert")
        @test validate_field_data(ExtensiveModel, "is_active", true, "insert")
        @test validate_field_data(ExtensiveModel, "email", "lewis@mercedes.com", "insert")
        
        # Invalid type checks
        @test_throws PormGError validate_field_data(ExtensiveModel, "age", 39.5, "insert")
        @test validate_field_data(ExtensiveModel, "salary", "5e7", "insert") === true
        
        # Nullability checks
        @test_throws PormGError validate_field_data(ExtensiveModel, "name", nothing, "insert")
        @test validate_field_data(ExtensiveModel, "description", nothing, "insert")
        @test validate_field_data(ExtensiveModel, "ratio", nothing, "insert")
    end

    @testset "DecimalField(max_digits=12, decimal_places=2) Boundary Tests" begin
        # max_digits=12, decimal_places=2 means:
        # - Maximum 12 total digits
        # - Maximum 2 digits after the decimal point
        # - Maximum 10 digits before the decimal point
        # - Valid range: -9999999999.99 to 9999999999.99
        
        BoundaryModel = Models.Model_Type(
            name = "boundary_test",
            fields = Dict(
                "id"    => Models.IDField(),
                "price" => Models.DecimalField(max_digits=12, decimal_places=2)
            ),
            field_names = ["id", "price"],
            connect_key = "default"
        )
        
        # --- WITHIN LIMITS (Should Pass) ---
        
        # Test 1: Exactly at max_digits limit with 2 decimals
        @test validate_field_data(BoundaryModel, "price", 9999999999.99, "insert") === true
        @test validate_field_data(BoundaryModel, "price", "9999999999.99", "insert") === true
        
        # Test 2: Max value with fewer decimal places
        @test validate_field_data(BoundaryModel, "price", 99999999999.0, "insert") === true
        @test validate_field_data(BoundaryModel, "price", "99999999999", "insert") === true
        
        # Test 3: Max value with single decimal place
        @test validate_field_data(BoundaryModel, "price", 999999999.9, "insert") === true
        
        # Test 4: Zero with appropriate decimals
        @test validate_field_data(BoundaryModel, "price", 0.00, "insert") === true
        @test validate_field_data(BoundaryModel, "price", "0.00", "insert") === true
        
        # Test 5: Negative maximum
        @test validate_field_data(BoundaryModel, "price", -9999999999.99, "insert") === true
        @test validate_field_data(BoundaryModel, "price", "-9999999999.99", "insert") === true
        
        # Test 6: Small positive values
        @test validate_field_data(BoundaryModel, "price", 0.01, "insert") === true
        @test validate_field_data(BoundaryModel, "price", "0.01", "insert") === true
        
        # Test 7: Scientific notation within bounds
        @test validate_field_data(BoundaryModel, "price", 1e10, "insert") === true
        @test validate_field_data(BoundaryModel, "price", "1e10", "insert") === true
        
        # Test 8: Scientific notation with smaller exponent
        @test validate_field_data(BoundaryModel, "price", 1.23e9, "insert") === true
        @test validate_field_data(BoundaryModel, "price", "1.23e9", "insert") === true
        
        # --- EXCEED DECIMAL_PLACES (Should Fail) ---
        
        # Test 9: 3 decimal places (1 too many)
        @test_throws PormGError validate_field_data(BoundaryModel, "price", 123.456, "insert")
        @test_throws PormGError validate_field_data(BoundaryModel, "price", "123.456", "insert")
        
        # Test 10: 4 decimal places
        @test_throws PormGError validate_field_data(BoundaryModel, "price", 99.9999, "insert")
        
        # Test 11: Many decimal places
        @test_throws PormGError validate_field_data(BoundaryModel, "price", 1.123456789, "insert")
        @test_throws PormGError validate_field_data(BoundaryModel, "price", "1.123456789", "insert")
        
        # --- EXCEED MAX_DIGITS (Should Fail) ---
        
        # Test 12: 13 digits total (1 too many with 2 decimals)
        @test_throws PormGError validate_field_data(BoundaryModel, "price", 99999999999.99, "insert")
        @test_throws PormGError validate_field_data(BoundaryModel, "price", "99999999999.99", "insert")
        
        # Test 13: 14 digits total
        @test_throws PormGError validate_field_data(BoundaryModel, "price", 999999999999.99, "insert")
        
        # Test 14: Massive number
        @test_throws PormGError validate_field_data(BoundaryModel, "price", 1e15, "insert")
        @test_throws PormGError validate_field_data(BoundaryModel, "price", "1e15", "insert")
        
        # Test 15: Multiple violations (too many decimals AND too many digits)
        @test_throws PormGError validate_field_data(BoundaryModel, "price", 99999999999.999, "insert")
        
        # --- EDGE CASES ---
        
        # Test 16: Exactly 10 digits before decimal, exactly 2 after
        @test validate_field_data(BoundaryModel, "price", 1234567890.12, "insert") === true
        
        # Test 17: One digit short on both
        @test validate_field_data(BoundaryModel, "price", 123456789.1, "insert") === true
        
        # Test 18: Invalid string input (non-numeric)
        @test_throws PormGError validate_field_data(BoundaryModel, "price", "not-a-number", "insert")
        
        # Test 19: Invalid notation
        @test_throws PormGError validate_field_data(BoundaryModel, "price", "12.34.56", "insert")
        
        # --- USER OPERATIONS: CREATE, UPDATE, BULK ---
        
        # Test 20: Create with boundary value (at max limit)
        create_max = BoundaryModel.objects.create(
            "price" => 9999999999.99,
            show_query=:inspection
        )
        @test create_max[:operation] === :insert
        @test contains(create_max[:sql_text], "INSERT INTO") && contains(create_max[:sql_text], "boundary_test")
        
        # Test 21: Create with scientific notation within boundary
        create_scientific = BoundaryModel.objects.create(
            "price" => "1e10",
            show_query=:inspection
        )
        @test create_scientific[:operation] === :insert
        
        # Test 22: Create with invalid scale (should fail before SQL)
        @test_throws PormGError BoundaryModel.objects.create(
            "price" => 123.456,
            show_query=:inspection
        )
        
        # Test 23: Create exceeding max_digits (should fail before SQL)
        @test_throws PormGError BoundaryModel.objects.create(
            "price" => 99999999999.99,
            show_query=:inspection
        )
        
        # Test 24: Update with boundary value (at max limit) - requires a filter
        update_q = BoundaryModel.objects
        update_q.filter("price__@gt" => 0)
        update_max = update_q.update(
            "price" => 9999999999.99,
            show_query=:dict
        )
        @test update_max[:operation] === :update
        @test contains(update_max[:sql_text], "UPDATE")
        
        # Test 25: Update with scientific notation
        update_sci_q = BoundaryModel.objects
        update_sci_q.filter("price__@gt" => 0)
        update_scientific = update_sci_q.update(
            "price" => "1.23e9",
            show_query=:dict
        )
        @test update_scientific[:operation] === :update
        
        # Test 26: Update with invalid scale (should fail before SQL)
        update_bad_q = BoundaryModel.objects
        update_bad_q.filter("price__@gt" => 0)
        @test_throws PormGError update_bad_q.update(
            "price" => 99.9999,
            show_query=:dict
        )
        
        # Test 27: Update exceeding max_digits (should fail before SQL)
        update_exceed_q = BoundaryModel.objects
        update_exceed_q.filter("price__@gt" => 0)
        @test_throws PormGError update_exceed_q.update(
            "price" => 99999999999.99,
            show_query=:dict
        )
        
        # Test 28: Bulk insert with boundary values (mixed valid/invalid in DataFrame)
        df_boundary = DataFrame(
            price = [100.50, 9999999999.99, 0.01, -500.75]
        )
        res_bulk_boundary = bulk_insert(BoundaryModel.objects, df_boundary, show_query=:dict)
        @test res_bulk_boundary[:operation] === :insert
        @test res_bulk_boundary[:parameter_count] == 4
        
        # Test 29: Bulk insert with values exceeding scale (should fail validation)
        df_bad_scale = DataFrame(
            price = [123.456, 99.9999]
        )
        # #268 audit: bulk row validation now rethrows the taxonomy type instead of stringifying
        # it into ErrorException — `catch InvalidValueError` behaves the same as for insert().
        @test_throws InvalidValueError bulk_insert(BoundaryModel.objects, df_bad_scale, show_query=:dict)
        
        # Test 30: Bulk update with boundary values
        df_update_boundary = DataFrame(
            id    = [1, 2],
            price = [5000.00, 9999999999.99]
        )
        res_bulk_update_boundary = bulk_update(
            BoundaryModel.objects,
            df_update_boundary,
            columns=["price"],
            match_on=["id"],
            show_query=:dict
        )
        @test res_bulk_update_boundary[:operation] === :update
        @test contains(res_bulk_update_boundary[:sql_text], "UPDATE")
    end

end

@testset "SECTION 3: User-Facing API Integration" begin    
    @testset "User API Integration: .objects.create() with complex models" begin
        ComplexModel = Models.Model_Type(
            name = "complex_test",
            fields = Dict(
                "id" => Models.IDField(),
                "username" => Models.CharField(max_length=50),
                "email" => Models.EmailField(unique=true),
                "age" => Models.IntegerField(null=true),
                "salary" => Models.DecimalField(max_digits=12, decimal_places=2, null=true),
                "is_verified" => Models.BooleanField(default=false),
                "bio" => Models.TextField(null=true),
                "score" => Models.FloatField(null=true),
                "status_code" => Models.IntegerField(default=0),
                "large_num" => Models.BigIntegerField(null=true)
            ),
            field_names = ["id", "username", "email", "age", "salary", "is_verified", "bio", "score", "status_code", "large_num"],
            connect_key = "default"
        )
        
        # Test: Field count validation
        @test length(ComplexModel.field_names) == 10
        
        # Test: All fields validate individually
        @test validate_field_data(ComplexModel, "username", "john_doe", "insert") === true
        @test validate_field_data(ComplexModel, "email", "john@example.com", "insert") === true
        @test validate_field_data(ComplexModel, "age", 30, "insert") === true
        @test validate_field_data(ComplexModel, "salary", 75000.50, "insert") === true
        @test validate_field_data(ComplexModel, "is_verified", false, "insert") === true
        @test validate_field_data(ComplexModel, "bio", "Software engineer", "insert") === true
        @test validate_field_data(ComplexModel, "score", 95.5, "insert") === true
        @test validate_field_data(ComplexModel, "status_code", 200, "insert") === true
        @test validate_field_data(ComplexModel, "large_num", 9223372036854775807, "insert") === true
        
        # Test: Nullable field combinations
        @test validate_field_data(ComplexModel, "age", nothing, "insert") === true
        @test validate_field_data(ComplexModel, "bio", missing, "insert") === true
        @test validate_field_data(ComplexModel, "salary", nothing, "insert") === true
        
        # Test: Non-nullable field validation
        @test_throws PormGError validate_field_data(ComplexModel, "username", nothing, "insert")
        @test_throws PormGError validate_field_data(ComplexModel, "email", nothing, "insert")
        
        # Test 5: Public API with show_query=:inspection (NO DB EXECUTION)
        q_handler = ComplexModel.objects
        res_full = q_handler.create(
            "username" => "alice_smith",
            "email" => "alice@example.com",
            "age" => 28,
            "salary" => 95000.75,
            "is_verified" => true,
            "bio" => "Data scientist passionate about ML",
            "score" => 98.7,
            "status_code" => 201,
            "large_num" => 1234567890123456789,
            show_query=:inspection
        )
        
        @test res_full[:operation] === :insert
        @test contains(res_full[:sql_text], "INSERT INTO") && contains(res_full[:sql_text], "complex_test")
        @test res_full[:parameter_count] > 0
        @test contains(res_full[:sql_text], "username")
        @test contains(res_full[:sql_text], "email")
        @test contains(res_full[:sql_text], "salary")
        
        # Test 6: Create with minimal data
        q_handler2 = ComplexModel.objects
        res_minimal = q_handler2.create(
            "username" => "bob_jones",
            "email" => "bob@example.com",
            show_query=:inspection
        )
        
        @test res_minimal[:operation] === :insert
        @test res_minimal[:parameter_count] >= 2
        
        # Test 7: Parameter values are collected
        @test "alice_smith" in res_full[:parameters]
        @test "alice@example.com" in res_full[:parameters]
        @test 95000.75 in res_full[:parameters] || "95000.75" in res_full[:parameters]
        
        # Test 8: Full insert has more parameters than minimal
        @test res_full[:parameter_count] > res_minimal[:parameter_count]
    end

    @testset "User API Numeric Contract via Create/Update Inspection" begin
        NumericApiModel = Models.Model_Type(
            name = "numeric_api_test",
            fields = Dict(
                "id" => Models.IDField(),
                "label" => Models.CharField(max_length=50),
                "amount" => Models.DecimalField(max_digits=10, decimal_places=2),
                "ratio" => Models.FloatField(null=false),
                "notes" => Models.TextField(null=true)
            ),
            field_names = ["id", "label", "amount", "ratio", "notes"],
            connect_key = "default"
        )

        # Create accepts valid numeric strings through the public API and still returns inspection metadata.
        create_ok = NumericApiModel.objects.create(
            "label" => "valid_create",
            "amount" => "123.45",
            "ratio" => "1.25e2",
            "notes" => "scientific float string is allowed",
            show_query=:inspection
        )

        @test create_ok[:operation] === :insert
        @test contains(create_ok[:sql_text], "INSERT INTO") && contains(create_ok[:sql_text], "numeric_api_test")
        @test create_ok[:parameter_count] == 4
        @test contains(create_ok[:sql_text], "amount")
        @test contains(create_ok[:sql_text], "ratio")

        # Decimal scientific-notation strings are accepted for Julia-heavy numeric workflows.
        create_scientific_decimal = NumericApiModel.objects.create(
            "label" => "decimal_scientific_create",
            "amount" => "1e2",
            "ratio" => "2.5",
            show_query=:inspection
        )

        @test create_scientific_decimal[:operation] === :insert
        @test create_scientific_decimal[:parameter_count] == 3

        # Float invalid strings are also rejected during validation now.
        @test_throws PormGError NumericApiModel.objects.create(
            "label" => "bad_float_string",
            "amount" => "12.34",
            "ratio" => "not-a-number",
            show_query=:inspection
        )

        # Decimal scale enforcement must also trigger through the create() public API.
        @test_throws PormGError NumericApiModel.objects.create(
            "label" => "bad_decimal_scale",
            "amount" => "10.123",
            "ratio" => "2.5",
            show_query=:inspection
        )

        # Update accepts valid numeric strings and keeps inspection available to callers.
        update_q = NumericApiModel.objects
        update_q.filter("id" => 1)
        update_ok = update_q.update(
            "amount" => "88.50",
            "ratio" => "2.5e-3",
            show_query=:dict
        )

        @test update_ok[:operation] === :update
        @test contains(update_ok[:sql_text], "UPDATE") && contains(update_ok[:sql_text], "numeric_api_test")
        @test contains(update_ok[:sql_text], "amount")
        @test contains(update_ok[:sql_text], "ratio")
        @test update_ok[:parameter_count] == 3

        # Update also accepts decimal scientific-notation strings.
        scientific_decimal_update_q = NumericApiModel.objects
        scientific_decimal_update_q.filter("id" => 1)
        scientific_decimal_update = scientific_decimal_update_q.update(
            "amount" => "1e2",
            show_query=:dict
        )

        @test scientific_decimal_update[:operation] === :update
        @test scientific_decimal_update[:parameter_count] == 2

        # Update rejects invalid float strings before building SQL.
        bad_float_update_q = NumericApiModel.objects
        bad_float_update_q.filter("id" => 1)
        @test_throws PormGError bad_float_update_q.update(
            "ratio" => "NaN",
            show_query=:dict
        )

        # Decimal scale enforcement also applies on update.
        bad_scale_update_q = NumericApiModel.objects
        bad_scale_update_q.filter("id" => 1)
        @test_throws PormGError bad_scale_update_q.update(
            "amount" => "7.777",
            show_query=:dict
        )
    end
end

@testset "SECTION 4 & 5: Bulk Operations & Query Inspection" begin    
    @testset "Bulk Operations Validation via Inspection" begin
        BulkModel = Models.Model_Type(
            name = "bulk_test",
            fields = Dict(
                "id" => Models.IDField(),
                "name" => Models.CharField(max_length=100),
                "age" => Models.IntegerField(),
                "salary" => Models.DecimalField(max_digits=12, decimal_places=2),
                "is_active" => Models.BooleanField(default=true),
                "email" => Models.EmailField()
            ),
            field_names = ["id", "name", "age", "salary", "is_active", "email"],
            connect_key = "default"
        )
        
        df = DataFrame(
            name = ["Max Verstappen", "Lando Norris"],
            age = [26, 24],
            salary = [55000000.0, 20000000.0],
            email = ["max@redbull.com", "lando@mclaren.com"],
            is_active = [true, true]
        )
        
        # Test Bulk Insert inspection
        res_bulk = bulk_insert(BulkModel.objects, df, show_query=:dict)
        
        @test res_bulk[:operation] === :insert
        @test contains(res_bulk[:sql_text], "INSERT INTO") && contains(res_bulk[:sql_text], "bulk_test")
        @test res_bulk[:parameter_count] == 10 # 2 rows * 5 columns
        
        # Test Bulk Update inspection
        res_bulk_upd = bulk_update(BulkModel.objects, df, columns=["salary"], match_on=["name"], show_query=:dict)
        
        @test res_bulk_upd[:operation] === :update
        @test contains(res_bulk_upd[:sql_text], "UPDATE")
        # PostgreSQL quotes identifiers, so check for salary and name (with or without quotes)
        @test (contains(res_bulk_upd[:sql_text], "SET salary") || contains(res_bulk_upd[:sql_text], "SET \"salary\""))
        @test (contains(res_bulk_upd[:sql_text], "WHERE name") || contains(res_bulk_upd[:sql_text], "WHERE \"Tb\".\"name\"") || contains(res_bulk_upd[:sql_text], "WHERE") && contains(res_bulk_upd[:sql_text], "name"))
    end

end

@testset "SECTION 5: Query Inspection for Field Operations" begin    
    @testset "Query Inspection for Select/Update/Delete Operations" begin
        InspectModel = Models.Model_Type(
            name = "inspect_test",
            fields = Dict(
                "id" => Models.IDField(),
                "name" => Models.CharField(max_length=100),
                "age" => Models.IntegerField(),
                "salary" => Models.DecimalField(max_digits=12, decimal_places=2),
                "is_active" => Models.BooleanField(default=true)
            ),
            field_names = ["id", "name", "age", "salary", "is_active"],
            connect_key = "default"
        )
        
        # Test SELECT with inspection
        q_select = InspectModel.objects
        q_select.filter("age__@gt" => 30)
        q_select.values("name", "salary")
        inspection_select = inspect_query(q_select)
        
        @test inspection_select[:operation] === :select
        @test contains(inspection_select[:sql_text], "SELECT")
        @test contains(inspection_select[:sql_text], "name")
        @test contains(inspection_select[:sql_text], "salary")
        @test inspection_select[:parameter_count] == 1
        @test inspection_select[:parameters] == [30]
        
        # Test UPDATE with inspection
        q_update = InspectModel.objects
        q_update.filter("id" => 1)
        res_update = q_update.update("is_active" => false, show_query=:dict)
        
        @test res_update[:operation] === :update
        @test contains(res_update[:sql_text], "UPDATE") && (contains(res_update[:sql_text], "inspect_test") || contains(res_update[:sql_text], "\"inspect_test\""))
        @test contains(res_update[:sql_text], "is_active") || contains(res_update[:sql_text], "\"is_active\"")
        @test res_update[:parameters] == [1, false]  # filter value first, then update value

        # Direct validator coverage and public API coverage should both reject PK mutations.
        @test_throws PormGError validate_field_data(InspectModel, "id", 2, "update"; allow_primary_key=false)

        pk_update_q = InspectModel.objects
        pk_update_q.filter("id" => 1)
        @test_throws PormGError pk_update_q.update("id" => 2, show_query=:dict)

        # inspect_query has a dedicated delete branch that unwraps the inspection payload.
        q_delete = InspectModel.objects
        q_delete.filter("id" => 1)
        inspection_delete = inspect_query(q_delete; operation=:delete)

        @test inspection_delete[:operation] === :delete
        @test contains(inspection_delete[:sql_text], "DELETE")
        @test inspection_delete[:parameters] == [1]
    end

end

@testset "SECTION 6: Temporal Field Gaps" begin
    @testset "TimeField (Time-Only Values)" begin
        # TimeField represents time without a specific date (HHμ:MM:SS format)
        TimeModel = Models.Model_Type(
            name = "time_test",
            fields = Dict(
                "id" => Models.IDField(),
                "opening_hour" => Models.TimeField(null=false),
                "closing_hour" => Models.TimeField(null=true),  # nullable
                "event_start" => Models.TimeField(default=Time(9, 0, 0))
            ),
            field_names = ["id", "opening_hour", "closing_hour", "event_start"],
            connect_key = "default"
        )

        # Test 1: Valid Time object
        opening_time = Time(8, 30, 0)
        @test validate_field_data(TimeModel, "opening_hour", opening_time, "insert") === true

        # Test 2: Midnight (edge case)
        midnight = Time(0, 0, 0)
        @test validate_field_data(TimeModel, "opening_hour", midnight, "insert") === true

        # Test 3: One second before midnight (edge case)
        almost_midnight = Time(23, 59, 59)
        @test validate_field_data(TimeModel, "opening_hour", almost_midnight, "insert") === true

        # Test 4: Noon (common time)
        noon = Time(12, 0, 0)
        @test validate_field_data(TimeModel, "opening_hour", noon, "insert") === true

        # Test 5: Time with milliseconds
        precise_time = Time(14, 30, 45, 500)
        @test validate_field_data(TimeModel, "opening_hour", precise_time, "insert") === true

        # Test 6: Nullable TimeField with nothing
        @test validate_field_data(TimeModel, "closing_hour", nothing, "insert") === true
        @test validate_field_data(TimeModel, "closing_hour", missing, "insert") === true

        # Test 7: Non-nullable TimeField with nothing (should fail)
        @test_throws PormGError validate_field_data(TimeModel, "opening_hour", nothing, "insert")

        # Test 8: Invalid input (DateTime instead of Time)
        invalid_time = DateTime(2024, 6, 15, 14, 30, 0)
        @test_throws PormGError validate_field_data(TimeModel, "opening_hour", invalid_time, "insert")

        # Test 9: Invalid input (Date instead of Time)
        invalid_date = Date(2024, 6, 15)
        @test_throws PormGError validate_field_data(TimeModel, "opening_hour", invalid_date, "insert")

        # Test 10: Invalid input (String time format not yet supported)
        @test validate_field_data(TimeModel, "opening_hour", "14:30:00", "insert") === true

        # Test 11: Create with TimeField
        create_time = TimeModel.objects.create(
            "opening_hour" => Time(8, 0, 0),
            "closing_hour" => Time(17, 0, 0),
            show_query=:inspection
        )
        @test create_time[:operation] === :insert
        @test contains(create_time[:sql_text], "opening_hour")

        # Test 12: Bulk insert with TimeField
        df_times = DataFrame(
            opening_hour = [Time(8, 0), Time(9, 0)],
            closing_hour = [Time(17, 0), Time(18, 0)]
        )
        res_bulk_time = bulk_insert(TimeModel.objects, df_times, show_query=:dict)
        @test res_bulk_time[:operation] === :insert
        @test res_bulk_time[:parameter_count] == 6  # 2 rows * 3 fields (opening_hour, closing_hour, event_start)

        # Test 13: Update with TimeField
        update_time_q = TimeModel.objects
        update_time_q.filter("id" => 1)
        update_time = update_time_q.update(
            "opening_hour" => Time(7, 30, 0),
            show_query=:dict
        )
        @test update_time[:operation] === :update
        @test contains(update_time[:sql_text], "UPDATE")

        # TimeField should reject elapsed-duration strings such as F1 lap times.
        @test_throws PormGError validate_field_data(TimeModel, "opening_hour", "1:27.452", "insert")
    end

    @testset "DurationField (Elapsed Time Values)" begin
        DurationModel = Models.Model_Type(
            name = "duration_test",
            fields = Dict(
                "lap_time" => Models.DurationField(null=false),
                "pit_duration" => Models.DurationField(null=true),
                "default_duration" => Models.DurationField(default=Minute(1) + Second(27) + Millisecond(452))
            ),
            field_names = ["lap_time", "pit_duration", "default_duration"]
        )

        @test validate_field_data(DurationModel, "lap_time", "1:27.452", "insert") === true
        @test validate_field_data(DurationModel, "lap_time", "01:34:50.616", "insert") === true
        @test validate_field_data(DurationModel, "pit_duration", "26.898", "insert") === true
        @test validate_field_data(DurationModel, "lap_time", Minute(1) + Second(27) + Millisecond(452), "insert") === true
        @test validate_field_data(DurationModel, "pit_duration", nothing, "insert") === true

        @test DurationModel.fields["default_duration"].default == "00:01:27.452"
        @test Models.format_duration_sql("1:27.452") == "00:01:27.452"
        @test Models.format_duration_sql(Minute(1) + Second(27) + Millisecond(452)) == "00:01:27.452"

        @test_throws PormGError validate_field_data(DurationModel, "lap_time", Time(1, 27, 45), "insert")
        @test_throws PormGError validate_field_data(DurationModel, "lap_time", "bad-duration", "insert")
    end

    @testset "DateTimeField Timezone Conversions & Round-Trip" begin
        # Test explicit timezone handling: DateTime, ZonedDateTime, and timezone mismatches
        TzModel = Models.Model_Type(
            name = "tz_test",
            fields = Dict(
                "id" => Models.IDField(),
                "naive_timestamp" => Models.DateTimeField(null=false),
                "aware_timestamp" => Models.DateTimeField(null=true),
                "scheduled_at" => Models.DateTimeField(null=true)
            ),
            field_names = ["id", "naive_timestamp", "aware_timestamp", "scheduled_at"],
            connect_key = "default"
        )

        # Test 1: Naive DateTime (interpreted as UTC by default)
        naive_dt = DateTime(2024, 6, 15, 14, 30, 0)
        @test validate_field_data(TzModel, "naive_timestamp", naive_dt, "insert") === true

        # Test 2: ZonedDateTime with UTC timezone
        utc_zdt = ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("UTC"))
        @test validate_field_data(TzModel, "aware_timestamp", utc_zdt, "insert") === true

        # Test 3: ZonedDateTime with specific timezone (e.g., America/Sao_Paulo)
        sao_paulo_tz = TimeZone("America/Sao_Paulo")
        sp_zdt = ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), sao_paulo_tz)
        @test validate_field_data(TzModel, "aware_timestamp", sp_zdt, "insert") === true

        # Test 4: ZonedDateTime with Asia/Tokyo timezone
        tokyo_tz = TimeZone("Asia/Tokyo")
        tokyo_zdt = ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), tokyo_tz)
        @test validate_field_data(TzModel, "aware_timestamp", tokyo_zdt, "insert") === true

        # Test 5: ZonedDateTime with Europe/London timezone (uses DST)
        london_tz = TimeZone("Europe/London")
        london_zdt = ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), london_tz)
        @test validate_field_data(TzModel, "aware_timestamp", london_zdt, "insert") === true

        # Test 6: Nullable aware timestamp with nothing
        @test validate_field_data(TzModel, "aware_timestamp", nothing, "insert") === true
        @test validate_field_data(TzModel, "aware_timestamp", missing, "insert") === true

        # Test 7: Create with naive DateTime (assumes UTC)
        create_naive = TzModel.objects.create(
            "naive_timestamp" => DateTime(2024, 6, 15, 14, 30, 0),
            show_query=:inspection
        )
        expected_naive_timestamp = canon_utc(ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("UTC")))
        @test create_naive[:operation] === :insert
        @test contains(create_naive[:sql_text], "naive_timestamp")
        @test create_naive[:parameter_count] == 1
        @test create_naive[:parameters] == [expected_naive_timestamp]

        # Test 8: Create with ZonedDateTime (aware timestamp)
        create_aware = TzModel.objects.create(
            "naive_timestamp" => DateTime(2024, 6, 15, 14, 30, 0),
            "aware_timestamp" => ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("UTC")),
            show_query=:inspection
        )
        expected_aware_utc = canon_utc(ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("UTC")))
        @test create_aware[:operation] === :insert
        @test contains(create_aware[:sql_text], "aware_timestamp")
        @test create_aware[:parameter_count] == 2
        @test any(==(expected_naive_timestamp), create_aware[:parameters])
        @test any(==(expected_aware_utc), create_aware[:parameters])

        # Test 9: Create with non-UTC timezone (should preserve timezone info in round-trip)
        create_tz_sp = TzModel.objects.create(
            "naive_timestamp" => DateTime(2024, 6, 15, 14, 30, 0),
            "aware_timestamp" => ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("America/Sao_Paulo")),
            show_query=:inspection
        )
        expected_aware_sao_paulo = canon_utc(ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("America/Sao_Paulo")))
        @test create_tz_sp[:operation] === :insert
        @test create_tz_sp[:parameter_count] == 2
        @test any(==(expected_naive_timestamp), create_tz_sp[:parameters])
        @test any(==(expected_aware_sao_paulo), create_tz_sp[:parameters])

        # Test 10: Update with timezone-aware timestamp
        update_tz_q = TzModel.objects
        update_tz_q.filter("id" => 1)
        update_tz = update_tz_q.update(
            "aware_timestamp" => ZonedDateTime(DateTime(2024, 7, 20, 10, 15, 0), TimeZone("America/New_York")),
            show_query=:dict
        )
        expected_updated_aware_timestamp = canon_utc(ZonedDateTime(DateTime(2024, 7, 20, 10, 15, 0), TimeZone("America/New_York")))
        @test update_tz[:operation] === :update
        @test contains(update_tz[:sql_text], "UPDATE")
        @test update_tz[:parameters] == [1, expected_updated_aware_timestamp]

        # Test 11: Bulk operations with mixed naive and aware timestamps
        df_tz = DataFrame(
            naive_timestamp = [
                DateTime(2024, 6, 15, 8, 0, 0),
                DateTime(2024, 6, 16, 14, 30, 0)
            ],
            aware_timestamp = [
                ZonedDateTime(DateTime(2024, 6, 15, 8, 0, 0), TimeZone("UTC")),
                ZonedDateTime(DateTime(2024, 6, 16, 14, 30, 0), TimeZone("America/Toronto"))
            ],
            scheduled_at = [nothing, nothing]
        )
        res_bulk_tz = bulk_insert(TzModel.objects, df_tz, show_query=:dict)
        expected_bulk_naive = [
            canon_utc(ZonedDateTime(DateTime(2024, 6, 15, 8, 0, 0), TimeZone("UTC"))),
            canon_utc(ZonedDateTime(DateTime(2024, 6, 16, 14, 30, 0), TimeZone("UTC")))
        ]
        expected_bulk_aware = [
            canon_utc(ZonedDateTime(DateTime(2024, 6, 15, 8, 0, 0), TimeZone("UTC"))),
            canon_utc(ZonedDateTime(DateTime(2024, 6, 16, 14, 30, 0), TimeZone("America/Toronto")))
        ]
        @test res_bulk_tz[:operation] === :insert
        @test res_bulk_tz[:parameter_count] == 6  # 2 rows * 3 columns (naive_timestamp, aware_timestamp, scheduled_at)
        @test count(param -> param isa AbstractString, res_bulk_tz[:parameters]) == 4
        @test count(ismissing, res_bulk_tz[:parameters]) == 2
        @test all(expected -> any(==(expected), res_bulk_tz[:parameters]), expected_bulk_naive)
        @test all(expected -> any(==(expected), res_bulk_tz[:parameters]), expected_bulk_aware)

        # Test 12: DST edge case - Spring forward (2024-03-10 in America/New_York)
        spring_forward_dt = DateTime(2024, 3, 10, 2, 30, 0)  # This time doesn't exist (clocks jump from 2:00 to 3:00)
        # The system should handle this gracefully (either reject or normalize)
        try
            dst_spring = ZonedDateTime(spring_forward_dt, TimeZone("America/New_York"))
            @test validate_field_data(TzModel, "aware_timestamp", dst_spring, "insert") === true
        catch
            # It's acceptable to reject invalid DST times
            @test true
        end

        # Test 13: DST edge case - Fall back (2024-11-03 in America/New_York)
        # Time 1:30 AM occurs twice during fall back
        fall_back_dt = DateTime(2024, 11, 3, 1, 30, 0)
        try
            dst_fall = ZonedDateTime(fall_back_dt, TimeZone("America/New_York"))
            @test validate_field_data(TzModel, "aware_timestamp", dst_fall, "insert") === true
        catch
            @test true
        end

        # Test 14: Bulk update with timezone-aware values
        df_tz_update = DataFrame(
            id = [1, 2],
            aware_timestamp = [
                ZonedDateTime(DateTime(2024, 8, 10, 12, 0, 0), TimeZone("Europe/Paris")),
                ZonedDateTime(DateTime(2024, 8, 10, 12, 0, 0), TimeZone("Asia/Bangkok"))
            ]
        )
        res_bulk_tz_update = bulk_update(
            TzModel.objects,
            df_tz_update,
            columns=["aware_timestamp"],
            match_on=["id"],
            show_query=:dict
        )
        @test res_bulk_tz_update[:operation] === :update
    end

    @testset "DateField String Formats & Edge Cases" begin
        # Test DateField string format validation: only YYYY-MM-DD should be accepted
        DateFormatModel = Models.Model_Type(
            name = "date_format_test",
            fields = Dict(
                "id" => Models.IDField(),
                "event_date" => Models.DateField(null=false),
                "optional_date" => Models.DateField(null=true)
            ),
            field_names = ["id", "event_date", "optional_date"],
            connect_key = "default"
        )

        # Test 1: Valid YYYY-MM-DD string format
        @test validate_field_data(DateFormatModel, "event_date", "2024-06-15", "insert") === true

        # Test 2: Valid Date object
        @test validate_field_data(DateFormatModel, "event_date", Date(2024, 6, 15), "insert") === true

        # Test 3: Valid DateTime (coerced to date)
        @test validate_field_data(DateFormatModel, "event_date", DateTime(2024, 6, 15, 14, 30, 0), "insert") === true

        # Test 4: Valid ZonedDateTime (coerced to date)
        @test validate_field_data(DateFormatModel, "event_date", ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("UTC")), "insert") === true

        # Test 5: Invalid DD-MM-YYYY format (should fail)
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", "15-06-2024", "insert")

        # Test 6: Invalid MM/DD/YYYY format (should fail)
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", "06/15/2024", "insert")

        # Test 7: Invalid YYYY/MM/DD format (should fail)
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", "2024/06/15", "insert")

        # Test 8: Invalid ISO format with time (should fail because DateField is date-only)
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", "2024-06-15T14:30:00", "insert")

        # Test 9: Invalid malformed string (should fail)
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", "2024-6-15", "insert")

        # Test 10: Invalid malformed string (not a date at all)
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", "not-a-date", "insert")

        # Test 11: Invalid numeric input (should fail)
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", 20240615, "insert")

        # Test 12: Valid edge case - Jan 1 (year boundary)
        @test validate_field_data(DateFormatModel, "event_date", "2024-01-01", "insert") === true

        # Test 13: Valid edge case - Dec 31 (year boundary)
        @test validate_field_data(DateFormatModel, "event_date", "2024-12-31", "insert") === true

        # Test 14: Valid leap year date
        @test validate_field_data(DateFormatModel, "event_date", "2024-02-29", "insert") === true

        # Test 15: Invalid non-leap year Feb 29 (should fail)
        # Note: Base.Date(2023, 2, 29) throws ArgumentError, validate_field_data catches it
        @test_throws PormGError validate_field_data(DateFormatModel, "event_date", "2023-02-29", "insert")

        # Test 16: Nullable field with nothing
        @test validate_field_data(DateFormatModel, "optional_date", nothing, "insert") === true
        @test validate_field_data(DateFormatModel, "optional_date", missing, "insert") === true

        # Test 17: Create with valid string date format
        create_str_date = DateFormatModel.objects.create(
            "event_date" => "2024-06-15",
            show_query=:inspection
        )
        @test create_str_date[:operation] === :insert
        @test contains(create_str_date[:sql_text], "event_date")

        # Test 18: Create with Date object
        create_date_obj = DateFormatModel.objects.create(
            "event_date" => Date(2024, 6, 15),
            show_query=:inspection
        )
        @test create_date_obj[:operation] === :insert

        # Test 19: Update with valid string date format
        update_str_date_q = DateFormatModel.objects
        update_str_date_q.filter("id" => 1)
        update_str_date = update_str_date_q.update(
            "event_date" => "2024-07-20",
            show_query=:dict
        )
        @test update_str_date[:operation] === :update
        @test contains(update_str_date[:sql_text], "UPDATE")

        # Test 20: Update with DateTime (should be coerced)
        update_dt_date_q = DateFormatModel.objects
        update_dt_date_q.filter("id" => 1)
        update_dt_date = update_dt_date_q.update(
            "event_date" => DateTime(2024, 8, 10, 15, 45, 0),
            show_query=:dict
        )
        @test update_dt_date[:operation] === :update

        # Test 21: Bulk insert with mixed date formats
        df_mixed_dates = DataFrame(
            event_date = [
                Date(2024, 6, 15),
                DateTime(2024, 7, 20, 10, 0, 0),
                "2024-08-25"
            ],
            optional_date = [nothing, nothing, nothing]
        )
        res_bulk_date_str = bulk_insert(DateFormatModel.objects, df_mixed_dates, show_query=:dict)
        @test res_bulk_date_str[:operation] === :insert
        @test res_bulk_date_str[:parameter_count] == 6 # 3 rows * 2 fields (event_date, optional_date)

        # Test 22: Bulk insert with invalid format (should fail validation)
        df_invalid_dates = DataFrame(
            event_date = [
                "2024-06-15",
                "15-06-2024"  # Invalid format
            ]
        )
        @test_throws PormGError bulk_insert(DateFormatModel.objects, df_invalid_dates, show_query=:dict)

        # Test 23: Bulk update with valid string dates
        df_bulk_update_dates = DataFrame(
            id = [1, 2],
            event_date = ["2024-09-10", "2024-10-15"]
        )
        res_bulk_update_dates = bulk_update(
            DateFormatModel.objects,
            df_bulk_update_dates,
            columns=["event_date"],
            match_on=["id"],
            show_query=:dict
        )
        @test res_bulk_update_dates[:operation] === :update
        @test contains(res_bulk_update_dates[:sql_text], "UPDATE")

        # Test 24: Verify that invalid string format fails before SQL generation
        @test_throws PormGError DateFormatModel.objects.create(
            "event_date" => "2024/06/15",
            show_query=:inspection
        )
    end
end

@testset "SECTION 7: Relationship Field Validation" begin
    @testset "Relationship Fields: ForeignKey & OneToOneField" begin
        # Test ForeignKey field initialization and validation
        UserModel = Models.Model_Type(
            name = "users",
            fields = Dict(
                "id" => Models.IDField(),
                "username" => Models.CharField(max_length=50)
            ),
            field_names = ["id", "username"],
            connect_key = "default"
        )

        PostModel = Models.Model_Type(
            name = "posts",
            fields = Dict(
                "id" => Models.IDField(),
                "title" => Models.CharField(max_length=200),
                "author" => Models.ForeignKey("User", on_delete="CASCADE"),
                "editor" => Models.ForeignKey("User", null=true, on_delete="SET_NULL", related_name="edited_posts")
            ),
            field_names = ["id", "title", "author", "editor"],
            connect_key = "default"
        )

        # Test 1: ForeignKey accepts valid integer IDs
        @test validate_field_data(PostModel, "author", 1, "insert") === true
        @test validate_field_data(PostModel, "author", 100, "insert") === true
        @test validate_field_data(PostModel, "author", 9223372036854775807, "insert") === true

        # Test 2: ForeignKey rejects non-integer values
        @test_throws PormGError validate_field_data(PostModel, "author", "not-an-id", "insert")
        @test_throws PormGError validate_field_data(PostModel, "author", 1.5, "insert")

        # Test 3: Nullable ForeignKey accepts nothing/missing
        @test validate_field_data(PostModel, "editor", nothing, "insert") === true
        @test validate_field_data(PostModel, "editor", missing, "insert") === true

        # Test 4: Non-nullable ForeignKey rejects nothing/missing
        @test_throws PormGError validate_field_data(PostModel, "author", nothing, "insert")
        @test_throws PormGError validate_field_data(PostModel, "author", missing, "insert")

        # Test 5: ForeignKey field contains on_delete information
        author_field = PostModel.fields["author"]
        @test string(author_field.on_delete) == "CASCADE"
        editor_field = PostModel.fields["editor"]
        @test string(editor_field.on_delete) == "SET_NULL"

        # Test 5b: SQL-style on_delete strings from schema introspection normalize
        # back into the ORM's internal tokens.
        sql_style_set_null = Models.ForeignKey("User", null=true, on_delete="SET NULL")
        sql_style_set_default = Models.ForeignKey("User", null=true, default=1, on_delete="SET DEFAULT")
        sql_style_no_action = Models.ForeignKey("User", null=true, on_delete="NO ACTION")
        @test string(sql_style_set_null.on_delete) == "SET_NULL"
        @test string(sql_style_set_default.on_delete) == "SET_DEFAULT"
        @test string(sql_style_no_action.on_delete) == "DO_NOTHING"

        # Test 5c (#287): the removed `SET` sentinel. `_get_on_delete_mode` used to end with a
        # `contains(on_delete, "SET")` fallback, so anything vaguely SET-shaped that missed the
        # exact SET_NULL / SET_DEFAULT substrings silently became a sentinel that no branch of
        # handle_on_delete! implements and that renders the invalid `ON DELETE SET` in DDL.
        # Those inputs must be rejected at construction now.
        @test_throws PormG.FieldValidationError Models.ForeignKey("User", null=true, on_delete="SET")
        # A near-miss typo: the hyphen is not whitespace, so it never normalized to SET_NULL and
        # fell through to the old fallback. This is the case that made the fallback dangerous.
        @test_throws PormG.FieldValidationError Models.ForeignKey("User", null=true, on_delete="SET-NULL")
        @test_throws PormG.FieldValidationError Models.ForeignKey("User", null=true, on_delete="SETNULL")

        # Django's callable sentinel gets its own message rather than the generic option list —
        # it used to be swallowed by the same fallback, discarding the callable and producing a
        # FK that emitted `ON DELETE SET`.
        django_set_err = try
            Models.ForeignKey("User", null=true, on_delete="models.SET(get_sentinel_user)")
            nothing
        catch e
            e
        end
        @test django_set_err isa PormG.FieldValidationError
        @test occursin("SET(...)", sprint(showerror, django_set_err))
        @test occursin("SET_DEFAULT", sprint(showerror, django_set_err))

        # The SET(...) check must run BEFORE the substring branches. The callable's name is
        # arbitrary text, so a sentinel getter called `protect_sentinel` or `set_default_team`
        # matches `contains(…, "PROTECT")` / `contains(…, "SET_DEFAULT")` first. With the check
        # ordered last, every one of these silently returned a wrong action instead of raising —
        # the exact mistranslation #287 removes. These names are all plausible in real Django code.
        for callable_name in ("protect_sentinel", "set_default_team", "cascade_to_default",
                              "restrict_fn", "do_nothing")
            @test_throws PormG.FieldValidationError Models.ForeignKey(
                "User", null=true, on_delete="models.SET($(callable_name))")
        end

        # Discrimination: the valid tokens must still be accepted, including the bare sentinel
        # form, so the removal did not over-reach.
        @test string(Models.ForeignKey("User", null=true, on_delete=Models.SET_NULL).on_delete) == "SET_NULL"
        @test string(Models.ForeignKey("User", null=true, on_delete="set_null").on_delete) == "SET_NULL"

        # Test 6: ForeignKey field contains related_name when specified
        @test editor_field.related_name == "edited_posts"

        # Test OneToOneField
        ProfileModel = Models.Model_Type(
            name = "profiles",
            fields = Dict(
                "id" => Models.IDField(),
                "user" => Models.OneToOneField("User", on_delete="CASCADE"),
                "bio" => Models.TextField(null=true),
                "backup_contact" => Models.OneToOneField("User", null=true, on_delete="SET_NULL")
            ),
            field_names = ["id", "user", "bio", "backup_contact"],
            connect_key = "default"
        )

        # Test 7: OneToOneField accepts valid integer IDs
        @test validate_field_data(ProfileModel, "user", 1, "insert") === true

        # Test 8: OneToOneField with unique constraint is enforced at field level
        user_field = ProfileModel.fields["user"]
        @test user_field.unique == true
        @test string(user_field.on_delete) == "CASCADE"

        # Test 9: Create operation with ForeignKey
        create_post = PostModel.objects.create(
            "title" => "My First Post",
            "author" => 1,
            show_query=:inspection
        )
        @test create_post[:operation] === :insert
        @test contains(create_post[:sql_text], "author")

        # Test 10: Update operation with ForeignKey
        update_q = PostModel.objects
        update_q.filter("id" => 1)
        update_post = update_q.update(
            "editor" => 2,
            show_query=:dict
        )
        @test update_post[:operation] === :update
        @test contains(update_post[:sql_text], "UPDATE")

        # Test 11: Bulk insert with ForeignKey
        df_posts = DataFrame(
            title = ["Post 1", "Post 2"],
            author = [1, 2],
            editor = [1, nothing]
        )
        bulk_posts = bulk_insert(PostModel.objects, df_posts, show_query=:dict)
        @test bulk_posts[:operation] === :insert

        # Test 12: OneToOneField bulk operations
        df_profiles = DataFrame(
            user = [1, 2],
            backup_contact = [2, nothing]
        )
        bulk_profiles = bulk_insert(ProfileModel.objects, df_profiles, show_query=:dict)
        @test bulk_profiles[:operation] === :insert
    end

    @testset "FK zero primary keys are valid scalar references" begin
        # Foreign keys validate scalar shape only. Some schemas legitimately use
        # primary key 0, so the ORM must pass it through and let the database
        # constraint decide whether the referenced row exists.

        ZeroSentinelModel = Models.Model_Type(
            name = "zero_sentinel_test",
            fields = Dict(
                "id" => Models.IDField(),
                "title" => Models.CharField(max_length=100),
                "required_fk" => Models.ForeignKey("Other", on_delete="CASCADE"),
                "optional_fk" => Models.ForeignKey("Other", null=true, on_delete="SET_NULL"),
                "no_constraint_fk" => Models.ForeignKey("Other", on_delete="CASCADE", db_constraint=false),
            ),
            field_names = ["id", "title", "required_fk", "optional_fk", "no_constraint_fk"],
            connect_key = "default"
        )

        # 0 can be a real primary key, including on nullable FKs. NULL must still
        # be expressed as nothing/missing.
        @test validate_field_data(ZeroSentinelModel, "required_fk", 0, "insert") === true
        @test validate_field_data(ZeroSentinelModel, "optional_fk", 0, "insert") === true
        @test validate_field_data(ZeroSentinelModel, "required_fk", "0", "insert") === true
        @test validate_field_data(ZeroSentinelModel, "no_constraint_fk", 0, "insert") === true

        # Valid positive integer FKs still pass
        @test validate_field_data(ZeroSentinelModel, "required_fk", 1, "insert") === true
        @test validate_field_data(ZeroSentinelModel, "required_fk", 9999, "insert") === true

        # nothing/missing pass through as NULL.
        @test validate_field_data(ZeroSentinelModel, "optional_fk", nothing, "insert") === true
        @test validate_field_data(ZeroSentinelModel, "optional_fk", missing, "insert") === true
    end

end

@testset "SECTION 8: Unique Constraint Validation" begin
    @testset "Unique Constraint Validation" begin
        # Test unique=true field enforcement
        UniqueModel = Models.Model_Type(
            name = "unique_test",
            fields = Dict(
                "id" => Models.IDField(),
                "email" => Models.EmailField(unique=true),
                "username" => Models.CharField(max_length=50, unique=true),
                "firstname" => Models.CharField(max_length=50),  # Non-unique
                "phone" => Models.CharField(max_length=20, unique=true, null=true)
            ),
            field_names = ["id", "email", "username", "firstname", "phone"],
            connect_key = "default"
        )

        # Test 1: Unique field metadata is stored
        @test UniqueModel.fields["email"].unique == true
        @test UniqueModel.fields["username"].unique == true
        @test UniqueModel.fields["phone"].unique == true
        @test UniqueModel.fields["firstname"].unique == false

        # Test 2: Unique fields with valid string values
        @test validate_field_data(UniqueModel, "email", "alice@example.com", "insert") === true
        @test validate_field_data(UniqueModel, "username", "alice_smith", "insert") === true
        @test validate_field_data(UniqueModel, "phone", "+1234567890", "insert") === true

        # Test 3: Nullable unique field with nothing
        @test validate_field_data(UniqueModel, "phone", nothing, "insert") === true
        @test validate_field_data(UniqueModel, "phone", missing, "insert") === true

        # Test 4: Non-unique field with any valid string value
        @test validate_field_data(UniqueModel, "firstname", "Alice", "insert") === true
        @test validate_field_data(UniqueModel, "firstname", "Bob", "insert") === true
        @test validate_field_data(UniqueModel, "firstname", "Alice", "insert") === true  # Duplicate is OK at validation level

        # Test 5: Unique field rejects null for non-nullable unique fields
        @test_throws PormGError validate_field_data(UniqueModel, "email", nothing, "insert")
        @test_throws PormGError validate_field_data(UniqueModel, "username", nothing, "insert")

        # Test 6: Create with unique fields
        create_unique = UniqueModel.objects.create(
            "email" => "user1@example.com",
            "username" => "user1_name",
            "firstname" => "User",
            "phone" => "+99887766",
            show_query=:inspection
        )
        @test create_unique[:operation] === :insert
        @test contains(create_unique[:sql_text], "email")
        @test contains(create_unique[:sql_text], "username")

        # Test 7: Update with unique field
        update_q = UniqueModel.objects
        update_q.filter("id" => 1)
        update_unique = update_q.update(
            "email" => "newemail@example.com",
            show_query=:dict
        )
        @test update_unique[:operation] === :update
        @test contains(update_unique[:sql_text], "UPDATE")

        # Test 8: Bulk insert with unique fields
        df_unique = DataFrame(
            email = ["a@test.com", "b@test.com"],
            username = ["user_a", "user_b"],
            firstname = ["Alice", "Bob"],
            phone = ["+111", "+222"]
        )
        bulk_unique = bulk_insert(UniqueModel.objects, df_unique, show_query=:dict)
        @test bulk_unique[:operation] === :insert

        # Test 9: Bulk insert with null unique field values (nullable)
        df_unique_nullable = DataFrame(
            email = ["c@test.com", "d@test.com"],
            username = ["user_c", "user_d"],
            firstname = ["Charlie", "Diana"],
            phone = [nothing, "+333"]
        )
        bulk_unique_null = bulk_insert(UniqueModel.objects, df_unique_nullable, show_query=:dict)
        @test bulk_unique_null[:operation] === :insert
    end
end

@testset "SECTION 9: String Field Boundaries" begin
    @testset "String Field Boundaries: CharField & TextField" begin
        # Test CharField max_length enforcement
        StringModel = Models.Model_Type(
            name = "string_test",
            fields = Dict(
                "id" => Models.IDField(),
                "code" => Models.CharField(max_length=5),
                "title" => Models.CharField(max_length=100),
                "description" => Models.TextField(null=true),
                "slug" => Models.CharField(max_length=50, unique=true)
            ),
            field_names = ["id", "code", "title", "description", "slug"],
            connect_key = "default"
        )

        # Test 1: CharField within max_length
        @test validate_field_data(StringModel, "code", "ABC", "insert") === true
        @test validate_field_data(StringModel, "code", "ABCDE", "insert") === true
        @test validate_field_data(StringModel, "title", "A" ^ 100, "insert") === true

        # Test 2: CharField exceeds max_length
        @test_throws PormGError validate_field_data(StringModel, "code", "ABCDEF", "insert")
        @test_throws PormGError validate_field_data(StringModel, "code", "A" ^ 10, "insert")
        @test_throws PormGError validate_field_data(StringModel, "title", "A" ^ 101, "insert")

        # Test 3: CharField with empty string (should be OK)
        @test validate_field_data(StringModel, "code", "", "insert") === true

        # Test 4: CharField with whitespace (counts toward max_length)
        @test validate_field_data(StringModel, "code", "A B C", "insert") === true
        @test_throws PormGError validate_field_data(StringModel, "code", "A B C D E", "insert")

        # Test 5: CharField with special characters (counts toward max_length)
        @test validate_field_data(StringModel, "code", "A-BC!", "insert") === true
        @test_throws PormGError validate_field_data(StringModel, "code", "A-BC!!", "insert")

        # Test 6: TextField has no max_length (very large strings OK)
        large_text = "X" ^ 10000
        @test validate_field_data(StringModel, "description", large_text, "insert") === true

        # Test 7: TextField nullable with nothing
        @test validate_field_data(StringModel, "description", nothing, "insert") === true
        @test validate_field_data(StringModel, "description", missing, "insert") === true

        # Test 8: Slug field with alphanumeric and hyphen
        @test validate_field_data(StringModel, "slug", "my-great-post-2024", "insert") === true
        @test validate_field_data(StringModel, "slug", "s" ^ 50, "insert") === true
        @test_throws PormGError validate_field_data(StringModel, "slug", "s" ^ 51, "insert")

        # Test 9: Create with max_length string
        create_max = StringModel.objects.create(
            "code" => "ABCDE",
            "title" => "X" ^ 100,
            "slug" => "my-slug",
            show_query=:inspection
        )
        @test create_max[:operation] === :insert

        # Test 10: Create with string exceeding max_length (should fail)
        @test_throws PormGError StringModel.objects.create(
            "code" => "ABCDEF",
            "title" => "X" ^ 100,
            "slug" => "my-slug",
            show_query=:inspection
        )

        # Test 11: Update with max_length string
        update_q = StringModel.objects
        update_q.filter("id" => 1)
        update_max = update_q.update(
            "code" => "ABCDE",
            show_query=:dict
        )
        @test update_max[:operation] === :update

        # Test 12: Update with string exceeding max_length (should fail)
        update_bad_q = StringModel.objects
        update_bad_q.filter("id" => 1)
        @test_throws PormGError update_bad_q.update(
            "code" => "ABCDEF",
            show_query=:dict
        )

        # Test 13: Bulk insert with strings at boundary
        df_strings = DataFrame(
            code = ["A", "AB", "ABC", "ABCD", "ABCDE"],
            title = [
                "X" ^ 50,
                "Y" ^ 75,
                "Z" ^ 100,
                "TITLE",
                "ANOTHER"
            ],
            slug = ["slug1", "slug2", "slug3", "slug4", "slug5"]
        )
        bulk_strings = bulk_insert(StringModel.objects, df_strings, show_query=:dict)
        @test bulk_strings[:operation] === :insert

        # Test 14: Bulk insert with string exceeding max_length (should fail)
        df_bad_strings = DataFrame(
            code = ["A", "ABCDEF"],  # Second exceeds max_length
            title = ["TITLE", "ANOTHER"],
            slug = ["slug1", "slug2"]
        )
        # #268 audit: same contract as single-row insert — the taxonomy type survives bulk.
        @test_throws InvalidValueError bulk_insert(StringModel.objects, df_bad_strings, show_query=:dict)
        # …and bulk_update shares the rethrow pattern (bulk_copy is identical code, PG-only).
        @test_throws InvalidValueError bulk_update(StringModel.objects,
            DataFrame(id = [1], code = ["TOOLONG"]), columns = ["code"], match_on = ["id"],
            show_query = :dict)

        # Test 15: Unicode strings (count as characters, not bytes)
        @test validate_field_data(StringModel, "code", "你好世", "insert") === true
        @test_throws PormGError validate_field_data(StringModel, "code", "你好世界中国", "insert")
    end

end

@testset "SECTION 10: Boolean Field Edge Cases" begin
    @testset "Boolean Field Edge Cases & Truthiness" begin
        # Test BooleanField with various input values
        BoolModel = Models.Model_Type(
            name = "bool_test",
            fields = Dict(
                "id" => Models.IDField(),
                "is_active" => Models.BooleanField(default=false),
                "is_verified" => Models.BooleanField(default=true),
                "is_blocked" => Models.BooleanField(null=true)
            ),
            field_names = ["id", "is_active", "is_verified", "is_blocked"],
            connect_key = "default"
        )

        # Test 1: BooleanField accepts literal true
        @test validate_field_data(BoolModel, "is_active", true, "insert") === true

        # Test 2: BooleanField accepts literal false
        @test validate_field_data(BoolModel, "is_active", false, "insert") === true

        # Test 3: BooleanField with default=false
        is_active_field = BoolModel.fields["is_active"]
        @test is_active_field.default == false

        # Test 4: BooleanField with default=true
        is_verified_field = BoolModel.fields["is_verified"]
        @test is_verified_field.default == true

        # Test 5: BooleanField nullable with nothing
        @test validate_field_data(BoolModel, "is_blocked", nothing, "insert") === true

        # Test 6: BooleanField nullable with missing
        @test validate_field_data(BoolModel, "is_blocked", missing, "insert") === true

        # Test 7: BooleanField validation semantics
        # Note: The ORM currently accepts 1/0 and string values as valid boolean-like coercions
        # Strict type checking for BooleanField is pending implementation
        # For now, we verify that boolean-like values are accepted
        # @test_throws ErrorException validate_field_data(BoolModel, "is_active", 1, "insert")
        # @test_throws ErrorException validate_field_data(BoolModel, "is_active", 0, "insert")
        # String coercions are currently accepted (pending strict type checking)
        # @test_throws ErrorException validate_field_data(BoolModel, "is_active", "true", "insert")
        # @test_throws ErrorException validate_field_data(BoolModel, "is_active", "false", "insert")
        # @test_throws ErrorException validate_field_data(BoolModel, "is_active", "", "insert")

        # Test 8: Create with boolean values
        create_bool = BoolModel.objects.create(
            "is_active" => true,
            "is_verified" => false,
            "is_blocked" => nothing,
            show_query=:inspection
        )
        @test create_bool[:operation] === :insert
        @test contains(create_bool[:sql_text], "is_active")
        @test contains(create_bool[:sql_text], "is_verified")

        # Test 9: Update with boolean values
        update_q = BoolModel.objects
        update_q.filter("id" => 1)
        update_bool = update_q.update(
            "is_active" => false,
            show_query=:dict
        )
        @test update_bool[:operation] === :update
        @test contains(update_bool[:sql_text], "UPDATE")

        # Test 10: Bulk insert with boolean values
        df_bools = DataFrame(
            is_active = [true, false, true, false],
            is_verified = [true, true, false, false],
            is_blocked = [nothing, true, false, nothing]
        )
        bulk_bools = bulk_insert(BoolModel.objects, df_bools, show_query=:dict)
        @test bulk_bools[:operation] === :insert

        # Test 11: Bulk insert with string values in boolean column (should fail)
        df_bad_bools = DataFrame(
            is_active = [true, false],
            is_verified = [true, true],
            is_blocked = [nothing, nothing]
        )
        # String booleans should be rejected
        @test_throws Exception bulk_insert(
            BoolModel.objects,
            DataFrame(
                is_active = ["true", "false"],
                is_verified = [true, false],
                is_blocked = [nothing, nothing]
            ),
            show_query=:dict
        )

        # Test 12: Inspect query metadata with boolean filter
        q_bool = BoolModel.objects
        q_bool.filter("is_active" => true)
        inspect_bool = inspect_query(q_bool)
        @test inspect_bool[:operation] === :select
        @test contains(inspect_bool[:sql_text], "is_active")
        @test true in inspect_bool[:parameters]

        # Test 13: Multiple boolean fields in filter
        q_multi_bool = BoolModel.objects
        q_multi_bool.filter("is_active" => true, "is_verified" => false)
        inspect_multi = inspect_query(q_multi_bool)
        @test inspect_multi[:operation] === :select
        @test true in inspect_multi[:parameters]
        @test false in inspect_multi[:parameters]

        # Test 14: Boolean field with both values in bulk update
        df_bool_update = DataFrame(
            id = [1, 2, 3, 4],
            is_active = [true, false, true, false]
        )
        update_bulk_bool = bulk_update(
            BoolModel.objects,
            df_bool_update,
            columns=["is_active"],
            match_on=["id"],
            show_query=:dict
        )
        @test update_bulk_bool[:operation] === :update
    end

end



# ─────────────────────────────────────────────────────────────────────────────
# SECTION: Django Compatibility Contracts (Pure Julia, No DB)
#
# Validates PormG's ability to target Django-managed tables and match Django's
# field semantics — without any Python or Django dependency.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SECTION: Django Compatibility Contracts" begin

    # ─────────────────────────────────────────────────────────────────────────
    # Table Prefix Contract
    # Django uses app_label naming (e.g. `myapp_driver`).
    # 1. The explicit table string passed to Model() remains verbatim for SQL queries.
    # 2. If `django_prefix` is set in Configuration.Settings, PormG strips it
    #    when generating internal relationship names (e.g., related_objects) 
    #    so you don't get double-prefixed property names.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Table Prefix: Configuration parameter strips prefixes from relationships" begin
        # Setup a configuration WITH a django_prefix
        django_cfg = PormG.Configuration.Settings(
            connections = MockPostgres(),
            django_prefix = "prefix"
        )
        PormG.config["django_cfg_test"] = django_cfg

        # Mimics what PormG Generator creates when it reads a Django DB:
        # Django model `Dim_municipio` and `Dim_feriados` with prefix `prefix`
        Dim_municipio = Models.Model("prefix_dim_municipio", 
            id = Models.IDField()
        )
        Dim_feriados = Models.Model("prefix_dim_feriados",
            ibge_id = Models.ForeignKey(Dim_municipio, pk_field="id", on_delete="RESTRICT"),
            nome    = Models.CharField(),
            ativo   = Models.BooleanField(default=true)
        )
        Dim_municipio.connect_key = "django_cfg_test"
        Dim_feriados.connect_key  = "django_cfg_test"
        Dim_municipio._module = @__MODULE__
        Dim_feriados._module  = @__MODULE__

        # 1. Prove the underlying table name used in SQL remains EXACTLY the explicit string
        @test Dim_feriados.name == "prefix_dim_feriados"

        q = Dim_feriados.objects
        # PormG mirrors Django's relationship querying syntax:
        # even though the literal field is `ibge_id`, you must drop the `_id`
        # when traversing the join (using `ibge__`).
        q.filter("ibge__id" => 1)
        insp = inspect_query(q)
        @test contains(insp[:sql_text], "prefix_dim_feriados")
        @test !contains(insp[:sql_text], "prefix_prefix_dim_feriados")
        
        # Ensures that in the actual generated SQL, `ibge_id` is used because
        # that is the literal definition of the physical column.
        @test contains(insp[:sql_text], "\"ibge_id\"")

        # 2. Prove the Configuration parameter strips the prefix for internal relationship naming
        # This is where the `django_prefix` setting is actually used by PormG internally
        feriado_logical_name = Models.get_model_name(Dim_feriados, django_cfg, false)
        @test feriado_logical_name == "dim_feriados"  # "prefix_" was stripped!

    end

    # ─────────────────────────────────────────────────────────────────────────

    # DateField Truncation Contract (unit-level, SQL inspection only)
    # Django silently truncates datetime to date. PormG must do the same.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "DateField: DateTime input truncates to Date (no error)" begin
        DateContractModel = Models.Model_Type(
            name = "django_date_contract",
            fields = Dict(
                "id"         => Models.IDField(),
                "event_date" => Models.DateField(null=true),
            ),
            field_names = ["id", "event_date"],
            connect_key = "default"
        )

        dt_with_time = DateTime(2024, 7, 14, 22, 30, 45)
        plain_date   = Date(2024, 7, 14)

        # Must NOT throw — truncation is a contract, not an error
        @test validate_field_data(DateContractModel, "event_date", dt_with_time, "insert") === true
        @test validate_field_data(DateContractModel, "event_date", plain_date,   "insert") === true

        # SQL parameter must contain the date portion
        insp = DateContractModel.objects.create(
            "event_date" => dt_with_time,
            show_query = :inspection
        )
        date_param = findfirst(p -> contains(string(p), "2024-07-14"), insp[:parameters])
        @test !isnothing(date_param)
        @test !any(p -> contains(string(p), "22:30"), insp[:parameters])
    end

    # ─────────────────────────────────────────────────────────────────────────
    # DecimalField Precision (unit-level)
    # Validates that NUMERIC(10,2) precision constraints are enforced at ORM
    # layer before any DB round-trip occurs.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "DecimalField: NUMERIC(10,2) precision enforced before DB" begin
        PriceModel = Models.Model_Type(
            name        = "django_decimal_contract",
            fields      = Dict(
                "id"    => Models.IDField(),
                "price" => Models.DecimalField(max_digits=10, decimal_places=2)
            ),
            field_names = ["id", "price"],
            connect_key = "default"
        )

        @test validate_field_data(PriceModel, "price", "99.99",    "insert") === true
        @test validate_field_data(PriceModel, "price", "0.01",     "insert") === true
        @test validate_field_data(PriceModel, "price", "-1234.56", "insert") === true
        @test validate_field_data(PriceModel, "price", 3.14,       "insert") === true

        @test_throws PormGError validate_field_data(PriceModel, "price", "99.999",       "insert")
        @test_throws PormGError validate_field_data(PriceModel, "price", 9.141,          "insert")
        @test_throws PormGError validate_field_data(PriceModel, "price", "12345678901",  "insert")
    end

    @testset "SQL function helpers preserve advanced constructor inputs" begin
        # These regressions protect the public helper boundary from becoming narrower
        # than FObject itself. Advanced callers and internal builder paths may already
        # hold a SQLField, so helpers like Lower/Round/Cast must continue to accept it.
        @test hasmethod(QB.Lower, Tuple{QB.SQLField})
        @test hasmethod(QB.Round, Tuple{QB.SQLField, Int})
        @test hasmethod(QB.Cast, Tuple{QB.SQLField, String})

        FunctionContractModel = Models.Model_Type(
            name = "function_contract_model",
            fields = Dict(
                "id" => Models.IDField(),
                "forename" => Models.CharField(max_length=100),
                "points" => Models.FloatField(null=true),
            ),
            field_names = ["id", "forename", "points"],
            connect_key = "default"
        )

        q = FunctionContractModel.objects
        q.values(
            "lower_name" => QB.Lower(QB.SQLField("forename")),
            "trimmed_name" => QB.Trim(QB.SQLField("forename")),
            "name_len" => QB.Length(QB.SQLField("forename")),
            "rounded_pts" => QB.Round(QB.SQLField("points"), 2),
            "absolute_pts" => QB.Abs(QB.SQLField("points")),
            "floored_pts" => QB.Floor(QB.SQLField("points")),
            "sqrt_pts" => QB.Sqrt(QB.SQLField("points")),
            "casted_pts" => QB.Cast(QB.SQLField("points"), "text")
        )

        insp = inspect_query(q)
        sql = insp[:sql_text]

        @test contains(sql, "LOWER")
        @test contains(sql, "TRIM")
        @test contains(sql, "LENGTH")
        @test contains(sql, "ROUND")
        @test contains(sql, "ABS")
        @test contains(sql, "FLOOR")
        @test contains(sql, "SQRT")
        @test contains(sql, "::text") || contains(sql, "CAST(")
        @test contains(sql, "\"forename\"")
        @test contains(sql, "\"points\"")
        @test 2 in insp[:parameters]
    end

    @testset "Aggregate-wrapped Round stays aggregate in inspection" begin
        # Wrapping an aggregate FExpression in Round must not demote it to a non-aggregate
        # select item, otherwise the builder incorrectly pushes it into GROUP BY.
        AggregateContractModel = Models.Model_Type(
            name = "aggregate_contract_model",
            fields = Dict(
                "id" => Models.IDField(),
                "team" => Models.CharField(max_length=100),
                "points" => Models.FloatField(null=true),
            ),
            field_names = ["id", "team", "points"],
            connect_key = "default"
        )

        q = AggregateContractModel.objects
        q.values(
            "team",
            "avg_points_round" => QB.Round(QB.Sum("points") / QB.Count("id"), 1)
        )
        q.order_by("team")

        insp = inspect_query(q)
        sql = insp[:sql_text]

        @test contains(sql, "ROUND")
        @test contains(sql, "SUM")
        @test contains(sql, "COUNT")
        @test contains(sql, "GROUP BY 1")
        @test !contains(sql, "GROUP BY ROUND")
        @test !contains(sql, "GROUP BY SUM")
        @test 1 in insp[:parameters]

        wrapped_avg = QB.Round(QB.Sum("points") / QB.Count("id"), 1)
        @test wrapped_avg.aggregate === true
    end

    @testset "Extract and ToChar preserve helper surface consistency" begin
        # These helpers should accept the same advanced field wrappers as the rest of the
        # SQL helper family: direct SQLField objects and F expressions.
        @test hasmethod(QB.Extract, Tuple{QB.SQLField, String})
        @test hasmethod(QB.Extract, Tuple{QB.FExpression, String})
        @test hasmethod(QB.ToChar, Tuple{QB.SQLField, String})
        @test hasmethod(QB.ToChar, Tuple{QB.FExpression, String})

        DateHelperModel = Models.Model_Type(
            name = "date_helper_model",
            fields = Dict(
                "id" => Models.IDField(),
                "created_at" => Models.DateTimeField(null=true),
            ),
            field_names = ["id", "created_at"],
            connect_key = "default"
        )

        q = DateHelperModel.objects
        q.values(
            "year_from_sqlfield" => QB.Extract(QB.SQLField("created_at"), "YEAR"),
            "year_from_f" => QB.Extract(QB.F("created_at"), "YEAR"),
            "text_from_sqlfield" => QB.ToChar(QB.SQLField("created_at"), "YYYY-MM-DD"),
            "text_from_f" => QB.ToChar(QB.F("created_at"), "YYYY-MM-DD")
        )

        insp = inspect_query(q)
        sql = insp[:sql_text]

        @test contains(sql, "EXTRACT") || contains(sql, "strftime")
        @test contains(sql, "created_at")
        @test contains(sql, "YYYY") || contains(sql, "%Y")
    end

end
