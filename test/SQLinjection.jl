# I want prevent sql injection, can you help me trace a plan to intruce this in PormG?

# Looking at your PormG codebase, I can see several areas where SQL injection vulnerabilities exist. Here's a comprehensive plan to introduce SQL injection prevention:

# Current Vulnerabilities Identified
# Direct string interpolation in queries (QueryBuilder.jl)
# Unescaped user input in filter values
# Dynamic SQL construction without parameterization
# Raw field names and table names inserted directly
# Implementation Plan
# Phase 1: Core Infrastructure
# 1.1 Add Parameterized Query Support

# Add after existing imports

mutable struct ParameterizedQuery
    sql::String
    parameters::Vector{Any}
    parameter_count::Int
    
    ParameterizedQuery() = new("", Any[], 0)
end

function add_parameter!(pq::ParameterizedQuery, value::Any)::String
    pq.parameter_count += 1
    push!(pq.parameters, value)
    return "\$$(pq.parameter_count)"  # PostgreSQL style
end

function add_parameter_sqlite!(pq::ParameterizedQuery, value::Any)::String
    pq.parameter_count += 1
    push!(pq.parameters, value)
    return "?"  # SQLite style
end

# 1.2 Create SQL Sanitization Module

module SQLSanitizer

import PormG: PormGPostgres, PormGSQLite
using SQLite, LibPQ

export sanitize_identifier, sanitize_value, escape_like_pattern

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
Validate and format values for parameterized queries
"""
function prepare_value_for_parameter(value::Any)::Any
    if value isa String
        return value  # Will be properly escaped by driver
    elseif value isa Number || value isa Bool || value isa Date || value isa DateTime
        return value
    elseif value === nothing || ismissing(value)
        return nothing
    else
        # Convert to string as fallback, but log warning
        @warn "Converting value of type $(typeof(value)) to string for SQL parameter"
        return string(value)
    end
end

end



# Phase 2: Update Core Query Building
# 2.1 Modify SQLInstruction to Support Parameters
# Modify the InstrucObject struct

@kwdef mutable struct InstrucObject <: SQLInstruction
    text::String
    table_alias::SQLTableAlias
    alias::String
    object::SQLObject
    select::Vector{SQLTypeField} = Array{SQLTypeField, 1}(undef, 60)
    join::Vector{String} = []
    _where::Vector{String} = []
    # Add parameterized query support
    parameterized_query::ParameterizedQuery = ParameterizedQuery()
    # ...existing code...
    agregate::Bool = false
    group::Vector{String} = []
    having::Vector{String} = []
    order::Vector{String} = []
    row_join::Vector{Dict{String, Any}} = []
    tab_field_cache::Dict{String, PormGField} = sizehint!(Dict{String, PormGField}(), 12)
    connection::Union{SQLite.DB, PormGPostgres, Nothing} = nothing
    array_defs::SQLTypeArrays = SQLArrays()
    cache::Dict{String, SQLTypeField} = sizehint!(Dict{String, SQLTypeField}(), 12)
    django::Union{Nothing, String} = nothing
end

# 2.2 Update Filter Query Generation
function _get_filter_query(v::SQLTypeOper, instruc::SQLInstruction)
    using .SQLSanitizer
    
    @infiltrate false
    
    # Get the column part (already handles joins, etc.)
    column = _get_filter_query(v.column, instruc)
    
    # Handle different value types securely
    if isa(v.values, SQLTypeF)
        # F expressions are safe since they reference model fields
        value = _get_filter_query(v.values, instruc)
        return string(column, " ", v.operator, " ", value)
        
    elseif isa(v.values, SQLObjectHandler)
        # Subqueries - these are safe since they're built through our system
        if !(v.operator in ["in", "not in"])
            throw("Error in values, $(v.values) is not a SQLObjectHandler")
        end
        value = query(v.values, table_alias=instruc.table_alias, connection=instruc.connection)
        return string(column, " ", v.operator, " ($value)")
        
    else
        # User-provided values - use parameterized queries
        if v.operator in ["ISNULL"]
            return getfield(QueryBuilder, Symbol(v.operator))(column, v.values)
            
        elseif v.operator in ["contains", "icontains"]
            # Special handling for LIKE operations
            safe_pattern = escape_like_pattern(string(v.values))
            param_placeholder = if instruc.connection isa PormGPostgres
                add_parameter!(instruc.parameterized_query, "%$(safe_pattern)%")
            else
                add_parameter_sqlite!(instruc.parameterized_query, "%$(safe_pattern)%")
            end
            
            operator_sql = v.operator == "contains" ? "LIKE" : "ILIKE"
            return string(column, " ", operator_sql, " ", param_placeholder)
            
        elseif v.operator in ["=", ">", "<", ">=", "<=", "<>", "!="]
            # Use parameterized query for the value
            safe_value = prepare_value_for_parameter(v.values)
            param_placeholder = if instruc.connection isa PormGPostgres
                add_parameter!(instruc.parameterized_query, safe_value)
            else
                add_parameter_sqlite!(instruc.parameterized_query, safe_value)
            end
            return string(column, " ", v.operator, " ", param_placeholder)
            
        elseif v.operator in ["in", "not in"]
            # Handle IN clauses with multiple parameters
            if !isa(v.values, Vector)
                throw(ArgumentError("IN operator requires a vector of values"))
            end
            
            placeholders = String[]
            for val in v.values
                safe_val = prepare_value_for_parameter(val)
                placeholder = if instruc.connection isa PormGPostgres
                    add_parameter!(instruc.parameterized_query, safe_val)
                else
                    add_parameter_sqlite!(instruc.parameterized_query, safe_val)
                end
                push!(placeholders, placeholder)
            end
            
            return string(column, " ", v.operator, " (", join(placeholders, ", "), ")")
            
        else
            throw("Error in operator, $(v.operator) is not a valid operator")
        end
    end
end

# Phase 3: Update Execution Layer
# 3.1 Modify Configuration.jl fetch function
# Add parameterized query execution

function fetch_parameterized(connection::PormGPostgres, sql::String, parameters::Vector{Any}; conn::Union{Nothing, LibPQ.Connection} = nothing)
    @infiltrate false
    conn === nothing && (conn = acquire_connection(connection))
    try
        # Use LibPQ's parameterized query support
        return LibPQ.execute(conn, sql, parameters)
    catch e
        @infiltrate
        if is_connection_error(e, connection)
            @warn "Lost connection to database. Attempting to reconnect..."
            conn = reconnect_db(connection, conn)
            return LibPQ.execute(conn, sql, parameters)
        end
        @error "Failed to execute parameterized SQL query: $e" sql=sql parameters=parameters
        throw(e)
    finally
        release_connection(connection, conn)
    end
end

function fetch_parameterized(connection::SQLite.DB, sql::String, parameters::Vector{Any})
    try
        stmt = SQLite.Stmt(connection, sql)
        # Bind parameters
        for (i, param) in enumerate(parameters)
            SQLite.bind!(stmt, i, param)
        end
        return SQLite.execute(stmt)
    catch e
        @error "Failed to execute parameterized SQLite query: $e" sql=sql parameters=parameters
        throw(e)
    end
end

# Wrapper for settings
fetch_parameterized(settings::SQLConn, sql::String, parameters::Vector{Any}; conn::Union{Nothing, LibPQ.Connection} = nothing) = 
    fetch_parameterized(settings.connections, sql, parameters; conn=conn)

# 3.2 Update Main Query Execution
# Update the list function to use parameterized queries

function list(objct::SQLObjectHandler)
    if objct.object.model.connect_key === nothing
        throw(ArgumentError("Error in list, the model $(objct.object.model.name) not have a build correctly, please reload the app"))
    end
    
    settings = config[objct.object.model.connect_key]
    connection = settings.connections

    # Build the query with parameterization
    instruction = build(objct.object, connection=connection)
    sql = build_parameterized_sql(objct, instruction)
    
    @infiltrate false
    
    # Execute with parameters if any exist
    if !isempty(instruction.parameterized_query.parameters)
        return fetch_parameterized(settings, instruction.parameterized_query.sql, 
                                 instruction.parameterized_query.parameters)
    else
        return fetch(settings, sql)  # Fallback for queries without parameters
    end
end

function build_parameterized_sql(objct::SQLObjectHandler, instruction::SQLInstruction)::String
    # Store the parameterized SQL in the instruction
    sql = """
    SELECT
      $(objct.object.distinct ? "DISTINCT" : "") $(_query_select(instruction.select))
    FROM $(objct.object.model.name) as $(instruction.alias)
    $(join(instruction.join, "\n"))
    """
    
    if !isempty(instruction._where)
        sql *= "WHERE " * join(instruction._where, " AND \n   ") * "\n"
    end
    if instruction.agregate && size(instruction.group, 1) > 0
        sql *= "GROUP BY $(join(instruction.group, ", ")) \n"
    end
    if !isempty(instruction.having)
        sql *= "HAVING " * join(instruction.having, " AND \n   ") * "\n"
    end
    if !isempty(instruction.order)
        sql *= "ORDER BY " * join(instruction.order, ", \n  ") * "\n"
    end
    if objct.object.limit !== 0
        sql *= "LIMIT $(objct.object.limit) \n"
    end
    if objct.object.offset !== 0
        sql *= "OFFSET $(objct.object.offset) \n"
    end
    
    instruction.parameterized_query.sql = sql
    return sql
end

# Phase 4: Additional Security Measures
# 4.1 Add Input Validation
# Add validation functions

function validate_field_name(field_name::String, model::PormGModel)::String
    using .SQLSanitizer
    
    # Split on __ to handle joins
    parts = split(field_name, "__")
    valid_fields = vcat(model.field_names, collect(keys(model.related_objects)))
    
    # Validate the first part against model fields
    if !(parts[1] in valid_fields)
        throw(ArgumentError("Invalid field name: $(parts[1]) for model $(model.name)"))
    end
    
    return sanitize_identifier(field_name, [field_name])  # Allow the full field path
end

function validate_operator(operator::String)::String
    valid_operators = ["=", ">", "<", ">=", "<=", "<>", "!=", "in", "not in", 
                      "contains", "icontains", "ISNULL", "startswith", "endswith"]
    
    if !(operator in valid_operators)
        throw(ArgumentError("Invalid operator: $operator"))
    end
    
    return operator
end

# Phase 5: Update Model Field Formatters
function format_string_for_parameter(v::Union{String, Missing, Nothing})::Union{String, Nothing}
    if ismissing(v) || v === nothing
        return nothing
    else
        return string(v)  # Don't add quotes - parameterized query will handle this
    end
end

function format_integer_for_parameter(v::Union{Integer, String, Missing, Nothing})::Union{Integer, Nothing}
    if ismissing(v) || v === nothing
        return nothing
    elseif v isa Integer
        return v
    else
        try
            return parse(Int, string(v))
        catch
            throw(ArgumentError("Cannot convert $v to integer"))
        end
    end
end

# Phase 6: Testing and Migration
# 6.1 Add Tests

using Test
using PormG

@testset "SQL Injection Prevention" begin
    @testset "Basic Parameter Injection" begin
        query = M.Status |> object
        # This should be safely parameterized
        query.filter("status" => "'; DROP TABLE status; --")
        
        # Should not throw an error and should not execute the injection
        @test_nowarn query |> do_count
    end
    
    @testset "Field Name Validation" begin
        query = M.Status |> object
        
        # Invalid field names should throw errors
        @test_throws ArgumentError query.filter("invalid_field" => "test")
        @test_throws ArgumentError query.filter("status; DROP TABLE" => "test")
    end
    
    @testset "LIKE Pattern Escaping" begin
        query = M.Status |> object
        
        # Special LIKE characters should be escaped
        query.filter("status__@contains" => "test_%_pattern")
        sql = query |> show_query
        
        # Should contain escaped patterns
        @test !occursin("test_%_pattern", sql)  # Raw pattern shouldn't appear
    end
end