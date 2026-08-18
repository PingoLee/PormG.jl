"""
Unit coverage for the schema importers' connection-key resolution contract.

`import_models_from_sqlite` was realigned to take a configuration KEY (`db::String`),
symmetric with `import_models_from_postgres`, instead of a connection object. This file
pins the resulting contract:

  - a missing/unregistered key fails closed with a clear `InvalidConfigurationError` (no silent
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
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!

# Top-level mock connection (struct definitions are forbidden inside @testset bodies).
# Uniquely named so it never clashes with other unit files included into the same module.
if !isdefined(Main, :_MockPgImporterConn)
  struct _MockPgImporterConn <: PormG.PormGPostgres end
end

@testset "Schema importers — connection key resolution" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. An unregistered key fails closed: get_settings raises a clear InvalidConfigurationError
  #    rather than returning nothing (which previously deferred the failure into a
  #    confusing MethodError on `settings === nothing`).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "unregistered key throws InvalidConfigurationError" begin
    @test_throws PormG.InvalidConfigurationError PormG.Migrations.import_models_from_sqlite("totally_unregistered_importer_key_xyz")
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
      @test_throws PormG.BackendCapabilityError PormG.Migrations.import_models_from_sqlite(key)
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

  # ───────────────────────────────────────────────────────────────────────────
  # 4. End-to-end regression for #338: two REAL tables in the same database that render to the
  #    same Julia binding must not have the second silently vanish — pre-fix, the SECOND
  #    `Binding = Models.Model(...)` line overwrites the first's Julia global when the generated
  #    file is `include`d, with no error anywhere. Unit coverage for the dedup itself lives in
  #    test_model_to_str_identifiers.jl; this proves import_models_from_sqlite's loop actually
  #    shares one taken_bindings/taken_names pair across the whole file, not just that Model_to_str
  #    supports it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "colliding table names both survive the generated file (#338)" begin
    mktempdir() do dir
      dbfile   = joinpath(dir, "scratch_collision.sqlite")
      modeldir = joinpath(dir, "generated_models_collision")
      mkpath(modeldir)

      pool = SQLiteConnectionPool(dbfile; pool_size = 1)
      # "driver profile" sanitizes to the binding `Driver_profile` — the SAME binding the
      # already-legal `driver_profile` uppercasefirst's to. (Not `driver`/`Driver`: SQLite table
      # names are case-insensitive, so that pair can't exist as two tables in one database.)
      fetch(pool, "CREATE TABLE \"driver profile\" (id INTEGER PRIMARY KEY);")
      fetch(pool, "CREATE TABLE driver_profile (id INTEGER PRIMARY KEY);")

      key = "importer_collision_test"
      PormG.config[key] = Configuration.Settings(
        connections   = pool,
        db_def_folder = modeldir,
        change_data   = true,
      )
      try
        PormG.Migrations.import_models_from_sqlite(key)

        outfile = joinpath(modeldir, "automatic_models.jl")
        @test isfile(outfile)
        content = read(outfile, String)

        # Both bindings present and DISTINCT in the source text — the whole point of the fix.
        @test occursin("Driver_profile = Models.Model(", content)
        @test occursin("Driver_profile2 = Models.Model(", content)

        # And the file actually loads, with BOTH models independently addressable — neither
        # shadowed the other — each still pointing at its own real physical table.
        # `Base.invokelatest`: `Base.eval` below bumps the world age (Julia 1.12), so reading the
        # freshly-defined bindings back in this same closure needs the LATEST world, not the one
        # captured when the enclosing `mktempdir` do-block was compiled.
        scratch = Module(:ImporterCollisionScratch338)
        Base.eval(scratch, :(using PormG))
        Base.eval(scratch, Meta.parse(content))   # the generated `module automatic_models ... end`
        Base.invokelatest() do
          gen_mod = getfield(scratch, :automatic_models)
          m1 = getfield(gen_mod, Symbol("Driver_profile"))
          m2 = getfield(gen_mod, Symbol("Driver_profile2"))
          @test Set([PormG.model_table_name(m1), PormG.model_table_name(m2)]) ==
                Set(["driver profile", "driver_profile"])
        end
      finally
        delete!(PormG.config, key)
        # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5. #360 — a ForeignKey aimed at the collision-SUFFIXED sibling must still reach ITS OWN
  #    table. This is the half #338 explicitly left open: `.to` was derived independently of
  #    the binding (`uppercasefirst(<parent table>)`), so when disambiguation renamed the
  #    binding it was counting on, `.to` still named the un-suffixed spelling and
  #    `_resolve_target_model` — a pure binding lookup — handed back the WRONG sibling.
  #
  #    Two foreign keys, one into each colliding table, on purpose: with only one, the test
  #    would pass whenever that key happened to aim at whichever sibling kept the un-suffixed
  #    binding, which is exactly the broken behaviour. Assertions are on the RESOLVED model's
  #    physical table, never on the generated text — matching `"Driver_profile2"` in the source
  #    would prove the string was written, not that it points anywhere real.
  #
  #    Mutation gate: revert `_plan_inspectdb_bindings!`'s rewrite loop and both foreign keys
  #    resolve to the same model, failing the `!==` test and one of the two table assertions.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a ForeignKey into a collision-suffixed sibling resolves to its own table (#360)" begin
    mktempdir() do dir
      dbfile   = joinpath(dir, "scratch_fk_collision.sqlite")
      modeldir = joinpath(dir, "generated_models_fk_collision")
      mkpath(modeldir)

      pool = SQLiteConnectionPool(dbfile; pool_size = 1)
      # Same colliding pair as testset 4 — both derive the binding `Driver_profile`, so one of
      # them is renamed to `Driver_profile2` in the generated file.
      fetch(pool, "CREATE TABLE \"driver profile\" (id INTEGER PRIMARY KEY);")
      fetch(pool, "CREATE TABLE driver_profile (id INTEGER PRIMARY KEY);")
      # ...and a child holding one real foreign key into EACH of them.
      fetch(pool, """CREATE TABLE pit_stop (
        id INTEGER PRIMARY KEY,
        spaced_id INTEGER REFERENCES "driver profile"(id),
        plain_id  INTEGER REFERENCES driver_profile(id)
      );""")

      key = "importer_fk_collision_test"
      PormG.config[key] = Configuration.Settings(
        connections   = pool,
        db_def_folder = modeldir,
        change_data   = true,
      )
      try
        PormG.Migrations.import_models_from_sqlite(key)
        content = read(joinpath(modeldir, "automatic_models.jl"), String)

        scratch = Module(:ImporterFkCollisionScratch360)
        Base.eval(scratch, :(using PormG))
        Base.eval(scratch, Meta.parse(content))
        # `Base.invokelatest` for the same world-age reason as testset 4.
        Base.invokelatest() do
          gen_mod = getfield(scratch, :automatic_models)
          stop    = getfield(gen_mod, :Pit_stop)

          # Resolve each `.to` exactly the way PormG does at load time: binding lookup, nothing else.
          target_spaced = PormG.Models._resolve_target_model(stop.fields["spaced_id"].to, gen_mod)
          target_plain  = PormG.Models._resolve_target_model(stop.fields["plain_id"].to, gen_mod)

          # Both `.to` strings name a binding the generated file actually defines. (Pre-#360 this
          # already held — both resolved fine, just to the same model.)
          @test target_spaced !== nothing
          @test target_plain  !== nothing

          # The real assertion: each key reaches the table it was declared against.
          @test PormG.model_table_name(target_spaced) == "driver profile"
          @test PormG.model_table_name(target_plain)  == "driver_profile"

          # And they are genuinely two different models — the pre-fix failure was both landing on
          # whichever sibling kept the un-suffixed binding.
          @test target_spaced !== target_plain

          # The breadcrumb that made the rewrite possible is an in-memory detail and must NOT reach
          # the generated file: `ForeignKey` accepts no such kwarg, so every reload would `@warn`
          # and discard it. Guards the `sfield === :to_table` skip in `_model_to_str_foreign_key`.
          @test !occursin("to_table", content)
        end
      finally
        delete!(PormG.config, key)
        close_pool!(pool)
      end
    end
  end

end
