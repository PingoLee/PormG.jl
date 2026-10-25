# MySQL backend, phase 3c (#1130): bulk writes against a live MySQL 8.4 — `bulk_insert` with chunks,
# `on_conflict` (#1267) with the counts its docstring promises and `returning` without RETURNING
# (#1266); `bulk_update`; and the many-to-many manager.
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_bulk.jl
#
# The writes go through the ORM surface. The tables are made with raw SQL, deliberately: `migrate` is
# phase 4, so there is no ORM way to make them yet, and they are dropped at the end. The models are this
# file's own, on their own connection key over the suite's MySQL pool. On another engine the whole file
# is skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, DataFrames, Dates
import Decimals
import PormG.QueryBuilder: bulk_insert, bulk_update, allocate_primary_keys, resync_sequences

module P3kModels
import PormG
import PormG.Models
# `ref` is the upsert target; `code` a second, nullable unique key.
Team = Models.Model("p3k_team",
  id = Models.IDField(),
  ref = Models.CharField(unique = true),
  code = Models.CharField(null = true, unique = true),
  name = Models.CharField())
Car = Models.Model("p3k_car",
  id = Models.IDField(),
  team = Models.ForeignKey(Team, pk_field = "id", on_delete = "RESTRICT", related_name = "cars"),
  label = Models.CharField())
# A primary key without AUTO_INCREMENT.
Status = Models.Model("p3k_status",
  code = Models.CharField(primary_key = true, max_length = 10),
  label = Models.CharField())
# Every kind of value bulk_update sends through a VALUES ROW column.
Stint = Models.Model("p3k_stint",
  id = Models.IDField(),
  time = Models.FloatField(null = true),
  pitted = Models.BooleanField(null = true),
  at = Models.DateTimeField(null = true),
  fee = Models.DecimalField(max_digits = 20, decimal_places = 2, null = true))
# A table on MySQL 8's default collation (utf8mb4_0900_ai_ci), not PormG's binary one.
Garage = Models.Model("p3k_garage",
  id = Models.IDField(),
  ref = Models.CharField(),
  name = Models.CharField())
# A many-to-many relation through an auto join table.
Sponsor = Models.Model("p3k_sponsor",
  id = Models.IDField(),
  name = Models.CharField())
Season = Models.Model("p3k_season",
  id = Models.IDField(),
  year = Models.IntegerField(),
  sponsors = Models.ManyToManyField(Sponsor, related_name = "seasons"))
Kit = Models.Model("p3k_kit",
  id = Models.IDField(),
  slug = Models.CharField(unique = true),
  blob = Models.BinaryField(null = true))
end

# The tables, in drop order (children first).
const _MYK_TABLES = ("p3k_car", "p3k_team", "p3k_status", "p3k_season", "p3k_sponsor", "p3k_stint", "p3k_plain_join",
                     "p3k_garage", "p3k_kit")

@testset "MySQL backend, phase 3c: bulk writes and the many-to-many manager (#1130)" begin
if only_on(:mysql, "bulk writes through the MySQL query builder (phase 3c)")
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.config["p3k_my"] = PormG.Configuration.Settings(connections = pool, change_data = true, db_def_folder = "p3k_my")
    Base.invokelatest(PormG.Models.set_models, P3kModels, "p3k_my")
    K = P3kModels
    run(sql; params = nothing) = PormG.fetch(pool, sql; params = params)
    msg(e) = sprint(showerror, e)
    caught(f) = try f(); nothing catch err; err end
    teams() = sort(DataFrame(K.Team.objects.values("ref", "code", "name").list()), :ref)
    rel = PormG.Models.get_many_to_many_relation(K.Season, "sponsors")
    run("DROP TABLE IF EXISTS `$(rel.through_table)`")
    for t in _MYK_TABLES
        run("DROP TABLE IF EXISTS `$(t)`")
    end
    try
        tail = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
        run("CREATE TABLE `p3k_team` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `ref` VARCHAR(255) NOT NULL UNIQUE, " *
            "`code` VARCHAR(255) NULL UNIQUE, `name` VARCHAR(255) NOT NULL)" * tail)
        run("CREATE TABLE `p3k_car` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `team` BIGINT NOT NULL, `label` VARCHAR(255) NOT NULL, " *
            "CONSTRAINT `p3k_car_team_fk` FOREIGN KEY (`team`) REFERENCES `p3k_team` (`id`) ON DELETE RESTRICT)" * tail)
        run("CREATE TABLE `p3k_status` (`code` VARCHAR(10) PRIMARY KEY, `label` VARCHAR(255) NOT NULL)" * tail)
        run("CREATE TABLE `p3k_stint` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `time` DOUBLE NULL, `pitted` TINYINT(1) NULL, " *
            "`at` DATETIME(3) NULL, `fee` DECIMAL(20,2) NULL)" * tail)
        run("CREATE TABLE `p3k_garage` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `ref` VARCHAR(255) NOT NULL, " *
            "`name` VARCHAR(255) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci")
        run("CREATE TABLE `p3k_sponsor` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `name` VARCHAR(255) NOT NULL)" * tail)
        run("CREATE TABLE `p3k_season` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `year` INT NOT NULL)" * tail)
        run("CREATE TABLE `p3k_kit` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `slug` VARCHAR(255) NOT NULL UNIQUE, " *
            "`blob` LONGBLOB NULL)" * tail)
        o, r = rel.owner_column, rel.related_column
        run("CREATE TABLE `$(rel.through_table)` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `$(o)` BIGINT NOT NULL, " *
            "`$(r)` BIGINT NOT NULL, UNIQUE KEY `$(rel.through_table)_uq` (`$(o)`, `$(r)`), " *
            "CONSTRAINT `$(rel.through_table)_o_fk` FOREIGN KEY (`$(o)`) REFERENCES `p3k_season` (`id`) ON DELETE CASCADE, " *
            "CONSTRAINT `$(rel.through_table)_r_fk` FOREIGN KEY (`$(r)`) REFERENCES `p3k_sponsor` (`id`) ON DELETE CASCADE)" * tail)

        # What: a plain bulk insert, chunked, counts the rows it wrote.
        # SQL: INSERT INTO `p3k_team` (`ref`, `name`) VALUES (?, ?), (?, ?) per chunk of two.
        # Why: MySQL binds one `?` per cell, as SQLite does (65535 per statement).
        @testset "a plain bulk insert across chunks" begin
            df = DataFrame(ref = ["mclaren", "williams", "ferrari", "lotus", "brabham"], name = ["McLaren", "Williams", "Ferrari", "Lotus", "Brabham"])
            r = bulk_insert(K.Team, df; chunk_size = 2)
            @test r.count == 5 && r.rows === nothing
            @test teams().ref == sort(df.ref) && all(ismissing, teams().code)
        end

        # What: on_conflict = :nothing skips a duplicate on any unique key and does not count it.
        # SQL: INSERT … VALUES (?, ?), … ON DUPLICATE KEY UPDATE `ref` = `p3k_team`.`ref`; a one-row frame
        #      sends the plain INSERT, whose duplicate-key error is the skip.
        # Why: MySQL counts an inserted row and a skipped one alike (1 each, under `found_rows`); the
        #      multi-row INSERT's report says how many met a duplicate (#1267).
        @testset "DO NOTHING counts only the rows it wrote" begin
            # Two old refs, one new ref twice, one new ref, one old code under a new ref.
            run("UPDATE `p3k_team` SET `code` = 'MCL' WHERE `ref` = 'mclaren'")
            df = DataFrame(ref = ["mclaren", "ferrari", "tyrrell", "tyrrell", "ligier", "march"],
                           code = [missing, missing, missing, missing, missing, "MCL"],
                           name = ["x", "x", "Tyrrell", "Tyrrell 2", "Ligier", "March"])
            r = bulk_insert(K.Team, df; on_conflict = :nothing)
            @test r.count == 2
            stored = teams()
            @test stored.ref == ["brabham", "ferrari", "ligier", "lotus", "mclaren", "tyrrell", "williams"]
            @test only(stored[stored.ref .== "tyrrell", :name]) == "Tyrrell"   # the first occurrence
            @test only(stored[stored.ref .== "mclaren", :name]) == "McLaren"   # untouched
            # Targeted on `ref`, with no `code` column: the same count rule.
            r = bulk_insert(K.Team, DataFrame(ref = ["ligier", "minardi", "minardi"], name = ["x", "Minardi", "y"]);
                            on_conflict = (action = :nothing, target = ["ref"]))
            @test r.count == 1
            # Chunks of two over three rows: the last chunk is one row, sent without the clause.
            r = bulk_insert(K.Team, DataFrame(ref = ["ligier", "minardi", "coloni"], name = ["x", "y", "Coloni"]);
                            on_conflict = :nothing, chunk_size = 2)
            @test r.count == 1 && K.Team.objects.filter("ref" => "coloni").count() == 1
            r = bulk_insert(K.Team, DataFrame(ref = ["ligier", "lola", "coloni"], name = ["x", "Lola", "y"]);
                            on_conflict = :nothing, chunk_size = 2)
            @test r.count == 1 && only(K.Team.objects.filter("ref" => "coloni").values("name").list())[:name] == "Coloni"
            # One row: new, then a duplicate.
            @test bulk_insert(K.Team, DataFrame(ref = ["arrows"], name = ["Arrows"]); on_conflict = :nothing).count == 1
            @test bulk_insert(K.Team, DataFrame(ref = ["arrows"], name = ["x"]); on_conflict = :nothing).count == 0
            @test only(K.Team.objects.filter("ref" => "arrows").values("name").list())[:name] == "Arrows"
            # A one-row skip is a duplicate key only: a foreign-key failure still raises.
            e = caught(() -> bulk_insert(K.Car, DataFrame(team = [99_999], label = ["ghost"]); on_conflict = :nothing))
            @test e isa PormG.IntegrityError && K.Car.objects.count() == 0
            # Inside a transaction, a skipped one-row duplicate leaves it usable.
            PormG.atomic(PormG.config["p3k_my"]) do
                @test bulk_insert(K.Team, DataFrame(ref = ["arrows"], name = ["x"]); on_conflict = :nothing).count == 0
                @test bulk_insert(K.Team, DataFrame(ref = ["toleman"], name = ["Toleman"]); on_conflict = :nothing).count == 1
            end
            @test K.Team.objects.filter("ref" => "toleman").count() == 1
        end

        # What: on_conflict = (action = :update, …) upserts on its target and counts every row.
        # SQL: INSERT … AS `__pormg_new` ON DUPLICATE KEY UPDATE `name` = `__pormg_new`.`name`.
        # Why: PostgreSQL counts each row the upsert inserted or updated; MySQL's own count would be 2 for
        #      a changed duplicate and 1 for an unchanged one (#1267).
        @testset "DO UPDATE upserts on its target and counts every row" begin
            df = DataFrame(ref = ["mclaren", "ferrari", "benetton"], name = ["McLaren", "Scuderia Ferrari", "Benetton"])
            r = bulk_insert(K.Team, df; on_conflict = (action = :update, target = ["ref"], set = ["name"]))
            @test r.count == 3
            stored = teams()
            @test only(stored[stored.ref .== "ferrari", :name]) == "Scuderia Ferrari"
            @test only(stored[stored.ref .== "benetton", :name]) == "Benetton"
            @test only(stored[stored.ref .== "mclaren", :code]) == "MCL"   # not in the SET
            # A row that could also conflict on `code` is refused, and nothing is written.
            n = K.Team.objects.count()
            e = caught(() -> bulk_insert(K.Team, DataFrame(ref = ["jordan"], code = ["MCL"], name = ["Jordan"]);
                                         on_conflict = (action = :update, target = ["ref"], set = ["name"])))
            @test e isa PormG.BackendCapabilityError && occursin("(code)", msg(e)) && K.Team.objects.count() == n
        end

        # What: returning = … matches the rows to the input by a key the client holds.
        # SQL: the INSERT, then SELECT … WHERE `ref` IN (?, …) on the same transaction connection (locked
        #      outside DO NOTHING); under DO NOTHING a pre-read of the keys already there.
        # Why: MySQL has no RETURNING, and no AUTO_INCREMENT value can be drawn ahead (#1266).
        @testset "returning by a supplied key or a target, and the auto-pk refusal" begin
            df = DataFrame(code = ["F", "R", "D"], label = ["Finished", "Retired", "Disqualified"])
            r = bulk_insert(K.Status, df; returning = ["code", "label"])
            @test r.count == 3 && r.rows.code == ["F", "R", "D"] && r.rows.label == ["Finished", "Retired", "Disqualified"]
            df = DataFrame(ref = ["ferrari", "zakspeed", "zakspeed", "osella"], name = ["x", "Zakspeed", "y", "Osella"])
            r = bulk_insert(K.Team, df; on_conflict = (action = :nothing, target = ["ref"]), returning = ["id", "name"])
            ids = Dict(row[:ref] => row[:id] for row in K.Team.objects.values("ref", "id").list())
            @test r.count == 2
            @test ismissing(r.rows.id[1]) && ismissing(r.rows.id[3])   # an old row, and the later repeat
            @test r.rows.id[2] == ids["zakspeed"] && r.rows.id[4] == ids["osella"] && r.rows.name[2] == "Zakspeed"
            r = bulk_insert(K.Team, DataFrame(ref = ["osella", "life"], name = ["Osella Corse", "Life"]);
                            on_conflict = (action = :update, target = ["ref"], set = ["name"]), returning = ["id", "name"])
            @test r.rows.id[1] == ids["osella"] && r.rows.name == ["Osella Corse", "Life"]
            @test r.rows.id[2] == only(K.Team.objects.filter("ref" => "life").values("id").list())[:id]   # a new row
            # Inside a transaction whose snapshot predates a row another session committed, the upsert
            # meets that row unchanged; the read-back locks, so it still finds it.
            PormG.atomic(PormG.config["p3k_my"]) do
                @test K.Team.objects.filter("ref" => "ags").count() == 0   # opens the snapshot
                PormG.fetch(pool, "INSERT INTO `p3k_team` (`ref`, `name`) VALUES (?, ?)"; params = ["ags", "AGS"], ignore_tx = true)
                r = bulk_insert(K.Team, DataFrame(ref = ["ags", "rial"], name = ["AGS", "Rial"]);
                                on_conflict = (action = :update, target = ["ref"], set = ["name"]), returning = ["id", "name"])
                @test r.count == 2 && r.rows.name == ["AGS", "Rial"] && !any(ismissing, r.rows.id)
            end
            n = K.Team.objects.count()
            e = caught(() -> bulk_insert(K.Team, DataFrame(ref = ["eurobrun"], name = ["EuroBrun"]); returning = ["id"]))
            @test e isa PormG.BackendCapabilityError && occursin("drawing auto-increment keys", msg(e)) &&
                  K.Team.objects.count() == n
            e = caught(() -> allocate_primary_keys(K.Team, DataFrame(ref = ["eurobrun"], name = ["EuroBrun"])))
            @test e isa PormG.BackendCapabilityError
        end

        # What: explicit ids, then generated ones; resync_sequences has nothing to repair.
        # SQL: INSERT with the `id` column, then one without; `resync_sequences` sends nothing.
        # Why: an explicit id moves AUTO_INCREMENT past it on MySQL, so there is no sequence to fall behind.
        @testset "explicit ids, then generated ones" begin
            top = maximum(row[:id] for row in K.Team.objects.values("id").list())
            bulk_insert(K.Team, DataFrame(id = [top + 100], ref = ["onyx"], name = ["Onyx"]))
            bulk_insert(K.Team, DataFrame(ref = ["larrousse"], name = ["Larrousse"]))
            @test only(K.Team.objects.filter("ref" => "larrousse").values("id").list())[:id] > top + 100
            @test resync_sequences(K.Team) == ["id"]
        end

        # What: bulk_update writes each row's values to the row its key matches, and counts matched rows.
        # SQL: UPDATE `p3k_team` AS `Tb`, (VALUES ROW(?, ?), …) AS source (`id`, `name`) SET `Tb`.`name` =
        #      source.`name` WHERE `Tb`.`id` = source.`id` [AND the handler's and filters='s predicates].
        # Why: MySQL has no UPDATE … FROM; its multi-table UPDATE over a VALUES ROW derived table is the
        #      shape, with every SET target qualified (a bare one is ambiguous, error 1052), and a
        #      membership subquery on the table it writes read through a derived table (error 1093).
        @testset "bulk_update: a multi-table UPDATE over VALUES ROW, matched rows counted" begin
            ids = Dict(row[:ref] => row[:id] for row in K.Team.objects.values("ref", "id").list())
            before = only(K.Team.objects.filter("ref" => "ferrari").values("name").list())[:name]
            r = bulk_update(K.Team, DataFrame(id = [ids["mclaren"], ids["ferrari"]], name = ["McLaren Honda", before]))
            @test r.count == 2   # the row whose value did not change is matched too, as update() counts
            stored = teams()
            @test only(stored[stored.ref .== "mclaren", :name]) == "McLaren Honda"
            # By another key, writing a NULL, in chunks of one.
            r = bulk_update(K.Team, DataFrame(ref = ["mclaren", "lotus"], code = [missing, "LOT"]); match_on = ["ref"], chunk_size = 1)
            @test r.count == 2
            stored = teams()
            @test ismissing(only(stored[stored.ref .== "mclaren", :code])) && only(stored[stored.ref .== "lotus", :code]) == "LOT"
            # The handler's filters and filters= scope it.
            r = bulk_update(K.Team.objects.filter("ref" => "lotus"), DataFrame(ref = ["lotus", "williams"], name = ["Team Lotus", "x"]);
                            match_on = ["ref"])
            @test r.count == 1 && only(K.Team.objects.filter("ref" => "williams").values("name").list())[:name] == "Williams"
            # A filter that reads the table being written: through a derived table on MySQL.
            r = bulk_update(K.Team, DataFrame(ref = ["lotus", "williams"], name = ["Lotus", "Williams F1"]); match_on = ["ref"],
                            filters = ["id__@in" => K.Team.objects.filter("ref" => "williams").values("id")])
            @test r.count == 1 && only(K.Team.objects.filter("ref" => "williams").values("name").list())[:name] == "Williams F1"
            @test only(K.Team.objects.filter("ref" => "lotus").values("name").list())[:name] == "Team Lotus"
            # A float, a boolean, a timestamp with milliseconds and a decimal round-trip exactly, and a
            # NULL overwrites a value. The float needs all 17 digits; the decimal has more than a double holds.
            a = K.Stint.objects.create("time" => 1.0).id
            b = K.Stint.objects.create("time" => 2.0, "pitted" => true, "at" => DateTime(1988, 1, 1),
                                       "fee" => parse(Decimals.Decimal, "1.00")).id
            at = DateTime(1988, 5, 15, 14, 30, 5, 123)
            wide = parse(Decimals.Decimal, "123456789012345678.91")
            df = DataFrame(id = [a, b], time = [0.1 + 0.2, missing], pitted = [true, missing],
                           at = [at, missing], fee = [wide, missing])
            @test bulk_update(K.Stint, df).count == 2
            rows = Dict(row[:id] => row for row in K.Stint.objects.values("id", "time", "pitted", "at", "fee").list())
            @test rows[a][:time] === 0.1 + 0.2 && rows[a][:pitted] === true && DateTime(rows[a][:at]) == at &&
                  rows[a][:fee] == wide
            @test all(ismissing, (rows[b][:time], rows[b][:pitted], rows[b][:at], rows[b][:fee]))
            @test only(DataFrame(run("SELECT CAST(`at` AS CHAR) AS t FROM `p3k_stint` WHERE `id` = ?"; params = [a])).t) ==
                  "1988-05-15 14:30:05.123"
            # On a case-insensitive table a text match key compares by the column's collation, as a filter does.
            for (ref, name) in (("lotus", "x"), ("brabham", "y"))
                K.Garage.objects.create("ref" => ref, "name" => name)
            end
            @test bulk_update(K.Garage, DataFrame(ref = ["LOTUS"], name = ["Lotus"]); match_on = ["ref"]).count == 1
            @test only(K.Garage.objects.filter("ref" => "lotus").values("name").list())[:name] == "Lotus"
            @test K.Garage.objects.filter("ref" => "LOTUS").count() == 1   # the filter agrees
        end

        # What: the many-to-many manager adds, removes, clears and sets the links of one row.
        # SQL: add is INSERT INTO <join> (o, r) SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM <join> WHERE o = ?
        #      AND r = ?) per target; remove and clear a DELETE; set reads the links, then removes and adds.
        # Why: MySQL runs PostgreSQL's idempotent INSERT as written, and it needs no unique key (#1130).
        @testset "the many-to-many manager: add, remove, clear, set" begin
            marlboro, camel, jps = (K.Sponsor.objects.create("name" => n).id for n in ("Marlboro", "Camel", "JPS"))
            season = K.Season.objects.create("year" => 1988)
            linked() = sort([row[:id] for row in K.Season.sponsors(season.id).all().values("id").list()])
            K.Season.sponsors(season.id).add(marlboro, camel)
            K.Season.sponsors(season.id).add(marlboro)   # already linked: nothing written
            @test linked() == sort([marlboro, camel])
            @test only(DataFrame(run("SELECT COUNT(*) AS n FROM `$(rel.through_table)`")).n) == 2
            K.Season.sponsors(season.id).remove(camel)
            @test linked() == [marlboro]
            @test K.Season.sponsors(season.id).set(camel, jps) == (added = 2, removed = 1)
            @test linked() == sort([camel, jps])
            K.Season.sponsors(season.id).clear()
            @test isempty(linked())
            # The NOT EXISTS shape needs no unique key: on a join table without one, a repeated add still
            # writes one row (an INSERT IGNORE would write two).
            run("CREATE TABLE `p3k_plain_join` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `o` BIGINT NOT NULL, `r` BIGINT NOT NULL)" * tail)
            QB = PormG.QueryBuilder
            for _ in 1:2
                QB._m2m_add!(pool, PormG.config["p3k_my"], "`p3k_plain_join`", "`o`", "`r`", season.id, [marlboro])
            end
            @test only(DataFrame(run("SELECT COUNT(*) AS n FROM `p3k_plain_join`")).n) == 1
        end

        # What: a bulk write with more parameters than MySQL.jl binds in one statement is chunked under
        # its limit, and every row is written.
        # SQL: INSERT INTO `p3k_stint` (…) VALUES (?, ?, ?, ?), … in chunks of at most 1024 rows (4096 ÷ 4),
        #      though `chunk_size` asks for all 2100; bulk_update's `VALUES ROW(?, ?)` source in chunks of at
        #      most 2048.
        # Why: MySQL.jl refuses a statement past its `max_columns` (4096) with a ProtocolError before
        #      sending it, though the protocol counts up to 65535 (#84): seeding 861 nine-column rows failed.
        @testset "a bulk write past MySQL.jl's parameter limit is chunked under it (#84)" begin
            n = 2100
            day = DateTime(1999, 1, 1)
            df = DataFrame(time = Float64.(1:n), pitted = fill(true, n), at = fill(day, n),
                           fee = [Decimals.Decimal(0, i, -2) for i in 1:n])
            bulk_insert(K.Stint, df; chunk_size = n)
            rows = K.Stint.objects.filter("at" => day).values("id", "time").order_by("time").list()
            @test length(rows) == n && [r[:time] for r in rows] == Float64.(1:n)
            ids = [r[:id] for r in rows]
            fees = [Decimals.Decimal(0, 10 * i, -2) for i in 1:n]
            res = bulk_update(K.Stint, DataFrame(id = ids, fee = fees); chunk_size = n)
            @test res.count == n
            stored = K.Stint.objects.filter("at" => day).values("fee").order_by("time").list()
            @test [r[:fee] for r in stored] == fees
        end

        # What: bytes with high values and a NUL round-trip through bulk_insert and bulk_update.
        # SQL: bulk_update's `UPDATE `p3k_kit` AS `Tb`, (VALUES ROW(?, ?)) AS source (`blob`, `slug`) SET
        #      `Tb`.`blob` = source.`blob` WHERE `Tb`.`slug` = source.`slug``, the bytes bound as bytes.
        # Why: the derived table's column must stay binary: as text in the connection's utf8mb4, MySQL
        #      refuses a byte sequence that is not UTF-8 (1366).
        @testset "bulk_insert and bulk_update write bytes as bytes" begin
            payload = UInt8[0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xC3, 0x28]
            updated = UInt8[0x00, 0x01, 0xFE, 0xFF, 0x00]
            blob(slug) = collect(only(K.Kit.objects.filter("slug" => slug).values("blob").list())[:blob])
            bulk_insert(K.Kit, DataFrame(slug = ["k1", "k2"], blob = Union{Vector{UInt8}, Missing}[payload, missing]))
            @test blob("k1") == payload
            res = bulk_update(K.Kit, DataFrame(slug = ["k1", "k2"], blob = [updated, payload]);
                              columns = ["blob", "slug"], match_on = ["slug"])
            @test res.count == 2
            @test blob("k1") == updated && blob("k2") == payload
        end
    finally
        run("DROP TABLE IF EXISTS `$(rel.through_table)`")
        for t in _MYK_TABLES
            run("DROP TABLE IF EXISTS `$(t)`")
        end
        delete!(PormG.config, "p3k_my")
    end
end
end
