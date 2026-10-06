"""
One relation resolver for join paths (#977).

"Which model does segment `s` reach from model `m`?" had three answers — the renderer's first hop,
`_resolve_join_target_model` (`on()`'s path, base field first) and `_relation_hop` (#962's check, `cjoin`
link first) — and #974 was two of them disagreeing: `on("grid", …)` after `cjoin("grid" => "Driver",
field = …)` was refused while the renderer joined `grid` through the link. The fix is not a reordering
but a deletion, so the rule is mechanical:

1. **`_get_join_field(` is called from `_segment_field` only.** A `cjoin` link read anywhere else is a
   second precedence in waiting.
2. **The retired resolvers stay retired.** A line of code naming one is a second copy of the rule.
3. **The resolver agrees with the renderer** on the model every path reaches — forward, short form,
   reverse, ManyToMany, a deep hop and a `cjoin` link.
4. **Binding a condition has no render side effects.** `join_conditions.jl` never calls the field-path
   walker, a render entry point or a memo: the walker ADDS joins as it resolves, which is #973.
5. **The render-time backstop holds.** A path join's condition that appends a row while rendering is
   refused, never an emitted join: by #985's column recorder when the condition names a column of the
   added row (it is never among the rows the ON clause may name), and by the backstop otherwise.

Static text scan plus a live check — no database.
"""
# julia --project=test/integration test/unit/test_join_resolver_single.jl

using Test
using PormG
using PormG.QueryBuilder: inspect_query

const JRS_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const JRS_RESOLVER_FILE = joinpath(JRS_REPO_ROOT, "src", "querybuilder", "join_conditions.jl")

# CRLF-normalized, as `test_memo_interface.jl` does: `.jl` is not pinned to LF.
_jrs_lines(path) = split(replace(read(path, String), "\r\n" => "\n"), '\n')
_jrs_files(dir) = isdir(dir) ? sort!([joinpath(root, f)
                                     for (root, _, files) in walkdir(dir)
                                     for f in files if endswith(f, ".jl")]) : String[]
_jrs_rel(path) = replace(relpath(path, JRS_REPO_ROOT), '\\' => '/')

# Code lines only — comments and docstrings discuss the rule and must not count as breaking it. Comment
# lines are dropped before `"""` markers are counted (`test_memo_interface.jl` records why).
function _jrs_code_lines(path)
    out = Tuple{Int,String}[]
    in_docstring = false
    for (i, line) in enumerate(_jrs_lines(path))
        startswith(strip(line), "#") && continue
        markers = length(collect(eachmatch(r"\"\"\"", line)))
        was_in = in_docstring
        isodd(markers) && (in_docstring = !in_docstring)
        (was_in || in_docstring) && continue
        push!(out, (i, line))
    end
    return out
end

# A CALL to `_get_join_field` — not its definition.
const JRS_LINK_READ = r"(?<!function )\b_get_join_field\("
# The one read, pinned by expression so a second read added to the resolver file is still caught.
const JRS_LINK_READ_ALLOWED = "link = _get_join_field(q, col)"
# The resolvers #977 deleted.
const JRS_RETIRED = r"\b(_resolve_join_target_model|_relation_hop|_rhs_relation_prefix)\b"

# ─────────────────────────────────────────────────────────────────────────────
# Join resolver: only `_segment_field` reads a cjoin link
# Every `_get_join_field(` call in `src/` and `ext/` is the one inside `_segment_field`, and that one is
# found exactly once — so the scan cannot pass vacuously after a rewrite moves or renames it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join resolver: a cjoin link is read in one place (#977)" begin
    offenders = Tuple{String,Int,String}[]
    allowed_hits = 0
    for dir in (joinpath(JRS_REPO_ROOT, "src"), joinpath(JRS_REPO_ROOT, "ext"))
        for path in _jrs_files(dir), (lineno, line) in _jrs_code_lines(path)
            occursin(JRS_LINK_READ, line) || continue
            if path == JRS_RESOLVER_FILE && strip(first(split(line, '#'))) == JRS_LINK_READ_ALLOWED
                allowed_hits += 1
            else
                push!(offenders, (_jrs_rel(path), lineno, String(strip(line))))
            end
        end
    end
    isempty(offenders) ||
        @error "A cjoin link is read outside _segment_field (#977). Ask _relation_step / " *
               "_segment_field instead, so every caller shares one precedence." offenders
    @test isempty(offenders)
    @test allowed_hits == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Join resolver: the retired resolvers stay retired
# `_resolve_join_target_model`, `_relation_hop` and `_rhs_relation_prefix` were the second and third
# answers to the question `_relation_step` now answers alone.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join resolver: no second resolver (#977)" begin
    offenders = Tuple{String,Int,String}[]
    for dir in (joinpath(JRS_REPO_ROOT, "src"), joinpath(JRS_REPO_ROOT, "ext"))
        for path in _jrs_files(dir), (lineno, line) in _jrs_code_lines(path)
            occursin(JRS_RETIRED, line) && push!(offenders, (_jrs_rel(path), lineno, String(strip(line))))
        end
    end
    @test isempty(offenders)
end

# ─────────────────────────────────────────────────────────────────────────────
# Join resolver: the scan patterns match what they are meant to
# Guards the guard: a regex that silently matches nothing makes both scans above pass forever.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join resolver: scan patterns (#977)" begin
    @test occursin(JRS_LINK_READ, "  field = _get_join_field(q, seg)")
    @test occursin(JRS_LINK_READ, "x = cfg === nothing ? nothing : _get_join_field(q, p)")
    @test !occursin(JRS_LINK_READ, "function _get_join_field(q::SQLObject, join_path::String)")
    @test occursin(JRS_RETIRED, "  model = _relation_hop(q, model, seg, true)")
    @test occursin(JRS_RETIRED, "target = _resolve_join_target_model(q, path)")
    @test !occursin(JRS_RETIRED, "step = _relation_step(q, model, seg, true)")
end

struct JrsMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::JrsMockSQLite) = 3045000
PormG.config["jrs_sl"] = PormG.Configuration.Settings(
  connections = JrsMockSQLite(), change_data = true, db_def_folder = "jrs_sl")

module JrsModels
import PormG
import PormG.Models
Team = Models.Model("jrs_team", teamid = Models.IDField(), name = Models.CharField())
Sponsor = Models.Model("jrs_sponsor", sponsorid = Models.IDField(), name = Models.CharField())
Driver = Models.Model("jrs_driver",
  driverid = Models.IDField(),
  number = Models.IntegerField(),
  teamid = Models.ForeignKey(Team, on_delete = "CASCADE", null = true, related_name = "drivers"),
  sponsors = Models.ManyToManyField(Sponsor, related_name = "drivers"),
)
Status = Models.Model("jrs_status", statusid = Models.IDField(), name = Models.CharField())
Result = Models.Model("jrs_result",
  resultid = Models.IDField(),
  grid = Models.IntegerField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
  status_id = Models.ForeignKey(Status, on_delete = "CASCADE", null = true, related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "jrs_sl")
end

# The table the LAST join of a statement reads — the model the projected path's final hop reached.
_jrs_last_join_table(sql) = last(collect(eachmatch(r"JOIN \"(\w+)\" AS", sql))).captures[1]

# ─────────────────────────────────────────────────────────────────────────────
# Join resolver: `_relation_step` reaches the model the renderer joins
# For each path: the model `_join_path_target` resolves must be the table the renderer joins last when
# the same path is projected. Covers a forward FK, the FK short form, a deep forward hop, a reverse
# relation, a forward and a reverse ManyToMany, and a `cjoin` link over a plain column (#974).
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join resolver: agrees with the renderer (#977)" begin
    link() = PormG.Models.ForeignKey(JrsModels.Driver, pk_field = "number", on_delete = "RESTRICT", null = true)
    cases = (
        ("forward FK",        "driverid",          "number", q -> nothing),
        ("FK short form",     "status",            "name",   q -> nothing),
        ("deep forward",      "driverid__teamid",  "name",   q -> nothing),
        ("reverse",           "driverid__results", "grid",   q -> nothing),
        ("ManyToMany",        "driverid__sponsors", "name",  q -> nothing),
        ("cjoin link (#974)", "grid",              "number", q -> q.cjoin("grid" => "Jrs_driver", warn = false, field = link())),
    )
    @testset "$label" for (label, path, col, prepare) in cases
        q = JrsModels.Result.objects
        prepare(q)
        target = PormG.QueryBuilder._join_path_target(q.object, path)
        q.values("resultid", "$(path)__$(col)")
        @test _jrs_last_join_table(inspect_query(q)[:sql_text]) == PormG.Models.model_table_name(target)
    end

    # The canonical spelling is the one `row_path` records: the short form resolves, a reverse name stays.
    q = JrsModels.Result.objects
    @test PormG.QueryBuilder._canonical_join_path(q.object, "status") == "status_id"
    @test PormG.QueryBuilder._canonical_join_path(q.object, "driverid__results") == "driverid__results"
    # A plain column is not a relation without a link, and is one with it.
    @test PormG.QueryBuilder._canonical_join_path(q.object, "grid") == ""
    q.cjoin("grid" => "Jrs_driver", warn = false, field = link())
    @test PormG.QueryBuilder._canonical_join_path(q.object, "grid") == "grid"
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: binding never resolves through the renderer
# `join_conditions.jl` binds a condition by rewriting strings against the model graph — it must never
# call the field-path walker (which ADDS joins as it resolves, #973), a render entry point, or a memo.
# A call to any of them there would make binding a render with side effects again.
# ─────────────────────────────────────────────────────────────────────────────
const JRS_RENDER_CALL = r"\b(_build_row_join|_insert_join|_get_filter_query|_get_select_query|memo_[a-z_]+!?)\("

@testset "Join conditions: binding has no render side effects (#977)" begin
    offenders = [(lineno, String(strip(line))) for (lineno, line) in _jrs_code_lines(JRS_RESOLVER_FILE)
                 if occursin(JRS_RENDER_CALL, line)]
    @test isempty(offenders)
    # Guard the guard.
    @test occursin(JRS_RENDER_CALL, "  _build_row_join(array, instruct)")
    @test occursin(JRS_RENDER_CALL, "x = memo_field!(instruc, k, f)")
    @test !occursin(JRS_RENDER_CALL, "  _join_path_columns(q, path, config)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: the render-time backstop raises on an added join
# `build_row_join_sql_text` checks that rendering a path join's condition appended no row. Exercised
# directly: a built query's own rows, with one counted as "added during the render".
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join conditions: an added join is an internal error (#977)" begin
    q = JrsModels.Result.objects
    q.values("resultid", "driverid__teamid__name")
    instruc = PormG.QueryBuilder.build(q.object; connection = JrsMockSQLite())
    rows = instruc.row_join
    @test length(rows) == 2
    # No row added: silent.
    @test PormG.QueryBuilder._assert_condition_added_no_join(instruc, rows[1], length(rows)) === nothing
    # One row added: an internal error naming it.
    err = try
        PormG.QueryBuilder._assert_condition_added_no_join(instruc, rows[1], length(rows) - 1)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("PormG internal error", err.msg)
    @test occursin("\"jrs_team\"", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: the ON-clause render refuses a condition that adds a join
# End to end through `build_row_join_sql_text`: a built query's driver row is handed a condition that
# was never bound — it names the team, one relation past the hop — and re-rendered. Unchecked, the
# render would add the team's join and carry the predicate there (#973). Since #985 the first refusal
# is the column recorder's: the team's column renders while the team's row is not among the rows the
# driver's ON clause may name, so it is refused before the backstop counts the row (tested directly
# above). Either way the join is never emitted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join conditions: the ON render refuses a condition that adds a join (#977, #985)" begin
    QB = PormG.QueryBuilder
    q = JrsModels.Result.objects
    q.values("resultid", "driverid__number")
    instruc = QB.build(q.object; connection = JrsMockSQLite())
    @test length(instruc.row_join) == 1
    unbound = QB._check_filter("driverid__teamid__name" => "X")
    instruc.row_join[1] = QB._with_config(instruc.row_join[1], nothing, QB.FilterType[unbound])
    empty!(instruc.join)
    err = try
        QB.build_row_join_sql_text(instruc)
        nothing
    catch e
        e
    end
    @test err isa PormG.FilterError
    msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
    @test occursin("is on the left side of a condition in the ON clause of \"Tb_1\"", msg)
    @test occursin("#985", msg)
    @test isempty(instruc.join)   # nothing emitted
end
