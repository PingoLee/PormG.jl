# =============================================================================
# Configuration.load / load_many(…; root): short registry keys without `cd` (#857)
#
# `load("db")` uses its one string as both the registry key and the folder, resolved against
# `pwd()`, and stores it as `Settings.db_def_folder`. An application that wants short keys therefore
# had to run from its project root or wrap every load in `cd(root) do … end` — at precompile, in
# `__init__`, and at boot. `root` separates the two: the key is the string passed, the folder is
# `joinpath(root, path)`, stored absolute.
#
# Every testset runs with the working directory OUTSIDE the root. That is the whole claim: from the
# root itself, `load("db")` already worked, so a test run there could not tell the two apart.
#
# Hermetic: temporary config folders and temporary SQLite files, no live database.
# =============================================================================
# julia --project=test/integration test/unit/test_load_root.jl

using Test
using Logging
using PormG
# The SQLite pools open real (temporary) files, so they need the weakdep extension.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations
import PormG.Configuration: MissingConfigurationError, InvalidConfigurationError

# Suffixed names: `runtests.jl` includes every unit file into ONE module.
const _LR857_YML =
    "default_env: test\ntest:\n  adapter: SQLite\n  database: f857.sqlite\n" *
    "  config:\n    change_db: true\n    change_data: true\n"

const _LR857_MODELS =
    "module models\nimport PormG.Models\n" *
    "Driver857 = Models.Model(\n    id = Models.IDField(),\n    surname = Models.CharField(null = true)\n)\nend\n"

# A project root holding `db/` and `db_bs/`, a second directory to stand in, and a clean global
# config. Every pool opened inside is closed and the config restored, whatever the body did.
function _lr857_with_project(f)
    saved = copy(PormG.config)
    root = mktempdir()
    elsewhere = mktempdir()
    try
        empty!(PormG.config)
        for d in ("db", "db_bs")
            mkpath(joinpath(root, d))
            write(joinpath(root, d, "connection.yml"), _LR857_YML)
        end
        cd(() -> f(root, elsewhere), elsewhere)
    finally
        for (_, s) in PormG.config
            s.connections === nothing || try Configuration.close_pool!(s.connections) catch end
        end
        empty!(PormG.config)
        merge!(PormG.config, saved)
        rm(root; recursive = true, force = true)
        rm(elsewhere; recursive = true, force = true)
    end
end

@testset "load(path; root) registers the short key with the folder under root" begin
    _lr857_with_project() do root, elsewhere
        db = PormG.Models._canonical_folder_path(joinpath(root, "db"))

        @test Configuration.load("db"; root = root, env = "test") == "db"
        @test collect(keys(PormG.config)) == ["db"]
        # The folder is absolute and under the root — not the key, and not under `pwd()`.
        @test PormG.config["db"].db_def_folder == db
        @test isabspath(PormG.config["db"].db_def_folder)

        # The relative SQLite `database:` resolves inside the folder, so the file lands under the
        # root. Before, it was resolved against the folder string `"db"`, i.e. against `pwd()`.
        @test Configuration.ping("db")
        @test isfile(joinpath(db, "f857.sqlite"))
        @test !ispath(joinpath(elsewhere, "db"))
    end
end

@testset "load_many(paths; root) returns the short keys" begin
    _lr857_with_project() do root, elsewhere
        @test Configuration.load_many(["db", "db_bs"]; root = root, env = "test") == ["db", "db_bs"]
        @test sort(collect(keys(PormG.config))) == ["db", "db_bs"]
        @test PormG.config["db_bs"].db_def_folder ==
              PormG.Models._canonical_folder_path(joinpath(root, "db_bs"))
    end
end

@testset "without root, load still resolves against pwd()" begin
    _lr857_with_project() do root, elsewhere
        # The default is unchanged: from outside the root there is no `db` folder to find.
        @test_throws MissingConfigurationError Configuration.load("db"; env = "test")
        @test isempty(PormG.config)
        # …and from the root it is today's behaviour exactly, folder string and all.
        cd(root) do
            @test Configuration.load("db"; env = "test") == "db"
        end
        @test PormG.config["db"].db_def_folder == "db"
    end
end

@testset "root with an absolute path, or a missing folder, fails loudly" begin
    _lr857_with_project() do root, elsewhere
        # `joinpath(root, "/abs")` silently discards `root`; refused rather than honoured.
        err = try
            Configuration.load(joinpath(root, "db"); root = root, env = "test"); nothing
        catch e
            e
        end
        @test err isa InvalidConfigurationError
        @test occursin("absolute", sprint(showerror, err))
        @test isempty(PormG.config)

        # A missing folder is reported where it was looked for — under the root — and the call to
        # repeat keeps the root, since `load("nope")` alone would look under `pwd()`.
        err = try
            Configuration.load("nope"; root = root, env = "test"); nothing
        catch e
            e
        end
        @test err isa MissingConfigurationError
        msg = sprint(showerror, err)
        @test occursin(joinpath(root, "nope"), msg)
        # `repr`: a Windows root's backslashes must come out escaped to paste back as valid Julia.
        @test occursin("load(\"nope\"; root = $(repr(root)), scaffold=true)", msg)

        # Without root the hint is today's, unchanged.
        err = try
            Configuration.load("nope"; env = "test"); nothing
        catch e
            e
        end
        @test occursin("load(\"nope\"; scaffold=true)", sprint(showerror, err))
    end
end

@testset "scaffold = true writes the skeleton under root" begin
    _lr857_with_project() do root, elsewhere
        @test Configuration.load("fresh"; root = root, scaffold = true) === nothing
        @test isfile(joinpath(root, "fresh", "connection.yml"))
        @test !ispath(joinpath(elsewhere, "fresh"))
    end
end

@testset "an implicit absolute entry migrates to the short key (#550)" begin
    _lr857_with_project() do root, elsewhere
        db = joinpath(root, "db")
        # The precompile shape: `set_models` minted an entry under the absolute folder first.
        Configuration.load(db; env = "test", implicit = true)
        @test collect(keys(PormG.config)) == [db]

        # The explicit short-key load finds it by folder, not by the key's spelling, and takes over.
        @test_logs((:warn, r"implicit load"), match_mode = :any,
                   @test Configuration.load("db"; root = root, env = "test") == "db")
        @test collect(keys(PormG.config)) == ["db"]
        @test !PormG.config["db"].implicit
    end
end

@testset "a folder already held under an explicit key is reused, and keeps an absolute folder" begin
    _lr857_with_project() do root, elsewhere
        db = joinpath(root, "db")
        canonical = PormG.Models._canonical_folder_path(db)

        # Explicit absolute key first: one folder, one entry (#550) wins over "the key is `path`",
        # and the return value says which key was used.
        Configuration.load(db; env = "test")
        @test_logs((:warn, r"already loaded under a different key"), match_mode = :any,
                   @test Configuration.load("db"; root = root, env = "test") == db)
        @test collect(keys(PormG.config)) == [db]
        @test PormG.config[db].db_def_folder == canonical

        # The reverse: a short key loaded with `root`, then the same folder named WITHOUT root. The
        # entry is reused, and must keep its absolute folder — overwriting it with the bare key
        # `"db"` would point `makemigrations` at `<pwd>/db/models.jl`.
        empty!(PormG.config)
        Configuration.load("db"; root = root, env = "test")
        @test_logs((:warn, r"already loaded under a different key"), match_mode = :any,
                   @test Configuration.load(db; env = "test") == "db")
        @test collect(keys(PormG.config)) == ["db"]
        @test PormG.config["db"].db_def_folder == canonical
    end
end

@testset "a model imported by relative path binds to the short key by path" begin
    _lr857_with_project() do root, elsewhere
        # A decoy: an unrelated folder that is also named `db`. With the old relative folder the
        # short key could only match by folder NAME, and two folders share that name, so the
        # binding was a warned ambiguity. Under `root` the short key is an exact path hit.
        decoy = joinpath(elsewhere, "vendor", "db")
        mkpath(decoy)
        write(joinpath(decoy, "connection.yml"), _LR857_YML)
        Configuration.load(decoy; env = "test")
        Configuration.load("db"; root = root, env = "test")

        # How `@import_models "../db/models.jl"` from `<root>/src/App.jl` names the folder.
        imported = joinpath(root, "src", "..", "db")
        @test_logs(min_level = Logging.Warn,
                   @test PormG.Models._resolve_connect_key(imported, PormG.config) == "db")

        # Through the real `set_models`, as `@import_models`'s `__init__` reaches it.
        scratch = Module(:ScratchLoadRoot857)
        Core.eval(scratch, :(import PormG.Models))
        Core.eval(scratch, :(Driver857 = Models.Model("driver857", id = Models.IDField())))
        @test_logs(min_level = Logging.Warn,
                   Base.invokelatest(PormG.Models.set_models, scratch, imported))
        @test Base.invokelatest(getfield, scratch, :Driver857).connect_key == "db"
    end
end

@testset "migrations resolve against the folder, not pwd(), and the hint names the key" begin
    _lr857_with_project() do root, elsewhere
        db_bs = joinpath(root, "db_bs")
        write(joinpath(db_bs, "models.jl"), _LR857_MODELS)
        @test Configuration.load("db_bs"; root = root, env = "test") == "db_bs"

        logger = Test.TestLogger(min_level = Logging.Info)
        with_logger(() -> Migrations.makemigrations("db_bs"; interactive = false), logger)

        # The plan is written under the folder; nothing appears under the working directory.
        @test isfile(joinpath(db_bs, "migrations", "pending_migrations.jl"))
        @test !ispath(joinpath(elsewhere, "db_bs"))

        # The hint tells the user what to call, so it must name the KEY: `migrate(db::String)` looks
        # its argument up as a key, and the absolute folder is not one.
        hint = only(filter(r -> occursin("Migration plan generated", string(r.message)), logger.logs))
        @test occursin("migrate(\"db_bs\")", string(hint.message))
        @test !occursin(root, string(hint.message))

        # …and following it works, archiving under the folder.
        res = with_logger(() -> Migrations.migrate("db_bs"; interactive = false), NullLogger())
        @test res.outcome === :applied
        @test !isempty(readdir(joinpath(db_bs, "migrations", "applied_migrations")))
    end
end

@testset "_settings_key finds the entry by identity, else falls back to the folder" begin
    s = Configuration.Settings(db_def_folder = "/srv/app/db")
    cfg = Dict{String,PormG.PormGSettings}("db" => s)
    @test Configuration._settings_key(s, cfg) == "db"
    # An equal-looking but distinct entry is not the same entry.
    @test Configuration._settings_key(Configuration.Settings(db_def_folder = "/srv/app/db"), cfg) == "/srv/app/db"
end
