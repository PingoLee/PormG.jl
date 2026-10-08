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
    @test _err31(() -> SearchRank("surname", "senna")) isa QueryBuildError
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
      () -> _q31(; vals = Any["driverid", "v" => sv]),
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
end
