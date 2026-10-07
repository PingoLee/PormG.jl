"""
The join-condition column recorder (#985).

PR #981's render-time backstop closes "a condition silently ADDED a join". Its neighbour is "a column
silently names the WRONG row, and no join is added" — #961's shape: a left-side node the lowering does
not descend into stays on the base alias, renders as valid SQL, and compares the wrong column. The
defence used to be walkers alone, each enumerating every node type a column can hide in, and #981
closed four gaps in one of them a day after it merged.

So every model column now becomes `"alias"."col"` in ONE place, `_column_sql`, which checks it against
the rows the ON clause being rendered may name (`_record_join_column`): the left side of a comparison
names the joined row; everything else the base row, an earlier table on the path, or the joined row.
The rules this file pins:

1. **One emitting site.** No `src/`/`ext/` code builds `"alias"."col"` outside `_column_sql`.
2. **A walker gap is caught.** Each mutant below re-opens a gap the walkers close; the recorder refuses
   the column it leaves on the wrong row, with no walker involved.
3. **A memoized column is checked too.** A path projected before the ON clause renders is rendered
   afresh there, not reused unchecked.
4. **The nested-side rule (decided on #985).** A comparison nested in a LEFT side splits again — its
   column left, its values right. Inside a RIGHT side every column stays right (#975).
5. **Legal cells render unchanged** — `test_join_condition_matrix.jl` holds that, byte for byte.

Static text scan plus live checks on mock connections — no database.
"""
# julia --project=test/integration test/unit/test_join_column_recorder.jl

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Case, When, Exists, OuterRef, Joined
using PormG.Functions: Abs

const JCR_QB = PormG.QueryBuilder
const JCR_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const JCR_HELPER_FILE = joinpath(JCR_REPO_ROOT, "src", "querybuilder", "join_conditions.jl")

# CRLF-normalized, as `test_memo_interface.jl` does: `.jl` is not pinned to LF.
_jcr_lines(path) = split(replace(read(path, String), "\r\n" => "\n"), '\n')
_jcr_files(dir) = isdir(dir) ? sort!([joinpath(root, f)
                                     for (root, _, files) in walkdir(dir)
                                     for f in files if endswith(f, ".jl")]) : String[]
_jcr_rel(path) = replace(relpath(path, JCR_REPO_ROOT), '\\' => '/')

# Code lines only — comment lines are dropped before `"""` markers are counted, then docstring bodies
# are skipped (`test_memo_interface.jl` records why that order matters).
function _jcr_code_lines(path)
    out = Tuple{Int,String}[]
    in_docstring = false
    for (i, line) in enumerate(_jcr_lines(path))
        startswith(strip(line), "#") && continue
        markers = length(collect(eachmatch(r"\"\"\"", line)))
        was_in = in_docstring
        isodd(markers) && (in_docstring = !in_docstring)
        (was_in || in_docstring) && continue
        push!(out, (i, line))
    end
    return out
end

# A column reference assembled by hand: `string(quote_identifier(…), ".", …)` or the same over a
# variable holding a quoted alias. The JOIN key anchor (`"$alias_a_quoted.$key_a_quoted = …"`) is not
# a condition column and does not match.
const JCR_EMIT = r"string\(\s*(quote_identifier\(|quoted_\w+\s*,)[^\n]*\"\.\""
const JCR_EMIT_ALLOWED = "return string(quote_identifier(alias, instruc.connection), \".\", column_sql)"

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: one place builds "alias"."col"
# Every `"alias"."col"` construction in `src/` and `ext/` is the one inside `_column_sql`, and that one
# is found exactly once — so the scan cannot pass vacuously after a rewrite moves or renames it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: one emitting site (#985)" begin
    offenders = Tuple{String,Int,String}[]
    allowed_hits = 0
    for dir in (joinpath(JCR_REPO_ROOT, "src"), joinpath(JCR_REPO_ROOT, "ext"))
        for path in _jcr_files(dir), (lineno, line) in _jcr_code_lines(path)
            occursin(JCR_EMIT, line) || continue
            if path == JCR_HELPER_FILE && strip(first(split(line, '#'))) == JCR_EMIT_ALLOWED
                allowed_hits += 1
            else
                push!(offenders, (_jcr_rel(path), lineno, String(strip(line))))
            end
        end
    end
    isempty(offenders) ||
        @error "A model column is rendered as \"alias\".\"col\" outside _column_sql (#985). Call " *
               "_column_sql(instruc, alias, column_sql), so the join-condition recorder sees it." offenders
    @test isempty(offenders)
    @test allowed_hits == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: the scan pattern matches what it is meant to
# Guards the guard: a regex that silently matches nothing makes the scan above pass forever.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: scan pattern (#985)" begin
    @test occursin(JCR_EMIT, "  col = string(quote_identifier(alias, conn), \".\",")
    @test occursin(JCR_EMIT, "    return string(quoted_alias, \".\", _solve_field(v, m, instruc))")
    @test occursin(JCR_EMIT, JCR_EMIT_ALLOWED)
    @test !occursin(JCR_EMIT, "      return string(quote_identifier(instruc.alias, instruc.connection), \".*\")")
    @test !occursin(JCR_EMIT, "  return _column_sql(instruc, ref.alias, col)")
    @test !occursin(JCR_EMIT, "      on_clause = \"\$alias_a_quoted.\$key_a_quoted = \$alias_b_quoted.\$key_b_quoted\"")
end

struct JcrMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::JcrMockSQLite) = 3045000
PormG.config["jcr_sl"] = PormG.Configuration.Settings(
  connections = JcrMockSQLite(), change_data = true, db_def_folder = "jcr_sl")

# `Result` and `Driver` both carry `number`, so a column on the wrong row is visible in the SQL; `grid`
# is a `Result` column `Driver` does not have, so a base-row column cannot pass for the joined row's.
module JcrModels
import PormG
import PormG.Models
Constructor = Models.Model("jcr_constructor", constructorid = Models.IDField(), name = Models.CharField())
Driver = Models.Model("jcr_driver",
  driverid = Models.IDField(),
  code = Models.CharField(),
  number = Models.IntegerField(),
)
Result = Models.Model("jcr_result",
  resultid = Models.IDField(),
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  note = Models.CharField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
  constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", null = true, related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "jcr_sl")
end

_jcr_no_ansi(s) = replace(s, r"\e\[[0-9;]*m" => "")
_jcr_msg(e) = _jcr_no_ansi(sprint(showerror, e))
# `invokelatest`, so a mutant method defined in this testset's toplevel is the one that runs (#211's
# world-age rule: a method added mid-block is invisible to code already running in the older world).
_jcr_sql(q) = Base.invokelatest(inspect_query, q)[:sql_text]
_jcr_err(q) = try _jcr_sql(q); nothing catch e; e end

# Define a mutant method, run `body`, then delete exactly the methods the mutant added — never the real
# one it shadows (`methods(f, types)` would also match the real, less specific arm). A method with
# keyword arguments adds a second one to `Core.kwcall`, which is what a call passing `base = …`
# dispatches through, so both tables are snapshotted.
function _jcr_with_mutant(body, define::Function, fn::Function)
    tables = (fn, Core.kwcall)
    before = [Set(methods(t)) for t in tables]
    define()
    added = reduce(vcat, [collect(setdiff(Set(methods(t)), b)) for (t, b) in zip(tables, before)])
    try
        # Inside the `try`, so a failed check still deletes what was added: a mutant left behind would
        # run in every later file of the one-process suite.
        @assert 1 <= length(added) <= 2 "a mutant adds its method, and its kwcall method if it takes keywords"
        return body()
    finally
        foreach(Base.delete_method, added)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: a lowering gap on the left side is refused (mutant a)
# `on("driverid", Abs(F("number")) > 0)` names the DRIVER's number: the lowering prefixes the column
# inside the function (`_prefix_join_column`'s `FObject` arm). Without that arm the column stays on the
# base row and renders `ABS("Tb"."number") > 0` — valid SQL comparing the result's number, which no
# walker notices: `_refuse_lhs_past_hop` looks for a relation PAST the hop, and the left side is not the
# right-side walks' business. The recorder sees the left side naming "Tb" and refuses.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: a missing lowering arm is caught on the left (#985)" begin
    build() = (q = JcrModels.Result.objects; q.on("driverid", Abs(F("number")) > 0);
               q.values("resultid", "driverid__code"); q)
    # Control: with the arm, the function's column is the driver's.
    @test occursin("ABS(\"Tb_1\".\"number\")", _jcr_sql(build()))

    # The mutant: a more specific method that returns the node unlowered, shadowing the real arm.
    define() = @eval JCR_QB function _prefix_join_column(x::FObject, prefix::String, foreign_model::PormGModel; base = nothing)
        return x
    end
    _jcr_with_mutant(define, JCR_QB._prefix_join_column) do
        err = _jcr_err(build())
        @test err isa PormG.FilterError
        msg = _jcr_msg(err)
        @test occursin("\"Tb\".\"number\" is on the left side", msg)
        @test occursin("#985", msg)
    end
    # The real arm is back.
    @test occursin("ABS(\"Tb_1\".\"number\")", _jcr_sql(build()))
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: a right-side walker gap is refused (mutant b)
# #981 closed #962's `Exists` gap: `Q(Exists(…OuterRef("constructorid__name")))` in the driver join's ON
# clause names the CONSTRUCTOR, a relation off the path. Re-open that gap — skip `Exists` in the walk —
# and nothing at binding refuses it. The recorder does, at the `OuterRef`, which resolves in this
# statement and so is checked as a right-side column of the driver join.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: a re-opened #962 gap is caught without the walker (#985)" begin
    build() = (q = JcrModels.Result.objects;
               q.on("driverid", Q(Exists(JcrModels.Constructor.objects.filter("name" => OuterRef("constructorid__name")))));
               q.values("resultid", "driverid__code"); q)
    # Control: the walker refuses it at binding, as #962.
    err = _jcr_err(build())
    @test err isa PormG.FilterError
    @test occursin("#962", _jcr_msg(err))

    define() = @eval JCR_QB _off_path_rhs_condition(f::ExistsObject, q::SQLObject, path::String, depth::Int) = nothing
    _jcr_with_mutant(define, JCR_QB._off_path_rhs_condition) do
        err = _jcr_err(build())
        @test err isa PormG.FilterError
        msg = _jcr_msg(err)
        @test occursin("#985", msg)
        @test !occursin("#962", msg)
        @test occursin("in the ON clause of \"Tb_1\"", msg)
    end
    @test occursin("#962", _jcr_msg(_jcr_err(build())))
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: a cjoin_on ON clause names only rows emitted before it (mutant c)
# Binding emits each alias after the aliases it names (#982). Swap two already-ordered rows — the
# state a wrong emission order would leave — and re-render: the second alias's ON clause now names a
# row that has not appeared yet, and the recorder refuses it rather than emitting the forward reference.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: a forward cjoin_on reference is caught (#985)" begin
    q = JcrModels.Result.objects
    q.cjoin_on("Driver", alias = "d1", on = [Joined("d1", "driverid") == F("driverid")])
    q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "number") == Joined("d1", "number")])
    q.values("resultid")
    instruc = JCR_QB.build(q.object; connection = JcrMockSQLite())
    @test [r.alias_b for r in instruc.row_join] == ["d1", "d2"]
    # In order, it renders.
    empty!(instruc.join)
    JCR_QB.build_row_join_sql_text(instruc)
    @test occursin("ON (\"d2\".\"number\" = \"d1\".\"number\")", join(instruc.join))
    # Out of order, `d2`'s ON clause names `d1` before `d1` is joined.
    instruc.row_join[1], instruc.row_join[2] = instruc.row_join[2], instruc.row_join[1]
    empty!(instruc.join)
    err = try JCR_QB.build_row_join_sql_text(instruc); nothing catch e; e end
    @test err isa PormG.FilterError
    @test occursin("in the ON clause of \"d2\" names \"d1\"", _jcr_msg(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: a memoized column is checked, not reused unchecked
# `values("number")` memoizes the base row's `"Tb"."number"`. A condition left on the base row by a
# lowering gap would find that memo and reuse the text, which never passed the recorder. Inside an ON
# clause the column renders afresh instead, so it is checked. White-box: the row is handed an unlowered
# condition, the shape a gap leaves, after a normal build.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: a memoized column is rendered and checked (#985)" begin
    q = JcrModels.Result.objects
    q.values("resultid", "number", "driverid__code")
    instruc = JCR_QB.build(q.object; connection = JcrMockSQLite())
    @test JCR_QB.memo_projection(instruc, JCR_QB.memo_key(:base, "number")) !== nothing
    unlowered = JCR_QB._check_filter("number" => 5)   # should have been "driverid__number"
    instruc.row_join[1] = JCR_QB._with_config(instruc.row_join[1], nothing, JCR_QB.FilterType[unlowered])
    empty!(instruc.join)
    err = try JCR_QB.build_row_join_sql_text(instruc); nothing catch e; e end
    @test err isa PormG.FilterError
    @test occursin("\"Tb\".\"number\" is on the left side", _jcr_msg(err))

    # The same column on the RIGHT is legal (the base row), memoized or not.
    q2 = JcrModels.Result.objects
    q2.values("resultid", "number", "driverid__code")
    q2.on("driverid", "number" => F("number"))
    @test occursin("\"Tb_1\".\"number\" = \"Tb\".\"number\"", _jcr_sql(q2))
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: the side of a nested comparison (decided on #985)
# A comparison nested in a LEFT side splits again: `Case(When(F("number") > F("grid")))` on the left
# compares the driver's number (lowered onto the hop) with the RESULT's grid — the base row, a legal
# right side. Inside a RIGHT side every column stays right (#975), so a `When` column there may name
# the base row too. These are the two readings the rule had to choose between; the matrix holds every
# other legal cell.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: a nested comparison's sides (#985)" begin
    left = JcrModels.Result.objects
    left.on("driverid", Case(When(F("number") > F("grid"), then = 1), default = 0) > 0)
    left.values("resultid", "driverid__code")
    @test occursin("\"Tb_1\".\"number\" > \"Tb\".\"grid\"", _jcr_sql(left))

    right = JcrModels.Result.objects
    right.on("driverid", "number" => Case(When("grid" => 1, then = 1), default = 0))
    right.values("resultid", "driverid__code")
    @test occursin("\"Tb\".\"grid\" = ", _jcr_sql(right))
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: every operator's right side may name the base row
# Each lookup family renders its right side through its own arm, and each arm must render it as the
# RIGHT side. One arm that does not checks a base-row `F(...)` against the hop alone and refuses a legal
# condition — the network lookups did, in review of #985. Swept here so a new arm cannot repeat it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: a base-row right side in every lookup family (#985)" begin
    shapes = (
        "number" => F("number"), "number__@gt" => F("number"), "number__@gte" => F("number"),
        "number__@lt" => F("number"), "number__@lte" => F("number"), "number__@ne" => F("number"),
        # A pattern lookup (`@contains`, `@startswith`, …) takes a text value, never a column, so it is
        # not in the sweep; `@iexact` takes either.
        "code" => F("note"), "code__@iexact" => F("note"),
    )
    for cond in shapes
        @testset "$(cond.first)" begin
            q = JcrModels.Result.objects
            q.on("driverid", cond)
            q.values("resultid", "driverid__code")
            sql = _jcr_sql(q)
            @test occursin("\"Tb\".\"$(cond.second.column)\"", sql)   # the base row, on the right
            @test occursin("\"Tb_1\".\"$(first(split(cond.first, "__@")))\"", sql)   # the hop, on the left
        end
    end
end

struct JcrMockPostgres <: PormG.PormGPostgres end
PormG.config["jcr_pg"] = PormG.Configuration.Settings(
  connections = JcrMockPostgres(), change_data = true, db_def_folder = "jcr_pg")

# Network columns are refused on SQLite by default, so the network lookups render on PostgreSQL only.
module JcrNetModels
import PormG
import PormG.Models
Session = Models.Model("jcr_session", sessionid = Models.IDField(), client_ip = Models.GenericIPAddressField())
Badge = Models.Model("jcr_badge",
  badgeid = Models.IDField(),
  badge_net = Models.CIDRField(),
  session = Models.ForeignKey(Session, on_delete = "CASCADE", related_name = "badges"),
)
PormG.Models.set_models(@__MODULE__, "jcr_pg")
end

# ─────────────────────────────────────────────────────────────────────────────
# Join-column recorder: a network lookup's right side names the base row (#985 review)
# `on("session", "client_ip__@net_contained" => F("badge_net"))` asks whether the session's address
# lies inside the badge's network: the badge is the base row, on the right. The network arm rendered
# that column without marking it as the right side, so the recorder checked it against the hop and
# refused a legal condition.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Join-column recorder: a network lookup's right side (#985)" begin
    q = JcrNetModels.Badge.objects
    q.on("session", "client_ip__@net_contained" => F("badge_net"))
    q.values("badgeid", "session__client_ip")
    sql = _jcr_sql(q)
    @test occursin("\"Tb_1\".\"client_ip\" << \"Tb\".\"badge_net\"", sql)
end
