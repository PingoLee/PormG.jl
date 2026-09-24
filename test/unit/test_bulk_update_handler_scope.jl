# ============================================================
# test/unit/test_bulk_update_handler_scope.jl
#
# bulk_update honors the handler's scope and never writes to the handler (#665).
#
# CONTRACT being tested:
#   `bulk_update(q, df; match_on, filters)` builds its statement from a private copy of `q`. The
#   filters already attached to `q` are part of the statement's scope, AND'd with the per-row
#   `match_on=` condition and the constant `filters=` predicates — the Django shape
#   (`queryset.filter(pk__in=…).update(…)`) and what `update()` / `delete()` already do. `q` itself
#   is left exactly as the caller built it. Handler state an UPDATE cannot express (limit, offset,
#   order_by, distinct, aggregates, a CTE, a cjoin) raises `UnsafeMutationError` instead of being
#   dropped, because every one of those drops widens the statement past what the caller scoped.
#
#   Before #665 the handler's filters were cleared IN PLACE: a handler scoped to `year = 1988`
#   updated matching rows of every year, and afterwards carried `bulk_update`'s `filters=` instead
#   of its own.
#
# Deterministic and DB-free: mock PostgreSQL and SQLite connections; `show_query = :dict` returns
# each chunk's prepared statement before any driver call.
# ============================================================

using Test
using PormG
using PormG.QueryBuilder: bulk_update, Qor, Count, Value
import DataFrames

# Dedicated mocks and config keys so this file cannot contaminate (or be contaminated by) other
# unit files sharing Main in runtests.jl. `db_def_folder` names the key itself, so `set_models`
# resolves the in-memory entry instead of looking for a folder on disk.
struct BulkHandlerScopeMockPg <: PormG.PormGPostgres end
struct BulkHandlerScopeMockSl <: PormG.PormGSQLite end
# The chunk cap reads the SQLite version for its bind-parameter limit; a modern build (32766).
PormG.backend_sqlite_version(::BulkHandlerScopeMockSl) = 3045000
PormG.config["bh665_pg"] = PormG.Configuration.Settings(
    connections = BulkHandlerScopeMockPg(), change_data = true, db_def_folder = "bh665_pg")
PormG.config["bh665_sl"] = PormG.Configuration.Settings(
    connections = BulkHandlerScopeMockSl(), change_data = true, db_def_folder = "bh665_sl")

# Inline F1-flavoured fixtures, one module per backend. `set_models` is required, not a style
# choice: the cjoin and joined-filter cases render a join, and `_build_row_join` reads the model's
# `_module`, which a bare `Model(...)` leaves as `nothing`.
module BulkHandlerScopePg
import PormG.Models
Bh665_driver = Models.Model("bh665_driver", id = Models.IDField(), surname = Models.CharField())
Bh665_result = Models.Model("bh665_result",
    id     = Models.IDField(),
    driver = Models.ForeignKey(Bh665_driver, on_delete = "CASCADE"),
    year   = Models.IntegerField(),
    points = Models.IntegerField(),
)
Models.set_models(@__MODULE__, "bh665_pg")
end

module BulkHandlerScopeSl
import PormG.Models
Bh665_driver = Models.Model("bh665_driver", id = Models.IDField(), surname = Models.CharField())
Bh665_result = Models.Model("bh665_result",
    id     = Models.IDField(),
    driver = Models.ForeignKey(Bh665_driver, on_delete = "CASCADE"),
    year   = Models.IntegerField(),
    points = Models.IntegerField(),
)
Models.set_models(@__MODULE__, "bh665_sl")
end

const BH665_PG = BulkHandlerScopePg.Bh665_result
const BH665_SL = BulkHandlerScopeSl.Bh665_result

# Two 1988 results to re-score: `points` is SET, `id` is the per-row match key.
bh665_df() = DataFrames.DataFrame(id = [11, 12], points = [9, 6])

# The row values each statement binds, in `bulk_update`'s order: every SET column, then every
# match key — `[points, id]` per row on SQLite, and on PostgreSQL the same values as one array
# per column (#672).
const BH665_ROWS = Any[9, 11, 6, 12]
const BH665_COLUMNS = Any[[9, 6], [11, 12]]

# A handler on `model` scoped to the 1988 season: the scope the issue's repro drops.
bh665_scoped(model) = (q = model.objects; q.filter("year" => 1988); q)

bh665_update(q; kwargs...) = bulk_update(q, bh665_df();
    columns = ["points"], match_on = ["id"], show_query = :dict, kwargs...)

# The error a call raises, or `nothing`. The guards are asserted on type AND on the message naming
# `bulk_update()`, so an unrelated UnsafeMutationError from elsewhere cannot satisfy them.
bh665_error(f) = try
    f()
    nothing
catch e
    e
end

@testset "bulk_update handler scope (#665)" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler scope: the handler's filters reach the UPDATE's WHERE clause, with their values bound.
    # The issue's repro: a handler scoped to `year = 1988` must only re-score 1988 rows. Asserted on
    # both the SQL text and the bound parameters, since a predicate rendered without its value (or
    # a value bound without its predicate) is the misbind shape, not the fix.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the handler's filters are AND'd into the WHERE clause" begin
        @testset "PostgreSQL" begin
            res = bh665_update(bh665_scoped(BH665_PG))
            # The handler filter binds first (at build time), so it is $1 ahead of the rows.
            @test occursin(r"\"Tb\"\.\"year\"\s*=\s*\$1\b", res[:sql_text])
            @test occursin(r"\"Tb\"\.\"id\"\s*=\s*source\.\"id\"", res[:sql_text])
            @test res[:parameters] == vcat(Any[1988], BH665_COLUMNS)
        end

        @testset "SQLite" begin
            res = bh665_update(bh665_scoped(BH665_SL))
            # SQLite's UPDATE is unaliased, so "Tb" is rewritten to the table name.
            @test occursin("\"bh665_result\".\"year\" = ?", res[:sql_text])
            # Positional: the CTE's VALUES rows render before the WHERE filter.
            @test res[:parameters] == vcat(BH665_ROWS, Any[1988])
            @test count("?", res[:sql_text]) == length(res[:parameters])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler scope: filters= is added to the handler's scope, not substituted for it.
    # Both predicates must be present, handler first: `filters=` is pushed onto the private copy
    # after the handler's own filters, so it binds second.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "filters= combines with the handler's filters" begin
        res = bh665_update(bh665_scoped(BH665_PG); filters = ["points__@gte" => 0])
        @test occursin(r"\"Tb\"\.\"year\"\s*=\s*\$1\b", res[:sql_text])
        @test occursin(r"\"Tb\"\.\"points\"\s*>=\s*\$2\b", res[:sql_text])
        @test res[:parameters] == vcat(Any[1988, 0], BH665_COLUMNS)

        res = bh665_update(bh665_scoped(BH665_SL); filters = ["points__@gte" => 0])
        @test occursin("\"bh665_result\".\"year\" = ?", res[:sql_text])
        @test occursin("\"bh665_result\".\"points\" >= ?", res[:sql_text])
        @test res[:parameters] == vcat(BH665_ROWS, Any[1988, 0])
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler scope: composite and subquery filters are kept too.
    # A `Qor` renders as one parenthesized OR group, and a `__@in` subquery renders with its inner
    # alias ("R1", never "Tb") — which is what keeps SQLite's "Tb" → table-name rewrite from
    # touching it. Both bind into the WHERE bucket, after the rows on SQLite.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Qor and subquery handler filters are kept" begin
        q = BH665_PG.objects
        q.filter(Qor("year" => 1988, "year" => 1989))
        res = bh665_update(q)
        @test occursin(r"\(\"Tb\"\.\"year\" = \$1 OR \"Tb\"\.\"year\" = \$2\)", res[:sql_text])
        @test res[:parameters] == vcat(Any[1988, 1989], BH665_COLUMNS)

        sub = BH665_SL.objects
        sub.filter("points__@gte" => 10)
        sub.values("id")
        q = bh665_scoped(BH665_SL)
        q.filter("id__@in" => sub)
        res = bh665_update(q)
        @test occursin("\"bh665_result\".\"id\" IN (SELECT", res[:sql_text])
        @test occursin("\"R1\".\"points\" >= ?", res[:sql_text])
        @test res[:parameters] == vcat(BH665_ROWS, Any[1988, 10])
        @test count("?", res[:sql_text]) == length(res[:parameters])
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler scope: every chunk carries the handler's filter values.
    # They are bound once at build time and are the fixed prefix each chunk's collector forks from
    # (#73), so with chunk_size = 1 both statements must carry 1988 — and on PostgreSQL bind their
    # own rows as the arrays $2 and $3 (#672).
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "every chunk carries the handler's filter values" begin
        res = bh665_update(bh665_scoped(BH665_PG); chunk_size = 1)
        @test length(res) == 2
        @test res[1][:parameters] == Any[1988, [9], [11]]
        @test res[2][:parameters] == Any[1988, [6], [12]]
        for r in res
            @test occursin(r"\"Tb\"\.\"year\"\s*=\s*\$1\b", r[:sql_text])
            @test !occursin("\$4", r[:sql_text])
        end

        res = bh665_update(bh665_scoped(BH665_SL); chunk_size = 1)
        @test length(res) == 2
        @test res[1][:parameters] == Any[9, 11, 1988]
        @test res[2][:parameters] == Any[6, 12, 1988]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler not mutated: the caller's handler reads the same before and after.
    # Compared on what the caller observes — the handler's own SELECT and its bound values — plus
    # the filter count. Before #665 the handler came back unfiltered, or carrying the call's
    # `filters=` in place of its own scope.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the caller's handler is left untouched" begin
        for model in (BH665_PG, BH665_SL)
            q = bh665_scoped(model)
            before = q.list(show_query = :dict)

            bh665_update(q)
            after = q.list(show_query = :dict)
            @test after[:sql_text] == before[:sql_text]
            @test after[:parameters] == before[:parameters]
            @test length(q.object.filter) == 1

            # filters= is applied to the statement only; it is never written back onto the handler.
            bh665_update(q; filters = ["points__@gte" => 0])
            after = q.list(show_query = :dict)
            @test after[:sql_text] == before[:sql_text]
            @test after[:parameters] == before[:parameters]
            @test length(q.object.filter) == 1
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler shape guards: state an UPDATE cannot express raises UnsafeMutationError.
    # `update()`'s three guards (limit/offset/order_by, distinct, aggregates) plus a CTE and a
    # cjoin. Each was silently ignored before, which for limit/offset widens the statement to every
    # matching row — and on the unpatched code the cjoin surfaced as the misleading "joined field
    # paths" QueryBuildError. The guard fires before any DataFrame work.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "unsupported handler state raises UnsafeMutationError" begin
        shapes = [
            "limit"     => (q, m) -> q.limit(5),
            "offset"    => (q, m) -> q.offset(5),
            "order_by"  => (q, m) -> q.order_by("id"),
            "distinct"  => (q, m) -> q.distinct(),
            "aggregate" => (q, m) -> q.values("n" => Count("id")),
            "CTE"       => (q, m) -> q.with("r88" => (s = m.objects; s.filter("year" => 1988); s.values("id"); s)),
            "cjoin"     => (q, m) -> q.cjoin("driver" => "Bh665_driver", warn = false),
        ]
        for model in (BH665_PG, BH665_SL), (label, apply!) in shapes
            q = bh665_scoped(model)
            apply!(q, model)
            err = bh665_error(() -> bh665_update(q))
            @test err isa PormG.UnsafeMutationError
            @test err !== nothing && occursin("bulk_update()", sprint(showerror, err))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Shared guards: update() still raises the same three, naming itself.
    # #665 moved update()'s limit/offset/order_by, distinct and aggregate guards into
    # `_reject_unsafe_mutation_shape`, shared with bulk_update. The refactor must not have moved the
    # name `update()` out of update()'s own messages, nor dropped a guard from the non-bulk path.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "update() keeps its shape guards after the extraction" begin
        shapes = [
            "limit"     => q -> q.limit(5),
            "distinct"  => q -> q.distinct(),
            "aggregate" => q -> q.values("n" => Count("id")),
        ]
        for (label, apply!) in shapes
            q = bh665_scoped(BH665_PG)
            apply!(q)
            err = bh665_error(() -> q.update("points" => 0, show_query = :dict))
            @test err isa PormG.UnsafeMutationError
            @test err !== nothing && occursin("Cannot call update() on a query", sprint(showerror, err))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler shape guards: a handler filter that traverses a relation is still a QueryBuildError.
    # bulk_update updates the model's own table and does not join, so `driver__surname` is refused
    # by the existing joined-path guard — the same error a joined column gets.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a joined handler filter raises QueryBuildError" begin
        for model in (BH665_PG, BH665_SL)
            q = bh665_scoped(model)
            q.filter("driver__surname" => "Senna")
            err = bh665_error(() -> bh665_update(q))
            @test err isa PormG.QueryBuildError
            @test err !== nothing && occursin("joined field paths", sprint(showerror, err))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # values() projection: ignored, and never bound.
    # An UPDATE has no projection. A `values()` entry that binds a parameter (`Value(5)`) would
    # otherwise land in the `:select` bucket — the bucket the chunk rows bind into — shifting every
    # positional parameter on SQLite. The statement must bind exactly the rows plus the filter.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a values() projection is ignored and binds nothing" begin
        q = bh665_scoped(BH665_SL)
        q.values("id", "bonus" => Value(5))
        res = bh665_update(q)
        @test res[:parameters] == vcat(BH665_ROWS, Any[1988])
        @test count("?", res[:sql_text]) == length(res[:parameters])

        q = bh665_scoped(BH665_PG)
        q.values("id", "bonus" => Value(5))
        res = bh665_update(q)
        @test res[:parameters] == vcat(Any[1988], BH665_COLUMNS)
        # The filter and the two column arrays are $1…$3; a bound Value(5) would push them to $4.
        @test !occursin("\$4", res[:sql_text])
    end
end
