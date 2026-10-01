# =============================================================================
# Lossy ALTERs: classified from the ColumnDelta, pre-checked against the rows (#803)
#
# The destructive guard reads SQL text, so it sees a `DROP` and nothing that merely NARROWS a
# column. #803 classifies what a column change can do to the rows already there from the column's
# `ColumnDelta`, records it in the plan header, and has `dry_run` / `migrate` act on it:
#
#   * `:rows`    — the ALTER fails on some rows. Counted first; `migrate` refuses any plan with a
#                  row that would fail, and `destructive = true` does not bypass that.
#   * `:silent`  — the ALTER changes values (a lower scale rounds). Needs `destructive = true`.
#   * `:refused` — PostgreSQL cannot apply it as rendered (text → integer, no `USING`).
#
# Hermetic: mock backends for the classifier and the SQL, temporary SQLite files end to end. The
# PostgreSQL half (a real narrowing on a real server) is test/integration/test_lossy_alter.jl.
# =============================================================================
# julia --project=test/integration test/unit/test_lossy_alters.jl

using Test
using Logging
using DataFrames
using PormG
# The end-to-end testsets open real (temporary) SQLite files, so they need the weakdep extension.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, Models, Dialect, PormGModel, PormGPostgres, PormGSQLite
import PormG: InvalidMigrationError
import PormG.Migrations: LossyAlter, LOSSY_ALTER_KINDS, column_delta, _lossy_alters, lossy_alter_class,
                         _lossy_alter_header, _plan_lossy_alters, _precheck_sql,
                         MigrationPrecheckError, DestructiveMigrationError
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import OrderedCollections: OrderedDict

# Suffixed names: `runtests.jl` includes every unit file into ONE module.
struct MockPgLa803 <: PormGPostgres end
struct MockSlLa803 <: PormGSQLite end
const PG_LA803 = MockPgLa803()
const SL_LA803 = MockSlLa803()
# The constraint-name lookups `alter_field` and the planner ask a PostgreSQL catalog for.
PormG.get_constraints_pk(::MockPgLa803, t::String, f::String) = nothing
PormG.get_constraints_unique(::MockPgLa803, t::String, f::String) = nothing
PormG.get_constraints_checks(::MockPgLa803, t::String, f::String) = String[]
PormG.get_constraints_byte_length_checks(::MockPgLa803, t::String, f::String) = String[]

# The kinds one change yields: `declared` is the models file, `live` the database (the planner's
# own argument order — new side first).
_la803_kinds(declared, live, conn) =
    [f.kind for f in _lossy_alters(column_delta(declared, live, conn; name = "c"), conn; table = "t", column = "c")]
_la803_one(declared, live, conn) =
    only(_lossy_alters(column_delta(declared, live, conn; name = "c"), conn; table = "t", column = "c"))

# ─────────────────────────────────────────────────────────────────────────────
# Classifier: every kind, each beside a change that must NOT be flagged
# A false positive costs the operator an opt-in (or, for `:refused`, blocks a valid migration), so
# each flagged case sits next to the nearest harmless one. The SQLite column is the engine
# asymmetry: it enforces no length, width or scale, so narrowings there flag nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the classifier reads the delta: each kind and its harmless neighbour" begin
    M = Models
    # NULL → NOT NULL, on both engines; the reverse and an unchanged NOT NULL are harmless.
    for conn in (PG_LA803, SL_LA803)
        @test _la803_kinds(M.IntegerField(), M.IntegerField(null = true), conn) == [:set_not_null]
        @test isempty(_la803_kinds(M.IntegerField(null = true), M.IntegerField(), conn))
        @test isempty(_la803_kinds(M.IntegerField(), M.IntegerField(), conn))
    end

    # A shorter VARCHAR fails on PostgreSQL; widening does not; SQLite never enforces a length.
    @test _la803_kinds(M.CharField(max_length = 5), M.CharField(max_length = 40), PG_LA803) == [:varchar_length]
    @test _la803_one(M.CharField(max_length = 5), M.CharField(max_length = 40), PG_LA803).bound == 5
    @test _la803_kinds(M.CharField(max_length = 5), M.TextField(), PG_LA803) == [:varchar_length]
    @test isempty(_la803_kinds(M.CharField(max_length = 40), M.CharField(max_length = 5), PG_LA803))
    @test isempty(_la803_kinds(M.CharField(max_length = 5), M.CharField(max_length = 40), SL_LA803))

    # A narrower integer can overflow on PostgreSQL; widening cannot. On SQLite `IntegerField →
    # PositiveIntegerField` reads as `CInt64 → CInt32` (both INTEGER affinity) — it must NOT be an
    # integer narrowing, but it does add a `>= 0` CHECK that existing rows must pass.
    @test _la803_kinds(M.IntegerField(), M.BigIntegerField(), PG_LA803) == [:integer_range]
    @test _la803_one(M.IntegerField(), M.BigIntegerField(), PG_LA803).bound == 32
    @test isempty(_la803_kinds(M.BigIntegerField(), M.IntegerField(), PG_LA803))
    @test _la803_kinds(M.PositiveIntegerField(), M.IntegerField(), SL_LA803) == [:non_negative_check]
    @test _la803_kinds(M.PositiveIntegerField(), M.IntegerField(), PG_LA803) == [:non_negative_check]
    @test isempty(_la803_kinds(M.IntegerField(), M.PositiveIntegerField(), SL_LA803))
    @test isempty(_la803_kinds(M.IntegerField(), M.PositiveIntegerField(), PG_LA803))

    # A float to an integer both rounds and can overflow — two findings for one column. A decimal
    # with no fraction that always fits a bigint does neither.
    @test _la803_kinds(M.IntegerField(), M.FloatField(), PG_LA803) == [:to_integer, :integer_range]
    @test isempty(_la803_kinds(M.BigIntegerField(), M.DecimalField(max_digits = 10, decimal_places = 0), PG_LA803))

    # NUMERIC: fewer whole digits and a lower scale are both reported; raising them is harmless; the
    # equal-whole-digits case still fails through the rounding carry (`9.999` → `10.00`).
    @test _la803_kinds(M.DecimalField(max_digits = 8, decimal_places = 2),
                       M.DecimalField(max_digits = 12, decimal_places = 2), PG_LA803) == [:decimal_precision]
    @test _la803_kinds(M.DecimalField(max_digits = 3, decimal_places = 2),
                       M.DecimalField(max_digits = 4, decimal_places = 3), PG_LA803) == [:decimal_precision, :decimal_scale]
    carry = _la803_kinds(M.DecimalField(max_digits = 10, decimal_places = 2),
                         M.DecimalField(max_digits = 12, decimal_places = 4), PG_LA803)
    @test carry == [:decimal_precision, :decimal_scale]
    precision = _la803_one(M.DecimalField(max_digits = 8, decimal_places = 2),
                           M.DecimalField(max_digits = 12, decimal_places = 2), PG_LA803)
    @test (precision.bound, precision.scale) == (6, 2)
    @test isempty(_la803_kinds(M.DecimalField(max_digits = 12, decimal_places = 4),
                               M.DecimalField(max_digits = 10, decimal_places = 2), PG_LA803))
    @test isempty(_la803_kinds(M.DecimalField(max_digits = 10, decimal_places = 4),
                               M.DecimalField(max_digits = 10, decimal_places = 2), SL_LA803))

    # Time: a timestamp to a date or a time drops half of it; the widening directions are harmless.
    @test _la803_kinds(M.DateField(), M.DateTimeField(), PG_LA803) == [:to_date]
    @test _la803_kinds(M.TimeField(), M.DateTimeField(), PG_LA803) == [:to_time]
    @test _la803_kinds(M.DateTimeField(type = "TIMESTAMP"), M.DateTimeField(), PG_LA803) == [:drop_timezone]
    @test isempty(_la803_kinds(M.DateTimeField(), M.DateField(), PG_LA803))
    @test isempty(_la803_kinds(M.DateTimeField(), M.DateTimeField(type = "TIMESTAMP"), PG_LA803))

    # No automatic cast: text → integer cannot run on PostgreSQL at all. The reverse, and the types
    # the renderer DOES cast with a `USING` (interval, time, bytea), are not refused.
    @test _la803_kinds(M.IntegerField(), M.CharField(), PG_LA803) == [:no_implicit_cast]
    @test _la803_kinds(M.BooleanField(), M.CharField(), PG_LA803) == [:no_implicit_cast]
    @test isempty(_la803_kinds(M.TextField(), M.IntegerField(), PG_LA803))
    @test isempty(_la803_kinds(M.DurationField(), M.IntegerField(), PG_LA803))
    @test isempty(_la803_kinds(M.TimeField(), M.CharField(), PG_LA803))
    @test isempty(_la803_kinds(M.BinaryField(), M.CharField(), PG_LA803))

    # SQLite's one type-driven change of VALUE: text under a numeric affinity (`'0042'` → `42`).
    @test _la803_kinds(M.IntegerField(), M.CharField(), SL_LA803) == [:text_affinity]
    @test isempty(_la803_kinds(M.CharField(), M.IntegerField(), SL_LA803))

    # A byte bound added or lowered is checked against the rows; raising it is not.
    @test _la803_kinds(M.BinaryField(max_length = 16), M.BinaryField(), SL_LA803) == [:byte_length_check]
    @test _la803_kinds(M.BinaryField(max_length = 16), M.BinaryField(max_length = 64), PG_LA803) == [:byte_length_check]
    @test isempty(_la803_kinds(M.BinaryField(max_length = 64), M.BinaryField(max_length = 16), PG_LA803))

    # Every kind the classifier can emit belongs to the closed table, with one of the three classes.
    @test Set(values(LOSSY_ALTER_KINDS)) == Set([:rows, :silent, :refused])
    @test lossy_alter_class(_la803_one(M.IntegerField(), M.CharField(), PG_LA803)) === :refused
end

# ─────────────────────────────────────────────────────────────────────────────
# Classifier: a side the compiler could not read is never classified
# `CUnsupported` (a catalog type PormG never renders, or a degraded spec) says nothing about what the
# column holds, so no kind may be inferred from it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unreadable side is never classified" begin
    live = PormG.ColumnSpec("c", PormG.CUnsupported("character(12)"), true, false, false, PormG.NoDefault(),
                            nothing, PormG.CheckKind[], nothing, "character(12)")
    delta = column_delta(Models.CharField(max_length = 5), live, PG_LA803; name = "c")
    @test :type in delta
    # The nullability change is still a real fact; only the type side is unreadable.
    @test [f.kind for f in _lossy_alters(delta, PG_LA803; table = "t", column = "c")] == [:set_not_null]
end

# ─────────────────────────────────────────────────────────────────────────────
# The sink: recorded where the delta becomes an action, under the catalog's names
# The pre-check runs before anything executes, so a renamed column must be recorded under the name
# the live table still has. The plan itself is unchanged by collecting the findings.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the planner records a finding under the pre-rename column, and the plan is unchanged" begin
    settings = Configuration.Settings()
    settings.change_db = true
    live = Models.Model("race803"; id = Models.IDField(), name = Models.CharField(max_length = 40, null = true))
    declared = Models.Model("race803"; id = Models.IDField(), title = Models.CharField(max_length = 40))
    schema() = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :race803 => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
    # One rename candidate, answered "1" on stdin; the planner prints its question to stdout.
    function plan_with(sink)
        answer, io = mktemp(); write(io, "1\n"); close(io)
        open(answer) do stdin_file
            redirect_stdin(stdin_file) do
                redirect_stdout(devnull) do
                    Migrations.get_migration_plan(PormGModel[live], schema(), PG_LA803, settings;
                                                  interactive = true, lossy_alters = sink)
                end
            end
        end
    end
    sink = LossyAlter[]
    with_sink = plan_with(sink)
    # The rename and the NOT NULL are both planned, and the finding names the OLD column.
    @test any(k -> startswith(k, "Rename field"), keys(with_sink[:race803]))
    @test [(f.kind, f.table, f.column) for f in sink] == [(:set_not_null, "race803", "name")]
    # Collecting findings changes nothing about the plan.
    @test plan_with(LossyAlter[]) == with_sink
end

# ─────────────────────────────────────────────────────────────────────────────
# The plan header: written by `generate_migration_plan`, read back by `_plan_lossy_alters`
# The finding is the only record of what a column held before; the SQL cannot say. Values are
# escaped (#710), so a tab, a newline or a quote in a catalog name round-trips; the checksum and a
# finding-free plan are untouched; a damaged line is refused rather than silently dropped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the plan header round-trips, stays outside the checksum, and refuses a damaged line" begin
    dir = mktempdir()
    try
        plan = OrderedDict{Symbol, OrderedDict{String, String}}(
            :race803 => OrderedDict{String, String}("Alter field: c" => """ALTER TABLE "race803" ALTER COLUMN "c" SET NOT NULL;"""))
        findings = [LossyAlter(:set_not_null, "race\t803", "c\n\"\$x", "varchar(5)", "varchar(5)"),
                    LossyAlter(:decimal_precision, "race803", "points", "numeric(12,2)", "numeric(8,2)"; bound = 6, scale = 2)]

        # With and without findings: identical SQL, identical checksum.
        PormG.Generator.generate_migration_plan("with.jl", plan, dir; lossy_alters = findings)
        PormG.Generator.generate_migration_plan("without.jl", plan, dir)
        @test _plan_lossy_alters(joinpath(dir, "with.jl")) == findings
        @test isempty(_plan_lossy_alters(joinpath(dir, "without.jl")))
        order(f) = Migrations._order_statements(Migrations._read_migration_plan(joinpath(dir, f)))
        @test order("with.jl") == order("without.jl")

        # A plan without findings is byte-identical to one written by the pre-#803 call shape (below
        # the `module` line, which is named after the file).
        PormG.Generator.generate_migration_plan("empty_tuple.jl", plan, dir; lossy_alters = ())
        @test readlines(joinpath(dir, "empty_tuple.jl"))[2:end] == readlines(joinpath(dir, "without.jl"))[2:end]

        # Each header line starts at column 0 under the format marker, one per finding.
        lines = readlines(joinpath(dir, "with.jl"))
        @test count(l -> startswith(l, Migrations.LOSSY_ALTER_HEADER), lines) == 2

        # A damaged line: missing field, unknown kind, non-integer bound — each refused.
        with = read(joinpath(dir, "with.jl"), String)
        for (damage, needle) in ((l -> replace(l, r"\tcolumn=[^\t]*" => ""), "no `column`"),
                                 (l -> replace(l, "kind=set_not_null" => "kind=shrug"), "unknown kind"),
                                 (l -> replace(l, "bound=6" => "bound=six"), "not an integer"))
            damaged = join([startswith(l, Migrations.LOSSY_ALTER_HEADER) ? damage(l) : l for l in split(with, '\n')], '\n')
            write(joinpath(dir, "damaged.jl"), damaged)
            err = try _plan_lossy_alters(joinpath(dir, "damaged.jl")); nothing catch e; e end
            @test err isa InvalidMigrationError
            @test err !== nothing && occursin(needle, sprint(showerror, err))
        end

        # A line below the first `import` is not a header — the plan body cannot plant one.
        write(joinpath(dir, "late.jl"), replace(read(joinpath(dir, "without.jl"), String),
              "import OrderedCollections: OrderedDict" =>
              "import OrderedCollections: OrderedDict\n" * _lossy_alter_header(findings[2])))
        @test isempty(_plan_lossy_alters(joinpath(dir, "late.jl")))
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The pre-check SQL: identifiers escaped, bounds bound
# The table and column come back from a file, so they get the same `""` escape every plan
# statement's identifiers get, and every limit is a parameter — never interpolated.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the pre-check SQL escapes its identifiers and binds its bounds" begin
    f(kind; kw...) = LossyAlter(kind, "Ev\"il", "c", "a", "b"; kw...)
    @test _precheck_sql(PG_LA803, f(:set_not_null)) ==
          ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE \"c\" IS NULL", Any[])
    @test _precheck_sql(PG_LA803, f(:varchar_length; bound = 5)) ==
          ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE char_length(rtrim(CAST(\"c\" AS text))) > \$1::integer", Any[5])
    @test _precheck_sql(PG_LA803, f(:integer_range; bound = 16)) ==
          ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE round(CAST(\"c\" AS numeric)) NOT BETWEEN \$1::numeric AND \$2::numeric",
           Any[-32768, 32767])
    @test _precheck_sql(PG_LA803, f(:decimal_precision; bound = 1, scale = 2))[2] == Any[2, 1]
    @test _precheck_sql(PG_LA803, f(:non_negative_check))[1] == "SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE \"c\" < 0"
    # SQLite has no `octet_length`, and `?` placeholders.
    @test _precheck_sql(SL_LA803, f(:byte_length_check; bound = 16)) ==
          ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE length(CAST(\"c\" AS BLOB)) > ?", Any[16])
    # The other two classes count nothing.
    @test _precheck_sql(PG_LA803, f(:decimal_scale; scale = 2)) === nothing
    @test _precheck_sql(PG_LA803, f(:no_implicit_cast)) === nothing
end

# ── End to end on a temporary SQLite database ────────────────────────────────────────────────────

# The F1 race table: `name` nullable in v1, `code` text, `laps` a plain integer.
function _la803_models(; name = "Models.CharField(null = true)", code = "Models.CharField(null = true)",
                         laps = "Models.IntegerField(null = true)")
    return "module models\nimport PormG.Models\nRace803 = Models.Model(\n    id = Models.IDField(),\n" *
           "    name = $name,\n    code = $code,\n    laps = $laps\n)\nend\n"
end
_la803_quiet(f) = with_logger(f, NullLogger())
_la803_history(pool) = DataFrame(fetch(pool, "SELECT COUNT(*) AS n FROM pormg_migrations;")).n[1]
_la803_notnull(pool, col) =
    only(DataFrame(fetch(pool, "PRAGMA table_info(race803);")) |> d -> d[d.name .== col, :notnull])

# A connection registered under `key`, the way the `String` forms find it. Restores the global config.
function _la803_with_key(f, tag::String)
    saved = copy(PormG.config)
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath(tag)
            pool = SQLiteConnectionPool(joinpath(dir, "$(tag).sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = tag)
            settings.change_db = true
            PormG.config[tag] = settings
            write(joinpath(tag, "models.jl"), _la803_models())
            _la803_quiet(() -> Migrations.makemigrations(tag; interactive = false))
            _la803_quiet(() -> Migrations.migrate(tag; interactive = false))
            f(tag, pool)
        end
    finally
        pool === nothing || close_pool!(pool)
        empty!(PormG.config); merge!(PormG.config, saved)
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# SET NOT NULL over a NULL row: named, counted, refused before any write — then applied
# The whole #803 story on one column. A declared default does not rescue the row (neither engine
# backfills an existing NULL from one), so the count is still 1. `destructive = true` is passed
# throughout — a SQLite rebuild is destructive anyway — to show the pre-check is not bypassed by it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: SET NOT NULL over a NULL row is counted and refused, then applies once fixed" begin
    _la803_with_key("la803nn") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES (NULL, 'MON', 78);")
        write(joinpath(key, "models.jl"), _la803_models(name = "Models.CharField(default = \"TBA\")"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        pending = joinpath(key, "migrations", "pending_migrations.jl")
        @test [f.kind for f in _plan_lossy_alters(pending)] == [:set_not_null]

        # dry_run counts the row and says migrate() will refuse; the regex half still sees the rebuild.
        r = Migrations.dry_run(key)
        @test only(r.lossy_alters).rows == 1
        @test occursin("WOULD FAIL", sprint(show, r))

        # Refused before any write: no history row, the column still nullable, the row intact.
        history = _la803_history(pool)
        err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)); nothing catch e; e end
        @test err isa MigrationPrecheckError
        @test err isa PormG.MigrationError
        @test only(err.findings).column == "name" && only(err.findings).rows == 1
        @test occursin("1 row(s) would fail", sprint(showerror, err))
        @test _la803_history(pool) == history
        @test _la803_notnull(pool, "name") == 0
        @test isfile(pending)

        # Fixed data: the same plan now counts 0 and applies.
        fetch(pool, "UPDATE race803 SET name = 'Monaco';")
        @test only(Migrations.dry_run(key).lossy_alters).rows == 0
        @test _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied
        @test _la803_notnull(pool, "name") == 1
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The premise: without the header, the database itself refuses — and rolls back
# The pre-check predicts a failure; it does not create one. Deleting the header line (a hand edit)
# leaves the plan to the engine, which fails the rebuild's `INSERT … SELECT` and rolls the whole
# migration back: the row and the nullable column survive.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: with the header removed, the engine refuses the same plan and rolls back" begin
    _la803_with_key("la803raw") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES (NULL, 'MON', 78);")
        write(joinpath(key, "models.jl"), _la803_models(name = "Models.CharField()"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        pending = joinpath(key, "migrations", "pending_migrations.jl")
        write(pending, join(filter(l -> !startswith(l, Migrations.LOSSY_ALTER_HEADER), readlines(pending)), "\n") * "\n")
        @test isempty(_plan_lossy_alters(pending))

        err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)); nothing catch e; e end
        @test err !== nothing && !(err isa MigrationPrecheckError)
        @test _la803_notnull(pool, "name") == 0
        @test DataFrame(fetch(pool, "SELECT COUNT(*) AS n FROM race803;")).n[1] == 1
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite text affinity: `'0042'` becomes `42` — a silent change, behind the destructive opt-in
# The rebuild was already destructive (it drops the old table); what #803 adds is that the error and
# `dry_run` now NAME the value change, instead of a DROP TABLE the operator did not write.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: text under a numeric affinity is named, and changes only with destructive = true" begin
    _la803_with_key("la803aff") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('Monaco', '0042', 78);")
        write(joinpath(key, "models.jl"), _la803_models(code = "Models.IntegerField(null = true)"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))

        @test Migrations.is_destructive(Migrations.dry_run(key))
        err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false)); nothing catch e; e end
        @test err isa DestructiveMigrationError
        @test [f.kind for f in err.lossy_alters] == [:text_affinity]
        @test occursin("text_affinity", sprint(showerror, err))

        @test _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied
        @test DataFrame(fetch(pool, "SELECT code FROM race803;")).code[1] == 42
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a new `>= 0` CHECK is counted against the rows (IntegerField → PositiveIntegerField)
# The SQLite reading of this change used to look like an integer narrowing (`CInt64 → CInt32`); it
# is the CHECK that matters, and a negative row is what fails it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a new non-negative CHECK refuses a negative row, and applies over clean data" begin
    _la803_with_key("la803chk") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('Monaco', 'MON', -1);")
        write(joinpath(key, "models.jl"), _la803_models(laps = "Models.PositiveIntegerField(null = true)"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))

        err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)); nothing catch e; e end
        @test err isa MigrationPrecheckError
        @test only(err.findings).kind === :non_negative_check

        fetch(pool, "UPDATE race803 SET laps = 78;")
        @test _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A stale header: a finding about a column the database does not have is dropped, with a warning
# A hand-edited plan can outlive what its header describes. Refusing on a column that is not there
# would block a plan for no reason; silently ignoring the line would hide the edit.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a header naming a column the database lacks is ignored with a warning" begin
    _la803_with_key("la803stale") do key, pool
        write(joinpath(key, "models.jl"), _la803_models(name = "Models.CharField()"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        pending = joinpath(key, "migrations", "pending_migrations.jl")
        write(pending, replace(read(pending, String), "column=name" => "column=ghost"))
        r = @test_logs (:warn, r"database does not have") match_mode = :any Migrations.dry_run(key)
        @test isempty(r.lossy_alters)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# DryRunResult display: multibyte SQL, and the three lossy sections
# `show` sliced by BYTE (`s[1:120]`), which throws `StringIndexError` when the cut lands inside a
# multibyte character — a table name or default in Portuguese is enough.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DryRunResult shows multibyte SQL and each lossy class" begin
    long = """ALTER TABLE "corridas" DROP COLUMN "situação"; -- """ * repeat("ã", 200)
    silent = LossyAlter(:decimal_scale, "results", "points", "numeric(10,4)", "numeric(10,2)"; scale = 2)
    failing = LossyAlter(:set_not_null, "results", "grid", "integer", "integer"; rows = 3)
    counted_ok = LossyAlter(:set_not_null, "results", "laps", "integer", "integer"; rows = 0)
    r = Migrations.DryRunResult("0"^64, [long], [long], [silent, failing, counted_ok])
    out = sprint(show, r)
    @test occursin("CHANGES EXISTING VALUES", out) && occursin("decimal_scale", out)
    @test occursin("WOULD FAIL: 1", out) && occursin("3 row(s) would fail", out)
    @test !occursin("\"laps\"", out)
    @test Migrations.is_destructive(Migrations.DryRunResult("0"^64, String[], String[], [silent]))
    @test !Migrations.is_destructive(Migrations.DryRunResult("0"^64, String[], String[], [failing]))
    @test occursin("Safe", sprint(show, Migrations.DryRunResult("0"^64, String[], String[], [counted_ok])))
end

# ─────────────────────────────────────────────────────────────────────────────
# Dialect.alter_field no longer re-decides the lower scale with a private @warn
# That warning was an action site's own opinion of a fact the delta settles; the `:decimal_scale`
# finding replaces it, and the renderer only renders.
# ─────────────────────────────────────────────────────────────────────────────
@testset "alter_field renders a lower scale without a warning of its own" begin
    declared = Models.DecimalField(max_digits = 10, decimal_places = 2)
    delta = column_delta(declared, Models.DecimalField(max_digits = 10, decimal_places = 4), PG_LA803; name = "points")
    sql = @test_logs min_level = Logging.Warn Dialect.alter_field(PG_LA803, "results", "points", declared, delta)
    @test occursin("TYPE DECIMAL(10, 2)", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# Review fixes: a refused cast stands alone, and a CHECK is only counted where it can be
# `CharField → PositiveIntegerField` used to yield `:non_negative_check` beside the refusal, and its
# count (`"c" < 0` on a varchar) was a query PostgreSQL rejects — `dry_run` raised a database error
# instead of reporting the plan. Integer ↔ boolean is refused in both directions.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a refused cast is the only finding, and a CHECK is only counted where it can be" begin
    M = Models
    @test _la803_kinds(M.PositiveIntegerField(), M.CharField(), PG_LA803) == [:no_implicit_cast]
    @test _la803_kinds(M.PositiveIntegerField(), M.BooleanField(), PG_LA803) == [:no_implicit_cast]
    @test _la803_kinds(M.BooleanField(), M.IntegerField(), PG_LA803) == [:no_implicit_cast]
    @test _la803_kinds(M.IntegerField(), M.CharField(null = true), PG_LA803) == [:no_implicit_cast]
    # `octet_length` exists for bytea and strings only on PostgreSQL; SQLite measures anything.
    @test isempty(_la803_kinds(M.BinaryField(max_length = 16), M.IntegerField(), PG_LA803))
    @test _la803_kinds(M.BinaryField(max_length = 16), M.CharField(), PG_LA803) == [:byte_length_check]
    @test _la803_kinds(M.BinaryField(max_length = 16), M.IntegerField(), SL_LA803) == [:byte_length_check]
    # SQLite text → PositiveIntegerField: both the value change and the CHECK, counted on the NUMBER.
    @test _la803_kinds(M.PositiveIntegerField(), M.CharField(), SL_LA803) == [:non_negative_check, :text_affinity]
    @test _precheck_sql(SL_LA803, LossyAlter(:non_negative_check, "t", "c", "a", "b"))[1] ==
          "SELECT COUNT(*) AS n FROM \"t\" WHERE CAST(\"c\" AS REAL) < 0"
    # A constrained numeric accepts NaN, so it is not a failing row.
    @test occursin("<> 'NaN'::numeric", _precheck_sql(PG_LA803, LossyAlter(:decimal_precision, "t", "c", "a", "b"; bound = 1, scale = 2))[1])
end

# ─────────────────────────────────────────────────────────────────────────────
# Review fix: a header line missing the limit its kind is counted against is refused
# Without the bound, `varchar_length` would bind NULL, count 0 and pass the plan silently; an
# `integer_range` with a width PormG never writes used to raise a bare KeyError.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a header line without its kind's limit is refused, not counted as zero" begin
    for (line, needle) in (("kind=varchar_length\ttable=t\tcolumn=c\told=a\tnew=b", "no `bound`"),
                           ("kind=decimal_precision\ttable=t\tcolumn=c\told=a\tnew=b\tbound=6", "no `scale`"),
                           ("kind=byte_length_check\ttable=t\tcolumn=c\told=a\tnew=b", "no `bound`"),
                           ("kind=integer_range\ttable=t\tcolumn=c\told=a\tnew=b\tbound=8", "integer width"))
        err = try Migrations._parse_lossy_alter_header(line, "p.jl"); nothing catch e; e end
        @test err isa InvalidMigrationError
        @test err !== nothing && occursin(needle, sprint(showerror, err))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review fix: a renamed TABLE's finding is recorded under its old name
# The rename runs in the same migration, after the pre-check, so the count must name the table the
# database still has. A real temporary SQLite table, renamed and tightened at once.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a table rename records its finding under the pre-rename table" begin
    mktempdir() do dir
        pool = SQLiteConnectionPool(joinpath(dir, "la803rt.sqlite"); pool_size = 1)
        try
            settings = Configuration.Settings(); settings.change_db = true
            schema(m) = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
                Symbol(Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormGModel}}(:model => m, :exist => false))
            old_t = Models.Model("circuits_old803"; id = Models.IDField(), laps = Models.IntegerField(null = true))
            new_t = Models.Model("circuits_new803"; id = Models.IDField(), laps = Models.IntegerField())
            created = Migrations.get_migration_plan(Migrations.LiveTable[], schema(old_t), pool, settings; interactive = false)
            for stmt in first(Migrations._order_statements([created[k] for k in keys(created)]))
                for part in Migrations._split_sqlite_statements(stmt)
                    fetch(pool, part)
                end
            end
            sink = LossyAlter[]
            answer, io = mktemp(); write(io, "no\n1\n"); close(io)
            plan = open(answer) do stdin_file
                redirect_stdin(stdin_file) do
                    redirect_stdout(devnull) do
                        Migrations.get_migration_plan(Migrations.read_live_schema(pool), schema(new_t), pool, settings;
                                                      interactive = true, lossy_alters = sink)
                    end
                end
            end
            @test haskey(plan[:circuits_new803], "Rename table")
            @test [(f.kind, f.table, f.column) for f in sink] == [(:set_not_null, "circuits_old803", "laps")]
        finally
            close_pool!(pool)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review fix: the row pre-check runs BEFORE the destructive guard
# A plan with a failing row AND a value-changing column, run without the opt-in: the refusal must
# be the row one — the opt-in would not help, so asking for it would send the operator the wrong way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a failing row is reported before the destructive opt-in is asked for" begin
    _la803_with_key("la803ord") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES (NULL, '0042', 78);")
        write(joinpath(key, "models.jl"), _la803_models(name = "Models.CharField()", code = "Models.IntegerField(null = true)"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false)); nothing catch e; e end
        @test err isa MigrationPrecheckError
        fetch(pool, "UPDATE race803 SET name = 'Monaco';")
        @test _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review fix: SQLite counts a text '-5' as the -5 its INTEGER column will store
# Compared as text, `'-5' < 0` is false and the plan would pass the pre-check, then fail the new
# CHECK inside the rebuild. Counted as the number the rebuild stores, it is refused up front.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: text '-5' moving into a PositiveIntegerField is counted as a failing row" begin
    _la803_with_key("la803neg") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('Monaco', '-5', 78);")
        write(joinpath(key, "models.jl"), _la803_models(code = "Models.PositiveIntegerField(null = true)"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        r = Migrations.dry_run(key)
        @test only(filter(f -> f.kind === :non_negative_check, r.lossy_alters)).rows == 1
        err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)); nothing catch e; e end
        @test err isa MigrationPrecheckError
    end
end

# =============================================================================
# #829: a NEW NOT NULL column with no default
# It has no `ColumnDelta` — `_add_new_field` plans it, not `_plan_column_change!` — so #803 never
# saw it. PostgreSQL's `ADD COLUMN … NOT NULL` fails on the first existing row; SQLite's refused it
# on every table, even an empty one. Now it is an `:add_not_null` finding counted against the whole
# table, and SQLite adds the column nullable and tightens it in the rebuild, so both engines fail
# exactly when the table has rows — and the pre-check refuses that before any write.
# =============================================================================

_la829_kinds(field, conn; temporary_default = nothing) =
    [f.kind for f in Migrations._lossy_add_column(Migrations.column_spec(field, conn; name = "grid"), conn;
                                                  table = "t", temporary_default = temporary_default)]

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#829): the added-column classifier and its harmless neighbours
# Only a NOT NULL column with nothing to fill the existing rows is a finding. A default, a db_default,
# the planner's temporary default (#607) and an identity all fill them; a nullable column needs none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#829: a new NOT NULL defaultless column is a finding; anything that fills the rows is not" begin
    M = Models
    for conn in (PG_LA803, SL_LA803)
        @test _la829_kinds(M.IntegerField(), conn) == [:add_not_null]
        @test _la829_kinds(M.CharField(max_length = 3), conn) == [:add_not_null]
        @test isempty(_la829_kinds(M.IntegerField(null = true), conn))
        @test isempty(_la829_kinds(M.IntegerField(default = 0), conn))
        @test isempty(_la829_kinds(M.DateTimeField(db_default = "CURRENT_TIMESTAMP"), conn))
        # #607: a NOT NULL temporal column gets a temporary default the plan later drops.
        @test isempty(_la829_kinds(M.DateTimeField(), conn; temporary_default = "1970-01-01"))
        # The engine fills an identity itself.
        @test isempty(_la829_kinds(M.IDField(), conn))
    end
    # The finding names the table and column, with no old type: the column does not exist yet.
    f = only(Migrations._lossy_add_column(Migrations.column_spec(Models.IntegerField(), PG_LA803; name = "grid"),
                                          PG_LA803; table = "race829"))
    @test (f.table, f.column, f.old_type) == ("race829", "grid", "")
    @test lossy_alter_class(f) === :rows
    # The summary says what is being added rather than an arrow from an empty type.
    @test Migrations._lossy_alter_summary(f) == "\"race829\".\"grid\": add_not_null ($(f.new_type))"
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#829): recorded by the planner under the catalog's table name
# `_add_new_field` is reached from `_resolve_table_fields`; the finding must land in the same sink
# the column changes use, so `makemigrations` writes it into the header beside them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#829: the planner records the added column, and only the defaultless NOT NULL one" begin
    settings = Configuration.Settings()
    settings.change_db = true
    live = Models.Model("race829"; id = Models.IDField(), name = Models.CharField(max_length = 40))
    declared = Models.Model("race829"; id = Models.IDField(), name = Models.CharField(max_length = 40),
                            grid = Models.IntegerField(), laps = Models.IntegerField(default = 0),
                            fastest = Models.IntegerField(null = true))
    schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :race829 => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
    sink = LossyAlter[]
    plan = Migrations.get_migration_plan(PormGModel[live], schema, PG_LA803, settings;
                                         interactive = false, lossy_alters = sink)
    @test [(f.kind, f.table, f.column) for f in sink] == [(:add_not_null, "race829", "grid")]
    # PostgreSQL's ADD COLUMN is unchanged: NOT NULL, as declared.
    @test plan[:race829]["Add field: grid"] == "ALTER TABLE \"race829\" ADD COLUMN \"grid\" integer NOT NULL;"
end

@testset "#829: the pre-check counts every row of the table" begin
    f = LossyAlter(:add_not_null, "Ev\"il", "grid", "", "INTEGER")
    @test _precheck_sql(PG_LA803, f) == ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\"", Any[])
    @test _precheck_sql(SL_LA803, f) == ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\"", Any[])
end

# The race table of `_la803_models` with one more column, `grid`.
_la829_models(grid) = replace(_la803_models(), "\n)\nend" => ",\n    grid = $grid\n)\nend")
_la829_columns(pool) = String.(DataFrame(fetch(pool, "PRAGMA table_info(race803);")).name)

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#829): SQLite end to end — an empty table takes the column, a populated one is refused
# Before #829 SQLite refused `ADD COLUMN … NOT NULL` with no default even on an EMPTY table. The
# column is now added nullable and the rebuild declares it NOT NULL, so the empty table applies; with
# a row, the pre-check counts it and refuses before any write, naming the two ways through.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite #829: an empty table takes a new NOT NULL column; a populated one is refused first" begin
    _la803_with_key("la829empty") do key, pool
        write(joinpath(key, "models.jl"), _la829_models("Models.IntegerField()"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        pending = joinpath(key, "migrations", "pending_migrations.jl")
        @test [f.kind for f in _plan_lossy_alters(pending)] == [:add_not_null]
        # The ADD COLUMN is nullable; the rebuild that follows declares NOT NULL.
        statements = Migrations.dry_run(key).statements
        add = only(filter(s -> occursin("ADD COLUMN \"grid\"", s), statements))
        @test occursin("\"grid\" INTEGER NULL", add)
        @test only(Migrations.dry_run(key).lossy_alters).rows == 0
        @test _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied
        @test _la803_notnull(pool, "grid") == 1
    end

    _la803_with_key("la829rows") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('Monaco', 'MON', 78);")
        write(joinpath(key, "models.jl"), _la829_models("Models.IntegerField()"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        history = _la803_history(pool)
        err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)); nothing catch e; e end
        @test err isa MigrationPrecheckError
        @test err !== nothing && only(err.findings).kind === :add_not_null && only(err.findings).rows == 1
        # The message names both ways through.
        msg = err === nothing ? "" : sprint(showerror, err)
        @test occursin("declare a `default`", msg) && occursin("`null = true`", msg)
        # Nothing was written: no history row, no column.
        @test _la803_history(pool) == history
        @test !("grid" in _la829_columns(pool))
    end

    # The neighbour: a declared default fills the existing row, so there is no finding and it applies.
    _la803_with_key("la829default") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('Monaco', 'MON', 78);")
        write(joinpath(key, "models.jl"), _la829_models("Models.IntegerField(default = 0)"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        @test isempty(_plan_lossy_alters(joinpath(key, "migrations", "pending_migrations.jl")))
        @test _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied
        @test DataFrame(fetch(pool, "SELECT grid FROM race803;")).grid == [0]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#829): a header for an added column the table already has is stale
# For a changed column, "stale" means the column is gone; for an added one it is the opposite — the
# column already exists, because the plan was applied (the #81 re-archive) or edited by hand.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite #829: an added-column finding applies only while the column is absent" begin
    _la803_with_key("la829stale") do key, pool
        absent = LossyAlter(:add_not_null, "race803", "grid", "", "INTEGER")
        present = LossyAlter(:add_not_null, "race803", "laps", "", "INTEGER")
        no_table = LossyAlter(:add_not_null, "race_gone", "grid", "", "INTEGER")
        @test Migrations._finding_applies(pool, absent)
        @test !Migrations._finding_applies(pool, present)
        @test !Migrations._finding_applies(pool, no_table)
        # Counted, the stale ones dropped with a warning.
        counted = @test_logs (:warn,) (:warn,) Migrations._precheck_lossy_alters(pool, [absent, present, no_table])
        @test [(f.column, f.rows) for f in counted] == [("grid", 0)]
    end
end
