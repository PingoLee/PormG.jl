"""
Memo-access interface guard (#478).

`InstructionObject` carries three per-build memos — `cache`, `tab_field_cache`, `json_lookup_paths`
— all keyed by `MemoKey` (`src/querybuilder/types.jl`). #474 gave them a typed key; #478 gave them a
single accessor (`src/querybuilder/memos.jl`) and made a bare-`String` lookup impossible.

This file is the mechanical form of a hand audit. PR #477's third review pass had to enumerate ~30
direct `Dict` accesses by eye to prove the #474 fix was complete — that enumeration is the symptom
this guard removes. Three invariants:

1. **No `src/` or `ext/` file outside `memos.jl` may touch the three fields directly**, by dot
   access or by `getfield`/`getproperty`/`hasproperty`.
2. **No call site outside `memos.jl` may CONSTRUCT a key.** This is the issue's actual subject and
   the one most easily mistaken for invariant 1: `memo_field(instruc, (:base, name))` passes
   dispatch and touches no field, yet restates the keying rule exactly as the 15 bare `(:base, x)`
   literals #478 removed did. Owning the field without owning the key buys nothing.
3. **A bare-`String` lookup is refused by dispatch**, so a missed key is an error rather than a
   degradation. This matters because the failure is otherwise invisible: a bare-`String` WRITE is a
   loud `MethodError` (`setindex!` calls `convert(K, key0)` and no conversion exists), but a
   bare-`String` READ is a silent `false`/default — the memo misses, the expression re-resolves, and
   in the collision case it resolves against the wrong namespace and returns valid SQL for the wrong
   column.

Julia's dispatch, unlike `setindex!`, never converts its arguments. `String <: Tuple{Symbol,String}`
is false, so typing every accessor on `::MemoKey` buys invariant 3 outright — which is why no wrapper
struct was added. #41 measured the `Tuple` key at +3.6% allocation on #477; a struct would have cost
that again to buy a refusal that dispatch already gives away.

Static text scan plus a live dispatch check — no database.
"""
# julia --project=. test/unit/test_memo_interface.jl

using Test
using PormG
using PormG.Models

import PormG.QueryBuilder: memo_key, memo_projection, memo_projection!, memo_projection_names,
                           memo_field, memo_field!, memo_json_lookup, memo_json_lookup!,
                           CTE, Joined

const MEMO_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const MEMO_SRC_DIR = joinpath(MEMO_REPO_ROOT, "src")
const MEMO_EXT_DIR = joinpath(MEMO_REPO_ROOT, "ext")
const MEMO_QB_DIR = joinpath(MEMO_SRC_DIR, "querybuilder")

# The interface itself, plus the struct that declares the fields. These two are the whole allow-list.
const MEMO_INTERFACE_FILE = joinpath(MEMO_QB_DIR, "memos.jl")
const MEMO_DECLARATION_FILE = joinpath(MEMO_QB_DIR, "types.jl")

# `.jl` is not pinned to LF in `.gitattributes`, so a Windows checkout yields CRLF. Normalize before
# matching or every assertion below becomes platform-dependent (the same reason
# `test_docs_error_type_drift.jl` carries this helper).
_memo_lines(path) = split(replace(read(path, String), "\r\n" => "\n"), '\n')

_memo_files(dir) = isdir(dir) ? sort!([joinpath(root, f)
                                       for (root, _, files) in walkdir(dir)
                                       for f in files if endswith(f, ".jl")]) : String[]

_memo_rel(path) = replace(relpath(path, MEMO_REPO_ROOT), '\\' => '/')

# Lines that are CODE, not commentary. Both filters are load-bearing: this repo documents the rules
# it enforces, so `memos.jl`, the migrated call sites and the `MemoKey` docstring all discuss
# `tab_field_cache` in prose. A guard that counted prose would flag the documentation of the rule as
# a violation of it.
#
#   - `#` lines: comment-only.
#   - triple-quoted blocks: docstrings. Tracked with a parity toggle so a one-line docstring (two
#     markers on one line) nets to zero rather than swallowing the rest of the file.
#
# ORDER IS LOAD-BEARING: comment lines are dropped BEFORE the markers are counted. Two `#` lines in
# `src/` carry an odd number of `"""` — `migrations/importers.jl` explaining how `"` is told from
# `"""`, and `migrations/introspection.jl`'s `# Example"""` — and counting those inverted the parity
# for the whole rest of each file, hiding 75% of `importers.jl` from every scan below. Measured, not
# feared: a line violating all three invariants at once sat in that dead zone and the suite stayed
# green.
#
# Counted with a regex, never by byte-slicing: `src/` is full of box-drawing rules and accented
# prose, and indexing a multi-byte line by byte offset throws `StringIndexError`.
function _memo_code_lines(path)
    out = Tuple{Int,String}[]
    in_docstring = false
    for (i, line) in enumerate(_memo_lines(path))
        startswith(strip(line), "#") && continue
        markers = length(collect(eachmatch(r"\"\"\"", line)))
        was_in = in_docstring
        isodd(markers) && (in_docstring = !in_docstring)
        (was_in || in_docstring) && continue
        push!(out, (i, line))
    end
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 1a: the two uniquely-named memos
#
# Neither name exists anywhere else in the package, so any occurrence outside the interface is a
# bypass — including one spelled `getfield(i, :tab_field_cache)`, which a plain substring match
# catches for free. `json_lookup_cache` is scanned too: it is the RETIRED name (#478 collapsed that
# `Dict` to a `Set`, because both halves of its value were dead), and a stale reference to it would
# otherwise read as "no match" — a guard that passes because the thing it looks for was renamed is
# worse than no guard.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no direct access to the uniquely-named memos" begin
    offenders = Tuple{String,Int,String}[]

    for path in vcat(_memo_files(MEMO_SRC_DIR), _memo_files(MEMO_EXT_DIR))
        (path == MEMO_INTERFACE_FILE || path == MEMO_DECLARATION_FILE) && continue
        for (lineno, line) in _memo_code_lines(path)
            if occursin("tab_field_cache", line) || occursin("json_lookup_paths", line) ||
               occursin("json_lookup_cache", line)
                push!(offenders, (_memo_rel(path), lineno, strip(line)))
            end
        end
    end

    if !isempty(offenders)
        @error "Memo fields accessed outside src/querybuilder/memos.jl (#478). Use memo_field / " *
               "memo_field! / memo_json_lookup / memo_json_lookup!." offenders
    end
    @test isempty(offenders)
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 1b: `cache` is NOT a unique name
#
# `PormGModel.cache` is a real field holding migration metadata ("unique_constraints",
# "composite_indexes", "many_to_many"), used across `src/Models.jl` and `src/migrations/`. So the
# instruction's memo cannot be found by the bare word, and two complementary patterns are needed:
#
#   - a NAMED-RECEIVER scan over all of `src/` + `ext/`, because the instruction is bound to
#     `instruc`/`instruct` everywhere in this package. This is what reaches `src/QueryBuilder.jl` —
#     the module root that includes the query builder, and the most plausible place outside
#     `src/querybuilder/` for an instruction to be touched;
#   - a BARE-DOT scan scoped to `src/querybuilder/` + `ext/`, which catches a receiver named
#     anything at all in the files that actually hold one.
#
# The single legitimate hit is pinned by EXPRESSION, not by receiver name. Allowing `m.cache`
# wholesale would hand a free pass to `m = instruc; m.cache[k]`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no direct access to the instruction's projection memo" begin
    offenders = Tuple{String,Int,String}[]
    allowed_hits = 0

    # `_cte_body_model`'s read of the MODEL's own migration metadata (`ctes.jl`) — a different field
    # on a different type that merely shares a name.
    allowed = r"get\(m\.cache, \"many_to_many\""
    named_receiver = r"\b(instruc|instruct)\.cache\b"
    bare_dot = r"\.cache\b"
    indirect = r"(getfield|getproperty|hasproperty)\([^)]*:(cache|tab_field_cache|json_lookup_paths)\b"

    for path in vcat(_memo_files(MEMO_SRC_DIR), _memo_files(MEMO_EXT_DIR))
        (path == MEMO_INTERFACE_FILE || path == MEMO_DECLARATION_FILE) && continue
        in_qb = startswith(path, MEMO_QB_DIR) || startswith(path, MEMO_EXT_DIR)
        for (lineno, line) in _memo_code_lines(path)
            # Strip the allowed OCCURRENCES, not the whole line: a line carrying both the model's
            # cache and the instruction's must still report the second one.
            allowed_hits += length(collect(eachmatch(allowed, line)))
            rest = replace(line, allowed => "")

            flagged = occursin(named_receiver, rest) || occursin(indirect, rest) ||
                      (in_qb && occursin(bare_dot, rest))
            flagged && push!(offenders, (_memo_rel(path), lineno, strip(line)))
        end
    end

    if !isempty(offenders)
        @error "Instruction projection memo accessed outside src/querybuilder/memos.jl (#478). " *
               "Use memo_projection / memo_projection! / memo_projection_names." offenders
    end
    @test isempty(offenders)
    # Pinned, not bounded: if the model-cache read moves or multiplies, this fails and the reason
    # gets re-examined rather than silently widened.
    @test allowed_hits == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 2: nobody CONSTRUCTS a key
#
# The half a field-access scan cannot see. `memo_field(instruc, (:base, path))` touches no field and
# type-checks, yet it restates the keying rule at the call site — which is the debt #478 exists to
# remove, not the `Dict` indexing that made it visible. Build keys with `memo_key`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no raw MemoKey tuple is constructed outside the interface" begin
    offenders = Tuple{String,Int,String}[]

    # Two exclusions, both earned by a false positive on the first run:
    #
    #   - `memo_key(:base, x)` is the CORRECT spelling, and its own argument list looks exactly like
    #     the literal being hunted. Consume the call's opening paren before matching, so what is left
    #     is only tuples nobody built through the interface.
    #   - the second element must not itself be a `Symbol`. A `MemoKey`'s second half is always a
    #     name; `parameters.jl`'s `_BUCKET_ORDER = (:cte, :select, …)` is an unrelated 6-tuple of
    #     bucket tags that merely opens with one of the same words.
    literal_key = r"\(\s*:(base|cte|joined)\s*,\s*[^:\s]"

    for path in vcat(_memo_files(MEMO_SRC_DIR), _memo_files(MEMO_EXT_DIR))
        path == MEMO_INTERFACE_FILE && continue
        for (lineno, line) in _memo_code_lines(path)
            rest = replace(line, r"\bmemo_key\(" => "memo_key·")
            occursin(literal_key, rest) && push!(offenders, (_memo_rel(path), lineno, strip(line)))
        end
    end

    if !isempty(offenders)
        @error "A MemoKey was built inline (#478). Use memo_key(:base|:cte|:joined, name), or " *
               "memo_key(field_or_handle)." offenders
    end
    @test isempty(offenders)
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 2, second half: nobody reads `SQLField.root` to build a key by hand
#
# The scan above finds a LITERAL namespace token. It is structurally blind to the likelier bypass —
# `memo_field(instruc, (v.root, v._as))`, which is the verbatim body of `memo_key(::SQLTypeField)`
# restated at a call site. That is the #474 defect shape exactly, it type-checks, and there is no
# `:base`/`:cte` token on the line for a regex to see. It is also what someone reproducing the
# pattern would most naturally reach for: the existing implementation, not a literal they must
# invent.
#
# So pin the `.root` readers instead. A hand-built key MUST consult `root` to get its namespace, and
# `root` is deliberately tiny surface: two writers, two rewrite carriers, the constructor, and
# `deepcopy`. Anything else is either a seventh legitimate reader — re-examined deliberately, the
# way `allowed_hits` forces — or a key being built outside the interface.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLField.root is read only by the sites entitled to it" begin
    expected = Set([
        ("src/querybuilder/build_helpers.jl", "_retag_cte_field! sets the CTE tag"),
        ("src/querybuilder/ctes.jl", "the CTE filter rewrite carries the tag through"),
        ("src/querybuilder/memos.jl", "memo_key — the constructor itself"),
        ("src/querybuilder/types.jl", "SQLField's deepcopy"),
    ])
    root_pattern = r"\.root\b"

    sites = Tuple{String,Int,String}[]
    for path in vcat(_memo_files(MEMO_SRC_DIR), _memo_files(MEMO_EXT_DIR)),
        (lineno, line) in _memo_code_lines(path)
        occursin(root_pattern, line) && push!(sites, (_memo_rel(path), lineno, strip(line)))
    end

    unexpected = filter(s -> !any(e -> e[1] == s[1], expected), sites)
    if !isempty(unexpected)
        @error "`SQLField.root` read outside the sites entitled to it (#478). If this is a memo " *
               "key, build it with `memo_key(field)` — restating `(v.root, v._as)` at a call site " *
               "is the #474 defect." unexpected
    end
    @test isempty(unexpected)
    # Pinned, not bounded — the same contract as `allowed_hits` above. Six sites today:
    # build_helpers ×2 (the two `_retag_*` writers), ctes ×2 (rewrite carriers), memos ×1, types ×1.
    @test length(sites) == 6
end

# ─────────────────────────────────────────────────────────────────────────────
# Positive control
#
# Without this, renaming a field makes every scan above vacuously green — they would find no matches
# and report success. Assert the interface really does own the names, and that the four retired key
# constructors are gone rather than merely unused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the interface owns the memo fields, and the old key helpers are gone" begin
    interface = read(MEMO_INTERFACE_FILE, String)
    @test occursin("tab_field_cache", interface)
    @test occursin("json_lookup_paths", interface)
    @test occursin(".cache", interface)
    # The scans above are only meaningful if the interface is where the keys are actually built.
    @test occursin(r"\(\s*:cte\s*,", interface)

    # The four constructors `memo_key` replaced. Their presence anywhere in `src/` would mean a
    # second way to build a key survived the migration.
    retired = ["_field_cache_key", "_cte_cache_key", "_joined_cache_key", "_join_path_key"]
    survivors = Tuple{String,Int,String}[]
    for path in _memo_files(MEMO_SRC_DIR), (lineno, line) in _memo_code_lines(path)
        for name in retired
            occursin(name, line) && push!(survivors, (_memo_rel(path), lineno, strip(line)))
        end
    end
    if !isempty(survivors)
        @error "A retired key constructor survived the #478 migration." survivors
    end
    @test isempty(survivors)
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 3: a bare-String lookup is refused by dispatch
#
# #478's acceptance criterion asserted directly, and the half a text scan cannot prove: a scan shows
# nobody bypasses the interface TODAY, while this shows the interface cannot be bypassed by accident
# tomorrow.
#
# Note the deliberate asymmetry between readers and writers. Readers accept `nothing` because
# `memo_key(::SQLTypeField)` produces one for an unnamed expression and several call sites pass it
# straight through. Writers refuse it: `build_query.jl`'s ORDER BY memo can reach a write with an
# unnamed projection, and the resulting `MethodError` is a separately-tracked leak recorded there,
# not a behaviour this refactor may quietly absorb.
# ─────────────────────────────────────────────────────────────────────────────
struct MemoMockSQLite <: PormG.PormGSQLite end
const _MEMO_SL = MemoMockSQLite()
PormG.backend_sqlite_version(::MemoMockSQLite) = 3045000

PormG.config["memo_iface_mock"] = PormG.Configuration.Settings(
  connections = _MEMO_SL,
  change_data = true,
  db_def_folder = "memo_iface_mock",
)

module MemoIfaceModels
import PormG
import PormG.Models

Mi_race = Models.Model("mi_race",
  id   = Models.IDField(),
  name = Models.CharField(),
)

Mi_result = Models.Model("mi_result",
  id     = Models.IDField(),
  raceid = Models.ForeignKey(Mi_race, on_delete = "CASCADE", related_name = "mi_results", null = true),
  points = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "memo_iface_mock")
end

const MI = MemoIfaceModels

@testset "a bare-String key is a MethodError, not a silent miss" begin
    # A real instruction, built the way every read path builds one.
    q = MI.Mi_result.objects
    q.values("id", "points")
    instruc = PormG.QueryBuilder.build(q.object; connection = _MEMO_SL)

    some_field = MI.Mi_result.fields["points"]
    # Constructed OUTSIDE the @test_throws below: a constructor that stopped resolving would
    # otherwise make those assertions pass for the wrong reason.
    some_projection = PormG.QueryBuilder.SQLField("x", "x")

    # `instruc` is a real SQLInstruction — pinned here, so a wrong first-argument type cannot be
    # what makes the refusals below pass.
    @test instruc isa PormG.QueryBuilder.SQLInstruction

    # Readers: a String has no method. This is the silent-miss class #478 closes.
    @test_throws MethodError memo_projection(instruc, "points")
    @test_throws MethodError memo_field(instruc, "points")
    @test_throws MethodError memo_json_lookup(instruc, "points")

    # Writers: a String has no method either — and neither does `nothing`, deliberately.
    @test_throws MethodError memo_field!(instruc, "points", some_field)
    @test_throws MethodError memo_projection!(instruc, nothing, some_projection)
    @test_throws MethodError memo_json_lookup!(instruc, nothing)

    # Readers accept `nothing` — the unnamed-expression case, which must stay a miss, not an error.
    @test memo_projection(instruc, nothing) === nothing
    @test memo_field(instruc, nothing) === nothing
    @test memo_json_lookup(instruc, nothing) === false

    # And a well-formed key round-trips through the verbs.
    key = memo_key(:base, "points")
    @test key isa PormG.QueryBuilder.MemoKey
    memo_field!(instruc, key, some_field)
    @test memo_field(instruc, key) === some_field
    # The namespace half discriminates: the same NAME in another namespace is a different entry.
    @test memo_field(instruc, memo_key(:cte, "points")) === nothing

    memo_json_lookup!(instruc, key)
    @test memo_json_lookup(instruc, key) === true
    @test memo_json_lookup(instruc, memo_key(:cte, "points")) === false
end

# ─────────────────────────────────────────────────────────────────────────────
# Reader/writer key agreement — the #474 defect, mechanised
#
# The invariant whose violation is SILENT: `_build_row_join` writes a resolved CTE column under
# `memo_key(:cte, join(path, "__"))`, and every reader asks for it under `memo_key(::CTEReference)`.
# If those two ever stop producing the same key the memo simply misses, the expression re-resolves,
# and in the collision case it resolves against the wrong namespace — valid SQL, wrong column. The
# end-to-end behaviour is covered in `test_cte_reference.jl`; this pins the KEYS, so a divergence
# fails here with the reason rather than there with a symptom.
# ─────────────────────────────────────────────────────────────────────────────
@testset "handle keys agree with what the join builder writes" begin
    # `_build_row_join` writes its terminal field under `memo_key(cte ? :cte : :base,
    # join(field, "__"))`, where `field` is the segment vector `_cte_join_path` lowered the handle
    # to. The right-hand side below therefore CALLS `_cte_join_path` rather than transcribing what
    # it is believed to return: hard-coding `["ev", "name"]` would pin `_cte_as`'s spelling against
    # a literal while leaving reader and writer free to drift apart together — which is the silent
    # failure this testset exists to catch. `_cte_join_path` is pure (it validates, then returns
    # `String[v.name; split(v.path, "__")]`), so no build and no #433 WITH-clause guard is involved.
    ref = CTE("ev", "name")
    @test memo_key(ref) == memo_key(:cte, join(PormG.QueryBuilder._cte_join_path(ref), "__"))

    # A deep path inside the CTE keeps agreeing — the segment vector is longer, the join is the same.
    deep = CTE("ev", "meta__driver")
    @test memo_key(deep) == memo_key(:cte, join(PormG.QueryBuilder._cte_join_path(deep), "__"))

    # #481's twin pins `_joined_as`'s spelling ONLY, and deliberately claims nothing more: there is
    # no reader/writer gap for `:joined`. `_build_row_join` writes only `:cte`/`:base`, and
    # `_resolve_joined` writes with `memo_key(ref)` — the same expression every reader reads with —
    # so the two cannot disagree by construction.
    jref = Joined("p2", "name")
    @test memo_key(jref) == memo_key(:joined, "p2__name")

    # And all three are genuinely namespaced away from the identically-spelled field path — the
    # whole reason a tuple key exists (#474). `_cte_as` fixes a CTE's output name at "<name>__<path>"
    # precisely so it collides with a field path, so only the namespace half can separate them.
    @test memo_key(ref) != memo_key(:base, "ev__name")
    @test memo_key(jref) != memo_key(:base, "p2__name")
    @test memo_key(ref) != memo_key(jref)
end

# ─────────────────────────────────────────────────────────────────────────────
# `memo_projection_names` yields the NAME half only
#
# The one accessor whose output reaches a user: `_unknown_field`'s "declared aliases" tail. The
# namespace half is internal bookkeeping, and leaking `(:cte, "ev__sku")` into an error message
# reads as a bug. `test_relation_alias_namespace.jl` asserts the message never contains a raw key;
# this asserts the accessor that feeds it, so the two fail independently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "memo_projection_names yields output names, never raw keys" begin
    q = MI.Mi_result.objects
    q.values("id", "points")
    instruc = PormG.QueryBuilder.build(q.object; connection = _MEMO_SL)

    memo_projection!(instruc, memo_key(:base, "points"), PormG.QueryBuilder.SQLField("x", "points"))
    memo_projection!(instruc, memo_key(:cte, "ev__sku"), PormG.QueryBuilder.SQLField("y", "ev__sku"))

    names = memo_projection_names(instruc)
    @test names isa Vector{String}
    @test "points" in names
    @test "ev__sku" in names
    # Not a stringified tuple, and no namespace tag anywhere in the output.
    @test !any(n -> occursin("(:base", n) || occursin("(:cte", n) || occursin("(:joined", n), names)
end
