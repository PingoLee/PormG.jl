"""
Unit coverage for PostgreSQL full-text search (#31, part 1): the `@search` lookup and `SearchQuery`,
`SearchVector`, `SearchRank` and `SearchHeadline`. Part 2 (#1021), in its own outer testset at the end:
`Models.search_vector_expression`, the index text that cannot drift from the query's.

PostgreSQL only. SQLite's FTS5 is a separate index table with its own query syntax and ranking, so
every piece raises `BackendCapabilityError` there when the query is built rather than being emulated.
Pinned here, with mock connections and no database:

  1. **The SQL**, per search type, with the config a validated literal (`'simple'::regconfig`) and the
     search text bound, and every `\$N` in text order.
  2. **The config cannot carry SQL.** Anything that is not a plain or schema-qualified name raises
     `InvalidValueError`, at the constructor and again at render (the node's kwargs are mutable).
  3. **Operands are not values.** A `SearchVector` or `SearchQuery` projected, compared, wrapped or
     put on the right of another lookup is refused, as is `@search` on a non-text column or an alias.
  4. **SQLite refuses**, naming the feature, never as a `MethodError`.

The live results — stemming, ranking order, headline markup, and the index the literal config exists
for — are in `test/integration/test_full_text_search.jl`.

julia --project=test/integration test/unit/test_full_text_search.jl
"""

using Test
using PormG
using PormG.Models
import PormG.QueryBuilder: inspect_query
using PormG.Functions: SearchQuery, SearchVector, SearchRank, SearchHeadline, Lower, Concat, Coalesce,
                       Value, When, Case

include("helper_marker_alignment.jl")

struct _MockPgFts31 <: PormG.PormGPostgres end
struct _MockSlFts31 <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::_MockSlFts31) = 3045000
const _FTS_PG = _MockPgFts31()
const _FTS_SL = _MockSlFts31()

PormG.config["fts31"] = PormG.Configuration.Settings(connections = _FTS_PG, change_data = true,
                                                     db_def_folder = "fts31")

# Drivers and their results, and races: a text column on the base model, one reached through a
# ForeignKey, and a column that is not text for every type guard.
module FtsModels31
import PormG
import PormG.Models
Driver = Models.Model("driver",
  driverid = Models.IDField(),
  forename = Models.CharField(max_length = 255),
  surname  = Models.CharField(max_length = 255),
  number   = Models.IntegerField(null = true),
)
Race = Models.Model("race",
  raceid = Models.IDField(),
  name   = Models.TextField(),
  year   = Models.IntegerField(),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  driverid = Models.ForeignKey("Driver"),
  points   = Models.FloatField(),
)
# #1021: a race report with its document stored, and a ForeignKey to reach it through.
Report = Models.Model("report",
  reportid = Models.IDField(),
  raceid   = Models.ForeignKey("Race"),
  title    = Models.CharField(max_length = 200),
  body     = Models.TextField(),
  search   = Models.SearchVectorField(null = true),
)
PormG.Models.set_models(@__MODULE__, "fts31")
end
const _F = FtsModels31

_plain31(msg::AbstractString) = replace(msg, r"\e\[[0-9;]*m" => "")
_err31(f) = try f(); nothing catch e; e end
_msg31(f) = (e = _err31(f); e === nothing ? "" : _plain31(sprint(showerror, e)))

# Build on `model`, with `filter(pairs...)` and `values(vals...)`, and inspect it on `conn`.
function _q31(pairs...; vals = Any["driverid"], model = _F.Driver, conn = _FTS_PG)
  q = model.objects
  isempty(pairs) || q.filter(pairs...)
  q.values(vals...)
  return inspect_query(q; connection = conn)
end

# PostgreSQL numbers its markers as it renders, so the parameters must come back in text order with
# the markers ascending from $1 — the oracle a reordered render would break.
function _assert_pg_text_order31(insp::Dict, expected::Vector)
  idx = [parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", insp[:sql_text])]
  @test idx == collect(1:length(idx))
  @test _pg_text_order(insp) == expected
  assert_marker_count(insp, :postgres)
end

@testset "Full-text search (#31)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # The @search lookup
  # A bare string is a plain query with no config, as in Django; a SearchQuery's config parses the
  # column too, so both sides agree on how words are split and stemmed.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "@search with the text renders to_tsvector @@ plainto_tsquery" begin
    r = _q31("surname__@search" => "senna")
    @test occursin("WHERE to_tsvector(\"Tb\".\"surname\") @@ plainto_tsquery(\$1::text)", r[:sql_text])
    @test r[:parameters] == Any["senna"]
  end

  @testset "@search with a SearchQuery parses the column with the query's config" begin
    r = _q31("surname__@search" => SearchQuery("senna"; config = "simple"))
    @test occursin("WHERE to_tsvector('simple'::regconfig, \"Tb\".\"surname\") @@ " *
                   "plainto_tsquery('simple'::regconfig, \$1::text)", r[:sql_text])
    @test r[:parameters] == Any["senna"]
  end

  @testset "each search_type renders its parser" begin
    for (st, fn) in (("plain", "plainto_tsquery"), ("phrase", "phraseto_tsquery"),
                     ("websearch", "websearch_to_tsquery"), ("raw", "to_tsquery"))
      r = _q31("name__@search" => SearchQuery("grand prix"; search_type = st); model = _F.Race, vals = Any["raceid"])
      @test occursin("@@ $(fn)(\$1::text)", r[:sql_text])
      @test r[:parameters] == Any["grand prix"]
    end
  end

  @testset "a schema-qualified config and a TextField column" begin
    r = _q31("name__@search" => SearchQuery("prix"; config = "pg_catalog.english");
             model = _F.Race, vals = Any["raceid"])
    @test occursin("to_tsvector('pg_catalog.english'::regconfig, \"Tb\".\"name\")", r[:sql_text])
  end

  @testset "@search on a column reached through a ForeignKey" begin
    r = _q31("driverid__surname__@search" => SearchQuery("senna"; config = "simple");
             model = _F.Result, vals = Any["resultid"])
    @test occursin(r"to_tsvector\('simple'::regconfig, \"Tb_\d+\"\.\"surname\"\) @@ plainto_tsquery\('simple'::regconfig, \$1::text\)",
                   r[:sql_text])
    @test occursin("JOIN", r[:sql_text])
  end

  @testset "the text binds verbatim: no LIKE decoration, no escaping" begin
    text = "50% o'brien \\ _x"
    r = _q31("surname__@search" => text)
    @test r[:parameters] == Any[text]
    @test !occursin("ESCAPE", r[:sql_text])
  end

  @testset "@search composes inside Q, Qor and a When condition" begin
    r = _q31(PormG.Q("surname__@search" => "senna", "forename" => "Ayrton"))
    @test occursin("to_tsvector(\"Tb\".\"surname\") @@ plainto_tsquery(\$1::text)", r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "Ayrton"])
    r = _q31(PormG.Qor("surname__@search" => "senna", "surname__@search" => "prost"))
    @test occursin(" OR ", r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "prost"])
    r = _q31(; vals = Any["driverid", "is_senna" => Case([When("surname__@search" => "senna", then = 1)], default = 0)])
    @test occursin("WHEN to_tsvector(\"Tb\".\"surname\") @@ plainto_tsquery(\$1::text) THEN", r[:sql_text])
  end

  @testset "a reused SearchQuery renders identically in two queries" begin
    q = SearchQuery("senna"; config = "simple", search_type = "websearch")
    a = _q31("surname__@search" => q)
    b = _q31("forename__@search" => q)
    @test replace(a[:sql_text], "surname" => "X") == replace(b[:sql_text], "forename" => "X")
    @test a[:parameters] == b[:parameters] == Any["senna"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SearchVector and SearchRank
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchRank over a SearchVector: SQL, Float64 cast, and the alias filter in text order" begin
    rank = SearchRank(SearchVector("forename", "surname"; config = "simple"),
                      SearchQuery("ayrton senna"; config = "simple"))
    q = _F.Driver.objects
    q.values("forename", "rank" => rank).filter("rank__@gt" => 0).order_by("-rank")
    r = inspect_query(q; connection = _FTS_PG)
    vec = "to_tsvector('simple'::regconfig, COALESCE((\"Tb\".\"forename\")::text, '') || ' ' || " *
          "COALESCE((\"Tb\".\"surname\")::text, ''))"
    @test occursin("(ts_rank($(vec), plainto_tsquery('simple'::regconfig, \$1::text)))::double precision as \"rank\"",
                   r[:sql_text])
    # A row alias is filtered in WHERE by rendering the expression again, so the text binds twice.
    @test occursin("WHERE (ts_rank($(vec), plainto_tsquery('simple'::regconfig, \$2::text)))::double precision > \$3",
                   r[:sql_text])
    @test occursin("ORDER BY \"rank\" DESC", r[:sql_text])
    _assert_pg_text_order31(r, Any["ayrton senna", "ayrton senna", 0])
  end

  @testset "a one-field SearchVector, and a string query borrows the vector's config" begin
    r = _q31(; vals = Any["driverid", "r" => SearchRank(SearchVector("surname"; config = "english"), "senna")])
    @test occursin("ts_rank(to_tsvector('english'::regconfig, COALESCE((\"Tb\".\"surname\")::text, '')), " *
                   "plainto_tsquery('english'::regconfig, \$1::text))", r[:sql_text])
  end

  @testset "cover_density and normalization" begin
    r = _q31(; vals = Any["driverid", "r" => SearchRank(SearchVector("surname"), "senna";
                                                         cover_density = true, normalization = 32)])
    @test occursin("(ts_rank_cd(to_tsvector(COALESCE((\"Tb\".\"surname\")::text, '')), plainto_tsquery(\$1::text), 32))::double precision",
                   r[:sql_text])
    for n in (-1, 64, 1.5, "1")
      @test _err31(() -> SearchRank(SearchVector("surname"), "x"; normalization = n)) isa InvalidValueError
    end
  end

  @testset "SearchRank compared directly in a filter" begin
    r = _q31(SearchRank(SearchVector("surname"; config = "simple"), "senna") > 0.5)
    @test occursin("WHERE ((ts_rank(", r[:sql_text])
    @test occursin("))::double precision > \$2::double precision)", r[:sql_text])
    # An `F`-style comparison binds its number as numeric text, as it does for every other expression.
    _assert_pg_text_order31(r, Any["senna", "0.5"])
  end

  @testset "SearchRank's operands: a SearchVector, and a String or SearchQuery" begin
    # #1021: a String is the path of a SearchVectorField column, so a text column's path is refused
    # where it resolves — at render — rather than when the rank is built.
    @test _err31(() -> _q31(; vals = Any["driverid", "r" => SearchRank("surname", "senna")])) isa QueryBuildError
    @test _err31(() -> SearchRank(1, "senna")) isa QueryBuildError
    @test _err31(() -> SearchRank(SearchVector("surname"), SearchVector("forename"))) isa QueryBuildError
    @test _err31(() -> SearchRank(SearchVector("surname"), 1)) isa QueryBuildError
    @test _err31(() -> SearchVector()) isa QueryBuildError
    @test _err31(() -> SearchVector(1)) isa QueryBuildError
    @test _err31(() -> SearchVector(SearchQuery("x"))) isa QueryBuildError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SearchHeadline
  # The options are one bound string, in PostgreSQL's names and a fixed order, with `'` doubled.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchHeadline: config from the query, options bound after it" begin
    q = _F.Race.objects
    q.filter("name__@search" => SearchQuery("grand prix"; config = "english")).
      values("year", "hl" => SearchHeadline("name", SearchQuery("grand prix"; config = "english");
                                            start_sel = "<b>", stop_sel = "</b>"))
    r = inspect_query(q; connection = _FTS_PG)
    @test occursin("ts_headline('english'::regconfig, (\"Tb\".\"name\")::text, " *
                   "plainto_tsquery('english'::regconfig, \$1::text), \$2::text) as \"hl\"", r[:sql_text])
    _assert_pg_text_order31(r, Any["grand prix", "StartSel='<b>', StopSel='</b>'", "grand prix"])
  end

  @testset "SearchHeadline: every option, in order, with quotes and backslashes doubled" begin
    h = SearchHeadline("name", "prix"; config = "simple", start_sel = "<b class='x'>", stop_sel = "</b\\\\>",
                       max_words = 20, min_words = 5, short_word = 2, highlight_all = true,
                       max_fragments = 3, fragment_delimiter = " … , ")
    r = _q31(; model = _F.Race, vals = Any["raceid", "hl" => h])
    @test occursin("ts_headline('simple'::regconfig, (\"Tb\".\"name\")::text, plainto_tsquery('simple'::regconfig, \$1::text), \$2::text)",
                   r[:sql_text])
    @test r[:parameters] == Any["prix",
      "StartSel='<b class=''x''>', StopSel='</b\\\\\\\\>', MaxWords=20, MinWords=5, ShortWord=2, " *
      "HighlightAll=true, MaxFragments=3, FragmentDelimiter=' … , '"]
  end

  @testset "SearchHeadline with no options binds only the query" begin
    r = _q31(; model = _F.Race, vals = Any["raceid", "hl" => SearchHeadline("name", "prix")])
    @test occursin("ts_headline((\"Tb\".\"name\")::text, plainto_tsquery(\$1::text)) as \"hl\"", r[:sql_text])
    @test r[:parameters] == Any["prix"]
  end

  @testset "SearchHeadline refuses a bad option when it is built" begin
    for kw in ((; start_sel = 1), (; start_sel = "a\0b"), (; highlight_all = 1), (; max_words = -1),
               (; max_words = true), (; max_words = 10, min_words = 10), (; min_words = 40),
               (; max_words = 0), (; short_word = 1.5), (; max_words = typemax(UInt64)),
               (; max_fragments = 2^40))
      @test _err31(() -> SearchHeadline("name", "prix"; kw...)) isa InvalidValueError
    end
    # HighlightAll ignores MinWords/MaxWords, so PostgreSQL does not check them under it, and neither
    # does PormG.
    @test _err31(() -> SearchHeadline("name", "prix"; highlight_all = true, max_words = 5)) === nothing
    @test _err31(() -> SearchHeadline("name", "prix"; highlight_all = false, max_words = 5)) isa InvalidValueError
    @test _err31(() -> SearchHeadline(SearchVector("name"), "prix")) isa QueryBuildError
    @test _err31(() -> SearchHeadline(1, "prix")) isa QueryBuildError
    @test _err31(() -> SearchHeadline("name", 1)) isa QueryBuildError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The config is a literal, so it must be a name and nothing else
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a config that is not a name raises InvalidValueError" begin
    for bad in ("english'--", "", "a.b.c", "1x", "english\n", "eng lish", "english;", "\"english\"", :english, 1)
      @test _err31(() -> SearchQuery("x"; config = bad)) isa InvalidValueError
      @test _err31(() -> SearchVector("surname"; config = bad)) isa InvalidValueError
      @test _err31(() -> SearchHeadline("surname", "x"; config = bad)) isa InvalidValueError
    end
    # The refusal never prints what it refused (#971).
    @test !occursin("english'--", _msg31(() -> SearchQuery("x"; config = "english'--")))
    for good in ("english", "simple", "pg_catalog.portuguese", "_my_cfg2")
      @test _err31(() -> SearchQuery("x"; config = good)) === nothing
    end
  end

  @testset "a config written into the node after construction is checked again at render" begin
    q = SearchQuery("senna"; config = "simple")
    q.kwargs["config"] = "simple'::regconfig, 'x"
    @test _err31(() -> _q31("surname__@search" => q)) isa InvalidValueError
    v = SearchVector("surname")
    v.kwargs["config"] = "x'); DROP TABLE driver; --"
    @test _err31(() -> _q31(; vals = Any["driverid", "r" => SearchRank(v, "senna")])) isa InvalidValueError
    rank = SearchRank(SearchVector("surname"), "senna")
    rank.kwargs["normalization"] = "1); DROP TABLE driver; --"
    @test _err31(() -> _q31(; vals = Any["driverid", "r" => rank])) isa InvalidValueError
  end

  @testset "SearchQuery refuses a bad search_type, a NUL and a non-string text" begin
    @test _err31(() -> SearchQuery("x"; search_type = "fuzzy")) isa InvalidValueError
    @test _err31(() -> SearchQuery("x"; search_type = :plain)) isa InvalidValueError
    @test _err31(() -> SearchRank(SearchVector("surname"), "x"; cover_density = 1)) isa InvalidValueError
    @test _err31(() -> SearchQuery("a\0b")) isa InvalidValueError
    @test _err31(() -> SearchQuery(1)) isa QueryBuildError
    @test _err31(() -> SearchQuery(nothing)) isa QueryBuildError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Operands are not values
  # Every spelling that would put a tsvector or a tsquery where a value goes is refused when the query
  # is built, so none reaches the server as SQL it would reject or read back as text.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a SearchVector or SearchQuery used as a value raises QueryBuildError" begin
    sv, sq = SearchVector("surname"), SearchQuery("senna")
    spellings = (
      () -> _q31(; vals = Any["driverid", "q" => sq]),
      () -> _q31(; vals = Any["driverid", "x" => Lower(sq)]),
      () -> _q31(; vals = Any["driverid", "x" => Coalesce(sv, Value(""))]),
      () -> _q31(; vals = Any["driverid", "x" => Concat("surname", sq)]),
      () -> _q31(sq == "x"),
      () -> _q31(; vals = Any["driverid", "x" => SearchHeadline(Lower(sq), "x")]),
    )
    for f in spellings
      @test _err31(f) isa QueryBuildError
    end
  end

  @testset "a SearchVector or SearchQuery on the right of another lookup raises FilterError" begin
    for pair in ("surname" => SearchQuery("senna"), "surname__@icontains" => SearchQuery("senna"),
                 "surname__@search" => SearchVector("forename"), "number__@gt" => SearchVector("surname"))
      e = _err31(() -> _q31(pair))
      @test e isa FilterError
      @test occursin("@search", _plain31(sprint(showerror, e)))
    end
  end

  @testset "@search takes the text or a SearchQuery, and nothing else" begin
    # Refused at parse, in the lookup's own words: the render-time fail-safe raises `FilterError` too,
    # so the type alone cannot tell the two apart.
    for value in (1, 1.5, true, PormG.F("forename"), Lower("forename"))
      e = _err31(() -> _q31("surname__@search" => value))
      @test e isa FilterError
      @test occursin("takes the search text (a String) or a SearchQuery", _plain31(sprint(showerror, e)))
    end
    @test occursin("got a column expression", _msg31(() -> _q31("surname__@search" => PormG.F("forename"))))
    @test _err31(() -> _q31("surname__@search" => ["senna"])) isa FilterError
  end

  @testset "@search needs a text column, not a number or a projection alias" begin
    msg = _msg31(() -> _q31("number__@search" => "1"))
    @test occursin("@search lookup searches a text column", msg)
    @test occursin("number", msg)
    @test _err31(() -> _q31("number__@search" => "1")) isa FilterError
    q = _F.Driver.objects
    q.values("driverid", "n" => Lower("surname")).filter("n__@search" => "senna")
    @test _err31(() -> inspect_query(q; connection = _FTS_PG)) isa FilterError
  end

  @testset "the missing-@ hint names @search" begin
    msg = _msg31(() -> _q31("surname__search" => "senna"))
    @test occursin("'__@search'", msg)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite refuses at build, naming the feature
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite: every piece raises BackendCapabilityError, never a MethodError" begin
    cases = (
      ("@search lookup", () -> _q31("surname__@search" => "senna"; conn = _FTS_SL)),
      ("@search lookup", () -> _q31("surname__@search" => SearchQuery("senna"; config = "simple"); conn = _FTS_SL)),
      ("SearchRank", () -> _q31(; vals = Any["driverid", "r" => SearchRank(SearchVector("surname"), "senna")], conn = _FTS_SL)),
      ("SearchHeadline", () -> _q31(; model = _F.Race, vals = Any["raceid", "h" => SearchHeadline("name", "prix")], conn = _FTS_SL)),
      ("SearchVector", () -> _q31(; vals = Any["driverid", "v" => SearchVector("surname")], conn = _FTS_SL)),
    )
    for (what, f) in cases
      e = _err31(f)
      @test e isa BackendCapabilityError
      msg = _plain31(sprint(showerror, e))
      @test occursin(what, msg)
      @test occursin("PostgreSQL", msg)
    end
    # The engine is refused before the column is checked: on SQLite a non-text column still names
    # PostgreSQL, the remedy that applies whatever the column.
    @test _err31(() -> _q31("number__@search" => "1"; conn = _FTS_SL)) isa BackendCapabilityError
    # The Dialect arms are the backstop for a node that reaches them some other way.
    for f in (PormG.Dialect.SEARCH_VECTOR, PormG.Dialect.SEARCH_QUERY, PormG.Dialect.SEARCH_RANK,
              PormG.Dialect.SEARCH_HEADLINE)
      @test _err31(() -> f(Any["x"], Dict{String,Any}(), _FTS_SL)) isa BackendCapabilityError
    end
    @test _err31(() -> PormG.Dialect.search(_FTS_SL, "a", "b")) isa BackendCapabilityError
    @test _err31(() -> PormG.Dialect.ts_vector_sql("a", nothing, _FTS_SL)) isa BackendCapabilityError
  end
end

# ═════════════════════════════════════════════════════════════════════════════
# Part 2 (#1021)
# ═════════════════════════════════════════════════════════════════════════════

# The `to_tsvector(…)` a rendered query holds, with the table qualification dropped — the text an
# expression index must equal to serve it. `"Tb"."surname"` is `"surname"` to the index, which names
# the column of its own table.
function _tsvector_of1021(sql::AbstractString)
  start = findfirst("to_tsvector(", sql)
  start === nothing && return nothing
  depth, i = 0, first(start)
  for j in first(start):lastindex(sql)
    sql[j] == '(' && (depth += 1)
    sql[j] == ')' && (depth -= 1; depth == 0 && (i = j; break))
  end
  return replace(sql[first(start):i], r"\"Tb(?:_\d+)?\"\." => "")
end

@testset "Full-text search, part 2 (#1021)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Index helper: search_vector_expression is the query's own to_tsvector text
  # One column is the @search lookup's expression, several are SearchVector's. Both come from the
  # Kernel function the query is rendered with, so the index and the query cannot drift apart — a
  # config or cast that differs is still a valid index, just one PostgreSQL never uses (#1021).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "search_vector_expression equals the rendered to_tsvector, per config and shape" begin
    for config in (nothing, "simple", "pg_catalog.english")
      # One column: the lookup's bare form, parsed with the query's config.
      r = _q31("surname__@search" => SearchQuery("senna"; config = config))
      @test Models.search_vector_expression("surname"; config = config) == _tsvector_of1021(r[:sql_text])
      # Several columns: SearchVector's COALESCE'd document, as SearchRank renders it.
      vec = SearchVector("forename", "surname"; config = config)
      r = _q31(; vals = Any["driverid", "r" => SearchRank(vec, SearchQuery("senna"; config = config))])
      @test Models.search_vector_expression("forename", "surname"; config = config) ==
            _tsvector_of1021(r[:sql_text])
    end
    @test Models.search_vector_expression("surname"; config = "simple") ==
          "to_tsvector('simple'::regconfig, \"surname\")"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Index helper: what it produces is a declarable GIN index, and its inputs are checked
  # The text has to pass Index's own expression check (it is SQL a migration will run), and an input
  # the query would refuse — a config that is not a name — is refused here too, with the same type.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "search_vector_expression declares an Index; bad columns and configs are refused" begin
    expr = Models.search_vector_expression("forename", "surname"; config = "simple")
    idx = Models.Index(expressions = (expr,), method = "gin", name = "driver_name_tsv")
    @test idx.expressions == [expr]
    # A config the lookup refuses is refused with the lookup's error type.
    @test _err31(() -> Models.search_vector_expression("surname"; config = "simple'); DROP TABLE x; --")) isa InvalidValueError
    # A column is an identifier: nothing the helper would have to escape inside its quotes.
    for bad in ("sur\"name", "surname)", "a b", "", "1abc", "\"surname\"")
      @test _err31(() -> Models.search_vector_expression(bad)) isa ModelDefinitionError
    end
    @test _err31(() -> Models.search_vector_expression()) isa ModelDefinitionError
    @test _err31(() -> Models.search_vector_expression(:surname)) isa ModelDefinitionError
    # The function is the published spelling: `Models.search_vector_expression`.
    @test Base.ispublic(Models, :search_vector_expression)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Weights: SearchVector(…; weight) labels the document with setweight
  # The label is a literal like the config (an index matches by text), checked against A–D. The
  # index helper renders the same text for the same weight, through the same Kernel function.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchVector(…; weight) renders setweight, and the index helper agrees" begin
    vec = SearchVector("forename", "surname"; config = "simple", weight = "A")
    r = _q31(; vals = Any["driverid", "r" => SearchRank(vec, "senna")])
    @test occursin("ts_rank(setweight(to_tsvector('simple'::regconfig, COALESCE((\"Tb\".\"forename\")::text, '') " *
                   "|| ' ' || COALESCE((\"Tb\".\"surname\")::text, '')), 'A'), plainto_tsquery(", r[:sql_text])
    @test r[:parameters] == Any["senna"]
    # The helper wraps the same document in the same setweight.
    rendered = match(r"setweight\(.*?, 'A'\)", r[:sql_text]).match
    @test Models.search_vector_expression("forename", "surname"; config = "simple", weight = "A") ==
          replace(rendered, r"\"Tb\"\." => "")
    # One weighted column is SearchVector's document too: the lookup has no weight to match.
    @test Models.search_vector_expression("surname"; weight = "B") ==
          "setweight(to_tsvector(COALESCE((\"surname\")::text, '')), 'B')"
  end

  @testset "a weight other than A, B, C or D is refused, at construction and at render" begin
    for bad in ("E", "a", "AB", "A'); SELECT 1; --", 1, :A)
      @test _err31(() -> SearchVector("surname"; weight = bad)) isa InvalidValueError
      @test _err31(() -> Models.search_vector_expression("surname"; weight = bad)) isa InvalidValueError
    end
    # The kwargs Dict is mutable, so the renderer checks the label again rather than printing it.
    vec = SearchVector("surname"; weight = "A")
    vec.kwargs["weight"] = "A'); --"
    @test _err31(() -> _q31(; vals = Any["driverid", "r" => SearchRank(vec, "x")])) isa InvalidValueError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Weights: v1 + v2 is one document, each half with its own config and weight
  # Django's CombinedSearchVector. It renders `(v1 || v2)` and binds nothing of its own, so the only
  # parameters are the operands' own, in text order, before the query's text.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchVector + SearchVector renders the two documents concatenated" begin
    vec = SearchVector("forename"; config = "simple", weight = "A") +
          SearchVector("surname"; config = "simple", weight = "B")
    r = _q31(; vals = Any["driverid", "r" => SearchRank(vec, "senna")])
    @test occursin("ts_rank((setweight(to_tsvector('simple'::regconfig, COALESCE((\"Tb\".\"forename\")::text, '')), 'A') || " *
                   "setweight(to_tsvector('simple'::regconfig, COALESCE((\"Tb\".\"surname\")::text, '')), 'B')), " *
                   "plainto_tsquery('simple'::regconfig, \$1::text))", r[:sql_text])
    _assert_pg_text_order31(r, Any["senna"])
    # Three vectors nest left to right, and an expression operand still binds in text order.
    vec3 = SearchVector("forename") + SearchVector(Concat("surname", Value(" jr"))) + SearchVector("number")
    r = _q31(; vals = Any["driverid", "r" => SearchRank(vec3, "senna")])
    @test occursin("ts_rank(((to_tsvector(", r[:sql_text])
    _assert_pg_text_order31(r, Any[" jr", "senna"])
  end

  @testset "a sum of vectors with different configs needs a SearchQuery, not a String" begin
    mixed = SearchVector("forename"; config = "simple") + SearchVector("surname"; config = "english")
    @test _err31(() -> SearchRank(mixed, "senna")) isa QueryBuildError
    @test occursin("different configs", _msg31(() -> SearchRank(mixed, "senna")))
    # A config and none are different configs too: the text would be parsed one way or the other.
    @test _err31(() -> SearchRank(SearchVector("forename") + SearchVector("surname"; config = "simple"), "x")) isa QueryBuildError
    # An explicit query names its own config, so nothing is guessed.
    r = _q31(; vals = Any["driverid", "r" => SearchRank(mixed, SearchQuery("senna"; config = "simple"))])
    @test occursin("plainto_tsquery('simple'::regconfig, \$1::text)", r[:sql_text])
    # Agreeing configs carry over to a String query, as for a single vector — and stay mixed once
    # mixed, however the sum is extended.
    same = SearchVector("forename"; config = "simple") + SearchVector("surname"; config = "simple")
    r = _q31(; vals = Any["driverid", "r" => SearchRank(same, "senna")])
    @test occursin("plainto_tsquery('simple'::regconfig, \$1::text)", r[:sql_text])
    @test _err31(() -> SearchRank(mixed + SearchVector("number"; config = "simple"), "x")) isa QueryBuildError
  end

  @testset "a SearchVector adds only to a SearchVector" begin
    vec = SearchVector("surname")
    for f in (() -> vec + 1, () -> 1 + vec, () -> vec + 1.5, () -> vec + "forename",
              () -> vec + SearchQuery("x"), () -> SearchQuery("x") + vec, () -> vec + Lower("forename"),
              () -> PormG.Functions.Sum("number") + vec)
      e = _err31(f)
      @test e isa QueryBuildError
      @test occursin("adds only to another SearchVector", _plain31(sprint(showerror, e)))
    end
    # A vector inside a SearchVector is still refused, and now names the sum as the way to join two.
    @test occursin("add them", _msg31(() -> SearchVector(vec)))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Weights: SearchRank(…; weights) prints PostgreSQL's float4[] in D, C, B, A order
  # Printed like normalization — four finite numbers in 0..1, so the literal holds only digits, `.`,
  # `e` and `-` — and re-checked at render because the node's kwargs are mutable.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchRank(…; weights) renders the weights array first" begin
    vec = SearchVector("surname"; config = "simple", weight = "A")
    r = _q31(; vals = Any["driverid", "r" => SearchRank(vec, "senna"; weights = [0, 0.25, 0.5, 1], normalization = 2)])
    @test occursin("(ts_rank('{0.0,0.25,0.5,1.0}'::float4[], setweight(", r[:sql_text])
    @test occursin("plainto_tsquery('simple'::regconfig, \$1::text), 2))::double precision", r[:sql_text])
    @test r[:parameters] == Any["senna"]
    r = _q31(; vals = Any["driverid", "r" => SearchRank(vec, "senna"; weights = (0.1, 0.2, 0.4, 1.0), cover_density = true)])
    @test occursin("(ts_rank_cd('{0.1,0.2,0.4,1.0}'::float4[], ", r[:sql_text])
  end

  @testset "weights other than four numbers in 0..1 are refused, at construction and at render" begin
    vec = SearchVector("surname")
    for bad in ([0.1, 0.2, 0.4], [0.1, 0.2, 0.4, 1.0, 1.0], [0.1, 0.2, 0.4, 1.5], [-0.1, 0.2, 0.4, 1.0],
                [NaN, 0.2, 0.4, 1.0], [Inf, 0.2, 0.4, 1.0], [true, false, true, true], ["0.1", "0.2", "0.4", "1"],
                0.5, "{0.1,0.2,0.4,1.0}")
      @test _err31(() -> SearchRank(vec, "x"; weights = bad)) isa InvalidValueError
    end
    rank = SearchRank(vec, "x"; weights = [0.1, 0.2, 0.4, 1.0])
    rank.kwargs["weights"] = ["1}'::float4[], (SELECT 1)) --"]
    @test _err31(() -> _q31(; vals = Any["driverid", "r" => rank])) isa InvalidValueError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Query combinators: &, | and ~ are tsquery's &&, || and !!
  # Each leaf keeps its own parser and binds its own text, so the parameters come back in text order;
  # the combination is parenthesized, so nesting keeps the grouping it was written with.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchQuery & | ~ render tsquery's operators, leaves bound in text order" begin
    a = SearchQuery("senna"; config = "simple")
    b = SearchQuery("prost"; config = "simple", search_type = "websearch")
    r = _q31("surname__@search" => a | b)
    @test occursin("WHERE to_tsvector('simple'::regconfig, \"Tb\".\"surname\") @@ " *
                   "(plainto_tsquery('simple'::regconfig, \$1::text) || websearch_to_tsquery('simple'::regconfig, \$2::text))",
                   r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "prost"])
    r = _q31("surname__@search" => a & ~b)
    @test occursin("@@ (plainto_tsquery('simple'::regconfig, \$1::text) && (!!websearch_to_tsquery('simple'::regconfig, \$2::text)))",
                   r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "prost"])
    # Nesting: ~(a & b) | c keeps its parentheses, and the texts still bind left to right.
    c = SearchQuery("hill"; config = "simple")
    r = _q31("surname__@search" => ~(a & b) | c)
    @test occursin("@@ ((!!(plainto_tsquery('simple'::regconfig, \$1::text) && websearch_to_tsquery('simple'::regconfig, \$2::text))) " *
                   "|| plainto_tsquery('simple'::regconfig, \$3::text))", r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "prost", "hill"])
  end

  @testset "a combined query works wherever one query does" begin
    q = SearchQuery("senna"; config = "simple") | SearchQuery("prost"; config = "simple")
    # The lookup parses the column with the combination's (shared) config.
    @test occursin("to_tsvector('simple'::regconfig, \"Tb\".\"surname\") @@ (",
                   _q31("surname__@search" => q)[:sql_text])
    # SearchRank, with the alias filter re-rendering it: four texts, in text order.
    r = _q31("r__@gte" => 0.01; vals = Any["driverid", "r" => SearchRank(SearchVector("surname"; config = "simple"), q)])
    @test occursin("ts_rank(to_tsvector('simple'::regconfig, COALESCE((\"Tb\".\"surname\")::text, '')), " *
                   "(plainto_tsquery('simple'::regconfig, \$1::text) || plainto_tsquery('simple'::regconfig, \$2::text)))",
                   r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "prost", "senna", "prost", "0.01"])
    # SearchHeadline takes the combination's config for the document.
    r = _q31(; model = _F.Race, vals = Any["raceid", "h" => SearchHeadline("name", q)])
    @test occursin("ts_headline('simple'::regconfig, (\"Tb\".\"name\")::text, (plainto_tsquery(", r[:sql_text])
    # Inside Q, beside another predicate.
    r = _q31(PormG.Q("surname__@search" => ~SearchQuery("senna"), "forename" => "Bruno"))
    @test occursin("@@ (!!plainto_tsquery(\$1::text))", r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "Bruno"])
  end

  @testset "a SearchQuery combines only with a SearchQuery of the same config" begin
    q = SearchQuery("senna")
    for f in (() -> q & 1, () -> 1 & q, () -> q | 2, () -> 2 | q, () -> q & SearchVector("surname"),
              () -> SearchVector("surname") | q, () -> ~SearchVector("surname"), () -> q & Lower("surname"),
              () -> PormG.F("driverid") & q)
      e = _err31(f)
      @test e isa QueryBuildError
      @test occursin("combines only with another SearchQuery", _plain31(sprint(showerror, e)))
    end
    # Two configs, or a config and none, have no single config for the lookup's column.
    for (x, y) in ((SearchQuery("a"; config = "simple"), SearchQuery("b"; config = "english")),
                   (SearchQuery("a"; config = "simple"), SearchQuery("b")))
      for f in (() -> x & y, () -> x | y)
        e = _err31(f)
        @test e isa QueryBuildError
        @test occursin("must share one config", _plain31(sprint(showerror, e)))
      end
    end
    # The integer bitwise operators are untouched.
    r = _q31(; vals = Any["driverid", "m" => PormG.F("number") & 3])
    @test occursin("&", r[:sql_text]) && !occursin("&&", r[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # @search on a projection alias: values("doc" => SearchVector(…)).filter("doc__@search" => q)
  # Django's multi-column search. The vector is projected (its tsvector text) and rendered again in
  # WHERE, then the query: `<vector> @@ <query>`. A String query takes the vector's config.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a SearchVector alias is projected, and @search on it renders vector @@ query" begin
    vec = SearchVector("forename", "surname"; config = "simple")
    r = _q31("doc__@search" => "senna"; vals = Any["driverid", "doc" => vec])
    doc = "to_tsvector('simple'::regconfig, COALESCE((\"Tb\".\"forename\")::text, '') || ' ' || " *
          "COALESCE((\"Tb\".\"surname\")::text, ''))"
    @test occursin("$(doc) as \"doc\"", r[:sql_text])
    @test occursin("WHERE $(doc) @@ plainto_tsquery('simple'::regconfig, \$1::text)", r[:sql_text])
    _assert_pg_text_order31(r, Any["senna"])
    # The index helper's text for the same columns and config is the predicate's document.
    @test Models.search_vector_expression("forename", "surname"; config = "simple") ==
          replace(doc, r"\"Tb\"\." => "")
    # A projected vector with no filter on it builds too, and reads as its text.
    r = _q31(; vals = Any["driverid", "doc" => vec])
    @test occursin("$(doc) as \"doc\"", r[:sql_text])
  end

  @testset "alias @search: a SearchQuery, a combination, a weighted sum, a binding operand, inside Q" begin
    # A SearchQuery keeps its own parser and config; the vector keeps its own.
    q = SearchQuery("senna"; config = "english", search_type = "websearch")
    r = _q31("doc__@search" => q; vals = Any["driverid", "doc" => SearchVector("surname"; config = "simple")])
    @test occursin("WHERE to_tsvector('simple'::regconfig, COALESCE((\"Tb\".\"surname\")::text, '')) @@ " *
                   "websearch_to_tsquery('english'::regconfig, \$1::text)", r[:sql_text])
    # A combined query and a weighted sum of vectors.
    both = SearchQuery("senna"; config = "simple") | SearchQuery("prost"; config = "simple")
    sum = SearchVector("surname"; config = "simple", weight = "A") + SearchVector("forename"; config = "simple", weight = "D")
    r = _q31("doc__@search" => both; vals = Any["driverid", "doc" => sum])
    @test occursin("WHERE (setweight(", r[:sql_text])
    @test occursin("'D')) @@ (plainto_tsquery('simple'::regconfig, \$1::text) || plainto_tsquery('simple'::regconfig, \$2::text))",
                   r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "prost"])
    # A vector whose operand binds: it binds once in SELECT and again in WHERE, ahead of the query.
    vec = SearchVector("forename", Concat("surname", Value(" jr")); config = "simple")
    r = _q31("doc__@search" => "senna"; vals = Any["driverid", "doc" => vec])
    _assert_pg_text_order31(r, Any[" jr", " jr", "senna"])
    # Inside Q, beside a column predicate, in text order.
    r = _q31(PormG.Q("doc__@search" => "senna", "forename" => "Bruno");
             vals = Any["driverid", "doc" => SearchVector("surname"; config = "simple")])
    @test occursin("@@ plainto_tsquery('simple'::regconfig, \$1::text)", r[:sql_text])
    _assert_pg_text_order31(r, Any["senna", "Bruno"])
  end

  @testset "a SearchVector alias takes @search and nothing else; other aliases still refuse @search" begin
    vals = Any["driverid", "doc" => SearchVector("surname")]
    for pair in ("doc__@gt" => 1, "doc" => "senna", "doc__@icontains" => "senna", "doc__@isnull" => true)
      e = _err31(() -> _q31(pair; vals = vals))
      @test e isa FilterError
      @test occursin("the only lookup on it is @search", _plain31(sprint(showerror, e)))
    end
    # @search on an alias that is not a SearchVector, in words that name the SearchVector route.
    msg = _msg31(() -> _q31("n__@search" => "senna"; vals = Any["driverid", "n" => Lower("surname")]))
    @test occursin("an alias that projects a SearchVector", msg)
    # A sum with mixed configs has no config for a String query.
    mixed = SearchVector("forename"; config = "simple") + SearchVector("surname"; config = "english")
    e = _err31(() -> _q31("doc__@search" => "senna"; vals = Any["driverid", "doc" => mixed]))
    @test e isa FilterError
    @test occursin("different configs", _plain31(sprint(showerror, e)))
    # Projected is the one new use: wrapped or compared, it is still not a value.
    for f in (() -> _q31(; vals = Any["driverid", "x" => Coalesce(SearchVector("surname"), Value(""))]),
              () -> _q31(SearchVector("surname") == "x"))
      e = _err31(f)
      @test e isa QueryBuildError
      @test occursin("cannot be compared or wrapped", _plain31(sprint(showerror, e)))
    end
    # Beside an aggregate it is a grouping key, named by its position — the projection is not
    # rendered again, so nothing re-checks it there (tsvector has equality, so PostgreSQL groups it).
    r = _q31(; vals = Any["doc" => SearchVector("surname"), "n" => PormG.Functions.Count("driverid")])
    @test occursin("GROUP BY 1", r[:sql_text])
    # On SQLite the projection and the alias search name PostgreSQL.
    @test _err31(() -> _q31("doc__@search" => "x"; vals = vals, conn = _FTS_SL)) isa BackendCapabilityError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SearchVectorField: @search on a stored document is `col @@ query`
  # The column is already a tsvector, so the lookup puts no `to_tsvector` around it: the query's
  # config parses the query alone. On a column reached through a ForeignKey too.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "@search on a SearchVectorField renders the column itself @@ the query" begin
    r = _q31("search__@search" => SearchQuery("monaco"; config = "english"); model = _F.Report, vals = Any["reportid"])
    @test occursin("WHERE \"Tb\".\"search\" @@ plainto_tsquery('english'::regconfig, \$1::text)", r[:sql_text])
    @test !occursin("to_tsvector", r[:sql_text])
    _assert_pg_text_order31(r, Any["monaco"])
    # A bare string is a plain query under the server's default config, as on a text column.
    r = _q31("search__@search" => "monaco"; model = _F.Report, vals = Any["reportid"])
    @test occursin("\"Tb\".\"search\" @@ plainto_tsquery(\$1::text)", r[:sql_text])
    # A combined query, and the reverse path from a race to its reports.
    q = SearchQuery("monaco"; config = "english") & ~SearchQuery("rain"; config = "english")
    r = _q31("search__@search" => q; model = _F.Report, vals = Any["reportid"])
    @test occursin("\"Tb\".\"search\" @@ (plainto_tsquery('english'::regconfig, \$1::text) && (!!plainto_tsquery(", r[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SearchVectorField: SearchRank ranks the stored column by its path
  # Django's `SearchRank(F("search"), q)`. The path is checked at render to be a SearchVectorField: a
  # text column is not a document, and casting it to tsvector would read it as a literal.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchRank(\"search\", q) ranks the stored document; a text path is refused" begin
    r = _q31(; model = _F.Report, vals = Any["reportid", "rank" => SearchRank("search", SearchQuery("monaco"; config = "english"); weights = [0.1, 0.2, 0.4, 1.0])])
    @test occursin("(ts_rank('{0.1,0.2,0.4,1.0}'::float4[], \"Tb\".\"search\", plainto_tsquery('english'::regconfig, \$1::text)))::double precision",
                   r[:sql_text])
    # A String query on a stored column has no vector config to borrow: the server's default.
    r = _q31(; model = _F.Report, vals = Any["reportid", "rank" => SearchRank("search", "monaco")])
    @test occursin("ts_rank(\"Tb\".\"search\", plainto_tsquery(\$1::text))", r[:sql_text])
    # Ranked through the alias filter, the text binds twice, in text order.
    r = _q31("rank__@gte" => 0.01; model = _F.Report, vals = Any["reportid", "rank" => SearchRank("search", "monaco")])
    _assert_pg_text_order31(r, Any["monaco", "monaco", "0.01"])
    for path in ("title", "body", "reportid")
      e = _err31(() -> _q31(; model = _F.Report, vals = Any["reportid", "r" => SearchRank(path, "x")]))
      @test e isa QueryBuildError
      @test occursin("SearchRank(SearchVector(\"$(path)\")", _plain31(sprint(showerror, e)))
    end
  end

  @testset "a SearchVectorField is not text: SearchVector, SearchHeadline and pattern lookups refuse it" begin
    e = _err31(() -> _q31(; model = _F.Report, vals = Any["reportid", "r" => SearchRank(SearchVector("title", "search"), "x")]))
    @test e isa QueryBuildError
    @test occursin("already a document", _plain31(sprint(showerror, e)))
    e = _err31(() -> _q31(; model = _F.Report, vals = Any["reportid", "h" => SearchHeadline("search", "x")]))
    @test e isa QueryBuildError
    @test occursin("SearchHeadline marks words in TEXT", _plain31(sprint(showerror, e)))
    for op in ("@contains", "@icontains", "@startswith", "@regex")
      e = _err31(() -> _q31("search__$(op)" => "mon"; model = _F.Report, vals = Any["reportid"]))
      @test e isa FilterError
      @test occursin("Search it with \"search__@search\"", _plain31(sprint(showerror, e)))
    end
    # A number column is still not searchable, and the message now names both kinds.
    @test occursin("or a SearchVectorField", _msg31(() -> _q31("number__@search" => "1")))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SearchVectorField: update fills it from a SearchVector
  # Django's `update(search=SearchVector(…))`. The vector renders as the document it is — past the
  # "operand, not a value" refusal — and only into a SearchVectorField; a SearchQuery, or a vector
  # into any other column, is refused before anything runs.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "update(\"search\" => SearchVector(…)) writes the document into the column" begin
    q = _F.Report.objects
    q.filter("raceid" => 7)
    vec = SearchVector("title"; config = "english", weight = "A") + SearchVector("body"; config = "english", weight = "B")
    res = q.update("search" => vec, show_query = :dict)
    @test occursin(r"SET \"search\" = \(setweight\(to_tsvector\('english'::regconfig, COALESCE\(\(\"?[A-Za-z_]*\"?\.?\"title\"\)::text, ''\)\), 'A'\) \|\| setweight\(",
                   res[:sql_text])
    @test !occursin("::tsvector", res[:sql_text])
    # One binding operand. PostgreSQL numbers its markers: the WHERE value is bound when the scope is
    # built ($1), and the SET operand after it ($2) — the order #668 pins for every update.
    q = _F.Report.objects
    q.filter("raceid" => 7)
    res = q.update("search" => SearchVector(Concat("title", Value(" report")); config = "simple"), show_query = :dict)
    @test res[:parameters] == Any[7, " report"]
    @test occursin("SET \"search\" = to_tsvector('simple'::regconfig, COALESCE((CONCAT(\"Tb\".\"title\", \$2::text))::text, ''))",
                   replace(res[:sql_text], r"\s+" => " "))
    @test occursin(r"\"raceid\" = \$1\b", res[:sql_text])
    # Refused: a vector into a text column, a query anywhere, and the raw value types the column
    # does not hold.
    for (field, value) in (("title", SearchVector("body")), ("search", SearchQuery("x")), ("title", SearchQuery("x")))
      q = _F.Report.objects
      q.filter("raceid" => 7)
      e = _err31(() -> q.update(field => value, show_query = :dict))
      @test e isa QueryBuildError
      @test occursin("a SearchVector fills a SearchVectorField column", _plain31(sprint(showerror, e)))
    end
    q = _F.Report.objects
    q.filter("raceid" => 7)
    @test occursin("SET \"search\" = \$", q.update("search" => "'monaco':1", show_query = :dict)[:sql_text])
    q = _F.Report.objects
    q.filter("raceid" => 7)
    @test _err31(() -> q.update("search" => 1, show_query = :dict)) isa InvalidValueError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SearchVectorField: the column — DDL, the canonical type, SQLite, inspectdb, the model file
  # `tsvector` on PostgreSQL; refused on SQLite at both sites the #648 pattern names; read back as its
  # own kind, so a declared field equals its live column; and a model file round-trips it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SearchVectorField renders tsvector, is refused on SQLite, and round-trips" begin
    field = Models.SearchVectorField(null = true)
    @test PormG.Dialect._get_column_type(field, _FTS_PG) == "tsvector"
    e = _err31(() -> PormG.Dialect.field_to_column("search", field, _FTS_SL))
    @test e isa BackendCapabilityError
    @test occursin("SearchVectorField \"search\"", _plain31(sprint(showerror, e)))
    @test PormG.Migrations.column_spec(field, _FTS_PG).type == PormG.CTsVector()
    @test PormG.Migrations.parse_canonical_type("tsvector", _FTS_PG) == PormG.CTsVector()
    # inspectdb writes the field back from the live column's kind.
    spec = PormG.Migrations.column_spec(field, _FTS_PG)
    back = PormG.Migrations._inspectdb_field(spec, "report", _FTS_PG, false, nothing)
    @test back isa Models.sSearchVectorField && back.null
    # A generated model file declares it by its constructor.
    @test occursin("search = Models.SearchVectorField(null=true)", PormG.Models.Model_to_str(_F.Report))
    # A default is a document's text, nothing else.
    @test Models.SearchVectorField(default = "'monaco':1").default == "'monaco':1"
    @test _err31(() -> Models.SearchVectorField(default = 1)) isa FieldValidationError
  end

  @testset "a retype into tsvector is refused; out of it, only to text" begin
    nic = PormG.Migrations._pg_no_implicit_cast
    @test nic(PormG.CText(), PormG.CTsVector())
    @test nic(PormG.CVarChar(200), PormG.CTsVector())
    @test nic(PormG.CInt32(), PormG.CTsVector())
    @test !nic(PormG.CTsVector(), PormG.CText())
    @test nic(PormG.CTsVector(), PormG.CInt32())
    # No USING is written for it: `CAST(col AS tsvector)` would read the text as a tsvector literal.
    @test PormG.Dialect._postgres_retype_using("c", PormG.CText(), PormG.CTsVector(), "tsvector") === nothing
  end
end
