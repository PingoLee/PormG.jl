
"""
Sanitize SQL identifiers (table names, column names) to prevent injection.
Only allows alphanumeric characters, underscores, and validates against model schema.
"""
function sanitize_identifier(identifier::String, valid_identifiers::Vector{String})::String
    # Remove any non-alphanumeric/underscore characters
    clean_id = replace(identifier, r"[^a-zA-Z0-9_]" => "")
    
    # Validate against whitelist
    if !(clean_id in valid_identifiers)
        throw(ArgumentError("Invalid identifier: $identifier"))
    end
    
    return "\"$clean_id\""  # Quote the identifier
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
    clean_id = replace(identifier, r"[^a-zA-Z0-9_]" => "")
    return "\"$clean_id\""
end

"""
Validate and quote table name
"""
function safe_table_identifier(table_name::String, conn)::String
    clean_name = replace(table_name, r"[^a-zA-Z0-9_]" => "")
    
    if clean_name != table_name
        @warn "Table name contains invalid characters, sanitized: $table_name -> $clean_name"
    end
    
    return quote_identifier(clean_name, conn)
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

function _is_decimal_like_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("DECIMAL", "DOUBLE PRECISION")
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

function _validate_integer_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="pass 0 or 1 as Int64, not Bool")
    elseif value isa Integer
        return true
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
        _type_mismatch_error(operation, model, field, value, "Int64 or an integer string")
    end
end

function _validate_decimal_like_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "a numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a literal numeric string")
    elseif value isa Integer || value isa AbstractFloat || value isa Decimals.Decimal
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

function validate_field_data(model::PormGModel, field::String, value::Any, operation::String; allow_primary_key::Bool = true)
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
    elseif _is_decimal_like_field(f_meta)
        _validate_decimal_like_value(model, field, value, operation)
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
    
    return true
end
