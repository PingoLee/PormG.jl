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
#
# #868 (the three testsets after #860's) is the write-side follow-up: once an integer or a date is
# written as text, a text field's `max_length` has to measure that text too, not only a String's.
#
# #876 (the last testsets) refuses a `Bool` the same way #860 refuses a float. It was passed through
# unformatted, so each driver chose its text — `"true"` on PostgreSQL, `"1"` on SQLite.
# ============================================================

using Test
using PormG
using Decimals: Decimal
using PormG.Models: Model, IDField, CharField, DateField
using Dates: Date, DateTime, Time
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
  # Every integer width has the one text an `Int64` has. `Bool` is an `Integer` too but keeps its own
  # method, which refuses it (#876) — pinned with the #876 testsets below. Until #876 this line pinned
  # `format_text_sql(true) === true`, recorded as "unchanged" while the Bool question was open; #876
  # settled it as a refusal, so that pin is replaced, not lost.
  @test PormG.Models.format_text_sql(Int32(5)) == "5"
  @test PormG.Models.format_text_sql(UInt8(3)) == "3"
  @test PormG.Models.format_text_sql(big(7)) == "7"
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

# ─────────────────────────────────────────────────────────────────────────────
# #868 — a text field's `max_length` is measured on the text written, not only on a String.
# `format_text_sql` writes an integer (any width, #860) and a date/time as text, but the check ran
# only for an `AbstractString`, so `CharField(max_length = 3)` took `12345` and `Date(2020, 1, 1)`:
# SQLite stored the over-length value, PostgreSQL refused it as an untyped driver error. Now each is
# the same `InvalidValueError` an over-length String gets, naming the field, on both engines.
# ─────────────────────────────────────────────────────────────────────────────

# F1 driver codes are three letters ("SEN", "PRO"), so `code` is the bounded text column.
textval868_driver(key) = begin
  m = Model("textval868_driver", driverid = IDField(), code = CharField(max_length = 3, null = true))
  m.connect_key = key
  m
end
const TEXTVAL868_MODELS = ((:postgres, textval868_driver("textval860_pg")), (:sqlite, textval868_driver("textval860_sl")))

# The message a refusal carries, or "" when there was none, so `occursin` fails instead of erroring.
textval868_msg(err) = err === nothing ? "" : sprint(showerror, err)

@testset "#868: create measures an integer or date written to a text field against max_length" begin
  over = (12345, Int32(12345), UInt16(1000), big(1000), Date(2020, 1, 1), DateTime(2020, 1, 1, 12),
          Time(12, 30))
  for (backend, M) in TEXTVAL868_MODELS, v in over
    @testset "$backend · $(typeof(v))" begin
      err = textval860_refusal(() -> M.objects.create("code" => v, show_query = :dict))
      @test err isa PormG.InvalidValueError
      msg = textval868_msg(err)
      # The same refusal an over-length String gets: the field, the bound, the measured length.
      @test occursin("\"code\"", msg)
      @test occursin("max_length is 3", msg)
      @test occursin("has length $(length(PormG.Models.format_text_sql(v)))", msg)
      # A value that is not a String says what text it was measured as.
      @test occursin(repr(PormG.Models.format_text_sql(v)), msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #868: the boundary. A value whose text fits is written as before, at exactly max_length and
# below. (A `Bool` was pinned here as still written; since #876 it is refused, below.)
# ─────────────────────────────────────────────────────────────────────────────
@testset "#868: a value whose text fits max_length is still written" begin
  for (backend, M) in TEXTVAL868_MODELS
    @test "123" in M.objects.create("code" => 123, show_query = :dict)[:parameters]
    @test "255" in M.objects.create("code" => UInt8(255), show_query = :dict)[:parameters]
    @test "SEN" in M.objects.create("code" => "SEN", show_query = :dict)[:parameters]
    # An over-length String is refused exactly as before #868.
    @test textval860_refusal(() -> M.objects.create("code" => "SENNA", show_query = :dict)) isa PormG.InvalidValueError
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #868: every writer shares the check (`_validate_field_value`), so a bulk write refuses the same
# integer. `bulk_insert` stands in for the three bulk writers here, on the PostgreSQL mock only: the
# SQLite mock stops earlier, at the driver's bind-limit probe, which needs the SQLite extension this
# DB-free file does not load. The check it would reach is the same function on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#868: bulk_insert refuses an over-length integer in a text field" begin
  M = last(first(TEXTVAL868_MODELS))
  df = PormG.QueryBuilder.DataFrames.DataFrame(code = Any["SEN", 12345])
  err = textval860_refusal(() -> PormG.QueryBuilder.bulk_insert(M.objects, df; show_query = :dict))
  @test err isa PormG.InvalidValueError
  @test occursin("max_length is 3", textval868_msg(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# #876 — a `Bool` written to or compared with a text field is refused, typed, like a float (#860).
# `format_text_sql(::Bool)` returned the `Bool` unformatted, so the driver chose its text: LibPQ binds
# `"true"`, SQLite stores `1` as `"1"`. The same `create` stored different text per engine, and
# `filter("code" => true)` matched on one of them. A text field's `default = true` was already a
# `FieldValidationError`; now a written or filtered `Bool` is refused too, on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#876: format_text_sql refuses a Bool, alone or in a list" begin
  for v in (true, false, [true], ["SEN", false])
    @testset "$(repr(v))" begin
      err = textval860_refusal(() -> PormG.Models.format_text_sql(v))
      @test err isa PormG.InvalidValueError
      # The message names the type and the explicit spelling that does work.
      msg = textval868_msg(err)
      @test occursin("Got a Bool", msg)
      @test occursin("string(x)", msg)
    end
  end
end

@testset "#876: a Bool compared with text raises FilterError" begin
  for (backend, M) in TEXTVAL860_MODELS, r in TEXTVAL860_ROUTES, v in (true, false)
    @testset "$backend · $(r.route) · $v" begin
      err = textval860_refusal(() -> r.build(M, v))
      @test err isa PormG.FilterError
      @test occursin(r.label, textval868_msg(err))
    end
  end
  # An `__in` list of `Bool`s maps element-wise into the same refusal. This one is pinned, not fixed:
  # before #876 the element failed to `convert` into the formatter's `Vector{String}`, which the
  # filter guard already reported as this `FilterError` (a mixed list such as `["SEN", true]` stops
  # earlier still, at the homogeneous-list check). It must stay refused now that the cause is typed.
  for (backend, M) in TEXTVAL860_MODELS, v in ([true], [true, false])
    @testset "$backend · __in $(repr(v))" begin
      err = textval860_refusal(() -> (q = M.objects; q.filter("surname__in" => v); inspect_query(q)))
      @test err isa PormG.FilterError
      @test occursin("surname", textval868_msg(err))
    end
  end
end

@testset "#876: create and update refuse a Bool in a text field" begin
  for (backend, M) in TEXTVAL868_MODELS, v in (true, false)
    @testset "$backend · $v" begin
      err = textval860_refusal(() -> M.objects.create("code" => v, show_query = :dict))
      @test err isa PormG.InvalidValueError
      msg = textval868_msg(err)
      @test occursin("Got a Bool", msg)
      # Refused as a Bool, not measured as a length: `CharField(max_length = 3)` has no text to
      # measure a `Bool` against, which was #868's open half.
      @test !occursin("max_length", msg)

      q = M.objects; q.filter("driverid" => 1)
      err = textval860_refusal(() -> q.update("code" => v, show_query = :dict))
      @test err isa PormG.InvalidValueError
      @test occursin("Got a Bool", textval868_msg(err))
    end
  end
end

# The bulk writers format through the same formatter, so their depuration pass names the cell
# (#875/#869 own that wording); here only that a `Bool` is refused at all, on the PostgreSQL mock
# for the reason the #868 bulk testset above gives.
@testset "#876: bulk_insert and bulk_update refuse a Bool in a text field" begin
  M = last(first(TEXTVAL868_MODELS))
  df = PormG.QueryBuilder.DataFrames.DataFrame(driverid = [1, 2], code = Any["SEN", true])
  err = textval860_refusal(() -> PormG.QueryBuilder.bulk_insert(M.objects, df[:, [:code]]; show_query = :dict))
  @test err isa PormG.InvalidValueError
  @test occursin("Got a Bool", textval868_msg(err))
  err = textval860_refusal(() -> PormG.QueryBuilder.bulk_update(M.objects, df; columns = ["code"],
                                                                match_on = ["driverid"], show_query = :dict))
  @test err isa PormG.InvalidValueError
  @test occursin("Got a Bool", textval868_msg(err))
end

# `TimeField` has no formatter of its own and rides `format_text_sql`, so a `Bool` compared with a
# time is refused by the same method. Before #876 it bound `true` against the time column.
textval876_lap(key) = begin
  m = Model("textval876_lap", lapid = IDField(), lap_time = PormG.Models.TimeField(null = true))
  m.connect_key = key
  m
end
@testset "#876: a Bool compared with a TimeField raises FilterError" begin
  for key in ("textval860_pg", "textval860_sl")
    M = textval876_lap(key)
    err = textval860_refusal(() -> (q = M.objects; q.filter("lap_time" => true); inspect_query(q)))
    @test err isa PormG.FilterError
    @test occursin("lap_time", textval868_msg(err))
  end
end
