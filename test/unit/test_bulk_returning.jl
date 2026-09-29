# ============================================================
# test/unit/test_bulk_returning.jl
#
# bulk_insert(…; returning=) hands back the values the database wrote, correlated to the input
# rows (#671).
#
# CONTRACT being tested:
#   `returning = ["id", …]` makes the executed call return `(count, rows::DataFrame)`, where `rows`
#   has one column per requested field and `nrow(df)` rows, and row `i` belongs to input row `i`.
#   A row this call did not write — skipped by `on_conflict = :nothing`, or a later duplicate of a
#   key inside the frame — is `missing`. Rows are matched to the input by KEY VALUE (the
#   `on_conflict` target, else the primary key), never by position: neither engine promises that a
#   multi-row INSERT reports its rows in input order. An auto pk the frame does not carry is
#   pre-allocated from its own sequence so it can serve as that key.
#
# Hermetic: the SQLite half runs against a real temp database (SQLite has no RETURNING in PormG, so
# the read-back is the thing under test and is simpler to prove for real), and the PostgreSQL half
# uses a mock pool whose RETURNING rows are scripted per statement — deliberately shuffled, so a
# positional match fails.
# ============================================================

using Test
using DataFrames
using UUIDs
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, UUIDField, DurationField, DecimalField
import Decimals
using Dates
using PormG.QueryBuilder: bulk_insert
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

# Run `f(pool, model)` against a fresh temp SQLite database. `results` carries a UNIQUE (driver, year)
# so a conflict can be built without the pk, and `status` has a database default the frame never
# supplies — the value `returning` exists to hand back. `id` is AUTOINCREMENT, as PormG's DDL makes it.
function br671_with_sqlite(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "br671.sqlite"); pool_size = 1)
    key = "br671_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(
      connections = pool, db_def_folder = dir, change_data = true)
    try
      fetch(pool, """CREATE TABLE br671_result (
        id INTEGER PRIMARY KEY AUTOINCREMENT, driver TEXT NOT NULL, year INTEGER NOT NULL,
        points INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'classified', UNIQUE (driver, year));""")
      model = Model("br671_result",
        id = IDField(), driver = CharField(), year = IntegerField(), points = IntegerField(),
        status = CharField(db_default = (postgres = "'classified'", sqlite = "'classified'")))
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

# The 1988 season, five results — three chunks at chunk_size = 2.
br671_season() = DataFrame(
  driver = ["Senna", "Prost", "Berger", "Alboreto", "Piquet"],
  year   = fill(1988, 5),
  points = [9, 6, 4, 3, 2])

# The table as the database holds it, keyed by driver — the independent source every correlation
# assertion is checked against.
br671_ids(pool) = Dict(r.driver => r.id for r in
  eachrow(fetch(pool, "SELECT id, driver FROM br671_result;") |> DataFrame))

@testset "bulk_insert returning= (#671), SQLite" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Auto pk, several chunks: the ids are pre-allocated and come back in input order.
  # The frame has no `id` column, so the pk is allocated from sqlite_sequence and matched per chunk.
  # Every returned id is checked against the row the database really holds for that driver, and
  # `status` is the column default the frame never supplied.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "auto pk across chunks, correlated to the input" begin
    br671_with_sqlite() do pool, model
      df = br671_season()
      r = bulk_insert(model.objects, df; returning = ["id", "status"], chunk_size = 2)
      @test r.count == 5
      @test r.rows isa DataFrame
      @test names(r.rows) == ["id", "status"]
      @test nrow(r.rows) == 5
      ids = br671_ids(pool)
      @test r.rows.id == [ids[d] for d in df.driver]
      @test all(==("classified"), r.rows.status)
      # The caller's frame is untouched: the allocated ids lived in a private working column.
      @test names(df) == ["driver", "year", "points"]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A single field name, and Symbols, are accepted; a repeated name is returned once.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "returning accepts a name, Symbols, and de-duplicates" begin
    br671_with_sqlite() do pool, model
      r = bulk_insert(model.objects, br671_season(); returning = "id")
      @test names(r.rows) == ["id"]
      r2 = bulk_insert(model.objects, DataFrame(driver = ["Mansell"], year = [1988], points = [0]);
        returning = [:id, :points, :id])
      @test names(r2.rows) == ["id", "points"]
      @test r2.rows.id == [br671_ids(pool)["Mansell"]]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A supplied pk is the key as it is; nothing is allocated.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "supplied pk" begin
    br671_with_sqlite() do pool, model
      df = transform(br671_season(), :driver => (d -> 100 .+ (1:length(d))) => :id)
      r = bulk_insert(model.objects, df; returning = ["id", "status"], chunk_size = 2)
      @test r.rows.id == [101, 102, 103, 104, 105]
      @test all(==("classified"), r.rows.status)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DO NOTHING by target: a row that already existed, and a key repeated inside the frame, are
  # `missing`. Senna and Prost are in the table before the call; Berger appears twice in the frame,
  # so its second occurrence is skipped by the first. Without the pre-check, the read-back would
  # report Senna's and Prost's EXISTING ids as rows this call wrote.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DO NOTHING by target leaves skipped rows missing" begin
    br671_with_sqlite() do pool, model
      bulk_insert(model.objects, br671_season()[1:2, :])
      df = vcat(br671_season(), DataFrame(driver = ["Berger"], year = [1988], points = [1]))
      r = bulk_insert(model.objects, df; returning = ["id", "points"], chunk_size = 2,
        on_conflict = (action = :nothing, target = ["driver", "year"]))
      @test r.count == 3
      ids = br671_ids(pool)
      @test isequal(r.rows.id, [missing, missing, ids["Berger"], ids["Alboreto"], ids["Piquet"], missing])
      # Berger's written row is the first occurrence (4 points), not the skipped duplicate (1).
      @test isequal(r.rows.points, [missing, missing, 4, 3, 2, missing])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DO UPDATE by target: an updated row comes back with its OLD id and the value just written.
  # This is why the key is the target and not the pk: the upserted row keeps the pk it had.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DO UPDATE by target returns the updated row" begin
    br671_with_sqlite() do pool, model
      bulk_insert(model.objects, br671_season()[1:1, :])     # Senna, 9 points
      senna_id = br671_ids(pool)["Senna"]
      df = DataFrame(driver = ["Mansell", "Senna"], year = [1988, 1988], points = [0, 10])
      r = bulk_insert(model.objects, df; returning = ["id", "points"],
        on_conflict = (action = :update, target = ["driver", "year"], set = ["points"]))
      @test r.rows.id == [br671_ids(pool)["Mansell"], senna_id]
      @test r.rows.points == [0, 10]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Untargeted DO NOTHING with an auto pk: the pre-allocated id of a skipped row matches nothing.
  # Senna conflicts on the UNIQUE (driver, year), not on the pk, so its allocated id is never
  # written and the read-back by pk cannot find it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "untargeted DO NOTHING with an auto pk" begin
    br671_with_sqlite() do pool, model
      bulk_insert(model.objects, br671_season()[1:1, :])
      r = bulk_insert(model.objects, br671_season()[1:2, :]; returning = ["id"], on_conflict = :nothing)
      @test r.count == 1
      @test isequal(r.rows.id, [missing, br671_ids(pool)["Prost"]])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A PormG-minted UUID pk is a key the client already holds: `_prepare_bulk_df!` fills it before
  # the INSERT, so no allocation is needed and each row gets its own UUID back.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "UUID auto_add pk" begin
    br671_with_sqlite() do pool, _
      fetch(pool, "CREATE TABLE br671_tyre (id TEXT PRIMARY KEY, compound TEXT NOT NULL);")
      tyre = Model("br671_tyre", id = UUIDField(primary_key = true, auto_add = true), compound = CharField())
      tyre.connect_key = "br671_sqlite"
      df = DataFrame(compound = ["soft", "medium", "hard"])
      r = bulk_insert(tyre.objects, df; returning = ["id", "compound"], chunk_size = 2)
      @test r.rows.compound == ["soft", "medium", "hard"]
      stored = Dict(row.compound => row.id for row in
        eachrow(fetch(pool, "SELECT id, compound FROM br671_tyre;") |> DataFrame))
      @test string.(r.rows.id) == [stored[c] for c in df.compound]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A key repeated INSIDE one chunk under DO NOTHING: the first occurrence is credited, the second
  # is missing. Neither is in the table beforehand, so the `existing` pre-check cannot be what
  # skips the duplicate — only the first-occurrence rule does (the case above spans two chunks).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DO NOTHING credits the first occurrence of a key within one chunk" begin
    br671_with_sqlite() do pool, model
      df = DataFrame(driver = ["Senna", "Berger", "Berger"], year = fill(1988, 3), points = [9, 4, 1])
      r = bulk_insert(model.objects, df; returning = ["id", "points"],
        on_conflict = (action = :nothing, target = ["driver", "year"]))
      ids = br671_ids(pool)
      @test r.count == 2
      @test isequal(r.rows.id, [ids["Senna"], ids["Berger"], missing])
      @test isequal(r.rows.points, [9, 4, missing])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A key loaded as text (a CSV column of "101", "102") still matches the integer the database
  # stores. The integer formatter keeps the text of a string and the Int of an Int, so keys are
  # compared after the formatter AND as text — without that, every row came back `missing`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a pk supplied as strings matches the stored integers" begin
    br671_with_sqlite() do pool, model
      df = DataFrame(id = ["101", "102"], driver = ["Senna", "Prost"], year = [1988, 1988], points = [9, 6])
      r = bulk_insert(model.objects, df; returning = ["id", "points"])
      @test r.rows.id == [101, 102]
      @test r.rows.points == [9, 6]
      # Spellings the integer column normalizes on write — a leading zero, a plus sign — match too:
      # integer keys are compared by value, not by text.
      df = DataFrame(id = ["0103", "+104"], driver = ["Berger", "Piquet"], year = [1988, 1988], points = [4, 2])
      @test bulk_insert(model.objects, df; returning = ["id"]).rows.id == [103, 104]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A two-column key over a very large chunk. The read-back renders `(a AND b) OR …` per key, and
  # the driver's SQLite refuses an expression deeper than 10,000 (measured: 16,000 keys in one
  # statement fail, 8,000 pass). Two inserted columns cap a chunk at 16,383 rows, so a caller who
  # raises `chunk_size` reaches it — the read-back has to be batched.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a multi-column key over a 12,000-row chunk" begin
    br671_with_sqlite() do pool, _
      fetch(pool, """CREATE TABLE br671_grid (id INTEGER PRIMARY KEY AUTOINCREMENT, driver TEXT NOT NULL,
        year INTEGER NOT NULL, UNIQUE (driver, year));""")
      grid = Model("br671_grid", id = IDField(), driver = CharField(), year = IntegerField())
      grid.connect_key = "br671_sqlite"
      n = 12_000
      df = DataFrame(driver = ["D$(i)" for i in 1:n], year = fill(1988, n))
      r = bulk_insert(grid.objects, df; returning = ["id"], chunk_size = n,
        on_conflict = (action = :nothing, target = ["driver", "year"]))
      stored = Dict(row.driver => row.id for row in eachrow(fetch(pool, "SELECT id, driver FROM br671_grid;") |> DataFrame))
      @test r.count == n
      @test r.rows.id == [stored[d] for d in df.driver]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A NULL in the key: the row is written but cannot be looked up, so it is `missing` — and that is
  # not mistaken for a matching failure. `code` is UNIQUE and nullable; NULLs never conflict.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a NULL key is written but not correlated" begin
    br671_with_sqlite() do pool, _
      fetch(pool, "CREATE TABLE br671_car (id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT UNIQUE, n INTEGER NOT NULL);")
      car = Model("br671_car", id = IDField(), code = CharField(null = true), n = IntegerField())
      car.connect_key = "br671_sqlite"
      df = DataFrame(code = Union{String, Missing}["MP4/4", missing], n = [1, 2])
      r = bulk_insert(car.objects, df; returning = ["id", "n"], on_conflict = (action = :nothing, target = ["code"]))
      @test r.count == 2
      @test isequal(r.rows.n, [1, missing])
      @test (fetch(pool, "SELECT COUNT(*) AS n FROM br671_car;") |> DataFrame).n[1] == 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A field stored under another column name (`db_column`) comes back under its FIELD name.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a db_column field is returned by field name" begin
    br671_with_sqlite() do pool, _
      fetch(pool, "CREATE TABLE br671_lap (id INTEGER PRIMARY KEY AUTOINCREMENT, pos INTEGER NOT NULL);")
      lap = Model("br671_lap", id = IDField(), position = IntegerField(db_column = "pos"))
      lap.connect_key = "br671_sqlite"
      r = bulk_insert(lap.objects, DataFrame(position = [3, 1, 2]); returning = ["id", "position"], chunk_size = 2)
      @test names(r.rows) == ["id", "position"]
      @test r.rows.position == [3, 1, 2]
      stored = fetch(pool, "SELECT id, pos FROM br671_lap;") |> DataFrame
      @test r.rows.id == [only(stored.id[stored.pos .== p]) for p in [3, 1, 2]]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Refusals: nothing to match on, or a request that cannot be honored, raises before any write.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "refusals" begin
    br671_with_sqlite() do pool, model
      # An unknown field is a typo, refused like any other unknown field name.
      @test_throws UnknownFieldError bulk_insert(model.objects, br671_season(); returning = ["pointz"])
      @test_throws QueryBuildError bulk_insert(model.objects, br671_season(); returning = String[])
      @test_throws QueryBuildError bulk_insert(model.objects, br671_season(); returning = 1)
      # The target is the key, so it must be something the frame carries.
      @test_throws QueryBuildError bulk_insert(model.objects, br671_season();
        columns = ["driver", "points"], returning = ["id"],
        on_conflict = (action = :nothing, target = ["driver", "year"]))
      # A pk the database generates, that PormG cannot pre-allocate, with no target to match on.
      fetch(pool, "CREATE TABLE br671_circuit (ref TEXT PRIMARY KEY DEFAULT (hex(randomblob(8))), name TEXT NOT NULL);")
      circuit = Model("br671_circuit", ref = CharField(primary_key = true), name = CharField())
      circuit.connect_key = "br671_sqlite"
      @test_throws QueryBuildError bulk_insert(circuit.objects, DataFrame(name = ["Monza"]); returning = ["ref"])
      # None of the refused calls wrote anything.
      @test (fetch(pool, "SELECT COUNT(*) AS n FROM br671_result;") |> DataFrame).n[1] == 0
      @test (fetch(pool, "SELECT COUNT(*) AS n FROM br671_circuit;") |> DataFrame).n[1] == 0
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Without returning the #670 shape is unchanged, and an empty frame returns an empty `rows`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "default and empty-frame shapes" begin
    br671_with_sqlite() do pool, model
      @test bulk_insert(model.objects, br671_season()) == (count = 5, rows = nothing)
      r = @test_logs (:warn,) bulk_insert(model.objects, br671_season()[1:0, :]; returning = ["id"])
      @test r.count == 0
      @test r.rows isa DataFrame && names(r.rows) == ["id"] && nrow(r.rows) == 0
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A dry run allocates nothing: pre-allocation draws the sequence, which is a write.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a dry run allocates no ids" begin
    br671_with_sqlite() do pool, model
      bulk_insert(model.objects, br671_season()[1:1, :])      # creates the sqlite_sequence row
      seq() = (fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'br671_result';") |> DataFrame).seq[1]
      before = seq()
      sql = bulk_insert(model.objects, br671_season(); returning = ["id"], show_query = :sql)
      @test sql isa AbstractString
      @test !occursin("RETURNING", sql)        # SQLite never renders it
      @test seq() == before
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL mock: RETURNING rows are scripted per INSERT, and the pk allocation is scripted too.
# The calls run inside `with_tx_context`, standing in for `run_in_transaction` — the mock pool has
# no real connection to pin.
# ─────────────────────────────────────────────────────────────────────────────
struct BulkReturningMockPg <: PormG.PormGPostgres end
PormG.config["br671_pg"] = PormG.Configuration.Settings(
  connections = BulkReturningMockPg(), change_data = true)

const BR671_RETURNED = DataFrame[]   # what each INSERT … RETURNING reports, in turn
const BR671_RESERVED = Int[]         # what the nextval() allocation reports
const BR671_WRITES = String[]
const BR671_DUPLICATE = Ref(false)   # make every INSERT fail as a duplicate key

function fetch(connection::BulkReturningMockPg, sql::String;
  conn = nothing, params = nothing, ignore_tx::Bool = false)
  occursin("nextval(", sql) && return DataFrame(reserved_id = copy(BR671_RESERVED))
  if occursin(r"^\s*INSERT"i, sql)
    push!(BR671_WRITES, sql)
    BR671_DUPLICATE[] && error("duplicate key value violates unique constraint \"br671_pg_result_pkey\"")
    return popfirst!(BR671_RETURNED)
  end
  return DataFrame()   # SAVEPOINT / RELEASE and anything else
end

const BR671_PG_RESULT = Model("br671_pg_result",
  id = IDField(), driver = CharField(), year = IntegerField(), points = IntegerField())
BR671_PG_RESULT.connect_key = "br671_pg"
const BR671_PG_ALWAYS = Model("br671_pg_always",
  id = IDField(generated_always = true), driver = CharField())
BR671_PG_ALWAYS.connect_key = "br671_pg"
# A db_column rename and an INTERVAL, the one PostgreSQL type with a read parser (#581).
const BR671_PG_STINT = Model("br671_pg_stint",
  id = IDField(), position = IntegerField(db_column = "pos"), duration = DurationField())
BR671_PG_STINT.connect_key = "br671_pg"
# Crossing names: `grid` is stored as "laps", and `laps` as "l". Renaming one column at a time
# collides — "l" => "laps" while the "laps" column still holds `grid`'s values.
const BR671_PG_CROSS = Model("br671_pg_cross",
  id = IDField(), grid = IntegerField(db_column = "laps"), laps = IntegerField(db_column = "l"))
BR671_PG_CROSS.connect_key = "br671_pg"
# A DECIMAL target: PostgreSQL hands back 1.50 for an input of 1.5.
const BR671_PG_PRICE = Model("br671_pg_price",
  id = IDField(), price = DecimalField(max_digits = 10, decimal_places = 2), label = CharField())
BR671_PG_PRICE.connect_key = "br671_pg"

function br671_pg(f; returned = DataFrame[], reserved = Int[], duplicate = false)
  empty!(BR671_WRITES); empty!(BR671_RETURNED); empty!(BR671_RESERVED)
  append!(BR671_RETURNED, returned); append!(BR671_RESERVED, reserved)
  BR671_DUPLICATE[] = duplicate
  try
    PormG.Configuration.with_tx_context(f, PormG.config["br671_pg"].connections, :mock_tx_conn)
  finally
    BR671_DUPLICATE[] = false
  end
end

@testset "bulk_insert returning= (#671), PostgreSQL" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # The statement: RETURNING names the key and the requested columns, after ON CONFLICT.
  # A dry run allocates nothing, so there is no pk column and no OVERRIDING clause.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "statement shape" begin
    sql = bulk_insert(BR671_PG_RESULT.objects, br671_season(); returning = ["points"], show_query = :sql)
    @test occursin(r"RETURNING \"id\", \"points\"\s*$", sql)
    # The dry run allocated nothing, so the pk is NOT in the column list.
    @test occursin("INSERT INTO \"br671_pg_result\" (\"driver\", \"year\", \"points\")\n", sql)
    # Nor does a generated_always pk get OVERRIDING without allocated ids to justify it.
    sql = bulk_insert(BR671_PG_ALWAYS.objects, DataFrame(driver = ["Senna"]); returning = ["id"], show_query = :sql)
    @test occursin("INSERT INTO \"br671_pg_always\" (\"driver\")\n", sql)
    @test !occursin("OVERRIDING", sql)
    sql = bulk_insert(BR671_PG_RESULT.objects, br671_season(); returning = ["id"], show_query = :sql,
      on_conflict = (action = :nothing, target = ["driver", "year"]))
    @test occursin(r"ON CONFLICT \(\"driver\", \"year\"\) DO NOTHING\s*RETURNING \"driver\", \"year\", \"id\"", sql)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Shuffled RETURNING rows land on the right input rows.
  # The ids 101–105 are pre-allocated; each chunk's RETURNING rows are scripted in REVERSE order, so
  # a positional match would swap every pair. The pk column joins the INSERT after allocation.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "matching is by key, not position" begin
    r = br671_pg(reserved = [101, 102, 103, 104, 105], returned = [
        DataFrame(id = [102, 101], points = [6, 9]),
        DataFrame(id = [104, 103], points = [3, 4]),
        DataFrame(id = [105], points = [2])]) do
      bulk_insert(BR671_PG_RESULT.objects, br671_season(); returning = ["id", "points"], chunk_size = 2)
    end
    @test r.count == 5
    @test r.rows.id == [101, 102, 103, 104, 105]
    @test r.rows.points == [9, 6, 4, 3, 2]
    @test length(BR671_WRITES) == 3
    @test all(sql -> occursin(r"INSERT INTO \"br671_pg_result\" \([^)]*\"id\"\)", sql), BR671_WRITES)
    @test !any(sql -> occursin("OVERRIDING", sql), BR671_WRITES)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DO NOTHING by target: RETURNING omits skipped rows, and they stay missing.
  # Prost's key is absent from what the database reported, so Prost is missing; the rest match by
  # (driver, year) although reported out of order.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DO NOTHING by target" begin
    df = br671_season()[1:3, :]
    r = br671_pg(returned = [DataFrame(driver = ["Berger", "Senna"], year = [1988, 1988], id = [7, 5])]) do
      bulk_insert(BR671_PG_RESULT.objects, df; returning = ["id"],
        on_conflict = (action = :nothing, target = ["driver", "year"]))
    end
    @test r.count == 2
    @test isequal(r.rows.id, [5, missing, 7])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A generated_always identity takes pre-allocated ids only through OVERRIDING SYSTEM VALUE.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "generated_always pk gets OVERRIDING SYSTEM VALUE" begin
    r = br671_pg(reserved = [1, 2], returned = [DataFrame(id = [2, 1])]) do
      bulk_insert(BR671_PG_ALWAYS.objects, DataFrame(driver = ["Senna", "Prost"]); returning = ["id"])
    end
    @test r.rows.id == [1, 2]
    @test occursin(r"\) OVERRIDING SYSTEM VALUE\n", only(BR671_WRITES))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DO NOTHING credits the first occurrence of a key repeated inside one chunk.
  # Senna appears twice; RETURNING reports one Senna row, which belongs to the first.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DO NOTHING: first occurrence within a chunk" begin
    df = DataFrame(driver = ["Senna", "Prost", "Senna"], year = fill(1988, 3), points = [9, 6, 1])
    r = br671_pg(returned = [DataFrame(driver = ["Prost", "Senna"], year = [1988, 1988], id = [8, 7])]) do
      bulk_insert(BR671_PG_RESULT.objects, df; returning = ["id"],
        on_conflict = (action = :nothing, target = ["driver", "year"]))
    end
    @test isequal(r.rows.id, [7, 8, missing])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A matching failure is loud. A reported row no input row owns, or — outside DO NOTHING — an
  # input row that did not come back, raises instead of leaving a silent `missing`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an unmatched row raises" begin
    df = br671_season()[1:2, :]
    @test_throws QueryBuildError br671_pg(reserved = [1, 2], returned = [DataFrame(id = [1, 99])]) do
      bulk_insert(BR671_PG_RESULT.objects, df; returning = ["id"])
    end
    @test_throws QueryBuildError br671_pg(reserved = [1, 2], returned = [DataFrame(id = [1])]) do
      bulk_insert(BR671_PG_RESULT.objects, df; returning = ["id"])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Pre-allocated ids are not retried on a duplicate key: the retry would send the same ids again.
  # A frame that supplies its own pk keeps the #197 resync-and-retry (two INSERTs); the allocated
  # one propagates after the first.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "no sequence-resync retry for pre-allocated ids" begin
    err = try
      br671_pg(reserved = [1, 2], duplicate = true) do
        bulk_insert(BR671_PG_RESULT.objects, br671_season()[1:2, :]; returning = ["id"])
      end
      nothing
    catch e
      e
    end
    @test err !== nothing && occursin("duplicate key", sprint(showerror, err))
    @test length(BR671_WRITES) == 1
    # Control: the same failure with a supplied pk is retried once after the resync.
    try
      br671_pg(duplicate = true) do
        bulk_insert(BR671_PG_RESULT.objects, transform(br671_season()[1:2, :], :year => (y -> [1, 2]) => :id);
          returning = ["id"])
      end
    catch
    end
    @test length(BR671_WRITES) == 2
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # RETURNING names columns by db_column; they come back by field name, and an INTERVAL gets the same
  # read parser `DataFrame(query)` applies, so a DurationField is a CompoundPeriod on either engine.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "db_column rename and the INTERVAL read parser" begin
    df = DataFrame(position = [2, 1], duration = [Dates.Minute(95), Dates.Minute(90)])
    r = br671_pg(reserved = [1, 2],
        returned = [DataFrame(id = [2, 1], pos = [1, 2], duration = [Dates.Minute(90), Dates.Minute(95)])]) do
      bulk_insert(BR671_PG_STINT.objects, df; returning = ["position", "duration"])
    end
    @test names(r.rows) == ["position", "duration"]
    @test r.rows.position == [2, 1]
    @test all(d -> d isa Dates.CompoundPeriod, r.rows.duration)
    @test r.rows.duration == [Dates.CompoundPeriod(Dates.Minute(95)), Dates.CompoundPeriod(Dates.Minute(90))]
    @test occursin("RETURNING \"id\", \"pos\", \"duration\"", only(BR671_WRITES))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Crossing db_columns are renamed together: `grid` lives in "laps" and `laps` in "l", so a
  # per-field rename of "l" => "laps" would clash with the "laps" column still owed to `grid`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "crossing db_column names" begin
    df = DataFrame(grid = [1, 2], laps = [61, 60])
    r = br671_pg(reserved = [1, 2], returned = [DataFrame(id = [2, 1], laps = [2, 1], l = [60, 61])]) do
      # `laps` first: its per-field rename ("l" => "laps") is the one that clashes.
      bulk_insert(BR671_PG_CROSS.objects, df; returning = ["laps", "grid"])
    end
    @test names(r.rows) == ["laps", "grid"]
    @test r.rows.grid == [1, 2]
    @test r.rows.laps == [61, 60]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A DECIMAL key is compared by value: the frame carries the text "1.50" and "20.0" (a CSV column,
  # say), which the formatter binds as is, and the database reports the decimals 1.50 and 20.00,
  # which print as "1.5" and "20". As text they differ; as decimals they are the same key.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a DECIMAL target matches its normalized value" begin
    df = DataFrame(price = ["1.50", "20.0"], label = ["slick", "wet"])
    r = br671_pg(returned = [DataFrame(price = parse.(Decimals.Decimal, ["20.00", "1.50"]), id = [8, 7])]) do
      bulk_insert(BR671_PG_PRICE.objects, df; returning = ["id"],
        on_conflict = (action = :update, target = ["price"], set = ["label"]))
    end
    @test r.rows.id == [7, 8]
  end
end
