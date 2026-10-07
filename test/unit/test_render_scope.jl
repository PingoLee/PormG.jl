"""
Render-scope interface guard (#932).

The #194 grouped-correlation guard reads one piece of dynamic state while a query renders: which
clause, and so which **evaluation phase**, a correlated subquery sits in. That state lives in one
immutable `RenderScope` on `InstructionObject.scope`, and `with_scope` is its only writer: it saves
the previous scope, installs the new one, and **restores** it in a `finally`.

The state used to be two mutable fields, each with its own save/restore discipline. A reset is right
only while nothing nests. The moment a render inside a render returns, a reset puts the outer render
in the wrong clause, and here that means a correlated subquery read as evaluated before GROUP BY when
it is not: wrong rows on SQLite, no error. So the rule is mechanical:

1. **No `src/` or `ext/` line outside `with_scope` assigns `.scope`**, by dot assignment or by
   `setfield!`/`setproperty!`.
2. **The retired fields stay retired.** `correlated_projection` and `post_group_predicate` were the
   two flags `RenderScope` replaced; a line of code naming either is a second copy of the state.
3. **`with_scope` restores on return, on throw, and when nested.**

The SQLite parameter bucket (`current_context`) is the second piece of render state, and it had the
same disease: three `get_filter_query` branches reset it to a hard-coded `:where`, `build()` and the
join render left their last bucket behind, and two nested renders saved and restored it by hand
(#936, #939). It stays on the shared COLLECTOR rather than in `RenderScope` — the outer and nested
builds share one collector, a scope belongs to one instruction — but takes the same rule:

4. **Only `with_bucket` changes the bucket on a build path.** `set_context!` is left to statement entry
   points starting a fresh collector, pinned below by file, expression and count.
5. **Nothing outside `parameters.jl` reads or writes `.current_context`** — the hand-written
   save/restore is how the old discipline was spelled.
6. **`with_bucket` restores on return, on throw, and when nested**, and is a no-op on PostgreSQL.

Static text scan plus a live check — no database.
"""
# julia --project=test/integration test/unit/test_render_scope.jl

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField
import PormG.QueryBuilder: RenderScope, with_scope, InstructionObject, SQLTbAlias,
    with_bucket, SQLiteParameterizedQuery, PgParameterizedQuery

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

# ─────────────────────────────────────────────────────────────────────────────
# The SQLite parameter bucket: only `with_bucket` changes it on a build path (#936, #939)
# ─────────────────────────────────────────────────────────────────────────────
const RSCOPE_PARAMS_FILE = joinpath(RSCOPE_REPO_ROOT, "src", "querybuilder", "parameters.jl")

# ANY use of `set_context!` — a call, or the function passed as a value (`map(set_context!, …)`,
# `set_context!.(…)`). `parameters.jl`, which defines it and `with_bucket`, is not scanned.
const RSCOPE_SET_CONTEXT = r"\bset_context!"
# Any reach into the bucket selector, read or write — the spelling of a hand-written save/restore.
# `.*` rather than `[^,]+` in the reflection arm, so a nested target (`getfield(x, :parameters)`) is
# still seen.
const RSCOPE_CURRENT_CONTEXT = r"\.current_context\b|(get|set)(field|property)!?\s*\(.*:current_context\b"

# Statement entry points: each starts a fresh collector, or picks the bucket for a statement it is
# assembling at top level (a SET list, an insert row, a fence re-emitted after its build). No render
# is suspended in such a collector, so there is no outer bucket to restore. Pinned by file AND
# expression with its count, so a new call — or one moved into a build path — fails here until
# someone decides which kind it is. The build paths (`build_query.jl`, `build_select.jl`,
# `projection_types.jl`, `build_filter.jl`, `build_helpers.jl`, `filter_pairs.jl`, `field_resolution.jl`,
# `select_nodes.jl`, `filter_nodes.jl`, `filter_operators.jl`, `ctes.jl`, `build_joins.jl`,
# `join_conditions.jl`, …) hold none.
const RSCOPE_SET_CONTEXT_ALLOWED = Dict(
    # query() of a top-level statement (`:cte` first: WITH prints first), count(), exists().
    "src/querybuilder/execution_read.jl" => Dict(
        "!is_subquery && set_context!(parameters, :cte)" => 1,
        "set_context!(parameters, :cte)" => 2),
    # insert and upsert rows (`:select`); update()'s SET list (`:update`); a temp-table insert
    # (`tp`); the mutation predicate and update fence re-emitting their lifted runs under `:where`.
    "src/querybuilder/execution_write.jl" => Dict(
        "set_context!(parameters, :select)" => 3,
        "set_context!(parameters, :update)" => 1,
        "set_context!(parameters, :where)" => 3,
        "set_context!(tp, :where)" => 1),
    # bulk insert / bulk update rows, and each bulk_update chunk's forked collector.
    "src/querybuilder/execution_bulk.jl" => Dict(
        "set_context!(parameters, :select)" => 3,
        "new_chunk_parameters() = (p = _fork_parameters(base_parameters); set_context!(p, :select); p)" => 1),
    # the many-to-many manager's own INSERT / DELETE / SELECT statements.
    "src/querybuilder/many_to_many.jl" => Dict(
        "set_context!(parameters, :select)" => 2,
        "set_context!(parameters, :where)" => 3),
    # the deletion collector's shared predicate collector.
    "src/querybuilder/deletion.jl" => Dict(
        "set_context!(parameters, :where)" => 1),
)

# Every code line under `src/`/`ext/` matching `pattern`, as (file => (expression => count)) plus the
# located hits for the failure message. A trailing `# …` comment is cut before matching.
function _rscope_scan(pattern; roots = (joinpath(RSCOPE_REPO_ROOT, "src"), joinpath(RSCOPE_REPO_ROOT, "ext")))
    hits = Dict{String,Dict{String,Int}}()
    located = Tuple{String,Int,String}[]
    for dir in roots, path in _rscope_files(dir)
        path == RSCOPE_PARAMS_FILE && continue
        for (lineno, line) in _rscope_code_lines(path)
            code = String(strip(first(split(line, '#'))))
            occursin(pattern, code) || continue
            counts = get!(hits, _rscope_rel(path), Dict{String,Int}())
            counts[code] = get(counts, code, 0) + 1
            push!(located, (_rscope_rel(path), lineno, code))
        end
    end
    return hits, located
end

@testset "parameter bucket: set_context! only at statement entry points (#936, #939)" begin
    hits, located = _rscope_scan(RSCOPE_SET_CONTEXT)
    hits == RSCOPE_SET_CONTEXT_ALLOWED ||
        @error "A set_context! call changed (#936, #939). On a build path, wrap the render in " *
               "with_bucket(f, instruc, clause) so the previous bucket is restored; at a statement " *
               "entry point, add it to RSCOPE_SET_CONTEXT_ALLOWED with its reason." located
    # Equality, not a subset check: a removed or rewritten entry point fails too, so the list cannot
    # go stale and let a later call slip in under an expression that no longer exists.
    @test hits == RSCOPE_SET_CONTEXT_ALLOWED
end

@testset "parameter bucket: no hand-written save/restore of current_context (#936, #939)" begin
    _, located = _rscope_scan(RSCOPE_CURRENT_CONTEXT)
    isempty(located) ||
        @error "current_context is read or written outside parameters.jl (#936, #939). Use " *
               "with_bucket(f, x, clause), which restores the bucket it found." located
    @test isempty(located)
end

# The mutants the scans exist for, against a synthetic tree, so the checks prove the patterns and the
# scanner rather than merely that today's tree is clean.
@testset "parameter bucket: the scans find a bare reset and a hand-written restore" begin
    @test occursin(RSCOPE_SET_CONTEXT, "set_context!(instruc, :where)")
    @test occursin(RSCOPE_SET_CONTEXT, "set_contexts && set_context!(instruct, :join)")
    @test occursin(RSCOPE_SET_CONTEXT, "foreach(p -> set_context!(p, :where), ps)")
    @test occursin(RSCOPE_SET_CONTEXT, "map(set_context!, ps, ctxs)")
    @test occursin(RSCOPE_SET_CONTEXT, "set_context!.(ps, :where)")
    @test !occursin(RSCOPE_SET_CONTEXT, "with_bucket(instruc, :where) do")
    @test occursin(RSCOPE_CURRENT_CONTEXT, "old = instruc.parameters.current_context")
    @test occursin(RSCOPE_CURRENT_CONTEXT, "p.current_context = :where")
    @test occursin(RSCOPE_CURRENT_CONTEXT, "setfield!(p, :current_context, :where)")
    @test occursin(RSCOPE_CURRENT_CONTEXT, "getfield(p, :current_context)")
    @test occursin(RSCOPE_CURRENT_CONTEXT, "setproperty!(getfield(x, :parameters), :current_context, :where)")
    @test !occursin(RSCOPE_CURRENT_CONTEXT, "with_bucket(p, :where) do")

    mktempdir() do dir
        write(joinpath(dir, "build_x.jl"), """
            function f(instruc)
              set_context!(instruc, :having)   # the reset this guards against
              old = instruc.parameters.current_context
              # set_context!(instruc, :where) and .current_context, in a comment only
            end
            """)
        hits, _ = _rscope_scan(RSCOPE_SET_CONTEXT; roots = (dir,))
        @test only(values(hits)) == Dict("set_context!(instruc, :having)" => 1)
        _, located = _rscope_scan(RSCOPE_CURRENT_CONTEXT; roots = (dir,))
        @test length(located) == 1
    end
end

@testset "parameter bucket: with_bucket restores on return, throw and nesting (#936, #939)" begin
    sq = SQLiteParameterizedQuery()
    @test sq.current_context === :where
    @test with_bucket(() -> sq.current_context, sq, :having) === :having
    @test sq.current_context === :where

    @test_throws ErrorException with_bucket(() -> error("boom"), sq, :join)
    @test sq.current_context === :where

    seen = Symbol[]
    with_bucket(sq, :select) do
        with_bucket(sq, :having) do
            push!(seen, sq.current_context)
        end
        push!(seen, sq.current_context)   # restored to the OUTER bucket, not reset to `:where`
    end
    @test seen == [:having, :select]
    @test sq.current_context === :where

    # Through an instruction, as every build path calls it.
    instruc = InstructionObject(text = "", table_alias = SQLTbAlias(), alias = "Tb",
                                object = RScopeLap.objects.object, parameters = sq)
    with_bucket(instruc, :order) do
        @test sq.current_context === :order
    end
    @test sq.current_context === :where

    # PostgreSQL numbers `$N` at render: there is no bucket, and the body still runs.
    @test with_bucket(() -> 42, PgParameterizedQuery("", Any[], 0), :having) == 42
    # An instruction without a collector runs the body as is.
    bare = InstructionObject(text = "", table_alias = SQLTbAlias(), alias = "Tb",
                             object = RScopeLap.objects.object)
    @test with_bucket(() -> :ran, bare, :where) === :ran
end
