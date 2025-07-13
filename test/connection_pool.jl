# Core ConnectionPool Structure

mutable struct PostgresConnectionPool <: PormGPostgres
    connections::Vector{Union{Nothing, LibPQ.Connection}}
    available::Vector{Bool}
    connection_string::String
    pool_size::Int
    adapter::String
    lock::ReentrantLock
    # ... constructor as before ...
end

mutable struct SQLiteConnectionPool <: PormGSQLite
    connections::Vector{Union{Nothing, SQLite.DB}}
    available::Vector{Bool}
    connection_string::String
    pool_size::Int
    adapter::String
    lock::ReentrantLock
    # ... constructor as before ...
end

function create_pool(conn_str::String, adapter::String; pool_size::Int = 10)
    if adapter == "PostgreSQL"
        return PostgresConnectionPool(conn_str, adapter, pool_size = pool_size)
    elseif adapter == "SQLite"
        return SQLiteConnectionPool(conn_str, adapter, pool_size = pool_size)
    else
        throw(ArgumentError("Unsupported adapter: $adapter"))
    end
end


# Initialize the pool with actual connections
function initialize_pool!(pool::Union{PostgresConnectionPool, SQLiteConnectionPool})
    Base.lock(pool.lock) do
        for i in 1:pool.pool_size
            try
                if pool.adapter == "PostgreSQL"
                    pool.connections[i] = LibPQ.Connection(pool.connection_string)
                elseif pool.adapter == "SQLite"
                    # For SQLite, each connection should point to the same file
                    db_path = extract_sqlite_path(pool.connection_string)
                    pool.connections[i] = SQLite.DB(db_path)
                end
                pool.available[i] = true
            catch e
                @error "Failed to create connection $i: $e"
                pool.connections[i] = nothing
                pool.available[i] = false
            end
        end
    end
end

function extract_sqlite_path(connection_string::String)
    # Extract database path from connection string
    # This depends on how you format your SQLite connection strings
    return connection_string
end


# Connection Management Functions
// ...existing code...

function acquire_connection(pool::Union{PostgresConnectionPool, SQLiteConnectionPool}; timeout::Float64 = 30.0)
    start_time = time()
    
    while time() - start_time < timeout
        Base.lock(pool.lock) do
            for i in 1:length(pool.connections)
                if pool.available[i] && pool.connections[i] !== nothing
                    # Check if connection is still alive
                    if is_connection_alive(pool.connections[i], pool.adapter)
                        pool.available[i] = false
                        return pool.connections[i]
                    else
                        # Reconnect if connection is dead
                        try
                            pool.connections[i] = create_new_connection(pool.connection_string, pool.adapter)
                            pool.available[i] = false
                            return pool.connections[i]
                        catch e
                            @warn "Failed to reconnect connection $i: $e"
                            pool.connections[i] = nothing
                            pool.available[i] = false
                        end
                    end
                end
            end
        end
        
        # Wait a bit before trying again
        sleep(0.1)
    end
    
    throw(ArgumentError("No available connections in the pool after $(timeout) seconds timeout"))
end

function release_connection(pool::Union{PostgresConnectionPool, SQLiteConnectionPool}, conn::Union{LibPQ.Connection, SQLite.DB})
    Base.lock(pool.lock) do
        for i in 1:length(pool.connections)
            if pool.connections[i] === conn
                pool.available[i] = true
                return true
            end
        end
    end
    @warn "Connection not found in the pool"
    return false
end

function is_connection_alive(conn::Union{LibPQ.Connection, SQLite.DB}, adapter::String)
    try
        if adapter == "PostgreSQL" && conn isa LibPQ.Connection
            return LibPQ.status(conn) == LibPQ.CONNECTION_OK
        elseif adapter == "SQLite" && conn isa SQLite.DB
            # For SQLite, try a simple query
            SQLite.execute(conn, "SELECT 1")
            return true
        end
    catch
        return false
    end
    return false
end

function create_new_connection(connection_string::String, adapter::String)
    if adapter == "PostgreSQL"
        return LibPQ.Connection(connection_string)
    elseif adapter == "SQLite"
        return SQLite.DB(connection_string)
    else
        throw(ArgumentError("Unsupported adapter: $adapter"))
    end
end

# Integration with Settings

// ...existing code...

mutable struct Settings <: SQLConn
    app_env::String
    db_def_folder::String
    model_file::String
    db_config_settings::Dict{String,Any}
    log_queries::Bool
    log_level::Logging.LogLevel
    log_to_file::Bool
    change_db::Bool
    change_data::Bool
    connections::Union{Nothing, SQLite.DB, LibPQ.Connection, PormGPostgres, PormGSQLite}
    time_zone::String
    django_prefix::Union{Nothing, String}
    use_connection_pool::Bool  # New field to enable/disable pooling

    Settings(;
        app_env             = ENV["PORMG_ENV"],           
        db_def_folder       = DB_PATH,
        model_file          = MODEL_FILE,
        db_config_settings  = Dict{String,Any}(),
        log_queries         = true,
        log_level           = Logging.Debug,
        log_to_file         = true,
        change_db           = false,
        change_data         = false,
        connections         = nothing,
        time_zone           = DATETIME_FORMAT,
        django_prefix       = nothing,
        use_connection_pool = false  # Default to false for backward compatibility
    ) =
    new(
        app_env,
        db_def_folder,
        model_file,
        db_config_settings,
        log_queries,
        log_level,
        log_to_file,
        change_db,
        change_data,
        connections,
        time_zone,
        django_prefix,
        use_connection_pool
    )
end

# Updated fetch Function with Pool Support
// ...existing code...

function fetch(settings::SQLConn, sql::String)
    if settings.use_connection_pool && settings.connections isa Union{PostgresConnectionPool, SQLiteConnectionPool}
        conn = acquire_connection(settings.connections)
        try
            result = fetch(conn, sql)
            release_connection(settings.connections, conn)
            return result
        catch e
            release_connection(settings.connections, conn)
            @error "Database error with pooled connection: $(e)"
            rethrow(e)
        end
    else
        # Existing single connection logic
        try
            return fetch(settings.connections, sql)
        catch e    
            if e == LibPQ.Errors.UnknownError("") || occursin("server closed the connection", string(e)) || occursin("connection not open", string(e))
                @warn "Lost connection to database. Attempting to reconnect..."
                reconnect_to_db(settings)
                try
                    return fetch(settings.connections, sql)
                catch e
                    @error "Failed to reconnect to the database: $(e)"
                    throw(e)
                end
            else
                rethrow(e)
            end
        end
    end
end

# Pool Cleanup Function
// ...existing code...

function close_pool!(pool::Union{PostgresConnectionPool, SQLiteConnectionPool})
    Base.lock(pool.lock) do
        for i in 1:length(pool.connections)
            if pool.connections[i] !== nothing
                try
                    if pool.adapter == "PostgreSQL" && pool.connections[i] isa LibPQ.Connection
                        LibPQ.close(pool.connections[i])
                    elseif pool.adapter == "SQLite" && pool.connections[i] isa SQLite.DB
                        SQLite.close(pool.connections[i])
                    end
                catch e
                    @warn "Error closing connection $i: $e"
                end
                pool.connections[i] = nothing
                pool.available[i] = false
            end
        end
    end
end

# Add this to your module cleanup if needed
function __cleanup__()
    for (path, settings) in config
        if settings.connections isa Union{PostgresConnectionPool, SQLiteConnectionPool}
            close_pool!(settings.connections)
        end
    end
end