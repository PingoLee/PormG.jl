# MySQL backend, phase 3a (#1130): single-row writes and deletes against a live MySQL 8.4 — `create`,
# `update`, `save` and `delete` with its cascades.
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
end

# The tables, in drop order (children first).
const _MYW_TABLES = ("p3w_note", "p3w_guard", "p3w_driver", "p3w_team", "p3w_token", "p3w_plain", "p3w_node")

@testset "MySQL backend, phase 3a: single-row writes and deletes (#1130)" begin
if only_on(:mysql, "writes through the MySQL query builder (phase 3a)")
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
            @test W.Driver.objects.filter("id" => alesi.id).update("surname" => F("team__name")) == 1
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
    finally
        for t in _MYW_TABLES
            run("DROP TABLE IF EXISTS `$(t)`")
        end
        delete!(PormG.config, "p3w_my")
    end
end
end
