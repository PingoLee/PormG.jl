# Full-Text Search

PostgreSQL's full-text search finds rows by the **words** in a text column rather than by a
pattern. `"senna"` matches `"Ayrton Senna"` without a `%`. A configuration such as `english`
stems words, so `"circuits"` matches `"Silverstone Circuit"`. Results can be **ranked** by how
well they match, and **headlined** with the matched words marked.

PormG follows Django's `django.contrib.postgres.search`. It has one lookup, `@search`, and four
functions in `PormG.Functions`:

| | What it is | Renders |
| :--- | :--- | :--- |
| `"col__@search" => …` | the lookup: does the column match the query? | `to_tsvector(col) @@ <query>` |
| `SearchQuery(text; …)` | the query | `plainto_tsquery(…)` and its siblings |
| `SearchVector(fields...; …)` | a document made of one or more columns | `to_tsvector(…)` |
| `SearchRank(vector, query; …)` | how well each row matches, as a `Float64` | `ts_rank(…)` |
| `SearchHeadline(field, query; …)` | the text with the matched words marked | `ts_headline(…)` |

!!! warning "PostgreSQL only"
    SQLite has no `tsvector` or `tsquery`. Its FTS5 extension is a separate index table with its
    own query syntax and ranking. PormG does not emulate it, because an emulation would answer a
    different question. On SQLite the lookup and each function raise `BackendCapabilityError` when
    the query is built, so a test suite on SQLite fails where production would diverge. See the
    [PostgreSQL Guide](../postgres.md).

```julia
using PormG.Functions: SearchQuery, SearchVector, SearchRank, SearchHeadline
```

## The `@search` lookup

Give it the search text, and it matches the rows whose column contains every word:

```julia
M.Driver.objects.filter("surname__@search" => "senna").values("forename", "surname") |> DataFrame
# renders:  WHERE to_tsvector("Tb"."surname") @@ plainto_tsquery($1::text)
#  Row │ forename  surname
# ─────┼───────────────────
#    1 │ Ayrton    Senna
#    2 │ Bruno     Senna
```

The column must be a text column, a `CharField` or a `TextField`, on the model or reached through
a ForeignKey (`"driverid__surname__@search"`). On any other column the lookup raises `FilterError`.
The value is the search text or a [`SearchQuery`](#SearchQuery), and anything else raises
`FilterError`. The lookup composes like any other: inside `Q`, `Qor` and a `When` condition.

With a bare string, PostgreSQL parses both the column and the text with its
`default_text_search_config`. To choose the configuration, or the way the text is read, pass a
`SearchQuery`. The column is then parsed with the query's configuration too:

```julia
M.Driver.objects.filter("surname__@search" => SearchQuery("senna"; config = "simple"))
# renders:  WHERE to_tsvector('simple'::regconfig, "Tb"."surname") @@ plainto_tsquery('simple'::regconfig, $1::text)
```

The lookup searches one column. To find words spread across several columns, rank a
[`SearchVector`](#SearchVector-and-SearchRank) of them and keep the rows above a threshold. That
scores every row, so on a large table narrow the rows with an indexed `@search` first where you can
(see [Indexing](#Indexing)).

## `SearchQuery`

`SearchQuery(text; config = nothing, search_type = "plain")` turns the text into a `tsquery`. The
text is always bound as a parameter. `search_type` picks the parser PostgreSQL applies to it:

| `search_type` | Renders | The text is read as | Example |
| :--- | :--- | :--- | :--- |
| `"plain"` (default) | `plainto_tsquery` | words, all of them required | `"ayrton senna"` |
| `"phrase"` | `phraseto_tsquery` | words, adjacent and in this order | `"grand prix"` |
| `"websearch"` | `websearch_to_tsquery` | search-engine syntax: `"a phrase"`, `or`, `-word` | `"senna or prost"` |
| `"raw"` | `to_tsquery` | `tsquery` syntax: `&`, `\|`, `!`, `<->`, `:*` | `"sen:*"` |

```julia
# Every race whose name has "Grand Prix" as a phrase, parsed with the English configuration
M.Race.objects.filter("name__@search" => SearchQuery("grand prix"; config = "english", search_type = "phrase"))

# Senna or Prost, the way a search box would take it
M.Driver.objects.filter("surname__@search" => SearchQuery("senna or prost"; config = "simple", search_type = "websearch"))

# A prefix: every surname with a word starting "sen"
M.Driver.objects.filter("surname__@search" => SearchQuery("sen:*"; config = "simple", search_type = "raw"))

# Stemming: "circuits" matches "Silverstone Circuit" under english, and not under simple
M.Circuit.objects.filter("name__@search" => SearchQuery("circuits"; config = "english"))
```

A `"raw"` query is PostgreSQL's own syntax, and PormG does not parse it. A text the server cannot
read, such as `"a & | b"`, raises `DatabaseError` (a `StatementError`) when the query runs, not when
it is built. Use `"websearch"` for text a user typed, because it accepts any input.

An unknown `search_type`, or text containing a NUL character, raises `InvalidValueError` when the
`SearchQuery` is built.

### Combining queries

Queries combine with `&` (both), `|` (either) and `~` (not), like Django's. They render PostgreSQL's
`&&`, `||` and `!!` on `tsquery`. Each query keeps its own `search_type`, and each text is bound:

```julia
english(text; kw...) = SearchQuery(text; config = "english", kw...)

# Every Grand Prix that is not the British one
M.Race.objects.filter("name__@search" => english("grand prix"; search_type = "phrase") & ~english("british"))
# WHERE to_tsvector('english'::regconfig, "Tb"."name") @@
#       (phraseto_tsquery('english'::regconfig, $1::text) && (!!plainto_tsquery('english'::regconfig, $2::text)))

# Senna or Prost, built from two queries rather than one websearch string
M.Driver.objects.filter("surname__@search" => SearchQuery("senna"; config = "simple") | SearchQuery("prost"; config = "simple"))
```

Combined queries must share one configuration. The lookup parses the column with its query's
configuration, so a combination of two configurations has none to give it. Two different
configurations, or one and none, raise `QueryBuildError`. So does combining a `SearchQuery` with a
`SearchVector`, a number or a column expression. On text a user typed, a single `"websearch"` query is still the
simpler choice: it reads `or` and `-word` itself.

### The configuration

`config` names a text-search configuration: `"english"`, `"simple"`, `"portuguese"`, or a
schema-qualified `"pg_catalog.english"`. It decides how words are split, lowercased, stemmed, and
which stop words are dropped. With none, the server's `default_text_search_config` applies.

The configuration is written into the SQL as `'english'::regconfig`, not bound as a parameter.
PostgreSQL matches an expression index by its text, so only a written configuration lets an index
serve the query (see [Indexing](#Indexing)). It is safe to write in because it is a **name**.
Anything that is not letters, digits and underscores, optionally schema-qualified, raises
`InvalidValueError` when the expression is built. The search text never takes this path.

A side written as a bare string takes its configuration from the side written as an object.
`"surname__@search" => SearchQuery("senna"; config = "simple")` parses the column with `simple`, and
`SearchRank(SearchVector("surname"; config = "english"), "senna")` parses `"senna"` with `english`.
That keeps both sides agreeing on what a word is. An `english` document searched with a `simple` query
quietly misses every stemmed word.

## `SearchVector` and `SearchRank`

`SearchVector(fields...; config = nothing)` builds one document from one or more columns. Each is
cast to text and made NULL-safe, and they are joined by a space, so a driver with no forename still
matches on the surname:

```julia
SearchVector("forename", "surname"; config = "simple")
# to_tsvector('simple'::regconfig, COALESCE(("Tb"."forename")::text, '') || ' ' || COALESCE(("Tb"."surname")::text, ''))
```

`SearchRank(vector, query; normalization = nothing, cover_density = false)` scores each row's
document against a query, as a `Float64`. Project it under a name, then filter and order by that name:

```julia
M.Driver.objects.
    values("forename", "surname",
           "rank" => SearchRank(SearchVector("forename", "surname"; config = "simple"), "senna")).
    filter("rank__@gte" => 0.01).
    order_by("-rank") |> DataFrame
#  Row │ forename  surname  rank
# ─────┼────────────────────────────
#    1 │ Ayrton    Senna    0.0607927
#    2 │ Bruno     Senna    0.0607927
```

- **Filter on a threshold, not on `> 0`.** `ts_rank` does not give every row that fails to match a
  `0`. For a query of several words, a row that misses them scores a tiny positive value (`1e-20`).
  With `"ayrton senna"`, `"rank__@gt" => 0` keeps all 861 drivers. Django's examples use a
  threshold for the same reason.
- The rank's filter renders the expression again in `WHERE`, so `ts_rank` runs twice per row and
  the text is bound twice. Ordering by the name binds nothing.
- `cover_density = true` uses `ts_rank_cd`, which also rewards matched words that sit close
  together.
- `normalization` is PostgreSQL's integer bitmask (0 to 63) for weighing a long document against a
  short one. Any other value raises `InvalidValueError`.
- `query` is a `SearchQuery`, or the search text as a String. `vector` must be a `SearchVector`, and
  anything else raises `QueryBuildError`.

A comparison works too, with no alias: `filter(SearchRank(SearchVector("surname"), "senna") > 0.5)`.

### Searching several columns

To match a word in any of several columns, project a `SearchVector` under a name and filter that
name with `@search`, as Django's annotate-then-filter does:

```julia
M.Driver.objects.
    values("forename", "surname", "doc" => SearchVector("forename", "surname"; config = "simple")).
    filter("doc__@search" => "lewis") |> DataFrame
#  Row │ forename  surname      doc
# ─────┼──────────────────────────────────────────────
#    1 │ Lewis     Hamilton     'hamilton':2 'lewis':1
#    2 │ Jackie    Lewis        'jackie':1 'lewis':2
#    3 │ Stuart    Lewis-Evans  'evans':4 'lewis':3 'lewis-evans':2 'stuart':1
# renders:  WHERE to_tsvector('simple'::regconfig, COALESCE(("Tb"."forename")::text, '') || ' ' ||
#                 COALESCE(("Tb"."surname")::text, '')) @@ plainto_tsquery('simple'::regconfig, $1::text)
```

The alias reads as the `tsvector`'s text, a `String`. A query written as a String takes the
vector's configuration, as in `SearchRank`. `@search` is the only lookup on such an alias, and any
other raises `FilterError`. `@search` on an alias that is not a `SearchVector` raises `FilterError`
too. Weighted and summed vectors work here as well.

### Weights

A match in one column can count for more than a match in another. Label each column's words with a
`weight` of `"A"`, `"B"`, `"C"` or `"D"`, and add the vectors with `+` into one document. The rank
then scores a word by its label:

```julia
vector = SearchVector("surname"; config = "simple", weight = "A") +
         SearchVector("forename"; config = "simple", weight = "D")

M.Driver.objects.
    values("forename", "surname", "rank" => SearchRank(vector, SearchQuery("lewis"; config = "simple"))).
    filter("rank__@gte" => 0.01).
    order_by("-rank", "surname") |> DataFrame
#  Row │ forename  surname      rank
# ─────┼──────────────────────────────────
#    1 │ Jackie    Lewis        0.607927
#    2 │ Stuart    Lewis-Evans  0.607927
#    3 │ Lewis     Hamilton     0.0607927
```

PostgreSQL's default weights are `0.1`, `0.2`, `0.4` and `1.0` for D, C, B and A, which is why a
forename match scores a tenth of a surname match. `SearchRank(…; weights = [d, c, b, a])` sets them,
**in that order** (D first), as four numbers from 0 to 1. With `weights = [0.0, 0.0, 0.0, 1.0]` only
the surname counts, and Lewis Hamilton drops below the threshold.

- Weights only change the score of a word against a word labelled differently. On a vector with no
  `weight`, every word carries `"D"`.
- Each half of a sum keeps its own config and weight. If the configs differ, a query written as a
  String has no config to be parsed with, so `SearchRank` needs a `SearchQuery` and raises
  `QueryBuildError` otherwise.
- A weight other than `"A"` to `"D"`, or weights that are not four numbers from 0 to 1, raise
  `InvalidValueError`. A `SearchVector` adds only to another `SearchVector`: adding a number, a column
  path, a `SearchQuery` or a function to one raises `QueryBuildError`.

## `SearchHeadline`

`SearchHeadline(field, query; config = nothing, options...)` returns the field's text with the
words the query matched marked, as a `String`:

```julia
M.Race.objects.
    filter("name__@search" => SearchQuery("grand prix"; config = "english"), "year" => 2009).
    values("round", "hl" => SearchHeadline("name", SearchQuery("grand prix"; config = "english");
                                           start_sel = "<b>", stop_sel = "</b>")).
    order_by("round") |> DataFrame
#  Row │ round  hl
# ─────┼──────────────────────────────────────────────
#    1 │     1  Australian <b>Grand</b> <b>Prix</b>
#    2 │     2  Malaysian <b>Grand</b> <b>Prix</b>
#  ⋮
```

The options are PostgreSQL's, written in snake case. They are checked when the expression is built
and sent as **one bound parameter**, so a quote, a comma or a backslash in a marker arrives as
written:

| Option | PostgreSQL | Value |
| :--- | :--- | :--- |
| `start_sel`, `stop_sel` | `StartSel`, `StopSel` | `String`. The markers around a matched word (default `<b>`, `</b>`) |
| `max_words`, `min_words` | `MaxWords`, `MinWords` | integers, `0 < min_words < max_words` (defaults 35 and 15) |
| `short_word` | `ShortWord` | integer ≥ 0. Words this long or shorter are dropped at the ends of a headline, unless they match (default 3) |
| `highlight_all` | `HighlightAll` | `Bool`. Return the whole text, ignoring the three options above |
| `max_fragments` | `MaxFragments` | integer ≥ 0. Above 0, return up to this many fragments |
| `fragment_delimiter` | `FragmentDelimiter` | `String`. The separator between fragments |

A value of the wrong type or out of range raises `InvalidValueError`. `config` defaults to the
query's.

!!! warning "The headline is not HTML-escaped"
    `ts_headline` returns the column's own text with the markers inserted around matches; nothing
    in it is escaped. A headline shown in a web page is stored text like any other: escape it, then
    put the markers back, or pick markers that survive your escaping.

!!! tip "Filter and limit first"
    `ts_headline` reads the whole text of every row it returns, and it cannot use an index. Narrow
    the rows with `@search` and `limit` before projecting a headline.

## A stored document: `SearchVectorField`

Every query above parses the text of every row it reads. A `SearchVectorField` stores the parsed
document in a `tsvector` column instead, as Django's does, so a search reads the stored document:

```julia
Race_report = Models.Model("race_report",
    id     = Models.IDField(),
    title  = Models.CharField(max_length = 200),
    body   = Models.TextField(null = true),
    search_vector = Models.SearchVectorField(null = true),
    indexes = [Models.Index(fields = ("search_vector",), method = "gin", name = "race_report_search_vector_gin")],
)
```

Fill it from the text columns with `update` and a `SearchVector`. Weights and sums work here too:

```julia
M.Race_report.objects.filter("id__@gte" => 0).
    update("search_vector" => SearchVector("title"; config = "simple", weight = "A") +
                       SearchVector("body"; config = "simple", weight = "B"))
# UPDATE "race_report" AS "Tb"
# SET "search_vector" = (setweight(to_tsvector('simple'::regconfig, COALESCE(("Tb"."title")::text, '')), 'A') || …)
```

Then search it with `@search`, which on this column renders `"search_vector" @@ <query>` with no
`to_tsvector`, and rank it by its path, Django's `SearchRank(F("search_vector"), …)`:

```julia
M.Race_report.objects.filter("search_vector__@search" => SearchQuery("senna"; config = "simple"))

M.Race_report.objects.
    values("title", "rank" => SearchRank("search_vector", SearchQuery("senna"; config = "simple"))).
    filter("rank__@gte" => 0.01).
    order_by("-rank") |> DataFrame
#  Row │ title              rank
# ─────┼───────────────────────────────
#    1 │ Senna at Suzuka    0.607927
#    2 │ Monaco Grand Prix  0.243171
```

- **The column does not refresh itself.** Run the `update` again after the text changes, for the
  rows that changed. A generated column (`GENERATED ALWAYS AS (…) STORED`) is not supported yet.
- **Search with the configuration the document was built with.** The stored document does not
  record it, so a `SearchQuery` without one is parsed with the server's default, and an `english`
  document searched with a `simple` query misses every stemmed word.
- The column reads as the `tsvector`'s text, a `String`: `'at':2A 'senna':1A 'suzuka':3A`. A
  `String` written to it is parsed as that text, not as words. Use `update` with a `SearchVector`
  to build it from words. It takes no `default` (`FieldValidationError`): PostgreSQL stores a
  document literal rewritten, so a declared one would never match its column. Declare it
  `null = true`, and fill it with `update`.
- Name it something other than `search`, such as Django's `search_vector`. `search` is also the
  lookup's name, so a bare `filter("search" => …)` on such a column is misread today (#1030).
- A GIN index on the column (`Models.Index(fields = ("search_vector",), method = "gin", …)`) serves
  `@search`, with no expression to match.
- `SearchVector`, `SearchHeadline` and the pattern lookups (`@contains`, …) do not take the column.
  It is already a document, so they raise `QueryBuildError` or `FilterError`. So does a
  `SearchVector` written to any other column, or a `SearchQuery` written to any column.
- PostgreSQL only: on SQLite, `makemigrations` raises `BackendCapabilityError` for a model that
  declares one. A retype from text into `tsvector` is refused, because `CAST(text AS tsvector)`
  reads the text as a document literal rather than parsing its words. Add a new column and fill it
  with `update` instead.

## Indexing

Without an index, every search reads and parses each row's text. A GIN index on the same expression
the query renders lets PostgreSQL find the matching rows directly. PostgreSQL uses the index only
when the two expressions are the same, and a wrong configuration or column still makes a valid index
that is simply never used. So declare the expression with `Models.search_vector_expression`, which
returns the text the query itself renders, rather than typing it by hand:

```julia
Driver = Models.Model("driver",
    driverid = Models.IDField(),
    forename = Models.CharField(),
    surname  = Models.CharField(),
    indexes  = [Models.Index(expressions = (Models.search_vector_expression("surname"; config = "simple"),),
                             method = "gin", name = "driver_surname_tsv")],
)

Models.search_vector_expression("surname"; config = "simple")
# "to_tsvector('simple'::regconfig, \"surname\")"

# Served by driver_surname_tsv: the same configuration, the same column
M.Driver.objects.filter("surname__@search" => SearchQuery("senna"; config = "simple"))
```

| The query | The index expression it needs |
| :--- | :--- |
| `"col__@search" => SearchQuery(…; config = "cfg")` | `search_vector_expression("col"; config = "cfg")` |
| `"col__@search" => "text"` (no configuration) | none: one-argument `to_tsvector` depends on a server setting, so PostgreSQL refuses to index it |
| `"doc__@search"` on `"doc" => SearchVector("a", "b"; config = "cfg")` | `search_vector_expression("a", "b"; config = "cfg")` |
| the same with `weight = "A"` | `search_vector_expression("a", "b"; config = "cfg", weight = "A")` |

The second row is the reason to always pass a configuration on a large table. The configuration you
give the helper must be the query's, and it is required: without one there is no index to declare. Its columns are database column names, a field's `db_column`
where it sets one. A configuration that is not a name raises `InvalidValueError`, as it does in the
query, and a column that is not an identifier, or no configuration, raises `ModelDefinitionError`.

Only the lookup uses an index. `SearchRank` and `SearchHeadline` are computed for each row the query
keeps, so filter with an indexed `@search` first and rank or headline what is left.

## Limitations

These are deliberate for now. Each is refused with a typed error, not run as something else:

- **A `SearchVector` or `SearchQuery` is not a value.** A `SearchVector` may be projected under a
  name (above). Otherwise, projecting either, comparing it, or wrapping it in another function raises
  `QueryBuildError`, and putting one on the right of any lookup but `@search` raises `FilterError`.
- **A single-column `SearchVector` alias is not the lookup's expression.** `SearchVector("surname")`
  is `COALESCE`d and cast, so an index on `search_vector_expression("surname"; config = …)` serves
  `"surname__@search"` but not that alias. Search the column itself.
- **No generated `tsvector` column.** A `SearchVectorField` is filled by `update`, not by the
  database. A column that keeps itself current (`GENERATED ALWAYS AS (to_tsvector(…)) STORED`) is
  not supported yet.
