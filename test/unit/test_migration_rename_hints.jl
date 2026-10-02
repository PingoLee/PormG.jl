# =============================================================================
# Declarative rename hints, and a non-interactive run that refuses to guess (#734)
#
# A rename used to be reachable only through the interactive prompt. `interactive = false` answered
# "new" to everything, so in CI a renamed model or field became DROP + ADD and its rows were lost
# (the destructive guard caught the DROP, but the plan was still the wrong one). Two changes:
#
#   * `renames = ["old" => "new", "table.old" => "table.new"]` names the renames at the call site,
#     resolved without a question. Physical names on both sides. A stale hint (old already gone) is a
#     no-op; one that contradicts the schema raises. `"old" => nothing` says "not a rename".
#   * `interactive = false` no longer picks a side for an unhinted pair with the SAME definition: it
#     raises, listing every such pair with the hint that decides it. A pair whose definition differs
#     is still DROP + ADD. `fail_closed = false` keeps the old behavior for `check`, which reports
#     drift rather than refusing it.
#
# Hermetic: a mock PostgreSQL connection and temporary SQLite files, no live database.
# =============================================================================

using Test
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import PormG.Migrations: LiveTable, read_live_schema

# ─────────────────────────────────────────────────────────────────────────────
# Harness
# ─────────────────────────────────────────────────────────────────────────────

# Suffixed name: `runtests.jl` includes every unit file into ONE module. The catalog knows nothing,
# which is all a plan over plain columns needs.
struct RenameHintsMockPg734 <: PormGPostgres end
const RH_PG = RenameHintsMockPg734()
PormG.get_constraints_pk(::RenameHintsMockPg734, t::String, f::String) = nothing
PormG.get_constraints_unique(::RenameHintsMockPg734, t::String, f::String) = nothing
PormG.get_constraints_checks(::RenameHintsMockPg734, t::String, f::String) = String[]
PormG.get_constraints_byte_length_checks(::RenameHintsMockPg734, t::String, f::String) = String[]
fetch(::RenameHintsMockPg734, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

_rh_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)

_rh_schema(models...) = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    Symbol(Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormGModel}}(:model => m, :exist => false)
    for m in models)

# Plans with stdin at end of input: a question would raise (#726), so a plan that comes back proves
# nothing was asked.
function _rh_plan(live, schema, conn; renames = Pair{String, Union{String, Nothing}}[], interactive = true, kw...)
    return redirect_stdin(devnull) do
        redirect_stdout(devnull) do
            Migrations.get_migration_plan(live, schema, conn, _rh_settings(); interactive = interactive,
                                          renames = renames, kw...)
        end
    end
end

_rh_error(f) = try f(); nothing catch e; e end

_rh_ordered(plan) = first(Migrations._order_statements([plan[k] for k in keys(plan)]))

function _rh_apply!(pool, plan)
    fetch(pool, "PRAGMA foreign_keys = OFF;")
    for sql in _rh_ordered(plan), stmt in split(sql, ";")
        s = strip(stmt)
        isempty(s) || fetch(pool, s * ";")
    end
    return nothing
end

@testset "rename hints and fail-closed non-interactive renames (#734)" begin

    old_t = Models.Model("old_t"; id = Models.IDField(), n = Models.IntegerField())
    new_t = Models.Model("new_t"; id = Models.IDField(), n = Models.IntegerField())

    # ─────────────────────────────────────────────────────────────────────────
    # A hint renames without a question
    # ─────────────────────────────────────────────────────────────────────────
    @testset "a table hint renames, and nothing is asked" begin
        plan = _rh_plan(PormGModel[old_t], _rh_schema(new_t), RH_PG; renames = ["old_t" => "new_t"])
        @test plan[:new_t]["Rename table"] == "ALTER TABLE \"old_t\" RENAME TO \"new_t\";"
        @test !haskey(plan, :old_t)
        # The same under interactive = false: a hint is not a guess, so nothing fails closed.
        plan = _rh_plan(PormGModel[old_t], _rh_schema(new_t), RH_PG; renames = ["old_t" => "new_t"], interactive = false)
        @test plan[:new_t]["Rename table"] == "ALTER TABLE \"old_t\" RENAME TO \"new_t\";"
    end

    @testset "a column hint renames, and nothing is asked" begin
        livem    = Models.Model("tbl_t"; id = Models.IDField(), a = Models.IntegerField(), b = Models.IntegerField())
        declared = Models.Model("tbl_t"; id = Models.IDField(), a = Models.IntegerField(), m = Models.IntegerField())
        for interactive in (true, false)
            plan = _rh_plan(PormGModel[livem], _rh_schema(declared), RH_PG; renames = ["tbl_t.b" => "tbl_t.m"],
                            interactive = interactive)
            @test collect(keys(plan[:tbl_t])) == ["Rename field: m"]
            @test plan[:tbl_t]["Rename field: m"] == "ALTER TABLE \"tbl_t\" RENAME COLUMN \"b\" TO \"m\";"
        end
    end

    # A hinted column of a hinted table: the column hint names the table by its NEW name.
    @testset "a column hint on a renamed table names the table by its new name" begin
        livem    = Models.Model("old_t"; id = Models.IDField(), n = Models.IntegerField())
        declared = Models.Model("new_t"; id = Models.IDField(), m = Models.IntegerField())
        plan = _rh_plan(PormGModel[livem], _rh_schema(declared), RH_PG; interactive = false,
                        renames = ["old_t" => "new_t", "new_t.n" => "new_t.m"])
        @test plan[:new_t]["Rename table"] == "ALTER TABLE \"old_t\" RENAME TO \"new_t\";"
        @test plan[:new_t]["Rename field: m"] == "ALTER TABLE \"new_t\" RENAME COLUMN \"n\" TO \"m\";"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Resolution rules
    # A stale hint — the rename already ran — does nothing, so a hint list can stay in a script. Every
    # hint that contradicts the schema raises instead of being ignored.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "a stale hint is a no-op" begin
        @test isempty(_rh_plan(PormGModel[new_t], _rh_schema(new_t), RH_PG; interactive = false,
                               renames = ["old_t" => "new_t", "new_t.gone" => "new_t.n"]))
    end

    @testset "a hint that contradicts the schema raises" begin
        cases = [
            # both tables exist
            (PormGModel[old_t, Models.Model("new_t"; id = Models.IDField(), n = Models.IntegerField())],
             _rh_schema(new_t), ["old_t" => "new_t"], "both tables exist"),
            # the old table is still declared, so it is not being removed
            (PormGModel[old_t], _rh_schema(old_t, new_t), ["old_t" => "new_t"], "not being removed"),
            # the new table is not declared
            (PormGModel[old_t], _rh_schema(new_t), ["old_t" => "newer_t"], "no declared model"),
            # a column hint naming an undeclared table
            (PormGModel[old_t], _rh_schema(new_t), ["old_t.n" => "old_t.m", "old_t" => "new_t"], "no declared model"),
            # both columns exist
            (PormGModel[Models.Model("tbl_t"; id = Models.IDField(), a = Models.IntegerField(), m = Models.IntegerField())],
             _rh_schema(Models.Model("tbl_t"; id = Models.IDField(), m = Models.IntegerField())),
             ["tbl_t.a" => "tbl_t.m"], "both columns exist"),
            # the old column is still declared
            (PormGModel[Models.Model("tbl_t"; id = Models.IDField(), a = Models.IntegerField())],
             _rh_schema(Models.Model("tbl_t"; id = Models.IDField(), a = Models.IntegerField(), m = Models.IntegerField())),
             ["tbl_t.a" => "tbl_t.m"], "not being removed"),
            # the new column is not declared
            (PormGModel[Models.Model("tbl_t"; id = Models.IDField(), a = Models.IntegerField())],
             _rh_schema(Models.Model("tbl_t"; id = Models.IDField(), m = Models.IntegerField())),
             ["tbl_t.a" => "tbl_t.x"], "declares no column"),
        ]
        for (live, schema, renames, needle) in cases
            err = _rh_error(() -> _rh_plan(live, schema, RH_PG; renames = renames, interactive = false))
            @test err isa PormG.InvalidMigrationError
            @test err !== nothing && occursin("Invalid `renames` hint", err.msg) && occursin(needle, err.msg)
        end
    end

    @testset "a malformed hint raises before anything is planned" begin
        for renames in (["old_t" => 1], ["old_t"], ["t.a" => "u.a"], ["t.a" => "b"], ["t" => "u.b"],
                        ["old_t" => "a", "old_t" => "b"], ["a" => "new_t", "b" => "new_t"],
                        ["t.a" => "t.c", "t.b" => "t.c"])
            err = _rh_error(() -> _rh_plan(PormGModel[old_t], _rh_schema(new_t), RH_PG; renames = renames))
            @test err isa PormG.InvalidMigrationError
            @test err !== nothing && occursin("Invalid `renames` hint", err.msg)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # interactive = false fails closed on a same-definition pair
    # It used to plan DROP + ADD for these. Both are listed in one error, each with its hint.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "interactive = false refuses an unhinted same-definition pair, table and column" begin
        live_tbl = Models.Model("tbl_t"; id = Models.IDField(), b = Models.IntegerField())
        decl_tbl = Models.Model("tbl_t"; id = Models.IDField(), m = Models.IntegerField())
        err = _rh_error(() -> _rh_plan(PormGModel[old_t, live_tbl], _rh_schema(new_t, decl_tbl), RH_PG; interactive = false))
        @test err isa PormG.InvalidMigrationError
        @test err !== nothing && occursin("will not guess a rename", err.msg)
        @test err !== nothing && occursin("\"old_t\" => \"new_t\" to rename, or \"old_t\" => nothing", err.msg)
        @test err !== nothing && occursin("\"tbl_t.b\" => \"tbl_t.m\" to rename, or \"tbl_t.b\" => nothing", err.msg)
    end

    @testset "a `=> nothing` hint plans the drop and the add" begin
        live_tbl = Models.Model("tbl_t"; id = Models.IDField(), b = Models.IntegerField())
        decl_tbl = Models.Model("tbl_t"; id = Models.IDField(), m = Models.IntegerField())
        plan = _rh_plan(PormGModel[old_t, live_tbl], _rh_schema(new_t, decl_tbl), RH_PG; interactive = false,
                        renames = ["old_t" => nothing, "tbl_t.b" => nothing])
        @test haskey(plan[:old_t], "Drop table")
        @test haskey(plan[:new_t], "New model")
        @test haskey(plan[:tbl_t], "Add field: m") && haskey(plan[:tbl_t], "Remove field: b")
        # Interactive too: the dropped candidate is offered to no question, so none is asked.
        plan = _rh_plan(PormGModel[old_t, live_tbl], _rh_schema(new_t, decl_tbl), RH_PG;
                        renames = ["old_t" => nothing, "tbl_t.b" => nothing])
        @test haskey(plan[:old_t], "Drop table") && haskey(plan[:tbl_t], "Remove field: b")
    end

    @testset "a pair whose definition differs is still drop + add" begin
        live_tbl = Models.Model("tbl_t"; id = Models.IDField(), b = Models.IntegerField())
        decl_tbl = Models.Model("tbl_t"; id = Models.IDField(), m = Models.CharField(max_length = 20))
        other_t  = Models.Model("other_t"; id = Models.IDField(), label = Models.CharField(max_length = 20))
        plan = _rh_plan(PormGModel[old_t, live_tbl], _rh_schema(other_t, decl_tbl), RH_PG; interactive = false)
        @test haskey(plan[:old_t], "Drop table") && haskey(plan[:other_t], "New model")
        @test haskey(plan[:tbl_t], "Add field: m") && haskey(plan[:tbl_t], "Remove field: b")
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Found in review
    # ─────────────────────────────────────────────────────────────────────────

    # A hint's old column is claimed before any field is processed. `a` comes first and has `b`'s
    # definition; without the claim it was refused against `b` (and offered `b` interactively),
    # although the hint already gives `b` to `m` — and `"tbl_t.b" => nothing` could not fix that.
    @testset "a hinted old column is offered to no other field" begin
        livem    = Models.Model("tbl_t"; id = Models.IDField(), b = Models.IntegerField())
        declared = Models.Model("tbl_t"; id = Models.IDField(), a = Models.IntegerField(), m = Models.IntegerField())
        for interactive in (false, true)
            plan = _rh_plan(PormGModel[livem], _rh_schema(declared), RH_PG; renames = ["tbl_t.b" => "tbl_t.m"],
                            interactive = interactive)
            @test plan[:tbl_t]["Rename field: m"] == "ALTER TABLE \"tbl_t\" RENAME COLUMN \"b\" TO \"m\";"
            @test haskey(plan[:tbl_t], "Add field: a")
        end
    end

    # The hinted renames apply before any table is checked. `race_result_t` sorts before
    # `race_status_t`, so its key used to be compared against the OLD parent name, read as changed,
    # and the vanished `result_t` was dropped without a word — even after the user hinted the parent.
    @testset "a child of a hinted parent is checked against the parent's new name" begin
        status_live = Models.Model("status_t"; id = Models.IDField(), label = Models.CharField(max_length = 20))
        result_live = Models.Model("result_t"; id = Models.IDField(), points = Models.IntegerField(),
                                   statusid = Models.ForeignKey("Status_t"; pk_field = "id"))
        result_live.fields["statusid"].to_table = "status_t"
        race_status = Models.Model("race_status_t"; id = Models.IDField(), label = Models.CharField(max_length = 20))
        race_result = Models.Model("race_result_t"; id = Models.IDField(), points = Models.IntegerField(),
                                   statusid = Models.ForeignKey(race_status; pk_field = "id"))
        err = _rh_error(() -> _rh_plan(PormGModel[status_live, result_live], _rh_schema(race_status, race_result), RH_PG;
                                       interactive = false, renames = ["status_t" => "race_status_t"]))
        @test err isa PormG.InvalidMigrationError
        @test err !== nothing && occursin("\"result_t\" => \"race_result_t\" to rename", err.msg)
        # Both hinted: both renamed, nothing dropped.
        plan = _rh_plan(PormGModel[status_live, result_live], _rh_schema(race_status, race_result), RH_PG;
                        interactive = false, renames = ["status_t" => "race_status_t", "result_t" => "race_result_t"])
        @test haskey(plan[:race_status_t], "Rename table") && haskey(plan[:race_result_t], "Rename table")
        @test !any(k -> haskey(plan[k], "Drop table"), collect(keys(plan)))
    end

    # A hint whose old AND new names are both missing is more likely a typo than history: it warns,
    # where a hint already applied (new name present) stays silent.
    @testset "a hint naming neither table warns" begin
        other = Models.Model("other_t"; id = Models.IDField(), label = Models.CharField(max_length = 20))
        @test_logs (:warn, r"check the old name") match_mode = :any begin
            plan = _rh_plan(PormGModel[old_t], _rh_schema(other), RH_PG; interactive = false, renames = ["olde_t" => "other_t"])
            @test haskey(plan[:old_t], "Drop table") && haskey(plan[:other_t], "New model")
        end
        @test_logs min_level = Base.CoreLogging.Warn _rh_plan(PormGModel[new_t], _rh_schema(new_t), RH_PG;
                                                              interactive = false, renames = ["old_t" => "new_t"])
        # The column rule is the same, one level down.
        livem    = Models.Model("tbl_t"; id = Models.IDField(), b = Models.IntegerField())
        declared = Models.Model("tbl_t"; id = Models.IDField(), m = Models.CharField(max_length = 20))
        @test_logs (:warn, r"check the old name") match_mode = :any begin
            plan = _rh_plan(PormGModel[livem], _rh_schema(declared), RH_PG; interactive = false, renames = ["tbl_t.typo" => "tbl_t.m"])
            @test haskey(plan[:tbl_t], "Add field: m") && haskey(plan[:tbl_t], "Remove field: b")
        end
    end

    # A model declaring only its key matches every key-only table, so that match says nothing: it is
    # planned as before. Found by `test_plan_schema_fingerprint.jl`, whose new model is `id` alone.
    @testset "a key-only model is not refused" begin
        gone  = Models.Model("scratch_t"; id = Models.IDField())
        fresh = Models.Model("fresh_t"; id = Models.IDField())
        plan = _rh_plan(PormGModel[gone], _rh_schema(fresh), RH_PG; interactive = false)
        @test haskey(plan[:scratch_t], "Drop table") && haskey(plan[:fresh_t], "New model")
    end

    # `check(kinds = [:schema_drift])` plans with `fail_closed = false`: drift is reported, not refused.
    @testset "fail_closed = false keeps the drop + add" begin
        plan = _rh_plan(PormGModel[old_t], _rh_schema(new_t), RH_PG; interactive = false, fail_closed = false)
        @test haskey(plan[:old_t], "Drop table") && haskey(plan[:new_t], "New model")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite, applied: hints alone rename a table, a retyped column and a join table, and keep the rows
# The CI case the issue was filed for: `interactive = false`, no stdin, a model renamed together with
# its many-to-many join table (#735 follows it) and a column renamed and widened in the same plan.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: hints rename under interactive = false and keep every row (#734)" begin
    mktempdir() do dir
        pool = SQLiteConnectionPool(joinpath(dir, "rh734.sqlite"); pool_size = 1)
        try
            driver  = Models.Model("driver_t"; id = Models.IDField(), name = Models.CharField(max_length = 20))
            team_v1 = Models.Model("team_t"; id = Models.IDField(), wins = Models.IntegerField(),
                                   drivers = Models.ManyToManyField(driver))
            _rh_apply!(pool, Migrations.get_migration_plan(LiveTable[], _rh_schema(driver, team_v1), pool,
                                                          _rh_settings(); interactive = false))
            fetch(pool, """INSERT INTO "driver_t" ("id", "name") VALUES (1, 'Senna')""")
            fetch(pool, """INSERT INTO "team_t" ("id", "wins") VALUES (1, 15)""")
            fetch(pool, """INSERT INTO "team_t_drivers" ("id", "team_t_id", "driver_t_id") VALUES (1, 1, 1)""")

            team_v2 = Models.Model("squad_t"; id = Models.IDField(), victories = Models.BigIntegerField(),
                                   drivers = Models.ManyToManyField(driver))
            schema_v2 = _rh_schema(driver, team_v2)
            renames = ["team_t" => "squad_t", "squad_t.wins" => "squad_t.victories"]

            # Without the hints this is NOT refused: `team_t` lacks `victories`, so it is no
            # same-definition table, and the plan is the old drop + create, which the destructive guard
            # stops at `migrate`. The hints are what make it a rename.
            plan = _rh_plan(read_live_schema(pool), schema_v2, pool; interactive = false, renames = renames)
            @test plan[:squad_t]["Rename table"] == "ALTER TABLE \"team_t\" RENAME TO \"squad_t\";"
            @test haskey(plan[:squad_t], "Rename field: victories")
            @test plan[:squad_t_drivers]["Rename table"] == "ALTER TABLE \"team_t_drivers\" RENAME TO \"squad_t_drivers\";"
            @test !any(k -> haskey(plan[k], "Drop table"), collect(keys(plan)))

            _rh_apply!(pool, plan)
            @test (fetch(pool, """SELECT "victories" FROM "squad_t" """) |> DataFrame).victories == [15]
            @test (fetch(pool, """SELECT "squad_t_id" FROM "squad_t_drivers" """) |> DataFrame).squad_t_id == [1]

            # Converged — and the hints, now stale, still plan nothing.
            @test isempty(_rh_plan(read_live_schema(pool), schema_v2, pool; interactive = false, renames = renames))
        finally
            close_pool!(pool)
        end
    end
end
