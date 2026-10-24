# MySQL backend, phase 4b (#1130, #1268): migrations that change a table that exists, against a live
# MySQL 8.4 — every change kind, the row pre-checks that refuse a change existing rows would fail, and a
# stopped alter plan finished by the next one.
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_alters.jl
#
# The layout is `test_mysql_migrations.jl`'s: this file's own models (`m4b_*` tables), on a connection
# folder of its own over the suite's MySQL database, whose `ignore_tables:` lists every other table there.
# The test user owns one database, so there is no scratch database to create. The `m4b_*` tables and the
# `pormg_migrations` history table are dropped before and after. The catalog is read and rows are seeded
# with raw SQL, since what MySQL holds is the feature under test. On another engine the whole file is
# skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, DataFrames, YAML
import PormG.Migrations

if only_on(:mysql, "alters through the MySQL DDL (phase 4b)")
@testset "MySQL migrations that change an existing table (#1268)" begin
    Mig = PormG.Migrations
    suite = PormG.config[PORMG_DB_FOLDER].connections
    raw(sql) = DataFrame(PormG.ConnectionPool.fetch(suite, sql))
    exec(sql) = PormG.ConnectionPool.fetch(suite, sql)
    scratch_tables() = String[String(r.t) for r in eachrow(raw(
        "SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'm4b\\_%'"))]
    function drop_scratch!()
        tables = scratch_tables()
        # One statement drops them all, whatever references what (MySQL has no CASCADE).
        isempty(tables) || exec("DROP TABLE " * join(("`$t`" for t in tables), ", "))
        exec("DROP TABLE IF EXISTS `pormg_migrations`")
    end
    drop_scratch!()
    others = String[String(r.t) for r in eachrow(raw(
        "SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME NOT LIKE 'm4b\\_%'"))]
    folder = mktempdir()
    yml = YAML.load_file(joinpath(@__DIR__, "db_my", "connection.yml"))
    yml[get(yml, "default_env", "dev")]["ignore_tables"] = others
    YAML.write_file(joinpath(folder, "connection.yml"), yml)
    models_path = joinpath(folder, "models.jl")
    pending = joinpath(folder, "migrations", "pending_migrations.jl")
    PormG.Configuration.load(folder)
    settings = PormG.Configuration.get_settings(folder)
    pool = settings.connections
    ignore() = Mig._with_connection_ignores(Mig._backend_ignore_tables(pool, settings), settings)
    live(table) = only(Mig.read_live_schema(pool; ignore_table = ignore(), include_table = [table]))
    write_models(src) = write(models_path, "module models\nimport PormG.Models\n" * src * "\nend\n")
    # Plan and apply; returns the plan's text. Every MySQL plan of more than one statement needs
    # `atomic = false` (#1268).
    function apply!(src)
        write_models(src)
        Mig.makemigrations(folder; interactive = false)
        plan = isfile(pending) ? read(pending, String) : ""
        isempty(plan) || Mig.migrate(folder; interactive = false, atomic = false, destructive = true)
        return plan
    end
    # The next plan after an apply is empty: the change converged.
    function converged()
        Mig.makemigrations(folder; interactive = false)
        return !isfile(pending)
    end
    try
        # What: a UniqueConstraint added to a table that exists, over rows it would reject and over rows
        # it accepts.
        # SQL: the pre-check `SELECT CAST((SELECT COALESCE(SUM(n), 0) … HAVING COUNT(*) > 1) …) AS SIGNED)`;
        #      then `CREATE UNIQUE INDEX `m4b_driver_forename_code_uniq` ON `m4b_driver` (`forename`, `code`)`.
        # Why: the step a stopped plan leaves (#1268) recorded a pre-check the 4a counter refused, so
        # `migrate` raised "phase 4b" instead of counting; the duplicates must be counted and refused
        # before any statement runs, and the clean table must take the key.
        @testset "a UniqueConstraint on a table that exists is pre-checked" begin
            driver = "Driver = Models.Model(\"m4b_driver\", driverid = Models.IDField(), " *
                     "forename = Models.CharField(max_length = 100), code = Models.CharField(max_length = 8)%s)"
            apply!(replace(driver, "%s" => ""))
            exec("INSERT INTO `m4b_driver` (`forename`, `code`) VALUES ('Ayrton', 'SEN'), ('Ayrton', 'SEN'), ('Alain', 'PRO')")
            write_models(replace(driver, "%s" => "; constraints = [Models.UniqueConstraint(fields = (\"forename\", \"code\"))]"))
            Mig.makemigrations(folder; interactive = false)
            e = try; Mig.migrate(folder; interactive = false, atomic = false); nothing; catch err; err; end
            @test e isa Mig.MigrationPrecheckError
            @test only(e.findings).kind === :add_composite_unique && only(e.findings).rows == 2
            @test isempty(live("m4b_driver").composites)
            exec("DELETE FROM `m4b_driver` WHERE `forename` = 'Ayrton' AND `driverid` > 1")
            @test Mig.migrate(folder; interactive = false, atomic = false).outcome === :applied
            @test [(c.columns, c.unique) for c in live("m4b_driver").composites] == [(["forename", "code"], true)]
            @test converged()
        end
    finally
        drop_scratch!()
        try; PormG.Configuration.close_pool!(folder); catch; end
        rm(folder; recursive = true, force = true)
    end
end
end
