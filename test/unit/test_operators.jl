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
using PormG.Models: Model, CharField, IDField, IntegerField, DateField, DateTimeField
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
