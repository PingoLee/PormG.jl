"""
Unit coverage for model-name case handling (#300) and leading-underscore handling (#306).

A model's positional name used to be stored VERBATIM while the two groups of consumers disagreed
about its case: `makemigrations` lowercased it into the DDL, and the query builder quoted it as
declared. So `Model("Driver_Profile", …)` migrated the table `driver_profile` and then addressed
`"Driver_Profile"` in every SELECT/INSERT/UPDATE — a table that does not exist on PostgreSQL, where a
quoted identifier is case-sensitive. SQLite's case-insensitive identifiers masked it entirely.

A leading underscore split the schema the same way, one character away from #300: `format_model_name`
(used to render an FK `REFERENCES` target and to resolve a model reference by name) stripped ONE
leading underscore, inherited from the FIELD-name reserved-word escape hatch — but `create_table`
wrote the stored name as-is. So `Model("_order", …)` created table `_order` while a `ForeignKey`
pointing at it referenced `"order"` — a different table, or a failed constraint if `order` didn't
exist.

**That second split no longer exists at all.** #317 retired the field-name hatch, so
`format_model_name` is a pure `lowercase` fold with nothing to inherit: an unresolved FK target
`"_Order"` now renders `REFERENCES "_order"`, exactly what `create_table` writes. The #306 rejection
stands on its own footing instead — a PormG model name is a lowercase LOGICAL identifier, and
`db_table` (#59) carries a physical name that is anything else. Same reasoning as the case rule, and
the guard's message says so.

So this file **pins** both rejections (the only assertions here that go red without the guards),
**documents** the DDL/query agreement they buy, **pins the decoupling** that closed the underscore
split at the root, and **characterizes** the case split as it still stands on the paths deliberately
left exempt. It also records one remaining limit of the guard: it does not reject an invalid bare
identifier (a reserved word or a name containing a space).

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
  # It was originally the same defect as #300 one character away — the declaration succeeded and
  # produced a model whose created table and FK `REFERENCES` target disagreed. #317 closed that at the
  # root (see the decoupling testset below), so this is now a POLICY rejection: a model name is a
  # lowercase logical identifier, and `db_table` carries a physical name that is anything else.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "positional name with a leading underscore is rejected (#306)" begin
    @test_throws PormG.ModelDefinitionError Model("_driver_scratch", id = IDField())
    @test_throws PormG.ModelDefinitionError Model("_order", id = IDField())

    # Same actionability requirement as the case guard: the message names the offending value, the
    # spelling to declare instead, AND the escape valve for a table genuinely named `_order`.
    err = try
      Model("_order", id = IDField()); nothing
    catch e; e end
    @test err isa PormG.ModelDefinitionError
    @test occursin("_order", err.msg)     # the name the user wrote
    @test occursin("order", err.msg)      # the name they should write
    @test occursin("db_table", err.msg)   # …and how to keep the underscored physical table

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

    # An all-underscore name ("_", "___") strips to the empty string, and "Declare it as ''." is
    # worse than no suggestion at all — the message omits that clause rather than emitting it.
    # Any number of leading underscores is one rejection with one message (#317 removed the
    # two-branch split, whose premise was that `format_model_name` stripped exactly one and then
    # rejected the remainder — it strips none now).
    for bad in ("__order", "_", "___")
      err_multi = try
        Model(bad, id = IDField()); nothing
      catch e; e end
      @test err_multi isa PormG.ModelDefinitionError
      @test occursin(bad, err_multi.msg)
      @test !occursin("Declare it as ''", err_multi.msg)
      @test occursin("db_table", err_multi.msg)      # still actionable: pin the physical name
    end
    # `__order` DOES have a usable suggestion — all leading underscores are stripped for the hint,
    # so it is one-shot correct rather than the still-rejected `_order` a single strip would give.
    err_dbl = try; Model("__order", id = IDField()); nothing; catch e; e end
    @test occursin("Declare it as 'order'", err_dbl.msg)

    # No message may claim the FK-divergence story any more — it is not what happens for ANY of
    # these names since #317 decoupled `format_model_name`.
    for bad in ("_order", "__order", "_", "___", "_driver_scratch")
      err_ref = try; Model(bad, id = IDField()); nothing; catch e; e end
      @test !occursin("REFERENCES", err_ref.msg)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The DECOUPLING that closed the underscore split at its root (#317). `format_model_name` no
  # longer inherits the field-name hatch, so it rewrites nothing but case — and an unresolved
  # String FK target renders the SAME identifier `create_table` writes. Before, these disagreed.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_model_name is a pure case fold (#317)" begin
    @test Models.format_model_name("_Order")  == "_order"    # was: "order" — the split
    @test Models.format_model_name("__order") == "__order"   # was: ModelDefinitionError
    @test Models.format_model_name("a__b")    == "a__b"      # was: ModelDefinitionError
    @test Models.format_model_name("Driver")  == "driver"    # the fold itself is unchanged

    # The property that matters: an FK pointing at an unresolved `_`-prefixed target references the
    # table that name denotes, not a stripped variant of it.
    fk = Models.ForeignKey("_Fk317_Parent", pk_field = "id")
    @test Models.fk_target_table(fk) == "_fk317_parent"
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
  # CLOSED (#59). This testset used to CHARACTERIZE the DDL/query split on the exempt `Dict` path —
  # `create_table` folded `Driver_Profile` to `driver_profile` while the query builder quoted it as
  # declared, so one model addressed two tables. Its own comment said it was "SUPPOSED TO FAIL" once
  # the split was closed properly, naming #59's `db_table` as one of the ways that could happen.
  #
  # That is what happened. `model_table_name` is now the single seam every renderer resolves through
  # and it applies NO case fold, so the DDL and the query agree by construction — on this exempt path
  # too, where `model.name` IS the live physical name read out of a database.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the DDL/query split is CLOSED, including on the exempt path (#59)" begin
    split_model = Model("Driver_Profile", Dict{String, PormG.PormGField}(
      "id" => IDField(), "surname" => CharField()))
    split_model.connect_key = "model_name_case_mock"

    ddl = PormG.Dialect.create_table(MockPostgresNameCase(), split_model)
    sel = inspect_query(split_model.objects)[:sql_text]

    @test occursin("\"Driver_Profile\"", ddl)      # DDL preserves the name it was given…
    @test !occursin("driver_profile", ddl)         # …and no longer folds it into a second table
    @test occursin("\"Driver_Profile\"", sel)      # …which is the SAME string the query addresses
    @test !occursin("\"driver_profile\"", sel)

    # DELETE was the sharpest illustration of the defect — ONE statement carrying BOTH spellings,
    # because `deletion.jl` wrote the outer table bare+folded while the `IN (...)` subquery went
    # through the normal (quoting) builder. Both halves now resolve through `model_table_name`.
    del_raw = split_model.objects.filter("id" => 1).delete(show_query = :dict)
    del = del_raw isa Vector ? first(del_raw) : del_raw
    @test occursin("DELETE FROM \"Driver_Profile\"", del[:sql_text])   # quoted + unfolded
    @test !occursin("DELETE FROM driver_profile", del[:sql_text])      # the old bare+folded spelling
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CLOSED (#59), same story one character over. This used to characterize the create/REFERENCES
  # split from #306: `create_table` wrote the parent's name verbatim while a child's `ForeignKey`
  # rendered its target through `format_model_name`, which strips a leading underscore — so the FK
  # pointed at a table one character removed from the one created. Its comment likewise said it was
  # "SUPPOSED TO FAIL" once the split closed for the exempt path.
  #
  # `fk_target_table` now resolves a RESOLVED model target through `model_table_name` (no strip, no
  # fold), so both sides agree. Declaring such a name positionally is still rejected (#306) — this is
  # the introspection path, where the name is read from a live database and must survive verbatim.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the create/REFERENCES split is CLOSED on the exempt path (#306 → #59)" begin
    fk_parent = Model("_fk306_driver_scratch", Dict{String, PormG.PormGField}("id" => IDField()))
    fk_child = Model("fk306_child_scratch",
      id       = IDField(),
      driverid = Models.ForeignKey(fk_parent, pk_field = "id", on_delete = "CASCADE"),
    )

    parent_ddl = PormG.Dialect.create_table(MockSQLiteNameCase(), fk_parent)
    child_ddl  = PormG.Dialect.create_table(MockSQLiteNameCase(), fk_child)

    @test occursin("\"_fk306_driver_scratch\"", parent_ddl)                # the table actually created…
    @test occursin("REFERENCES \"_fk306_driver_scratch\"", child_ddl)      # …is the one referenced
    @test !occursin("REFERENCES \"fk306_driver_scratch\"", child_ddl)      # not the stripped spelling
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

    # …and the generated model file lowercases the POSITIONAL name, so the round-trip produces a
    # declaration the guard above accepts rather than one that would throw on reload.
    #
    # The two exempt paths diverge HERE, and the difference is load-bearing (#59). `model.name` is a
    # Python CLASS name for the Django importer and a LIVE TABLE name for `inspectdb` — identical as
    # strings, opposite in meaning — so `Model_to_str` is TOLD which it has rather than guessing.
    settings = PormG.Configuration.Settings(connections = MockPostgresNameCase(), change_data = true)

    # Django importer (name_is_physical_table = false, the default): the physical table genuinely IS
    # the lowercased class name. Pinning `db_table = "CustomUser"` here would invent a table that
    # does not exist and break every query against it.
    generated = Models.Model_to_str(django_like, settings)
    @test occursin("Models.Model(\"customuser\"", generated)
    @test !occursin("Models.Model(\"CustomUser\"", generated)
    @test !occursin("db_table", generated)

    # inspectdb (name_is_physical_table = true): the name came off a live database, so the original
    # spelling MUST be pinned — otherwise the generated declaration addresses `driver_profile`, a
    # different table from the `Driver_Profile` it was read from (the #300 split, from the other end).
    introspected_gen = Models.Model_to_str(introspected, settings; name_is_physical_table = true)
    @test occursin("Models.Model(\"driver_profile\"", introspected_gen)
    @test occursin("db_table = \"Driver_Profile\"", introspected_gen)

    # An already-lowercase live table needs no override, and must not grow a redundant one.
    plain = Model("plain_scratch", Dict{String, PormG.PormGField}("id" => IDField()))
    @test !occursin("db_table", Models.Model_to_str(plain, settings; name_is_physical_table = true))
  end
end
