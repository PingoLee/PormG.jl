# ==============================================================================
# UNIT TESTS: upgrade_guide — version-scoped UPGRADING.md emitter (issue #216)
#
# `PormG.upgrade_guide(; from, to)` reads the UPGRADING.md shipped with the resolved
# install and renders only the entries a consuming app must port across a version jump.
# These tests pin the scoping math and the parser's robustness against UPGRADING.md's
# two hazards: unstamped "pre-0.2 history" entries, and the commented-out "Template for
# new entries" block (which carries a fake `## …` heading + `- **Version**:` placeholder
# that must NEVER surface as a real entry).
#
# The function parses the *real* repo UPGRADING.md (via `pkgdir`, which resolves to the
# repo root here), so assertions key on frozen historical facts — the 0.1.0 → 0.2.0
# window and the #197 entry — never on the total entry count, which grows over time.
#
# Runs WITHOUT a live database — it only parses a bundled markdown file.
# ==============================================================================

using Test
using PormG

@testset "upgrade_guide over UPGRADING.md (#216)" begin

    # ── structured scope: the historical 0.1.0 → 0.2.0 window is frozen ─────────
    # Upgrading from before the versioning policy up to the first stamped release must
    # surface BOTH the version-stamped 0.2.0 entry (#197) and the unstamped pre-0.2
    # entries (which sort just below 0.2.0).
    @testset "structured scope: 0.1.0 → 0.2.0" begin
        entries = PormG.upgrade_guide(from = v"0.1.0", to = v"0.2.0", structured = true)

        @test entries isa AbstractVector
        @test !isempty(entries)

        # The one stamped entry in this window is the typed-exceptions change (#197 @ 0.2.0).
        i197 = findfirst(e -> occursin("(#197)", e.title), entries)
        @test i197 !== nothing
        @test entries[i197].version == v"0.2.0"

        # The unstamped pre-0.2 history is included and sorts below 0.2.0.
        @test any(e -> e.version < v"0.2.0", entries)

        # Every returned entry falls inside the requested (from, to] window.
        @test all(e -> v"0.1.0" < e.version <= v"0.2.0", entries)

        # Rendered newest-first: the 0.2.0 entry precedes the pre-0.2 ones.
        @test i197 < findfirst(e -> e.version < v"0.2.0", entries)
    end

    # ── nothing newer than where you already are ───────────────────────────────
    @testset "empty scope when from == to" begin
        @test isempty(PormG.upgrade_guide(from = v"0.2.0", to = v"0.2.0", structured = true))
    end

    # ── parser hygiene: the template block must never leak as an entry ──────────
    @testset "no bogus entries from the template block" begin
        all_entries = PormG.upgrade_guide(from = v"0.0.0", to = v"999.0.0", structured = true)
        @test !isempty(all_entries)
        @test !any(e -> occursin("Template", e.title), all_entries)  # template heading dropped
        @test !any(e -> occursin("<api>", e.title), all_entries)     # placeholder never parsed
        # Titles are single-line headings; every body kept some prose after trimming.
        @test all(e -> !occursin('\n', e.title) && !isempty(e.body), all_entries)
    end

    # ── CRLF robustness: a Windows checkout stores UPGRADING.md with \r\n (only *.jl /
    #    *.sh are pinned to eol=lf), and the `(?m)^---$` block separator never matches a
    #    `---\r` line — collapsing the whole file into one bogus entry, so every scoped
    #    lookup comes back empty. This regressed on Windows CI since #216 landed. Exercised
    #    on every platform by feeding CRLF text straight to the parser (Linux CI never
    #    checks the file out as CRLF, so it can't catch this via the on-disk path).
    @testset "parser tolerates CRLF line endings (Windows checkout)" begin
        path = joinpath(pkgdir(PormG), "UPGRADING.md")
        lf   = replace(read(path, String), "\r\n" => "\n")   # normalize whatever is on disk
        crlf = replace(lf, "\n" => "\r\n")

        from_lf   = PormG._parse_upgrading(lf)
        from_crlf = PormG._parse_upgrading(crlf)

        @test !isempty(from_crlf)
        @test from_crlf == from_lf   # identical parse regardless of line endings (version/title/body)
        # The concrete CI symptom: the stamped 0.2.0/#197 entry must survive the block split.
        @test any(e -> occursin("(#197)", e.title) && e.version == v"0.2.0", from_crlf)
    end

    # ── human output: header + entry, internal rollout table trimmed off ────────
    @testset "printed guide: header, entry, no per-app rollout" begin
        out = sprint(io -> PormG.upgrade_guide(io; from = v"0.1.0", to = v"0.2.0"))
        @test occursin("Porting a PormG consumer from", out)     # scope header
        @test occursin("(#197)", out)                            # the entry itself
        @test occursin("How to find the calls to migrate", out)  # grep recipe survives
        @test !occursin("### Per-app rollout", out)              # PormG-internal table trimmed
    end

    @testset "printed guide: empty range says so, no throw" begin
        out = sprint(io -> PormG.upgrade_guide(io; from = v"0.2.0", to = v"0.2.0"))
        @test occursin("nothing to port", out)
    end

    # ── argument handling ──────────────────────────────────────────────────────
    @testset "from is required" begin
        @test_throws ArgumentError PormG.upgrade_guide()
    end

    @testset "string versions coerce like VersionNumbers" begin
        as_str = PormG.upgrade_guide(from = "0.1.0", to = "0.2.0", structured = true)
        as_ver = PormG.upgrade_guide(from = v"0.1.0", to = v"0.2.0", structured = true)
        @test [e.title for e in as_str] == [e.title for e in as_ver]
    end

    @testset "from > to yields an empty scope, not an error" begin
        @test isempty(PormG.upgrade_guide(from = v"9.9.9", to = v"0.2.0", structured = true))
    end

    # ── default `to` resolves to the installed version (no `nothing` path) ──────
    @testset "default to = installed version" begin
        installed = pkgversion(PormG)
        @test installed isa VersionNumber                           # resolves, not `nothing`
        scoped = PormG.upgrade_guide(from = v"0.1.0", structured = true)  # to defaults to installed
        @test !isempty(scoped)
        @test all(e -> e.version <= installed, scoped)
        # From the installed version itself there is nothing newer to port.
        @test isempty(PormG.upgrade_guide(from = installed, structured = true))
    end
end
