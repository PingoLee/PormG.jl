"""
A NUL in a string value is refused before anything is sent, the same way on every backend (#951).

Before, each driver took its own wrong path: LibPQ passes a text parameter to libpq as a C string,
so `"alice\\0x"` was silently cut to `"alice"` (a filter matched the wrong rows, an insert stored a
different value); Postgres.jl sent every byte and the server's SQLSTATE 22021 came back as a
`StatementError`, a 500 for what is client input; SQLite stored every byte but read back only up to
the NUL, and cut a `LIKE` pattern at it. PostgreSQL `text` cannot hold one at all.

Pinned here, with no server:

  1. **The predicate.** Text, a `Char`, an array literal and anything nested in a vector or tuple are
     checked; binary (`PormGBytes`, `Vector{UInt8}`) is not, since a NUL byte is valid data there.
  2. **The message never echoes the value.** A bound value can be a secret.
  3. **Every funnel refuses before the driver is called** — `fetch`, `with_transaction`,
     `with_transaction_async` and `with_advisory_lock` — on a mock PostgreSQL pool that records each
     call it receives. The statement text is checked too.
  4. **Writes name their field, and bulk writes their row** — `create`, `update`, `bulk_insert`,
     `bulk_update`, `bulk_copy`.
  5. **A real SQLite database** refuses every shape, writes nothing, and still round-trips binary
     bytes that contain a NUL.

julia --project=test/integration test/unit/test_nul_in_string_values.jl
"""

using Test
using DataFrames
using PormG
# Standalone runs need the SQLite extension for the real-engine half (runtests.jl loads it too).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG.Models: Model, IDField, CharField, IntegerField, BinaryField
using PormG.QueryBuilder: bulk_insert, bulk_update, bulk_copy
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
using PormG.ConnectionPool: _contains_nul, _refuse_nul, with_transaction, with_transaction_async

const NUL951 = "SEN\0hidden"            # the text after the NUL must never appear in a message
nul951_msg(e) = sprint(showerror, e)

# ─────────────────────────────────────────────────────────────────────────────
# The predicate: which bound values count as text carrying a NUL
# Text in any string type, a bare `Char`, an `ArrayField` literal, and any of those nested inside a
# vector or tuple (PostgreSQL bulk writers bind one array per column, #672). Binary never does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#951: _contains_nul — text is checked, nested values too, binary never" begin
  # Text, however it is spelled.
  @test _contains_nul("a\0b")
  @test _contains_nul(SubString("xa\0b", 2))
  @test _contains_nul("\0")                       # a NUL alone, at position 1
  @test _contains_nul('\0')
  @test _contains_nul(PormG.PormGArrayLiteral("{\"a\0\",\"b\"}"))
  # Nested: the PostgreSQL column arrays, an `__in` list, a raw-params tuple.
  @test _contains_nul(Any["ok", missing, "a\0b"])
  @test _contains_nul(("ok", ["x", "y\0"]))
  # Clean text and non-text values pass.
  @test !_contains_nul("Senna")
  @test !_contains_nul('a')
  @test !_contains_nul(Any["Senna", 1, missing, nothing, 2.5])
  @test !_contains_nul(PormG.PormGArrayLiteral("{\"a\",\"b\"}"))
  # Binary: a NUL byte is data, and both bound forms of it pass.
  @test !_contains_nul(UInt8[0x61, 0x00, 0x62])
  @test !_contains_nul(PormG.PormGBytes(UInt8[0x00]))
  @test !_contains_nul(Any[UInt8[0x00], "ok"])
end

# ─────────────────────────────────────────────────────────────────────────────
# The funnel check: which value, never what it was
# `_refuse_nul` names the parameter's position, or the statement text, and says why. The value is
# not in the message — what follows the NUL is the part a log would otherwise leak.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#951: _refuse_nul names the parameter, never the value" begin
  e = try _refuse_nul("SELECT \$1, \$2", ["Prost", NUL951]); nothing catch err err end
  @test e isa PormG.InvalidValueError
  @test occursin("Parameter 2 contains a NUL character", e.msg)
  @test occursin("on every backend", e.msg)
  @test !occursin("hidden", nul951_msg(e))
  # Nested: the position is the top-level parameter that holds it.
  e = try _refuse_nul("SELECT 1", (1, Any["a", NUL951])); nothing catch err err end
  @test e isa PormG.InvalidValueError && occursin("Parameter 2", e.msg)
  # The ORM's own collector, as the funnels receive it.
  pq = PormG.QueryBuilder.PgParameterizedQuery("", Any["Senna", Any["Prost", NUL951]], 2)
  e = try _refuse_nul("SELECT 1", pq); nothing catch err err end
  @test e isa PormG.InvalidValueError && occursin("Parameter 2", e.msg)
  # The statement text itself.
  e = try _refuse_nul("SELECT '$NUL951'", nothing); nothing catch err err end
  @test e isa PormG.InvalidValueError
  @test occursin("statement text contains a NUL", e.msg)
  @test !occursin("hidden", nul951_msg(e))
  # Clean statements pass, with or without params.
  @test _refuse_nul("SELECT \$1", ["Senna", UInt8[0x00]]) === nothing
  @test _refuse_nul("SELECT 1", nothing) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL mock: nothing reaches the driver
# The mock records every statement handed to `backend_execute_async` / `backend_copy_in!`, then
# fails, so a statement that got through is visible as a recorded call. Calls run inside
# `with_tx_context`, standing in for `run_in_transaction`: the mock has no connection to acquire.
# ─────────────────────────────────────────────────────────────────────────────
struct Nul951MockPg <: PormG.PormGPostgres end
PormG.config["nul951_pg"] = PormG.Configuration.Settings(connections = Nul951MockPg(), change_data = true)

const NUL951_SENT = String[]
struct Nul951Reached <: Exception end
function PormG.backend_execute_async(::Nul951MockPg, conn, sql::String, params)
  push!(NUL951_SENT, sql)
  throw(Nul951Reached())
end
function PormG.backend_copy_in!(::Nul951MockPg, conn, sql::String, data_itr)
  push!(NUL951_SENT, sql)
  throw(Nul951Reached())
end

const NUL951_PG = Model("nul951_result",
  id = IDField(), code = CharField(max_length = 20), year = IntegerField(), blob = BinaryField(null = true))
NUL951_PG.connect_key = "nul951_pg"

const NUL951_POOL = PormG.config["nul951_pg"].connections

# Run `f` in the mock's transaction context, and return what it raised, or `nothing`.
function nul951_pg(f)
  empty!(NUL951_SENT)
  try
    PormG.Configuration.with_tx_context(f, NUL951_POOL, :mock_tx_conn)
    nothing
  catch e
    e
  end
end

@testset "#951: PostgreSQL — every funnel refuses before the driver is called" begin
  # The control: a clean value does reach the driver, so a zero count below means "refused".
  e = nul951_pg(() -> NUL951_PG.objects.filter("code" => "SEN").list())
  @test !(e isa PormG.InvalidValueError)
  @test length(NUL951_SENT) == 1

  # A filter value — the issue's `?q=…%00…` search route.
  e = nul951_pg(() -> NUL951_PG.objects.filter("code" => NUL951).list())
  @test e isa PormG.InvalidValueError && occursin("Parameter 1 contains a NUL", e.msg)
  @test isempty(NUL951_SENT)
  # An `__in` list binds one array parameter: the NUL is nested inside it.
  e = nul951_pg(() -> NUL951_PG.objects.filter("code__@in" => ["PRO", NUL951]).list())
  @test e isa PormG.InvalidValueError
  @test isempty(NUL951_SENT)

  # Raw SQL, through each funnel. `fetch` is the one apps call; the transaction pair is public too.
  e = nul951_pg(() -> fetch(NUL951_POOL, "SELECT \$1::text"; params = [NUL951]))
  @test e isa PormG.InvalidValueError && isempty(NUL951_SENT)
  e = nul951_pg(() -> fetch(NUL951_POOL, "SELECT '$NUL951'"))
  @test e isa PormG.InvalidValueError && occursin("statement text", e.msg) && isempty(NUL951_SENT)
  # `with_transaction` logs every failure with `@error` before rethrowing (its generic wording,
  # not a rollback: nothing was sent, and a caller's own `conn` is never released).
  e = @test_logs (:error,) match_mode = :any try
    with_transaction(NUL951_POOL, "SELECT \$1::text"; conn = :mock_conn, params = (NUL951,)); nothing
  catch err
    err
  end
  @test e isa PormG.InvalidValueError && isempty(NUL951_SENT)
  e = try with_transaction_async(NUL951_POOL, "SELECT \$1::text"; conn = :mock_conn, params = [NUL951]); nothing catch err err end
  @test e isa PormG.InvalidValueError && isempty(NUL951_SENT)

  # The advisory-lock key is bound past every funnel, so it is checked on its own — before the
  # acquire, which on this mock would fail with an unrelated error.
  ran = Ref(false)
  e = try PormG.with_advisory_lock(() -> (ran[] = true), NUL951_POOL, "job\0a"); nothing catch err err end
  @test e isa PormG.InvalidValueError && occursin("with_advisory_lock: the key contains a NUL", e.msg)
  @test !ran[]
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL mock: writes name their field, bulk writes their row
# A write is refused at its format step (`_format_single`), which knows the field. The bulk writers
# re-raise it naming the row too (#869/#875), and `bulk_copy` — which never passes `fetch` — is
# covered by the same step.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#951: PostgreSQL — create/update/bulk writes name the field and row" begin
  e = nul951_pg(() -> NUL951_PG.objects.create("code" => NUL951, "year" => 1988))
  @test e isa PormG.InvalidValueError
  @test occursin("Error in insert, field `code`: The value contains a NUL character", e.msg)
  @test !occursin("hidden", nul951_msg(e))
  @test isempty(NUL951_SENT)

  e = nul951_pg(() -> NUL951_PG.objects.filter("id" => 1).update("code" => NUL951))
  @test e isa PormG.InvalidValueError && occursin("Error in update, field `code`: The value contains a NUL", e.msg)
  @test isempty(NUL951_SENT)

  # Row 2 carries the NUL, so the reported row is the failing one, not the first one formatted.
  df = DataFrame(id = [1, 2], code = ["PRO", NUL951], year = [1988, 1988])
  for (op, run) in (("bulk_insert", () -> bulk_insert(NUL951_PG.objects, df)),
                    ("bulk_update", () -> bulk_update(NUL951_PG.objects, df)),
                    ("bulk_copy",   () -> bulk_copy(NUL951_PG.objects, df)))
    # bulk_copy logs its failure with `@error` before rethrowing; that log is not under test here.
    e = op == "bulk_copy" ? (@test_logs (:error,) match_mode = :any nul951_pg(run)) : nul951_pg(run)
    @test e isa PormG.InvalidValueError
    @test occursin("Error in $op, row 2 for model nul951_result, field `code`: The value contains a NUL", e.msg)
    @test !occursin("hidden", nul951_msg(e))
    @test isempty(NUL951_SENT)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A real SQLite database: every shape refused, nothing written, binary intact
# SQLite is the backend that could store the NUL, and refuses it anyway so the engines agree. A
# mock proves what PormG sends; here the table proves nothing changed, and that a `BinaryField`
# value containing a NUL byte still round-trips byte for byte.
# ─────────────────────────────────────────────────────────────────────────────
function nul951_with_sqlite(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "nul951.sqlite"); pool_size = 1)
    key = "nul951_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
    try
      fetch(pool, """CREATE TABLE nul951_result (id INTEGER PRIMARY KEY, code VARCHAR(20) NOT NULL,
                     year INTEGER NOT NULL, blob BLOB);""")
      fetch(pool, "INSERT INTO nul951_result (id, code, year) VALUES (1, 'SEN', 1988), (2, 'PRO', 1988);")
      model = Model("nul951_result", id = IDField(), code = CharField(max_length = 20),
                    year = IntegerField(), blob = BinaryField(null = true))
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      PormG.ConnectionPool.close_pool!(pool)   # release the handle so mktempdir can clean up (Windows)
    end
  end
end

nul951_codes(model) = [r[:code] for r in model.objects.values("id", "code").order_by("id").list()]
nul951_refused(f) = try f(); nothing catch e e end

@testset "#951: SQLite — a NUL is refused on every path and nothing is written" begin
  nul951_with_sqlite() do pool, model
    @test nul951_codes(model) == ["SEN", "PRO"]

    # Filter, create, update — each refused, and the table is exactly as seeded afterwards.
    @test nul951_refused(() -> model.objects.filter("code" => NUL951).list()) isa PormG.InvalidValueError
    @test nul951_refused(() -> model.objects.create("id" => 3, "code" => NUL951, "year" => 1989)) isa PormG.InvalidValueError
    @test nul951_refused(() -> model.objects.filter("id" => 1).update("code" => NUL951)) isa PormG.InvalidValueError
    # bulk_insert: row 1 is clean, row 2 is not — the whole call is refused before its statement.
    e = nul951_refused(() -> bulk_insert(model.objects, DataFrame(id = [3, 4], code = ["MAN", NUL951], year = [1989, 1989])))
    @test e isa PormG.InvalidValueError && occursin("row 2", e.msg)
    e = nul951_refused(() -> bulk_update(model.objects, DataFrame(id = [1, 2], code = ["MAN", NUL951], year = [1989, 1989])))
    @test e isa PormG.InvalidValueError && occursin("row 2", e.msg)
    @test nul951_codes(model) == ["SEN", "PRO"]
    @test only(fetch(pool, "SELECT COUNT(*) AS n FROM nul951_result;") |> DataFrame).n == 2

    # Raw SQL: list params, a tuple, and the statement text.
    @test nul951_refused(() -> fetch(pool, "SELECT ? AS t;", [NUL951])) isa PormG.InvalidValueError
    @test nul951_refused(() -> fetch(pool, "SELECT ? AS t;", ("ok",)) ) === nothing
    @test nul951_refused(() -> fetch(pool, "SELECT ? AS a, ? AS b;", ("ok", NUL951))) isa PormG.InvalidValueError
    @test nul951_refused(() -> fetch(pool, "SELECT '$NUL951' AS t;")) isa PormG.InvalidValueError

    # `with_transaction` given no `conn` acquires its own, so a refusal must still hand it back — the
    # check sits inside the `try` for that (#846). Read from `pool_stats`, not from a second acquire:
    # the pool grows on demand past `pool_size`, so a leaked lease would never block one. Both
    # `release_conn` arms, since each releases on its own path.
    for release_conn in (true, false)
      e = @test_logs (:error,) match_mode = :any nul951_refused(() ->
        with_transaction(pool, "SELECT ? AS t;"; params = [NUL951], release_conn = release_conn))
      @test e isa PormG.InvalidValueError
      @test PormG.ConnectionPool.pool_stats(pool).in_use == 0
    end

    # An advisory lock is a no-op on SQLite, but the key is refused all the same, so one call site
    # behaves alike on both engines; the body never runs.
    ran = Ref(false)
    e = nul951_refused(() -> PormG.with_advisory_lock(() -> (ran[] = true), pool, "job\0a"; on_missing_lock = :ignore))
    @test e isa PormG.InvalidValueError && !ran[]

    # Binary is untouched: bytes with a NUL in the middle are written and read back whole.
    bytes = UInt8[0x61, 0x00, 0x62]
    model.objects.filter("id" => 1).update("blob" => bytes)
    @test only(model.objects.filter("id" => 1).values("blob").list())[:blob] == bytes
  end
end
