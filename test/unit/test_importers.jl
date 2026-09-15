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

The round-trip uses a hermetic temp SQLite database (in-process), so it needs no external DB
setup and runs in the default suite.
"""

using Test
using PormG
# Three of the testsets below open a real (temporary) SQLite file, so they need the weakdep
# extension. SQLite is NOT a hard dependency of PormG — it has been a `[weakdeps]` since #34, and
# this file's own header used to say otherwise, which is why the guard was never written (#430).
# `runtests.jl` loads the drivers for the whole suite; this line is what makes the file runnable on
# its own (`julia --project=. test/unit/test_importers.jl`) without double-loading under the suite.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
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
        # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
        close_pool!(pool)
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

# ───────────────────────────────────────────────────────────────────────────
# 6. #415 — a genuinely MULTI-COLUMN foreign key is skipped, not split into N single-column ones.
#
#    `PRAGMA foreign_key_list` returns one row per column and groups a composite constraint under
#    a shared `id`. The reader keyed `fk_map` on the child column (`from`) alone, so one composite
#    constraint became TWO independent single-column relations — each plausible on its own, and
#    each regenerating as a separate `REFERENCES parent(col)` that the parent may not even accept,
#    since neither member of a composite key is unique by itself. PormG has no composite-FK field
#    type, so there is nothing faithful to read: the reject-rather-than-reinterpret rule this file
#    already applies to composite UNIQUE and to non-default indexes applies here too.
#
#    This is the SQLite half of a cross-engine change. PostgreSQL excludes the same shape in its
#    `foreign_keys` CTE (`array_length(con.conkey, 1) = 1`), and the two are kept symmetric on
#    purpose — one schema must not read two ways.
#
#    Mutation gate: drop the `columns_per_fk[...] > 1 && continue` skip and `child_a`/`child_b`
#    come back as `sForeignKey`, failing the two `isa` assertions below.
# ───────────────────────────────────────────────────────────────────────────
@testset "a composite foreign key is skipped rather than split (#415)" begin
  mktempdir() do dir
    dbfile = joinpath(dir, "scratch_composite_fk.sqlite")
    pool   = SQLiteConnectionPool(dbfile; pool_size = 1)
    try
      # `parent` carries a two-column PRIMARY KEY; `child` references BOTH columns as one
      # constraint, and separately carries an ordinary single-column FK into a normal parent.
      fetch(pool, "CREATE TABLE parent (a INTEGER, b INTEGER, PRIMARY KEY (a, b));")
      fetch(pool, "CREATE TABLE solo (id INTEGER PRIMARY KEY);")
      fetch(pool, """CREATE TABLE child (
                       id      INTEGER PRIMARY KEY,
                       child_a INTEGER,
                       child_b INTEGER,
                       solo_id INTEGER REFERENCES solo(id),
                       FOREIGN KEY (child_a, child_b) REFERENCES parent(a, b)
                     );""")

      model = PormG.Migrations.convertSQLToModel(pool, "child")

      # The composite members are ordinary columns, not relations. Pre-fix each came back as an
      # `sForeignKey` bound to its own half of the parent key.
      @test !(model.fields["child_a"] isa PormG.Models.sForeignKey)
      @test !(model.fields["child_b"] isa PormG.Models.sForeignKey)
      @test model.fields["child_a"] isa PormG.Models.sIntegerField
      @test model.fields["child_b"] isa PormG.Models.sIntegerField

      # CONTROL, and the reason the skip is per-CONSTRAINT rather than per-table: an ordinary
      # single-column foreign key on the SAME table is untouched. A guard that keyed off "this
      # table has a composite FK" would take this one out with it.
      @test model.fields["solo_id"] isa PormG.Models.sForeignKey
      @test model.fields["solo_id"].pk_field == "id"
      @test model.fields["solo_id"].to_table == "solo"
    finally
      close_pool!(pool)
    end
  end
end


# ─────────────────────────────────────────────────────────────────────────────
# #516: an introspected constraint's unrendered options never reach the generated file
# The SQLite reader parses `ON UPDATE` and `DEFERRABLE INITIALLY` out of the stored DDL, and until
# #516 it threaded both into the reconstructed `ForeignKey` as `on_update=` / `deferrable=`.
# `_model_to_str_foreign_key` emits any slot differing from the constructor default, so a database
# whose foreign keys carried either clause made PormG GENERATE a models file containing keywords
# nobody typed. #516 removed the keywords, which makes that generated file unloadable — so the
# reader must stop producing it. This is the regression guarding that pair: parse the clauses, keep
# `ON DELETE` (the one referential action PormG does render), and carry neither into the field.
# Hermetic — `convertSQLToModel(::String)` parses DDL text, no database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "unrendered constraint options do not survive introspection (#516)" begin
  # Both clauses present, in the order SQLite stores them, plus the ON DELETE that must survive.
  #
  # `ON DELETE RESTRICT` against `ON UPDATE CASCADE` deliberately: the reader destructures six regex
  # captures and #516 replaced two of them with `_` placeholders, so the realistic defect is a
  # capture-index shift. Identical actions on both clauses would make that shift INVISIBLE — the
  # wrong capture would hold the right string — so the two must differ, and the assertion has to pin
  # the value rather than settle for `!== nothing`.
  sql = """CREATE TABLE "lap_time" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    "milliseconds" INTEGER NOT NULL,
    "race_id" INTEGER NOT NULL,
    FOREIGN KEY("race_id") REFERENCES "race"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
  );"""

  model = PormG.Migrations.convertSQLToModel(sql)
  race = model.fields["race_id"]

  # The constraint was parsed — this is not passing because the regex failed to match.
  @test race isa PormG.Models.sForeignKey
  @test race.to_table == "race"
  @test race.pk_field == "id"
  # `ON DELETE` is the referential action PormG renders (#292), so it must still round-trip — and it
  # must be RESTRICT, the clause's own value, not CASCADE leaking in from the `ON UPDATE` capture.
  @test race.on_delete === PormG.RESTRICT

  # The three removed keywords have no slot to land in. Asserted on the instance rather than on the
  # type so this fails loudly if a slot is ever reintroduced without updating the reader.
  for attr in (:on_update, :deferrable, :initially_deferred)
    @test !hasproperty(race, attr)
  end

  # The generated file must not mention them either. String-matched first because that is the
  # artifact a user actually gets handed.
  generated = PormG.Models.Model_to_str(model)
  @test occursin("Models.ForeignKey(", generated)
  for kw in ("on_update", "deferrable", "initially_deferred")
    @test !occursin(kw, generated)
  end

  # And it RELOADS. This is the assertion the string matches cannot make: before #516's reader fix,
  # the generated text carried `on_update="CASCADE"`, which the post-#516 constructor refuses —
  # PormG would have generated a file it then could not load.
  # The scratch module mirrors the envelope `Generator.jl` actually writes — `import PormG.Models`
  # plus the sentinel bindings (`CASCADE`, `SET_NULL`, …) — rather than a hand-rolled `const Models`.
  # Built from `GENERATED_MODULE_RESERVED_BINDINGS`, the same constant the generator reads, so this
  # cannot drift from the real file's imports.
  rmod = Module(:Fk516RoundTripScratch)
  Base.eval(rmod, :(import PormG.Models))
  sentinels = join(filter(!=("Models"), PormG.GENERATED_MODULE_RESERVED_BINDINGS), ", ")
  Base.eval(rmod, Meta.parse("import PormG.Models: $sentinels"))
  reloaded = Base.eval(rmod, Meta.parse(generated))
  @test reloaded.fields["race_id"] isa PormG.Models.sForeignKey

  # Control: a constraint carrying NEITHER optional clause is unaffected, so the assertions above
  # are about the clauses rather than about foreign keys in general.
  plain_sql = """CREATE TABLE "pit_stop" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    "race_id" INTEGER NOT NULL,
    FOREIGN KEY("race_id") REFERENCES "race"("id") ON DELETE CASCADE
  );"""
  plain = PormG.Migrations.convertSQLToModel(plain_sql).fields["race_id"]
  @test plain isa PormG.Models.sForeignKey
  @test plain.to_table == "race"
end
