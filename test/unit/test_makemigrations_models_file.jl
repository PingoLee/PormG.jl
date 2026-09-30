# =============================================================================
# makemigrations(db; models_file = …): plan against any models file (#736)
#
# A state-based engine has no down migrations: the stored forward SQL cannot be inverted. It does
# not need them. `makemigrations` plans `diff(live database, declared models)`, so pointing it at an
# OLDER models file plans the way back — Atlas's declarative apply to an older desired state. The
# `String` form now takes that file as `models_file`, resolved the way `check(kinds =
# [:schema_drift])` resolves its own `models_file` (one shared helper).
#
# Two things ride with it. The plan header records a non-default models file, and `migrate`
# snapshots THAT file as `_old_models.jl` — before, it always copied `<db_def_folder>/<model_file>`,
# which after a revert is the newer file the plan was not diffed against. And the default path is
# now absolute before `Base.include` sees it: the `String` form used to hand `include` a relative
# `joinpath(db, …)`, which resolves against the including source file rather than the working
# directory its own `isfile` check had used — so every call here, from a temporary cwd, would fail.
#
# Hermetic: temporary SQLite files and temporary config folders, no live database.
# =============================================================================
# julia --project=test/integration test/unit/test_makemigrations_models_file.jl

using Test
using Logging
using DataFrames
using PormG
# The testsets open real (temporary) SQLite files, so they need the weakdep extension.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations
import PormG.Configuration: MissingConfigurationError
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import OrderedCollections: OrderedDict

# Suffixed names: `runtests.jl` includes every unit file into ONE module.
# The F1 driver table in two states: v1 declares `code`; v2 adds `nickname`.
function _mf736_driver_model(; with_nickname::Bool)
    nickname = with_nickname ? "    nickname = Models.CharField(null = true),\n" : ""
    return "Driver736 = Models.Model(\n    id = Models.IDField(),\n" *
           "    surname = Models.CharField(null = true),\n" * nickname *
           "    code = Models.CharField(null = true)\n)\n"
end
_mf736_models(; with_nickname::Bool) =
    "module models\nimport PormG.Models\n" * _mf736_driver_model(; with_nickname) * "end\n"

_mf736_columns(pool) = String.(DataFrame(fetch(pool, "PRAGMA table_info(driver736);")).name)
_mf736_quiet(f) = with_logger(f, NullLogger())

# A connection registered under `key`, the way the `String` forms find it. Restores the global config.
function _mf736_with_key(f, tag::String)
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
            f(dir, pool, settings)
        end
    finally
        pool === nothing || close_pool!(pool)
        empty!(PormG.config); merge!(PormG.config, saved)
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Reverting by declaring the old state: apply v2, plan v1, apply, re-plan is empty
# The recipe the docs teach, end to end through the `String` forms. The v1 file `include`s a sibling
# — the shape a consuming app's models file has — which resolves because it sits beside it. Data in
# the columns both states declare survives; the dropped column's data does not (the documented limit).
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations(db; models_file) plans a revert to an older models file (#736)" begin
    _mf736_with_key("db736") do dir, pool, settings
        key = "db736"
        pending = joinpath(key, "migrations", "pending_migrations.jl")
        applied_dir = joinpath(key, "migrations", "applied_migrations")

        # v1 is the connection's own models file, planned and applied with the default call.
        write(joinpath(key, "models.jl"), _mf736_models(with_nickname = false))
        _mf736_quiet(() -> Migrations.makemigrations(key; interactive = false))
        _mf736_quiet(() -> Migrations.migrate(key; interactive = false))
        fetch(pool, "INSERT INTO driver736 (surname, code) VALUES ('Senna', 'SEN');")

        # v2 replaces it. The default plan carries no models-file header: byte-for-byte today's
        # layout, the format marker still the line right under `module`.
        write(joinpath(key, "models.jl"), _mf736_models(with_nickname = true))
        _mf736_quiet(() -> Migrations.makemigrations(key; interactive = false))
        lines = readlines(pending)
        @test lines[2] == "# pormg-migration-format: $(Migrations.MIGRATION_FORMAT_VERSION)"
        @test lines[3] == ""
        @test !any(l -> startswith(l, Migrations.MODELS_FILE_HEADER), lines)
        _mf736_quiet(() -> Migrations.migrate(key; interactive = false))
        fetch(pool, "UPDATE driver736 SET nickname = 'Magic' WHERE surname = 'Senna';")
        @test "nickname" in _mf736_columns(pool)

        # The old state, checked out beside its sibling (as `git show REV:… > …` would).
        write(joinpath(key, "driver_v1.jl"), _mf736_driver_model(with_nickname = false))
        v1 = "module models\nimport PormG.Models\ninclude(\"driver_v1.jl\")\nend\n"
        write(joinpath(key, "models_v1.jl"), v1)

        # Relative to the working directory, like any path a user types.
        _mf736_quiet(() -> Migrations.makemigrations(key; models_file = joinpath(key, "models_v1.jl"), interactive = false))
        plan = read(pending, String)
        @test occursin("nickname", plan)
        # Recorded relative to the folder, so `migrate` resolves it from any working directory.
        @test readlines(pending)[3] == Migrations.MODELS_FILE_HEADER * "models_v1.jl"
        # With the digest of the bytes it was generated from, which `migrate` checks before copying.
        @test readlines(pending)[4] == Migrations.MODELS_SHA256_HEADER * Migrations._models_file_digest(joinpath(key, "models_v1.jl"))

        # A revert that drops a column is destructive, and the guard applies to it unchanged.
        @test_throws Migrations.DestructiveMigrationError _mf736_quiet(() -> Migrations.migrate(key; interactive = false))
        @test "nickname" in _mf736_columns(pool)
        @test _mf736_quiet(() -> Migrations.migrate(key; interactive = false, destructive = true)).outcome === :applied

        # Back at v1: the column is gone, the data in the surviving columns is intact.
        @test !("nickname" in _mf736_columns(pool))
        rows = DataFrame(fetch(pool, "SELECT surname, code FROM driver736;"))
        @test size(rows, 1) == 1 && rows.surname[1] == "Senna" && rows.code[1] == "SEN"

        # The snapshot beside the applied migration is the file the plan was diffed against, not the
        # connection's `models.jl` (still v2 until the user commits v1 over it).
        # Paired by name with the archived plan that carries the header — not by sort order: three
        # applies within one second get random `_NNNN` suffixes, which do not sort chronologically.
        @test length(filter(f -> endswith(f, "_old_models.jl"), readdir(applied_dir))) == 3
        revert = only(filter(f -> endswith(f, "_migration.jl") &&
                                  occursin(Migrations.MODELS_FILE_HEADER, read(joinpath(applied_dir, f), String)),
                             readdir(applied_dir)))
        @test read(joinpath(applied_dir, replace(revert, "_migration.jl" => "_old_models.jl")), String) == v1

        # A re-plan against v1 is empty: the database IS that state now.
        _mf736_quiet(() -> Migrations.makemigrations(key; models_file = joinpath(key, "models_v1.jl"), interactive = false))
        @test !isfile(pending)

        # Until v1 is committed as `models.jl`, the default declared state is still v2 — which is
        # why the docs tell the user to finish the revert by moving the file over it.
        @test !isempty(Migrations.check(key; kinds = [:schema_drift]))
        @test isempty(Migrations.check(key; kinds = [:schema_drift], models_file = joinpath(key, "models_v1.jl")))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The header value: relative under the folder, absolute outside it, and inert whatever it holds
# A path is written into the plan file, which #710 established must never become code. The value is
# `escape_string`'d, so a newline cannot end the comment; the plan still parses as data and the
# reader recovers the exact path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the models-file header is escaped and round-trips (#736)" begin
    _mf736_with_key("db736h") do dir, pool, settings
        folder = joinpath("db736h", "migrations")
        mkpath(folder)
        # The connection's own file records nothing; a file outside the folder records an absolute path.
        @test Migrations._models_file_header_value(settings, joinpath(dir, "db736h", "models.jl")) === nothing
        @test Migrations._models_file_header_value(settings, joinpath(dir, "db736h", "old", "m.jl")) == joinpath("old", "m.jl")
        @test Migrations._models_file_header_value(settings, joinpath(dir, "elsewhere.jl")) == joinpath(dir, "elsewhere.jl")

        hostile = joinpath(dir, "a\"b\$(run(`false`))\nimport Base: x\n.jl")
        plan = OrderedDict(:driver736 => OrderedDict("New model" => "CREATE TABLE driver736 (id INTEGER PRIMARY KEY);"))
        PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, folder; models_file = hostile)
        lines = readlines(joinpath(folder, "pending_migrations.jl"))
        # Still one comment line under the format marker, and the plan still reads as data.
        @test startswith(lines[3], Migrations.MODELS_FILE_HEADER) && lines[4] == ""
        @test length(Migrations._load_migration_plan(settings)) == 1
        # No digest was passed, so none is read back — and `migrate` would snapshot nothing.
        @test Migrations._plan_models_file(settings) == (path = hostile, sha256 = nothing)

        # Only the header block counts: a matching line below the plan's `import`s — where table
        # names and SQL go — is never read as the header.
        PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, folder)
        path = joinpath(folder, "pending_migrations.jl")
        write(path, read(path, String) * Migrations.MODELS_FILE_HEADER * "spoofed.jl\n")
        @test Migrations._plan_models_file(settings) === nothing
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A missing models file is a MissingConfigurationError, naming the file
# Both the default and an explicit `models_file`; nothing is planned or written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations(db; models_file) refuses a missing file (#736)" begin
    _mf736_with_key("db736m") do dir, pool, settings
        err = try
            Migrations.makemigrations("db736m"; models_file = "nope/models_v1.jl", interactive = false)
            nothing
        catch e
            e
        end
        @test err isa MissingConfigurationError
        @test occursin("nope/models_v1.jl", sprint(showerror, err))
        # No models.jl was ever written, so the default is missing too — and the message says to
        # create it, rather than steering the user to a keyword they do not need.
        err = try
            Migrations.makemigrations("db736m"; interactive = false)
            nothing
        catch e
            e
        end
        @test err isa MissingConfigurationError
        @test occursin("Create it", sprint(showerror, err))
        @test !isfile(joinpath("db736m", "migrations", "pending_migrations.jl"))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A header migrate cannot use: warn, archive the plan, snapshot nothing
# Four ways: the recorded file is gone; the value was written by hand without `escape_string` (a
# Windows path's `\U` is an invalid escape); the value names a different file (a comment a reviewer
# reads past must not copy a Genie `config/secrets.jl` into a folder that gets committed — its bytes
# do not match the recorded digest); the models file was edited between `makemigrations` and
# `migrate`, so it is no longer the state the plan was diffed against. Falling back to the
# connection's own models file would archive a state the plan was not diffed against — the defect
# the header exists to prevent. And the plan is archived either way: a header read before the move
# used to be able to throw there, leaving an applied plan behind as pending for good.
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate archives no snapshot from an unusable models-file header (#736)" begin
    for (case, rewrite) in [
            ("gone",         key -> rm(joinpath(key, "models_v1.jl"))),
            ("unescaped",    key -> nothing),
            ("another file", key -> write(joinpath(key, "secrets.jl"), "const SECRET_TOKEN = \"x\"\n")),
            ("edited",       key -> open(io -> write(io, "# edited after planning\n"), joinpath(key, "models_v1.jl"); append = true)),
        ]
        tag = "db736g_" * replace(case, r"[^a-z]" => "")
        @testset "$case" begin
            _mf736_with_key(tag) do dir, pool, settings
                applied_dir = joinpath(tag, "migrations", "applied_migrations")
                pending = joinpath(tag, "migrations", "pending_migrations.jl")
                write(joinpath(tag, "models.jl"), _mf736_models(with_nickname = true))
                write(joinpath(tag, "models_v1.jl"), _mf736_models(with_nickname = false))
                _mf736_quiet(() -> Migrations.makemigrations(tag; models_file = joinpath(tag, "models_v1.jl"), interactive = false))
                rewrite(tag)
                # Replace the generated header value where the case is about the value itself.
                value = case == "unescaped" ? "C:\\Users\\me\\models.jl" :
                        case == "another file" ? "secrets.jl" : nothing
                if value !== nothing
                    write(pending, replace(read(pending, String),
                        Migrations.MODELS_FILE_HEADER * "models_v1.jl" => Migrations.MODELS_FILE_HEADER * value))
                end

                result = @test_logs (:warn, r"no models snapshot was archived") match_mode = :any Migrations.migrate(tag; interactive = false)
                @test result.outcome === :applied
                @test !isfile(pending)
                @test length(filter(f -> endswith(f, "_migration.jl"), readdir(applied_dir))) == 1
                @test isempty(filter(f -> endswith(f, "_old_models.jl"), readdir(applied_dir)))
            end
        end
    end
end
