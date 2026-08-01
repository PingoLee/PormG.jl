"""
Docstring coverage of the public surface (#212).

Two invariants that nothing else enforces:

1. **Every exported name answers `?`.** `?Name` is the first thing a Julia user tries. Documenter's
   `checkdocs = :exports` does NOT catch a gap here — it flags docstrings that *exist* but are not
   included in the manual, and a name with no docstring has no docs object for it to see. So an
   undocumented export ships silently, which is exactly what happened: the 2026-07-23 audit behind
   #212 missed `@pormg_debug`, and `PormGError` did not exist yet when it was written.

2. **The fluent surface stays documented as it grows.** `query.filter(...)` and friends are
   synthesized by `getproperty`, so they have no bindings — `?query.filter` cannot work (it errors,
   for any Julia value, not just PormG's). Their reference therefore lives in prose, in two places
   that have no compiler link to the code: the `object` docstring and `docs/src/api.md`. Without
   this guard they rot — `object`'s list had drifted 15 methods behind `getproperty` by #212.

Runs WITHOUT a live database: it inspects module namespaces and scans source text.
"""
# julia --project=. test/unit/test_docstring_coverage.jl

using Test
using PormG

const DOCCOV_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const DOCCOV_OBJECT_MANAGER = joinpath(DOCCOV_REPO_ROOT, "src", "querybuilder", "object_manager.jl")
const DOCCOV_API_MD = joinpath(DOCCOV_REPO_ROOT, "docs", "src", "api.md")

# `.md`/`.jl` are not pinned to LF in `.gitattributes`, so a Windows checkout yields CRLF (#216,
# #228). Normalize before matching or every assertion below becomes platform-dependent.
_doccov_read(path) = replace(read(path, String), "\r\n" => "\n")

@testset "Docstring coverage (#212)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # Every exported name has a docstring
    # `names(PormG)` is the curated public surface frozen by test_public_exports.jl (#35); this is
    # the docs-side counterpart. Adding a public name means writing its docstring in the same PR.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "every exported name answers `?`" begin
        exported = filter(n -> n !== :PormG, names(PormG))
        # Guard the guard: if the export surface ever came back empty the loop below would pass
        # vacuously and this file would silently stop testing anything.
        @test length(exported) > 50

        undocumented = filter(n -> !Base.Docs.hasdoc(PormG, n), exported)
        # Name the offenders in the failure output so the fix is obvious.
        @test undocumented == Symbol[]
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Fluent-method drift: every getproperty branch is documented
    # Source of truth is the `sym === :name` chain in Base.getproperty(::ObjectHandler). Scanning
    # the text (rather than calling getproperty) keeps this DB-free and catches a method the
    # moment it is added, before anyone can execute it.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "fluent methods are documented on `object` and in api.md" begin
        source = _doccov_read(DOCCOV_OBJECT_MANAGER)

        # Isolate Base.getproperty(q::ObjectHandler, …). The file holds a SECOND getproperty (on
        # Models.Model_Type, for `.objects`) whose branches are not fluent query methods, so a
        # whole-file scan would demand docs for `:objects` and fail wrongly.
        start_idx = findfirst("function Base.getproperty(q::ObjectHandler", source)
        @test start_idx !== nothing
        rest = source[first(start_idx):end]
        stop_idx = findfirst("\nend\n", rest)
        @test stop_idx !== nothing
        body = rest[1:first(stop_idx)]

        fluent = unique([m.captures[1] for m in eachmatch(r"sym === :(\w+)", body)])
        # Sanity floor: the chain had 29 branches at the time of writing. A regex that silently
        # stopped matching would otherwise turn this testset into a no-op.
        @test length(fluent) >= 25

        object_doc = string(@doc PormG.QueryBuilder.object)
        api_md = _doccov_read(DOCCOV_API_MD)

        # Both surfaces are prose, so match on the `.method(` spelling a reader would search for.
        # The trailing `(` is load-bearing: a bare `.$name` substring lets `.get_or_create` satisfy
        # `.get` and `.update_or_create` satisfy `.update`, so deleting the `.get(...)` bullet would
        # not fail this test. Every documented mention is a call form, so requiring it costs nothing.
        missing_from_doc = filter(name -> !occursin(".$name(", object_doc), fluent)
        missing_from_api = filter(name -> !occursin(".$name(", api_md), fluent)

        @test missing_from_doc == String[]
        @test missing_from_api == String[]
    end

    # ─────────────────────────────────────────────────────────────────────────
    # `ChainCaller` stays undocumented — the `@doc "…" ChainCaller(up_filter!, q)` trap
    # That form does not document `.filter`: the docsystem does not evaluate the expression, it
    # reads it as a signature and binds the text to `ChainCaller(::Any, ::Any)`. `@autodocs`
    # (Private = true by default) then publishes it on the site under a `filter(args...)` heading
    # that belongs to nothing. It looked like it worked for as long as nobody checked.
    #
    # This forbids ANY docstring on ChainCaller, not just a misattributed one — deliberately. The
    # type is internal plumbing with nothing a user needs to read, and no-docstring is the only
    # state distinguishable from the trap by a test. Document the fluent surface on `object`.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "ChainCaller carries no docstring" begin
        @test !Base.Docs.hasdoc(PormG.QueryBuilder, :ChainCaller)
    end
end
