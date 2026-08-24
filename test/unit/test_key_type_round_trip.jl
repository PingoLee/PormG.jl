"""
Unit coverage for the integer/natural primary-key round trip (#408, #409) and for the
`sOneToOneField` DDL gap the two of them exposed.

Three defects that compounded, all about a key that is not a plain `IDField`:

  * **#408** — `AutoField` was documented as "INTEGER with SERIAL" and rendered **`TEXT`** on both
    backends, because `Dialect._get_column_type` had no `sAutoField` branch and the field fell
    through to the `else`. No sequence, no identity, no `AUTOINCREMENT`. It is now retired: the
    name survives only as a stub that raises, naming `IDField`.
  * **#409** — both schema readers force-converted every non-UUID primary key to `IDField`. A model
    declaring any other key type could therefore never equal what introspection reported, and
    `makemigrations` proposed the same `ALTER` on that column on every run — on SQLite as a full
    table rebuild. Worse, the `primary_key` arm ran BEFORE the `fk_map` arm, so a key that was also
    a foreign key came back as a bare `IDField` with the relation silently discarded.
  * **`sOneToOneField`** had #408's exact shape: no `_get_column_type` branch (so `TEXT`), and the
    SQLite `CREATE TABLE` foreign-key clause gated on `isa sForeignKey` (so no constraint at all).
    It had to be fixed before a pk-fk could be reconstructed as a relation without making the
    round trip strictly worse.

Why this file pins the RENDERED column rather than the constructor's `type` slot: that gap is
exactly why #408 went unnoticed for so long. `test_field_kwargs_equivalence.jl` froze
`type="INTEGER"` on the struct while every DDL path the struct fed returned `"TEXT"`, and nothing
compared the two.

Rendering is hermetic — `_get_column_type` / `field_to_column` dispatch on the abstract backend
marker and never touch connection state, so a bare marker struct is a sufficient `conn` (the
pattern from `test_column_equivalence.jl`). The convergence half uses a hermetic temp SQLite, as
`test_ignore_tables_registry.jl` does. The live-database counterpart is
`test/integration/test_migration_bootstrap.jl`'s `assert_no_schema_drift`.
"""

using Test
using PormG
using DataFrames
# The convergence testset opens a real (temporary) SQLite file, so it needs the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable on its own
# (`julia --project=. test/unit/test_key_type_round_trip.jl`) without double-loading under the suite.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG.Models
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: convert_schema_to_models

struct MockPgKey <: PormG.PormGPostgres end
struct MockSlKey <: PormG.PormGSQLite end

const PGK = MockPgKey()
const SLK = MockSlKey()

# Local alias — the rendered column type is what these tests are ABOUT, so it is worth naming.
Dialect_get(f, conn) = PormG.Dialect._get_column_type(f, conn)

# A one-row "introspection result" for the PostgreSQL reader, which takes a `DataFrameRow` and
# nothing else. Same shape as `_introspection_row` in test_introspection_guards.jl; duplicated
# rather than shared because the two files are included independently.
function _key_row(; table_name, columns, primary_keys,
                    foreign_keys = missing, foreign_tables = missing,
                    referenced_primary_keys = missing, delete_rules = missing,
                    index_columns = missing, index_names = missing)
  DataFrames.DataFrame(
    table_name = [table_name], columns = [columns], primary_keys = [primary_keys],
    foreign_keys = [foreign_keys], foreign_tables = [foreign_tables],
    referenced_primary_keys = [referenced_primary_keys], delete_rules = [delete_rules],
    index_columns = [index_columns], index_names = [index_names])[1, :]
end

# ─────────────────────────────────────────────────────────────────────────────
# #408: AutoField is retired, and says so usefully
# A consuming app must fail at the declaration with an actionable message, not with an
# `UndefVarError` raised from somewhere inside a generated models file.
# ─────────────────────────────────────────────────────────────────────────────
@testset "AutoField is retired and names its replacement (#408)" begin
  @test_throws PormG.FieldValidationError Models.AutoField()

  msg = try
    Models.AutoField()
    ""
  catch e
    sprint(showerror, e)
  end
  @test occursin("IDField", msg)      # the replacement, by name
  @test occursin("#408", msg)         # where to read the reasoning
  @test occursin("UPGRADING", msg)    # where the migration recipe lives

  # It must be gone as a TYPE, not merely unreachable through the constructor: a lingering
  # `sAutoField` would still be a valid field in a hand-built model and would still render TEXT.
  @test !isdefined(Models, :sAutoField)
end

# ─────────────────────────────────────────────────────────────────────────────
# #408: the RENDERED column for a one-to-one, on both backends
# `sOneToOneField` is not a subtype of `sForeignKey` — both are bare `PormGField` — so an
# `isa sForeignKey` gate silently misses it. It rendered `text`/`TEXT`, the referenced key's type
# being `BIGINT` on the struct all along. This fixes the DDL gates only; several gates of the same
# shape remain in `src/querybuilder/` (lazy traversal, `save()`'s FK handling), which this change
# makes more reachable rather than less.
# ─────────────────────────────────────────────────────────────────────────────
@testset "OneToOneField renders the referenced key's column type (#408)" begin
  o2o = Models.OneToOneField("Driver", pk_field = "id", on_delete = Models.CASCADE)
  fk  = Models.ForeignKey("Driver", pk_field = "id", on_delete = Models.CASCADE)

  # THE mutation gate: both were `"TEXT"` before the fix, on both backends.
  @test Dialect_get(o2o, PGK) == "bigint"
  @test Dialect_get(o2o, SLK) == "INTEGER"

  # A one-to-one is a foreign key plus UNIQUE, so its column must match the plain FK's exactly.
  @test Dialect_get(o2o, PGK) == Dialect_get(fk, PGK)
  @test Dialect_get(o2o, SLK) == Dialect_get(fk, SLK)

  # …and the full column, where the UNIQUE that distinguishes the two shows up.
  @test occursin("bigint", PormG.Dialect.field_to_column("driver_id", o2o, PGK))
  @test occursin("UNIQUE", PormG.Dialect.field_to_column("driver_id", o2o, PGK))
  @test occursin("INTEGER", PormG.Dialect.field_to_column("driver_id", o2o, SLK))
end

# ─────────────────────────────────────────────────────────────────────────────
# #408: SQLite CREATE TABLE emits the one-to-one's FOREIGN KEY clause
# The inline clause is built in a second pass over the model's fields, gated on the concrete type.
# `isa sForeignKey` silently produced a table with the column and no constraint — so a one-to-one
# relation existed in the model and nowhere in the database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite CREATE TABLE carries the OneToOneField constraint (#408)" begin
  parent = Models.Model("driver", id = Models.IDField(), surname = Models.CharField(max_length = 50))
  child  = Models.Model("driver_seat",
              id        = Models.IDField(),
              driver_id = Models.OneToOneField(parent, pk_field = "id", on_delete = Models.CASCADE),
              backup_id = Models.ForeignKey(parent, pk_field = "id", on_delete = Models.CASCADE))

  sql = PormG.Dialect.create_table(SLK, child)
  sql = sql isa AbstractString ? sql : join(sql, "\n")

  # THE mutation gate — this clause did not exist before the fix.
  @test occursin("FOREIGN KEY (\"driver_id\") REFERENCES \"driver\"(\"id\")", sql)
  # The plain FK's clause is the control: it was always emitted, so its presence proves the
  # assertion above is testing the O2O and not the second pass as a whole.
  @test occursin("FOREIGN KEY (\"backup_id\") REFERENCES \"driver\"(\"id\")", sql)
  # And the column itself is an integer, not TEXT.
  @test occursin("\"driver_id\" INTEGER", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #409: a key that is not an IDField CONVERGES
# This is the issue's own acceptance criterion, and the shape no existing test covered. A live
# SQLite schema is introspected and compared against the model a developer would DECLARE for it;
# unequal means `makemigrations` proposes an alteration, and it would propose the same one again
# after applying it, forever.
#
# Hermetic: a temp SQLite file, created and introspected in-process. No fixture database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a non-IDField key converges against its own live table (#409)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "keys.sqlite"); pool_size = 1)
    try

    # Exactly what PormG's own DDL emits for the declarations below.
    fetch(pool, """CREATE TABLE "natural_key" (
                     "code"  TEXT(20) PRIMARY KEY UNIQUE NOT NULL,
                     "label" TEXT(50) NOT NULL)""")
    fetch(pool, """CREATE TABLE "parent_t" (
                     "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                     "n"  INTEGER NOT NULL)""")
    fetch(pool, """CREATE TABLE "profile_t" (
                     "parent_id" INTEGER PRIMARY KEY UNIQUE NOT NULL,
                     "bio"       TEXT(80) NOT NULL,
                     FOREIGN KEY ("parent_id") REFERENCES "parent_t"("id") ON DELETE CASCADE)""")

    live = convert_schema_to_models(pool;
             include_table = ["natural_key", "parent_t", "profile_t"])
    by = Dict(lowercase(string(m.name)) => m for m in live)

    # ── what introspection reconstructs ──────────────────────────────────────
    code = by["natural_key"].fields["code"]
    @test code isa Models.sCharField        # was sIDField — the flattening
    @test code.primary_key
    @test code.max_length == 20             # the length that makes it match the live column

    pid = by["profile_t"].fields["parent_id"]
    # `sOneToOneField`, matching what the PostgreSQL reader produces for the same physical schema.
    # An earlier revision emitted `sForeignKey` here, which converged on SQLite and churned forever
    # on PostgreSQL for a declared `OneToOneField(primary_key=true)` — the Django importer's output
    # for every profile/extension table. A per-backend answer does not fix #409, it relocates it.
    @test pid isa Models.sOneToOneField     # was sIDField, relation DISCARDED
    @test pid.primary_key
    @test pid.to_table == "parent_t"
    @test pid.pk_field == "id"

    # ── and the convergence itself ───────────────────────────────────────────
    parent = Models.Model("parent_t", id = Models.IDField(), n = Models.IntegerField())
    natural = Models.Model("natural_key",
                code  = Models.CharField(primary_key = true, max_length = 20),
                label = Models.CharField(max_length = 50))
    profile = Models.Model("profile_t",
                parent_id = Models.OneToOneField(parent, primary_key = true, pk_field = "id",
                                                 on_delete = Models.CASCADE),
                bio       = Models.CharField(max_length = 80))

    # THE assertion #409 asks for: declared == live, so the planner proposes nothing.
    @test Models.are_model_fields_equal(natural, by["natural_key"])
    @test Models.are_model_fields_equal(profile, by["profile_t"])
    # The plain integer key is the control — it converged before this change and must still.
    @test Models.are_model_fields_equal(parent, by["parent_t"])
    finally
      # Windows will not remove the temp dir while the file handle is open, so `mktempdir` prints a
      # cleanup error and leaks the directory. `test_ignore_tables_registry.jl` — the pattern this
      # file follows — has the same leak; it is not copied here.
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The two readers must classify the SAME schema the SAME way (#409)
#
# #409 is "declared and live disagree". Two READERS that disagree with each other is the same defect
# wearing a different hat: whichever field type a model declares, one backend converges and the
# other proposes `:type` on every `makemigrations` — a full table rebuild on SQLite — and no single
# models file can satisfy both. So the agreement is asserted directly, not left to be inferred from
# two tests in different files.
#
# The PostgreSQL side is hermetic (`convertSQLToModel(::DataFrameRow)`); the SQLite side needs a
# real file because its reader is driven by PRAGMAs.
# ─────────────────────────────────────────────────────────────────────────────
@testset "both readers classify one schema identically (#409)" begin
  pg_row = _key_row(
    table_name              = "profile_t",
    columns                 = "parent_id bigint NOT NULL",
    primary_keys            = "parent_id",
    foreign_keys            = "parent_id",
    foreign_tables          = "parent_t",
    referenced_primary_keys = "id",
    delete_rules            = "c")
  pg_field = PormG.Migrations.convertSQLToModel(pg_row).fields["parent_id"]

  sl_field = mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "agree.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "parent_t" ("id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL)""")
      fetch(pool, """CREATE TABLE "profile_t" ("parent_id" INTEGER PRIMARY KEY UNIQUE NOT NULL,
                       FOREIGN KEY ("parent_id") REFERENCES "parent_t"("id") ON DELETE CASCADE)""")
      models = convert_schema_to_models(pool; include_table = ["parent_t", "profile_t"])
      only(m for m in models if lowercase(string(m.name)) == "profile_t").fields["parent_id"]
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end

  # THE assertion. Same physical table, same reconstructed type.
  @test typeof(pg_field) === typeof(sl_field)
  @test pg_field isa Models.sOneToOneField
  @test pg_field.primary_key && sl_field.primary_key
  @test pg_field.pk_field == sl_field.pk_field == "id"
  @test pg_field.to_table == sl_field.to_table == "parent_t"
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite accepts three spellings for a textual key, and all three must reconstruct (#409)
#
# `sqlite_type_map` maps `TEXT`, `VARCHAR` and `CHAR` onto `CharField` precisely for schemas PormG
# did not create — which is the whole population the natural-key branch serves. Gating that branch
# on `TEXT` alone left `VARCHAR(20) PRIMARY KEY` flattened to `IDField` on SQLite while PostgreSQL
# reconstructed the identical column, so the same legacy schema converged on one engine only.
#
# The lengthless case is asserted too, because it is a DOCUMENTED limitation rather than an
# oversight, and a documented limitation with no test is just a comment.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite reconstructs TEXT(n), VARCHAR(n) and CHAR(n) keys alike (#409)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "spellings.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "t_key"  ("code" TEXT(20)    PRIMARY KEY UNIQUE NOT NULL)""")
      fetch(pool, """CREATE TABLE "v_key"  ("code" VARCHAR(20) PRIMARY KEY UNIQUE NOT NULL)""")
      fetch(pool, """CREATE TABLE "c_key"  ("code" CHAR(8)     PRIMARY KEY UNIQUE NOT NULL)""")
      fetch(pool, """CREATE TABLE "bare_key" ("code" TEXT      PRIMARY KEY UNIQUE NOT NULL)""")

      models = convert_schema_to_models(pool;
                 include_table = ["t_key", "v_key", "c_key", "bare_key"])
      by = Dict(lowercase(string(m.name)) => m for m in models)

      for (t, len) in (("t_key", 20), ("v_key", 20), ("c_key", 8))
        f = by[t].fields["code"]
        @test f isa Models.sCharField
        @test f.primary_key
        @test f.max_length == len
      end

      # Lengthless: nothing to reconstruct into. `CharField()` would invent `max_length = 250` and
      # never match the live bare `TEXT`; `TextField` does not accept `primary_key` at all. The
      # `IDField` fallback is deliberate and is documented at the branch.
      @test by["bare_key"].fields["code"] isa Models.sIDField
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A UUID key that is ALSO a foreign key stays a UUIDField, on both readers (#334 × #409)
#
# Reordering the arms for the pk-fk case is what makes this worth pinning: hoisting the foreign-key
# check above the WHOLE primary-key block — the obvious way to write that fix — puts it above the
# UUID arm too, and a `UUID PRIMARY KEY REFERENCES …` column then reads back as an integer relation
# on SQLite while PostgreSQL still reads a `UUIDField`. The arm order in the two readers is the
# thing under test here, not the UUID handling itself.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a UUID key that is also an FK stays a UUIDField (#334 × #409)" begin
  pg = PormG.Migrations.convertSQLToModel(_key_row(
    table_name              = "uuid_profile",
    columns                 = "uid uuid NOT NULL",
    primary_keys            = "uid",
    foreign_keys            = "uid",
    foreign_tables          = "uuid_parent",
    referenced_primary_keys = "uid",
    delete_rules            = "c")).fields["uid"]
  @test pg isa Models.sUUIDField

  sl = mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "uuidfk.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "uuid_parent"  ("uid" UUID PRIMARY KEY UNIQUE NOT NULL)""")
      fetch(pool, """CREATE TABLE "uuid_profile" ("uid" UUID PRIMARY KEY UNIQUE NOT NULL,
                       FOREIGN KEY ("uid") REFERENCES "uuid_parent"("uid"))""")
      models = convert_schema_to_models(pool; include_table = ["uuid_parent", "uuid_profile"])
      only(m for m in models if lowercase(string(m.name)) == "uuid_profile").fields["uid"]
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
  @test sl isa Models.sUUIDField
  @test typeof(pg) === typeof(sl)

  # …and the same `db_index` rule the CharField key arm follows. `UUIDField` defaults
  # `db_index=false`, so an arm passing the literal `true` — as the PostgreSQL one did until #409 —
  # permanently disagrees with a plain `UUIDField(primary_key=true)` declaration, and disagrees with
  # the SQLite reader too, which passes nothing. Only `IDField` defaults `db_index=true`, so only
  # its arm may hardcode it.
  plain_uuid_pg = PormG.Migrations.convertSQLToModel(_key_row(
    table_name   = "uuid_key",
    columns      = "uid uuid NOT NULL",
    primary_keys = "uid")).fields["uid"]
  @test plain_uuid_pg isa Models.sUUIDField
  @test plain_uuid_pg.db_index == Models.UUIDField(primary_key = true).db_index
  @test plain_uuid_pg.db_index == false
end
