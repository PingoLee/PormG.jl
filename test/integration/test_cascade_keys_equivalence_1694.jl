# julia -t auto --project=test/integration test/integration/test_cascade_keys_equivalence_1694.jl
# PORMG_POSTGRES_DRIVER=Postgres julia -t auto --project=test/integration test/integration/test_cascade_keys_equivalence_1694.jl
# PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_cascade_keys_equivalence_1694.jl
# PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_cascade_keys_equivalence_1694.jl
#
# On LibPQ the key read keeps `Tables.columntable` (its rows would be built from it anyway), so that run compares the
# old read with itself; the decode is exercised by the SQLite, Postgres.jl and MySQL runs.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# #1599 layer 7, #1694 — a cascading delete reads its root's primary keys first (#1342, #1370), and on SQLite, Postgres.jl
# and MySQL it now reads them through the untyped read's decoder (`with_transaction`'s internal `_decode`), where the driver's
# result is concrete. Before, it read `Tables.columntable` over the result typed `Any`, which a `juliac --trim` image
# has no code for.
#
# The keys must be exactly what they were: the same values in the same order, and the same vector type, which is what
# the cascade's `"<pk>__@in"` filters receive. The oracle is the old read itself: the same statement, run on the same
# transaction's connection, through `Tables.columntable` and `_key_vector`, against `_resolve_root_keys!`.

const _CK_QB = PormG.QueryBuilder

# The old read: the key step's statement, its raw result, then `_key_vector` over its columns.
function _ck_old_keys(pool, model, plan, conn)
    locks = _CK_QB._locks_cascade_parents(pool)
    key_column = _CK_QB.safe_column_identifier(PormG.Models.model_column(model, plan.entry[:key]), pool)
    select_sql = "SELECT $(plan.alias).$(key_column) FROM $(_CK_QB.safe_table_identifier(PormG.Models.model_table_name(model), pool))" *
        " AS $(plan.alias) WHERE $(plan.where_sql)"
    sql = locks ? select_sql * " FOR UPDATE" : select_sql
    result, _ = _CK_QB._with_transaction_with(pool, sql, conn, false, plan.parameters)
    return _CK_QB._key_vector(_CK_QB.Tables.columntable(result))
end

const _CK_ROOTS = [
    ("a filter on the root's own column", () -> M.Race.objects.filter("year" => 2008), true),
    ("a filter across a join", () -> M.Race.objects.filter("circuitid__country" => "Monaco"), true),
    ("a filter across a reverse relation", () -> M.Race.objects.filter("year" => 2008, "result__grid" => 1), true),
    ("no row matches", () -> M.Race.objects.filter("year" => 1800), false),
]

@testset "The cascade's key read returns the keys it read before (#1599 layer 7)" begin
    # Expected SQL: `SELECT "Tb"."raceid" FROM race AS "Tb" WHERE <filter>` (with `FOR UPDATE` on PostgreSQL and MySQL),
    # run twice in one transaction. Why: a trimmed image can read the keys only once they are decoded at the driver's
    # concrete result type, and the decode must not change a key, their order or the vector type on any engine.
    PormG.run_in_transaction(PORMG_DB_FOLDER) do
        settings = PormG.Configuration.get_settings(PORMG_DB_FOLDER)
        pool = settings.connections
        conn = PormG.Configuration.transaction_connection_for(settings)
        @test conn !== nothing
        for (label, make, nonempty) in _CK_ROOTS
            @testset "$label" begin
                old = _ck_old_keys(pool, M.Race, _CK_QB._root_key_plan(pool, M.Race, make()), conn)
                new = _CK_QB._resolve_root_keys!(Any[], pool, M.Race, _CK_QB._root_key_plan(pool, M.Race, make()), :execute, conn)
                @test isempty(old) != nonempty
                @test typeof(new) === typeof(old)
                @test isequal(new, old)
            end
        end
    end
end
