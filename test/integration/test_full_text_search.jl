# ==============================================================================
# FULL-TEXT SEARCH — Live-Database Integration Test (#31, part 1)
#
# The `@search` lookup and `SearchQuery` / `SearchVector` / `SearchRank` / `SearchHeadline` against the
# F1 fixture. PostgreSQL only: on SQLite this file asserts the refusal and nothing else.
#
# A search result is checked against an INDEPENDENT reading of the same rows — every surname or race
# name, fetched through the ORM and tokenized in Julia — rather than against a list typed from memory,
# so a lookup that silently matched more or fewer rows fails here. The unit file
# (`test/unit/test_full_text_search.jl`) pins the SQL; only the server can say it means what it says.
#
# The last testset is the reason the config is a literal: a GIN index built on `to_tsvector('simple',
# body)` — declared through `Models.search_vector_expression` (#1021) — serves the lookup. It builds a scratch table through the planner, so the shared fixture never
# sees it, and drops it in a `finally`.
#
#   julia -t auto --project=test/integration test/integration/test_full_text_search.jl
#   PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_full_text_search.jl
# ==============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

using PormG.Functions: SearchQuery, SearchVector, SearchRank, SearchHeadline
import PormG.Migrations: LiveTable, get_migration_plan, _order_statements, _execute_statements_pg
import PormG.ConnectionPool: finalize_transaction_connection!
const _fts31_tx = PormG.ConnectionPool.with_transaction

const FTS31_TABLE = "pormg_fts31_doc"

# The words of a text as PostgreSQL's `simple` parser yields them for ASCII names: lowercased, split on
# anything that is not a letter or a digit.
_fts31_words(s::AbstractString) = filter(!isempty, split(lowercase(s), r"[^\p{L}\p{N}]+"))
_fts31_err(f) = try f(); nothing catch e; e end

@testset "Full-text search, live ($(PORMG_DB_FOLDER)) (#31)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    is_pg = pool isa PormG.PormGPostgres

    # ─────────────────────────────────────────────────────────────────────
    # SQLite: refused when the query is built, before anything runs
    # ─────────────────────────────────────────────────────────────────────
    if !is_pg
        @testset "SQLite refuses every piece" begin
            for f in (() -> M.Driver.objects.filter("surname__@search" => "senna").list(),
                      () -> M.Driver.objects.values("r" => SearchRank(SearchVector("surname"), "senna")).list(),
                      () -> M.Race.objects.values("h" => SearchHeadline("name", "prix")).list())
                e = _fts31_err(f)
                @test e isa PormG.BackendCapabilityError
                @test e !== nothing && occursin("PostgreSQL", sprint(showerror, e))
            end
        end
    else
        surnames = M.Driver.objects.values("driverid", "surname").list()
        race_names = M.Race.objects.values("raceid", "name").list()
        ids(rows, key) = Set(r[key] for r in rows)

        # ─────────────────────────────────────────────────────────────────────
        # The lookup, per search type
        # ─────────────────────────────────────────────────────────────────────
        @testset "@search finds exactly the rows whose words match" begin
            expected = Set(r["driverid"] for r in surnames if "senna" in _fts31_words(r["surname"]))
            @test !isempty(expected)
            got = M.Driver.objects.filter("surname__@search" => SearchQuery("senna"; config = "simple")).
                values("driverid").list()
            @test ids(got, "driverid") == expected
            # The bare string is the same query under the server's default config.
            @test ids(M.Driver.objects.filter("surname__@search" => "senna").values("driverid").list(), "driverid") == expected
        end

        @testset "phrase: the words, adjacent and in order" begin
            adjacent(ws) = any(i -> ws[i] == "grand" && ws[i + 1] == "prix", 1:length(ws) - 1)
            expected = Set(r["raceid"] for r in race_names if adjacent(_fts31_words(r["name"])))
            @test !isempty(expected)
            got = M.Race.objects.filter("name__@search" => SearchQuery("grand prix"; config = "simple", search_type = "phrase")).
                values("raceid").list()
            @test ids(got, "raceid") == expected
        end

        @testset "websearch: or" begin
            expected = Set(r["driverid"] for r in surnames if !isdisjoint(_fts31_words(r["surname"]), ("senna", "prost")))
            got = M.Driver.objects.filter("surname__@search" => SearchQuery("senna or prost"; config = "simple", search_type = "websearch")).
                values("driverid").list()
            @test ids(got, "driverid") == expected
            @test length(expected) >= 3
        end

        @testset "raw: a prefix match" begin
            expected = Set(r["driverid"] for r in surnames if any(w -> startswith(w, "sen"), _fts31_words(r["surname"])))
            got = M.Driver.objects.filter("surname__@search" => SearchQuery("sen:*"; config = "simple", search_type = "raw")).
                values("driverid").list()
            @test ids(got, "driverid") == expected
        end

        @testset "english: a plural matches its stem" begin
            circuits = M.Circuit.objects.values("circuitid", "name").list()
            expected = Set(r["circuitid"] for r in circuits if !isdisjoint(_fts31_words(r["name"]), ("circuit", "circuits")))
            @test !isempty(expected)
            got = M.Circuit.objects.filter("name__@search" => SearchQuery("circuits"; config = "english")).
                values("circuitid").list()
            @test ids(got, "circuitid") == expected
            # `simple` does not stem, so the plural finds nothing the fixture spells singular.
            plain = M.Circuit.objects.filter("name__@search" => SearchQuery("circuits"; config = "simple")).
                values("circuitid").list()
            @test length(plain) < length(expected)
        end

        @testset "a raw query the server cannot parse is a DatabaseError when it runs" begin
            e = _fts31_err(() -> M.Driver.objects.filter("surname__@search" => SearchQuery("a & | b"; search_type = "raw")).list())
            @test e isa PormG.DatabaseError
        end

        # ─────────────────────────────────────────────────────────────────────
        # SearchRank: a Float64 per row, filtered and ordered by its alias
        # ─────────────────────────────────────────────────────────────────────
        @testset "SearchRank ranks the full match first and reads as Float64" begin
            rows = M.Driver.objects.
                values("forename", "surname",
                       "rank" => SearchRank(SearchVector("forename", "surname"; config = "simple"),
                                            SearchQuery("ayrton senna or senna"; config = "simple", search_type = "websearch"))).
                filter("rank__@gte" => 0.01).
                order_by("-rank").
                list()
            @test length(rows) >= 2
            @test (rows[1]["forename"], rows[1]["surname"]) == ("Ayrton", "Senna")
            ranks = [r["rank"] for r in rows]
            @test all(r -> r isa Float64, ranks)
            @test issorted(ranks; rev = true)
            # Every Senna, and only them. For an AND of several words a row that misses them can rank
            # 1e-20 rather than 0, so the threshold is what separates them.
            @test Set(r["surname"] for r in rows) == Set(["Senna"])
            # The documented reason for the threshold: with a two-word query `> 0` keeps every row.
            loose = M.Driver.objects.
                values("driverid",
                       "rank" => SearchRank(SearchVector("forename", "surname"; config = "simple"), "ayrton senna")).
                filter("rank__@gt" => 0).
                list()
            @test length(loose) == length(surnames)
        end

        # ─────────────────────────────────────────────────────────────────────
        # Weights (#1021): the label each half of a summed vector carries is what `weights` scores
        # A word that is a forename for some drivers and a surname for others, labelled D in the
        # forename and A in the surname: weighing only A keeps the surname matches, weighing only D
        # the forename ones. Both sets come from tokenizing the same rows in Julia.
        # ─────────────────────────────────────────────────────────────────────
        @testset "weights score a summed vector by its labels" begin
            names = M.Driver.objects.values("driverid", "forename", "surname").list()
            both = intersect(Set(w for r in names for w in _fts31_words(r["forename"])),
                             Set(w for r in names for w in _fts31_words(r["surname"])))
            @test !isempty(both)
            word = minimum(both)
            vector = SearchVector("forename"; config = "simple", weight = "D") +
                     SearchVector("surname"; config = "simple", weight = "A")
            ranked(weights) = ids(M.Driver.objects.
                values("driverid", "rank" => SearchRank(vector, SearchQuery(word; config = "simple"); weights = weights)).
                filter("rank__@gte" => 0.01).
                list(), "driverid")
            by_surname = Set(r["driverid"] for r in names if word in _fts31_words(r["surname"]))
            by_forename = Set(r["driverid"] for r in names if word in _fts31_words(r["forename"]))
            @test ranked([0.0, 0.0, 0.0, 1.0]) == by_surname
            @test ranked([1.0, 0.0, 0.0, 0.0]) == by_forename
            @test by_surname != by_forename
        end

        # ─────────────────────────────────────────────────────────────────────
        # SearchHeadline: the markup, and options that survive PostgreSQL's option parser
        # ─────────────────────────────────────────────────────────────────────
        @testset "SearchHeadline marks the matched words" begin
            rows = M.Race.objects.
                filter("name__@search" => SearchQuery("grand prix"; config = "english"), "year" => 2009).
                values("name", "hl" => SearchHeadline("name", SearchQuery("grand prix"; config = "english");
                                                      start_sel = "<b>", stop_sel = "</b>")).
                list()
            @test !isempty(rows)
            for r in rows
                @test r["hl"] == replace(r["name"], "Grand Prix" => "<b>Grand</b> <b>Prix</b>")
            end
        end

        @testset "a headline option with a quote, a comma and backslashes comes back intact" begin
            # Two backslashes in a row are the case PostgreSQL's option parser collapses unless they are
            # escaped; one followed by a space it copies either way.
            for sel in ("<i class='x', y=\"z\" \\ >", "a\\\\b", "x\\")
                row = M.Race.objects.filter("raceid" => 1).
                    values("name", "hl" => SearchHeadline("name", SearchQuery("grand"; config = "english");
                                                          start_sel = sel, stop_sel = "</i>")).
                    list()[1]
                @test (sel, row["hl"]) == (sel, replace(row["name"], "Grand" => "$(sel)Grand</i>"))
            end
        end

        # ─────────────────────────────────────────────────────────────────────
        # The literal config is what lets an expression index serve the lookup
        # `enable_seqscan = off` makes the planner take any index that can answer the predicate, so
        # an index scan here means the lookup's expression matches the index's.
        # ─────────────────────────────────────────────────────────────────────
        # A CharField, as in the docs' example: the varchar column reaches `to_tsvector` through the
        # same implicit cast in the index and in the query, so the two expressions still match. The
        # index is declared through `Models.search_vector_expression` (#1021), the text the lookup
        # itself renders, rather than a hand-typed copy of it.
        @testset "a GIN index from search_vector_expression(\"body\") serves @search" begin
            drop() = try; PormG.ConnectionPool.fetch(pool, Dialect.drop_table(pool, FTS31_TABLE)); catch; end
            model = Models.Model(FTS31_TABLE;
                id   = Models.IDField(),
                body = Models.CharField(max_length = 200),
                indexes = [Models.Index(expressions = (Models.search_vector_expression("body"; config = "simple"),), method = "gin",
                                        name = "pormg_fts31_body_tsv")])
            model.connect_key = PORMG_DB_FOLDER
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                Symbol(FTS31_TABLE) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => model, :exist => false))
            settings = (s = PormG.Configuration.Settings(); s.change_db = true; s)
            drop()
            try
                plan = get_migration_plan(LiveTable[], schema, pool, settings; interactive = false)
                ordered, _ = _order_statements([plan[k] for k in keys(plan)])
                _, ddl_conn = _fts31_tx(pool, "BEGIN;")
                try
                    _execute_statements_pg(pool, ordered; conn = ddl_conn)
                    _fts31_tx(pool, "COMMIT;", conn = ddl_conn, release_conn = false)
                catch
                    _fts31_tx(pool, "ROLLBACK;", conn = ddl_conn, release_conn = false)
                    rethrow()
                finally
                    finalize_transaction_connection!(pool, ddl_conn)
                end
                for body in ("Ayrton Senna wins at Monaco", "Alain Prost wins at Imola", "Senna on pole")
                    model.objects.create("body" => body)
                end
                q = model.objects
                q.filter("body__@search" => SearchQuery("senna"; config = "simple")).values("id")
                @test length(q.list()) == 2
                insp = PormG.QueryBuilder.inspect_query(q)
                @test insp[:parameters] == Any["senna"]
                # Raw SQL by necessity: EXPLAIN and a planner setting are not ORM surface. The one
                # parameter is the constant above, written in as a literal for EXPLAIN.
                function plan_of(query)
                    sql = PormG.QueryBuilder.inspect_query(query)[:sql_text]
                    explain = "EXPLAIN " * replace(sql, "\$1::text" => "'senna'::text")
                    _, conn = _fts31_tx(pool, "BEGIN;")
                    try
                        return with_tx_context(pool, conn) do
                            PormG.ConnectionPool.fetch(pool, "SET LOCAL enable_seqscan = off")
                            join((PormG.ConnectionPool.fetch(pool, explain) |> DataFrame)[:, 1], "\n")
                        end
                    finally
                        _fts31_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
                        finalize_transaction_connection!(pool, conn)
                    end
                end
                @test occursin("pormg_fts31_body_tsv", plan_of(q))
                # The control: with no config the call is `to_tsvector(body)`, a different expression
                # (and not IMMUTABLE), so the same index cannot serve it. Without this, the assertion
                # above would also pass for a planner that ignored the predicate's shape.
                bare = model.objects
                bare.filter("body__@search" => "senna").values("id")
                @test !occursin("pormg_fts31_body_tsv", plan_of(bare))
            finally
                drop()
            end
        end
    end
end
