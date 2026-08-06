"""
Unit coverage for model-name case handling (#300) and leading-underscore handling (#306).

A model's positional name used to be stored VERBATIM while the two groups of consumers disagreed
about its case: `makemigrations` lowercased it into the DDL, and the query builder quoted it as
declared. So `Model("Driver_Profile", …)` migrated the table `driver_profile` and then addressed
`"Driver_Profile"` in every SELECT/INSERT/UPDATE — a table that does not exist on PostgreSQL, where a
quoted identifier is case-sensitive. SQLite's case-insensitive identifiers masked it entirely.

A leading underscore split the schema the same way, one character away from #300: `format_model_name`
(used to render an FK `REFERENCES` target and to resolve a model reference by name) strips ONE leading
underscore, inherited from the FIELD-name reserved-word escape hatch — but `create_table` writes the
stored name as-is. So `Model("_order", …)` created table `_order` while a `ForeignKey` pointing at it
referenced `"order"` — a different table, or a failed constraint if `order` didn't exist.

Since #300 (case) and #306 (leading underscore) the split is unreachable from a user declaration: a
non-lowercase or underscore-prefixed positional name is rejected at construction. This file **pins
the rejection** (the only assertions here that go red without the guards), **documents** the
DDL/query agreement it buys, and **characterizes** the split as it still stands on the paths
deliberately left exempt. It also records one remaining limit of the guard: it does not reject an
invalid bare identifier (a reserved word or a name containing a space).

All assertions render via mock PostgreSQL/SQLite connections; no live database.
"""

using Test
using PormG
using PormG.Models
using PormG.Models: Model, IDField, CharField
using PormG.QueryBuilder: inspect_query

# Dedicated mocks + config key — uniquely named so they never clash with other unit files' mock
# structs when runtests.jl includes them all into the same module.
struct MockPostgresNameCase <: PormG.PormGPostgres end
struct MockSQLiteNameCase <: PormG.PormGSQLite end
PormG.config["model_name_case_mock"] = PormG.Configuration.Settings(
  connections = MockPostgresNameCase(),
  change_data = true,
)

# The supported declaration: a lowercase positional name.
NameCaseDriver = Model("name_case_driver_scratch",
  id      = IDField(),
  surname = CharField(),
)
NameCaseDriver.connect_key = "model_name_case_mock"

@testset "Model-name case and leading-underscore handling (#300, #306)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # The guard: a positional name needing a fold is a declaration-time error.
  # This is the assertion that was RED before #300 — the declaration used to succeed and produce a
  # model that migrated one table and queried another.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "non-lowercase positional name is rejected" begin
    @test_throws PormG.ModelDefinitionError Model("Driver_Profile", id = IDField())
    @test_throws PormG.ModelDefinitionError Model("Driver", id = IDField())
    @test_throws PormG.ModelDefinitionError Model("driverProfile", id = IDField())   # camelCase too

    # The message has to be actionable: it names the offending value AND the spelling to use,
    # because "must be lowercase" alone does not say what the fold would have produced.
    err = try
      Model("Driver_Profile", id = IDField()); nothing
    catch e; e end
    @test err isa PormG.ModelDefinitionError
    @test occursin("Driver_Profile", err.msg)     # the name the user wrote
    @test occursin("driver_profile", err.msg)     # the name they should write

    # Lowercase names, including digits and underscores, are unaffected and stored as written.
    @test Model("name_case_ok_scratch", id = IDField()).name == "name_case_ok_scratch"
    @test Model("f1_results_2024", id = IDField()).name == "f1_results_2024"

    # The guard checks CASE and a LEADING UNDERSCORE (#306) — and nothing else. It is NOT
    # `format_model_name`, and it applies no other identifier-shape validation. One consequence
    # remains, pinned here so it stays deliberate: the guard accepts names that are lowercase and
    # underscore-free at the front but are not valid bare identifiers — `"order"` is a reserved word,
    # `"driver profile"` contains a space — and the DDL writes the table bare, so those render invalid
    # SQL. Pre-existing and out of scope; recorded so nobody reads the guard as "the model name is now
    # safe". (A leading underscore used to be a second such gap here — see the rejection testset below.)
    @test Model("order", id = IDField()).name == "order"                    # accepted as-is
    @test Model("driver profile", id = IDField()).name == "driver profile"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The guard, extended (#306): a positional name starting with '_' is also a declaration-time error.
  # This is the assertion that was RED before #306 — the declaration used to succeed and produce a
  # model whose created table and FK `REFERENCES` target disagreed, one character away from #300.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "positional name with a leading underscore is rejected (#306)" begin
    @test_throws PormG.ModelDefinitionError Model("_driver_scratch", id = IDField())
    @test_throws PormG.ModelDefinitionError Model("_order", id = IDField())

    # Same actionability requirement as the case guard: the message names the offending value AND the
    # spelling to declare instead (the same spelling the FK `REFERENCES` target would have used).
    err = try
      Model("_order", id = IDField()); nothing
    catch e; e end
    @test err isa PormG.ModelDefinitionError
    @test occursin("_order", err.msg)     # the name the user wrote
    @test occursin("order", err.msg)      # the name they should write

    # A name failing BOTH checks (case AND underscore) must still suggest a spelling that passes on
    # RETRY — not just fix the one problem its own message names. Before this was pinned, the case
    # message suggested `lowercase(name)` alone, which for "_Driver_Scratch" is "_driver_scratch" —
    # still underscore-prefixed, so a user "fixing" it per the message would be rejected again.
    err_both = try
      Model("_Driver_Scratch", id = IDField()); nothing
    catch e; e end
    @test err_both isa PormG.ModelDefinitionError
    # The "would migrate the table '_driver_scratch'" clause legitimately still names the lowercased-
    # but-underscored spelling (that IS what makemigrations would emit) — the precise claim under test
    # is the "Declare it as" suggestion specifically, which must be the ONE-SHOT correct spelling.
    @test occursin("Declare it as 'driver_scratch'", err_both.msg)
    @test !occursin("Declare it as '_driver_scratch'", err_both.msg)   # not the still-broken half-fix

    # A double leading underscore (or a bare "_") is not one strip away from a valid FK reference the
    # way a single underscore is: `format_model_name` strips only ONE, then itself rejects what's left
    # if it still starts with '_' — so the "creates X, references Y" divergence this guard warns about
    # can never actually happen for these names. The message says so instead of making that (wrong)
    # claim, and never emits the unusable "Declare it as ''." that a naive full-strip would produce.
    for bad in ("__order", "_", "___")
      err_multi = try
        Model(bad, id = IDField()); nothing
      catch e; e end
      @test err_multi isa PormG.ModelDefinitionError
      @test occursin(bad, err_multi.msg)
      @test !occursin("Declare it as ''", err_multi.msg)
      @test !occursin("REFERENCES", err_multi.msg)   # not the single-underscore FK-divergence story
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The invariant the guard buys: the identifier in the DDL and the identifier in the query are the
  # SAME STRING. This is the assertion #300 asks for.
  #
  # DELETE is covered in the characterization testset below instead of here: `deletion.jl` lowercases
  # the OUTER table while its `IN (...)` subquery goes through the normal builder and quotes verbatim,
  # so a single DELETE renders the table twice through two different renderers. That makes it the
  # sharpest illustration of the defect (as #300 says) rather than something to leave out — but it
  # only shows anything on a name that needs folding, which the guard now forbids here.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DDL and query render the same table identifier" begin
    expected = "name_case_driver_scratch"
    @test NameCaseDriver.name == expected            # nothing rewrote it on the way in

    for conn in (MockPostgresNameCase(), MockSQLiteNameCase())
      ddl = PormG.Dialect.create_table(conn, NameCaseDriver)
      @test occursin(expected, ddl)
    end

    sel = inspect_query(NameCaseDriver.objects)[:sql_text]
    @test occursin(expected, sel)

    ins = NameCaseDriver.objects.create("id" => 1, "surname" => "Senna", show_query = :sql)
    @test occursin("INSERT INTO", uppercase(ins))
    @test occursin(expected, ins)

    upd = NameCaseDriver.objects.filter("id" => 1).update("surname" => "Prost", show_query = :sql)
    @test occursin("UPDATE", uppercase(upd))
    @test occursin(expected, upd)

    # Honest scope of this testset: on a name that is already lowercase every renderer's `|> lowercase`
    # is a no-op, so ADDING or REMOVING a fold anywhere leaves these assertions green. Only a path that
    # started *capitalizing* the identifier would trip them. It is therefore documentation-by-test of
    # the post-#300 invariant, NOT regression coverage — the assertions that actually go red without
    # the guard are in the rejection testset above, and the defect itself is pinned by the
    # characterization testset below.
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CHARACTERIZATION: the split the guard prevents is real, and still reachable through the exempt
  # `Dict` path. Without this, every assertion above is compatible with the split never having
  # existed — the guard would look like cargo cult. Here the same model renders `driver_profile` in
  # the DDL and `"Driver_Profile"` in the SELECT: one declaration, two tables.
  #
  # This is a characterization test, not an endorsement. If the split is ever closed properly
  # (folding or preserving case across both paths — options A/B/D on #300, or #59's `db_table`),
  # THIS TESTSET IS SUPPOSED TO FAIL, and updating it is the deliberate signal that the scope limit
  # documented above no longer applies.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "characterize: the DDL/query split is real on the exempt path" begin
    split_model = Model("Driver_Profile", Dict{String, PormG.PormGField}(
      "id" => IDField(), "surname" => CharField()))
    split_model.connect_key = "model_name_case_mock"

    ddl = PormG.Dialect.create_table(MockPostgresNameCase(), split_model)
    sel = inspect_query(split_model.objects)[:sql_text]

    @test occursin("driver_profile", ddl)          # DDL folds…
    @test !occursin("Driver_Profile", ddl)
    @test occursin("\"Driver_Profile\"", sel)      # …the query quotes it as declared
    @test !occursin("\"driver_profile\"", sel)

    # The sharpest illustration, and the reason DELETE is characterized here rather than asserted as
    # "agreeing" anywhere: ONE statement carries BOTH spellings. `deletion.jl` writes the outer table
    # bare and lowercased, while the `IN (...)` subquery is rendered by the normal builder and quoted
    # verbatim — so the DELETE targets `driver_profile` by way of a subquery reading
    # `"Driver_Profile"`, a table that does not exist on PostgreSQL.
    del_raw = split_model.objects.filter("id" => 1).delete(show_query = :dict)
    del = del_raw isa Vector ? first(del_raw) : del_raw
    @test occursin("DELETE FROM driver_profile", del[:sql_text])   # bare + folded
    @test occursin("\"Driver_Profile\"", del[:sql_text])           # …and quoted verbatim, same string
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CHARACTERIZATION (#306): the create/REFERENCES split the underscore guard prevents is real, and
  # still reachable through the exempt `Dict` path — the issue's own repro, DB-free via SQLite's inline
  # FK. `create_table` writes the PARENT's name verbatim (`_fk306_driver_scratch`); the CHILD's
  # `ForeignKey` renders through `format_model_name`, which strips the leading underscore
  # (`fk306_driver_scratch`) — a table one character removed from the one actually created.
  #
  # This is a characterization test, not an endorsement. If this split is ever closed for the exempt
  # path too, THIS TESTSET IS SUPPOSED TO FAIL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "characterize: the create/REFERENCES split is real on the exempt path (#306)" begin
    fk_parent = Model("_fk306_driver_scratch", Dict{String, PormG.PormGField}("id" => IDField()))
    fk_child = Model("fk306_child_scratch",
      id       = IDField(),
      driverid = Models.ForeignKey(fk_parent, pk_field = "id", on_delete = "CASCADE"),
    )

    parent_ddl = PormG.Dialect.create_table(MockSQLiteNameCase(), fk_parent)
    child_ddl  = PormG.Dialect.create_table(MockSQLiteNameCase(), fk_child)

    @test occursin("_fk306_driver_scratch", parent_ddl)                    # the table actually created…
    @test occursin("REFERENCES \"fk306_driver_scratch\"", child_ddl)       # …a DIFFERENT table referenced
    @test !occursin("REFERENCES \"_fk306_driver_scratch\"", child_ddl)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The two exemptions, pinned. `inspectdb` introspection and the Django importer build models from a
  # name they read out of a live database or a Python class, where mixed case is legitimate and must
  # survive verbatim — `Model_to_str` lowercases it when it writes the generated model file.
  # Tightening the guard onto these methods would break `inspectdb` on legacy tables and break Django
  # import outright, so this testset exists to make that mistake fail loudly.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "introspection and Django-importer paths stay verbatim" begin
    # Django importer: `Models.Model(class_name, fields_dict)` with a Dict{Symbol, Any}.
    django_like = Model("CustomUser", Dict{Symbol, Any}(:id => IDField()))
    @test django_like.name == "CustomUser"

    # inspectdb: `Models.Model(table_name, fields_dict)` with a Dict{String, PormGField}.
    introspected = Model("Driver_Profile", Dict{String, PormG.PormGField}("id" => IDField()))
    @test introspected.name == "Driver_Profile"

    # …and the generated model file lowercases it, so the round-trip produces a declaration that the
    # guard above accepts rather than one that would throw on reload.
    settings = PormG.Configuration.Settings(connections = MockPostgresNameCase(), change_data = true)
    generated = Models.Model_to_str(django_like, settings)
    @test occursin("Models.Model(\"customuser\"", generated)
    @test !occursin("Models.Model(\"CustomUser\"", generated)
  end
end
