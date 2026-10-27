"""
`IDField(generated = false)` is a key no engine fills, in the DDL and on the write path (#1393).

Since #1334 `generated` is the one keyword that controls identity, but only PostgreSQL's DDL read it.
The write paths read the `sIDField.auto_increment` slot, which is `true` on every `IDField`, and SQLite
and MySQL rendered AUTOINCREMENT/AUTO_INCREMENT on every `IDField` key. So:

  * `allocate_primary_keys` on PostgreSQL ran `nextval(pg_get_serial_sequence(…))` on a column with no
    sequence and returned the frame with the ids missing, no error; on SQLite it allocated ids;
  * `bulk_insert` treated an all-blank key column as absent and left it out of the INSERT;
  * on SQLite and MySQL the column was a database-generated key whatever `generated` said.

`Models._database_generates` is now the one answer, read by every engine's DDL, by
`_column_identity` and by the write path. This file pins that they agree (hermetic, marker
connections), and checks the SQLite half end to end on a temp file: the rowid-alias reader, the
identity delta against the old DDL, inspectdb, `allocate_primary_keys` and `bulk_insert`. The
PostgreSQL and MySQL halves are in `test/integration/test_idfield_generated_key.jl`.

Every testset fails on the code before #1393 (measured on a copy of it). The predicate-agreement one
fails there only because the predicate did not exist: its readers agreed then too, all ignoring
`generated` on SQLite and MySQL, which the testsets after it catch.
"""
# julia --project=test/integration test/unit/test_idfield_generated_key.jl

using Test
using DataFrames
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.Models as IGK_M
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.QueryBuilder: bulk_insert, allocate_primary_keys

const _IGK_Mig = PormG.Migrations
const _IGK_QB = PormG.QueryBuilder

struct IgkPg <: PormG.PormGPostgres end
struct IgkSl <: PormG.PormGSQLite end
struct IgkMy <: PormG.PormGMySQL end
# The catalog read `alter_field(::PormGMySQL)` makes before a MODIFY: no hand-made attributes.
PormG._column_attributes(::IgkMy, table::AbstractString, column::AbstractString) = nothing

_igk_err(f) = try
  f(); nothing
catch e
  e
end

# Run `f(pool, key)` against a fresh temp SQLite database registered under its own config key.
function igk_with_sqlite(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "igk1393.sqlite"); pool_size = 1)
    key = "igk1393_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
    try
      f(pool, key)
    finally
      delete!(PormG.config, key)
      close_pool!(pool)   # releases the handle so mktempdir can delete the file on Windows
    end
  end
end

# The F1 circuit table under a key the caller supplies, and under one the database generates.
igk_circuit(key; generated::Bool) = begin
  m = IGK_M.Model(generated ? "igk_circuit_auto" : "igk_circuit_source",
                  circuitid = IGK_M.IDField(generated = generated),
                  name = IGK_M.CharField(max_length = 255))
  m.connect_key = key
  m
end

igk_create!(pool, model) = fetch(pool, "CREATE TABLE \"$(IGK_M.model_table_name(model))\" (" *
  join([PormG.Dialect.field_to_column(String(n), model.fields[String(n)], pool) for n in model.field_names], ", ") * ")")

@testset "IDField(generated = false) on every engine (#1393)" begin

# What: the renderer, the migration IR and the write path give one answer per field and engine.
# Expected: an identity token in the DDL (GENERATED / AUTOINCREMENT / AUTO_INCREMENT) exactly when
# `_column_identity` compiles one, and on SQLite and MySQL exactly when the write path treats the key
# as database-generated. Why: three readers of one fact drifted before — the write path read a slot
# nothing set to `false`, SQLite and MySQL read `sIDField && primary_key`.
@testset "the DDL, the IR and the write path read one predicate" begin
  fields = ["IDField()" => IGK_M.IDField(),
            "IDField(generated_always = true)" => IGK_M.IDField(generated_always = true),
            "IDField(generated = false)" => IGK_M.IDField(generated = false),
            "IDField(primary_key = false)" => IGK_M.IDField(primary_key = false),
            "BigIntegerField()" => IGK_M.BigIntegerField(),
            "UUIDField(primary_key = true, auto_add = true)" => IGK_M.UUIDField(primary_key = true, auto_add = true),
            "CharField(primary_key = true)" => IGK_M.CharField(primary_key = true, max_length = 10)]
  tokens = (IgkPg() => "GENERATED", IgkSl() => "AUTOINCREMENT", IgkMy() => "AUTO_INCREMENT")
  for (label, f) in fields, (conn, token) in tokens
    ddl = PormG.Dialect.field_to_column("circuitid", f, conn)
    identity = _IGK_Mig._column_identity(f, conn) !== nothing
    @test (label, typeof(conn), occursin(token, ddl)) == (label, typeof(conn), identity)
    conn isa PormG.PormGPostgres && continue
    @test (label, typeof(conn), _IGK_QB._is_auto_generated_bulk_primary_key(f)) == (label, typeof(conn), identity)
  end
  @test IGK_M._database_generates(IGK_M.IDField())
  @test !IGK_M._database_generates(IGK_M.IDField(generated = false))
  @test !IGK_M._database_generates(IGK_M.BigIntegerField())
end

# What: on MySQL an identity-only change — `IDField()` ⇄ `IDField(generated = false)` — is one MODIFY
# with foreign-key checks suspended around it; a retype is not wrapped. Expected SQL below. Why: MySQL
# refuses a MODIFY that drops or adds `AUTO_INCREMENT` on a key another table's foreign key references
# (measured on 8.4 in #1393), and with only the identity changing no stored value moves.
@testset "MySQL: an identity-only MODIFY suspends foreign-key checks" begin
  circuit = IGK_M.Model("circuit", circuitid = IGK_M.IDField(), name = IGK_M.CharField(max_length = 255))
  alter(new, old) = PormG.Dialect.alter_field(IgkMy(), circuit, "circuitid", new,
    _IGK_Mig.column_delta(new, _IGK_Mig.column_spec(old, IgkMy(); name = "circuitid"), IgkMy(); name = "circuitid"))
  @test alter(IGK_M.IDField(generated = false), IGK_M.IDField()) ==
        "SET FOREIGN_KEY_CHECKS = 0;\nALTER TABLE `circuit` MODIFY COLUMN `circuitid` BIGINT NOT NULL;\nSET FOREIGN_KEY_CHECKS = 1;"
  @test alter(IGK_M.IDField(), IGK_M.IDField(generated = false)) ==
        "SET FOREIGN_KEY_CHECKS = 0;\nALTER TABLE `circuit` MODIFY COLUMN `circuitid` BIGINT NOT NULL AUTO_INCREMENT;\nSET FOREIGN_KEY_CHECKS = 1;"
  # Not identity alone: a retype keeps MySQL's own check.
  retype = alter(IGK_M.IDField(), IGK_M.CharField(primary_key = true, max_length = 10))
  @test occursin("MODIFY COLUMN `circuitid` BIGINT NOT NULL AUTO_INCREMENT", retype)
  @test !occursin("FOREIGN_KEY_CHECKS", retype)
end

# What: the SQLite reader compiles the identity for a rowid alias only. Expected: identity for
# `INTEGER PRIMARY KEY` with or without AUTOINCREMENT, a lowercase `integer` and a table-level
# `PRIMARY KEY (circuitid)`; none for a `BIGINT`/`INT` key, `INTEGER PRIMARY KEY DESC` and a
# `WITHOUT ROWID` table — SQLite fills only the first group (measured in #1393). Why: before #1393 every
# integer key read as the identity, so the `BIGINT` key `IDField(generated = false)` renders would plan
# a rebuild on every run.
@testset "SQLite: only a rowid alias reads as the identity" begin
  igk_with_sqlite() do pool, key
    shapes = ["igk_alias_autoinc" => ("(\"circuitid\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL)", true),
              "igk_alias_plain" => ("(\"circuitid\" INTEGER PRIMARY KEY)", true),
              "igk_alias_lower" => ("(\"circuitid\" integer primary key)", true),
              "igk_alias_table_pk" => ("(\"circuitid\" INTEGER, PRIMARY KEY (\"circuitid\"))", true),
              "igk_bigint" => ("(\"circuitid\" BIGINT PRIMARY KEY UNIQUE NOT NULL)", false),
              "igk_int" => ("(\"circuitid\" INT PRIMARY KEY NOT NULL)", false),
              "igk_desc" => ("(\"circuitid\" INTEGER PRIMARY KEY DESC)", false),
              "igk_without_rowid" => ("(\"circuitid\" INTEGER PRIMARY KEY NOT NULL) WITHOUT ROWID", false)]
    for (t, (body, _)) in shapes
      fetch(pool, "CREATE TABLE \"$(t)\" $(body)")
    end
    for (t, (_, alias)) in shapes
      spec = _IGK_Mig._sqlite_live_table(pool, t).columns["circuitid"]
      @test (t, spec.identity !== nothing) == (t, alias)
    end
  end
end

# What: a table made by the old DDL (every `IDField` key was `INTEGER PRIMARY KEY AUTOINCREMENT`)
# under a model that now declares `generated = false` plans an `:identity` change, though
# `parse_canonical_type` reads `INTEGER` and `BIGINT` as one type; the new DDL then plans nothing.
# Why: that delta is what makes `makemigrations` rebuild the table into a key SQLite does not fill.
@testset "SQLite: the old DDL plans an identity change, the new DDL none" begin
  igk_with_sqlite() do pool, key
    supplied = igk_circuit(key; generated = false)
    fetch(pool, "CREATE TABLE \"old_circuit\" (\"circuitid\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL)")
    fetch(pool, "CREATE TABLE \"new_circuit\" ($(PormG.Dialect.field_to_column("circuitid", supplied.fields["circuitid"], pool)))")
    old_spec = _IGK_Mig._sqlite_live_table(pool, "old_circuit").columns["circuitid"]
    new_spec = _IGK_Mig._sqlite_live_table(pool, "new_circuit").columns["circuitid"]
    @test _IGK_Mig.column_delta(supplied.fields["circuitid"], old_spec, pool; name = "circuitid").changed == [:identity]
    @test isempty(_IGK_Mig.column_delta(supplied.fields["circuitid"], new_spec, pool; name = "circuitid").changed)
    @test old_spec.type == new_spec.type   # the type axis alone would not see it
    # Measured: the new key is not filled by SQLite.
    e = _igk_err(() -> fetch(pool, "INSERT INTO \"new_circuit\" DEFAULT VALUES"))
    @test e isa IntegrityError
  end
end

# What: inspectdb on SQLite writes `generated = false` for an integer key that is not a rowid alias, and
# that model plans nothing against its table. Expected: `IDField()` for `INTEGER PRIMARY KEY` (with or
# without AUTOINCREMENT), `IDField(generated = false)` for a `BIGINT` key. Why: a regenerated models
# file must say what the table does; before #1393 the `BIGINT` key came back as a generated key, which
# `allocate_primary_keys` and `bulk_insert` then treated as one.
@testset "SQLite: inspectdb round trip" begin
  igk_with_sqlite() do pool, key
    fetch(pool, "CREATE TABLE \"igk_auto\" (\"circuitid\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL)")
    fetch(pool, "CREATE TABLE \"igk_legacy\" (\"circuitid\" INTEGER PRIMARY KEY)")
    fetch(pool, "CREATE TABLE \"igk_source\" (\"circuitid\" BIGINT PRIMARY KEY UNIQUE NOT NULL)")
    tables = ["igk_auto", "igk_legacy", "igk_source"]
    models = _IGK_Mig.convert_schema_to_models(pool; include_table = tables)
    by = Dict(lowercase(string(m.name)) => m for m in models)
    for (t, generated) in ("igk_auto" => true, "igk_legacy" => true, "igk_source" => false)
      f = by[t].fields["circuitid"]
      @test (t, f.generated) == (t, generated)
      @test occursin(generated ? "circuitid = Models.IDField()" : "circuitid = Models.IDField(generated=false)",
                     IGK_M.Model_to_str(by[t]))
      spec = _IGK_Mig._sqlite_live_table(pool, t).columns["circuitid"]
      @test (t, _IGK_Mig.column_delta(f, spec, pool; name = "circuitid").changed) == (t, Symbol[])
    end
  end
end

# What: `allocate_primary_keys` on a caller-supplied key raises `QueryBuildError` naming the model, the
# key and the engine, whatever the frame holds, and reserves nothing; on a generated key it still
# allocates. Why: there is nothing to allocate from — the PostgreSQL call returned the ids missing.
@testset "allocate_primary_keys refuses a key the caller supplies" begin
  igk_with_sqlite() do pool, key
    supplied = igk_circuit(key; generated = false)
    auto = igk_circuit(key; generated = true)
    igk_create!(pool, supplied); igk_create!(pool, auto)
    for df in (DataFrame(name = ["Monza", "Spa"]),
               DataFrame(circuitid = [missing, missing], name = ["Monza", "Spa"]),
               DataFrame(circuitid = [14, 13], name = ["Monza", "Spa"]),
               DataFrame(name = String[]))
      e = _igk_err(() -> allocate_primary_keys(supplied.objects, df))
      @test e isa QueryBuildError
      msg = sprint(showerror, e)
      @test occursin("circuitid", msg) && occursin("igk_circuit_source", msg)
      @test occursin("IDField(generated = false)", msg) && occursin("SQLite", msg)
      @test !occursin("Monza", msg) && !occursin("14", msg)
    end
    filled = allocate_primary_keys(auto.objects, DataFrame(name = ["Monza", "Spa"]))
    @test filled.circuitid == [1, 2]
  end
end

# What: a key PormG did not create can hold a non-integer, and allocating after it raises
# `QueryBuildError`, never `InexactError`. Expected: a REAL key declared `IDField()` by hand, holding
# 2.5, refuses; inspectdb declares the same table `IDField(generated = false)`, which refuses before
# any read. Why: `Int64(2.5)` escaped the PormGError taxonomy (#1393 item 3).
@testset "allocate_primary_keys refuses a non-integer maximum" begin
  igk_with_sqlite() do pool, key
    fetch(pool, "CREATE TABLE \"igk_lap_real\" (\"lapid\" REAL PRIMARY KEY NOT NULL)")
    fetch(pool, "INSERT INTO \"igk_lap_real\" VALUES (2.5)")
    hand = IGK_M.Model("igk_lap_real", lapid = IGK_M.IDField())
    hand.connect_key = key
    e = _igk_err(() -> allocate_primary_keys(hand.objects, DataFrame(x = [1])))
    @test e isa QueryBuildError
    @test occursin("not a 64-bit integer", sprint(showerror, e)) && !occursin("2.5", sprint(showerror, e))

    imported = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
      only(_IGK_Mig.convert_schema_to_models(pool; include_table = ["igk_lap_real"]))
    end
    @test imported.fields["lapid"].generated === false
    imported.connect_key = key
    e = _igk_err(() -> allocate_primary_keys(imported.objects, DataFrame(x = [1])))
    @test e isa QueryBuildError && occursin("IDField(generated = false)", sprint(showerror, e))
  end
end

# What: `bulk_insert` on a caller-supplied key treats a blank key as caller data — a missing value the
# NOT NULL key refuses, with `InvalidValueError`, before any SQL — and never leaves the column out;
# explicit ids insert. On a generated key an all-blank column is still left out and the database
# allocates. Why: dropping the column sent an INSERT the database refused (or, on SQLite before #1393,
# filled from the rowid), which is not what the caller wrote.
@testset "bulk_insert: a blank caller-supplied key is caller data" begin
  igk_with_sqlite() do pool, key
    supplied = igk_circuit(key; generated = false)
    auto = igk_circuit(key; generated = true)
    igk_create!(pool, supplied); igk_create!(pool, auto)
    for blank in ([missing, missing], [nothing, nothing], [missing, 14])
      e = _igk_err(() -> bulk_insert(supplied.objects, DataFrame(circuitid = blank, name = ["Monza", "Spa"])))
      @test (repr(blank), typeof(e)) == (repr(blank), InvalidValueError)
    end
    @test supplied.objects.count() == 0
    @test bulk_insert(supplied.objects, DataFrame(circuitid = [14, 13], name = ["Monza", "Spa"])).count == 2
    @test sort([r[:circuitid] for r in supplied.objects.values("circuitid").list()]) == [13, 14]

    @test bulk_insert(auto.objects, DataFrame(circuitid = [missing, missing], name = ["Monza", "Spa"])).count == 2
    @test sort([r[:circuitid] for r in auto.objects.values("circuitid").list()]) == [1, 2]

    # `returning` with no key column: a generated key is pre-allocated and matched; a caller-supplied
    # one has no ids to match by, so the call is refused before any SQL (it pre-allocated before #1393).
    e = _igk_err(() -> bulk_insert(supplied.objects, DataFrame(name = ["Suzuka"]); returning = ["circuitid"]))
    @test e isa QueryBuildError
    @test supplied.objects.count() == 2
    back = bulk_insert(auto.objects, DataFrame(name = ["Suzuka"]); returning = ["circuitid"])
    @test only(back.rows)[:circuitid] == 3
  end
end

end
