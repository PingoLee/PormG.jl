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
        exec("DROP TABLE IF EXISTS `pormg_migrations_data`")
    end
    drop_scratch!()
    others = String[String(r.t) for r in eachrow(raw(
        "SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME NOT LIKE 'm4b\\_%'"))]
    folder = mktempdir()
    yml = YAML.load_file(joinpath(@__DIR__, "db_my", "connection.yml"))
    # `m4b_ext` stands for a table outside what PormG reads: it holds a foreign key to a table a plan drops.
    yml[get(yml, "default_env", "dev")]["ignore_tables"] = vcat(others, ["m4b_ext"])
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
    function apply!(src; renames = Pair{String, Union{String, Nothing}}[])
        write_models(src)
        Mig.makemigrations(folder; interactive = false, renames = renames)
        plan = isfile(pending) ? read(pending, String) : ""
        isempty(plan) || Mig.migrate(folder; interactive = false, atomic = false, destructive = true)
        return plan
    end
    # The next plan after an apply is empty: the change converged.
    function converged()
        Mig.makemigrations(folder; interactive = false)
        return !isfile(pending)
    end
    # One session variable on every connection of the folder's pool, each leased at once so each is a
    # different connection: what a plan set on the one it ran on must not reach any of them.
    function every_session(var)
        held = [PormG.ConnectionPool.acquire_connection(pool) for _ in 1:pool.pool_size]
        try
            return [DataFrame(first(PormG.ConnectionPool.with_transaction(pool, "SELECT @@SESSION.$(var) AS v"; conn = c)))[1, :v]
                    for c in held]
        finally
            foreach(c -> PormG.ConnectionPool.release_connection(pool, c), held)
        end
    end
    column_row(table, col) = raw("SELECT COLUMN_DEFAULT AS d, COLUMN_COMMENT AS c, COLLATION_NAME AS k, IS_NULLABLE AS n " *
        "FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '$(table)' AND COLUMN_NAME = '$(col)'")[1, :]
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

        # A plan the row pre-checks refuse, with the kind and count they report; nothing of it runs.
        function refused_by_precheck(src)
            write_models(src)
            Mig.makemigrations(folder; interactive = false)
            e = try; Mig.migrate(folder; interactive = false, atomic = false, destructive = true); nothing; catch err; err; end
            e isa Mig.MigrationPrecheckError || return e
            return sort!([(f.kind, f.rows) for f in e.findings if something(f.rows, 0) > 0])
        end
        circuit(fields) = "Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField(), $(fields))"

        # What: columns added to a table that exists — nullable, with a default, and NOT NULL without one.
        # SQL: `ALTER TABLE `m4b_circuit` ADD COLUMN `alt` INT NOT NULL DEFAULT 0;`, …
        # Why: MySQL fills a NOT NULL column with no default with an implicit value (`0`, `''`) where
        # PostgreSQL fails, so the row pre-check must refuse it over rows (`:add_not_null`), as it does
        # on PostgreSQL; on an empty table it applies.
        @testset "added columns" begin
            apply!(circuit("name = Models.CharField(max_length = 100)"))
            exec("INSERT INTO `m4b_circuit` (`name`) VALUES ('Interlagos'), ('Monza')")
            @test refused_by_precheck(circuit("name = Models.CharField(max_length = 100), lat = Models.FloatField()")) ==
                  [(:add_not_null, 2)]
            apply!(circuit("name = Models.CharField(max_length = 100), lat = Models.FloatField(null = true), " *
                           "alt = Models.IntegerField(default = 0), notes = Models.TextField(default = \"n/a\")"))
            @test raw("SELECT `alt`, `notes`, `lat` IS NULL AS no_lat FROM `m4b_circuit` ORDER BY `circuitid`")[1, :] |>
                  collect == [0, "n/a", 1]
            @test converged()
        end

        # What: retypes and nullability over rows that fit and rows that do not.
        # SQL: `ALTER TABLE `m4b_circuit` MODIFY COLUMN `name` VARCHAR(5) NOT NULL;`, …
        # Why: under MySQL's strict mode a row that does not fit fails the ALTER part-way through a plan
        # (#1268); each kind is counted first and refused with its count — a string too long (trailing
        # spaces included, unlike PostgreSQL), an integer out of range, text that is not a number, a
        # NULL under NOT NULL — and applies once the rows fit.
        @testset "retypes and NOT NULL are pre-checked" begin
            base = "name = Models.CharField(max_length = 100), lat = Models.FloatField(null = true), " *
                   "alt = Models.IntegerField(default = 0), notes = Models.TextField(default = \"n/a\")"
            exec("UPDATE `m4b_circuit` SET `alt` = 70000, `notes` = '12' WHERE `name` = 'Monza'")
            @test refused_by_precheck(circuit(replace(base, "max_length = 100" => "max_length = 5"))) == [(:varchar_length, 1)]
            @test refused_by_precheck(circuit(replace(base, "alt = Models.IntegerField(default = 0)" =>
                                                            "alt = Models.PositiveSmallIntegerField(default = 0)"))) ==
                  [(:integer_range, 1)]
            @test refused_by_precheck(circuit(replace(base, "notes = Models.TextField(default = \"n/a\")" =>
                                                            "notes = Models.IntegerField(default = 0)"))) == [(:text_cast, 1)]
            @test refused_by_precheck(circuit(replace(base, "lat = Models.FloatField(null = true)" =>
                                                            "lat = Models.FloatField(default = 0.0)"))) == [(:set_not_null, 2)]
            exec("UPDATE `m4b_circuit` SET `name` = LEFT(`name`, 5), `alt` = 7, `notes` = '3', `lat` = 1.5")
            apply!(circuit("name = Models.CharField(max_length = 5), lat = Models.FloatField(default = 0.0), " *
                           "alt = Models.PositiveSmallIntegerField(default = 0), notes = Models.IntegerField(default = 0)"))
            spec = live("m4b_circuit").columns
            @test spec["name"].type == PormG.CVarChar(5) && spec["alt"].type == PormG.CInt16() &&
                  spec["alt"].checks == [PormG.NonNegativeCheck()] && spec["notes"].type == PormG.CInt32() &&
                  !spec["lat"].nullable
            @test raw("SELECT `notes` FROM `m4b_circuit` ORDER BY `circuitid`")[!, :notes] == [3, 3]
            @test converged()
            # PormG's CHECK holds: a negative value is refused by it (3819), and dropped with the field kind.
            e = try; exec("UPDATE `m4b_circuit` SET `alt` = -1"); nothing; catch err; err; end
            @test e isa PormG.IntegrityError && occursin("3819", sprint(showerror, e.cause))
            apply!(circuit("name = Models.CharField(max_length = 5), lat = Models.FloatField(default = 0.0), " *
                           "alt = Models.IntegerField(default = 0), notes = Models.IntegerField(default = 0)"))
            @test isempty(live("m4b_circuit").columns["alt"].checks)
            @test converged()
        end

        # What: a column's own unique key added and dropped, and the column renamed with it and a CHECK.
        # SQL: `ALTER TABLE … ADD UNIQUE INDEX `code` (`code`)`; `ALTER TABLE … DROP CHECK `m4b_team_chk_1`,
        #      RENAME COLUMN `code` TO `abbr`, RENAME INDEX `code` TO `abbr`, ADD CHECK (`abbr` …)`.
        # Why: MySQL refuses to rename a column a CHECK names (3959) and keeps the unique index's old
        # name, which the reader would then take for a model-level index; the rename must converge.
        @testset "unique keys and a renamed column" begin
            team(code) = "Team = Models.Model(\"m4b_team\", teamid = Models.IDField(), $(code), " *
                         "points = Models.PositiveIntegerField(default = 0))"
            apply!(team("code = Models.CharField(max_length = 8)"))
            exec("INSERT INTO `m4b_team` (`code`) VALUES ('MCL'), ('MCL')")
            @test refused_by_precheck(team("code = Models.CharField(max_length = 8, unique = true)")) == [(:add_unique, 2)]
            exec("UPDATE `m4b_team` SET `code` = 'FER' WHERE `teamid` = 2")
            apply!(team("code = Models.CharField(max_length = 8, unique = true)"))
            @test live("m4b_team").columns["code"].unique && converged()
            plan = apply!(replace(team("abbr = Models.CharField(max_length = 8, unique = true)"), "points" => "pts");
                          renames = Pair{String, Union{String, Nothing}}["m4b_team.code" => "m4b_team.abbr",
                                                                         "m4b_team.points" => "m4b_team.pts"])
            @test occursin("RENAME COLUMN `code` TO `abbr`", plan) && occursin("RENAME INDEX `code` TO `abbr`", plan)
            t = live("m4b_team")
            @test t.columns["abbr"].unique && t.columns["pts"].checks == [PormG.NonNegativeCheck()] &&
                  isempty(t.composites) && !haskey(t.columns, "code")
            @test converged()
            apply!(replace(team("abbr = Models.CharField(max_length = 8)"), "points" => "pts"))
            @test !live("m4b_team").columns["abbr"].unique && converged()
        end

        # What: a foreign key added to a table that exists, re-pointed, and dropped (its column kept).
        # SQL: `ADD CONSTRAINT … FOREIGN KEY`; `DROP FOREIGN KEY …`, then `ADD CONSTRAINT` again; on a drop,
        #      `ALTER TABLE … DROP FOREIGN KEY `<k>`, DROP INDEX `<k>``.
        # Why: InnoDB keeps the index it made for a key after `DROP FOREIGN KEY`, and the reader would take
        # it for an undeclared `db_index` (#1268); the plan drops it with the key, so the next plan is empty.
        @testset "foreign keys added, re-pointed and dropped" begin
            parents = "Team = Models.Model(\"m4b_team\", teamid = Models.IDField(), abbr = Models.CharField(max_length = 8), " *
                      "pts = Models.PositiveIntegerField(default = 0))\n"
            seat(fk) = parents * "Seat = Models.Model(\"m4b_seat\", seatid = Models.IDField(), $(fk))"
            apply!(seat("teamid = Models.BigIntegerField(null = true)"))
            exec("INSERT INTO `m4b_seat` (`teamid`) VALUES (1), (99)")
            fk(on_delete) = "teamid = Models.ForeignKey(Team, pk_field = \"teamid\", null = true, on_delete = \"$(on_delete)\", db_index = false)"
            @test refused_by_precheck(seat(fk("CASCADE"))) == [(:add_foreign_key, 1)]
            exec("DELETE FROM `m4b_seat` WHERE `teamid` = 99")
            apply!(seat(fk("CASCADE")))
            @test live("m4b_seat").columns["teamid"].reference.on_delete == "CASCADE" && converged()
            apply!(seat(fk("SET_NULL")))
            @test live("m4b_seat").columns["teamid"].reference.on_delete == "SET NULL" && converged()
            plan = apply!(seat("teamid = Models.BigIntegerField(null = true)"))
            @test occursin(r"DROP FOREIGN KEY `[^`]+`, DROP INDEX `[^`]+`", plan)
            t = live("m4b_seat")
            @test t.columns["teamid"].reference === nothing && isempty(t.indexes)
            @test raw("SELECT COUNT(*) AS n FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() " *
                      "AND TABLE_NAME = 'm4b_seat' AND INDEX_NAME <> 'PRIMARY'")[1, :n] == 0
            @test converged()
        end

        # What: a `db_index` and model-level indexes added, renamed and dropped on a table that exists.
        # SQL: `CREATE INDEX …`; `ALTER TABLE `m4b_team` RENAME INDEX `a` TO `b``; `DROP INDEX `b` ON `m4b_team``.
        # Why: a MySQL index is named per table, so its drop and rename must name the table, and none of it
        # existed before phase 4b.
        @testset "indexes added, renamed and dropped" begin
            team(tail) = "Team = Models.Model(\"m4b_team\", teamid = Models.IDField(), abbr = Models.CharField(max_length = 8, db_index = true), " *
                         "pts = Models.PositiveIntegerField(default = 0)$(tail))"
            ix(n) = "; indexes = [Models.Index(fields = (\"abbr\", \"-pts\"), name = \"$(n)\")]"
            apply!(team(""))
            @test haskey(live("m4b_team").indexes, "abbr") && converged()
            apply!(team(ix("m4b_team_a_idx")))
            @test [(c.name, c.marker) for c in live("m4b_team").composites] == [("m4b_team_a_idx", PormG.INDEX_MARKER)] &&
                  converged()
            apply!(team(ix("m4b_team_b_idx")))
            @test [c.name for c in live("m4b_team").composites] == ["m4b_team_b_idx"] && converged()
            apply!(replace(team(""), ", db_index = true" => ""))
            t = live("m4b_team")
            # The descending index was PormG's (its COMMENT carries the marker), so it is dropped too.
            @test isempty(t.composites) && isempty(t.indexes) && converged()
        end

        # What: a column dropped from under a UniqueConstraint, with rows the rest of the key repeats.
        # SQL: `DROP INDEX `m4b_team_abbr_pts_uniq` ON `m4b_team``, then `ALTER TABLE `m4b_team` DROP COLUMN `pts``.
        # Why: MySQL narrows the index to `UNIQUE (abbr)` instead of dropping it with the column (PostgreSQL's
        # meaning), so the DROP COLUMN fails on the repeated `abbr` (1062); the plan drops the index first.
        @testset "a column dropped from under a composite key" begin
            team(pts, tail) = "Team = Models.Model(\"m4b_team\", teamid = Models.IDField(), abbr = Models.CharField(max_length = 8)$(pts)$(tail))"
            pts = ", pts = Models.PositiveIntegerField(default = 0)"
            apply!(team(pts, "; constraints = [Models.UniqueConstraint(fields = (\"abbr\", \"pts\"))]"))
            exec("INSERT INTO `m4b_team` (`abbr`, `pts`) VALUES ('WIL', 1), ('WIL', 2)")
            plan = apply!(team("", ""))
            @test occursin(r"DROP INDEX `m4b_team_abbr_pts_uniq` ON `m4b_team`;[\s\S]*DROP COLUMN `pts`", plan)
            t = live("m4b_team")
            @test !haskey(t.columns, "pts") && isempty(t.composites) && isempty(t.indexes) && converged()
            apply!(team(pts, ""))
            @test haskey(live("m4b_team").columns, "pts") && converged()
        end

        # What: a column dropped from under a composite key that a foreign key needs (its only index).
        # SQL: none while the key stays (`makemigrations` refuses); when the key goes too, `DROP FOREIGN KEY`
        #      before `DROP INDEX `m4b_turn_trackid_n_uniq``, before `DROP COLUMN `n``.
        # Why: MySQL keeps every foreign key indexed (1553): the index cannot go before the key does, and a key
        # that stays would be left without one, which only an earlier migration indexing it can avoid.
        @testset "a composite a foreign key needs" begin
            team = "Team = Models.Model(\"m4b_team\", teamid = Models.IDField(), abbr = Models.CharField(max_length = 8), " *
                   "pts = Models.PositiveIntegerField(default = 0))\n"
            turn(key, n, tail) = team * "Track = Models.Model(\"m4b_track\", trackid = Models.IDField())\n" *
                                 "Turn = Models.Model(\"m4b_turn\", turnid = Models.IDField(), trackid = $(key)$(n)$(tail))"
            fk = "Models.ForeignKey(Track, pk_field = \"trackid\", null = true, db_index = false)"
            n = ", n = Models.IntegerField(default = 0)"
            apply!(turn(fk, n, "; constraints = [Models.UniqueConstraint(fields = (\"trackid\", \"n\"))]"))
            write_models(turn(fk, "", ""))
            e = try; Mig.makemigrations(folder; interactive = false); nothing; catch err; err; end
            @test e isa PormG.InvalidMigrationError &&
                  occursin("only index of the foreign key on 'trackid'", sprint(showerror, e)) && !isfile(pending)
            plan = apply!(turn("Models.BigIntegerField(null = true)", "", ""))
            @test occursin(r"DROP FOREIGN KEY[\s\S]*DROP INDEX `m4b_turn_trackid_n_uniq`[\s\S]*DROP COLUMN `n`", plan)
            t = live("m4b_turn")
            @test t.columns["trackid"].reference === nothing && isempty(t.composites) && converged()
            # With the key column indexed on its own (the default `db_index = true`), the catalog says the key
            # keeps an index, and the composite goes first.
            keyed = "Models.ForeignKey(Track, pk_field = \"trackid\", null = true)"
            apply!(turn(keyed, n, "; constraints = [Models.UniqueConstraint(fields = (\"trackid\", \"n\"))]"))
            plan = apply!(turn(keyed, "", ""))
            @test occursin(r"DROP INDEX `m4b_turn_trackid_n_uniq`[\s\S]*DROP COLUMN `n`", plan)
            t = live("m4b_turn")
            @test t.columns["trackid"].reference !== nothing && haskey(t.indexes, "trackid") && isempty(t.composites) &&
                  converged()
        end

        # What: a table renamed (by a rename hint) with a CHECKed column renamed in the same plan, and a parent
        # and its child dropped together.
        # SQL: `RENAME TABLE `m4b_team` TO `m4b_constructor``, then `ALTER TABLE `m4b_constructor` DROP CHECK
        #      `m4b_constructor_chk_1`, RENAME COLUMN `pts` TO `points`, ADD CHECK …`; `SET FOREIGN_KEY_CHECKS = 0;
        #      DROP TABLE …`.
        # Why: the table rename runs first and renames the CHECKs MySQL named, so the column's DROP CHECK must
        # name the new one (3821/3959 after `RENAME TABLE` committed otherwise). MySQL has no `DROP TABLE …
        # CASCADE` and refuses to drop a table another references (3730); the plan drops each with the
        # session's key checks off, on the one connection the plan runs on.
        @testset "tables renamed and dropped" begin
            write_models("Constructor = Models.Model(\"m4b_constructor\", teamid = Models.IDField(), " *
                         "abbr = Models.CharField(max_length = 8), points = Models.PositiveIntegerField(default = 0))\n" *
                         "Seat = Models.Model(\"m4b_seat\", seatid = Models.IDField(), teamid = Models.BigIntegerField(null = true))")
            Mig.makemigrations(folder; interactive = false,
                               renames = ["m4b_team" => "m4b_constructor", "m4b_constructor.pts" => "m4b_constructor.points"])
            plan = read(pending, String)
            @test occursin("RENAME TABLE `m4b_team` TO `m4b_constructor`", plan) &&
                  occursin(r"DROP CHECK `m4b_constructor_chk_\d+`, RENAME COLUMN `pts` TO `points`", plan)
            Mig.migrate(folder; interactive = false, atomic = false, destructive = true, lock_timeout = 2.5)
            @test "m4b_constructor" in scratch_tables() && !("m4b_team" in scratch_tables()) && converged()
            @test live("m4b_constructor").columns["points"].checks == [PormG.NonNegativeCheck()]
            apply!("Constructor = Models.Model(\"m4b_constructor\", teamid = Models.IDField(), " *
                   "abbr = Models.CharField(max_length = 8), points = Models.PositiveIntegerField(default = 0))\n" *
                   "Seat = Models.Model(\"m4b_seat\", seatid = Models.IDField(), teamid = Models.ForeignKey(Constructor, " *
                   "pk_field = \"teamid\", null = true))")
            @test live("m4b_seat").columns["teamid"].reference !== nothing && converged()
            # The parent and its child dropped together: the parent first, its child's key notwithstanding.
            apply!("Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField())")
            @test !("m4b_seat" in scratch_tables()) && !("m4b_constructor" in scratch_tables()) && converged()
            # The connections the plans ran on were renewed: none in the pool has the key checks off, or the
            # `lock_wait_timeout` the rename plan set (`lock_timeout = 2.5`, three seconds).
            @test all(==(1), every_session("FOREIGN_KEY_CHECKS")) && !any(==(3), every_session("lock_wait_timeout"))
        end

        # What: a table dropped while a table PormG does not read (an ignored one) holds a foreign key to it.
        # SQL: none — `makemigrations` refuses, naming the key; once it is gone, `DROP TABLE` runs.
        # Why: the drop runs with the key checks off, so the key would be left pointing at a missing table
        # (PostgreSQL's `CASCADE` removes it); PormG manages neither that table nor its key.
        @testset "a dropped table another table's key points at is refused" begin
            apply!("Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField())\n" *
                   "Venue = Models.Model(\"m4b_venue\", venueid = Models.IDField())")
            exec("CREATE TABLE `m4b_ext` (`id` BIGINT NOT NULL PRIMARY KEY, `venueid` BIGINT NULL, " *
                 "CONSTRAINT `m4b_ext_venue_fk` FOREIGN KEY (`venueid`) REFERENCES `m4b_venue` (`venueid`)) ENGINE=InnoDB")
            write_models("Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField())")
            e = try; Mig.makemigrations(folder; interactive = false); nothing; catch err; err; end
            @test e isa PormG.InvalidMigrationError &&
                  occursin("foreign key `m4b_ext_venue_fk` on `m4b_ext`", sprint(showerror, e)) && !isfile(pending)
            exec("DROP TABLE `m4b_ext`")
            # An unmanaged model's table is read but never migrated: its key is not the plan's either.
            exec("CREATE TABLE `m4b_view_src` (`id` BIGINT NOT NULL PRIMARY KEY, `venueid` BIGINT NULL, " *
                 "CONSTRAINT `m4b_view_src_fk` FOREIGN KEY (`venueid`) REFERENCES `m4b_venue` (`venueid`)) ENGINE=InnoDB")
            unmanaged = "\nSource = Models.Model(\"m4b_view_src\"; managed = false, id = Models.IDField(), " *
                        "venueid = Models.BigIntegerField(null = true))"
            write_models("Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField())" * unmanaged)
            e = try; Mig.makemigrations(folder; interactive = false); nothing; catch err; err; end
            @test e isa PormG.InvalidMigrationError && occursin("foreign key `m4b_view_src_fk` on `m4b_view_src`", sprint(showerror, e))
            exec("DROP TABLE `m4b_view_src`")
            apply!("Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField())")
            @test !("m4b_venue" in scratch_tables()) && converged()
        end

        # What: a column change over a column carrying what no model states — an expression default, a COMMENT,
        # its own collation — set by hand.
        # SQL: `ALTER TABLE `m4b_car` MODIFY COLUMN `tag` VARCHAR(40) NULL DEFAULT (uuid()) COMMENT 'set by hand'
        #      COLLATE utf8mb4_0900_ai_ci;`, then a retype without the default.
        # Why: MODIFY resets what it does not restate, where PostgreSQL's per-slot ALTER changes only the slot;
        # a retype drops the expression default (it may not suit the new type), which takes `destructive`.
        @testset "a MODIFY keeps what the model does not state" begin
            car(tag) = "Car = Models.Model(\"m4b_car\", carid = Models.IDField(), tag = $(tag))"
            apply!(car("Models.CharField(max_length = 40)"))
            exec("ALTER TABLE `m4b_car` MODIFY COLUMN `tag` VARCHAR(40) NOT NULL DEFAULT (uuid()) " *
                 "COMMENT 'set by hand' COLLATE utf8mb4_0900_ai_ci")
            @test converged()
            apply!(car("Models.CharField(max_length = 40, null = true)"))
            r = column_row("m4b_car", "tag")
            @test (r.d, r.c, r.k, r.n) == ("uuid()", "set by hand", "utf8mb4_0900_ai_ci", "YES") && converged()
            write_models(car("Models.CharField(max_length = 60, null = true)"))
            Mig.makemigrations(folder; interactive = false)
            @test occursin("drop_default", read(pending, String))
            e = try; Mig.migrate(folder; interactive = false, atomic = false); nothing; catch err; err; end
            @test e isa Mig.DestructiveMigrationError
            Mig.migrate(folder; interactive = false, atomic = false, destructive = true)
            r = column_row("m4b_car", "tag")
            @test ismissing(r.d) && (r.c, r.k) == ("set by hand", "utf8mb4_0900_ai_ci") && converged()
            # A generated column made by hand reads as a plain one; a MODIFY that changes it restates its
            # generation, which a MODIFY that left it out would end (STORED) or fail on (VIRTUAL, 3106).
            exec("UPDATE `m4b_car` SET `tag` = 'ab'")
            exec("ALTER TABLE `m4b_car` ADD COLUMN `twice` BIGINT GENERATED ALWAYS AS (CHAR_LENGTH(`tag`)) STORED, " *
                 "ADD COLUMN `half` INT GENERATED ALWAYS AS (CHAR_LENGTH(`tag`) DIV 2) VIRTUAL")
            car2(twice, half) = "Car = Models.Model(\"m4b_car\", carid = Models.IDField(), " *
                                "tag = Models.CharField(max_length = 60, null = true), twice = $(twice), half = $(half))"
            write_models(car2("Models.BigIntegerField(null = true)", "Models.IntegerField(null = true)"))
            @test converged()
            apply!(car2("Models.IntegerField(null = true)", "Models.BigIntegerField(null = true)"))
            gen = raw("SELECT COLUMN_NAME AS c, COLUMN_TYPE AS t, EXTRA AS e FROM information_schema.COLUMNS " *
                      "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'm4b_car' AND COLUMN_NAME IN ('twice', 'half') ORDER BY 1")
            @test [(String(r.c), String(r.t), String(r.e)) for r in eachrow(gen)] ==
                  [("half", "bigint", "VIRTUAL GENERATED"), ("twice", "int", "STORED GENERATED")]
            exec("INSERT INTO `m4b_car` (`tag`) VALUES ('abcd')")
            row = raw("SELECT `twice`, `half` FROM `m4b_car` WHERE `tag` = 'abcd'")[1, :]
            @test (row.twice, row.half) == (4, 2)
            @test converged()
            exec("ALTER TABLE `m4b_car` DROP COLUMN `twice`, DROP COLUMN `half`")
        end

        # What: an alter plan stopped part-way — its `ADD CONSTRAINT` refused because another table holds the
        # foreign key's name (MySQL names keys per database) — then finished by the next plan.
        # SQL: `ADD COLUMN`, then `ALTER TABLE `m4b_seat` ADD CONSTRAINT `<k>` …` (1826, duplicate name); after
        #      the planted table is dropped, a plan of what is missing.
        # Why: #1268's promise on an engine whose DDL commits each statement: the history says `failed`, and
        # the next `makemigrations` plans exactly what is missing, so the schema ends as a clean apply's.
        @testset "a stopped alter plan is finished by the next plan (#1268)" begin
            parent = "Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField())\n"
            apply!(parent * "Seat = Models.Model(\"m4b_seat2\", seatid = Models.IDField(), circuitid = Models.BigIntegerField(null = true))")
            write_models(parent * "Seat = Models.Model(\"m4b_seat2\", seatid = Models.IDField(), " *
                         "circuitid = Models.ForeignKey(Circuit, pk_field = \"circuitid\", null = true, db_index = false), " *
                         "row = Models.IntegerField(null = true))")
            Mig.makemigrations(folder; interactive = false)
            plan = read(pending, String)
            key = match(r"ADD CONSTRAINT `(m4b_seat2_circuitid_[0-9A-Za-z]+_fk)`", plan)[1]
            exec("CREATE TABLE `m4b_planted` (`id` BIGINT NOT NULL PRIMARY KEY, `p` BIGINT NULL, " *
                 "CONSTRAINT `$(key)` FOREIGN KEY (`p`) REFERENCES `m4b_planted` (`id`)) ENGINE=InnoDB")
            e = try; Mig.migrate(folder; interactive = false, atomic = false); nothing; catch err; err; end
            @test e isa PormG.PormGError
            @test length(Mig.status(folder).failed) == 1
            t = live("m4b_seat2")
            @test haskey(t.columns, "row") && t.columns["circuitid"].reference === nothing   # the step before it ran
            exec("DROP TABLE `m4b_planted`")
            Mig.makemigrations(folder; interactive = false)
            rest = read(pending, String)
            @test occursin("ADD CONSTRAINT", rest) && !occursin("ADD COLUMN", rest)
            @test Mig.migrate(folder; interactive = false).outcome === :applied   # one statement: no atomic needed
            @test live("m4b_seat2").columns["circuitid"].reference !== nothing && converged()
        end

        # What: a declared CheckConstraint on a table that exists (#1130 phase 4c): added over rows it rejects
        # and over rows it accepts, read back as declared, renamed, given a new condition, adopted from one
        # written by hand, dropped with its declaration; a CHECK name another table holds is refused.
        # SQL: the pre-check `SELECT COUNT(*) AS n FROM `m4b_grid` WHERE NOT (grid >= 0)`, then
        #      `ADD CONSTRAINT `m4b_grid_nonneg` CHECK ((grid >= 0) AND 'pormg:check:<h>' IS NOT NULL)`; a rename
        #      `DROP CHECK `m4b_grid_nonneg`, ADD CONSTRAINT `m4b_grid_min` …`; `DROP CHECK `m4b_grid_min``.
        # Why: MySQL keeps no comment on a CHECK and strips one from its clause, so PormG's marker rides in the
        # clause. Read back, the CHECK must be the declared one (not the positive-integer column CHECK its
        # condition looks like), converge, follow a rename, and go when its declaration goes.
        @testset "a declared CheckConstraint" begin
            grid(cs = "") = "Grid = Models.Model(\"m4b_grid\", gridid = Models.IDField(), grid = Models.IntegerField(null = true)" *
                            (isempty(cs) ? ")" : "; constraints = [$(cs)])")
            ck(name, cond = "grid >= 0") = "Models.CheckConstraint(condition = \"$(cond)\", name = \"$(name)\")"
            apply!(grid())
            exec("INSERT INTO `m4b_grid` (`grid`) VALUES (-1), (3), (NULL)")
            @test refused_by_precheck(grid(ck("m4b_grid_nonneg"))) == [(:add_check, 1)]
            @test isempty(live("m4b_grid").checks)
            exec("DELETE FROM `m4b_grid` WHERE `grid` < 0")
            apply!(grid(ck("m4b_grid_nonneg")))
            t = live("m4b_grid")
            @test [(c.name, c.marker) for c in t.checks] == [("m4b_grid_nonneg", PormG.check_marker("grid >= 0"))]
            @test isempty(t.columns["grid"].checks) && converged()
            @test (try; exec("INSERT INTO `m4b_grid` (`grid`) VALUES (-5)"); false; catch; true; end)
            plan = apply!(grid(ck("m4b_grid_min")))
            @test occursin("DROP CHECK `m4b_grid_nonneg`, ADD CONSTRAINT `m4b_grid_min`", plan)
            @test [c.name for c in live("m4b_grid").checks] == ["m4b_grid_min"] && converged()
            apply!(grid(ck("m4b_grid_min", "grid >= 1")))
            @test only(live("m4b_grid").checks).marker == PormG.check_marker("grid >= 1") && converged()
            # Written by hand under the declared name: no marker, so it is re-created with one. (A condition
            # of its own, or the plan would repeat the last one's text, which `migrate` takes as applied.)
            exec("ALTER TABLE `m4b_grid` DROP CHECK `m4b_grid_min`, ADD CONSTRAINT `m4b_grid_min` CHECK (grid >= 2)")
            @test only(live("m4b_grid").checks).marker === nothing
            apply!(grid(ck("m4b_grid_min", "grid >= 2")))
            @test only(live("m4b_grid").checks).marker == PormG.check_marker("grid >= 2") && converged()
            plan = apply!(grid())
            @test occursin("DROP CHECK `m4b_grid_min`", plan) && isempty(live("m4b_grid").checks) && converged()
            apply!(grid(ck("m4b_grid_min")))
            lap3 = "\nLap = Models.Model(\"m4b_lap3\", lapid = Models.IDField(), " *
                   "lap = Models.IntegerField(); constraints = [$(ck("m4b_grid_min", "lap >= 0"))])"
            # Two models declaring it; and a name moved to a new table in the plan that drops it from its own,
            # which MySQL still holds when the new table's CHECK is added (two migrations, then).
            for (src, why) in (grid(ck("m4b_grid_min")) * lap3 => "declared on models",
                               grid() * lap3 => "already the name of a CHECK on table 'm4b_grid'")
                write_models(src)
                e = try; Mig.makemigrations(folder; interactive = false); nothing; catch err; err; end
                @test e isa PormG.InvalidMigrationError && occursin(why, sprint(showerror, e))
            end
            # A CHECK MySQL named itself (`<table>_chk_1`, the name `inspectdb` declares it under), adopted,
            # then dropped by the plan that renames its table: the RENAME TABLE runs first and renames the
            # CHECK with it, so the drop names it as it is then.
            exec("CREATE TABLE `m4b_tr` (`trid` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, `lap` INT NULL, " *
                 "CHECK (`lap` < 100)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin")
            tr(name, cs) = "Tr = Models.Model(\"$(name)\", trid = Models.IDField(), lap = Models.IntegerField(null = true)$(cs))"
            apply!(tr("m4b_tr", "; constraints = [$(ck("m4b_tr_chk_1", "lap < 100"))]"))
            @test only(live("m4b_tr").checks).marker == PormG.check_marker("lap < 100") && converged()
            plan = apply!(tr("m4b_tr2", ""); renames = ["m4b_tr" => "m4b_tr2"])
            @test occursin("RENAME TABLE `m4b_tr` TO `m4b_tr2`", plan) && occursin("DROP CHECK `m4b_tr2_chk_1`", plan)
            @test isempty(live("m4b_tr2").checks) && converged()
        end

        # What: a functional index and a functional UniqueConstraint (#1130 phase 4c): created, converged,
        # re-created for a new expression, dropped; one made by hand under the declared name is refused.
        # SQL: `CREATE INDEX `m4b_fn_idx` ON `m4b_fn` ((lower(name))) COMMENT 'pormg:index:<h>'`, then
        #      `DROP INDEX `m4b_fn_idx` ON `m4b_fn`` and the new create.
        # Why: MySQL re-prints the expression (`lower(`name`)`), so the hashed marker in the COMMENT is what
        # makes the index converge, and what tells a changed expression or a hand-made index from PormG's.
        @testset "a functional index" begin
            fn(ix) = "Fn = Models.Model(\"m4b_fn\", fnid = Models.IDField(), name = Models.CharField(max_length = 40), " *
                     "code = Models.CharField(max_length = 8)$(ix))"
            index(e) = "; indexes = [Models.Index(expressions = (\"$(e)\",), name = \"m4b_fn_idx\")]"
            apply!(fn(""))
            exec("INSERT INTO `m4b_fn` (`name`, `code`) VALUES ('Senna', 'SEN'), ('Prost', 'PRO')")
            apply!(fn(index("lower(name)")))
            c = only(live("m4b_fn").composites)
            @test (c.name, c.expressions, c.marker) == ("m4b_fn_idx", ["lower(name)"], PormG.index_text_marker(["lower(name)"], nothing))
            @test converged()
            plan = apply!(fn(index("upper(name) DESC")))
            @test occursin("DROP INDEX `m4b_fn_idx` ON `m4b_fn`", plan) && occursin("((upper(name)) DESC)", plan)
            @test only(live("m4b_fn").composites).expressions == ["upper(name) DESC"] && converged()
            unique = "; constraints = [Models.UniqueConstraint(expressions = (\"lower(code)\",), name = \"m4b_fn_code_uniq\")]"
            apply!(fn(unique))
            c = only(live("m4b_fn").composites)
            @test (c.name, c.unique) == ("m4b_fn_code_uniq", true) && converged()
            @test (try; exec("INSERT INTO `m4b_fn` (`name`, `code`) VALUES ('Senna', 'sen')"); false; catch; true; end)
            apply!(fn(""))
            @test isempty(live("m4b_fn").composites) && converged()
            # Made by hand under the declared name: of the declared expression, it is the declaration's (its
            # text read in declarable form), left unowned; of another, the name is taken and the plan refused.
            exec("CREATE INDEX `m4b_fn_idx` ON `m4b_fn` ((lower(`name`)))")
            write_models(fn(index("lower(name)")))
            @test converged()
            write_models(fn(index("upper(name)")))
            e = try; Mig.makemigrations(folder; interactive = false); nothing; catch err; err; end
            @test e isa PormG.InvalidMigrationError && occursin("m4b_fn_idx", sprint(showerror, e))
            exec("DROP INDEX `m4b_fn_idx` ON `m4b_fn`")
        end

        # What: a per-engine db_default on MySQL (#1130 phase 4c): created with its stamp, converged, changed
        # (a DBA's comment kept), changed by hand and seen, added with a new column, non-ASCII text included.
        # SQL: `CREATE TABLE … `label` VARCHAR(40) NOT NULL DEFAULT (lower('AbC'))`, then the stamp:
        #      `SET @pormg_stamp = (SELECT CONCAT('ALTER TABLE `m4b_tag` MODIFY COLUMN …', QUOTE(…)) …);
        #      PREPARE pormg_stamp FROM @pormg_stamp; EXECUTE pormg_stamp; DEALLOCATE PREPARE pormg_stamp;`.
        # Why: MySQL re-prints the expression, so only the marker's second hash, computed by the server from
        # the text it printed, makes the column converge, and tells a hand-made SET DEFAULT (which keeps the
        # comment) from PormG's own.
        @testset "a per-engine db_default" begin
            tag(d, extra = "") = "Tag = Models.Model(\"m4b_tag\", tagid = Models.IDField(), " *
                                 "label = Models.CharField(max_length = 40$(d))$(extra))"
            ex(e) = ", db_default = (postgres = \"$(e)\", mysql = \"$(e)\")"
            marked(c) = occursin(r"pormg:default:[0-9a-f]{16}:[0-9a-f]{16}$", c)
            plan = apply!(tag(ex("lower('AbC')")))
            @test occursin("PREPARE pormg_stamp FROM @pormg_stamp;", plan)
            r = column_row("m4b_tag", "label")
            @test r.d == "lower(_utf8mb4\\'AbC\\')" && marked(r.c) && converged()
            exec("INSERT INTO `m4b_tag` () VALUES ()")
            @test raw("SELECT `label` FROM `m4b_tag`")[1, :label] == "abc"
            # A note a DBA adds beside the marker is kept through a changed default.
            exec("ALTER TABLE `m4b_tag` MODIFY COLUMN `label` VARCHAR(40) NOT NULL DEFAULT (lower('AbC')) COMMENT 'note $(r.c)'")
            @test converged()
            apply!(tag(ex("upper('ção')")))
            r = column_row("m4b_tag", "label")
            @test occursin("upper(", r.d) && Base.startswith(r.c, "note pormg:default:") && marked(r.c) && converged()
            # Changed by hand: the comment stays, the second hash no longer matches, and the plan re-applies it.
            exec("ALTER TABLE `m4b_tag` ALTER COLUMN `label` SET DEFAULT (concat('a', 'b'))")
            @test !converged()
            Mig.migrate(folder; interactive = false, atomic = false)
            @test occursin("upper(", column_row("m4b_tag", "label").d) && converged()
            # A new column with one: ADD COLUMN, then its stamp. (Deterministic: a server logging statements
            # refuses a `uuid()` default added over rows, 1674.)
            code = ", code = Models.CharField(max_length = 36, db_default = (mysql = \"concat('M', 'Y')\",))"
            plan = apply!(tag(ex("upper('ção')"), code))
            @test occursin("ADD COLUMN `code` VARCHAR(36) NOT NULL DEFAULT (concat('M', 'Y'))", plan)
            @test raw("SELECT `code` FROM `m4b_tag`")[1, :code] == "MY"
            @test marked(column_row("m4b_tag", "code").c) && converged()
        end

        # What: columns PormG did not write, under the fields whose values they hold (#1130 phase 4c): a
        # `datetime(6)`, a `timestamp`, a `time`, a `text`, an `int` — and an `int unsigned`, which holds others.
        # SQL: none for the first five once declared; `MODIFY COLUMN `u` INT NULL` for the unsigned one; then,
        #      for `NOT NULL`, `MODIFY COLUMN `at` DATETIME(6) NOT NULL` (the column's own type, not PormG's).
        # Why: `inspectdb` reads such a schema as those fields, so the planner must call them equal rather
        # than retype each to PormG's own spelling, and must still retype what holds other values; and a
        # MODIFY for another change must not write PormG's spelling either, which rounds a `datetime(6)`.
        @testset "columns PormG did not write, under the fields that hold their values" begin
            exec("CREATE TABLE `m4b_legacy` (`legacyid` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, " *
                 "`at` DATETIME(6) NULL, `stamp` TIMESTAMP NULL, `lap` TIME NULL, `note` TEXT NULL, `n` INT NULL, " *
                 "`u` INT UNSIGNED NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin")
            legacy(u) = "Legacy = Models.Model(\"m4b_legacy\", legacyid = Models.IDField(), " *
                        "at = Models.DateTimeField(null = true), stamp = Models.DateTimeField(null = true), " *
                        "lap = Models.TimeField(null = true), note = Models.TextField(null = true), " *
                        "n = Models.IntegerField(null = true), u = $(u))"
            write_models(legacy("Models.IntegerField(null = true)"))
            Mig.makemigrations(folder; interactive = false)
            plan = read(pending, String)
            @test occursin("MODIFY COLUMN `u` INT NULL", plan) && !occursin(r"MODIFY COLUMN `(at|stamp|lap|note|n)`", plan)
            Mig.migrate(folder; interactive = false, atomic = false, destructive = true)
            @test converged()
            # A MODIFY that changes no type restates the column's own: `NOT NULL` keeps a `datetime(6)`'s
            # microseconds (`DATETIME(3)` would round them, here into the next day) and a `timestamp`.
            exec("INSERT INTO `m4b_legacy` (`at`, `stamp`, `note`) VALUES ('2026-01-01 23:59:59.999600', '2026-01-01 10:00:00', 'x')")
            write_models(replace(legacy("Models.IntegerField(null = true)"),
                                 "at = Models.DateTimeField(null = true), stamp = Models.DateTimeField(null = true)" =>
                                 "at = Models.DateTimeField(), stamp = Models.DateTimeField()",
                                 "note = Models.TextField(null = true)" => "note = Models.TextField()"))
            Mig.makemigrations(folder; interactive = false)
            plan = read(pending, String)
            @test occursin("MODIFY COLUMN `at` DATETIME(6) NOT NULL", plan) && occursin("MODIFY COLUMN `stamp` TIMESTAMP NOT NULL", plan) &&
                  occursin("MODIFY COLUMN `note` TEXT NOT NULL", plan)
            Mig.migrate(folder; interactive = false, atomic = false, destructive = true)
            @test converged()
            @test String.(raw("SELECT COLUMN_TYPE AS ctype FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() " *
                              "AND TABLE_NAME = 'm4b_legacy' AND COLUMN_NAME IN ('at', 'stamp', 'note') ORDER BY COLUMN_NAME").ctype) ==
                  ["datetime(6)", "text", "timestamp"]
            row = raw("SELECT MICROSECOND(`at`) AS us, DATE(`at`) = '2026-01-01' AS same_day FROM `m4b_legacy`")[1, :]
            @test (Int(row.us), Int(row.same_day)) == (999600, 1)
            exec("DROP TABLE `m4b_legacy`")
        end

        # What: a data step (`run_once`) on MySQL, transactional and not, and `ensure_table!`.
        # SQL: `GET_LOCK('pormg::migrations', …)`, the step's writes and its `pormg_migrations_data` row in one
        #      transaction; `ensure_table!`'s CREATE TABLE and key.
        # Why: both were refused before phase 4b; a transactional step that throws must leave neither its
        # writes nor its record, and `ensure_table!` must not leave a table half-made when a statement after
        # its CREATE TABLE fails (each MySQL DDL statement commits on its own).
        @testset "run_once and ensure_table!" begin
            apply!("Circuit = Models.Model(\"m4b_circuit\", circuitid = Models.IDField(), name = Models.CharField(max_length = 50, null = true))")
            exec("INSERT INTO `m4b_circuit` (`name`) VALUES ('monza')")
            upper!(_) = exec("UPDATE `m4b_circuit` SET `name` = UPPER(`name`)")
            @test Mig.run_once(upper!, pool, settings, "m4b_upper") === :applied
            @test Mig.run_once(upper!, pool, settings, "m4b_upper") === :already_applied
            @test raw("SELECT `name` FROM `m4b_circuit`")[1, :name] == "MONZA"
            e = try
                Mig.run_once(pool, settings, "m4b_broken") do _
                    PormG.ConnectionPool.fetch(pool, "UPDATE `m4b_circuit` SET `name` = 'lost'")
                    error("the step fails")
                end
                nothing
            catch err
                err
            end
            @test e isa ErrorException && raw("SELECT `name` FROM `m4b_circuit`")[1, :name] == "MONZA"
            @test !Mig._data_step_recorded(pool, "m4b_broken")
            @test Mig.run_once(_ -> nothing, pool, settings, "m4b_plain"; transaction = false) === :applied
            @test [s.name for s in Mig.status(folder).data_steps] == ["m4b_upper", "m4b_plain"]

            target = PormG.Models.Model("m4b_circuit", circuitid = PormG.Models.IDField())
            lap = PormG.Models.Model("m4b_lap", lapid = PormG.Models.IDField(), lap = PormG.Models.IntegerField(),
                                     circuitid = PormG.Models.ForeignKey(target, pk_field = "circuitid", null = true))
            @test Mig.ensure_table!(lap, folder) === :created
            @test Mig.ensure_table!(lap, folder) === :exists
            @test live("m4b_lap").columns["circuitid"].reference !== nothing
            # An expression default's stamp keeps a session variable between its statements: they run on
            # one connection.
            stamped = PormG.Models.Model("m4b_lap4", lapid = PormG.Models.IDField(),
                                         label = PormG.Models.CharField(max_length = 9, db_default = (mysql = "lower('X')",)))
            @test Mig.ensure_table!(stamped, folder) === :created
            @test occursin(r"^pormg:default:[0-9a-f]{16}:[0-9a-f]{16}$", column_row("m4b_lap4", "label").c)
            # A key to a table that does not exist fails after the CREATE TABLE: the table goes again.
            nowhere = PormG.Models.Model("m4b_nowhere", nid = PormG.Models.IDField())
            ghost = PormG.Models.Model("m4b_lap2", lapid = PormG.Models.IDField(),
                                       circuitid = PormG.Models.ForeignKey(nowhere, pk_field = "nid", null = true))
            e = try; Mig.ensure_table!(ghost, folder); nothing; catch err; err; end
            @test e isa PormG.PormGError && !("m4b_lap2" in scratch_tables())
        end
    finally
        drop_scratch!()
        try; PormG.Configuration.close_pool!(folder); catch; end
        rm(folder; recursive = true, force = true)
    end
end
end
