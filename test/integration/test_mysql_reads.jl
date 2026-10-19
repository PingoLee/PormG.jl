# MySQL backend, phase 2a (#1130): plain-column fluent reads against a live MySQL 8.4.
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_reads.jl
#
# The reads go through the ORM surface (`M.Model.objects`). The tables and their rows are made with
# raw SQL, deliberately: `migrate` and the writes are later phases (4 and 3), so there is no ORM way to
# make them yet. The DDL declares what #1265 and #1270 decided a PormG column is on MySQL — text in
# `utf8mb4_0900_bin`, a `DateTimeField` as `DATETIME(3)`, a boolean as `TINYINT(1)` — and the tables
# are dropped at the end. On another engine the whole file is skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, Dates, TimeZones, Decimals, DataFrames
import PormG.QueryBuilder: Sum, Avg, Count, Max, Min, F

# The model tables this file creates, in drop order (children first).
const _MYR_TABLES = ("result", "new_join_position", "race", "circuit", "driver")

@testset "MySQL backend, phase 2a: plain-column reads (#1130)" begin
if only_on(:mysql, "reads through the MySQL query builder (phase 2a)")
    pool = PormG.config[PORMG_DB_FOLDER].connections
    run(sql; params = nothing) = PormG.fetch(pool, sql; params = params)
    sql_rows(sql; params = nothing) = DataFrame(run(sql; params = params))
    msg(e) = sprint(showerror, e)
    @test Tuple(PormG.Models.model_table_name(m) for m in (M.Result, M.New_join_position, M.Race, M.Circuit, M.Driver)) ==
          _MYR_TABLES
    for t in _MYR_TABLES
        run("DROP TABLE IF EXISTS `$(t)`")
    end
    try
        # ── Schema: what a PormG column is on MySQL (#1265, #1270) ─────────────────────────────
        tail = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
        run("CREATE TABLE `circuit` (`circuitid` BIGINT AUTO_INCREMENT PRIMARY KEY, `circuitref` VARCHAR(255) NOT NULL, " *
            "`name` VARCHAR(255) NOT NULL, `location` VARCHAR(255) NOT NULL, `country` VARCHAR(255) NOT NULL, " *
            "`lat` DOUBLE NOT NULL, `lng` DOUBLE NOT NULL, `alt` INT NOT NULL, `url` VARCHAR(255) NOT NULL)" * tail)
        run("CREATE TABLE `race` (`raceid` BIGINT AUTO_INCREMENT PRIMARY KEY, `year` INT NOT NULL, `round` INT NOT NULL, " *
            "`circuitid` BIGINT NOT NULL, `name` VARCHAR(255) NOT NULL, `date` DATE NOT NULL, `time` TIME(3) NULL, " *
            "`start_at` DATETIME(3) NULL, `url` VARCHAR(255) NOT NULL, " *
            join(("`$(p)_date` DATE NULL, `$(p)_time` TIME(3) NULL" for p in ("fp1", "fp2", "fp3", "quali", "sprint")), ", ") *
            ")" * tail)
        run("CREATE TABLE `driver` (`driverid` BIGINT AUTO_INCREMENT PRIMARY KEY, `driverref` VARCHAR(255) NOT NULL, " *
            "`number` INT NULL, `code` VARCHAR(255) NOT NULL, `forename` VARCHAR(255) NOT NULL, " *
            "`surname` VARCHAR(255) NOT NULL, `dob` DATE NOT NULL, `nationality` VARCHAR(255) NOT NULL, " *
            "`url` VARCHAR(255) NOT NULL)" * tail)
        run("CREATE TABLE `result` (`resultid` BIGINT AUTO_INCREMENT PRIMARY KEY, `raceid` BIGINT NOT NULL, " *
            "`driverid` BIGINT NOT NULL, `constructorid` BIGINT NOT NULL, `number` INT NULL, `grid` INT NOT NULL, " *
            "`position` INT NULL, `positiontext` VARCHAR(255) NOT NULL, `positionorder` INT NOT NULL, " *
            "`points` DOUBLE NOT NULL, `laps` INT NOT NULL, `time` VARCHAR(255) NULL, `milliseconds` INT NULL, " *
            "`fastestlap` INT NULL, `rank` INT NULL, `fastestlaptime` TIME(3) NULL, `fastestlapspeed` DOUBLE NULL, " *
            "`statusid` BIGINT NOT NULL)" * tail)
        run("CREATE TABLE `new_join_position` (`id` BIGINT AUTO_INCREMENT PRIMARY KEY, `description` VARCHAR(255) NOT NULL, " *
            "`result` INT NULL, `boolean_field` TINYINT(1) NULL)" * tail)

        # ── Seed: a few 1990-91 rows, plus the rows that pin #1265 ──────────────────────────────
        run("INSERT INTO `circuit` VALUES (1, 'interlagos', 'Autódromo José Carlos Pace', 'São Paulo', 'Brazil', -23.7, -46.7, 785, 'u'), " *
            "(2, 'suzuka', 'Suzuka Circuit', 'Suzuka', 'Japan', 34.8, 136.5, 45, 'u')")
        run("INSERT INTO `race` (`raceid`, `year`, `round`, `circuitid`, `name`, `date`, `time`, `start_at`, `url`) VALUES " *
            "(1, 1990, 2, 1, 'Brazilian Grand Prix', '1990-03-25', '17:00:00', '1990-03-25 17:00:00.125', 'u'), " *
            "(2, 1991, 2, 1, 'Brazilian Grand Prix', '1991-03-24', NULL, NULL, 'u'), " *
            "(3, 1991, 15, 2, 'Japanese Grand Prix', '1991-10-20', '05:00:00', '1991-10-20 05:00:00.000', 'u')")
        run("INSERT INTO `driver` VALUES " *
            "(1, 'senna', NULL, 'SEN', 'Ayrton', 'Senna', '1960-03-21', 'Brazilian', 'u'), " *
            "(2, 'prost', NULL, 'PRO', 'Alain', 'Prost', '1955-02-24', 'French', 'u'), " *
            "(3, 'mansell', NULL, 'MAN', 'Nigel', 'Mansell', '1953-08-08', 'British', 'u'), " *
            "(4, 'raikkonen', 7, 'RAI', 'Kimi', 'Räikkönen', '1979-10-17', 'Finnish', 'u'), " *
            # #1265 pin rows: a trailing space, and the same name in capitals, which the server default
            # collation would both equate with 'Senna'. And a literal `%` for the LIKE escape.
            "(5, 'senna_pad', NULL, 'SNP', 'Ayrton', 'Senna ', '1960-03-21', 'Brazilian', 'u'), " *
            "(6, 'senna_caps', NULL, 'SNC', 'Ayrton', 'SENNA', '1960-03-21', 'Brazilian', 'u'), " *
            "(7, 'pct_100%', NULL, 'PCT', 'Test', 'Hundred', '1960-01-01', 'None', 'u')")
        run("INSERT INTO `result` (`resultid`, `raceid`, `driverid`, `constructorid`, `grid`, `position`, `positiontext`, " *
            "`positionorder`, `points`, `laps`, `statusid`) VALUES " *
            "(1, 1, 1, 1, 1, 2, '2', 2, 6, 71, 1), (2, 1, 2, 2, 4, 1, '1', 1, 9, 71, 1), " *
            "(3, 1, 3, 3, 3, NULL, 'R', 7, 0, 30, 5), (4, 2, 1, 1, 1, 1, '1', 1, 10, 71, 1), " *
            "(5, 2, 2, 2, 2, NULL, 'R', 9, 0, 52, 5), (6, 3, 1, 1, 1, 2, '2', 2, 6, 53, 1), " *
            "(7, 3, 3, 3, 5, 3, '3', 3, 4, 53, 1)")
        run("INSERT INTO `new_join_position` VALUES (1, 'yes', 1, 1), (2, 'no', 2, 0), (3, 'unknown', 3, NULL)")

        # What: the session a statement reads with: UTC, the code-point collation, 30 decimal digits.
        # SQL: `SELECT @@collation_connection, @@div_precision_increment`, then `? = ?` on two parameters.
        # Why: a comparison of two parameters takes the connection collation (#1265); the server default
        # `utf8mb4_0900_ai_ci` would answer `'senna' = 'Senna'` true, and pad `'Senna '`.
        @testset "the session pins the collation and the decimal precision (#1265)" begin
            r = sql_rows("SELECT @@collation_connection AS c, @@div_precision_increment AS d, @@time_zone AS tz")
            @test r[1, :c] == "utf8mb4_0900_bin" && r[1, :d] == 30 && r[1, :tz] == "+00:00"
            eq(a, b) = sql_rows("SELECT (? = ?) AS e"; params = Any[a, b])[1, :e]
            @test eq("senna", "Senna") == 0 && eq("Senna ", "Senna") == 0 && eq("Senna", "Senna") == 1
        end

        # What: a filter across a join, projected and ordered, returns the rows it means.
        # SQL: SELECT `Tb`.`points` …, `Tb_1`.`surname` … INNER JOIN `driver` AS `Tb_1` … WHERE `Tb_1`.`surname` = ?
        #      ORDER BY (`points` IS NULL) DESC, `points` DESC
        # Why: the first fluent query MySQL runs; backticks, `?` and the NULL sort key all reach the server.
        @testset "a join, projected and ordered, returns the rows it means" begin
            rows = M.Result.objects.
                filter("driverid__surname" => "Senna").
                values("points", "driverid__surname", "raceid__year").
                order_by("-points").
                list()
            @test [r[:points] for r in rows] == [10.0, 6.0, 6.0]
            @test all(r -> r[:driverid__surname] == "Senna", rows) && Set(r[:raceid__year] for r in rows) == Set([1990, 1991])
            @test eltype([r[:points] for r in rows]) == Float64
        end

        # What: NULL placement is PormG's default on MySQL too — last ascending, first descending.
        # SQL: ORDER BY (`position` IS NULL) ASC, `position` ASC, and the DESC twin.
        # Why: MySQL sorts NULL as the smallest value, so without the key a descending order would put
        # them last, the opposite of PostgreSQL, silently.
        @testset "NULL placement: last ascending, first descending" begin
            nullish(v) = ismissing(v) || isnothing(v)
            asc = [r[:position] for r in M.Result.objects.order_by("position", "resultid").values("position").list()]
            @test asc[1:5] == [1, 1, 2, 2, 3] && all(nullish, asc[6:7])
            desc = [r[:position] for r in M.Result.objects.order_by("-position", "resultid").values("position").list()]
            @test all(nullish, desc[1:2]) && desc[3:7] == [3, 2, 2, 1, 1]
            # An alias inside the key is read as the projection when no FROM column has its name: a
            # rename, an aggregate, and the same under DISTINCT (measured on 8.4).
            renamed = [r[:pos2] for r in M.Result.objects.values("pos2" => "position", "resultid").order_by("-pos2", "resultid").list()]
            @test all(nullish, renamed[1:2]) && renamed[3:7] == [3, 2, 2, 1, 1]
            totals = [r[:total] for r in M.Result.objects.values("driverid", "total" => Sum("laps")).order_by("total").list()]
            @test totals == [83, 123, 195]
            distinct = [r[:pos2] for r in M.Result.objects.values("pos2" => "position").distinct().order_by("-pos2").list()]
            @test nullish(distinct[1]) && distinct[2:4] == [3, 2, 1]
            # An alias that is also another column's name (`laps`) is read there as the column, which is
            # never NULL, so the NULLs would sort last instead of first: refused before any SQL.
            e = try
                M.Result.objects.values("laps" => "position").order_by("-laps").list(); nothing
            catch err
                err
            end
            @test e isa PormG.QueryBuildError && occursin("a table this query reads has a column with that name", msg(e))
        end

        # What: the count forms, exists and first.
        # SQL: COUNT(*); COUNT(*) FROM (SELECT DISTINCT …) as `__pormg_distinct_count`; COUNT(DISTINCT …);
        #      COUNT(*) FROM (SELECT 1 … LIMIT ?) as `__pormg_sliced_count`; SELECT 1 … LIMIT 1.
        # Why: each derived table needs an alias MySQL accepts, and a slice binds its LIMIT last.
        @testset "count(), its distinct and sliced forms, exists() and first()" begin
            @test M.Result.objects.count() == 7
            @test M.Result.objects.filter("grid__@gt" => 2).count() == 3
            @test M.Result.objects.values("driverid").distinct().count() == 3
            @test M.Result.objects.count("driverid", distinct = true) == 3
            @test M.Result.objects.order_by("resultid").limit(4).count() == 4
            @test M.Result.objects.filter("grid__@gt" => 4).exists()
            @test !M.Result.objects.filter("grid__@gt" => 5).exists()
            first_row = M.Result.objects.order_by("-points").first()
            @test first_row !== nothing && first_row[:resultid] == 4
        end

        # What: an offset with no limit.
        # SQL: … ORDER BY … LIMIT 18446744073709551615 OFFSET ?
        # Why: MySQL has no standalone OFFSET (#1271); its documentation's no-limit spelling.
        @testset "an offset with no limit skips the rows it says" begin
            ids = [r[:resultid] for r in M.Result.objects.order_by("resultid").values("resultid").offset(5).list()]
            @test ids == [6, 7]
            ids = [r[:resultid] for r in M.Result.objects.order_by("resultid").values("resultid").limit(2).offset(1).list()]
            @test ids == [2, 3]
        end

        # What: text comparisons compare code points (#1265): equality and LIKE keep case, accents and
        # trailing spaces; the i* lookups fold case only; a literal `%` matches only itself.
        # SQL: `surname` = ?; `surname` LIKE ? ESCAPE '\\'; LOWER(`surname`) LIKE LOWER(?) ESCAPE '\\'.
        # Why: under the server default collation each of these returns more rows than it says.
        @testset "text comparisons compare code points (#1265)" begin
            refs(q) = sort([r[:driverref] for r in q.values("driverref").list()])
            @test refs(M.Driver.objects.filter("surname" => "Senna")) == ["senna"]
            @test refs(M.Driver.objects.filter("surname" => "senna")) == String[]
            @test refs(M.Driver.objects.filter("surname" => "Raikkonen")) == String[]
            @test refs(M.Driver.objects.filter("surname__@contains" => "enn")) == ["senna", "senna_pad"]
            @test refs(M.Driver.objects.filter("surname__@icontains" => "ENN")) == ["senna", "senna_caps", "senna_pad"]
            @test refs(M.Driver.objects.filter("surname__@iexact" => "SENNA")) == ["senna", "senna_caps"]
            @test refs(M.Driver.objects.filter("surname__@istartswith" => "räi")) == ["raikkonen"]
            # Accent-sensitive, as on PostgreSQL: `raik` is not `räik`.
            @test refs(M.Driver.objects.filter("surname__@icontains" => "raik")) == String[]
            @test refs(M.Driver.objects.filter("driverref__@contains" => "%")) == ["pct_100%"]
            @test refs(M.Driver.objects.filter("driverref__@endswith" => "_pad")) == ["senna_pad"]
            @test refs(M.Driver.objects.filter("surname__@nstartswith" => "S", "driverid__@lte" => 4)) == ["mansell", "prost", "raikkonen"]
        end

        # What: list membership, with values and with an empty list.
        # SQL: `grid` IN (?, ?, ?); an empty list matches no row.
        # Why: MySQL has no array binding, so a list is one placeholder per element.
        @testset "list membership: one placeholder per element, and the empty list" begin
            ids = sort([r[:resultid] for r in M.Result.objects.filter("grid__@in" => [1, 5]).values("resultid").list()])
            @test ids == [1, 4, 6, 7]
            @test M.Result.objects.filter("grid__@in" => Int[]).count() == 0
            sub = M.Driver.objects.filter("nationality" => "British").values("driverid")
            @test sort([r[:resultid] for r in M.Result.objects.filter("driverid__@in" => sub).values("resultid").list()]) == [3, 7]
        end

        # What: the nested and declared joins: EXISTS, a projected Subquery, a CTE, `cjoin_on`, `on()`,
        # and Q/Qor across a join.
        # SQL: WHERE EXISTS (SELECT 1 … LIMIT 1); (SELECT … ORDER BY … LIMIT ?) as `best`; WITH `br` AS (…);
        #      INNER JOIN `driver` AS `d` ON …; a join's ON condition with a bound value.
        # Why: each nests a render whose `?` values must bind in text order on a positional engine.
        @testset "EXISTS, Subquery, CTE, cjoin_on, on() and Q/Qor" begin
            import PormG.QueryBuilder: Exists, Subquery, OuterRef, CTE, Joined, Q, Qor
            winners = M.Driver.objects.filter(Exists(M.Result.objects.filter("driverid" => OuterRef("driverid"), "position" => 1)))
            @test sort([r[:driverref] for r in winners.values("driverref").list()]) == ["prost", "senna"]
            best = M.Driver.objects.filter("driverid__@lte" => 3).order_by("driverid").values("driverref",
                "best" => Subquery(M.Result.objects.filter("driverid" => OuterRef("driverid")).values("grid").order_by("grid").limit(1))).list()
            @test [r[:best] for r in best] == [1, 2, 3]
            q = M.Result.objects
            q.with("br" => M.Driver.objects.filter("nationality" => "Brazilian", "driverid__@lte" => 4).values("driverid", "surname"),
                   join_field = "driverid" => "driverid")
            # `join_field` joins the CTE LEFT: every result, the surname where the driver is Brazilian.
            br = Dict(r[:resultid] => r[:br_surname] for r in q.values("resultid", "br_surname" => CTE("br", "surname")).list())
            @test sort(collect(keys(br))) == 1:7
            @test sort([k for (k, v) in br if !(ismissing(v) || isnothing(v))]) == [1, 4, 6] && br[1] == "Senna"
            q = M.Result.objects.filter("grid__@lte" => 2).values("resultid", "d_surname" => Joined("d", "surname"))
            q.cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid")])
            @test Dict(r[:resultid] => r[:d_surname] for r in q.list()) == Dict(1 => "Senna", 4 => "Senna", 5 => "Prost", 6 => "Senna")
            q = M.Result.objects.filter("grid__@lte" => 3).values("resultid", "driverid__surname")
            q.on("driverid", "nationality" => "Brazilian")
            @test sort([r[:resultid] for r in q.list()]) == [1, 4, 6]
            either = M.Result.objects.filter(Qor("driverid__nationality" => "British", Q("raceid__year" => 1991, "grid" => 2)))
            @test sort([r[:resultid] for r in either.values("resultid").list()]) == [3, 5, 7]
        end

        # What: aggregates read as the type their call means (Django's `output_field`, #1121).
        # SQL: (SUM(`grid`) DIV 1); SUM(`points`); AVG(`grid`); COUNT; MAX; MIN.
        # Why: MySQL sums integers to a DECIMAL and averages them to a DECIMAL with 4 decimals by default.
        @testset "aggregates read as the type their call means" begin
            row = M.Result.objects.values("g" => Sum("grid"), "p" => Sum("points"), "a" => Avg("grid"),
                                          "c" => Count("resultid"), "mx" => Max("points"), "mn" => Min("grid")).list()[1]
            @test row[:g] === 17
            @test row[:p] === 35.0
            @test row[:a] === 17 / 7
            @test row[:c] == 7 && row[:mx] == 10.0 && row[:mn] == 1
            by_driver = Dict(r[:driverid] => r[:total] for r in M.Result.objects.values("driverid", "total" => Sum("laps")).list())
            @test by_driver == Dict(1 => 195, 2 => 123, 3 => 83)
            # Past the BIGINT range the sum raises, as PostgreSQL's `sum(bigint)::bigint` does, rather than
            # clamping to the largest value as `CAST(… AS SIGNED)` would (measured on 8.4). `raceid` is a
            # BIGINT; the two rows are this testset's own.
            big = typemax(Int64) - 1
            run("INSERT INTO `race` (`raceid`, `year`, `round`, `circuitid`, `name`, `date`, `url`) VALUES " *
                "(?, 2099, 1, 1, 'Edge', '2099-01-01', 'u'), (?, 2099, 2, 1, 'Edge', '2099-01-02', 'u')"; params = Any[big, 900])
            try
                exact = M.Race.objects.filter("raceid__@in" => [big, 1]).values("s" => Sum("raceid")).list()[1][:s]
                @test exact === typemax(Int64)
                e = try
                    M.Race.objects.filter("raceid__@in" => [big, 900]).values("s" => Sum("raceid")).list(); nothing
                catch err
                    err
                end
                @test e isa PormG.StatementError
            finally
                run("DELETE FROM `race` WHERE `year` = 2099")
            end
            # HAVING filters on the same integer sum.
            having = M.Result.objects.values("driverid", "total" => Sum("laps")).filter("total__@gt" => 100).order_by("driverid").list()
            @test [r[:driverid] for r in having] == [1, 2]
        end

        # What: a boolean, a date, a time and a time-zone-aware timestamp read as Julia's types (#1270).
        # SQL: SELECT `boolean_field`, `date`, `time`, `start_at`; a filter binding a ZonedDateTime.
        # Why: MySQL has no boolean on the wire (`Int8`), and a DATETIME has no zone.
        @testset "booleans, dates, times and timestamps read as Julia's types (#1270)" begin
            flags = Dict(r[:description] => r[:boolean_field] for r in M.New_join_position.objects.values("description", "boolean_field").list())
            @test flags["yes"] === true && flags["no"] === false
            @test ismissing(flags["unknown"]) || isnothing(flags["unknown"])
            race = M.Race.objects.filter("raceid" => 1).values("date", "time", "start_at").list()[1]
            @test race[:date] === Date(1990, 3, 25) && race[:time] == Time(17, 0, 0)
            @test race[:start_at] == ZonedDateTime(DateTime(1990, 3, 25, 17, 0, 0, 125), tz"UTC")
            at = ZonedDateTime(DateTime(1991, 10, 20, 5, 0, 0), tz"UTC")
            @test [r[:raceid] for r in M.Race.objects.filter("start_at" => at).values("raceid").list()] == [3]
            @test [r[:raceid] for r in M.Race.objects.filter("date__@gte" => Date(1991, 1, 1)).order_by("raceid").values("raceid").list()] == [2, 3]
        end

        # What: select_for_update takes InnoDB row locks inside a transaction, and refuses what MySQL lacks.
        # SQL: … FOR UPDATE / FOR UPDATE SKIP LOCKED; `no_key = true` raises before any SQL.
        # Why: #1269 — MySQL has no lock that leaves foreign-key checks free, so `no_key` is refused.
        @testset "select_for_update locks rows, and refuses no_key (#1269)" begin
            rows = PormG.atomic(PORMG_DB_FOLDER) do
                q = M.Driver.objects.filter("driverref" => "senna")
                q.select_for_update()
                @test contains(q.list(show_query = :sql), "FOR UPDATE")
                q.list()
            end
            @test length(rows) == 1
            claimed = PormG.atomic(PORMG_DB_FOLDER) do
                M.Driver.objects.filter("driverref" => "senna").select_for_update(skip_locked = true).list()
            end
            @test length(claimed) == 1
            e = try
                PormG.atomic(PORMG_DB_FOLDER) do
                    M.Driver.objects.filter("driverref" => "senna").select_for_update(no_key = true).list()
                end
                nothing
            catch err
                err
            end
            @test e isa PormG.BackendCapabilityError && occursin("which MySQL does not support", msg(e))
            @test_throws PormG.PormGError M.Driver.objects.filter("driverref" => "senna").select_for_update().list()
        end

        # What: what phase 2a does not render stays loud, never another engine's SQL.
        # SQL: none — division (phase 2b's `DIV`) and `create` (phase 3) fail before a statement is sent.
        # Why: a silent wrong answer is the failure #1130 exists to prevent.
        @testset "what 2a does not render fails before any SQL is sent" begin
            # Each names the piece of the query builder MySQL does not have yet.
            e = try; M.Result.objects.values("half" => F("grid") / 2).list(); nothing; catch err; err; end
            @test e isa MethodError && e.f === PormG.QueryBuilder._division_sql
            e = try; M.New_join_position.objects.create("description" => "x"); nothing; catch err; err; end
            @test e isa MethodError && e.f === PormG.QueryBuilder._insert_returns_rows
            @test M.New_join_position.objects.count() == 3
        end

        # What: a DurationField filter is refused before any SQL; an ordering or a sum over one reaches the
        # server and is rejected there; IS NULL works.
        # SQL: none for a filter; for an ordering or a sum, the millisecond form PormG writes for an engine
        #      with no interval type, which MySQL cannot parse (`CAST(… AS INTEGER)`), whatever the rows hold.
        # Why: what a DurationField stores on MySQL is phase 4's decision; until then a duration read
        # must fail rather than answer.
        @testset "a DurationField read fails rather than answers" begin
            run("UPDATE `result` SET `fastestlaptime` = '00:01:20.500' WHERE `resultid` IN (1, 2)")
            for pair in ("fastestlaptime" => Dates.Second(80), "fastestlaptime__@in" => [Dates.Second(80)],
                         "fastestlaptime__@gt" => Dates.Second(70))
                e = try; M.Result.objects.filter(pair).values("resultid").list(); nothing; catch err; err; end
                @test e isa PormG.UnsupportedConnectionError && occursin("not rendered for MySQL yet", msg(e))
            end
            for q in (() -> M.Result.objects.order_by("fastestlaptime").values("resultid").list(),
                      () -> M.Result.objects.values("t" => Sum("fastestlaptime")).list())
                e = try; q(); nothing; catch err; err; end
                @test e isa PormG.StatementError
            end
            @test M.Result.objects.filter("fastestlaptime__@isnull" => false).count() == 2
        end
    finally
        for t in _MYR_TABLES
            run("DROP TABLE IF EXISTS `$(t)`")
        end
    end
end
end
