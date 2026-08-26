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
        all_entries = PormG.upgrade_guide(from = v"0.0.0", to = PormG._UNRELEASED_VERSION, structured = true)
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

    # ── `/pormg-cut-release` writes the release marker (`## 0.8.0 — <date>`) directly above the
    #    FIRST entry of that release with no `---` between them, so the block's first `##` is the
    #    marker, not the entry heading. Hand-fed so the test does not depend on which releases the
    #    live file happens to contain. ──────────────────────────────────────────────────────────
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
    #   A + B + E run against the REAL file and guard file↔parser AGREEMENT. They fail the moment
    #     an entry is written that the parser cannot see (B), that it can see but files under the
    #     wrong version (E), or that it silently merges into a neighbour (A). They are deliberately
    #     blind to a parser regression on their own: with every entry carrying both of the old
    #     markers, the pre-#438 parser also passes them. That is not a gap, it is their scope.
    #   C + D pin the parser CONTRACT on hand-fed text — reverting `_parse_upgrading` to the
    #     `---`/`Recorded` gate fails them immediately.
    #   The `_trim_trailing_structure` testset pins the tail trimmer directly, on shapes the real
    #     file does not contain and the file-level guards therefore cannot reach.
    #
    # Every one of them was mutation-tested before landing — each fails under a change that
    # reintroduces the defect it describes. Together they are the only thing standing between a
    # written entry and a consumer never being told to port it.

    # ── A: every declared entry is a parsed entry ──────────────────────────────
    @testset "every `- **Version**:` bullet parses as its own entry (#438)" begin
        path = joinpath(pkgdir(PormG), "UPGRADING.md")
        raw  = read(path, String)

        # Same two normalizations the parser does, so the count is over the same text.
        text = replace(raw, "\r\n" => "\n", "\r" => "\n")
        tmpl = findfirst("## Template for new entries", text)
        tmpl === nothing || (text = text[1:prevind(text, first(tmpl))])

        declared = length(collect(eachmatch(r"(?m)^-[ \t]+\*\*Version\*\*:", text)))
        parsed   = PormG._parse_upgrading(raw)
        stamped  = count(e -> e.version != PormG._UNSTAMPED_VERSION, parsed)

        @test declared > 0                # the file always has stamped entries

        # Name the offending heading on failure — a bare count mismatch sends the maintainer
        # hunting through 3700 lines for which entry the parser could not see.
        #
        # Re-segment to do it: `declared - stamped` is by definition "headings whose OWN segment
        # declares a `- **Version**:` but produced no entry", so the segment must be re-derived to
        # single one out. Listing every unparsed heading instead would bury the culprit among the
        # four that never parse by design — and the likeliest culprit is a marker-shaped title,
        # which would sit camouflaged among the three real release markers.
        if stamped != declared
            seen  = Set(e.title for e in parsed)
            heads = collect(eachmatch(r"(?m)^##[ \t]+(.+?)[ \t]*$", text))
            culprits = String[]
            for (i, h) in enumerate(heads)
                h[1] in seen && continue
                stop = i < length(heads) ? prevind(text, heads[i + 1].offset) : lastindex(text)
                occursin(r"(?m)^-[ \t]+\*\*Version\*\*:", text[h.offset:stop]) &&
                    push!(culprits, String(h[1]))
            end
            @info "declared an entry but did not parse as one" culprits
        end
        @test stamped == declared         # …and every declared entry came back as an entry

        # `---` rules and the `<!-- pre-0.2 history -->` divider are file structure, never content.
        # NOT `!endswith(body, "---")`: the divider sits below its rule, so a real leak ends in
        # `-->` and slips straight past a tail check. That weaker assertion shipped in the first
        # cut of this testset and passed while `#197`'s body carried both (found in review).
        @test all(e -> !occursin(r"(?m)^---[ \t]*$", e.body), parsed)
        @test all(e -> !occursin("pre-0.2 history", e.body), parsed)
    end

    # ── B: no entry heading is silently dropped ────────────────────────────────
    # Structural, not a whitelist: everything above the first release marker is prose (the file
    # header and these very rules), everything below it is entries. So each non-marker heading
    # from the first marker on must come back as exactly one parsed title.
    #
    # This also guards the one hazard heading-based segmentation introduces — a stray `## ` inside
    # an entry body would split that entry, and the orphaned half would show up here as an
    # unparsed heading instead of silently truncating the entry.
    @testset "no entry heading is silently dropped (#438)" begin
        path = joinpath(pkgdir(PormG), "UPGRADING.md")
        raw  = read(path, String)

        text = replace(raw, "\r\n" => "\n", "\r" => "\n")
        tmpl = findfirst("## Template for new entries", text)
        tmpl === nothing || (text = text[1:prevind(text, first(tmpl))])

        heads = [String(m[1]) for m in eachmatch(r"(?m)^##[ \t]+(.+?)[ \t]*$", text)]
        marker_at = findfirst(h -> occursin(PormG._RELEASE_MARKER, h), heads)
        @test marker_at !== nothing

        expected = filter(h -> !occursin(PormG._RELEASE_MARKER, h), heads[marker_at:end])
        titles   = [e.title for e in PormG._parse_upgrading(raw)]

        # Named so a failure prints WHICH heading vanished, not just a count mismatch.
        unparsed = setdiff(expected, titles)
        unexpected = setdiff(titles, expected)
        @test unparsed == String[]
        @test unexpected == String[]
        @test length(titles) == length(expected)   # no heading parsed twice
    end

    # ── E: only genuine pre-0.2 history may omit `- **Version**:` ──────────────
    # The parser accepts `- **Recorded**:` alone as an entry marker, because the pre-0.2 history
    # predates the `- **Version**:` policy and has no such bullet. That leniency has a sharp edge:
    # a NEW entry carrying `Recorded` but not `Version` — an easy slip, the two are adjacent in
    # the template — parses at `_UNSTAMPED_VERSION`, sorts below 0.2.0, and is invisible to every
    # consumer on ≥ 0.2.0. That is #438's own failure mode in a new place, and A and B both pass
    # through it: A counts only declared bullets, B only asks that the heading parsed at all.
    #
    # So pin the population instead — unstamped entries are exactly the ones below the divider,
    # and that set is closed. It never grows again.
    @testset "only pre-0.2 history entries may omit `- **Version**:` (#438)" begin
        path = joinpath(pkgdir(PormG), "UPGRADING.md")
        raw  = read(path, String)

        text = replace(raw, "\r\n" => "\n", "\r" => "\n")
        tmpl = findfirst("## Template for new entries", text)
        tmpl === nothing || (text = text[1:prevind(text, first(tmpl))])

        # Match the divider COMMENT, not the bare phrase — "Writing an entry" names the marker in
        # prose hundreds of lines above it, and `findfirst` on the phrase lands there instead.
        divider = match(r"<!--[^\n]*pre-0\.2 history[^\n]*-->", text)
        @test divider !== nothing        # the marker `UPGRADING.md`'s own rules point at
        # Bail rather than let `divider.offset` throw a `FieldError` over the real diagnosis:
        # every assertion below is about where the divider IS, so a missing one has one cause.
        divider === nothing && return

        below = count(m -> m.offset > divider.offset && !occursin(PormG._RELEASE_MARKER, m[1]),
                      eachmatch(r"(?m)^##[ \t]+(.+?)[ \t]*$", text))
        unstamped = count(e -> e.version == PormG._UNSTAMPED_VERSION,
                          PormG._parse_upgrading(raw))

        @test below > 0
        @test unstamped == below
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
