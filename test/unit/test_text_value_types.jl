# ============================================================
# #860 — which values a text comparison accepts, and how it refuses the rest.
#
# `Models.format_text_sql` had methods for `Int`, the date/time types, `Bool`, strings, arrays and
# `missing`/`nothing`, and nothing else. A float or a `Decimal` compared with a text column therefore
# escaped `_guarded_format` as a raw `MethodError` naming an internal function — on every path that
# formats through it: a plain `CharField`, a text-function alias (`Lower`), a `ToChar` alias, and an
# `F(...)` comparison. The method covered `Int` only, so an `Int32` or a `UInt8` failed the same way
# although `5` worked.
#
# The fix refuses what has no single text (a float, a `Decimal`: `1.5` vs `1.50`, `"1.0e10"`) with a
# typed error, and widens `Int` to `Integer`. Deterministic and DB-free: mock connections on both
# engines, `inspect_query` for the bound parameters, `show_query = :dict` for the write path.
# ============================================================

using Test
using PormG
using Decimals: Decimal
using PormG.Models: Model, IDField, CharField, DateField
using PormG.QueryBuilder: inspect_query, F, ToChar
using PormG.Functions: Lower

# Dedicated mocks and config keys, so this file shares nothing with the other unit files in Main.
struct TextVal860MockPg <: PormG.PormGPostgres end
struct TextVal860MockSl <: PormG.PormGSQLite end
PormG.config["textval860_pg"] = PormG.Configuration.Settings(connections = TextVal860MockPg(), change_data = true)
PormG.config["textval860_sl"] = PormG.Configuration.Settings(connections = TextVal860MockSl(), change_data = true)

# A trimmed F1 drivers table: `surname` is the text column under test, `dob` feeds the `ToChar` alias.
textval860_driver(key) = begin
  m = Model("textval860_driver", driverid = IDField(), surname = CharField(null = true), dob = DateField(null = true))
  m.connect_key = key
  m
end
const TEXTVAL860_MODELS = ((:postgres, textval860_driver("textval860_pg")), (:sqlite, textval860_driver("textval860_sl")))

# The four routes a value compared with text takes. Each returns the query, built and inspected, so a
# refusal raised at build time or at render time is caught by the same call. The name is the label
# the `FilterError` must carry: the field, or the alias the user filtered on.
const TEXTVAL860_ROUTES = (
  (route = "plain CharField", label = "surname",
   build = (M, v) -> (q = M.objects; q.filter("surname" => v); inspect_query(q))),
  (route = "Lower alias", label = "nm",
   build = (M, v) -> (q = M.objects; q.values("driverid", "nm" => Lower("surname")); q.filter("nm" => v); inspect_query(q))),
  (route = "ToChar alias", label = "y",
   build = (M, v) -> (q = M.objects; q.values("driverid", "y" => ToChar("dob", "YYYY")); q.filter("y" => v); inspect_query(q))),
  (route = "F operand", label = "surname",
   build = (M, v) -> (q = M.objects; q.filter(F("surname") == v); inspect_query(q))),
)

# The exception a call raises, or `nothing` — so a missing refusal fails the `isa` test below rather
# than aborting the file (a unit file stops at its first failing top-level testset).
textval860_refusal(call) = try
  call()
  nothing
catch e
  e
end

# ─────────────────────────────────────────────────────────────────────────────
# Formatter: a float or a Decimal is refused with the #231 value-error type, an integer of any width
# is its base-10 text. This is the unit the four routes below all reach.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#860: format_text_sql refuses a float or Decimal, formats any integer" begin
  for v in (1.5, Float32(2.5), Decimal(1.5), Base.UUID(0))
    err = textval860_refusal(() -> PormG.Models.format_text_sql(v))
    @test err isa PormG.InvalidValueError
    # The message names the type it was given and the explicit spelling that does work.
    msg = err === nothing ? "" : sprint(showerror, err)
    @test occursin(string(typeof(v)), msg)
    @test occursin("string(x)", msg)
  end
  # Every integer width has the one text an `Int64` has. `Bool` keeps its own method (it is an
  # `Integer` too), so it is pinned here as unchanged rather than as base-10 text.
  @test PormG.Models.format_text_sql(Int32(5)) == "5"
  @test PormG.Models.format_text_sql(UInt8(3)) == "3"
  @test PormG.Models.format_text_sql(big(7)) == "7"
  @test PormG.Models.format_text_sql(true) === true
  # A collection maps element-wise, so one float element refuses the whole list the same way.
  @test textval860_refusal(() -> PormG.Models.format_text_sql([1, 1.5])) isa PormG.InvalidValueError
end

# ─────────────────────────────────────────────────────────────────────────────
# Filter: a float or a Decimal compared with text is a `FilterError` naming the field or alias, on
# both engines and through every route — never the raw `MethodError` it was. The `ToChar` route is
# the one the #851 work opened (`values("y" => ToChar(...)).filter("y" => 20.5)`).
# `Decimal` skips the `F` route: `F("surname") == Decimal(…)` is refused before any formatter, by a
# different check this issue does not touch.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#860: a float or Decimal compared with text raises FilterError" begin
  for (backend, M) in TEXTVAL860_MODELS, r in TEXTVAL860_ROUTES, v in (1.5, Float32(20.5), Decimal(1.5))
    v isa Decimal && r.route == "F operand" && continue
    @testset "$backend · $(r.route) · $(typeof(v))" begin
      err = textval860_refusal(() -> r.build(M, v))
      @test err isa PormG.FilterError
      msg = err === nothing ? "" : sprint(showerror, err)
      @test occursin(r.label, msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Filter: a narrow integer binds the same text a plain `Int` does, through every route. Before #860
# an `Int32` or a `UInt8` raised the raw `MethodError` while `5` bound `"5"`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#860: an integer of any width binds as text" begin
  for (backend, M) in TEXTVAL860_MODELS, r in TEXTVAL860_ROUTES
    @testset "$backend · $(r.route)" begin
      expected = last(r.build(M, 5)[:parameters])
      @test expected == "5"
      @test last(r.build(M, Int32(5))[:parameters]) == expected
      @test last(r.build(M, UInt8(5))[:parameters]) == expected
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Write path: the same formatter is the CharField's write formatter, so a float in `create` is the
# write path's `InvalidValueError` (not a `FilterError`: nothing is being filtered), and an `Int32`
# is written as its text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#860: create refuses a float in a text field and writes a narrow integer as text" begin
  for (backend, M) in TEXTVAL860_MODELS
    err = textval860_refusal(() -> M.objects.create("surname" => 1.5, show_query = :dict))
    @test err isa PormG.InvalidValueError
    out = M.objects.create("surname" => Int32(5), show_query = :dict)
    @test "5" in out[:parameters]
  end
end
