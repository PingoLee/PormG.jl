# ============================================================
# test/unit/test_update_values_projection.jl
#
# update() ignores a values() projection and refuses a filter on a values() alias (#668).
#
# CONTRACT being tested:
#   An UPDATE has no projection. `q.update(...)` builds its statement from a private copy of `q`
#   with `values()` emptied, so it binds exactly the SET values and the WHERE values — the #665
#   shape `bulk_update` already uses. A filter that a read resolves through the projection — a
#   plain alias key (`"p2__@gt" => 10`, routed to HAVING), an alias reusing a model field's name, or
#   either nested in `Q`/`Qor` — raises `UnsafeMutationError` from `update()` and `bulk_update()`,
#   because without the projection it would be dropped or silently change meaning.
#
#   Before #668 `update()` built the handler as-is: a binding projection (`Value(5)`,
#   `F("points") * 2`) filed its operands into the `:select` bucket, which flattens ahead of SET and
#   WHERE — on SQLite the repro bound `points = 2, year = 3` — and the alias predicate vanished,
#   widening the UPDATE to every 1988 row (the #74 shape).
#
# Deterministic and DB-free: mock PostgreSQL and SQLite connections; `show_query = :dict` returns
# the prepared statement before any driver call.
# ============================================================

using Test
using PormG
using PormG.QueryBuilder: bulk_update, F, Value
import DataFrames

# Dedicated mocks and config keys so this file cannot contaminate (or be contaminated by) other
# unit files sharing Main in runtests.jl. `db_def_folder` names the key itself, so `set_models`
# resolves the in-memory entry instead of looking for a folder on disk.
struct UpdateValuesMockPg <: PormG.PormGPostgres end
struct UpdateValuesMockSl <: PormG.PormGSQLite end
# bulk_update's chunk cap reads the SQLite version for its bind-parameter limit; a modern build.
PormG.backend_sqlite_version(::UpdateValuesMockSl) = 3045000
PormG.config["uv668_pg"] = PormG.Configuration.Settings(
    connections = UpdateValuesMockPg(), change_data = true, db_def_folder = "uv668_pg")
PormG.config["uv668_sl"] = PormG.Configuration.Settings(
    connections = UpdateValuesMockSl(), change_data = true, db_def_folder = "uv668_sl")

# Inline F1-flavoured fixtures, one module per backend.
module UpdateValuesPg
import PormG.Models
Uv668_result = Models.Model("uv668_result",
    id = Models.IDField(), year = Models.IntegerField(), points = Models.IntegerField())
Models.set_models(@__MODULE__, "uv668_pg")
end

module UpdateValuesSl
import PormG.Models
Uv668_result = Models.Model("uv668_result",
    id = Models.IDField(), year = Models.IntegerField(), points = Models.IntegerField())
Models.set_models(@__MODULE__, "uv668_sl")
end

const UV668_PG = UpdateValuesPg.Uv668_result
const UV668_SL = UpdateValuesSl.Uv668_result

# A handler scoped to the 1988 season, optionally carrying a projection.
function uv668_scoped(model; projection = nothing)
    q = model.objects
    q.filter("year" => 1988)
    projection === nothing || q.values(projection...)
    return q
end

# The error a call raises, or `nothing`.
uv668_error(f) = try
    f()
    nothing
catch e
    e
end

# The binding projections from the issue: a bound literal and an F expression with a bound operand.
const UV668_BINDING_PROJECTIONS = [
    "Value(5)"         => ["id", "bonus" => Value(5)],
    "F(points) * 2"    => ["id", "p2" => F("points") * 2],
]

@testset "update() and values() projections (#668)" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # Binding projection, SQLite: update() binds exactly SET then WHERE.
    # Positional `?` placeholders make a leaked `:select` operand shift every value — the issue's
    # repro wrote `points = 2` into `year = 3` rows. The parameter vector must be `[SET, WHERE]` and
    # match the placeholder count one-for-one.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "SQLite binds only the SET and WHERE values" begin
        for (label, projection) in UV668_BINDING_PROJECTIONS
            res = uv668_scoped(UV668_SL; projection).update("points" => 3, show_query = :dict)
            @test res[:parameters] == Any[3, 1988]
            @test count("?", res[:sql_text]) == length(res[:parameters])
            @test occursin(r"SET \"points\" = \?\s*WHERE \"Tb\"\.\"year\" = \?", res[:sql_text])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Binding projection, PostgreSQL: no orphaned `$N` parameters.
    # Numbered placeholders do not shift, but the projection's operands were still bound and never
    # referenced (the repro sent five values for a two-placeholder statement). The WHERE value binds
    # at build time as $1, the SET value after it as $2, and nothing else is sent.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL binds only the SET and WHERE values" begin
        for (label, projection) in UV668_BINDING_PROJECTIONS
            res = uv668_scoped(UV668_PG; projection).update("points" => 3, show_query = :dict)
            @test res[:parameters] == Any[1988, 3]
            @test occursin(r"SET \"points\" = \$2\b", res[:sql_text])
            @test occursin(r"\"Tb\"\.\"year\" = \$1\b", res[:sql_text])
            @test !occursin("\$3", res[:sql_text])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Plain projection: a non-binding values() does not change the statement.
    # Non-regression for the common case — a handler reused from a read — which rendered correctly
    # before #668 and must render byte-identically to the same handler without a projection.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a plain values() projection leaves the statement unchanged" begin
        for model in (UV668_PG, UV668_SL)
            with_values = uv668_scoped(model; projection = ["id", "points"]).update("points" => 3, show_query = :dict)
            without     = uv668_scoped(model).update("points" => 3, show_query = :dict)
            @test with_values[:sql_text] == without[:sql_text]
            @test with_values[:parameters] == without[:parameters]
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Alias filter: refused by update() and bulk_update(), never dropped.
    # `"p2__@gt" => 10` names the projection alias, so it routes to HAVING; an UPDATE renders no
    # HAVING. Unpatched, update() returned a statement scoped by `year` alone, and bulk_update()
    # raised a misleading "column p2 not found". Both now raise UnsafeMutationError naming the alias
    # and the terminal.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a filter on a values() alias raises UnsafeMutationError" begin
        for model in (UV668_PG, UV668_SL)
            q = uv668_scoped(model; projection = ["id", "p2" => F("points") * 2])
            q.filter("p2__@gt" => 10)
            err = uv668_error(() -> q.update("points" => 3, show_query = :dict))
            @test err isa PormG.UnsafeMutationError
            @test err !== nothing && occursin("update() with a filter on the values() alias \"p2\"", sprint(showerror, err))

            df = DataFrames.DataFrame(id = [11, 12], points = [9, 6])
            err = uv668_error(() -> bulk_update(q, df; columns = ["points"], match_on = ["id"], show_query = :dict))
            @test err isa PormG.UnsafeMutationError
            @test err !== nothing && occursin("bulk_update() with a filter on the values() alias \"p2\"", sprint(showerror, err))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Alias guard: an alias that reuses a model field's name is refused too.
    # A read resolves `filter("points__@gt" => 0)` through the projection memo, so with
    # `values("points" => F("points") - 100)` it filters `("Tb"."points" - $N) > $M`. Built without
    # the projection it would silently filter the raw column instead — a different set of rows with
    # no error, found in review of the first #668 patch. No row filter may change meaning.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "an alias shadowing a model field raises UnsafeMutationError" begin
        for model in (UV668_PG, UV668_SL)
            q = uv668_scoped(model; projection = ["id", "points" => F("points") - 100])
            q.filter("points__@gt" => 0)
            # The read this guards: the predicate is on the projected expression, not the column.
            @test occursin(r"\(\"Tb\"\.\"points\" - (\?|\$\d+(::\w+)?)\) > ", q.list(show_query = :dict)[:sql_text])
            err = uv668_error(() -> q.update("points" => 3, show_query = :dict))
            @test err isa PormG.UnsafeMutationError
            @test err !== nothing && occursin("values() alias \"points\"", sprint(showerror, err))

            # A `Value(x)` literal memoizes under its output name by a separate arm; the read
            # compares the bound literal (`WHERE ? > ?`), so the update must refuse it the same way.
            q = uv668_scoped(model; projection = ["id", "points" => Value(7)])
            q.filter("points__@gt" => 0)
            err = uv668_error(() -> q.update("points" => 3, show_query = :dict))
            @test err isa PormG.UnsafeMutationError
            @test err !== nothing && occursin("values() alias \"points\"", sprint(showerror, err))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Alias guard: an alias filter nested in Q or Qor is refused, naming the alias.
    # Nested, the alias renders in WHERE as the projected expression on a read. Without the guard the
    # emptied projection turned it into an `UnknownFieldError` claiming "p2" does not exist — loud,
    # but wrong about a name the caller declared.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "an alias filter nested in Q or Qor raises UnsafeMutationError" begin
        nested = [
            "Q"   => PormG.QueryBuilder.Q("p2__@gt" => 10),
            "Qor" => PormG.QueryBuilder.Qor("year" => 1989, PormG.QueryBuilder.Q("p2__@gt" => 10)),
        ]
        for model in (UV668_PG, UV668_SL), (label, filt) in nested
            q = uv668_scoped(model; projection = ["id", "p2" => F("points") * 2])
            q.filter(filt)
            err = uv668_error(() -> q.update("points" => 3, show_query = :dict))
            @test err isa PormG.UnsafeMutationError
            @test err !== nothing && occursin("values() alias \"p2\"", sprint(showerror, err))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Alias guard scope: a field projected under its own name is not an alias.
    # `values("points")` memoizes the plain column, which is exactly what the filter renders without
    # it, so `filter("points__@gt" => 0)` must still update.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a plain field projection does not trip the alias guard" begin
        for model in (UV668_PG, UV668_SL)
            q = uv668_scoped(model; projection = ["id", "points"])
            q.filter("points__@gt" => 0)
            res = q.update("points" => 3, show_query = :dict)
            @test sort(res[:parameters]; by = string) == sort(Any[3, 1988, 0]; by = string)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Alias guard scope: an unknown plain key is still an unknown field.
    # The guard refuses only names a projection declares. A key naming nothing must keep the
    # `UnknownFieldError` build() raises, rather than being reported as an alias.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "an unknown plain filter key still raises UnknownFieldError" begin
        for model in (UV668_PG, UV668_SL)
            q = uv668_scoped(model; projection = ["id", "p2" => F("points") * 2])
            q.filter("nope__@gt" => 10)
            err = uv668_error(() -> q.update("points" => 3, show_query = :dict))
            @test err isa PormG.UnknownFieldError
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Handler not mutated: the projection is emptied on a private copy only.
    # update() now deep-copies before building; the caller's handler must keep its projection and
    # filters so it still reads the same afterwards.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the caller's handler keeps its projection" begin
        for model in (UV668_PG, UV668_SL)
            q = uv668_scoped(model; projection = ["id", "bonus" => Value(5)])
            before = q.list(show_query = :dict)
            q.update("points" => 3, show_query = :dict)
            after = q.list(show_query = :dict)
            @test after[:sql_text] == before[:sql_text]
            @test after[:parameters] == before[:parameters]
            @test length(q.object.values) == 2
            @test length(q.object.filter) == 1
        end
    end
end
