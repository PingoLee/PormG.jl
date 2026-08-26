
# User-facing lifecycle helpers: `setup`, `install_ai_skills`, `upgrade_guide`. Included last in
# PormG.jl — this file consumes the layers above and nothing depends on it.
#
# `_emsg` used to live here, which forced this file to be included before Models/QueryBuilder even
# though nothing else in it is infrastructure. It now lives in `Kernel`, next to the `PormGError`
# root — the error types whose constructors call it need it available from layer 1.

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
    println("PormG can install 'AI skills' (.github/skills) to help coding assistants")
    println("(GitHub Copilot, Claude, Cursor, and other agents) understand the PormG API in your project.")
    print("Do you want to install PormG AI skills? (Y/n) [Default Y]: ")
    
    choice = readline() |> strip |> lowercase
    if isempty(choice) || choice == "y"
        install_ai_skills()
    end
end

"""
    install_ai_skills(target_dir::String = pwd())

Copy PormG's AI skill blueprint into the target project's `.github/skills/pormg-usage/`
directory. This helps AI assistants (GitHub Copilot, Claude, Cursor, and other agents)
provide accurate PormG code suggestions.

The blueprint ships with the PormG package under `.github/skills/pormg-usage/` and is a
multi-file bundle — `SKILL.md` plus the supporting `reference.md`/`writing.md` it links to.
The **whole directory** is copied so none of `SKILL.md`'s relative links dangle after install.
"""
function install_ai_skills(target_dir::String = pwd())
    # Resolve the package root the same way `upgrade_guide` does (works for a
    # registry install, not just a dev checkout). The blueprint moved from
    # `.cursor/skills/` to `.github/skills/` — see commit ee2ad67.
    skill_src_dir    = joinpath(Base.pkgdir(@__MODULE__), ".github", "skills", "pormg-usage")
    target_skill_dir = joinpath(target_dir, ".github", "skills", "pormg-usage")

    try
        if !isdir(skill_src_dir)
            @warn "Could not find PormG skill blueprint" expected_path=skill_src_dir
            return
        end

        # Copy every file in the bundle so sibling links (SKILL.md → reference.md /
        # writing.md) resolve in the consumer project. Flat bundle only — per-file
        # (not a whole-dir replace) so any files the consumer added alongside it are
        # left intact; add a recursive walk here if the bundle ever grows subdirs.
        files = filter(f -> isfile(joinpath(skill_src_dir, f)), readdir(skill_src_dir))
        if isempty(files)
            @warn "PormG skill blueprint has no files to install" source=skill_src_dir
            return
        end

        mkpath(target_skill_dir)
        for f in files
            cp(joinpath(skill_src_dir, f), joinpath(target_skill_dir, f); force=true)
        end

        println(_emsg("\e[32mPormG AI skill installed ($(length(files)) files) → $target_skill_dir\e[0m"))
        println("Your coding assistant now understands PormG's query API, models, migrations, and write path.")
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

# Entries under the `## Unreleased` heading carry `- **Version**: Unreleased` — changes merged but
# not yet cut into a release train (the release-train model). They sort ABOVE every real version so
# a consumer dev'ing PormG at HEAD sees the uncut work they are actually running; the maintainer's
# `/pormg-cut-release` command later rewrites `Unreleased` to the assigned release number.
const _UNRELEASED_VERSION = v"1000000.0.0"

# `_UNRELEASED_VERSION` is an internal sort key, never a user-facing version. Render it as the
# literal `UPGRADING.md` token so output reads "0.3.0 → Unreleased" and not "0.3.0 → 1000000.0.0".
_version_label(v::VersionNumber) = v == _UNRELEASED_VERSION ? "Unreleased" : string(v)

const _UpgradeEntry = @NamedTuple{version::VersionNumber, title::String, body::String}

# A release marker heading — `## 0.3.0 — 2026-07-24` or `## Unreleased — next \`0.4.0\``, both
# written by `/pormg-cut-release`. It groups the entries of one release; it is NOT an entry title.
#
# The em-dash separator is REQUIRED, not decoration: without it this also matches a real entry whose
# title merely starts with a version (`## 0.5.0 config format is now strict`), and that entry's
# whole segment is then skipped as a marker — it disappears from the guide SILENTLY, no error.
# Both forms `/pormg-cut-release` writes carry the separator, so requiring it costs nothing.
const _RELEASE_MARKER = r"^(?:Unreleased|\d+\.\d+\.\d+)\s+—"

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
    return _parse_upgrading(read(path, String))
end

"""
    _parse_upgrading(text::AbstractString) -> Vector{_UpgradeEntry}

Parse raw `UPGRADING.md` text into change entries, newest-first (see `_read_upgrading_entries`).
Split out so the parser can be exercised on hand-fed text — the CRLF-robustness regression in
particular — without touching the on-disk file.

An entry is delimited by its own `## ` heading and runs to the next one — the marker
`UPGRADING.md`'s *"Writing an entry"* rules actually mandate. The `---` rules between entries are
decorative and the parser does not depend on them.

#438: it used to split on `^---\$` and gate each block on a `- **Recorded**:` bullet, neither of
which the writing rules ever asked for. Nine headings written to spec were lost — three
(`#424`, `#394`, `#396`) never reached any guide at all, and six (`#379`, `#388`, `#380`, `#347`,
`#346`, and `#300` since `0.4.0` shipped) were merged into a neighbour's body and rendered under
its title. `upgrade_guide(from = v"0.4.0")` returned 3 entries of 11.

Line endings are normalized to `\\n` up front: a Windows checkout can store `UPGRADING.md`
with `\\r\\n` (only `*.jl`/`*.sh` are pinned to `eol=lf`), and a `(?m)…\$` anchor never sees past
a trailing `\\r` — so headings and bullets would match inconsistently and the parse would be
platform-dependent.
"""
function _parse_upgrading(text::AbstractString)
    text = replace(text, "\r\n" => "\n", "\r" => "\n")

    # Drop the "## Template for new entries" section: its body is an HTML comment holding a
    # fake `## …` heading and a `- **Version**:` placeholder that would parse as a bogus entry.
    tmpl = findfirst("## Template for new entries", text)
    tmpl === nothing || (text = text[1:prevind(text, first(tmpl))])

    entries = _UpgradeEntry[]

    # Segment on the entry heading itself. Each segment runs from its `## ` to just before the
    # next one, so a body ALWAYS starts at its own heading: a release marker written directly
    # above the first entry of a release (`/pormg-cut-release` emits it with no `---` between) is
    # its own skipped segment rather than something to trim off, and every entry renders
    # identically no matter where it sits in a release.
    #
    # The flip side is that a stray `## ` inside an entry body would split that entry. There is
    # none today, and `test_upgrade_guide.jl` fails if one appears: it asserts every non-marker
    # heading below the first release marker comes back as a parsed entry.
    heads = collect(eachmatch(r"(?m)^##[ \t]+(.+?)[ \t]*$", text))
    for (i, h) in enumerate(heads)
        occursin(_RELEASE_MARKER, h[1]) && continue

        stop  = i < length(heads) ? prevind(text, heads[i + 1].offset) : lastindex(text)
        block = text[h.offset:stop]

        # A real change entry carries `- **Version**:` (the policy from 0.2.0 on) or
        # `- **Recorded**:` (pre-0.2 history, written before that policy existed). The header
        # prose and the "Writing an entry" recipe carry neither — their only `- **Version**:`
        # mention is indented inside backticks, which `^-` does not match.
        ver_m = match(r"(?m)^-[ \t]+\*\*Version\*\*:[ \t]*(\S+)", block)
        (ver_m === nothing && !occursin(r"(?m)^-[ \t]+\*\*Recorded\*\*:", block)) && continue

        version = ver_m === nothing        ? _UNSTAMPED_VERSION  :
                  ver_m[1] == "Unreleased" ? _UNRELEASED_VERSION :
                                             VersionNumber(ver_m[1])

        # Trim the internal per-app rollout table (which of PormG's own apps adopted it) —
        # noise for a consuming app, which only needs the porting work.
        body = block
        roll = findfirst("### Per-app rollout", body)
        roll === nothing || (body = body[1:prevind(body, first(roll))])

        push!(entries, (version = version,
                        title = String(h[1]),
                        body = _trim_trailing_structure(body)))
    end
    return entries
end

# A trailing `---` rule, and a trailing HTML comment (the `<!-- pre-0.2 history (unstamped) -->`
# divider).
#
# THE INVARIANT: peel only WHOLE LINES of structure, never reach into a line that carries prose.
# Every piece of both patterns exists to hold it, and it is not decorative — this function ate an
# entry's content twice in review before the invariant was stated:
#
#   `\z`               anchors to the end. Structure is peeled off the tail; a rule or a comment
#                      INSIDE an entry's prose is content and must survive, so neither pattern may
#                      ever be applied globally.
#   `(?:\A|\n)[ \t]*`  anchors the START to a line. Without it, `match` takes the leftmost viable
#                      position, so a stray `<!--` anywhere in the body — a code fence documenting
#                      HTML, a mid-line mention — paired with any `-->` at the tail swallowed
#                      everything between them. Measured on a 400-line body: 11,645 chars → 33.
#                      An unclosed `<!--` inside a fence was worse than lost content: it left the
#                      fence open, and `upgrade_guide` prints entries into one stream, so every
#                      LATER entry disappeared into it too.
#   `(?!-->|<!--)`     tempers the scan so it crosses neither a closed comment nor another opener.
#                      The `-->` half keeps an interior closed comment intact. The `<!--` half is
#                      what saves the fence case, where the stray opener IS at a line start and
#                      the line anchor alone cannot help.
#   `[\s\S]`           spans newlines, so a multi-line comment is one unit. A single-line-only tail
#                      check leaked a multi-line divider exactly the way the first cut of this
#                      leaked the single-line one.
#
# `[ ]{0,3}` on the left, NOT `[ \t]*`: CommonMark allows up to three spaces of indent on a
# thematic break, and four spaces or a tab makes the line an indented CODE BLOCK instead. An
# unbounded class peels the last line of a code sample the consumer is meant to copy.
#
# Known residual, deliberately not chased further: a line-start `<!--` that is never closed, in a
# body that ends with a prose `-->`, is still peeled along with everything between them. It needs
# all four conditions at once, `UPGRADING.md` contains no such shape, and the text really is an
# HTML comment unless a code fence makes it literal — which no regex can know. Tightening past
# this point costs more than it buys.
const _TRAILING_RULE    = r"(?:\A|\n)[ ]{0,3}---[ \t]*\z"
const _TRAILING_COMMENT = r"(?:\A|\n)[ ]{0,3}<!--(?:(?!-->|<!--)[\s\S])*-->[ \t]*\z"

# Drop the file structure that visually precedes the NEXT heading — blank lines, `---` rules and
# HTML comments. None of it is the entry's content; a segment simply runs up to the next `##`, so
# all of it lands in this one's tail.
#
# All three, not just rules: the divider sits BELOW its rule, so a rule-only trim leaves `---`
# *and* the comment in `#197`'s rendered body. Caught in review — and the assertion written to
# catch that leak (`!endswith(body, "---")`) passed anyway, because the leak ends in `-->`.
#
# Peeling in a loop rather than one pass: rule and comment alternate, and either may be outermost.
# It terminates because both patterns require a non-empty match anchored at `\z`, so `s` loses at
# least three bytes per iteration.
function _trim_trailing_structure(body::AbstractString)
    s = rstrip(body)
    while true
        m = match(_TRAILING_COMMENT, s)
        if m === nothing
            m = match(_TRAILING_RULE, s)
            m === nothing && break
        end
        s = rstrip(s[1:prevind(s, m.offset)])
    end
    return String(strip(s))
end

"""
    upgrade_guide([io::IO = stdout]; from, to = <current code>, structured = false)

Print the `UPGRADING.md` entries a consuming app must work through to move from PormG
version `from` up to `to`. The default `to` covers the **current code** — every released
entry **plus** the uncut `## Unreleased` changes the install is running (release-train model),
so a consumer dev'ing PormG at HEAD sees work that has not been stamped with a release number
yet. Pass `to = pkgversion(PormG)` to scope to the installed *release* only. Reads the
`UPGRADING.md` shipped with the *resolved* PormG install, so the scope is accurate against the
version your app actually depends on — not a latest-on-GitHub copy that may not match.

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
function upgrade_guide(io::IO = stdout; from = nothing, to = _UNRELEASED_VERSION,
                       structured::Bool = false)
    from === nothing && throw(ArgumentError(
        "upgrade_guide requires `from` — the PormG version your app currently depends on, " *
        "e.g. `upgrade_guide(from = v\"0.2\")`."))
    from_v = _asver(from)
    to_v   = _asver(to)

    entries = filter(e -> from_v < e.version <= to_v, _read_upgrading_entries())

    structured && return entries

    if isempty(entries)
        println(io, "# PormG: nothing to port between $(_version_label(from_v)) and $(_version_label(to_v)).")
        return nothing
    end

    println(io, "# Porting a PormG consumer from $(_version_label(from_v)) → $(_version_label(to_v))")
    println(io, "# Work newest-first; for each entry run its \"How to find the calls to migrate\"")
    println(io, "# grep, apply before → after, then run your app's tests.")
    for e in entries
        println(io)
        println(io, e.body)
    end
    return nothing
end
