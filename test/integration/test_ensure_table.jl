# =============================================================================
# Migrations.ensure_table! against a live database (#1230)
#
# The unit file `test/unit/test_host_primitives.jl` pins the statements `ensure_table!` renders and
# runs it on SQLite `:memory:`. This one runs it against the configured fixture database —
# PostgreSQL under db_2, where it takes the migration advisory lock and repeats the existence check
# under it, SQLite under db_sl — and checks that what it creates is what `migrate` would create: the
# statements equal the plan's for the same model, and once the table exists the drift gate is clean.
#
# Isolation: one scratch table, `ensure1230`, dropped before and after, and a temporary models file
# declaring only that table. `include_table` keeps the drift comparison to it.
#
# julia -t auto --project=test/integration test/integration/test_ensure_table.jl
# PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_ensure_table.jl
# =============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# ensure_table! on the live backend: refused in a transaction, created, converged, then left alone
# What it tests:
#   1. inside an open transaction it raises `TransactionError` and creates nothing;
#   2. its statements are the migration plan's for the same model, statement for statement;
#   3. the first call returns `:created`, and `check(kinds = [:schema_drift])` then finds nothing —
#      the live reader reads back what `migrate` would have written;
#   4. the second call returns `:exists`.
# Why it matters: a library creates its infrastructure tables with this on every boot. If its DDL
#   drifted from `migrate`'s, the next `makemigrations` on an app that later declared the same table
#   would propose changes forever; if it ran inside a caller's transaction, the PostgreSQL lock that
#   serializes it would be released before the outer COMMIT.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ensure_table! on the live $(adapter_name) fixture (#1230)" begin
    key = PORMG_DB_FOLDER
    settings = PormG.config[key]
    conn = settings.connections
    @test settings.change_db                       # the fixture can change the schema
    table = "ensure1230"
    # MySQL indexes a LONGTEXT only by a prefix, so an Index over a TextField is refused there
    # (`unbounded_text_indexes`); the indexed text is a CharField on that engine.
    payload = by_engine(postgres = "Models.TextField(null = true)", sqlite = "Models.TextField(null = true)",
                        mysql = "Models.CharField(max_length = 200, null = true)")
    source = "module models\nimport PormG.Models\n" *
             "Ensure1230 = Models.Model(\"ensure1230\",\n    id = Models.IDField(),\n" *
             "    driverref = Models.CharField(max_length = 64),\n" *
             "    payload = $(payload);\n" *
             "    indexes = [Models.Index(fields = (\"driverref\", \"payload\"), name = \"ensure1230_lookup\")])\nend\n"
    dir = mktempdir()
    models_path = joinpath(dir, "models.jl")
    write(models_path, source)
    holder = Module(:Ensure1230Holder)
    Base.include_string(holder, source)
    model = Base.invokelatest(getfield, Base.invokelatest(getfield, holder, :models), :Ensure1230)
    PormG.Models.bind!(model, key)

    drift() = PormG.Migrations.check(conn, settings; kinds = [:schema_drift],
                                     models_file = models_path, include_table = [table])
    run_sql(sql) = for part in split_statements(engine_sql(sql; conn = conn); conn = conn)
        PormG.ConnectionPool.fetch(conn, part)
    end
    exists() = PormG.Migrations._live_table_exists(conn, table)

    run_sql("DROP TABLE IF EXISTS \"$(table)\";")
    try
        @test !exists()

        # 1. Inside an open transaction: refused, nothing created.
        err = try
            PormG.run_in_transaction(conn) do
                PormG.Migrations.ensure_table!(model, key)
            end
            nothing
        catch e
            e
        end
        @test err isa PormG.TransactionError
        @test !exists()

        # 2. The statements are the migration plan's for the same model.
        live = PormG.Migrations.read_live_schema(conn; include_table = [table])
        plan = PormG.Migrations.get_migration_plan(live, PormG.Migrations._load_current_models(models_path),
                                                   conn, settings; interactive = false)
        planned, _ = PormG.Migrations._order_statements(collect(values(plan)))
        @test PormG.Migrations._ensure_table_statements(conn, model) == planned

        # 3. Created, and converged: the drift gate reads back no difference.
        @test PormG.Migrations.ensure_table!(model, key) === :created
        @test exists()
        @test isempty(drift())

        # 4. Every later call leaves it alone.
        @test PormG.Migrations.ensure_table!(model, key) === :exists
        @test isempty(drift())
    finally
        run_sql("DROP TABLE IF EXISTS \"$(table)\";")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# ensure_table! on a dotted db_table: one identifier, found again on every later boot (#1254)
# What it tests: a model whose `db_table` holds a dot (`"ensure1254.lap_times"`) and a plain index (`db_index = true`).
#   The first call returns `:created`, the second and third `:exists` without raising. The DDL quotes
#   the whole name (`CREATE TABLE IF NOT EXISTS "ensure1254.lap_times"`), and `_live_table_exists`
#   asks for the same single identifier (`to_regclass(quote_ident($1))` on PostgreSQL), so the two
#   agree. No schema named `ensure1254` is involved.
# Why it matters: #1254 read `quote_ident` as missing a schema-qualified table, which would make
#   every boot re-run the DDL and fail on the plain `CREATE INDEX`. `db_table` is stored and quoted
#   verbatim as ONE identifier on every path (`docs/src/schema_conventions.md`), so the existence
#   check must look the name up whole; splitting it on the dot would look where the DDL never writes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ensure_table! on a dotted db_table on the live $(adapter_name) fixture (#1254)" begin
    key = PORMG_DB_FOLDER
    conn = PormG.config[key].connections
    table = "ensure1254.lap_times"
    model = PormG.Models.Model("ensure1254",
        db_table = table,
        id = PormG.Models.IDField(),
        driverref = PormG.Models.CharField(max_length = 64, db_index = true))
    PormG.Models.bind!(model, key)
    run_sql(sql) = for part in split_statements(engine_sql(sql; conn = conn); conn = conn)
        PormG.ConnectionPool.fetch(conn, part)
    end

    run_sql("DROP TABLE IF EXISTS \"$(table)\";")
    try
        @test !PormG.Migrations._live_table_exists(conn, table)
        @test PormG.Migrations.ensure_table!(model, key) === :created
        @test PormG.Migrations._live_table_exists(conn, table)
        @test PormG.Migrations.ensure_table!(model, key) === :exists
        @test PormG.Migrations.ensure_table!(model, key) === :exists   # no second CREATE INDEX
        @test PormG.Migrations._live_column_exists(conn, table, "driverref")
    finally
        run_sql("DROP TABLE IF EXISTS \"$(table)\";")
    end
end
