"""
Unit tests for pattern lookups on a `UUIDField` (#902).

A pattern lookup (`@contains`, `@startswith`, `@endswith`, their `i`/`n` variants, `@regex`) takes a
FRAGMENT of a UUID, which the strict `format_uuid_sql` used to refuse on both engines (`FilterError`).
A whole UUID got past it, but PostgreSQL has no `LIKE` for `uuid`, so the server would reject the SQL.

The match is against the canonical lowercase hyphenated text — what SQLite stores and what PostgreSQL
prints. Django's PostgreSQL backend reads the same `::text`; its hyphen stripping (`UUIDTextMixin`)
exists only for backends that store 32 hex digits, which PormG never does. So:

- PostgreSQL wraps the column as `CAST(col AS text)`; SQLite reads it as it is.
- The fragment binds as plain text on both engines.
- Every other lookup (`=`, `@in`, ordering) compares the column natively, with the value validated.

Covers the model-field arm, the joined-path arm and a projection alias — all three go through
`_pattern_operand` / `_lookup_formatter` (`src/querybuilder/filter_nodes.jl`).

Hermetic: mock connections only. The live half is the UUID round trip in
`test/integration/test_field_validation_db_roundtrip.jl`, on both engines.
"""
# julia --project=test/integration test/unit/test_uuid_pattern_lookups.jl

using Test
using PormG
using PormG.Models: Model, IDField, UUIDField, CharField, ForeignKey
using PormG.Functions: Case, When

struct _MockPgUuid902 <: PormG.PormGPostgres end
struct _MockSlUuid902 <: PormG.PormGSQLite end
PormG.config["uuid902_pg"] = PormG.Configuration.Settings(connections = _MockPgUuid902(), change_data = true)
PormG.config["uuid902_sl"] = PormG.Configuration.Settings(connections = _MockSlUuid902(), change_data = true)

# A car's telemetry token, and the laps that reference the car — the joined path reads the token
# through the foreign key.
function _uuid902_models(key::String)
  car = Model("uuid902_car_$key", id = IDField(), chassis = CharField(max_length = 20),
              token = UUIDField(null = true))
  lap = Model("uuid902_lap_$key", id = IDField(), carid = ForeignKey(car, pk_field = "id"))
  car.connect_key = key; car._module = Main
  lap.connect_key = key; lap._module = Main
  return car, lap
end
const _CAR_PG, _LAP_PG = _uuid902_models("uuid902_pg")
const _CAR_SL, _LAP_SL = _uuid902_models("uuid902_sl")

const _TOKEN902 = "550e8400-e29b-41d4-a716-446655440000"

_sql902(q) = q.list(show_query = :dict)

@testset "UUIDField pattern lookups (#902)" begin
  # ─────────────────────────────────────────────────────────────────────────────
  # Model field: PostgreSQL casts the column, SQLite reads it as stored
  # The fragment is bound as text (decorated with `%` by the LIKE operators), never validated as a UUID.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a fragment on the column" begin
    q = _CAR_PG.objects.filter("token__@startswith" => "550e")
    q.values("id")
    res = _sql902(q)
    @test occursin("WHERE CAST(\"Tb\".\"token\" AS text) LIKE \$1", res[:sql_text])
    @test res[:parameters] == ["550e%"]

    q_sl = _CAR_SL.objects.filter("token__@startswith" => "550e")
    q_sl.values("id")
    res_sl = _sql902(q_sl)
    # SQLite's column is already the text, so nothing wraps it.
    @test occursin("WHERE \"Tb\".\"token\" LIKE ?", res_sl[:sql_text])
    @test !occursin("CAST(", res_sl[:sql_text])
    @test res_sl[:parameters] == ["550e%"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Every pattern operator gets the same operand
  # The case-insensitive, negated and regex forms are the same lookup over the same text.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the case-insensitive, negated and regex forms" begin
    for (lookup, value) in [("@icontains", "E29B"), ("@nendswith", "0000"), ("@regex", "^550e"),
                            ("@contains", _TOKEN902)]
      q = _CAR_PG.objects.filter("token__$lookup" => value)
      q.values("id")
      res = _sql902(q)
      @test occursin("CAST(\"Tb\".\"token\" AS text)", res[:sql_text])
      # Bound as given (plus the LIKE decoration) — never `format_uuid_sql`'s lowercased whole UUID.
      @test occursin(value, string(only(res[:parameters])))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Joined path and projection alias
  # A path through a foreign key and an alias over the column reach the same two helpers, so they
  # read the same text. Before the fix both refused the fragment.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a joined path and a projection alias" begin
    q = _LAP_PG.objects.filter("carid__token__@startswith" => "550e")
    q.values("id")
    res = _sql902(q)
    @test occursin(r"CAST\(\"Tb_\d+\"\.\"token\" AS text\) LIKE \$1", res[:sql_text])
    @test res[:parameters] == ["550e%"]

    q_a = _CAR_PG.objects
    q_a.values("chassis", "t2" => F("token"))
    q_a.filter("t2__@endswith" => "0000")
    res_a = _sql902(q_a)
    @test occursin("CAST(\"Tb\".\"token\" AS text) LIKE \$1", res_a[:sql_text])
    @test res_a[:parameters] == ["%0000"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A `UUID` object as the pattern
  # Plain text is what a fragment binds as, but `format_text_sql` refuses a `UUID` (#860). A whole
  # `UUID` value is matched as the column's text instead — it worked on SQLite before #902, and
  # must not start raising because the column is now read as text.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a UUID object as the value" begin
    for (model, key) in [(_CAR_PG, "pg"), (_CAR_SL, "sl")]
      q = model.objects.filter("token__@contains" => Base.UUID(uppercase(_TOKEN902)))
      q.values("id")
      @test _sql902(q)[:parameters] == ["%$(_TOKEN902)%"]
    end
    q_a = _CAR_PG.objects
    q_a.values("chassis", "t2" => F("token"))
    q_a.filter("t2__@startswith" => Base.UUID(_TOKEN902))
    @test _sql902(q_a)[:parameters] == ["$(_TOKEN902)%"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A `When` condition on the alias
  # It renders through the column path rather than the alias filter path, and has no field there;
  # the alias's formatter is what says the column is a UUID.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a When condition on a projection alias" begin
    q = _CAR_PG.objects
    q.values("chassis", "t2" => F("token"),
             "early" => Case([When(Q("t2__@startswith" => "550e"), then = 1)], default = 0))
    res = _sql902(q)
    @test occursin("WHEN (CAST(\"Tb\".\"token\" AS text) LIKE \$1", res[:sql_text])
    @test "550e%" in res[:parameters]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Only a pattern lookup changes
  # Equality compares the uuid natively and still validates the value, so a fragment there is an
  # error rather than a silent no-match.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "equality is unchanged" begin
    q = _CAR_PG.objects.filter("token" => uppercase(_TOKEN902))
    q.values("id")
    res = _sql902(q)
    @test occursin("WHERE \"Tb\".\"token\" = \$1", res[:sql_text]) && !occursin("CAST(", res[:sql_text])
    @test res[:parameters] == [_TOKEN902]
    @test_throws PormG.InvalidValueError _sql902(_CAR_PG.objects.filter("token" => "550e"))
    @test_throws PormG.InvalidValueError _sql902(_CAR_SL.objects.filter("token" => "550e"))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# An alias the type ladder could not name (#929)
# #902/#903 typed a pattern lookup's alias from its projection's formatter, but a `Cast(…, "uuid")`
# alias had none (`_sql_type_field` did not know `uuid`) and a `Subquery(...)` alias was typed by
# nothing at all, so both rendered `LIKE` on a uuid, which PostgreSQL rejects. Now the cast names its
# type, and a subquery has its one projected column's formatter, as the inner build resolved it.
# ─────────────────────────────────────────────────────────────────────────────
using PormG.Functions: Cast, Max
using PormG.QueryBuilder: Subquery, OuterRef

@testset "a Cast or Subquery alias over a uuid (#929)" begin
  token_of(car) = Subquery(car.objects.filter("id" => OuterRef("id")).values("token"))
  # The token reached through the lap's foreign key: the inner build resolves a JOINED path, which
  # only its own memo knows — the reason the formatter is read while the inner build is alive.
  joined_token_of(car, lap) = Subquery(lap.objects.filter("carid" => OuterRef("id")).values("carid__token"))

  @testset "PostgreSQL wraps the alias as text" begin
    for (label, proj) in (("Cast", Cast("chassis", "uuid")), ("Subquery", token_of(_CAR_PG)),
                          ("Subquery over a joined path", joined_token_of(_CAR_PG, _LAP_PG)))
      for (lookup, value, bound) in (("@startswith", "550e", "550e%"), ("@icontains", "E29B", "%E29B%"))
        q = _CAR_PG.objects
        q.values("id", "t" => proj)
        q.filter("t__$lookup" => value)
        res = _sql902(q)
        @test occursin(r"WHERE (UPPER\()?CAST\(.+ AS text\)\)? (I)?LIKE (UPPER\()?\$1", replace(res[:sql_text], r"\s+" => " "))
        @test !occursin(r"::uuid\)? (I)?LIKE"i, replace(res[:sql_text], r"\s+" => " "))
        @test res[:parameters] == [bound]
      end
    end
  end

  @testset "SQLite reads it as it is" begin
    for proj in (Cast("chassis", "uuid"), token_of(_CAR_SL))
      q = _CAR_SL.objects
      q.values("id", "t" => proj)
      q.filter("t__@startswith" => "550e")
      res = _sql902(q)
      @test occursin(r"WHERE (CAST\(\"Tb\"\.\"chassis\" AS TEXT\)|\(SELECT .+\)) LIKE \?", replace(res[:sql_text], r"\s+" => " "))
      @test res[:parameters] == ["550e%"]
    end
  end

  # The formatter is what the alias's values are checked against. A UUID value is validated and
  # canonicalized wherever the compared value IS the canonical text: a cast on PostgreSQL (`::uuid`
  # compares semantically) and a subquery over a `UUIDField`, whose column stores that text, on both.
  check_uuid(car, proj) = begin
    good = car.objects
    good.values("id", "t" => proj)
    good.filter("t" => uppercase(_TOKEN902))
    @test _sql902(good)[:parameters] == [_TOKEN902]
    bad = car.objects
    bad.values("id", "t" => proj)
    bad.filter("t" => "not-a-uuid")
    err = try; _sql902(bad); nothing; catch e; e; end
    @test err isa PormG.InvalidValueError
    @test occursin("projection alias (uuid)", replace(sprint(showerror, err), r"\e\[[0-9;]*m" => ""))
  end
  @testset "equality validates the value" begin
    check_uuid(_CAR_PG, Cast("chassis", "uuid"))
    check_uuid(_CAR_PG, token_of(_CAR_PG))
    check_uuid(_CAR_SL, token_of(_CAR_SL))
    num = _CAR_PG.objects
    num.values("chassis", "top" => Subquery(_CAR_PG.objects.filter("id" => OuterRef("id")).values("m" => Max("id"))))
    num.filter("top" => "abc")
    @test_throws PormG.InvalidValueError _sql902(num)
  end

  # On SQLite `Cast(x, "uuid")` is `CAST(x AS TEXT)`: the SQL normalizes nothing, so neither does the
  # value. Lowercasing it would stop it matching an upper-case value stored in a text column
  # (`chassis` is a `CharField`), and the cast never claimed the text was a UUID (review of #929).
  @testset "SQLite: a uuid cast binds its value as written" begin
    for value in (uppercase(_TOKEN902), "not-a-uuid")
      q = _CAR_SL.objects
      q.values("id", "t" => Cast("chassis", "uuid"))
      q.filter("t" => value)
      res = _sql902(q)
      @test occursin("WHERE CAST(\"Tb\".\"chassis\" AS TEXT) = ?", res[:sql_text])
      @test res[:parameters] == [value]
    end
  end

  # A CTE column declared `uuid` was refused on both engines ("cannot be typed from the SQL type
  # uuid"). On PostgreSQL it is typed now, and a filter on it is wrapped like the column's; on SQLite,
  # where the cast is text, it stays refused.
  @testset "a CTE column declared uuid" begin
    cte_query(car) = begin
      body = car.objects
      body.values("id", "u" => Cast("chassis", "uuid"))
      q = car.objects
      q.with("ev" => body, join_field = "id" => "id")
      q.values("id", "ev__u")
      q.filter("ev__u__@startswith" => "550e")
      q
    end
    res = _sql902(cte_query(_CAR_PG))
    @test occursin(r"WHERE CAST\(\"R1_1\"\.\"u\" AS text\) LIKE \$1", res[:sql_text])
    @test res[:parameters] == ["550e%"]
    err = try; _sql902(cte_query(_CAR_SL)); nothing; catch e; e; end
    @test err isa PormG.QueryBuildError
    @test occursin("cannot be typed from the SQL type", replace(sprint(showerror, err), r"\e\[[0-9;]*m" => ""))
  end
end
