
"""
    setup(path::String = DB_PATH)

Interactively setup the `connection.yml` file for PormG.
This will prompt for database adapter, name, and connection details.
"""
function setup(path::String = DB_PATH)
    println("\e[34m--- PormG Database Setup ---\e[0m")
    println("Setting up configuration in folder: \e[32m$path\e[0m")
    
    # 1. Adapter
    print("Choose database adapter (1: PostgreSQL, 2: SQLite) [Default 1]: ")
    adapter_choice = readline() |> strip
    adapter = "PostgreSQL"
    if adapter_choice == "2"
        adapter = "SQLite"
    end

    database = ""
    host = ""
    username = ""
    password = ""
    port = 5432

    if adapter == "SQLite"
        print("Database filename [Default: database.sqlite]: ")
        database = readline() |> strip
        if isempty(database); database = "database.sqlite"; end
    else
        print("Database name: ")
        database = readline() |> strip
        print("Host [Default: localhost]: ")
        host = readline() |> strip
        if isempty(host); host = "localhost"; end
        print("Username: ")
        username = readline() |> strip
        print("Password: ")
        password = readline() |> strip
        print("Port [Default: 5432]: ")
        p_input = readline() |> strip
        if !isempty(p_input)
            port = p_input
        end
    end

    print("Time zone [Default: UTC]: ")
    time_zone = readline() |> strip
    if isempty(time_zone); time_zone = "UTC"; end

    Generator.create_db_folder_and_yml(
        path = path,
        adapter = adapter,
        database = database,
        host = host,
        username = username,
        password = password,
        port = port,
        time_zone = time_zone
    )

    println("\e[32mConfiguration saved successfully to $(joinpath(path, "connection.yml"))\e[0m")
    println("You can now load it using: \e[36mPormG.Configuration.load(\"$path\")\e[0m")
end
