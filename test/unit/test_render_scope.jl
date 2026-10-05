"""
Render-scope interface guard (#932).

The #194 grouped-correlation guard reads one piece of dynamic state while a query renders: which
clause, and so which **evaluation phase**, a correlated subquery sits in. That state lives in one
immutable `RenderScope` on `InstructionObject.scope`, and `with_scope` is its only writer: it saves
the previous scope, installs the new one, and **restores** it in a `finally`.

The state used to be two mutable fields, each with its own save/restore discipline, and a third
sibling (`set_context!`) still resets to a hard-coded `:where` instead of restoring. A reset is right
only while nothing nests. The moment a render inside a render returns, a reset puts the outer render
in the wrong clause, and here that means a correlated subquery read as evaluated before GROUP BY when
it is not: wrong rows on SQLite, no error. So the rule is mechanical:

1. **No `src/` or `ext/` line outside `with_scope` assigns `.scope`**, by dot assignment or by
   `setfield!`/`setproperty!`.
2. **The retired fields stay retired.** `correlated_projection` and `post_group_predicate` were the
   two flags `RenderScope` replaced; a line of code naming either is a second copy of the state.
3. **`with_scope` restores on return, on throw, and when nested.**

Static text scan plus a live check — no database.
"""
# julia --project=test/integration test/unit/test_render_scope.jl

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField
import PormG.QueryBuilder: RenderScope, with_scope, InstructionObject, SQLTbAlias

const RSCOPE_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const RSCOPE_DECLARATION_FILE = joinpath(RSCOPE_REPO_ROOT, "src", "querybuilder", "types.jl")

# CRLF-normalized, as `test_memo_interface.jl` does: `.jl` is not pinned to LF.
_rscope_lines(path) = split(replace(read(path, String), "\r\n" => "\n"), '\n')
_rscope_files(dir) = isdir(dir) ? sort!([joinpath(root, f)
                                         for (root, _, files) in walkdir(dir)
                                         for f in files if endswith(f, ".jl")]) : String[]
_rscope_rel(path) = replace(relpath(path, RSCOPE_REPO_ROOT), '\\' => '/')

# Code lines only — comment lines and docstrings discuss the rule, and must not count as breaking it.
# Comment lines are dropped BEFORE the `"""` markers are counted, for the reason
# `test_memo_interface.jl` records: two `#` lines in `src/` carry an odd number of markers.
function _rscope_code_lines(path)
    out = Tuple{Int,String}[]
    in_docstring = false
    for (i, line) in enumerate(_rscope_lines(path))
        startswith(strip(line), "#") && continue
        markers = length(collect(eachmatch(r"\"\"\"", line)))
        was_in = in_docstring
        isodd(markers) && (in_docstring = !in_docstring)
        (was_in || in_docstring) && continue
        push!(out, (i, line))
    end
    return out
end

# An ASSIGNMENT to a `scope` field (`x.scope = …`, never `x.scope == …`), or one through reflection.
const RSCOPE_WRITE = r"\.scope\s*=(?!=)|set(field|property)!\s*\([^,]+,\s*:scope\b"

# The two writes `with_scope` itself makes — pinned by EXPRESSION, not by file, so a second write
# added to `types.jl` is still caught.
const RSCOPE_ALLOWED = Set(["instruc.scope = _with_scope(prev; kw...)", "instruc.scope = prev"])

@testset "RenderScope: only with_scope writes the scope (#932)" begin
    offenders = Tuple{String,Int,String}[]
    allowed_hits = 0
    for dir in (joinpath(RSCOPE_REPO_ROOT, "src"), joinpath(RSCOPE_REPO_ROOT, "ext"))
        for path in _rscope_files(dir), (lineno, line) in _rscope_code_lines(path)
            occursin(RSCOPE_WRITE, line) || continue
            code = strip(first(split(line, '#')))
            if path == RSCOPE_DECLARATION_FILE && code in RSCOPE_ALLOWED
                allowed_hits += 1
            else
                push!(offenders, (_rscope_rel(path), lineno, String(strip(line))))
            end
        end
    end
    isempty(offenders) ||
        @error "A RenderScope is written outside with_scope (#932). Wrap the render in " *
               "with_scope(f, instruc; kw...) instead, so the previous scope is restored." offenders
    @test isempty(offenders)
    # The allow-list must still match the real code: if `with_scope` is rewritten, the two pinned
    # expressions stop matching and this scan would pass vacuously.
    @test allowed_hits == 2
end

@testset "RenderScope: the retired flags stay retired (#932)" begin
    offenders = Tuple{String,Int,String}[]
    for dir in (joinpath(RSCOPE_REPO_ROOT, "src"), joinpath(RSCOPE_REPO_ROOT, "ext"))
        for path in _rscope_files(dir), (lineno, line) in _rscope_code_lines(path)
            code = first(split(line, '#'))
            (occursin("correlated_projection", code) || occursin("post_group_predicate", code)) &&
                push!(offenders, (_rscope_rel(path), lineno, String(strip(line))))
        end
    end
    @test isempty(offenders)
end

# The mutant the scan exists for: a bare assignment must be found. Run against a synthetic file so
# the check proves the pattern, not merely that today's tree is clean.
@testset "RenderScope: the scan pattern finds a bare write" begin
    @test occursin(RSCOPE_WRITE, "    instruc.scope = RenderScope()")
    @test occursin(RSCOPE_WRITE, "outer.scope=s")
    @test occursin(RSCOPE_WRITE, "setfield!(instruc, :scope, s)")
    @test !occursin(RSCOPE_WRITE, "outer.scope == s && return")
    @test !occursin(RSCOPE_WRITE, "phase = instruc.scope.phase")
end

struct RScopeMockSQLite <: PormG.PormGSQLite end
PormG.config["rscope_sl"] = PormG.Configuration.Settings(connections = RScopeMockSQLite(), change_data = true)
const RScopeLap = let m = Model("rscope_laps", id = IDField(), lap = IntegerField())
    m.connect_key = "rscope_sl"; m
end

@testset "RenderScope: with_scope restores on return, throw and nesting (#932)" begin
    instruc = InstructionObject(text = "", table_alias = SQLTbAlias(), alias = "Tb",
                                object = RScopeLap.objects.object)
    base = instruc.scope
    @test base == RenderScope()
    # FAIL-CLOSED: a clause entry that forgets to set the phase must leave a correlated subquery
    # CHECKED (`:group`), so the cost of a missed site is a loud false refusal, never wrong rows.
    # Every clause in `build()` sets its phase today, so no query reaches this default — which is
    # exactly why it is pinned here rather than through one.
    @test base.phase === :group
    @test base.group_key === false

    @test with_scope(() -> instruc.scope.label, instruc; label = "x") == "x"
    @test instruc.scope === base

    @test_throws ErrorException with_scope(() -> error("boom"), instruc; label = "x")
    @test instruc.scope === base

    inner_seen = Ref{Any}(nothing)
    outer_seen = Ref{Any}(nothing)
    with_scope(instruc; label = "outer") do
        with_scope(instruc; label = "inner") do
            inner_seen[] = instruc.scope.label
        end
        outer_seen[] = instruc.scope.label   # restored to the OUTER scope, not reset to a default
    end
    @test inner_seen[] == "inner"
    @test outer_seen[] == "outer"
    @test instruc.scope === base

    # Fields not named keep the enclosing value.
    with_scope(instruc; label = "kept") do
        with_scope(instruc) do
            @test instruc.scope.label == "kept"
        end
    end
end
