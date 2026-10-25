# MySQL backend, phase 4a (#1130, #1268): migrations of a schema created from nothing, against a live
# MySQL 8.4 — `makemigrations`, `migrate`, `status` and `check`, the refusal of a multi-statement plan
# without `atomic = false`, and a plan stopped part-way and finished by a re-plan.
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_migrations.jl
#
# The models are this file's own (`m4a_*` tables), on a connection folder of its own over the suite's
# MySQL database, whose `ignore_tables:` lists every other table there, so the plans see only these.
# The test user owns one database, so there is no scratch database to create. The `m4a_*` tables and the
# `pormg_migrations` history table are dropped before and after. The catalog is read with raw SQL where
# the test checks what MySQL holds, since that is the feature under test. On another engine the whole
# file is skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, DataFrames, YAML
import PormG.Migrations

if only_on(:mysql, "migrations through the MySQL DDL (phase 4a)")
@testset "MySQL migrations of a schema created from nothing (#1268)" begin
    Mig = PormG.Migrations
    suite = PormG.config[PORMG_DB_FOLDER].connections
    raw(sql) = DataFrame(PormG.ConnectionPool.fetch(suite, sql))
    scratch = ("m4a_planted", "m4a_season", "m4a_result", "m4a_driver", "m4a_circuit", "pormg_migrations")
    drop_scratch!() = foreach(t -> PormG.ConnectionPool.fetch(suite, "DROP TABLE IF EXISTS `$t`"), scratch)
    drop_scratch!()
    others = String[String(r.t) for r in eachrow(raw(
        "SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME NOT LIKE 'm4a\\_%'"))]
    folder = mktempdir()
    yml = YAML.load_file(joinpath(@__DIR__, "db_my", "connection.yml"))
    env = yml[get(yml, "default_env", "dev")]
    env["ignore_tables"] = others
    YAML.write_file(joinpath(folder, "connection.yml"), yml)
    models_path = joinpath(folder, "models.jl")
    pending = joinpath(folder, "migrations", "pending_migrations.jl")
    base_models = """
    Circuit = Models.Model("m4a_circuit", circuitid = Models.IDField(), name = Models.CharField(max_length = 255),
      location = Models.TextField(null = true), alt = Models.IntegerField(default = 0), lat = Models.FloatField(null = true),
      url = Models.URLField(unique = true), circuitref = Models.CharField(max_length = 40, db_index = true))
    Driver = Models.Model("m4a_driver", driverid = Models.IDField(), forename = Models.CharField(max_length = 100),
      dob = Models.DateField(null = true), active = Models.BooleanField(default = true),
      created = Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"), number = Models.PositiveSmallIntegerField(null = true),
      rating = Models.DecimalField(max_digits = 6, decimal_places = 3, null = true),
      code = Models.CharField(max_length = 8, default = "a\\\\b'c");
      indexes = [Models.Index(fields = ("forename", "-dob"))],
      constraints = [Models.UniqueConstraint(fields = ("forename", "code"))])
    Result = Models.Model("m4a_result", resultid = Models.IDField(),
      driverid = Models.ForeignKey(Driver, on_delete = "CASCADE"),
      circuitid = Models.ForeignKey(Circuit, null = true, on_delete = "SET_NULL"),
      laptime = Models.TimeField(null = true), fastest = Models.DurationField(null = true),
      uid = Models.UUIDField(null = true), meta = Models.JSONField(null = true), blob = Models.BinaryField(null = true),
      notes = Models.TextField(default = "it's"), points = Models.FloatField(default = 0.0),
      grid = Models.PositiveIntegerField(default = 0), today = Models.DateField(db_default = "CURRENT_DATE"))
    """
    write_models(extra = "") = write(models_path, "module models\nimport PormG.Models\n" * base_models * extra * "\nend\n")
    write_models()
    PormG.Configuration.load(folder)
    settings = PormG.Configuration.get_settings(folder)
    pool = settings.connections
    ignore() = Mig._with_connection_ignores(Mig._backend_ignore_tables(pool, settings), settings)
    live() = Mig.read_live_schema(pool; ignore_table = ignore())
    # A table as the reader describes it, without the names a plan draws at random (`_hash_field_name`).
    shape(t) = (t.name, collect(t.columns), sort!(collect(keys(t.indexes))),
                sort!([(c.columns, c.unique, c.descending) for c in t.composites]), t.checks)
    try
        # What: a plan made from nothing, refused whole and applied with `atomic = false`.
        # SQL: `CREATE TABLE IF NOT EXISTS `m4a_…` (…) ENGINE=InnoDB …`, then `ALTER TABLE … ADD CONSTRAINT …
        #      FOREIGN KEY …` and `CREATE INDEX …` per key and index.
        # Why: each MySQL DDL statement commits on its own, so `migrate` may not promise the plan applies
        # whole (#1268); refused before anything is written, the database has no history table yet.
        @testset "a fresh plan needs atomic = false, and then applies" begin
            Mig.makemigrations(folder; interactive = false)
            plan = read(pending, String)
            @test occursin("CREATE TABLE IF NOT EXISTS `m4a_result`", plan) && !occursin("CREATE TABLE IF NOT EXISTS \"", plan)
            # 3 tables, 2 foreign keys, 3 db_index indexes (circuitref and the two keys), 2 composites.
            n_steps = count(r"^\"[^\"\n]+\" =>$"m, plan)
            @test n_steps == 10
            e = try; Mig.migrate(folder; interactive = false); nothing; catch err; err; end
            @test e isa PormG.BackendCapabilityError && occursin("atomic = false", sprint(showerror, e))
            @test !Mig._live_table_exists(pool, "m4a_driver") && !Mig._migrations_table_exists(pool)
            saved = read(pending, String)
            r = Mig.migrate(folder; interactive = false, atomic = false)
            @test r.outcome === :applied && r.n_statements == n_steps
            # The #81 case: the applied plan back as pending (an archive that failed). Recognized as the
            # latest applied, it is archived without the atomic refusal and runs nothing.
            write(pending, saved)
            @test Mig.migrate(folder; interactive = false).outcome === :already_applied
            @test !isfile(pending)
            st = Mig.status(folder)
            @test length(st.applied) == 1 && isempty(st.failed) && !st.pending
        end

        # What: the schema MySQL now holds, read back through `information_schema`, against the models.
        # SQL: the reader's five `information_schema` reads, scoped to `DATABASE()`.
        # Why: the reader-equals-compiler law (#507) on a live server: a table PormG created must read
        # back as its declaration, or the next `makemigrations` re-plans it forever.
        @testset "the applied schema reads back as its declaration, with no drift" begin
            models = Mig._load_current_models(models_path)
            tables = Dict(t.name => t for t in live())
            @test sort!(collect(keys(tables))) == ["m4a_circuit", "m4a_driver", "m4a_result"]
            for (_, entry) in models
                model = entry[:model]
                for (name, field) in model.fields
                    @test (name, tables[model.name].columns[String(name)]) ==
                          (name, Mig.column_spec(field, pool; name = String(name)))
                end
            end
            @test sort!(collect(keys(tables["m4a_result"].indexes))) == ["circuitid", "driverid"]
            @test sort!([(c.columns, c.unique, c.descending) for c in tables["m4a_driver"].composites]) ==
                  [(["forename", "code"], true, [false, false]), (["forename", "dob"], false, [false, true])]
            Mig.makemigrations(folder; interactive = false)
            @test !isfile(pending)
            @test isempty(Mig.check(folder; kinds = [:schema_drift]).findings)
            # `check`'s default kind advises on each column whose DEFAULT is an expression, declared or not,
            # as on PostgreSQL: it reads the database, not the models.
            @test sort!([(f.table, only(f.columns), f.detail) for f in Mig.check(folder).findings]) ==
                  [("m4a_driver", "created", "CURRENT_TIMESTAMP"), ("m4a_result", "today", "CURRENT_DATE")]
            @test Mig.migrate(folder; interactive = false).outcome === :nothing_pending
        end

        # What: the defaults and the CHECK the DDL wrote, on a row that names only its required column.
        # SQL: `INSERT INTO `m4a_driver` (`forename`) VALUES ('Ayrton')`, read back.
        # Why: a literal default is written MySQL's way (a backslash doubled, a TEXT default as an
        # expression) and `CURRENT_TIMESTAMP(3)` on a `DATETIME(3)`; a wrong spelling stores another value.
        @testset "the defaults and checks the DDL wrote hold" begin
            PormG.ConnectionPool.fetch(suite, "INSERT INTO `m4a_driver` (`forename`) VALUES ('Ayrton')")
            row = raw("SELECT `code`, `active`, `created` IS NOT NULL AS has_created FROM `m4a_driver`")
            @test row[1, :code] == "a\\b'c" && row[1, :active] == 1 && row[1, :has_created] == 1
            e = try; PormG.ConnectionPool.fetch(suite, "INSERT INTO `m4a_driver` (`forename`, `number`) VALUES ('Alain', -1)"); nothing; catch err; err; end
            # MySQL's error 3819: the `>= 0` CHECK the DDL wrote, not another failure.
            @test e isa PormG.IntegrityError && occursin("3819", sprint(showerror, e.cause))
            @test raw("SELECT COUNT(*) AS n FROM `m4a_driver`")[1, :n] == 1
            PormG.ConnectionPool.fetch(suite, "INSERT INTO `m4a_circuit` (`name`, `url`, `circuitref`) VALUES ('Interlagos', 'u', 'interlagos')")
            PormG.ConnectionPool.fetch(suite, "INSERT INTO `m4a_result` (`driverid`) VALUES (1)")
            row = raw("SELECT `notes`, `grid`, `today` IS NOT NULL AS has_today FROM `m4a_result`")
            @test row[1, :notes] == "it's" && row[1, :grid] == 0 && row[1, :has_today] == 1
        end

        # What: a plan of one statement, and a change to a table that exists, reported then applied.
        # SQL: `CREATE TABLE IF NOT EXISTS `m4a_season` (…)` alone; then
        #      `ALTER TABLE `m4a_driver` MODIFY COLUMN `forename` VARCHAR(120) NOT NULL;`.
        # Why: one statement is atomic on MySQL 8.0+, so it needs no opt-in; since phase 4b a change to an
        # existing column is planned (MySQL's own `MODIFY`), and the drift gate reports it before it runs.
        @testset "one statement runs as it is; a change to an existing table is planned" begin
            write_models("Season = Models.Model(\"m4a_season\", seasonid = Models.IDField(), year = Models.IntegerField())\n")
            Mig.makemigrations(folder; interactive = false)
            @test Mig.migrate(folder; interactive = false).outcome === :applied
            @test Mig._live_table_exists(pool, "m4a_season")
            write(models_path, replace(read(models_path, String), "forename = Models.CharField(max_length = 100)" =>
                                                                  "forename = Models.CharField(max_length = 120)"))
            @test !isempty(Mig.check(folder; kinds = [:schema_drift]).findings)
            Mig.makemigrations(folder; interactive = false)
            @test occursin("MODIFY COLUMN `forename` VARCHAR(120) NOT NULL", read(pending, String))
            @test Mig.migrate(folder; interactive = false).outcome === :applied
            Mig.makemigrations(folder; interactive = false)
            @test !isfile(pending)
        end

        # What: #1268's acceptance — a plan stopped at a statement part-way, then finished by a re-plan.
        # SQL: the plan up to the `ADD CONSTRAINT` whose name a planted table holds (error 1826), each
        # statement before it committed; after the planted table is gone, a plan of the missing steps.
        # Why: without transactional DDL a failure leaves the statements before it applied; the history
        # must say `failed`, and the next `makemigrations` must plan exactly what is missing, so the
        # schema ends as a clean apply's.
        @testset "a plan stopped part-way is finished by the next plan (#1268)" begin
            write_models()
            drop_scratch!()
            Mig.makemigrations(folder; interactive = false)
            Mig.migrate(folder; interactive = false, atomic = false)
            clean = sort!([shape(t) for t in live()]; by = first)
            drop_scratch!()

            Mig.makemigrations(folder; interactive = false)
            fk = match(r"ADD CONSTRAINT `(m4a_result_circuitid_[0-9A-Za-z]+_fk)`", read(pending, String))[1]
            PormG.ConnectionPool.fetch(suite, "CREATE TABLE `m4a_planted` (`id` BIGINT NOT NULL PRIMARY KEY, `p` BIGINT NULL, " *
                                              "CONSTRAINT `$fk` FOREIGN KEY (`p`) REFERENCES `m4a_planted` (`id`)) ENGINE=InnoDB")
            e = try; Mig.migrate(folder; interactive = false, atomic = false); nothing; catch err; err; end
            @test e isa PormG.PormGError
            st = Mig.status(folder)
            @test length(st.failed) == 1 && isempty(st.applied) && st.pending
            # The tables and the statements before the failed one are there; the planted name is not ours.
            @test all(t -> Mig._live_table_exists(pool, t), ("m4a_circuit", "m4a_driver", "m4a_result"))
            stopped = Mig.read_live_schema(pool; ignore_table = ignore(), include_table = ["m4a_result"])[1]
            @test stopped.columns["circuitid"].reference === nothing
            # The driverid key ran, so InnoDB made it an index named after the constraint; the plan's own
            # index on it did not run yet, and InnoDB's is not a `db_index`.
            @test stopped.columns["driverid"].reference !== nothing && !haskey(stopped.indexes, "driverid")
            @test any(r -> endswith(String(r.idx), "_fk"), eachrow(raw(
                "SELECT INDEX_NAME AS idx FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() " *
                "AND TABLE_NAME = 'm4a_result' AND COLUMN_NAME = 'driverid'")))

            PormG.ConnectionPool.fetch(suite, "DROP TABLE `m4a_planted`")
            # The drift gate reports what the stopped plan left out.
            @test !isempty(Mig.check(folder; kinds = [:schema_drift]).findings)
            Mig.makemigrations(folder; interactive = false)
            rest = read(pending, String)
            @test occursin("ADD CONSTRAINT", rest) && !occursin("CREATE TABLE", rest)
            @test occursin("\"Create index on driverid\"", rest)
            r = Mig.migrate(folder; interactive = false, atomic = false)
            @test r.outcome === :applied
            @test sort!([shape(t) for t in live()]; by = first) == clean
            Mig.makemigrations(folder; interactive = false)
            @test !isfile(pending)
        end
    finally
        drop_scratch!()
        try; PormG.Configuration.close_pool!(folder); catch; end
        rm(folder; recursive = true, force = true)
    end
end
end
