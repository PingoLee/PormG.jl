# ==============================================================================
# UNIT TESTS: pormg-usage skill bundle — public-API coverage drift guard (#253)
#
# `.github/skills/pormg-usage/` is what `PormG.install_ai_skills()` copies into a consuming app, and
# it is how an AI assistant working there learns PormG. Whatever it omits, the assistant guesses,
# usually from Django intuition. #206 fixed the bundle once; #231 then shipped the PormGError
# taxonomy and the bundle drifted straight back to teaching `catch ArgumentError` — a catch block
# that silently stops firing. By #253 it covered 35 of 111 public names.
#
# This file makes the next drift a CI failure instead of a surprise:
#
#   1. every public name of `PormG` and `PormG.Functions` must appear in the bundle as a whole word,
#      OR sit on `OUT_OF_SCOPE` below with a stated reason — so adding a public name fails here until
#      it is taught or deliberately excluded;
#   2. every `OUT_OF_SCOPE` entry must still be a public name and must NOT also be taught, so the
#      exclusion list cannot rot into a second, silent allow-list;
#   3. every hosted-docs link in the bundle must name a page that exists under `docs/src/`.
#
# "Appears as a whole word" is a mention, not an explanation — a floor, not a proof of teaching. It
# is still the check that would have caught #231's drift: not one of the twelve error types appeared.
#
# Modelled on `test_public_exports.jl`, which freezes the export surface the same way. Runs WITHOUT
# a live database — it only reads markdown shipped with the package.
# ==============================================================================

using Test
using PormG

const USAGE_SKILL_DIR = joinpath(pkgdir(PormG), ".github", "skills", "pormg-usage")

# Public names the consumer bundle deliberately does not teach. Each needs a reason a reviewer can
# check; "not written yet" is not one — write it instead.
const OUT_OF_SCOPE = Dict{Symbol,String}(
    :register_ignore_tables! =>
        "framework-author extension hook (packages built on PormG, e.g. Nitro), not app code — " *
        "documented on the Extending PormG page",
)

# The concatenated text of every markdown file the installer ships.
function usage_skill_text()
    files = filter(f -> endswith(f, ".md") && isfile(joinpath(USAGE_SKILL_DIR, f)),
                   readdir(USAGE_SKILL_DIR))
    return join((read(joinpath(USAGE_SKILL_DIR, f), String) for f in files), "\n")
end

# Whole-word match: `Lag` must not pass by matching inside `flag`, nor `Rank` inside `DenseRank`.
# A name can start with `@` (macros) or end with `!`, which `\b` does not handle, hence the explicit
# look-arounds; the name itself is escaped because `!` and `@` are regex-significant in places.
taught(text::AbstractString, name::Symbol) =
    occursin(Regex("(?<![\\w@])" * escape_string_regex(string(name)) * "(?![\\w!])"), text)

escape_string_regex(s::AbstractString) = replace(s, r"([\\^$.|?*+()\[\]{}])" => s"\\\1")

# The two surfaces the bundle is responsible for. `names` covers exported AND `public` names on
# Julia ≥ 1.11, which is the right set: `install_ai_skills` and `setup` are public-but-unexported.
public_surface() = sort!(unique!(vcat(
    [n for n in names(PormG) if n !== :PormG],
    [n for n in names(PormG.Functions) if n !== :Functions],
)))

# ─────────────────────────────────────────────────────────────────────────────
# Usage skill: every public name is taught or explicitly excluded (#253)
# The core guard. A new export with no mention in the bundle fails here with its name in the
# report, so the fix is obvious: teach it in the right topic file, or add it to OUT_OF_SCOPE with
# a reason. The count assertion stops the loop from passing vacuously if `names` ever returned
# nothing (e.g. a module-loading change).
# ─────────────────────────────────────────────────────────────────────────────
@testset "pormg-usage teaches every public name, or excludes it on purpose (#253)" begin
    text    = usage_skill_text()
    surface = public_surface()
    @test length(surface) > 90                        # PormG + Functions: 111 names at #253

    untaught = [n for n in surface if !taught(text, n) && !haskey(OUT_OF_SCOPE, n)]
    isempty(untaught) || @info "Public names the pormg-usage bundle never mentions" untaught
    @test isempty(untaught)
end

# ─────────────────────────────────────────────────────────────────────────────
# Usage skill: the exclusion list cannot go stale (#253)
# An OUT_OF_SCOPE entry that is no longer public, or that the bundle now teaches anyway, is a
# leftover — and a leftover exclusion is exactly how a real gap would later hide. Both directions
# fail loudly.
# ─────────────────────────────────────────────────────────────────────────────
@testset "pormg-usage OUT_OF_SCOPE entries are real, untaught public names (#253)" begin
    text    = usage_skill_text()
    surface = Set(public_surface())
    for (name, reason) in OUT_OF_SCOPE
        @test name in surface                         # still public — else delete the entry
        @test !taught(text, name)                     # not taught — else delete the entry
        @test length(reason) > 20                     # a reason, not a placeholder
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Usage skill: the whole-word matcher means what it says (#253)
# Guards the guard. A substring match would count `Lag` as taught by the word "flag", and `Rank` by
# `DenseRank`, which is how #253's own first measurement overstated coverage.
# ─────────────────────────────────────────────────────────────────────────────
@testset "pormg-usage coverage uses whole-word matching (#253)" begin
    @test  taught("x = Lag(\"ms\")", :Lag)
    @test !taught("set the flag", :Lag)
    @test !taught("DenseRank(over = w)", :Rank)
    @test  taught("PormG.@import_models \"db/models.jl\"", Symbol("@import_models"))
    @test !taught("register_ignore_tables!(x)", :register_ignore_tables)   # `!` is part of a name
    @test  taught("call register_ignore_tables!(x)", :register_ignore_tables!)
end

# ─────────────────────────────────────────────────────────────────────────────
# Usage skill: every hosted-docs link names a page that exists (#253)
# The bundle is operational and links to the hosted docs for depth. A link to a page that was
# renamed or never existed would send the assistant to a 404 for exactly the detail it went looking
# for. `https://pingolee.github.io/PormG.jl/stable/<path>/` must map to `docs/src/<path>.md` or
# `docs/src/<path>/index.md` (the root to `index.md`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "pormg-usage links only to docs pages that exist (#253)" begin
    text     = usage_skill_text()
    docs_src = joinpath(pkgdir(PormG), "docs", "src")
    links    = unique([m.captures[1] for m in
                       eachmatch(r"https://pingolee\.github\.io/PormG\.jl/stable/([A-Za-z0-9_/]*)", text)])
    @test length(links) > 5                           # the loop below actually ran

    for link in links
        path = strip(link, '/')
        page = isempty(path) ? joinpath(docs_src, "index.md") : joinpath(docs_src, path * ".md")
        ok   = isfile(page) || isfile(joinpath(docs_src, path, "index.md"))
        ok || @info "pormg-usage links to a docs page that does not exist" link
        @test ok
    end
end
