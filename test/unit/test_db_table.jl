"""
Unit coverage for the model-level `db_table` option (#59).

`db_table` makes the physical SQL table name differ from the model's declared (logical) name,
Django `Meta.db_table`-style: `Model("driver_races", db_table = "Driver_Races", …)` keeps model
identity `driver_races` but renders the table `"Driver_Races"` in DDL, SELECT/INSERT/UPDATE/DELETE,
JOINs, foreign-key `REFERENCES` targets, and migration diffing. It is the table-level sibling of
`db_column` (#50), and its value is carried **verbatim** — no case fold, no underscore strip.

The default (table == model name) is unchanged, so existing schemas are unaffected (non-breaking).

Two things this file deliberately pins beyond the happy path:

  * the resolution seam is ONE function (`model_table_name`), so a renderer that forgets it shows up
    as a spelling mismatch here rather than as a wrong-table write in production; and
  * `ManyToManyField(db_table = …)`, which pre-dates this option and used to silently lowercase its
    argument, now follows the same case-preserving policy — the two seams express the same intent.

All assertions render via mock PostgreSQL/SQLite connections (no live database required).
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, ForeignKey, ManyToManyField,
                    UniqueConstraint, model_table_name, model_has_db_table, fk_target_table,
                    Model_to_str
using PormG.QueryBuilder: inspect_query

# Dedicated mock connections + config key — uniquely named so they never clash with other unit
# files' mock structs when runtests.jl includes them all into the same module.
struct MockPostgresDbTable <: PormG.PormGPostgres end
struct MockSQLiteDbTable <: PormG.PormGSQLite end
PormG.config["db_table_mock"] = PormG.Configuration.Settings(
  connections = MockPostgresDbTable(),
  change_data = true,
)

# The headline fixture: logical name `dbt_driver_scratch`, physical table `Dbt_Driver_Scratch`.
# The two differ in case ONLY, which is the case that used to be unrepresentable — a positional
# mixed-case name is rejected (#300) and there was nowhere else to put the physical spelling.
DbtDriver = Model("dbt_driver_scratch",
  db_table = "Dbt_Driver_Scratch",
  id      = IDField(),
  surname = CharField(),
)
DbtDriver.connect_key = "db_table_mock"

# A child whose FK targets the db_table-mapped parent — exercises fk_target_table.
DbtResult = Model("dbt_result_scratch",
  id       = IDField(),
  driverid = ForeignKey(DbtDriver, pk_field = "id", on_delete = "CASCADE"),
  points   = IntegerField(),
)
DbtResult.connect_key = "db_table_mock"

# Control: no db_table at all. Every assertion about this model is an assertion that the option is
# inert when unused.
DbtPlain = Model("dbt_plain_scratch",
  id   = IDField(),
  nome = CharField(),
)
DbtPlain.connect_key = "db_table_mock"

@testset "db_table authoritative (#59)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # model_table_name: db_table when set & non-empty, else model.name. The single seam every
  # renderer resolves through — if this is wrong, everything below is wrong in the same direction.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "model_table_name / model_has_db_table" begin
    @test model_table_name(DbtDriver) == "Dbt_Driver_Scratch"
    @test model_table_name(DbtPlain)  == "dbt_plain_scratch"   # falls back to the logical name
    @test model_has_db_table(DbtDriver)
    @test !model_has_db_table(DbtPlain)

    # The logical name is untouched — db_table is an override, not a rename.
    @test DbtDriver.name == "dbt_driver_scratch"

    # An empty string is "unset", mirroring `field_db_column`'s (#50) treatment of an empty
    # db_column — so it falls back rather than producing a nameless table.
    empty_dbt = Model("dbt_empty_scratch", db_table = "", id = IDField())
    @test empty_dbt.db_table === nothing
    @test model_table_name(empty_dbt) == "dbt_empty_scratch"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Constructor plumbing. `db_table` has to be peeled off BEFORE the `fields...` slurp, exactly
  # like `constraints` — otherwise it reaches the field loop and trips the `isa PormGField` check
  # with a message about field types, which is the confusing failure the peel exists to prevent.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "constructor accepts and validates db_table" begin
    # Both entry points take it: positional-name and no-positional-name (binding-derived) forms.
    @test Model("dbt_named_scratch", db_table = "X_Named", id = IDField()).db_table == "X_Named"
    @test Model(db_table = "X_Anon", id = IDField()).db_table == "X_Anon"

    # It composes with `constraints`, the other model-level option — neither peel eats the other.
    both = Model("dbt_both_scratch", db_table = "X_Both",
      id = IDField(), a = IntegerField(), b = IntegerField(),
      constraints = [UniqueConstraint(fields = ("a", "b"), name = "dbt_both_uniq")],
    )
    @test both.db_table == "X_Both"
    @test haskey(both.cache, "unique_constraints")

    # A non-String is a definition-time error naming the option, not a field-type error.
    err = try
      Model("dbt_bad_scratch", db_table = 42, id = IDField()); nothing
    catch e; e end
    @test err isa PormG.ModelDefinitionError
    @test occursin("db_table", err.msg)

    # NOT normalized: no case fold, no leading-underscore strip, no identifier-shape check. The
    # whole point is to carry an arbitrary legacy spelling the ORM would never generate itself.
    @test Model("dbt_verbatim_scratch", db_table = "MiXeD_CaSe", id = IDField()).db_table == "MiXeD_CaSe"
    @test Model("dbt_underscore_scratch", db_table = "_leading", id = IDField()).db_table == "_leading"

    # …while the POSITIONAL name keeps its own rules (#300/#306) — db_table is the escape valve for
    # a physical name those rules reject, not a way to relax them. Assert on the CAUSE, so this
    # cannot pass because the db_table validator happened to throw for an unrelated reason.
    case_err = try
      Model("Mixed_Case", db_table = "whatever", id = IDField()); nothing
    catch e; e end
    @test case_err isa PormG.ModelDefinitionError
    @test occursin("must be lowercase", case_err.msg)

    # NAME COLLISION. Because `db_table` is peeled off before the `fields...` slurp, a FIELD named
    # `db_table` can no longer be declared that way — it is read as the option and fails the type
    # check. Loud, not silent, which is the point (the older `constraints` peel dies with a raw
    # MethodError instead).
    field_err = try
      Model("dbt_collide_scratch", id = IDField(), db_table = CharField()); nothing
    catch e; e end
    @test field_err isa PormG.ModelDefinitionError
    @test occursin("db_table", field_err.msg)

    # `db_column` is the supported spelling for that column (#317). It is the ONLY one that works:
    # the peel keys on the kwarg NAME however it was spelled, so `var"db_table"` is peeled too, and
    # the old `_db_table` leading-underscore hatch is retired.
    @test_throws PormG.ModelDefinitionError Model("dbt_hatch_scratch", id = IDField(), _db_table = CharField())
    var_err = try
      Model("dbt_var_scratch", id = IDField(), var"db_table" = CharField()); nothing
    catch e; e end
    @test var_err isa PormG.ModelDefinitionError
    @test occursin("'db_table' option", var_err.msg)   # peeled as the OPTION, not read as a field

    escaped = Model("dbt_escape_scratch", id = IDField(), table_kind = CharField(db_column = "db_table"))
    @test PormG.Models.field_db_column(escaped.fields["table_kind"], "table_kind") == "db_table"  # the COLUMN…
    @test escaped.db_table === nothing                # …and the OPTION is untouched
    @test occursin("\"db_table\"", PormG.Dialect.create_table(MockPostgresDbTable(), escaped))

    # A TABLE named `db_table` collides with nothing — the option's name and a table's name live in
    # different places entirely.
    @test model_table_name(Model("db_table", id = IDField())) == "db_table"
    @test model_table_name(Model("dbt_alias_scratch", db_table = "db_table", id = IDField())) == "db_table"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DDL. The table identifier is QUOTED (#59) — it used to be written bare, which was invisible
  # while every name was lowercase but would silently fold a mixed-case db_table on PostgreSQL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "create_table renders db_table on both backends" begin
    for conn in (MockPostgresDbTable(), MockSQLiteDbTable())
      ddl = PormG.Dialect.create_table(conn, DbtDriver)
      @test occursin("CREATE TABLE IF NOT EXISTS \"Dbt_Driver_Scratch\"", ddl)
      @test !occursin("dbt_driver_scratch", ddl)   # the logical name never reaches the DDL

      # Columns are unaffected — db_table is a table-level option and touches nothing below it.
      @test occursin("\"surname\"", ddl)

      # Unset db_table still renders the logical name, quoted the same way.
      plain_ddl = PormG.Dialect.create_table(conn, DbtPlain)
      @test occursin("CREATE TABLE IF NOT EXISTS \"dbt_plain_scratch\"", plain_ddl)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Foreign keys. This is the half that made the mixed-case model name a SILENT bug rather than a
  # loud one before #300: a FK renders its target through a different code path than the one that
  # creates the table, so the two could disagree and bind to a table that merely happens to exist.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "FK REFERENCES resolves to the target's db_table" begin
    @test fk_target_table(DbtResult.fields["driverid"]) == "Dbt_Driver_Scratch"

    # SQLite carries FKs inline in CREATE TABLE — the created table and the referenced one are
    # rendered by the same call here, so this asserts they agree as ONE string.
    child_ddl = PormG.Dialect.create_table(MockSQLiteDbTable(), DbtResult)
    @test occursin("REFERENCES \"Dbt_Driver_Scratch\"(\"id\")", child_ddl)
    @test !occursin("REFERENCES \"dbt_driver_scratch\"", child_ddl)

    # An UNRESOLVED (String) target keeps the pre-existing format_model_name fallback — that is the
    # introspection/pre-set_models shape, where there is no model object to read a db_table off.
    strfk = Model("dbt_strfk_scratch",
      id = IDField(), other = ForeignKey("Some_Model", pk_field = "id", on_delete = "CASCADE"))
    @test fk_target_table(strfk.fields["other"]) == "some_model"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Reads. The base table and any JOIN target both resolve through the same seam.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SELECT and JOIN render db_table" begin
    sel = inspect_query(DbtDriver.objects)[:sql_text]
    @test occursin("FROM \"Dbt_Driver_Scratch\"", sel)
    @test !occursin("dbt_driver_scratch", sel)

    # A JOIN resolves the FK target through the model's owning module, so the fixtures need one.
    # Wiring `_module`/`connect_key` by hand rather than calling `set_models`, which would try to
    # LOAD a connection folder off disk — this file is deliberately DB-free.
    jmod = Module(:DbtJoinScratch)
    Base.eval(jmod, :(using PormG))
    jdriver = Model("dbtj_driver_scratch",
      db_table = "Dbtj_Driver_Scratch", id = IDField(), surname = CharField())
    jresult = Model("dbtj_result_scratch",
      id = IDField(), points = IntegerField(),
      driverid = ForeignKey(jdriver, pk_field = "id", on_delete = "CASCADE"))
    for (bind, m) in ((:Dbtj_driver_scratch, jdriver), (:Dbtj_result_scratch, jresult))
      m._module = jmod
      m.connect_key = "db_table_mock"
      Base.eval(jmod, :(const $bind = $m))
    end

    # Joining CHILD → PARENT puts the PARENT's db_table in the JOIN clause, while the child (which
    # declares none) keeps its logical name — both resolved through the same seam.
    joined = inspect_query(jresult.objects.values("points", "driverid__surname"))[:sql_text]
    @test occursin("\"Dbtj_Driver_Scratch\"", joined)
    @test !occursin("dbtj_driver_scratch", joined)
    @test occursin("\"dbtj_result_scratch\"", joined)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Writes. INSERT/UPDATE go through the query builder; DELETE has its own renderer in deletion.jl
  # which used to write the table BARE and lowercased — a second spelling of the same table in the
  # same statement as its (quoted) subquery.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "INSERT, UPDATE and DELETE render db_table" begin
    ins = DbtDriver.objects.create("id" => 1, "surname" => "Senna", show_query = :sql)
    @test occursin("INSERT INTO \"Dbt_Driver_Scratch\"", ins)

    upd = DbtDriver.objects.filter("id" => 1).update("surname" => "Prost", show_query = :sql)
    @test occursin("UPDATE \"Dbt_Driver_Scratch\"", upd)

    del_raw = DbtDriver.objects.filter("id" => 1).delete(show_query = :dict)
    del = del_raw isa Vector ? first(del_raw) : del_raw
    @test occursin("DELETE FROM \"Dbt_Driver_Scratch\"", del[:sql_text])
    # The outer DELETE and its `IN (...)` subquery are rendered by two different code paths; the
    # whole point of the single seam is that they cannot disagree. Assert the logical name appears
    # NOWHERE in the statement, which is what "they agree" means here.
    @test !occursin("dbt_driver_scratch", del[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Migration diffing. This is the failure with the worst blast radius: the planner matches the
  # LIVE schema (keyed by the physical table name it read from the database) against the DECLARED
  # schema. If the declared side keys on anything else, a db_table model looks like "a table that
  # does not exist yet" plus "a live table nobody declared" — i.e. CREATE + DROP of a live table
  # that did not structurally change at all.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "planner keys the declared schema on the physical table name" begin
    mod = Module(:DbtPlannerScratch)
    Base.eval(mod, :(using PormG))
    # Binding name, logical name and physical name are all DIFFERENT here on purpose — only a
    # db_table-aware key lands on the physical one.
    Base.eval(mod, :(Whatever = PormG.Models.Model("dbt_logical_scratch",
      db_table = "Dbt_Physical_Scratch", id = PormG.Models.IDField())))

    declared = PormG.Migrations.get_all_models(mod)
    @test haskey(declared, Symbol("Dbt_Physical_Scratch"))
    @test !haskey(declared, :dbt_logical_scratch)   # not the logical name
    @test !haskey(declared, :whatever)              # and not the Julia binding

    # A model WITHOUT db_table still keys on its own name, exactly as before.
    Base.eval(mod, :(Plain = PormG.Models.Model("dbt_plain_keyed_scratch", id = PormG.Models.IDField())))
    @test haskey(PormG.Migrations.get_all_models(mod), :dbt_plain_keyed_scratch)

    # …and the RENDERED PLAN must agree with that key. Asserting only on `get_all_models` is not
    # enough: `get_migration_plan` funnels every model through `strip_many_to_many_fields`, which
    # rebuilds `Model_Type` field by field — an omitted slot silently defaults. When `db_table` was
    # dropped there, the plan key was the physical name while the DDL it rendered used the logical
    # one, so `CREATE TABLE` and the FK `REFERENCES` disagreed and a second `makemigrations`
    # proposed dropping the live table. This is the assertion that would have caught it.
    settings = PormG.Configuration.Settings(connections = MockPostgresDbTable(), change_data = true)
    plan = PormG.Migrations.get_migration_plan(
      PormG.PormGModel[], PormG.Migrations.get_all_models(mod), MockPostgresDbTable(), settings;
      interactive = false)
    ddl = join(values(plan[Symbol("Dbt_Physical_Scratch")]), "\n")
    @test occursin("\"Dbt_Physical_Scratch\"", ddl)
    @test !occursin("dbt_logical_scratch", ddl)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # strip_many_to_many_fields rebuilds a Model_Type slot by slot, so anything it forgets is silently
  # lost — and EVERY model on the migration path goes through it. Pinned directly, because the
  # symptom (a plan that creates the wrong table) is several layers away from the cause.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "strip_many_to_many_fields carries db_table" begin
    stripped = PormG.Models.strip_many_to_many_fields(DbtDriver)
    @test model_table_name(stripped) == "Dbt_Driver_Scratch"
    @test stripped.name == "dbt_driver_scratch"   # …and the logical name is still intact
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Two renderers reach a model's table through paths the forward-FK JOIN does not: a REVERSE
  # relation (which stores only the LOGICAL name in `related_objects`, so the resolved model is the
  # sole source of a db_table) and an `Exists()` subquery (its own FROM builder). Both were missed
  # on the first pass and are asserted here with the db_table on the model being *reached*.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "reverse joins and Exists() subqueries render db_table" begin
    rmod = Module(:DbtReverseScratch)
    Base.eval(rmod, :(using PormG))
    rparent = Model("dbtr_parent_scratch", id = IDField(), nome = CharField())
    # The CHILD is the one carrying db_table here — it is the table a reverse traversal reaches.
    rchild = Model("dbtr_child_scratch", db_table = "Dbtr_Child_Legacy",
      id = IDField(), note = CharField(),
      parentid = ForeignKey(rparent, pk_field = "id", on_delete = "CASCADE", related_name = "kids"))
    for (bind, m) in ((:Dbtr_parent_scratch, rparent), (:Dbtr_child_scratch, rchild))
      m._module = rmod
      m.connect_key = "db_table_mock"
      Base.eval(rmod, :(const $bind = $m))
    end
    # The reverse accessor `set_models` would install. `model_name` is the child's LOGICAL name —
    # which is precisely why the reverse renderer must consult `model_resolved` for a db_table, and
    # (since #343) why `binding` is stored rather than respelled from that name.
    rparent.related_objects["kids"] = PormG.Models.ReverseRelation(
      fk_field = :parentid, target_pk = :id, model_name = :dbtr_child_scratch,
      binding = :Dbtr_child_scratch, model_resolved = rchild)

    rev = inspect_query(rparent.objects.values("nome", "kids__note"))[:sql_text]
    @test occursin("\"Dbtr_Child_Legacy\"", rev)
    @test !occursin("\"dbtr_child_scratch\"", rev)

    ex = inspect_query(rparent.objects.filter(
      PormG.QueryBuilder.Exists(rchild.objects.filter("note" => "x"))))[:sql_text]
    @test occursin("\"Dbtr_Child_Legacy\"", ex)
    @test !occursin("\"dbtr_child_scratch\"", ex)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Round-trip through the generated model file. `inspectdb` and the Django importer write a model
  # file that must re-declare the SAME physical table when it is loaded back.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Model_to_str round-trips db_table" begin
    settings = PormG.Configuration.Settings(connections = MockPostgresDbTable(), change_data = true)

    generated = Model_to_str(DbtDriver, settings)
    @test occursin("db_table = \"Dbt_Driver_Scratch\"", generated)
    @test occursin("Models.Model(\"dbt_driver_scratch\"", generated)   # logical name stays positional

    # ACTUALLY round-trip it, rather than string-matching the text: evaluating the generated
    # declaration must produce a model resolving to the SAME physical table. That is the property
    # the testset name claims, and string assertions alone cannot establish it.
    rmod = Module(:DbtRoundTripScratch)
    Base.eval(rmod, :(using PormG))
    Base.eval(rmod, :(const Models = PormG.Models))
    reloaded = Base.eval(rmod, Meta.parse(generated))
    @test model_table_name(reloaded) == "Dbt_Driver_Scratch"
    @test reloaded.name == "dbt_driver_scratch"

    # No db_table declared → no db_table emitted. A redundant override would be noise in every
    # generated file and would freeze a name the user never pinned.
    @test !occursin("db_table", Model_to_str(DbtPlain, settings))

    # An introspected LEADING-UNDERSCORE table (#306 rejects that spelling positionally): the name is
    # stripped for the positional slot and pinned as db_table, so the file both LOADS and addresses
    # the right table. Before, it generated `Model("_order", …)` — which threw on reload.
    underscore_tbl = Model("_dbt_order_scratch", Dict{String, PormG.PormGField}("id" => IDField()))
    ugen = Model_to_str(underscore_tbl, settings; name_is_physical_table = true)
    @test occursin("db_table = \"_dbt_order_scratch\"", ugen)
    ureloaded = Base.eval(rmod, Meta.parse(ugen))
    @test model_table_name(ureloaded) == "_dbt_order_scratch"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `db_table` is an IDENTIFIER, so it is quoted rather than bound as a parameter — and it is
  # deliberately not shape-validated, so an embedded `"` must be escaped or it closes the quoted
  # identifier early and the rest of the value becomes SQL. Asserted across every DDL renderer that
  # writes a table name, since escaping at one site and not the next is the shape this can regress to.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an embedded quote in db_table cannot break out of the identifier" begin
    evil = "x\" (id int); DROP TABLE drivers; --"
    m = Model("dbt_evil_scratch", db_table = evil, id = IDField())
    tbl = PormG.Models.model_table_name(m)
    # These renderers declare `table_name::Union{String,Symbol}` and the MIGRATION path reaches them
    # with a Symbol (the planner keys its plan by one) while every unit fixture passed a String — so
    # a String-only escape helper compiled fine and blew up only under a live migration. Both types
    # are exercised here for that reason.
    for conn in (MockPostgresDbTable(), MockSQLiteDbTable()), t in (tbl, Symbol(tbl))
      stmts = String[
        PormG.Dialect.create_table(conn, m),
        PormG.Dialect.drop_table(conn, t),
        PormG.Dialect.add_field(conn, t, "c", CharField()),
        PormG.Dialect.drop_field(conn, t, "c"),
        PormG.Dialect.rename_field(conn, t, "c", "d"),
        PormG.Dialect.rename_table(conn, tbl, "z"),
      ]
      for sql in stmts
        # The `"` that would have terminated the identifier is DOUBLED, so the payload stays inside
        # it as data rather than becoming statements.
        @test occursin("x\"\" (id int); DROP TABLE drivers; --", sql)
        # …and the un-doubled form — the one that would close the identifier and let `DROP TABLE
        # drivers` execute — appears nowhere. `x" (` can only occur if a renderer skipped escaping.
        @test !occursin("x\" (", sql)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ManyToManyField(db_table = …) predates this option and applied the OPPOSITE policy: it ran the
  # value through `format_model_name`, silently lowercasing it (and, until #317 retired that strip,
  # removing a leading underscore too). Same user intent — "this table is called X" — so it now
  # behaves the same way.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "ManyToManyField db_table preserves case too" begin
    m2m = ManyToManyField("dbt_driver_scratch", db_table = "Dbt_Driver_Races")
    @test m2m.db_table == "Dbt_Driver_Races"      # was "dbt_driver_races" before #59

    # Empty-as-unset, matching the model-level option.
    @test ManyToManyField("dbt_driver_scratch", db_table = "").db_table === nothing
    @test ManyToManyField("dbt_driver_scratch").db_table === nothing
  end
end
