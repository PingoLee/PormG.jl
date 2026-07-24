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
