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

# Isolate the body of `Base.getproperty(q::ObjectHandler, …)` — shared by the two scans below.
# The file holds a SECOND getproperty (on `Models.Model_Type`, for `.objects`) whose branches are
# not fluent query methods, so a whole-file scan would demand docs for `:objects` and fail wrongly.
# The `"\nend\n"` stop works only because every nested `end` inside the chain is indented.
# Returns "" when either anchor is missing, so the callers' floors turn a broken scan into a
# failure instead of a vacuous pass.
function _doccov_getproperty_body()
    source = _doccov_read(DOCCOV_OBJECT_MANAGER)
    start_idx = findfirst("function Base.getproperty(q::ObjectHandler", source)
    start_idx === nothing && return ""
    rest = source[first(start_idx):end]
    stop_idx = findfirst("\nend\n", rest)
    stop_idx === nothing && return ""
    return rest[1:first(stop_idx)]
end

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
    # The same invariant for the submodule surfaces (#274)
    # `using PormG` does not bring these names into scope, so the loop above never saw them —
    # yet the docs tell users to reach the function library by `using PormG.Functions`, which
    # makes it just as public as the top level. #274 closed the gap: Functions 16 missing,
    # Migrations 12, ConnectionPool 3.
    #
    # `PormG.Kernel` is deliberately NOT in this list. Its ~95 exports are almost entirely
    # constants and type maps (`APP_PATH`, `*_type_map`, `reserved_words`, `CASCADE`, …) that no
    # user types at the REPL; docstrings on them would be noise in the `@autodocs` dump for no
    # gain. Only the extension-facing types (`PormGModel`, `PormGField`, `SQLObject`,
    # `SQLObjectHandler`, `PormGBackend`) are documented, which is partial by design and so
    # cannot be enforced by an all-or-nothing check.
    #
    # `Models`, `QueryBuilder`, `Configuration` and `Utils` are also in `docs/make.jl`'s
    # `modules` list and the api.md `@autodocs` block but are NOT guarded here — #274 scoped
    # itself to the three surfaces the docs actively tell users to import. Adding them is a
    # follow-up, and each needs its own gap measured first.
    #
    # Note the one thing this cannot catch: a name can always be made to pass by DELETING its
    # export rather than documenting it. That is a legitimate fix (it is what #274 did for nine
    # Migrations internals) but it is a public-surface decision, so the floors below exist to
    # make a wholesale export cull fail loudly rather than silently satisfy the check.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "submodule exports answer `?`" begin
        # (module, floor) — the floor is the vacuous-pass guard. `names(M)` on a module whose
        # export list vanished returns just `[:M]`, which would filter to an empty
        # `undocumented` and pass while testing nothing. Floors sit just under the real counts
        # at the time of writing (42 / 24 / 16) so a genuine addition does not trip them.
        for (mod, floor) in ((PormG.Functions, 40), (PormG.Migrations, 20), (PormG.ConnectionPool, 14))
            @testset "$(nameof(mod))" begin
                exported = filter(n -> n !== nameof(mod), names(mod))
                @test length(exported) >= floor

                undocumented = sort(filter(n -> !Base.Docs.hasdoc(mod, n), exported))
                @test undocumented == Symbol[]
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Fluent-method drift: every getproperty branch is documented
    # Source of truth is the `sym === :name` chain in Base.getproperty(::ObjectHandler). Scanning
    # the text (rather than calling getproperty) keeps this DB-free and catches a method the
    # moment it is added, before anyone can execute it.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "fluent methods are documented on `object` and in api.md" begin
        body = _doccov_getproperty_body()
        @test !isempty(body)

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

    # ─────────────────────────────────────────────────────────────────────────
    # …and neither do the helpers it dispatches to (#281)
    # `api.md`'s `@autodocs` block sets no `Private` key, so Documenter's `Private = true` default
    # publishes EVERY docstring in `PormG.QueryBuilder` as a public API heading. A docstring on
    # `up_filter!` therefore ships a heading for a function no user can name — the same defect the
    # ChainCaller guard above exists to prevent, one level down. Three had drifted in
    # (`up_filter!`, `up_values!`, `order_by!`) before #281; `page` had it until #280.
    #
    # SCOPED TO `ChainCaller(helper, q)` BRANCHES ON PURPOSE — do not "fix" this by widening it to
    # every `sym === :name` branch. That rule is not satisfiable: the closure branches route to
    # `first`/`last`/`get`/`deepcopy`, whose bindings resolve to **Base**, so `hasdoc` is
    # permanently true for them; and to `delete`/`earliest`/`latest`/`list`/`inspect_query`/
    # `cjoin`/`With`, which are legitimately documented. The ChainCaller set is exactly the set
    # with no user-facing binding to attach docs to.
    #
    # This is NOT the whole leak. 41 documented QueryBuilder-owned bindings are exported from
    # neither `QueryBuilder` nor `PormG`, and `@autodocs` publishes every one of them
    # (`_solve_field`, `get_filter_query`, `set_context!`, `quote_identifier`, `CTEDict`, …).
    # Closing that needs a deliberate call, not a flag flip: the same 41 also contains `delete`,
    # `list`, `earliest`, `latest`, `cjoin`, `save` and `ObjectHandler`, which are genuinely
    # user-facing, so `Private = false` would drop real documentation. Tracked separately.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "ChainCaller-backed helpers carry no docstring (#281)" begin
        body = _doccov_getproperty_body()
        @test !isempty(body)

        # `sym === :name` → any comment/blank lines → `return ChainCaller(helper, q)`.
        # Comment-tolerant deliberately: `:select_for_update` already carries two comment lines
        # between its `elseif` and its `return`, so a strict two-line pattern would silently stop
        # matching the first time someone annotates a ChainCaller branch.
        pattern = r"sym === :\w+\s*\n(?:[ \t]*#[^\n]*\n|[ \t]*\n)*[ \t]*return ChainCaller\((\w+!?), q\)"
        matches = collect(eachmatch(pattern, body))
        helpers = unique([m.captures[1] for m in matches])

        # Guard the guard, two ways. The equality is self-calibrating — it proves the regex matched
        # EVERY ChainCaller construction rather than a lucky subset, without hard-coding a count
        # that a legitimate new method would have to bump. The floor catches both regexes failing
        # together, which equality alone would report as a vacuous pass.
        #
        # Count over a COMMENT-STRIPPED copy, and keep the count regex shape-agnostic. Both halves
        # are load-bearing, and the obvious simplifications each break one:
        #   - stripping comments stops a mere mention of `ChainCaller(...)` — this file's own header
        #     has one, and object_manager.jl is heavily commented — inflating the count into a bogus
        #     "8 == 9" that reads like a missing branch.
        #   - the count must NOT be anchored to `return ChainCaller(` the way `pattern` is. Sharing
        #     a lexical shape makes both regexes blind to the same thing, so a construction written
        #     any other way (`sym === :x; return ChainCaller(…)` on one line, or assigned to a local
        #     first) passes silently — which is exactly the leak this guard exists to catch.
        #   - compare `matches`, not `helpers`: two branches legitimately routing to one helper
        #     (an alias) would otherwise fail as "7 == 8". `unique` matters only for the doc loop.
        code = replace(body, r"^[ \t]*#[^\n]*$"m => "")
        n_constructions = length(collect(eachmatch(r"ChainCaller\(", code)))
        @test length(matches) == n_constructions
        @test n_constructions >= 8

        # `hasdoc` alone is NOT enough: it resolves the binding through to its defining module, so
        # it returns true for anything named after a documented `Base` function. Require the
        # docstring to be owned by QueryBuilder before calling it a leak.
        documented = filter(helpers) do name
            sym = Symbol(name)
            Base.Docs.hasdoc(PormG.QueryBuilder, sym) &&
                Base.Docs.Binding(PormG.QueryBuilder, sym).mod === PormG.QueryBuilder
        end
        @test documented == String[]
    end
end
