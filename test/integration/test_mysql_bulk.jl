# MySQL backend, phase 3c-1 (#1130): `bulk_insert` against a live MySQL 8.4 — chunks, `on_conflict`
# (#1267) with the counts its docstring promises, and `returning` without RETURNING (#1266).
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
using Test, DataFrames
import PormG.QueryBuilder: bulk_insert, allocate_primary_keys, resync_sequences

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
end

# The tables, in drop order (children first).
const _MYK_TABLES = ("p3k_car", "p3k_team", "p3k_status")

@testset "MySQL backend, phase 3c-1: bulk_insert (#1130)" begin
if only_on(:mysql, "bulk writes through the MySQL query builder (phase 3c-1)")
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.config["p3k_my"] = PormG.Configuration.Settings(connections = pool, change_data = true, db_def_folder = "p3k_my")
    Base.invokelatest(PormG.Models.set_models, P3kModels, "p3k_my")
    K = P3kModels
    run(sql; params = nothing) = PormG.fetch(pool, sql; params = params)
    msg(e) = sprint(showerror, e)
    caught(f) = try f(); nothing catch err; err end
    teams() = sort(DataFrame(K.Team.objects.values("ref", "code", "name").list()), :ref)
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
            r = bulk_insert(K.Team, DataFrame(ref = ["osella", "coloni"], name = ["Osella Corse", "Coloni"]);
                            on_conflict = (action = :update, target = ["ref"], set = ["name"]), returning = ["id", "name"])
            @test r.rows.id[1] == ids["osella"] && r.rows.name == ["Osella Corse", "Coloni"] && !ismissing(r.rows.id[2])
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
    finally
        for t in _MYK_TABLES
            run("DROP TABLE IF EXISTS `$(t)`")
        end
        delete!(PormG.config, "p3k_my")
    end
end
end
