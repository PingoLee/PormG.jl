
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

# ─────────────────────────────────────────────────────────────────────────────
# upgrade_guide — version-scoped emitter over UPGRADING.md (issue #216)
# ─────────────────────────────────────────────────────────────────────────────

# Unstamped ("pre-0.2 history") UPGRADING.md entries sort just below 0.2.0: under any
# 0.2.x release, but above every 0.1.x. So a consumer coming from before the versioning
# policy still sees them, while one already on ≥ 0.2.0 does not.
const _UNSTAMPED_VERSION = v"0.2.0-"

const _UpgradeEntry = @NamedTuple{version::VersionNumber, title::String, body::String}

_asver(v::VersionNumber) = v
_asver(v::AbstractString) = VersionNumber(v)

"""
    _read_upgrading_entries() -> Vector{_UpgradeEntry}

Parse the `UPGRADING.md` bundled with the resolved PormG install into change entries,
newest-first. `body` is the entry's markdown with its PormG-internal `### Per-app rollout`
table trimmed off. Unstamped pre-0.2 entries get `version = _UNSTAMPED_VERSION`.
"""
function _read_upgrading_entries()
    path = joinpath(Base.pkgdir(@__MODULE__), "UPGRADING.md")
    isfile(path) || throw(ArgumentError(
        "UPGRADING.md not found next to the installed PormG (looked in $(dirname(path)))."))
    text = read(path, String)

    # Drop the "## Template for new entries" section: its body is an HTML comment holding a
    # fake `## …` heading and a `- **Version**:` placeholder that would parse as a bogus entry.
    tmpl = findfirst("## Template for new entries", text)
    tmpl === nothing || (text = text[1:prevind(text, first(tmpl))])

    entries = _UpgradeEntry[]
    for block in split(text, r"(?m)^---[ \t]*$")
        # A real change entry has a `## ` heading AND a `- **Recorded**:` bullet — this rejects
        # the header/recipe prose and any stray section, regardless of `---` placement.
        title_m = match(r"(?m)^##[ \t]+(.+)$", block)
        (title_m === nothing || !occursin(r"(?m)^-[ \t]+\*\*Recorded\*\*:", block)) && continue

        ver_m = match(r"(?m)^-[ \t]+\*\*Version\*\*:[ \t]*(\S+)", block)
        version = ver_m === nothing ? _UNSTAMPED_VERSION : VersionNumber(ver_m[1])

        # Trim the internal per-app rollout table (which of PormG's own apps adopted it) —
        # noise for a consuming app, which only needs the porting work.
        body = block
        roll = findfirst("### Per-app rollout", body)
        roll === nothing || (body = body[1:prevind(body, first(roll))])

        push!(entries, (version = version,
                        title = String(strip(title_m[1])),
                        body = String(strip(body))))
    end
    return entries
end

"""
    upgrade_guide([io::IO = stdout]; from, to = pkgversion(PormG), structured = false)

Print the `UPGRADING.md` entries a consuming app must work through to move from PormG
version `from` up to `to` (default: the installed version). Reads the `UPGRADING.md`
shipped with the *resolved* PormG install, so the scope is accurate against the version
your app actually depends on — not a latest-on-GitHub copy that may not match.

Entries print newest-first; each keeps its "How to find the calls to migrate" grep and its
`before → after`, with the PormG-internal per-app rollout table trimmed off.

`from` is required — pass the PormG version your app currently depends on. Both `from` and
`to` accept a `VersionNumber` or a version string (`v"0.2"` or `"0.2"`).

Pass `structured = true` to get the entries back as data instead of printing — a `Vector`
of `(; version, title, body)` named tuples, newest-first — for programmatic consumers.

# Examples
```julia
julia> using PormG

julia> PormG.upgrade_guide(from = v"0.1")            # everything up to the installed version

julia> PormG.upgrade_guide(from = "0.2", to = "0.3")

julia> entries = PormG.upgrade_guide(from = v"0.1", structured = true);
```
"""
function upgrade_guide(io::IO = stdout; from = nothing, to = pkgversion(@__MODULE__),
                       structured::Bool = false)
    from === nothing && throw(ArgumentError(
        "upgrade_guide requires `from` — the PormG version your app currently depends on, " *
        "e.g. `upgrade_guide(from = v\"0.2\")`."))
    from_v = _asver(from)
    to_v   = _asver(to)

    entries = filter(e -> from_v < e.version <= to_v, _read_upgrading_entries())

    structured && return entries

    if isempty(entries)
        println(io, "# PormG: nothing to port between $from_v and $to_v.")
        return nothing
    end

    println(io, "# Porting a PormG consumer from $from_v → $to_v")
    println(io, "# Work newest-first; for each entry run its \"How to find the calls to migrate\"")
    println(io, "# grep, apply before → after, then run your app's tests.")
    for e in entries
        println(io)
        println(io, e.body)
    end
    return nothing
end
