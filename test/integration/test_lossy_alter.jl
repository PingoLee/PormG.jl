# =============================================================================
# Lossy ALTERs against a real PostgreSQL server (#803)
#
# The unit file `test/unit/test_lossy_alters.jl` pins the classifier, the plan header and the
# pre-check SQL on mocks, and the whole flow end to end on SQLite. What it cannot show is the half
# only PostgreSQL has — the engine enforces a VARCHAR length, an integer width and a NUMERIC scale,
# and cannot cast text to integer without a `USING`:
#
#   (a) a shorter VARCHAR over a longer value is refused with the row counted; fixed, it applies;
#   (b) bigint → integer over 3e9 is refused;
#   (c) a lower NUMERIC scale rounds, so it needs `destructive = true` and is recorded destructive;
#   (d) text → integer is refused as `:no_implicit_cast` — and, with the header stripped, PostgreSQL
#       itself rejects it, which is the live check that the deny-list entry is true;
#   (e) SET NOT NULL over a NULL is refused;
#   (f) fewer NUMERIC whole digits and (g) a byte bound are counted by the server's own arithmetic;
#   (h) text → PositiveIntegerField is reported by `dry_run` as refused, not raised as a query error;
#   (j) a new NOT NULL column with no default is refused over a populated table with the rows
#       counted, and applies over an empty one (#829);
#   (k) `unique = true` over duplicates, (l) a foreign key over an orphan and (m) a CheckConstraint
#       over a failing row are each counted by the server and refused (#830).
#
# Run it under both PostgreSQL drivers: `PORMG_POSTGRES_DRIVER=Postgres` selects Postgres.jl (#788),
# whose parameter typing differs from LibPQ's.
#
# Isolation: a temporary `db_def_folder`, so the plan files are private, and one scratch table plus
# the history rows this file writes (by name), both removed in `finally`. Configured extensions are
# stripped from the copied settings, so no extension DDL runs from here. The shared fixture's own
# tables are neither read nor planned: `include_table` keeps the diff to the scratch table.
#
# julia -t auto --project=test/integration test/integration/test_lossy_alter.jl
# =============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

if adapter_name == "SQLite"
    @info "Skipping the PostgreSQL lossy-ALTER tests on SQLite (its half is test/unit/test_lossy_alters.jl)"
else

import OrderedCollections: OrderedDict

const _LA803PG_BASE = PormG.config[haskey(PormG.config, "db_2") ? "db_2" : first(keys(PormG.config))]
const _LA803PG_TABLE = "pormg_test_lossy803"
const _LA803PG_NAME = "pormg_test_lossy803"

# A pool on the fixture database with its own temporary folder, change_db on.
function _la803pg_settings()
    cfg = copy(_LA803PG_BASE.db_config_settings)
    delete!(cfg, "extensions")   # no extension DDL from this file
    folder = mktempdir()
    st = PormG.Configuration.Settings(app_env = _LA803PG_BASE.app_env, db_def_folder = folder,
                                      db_config_settings = cfg)
    st.change_db = true
    PormG.Configuration._build_connection_pool!(st, "pormg_test::lossy803")
    return st
end

_la803pg_quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error))

# The F1 results table, reduced to one column per case. `overrides` replaces one declaration.
function _la803pg_models(; overrides...)
    cols = OrderedDict{Symbol, String}(
        :code   => "Models.CharField(max_length = 20, null = true)",
        :big    => "Models.BigIntegerField(null = true)",
        :points => "Models.DecimalField(max_digits = 10, decimal_places = 4, null = true)",
        :note   => "Models.TextField(null = true)",
        :grid   => "Models.IntegerField(null = true)",
        :bytes  => "Models.BinaryField(null = true)")
    for (k, v) in overrides
        cols[k] = v
    end
    body = join(("    $(k) = $(v)" for (k, v) in cols), ",\n")
    return "module models\nimport PormG.Models\nPormg_test_lossy803 = Models.Model(\"$(_LA803PG_TABLE)\";\n" *
           "    id = Models.IDField(),\n$(body)\n)\nend\n"
end

# Plan the scratch table against the models file the way `makemigrations` does — scoped to that one
# table with `include_table`, so nothing else in the shared fixture is diffed — and write the plan
# with its lossy-ALTER header through the same writer.
function _la803pg_plan!(st, models::String)
    models_path = joinpath(st.db_def_folder, st.model_file)
    write(models_path, models)
    live = PormG.Migrations.read_live_schema(st.connections; include_table = [_LA803PG_TABLE])
    sink = PormG.Migrations.LossyAlter[]
    plan = PormG.Migrations.get_migration_plan(live, PormG.Migrations._load_current_models(models_path),
                                               st.connections, st; interactive = false, lossy_alters = sink)
    _la803pg_quiet(() -> PormG.Migrations._write_pending_plan(st.connections, st, plan;
                                                            models_path = models_path, lossy_alters = sink))
    return sink
end

_la803pg_migrate(st; kw...) =
    _la803pg_quiet(() -> PormG.Migrations.migrate(st.connections, st; interactive = false, name = _LA803PG_NAME, kw...))
_la803pg_sql(st, sql) = DataFrame(PormG.ConnectionPool.fetch(st.connections, sql))
_la803pg_type(st, col) = _la803pg_sql(st, """
    SELECT format_type(atttypid, atttypmod) AS t FROM pg_attribute
     WHERE attrelid = '$(_LA803PG_TABLE)'::regclass AND attname = '$(col)'""").t[1]
_la803pg_err(f) = try f(); nothing catch e; e end

# Each case starts from the base table, created from its own plan, with the rows it needs.
function _la803pg_case(f, rows_sql::String)
    st = _la803pg_settings()
    try
        PormG.ConnectionPool.fetch(st.connections, "DROP TABLE IF EXISTS \"$(_LA803PG_TABLE)\";")
        _la803pg_plan!(st, _la803pg_models())
        @test _la803pg_migrate(st).outcome === :applied
        isempty(rows_sql) || PormG.ConnectionPool.fetch(st.connections, rows_sql)
        f(st)
    finally
        try; PormG.ConnectionPool.fetch(st.connections, "DROP TABLE IF EXISTS \"$(_LA803PG_TABLE)\";"); catch; end
        try; PormG.ConnectionPool.fetch(st.connections, "DELETE FROM pormg_migrations WHERE name = '$(_LA803PG_NAME)';"); catch; end
        try; PormG.Configuration.close_pool!(st.connections); catch; end
        rm(st.db_def_folder; recursive = true, force = true)
    end
end

const _LA803PG_INSERT = "INSERT INTO \"$(_LA803PG_TABLE)\" (code, big, points, note, grid, bytes) VALUES "

# ─────────────────────────────────────────────────────────────────────────────
# (a) A shorter VARCHAR over a longer value: counted, refused, then applied once the data fits
# PostgreSQL would fail the ALTER on the row and roll back; the pre-check says so first, with the
# count, and `destructive = true` does not change that. After the row is shortened the SAME plan
# applies, and the column really is `varchar(5)` — the plan's SQL is untouched by the header.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a shorter VARCHAR over a longer value is refused, then applies (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('abcdefghij', 1, 1.5, 'x', 1, NULL);") do st
        sink = _la803pg_plan!(st, _la803pg_models(code = "Models.CharField(max_length = 5, null = true)"))
        @test [(f.kind, f.column, f.bound) for f in sink] == [(:varchar_length, "code", 5)]
        @test only(PormG.Migrations.dry_run(st.connections, st).lossy_alters).rows == 1

        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test err !== nothing && only(err.findings).rows == 1
        @test _la803pg_type(st, "code") == "character varying(20)"

        PormG.ConnectionPool.fetch(st.connections, "UPDATE \"$(_LA803PG_TABLE)\" SET code = 'abc';")
        @test _la803pg_migrate(st).outcome === :applied
        @test _la803pg_type(st, "code") == "character varying(5)"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (b) bigint → integer over a value outside int32: refused
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: bigint → integer over 3e9 is refused (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 3000000000, 1.5, 'x', 1, NULL);") do st
        sink = _la803pg_plan!(st, _la803pg_models(big = "Models.IntegerField(null = true)"))
        @test [(f.kind, f.bound) for f in sink] == [(:integer_range, 32)]
        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test _la803pg_type(st, "big") == "bigint"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (c) A lower NUMERIC scale: applies, rounds, and so needs the destructive opt-in
# Nothing fails here — PostgreSQL rounds `1.2345` to `1.23` — which is exactly why it is data loss.
# Before #803 this applied with no opt-in and a log line; now it is refused without one, applies
# with one, and the history row records it as destructive.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a lower NUMERIC scale needs destructive = true, then rounds (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.2345, 'x', 1, NULL);") do st
        _la803pg_plan!(st, _la803pg_models(points = "Models.DecimalField(max_digits = 10, decimal_places = 2, null = true)"))
        @test PormG.Migrations.is_destructive(PormG.Migrations.dry_run(st.connections, st))

        err = _la803pg_err(() -> _la803pg_migrate(st))
        @test err isa PormG.Migrations.DestructiveMigrationError
        @test err !== nothing && [f.kind for f in err.lossy_alters] == [:decimal_scale]
        @test _la803pg_type(st, "points") == "numeric(10,4)"

        @test _la803pg_migrate(st; destructive = true).outcome === :applied
        @test string(_la803pg_sql(st, "SELECT points::text AS p FROM \"$(_LA803PG_TABLE)\";").p[1]) == "1.23"
        rec = _la803pg_sql(st, "SELECT is_destructive FROM pormg_migrations WHERE name = '$(_LA803PG_NAME)' ORDER BY id DESC LIMIT 1;")
        @test rec.is_destructive[1] == true
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (d) text → integer: refused, and PostgreSQL itself confirms it cannot run
# The deny-list entry is a claim about PostgreSQL: with no `USING`, the ALTER fails even on a table
# whose values would all convert. With the header line removed the plan goes to the server, which
# must refuse it — the live evidence that the refusal blocks nothing that would have worked.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: text → integer is refused as no_implicit_cast, as the server confirms (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, '42', 1, NULL);") do st
        sink = _la803pg_plan!(st, _la803pg_models(note = "Models.IntegerField(null = true)"))
        @test [f.kind for f in sink] == [:no_implicit_cast]
        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError

        pending = joinpath(st.db_def_folder, "migrations", "pending_migrations.jl")
        write(pending, join(filter(l -> !startswith(l, PormG.Migrations.LOSSY_ALTER_HEADER), readlines(pending)), "\n") * "\n")
        raw = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test raw !== nothing && !(raw isa PormG.Migrations.MigrationPrecheckError)
        @test raw !== nothing && occursin("cannot be cast automatically", sprint(showerror, raw))
        @test _la803pg_type(st, "note") == "text"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (e) SET NOT NULL over a NULL: refused, the column left nullable
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: SET NOT NULL over a NULL is refused (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, 'x', NULL, NULL);") do st
        _la803pg_plan!(st, _la803pg_models(grid = "Models.IntegerField()"))
        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test err !== nothing && only(err.findings).kind === :set_not_null
        @test _la803pg_sql(st, """SELECT attnotnull FROM pg_attribute
                                 WHERE attrelid = '$(_LA803PG_TABLE)'::regclass AND attname = 'grid'""").attnotnull[1] == false
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (f) Fewer NUMERIC whole digits over a value that no longer fits: counted and refused
# The one pre-check whose SQL does arithmetic on the server (`round`, `power`, the NaN exclusion),
# so it is run here rather than only rendered.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: fewer NUMERIC whole digits over a value that no longer fits is refused (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 123456.5, 'x', 1, NULL), ('HAM', 2, 99.994, 'y', 2, NULL);") do st
        sink = _la803pg_plan!(st, _la803pg_models(points = "Models.DecimalField(max_digits = 6, decimal_places = 4, null = true)"))
        @test [(f.kind, f.bound, f.scale) for f in sink] == [(:decimal_precision, 2, 4)]
        # 123456.5 needs six whole digits; 99.994 fits in two. One row fails.
        @test only(PormG.Migrations.dry_run(st.connections, st).lossy_alters).rows == 1
        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test _la803pg_type(st, "points") == "numeric(10,4)"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (g) A byte bound over a longer value: counted with `octet_length`, and refused
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a byte bound over a longer value is refused (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, 'x', 1, '\\x0102030405060708'::bytea);") do st
        sink = _la803pg_plan!(st, _la803pg_models(bytes = "Models.BinaryField(max_length = 4, null = true)"))
        @test [(f.kind, f.bound) for f in sink] == [(:byte_length_check, 4)]
        @test only(PormG.Migrations.dry_run(st.connections, st).lossy_alters).rows == 1
        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (h) A refused cast beside a new CHECK: `dry_run` reports it, it does not raise
# Text → PositiveIntegerField used to add a `"c" < 0` count on the text column, which PostgreSQL
# rejects as a query, so `dry_run` raised a database error instead of describing the plan.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: text → PositiveIntegerField is reported by dry_run, not raised (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, '-5', 1, NULL);") do st
        _la803pg_plan!(st, _la803pg_models(note = "Models.PositiveIntegerField(null = true)"))
        r = PormG.Migrations.dry_run(st.connections, st)
        @test [f.kind for f in r.lossy_alters] == [:no_implicit_cast]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (i) The row count runs before the migration lock, so `lock_wait` bounds it too
# Another session holds the table — the shape of a second instance mid-`ALTER`. Before #803 a
# booting instance waited on the ADVISORY lock, bounded by `lock_wait`; the count must not turn that
# into an unbounded wait on the table lock. Only the scratch table is locked, and only by this file.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: the row count waits on a held table no longer than lock_wait (#803)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, 'x', NULL, NULL);") do st
        _la803pg_plan!(st, _la803pg_models(grid = "Models.IntegerField()"))
        holder = PormG.ConnectionPool.acquire_connection(st.connections)
        try
            PormG.ConnectionPool.with_transaction(st.connections, "BEGIN;"; conn = holder)
            PormG.ConnectionPool.with_transaction(st.connections,
                "LOCK TABLE \"$(_LA803PG_TABLE)\" IN ACCESS EXCLUSIVE MODE;"; conn = holder)
            t0 = time()
            err = _la803pg_err(() -> _la803pg_migrate(st; lock_wait = 1))
            elapsed = time() - t0
            @test err !== nothing && !(err isa PormG.Migrations.MigrationPrecheckError)
            @test elapsed < 15   # ~1 s, not "until the holder commits"

            # While the count waits, its transaction's connection stays LEASED — the holder's and
            # the pre-check's, two in use. A `fetch(...; conn = leased)` used to hand it back to the
            # pool after the first statement, so another task could be given a connection with an
            # open READ ONLY transaction on it (#139's class). Measured mid-wait from another task.
            waiting = Threads.@spawn _la803pg_err(() -> _la803pg_migrate(st; lock_wait = 5))
            sleep(2)
            @test PormG.ConnectionPool._pool_in_use(st.connections) == 2
            @test fetch(waiting) !== nothing
            @test PormG.ConnectionPool._pool_in_use(st.connections) == 1   # released afterwards, once
        finally
            try; PormG.ConnectionPool.with_transaction(st.connections, "ROLLBACK;"; conn = holder); catch; end
            PormG.ConnectionPool.release_connection(st.connections, holder)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (j) A new NOT NULL column with no default: refused over rows, applied over an empty table (#829)
# PostgreSQL's `ADD COLUMN … NOT NULL` fails on the first existing row (`contains null values`). The
# column has no `ColumnDelta`, so #803 never recorded it; now the whole table is counted first. The
# empty case is the neighbour that must NOT be refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a new NOT NULL column is refused over rows, applied over none (#829)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, 'x', 1, NULL), ('PRO', 2, 2.5, 'y', 2, NULL);") do st
        sink = _la803pg_plan!(st, _la803pg_models(laps = "Models.IntegerField()"))
        @test [(f.kind, f.column) for f in sink] == [(:add_not_null, "laps")]
        @test only(PormG.Migrations.dry_run(st.connections, st).lossy_alters).rows == 2
        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test err !== nothing && only(err.findings).rows == 2
        # Nothing was written: the column is not there.
        @test isempty(_la803pg_sql(st, """
            SELECT 1 FROM pg_attribute WHERE attrelid = '$(_LA803PG_TABLE)'::regclass
               AND attname = 'laps' AND NOT attisdropped"""))

        # Emptied, the same plan applies and the column is NOT NULL.
        PormG.ConnectionPool.fetch(st.connections, "DELETE FROM \"$(_LA803PG_TABLE)\";")
        @test _la803pg_migrate(st).outcome === :applied
        @test _la803pg_sql(st, """
            SELECT attnotnull FROM pg_attribute WHERE attrelid = '$(_LA803PG_TABLE)'::regclass
               AND attname = 'laps'""").attnotnull == [true]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (k) `unique = true` over duplicate values: counted, refused, then applied (#830)
# PostgreSQL's `ADD UNIQUE` fails on the duplicates; NULLs are distinct and are not counted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: unique = true over duplicates is refused, then applies (#830)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, 'x', 1, NULL), ('SEN', 2, 2.5, 'y', 2, NULL), " *
                                    "(NULL, 3, 3.5, 'z', 3, NULL), (NULL, 4, 4.5, 'w', 4, NULL);") do st
        models = _la803pg_models(code = "Models.CharField(max_length = 20, null = true, unique = true)")
        sink = _la803pg_plan!(st, models)
        @test [(f.kind, f.column) for f in sink] == [(:add_unique, "code")]
        err = _la803pg_err(() -> _la803pg_migrate(st; destructive = true))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test err !== nothing && only(err.findings).rows == 2
        PormG.ConnectionPool.fetch(st.connections, "UPDATE \"$(_LA803PG_TABLE)\" SET code = 'PRO' WHERE big = 2;")
        @test _la803pg_migrate(st).outcome === :applied
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (l) A foreign key added over an orphan row: counted against the parent, refused, then applied (#830)
# Self-referencing, so the parent is the scratch table itself and nothing else in the fixture is
# planned. It starts as `db_constraint = false` (a plain column, no constraint) and becomes a key.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a foreign key over an orphan row is refused, then applies (#830)" begin
    _la803pg_case("") do st
        fk(c) = "Models.ForeignKey(\"Pormg_test_lossy803\", pk_field = \"id\", null = true, db_constraint = $c)"
        _la803pg_plan!(st, _la803pg_models(parent = fk(false)))
        @test _la803pg_migrate(st).outcome === :applied
        PormG.ConnectionPool.fetch(st.connections, _LA803PG_INSERT * "('SEN', 1, 1.5, 'x', 1, NULL), ('PRO', 2, 2.5, 'y', 2, NULL);")
        PormG.ConnectionPool.fetch(st.connections, "UPDATE \"$(_LA803PG_TABLE)\" SET parent = id + 1000 WHERE big = 2;")

        sink = _la803pg_plan!(st, _la803pg_models(parent = fk(true)))
        @test [(f.kind, f.column, f.references) for f in sink] == [(:add_foreign_key, "parent", (_LA803PG_TABLE, "id"))]
        err = _la803pg_err(() -> _la803pg_migrate(st))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test err !== nothing && only(err.findings).rows == 1
        PormG.ConnectionPool.fetch(st.connections, "UPDATE \"$(_LA803PG_TABLE)\" SET parent = NULL WHERE big = 2;")
        @test _la803pg_migrate(st).outcome === :applied
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# (m) A CheckConstraint over a failing row: the condition is evaluated by the server, inside the
# pre-check's READ ONLY transaction (#830)
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a CheckConstraint over a failing row is refused, then applies (#830)" begin
    _la803pg_case(_LA803PG_INSERT * "('SEN', 1, 1.5, 'x', -1, NULL), ('PRO', 2, 2.5, 'y', NULL, NULL);") do st
        models = _la803pg_models(constraints = "[Models.CheckConstraint(condition = \"grid >= 0\", name = \"pormg_test_lossy803_grid_ck\")]")
        sink = _la803pg_plan!(st, models)
        @test [f.kind for f in sink] == [:add_check]
        err = _la803pg_err(() -> _la803pg_migrate(st))
        @test err isa PormG.Migrations.MigrationPrecheckError
        @test err !== nothing && only(err.findings).rows == 1   # the NULL passes a CHECK
        PormG.ConnectionPool.fetch(st.connections, "UPDATE \"$(_LA803PG_TABLE)\" SET grid = 0 WHERE grid < 0;")
        @test _la803pg_migrate(st).outcome === :applied
    end
end

end # adapter_name
