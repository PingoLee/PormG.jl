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
using PormG
using PormG.Migrations: convertSQLToModel

# One-row "introspection result" carrying the columns convertSQLToModel(row) reads. The optional
# FK/index columns default to `missing`, matching a table that has none. The FK keywords let a test
# describe a foreign key without a live database: `delete_rules` carries the raw
# `pg_constraint.confdeltype` codes, comma-joined in the same order as `foreign_keys` (#292).
function _introspection_row(; table_name, columns, primary_keys,
                              foreign_keys = missing, foreign_tables = missing,
                              referenced_primary_keys = missing, delete_rules = missing,
                              index_columns = missing, index_names = missing)
  df = DataFrame(
    table_name              = [table_name],
    columns                 = [columns],
    primary_keys            = [primary_keys],
    foreign_keys            = [foreign_keys],
    foreign_tables          = [foreign_tables],
    referenced_primary_keys = [referenced_primary_keys],
    delete_rules            = [delete_rules],
    index_columns           = [index_columns],
    index_names             = [index_names],
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
      columns      = "code varchar(20) NOT NULL, name varchar(100)",
      primary_keys = "code",
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
      table_name              = "driver_profile",
      columns                 = "driver_id bigint NOT NULL",
      primary_keys            = "driver_id",
      foreign_keys            = "driver_id",
      foreign_tables          = "driver",
      referenced_primary_keys = "id",
      delete_rules            = "c"))

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
      columns      = "id numeric(10,0) NOT NULL",
      primary_keys = "id",
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
        table_name = "int_key_tbl", columns = "id $t NOT NULL", primary_keys = "id"))
      @test model.fields["id"] isa PormG.Models.sIDField
      @test model.fields["id"].primary_key
    end

    # A LENGTHLESS text key has no field type to become: `TextField` does not accept `primary_key`
    # (its constructor passes a literal `false`), and a bare `CharField` would invent
    # `max_length = 250`. It keeps the IDField fallback, deliberately and documented.
    model = convertSQLToModel(_introspection_row(
      table_name = "text_key_tbl", columns = "id text NOT NULL", primary_keys = "id"))
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
    columns      = "id bigint NOT NULL, slug character varying(120) NOT NULL UNIQUE, " *
                   "token uuid NOT NULL UNIQUE, plain text",
    primary_keys = "id")
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
    columns      = "id bigint NOT NULL, UNIQUE_CODE text, label text DEFAULT 'UNIQUE'",
    primary_keys = "id"))
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
    columns      = "id bigint NOT NULL, canonical_url character varying(500) NOT NULL, " *
                   "short character varying(120), body text",
    primary_keys = "id"))

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
# key, which is built from the `quote_ident`-ed `columns` aggregate and de-quoted on the way in.
# `index_columns`, uniquely among the schema query's identifier aggregates, is `array_agg(a.attname)`
# — RAW — so a mixed-case column (#57) arrives here ALREADY unquoted and the two sides meet in the
# middle. This fixture used to spell it `"mixedCase"`, a shape production never emits, which meant
# the mixed-case path was pinned against the wrong input (#389).
#
# The CTE's own filters (non-unique, non-partial, single-column) run against a live database in
# test/integration/test_migration_bootstrap.jl — nothing here executes SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL db_index is read back off the index map (#325)" begin
  model = convertSQLToModel(_introspection_row(
    table_name    = "db_index_guard",
    columns       = "id bigint NOT NULL, slug character varying(120), plain text, \"mixedCase\" text",
    primary_keys  = "id",
    # What the `indexes` CTE hands back: one entry per indexed column, RAW (`array_agg(a.attname)`,
    # no `quote_ident` — verified against a live catalog), with the `quote_ident`-ed index names
    # aligned positionally.
    index_columns = "slug, mixedCase",
    index_names   = "db_index_guard_slug_idx, db_index_guard_mixedcase_idx"))

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

  # `foreign_tables` is spelled the way the PRODUCTION schema query emits it — the CTE aggregates
  # `quote_ident(cf.relname)`, so a name needing quotes arrives WRAPPED IN `"` while `table_name`
  # comes from a bare `c.relname`. Feeding the unquoted form here would be a dead test: it passes
  # against a reader that never de-quotes, while the live path stores `"\"driver profile\""` as
  # `to_table`, matches no imported model, and skips the binding rewrite entirely.
  @testset "the PostgreSQL path (convertSQLToModel(::DataFrameRow))" begin
    model = convertSQLToModel(_introspection_row(
      table_name              = "pit_stop",
      columns                 = "id bigint NOT NULL, plain_id bigint, spaced_id bigint",
      primary_keys            = "id",
      foreign_keys            = "plain_id, spaced_id",
      foreign_tables          = "driver_profile, \"driver profile\"",
      referenced_primary_keys = "id, id",
      delete_rules            = "a, a"))

    # `quote_ident` leaves an already-legal lowercase name alone, so this half is unquoted input.
    @test model.fields["plain_id"].to       == "Driver_profile"
    @test model.fields["plain_id"].to_table == "driver_profile"

    # THE mutation gate for the de-quoting: without it `to_table` keeps its `"` and no longer equals
    # any `model.name`, so `_plan_inspectdb_bindings!` cannot find the target.
    @test model.fields["spaced_id"].to       == "Driver_profile"
    @test model.fields["spaced_id"].to_table == "driver profile"
  end

  # This reader is the ONLY one that emits a `OneToOneField` (when the FK column is also UNIQUE), so
  # the slot has to exist on `sOneToOneField` too — a fix applied to `sForeignKey` alone would leave
  # every one-to-one relation on PostgreSQL unrewritable, and `to_table` would be a MethodError.
  @testset "a UNIQUE foreign key becomes a OneToOneField and still carries both" begin
    model = convertSQLToModel(_introspection_row(
      table_name              = "driver_seat",
      columns                 = "id bigint NOT NULL, profile_id bigint UNIQUE",
      primary_keys            = "id",
      foreign_keys            = "profile_id",
      foreign_tables          = "\"driver profile\"",   # quote_ident form, as the live query emits
      referenced_primary_keys = "id",
      delete_rules            = "a"))

    @test model.fields["profile_id"] isa PormG.Models.sOneToOneField
    @test model.fields["profile_id"].to       == "Driver_profile"
    @test model.fields["profile_id"].to_table == "driver profile"
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #389: FK metadata arrives `quote_ident`-quoted, and every half must be de-quoted together
#
# The PostgreSQL schema query aggregates `fk_cols`, `fk_tables` and `referenced_primary_keys`
# through `quote_ident`, so a mixed-case identifier arrives with the `"` characters as part of the
# Julia string. #360 (PR #386) de-quoted the TABLE half; this is the rest of it.
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
# Either way it is wrong — de-quoting at the source, which is what this testset pins, is the fix.)
#
# `fk_cols` and `col_name` move in the SAME change on purpose: `fk_map`'s keys come from `fk_cols`
# and are looked up with `col_name`, so normalizing one side alone would break FK detection for
# every mixed-case column. Both are covered below — the second testset is that mutation gate.
#
# Fully hermetic: `convertSQLToModel(::DataFrameRow)` takes the metadata and nothing else.
# The live-database half is test/integration/test_importers_introspection.jl.
# ─────────────────────────────────────────────────────────────────────────────
# `add_foreign_key` dispatches on the abstract backend marker and never touches connection state,
# so a bare marker struct is a sufficient `conn`. Declared at top level, like every other mock in
# test/unit/ (a struct inside a `@testset` body parses, but is not the house pattern).
struct MockPg389 <: PormG.PormGPostgres end

@testset "quote_ident-quoted FK metadata is de-quoted (#389)" begin
  @testset "a mixed-case parent primary key lands unquoted on pk_field" begin
    # Exactly what the production query emits for a parent keyed on `"Id"`: quote_ident quotes the
    # mixed-case pk and the mixed-case table, and leaves the all-lowercase child column alone.
    model = convertSQLToModel(_introspection_row(
      table_name              = "pit_stop",
      columns                 = "id bigint NOT NULL, parent_id bigint",
      primary_keys            = "id",
      foreign_keys            = "parent_id",
      foreign_tables          = "\"MixedParent\"",
      referenced_primary_keys = "\"Id\"",
      delete_rules            = "a"))

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
      table_name              = "pit_stop",
      columns                 = "id bigint NOT NULL, parent_id bigint",
      primary_keys            = "id",
      foreign_keys            = "parent_id",
      foreign_tables          = "\"MixedParent\"",
      referenced_primary_keys = "\"Id\"",
      delete_rules            = "a"))

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
      table_name              = "pit_stop",
      columns                 = "id bigint NOT NULL, parent_id bigint",
      primary_keys            = "id",
      foreign_keys            = "parent_id",
      foreign_tables          = "\"MixedParent\"",
      referenced_primary_keys = "\"Id\"",
      delete_rules            = "a")).fields["parent_id"]

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
      table_name              = "pit_stop",
      columns                 = "id bigint NOT NULL, \"ParentId\" bigint",
      primary_keys            = "id",
      foreign_keys            = "\"ParentId\"",
      foreign_tables          = "\"MixedParent\"",
      referenced_primary_keys = "\"Id\"",
      delete_rules            = "a"))

    # `fields_dict` is keyed de-quoted, so this is the name the rest of PormG sees.
    @test haskey(model.fields, "ParentId")
    @test model.fields["ParentId"] isa PormG.Models.sForeignKey
    @test model.fields["ParentId"].pk_field == "Id"
    @test model.fields["ParentId"].to_table == "MixedParent"
  end

  @testset "a mixed-case PRIMARY KEY column is still detected as the key" begin
    # `pk_set` comes from `quote_ident(a.attname)` too, and is compared against `col_name`. The two
    # used to agree only because BOTH were quoted; normalizing `col_name` without normalizing
    # `pk_set` would leave the table keyless, which no other assertion in this file would catch.
    model = convertSQLToModel(_introspection_row(
      table_name   = "mixed_key",
      columns      = "\"Id\" bigint NOT NULL, label character varying(50)",
      primary_keys = "\"Id\""))

    @test haskey(model.fields, "Id")
    @test model.fields["Id"] isa PormG.Models.sIDField
    @test model.fields["Id"].primary_key
  end

  @testset "an embedded quote round-trips instead of being silently deleted" begin
    # `quote_ident` DOUBLES an embedded `"`, so `Say"Hi` — a legal PostgreSQL column name — comes
    # back as `"Say""Hi"`. The old `replace(s, "\"" => "")` deleted every quote and produced
    # `SayHi`, a column that does not exist: `makemigrations` then proposed `ADD COLUMN "SayHi"`
    # alongside a `DROP` of the real one, on every run, silently. `_unquote_ident` undoes the
    # doubling instead, so the name survives: the existing table converges, and `Model_to_str`
    # regenerates it as a legal binding plus `db_column="Say\"Hi"` — a rename of the BINDING, not
    # of the column. As of #394 the name is usable end to end as well: `Dialect.create_table`
    # escapes a column identifier the same way it has escaped `db_table` since #388, and the query
    # path escapes rather than validates it (`safe_column_identifier`). Both halves are asserted in
    # `test/unit/test_identifier_quoting.jl`; what this testset pins is the narrower and still
    # separate claim that introspection round-trips the spelling INTACT.
    model = convertSQLToModel(_introspection_row(
      table_name              = "odd_names",
      columns                 = "id bigint NOT NULL, \"Say\"\"Hi\" bigint",
      primary_keys            = "id",
      foreign_keys            = "\"Say\"\"Hi\"",
      foreign_tables          = "\"Par\"\"ent\"",
      referenced_primary_keys = "\"Sa\"\"y\"",
      delete_rules            = "a"))

    @test haskey(model.fields, "Say\"Hi")
    @test model.fields["Say\"Hi"].pk_field == "Sa\"y"
    @test model.fields["Say\"Hi"].to_table == "Par\"ent"
  end

  @testset "the RAW index aggregate is not run through the quote_ident inverse" begin
    # The mutation gate for the one identifier aggregate that is NOT `quote_ident`-ed:
    # `indexes.index_columns` is a bare `array_agg(a.attname)`. Undoing a doubling that was never
    # applied corrupts exactly one name class — a column whose real name IS quoted.
    #
    # Real name `"x"` (three characters). `columns` carries `quote_ident("\"x\"")` = `"""x"""`,
    # `index_columns` carries the raw `"x"`. De-quote both and they still agree; de-quote only the
    # `columns` side, as it must be, and take the raw side verbatim, and they agree too. Run
    # `_unquote_ident` on BOTH and the index key collapses to `x` while the field key stays `"x"`
    # — the #325 db_index churn, reintroduced for that name class by the #389 fix itself.
    model = convertSQLToModel(_introspection_row(
      table_name    = "d1_probe",
      columns       = "id bigint NOT NULL, \"\"\"x\"\"\" bigint",
      primary_keys  = "id",
      index_columns = "\"x\"",
      index_names   = "d1_probe_x_idx"))

    @test haskey(model.fields, "\"x\"")
    @test model.fields["\"x\""].db_index
    @test model.cache["index"]["\"x\""] == "d1_probe_x_idx"
  end

  @testset "the all-lowercase case is unchanged (control)" begin
    # quote_ident leaves a legal lowercase identifier alone, so this is the shape every existing
    # fixture exercises. It is a NO-REGRESSION CONTROL for the common path, not a mutation gate:
    # a lowercase name carries no quotes, so no partial normalization can make it fail.
    model = convertSQLToModel(_introspection_row(
      table_name              = "results",
      columns                 = "id bigint NOT NULL, driverid bigint",
      primary_keys            = "id",
      foreign_keys            = "driverid",
      foreign_tables          = "drivers",
      referenced_primary_keys = "driverid",
      delete_rules            = "c"))

    @test model.fields["driverid"] isa PormG.Models.sForeignKey
    @test model.fields["driverid"].pk_field == "driverid"
    @test model.fields["driverid"].to_table == "drivers"
    @test model.fields["driverid"].on_delete === PormG.Models.CASCADE
  end
end
