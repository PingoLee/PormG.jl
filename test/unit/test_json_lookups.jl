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
const _JL_SL = JsonLookupMockSQLite()
const _JL_PG = JsonLookupMockPostgres()

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
  # single plain-text parameter (NOT through the JSON formater, which would reject "hamilton").
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

end
