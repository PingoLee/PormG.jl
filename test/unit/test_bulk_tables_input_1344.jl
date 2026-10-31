"""
The bulk writers take any Tables.jl table (#1344 phase 3).

`bulk_insert`, `bulk_update`, `bulk_copy` and `allocate_primary_keys` used to accept only a
`DataFrames.DataFrame`. They now take any Tables.jl table — a `DataFrame`, a `Vector` of
`NamedTuple`s, a `NamedTuple` of vectors, a `CSV.File` — and convert it once, in `_bulk_frame`, into
PormG's own working frame (`_BulkFrame`). Nothing past that point names the caller's table type.

What this file pins:
1. **Source parity.** The same rows as a `DataFrame`, a row table, a column table and a `CSV.File`
   render the same SQL and bind the same parameters, for every writer on every engine. That is what
   "converted once" means: the source type cannot reach the statement.
2. **Zero copy (#132).** A `DataFrame`'s column vectors reach the frame uncopied, and no writer
   changes the caller's table, a row table included.
3. **Refusals.** An argument that is not a table, to a writer or to its curried form, raises
   `QueryBuildError`, not a `MethodError`; so do columns of different lengths.
4. **`allocate_primary_keys` (#1344 decision 3)** returns a new table of the caller's own kind, with
   columns independent of the caller's, and has no `clone` keyword.

Hermetic: mock connections, `show_query` dry runs, no database.

julia --project=test/integration test/unit/test_bulk_tables_input_1344.jl
"""

using Test
using PormG
using PormG.QueryBuilder: bulk_copy, bulk_insert, bulk_update, allocate_primary_keys
import DataFrames
import Dates: Date

const _BT_QB = PormG.QueryBuilder
const _BT_Tables = _BT_QB.Tables
const _BT_CSV = _BT_QB.CSV

struct BtMockPostgres <: PormG.PormGPostgres end
struct BtMockSQLite <: PormG.PormGSQLite end
struct BtMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::BtMockSQLite) = 3045000   # the capability table's version rows ask for it

for (key, conn) in (("bt_pg", BtMockPostgres()), ("bt_sl", BtMockSQLite()), ("bt_my", BtMockMySQL()))
  PormG.config[key] = PormG.Configuration.Settings(connections = conn, change_data = true, db_def_folder = key)
end

# The F1 subset these shapes name (`test/integration/db_2/models.jl`), once per engine.
for (modname, key) in ((:BtPGModels, "bt_pg"), (:BtSLModels, "bt_sl"), (:BtMyModels, "bt_my"))
  @eval module $modname
  import PormG
  import PormG.Models
  Driver = Models.Model(
    driverid = Models.IDField(),
    forename = Models.CharField(),
    surname = Models.CharField(),
    number = Models.IntegerField(null = true),
    dob = Models.DateField(),
  )
  Result = Models.Model(
    resultid = Models.IDField(),
    driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "RESTRICT"),
    position = Models.IntegerField(null = true),
    laps = Models.IntegerField(),
    updated_at = Models.DateTimeField(auto_now = true, null = true),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

# A row source that can be read once and has no schema, as a database cursor is (`SQLite.Query` from
# `DBInterface.execute`): a second pass finds it exhausted.
mutable struct BtOnceRows
  rows::Vector{Any}
  read::Bool
end
_BT_Tables_mod = PormG.QueryBuilder.Tables
_BT_Tables_mod.istable(::Type{BtOnceRows}) = true
_BT_Tables_mod.rowaccess(::Type{BtOnceRows}) = true
_BT_Tables_mod.rows(x::BtOnceRows) = x
function Base.iterate(x::BtOnceRows, i = 1)
  i == 1 && (x.read && return nothing; x.read = true)
  return i > length(x.rows) ? nothing : (x.rows[i], i + 1)
end
Base.IteratorSize(::Type{BtOnceRows}) = Base.SizeUnknown()

# A PostgreSQL whose key has no sequence: `nextval(pg_get_serial_sequence(…))` is `nextval(NULL)`.
struct BtNoSequencePg <: PormG.PormGPostgres end
PormG.config["bt_noseq"] = PormG.Configuration.Settings(connections = BtNoSequencePg(), change_data = true,
                                                         db_def_folder = "bt_noseq")
PormG.ConnectionPool.fetch(::BtNoSequencePg, sql::String; kwargs...) =
  occursin("reserved_id", sql) ? [(reserved_id = missing,), (reserved_id = missing,)] : NamedTuple[]
module BtNoSeqModels
import PormG, PormG.Models
Status = Models.Model(statusid = Models.IDField(), status = Models.CharField())
PormG.Models.set_models(@__MODULE__, "bt_noseq")
end

const _BT_ENGINES = (("PostgreSQL", BtPGModels), ("SQLite", BtSLModels), ("MySQL", BtMyModels))

# The same rows, as each kind of table. The `CSV.File` is compared against `DataFrame(file)` rather
# than the hand-built frame: it reads text as `InlineString`s, which a frame built from it carries too.
const _BT_DRIVERS = DataFrames.DataFrame(
  driverid = [1, 2, 3],
  forename = ["Ayrton", "Alain", "Nigel"],
  surname = ["Senna", "Prost", "Mansell"],
  number = Union{Int, Missing}[12, missing, 5],
  dob = [Date(1960, 3, 21), Date(1955, 2, 24), Date(1953, 8, 8)],
)
const _BT_DRIVERS_CSV = """
driverid,forename,surname,number,dob
1,Ayrton,Senna,12,1960-03-21
2,Alain,Prost,,1955-02-24
3,Nigel,Mansell,5,1953-08-08
"""
_bt_kinds(df) = (
  "Vector of NamedTuples" => _BT_Tables.rowtable(df),
  "NamedTuple of vectors" => _BT_Tables.columntable(df),
)
# A dry run, as text: the SQL, or the bound parameters. A vector when the call made several chunks.
_bt_render(f, mode) = repr(f(mode))

@testset "Bulk writers take any Tables.jl table (#1344 phase 3)" begin

  @testset "source parity: the same rows render the same statement on $(engine)" for (engine, M) in _BT_ENGINES
    # Every call below, written once, run against each kind of table; `src` is the table.
    calls = [
      "bulk_insert, two chunks" =>
        (src, mode) -> bulk_insert(M.Driver.objects, src; show_query = mode, chunk_size = 2),
      "bulk_insert, columns= with a Pair" =>
        (src, mode) -> bulk_insert(M.Driver.objects, src; show_query = mode,
                                   columns = ["driverid", "surname", "dob", "forename" => "forename"]),
      "bulk_insert, on_conflict upsert" =>
        (src, mode) -> bulk_insert(M.Driver.objects, src; show_query = mode,
                                   on_conflict = (action = :update, target = ["driverid"], set = ["surname"])),
      "bulk_update by primary key" =>
        (src, mode) -> bulk_update(M.Driver.objects, src; show_query = mode, columns = ["driverid", "surname"]),
      "bulk_update, match_on= and filters=" =>
        (src, mode) -> bulk_update(M.Driver.objects, src; show_query = mode, columns = ["number"],
                                   match_on = ["surname"], filters = ["forename" => "Ayrton"]),
    ]
    engine == "PostgreSQL" &&
      push!(calls, "bulk_copy" => (src, mode) -> bulk_copy(M.Driver.objects, src; show_query = mode))

    csv = _BT_CSV.File(IOBuffer(_BT_DRIVERS_CSV))
    for (label, f) in calls, mode in (:sql, :params)
      expected = _bt_render(mode -> f(_BT_DRIVERS, mode), mode)
      for (kind, src) in _bt_kinds(_BT_DRIVERS)
        @test _bt_render(mode -> f(src, mode), mode) == expected
      end
      # A `CSV.File` against the frame it would make.
      @test _bt_render(mode -> f(csv, mode), mode) == _bt_render(mode -> f(DataFrames.DataFrame(csv), mode), mode)
    end
  end

  @testset "the frame shares a DataFrame's columns, and no writer changes the caller's table" begin
    frame = _BT_QB._bulk_frame(_BT_DRIVERS, "bulk_insert")
    @test frame.names == ["driverid", "forename", "surname", "number", "dob"]
    @test frame.row_count == 3
    @test all(_BT_QB._bulk_column(frame, n) === _BT_DRIVERS[!, n] for n in frame.names)   # #132: no copy

    # `updated_at` is `auto_now`, so every update injects a fill column into the frame: it must
    # stay in the frame, whatever kind of table the caller passed.
    rows = [(resultid = 1, driverid = 1, position = 1, laps = 58), (resultid = 2, driverid = 2, position = missing, laps = 57)]
    before = deepcopy(rows)
    bulk_update(BtPGModels.Result.objects, rows; show_query = :sql)
    bulk_insert(BtPGModels.Result.objects, rows; show_query = :sql)
    @test isequal(rows, before)   # the caller's Vector itself: no row replaced, added or removed

    df = DataFrames.DataFrame(rows)
    vectors = [df[!, n] for n in DataFrames.names(df)]
    bulk_update(BtPGModels.Result.objects, df; show_query = :sql)
    @test DataFrames.names(df) == ["resultid", "driverid", "position", "laps"]
    @test all(df[!, n] === v for (n, v) in zip(DataFrames.names(df), vectors))
  end

  @testset "an empty table of any kind writes nothing" begin
    empty_rows = NamedTuple{(:driverid, :surname), Tuple{Int, String}}[]
    @test (@test_logs (:warn, r"the table is empty") bulk_insert(BtPGModels.Driver.objects, empty_rows)) ==
          (count = 0, rows = nothing)
    @test (@test_logs (:warn, r"the table is empty") bulk_update(BtPGModels.Driver.objects, (driverid = Int[],))) ==
          (count = 0, rows = nothing)
  end

  @testset "an argument that is not a table is refused with QueryBuildError" begin
    D = BtPGModels.Driver
    # The refusal, and its message: the type alone would also pass for an unrelated QueryBuildError.
    refusal(f) = try f(); nothing catch e; e end
    refused(f, text) = (e = refusal(f); e isa PormG.QueryBuildError && occursin(text, sprint(showerror, e)))
    @test refused(() -> bulk_insert(D.objects, 42), "expected a Tables.jl table")
    @test refused(() -> bulk_update(D.objects, "driverid"), "expected a Tables.jl table")
    @test refused(() -> bulk_copy(D.objects, [1, 2, 3]), "expected a Tables.jl table")
    @test refused(() -> allocate_primary_keys(D.objects, 42), "expected a Tables.jl table")
    # The curried forms check at once, so a model in the table's place is not taken for a table.
    @test refused(() -> bulk_insert(D), "expected a Tables.jl table")
    @test refused(() -> bulk_update(D), "expected a Tables.jl table")
    # A query is a Tables.jl source (#1344 phase 1) but not a bulk input: reading it would run a SELECT
    # inside the write, and `target |> bulk_insert(query)` would insert the target's rows.
    @test refused(() -> bulk_insert(D.objects, D.objects; show_query = :sql), "a query is not a table to write")
    @test bulk_update(D.objects) isa Function   # a handler alone is still the handler-curried form
    # Columns of different lengths are not a table PormG can write (without the check: a BoundsError).
    @test refused(() -> bulk_insert(D.objects, (driverid = [1, 2], surname = ["Senna"]); show_query = :sql),
                  "columns have different lengths")
    # Rows that name different columns: `Tables.columns` would drop a key only a later row has, or raise
    # a bare FieldError for one a later row lacks.
    extra = [(driverid = 1, surname = "Senna"), (driverid = 2, surname = "Prost", number = 4)]
    lacking = [(driverid = 2, surname = "Prost", number = 4), (driverid = 1, surname = "Senna")]
    @test refused(() -> bulk_insert(D.objects, extra; show_query = :sql), "row 2 of the table does not have the columns row 1")
    @test refused(() -> bulk_insert(D.objects, lacking; show_query = :sql), "(number differ)")
    @test refused(() -> allocate_primary_keys(D.objects, extra), "row 2 of the table")
    # The same keys in another order, or one value missing, are the same columns.
    @test bulk_insert(D.objects, [(driverid = 1, surname = "Senna"), (surname = "Prost", driverid = 2)]; show_query = :params) ==
          bulk_insert(D.objects, (driverid = [1, 2], surname = ["Senna", "Prost"]); show_query = :params)
    # Rows but no columns: nothing could be written, so it is not taken for an empty table.
    @test refused(() -> bulk_insert(D.objects, [NamedTuple(), NamedTuple()]), "the table has rows but no columns")
    # The curried forms still take a table.
    @test bulk_insert(_BT_DRIVERS; show_query = :sql)(D.objects) == bulk_insert(D.objects, _BT_DRIVERS; show_query = :sql)
  end

  @testset "allocate_primary_keys returns the caller's kind of table, independent of it" begin
    # The key column is filled, so no id is reserved and no database is reached.
    D = BtPGModels.Driver
    filled = DataFrames.DataFrame(driverid = [10, 20], surname = ["Lauda", "Hunt"])
    csv = _BT_CSV.File(IOBuffer("driverid,surname\n10,Lauda\n20,Hunt\n"))
    for (src, kind) in ((filled, DataFrames.DataFrame),
                        (_BT_Tables.rowtable(filled), Vector{<:NamedTuple}),
                        (_BT_Tables.columntable(filled), NamedTuple),
                        (csv, NamedTuple))   # a `CSV.File` has no materializer of its own
      out = allocate_primary_keys(D.objects, src)
      @test out isa kind
      cols = _BT_Tables.columns(out)
      @test collect(_BT_Tables.getcolumn(cols, :driverid)) == [10, 20]
      @test String.(collect(_BT_Tables.getcolumn(cols, :surname))) == ["Lauda", "Hunt"]
      # A column store's vectors are the caller's own, so the result must hold copies. (A row table's
      # rows are immutable `NamedTuple`s: there is nothing of the caller's to share.)
      if _BT_Tables.columnaccess(src)
        @test _BT_Tables.getcolumn(cols, :surname) !== _BT_Tables.getcolumn(_BT_Tables.columns(src), :surname)
      end
    end
    # There is no in-place mode any more (#1344 decision 3).
    @test_throws MethodError allocate_primary_keys(D.objects, filled; clone = false)
  end

  @testset "the allocated key lands where the caller's key column was, or is appended" begin
    # `_allocated_table` directly, with ids as the database would hand them back: the placement a
    # `DataFrame`'s `df[!, pk] = ids` gave, for every kind of table.
    ids = Int64[7, 8]
    blank = DataFrames.DataFrame(surname = ["Lauda", "Hunt"], driverid = Union{Int, Missing}[missing, missing])
    absent = DataFrames.DataFrame(surname = ["Lauda", "Hunt"])
    for make in (identity, _BT_Tables.rowtable, _BT_Tables.columntable)
      for (df, expected) in ((blank, [:surname, :driverid]), (absent, [:surname, :driverid]))
        src = make(df)
        out = _BT_QB._allocated_table(src, _BT_QB._bulk_frame(src, "allocate_primary_keys"), "driverid", ids)
        cols = _BT_Tables.columns(out)
        @test collect(_BT_Tables.columnnames(cols)) == expected
        @test collect(_BT_Tables.getcolumn(cols, :driverid)) == ids
        @test eltype(_BT_Tables.getcolumn(cols, :driverid)) === Int64   # the missing-able type is dropped
      end
    end
    # The key column in the middle stays in the middle.
    middle = (forename = ["Niki", "James"], driverid = [missing, missing], surname = ["Lauda", "Hunt"])
    out = _BT_QB._allocated_table(middle, _BT_QB._bulk_frame(middle, "allocate_primary_keys"), "driverid", ids)
    @test collect(keys(out)) == [:forename, :driverid, :surname]
  end
  @testset "a row source that can be read only once is written whole" begin
    # Before the single-pass read, a check pass over the rows exhausted such a cursor, and the write
    # that followed found no rows: `the table is empty`, and nothing written.
    D = BtPGModels.Driver
    rows = Any[(driverid = 1, surname = "Senna", number = 12), (driverid = 2, surname = "Prost", number = missing)]
    expected = bulk_insert(D.objects, (driverid = [1, 2], surname = ["Senna", "Prost"], number = [12, missing]);
                           show_query = :params)
    @test isequal(bulk_insert(D.objects, BtOnceRows(rows, false); show_query = :params), expected)
    once = BtOnceRows(rows, false)
    collect(once)
    @test isempty(collect(once))   # the mock really is single-pass
    # A Vector{Any} is not a table to Tables.jl; the refusal names its element type and the fix.
    err = try bulk_insert(D.objects, rows) catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("element type is Any", sprint(showerror, err)) && occursin("identity.(rows)", sprint(showerror, err))
  end

  @testset "a PostgreSQL key with no sequence behind it is refused by name" begin
    # Before, the NULL ids came back as `missing` in the key column.
    rows = [(status = "Finished",), (status = "Retired",)]
    err = try allocate_primary_keys(BtNoSeqModels.Status.objects, rows) catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("no sequence or identity behind the primary key statusid", sprint(showerror, err))
  end
end
