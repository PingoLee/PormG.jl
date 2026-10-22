# MySQL backend, phases 2a and 2b (#1130): fluent reads against a live MySQL 8.4 — plain columns (2a),
# and the expressions 2b renders: division, casts, `Concat`, date arithmetic and intervals.
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_reads.jl
#
# The reads go through the ORM surface (`M.Model.objects`). The tables and their rows are made with
# raw SQL, deliberately: `migrate` and the writes are later phases (4 and 3), so there is no ORM way to
# make them yet. The DDL declares what #1265 and #1270 decided a PormG column is on MySQL — text in
# `utf8mb4_0900_bin`, a `DateTimeField` as `DATETIME(3)`, a boolean as `TINYINT(1)`, a `DurationField`
# as a BIGINT of microseconds (#1130) — and the tables
# are dropped at the end. On another engine the whole file is skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, Dates, TimeZones, Decimals, DataFrames
import PormG.QueryBuilder: Sum, Avg, Count, Max, Min, F, Coalesce, Cast, Concat, Greatest, Least, NullIf, Case, When, Value, Abs

# The model tables this file creates, in drop order (children first).
const _MYR_TABLES = ("result", "new_join_position", "race", "circuit", "driver")

@testset "MySQL backend, phases 2a and 2b: reads (#1130)" begin
if only_on(:mysql, "reads through the MySQL query builder (phases 2a and 2b)")
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
            "`fastestlap` INT NULL, `rank` INT NULL, `fastestlaptime` BIGINT NULL, `fastestlapspeed` DOUBLE NULL, " *
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

        # What: what MySQL does not render yet stays loud, never another engine's SQL.
        # SQL: none — `Abs` (phase 2c-2) and `create` (phase 3) fail before a statement is sent.
        # Why: a silent wrong answer is the failure #1130 exists to prevent.
        @testset "what is not rendered yet fails before any SQL is sent" begin
            # Each names the piece of the query builder MySQL does not have yet.
            e = try; M.Result.objects.values("a" => Abs("grid")).list(); nothing; catch err; err; end
            @test e isa MethodError && e.f === PormG.Dialect.ABS
            e = try; M.New_join_position.objects.create("description" => "x"); nothing; catch err; err; end
            @test e isa MethodError && e.f === PormG.QueryBuilder._insert_returns_rows
            @test M.New_join_position.objects.count() == 3
        end

        # What: `/` divides as its operands mean: integers as integers, a float side keeping the fraction.
        # SQL: `(`Tb`.`grid` DIV ?)` between integers, `(`Tb`.`points` / ?)` beside a DOUBLE.
        # Why: MySQL's own `/` keeps the fraction of `7 / 2`, which `F("grid") / 2` does not mean (#1130
        # phase 2b): each value is checked against Julia's own division, never against another engine.
        @testset "division divides integers as integers, and keeps a float's fraction" begin
            rows = M.Result.objects.values("resultid", "grid", "laps", "points", "h" => F("grid") / 2,
                                           "q" => F("laps") / F("grid"), "n" => (F("grid") - 10) / 4,
                                           "f" => F("points") / 4).order_by("resultid").list()
            @test length(rows) == 7
            for r in rows
                @test r[:h] isa Integer && r[:h] == div(r[:grid], 2)
                @test r[:q] isa Integer && r[:q] == div(r[:laps], r[:grid])
                # truncation toward zero, as an integer `/` means: (1 - 10) / 4 is -2, not -3
                @test r[:n] == div(r[:grid] - 10, 4)
                @test r[:f] isa Float64 && r[:f] == r[:points] / 4
            end
            # Division by zero reads NULL on MySQL (the server warns, 1365); documented per engine.
            @test only(M.Result.objects.filter("resultid" => 1).values("z" => F("grid") / 0).list())[:z] === missing
        end

        # What: `Cast` reads back as the type it names, and a cast MySQL computes another value for is
        # refused before any SQL.
        # SQL: `CAST(`Tb`.`grid` AS CHAR)`, `CAST(… AS DECIMAL(10,2))`, `CAST(… AS SIGNED)`, `CAST(… AS FLOAT)`,
        #      `CAST(`Tb`.`start_at` AS DATE)`, `CAST(… AS DATETIME(3))`, `CAST(… AS DECIMAL(65,30))`.
        # Why: MySQL's CAST takes a closed set of targets, so each type name is mapped to the one that
        # holds its meaning (#1271): checked here against the value each type means in Julia.
        @testset "Cast reads back as the type it names" begin
            r = only(M.Result.objects.filter("resultid" => 2).values(
                "t" => Cast("grid", "text"), "d" => Cast("points", "numeric(10,2)"), "i" => Cast("points", "integer"),
                "n" => Cast("grid", "numeric"), "f4" => Cast("points", "real"), "f8" => Cast("grid", "float8")).list())
            @test r[:t] == "4"
            @test r[:d] isa Decimals.Decimal && r[:d] == Decimals.Decimal(9)
            @test r[:i] isa Integer && r[:i] == 9
            # A bare `numeric` keeps the value: MySQL's own bare `DECIMAL` would be `DECIMAL(10,0)`.
            @test r[:n] isa Decimals.Decimal && r[:n] == Decimals.Decimal(4)
            @test r[:f4] isa Float32 && r[:f4] == 9.0f0
            @test r[:f8] isa Float64 && r[:f8] == 4.0
            # Rounding to the scale and to the nearest integer, as the casts mean: 6 / 4 = 1.5.
            r = only(M.Result.objects.filter("resultid" => 1).values(
                "half" => Cast(F("points") / 4, "integer"), "s" => Cast(F("points") / 4, "numeric(10,0)")).list())
            @test r[:half] == 2 && r[:s] == Decimals.Decimal(2)
            # Temporal targets: a timestamp cut to its date, and a timestamp at millisecond precision.
            r = only(M.Race.objects.filter("raceid" => 1).values(
                "d" => Cast("start_at", "date"), "ts" => Cast("start_at", "timestamp")).list())
            @test r[:d] == Date(1990, 3, 25)
            @test r[:ts] == DateTime(1990, 3, 25, 17, 0, 0, 125)
            # A cast whose value MySQL computes differently is refused before any SQL (#1260): a date's
            # number is its digits there (`19900325`), not the error the cast means.
            e = try; M.Race.objects.values("n" => Cast("date", "integer")).list(); nothing; catch err; err; end
            @test e isa PormG.QueryBuildError && occursin("so PormG refuses it on MySQL", msg(e))
            # A type with no faithful MySQL target is refused before any SQL, never passed through.
            e = try; M.Result.objects.values("b" => Cast("grid", "bytea")).list(); nothing; catch err; err; end
            @test e isa PormG.UnsupportedConnectionError && occursin("is not rendered for MySQL yet", msg(e))
            # A boolean has no CAST target there either; over an integer it is `((x) <> 0)`, as PostgreSQL's
            # `integer::boolean` reads it (#1130 phase 2c-1).
            flags = M.Result.objects.values("resultid", "grid", "b" => Cast(F("grid") - 1, "boolean")).order_by("resultid").list()
            @test all(r -> r[:b] === (r[:grid] - 1 != 0), flags)
        end

        # What: `Concat` joins its operands' text and skips a NULL one, as it means on every engine.
        # SQL: `CONCAT_WS('', `Tb`.`positiontext`, `Tb`.`grid`)` — never `||`, a logical OR on MySQL.
        # Why: `'a' || 'b'` is `0` on MySQL; a NULL operand is skipped, not a NULL result (#1006).
        @testset "Concat joins text and skips a NULL operand" begin
            rows = M.Result.objects.filter("resultid__@in" => [1, 3]).values(
                "resultid", "positiontext", "grid", "position", "c" => Concat("positiontext", "grid"),
                "n" => Concat("raceid__name", "position")).order_by("resultid").list()
            @test [r[:c] for r in rows] == [string(r[:positiontext], r[:grid]) for r in rows] == ["21", "R3"]
            # Result 3 has no position: the NULL operand is skipped, so the name stands alone.
            @test [r[:n] for r in rows] == ["Brazilian Grand Prix2", "Brazilian Grand Prix"]
            @test rows[2][:position] === missing
        end

        # What: date arithmetic answers as Julia's own `Date` arithmetic does.
        # SQL: `(`Tb`.`date` + INTERVAL ? DAY)`, `((… - INTERVAL ? MONTH) - INTERVAL ? DAY)`,
        #      `(`Tb`.`date` + INTERVAL (`Tb`.`year`) DAY)`, `DATEDIFF(…)`, `(`Tb`.`start_at` + INTERVAL ? HOUR)`.
        # Why: MySQL's own `+` on a date reads its digits (`DATE '2009-03-29' + 1` is `20090330`), so each
        # shape renders MySQL's date functions (#1130 phase 2b); the values are checked against Julia.
        @testset "date arithmetic answers as Julia's Date arithmetic" begin
            rows = M.Race.objects.values("raceid", "date", "year", "start_at",
                "d3" => F("date") + Day(3), "m" => F("date") - (Month(1) + Day(2)), "y" => F("date") + F("year"),
                "dd" => F("date") - F("date"),
                "h" => F("start_at") + Hour(2), "ms" => F("start_at") + Millisecond(1500)).order_by("raceid").list()
            @test length(rows) == 3
            for r in rows
                @test r[:d3] isa Date && r[:d3] == r[:date] + Day(3)
                @test r[:m] == r[:date] - Month(1) - Day(2)
                @test r[:y] == r[:date] + Day(r[:year])
                @test r[:dd] == 0
                if r[:start_at] === missing
                    # NULL in is NULL out.
                    @test r[:h] === missing && r[:ms] === missing
                else
                    @test r[:h] == r[:start_at] + Hour(2)
                    @test r[:ms] == r[:start_at] + Millisecond(1500)
                end
            end
            # The difference of two dates is the whole days between them, negative the other way round.
            @test only(M.Race.objects.filter("raceid" => 3).values("n" => F("date") - Date(1991, 3, 24)).list())[:n] == 210
            # A value PormG cannot type beside a date is refused before any SQL, naming the typed spellings.
            e = try; M.Race.objects.values("x" => F("date") + Sum("year")).list(); nothing; catch err; err; end
            @test e isa PormG.QueryBuildError && occursin("reads a date as the number its digits spell", msg(e))
        end

        # What: a DurationField reads, filters, orders and computes as the duration it holds, each value
        # checked against Julia's own `Dates` arithmetic.
        # SQL: the column is a BIGINT of microseconds (#1130, Django's choice): `WHERE `Tb`.`fastestlaptime`
        #      = ?` binding `80500000`; `SUM(…)`, `CAST(ROUND(AVG(…)) AS SIGNED)`,
        #      `CAST(ROUND((…) * (?)) AS SIGNED)`; `(-TIMESTAMPDIFF(MICROSECOND, l, r))`;
        #      `(`Tb_1`.`date` + INTERVAL (`Tb`.`fastestlaptime`) MICROSECOND)`.
        # Why: MySQL has no interval type; its `TIME` stops at 838:59:59, and the `HH:MM:SS` text against a
        # BIGINT would compare the number its leading digits spell, silently. 1000 hours is past `TIME`.
        @testset "a DurationField is its microseconds: it reads, filters, orders and computes" begin
            lap = Dict(1 => Second(80) + Millisecond(500), 2 => Hour(1000) + Microsecond(1),
                       3 => Second(81) + Millisecond(250))
            us(p) = Dates.tons(p) ÷ 1_000
            for (id, p) in lap
                run("UPDATE `result` SET `fastestlaptime` = ? WHERE `resultid` = ?"; params = Any[us(p), id])
            end
            same(a, b) = a !== missing && Dates.tons(a) == Dates.tons(b)
            ids(q) = sort!([r[:resultid] for r in q.values("resultid").list()])
            # Reads back as the `CompoundPeriod` SQLite reads, in its units.
            row = only(M.Result.objects.filter("resultid" => 1).values("t" => F("fastestlaptime")).list())
            @test row[:t] isa Dates.CompoundPeriod && row[:t].periods == PormG.Dialect._parse_sqlite_interval("00:01:20.5").periods
            @test same(only(M.Result.objects.filter("resultid" => 2).values("fastestlaptime").list())[:fastestlaptime], lap[2])
            # Filters bind the microseconds, an equality and a membership too.
            @test ids(M.Result.objects.filter("fastestlaptime" => lap[1])) == [1]
            @test ids(M.Result.objects.filter("fastestlaptime" => "00:01:20.5")) == [1]
            @test ids(M.Result.objects.filter("fastestlaptime__@in" => [lap[1], lap[3]])) == [1, 3]
            @test ids(M.Result.objects.filter("fastestlaptime__@gt" => Second(81))) == [2, 3]
            @test ids(M.Result.objects.filter("fastestlaptime__@range" => [Second(80), Second(82)])) == [1, 3]
            @test ids(M.Result.objects.filter(F("fastestlaptime") > Hour(1))) == [2]
            @test M.Result.objects.filter("fastestlaptime__@isnull" => false).count() == 3
            # Ordered as durations: 1000 hours last, where its `HH:MM:SS` text would sort first.
            @test [r[:resultid] for r in M.Result.objects.filter("fastestlaptime__@isnull" => false).
                   values("resultid").order_by("fastestlaptime").list()] == [1, 3, 2]
            # Aggregates and arithmetic, against Julia.
            agg = only(M.Result.objects.values("s" => Sum("fastestlaptime"), "x" => Max("fastestlaptime")).list())
            @test same(agg[:s], lap[1] + lap[2] + lap[3]) && same(agg[:x], lap[2])
            avg = only(M.Result.objects.filter("resultid__@in" => [1, 3]).values("a" => Avg("fastestlaptime")).list())
            @test same(avg[:a], Microsecond((us(lap[1]) + us(lap[3])) ÷ 2))
            r1 = only(M.Result.objects.filter("resultid" => 1).values(
                "d" => F("fastestlaptime") * 2, "t" => F("fastestlaptime") / 3,
                "p" => F("fastestlaptime") + F("fastestlaptime"), "on" => F("raceid__date") + F("fastestlaptime")).list())
            @test same(r1[:d], Microsecond(2 * us(lap[1]))) && same(r1[:p], Microsecond(2 * us(lap[1])))
            @test same(r1[:t], Microsecond(round(Int, us(lap[1]) / 3)))
            @test r1[:on] == DateTime(1990, 3, 25) + lap[1]
            # An alias over arithmetic orders and filters as the duration it is.
            q = M.Result.objects.values("resultid", "t" => F("fastestlaptime") * 2)
            @test [r[:resultid] for r in q.filter("t__@gt" => Second(162)).order_by("t").list()] == [3, 2]
            # A timestamp difference is the microseconds between them; NULL in is NULL out.
            diffs = M.Race.objects.values("raceid", "start_at", "g" => (F("start_at") + Hour(2)) - F("start_at")).
                order_by("raceid").list()
            for r in diffs
                @test r[:start_at] === missing ? r[:g] === missing : same(r[:g], Hour(2))
            end
            # Its text is the `HH:MM:SS` text PormG writes and reads back, not the stored count.
            texts = M.Result.objects.filter("fastestlaptime__@isnull" => false).values("resultid",
                "t" => Cast("fastestlaptime", "text"), "d" => Cast(F("fastestlaptime") * 2, "text")).order_by("resultid").list()
            @test [r[:t] for r in texts] == ["00:01:20.5", "1000:00:00.000001", "00:01:21.25"]
            @test [r[:d] for r in texts] == ["00:02:41", "2000:00:00.000002", "00:02:42.5"]
            @test PormG.Models.format_duration_sql(lap[3]) == texts[3][:t]
            # Over an aggregate too, grouped: the derived table reads the outer query's aggregate.
            per_race = M.Result.objects.filter("fastestlaptime__@isnull" => false).values("raceid",
                "s" => Cast(Sum("fastestlaptime"), "text"), "x" => Cast(Max("fastestlaptime"), "text")).order_by("raceid").list()
            @test [(r[:raceid], r[:s], r[:x]) for r in per_race] ==
                  [(1, "1000:02:41.750001", "1000:00:00.000001")]
            # What has no meaning is refused before any SQL, naming MySQL.
            e = try; M.Result.objects.values("t" => F("fastestlaptime") + 1).list(); nothing; catch err; err; end
            @test e isa PormG.QueryBuildError && occursin("is not supported on MySQL", msg(e))
        end
        # What: the conditionals answer as their meaning, each value checked against Julia over the same rows.
        # SQL: `COALESCE(`Tb`.`position`, ?)`; `GREATEST(COALESCE(a, b), COALESCE(b, a))` (MySQL's GREATEST
        #      is NULL on any NULL, so the operands are the #844 rotations); `NULLIF(…)`; `CASE WHEN … THEN ?
        #      ELSE ? END`; a Decimal branch bound as `CAST(? AS DECIMAL(p,s))`; `CAST(… AS DECIMAL(10,2))`;
        #      a boolean declaration as `((…) <> 0)`; an interval declared as text through its `HH:MM:SS`.
        # Why: MySQL has each function natively, but a Decimal bound as text made a CASE a VARCHAR that
        #      ordered as text, a boolean has no cast target there, and an interval is its microseconds
        #      (#1130 phase 2c-1).
        @testset "conditionals answer as their meaning (phase 2c-1)" begin
            base = Dict(r[:resultid] => r for r in M.Result.objects.values("resultid", "grid", "position", "fastestlaptime").list())
            rows = M.Result.objects.values("resultid",
                "c" => Coalesce("position", 0), "g" => Greatest("grid", "position"), "l" => Least("grid", "position"),
                "n" => NullIf("grid", 1), "k" => Case(When("grid__@gt" => 2, then = "back"), default = "front"),
                "d" => Case(When("grid__@gt" => 2, then = parse(Decimal, "10.25")), default = parse(Decimal, "5.5")),
                "o" => Coalesce("position", 0; output_field = "numeric(10,2)"),
                "b" => Case(When("grid__@gt" => 2, then = 1), default = 0; output_field = "boolean"),
                "t" => Coalesce("position", 0; output_field = "text")).order_by("resultid").list()
            @test length(rows) == 7
            for r in rows
                g, p = base[r[:resultid]][:grid], base[r[:resultid]][:position]
                @test r[:c] == coalesce(p, 0)
                @test r[:g] == (p === missing ? g : max(g, p)) && r[:l] == (p === missing ? g : min(g, p))
                @test isequal(r[:n], g == 1 ? missing : g)
                @test r[:k] == (g > 2 ? "back" : "front")
                @test r[:d] == (g > 2 ? parse(Decimal, "10.25") : parse(Decimal, "5.5")) && r[:d] isa Decimal
                @test r[:o] == coalesce(p, 0) && r[:o] isa Decimal
                @test r[:b] === (g > 2) && r[:t] == string(coalesce(p, 0))
            end
            # The Decimal branch orders as a number, not as text (`'10.25' < '5.5'`).
            ordered = M.Result.objects.values("resultid", "d" => Case(When("grid__@gt" => 2, then = parse(Decimal, "10.25")),
                default = parse(Decimal, "5.5"))).order_by("d", "resultid").list()
            @test issorted([Float64(r[:d]) for r in ordered]) && [r[:d] for r in ordered][1] == parse(Decimal, "5.5")
            # A Case over durations is the microseconds it holds: it orders, filters and reads as one.
            lap = Case(When("grid__@gt" => 2, then = F("fastestlaptime")), default = Value(Second(0)))
            want(id) = (g = base[id][:grid]; t = base[id][:fastestlaptime]; g > 2 ? t : Dates.CompoundPeriod(Second(0)))
            us(p) = p === missing ? missing : Dates.tons(p) ÷ 1000
            laps = M.Result.objects.values("resultid", "v" => lap).order_by("v", "resultid").list()
            @test isequal([us(r[:v]) for r in laps], sort([us(want(r[:resultid])) for r in laps]))
            @test all(r -> isequal(us(r[:v]), us(want(r[:resultid]))), laps)
            over = M.Result.objects.values("resultid", "v" => lap).filter("v__@gt" => Second(80)).order_by("resultid").list()
            @test [r[:resultid] for r in over] == sort([id for id in keys(base) if (u = us(want(id))) !== missing && u > 80_000_000])
            text = only(M.Result.objects.filter("resultid" => 1).values("t" => Coalesce("fastestlaptime", Value(Second(0)); output_field = "text")).list())
            @test text[:t] == PormG.Models.format_duration_sql(base[1][:fastestlaptime])
            # A duration beside a number would read the duration as its count: refused before any SQL.
            e = try; M.Result.objects.values("c" => Coalesce("fastestlaptime", 0)).list(); nothing; catch err; err; end
            @test e isa PormG.QueryBuildError && occursin("over an interval and a value of another type", msg(e))
        end
    finally
        for t in _MYR_TABLES
            run("DROP TABLE IF EXISTS `$(t)`")
        end
    end
end
end
