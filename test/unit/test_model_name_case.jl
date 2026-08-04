"""
Unit coverage for model-name case handling (#300).

A model's positional name used to be stored VERBATIM while the two groups of consumers disagreed
about its case: `makemigrations` lowercased it into the DDL, and the query builder quoted it as
declared. So `Model("Driver_Profile", …)` migrated the table `driver_profile` and then addressed
`"Driver_Profile"` in every SELECT/INSERT/UPDATE — a table that does not exist on PostgreSQL, where a
quoted identifier is case-sensitive. SQLite's case-insensitive identifiers masked it entirely.

Since #300 the split is unreachable from a user declaration: a non-lowercase positional name is
rejected at construction. This file **pins the rejection** (the only assertions here that go red
without the guard), **documents** the DDL/query agreement it buys, and **characterizes** the split as
it still stands on the paths deliberately left exempt. It also records two limits of the guard: it
checks case only, so it neither strips a leading underscore nor rejects an invalid bare identifier.

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

@testset "Model-name case (#300)" begin

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

    # The guard checks CASE and nothing else — it is NOT `format_model_name`, and it applies no
    # identifier-shape validation. Two consequences, pinned here so they are deliberate:
    #
    # (a) A positional name keeps its leading underscore, where `format_model_name` strips it as the
    #     reserved-word escape hatch. This is NOT harmless: FK targets are rendered through
    #     `format_model_name` (`Dialect.jl` inline FK, `planner.jl` ADD CONSTRAINT), so a model named
    #     "_order" is created as `_order` and referenced as `"order"` — a split of the same shape as
    #     #300, one character away. Out of scope here (it is an underscore split, not a case split);
    #     see the follow-up noted on the issue.
    # (b) The guard accepts names that are lowercase but not valid bare identifiers — `"order"` is a
    #     reserved word, `"driver profile"` contains a space — and the DDL writes the table bare, so
    #     those render invalid SQL. Also pre-existing and out of scope; recorded so nobody reads the
    #     guard as "the model name is now safe".
    @test Model("_driver_scratch", id = IDField()).name == "_driver_scratch"
    @test Models.format_model_name("_driver_scratch") == "driver_scratch"   # (a): the two disagree
    @test Model("order", id = IDField()).name == "order"                    # (b): accepted as-is
    @test Model("driver profile", id = IDField()).name == "driver profile"
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
