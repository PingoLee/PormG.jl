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

## Indexing

Without an index, every search reads and parses each row's text. A GIN index on the same expression
the query renders lets PostgreSQL find the matching rows directly. Declare it with `Models.Index`,
and write the expression **exactly** as PormG renders it, configuration included:

```julia
Driver = Models.Model("driver",
    driverid = Models.IDField(),
    forename = Models.CharField(),
    surname  = Models.CharField(),
    indexes  = [Models.Index(expressions = ("to_tsvector('simple', surname)",),
                             method = "gin", name = "driver_surname_tsv")],
)

# Served by driver_surname_tsv: the same configuration, the same column
M.Driver.objects.filter("surname__@search" => SearchQuery("senna"; config = "simple"))
```

| The lookup | The index expression it needs |
| :--- | :--- |
| `"col__@search" => SearchQuery(…; config = "cfg")` | `to_tsvector('cfg', col)` |
| `"col__@search" => "text"` (no configuration) | none: one-argument `to_tsvector` depends on a server setting, so PostgreSQL refuses to index it |

The second row is the reason to always pass a configuration on a large table. The `'cfg'` in an
index and the `'cfg'::regconfig` PormG renders are the same expression to PostgreSQL.

Only the lookup uses an index. `SearchRank` and `SearchHeadline` are computed for each row the query
keeps, so filter with an indexed `@search` first and rank or headline what is left.

## Limitations

These are deliberate for now. Each is refused with a typed error, not run as something else:

- **A `SearchVector` or `SearchQuery` is not a value.** Projecting one, comparing it, or wrapping it
  in another function raises `QueryBuildError`. Putting one on the right of any lookup but `@search`
  raises `FilterError`. Neither has a Julia reading yet.
- **No stored `tsvector` column.** A model has no `SearchVectorField` yet, so a document is always
  computed from its text columns. Use an expression index (above) to make that fast.
- **No weights**: `SearchVector(…; weight = …)` and `SearchRank(…; weights = …)` raise
  `QueryBuildError`. Ranking weighs every word the same.
- **No query combinators**: `SearchQuery` objects do not combine with `&`, `|` or `~`. A
  `"websearch"` query takes `or` and `-word` in its text, and a `"raw"` one takes `&`, `|` and `!`.
- **`@search` on a projection alias** raises `FilterError`. Search the column itself.
