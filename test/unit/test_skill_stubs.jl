# ============================================================
# test/unit/test_skill_stubs.jl
#
# PormG's agent rulesets live in `.github/skills/`, deliberately: `AGENTS.md` -> *Tool notes*
# makes "one copy, readable by any agent" the whole point of that location, and the sibling
# `.github/instructions/` is what Copilot picks up via `applyTo: '**'`.
#
# Claude Code does not scan that tree. It registers a skill only when it finds
# `.claude/skills/<name>/SKILL.md`. So for as long as `.claude/skills/` did not exist,
# `Skill(pormg-board)` returned `Unknown skill` -- and the failure mode was not the error.
# It was what came next: the session carried on WITHOUT the ruleset it had just tried to load.
# For `pormg-board` that ruleset is a stop rule ("planning only, no implementation"), and for
# `pormg-issue-workflow` it is the verification tiers that buy the merge gate its autonomy.
# A skill that silently does not bind is strictly worse than one that loudly fails.
#
# THE FIX, AND WHY IT IS A STUB RATHER THAN A LINK. `.claude/skills/<name>/SKILL.md` is a
# discovery stub: real frontmatter so Claude Code registers the name, and a body that says
# nothing except "read the canonical file". Three alternatives were rejected:
#
#   * a git symlink (mode 120000) -- `core.symlinks` is false in this checkout, so it lands as
#     a text file containing a path, and on any Windows clone without Developer Mode it always
#     will. The stub is what a symlink would degrade into anyway, only legible.
#   * a Windows junction -- not representable in git at all, so it could not be pushed.
#   * copying the rulesets -- `general.instructions.md` forbids a second copy, and it is right:
#     the copy is what drifts.
#
# WHAT THIS GUARD PINS. The stub duplicates exactly one thing -- the YAML frontmatter, because
# discovery needs `name` and `description` in the file Claude Code actually reads. Duplication
# is the defect class this repo keeps hitting (#244-#246, #239), so the duplicated bytes are
# pinned byte-for-byte rather than trusted:
#
#   1. the two trees hold the SAME set of skill names -- a skill added to one and not the other
#      is either invisible to Claude Code or a stub pointing at nothing;
#   2. each stub's frontmatter block is byte-identical to its canonical file's;
#   3. each stub actually names its canonical path, so "read the real one" is checkable;
#   4. each stub stays under a SIZE CEILING. This is the load-bearing one and it is deliberately
#      quantitative, in the spirit of `test_repl_display.jl`: the way a stub fails is not by
#      being wrong, it is by slowly accreting "just one note" until it is a second, stale copy
#      of the ruleset. A byte count is the only check that catches that while it is still small.
#   5. each frontmatter is SAFE TO PARSE as plain YAML, in BOTH trees. Discovery fails silently:
#      an unquoted ": " makes the block unparseable and the skill is never registered at all, while
#      an unquoted " #" opens a comment and truncates the description mid-sentence. Three
#      descriptions shipped with one or the other, and nothing noticed -- until the stubs existed,
#      nothing in this repo parsed these files as skills.
# ============================================================

using Test

const REPO_ROOT    = normpath(joinpath(@__DIR__, "..", ".."))
const CANON_DIR    = joinpath(REPO_ROOT, ".github", "skills")
const STUB_DIR     = joinpath(REPO_ROOT, ".claude", "skills")

# A stub is frontmatter + ~15 lines of pointer prose. The canonical files run 4-25 KB, so this
# ceiling sits an order of magnitude below the thing it is protecting against. Raising it is a
# deliberate edit, and the answer is almost always "put that sentence in the canonical file".
const STUB_MAX_BYTES = 2_048

"""
Return the YAML frontmatter block of `path`, delimiters included, as it appears on disk.

Returns `nothing` when the file does not open with a `---` line, which is itself a failure the
callers assert on: Claude Code will not register a skill whose frontmatter it cannot parse.
"""
function frontmatter(path::AbstractString)
    lines = readlines(path)
    (isempty(lines) || strip(lines[1]) != "---") && return nothing
    closing = findnext(l -> strip(l) == "---", lines, 2)
    closing === nothing && return nothing
    return join(lines[1:closing], "\n")
end

skill_names(dir) = sort!([d for d in readdir(dir)
                          if isdir(joinpath(dir, d)) && isfile(joinpath(dir, d, "SKILL.md"))])

"""
Return `nothing` if the `key: value` line is safe as YAML, or a reason string if it is not.

This is deliberately NOT a YAML parser -- the unit suite has no YAML dependency and is not
getting one for two lines of frontmatter. It pins the single hazard that actually bit, plus the
neighbouring one that would bite the same way. Both are properties of a *plain* (unquoted)
scalar, so a value the author chose to quote is exempt and returns `nothing` immediately.
"""
function yaml_scalar_problem(key::AbstractString, value::AbstractString)
    v = strip(value)
    isempty(v) && return "$key is empty"
    # A quoted scalar can hold anything; we only police the unquoted form.
    (startswith(v, '"') && endswith(v, '"')) && return nothing
    (startswith(v, '\'') && endswith(v, '\'')) && return nothing
    # ": " terminates a plain scalar -- YAML reads the remainder as a nested mapping and raises
    # "mapping values are not allowed here". This is the one that shipped: two descriptions named
    # a source file ("src/Dialect.jl: SQL generation, ..."), so their frontmatter did not parse
    # and Claude Code registered neither skill. Nothing noticed, because nothing had ever parsed
    # these files as skills before the stubs existed.
    occursin(": ", v) && return "$key contains \": \" but is not quoted"
    # " #" OPENS A COMMENT inside a plain scalar, so YAML keeps only what precedes it -- there is no
    # error, just a silently truncated value. `pormg-cut-release`'s description read "... stamp the
    # ## Unreleased UPGRADING.md entries ..." and registered as "Cut a PormG release train -- bump
    # Project.toml once, stamp the", dropping the half that says it is maintainer-invoked. Same class
    # as the rule above and strictly harder to notice: the skill still loads, and advertises half a
    # sentence to whoever is choosing between skills.
    occursin(" #", v) && return "$key contains ' #' but is not quoted"
    # A plain scalar may not OPEN with a YAML indicator character.
    occursin(first(v), "\"'{}[]&*!|>%@`#") && return "$key starts with the YAML indicator '$(first(v))'"
    return nothing
end

function frontmatter_pairs(path::AbstractString)
    pairs = Dict{String,String}()
    for line in readlines(path)
        strip(line) == "---" && !isempty(pairs) && break
        m = match(r"^([A-Za-z_][A-Za-z0-9_-]*):[ ](.*)$", line)
        m === nothing || (pairs[m.captures[1]] = m.captures[2])
    end
    return pairs
end

# ─────────────────────────────────────────────────────────────────────────────
# Skill stubs: the two trees agree on which skills exist
# Every `.github/skills/<n>/` needs a `.claude/skills/<n>/` stub or Claude Code cannot see it,
# and every stub needs a canonical file or it points at nothing. Checked as a set comparison so
# the failure message names the missing skill instead of a count.
# ─────────────────────────────────────────────────────────────────────────────
@testset "skill name sets match" begin
    @test isdir(CANON_DIR)
    @test isdir(STUB_DIR)

    canon = skill_names(CANON_DIR)
    stubs = skill_names(STUB_DIR)

    @test !isempty(canon)                      # a globbing mistake must not pass vacuously
    @test setdiff(canon, stubs) == String[]    # canonical skill with no stub -> invisible to Claude Code
    @test setdiff(stubs, canon) == String[]    # stub with no canonical file -> points at nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Skill stubs: the duplicated frontmatter is byte-identical
# `name` and `description` are the only bytes that exist twice in the repo by design. A stub
# whose description has drifted advertises the wrong thing to the model choosing a skill, and
# nothing else in the repo would notice.
# ─────────────────────────────────────────────────────────────────────────────
@testset "stub frontmatter matches canonical" begin
    for n in skill_names(CANON_DIR)
        canon_fm = frontmatter(joinpath(CANON_DIR, n, "SKILL.md"))
        stub_fm  = frontmatter(joinpath(STUB_DIR, n, "SKILL.md"))

        @test canon_fm !== nothing            # canonical file must carry parseable frontmatter
        @test stub_fm  !== nothing            # ...and so must the stub, or discovery fails
        @test stub_fm == canon_fm             # byte-for-byte; `name:` drift breaks invocation,
                                              # `description:` drift breaks skill selection
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Skill stubs: frontmatter is safe to parse as YAML, in BOTH trees
# Discovery is all-or-nothing and silent: frontmatter that does not parse means the skill is
# never registered, with no error anywhere -- the caller just gets `Unknown skill` later, which
# is the exact failure these stubs exist to remove. Checked on the canonical files too, since
# that is where the bytes come from and where a new skill gets written first.
# ─────────────────────────────────────────────────────────────────────────────
@testset "frontmatter is YAML-safe" begin
    for dir in (CANON_DIR, STUB_DIR), n in skill_names(dir)
        path  = joinpath(dir, n, "SKILL.md")
        pairs = frontmatter_pairs(path)

        @test haskey(pairs, "name")            # without these two keys Claude Code cannot
        @test haskey(pairs, "description")     # register or select the skill at all

        for key in ("name", "description")
            haskey(pairs, key) || continue
            problem = yaml_scalar_problem(key, pairs[key])
            problem === nothing || @info "YAML-unsafe frontmatter" file=path problem
            @test problem === nothing
        end

        # `name:` must match the directory, or `/`-invoking it addresses the wrong skill.
        @test get(pairs, "name", "") == n
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Skill stubs: the body points at the canonical file and stays a pointer
# The size ceiling is the real guard. A stub cannot be "slightly wrong" -- it fails by growing
# into a second copy of a ruleset that no longer matches, one appended sentence at a time.
# ─────────────────────────────────────────────────────────────────────────────
@testset "stub body stays a pointer" begin
    for n in skill_names(CANON_DIR)
        stub_path = joinpath(STUB_DIR, n, "SKILL.md")
        body      = read(stub_path, String)

        # The stub has to name the file it defers to, in the spelling a reader can follow.
        @test occursin(".github/skills/$n/SKILL.md", body)

        @test filesize(stub_path) <= STUB_MAX_BYTES
    end
end
