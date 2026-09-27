# =============================================================================
# check(kinds = [:schema_drift]) against a live database (#738)
#
# The unit file `test/unit/test_schema_drift_check.jl` covers the drift gate on temporary SQLite
# files. This one runs it against the configured fixture database — PostgreSQL under db_2, SQLite
# under db_sl — so the PostgreSQL live reader, and the planner's convergence on what that reader
# returns, are exercised too: a table created from the plan must read back as no drift at all.
#
# Isolation: one scratch table, `drift738`, created and dropped here, and a temporary models file
# declaring only that table. `include_table` keeps both sides of the comparison to it, so nothing
# else in the shared fixture is read as drift.
#
# julia -t auto --project=test/integration test/integration/test_schema_drift_check.jl
# PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_schema_drift_check.jl
# =============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# schema_drift on the live backend: missing, converged, then an out-of-band column
# The three states a release gate meets. A table the models declare but the database lacks is a
# "New model"; once it is created from the plan's own DDL the gate is clean; a column added by hand
# outside PormG is a "Remove field" — in the database, not declared.
# ─────────────────────────────────────────────────────────────────────────────
@testset "check(kinds = [:schema_drift]) on the live $(adapter_name) fixture (#738)" begin
    settings = PormG.config[PORMG_DB_FOLDER]
    conn = settings.connections
    table = "drift738"
    dir = mktempdir()
    models_path = joinpath(dir, "models.jl")
    write(models_path, "module models\nimport PormG.Models\n" *
                       "Drift738 = Models.Model(\n    id = Models.IDField(),\n" *
                       "    name = Models.CharField(null = true)\n)\nend\n")
    drift() = PormG.Migrations.check(conn, settings; kinds = [:schema_drift],
                                     models_file = models_path, include_table = [table])
    run_sql(sql) = for part in (conn isa PormG.PormGSQLite ? PormG.Migrations._split_sqlite_statements(sql) : [sql])
        PormG.ConnectionPool.fetch(conn, part)
    end

    run_sql("DROP TABLE IF EXISTS \"$(table)\";")
    try
        # 1. Declared, not in the database.
        r = drift()
        @test [f.detail for f in r.findings] == ["New model"]
        @test only(r.findings).table == table

        # 2. Create it with exactly the DDL the plan holds; the gate is then clean. This is the
        #    convergence half: the live reader must read back what the planner wrote.
        live = PormG.Migrations.read_live_schema(conn; include_table = [table])
        plan = PormG.Migrations.get_migration_plan(live, PormG.Migrations._load_current_models(models_path),
                                                   conn, settings; interactive = false)
        ordered, _ = PormG.Migrations._order_statements(collect(values(plan)))
        foreach(run_sql, ordered)
        @test isempty(drift())

        # 3. A column added outside PormG is drift the other way.
        run_sql("ALTER TABLE \"$(table)\" ADD COLUMN \"extra\" TEXT;")
        r = drift()
        @test [f.detail for f in r.findings] == ["Remove field: extra"]
        @test only(r.findings).columns == ["extra"]
        @test occursin("not declared in the models", only(r.findings).message)
    finally
        run_sql("DROP TABLE IF EXISTS \"$(table)\";")
        rm(dir; recursive = true, force = true)
    end
end
