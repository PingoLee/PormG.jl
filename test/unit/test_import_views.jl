"""
UNIT TESTS: `inspectdb` with `include_views = true` — views written as unmanaged, keyless models (#767)

Views are deliberately absent from the live table list (#730), so the SQLite and PostgreSQL importers
never wrote one. With `managed = false` (#741) a view can be modelled, and `include_views = true` now
writes each view as such a model. What each testset below proves against the unpatched code:

  * views are imported ONLY on request, after the tables, `managed = false`, under the same
    `include_table` / ignore filters as the tables;
  * a view model is keyless — no key is guessed, since nothing in a view guarantees one — and carries
    a `# PormG:` marker saying so (the maintainer's decision on #767);
  * the generated file loads, the view model reads its rows, and `makemigrations` over the whole
    generated set plans nothing;
  * the view reader is separate from `read_live_schema`, so the #730 guarantee — `makemigrations`
    never sees a view — holds by construction, and the PostgreSQL dump asks for views only when told.

Hermetic: a temp SQLite file, plus a PostgreSQL stand-in that records the SQL it is sent. The live
PostgreSQL half (a real view and a materialized view) is in
`test/integration/test_importers_introspection.jl`.

`_iv`-prefixed throughout: `runtests.jl` includes every unit file into ONE module.
"""

using Test
using Logging
using DataFrames
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, model_table_name, model_is_managed
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: read_live_schema, read_live_views, get_migration_plan

# The F1 shape every testset shares: two tables, a view over a join and a view over one table.
function _iv_seed!(pool)
  fetch(pool, "CREATE TABLE driver (driverid INTEGER PRIMARY KEY, surname TEXT NOT NULL);")
  fetch(pool, "CREATE TABLE result (resultid INTEGER PRIMARY KEY, " *
              "driverid INTEGER NOT NULL REFERENCES driver(driverid), points REAL NOT NULL);")
  fetch(pool, "CREATE VIEW driver_points AS SELECT d.driverid, d.surname, SUM(r.points) AS points " *
              "FROM driver d JOIN result r ON r.driverid = d.driverid GROUP BY d.driverid, d.surname;")
  fetch(pool, "CREATE VIEW senna_results AS SELECT resultid, points FROM result WHERE driverid = 1;")
  fetch(pool, "INSERT INTO driver (driverid, surname) VALUES (1, 'Senna'), (2, 'Prost');")
  fetch(pool, "INSERT INTO result (resultid, driverid, points) VALUES (1, 1, 9.0), (2, 1, 6.0), (3, 2, 4.0);")
  return pool
end

# Run `f(pool, key, modeldir)` against a fresh seeded database registered under its own key. The key
# IS the model folder, so `set_models(generated_module, key)` finds this connection.
function _iv_with_db(f)
  mktempdir() do dir
    modeldir = joinpath(dir, "generated_views")
    mkpath(modeldir)
    pool = _iv_seed!(SQLiteConnectionPool(joinpath(dir, "views767.sqlite"); pool_size = 1))
    PormG.config[modeldir] = Configuration.Settings(connections = pool, db_def_folder = modeldir, change_data = true)
    try
      f(pool, modeldir, modeldir)
    finally
      delete!(PormG.config, modeldir)
      close_pool!(pool)   # releases the file, or mktempdir cannot remove it on Windows
    end
  end
end

# The text of one generated model, from its binding line to the next blank line.
_iv_block(content, binding) = match(Regex("(?ms)^$(binding) = Models\\.Model\\(.*?(?=\\n\\n|\\nend)"), content)

# ─────────────────────────────────────────────────────────────────────────────
# SQLite importer: views are written only on request, as managed = false keyless models (#767)
# Without the option nothing changes. With it, each view is a model after the tables, carrying
# `managed = false`, no primary key, and the marker directly above it; the tables carry no marker.
# `include_table` and `ignore_schema` filter views by name exactly as they filter tables.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite importer: include_views writes views as managed = false keyless models (#767)" begin
  _iv_with_db() do pool, key, modeldir
    outfile = joinpath(modeldir, "automatic_models.jl")

    # The default is unchanged: tables only.
    PormG.Migrations.import_models_from_sqlite(key; force_replace = true)
    content = read(outfile, String)
    @test occursin("Driver = Models.Model(\"driver\"", content)
    @test !occursin("driver_points", content)
    @test !occursin("senna_results", content)

    # Opted in: both views, after both tables.
    PormG.Migrations.import_models_from_sqlite(key; force_replace = true, include_views = true)
    content = read(outfile, String)
    @test findfirst("Result = Models.Model(", content).start < findfirst("Driver_points = Models.Model(", content).start
    marker = "# PormG: generated from the view 'driver_points' — managed = false, so migrations never " *
             "create, alter or drop it. A view has no primary key, so none is declared: reads work, but " *
             "writes that address rows by key (a filtered delete, bulk_update without match_on) need one — " *
             "mark a column that is unique in the view primary_key = true.\n" *
             # SUM(points) has no declared type on SQLite: named, so the reader declares it by hand.
             "# PormG: the database reports no type for 'points' of the view 'driver_points' — SQLite " *
             "gives none to a computed column — so it is emitted as TextField. Declare the real field " *
             "type by hand: as a TextField, a filter compares the column as text.\n" *
             "Driver_points = Models.Model(\"driver_points\""
    @test occursin(marker, content)
    # `senna_results` only selects columns, which keep their table's types: no second marker.
    @test count("# PormG: the database reports no type", content) == 1
    view = _iv_block(content, "Driver_points")
    @test view !== nothing
    @test occursin("managed = false", view.match)
    # Keyless: no IDField and no primary_key anywhere in the view's model — the key is never guessed,
    # even for `driverid`, which is unique in this view but nothing in the view guarantees it.
    @test !occursin("IDField", view.match)
    @test !occursin("primary_key", view.match)
    @test occursin("driverid = Models.IntegerField(", view.match)
    # A table keeps its key and carries no marker.
    @test !occursin("generated from the view 'driver'", content)
    @test occursin("driverid = Models.IDField(", _iv_block(content, "Driver").match)
    @test count("# PormG: generated from the view", content) == 2

    # The table filters reach views too.
    PormG.Migrations.import_models_from_sqlite(key; force_replace = true, include_views = true,
                                               include_table = ["driver", "driver_points"])
    content = read(outfile, String)
    @test occursin("Driver_points = Models.Model(", content)
    @test !occursin("senna_results", content)
    @test !occursin("Result = Models.Model(", content)

    PormG.Migrations.import_models_from_sqlite(key; force_replace = true, include_views = true,
                                               ignore_schema = ["senna_"])
    content = read(outfile, String)
    @test occursin("Driver_points = Models.Model(", content)
    @test !occursin("senna_results", content)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite importer: the generated view model loads, reads its rows, and plans nothing (#767)
# The file is evaluated and registered against the database it came from. The view model is
# unmanaged and keyless on the live object, its rows come back through the ORM, and a plan over
# every generated model — tables and views — is empty, so adopting the file changes no schema.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite importer: a generated view model loads, reads its rows, and plans nothing (#767)" begin
  _iv_with_db() do pool, key, modeldir
    PormG.Migrations.import_models_from_sqlite(key; force_replace = true, include_views = true)
    scratch = Module(:ImportViewsScratch767)
    Base.eval(scratch, :(using PormG))
    Base.eval(scratch, Meta.parse(read(joinpath(modeldir, "automatic_models.jl"), String)))

    # `invokelatest`: the module above was defined during this call, so its bindings are newer than
    # this closure's world age (Julia 1.12).
    Base.invokelatest() do
      gen = getfield(scratch, :automatic_models)
      PormG.Models.set_models(gen, key)
      points = getfield(gen, :Driver_points)

      @test !model_is_managed(points)
      @test PormG.Models.get_model_pk_field(points) === nothing
      @test model_is_managed(getfield(gen, :Driver))

      # Reads work, filter included.
      senna = points.objects.filter("surname" => "Senna").values("points").list()
      @test length(senna) == 1
      @test senna[1][:points] == 15.0
      @test points.objects.count() == 2
      @test getfield(gen, :Senna_results).objects.count() == 2
      # The pitfall docs/src/models.md states, and the reason for the untyped-column marker: the
      # computed column is a TextField, so a numeric filter binds text and matches nothing on SQLite.
      @test isempty(points.objects.filter("points__@gt" => 10).values("surname").list())

      # makemigrations over the whole generated set: nothing to do.
      models = [getfield(gen, b) for b in (:Driver, :Result, :Driver_points, :Senna_results)]
      schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
        Symbol(model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false)
        for m in models)
      settings = Configuration.Settings(); settings.change_db = true
      plan = get_migration_plan(read_live_schema(pool), schema, pool, settings; interactive = false)
      @test all(isempty, values(plan))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite importer: a view that no longer resolves is skipped and reported, not fatal (#767)
# SQLite lets a table a view reads be dropped, and the pragma on such a view then raises. Before this
# guard one stale view aborted the whole import — tables included. Now the tables and every readable
# view are written, and the stale view is named in a marker and a warning.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite importer: a view that no longer resolves is skipped and reported, not fatal (#767)" begin
  _iv_with_db() do pool, key, modeldir
    fetch(pool, "CREATE TABLE pitstop_scratch (stop INTEGER);")
    fetch(pool, "CREATE VIEW stale_stops AS SELECT stop FROM pitstop_scratch;")
    fetch(pool, "DROP TABLE pitstop_scratch;")

    content = with_logger(NullLogger()) do
      PormG.Migrations.import_models_from_sqlite(key; force_replace = true, include_views = true)
      read(joinpath(modeldir, "automatic_models.jl"), String)
    end
    @test occursin("Driver = Models.Model(\"driver\"", content)
    @test occursin("Driver_points = Models.Model(\"driver_points\"", content)
    @test occursin("# PormG: a view could not be read, so it is not imported — stale_stops: ", content)
    @test !occursin("Stale_stops = Models.Model(", content)

    # The reader reports it through `unreadable`, and warns.
    unreadable = String[]
    @test_logs (:warn, r"the view could not be read") match_mode = :any read_live_views(pool; unreadable = unreadable)
    @test length(unreadable) == 1 && startswith(only(unreadable), "stale_stops: ")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The view reader is separate from read_live_schema, which still never sees a view (#730, #767)
# `makemigrations`, `status()` and `check()` read through `read_live_schema`, so the views must be
# read by a different function rather than behind a flag on it. On PostgreSQL the schema dump asks for
# `relkind IN ('v', 'm')` only when told to, and keeps the extension-ownership filter either way.
# ─────────────────────────────────────────────────────────────────────────────
struct ViewsCaptureMockPg767 <: PormG.PormGPostgres end
const IV_PG_SQL = String[]
# #1032: the schema reader asks the server version first (the PostgreSQL 13 floor, #1108); answered here
# and not recorded, so the captured statements are the schema reads alone.
fetch(::ViewsCaptureMockPg767, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
  occursin("server_version_num", sql) ? DataFrame(v = [160000]) :
  (push!(IV_PG_SQL, sql); DataFrame())

@testset "read_live_views is separate from read_live_schema, which still never sees a view (#730, #767)" begin
  _iv_with_db() do pool, _, _
    @test sort([t.name for t in read_live_views(pool)]) == ["driver_points", "senna_results"]
    @test sort([t.name for t in read_live_schema(pool)]) == ["driver", "result"]
    # A view has no key and no foreign key, so its LiveTable is columns only.
    v = only(filter(t -> t.name == "driver_points", read_live_views(pool)))
    @test collect(keys(v.columns)) == ["driverid", "surname", "points"]
  end

  empty!(IV_PG_SQL)
  with_logger(NullLogger()) do
    PormG.Migrations.get_database_schema(ViewsCaptureMockPg767())
    PormG.Migrations.read_live_views(ViewsCaptureMockPg767())
  end
  tables_sql, views_sql = IV_PG_SQL
  @test occursin("WHERE c.relkind = 'r'", tables_sql)
  @test !occursin("relkind IN", tables_sql)
  @test occursin("WHERE c.relkind IN ('v', 'm')", views_sql)
  @test occursin(PormG.Migrations._PG_OWNABLE_TABLE_FILTER, views_sql)
end
