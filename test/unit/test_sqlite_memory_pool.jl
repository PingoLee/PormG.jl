"""
Regression (#545): a bare SQLite `:memory:` database is private to the connection that opened
it, so a pool of more than one connection is a pool of more than one *database*.

Background: `Configuration.load` used to resolve `database: ":memory:"` as a relative path, which
on POSIX produced an on-disk file — shared by every pool connection, and therefore masking the
isolation entirely. Once `:memory:` is honoured as the keyword it is, the isolation becomes
reachable on every platform, and it splits into two cases that want different answers:

  * `split_read_write` pins writes to `writer_slot` and reads to the other slots. With a
    per-connection database, every write lands in one private database and every read looks in an
    empty one. No concurrency is required and no ordering makes it work, so the constructor
    REFUSES the pairing.

  * A shared (non-split) pool scans slots in ascending order and reuses slot 1 whenever it is
    free, so a sequential workload never opens a second database. That is a latent trap, not a
    certain failure, so it WARNS — and warns at the moment the second slot is actually opened
    rather than at construction, which is both quieter and better timed: it is exactly when the
    caller is about to see `no such table`.

`file:<name>?mode=memory&cache=shared` is the URI spelling that gives the whole pool one shared
in-memory database while still writing nothing to disk; it must therefore be accepted in both
cases. This test is DB-free in the sense that it touches no fixture and no server — it does open
real in-memory SQLite handles, which cost nothing and leave nothing behind.
"""

using Test
using PormG
using Logging

const CP = PormG.ConnectionPool

const SHARED_MEM = "file:pormg_guard_test?mode=memory&cache=shared"

# ── #545: `:memory:` + split read/write is refused ─────────────────────────────────────────────
# The pairing cannot work, so it must fail loudly at construction rather than hand back a pool
# that silently loses every write. `pool_size = 1` is the escape hatch: the existing
# `effective_split` downgrade already turns split mode off there, so there is nothing to refuse.
@testset "SQLite `:memory:` refuses split read/write (#545)" begin
    # (1) The broken pairing raises, and the message names the working spelling rather than just
    #     saying "no".
    err = try
        CP.SQLiteConnectionPool(":memory:"; pool_size = 3, split_read_write = true)
        nothing
    catch e
        e
    end
    @test err isa PormG.InvalidConfigurationError
    @test err isa PormG.ConfigurationError          # the umbrella `catch` must not have a hole
    msg = sprint(showerror, err)
    @test occursin("mode=memory&cache=shared", msg) # the remedy, not just the diagnosis
    @test occursin("pool_size=1", msg)

    # (2) pool_size = 1 makes split mode inert (`effective_split`), so there is no conflict left
    #     to refuse — this must construct. It still warns about the ignored split request, which
    #     is pre-existing behaviour and not what this case is pinning.
    pool = @test_nowarn (@test_logs (:warn,) match_mode = :any CP.SQLiteConnectionPool(
        ":memory:"; pool_size = 1, split_read_write = true))
    @test pool.split_read_write == false
    @test pool.connection_string == ":memory:"
    CP.close_pool!(pool)

    # (3) The shared-cache URI is a genuinely shared database, so split mode is fine with it.
    shared = CP.SQLiteConnectionPool(SHARED_MEM; pool_size = 3, split_read_write = true)
    @test shared.split_read_write == true
    CP.close_pool!(shared)
end

# ── #545: the private-database warning fires on the second slot, not at construction ──────────
# Construction must stay silent: PormG's own configuration tests build 28 `:memory:` pools and
# connect on 10 of them, so warning per pool would be 28 warnings about a trap that 18 of them
# never reach. The warning belongs where the second database actually comes into existence.
@testset "SQLite `:memory:` warns when a second slot opens, not before (#545)" begin
    # (1) Constructing a multi-connection `:memory:` pool is silent.
    pool = @test_nowarn CP.SQLiteConnectionPool(":memory:"; pool_size = 3)
    @test length(pool.connections) == 3           # pool_size is honoured, never rewritten

    # (2) Taking the FIRST connection is still silent — one slot, one database, nothing wrong.
    c1 = @test_nowarn CP.acquire_connection(pool)

    # (3) Holding slot 1 forces the next acquire onto slot 2, which is a second, empty database.
    #     That is the moment the caller needs to be told.
    logs = Test.collect_test_logs() do
        c2 = CP.acquire_connection(pool)
        CP.release_connection(pool, c2)
    end |> first
    warns = filter(l -> l.level == Logging.Warn && occursin("own private database", l.message), logs)
    @test length(warns) == 1
    @test Dict(warns[1].kwargs)[:slot] == 2

    CP.release_connection(pool, c1)
    CP.close_pool!(pool)

    # (4) The same shape on the shared-cache URI must NOT warn — that pool really does share one
    #     database, which is the whole point of recommending it.
    shared = CP.SQLiteConnectionPool(SHARED_MEM; pool_size = 3)
    s1 = CP.acquire_connection(shared)
    slogs = Test.collect_test_logs() do
        s2 = CP.acquire_connection(shared)
        CP.release_connection(shared, s2)
    end |> first
    @test isempty(filter(l -> l.level == Logging.Warn && occursin("own private database", l.message),
                         slogs))
    CP.release_connection(shared, s1)
    CP.close_pool!(shared)
end
