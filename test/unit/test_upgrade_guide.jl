# ==============================================================================
# UNIT TESTS: upgrade_guide — version-scoped emitter over the `upgrading/` log (#216, #638)
#
# `PormG.upgrade_guide(; from, to)` reads the `upgrading/` change log shipped with the
# resolved install — one file per entry (#638) — and renders only the entries a consuming
# app must port across a version jump. These tests pin the scoping math and the parser's
# robustness against the log's two hazards: unstamped "pre-0.2 history" entries, and the
# commented-out "Template for new entries" block in `UPGRADING.md` (a fake `## …` heading +
# `- **Version**:` placeholder that must NEVER surface as a real entry — that file is no
# longer parsed, and a testset below asserts it stays that way).
#
# The function parses the *real* repo log (via `pkgdir`, which resolves to the repo root
# here), so assertions key on frozen historical facts — the 0.1.0 → 0.2.0 window and the
# #197 entry — never on the total entry count, which grows over time.
#
# Runs WITHOUT a live database — it only parses bundled markdown files.
# ==============================================================================

using Test
using PormG

# The fourteen entries written before the `- **Version**:` policy existed. They parse at
# `_UNSTAMPED_VERSION` and sort below `0.2.0`; testset E pins the population to exactly this set,
# so a NEW entry that omits the bullet fails there instead of sorting below every consumer's pin.
# Under the single-file log this was "everything below the `pre-0.2 history` divider"; a directory
# has no divider, so the closed set is spelled out. It never grows again.
const PRE_0_2_HISTORY = Set([
    "2026-07-12-bulk-copy-field-formatters-applied.md",
    "2026-07-12-bulk-ops-copy-kwarg-removed.md",
    "2026-07-12-bulk-update-match-pairs-removed.md",
    "2026-07-12-order-nullable-columns-null-placement.md",
    "2026-07-12-pool-exhaustion-raises-typed-pooltimeouterror.md",
    "2026-07-12-sqlorder-orientation-whitelisted-asc-desc.md",
    "2026-07-13-connection-errors-inside-run-transaction.md",
    "2026-07-13-datetimefield-values-canonicalized-utc-existing.md",
    "2026-07-13-distinct-order-sort-key-projection.md",
    "2026-07-16-connection-pool-wait-direct-handoff.md",
    "2026-07-16-create-insert-return-pormgrow-dict.md",
    "2026-07-18-connect-fast-fail-poolconnecterror-fail.md",
    "2026-07-21-87-migrate-non-interactive-safe-throws.md",
    "2026-07-22-92-scalar-correlated-subqueries-subquery-values.md",
])

@testset "upgrade_guide over upgrading/ (#216, #638)" begin

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
    # The authoring template lives in `UPGRADING.md`, which is no longer parsed (#638). If it ever
    # leaks into `upgrading/` it would parse as a bogus entry, so keep asserting it does not.
    @testset "no bogus entries from the template block" begin
        all_entries = PormG.upgrade_guide(from = v"0.0.0", to = PormG._UNRELEASED_VERSION, structured = true)
        @test !isempty(all_entries)
        @test !any(e -> occursin("Template", e.title), all_entries)  # template heading dropped
        @test !any(e -> occursin("<api>", e.title), all_entries)     # placeholder never parsed
        # Titles are single-line headings; every body kept some prose after trimming.
        @test all(e -> !occursin('\n', e.title) && !isempty(e.body), all_entries)
    end

    # ── UPGRADING.md is the contract, not the log ───────────────────────────────
    # #638 moved every entry out of it, and the reader never opens it. That is only a real fix
    # while nobody appends an entry there by old habit: such an entry would sit in a file nothing
    # parses, and the merge would ship the behavior change with no entry anywhere `upgrade_guide`
    # looks. So run the parser over the contract and demand nothing — the writing rules, the
    # release-train table and the commented-out template must all fail acceptance.
    @testset "UPGRADING.md holds no entries (#638)" begin
        contract = replace(read(joinpath(pkgdir(PormG), "UPGRADING.md"), String),
                           "\r\n" => "\n", "\r" => "\n")

        # Cut the commented-out template — the one legitimate `- **Version**:` in the file — by its
        # HTML comment, and do NOT lean on `_parse_upgrading` alone here. That parser truncates
        # everything BELOW the `## Template for new entries` marker, and the template sits at the
        # bottom of the contract; an entry appended after it is therefore discarded before the
        # parser ever looks, which is the likeliest version of this mistake since the template you
        # just copied lives right there. Measured while writing this guard: an appended entry left
        # the suite GREEN until the scan below replaced the parser-only check.
        rest = replace(contract, r"(?s)<!--.*?-->" => "")

        @test occursin(r"(?m)^-[ \t]+\*\*Version\*\*:", contract)      # the template still has one
        @test !occursin(r"(?m)^-[ \t]+\*\*Version\*\*:", rest)         # …and it is the only one
        @test !occursin(r"(?m)^-[ \t]+\*\*Recorded\*\*:", rest)
        @test [e.title for e in PormG._parse_upgrading(rest)] == String[]

        # The two sections everything else points at.
        @test occursin("## Release trains", contract)
        @test occursin("## Template for new entries", contract)
    end

    # ── CRLF robustness: a Windows checkout can store an entry file with \r\n (a file that
    #    never went through git is not covered by `.gitattributes`), and a `(?m)…$` anchor
    #    never sees past a trailing `\r` — headings and bullets then match inconsistently and
    #    the parse becomes platform-dependent. This regressed on Windows CI once #216 landed.
    #    Exercised on every platform by feeding CRLF text straight to the parser (Linux CI
    #    never checks the files out as CRLF, so it can't catch this via the on-disk path).
    @testset "parser tolerates CRLF line endings (Windows checkout)" begin
        seen197 = false
        for path in PormG._upgrading_files()
            name = basename(path)
            lf   = replace(read(path, String), "\r\n" => "\n")   # normalize whatever is on disk
            crlf = replace(lf, "\n" => "\r\n")

            from_lf   = PormG._parse_upgrading(lf)
            from_crlf = PormG._parse_upgrading(crlf)

            # identical parse regardless of line endings (version/title/body); named per file
            @test (name, from_crlf == from_lf) == (name, true)
            seen197 |= any(e -> occursin("(#197)", e.title) && e.version == v"0.2.0", from_crlf)
        end
        # The concrete CI symptom: the stamped 0.2.0/#197 entry must survive.
        @test seen197
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

    # `to` defaults to _UNRELEASED_VERSION — an internal sort key (v"1000000.0.0"), not a real
    # version. It must render as the literal "Unreleased" token on BOTH output paths; leaking the
    # raw sentinel reads as a bug to the consumer running the command.
    @testset "printed guide: the Unreleased sentinel never reaches output" begin
        # populated path — the scope header, with `to` defaulted
        full = sprint(io -> PormG.upgrade_guide(io; from = v"0.1.0"))
        @test occursin("→ Unreleased", full)
        @test !occursin("1000000", full)

        # empty path — from == to == sentinel is an empty range by construction
        empty = sprint(io -> PormG.upgrade_guide(io; from = PormG._UNRELEASED_VERSION))
        @test occursin("nothing to port between Unreleased and Unreleased.", empty)
        @test !occursin("1000000", empty)

        # a real version still renders normally — the label must not swallow ordinary versions
        real = sprint(io -> PormG.upgrade_guide(io; from = v"0.1.0", to = v"0.2.0"))
        @test occursin("0.1.0 → 0.2.0", real)
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

    # ── default `to` reaches the uncut `## Unreleased` work (release-train model) ─
    @testset "default `to` covers the current code" begin
        installed = pkgversion(PormG)
        @test installed isa VersionNumber                           # resolves, not `nothing`
        # The default scope is never NARROWER than the installed release: it also reaches any
        # `## Unreleased` entries (merged but not yet cut), so a consumer dev'ing PormG at HEAD
        # sees what they are actually running.
        default_scope   = PormG.upgrade_guide(from = v"0.1.0", structured = true)
        installed_scope = PormG.upgrade_guide(from = v"0.1.0", to = installed, structured = true)
        @test length(default_scope) >= length(installed_scope)
        @test all(e -> e.version <= installed, installed_scope)     # explicit release scope excludes uncut
    end

    # ── the `## Unreleased` sentinel: exercised on hand-fed text so the test does NOT depend on
    #    the live file's transient Unreleased state (which empties whenever a train is cut). ────
    @testset "`## Unreleased` entries parse as the sentinel and sort newest" begin
        text = "# UPGRADING (fixture)\n\n---\n\n" *
               "## A brand new breaking change (#9001)\n\n" *
               "- **Version**: Unreleased\n- **Recorded**: 2026-01-01\n\n" *
               "Body prose that must survive.\n\n" *
               "### Per-app rollout\n| App | Status |\n\n---\n\n" *
               "## An older shipped change (#9000)\n\n" *
               "- **Version**: 0.2.0\n- **Recorded**: 2025-01-01\n\n" *
               "Old body.\n"
        parsed = PormG._parse_upgrading(text)
        u = findfirst(e -> occursin("(#9001)", e.title), parsed)
        s = findfirst(e -> occursin("(#9000)", e.title), parsed)
        @test u !== nothing && s !== nothing
        @test parsed[u].version == PormG._UNRELEASED_VERSION        # "Unreleased" → sentinel
        @test parsed[s].version == v"0.2.0"
        @test u < s                                                 # sorts above every stamped entry
        @test !occursin("Per-app rollout", parsed[u].body)          # internal table still trimmed
        # Mirrors upgrade_guide's window: the default (current code) includes it; a real target excludes it.
        @test any(e -> occursin("(#9001)", e.title),
                  filter(e -> v"0.1.0" < e.version <= PormG._UNRELEASED_VERSION, parsed))
        @test !any(e -> occursin("(#9001)", e.title),
                   filter(e -> v"0.1.0" < e.version <= v"0.2.0", parsed))
    end

    # ── The single-file log's cut step wrote the release marker (`## 0.8.0 — <date>`) directly
    #    above the FIRST entry of that release with no `---` between them, so the block's first
    #    `##` was the marker, not the entry heading. The per-file log writes no markers (#638),
    #    but the filter stays — one added to an entry file by hand must be ignored, never become
    #    the title — so the grammar is still pinned on hand-fed text. ────────────────────────────
    @testset "release-marker heading is not mistaken for the entry title" begin
        text = "# UPGRADING (fixture)\n\n---\n\n" *
               "## Unreleased — next `0.9.0`\n\n" *
               "## An uncut change (#9101)\n\n" *
               "- **Version**: Unreleased\n- **Recorded**: 2026-02-02\n\nUncut body.\n\n---\n\n" *
               "## 0.8.0 — 2026-01-15\n\n" *
               "## First entry of the release (#9100)\n\n" *
               "- **Version**: 0.8.0\n- **Recorded**: 2026-01-15\n\nFirst body.\n\n---\n\n" *
               "## Second entry of the same release (#9099)\n\n" *
               "- **Version**: 0.8.0\n- **Recorded**: 2026-01-14\n\nSecond body.\n"
        parsed = PormG._parse_upgrading(text)
        @test length(parsed) == 3

        # the title is the entry's OWN heading — never the release marker above it
        @test parsed[1].title == "An uncut change (#9101)"
        @test parsed[2].title == "First entry of the release (#9100)"
        @test parsed[3].title == "Second entry of the same release (#9099)"

        # the version still comes from the `- **Version**:` bullet, not the marker's date
        @test parsed[1].version == PormG._UNRELEASED_VERSION
        @test parsed[2].version == v"0.8.0"

        # the marker is stripped from the body so entries render uniformly: without this, only the
        # first entry of a release carries a `## <ver> — <date>` line and later entries from OTHER
        # releases read as if they belonged to it.
        @test startswith(parsed[2].body, "## First entry of the release (#9100)")
        @test !occursin("## 0.8.0 — 2026-01-15", parsed[2].body)
        @test !occursin("## Unreleased — next", parsed[1].body)
        @test occursin("First body.", parsed[2].body)   # the entry's own content still survives
    end

    # A marker is recognized by the `<token> — ` shape, NOT by "starts with a version". Without the
    # em-dash requirement a real entry titled `## 0.5.0 config format …` is skipped as a marker, the
    # block then has no other `##`, and the entry is dropped SILENTLY — no error, it just vanishes
    # from every guide that should have listed it. That is the worst failure mode this parser has.
    @testset "an entry whose title starts with a version is NOT treated as a marker" begin
        text = "# fixture\n\n---\n\n" *
               "## 0.5.0 config format is now strict (#9200)\n\n" *
               "- **Version**: 0.5.0\n- **Recorded**: 2026-03-03\n\nImportant body.\n"
        parsed = PormG._parse_upgrading(text)
        @test length(parsed) == 1                                        # not swallowed
        @test parsed[1].title == "0.5.0 config format is now strict (#9200)"
        @test parsed[1].version == v"0.5.0"
        @test occursin("Important body.", parsed[1].body)

        # …while a genuine marker sharing a block with its first entry is still stripped.
        marked = PormG._parse_upgrading(
            "# fixture\n\n---\n\n## 0.5.0 — 2026-03-03\n\n## A real change (#9201)\n\n" *
            "- **Version**: 0.5.0\n- **Recorded**: 2026-03-03\n\nBody.\n")
        @test length(marked) == 1
        @test marked[1].title == "A real change (#9201)"
    end

    # ══ #438 — the parser and UPGRADING.md's own "Writing an entry" rules must agree ══════════
    #
    # The parser used to split on `^---$` and gate each block on a `- **Recorded**:` bullet. The
    # writing rules mandate NEITHER, so nine headings written exactly to spec were lost: three
    # (#424, #394, #396) never reached any guide, and six (#379, #388, #380, #347, #346, and #300
    # since 0.4.0 shipped) were merged into a neighbour's body and rendered under its title.
    # `upgrade_guide(from = v"0.4.0")` returned 3 of 11. Nothing caught it — every other assertion
    # in this file keys on frozen historical facts or on `!isempty(...)`, which the 40 older
    # entries satisfied no matter how many new ones were dropped.
    #
    # Three layers, and they cover different things — do not collapse them:
    #
    #   A + B + E (and the #638 directory guards after them) run against the REAL log and guard
    #     log↔parser AGREEMENT. They fail the moment an entry is written that the parser cannot
    #     see (B), that it can see but files under the wrong version (E), or that shares a file
    #     with a neighbour (A). They are deliberately blind to a parser regression on their own:
    #     with every shipped entry carrying both of the old markers, the pre-#438 parser also
    #     passes them. That is not a gap, it is their scope.
    #   C + D pin the parser CONTRACT on hand-fed text — reverting `_parse_upgrading` to the
    #     `---`/`Recorded` gate fails them immediately.
    #   The `_trim_trailing_structure` testset pins the tail trimmer directly, on shapes the real
    #     log does not contain and the file-level guards therefore cannot reach.
    #
    # Every one of them was mutation-tested before landing — each fails under a change that
    # reintroduces the defect it describes. Together they are the only thing standing between a
    # written entry and a consumer never being told to port it.
    #
    # #638 made A and B *simpler*, not weaker: with a file per entry there is no preamble to skip
    # and no template section to truncate, so "every declared entry parses" is "every file yields
    # exactly one entry" and B's derivation is "every non-marker `## ` heading in the directory",
    # with no positional reasoning at all.

    # ── A: every file is exactly one parsed entry ──────────────────────────────
    # `== 1`, not `>= 1`: a second entry in a file is exactly the merge-conflict shape #638 removed,
    # and `== 0` is an entry the parser cannot see. Named per file so a failure says WHICH.
    @testset "every entry file parses as exactly one entry (#438, #638)" begin
        files = PormG._upgrading_files()
        @test !isempty(files)

        for path in files
            name   = basename(path)
            text   = replace(read(path, String), "\r\n" => "\n", "\r" => "\n")
            parsed = PormG._parse_upgrading(text)
            @test (name, length(parsed)) == (name, 1)

            # A line-start `- **Version**:` bullet is the stamp; a file may carry at most one, and
            # when it does the entry must have come back stamped — not at `_UNSTAMPED_VERSION`.
            declared = length(collect(eachmatch(r"(?m)^-[ \t]+\*\*Version\*\*:", text)))
            @test (name, declared <= 1) == (name, true)
            declared == 1 && length(parsed) == 1 &&
                @test (name, parsed[1].version != PormG._UNSTAMPED_VERSION) == (name, true)

            # `---` rules and the old `<!-- pre-0.2 history -->` divider are file structure, never
            # content. NOT `!endswith(body, "---")`: a divider sat below its rule, so a real leak
            # ended in `-->` and slipped straight past a tail check. That weaker assertion shipped
            # in the first cut of this testset and passed while `#197`'s body carried both.
            for e in parsed
                @test (name, occursin(r"(?m)^---[ \t]*$", e.body)) == (name, false)
                @test (name, occursin("pre-0.2 history", e.body)) == (name, false)
            end
        end
    end

    # ── B: no entry heading is silently dropped ────────────────────────────────
    # The expected set is derived from a RAW `readdir` of the log directory, not from
    # `_upgrading_files()`, and that independence is the whole point: `_upgrading_files` keeps only
    # `.md`, and that extension filter is the one selection step the reader has. Deriving the
    # expected set through it would make a file the filter drops disappear from BOTH sides of the
    # comparison — `foo.markdown`, `foo.MD` on a case-sensitive filesystem, a `foo.md.orig` merge
    # leftover — and every assertion would pass while the entry is missing from the guide. Nitro
    # measured exactly that with a planted `foo.markdown` before its own port shipped.
    #
    # The independence is REAL BUT PARTIAL, and the scope is worth stating so nobody over-trusts it:
    # the `.md` filter is genuinely covered, but the derivation below still uses the parser's own
    # heading regex, so a regression in THAT moves both sides together. `_RELEASE_MARKER` is pinned
    # separately on hand-fed text (testsets C/D), which leaves the heading regex as the one shared
    # piece.
    #
    # Note for whoever hits this red without having touched the log: it also fires on a gitignored
    # editor artifact (`….md~`, `….md.swp`), because those are neither `.md` nor absent. That is
    # the same assertion as the `foo.md.orig` case it is built for, and `git status` will look
    # clean while it is red. Delete the artifact.
    #
    # This also guards the one hazard heading-based segmentation introduces — a stray `## ` inside
    # an entry body would split that entry, and the orphaned half would show up here as an
    # unparsed heading instead of silently truncating the entry.
    @testset "no entry heading is silently dropped (#438, #638)" begin
        dir = PormG._upgrading_dir()
        expected = String[]
        for f in readdir(dir)
            path = joinpath(dir, f)
            # Every `.md` is an entry and nothing else belongs in the directory — asserted here
            # against the raw listing, which is the only thing keeping this net independent of the
            # reader's selection step.
            @test (f, isfile(path) && endswith(f, ".md")) == (f, true)
            isfile(path) || continue
            text = replace(read(path, String), "\r\n" => "\n", "\r" => "\n")
            append!(expected, [String(m[1]) for m in eachmatch(r"(?m)^##[ \t]+(.+?)[ \t]*$", text)
                               if !occursin(PormG._RELEASE_MARKER, m[1])])
        end
        titles = [e.title for e in PormG._read_upgrading_entries()]

        @test !isempty(expected)                   # the derivation itself still finds headings

        # Named so a failure prints WHICH heading vanished, not just a count mismatch.
        unparsed   = setdiff(expected, titles)
        unexpected = setdiff(titles, expected)
        @test unparsed == String[]
        @test unexpected == String[]
        @test length(titles) == length(expected)   # no heading parsed twice (setdiff ignores multiplicity)
    end

    # ── E: only genuine pre-0.2 history may omit `- **Version**:` ──────────────
    # The parser accepts `- **Recorded**:` alone as an entry marker, because the pre-0.2 history
    # predates the `- **Version**:` policy and has no such bullet. That leniency has a sharp edge:
    # a NEW entry carrying `Recorded` but not `Version` — an easy slip, the two are adjacent in
    # the template — parses at `_UNSTAMPED_VERSION`, sorts below 0.2.0, and is invisible to every
    # consumer on ≥ 0.2.0. That is #438's own failure mode in a new place, and A and B both pass
    # through it: A only asks that a declared bullet came back stamped, B only that the heading
    # parsed at all.
    #
    # So pin the population instead — the unstamped entries are exactly `PRE_0_2_HISTORY`, and that
    # set is closed. It never grows again. (Under the single-file log this was "everything below
    # the divider"; a directory has no divider, so the set is spelled out by filename.)
    @testset "only pre-0.2 history entries may omit `- **Version**:` (#438, #638)" begin
        unstamped = Set{String}()
        for path in PormG._upgrading_files()
            any(e -> e.version == PormG._UNSTAMPED_VERSION,
                PormG._parse_upgrading(read(path, String))) && push!(unstamped, basename(path))
        end

        # Both directions, named: a new unstamped file shows up in `extra`, a renamed or deleted
        # historical one in `gone`. Either is a deliberate test edit, never a silent pass.
        extra = sort(collect(setdiff(unstamped, PRE_0_2_HISTORY)))
        gone  = sort(collect(setdiff(PRE_0_2_HISTORY, unstamped)))
        @test extra == String[]
        @test gone  == String[]
    end

    # ══ #638 — one file per entry, and the directory is the log ════════════════════════════════

    # ── the filename is the sort key, so it must tell the truth ────────────────
    # `_upgrading_files` sorts by filename, and that is what orders entries sharing a version. A
    # file named anything else still parses — the reader has no name gate, deliberately — but it
    # would sort arbitrarily, so pin the convention here, where the failure is loud.
    @testset "entry filenames are `YYYY-MM-DD-<slug>.md` and match their Recorded bullet (#638)" begin
        for path in PormG._upgrading_files()
            name = basename(path)
            @test (name, occursin(r"^\d{4}-\d{2}-\d{2}-[a-z0-9.-]+\.md$", name)) == (name, true)

            # The prefix must be the date the entry itself records, or the sort is a lie.
            m = match(r"(?m)^-[ \t]+\*\*Recorded\*\*:[ \t]*(\d{4}-\d{2}-\d{2})", read(path, String))
            @test (name, m === nothing ? "" : m[1]) == (name, first(name, 10))
        end
    end

    # ── newest-first holds by construction, not by layout ──────────────────────
    # Under the single-file log, newest-first was a property of a hand-maintained layout that the
    # parser merely preserved. `_read_upgrading_entries` now sorts by version with a stable sort.
    #
    # THIS MUST BE TESTED ON A FIXTURE, NOT ON THE SHIPPED LOG, and the first cut of this testset
    # got that wrong in a way worth recording: it asserted `issorted(entries; by = version)` over
    # the live corpus, which is the direct postcondition of the `sort!` on the line above it AND
    # already true of the input, because every entry's `Recorded` date happens to agree with its
    # release order. Deleting the `sort!` outright left the whole file green. A sort is only
    # load-bearing where filename order and version order DISAGREE — a `z` hotfix stamped onto an
    # older-dated entry, or a `Recorded` date corrected after a cut — and the shipped log cannot
    # express that case. Hence `dir`.
    @testset "the reader sorts by version, stably, not by filename (#638)" begin
        mktempdir() do dir
            entry(name, ver, rec, title) = write(joinpath(dir, name),
                "## $title\n\n- **Version**: $ver\n- **Recorded**: $rec\n\nBody.\n")

            # Filename order (descending) is deliberately NOT version order:
            #   by filename:  bbb(09-09) ccc(05-05) ddd(04-04) aaa(03-03)
            #   by version:   ccc ddd aaa  (0.6.0, ties keep filename order) then bbb (0.3.0)
            entry("2026-09-09-bbb.md", "0.3.0", "2026-09-09", "bbb")   # newest date, OLDEST version
            entry("2026-05-05-ccc.md", "0.6.0", "2026-05-05", "ccc")
            entry("2026-04-04-ddd.md", "0.6.0", "2026-04-04", "ddd")
            entry("2026-03-03-aaa.md", "0.6.0", "2026-03-03", "aaa")

            got = [e.title for e in PormG._read_upgrading_entries(dir)]

            # One assertion against a hand-computed constant, deliberately — it pins the key AND
            # the stability at once, and every weaker restatement beside it (`first(got) != "bbb"`,
            # a filtered-subsequence check) is implied by it and cannot fail on its own. This
            # file removed a line for that reason; adding two back would be the same defect.
            #
            # What it discriminates: by filename this is ["bbb","ccc","ddd","aaa"], so a deleted
            # `sort!` is red; re-keying by title gives ["ddd","ccc","bbb","aaa"], red; dropping
            # `rev = true` from the filename sort gives ["aaa","ddd","ccc","bbb"], red; and an
            # unstable sort permutes the three 0.6.0 entries, red. It does NOT discriminate
            # `alg = MergeSort` from the default, because Julia's default sort is already stable —
            # the `alg` is documentation of intent, not a behavior this can pin.
            @test got == ["ccc", "ddd", "aaa", "bbb"]
        end
    end

    # ── the shipped log is consistent with that contract ─────────────────────────
    # Kept as a weaker companion to the fixture above, because it guards a different thing: that
    # nobody has shipped an entry whose `Recorded` date contradicts its release order. That is not
    # an error — the sort handles it — but it is worth knowing about, since it is the only way the
    # rendered order stops matching the directory listing a reader browses on GitHub.
    @testset "shipped entries come back newest-first (#638)" begin
        entries = PormG._read_upgrading_entries()
        @test !isempty(entries)
        @test issorted(entries; by = e -> e.version, rev = true)
    end

    # ── a broken install must not read as "you are up to date" ───────────────────
    # `upgrade_guide` renders an empty result as "nothing to port", which is exactly what a consumer
    # already on the latest version sees. So a log that failed to ship — trimmed by a sparse
    # checkout, an rsync filter, a Docker layer copying only `src/` — would be indistinguishable
    # from good news, in the one tool whose whole job is to tell an app what it still has to port.
    @testset "a missing or empty log throws rather than reporting nothing to port (#638)" begin
        # The type alone is NOT enough here. Two different faults throw the same
        # `InvalidConfigurationError`, so swapping the two message strings — or collapsing the
        # guards into one — would leave every type assertion below green while a consuming app is
        # handed a diagnosis naming the wrong cause. Assert on the message for the missing-vs-empty
        # pair, which is the distinction the guards exist to draw. (The type itself is #639's, and
        # its catchability is asserted in the next testset.)
        ICE = PormG.InvalidConfigurationError
        mktempdir() do dir
            absent = joinpath(dir, "no-such-log")
            @test_throws ICE PormG._upgrading_files(absent)
            @test occursin("does not exist",
                           sprint(showerror, try PormG._upgrading_files(absent) catch e; e end))

            # present but empty — the case a directory makes newly reachable
            @test_throws ICE PormG._upgrading_files(dir)
            @test_throws ICE PormG._read_upgrading_entries(dir)
            @test occursin("holds no `.md` entry files",
                           sprint(showerror, try PormG._upgrading_files(dir) catch e; e end))

            # …and a non-`.md` file is not an entry, so a directory holding only one is still empty
            write(joinpath(dir, "README.txt"), "not an entry")
            @test_throws ICE PormG._upgrading_files(dir)

            # A DIRECTORY named `x.md` is not an entry either. Without the `isfile` filter this
            # reaches `read` and throws a bare `SystemError` at a consuming app instead.
            mkpath(joinpath(dir, "notafile.md"))
            @test_throws ICE PormG._upgrading_files(dir)

            # one real entry beside them is enough, and the non-entries stay out of the result
            write(joinpath(dir, "2026-09-21-9500-real.md"),
                  "## A real entry (#9500)\n\n- **Version**: 0.6.0\n- **Recorded**: 2026-09-21\n\nBody.\n")
            @test length(PormG._upgrading_files(dir)) == 1
            @test [e.title for e in PormG._read_upgrading_entries(dir)] == ["A real entry (#9500)"]
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # upgrade_guide errors: a broken install is catchable as `PormGError` (#639)
    # The three log guards used to throw `ArgumentError`, so the `catch e isa PormGError` that
    # docs/src/errors.md tells a consuming app to write caught none of them. They are a broken
    # install, not caller misuse; only the missing `from` kwarg stays `ArgumentError`.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a broken log is a ConfigurationError, a missing `from` is not (#639)" begin
        caught(f) = try f(); nothing catch e; e end

        mktempdir() do root
            # No `upgrading/` next to the install. `root` stands in for `pkgdir`, which cannot be
            # broken on the real install — this guard had no test at all before #639.
            e = caught(() -> PormG._upgrading_dir(root))
            @test e isa PormG.ConfigurationError
            @test e isa PormG.PormGError           # the type a consumer's catch block names
            @test !(e isa ArgumentError)
            @test occursin("not found next to the installed PormG", sprint(showerror, e))

            # The missing and the empty directory: one supertype check each — their messages are
            # asserted in the testset above.
            @test caught(() -> PormG._upgrading_files(joinpath(root, "nope"))) isa PormG.PormGError
            @test caught(() -> PormG._upgrading_files(root)) isa PormG.PormGError
        end

        # The default still resolves the shipped log, so the new `root` argument changed nothing.
        @test PormG._upgrading_dir() == joinpath(pkgdir(PormG), "upgrading")

        # The one deliberate keep: omitting `from` is a mistake in the call, not in the install.
        e = caught(() -> PormG.upgrade_guide())
        @test e isa ArgumentError
        @test !(e isa PormG.PormGError)
    end

    # ── an entry may quote the contract without losing its body ─────────────────
    # `_parse_upgrading` cuts the authoring template out of the text it is given. That branch
    # existed for `UPGRADING.md`, which is no longer parsed — so since #638 the only text it can
    # act on is an ENTRY FILE, and a bare substring match truncated any entry that merely mentioned
    # the template by name. Below the `- **Version**:` bullet the loss is SILENT: the entry keeps
    # its title and version and ships a shortened body. Nothing else can catch that, because every
    # log-versus-parse check runs through this same function on both sides.
    @testset "an entry quoting the template keeps its body (#638)" begin
        quoted = "## An entry about the upgrade log itself (#9600)\n\n" *
                 "- **Version**: Unreleased\n- **Recorded**: 2026-09-21\n\n" *
                 "### What changed\n\n" *
                 "Copy the block under `## Template for new entries` into a new file.\n\n" *
                 "TRAILING PROSE THAT MUST SURVIVE.\n"
        parsed = PormG._parse_upgrading(quoted)
        @test length(parsed) == 1
        @test parsed[1].title == "An entry about the upgrade log itself (#9600)"
        @test occursin("TRAILING PROSE THAT MUST SURVIVE.", parsed[1].body)

        # …while a REAL template section, written as a column-0 heading, is still cut — otherwise
        # its commented-out `- **Version**:` placeholder parses as a bogus entry.
        with_section = "## A real entry (#9601)\n\n- **Version**: 0.6.0\n- **Recorded**: 2026-09-21\n\n" *
                       "Body.\n\n## Template for new entries\n\n<!--\n## `<api>` — <summary>\n\n" *
                       "- **Version**: Unreleased\n- **Recorded**: <YYYY-MM-DD>\n-->\n"
        # The title-set equality already excludes the `<api>` placeholder; a separate
        # `!any(occursin("<api>"), …)` beside it could not fail on its own.
        cut = PormG._parse_upgrading(with_section)
        @test [e.title for e in cut] == ["A real entry (#9601)"]
    end

    # ── every cut release has a dated row ──────────────────────────────────────
    # A release's DATE used to live in a `## <ver> — <date>` marker sitting in the same file as its
    # entries, so forgetting one was visible in the diff that stamped them. #638 moved it into a
    # table in `UPGRADING.md` — a file nothing parses and, without this, nothing tests. That would
    # leave `/pormg-cut-release`'s "skipping it loses the date for good" as the only guard, which
    # is exactly the say-so-only shape this suite exists to replace.
    @testset "every cut release is recorded in the Release trains table (#638)" begin
        contract = read(joinpath(pkgdir(PormG), "UPGRADING.md"), String)
        cut = sort(unique(e.version for e in PormG._read_upgrading_entries()
                          if e.version != PormG._UNRELEASED_VERSION &&
                             e.version != PormG._UNSTAMPED_VERSION))
        @test !isempty(cut)

        for v in cut
            # Match the row, not just the number: a bare `occursin` would be satisfied by any prose
            # mentioning the version, and the thing being guarded is that a DATE was recorded.
            row = Regex("(?m)^\\|\\s*`" * replace(string(v), "." => "\\.") *
                        "`\\s*\\|\\s*\\d{4}-\\d{2}-\\d{2}\\s*\\|")
            @test (string(v), occursin(row, contract)) == (string(v), true)
        end
    end

    # ── C: the contract the writing rules actually state ───────────────────────
    # A `## ` heading plus a line-start `- **Version**:` — no `---`, no `- **Recorded**:`. This is
    # the exact shape of the eight entries #438 was filed for.
    @testset "an entry needs neither `---` nor `- **Recorded**:` (#438)" begin
        text = "# fixture\n\n" *
               "## Writing an entry\n\n- One `##` entry per change, with\n" *
               "  `- **Version**: Unreleased` on it.\n\n" *
               "## Unreleased — next `0.9.0`\n\n" *
               "## First uncut change (#9300)\n\n- **Version**: Unreleased\n\nFirst body.\n\n" *
               "## Second uncut change (#9301)\n\n- **Version**: Unreleased\n\nSecond body.\n"
        parsed = PormG._parse_upgrading(text)

        @test length(parsed) == 2
        @test parsed[1].title == "First uncut change (#9300)"
        @test parsed[2].title == "Second uncut change (#9301)"
        @test all(e -> e.version == PormG._UNRELEASED_VERSION, parsed)

        # The regression itself: without a `---` between them the first entry used to swallow the
        # second, which then never appeared under its own title or its own version.
        @test occursin("First body.", parsed[1].body)
        @test !occursin("Second uncut change", parsed[1].body)
        @test occursin("Second body.", parsed[2].body)

        # The writing rules themselves are prose, not an entry — their `- **Version**:` mention is
        # indented inside backticks, which the line-start marker does not match.
        @test !any(e -> occursin("Writing an entry", e.title), parsed)
    end

    # ── the tail trimmer, directly ─────────────────────────────────────────────
    # `_trim_trailing_structure` is the one piece of #438 with a silent failure mode: whatever it
    # fails to strip is rendered to the consumer, and whatever it strips too eagerly is content
    # they never see. Both halves are pinned below, and the second half needs its own coverage
    # because NO file-level guard can reach it — testset A asserts a body contains no stray rule
    # and no divider, and eating content makes both of those assertions *more* satisfied. B only
    # checks headings, which sit at a body's start and always survive. An over-strip is invisible
    # everywhere except here.
    @testset "`_trim_trailing_structure` peels structure, keeps content (#438)" begin
        T = PormG._trim_trailing_structure

        # strips: blanks, rules, single- and multi-line comments, in any order
        @test T("Body.")                              == "Body."
        @test T("Body.\n\n\n")                        == "Body."
        @test T("Body.\n\n---\n")                     == "Body."
        @test T("Body.\n\n---\n\n<!-- div -->")       == "Body."
        @test T("Body.\n\n---\n\n<!--\nmulti\n-->")   == "Body."   # multi-line: one unit
        @test T("Body.\n\n<!-- x -->\n")              == "Body."
        @test T("Body.\n\n<!-- x -->\n\n---\n")       == "Body."   # alternating, either outermost

        @test T("Body.\n\n  ---\n")                   == "Body."   # ≤3 spaces: still a rule

        # …but 4 spaces or a tab makes it an indented CODE BLOCK, not a rule. Peeling there
        # deletes the last line of a code sample the consumer is meant to copy.
        @test T("Body.\n\n    ---\n")                 == "Body.\n\n    ---"
        @test T("Body.\n\n\t---\n")                   == "Body.\n\n\t---"
        @test T("Example:\n\n    key: v\n    ---\n")  == "Example:\n\n    key: v\n    ---"

        # keeps: anything interior
        @test T("Top\n\n---\n\nBottom.")              == "Top\n\n---\n\nBottom."
        @test T("Top\n<!-- keep -->\nBottom.")        == "Top\n<!-- keep -->\nBottom."
        @test T("```html\n<!-- keep me -->\n```")     == "```html\n<!-- keep me -->\n```"

        # near-misses that are markdown content, not a rule
        @test T("Body.\n\n----\n")                    == "Body.\n\n----"
        @test T("Body.\n\n| --- |\n")                 == "Body.\n\n| --- |"

        # ── the over-strip half: a line carrying prose is never peeled, whole or in part ──
        # This is the invariant, and it is the one this function broke twice. A trimmer that can
        # only remove whole structural LINES cannot delete prose by construction; one that can
        # start matching mid-line always can. Every row below returned less — sometimes far less —
        # than its input under an earlier cut.
        @test T("<!-- a --> VISIBLE <!-- b -->")      == "<!-- a --> VISIBLE <!-- b -->"

        # a stray opener + any `-->` at the tail used to swallow everything between them
        @test T("stray <!-- opener\n\nKEEP ME\n\n<!-- div -->") == "stray <!-- opener\n\nKEEP ME"
        @test T("prose with <!-- open\nMORE PROSE\nthe arrow points -->") ==
              "prose with <!-- open\nMORE PROSE\nthe arrow points -->"

        # worst case: an unclosed opener inside a fence. Losing the content is the small half —
        # eating the closing fence leaves it open, and `upgrade_guide` prints entries into one
        # stream, so every LATER entry vanishes into it as well.
        @test T("```html\n<!-- unclosed\n```\nKEEP\n\n<!-- div -->") ==
              "```html\n<!-- unclosed\n```\nKEEP"
    end

    # ── the `---` rule is a visual separator, never content ────────────────────
    @testset "a decorative `---` rule never reaches an entry body (#438)" begin
        parsed = PormG._parse_upgrading(
            "# fixture\n\n## 0.9.0 — 2026-09-09\n\n" *
            "## A change (#9400)\n\n- **Version**: 0.9.0\n\nBody.\n\n---\n\n" *
            "## Another change (#9401)\n\n- **Version**: 0.9.0\n\nOther body.\n")
        @test length(parsed) == 2
        @test endswith(parsed[1].body, "Body.")
        @test !occursin("---", parsed[1].body)
        @test endswith(parsed[2].body, "Other body.")
    end
end
