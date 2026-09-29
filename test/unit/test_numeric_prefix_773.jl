# =============================================================================
# A numeric String is written in base 10 — `0x`/`0b`/`0o` prefixes are refused (#773)
#
# Julia's `tryparse(Int64, …)` reads `"0x10"`, `"0b101"` and `"0o17"`, and `tryparse(Float64, …)` reads
# hex too (`"0X10"`, `"0x1p4"`). The numeric write paths validated with those parsers while
# `Models.format_number_sql` bound the ORIGINAL text, so `"0x10"` passed as 16 and reached the driver
# as the string '0x10' — stored as TEXT by SQLite, refused or parsed depending on the PostgreSQL
# version. The #761 width check counted the text as well (`"0b101"` → 4 whole digits).
#
# Refused, not converted: Django's `int(str)` / `Decimal(str)` accept no prefix, and neither does the
# `@year` filter (`_year_bucket_bounds`). The refusal names the prefix, so it cannot pass for a width
# or a type refusal.
#
# Hermetic: a mock PostgreSQL connection and `show_query` inspection. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_numeric_prefix_773.jl

using Test
using DataFrames
using PormG
import PormG: Models, InvalidValueError, FilterError
import PormG.QueryBuilder: validate_field_data, bulk_insert, bulk_update

struct Mock773Postgres <: PormG.PormGPostgres end
PormG.config["mock773"] = PormG.Configuration.Settings(connections = Mock773Postgres(), change_data = true, db_def_folder = "mock773")

const Lap773 = Models.Model_Type(
    name = "fu_lap773",
    fields = PormG.OrderedCollections.OrderedDict(
        "id"       => Models.IDField(),
        "amount"   => Models.DecimalField(max_digits = 5, decimal_places = 2),
        "laps"     => Models.IntegerField(),
        "millis"   => Models.BigIntegerField(null = true),
        "speed"    => Models.FloatField(null = true),
    ),
    field_names = ["id", "amount", "laps", "millis", "speed"],
    connect_key = "mock773",
)

const PREFIXED = ("0x10", "-0x10", "+0x10", "0X10", "0b101", "0B101", "0o17", "0O17", "0x1p4", " 0x10 ")

# The refusal, with its message naming the prefix — so a value the #761 width check refuses
# (`"0b101"` counted as 4 whole digits) cannot pass for this one.
function prefix_refusal(f)
    err = try
        f()
        nothing
    catch e
        e
    end
    return err isa InvalidValueError && occursin(r"0x, 0b (and|or) 0o", err.msg)
end

@testset "write validation refuses 0x/0b/0o on every numeric field kind" begin
    for field in ("amount", "laps", "millis", "speed"), v in PREFIXED
        @test prefix_refusal(() -> validate_field_data(Lap773, field, v, "create"))
        @test prefix_refusal(() -> validate_field_data(Lap773, field, v, "update"))
    end
end

# Julia's integer parser also takes a space between the sign and the digits, even with `base = 10`,
# and the formatter now refuses it. The validator must refuse it first, so the error names the field
# rather than arriving from the formatter without one. Only the integer rows are regressions: the
# `amount` and `speed` validators already refused this shape, so those rows are controls.
@testset "a sign followed by a space is refused by the validator, naming the field" begin
    for field in ("laps", "millis", "amount", "speed"), v in ("+ 1", "- 5", "+\t9")
        err = try validate_field_data(Lap773, field, v, "create"); nothing catch e; e end
        @test err isa InvalidValueError
        @test occursin("field \"$field\"", err.msg)
    end
end

@testset "base-10 spellings accepted before are still accepted" begin
    for v in ("16", "+16", "-16", "00012", " 16 ", "0")
        @test validate_field_data(Lap773, "laps", v, "create") === true
        @test validate_field_data(Lap773, "millis", v, "create") === true
    end
    for v in ("1.5", ".5e2", "5.e2", "-5.E+1", "999.99", "0.50", "0")
        @test validate_field_data(Lap773, "amount", v, "create") === true
        @test validate_field_data(Lap773, "speed", v, "create") === true
    end
    @test validate_field_data(Lap773, "speed", "1.23e4", "create") === true
end

# The formatter is what binds the value, and it is also the filter formatter of every numeric field:
# refusing here is what stops the raw text reaching the driver on any path that skips the validators.
@testset "format_number_sql refuses the prefixes and keeps its base-10 contract" begin
    for v in PREFIXED
        err = try Models.format_number_sql(v); nothing catch e; e end
        @test err isa InvalidValueError
        @test occursin("non-decimal prefix", err.msg)
    end
    @test Models.format_number_sql("16") == "16"
    @test Models.format_number_sql(" .5e3 ") == ".5e3"
    @test Models.format_number_sql(["1", "2.5"]) == ["1", "2.5"]
    @test_throws InvalidValueError Models.format_number_sql(["1", "0x10"])
    # Garbage and the non-finite words stay refused, now by the grammar rather than by the parser.
    for v in ("1_000", "inf", "NaN", "1.5f0", "e5", ".")
        @test_throws InvalidValueError Models.format_number_sql(v)
    end
end

@testset "create, update and bulk writers refuse a prefixed value before SQL" begin
    @test Lap773.objects.create("amount" => "16", "laps" => "16", show_query = :dict)[:operation] === :insert
    @test prefix_refusal(() -> Lap773.objects.create("amount" => "0x10", "laps" => 1, show_query = :dict))
    @test prefix_refusal(() -> Lap773.objects.create("amount" => 1, "laps" => "0b101", show_query = :dict))

    q = Lap773.objects
    q.filter("id" => 1)
    @test prefix_refusal(() -> q.update("speed" => "0x1p4", show_query = :dict))

    @test bulk_insert(Lap773.objects, DataFrame(amount = ["1.5", "16"], laps = ["1", "16"]), show_query = :dict)[:operation] === :insert
    @test prefix_refusal(() -> bulk_insert(Lap773.objects, DataFrame(amount = ["1.5", "0x10"], laps = ["1", "2"]), show_query = :dict))
    @test prefix_refusal(() -> bulk_insert(Lap773.objects, DataFrame(amount = ["1.5", "2"], laps = ["1", "0o17"]), show_query = :dict))

    df_ok = DataFrame(id = [1, 2], amount = ["1.5", "16"], laps = ["1", "16"])
    @test bulk_update(Lap773.objects, df_ok, columns = ["amount", "laps"], match_on = ["id"], show_query = :dict)[:operation] === :update
    df_bad = DataFrame(id = [1, 2], amount = ["1.5", "0X10"], laps = ["1", "0b101"])
    @test prefix_refusal(() -> bulk_update(Lap773.objects, df_bad, columns = ["amount", "laps"], match_on = ["id"], show_query = :dict))
end

@testset "a filter value on a numeric field is base 10 too" begin
    ok = Lap773.objects
    ok.filter("laps" => "16")
    @test ok.list(show_query = :dict)[:parameters] == ["16"]

    # The filter path reports any formatter refusal as `FilterError` naming the field and the value.
    # Before #773 the formatter returned the text, so nothing was raised and '0x10' was bound.
    for (field, v) in (("laps", "0x10"), ("amount", "0b101"), ("speed", "0x1p4"))
        q = Lap773.objects
        q.filter(field => v)
        @test_throws FilterError q.list(show_query = :dict)
    end
end

# A JSON path lookup needs a registered models module (`set_models`), like `test_json_lookups.jl`.
module Json773Models
import PormG
import PormG.Models
Stint773 = Models.Model("fu_stint773",
    id = Models.IDField(),
    payload = Models.JSONField(null = true),
)
PormG.Models.set_models(@__MODULE__, "mock773")
end

# A JSON numeric comparison coerces its RHS to a Julia number, and it read "0x10" as 16.
@testset "a JSON numeric comparison takes a base-10 RHS" begin
    j_ok = Json773Models.Stint773.objects
    j_ok.filter("payload__laps__@gte" => "16")
    @test j_ok.list(show_query = :dict)[:parameters] == [16]
    for v in ("0x10", "0b101", "0x1p4")
        j_bad = Json773Models.Stint773.objects
        j_bad.filter("payload__laps__@gte" => v)
        err = try j_bad.list(show_query = :dict); nothing catch e; e end
        @test err isa FilterError
        @test occursin("base-10 number", err.msg)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Declarations are base 10 too: a field `default=` and an integer width keyword (#780)
# #773 fixed every VALUE path; the declaration-time converters — `format2int64` / `format2float64`
# (`src/Models.jl`) and `_int_kwarg` (`src/models/fields.jl`) — still used the bare `parse`, so
# `IntegerField(default = "0x10")` stored 16 and `CharField(max_length = "0x10")` made a 16-character
# column while the same string was refused as a value. Now a declaration takes exactly the spellings a
# value does. The constructors surface `FieldValidationError` (`validate_default` relabels the
# converter's refusal); the width keywords keep their own message, which names the keyword.
# ─────────────────────────────────────────────────────────────────────────────
const _INT_DEFAULTS780 = (
    ("IDField",                   d -> Models.IDField(default = d)),
    ("ForeignKey",                d -> Models.ForeignKey("drivers", default = d)),
    ("OneToOneField",             d -> Models.OneToOneField("drivers", default = d)),
    ("IntegerField",              d -> Models.IntegerField(default = d)),
    ("PositiveSmallIntegerField", d -> Models.PositiveSmallIntegerField(default = d)),
    ("PositiveIntegerField",      d -> Models.PositiveIntegerField(default = d)),
    ("BigIntegerField",           d -> Models.BigIntegerField(default = d)),
)
const _FLOAT_DEFAULTS780 = (
    ("FloatField",   d -> Models.FloatField(default = d)),
    ("DecimalField", d -> Models.DecimalField(default = d)),
)
# Every String-taking width site, with the keyword its message must name.
const _WIDTHS780 = (
    ("CharField",    "max_length",     w -> Models.CharField(max_length = w)),
    ("URLField",     "max_length",     w -> Models.URLField(max_length = w)),
    ("SlugField",    "max_length",     w -> Models.SlugField(max_length = w)),
    ("BinaryField",  "max_length",     w -> Models.BinaryField(max_length = w)),
    ("DecimalField", "max_digits",     w -> Models.DecimalField(max_digits = w, decimal_places = 2)),
    ("DecimalField", "decimal_places", w -> Models.DecimalField(max_digits = 10, decimal_places = w)),
)
_raised780(thunk) = try thunk(); nothing catch e; e end

@testset "a field default= refuses 0x/0b/0o and non-base-10 spellings (#780)" begin
    for (_, ctor) in (_INT_DEFAULTS780..., _FLOAT_DEFAULTS780...), v in (PREFIXED..., "+ 1")
        @test _raised780(() -> ctor(v)) isa PormG.FieldValidationError
    end
    # A float default had one more gap: the String arm read "Inf"/"NaN" (and an exponent that
    # overflows) although the `Real` arm refuses `Inf`. Same grammar as a value now.
    for (_, ctor) in _FLOAT_DEFAULTS780, v in ("Inf", "-inf", "NaN", "Infinity", "1e400")
        @test _raised780(() -> ctor(v)) isa PormG.FieldValidationError
    end

    # The constructor rows above are type-only, and `validate_default` relabels ANY converter throw
    # into `FieldValidationError` — so on their own they cannot tell the grammar's refusal from the
    # old parser's (several of those spellings were already refused by `parse`). The converters are
    # asked directly, where the message survives: every prefixed spelling is refused BY NAME.
    for conv in (Models.format2int64, Models.format2float64), v in PREFIXED
        err = _raised780(() -> conv(v))
        @test err isa PormG.FieldValidationError
        @test err isa Exception && occursin("non-decimal prefix", sprint(showerror, err))
    end
    # Integral-looking but not an Int64: a refusal inside the taxonomy, not a raw parse error.
    for v in ("12.5", "1e3", "99999999999999999999")
        @test _raised780(() -> Models.format2int64(v)) isa PormG.FieldValidationError
    end
    # The float twin: an exponent outside Float64's range passes the grammar, and `parse` raises a raw
    # `ArgumentError` on it (it does not return `Inf`), so the arm must refuse it itself.
    for v in ("1e400", "-1e400", "1e-400")
        err = _raised780(() -> Models.format2float64(v))
        @test err isa PormG.FieldValidationError
        @test err isa Exception && occursin("finite number", sprint(showerror, err))
    end
    # Introspection coerces a live default through the same converters, so a live reader agrees
    # with the declared side (`_default_or_drop` turns this refusal into its warn-and-drop).
    @test _raised780(() -> PormG.Migrations._coerce_default("0x10", PormG.CInt64())) isa PormG.FieldValidationError
    @test _raised780(() -> PormG.Migrations._coerce_default("Infinity", PormG.CFloat64())) isa PormG.FieldValidationError
end

@testset "an integer width keyword refuses 0x/0b/0o, naming the keyword (#780)" begin
    for (name, kw, ctor) in _WIDTHS780, v in PREFIXED
        err = _raised780(() -> ctor(v))
        @test err isa PormG.FieldValidationError
        msg = err isa Exception ? sprint(showerror, err) : ""
        @test occursin("'$kw'", msg)
        @test occursin("base 10", msg)
    end
    # `parse(Int, …; base = 10)` still reads a space after the sign; the grammar does not.
    for (_, kw, ctor) in _WIDTHS780
        err = _raised780(() -> ctor("+ 8"))
        @test err isa PormG.FieldValidationError && occursin("'$kw'", sprint(showerror, err))
    end
end

@testset "base-10 declarations are unchanged (#780)" begin
    for (_, ctor) in _INT_DEFAULTS780, v in ("16", " 16 ", "+16", "00016")
        @test ctor(v).default === Int64(16)
    end
    @test Models.IntegerField(default = "-16").default === Int64(-16)
    for (_, ctor) in _FLOAT_DEFAULTS780
        @test ctor("12.5").default === 12.5
        @test ctor(" .5e2 ").default === 50.0
        @test ctor("16").default === 16.0
    end
    for (_, kw, ctor) in _WIDTHS780
        field = ctor(" 8 ")
        slot = kw == "max_length" ? :max_length : Symbol(kw)
        @test getproperty(field, slot) === 8
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A refused live default is warned and dropped (#780)
# The live side of the one-converter seam. The rows above only prove `_coerce_default` refuses; the
# contract is what the schema reader DOES with that refusal: warn and import the column with no
# default (#292/#472), never abort `convert_schema_to_models`. Only a QUOTED literal reaches the
# converter — an unquoted SQLite `DEFAULT 0x10` is an expression token and is carried as a
# `db_default`, exactly as before #780.
# ─────────────────────────────────────────────────────────────────────────────
struct _Mock780SL <: PormG.PormGSQLite end
struct _Mock780PG <: PormG.PormGPostgres end
_spec780(t) = PormG.ColumnSpec("laps", t, true, false, false, PormG.NoDefault(), nothing,
                               PormG.CheckKind[], nothing, "")

@testset "a refused live default is warned and dropped, not raised (#780)" begin
    for (conn, raw, t) in ((_Mock780SL(), "'0x10'", PormG.CInt64()),
                           (_Mock780SL(), "'Inf'", PormG.CFloat64()),
                           (_Mock780PG(), "'Infinity'::double precision", PormG.CFloat64()))
        @test (@test_logs (:warn, r"could not be represented") PormG.Migrations._default_or_drop(
            "results", _spec780(t), raw, conn)) === PormG.NoDefault()
    end
    @test PormG.Migrations._default_or_drop("results", _spec780(PormG.CInt64()), "0x10", _Mock780SL()) ==
          PormG.ExpressionDefault("0x10")
    # And a base-10 live default still reads, so the drop is the refusal, not the reader.
    @test PormG.Migrations._default_or_drop("results", _spec780(PormG.CInt64()), "16", _Mock780SL()) ==
          PormG.LiteralDefault(16)
end
