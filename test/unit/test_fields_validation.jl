using Test
using PormG
using Decimals
using Dates
using TimeZones

const QB = PormG.QueryBuilder
const Models = PormG.Models

mock_numeric_model = Models.Model_Type(
    name = "test_numbers",
    fields = Dict(
        "price" => Models.DecimalField(max_digits = 10, decimal_places = 2),
        "quantity" => Models.IntegerField(),
        "nickname" => Models.CharField(max_length = 10, null = true),
        "optional_price" => Models.DecimalField(max_digits = 10, decimal_places = 2, null = true)
    ),
    field_names = ["price", "quantity", "nickname", "optional_price"]
)

@testset "validate_field_data numeric enforcement" begin
    # This block verifies the core contract for numeric validation.
    # The validator now owns type checking for both single-row and bulk APIs, so these
    # expectations must stay stable even if the execution layer changes later.

    # Decimal inputs should accept ordinary Julia numbers and decimal strings when the value is
    # explicit and compatible with the field. This keeps valid currency-like inputs ergonomic.
    @test QB.validate_field_data(mock_numeric_model, "price", 123.45, "insert")
    @test QB.validate_field_data(mock_numeric_model, "price", parse(Decimals.Decimal, "123.45"), "insert")
    @test QB.validate_field_data(mock_numeric_model, "price", "123.45", "insert")

    # Numeric scientific notation is acceptable when it already entered Julia as a number. The
    # validator should count digits on the expanded fixed-point representation, not on `1.23e2`.
    @test QB.validate_field_data(mock_numeric_model, "price", 1.23e2, "insert")

    # Integer-backed fields should reject Float64 values even when the float is mathematically an
    # integer. Silent coercion hides data-quality bugs in CSV/DataFrame pipelines.
    err_float = try
        QB.validate_field_data(mock_numeric_model, "quantity", 14.0, "insert")
        nothing
    catch e
        e
    end
    @test err_float !== nothing
    @test occursin("quantity", string(err_float))
    @test occursin("expected Int64 or an integer string", string(err_float))

    # Integer strings remain allowed because they are explicit and lossless for integer fields.
    @test QB.validate_field_data(mock_numeric_model, "quantity", "14", "insert")

    # Decimal strings that use scientific notation are rejected on purpose. The ORM wants the
    # literal decimal source of truth instead of a notation that depends on parsing rules.
    err_scientific = try
        QB.validate_field_data(mock_numeric_model, "price", "1.23e2", "insert")
        nothing
    catch e
        e
    end
    @test err_scientific !== nothing
    @test occursin("Scientific notation strings are not supported", string(err_scientific))
end

@testset "validate_field_data null and max_digits" begin
    # Nullability must be enforced before formatting so the user gets a model-level message.
    err_required = try
        QB.validate_field_data(mock_numeric_model, "price", nothing, "insert")
        nothing
    catch e
        e
    end
    @test err_required !== nothing
    @test occursin("price", string(err_required))
    @test occursin("null values are not allowed", string(err_required))

    # Nullable fields should accept both `nothing` and `missing` because DataFrames commonly use
    # `missing` while Julia APIs sometimes hand over `nothing`.
    @test QB.validate_field_data(mock_numeric_model, "optional_price", nothing, "insert")
    @test QB.validate_field_data(mock_numeric_model, "optional_price", missing, "insert")

    # max_digits counts the normalized fixed-point representation after removing the sign and dot.
    # This should accept a negative value with five digits but reject an eleven-digit decimal.
    @test QB.validate_field_data(mock_numeric_model, "price", -999.99, "insert")

    err_digits = try
        QB.validate_field_data(mock_numeric_model, "price", 123456789.99, "insert")
        nothing
    catch e
        e
    end
    @test err_digits !== nothing
    @test occursin("max_digits is 10", string(err_digits))
end

@testset "format_number_sql strict string handling" begin
    # Formatter tests are important because validation and SQL generation both rely on the same
    # normalization function. If this logic drifts, bulk and single-row operations diverge.
    @test Models.format_number_sql(123.456) == "123.456"
    @test Models.format_number_sql(123) == 123
    @test Models.format_number_sql(parse(Decimals.Decimal, "123.45")) == "123.45"
    @test Models.format_number_sql("123.45") == "123.45"

    err_comma = try
        Models.format_number_sql("123,45")
        nothing
    catch e
        e
    end
    @test err_comma !== nothing
    @test occursin("decimal separator", string(err_comma))

    err_scientific = try
        Models.format_number_sql("1.23e2")
        nothing
    catch e
        e
    end
    @test err_scientific !== nothing
    @test occursin("Scientific notation strings are not supported", string(err_scientific))
end

@testset "date and datetime formatter normalization" begin
    # These formatter tests cover the remaining normalization gap from the plan. They verify the
    # pure date/time formatters without needing a database, which keeps failures anchored to the
    # serializer layer rather than surfacing later as SQL or adapter errors.
    dt = DateTime(2024, 1, 2, 3, 4, 5, 678)
    zdt = ZonedDateTime(dt, TimeZone("UTC"))

    # Date formatter behavior should normalize richer datetime inputs down to YYYY-MM-DD because
    # DateField stores dates only. This protects users from accidentally smuggling time-of-day
    # information into a date column.
    @test Models.format_date_sql(Date(2024, 1, 2)) == "2024-01-02"
    @test Models.format_date_sql(dt) == "2024-01-02"
    @test Models.format_date_sql(zdt) == "2024-01-02"
    @test Models.format_date_sql("2024-01-02") == "2024-01-02"
    @test Models.format_date_sql(missing) === missing
    @test Models.format_date_sql(nothing) === missing

    err_bad_date = try
        Models.format_date_sql("2024/01/02")
        nothing
    catch e
        e
    end
    @test err_bad_date !== nothing
    @test occursin("is invalid", string(err_bad_date))

    # Timezone formatter behavior is distinct from DateField normalization: valid timezone-aware
    # strings and ZonedDateTime values should survive with their datetime information intact.
    # The string path is especially important because it previously threw a TypeError on valid
    # input due to a boolean/string mismatch in the implementation.
    @test Models.format_timezone_sql(zdt) == string(zdt)
    @test Models.format_timezone_sql(dt, "UTC") == zdt
    @test Models.format_timezone_sql("2024-01-02T03:04:05.678+0000") == "2024-01-02T03:04:05.678"
    @test Models.format_timezone_sql(missing) === missing
    @test Models.format_timezone_sql(nothing) === missing

    err_bad_timezone = try
        Models.format_timezone_sql("not-a-timestamp")
        nothing
    catch e
        e
    end
    @test err_bad_timezone !== nothing
    @test occursin("Invalid timezone format", string(err_bad_timezone))
end