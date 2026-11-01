"""
Unit coverage for JSON/JSONB path lookups (#27): `filter("payload__key" => …)`,
`payload__0__name` (array index), nested paths, numeric comparisons, `__@isnull`, projection,
and ORDER BY — with deterministic per-dialect SQL and parameter checks (no live database).

A non-terminal JSONField in a `__` path is a value **extraction**, not a join hop:
  - PostgreSQL: `<col> #>> '{seg,…}'` (text[] path; numeric segment = array index).
  - SQLite:     `json_extract(<col>, '\$.seg[0]…')`.
Extraction is TEXT; comparisons bind the RHS as plain text, and `<`/`>` cast the extracted text to
numeric on PostgreSQL (`#>>` always yields text) while SQLite's `json_extract` returns native types.

Key segments are validated fail-closed and interpolated (NOT parameterized) so the resolved
selector carries no placeholder — see test_parameters.jl for the cross-clause bucket-alignment guard.

Sibling coverage:
  - `test_json_operators.jl` → the PostgreSQL-only containment operators (@>, ?, ?|, ?&).
  - `test/integration/test_json_fields.jl` → round-trip against the real `payload` JSONField.
"""

using Test
using PormG
using PormG.Models
using Dates

struct JsonLookupMockSQLite <: PormG.PormGSQLite end
struct JsonLookupMockPostgres <: PormG.PormGPostgres end
struct JsonLookupMockMySQL <: PormG.PormGMySQL end
const _JL_SL = JsonLookupMockSQLite()
const _JL_PG = JsonLookupMockPostgres()
const _JL_MY = JsonLookupMockMySQL()

PormG.config["json_lookup_mock"] = PormG.Configuration.Settings(
  connections = _JL_SL, change_data = true, db_def_folder = "json_lookup_mock",
)

# Inline model with a JSONField (dedicated key/module so this file is collision-safe in runtests).
module JsonLookupModels
import PormG
import PormG.Models
Json_scratch = Models.Model("json_scratch",
  id = Models.IDField(),
  name = Models.CharField(),
  payload = Models.JSONField(null = true),
)
PormG.Models.set_models(@__MODULE__, "json_lookup_mock")
end

const JL = JsonLookupModels

# #1381: a model with a date and a number beside the JSON column, for the `When`-on-alias renders.
PormG.config["json_lookup_when_mock"] = PormG.Configuration.Settings(
  connections = _JL_SL, change_data = true, db_def_folder = "json_lookup_when_mock",
)
module JsonWhenModels
import PormG
import PormG.Models
Lap_scratch = Models.Model("lap_scratch",
  id = Models.IDField(),
  payload = Models.JSONField(null = true),
  day = Models.DateField(null = true),
  laps = Models.IntegerField(null = true),
)
PormG.Models.set_models(@__MODULE__, "json_lookup_when_mock")
end
const JW = JsonWhenModels

# #1511: a JSON column on a joined row, for a comparison over its key in an ON clause.
PormG.config["json_lookup_join_mock"] = PormG.Configuration.Settings(
  connections = _JL_SL, change_data = true, db_def_folder = "json_lookup_join_mock",
)
module JsonJoinModels
import PormG
import PormG.Models
Json_team = Models.Model("json_team", id = Models.IDField(), payload = Models.JSONField(null = true))
Json_entry = Models.Model("json_entry", id = Models.IDField(),
  team = Models.ForeignKey(Json_team, on_delete = "CASCADE", related_name = "entries"))
PormG.Models.set_models(@__MODULE__, "json_lookup_join_mock")
end
const JJ = JsonJoinModels
import PormG.QueryBuilder: inspect_query, Case, When

# Resolve a query's SQL under a specific dialect (default = mock SQLite).
_sql(q; conn = nothing) = (conn === nothing ? inspect_query(q) : inspect_query(q; connection = conn))

@testset "JSON path lookups (#27)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Equality lookup — the core `payload__key => value` shape on both dialects
  # PG extracts via `#>>` (text[] path), SQLite via `json_extract` (JSONPath); the RHS binds as a
  # single plain-text parameter (NOT through the JSON formatter, which would reject "hamilton").
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "equality: payload__nome => value (both dialects)" begin
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload__nome" => "hamilton"); q.values("id"); q)

    sl = _sql(mkq())
    @test occursin("json_extract(\"Tb\".\"payload\", '\$.nome') = ?", sl[:sql_text])
    @test sl[:parameters] == ["hamilton"]

    pg = _sql(mkq(); conn = _JL_PG)
    @test occursin("\"Tb\".\"payload\" #>> '{\"nome\"}' = \$1", pg[:sql_text])   # keys quoted in the path
    @test pg[:parameters] == ["hamilton"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Numeric VALUE equality binds dialect-appropriately (regression for the SQLite type bug)
  # SQLite json_extract returns a native number, so `payload__n => 5` must bind the native Int 5
  # (5 = 5), NOT the text "5" (which SQLite evaluates 5 = '5' → false → wrong rows). PostgreSQL
  # `#>>` yields text, so it binds "5" (text = text).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "numeric value equality binds native on SQLite, text on PG" begin
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload__count" => 5); q.values("id"); q)
    @test _sql(mkq())[:parameters] == [5]              # SQLite: native Int 5
    @test _sql(mkq(); conn = _JL_PG)[:parameters] == ["5"]   # PG: text "5"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Nested path + array index — `payload__standings__0__name`
  # A numeric segment is a JSON array index on both dialects: PG `{standings,0,name}`,
  # SQLite `$.standings[0].name`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "nested + array index path" begin
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload__standings__0__name" => "Max"); q.values("id"); q)

    @test occursin("json_extract(\"Tb\".\"payload\", '\$.standings[0].name') = ?", _sql(mkq())[:sql_text])
    @test occursin("\"Tb\".\"payload\" #>> '{\"standings\",0,\"name\"}' = \$1", _sql(mkq(); conn = _JL_PG)[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Numeric comparison — PostgreSQL casts the extracted text to numeric; SQLite does not
  # `#>>` always yields text, so `>=` needs `::numeric`. SQLite json_extract returns native types.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "numeric comparison casts on PG, not SQLite" begin
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload__count__@gte" => 5); q.values("id"); q)

    sl = _sql(mkq())
    @test occursin("json_extract(\"Tb\".\"payload\", '\$.count') >= ?", sl[:sql_text])
    @test !occursin("::numeric", sl[:sql_text])          # SQLite: no cast
    @test sl[:parameters] == [5]

    pg = _sql(mkq(); conn = _JL_PG)
    @test occursin("(\"Tb\".\"payload\" #>> '{\"count\"}')::numeric >= \$1", pg[:sql_text])   # PG: cast
    @test pg[:parameters] == [5]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # MySQL (#1130 phase 5b): the value at the path as text, as PostgreSQL reads it
  # `JSON_EXTRACT` with every key double-quoted (so a key named `null` is a key), `JSON_UNQUOTE` for the
  # text, and `NULLIF` against JSON's `null` first, because `JSON_UNQUOTE` alone reads a JSON null as
  # the text 'null' (measured), which `@isnull` would not match; and a code-point collation, because the
  # text's own `utf8mb4_bin` pads trailing spaces (`"Max "` equalled `'Max'`). Equality binds text, as on
  # PostgreSQL; an ordering compares the text with the bound number, which MySQL does as a double, so
  # it has no cast. Before phase 5b every path lookup was a `MethodError` on MySQL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "MySQL: the value at the path as text, a JSON null as NULL" begin
    mk(f) = (q = JL.Json_scratch.objects; f(q); q.values("id"); q)
    x(path) = "(JSON_UNQUOTE(NULLIF(JSON_EXTRACT(`Tb`.`payload`, '$(path)'), CAST('null' AS JSON))) COLLATE utf8mb4_0900_bin)"
    r = _sql(mk(q -> q.filter("payload__nome" => "hamilton")); conn = _JL_MY)
    @test occursin("WHERE $(x("\$.\"nome\"")) = ?", r[:sql_text]) && r[:parameters] == ["hamilton"]
    @test _sql(mk(q -> q.filter("payload__count" => 5)); conn = _JL_MY)[:parameters] == ["5"]
    @test occursin(x("\$.\"standings\"[0].\"name\""),
                   _sql(mk(q -> q.filter("payload__standings__0__name" => "Max")); conn = _JL_MY)[:sql_text])
    r = _sql(mk(q -> q.filter("payload__count__@gte" => 5)); conn = _JL_MY)
    @test occursin("WHERE $(x("\$.\"count\"")) >= ?", r[:sql_text]) && r[:parameters] == [5]
    @test occursin("$(x("\$.\"missing\"")) IS NULL", _sql(mk(q -> q.filter("payload__missing__@isnull" => true)); conn = _JL_MY)[:sql_text])
    @test occursin("'\$.\"null\"'", _sql(mk(q -> q.filter("payload__null" => "x")); conn = _JL_MY)[:sql_text])
    @test PormG.Dialect._json_extract_expr(_JL_MY, "`c`", ["a", "0", "b"]) ==
          "(JSON_UNQUOTE(NULLIF(JSON_EXTRACT(`c`, '\$.\"a\"[0].\"b\"'), CAST('null' AS JSON))) COLLATE utf8mb4_0900_bin)"
    # The projection reads the key's text. (An ordering over the uncast key is refused, #1497.)
    q = JL.Json_scratch.objects; q.values("id", "payload__nome")
    sql = _sql(q; conn = _JL_MY)[:sql_text]
    @test occursin("$(x("\$.\"nome\"")) as `payload__nome`", sql)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #1091: a non-finite float is refused on a JSON path, under every operator.
  # `_json_numeric_rhs` refused text that overflows to `Inf` but passed a float through, so `Inf` and
  # `NaN` were bound. The engines then disagree on the row set: PostgreSQL's `numeric` orders `NaN`
  # above every number (and `<>` against the text 'NaN' is every row), while SQLite binds `NaN` as
  # NULL, which compares with nothing. A finite float still binds as itself.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a non-finite float is refused on a JSON path (#1091)" begin
    for conn in (_JL_SL, _JL_PG), (path, v) in (("payload__count__@gte", Inf), ("payload__count__@lt", -Inf),
                                                ("payload__count__@gte", NaN), ("payload__count", NaN),
                                                ("payload__count__@ne", NaN))
      e = try _sql((q = JL.Json_scratch.objects; q.filter(path => v); q.values("id"); q); conn = conn); nothing catch err; err end
      @test e isa PormG.InvalidValueError && e.kind === :range
      e isa PormG.InvalidValueError && @test e.field == "payload__count" && occursin("finite number", e.msg)
    end
    @test _sql((q = JL.Json_scratch.objects; q.filter("payload__count__@gte" => 2.5); q.values("id"); q))[:parameters] == [2.5]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # __@isnull on a JSON path — IS NULL / IS NOT NULL, no parameter
  # Rendered directly (the shared ISNULL() rejects any column containing "(", which a legitimate
  # SQLite json_extract(...) expression trips).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "__@isnull renders IS NULL on both dialects" begin
    mk(v) = (q = JL.Json_scratch.objects; q.filter("payload__opt__@isnull" => v); q.values("id"); q)

    @test occursin("json_extract(\"Tb\".\"payload\", '\$.opt') IS NULL", _sql(mk(true))[:sql_text])
    @test occursin("\"Tb\".\"payload\" #>> '{\"opt\"}' IS NULL", _sql(mk(true); conn = _JL_PG)[:sql_text])
    @test occursin("IS NOT NULL", _sql(mk(false))[:sql_text])
    @test _sql(mk(true))[:parameters] == []   # presence check binds no parameter
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Projection + ORDER BY on a JSON path — alias is the dotted path; reuses the resolved selector
  # (SELECT asserted on SQLite; ORDER BY on PG — a mock SQLite trips the #75 version probe in the
  # ORDER BY path, unrelated to JSON. The JSON-path resolution itself is dialect-independent.)
  # ─────────────────────────────────────────────────────────────────────────────
  @testset ".values() projection alias on a JSON path (SQLite)" begin
    q = JL.Json_scratch.objects
    q.values("id", "payload__nome")
    @test occursin("json_extract(\"Tb\".\"payload\", '\$.nome') as \"payload__nome\"", _sql(q)[:sql_text])
  end

  # An ordering over a key states its type (#1497); the cast resolves the extraction inside ORDER BY.
  @testset "order_by over a cast JSON path resolves the extraction (PG)" begin
    q = JL.Json_scratch.objects
    q.values("id")
    q.order_by(PormG.QueryBuilder.SQLOrder(PormG.QueryBuilder.SQLField(PormG.Functions.Cast("payload__nome", "text"), "o")))
    @test occursin(r"ORDER BY\s+\(?\"Tb\".\"payload\" #>> '\{\"nome\"\}'", _sql(q; conn = _JL_PG)[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A key literally named `null` is quoted in the PG path so it isn't parsed as an array-literal
  # NULL element (which would make `#>>` return NULL for every row).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "reserved-looking key is quoted in the PG path" begin
    q = JL.Json_scratch.objects
    q.filter("payload__null" => "x")
    q.values("id")
    @test occursin("\"Tb\".\"payload\" #>> '{\"null\"}'", _sql(q; conn = _JL_PG)[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Fail-closed key validation — segments are interpolated (not parameterized), so anything
  # outside the safe charset (space, dot, quote, brace, paren) must be rejected with the specific
  # "Invalid JSON key segment" error, proving the interpolation can't be broken out of.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "invalid key segments are rejected fail-closed" begin
    for bad in ("payload__bad key", "payload__a.b", "payload__x\")", "payload__x'}")
      q = JL.Json_scratch.objects
      q.filter(bad => "x")
      q.values("id")
      @test_throws "Invalid JSON key segment" inspect_query(q)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `!=` (@ne) uses the same dialect-aware RHS binding as `=`; an unsupported operator is rejected
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "@ne binds native/text per dialect; unsupported operator rejected" begin
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload__count__@ne" => 5); q.values("id"); q)
    sl = _sql(mkq())
    @test occursin("json_extract(\"Tb\".\"payload\", '\$.count') != ?", sl[:sql_text])
    @test sl[:parameters] == [5]                          # SQLite: native
    @test _sql(mkq(); conn = _JL_PG)[:parameters] == ["5"]   # PG: text

    # A string/LIKE operator on a JSON path is not a supported comparison → clear error, naming the
    # lookup as written (#1499: `@startswith`, not the internal `startswith`).
    q = JL.Json_scratch.objects; q.filter("payload__nome__@startswith" => "ham"); q.values("id")
    e = try inspect_query(q); nothing catch err; err end
    @test e isa PormG.FilterError
    # CI renders with color, so the message is read without its ANSI codes.
    e isa PormG.FilterError && @test occursin("The @startswith lookup is not supported on payload__nome, a JSON key's value",
      PormG._emsg(sprint(showerror, e); color = false))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PG projection alias (SQLite projection is covered above; this closes the other dialect)
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "PG .values() projection alias on a JSON path" begin
    q = JL.Json_scratch.objects
    q.values("id", "payload__nome")
    @test occursin("\"Tb\".\"payload\" #>> '{\"nome\"}' as \"payload__nome\"", _sql(q; conn = _JL_PG)[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A numeric segment is an ARRAY INDEX on both dialects — the documented PG/SQLite divergence for
  # numeric OBJECT keys (SQLite `[n]` is array-only; PG `{n}` may also resolve an object key).
  # Pinned as SQL shape so the divergence is intentional and visible, not a silent surprise.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "numeric segment renders as an array index (documented divergence)" begin
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload__2024__revenue" => "x"); q.values("id"); q)
    @test occursin("json_extract(\"Tb\".\"payload\", '\$[2024].revenue')", _sql(mkq())[:sql_text])   # SQLite: array subscript
    @test occursin("\"Tb\".\"payload\" #>> '{2024,\"revenue\"}'", _sql(mkq(); conn = _JL_PG)[:sql_text])  # PG: bare element
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # One array-index test for the validator and both renderers: ASCII digits only (#779)
  # The renderers used `tryparse(Int, s)` and the validator `^\d+$`, and the two disagreed in both
  # directions: `tryparse` reads `0x`/`0b`/`0o` prefixes and returns `nothing` for a digit string too
  # wide for `Int`, while Julia's `\d` also matches non-ASCII digits. `Dialect._is_json_array_index`
  # is now the single answer, so a segment is an index exactly when the validator says it is one.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "array index means ASCII digits, in the validator and both renderers (#779)" begin
    col = "\"Tb\".\"payload\""

    # The renderer on its own: a prefixed segment is a KEY, never a subscript. The public path never
    # hands these over (the validator refuses a leading digit in a key, below), which is exactly why
    # the renderer is asked directly — it must not carry a second, laxer definition.
    for key in ("0x1", "0b1", "0o7")
      @test PormG.Dialect._json_extract_expr(_JL_SL, col, [key]) == "json_extract($col, '\$.$key')"
      @test PormG.Dialect._json_extract_expr(_JL_PG, col, [key]) == "$col #>> '{\"$key\"}'"
    end

    # A digit string wider than `Int` is still an index — `tryparse(Int, …)` returned `nothing` for it
    # and rendered it as a key, while the validator had accepted it as an index.
    wide = "99999999999999999999"
    @test tryparse(Int, wide) === nothing   # precondition: the old test's blind spot
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload__$(wide)__name" => "x"); q.values("id"); q)
    @test occursin("json_extract($col, '\$[$wide].name')", _sql(mkq())[:sql_text])
    @test occursin("$col #>> '{$wide,\"name\"}'", _sql(mkq(); conn = _JL_PG)[:sql_text])

    # Non-ASCII digits are neither an index nor a safe key (a key cannot start with a digit), so they
    # are refused. Before, `^\d+$` accepted `"١٢"` as an index and the renderer then emitted a key.
    @test occursin(r"^\d+$", "١٢")          # precondition: the old validator test accepted it
    q = JL.Json_scratch.objects; q.filter("payload__١٢" => "x"); q.values("id")
    @test_throws "Invalid JSON key segment" inspect_query(q)

    # Anchored with `\A…\z`: PCRE's `$` also matches before a final newline, so a `^[0-9]+$` spelling
    # of the classifier would call `"12\n"` an index.
    @test PormG.Dialect._is_json_array_index("12")
    @test !PormG.Dialect._is_json_array_index("12\n")
    @test !PormG.Dialect._is_json_array_index("")

    # And the prefixed spellings stay refused through the public path, on both dialects.
    for key in ("0x1", "0b1")
      qq = JL.Json_scratch.objects; qq.filter("payload__$key" => 5); qq.values("id")
      @test_throws "Invalid JSON key segment" inspect_query(qq)
      @test_throws "Invalid JSON key segment" inspect_query(qq; connection = _JL_PG)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A KEY segment is anchored the same way as the index test above (#794)
  # `SAFE_JSON_KEY_PATTERN` was `^…$`, so `"driver\n"` passed as a key and the newline went unquoted
  # into the path literal: `'$.driver⏎'` on SQLite, `'{"driver⏎"}'` on PostgreSQL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a key with a trailing newline is refused on both dialects (#794)" begin
    for path in ("payload__driver\n", "payload__driver__name\n")
      q = JL.Json_scratch.objects; q.filter(path => "x"); q.values("id")
      @test_throws "Invalid JSON key segment" inspect_query(q)
      @test_throws "Invalid JSON key segment" inspect_query(q; connection = _JL_PG)
    end

    # The message `repr`s the segment, so the newline that caused the refusal is visible in it.
    q = JL.Json_scratch.objects; q.filter("payload__driver\n" => "x"); q.values("id")
    err = @test_throws PormG.InvalidValueError inspect_query(q)
    @test occursin(repr("driver\n"), err.value.msg)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite bucket alignment (the Option-B design guard)
  # The same JSON path appears in .values() (:select) AND .filter() (:where). The resolved
  # extraction is cached and reused verbatim across clauses; because the keys are interpolated
  # (NOT parameterized), the cached selector carries NO placeholder, so the positional `?`
  # parameters stay perfectly aligned. Parameterizing the path (rejected design) would push a `?`
  # into the :select bucket that the :where reuse cannot account for, shifting every later param.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "same JSON path in values() + filter(): SQLite bucket alignment" begin
    q = JL.Json_scratch.objects
    q.values("id", "payload__nome")           # :select
    q.filter("payload__nome" => "hamilton")   # :where
    insp = _sql(q)                            # SQLite (positional ?)
    @test count(==('?'), insp[:sql_text]) == length(insp[:parameters])   # placeholders == params
    @test insp[:parameters] == ["hamilton"]
    @test insp[:parameter_buckets][:where] == ["hamilton"]
    @test insp[:parameter_buckets][:select] == []   # the SELECT extraction bound no parameter
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A whole document compared with the column: JSON on every engine (#1130 phase 5b)
  # MySQL compares a JSON column with a string as a JSON string scalar, so `payload = ?` matched no
  # stored document (measured on 8.4), and get_or_create's hit read missed into an INSERT. Expected SQL:
  # MySQL parses the bound text, `CAST(? AS JSON)`, one per element of a list; PostgreSQL and SQLite
  # bind the bare marker, the text the write stored. A pattern lookup on the column binds text as before.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a whole JSON document: CAST(? AS JSON) on MySQL, the bare marker elsewhere" begin
    doc = "{\"driver\":\"hamilton\"}"
    mkq() = (q = JL.Json_scratch.objects; q.filter("payload" => doc); q.values("id"); q)
    my = _sql(mkq(); conn = _JL_MY)
    @test occursin("WHERE `Tb`.`payload` = CAST(? AS JSON)", my[:sql_text])
    @test my[:parameters] == Any[doc]
    @test occursin("WHERE \"Tb\".\"payload\" = \$1\n", _sql(mkq(); conn = _JL_PG)[:sql_text])
    @test occursin("WHERE \"Tb\".\"payload\" = ?\n", _sql(mkq(); conn = _JL_SL)[:sql_text])
    ne = (q = JL.Json_scratch.objects; q.filter("payload__@ne" => doc); q.values("id"); q)
    @test occursin(r"`Tb`.`payload` (<>|!=) CAST\(\? AS JSON\)", _sql(ne; conn = _JL_MY)[:sql_text])   # the marker, whichever spelling
    other = "{\"driver\":\"max\"}"
    inq = (q = JL.Json_scratch.objects; q.filter("payload__@in" => [doc, other]); q.values("id"); q)
    my_in = _sql(inq; conn = _JL_MY)
    @test occursin("IN (CAST(? AS JSON), CAST(? AS JSON))", my_in[:sql_text]) && my_in[:parameters] == Any[doc, other]
    # A pattern lookup binds text, a LIKE or a verbatim one alike: no JSON marker.
    for lookup in ("@contains", "@iexact", "@niexact")
      like = (q = JL.Json_scratch.objects; q.filter("payload__$(lookup)" => "hamilton"); q.values("id"); q)
      @test (lookup, occursin("AS JSON", _sql(like; conn = _JL_MY)[:sql_text])) == (lookup, false)
    end
    # An empty list is the membership that matches nothing, as on every engine, not `CAST( AS JSON)`.
    none = (q = JL.Json_scratch.objects; q.filter("payload__@in" => String[]); q.values("id"); q)
    @test !occursin("AS JSON", _sql(none; conn = _JL_MY)[:sql_text])
    @test _sql(none; conn = _JL_MY)[:sql_text] == replace(_sql(none; conn = _JL_SL)[:sql_text], '"' => '`')
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #1382: an alias over a key lookup compares as the key lookup does
  # What: `values("d" => F("payload__driver"))` then `filter`/`Q` on `d`, on the three engines.
  # Expected SQL: the key lookup's own comparison — `#>> '{"driver"}' = $1` bound text on PostgreSQL,
  # `json_extract(…) = ?` bound native on SQLite, `(JSON_UNQUOTE(…)) = ?` on MySQL; an ordering casts
  # `::numeric` on PostgreSQL and binds a number; `@isnull` is `IS NULL`; a pattern lookup binds text.
  # Why: the alias was typed as the JSONField, so a plain string raised InvalidValueError, a number
  # bound as the text "5" (no row on SQLite, where `json_extract` returns 5), and an ordering
  # compared text on PostgreSQL — while `filter("payload__driver" => …)` did none of this.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an alias over a key lookup compares as the key lookup does (#1382)" begin
    keyed(key, value; q_wrap = false) = (q = JL.Json_scratch.objects; q.values("id", "d" => F("payload__driver"));
                                         q.filter(q_wrap ? Q(key => value) : key => value); q)
    direct(key, value; q_wrap = false) = (q = JL.Json_scratch.objects; q.values("id", "d" => F("payload__driver"));
                                          k = replace(key, r"^d" => "payload__driver");
                                          q.filter(q_wrap ? Q(k => value) : k => value); q)
    for conn in (_JL_PG, _JL_SL, _JL_MY), (key, value) in (("d", "hamilton"), ("d", 5), ("d__@gt", 5),
                                                           ("d__@lte", 2.5), ("d__@ne", "x"), ("d__@isnull", true))
      for wrap in (false, true)
        a = _sql(keyed(key, value; q_wrap = wrap); conn = conn)
        b = _sql(direct(key, value; q_wrap = wrap); conn = conn)
        # The same predicate and the same bound value as the key lookup itself.
        where(r) = last(split(r[:sql_text], "WHERE "))
        @test (typeof(conn), key, wrap, where(a), a[:parameters]) == (typeof(conn), key, wrap, where(b), b[:parameters])
      end
    end
    @test occursin("(\"Tb\".\"payload\" #>> '{\"driver\"}')::numeric > \$1", _sql(keyed("d__@gt", 5); conn = _JL_PG)[:sql_text])
    @test _sql(keyed("d", 5); conn = _JL_SL)[:parameters] == Any[5]
    @test _sql(keyed("d", 5); conn = _JL_PG)[:parameters] == Any["5"]
    # A pattern lookup and a membership list are refused, as on the key lookup (#1499).
    @test_throws PormG.FilterError _sql(keyed("d__@contains", "ham"); conn = _JL_PG)
    @test_throws PormG.FilterError _sql(keyed("d__@in", ["a", "b"]); conn = _JL_SL)
    # An alias over the whole document keeps the JSON formatter and the #1360 marker.
    whole = (q = JL.Json_scratch.objects; q.values("id", "p" => F("payload")); q.filter("p" => "notjson"); q)
    @test_throws PormG.InvalidValueError _sql(whole; conn = _JL_PG)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #1381: a `When` condition on a projection alias binds as the alias's `Q` binds
  # What: `values(alias => F(col))` then `Case([When(alias => v, then = 1)], default = 0)`, in a filter
  # and in the projection, for an alias over a JSON document, a JSON key, a date and a number.
  # Expected SQL: the `Q(alias => v)` predicate's own value and marker inside `CASE WHEN … THEN`:
  # `CAST(? AS JSON)` for a whole document on MySQL, a date bound as its text, a number as the
  # integer formatter binds it; an invalid value raises InvalidValueError as `Q` does.
  # Why: the `When` arm bound the value raw, so on MySQL a document was compared as a JSON string
  # scalar (no row), and on every engine an invalid date or number was sent to the database.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a When condition on a projection alias binds as Q does (#1381)" begin
    doc = "{\"driver\":\"hamilton\"}"
    projected(alias, src) = (q = JW.Lap_scratch.objects; q.values("id", alias => src); q)
    when_q(alias, src, key, v) = (q = projected(alias, src); q.filter(Case([When(key => v, then = 1)], default = 0) == 1); q)
    q_q(alias, src, key, v) = (q = projected(alias, src); q.filter(Q(key => v)); q)
    cases = (("p", F("payload"), "p", doc), ("p", F("payload"), "p__@ne", doc), ("p", F("payload"), "p__@in", [doc]),
             ("k", F("payload__driver"), "k", "hamilton"), ("k", F("payload__driver"), "k__@gt", 5),
             ("dd", F("day"), "dd", Date(2020, 1, 2)), ("dd", F("day"), "dd__@in", [Date(2020, 1, 2)]),
             ("n", F("laps"), "n", 2.5), ("n", F("laps"), "n__@gte", 5), ("n", F("laps"), "n__@range", [1, 9]),
             ("dd", F("day"), "dd__@range", [Date(2020, 1, 1), Date(2020, 2, 1)]))
    for conn in (_JL_PG, _JL_SL, _JL_MY), (alias, src, key, v) in cases
      w = _sql(when_q(alias, src, key, v); conn = conn)
      q = _sql(q_q(alias, src, key, v); conn = conn)
      # The `When` predicate is the `Q` one; its bound value comes first, before THEN's and ELSE's.
      pred = strip(last(split(q[:sql_text], "WHERE ")))
      pred = pred[nextind(pred, 1):prevind(pred, lastindex(pred))]   # the `Q`'s own parentheses
      @test (typeof(conn), key, occursin("CASE WHEN $(pred) THEN", replace(w[:sql_text], r"\s+" => " ")),
             w[:parameters][1:length(q[:parameters])]) == (typeof(conn), key, true, q[:parameters])
    end
    # The same condition inside the projection.
    sel = (q = projected("p", F("payload")); q.values("id", "p" => F("payload"), "w" => Case([When("p" => doc, then = 1)], default = 0)); q)
    @test occursin("WHEN `Tb`.`payload` = CAST(? AS JSON) THEN", _sql(sel; conn = _JL_MY)[:sql_text])
    # An invalid value raises as the `Q` spelling does, on every engine.
    for conn in (_JL_PG, _JL_SL, _JL_MY), (alias, src, v) in (("p", F("payload"), "notjson"), ("dd", F("day"), "not-a-date"),
                                                             ("n", F("laps"), "five"))
      @test_throws PormG.InvalidValueError _sql(when_q(alias, src, alias, v); conn = conn)
      @test_throws PormG.InvalidValueError _sql(q_q(alias, src, alias, v); conn = conn)
    end
    @test_throws PormG.InvalidValueError _sql(when_q("dd", F("day"), "dd__@range", ["x", "y"]); conn = _JL_PG)
    # `@isnull` on an alias over a key lookup renders as the key lookup's own `IS NULL`, on SQLite too,
    # where the generic arm refused a `json_extract(…)` column (FilterError).
    @test occursin("WHEN json_extract(\"Tb\".\"payload\", '\$.driver') IS NULL THEN",
                   _sql(when_q("k", F("payload__driver"), "k__@isnull", true); conn = _JL_SL)[:sql_text])
    # #1507: a column expression on the right of an alias over a key is refused as on the key (#811). It
    # rendered as a column comparison, which on PostgreSQL compared the key's text with a bigint.
    for conn in (_JL_PG, _JL_SL, _JL_MY)
      q = projected("k", F("payload__driver")); q.filter("k" => F("id"))
      @test_throws PormG.FilterError _sql(q; conn = conn)
      @test_throws PormG.FilterError _sql(when_q("k", F("payload__driver"), "k", F("id")); conn = conn)
      # An alias over a column that is not a key still compares with a column: no value to bind or check.
      qt = conn isa PormG.PormGMySQL ? "`" : "\""
      idcol = "= $(qt)Tb$(qt).$(qt)id$(qt)"
      w = _sql(when_q("n", F("laps"), "n", F("id")); conn = conn)
      @test (typeof(conn), occursin(idcol, w[:sql_text])) == (typeof(conn), true)
      # A queryset on the right keeps its refusal: it needs a membership operator.
      @test_throws PormG.FilterError _sql(when_q("k", F("payload__driver"), "k", JL.Json_scratch.objects); conn = conn)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The same document through a projection alias and through `F("payload") ==` (#1360)
  # Both bound a bare marker on MySQL, so each matched no row with no error; and `F ==` bound
  # `$1::text` on PostgreSQL, `jsonb = text`, which has no operator (measured: SQLSTATE 42883).
  # Expected SQL: MySQL `CAST(? AS JSON)` for `=`, `@ne`, `@in` on the alias and for `F ==`/`!=`; a
  # pattern lookup on the alias and a key lookup either way stay bare; PostgreSQL binds an uncast `$1`
  # (typed from the jsonb column, as the filter arm binds it) and SQLite a bare `?`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a whole JSON document through an alias or F(...) == (#1360)" begin
    doc = "{\"driver\":\"hamilton\"}"
    other = "{\"driver\":\"max\"}"
    aliased(key, value) = (q = JL.Json_scratch.objects; q.values("id", "p" => F("payload")); q.filter(key => value); q)
    my = _sql(aliased("p", doc); conn = _JL_MY)
    @test occursin("WHERE `Tb`.`payload` = CAST(? AS JSON)", my[:sql_text])
    @test my[:parameters] == Any[doc]
    @test occursin(r"`Tb`.`payload` (<>|!=) CAST\(\? AS JSON\)", _sql(aliased("p__@ne", doc); conn = _JL_MY)[:sql_text])
    my_in = _sql(aliased("p__@in", [doc, other]); conn = _JL_MY)
    @test occursin("IN (CAST(? AS JSON), CAST(? AS JSON))", my_in[:sql_text]) && my_in[:parameters] == Any[doc, other]
    # A pattern lookup on the alias binds text, as on the column.
    @test !occursin("AS JSON", _sql(aliased("p__@contains", "ham"); conn = _JL_MY)[:sql_text])
    # PostgreSQL and SQLite keep the bare marker: they compare the document already.
    @test occursin("WHERE \"Tb\".\"payload\" = \$1\n", _sql(aliased("p", doc); conn = _JL_PG)[:sql_text])
    @test occursin("WHERE \"Tb\".\"payload\" = ?\n", _sql(aliased("p", doc); conn = _JL_SL)[:sql_text])

    compared(expr) = (q = JL.Json_scratch.objects; q.filter(expr); q.values("id"); q)
    my_eq = _sql(compared(F("payload") == doc); conn = _JL_MY)
    @test occursin("WHERE (`Tb`.`payload` = CAST(? AS JSON))", my_eq[:sql_text])
    @test my_eq[:parameters] == Any[doc]
    @test occursin("WHERE (`Tb`.`payload` != CAST(? AS JSON))", _sql(compared(F("payload") != doc); conn = _JL_MY)[:sql_text])
    @test occursin("WHERE (\"Tb\".\"payload\" = \$1)", _sql(compared(F("payload") == doc); conn = _JL_PG)[:sql_text])
    @test occursin("WHERE (\"Tb\".\"payload\" = ?)", _sql(compared(F("payload") == doc); conn = _JL_SL)[:sql_text])
    # A document holding `__` is still a document, not a field path (review of #1360: it raised
    # `UnknownFieldError: the column {" not found`); a JSON scalar document is one too.
    typename = "{\"__typename\":\"Driver\"}"
    my_tn = _sql(compared(F("payload") == typename); conn = _JL_MY)
    @test occursin("WHERE (`Tb`.`payload` = CAST(? AS JSON))", my_tn[:sql_text]) && my_tn[:parameters] == Any[typename]
    @test occursin("CAST(? AS JSON)", _sql(compared(F("payload") == "5"); conn = _JL_MY)[:sql_text])
    # A column name on the right is still that column (`F("payload") == "name"`), not a document.
    @test occursin("WHERE (`Tb`.`payload` = `Tb`.`name`)", _sql(compared(F("payload") == "name"); conn = _JL_MY)[:sql_text])
    # An alias that is not the document (a COUNT) keeps the bare marker: the wrap is the document's only.
    counted = (q = JL.Json_scratch.objects; q.values("name", "n" => PormG.QueryBuilder.Count("id")); q.filter("n" => 2); q)
    my_n = _sql(counted; conn = _JL_MY)[:sql_text]
    @test occursin("HAVING COUNT(`Tb`.`id`) = ?", my_n) && !occursin("CAST(? AS JSON)", my_n)
    # A key lookup is that key's text, not a document: bare on MySQL, and on PostgreSQL the bare marker
    # the filter pair binds (#1511: it was the generic path's `$1::text` before).
    # (The extraction itself holds `CAST('null' AS JSON)`, so the needle is the bound marker.)
    my_key = _sql(compared(F("payload__driver") == "hamilton"); conn = _JL_MY)[:sql_text]
    @test !occursin("CAST(? AS JSON)", my_key) && occursin("utf8mb4_0900_bin) = ?)", my_key)
    @test occursin("#>> '{\"driver\"}' = \$1)", _sql(compared(F("payload__driver") == "hamilton"); conn = _JL_PG)[:sql_text])
  end

end

# ─────────────────────────────────────────────────────────────────────────────
# #1458 (#1034 phase 4, D1): the walk names a key lookup the key's value, `CJSONValue`, not the document
# Before, `_expression_kind("payload__n")` was the document's `CJSON()`, and four readers told a key from
# the document by the record of rendered lookups instead. Expected, on PostgreSQL, SQLite and MySQL:
# the document is `CJSON()` and a key lookup `CJSONValue()` — alone, as a CTE column the outer query
# reads (which recorded no kind before), and as `Max` over the key under a CTE (which the outer query
# read as the document). That last column now builds in `Concat` and in `Coalesce` beside text, as the
# same `Max` already did alone: it raised #1028 ("the JSONField … is not text") and #1386 ("mixes a JSON
# document"). The bare lookup keeps the JSON formatter (#1382). Why it matters: one answer for what a key
# lookup is, in every context, instead of a patch per reader.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1458: a JSON key lookup is the key's value to the walk, in every context" begin
  QB = PormG.QueryBuilder
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @testset "$(nameof(typeof(conn)))" begin
      # The walk's answers, asked of the built instruction while `query` holds it (its `built` callback).
      asked(q, f) = (r = Ref{Any}(); QB.query(q; connection = conn, show_query = :sql, built = i -> (r[] = f(i))); r[])
      node(i, name) = QB._projected_source(QB.memo_key(:base, name), i).field
      # Alone: the document and a key lookup.
      q = JL.Json_scratch.objects
      q.values("id", "d" => "payload", "k" => "payload__n")
      alone = asked(q, i -> (d = QB._expression_kind(node(i, "d"), i), k = QB._expression_kind(node(i, "k"), i),
        kformat = QB._expression_formatter(node(i, "k"), i),
        ddoc = QB._json_document_operand(node(i, "d"), i), kdoc = QB._json_document_operand(node(i, "k"), i),
        kkey = QB._json_key_lookup_operand(node(i, "k"), i), dkey = QB._json_key_lookup_operand(node(i, "d"), i)))
      @test alone.d == PormG.CJSON()
      @test alone.k == QB.CJSONValue()
      # The bare lookup keeps the JSON formatter (#1382's alias comparison reads the lookup, not it).
      @test alone.kformat === PormG.Models.format_json_sql
      # The readers that told the two apart now read the walk.
      @test alone.ddoc && !alone.kdoc
      @test alone.kkey && !alone.dkey

      # Under a CTE: the body records each column's kind, so the outer query reads the same answers.
      body = JL.Json_scratch.objects
      body.values("id", "d" => "payload", "k" => "payload__n")
      outer = JL.Json_scratch.objects
      outer.with("g" => body, join_field = "id" => "id", join_type = "INNER")
      outer.values("id", "gd" => "g__d", "gk" => "g__k")
      ctek = asked(outer, i -> Tuple(QB._expression_kind(node(i, n), i) for n in ("gd", "gk")))
      @test ctek == (PormG.CJSON(), QB.CJSONValue())

      # A CTE column that is the key's value joins text and sits beside it. (`Max` was the seed until #1491
      # refused it over an uncast key, and `NullIf(key, 0)` until #1510 did; the bare key is what is left.)
      lifted(expr) = (o = JL.Json_scratch.objects;
        o.with("g" => JL.Json_scratch.objects.values("id", "v" => "payload__n"), join_field = "id" => "id", join_type = "INNER");
        o.values("id", "w" => expr); o)
      nullif_body = (o = JL.Json_scratch.objects;
        o.with("g" => JL.Json_scratch.objects.values("id", "v" => QB.NullIf("payload__n", 0)), join_field = "id" => "id", join_type = "INNER");
        o.values("id", "g__v"); o)
      @test_throws PormG.QueryBuildError _sql(nullif_body; conn = conn)
      @test occursin("\"v\"", replace(_sql(lifted(PormG.Functions.Concat(PormG.Functions.Value("n="), "g__v")); conn = conn)[:sql_text], "`" => "\""))
      @test occursin("COALESCE(", _sql(lifted(PormG.Functions.Coalesce("g__v", PormG.Functions.Value("x"))); conn = conn)[:sql_text])
      # `LPad` reads the same answer (`_pad_textless`): it raised #122 ("the JSONField … is not text").
      @test occursin(r"(?i)lpad\(", _sql(lifted(PormG.Functions.LPad("g__v", 5, "0")); conn = conn)[:sql_text])
      # The whole document under a CTE is still refused in `Concat`, as the column is (#1028).
      doc = (o = JL.Json_scratch.objects;
        o.with("g" => JL.Json_scratch.objects.values("id", "v" => "payload"), join_field = "id" => "id", join_type = "INNER");
        o.values("id", "w" => PormG.Functions.Concat(PormG.Functions.Value("n="), "g__v")); o)
      @test_throws PormG.QueryBuildError _sql(doc; conn = conn)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1483 (was #1471): arithmetic, a Sum or an Avg over an uncast JSON key is refused on every engine
# A JSON key's value has no declared type: the document decides, row by row, whether it is an integer,
# a float or text. Arithmetic on it does not say which number it computes on, and the engines answer
# differently: SQLite's `json_extract` hands over the integer the document holds, so `FLOOR(…) / ?`
# divided as integers (`7 / 2` was `3`); PostgreSQL's `#>>` is text, which `+`, `/` and `sum` reject at
# the server. Expected: every shape below raises `QueryBuildError` on PostgreSQL, SQLite and MySQL
# alike, naming the key, the operation, and the explicit spelling (`Cast("payload__n", "numeric")`),
# and no engine. A value that names its number builds on every engine: `Cast(key, "numeric") / 2`
# renders `(CAST(CAST(json_extract(…) AS NUMERIC) AS REAL) / ?)` on SQLite and
# `((… #>> '{"n"}')::decimal / $1::bigint)` on PostgreSQL; `Round` (a `numeric` function) and
# `NullIf("id", Cast(key, "numeric"))`, whose value is the integer `id`, build too, and so does a function over the key
# with nothing computed on it (`Floor(key)`). An extremum over the key is #1491's, below.
# Why it matters: the SQLite answer was a different value with nothing to say so, and PostgreSQL's
# error, raised only when the query ran, named neither the key nor the cast to write.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1483: arithmetic, Sum or Avg over an uncast JSON key is refused on every engine" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  proj(expr) = (q = JL.Json_scratch.objects; q.values("v" => expr); q)
  plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  for (label, op, expr) in (
      ("the key / 2", "`/`", () -> QB.F("payload__n") / 2),
      ("the key + 1", "`+`", () -> QB.F("payload__n") + 1),
      ("the key - 1", "`-`", () -> QB.F("payload__n") - 1),
      ("the key * 2", "`*`", () -> QB.F("payload__n") * 2),
      ("the key * 1.0", "`*`", () -> QB.F("payload__n") * 1.0),
      ("the key / 2.0", "`/`", () -> QB.F("payload__n") / 2.0),
      ("a column + the key", "`+`", () -> QB.F("id") + QB.F("payload__n")),
      ("the divisor", "`/`", () -> QB.F("id") / FN.Floor("payload__n")),
      ("Floor", "`/`", () -> FN.Floor("payload__n") / 2),
      ("Ceil", "`/`", () -> FN.Ceil("payload__n") / 2),
      ("Abs", "`/`", () -> FN.Abs("payload__n") / 2),
      ("Coalesce", "`/`", () -> FN.Coalesce("payload__n", 0) / 2),
      ("Coalesce beside a float", "`/`", () -> FN.Coalesce("payload__n", 0.5) / 2),
      ("a Case branch", "`/`", () -> QB.Case([QB.When("id" => 1, then = QB.F("payload__n"))], default = 0) / 2),
      ("Sum", "Sum", () -> FN.Sum("payload__n")),
      ("Avg", "Avg", () -> FN.Avg("payload__n")),
      ("Sum / 2", "Sum", () -> FN.Sum("payload__n") / 2),
      ("Sum of Coalesce", "Sum", () -> FN.Sum(FN.Coalesce("payload__n", 0))))
    @testset "$label on $(nameof(typeof(conn)))" for conn in (_JL_PG, _JL_SL, _JL_MY)
      e = try _sql(proj(expr()); conn = conn); nothing catch err; err end
      @test e isa PormG.QueryBuildError
      msg = e === nothing ? "" : plain(e)
      @test startswith(msg, "$(op) over ")
      @test occursin("JSON key `payload__n`", msg)
      @test occursin("has no declared type", msg)
      @test occursin("(#1483)", msg)
      @test occursin("Cast(\"payload__n\", \"numeric\")", msg)
      @test occursin("Cast(\"payload__n\", BigIntegerField())", msg)
      @test !occursin("PostgreSQL", msg) && !occursin("SQLite", msg) && !occursin("MySQL", msg)
    end
  end
  # A value that names its number builds on every engine, with the SQL it always had.
  @test occursin("(CAST(CAST(json_extract(\"Tb\".\"payload\", '\$.n') AS NUMERIC) AS REAL) / ?)",
                 _sql(proj(FN.Cast("payload__n", "numeric") / 2); conn = _JL_SL)[:sql_text])
  @test occursin("((\"Tb\".\"payload\" #>> '{\"n\"}')::decimal / \$1::bigint)",
                 _sql(proj(FN.Cast("payload__n", "numeric") / 2); conn = _JL_PG)[:sql_text])
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @test _sql(proj(FN.Cast("payload__n", "numeric") + 1); conn = conn) isa AbstractDict
    @test _sql(proj(FN.Sum(FN.Cast("payload__n", "numeric"))); conn = conn) isa AbstractDict
    @test _sql(proj(FN.Round("payload__n") / 2); conn = conn) isa AbstractDict
    # A function over the key with nothing computed on it is the key's own value.
    @test _sql(proj(FN.Floor("payload__n")); conn = conn) isa AbstractDict
  end
  # `NullIf`'s value is its first operand, here the integer `id`, whose quotient is the meaning. It
  # compares `id` with the key, though, so the key states its type (#1510; uncast it is refused, below).
  @test occursin("(NULLIF(\"Tb\".\"id\", CAST(json_extract(\"Tb\".\"payload\", '\$.n') AS NUMERIC)) / ?)",
                 _sql(proj(FN.NullIf("id", FN.Cast("payload__n", "numeric")) / 2); conn = _JL_SL)[:sql_text])
  # A comparison is not arithmetic: the key lookup's own filter binds it (#1382).
  @test _sql((q = JL.Json_scratch.objects; q.filter("payload__n__@gt" => 5); q); conn = _JL_PG) isa AbstractDict
  # Wherever the arithmetic renders: a filter value, a CTE body, an `update()` value. (`order_by` takes
  # no expression; ordering by a projected alias goes through the projection, refused above.)
  arith() = QB.F("payload__n") + 1
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    for (label, run) in (
        ("filter value", () -> _sql((q = JL.Json_scratch.objects; q.filter("id__@gt" => arith()); q); conn = conn)),
        ("CTE body",     () -> _sql((b = JL.Json_scratch.objects; b.values("id", "w" => arith());
                                     q = JL.Json_scratch.objects; q.with("c" => b, join_field = "id" => "id");
                                     q.values("id", "c__w"); q); conn = conn)))
      e = try run(); nothing catch err; err end
      @test e isa PormG.QueryBuildError && occursin("(#1483)", plain(e))
    end
  end
  # `update()` builds on the model's own connection (the mock SQLite here): the SET value refuses too.
  e = try (q = JL.Json_scratch.objects; q.filter("id" => 1); q.update("name" => arith(); show_query = :sql)); nothing catch err; err end
  @test e isa PormG.QueryBuildError && occursin("(#1483)", plain(e))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1491: a Max or a Min over an uncast JSON key is refused on every engine
# An extremum computes nothing on the key's value, but it orders it, and the document decides whether
# that value is a number or text. PostgreSQL's `#>>` extracts text, so over `{"n": 9}` and `{"n": 10}`
# `MAX("Tb"."payload" #>> '{"n"}')` was `"9"` (`'9' > '10'`) and `MIN` was `"10"`; SQLite's
# `json_extract` hands over the number, so it answered `10` and `9`. Same query, different values,
# nothing reported. Expected: `Max`/`Min` over the key, or over a value that carries it (`Floor`, a
# `Case` branch, a CTE column projecting it), raises `QueryBuildError` on PostgreSQL,
# SQLite and MySQL alike (explicit intent, as #1483), naming the key and both spellings:
# `Cast(key, "numeric")` orders numbers, `Cast(key, "text")` orders text. Each spelling builds
# (PostgreSQL `MAX(("Tb"."payload" #>> '{"n"}')::decimal)`), and so does `Max` over a typed column.
# Why it matters: the PostgreSQL answer was another row's value, as a `String`, with nothing to say so.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1491: Max or Min over an uncast JSON key is refused on every engine" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  proj(expr) = (q = JL.Json_scratch.objects; q.values("v" => expr); q)
  plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  refusal(q, conn) = try _sql(q; conn = conn); nothing catch err; err end
  withcte(colexpr, outer) = (q = JL.Json_scratch.objects;
    q.with("c" => JL.Json_scratch.objects.values("id", "w" => colexpr), join_field = "id" => "id");
    q.values("v" => outer); q)
  for (label, op, expr) in (
      ("Max", "Max", () -> FN.Max("payload__n")),
      ("Min", "Min", () -> FN.Min("payload__n")),
      ("Max over Floor", "Max", () -> FN.Max(FN.Floor("payload__n"))),
      ("Min over a Case branch", "Min", () -> FN.Min(QB.Case([QB.When("id" => 1, then = QB.F("payload__n"))], default = QB.F("payload__n")))),
      ("Max / 2", "Max", () -> FN.Max("payload__n") / 2))
    @testset "$label on $(nameof(typeof(conn)))" for conn in (_JL_PG, _JL_SL, _JL_MY)
      e = refusal(proj(expr()), conn)
      @test e isa PormG.QueryBuildError
      msg = e === nothing ? "" : plain(e)
      @test startswith(msg, "$(op) over ")
      @test occursin("JSON key `payload__n`", msg)
      @test occursin("whether it orders numbers or text (#1491)", msg)
      @test occursin("Cast(\"payload__n\", \"numeric\")", msg)
      @test occursin("Cast(\"payload__n\", \"text\")", msg)
      @test !occursin("PostgreSQL", msg) && !occursin("SQLite", msg) && !occursin("MySQL", msg)
    end
  end
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @testset "the CTE column and the spellings on $(nameof(typeof(conn)))" begin
      # Over a CTE column that is the key's value, in the outer query.
      e = refusal(withcte("payload__n", FN.Max(PormG.CTE("c", "w"))), conn)
      @test e isa PormG.QueryBuildError
      @test e !== nothing && startswith(plain(e), "Max over the CTE column") && occursin("(#1491)", plain(e))
      # Each spelling builds, as does an extremum over a typed column.
      for expr in (FN.Max(FN.Cast("payload__n", "numeric")), FN.Min(FN.Cast("payload__n", "text")), FN.Max("id"))
        @test _sql(proj(expr); conn = conn) isa AbstractDict
      end
      @test _sql(withcte(FN.Cast("payload__n", "numeric"), FN.Max(PormG.CTE("c", "w"))); conn = conn) isa AbstractDict
    end
  end
  # The spelled SQL: PostgreSQL orders the numeric cast, not the text.
  @test occursin("MAX((\"Tb\".\"payload\" #>> '{\"n\"}')::decimal)",
                 _sql(proj(FN.Max(FN.Cast("payload__n", "numeric"))); conn = _JL_PG)[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# #1482: arithmetic over a CTE column or a Subquery that carries an uncast JSON key is refused
# A CTE body or a `Subquery` projection can carry a key's value with no arithmetic of its own, and its
# column's kind need not say so: `Lag("id"; default = F(key))` is typed by `id`, an integer, though the
# key is its value on the rows the default applies to; a `Subquery` is typed by its inner build. Outer
# arithmetic over it computed on the key: on SQLite `(COALESCE("R1_1"."w", ?) / ?)` divided the integer
# the document holds as one (`7 / 2` was `3`). Expected: the body records the key
# (`CTEDivision.json_key`, `subquery_json_key`), and arithmetic over the column refuses as over the key
# (#1483) on every engine, naming the CTE column or the Subquery, what its body is, and the key's cast.
# The other routes in: a body column that IS the key's value (the key itself) refuses through its
# kind (`CJSONValue`); a body that sums, orders or compares the key refuses itself (#1483, #1491,
# #1510's `NullIf`); one that mixes the
# key with a literal (`Coalesce(key, 0)`) is refused while the column is typed (#823). A body that casts
# the key, or declares its number (`output_field`), builds outside.
# Why it matters: the SQLite answer was a different value with nothing to say so.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1482: arithmetic over a CTE column or a Subquery carrying a JSON key is refused" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  function withcte(colexpr, outer)
    q = JL.Json_scratch.objects
    body = JL.Json_scratch.objects
    body.values("id", "w" => colexpr)
    q.with("c" => body, join_field = "id" => "id")
    q.values("v" => outer)
    return q
  end
  sub(expr) = QB.Subquery((s = JL.Json_scratch.objects; s.filter("id" => 1); s.values("v" => expr); s))
  proj(expr) = (q = JL.Json_scratch.objects; q.values("v" => expr); q)
  refusal(q, conn) = try _sql(q; conn = conn); nothing catch err; err end
  lag_default_key() = QB.Lag("id"; default = QB.F("payload__n"), over = QB.WindowOver(order_by = ["id"]))
  half(col) = FN.Coalesce(col, 0) / 2
  function refused_1483(q, conn, named)
    e = refusal(q, conn)
    @test e isa PormG.QueryBuildError
    msg = e === nothing ? "" : plain(e)
    @test occursin("(#1483)", msg)
    @test occursin(named, msg)
    @test occursin("Cast(\"", msg)
    return msg
  end
  # The record: a window body whose kind is its integer column. (SQLite's mock renders no window
  # function without its driver, so this route is pinned on PostgreSQL and MySQL.)
  for conn in (_JL_PG, _JL_MY)
    msg = refused_1483(withcte(lag_default_key(), half(PormG.CTE("c", "w"))), conn, "the CTE column `CTE(\"c\", \"w\")`")
    @test occursin("`LAG(…)` over the JSON key `payload__n`", msg)
    refused_1483(withcte(lag_default_key(), FN.Floor(PormG.CTE("c", "w")) + 1), conn, "the CTE column")
    @test _sql(withcte(lag_default_key(), PormG.CTE("c", "w")); conn = conn) isa AbstractDict
  end
  # An `OuterRef` to the outer query's key carries it into a `Subquery`, typed on the outer query.
  outer_sub(expr) = QB.Subquery((s = JL.Json_scratch.objects; s.filter("id" => QB.OuterRef("id")); s.values("v" => expr); s))
  for conn in (_JL_PG, _JL_MY)
    msg = refused_1483(proj(outer_sub(FN.Coalesce(QB.OuterRef("payload__n"), 0) / 2)), conn, "of the outer query")
    @test occursin("`OuterRef`", msg)
  end
  # The control (MySQL refuses an `OuterRef` side it cannot type in `/`, #1130, so PostgreSQL only).
  @test _sql(proj(outer_sub(FN.Coalesce(QB.OuterRef("id"), 0) / 2)); conn = _JL_PG) isa AbstractDict
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @testset "$(nameof(typeof(conn)))" begin
      # The Subquery record: a projection carrying the key, or the key itself.
      for inner in (FN.Coalesce("payload__n", 0), QB.F("payload__n"))
        msg = refused_1483(proj(half(sub(inner))), conn, "a Subquery projecting")
        @test occursin("JSON key `payload__n`", msg)
        @test occursin("Cast(\"payload__n\", \"numeric\")", msg)
      end
      @test _sql(proj(half(sub(FN.Cast("payload__n", "numeric")))); conn = conn) isa AbstractDict
      # Through the column's kind: a body column that is the key's value.
      refused_1483(withcte("payload__n", half(PormG.CTE("c", "w"))), conn, "JSON key")
      # A body that sums, orders or compares the key refuses itself; one that mixes it with a literal is
      # refused as untyped.
      e = refusal(withcte(FN.NullIf("payload__n", 0), half(PormG.CTE("c", "w"))), conn)
      @test e isa PormG.QueryBuildError && startswith(plain(e), "`NullIf` over the JSON key `payload__n`")
      e = refusal(withcte(FN.Sum("payload__n"), half(PormG.CTE("c", "w"))), conn)
      @test e isa PormG.QueryBuildError && startswith(plain(e), "Sum over the JSON key `payload__n`")
      e = refusal(withcte(FN.Max("payload__n"), half(PormG.CTE("c", "w"))), conn)
      @test e isa PormG.QueryBuildError && startswith(plain(e), "Max over the JSON key `payload__n`")
      e = refusal(withcte(FN.Coalesce("payload__n", 0), half(PormG.CTE("c", "w"))), conn)
      @test e isa PormG.QueryBuildError && occursin("(#823)", plain(e))
      # A body that names the number builds outside, as does one with no key.
      for body in (FN.Cast("payload__n", "numeric"), FN.Coalesce("payload__n", 0; output_field = "integer"), FN.Coalesce("id", 0))
        @test _sql(withcte(body, half(PormG.CTE("c", "w"))); conn = conn) isa AbstractDict
      end
      # The spelling names the body's key path, where the cast goes, whether the body computed over the
      # key or projected it bare (never a `"<flag>"` placeholder); the spelled body then builds outside.
      for body in ("payload__n",)
        msg = refused_1483(withcte(body, half(PormG.CTE("c", "w"))), conn, "the CTE column")
        @test occursin("Cast(\"payload__n\", \"numeric\")", msg) && !occursin("<flag>", msg)
      end
      @test _sql(withcte(FN.Cast("payload__n", "numeric"), half(PormG.CTE("c", "w"))); conn = conn) isa AbstractDict
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1472: a filter on a CTE column over a JSON key lookup compares as the key lookup does
# A CTE column whose body projects `payload__driver` holds the key's value, which the
# walk names `CJSONValue` (#1458). The outer filter bound through the column's field, the document's
# JSONField: equality ran the JSON formatter and refused plain text ("The text is not valid JSON"), and
# an ordering bound the number as text (`"R1_1"."k" > $1` with `'5'` on PostgreSQL, a text comparison;
# `CAST(? AS JSON)` on MySQL). Expected, as `filter("payload__driver" => …)` binds (#1382):
# PostgreSQL `"R1_1"."k" = $1` with `"hamilton"` and `("R1_1"."k")::numeric > $1` with `5`; SQLite
# `"R1_1"."k" = ?` and `"R1_1"."k" > ?` with the native values; MySQL `` `R1_1`.`k` = ? `` and
# `` `R1_1`.`k` > ? ``. A whole-document column keeps the JSON formatter (#1360): a document binds,
# plain text is refused.
# Why it matters: the equality was unusable, and the ordering returned the rows a text comparison picks.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1472: a filter on a CTE column over a JSON key binds as the key lookup does" begin
  FN = PormG.Functions
  function filtered(col, filt)
    body = JL.Json_scratch.objects
    body.values("id", "k" => col)
    q = JL.Json_scratch.objects
    q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
    q.values("id", "g__k")
    q.filter(filt)
    return q
  end
  where(r) = replace(r[:sql_text], r"\s+" => " ")
  for col in ("payload__driver",)   # (`NullIf` of it was the second until #1510 refused it, below)
    r = _sql(filtered(col, "g__k" => "hamilton"); conn = _JL_PG)
    @test occursin("WHERE \"R1_1\".\"k\" = \$1", where(r)) && r[:parameters] == ["hamilton"]
    r = _sql(filtered(col, "g__k" => "hamilton"); conn = _JL_SL)
    @test occursin("WHERE \"R1_1\".\"k\" = ?", where(r)) && r[:parameters] == ["hamilton"]
    r = _sql(filtered(col, "g__k" => "hamilton"); conn = _JL_MY)
    @test occursin("WHERE `R1_1`.`k` = ?", where(r)) && r[:parameters] == ["hamilton"]
  end
  # A number for an equality binds as the key lookup binds it: text on PostgreSQL and MySQL, the native
  # number on SQLite (where it bound the text `"121"` before, which an integer never equals there).
  @test _sql(filtered("payload__n", "g__k" => 121); conn = _JL_PG)[:parameters] == ["121"]
  @test _sql(filtered("payload__n", "g__k" => 121); conn = _JL_SL)[:parameters] == [121]
  @test _sql(filtered("payload__n", "g__k" => 121); conn = _JL_MY)[:parameters] == ["121"]
  r = _sql(filtered("payload__n", "g__k__@gt" => 5); conn = _JL_PG)
  @test occursin("WHERE (\"R1_1\".\"k\")::numeric > \$1", where(r)) && r[:parameters] == [5]
  r = _sql(filtered("payload__n", "g__k__@gt" => 5); conn = _JL_SL)
  @test occursin("WHERE \"R1_1\".\"k\" > ?", where(r)) && r[:parameters] == [5]
  r = _sql(filtered("payload__n", "g__k__@gt" => 5); conn = _JL_MY)
  @test occursin("WHERE `R1_1`.`k` > ?", where(r)) && r[:parameters] == [5]
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @test occursin("\"k\" IS NULL", replace(where(_sql(filtered("payload__driver", "g__k__@isnull" => true); conn = conn)), "`" => "\""))
    # A whole-document column keeps the JSON formatter: a document binds, plain text is refused.
    @test _sql(filtered("payload", "g__k" => """{"a": 1}"""); conn = conn) isa AbstractDict
    @test_throws PormG.InvalidValueError _sql(filtered("payload", "g__k" => "hamilton"); conn = conn)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1492: a filter on a Subquery alias over a JSON key binds as the key lookup does
# A `Subquery` is its one projected column (#888), so one that projects `payload__n` holds the key's
# value, which the walk names `CJSONValue`. A filter on its projection alias bound through the
# document's JSON formatter: `w__@gt => 100` bound the text `"100"` on every engine, a text comparison
# on PostgreSQL (`'99' > '100'` is true) and never true on SQLite, where a number is never greater than
# text. #1472 fixed the same defect for a CTE column. Expected, as `filter("payload__n" => …)` binds
# (#1382): PostgreSQL `((SELECT … #>> '{"n"}' …))::numeric > $1` with `100`, SQLite and MySQL
# `(SELECT …) > ?` with `100`; an equality binds `"100"` on PostgreSQL and MySQL and `100` on SQLite;
# text equality binds the text; a `When` condition on the alias compares the same way. A `Subquery`
# over the whole document keeps the JSON formatter, and one over a typed column binds as it did.
# Why it matters: the ordering returned the rows a text comparison picks, with nothing to say so.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1492: a filter on a Subquery alias over a JSON key binds as the key lookup does" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  sub(col) = (s = JL.Json_scratch.objects; s.filter("id" => QB.OuterRef("id")); s.values("w" => col); s)
  withsub(filt; col = "payload__n") =
    (q = JL.Json_scratch.objects; q.values("name", "w" => QB.Subquery(sub(col))); q.filter(filt); q)
  # The whole statement, one line: the outer WHERE is its tail (the subquery has a WHERE of its own).
  where(r) = rstrip(replace(r[:sql_text], r"\s+" => " "))
  # The subquery's projection warns that it may match more than one row; that is not under test.
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  sql(filt, conn; col = "payload__n") = quiet(() -> _sql(withsub(filt; col); conn = conn))
  # An ordering: a numeric comparison, the number bound as a number.
  r = sql("w__@gt" => 100, _JL_PG)
  @test occursin(r"\)\)::numeric > \$1$", where(r)) && r[:parameters] == [100]
  for conn in (_JL_SL, _JL_MY)
    r = sql("w__@gt" => 100, conn)
    @test occursin(r"\) > \?$", where(r)) && r[:parameters] == [100]
  end
  # `@in`, which a key lookup refuses, is refused here too (#1499).
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @test_throws PormG.FilterError sql("w__@in" => [9, 10], conn)
  end
  # An equality with a number: text on PostgreSQL and MySQL, the native number on SQLite.
  @test sql("w" => 100, _JL_PG)[:parameters] == ["100"]
  @test sql("w" => 100, _JL_SL)[:parameters] == [100]
  @test sql("w" => 100, _JL_MY)[:parameters] == ["100"]
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    # An equality on text binds the text.
    @test sql("w" => "hamilton", conn; col = "payload__driver")[:parameters] == ["hamilton"]
    # A `When` condition on the alias compares as the alias's filter does.
    q = JL.Json_scratch.objects
    q.values("name", "w" => QB.Subquery(sub("payload__n")))
    q.filter(QB.Case([QB.When("w__@gt" => 100, then = 1)], default = 0) == 1)
    @test quiet(() -> _sql(q; conn = conn))[:parameters] == [100, 1, 0, 1]
    # Controls: the whole document keeps the JSON formatter, a typed column binds its number.
    @test sql("w" => """{"a": 1}""", conn; col = "payload") isa AbstractDict
    @test_throws PormG.InvalidValueError sql("w" => "hamilton", conn; col = "payload")
    @test sql("w__@gt" => 100, conn; col = "id")[:parameters] == [100]
  end
  @test occursin("::numeric", where(sql("w__@gt" => 100, _JL_PG))) &&
        !occursin("::numeric", where(sql("w__@gt" => 100, _JL_PG; col = "id")))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1499: a filter on anything that holds a JSON key's value refuses what the key lookup refuses
# A filter on a projection alias over a key (`F("payload__n")`), a CTE column over one and a `Subquery`
# alias projecting one compared as the key lookup does for `=`, `@ne`, the orderings and `@isnull`
# (#1382, #1472, #1492), but the other operators fell through and bound their values raw. On PostgreSQL
# the alias is text, so `w__@range => (9, 100)` rendered `#>> '{"n"}' BETWEEN $1 AND $2`, where `'15'`
# is not between `'9'` and `'100'`: the row dropped without a word. Expected, on every engine and for
# every handle: `@in`, `@nin`, `@range` and a pattern lookup raise the `FilterError` the key lookup
# raises, naming the lookup as the caller wrote it and the cast spelling; a cast alias takes the range.
# Why it matters: a filter on the alias returned fewer rows, silently, where the same filter on the key
# refused to run.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1499: an alias, CTE column or Subquery over a JSON key refuses what the key lookup refuses" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  sub() = (s = JL.Json_scratch.objects; s.filter("id" => QB.OuterRef("id")); s.values("w" => "payload__n"); s)
  aliased(filt) = (q = JL.Json_scratch.objects; q.values("name", "w" => F("payload__n")); q.filter(filt); q)
  subquery(filt) = (q = JL.Json_scratch.objects; q.values("name", "w" => QB.Subquery(sub())); q.filter(filt); q)
  function cte(filt)
    body = JL.Json_scratch.objects
    body.values("id", "w" => "payload__n")
    q = JL.Json_scratch.objects
    q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
    q.values("id", "g__w")
    q.filter(filt)
    return q
  end
  key(filt) = (q = JL.Json_scratch.objects; q.values("name"); q.filter(filt); q)
  # The `Subquery` projection warns that it may match more than one row; that is not under test.
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  refusal(mk, filt, conn) = quiet(() -> try _sql(mk(filt); conn = conn); nothing catch e; e end)
  # CI renders with color, so a message is read without its ANSI codes.
  plain(e) = PormG._emsg(sprint(showerror, e); color = false)
  for conn in (_JL_PG, _JL_SL, _JL_MY),
      (suffix, value) in (("@range", (9, 100)), ("@in", [9, 15]), ("@nin", [9, 15]), ("@startswith", "1"))
    @testset "$suffix on $(nameof(typeof(conn)))" begin
      # The key lookup itself: the reference refusal.
      e = refusal(key, "payload__n__$suffix" => value, conn)
      @test e isa PormG.FilterError && occursin("The $suffix lookup is not supported on payload__n", plain(e))
      for (mk, name) in ((aliased, "w"), (subquery, "w"), (cte, "g__w"))
        e = refusal(mk, "$(name)__$suffix" => value, conn)
        @test e isa PormG.FilterError
        e isa PormG.FilterError &&
          @test occursin("The $suffix lookup is not supported on $name, a JSON key's value", plain(e))
        # Both casts: a pattern lookup or a list of text needs the text one (review of #1499).
        e isa PormG.FilterError && @test occursin("Cast(<the key path>, \"numeric\")", plain(e)) &&
          occursin("Cast(<the key path>, \"text\")", plain(e))
      end
      # A `When` condition on the alias refuses as the alias's filter does.
      q = JL.Json_scratch.objects
      q.values("name", "w" => F("payload__n"))
      q.filter(QB.Case([QB.When("w__$suffix" => value, then = 1)], default = 0) == 1)
      @test_throws PormG.FilterError _sql(q; conn = conn)
    end
  end
  # The explicit spelling: a cast alias takes the range, two numbers bound on every engine.
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    q = JL.Json_scratch.objects
    q.values("name", "w" => FN.Cast("payload__n", "numeric"))
    q.filter("w__@range" => (9, 100))
    r = _sql(q; conn = conn)
    @test occursin("BETWEEN", r[:sql_text]) && r[:parameters] == [9, 100]
  end
  # Controls: the comparisons the key lookup renders still build on the alias.
  @test _sql(aliased("w__@gte" => 9); conn = _JL_PG)[:parameters] == [9]
  @test isempty(_sql(aliased("w__@isnull" => true); conn = _JL_SL)[:parameters])
end

# ─────────────────────────────────────────────────────────────────────────────
# #1506: a filter on an alias over a value that CARRIES an uncast JSON key is refused on every engine
# #1382 compares an alias over the key as the key lookup does; an alias over `Coalesce(key, 0)`, a
# `Case` branch, `NullIf(key, …)`, `Abs(key)`, or a `Subquery` projecting one, is not the key, and bound
# its value through its own formatter: `COALESCE(json_extract(…), ?) > ?` with `"9"` as text on SQLite,
# where an integer is never greater than text, so the filter matched no row with no error;
# `COALESCE(#>> …, $2::bigint)` on PostgreSQL is a server error. Expected: `FilterError` naming `(#1506)`
# and the cast inside the expression, under `=`, `@gt`, `@ne` and a column on the right, on the alias's
# filter, a `Q`, a `When` condition and a `Subquery` alias. `@isnull` keeps its own arm; the cast inside
# the carrier builds and binds the number. Why it matters: the rows silently differed by engine (#1497
# already refuses an `order_by` on this same alias, #1483 arithmetic over it).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1506: a filter on an alias over a carrier of an uncast JSON key is refused on every engine" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  # (`NullIf(key, …)` was a carrier here until #1510 refused it at the projection, below.)
  carriers = (("Coalesce", () -> FN.Coalesce("payload__n", 0)),
              ("Case", () -> Case([When("id" => 1, then = F("payload__n"))], default = 0)),
              ("Abs", () -> FN.Abs("payload__n")),
              ("Ceil", () -> FN.Ceil("payload__n")))
  sub(src) = (s = JL.Json_scratch.objects; s.filter("id" => QB.OuterRef("id")); s.values("w" => src); s)
  aliased(src, filt) = (q = JL.Json_scratch.objects; q.values("name", "w" => src); q.filter(filt); q)
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  refusal(q, conn) = quiet(() -> try _sql(q; conn = conn); nothing catch e; e end)
  plain(e) = PormG._emsg(sprint(showerror, e); color = false)
  for conn in (_JL_PG, _JL_SL, _JL_MY), (label, src) in carriers
    @testset "$label on $(nameof(typeof(conn)))" begin
      for filt in ("w" => 9, "w__@gt" => 9, "w__@ne" => 9, "w__@gt" => F("id"))
        handles = (("alias", aliased(src(), filt)), ("Q", aliased(src(), QB.Q(filt))),
                   ("Qor", aliased(src(), QB.Qor(filt, "name" => "Senna"))),
                   ("Subquery", aliased(QB.Subquery(sub(src())), filt)))
        for (handle, q) in handles
          e = refusal(q, conn)
          @test (handle, e isa PormG.FilterError) == (handle, true)
          e isa PormG.FilterError && @test occursin("A filter on w is not supported", plain(e)) &&
            occursin("(#1506)", plain(e)) && occursin("Cast(\"payload__n\", \"numeric\")", plain(e))
        end
      end
      # A `When` condition on the alias refuses as the alias's filter does.
      q = JL.Json_scratch.objects
      q.values("name", "w" => src())
      q.filter(Case([When("w__@gt" => 9, then = 1)], default = 0) == 1)
      e = refusal(q, conn)
      @test e isa PormG.FilterError && occursin("(#1506)", plain(e))
      # `@isnull` binds nothing and is not this refusal: it renders `IS NULL`, or its own arm refuses a
      # function expression under it, as before #1506.
      q = aliased(src(), "w__@isnull" => true)
      e = refusal(q, conn)
      @test (label, e === nothing ? occursin("IS NULL", _sql(q; conn = conn)[:sql_text]) :
                    e isa PormG.FilterError && occursin("Error in ISNULL", plain(e))) == (label, true)
    end
  end
  # The explicit spelling: the cast inside the carrier binds the number on every engine.
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    r = _sql(aliased(FN.Coalesce(FN.Cast("payload__n", "numeric"), 0), "w__@gt" => 9); conn = conn)
    @test r[:parameters] == [0, 0, 9]
  end
  # Control: an alias that IS the key still compares as the key lookup (#1382).
  @test _sql(aliased(F("payload__n"), "w__@gt" => 9); conn = _JL_SL)[:parameters] == [9]
end

# ─────────────────────────────────────────────────────────────────────────────
# #1507: an expression on the right of an alias, CTE column or Subquery over a JSON key is refused as
# on the key (#811)
# The key lookup refuses a column expression on the right ("a JSON path lookup compares the extracted
# value against a value, not a column expression"); the #1382/#1472/#1492 routing skipped any expression
# or queryset on the right, so the alias, CTE column and `Subquery` alias rendered a column comparison:
# `"Tb"."payload" #>> '{"n"}' > "Tb"."id"` on PostgreSQL, text against a bigint, a server error. Expected:
# the key's own `FilterError` on every handle, engine and right side (`F`, a function, a `Subquery`), with
# the handle's name; a queryset under `@in` gets #1499's refusal on every handle, as on the key. Why it
# matters: the alias stands for the key lookup, and the two answered differently on this one shape.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1507: an expression on the right of a handle over a JSON key is refused as on the key" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  sub(src) = (s = JL.Json_scratch.objects; s.filter("id" => QB.OuterRef("id")); s.values("w" => src); s)
  key(filt) = (q = JL.Json_scratch.objects; q.values("name"); q.filter(filt); q)
  aliased(filt) = (q = JL.Json_scratch.objects; q.values("name", "w" => F("payload__n")); q.filter(filt); q)
  q_wrapped(filt) = aliased(QB.Q(filt))
  subquery(filt) = (q = JL.Json_scratch.objects; q.values("name", "w" => QB.Subquery(sub("payload__n"))); q.filter(filt); q)
  function cte(filt)
    body = JL.Json_scratch.objects
    body.values("id", "w" => "payload__n")
    q = JL.Json_scratch.objects
    q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
    q.values("id", "g__w")
    q.filter(filt)
    return q
  end
  when(filt) = (q = JL.Json_scratch.objects; q.values("name", "w" => F("payload__n"));
                q.filter(Case([When(filt, then = 1)], default = 0) == 1); q)
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  refusal(q, conn) = quiet(() -> try _sql(q; conn = conn); nothing catch e; e end)
  plain(e) = PormG._emsg(sprint(showerror, e); color = false)
  column_rhs = "a JSON path lookup compares the extracted value against a value, not a column expression"
  rights = (("F", (n -> "$(n)__@gt" => F("id"))), ("F, equality", (n -> n => F("id"))),
            ("a function", (n -> "$(n)__@lte" => FN.Abs("id"))),
            ("a Subquery", (n -> "$(n)__@gt" => QB.Subquery(sub("id")))))
  handles = (("the key", key, "payload__n"), ("an alias", aliased, "w"), ("a Q on the alias", q_wrapped, "w"),
             ("a Subquery alias", subquery, "w"), ("a CTE column", cte, "g__w"), ("a When on the alias", when, "w"))
  for conn in (_JL_PG, _JL_SL, _JL_MY), (right, filt_for) in rights
    @testset "$right on $(nameof(typeof(conn)))" begin
      for (handle, mk, name) in handles
        e = refusal(mk(filt_for(name)), conn)
        @test (handle, e isa PormG.FilterError) == (handle, true)
        e isa PormG.FilterError &&
          @test (handle, occursin("Error in filter '$name': $column_rhs", plain(e))) == (handle, true)
      end
    end
  end
  # A queryset under `@in` is a membership list, which the key lookup refuses (#1499); so do the others.
  members() = (s = JL.Json_scratch.objects; s.values("id"); s)
  for conn in (_JL_PG, _JL_SL, _JL_MY), (handle, mk, name) in handles
    e = refusal(mk("$(name)__@in" => members()), conn)
    @test (handle, e isa PormG.FilterError && occursin("The @in lookup is not supported on $name", plain(e))) ==
          (handle, true)
  end
  # Control: a value on the right still compares as the key lookup on every handle (a `When` binds its
  # THEN and ELSE values after it).
  for (handle, mk, name) in handles
    @test (handle, 9 in _sql(mk("$(name)__@gt" => 9); conn = _JL_SL)[:parameters]) == (handle, true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1510: NullIf over an uncast JSON key is refused on every engine, where it is built
# `NullIf` compares its operands for equality, and a key's value has no declared type. The walk typed
# `NullIf(key, 0)` as the key's value, so the same expression answered three ways by the handle it sat
# behind: a filter on its projection alias was refused as a carrier (#1506), while a CTE column or a
# `Subquery` over it compared as the key (#1472, #1492). The projection itself was a server error on
# PostgreSQL (`NULLIF(#>> '{"n"}', $1::bigint)`, `text = bigint`) and compared the native value on
# SQLite. Expected: `QueryBuildError` naming `(#1510)`, the cast written where the key sits
# (`NullIf(Cast("payload__n", "numeric"), 0)`, or `NullIf(…, Cast(…))` for the second operand) and
# the text cast, on PostgreSQL, SQLite and MySQL, for the key or a carrier of it in either operand and in
# a projection, a CTE body, a `Subquery`, a filter value and under `Max`. Each cast spelling builds:
# PostgreSQL `NULLIF(("Tb"."payload" #>> '{"n"}')::decimal, $1::bigint)`. A `NullIf` with no key builds.
# Why it matters: one value answered three ways, and nothing said which one the query meant.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1510: NullIf over an uncast JSON key is refused on every engine" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  proj(x) = (q = JL.Json_scratch.objects; q.values("id", "m" => x); q)
  cte(x) = (q = JL.Json_scratch.objects;
    q.with("g" => JL.Json_scratch.objects.values("id", "w" => x), join_field = "id" => "id", join_type = "INNER");
    q.values("id", "g__w"); q.filter("g__w__@gt" => 5); q)
  sub(x) = (q = JL.Json_scratch.objects;
    q.values("id", "w" => QB.Subquery((s = JL.Json_scratch.objects; s.filter("id" => QB.OuterRef("id")); s.values("v" => x); s)));
    q.filter("w__@gt" => 5); q)
  filtered(x) = (q = JL.Json_scratch.objects; q.values("id"); q.filter("id" => x); q)
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  refusal(q, conn) = quiet(() -> try _sql(q; conn = conn); nothing catch e; e end)
  plain(e) = PormG._emsg(sprint(showerror, e); color = false)
  # The spelling casts the key where it sits: in the second position, a cast moved to the first would
  # change which value `NullIf` returns (review).
  first_spelling(k) = "NullIf(Cast(\"$(k)\", \"numeric\"), 0)"
  shapes = (("the key first", () -> FN.NullIf("payload__n", 0), "the JSON key `payload__n`", first_spelling("payload__n")),
            ("a text key", () -> FN.NullIf("payload__s", FN.Value("")), "the JSON key `payload__s`", first_spelling("payload__s")),
            ("the key second", () -> FN.NullIf("id", "payload__n"), "the JSON key `payload__n`",
             "NullIf(…, Cast(\"payload__n\", \"numeric\"))"),
            ("a carrier", () -> FN.NullIf(FN.Coalesce("payload__n", 0), 0), "`COALESCE(…)` over the JSON key `payload__n`",
             first_spelling("payload__n")))
  handles = (("projection", proj), ("CTE body", cte), ("Subquery", sub), ("filter value", filtered),
             ("under Max", x -> proj(FN.Max(x))))
  for conn in (_JL_PG, _JL_SL, _JL_MY), (shape, mk, named, spelling) in shapes, (handle, h) in handles
    e = refusal(h(mk()), conn)
    @test (shape, handle, e isa PormG.QueryBuildError) == (shape, handle, true)
    msg = e === nothing ? "" : plain(e)
    @test (shape, handle, startswith(msg, "`NullIf` over $(named) is not supported") && occursin("(#1510)", msg)) ==
          (shape, handle, true)
    @test (shape, handle, occursin(spelling, msg)) == (shape, handle, true)
  end
  # The explicit spellings build on every engine, and so does a `NullIf` over no key.
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @test _sql(proj(FN.NullIf(FN.Cast("payload__n", "numeric"), 0)); conn = conn)[:parameters] == [0]
    @test _sql(proj(FN.NullIf(FN.Cast("payload__s", "text"), FN.Value(""))); conn = conn)[:parameters] == [""]
    @test _sql(proj(FN.NullIf("id", 0)); conn = conn)[:parameters] == [0]
  end
  @test occursin("NULLIF((\"Tb\".\"payload\" #>> '{\"n\"}')::decimal, \$1::bigint)",
                 _sql(proj(FN.NullIf(FN.Cast("payload__n", "numeric"), 0)); conn = _JL_PG)[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# #1511: an expression comparison over a JSON key compares as the key lookup does
# `F("payload__n") == 5` rendered through the generic operator path, which bound the text `"5"` on every
# engine and put no `::numeric` on a PostgreSQL ordering. Expected: the predicate the filter pair
# `"payload__n" => 5` renders, in parentheses, with the same parameters (SQLite `json_extract(…) = ?`
# binding `5`; PostgreSQL `#>> '{"n"}' = $1` binding `"5"`, and `(#>> …)::numeric > $1` binding `5`),
# through `F`, `Q`, a `When` and a projection. A column or a field path on the right of the key, and a
# carrier on the left (`Coalesce(key, 0)`), raise `FilterError`, as the key lookup (#811) and its alias
# (#1506) do. A key on the right of a column is refused since #1528 (its testset, below), and a cast key
# keeps the generic path.
# Why it matters: on SQLite the integer `json_extract` hands over never equals text, so the filter
# matched no row with no error, and on PostgreSQL `9` sorted above `10`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1511: an expression comparison over a JSON key compares as the key lookup does" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  where_of(sql) = strip(split(sql, "WHERE ")[end])
  pair(path) = (q = JL.Json_scratch.objects; q.values("id"); q.filter(path); q)
  expr(f) = (q = JL.Json_scratch.objects; q.values("id"); q.filter(f); q)
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  refusal(q, conn) = quiet(() -> try _sql(q; conn = conn); nothing catch e; e end)
  plain(e) = PormG._emsg(sprint(showerror, e); color = false)
  cases = (("==", "payload__n", 5, f -> f == 5), ("!=", "payload__n__@ne", 5, f -> f != 5),
           (">", "payload__n__@gt", 5, f -> f > 5), ("<=", "payload__n__@lte", 2.5, f -> f <= 2.5))
  for conn in (_JL_PG, _JL_SL, _JL_MY), (op, path, value, cmp) in cases
    @testset "F $op on $(nameof(typeof(conn)))" begin
      ref = _sql(pair(path => value); conn = conn)
      for (label, q) in (("F", expr(cmp(F("payload__n")))), ("Q", expr(QB.Q(cmp(F("payload__n"))))))
        got = _sql(q; conn = conn)
        @test (label, occursin("(" * where_of(ref[:sql_text]) * ")", got[:sql_text])) == (label, true)
        @test (label, got[:parameters]) == (label, ref[:parameters])
      end
      # A projection and a `When` condition bind the same value (the `When` binds THEN/ELSE after it).
      proj = (q = JL.Json_scratch.objects; q.values("id", "b" => cmp(F("payload__n"))); q)
      @test _sql(proj; conn = conn)[:parameters] == ref[:parameters]
      when = (q = JL.Json_scratch.objects; q.values("id", "b" => Case([When(cmp(F("payload__n")), then = 1)], default = 0)); q)
      @test _sql(when; conn = conn)[:parameters][1:1] == ref[:parameters]
    end
  end
  # The values themselves, per engine: the bug was the bound type, so the oracle is the parameter.
  @test _sql(expr(F("payload__n") == 5); conn = _JL_SL)[:parameters] == Any[5]
  @test _sql(expr(F("payload__n") == 5); conn = _JL_PG)[:parameters] == Any["5"]
  @test occursin("((\"Tb\".\"payload\" #>> '{\"n\"}')::numeric > \$1)", _sql(expr(F("payload__n") > 5); conn = _JL_PG)[:sql_text])
  @test _sql(expr(F("payload__n") > 5); conn = _JL_PG)[:parameters] == Any[5]
  column_rhs = "a JSON path lookup compares the extracted value against a value, not a column expression"
  refused = (("a column on the right", F("payload__n") > F("id"), "Error in filter 'payload__n': $column_rhs"),
             ("a field path on the right", F("payload__n") == "name", "Error in filter 'payload__n': $column_rhs"),
             ("a carrier on the left", FN.Coalesce("payload__n", 0) > 5, "it holds `COALESCE(…)` over the JSON key `payload__n`"),
             ("NaN", F("payload__n") == NaN, "A numeric JSON comparison requires a finite number"))
  for conn in (_JL_PG, _JL_SL, _JL_MY), (label, f, msg) in refused
    e = refusal(expr(f), conn)
    @test (label, e isa Union{PormG.FilterError,PormG.InvalidValueError}) == (label, true)
    e === nothing || @test (label, occursin(msg, plain(e))) == (label, true)
  end
  # An ON clause: `on("team", F("payload__n") > 5)` names the joined row's key, and binds as the pair
  # `on("team", "payload__n__@gt" => 5)` does (review: the entry and docs list the join condition).
  on_pred = Dict(_JL_PG => "AND ((\"Tb_1\".\"payload\" #>> '{\"n\"}')::numeric > \$1)",
                 _JL_SL => "AND (json_extract(\"Tb_1\".\"payload\", '\$.n') > ?)",
                 _JL_MY => "COLLATE utf8mb4_0900_bin) > ?)")
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    joined(cond) = (q = JJ.Json_entry.objects; q.on("team", cond); q.values("id", "team__id"); _sql(q; conn = conn))
    got, ref = joined(F("payload__n") > 5), joined("payload__n__@gt" => 5)
    @test got[:parameters] == ref[:parameters] == Any[5]
    @test occursin(on_pred[conn], replace(got[:sql_text], r"\s+" => " "))
  end
  # A key on the RIGHT of a column is #1528's testset below: refused in both spellings, which #1511 left
  # rendering as the pair did.
  # Control: a cast key states its type, so it keeps the generic path (`::decimal`, no key binding).
  @test occursin("::decimal > \$1::bigint", _sql(expr(FN.Cast("payload__n", "numeric") > 5); conn = _JL_PG)[:sql_text])
  # Control: a whole document is not a key, and keeps its JSON bind (#1360).
  @test occursin("CAST(? AS JSON)", _sql(expr(F("payload") == "{\"a\": 1}"); conn = _JL_MY)[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# #1528: a JSON key, or a value carrying one, on the right of a comparison is refused on every engine
# #1511 made a key on the LEFT compare as its lookup does and left the RIGHT alone, so both spellings of
# `F("id") == F("payload__n")` — the operator and the pair `"id" => F("payload__n")` — rendered the
# generic column comparison: `"Tb"."id" = "Tb"."payload" #>> '{"n"}'` on PostgreSQL (`bigint = text`, a
# server error) and `json_extract(…)`'s native value on SQLite. A carrier on the right did the same:
# `F("id") > Coalesce("payload__n", 0)` rendered `COALESCE(#>> …, $1::bigint)`. Expected: `FilterError`
# on every engine when the query is built, in both spellings and in a projection, naming `(#1528)`, the
# key and the cast spelling; a text key against a text column is refused too (it is still untyped), as
# are a `Subquery` projecting the key, a CTE column over it, an `OuterRef` to it and a join condition.
# Controls: a cast key on the right builds, a bound text value that is not a field path is not a column,
# and the key on the left keeps #1511's comparison.
# Why it matters: the same comparison was a server error on PostgreSQL and a silent native-value
# comparison on SQLite, and only the left side said what the comparison meant.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1528: a JSON key or a carrier on the right of a comparison is refused on every engine" begin
  FN = PormG.Functions
  pair(p) = (q = JL.Json_scratch.objects; q.values("id"); q.filter(p); q)
  expr(f) = (q = JL.Json_scratch.objects; q.values("id"); q.filter(f); q)
  proj(f) = (q = JL.Json_scratch.objects; q.values("id", "b" => f); q)
  QB = PormG.QueryBuilder
  sub_key() = (s = JL.Json_scratch.objects; s.filter("id" => 1); s.values("payload__n"); s)
  function cte(cond)
    body = JL.Json_scratch.objects
    body.values("id", "k" => "payload__n")
    q = JL.Json_scratch.objects
    q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
    q.values("id")
    q.filter(cond)
    return q
  end
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  refusal(q, conn) = quiet(() -> try _sql(q; conn = conn); nothing catch e; e end)
  plain(e) = PormG._emsg(sprint(showerror, e); color = false)
  shapes = (
    ("F == key", () -> expr(F("id") == F("payload__n")), "the JSON key `payload__n`"),
    ("F > key", () -> expr(F("id") > F("payload__n")), "the JSON key `payload__n`"),
    ("pair = key", () -> pair("id" => F("payload__n")), "the JSON key `payload__n`"),
    ("pair @gt key", () -> pair("id__@gt" => F("payload__n")), "the JSON key `payload__n`"),
    ("text column == text key", () -> expr(F("name") == F("payload__s")), "the JSON key `payload__s`"),
    ("a key path string", () -> expr(F("name") == "payload__s"), "the JSON key `payload__s`"),
    ("pair = carrier", () -> pair("id" => FN.Coalesce("payload__n", 0)), "`COALESCE(…)` over the JSON key `payload__n`"),
    ("F > carrier", () -> expr(F("id") > FN.Coalesce("payload__n", 0)), "`COALESCE(…)` over the JSON key `payload__n`"),
    ("projection", () -> proj(F("id") == F("payload__n")), "the JSON key `payload__n`"),
    # Review of #1528: every value that holds the key, wherever it comes from, on the right.
    ("pair = Subquery(key)", () -> pair("id" => QB.Subquery(sub_key())), "a Subquery projecting the JSON key `payload__n`"),
    ("F == Subquery(key)", () -> expr(F("id") == QB.Subquery(sub_key())), "a Subquery projecting the JSON key `payload__n`"),
    ("pair = CTE column over a key", () -> cte("id" => QB.CTE("g", "k")), "(the JSON key `payload__n`)"),
    ("OuterRef(key) on the right", () -> proj(QB.Subquery((s = JL.Json_scratch.objects;
        s.filter("id" => QB.OuterRef("payload__n")); s.values("id"); s))), "the JSON key `payload__n`"),
    ("a join condition", () -> (q = JJ.Json_entry.objects; q.on("team", "id" => F("team__payload__n"));
        q.values("id", "team__id"); q), "the JSON key `team__payload__n`"),
  )
  for conn in (_JL_PG, _JL_SL, _JL_MY), (label, build, held) in shapes
    e = refusal(build(), conn)
    @test (label, e isa PormG.FilterError) == (label, true)
    e isa PormG.FilterError || continue
    msg = plain(e)
    @test (label, occursin("(#1528)", msg)) == (label, true)
    @test (label, occursin(held, msg)) == (label, true)
    @test (label, occursin(r"Cast\(\"(team__)?payload__[ns]\", \"numeric\"\)", msg)) == (label, true)
  end
  # Controls, every engine: the cast spelling builds, a text value is a value, the left keeps #1511's.
  for conn in (_JL_PG, _JL_SL, _JL_MY)
    @test _sql(expr(F("id") == FN.Cast("payload__n", "numeric")); conn = conn)[:sql_text] isa String
    @test _sql(pair("id" => FN.Coalesce(FN.Cast("payload__n", "numeric"), 0)); conn = conn)[:sql_text] isa String
    @test _sql(expr(F("name") == "Senna"); conn = conn)[:parameters] == Any["Senna"]
    @test _sql(expr(F("payload__n") == 5); conn = conn)[:parameters] == _sql(pair("payload__n" => 5); conn = conn)[:parameters]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1497: an ordering over an uncast JSON key is refused on every engine
# #1491 refuses `Max`/`Min` over a key because they order a value the query does not type; an
# ordering term and `Greatest`/`Least` asked the same question and still built. PostgreSQL rendered
# `ORDER BY "Tb"."payload" #>> '{"n"}' DESC` and MySQL `JSON_UNQUOTE(…) COLLATE utf8mb4_0900_bin DESC`,
# both text, so over 9 and 10 descending `9` came first, while SQLite's `json_extract` ordered the
# numbers; `GREATEST(#>> '{"n"}', "id")` compared text with a bigint. Expected: `QueryBuildError` on
# every engine when the query is built, naming `(#1497)` and both cast spellings, for an `order_by` path,
# a projection alias over the key or over a carrier (`Coalesce(key, 0)`), a CTE column, a `Subquery`
# alias, a labelled expression, a window's ordering and `Greatest`/`Least`; each cast spelling builds.
# (The SQLite mock cannot render ORDER BY, the #75 version probe; its cells are the integration test's.)
# Why it matters: the rows came back in a different order on each engine, and nothing said so.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1497: an ordering over an uncast JSON key is refused on every engine" begin
  FN = PormG.Functions
  QB = PormG.QueryBuilder
  sub() = (s = JL.Json_scratch.objects; s.filter("id" => QB.OuterRef("id")); s.values("w" => "payload__n"); s)
  ordered(proj, order) = (q = JL.Json_scratch.objects; q.values(proj...); q.order_by(order); q)
  function cte(order)
    body = JL.Json_scratch.objects
    body.values("id", "k" => "payload__n")
    q = JL.Json_scratch.objects
    q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
    q.values("id", "g__k")
    q.order_by(order)
    return q
  end
  window(order) = (q = JL.Json_scratch.objects; q.values("name", "r" => FN.Rank(over = FN.WindowOver(order_by = [order]))); q)
  function cte_window()
    body = JL.Json_scratch.objects
    body.values("id", "k" => "payload__n")
    q = JL.Json_scratch.objects
    q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
    q.values("id", "r" => FN.Rank(over = FN.WindowOver(order_by = [QB.CTE("g", "k"; desc = true)])))
    return q
  end
  projected(expr) = (q = JL.Json_scratch.objects; q.values("name", "g" => expr); q)
  labelled(expr) = QB.SQLOrder(QB.SQLField(expr, "o"); orientation = "DESC")
  quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
  plain(e) = PormG._emsg(sprint(showerror, e); color = false)
  refused = (
    ("an order_by path", () -> ordered(("name",), "-payload__n"), "`order_by`"),
    ("a projected path", () -> ordered(("id", "payload__nome"), "payload__nome"), "`order_by`"),
    ("an F alias", () -> ordered(("name", "w" => F("payload__n")), "-w"), "`order_by`"),
    ("a Coalesce alias", () -> ordered(("name", "w" => FN.Coalesce("payload__n", 0)), "-w"), "`order_by`"),
    ("a CTE column", () -> cte("-g__k"), "`order_by`"),
    ("a Subquery alias", () -> ordered(("name", "w" => QB.Subquery(sub())), "-w"), "`order_by`"),
    ("a labelled expression", () -> ordered(("name",), labelled(F("payload__n"))), "`order_by`"),
    ("a window path", () -> window("-payload__n"), "A window's `order_by`"),
    ("a window SQLOrder", () -> window(labelled(F("payload__n"))), "A window's `order_by`"),
    ("a window over a CTE handle", () -> cte_window(), "A window's `order_by`"),
    ("a Case alias", () -> ordered(("name", "w" => QB.Case([QB.When("id__@gt" => 1, then = F("payload__n"))], default = 0)), "-w"), "`order_by`"),
    ("Greatest", () -> projected(FN.Greatest("payload__n", "id")), "`Greatest`"),
    ("Least", () -> projected(FN.Least("id", "payload__n")), "`Least`"),
    # An `output_field` casts the result after the operands are compared, so it states no order.
    ("Greatest with an output_field", () -> projected(FN.Greatest("payload__n", "id"; output_field = "integer")), "`Greatest`"),
  )
  builds = (
    ("a cast alias", () -> ordered(("name", "w" => FN.Cast("payload__n", "numeric")), "-w")),
    ("a labelled cast", () -> ordered(("name",), labelled(FN.Cast("payload__n", "text")))),
    ("a window over a cast", () -> window(labelled(FN.Cast("payload__n", "numeric")))),
    ("Greatest over a cast", () -> projected(FN.Greatest(FN.Cast("payload__n", "numeric"), "id"))),
    ("a typed column", () -> ordered(("name",), "-id")),
  )
  for conn in (_JL_PG, _JL_MY)
    @testset "$label on $(nameof(typeof(conn)))" for (label, mk, what) in refused
      e = quiet(() -> try _sql(mk(); conn = conn); nothing catch err; err end)
      @test e isa PormG.QueryBuildError
      e isa PormG.QueryBuildError && @test startswith(plain(e), what) && occursin("(#1497)", plain(e)) &&
        occursin("\", \"numeric\")", plain(e)) && occursin("\", \"text\")", plain(e))
    end
    @testset "$label builds on $(nameof(typeof(conn)))" for (label, mk) in builds
      @test quiet(() -> _sql(mk(); conn = conn)) isa AbstractDict
    end
  end
  # An `order_by` term takes a path or a name, so its message adds the projected spelling.
  e = try _sql(ordered(("name",), "-payload__n"); conn = _JL_PG) catch err; err end
  @test occursin("values(\"n\" => Cast(\"payload__n\", \"numeric\")), then order_by(\"n\")", plain(e))
  # `last()` inverts the ordering and renders it through the same path, on the configured (SQLite)
  # mock. The refusal comes before the mock's driver probe; a cast term gets past it to that probe
  # (`InvalidConfigurationError`, no driver loaded), which is the discrimination here.
  lasted(proj, order) = try (q = ordered(proj, order); q.last(show_query = :sql)); nothing catch err; err end
  e = lasted(("name",), "-payload__n")
  @test e isa PormG.QueryBuildError && occursin("(#1497)", plain(e))
  @test !(lasted(("name", "w" => FN.Cast("payload__n", "numeric")), "-w") isa PormG.QueryBuildError)
  # Greatest/Least render with no ORDER BY, so SQLite's mock reaches them too.
  @test_throws PormG.QueryBuildError _sql(projected(FN.Greatest("payload__n", "id")); conn = _JL_SL)
  @test _sql(projected(FN.Greatest(FN.Cast("payload__n", "numeric"), "id")); conn = _JL_SL) isa AbstractDict
end
