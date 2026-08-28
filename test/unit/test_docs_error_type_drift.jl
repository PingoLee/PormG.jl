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

# Julia source lines that are CODE, not commentary. Every `src/` guard below needs this: the
# taxonomy's own header documents the contracts being enforced, so it necessarily quotes
# `throw(ArgumentError(` and names the retired `_argerr`. A guard that counted prose would flag the
# documentation of the rule as a violation of it — which it did, until this helper existed.
_drift_code_lines(path) = [(i, l) for (i, l) in enumerate(_drift_lines(path))
                           if !startswith(strip(l), "#")]

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
const ALLOWED_SRC_ARGUMENTERROR = Dict(
    "src/tools.jl" => 2,   # upgrade_guide's missing kwarg / missing path — Julia-level misuse
    "src/Utils.jl" => 1,   # @import_models non-literal path — macro (Julia-level) misuse
)

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
# src/ and ext/ raise no untyped errors (#268 audit)
# `catch PormGError` is the documented contract, and the 2026-07-30 audit found it leaking through
# exactly the patterns no guard policed: `throw(ErrorException(` and bare `error(` calls — 14 of
# them user-reachable (bulk row validation, missing-driver hints, five migration-engine sites, the
# before_connect hook, `with_advisory_lock`). Those are fixed; this pins the residue so the leak
# class cannot regrow. `ext/` is scanned too — it previously had NO guard coverage at all.
#
# The allowlists are positive pins (== , not <=): every entry is a deliberate, commented keep, and
# removing one from src/ must shrink the list here or the guard fails — same discipline as
# ALLOWED_SRC_ARGUMENTERROR.
# ─────────────────────────────────────────────────────────────────────────────
const DRIFT_EXT_DIR = joinpath(DRIFT_REPO_ROOT, "ext")

# Internal invariant violations ("should not happen; please report") — not PormG misuse, so they
# stay ErrorException by design rather than polluting the taxonomy with an InternalError type.
const ALLOWED_UNTYPED_ERROREXCEPTION = Dict(
    # AdvisoryLock's entry is GONE, not zeroed: #268 settled the boundary decision it was parked
    # with, and lock-acquisition timeout is now an OperationalError (contention is a transient
    # runtime condition, not misuse). This dict is asserted with `==`, so a stale key fails too.
    "src/ConnectionPool.jl"  => 1,  # SQLite async worker returned a malformed payload (internal)
)
const ALLOWED_UNTYPED_BARE_ERROR = Dict(
    # #452 took this from 1 to 2, and REWROTE the first rationale: the old keep was "empty generated
    # SQL", a check on a `sql` variable that could only stay empty if neither branch of a two-branch
    # if/else ran. Collapsing those branches into one render path made that unreachable in the
    # trivial sense, so it was replaced by the condition that actually protects the same statement —
    # `delete_objects` called with no keys, which would emit `WHERE` with nothing after it.
    # Both keeps are genuinely internal: callers reach `delete_objects` only through
    # `run_deletions`, which iterates non-empty collections, and `_affected_row_count` only after the
    # `show_query !== :execute` return, where `conn` is the transaction's pinned connection.
    "src/querybuilder/deletion.jl"      => 2,  # no keys / no conn to count on — internal invariants
    # #433 shrank this from 2 to 1. The "unmaterialized CTE" site was NOT an internal invariant:
    # `cte_dict["model"]` is written only by `build_cte_clause`, so its absence means the statement
    # emits no WITH clause — reachable from `update()` on a query that references a CTE. It is now a
    # QueryBuildError. The remaining keep is the missing-join-alias lookup, which is genuinely
    # internal (aliases are minted from the same row_join vector that is then searched).
    "src/querybuilder/build_joins.jl"   => 1,  # missing join alias — internal invariant
    "src/querybuilder/build_helpers.jl" => 2,  # duplicate dedup row / bad placeholder type — internal
    "src/ConnectionPool.jl"             => 1,  # `error("validation failed")` inside atomic()'s DOCSTRING example
)

@testset "src/ and ext/ raise no untyped errors (#268)" begin
    found_ee = Dict{String,Int}()
    found_err = Dict{String,Int}()
    for dir in (DRIFT_SRC_DIR, DRIFT_EXT_DIR)
        isdir(dir) || continue
        for path in _drift_files(dir, ".jl")
            n_ee, n_err = 0, 0
            for (_, line) in _drift_code_lines(path)
                occursin("throw(ErrorException(", line) && (n_ee += 1)
                # The negated class's `.` lets `Base.error(` through — the canonical qualified
                # spelling of exactly what this hunts — so it gets its own pattern.
                (occursin(r"(?:^|[^_\w!.@])error\(", line) || occursin("Base.error(", line)) && (n_err += 1)
            end
            n_ee  > 0 && (found_ee[_drift_rel(path)] = n_ee)
            n_err > 0 && (found_err[_drift_rel(path)] = n_err)
        end
    end

    for (label, found, allowed) in (("throw(ErrorException(", found_ee, ALLOWED_UNTYPED_ERROREXCEPTION),
                                    ("bare error(",           found_err, ALLOWED_UNTYPED_BARE_ERROR))
        unexpected = filter(p -> get(allowed, p.first, 0) != p.second, found)
        if !isempty(unexpected)
            @error """
            Untyped $(label) found outside the allowlisted internal invariants.
            An error a consumer can reach must be a PormGError subtype — see the taxonomy index in
            src/exceptions.jl. A genuine internal invariant may stay untyped, but it must be added
            here WITH its rationale.
            """ unexpected expected = allowed
        end
        @test isempty(unexpected)
        # Equality (not <=): a STALE allowlist entry — the keep was removed but the pin wasn't —
        # must also fail, so the list stays earned. The printed dicts show which side drifted.
        @test found == allowed
    end

    # ext/ must stay completely clean — it has no legitimate keeps.
    @test isdir(DRIFT_EXT_DIR)
    @test !any(startswith(k, "ext/") for k in keys(found_ee))
    @test !any(startswith(k, "ext/") for k in keys(found_err))
end

# ─────────────────────────────────────────────────────────────────────────────
# The `_argerr` alias stays retired (#262)
# It only mapped a message to `QueryBuildError`, so `throw(_argerr("…"))` told a reader nothing
# about the resulting type — scaffolding from #231's mechanical swap, removed once the migration
# finished. Reintroducing it by habit would re-hide the type at every new call site, so fail loudly
# rather than let it creep back.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the _argerr alias stays retired (#262)" begin
    # Absence-only guards pass when the scan itself breaks. Pin the fixture and prove the helper
    # actually returns code lines from a file we know contains a funnel call — otherwise inverting
    # `_drift_code_lines`' filter, or pointing DRIFT_SRC_DIR at an empty tree, would look green.
    @test isdir(DRIFT_SRC_DIR)
    @test length(_drift_files(DRIFT_SRC_DIR, ".jl")) >= 30
    @test any(((_, l),) -> occursin("_write_not_allowed(", l),
              _drift_code_lines(joinpath(DRIFT_SRC_DIR, "querybuilder", "error_funnels.jl")))

    offenders = String[]
    for path in _drift_files(DRIFT_SRC_DIR, ".jl")
        for (lineno, line) in _drift_code_lines(path)
            occursin("_argerr", line) || continue
            push!(offenders, "$(_drift_rel(path)):$(lineno)  $(strip(line))")
        end
    end
    if !isempty(offenders)
        @error """
        `_argerr` is back in src/. It is a pure alias for `QueryBuildError` and hides the thrown
        type at the call site. Write `throw(QueryBuildError("…"))` instead. A funnel earns its place
        only by composing a message from parameters — see src/querybuilder/error_funnels.jl.
        """ offenders
    end
    @test isempty(offenders)
end

# ─────────────────────────────────────────────────────────────────────────────
# Every funnel call site throws its result (#262)
# This is the hazard `error_funnels.jl`'s header describes and that the convention exists to remove:
# the funnels RETURN an exception, so a call site that forgets `throw(` constructs one, discards it,
# and lets execution continue straight past the guard. Nothing raised, nothing failed — `insert()`
# would simply return the exception object as its row.
#
# `test_typed_exceptions.jl` pins the funnel side (they return). Behavioral coverage of the call
# sites is thin by nature — 4 of 13 `_write_not_allowed` sites, 0 of 8 `_unsupported_conn` — so a
# static check is what actually covers the other 260-odd. Deliberately requires `throw(` on the SAME
# line as the funnel call; a call split across lines should keep them together.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every funnel call site throws its result (#262)" begin
    funnels = ("_unsupported_conn", "_write_not_allowed", "_fielderr")

    offenders = String[]
    seen = Dict(f => 0 for f in funnels)
    for path in _drift_files(DRIFT_SRC_DIR, ".jl")
        for (lineno, line) in _drift_code_lines(path)
            for f in funnels
                occursin(f * "(", line) || continue
                # Skip the funnel's own DEFINITION. Must match on the `= ` — testing only
                # `startswith(line, "_funnel(")` also matches a bare call at statement start, which
                # is exactly the violation being hunted, so the guard would skip its own target.
                # (Verified by mutation: dropping `throw(` at execution.jl:661 must fail here.)
                occursin(Regex("^" * f * raw"\(.*\)\s*="), strip(line)) && continue
                seen[f] += 1
                occursin("throw(", line) && continue
                push!(offenders, "$(_drift_rel(path)):$(lineno)  $(strip(line))")
            end
        end
    end

    if !isempty(offenders)
        @error """
        Funnel result constructed but never thrown. These helpers RETURN an exception — the call
        site must throw it, e.g. `throw(_write_not_allowed(op, key))`. As written the exception is
        built and discarded, and execution continues past the guard with no error at all.
        """ offenders
    end
    @test isempty(offenders)

    # Guard the guard: every funnel must actually have been found, or a rename would silence this.
    for f in funnels
        @test seen[f] > 0
    end

    # And the funnel file itself must contain no `throw(` — that is the convention, stated once and
    # enforced here, so a FOURTH funnel added later cannot quietly throw internally. The name-by-name
    # testset in test_typed_exceptions.jl cannot cover a funnel nobody has written yet.
    funnel_file = joinpath(DRIFT_SRC_DIR, "querybuilder", "error_funnels.jl")
    @test isfile(funnel_file)
    throwing = [(i, strip(l)) for (i, l) in _drift_code_lines(funnel_file) if occursin("throw(", l)]
    if !isempty(throwing)
        @error """
        `error_funnels.jl` contains `throw(`. Funnels return; call sites throw — see the file header.
        """ throwing
    end
    @test isempty(throwing)
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
        n = count(((_, l),) -> occursin("throw(ArgumentError(", l), _drift_code_lines(path))
        n > 0 && (found[_drift_rel(path)] = n)
    end

    unexpected = filter(p -> get(ALLOWED_SRC_ARGUMENTERROR, p.first, 0) != p.second, found)
    if !isempty(unexpected)
        @error """
        `throw(ArgumentError(...))` found in src/ outside the deliberate keeps.
        Use a `PormGError` subtype — `FieldValidationError` for a field constructor,
        `ModelDefinitionError` for a schema definition, `QueryBuildError` for query-builder
        misuse. `ArgumentError` is correct ONLY for Julia-level API misuse.
        """ unexpected expected = ALLOWED_SRC_ARGUMENTERROR
    end
    @test isempty(unexpected)

    # Pin the keeps positively too, so deleting them silently doesn't loosen the guard.
    @test found == ALLOWED_SRC_ARGUMENTERROR
end
