
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
function validate_field_data(model::PormGModel, field::String, value::Any, operation::String; allow_primary_key::Bool = true)
    # 1. Field existence
    if !(field in model.field_names)
        error("Error in $operation, the field \"$field\" not found in $(model.name)")
    end
    
    f_meta = model.fields[field]
    
    # 2. Primary key protection
    if !allow_primary_key && f_meta.primary_key
        error("Error in $operation, the field \e[4m\e[31m$field\e[0m is a primary key and not allow to update")
    end

    # 3. Nullability check
    if !f_meta.null && (value === nothing || ismissing(value))
        error("Error in $operation, the field \e[4m\e[31m$field\e[0m does not allow null values")
    end
    
    # 4. Skip further validation for SQL expressions (F-expressions, Functions)
    if value isa SQLTypeF || value isa SQLTypeFunction
        return true
    end
    
    # 4. Max length validation (Strings)
    if hasfield(typeof(f_meta), :max_length) && isa(value, AbstractString)
        if length(value) > f_meta.max_length
            error("Error in $operation, the field \e[4m\e[31m$field\e[0m has a max_length of \e[4m\e[32m$(f_meta.max_length)\e[0m, but the value has \e[4m\e[31m$(length(value))\e[0m")
        end
    end
    
    # 5. Max digits validation (Decimals/Floats)
    if hasfield(typeof(f_meta), :max_digits)
        # Use a robust digit counter (excludes sign and dot)
        value_str = replace(string(value), "-" => "", "." => "")
        if length(value_str) > f_meta.max_digits
            error("Error in $operation, the field \e[4m\e[31m$field\e[0m has a max_digits of \e[4m\e[32m$(f_meta.max_digits)\e[0m, but the value has \e[4m\e[31m$(length(value_str))\e[0m")
        end
    end
    
    return true
end
