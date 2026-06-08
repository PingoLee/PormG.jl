
const SAFE_IDENTIFIER_PATTERN = r"^[\p{L}_][\p{L}\p{M}\p{N}_]*$"

function _validate_identifier(identifier::String)::String
    if !occursin(SAFE_IDENTIFIER_PATTERN, identifier)
        throw(ArgumentError("Invalid SQL identifier: $identifier"))
    end
    return identifier
end

"""
Sanitize SQL identifiers (table names, column names) to prevent injection.
Only allows Unicode letters, combining marks, numbers, underscores, and validates
against model schema.
"""
function sanitize_identifier(identifier::String, valid_identifiers::Vector{String})::String
    # Validate against whitelist
    if !(identifier in valid_identifiers)
        throw(ArgumentError("Invalid identifier: $identifier"))
    end
    
    return quote_identifier(identifier, nothing)
end

"""
Escape LIKE patterns to prevent wildcard injection
"""
function escape_like_pattern(pattern::String)::String
    # Escape special LIKE characters
    escaped = replace(pattern, "\\" => "\\\\")
    escaped = replace(escaped, "%" => "\\%")
    escaped = replace(escaped, "_" => "\\_")
    return escaped
end

"""
Quote SQL identifiers based on database type
"""
function quote_identifier(identifier::String, conn)::String
    return "\"$(_validate_identifier(identifier))\""
end

"""
Validate and quote table name
"""
function safe_table_identifier(table_name::String, conn)::String
    return quote_identifier(table_name, conn)
end

"""
Validate field name against model and return quoted identifier
"""
function safe_field_identifier(field_name::String, model::PormGModel, conn)::String
    # Validate field exists in model
    if !(field_name in model.field_names)
        throw(ArgumentError("Invalid field name: $field_name for model $(model.name)"))
    end
    return quote_identifier(field_name, conn)
end

"""
    validate_field_data(model::PormGModel, field::String, value::Any, operation::String; allow_primary_key::Bool = true)

Validates that a value is compatible with the model field definition before SQL generation.
Checks:
1. Field existence in model.
2. Primary key modification protection (disabled if allow_primary_key is false).
3. Max length for CharFields.
4. Max digits for Decimal/Numeric fields.

Returns `true` if valid, throws an `ErrorException` otherwise.
SQL expressions (SQLTypeF, SQLTypeFunction) skip data validation as they are evaluated by the DB.
"""
function _validation_error(operation::String, model::PormGModel, field::String, message::String; suggestion::Union{Nothing, String}=nothing)
    suffix = suggestion === nothing ? "" : " Suggested fix: $suggestion"
    error("Error in $operation for model $(model.name), field \"$field\": $message$suffix")
end

function _type_mismatch_error(operation::String, model::PormGModel, field::String, value::Any, expected::String; suggestion::Union{Nothing, String}=nothing)
    actual_type = value === nothing ? "Nothing" : ismissing(value) ? "Missing" : string(typeof(value))
    preview = value === nothing || ismissing(value) ? "" : " (value=$(repr(value)))"
    _validation_error(operation, model, field, "expected $expected, got $actual_type$preview"; suggestion=suggestion)
end

function _is_integer_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("INTEGER", "BIGINT")
end

function _is_decimal_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "DECIMAL"
end

function _is_float_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("FLOAT", "DOUBLE PRECISION")
end

function _is_decimal_like_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("DECIMAL", "FLOAT", "DOUBLE PRECISION")
end

function _is_date_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "DATE"
end

function _is_time_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "TIME"
end

function _is_duration_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "INTERVAL"
end

function _is_datetime_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("TIMESTAMPTZ", "TIMESTAMP")
end

function _is_uuid_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "UUID"
end

function _is_json_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("JSON", "JSONB")
end

function _string_uses_scientific_notation(value::AbstractString)::Bool
    return occursin(r"^[+-]?(?:\d+\.?\d*|\.\d+)[eE][+-]?\d+$", strip(value))
end

function _expand_scientific_notation(value::AbstractString)::String
    match_result = match(r"^([+-]?)(\d+)(?:\.(\d+))?[eE]([+-]?\d+)$", value)
    match_result === nothing && return value

    sign, integer_part, fractional_part, exponent_str = match_result.captures
    fractional_part = fractional_part === nothing ? "" : fractional_part
    exponent = parse(Int, exponent_str)
    digits = integer_part * fractional_part
    decimal_index = length(integer_part)
    target_index = decimal_index + exponent

    if target_index <= 0
        return string(sign, "0.", repeat("0", -target_index), digits)
    elseif target_index >= length(digits)
        return string(sign, digits, repeat("0", target_index - length(digits)))
    end

    return string(sign, digits[1:target_index], ".", digits[target_index + 1:end])
end

function _trim_fixed_point(value::AbstractString)::String
    trimmed = value
    if occursin('.', trimmed)
        trimmed = replace(trimmed, r"0+$" => "")
        trimmed = replace(trimmed, r"\.$" => "")
    end
    return trimmed in ("-0", "+0", "") ? "0" : trimmed
end

function _normalized_numeric_string(value)::String
    base = if value isa AbstractString
        strip(Models.format_number_sql(value))
    elseif value isa Integer
        string(value)
    elseif value isa AbstractFloat || value isa Decimals.Decimal
        string(value)
    else
        formatted = Models.format_number_sql(value)
        formatted isa AbstractString ? strip(formatted) : string(formatted)
    end

    return _trim_fixed_point(_expand_scientific_notation(base))
end

function _count_numeric_digits(value)::Int
    value_str = _normalized_numeric_string(value)
    digits_only = replace(value_str, r"^[+-]" => "")
    digits_only = replace(digits_only, "." => "")
    return isempty(digits_only) ? 0 : length(digits_only)
end

function _count_decimal_places(value)::Int
    value_str = _normalized_numeric_string(value)
    point_index = findfirst(==('.'), value_str)
    point_index === nothing && return 0
    return length(value_str) - point_index
end

function _validate_integer_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="pass 0 or 1 as Int64, not Bool")
    elseif value isa Integer
        return true
    elseif value isa Decimals.Decimal
        try
            Int64(value)
            return true
        catch
            _type_mismatch_error(operation, model, field, value, "Int64, an integer-valued Decimal, or an integer string"; suggestion="round or convert the Decimal to Int64 before calling $operation")
        end
    elseif value isa AbstractString
        stripped = strip(value)
        if _string_uses_scientific_notation(stripped)
            _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="replace scientific notation with a literal integer string like \"123\"")
        end
        if tryparse(Int64, stripped) === nothing
            _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="convert the value to Int64 before calling $operation")
        end
        return true
    elseif value isa AbstractFloat
        _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="convert the value with Int64(...) before calling $operation")
    else
        _type_mismatch_error(operation, model, field, value, "Int64, an integer-valued Decimal, or an integer string")
    end
end

function _validate_decimal_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "a numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a literal numeric string")
    elseif value isa Integer || value isa Decimals.Decimal
        return true
    elseif value isa AbstractFloat
        isfinite(value) || _validation_error(operation, model, field, "non-finite numeric values are not allowed"; suggestion="pass a finite Float64 value")
        return true
    elseif value isa AbstractString
        try
            Models.format_number_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a literal numeric string like \"123.45\" or a Julia numeric value")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a literal numeric string")
    end
end

function _validate_float_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "a finite numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a parseable numeric string")
    elseif value isa Integer || value isa Decimals.Decimal
        return true
    elseif value isa AbstractFloat
        isfinite(value) || _validation_error(operation, model, field, "non-finite numeric values are not allowed"; suggestion="pass a finite Float64 value")
        return true
    elseif value isa AbstractString
        stripped = strip(value)
        isempty(stripped) && _validation_error(operation, model, field, "the value is empty and cannot be used as a number"; suggestion="pass a parseable numeric string like \"123.45\"")
        if occursin(r"^[+-]?\d+,\d+$", stripped)
            _validation_error(operation, model, field, "comma decimal separators are not supported"; suggestion="use '.' as the decimal separator")
        end
        parsed = tryparse(Float64, stripped)
        parsed === nothing && _type_mismatch_error(operation, model, field, value, "a finite numeric value or numeric string"; suggestion="pass a parseable numeric string like \"123.45\" or \"1.23e4\"")
        isfinite(parsed) || _validation_error(operation, model, field, "non-finite numeric values are not allowed"; suggestion="pass a finite Float64 value")
        return true
    else
        _type_mismatch_error(operation, model, field, value, "a finite numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a parseable numeric string")
    end
end

function _validate_date_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Union{Date, DateTime, ZonedDateTime}
        return true
    elseif value isa AbstractString
        try
            Models.format_date_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a Date, DateTime, ZonedDateTime, or a YYYY-MM-DD string")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a Date, DateTime, ZonedDateTime, or YYYY-MM-DD string"; suggestion="normalize the value to a calendar date before calling $operation")
    end
end

function _validate_time_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Time
        return true
    elseif value isa AbstractString
        # Standard HH:MM or HH:MM:SS
        if occursin(r"^\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?$", value)
            try
                # Try to parse as Time to validate ranges
                Time(value)
                return true
            catch e
                _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a Time object or a valid HH:MM:SS string")
            end
        else
            _validation_error(operation, model, field, "invalid time format: $value"; suggestion="pass a Time object or an HH:MM:SS string")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a Time object or time string"; suggestion="use Time(...) or normalize to HH:MM:SS")
    end
end

function _validate_duration_value(model::PormGModel, field::String, value::Any, operation::String)
    try
        Models.format_duration_sql(value)
        return true
    catch e
        if value isa Union{Period, Dates.CompoundPeriod, AbstractString}
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a Period, CompoundPeriod, or a duration string like \"1:27.452\"")
        else
            _type_mismatch_error(operation, model, field, value, "a Period, CompoundPeriod, or duration string"; suggestion="use Minute(1) + Second(27) + Millisecond(452) or a string like \"1:27.452\"")
        end
    end
end

function _validate_datetime_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Union{DateTime, ZonedDateTime}
        return true
    elseif value isa AbstractString
        try
            Models.format_timezone_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a DateTime, ZonedDateTime, or a datetime string matching the configured timestamp format")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a DateTime, ZonedDateTime, or timezone-aware datetime string"; suggestion="use DateTime(...) or ZonedDateTime(...)")
    end
end

function _validate_uuid_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa UUIDs.UUID
        return true
    elseif value isa AbstractString
        try
            Models.format_uuid_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a UUID or a string in the format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a UUID or UUID-formatted string"; suggestion="use UUIDs.uuid4() or a string like \"550e8400-e29b-41d4-a716-446655440000\"")
    end
end

function _validate_json_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Union{AbstractDict, AbstractVector, NamedTuple, Bool, Integer, AbstractFloat}
        return true
    elseif value isa AbstractString
        try
            Models.format_json_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a valid JSON string, Dict, Vector, or scalar value")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a valid JSON value (Dict, Vector, String, Number, Bool)"; suggestion="serialize to a JSON string or use a Dict/Vector")
    end
end

function validate_field_data(model::PormGModel, field::String, value::Any, operation::String; allow_primary_key::Bool = true)
    if haskey(model.fields, field) && Models.is_many_to_many_field(model.fields[field])
        _validation_error(operation, model, field, "many-to-many relations are not physical columns"; suggestion="use the many-to-many manager add!, remove!, clear!, or set! methods")
    end

    # 1. Field existence
    if !(field in model.field_names)
        _validation_error(operation, model, field, "field does not exist in the model schema")
    end
    
    f_meta = model.fields[field]
    
    # 2. Primary key protection
    if !allow_primary_key && f_meta.primary_key
        _validation_error(operation, model, field, "primary keys cannot be modified in this operation")
    end

    # 3. Nullability check
    if !f_meta.null && (value === nothing || ismissing(value))
        _validation_error(operation, model, field, "null values are not allowed")
    elseif value === nothing || ismissing(value)
        return true
    end

    # 4. Skip further validation for SQL expressions (F-expressions, Functions)
    if value isa SQLTypeF || value isa SQLTypeFunction
        return true
    end

    # 5. Type validation for numeric fields.
    if _is_integer_field(f_meta)
        _validate_integer_value(model, field, value, operation)
    elseif _is_decimal_field(f_meta)
        _validate_decimal_value(model, field, value, operation)
    elseif _is_float_field(f_meta)
        _validate_float_value(model, field, value, operation)
    elseif _is_date_field(f_meta)
        _validate_date_value(model, field, value, operation)
    elseif _is_time_field(f_meta)
        _validate_time_value(model, field, value, operation)
    elseif _is_duration_field(f_meta)
        _validate_duration_value(model, field, value, operation)
    elseif _is_datetime_field(f_meta)
        _validate_datetime_value(model, field, value, operation)
    elseif _is_decimal_like_field(f_meta)
        _validate_decimal_value(model, field, value, operation)
    elseif _is_uuid_field(f_meta)
        _validate_uuid_value(model, field, value, operation)
    elseif _is_json_field(f_meta)
        _validate_json_value(model, field, value, operation)
    end
    
    # 6. Max length validation (Strings)
    if hasfield(typeof(f_meta), :max_length) && isa(value, AbstractString)
        if length(value) > f_meta.max_length
            _validation_error(operation, model, field, "max_length is $(f_meta.max_length), but the provided value has length $(length(value))")
        end
    end
    
    # 7. Max digits validation (Decimals/Floats)
    if hasfield(typeof(f_meta), :max_digits)
        digit_count = _count_numeric_digits(value)
        if digit_count > f_meta.max_digits
            _validation_error(operation, model, field, "max_digits is $(f_meta.max_digits), but the normalized numeric value uses $digit_count digits")
        end
    end

    # 8. Decimal scale validation (DecimalField)
    if _is_decimal_field(f_meta) && hasfield(typeof(f_meta), :decimal_places)
        decimal_places = _count_decimal_places(value)
        if decimal_places > f_meta.decimal_places
            _validation_error(operation, model, field, "decimal_places is $(f_meta.decimal_places), but the normalized numeric value uses $decimal_places fractional digits")
        end
    end
    
    return true
end
