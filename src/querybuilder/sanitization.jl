
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