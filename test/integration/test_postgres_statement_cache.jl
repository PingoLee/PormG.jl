"""
The Postgres.jl driver runs statements through its per-connection prepared-statement cache (#1479).

Before #1479 the Postgres.jl extension sent every statement as an unnamed one, parsed and planned on
every call; it now goes through `DBInterface.prepare`, which serves a statement the connection has
seen from the driver's LRU (`statement_cache_maxsize`, default 100). A cached statement whose result
columns change under it — an `ADD COLUMN` on the table of a cached `SELECT *` or `RETURNING *`, run
by another connection or process — is refused by PostgreSQL with `cached plan must not change result
type` (SQLSTATE 0A000), and one the server deallocated (`DEALLOCATE ALL`, `DISCARD ALL`) with
26000. Either way the extension clears the cache. Outside a transaction it runs the statement again;
inside one the transaction is already aborted, so the error propagates and a retried transaction
prepares afresh.

The statements here are raw SQL on purpose: the feature is the statement cache under a concurrent
schema change, which no ORM call can stage. The meaning testsets run on both PostgreSQL drivers, so
run the file once per driver:

    julia -t auto --project=test/integration test/integration/test_postgres_statement_cache.jl                                 # LibPQ
    PORMG_POSTGRES_DRIVER=postgres julia -t auto --project=test/integration test/integration/test_postgres_statement_cache.jl  # Postgres.jl

Every table is the scratch table `stmt_cache_1479_scratch`, dropped before and after.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

const SC1479_POOL = PormG.config[PORMG_DB_FOLDER].connections
const SC1479_TABLE = "stmt_cache_1479_scratch"
const SC1479_SELECT = """SELECT * FROM "$(SC1479_TABLE)" WHERE "id" = \$1"""
# The driver this run goes through; `nothing` off PostgreSQL. A row per engine (#1179).
const SC1479_DRIVER = by_engine(postgres = () -> PormG.postgres_driver(SC1479_POOL), sqlite = () -> nothing,
                                mysql = () -> nothing)()

sc1479_run(conn, sql, params = nothing) = PormG.backend_execute(SC1479_POOL, conn, sql, params)
sc1479_ncols(result) = length(Tables.columnnames(Tables.columns(result)))
sc1479_raised(f) = try f(); nothing catch e e end

function sc1479_reset!()
  drop_scratch_tables!(SC1479_POOL, SC1479_TABLE)
  PormG.ConnectionPool.fetch(SC1479_POOL, """CREATE TABLE "$(SC1479_TABLE)" ("id" integer PRIMARY KEY, "name" text)""")
  PormG.ConnectionPool.fetch(SC1479_POOL, """INSERT INTO "$(SC1479_TABLE)" ("id", "name") VALUES (1, 'Senna')""")
end

# Two connections held for the whole block: `conn` caches the statement, `other` changes the table
# under it — the deploy's `migrate` from another process.
function sc1479_with_two_connections(f)
  conn = PormG.ConnectionPool.acquire_connection(SC1479_POOL)
  other = PormG.ConnectionPool.acquire_connection(SC1479_POOL)
  try
    f(conn, other)
  finally
    PormG.ConnectionPool.release_connection(SC1479_POOL, other)
    PormG.ConnectionPool.release_connection(SC1479_POOL, conn)
  end
end

@testset "Postgres statement cache (#1479) on $(PORMG_DB_FOLDER)" begin
  if only_on(:postgres, "the driver statement cache is a PostgreSQL driver's (#1479)")
    sc1479_reset!()
    try
      # ─────────────────────────────────────────────────────────────────────────────
      # Meaning: a cached `SELECT *` reads the new column after a concurrent ADD COLUMN, outside a transaction
      # `SELECT * FROM "stmt_cache_1479_scratch" WHERE "id" = $1` runs twice on one connection (cached
      # under Postgres.jl), another connection adds a column, and the third run must return the new
      # three-column row instead of raising 0A000: this is what every pooled connection meets after a
      # deploy migrates a table a cached `create()` (`RETURNING *`) writes to. Both drivers answer it.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "outside a transaction the statement is prepared again after ADD COLUMN ($(SC1479_DRIVER))" begin
        sc1479_with_two_connections() do conn, other
          @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 2
          @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 2
          if SC1479_DRIVER === :postgres
            # The second run was served from the driver's cache, not sent unnamed.
            @test haskey(Postgres.get_cached_statements(conn), SC1479_SELECT)
          end
          sc1479_run(other, """ALTER TABLE "$(SC1479_TABLE)" ADD COLUMN "team" text""")
          result = sc1479_run(conn, SC1479_SELECT, [1])
          @test sc1479_ncols(result) == 3
          @test only(Tables.rowtable(result)).name == "Senna"
        end
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # Meaning departure (driver): inside a transaction, a stale cached statement raises 0A000 under Postgres.jl
      # The statement is cached outside the transaction; after `BEGIN` another connection adds a
      # column, and the cached `SELECT *` is refused by the server. The transaction is already aborted,
      # so the extension does not try again (a retry could only raise 25P02 and hide the cause), but it
      # drops the stale statement, so the caller's retried transaction reads. LibPQ sends the
      # statement unnamed and reads the new column. The refusal must carry the routine the extension
      # recognises the error by, `RevalidateCachedQuery`, on this server.
      # ─────────────────────────────────────────────────────────────────────────────
      sc1479_reset!()
      @testset "inside a transaction the stale statement $(SC1479_DRIVER === :postgres ? "raises 0A000" : "reads the new column")" begin
        sc1479_with_two_connections() do conn, other
          sc1479_run(conn, SC1479_SELECT, [1])
          sc1479_run(conn, SC1479_SELECT, [1])
          sc1479_run(conn, "BEGIN")
          try
            sc1479_run(other, """ALTER TABLE "$(SC1479_TABLE)" ADD COLUMN "team" text""")
            if SC1479_DRIVER === :postgres
              @test (@lock conn.lock conn.server_in_transaction)   # the field `_execute` reads (2.2.2–2.4.0)
              e = sc1479_raised(() -> sc1479_run(conn, SC1479_SELECT, [1]))
              @test e isa Postgres.Error
              @test e.code == "0A000"
              @test e.routine == "RevalidateCachedQuery"
              # Through core it is the caller's statement that failed, not the connection.
              @test PormG.backend_classify_error(SC1479_POOL, e) === :statement
              @test !PormG.backend_is_retry_safe(SC1479_POOL, e)
            else
              @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 3
            end
          finally
            sc1479_run(conn, "ROLLBACK")
          end
          if SC1479_DRIVER === :postgres
            @test !(@lock conn.lock conn.server_in_transaction)
          end
          # The caller's retry of the transaction, on the same connection, reads the new column: the
          # failure dropped the stale statement, which PostgreSQL would otherwise refuse on every
          # Bind, inside a transaction where no retry clears it.
          sc1479_run(conn, "BEGIN")
          try
            @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 3
          finally
            sc1479_run(conn, "ROLLBACK")
          end
        end
      end

      if SC1479_DRIVER === :postgres
        # ─────────────────────────────────────────────────────────────────────────────
        # Postgres.jl: a cached statement the server deallocated (26000) is prepared again
        # `DEALLOCATE ALL`, sent unnamed on the connection, drops every named statement behind the
        # driver's cache; the next `SELECT * … WHERE "id" = $1` is refused with SQLSTATE 26000
        # (`prepared statement … does not exist`). Outside a transaction it is prepared again and
        # reads; inside one it raises and the retried transaction reads. Without this a connection
        # that met a `DISCARD ALL` would refuse every cached statement until it was renewed.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "a deallocated cached statement is prepared again (26000)" begin
          sc1479_with_two_connections() do conn, _
            sc1479_run(conn, SC1479_SELECT, [1])
            DBInterface.execute(conn, "DEALLOCATE ALL")
            @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 3

            # The heal above cleared the cache, so here it holds only the SELECT: `BEGIN` is prepared
            # afresh and the stale SELECT is what meets 26000. A broken heal turns this red, never green.
            DBInterface.execute(conn, "DEALLOCATE ALL")
            sc1479_run(conn, "BEGIN")
            try
              e = sc1479_raised(() -> sc1479_run(conn, SC1479_SELECT, [1]))
              @test e isa Postgres.Error
              @test e.code == "26000"
            finally
              sc1479_run(conn, "ROLLBACK")
            end
            sc1479_run(conn, "BEGIN")
            try
              @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 3
            finally
              sc1479_run(conn, "ROLLBACK")
            end
          end
        end
      end

      if SC1479_DRIVER === :postgres
        # ─────────────────────────────────────────────────────────────────────────────
        # Postgres.jl: `statement_cache_maxsize=0` keeps the unnamed statement
        # With the cache sized to zero the extension sends `SELECT * … WHERE "id" = $1` unnamed, as
        # before #1479, so nothing is cached and no server-side statement is left behind — the escape a
        # PgBouncer in transaction mode before 1.21 needs. The connection-string key reaches the driver.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "statement_cache_maxsize=0 caches nothing" begin
          ext = Base.get_extension(PormG, :PormGPostgresExt)
          params = ext._checked_params("host=127.0.0.1 dbname=f1 user=u statement_cache_maxsize=0")
          @test params.statement_cache_maxsize == 0

          conn = PormG.backend_connect(SC1479_POOL)
          try
            Postgres.set_statement_cache_maxsize!(conn, 0)
            for _ in 1:3
              @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 3
            end
            @test isempty(Postgres.get_cached_statements(conn))
            # No named statement on the server either.
            n = sc1479_run(conn, "SELECT count(*) AS n FROM pg_prepared_statements")
            @test only(Tables.rowtable(n)).n == 0
            # What tells the unnamed path apart: a prepared statement would refuse two values for one
            # marker client-side (`PostgresInterfaceError`); unnamed, the server refuses it (08P01).
            e = sc1479_raised(() -> sc1479_run(conn, SC1479_SELECT, [1, 2]))
            @test e isa Postgres.Error
            @test e.code == "08P01"
          finally
            close(conn)
          end
        end

        # ─────────────────────────────────────────────────────────────────────────────
        # Postgres.jl: a parameter-count mismatch is refused by the driver before anything is sent
        # A prepared statement knows its parameter count, so `SELECT … WHERE "id" = $1` with two values
        # is refused client-side (`PostgresInterfaceError`), which core reads as the caller's statement
        # (`:unknown` → `StatementError`) — not the server's protocol error 08P01 the unnamed path got.
        # The connection stays usable.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "a parameter-count mismatch is the driver's refusal and leaves the connection usable" begin
          sc1479_with_two_connections() do conn, _
            e = sc1479_raised(() -> sc1479_run(conn, SC1479_SELECT, [1, 2]))
            @test e isa Postgres.PostgresInterfaceError
            @test !PormG.backend_is_connection_error(SC1479_POOL, e)
            @test PormG.backend_classify_error(SC1479_POOL, e) === :unknown
            @test sc1479_ncols(sc1479_run(conn, SC1479_SELECT, [1])) == 3
          end
        end
      end
    finally
      drop_scratch_tables!(SC1479_POOL, SC1479_TABLE)
    end
  end
end
