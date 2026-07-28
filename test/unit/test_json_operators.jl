"""
Unit coverage for the PostgreSQL-only JSONB containment/overlap operators (#27):
`__@jcontains` (@>), `__@has_key` (?), `__@has_any_keys` (?|), `__@has_keys` (?&).

These are PostgreSQL-only (SQLite has no equivalent): the SQLite renderer throws a friendly
UnsupportedConnectionError, mirroring the `iunaccent_*` precedent. The RHS binds per operator — a jsonb
document (`::jsonb`) for @>, a text key for ?, a text[] key array for ?|/?&. LibPQ binds `\$N`
placeholders, so a literal `?`/`?|`/`?&` in the SQL is the operator, not a bind marker.

Sibling coverage: `test_json_lookups.jl` (both-dialect path lookups); `test/integration/test_json_fields.jl`.
"""

using Test
using PormG
using PormG.Models

struct JsonOpMockSQLite <: PormG.PormGSQLite end
struct JsonOpMockPostgres <: PormG.PormGPostgres end
const _JO_SL = JsonOpMockSQLite()
const _JO_PG = JsonOpMockPostgres()

PormG.config["json_operator_mock"] = PormG.Configuration.Settings(
  connections = _JO_PG, change_data = true, db_def_folder = "json_operator_mock",
)

module JsonOperatorModels
import PormG
import PormG.Models
Json_op_scratch = Models.Model("json_op_scratch",
  id = Models.IDField(),
  name = Models.CharField(),                 # a non-JSON field, to test the operator's type guard
  payload = Models.JSONField(null = true),
)
PormG.Models.set_models(@__MODULE__, "json_operator_mock")
end

const JO = JsonOperatorModels
import PormG.QueryBuilder: inspect_query

# Default dialect is mock Postgres (the operators are PG-only).
_pg(q) = inspect_query(q; connection = _JO_PG)

@testset "JSONB containment/overlap operators (#27)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # PostgreSQL SQL shape + bound parameter for each operator
  # @> binds a jsonb document; ? a text key; ?|/?& a text[] key array.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL renders @>, ?, ?|, ?& with the right bound value" begin
    # @> (jcontains) with a Dict → serialized jsonb document, cast ::jsonb
    q = JO.Json_op_scratch.objects; q.filter("payload__@jcontains" => Dict("nome" => "hamilton")); q.values("id")
    r = _pg(q)
    @test occursin("\"Tb\".\"payload\" @> \$1::jsonb", r[:sql_text])
    @test r[:parameters] == ["{\"nome\":\"hamilton\"}"]

    # ? (has_key) with a single key → text
    q = JO.Json_op_scratch.objects; q.filter("payload__@has_key" => "nome"); q.values("id")
    r = _pg(q)
    @test occursin("\"Tb\".\"payload\" ? \$1", r[:sql_text])
    @test r[:parameters] == ["nome"]

    # ?| (has_any_keys) with a key array → text[]
    q = JO.Json_op_scratch.objects; q.filter("payload__@has_any_keys" => ["nome", "team"]); q.values("id")
    r = _pg(q)
    @test occursin("\"Tb\".\"payload\" ?| \$1::text[]", r[:sql_text])
    @test r[:parameters] == [["nome", "team"]]

    # ?& (has_keys) with a key array → text[]
    q = JO.Json_op_scratch.objects; q.filter("payload__@has_keys" => ["nome", "team"]); q.values("id")
    r = _pg(q)
    @test occursin("\"Tb\".\"payload\" ?& \$1::text[]", r[:sql_text])
    @test r[:parameters] == [["nome", "team"]]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # jcontains accepts Dict / Vector / NamedTuple / raw JSON string — all serialize identically
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "jcontains accepts Dict / Vector / NamedTuple / JSON string" begin
    mk(v) = (q = JO.Json_op_scratch.objects; q.filter("payload__@jcontains" => v); q.values("id"); q)
    @test _pg(mk(Dict("a" => 1)))[:parameters]         == ["{\"a\":1}"]
    @test _pg(mk([1, 2, 3]))[:parameters]              == ["[1,2,3]"]
    @test _pg(mk((a = 1,)))[:parameters]               == ["{\"a\":1}"]
    @test _pg(mk("{\"a\":1}"))[:parameters]            == ["{\"a\":1}"]     # raw JSON string passes through
    # a raw JSON string is passed through VERBATIM (validated, not re-canonicalized) — whitespace kept
    @test _pg(mk("{ \"a\" : 1 }"))[:parameters]        == ["{ \"a\" : 1 }"]
    # an invalid JSON string is rejected at build time (format_json_sql validates)
    @test_throws PormG.InvalidValueError _pg(mk("not json"))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PostgreSQL-only: every operator throws a friendly error on SQLite
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite rejects all four operators" begin
    for (suffix, val) in [("has_key", "nome"), ("jcontains", Dict("a" => 1)),
                          ("has_any_keys", ["a", "b"]), ("has_keys", ["a", "b"])]
      q = JO.Json_op_scratch.objects
      q.filter("payload__@$(suffix)" => val)
      q.values("id")
      # message-match so an unrelated error can't masquerade as the PG-only guard
      @test_throws "requires PostgreSQL" inspect_query(q; connection = _JO_SL)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Type guard: an operator on a non-JSON column is rejected
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "operator on a non-JSON field is rejected" begin
    q = JO.Json_op_scratch.objects
    q.filter("name__@has_key" => "x")          # `name` is a CharField
    q.values("id")
    @test_throws PormGError _pg(q)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Scope guard: a containment operator on a NESTED key path is rejected (v1)
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "operator on a nested key path is rejected (v1)" begin
    q = JO.Json_op_scratch.objects
    q.filter("payload__meta__@has_key" => "x")
    q.values("id")
    @test_throws PormGError _pg(q)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Shape guard: ?| / ?& require an array of keys, not a scalar
  # A scalar reaches the array branch and would otherwise bind a malformed text[] — reject clearly.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "has_any_keys / has_keys require an array" begin
    for suffix in ("has_any_keys", "has_keys")
      q = JO.Json_op_scratch.objects
      q.filter("payload__@$(suffix)" => "single")   # scalar, not a vector
      q.values("id")
      @test_throws PormGError _pg(q)
    end
  end

end
