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
import PormG.QueryBuilder: inspect_query

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
    # The projection and the ordering read the same text.
    q = JL.Json_scratch.objects; q.values("id", "payload__nome"); q.order_by("payload__nome")
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

  @testset "order_by on a JSON path resolves the extraction (PG)" begin
    q = JL.Json_scratch.objects
    q.values("id")
    q.order_by("payload__nome")
    @test occursin(r"ORDER BY\s+\"Tb\".\"payload\" #>> '\{\"nome\"\}'", _sql(q; conn = _JL_PG)[:sql_text])
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

    # A string/LIKE operator on a JSON path is not a supported comparison → clear error.
    q = JL.Json_scratch.objects; q.filter("payload__nome__@startswith" => "ham"); q.values("id")
    @test_throws "not supported on a JSON path lookup" inspect_query(q)
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
  # The same document through a projection alias and through `F("payload") ==` (#1360)
  # Both bound a bare marker on MySQL, so each matched no row with no error; and `F ==` bound
  # `$1::text` on PostgreSQL, `jsonb = text`, which has no operator (measured: SQLSTATE 42883).
  # Expected SQL: MySQL `CAST(? AS JSON)` for `=`, `@ne`, `@in` on the alias and for `F ==`/`!=`; a
  # pattern lookup on the alias and a key lookup either way stay bare; PostgreSQL binds an uncast `$1`
  # (typed from the jsonb column, as the filter arm binds it) and SQLite a bare `?`.
  # ─────────────────────────────────────────────────────────────────────────────
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
    # A pattern lookup and a membership list bind as given, as they did: the key's text, unchecked.
    @test _sql(keyed("d__@contains", "ham"); conn = _JL_PG)[:parameters] == Any["%ham%"]
    @test _sql(keyed("d__@in", ["a", "b"]); conn = _JL_SL)[:parameters] == Any["a", "b"]
    # An alias over the whole document keeps the JSON formatter and the #1360 marker.
    whole = (q = JL.Json_scratch.objects; q.values("id", "p" => F("payload")); q.filter("p" => "notjson"); q)
    @test_throws PormG.InvalidValueError _sql(whole; conn = _JL_PG)
  end

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
    # A key lookup is that key's text, not a document: bare on MySQL, `::text` on PostgreSQL as before.
    # (The extraction itself holds `CAST('null' AS JSON)`, so the needle is the bound marker.)
    my_key = _sql(compared(F("payload__driver") == "hamilton"); conn = _JL_MY)[:sql_text]
    @test !occursin("CAST(? AS JSON)", my_key) && occursin("utf8mb4_0900_bin) = ?)", my_key)
    @test occursin("= \$1::text)", _sql(compared(F("payload__driver") == "hamilton"); conn = _JL_PG)[:sql_text])
  end

end
