# =============================================================================
# check(kinds = [:schema_drift]): a read-only drift gate (#738)
#
# Nothing in PormG answered "does this database match the declared models?" without side effects.
# `status()` never compared schemas, and `makemigrations` writes a file, refuses under
# `change_db: false` — the setting a production connection usually carries — and swallows a failed
# read. A consuming app had built the gate itself out of `get_migration_plan`.
#
# `check(...; kinds = [:schema_drift])` is that gate. Each step the next `makemigrations` would plan
# becomes one `SchemaCheckFinding`, whose `detail` is the step's label. It never writes, never
# prompts, runs under `change_db: false`, and raises on a failed read, so a gate can never report
# clean because it could not look.
#
# Hermetic: temporary SQLite files and folders, no live database. The PostgreSQL arm shares every
# line past the live read and is exercised against db_2 by test/integration/test_schema_drift_check.jl.
# =============================================================================
# julia --project=test/integration test/unit/test_schema_drift_check.jl

using Test
using Logging
using DataFrames
using PormG
# The testsets open real (temporary) SQLite files, so they need the weakdep extension. `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, InvalidValueError
import PormG.ConnectionPool: close_pool!, SQLiteConnectionPool

_dc738_quiet(f) = with_logger(f, NullLogger())

# A models file for one F1 schema, with the pieces each testset varies passed in as source text.
function _dc738_write_models(path::AbstractString; circuit_fields::String = "", extra_models::String = "")
    write(path, "module models\nimport PormG.Models\n" *
                "Circuit738 = Models.Model(\n    id = Models.IDField(),\n" *
                "    name = Models.CharField(null = true)" * circuit_fields * "\n)\n" *
                extra_models * "end\n")
end

# A temporary SQLite project whose database already matches the models `write!` writes: the models
# file sits where `check` looks for it by default (`db_def_folder/model_file`), and it has been
# planned and applied once. `f(pool, settings, models_path)` runs inside the temp dir.
function _dc738_applied_project(f, tag::String, write!::Function)
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath(tag)
            pool = SQLiteConnectionPool(joinpath(dir, "$(tag).sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = tag)
            settings.change_db = true
            models_path = joinpath(dir, tag, settings.model_file)
            write!(models_path)
            _dc738_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
            _dc738_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
            f(pool, settings, models_path)
        end
    finally
        pool === nothing || close_pool!(pool)
        rm(dir; recursive = true, force = true)
    end
end

_dc738_drift(pool, settings; kw...) =
    _dc738_quiet(() -> Migrations.check(pool, settings; kinds = [:schema_drift], kw...))

# ─────────────────────────────────────────────────────────────────────────────
# A database that matches its models has no drift
# The gate's green state: right after `migrate`, the next `makemigrations` would plan nothing, so
# `check` reports nothing — and the CI snippet `exit(isempty(r) ? 0 : 1)` exits 0.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema_drift: an applied schema is clean (#738)" begin
    _dc738_applied_project("db738a", p -> _dc738_write_models(p)) do pool, settings, _
        r = _dc738_drift(pool, settings)
        @test r.backend === :sqlite
        @test isempty(r)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Each kind of difference is a finding, labelled the way the plan labels it
# One finding per step `makemigrations` would plan: its `detail` is the step's label, its `columns`
# the column the label names, and its `message` which side has the thing the other lacks.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema_drift: one finding per planned step (#738)" begin
    _dc738_applied_project("db738b", p -> _dc738_write_models(p)) do pool, settings, models_path
        # The models gain a column and a table the database does not have.
        _dc738_write_models(models_path;
            circuit_fields = ",\n    country = Models.CharField(null = true)",
            extra_models = "Season738 = Models.Model(\n    id = Models.IDField(),\n    year = Models.IntegerField(default = 0)\n)\n")
        r = _dc738_drift(pool, settings)
        @test all(f -> f.kind === :schema_drift, r.findings)

        add = only(filter(f -> f.detail == "Add field: country", r.findings))
        @test add.table == "circuit738" && add.columns == ["country"]
        @test occursin("missing from the database", add.message)

        new_tables = filter(f -> f.detail == "New model", r.findings)
        @test [f.table for f in new_tables] == ["season738"]
        @test isempty(only(new_tables).columns)
        @test occursin("missing from the database", only(new_tables).message)

        # `include_table` narrows BOTH sides: the declared Season738 is outside it, so it is not
        # reported as a table missing from the database.
        narrowed = _dc738_drift(pool, settings; include_table = ["circuit738"])
        @test [f.detail for f in narrowed.findings] == ["Add field: country"]
    end

    _dc738_applied_project("db738c", p -> _dc738_write_models(p;
            circuit_fields = ",\n    country = Models.CharField(null = true)",
            extra_models = "Season738 = Models.Model(\n    id = Models.IDField(),\n    year = Models.IntegerField(default = 0)\n)\n")) do pool, settings, models_path
        # The reverse: the database has a column and a table the models no longer declare.
        _dc738_write_models(models_path)
        r = _dc738_drift(pool, settings)

        dropped_col = only(filter(f -> f.detail == "Remove field: country", r.findings))
        @test dropped_col.columns == ["country"]
        @test occursin("not declared in the models", dropped_col.message)

        dropped = only(filter(f -> f.detail == "Drop table", r.findings))
        @test dropped.table == "season738"
        @test occursin("not declared in the models", dropped.message)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# An unhinted rename is drift, and says it might be a rename
# `check` never prompts, so like `makemigrations(interactive = false)` it plans a renamed column as
# an add plus a remove, and a renamed table as a new model plus a drop. That IS drift — the live and
# declared names differ — but the message names the pair, so the reader knows it may be one change.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema_drift: an unhinted rename names the pair (#738)" begin
    _dc738_applied_project("db738d", p -> _dc738_write_models(p;
            extra_models = "Season738 = Models.Model(\n    id = Models.IDField(),\n    year = Models.IntegerField(default = 0)\n)\n")) do pool, settings, models_path
        # `name` becomes `circuit_name`; `Season738` becomes `Championship738`.
        write(models_path, "module models\nimport PormG.Models\n" *
              "Circuit738 = Models.Model(\n    id = Models.IDField(),\n    circuit_name = Models.CharField(null = true)\n)\n" *
              "Championship738 = Models.Model(\n    id = Models.IDField(),\n    year = Models.IntegerField(default = 0)\n)\nend\n")
        r = _dc738_drift(pool, settings)

        added = only(filter(f -> f.detail == "Add field: circuit_name", r.findings))
        removed = only(filter(f -> f.detail == "Remove field: name", r.findings))
        @test occursin("could be a rename", added.message) && occursin("name", added.message)
        @test occursin("could be a rename", removed.message) && occursin("circuit_name", removed.message)

        created = only(filter(f -> f.detail == "New model", r.findings))
        dropped = only(filter(f -> f.detail == "Drop table", r.findings))
        @test created.table == "championship738" && dropped.table == "season738"
        @test occursin("could be a rename", created.message) && occursin("season738", created.message)
        @test occursin("could be a rename", dropped.message) && occursin("championship738", dropped.message)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# include_table reports only the listed tables; a ManyToManyField does not leak through it
# Found in review: `include_table` used to narrow the DECLARED models before planning, and the planner
# builds each ManyToManyField's through table from them. So an included owner produced a through
# table the narrowed live side lacked — a false "New model" plus its indexes — and a string target
# outside the list raised ModelDefinitionError. Every declared model is now planned and only the
# listed tables reported. `ignore_table` is the other filter and stays live-side only, as it is for
# `makemigrations`: a declared model on an ignored table reads as missing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema_drift: include_table with a ManyToManyField, and ignore_table (#738)" begin
    m2m_models(p) = write(p, "module models\nimport PormG.Models\n" *
        "Driver738m = Models.Model(\n    id = Models.IDField(),\n    surname = Models.CharField(null = true)\n)\n" *
        "Season738m = Models.Model(\n    id = Models.IDField(),\n    year = Models.IntegerField(default = 0),\n" *
        "    drivers = Models.ManyToManyField(\"Driver738m\")\n)\nend\n")
    _dc738_applied_project("db738m", m2m_models) do pool, settings, _
        tables = String.(DataFrame(PormG.ConnectionPool.fetch(pool,
                         "SELECT name FROM sqlite_master WHERE type = 'table';")).name)
        through = only(filter(t -> startswith(t, "season738m_"), tables))

        @test isempty(_dc738_drift(pool, settings))
        # Mutation gate: narrow the declared models by include_table again and the first of these
        # throws (the string target "Driver738m" is outside the list) — or, with the target listed,
        # reports the existing through table as "New model".
        @test isempty(_dc738_drift(pool, settings; include_table = ["season738m"]))
        @test isempty(_dc738_drift(pool, settings; include_table = ["season738m", "driver738m"]))
        @test isempty(_dc738_drift(pool, settings; include_table = ["season738m", through]))

        # ignore_table replaces the default skip list (as it does for :expression_default), so the
        # defaults are passed along with the table to skip.
        ignored = _dc738_drift(pool, settings; ignore_table = vcat(PormG.sqlite_ignore_schema, ["driver738m"]))
        @test [(f.table, f.detail) for f in ignored.findings] == [("driver738m", "New model")]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Read-only, and usable where makemigrations is not
# `change_db: false` is how a production connection is usually configured, and `makemigrations`
# refuses to run there. The gate must work there, and must leave no trace: no pending plan, no
# history rows, no archive.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema_drift: runs under change_db false and writes nothing (#738)" begin
    _dc738_applied_project("db738e", p -> _dc738_write_models(p)) do pool, settings, models_path
        _dc738_write_models(models_path; circuit_fields = ",\n    country = Models.CharField(null = true)")
        settings.change_db = false
        migrations_dir = joinpath("db738e", "migrations")
        before = sort(readdir(migrations_dir; join = true))
        applied_before = sort(readdir(joinpath(migrations_dir, "applied_migrations")))

        r = _dc738_drift(pool, settings)
        @test !isempty(r)

        @test sort(readdir(migrations_dir; join = true)) == before
        @test sort(readdir(joinpath(migrations_dir, "applied_migrations"))) == applied_before
        @test !isfile(joinpath(migrations_dir, "pending_migrations.jl"))
        @test nrow(DataFrame(PormG.ConnectionPool.fetch(pool, "SELECT * FROM pormg_migrations;"))) == 1
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A failed read raises; it is never reported as clean
# `makemigrations` logs a live-schema read error and returns. A gate that did that would exit 0
# against a database it could not read. The file below is not a database at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema_drift: a failed read raises (#738)" begin
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath("db738f")
            _dc738_write_models(joinpath(dir, "db738f", "models.jl"))
            write("broken.sqlite", "this is not an SQLite database, and reading it must not look clean\n" ^ 64)
            # `pool_timeout = 2`: SQLite's "file is not a database" is not classed as a permanent
            # connect failure, so the pool would otherwise retry for its default 30 s first.
            pool = SQLiteConnectionPool(joinpath(dir, "broken.sqlite"); pool_size = 1, pool_timeout = 2)
            settings = Configuration.Settings(connections = pool, db_def_folder = "db738f")
            # Mutation gate: wrap the live read in a try that returns an empty result, and this
            # passes silently instead of throwing.
            @test_throws PormG.PoolConnectError _dc738_drift(pool, settings)
        end
    finally
        pool === nothing || try close_pool!(pool) catch end
        # The failed connect leaves its `SQLite.DB` handle to the finalizer (the connect path does
        # not close it when the first PRAGMA throws), and Windows refuses to delete an open file —
        # CI failed here on `unlink … resource busy or locked`. Collect it first, and never let
        # removing a temp dir fail the test.
        GC.gc()
        try rm(dir; recursive = true, force = true) catch end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Where the models come from, and what the keywords refuse
# By default the models file is `db_def_folder/model_file`, as for `makemigrations`; `models_file`
# points elsewhere. A missing file is `MissingConfigurationError`. `kinds` must name known classes
# and at least one of them — an empty list would be a gate that can never fail — and `models_file`
# is refused unless `:schema_drift` asked for it, rather than silently ignored.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema_drift: models_file, and the keywords it refuses (#738)" begin
    _dc738_applied_project("db738g", p -> _dc738_write_models(p)) do pool, settings, models_path
        other = abspath("other_models.jl")
        _dc738_write_models(other; circuit_fields = ",\n    country = Models.CharField(null = true)")
        r = _dc738_drift(pool, settings; models_file = other)
        @test [f.detail for f in r.findings] == ["Add field: country"]
        @test isempty(_dc738_drift(pool, settings))   # the default file still matches

        @test_throws PormG.Configuration.MissingConfigurationError _dc738_drift(pool, settings; models_file = abspath("nope.jl"))
        refusal(f) = try f(); "" catch e; e isa InvalidValueError ? sprint(showerror, e) : "wrong type: $(typeof(e))" end
        @test occursin(":schema_drfit", refusal(() -> Migrations.check(pool, settings; kinds = [:schema_drfit])))
        @test occursin("at least one", refusal(() -> Migrations.check(pool, settings; kinds = Symbol[])))
        @test occursin("read only by the :schema_drift class",
                       refusal(() -> Migrations.check(pool, settings; models_file = other)))

        # Both classes at once: the result carries each kind's findings, ordered by kind.
        both = _dc738_quiet(() -> Migrations.check(pool, settings; kinds = [:schema_drift, :expression_default],
                                                   models_file = other))
        @test [f.kind for f in both.findings] == [:schema_drift]
        shown = sprint(show, both)
        @test occursin("schema_drift", shown) && occursin("circuit738.country", shown) && occursin("Add field: country", shown)
        @test !occursin("DEFAULT", shown)
    end
end

# #762: `Circuit762 = Models.Model("f1_circuit762", …)` is how a generated models file declares a model
# whose table carries an app prefix. `ManyToManyField("Circuit762")` names the BINDING, which appears
# in neither the planner's schema-dict keys (physical tables) nor the model's `name`.
_m2m762_models(target::String; extra::String = "") = (p -> write(p, "module models\nimport PormG.Models\n" *
    "Circuit762 = Models.Model(\"f1_circuit762\", id = Models.IDField(), name = Models.CharField(null = true))\n" *
    extra *
    "Season762 = Models.Model(id = Models.IDField(), year = Models.IntegerField(default = 0),\n" *
    "    circuits = Models.ManyToManyField(\"$(target)\"))\nend\n"))

# Load a models file written by `write!` and plan it against an empty SQLite database, without
# `set_models`, the way `makemigrations` does. Returns `(current, plan_or_exception)`.
function _m2m762_plan(write!::Function)
    dir = mktempdir()
    pool = SQLiteConnectionPool(joinpath(dir, "probe762.sqlite"); pool_size = 1)
    try
        models_path = joinpath(dir, "models.jl")
        write!(models_path)
        settings = Configuration.Settings(connections = pool, db_def_folder = dir)
        current = Migrations._load_current_models(models_path)
        plan = try
            _dc738_quiet(() -> Migrations.get_migration_plan(Migrations.LiveTable[], current, pool, settings;
                                                             interactive = false))
        catch e
            e
        end
        return current, plan
    finally
        close_pool!(pool)
        try rm(dir; recursive = true, force = true) catch end
    end
end

_m2m762_season(current) = only(e[:model] for (k, e) in current if startswith(String(k), "season762"))

# ─────────────────────────────────────────────────────────────────────────────
# M2M target by binding: planned when its table differs (#762)
# The issue's repro. The planner used to raise "not defined" here, which blocked `makemigrations`
# and the drift gate for the whole model set; the target now resolves by binding, as at runtime.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#762: an M2M target whose table differs from its binding is planned" begin
    current, plan = _m2m762_plan(_m2m762_models("Circuit762"))
    # The write-back: the declared field holds the target model itself, not the string.
    @test _m2m762_season(current).fields["circuits"].to === current[:f1_circuit762][:model]
    @test !(plan isa Exception)
    through = only(k for k in keys(plan) if startswith(String(k), "season762_"))
    # The join table's key into the target names the target's PHYSICAL table.
    @test occursin(r"REFERENCES\s+\"f1_circuit762\"", join(values(plan[through]), "\n"))
end

# ─────────────────────────────────────────────────────────────────────────────
# M2M target by binding: applied, then no drift (#762)
# End to end on a temporary SQLite project: `makemigrations` → `migrate` creates the join table,
# and the next plan is empty, so `check(kinds = [:schema_drift])` reports nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#762: makemigrations applies it and schema_drift is clean" begin
    _dc738_applied_project("db762", _m2m762_models("Circuit762")) do pool, settings, _
        tables = String.(DataFrame(PormG.ConnectionPool.fetch(pool,
                         "SELECT name FROM sqlite_master WHERE type = 'table';")).name)
        @test "f1_circuit762" in tables
        @test count(t -> startswith(t, "season762_"), tables) == 1
        @test isempty(_dc738_drift(pool, settings))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# M2M target by binding: a name bound to something else falls back (#762)
# `position` is `Base.position` inside the models module, not a model. The binding lookup must pass
# it over rather than throw, so the planner's own name match still finds the model named `position`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#762: an M2M target that is a non-model binding falls back to the model name" begin
    pos_model = "Pos762 = Models.Model(\"position\", id = Models.IDField())\n"
    current, plan = _m2m762_plan(_m2m762_models("position"; extra = pos_model))
    # Left as the String: the binding `position` is `Base.position`, which is no model.
    @test _m2m762_season(current).fields["circuits"].to == "position"
    @test !(plan isa Exception)
    through = only(k for k in keys(plan) if startswith(String(k), "season762_"))
    @test occursin(r"REFERENCES\s+\"position\"", join(values(plan[through]), "\n"))
end

# ─────────────────────────────────────────────────────────────────────────────
# M2M target by binding: a name no model answers to still raises (#762)
# The resolution is best-effort, so a typo is left to the planner's own lookup, which refuses it
# with `ModelDefinitionError` naming the target, exactly as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#762: an M2M target that names no model still raises" begin
    current, err = _m2m762_plan(_m2m762_models("Circuit762x"))
    @test _m2m762_season(current).fields["circuits"].to == "Circuit762x"
    @test err isa PormG.ModelDefinitionError
    @test occursin("Circuit762x", sprint(showerror, err))
end
