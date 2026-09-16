# ============================================================
# test/unit/test_compat_guards.jl
#
# Dependency-resolution contracts that are load-bearing for an environment PormG's own test runs
# never build: a DRIVER environment (#558), a CONSUMING-APP environment (#560), and a
# CompatHelper PR's environment (#599). The first two are about the declared `[compat]` ranges;
# the third is about which END of one CI selects.
#
# CONTRACT 1 — `Decimals` keeps `LibPQ` installable (#558):
#   PormG's declared `[compat]` must leave `LibPQ` — the only PostgreSQL driver — with an
#   installable version. Every `LibPQ` release from 1.1 through the current 1.18.0 pins
#   `Decimals 0.4` (General registry, `L/LibPQ/Compat.toml`, range `["1.1-1"]`), so a
#   `Decimals` range that excludes 0.4 leaves LibPQ with no versions left and *any* app
#   carrying the driver fails to resolve — `test/integration` included.
#
# CONTRACT 2 — `OrderedCollections` keeps the *consuming apps* resolvable (#560):
#   PormG's declared `[compat]` must not exclude `OrderedCollections 1`. PormG itself uses only
#   `OrderedDict` / `OrderedSet` construction, which behaves identically on both majors, so keeping
#   1 costs nothing — but dropping it costs the apps. Measured by resolving a scratch environment
#   carrying each internal app's dependency set plus PormG: under `OrderedCollections = "2"`,
#   2 of the 5 apps are unresolvable, and the resolver names PormG as the cause —
#     * `bi_server_nitro` pins `XLSX = "0.11.3"`, and XLSX accepts OC 2 only from `0.12`
#     * `bi_server` pins `Genie = "5.35.5"`, and Genie accepts OC 2 only from `6`
#   — while `"1, 2"` resolves all 5 (those two land on OC 1.8.2). #549 kept `"1, 2"` on purpose
#   after fixing 53 fixture sites to construct `OrderedDict` explicitly; the narrowing came from
#   the same blanket chore commit that broke `Decimals`, not from any need of PormG's.
#
#   #574 found that EXPLICIT IS NOT ENOUGH — the element type has to be spelled too, and the gap
#   is across MINORS rather than majors. `OrderedDict(k => v for …)` is perfectly explicit and
#   still infers `{Any, Any}` below OC 1.3; it only infers `{String, String}` from 1.3 on. At the
#   floor, `src/migrations/planner.jl` handed such a map to a parameter typed
#   `::AbstractDict{String, String}` and every migration-planner call was a MethodError. Fixed in
#   PormG rather than in the bound, because this floor is the load-bearing kind.
#
#   So the rule is: `OrderedDict{K, V}(...)` / `OrderedSet{T}(...)` at every new site. (Bare
#   `OrderedSet(keys(d))` is already safe — `keys` of a typed dict has a concrete eltype — but
#   spelling it costs nothing and removes the judgement call.)
#
# CONTRACT 3 — CI must not force the CEILING of a spanning range (#599):
#   `julia-actions/julia-runtest`'s `force_latest_compatible_version` defaults to `auto`, i.e.
#   TRUE on a Dependabot/CompatHelper PR, where it pins every direct dependency to the newest
#   version its range allows. For `Decimals = "0.4, 0.5"` that is 0.5.x — the end CONTRACT 1 says
#   no LibPQ release accepts — so every CompatHelper PR arrives with all four `test` jobs dead in
#   `Pkg.resolve`. Same symptom as #558, opposite cause: there the range was wrong, here the range
#   is right and CI picks the wrong end of it, so neither testset above can see it and a re-run
#   never clears it. Guarded as a text scan of `.github/workflows/CI.yml`, at the bottom of this
#   file.
#
# Why a test at all — the shared mechanism, and why none of the three can be seen locally:
#   `Manifest.toml` is gitignored, so an already-resolved environment keeps the old version of
#   either package indefinitely and stays green. CI caught #558 only *after* the narrowing reached
#   `main`, at the cost of all four test jobs; nothing at all would have caught #560, because the
#   environment that breaks belongs to a different repository. This moves both failures to the
#   narrow end of the verify rungs, where each is one line to read.
#
# Why a text assertion and not a real `Pkg.resolve`:
#   A resolve costs minutes and needs the network, and neither failure is the solver's — both are
#   the declared range. The measured resolves belong in the PR that changes the range; this file is
#   the cheap regression guard that fires on the next narrowing.
#
# Mutation gates: restoring `Decimals = "0.5"` in Project.toml — the #558 regression, commit
# 8f91cf37 — fails the `"0.4" in bounds` assertion below; restoring `OrderedCollections = "2"`,
# the other half of that same commit, fails the `"1" in bounds` assertion; deleting the `with:`
# block under the `test` job's `julia-runtest` step in `.github/workflows/CI.yml`, or flipping it
# back to `true`/`auto`, fails the CONTRACT 3 testset.
#
# The other half, and how to read the two together (#574):
#   `.github/workflows/CI.yml` -> the `floor-resolve` job now resolves each non-stdlib `[compat]`
#   range at its MINIMUM allowed version (`julia-downgrade-compat`) and runs this suite there,
#   with LibPQ and SQLite installed. (Stdlibs have no minimum to resolve — their version is the
#   Julia version.) That job is the direction this file cannot check: whether the declared floor
#   still WORKS. This file checks the opposite direction — whether the floor is still DECLARED.
#
#   They meet when the floor job goes red, and there the reading matters, because the two
#   possible fixes are opposites:
#     * The usual case — PormG needs something the old version lacks. Raise the lower bound.
#     * The case THIS FILE encodes — the floor is load-bearing (Decimals 0.4 for LibPQ,
#       OrderedCollections 1 for the consuming apps). Raising it is exactly the wrong edit, and
#       the red run is telling you to fix PormG instead. Read this file before moving a bound.
#
#   Neither half subsumes the third check: #560's break lived in a CONSUMING APP's environment,
#   which no PormG-side resolve can observe. `general.instructions.md` -> the two-scratch-env
#   recipe still stands.
#
# Deterministic, DB-free, no network.
# ============================================================

using Test
using PormG

const _COMPAT_PROJECT_TOML = joinpath(pkgdir(PormG), "Project.toml")

# Read one `[compat]` entry without a TOML dependency: the `test` target does not carry the
# TOML stdlib, and the assertion is about the literal declared range anyway. Section-aware,
# because `[deps]` holds a `Decimals = "<uuid>"` line that a naive scan would match first.
function _compat_entry(name::AbstractString)
  in_compat = false
  for raw in eachline(_COMPAT_PROJECT_TOML)
    line = strip(raw)
    if startswith(line, "[")
      in_compat = (line == "[compat]")
      continue
    end
    in_compat || continue
    m = match(Regex("^\\Q$name\\E\\s*=\\s*\"([^\"]*)\"\\s*\$"), line)
    m === nothing || return String(m.captures[1])
  end
  return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Compat guards: the `Decimals` range must keep `LibPQ` installable (#558)
# Asserts the declared range still admits `0.4` — the only Decimals major any LibPQ release
# accepts. A narrowing here kills every CI job and every app carrying the PostgreSQL driver.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Decimals compat keeps LibPQ installable (#558)" begin
  decimals = _compat_entry("Decimals")
  @test decimals !== nothing

  # The parser has to be trustworthy before its verdict means anything: `[deps]` declares
  # `Decimals` too, and a section-blind read would return that UUID. It would still fail the
  # range check below — but for the wrong reason and with a baffling message — so pin the
  # shape first. Deliberately NOT asserted against a specific range: this testset is about
  # LibPQ's floor, and coupling it to the current declaration would fail on every legitimate
  # widening.
  @test occursin(r"^[0-9][0-9.,\s]*$", decimals)
  @test _compat_entry("PormGNotADependency") === nothing

  bounds = strip.(split(decimals, ","))
  # 0.4 is not a legacy range being carried for politeness — it is the ONLY Decimals major
  # any LibPQ release accepts. Dropping it is what made all four CI jobs die before a
  # testset ran. README.md → Requirements and general.instructions.md both state why.
  @test "0.4" in bounds

  # The premise this guard rests on: PormG still ships LibPQ as the PostgreSQL weakdep at
  # 1.x. If that ever moves to a major that pins a newer Decimals, revisit the range above
  # rather than deleting this testset.
  @test _compat_entry("LibPQ") == "1"
end

# ─────────────────────────────────────────────────────────────────────────────
# Compat guards: the `OrderedCollections` range must keep the consuming apps resolvable (#560)
# Asserts the declared range still admits `1`. Measured: `"2"` alone leaves 2 of the 5 internal
# apps unresolvable (XLSX below 0.12 and Genie below 6 both cap OC at 1), and PormG needs
# nothing from OC 2 — the break is invisible to every PormG-side environment.
# ─────────────────────────────────────────────────────────────────────────────
@testset "OrderedCollections compat keeps the consuming apps resolvable (#560)" begin
  oc = _compat_entry("OrderedCollections")
  @test oc !== nothing

  bounds = strip.(split(oc, ","))
  # 1 is not a legacy major carried for politeness. Two of the five internal apps have an
  # upstream that caps OrderedCollections at 1 — XLSX below 0.12, Genie below 6 — and PormG
  # requiring 2 makes them unresolvable outright. PormG gains nothing from the exclusion: every
  # construction site is an explicit `OrderedDict(...)` / `OrderedSet(...)` with the ELEMENT TYPE
  # SPELLED OUT, identical on both majors. Explicit alone is not enough — see the #574 paragraph
  # in the header: `OrderedDict(gen)` is explicit and still infers `{Any, Any}` below OC 1.3.
  # README.md → Requirements states why, user-facing.
  @test "1" in bounds

  # The floor is what is asserted, deliberately NOT the literal "1, 2": a future widening to a
  # third major is legitimate and must not fail here. Shape check on the parser's return, same
  # reason as the Decimals testset — a section-blind read would hand back the `[deps]` UUID.
  @test occursin(r"^[0-9][0-9.,\s]*$", oc)
end

# ─────────────────────────────────────────────────────────────────────────────
# Compat guards: floors that CI's `floor-resolve` job measured and PormG cannot go below (#574)
# These are the OPPOSITE case from the two above. There the floor is load-bearing for someone
# else's environment and must not RISE; here PormG is simply broken below the bound, and the
# bound must not FALL. Both directions are cheap to assert and neither is visible locally,
# because `Manifest.toml` is gitignored and an already-resolved env never moves.
#
# Each bound below was measured version by version on Julia 1.12, not inferred:
#   CSV    0.10.0-0.10.12 fail their own module `__init__` (`getsource` typeassert,
#          CSV/src/utils.jl); 0.10.13 is the lowest that loads. PormG did not precompile at
#          all at the old `"0.10"` floor — no testset ran.
#   SQLite Two separate breaks, so the bound is the higher of the two. 1.0.0-1.4.2 have no
#          `SQLite.Stmt(db, sql; register = …)` method, which `ext/PormGSQLiteExt.jl` needs (it
#          keeps bulk seeding from accumulating registered statements) — 1.5.0 fixes that. But
#          1.5.0-1.6.0 then re-`@eval` the C wrapper when the SAME Julia function is registered
#          on a second connection, and `_create_sqlite_connection` registers `pormg_lower` PER
#          CONNECTION, so a pool emits `WARNING: Method definition pormg_lower(...) overwritten
#          on the same line` from the second slot on — which fails the `@test_nowarn` in
#          `test_sqlite_memory_pool.jl`. 1.6.1 is the lowest clean on both counts.
#
#          That warning is only visible under `--warn-overwrite=yes`, which `Pkg.test` sets and a
#          bare `julia test/runtests.jl` does not — so it was invisible to a local rehearsal and
#          surfaced only once CI ran `julia-runtest` (run 35018968976). Rehearse through
#          `Pkg.test`, not by invoking the suite directly.
#   Consuming-app blast radius, measured before raising these (#574, the env-#2 half of the rule in
#   general.instructions.md): `TimeZones` is the only one of the four that is a hard `[deps]` entry,
#   so it is the only one an app resolves at all — `Aqua` is a test-only extra, and the `CSV`/
#   `SQLite` floors are old. Resolving a scratch env carrying each #560 capping pin plus PormG:
#   `XLSX 0.11.3`, `Genie 5.35.5`, and both together all resolve, landing on TimeZones 1.22.2 —
#   ten minors above the new floor, because neither cap touches TimeZones. 3 of 3, no app affected.
#   (Same run re-confirms CONTRACT 2: the capped envs land on OC 1.8.2, an uncapped one on 2.0.1.)
#
#   TimeZones PormG's DateTimeField conversions need named zones, and the floor failed in two
#          different ways. 1.0.0-1.10.0 cannot resolve one at all without an explicit
#          `TimeZones.build()` ("Unable to find time zone \"America/Sao_Paulo\""). 1.11.0 can,
#          but only via a `deps/build.jl` step that cannot bootstrap on Julia 1.12: build.jl's
#          first line is `using TimeZones`, whose `__init__` demands the very cache the build is
#          supposed to write, so `Pkg.build` itself dies with "Cache remains empty after
#          loading". 1.12.0 is the lowest with no build step at all — it gets tzdata from the
#          `TZJData` artifact (registry `T/TimeZones/Deps.toml`, `["1.12 - 1"]`), which is why
#          that, and not 1.11, is the floor.
#   Aqua   0.8.0-0.8.13 cannot introspect on Julia 1.12 — piracy detection reads
#          `Core.TypeName.mt`, which 1.12 removed, and ambiguity detection reports false
#          positives; 0.8.14 is the lowest that works.
#
# Asserted as ">= the measured floor" rather than as the literal string, so a legitimate
# later raise or a widening to a new major still passes. Mutation gate: restoring any of the
# four to its old range (`"0.10"`, `"1"`, `"1"`, `"0.8"`) fails the matching assertion here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Measured floors that PormG cannot go below (#574)" begin
  # Lower bound of a range's FIRST comma-separated arm, as a VersionNumber. `"0.10.13"` and
  # `"0.10.13, 1"` both give v"0.10.13"; a bare major `"1"` gives v"1.0.0".
  function _compat_floor(name::AbstractString)
    entry = _compat_entry(name)
    entry === nothing && return nothing
    first_arm = strip(first(split(entry, ",")))
    parts = split(first_arm, ".")
    while length(parts) < 3
      push!(parts, "0")
    end
    return VersionNumber(join(parts[1:3], "."))
  end

  # Pin the helper before trusting its verdicts, same reason as the testsets above.
  @test _compat_floor("PormGNotADependency") === nothing

  # `entry !== nothing` and the shape check come FIRST for each name, so a deleted or
  # oddly-spelled bound fails as itself rather than as a downstream `MethodError` on
  # `nothing >= v"..."` or an `ArgumentError` out of `VersionNumber`. The shape regex is the
  # same one the two testsets above use: it admits `"1.5"` and `"0.4, 0.5"` and rejects the
  # prefixed and hyphenated forms (`"^1.2"`, `"0.10 - 0.11"`) that `_compat_floor` cannot parse.
  # PormG uses none of those today and CompatHelper writes bare forms, so this is a latent guard.
  for (name, floor) in (
    ("CSV", v"0.10.13"),
    ("SQLite", v"1.6.1"),
    ("TimeZones", v"1.12.0"),
    ("Aqua", v"0.8.14"),
  )
    entry = _compat_entry(name)
    @test entry !== nothing
    @test entry !== nothing && occursin(r"^[0-9][0-9.,\s]*$", entry)
    @test _compat_floor(name) >= floor
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The OrderedCollections element-type rule, enforced rather than merely stated (#574)
# Modelled on `test_memo_interface.jl`: a text scan of `src/`/`ext/`, because the defect this
# catches is INVISIBLE to every other test. Reverting `planner.jl`'s `OrderedDict{String, String}`
# back to `OrderedDict` fails nothing in the unit suite — every local and CI environment resolves
# OrderedCollections >= 1.3, where inference happens to produce the concrete type. Only the
# floor-resolve job sees it, minutes later and on a job that can be red for unrelated reasons.
# #549 already showed that a convention nothing enforces does not hold.
#
# Scope: only the forms where inference is actually load-bearing — a generator (`for`) or an
# explicit pair (`=>`). `OrderedSet(keys(d))` is deliberately NOT flagged: `keys` of a typed dict
# already has a concrete eltype, and there are two such sites in `planner.jl` today.
# ─────────────────────────────────────────────────────────────────────────────
@testset "OrderedDict/OrderedSet sites spell the element type (#574)" begin
  roots = [joinpath(pkgdir(PormG), d) for d in ("src", "ext")]
  offenders = String[]

  for root in roots
    isdir(root) || continue
    for (dir, _, files) in walkdir(root), file in files
      endswith(file, ".jl") || continue
      path = joinpath(dir, file)
      for (lineno, line) in enumerate(eachline(path))
        code = first(split(line, '#'))            # ignore trailing comments
        startswith(strip(line), "#") && continue  # ...and comment-only lines
        # Bare constructor: `OrderedDict(` / `OrderedSet(` with no `{...}` before the paren.
        occursin(r"Ordered(Dict|Set)\(", code) || continue
        # ...carrying a generator or a pair, i.e. where the element type comes from inference.
        (occursin(r"\bfor\b", code) || occursin("=>", code)) || continue
        push!(offenders, "$(relpath(path, pkgdir(PormG))):$(lineno)")
      end
    end
  end

  # Mutation gate: reverting planner.jl:732 to `OrderedDict(... => ... for ...)` lists it here.
  @test isempty(offenders)
  isempty(offenders) || @info "Bare OrderedDict/OrderedSet sites" offenders
end

# ─────────────────────────────────────────────────────────────────────────────
# CI must not force every dependency to the TOP of its `[compat]` range (#599)
# The third member of this file's family, and the one that is not about a range at all — it is
# about which END of a range CI selects.
#
# `julia-actions/julia-runtest`'s `force_latest_compatible_version` defaults to `auto`, which
# means "true when the PR was opened by Dependabot or CompatHelper". True pins every direct
# dependency to the newest version its `[compat]` range allows — including `Decimals` to 0.5.x,
# which no registered `LibPQ` release accepts (CONTRACT 1 above: they all pin `Decimals 0.4`).
# So the test environment cannot resolve and all four `test` jobs die in `Pkg.resolve`, before a
# single testset runs. Measured on this machine: `LibPQ` + PormG with no pin resolves clean at
# Decimals 0.4.1 / LibPQ 1.18.0; adding `Decimals@0.5.1` leaves LibPQ with no versions left.
#
# This is the same SYMPTOM as #558 with a different CAUSE, which is what makes it worth a guard.
# There the range had been wrongly narrowed to `"0.5"` and the two testsets above catch it. Here
# the range is exactly right and CI selects the end LibPQ forbids — invisible to both of them,
# and self-inflicted rather than upstream, so it never clears on a re-run.
#
# Why a text scan of the workflow, in THIS file: identical reasoning to the two contracts above.
# The failure lives in an environment no local run builds — it needs a CompatHelper PR to exist —
# so nothing else can observe it, and by the time it is observable it has already cost the whole
# matrix. Asserting the declaration is the cheap half; `#593` was the expensive half.
#
# The `floor-resolve` job is asserted too, for the MIRROR-IMAGE reason (#574): there force-latest
# on a CompatHelper PR would silently resolve the ceiling and report a floor job green. Both ends
# of the same input, and neither is a preference.
#
# Mutation gates: deleting the `with:` block under the `test` job's `julia-runtest` step fails the
# first assertion; deleting `floor-resolve`'s fails the second. Flipping either to `true` fails it
# too — the scan matches the value, not merely the key.
#
# Deterministic, DB-free, no network.
# ─────────────────────────────────────────────────────────────────────────────
@testset "CI does not force the ceiling of a spanning [compat] range (#599)" begin
  ci_workflow = joinpath(pkgdir(PormG), ".github", "workflows", "CI.yml")
  @test isfile(ci_workflow)

  # A DECLARATION of this input set to `false`, judged on code only: trailing comments are
  # stripped and comment-only lines dropped. That is not cosmetic — BOTH jobs that carry this
  # input also spell its name in prose ("* force_latest_compatible_version — its `auto` default
  # means …"), so a scan that cannot tell a declaration from a sentence about one would pass on
  # a workflow that declares nothing at all.
  declares_false(lines) = any(lines) do line
    startswith(strip(line), "#") && return false
    occursin(r"^\s*force_latest_compatible_version:\s*false\s*$", first(split(line, '#')))
  end

  # The lines belonging to one top-level job: from `  <name>:` (exactly two spaces) up to the
  # next key at that indent. Section-aware on purpose — both `test` and `floor-resolve` declare
  # this input, so a flat file scan cannot say which job it found, and #599 is specifically
  # about the `test` job.
  function job_lines(job::AbstractString)
    lines = readlines(ci_workflow)
    start = findfirst(l -> l == "  $(job):", lines)
    start === nothing && return nothing
    stop = findfirst(l -> occursin(r"^  \S", l), lines[(start + 1):end])
    return lines[(start + 1):(stop === nothing ? length(lines) : start + stop - 1)]
  end

  # ── Pin both helpers before trusting a verdict, same discipline as `_compat_entry` above ──
  # A mis-spelled job name must fail as itself, never as a silent `false` that reads like a
  # finding about the workflow.
  @test job_lines("test") !== nothing
  @test job_lines("floor-resolve") !== nothing
  @test job_lines("PormGNotAJob") === nothing

  # The sectioning is real, checked on content UNIQUE to each job rather than on the job names —
  # the comment this PR added inside `test` legitimately mentions `floor-resolve` by name, so a
  # name scan would fail on correct code. `steps:` appears in both, so it only proves a block was
  # captured at all; the two `uses`/matrix keys prove the blocks do not overlap.
  @test any(l -> strip(l) == "steps:", job_lines("test"))
  # `matrix:` and the `julia-downgrade-compat` step are structural, not cosmetic: `test` is a
  # matrix job and `floor-resolve` is a single-Julia job that downgrades. Chosen over the literal
  # `os:` list so that adding a platform to the matrix does not fail this guard for an unrelated
  # reason.
  @test any(l -> strip(l) == "matrix:", job_lines("test"))
  @test !any(l -> occursin("julia-downgrade-compat", l), job_lines("test"))
  @test any(l -> occursin("julia-downgrade-compat", l), job_lines("floor-resolve"))
  @test !any(l -> strip(l) == "matrix:", job_lines("floor-resolve"))

  # The comment stripping is real, checked against synthetic lines rather than against a job
  # that happens to declare the right thing anyway. Without the strip, the first two of these
  # would each satisfy `declares_false` and every assertion below would be theater.
  @test !declares_false(["          # force_latest_compatible_version: false"])
  @test !declares_false(["          allow_reresolve: false  # force_latest_compatible_version: false"])
  @test !declares_false(["          force_latest_compatible_version: true"])
  @test !declares_false(["          force_latest_compatible_version: auto"])
  @test declares_false(["          force_latest_compatible_version: false"])
  @test declares_false(["          force_latest_compatible_version: false   # OFF DELIBERATELY"])

  # ── The guard itself ──
  # `test` is the job #599 is about: left at the `auto` default, a CompatHelper PR pins Decimals
  # to 0.5.x and no LibPQ release allows it, so all four jobs die before a testset runs.
  @test declares_false(job_lines("test"))
  # `floor-resolve` has carried it since #574, for the mirror-image reason: force-latest there
  # would resolve the CEILING and report a floor job green.
  @test declares_false(job_lines("floor-resolve"))
end
