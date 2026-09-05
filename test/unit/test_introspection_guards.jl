"""
Unit coverage for the introspection primary-key attribute guards
(`convertSQLToModel(row::DataFrameRow)`, the PostgreSQL path).

The original guard (this file's reason for existing): a natural primary key
(`VARCHAR(n) PRIMARY KEY`) or a numeric one (`NUMERIC(p,s) PRIMARY KEY`) parsed a
`max_length`/`max_digits` and then tried to assign it onto a field that has no such slot, raising
a `FieldError` that crashed the whole schema import. The fix added
`&& hasfield(typeof(field), :max_length)` / `:max_digits`; the import must succeed either way.

**What the primary key maps to changed in #409.** It used to be `IDField` for every non-UUID key,
which is what made the crash possible in the first place — and which meant a model declaring any
other key type could never equal what introspection reported, so `makemigrations` proposed the same
`ALTER` on that column forever. Now:

  * `varchar(n)` key ⇒ `CharField(primary_key=true, max_length=n)` — reconstructed
  * a key that is ALSO a foreign key ⇒ the relation, carrying `primary_key=true`
  * every integer width ⇒ `IDField`, which since #408 is the only integer key type PormG has, so
    this is correct by construction rather than by flattening
  * `numeric`, and a lengthless `text` key ⇒ still `IDField`, deliberately: `DecimalField` refuses
    `primary_key` outright, and no field type both accepts `primary_key` and carries no length.

So the max_length/max_digits guard is still load-bearing, but for the `numeric` fallback rather than
for every key.

`convertSQLToModel(row)` takes the introspected table metadata as a single `DataFrameRow`, so
this is fully hermetic — no live database.
"""

using Test
using DataFrames
using JSON
using Logging          # `@test_logs min_level = Logging.Warn` in the #455 block
using PormG
using PormG.Migrations: convertSQLToModel

# #472 needs the LIVE SQLite reader as well as the hermetic PostgreSQL one: `convert_schema_to_models`
# on SQLite goes through the PRAGMA path, which a `DataFrameRow` fixture cannot reach. The guard is
# `test_key_type_round_trip.jl`'s — `test/runtests.jl` already loads the drivers for the whole
# suite, so this only matters when the file is run on its own, which it now can be.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: PormGModel, PormGPostgres, PormGSQLite
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: convert_schema_to_models, _field_or_drop_default

# The cleaners return `_ExpressionDefault` for a DEFAULT that is a SQL expression rather than a
# literal value (#475). Aliased so assertions read as the expression they are about rather than as a
# constructor call. Named `sql_expr` rather than `expr` because `test/runtests.jl` includes every
# unit file into ONE module, and this file already carries `expr_columns`/`expr_defaults`/`expr_warns`
# locals that a bare `expr` would sit confusingly beside.
const sql_expr = PormG.Migrations._ExpressionDefault

# Mock connections for the planner assertion in the #472 block (the shape used by
# `test_fk_to_table_planner.jl`). Prefixed with this file's own name because `test/runtests.jl`
# includes every unit file into the same module, and a bare `MockPg` would collide.
struct IntrospectionGuardMockPg <: PormGPostgres end
struct IntrospectionGuardMockSQLite <: PormGSQLite end
# The SQLite rebuild path asks the backend for its version to decide which DDL it may use.
PormG.backend_sqlite_version(::IntrospectionGuardMockSQLite) = 3045000

# ── Fixture builders ────────────────────────────────────────────────────────────────────────────
#
# #455 moved the PostgreSQL schema query's wire format from `array_to_string(array_agg(...), ', ')`
# to `json_agg(json_build_object(...))`, so these build the JSON the reader now parses.
#
# The fixtures are written as OBJECTS rather than as JSON string literals on purpose. Every marker
# (`notnull`, `unique`, `non_negative_check`) used to be a space-delimited token inside the same
# string that carried the column's DEFAULT, and a test could only assert on that string as a whole;
# stating each one positively is what makes "a DEFAULT cannot forge a marker" testable at all.
#
# STATED LIMIT, so nobody mistakes this file for more coverage than it gives: these builders write
# the same key names `convertSQLToModel` reads, so a typo in the SQL's own `json_build_object` keys
# is INVISIBLE here — a `DataFrameRow` fixture executes no SQL. The live query is exercised only by
# `test/integration/test_importers_introspection.jl`, which is therefore the mutation gate for the
# key names, exactly as the #415 block near the end of this file already notes for FK pairing.

# One entry of the `columns` aggregate.
_col(name, type; notnull = false, default = nothing, identity = "",
     unique = false, non_negative_check = false, byte_limit = nothing) =
  Dict{String, Any}("name" => name, "type" => type, "notnull" => notnull, "default" => default,
                    "identity" => identity, "unique" => unique,
                    "non_negative_check" => non_negative_check, "byte_limit" => byte_limit)

# One entry of the `foreign_keys` aggregate. `on_delete` carries the raw
# `pg_constraint.confdeltype` code (#292); "a" is NO ACTION.
_fk(column, table, pk; on_delete = "a") =
  Dict{String, Any}("column" => column, "table" => table, "pk" => pk, "on_delete" => on_delete)

# One entry of the `indexes` aggregate: the indexed column and the index's own name.
_ix(column, name) = Dict{String, Any}("column" => column, "name" => name)

# One-row "introspection result" carrying the columns convertSQLToModel(row) reads. `foreign_keys`
# and `indexes` default to `missing`, matching a table that has none — which is what the schema
# query's LEFT JOINs actually produce.
function _introspection_row(; table_name, columns, primary_keys,
                              foreign_keys = missing, indexes = missing)
  df = DataFrame(
    table_name   = [table_name],
    columns      = [columns isa AbstractVector ? JSON.json(columns) : columns],
    primary_keys = [primary_keys isa AbstractVector ? JSON.json(primary_keys) : primary_keys],
    foreign_keys = [foreign_keys isa AbstractVector ? JSON.json(foreign_keys) : foreign_keys],
    indexes      = [indexes isa AbstractVector ? JSON.json(indexes) : indexes],
  )
  return df[1, :]
end

@testset "Introspection PK attribute guards (convertSQLToModel)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. VARCHAR primary key + a normal sized column. It must not crash (the original guard), and
  #    since #409 it must come back as the CharField it actually is rather than as an IDField.
  #    Flattened to IDField, a model declaring `code = CharField(primary_key=true, max_length=20)`
  #    could never equal the live table: `describes_same_column` refuses to equate two field types
  #    when either declares a key, so the planner pushed `:type` on every makemigrations — a full
  #    table rebuild each time on SQLite.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "VARCHAR(n) PRIMARY KEY reconstructs as a CharField key (#409)" begin
    row = _introspection_row(
      table_name   = "natural_key_tbl",
      columns      = [_col("code", "varchar(20)"; notnull = true),
                      _col("name", "varchar(100)")],
      primary_keys = ["code"],
    )
    model = convertSQLToModel(row)   # must not throw — the original guard

    @test model.fields["code"] isa PormG.Models.sCharField
    @test model.fields["code"].primary_key
    # The length is REQUIRED, not decorative: `CharField()` invents `max_length = 250`, which would
    # render `varchar(250)` and never match a live `varchar(20)` (the #325 trap).
    @test model.fields["code"].max_length == 20
    # `unique` is the COMPUTED column marker, not a hardcoded `true`. `CharField`'s constructor
    # defaults it to `false` and `:unique` has no exemption in `_NON_SCHEMA_FIELD_ATTRS`, so
    # hardcoding it here would keep declared and live unequal forever in a different way.
    @test model.fields["code"].unique == false
    @test model.fields["name"].max_length == 100                 # normal column unaffected
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 1b. A key that is ALSO a foreign key keeps its relation (#409).
  #    The `primary_key` arm used to precede the `fk_map` arm, so this column came back as a bare
  #    `IDField` and the foreign key was DISCARDED — `inspectdb` regenerated the model with no
  #    relation at all. That is loss, not drift, and no other test in this file covers the shape.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a PRIMARY KEY that is also a FOREIGN KEY stays a relation (#409)" begin
    model = convertSQLToModel(_introspection_row(
      table_name   = "driver_profile",
      columns      = [_col("driver_id", "bigint"; notnull = true)],
      primary_keys = ["driver_id"],
      foreign_keys = [_fk("driver_id", "driver", "id"; on_delete = "c")]))

    f = model.fields["driver_id"]
    # A pk-fk is unique by the key constraint, so PostgreSQL records no separate UNIQUE marker —
    # the reader treats the key itself as the one-to-one signal.
    @test f isa PormG.Models.sOneToOneField
    @test f.primary_key
    @test f.to_table == "driver"
    @test f.pk_field == "id"
    @test f.on_delete === PormG.Models.CASCADE
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. NUMERIC(p,s) primary key. Pre-fix: assigning max_digits onto the IDField threw.
  #    #409 did NOT widen the reconstruction to this one, and that is deliberate: `DecimalField`
  #    refuses `primary_key` outright ("DecimalField cannot be used as a Primary Key"), so there is
  #    nothing to reconstruct it AS. The IDField fallback stays, and so does the max_digits guard
  #    that keeps it from throwing.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "NUMERIC(p,s) PRIMARY KEY does not crash (max_digits guard)" begin
    row = _introspection_row(
      table_name   = "numeric_key_tbl",
      columns      = [_col("id", "numeric(10,0)"; notnull = true)],
      primary_keys = ["id"],
    )
    model = convertSQLToModel(row)   # must not throw

    @test model.fields["id"] isa PormG.Models.sIDField
    @test !hasfield(typeof(model.fields["id"]), :max_digits)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3. The integer keys, and the lengthless text key that still falls back.
  #    `IDField` for an integer key is no longer a flattening: #408 retired `AutoField`, so it is
  #    the only integer key type PormG has and a declared key equals an introspected one. The three
  #    widths are pinned together because reconstructing them separately is exactly the thing that
  #    would reintroduce #409 — there is no `SmallAutoField`/`BigAutoField` to reconstruct INTO.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "every integer key width still reads as IDField (#408/#409)" begin
    for t in ("bigint", "integer", "smallint")
      model = convertSQLToModel(_introspection_row(
        table_name = "int_key_tbl", columns = [_col("id", t; notnull = true)],
        primary_keys = ["id"]))
      @test model.fields["id"] isa PormG.Models.sIDField
      @test model.fields["id"].primary_key
    end

    # A LENGTHLESS text key has no field type to become: `TextField` does not accept `primary_key`
    # (its constructor passes a literal `false`), and a bare `CharField` would invent
    # `max_length = 250`. It keeps the IDField fallback, deliberately and documented.
    model = convertSQLToModel(_introspection_row(
      table_name = "text_key_tbl", columns = [_col("id", "text"; notnull = true)],
      primary_keys = ["id"]))
    @test model.fields["id"] isa PormG.Models.sIDField
  end

end

# ═════════════════════════════════════════════════════════════════════════════
# #292 — foreign keys must round-trip their referential action and their default
#
# Introspection lost a different half of the FK declaration on each backend, and the two halves
# were mirror images. PostgreSQL carried the `default` but never even QUERIED `on_delete`, so a
# table whose FK was `ON DELETE CASCADE` introspected to a model claiming no cascade and a
# migration generated from it silently dropped the action. SQLite carried `on_delete` but dropped
# the `default`, which since #287 is a HARD failure: `SET_DEFAULT` with no default throws
# `ModelDefinitionError` at `set_models`, and regenerating produced the identical broken file.
#
# These are the hermetic halves — the `confdeltype` mapping and the failure policy, both reachable
# through a synthetic `DataFrameRow` with no database. The end-to-end round trip (create table →
# introspect → regenerate → `set_models`) lives in `test/integration/test_importers_introspection.jl`
# because it needs a real engine on both backends.
# ═════════════════════════════════════════════════════════════════════════════

using PormG.Migrations: _pg_confdeltype_to_on_delete, _normalize_introspected_on_delete,
                        _fk_default_or_warn

@testset "Introspection carries on_delete and the FK default (#292)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: every `pg_constraint.confdeltype` code maps to the PormG spelling
  # PostgreSQL stores the action as a single char. Asserted as a full table rather than one
  # sample, because a partial mapping is what the bug was — the column was never selected at all.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "confdeltype codes map to PormG on_delete spellings" begin
    @test _pg_confdeltype_to_on_delete("c") == "CASCADE"
    @test _pg_confdeltype_to_on_delete("r") == "RESTRICT"
    @test _pg_confdeltype_to_on_delete("n") == "SET NULL"
    @test _pg_confdeltype_to_on_delete("d") == "SET DEFAULT"

    # 'a' is NO ACTION — which PostgreSQL stores BOTH for an explicit NO ACTION and for a foreign
    # key that declared no action at all. Mapping it to DO_NOTHING would stamp an explicit
    # `on_delete=DO_NOTHING` onto every plain FK in every generated model. `nothing` is lossless:
    # `_foreign_key_on_delete_sql(nothing)` and the DO_NOTHING branch both emit `ON DELETE NO
    # ACTION`, so the re-emitted DDL is byte-identical either way.
    @test _pg_confdeltype_to_on_delete("a") === nothing

    # Degradation, not an error: an unknown/blank code (a row from a pre-#292 schema query, a
    # future PostgreSQL code) behaves as "no action recorded" rather than throwing mid-import.
    @test _pg_confdeltype_to_on_delete("") === nothing
    @test _pg_confdeltype_to_on_delete("?") === nothing
    @test _pg_confdeltype_to_on_delete(missing) === nothing
    @test _pg_confdeltype_to_on_delete(nothing) === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: the SQLite spelling normalizes to the same values as PostgreSQL
  # SQLite reports the action as text ("SET NULL"), PostgreSQL as a code ('n'). Both must land on
  # the same PormG spelling or the two backends generate different models from the same schema —
  # the "keep PostgreSQL and SQLite aligned" rule.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite action text normalizes to the PostgreSQL result" begin
    @test _normalize_introspected_on_delete("CASCADE") == "CASCADE"
    @test _normalize_introspected_on_delete("SET NULL") == "SET_NULL"
    @test _normalize_introspected_on_delete("SET DEFAULT") == "SET_DEFAULT"
    @test _normalize_introspected_on_delete("RESTRICT") == "RESTRICT"

    # The alignment case. SQLite's DDL spells PormG's `on_delete === nothing` as the literal
    # "ON DELETE NO ACTION", so the regex path reads back "NO ACTION" for a foreign key that
    # declared nothing. Before #292 that became DO_NOTHING on SQLite while PostgreSQL produced
    # nothing at all — the same table, two different models.
    @test _normalize_introspected_on_delete("NO ACTION") === nothing
    @test _normalize_introspected_on_delete(nothing) === nothing
    @test _normalize_introspected_on_delete(missing) === nothing

    # Both backends agree for every action a round trip can preserve. PROTECT is absent on
    # purpose: it renders as SQL RESTRICT, so introspection can only ever return RESTRICT.
    for (sqlite_text, pg_code) in (("CASCADE", "c"), ("RESTRICT", "r"),
                                   ("SET NULL", "n"), ("SET DEFAULT", "d"), ("NO ACTION", "a"))
      @test _normalize_introspected_on_delete(sqlite_text) ==
            _normalize_introspected_on_delete(_pg_confdeltype_to_on_delete(pg_code))
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: an unrepresentable column default warns instead of throwing
  # `ForeignKey` runs `validate_default(…, Union{Int64,Nothing}, …, format2int64)`, which raises
  # `FieldValidationError` on anything non-numeric. Letting that escape would abort an entire
  # `convert_schema_to_models` run over one odd column with no way to skip it, so the policy is
  # warn-and-omit. This is the decision #291 deferred and #292 had to make.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "unrepresentable FK default warns and is omitted, never throws" begin
    # Representable: passes straight through, in both the integer and the string spelling the two
    # backends produce (SQLite PRAGMA yields a value, the PostgreSQL column regex yields text).
    @test _fk_default_or_warn(7, "results", "driverid") == 7
    @test _fk_default_or_warn("7", "results", "driverid") == 7
    @test _fk_default_or_warn(nothing, "results", "driverid") === nothing
    @test _fk_default_or_warn(missing, "results", "driverid") === nothing

    # Unrepresentable: a text default on a text FK column, and a PostgreSQL expression default.
    # Must WARN and return nothing. `@test_logs` fails if no warning is emitted, so this pins the
    # diagnostic too — a silent drop is what SQLite did before #292 and is what made the
    # SET_DEFAULT failure unexplainable.
    @test (@test_logs (:warn,) match_mode = :any _fk_default_or_warn("unknown", "drivers", "code")) === nothing
    @test (@test_logs (:warn,) match_mode = :any _fk_default_or_warn("nextval('s'::regclass)", "t", "c")) === nothing

    # The guarantee that matters: introspection does not throw on any of them.
    for bad in ("unknown", "nextval('s'::regclass)", "", "3.5")
      @test _fk_default_or_warn(bad, "t", "c") === nothing
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: a CASCADE foreign key survives the PostgreSQL row → model conversion
  # The end-to-end assertion for the PostgreSQL half, minus the database: before #292 `fk_map` was
  # a `(table, pk)` tuple with nowhere to put the action, so this came back `nothing`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "on_delete survives convertSQLToModel(::DataFrameRow)" begin
    row = _introspection_row(
      table_name   = "results",
      columns      = [_col("id", "bigint"; notnull = true), _col("driverid", "bigint"),
                      _col("raceid", "bigint")],
      primary_keys = ["id"],
      # CASCADE and SET NULL. Each rule travels ON the constraint it belongs to since #455, where
      # it used to be one entry of a parallel aggregate the reader zipped by position.
      foreign_keys = [_fk("driverid", "drivers", "driverid"; on_delete = "c"),
                      _fk("raceid", "races", "raceid"; on_delete = "n")],
    )
    model = convertSQLToModel(row)

    @test model.fields["driverid"] isa PormG.Models.sForeignKey
    @test model.fields["driverid"].on_delete === PormG.Models.CASCADE
    # The second FK proves the zip stays aligned rather than applying one action to every column.
    @test model.fields["raceid"].on_delete === PormG.Models.SET_NULL
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: a plain foreign key stays free of an invented on_delete
  # Guards the churn side of the 'a' → nothing decision. If this ever returns DO_NOTHING, every
  # regenerated model file gains an `on_delete=DO_NOTHING` on every FK that never declared one.
  #
  # Second line of defence, not the first: the two normalizers compose, so making
  # `_pg_confdeltype_to_on_delete("a")` return "NO_ACTION" is caught by the direct assertion in the
  # confdeltype testset above but NOT here — `_normalize_introspected_on_delete` collapses
  # "NO_ACTION" back to `nothing`. What this pins is the end-to-end result through both.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "NO ACTION introspects as no declaration, not DO_NOTHING" begin
    row = _introspection_row(
      table_name   = "results",
      columns      = [_col("id", "bigint"; notnull = true), _col("raceid", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("raceid", "races", "raceid")],
    )
    model = convertSQLToModel(row)
    @test model.fields["raceid"].on_delete === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: missing referential-action metadata degrades, it does not throw
  #
  # STATED HONESTLY, because #455 changed what this can still cover. The original premise was the
  # pre-#292 DataFrame SHAPE — a row with no `delete_rules` COLUMN — which a caller holding an older
  # row could still produce. That shape can no longer reach the reader at all: it carries
  # `", "`-joined strings, and `_pg_json` would raise on the first `JSON.parse`.
  #
  # What survives is the POLICY, which is a real contract and is what the two testsets below pin:
  # introspection never aborts a whole schema read over one field it cannot read (the same rule
  # `_fk_default_or_warn` follows for defaults). Neither shape is emitted by the current query —
  # `confdeltype` is NOT NULL — so these are belt-and-braces, and saying so is the point: a reader
  # who thinks they reproduce a live shape will draw the wrong conclusion from them.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "an FK with no on_delete recorded degrades instead of throwing" begin
    # No `on_delete` KEY at all. Built by hand rather than through `_fk`, which always writes it.
    row = _introspection_row(
      table_name   = "results",
      columns      = [_col("id", "bigint"; notnull = true), _col("raceid", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [Dict{String, Any}("column" => "raceid", "table" => "races", "pk" => "raceid")],
    )
    model = convertSQLToModel(row)     # must not throw
    @test model.fields["raceid"] isa PormG.Models.sForeignKey
    @test model.fields["raceid"].on_delete === nothing

    # …and JSON `null`, which parses to `nothing`. `String(nothing)` is a MethodError, so this is
    # the gate for the `something(...)` wrapper rather than a restatement of the case above.
    null_row = _introspection_row(
      table_name   = "results",
      columns      = [_col("id", "bigint"; notnull = true), _col("raceid", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [Dict{String, Any}("column" => "raceid", "table" => "races",
                                        "pk" => "raceid", "on_delete" => nothing)],
    )
    @test convertSQLToModel(null_row).fields["raceid"].on_delete === nothing
  end

  @testset "an absent aggregate column degrades to 'none' (#455)" begin
    # The other half of the same policy, and the one that IS still reachable: `convertSQLToModel`
    # is exported, so a row may come from somewhere other than the current `get_database_schema`.
    # A row with no `indexes` column at all must read as "no indexes", not raise.
    df = DataFrame(
      table_name   = ["results"],
      columns      = [JSON.json([_col("id", "bigint"; notnull = true), _col("slug", "text")])],
      primary_keys = [JSON.json(["id"])],
    )
    model = convertSQLToModel(df[1, :])       # must not throw on the absent :foreign_keys/:indexes
    @test model.fields["id"] isa PormG.Models.sIDField
    # `slug` is the discriminating one: a PK gets `db_index = true` from its own arm regardless, so
    # asserting on `id` would pass whatever the index map contained.
    @test model.fields["slug"].db_index == false
    @test !haskey(model.cache, "index")
  end

  @testset "an OPTIONAL per-column key may be absent; name and type may not (#455)" begin
    # Where the degrade policy stops, pinned in both directions so the boundary is a decision
    # rather than an accident.
    #
    # Found in review: every optional key used to be read with `col[...]`, so a missing one raised
    # `KeyError`. `non_negative_check` is the one that made that intolerable rather than merely
    # untidy — it is only consulted for an `integer` column, so the SAME malformed row imported a
    # `text` column fine and died on the next `integer` one. A type-dependent abort is the worst
    # shape to debug, so the five optional keys now carry defaults.
    bare = Dict{String, Any}("name" => "n", "type" => "integer")     # nothing but the two required
    model = convertSQLToModel(_introspection_row(
      table_name = "sparse", columns = [bare], primary_keys = ["n"]))
    @test model.fields["n"] isa PormG.Models.sIDField

    # …and specifically the integer arm, which is where the asymmetry lived.
    plain = convertSQLToModel(_introspection_row(
      table_name = "sparse2",
      columns    = [_col("id", "bigint"; notnull = true),
                    Dict{String, Any}("name" => "count", "type" => "integer")],
      primary_keys = ["id"]))
    @test plain.fields["count"] isa PormG.Models.sIntegerField   # not PositiveIntegerField
    @test plain.fields["count"].null == true                     # absent `notnull` ⇒ nullable
    @test plain.fields["count"].unique == false

    # The other direction: an entry with no `name` (or no `type`) describes no column at all, so
    # there is nothing to degrade TO and raising is the honest answer. A silent phantom here is the
    # exact failure #414/#455 exist to remove.
    @test_throws KeyError convertSQLToModel(_introspection_row(
      table_name = "broken", columns = [Dict{String, Any}("type" => "bigint")],
      primary_keys = String[]))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: a SET DEFAULT foreign key carries its default through registration
  # This is the #287/#291 regression in one assertion. `SET_DEFAULT` with no `default` raises
  # `ModelDefinitionError` at `set_models`; before #292 introspection produced exactly that shape
  # and regenerating produced the identical broken file, so there was no way out but a hand edit.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SET DEFAULT FK keeps its default so the model can register" begin
    row = _introspection_row(
      table_name   = "results",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("statusid", "bigint"; default = "1")],
      primary_keys = ["id"],
      foreign_keys = [_fk("statusid", "status", "statusid"; on_delete = "d")],
    )
    model = convertSQLToModel(row)

    @test model.fields["statusid"].on_delete === PormG.Models.SET_DEFAULT
    # The default is what makes the pair self-consistent — without it `set_models` rejects the
    # model, which is the whole failure #292 exists to end.
    @test model.fields["statusid"].default == 1
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: the SQLite DDL-regex path carries both halves too
  # `convertSQLToModel(sql::String)` parses a CREATE TABLE statement and is a SEPARATE
  # implementation from the `PRAGMA` path that `convert_schema_to_models` actually calls. It is
  # public API with no caller in `src/`, so nothing else exercises its FK branch — reverting that
  # branch's #292 fix left the whole unit suite AND the SQLite integration suite green. This is the
  # test that makes it defended rather than incidentally correct.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the SQLite DDL-regex path carries on_delete and the default" begin
    sql = """
    CREATE TABLE "results" (
      "id" INTEGER NOT NULL,
      "statusid" INTEGER DEFAULT 1,
      "raceid" INTEGER,
      PRIMARY KEY("id"),
      FOREIGN KEY("statusid") REFERENCES "status"("statusid") ON DELETE SET DEFAULT,
      FOREIGN KEY("raceid") REFERENCES "races"("raceid") ON DELETE NO ACTION
    )"""
    model = convertSQLToModel(sql)

    # The SET DEFAULT half: action AND default, the pair #287 requires to be consistent.
    @test model.fields["statusid"] isa PormG.Models.sForeignKey
    @test model.fields["statusid"].on_delete === PormG.Models.SET_DEFAULT
    @test model.fields["statusid"].default == 1

    # The alignment half: this path reads back the literal "NO ACTION" that PormG's own DDL emits
    # for an undeclared action, so without normalization it produced DO_NOTHING here while
    # PostgreSQL produced nothing for the identical schema.
    @test model.fields["raceid"].on_delete === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The SQLite DDL-regex path reads nullability the right way round (#310)
  # The column regex captures `(NOT NULL)?` into `nullable`, which holds the literal string
  # "NOT NULL" when the column IS NOT NULL, and `nothing` when it IS nullable. Every field branch
  # (IDField, ForeignKey, and the general/default branch) used to write `null=!(nullable ===
  # nothing)`, inverting it: a NOT NULL column round-tripped as `null=true` and a nullable column
  # as `null=false` — backwards against `src/Dialect.jl`, where `field.null == true` renders NULL.
  # A fixture that only used one polarity would pass against either the correct or the inverted
  # implementation, so this one mixes NOT NULL and nullable columns across all three branches.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the SQLite DDL-regex path reads nullability the right way round" begin
    sql = """
    CREATE TABLE "results" (
      "id" INTEGER NOT NULL,
      "points" REAL NOT NULL,
      "notes" TEXT,
      "statusid" INTEGER NOT NULL,
      "raceid" INTEGER,
      PRIMARY KEY("id"),
      FOREIGN KEY("statusid") REFERENCES "status"("statusid"),
      FOREIGN KEY("raceid") REFERENCES "races"("raceid")
    )"""
    model = convertSQLToModel(sql)

    # IDField branch: a NOT NULL primary key must not come back nullable.
    @test model.fields["id"].null == false

    # General/default branch: NOT NULL and nullable plain columns, both polarities.
    @test model.fields["points"].null == false
    @test model.fields["notes"].null == true

    # ForeignKey branch: NOT NULL and nullable FK columns, both polarities.
    @test model.fields["statusid"].null == false
    @test model.fields["raceid"].null == true
  end

end

# ─────────────────────────────────────────────────────────────────────────────
# #318: the PostgreSQL reader takes uniqueness from a ' UNIQUE' token the schema query appends to
# each column string. This pins that CONTRACT hermetically — a future edit to the CTE that renames or
# drops the token fails here, without a database.
#
# It does NOT test the CTE itself (no SQL runs here); that query is covered in
# test/integration/test_importers_introspection.jl. What it DOES test is the half that silently
# over-matched: the read used `occursin("UNIQUE", col)` against the WHOLE column string, so a column
# *named* `UNIQUE_CODE` (mixed-case names are supported, #57) or a `DEFAULT 'UNIQUE'` literal
# introspected as unique and then churned forever.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL UNIQUE marker is a token, not a substring (#318)" begin
  row = _introspection_row(
    table_name   = "uniq_guard",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("slug", "character varying(120)"; notnull = true, unique = true),
                    _col("token", "uuid"; notnull = true, unique = true),
                    _col("plain", "text")],
    primary_keys = ["id"])
  model = convertSQLToModel(row)

  # Baseline, NOT a mutation gate: these three pass on main too, because this file feeds
  # `convertSQLToModel` a pre-rendered `columns` string and never runs the CTE. They pin the marker
  # CONTRACT — if a future CTE edit renames or drops the ' UNIQUE' token, the reader stops seeing it
  # and these fail. The CTE bug itself (a per-table array that rejected both columns of a two-unique
  # table) is gated in test/integration/test_importers_introspection.jl, where the SQL actually runs.
  @test model.fields["slug"].unique
  @test model.fields["token"].unique
  @test !model.fields["plain"].unique

  # THE mutation gate for this testset: a column whose NAME contains the substring, and a DEFAULT
  # literal that does. Both returned `true` under the old `occursin("UNIQUE", col)` and `false` under
  # the token match — so these two assertions, unlike the three above, go red on main.
  tricky = convertSQLToModel(_introspection_row(
    table_name   = "uniq_guard_tricky",
    columns      = [_col("id", "bigint"; notnull = true), _col("UNIQUE_CODE", "text"),
                    _col("label", "text"; default = "'UNIQUE'")],
    primary_keys = ["id"]))
  @test !tricky.fields["UNIQUE_CODE"].unique
  @test !tricky.fields["label"].unique
end

# ─────────────────────────────────────────────────────────────────────────────
# #325: a long VARCHAR must keep its length instead of being retyped to TEXT
# The reader used to parse `character varying(500)`, then throw the result away — `CharField`
# refused any `max_length > 255`, so the column was rebuilt as a `TextField` with no length at all.
# The live column really was `varchar(500)`, so the declared model never matched its own table and
# `makemigrations` proposed the same widening on every run. Both assertions go red on main.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL varchar(n > 255) keeps its length (#325)" begin
  model = convertSQLToModel(_introspection_row(
    table_name   = "long_varchar_guard",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("canonical_url", "character varying(500)"; notnull = true),
                    _col("short", "character varying(120)"), _col("body", "text")],
    primary_keys = ["id"]))

  # THE mutation gate: on main this field is an `sTextField` and has no `max_length` at all.
  @test model.fields["canonical_url"] isa PormG.Models.sCharField
  @test model.fields["canonical_url"].max_length == 500

  # The ≤ 255 case is the baseline — it passed before too. Kept so a fix that swings the other way
  # (everything becomes a TextField) cannot go green here.
  @test model.fields["short"] isa PormG.Models.sCharField
  @test model.fields["short"].max_length == 120

  # …and a genuine `text` column is still a TextField: `varchar` ⇒ CharField, `text` ⇒ TextField is
  # now the whole rule, with no length-dependent crossover between them.
  @test model.fields["body"] isa PormG.Models.sTextField
end

# ─────────────────────────────────────────────────────────────────────────────
# #325: `db_index` is read back from the schema query's index columns
# The reader computed `haskey(index_map, col_name |> Symbol)` against a `Dict{String,String}` — a
# `Symbol` key never matches a `String` key, so `db_index` was a hard `false` for every plain
# PostgreSQL column. Every `db_index=true` field therefore compared unequal to its own live table
# forever, and `Dialect.alter_field` has no `db_index` branch, so the migration it triggered emitted
# no DDL for it. The name half matters just as much: `index_map`'s key must equal the `fields_dict`
# key. Those two came from different aggregates with different quoting until #455 — `columns` was
# `quote_ident`-ed and `index_columns` was raw — so the reader de-quoted one side and not the other,
# and this fixture used to spell the column `"mixedCase"`, a shape production never emits, which
# pinned the mixed-case path against the wrong input (#389). Both sides are now raw.
#
# The CTE's own filters (non-unique, non-partial, single-column) run against a live database in
# test/integration/test_migration_bootstrap.jl — nothing here executes SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL db_index is read back off the index map (#325)" begin
  model = convertSQLToModel(_introspection_row(
    table_name   = "db_index_guard",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("slug", "character varying(120)"), _col("plain", "text"),
                    _col("mixedCase", "text")],
    primary_keys = ["id"],
    # What the `indexes` CTE hands back: one object per indexed column, carrying that column's
    # physical name and its index's own name. Both raw since #455 — the aggregate used to emit the
    # column raw and the index name quote_ident-ed, an asymmetry the reader had to undo on one
    # side only.
    indexes      = [_ix("slug", "db_index_guard_slug_idx"),
                    _ix("mixedCase", "db_index_guard_mixedcase_idx")]))

  # THE mutation gate — all three are `false` on main.
  @test model.fields["slug"].db_index
  @test model.fields["mixedCase"].db_index      # the de-quoting half (#57) — of `col_name`,
                                                # since the index side arrives raw
  @test !model.fields["plain"].db_index         # …and it did not over-mark

  # The index NAME is carried too, de-quoted, because the planner needs it to DROP the index when a
  # model stops declaring `db_index`. `_drop_index` re-quotes, so a quoted value would double up.
  @test model.cache["index"]["slug"] == "db_index_guard_slug_idx"
  @test model.cache["index"]["mixedCase"] == "db_index_guard_mixedcase_idx"
end

# ─────────────────────────────────────────────────────────────────────────────
# Introspected foreign keys carry the target BINDING and the physical table (#360)
#
# Two separate things a `.to` has to get right, and before #360 it got neither reliably:
#
#  1. `.to` must be the Julia BINDING `Model_to_str` will emit for the parent, because
#     `_resolve_target_model` resolves it by binding lookup and nothing else. It was bare
#     `uppercasefirst`, which agrees with the real derivation only when the table name is already a
#     legal identifier — `driver profile` bound as `Driver_profile` but got `.to = "Driver profile"`,
#     a string no binding can ever spell, so the key was permanently unresolvable.
#  2. `to_table` records the parent's PHYSICAL name, which the binding cannot round-trip back to
#     (`_model_binding_name` is lossy — `driver` and `Driver` both give `Driver`). It is what lets
#     `_plan_inspectdb_bindings!` rewrite `.to` to the target's final, collision-deduped binding.
#
# These two readers are covered here rather than through an importer because neither is reachable
# from `import_models_from_sqlite`: the DDL-regex reader is off the production path entirely, and
# the PostgreSQL reader needs a live server — but it takes a `DataFrameRow` and nothing else, so a
# synthetic row exercises it at full fidelity.
# ─────────────────────────────────────────────────────────────────────────────
@testset "introspected FKs carry the target binding and physical table (#360)" begin

  # The parent name here is `2fast`, not the `driver profile` used elsewhere in this file: this
  # reader finds foreign keys with a `REFERENCES "(\w+)"` regex, and `\w` never matches a space, so
  # a spaced parent is not seen as a relation at all on this path. A leading DIGIT is inside `\w+`
  # yet still illegal as an identifier, so it exercises the sanitizer branch just as well.
  @testset "the SQLite DDL-regex path (convertSQLToModel(::String))" begin
    sql = """
    CREATE TABLE "pit_stop" (
      "id" INTEGER NOT NULL,
      "plain_id" INTEGER,
      "fast_id" INTEGER,
      PRIMARY KEY("id"),
      FOREIGN KEY("plain_id") REFERENCES "driver_profile"("id"),
      FOREIGN KEY("fast_id") REFERENCES "2fast"("id")
    )"""
    model = convertSQLToModel(sql)

    # An already-legal table name: binding and physical table differ only by the leading capital,
    # so this pair passed before #360 too. It is here to prove the swap did not move the common case.
    @test model.fields["plain_id"].to       == "Driver_profile"
    @test model.fields["plain_id"].to_table == "driver_profile"

    # THE mutation gate for the `_model_binding_name` swap: bare `uppercasefirst("2fast")` is
    # "2fast", which is not a legal Julia identifier — so the generated `.to` named a binding that
    # could not exist and `_resolve_target_model` returned `nothing` forever.
    @test model.fields["fast_id"].to       == "Col_2fast"
    @test model.fields["fast_id"].to_table == "2fast"
  end
  # `foreign_keys` is spelled the way the PRODUCTION schema query emits it. Until #455 the CTE
  # aggregated `quote_ident(cf.relname)`, so a name needing quotes arrived WRAPPED IN `"` while
  # `table_name` came from a bare `c.relname`, and feeding the unquoted form here would have been a
  # dead test — it passes against a reader that never de-quotes, while the live path stored
  # `"\"driver profile\""` as `to_table`, matched no imported model, and skipped the binding
  # rewrite entirely. Both sides are now the raw physical name, so the two agree by construction.
  @testset "the PostgreSQL path (convertSQLToModel(::DataFrameRow))" begin
    model = convertSQLToModel(_introspection_row(
      table_name   = "pit_stop",
      columns      = [_col("id", "bigint"; notnull = true), _col("plain_id", "bigint"),
                      _col("spaced_id", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("plain_id", "driver_profile", "id"),
                      _fk("spaced_id", "driver profile", "id")]))

    # `quote_ident` leaves an already-legal lowercase name alone, so this half is unquoted input.
    @test model.fields["plain_id"].to       == "Driver_profile"
    @test model.fields["plain_id"].to_table == "driver_profile"

    # THE mutation gate for the de-quoting: without it `to_table` keeps its `"` and no longer equals
    # any `model.name`, so `_plan_inspectdb_bindings!` cannot find the target.
    @test model.fields["spaced_id"].to       == "Driver_profile"
    @test model.fields["spaced_id"].to_table == "driver profile"
  end

  # Both readers emit a `OneToOneField` when the FK column is also UNIQUE — PostgreSQL always did,
  # SQLite since #417 — so the slot has to exist on `sOneToOneField` too: a fix applied to
  # `sForeignKey` alone would leave every one-to-one relation unrewritable, and `to_table` would be
  # a MethodError. This testset covers the PostgreSQL reader; its SQLite twin, and the cross-reader
  # agreement itself, are in `test_key_type_round_trip.jl`.
  @testset "a UNIQUE foreign key becomes a OneToOneField and still carries both" begin
    model = convertSQLToModel(_introspection_row(
      table_name   = "driver_seat",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("profile_id", "bigint"; unique = true)],
      primary_keys = ["id"],
      # The parent's PHYSICAL name, raw. The schema query no longer quote_ident's it (#455), so
      # there is no de-quoting step left for a spaced name to be lost in.
      foreign_keys = [_fk("profile_id", "driver profile", "id")]))

    @test model.fields["profile_id"] isa PormG.Models.sOneToOneField
    @test model.fields["profile_id"].to       == "Driver_profile"
    @test model.fields["profile_id"].to_table == "driver profile"
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #389: every half of the FK metadata must spell an identifier the same way
#
# The PostgreSQL schema query used to aggregate `fk_cols`, `fk_tables` and
# `referenced_primary_keys` through `quote_ident`, so a mixed-case identifier arrived with the `"`
# characters as part of the Julia string and every consumer had to undo that. #360 (PR #386)
# de-quoted the TABLE half; #389 was the rest of it. Since #455 the query transports each of them as
# a JSON string and none is quoted at all — so what these testsets pin is no longer "the inverse is
# applied" but the outcome it existed to produce: **one identifier, one spelling, on every side.**
#
# The one that bites is `referenced_primary_keys` → `pk_field`. Stored quoted, `fk_target_column`
# returns it unchanged — an introspected field's `.to` is still a String binding, so the
# resolve-through-the-parent branch never runs. Three things break on that one value:
# `Dialect.add_foreign_key` emits `REFERENCES "parent"(""Id"")` (TWO quote pairs — the caller adds
# one around a value that already carries one; the issue body's `"""Id"""` is wrong),
# `_compare_field_foreign_key` reports the key as changed on every `makemigrations`, and the query
# builder addresses a column that does not exist. (It threw `InvalidValueError` when #389 was
# written, because `SAFE_IDENTIFIER_PATTERN` forbade a `"`; since #394 a physical column is escaped
# rather than validated, so the same bad value would now render as a column literally named `"Id"`.
# Either way it is wrong.)
#
# `fk_map`'s keys and `col_name` still have to agree — the keys come from one aggregate and the
# lookup from another — so a change that normalized one side alone would break FK detection for
# every mixed-case column. The second testset below is that mutation gate.
#
# Fully hermetic: `convertSQLToModel(::DataFrameRow)` takes the metadata and nothing else.
# The live-database half is test/integration/test_importers_introspection.jl.
# ─────────────────────────────────────────────────────────────────────────────
# `add_foreign_key` dispatches on the abstract backend marker and never touches connection state,
# so a bare marker struct is a sufficient `conn`. Declared at top level, like every other mock in
# test/unit/ (a struct inside a `@testset` body parses, but is not the house pattern).
struct MockPg389 <: PormG.PormGPostgres end

@testset "FK metadata spells every identifier once (#389)" begin
  @testset "a mixed-case parent primary key lands unquoted on pk_field" begin
    # The parent is keyed on `Id` and lives in a table named `MixedParent` — two mixed-case names
    # that `quote_ident` used to wrap and the reader had to unwrap.
    model = convertSQLToModel(_introspection_row(
      table_name   = "pit_stop",
      columns      = [_col("id", "bigint"; notnull = true), _col("parent_id", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("parent_id", "MixedParent", "Id")]))

    fk = model.fields["parent_id"]
    @test fk isa PormG.Models.sForeignKey

    # THE defect. Before the fix this was the four-character string `"Id"` — quote characters
    # included — not the two-character `Id`.
    @test fk.pk_field == "Id"

    # …and the resolved form, which is what the planner and the DDL actually consume. For an
    # INTROSPECTED field this equals `pk_field` by construction — `.to` is still a String binding,
    # so `fk_target_column`'s resolve-through-the-parent branch cannot run and it returns the value
    # verbatim. So this asserts propagation, not an independent fact; the genuinely separate
    # consequence is pinned by the `_compare_field_foreign_key` testset below.
    @test PormG.Models.fk_target_column(fk) == "Id"

    # The #360 half still holds — this fix must not disturb it.
    @test fk.to_table == "MixedParent"
  end

  @testset "the emitted ALTER references the parent column with ONE pair of quotes" begin
    # The consequence the issue leads with. `add_foreign_key` interpolates its identifiers verbatim
    # — every one is pre-quoted by the CALLER — so this reproduces `planner.jl`'s call shape exactly
    # (`"\"$resolved_pk\""`). With a quoted `pk_field` the result was `REFERENCES ... (""Id"")`,
    # which is a syntax error, not merely ugly. (The issue body says `"""Id"""`; the measured output
    # is two pairs, because the caller adds ONE pair around a value that already carries one.)
    model = convertSQLToModel(_introspection_row(
      table_name   = "pit_stop",
      columns      = [_col("id", "bigint"; notnull = true), _col("parent_id", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("parent_id", "MixedParent", "Id")]))

    resolved_pk = PormG.Models.fk_target_column(model.fields["parent_id"])
    sql = PormG.Dialect.add_foreign_key(MockPg389(), "pit_stop", "\"pit_stop_parent_id_fk\"",
                                        "\"parent_id\"", "\"MixedParent\"", "\"$resolved_pk\"")

    @test occursin("(\"Id\")", sql)
    @test !occursin("\"\"", sql)   # no doubled quote anywhere in the statement
  end

  @testset "a declared key compares EQUAL to the introspected one (no perpetual ALTER)" begin
    # The consequence the issue leads with and the one a user actually notices, reached through a
    # DIFFERENT path than the two above: `planner.jl` asks `_compare_field_foreign_key(declared,
    # live)`, which compares `fk_target_column` on both sides. Declared `Id` vs live `"Id"` is
    # `false`, so the planner pushes an alteration for that column on EVERY `makemigrations` —
    # forever, and on SQLite as a full table rebuild. Nothing above constrains this: those pin the
    # stored value, not the comparison that consumes it.
    live = convertSQLToModel(_introspection_row(
      table_name   = "pit_stop",
      columns      = [_col("id", "bigint"; notnull = true), _col("parent_id", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("parent_id", "MixedParent", "Id")])).fields["parent_id"]

    # What a hand-written or regenerated model file declares for that same column.
    declared = PormG.Models.ForeignKey("MixedParent", pk_field = "Id")
    declared.to_table = "MixedParent"

    @test PormG.Models._compare_field_foreign_key(declared, live)
    # Symmetric — the planner calls it (new, old) and nothing should depend on the order.
    @test PormG.Models._compare_field_foreign_key(live, declared)
  end

  @testset "a mixed-case FK COLUMN is still detected as a foreign key" begin
    # The mutation gate for moving `fk_cols` and `col_name` together. `fk_map`'s key comes from
    # `fk_cols` and is probed with `col_name`; de-quoting either one alone makes this lookup miss,
    # and the column silently degrades from a ForeignKey to a plain BigIntegerField — FK detection
    # broken for every mixed-case column, which is strictly worse than the bug being fixed.
    model = convertSQLToModel(_introspection_row(
      table_name   = "pit_stop",
      columns      = [_col("id", "bigint"; notnull = true), _col("ParentId", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("ParentId", "MixedParent", "Id")]))

    # `fields_dict` is keyed de-quoted, so this is the name the rest of PormG sees.
    @test haskey(model.fields, "ParentId")
    @test model.fields["ParentId"] isa PormG.Models.sForeignKey
    @test model.fields["ParentId"].pk_field == "Id"
    @test model.fields["ParentId"].to_table == "MixedParent"
  end

  @testset "a mixed-case PRIMARY KEY column is still detected as the key" begin
    # `pk_set` and the column name come from two different aggregates and are compared to each
    # other, so they have to agree about spelling. They used to agree only because BOTH were
    # `quote_ident`-ed; normalizing one side alone would leave the table KEYLESS, which no other
    # assertion in this file would catch. Both are now raw, which is the same agreement by
    # construction rather than by two matching transforms (#455).
    model = convertSQLToModel(_introspection_row(
      table_name   = "mixed_key",
      columns      = [_col("Id", "bigint"; notnull = true), _col("label", "character varying(50)")],
      primary_keys = ["Id"]))

    @test haskey(model.fields, "Id")
    @test model.fields["Id"] isa PormG.Models.sIDField
    @test model.fields["Id"].primary_key
  end

  @testset "an embedded quote round-trips instead of being silently deleted" begin
    # `Say"Hi` is a legal PostgreSQL column name. The original defect was a
    # `replace(s, "\"" => "")` that deleted every quote and produced `SayHi`, a column that does not
    # exist: `makemigrations` then proposed `ADD COLUMN "SayHi"` alongside a `DROP` of the real one,
    # on every run, silently. #389 fixed it by undoing `quote_ident`'s doubling exactly; #455 made
    # the doubling never happen, since a JSON string carries the name as-is.
    #
    # As of #394 the name is usable end to end as well: `Dialect.create_table` escapes a column
    # identifier the same way it has escaped `db_table` since #388, and the query path escapes
    # rather than validates it (`safe_column_identifier`). Both halves are asserted in
    # `test/unit/test_identifier_quoting.jl`; what this testset pins is the narrower and still
    # separate claim that introspection round-trips the spelling INTACT.
    model = convertSQLToModel(_introspection_row(
      table_name   = "odd_names",
      columns      = [_col("id", "bigint"; notnull = true), _col("Say\"Hi", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("Say\"Hi", "Par\"ent", "Sa\"y")]))

    @test haskey(model.fields, "Say\"Hi")
    @test model.fields["Say\"Hi"].pk_field == "Sa\"y"
    @test model.fields["Say\"Hi"].to_table == "Par\"ent"
  end

  @testset "a name that is itself quoted keys fields_dict and index_map identically" begin
    # ITS ORIGINAL PREMISE IS RETIRED, and the replacement is deliberate rather than a rename.
    #
    # This testset used to be "the RAW index aggregate is not run through the quote_ident inverse":
    # `index_columns` was the ONE identifier aggregate the schema query did not wrap in
    # `quote_ident`, so the reader had to de-quote the `columns` side and take the index side
    # verbatim. Get that asymmetry wrong in either direction and a column whose real name IS quoted
    # lands under two different keys, reintroducing the #325 db_index churn for that name class.
    #
    # #455 removed the asymmetry itself: every aggregate carries the raw physical name, so there is
    # no inverse to apply and no side to exempt. What survives is the OUTCOME that asymmetry existed
    # to protect — the field key and the index key must be the same string — and that is what this
    # now pins. It is still a live mutation gate: reintroducing any de-quoting step on either side
    # collapses `"x"` to `x` on that side alone and fails here.
    #
    # Real name `"x"`, three characters including the quotes. A legal PostgreSQL column name.
    model = convertSQLToModel(_introspection_row(
      table_name   = "d1_probe",
      columns      = [_col("id", "bigint"; notnull = true), _col("\"x\"", "bigint")],
      primary_keys = ["id"],
      indexes      = [_ix("\"x\"", "d1_probe_x_idx")]))

    @test haskey(model.fields, "\"x\"")
    @test model.fields["\"x\""].db_index
    @test model.cache["index"]["\"x\""] == "d1_probe_x_idx"
  end

  @testset "the all-lowercase case is unchanged (control)" begin
    # A legal lowercase identifier needs no quoting on either wire format, so this is the shape
    # every existing fixture exercises. It is a NO-REGRESSION CONTROL for the common path, not a
    # mutation gate: nothing about such a name can be mis-normalized.
    model = convertSQLToModel(_introspection_row(
      table_name   = "results",
      columns      = [_col("id", "bigint"; notnull = true), _col("driverid", "bigint")],
      primary_keys = ["id"],
      foreign_keys = [_fk("driverid", "drivers", "driverid"; on_delete = "c")]))

    @test model.fields["driverid"] isa PormG.Models.sForeignKey
    @test model.fields["driverid"].pk_field == "driverid"
    @test model.fields["driverid"].to_table == "drivers"
    @test model.fields["driverid"].on_delete === PormG.Models.CASCADE
  end
end

# ───────────────────────────────────────────────────────────────────────────
# #414 — an identifier CONTAINING A SPACE survives the columns parse.
#
# The reader used to `split(col, " ")` and take `[1]` as the name and `[2]` as the type, so
# `"Parent Id" bigint` was torn in half before anything else could look at it. Three things went
# wrong at once and this block gates all three: the phantom name `"Parent` (the leading quote
# SURVIVED — the de-quoter correctly refused to strip a lone unbalanced one), the type `Id"` which
# no lookup matches so the column degraded to `TextField`, and the LOST RELATION, because `fk_map`'s
# key came from an aggregate split on `", "` and therefore survived the space intact. The two sides
# genuinely disagreed for exactly this class of name.
#
# Since #394 this was the only layer where a spaced `db_column` still broke — the DDL and the query
# builder both handle it — which is what made every `makemigrations` propose `ADD COLUMN "\"Parent"`
# plus a DROP of the real column, forever.
#
# #455 REPLACED THE MECHANISM this testset was written against. #414 recovered the name by scanning
# `quote_ident`'s self-delimiting quoting; the schema query now transports the name as its own JSON
# string, so there is no field separator to be torn by and `_split_leading_quoted_ident` is gone.
# The CLAIM is unchanged and still worth pinning — a spaced name must survive whole — so the
# assertions below are untouched; only the fixture moved to the new wire format.
# ───────────────────────────────────────────────────────────────────────────
@testset "a column name containing a space is not torn in half (#414)" begin
  model = convertSQLToModel(_introspection_row(
    table_name   = "probe",
    columns      = [_col("id", "bigint"; notnull = true), _col("Parent Id", "bigint")],
    primary_keys = ["id"],
    foreign_keys = [_fk("Parent Id", "MixedParent", "Id")]))

  # The name, whole. `"Parent` — the measured pre-fix value — must not appear under any key.
  @test haskey(model.fields, "Parent Id")
  @test !any(k -> occursin('"', k), keys(model.fields))
  @test Set(keys(model.fields)) == Set(["id", "Parent Id"])

  # The RELATION, not a TextField. This is the discriminating assertion: the type degraded
  # because `col_parts[2]` was `Id"` rather than `bigint`, and the FK lookup missed because it
  # was keyed on the phantom name.
  @test model.fields["Parent Id"] isa PormG.Models.sForeignKey
  @test !(model.fields["Parent Id"] isa PormG.Models.sTextField)
  @test model.fields["Parent Id"].pk_field == "Id"
  @test model.fields["Parent Id"].to_table == "MixedParent"
end

@testset "a spaced name reaches pk_set and index_map too (#414)" begin
  # The other two consumers keyed on `col_name`. Both already survived a space on their own side
  # (`primary_keys` split on `", "`; `index_columns` was the one RAW aggregate), so they were
  # correct all along and only `col_name` disagreed with them — which is why repairing the one parse
  # site made all four agree. A spaced PRIMARY KEY left the table KEYLESS before. Under #455 all
  # four read the same JSON strings, so there is no longer a normalization step to get half right.
  model = convertSQLToModel(_introspection_row(
    table_name   = "probe2",
    columns      = [_col("Key Col", "bigint"; notnull = true), _col("Idx Col", "bigint")],
    primary_keys = ["Key Col"],
    indexes      = [_ix("Idx Col", "probe2_idx")]))

  @test model.fields["Key Col"] isa PormG.Models.sIDField
  @test model.fields["Key Col"].primary_key
  @test model.fields["Idx Col"].db_index
  @test model.cache["index"]["Idx Col"] == "probe2_idx"
end

@testset "a column NAMED like a marker does not mark itself (#414)" begin
  # The sibling class the same parse defect created — and, since #455, a class that is
  # UNREPRESENTABLE rather than guarded. Both halves of the mechanism are gone: the name no longer
  # shares a string with the markers (each is its own JSON field), and the type no longer shares one
  # with the name.
  #
  # Which shapes actually broke, measured rather than assumed — a bare reserved word did NOT.
  # `quote_ident` wrapped it, so `"UNIQUE" bigint` split to `["\"UNIQUE\"", "bigint"]` and #318's
  # token test did not match the quoted form. That case was safe by accident of quoting, and is kept
  # below as a control. The three that broke are the ones where a SPACE inside the name put a bare
  # marker token, or a rewritten type, into the split:
  #
  #   * `"has UNIQUE inside"` → `[…, "UNIQUE", …]`, so #318's token test fired on the NAME and the
  #     column was read as carrying a uniqueness constraint it never had. #318 closed the
  #     `DEFAULT 'UNIQUE'` half; the name half stayed open because the split it depended on was the
  #     defect underneath.
  #   * `"NOT NULL"` → `occursin("NOT NULL", col)` fired on the name alone, so a nullable column
  #     read as NOT NULL.
  #   * `"double precision"` → the reader rewrote that two-word TYPE to `double_precision` before
  #     splitting, and the rewrite hit a column so NAMED.
  model = convertSQLToModel(_introspection_row(
    table_name   = "marker_probe",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("has UNIQUE inside", "bigint"), _col("NOT NULL", "bigint"),
                    _col("double precision", "bigint"), _col("UNIQUE", "bigint")],
    primary_keys = ["id"]))

  @test Set(keys(model.fields)) ==
        Set(["id", "has UNIQUE inside", "NOT NULL", "double precision", "UNIQUE"])
  @test !model.fields["has UNIQUE inside"].unique   # says it, does not have it
  @test model.fields["NOT NULL"].null               # says it, is still nullable
  # The name was NOT rewritten to `double_precision`, and the column keeps its declared bigint
  # type rather than being read as the float that rewrite would have implied.
  @test model.fields["double precision"] isa PormG.Models.sBigIntegerField
  @test !model.fields["UNIQUE"].unique               # control: was already correct pre-#414

  # Control: the real markers still work, on a column whose name says nothing.
  plain = convertSQLToModel(_introspection_row(
    table_name   = "marker_control",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("slug", "character varying(30)"; notnull = true, unique = true),
                    _col("dp", "double precision")],
    primary_keys = ["id"]))
  @test plain.fields["slug"].unique
  @test !plain.fields["slug"].null
  @test plain.fields["slug"].max_length == 30
  @test plain.fields["dp"] isa PormG.Models.sFloatField
end

# ───────────────────────────────────────────────────────────────────────────
# #415 — the CONSUMER half. Read the scope of this block literally.
#
# The defect was in the `foreign_keys` CTE (it derived the referenced column from the parent's
# PRIMARY KEY INDEX instead of from `con.confkey`, and fanned every aggregate out once per parent
# PK column). A `DataFrameRow` fixture cannot execute SQL, so NOTHING HERE PROVES THE FIX — that
# is `test/integration/test_importers_introspection.jl`'s job, against a live server.
#
# What this pins is the contract the fixed CTE now relies on: given ONE entry per foreign key,
# every aggregate pairs by position. The values are made mutually distinguishable on purpose —
# two FKs with different parents, different referenced columns and different delete rules — so a
# future off-by-one or a reintroduced fan-out fails here rather than passing on symmetry.
# ───────────────────────────────────────────────────────────────────────────
@testset "one entry per FK: every aggregate pairs by position (#415)" begin
  model = convertSQLToModel(_introspection_row(
    table_name   = "child",
    columns      = [_col("id", "bigint"; notnull = true), _col("a_id", "bigint"), _col("b_id", "bigint")],
    primary_keys = ["id"],
    # `some_unique_col` is NOT the parent's primary key: `parent_a` is referenced on a non-PK
    # UNIQUE column. This is the value the old CTE could not produce at all, because it never
    # selected `confkey`. Each referenced column now travels ON its own constraint (#455), so the
    # pairing this testset checks is structural rather than positional.
    foreign_keys = [_fk("a_id", "parent_a", "some_unique_col"; on_delete = "c"),
                    _fk("b_id", "parent_b", "id"; on_delete = "n")]))

  @test model.fields["a_id"].pk_field == "some_unique_col"
  @test model.fields["a_id"].to_table == "parent_a"
  @test model.fields["a_id"].on_delete === PormG.Models.CASCADE

  @test model.fields["b_id"].pk_field == "id"
  @test model.fields["b_id"].to_table == "parent_b"
  @test model.fields["b_id"].on_delete === PormG.Models.SET_NULL
end

@testset "the fanned-out row shape is what the CTE must no longer emit (#415)" begin
  # The measurement from the issue, kept as documentation of the defect rather than as a
  # requirement on the reader. A composite-keyed parent used to multiply every aggregate, so this
  # row — `foreign_keys` naming ONE child column twice, `referenced_primary_keys` naming the
  # parent's two key columns — is what reached the consumer, and the LAST entry won the
  # `fk_map[...]` assignment: `pk_field` came back as `"b"` for a relation that references `a`.
  #
  # The reader still behaves that way given that input, and deliberately so: last-write-wins on a
  # duplicate key is not a defect the consumer can detect, and inventing a guard here would
  # duplicate — badly — a fix that belongs in the SQL. The assertion is that the shape is
  # DEGENERATE, which is the argument for why the CTE must not produce it.
  model = convertSQLToModel(_introspection_row(
    table_name   = "probe",
    columns      = [_col("id", "bigint"; notnull = true), _col("parent_id", "bigint")],
    primary_keys = ["id"],
    foreign_keys = [_fk("parent_id", "comp_parent", "a"), _fk("parent_id", "comp_parent", "b")]))

  # MEMBERSHIP, not the exact value. `== "b"` is what this actually returns today (last write wins),
  # but pinning it would freeze an answer the codebase calls wrong: anyone later adding a
  # consumer-side guard — warn or skip on a duplicated `fk_map` key, a reasonable defence in depth —
  # would have to DELETE this test to go green. What is worth pinning is that the reader picks one
  # of the parent's key columns arbitrarily and reports no problem, which is the argument for fixing
  # it upstream in the CTE.
  @test model.fields["parent_id"].pk_field in ("a", "b")
end

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# #455 — the ENTRY separator, and the DEFAULT parser it hid
#
# #414 fixed the FIELD separator inside one entry of the `columns` aggregate. The ENTRY separator
# was `", "`, chosen by `array_to_string`, and it is a legal substring of the data it delimited:
# `quote_ident('Race, Total')` is `"Race, Total"`, and `pg_get_expr` renders
# `DEFAULT concat('a', 'b')` with one too. One entry tore into two, the real column vanished, and
# `makemigrations` proposed adding the phantoms and dropping the real column on every run — the
# #414 failure reached by a different trigger, and one that needs no unusual identifier at all.
#
# Nothing could be fixed at the parse: the entry was already in two pieces before any parser saw
# it. The aggregates are now `json_agg(json_build_object(...))`, so the tear is UNREPRESENTABLE.
# That is what the four measured rows below assert — not that a guard catches them, but that the
# shape they describe is now ordinary.
#
# THE SECOND DEFECT, and the reason acceptance needs more than the aggregate change: the DEFAULT
# extractor was WHITESPACE-TERMINATED (`[^:\s]+`), so `DEFAULT 'Ferrari, Scuderia'::text` cleaned
# to `'Ferrari` even from an entry that arrived INTACT. Moving where the string comes from does not
# fix a parser that stops at the first space. `_pg_clean_default` is the fix, and it is pinned
# directly below as well as through the reader.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
@testset "a comma-space in a name or a DEFAULT cannot tear an entry (#455)" begin
  # Row 1 of the issue's measurement: `id bigint NOT NULL, "Race, Total" bigint` used to yield the
  # field keys `"Race`, `Total"` and `id` — the real column GONE, two phantoms in its place.
  model = convertSQLToModel(_introspection_row(
    table_name   = "comma_name",
    columns      = [_col("id", "bigint"; notnull = true), _col("Race, Total", "bigint")],
    primary_keys = ["id"]))

  @test Set(keys(model.fields)) == Set(["id", "Race, Total"])
  @test model.fields["Race, Total"] isa PormG.Models.sBigIntegerField  # not the TextField degrade
  @test !any(k -> occursin('"', k), keys(model.fields))                # no `"Race` / `Total"`

  # Row 2: a DEFAULT containing `, ` on an ORDINARY lowercase column. This is the case that makes
  # the issue more than a curiosity — no odd identifier is involved anywhere.
  model2 = convertSQLToModel(_introspection_row(
    table_name   = "comma_default",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("note", "text"; default = "'Ferrari, Scuderia'::text")],
    primary_keys = ["id"]))

  @test Set(keys(model2.fields)) == Set(["id", "note"])
  # THE mutation gate for `_pg_clean_default`. The pre-fix reader produced `Scuderia'::text` as a
  # phantom FIELD KEY; a reader that fixed only the aggregate produces the truncated `Ferrari`.
  # Both fail here, and they fail differently, which is the point of asserting the value.
  @test model2.fields["note"].default == "Ferrari, Scuderia"

  # Row 3: a name carrying BOTH a space and a comma. Measured at ZERO warnings on `main` — the #414
  # degrade warning fired only when the last torn fragment happened to contain no space, so this
  # produced phantoms in complete silence.
  model3 = convertSQLToModel(_introspection_row(
    table_name   = "comma_spaced_name",
    columns      = [_col("id", "bigint"; notnull = true), _col("Driver Ref, Total", "bigint")],
    primary_keys = ["id"]))

  @test Set(keys(model3.fields)) == Set(["id", "Driver Ref, Total"])

  # Row 4, the one most likely to occur in a real schema and also silent: a multi-argument function
  # default followed by a marker. `pg_get_expr` renders `concat('a','b')` with a `, `, and such a
  # column is usually NOT NULL. Pre-fix field keys: `'b'::text)`, `id`, `note`.
  #
  # SCOPED DELIBERATELY: what is asserted is that the COLUMN round-trips and keeps its NOT NULL —
  # not that PormG reproduces an expression default. It cannot; `note.default` is the literal
  # string `concat('a'::text, 'b'::text)`, which PormG would re-emit as a quoted literal. That is
  # pre-existing, out of scope here, and asserting otherwise would be asserting a bug.
  model4 = convertSQLToModel(_introspection_row(
    table_name   = "comma_fn_default",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("note", "text"; notnull = true, default = "concat('a'::text, 'b'::text)")],
    primary_keys = ["id"]))

  @test Set(keys(model4.fields)) == Set(["id", "note"])
  @test model4.fields["note"].null == false
end

@testset "a comma-space in a KEY, an FK or an INDEX cannot misalign either (#455)" begin
  # The aggregates #455 widened past the issue's own scope, because `", "` was the entry separator
  # for ALL of them and three were consumed by zipping parallel splits.
  #
  # `primary_keys` tore on the SAME name as `columns`, so both sides agreed on both WRONG names and
  # both phantoms came back marked as keys.
  keyed = convertSQLToModel(_introspection_row(
    table_name   = "comma_key",
    columns      = [_col("Key, Col", "bigint"; notnull = true), _col("label", "text")],
    primary_keys = ["Key, Col"]))

  @test Set(keys(keyed.fields)) == Set(["Key, Col", "label"])
  @test keyed.fields["Key, Col"] isa PormG.Models.sIDField
  @test keyed.fields["Key, Col"].primary_key

  # THE FK MISALIGNMENT GATE, and the worst of the four failures. Six parallel aggregates were
  # zipped positionally and `zip` truncates to the shortest, so a `, ` in a PARENT TABLE name made
  # `fk_tables` one entry longer than `fk_cols` and shifted every LATER foreign key onto a
  # different parent. `plain_id` is declared AFTER the comma-named parent for exactly that reason:
  # it is the column that came back pointing at the wrong — but real — table, which the planner
  # then diffed into a DROP/ADD CONSTRAINT against a table the relation never named.
  rel = convertSQLToModel(_introspection_row(
    table_name   = "comma_child",
    columns      = [_col("id", "bigint"; notnull = true), _col("first_id", "bigint"),
                    _col("plain_id", "bigint")],
    primary_keys = ["id"],
    foreign_keys = [_fk("first_id", "comma, parent", "Ref, Key"; on_delete = "c"),
                    _fk("plain_id", "plain_parent", "id"; on_delete = "n")]))

  @test rel.fields["first_id"].to_table == "comma, parent"
  @test rel.fields["first_id"].pk_field == "Ref, Key"
  @test rel.fields["first_id"].on_delete === PormG.Models.CASCADE
  # The shifted one. Pre-fix this named `comma` or `parent"`, never `plain_parent`.
  @test rel.fields["plain_id"].to_table == "plain_parent"
  @test rel.fields["plain_id"].pk_field == "id"
  @test rel.fields["plain_id"].on_delete === PormG.Models.SET_NULL

  # The index pair was the other zip. A shifted index NAME reaches `planner._drop_index`, so a
  # model that stops declaring `db_index` on one column could emit `DROP INDEX` for another's.
  idx = convertSQLToModel(_introspection_row(
    table_name   = "comma_idx",
    columns      = [_col("id", "bigint"; notnull = true), _col("Idx, Col", "bigint"),
                    _col("plain", "bigint")],
    primary_keys = ["id"],
    indexes      = [_ix("Idx, Col", "comma_idx_first"), _ix("plain", "comma_idx_second")]))

  @test idx.fields["Idx, Col"].db_index
  @test idx.cache["index"]["Idx, Col"] == "comma_idx_first"
  @test idx.cache["index"]["plain"]    == "comma_idx_second"
end

@testset "a DEFAULT can no longer forge a column marker (#455)" begin
  # #318 moved the UNIQUE test from `occursin` to token membership, which fixed the single-word
  # `DEFAULT 'UNIQUE'`; #414 removed the NAME's contribution. What neither could remove is that the
  # DEFAULT still shared one string with every marker being scanned — so these two shapes, both
  # legal and both silent, still produced fabricated constraints on `main`.
  #
  # They are structurally impossible now: `notnull` and `unique` are their own JSON fields. These
  # are the anti-regression gates for anyone tempted to fold the markers back into the type string.
  model = convertSQLToModel(_introspection_row(
    table_name   = "forged_markers",
    columns      = [_col("id", "bigint"; notnull = true),
                    # A NULLABLE column whose default literal contains "NOT NULL".
                    _col("nul", "text"; default = "'NOT NULL'::text"),
                    # A NON-UNIQUE column whose default literal contains "UNIQUE" as its own word —
                    # the multi-word form #318's token test cannot tell from a real marker.
                    _col("uq", "text"; default = "'a UNIQUE b'::text")],
    primary_keys = ["id"]))

  @test model.fields["nul"].null == true            # `occursin("NOT NULL", …)` used to fire here
  @test model.fields["nul"].default == "NOT NULL"
  @test model.fields["uq"].unique == false          # `"UNIQUE" in col_parts` used to fire here
  @test model.fields["uq"].default == "a UNIQUE b"
end

@testset "the #414 degrade path is gone rather than merely rare (#455)" begin
  # Acceptance checkbox 4 is satisfied by DELETION, not by a guard — the strongest form the claim
  # can take. `_split_leading_quoted_ident` peeled a `quote_ident`-ed name off a rendered entry and
  # `_unquote_ident` was its inverse; the schema query emits neither a rendered entry nor a quoted
  # identifier any more, so both are gone.
  #
  # The precedent for asserting a definition's absence is `!isdefined(Models, :sAutoField)` in
  # test_key_type_round_trip.jl (#408): a lingering definition is a lingering code path.
  @test !isdefined(PormG.Migrations, :_split_leading_quoted_ident)
  @test !isdefined(PormG.Migrations, :_unquote_ident)

  # …and the warning they degraded into is not merely unreached, it is unreachable: the row that
  # used to produce it now reads cleanly. `min_level = Logging.Warn` fails on ANY warning, which is
  # what makes this a gate rather than a formality.
  #
  # The `note` default is a QUOTED literal (#475). It was `concat('a'::text, 'b'::text)` — chosen
  # here for the `, ` this file's #455 fixtures are about — but an expression default now warns on
  # every column type, which would fail this zero-warning gate for a reason that has nothing to do
  # with identifier tearing. A quoted literal carrying the same `, ` tests the tear just as well.
  @test_logs min_level = Logging.Warn convertSQLToModel(_introspection_row(
    table_name   = "no_warn",
    columns      = [_col("id", "bigint"; notnull = true), _col("Race, Total", "bigint"),
                    _col("note", "text"; notnull = true, default = "'Ferrari, Scuderia'::text")],
    primary_keys = ["id"]))
end

@testset "_pg_clean_default undoes pg_get_expr without truncating (#455)" begin
  # Direct coverage for the helper, because the reader can only show a few of its branches and each
  # of these was a distinct way the old three-line `replace` chain went wrong.
  clean = PormG.Migrations._pg_clean_default

  @test clean(nothing) === nothing
  @test clean("1") == "1"
  @test clean("(0)::numeric") == "0"                            # cast, then the paren wrapper
  @test clean("'Ferrari, Scuderia'::character varying") == "Ferrari, Scuderia"
  @test clean("'a, b'::character varying(40)") == "a, b"        # a cast that carries a modifier
  @test clean("'it''s'::text") == "it's"                        # `''` is one escaped quote
  @test clean("'x'::\"MyEnum\"") == "x"                         # a quoted user-defined type

  # THE anchoring gate. The old cast strip was global, so it rewrote `'{1,2}'::integer[]` to
  # `'{1,2}'[]` — losing the array default the issue names by example.
  @test clean("'{1,2}'::integer[]") == "{1,2}"

  # Balance-checked unwrapping, not regex-anchored. `r"^\((.+)\)$"` turned the first into `a) + (b`,
  # and `r"^'(.+)'$"` would treat the second — a concatenation of two literals — as one literal.
  #
  # Both are EXPRESSIONS, so since #475 they come back tagged rather than as bare Strings. What this
  # block is testing is unchanged: that the TEXT survives unmangled. `_ExpressionDefault` compares
  # by its `.sql`, so the assertion still reads as the expression it is about.
  @test clean("(a) + (b)") == sql_expr("(a) + (b)")
  @test clean("'a' || 'b'") == sql_expr("'a' || 'b'")

  # THE CONDITIONAL-RE-STRIP GATE, found in review. `pg_get_expr` parenthesizes every non-trivial
  # expression, so after unwrapping those parens the inner text is usually a COMPOUND expression
  # whose trailing cast belongs to its last OPERAND. Re-stripping unconditionally — which the first
  # implementation did — turns these into MANGLED expressions rather than unrecognized ones, which
  # is strictly worse: an unrecognized default is refused, a mangled one may be accepted.
  @test clean("('x'::text || 'y'::text)") == sql_expr("'x'::text || 'y'::text")
  @test clean("(now() - '1 day'::interval)") == sql_expr("now() - '1 day'::interval")
  # …while the case the re-strip exists for still reduces, because it reduces to a LITERAL.
  @test clean("('x'::text)") == "x"

  # A bare NULL is "no default", not the four-character string. `_normalize_sqlite_default` gives
  # the same answer for the same input, and the two engines have to agree (#455).
  # `DEFAULT NULL::character varying` is a shape pg_dump emits routinely.
  @test clean("NULL::text") === nothing
  @test clean("NULL") === nothing
  @test clean("'NULL'::text") == "NULL"        # the LITERAL string is still a real default

  # An expression that cannot reduce to a literal is returned WHOLE and TAGGED (#475), so the reader
  # arms drop it on every column type instead of asking each field constructor to judge it.
  # `nextval(...)` is what `_fk_default_or_warn` above already refuses by name.
  @test clean("concat('a'::text, 'b'::text)") == sql_expr("concat('a'::text, 'b'::text)")
  @test clean("nextval('s'::regclass)") == sql_expr("nextval('s'::regclass)")

  # …and every literal above is still a bare String, not a tag. Asserted as a type, because `==`
  # on `_ExpressionDefault` is deliberately not defined against `AbstractString`: if the classifier
  # ever mistook one of these for an expression, the `==` assertions above would keep passing while
  # the reader silently dropped a real default.
  for lit in ("1", "(0)::numeric", "'Ferrari, Scuderia'::character varying", "'{1,2}'::integer[]",
              "('x'::text)", "'NULL'::text")
    @test clean(lit) isa String
  end
end

@testset "the type arrives whole, so no spelling needs rewriting (#455)" begin
  # `format_type` output is its own JSON field now, which retires two workarounds at once: the
  # `replace(col, "double precision" => "double_precision")` that ran over the whole rendered entry
  # (and so also rewrote a column so NAMED), and the `character varying\((\d+)\)` re-match that
  # existed because `col_parts[1]` was only ever `character`.
  split_ft = PormG.Migrations._pg_split_format_type
  tm = PormG.postgres_type_map

  @test split_ft("character varying(120)", tm) == ("varchar", "120")
  @test split_ft("double precision", tm)       == ("double_precision", nothing)
  @test split_ft("numeric(10,2)", tm)          == ("numeric", "10,2")

  # The modifier is the FIRST parenthesized group and is REMOVED rather than assumed to trail:
  # `format_type` renders datetime precision in the MIDDLE. Applying it by pattern rather than by
  # type is how `timestamp(3)` would have become a `max_length`.
  @test split_ft("timestamp(3) without time zone", tm) == ("timestamp", "3")

  # Unmatched long spellings fall back to the first word, exactly as `split(col_rest, " ")[1]` did,
  # so an unknown type still degrades to TextField rather than being re-typed.
  @test split_ft("interval day to second(3)", tm) == ("interval", "3")
  @test split_ft("integer[]", tm)                 == ("integer[]", nothing)

  # Through the reader: the modifier lands on the right slot for the right type, and nowhere for a
  # type that has no such slot.
  model = convertSQLToModel(_introspection_row(
    table_name   = "types_probe",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("name", "character varying(40)"),
                    _col("ratio", "double precision"),
                    _col("amount", "numeric(9,3)"),
                    _col("seen_at", "timestamp(3) without time zone")],
    primary_keys = ["id"]))

  @test model.fields["name"] isa PormG.Models.sCharField
  @test model.fields["name"].max_length == 40
  @test model.fields["ratio"] isa PormG.Models.sFloatField
  @test model.fields["amount"] isa PormG.Models.sDecimalField
  @test model.fields["amount"].max_digits == 9
  @test model.fields["amount"].decimal_places == 3
  # The one that would regress if the modifier were applied by pattern: a DateTimeField with a
  # `max_length` of 3, or (pre-#455) a TextField, because `timestamp(3)` matched no type-map key.
  @test model.fields["seen_at"] isa PormG.Models.sDateTimeField
end

# ════════════════════════════════════════════════════════════════════════════════════════════════
# #472 — an unrepresentable column DEFAULT on a NON-FK column
#
# #292 gave the five foreign-key arms `_fk_default_or_warn`: warn, drop the default, never throw.
# The seven other arms kept passing the introspected default straight into the constructor, where
# `validate_default` THROWS — so one `created_at timestamptz DEFAULT now()` aborted the entire
# `convert_schema_to_models` read and `inspectdb` produced nothing for the whole database.
#
# Measured on `main` before the fix (this row, this reader): `now()`, `CURRENT_DATE`,
# `(random() * …)`, `time now()`, `random()` and `gen_random_uuid()` all raised
# `FieldValidationError`. Only a `text` column survived, because `TextField` accepts any `String`.
# ════════════════════════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# Introspection: an unrepresentable column default is dropped, not fatal
# The whole read must complete, every column must arrive, and every attribute OTHER than the
# default must survive — the retry inside the guard rebuilds the field with the same kwargs, so a
# `NOT NULL` that went missing would mean the guard dropped more than it was asked to.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unrepresentable column default warns and is dropped, never throws (#472)" begin
  # Type spellings are what `format_type` renders and defaults are what `pg_get_expr` renders —
  # the reader sees exactly these strings from the live schema query.
  expr_columns = [_col("id", "bigint"; notnull = true),
                  _col("created_at", "timestamp with time zone"; notnull = true, default = "now()"),
                  _col("d", "date"; default = "CURRENT_DATE"),
                  _col("n", "integer"; default = "(random() * (10)::double precision)"),
                  _col("tm", "time without time zone"; default = "now()"),
                  _col("fl", "double precision"; default = "random()"),
                  _col("u", "uuid"; default = "gen_random_uuid()"),
                  # Controls, in the SAME row: a representable default must be untouched by a
                  # sibling column's failure, which a per-row abort could never demonstrate.
                  _col("ok", "integer"; default = "5"),
                  _col("note", "text"; notnull = true, default = "concat('a'::text, 'b'::text)")]

  logs, model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name = "expr_defaults", columns = expr_columns, primary_keys = ["id"]))
  end

  # 1. THE regression gate: the read completed at all. Pre-fix this line never ran — the
  #    `@testset` reported an Error from `FieldValidationError`, not a failure.
  @test Set(keys(model.fields)) ==
        Set(["id", "created_at", "d", "n", "tm", "fl", "u", "ok", "note"])

  # 2. Each unrepresentable default is gone, and the COLUMN is still its real type. Dropping the
  #    default must not degrade `timestamptz` to text, which is the other way an importer could
  #    "not crash" while still destroying the schema.
  @test model.fields["created_at"] isa PormG.Models.sDateTimeField
  @test model.fields["d"]  isa PormG.Models.sDateField
  @test model.fields["n"]  isa PormG.Models.sIntegerField
  @test model.fields["tm"] isa PormG.Models.sTimeField
  @test model.fields["fl"] isa PormG.Models.sFloatField
  @test model.fields["u"]  isa PormG.Models.sUUIDField
  for c in ("created_at", "d", "n", "tm", "fl", "u")
    @test model.fields[c].default === nothing
  end

  # 3. Every OTHER attribute survived the retry. `created_at` is NOT NULL in the fixture, and a
  #    guard that rebuilt the field with defaulted kwargs would silently report it nullable —
  #    which the planner would then propose "fixing" with an ALTER on every run.
  @test model.fields["created_at"].null == false

  # 4. Representable defaults are untouched, including on a row where seven siblings failed.
  @test model.fields["ok"].default == 5
  # THE #475 REVERSAL, and the headline assertion of this file. A text column used to KEEP an
  # expression as a quoted literal — `TextField` validates against `Union{String, Nothing}` and
  # accepts anything, so the same `concat(…)` that aborted a `date` column slipped through here
  # silently, and `Model_to_str` wrote `default="concat('a'::text, 'b'::text)"` into the generated
  # models file, where re-applying it renders `DEFAULT 'concat(...)'` and stores that TEXT in every
  # new row. The outcome is now decided by the schema, not by which field type happens to refuse a
  # String, so `text` and `date` reach the same answer.
  @test model.fields["note"].default === nothing
  # …and the column is otherwise untouched: still text, still NOT NULL. Dropping a default must not
  # cost the column anything else.
  @test model.fields["note"] isa PormG.Models.sTextField
  @test model.fields["note"].null == false

  # 5. The failure is REPORTED, not silent — one warning per dropped column, each naming the table
  #    and the column, so a large import says which columns lost a default and where.
  warns = filter(l -> l.level == Logging.Warn &&
                      occursin("could not be represented", l.message), logs)
  @test length(warns) == 7          # six typed columns + `note`, which used to be kept silently

  by_col = Dict(string(Dict(w.kwargs)[:column]) => Dict(w.kwargs) for w in warns)
  @test Set(keys(by_col)) == Set(["created_at", "d", "n", "tm", "fl", "u", "note"])
  @test by_col["created_at"][:table] == "expr_defaults"
  # The RAW value, as introspection received it: enough to find the column in the DDL.
  @test by_col["created_at"][:default] == "now()"
  @test by_col["d"][:default] == "CURRENT_DATE"
  # …and the field type it ended up as, so the warning says what PormG imported instead — in the
  # PUBLIC spelling the user declares (`DateTimeField`), not the private struct name
  # (`sDateTimeField`), which is the convention `Model_to_str`'s own degrade warning follows.
  @test by_col["created_at"][:field_type] == "DateTimeField"
  # …and WHY. Since #475 an expression never reaches a constructor at all — it is classified by the
  # cleaner and dropped before one is asked — so there is no `FieldValidationError` to quote and the
  # reason names the actual condition instead.
  @test occursin("SQL expression", by_col["created_at"][:reason])
  @test occursin("SQL expression", by_col["note"][:reason])
  # The kwarg SET is identical on both arms, so no consumer has to branch on which one fired.
  @test by_col["note"][:table] == "expr_defaults"
  @test by_col["note"][:field_type] == "TextField"
  @test by_col["note"][:default] == "concat('a'::text, 'b'::text)"

  # 6. The mirror image, and the reason `min_level` is used rather than a count: a row whose
  #    defaults are ALL representable must produce no warning at all. Without this, a guard that
  #    warned unconditionally would pass every assertion above.
  #
  #    Since #475 this is also THE gate on the classifier's cheapest way to be wrong. `ok` and
  #    `flag` arrive at the cleaner as the BARE tokens `5` and `true` — the very same unquoted
  #    fallthrough branch that carries `now()` — and they are literals only because
  #    `_is_sql_literal_token` says so. A fix that dropped that branch wholesale, rather than
  #    classifying it, would take every unquoted numeric and boolean default with it and fail here.
  #    `note` is a quoted literal that CONTAINS an expression's spelling, which no classifier
  #    working on the cleaner's unquoted OUTPUT could tell from the real thing.
  @test_logs min_level = Logging.Warn convertSQLToModel(_introspection_row(
    table_name   = "clean_defaults",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("ok", "integer"; default = "5"),
                    _col("flag", "boolean"; default = "true"),
                    _col("note", "text"; notnull = true, default = "'concat(a, b)'::text")],
    primary_keys = ["id"]))
end

# ─────────────────────────────────────────────────────────────────────────────
# Introspection: the KEY arms drop an unrepresentable default too
# `default=` reaches three PostgreSQL arms, not one. The issue named only the generic arm, but a
# `uuid PRIMARY KEY DEFAULT gen_random_uuid()` is the single most common uuid-key declaration
# there is, and it aborted the read exactly the same way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the UUID and VARCHAR key arms drop an unrepresentable default too (#472)" begin
  # UUID primary key. `gen_random_uuid()` is not a UUID literal, so `UUIDField` rejects it.
  logs_uuid, uuid_model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "uuid_keyed",
      columns      = [_col("id", "uuid"; notnull = true, default = "gen_random_uuid()"),
                      _col("label", "text")],
      primary_keys = ["id"]))
  end

  key = uuid_model.fields["id"]
  @test key isa PormG.Models.sUUIDField    # still reconstructed as its real type (#334)
  @test key.primary_key
  @test key.default === nothing
  @test count(l -> l.level == Logging.Warn &&
                   occursin("could not be represented", l.message), logs_uuid) == 1

  # VARCHAR natural key (#409). `CharField` rejects a default longer than `max_length`, which is
  # the only way this arm can refuse a string — and it is a real shape: a legacy key column with a
  # computed default that does not fit the declared width.
  logs_char, char_model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "char_keyed",
      columns      = [_col("code", "character varying(5)"; notnull = true,
                           default = "concat('a'::text, 'b'::text)"),
                      _col("label", "text")],
      primary_keys = ["code"]))
  end

  code = char_model.fields["code"]
  @test code isa PormG.Models.sCharField
  @test code.primary_key
  @test code.max_length == 5              # the declared width survived the retry
  @test code.default === nothing
  @test count(l -> l.level == Logging.Warn &&
                   occursin("could not be represented", l.message), logs_char) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# The guard blames the default only when the default IS the culprit
# `FieldValidationError` is also what a bad `max_length` raises, so a guard that caught it and
# reported "bad default" would lie about failures that have nothing to do with the default. The
# retry is what separates the two: if the field cannot be built WITHOUT the default either, the
# exception propagates undisguised and no warning is emitted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a failure that is not about the default propagates undisguised (#472)" begin
  # `max_length = 0` is rejected by CharField itself, with or without a default.
  err = nothing
  logs, _ = Test.collect_test_logs() do
    err = try
      _field_or_drop_default("t", "c", "anything") do d
        PormG.Models.CharField(max_length = 0, default = d)
      end
      nothing
    catch e
      e
    end
  end

  @test err isa PormG.FieldValidationError            # the REAL error, not a swallowed one
  @test occursin("max_length", sprint(showerror, err))  # …and it still says what is wrong
  # The gate: no warning. A guard that warned before retrying would have told the user the column
  # default was at fault, sending them to look at a DEFAULT that is perfectly fine.
  @test isempty(filter(l -> l.level == Logging.Warn, logs))

  # And the ordinary path still works when the default IS the culprit: same constructor, legal
  # `max_length`, a default that does not fit.
  logs2, field = Test.collect_test_logs() do
    _field_or_drop_default("t", "c", "way too long for five") do d
      PormG.Models.CharField(max_length = 5, default = d)
    end
  end
  @test field isa PormG.Models.sCharField
  @test field.default === nothing
  @test length(filter(l -> l.level == Logging.Warn, logs2)) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# A cancelled import is not a bad column default
# `_fk_default_or_warn` carries this carve-out explicitly (#292). The #472 guard gets it BY
# CONSTRUCTION by catching only `FieldValidationError` — but that is only honest because
# `validate_default` stopped relabelling an interrupt raised inside a converter, which it did
# until this change. Both halves are pinned here; the first alone would pass with the relabelling
# still in place.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an interrupt during a large import aborts rather than being a bad default (#472)" begin
  # The guard itself: nothing but a FieldValidationError may be caught.
  @test_throws InterruptException _field_or_drop_default("t", "c", "x") do d
    throw(InterruptException())
  end
  @test_throws StackOverflowError _field_or_drop_default("t", "c", "x") do d
    throw(StackOverflowError())
  end

  # …and the layer underneath, which is what made the narrow catch safe. Pre-fix BOTH of these
  # returned a `FieldValidationError`, so a Ctrl-C mid-import reached the guard disguised as a bad
  # default, got retried, and was reported as one.
  @test_throws InterruptException PormG.Models.validate_default(
      "x", Int64, "F", _ -> throw(InterruptException()))
  @test_throws StackOverflowError PormG.Models.validate_default(
      "x", Int64, "F", _ -> throw(StackOverflowError()))

  # The control that keeps the carve-out from being a blanket rethrow: an ordinary converter
  # failure is still a FieldValidationError, which is the entire contract the guard relies on.
  @test_throws PormG.FieldValidationError PormG.Models.validate_default(
      "x", Int64, "F", _ -> error("boom"))
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: an unquoted default is classified, not kept
# #472 widened this branch from the `SubString` that `strip` produced to a `String`, because
# `TextField`'s converter is `parse(String, x)` — which has no method for ANY input — so a
# `SubString` threw and even `TEXT DEFAULT CURRENT_TIMESTAMP` aborted the read. That made SQLite
# agree with PostgreSQL, but at the wrong answer: BOTH then kept an expression as a quoted literal
# on a textual column. #475 keeps the widening (a literal still has to be a `String`) and adds the
# question that was missing — is this unquoted token a LITERAL or an EXPRESSION?
# ─────────────────────────────────────────────────────────────────────────────
@testset "a SQLite unquoted default is classified as literal or expression (#475)" begin
  norm = PormG.Migrations._normalize_sqlite_default

  # THE reversal. These reach the cleaner's unquoted fallthrough and are now tagged, so every reader
  # arm drops them — a `text` column no longer gets a different answer from a `date` one.
  @test norm("CURRENT_TIMESTAMP", :TextField) == sql_expr("CURRENT_TIMESTAMP")
  @test norm("(datetime('now'))", :DateTimeField) == sql_expr("datetime('now')")
  @test norm("(random()*10)", :IntegerField) == sql_expr("random()*10")

  # …and the half of #472 that must NOT regress: a genuine literal is still a `String`, never the
  # `SubString` `strip` produces, because `parse(String, ::SubString)` has no method.
  @test norm("'abc'", :TextField) isa String
  @test norm("5", :IntegerField) isa String

  # Values are unchanged — this classifies, it does not reinterpret anything.
  @test norm("'abc'", :TextField) == "abc"
  @test norm("5", :IntegerField) == "5"
  @test norm("NULL", :TextField) === nothing
  @test norm(nothing, :TextField) === nothing
  @test norm("1", :BooleanField) === true          # the Bool branch still short-circuits
  @test norm("X'0102'", :BinaryField) == UInt8[0x01, 0x02]   # …and so does the bytes branch (#296)

  # THE mutation gate for #475, and the one assertion no post-hoc classifier can pass. Both cleaners
  # UNQUOTE a literal, so after that step these two inputs are the SAME BYTES — a classifier reading
  # the cleaner's RESULT must either keep the expression or drop the string a user deliberately
  # quoted. Only a decision made inside the cleaner, while the quoting is still visible, gets both.
  @test norm("'CURRENT_TIMESTAMP'", :TextField) == "CURRENT_TIMESTAMP"
  @test norm("'CURRENT_TIMESTAMP'", :TextField) isa String
  @test norm("CURRENT_TIMESTAMP", :TextField) == sql_expr("CURRENT_TIMESTAMP")

  # Through the DDL-regex reader (off the live route, but the one with unit coverage): a typed
  # column and a text column now reach the SAME outcome. Same row, one answer.
  logs, model = Test.collect_test_logs() do
    convertSQLToModel("""CREATE TABLE "sl_expr" (
        "id" INTEGER PRIMARY KEY,
        "created" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        "note" TEXT DEFAULT CURRENT_TIMESTAMP,
        "ok" INTEGER DEFAULT 5)""")
  end

  @test model.fields["created"] isa PormG.Models.sDateTimeField
  @test model.fields["created"].default === nothing
  @test model.fields["note"].default === nothing          # #475: was "CURRENT_TIMESTAMP"
  @test model.fields["note"] isa PormG.Models.sTextField  # …and it is still a text column
  @test model.fields["ok"].default == 5                   # the unquoted-LITERAL control
  warns = filter(l -> l.level == Logging.Warn &&
                      occursin("could not be represented", l.message), logs)
  @test length(warns) == 2
  @test Set(string(Dict(w.kwargs)[:column]) for w in warns) == Set(["created", "note"])
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: the LIVE reader (PRAGMA) agrees with the PostgreSQL one
# `convert_schema_to_models` on SQLite goes through the PRAGMA reader, not the DDL-regex one, so
# the block above proves nothing about production. The two readers must also AGREE: one engine
# dropping a default the other keeps is the two-readers-disagree failure #409/#417 exist to
# prevent, and it shows up as `makemigrations` churn on whichever engine the model was written for.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the live SQLite reader drops the same defaults as PostgreSQL (#472)" begin
  sl_model, sl_logs = mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "expr_defaults.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "expr_defaults" (
          "id" INTEGER PRIMARY KEY,
          "created_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          "d" DATE DEFAULT CURRENT_DATE,
          "n" INTEGER DEFAULT (abs(random()) % 10),
          "ok" INTEGER DEFAULT 5,
          "note" TEXT DEFAULT CURRENT_TIMESTAMP)""")
      logs, models = Test.collect_test_logs() do
        convert_schema_to_models(pool; include_table = ["expr_defaults"])
      end
      (only(m for m in models if lowercase(string(m.name)) == "expr_defaults"), logs)
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end

  # The read completed — pre-fix this raised from inside the PRAGMA reader's generic arm.
  @test Set(keys(sl_model.fields)) == Set(["id", "created_at", "d", "n", "ok", "note"])
  @test sl_model.fields["created_at"] isa PormG.Models.sDateTimeField
  @test sl_model.fields["created_at"].default === nothing
  @test sl_model.fields["created_at"].null == false     # NOT NULL survived the retry here too
  @test sl_model.fields["d"].default === nothing
  @test sl_model.fields["n"].default === nothing
  @test sl_model.fields["ok"].default == 5
  @test sl_model.fields["note"].default === nothing        # #475: was "CURRENT_TIMESTAMP"

  warns = filter(l -> l.level == Logging.Warn &&
                      occursin("could not be represented", l.message), sl_logs)
  @test length(warns) == 4
  @test Set(string(Dict(w.kwargs)[:column]) for w in warns) ==
        Set(["created_at", "d", "n", "note"])
  @test all(string(Dict(w.kwargs)[:table]) == "expr_defaults" for w in warns)

  # THE cross-engine assertion: the same logical column, read by two entirely separate
  # implementations, produces the same field type and the same (absent) default.
  pg_model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "expr_defaults",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("created_at", "timestamp with time zone"; notnull = true,
                           default = "now()"),
                      _col("note", "text"; default = "now()")],
      primary_keys = ["id"]))
  end[2]

  @test typeof(pg_model.fields["created_at"]) === typeof(sl_model.fields["created_at"])
  @test pg_model.fields["created_at"].default === sl_model.fields["created_at"].default === nothing
  # …and the half #475 reversed. This used to assert that BOTH engines KEEP an expression default on
  # a text column as a literal string — two engines agreeing on the wrong answer, which is what made
  # it look like a decision rather than an accident of `TextField` accepting any `String`. They now
  # agree on "no default", so the text column and the timestamptz column above are indistinguishable
  # in outcome. That is the whole of #475.
  @test pg_model.fields["note"].default === sl_model.fields["note"].default === nothing
  @test typeof(pg_model.fields["note"]) === typeof(sl_model.fields["note"])
end

# ─────────────────────────────────────────────────────────────────────────────
# A dropped expression default is not schema drift
# The consequence that decides whether this fix is usable: after it, a live `DEFAULT now()` reads
# back as "no default". If the planner compared that against a model declaring no default and saw
# a difference, every `makemigrations` would propose an ALTER — `DROP DEFAULT` on PostgreSQL, a
# FULL TABLE REBUILD on SQLite — forever, and the fix would have traded a hard abort for permanent
# churn. `:default` IS diffed (it is not in `_NON_SCHEMA_FIELD_ATTRS`), so this is asserted rather
# than assumed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a dropped expression default does not make makemigrations churn (#472)" begin
  # Built outside the log-assertion below on purpose: the read itself warns, and that warning is
  # not what this test is about.
  # `identity = "d"` (GENERATED BY DEFAULT AS IDENTITY) is what a PormG-created key column really
  # carries, and it is what a declared `IDField()` renders. Leaving it empty here would make the
  # key itself differ (`generated`), and the resulting `ADD GENERATED BY DEFAULT AS IDENTITY` in
  # the plan would be mistaken for the drift this testset exists to rule out.
  live = convertSQLToModel(_introspection_row(
    table_name   = "expr_defaults",
    columns      = [_col("id", "bigint"; notnull = true, identity = "d"),
                    _col("created_at", "timestamp with time zone"; notnull = true,
                         default = "now()"),
                    _col("d", "date"; default = "CURRENT_DATE"),
                    _col("ok", "integer"; default = "5")],
    primary_keys = ["id"]))

  # The dropped defaults are the precondition for everything below.
  @test live.fields["created_at"].default === nothing
  @test live.fields["d"].default === nothing

  settings = PormG.Configuration.Settings()
  settings.change_db = true

  # What a user would actually declare for `created_at timestamptz NOT NULL DEFAULT now()`: the
  # Django-shaped answer, which carries no `default` at all (`auto_now_add` is applied by PormG on
  # insert, never rendered into DDL, and is exempt from the diff via `_NON_SCHEMA_FIELD_ATTRS`).
  # It is deliberately NOT the trivially-equal declaration: `auto_now_add` makes the fast path
  # `Models._compare_model_field` report "changed", so the detailed per-attribute loop runs for
  # real and has to filter it — which is the path a live schema actually takes.
  declared = PormG.Models.Model("expr_defaults",
      id         = PormG.Models.IDField(),
      created_at = PormG.Models.DateTimeField(auto_now_add = true, null = false),
      d          = PormG.Models.DateField(null = true),
      ok         = PormG.Models.IntegerField(default = 5, null = true))

  for conn in (IntrospectionGuardMockSQLite(), IntrospectionGuardMockPg())
    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :expr_defaults => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))

    # `min_level = Logging.Warn` with no expected specs asserts ZERO warnings: planning over a
    # model whose default was dropped at import time must be silent as well as empty.
    plan = @test_logs min_level = Logging.Warn PormG.Migrations.get_migration_plan(
        PormGModel[live], current_schema, conn, settings)

    # THE assertion. A non-empty plan here is `ALTER COLUMN … DROP DEFAULT` on PostgreSQL and a
    # full table rebuild on SQLite, proposed again on every single `makemigrations` — which would
    # have made this fix a trade of one hard failure for permanent churn.
    @test !haskey(plan, :expr_defaults) || isempty(plan[:expr_defaults])
  end

  # THE control, without which the assertion above would also pass on a planner that ignored
  # `:default` entirely: a REAL default difference must still be proposed. PostgreSQL only —
  # a genuine difference sends SQLite down `_sqlite_rebuild_preserving_indexes`, which queries the
  # connection for secondary indexes and so needs a live database rather than a mock. Same
  # restriction, for the same reason, as `test_fk_to_table_planner.jl`'s real-difference testset.
  changed = PormG.Models.Model("expr_defaults",
      id         = PormG.Models.IDField(),
      created_at = PormG.Models.DateTimeField(auto_now_add = true, null = false),
      d          = PormG.Models.DateField(null = true),
      ok         = PormG.Models.IntegerField(default = 7, null = true))

  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :expr_defaults => Dict{Symbol, Union{Bool, PormGModel}}(:model => changed, :exist => false))

  plan = PormG.Migrations.get_migration_plan(
      PormGModel[live], current_schema, IntrospectionGuardMockPg(), settings)

  @test haskey(plan, :expr_defaults) && !isempty(plan[:expr_defaults])
  @test any(occursin("DEFAULT", sql) for sql in values(plan[:expr_defaults]))
end

# ─────────────────────────────────────────────────────────────────────────────
# The width is validated against the default, not stamped on afterwards
# The generic arms build the field and then ASSIGN `max_length`, which is a plain struct write
# with no checks — so `CharField`'s own "a default must fit max_length" rule was bypassed and a
# `varchar(5) DEFAULT concat('a','b')` imported as `CharField(max_length=5, default=<28 chars>)`.
# That field is one `CharField` itself refuses, so `inspectdb` wrote a models file that threw at
# `set_models`: the abort MOVED out of introspection instead of going away. Found in review.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a default too long for the column's width is dropped, not stamped past the check (#472)" begin
  # NON-key, which is what makes this distinct from the `char_keyed` case above: the key arm
  # passes `max_length` to the constructor and always validated; the generic arm did not.
  logs, model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "narrow_default",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("code", "character varying(5)";
                           default = "concat('a'::text, 'b'::text)")],
      primary_keys = ["id"]))
  end

  code = model.fields["code"]
  @test code isa PormG.Models.sCharField
  @test code.max_length == 5          # the real width, not CharField's invented 250
  @test code.default === nothing      # …and the default that does not fit is gone
  @test count(l -> l.level == Logging.Warn &&
                   occursin("could not be represented", l.message), logs) == 1

  # THE assertion that makes this a regression rather than a restatement: what `inspectdb` writes
  # must LOAD. Pre-fix this field was `CharField(max_length=5, default=<28 chars>)`, and
  # re-declaring it — which is exactly what the generated models file does — threw.
  @test PormG.Models.CharField(max_length = code.max_length, null = true,
                               default = code.default) isa PormG.Models.sCharField

  # The control: a default that DOES fit is untouched, so the guard is not just dropping every
  # default on a sized column.
  fits = convertSQLToModel(_introspection_row(
    table_name   = "narrow_default_ok",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("code", "character varying(5)"; default = "'abc'::character varying")],
    primary_keys = ["id"]))
  @test fits.fields["code"].max_length == 5
  @test fits.fields["code"].default == "abc"

  # And a DecimalField still gets its precision — the other modifier stamped after construction.
  dec = convertSQLToModel(_introspection_row(
    table_name   = "decimal_default",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("amount", "numeric(9,3)"; default = "1.5")],
    primary_keys = ["id"]))
  @test dec.fields["amount"] isa PormG.Models.sDecimalField
  @test dec.fields["amount"].max_digits == 9
  @test dec.fields["amount"].decimal_places == 3
  @test dec.fields["amount"].default == 1.5
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite unwraps parentheses by BALANCE, so a compound default is not mangled
# `_strip_sqlite_default_wrapper` tested `startswith("(") && endswith(")")`, which is true of
# `(a) + (b)` even though the opening paren does not close on the final character — it unwrapped
# to `a) + (b`. That was survivable only while such a value went on to throw. Now that SQLite
# defaults degrade to a `String` and a text column KEEPS the value, a mangled one would be written
# into the generated model and re-rendered as `DEFAULT 'a) + (b'`. Found in review.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a compound SQLite default is not mangled by paren unwrapping (#472)" begin
  norm = PormG.Migrations._normalize_sqlite_default
  clean_pg = PormG.Migrations._pg_clean_default

  # Each of these has a `(` first and a `)` last WITHOUT being one parenthesized group. The second
  # column is what the pre-fix code produced.
  for expr in ["(a) + (b)",                              # -> "a) + (b"
               "((x)+(y))",                              # -> "x)+(y"
               "((strftime('%s','now')) * (1000))",      # -> "strftime('%s','now')) * (1000"
               "(('a') || ('b'))"]                       # -> "a') || ('b"
    got = norm(expr, :TextField)
    # Every one of these is an EXPRESSION, so since #475 the cleaners tag it rather than returning
    # a bare String — which is itself worth asserting here: the mangling this testset is about was
    # only ever survivable because a text column KEPT the mangled value.
    @test got isa PormG.Migrations._ExpressionDefault
    # Balanced: as many `(` as `)`. The mangled forms all fail this.
    @test count(==('('), got.sql) == count(==(')'), got.sql)
    # THE cross-engine assertion, and the reason this is in scope for #472 at all: the diff claims
    # the two engines agree on an unrepresentable default, and they did not.
    @test got == clean_pg(expr)
  end

  # Genuine single-group wrapping still unwraps, including repeatedly — this is what the loop is
  # FOR, and a fix that simply stopped unwrapping would pass every assertion above. The unwrapping
  # runs BEFORE the #475 classification, so `(5)` reduces to a literal and `(datetime('now'))` to a
  # tagged expression: the paren handling is what decides which question is even asked.
  @test norm("(5)", :IntegerField) == "5"
  @test norm("('abc')", :TextField) == "abc"
  @test norm("(datetime('now'))", :DateTimeField) == sql_expr("datetime('now')")
  @test norm("((7))", :IntegerField) == "7"

  # A paren inside a string literal must not be counted — the reason the predicate is shared with
  # PostgreSQL rather than reimplemented.
  @test norm("(')(')", :TextField) == ")("
end

# ─────────────────────────────────────────────────────────────────────────────
# The SQLite PRAGMA reader's KEY arms are guarded too
# The live SQLite reader has three arms that pass a default, and the two KEY ones had no test:
# reverting both to their unguarded form left the whole unit suite green. Both are reachable from
# a hand-written or foreign schema, which is precisely the `inspectdb` population. Found in review.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the SQLite PRAGMA reader guards its UUID and CharField key arms (#472)" begin
  uuid_field, char_field, logs = mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "sl_keys.sqlite"); pool_size = 1)
    try
      # A UUID-typed primary key with a computed default. SQLite accepts any type name, so a
      # foreign schema really can declare `UUID`; PormG's own DDL never emits it, which is why
      # this arm existed untested.
      fetch(pool, """CREATE TABLE "sl_uuid_key" (
          "id" UUID PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
          "label" TEXT)""")
      # A sized textual natural key whose default does not fit the declared width.
      fetch(pool, """CREATE TABLE "sl_char_key" (
          "code" TEXT(5) PRIMARY KEY DEFAULT (lower('abcdefghijkl')),
          "label" TEXT)""")

      lg, models = Test.collect_test_logs() do
        convert_schema_to_models(pool; include_table = ["sl_uuid_key", "sl_char_key"])
      end
      by = Dict(lowercase(string(m.name)) => m for m in models)
      (by["sl_uuid_key"].fields["id"], by["sl_char_key"].fields["code"], lg)
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end

  # UUID key: reconstructed as its real type (#334), key intact, unrepresentable default gone.
  @test uuid_field isa PormG.Models.sUUIDField
  @test uuid_field.primary_key
  @test uuid_field.default === nothing

  # CharField key: the declared width survives and the over-long default is dropped.
  @test char_field isa PormG.Models.sCharField
  @test char_field.primary_key
  @test char_field.max_length == 5
  @test char_field.default === nothing

  # Both reported, naming their own table — the arms are guarded independently, so one warning
  # would mean only one of them is.
  warns = filter(l -> l.level == Logging.Warn &&
                      occursin("could not be represented", l.message), logs)
  @test length(warns) == 2
  @test Set(string(Dict(w.kwargs)[:table]) for w in warns) == Set(["sl_uuid_key", "sl_char_key"])
end

# ─────────────────────────────────────────────────────────────────────────────
# The width probe must not judge the default, and the warning must not cite a phantom width
# The generic arms learn which slot a field type carries by building one first. That probe carried
# the real default, so `CharField()`'s INVENTED `max_length = 250` judged it: a 300-character
# default on a `varchar(500)` was dropped, and `reason` blamed a `max_length is 250` that appears
# nowhere in the schema or the model. Found in delta review — introduced by the fix for the
# opposite bug, which is why the probe now carries no default at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a default that fits the column's real width is kept, whatever CharField invents (#472)" begin
  # 300 characters: comfortably over CharField's default 250, comfortably under the declared 500.
  wide = "'" * repeat("x", 300) * "'::character varying"

  logs, model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "wide_default",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("note", "character varying(500)"; default = wide)],
      primary_keys = ["id"]))
  end

  note = model.fields["note"]
  @test note isa PormG.Models.sCharField
  @test note.max_length == 500
  # THE assertion: the column accepts this default, so it must survive. Pre-fix it was `nothing`.
  @test note.default == repeat("x", 300)
  # …and no warning, because nothing was dropped. This is what makes the test a gate rather than a
  # restatement of the one above: a guard that dropped it would have warned.
  @test isempty(filter(l -> l.level == Logging.Warn &&
                            occursin("could not be represented", l.message), logs))

  # The boundary in the other direction still drops — the fix widened the accepted range, it did
  # not remove the rule.
  logs2, model2 = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "narrow_again",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("note", "character varying(100)"; default = wide)],
      primary_keys = ["id"]))
  end
  @test model2.fields["note"].max_length == 100
  @test model2.fields["note"].default === nothing
  warns2 = filter(l -> l.level == Logging.Warn &&
                       occursin("could not be represented", l.message), logs2)
  @test length(warns2) == 1
  # And when it DOES drop, the reason must cite the column's real width — not the constructor's
  # invented one. `250` appearing here is the phantom this testset exists to prevent.
  @test occursin("max_length is 100", Dict(first(warns2).kwargs)[:reason])
  @test !occursin("250", Dict(first(warns2).kwargs)[:reason])
end

# ─────────────────────────────────────────────────────────────────────────────
# A precision without a scale must not abort the whole read
# `DecimalField` refuses `max_digits` with no `decimal_places`, and that refusal reaches the RETRY
# as well — so both `build(default_val)` and `build(nothing)` throw and the second escapes, which
# is the whole-schema abort #472 exists to remove, arriving through the guard itself. `format_type`
# sets the pair together today, so this pins the arm rather than a reachable input.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a numeric precision with no scale cannot abort the read (#472)" begin
  # The premise, stated so the testset explains itself if the constructor ever changes.
  @test_throws PormG.FieldValidationError PormG.Models.DecimalField(max_digits = 10,
                                                                    decimal_places = nothing)

  # A numeric column carrying BOTH still gets them — the arm is guarded, not disabled.
  model = convertSQLToModel(_introspection_row(
    table_name   = "scaled",
    columns      = [_col("id", "bigint"; notnull = true),
                    _col("amount", "numeric(9,3)"; default = "1.5")],
    primary_keys = ["id"]))
  @test model.fields["amount"].max_digits == 9
  @test model.fields["amount"].decimal_places == 3
  @test model.fields["amount"].default == 1.5

  # A bare `numeric` — no precision at all — imports without one rather than throwing.
  bare = convertSQLToModel(_introspection_row(
    table_name   = "unscaled",
    columns      = [_col("id", "bigint"; notnull = true), _col("amount", "numeric")],
    primary_keys = ["id"]))
  @test bare.fields["amount"] isa PormG.Models.sDecimalField
end

# An `AbstractString` that raises `InterruptException` as soon as anything reads its contents.
# That puts the throw INSIDE each converter's own `try`, which is where a Ctrl-C during a large
# `convert_schema_to_models` run actually lands — a converter that catches broadly turns it into a
# `FieldValidationError` and introspection then reports a cancelled import as a bad column default.
struct InterruptOnRead <: AbstractString end
Base.ncodeunits(::InterruptOnRead) = 19
Base.codeunit(::InterruptOnRead) = UInt8
Base.codeunit(::InterruptOnRead, ::Integer) = throw(InterruptException())
Base.isvalid(::InterruptOnRead, ::Integer) = true
Base.iterate(::InterruptOnRead, i::Integer = 1) = throw(InterruptException())
Base.String(::InterruptOnRead) = throw(InterruptException())

# ─────────────────────────────────────────────────────────────────────────────
# Every converter `validate_default` is handed lets a cancelled import through
# The carve-out in `validate_default` is only half the contract: a converter with its own bare
# `catch` swallows the interrupt before `validate_default` can ever see it. Three did —
# `normalize_datetime_default` (two nested catches), `format_json_sql` and `format_date_sql` —
# and between them they cover `DEFAULT now()` and `DEFAULT CURRENT_DATE`, i.e. the two defaults
# every fixture in this file uses. Found in delta review.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no field converter disguises a cancelled import as a bad default (#472)" begin
  # An interrupt raised while the CONVERTER runs must reach the caller as an interrupt. Each of
  # these reaches a different converter with its own internal try/catch:
  #   DateTimeField -> normalize_datetime_default (two nested bare catches)
  #   DateField     -> format_date_sql
  #   JSONField     -> format_json_sql
  # `InterruptOnRead` raises the moment its contents are read, which is inside each converter's
  # own `try` — exactly where a real Ctrl-C during a large import would land.
  #
  # MEASURED COVERAGE, stated rather than implied. Reverting the three converter carve-outs fails
  # the JSONField line ONLY: this fixture raises on every read, so the datetime converter exhausts
  # all three of its parse attempts and the last throw escapes its `try` into `validate_default`'s
  # carve-out, and `format_date_sql` raises at the `occursin` that sits outside its own `try`. The
  # real hazard is the case a fixture cannot reproduce — ONE interrupt, swallowed by the first
  # attempt, after which the next attempt parses normally and the cancellation is lost entirely.
  # So two of these three lines are defence in depth against that, gated only by the JSON one.
  @test_throws InterruptException PormG.Models.DateTimeField(default = InterruptOnRead())
  @test_throws InterruptException PormG.Models.DateField(default = InterruptOnRead())
  @test_throws InterruptException PormG.Models.JSONField(default = InterruptOnRead())

  # The control that keeps the above from passing on a blanket rethrow: an ORDINARY bad default
  # still becomes a FieldValidationError, which is the contract the introspection guard catches.
  @test_throws PormG.FieldValidationError PormG.Models.DateField(default = "not-a-date")
  @test_throws PormG.FieldValidationError PormG.Models.JSONField(default = "{not json")
  @test_throws PormG.FieldValidationError PormG.Models.DateTimeField(default = "not-a-datetime")
end

# ════════════════════════════════════════════════════════════════════════════════════════════════
# #475 — a non-literal DEFAULT is treated the same on every column type
#
# #472 made an unrepresentable default survivable (drop + warn) and left one shape alone: a TEXTUAL
# column kept an expression as a quoted literal, because `TextField` validates against
# `Union{String, Nothing}` and accepts anything. So the outcome was decided by whether the field
# type happened to REFUSE the string rather than by anything about the schema — `text DEFAULT
# now()` and `timestamptz DEFAULT now()` reached opposite answers, and the textual one was silent.
#
# The fix classifies the DEFAULT inside the two cleaners, where the quoting is still visible, and
# routes an expression to the same drop-and-warn path every other column type already took. The
# testsets above carry the reversal itself; these five cover the ways the fix could be WRONG.
# ════════════════════════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# The unquoted fallthrough carries LITERALS too
# The trap in this issue, and the reason the fix is not "drop the fallthrough". Both cleaners route
# an unquoted token down one branch, and `5`, `-1` and `true` travel it alongside `now()`:
# `DEFAULT 5` reaches `IntegerField` as the STRING "5" and only becomes 5 because the converter is
# `format2int64`; `DEFAULT true` reaches `BooleanField` as "true" and is parsed there. A fix that
# dropped the branch wholesale would silently delete every unquoted numeric and boolean default in
# the schema — which no #472 testset would have caught, since they all use `DEFAULT 5` as a control
# and would simply have started failing without saying why.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the unquoted fallthrough keeps literals and tags only expressions (#475)" begin
  is_lit   = PormG.Migrations._is_sql_literal_token
  clean_pg = PormG.Migrations._pg_clean_default
  norm     = PormG.Migrations._normalize_sqlite_default

  # The predicate itself. Deliberately narrow because of WHERE it is called — every quoted form,
  # `NULL`, the SQLite blob literal and the SQLite booleans are claimed by a branch above it, so
  # the only inputs it ever judges are bare tokens.
  for lit in ("5", "-1", "+2", "0", "1.5", ".5", "1.", "1e10", "1E+10", "-2.5e-3",
              "true", "false", "TRUE", "False")
    @test is_lit(lit)
  end
  for ex in ("now()", "CURRENT_TIMESTAMP", "CURRENT_DATE", "nextval('s'::regclass)",
             "gen_random_uuid()", "random()*10", "a", "", "5 + 1", "1,2")
    @test !is_lit(ex)
  end

  # `0x1F` and `1_000` are EXPRESSIONS by decision, not by oversight: `parse(Int64, "0x1F")` would
  # succeed in Julia, but the same token on a FloatField column would not, and importing 31 as a
  # default the user never wrote is worse than reporting one PormG declined to read.
  @test !is_lit("0x1F")
  @test !is_lit("1_000")

  # …and the same answers through both cleaners, which is what the readers actually call.
  for (input, engine_type) in (("5", :IntegerField), ("-1", :IntegerField), ("1.5", :FloatField))
    @test clean_pg(input) isa String
    @test norm(input, engine_type) isa String
  end
  @test clean_pg("true") == "true"                    # PostgreSQL renders a boolean default bare
  @test clean_pg("now()") == sql_expr("now()")
  @test norm("CURRENT_TIMESTAMP", :DateTimeField) == sql_expr("CURRENT_TIMESTAMP")

  # THE consequence, through the reader rather than the helper: the literals still land on the
  # field, so the classifier bought the fix without costing an ordinary schema anything.
  logs, model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "lit_defaults",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("n",    "integer";          default = "5"),
                      _col("neg",  "integer";          default = "-1"),
                      _col("f",    "double precision"; default = "1.5"),
                      _col("flag", "boolean";          default = "true"),
                      _col("off",  "boolean";          default = "false")],
      primary_keys = ["id"]))
  end
  @test model.fields["n"].default    == 5
  @test model.fields["neg"].default  == -1
  @test model.fields["f"].default    == 1.5
  @test model.fields["flag"].default === true
  @test model.fields["off"].default  === false
  @test isempty(filter(l -> l.level == Logging.Warn, logs))
end

# ─────────────────────────────────────────────────────────────────────────────
# A quoted literal that LOOKS like an expression is still a literal
# THE mutation gate for the whole issue, and the assertion that pins the one design decision that
# cannot be walked back later. Both cleaners UNQUOTE a literal, so after that step `'now()'::text`
# and `now()` are the SAME BYTES — the string "now()". A classifier applied to the cleaner's RESULT
# is therefore forced to be wrong in one direction: keep the real expression, or drop the
# five-character string a user deliberately quoted and stored. Only a decision made INSIDE the
# cleaner, while the quoting is still there, answers both correctly.
#
# Without this testset the fix could be implemented the wrong way — a `_is_sql_literal_token` call
# in the reader arms instead of in the cleaners — and pass every other assertion in this file.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a quoted literal spelled like an expression is kept, not dropped (#475)" begin
  clean_pg = PormG.Migrations._pg_clean_default
  norm     = PormG.Migrations._normalize_sqlite_default

  # PostgreSQL: same output bytes, opposite classifications.
  @test clean_pg("'now()'::text") == "now()"
  @test clean_pg("'now()'::text") isa String
  @test clean_pg("now()")         == sql_expr("now()")

  @test clean_pg("'CURRENT_TIMESTAMP'::text") isa String
  @test clean_pg("CURRENT_TIMESTAMP")         == sql_expr("CURRENT_TIMESTAMP")

  # SQLite, both quoting styles it accepts.
  @test norm("'CURRENT_TIMESTAMP'", :TextField)  == "CURRENT_TIMESTAMP"
  @test norm("\"CURRENT_TIMESTAMP\"", :TextField) == "CURRENT_TIMESTAMP"
  @test norm("CURRENT_TIMESTAMP", :TextField)    == sql_expr("CURRENT_TIMESTAMP")

  # …and through the readers, which is where it would actually cost a user data: the quoted form
  # must still arrive on the field, on both engines.
  pg_model = Test.collect_test_logs() do
    convertSQLToModel(_introspection_row(
      table_name   = "quoted_defaults",
      columns      = [_col("id", "bigint"; notnull = true),
                      _col("kept",    "text"; default = "'now()'::text"),
                      _col("dropped", "text"; default = "now()")],
      primary_keys = ["id"]))
  end[2]
  @test pg_model.fields["kept"].default    == "now()"
  @test pg_model.fields["dropped"].default === nothing

  sl_model = mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "quoted_defaults.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "quoted_defaults" (
          "id" INTEGER PRIMARY KEY,
          "kept" TEXT DEFAULT 'CURRENT_TIMESTAMP',
          "dropped" TEXT DEFAULT CURRENT_TIMESTAMP)""")
      models = Test.collect_test_logs() do
        convert_schema_to_models(pool; include_table = ["quoted_defaults"])
      end[2]
      only(m for m in models if lowercase(string(m.name)) == "quoted_defaults")
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
  @test sl_model.fields["kept"].default    == "CURRENT_TIMESTAMP"
  @test sl_model.fields["dropped"].default === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# The FK arms are unchanged by the classifier
# `_fk_default_or_warn` coerces through `format2int64`, so no expression ever survived it — the
# `catch` already warned and dropped `nextval(...)` (asserted in the #292 block above). The tag it
# now receives is neither an `Integer` nor something `format2int64` accepts, so this pins that the
# routing added for it is behaviour-preserving rather than a second, differently-worded drop.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the classifier does not change what the FK arms do (#475)" begin
  fk = PormG.Migrations._fk_default_or_warn

  # The tagged form and the raw form reach the same answer, each with exactly one warning.
  for val in (sql_expr("nextval('s'::regclass)"), "nextval('s'::regclass)")
    logs, got = Test.collect_test_logs() do
      fk(val, "race_result", "driverid")
    end
    @test got === nothing
    warns = filter(l -> l.level == Logging.Warn &&
                        occursin("could not be represented", l.message), logs)
    @test length(warns) == 1
    @test Dict(first(warns).kwargs)[:column] == "driverid"
    # The expression text survives into the warning, so the column is findable in the DDL.
    @test Dict(first(warns).kwargs)[:default] == "nextval('s'::regclass)"
  end

  # …and a representable FK default is still converted, not swept up by the new arm.
  @test @test_logs(min_level = Logging.Warn, fk("7", "race_result", "driverid")) == 7
  @test @test_logs(min_level = Logging.Warn, fk(7, "race_result", "driverid")) == 7
  @test fk(nothing, "race_result", "driverid") === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# The newly-dropped textual shape converges, and the declared-literal shape is the upgrade hazard
# Two halves of one question, and they must be asserted together.
#
# POSITIVE: a live `TEXT DEFAULT CURRENT_TIMESTAMP` now reads back as "no default", so a model
# declaring a plain `TextField()` must plan NOTHING. Before #475 the live side read back the
# STRING "CURRENT_TIMESTAMP", which differed from the declared `nothing` and made `makemigrations`
# propose an alteration on every run — a full table rebuild on SQLite. That churn is the #2
# consequence in the issue, and this is what proves it is gone rather than merely relocated.
#
# NEGATIVE: the same fix breaks the app that FOLLOWED the old advice and declared a default
# matching the expression to make the churn stop. The declared literal must be what the live side
# USED to read back — `"now()"` for a `text DEFAULT now()` column — or the fixture proves nothing:
# a declared value that never equalled the old live value never converged, so the plan it produces
# is the same before and after the fix and the assertion below would pass on unfixed code too.
# With the values matched, the pre-fix planner saw `"now()" == "now()"` and proposed NOTHING, while
# the post-fix one sees `"now()"` against `nothing` and proposes `SET DEFAULT 'now()'` — a quoted
# literal written over the database's real expression default, after which every INSERT stores
# those five characters. Pinned rather than merely documented, because the UPGRADING entry claims
# it and a claim about the planner that no test holds is a claim that rots.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a dropped textual expression default converges, but a declared literal does not (#475)" begin
  live = convertSQLToModel(_introspection_row(
    table_name   = "lap_note",
    columns      = [_col("id", "bigint"; notnull = true, identity = "d"),
                    _col("note", "text"; default = "now()"),
                    _col("ok", "integer"; default = "5")],
    primary_keys = ["id"]))

  # The precondition, restated locally so a failure here is not mistaken for a planner bug.
  @test live.fields["note"].default === nothing

  settings = PormG.Configuration.Settings()
  settings.change_db = true

  # POSITIVE — what a user should declare for such a column: nothing at all.
  declared = PormG.Models.Model("lap_note",
      id   = PormG.Models.IDField(),
      note = PormG.Models.TextField(null = true),
      ok   = PormG.Models.IntegerField(default = 5, null = true))

  for conn in (IntrospectionGuardMockSQLite(), IntrospectionGuardMockPg())
    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :lap_note => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
    plan = @test_logs min_level = Logging.Warn PormG.Migrations.get_migration_plan(
        PormGModel[live], current_schema, conn, settings)
    @test !haskey(plan, :lap_note) || isempty(plan[:lap_note])
  end

  # NEGATIVE — the upgrade hazard. PostgreSQL only, for the same reason as the #472 control above:
  # a real difference sends SQLite down `_sqlite_rebuild_preserving_indexes`, which queries the
  # connection for secondary indexes and so needs a live database rather than a mock.
  matched = PormG.Models.Model("lap_note",
      id   = PormG.Models.IDField(),
      note = PormG.Models.TextField(null = true, default = "now()"),
      ok   = PormG.Models.IntegerField(default = 5, null = true))

  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :lap_note => Dict{Symbol, Union{Bool, PormGModel}}(:model => matched, :exist => false))
  plan = PormG.Migrations.get_migration_plan(
      PormGModel[live], current_schema, IntrospectionGuardMockPg(), settings)

  @test haskey(plan, :lap_note) && !isempty(plan[:lap_note])
  # The exact statement the UPGRADING entry warns about: a quoted literal written over a live
  # expression default. `SET DEFAULT` is not a destructive pattern, so nothing gates it.
  @test any(occursin("SET DEFAULT 'now()'", sql) for sql in values(plan[:lap_note]))

  # …and the discriminator, spelled out: reconstruct what the PRE-fix reader produced for this
  # column — the retained literal `"now()"` — and confirm the SAME declared model planned NOTHING
  # against it. This is what makes the assertion above evidence of a behaviour CHANGE rather than
  # of a difference that was always there.
  pre_fix_live = PormG.Models.Model("lap_note",
      id   = PormG.Models.IDField(auto_increment = true),
      note = PormG.Models.TextField(null = true, default = "now()"),
      ok   = PormG.Models.IntegerField(default = 5, null = true))
  pre_fix_plan = PormG.Migrations.get_migration_plan(
      PormGModel[pre_fix_live],
      Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :lap_note => Dict{Symbol, Union{Bool, PormGModel}}(:model => matched, :exist => false)),
      IntrospectionGuardMockPg(), settings)
  @test !haskey(pre_fix_plan, :lap_note) || isempty(pre_fix_plan[:lap_note])
end

# ─────────────────────────────────────────────────────────────────────────────
# A concatenation is not a literal, on EITHER engine
# Found in review. `_normalize_sqlite_default` tested `startswith(s, "'") && endswith(s, "'")`,
# which is true of `'a' || 'b'` — a concatenation of TWO literals whose first and last characters
# merely happen to be quotes. It unquoted to the mangled `a' || 'b`, and a textual column KEPT it,
# so `inspectdb` wrote `default="a' || 'b"` and re-rendering produced `DEFAULT 'a'' || ''b'`.
# PostgreSQL has used a balanced predicate since #455, so this was also a live PG/SQLite divergence
# on exactly the shape #475 exists to make the engines agree on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a quoted concatenation is an expression, not a mangled literal (#475)" begin
  norm     = PormG.Migrations._normalize_sqlite_default
  clean_pg = PormG.Migrations._pg_clean_default

  for concat in ("'a' || 'b'", "'a'||'b'", "'Ferrari, ' || 'Scuderia'")
    got = norm(concat, :TextField)
    @test got isa PormG.Migrations._ExpressionDefault
    # Unmangled: the text is carried whole, quotes and all.
    @test got.sql == concat
    # THE cross-engine assertion. This is what was divergent.
    @test got == clean_pg(concat)
  end

  # …and a genuine single literal is still unquoted, including one whose CONTENT is a quote — the
  # case that makes a naive `startswith`/`endswith` test look adequate.
  @test norm("'Ferrari'", :TextField) == "Ferrari"
  @test norm("'it''s'", :TextField) == "it's"
  @test norm("''", :TextField) == ""
  @test norm("\"it\"\"s\"", :TextField) == "it\"s"
  for lit in ("'Ferrari'", "'it''s'", "''")
    @test norm(lit, :TextField) isa String
    @test norm(lit, :TextField) == clean_pg(lit)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A BLOB column's expression default is reported, not swallowed
# Found in review. The `:BinaryField` branch returns `_sqlite_blob_literal_bytes`, i.e. `nothing`
# for anything that is not `X'…'` — and it runs BEFORE the classification, so
# `BLOB DEFAULT (randomblob(16))` was dropped in total silence while PostgreSQL's `bytea` twin
# warned. That is a hole in the "uniform on every column type" rule this issue establishes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a SQLite BLOB expression default is classified, not silently swallowed (#475)" begin
  norm = PormG.Migrations._normalize_sqlite_default

  @test norm("(randomblob(16))", :BinaryField) == sql_expr("randomblob(16)")
  @test norm("randomblob(16)", :BinaryField) == sql_expr("randomblob(16)")

  # #296's contract, deliberately UNCHANGED: a real blob literal decodes to bytes, and a LITERAL
  # that simply is not valid blob syntax still degrades to "no default" with no warning. It is a
  # literal the field type refuses, not an expression — a different axis, and the one #296 decided.
  @test norm("X'0102'", :BinaryField) == UInt8[0x01, 0x02]
  @test norm("x'0102'", :BinaryField) == UInt8[0x01, 0x02]
  @test norm("X''", :BinaryField) == UInt8[]
  @test norm("'not a blob'", :BinaryField) === nothing
  @test norm("5", :BinaryField) === nothing
  # …including an `X'…'`-SHAPED token that is MALFORMED. Found in review: the first version of this
  # fix carved out only quoted literals, so odd-length and non-hex blob literals fell through to
  # the expression path and were reported with the reason "the DEFAULT is a SQL expression" — a
  # false diagnosis in a warning the user cannot check.
  @test norm("X'010'", :BinaryField) === nothing     # odd-length hex
  @test norm("X'0G'", :BinaryField) === nothing      # not hex

  # …and the shape that separates a malformed LITERAL from an EXPRESSION that merely starts and
  # ends like one. Found in review, after the first draft of the line above was written as
  # `startswith(s, "X'") && endswith(s, "'")` — the same naive predicate this whole issue exists to
  # remove — which swallowed this concatenation in silence.
  @test norm("X'0102' || X'03'", :BinaryField) == sql_expr("X'0102' || X'03'")
  @test norm("x'0102' || 'a'", :BinaryField) == sql_expr("x'0102' || 'a'")

  # …and end to end: the column imports without the default, and the drop is REPORTED.
  logs, model = Test.collect_test_logs() do
    convertSQLToModel("""CREATE TABLE "sl_blob" (
        "id" INTEGER PRIMARY KEY,
        "payload" BLOB DEFAULT (randomblob(16)))""")
  end
  @test model.fields["payload"].default === nothing
  warns = filter(l -> l.level == Logging.Warn &&
                      occursin("could not be represented", l.message), logs)
  @test length(warns) == 1
  @test Dict(first(warns).kwargs)[:column] == "payload"
end

# ─────────────────────────────────────────────────────────────────────────────
# A non-ASCII default does not abort the schema read
# Found in review. The SQLite cleaner unquoted with `stripped[2:end-1]` — BYTE offsets — so `end-1`
# landed on a UTF-8 continuation byte whenever the character before the closing quote was multibyte.
# `DEFAULT 'São José'` raised `StringIndexError` from inside the cleaner and aborted the WHOLE
# `convert_schema_to_models` read: #472's failure mode exactly, reachable from an ordinary column,
# and newly reachable through `check()` — the read-only command this issue tells users to run
# BEFORE upgrading. PostgreSQL always used the `nextind`/`prevind` form and never had it.
#
# `'Räikkönen'` is the near-miss that made this survive review-by-reading: it ends in an ASCII `n`,
# so the byte slice happens to land correctly.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a non-ASCII default is read, not a StringIndexError (#475)" begin
  norm     = PormG.Migrations._normalize_sqlite_default
  clean_pg = PormG.Migrations._pg_clean_default

  for (lit, want) in ("'São José'" => "São José", "'café'" => "café", "'日本語'" => "日本語",
                      "'Räikkönen'" => "Räikkönen", "'é'" => "é",
                      "'it''s café'" => "it's café")
    @test norm(lit, :TextField) == want
    @test norm(lit, :TextField) == clean_pg(lit * "::text")   # and the engines agree
  end
  @test norm("\"São José\"", :TextField) == "São José"       # the double-quoted branch too

  # End to end through the live SQLite reader: the read completes and the value arrives intact.
  model = mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "utf8.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "driver" (
          "id" INTEGER PRIMARY KEY,
          "hometown" TEXT DEFAULT 'São José',
          "team" TEXT DEFAULT 'Ferrari')""")
      models = convert_schema_to_models(pool; include_table = ["driver"])
      only(m for m in models if lowercase(string(m.name)) == "driver")
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
  @test model.fields["hometown"].default == "São José"
  @test model.fields["team"].default == "Ferrari"
end
