"""
Unit tests for `ArrayField` (#28): a one-dimensional PostgreSQL array of a base field's values.
PostgreSQL only: SQLite has no array type, and rendering one there raises `BackendCapabilityError`
— PormG refuses a specialized type on SQLite rather than emulate it (the engine-alignment rule:
core types stay aligned, specialized ones are refused).

This file covers:
- Construction: the element table (`array_element_kind`), the refused bases and base keywords, `size`,
  `default=` canonicalization and refusal
- The array literal: parser and printer against a golden corpus, and the round trip
- The element codecs, and `normalize_pg_array` over every shape either driver returns
- DDL on PostgreSQL, the SQLite refusal at both sites, the canonical column IR (drift guard)
- Catalog defaults, inspectdb, the migration retypes and their lossy-ALTER findings
- `Model_to_str` round trip and the REPL display
- Write validation, filters (equality, `@isnull`, the refusals), and the bulk writers' SQL
- The Django importer still reports `ArrayField` instead of constructing it

Hermetic: mock connections only. The live half — both drivers round-tripping every element kind,
the bulk writers and the migrations against a real server — is `test/integration/test_array_field.jl`.
"""
# julia --project=test/integration test/unit/test_array_field.jl

using Test
using Logging
using Dates, TimeZones, UUIDs
using Decimals
using PormG
using PormG.Models
using PormG.QueryBuilder: validate_field_data, bulk_insert, bulk_update, bulk_copy
import PormG: Migrations, Dialect, CArray, CInt32, CInt64, CFloat64, CDecimal, CBool, CText,
              CVarChar, CDate, CDateTime, CUUID, CUnsupported, PormGArrayLiteral
import PormG.Migrations: column_spec, column_delta, parse_canonical_type, _lossy_alters,
                         ColumnSpec, NoDefault
import DataFrames

const AF = PormG.Models

struct _MockPgArr28 <: PormG.PormGPostgres end
struct _MockSlArr28 <: PormG.PormGSQLite end
const PG_ARR28 = _MockPgArr28()
const SL_ARR28 = _MockSlArr28()
# The constraint-name lookups `alter_field` asks a PostgreSQL catalog for.
PormG.get_constraints_pk(::_MockPgArr28, t::String, f::String) = nothing
PormG.get_constraints_unique(::_MockPgArr28, t::String, f::String) = nothing
PormG.get_constraints_checks(::_MockPgArr28, t::String, f::String) = String[]
PormG.get_constraints_byte_length_checks(::_MockPgArr28, t::String, f::String) = String[]

PormG.config["arr28_pg"] = PormG.Configuration.Settings(connections = PG_ARR28, change_data = true)

# A race's tyre plan: the compounds a team brought, the laps it pitted on, its lap-time targets.
if !isdefined(Main, :_Arr28Strategy)
  _Arr28Strategy = AF.Model("race_strategy",
    id             = AF.IDField(),
    team           = AF.CharField(max_length = 100),
    tyre_compounds = AF.ArrayField(AF.CharField(max_length = 12); size = 6),
    pit_laps       = AF.ArrayField(AF.IntegerField(null = true), default = Int[]),
    targets        = AF.ArrayField(AF.DecimalField(max_digits = 7, decimal_places = 3), null = true),
  )
  _Arr28Strategy.connect_key = "arr28_pg"
end
const _AS = _Arr28Strategy

# Error messages carry ANSI colour on a TTY (and on CI); strip it before matching text.
_plain_a28(msg::AbstractString) = replace(msg, r"\e\[[0-9;]*m" => "")
_err_a28(f) = try f(); nothing catch e; e end
_msg_a28(f) = (e = _err_a28(f); e === nothing ? "" : _plain_a28(sprint(showerror, e)))

# Every base field an ArrayField accepts, with the element kind and the PostgreSQL column type.
const ARR28_BASES = [
  AF.CharField(max_length = 12)                        => (CVarChar(12), "varchar(12)[]"),
  AF.TextField()                                       => (CText(), "text[]"),
  AF.SlugField()                                       => (CVarChar(50), "varchar(50)[]"),
  AF.EmailField()                                      => (CText(), "TEXT[]"),
  AF.URLField()                                        => (CVarChar(200), "varchar(200)[]"),
  AF.IntegerField()                                    => (CInt32(), "integer[]"),
  AF.BigIntegerField()                                 => (CInt64(), "bigint[]"),
  AF.FloatField()                                      => (CFloat64(), "float[]"),
  AF.DecimalField(max_digits = 7, decimal_places = 3)  => (CDecimal(7, 3), "decimal(7, 3)[]"),
  AF.BooleanField()                                    => (CBool(), "boolean[]"),
  AF.DateField()                                       => (CDate(), "date[]"),
  AF.DateTimeField()                                   => (CDateTime(true), "timestamptz[]"),
  AF.DateTimeField(type = "TIMESTAMP")                 => (CDateTime(false), "timestamp[]"),
  AF.UUIDField()                                       => (CUUID(), "uuid[]"),
]

@testset "ArrayField (#28)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Construction: the element table
  # `array_element_kind` is the one table of what an array may hold. The bases it leaves out are
  # refused by name, and a column keyword on the base field (which would never be rendered) is
  # refused rather than silently dropped — the #516 stance.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "construction: element table and refusals" begin
    for (base, (kind, _)) in ARR28_BASES
      @test AF.array_element_kind(base) == kind
      f = AF.ArrayField(base)
      @test f isa AF.sArrayField && f.type == "ARRAY" && f.base_field === base
      @test f.size === nothing && f.default === nothing && !f.null && f.editable
      @test nameof(f.formatter) === :format_array_sql
    end
    for bad in (AF.JSONField(), AF.BinaryField(), AF.DurationField(), AF.TimeField(),
                AF.PositiveIntegerField(), AF.GenericIPAddressField(), AF.ForeignKey("Driver"),
                AF.ArrayField(AF.IntegerField()))
      e = _err_a28(() -> AF.ArrayField(bad))
      @test e isa PormG.FieldValidationError
      @test occursin("cannot be an array element", _plain_a28(sprint(showerror, e)))
    end
    # The message names the public constructor, never the storage struct.
    @test occursin("a JSONField cannot", _msg_a28(() -> AF.ArrayField(AF.JSONField())))
    # A column keyword on the element field: every one is named, in one message.
    m = _msg_a28(() -> AF.ArrayField(AF.IntegerField(unique = true, db_index = true, default = 3)))
    @test occursin("`unique`", m) && occursin("`db_index`", m) && occursin("`default`", m)
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.DateTimeField(auto_now = true))
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.UUIDField(auto_add = true))
    @test_throws PormG.FieldValidationError AF.ArrayField("integer")
    # `null` on the element field is the element-NULL rule, and is accepted.
    @test AF.ArrayField(AF.IntegerField(null = true)).base_field.null
    # No primary key: an array is no row's identity.
    @test (@test_logs (:warn, r"Unexpected parameter") AF.ArrayField(AF.IntegerField(); primary_key = true)).primary_key == false
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Construction: `size` and `default=`
  # `size` is checked in Julia on write (PostgreSQL neither enforces nor keeps it). A default is
  # stored as its canonical literal, so it is never one shared mutable vector, and every spelling of
  # one array — vector, tuple, literal — stores the same text.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "construction: size and default" begin
    @test AF.ArrayField(AF.IntegerField(); size = 3).size == 3
    @test AF.ArrayField(AF.IntegerField(); size = Int32(3)).size == 3
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); size = 0)
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); size = "x")
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); size = true)

    @test AF.ArrayField(AF.IntegerField(); default = Int[]).default == "{}"
    @test AF.ArrayField(AF.IntegerField(); default = [1, 2]).default == "{1,2}"
    @test AF.ArrayField(AF.IntegerField(); default = (1, 2)).default == "{1,2}"
    @test AF.ArrayField(AF.IntegerField(); default = " { 1 , 2 } ").default == "{1,2}"
    @test AF.ArrayField(AF.CharField(max_length = 12); default = ["SOFT", "a b"]).default == "{SOFT,\"a b\"}"
    @test AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2); default = [1.5, "2.50"]).default == "{1.5,2.5}"
    # The default is validated as a write would be: too many elements, a NULL element the base field
    # refuses, an element the base field refuses, a function.
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); size = 1, default = [1, 2])
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); default = [1, nothing])
    @test AF.ArrayField(AF.IntegerField(null = true); default = [1, nothing]).default == "{1,NULL}"
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); default = ["x"])
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); default = 2^40)
    @test occursin("not a function", _msg_a28(() -> AF.ArrayField(AF.IntegerField(); default = () -> Int[])))
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); default = 1)
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); default = [1 2; 3 4])
    # A default element is held to the element field's bounds, as a scalar default is — not left for
    # the server to refuse on the first insert that relies on it (#28 review).
    @test occursin("max_length is 3", _msg_a28(() -> AF.ArrayField(AF.CharField(max_length = 3); default = ["abcd"])))
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2); default = [12345.6])
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2); default = [1.555])
    @test AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2); default = [-123.45, 0.5]).default == "{-123.45,0.5}"
    # A float element is spelled by its shortest text, not the formatter's 17 digits.
    @test AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2); default = [1.1]).default == "{1.1}"
    @test _AS.fields["targets"].formatter([0.1, 81.5]) == PormGArrayLiteral("{0.1,81.5}")
    # A `Decimal` element keeps its own value — under Decimals 0.4 it is an `AbstractFloat` too, and
    # must not take the float spelling (found by the live suite).
    @test _AS.fields["targets"].formatter([Decimals.Decimal(0, 81500, -3), parse(Decimals.Decimal, "1.25")]) ==
          PormGArrayLiteral("{81.5,1.25}")
    # …and every IEEE width converts through its plain text (`repr(1.5f0)` is `"1.5f0"`, delta review).
    @test _AS.fields["targets"].formatter(Float32[1.5, 81.25]) == PormGArrayLiteral("{1.5,81.25}")
    @test _AS.fields["targets"].formatter(Float16[1.5]) == PormGArrayLiteral("{1.5}")
    @test AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2); default = Float32[1.5]).default == "{1.5}"
    # `db_default` and `default` stay exclusive.
    @test_throws PormG.FieldValidationError AF.ArrayField(AF.IntegerField(); default = Int[],
                                                          db_default = (postgres = "ARRAY[]::integer[]",))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The array literal: golden corpus
  # The printer quotes exactly what PostgreSQL's `array_out` quotes (empty, whitespace, a reserved
  # character, anything reading as NULL), and the parser reads what PostgreSQL prints — the bounds
  # decoration included, which is dropped (PormG reads every array 1-based).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "literal parser and printer" begin
    corpus = [
      Union{Nothing, String}[]                                  => "{}",
      Union{Nothing, String}["SOFT", "MEDIUM"]                  => "{SOFT,MEDIUM}",
      Union{Nothing, String}["a b", "", " lead"]                => "{\"a b\",\"\",\" lead\"}",
      Union{Nothing, String}["x,y", "{z}", "q\"t", "b\\s"]      => "{\"x,y\",\"{z}\",\"q\\\"t\",\"b\\\\s\"}",
      Union{Nothing, String}[nothing, "NULL", "null"]           => "{NULL,\"NULL\",\"null\"}",
      Union{Nothing, String}["São Paulo", "Ímola"]              => "{\"São Paulo\",Ímola}",
    ]
    for (elems, text) in corpus
      @test AF.print_pg_array_literal(elems) == text
      @test isequal(AF.parse_pg_array_literal(text), elems)
    end
    # What PostgreSQL may print that PormG does not: spacing, a lower-case null, a bounds decoration.
    @test isequal(AF.parse_pg_array_literal(" { 1 , NULL , 3 } "), Union{Nothing, String}["1", nothing, "3"])
    @test isequal(AF.parse_pg_array_literal("[0:2]={1,2,3}"), Union{Nothing, String}["1", "2", "3"])
    @test isequal(AF.parse_pg_array_literal("{a\\,b}"), Union{Nothing, String}["a,b"])
    # Only PostgreSQL's six ASCII whitespace characters separate; a no-break or ideographic space is
    # data, which PostgreSQL prints unquoted at an element's edge (#28 review).
    @test isequal(AF.parse_pg_array_literal("{\u00a0Senna\u3000, x}"), Union{Nothing, String}["\u00a0Senna\u3000", "x"])
    @test isequal(AF.parse_pg_array_literal("{\u00a0}"), Union{Nothing, String}["\u00a0"])
    @test AF.canonical_array_literal(["\u00a0Senna"], CText()) == "{\"\u00a0Senna\"}"   # the printer still quotes it
    for bad in ("", "1,2", "{1,2", "{1,,2}", "{{1,2},{3,4}}", "{1}x", "{\"a}", "{a\"b}")
      @test_throws PormG.InvalidValueError AF.parse_pg_array_literal(bad)
    end
    @test occursin("multi-dimensional", _msg_a28(() -> AF.parse_pg_array_literal("{{1}}")))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The element codecs
  # Every element is converted to its VALUE and printed from it, so a written literal and a
  # canonicalized default share one printer. The text forms PostgreSQL prints are read back too.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "element codecs" begin
    v(k, x) = AF.pg_array_element_value(k, x)
    t(k, x) = AF.pg_array_element_text(k, v(k, x))
    @test v(CInt32(), "42") === Int32(42) && v(CInt32(), Int64(7)) === Int32(7)
    @test_throws PormG.InvalidValueError v(CInt32(), 2^31)
    @test_throws PormG.InvalidValueError v(CInt32(), true)
    @test_throws PormG.InvalidValueError v(CInt32(), "4.5")
    @test v(CInt64(), 2^40) === Int64(2^40)
    @test t(CFloat64(), 1.5) == "1.5" && t(CFloat64(), "Infinity") == "Infinity" && t(CFloat64(), "NaN") == "NaN"
    @test t(CDecimal(7, 3), "1.500") == "1.5" && t(CDecimal(7, 3), "-0.050") == "-0.05" &&
          t(CDecimal(7, 3), "1200") == "1200" && t(CDecimal(7, 3), 0) == "0"
    @test v(CDecimal(7, 3), "2.25") isa Decimals.Decimal
    @test_throws PormG.InvalidValueError v(CDecimal(7, 3), NaN)
    @test_throws PormG.InvalidValueError v(CDecimal(7, 3), "abc")
    @test t(CBool(), "t") == "t" && t(CBool(), false) == "f" && v(CBool(), "TRUE") === true
    @test_throws PormG.InvalidValueError v(CBool(), "yes")
    @test t(CDate(), "2024-03-02") == "2024-03-02" && v(CDate(), Date(2024, 3, 2)) == Date(2024, 3, 2)
    @test_throws PormG.InvalidValueError v(CDate(), "2024-02-30")
    # A timestamptz element: PostgreSQL's spelling and PormG's own both read to one UTC instant.
    zdt = ZonedDateTime(DateTime(2024, 3, 2, 12, 0, 0, 250), tz"UTC")
    @test v(CDateTime(true), "2024-03-02 14:00:00.25+02") == zdt
    @test v(CDateTime(true), "2024-03-02T12:00:00.250+00:00") == zdt
    @test v(CDateTime(true), "2024-03-02 12:00:00.250123+00") == zdt   # microseconds dropped
    @test t(CDateTime(true), zdt) == "2024-03-02T12:00:00.250+00:00"
    @test v(CDateTime(false), "2024-03-02 12:00:00.25") == DateTime(2024, 3, 2, 12, 0, 0, 250)
    @test v(CDateTime(false), zdt) == DateTime(2024, 3, 2, 12, 0, 0, 250)
    @test t(CUUID(), "550E8400-E29B-41D4-A716-446655440000") == "550e8400-e29b-41d4-a716-446655440000"
    @test_throws PormG.InvalidValueError v(CUUID(), "not-a-uuid")
    @test v(CText(), "a") == "a"
    @test_throws PormG.InvalidValueError v(CText(), 1)

    # Whole arrays: any two spellings of one array canonicalize to the same text.
    @test AF.canonical_array_literal("{1.50,2}", CDecimal(5, 2)) == AF.canonical_array_literal([1.5, 2], CDecimal(5, 2)) == "{1.5,2}"
    @test AF.canonical_array_literal(["2024-03-02 14:00:00+02"], CDateTime(true)) == "{2024-03-02T12:00:00.000+00:00}"
    @test AF.canonical_array_literal("{t,NULL}", CBool()) == "{t,NULL}"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Reads: every driver shape normalizes to one Vector{T}
  # LibPQ returns the raw literal for most element types and a possibly offset-indexed array for the
  # numeric ones; Postgres.jl returns a typed Vector or a Vector{Any}. All of them read as the same
  # 1-based Vector{T}, `T` being a scalar read's type — or Vector{Union{Missing, T}} with a NULL.
  # Fail-open: a multi-dimensional value, or text that is not a literal, comes back unchanged.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "read normalization (value_parser)" begin
    parse_with(kind) = PormG.value_parser(CArray(kind), PG_ARR28)
    p32 = parse_with(CInt32())
    for shape in ("{1,2}", Int32[1, 2], Union{Missing, Int32}[1, 2], Any[Int32(1), Int32(2)], Int64[1, 2])
      r = p32(shape)
      @test r == Int32[1, 2] && r isa Vector{Int32}
    end
    @test p32("[0:1]={1,2}") == Int32[1, 2]
    r = p32("{1,NULL}")
    @test r isa Vector{Union{Missing, Int32}} && r[1] == 1 && ismissing(r[2])
    @test p32(Union{Missing, Int32}[1, missing]) isa Vector{Union{Missing, Int32}}
    # Fail-open.
    m = Int32[1 2; 3 4]
    @test p32(m) === m
    @test p32("{{1,2},{3,4}}") == "{{1,2},{3,4}}"
    @test p32("{x}") == "{x}"
    @test p32(missing) === missing && p32(nothing) === nothing
    @test p32(Any[[1], [2]]) == Any[[1], [2]]
    # The other element types.
    @test parse_with(CText())("{\"a b\",c}") == ["a b", "c"]
    @test parse_with(CVarChar(12))(["SOFT"]) == ["SOFT"]
    @test parse_with(CBool())("{t,f}") == [true, false]
    @test parse_with(CDate())("{2024-03-02}") == [Date(2024, 3, 2)]
    d = parse_with(CDecimal(7, 3))("{1.500,2}")
    @test d isa Vector{Decimals.Decimal} && d == [Decimals.Decimal(0, 15, -1), Decimals.Decimal(0, 2, 0)]
    @test parse_with(CDateTime(true))("{\"2024-03-02 12:00:00+00\"}") ==
          [ZonedDateTime(DateTime(2024, 3, 2, 12), tz"UTC")]
    @test parse_with(CUUID())("{550E8400-E29B-41D4-A716-446655440000}") == ["550e8400-e29b-41d4-a716-446655440000"]
    # The field's canonical kind carries the element, so `list()` and write-returning rows pick it up.
    @test PormG.field_canonical_kind(_AS.fields["pit_laps"]) == CArray(CInt32())
    @test PormG.field_canonical_kind(_AS.fields["targets"]) == CArray(CDecimal(7, 3))
    @test PormG.value_formatter(CArray(CInt32()), PG_ARR28)([1, 2]) == "{1,2}"
    # PostgreSQL only: SQLite has no array parser, as it has no array column.
    @test PormG.value_parser(CArray(CInt32()), SL_ARR28) === nothing
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DDL and the canonical column IR
  # The column is the element's type followed by `[]`, with no size. The drift guard: what the
  # compiler reads back from that rendered type is `CArray(array_element_kind(base))`, for every base
  # — so the element codec and the DDL cannot disagree silently.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DDL and canonical types" begin
    for (base, (kind, rendered)) in ARR28_BASES
      f = AF.ArrayField(base)
      @test Dialect._get_column_type(f, PG_ARR28) == rendered
      @test parse_canonical_type(Dialect._get_column_type(f, PG_ARR28), PG_ARR28) == CArray(AF.array_element_kind(base))
      @test column_spec(f, PG_ARR28; name = "c").type == CArray(kind)
    end
    # The catalog's spellings (`format_type`) read to the same kinds.
    @test parse_canonical_type("integer[]", PG_ARR28) == CArray(CInt32())
    @test parse_canonical_type("character varying(10)[]", PG_ARR28) == CArray(CVarChar(10))
    @test parse_canonical_type("numeric(7,3)[]", PG_ARR28) == CArray(CDecimal(7, 3))
    @test parse_canonical_type("timestamp with time zone[]", PG_ARR28) == CArray(CDateTime(true))
    @test parse_canonical_type("timestamp(6) without time zone[]", PG_ARR28) == CArray(CDateTime(false))
    @test parse_canonical_type("integer[3]", PG_ARR28) == CArray(CInt32())
    @test parse_canonical_type("integer[][]", PG_ARR28) == CArray(CInt32())
    # An element no ArrayField declares stays unsupported, like any spelling PormG never writes.
    for raw in ("smallint[]", "inet[]", "jsonb[]", "bytea[]", "interval[]")
      @test parse_canonical_type(raw, PG_ARR28) isa CUnsupported
    end
    # Equality and hashing are structural.
    @test CArray(CVarChar(10)) == CArray(CVarChar(10)) && hash(CArray(CVarChar(10))) == hash(CArray(CVarChar(10)))
    @test CArray(CVarChar(10)) != CArray(CVarChar(20))

    @test Dialect.field_to_column("pit_laps", _AS.fields["pit_laps"], PG_ARR28) ==
          "\"pit_laps\" integer[] NOT NULL DEFAULT '{}'"
    @test Dialect.field_to_column("targets", _AS.fields["targets"], PG_ARR28) ==
          "\"targets\" decimal(7, 3)[] NULL"
    # `size` is model-layer only: changing it is no schema delta; changing the element is a type one.
    a, b = AF.ArrayField(AF.IntegerField()), AF.ArrayField(AF.IntegerField(); size = 4)
    @test isempty(column_delta(b, a, PG_ARR28; name = "c"))
    @test isempty(column_delta(AF.ArrayField(AF.IntegerField(null = true)), a, PG_ARR28; name = "c"))
    @test :type in column_delta(AF.ArrayField(AF.BigIntegerField()), a, PG_ARR28; name = "c")
    @test :type in column_delta(AF.ArrayField(AF.CharField(max_length = 20)),
                                AF.ArrayField(AF.CharField(max_length = 10)), PG_ARR28; name = "c")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The SQLite refusal, at both sites
  # The column renderer refuses (#648's pattern), and so does the planner for any model that DECLARES
  # one: on SQLite the field compiles to `CText` (for the compiler alone), so re-declaring an existing
  # `TEXT` column as an ArrayField is an empty delta that renders no DDL — the hole the renderer alone
  # leaves open (#28's network-field review).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite refuses an ArrayField" begin
    e = _err_a28(() -> Dialect.field_to_column("pit_laps", AF.ArrayField(AF.IntegerField()), SL_ARR28))
    @test e isa PormG.BackendCapabilityError
    msg = _plain_a28(sprint(showerror, e))
    @test occursin("pit_laps", msg) && occursin("integer[]", msg) && occursin("PostgreSQL", msg)

    settings = PormG.Configuration.Settings()
    schema_for(m) = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
      Symbol(AF.model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => true))
    as_text = AF.Model("arr28_plan", id = AF.IDField(), pit_laps = AF.TextField())
    as_array = AF.Model("arr28_plan", id = AF.IDField(), pit_laps = AF.ArrayField(AF.IntegerField()))
    # The premise of the hole: to the SQLite compiler the two declarations are the same column.
    @test isempty(column_delta(AF.ArrayField(AF.IntegerField()), AF.TextField(), SL_ARR28; name = "pit_laps"))
    live = [Migrations.live_table(as_text, SL_ARR28)]
    e2 = _err_a28(() -> Migrations.get_migration_plan(live, schema_for(as_array), SL_ARR28, settings; interactive = false))
    @test e2 isa PormG.BackendCapabilityError
    @test e2 !== nothing && occursin("pit_laps", _plain_a28(sprint(showerror, e2)))
    @test_throws PormG.BackendCapabilityError Migrations.get_migration_plan(
      Migrations.LiveTable[], schema_for(as_array), SL_ARR28, settings; interactive = false)

    # A value reaching the SQLite binder (a table PormG did not create) is refused, never stored as text.
    params = PormG.QueryBuilder.get_parameter(SL_ARR28)
    @test_throws PormG.BackendCapabilityError PormG.QueryBuilder.add_parameter!(params, PormGArrayLiteral("{1}"))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Catalog defaults and inspectdb
  # A catalog default reads through `canonical_array_literal`, so the catalog's `{1.50}` meets a
  # declared `default = [1.5]` and `makemigrations` plans nothing. An array column used to be emitted
  # as a warned TextField; it is an ArrayField of the element's own field now.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "catalog defaults and inspectdb" begin
    declared = AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2); default = [1.5, 2])
    @test Migrations._coerce_default("{1.50,2.00}", CArray(CDecimal(5, 2))) == declared.default
    @test Migrations._coerce_default("{}", CArray(CInt32())) == "{}"
    @test Migrations._coerce_default("{\"a b\",c}", CArray(CVarChar(10))) == "{\"a b\",c}"
    @test_throws PormG.FieldValidationError Migrations._coerce_default("{x}", CArray(CInt32()))
    @test_throws PormG.FieldValidationError Migrations._coerce_default(3, CArray(CInt32()))

    for (base, (kind, _)) in ARR28_BASES
      spec = ColumnSpec("c", CArray(kind), true, false, false, NoDefault(), nothing,
                        Migrations.CheckKind[], nothing, "x[]")
      tbl = Migrations.LiveTable("t", Migrations.OrderedDict("c" => spec), Dict{String, Union{String, Nothing}}())
      # No "has no PormG field type" warning.
      f = @test_logs min_level = Logging.Warn Migrations.field_from_spec(spec, tbl, PG_ARR28)
      @test f isa AF.sArrayField && f.null
      # inspectdb round-trips: the declaration compiles back to the live kind.
      @test column_spec(f, PG_ARR28; name = "c").type == CArray(kind)
    end
    # A literal default comes along, canonical.
    spec = ColumnSpec("c", CArray(CInt32()), false, false, false, Migrations.LiteralDefault("{1,2}"), nothing,
                      Migrations.CheckKind[], nothing, "integer[]")
    tbl = Migrations.LiveTable("t", Migrations.OrderedDict("c" => spec), Dict{String, Union{String, Nothing}}())
    @test Migrations.field_from_spec(spec, tbl, PG_ARR28).default == "{1,2}"
    # A modifier-less element warns, as its scalar arm does.
    spec_v = ColumnSpec("c", CArray(CVarChar(nothing)), true, false, false, NoDefault(), nothing,
                        Migrations.CheckKind[], nothing, "character varying[]")
    tbl_v = Migrations.LiveTable("t", Migrations.OrderedDict("c" => spec_v), Dict{String, Union{String, Nothing}}())
    @test_logs (:warn, r"varchar without a length") Migrations.field_from_spec(spec_v, tbl_v, PG_ARR28)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Migration retypes on PostgreSQL
  # text → array casts the column (`USING CAST`), counted as `:text_cast`. An array whose elements
  # only widen is a plain ALTER with no finding; any other element change converts through text, so
  # the new element type's input function decides every value, and the rows it would refuse are
  # counted — the element's silent changes (a rounded scale, a dropped offset) still need the opt-in.
  # An array and a scalar other than text have no conversion: refused as planned.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "retypes" begin
    ia, ba, ta = AF.ArrayField(AF.IntegerField()), AF.ArrayField(AF.BigIntegerField()), AF.TextField()
    retype(declared, live) = Dialect.alter_field(PG_ARR28, "t", "c", declared,
                                                 column_delta(declared, live, PG_ARR28; name = "c"))
    kinds(declared, live) = [f.kind for f in _lossy_alters(column_delta(declared, live, PG_ARR28; name = "c"),
                                                           PG_ARR28; table = "t", column = "c")]

    @test occursin("TYPE integer[] USING CAST(\"c\" AS integer[]);", retype(ia, ta))
    @test kinds(ia, ta) == [:text_cast]
    f = only(_lossy_alters(column_delta(ia, ta, PG_ARR28; name = "c"), PG_ARR28; table = "t", column = "c"))
    sql, params = Migrations._precheck_sql(PG_ARR28, f)
    @test occursin("pg_input_is_valid(CAST(\"c\" AS text), \$1) IS FALSE", sql) && params == Any["integer[]"]

    # Into a modified element type the cast drops the modifier, so the ALTER's assignment applies it
    # and RAISES on an over-long element — an explicit cast to `varchar(3)` would truncate silently.
    c3 = AF.ArrayField(AF.CharField(max_length = 3))
    @test occursin("TYPE varchar(3)[] USING CAST(\"c\" AS varchar[]);", retype(c3, ta))
    @test occursin("TYPE varchar(3)[] USING CAST(CAST(\"c\" AS text) AS varchar[]);",
                   retype(c3, AF.ArrayField(AF.CharField(max_length = 10))))
    # Widening: plain ALTER, nothing to count.
    @test strip(retype(ba, ia)) == "ALTER TABLE \"t\" ALTER COLUMN \"c\" TYPE bigint[];"
    @test isempty(kinds(ba, ia))
    @test isempty(kinds(AF.ArrayField(AF.CharField(max_length = 20)), AF.ArrayField(AF.CharField(max_length = 10))))
    @test isempty(kinds(AF.ArrayField(AF.TextField()), AF.ArrayField(AF.CharField(max_length = 10))))
    # Narrowing or reinterpreting: through text, counted.
    @test occursin("TYPE integer[] USING CAST(CAST(\"c\" AS text) AS integer[]);", retype(ia, ba))
    @test kinds(ia, ba) == [:text_cast]
    @test kinds(AF.ArrayField(AF.CharField(max_length = 10)), AF.ArrayField(AF.CharField(max_length = 20))) == [:text_cast]
    @test kinds(AF.ArrayField(AF.IntegerField()), AF.ArrayField(AF.TextField())) == [:text_cast]
    d52 = AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 2))
    d51 = AF.ArrayField(AF.DecimalField(max_digits = 5, decimal_places = 1))
    @test kinds(d51, d52) == [:text_cast, :decimal_scale]
    @test kinds(AF.ArrayField(AF.DateTimeField(type = "TIMESTAMP")), AF.ArrayField(AF.DateTimeField())) ==
          [:text_cast, :drop_timezone]
    # Array → text keeps PostgreSQL's assignment cast (the literal), with the usual length count.
    @test !occursin("USING", retype(ta, ia)) && isempty(kinds(ta, ia))
    @test kinds(AF.CharField(max_length = 5), ia) == [:varchar_length]
    # No conversion between an array and a scalar other than text.
    @test kinds(AF.IntegerField(), ia) == [:no_implicit_cast]
    @test kinds(ia, AF.IntegerField()) == [:no_implicit_cast]
    @test !occursin("USING", retype(AF.IntegerField(), ia))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Model_to_str round trip and display
  # An ArrayField's constructor takes its element as a positional FIELD, so the generated source
  # renders it as its own constructor call and diffs the array's keywords against `ArrayField(base)`.
  # The REPL display shows the same call; the model card shows the element type with `[]`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Model_to_str round trip and display" begin
    src = Logging.with_logger(Logging.NullLogger()) do
      AF.Model_to_str(_AS)
    end
    @test !occursin("formatter", src) && !occursin("base_field", src)
    @test occursin("tyre_compounds = Models.ArrayField(Models.CharField(max_length=12), size=6)", src)
    @test occursin("pit_laps = Models.ArrayField(Models.IntegerField(null=true), default=\"{}\")", src)
    @test occursin("targets = Models.ArrayField(Models.DecimalField(max_digits=7, decimal_places=3), null=true)", src)
    sandbox = Module()
    Core.eval(sandbox, :(import PormG; import PormG.Models))
    reloaded = Core.eval(sandbox, Meta.parse(src))
    for name in ("tyre_compounds", "pit_laps", "targets")
      a, b = reloaded.fields[name], _AS.fields[name]
      @test a isa AF.sArrayField && a.size == b.size && a.default == b.default && a.null == b.null
      @test column_spec(a, PG_ARR28; name = name) == column_spec(b, PG_ARR28; name = name)
      @test a.base_field.null == b.base_field.null
    end

    @test sprint(show, _AS.fields["tyre_compounds"]) == "ArrayField(CharField(max_length=12), size=6)"
    @test sprint(show, AF.ArrayField(AF.IntegerField())) == "ArrayField(IntegerField())"
    card = sprint(show, MIME"text/plain"(), _AS)
    @test occursin("VARCHAR(12)[]", card) && occursin("INTEGER[]", card)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Write validation
  # Every writer validates a value before it binds: the shape (a one-dimensional vector or a tuple),
  # `size`, the element-NULL rule, and each element exactly as the base field validates a scalar —
  # naming the element in the message.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "write validation" begin
    ok(field, value) = validate_field_data(_AS, field, value, "insert")
    msg(field, value) = _msg_a28(() -> ok(field, value))
    @test ok("tyre_compounds", ["SOFT", "MEDIUM"]) && ok("tyre_compounds", ("HARD",)) && ok("tyre_compounds", String[])
    @test ok("pit_laps", [12, nothing, 30])                      # the base field is null = true
    @test ok("targets", nothing)                                 # the column is null = true
    @test occursin("max_length is 12", msg("tyre_compounds", ["INTERMEDIATE!"]))
    @test occursin("tyre_compounds[1]", msg("tyre_compounds", ["INTERMEDIATE!"]))
    @test occursin("at most 6 elements", msg("tyre_compounds", fill("SOFT", 7)))
    @test occursin("element 1 is null", msg("tyre_compounds", [nothing]))
    @test occursin("max_digits", msg("targets", [123456.0]))
    @test occursin("Int64 or an integer string", msg("pit_laps", [true]))
    @test occursin("one-dimensional", msg("pit_laps", [1 2; 3 4]))
    @test occursin("wrap a single element", msg("pit_laps", 3))
    @test occursin("one-dimensional array", msg("pit_laps", [[1], [2]]))
    @test_throws PormG.InvalidValueError ok("tyre_compounds", nothing)
    # The formatter is the same contract, for every caller that formats without validating first.
    fmt = _AS.fields["pit_laps"].formatter
    @test fmt([1, 2]) == PormGArrayLiteral("{1,2}") && fmt("{1,2}") == PormGArrayLiteral("{1,2}")
    @test fmt(missing) === missing && fmt(PormGArrayLiteral("{9}")) == PormGArrayLiteral("{9}")
    @test occursin("element 2 of the array", _msg_a28(() -> fmt([1, "x"])))
    @test_throws PormG.InvalidValueError _AS.fields["tyre_compounds"].formatter(["a", 1.5])
    @test_throws PormG.InvalidValueError AF.ArrayField(AF.BooleanField()).formatter(["t"])

    # A single-row insert binds one literal per array, and fills an omitted array from its default.
    d = _AS.objects.create("team" => "Ferrari", "tyre_compounds" => ["SOFT", "a b"], show_query = :dict)
    @test "{SOFT,\"a b\"}" in d[:parameters] && "{}" in d[:parameters]
    @test !any(p -> p isa AbstractVector, d[:parameters])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Filters
  # A bare-path vector is an equality against the whole array — bound as ONE literal, never expanded
  # into a membership list. `@isnull` is unchanged. Three refusals, each typed and naming the path:
  # a vector on any other column, a pattern lookup on an array, and a membership list of arrays.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "filters" begin
    q = _AS.objects.filter("tyre_compounds" => ["SOFT", "MEDIUM"])
    q.values("id")
    res = q.list(show_query = :dict)
    @test occursin("\"tyre_compounds\" = \$1", res[:sql_text]) && res[:parameters] == ["{SOFT,MEDIUM}"]
    # The empty array and a Q() node reach the same render.
    q0 = _AS.objects.filter("pit_laps" => Int[]); q0.values("id")
    @test q0.list(show_query = :dict)[:parameters] == ["{}"]
    qq = _AS.objects.filter(PormG.Q("pit_laps" => [12, 30])); qq.values("id")
    @test qq.list(show_query = :dict)[:parameters] == ["{12,30}"]
    qn = _AS.objects.filter("targets__@isnull" => true); qn.values("id")
    @test occursin("\"targets\" IS NULL", qn.list(show_query = :dict)[:sql_text])
    # An element the base field refuses is an InvalidValueError, like any bad filter value (#971).
    qb = _AS.objects.filter("pit_laps" => ["x"]); qb.values("id")
    @test_throws PormG.InvalidValueError qb.list(show_query = :dict)

    # A vector on a column that holds one value: the message the parse ladder always gave.
    qt = _AS.objects.filter("team" => ["Ferrari", "Mercedes"]); qt.values("id")
    @test_throws PormG.FilterError qt.list(show_query = :dict)
    @test occursin("was given a vector value but no operator", _msg_a28(() -> qt.list(show_query = :dict)))
    # A path ending in an operator name is a typo for `__@…`, and keeps that message at `filter()`.
    @test occursin("was given a vector value but no operator",
                   _msg_a28(() -> _AS.objects.filter("team__in" => ["Ferrari"])))
    # A `nothing` element in a filter value: named, with the `missing` spelling.
    @test occursin("`missing`", _msg_a28(() -> _AS.objects.filter("tyre_compounds" => ["SOFT", nothing])))
    # A pattern lookup on an array names the containment lookup instead of matching text.
    qc = _AS.objects.filter("tyre_compounds__@contains" => "SOFT"); qc.values("id")
    m = _msg_a28(() -> qc.list(show_query = :dict))
    @test _err_a28(() -> qc.list(show_query = :dict)) isa PormG.FilterError
    @test occursin("@acontains", m) && occursin("tyre_compounds", m)
    # A membership list of whole arrays.
    e = _err_a28(() -> _AS.objects.filter("pit_laps__@in" => [[1], [2, 3]]))
    @test e isa PormG.FilterError && occursin("Qor(", _plain_a28(sprint(showerror, e)))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Bulk writers on PostgreSQL
  # A column of arrays cannot be one `int[][]` parameter (rows of different lengths are not one
  # array, and `unnest` flattens every dimension), so each cell travels as its literal's text in a
  # `text[]` and is cast back where the row is read. A table with no array column keeps the
  # `SELECT *` statement every other bulk insert renders.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "bulk writers" begin
    df = DataFrames.DataFrame(id = [1, 2], team = ["Ferrari", "McLaren"],
                              tyre_compounds = [["SOFT", "HARD"], String[]],
                              pit_laps = [[12, 30], [18]], targets = [nothing, [81.5]])
    ins = bulk_insert(_AS.objects, df, show_query = :dict)
    @test ins[:sql_text] ==
      "INSERT INTO \"race_strategy\" (\"id\", \"team\", \"tyre_compounds\", \"pit_laps\", \"targets\")\n" *
      "SELECT \"u\".\"c1\", \"u\".\"c2\", \"u\".\"c3\"::varchar[], \"u\".\"c4\"::integer[], \"u\".\"c5\"::decimal[] " *
      "FROM unnest(\$1::bigint[], \$2::varchar[], \$3::text[], \$4::text[], \$5::text[]) AS \"u\"(\"c1\", \"c2\", \"c3\", \"c4\", \"c5\")\n"
    @test isequal(ins[:parameters][3:5], Any[Any["{SOFT,HARD}", "{}"], Any["{12,30}", "{18}"], Any[missing, "{81.5}"]])

    upd = bulk_update(_AS.objects, df[:, [:id, :pit_laps]], columns = ["pit_laps"], match_on = ["id"], show_query = :dict)
    @test occursin("SET \"pit_laps\" = source.\"pit_laps\"::integer[]", upd[:sql_text])
    @test occursin("unnest(\$1::text[], \$2::bigint[])", upd[:sql_text])
    @test occursin("ArrayField", _msg_a28(() -> bulk_update(_AS.objects, df[:, [:id, :pit_laps]],
                                                            columns = ["id"], match_on = ["pit_laps"], show_query = :dict)))
    @test occursin("ArrayField", _msg_a28(() -> bulk_insert(_AS.objects, df, show_query = :dict, returning = ["id"],
                                                            on_conflict = (action = :nothing, target = ["pit_laps"]))))
    # A bad element refuses the row, naming it.
    bad = DataFrames.DataFrame(id = [1], team = ["Ferrari"], tyre_compounds = [["INTERMEDIATE!"]], pit_laps = [[1]], targets = [nothing])
    @test_throws PormG.InvalidValueError bulk_insert(_AS.objects, bad, show_query = :dict)
    # COPY writes each array as its literal.
    @test PormG.QueryBuilder._bulk_copy_cell(PormGArrayLiteral("{\"a b\",c}")) == "{\"a b\",c}"
    # An omitted array column is filled from its default, as a single-row insert fills it.
    filled = bulk_insert(_AS.objects, df[:, [:id, :team, :tyre_compounds]], show_query = :dict)
    @test occursin("\"u\".\"c4\"::integer[]", filled[:sql_text]) && filled[:parameters][4] == Any["{}", "{}"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The Django importer decides an ArrayField by its element (#943)
  # #28 pinned the opposite here — ArrayField on #410's report-and-skip path, because the importer
  # could not read a positional element. #943 reads it, so the TYPE is buildable and the element is
  # what is judged, against the same `array_element_kind` table `ArrayField` refuses from. The
  # end-to-end import is covered in `test_import_django_models.jl`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the Django importer judges an ArrayField by its element" begin
    @test Migrations._is_pormg_field_type("ArrayField")
    @test Migrations._is_pormg_field_type("CharField")
    for t in ("CharField", "TextField", "IntegerField", "DecimalField", "DateTimeField", "UUIDField")
      call, reason = Migrations._array_element_support("models.$t()")
      @test reason === nothing && call.type == t
    end
    # No `array_element_kind` method, a relation, a nested array, a type PormG lacks, no call.
    for el in ("models.JSONField()", "models.PositiveIntegerField()", "models.ForeignKey(Driver)",
               "ArrayField(models.IntegerField())", "models.SmallIntegerField()", "TAG_FIELD")
      call, reason = Migrations._array_element_support(el)
      @test call === nothing && occursin("ArrayField", reason)
    end
    @test Migrations._array_element_support(nothing)[2] ==
          "an ArrayField with no element field the importer can find"
    # The element is the first POSITIONAL argument — not split at its own inner `=` — or `base_field=`.
    @test Migrations._split_array_element("models.CharField(max_length=10), size=8, null=True") ==
          ("models.CharField(max_length=10)", "size=8, null=True")
    @test Migrations._split_array_element("base_field=models.IntegerField(null=True), default=list") ==
          ("models.IntegerField(null=True)", "default=list")
    @test Migrations._split_array_element("null=True") == (nothing, "null=True")
    # Django's second positional slot is `size`; it is re-spelled as the keyword, not dropped.
    @test Migrations._split_array_element("models.IntegerField(), 20, null=True") ==
          ("models.IntegerField()", "size=20, null=True")
    # A star argument fills no positional slot — it is neither the element nor `size`.
    @test Migrations._split_array_element("models.IntegerField(), **OPTS") ==
          ("models.IntegerField()", "**OPTS")
    @test Migrations._split_array_element("*EXTRA, size=4") == (nothing, "*EXTRA, size=4")
    # Every spelling of Django's empty-list default is the empty array, stored as `{}`.
    for d in ("list", "list()", "[]")
      @test Migrations.parse_field_args("default=$d", "ArrayField", String[])[1][:default] == Any[]
      @test AF.ArrayField(AF.IntegerField(); default = Migrations.parse_field_args("default=$d", "ArrayField", String[])[1][:default]).default == "{}"
    end
  end
end
