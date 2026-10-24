# MySQL backend, phase 4c (#1130): `inspectdb` — `import_models_from_mysql` reading a live MySQL 8.4 schema
# into a models file: one PormG created (its CHECKs, functional index and stamped default included), which
# must converge with the models it is read into, and one made by hand, whose types and SQL PormG reads as
# far as their values allow, saying what it cannot.
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_inspectdb.jl
#
# The layout is `test_mysql_alters.jl`'s: `m4c_*` tables on a connection folder of its own over the suite's
# MySQL database, whose `ignore_tables:` lists every other table there; the `m4c_*` tables, their views and
# the history tables are dropped before and after. Hand-made schema is written with raw SQL, since what
# MySQL holds is the input under test. On another engine the whole file is skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, DataFrames, YAML
import PormG.Migrations

if only_on(:mysql, "inspectdb on MySQL (phase 4c)")
@testset "inspectdb on MySQL (#1130)" begin
    Mig = PormG.Migrations
    suite = PormG.config[PORMG_DB_FOLDER].connections
    raw(sql) = DataFrame(PormG.ConnectionPool.fetch(suite, sql))
    exec(sql) = PormG.ConnectionPool.fetch(suite, sql)
    scratch(kind) = String[String(r.t) for r in eachrow(raw(
        "SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() " *
        "AND TABLE_TYPE = '$(kind)' AND TABLE_NAME LIKE 'm4c\\_%'"))]
    function drop_scratch!()
        views = scratch("VIEW")
        isempty(views) || exec("DROP VIEW " * join(("`$v`" for v in views), ", "))
        tables = scratch("BASE TABLE")
        isempty(tables) || exec("DROP TABLE " * join(("`$t`" for t in tables), ", "))
        exec("DROP TABLE IF EXISTS `pormg_migrations`")
        exec("DROP TABLE IF EXISTS `pormg_migrations_data`")
    end
    drop_scratch!()
    others = String[String(r.t) for r in eachrow(raw(
        "SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME NOT LIKE 'm4c\\_%'"))]
    folder = mktempdir()
    yml = YAML.load_file(joinpath(@__DIR__, "db_my", "connection.yml"))
    yml[get(yml, "default_env", "dev")]["ignore_tables"] = others
    YAML.write_file(joinpath(folder, "connection.yml"), yml)
    models_path = joinpath(folder, "models.jl")
    pending = joinpath(folder, "migrations", "pending_migrations.jl")
    PormG.Configuration.load(folder)
    settings = PormG.Configuration.get_settings(folder)
    pool = settings.connections
    write_models(src) = write(models_path, "module models\nimport PormG.Models\n" * src * "\nend\n")
    function apply!(src)
        write_models(src)
        Mig.makemigrations(folder; interactive = false)
        isfile(pending) && Mig.migrate(folder; interactive = false, atomic = false, destructive = true)
    end
    converged() = (Mig.makemigrations(folder; interactive = false); !isfile(pending))
    # `inspectdb` into the folder's own models file, so the next `makemigrations` reads what it wrote.
    import!(tables; views = false) = Mig.import_models_from_mysql(folder; file = "models.jl", force_replace = true,
                                                                  include_table = tables, include_views = views)
    try
        # What: a schema PormG created — keys, a composite key, a positive integer, a uuid, a duration, a
        # declared CHECK, a functional index, a per-engine and a portable default, a view — read back.
        # SQL: the catalog reads of `read_live_schema` and `read_live_views`; no DDL after the import.
        # Why: the `inspectdb` promise: a models file written from a database converges with it. On MySQL
        # that rests on reading its re-printed SQL in declarable form, and on the marker of each declaration.
        @testset "a schema PormG created imports into models that converge" begin
            apply!("""
                Circuit = Models.Model("m4c_circuit", circuitid = Models.IDField(), name = Models.CharField(max_length = 255),
                    alt = Models.IntegerField(default = 0), url = Models.URLField(unique = true),
                    created = Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"))
                Driver = Models.Model("m4c_driver", driverid = Models.IDField(), forename = Models.CharField(max_length = 100, db_index = true),
                    code = Models.CharField(max_length = 8, db_default = (postgres = "lower('X')", mysql = "lower('X')")),
                    number = Models.PositiveSmallIntegerField(null = true), dob = Models.DateField(null = true),
                    uid = Models.UUIDField(null = true), meta = Models.JSONField(null = true), fastest = Models.DurationField(null = true);
                    constraints = [Models.CheckConstraint(condition = "number <= 99", name = "m4c_driver_number_cap")],
                    indexes = [Models.Index(expressions = ("lower(forename)",), name = "m4c_driver_fn_idx")])
                Result = Models.Model("m4c_result", resultid = Models.IDField(),
                    driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "CASCADE"),
                    circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", null = true),
                    points = Models.FloatField(default = 0.0), laps = Models.BigIntegerField(default = 0);
                    constraints = [Models.UniqueConstraint(fields = ("driverid", "circuitid"))])""")
            @test converged()
            exec("CREATE VIEW `m4c_driver_codes` AS SELECT `driverid`, `code` FROM `m4c_driver`")
            import!(["m4c_circuit", "m4c_driver", "m4c_result", "m4c_driver_codes"]; views = true)
            text = read(models_path, String)
            @test occursin("db_default=(mysql = \"lower('X')\",)", text) && occursin("db_default=\"CURRENT_TIMESTAMP\"", text)
            @test occursin("Models.CheckConstraint(condition = \"(number <= 99)\", name = \"m4c_driver_number_cap\")", text)
            @test occursin("expressions = (\"lower(forename)\",)", text) && occursin("Models.UUIDField", text)
            @test occursin("fastest = Models.BigIntegerField", text) && occursin("number = Models.PositiveSmallIntegerField", text)
            @test occursin("Models.Model(\"m4c_driver_codes\", managed = false", text)
            @test converged()
            exec("DROP VIEW `m4c_driver_codes`")
            # `check` reads the same columns: each expression default, in the text it advises declaring.
            found = [(f.table, only(f.columns), f.detail) for f in Mig.check(folder; kinds = [:expression_default]).findings]
            @test ("m4c_driver", "code", "lower('X')") in found && ("m4c_circuit", "created", "CURRENT_TIMESTAMP") in found
        end

        # What: a schema made by hand: an `INT` key, an unsigned integer, an `enum`, a `datetime(6)`, a
        # `timestamp`, `text`, a generated column, a reserved-word column and its CHECK, a plain CHECK, a
        # default in no declarable form; and a view over a table dropped since.
        # SQL: the catalog reads; then the plan the imported models give.
        # Why: what holds PormG's values must read as its fields and plan nothing; what does not must be
        # said, by name — a retyped column, a generated column declared plain, a CHECK left out — never
        # written as another engine's SQL nor silently dropped.
        @testset "a schema made by hand imports as far as its values allow, and says what it cannot" begin
            exec("CREATE TABLE `m4c_legacy` (`legacyid` INT NOT NULL AUTO_INCREMENT PRIMARY KEY, `u` INT UNSIGNED NULL, " *
                 "`e` ENUM('a','b') NULL, `at` DATETIME(6) NULL, `stamp` TIMESTAMP NULL, `note` TEXT NULL, " *
                 "`twice` INT GENERATED ALWAYS AS (`u` * 2) VIRTUAL, `order` INT NULL, " *
                 "`odd` VARCHAR(9) NULL DEFAULT (concat('a\\\\b')), " *
                 "CONSTRAINT `m4c_legacy_order_pos` CHECK (`order` > 0), CONSTRAINT `m4c_legacy_note` CHECK (`note` <> 'x')) " *
                 "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin")
            exec("CREATE TABLE `m4c_gone` (`goneid` BIGINT NOT NULL PRIMARY KEY)")
            exec("CREATE VIEW `m4c_gone_view` AS SELECT `goneid` FROM `m4c_gone`")
            exec("DROP TABLE `m4c_gone`")
            @test_logs (:warn, r"IDField is BIGINT AUTO_INCREMENT") (:warn, r"no PormG field type") (:warn, r"no PormG field type") (:warn, r"generated column made by hand") (:warn, r"CHECK whose condition MySQL prints") (:warn, r"view could not be read") match_mode = :any import!(["m4c_legacy", "m4c_gone_view"]; views = true)
            text = read(models_path, String)
            @test occursin("at = Models.DateTimeField", text) && occursin("stamp = Models.DateTimeField", text) &&
                  occursin("note = Models.TextField", text) && occursin("u = Models.TextField", text) && occursin("e = Models.TextField", text)
            @test occursin("Models.CheckConstraint(condition = \"(note <> 'x')\", name = \"m4c_legacy_note\")", text)
            @test !occursin("m4c_legacy_order_pos", text) && !occursin("Models.Model(\"m4c_gone_view\"", text) &&
                  occursin("a view could not be read", text)
            Mig.makemigrations(folder; interactive = false)
            plan = read(pending, String)
            @test occursin("MODIFY COLUMN `u` LONGTEXT", plan) && occursin("MODIFY COLUMN `e` LONGTEXT", plan) &&
                  occursin("MODIFY COLUMN `legacyid` BIGINT", plan)
            @test !occursin(r"MODIFY COLUMN `(at|stamp|note|order)`", plan) && !occursin("m4c_legacy_order_pos", plan)
        end
    finally
        drop_scratch!()
        try; PormG.Configuration.close_pool!(folder); catch; end
        rm(folder; recursive = true, force = true)
    end
end
end
