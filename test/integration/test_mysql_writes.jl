# MySQL backend, phases 3a and 3b (#1130): single-row writes and deletes against a live MySQL 8.4 —
# `create`, `update`, `save`, `delete` with its cascades, and the upserts `update_or_create` and
# `get_or_create` (#1267).
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_writes.jl
#
# The writes go through the ORM surface. The tables are made with raw SQL, deliberately: `migrate` is
# phase 4, so there is no ORM way to make them yet, and they are dropped at the end. Every foreign key
# is declared `ON DELETE RESTRICT` in the DDL, so a statement PormG sends in the wrong order fails at
# once (InnoDB checks a foreign key at the statement, #1272) rather than being repaired by the schema.
# The models are this file's own, on their own connection key over the suite's MySQL pool. On another
# engine the whole file is skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, Dates, TimeZones, UUIDs, DataFrames
import PormG.QueryBuilder: F

module P3wModels
import PormG
import PormG.Models
Team = Models.Model("p3w_team",
  id = Models.IDField(),
  name = Models.CharField(),
  country = Models.CharField(default = "BR"),
  created_at = Models.DateTimeField(auto_now_add = true))
Driver = Models.Model("p3w_driver",
  id = Models.IDField(),
  team = Models.ForeignKey(Team, pk_field = "id", on_delete = "CASCADE", null = true, related_name = "drivers"),
  surname = Models.CharField(),
  points = Models.FloatField(default = 0.0))
Note = Models.Model("p3w_note",
  id = Models.IDField(),
  driver = Models.ForeignKey(Driver, pk_field = "id", on_delete = "SET_NULL", null = true, related_name = "notes"),
  fallback = Models.ForeignKey(Driver, pk_field = "id", on_delete = "SET_DEFAULT", default = 1, null = true,
                               related_name = "fallback_notes"),
  text = Models.CharField())
Guard = Models.Model("p3w_guard",
  id = Models.IDField(),
  driver = Models.ForeignKey(Driver, pk_field = "id", on_delete = "PROTECT", related_name = "guards"))
# `note` is NULL-able here and has a default in the DDL only, so only a row read back from the
# database carries it: the INSERT leaves it out.
Token = Models.Model("p3w_token",
  token = Models.UUIDField(primary_key = true, auto_add = true),
  label = Models.CharField(),
  note = Models.CharField(null = true))
Plain = Models.Model("p3w_plain",
  code = Models.CharField(primary_key = true, max_length = 10),
  label = Models.CharField(),
  note = Models.CharField(null = true))
Node = Models.Model("p3w_node",
  id = Models.IDField(),
  up = Models.ForeignKey("Node", pk_field = "id", on_delete = "CASCADE", null = true, related_name = "children"),
  name = Models.CharField())
# The upserts (#1267): `ref` is the lookup; `code` a second, nullable unique key.
Constructor = Models.Model("p3w_constructor",
  id = Models.IDField(),
  ref = Models.CharField(unique = true),
  code = Models.CharField(null = true, unique = true),
  nationality = Models.CharField(null = true))
# Two NOT NULL unique keys.
Circuit = Models.Model("p3w_circuit",
  id = Models.IDField(),
  ref = Models.CharField(unique = true),
  name = Models.CharField(unique = true))
# An `auto_now` column, which an update_or_create hit refreshes.
Season = Models.Model("p3w_season",
  id = Models.IDField(),
  year = Models.IntegerField(unique = true),
  url = Models.CharField(),
  updated = Models.DateTimeField(auto_now = true))
# A duration column (#1348): a BIGINT of microseconds on MySQL.
Lap = Models.Model("p3w_lap",
  id = Models.IDField(),
  ref = Models.CharField(unique = true),
  best = Models.DurationField(null = true))
end

# The tables, in drop order (children first).
const _MYW_TABLES = ("p3w_note", "p3w_guard", "p3w_driver", "p3w_team", "p3w_token", "p3w_plain", "p3w_node",
                     "p3w_constructor", "p3w_circuit", "p3w_season", "p3w_lap")

@testset "MySQL backend, phases 3a and 3b: single-row writes, deletes and upserts (#1130)" begin
if only_on(:mysql, "writes through the MySQL query builder (phases 3a and 3b)")
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.config["p3w_my"] = PormG.Configuration.Settings(connections = pool, change_data = true, db_def_folder = "p3w_my")
    Base.invokelatest(PormG.Models.set_models, P3wModels, "p3w_my")
    W = P3wModels
    run(sql; params = nothing) = PormG.fetch(pool, sql; params = params)
    sql_rows(sql; params = nothing) = DataFrame(run(sql; params = params))
    msg(e) = sprint(showerror, e)
    caught(f) = try f(); nothing catch err; err end
    for t in _MYW_TABLES
        run("DROP TABLE IF EXISTS `$(t)`")
    end
    try
        tail = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
        fk(table, col, parent) = "CONSTRAINT `$(table)_$(col)_fk` FOREIGN KEY (`$(col)`) REFERENCES `$(parent)` (`id`) ON DELETE RESTRICT"
        run("CREATE TABLE `p3w_team` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `name` VARCHAR(255) NOT NULL, " *
            "`country` VARCHAR(255) NOT NULL, `created_at` DATETIME(3) NOT NULL)" * tail)
        run("CREATE TABLE `p3w_driver` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `team` BIGINT NULL, " *
            "`surname` VARCHAR(255) NOT NULL, `points` DOUBLE NOT NULL, $(fk("p3w_driver", "team", "p3w_team")))" * tail)
        run("CREATE TABLE `p3w_note` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `driver` BIGINT NULL, `fallback` BIGINT NULL, " *
            "`text` VARCHAR(255) NOT NULL, $(fk("p3w_note", "driver", "p3w_driver")), $(fk("p3w_note", "fallback", "p3w_driver")))" * tail)
        run("CREATE TABLE `p3w_guard` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `driver` BIGINT NOT NULL, " *
            "$(fk("p3w_guard", "driver", "p3w_driver")))" * tail)
        run("CREATE TABLE `p3w_token` (`token` CHAR(36) PRIMARY KEY, `label` VARCHAR(255) NOT NULL, " *
            "`note` VARCHAR(255) NULL DEFAULT 'from the server')" * tail)
        run("CREATE TABLE `p3w_plain` (`code` VARCHAR(10) PRIMARY KEY, `label` VARCHAR(255) NOT NULL, " *
            "`note` VARCHAR(255) NULL DEFAULT 'from the server')" * tail)
        run("CREATE TABLE `p3w_node` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `up` BIGINT NULL, `name` VARCHAR(255) NOT NULL, " *
            "$(fk("p3w_node", "up", "p3w_node")))" * tail)
        run("CREATE TABLE `p3w_constructor` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `ref` VARCHAR(255) NOT NULL UNIQUE, " *
            "`code` VARCHAR(255) NULL UNIQUE, `nationality` VARCHAR(255) NULL)" * tail)
        run("CREATE TABLE `p3w_circuit` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `ref` VARCHAR(255) NOT NULL UNIQUE, " *
            "`name` VARCHAR(255) NOT NULL UNIQUE)" * tail)
        run("CREATE TABLE `p3w_season` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `year` INT NOT NULL UNIQUE, " *
            "`url` VARCHAR(255) NOT NULL, `updated` DATETIME(3) NOT NULL)" * tail)
        run("CREATE TABLE `p3w_lap` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `ref` VARCHAR(255) NOT NULL UNIQUE, " *
            "`best` BIGINT NULL)" * tail)

        # What: `create` returns the row the database wrote, read back on the same connection.
        # SQL: INSERT INTO `p3w_team` (…) VALUES (?, …), then SELECT * FROM `p3w_team` WHERE `id` = ?, bound
        #      to the id the INSERT's OK packet reports; for a pk the caller supplies, the supplied value.
        # Why: MySQL has no RETURNING (#1266). `LAST_INSERT_ID()` changes only when the server generates
        #      the id, so after a supplied one it would read an older row back.
        @testset "create reads back the row it wrote, by the key the INSERT wrote" begin
            before = now(UTC)
            mclaren = W.Team.objects.create("name" => "McLaren")
            @test mclaren.id isa Integer && mclaren.id > 0
            @test mclaren.name == "McLaren" && mclaren.country == "BR"   # the declared default, as stored
            @test mclaren.created_at isa ZonedDateTime && before - Second(1) <= DateTime(mclaren.created_at) <= now(UTC) + Second(1)
            stored = only(W.Team.objects.filter("id" => mclaren.id).values("id", "name", "country").list())
            @test (stored[:id], stored[:name], stored[:country]) == (mclaren.id, "McLaren", "BR")
            # A supplied AUTO_INCREMENT id is the row read back, and the next generated one follows it.
            williams = W.Team.objects.create("id" => 500, "name" => "Williams", "country" => "UK")
            @test (williams.id, williams.name, williams.country) == (500, "Williams", "UK")
            ferrari = W.Team.objects.create("name" => "Ferrari", "country" => "IT")
            @test ferrari.id == 501 && ferrari.name == "Ferrari"
            # A pk with no AUTO_INCREMENT (the OK packet reports 0) is read back by the value bound: the
            # column only the server filled is in the row.
            plain = W.Plain.objects.create("code" => "SEN", "label" => "Senna")
            @test (plain.code, plain.label, plain.note) == ("SEN", "Senna", "from the server")
            # A UUID pk PormG mints is read back by that UUID.
            token = W.Token.objects.create("label" => "t1")
            @test (token.label, token.note) == ("t1", "from the server")
            @test only(W.Token.objects.filter("token" => token.token).values("label").list())[:label] == "t1"
            # Inside a transaction the read-back uses the transaction's connection, and a rollback undoes it.
            n = W.Team.objects.count()
            e = caught(() -> PormG.atomic(PormG.config["p3w_my"]) do
                t = W.Team.objects.create("name" => "Brabham")
                @test only(W.Team.objects.filter("id" => t.id).values("name").list())[:name] == "Brabham"
                error("roll back")
            end)
            @test e isa ErrorException && W.Team.objects.count() == n
        end

        # What: `update` returns the rows it matched, a row it left unchanged included; a joined filter
        # and a SET that reads a joined table both write the rows they name.
        # SQL: UPDATE `p3w_driver` AS `Tb` SET `points` = ? WHERE …; a joined filter as
        #      `Tb`.`id` IN (SELECT * FROM (SELECT DISTINCT …) AS `__pormg_keys`) AND EXISTS (…); a joined
        #      SET as UPDATE `p3w_driver` AS `Tb`, `p3w_team` AS `Tb_1` SET `Tb`.`surname` = `Tb_1`.`name` WHERE ….
        # Why: Django's update() counts matched rows; MySQL refuses a subquery on the table an UPDATE
        #      writes (error 1093) unless it is materialized first.
        @testset "update counts matched rows, joined filters and joined SETs" begin
            mclaren = only(W.Team.objects.filter("name" => "McLaren").values("id").list())[:id]
            ferrari = only(W.Team.objects.filter("name" => "Ferrari").values("id").list())[:id]
            senna = W.Driver.objects.create("team" => mclaren, "surname" => "Senna")
            prost = W.Driver.objects.create("team" => mclaren, "surname" => "Prost")
            alesi = W.Driver.objects.create("team" => ferrari, "surname" => "Alesi")
            @test senna.points === 0.0
            q() = W.Driver.objects.filter("team" => mclaren)
            @test q().update("points" => 6.0) == 2
            @test q().update("points" => 6.0) == 2   # unchanged rows still match
            @test W.Driver.objects.filter("id" => 0).update("points" => 1.0) == 0
            @test W.Driver.objects.filter("team__name" => "Ferrari").update("points" => 4.0) == 1
            points = Dict(r[:surname] => r[:points] for r in W.Driver.objects.values("surname", "points").list())
            @test points == Dict("Senna" => 6.0, "Prost" => 6.0, "Alesi" => 4.0)
            # `team` is nullable, so the joined SET declares it INNER: a LEFT join is refused (#1430).
            @test W.Driver.objects.on("team", join_type = "INNER").filter("id" => alesi.id).update("surname" => F("team__name")) == 1
            @test only(W.Driver.objects.filter("id" => alesi.id).values("surname").list())[:surname] == "Ferrari"
            W.Driver.objects.filter("id" => alesi.id).update("surname" => "Alesi")
            # A SET that reads a column the same update writes would read its new value on MySQL: refused.
            e = caught(() -> W.Team.objects.filter("id" => mclaren).update("name" => F("country"), "country" => F("name")))
            @test e isa PormG.QueryBuildError && occursin("in order", msg(e))
            @test only(W.Team.objects.filter("id" => mclaren).values("name", "country").list())[:name] == "McLaren"
            # `save` writes the fields the row changed.
            row = W.Driver.objects.filter("id" => senna.id).get()
            row.points = 9.0
            row.save()
            @test only(W.Driver.objects.filter("id" => senna.id).values("points").list())[:points] === 9.0
            @test prost.surname == "Prost"
        end

        # What: `delete` runs children first, nulls a SET_NULL child and resets a SET_DEFAULT one before
        # the parent goes, refuses a PROTECT child, and counts what it deleted.
        # SQL: UPDATE `p3w_note` … SET `driver` = NULL / `fallback` = 1, then DELETE FROM `p3w_driver` AS
        #      `Tb` WHERE …, the parents locked FOR UPDATE first.
        # Why: every foreign key here is RESTRICT and InnoDB checks it at the statement, so any statement
        #      out of order fails with 1451 (#1272).
        @testset "delete runs children first, and refuses PROTECT" begin
            ids = Dict(r[:surname] => r[:id] for r in W.Driver.objects.values("surname", "id").list())
            # The SET_DEFAULT target (`default = 1`) must exist: driver 1 is the first one created here.
            @test minimum(values(ids)) == 1
            W.Note.objects.create("driver" => ids["Prost"], "fallback" => ids["Prost"], "text" => "prost")
            W.Note.objects.create("driver" => ids["Alesi"], "text" => "alesi")
            W.Guard.objects.create("driver" => ids["Alesi"])
            total, counts = W.Driver.objects.filter("id" => ids["Prost"]).delete()
            @test total == 1 && counts == Dict("p3w_driver" => 1)
            note = only(W.Note.objects.filter("text" => "prost").values("driver", "fallback").list())
            @test ismissing(note[:driver])
            @test note[:fallback] == 1
            # PROTECT: refused before anything is deleted.
            e = caught(() -> W.Driver.objects.filter("id" => ids["Alesi"]).delete())
            @test e isa PormG.ProtectedError
            @test W.Driver.objects.filter("id" => ids["Alesi"]).count() == 1
            W.Guard.objects.filter("driver" => ids["Alesi"]).delete()
            # A cascade: the team takes its drivers; their notes are nulled first. The parents are locked
            # FOR UPDATE, top-down, before any statement reads them (#770), as on PostgreSQL — statements
            # MySQL runs here, so a lock it could not parse fails this delete.
            ferrari = only(W.Team.objects.filter("name" => "Ferrari").values("id").list())[:id]
            total, counts = W.Team.objects.filter("id" => ferrari).delete()
            @test total == 2 && counts == Dict("p3w_team" => 1, "p3w_driver" => 1)
            @test W.Driver.objects.filter("id" => ids["Alesi"]).count() == 0
            alesi_note = only(W.Note.objects.filter("text" => "alesi").values("driver").list())
            @test ismissing(alesi_note[:driver])
            # A filter that reads the table the statement writes (`id__@in` over the same model): MySQL
            # refuses such a subquery (error 1093) unless it is read through a derived table, which a
            # mutation's membership subquery is. The same path scopes a cascade child by its parents.
            williams = only(W.Team.objects.filter("name" => "Williams").values("id").list())[:id]
            mansell = W.Driver.objects.create("team" => williams, "surname" => "Mansell")
            patrese = W.Driver.objects.create("team" => williams, "surname" => "Patrese")
            same = () -> W.Driver.objects.filter("team" => williams, "surname" => "Mansell").values("id")
            @test W.Driver.objects.filter("id__@in" => same()).update("points" => 3.0) == 1
            @test only(W.Driver.objects.filter("id" => mansell.id).values("points").list())[:points] === 3.0
            total, counts = W.Driver.objects.filter("id__@in" => same()).delete()
            @test total == 1 && counts == Dict("p3w_driver" => 1)
            @test [r[:id] for r in W.Driver.objects.filter("team" => williams).values("id").list()] == [patrese.id]
            # A joined filter on the root: the derived-table selection, then the fence.
            mclaren = only(W.Team.objects.filter("name" => "McLaren").values("id").list())[:id]
            extra = W.Driver.objects.create("team" => mclaren, "surname" => "Berger")
            total, _ = W.Driver.objects.filter("team__name" => "McLaren", "surname" => "Berger").delete()
            @test total == 1 && W.Driver.objects.filter("id" => extra.id).count() == 0
        end

        # What: what MySQL cannot do without deferred foreign keys is refused, naming the feature.
        # SQL: none for the refusals; a child INSERT before its parent fails at the statement (1452).
        # Why: InnoDB checks a foreign key per statement, and `FOREIGN_KEY_CHECKS = 0` disables the check
        #      without rechecking afterwards (#1272).
        @testset "no deferred foreign keys: self-referencing deletes and without_foreign_keys are refused" begin
            root = W.Node.objects.create("name" => "root")
            W.Node.objects.create("up" => root.id, "name" => "leaf")
            # Refused as on every engine: no order of statements leaves the rows' keys satisfied.
            e = caught(() -> W.Node.objects.filter("id" => root.id).delete())
            @test e isa PormG.QueryBuildError && occursin("Circular dependency", msg(e))
            @test W.Node.objects.count() == 2
            e = caught(() -> PormG.ConnectionPool.without_foreign_keys(() -> nothing, pool))
            @test e isa PormG.BackendCapabilityError && occursin("without_foreign_keys", msg(e))
            # A child written before its parent fails at once, inside a transaction too, and the
            # transaction rolls back whole.
            n = W.Driver.objects.count()
            e = caught(() -> PormG.atomic(PormG.config["p3w_my"]) do
                W.Driver.objects.create("surname" => "Orphan", "team" => 99_999)
            end)
            @test e isa PormG.IntegrityError
            @test W.Driver.objects.count() == n
        end

        # What: update_or_create upserts on its lookup, and `created` says whether the row was new.
        # SQL: INSERT INTO `p3w_constructor` (…) VALUES (?, ?) AS `__pormg_new` ON DUPLICATE KEY UPDATE
        #      `nationality` = `__pormg_new`.`nationality`, then SELECT * … WHERE `ref` = ? LIMIT 1.
        # Why: MySQL's upsert names no target and updates whichever row a unique key matched (#1267), so
        #      it runs only when the lookup is the one key the row can conflict on. Its affected-row count
        #      is 1 for an insert AND for a duplicate already holding the values; the OK packet's id tells
        #      them apart on an AUTO_INCREMENT table, a pre-check on any other.
        @testset "update_or_create: ON DUPLICATE KEY UPDATE on the lookup, created from the statement" begin
            row, created = W.Constructor.objects.update_or_create("ref" => "mclaren"; defaults = ["nationality" => "British"])
            @test created && row.ref == "mclaren" && row.nationality == "British" && row.id isa Integer
            id = row.id
            row, created = W.Constructor.objects.update_or_create("ref" => "mclaren"; defaults = ["nationality" => "UK"])
            @test !created && row.id == id && row.nationality == "UK"
            # The same values again: MySQL counts 1, as for an insert, and reports id 0.
            row, created = W.Constructor.objects.update_or_create("ref" => "mclaren"; defaults = ["nationality" => "UK"])
            @test !created && row.id == id && row.nationality == "UK"
            @test W.Constructor.objects.count() == 1
            # A row that could also conflict on `code` is refused, and no other row is touched.
            W.Constructor.objects.create("ref" => "brabham", "code" => "BRA", "nationality" => "British")
            e = caught(() -> W.Constructor.objects.update_or_create("ref" => "mclaren"; defaults = ["code" => "BRA"]))
            @test e isa PormG.BackendCapabilityError && occursin("(code)", msg(e))
            brabham = only(W.Constructor.objects.filter("ref" => "brabham").values("code", "nationality").list())
            @test (brabham[:code], brabham[:nationality]) == ("BRA", "British")
            @test ismissing(only(W.Constructor.objects.filter("ref" => "mclaren").values("code").list())[:code])
            # A primary key without AUTO_INCREMENT: the pre-check decides.
            row, created = W.Plain.objects.update_or_create("code" => "PRO"; defaults = ["label" => "Prost"])
            @test created && (row.code, row.label, row.note) == ("PRO", "Prost", "from the server")
            row, created = W.Plain.objects.update_or_create("code" => "PRO"; defaults = ["label" => "Prost"])
            @test !created && row.label == "Prost"
            row, created = W.Plain.objects.update_or_create("code" => "PRO"; defaults = ["label" => "Alain"])
            @test !created && row.label == "Alain"
            # A UUID primary key: no AUTO_INCREMENT either.
            tok = UUIDs.uuid4()
            row, created = W.Token.objects.update_or_create("token" => tok; defaults = ["label" => "t9"])
            @test created && (row.label, row.note) == ("t9", "from the server")
            row, created = W.Token.objects.update_or_create("token" => tok; defaults = ["label" => "t9"])
            @test !created && W.Token.objects.filter("token" => tok).count() == 1
            # A supplied AUTO_INCREMENT id as the lookup: the OK packet reports it on an insert.
            row, created = W.Team.objects.update_or_create("id" => 900; defaults = ["name" => "Ligier"])
            @test created && (row.id, row.name) == (900, "Ligier")
            row, created = W.Team.objects.update_or_create("id" => 900; defaults = ["name" => "Ligier"])
            @test !created && row.id == 900
            # Inside a transaction whose snapshot predates a row another session committed: the statement
            # hits that row unchanged, and the row read back is the stored one, not the values sent.
            PormG.atomic(PormG.config["p3w_my"]) do
                @test W.Plain.objects.filter("code" => "MAN").count() == 0   # opens the snapshot
                PormG.fetch(pool, "INSERT INTO `p3w_plain` (`code`, `label`) VALUES (?, ?)";
                            params = ["MAN", "Mansell"], ignore_tx = true)
                row, created = W.Plain.objects.update_or_create("code" => "MAN"; defaults = ["label" => "Mansell"])
                @test (row.code, row.label, row.note) == ("MAN", "Mansell", "from the server")
                @test !created   # the row was there, though the pre-check's snapshot could not see it
            end
            # A hit refreshes an `auto_now` column, as update() does.
            first_row, created = W.Season.objects.update_or_create("year" => 1988; defaults = ["url" => "u1988"])
            @test created
            sleep(0.05)
            again, created = W.Season.objects.update_or_create("year" => 1988; defaults = ["url" => "u1988"])
            @test !created && again.id == first_row.id && again.updated > first_row.updated
        end

        # What: a 0 written into an AUTO_INCREMENT key is stored as 0, through create, bulk_insert and
        # update_or_create, and update_or_create says `created` for it exactly once.
        # SQL: INSERT INTO `p3w_team` (`id`, …) VALUES (?, …) bound to 0, under the session's
        #      NO_AUTO_VALUE_ON_ZERO. update_or_create's OK packet then reports id 0 for the insert as for an
        #      unchanged duplicate, so the pre-check and a plain read by the lookup decide `created`.
        # Why: without the mode MySQL reads a written 0 as "generate one": the row was stored under the next
        #      id with no error (measured: 340003), where PostgreSQL and SQLite store 0.
        @testset "an explicit zero key is stored as zero" begin
            zero = W.Team.objects.create("id" => 0, "name" => "Zero")
            @test zero.id == 0
            @test only(W.Team.objects.filter("name" => "Zero").values("id").list())[:id] == 0
            W.Team.objects.filter("id" => 0).delete()
            bulk_insert(W.Team.objects, DataFrame(id = [0], name = ["Bulk zero"], country = ["BR"]))
            @test only(W.Team.objects.filter("name" => "Bulk zero").values("id").list())[:id] == 0
            W.Team.objects.filter("id" => 0).delete()
            row, created = W.Team.objects.update_or_create("id" => 0; defaults = ["name" => "Upsert zero"])
            @test created && (row.id, row.name) == (0, "Upsert zero")
            row, created = W.Team.objects.update_or_create("id" => 0; defaults = ["name" => "Upsert zero"])
            @test !created && row.id == 0
            row, created = W.Team.objects.update_or_create("id" => 0; defaults = ["name" => "Upsert zero 2"])
            @test !created && (row.id, row.name) == (0, "Upsert zero 2")
            @test W.Team.objects.filter("id" => 0).count() == 1
            W.Team.objects.filter("id" => 0).delete()
            # A zero spelled as text is the same 0, for MySQL and for `created`.
            row, created = W.Team.objects.update_or_create("id" => "00"; defaults = ["name" => "Text zero"])
            @test created && (row.id, row.name) == (0, "Text zero")
            W.Team.objects.filter("id" => 0).delete()
        end

        # What: a duration written through every write path reads back as the same duration.
        # SQL: each write binds the duration's microseconds (`83456000` for `Millisecond(83456)`) into the
        #      BIGINT column, as a filter binds it.
        # Why: the writes bound the field's `HH:MM:SS` text, which MySQL refuses for a BIGINT (1265, #1348),
        #      while a filter on the same column bound microseconds.
        @testset "a duration written through every write path reads back the same (#1348)" begin
            stored(ref) = only(W.Lap.objects.filter("ref" => ref).values("best").list())[:best]
            same(ref, p) = Dates.toms(stored(ref)) == Dates.toms(p)
            lap = W.Lap.objects.create("ref" => "create", "best" => Millisecond(83456))
            @test same("create", Millisecond(83456))
            @test only(W.Lap.objects.filter("best" => Millisecond(83456)).values("ref").list())[:ref] == "create"
            W.Lap.objects.create("ref" => "text", "best" => "1:27.452")
            @test same("text", Millisecond(87452))
            W.Lap.objects.filter("ref" => "create").update("best" => Second(90) + Millisecond(5))
            @test same("create", Millisecond(90005))
            row = W.Lap.objects.filter("ref" => "create").get()
            row.best = Minute(2)
            row.save()
            @test same("create", Minute(2))
            got, created = W.Lap.objects.get_or_create("ref" => "goc"; defaults = ["best" => Millisecond(61000)])
            @test created && same("goc", Millisecond(61000))
            upd, created = W.Lap.objects.update_or_create("ref" => "uoc"; defaults = ["best" => Millisecond(70250)])
            @test created && same("uoc", Millisecond(70250))
            upd, created = W.Lap.objects.update_or_create("ref" => "uoc"; defaults = ["best" => Millisecond(70500)])
            @test !created && same("uoc", Millisecond(70500))
            bulk_insert(W.Lap.objects, DataFrame(ref = ["bulk1", "bulk2"], best = [Millisecond(81000), missing]))
            @test same("bulk1", Millisecond(81000)) && ismissing(stored("bulk2"))
            ids = Dict(r[:ref] => r[:id] for r in W.Lap.objects.filter("ref__@in" => ["bulk1", "bulk2"]).values("id", "ref").list())
            bulk_update(W.Lap.objects, DataFrame(id = [ids["bulk1"], ids["bulk2"]], best = [Millisecond(82500), Second(85)]))
            @test same("bulk1", Millisecond(82500)) && same("bulk2", Second(85))
            # The column holds the microseconds themselves.
            raw = only(sql_rows("SELECT `best` FROM `p3w_lap` WHERE `ref` = 'bulk1'").best)
            @test raw == 82_500_000
        end

        # What: get_or_create finds the row by its lookup, or inserts it with a plain INSERT.
        # SQL: SELECT … WHERE `ref` = ? LIMIT 1; on a miss INSERT INTO `p3w_circuit` (…) VALUES (?, ?), then
        #      the same SELECT.
        # Why: get_or_create never updates a row, so MySQL needs no targeted DO NOTHING: the lookup's unique
        #      index makes a concurrent insert of the same key raise, and the winner is read back (#1267).
        #      A conflict on another key is MySQL's IntegrityError, as on PostgreSQL.
        @testset "get_or_create: a plain INSERT, the winner of a race read back" begin
            monza, created = W.Circuit.objects.get_or_create("ref" => "monza"; defaults = ["name" => "Monza"])
            @test created && monza.name == "Monza"
            # A hit needs no other column.
            hit, created = W.Circuit.objects.get_or_create("ref" => "monza")
            @test !created && hit.id == monza.id
            # The row conflicts on `name`, not on its lookup: MySQL's IntegrityError, nothing written.
            e = caught(() -> W.Circuit.objects.get_or_create("ref" => "monza2"; defaults = ["name" => "Monza"]))
            @test e isa PormG.IntegrityError && W.Circuit.objects.count() == 1
            # A race: another session inserted the key between the get and this INSERT. The miss path is
            # called directly with the INSERT get_or_create builds, the winner already in the table.
            W.Circuit.objects.create("ref" => "spa", "name" => "Spa")
            QB = PormG.QueryBuilder
            params = QB.get_parameter(pool)
            QB.set_context!(params, :select)
            insert_sql = "INSERT INTO `p3w_circuit` (`ref`, `name`) VALUES ($(QB.add_parameter!(params, "spa")), " *
                         "$(QB.add_parameter!(params, "Spa-Francorchamps")))"
            locked = Ref{Any}(nothing)   # outside a transaction the re-read takes no lock
            winner, created = QB._create_on_miss(pool, PormG.config["p3w_my"], W.Circuit, insert_sql, params,
                                                 (; lock = false) -> (locked[] = lock; W.Circuit.objects.filter("ref" => "spa").first()),
                                                 ["ref"])
            @test !created && winner.name == "Spa" && W.Circuit.objects.filter("ref" => "spa").count() == 1
            @test locked[] === false
            # Inside a transaction, the duplicate rolls back only its own statement.
            PormG.atomic(PormG.config["p3w_my"]) do
                W.Circuit.objects.create("ref" => "imola", "name" => "Imola")
                e = caught(() -> W.Circuit.objects.get_or_create("ref" => "imola2"; defaults = ["name" => "Imola"]))
                @test e isa PormG.IntegrityError
                W.Circuit.objects.create("ref" => "suzuka", "name" => "Suzuka")
            end
            @test W.Circuit.objects.filter("ref__@in" => ["imola", "imola2", "suzuka"]).count() == 2
            # A race inside a transaction: the winner committed after its snapshot is read back by a
            # locking read, so the call returns it rather than the duplicate-key error.
            PormG.atomic(PormG.config["p3w_my"]) do
                @test W.Circuit.objects.filter("ref" => "monaco").count() == 0   # opens the snapshot
                PormG.fetch(pool, "INSERT INTO `p3w_circuit` (`ref`, `name`) VALUES (?, ?)";
                            params = ["monaco", "Monaco"], ignore_tx = true)
                winner, created = W.Circuit.objects.get_or_create("ref" => "monaco"; defaults = ["name" => "Monte Carlo"])
                @test !created && winner.name == "Monaco"
            end
            # A lookup the model does not declare unique is refused on the miss.
            e = caught(() -> W.Plain.objects.get_or_create("label" => "Piquet"; defaults = ["code" => "PIQ"]))
            @test e isa PormG.QueryBuildError && occursin("to be a unique key of the model", msg(e))
            @test W.Plain.objects.filter("code" => "PIQ").count() == 0
        end
    finally
        for t in _MYW_TABLES
            run("DROP TABLE IF EXISTS `$(t)`")
        end
        delete!(PormG.config, "p3w_my")
    end
end
end
