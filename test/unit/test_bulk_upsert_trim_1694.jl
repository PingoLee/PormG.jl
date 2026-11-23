# ============================================================
# test/unit/test_bulk_upsert_trim_1694.jl
#
# CONTRACT being tested:
#   The paths retyped so a trimmed binary runs `bulk_insert(…; on_conflict = …)` (#1694, #1599 layer 7) and so the
#   SELECT render's `build` call infers under every Julia release (#1599 layer 5) answer what the code they replace
#   answered:
#     - `_blank_primary_key_mask` is `map(_is_blank_bulk_primary_key_value, column)` for every column type;
#     - `_is_blank_bulk_primary_key_value`'s `String` arm gives the generic answer;
#     - `_bulk_column_holds_value` is `any(v -> !(v === nothing || ismissing(v)), column)`;
#     - `_can_conflict`'s loops are `any(minted, …)` / `all(holds, …)`, in the same order;
#     - `_sqlite_sequence_value` is the expression it replaces, a raise included;
#     - the SELECT render's assertion on `build`'s answer (`::InstructionObject`) holds for every query shape, with and
#       without CTEs, on every engine;
#     - MySQL's frame conflict predicates answer as their closures did.
#   The old expressions are written out here as the oracle.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_bulk_upsert_trim_1694.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.QueryBuilder: F, Count
using Dates: Date
using Decimals: Decimal
using UUIDs: UUID

const _BUP_QB = PormG.QueryBuilder

struct BupMockSQLite <: PormG.PormGSQLite end
struct BupMockPostgres <: PormG.PormGPostgres end
struct BupMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::BupMockSQLite) = 3045000
PormG.config["bup_mock"] = PormG.Configuration.Settings(connections = BupMockSQLite(), change_data = true,
                                                        db_def_folder = "bup_mock")

module BupModels
import PormG
import PormG.Models
Bup_circuit::Models.ModelType = Models.Model("bup_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
)
Bup_race::Models.ModelType = Models.Model("bup_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  circuitid = Models.ForeignKey("Bup_circuit", pk_field = "circuitid"),
  name      = Models.CharField(max_length = 80),
)
Models.@models Bup_circuit Bup_race
PormG.Models.set_models(@__MODULE__, "bup_mock")
end
const _BUP_RACE = BupModels.Bup_race

# Run `f`, and name what it raised, so an oracle and its replacement are compared on refusals as well as values.
_bup_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# The old expressions, as they were before this change.
_bup_old_blank(value) = (value === nothing || ismissing(value)) ? true : (value isa AbstractString && isempty(strip(value)))
_bup_old_holds(column) = any(v -> !(v === nothing || ismissing(v)), column)
_bup_old_can_conflict(key, holds, minted) = key.kind === :text ? true : (any(minted, key.fields) ? false : all(holds, key.fields))
_bup_old_sequence_value(max_id) = max_id isa Real ? floor(Int64, max_id) : tryparse(Int64, string(max_id))

# Columns a frame can hold: every arm of the typed walks, a column with no arm, and a non-`Vector` one.
_bup_columns() = AbstractVector[
  Int64[1, 2], Int32[3], String["a", " ", ""], UUID[UUID(1)], Any[1, nothing, "  ", missing, "x"], Nothing[nothing],
  Missing[missing], Union{Missing, Int64}[missing, 4], Union{Nothing, Int64}[nothing, nothing],
  Union{Missing, String}["", missing], Union{Nothing, String}[nothing, "y"], Union{Missing, UUID}[missing],
  Float64[1.5], Bool[true], [Date(2008, 5, 25)], Decimal[Decimal(1)], view(Any[nothing, 2, missing], 1:3), 1:3,
  Int64[], Any[], SubString{String}[SubString(" a ", 2, 2), SubString("  ", 1, 2)]]

# What: the blank-key mask and its value test against the `map` and the generic test they replace.
# Expected: the same Bool for every cell of every column type, the arms' and the open arm's alike.
# Why: a primary-key column in a `bulk_insert` frame took `map` over the frame's `AbstractVector`, a dynamic call the
#   trimmed upsert stopped at (#1694); the typed mask must leave the same columns out and refuse the same mixes.
@testset "the blank-key mask answers as map did (#1694, #1599 layer 7)" begin
  for column in _bup_columns()
    @test (typeof(column), _BUP_QB._blank_primary_key_mask(column)) == (typeof(column), collect(Bool, map(_bup_old_blank, column)))
  end
  for value in Any[nothing, missing, "", " ", "\t", "x", SubString("  ", 1, 1), SubString("ab", 1, 1), 0, 1.0, UUID(1), :s]
    @test isequal((value, _BUP_QB._is_blank_bulk_primary_key_value(value)), (value, _bup_old_blank(value)))
  end
end

# What: whether a frame column holds a value, against the `any` it replaces; `_can_conflict`'s loops against
#   `any`/`all`, with the calls each makes recorded in order.
# Expected: the same answers, and the same predicate calls in the same order (both short-circuit where they did).
# Why: MySQL's upsert reads a frame's conflict keys before any SQL (#1267); the trimmed MySQL binary reaches these.
@testset "the upsert's conflict reading answers as before (#1694, #1599 layer 7)" begin
  for column in _bup_columns()
    @test (typeof(column), _BUP_QB._bulk_column_holds_value(column)) == (typeof(column), _bup_old_holds(column))
  end
  keys = [(fields = ["a"], kind = :pk), (fields = ["a", "b"], kind = :constraint), (fields = ["c"], kind = :text),
          (fields = String[], kind = :field), (fields = ["b", "a"], kind = :constraint)]
  readings = [(Set(["a"]), Set{String}()), (Set(["a", "b"]), Set(["b"])), (Set{String}(), Set(["a"])), (Set(["b"]), Set{String}())]
  for key in keys, (held, mint) in readings
    calls_new = String[]; calls_old = String[]
    holds_new = n -> (push!(calls_new, "h" * n); n in held); minted_new = n -> (push!(calls_new, "m" * n); n in mint)
    holds_old = n -> (push!(calls_old, "h" * n); n in held); minted_old = n -> (push!(calls_old, "m" * n); n in mint)
    @test (key, held, mint, _BUP_QB._can_conflict(key, holds_new, minted_new), calls_new) ==
          (key, held, mint, _bup_old_can_conflict(key, holds_old, minted_old), calls_old)
  end
end

# What: the SQLite sequence resync's reading of `MAX(pk)` against the expression it replaces.
# Expected: the same value, `nothing` or raise for an integer, a float (integral, fractional, out of range), text,
#   a narrower integer, a `Decimal`, a `Bool` and a `BigInt`.
# Why: the cell now arrives through a typed one-cell read (`_sqlite_one_cell_decoder`) as `Any`; a key the database
#   did not create can hold any of these, and the resync must skip or set the counter exactly as it did.
@testset "the SQLite sequence cells are read as before (#1694, #1599 layer 7)" begin
  for v in Any[Int64(5), 5.0, 5.7, -2.5, 1e30, "5", "5.0", "x", Int32(7), Decimal(3), Decimal(3.5), true, big(9)]
    @test (v, _bup_outcome(() -> _BUP_QB._sqlite_sequence_value(v))) == (v, _bup_outcome(() -> _bup_old_sequence_value(v)))
  end
  # The one-cell rows keep the driver's cell as it is: `Any` is the field type, so a NULL stays `missing`.
  for T in (_BUP_QB._SQLitePresentRow, _BUP_QB._SQLiteMaxRow)
    @test fieldtypes(T) == (Any,)
  end
  @test _BUP_QB._typed_value(Any, missing, :m, 1, _BUP_QB._TypedReadSite("t", "m")) === missing
  @test _BUP_QB._typed_value(Any, 7.0, :m, 1, _BUP_QB._TypedReadSite("t", "m")) === 7.0
end

# What: the SELECT render's assertion on `build`'s answer, for reads with and without CTEs, a subquery, a window and a
#   join, on every engine.
# Expected: each renders, so `build` answered an `InstructionObject` every time.
# Why: `_render_select` now asserts it (#1599 layer 5, for Julia 1.13.4's inference of the call); an answer of another
#   type would raise a `TypeError` where the render used to carry on. The SQL is checked against the code before the
#   change by a base-against-branch render (the PR), not here.
@testset "the render's build call answers an InstructionObject (#1599 layer 5)" begin
  sources = [
    () -> _BUP_RACE.objects.filter("year__@gte" => 2008).values("raceid", "name").order_by("-year"),
    () -> _BUP_RACE.objects.filter("circuitid__name" => "Monaco").values("year", "circuitid__name"),
    () -> _BUP_RACE.objects.with("st" => _BUP_RACE.objects.values("circuitid", "n" => Count("raceid")),
                                 join_field = "circuitid" => "circuitid").values("name", "st__n").filter("round" => F("year") - 2000),
    () -> _BUP_RACE.objects.filter("circuitid__@in" => BupModels.Bup_circuit.objects.filter("name" => "Monaco").values("circuitid")).values("name"),
  ]
  for conn in (BupMockSQLite(), BupMockPostgres(), BupMockMySQL()), mk in sources
    rendered = _BUP_QB._render_select(mk(); connection = conn)
    @test (typeof(conn), rendered.instruction isa _BUP_QB.InstructionObject, rendered.sql isa String) == (typeof(conn), true, true)
  end
end

# What: MySQL's frame conflict predicates (`_frame_conflict_reading`) against the closures they replace, over a frame
#   whose columns are set, partly NULL or all NULL, a field left out, and a column PormG fills itself.
# Expected: the same answer from each predicate for every field of the model.
# Why: they now read the column and the field at their types (#1599 layer 7); the reading decides whether MySQL's
#   upsert is refused before any SQL (#1267), so a different answer changes which calls raise.
@testset "the frame's conflict predicates answer as their closures did (#1694, #1599 layer 7)" begin
  model = _BUP_RACE
  fill_col = string(_BUP_QB._BULK_FILL_PREFIX, "name")
  columns = Dict{String, AbstractVector}("raceid" => Union{Missing, Int64}[missing, missing], "year" => Int64[2008, 2009],
                                          "round" => Any[nothing, nothing], fill_col => String["a", "b"])
  df = _BUP_QB._BulkFrame(collect(keys(columns)), columns, 2)
  mapping = Dict("raceid" => "raceid", "year" => "year", "round" => "round", "name" => fill_col)
  for fields_df in (["raceid", "year", "round", "name"], ["year"], ["raceid", "name"], String[])
    holds, minted = _BUP_QB._frame_conflict_reading(model, fields_df, mapping, df)
    inserted = Set(fields_df)
    holds_old = name -> name in inserted ? any(v -> !(v === nothing || ismissing(v)), _BUP_QB._bulk_column(df, mapping[name])) :
                                           _BUP_QB._has_db_default(model.fields[name])
    minted_old = name -> _BUP_QB._is_minted_value(model.fields[name]) &&
                         (!(name in inserted) || _BUP_QB._is_injected_fill_column(mapping[name]))
    for name in model.field_names
      name in keys(mapping) || continue
      @test (fields_df, name, holds(name), minted(name)) == (fields_df, name, holds_old(name), minted_old(name))
    end
  end
end
