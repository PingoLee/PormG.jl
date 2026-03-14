# Plan: Field Validation & Type Normalization

Improve robustness of field-level data handling by implementing comprehensive unit tests for normalization and validation logic, followed by targeted integration tests for bulk operations.

## Current State Assessment

Before implementation, establish a baseline understanding of existing behavior:

- **`format_number_sql` ([src/Models.jl](src/Models.jl#L512))**: Currently handles conversion of Julia numeric types (`Float64`, `Int64`) to SQL-safe strings using `@sprintf("%.17g", value)` to avoid scientific notation. Also attempts to parse string inputs; **currently unclear** if it rejects invalid formats (e.g., comma-separated decimals) or silently coerces.
- **`validate_field_data` ([src/querybuilder/sanitization.jl](src/querybuilder/sanitization.jl#L74))**: Performs existence checks, nullability enforcement, PK protection, and `max_length` validation for strings. **Investigation required**: Does it currently validate `max_digits` for `DecimalField`? Is the digit-counting logic (handling `-` and `.`) correct?
- **`bulk_insert` / `bulk_update` ([src/querybuilder/execution_bulk.jl](src/querybuilder/execution_bulk.jl))**: Currently accepts DataFrames. **Current behavior unknown**: Does it auto-coerce `Float64` to `Int64` when inserting into an `IntegerField`? What happens with `missing` values?

**Action Required**: Review source implementations before writing tests to avoid redundant coverage.

## Coercion Policy (Explicit Decision)

**PormG rejects type mismatches at the query-building stage with clear, actionable error messages.** Automatic coercion (e.g., `14.0` → `14` for `IntegerField`) is **explicitly not supported**:

- Users must provide correctly-typed data (e.g., `Int64` for `IntegerField`, not `Float64`).
- String inputs to numeric fields are only accepted if they represent valid numbers for that type.
- Invalid formats (e.g., using `,` as decimal separator, scientific notation outside PostgreSQL's native support) are rejected with error context.
- Missing values in required fields raise validation errors; missing values in nullable fields are allowed.

**Tooling**: Extend `validate_field_data` error messages to include:
- Field name and model
- Expected vs. actual type
- Suggested fix (when applicable)

## Phase 1: Unit Testing (Validation & Normalization)

### 1.1 Create [test/unit/test_fields_validation.jl](test/unit/test_fields_validation.jl)

New unit test file to house isolated tests for field logic without database dependency.

### 1.2 Mock Model Template

Use this structure to construct testable `Model_Type` objects (avoiding the full factory):

```julia
using PormG.Models
using PormG.QueryBuilder: validate_field_data

# Minimal mock for DecimalField validation
mock_decimal_model = Models.Model_Type(
    name = "test_decimals",
    table_name = "test_decimals",
    db = nothing,  # Not used in validate_field_data
    fields = Dict(
        "price" => Models.sDecimalField(
            verbose_name = "Price",
            primary_key = false,
            unique = false,
            blank = false,
            null = false,
            db_index = false,
            default = nothing,
            editable = true,
            max_digits = 10,
            decimal_places = 2,
            type = "DECIMAL",
            formater = Models.format_number_sql
        ),
        "quantity" => Models.sIntegerField(
            verbose_name = "Quantity",
            primary_key = false,
            unique = false,
            blank = false,
            null = false,
            db_index = false,
            default = nothing,
            editable = true,
            type = "INTEGER",
            formater = Models.format_number_sql
        )
    ),
    field_names = ["price", "quantity"],
    id_field = nothing,
    related_objects = Dict(),
    module_name = :test,
    exports = Symbol[],
    # ... other required fields
)
```

### 1.3 Test `validate_field_data`

Tested against the mock model above (heavily commented to explain logic and expected behavior):

- **`max_digits` validation for `DecimalField`**:
  - Valid: `123.45` (5 total digits, within `max_digits=10`)
  - Valid: `-999.99` (5 total digits, sign not counted)
  - Invalid: `12345678.99` (10 total digits, exceeds `max_digits=10` - should raise error)
  - Edge case: scientific notation `1.23e2` → should expand to `123` and validate correctly
- **`null=false` enforcement**:
  - Valid: `"123.45"` with `null=false`
  - Invalid: `nothing` with `null=false` → should raise error
  - Valid: `nothing` with `null=true`
- **`max_length` for `CharField`**: Already tested elsewhere; reference existing tests.

### 1.4 Test Formatters (`format_number_sql`, etc.)

Direct unit tests on pure formatter functions (heavily commented):

- **`format_number_sql` with valid inputs**:
  - `Float64`: `123.456` → `"123.456"` (uses `@sprintf("%.17g", ...)` to avoid sci notation)
  - `Int64`: `123` → `"123"`
  - `Decimals.Decimal`: `Decimal("123.45")` → `"123.45"`
- **`format_number_sql` with invalid/edge-case inputs**:
  - String with comma: `"123,45"` → should reject with clear error message
  - Valid numeric string: `"123.45"` → should parse and format correctly
  - Scientific notation string: `"1.23e2"` → decision required (see Further Considerations)
  - Extremely high precision: test against `Decimal` type's limits

## Phase 2: Integration Testing (Bulk Operations)

**Timing**: Can run in parallel with Phase 1 once Phase 1 unit test stubs are in place.

### 2.1 Extend [test/integration/test_bulk_copy.jl](test/integration/test_bulk_copy.jl)

Add test cases for `bulk_insert`, `bulk_update`, and `bulk_copy` with type-stress scenarios (against live F1 dataset models):

- **Type enforcement (non-coercion per policy)**:
  - Attempt `bulk_insert` with `Float64` vector into `IntegerField` → should raise validation error
  - Verify error message includes field name, expected type, and actual type
- **Missing value handling**:
  - Insert `Vector` with `missing` values into nullable field → should succeed
  - Insert `Vector` with `missing` values into required field → should raise error
  - Update with `missing` in optional vs. required fields
- **Decimal precision in bulk context**:
  - Insert `DecimalField` values exceeding `max_digits` → verify rejection before DB hit
  - Insert valid precision but high number of decimal places → verify database-level rounding behavior (if applicable)
- **Error reporting clarity**:
  - Verify that FK violations during `bulk_insert` include row number, field name, and constraint info
  - Test duplicate key violations during bulk insert (if `unique=true` field)

## Relevant files
- [src/querybuilder/sanitization.jl](src/querybuilder/sanitization.jl) — Contains `validate_field_data` logic.
- [src/Models.jl](src/Models.jl) — Contains `format_number_sql` and other formatter definitions.
- [src/models/fields.jl](src/models/fields.jl) — Define field behavior/metadata (e.g., `DecimalField`).

## Testing Guidelines

**All tests must be heavily commented** (per project pedagogy guidelines):
- Explain the **logic**: What behavior are we testing and why does it matter?
- Explain the **expected outcome**: What should happen and why?
- Explain the **why**: Why is this edge case important for users or database safety?

**Example comment style**:
```julia
# Test that max_digits validation correctly rejects values with too many digits.
# This is critical because DecimalField(max_digits=5, decimal_places=2) should
# only allow values like 999.99, not 9999.99. The validation counts digits
# after removing the sign (-) and decimal point (.), so -999.99 = 5 digits.
@test_throws ErrorException validate_field_data(
    mock_decimal_model, "price", 9999.99, "insert"
)
```

## Verification

1. **Unit tests**: `julia --project=. test/unit/test_fields_validation.jl`
2. **Integration tests**: `julia -t auto --project=. test/integration/test.jl` (or run full suite)
3. **Alignment**: Confirm that test coverage addresses TODO items (see references below)

## Key Definitions

- **Validation**: Ensuring data conforms to field constraints (`max_digits`, `null`, `max_length`, type checking).
- **Normalization**: Converting valid Julia/String types to SQL-safe format (e.g., `format_number_sql` converts `Float64` to string).
- **Strict policy**: Reject type mismatches; do not auto-coerce (e.g., `14.0` to `14` is rejected for `IntegerField`).

## TODO References

This plan directly addresses **TODO.md** items:
- `[x] Refactor QueryBuilder Parameter Handling` — Parameter handling depends on correct type validation.
- `[ ] Dataframes Type Normalization` — Implements the foundation for bulk operation type checking.
- `[ ] Extend test coverage for date/time functions` — unit tests will validate `DateField` and `DateTimeField` formatters.

## Scope & Out-of-Scope

**In Scope**:
- Unit testing of pure validation and formatter functions
- Integration testing of bulk operations with type-stress scenarios
- Enhanced error messages for validation failures

**Out of Scope** (for future consideration):
- Automatic data transformation (e.g., `transform` keyword on fields)
- Database-side coercion behavior (e.g., PostgreSQL's implicit casts)
- Schema migration coercion rules

## Further Considerations

1. **Scientific notation handling (Finalized Decision)**:
   - **Numeric Inputs (`Float`, `Int`)**: PormG will **expand** the value into a fixed-point string representation (removing `e/E`) **before** counting digits for `max_digits` validation. This ensures `1.23e2` is correctly validated as `123` (3 digits).
   - **String Inputs (`"123.45"`)**: PormG will **reject** strings containing `e` or `E`. Users must provide the literal decimal representation to ensure the "Source of Truth" is explicit and unambiguous.
   - **Database Generation**: `format_number_sql` will continue to use non-scientific formatting to ensure maximum compatibility across dialects (PostgreSQL, SQLite, etc.).

2. **Custom transformation logic**: Should we add a `transform` keyword to fields (e.g., `DecimalField(transform=x -> Float64(x))`) to allow user-defined type coercion? (Recommendation: Keep out of scope for now; add if field validation becomes a bottleneck in user workflows.)

3. **Decimal type support**: Currently testing assumes `Decimals.Decimal` is available. Confirm it's an optional dependency or decide on a lightweight decimal library.
