"""
Unit tests for UUIDField, URLField, SlugField, and JSONField.

This file covers:
- Field construction with defaults and keyword arguments
- Formatter function validation (format_uuid_sql, format_json_sql)
- Sanitization-level validation via validate_field_data
- SQL type assignment (UUID, JSONB, VARCHAR) matches expected values
- Invalid input rejection for each field type
"""
# julia --project=. test/unit/test_new_field_types.jl

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: validate_field_data
using UUIDs
using JSON

const QB = PormG.QueryBuilder

# Mock Postgres Dialect for inspection
struct MockPostgresNewFields <: PormG.PormGPostgres end
if !haskey(PormG.config, "default")
    MockSettings = PormG.Configuration.Settings(
        connections = MockPostgresNewFields(),
        change_data = true
    )
    PormG.config["default"] = MockSettings
end

@testset "SECTION: New Field Types" begin

    # ─────────────────────────────────────────────────────────────────────────
    # UUIDField: construction, formatting, and validation
    # ─────────────────────────────────────────────────────────────────────────
    @testset "UUIDField" begin
        @testset "Construction defaults" begin
            f = Models.UUIDField()
            @test f.type == "UUID"
            @test f.primary_key == false
            @test f.unique == false
            @test f.null == false
            @test f.blank == false
            @test f.db_index == false
            @test f.default === nothing
            @test f.editable == true
            @test f.auto_add == false
        end

        @testset "Construction with keyword arguments" begin
            f = Models.UUIDField(unique=true, null=true, db_index=true, primary_key=true, auto_add=true)
            @test f.unique == true
            @test f.null == true
            @test f.db_index == true
            @test f.primary_key == true
            @test f.auto_add == true
        end

        @testset "Construction with default UUID string" begin
            f = Models.UUIDField(default="550e8400-e29b-41d4-a716-446655440000")
            @test f.default == "550e8400-e29b-41d4-a716-446655440000"
        end

        @testset "Construction rejects invalid default" begin
            @test_throws PormG.FieldValidationError Models.UUIDField(default="not-a-uuid")
            @test_throws PormG.FieldValidationError Models.UUIDField(default="12345")
        end

        @testset "format_uuid_sql" begin
            # UUID type
            u = uuid4()
            @test Models.format_uuid_sql(u) == string(u)

            # Valid string
            @test Models.format_uuid_sql("550e8400-e29b-41d4-a716-446655440000") == "550e8400-e29b-41d4-a716-446655440000"

            # Uppercase normalizes to lowercase
            @test Models.format_uuid_sql("550E8400-E29B-41D4-A716-446655440000") == "550e8400-e29b-41d4-a716-446655440000"

            # Nothing/missing
            @test Models.format_uuid_sql(nothing) === missing
            @test Models.format_uuid_sql(missing) === missing

            # Invalid format
            @test_throws PormG.InvalidValueError Models.format_uuid_sql("not-a-uuid")
            @test_throws PormG.InvalidValueError Models.format_uuid_sql("550e8400-e29b-41d4-a716")
            @test_throws PormG.InvalidValueError Models.format_uuid_sql(42)
        end

        @testset "validate_field_data with UUIDField" begin
            mock_model = Models.Model_Type(
                name = "uuid_test",
                fields = Dict(
                    "token" => Models.UUIDField(),
                    "nullable_token" => Models.UUIDField(null=true)
                ),
                field_names = ["token", "nullable_token"]
            )

            # Valid UUID object
            @test validate_field_data(mock_model, "token", uuid4(), "insert") === true

            # Valid UUID string
            @test validate_field_data(mock_model, "token", "550e8400-e29b-41d4-a716-446655440000", "insert") === true

            # Invalid string
            @test_throws PormGError validate_field_data(mock_model, "token", "bad-uuid", "insert")

            # Wrong type
            @test_throws PormGError validate_field_data(mock_model, "token", 42, "insert")

            # Null handling
            @test_throws PormGError validate_field_data(mock_model, "token", nothing, "insert")
            @test validate_field_data(mock_model, "nullable_token", nothing, "insert") === true
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # URLField: construction, validation, and max_length enforcement
    # ─────────────────────────────────────────────────────────────────────────
    @testset "URLField" begin
        @testset "Construction defaults" begin
            f = Models.URLField()
            @test f.type == "VARCHAR"
            @test f.max_length == 200
            @test f.null == false
            @test f.blank == false
            @test f.editable == true
        end

        @testset "Construction with custom max_length" begin
            f = Models.URLField(max_length=500)
            @test f.max_length == 500
        end

        @testset "Construction rejects invalid max_length" begin
            @test_throws PormG.FieldValidationError Models.URLField(max_length=0)
            @test_throws PormG.FieldValidationError Models.URLField(max_length=-1)
        end

        @testset "validate_field_data with URLField" begin
            mock_model = Models.Model_Type(
                name = "url_test",
                fields = Dict(
                    "website" => Models.URLField(max_length=50)
                ),
                field_names = ["website"]
            )

            # Valid URLs pass validation (URLField stores as VARCHAR, text validation)
            @test validate_field_data(mock_model, "website", "https://example.com", "insert") === true
            @test validate_field_data(mock_model, "website", "http://test.org", "insert") === true

            # Max length enforcement: a URL exceeding max_length should fail
            long_url = "https://example.com/" * repeat("a", 50)
            @test_throws PormGError validate_field_data(mock_model, "website", long_url, "insert")
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SlugField: construction, validation, max_length, and db_index default
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SlugField" begin
        @testset "Construction defaults" begin
            f = Models.SlugField()
            @test f.type == "VARCHAR"
            @test f.max_length == 50
            @test f.db_index == true  # SlugField defaults to indexed
            @test f.unique == false
            @test f.editable == true
        end

        @testset "Construction with custom options" begin
            f = Models.SlugField(max_length=100, unique=true, db_index=false)
            @test f.max_length == 100
            @test f.unique == true
            @test f.db_index == false
        end

        @testset "Construction rejects invalid max_length" begin
            @test_throws PormG.FieldValidationError Models.SlugField(max_length=0)
            @test_throws PormG.FieldValidationError Models.SlugField(max_length=256)
        end

        @testset "validate_field_data with SlugField" begin
            mock_model = Models.Model_Type(
                name = "slug_test",
                fields = Dict(
                    "slug" => Models.SlugField(max_length=20)
                ),
                field_names = ["slug"]
            )

            # Valid slug values
            @test validate_field_data(mock_model, "slug", "hello-world", "insert") === true
            @test validate_field_data(mock_model, "slug", "test_slug_123", "insert") === true

            # Max length enforcement
            @test_throws PormGError validate_field_data(mock_model, "slug", repeat("a", 21), "insert")
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # JSONField: construction, formatting, validation
    # ─────────────────────────────────────────────────────────────────────────
    @testset "JSONField" begin
        @testset "Construction defaults" begin
            f = Models.JSONField()
            @test f.type == "JSONB"
            @test f.null == false
            @test f.blank == false
            @test f.editable == true
            @test f.default === nothing
        end

        @testset "Construction with default JSON string" begin
            f = Models.JSONField(default="{}")
            @test f.default == "{}"
        end

        @testset "Construction rejects invalid default" begin
            @test_throws PormG.FieldValidationError Models.JSONField(default="{invalid json")
        end

        @testset "format_json_sql" begin
            # Valid JSON string passthrough
            @test Models.format_json_sql("{}") == "{}"
            @test Models.format_json_sql("[1,2,3]") == "[1,2,3]"
            @test Models.format_json_sql("{\"key\":\"value\"}") == "{\"key\":\"value\"}"

            # Dict serialization
            result = Models.format_json_sql(Dict("a" => 1))
            parsed = JSON.parse(result)
            @test parsed["a"] == 1

            # Vector serialization
            result = Models.format_json_sql([1, 2, 3])
            @test JSON.parse(result) == [1, 2, 3]

            # Scalar serialization
            @test Models.format_json_sql(42) == "42"
            @test Models.format_json_sql(true) == "true"
            @test Models.format_json_sql(3.14) == "3.14"

            # Nothing/missing
            @test Models.format_json_sql(nothing) === missing
            @test Models.format_json_sql(missing) === missing

            # Invalid JSON string
            @test_throws PormG.InvalidValueError Models.format_json_sql("{invalid}")

            # Unsupported type
            @test_throws PormG.InvalidValueError Models.format_json_sql(r"regex")
        end

        @testset "validate_field_data with JSONField" begin
            mock_model = Models.Model_Type(
                name = "json_test",
                fields = Dict(
                    "data" => Models.JSONField(),
                    "nullable_data" => Models.JSONField(null=true)
                ),
                field_names = ["data", "nullable_data"]
            )

            # Valid JSON string
            @test validate_field_data(mock_model, "data", "{\"key\":\"value\"}", "insert") === true

            # Dict value
            @test validate_field_data(mock_model, "data", Dict("x" => 1), "insert") === true

            # Vector value
            @test validate_field_data(mock_model, "data", [1, 2, 3], "insert") === true

            # Scalar values
            @test validate_field_data(mock_model, "data", 42, "insert") === true
            @test validate_field_data(mock_model, "data", true, "insert") === true

            # Invalid JSON string
            @test_throws PormGError validate_field_data(mock_model, "data", "{bad json", "insert")

            # Null handling
            @test_throws PormGError validate_field_data(mock_model, "data", nothing, "insert")
            @test validate_field_data(mock_model, "nullable_data", nothing, "insert") === true
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SQL type assignment: verify each new field produces the expected SQL type
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQL Type Constants" begin
        @test Models.UUIDField().type == "UUID"
        @test Models.URLField().type == "VARCHAR"
        @test Models.SlugField().type == "VARCHAR"
        @test Models.JSONField().type == "JSONB"
    end
end
