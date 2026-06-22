"""
Unit tests for the `__@yyyy_mm` date-bucket filter operator.

`field__@yyyy_mm` is the month-bucket operator: it renders the column through
`to_char(col, 'YYYY-MM')` and binds the comparison value after normalising it via
`Models.format_yyyy_mm` (constants.jl: "yyyy_mm" => "Y_M";
functions.jl: `Y_M(x) = To_char(x, "YYYY-MM", formater = Models.format_yyyy_mm)`).

Why a dedicated file?
  - `test_operators.jl` covers the comparison / string / null suffixes but not the
    date-bucket transforms.
  - This operator carries a *custom value normaliser* (`format_yyyy_mm`) with its own
    accept/reject contract, and it is heavily used by downstream consumers
    (e.g. "competencia"/"periodo" month filters). A silent change to the rendered
    `to_char(...)` token or to the value normalisation would break those queries with
    no other failing test — so the contract is pinned here, with no live DB required
    (`show_query=:dict`).
"""

using Test
using PormG
using PormG.Models: Model, IDField, DateField, DateTimeField, format_yyyy_mm

# ---------------------------------------------------------------------------
# Minimal mock-Postgres fixture (no live database).
# ---------------------------------------------------------------------------
if !isdefined(Main, :_YmTestEvent)
  _YmTestEvent = Model("events",
    id        = IDField(),
    happened  = DateField(),
    logged_at = DateTimeField(),
  )
  _YmTestEvent.connect_key = "default"

  struct _MockPostgresYm <: PormG.PormGPostgres end
  PormG.config["default"] = PormG.Configuration.Settings(
    connections = _MockPostgresYm(),
    change_data = true,
  )
end

const _Ev = _YmTestEvent

@testset "Date bucket operator (__@yyyy_mm)" begin

  # =========================================================================
  # 1. String value already in YYYY-MM form
  # =========================================================================
  @testset "YYYY-MM string → to_char(col,'YYYY-MM') = \$1" begin
    res = _Ev.objects.filter("happened__@yyyy_mm" => "1991-10").list(show_query=:dict)

    # Column is rendered through to_char with the YYYY-MM format mask.
    @test occursin("to_char", lowercase(res[:sql_text]))
    @test contains(res[:sql_text], "'YYYY-MM'")
    @test contains(res[:sql_text], "happened")
    # Value is bound, never interpolated into the SQL text.
    @test res[:parameters] == ["1991-10"]
    @test !contains(res[:sql_text], "1991-10")
  end

  # =========================================================================
  # 2. Integer YYYYMM is normalised to a "YYYY-MM" bound parameter
  # =========================================================================
  @testset "Integer YYYYMM is normalised to YYYY-MM" begin
    res = _Ev.objects.filter("happened__@yyyy_mm" => 202501).list(show_query=:dict)

    @test contains(res[:sql_text], "'YYYY-MM'")
    # 202501 → "2025-01" (the dash is inserted by format_yyyy_mm).
    @test res[:parameters] == ["2025-01"]

    # The normaliser itself, pinned directly:
    @test format_yyyy_mm(202501) == "2025-01"
    @test format_yyyy_mm("1991-10") == "1991-10"
  end

  # =========================================================================
  # 3. Reject malformed values (the accept/reject contract)
  # =========================================================================
  @testset "Malformed bucket values throw ArgumentError" begin
    # 4-digit string (year only) — missing the month component.
    @test_throws ArgumentError _Ev.objects.filter("happened__@yyyy_mm" => "2025").list(show_query=:dict)
    # Bare 6-digit *string* is NOT accepted (only the dashed string or a 6-digit Integer).
    @test_throws ArgumentError _Ev.objects.filter("happened__@yyyy_mm" => "202501").list(show_query=:dict)
    # 4-digit integer is not a YYYYMM bucket.
    @test_throws ArgumentError format_yyyy_mm(2025)
    # Non String/Integer value.
    @test_throws ArgumentError format_yyyy_mm(2025.0)
  end

  # =========================================================================
  # 4. Combined with another filter — parameter ordering is preserved
  # =========================================================================
  @testset "Bucket filter composes with other filters in order" begin
    res = _Ev.objects.filter(
      "happened__@yyyy_mm" => "2025-01",
      "id__@gte"           => 10,
    ).list(show_query=:dict)

    @test contains(res[:sql_text], "'YYYY-MM'")
    @test contains(res[:sql_text], ">=")
    @test "2025-01" in res[:parameters]
    @test 10 in res[:parameters]
    @test length(res[:parameters]) == 2
  end

end
