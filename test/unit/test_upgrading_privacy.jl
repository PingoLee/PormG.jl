# ==============================================================================
# UNIT TESTS: upgrade-log entries carry no consuming-app details (#1089)
#
# `UPGRADING.md` → *No consuming-app details*: an entry's *Who this affects* names the affected call
# pattern and how to find it. It never reports how many calls the maintainer's private apps make,
# how many apps there are, or anything taken from them, and no entry carries an agent-session link.
# The rule was written down and still did not hold on its own: a measured-count sentence survived a
# PR that edited the very entry it sat in. This file makes the rule a check.
#
# Scope: entries still marked `- **Version**: Unreleased`. Released entries are history; cleaning
# them is #1089's own work, so this file never fails on a train that has already shipped.
#
# It matches PHRASING, never identifiers: the list of private names lives outside this repository,
# and putting it here would publish it.
#
# DB-free: it reads `upgrading/*.md` from the package tree.
#
#   julia --project=test/integration test/unit/test_upgrading_privacy.jl
# ==============================================================================
using Test
using PormG

# Each pattern is one way a measurement of the private apps has been written into an entry. They run
# over the entry with newlines turned into spaces (same length, so an offset still maps to a line),
# because a sentence routinely wraps across two lines.
const _UPP_PATTERNS = [
  r"\bconsuming[- ]apps?\b"i                         => "names the consuming apps",
  r"\b(?:internal|private|downstream) apps?\b"i      => "names the private apps",
  r"\b(?:one|two|three|four|five|no|both) apps?\b"i  => "counts apps",
  r"\bof the apps\b"i                                => "counts apps",
  r"\bmeasured\b[^.]*?\bcall sites?\b"i              => "reports a measured call-site count",
  r"\*\*\d+\*\*[^.]*?\bcall sites?\b"i               => "reports a call-site count",
  r"claude\.ai/code"i                                => "carries an agent-session link",
  r"\bClaude-Session:"i                              => "carries an agent-session link",
]

const _UPP_UNRELEASED = r"(?m)^-[ \t]+\*\*Version\*\*:[ \t]*Unreleased[ \t]*$"

# (line, reason, excerpt) for every pattern hit in `text`.
function _upp_findings(text::AbstractString)
  flat = replace(text, '\n' => ' ')
  hits = Tuple{Int,String,String}[]
  for (re, why) in _UPP_PATTERNS
    for m in eachmatch(re, flat)
      line = count(==('\n'), SubString(text, 1, prevind(text, m.offset))) + 1
      push!(hits, (line, why, String(m.match)))
    end
  end
  return sort!(hits)
end

# ─────────────────────────────────────────────────────────────────────────────
# Pattern self-test: what the patterns flag, and what they must leave alone.
# A pattern that flags the legitimate call-pattern phrasing every entry uses ("Apps that call …",
# "Measured on PostgreSQL 16.15") would make the whole check unusable, and one that misses the
# shapes found in real entries would make it decorative. Both directions are pinned here, so the
# real-tree testset below cannot pass vacuously.
# ─────────────────────────────────────────────────────────────────────────────
@testset "upgrading/ privacy patterns: flag measurements, keep call patterns" begin
  must_flag = [
    "Measured on 2026-10-05: **0** call sites in the consuming apps.",
    "Measured before the change: no consuming app catches `FilterError`.",
    "two of the internal apps depend on a package that caps it",
    "One app passes `sprint(showerror, error)` from its handlers.",
    "No app catches either type by name.",
    "Measured on 2026-10-08: **11** runtime `limit`/`offset`/`page` call sites.",
    "The work is in https://claude.ai/code/session_x",
  ]
  for s in must_flag
    @test !isempty(_upp_findings(s))
  end

  must_pass = [
    "Apps that call `on()` on a path the same query does not otherwise project.",
    "Code that concatenates a boolean, float or decimal value in SQL.",
    "Measured on PostgreSQL 16.15 and SQLite 3.45.1:",
    "The value is runtime input, so a grep cannot find every call site.",
    "Co-Authored-By: Claude Opus <noreply@anthropic.com>",
  ]
  for s in must_pass
    @test isempty(_upp_findings(s))
  end

  # A sentence wrapped across two lines is still one sentence, and the reported line is where the
  # match starts.
  wrapped = "Who this affects\n\nApps that write a key. Measured on 2026-10-06:\n**0** call sites in the consuming apps."
  hits = _upp_findings(wrapped)
  @test any(h -> h[2] == "reports a measured call-site count" && h[1] == 3, hits)
  @test any(h -> h[2] == "names the consuming apps" && h[1] == 4, hits)
end

# ─────────────────────────────────────────────────────────────────────────────
# Real tree: every Unreleased entry under upgrading/ is clean.
# A failure names file:line and the phrase, so the fix is to reword that sentence on its merits
# (the call pattern, and the grep that finds it), not to loosen a pattern.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Unreleased upgrade entries carry no consuming-app details (#1089)" begin
  dir = joinpath(pkgdir(PormG), "upgrading")
  files = filter(f -> endswith(f, ".md"), readdir(dir))
  versioned = 0
  for f in files
    text = read(joinpath(dir, f), String)
    occursin(r"(?m)^-[ \t]+\*\*Version\*\*:", text) && (versioned += 1)
    occursin(_UPP_UNRELEASED, text) || continue
    for (line, why, excerpt) in _upp_findings(text)
      @error "upgrading/$f:$line $why" excerpt
    end
    @test isempty(_upp_findings(text))
  end
  # Right after a release cut no entry is Unreleased, so an empty scope is legitimate. A renamed
  # `Version` bullet is not: it would make this file skip every entry and pass, so the bullet must
  # still be recognized somewhere in the log.
  @test versioned > 0
end
