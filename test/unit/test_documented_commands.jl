# ============================================================
# test/unit/test_documented_commands.jl
#
# A prescribed command that cannot run is worse than no command: it costs a developer (or an
# agent) a failed run and an improvised substitute, and it reads as authoritative the whole
# time. This file guards the one spelling that has already done that (#624).
#
# THE CONTRACT — handing a `test/unit/…` (or any non-integration) script to `--project=.` is
# never runnable.
#
# Since #34 LibPQ and SQLite are `[weakdeps]`, so the package environment cannot `using` them,
# and `Pkg.instantiate()` resolves `[deps]` alone — there is nothing for `test/load_drivers.jl`'s
# `Base.require`-by-UUID rescue to find either. Measured in the #624 worktree: a single
# `Pkg.resolve()`, reporting only two unrelated JLL patch bumps, removed both driver entries
# from `Manifest.toml`, after which the documented command died with
# `ArgumentError: Package LibPQ … is required but does not seem to be installed`.
#
# WHY IT SURVIVED LONG ENOUGH TO BE DOCUMENTED IN A DOZEN PLACES. A `Manifest.toml` resolved
# before #34 still lists both drivers, and `Pkg.instantiate()` only WARNS about a stale
# manifest instead of re-resolving it. So the broken command keeps working in any checkout old
# enough to have one — until a `Pkg.resolve()` / `Pkg.update()` / `Pkg.add()` / Julia upgrade
# drops them, at which point every copy of the command fails at once. `Manifest.toml` is
# gitignored, so `git status` never shows that coming and no CI job resolves the package env
# the way a developer does. (A third mirage exists: `LOAD_PATH` includes `@v#.#`, so a
# developer with LibPQ/SQLite in their shared default environment also sees it "work".)
#
# THE TWO SPELLINGS THAT DO WORK, and what each is for:
#   julia --project=. -e 'using Pkg; Pkg.test()'        full unit suite; what CI runs
#   julia --project=test/integration <test_file.jl>     one file — unit OR integration
#
# WHAT IS DELIBERATELY NOT FLAGGED — `--project=. test/integration/<file>.jl`. There it
# genuinely works, because `common_setup.jl` redirects the package env to the integration env
# before anything loads. `general.instructions.md` → *Verification* calls that a rescue for a
# wrong invocation rather than the spelling to teach, but it is not broken, so this guard does
# not police it. Note this is decided by the SCRIPT PATH, not by which file the line sits in —
# an earlier revision keyed it off the containing directory, which meant the header said one
# thing and the code did another.
#
# ESCAPE HATCH. Documentation sometimes has to quote the broken command exactly — to warn a
# reader off the spelling they have seen elsewhere, which is most of the point of fixing #624.
# A line carrying the marker `624-counterexample` is exempt. It is deliberately ugly and
# deliberately greppable, and `EXPECTED_COUNTEREXAMPLES` below pins where it may appear, so
# adding one is a deliberate test edit rather than a way to silence a red guard. It must not be
# used in `docs/src/**`: Documenter parses with the `Markdown` stdlib, which has no inline raw
# HTML, so an `<!-- … -->` marker RENDERS AS VISIBLE TEXT on the published page. That shipped
# once during this very change and was caught by reading `docs/build/contributing.html`, not by
# the build, which is perfectly happy to emit it. In user-facing docs, describe the broken
# command instead of quoting it.
# ============================================================

using Test
using PormG

@testset "Documented test commands are runnable (#624)" begin

    repo = pkgdir(PormG)

    # A `julia` invocation that hands a script path to a bare `--project=.`.
    #
    # Tolerated spellings of the flag: `--project=.`, `--project="."`, `--project .`, and the
    # `JULIA_PROJECT=.` env form. Tolerated path spellings: `test/…`, `test\…` (Windows
    # headers really do use backslashes — that is how #624's own sweep missed
    # test_field_validation_and_operations.jl) and a leading `./`.
    #
    # The `(?![^\n]*\s-eq?\b)` lookahead is what keeps a CORRECT command off the list: in
    # `julia --project=. -e 'using Pkg; Pkg.test()'  # replaces test/runtests.jl` the flag is
    # followed by `-e`, so the trailing mention is prose about a script, not an invocation of
    # one. Without it the lazy `[^\n]*?` walks straight past the `-e` payload.
    flag = raw"(?:--project[= ]\.(?![\w/\\.])|--project=\"\.\")"
    path = raw"(?<![\w\\-])(?<!/)(?:\./)?test[/\\][\w./\\-]+\.jl"
    noe  = raw"(?![^\n]*\s-e\b)"          # a `-e` after the flag means the path is prose
    # Two forms, because the env-var spelling puts the project BEFORE the executable.
    formA = "julia\\b[^\\n]*" * flag * noe * "[^\\n]*?" * path
    formB = "JULIA_PROJECT=\\.\\s[^\\n]*julia\\b" * noe * "[^\\n]*?" * path
    broken = Regex("(?:$formA)|(?:$formB)")

    # `--project=. test/integration/x.jl` is a rescue, not a defect — see the header.
    integration_script = r"(?:\./)?test[/\\]integration[/\\]"

    # A line that quotes the broken command in order to warn against it (see ESCAPE HATCH).
    exempt = "624-counterexample"

    # Where the escape hatch may appear, so a third use has to be added here on purpose.
    # NOT extendable into docs/src/** — the marker renders as visible text there.
    EXPECTED_COUNTEREXAMPLES = [joinpath(".github", "instructions", "general.instructions.md")]

    function flagged(line)
        occursin(broken, line)               || return false
        occursin(exempt, line)               && return false
        m = match(broken, line)
        occursin(integration_script, m.match) && return false
        return true
    end

    # Walk the repo rather than list folders: a hand-written target list is how #624's first
    # sweep missed src/precompile.jl and test/performance/snoop_compile.jl entirely.
    # NOTE the absence of a blanket `startswith(d, ".")` rule: it looks obviously right and it
    # silently excludes `.github`, i.e. every file this guard exists to police. The scan-reach
    # testset below is what caught that.
    SKIP_DIRS = Set([".git", ".claude", ".julia", ".vscode", "node_modules",
                     "build", "site",           # docs/build, docs/site — generated
                     "db_sl", "db_2", "snoop_out"])  # generated fixtures/migrations
    SCAN_EXT  = (".md", ".jl", ".sh", ".ps1", ".yml", ".yaml", ".toml")
    self      = joinpath(repo, "test", "unit", "test_documented_commands.jl")

    targets = String[]
    for (base, dirs, files) in walkdir(repo)
        filter!(d -> !(d in SKIP_DIRS), dirs)
        for f in files
            any(endswith(f, e) for e in SCAN_EXT) || continue
            p = joinpath(base, f)
            p == self && continue
            push!(targets, p)
        end
    end
    push!(targets, joinpath(repo, ".worktreeinclude"))   # extensionless, scanned explicitly
    filter!(isfile, targets)

    # The walk must actually reach the places commands live. Without this, a bad SKIP_DIRS
    # entry or a `startswith(d, ".")` rule that swallows `.github` leaves the scan green and
    # empty — the failure mode a hand-written list has by construction.
    @testset "the scan reaches the files that carry commands" begin
        rel = Set(relpath(p, repo) for p in targets)
        for must in (joinpath(".github", "instructions", "general.instructions.md"),
                     joinpath(".github", "skills", "pormg-issue-workflow", "SKILL.md"),
                     joinpath(".github", "workflows", "CI.yml"),
                     joinpath("docs", "src", "contributing.md"),
                     joinpath("scripts", "worktree_setup.sh"),
                     joinpath("src", "precompile.jl"),
                     joinpath("test", "runtests.jl"),
                     joinpath("test", "load_drivers.jl"),
                     joinpath("test", "performance", "snoop_compile.jl"),
                     joinpath("test", "unit", "test_field_validation_and_operations.jl"),
                     ".worktreeinclude")
            @test must in rel
        end
        @test length(targets) > 200            # the repo really is this big; a collapsed walk is not
    end

    hits = String[]
    counterexamples = String[]
    for path in targets
        for (i, line) in enumerate(eachline(path))
            rel = relpath(path, repo)
            occursin(exempt, line) && push!(counterexamples, rel)
            flagged(line) || continue
            push!(hits, "  $rel:$i\n      $(strip(line))")
        end
    end

    @test isempty(hits) || begin
        @error """
        A prescribed command hands a test script to `--project=.`, which cannot load the SQL
        driver extensions (#624). Use one of:
          full unit suite   julia --project=. -e 'using Pkg; Pkg.test()'
          one test file     julia --project=test/integration <path/to/test_file.jl>
        Offending lines:
        """ * "\n" * join(hits, "\n")
        false
    end

    @testset "the escape hatch stays where it was put" begin
        @test sort(unique(counterexamples)) == sort(EXPECTED_COUNTEREXAMPLES)
        # Never in rendered docs — the marker becomes visible text on the published page.
        @test !any(startswith(c, joinpath("docs", "src")) for c in counterexamples)
    end

    # The guard only means something if it can still see the shape it forbids. Without this,
    # a regex that silently stopped matching would leave every scanned file reading green.
    @testset "the matcher still recognises the broken shape" begin
        # Built from pieces so a repo-wide search-and-replace over the real commands cannot
        # silently "fix" these fixtures into passing — which is exactly what happened while
        # #624 was being written, and it would have left every positive assertion inverted.
        P = "--project=" * "."
        @test flagged("julia $P test/runtests.jl")
        @test flagged("| 3 | `julia $P test/runtests.jl` (full unit) |")
        @test flagged(raw"$env:PORMG_DB=" * "\"db_sl\"; julia $P test/runtests.jl")
        @test flagged("julia -t auto $P test/unit/test_x.jl")
        # The spellings that slipped past the first revision of this regex.
        @test flagged("# julia -t auto $P test" * "\\" * "unit" * "\\" * "test_x.jl")
        @test flagged("julia $P ./test/runtests.jl")
        @test flagged("julia " * "--project=\".\"" * " test/runtests.jl")
        @test flagged("julia " * "--project" * " " * "." * " test/runtests.jl")
        @test flagged("JULIA_PROJECT=" * ". julia test/runtests.jl")

        # ...and does not fire on the spellings that work.
        @test !flagged("julia --project=. -e 'using Pkg; Pkg.test()'")
        @test !flagged("julia --project=test/integration test/unit/test_x.jl")
        @test !flagged("julia -t 1 --project=test/integration test/integration/test_cte.jl")
        @test !flagged("julia --project=docs -e 'include(\"docs/make.jl\")'")
        # Correct command whose COMMENT names a test file — the `-e` lookahead case.
        @test !flagged("julia $P -e 'using Pkg; Pkg.test()'  # replaces test/runtests.jl")
        # The integration rescue, decided by the script path and not by the containing file.
        @test !flagged("julia -t auto $P test/integration/runtests.jl")
        @test !flagged("julia -t auto $P ./test/integration/test_cte.jl")

        # The escape hatch suppresses the report, and ONLY on the line carrying the marker.
        @test !flagged("julia $P test/runtests.jl  <!-- $exempt -->")
        @test flagged("julia $P test/runtests.jl")   # the previous call changed nothing
    end
end
