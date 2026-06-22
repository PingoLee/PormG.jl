"""
Unit coverage for the schema importers' connection-key resolution contract.

`import_models_from_sqlite` was realigned to take a configuration KEY (`db::String`),
symmetric with `import_models_from_postgres`, instead of a connection object. This file
pins the resulting contract:

  - a missing/unregistered key fails closed with a clear `ArgumentError` (no silent
    `MODEL_PATH` fallback, and no confusing downstream `MethodError`),
  - a key bound to a non-SQLite connection is rejected explicitly by the dialect guard,
  - the generated model file lands in the *resolved connection's* `db_def_folder` — the
    regression guard for the old hardcoded-`"db"` routing bug (the importer must follow
    the passed key, not a fixed key/path).

The round-trip uses a hermetic temp SQLite database (in-process; SQLite is a hard
dependency of PormG), so it needs no external DB setup and runs in the default suite.
"""

using Test
using PormG
import PormG: Configuration
import PormG.ConnectionPool: SQLiteConnectionPool, fetch

# Top-level mock connection (struct definitions are forbidden inside @testset bodies).
# Uniquely named so it never clashes with other unit files included into the same module.
if !isdefined(Main, :_MockPgImporterConn)
  struct _MockPgImporterConn <: PormG.PormGPostgres end
end

@testset "Schema importers — connection key resolution" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. An unregistered key fails closed: get_settings raises a clear ArgumentError
  #    rather than returning nothing (which previously deferred the failure into a
  #    confusing MethodError on `settings === nothing`).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "unregistered key throws ArgumentError" begin
    @test_throws ArgumentError PormG.Migrations.import_models_from_sqlite("totally_unregistered_importer_key_xyz")
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. A key that resolves to a non-SQLite connection is rejected by the dialect
  #    guard, instead of silently dispatching to the PostgreSQL introspection path.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "non-SQLite connection is rejected" begin
    key = "importer_wrong_dialect_test"
    PormG.config[key] = Configuration.Settings(
      connections   = _MockPgImporterConn(),
      db_def_folder = mktempdir(),
    )
    try
      @test_throws ArgumentError PormG.Migrations.import_models_from_sqlite(key)
    finally
      delete!(PormG.config, key)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3. Round-trip: the model file lands in the resolved connection's db_def_folder,
  #    proving the importer follows the passed key. Under the old hardcoded-"db"
  #    behaviour this file would be written elsewhere (or the lookup would throw),
  #    so `isfile(outfile)` discriminates the fix from the bug.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "models written to the resolved connection's folder" begin
    mktempdir() do dir
      dbfile   = joinpath(dir, "scratch.sqlite")
      modeldir = joinpath(dir, "generated_models")
      mkpath(modeldir)

      pool = SQLiteConnectionPool(dbfile; pool_size = 1)
      # Seed a trivial table through the same pool the importer will introspect.
      fetch(pool, "CREATE TABLE driver (driverid INTEGER PRIMARY KEY, surname TEXT);")

      key = "importer_roundtrip_test"
      PormG.config[key] = Configuration.Settings(
        connections   = pool,
        db_def_folder = modeldir,
        change_data   = true,
      )
      try
        PormG.Migrations.import_models_from_sqlite(key)

        outfile = joinpath(modeldir, "automatic_models.jl")
        @test isfile(outfile)                          # written to THIS key's folder
        content = read(outfile, String)
        @test occursin("driver", lowercase(content))   # the introspected table is present
      finally
        delete!(PormG.config, key)
      end
    end
  end

end
