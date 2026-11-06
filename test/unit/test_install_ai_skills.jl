# ==============================================================================
# UNIT TESTS: install_ai_skills — copies the pormg-usage skill bundle (issue #206)
#
# `PormG.install_ai_skills(dir)` copies the multi-file skill blueprint that ships under
# `.github/skills/pormg-usage/` into `<dir>/.github/skills/pormg-usage/`. Before #206 it
# read from a deleted `.cursor/` path (so it copied nothing) and, even path-fixed, copied
# only `SKILL.md` — leaving `SKILL.md`'s relative links to reference.md/writing.md dangling
# in the consumer project.
#
# These tests pin: (1) the full bundle is installed into `.github/skills` (not the obsolete
# `.cursor`), and (2) every relative markdown link inside the installed files resolves to a
# sibling file — the exact #206 defect, and a guard against any future dangling link.
#
# Runs WITHOUT a live database — it only copies bundled markdown files.
# ==============================================================================

using Test
using PormG

@testset "install_ai_skills copies the full skill bundle with resolving links" begin
    src_dir = joinpath(pkgdir(PormG), ".github", "skills", "pormg-usage")
    @test isdir(src_dir)                                   # sanity: blueprint ships with the package
    src_files = filter(f -> isfile(joinpath(src_dir, f)), readdir(src_dir))
    @test !isempty(src_files)

    mktempdir() do dir
        PormG.install_ai_skills(dir)

        installed_dir = joinpath(dir, ".github", "skills", "pormg-usage")
        @test isdir(installed_dir)

        # (1) every source file landed
        for f in src_files
            @test isfile(joinpath(installed_dir, f))
        end

        # (2) every relative markdown link inside the installed files resolves.
        # Inline `](target)` links only — reference-style/titled links aren't parsed
        # (the bundle uses none). `links_checked` guards against the loop passing
        # vacuously if the files ever lose all inline links.
        link_re = r"\]\(([^)]+)\)"
        links_checked = 0
        for f in readdir(installed_dir)
            endswith(f, ".md") || continue
            text = read(joinpath(installed_dir, f), String)
            for m in eachmatch(link_re, text)
                target = m.captures[1]
                (startswith(target, "http://") || startswith(target, "https://") ||
                 startswith(target, "#")) && continue        # external URL / same-page anchor
                path = first(split(target, '#'))             # strip any #anchor suffix
                isempty(path) && continue
                links_checked += 1
                @test isfile(joinpath(installed_dir, path))
            end
        end
        @test links_checked > 0                              # the resolution loop actually ran
    end
end

@testset "install_ai_skills targets .github/skills, not the obsolete .cursor" begin
    mktempdir() do dir
        PormG.install_ai_skills(dir)
        @test isdir(joinpath(dir, ".github", "skills", "pormg-usage"))
        @test !isdir(joinpath(dir, ".cursor"))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# install_ai_skills: reports what it did instead of what the assistant "knows" (#253)
# The old closing line claimed "your coding assistant now understands PormG" — a claim about the
# assistant, not the copy. The report now names every file written, and the return value carries
# the same facts so a caller (or this test) can act on them without parsing text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "install_ai_skills reports the files it wrote, by name (#253)" begin
    src_dir   = joinpath(pkgdir(PormG), ".github", "skills", "pormg-usage")
    src_files = filter(f -> isfile(joinpath(src_dir, f)), readdir(src_dir))

    mktempdir() do dir
        buf = IOBuffer()
        r = PormG.install_ai_skills(dir; io = buf)
        out = String(take!(buf))

        # Return value: the exact shipped set, the install path, nothing stale in a fresh dir.
        @test r.written == src_files
        @test r.installed_dir == joinpath(dir, ".github", "skills", "pormg-usage")
        @test isempty(r.stale)

        # Printed report: every written file named, and the overclaim is gone.
        for f in src_files
            @test occursin(f, out)
        end
        @test !occursin("now understands", out)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# install_ai_skills: files it does not ship are flagged, never deleted (#253)
# A topic file renamed between PormG versions stays behind in the consumer's directory, where an
# assistant browsing it would still read the outdated content. The installer cannot tell that file
# from one the consumer added, so it must report both and remove neither.
# ─────────────────────────────────────────────────────────────────────────────
@testset "install_ai_skills flags stale files and leaves them in place (#253)" begin
    mktempdir() do dir
        skill_dir = joinpath(dir, ".github", "skills", "pormg-usage")
        mkpath(skill_dir)
        # A file a pre-restructure PormG shipped, and one the consumer wrote themselves.
        write(joinpath(skill_dir, "retired-topic.md"), "old content")
        write(joinpath(skill_dir, "team-notes.md"), "ours")
        # A file this version DOES ship (an older copy of it): present before the install, but not
        # stale — it is about to be overwritten. Without it, a "stale = everything already there"
        # mutant passes this testset.
        write(joinpath(skill_dir, "SKILL.md"), "an older router")
        # Filesystem litter is nobody's topic file.
        write(joinpath(skill_dir, ".DS_Store"), "")

        buf = IOBuffer()
        r = PormG.install_ai_skills(dir; io = buf)
        out = String(take!(buf))

        @test r.stale == ["retired-topic.md", "team-notes.md"]   # sorted; SKILL.md and .DS_Store absent
        @test read(joinpath(skill_dir, "SKILL.md"), String) != "an older router"   # overwritten
        @test read(joinpath(skill_dir, "retired-topic.md"), String) == "old content"  # untouched
        @test read(joinpath(skill_dir, "team-notes.md"), String) == "ours"
        @test occursin("retired-topic.md", out) && occursin("left in place", out)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# install_ai_skills: detects whether any instruction file points at the bundle (#253)
# Copying files wires nothing up: an assistant only reads the skill when AGENTS.md / CLAUDE.md /
# the instructions directory send it there. Unreferenced → print the pointer line to add;
# referenced → say where. Either way the instruction files are read, never written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "install_ai_skills detects an existing pointer, suggests one otherwise (#253)" begin
    # (a) no instruction file mentions the bundle → the suggested line is printed verbatim.
    mktempdir() do dir
        write(joinpath(dir, "AGENTS.md"), "# Agents\n\nNothing about the ORM here.\n")
        buf = IOBuffer()
        r = PormG.install_ai_skills(dir; io = buf)
        out = String(take!(buf))
        @test isempty(r.referenced_in)
        @test occursin(PormG._SKILL_POINTER_LINE, out)
    end

    # (b) a pointer in AGENTS.md and one under .github/instructions/ → both found, no suggestion.
    mktempdir() do dir
        write(joinpath(dir, "AGENTS.md"), "- read .github/skills/pormg-usage/SKILL.md\n")
        mkpath(joinpath(dir, ".github", "instructions"))
        write(joinpath(dir, ".github", "instructions", "general.instructions.md"),
              "| ORM | `.github/skills/pormg-usage/SKILL.md` |\n")
        buf = IOBuffer()
        r = PormG.install_ai_skills(dir; io = buf)
        out = String(take!(buf))
        @test r.referenced_in == ["AGENTS.md", joinpath(".github", "instructions", "general.instructions.md")]
        @test !occursin(PormG._SKILL_POINTER_LINE, out)
        @test occursin("referenced from", out)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# install_ai_skills: an unreadable instruction file cannot fail a finished install (#253)
# The pointer scan runs after the copy. If a read inside it threw, the installer's catch-all would
# log "Failed to install AI skills" and return `nothing` for a bundle that was in fact written. An
# unreadable file is skipped with a warning instead. `chmod 000` does not make a file unreadable
# everywhere (Windows, or a root user), so the assertion only runs where it actually is.
# ─────────────────────────────────────────────────────────────────────────────
@testset "install_ai_skills survives an unreadable instruction file (#253)" begin
    mktempdir() do dir
        agents = joinpath(dir, "AGENTS.md")
        write(agents, "- read .github/skills/pormg-usage/SKILL.md\n")
        chmod(agents, 0o000)
        unreadable = try read(agents); false catch; true end
        try
            if unreadable
                r = @test_logs (:warn, r"Could not read agent instructions") match_mode=:any begin
                    PormG.install_ai_skills(dir; io = devnull)
                end
                @test r !== nothing                              # the install still reports success
                @test isempty(r.referenced_in)                   # the unreadable file is not claimed
                @test isfile(joinpath(r.installed_dir, "SKILL.md"))
            else
                @test_skip "chmod 000 left AGENTS.md readable on this platform/user"
            end
        finally
            chmod(agents, 0o644)                                 # let mktempdir clean up
        end
    end

    # The directory half: an unlistable `.github/instructions/` is skipped the same way, by the
    # separate `readdir` guard in `_skill_references`.
    mktempdir() do dir
        instr = joinpath(dir, ".github", "instructions")
        mkpath(instr)
        write(joinpath(instr, "general.instructions.md"), "pormg-usage\n")
        chmod(instr, 0o000)
        unlistable = try readdir(instr); false catch; true end
        try
            if unlistable
                r = @test_logs (:warn, r"Could not list agent instructions") match_mode=:any begin
                    PormG.install_ai_skills(dir; io = devnull)
                end
                @test r !== nothing
                @test isempty(r.referenced_in)
            else
                @test_skip "chmod 000 left .github/instructions listable on this platform/user"
            end
        finally
            chmod(instr, 0o755)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# install_ai_skills: writes nothing outside its own directory and its Claude Code stub (#253, #1132)
# The installer must stay read-only everywhere but `.github/skills/pormg-usage/` and, since #1132,
# the one stub file `.claude/skills/pormg-usage/SKILL.md`: consuming apps keep hand-curated skills
# tables in AGENTS.md, and an auto-appended pointer would fight them. Snapshot every other file's
# bytes before and after, and require them identical.
# ─────────────────────────────────────────────────────────────────────────────
@testset "install_ai_skills is read-only outside its skill directory and stub (#253, #1132)" begin
    mktempdir() do dir
        write(joinpath(dir, "AGENTS.md"), "# Agents\n")
        write(joinpath(dir, "CLAUDE.md"), "@AGENTS.md\n")
        mkpath(joinpath(dir, ".github", "instructions"))
        write(joinpath(dir, ".github", "instructions", "x.md"), "rules\n")
        # A Claude Code skill of the project's own, beside where the stub goes: not touched.
        mkpath(joinpath(dir, ".claude", "skills", "team-skill"))
        write(joinpath(dir, ".claude", "skills", "team-skill", "SKILL.md"), "ours\n")

        skill_dir = joinpath(dir, ".github", "skills", "pormg-usage")
        stub_path = joinpath(dir, ".claude", "skills", "pormg-usage", "SKILL.md")
        snapshot() = Dict(joinpath(root, f) => read(joinpath(root, f))
                          for (root, _, fs) in walkdir(dir) for f in fs
                          if !startswith(joinpath(root, f), skill_dir) && joinpath(root, f) != stub_path)
        before = snapshot()
        PormG.install_ai_skills(dir; io = devnull)
        @test snapshot() == before
        @test length(before) == 4                    # the snapshot actually covered the files
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# install_ai_skills: writes the Claude Code discovery stub (#1132)
# Claude Code registers a skill only from `.claude/skills/<name>/SKILL.md`. With the bundle alone,
# `/pormg-usage` was an unknown skill in a consuming project and the session went on without the
# ruleset. Expected: the stub exists, its front-matter is the bundle's byte-for-byte (discovery reads
# `name`/`description` from it), its body names the bundle's SKILL.md by a link that resolves, it
# stays under `test_skill_stubs.jl`'s ceiling, and the return value and the report both name it.
# ─────────────────────────────────────────────────────────────────────────────
# The front-matter block as it is on disk, delimiters included; `nothing` when there is none.
function _ai1132_frontmatter(path::AbstractString)
    m = match(r"\A---\r?\n.*?\r?\n---\r?\n"s, read(path, String))
    return m === nothing ? nothing : m.match
end

@testset "install_ai_skills writes a Claude Code discovery stub (#1132)" begin
    src_skill = joinpath(pkgdir(PormG), ".github", "skills", "pormg-usage", "SKILL.md")
    mktempdir() do dir
        buf = IOBuffer()
        r = PormG.install_ai_skills(dir; io = buf)
        out = String(take!(buf))
        stub = joinpath(dir, ".claude", "skills", "pormg-usage", "SKILL.md")

        @test r.stub == stub
        @test isfile(stub)
        @test occursin(stub, out)
        fm = _ai1132_frontmatter(stub)
        @test fm !== nothing && fm == _ai1132_frontmatter(src_skill)
        @test occursin("\nname: pormg-usage\n", fm)
        body = read(stub, String)
        # The pointer, by a relative link that resolves from the stub's directory to the bundle.
        m = match(r"\]\(([^)]+)\)", body)
        @test m !== nothing && endswith(m.captures[1], ".github/skills/pormg-usage/SKILL.md")
        @test m !== nothing && isfile(normpath(joinpath(dirname(stub), m.captures[1])))
        # A pointer, not a second copy: the ceiling `test_skill_stubs.jl` holds this repo's stub to.
        @test filesize(stub) <= 2_048
        # The bundle's `written` list is still the bundle's file names only.
        @test !any(f -> occursin(".claude", f), r.written)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# install_ai_skills: a rerun refreshes the stub; a link in its place is left alone (#1132)
# Re-running is the update mechanism for the stub as for the bundle, so an edited stub is
# overwritten. A link at the stub's path is not written through: a project that linked
# `.claude/skills/pormg-usage` to the bundle directory would otherwise get the bundle's own
# SKILL.md replaced by the stub. Expected: `stub === nothing`, a warning, the bundle intact.
# ─────────────────────────────────────────────────────────────────────────────
@testset "install_ai_skills refreshes the stub and never writes through a link (#1132)" begin
    mktempdir() do dir
        r = PormG.install_ai_skills(dir; io = devnull)
        fresh = read(r.stub, String)
        write(r.stub, "edited by hand\n")
        r2 = PormG.install_ai_skills(dir; io = devnull)
        @test r2.stub == r.stub
        @test read(r2.stub, String) == fresh
    end

    # Every step of the stub's path, each a layout that resolves it to the bundle's own SKILL.md
    # (review: a check on the last two steps only let `.claude/skills -> ../.github/skills` through).
    # `(link at, link target relative to its directory, directory?)`; the file link targets the
    # bundle's SKILL.md, which the install has written by the time the stub is.
    src_skill = joinpath(pkgdir(PormG), ".github", "skills", "pormg-usage", "SKILL.md")
    layouts = ((joinpath(".claude", "skills", "pormg-usage"), joinpath("..", "..", ".github", "skills", "pormg-usage"), true),
               (joinpath(".claude", "skills"), joinpath("..", ".github", "skills"), true),
               (".claude", ".github", true),
               (joinpath(".claude", "skills", "pormg-usage", "SKILL.md"),
                joinpath("..", "..", "..", ".github", "skills", "pormg-usage", "SKILL.md"), false))
    for (at, target, isdir_target) in layouts
        mktempdir() do dir
            bundle = joinpath(dir, ".github", "skills", "pormg-usage")
            mkpath(bundle)
            mkpath(dirname(joinpath(dir, at)))
            linked = try
                symlink(target, joinpath(dir, at); dir_target = isdir_target)
                true
            catch
                false
            end
            if linked
                r = @test_logs (:warn, r"Left the Claude Code skill entry in place") match_mode = :any begin
                    PormG.install_ai_skills(dir; io = devnull)
                end
                @test r.stub === nothing
                @test read(joinpath(bundle, "SKILL.md"), String) == read(src_skill, String)
            else
                @test_skip "symlink creation is not permitted on this platform/user"
            end
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# setup(path; root): the AI skills go into the project root, not pwd() (#1294)
# `setup` asked whether to install the skills and then called `install_ai_skills()`, which defaults
# to `pwd()`: `setup(joinpath(app, "db"))` from anywhere but `app` wrote `connection.yml` into the app
# and the skills somewhere else, so a caller scaffolding a project had to `cd` the whole process into
# it. `root` means what it means for `Configuration.load`: the folder is `joinpath(root, path)` and the
# skills go into `root`. Without `root` nothing moves: both still resolve against `pwd()`.
# Hermetic: SQLite is chosen at the prompt, and `setup` only writes files — it never connects.
# ─────────────────────────────────────────────────────────────────────────────
# Drive the five prompts (adapter, SQLite filename, time zone, models file, AI skills) from `answers`
# and capture what `setup` prints. Returns `(result, output)`.
function _ai1294_setup(answers::AbstractString, args...; kwargs...)
    mktempdir() do io_dir
        stdin_file, stdout_file = joinpath(io_dir, "stdin"), joinpath(io_dir, "stdout")
        write(stdin_file, answers)
        result = open(stdin_file) do in_io
            open(stdout_file, "w") do out_io
                redirect_stdin(in_io) do
                    redirect_stdout(out_io) do
                        PormG.setup(args...; kwargs...)
                    end
                end
            end
        end
        return result, read(stdout_file, String)
    end
end

# Every file under `dir`, relative to it.
_ai1294_files(dir) = sort!([relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs])

const _AI1294_SQLITE_DEFAULTS = "2\n\n\n\n"            # SQLite, database.sqlite, UTC, models.jl

@testset "setup(path; root) writes the config and the skills under root, from any pwd (#1294)" begin
    mktempdir() do project
        mktempdir() do elsewhere
            r, out = cd(elsewhere) do
                _ai1294_setup(_AI1294_SQLITE_DEFAULTS * "y\n", "db"; root = project)
            end
            @test isfile(joinpath(project, "db", "connection.yml"))
            @test isfile(joinpath(project, "db", "models.jl"))
            @test isfile(joinpath(project, ".github", "skills", "pormg-usage", "SKILL.md"))
            @test isfile(joinpath(project, ".claude", "skills", "pormg-usage", "SKILL.md"))
            @test r.installed_dir == joinpath(project, ".github", "skills", "pormg-usage")
            @test isempty(_ai1294_files(elsewhere))               # pwd() got nothing — the defect
            # The prompt names where the skills will go, and the load hint carries the root.
            @test occursin("install PormG AI skills into $(abspath(project))?", out)
            # `repr`, so a Windows root (`C:\\Users\\…`) prints as a string literal that parses.
            @test occursin("PormG.Configuration.load(\"db\"; root = $(repr(project)))", out)
        end
    end
end

@testset "setup(path) without root still resolves both against pwd() (#1294)" begin
    mktempdir() do project
        here, r, out = cd(project) do
            (pwd(), _ai1294_setup(_AI1294_SQLITE_DEFAULTS * "\n", "db")...)   # empty answer: default Y
        end
        @test isfile(joinpath(project, "db", "connection.yml"))
        @test isfile(joinpath(project, ".github", "skills", "pormg-usage", "SKILL.md"))
        @test realpath(r.installed_dir) == realpath(joinpath(project, ".github", "skills", "pormg-usage"))
        @test occursin("PormG.Configuration.load(\"db\")", out)   # no root keyword in the hint
        @test occursin("install PormG AI skills into $(here)?", out)   # the prompt names pwd()
    end
end

@testset "setup refuses an absolute path with root, before writing anything (#1294)" begin
    mktempdir() do project
        mktempdir() do elsewhere
            err = cd(elsewhere) do
                try
                    _ai1294_setup(_AI1294_SQLITE_DEFAULTS * "y\n", joinpath(elsewhere, "db"); root = project)
                    nothing
                catch e
                    e
                end
            end
            @test err isa PormG.InvalidConfigurationError
            @test err !== nothing && occursin("setup(\"db\"; root = …)", err.msg)
            @test isempty(_ai1294_files(project))
            @test isempty(_ai1294_files(elsewhere))
        end
    end
end

@testset "setup with root installs no skills when the answer is n (#1294)" begin
    mktempdir() do project
        _ai1294_setup(_AI1294_SQLITE_DEFAULTS * "n\n", "db"; root = project)
        @test isfile(joinpath(project, "db", "connection.yml"))
        @test !isdir(joinpath(project, ".github"))
        @test !isdir(joinpath(project, ".claude"))
    end
end

@testset "setup with a relative root resolves it against pwd() and keeps it in the load hint (#1294)" begin
    mktempdir() do parent
        here, r, out = cd(parent) do
            (pwd(), _ai1294_setup(_AI1294_SQLITE_DEFAULTS * "y\n", "db"; root = "race_control")...)
        end
        @test isfile(joinpath(parent, "race_control", "db", "connection.yml"))
        @test isfile(joinpath(parent, "race_control", ".github", "skills", "pormg-usage", "SKILL.md"))
        @test !isdir(joinpath(parent, ".github"))                # not the working directory itself
        @test occursin("install PormG AI skills into $(joinpath(here, "race_control"))?", out)
        # The relative root, as passed: the call `load` accepts from the same working directory.
        @test occursin("PormG.Configuration.load(\"db\"; root = \"race_control\")", out)
    end
end

# The load hint is printed to be pasted, so it is a Julia string literal on every platform: a `$` in
# the root (or a Windows `C:\Users`) must come out escaped. A temp path has neither on Linux/macOS,
# which is why this case names one explicitly rather than relying on the Windows CI leg alone.
@testset "setup prints the load hint's root as a literal that parses (#1294)" begin
    mktempdir() do project
        root = joinpath(project, raw"pit$lane")
        _, out = _ai1294_setup(_AI1294_SQLITE_DEFAULTS * "n\n", "db"; root = root)
        @test occursin("load(\"db\"; root = $(repr(root)))", out)
        @test occursin(raw"pit\$lane", out)                     # escaped, not raw interpolation
        @test isfile(joinpath(root, "db", "connection.yml"))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# setup: a typed models-file name is used, not a crash (#1477)
# The models prompt read its answer with `readline() |> strip`, a `SubString{String}`, and
# `Generator.create_models_jl` takes a `String`: any typed name threw a `MethodError` after
# `connection.yml` was already written, so only the empty answer (the `"models.jl"` literal) worked.
# Every other prompt reads through `read_input`, which returns a `String`; this one now does too.
# No SQL: `setup` only writes files.
# ─────────────────────────────────────────────────────────────────────────────
@testset "setup writes the models file under the name typed at the prompt (#1477)" begin
    mktempdir() do project
        # SQLite, database.sqlite, UTC, `f1_models.jl`, no skills.
        _ai1294_setup("2\n\n\nf1_models.jl\nn\n", "db"; root = project)
        models_file = joinpath(project, "db", "f1_models.jl")
        @test isfile(joinpath(project, "db", "connection.yml"))
        @test isfile(models_file)
        @test !isfile(joinpath(project, "db", "models.jl"))     # the typed name, not the default
        @test startswith(read(models_file, String), "module f1_models\n")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# setup: a models-file name that cannot be a module name is asked again (#1486)
# `create_models_jl` now refuses a name whose stem is not a Julia identifier, with
# `ModelDefinitionError`. `connection.yml` is already written when the models prompt runs, so a throw
# there would leave the wizard half done; the prompt prints the refusal and asks again instead. Before
# #1486 it wrote `module f1-models`, a file `include` could not load. No SQL: `setup` only writes files.
# ─────────────────────────────────────────────────────────────────────────────
@testset "setup asks again for a models-file name that cannot be a module name (#1486)" begin
    mktempdir() do project
        # SQLite, database.sqlite, UTC, `f1-models.jl` (refused), `f1_models.jl`, no skills.
        _, out = _ai1294_setup("2\n\n\nf1-models.jl\nf1_models.jl\nn\n", "db"; root = project)
        db = joinpath(project, "db")
        @test count("Models file name [Default: models.jl]: ", out) == 2   # asked again
        @test occursin("\"f1-models\" is not a Julia identifier", out)     # and told why
        @test !isfile(joinpath(db, "f1-models.jl"))                        # the refused name: no file
        @test startswith(read(joinpath(db, "f1_models.jl"), String), "module f1_models\n")
        @test occursin("Configuration saved successfully", out)            # the wizard finished
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# setup: a PostgreSQL adapter is asked for its driver (#1676)
# What it tests: after the port, a PostgreSQL setup asks `PostgreSQL driver (LibPQ or Postgres)`.
#   A typed answer (any case) writes its package's spelling as `postgres_driver:` into the dev, prod
#   and test blocks, and the driver `load` reads from that file (`_peek_driver`, what `load` asks
#   before it builds a pool) is that driver — `LibPQ` included, so `PORMG_POSTGRES_DRIVER` cannot
#   override a typed choice. An empty answer or end of input writes no key, and the file is
#   byte-identical to the writer's output without one, also when the variable is set (the prompt
#   then says the variable decides). An unknown answer prints the text `_resolve_postgres_driver`
#   raises and asks again. An SQLite adapter is not asked.
# Why it matters: Postgres.jl is a supported driver (#1072), and the only ways to choose it were
#   editing the file by hand or the environment variable, so a scaffold built on `setup` had nothing
#   to read; and a file written by taking the default must not change. Hermetic: `setup` only writes
#   files. The end-of-input case takes every later default too, the AI skills prompt's `Y` included,
#   so it installs them into its temporary project.
# PostgreSQL, f1, localhost, f1_user, f1_pass, 5432, <driver answer>, UTC, models.jl, no skills.
_pg1676(driver_answer) = "1\nf1\n\nf1_user\nf1_pass\n\n" * driver_answer * "\n\n\nn\n"

# The file the writer produces with setup's answers and no driver: what a LibPQ app's file must equal.
function _pg1676_reference()
    mktempdir() do ref
        PormG.Generator.create_db_folder_and_yml(path = ref, adapter = "PostgreSQL", database = "f1",
            host = "localhost", username = "f1_user", password = "f1_pass", port = 5432, time_zone = "UTC")
        read(joinpath(ref, "connection.yml"), String)
    end
end

const _PG1676_PROMPT = "PostgreSQL driver (LibPQ or Postgres) [Default: LibPQ]: "

@testset "setup writes postgres_driver: Postgres when Postgres is chosen (#1676)" begin
    for answer in ("Postgres", "postgres", " POSTGRES ")
        mktempdir() do project
            _, out = _ai1294_setup(_pg1676(answer), "db"; root = project)
            yml = joinpath(project, "db", "connection.yml")
            text = read(yml, String)
            @test count("\n  postgres_driver: Postgres\n", text) == 3        # dev, prod and test
            for env in ("dev", "prod", "test")
                @test PormG.Configuration._peek_driver(yml, env) === :postgres
            end
            @test count(_PG1676_PROMPT, out) == 1
            # The help line names what each choice costs.
            @test occursin("LibPQ (the default) is needed for `passfile`", out)
            @test occursin("Postgres (Postgres.jl, pure Julia)", out)
            # The only difference from a LibPQ file is the three key lines.
            @test replace(text, "  postgres_driver: Postgres\n" => "") == _pg1676_reference()
        end
    end
end

@testset "setup writes no postgres_driver key for an empty answer, whatever PORMG_POSTGRES_DRIVER says (#1676)" begin
    reference = _pg1676_reference()
    for env_value in (nothing, "Postgres")
        mktempdir() do project
            _, out = withenv("PORMG_POSTGRES_DRIVER" => env_value) do
                _ai1294_setup(_pg1676(""), "db"; root = project)
            end
            yml = joinpath(project, "db", "connection.yml")
            @test read(yml, String) == reference                       # byte-identical, no key
            # Without the key the variable still decides at load time, and the prompt says so when set.
            withenv("PORMG_POSTGRES_DRIVER" => env_value) do
                @test PormG.Configuration._peek_driver(yml, "dev") === (env_value === nothing ? :libpq : :postgres)
            end
            @test occursin("PORMG_POSTGRES_DRIVER is set", out) == (env_value !== nothing)
        end
    end
end

@testset "setup writes postgres_driver: LibPQ when LibPQ is typed, so the variable cannot override it (#1676)" begin
    for answer in ("LibPQ", "libpq")
        mktempdir() do project
            withenv("PORMG_POSTGRES_DRIVER" => "Postgres") do
                _ai1294_setup(_pg1676(answer), "db"; root = project)
            end
            yml = joinpath(project, "db", "connection.yml")
            text = read(yml, String)
            @test count("\n  postgres_driver: LibPQ\n", text) == 3          # the package's spelling
            @test replace(text, "  postgres_driver: LibPQ\n" => "") == _pg1676_reference()
            withenv("PORMG_POSTGRES_DRIVER" => "Postgres") do
                for env in ("dev", "prod", "test")
                    @test PormG.Configuration._peek_driver(yml, env) === :libpq   # the typed choice holds
                end
            end
        end
    end
end

@testset "setup asks again for a PostgreSQL driver it does not know, with the resolver's text (#1676)" begin
    expected = try
        PormG.Configuration._resolve_postgres_driver("pgx"; source = "setup")
        ""
    catch e
        PormG.error_message(e)
    end
    @test occursin("`postgres_driver` must be one of LibPQ or Postgres", expected)
    mktempdir() do project
        # PostgreSQL, f1, localhost, f1_user, f1_pass, 5432, `pgx` (refused), `Postgres`, UTC, models.jl, no skills.
        _, out = _ai1294_setup("1\nf1\n\nf1_user\nf1_pass\n\npgx\nPostgres\n\n\nn\n", "db"; root = project)
        @test count(_PG1676_PROMPT, out) == 2                          # asked again
        @test occursin(expected, out)                                  # with the resolver's own text
        @test count("\n  postgres_driver: Postgres\n", read(joinpath(project, "db", "connection.yml"), String)) == 3
        @test occursin("Configuration saved successfully", out)
    end
end

@testset "setup at end of input takes the default driver and finishes (#1676)" begin
    # The non-interactive path: `setup` takes every answer from stdin, and at end of input `readline`
    # returns "", the default. A script that stops after the database name gets a LibPQ file.
    mktempdir() do project
        _, out = _ai1294_setup("1\nf1\n", "db"; root = project)
        text = read(joinpath(project, "db", "connection.yml"), String)
        @test !occursin("postgres_driver", text)
        @test occursin("  database: f1\n", text)
        @test count(_PG1676_PROMPT, out) == 1
        @test occursin("Configuration saved successfully", out)
    end
end

@testset "setup does not ask an SQLite adapter for a PostgreSQL driver (#1676)" begin
    mktempdir() do project
        _, out = _ai1294_setup(_AI1294_SQLITE_DEFAULTS * "n\n", "db"; root = project)
        @test !occursin("PostgreSQL driver", out)
        @test !occursin("postgres_driver", read(joinpath(project, "db", "connection.yml"), String))
    end
end

@testset "create_db_folder_and_yml refuses postgres_driver for a non-PostgreSQL adapter (#1676)" begin
    for adapter in ("SQLite", "MySQL")
        mktempdir() do dir
            folder = joinpath(dir, "db")
            @test_throws PormG.InvalidConfigurationError PormG.Generator.create_db_folder_and_yml(
                path = folder, adapter = adapter, postgres_driver = "Postgres")
            @test !isdir(folder)                                       # refused before anything is written
        end
    end
end

@testset "create_db_folder_and_yml checks postgres_driver as load does and writes its canonical spelling (#1676)" begin
    # What: an unknown driver, an empty one, and a lowercase one, through the writer directly (a
    # scaffold calls it without `setup`). Expected: the unknown one raises the resolver's own refusal,
    # the empty one is refused (handed to the resolver it would read PORMG_POSTGRES_DRIVER, and write
    # the shell's choice), neither writes a file; `postgres` is written as `Postgres`. Why: a file the
    # writer accepts must be one `load` accepts.
    refusal(f) = try f(); nothing catch e; e end
    mktempdir() do dir
        folder = joinpath(dir, "db")
        e = refusal(() -> PormG.Generator.create_db_folder_and_yml(path = folder, postgres_driver = "pgx"))
        @test e isa PormG.InvalidConfigurationError
        @test occursin("`postgres_driver` must be one of LibPQ or Postgres", PormG.error_message(e))
        e = withenv("PORMG_POSTGRES_DRIVER" => "Postgres") do
            refusal(() -> PormG.Generator.create_db_folder_and_yml(path = folder, postgres_driver = " "))
        end
        @test e isa PormG.InvalidConfigurationError
        @test occursin("`postgres_driver` is empty", PormG.error_message(e))
        @test !isdir(folder)
        PormG.Generator.create_db_folder_and_yml(path = folder, database = "f1", postgres_driver = "postgres")
        @test count("\n  postgres_driver: Postgres\n", read(joinpath(folder, "connection.yml"), String)) == 3
    end
end
