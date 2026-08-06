"""
Unit coverage for the introspection primary-key attribute guards
(`convertSQLToModel(row::DataFrameRow)`, the PostgreSQL path).

A primary-key column is mapped to an `IDField`, which has **no** `max_length`/`max_digits`
field. Before the guard, a natural primary key (`VARCHAR(n) PRIMARY KEY`) or a numeric primary
key (`NUMERIC(p,s) PRIMARY KEY`) parsed a `max_length`/`max_digits` and then tried to assign it
onto the `IDField`, raising a `FieldError` that crashed the whole schema import.

`convertSQLToModel(row)` takes the introspected table metadata as a single `DataFrameRow`, so
this is fully hermetic — no live database. The fix adds
`&& hasfield(typeof(field), :max_length)` / `:max_digits`, so the import must succeed and the
PK must map to an `IDField`, while a normal sized column still keeps its `max_length`.
"""

using Test
using DataFrames
using PormG
using PormG.Migrations: convertSQLToModel

# One-row "introspection result" carrying the columns convertSQLToModel(row) reads. The optional
# FK/index columns default to `missing`, matching a table that has none. The FK keywords let a test
# describe a foreign key without a live database: `delete_rules` carries the raw
# `pg_constraint.confdeltype` codes, comma-joined in the same order as `foreign_keys` (#292).
function _introspection_row(; table_name, columns, primary_keys,
                              foreign_keys = missing, foreign_tables = missing,
                              referenced_primary_keys = missing, delete_rules = missing)
  df = DataFrame(
    table_name              = [table_name],
    columns                 = [columns],
    primary_keys            = [primary_keys],
    foreign_keys            = [foreign_keys],
    foreign_tables          = [foreign_tables],
    referenced_primary_keys = [referenced_primary_keys],
    delete_rules            = [delete_rules],
    index_columns           = [missing],
    index_names             = [missing],
  )
  return df[1, :]
end

# The same row WITHOUT a `delete_rules` column at all — the shape a schema query produced before
# #292 added it. Used to prove the reader degrades instead of throwing on a missing column.
function _introspection_row_without_delete_rules(; table_name, columns, primary_keys,
                                                   foreign_keys, foreign_tables,
                                                   referenced_primary_keys)
  df = DataFrame(
    table_name              = [table_name],
    columns                 = [columns],
    primary_keys            = [primary_keys],
    foreign_keys            = [foreign_keys],
    foreign_tables          = [foreign_tables],
    referenced_primary_keys = [referenced_primary_keys],
    index_columns           = [missing],
    index_names             = [missing],
  )
  return df[1, :]
end

@testset "Introspection PK attribute guards (convertSQLToModel)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. VARCHAR primary key + a normal sized column. Pre-fix: assigning max_length
  #    onto the IDField threw FieldError. Post-fix: PK → IDField (no max_length),
  #    while the normal column still keeps its max_length (guard didn't over-suppress).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "VARCHAR(n) PRIMARY KEY does not crash; PK maps to IDField" begin
    row = _introspection_row(
      table_name   = "natural_key_tbl",
      columns      = "code varchar(20) NOT NULL, name varchar(100)",
      primary_keys = "code",
    )
    model = convertSQLToModel(row)   # must not throw

    @test model.fields["code"] isa PormG.Models.sIDField
    @test model.fields["code"].type == "BIGINT"
    @test !hasfield(typeof(model.fields["code"]), :max_length)   # the attribute the old code tried to set
    @test model.fields["name"].max_length == 100                 # normal column unaffected
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. NUMERIC(p,s) primary key. Pre-fix: assigning max_digits onto the IDField threw.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "NUMERIC(p,s) PRIMARY KEY does not crash (max_digits guard)" begin
    row = _introspection_row(
      table_name   = "numeric_key_tbl",
      columns      = "id numeric(10,0) NOT NULL",
      primary_keys = "id",
    )
    model = convertSQLToModel(row)   # must not throw

    @test model.fields["id"] isa PormG.Models.sIDField
    @test !hasfield(typeof(model.fields["id"]), :max_digits)
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
      table_name              = "results",
      columns                 = "id bigint NOT NULL, driverid bigint, raceid bigint",
      primary_keys            = "id",
      foreign_keys            = "driverid, raceid",
      foreign_tables          = "drivers, races",
      referenced_primary_keys = "driverid, raceid",
      delete_rules            = "c, n",          # CASCADE, SET NULL — order matches foreign_keys
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
      table_name              = "results",
      columns                 = "id bigint NOT NULL, raceid bigint",
      primary_keys            = "id",
      foreign_keys            = "raceid",
      foreign_tables          = "races",
      referenced_primary_keys = "raceid",
      delete_rules            = "a",
    )
    model = convertSQLToModel(row)
    @test model.fields["raceid"].on_delete === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: a schema-query row with no delete_rules column still converts
  # `delete_rules` is new in #292. A caller holding an older row — or a unit fixture that predates
  # it — must degrade to "no action recorded" rather than raising a KeyError mid-import.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a row without delete_rules degrades instead of throwing" begin
    row = _introspection_row_without_delete_rules(
      table_name              = "results",
      columns                 = "id bigint NOT NULL, raceid bigint",
      primary_keys            = "id",
      foreign_keys            = "raceid",
      foreign_tables          = "races",
      referenced_primary_keys = "raceid",
    )
    model = convertSQLToModel(row)     # must not throw
    @test model.fields["raceid"] isa PormG.Models.sForeignKey
    @test model.fields["raceid"].on_delete === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FK introspection: a SET DEFAULT foreign key carries its default through registration
  # This is the #287/#291 regression in one assertion. `SET_DEFAULT` with no `default` raises
  # `ModelDefinitionError` at `set_models`; before #292 introspection produced exactly that shape
  # and regenerating produced the identical broken file, so there was no way out but a hand edit.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SET DEFAULT FK keeps its default so the model can register" begin
    row = _introspection_row(
      table_name              = "results",
      columns                 = "id bigint NOT NULL, statusid bigint DEFAULT 1",
      primary_keys            = "id",
      foreign_keys            = "statusid",
      foreign_tables          = "status",
      referenced_primary_keys = "statusid",
      delete_rules            = "d",
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
