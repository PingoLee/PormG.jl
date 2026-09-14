# ============================================================
# test/unit/test_compat_guards.jl
#
# `[compat]` ranges that are load-bearing for a DRIVER environment (#558).
#
# CONTRACT being tested:
#   PormG's declared `[compat]` must leave `LibPQ` — the only PostgreSQL driver — with an
#   installable version. Every `LibPQ` release from 1.1 through the current 1.18.0 pins
#   `Decimals 0.4` (General registry, `L/LibPQ/Compat.toml`, range `["1.1-1"]`), so a
#   `Decimals` range that excludes 0.4 leaves LibPQ with no versions left and *any* app
#   carrying the driver fails to resolve — `test/integration` included.
#
# Why a text assertion and not a real `Pkg.resolve`:
#   A resolve costs minutes and needs the network, and the point of failure is the declared
#   range, not the solver. Reading the range costs microseconds and fails in exactly the
#   place a narrowing happens.
#
# Why a test at all, when CI already caught it once:
#   It caught it *after* the narrowing reached `main`, and it cost all four test jobs to say
#   so. The break is invisible to every local environment: `Manifest.toml` is gitignored, so
#   an already-resolved checkout keeps `Decimals 0.4` indefinitely and stays green. This
#   moves the failure to the narrow end of the verify rungs, where it is one line to read.
#
# Mutation gate: restoring `Decimals = "0.5"` in Project.toml — the #558 regression, commit
# 8f91cf37 — fails the `"0.4" in bounds` assertion below.
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
