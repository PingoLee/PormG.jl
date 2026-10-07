"""
A database error's text never carries the value the database refused, on a real database (#987).

The unit file `test/unit/test_error_text_no_value.jl` pins the rendering against driver exceptions
built by hand. This one makes the server raise them: a unique violation whose DETAIL quotes the key
(`Key (slug)=(<value>) already exists.`) and, on PostgreSQL, an input-syntax error whose PRIMARY
message quotes the value (`invalid input syntax for type uuid: "<value>"`, SQLSTATE class 22). For
each, no rendering of the raised error — and no PormG log record — carries the value, the reason is
there as data, and `.cause` still holds the driver's full text. Run it once per driver:

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

        # The reason, as data — what each driver can report.
        if ERR987_IS_PG
            @test e.sqlstate == "23505"
            @test occursin("duplicate key value violates unique constraint", e.message)
            if ERR987_ON_PGJL
                @test e.constraint !== nothing && occursin("slug", e.constraint)
                @test e.table == "field_validation_scratch"
            else
                @test e.constraint === nothing   # LibPQ's exception keeps only its text
            end
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
