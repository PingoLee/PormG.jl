"""
Error-contract drift guard (#239).

Two invariants that #239 established and nothing else enforces:

1. **`docs/src` must never tell a user to expect `ArgumentError` from a PormG call.** Every PormG
   domain error is a `PormGError` subtype; a page that still names `ArgumentError` teaches a
   `catch` block that silently stops matching.
2. **`src/` must not raise `ArgumentError` for a PormG domain error.** Only genuine Julia-level
   API misuse (a missing kwarg, a missing path) may still use it.

This is a static text scan — no database, no query execution. It exists because 26 stale doc
claims survived an entire release (most broke when #231 shipped in `0.3.0`) with nothing to
catch them, which is what blocked #253's `errors.md`.

Scope note: this file only proves no page names the **wrong** type. The companion
`test/integration/test_docs_error_types.jl` proves the **right** type is actually raised for each
documented scenario — that is the check a plausible-but-wrong type would slip past here.
"""
# julia --project=. test/unit/test_docs_error_type_drift.jl

using Test

const DRIFT_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const DRIFT_DOCS_SRC = joinpath(DRIFT_REPO_ROOT, "docs", "src")
const DRIFT_SRC_DIR = joinpath(DRIFT_REPO_ROOT, "src")

# `.md` is not pinned to LF in `.gitattributes`, so a Windows checkout yields CRLF (#216, #228).
# Normalize before matching or every assertion below becomes platform-dependent.
_drift_lines(path) = split(replace(read(path, String), "\r\n" => "\n"), '\n')

_drift_files(dir, ext) = sort!([joinpath(root, f)
                                for (root, _, files) in walkdir(dir)
                                for f in files if endswith(f, ext)])

# Render a repo-relative path so failure output is copy-pasteable.
_drift_rel(path) = replace(relpath(path, DRIFT_REPO_ROOT), '\\' => '/')

# The ONLY legitimate reasons a `docs/src` page may name `ArgumentError`. Each entry is a
# *pattern*, never a line number — line numbers drift on every unrelated doc edit and would make
# this guard a nuisance rather than a signal.
const ALLOWED_DOC_MENTIONS = [
    # DataFrames.jl raises this itself on a bare `SELECT *` across joined tables. It is not a
    # PormG error, so it correctly stays `ArgumentError`.
    ("DataFrames.jl's own duplicate-column error", r"Duplicate variable names"),
    # api.md's warning that the taxonomy is deliberately NOT `<: ArgumentError` (the #231/#239
    # clean break). Naming the type is the entire point of the warning.
    ("the deliberate clean-break warning", r"These are not `ArgumentError`s"),
    ("the deliberate clean-break warning", r"deliberately \*\*not\*\* `<: ArgumentError`"),
]

# `src/tools.jl`'s two deliberate keeps: `upgrade_guide(from=…)` missing its required kwarg, and a
# missing path. Both are Julia-level API misuse, not a PormG domain error.
const ALLOWED_SRC_ARGUMENTERROR = Dict("src/tools.jl" => 2)

# ─────────────────────────────────────────────────────────────────────────────
# Docs error-type drift: no user-facing page may promise `ArgumentError`
# Scans every `docs/src/**/*.md` line naming `ArgumentError` and requires it to match one of the
# allow-listed reasons above. A page that says "raises an `ArgumentError`" for a PormG failure
# hands the reader a `catch` block that cannot fire — the exact defect #239 exists to remove.
# ─────────────────────────────────────────────────────────────────────────────
@testset "docs/src names no stale ArgumentError" begin
    @test isdir(DRIFT_DOCS_SRC)

    # Collect every offending (file, line) so one run reports all of them, not just the first.
    offenders = Tuple{String,Int,String}[]
    allowed_hits = 0

    for path in _drift_files(DRIFT_DOCS_SRC, ".md")
        for (lineno, line) in enumerate(_drift_lines(path))
            occursin("ArgumentError", line) || continue
            if any(pat -> occursin(pat, line), last.(ALLOWED_DOC_MENTIONS))
                allowed_hits += 1
            else
                push!(offenders, (_drift_rel(path), lineno, strip(line)))
            end
        end
    end

    if !isempty(offenders)
        @error """
        $(length(offenders)) docs/src line(s) still promise `ArgumentError`.
        Every PormG domain error is a `PormGError` subtype (#231, #239). Resolve each against its
        real throw site in src/ and name that subtype instead — do not add it to the allow-list
        unless the error genuinely is not PormG's (e.g. DataFrames.jl's own).
        """ offenders
    end
    @test isempty(offenders)

    # The allow-list must stay *earned*: if a documented DataFrames.jl caveat or the clean-break
    # warning is deleted, this drops and the list should shrink with it.
    @test allowed_hits == 4
end

# ─────────────────────────────────────────────────────────────────────────────
# Source error-type drift: `src/` raises no `ArgumentError` for a PormG domain error
# #239 retyped all 358 sites; only `src/tools.jl`'s two Julia-level API misuses remain. A new
# `throw(ArgumentError(...))` anywhere else re-splits the taxonomy that #239 closed, and
# `catch PormGError` silently stops covering it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "src/ raises no stale ArgumentError" begin
    @test isdir(DRIFT_SRC_DIR)

    found = Dict{String,Int}()
    for path in _drift_files(DRIFT_SRC_DIR, ".jl")
        n = count(l -> occursin("throw(ArgumentError(", l), _drift_lines(path))
        n > 0 && (found[_drift_rel(path)] = n)
    end

    unexpected = filter(p -> get(ALLOWED_SRC_ARGUMENTERROR, p.first, 0) != p.second, found)
    if !isempty(unexpected)
        @error """
        `throw(ArgumentError(...))` found in src/ outside the deliberate keeps.
        Use a `PormGError` subtype — `FieldValidationError` for a field constructor,
        `ModelDefinitionError` for a schema definition, `_argerr` (→ `QueryBuildError`) for
        query-builder misuse. `ArgumentError` is correct ONLY for Julia-level API misuse.
        """ unexpected expected = ALLOWED_SRC_ARGUMENTERROR
    end
    @test isempty(unexpected)

    # Pin the keeps positively too, so deleting them silently doesn't loosen the guard.
    @test found == ALLOWED_SRC_ARGUMENTERROR
end
