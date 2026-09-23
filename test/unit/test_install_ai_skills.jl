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
# install_ai_skills: writes nothing outside its own directory (#253)
# The installer must stay read-only everywhere but `.github/skills/pormg-usage/`: consuming apps
# keep hand-curated skills tables in AGENTS.md, and an auto-appended pointer would fight them.
# Snapshot every other file's bytes before and after, and require them identical.
# ─────────────────────────────────────────────────────────────────────────────
@testset "install_ai_skills is read-only outside its skill directory (#253)" begin
    mktempdir() do dir
        write(joinpath(dir, "AGENTS.md"), "# Agents\n")
        write(joinpath(dir, "CLAUDE.md"), "@AGENTS.md\n")
        mkpath(joinpath(dir, ".github", "instructions"))
        write(joinpath(dir, ".github", "instructions", "x.md"), "rules\n")

        skill_dir = joinpath(dir, ".github", "skills", "pormg-usage")
        snapshot() = Dict(joinpath(root, f) => read(joinpath(root, f))
                          for (root, _, fs) in walkdir(dir) for f in fs
                          if !startswith(joinpath(root, f), skill_dir))
        before = snapshot()
        PormG.install_ai_skills(dir; io = devnull)
        @test snapshot() == before
        @test length(before) == 3                    # the snapshot actually covered the files
    end
end
