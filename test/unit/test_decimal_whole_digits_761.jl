# =============================================================================
# DecimalField write validation checks all three widths (#761)
#
# A `DecimalField(max_digits = p, decimal_places = s)` is a `NUMERIC(p, s)` column, which holds at
# most `s` fractional digits AND at most `p - s` whole ones. Write validation checked the total and
# the fractional count only, so `DecimalField(5, 2)` let `1234.5` through: PostgreSQL then refused it
# as a driver `numeric field overflow`, and SQLite stored it. Django's `DecimalValidator` checks all
# three bounds; so does PormG now, raising `InvalidValueError` before any SQL on both engines.
#
# The same digit count also treated the integer part's leading zeros as digits, so `0.55` was refused
# for `DecimalField(2, 2)` although PostgreSQL stores it. Both are one rule: a value's digits are the
# ones `Dialect._parse_sqlite_decimal` measures when it decides a stored cell fits.
#
# Hermetic: a mock PostgreSQL connection and `show_query` inspection. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_decimal_whole_digits_761.jl

using Test
using DataFrames
using Decimals
using PormG
import PormG: Models, InvalidValueError
import PormG.QueryBuilder: validate_field_data, bulk_insert, bulk_update

struct Mock761Postgres <: PormG.PormGPostgres end
PormG.config["mock761"] = PormG.Configuration.Settings(connections = Mock761Postgres(), change_data = true)

# `amount` is NUMERIC(5, 2): 3 whole digits and 2 fractional. `rate` is NUMERIC(2, 2): no whole
# digit at all, which is where a counted leading zero shows.
const Invoice761 = Models.Model_Type(
    name = "fu_invoice",
    fields = PormG.OrderedCollections.OrderedDict(
        "id"     => Models.IDField(),
        "amount" => Models.DecimalField(max_digits = 5, decimal_places = 2),
        "rate"   => Models.DecimalField(max_digits = 2, decimal_places = 2, null = true),
    ),
    field_names = ["id", "amount", "rate"],
    connect_key = "mock761",
)

# The refusal, with the message naming the bound that failed — so a value refused by the TOTAL-digit
# check (step 7) cannot pass for a whole-digit refusal (step 9).
function whole_digit_refusal(f)
    err = try
        f()
        nothing
    catch e
        e
    end
    return err isa InvalidValueError && occursin("before the decimal point", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Whole digits: the boundary of NUMERIC(5, 2)
# `999.99` is the widest value the column holds; `1000` is the first with one whole digit too many.
# Each refused value fits BOTH checks that existed before #761 (total ≤ 5, fractional ≤ 2), so only
# the whole-digit bound can refuse it — every spelling the write path normalizes, including the
# scientific and `Decimal` ones.
# ─────────────────────────────────────────────────────────────────────────────
@testset "whole digits: NUMERIC(5, 2) holds 999.99, refuses 1000" begin
    for v in (999.99, "999.99", -999.99, "-999.99", 999, "0.01", 0)
        @test validate_field_data(Invoice761, "amount", v, "create") === true
    end

    for v in (1000, "1000", -1000, "-1000", 1234.5, "1234.5", "12345", 12345,
              "1e3", 1.0e3, Decimal(0, 12345, -1), "1000.00")
        @test whole_digit_refusal(() -> validate_field_data(Invoice761, "amount", v, "create"))
    end

    # Scientific notation with an empty side of the point. `format_number_sql` accepts all of these,
    # and until the expansion learned them `"5.e3"` was counted as `5` + `.e3` — one whole digit — so
    # 5000 got past the new bound, while `".5e3"` (500) was refused as three fractional digits.
    @test whole_digit_refusal(() -> validate_field_data(Invoice761, "amount", "5.e3", "create"))
    @test whole_digit_refusal(() -> validate_field_data(Invoice761, "amount", "-5.E+3", "create"))
    @test validate_field_data(Invoice761, "amount", ".5e3", "create") === true
    @test validate_field_data(Invoice761, "amount", "5.e2", "create") === true
    @test validate_field_data(Invoice761, "rate", ".55e0", "create") === true

    # The message reports the bound and the count, like the two width checks beside it.
    err = try validate_field_data(Invoice761, "amount", "1234.5", "create"); nothing catch e; e end
    @test err isa InvalidValueError
    @test occursin("max_digits - decimal_places is 3", err.msg)
    @test occursin("uses 4", err.msg)
    @test occursin("field `amount`", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Leading zeros are not digits
# NUMERIC(2, 2) stores `0.55`: its integer part is empty, not one digit. Counting the `0` refused it
# as "3 digits" while `1.5`, which really does not fit, passed. The same miscount refused a padded
# string like "0999.99", which is 999.99.
# ─────────────────────────────────────────────────────────────────────────────
@testset "leading zeros: 0.55 fits NUMERIC(2, 2), 1.5 does not" begin
    for v in (0.55, "0.55", "0.05", "-0.55", ".55", 0.01, "0.00")
        @test validate_field_data(Invoice761, "rate", v, "create") === true
    end
    @test whole_digit_refusal(() -> validate_field_data(Invoice761, "rate", 1.5, "create"))
    @test whole_digit_refusal(() -> validate_field_data(Invoice761, "rate", "1", "create"))

    @test validate_field_data(Invoice761, "amount", "0999.99", "create") === true
    @test validate_field_data(Invoice761, "amount", "000999.99", "create") === true

    # The fractional bound is unchanged: three places in a two-place column still fail, and fail
    # on `decimal_places`, not on the new check. `1.555` is 4 digits in a 5-digit column, so the
    # total check (which runs first, as in Django) cannot be the one refusing it.
    err = try validate_field_data(Invoice761, "amount", "1.555", "create"); nothing catch e; e end
    @test err isa InvalidValueError
    @test occursin("decimal_places is 2", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# A huge exponent is counted in bounded space
# The digit count expands scientific notation into fixed-point text, and the exponent is caller-sized.
# `format_number_sql` accepts a zero at any exponent (0.0 is finite), and a zero-PADDED mantissa lets
# a huge exponent through because the padding cancels it. Expanding literally raised `OverflowError`
# past Int64 and asked for billions of zeros below it. Zero is zero; the padding is dropped before the
# point is placed; the point's final position is clamped far past the widest NUMERIC — so a value
# that fits counts exactly, and one that does not is refused as `InvalidValueError`, never a crash.
# ─────────────────────────────────────────────────────────────────────────────
@testset "huge exponents: counted exactly where it matters, in bounded space" begin
    for v in ("0e99999999999999999999", "0.e9000000000000000000", "-.0e-9000000000000000000", "0e5")
        @test validate_field_data(Invoice761, "amount", v, "create") === true
    end
    for v in ("1e-99999999999999999999", "5.e-20000")
        @test_throws InvalidValueError validate_field_data(Invoice761, "amount", v, "create")
    end

    # Padding that cancels the exponent. Each value is plain once the zeros are gone — 1000, 10, 1 —
    # and must be counted as that value, whichever way the padding points. 1000 fits the total (4 of
    # 5) and so is refused by the whole-digit bound alone.
    pad = repeat("0", 10_000)
    @test whole_digit_refusal(() -> validate_field_data(Invoice761, "amount", "0.$(pad)1e10004", "create"))  # 1000
    @test validate_field_data(Invoice761, "amount", "0.$(pad)0001e10005", "create") === true                # 10
    @test validate_field_data(Invoice761, "amount", "1$(pad)00000e-10005", "create") === true               # 1
    # ...and an exponent past Int64 over the same padding is still too wide, not a fitting 1.
    @test_throws InvalidValueError validate_field_data(Invoice761, "amount", "0.$(pad)1e99999999999999999999", "create")

    # The bound itself, called directly: the expansion is about ten thousand characters, not the
    # exponent's size.
    @test length(PormG.QueryBuilder._expand_scientific_notation("1e-99999")) < 20_000
    @test length(PormG.QueryBuilder._expand_scientific_notation("7e99999")) < 20_000
end

# ─────────────────────────────────────────────────────────────────────────────
# Every writer refuses before SQL
# `create`, `update`, `bulk_insert` and `bulk_update` all reach `_validate_field_value`, so the
# whole-digit bound holds on each. `show_query` renders without executing, so a refusal here is
# PormG's own, never the driver's `numeric field overflow`. The accepted boundary value renders on
# the same paths, so the refusals are not an artifact of the mock.
# ─────────────────────────────────────────────────────────────────────────────
@testset "create, update and bulk writers refuse 1234.5 before SQL" begin
    ok = Invoice761.objects.create("amount" => 999.99, show_query = :dict)
    @test ok[:operation] === :insert
    @test whole_digit_refusal(() -> Invoice761.objects.create("amount" => 1234.5, show_query = :dict))

    q_ok = Invoice761.objects
    q_ok.filter("id" => 1)
    @test q_ok.update("amount" => "999.99", show_query = :dict)[:operation] === :update
    q_bad = Invoice761.objects
    q_bad.filter("id" => 1)
    @test whole_digit_refusal(() -> q_bad.update("amount" => "1234.5", show_query = :dict))

    @test bulk_insert(Invoice761.objects, DataFrame(amount = [1.5, 999.99]), show_query = :dict)[:operation] === :insert
    @test whole_digit_refusal(() -> bulk_insert(Invoice761.objects, DataFrame(amount = [1.5, 1234.5]), show_query = :dict))

    df_ok = DataFrame(id = [1, 2], amount = [1.5, 999.99])
    @test bulk_update(Invoice761.objects, df_ok, columns = ["amount"], match_on = ["id"], show_query = :dict)[:operation] === :update
    df_bad = DataFrame(id = [1, 2], amount = [1.5, 1234.5])
    @test whole_digit_refusal(() -> bulk_update(Invoice761.objects, df_bad, columns = ["amount"], match_on = ["id"], show_query = :dict))
end
