# ============================================================
# test/unit/test_validate_value.jl
#
# `validate_value(model, field, value)` refuses exactly what a write refuses (#1239).
#
# CONTRACT being tested:
#   `validate_value` runs the write path's per-field checks and nothing else, in its order:
#   `validate_field_data` (the field name, NULL, type, range, `max_length`, a decimal's width), then
#   `_format_single` (the bind-time formatter, a collection where a column holds one value, a NUL in
#   text), then the parameter bind of the engine the model is bound to (an integer wider than 64 bits,
#   an `ArrayField` value on SQLite). For every value in the table below, on both engines, it agrees
#   with `create(field => value)`: the same error type, `kind`, field and reason when the write
#   refuses, and — once the engine's parameter encoding is applied — the value the write binds when it
#   accepts. A test double built on it cannot drift from PormG's rules, because there is no second
#   copy of them.
#
# Hermetic: each write runs on a `register_offline` key (one PostgreSQL, one SQLite) with
# `show_query = :params`, which builds the INSERT and returns its bound parameters without sending
# anything. Every field except `code` is nullable, so a one-field row is a complete row and only the
# field under test can refuse.
# ============================================================

using Test
using PormG
using Dates, UUIDs

const KEYS_1239 = (postgres = "pormg1239_offline_pg", sqlite = "pormg1239_offline_sl")
PormG.Configuration.register_offline(KEYS_1239.postgres; adapter = :postgres)
PormG.Configuration.register_offline(KEYS_1239.sqlite; adapter = :sqlite)

# The same F1 models, bound once per engine.
for (engine, key) in pairs(KEYS_1239)
  modname = Symbol("F1Models1239_", engine)
  @eval module $modname
    import PormG
    import PormG.Models as Mo
    Driver = Mo.Model("driver", driverid = Mo.IDField(), surname = Mo.CharField(max_length = 30))
    Result = Mo.Model("result",
      resultid = Mo.IDField(),
      code = Mo.CharField(max_length = 3),                                  # the one NOT NULL column
      surname = Mo.CharField(max_length = 10, null = true),
      notes = Mo.TextField(null = true),
      grid = Mo.IntegerField(null = true),
      laps = Mo.PositiveSmallIntegerField(null = true),
      milliseconds = Mo.BigIntegerField(null = true),
      points = Mo.FloatField(null = true),
      fastestlapspeed = Mo.DecimalField(max_digits = 6, decimal_places = 3, null = true),
      finished = Mo.BooleanField(null = true),
      dob = Mo.DateField(null = true),
      updated = Mo.DateTimeField(null = true),
      fastestlaptime = Mo.TimeField(null = true),
      stint = Mo.DurationField(null = true),
      uid = Mo.UUIDField(null = true),
      meta = Mo.JSONField(null = true),
      photo = Mo.BinaryField(max_length = 4, null = true),
      lapsled = Mo.ArrayField(Mo.IntegerField(), null = true),
      driverid = Mo.ForeignKey(Driver, null = true),
      teammates = Mo.ManyToManyField(Driver, related_name = "teammate_results"),
      search = Mo.SearchVectorField(generated_from = ("notes",), config = "english", null = true))
    PormG.Models.set_models(@__MODULE__, $key)
  end
end
const RESULTS_1239 = (postgres = F1Models1239_postgres.Result, sqlite = F1Models1239_sqlite.Result)

# The row `create` writes for one field: `code` rides along so the row is complete, except when
# `code` is the field under test.
_row_1239(field, value) = field == "code" ? (field => value,) : ("code" => "SEN", field => value)

# What `create` does with the value: `(:ok, bound value)` or `(:refused, error)`.
function _write_outcome_1239(model, field, value)
  params = try
    model.objects.create(_row_1239(field, value)...; show_query = :params)
  catch e
    return (:refused, e)
  end
  field == "code" && return (:ok, only(params))
  rest = filter(p -> !isequal(p, "SEN"), params)   # drop `code`'s parameter, keep the field's
  return (:ok, only(rest))
end

function _check_outcome_1239(model, field, value)
  try
    return (:ok, validate_value(model, field, value))
  catch e
    return (:refused, e)
  end
end

# `validate_value` returns the engine-neutral formatted value; the parameter bucket then applies the
# engine's own encoding (a `PormGBytes` becomes PostgreSQL's `\\x…` text, an array literal its text),
# exactly as it does for `create`. Encode through the same bucket to compare what is bound.
function _bound_1239(key, formatted)
  pool = PormG.Configuration.get_settings(key).connections
  bucket = PormG.QueryBuilder.get_parameter(pool)
  PormG.QueryBuilder.add_parameter!(bucket, formatted)
  return only(bucket.parameters)
end

# The parts of a refusal a test double must reproduce: its type, and for a value refusal its kind,
# field and reason (the text minus the operation, which names the caller).
_as_insert_1239(text) = replace(text, "validate_value" => "insert")
_shape_1239(e::PormG.InvalidValueError) = (typeof(e), e.kind, e.field, _as_insert_1239(e.reason))
_shape_1239(e) = (typeof(e), _as_insert_1239(PormG.error_message(e)))

# (field, value, what the write does). The expectation column keeps the table honest: a row that
# stopped refusing on BOTH sides would still "agree", so each row also states which way it goes —
# per engine, as `(postgres = …, sqlite = …)`, where the engines' binds differ.
const TABLE_1239 = [
  # text: NOT NULL, max_length, NUL, collection
  ("code", "SEN", :ok),
  ("code", nothing, :refused),
  ("code", "SENNA", :refused),
  ("code", "S\0N", :refused),
  ("code", ["S", "E", "N"], :refused),
  ("surname", "Senna", :ok),
  ("surname", nothing, :ok),
  ("surname", 1991, :ok),                        # an integer is written as its text (#860)
  ("surname", "Fittipaldi Jr", :refused),        # 13 > max_length 10
  ("notes", "pole\0position", :refused),
  ("notes", ("wet", "dry"), :refused),
  # integers: type and range
  ("grid", 1, :ok),
  ("grid", 1.5, :refused),
  ("grid", "pole", :refused),
  ("grid", big(2)^70, (postgres = :ok, sqlite = :refused)),          # SQLite binds 64 bits at most
  ("laps", 58, :ok),
  ("laps", -1, :ok),                             # the sign is the column's CHECK: the database's, not a write check
  ("milliseconds", 5_000_000_000, :ok),
  ("milliseconds", Int128(2)^70, (postgres = :ok, sqlite = :refused)),
  # float, decimal width
  ("points", 25, :ok),
  ("points", "ten", :refused),
  ("fastestlapspeed", "218.300", :ok),
  ("fastestlapspeed", 1234.5, :refused),         # 4 whole digits > 6 - 3
  ("fastestlapspeed", "1.23456", :refused),      # 5 fractional digits > 3
  ("finished", true, :ok),
  # temporal
  ("dob", Date(1960, 3, 21), :ok),
  ("dob", "1960-03-21", :ok),
  ("dob", "1960-13-40", :refused),
  ("updated", DateTime(2024, 3, 2, 15, 0), :ok),
  ("updated", "after the race", :refused),
  ("fastestlaptime", Time(0, 1, 27), :ok),
  ("fastestlaptime", "a lap", :refused),
  ("stint", Second(90), :ok),
  # uuid, json, binary, array, foreign key
  ("uid", UUID("550e8400-e29b-41d4-a716-446655440000"), :ok),
  ("uid", "not-a-uuid", :refused),
  ("meta", Dict("tyre" => "soft"), :ok),
  ("meta", Dict("tyre" => "so\0ft"), :refused),
  ("photo", UInt8[1, 2, 3], :ok),
  ("photo", UInt8[1, 2, 3, 4, 5], :refused),     # 5 bytes > max_length 4
  ("lapsled", [1, 2, 3], (postgres = :ok, sqlite = :refused)),       # no array column on SQLite
  ("lapsled", [1, "two"], :refused),
  ("driverid", 1, :ok),
  ("driverid", "senna", :refused),
  # names that are not writable columns, and the primary key
  ("constructor", 1, :refused),                  # no such field: UnknownFieldError
  ("teammates", [1, 2], :refused),               # a many-to-many relation is not a column
  ("search", "pole", :refused),                  # a generated column is never written
  ("resultid", 7, :ok),                          # create may set a primary key
  # an expression is not a value: create refuses it (update writes it as SQL, and a double's
  # update passes it through without calling validate_value)
  ("surname", F("forename"), :refused),
  ("notes", PormG.Functions.Upper("surname"), :refused),
]

_expected_1239(e::Symbol, engine) = e
_expected_1239(e::NamedTuple, engine) = e[engine]

# What: every (field, value) row above, through `validate_value` and through `create` on an offline
#   key, on PostgreSQL and on SQLite. Expected: both accept, binding the same value, or both refuse
#   with the same error type, kind, field and reason; and the outcome is the one the row states.
# Why: a test double built on `validate_value` is only worth having if it refuses what PormG refuses.
#   #951's NUL refusal is the kind of rule a double would otherwise copy by hand; this pins the one
#   shared source, across every field type and both engines' binds, so the next refusal cannot reach
#   the write path alone.
@testset "validate_value agrees with create, per field type and engine (#1239)" begin
  for engine in keys(KEYS_1239), (field, value, expected) in TABLE_1239
    model, key = RESULTS_1239[engine], KEYS_1239[engine]
    @testset "$engine: $field => $(repr(value))" begin
      wrote, got = _write_outcome_1239(model, field, value), _check_outcome_1239(model, field, value)
      @test wrote[1] === _expected_1239(expected, engine)
      @test got[1] === wrote[1]
      if wrote[1] === :ok && got[1] === :ok
        @test isequal(_bound_1239(key, got[2]), wrote[2])
      elseif wrote[1] === :refused && got[1] === :refused
        @test wrote[2] isa PormG.PormGError
        @test _shape_1239(got[2]) == _shape_1239(wrote[2])
      end
    end
  end
end

# What: the refusals carry the field and the kind a double can branch on, and the error names the
#   field without printing the value. Expected: a NUL is kind `:nul` on `code`; a collection is
#   `:type`; an unknown name is `UnknownFieldError`; the return value is the formatted one.
# Why: a caller reports these as typed data (#971); a message that quoted the value would leak it,
#   and a double must raise the same type.
@testset "validate_value's refusals are typed and name the field, never the value (#1239)" begin
  R = RESULTS_1239.postgres
  e = try validate_value(R, "code", "S\0N"); nothing catch err; err end
  @test e isa PormG.InvalidValueError && e.kind === :nul && e.field == "code"
  @test e.op == "validate_value"
  e = try validate_value(R, "notes", ["Interlagos"]); nothing catch err; err end
  @test e isa PormG.InvalidValueError && e.kind === :type && e.field == "notes"
  e = try validate_value(R, "surname", "Fittipaldi Jr"); nothing catch err; err end
  @test e isa PormG.InvalidValueError && !occursin("Fittipaldi", PormG.error_message(e))
  @test_throws PormG.UnknownFieldError validate_value(R, "constructor", 1)
  # It returns the formatted value: an integer for a text column is its text (#860), a date its ISO text.
  @test validate_value(R, "surname", 1991) == "1991"
  @test validate_value(R, "dob", Date(1960, 3, 21)) == "1960-03-21"
  @test validate_value(R, SubString("grid_", 1, 4), 3) == 3   # any AbstractString names the field
end

# The offline keys are this file's alone: leave the registry as the suite found it.
foreach(PormG.Configuration.unregister_connection, values(KEYS_1239))
