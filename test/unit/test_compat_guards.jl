# ============================================================
# test/unit/test_compat_guards.jl
#
# `[compat]` ranges that are load-bearing for an environment PormG's own test runs never build:
# a DRIVER environment (#558) and a CONSUMING-APP environment (#560).
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
# Why a test at all — the shared mechanism, and why neither contract can be seen locally:
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
# the other half of that same commit, fails the `"1" in bounds` assertion.
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
  # construction site is an explicit `OrderedDict(...)` / `OrderedSet(...)`, identical on both
  # majors. README.md → Requirements states why, user-facing.
  @test "1" in bounds

  # The floor is what is asserted, deliberately NOT the literal "1, 2": a future widening to a
  # third major is legitimate and must not fail here. Shape check on the parser's return, same
  # reason as the Decimals testset — a section-blind read would hand back the `[deps]` UUID.
  @test occursin(r"^[0-9][0-9.,\s]*$", oc)
end
