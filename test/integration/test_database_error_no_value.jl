"""
A database error's text never carries the value the database refused, on a real database (#987).

The unit file `test/unit/test_error_text_no_value.jl` pins the rendering against driver exceptions
built by hand. This one makes the server raise them: a unique violation whose DETAIL quotes the key
(`Key (slug)=(<value>) already exists.`) and, on PostgreSQL, an input-syntax error whose PRIMARY
message quotes the value (`invalid input syntax for type uuid: "<value>"`, SQLSTATE class 22). For
each, no rendering of the raised error — and no PormG log record — carries the value, the reason is
there as data, and `.cause` still holds the driver's full text. On PostgreSQL the reason includes the
constraint, table and column the server named, on both drivers and through `bulk_copy`'s COPY path
too (#1000). Run it once per driver:

    julia -t auto --project=test/integration test/integration/test_database_error_no_value.jl                                 # LibPQ
    PORMG_POSTGRES_DRIVER=postgres julia -t auto --project=test/integration test/integration/test_database_error_no_value.jl  # Postgres.jl
    PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_database_error_no_value.jl                     # SQLite

Every write uses scratch rows whose slug starts `err987`, removed before and after.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

using Logging

const ERR987_POOL = PormG.config[PORMG_DB_FOLDER].connections
const ERR987_IS_PG = ERR987_POOL isa PormG.PormGPostgres
const ERR987_ON_PGJL = ERR987_IS_PG && PormG.postgres_driver(ERR987_POOL) === :postgres
const ERR987_SECRET = "s3cr3t987"

err987_raised(f) = try f(); nothing catch e e end

function err987_clear!()
    q = M.Field_validation_scratch.objects.filter("slug__@startswith" => "err987")
    q.exists() && q.delete()
    return nothing
end

# Run `f()` with PormG's logs captured, and return `(raised_error, log_text)`. On LibPQ the driver
# also prints the server's full message through its own Memento logger — the channel errors.md
# documents and tells an app to turn down — so it is turned down here the documented way, and
# restored, to keep the marker out of the suite's output.
function err987_capture(f)
    logger = Test.TestLogger(min_level = Logging.Debug)
    memento = ERR987_IS_PG && !ERR987_ON_PGJL
    level = memento ? LibPQ.Memento.getlevel(LibPQ.LOGGER) : nothing
    memento && LibPQ.Memento.setlevel!(LibPQ.LOGGER, "critical")
    raised = try
        with_logger(() -> err987_raised(f), logger)
    finally
        memento && LibPQ.Memento.setlevel!(LibPQ.LOGGER, level)
    end
    text = join((string(r.message, " ", join((string(k, "=", v isa Exception ? sprint(showerror, v) : v)
                                              for (k, v) in r.kwargs), " ")) for r in logger.logs), "\n")
    return raised, text
end

# Every way the raised error becomes text — what an app returns to a client, a REPL, `"$e"`.
err987_renderings(e) = [PormG.error_message(e), sprint(showerror, e), string(e), repr(e)]

# ─────────────────────────────────────────────────────────────────────────────
# A unique violation: the DETAIL quotes the key, and none of it reaches the error's text
# The second insert reuses the first row's slug, which carries the marker. The server's DETAIL is
# `Key (slug)=(err987-<marker>) already exists.` on PostgreSQL; SQLite names only the column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#987: a unique violation's text carries no value on $(PORMG_DB_FOLDER)" begin
    err987_clear!()
    slug = "err987-$(ERR987_SECRET)"
    try
        row = () -> M.Field_validation_scratch.objects.create(
            "uuid_token" => string(UUIDs.uuid4()),
            "canonical_url" => "https://www.formula1.com/en/drivers/ayrton-senna",
            "slug" => slug)
        row()
        e, logged = err987_capture(row)

        @test e isa PormG.IntegrityError
        for text in err987_renderings(e)
            @test !occursin(ERR987_SECRET, text)
        end
        @test !occursin(ERR987_SECRET, logged)

        # The reason, as data — what each driver can report. Both PostgreSQL drivers name the
        # constraint and the table: Postgres.jl keeps the fields on its exception, and the LibPQ
        # extension reads them off the failed result before LibPQ closes it (#1000).
        if ERR987_IS_PG
            @test e.sqlstate == "23505"
            @test e.message !== nothing   # the server's primary message, in whatever locale it speaks
            @test e.constraint !== nothing && occursin("slug", e.constraint)
            @test e.table == "field_validation_scratch"
            @test e.column === nothing    # a unique violation names its constraint, not a column
        else
            @test e.sqlstate === nothing
            @test e.message == "UNIQUE constraint failed: field_validation_scratch.slug"
        end

        # The driver's full text is still one hop away — on PostgreSQL, DETAIL and value included.
        @test e.cause !== nothing
        ERR987_IS_PG && @test occursin(ERR987_SECRET, sprint(showerror, e.cause))
    finally
        err987_clear!()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A class-22 error: the server's PRIMARY message is the value, so it is not carried at all
# PostgreSQL builds `invalid input syntax for type uuid: "<value>"` from the input itself. The
# SQLSTATE survives; the message does not. Raw SQL, because PormG refuses a malformed UUIDField
# value before sending (#971) — the server-side refusal is what this pins. SQLite has no uuid type.
# ─────────────────────────────────────────────────────────────────────────────
if ERR987_IS_PG
    @testset "#987: an input-syntax error's text carries no value on $(PORMG_DB_FOLDER)" begin
        e, logged = err987_capture(() -> fetch(ERR987_POOL, "SELECT \$1::uuid AS token", [ERR987_SECRET]))

        @test e isa PormG.StatementError
        @test e.sqlstate == "22P02"
        @test e.message === nothing
        for text in err987_renderings(e)
            @test !occursin(ERR987_SECRET, text)
        end
        @test occursin("SQLSTATE 22P02", PormG.error_message(e))
        @test !occursin(ERR987_SECRET, logged)
        @test occursin(ERR987_SECRET, sprint(showerror, e.cause))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A COPY that violates a constraint names it like any other write (#1000)
# `bulk_copy` streams through COPY FROM STDIN, a separate driver path from `fetch`. A duplicate slug
# must name the constraint and table, and a row missing a NOT NULL column must name the table and
# the column — the server, not PormG, refuses both, since COPY carries no per-field validation. The
# duplicate's DETAIL quotes the marker, so the error's text is checked for it too.
# ─────────────────────────────────────────────────────────────────────────────
if ERR987_IS_PG
    @testset "#1000: a bulk_copy constraint violation names its constraint, table and column on $(PORMG_DB_FOLDER)" begin
        err987_clear!()
        slug = "err987-copy-$(ERR987_SECRET)"
        try
            M.Field_validation_scratch.objects.create(
                "uuid_token" => string(UUIDs.uuid4()),
                "canonical_url" => "https://www.formula1.com/en/drivers/ayrton-senna",
                "slug" => slug)

            # A duplicate slug: the unique constraint and its table.
            dup = DataFrames.DataFrame(uuid_token = [string(UUIDs.uuid4())],
                                       canonical_url = ["https://www.formula1.com/en/drivers/alain-prost"],
                                       slug = [slug])
            e, logged = err987_capture(() -> bulk_copy(M.Field_validation_scratch, dup))
            @test e isa PormG.IntegrityError
            @test e.sqlstate == "23505"
            @test e.constraint !== nothing && occursin("slug", e.constraint)
            @test e.table == "field_validation_scratch"
            for text in err987_renderings(e)
                @test !occursin(ERR987_SECRET, text)
            end
            @test !occursin(ERR987_SECRET, logged)

            # A row without `canonical_url`: the NOT NULL column and its table, no constraint name.
            no_url = DataFrames.DataFrame(uuid_token = [string(UUIDs.uuid4())],
                                          slug = ["err987-copy-no-url"])
            e, _ = err987_capture(() -> bulk_copy(M.Field_validation_scratch, no_url))
            @test e isa PormG.IntegrityError
            @test e.sqlstate == "23502"
            @test e.table == "field_validation_scratch" && e.column == "canonical_url"
            @test e.constraint === nothing

            # Neither failed COPY left a row behind, and the pool still serves the next statement.
            @test M.Field_validation_scratch.objects.filter("slug__@startswith" => "err987").count() == 1
        finally
            err987_clear!()
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# LibPQ: the extension's own checks behind `throw_error = false` (#1000)
# The extension reads a failed result and closes it, so two things LibPQ used to handle are its job
# now. A second `fetch` of a failed handle must raise the same error again — not read the closed
# result, which libpq reports as an empty FATAL and PormG would take for a dropped connection, nor
# return it as a success. A statement handed to the COPY path that is not a COPY FROM STDIN must
# still be refused, as LibPQ did, rather than reported as a copy of zero rows. And a statement libpq
# returned no result for at all must still raise, as it did before.
# ─────────────────────────────────────────────────────────────────────────────
if ERR987_IS_PG && !ERR987_ON_PGJL
    @testset "#1000: a failed LibPQ handle re-raises; a non-COPY statement and a missing result are refused on $(PORMG_DB_FOLDER)" begin
        CP = PormG.ConnectionPool
        conn = CP.acquire_connection(ERR987_POOL)
        try
            handle = PormG.backend_execute_async(ERR987_POOL, conn, "SELEC 1", nothing)
            first_err = err987_capture(() -> Base.fetch(handle))[1]
            second_err = err987_raised(() -> Base.fetch(handle))
            @test first_err isa PormG.StatementError && first_err.sqlstate == "42601"
            @test second_err === first_err         # the same error, not a re-read of a closed result
        finally
            CP.release_connection(ERR987_POOL, conn)
        end

        e = err987_raised(() -> CP.fetch_copy(ERR987_POOL, "SELECT 1", String[]))
        @test e isa PormG.StatementError
        @test e.cause isa LibPQ.Errors.JLResultError

        # libpq hands back NO result on a connection that is gone; LibPQ wraps that as an already-
        # closed `Result`. It is a failure — the dropped-connection shape — never a success.
        dead = PormG.backend_connect(ERR987_POOL)
        close(dead)
        e = err987_raised(() -> PormG.backend_execute(ERR987_POOL, dead, "SELECT 1", nothing))
        @test e isa PormG.OperationalError
        @test PormG.backend_is_connection_error(ERR987_POOL, e.cause)
    end
end
