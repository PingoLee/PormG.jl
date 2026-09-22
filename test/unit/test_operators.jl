"""
Unit tests for PormGsuffix operator SQL generation.

Verifies that every operator alias defined in PormGsuffix produces the correct
SQL token and stores the correct bound parameter — with no live database required
(`show_query=:dict` mode).

Why a dedicated file?
  - `test_parameters.jl`  → tests the *parameter storage layer* (buckets, ordering).
  - `test_complex_queries.jl` → tests multi-step query *patterns* (pagination, Q objects, etc.).
  - This file → tests that each *operator suffix* (gt, gte, in, contains, …) emits the
    right SQL fragment.  One clear responsibility per file.
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, DateField, DateTimeField,
                    BooleanField, DurationField, UUIDField, JSONField, BinaryField, ForeignKey
using PormG.QueryBuilder: Q
using Dates
import Logging

# ---------------------------------------------------------------------------
# Minimal test models — same shape as test_complex_queries.jl so both files
# can be included independently or together without re-definition conflicts.
# ---------------------------------------------------------------------------
if !isdefined(Main, :_OperTestDriver)
  _OperTestDriver = Model("drivers",
    id          = IDField(),
    forename    = CharField(),
    surname     = CharField(),
    nationality = CharField()
  )
  _OperTestDriver.connect_key = "default"

  _OperTestRace = Model("races",
    id   = IDField(),
    name = CharField(),
    year = IntegerField()
  )
  _OperTestRace.connect_key = "default"

  _OperTestEvent = Model("events",
    id        = IDField(),
    happened  = DateField(),
    logged_at = DateTimeField()
  )
  _OperTestEvent.connect_key = "default"

  struct _MockPostgresOper <: PormG.PormGPostgres end
  _MockSettingsOper = PormG.Configuration.Settings(
    connections  = _MockPostgresOper(),
    change_data  = true
  )
  PormG.config["default"] = _MockSettingsOper
end

# Shorthand aliases kept local to this module's scope
const _D = _OperTestDriver
const _R = _OperTestRace
const _E = _OperTestEvent

@testset "PormGsuffix — Operator SQL Generation" begin

  # =========================================================================
  # 1. Comparison operators
  # =========================================================================
  @testset "Comparison operators (gt, gte, lt, lte, ne)" begin
    # Each entry: (suffix, expected SQL token, test description)
    for (suffix, sql_op) in [
        ("gt",  ">"),
        ("gte", ">="),
        ("lt",  "<"),
        ("lte", "<="),
        ("ne",  "!="),
    ]
      # Expected SQL: WHERE "id" <op> $1
      q   = _D.objects.filter("id__@$suffix" => 42)
      res = q.list(show_query=:dict)

      @test contains(res[:sql_text], sql_op)  # "@$suffix must emit '$sql_op' in SQL"
      @test res[:parameters] == [42]          # "@$suffix must bind value 42"
    end
  end

  # =========================================================================
  # 1b. Temporal scalar comparison values (Date / DateTime)
  # =========================================================================
  @testset "Scalar Date/DateTime comparison values" begin
    # Regression: a *scalar* Date/DateTime must be accepted as a filter value.
    # OperObject.values previously allowed Dates.TimeType only inside a Vector,
    # so `filter("field__@lte" => now())` threw a convert MethodError.
    d  = Date(2026, 6, 15)
    dt = DateTime(2026, 6, 15, 18, 30, 0)

    # The value is accepted and bound (normalized to an ISO string parameter); before
    # the fix, building the filter threw before reaching parameter binding.
    q_d = _E.objects.filter("happened__@lte" => d)
    res_d = q_d.list(show_query=:dict)
    @test contains(res_d[:sql_text], "<=")
    @test res_d[:parameters] == ["2026-06-15"]

    q_dt = _E.objects.filter("logged_at__@gte" => dt)
    res_dt = q_dt.list(show_query=:dict)
    @test contains(res_dt[:sql_text], ">=")
    @test length(res_dt[:parameters]) == 1
    @test startswith(res_dt[:parameters][1], "2026-06-15T18:30:00")
  end

  # =========================================================================
  # 2. BETWEEN  (range)
  # =========================================================================
  @testset "Range operator (range → BETWEEN)" begin
    # Expected SQL: WHERE "id" BETWEEN $1 AND $2
    # With Vector
    q_vec = _D.objects.filter("id__@range" => [10, 50])
    res_vec = q_vec.list(show_query=:dict)
    @test contains(res_vec[:sql_text], "BETWEEN")
    @test res_vec[:parameters] == [10, 50]

    # With Tuple — both forms must be accepted
    q_tup = _D.objects.filter("id__@range" => (10, 50))
    res_tup = q_tup.list(show_query=:dict)
    @test contains(res_tup[:sql_text], "BETWEEN")
    @test res_tup[:parameters] == [10, 50]
  end

  # =========================================================================
  # 3. IN / NOT IN
  # =========================================================================
  @testset "IN and NOT IN operators (in, nin)" begin
    lucky = [1, 2, 3]

    # Expected SQL (Postgres): WHERE "id" = ANY($1)
    # Expected SQL (generic):  WHERE "id" IN ($1, $2, $3)
    q_in  = _D.objects.filter("id__@in"  => lucky)
    res_in = q_in.list(show_query=:dict)
    @test contains(res_in[:sql_text], "= ANY") || contains(res_in[:sql_text], " IN ")
    if contains(res_in[:sql_text], "= ANY")
      @test res_in[:parameters] == [lucky]
    else
      @test res_in[:parameters] == lucky
    end

    # Expected SQL (Postgres): WHERE "id" <> ALL($1)
    # Expected SQL (generic):  WHERE "id" NOT IN ($1, $2, $3)
    q_nin  = _D.objects.filter("id__@nin" => lucky)
    res_nin = q_nin.list(show_query=:dict)
    @test contains(res_nin[:sql_text], "<> ALL") || contains(res_nin[:sql_text], "NOT IN")
    if contains(res_nin[:sql_text], "<> ALL")
      @test res_nin[:parameters] == [lucky]
    else
     @test res_nin[:parameters] == lucky
    end
  end

  # =========================================================================
  # 4. String pattern operators
  # =========================================================================
  @testset "String pattern operators (contains, icontains, startswith, endswith)" begin

    # contains → LIKE '%val%'
    # The bound value must be wrapped in % wildcards.
    q_c = _D.objects.filter("forename__@contains" => "lew")
    r_c = q_c.list(show_query=:dict)
    @test contains(r_c[:sql_text], "LIKE") || contains(r_c[:sql_text], "ILIKE")
    @test contains(r_c[:sql_text], "ESCAPE")
    @test r_c[:parameters] == ["%lew%"]

    # icontains → ILIKE '%val%' (PostgreSQL) or pormg_lower(col) LIKE pormg_lower('%val%') (SQLite, #78).
    # NOTE: these _OperTest models render through a PostgreSQL mock (_MockPostgresOper), so this checks
    # the operator SHAPE only — it is NOT a SQLite gate. The SQLite pormg_lower rendering is gated in
    # test_alignment_sqlite.jl and the UDF's folding behavior in test_pormg_lower_udf.jl. The bound
    # value is passed as-is; case folding happens in SQL.
    q_ic = _D.objects.filter("forename__@icontains" => "LEW")
    r_ic = q_ic.list(show_query=:dict)
    @test contains(r_ic[:sql_text], "ILIKE") || contains(r_ic[:sql_text], "pormg_lower")
    @test contains(r_ic[:sql_text], "ESCAPE")
    @test r_ic[:parameters] == ["%LEW%"]

    # iunaccent_contains → public.immutable_unaccent(column) ILIKE public.immutable_unaccent('%val%')
    q_iua = _D.objects.filter("forename__@iunaccent_contains" => "sao jose")
    r_iua = q_iua.list(show_query=:dict)
    @test contains(r_iua[:sql_text], "public.immutable_unaccent")
    @test contains(r_iua[:sql_text], "ILIKE")
    @test contains(r_iua[:sql_text], "ESCAPE")
    @test r_iua[:parameters] == ["%sao jose%"]

    # iunaccent_exact → LOWER(immutable_unaccent(column)) = LOWER(immutable_unaccent('val'))
    # Accent- and case-insensitive equality: no wildcards, no ESCAPE, value passed as-is.
    q_iue = _D.objects.filter("forename__@iunaccent_exact" => "são josé")
    r_iue = q_iue.list(show_query=:dict)
    @test contains(r_iue[:sql_text], "public.immutable_unaccent")
    @test contains(r_iue[:sql_text], "LOWER")
    @test contains(r_iue[:sql_text], "=")
    @test !contains(r_iue[:sql_text], "ESCAPE")
    @test r_iue[:parameters] == ["são josé"]

    # startswith → LIKE 'val%'
    q_sw = _D.objects.filter("nationality__@startswith" => "Brit")
    r_sw = q_sw.list(show_query=:dict)
    @test contains(r_sw[:sql_text], "LIKE") || contains(r_sw[:sql_text], "ILIKE")
    @test contains(r_sw[:sql_text], "ESCAPE")
    @test r_sw[:parameters] == ["Brit%"]

    # endswith → LIKE '%val'
    q_ew = _D.objects.filter("forename__@endswith" => "wis")
    r_ew = q_ew.list(show_query=:dict)
    @test contains(r_ew[:sql_text], "LIKE") || contains(r_ew[:sql_text], "ILIKE")
    @test contains(r_ew[:sql_text], "ESCAPE")
    @test r_ew[:parameters] == ["%wis"]

    # istartswith → ILIKE 'val%' (#604). The renderers shipped with #78; only the wiring was
    # missing, so before that fix this filter raised FilterError instead of building a query.
    # The wildcard must be on ONE side only — the bug's silent form was an undecorated value,
    # i.e. an accidental iexact.
    q_isw = _D.objects.filter("nationality__@istartswith" => "brit")
    r_isw = q_isw.list(show_query=:dict)
    @test contains(r_isw[:sql_text], "ILIKE") || contains(r_isw[:sql_text], "pormg_lower")
    @test contains(r_isw[:sql_text], "ESCAPE")
    @test r_isw[:parameters] == ["brit%"]

    # iendswith → ILIKE '%val' (#604)
    q_iew = _D.objects.filter("forename__@iendswith" => "WIS")
    r_iew = q_iew.list(show_query=:dict)
    @test contains(r_iew[:sql_text], "ILIKE") || contains(r_iew[:sql_text], "pormg_lower")
    @test contains(r_iew[:sql_text], "ESCAPE")
    @test r_iew[:parameters] == ["%WIS"]
  end

  # =========================================================================
  # 4b. Negated pattern operators (#207): NOT LIKE / NOT ILIKE / <>
  # Same wildcard decoration as the positive twin; only the operator flips.
  # NOTE (as above): the _OperTest models render through a PostgreSQL mock, so
  # these assert the PG operator SHAPE. Crucially, "NOT LIKE" contains "LIKE"
  # and "NOT ILIKE" contains "ILIKE", so each test asserts the "NOT " prefix
  # explicitly — a bare contains(…, "LIKE") would pass on the positive form too.
  # =========================================================================
  @testset "Negated pattern operators (ncontains, nstartswith, nendswith, nicontains) — #207" begin
    # ncontains → NOT LIKE '%val%'
    q_nc = _D.objects.filter("forename__@ncontains" => "lew")
    r_nc = q_nc.list(show_query=:dict)
    @test contains(r_nc[:sql_text], "NOT LIKE")
    @test contains(r_nc[:sql_text], "ESCAPE")
    @test r_nc[:parameters] == ["%lew%"]

    # nicontains → NOT ILIKE '%val%' (PostgreSQL) / pormg_lower(col) NOT LIKE … (SQLite, #78)
    q_nic = _D.objects.filter("forename__@nicontains" => "LEW")
    r_nic = q_nic.list(show_query=:dict)
    @test contains(r_nic[:sql_text], "NOT ILIKE") || contains(r_nic[:sql_text], "NOT LIKE")
    @test contains(r_nic[:sql_text], "ESCAPE")
    @test r_nic[:parameters] == ["%LEW%"]

    # nstartswith → NOT LIKE 'val%'
    q_nsw = _D.objects.filter("nationality__@nstartswith" => "Brit")
    r_nsw = q_nsw.list(show_query=:dict)
    @test contains(r_nsw[:sql_text], "NOT LIKE")
    @test contains(r_nsw[:sql_text], "ESCAPE")
    @test r_nsw[:parameters] == ["Brit%"]

    # nendswith → NOT LIKE '%val'
    q_new = _D.objects.filter("forename__@nendswith" => "wis")
    r_new = q_new.list(show_query=:dict)
    @test contains(r_new[:sql_text], "NOT LIKE")
    @test contains(r_new[:sql_text], "ESCAPE")
    @test r_new[:parameters] == ["%wis"]

    # nistartswith → NOT ILIKE 'val%' (#604). New in Dialect, added so the #207 negated set stays
    # complete once istartswith/iendswith became reachable — the docs state the "every pattern
    # lookup has a negated twin" rule universally.
    q_nisw = _D.objects.filter("nationality__@nistartswith" => "brit")
    r_nisw = q_nisw.list(show_query=:dict)
    @test contains(r_nisw[:sql_text], "NOT ILIKE") || contains(r_nisw[:sql_text], "NOT LIKE")
    @test contains(r_nisw[:sql_text], "ESCAPE")
    @test r_nisw[:parameters] == ["brit%"]

    # niendswith → NOT ILIKE '%val' (#604)
    q_niew = _D.objects.filter("forename__@niendswith" => "WIS")
    r_niew = q_niew.list(show_query=:dict)
    @test contains(r_niew[:sql_text], "NOT ILIKE") || contains(r_niew[:sql_text], "NOT LIKE")
    @test contains(r_niew[:sql_text], "ESCAPE")
    @test r_niew[:parameters] == ["%WIS"]
  end

  # =========================================================================
  # 4c. Negated unaccent operators (#207) — PostgreSQL-only, mirror positive twin
  # =========================================================================
  @testset "Negated unaccent operators (niunaccent_contains, niunaccent_exact) — #207" begin
    # niunaccent_contains → immutable_unaccent(col) NOT ILIKE immutable_unaccent('%val%')
    q_niuc = _D.objects.filter("forename__@niunaccent_contains" => "sao jose")
    r_niuc = q_niuc.list(show_query=:dict)
    @test contains(r_niuc[:sql_text], "public.immutable_unaccent")
    @test contains(r_niuc[:sql_text], "NOT ILIKE")
    @test contains(r_niuc[:sql_text], "ESCAPE")
    @test r_niuc[:parameters] == ["%sao jose%"]

    # niunaccent_exact → LOWER(immutable_unaccent(col)) <> LOWER(immutable_unaccent('val'))
    # No wildcards, no ESCAPE, value passed as-is.
    q_niue = _D.objects.filter("forename__@niunaccent_exact" => "são josé")
    r_niue = q_niue.list(show_query=:dict)
    @test contains(r_niue[:sql_text], "public.immutable_unaccent")
    @test contains(r_niue[:sql_text], "LOWER")
    @test contains(r_niue[:sql_text], "<>")
    @test !contains(r_niue[:sql_text], "ESCAPE")
    @test r_niue[:parameters] == ["são josé"]
  end

  # =========================================================================
  # 4d. Negated range operator (#207): nrange → NOT BETWEEN
  # =========================================================================
  @testset "Negated range operator (nrange → NOT BETWEEN) — #207" begin
    # With Vector — "NOT BETWEEN" contains "BETWEEN", so assert the "NOT " prefix.
    q_vec = _D.objects.filter("id__@nrange" => [10, 50])
    res_vec = q_vec.list(show_query=:dict)
    @test contains(res_vec[:sql_text], "NOT BETWEEN")
    @test res_vec[:parameters] == [10, 50]

    # With Tuple — both forms must be accepted, same as positive range.
    q_tup = _D.objects.filter("id__@nrange" => (10, 50))
    res_tup = q_tup.list(show_query=:dict)
    @test contains(res_tup[:sql_text], "NOT BETWEEN")
    @test res_tup[:parameters] == [10, 50]

    # Shape guard: a 3-element vector is rejected, and the error must name the operator and
    # the 2-value requirement. A bare @test_throws would also pass on an unrelated error
    # (e.g. if `nrange` were missing from the vector allowed-op list), so assert the cause.
    err_nr = try
      _D.objects.filter("id__@nrange" => [1, 2, 3]).list(show_query=:dict)
      nothing
    catch e
      e
    end
    @test err_nr !== nothing
    @test occursin("nrange", sprint(showerror, err_nr))
    @test occursin("exactly 2 values", sprint(showerror, err_nr))
  end

  # =========================================================================
  # 5. NULL checks  (isnull)
  # =========================================================================
  @testset "NULL check operator (isnull)" begin
    # isnull => true  → IS NULL
    q_null = _D.objects.filter("forename__@isnull" => true)
    r_null = q_null.list(show_query=:dict)
    @test contains(r_null[:sql_text], "IS NULL") || contains(r_null[:sql_text], "ISNULL")

    # isnull => false → IS NOT NULL
    q_notnull = _D.objects.filter("forename__@isnull" => false)
    r_notnull = q_notnull.list(show_query=:dict)
    @test contains(r_notnull[:sql_text], "IS NOT NULL") || contains(r_notnull[:sql_text], "ISNULL")
  end

  # =========================================================================
  # 6. Default equality (no suffix)
  # =========================================================================
  @testset "Default equality (no suffix → =)" begin
    q   = _D.objects.filter("id" => 1)
    res = q.list(show_query=:dict)
    @test contains(res[:sql_text], "=")
    @test res[:parameters] == [1]
  end

  # =========================================================================
  # 7. Combined multi-operator query
  # =========================================================================
  @testset "Combined multi-operator query" begin
    # Mixing gt, lte, and icontains in a single WHERE clause.
    # Expected SQL: WHERE "id" > $1 AND "id" <= $2 AND (ILIKE / LIKE pattern)
    q = _D.objects.filter(
      "id__@gt"               => 10,
      "id__@lte"              => 50,
      "nationality__@icontains" => "brit"
    )
    res = q.list(show_query=:dict)

    @test contains(res[:sql_text], ">")
    @test contains(res[:sql_text], "<=")
    @test contains(res[:sql_text], "ILIKE") || contains(res[:sql_text], "LIKE")
    # Three bound values: 10, 50, "%brit%"
    @test length(res[:parameters]) == 3
    @test 10     in res[:parameters]
    @test 50     in res[:parameters]
    @test "%brit%" in res[:parameters]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Bitwise Operators: F-Expression Bitwise Operations
  # Verifies that bitwise overloads (&, |, ~, <<, >>, xor/⊻) on F-Expressions,
  # WindowFunctions, and FObjects produce correct bitwise SQL tokens on PostgreSQL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Bitwise Operators on F-Expressions" begin
    # AND, OR, Left Shift, Right Shift
    q_and = _D.objects.values("res" => F("id") & 4)
    res_and = q_and.list(show_query=:dict)
    @test contains(res_and[:sql_text], "&")
    @test res_and[:parameters] == [4]

    q_or = _D.objects.values("res" => F("id") | 2)
    res_or = q_or.list(show_query=:dict)
    @test contains(res_or[:sql_text], "|")
    @test res_or[:parameters] == [2]

    q_not = _D.objects.values("res" => ~F("id"))
    res_not = q_not.list(show_query=:dict)
    @test contains(res_not[:sql_text], "~")

    q_shl = _D.objects.values("res" => F("id") << 1)
    res_shl = q_shl.list(show_query=:dict)
    @test contains(res_shl[:sql_text], "<<")
    @test res_shl[:parameters] == [1]

    q_shr = _D.objects.values("res" => F("id") >> 2)
    res_shr = q_shr.list(show_query=:dict)
    @test contains(res_shr[:sql_text], ">>")
    @test res_shr[:parameters] == [2]

    q_shl_left = _D.objects.values("res" => 1 << F("id"))
    res_shl_left = q_shl_left.list(show_query=:dict)
    @test contains(res_shl_left[:sql_text], "<<")
    @test contains(res_shl_left[:sql_text], "\$1::integer << \"Tb\".\"id\"")
    @test res_shl_left[:parameters] == [1]

    q_shr_left = _D.objects.values("res" => 8 >> F("id"))
    res_shr_left = q_shr_left.list(show_query=:dict)
    @test contains(res_shr_left[:sql_text], ">>")
    @test contains(res_shr_left[:sql_text], "\$1::integer >> \"Tb\".\"id\"")
    @test res_shr_left[:parameters] == [8]

    # XOR / ⊻
    q_xor = _D.objects.values("res" => F("id") ⊻ 4)
    res_xor = q_xor.list(show_query=:dict)
    # On PostgreSQL mock connection, it should render native XOR '#'
    @test contains(res_xor[:sql_text], "#")
    @test res_xor[:parameters] == [4]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Bitwise Documentation Examples SQL Verification (PostgreSQL Syntax)
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Bitwise Documentation Examples - PostgreSQL SQL Verification" begin
    _DocDriver = Model("drivers",
      id = IDField(),
      surname = CharField(),
      number = IntegerField(null=true)
    )
    _DocDriver.connect_key = "default"

    # 1. Projection values()
    q_proj = _DocDriver.objects.values(
      "surname",
      "number",
      "is_odd" => F("number") & 1
    )
    res_proj = q_proj.list(show_query=:dict)
    sql_proj = res_proj[:sql_text]
    @test contains(sql_proj, "SELECT")
    @test contains(sql_proj, "\"Tb\".\"surname\" as \"surname\"")
    @test contains(sql_proj, "\"Tb\".\"number\" as \"number\"")
    @test contains(sql_proj, "(\"Tb\".\"number\" & \$1::bigint) as \"is_odd\"")
    @test contains(sql_proj, "FROM \"drivers\" as \"Tb\"")
    @test res_proj[:parameters] == [1]

    # 2. Filtering filter()
    q_filt = _DocDriver.objects.filter(
      (F("number") & 1) > 0
    )
    res_filt = q_filt.list(show_query=:dict)
    sql_filt = res_filt[:sql_text]
    @test contains(sql_filt, "WHERE ((\"Tb\".\"number\" & \$1::bigint) > \$2::bigint)")
    @test res_filt[:parameters] == [1, 0]

    # 3. Update with XOR
    # Toggle lowest bit: update("number" => F("number") ⊻ 1)
    q_upd_xor = _DocDriver.objects.filter("id" => 1)
    res_upd_xor = q_upd_xor.update("number" => F("number") ⊻ 1, show_query=:inspection)
    @test contains(res_upd_xor[:sql_text], "UPDATE \"drivers\" AS \"Tb\"")
    @test contains(res_upd_xor[:sql_text], "SET \"number\" = (\"Tb\".\"number\" # \$2::bigint)")
    @test contains(res_upd_xor[:sql_text], "WHERE \"Tb\".\"id\" = \$1")
    @test res_upd_xor[:parameters] == [1, 1]

    # 4. Update with OR
    # Set lowest bit: update("number" => F("number") | 1)
    q_upd_or = _DocDriver.objects.filter("id" => 2)
    res_upd_or = q_upd_or.update("number" => F("number") | 1, show_query=:inspection)
    @test contains(res_upd_or[:sql_text], "UPDATE \"drivers\" AS \"Tb\"")
    @test contains(res_upd_or[:sql_text], "SET \"number\" = (\"Tb\".\"number\" | \$2::bigint)")
    @test contains(res_upd_or[:sql_text], "WHERE \"Tb\".\"id\" = \$1")
    @test res_upd_or[:parameters] == [2, 1]

    # 5. F1 Clean vs Dirty Grid Side Case Study
    _DocResult = Model("results",
      resultid = IDField(),
      grid = IntegerField(),
      position = IntegerField(null=true)
    )
    _DocResult.connect_key = "default"

    q_case = _DocResult.objects.values("grid", "position").filter(
      "position__@lte" => 3,
      (F("grid") & 1) == 0
    )
    res_case = q_case.list(show_query=:dict)
    sql_case = res_case[:sql_text]
    @test contains(sql_case, "WHERE")
    @test contains(sql_case, "\"Tb\".\"position\" <= \$1")
    @test contains(sql_case, "((\"Tb\".\"grid\" & \$2::bigint) = \$3::bigint)")
    @test res_case[:parameters] == [3, 1, 0]

    # 6. Left-hand shift scalar parameterized and typed verification
    q_left_shl = _DocDriver.objects.values(
      "surname",
      "index_mask" => 1 << F("number")
    )
    res_left_shl = q_left_shl.list(show_query=:dict)
    sql_left_shl = res_left_shl[:sql_text]
    @test contains(sql_left_shl, "SELECT")
    @test contains(sql_left_shl, "(\$1::integer << \"Tb\".\"number\") as \"index_mask\"")
    @test res_left_shl[:parameters] == [1]
  end

  # =========================================================================
  # Invalid operator diagnostics (#98)
  # An unknown or shape-incompatible operator must give one consistent,
  # actionable error across every value shape (scalar/vector/subquery/tuple):
  # list the valid operators, suggest the nearest match for a typo (e.g.
  # @notin → @nin), and clearly distinguish a typo from a *known* operator that
  # simply is not valid for that value shape (e.g. @gte with a vector). Before
  # this fix the vector/subquery/tuple paths threw a terse message with none of
  # that, so a one-character typo like @notin was a latent runtime bug.
  # =========================================================================
  @testset "Invalid operator diagnostics (#98)" begin
    # Run a filter that is expected to throw and return the exception, silencing
    # the @error _check_filter logs on the way out (keeps test output clean).
    grab(f) = try
      Logging.with_logger(Logging.NullLogger()) do
        f()
      end
      nothing
    catch e
      e
    end

    # --- vector value, UNKNOWN operator: the exact @notin → @nin typo from #98 ---
    e_vec = grab(() -> _D.objects.filter("id__@notin" => [1, 2]))
    @test e_vec isa PormGError
    m_vec = e_vec.msg
    @test occursin("is not a valid operator", m_vec)  # unknown-operator branch
    @test occursin("Did you mean", m_vec)             # nearest-match suggestion offered
    @test occursin("@nin", m_vec)                     # …and it is the intended operator
    @test occursin("Valid operators", m_vec)          # full valid-operator list present
    @test occursin("@gte", m_vec)                     # (spot-check an entry in that list)

    # --- vector value, KNOWN but shape-incompatible operator (@gte with a vector) ---
    e_known = grab(() -> _D.objects.filter("id__@gte" => [1, 2]))
    @test e_known isa PormGError
    m_known = e_known.msg
    @test occursin("not valid with a vector value", m_known)  # distinct from the typo branch
    @test !occursin("Did you mean", m_known)                  # no suggestion for a real operator
    @test occursin("use one of", m_known)                     # still points to the valid subset
    @test occursin("@in", m_known)

    # --- tuple value, unknown operator: message names the shape and its valid op ---
    e_tup = grab(() -> _D.objects.filter("id__@betwen" => (1, 2)))
    @test e_tup isa PormGError
    m_tup = e_tup.msg
    @test occursin("is not a valid operator", m_tup)
    @test occursin("tuple", m_tup)
    @test occursin("@range", m_tup)   # the only tuple-valid operator

    # --- subquery value, unknown operator: same treatment, shape = "subquery" ---
    sub = _D.objects.values("id")
    e_sub = grab(() -> _D.objects.filter("id__@notin" => sub))
    @test e_sub isa PormGError
    m_sub = e_sub.msg
    @test occursin("is not a valid operator", m_sub)
    @test occursin("@nin", m_sub)
    @test occursin("subquery", m_sub)

    # --- bare field + collection value, no __@ operator at all ---
    # Reaches the length(field_path) < 2 branch: the message must name the field
    # and show actionable examples, not treat the field name as a bogus operator.
    e_bare = grab(() -> _D.objects.filter("id" => [1, 2]))
    @test e_bare isa PormGError
    m_bare = e_bare.msg
    @test occursin("was given a vector value but no operator", m_bare)
    @test occursin("id__@in", m_bare)   # actionable example uses the real field name

    # --- short garbage suffix: unknown-operator error but NO nonsense suggestion ---
    # @xy is exactly 2 edits from @in/@ne/@gt (the whole word), so the relative
    # threshold must refuse a "did you mean"; the old floor-of-2 threshold would not.
    e_garb = grab(() -> _D.objects.filter("id__@xy" => [1, 2]))
    @test e_garb isa PormGError
    @test occursin("is not a valid operator", e_garb.msg)
    @test !occursin("Did you mean", e_garb.msg)

    # --- @range with the wrong number of values: explicit, actionable arity error ---
    # A valid operator on the right shape, but @range requires exactly 2 bounds; the
    # error must state that (and the count) rather than a generic "invalid operator".
    e_range = grab(() -> _D.objects.filter("id__@range" => [1, 2, 3]))
    @test e_range isa PormGError
    @test occursin("requires exactly 2 values", e_range.msg)
    @test occursin("got 3", e_range.msg)

    # --- no regression: the valid operator on each shape still builds fine ---
    ok_in    = _D.objects.filter("id__@in" => [1, 2]).list(show_query=:dict)
    @test ok_in isa Dict
    @test occursin("ANY", ok_in[:sql_text])   # PostgreSQL renders IN as "= ANY($1)"
    ok_range = _D.objects.filter("id__@range" => (1, 9)).list(show_query=:dict)
    @test ok_range isa Dict
    @test occursin("BETWEEN", ok_range[:sql_text])
  end

end  # end "PormGsuffix — Operator SQL Generation"

# ─────────────────────────────────────────────────────────────────────────────
# Pattern-lookup registry completeness: no operator may be half-wired (#604)
#
# This file's header claims it verifies "every operator alias defined in PormGsuffix". It did not:
# `istartswith` and `iendswith` had complete Dialect renderers (three arms each, shipped with #78)
# and were absent from PormGsuffix, from `_apply_like_wildcards` and from every operator list in
# build_helpers.jl — so they were unreachable and `filter("x__@istartswith" => v)` raised
# FilterError. Six sites restated the family as a literal; nothing checked that they agreed.
#
# These assertions close that by measuring the correspondence instead of restating a list, so the
# next lookup added to one place and not the others fails here rather than becoming a dead
# definition. Each one is red against the unpatched code: the set equality drops the two missing
# PormGsuffix keys, and the wildcard loop gets an undecorated value back.
#
# Deliberately NOT routed through a projection alias: the HAVING/alias path renders the operator
# name as a bare SQL token for the whole LIKE family (pre-existing, unrelated to #604), so an alias
# here would fail for the wrong reason.
# ─────────────────────────────────────────────────────────────────────────────
# The missing-`@` hint is reached from the field-path walk, which requires the model to carry a
# `_module`: a bare `Model(...)` has `_module === nothing` and dies in join resolution first
# (`foreing_table_module::Module = …model._module::Module`) before the hint can fire. That is an
# artifact of the shared `_OperTest*` fixtures, not of the code under test. So this check gets its
# own model rather than mutating `_D`, which `test_complex_queries.jl` shares. `Main` is a fine
# `_module` here — it is only consulted to resolve a foreign key, and this path has none.
if !isdefined(Main, :_OperHintDriver)
  _OperHintDriver = Model("drivers",
    id       = IDField(),
    forename = CharField(),
    surname  = CharField()
  )
  _OperHintDriver.connect_key = "default"
  _OperHintDriver._module = Main
end

@testset "Pattern-lookup registry is internally consistent (#604)" begin

  # A PormGsuffix entry whose value equals its key IS the `Dialect.<name>` dispatch symbol — that is
  # the documented convention in constants.jl. Every such entry is therefore either a pattern lookup
  # or a JSON containment operator, and nothing else. This is the bidirectional check: it catches a
  # suffix with no renderer AND a renderer reachable from no suffix.
  @testset "PormGsuffix self-mapping keys == pattern ∪ JSON operators" begin
    self_mapping = Set(k for (k, v) in PormG.PormGsuffix if v == k)
    declared = union(Set(PormG.PATTERN_LOOKUP_OPERATORS), Set(PormG.JSON_CONTAINMENT_OPERATORS))
    # Report the asymmetry explicitly — a bare set comparison prints two 16-element sets and makes
    # the reader diff them by eye.
    @test setdiff(self_mapping, declared) == Set{String}()   # suffix with no declared renderer
    @test setdiff(declared, self_mapping) == Set{String}()   # renderer reachable from no suffix
    @test self_mapping == declared
  end

  # The direction the two sets above CANNOT cover, and the one #604 actually needed: both sides of
  # that comparison are written in constants.jl, so a renderer that exists only in Dialect — named by
  # no constant and no suffix — is invisible to it. That is precisely what `istartswith` was. Reading
  # the renderers back out of Dialect closes it: a three-arm text-lookup renderer that nothing
  # declares now fails HERE, at the moment it is written, instead of shipping dead.
  #
  # The probe is the shared signature of the family: `(PormGPostgres, AbstractString, AbstractString)`.
  # It is discriminating rather than accidentally clean — Dialect has eight other three-argument
  # functions taking a PG connection (`create_table`, `drop_field`, `rename_table`, …) and this
  # signature excludes every one, because they are typed `::String` while the lookups widened to
  # `::AbstractString` in #603. That is also the one way to get a false positive: a future widening
  # pass that retypes a DDL helper to `AbstractString` turns this red on a non-lookup. It fails
  # CLOSED, which is the right direction — go look, then add the name to the skip or fix the cause.
  @testset "Every text-lookup renderer in Dialect is declared by a constant" begin
    sig = Tuple{PormG.PormGPostgres, AbstractString, AbstractString}
    reflected = Set{String}()
    for n in names(PormG.Dialect, all = true)
      startswith(String(n), "#") && continue          # gensyms from closures/macros
      isdefined(PormG.Dialect, n) || continue
      f = getfield(PormG.Dialect, n)
      f isa Function || continue
      hasmethod(f, sig) && push!(reflected, String(n))
    end
    declared = union(Set(PormG.PATTERN_LOOKUP_OPERATORS), Set(PormG.JSON_CONTAINMENT_OPERATORS))
    # A renderer nothing declares — the #604 shape, and the half no constants-only check can see.
    @test setdiff(reflected, declared) == Set{String}()
    # A declared name whose renderer does not exist — a typo in a constant.
    @test setdiff(declared, reflected) == Set{String}()
  end

  # Every operator the render branch dispatches to must actually have a method for all three
  # connection arms, or `getfield(Dialect, Symbol(op))(conn, col, ph)` is a MethodError at query time.
  @testset "Every PATTERN_LOOKUP_OPERATORS name has all three Dialect arms" begin
    for op in PormG.PATTERN_LOOKUP_OPERATORS
      @test isdefined(PormG.Dialect, Symbol(op))
      f = getfield(PormG.Dialect, Symbol(op))
      @test hasmethod(f, Tuple{PormG.PormGPostgres, AbstractString, AbstractString})
      @test hasmethod(f, Tuple{PormG.PormGSQLite, AbstractString, AbstractString})
      @test hasmethod(f, Tuple{PormG.PormGAbstractType, AbstractString, Any})
    end
  end

  # The wildcard shape, measured end-to-end through the public filter surface for every member of
  # each shape group. The probe value carries a literal `%`, so this also pins that the value is run
  # through escape_like_pattern — an undecorated operator skips escaping as well as wildcarding,
  # which would let user input act as a wildcard.
  @testset "Each shape group decorates and escapes its value" begin
    for (group, decorate) in ((PormG.LIKE_CONTAINS_OPERATORS, v -> "%$(v)%"),
                              (PormG.LIKE_PREFIX_OPERATORS,   v -> "$(v)%"),
                              (PormG.LIKE_SUFFIX_OPERATORS,   v -> "%$(v)"))
      for op in group
        r = _D.objects.filter("forename__@$(op)" => "a%b").list(show_query=:dict)
        # `a%b` escapes to `a\%b`; the decoration then wraps THAT, never the raw value.
        @test r[:parameters] == [decorate("a\\%b")]
        @test contains(r[:sql_text], "ESCAPE")
        # A negated operator must render the NOT form. "NOT ILIKE" contains "ILIKE", so asserting
        # the positive token alone would pass on either — assert the "NOT " prefix explicitly.
        if startswith(op, "n")
          @test contains(r[:sql_text], "NOT LIKE") || contains(r[:sql_text], "NOT ILIKE")
        else
          @test !contains(r[:sql_text], "NOT LIKE") && !contains(r[:sql_text], "NOT ILIKE")
        end
      end
    end
  end

  # The two *_exact lookups are in the render list but NOT in the wildcard list, and that asymmetry
  # is load-bearing: they compare with = / <>, so decorating or escaping their value would change
  # what they match. Pin the gap so a future "simplification" cannot collapse the two lists.
  @testset "The *_exact lookups render but take no wildcards" begin
    exact_only = setdiff(Set(PormG.PATTERN_LOOKUP_OPERATORS), Set(PormG.LIKE_WILDCARD_OPERATORS))
    @test exact_only == Set(["iunaccent_exact", "niunaccent_exact"])
    for op in exact_only
      r = _D.objects.filter("forename__@$(op)" => "a%b").list(show_query=:dict)
      @test r[:parameters] == ["a%b"]              # verbatim: no escape, no wildcard
      @test !contains(r[:sql_text], "ESCAPE")
    end
  end

  # The "you forgot the @" hint must not name a spelling that then fails. That exact two-step dead
  # end was #604's user-visible face: the hint listed `istartswith`, and `@istartswith` was not a
  # lookup. Checking the hint list against PormGsuffix wholesale would fail on the ~11 Django
  # lookups PormG does not implement, so this asserts only the property that broke.
  @testset "The missing-@ hint names only reachable pattern lookups" begin
    for op in PormG.PATTERN_LOOKUP_OPERATORS
      # `filter()` is lazy — the field path is only resolved at build time, so the terminal call is
      # what raises. Silence the @error log _check_filter emits on the way out.
      e = try
        Logging.with_logger(Logging.NullLogger()) do
          _OperHintDriver.objects.filter("forename__$(op)" => "x").list(show_query=:dict)
        end
        nothing
      catch err
        err
      end
      @test e isa PormG.FilterError
      @test occursin("requires '@' prefix", PormG.error_message(e))
      # …and the spelling it recommends builds a query rather than raising.
      @test haskey(PormG.PormGsuffix, op)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #619: the WHOLE hint list, reconciled against both registries.
  #
  # The loop above is scoped to `PATTERN_LOOKUP_OPERATORS` because widening it used to fail: the
  # hint also names 11 Django lookups PormG implements nowhere, and it promised each of them a
  # `__@name` spelling that then raised — #604's dead end, 11 more times. The membership was never
  # the defect (a near-miss hint is worth giving), the wording was, so the invariant this asserts
  # is conditional rather than universal: an example IFF the name is reachable.
  #
  # Reconciling against `PormGsuffix ∪ PormGtransform` rather than against a list is what makes it
  # non-rotting — wire one of the 11 and this test starts demanding the example form for it,
  # without anyone remembering to come back here.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Every name in the missing-@ hint is worded by its reachability (#619)" begin
    # The hint list is a local inside `_check_if_field_is_a_operator`; probing through the public
    # surface is deliberate — it is the message a user sees that is under test, not the literal.
    hint_names = [PormG.PATTERN_LOOKUP_OPERATORS...,
      "exact", "iexact", "in", "gt", "gte", "lt", "lte", "range", "nrange", "date", "isnull",
      "year", "iso_year", "quarter", "month", "day", "week", "week_day", "iso_week_day",
      "hour", "minute", "second", "regex", "iregex"]

    for name in hint_names
      e = try
        Logging.with_logger(Logging.NullLogger()) do
          _OperHintDriver.objects.filter("forename__$(name)" => "x").list(show_query=:dict)
        end
        nothing
      catch err
        err
      end
      # Every name in the list is recognised as a near-miss, reachable or not.
      @test e isa PormG.FilterError
      msg = PormG.error_message(e)

      if haskey(PormG.PormGsuffix, name) || haskey(PormG.PormGtransform, name)
        @test occursin("requires '@' prefix", msg)
        @test occursin("q.filter(\"name__@$(name)\"", msg)   # the example, which must work
      else
        # No example, and it says so. Asserting the ABSENCE of the example is the assertion that
        # would have failed before this fix — the type and the near-miss recognition would not.
        @test occursin("PormG has no", msg)
        @test !occursin("requires '@' prefix", msg)
        @test !occursin("q.filter(", msg)
      end
    end

    # The 11 are named here so the count is visible rather than implied: if one gets wired, this
    # list is where the change is declared, and the loop above proves the message moved with it.
    unreachable = [n for n in hint_names
                   if !haskey(PormG.PormGsuffix, n) && !haskey(PormG.PormGtransform, n)]
    @test sort(unreachable) == sort(["exact", "iexact", "iso_year", "week", "week_day",
                                     "iso_week_day", "hour", "minute", "second", "regex", "iregex"])

    # The alternatives table is a message table, not a registry: every key must be one of the
    # unreachable names. An entry for a name that later gets wired would advertise a detour around
    # a lookup that works.
    @test isempty(setdiff(keys(PormG.QueryBuilder.UNIMPLEMENTED_LOOKUP_HINTS), unreachable))

    # …and every `__@spelling` the alternatives RECOMMEND must itself be reachable. Without this the
    # fix reproduces #604 one level down: the keys are computed, but the suggestions inside the
    # values are free prose, so renaming `iunaccent_exact` would leave the hint advertising a dead
    # spelling — the exact defect this whole issue is about, moved into the remedy.
    for (name, hint) in PormG.QueryBuilder.UNIMPLEMENTED_LOOKUP_HINTS
      for m in eachmatch(r"__@([a-z_]+)", hint)
        suggested = m.captures[1]
        @test haskey(PormG.PormGsuffix, suggested) || haskey(PormG.PormGtransform, suggested)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #619: a name OUTSIDE the hint list is not claimed by it.
  #
  # The loop above proves each listed name gets the right message; on its own that would also pass
  # if the function threw its new "PormG has no …" error for everything. This is the discriminating
  # case — an ordinary misspelling must still fall through to the field walk's own error.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "The missing-@ hint claims only the names it lists (#619)" begin
    e = try
      Logging.with_logger(Logging.NullLogger()) do
        _OperHintDriver.objects.filter("forename__notalookup" => "x").list(show_query=:dict)
      end
      nothing
    catch err
      err
    end
    @test e !== nothing
    msg = PormG.error_message(e)
    @test !occursin("PormG has no", msg)
    @test !occursin("requires '@' prefix", msg)

    # Asserted POSITIVELY as well, and this is the half that matters: three negative assertions
    # certify whatever the current message happens to be, so they would still pass if the
    # fall-through error were junk. It currently IS junk — `QueryBuildError: The field 'CharField()'
    # does not have a 'how' property` names the field's type object and an internal property, and
    # never mentions `notalookup`. That is a pre-existing defect outside this cluster's scope and is
    # filed as a follow-up; pinning the OFFENDING NAME is the minimum this test can demand without
    # freezing the bad wording, and it fails the day the message stops naming what the user typed.
    @test occursin("notalookup", msg) broken = true
  end
end

# =============================================================================
# F-expression date arithmetic with explicit Julia duration types (#25).
#
# PostgreSQL rendering contract: `F(date) ± <period>` becomes a single
# `make_interval(...)` call with EXPLICITLY-typed placeholders — integer units as
# `$n::integer` (never bigint: `make_interval(days => bigint)` does not exist) and
# seconds as `$n::double precision`. The SQL operator mirrors +/-, and the raw
# component magnitudes are bound (compound intervals keep their internal signs).
# The SQLite counterpart (date()/datetime() + modifiers) is pinned in
# test_alignment_sqlite.jl; this file locks the typed-PG shape and parameter order.
# =============================================================================
@testset "F-expression date arithmetic — PostgreSQL make_interval (#25)" begin
  # _E = events(id, happened::DATE, logged_at::TIMESTAMPTZ) — mock PostgreSQL connection.

  # Each entry: (label, expression, expected make_interval fragment, expected params).
  # The fragment is asserted verbatim so a wrong keyword, missing cast, or dropped
  # component fails loudly.
  for (label, expr, frag, params) in [
      ("+ Day(30)",             F("happened") + Day(30),
        "(\"Tb\".\"happened\" + make_interval(days => \$1::integer))",              [30]),
      ("+ Month(3)",            F("happened") + Month(3),
        "(\"Tb\".\"happened\" + make_interval(months => \$1::integer))",            [3]),
      ("+ (Month(1)+Day(15))",  F("happened") + (Month(1) + Day(15)),
        "(\"Tb\".\"happened\" + make_interval(months => \$1::integer, days => \$2::integer))", [1, 15]),
      ("- Hour(6)",             F("logged_at") - Hour(6),
        "(\"Tb\".\"logged_at\" - make_interval(hours => \$1::integer))",            [6]),
      ("+ Week(2)",             F("happened") + Week(2),
        "(\"Tb\".\"happened\" + make_interval(weeks => \$1::integer))",             [2]),
      # Compound with an internal negative component: the magnitude is kept as-is and
      # the SQL operator stays '+', so the interval itself carries the -15.
      ("+ (Month(1)+Day(-15))", F("happened") + (Month(1) + Day(-15)),
        "(\"Tb\".\"happened\" + make_interval(months => \$1::integer, days => \$2::integer))", [1, -15]),
      # Reversed operand order commutes to the same tree.
      ("reversed Day(30)+F",    Day(30) + F("happened"),
        "(\"Tb\".\"happened\" + make_interval(days => \$1::integer))",              [30]),
    ]
    q = _E.objects
    q.values("shifted" => expr)
    res = q.list(show_query=:dict)
    @test contains(res[:sql_text], frag)      # exact typed make_interval fragment
    @test res[:parameters] == params          # magnitudes bound in textual order
  end

  @testset "Interval(...) helper — string and period forms" begin
    # Interval("HH:MM:SS") → time-only make_interval(hours, mins[, secs]).
    q1 = _E.objects; q1.values("s" => F("logged_at") + Interval("01:30:00"))
    r1 = q1.list(show_query=:dict)
    @test contains(r1[:sql_text], "make_interval(hours => \$1::integer, mins => \$2::integer)")
    @test r1[:parameters] == [1, 30]

    # Fractional seconds bind as double precision.
    q2 = _E.objects; q2.values("s" => F("logged_at") + Interval("00:00:01.5"))
    r2 = q2.list(show_query=:dict)
    @test contains(r2[:sql_text], "make_interval(secs => \$1::double precision)")
    @test r2[:parameters] == [1.5]

    # Interval(period) is interchangeable with the bare period.
    q3 = _E.objects; q3.values("s" => F("happened") + Interval(Month(2)))
    r3 = q3.list(show_query=:dict)
    @test contains(r3[:sql_text], "(\"Tb\".\"happened\" + make_interval(months => \$1::integer))")
    @test r3[:parameters] == [2]

    # Bare-seconds string ≥ 100 must PARSE, not throw: the duration normalizer emits "00:00:120"
    # (three seconds digits), which the parser must accept.
    q4 = _E.objects; q4.values("s" => F("logged_at") + Interval("120"))
    r4 = q4.list(show_query=:dict)
    @test contains(r4[:sql_text], "make_interval(secs => \$1::double precision)")
    @test r4[:parameters] == [120.0]
  end

  @testset "Chained (unparenthesised) periods nest into separate intervals" begin
    # `F + Month(1) + Day(15)` parses left-to-right as `(F + Month(1)) + Day(15)`, so it renders
    # as two chained make_interval() calls (correct result; parenthesise to `+ (Month(1)+Day(15))`
    # for a single interval). This locks that the nested form still renders and binds correctly.
    q = _E.objects
    q.values("shifted" => F("happened") + Month(1) + Day(15))
    res = q.list(show_query=:dict)
    @test contains(res[:sql_text],
      "((\"Tb\".\"happened\" + make_interval(months => \$1::integer)) + make_interval(days => \$2::integer))")
    @test res[:parameters] == [1, 15]
  end

  @testset "Update path — SET with make_interval" begin
    # Write path funnels through the same renderer. WHERE param is bound first ($1),
    # the interval magnitude second ($2), matching the bitwise-update convention above.
    q = _E.objects.filter("id" => 1)
    res = q.update("happened" => F("happened") + Day(7), show_query=:inspection)
    @test contains(res[:sql_text], "SET \"happened\" = (\"Tb\".\"happened\" + make_interval(days => \$2::integer))")
    @test contains(res[:sql_text], "WHERE \"Tb\".\"id\" = \$1")
    @test res[:parameters] == [1, 7]
  end

  @testset "Soft validation — duration on a non-date field throws" begin
    # A duration only makes sense on a DATE/TIMESTAMP column. _D.surname is CharField.
    err = try
      Logging.with_logger(Logging.NullLogger()) do
        _D.objects.values("bad" => F("surname") + Day(1)).list(show_query=:dict)
      end
      nothing
    catch e
      e
    end
    @test err isa PormGError
    @test occursin("requires a DATE/TIMESTAMP field", err.msg)
    @test occursin("surname", err.msg)
  end
end

# ═════════════════════════════════════════════════════════════════════════════
# #411 — `__@in` on every field type, not just the two whose formatter happened to take an array
#
# The call sites handed the WHOLE right-hand vector to `field.formatter`, so each formatter had to
# cope with an array individually. Only `format_text_sql` and `format_number_sql` did. `__@in` was
# therefore an error on DateField, DateTimeField, BooleanField, DurationField, UUIDField and
# BinaryField — and silently WRONG on JSONField, where `[1, 2]` became the single JSON string
# `"[1,2]"` and matched nothing.
#
# The fix maps the formatter per element, keyed on the OPERATOR rather than on the value's type.
# That distinction is the whole design: `format_binary_sql` and `format_json_sql` are the field types
# whose SCALAR value is itself a collection — a `Vector{UInt8}` is ONE binary value — so dispatching
# on `values isa AbstractArray` would map over a BinaryField's bytes and destroy it. Only "this is a
# membership lookup" licenses the map, which is exactly why Django puts its
# `FieldGetDbPrepValueIterableMixin` on the lookup class and keeps `get_prep_value` scalar-only.
#
# UUIDField and BinaryField needed a second fix: their element types were absent from the parse-time
# unions, so they failed with a MethodError BEFORE any formatter ran.
# ═════════════════════════════════════════════════════════════════════════════

if !isdefined(Main, :_In411Event)
  # A model of its own rather than widening `_OperTestEvent`, which is deliberately shaped to match
  # test_complex_queries.jl so the two files can be included together.
  _In411Event = Model("in411_events",
    id        = IDField(),
    n         = IntegerField(),
    code      = CharField(),
    happened  = DateField(),
    logged_at = DateTimeField(),
    ok        = BooleanField(),
    took      = DurationField(),
    uid       = UUIDField(),
    payload   = JSONField(),
    blob      = BinaryField(),
  )
  _In411Event.connect_key = "default"

  # A SQLite mock as well: the empty-list defect below is visible on ONE dialect only, because
  # SQLite expands a membership vector into one `?` per element while PostgreSQL binds the whole
  # vector as a single array parameter.
  struct _MockSQLiteIn411 <: PormG.PormGSQLite end
  PormG.config["in411_sl"] = PormG.Configuration.Settings(
    connections = _MockSQLiteIn411(), change_data = true)

  # #576: a RELATED pair, because the `#474` memo arm is only reachable across a join. A filter on
  # `"driverid__dob"` never consults `model.fields` (the path is not a key of it), so it resolves
  # through the memo — which is the arm the issue called unreachable. `_module` is set because the
  # field walk resolves the foreign model through it.
  _In411Result = Model("in411_results",
    resultid = IDField(),
    points   = IntegerField(),
    eventid  = ForeignKey(_In411Event, pk_field = "id", null = true,
                          related_name = "in411_results"),
  )
  # Only the ROOT model of a query needs `_module` — the field walk reads it off the model the
  # query is rooted at. `_In411Event` does not get one: it is shared by ~15 testsets in this file,
  # and mutating a shared fixture for a need the measurement does not support is how fixtures start
  # coupling testsets together.
  _In411Result.connect_key = "default"
  _In411Result._module = Main
end

# Error messages carry ANSI colour when `Base.have_color` is true and are stripped by `_emsg` when it
# is not. A local run is non-TTY so the codes are gone; CI runs with colour ON, so they are present.
# Any `occursin` whose needle SPANS a colorized token therefore passes locally and fails on CI —
# which is exactly how two assertions on this branch reached the PR green. Match plain text instead.
_plain(msg::AbstractString) = replace(msg, r"\e\[[0-9;]*m" => "")

const _IN411 = _In411Event
const _IN411R = _In411Result

# ─────────────────────────────────────────────────────────────────────────────
# `__@in` renders and binds correctly for every field type.
#
# One case per formerly-broken type, because the point of the fix is that the CLASS is closed — a
# test for `Date` alone would have passed with the one-method patch the issue proposed and left six
# field types broken.
# ─────────────────────────────────────────────────────────────────────────────
@testset "IN binds every field type, not only text and numbers (#411)" begin
  # Each entry: label, lookup, values, and the parameter vector expected inside the bound array.
  cases = [
    ("DateField",     "happened__@in",  [Date("2026-06-15"), Date("2026-06-16")], ["2026-06-15", "2026-06-16"]),
    ("BooleanField",  "ok__@in",        [true, false],                             [true, false]),
    ("DurationField", "took__@in",      [Dates.Hour(1), Dates.Hour(2)],            ["01:00:00", "02:00:00"]),
    ("UUIDField",     "uid__@in",       [Base.UUID("11111111-1111-1111-1111-111111111111")],
                                        ["11111111-1111-1111-1111-111111111111"]),
  ]
  for (label, lookup, values, expected) in cases
    q = _IN411.objects.filter(lookup => values)
    q.values("id")
    res = q.list(show_query = :dict)
    # PostgreSQL binds the list as ONE array parameter, so the payload is nested one deep.
    @test res[:parameters] == [expected]
    @test contains(res[:sql_text], "= ANY")
  end

  # DateTimeField renders through the timezone formatter, so assert the shape rather than an exact
  # string — the canonicalization itself is `test_datetime_canonicalization.jl`'s subject.
  q_dt = _IN411.objects.filter("logged_at__@in" => [DateTime("2026-06-15T10:00:00")])
  q_dt.values("id")
  res_dt = q_dt.list(show_query = :dict)
  @test length(res_dt[:parameters]) == 1 && length(res_dt[:parameters][1]) == 1
  @test startswith(res_dt[:parameters][1][1], "2026-06-15T10:00:00")

  # JSONField was not an error — it was SILENTLY WRONG, which is why this asserts the value and not
  # merely that the query built. The old contract produced the single string "[1,2]", so the query
  # compared a JSON column against one document instead of two scalars and matched nothing.
  q_js = _IN411.objects.filter("payload__@in" => [1, 2])
  q_js.values("id")
  res_js = q_js.list(show_query = :dict)
  @test res_js[:parameters] == [["1", "2"]]
  @test res_js[:parameters] != [["[1,2]"]]

  # BinaryField (#466). `format_binary_sql` returns a `PormGBytes` wrapper and the ARRAY methods of
  # `add_parameter!` used not to unwrap it, so #411 refused `blob__@in` by name rather than bind
  # wrappers: SQLite would have stored a Julia-serialized blob that matched NOTHING with no error,
  # and PostgreSQL would have emitted a nonsense `bytea[]` literal. Both collectors unwrap now, and
  # the assertions are on the BOUND ELEMENTS — a count (`length(params[1]) == 2`) once passed while
  # counting the wrappers, which is exactly the silent-wrong-rows path.
  q_bin = _IN411.objects.filter("blob__@in" => [UInt8[0x01, 0x02], UInt8[0x03]])
  q_bin.values("id")
  # PostgreSQL (the model's default connection here): ONE array parameter whose elements are the
  # scalar arm's hex text, so LibPQ renders `{"\\x0102","\\x03"}` and the server decodes each
  # element with `byteain` — no wrapper `show`.
  res_bin_pg = q_bin.list(show_query = :dict)
  @test occursin("= ANY(\$1)", res_bin_pg[:sql_text])
  @test res_bin_pg[:parameters] == Any[["\\x0102", "\\x03"]]
  @test all(v -> v isa String, res_bin_pg[:parameters][1])
  # SQLite: one `?` per member, each bound as raw bytes — the form sqlite3_bind_blob takes.
  res_bin_sl = PormG.QueryBuilder.inspect_query(q_bin; connection = _MockSQLiteIn411())
  @test count(==('?'), res_bin_sl[:sql_text]) == 2
  @test res_bin_sl[:parameters] == Any[UInt8[0x01, 0x02], UInt8[0x03]]
  @test all(v -> v isa Vector{UInt8}, res_bin_sl[:parameters])
  # `@nin` takes the same path with each dialect's negated renderer.
  q_nbin = _IN411.objects.filter("blob__@nin" => [UInt8[0x01, 0x02]])
  q_nbin.values("id")
  res_nbin_pg = q_nbin.list(show_query = :dict)
  @test occursin("<> ALL(\$1)", res_nbin_pg[:sql_text])
  @test res_nbin_pg[:parameters] == Any[["\\x0102"]]
  res_nbin_sl = PormG.QueryBuilder.inspect_query(q_nbin; connection = _MockSQLiteIn411())
  @test occursin("NOT IN", res_nbin_sl[:sql_text])
  @test res_nbin_sl[:parameters] == Any[UInt8[0x01, 0x02]]

  # Anything other than `@in`/`@nin` over a binary LIST is the ordinary "vector value, wrong
  # operator" mistake and goes to the shared funnel, naming what the user wrote — the same two
  # controls that held while the #411 guard existed. A list of payloads
  # (`Vector{Vector{UInt8}}`) is what these two pin; a flat `Vector{UInt8}` is one payload and has
  # been a valid scalar comparison since #596, which is a different type and a different method.
  no_op = @test_throws PormG.FilterError _IN411.objects.filter(
    "blob" => [UInt8[0x01], UInt8[0x02]]).list(show_query = :dict)
  @test occursin("no operator", no_op.value.msg)
  @test !occursin("membership filter", no_op.value.msg)

  wrong_op = @test_throws PormG.FilterError _IN411.objects.filter(
    "blob__@gte" => [UInt8[0x01], UInt8[0x02]]).list(show_query = :dict)
  @test occursin("not valid", wrong_op.value.msg)
  @test !occursin("membership filter", wrong_op.value.msg)

  # A scalar UUID filter renders. Only the VECTOR union was widened at first, so plain equality on a
  # UUIDField still raised a `convert` MethodError — an untyped error on the most ordinary spelling.
  q_uid = _IN411.objects.filter("uid" => Base.UUID("11111111-1111-1111-1111-111111111111"))
  q_uid.values("id")
  @test contains(q_uid.list(show_query = :dict)[:sql_text], "=")
end

# ─────────────────────────────────────────────────────────────────────────────
# Non-membership operators are untouched — the control for the operator-keyed design.
#
# If the map were keyed on `values isa AbstractArray` instead, `BETWEEN` and a scalar comparison
# against a collection-valued field would both change. They must not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a non-membership operator never maps its value (#411)" begin
  # BETWEEN indexes its two operands separately and formats each as a scalar. #467 moved that
  # formatting inside the re-raise guard, so this is also the control proving the move changed the
  # ERROR type only: a well-typed pair still binds two scalars, unwrapped and in order.
  q_r = _IN411.objects.filter("n__@range" => [1, 9])
  q_r.values("id")
  @test q_r.list(show_query = :dict)[:parameters] == [1, 9]

  # The negated arm binds identically — it differs only in the operator string it emits.
  q_nr = _IN411.objects.filter("happened__@nrange" => [Date("2026-06-15"), Date("2026-06-16")])
  q_nr.values("id")
  res_nr = q_nr.list(show_query = :dict)
  @test res_nr[:parameters] == ["2026-06-15", "2026-06-16"]
  @test contains(res_nr[:sql_text], "NOT BETWEEN")

  # A scalar Date comparison still formats as one value, not a one-element list.
  q_s = _IN411.objects.filter("happened__@lte" => Date("2026-06-15"))
  q_s.values("id")
  @test q_s.list(show_query = :dict)[:parameters] == ["2026-06-15"]
end

# ─────────────────────────────────────────────────────────────────────────────
# A wrong-typed filter value reports the filter path's own error type (#411).
#
# The re-wrap here used to string-match `"The date"` && `"is invalid"`, which matched exactly one
# formatter message — `format_date_sql(::AbstractString)` — and nothing else. Every other field type
# leaked `InvalidValueError`, whose docstring scopes it to the insert/update coercion helpers.
#
# This is a deliberate behavior change and is pinned as one: both remain `PormGError`, so an app
# catching the root is unaffected, but one catching `InvalidValueError` specifically will notice.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a wrong-typed filter value raises FilterError, not InvalidValueError (#411)" begin
  # Scalar, non-Date field — the case that leaked before. Asserting the CAUSE as well as the type:
  # `FilterError` is the filter path's long-tail bucket, so a bare `@test_throws` would also pass on
  # an operator-validity error or the binary refusal, neither of which is what this pins.
  scalar_err = @test_throws PormG.FilterError _IN411.objects.filter("n" => "abc").list(show_query = :dict)
  @test occursin("field is the type", scalar_err.value.msg)
  # And inside a membership list, where the map applies the formatter per element.
  list_err = @test_throws PormG.FilterError _IN411.objects.filter("n__@in" => ["abc"]).list(show_query = :dict)
  @test occursin("field is the type", list_err.value.msg)
  # A Date field was already converted by the old substring match; it must stay converted.
  @test_throws PormG.FilterError _IN411.objects.filter("happened" => "not-a-date").list(show_query = :dict)

  # #467: `@range`/`@nrange` were the one arm left out — `BETWEEN` formats its two operands in a
  # branch of its own, which sat outside the guard, so the SAME mistake reported a different type
  # depending on which operator was used. Both branches now go through `_rethrow_as_filter_error`.
  # Asserting the cause as well as the type, for the reason stated above.
  range_err = @test_throws PormG.FilterError _IN411.objects.filter(
    "happened__@range" => ["x", "y"]).list(show_query = :dict)
  @test occursin("field is the type", range_err.value.msg)

  # `@nrange` was untested either way before #467. It shares the branch but not the operator
  # string, and a fix written against `BETWEEN` alone would be easy to scope to one of them.
  nrange_err = @test_throws PormG.FilterError _IN411.objects.filter(
    "happened__@nrange" => ["x", "y"]).list(show_query = :dict)
  @test occursin("field is the type", nrange_err.value.msg)

  # Non-Date too: the leak was never about dates, and `n` is the field the scalar case above uses,
  # so a BETWEEN-specific regression cannot hide behind the Date formatter's own arms.
  @test_throws PormG.FilterError _IN411.objects.filter(
    "n__@range" => ["abc", "def"]).list(show_query = :dict)
end

# ─────────────────────────────────────────────────────────────────────────────
# An EMPTY membership list is valid SQL on both backends.
#
# SQLite bound zero parameters and rendered `IN ()` — a syntax error — while PostgreSQL rendered a
# valid `= ANY('{}')` that never matches. One query, a hard failure on one engine only, which is the
# divergence shape the ruleset calls a non-negotiable.
#
# The truth values are the point: nothing is a member of the empty set, and everything is not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an empty IN list is valid on both dialects (#411)" begin
  sl = Model("in411_sl_events", id = IDField(), n = IntegerField())
  sl.connect_key = "in411_sl"

  q_in = sl.objects.filter("n__@in" => Int[])
  q_in.values("id")
  res_in = q_in.list(show_query = :dict)
  # No `IN ()` anywhere, and an always-false predicate instead.
  @test !contains(res_in[:sql_text], "IN ()")
  @test contains(res_in[:sql_text], "(1 = 0)")
  @test isempty(res_in[:parameters])

  # NOT IN over the empty set is always TRUE — everything is outside it. Asserting the opposite
  # constant is what stops a fix that renders a constant without thinking about the negation.
  q_nin = sl.objects.filter("n__@nin" => Int[])
  q_nin.values("id")
  res_nin = q_nin.list(show_query = :dict)
  @test !contains(res_nin[:sql_text], "NOT IN ()")
  @test contains(res_nin[:sql_text], "(1 = 1)")

  # `[]` is `Vector{Any}`, which satisfies none of the element bounds the parse methods dispatch on —
  # so the way anyone actually writes an empty list used to raise a `MethodError`, and it was the
  # spelling the documentation showed. Both spellings must work, and `Int[]` must keep working.
  for empty_value in (Int[], [], Any[])
    q_e = _IN411.objects.filter("n__@in" => empty_value)
    q_e.values("id")
    @test contains(q_e.list(show_query = :dict)[:sql_text], "= ANY")
  end

  # A genuinely mixed list is reported, not looped over or leaked as a MethodError — the narrowing
  # path re-dispatches, so it needs a terminating case.
  mixed = @test_throws PormG.FilterError _IN411.objects.filter(
    "n__@in" => Any[1, "a"]).list(show_query = :dict)
  @test occursin("do not share", mixed.value.msg)

  # PostgreSQL was already correct and must stay on its own spelling — the two dialects agree on
  # BEHAVIOR, not on text, exactly as they already do for a non-empty list (`IN (?)` vs `= ANY($1)`).
  q_pg = _IN411.objects.filter("n__@in" => Int[])
  q_pg.values("id")
  @test contains(q_pg.list(show_query = :dict)[:sql_text], "= ANY")
end

# ─────────────────────────────────────────────────────────────────────────────
# The HAVING path had the identical inverted contract, at a fourth call site.
#
# Filtering on an aggregate ALIAS promotes the predicate into HAVING and resolves its value through
# `_resolve_having_filter_value`, which also handed the whole vector to a formatter. So
# `filter("mx__@in" => [Date(...)])` over a `Max("happened")` alias failed with the same
# `InvalidValueError` the plain-field path did. Found by probing rather than by reading — the fluent
# surface has no `.having()`, so the shape is not obvious from the API.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an aggregate-alias IN filter formats per element too (#411)" begin
  q = _IN411.objects
  q.values("code", "mx" => PormG.Functions.Max("happened"))
  q.filter("mx__@in" => [Date("2026-01-01"), Date("2026-02-01")])
  res = q.list(show_query = :dict)
  @test res[:parameters] == [["2026-01-01", "2026-02-01"]]

  # And the rendered HAVING is VALID SQL. Asserting only the parameters reported this path as fixed
  # while it emitted `HAVING MAX(x) IN $1` — no parentheses, no `= ANY` — a syntax error on both
  # engines. The value formatting and the rendering are two different bugs on one path, and a test
  # that checks one of them says nothing about the other.
  # Anchored to the HAVING clause itself: `contains(sql, "= ANY")` alone would pass if the membership
  # render leaked into WHERE and HAVING stayed broken.
  @test occursin(r"HAVING\s+MAX\(.*?\)\s+= ANY", res[:sql_text])
  @test !occursin(r"IN \$\d", res[:sql_text])

  # SQLite too. The original defect was invisible because nothing asserted the rendered HAVING at
  # all, and SQLite is where a membership render goes wrong differently — it expands to one `?` per
  # element, so its failure was `IN ?, ?` rather than `IN $1`. Asserting one dialect would leave the
  # same blind spot that hid this in the first place.
  sl_h = Model("in411_sl_having", id = IDField(), n = IntegerField(), code = CharField())
  sl_h.connect_key = "in411_sl"
  q_sl = sl_h.objects
  q_sl.values("code", "tot" => PormG.Functions.Sum("n"))
  q_sl.filter("tot__@in" => [1, 2])
  sql_sl = q_sl.list(show_query = :dict)[:sql_text]
  @test occursin(r"HAVING\s+SUM\(.*?\)\s+IN \(\?, \?\)", sql_sl)
  @test !occursin("IN ?, ?", sql_sl)

  # A scalar aggregate comparison is unchanged.
  q2 = _IN411.objects
  q2.values("code", "tot" => PormG.Functions.Sum("n"))
  q2.filter("tot__@gt" => 5)
  @test q2.list(show_query = :dict)[:parameters] == [5]
end

# ─────────────────────────────────────────────────────────────────────────────
# Error-type parity, the rest of it: every read path reports FilterError (#576)
#
# #411 converted the scalar/membership branches and #467 the `BETWEEN` arm. Twelve of the thirteen
# formatter call sites on the read path were still outside the guard, so the SAME user mistake
# reported `InvalidValueError` — the write path's type — depending only on which spelling was used.
#
# One case per converted arm, because the point is that the CLASS is closed. Each asserts the CAUSE
# as well as the type: `FilterError` is the filter path's long-tail bucket, so a bare `@test_throws`
# would pass on an operator-validity error too, which is not what this pins.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every read path reports FilterError, not InvalidValueError (#576)" begin
  # ── The HAVING / aggregate-alias ladder (`_resolve_having_filter_value`) ──
  # This is the documented alias spelling, and all seven of its arms formatted unguarded. The
  # message is alias-shaped: there is no field here, only a name the caller invented in `values()`.
  sum_q = _IN411.objects
  sum_q.values("code", "tot" => PormG.Functions.Sum("n"))
  sum_err = @test_throws PormG.FilterError sum_q.filter(
    "tot__@gt" => "abc").list(show_query = :dict)
  @test occursin("projection alias is the type", sum_err.value.msg)
  @test occursin("tot", sum_err.value.msg)

  # `MAX`/`MIN` resolve the formatter from the aggregated COLUMN, a different arm from `SUM`'s.
  max_q = _IN411.objects
  max_q.values("code", "mx" => PormG.Functions.Max("happened"))
  max_err = @test_throws PormG.FilterError max_q.filter(
    "mx__@gt" => "not-a-date").list(show_query = :dict)
  @test occursin("projection alias is the type", max_err.value.msg)

  # ── The transform ladder (`SQLTypeFunction` branches in `_get_filter_query`) ──
  # `@month`/`@day` extract a number, so a non-numeric value is the mistake. These reached
  # `format_number_sql` with no `try` around it at all.
  month_err = @test_throws PormG.FilterError _IN411.objects.filter(
    "happened__@month" => "abc").list(show_query = :dict)
  @test occursin("transform is the type", month_err.value.msg)
  @test_throws PormG.FilterError _IN411.objects.filter(
    "happened__@day" => "abc").list(show_query = :dict)

  # `@quarter` validates a RANGE rather than a type, through `format_quarter_sql`. Same leak, and
  # it is the one the docs named by error type, so both doc pages moved with this commit.
  quarter_err = @test_throws PormG.FilterError _IN411.objects.filter(
    "happened__@quarter" => 9).list(show_query = :dict)
  @test occursin("transform is the type", quarter_err.value.msg)

  # ── The sargable rewrite (`_render_sargable_date_range`) ──
  # Not named by the issue, and the one that actually fires for these spellings: on a plain
  # `DateField` the rewrite short-circuits AHEAD of the ladder above, so guarding the ladder alone
  # would have left `@date` and `@yyyy_mm` leaking while the tests for `@month` went green.
  date_err = @test_throws PormG.FilterError _IN411.objects.filter(
    "happened__@date" => "not-a-date").list(show_query = :dict)
  @test occursin("field is the type", date_err.value.msg)
  # `@yyyy_mm` leaks one call deeper — `_yyyy_mm_bucket_bounds` opens with `Models.format_yyyy_mm`,
  # whose `InvalidValueError` escaped before the bounds guard. Its sibling `_year_bucket_bounds`
  # already raised `FilterError` throughout, which is why `@year` was never on the leak list.
  @test_throws PormG.FilterError _IN411.objects.filter(
    "happened__@yyyy_mm" => "nonsense").list(show_query = :dict)

  # ── The #474 memo arm: an ordinary JOINED-PATH filter ──
  # The issue listed this arm as "suspected, no reproducing input found", and the first cut of the
  # fix repeated that after probing only alias reuse — which the field walk rejects earlier. The
  # reachable shape is any FK traversal: `"eventid__happened"` is not a key of `model.fields`, so
  # every joined filter resolves through the memo. That makes this plausibly the MOST common
  # wrong-typed filter in a consuming app, and it was leaking `InvalidValueError` like the rest.
  fk_err = @test_throws PormG.FilterError _IN411R.objects.filter(
    "eventid__happened" => "not-a-date").list(show_query = :dict)
  @test occursin("field is the type", fk_err.value.msg)
  @test occursin("eventid__happened", fk_err.value.msg)
  @test_throws PormG.FilterError _IN411R.objects.filter(
    "eventid__n" => "abc").list(show_query = :dict)
  # Through a pattern operator too, which reaches the same arm by a different branch of the caller.
  @test_throws PormG.FilterError _IN411R.objects.filter(
    "eventid__n__@contains" => "x").list(show_query = :dict)

  # ── Controls: the conversion must not swallow a well-typed value ──
  # Every spelling above, with a value its formatter accepts, still builds. Asserting the BOUND
  # PARAMETER, not merely that it did not throw: a guard that swallowed an error and bound
  # something else would pass an `isa Dict` check, which is what these assertions used to be.
  ok_sum = _IN411.objects
  ok_sum.values("code", "tot" => PormG.Functions.Sum("n"))
  ok_sum.filter("tot__@gt" => 10)
  @test ok_sum.list(show_query = :dict)[:parameters] == [10]
  @test _IN411.objects.filter("happened__@month" => 3).list(show_query = :dict)[:parameters] == [3]
  @test _IN411.objects.filter(
    "happened__@date" => Date("1991-10-01")).list(show_query = :dict)[:parameters] == ["1991-10-01"]
  # The sargable rewrite turns a bucket into a half-open range, so this binds two bounds.
  @test _IN411.objects.filter(
    "happened__@yyyy_mm" => "1991-10").list(show_query = :dict)[:parameters] == ["1991-10-01", "1991-11-01"]
  @test _IN411R.objects.filter("eventid__n" => 5).list(show_query = :dict)[:parameters] == [5]

  # ── The guard converts InvalidValueError and NOTHING else ──
  # `format_bool_sql` has no generic arm, so a wrong-typed value on a BooleanField raises a bare
  # `MethodError`. `_rethrow_as_filter_error`'s non-`InvalidValueError` arm is `rethrow(e)`, and
  # this pins that it stays that way: a guard that converted everything would hide real bugs.
  @test_throws MethodError _IN411.objects.filter(
    "ok" => Date("1991-10-01")).list(show_query = :dict)
end

# ─────────────────────────────────────────────────────────────────────────────
# A non-aggregate projection alias resolves its own formatter, not IntegerField's (#576)
#
# The HAVING ladder only ever inspected `SQLTypeFunction`, and a bare `F("col")` is an
# `FExpression`. Everything it did not recognise fell to `IntegerField().formatter`, so filtering a
# projected date alias forced `format_number_sql` onto it.
#
# This half is NOT an error-type problem and no consuming app could have had a working handler
# around it: it rejected WELL-TYPED values too. A real `Date` raised "is not a valid number". That
# is why the well-typed case below is the primary assertion and the error type is secondary —
# reversing the two would let a fix that only relabels the error pass.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a plain F() projection alias filters on its own type (#576)" begin
  # The case that was broken for correct input. Asserting the bound parameter, not merely that it
  # did not throw: the alias must format through the DATE formatter, so the value binds as the
  # column's own representation rather than as a number.
  q = _IN411.objects
  q.values("id", "d2" => F("happened"))
  q.filter("d2" => Date("2026-06-15"))
  @test q.list(show_query = :dict)[:parameters] == ["2026-06-15"]

  # And a genuinely wrong value on the same alias now reports the filter path's type.
  bad = _IN411.objects
  bad.values("id", "d2" => F("happened"))
  bad_err = @test_throws PormG.FilterError bad.filter(
    "d2" => "not-a-date").list(show_query = :dict)
  @test occursin("projection alias is the type", bad_err.value.msg)

  # The BOUND VALUE changes for every non-numeric column, not just for the ones that used to raise
  # — the old fallback coerced through `format_number_sql` whatever the alias projected. These two
  # never threw before and never throw now, so only the parameter shows the difference, and on
  # SQLite it is the difference between matching and not: a TEXT column compared against `5` finds
  # nothing while `'5'` finds the row. That makes it a silent result change, which is why it is
  # pinned here and named in UPGRADING rather than filed under "it used to raise".
  txt = _IN411.objects
  txt.values("id", "c2" => F("code"))
  txt.filter("c2" => 5)
  @test txt.list(show_query = :dict)[:parameters] == ["5"]        # was: 5

  flag = _IN411.objects
  flag.values("id", "b2" => F("ok"))
  flag.filter("b2" => 1)
  @test flag.list(show_query = :dict)[:parameters] == [true]      # was: 1

  # A numeric column is the case where old and new agree, which is what makes the two above a
  # targeted change rather than a blanket re-coercion.
  num = _IN411.objects
  num.values("id", "n2" => F("n"))
  num.filter("n2" => 7)
  @test num.list(show_query = :dict)[:parameters] == [7]

  # The same value through the ordinary non-alias spelling, to show which way the alias moved: it
  # now agrees with the plain filter instead of disagreeing with it.
  @test _IN411.objects.filter("code" => 5).list(show_query = :dict)[:parameters] == ["5"]

  # Deliberately NOT widened: an alias over arithmetic (`F("n") + 1`) keeps the `IntegerField`
  # fallback, because its result type is not the column's. Pinned so the narrowness is a decision
  # on the record rather than an accident of the `operation === nothing` test — if a later change
  # resolves this too, this assertion is where it announces itself. (#576 held a joined path to the
  # same fallback; #652 widened that half — a joined path names one column — see the testset below.)
  arith = _IN411.objects
  arith.values("id", "d3" => F("n") + 1)
  arith.filter("d3" => 5)
  # THREE parameters, in clause order: the `1` the arithmetic binds in SELECT, the `1` it binds
  # again in HAVING, then the filter's own `5`. Asserting the whole vector rather than just the
  # filter value keeps the bucket order visible — this alias reaches the fallback formatter, and a
  # change that started resolving `F("n") + 1` to the column's formatter would still bind `5` and
  # pass a narrower test.
  #
  # #595 changed this expectation, deliberately: it used to read `[1, 5]`, which was the defect
  # written down as design. The HAVING clause reprinted the projection's memoized text — `("n" + ?)`
  # — with nothing bound for its `?`, so SQLite got three markers for two values and could not bind
  # the statement. Adjudicated against the cross-backend differential rather than against either
  # side: PostgreSQL numbers `$n` at render, and its authoritative text-order walk reads `[1, 1, 5]`
  # both before and after the fix. SQLite now matches it; before, it did not.
  @test arith.list(show_query = :dict)[:parameters] == [1, 1, 5]
end

# ─────────────────────────────────────────────────────────────────────────────
# A joined-path Max/Min or bare-F projection alias filters on the joined column's type (#652)
#
# #576 typed an alias only when its column was a key of the queried model's `fields`, so
# `Max("eventid__code")` fell to the `IntegerField` fallback and refused a TEXT term as "the type
# number" — the shape #618's documented alias pattern lookups invite first ("the alphabetically last
# driver per constructor"). The terminal field is already in the memo the join walk writes while the
# SELECT renders, so the alias takes that field's formatter. Both mocks, because the pattern lookup
# renders per dialect (`ILIKE` on PostgreSQL, `LIKE` on SQLite) and must bind the same decorated term.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a joined-path Max/Min or F projection alias takes the joined column's type (#652)" begin
  for (backend, conn) in (("PostgreSQL", nothing), ("SQLite", _MockSQLiteIn411()))
    @testset "$backend" begin
      _inspect(q) = conn === nothing ? q.list(show_query = :dict) :
                                       PormG.QueryBuilder.inspect_query(q; connection = conn)

      # The issue's own shape: a text lookup on a joined `Max`. The primary assertion is the BOUND
      # value — `"V%"` proves the text formatter ran and the `%` decoration applied; the old
      # fallback raised before binding anything.
      for agg in (PormG.Functions.Max, PormG.Functions.Min)
        q = _IN411R.objects
        q.values("points", "mx" => agg("eventid__code"))
        q.filter("mx__@istartswith" => "V")
        res = _inspect(q)
        @test res[:parameters] == ["V%"]
        # The HAVING predicate aggregates the JOINED column, not a base-model one.
        @test occursin(r"HAVING .*(MAX|MIN)\(\"Tb_1\"\.\"code\"\)", res[:sql_text])
      end

      # A joined DATE column formats as a date — the value binds as the column's own text form, which
      # is the half no error-type fix could have produced: `format_number_sql` rejected a real `Date`.
      qd = _IN411R.objects
      qd.values("points", "last" => PormG.Functions.Max("eventid__happened"))
      qd.filter("last__@gt" => Date("2020-01-01"))
      @test _inspect(qd)[:parameters] == ["2020-01-01"]

      # A wrong-typed term on the same alias still refuses — and names the column's REAL type. Before
      # the fix the message said "number" for a date column the caller never declared as one.
      qbad = _IN411R.objects
      qbad.values("points", "last" => PormG.Functions.Max("eventid__happened"))
      qbad.filter("last__@gt" => "not-a-date")
      bad = @test_throws PormG.FilterError _inspect(qbad)
      @test occursin("projection alias is the type date", _plain(bad.value.msg))

      # #576's other declared-narrow case, same root: a bare `F` over a joined path. The oracle is
      # the ordinary WHERE filter on the same joined column — the alias must bind what the column
      # would. PostgreSQL only: on SQLite the alias path keeps a native number
      # (`_sqlite_preserve_native_parameter`) where the WHERE path binds the formatted text. That split
      # predates #652 and holds for a base-model alias too, so it is not this change's to settle.
      if conn === nothing
        qf = _IN411R.objects
        qf.values("points", "c" => F("eventid__code"))
        qf.filter("c" => 5)
        where_bound = _inspect(_IN411R.objects.filter("eventid__code" => 5))[:parameters]
        @test where_bound == ["5"]
        @test _inspect(qf)[:parameters] == where_bound
      end
      # And a text term — the fallback refused this outright as "the type number".
      qs = _IN411R.objects
      qs.values("points", "c" => F("eventid__code"))
      qs.filter("c" => "V")
      @test _inspect(qs)[:parameters] == ["V"]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A joined-path @range formats both operands through the joined column (#654)
# The WHERE `BETWEEN` arm formatted only a key of `model.fields`; a joined path bound its operands
# RAW, so `["x", "y"]` on a date column went to the database as two strings instead of refusing, and a
# real `Date` bound as a `Date` where its `@gt` twin binds the text form. Found while moving that arm
# into `_render_predicate`; it reads the terminal field from the memo, as the joined equality arm does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a joined-path @range formats its operands through the joined column (#654)" begin
  for (backend, conn) in (("PostgreSQL", nothing), ("SQLite", _MockSQLiteIn411()))
    @testset "$backend" begin
      _inspect(q) = conn === nothing ? q.list(show_query = :dict) :
                                       PormG.QueryBuilder.inspect_query(q; connection = conn)
      ok = _inspect(_IN411R.objects.filter(
        "eventid__happened__@range" => [Date("2020-01-01"), Date("2021-01-01")]))
      # The oracle is the same column's `@gt`: a range operand must bind what a scalar one does.
      twin = _inspect(_IN411R.objects.filter("eventid__happened__@gt" => Date("2020-01-01")))
      @test ok[:parameters] == ["2020-01-01", "2021-01-01"]
      @test ok[:parameters][1] == twin[:parameters][1]
      @test occursin(r"\"Tb_1\"\.\"happened\" BETWEEN", ok[:sql_text])

      # A wrong-typed pair now refuses at build time, naming the path the caller wrote.
      bad = @test_throws PormG.FilterError _inspect(_IN411R.objects.filter(
        "eventid__happened__@nrange" => ["x", "y"]))
      @test occursin("eventid__happened", _plain(bad.value.msg))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A scalar equality filter on a BinaryField has a spelling (#596)
#
# `filter("blob" => bytes)` was refused at parse time: `UInt8 <: Number`, so a byte payload reached
# the vector arm of `_get_pair_to_oper`, and every branch there slices off a trailing operator
# segment that a bare field path does not have. It fell through to "a vector value but no
# operator" — the very spelling #411's refusal message had prescribed as the workaround for
# `blob__@in`. It never worked.
#
# The fix admits it at parse (the types are unambiguous: `Vector{UInt8}` is one payload,
# `Vector{Vector{UInt8}}` is a membership list) and decides binary-ness at RENDER, where the field is
# known. That split is what makes it work through `Q`/`Qor` as well — those reach `_check_filter`
# with no model in scope, so a parse-time field lookup could never have covered them, and the `Q`
# case below is asserted for exactly that reason.
#
# `_IN411` renders through the PostgreSQL mock (`connect_key = "default"`); the SQLite side is taken
# by passing `_MockSQLiteIn411()` to `inspect_query`, the same pattern the #411/#466 block above uses.
# Both engines matter here because they bind a blob differently: SQLite binds the bytes, PostgreSQL
# the `\x`-prefixed hex text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a scalar equality filter on a BinaryField binds one blob (#596)" begin
  payload = UInt8[0x89, 0x50, 0x00, 0xFF]     # carries a 0x00 a text parameter could not carry

  # One marker either way — the payload is ONE value, which is the whole distinction from an
  # `@in` list, and the thing the old parse refused to express.
  q_sl = _IN411.objects
  q_sl.filter("blob" => payload)
  res_sl = PormG.QueryBuilder.inspect_query(q_sl; connection = _MockSQLiteIn411())
  @test res_sl[:parameters] == Any[payload]
  @test count("?", res_sl[:sql_text]) == 1
  @test occursin("\"blob\" = ?", res_sl[:sql_text])

  res_pg = _IN411.objects.filter("blob" => payload).list(show_query = :dict)
  @test res_pg[:parameters] == Any["\\x" * bytes2hex(payload)]
  @test occursin("\"blob\" = \$1", res_pg[:sql_text])

  # Through `Q(...)`, which reaches `_check_filter` with no model in scope. A parse-time,
  # model-aware fix would have left this one refused; deciding at render covers it for free.
  q_wrapped = _IN411.objects
  q_wrapped.filter(Q("blob" => payload))
  @test PormG.QueryBuilder.inspect_query(q_wrapped;
          connection = _MockSQLiteIn411())[:parameters] == Any[payload]

  # An empty payload is still ONE value, not zero — the empty-list shape `_render_membership`
  # special-cases does not apply, because this is not a membership filter.
  q_empty = _IN411.objects
  q_empty.filter("blob" => UInt8[])
  res_empty = PormG.QueryBuilder.inspect_query(q_empty; connection = _MockSQLiteIn411())
  @test res_empty[:parameters] == Any[UInt8[]]
  @test count("?", res_empty[:sql_text]) == 1

  # ── The refusals that must survive ────────────────────────────────────────────
  # A byte payload against a NON-binary field is still the "vector value, no operator" mistake and
  # must report it with the SAME message. That is the acceptance criterion, and it is why the render
  # guard calls the shared funnel rather than inventing a second wording.
  non_bin = @test_throws PormG.FilterError _IN411.objects.filter(
    "n" => UInt8[0x01, 0x02]).list(show_query = :dict)
  @test occursin("was given a vector value but no operator", non_bin.value.msg)
  @test occursin("n__@in", non_bin.value.msg)      # the example names the real field

  # The guard keys on the field STRUCT, not on `type == "BLOB"` — `ImageField`/`FileField` carry that
  # same type string and hold no bytes (#296). A text field is refused like any other non-binary.
  txt = @test_throws PormG.FilterError _IN411.objects.filter(
    "code" => UInt8[0x01]).list(show_query = :dict)
  @test occursin("was given a vector value but no operator", txt.value.msg)

  # ── Every resolver arm, not just the base-model one ───────────────────────────
  # A JOINED path resolves its field through the memo (#474), not `model.fields`, so it is a separate
  # arm and needs the same guard. Guarding only the base-model arm let
  # `filter("eventid__n" => UInt8[1, 2])` bind TWO parameters and compare the column against the
  # first byte — silently, because a payload reaching `add_parameter!` as a bare `AbstractArray`
  # expands to one marker per byte. Both directions are pinned so the omission cannot come back.
  joined_bin = _IN411R.objects
  joined_bin.filter("eventid__blob" => payload)
  res_joined = PormG.QueryBuilder.inspect_query(joined_bin; connection = _MockSQLiteIn411())
  @test res_joined[:parameters] == Any[payload]
  @test count("?", res_joined[:sql_text]) == 1

  joined_non_bin = @test_throws PormG.FilterError _IN411R.objects.filter(
    "eventid__n" => UInt8[0x01, 0x02]).list(show_query = :dict)
  @test occursin("was given a vector value but no operator", joined_non_bin.value.msg)
  @test occursin("eventid__n__@in", joined_non_bin.value.msg)   # the path the user wrote

  # A LIST of payloads with no operator keeps meaning what it always did. It is a different type and
  # takes a different method, so admitting the scalar cannot have widened it.
  lst = @test_throws PormG.FilterError _IN411.objects.filter(
    "blob" => [UInt8[0x01], UInt8[0x02]]).list(show_query = :dict)
  @test occursin("no operator", lst.value.msg)

  # And a suffix still wins over the bare-path reading. `blob__@in => UInt8[1, 2]` is read as a
  # membership list whose members are the NUMBERS 1 and 2, so `format_binary_sql` is mapped over
  # each and refuses a bare `UInt8` — verified byte-for-byte identical on the unpatched code. The
  # new method delegates whenever the last segment is a `PormGsuffix` key precisely so this reading
  # is untouched; a binary membership filter is spelled `blob__@in => [bytes_a, bytes_b]` (#466).
  suffixed = @test_throws PormG.FilterError _IN411.objects.filter(
    "blob__@in" => UInt8[0x01, 0x02]).list(show_query = :dict)
  # `_plain` because this phrase spans a COLORIZED token — the message is
  # "is the type \e[4m\e[32mBLOB\e[0m". `_emsg` keeps the escapes when `Base.have_color` is true and
  # strips them otherwise, so a local run (non-TTY, color off) matches and CI (color on) does not.
  # This assertion shipped green locally and failed on all five CI jobs; match the plain text.
  @test occursin("is the type BLOB", _plain(suffixed.value.msg))
end

# ─────────────────────────────────────────────────────────────────────────────
# Admitting a flat `Vector{UInt8}` must not widen anything else (#596)
#
# The first cut of the parse method above reimplemented the two-branch SCALAR shape, so its suffix
# branch built an `OperObject` directly instead of going through the vector arm's ladder. That
# silently dropped all four of that ladder's guards at once. Every case below was a clean
# `FilterError` before #596, so each is a regression this pins shut — and the `@range` truncation is
# the one that was SILENT, which is exactly the class the commit set out to remove.
#
# It now delegates: `_vector_oper_from_suffix` is ONE body with two callers, so a guard cannot be
# present for `Vector{Int}` and missing for `Vector{UInt8}`. The `Int` control rides along in each
# loop for that reason — the two must report identically.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a byte payload does not bypass the vector ladder's guards (#596)" begin
  # A suffix that is not a membership/range/JSON operator: refused, naming the OPERATOR the user
  # typed. Before: `@gt` built `WHERE "n" > ?, ?` (SQLite syntax error, PG bound the whole vector);
  # `@icontains` reached `format_text_sql(::UInt8)` as an untyped MethodError outside the #231
  # taxonomy; `@isnull` reached `ISNULL(::String, ::Vector{UInt8})`, likewise untyped.
  for op in ("gt", "gte", "lt", "icontains", "istartswith", "isnull", "ne")
    bytes_err = @test_throws PormG.FilterError _IN411.objects.filter(
      "n__@$(op)" => UInt8[0x01, 0x02]).list(show_query = :dict)
    int_err = @test_throws PormG.FilterError _IN411.objects.filter(
      "n__@$(op)" => Int[1, 2]).list(show_query = :dict)
    @test occursin("@$(op)", bytes_err.value.msg)
    # The payload and the plain integer list must report IDENTICALLY — that equality is the
    # regression test for the delegation, not the individual message.
    @test bytes_err.value.msg == int_err.value.msg
  end

  # `@range` / `@nrange` arity. A 3-element payload used to render a TRUNCATED `BETWEEN` over the
  # first two bytes with no error at all — valid SQL, wrong query, on both engines. A 1-element one
  # threw `BoundsError`, which is not even a `PormGError` (#239).
  for op in ("range", "nrange")
    for bad in (UInt8[0x01], UInt8[0x01, 0x02, 0x03], UInt8[])
      err = @test_throws PormG.FilterError _IN411.objects.filter(
        "n__@$(op)" => bad).list(show_query = :dict)
      @test occursin("requires exactly 2 values", err.value.msg)
      @test occursin("got $(length(bad))", err.value.msg)
    end
    # Two values is the legal arity and still renders.
    ok = _IN411.objects
    ok.filter("n__@$(op)" => UInt8[0x01, 0x02])
    @test count("?", PormG.QueryBuilder.inspect_query(ok;
                       connection = _MockSQLiteIn411())[:sql_text]) == 2
  end

  # `@in` / `@nin` keep working through the shared ladder — the branch that WAS correct.
  in_ok = _IN411.objects
  in_ok.filter("blob__@in" => [UInt8[0x01], UInt8[0x02]])
  @test length(PormG.QueryBuilder.inspect_query(in_ok;
                 connection = _MockSQLiteIn411())[:parameters]) == 2

  # ── Bare-path arms other than the base-model one ──────────────────────────────
  # A TRANSFORM column is a bare path, so a payload reaches the transform render arms. No transform
  # yields bytes, so every one is a refusal. Before: `WHERE CAST(strftime('%Y',…) AS INTEGER) = ?, ?`.
  for path in ("happened__@year", "happened__@month", "happened__@yyyy_mm")
    err = @test_throws PormG.FilterError _IN411.objects.filter(
      path => UInt8[0x01, 0x02]).list(show_query = :dict)
    @test occursin("vector value but no operator", err.value.msg)
  end

  # A JSON PATH lookup is the arm where this was silent on PostgreSQL rather than loud: the PG branch
  # binds `string(v.values)`, which stringified the payload's Julia `repr` into
  # `#>> '{"kind"}' = 'UInt8[0x01, 0x02]'` — valid SQL, zero rows, no error, on the engine most
  # consuming apps run. A JSON value is never a byte payload.
  # Its own model, because a JSON path lookup resolves a row-join and so needs `_module` — which the
  # shared `_In411Event` deliberately does not have (see its fixture note; ~15 testsets share it).
  _json596 = Model("json596", id = IDField(), payload = JSONField())
  _json596.connect_key = "default"
  _json596._module = Main
  json_err = @test_throws PormG.FilterError _json596.objects.filter(
    "payload__kind" => UInt8[0x01, 0x02]).list(show_query = :dict)
  @test occursin("vector value but no operator", json_err.value.msg)
  @test occursin("payload__kind", json_err.value.msg)
  # The control: the same lookup with an ordinary scalar still renders.
  json_ok = _json596.objects
  json_ok.filter("payload__kind" => "binary-in")
  @test length(json_ok.list(show_query = :dict)[:parameters]) == 1

  # A PROJECTION ALIAS is a bare path too, and it has no `PormGField` to decide with — the guard
  # reads the formatter `_having_alias_formatter` resolved instead. A non-binary alias refuses…
  alias_err = @test_throws PormG.FilterError (q = _IN411.objects;
                                             q.values("c" => PormG.QueryBuilder.Count("id"));
                                             q.filter("c" => UInt8[0x01, 0x02]);
                                             q.list(show_query = :dict))
  @test occursin("vector value but no operator", alias_err.value.msg)
  # The funnel's actionable example, not the bare alias name: `occursin("c", …)` would be a
  # tautology — "c" occurs in the message this assertion's neighbour already requires, and in almost
  # any English sentence, so it could not fail. `c__@in` is what discriminates, and it is the
  # spelling the guard's `label` argument produces.
  @test occursin("c__@in", alias_err.value.msg)

  # …and a BINARY one passes the guard rather than being refused: `Max` over a BinaryField resolves
  # `format_binary_sql`, so the payload binds as one blob under `:having`. This asserts the GUARD's
  # decision — that a binary-typed alias is not swept up by the refusal — and nothing more.
  #
  # SQLITE MOCK ONLY, deliberately, and not for convenience. Measured against the live PostgreSQL:
  # `function max(bytea) does not exist`, so this statement builds and then fails at the server there.
  # `F("blob")` is not a portable substitute either — a non-aggregate alias filter lands in HAVING and
  # PostgreSQL then rejects the ungrouped projection ("column must appear in the GROUP BY clause").
  # So there is no portable spelling for filtering a binary projection alias today; the guard stays
  # permissive because narrowing it is a behavior change beyond #596, but nothing here or in the docs
  # advertises the shape as supported.
  bin_alias = _IN411.objects
  bin_alias.values("b" => PormG.QueryBuilder.Max("blob"))
  bin_alias.filter("b" => UInt8[0x01, 0x02])
  res_bin_alias = PormG.QueryBuilder.inspect_query(bin_alias; connection = _MockSQLiteIn411())
  @test res_bin_alias[:parameters] == Any[UInt8[0x01, 0x02]]
  @test count("?", res_bin_alias[:sql_text]) == 1
  @test occursin("HAVING", res_bin_alias[:sql_text])
end
