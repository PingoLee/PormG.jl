# =============================================================================
# Migration statement ordering: the FK invariant, and two hazards it does not cover (#89)
#
# `_order_statements` orders a migration's DDL into fixed buckets with NO topological sort by
# foreign key. #89 filed that as a latent fragility ("survives by accident"). It is not an accident
# any more, and this file is what makes that a checked contract rather than a property three
# subsystems happen to hold:
#
#   1. PostgreSQL never inlines an FK in CREATE TABLE — every constraint is a separate, later
#      ALTER TABLE ... ADD CONSTRAINT, so CREATE order among new tables cannot matter;
#   2. PostgreSQL drops tables with CASCADE, so DROP order cannot matter;
#   3. SQLite runs the whole migration with PRAGMA foreign_keys = OFF (#276), so its inline
#      REFERENCES clauses constrain nothing while the migration runs.
#
# Why the invariant rather than the sort the issue asks for: `get_all_dicts` keeps only the
# OrderedDict VALUES when it reads `pending_migrations.jl` back, so the table name is gone before
# `_order_statements` ever runs — there is nothing to sort on. And #89's own acceptance case is two
# MUTUALLY-FK'd tables, i.e. a cycle, which no topological sort can order but which property 1
# handles for free. The day property 1 is broken, the first testset here fails, and that is the
# moment to design a format v2 rather than to sort opaque SQL strings.
#
# One REAL hazard the accident never covered is also pinned here — a PostgreSQL DROP CONSTRAINT
# reached after a parent's DROP TABLE ... CASCADE had already taken the constraint. A second
# candidate ("Rename table" sharing a bucket with "New foreign key: …") was unreachable when #89
# looked at it; #615 repaired the producer and gave the key its own bucket, and the testset below
# now pins that ordering. The rename's own coverage lives in `test_migration_rename_table.jl`.
# =============================================================================

using Test
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite, Dialect
import OrderedCollections: OrderedDict
# The cycle testset opens a real (temporary) SQLite file, so it needs the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool

# Suffixed name: `runtests.jl` includes every unit file into ONE module, so a bare `MockPostgres`
# would silently redefine a sibling's.
struct FkOrderMockPg89 <: PormGPostgres end
const FKPG89 = FkOrderMockPg89()
PormG.get_constraints_pk(::FkOrderMockPg89, t::String, f::String) = nothing
PormG.get_constraints_unique(::FkOrderMockPg89, t::String, f::String) = nothing
PormG.get_constraints_check(::FkOrderMockPg89, t::String, f::String) = nothing
PormG.get_constraints_byte_length_check(::FkOrderMockPg89, t::String, f::String) = nothing
fetch(::FkOrderMockPg89, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

# A genuine FK CYCLE. `a2` and `a` share the table name "a_t", so `b`'s key pointing at `a` and
# `a2`'s key pointing at `b_t` reference each other at the SQL level — which is the only level the
# ordering question lives at.
function _fk_cycle_models()
    a  = Models.Model("a_t"; id = Models.IDField(), n = Models.IntegerField())
    b  = Models.Model("b_t"; id = Models.IDField(),
                      a_id = Models.ForeignKey(a; pk_field = "id", null = true))
    a2 = Models.Model("a_t"; id = Models.IDField(), n = Models.IntegerField(),
                      b_id = Models.ForeignKey(b; pk_field = "id", null = true))
    return a2, b
end

# Plan both new tables in the given declaration order and flatten through the real orderer, the way
# the runner receives it.
function _plan_new_tables(conn, models::Vector)
    plan = OrderedDict{Symbol, OrderedDict{String, String}}()
    for m in models
        Migrations._add_new_table(conn, plan, Symbol(Models.model_table_name(m)), m)
    end
    ordered, _ = Migrations._order_statements([plan[k] for k in keys(plan)])
    return plan, ordered
end

@testset "Migration statement ordering: the FK invariant (#89)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # Property 1 — PostgreSQL never inlines a foreign key in CREATE TABLE
    # THE load-bearing assertion of this file. Every FK must arrive as its own ADD CONSTRAINT,
    # which `_order_statements` puts after every CREATE TABLE. That, and only that, is why two new
    # tables referencing each other apply in any order. If someone ever inlines an FK on PG to save
    # a statement, this fails — which is exactly the regression #89 is worried about.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL emits no inline REFERENCES in CREATE TABLE" begin
        a2, b = _fk_cycle_models()
        _, ordered = _plan_new_tables(FKPG89, [a2, b])

        creates = filter(s -> occursin("CREATE TABLE", uppercase(s)), ordered)
        @test length(creates) == 2
        for c in creates
            @test !occursin("REFERENCES", uppercase(c))
            @test !occursin("FOREIGN KEY", uppercase(c))
        end

        # And the constraints really are present, as separate statements — otherwise the assertion
        # above would pass simply because no FK was ever planned.
        adds = filter(s -> occursin("ADD CONSTRAINT", uppercase(s)), ordered)
        @test length(adds) == 2
        @test all(s -> occursin("REFERENCES", uppercase(s)), adds)

        # Every CREATE TABLE precedes every ADD CONSTRAINT: the ordering the invariant relies on.
        last_create = maximum(findall(s -> occursin("CREATE TABLE", uppercase(s)), ordered))
        first_add   = minimum(findall(s -> occursin("ADD CONSTRAINT", uppercase(s)), ordered))
        @test last_create < first_add
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Property 1 again, from the other declaration order
    # The cycle means neither order is "the right one". Both must produce the same shape, or a
    # models file that merely lists its models differently would migrate differently.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "declaration order does not change the plan's shape" begin
        a2, b = _fk_cycle_models()
        _, ab = _plan_new_tables(FKPG89, [a2, b])
        a2b, b2 = _fk_cycle_models()
        _, ba = _plan_new_tables(FKPG89, [b2, a2b])

        # NOT sorted: sorting would compare multisets, and the same two models always plan two
        # CREATEs and two ADDs whatever the order — a near-tautology. The claim is that the
        # SEQUENCE is the same, which is what "declaration order does not change the plan" means.
        shape(v) = [occursin("CREATE TABLE", uppercase(s)) ? "CREATE" :
                    occursin("ADD CONSTRAINT", uppercase(s)) ? "ADDFK" : "OTHER" for s in v]
        @test shape(ab) == shape(ba)
        # In both orders the CREATEs still all precede the ADD CONSTRAINTs.
        for v in (ab, ba)
            @test maximum(findall(s -> occursin("CREATE TABLE", uppercase(s)), v)) <
                  minimum(findall(s -> occursin("ADD CONSTRAINT", uppercase(s)), v))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Property 2 — PostgreSQL drops with CASCADE
    # Why drop order is allowed to be arbitrary: a parent can be dropped while children still
    # reference it. SQLite needs no CASCADE because enforcement is suspended (property 3).
    # ─────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL drops tables with CASCADE" begin
        @test occursin("CASCADE", Dialect.drop_table(FKPG89, :parent_t))
        @test occursin("IF EXISTS", Dialect.drop_table(FKPG89, :parent_t))
    end

    # ─────────────────────────────────────────────────────────────────────────
    # HAZARD 1 (live bug): a CASCADE drop makes the child's DROP CONSTRAINT a no-op target
    # "Drop table" is bucket 2 and "Remove foreign key: …" is bucket 5, so dropping a parent table
    # and removing the child's FK field in ONE migration reached the DROP CONSTRAINT after the
    # parent's CASCADE had already removed it — and PostgreSQL aborts on a missing constraint. The
    # ordering is fine; the unguarded DROP was not.
    # Mutation gate: without `IF EXISTS` the first assertion fails outright.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL DROP CONSTRAINT is guarded against a prior CASCADE" begin
        sql = Dialect.drop_foreign_key(FKPG89, :child_t, "child_t_parent_id_fk")
        @test occursin("DROP CONSTRAINT IF EXISTS", sql)

        # The ordering that makes the guard necessary, asserted rather than assumed.
        plan = [OrderedDict{String,String}(
            "Remove foreign key: parent_id" =>
                Dialect.drop_foreign_key(FKPG89, :child_t, "child_t_parent_id_fk"),
            "Drop table" => Dialect.drop_table(FKPG89, :parent_t),
        )]
        ordered, _ = Migrations._order_statements(plan)
        drop_tbl = findfirst(s -> occursin("DROP TABLE", uppercase(s)), ordered)
        drop_con = findfirst(s -> occursin("DROP CONSTRAINT", uppercase(s)), ordered)
        @test drop_tbl < drop_con
    end

    # ─────────────────────────────────────────────────────────────────────────
    # "Rename table" is reachable, and it runs before the table's column work (#615)
    # #89 found this key unreachable — the rename branch raised `KeyError` on `current_schema[old]`,
    # and one line later `MethodError` on `rename_table(conn, ::Symbol, …)` with the names swapped —
    # and pinned that here so the repair would fail it. #615 repaired it and chose the ordering: the
    # rename gets its own bucket right after DROP TABLE, and the column work names the NEW table. So
    # this asserts both halves at once — the step exists, old ⇒ new, and it precedes an ADD COLUMN
    # that targets the new name (which would fail if the order were the other way round).
    # ─────────────────────────────────────────────────────────────────────────
    @testset "a \"Rename table\" step is planned and ordered ahead of the column work (#615)" begin
        settings = PormG.Configuration.Settings()
        settings.change_db = true
        # The declared model gains a nullable column, so the renamed table has column work to order.
        declared = Models.Model("new_t"; id = Models.IDField(), n = Models.IntegerField(),
                                x = Models.IntegerField(null = true))
        livem    = Models.Model("old_t"; id = Models.IDField(), n = Models.IntegerField())
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
            :new_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))

        # "no" to "is this a new table?", then "1" to pick `old_t` as its former name.
        path, io2 = mktemp(); write(io2, "no\n1\n"); close(io2)
        plan = open(path) do stdin_file
            redirect_stdin(stdin_file) do
                redirect_stdout(devnull) do
                    Migrations.get_migration_plan(PormGModel[livem], current_schema, FKPG89,
                                                  settings; interactive = true)
                end
            end
        end

        # Everything is registered under the NEW key, and nothing drops the old table.
        @test collect(keys(plan)) == [:new_t]
        @test plan[:new_t]["Rename table"] == "ALTER TABLE \"old_t\" RENAME TO \"new_t\";"
        @test !haskey(plan[:new_t], "Drop table")
        @test occursin("ALTER TABLE \"new_t\" ADD COLUMN \"x\"", plan[:new_t]["Add field: x"])

        # The orderer puts the rename first, whatever the insertion order inside the table's dict.
        ordered, _ = Migrations._order_statements([plan[k] for k in keys(plan)])
        i_rename = findfirst(==(plan[:new_t]["Rename table"]), ordered)
        i_add    = findfirst(==(plan[:new_t]["Add field: x"]), ordered)
        @test i_rename !== nothing && i_add !== nothing
        @test i_rename < i_add
    end

    # ─────────────────────────────────────────────────────────────────────────
    # THE ORACLE — #89's acceptance criterion, hermetically
    # Two mutually-FK'd new tables apply cleanly against a real SQLite file in BOTH declaration
    # orders. SQLite inlines its FKs, so this is the engine where create order could plausibly
    # matter — and it does not, because SQLite resolves an FK's parent table lazily, at DML time.
    # Enforcement is left ON here deliberately (the acceptance criterion says "with SQLite FK
    # enforcement on, per #82"), which is STRICTER than the migration runner, and
    # `PRAGMA foreign_key_check` is read back to prove the result is actually consistent.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "two mutually-FK'd new tables apply in either declaration order (SQLite)" begin
        for (label, order) in (("a-then-b", :ab), ("b-then-a", :ba))
            mktempdir() do dir
                pool = SQLiteConnectionPool(joinpath(dir, "fkcycle89.sqlite"); pool_size = 1)
                try
                    # Stricter than the runner, which suspends enforcement for the whole migration.
                    fetch(pool, "PRAGMA foreign_keys = ON;")
                    a2, b = _fk_cycle_models()
                    models = order === :ab ? [a2, b] : [b, a2]
                    _, ordered = _plan_new_tables(pool, models)

                    for sql in ordered, stmt in split(sql, ";")
                        trimmed = strip(stmt)
                        isempty(trimmed) && continue
                        # A probe, not DDL — the runner treats it separately too.
                        startswith(uppercase(trimmed), "PRAGMA FOREIGN_KEY_CHECK") && continue
                        fetch(pool, String(trimmed))
                    end

                    tables = sort(string.((fetch(pool,
                        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") |> DataFrame).name))
                    @test tables == ["a_t", "b_t"]

                    # The keys really are enforceable: insert a consistent pair and prove the
                    # cycle holds, then confirm the catalog reports no violations.
                    fetch(pool, """INSERT INTO "a_t" ("id", "n") VALUES (1, 7)""")
                    fetch(pool, """INSERT INTO "b_t" ("id", "a_id") VALUES (1, 1)""")
                    fetch(pool, """UPDATE "a_t" SET "b_id" = 1 WHERE "id" = 1""")
                    @test nrow(fetch(pool, "PRAGMA foreign_key_check") |> DataFrame) == 0
                finally
                    close_pool!(pool)
                end
            end
        end
    end
end
