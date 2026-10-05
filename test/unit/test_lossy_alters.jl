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

    # No automatic cast: text → integer runs only through the `USING` the renderer writes since #828,
    # which parses each value — so it is counted (`:text_cast`), not refused. The reverse, and the
    # types the renderer has always cast (interval, time, bytea), are not findings at all.
    @test _la803_kinds(M.IntegerField(), M.CharField(), PG_LA803) == [:text_cast]
    @test _la803_kinds(M.BooleanField(), M.CharField(), PG_LA803) == [:text_cast]
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
    @test lossy_alter_class(_la803_one(M.IntegerField(), M.CharField(), PG_LA803)) === :rows
    @test lossy_alter_class(LossyAlter(:no_implicit_cast, "t", "c", "a", "b")) === :refused
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
# `handled=pre`: the operator's mark that a `Data (pre)` step fixes a finding's rows (#897)
# It round-trips like any other field, and it is the one header field written by a person, so
# it is checked like a damaged line. Only `pre` exists. Only a counted (`:rows`) kind can be
# handled. A plan with no `Data (pre):` step to back it is refused, or the mark would be a bare
# "skip the pre-check" switch. A handled finding is counted but never refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "handled=pre round-trips, is validated, and needs a Data (pre) step (#897)" begin
    dir = mktempdir()
    try
        alter = OrderedDict{String, String}("Alter field: c" => """ALTER TABLE "race897" ALTER COLUMN "c" SET NOT NULL;""")
        fill = OrderedDict{String, String}("Data (pre): fill c" => """UPDATE "race897" SET "c" = 'x' WHERE "c" IS NULL;""")
        handled = LossyAlter(:set_not_null, "race897", "c", "varchar(5)", "varchar(5)"; handled = :pre)
        backed = OrderedDict{Symbol, OrderedDict{String, String}}(:race897 => alter, :aaa_fill => fill)
        bare = OrderedDict{Symbol, OrderedDict{String, String}}(:race897 => alter)

        PormG.Generator.generate_migration_plan("backed.jl", backed, dir; lossy_alters = [handled])
        @test occursin("\thandled=pre", read(joinpath(dir, "backed.jl"), String))
        @test _plan_lossy_alters(joinpath(dir, "backed.jl")) == [handled]

        # No `Data (pre):` step in the plan: refused, naming the field and the missing step.
        PormG.Generator.generate_migration_plan("bare.jl", bare, dir; lossy_alters = [handled])
        err = try _plan_lossy_alters(joinpath(dir, "bare.jl")); nothing catch e; e end
        @test err isa InvalidMigrationError
        @test err !== nothing && occursin("handled=pre", sprint(showerror, err)) &&
              occursin("no `Data (pre):` step", sprint(showerror, err))

        # A value other than `pre`, and a kind with no count to skip: refused as damaged lines.
        silent = LossyAlter(:decimal_scale, "race897", "c", "numeric(8,2)", "numeric(8,1)")
        PormG.Generator.generate_migration_plan("silent.jl", backed, dir; lossy_alters = [silent])
        text = read(joinpath(dir, "backed.jl"), String)
        for (damaged, needle) in ((replace(text, "handled=pre" => "handled=post"), "not `pre`"),
                                  (replace(read(joinpath(dir, "silent.jl"), String),
                                           r"# pormg-lossy-alter: [^\n]*" => l -> l * "\thandled=pre"),
                                   "only a change whose rows are counted"))
            write(joinpath(dir, "damaged.jl"), damaged)
            err = try _plan_lossy_alters(joinpath(dir, "damaged.jl")); nothing catch e; e end
            @test err isa InvalidMigrationError
            @test err !== nothing && occursin(needle, sprint(showerror, err))
        end

        # The field a person types, typed wrong: a near-miss key, or spaces where the tab goes (the
        # mark would land inside `new=`). Each refused naming the mark, never read as no mark at all.
        # A new NOT NULL column is refused too: the `pre` step runs before its ADD COLUMN.
        added = LossyAlter(:add_not_null, "race897", "grid", "", "INTEGER")
        PormG.Generator.generate_migration_plan("added.jl", backed, dir; lossy_alters = [added])
        for (damaged, needle) in ((replace(text, "\thandled=pre" => "\tHandled=pre"), "reads like `handled`"),
                                  (replace(text, "\thandled=pre" => "  handled=pre"), "with a tab, not spaces"),
                                  (replace(read(joinpath(dir, "added.jl"), String),
                                           r"# pormg-lossy-alter: [^\n]*" => l -> l * "\thandled=pre"),
                                   "before the column is added"))
            write(joinpath(dir, "damaged.jl"), damaged)
            err = try _plan_lossy_alters(joinpath(dir, "damaged.jl")); nothing catch e; e end
            @test err isa InvalidMigrationError
            @test err !== nothing && occursin(needle, sprint(showerror, err))
        end

        # A CHECK condition is SQL the developer wrote, and may itself say `handled = 1`: not a mark.
        check = LossyAlter(:add_check, "race897", "is_handled", "", ""; condition = "status <> 0 AND handled = 1")
        checked = OrderedDict{Symbol, OrderedDict{String, String}}(:race897 => OrderedDict{String, String}(
            "Create check constraint: is_handled" =>
                """ALTER TABLE "race897" ADD CONSTRAINT "is_handled" CHECK (status <> 0 AND handled = 1);"""))
        PormG.Generator.generate_migration_plan("check.jl", checked, dir; lossy_alters = [check])
        @test _plan_lossy_alters(joinpath(dir, "check.jl")) == [check]

        # Counted, not refused: the same finding with rows is failing unmarked and not failing marked.
        counted(f) = Migrations._with_rows(f, 3)
        unmarked = LossyAlter(:set_not_null, "race897", "c", "varchar(5)", "varchar(5)")
        @test Migrations._failing_alters([counted(unmarked)]) == [counted(unmarked)]
        @test isempty(Migrations._failing_alters([counted(handled)]))
        @test Migrations._handled_alters([counted(handled), counted(unmarked)]) == [counted(handled)]
        @test occursin("3 row(s) for a `Data (pre)` step to fix", Migrations._lossy_alter_summary(counted(handled)))
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
# `v1` is the models file the database starts from.
function _la803_with_key(f, tag::String; v1::String = _la803_models())
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
            write(joinpath(tag, "models.jl"), v1)
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
    r = Migrations.DryRunResult("0"^64, [long], [long], [silent, failing, counted_ok], String[])
    out = sprint(show, r)
    @test occursin("CHANGES EXISTING VALUES", out) && occursin("decimal_scale", out)
    @test occursin("WOULD FAIL: 1", out) && occursin("3 row(s) would fail", out)
    @test !occursin("\"laps\"", out)
    @test Migrations.is_destructive(Migrations.DryRunResult("0"^64, String[], String[], [silent], String[]))
    @test !Migrations.is_destructive(Migrations.DryRunResult("0"^64, String[], String[], [failing], String[]))
    @test occursin("Safe", sprint(show, Migrations.DryRunResult("0"^64, String[], String[], [counted_ok], String[])))
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
# Review fixes: across a castless pair a CHECK is not counted, and a CHECK is only counted where it can be
# `CharField → PositiveIntegerField` used to yield `:non_negative_check` beside the refusal, and its
# count (`"c" < 0` on a varchar) was a query PostgreSQL rejects — `dry_run` raised a database error
# instead of reporting the plan. Since #828 the pair runs through a `USING`, so it is counted as a
# `:text_cast`, and the column is still text (or boolean) when the count runs: the CHECK stays the
# database's. Integer → boolean changes values; boolean → integer loses nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a castless pair carries no CHECK count, and a CHECK is only counted where it can be" begin
    M = Models
    @test _la803_kinds(M.PositiveIntegerField(), M.CharField(), PG_LA803) == [:text_cast]
    @test isempty(_la803_kinds(M.PositiveIntegerField(), M.BooleanField(), PG_LA803))
    @test _la803_kinds(M.BooleanField(), M.IntegerField(), PG_LA803) == [:to_boolean]
    @test _la803_kinds(M.IntegerField(), M.CharField(null = true), PG_LA803) == [:set_not_null, :text_cast]
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

# =============================================================================
# #830: constraint adds the rows already there can violate
# UNIQUE, PRIMARY KEY, a composite UniqueConstraint, a CheckConstraint and a foreign key were not
# pre-counted: such a plan failed inside its transaction, rolled back and left a `failed` history
# row. Each is now a `:rows` finding, recorded where the action is planned and counted with the
# predicate the engine itself enforces.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#830): UNIQUE and PRIMARY KEY read off the column delta
# A key column is unique too, so becoming the key is ONE finding. Dropping either, or keeping it,
# is harmless.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#830: unique and primary key added to a column are findings; removed or kept are not" begin
    M = Models
    for conn in (PG_LA803, SL_LA803)
        @test _la803_kinds(M.IntegerField(unique = true), M.IntegerField(), conn) == [:add_unique]
        @test isempty(_la803_kinds(M.IntegerField(), M.IntegerField(unique = true), conn))
        @test isempty(_la803_kinds(M.IntegerField(unique = true), M.IntegerField(unique = true), conn))
    end
    # Becoming the key: built from specs, since only a few field structs take `primary_key` at all.
    key(pk, uq) = PormG.ColumnSpec("c", PormG.CInt64(), false, pk, uq, PormG.NoDefault(), nothing,
                                   PormG.CheckKind[], nothing, "BIGINT")
    kinds(new, old) = [f.kind for f in _lossy_alters(PormG.ColumnDelta(new, old, PormG.column_delta(new, old)),
                                                     PG_LA803; table = "t", column = "c")]
    @test kinds(key(true, false), key(false, false)) == [:add_primary_key]
    @test kinds(key(true, true), key(false, false)) == [:add_primary_key]   # one finding, not two
    @test kinds(key(true, true), key(false, true)) == [:add_primary_key]
    @test isempty(kinds(key(false, false), key(true, true)))
end

# A ColumnSpec with a foreign key to `table`.`column` (or none), for the delta-level FK classifier.
_la830_spec(ref; type = PormG.CInt64(), raw = "BIGINT") =
    PormG.ColumnSpec("circuitid", type, true, false, false, PormG.NoDefault(),
                     ref === nothing ? nothing : PormG.ForeignKeyRef(ref[1], nothing, ref[2], "CASCADE"),
                     PormG.CheckKind[], nothing, raw)
_la830_fk(new, old) = Migrations._lossy_foreign_key(PormG.ColumnDelta(new, old, PormG.column_delta(new, old));
                                                    table = "race830", column = "circuitid")

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#830): a foreign key added or re-pointed, and the cases that cannot be counted
# The count compares the child column with the parent key, so it needs the parent's physical table
# and the child's CURRENT type; without either there is no finding and the database checks the key.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#830: a foreign key added or re-pointed is a finding with its parent" begin
    f = only(_la830_fk(_la830_spec(("circuit830", "id")), _la830_spec(nothing)))
    @test (f.kind, f.table, f.column, f.references) == (:add_foreign_key, "race830", "circuitid", ("circuit830", "id"))
    @test length(_la830_fk(_la830_spec(("track830", "id")), _la830_spec(("circuit830", "id")))) == 1   # re-pointed
    @test isempty(_la830_fk(_la830_spec(("circuit830", "id")), _la830_spec(("circuit830", "id"))))      # unchanged
    @test isempty(_la830_fk(_la830_spec(nothing), _la830_spec(("circuit830", "id"))))                   # dropped
    @test isempty(_la830_fk(_la830_spec((nothing, "id")), _la830_spec(nothing)))                         # parent unknown
    # Retyped in the same change: the count would compare the OLD type with the parent key.
    @test isempty(_la830_fk(_la830_spec(("circuit830", "id")), _la830_spec(nothing; type = PormG.CText(), raw = "TEXT")))
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#830): the pre-check SQL for each constraint kind
# Duplicates exclude NULLs (both engines treat NULLs as distinct); a primary key also counts NULLs on
# PostgreSQL only; a CHECK counts rows where the condition is FALSE; an orphan is a non-NULL value no
# parent holds. Identifiers are escaped like every other plan identifier.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#830: the pre-check SQL counts duplicates, NULL keys, failing checks and orphans" begin
    dups(col) = "SELECT COALESCE(SUM(n), 0) AS n FROM (SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE $col IS NOT NULL " *
                "GROUP BY $col HAVING COUNT(*) > 1) AS pormg_duplicates"
    unique = LossyAlter(:add_unique, "Ev\"il", "c", "INTEGER", "INTEGER")
    for conn in (PG_LA803, SL_LA803)
        @test _precheck_sql(conn, unique) == ("SELECT CAST(($(dups("\"c\""))) AS BIGINT) AS n", Any[])
    end
    pk = LossyAlter(:add_primary_key, "Ev\"il", "c", "INTEGER", "INTEGER")
    @test _precheck_sql(PG_LA803, pk) ==
          ("SELECT CAST(($(dups("\"c\""))) + (SELECT COUNT(*) FROM \"Ev\"\"il\" WHERE \"c\" IS NULL) AS BIGINT) AS n", Any[])
    @test _precheck_sql(SL_LA803, pk) == _precheck_sql(SL_LA803, unique)

    comp = LossyAlter(:add_composite_unique, "Ev\"il", "uq", "", ""; columns = ["a", "b\"c"])
    @test _precheck_sql(PG_LA803, comp) ==
          ("SELECT CAST((SELECT COALESCE(SUM(n), 0) AS n FROM (SELECT COUNT(*) AS n FROM \"Ev\"\"il\" " *
           "WHERE \"a\" IS NOT NULL AND \"b\"\"c\" IS NOT NULL GROUP BY \"a\", \"b\"\"c\" HAVING COUNT(*) > 1) " *
           "AS pormg_duplicates) AS BIGINT) AS n", Any[])

    check = LossyAlter(:add_check, "Ev\"il", "ck", "", ""; condition = "laps >= 0")
    @test _precheck_sql(SL_LA803, check) == ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE NOT (laps >= 0)", Any[])

    fk = LossyAlter(:add_foreign_key, "Ev\"il", "circuitid", "BIGINT", "BIGINT"; references = ("cir\"cuit", "id"))
    @test _precheck_sql(PG_LA803, fk) ==
          ("SELECT COUNT(*) AS n FROM \"Ev\"\"il\" AS pormg_child WHERE pormg_child.\"circuitid\" IS NOT NULL " *
           "AND NOT EXISTS (SELECT 1 FROM \"cir\"\"cuit\" AS pormg_parent " *
           "WHERE pormg_parent.\"id\" = pormg_child.\"circuitid\")", Any[])
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#830): the header carries members, parent and condition — and the condition is
# trusted only when the plan itself adds that CHECK
# The CHECK condition is the one value the pre-check interpolates into SQL. The header sits outside
# what `migrate` executes, so a condition that no plan statement carries is refused as damage.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#830: the header round-trips the new fields, and an unplanned CHECK condition is refused" begin
    dir = mktempdir()
    try
        cond = "laps >= 0 AND name <> 'a\tb'"
        plan = OrderedDict{Symbol, OrderedDict{String, String}}(
            :race830 => OrderedDict{String, String}(
                "Create check constraint: ck" => "ALTER TABLE \"race830\" ADD CONSTRAINT \"ck\" CHECK ($cond);"))
        findings = [LossyAlter(:add_composite_unique, "race830", "uq", "", ""; columns = ["name", "co,de\t"]),
                    LossyAlter(:add_foreign_key, "race830", "circuitid", "BIGINT", "BIGINT"; references = ("circuit830", "id")),
                    LossyAlter(:add_check, "race830", "ck", "", ""; condition = cond)]
        PormG.Generator.generate_migration_plan("p.jl", plan, dir; lossy_alters = findings)
        @test _plan_lossy_alters(joinpath(dir, "p.jl")) == findings

        # A condition the plan does not add — here, the same CHECK widened in the header only.
        text = read(joinpath(dir, "p.jl"), String)
        write(joinpath(dir, "tampered.jl"), replace(text, "condition=laps >= 0" => "condition=laps >= 0 OR true OR laps >= 0"))
        err = try _plan_lossy_alters(joinpath(dir, "tampered.jl")); nothing catch e; e end
        @test err isa InvalidMigrationError
        @test err !== nothing && occursin("names a condition no statement in the plan adds", sprint(showerror, err))

        # Each kind without the field it counts against is refused, not counted as zero.
        for (damage, needle) in ((r"\tmember=[^\t]*" => "", "no `member`"),
                                 (r"\tref_table=[^\t]*" => "", "no `ref_table`"),
                                 (r"\tcondition=[^\t\n]*" => "", "no `condition`"))
            write(joinpath(dir, "damaged.jl"), replace(text, damage))
            err = try _plan_lossy_alters(joinpath(dir, "damaged.jl")); nothing catch e; e end
            @test err isa InvalidMigrationError
            @test err !== nothing && occursin(needle, sprint(showerror, err))
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

# A two-table models file for the FK case: the race's `circuitid` points at `Circuit830`, with
# `db_constraint` as given (`false` declares no constraint at all, so `true` is an `:add`).
_la830_fk_models(db_constraint) =
    "module models\nimport PormG.Models\nCircuit830 = Models.Model(\n    id = Models.IDField(),\n" *
    "    name = Models.CharField(null = true)\n)\nRace803 = Models.Model(\n    id = Models.IDField(),\n" *
    "    name = Models.CharField(null = true),\n" *
    "    circuitid = Models.ForeignKey(\"Circuit830\", pk_field = \"id\", null = true, db_constraint = $db_constraint)\n)\nend\n"

# The race table of `_la803_models` with a `constraints = [...]` list.
_la830_models(constraint; kw...) = replace(_la803_models(; kw...), "\n)\nend" => ",\n    constraints = [$constraint]\n)\nend")

# Refused with `rows` counted, nothing written; returns the error.
function _la830_refused(key, pool, kind, rows)
    _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
    @test [f.kind for f in _plan_lossy_alters(joinpath(key, "migrations", "pending_migrations.jl"))] == [kind]
    history = _la803_history(pool)
    err = try _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)); nothing catch e; e end
    @test err isa MigrationPrecheckError
    @test err !== nothing && only(err.findings).kind === kind && only(err.findings).rows == rows
    @test _la803_history(pool) == history
    return err
end
_la830_applies(key) = _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#830): SQLite end to end, one case per constraint kind
# Each starts from rows that violate the new constraint: refused before any write with the offending
# rows counted (NULLs never count as duplicates), then the same plan applies once the data is fixed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite #830: unique = true over duplicates is counted and refused, then applies" begin
    _la803_with_key("la830uq") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code) VALUES ('Monaco', 'MON'), ('Monte Carlo', 'MON'), " *
                    "('Spa', 'SPA'), ('Imola', NULL), ('Monza', NULL);")
        write(joinpath(key, "models.jl"), _la803_models(code = "Models.CharField(null = true, unique = true)"))
        _la830_refused(key, pool, :add_unique, 2)
        fetch(pool, "UPDATE race803 SET code = 'MCO' WHERE name = 'Monte Carlo';")
        @test _la830_applies(key)
    end
end

@testset "SQLite #830: a UniqueConstraint over duplicate tuples is counted and refused, then applies" begin
    _la803_with_key("la830comp") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code) VALUES ('Monaco', 'MON'), ('Monaco', 'MON'), " *
                    "('Monaco', NULL), ('Monaco', NULL);")
        write(joinpath(key, "models.jl"), _la830_models("Models.UniqueConstraint(fields = (\"name\", \"code\"))"))
        err = _la830_refused(key, pool, :add_composite_unique, 2)
        @test err !== nothing && only(err.findings).columns == ("name", "code")
        fetch(pool, "DELETE FROM race803 WHERE id = (SELECT MAX(id) FROM race803 WHERE code = 'MON');")
        @test _la830_applies(key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#934): a partial UniqueConstraint counts only the rows its condition matches
# Counting the whole table would refuse duplicates the constraint never covers, so the condition rides
# in the header — interpolated into the count only when the plan's own CREATE UNIQUE INDEX carries
# it and the models file still declares it (the CHECK rule). A condition the models no longer vouch
# for drops the finding: the database checks the index when the plan runs. A functional one has no
# columns to group by, so it records no finding at all.
# Mutation gate: drop `where = f.condition` from `_precheck_sql` and the end-to-end count is 3, not 2.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#934: a partial UniqueConstraint's duplicates are counted under its condition" begin
    comp = LossyAlter(:add_composite_unique, "race934", "uq", "", ""; columns = ["code"], condition = "laps > 0")
    @test _precheck_sql(SL_LA803, comp) ==
          ("SELECT CAST((SELECT COALESCE(SUM(n), 0) AS n FROM (SELECT COUNT(*) AS n FROM \"race934\" " *
           "WHERE \"code\" IS NOT NULL AND (laps > 0) GROUP BY \"code\" HAVING COUNT(*) > 1) " *
           "AS pormg_duplicates) AS BIGINT) AS n", Any[])

    # The header round-trips it, and a condition no planned CREATE UNIQUE INDEX carries is refused.
    dir = mktempdir()
    try
        plan = OrderedDict{Symbol, OrderedDict{String, String}}(
            :race934 => OrderedDict{String, String}(
                "Create unique constraint: uq" =>
                    "CREATE UNIQUE INDEX \"uq\" ON \"race934\" (\"code\" /* pormg:index:0123456789abcdef */) WHERE laps > 0;"))
        PormG.Generator.generate_migration_plan("p.jl", plan, dir; lossy_alters = [comp])
        @test _plan_lossy_alters(joinpath(dir, "p.jl")) == [comp]
        text = read(joinpath(dir, "p.jl"), String)
        write(joinpath(dir, "tampered.jl"), replace(text, "condition=laps > 0" => "condition=laps > 0 OR 1 = 1"))
        err = try _plan_lossy_alters(joinpath(dir, "tampered.jl")); nothing catch e; e end
        @test err isa InvalidMigrationError
        @test err !== nothing && occursin("kind `add_composite_unique` names a condition no statement", sprint(showerror, err))
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "SQLite #934: a partial UniqueConstraint is counted under its condition, refused, then applies" begin
    _la803_with_key("la934part") do key, pool
        # MON twice among the rows the condition covers (laps > 0) — two duplicates. SPA twice, and a
        # third MON, among the rows it does not cover — never counted.
        fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('Monaco', 'MON', 78), ('Monte Carlo', 'MON', 77), " *
                    "('Spa', 'SPA', 0), ('Spa 2', 'SPA', 0), ('Monaco 2020', 'MON', NULL);")
        write(joinpath(key, "models.jl"),
              _la830_models("Models.UniqueConstraint(fields = (\"code\",), condition = \"laps > 0\", name = \"race803_code_raced\")"))
        err = _la830_refused(key, pool, :add_composite_unique, 2)
        @test err !== nothing && only(err.findings).condition == "laps > 0"
        fetch(pool, "UPDATE race803 SET laps = 0 WHERE name = 'Monte Carlo';")
        @test _la830_applies(key)
        # The index PormG built is the partial one, and it enforces exactly that.
        ddl = only(DataFrame(fetch(pool, "SELECT sql FROM sqlite_master WHERE name = 'race803_code_raced'")).sql)
        @test occursin("WHERE laps > 0", ddl) && occursin("pormg:index:", ddl)
        @test (try fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('X', 'SPA', 0);"); true catch; false end)
        @test (try fetch(pool, "INSERT INTO race803 (name, code, laps) VALUES ('Y', 'MON', 5);"); true catch; false end) == false
    end
end

@testset "SQLite #934: a functional UniqueConstraint records no finding; an unvouched condition is not counted" begin
    _la803_with_key("la934fn") do key, pool
        fetch(pool, "INSERT INTO race803 (name, code) VALUES ('Monaco', 'mon'), ('Spa', 'SPA');")
        write(joinpath(key, "models.jl"),
              _la830_models("Models.UniqueConstraint(expressions = (\"lower(code)\",), name = \"race803_code_ci\")"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        @test isempty(_plan_lossy_alters(joinpath(key, "migrations", "pending_migrations.jl")))
        @test _la830_applies(key)
    end
    _la803_with_key("la934anchor") do key, pool
        write(joinpath(key, "models.jl"),
              _la830_models("Models.UniqueConstraint(fields = (\"code\",), condition = \"laps > 0\", name = \"race803_code_raced\")"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        found = _plan_lossy_alters(joinpath(key, "migrations", "pending_migrations.jl"))
        @test only(found).condition == "laps > 0"
        @test only(Migrations._anchor_check_conditions(found, PormG.config[key])).condition == "laps > 0"
        # The models file changed since the plan: the header's condition is no longer vouched for, so
        # the finding is dropped rather than counted over the whole table.
        write(joinpath(key, "models.jl"),
              _la830_models("Models.UniqueConstraint(fields = (\"code\",), condition = \"laps > 1\", name = \"race803_code_raced\")"))
        @test isempty(_la803_quiet(() -> Migrations._anchor_check_conditions(found, PormG.config[key])))
    end
end

@testset "SQLite #830: a CheckConstraint some rows fail is counted and refused, then applies" begin
    _la803_with_key("la830ck") do key, pool
        fetch(pool, "INSERT INTO race803 (name, laps) VALUES ('Monaco', 78), ('Spa', -1), ('Monza', NULL);")
        write(joinpath(key, "models.jl"),
              _la830_models("Models.CheckConstraint(condition = \"laps >= 0\", name = \"race803_laps_ck\")"))
        _la830_refused(key, pool, :add_check, 1)   # NULL passes a CHECK, so it is not counted
        fetch(pool, "UPDATE race803 SET laps = 1 WHERE laps < 0;")
        @test _la830_applies(key)
    end
end

@testset "SQLite #830: a CHECK naming a column the same plan adds is not counted, and applies" begin
    _la803_with_key("la830cknew") do key, pool
        fetch(pool, "INSERT INTO race803 (name, laps) VALUES ('Monaco', 78);")
        models = replace(_la830_models("Models.CheckConstraint(condition = \"grid >= 0\", name = \"race803_grid_ck\")"),
                         "\n    constraints" => "\n    grid = Models.IntegerField(null = true),\n    constraints")
        write(joinpath(key, "models.jl"), models)
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        @test isempty(_plan_lossy_alters(joinpath(key, "migrations", "pending_migrations.jl")))
        @test _la830_applies(key)
    end
end

@testset "SQLite #830: a tampered CHECK condition in the header is refused by dry_run and migrate" begin
    _la803_with_key("la830tamper") do key, pool
        write(joinpath(key, "models.jl"),
              _la830_models("Models.CheckConstraint(condition = \"laps >= 0\", name = \"race803_laps_ck\")"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        pending = joinpath(key, "migrations", "pending_migrations.jl")
        write(pending, replace(read(pending, String), "condition=laps >= 0" => "condition=1 = 1"))
        @test (try Migrations.dry_run(key); nothing catch e; e end) isa InvalidMigrationError
        @test (try _la803_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)); nothing catch e; e end) isa InvalidMigrationError
    end
end

@testset "SQLite #830: a foreign key added over orphan rows is counted and refused, then applies" begin
    _la803_with_key("la830fk"; v1 = _la830_fk_models(false)) do key, pool
        fetch(pool, "INSERT INTO circuit830 (name) VALUES ('Monaco');")
        fetch(pool, "INSERT INTO race803 (name, circuitid) VALUES ('Monaco GP', 1), ('Ghost GP', 99), ('TBA', NULL);")
        write(joinpath(key, "models.jl"), _la830_fk_models(true))
        err = _la830_refused(key, pool, :add_foreign_key, 1)   # NULL has no parent to miss
        @test err !== nothing && only(err.findings).references == ("circuit830", "id")
        fetch(pool, "UPDATE race803 SET circuitid = NULL WHERE circuitid = 99;")
        @test _la830_applies(key)
    end
end

# =============================================================================
# #828: PostgreSQL retypes with no automatic cast get a USING
# Text into a number, boolean, date, timestamp, UUID or JSON, and boolean ↔ a number, have no
# assignment cast, so a bare `ALTER COLUMN … TYPE` failed on every table, even an empty one. #803
# refused them up front; the renderer now writes the `USING`, and the classifier turns each refusal
# into what the cast can actually do to the rows: text that does not parse fails (`:text_cast`,
# counted), a number becomes `true`/`false` (`:to_boolean`, an opt-in), a boolean becomes 1/0 (nothing).
# =============================================================================

const _LA828_TEXT_TARGETS = (Models.IntegerField(), Models.BigIntegerField(),
                             Models.FloatField(), Models.DecimalField(max_digits = 8, decimal_places = 2),
                             Models.BooleanField(), Models.DateField(), Models.DateTimeField(),
                             Models.UUIDField(), Models.JSONField())
const _LA828_NUMBERS = (Models.IntegerField(), Models.BigIntegerField(), Models.FloatField(),
                        Models.DecimalField(max_digits = 8, decimal_places = 2))

# The ALTER the PostgreSQL planner writes for one live → declared change of column `c` on table `t`.
function _la828_alter(declared, live)
    settings = Configuration.Settings()
    settings.change_db = true
    live_model = Models.Model("t828"; id = Models.IDField(), c = live)
    declared_model = Models.Model("t828"; id = Models.IDField(), c = declared)
    schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :t828 => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))
    plan = Migrations.get_migration_plan(PormGModel[live_model], schema, PG_LA803, settings; interactive = false)
    return plan[:t828]["Alter field: c"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#828): every castless pair is rendered with its USING
# The type in the `USING` is the one the `TYPE` clause names, so the two cannot disagree. A pair
# PostgreSQL casts by itself (integer → text, integer → bigint) is rendered exactly as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#828: every castless pair is rendered with a USING, and other retypes are unchanged" begin
    # `alter_field`'s DecimalField branch spells its own `DECIMAL(p, s)`; every other one renders the type.
    type_sql(f) = f isa Models.sDecimalField ? "DECIMAL($(f.max_digits), $(f.decimal_places))" :
                                               Dialect._get_column_type(f, PG_LA803)
    for target in _LA828_TEXT_TARGETS, live in (Models.CharField(max_length = 20), Models.TextField())
        @test _la828_alter(target, live) ==
              "ALTER TABLE \"t828\" ALTER COLUMN \"c\" TYPE $(type_sql(target)) USING CAST(\"c\" AS $(type_sql(target)));"
    end
    for n in _LA828_NUMBERS
        @test _la828_alter(n, Models.BooleanField()) ==
              "ALTER TABLE \"t828\" ALTER COLUMN \"c\" TYPE $(type_sql(n)) USING CAST(CAST(\"c\" AS integer) AS $(type_sql(n)));"
        @test _la828_alter(Models.BooleanField(), n) ==
              "ALTER TABLE \"t828\" ALTER COLUMN \"c\" TYPE $(type_sql(Models.BooleanField())) USING (\"c\" <> 0);"
    end
    # No USING where PostgreSQL has its own cast.
    @test _la828_alter(Models.TextField(), Models.IntegerField()) ==
          "ALTER TABLE \"t828\" ALTER COLUMN \"c\" TYPE $(type_sql(Models.TextField()));"
    @test _la828_alter(Models.BigIntegerField(), Models.IntegerField()) ==
          "ALTER TABLE \"t828\" ALTER COLUMN \"c\" TYPE $(type_sql(Models.BigIntegerField()));"
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#828): the classifier no longer refuses a pair that has a USING
# `_pg_no_implicit_cast` still names every castless pair; the renderer now covers all of them, so
# none is `:no_implicit_cast` any more. The kind stays for a plan written before #828, whose SQL has
# no USING — `migrate` still refuses that header.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#828: text is counted, a number into a boolean needs the opt-in, a boolean into a number is free" begin
    for target in _LA828_TEXT_TARGETS
        @test _la803_kinds(target, Models.CharField(), PG_LA803) == [:text_cast]
    end
    for n in _LA828_NUMBERS
        @test isempty(_la803_kinds(n, Models.BooleanField(), PG_LA803))
        @test _la803_kinds(Models.BooleanField(), n, PG_LA803) == [:to_boolean]
    end
    @test lossy_alter_class(LossyAlter(:to_boolean, "t", "c", "a", "b")) === :silent
    # A pre-#828 plan's header is still refused, whatever the opt-in.
    @test Migrations._failing_alters([LossyAlter(:no_implicit_cast, "t", "c", "text", "integer")]) ==
          [LossyAlter(:no_implicit_cast, "t", "c", "text", "integer")]
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#828): the text_cast count — pg_input_is_valid on 16+, the input grammar below it
# On 16+ the server's own parser answers, typmod included, so an overflow counts as a failing value.
# Before 16 the integer, numeric, float, boolean and UUID grammars are matched as anchored regexes
# (with the range / precision check the parser would apply), and a date, timestamp or JSON value
# cannot be verified at all, so every non-NULL one counts.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#828: the text_cast count asks the server's parser on 16+, and the input grammar below it" begin
    f(new) = LossyAlter(:text_cast, "Ev\"il", "c", "VARCHAR(20)", new)
    base = "SELECT COUNT(*) AS n FROM \"Ev\"\"il\" WHERE \"c\" IS NOT NULL AND "
    @test _precheck_sql(PG_LA803, f("INTEGER"); server_version = 160004) ==
          (base * "pg_input_is_valid(CAST(\"c\" AS text), \$1) IS FALSE", Any["INTEGER"])
    @test _precheck_sql(PG_LA803, f("DECIMAL(8, 2)"); server_version = 170000)[2] == Any["DECIMAL(8, 2)"]

    # PostgreSQL 15: an integer is its grammar plus the width's range.
    sql, params = _precheck_sql(PG_LA803, f("SMALLINT"); server_version = 150008)
    @test sql == base * "CASE WHEN CAST(\"c\" AS text) ~ \$1 THEN CAST(CAST(\"c\" AS text) AS numeric) " *
                        "NOT BETWEEN \$2::numeric AND \$3::numeric ELSE true END"
    @test params == Any[Migrations._TEXT_CAST_RE.int, -32768, 32767]
    # A bounded numeric checks its precision after rounding to its scale, like the parser.
    sql, params = _precheck_sql(PG_LA803, f("DECIMAL(8, 2)"); server_version = 150008)
    @test occursin("abs(round(CAST(CAST(\"c\" AS text) AS numeric), \$2::integer)) >= power(10::numeric, \$3::integer)", sql)
    @test params == Any[Migrations._TEXT_CAST_RE.numeric, 2, 6, Migrations._TEXT_CAST_RE.nan]
    @test occursin("CAST(\"c\" AS text) !~* \$4 AND", sql)   # the NaN test is bound, not a literal
    for (type, re) in (("DOUBLE PRECISION", :float), ("BOOLEAN", :bool), ("UUID", :uuid))
        @test _precheck_sql(PG_LA803, f(type); server_version = 110000) ==
              (base * "CAST(\"c\" AS text) !~* \$1", Any[getfield(Migrations._TEXT_CAST_RE, re)])
    end
    for type in ("DATE", "TIMESTAMP WITH TIME ZONE", "JSONB")
        @test _precheck_sql(PG_LA803, f(type); server_version = 150008) == (base * "true", Any[])
    end

    # The regexes accept what the input functions accept, and refuse their neighbours.
    ok(re, v) = occursin(Regex(getfield(Migrations._TEXT_CAST_RE, re), "i"), v)
    @test all(v -> ok(:int, v), (" 42 ", "-7", "+0"))
    @test !any(v -> ok(:int, v), ("4.2", "x", "", "1e3"))
    @test all(v -> ok(:numeric, v), ("1.5", ".5", "-2e3", "NaN", " 7 "))
    @test !any(v -> ok(:numeric, v), ("1.2.3", "abc", "Infinity"))
    @test all(v -> ok(:float, v), ("1.5", "-Infinity", "inf", "NaN", "1e-9"))
    @test all(v -> ok(:bool, v), ("t", "TRUE", " yes ", "of", "0", "On"))
    @test !any(v -> ok(:bool, v), ("o", "maybe", "2"))
    @test all(v -> ok(:uuid, v), ("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "{a0eebc999c0b4ef8bb6d6bb9bd380a11}",
                                 "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11"))
    @test !any(v -> ok(:uuid, v), ("a0eebc99", "g0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"))
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#828, review): a USING retype of a column with a DEFAULT drops it first
# The `USING` converts values, not the default; PostgreSQL converts the default with an assignment
# cast, and the castless pairs have none — so `TYPE … USING` failed on every table while the old
# default was still there. The sequence is DROP DEFAULT → TYPE … USING → SET DEFAULT <declared>.
# `0 == false` in Julia, so an integer default of 0 moving to a boolean default of false is not a
# `:default` delta; the declared default must still be put back.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#828 review: a USING retype drops the old default first and restores the declared one" begin
    drop = "ALTER TABLE \"t828\" ALTER COLUMN \"c\" DROP DEFAULT;"
    steps(sql) = [strip(l) for l in split(sql, '\n') if !isempty(strip(l))]

    s = steps(_la828_alter(Models.IntegerField(default = 0), Models.CharField(max_length = 5, default = "0")))
    @test s[1] == drop
    @test startswith(s[2], "ALTER TABLE \"t828\" ALTER COLUMN \"c\" TYPE ") && occursin(" USING CAST(\"c\" AS ", s[2])
    @test s[end] == "ALTER TABLE \"t828\" ALTER COLUMN \"c\" SET DEFAULT 0;"

    s = steps(_la828_alter(Models.BooleanField(default = false), Models.IntegerField(default = 0)))
    @test s[1] == drop && occursin("USING (\"c\" <> 0);", s[2])
    @test s[end] == "ALTER TABLE \"t828\" ALTER COLUMN \"c\" SET DEFAULT FALSE;"

    # No declared default: the drop is the whole story — one DROP, not two.
    s = steps(_la828_alter(Models.IntegerField(), Models.BooleanField(default = true)))
    @test count(==(drop), s) == 1 && s[1] == drop

    # No old default: nothing to drop.
    @test !occursin("DROP DEFAULT", _la828_alter(Models.IntegerField(default = 0), Models.CharField(max_length = 5)))
end

@testset "#829 review: an uncompilable added column is not classified" begin
    spec = Migrations._degraded_spec(Models.IntegerField(), PG_LA803, "<uncompilable:new>"; name = "grid")
    @test isempty(Migrations._lossy_add_column(spec, PG_LA803; table = "t"))
end

@testset "#828 review: the float grammar takes a signed NaN" begin
    ok(v) = occursin(Regex(Migrations._TEXT_CAST_RE.float, "i"), v)
    @test ok("-nan") && ok("+NaN") && ok("\tnan ")
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#828, delta review): an undeclared database default dropped by a USING retype
# The retype must drop the old default to run. A live expression default the model does not declare
# is never part of the delta, so nothing sets it back: future inserts lose it. That is recorded as a
# `:silent` finding, so it takes the opt-in; declaring it as a `db_default` restores it instead.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#828 review: a USING retype that would silently drop an undeclared expression default is a finding" begin
    M = Models
    @test _la803_kinds(M.IntegerField(), M.CharField(max_length = 5, db_default = (postgres = "'0'",)), PG_LA803) ==
          [:text_cast, :drop_default]
    @test lossy_alter_class(LossyAlter(:drop_default, "t", "c", "a", "b")) === :silent
    # Declared on the new side: it is set back after the retype, so nothing is lost.
    @test _la803_kinds(M.IntegerField(db_default = (postgres = "0",)), M.CharField(max_length = 5, db_default = (postgres = "'0'",)), PG_LA803) ==
          [:text_cast]
    # A literal default is a `:default` delta like any other, dropped by the plan on purpose.
    @test _la803_kinds(M.IntegerField(), M.CharField(max_length = 5, default = "0"), PG_LA803) == [:text_cast]
    # No USING, no forced drop.
    @test isempty(_la803_kinds(M.TextField(), M.IntegerField(db_default = (postgres = "0",)), PG_LA803))
end

# ─────────────────────────────────────────────────────────────────────────────
# Lossy ALTERs (#830, security review): the CHECK count runs only a condition the models declare
# The plan is data (#710): `dry_run` never executes its statements. A header condition rewritten
# together with the plan's own CHECK statement passes `_refuse_unplanned_conditions`, so that check
# cannot be what decides which SQL the count runs. The models file is: a condition it does not
# declare is left uncounted, and the payload — here a query that would raise if it ever ran — never
# reaches the database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite #830: a CHECK condition the models do not declare is never run by dry_run" begin
    _la803_with_key("la830anchor") do key, pool
        fetch(pool, "INSERT INTO race803 (name, laps) VALUES ('Spa', -1);")
        write(joinpath(key, "models.jl"),
              _la830_models("Models.CheckConstraint(condition = \"laps >= 0\", name = \"race803_laps_ck\")"))
        _la803_quiet(() -> Migrations.makemigrations(key; interactive = false))
        pending = joinpath(key, "migrations", "pending_migrations.jl")
        # Declared: counted (the -1 row).
        @test only(Migrations.dry_run(key).lossy_alters).rows == 1
        # Header and statement rewritten together: the plan-text guard is satisfied, the models are not.
        payload = "laps >= (SELECT COUNT(*) FROM pormg_no_such_table_830)"
        write(pending, replace(read(pending, String), "laps >= 0" => payload))
        @test only(Migrations._plan_lossy_alters(pending)).condition == payload   # the guard passes
        r = _la803_quiet(() -> Migrations.dry_run(key))                            # and nothing raises
        @test only(r.lossy_alters).rows === nothing
        @test only(r.lossy_alters).condition === nothing
    end
end
