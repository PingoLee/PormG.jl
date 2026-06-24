
"""
    _emsg(msg; color = (Base.have_color === true))

TTY-aware error-message colorizer. Many PormG error strings embed ANSI SGR codes
(`\\e[31m…\\e[0m`) to highlight the offending token in the REPL. Those codes are
helpful on a color terminal but leak as raw `\\e[..m` noise into non-TTY sinks
(CI output, file logs, `sprint(showerror, e)`, structured logging).

`_emsg` keeps the codes when `color` is true and strips every `\\e[..m` sequence
otherwise. The default tracks `Base.have_color` — the same flag Julia consults to
colorize its own error displays, so it honors the `--color` flag and `NO_COLOR`.
The `color` keyword exists so tests can exercise both branches deterministically.

This is the single shared definition; `QueryBuilder` (`_argerr`) and `Models` both
import it rather than re-embedding the strip logic.
"""
_emsg(msg::AbstractString; color::Bool = (Base.have_color === true)) =
  color ? String(msg) : replace(msg, r"\e\[[0-9;]*m" => "")

"""
    _emsg(io, msg)

IO-aware variant of [`_emsg`](@ref) for use inside `show` / `print(io, …)` methods:
it keeps ANSI only when the destination stream advertises color via its `:color`
IOContext property. This is the correct signal for rendered output, because a
non-color buffer (`sprint`, `repr`, a captured string, a file) must stay ANSI-free
even when the process itself is attached to a color terminal.
"""
_emsg(io::IO, msg::AbstractString) = _emsg(msg; color = get(io, :color, false))

"""
    setup(path::String = DB_PATH)

Interactively setup the `connection.yml` file for PormG.
This will prompt for database adapter, name, and connection details.
"""
function setup(path::String = DB_PATH)
    println(_emsg("\e[34m--- PormG Database Setup ---\e[0m"))
    println(_emsg("Setting up configuration in folder: \e[32m$path\e[0m"))

    read_input() = String(strip(readline()))
    
    # 1. Adapter
    print("Choose database adapter (1: PostgreSQL, 2: SQLite) [Default 1]: ")
    adapter_choice = read_input()
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
        database = read_input()
        if isempty(database); database = "database.sqlite"; end
    else
        print("Database name: ")
        database = read_input()
        print("Host [Default: localhost]: ")
        host = read_input()
        if isempty(host); host = "localhost"; end
        print("Username: ")
        username = read_input()
        print("Password: ")
        password = read_input()
        print("Port [Default: 5432]: ")
        p_input = read_input()
        if !isempty(p_input)
            port = p_input
        end
    end

    print("Time zone [Default: UTC]: ")
    time_zone = read_input()
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

    print("Models file name [Default: models.jl]: ")
    models_filename = readline() |> strip
    if isempty(models_filename); models_filename = "models.jl"; end

    Generator.create_models_jl(path, models_filename)

    println(_emsg("\e[32mConfiguration saved successfully to $(joinpath(path, "connection.yml"))\e[0m"))
    println(_emsg("You can now load it using: \e[36mPormG.Configuration.load(\"$path\")\e[0m"))

    println()
    println(_emsg("\e[34m--- AI Assistant Setup ---\e[0m"))
    println("PormG can install 'AI skills' (.cursor/skills) to help coding assistants")
    println("(Cursor and other agents) understand the PormG API in your project.")
    print("Do you want to install PormG AI skills? (Y/n) [Default Y]: ")
    
    choice = readline() |> strip |> lowercase
    if isempty(choice) || choice == "y"
        install_ai_skills()
    end
end

"""
    install_ai_skills(target_dir::String = pwd())

Copy PormG AI skill blueprints to the target project's `.cursor/skills` directory.
This helps AI assistants (Cursor and other agents) provide better PormG code suggestions.

The skill blueprint lives in the PormG package itself under `.cursor/skills/pormg-usage/`.
"""
function install_ai_skills(target_dir::String = pwd())
    # @__DIR__ is src/ — navigate up to package root then into .cursor/skills
    pkg_root = dirname(@__DIR__)
    skill_src = joinpath(pkg_root, ".cursor", "skills", "pormg-usage", "SKILL.md")

    target_skill_dir  = joinpath(target_dir, ".cursor", "skills", "pormg-usage")
    target_skill_file = joinpath(target_skill_dir, "SKILL.md")

    try
        mkpath(target_skill_dir)

        if isfile(skill_src)
            cp(skill_src, target_skill_file; force=true)
            println(_emsg("\e[32mPormG AI skill installed → $target_skill_file\e[0m"))
            println("Your coding assistant now understands PormG's query API, models, and migrations.")
        else
            @warn "Could not find PormG skill blueprint" expected_path=skill_src
        end
    catch e
        @error "Failed to install AI skills" exception=e
    end
end
