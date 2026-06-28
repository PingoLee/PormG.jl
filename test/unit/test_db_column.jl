"""
Unit coverage for the `db_column` field option (#50).

`db_column` makes the generated SQL column name differ from the declared field name,
Django-style: `sku = CharField(db_column="product_sku")` keeps field identity `sku` but
renders the physical column `"product_sku"` in DDL, SELECT/WHERE/ORDER BY, INSERT/UPDATE,
and FK constraints — while query results stay keyed by the field name (`sku`). The default
(column == field name) is unchanged, so existing schemas are unaffected (non-breaking).

All assertions render via mock PostgreSQL/SQLite connections (no live database required).
"""

using Test
using PormG
using DataFrames
using PormG.Models: Model, CharField, IDField, IntegerField, ForeignKey, OneToOneField,
                    field_db_column, fk_target_column, model_column, model_has_db_column,
                    are_model_fields_equal
using PormG.QueryBuilder: inspect_query, Count

# Dedicated mock connections — uniquely named so they never clash with other unit files'
# mock structs when runtests.jl includes them into the same module.
struct MockPostgresDbColumn <: PormG.PormGPostgres end
struct MockSQLiteDbColumn <: PormG.PormGSQLite end
PormG.config["default"] = PormG.Configuration.Settings(
  connections = MockPostgresDbColumn(),
  change_data = true,
)

# Scalar db_column fixture: field `sku` maps to physical column `product_sku`.
Product = Model("product_scratch",
  id   = IDField(),
  sku  = CharField(db_column="product_sku"),
  name = CharField(),
)
Product.connect_key = "default"

# Parent whose REFERENCED field carries a db_column — exercises fk_target_column. The FK
# target is passed as a model instance so `.to` is resolved (mirrors a post-set_models graph).
DriverRef = Model("driverref_scratch",
  id   = IDField(),
  code = CharField(db_column="driver_code", unique=true),
)
DriverRef.connect_key = "default"

# Child FK: local column renamed (`drv`) AND referencing a renamed parent column (`code`).
Entry = Model("entry_scratch",
  id     = IDField(),
  driver = ForeignKey(DriverRef, pk_field="code", db_column="drv"),
)
Entry.connect_key = "default"

# #62 string-target fixtures are built FRESH inside each test below (local instances or a
# throwaway Module), so every subtest is isolated and re-runnable — matching this file's
# convention of per-subtest fixtures rather than shared mutable module-level state.

@testset "db_column authoritative (#50)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # field_db_column: db_column when set & non-empty, else the field name. This is the
  # single helper every field→column conversion flows through.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "field_db_column helper" begin
    @test field_db_column(CharField(db_column="product_sku"), "sku") == "product_sku"
    @test field_db_column(CharField(), "sku")                        == "sku"   # unset → field name
    @test field_db_column(CharField(db_column=""), "sku")            == "sku"   # empty treated as unset
    @test field_db_column(IntegerField(db_column="qty_col"), "qty")  == "qty_col"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # fk_target_column: resolve the FK's referenced parent column to that field's
  # db_column when the target model is in scope; verbatim fallback otherwise.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "fk_target_column helper" begin
    @test fk_target_column(ForeignKey(DriverRef, pk_field="code")) == "driver_code"  # resolved
    @test fk_target_column(ForeignKey("UnresolvedTarget", pk_field="code")) == "code" # String .to → verbatim
    @test fk_target_column(ForeignKey(DriverRef)) == "id"                             # no pk_field → id

    # Underscore-escaped reserved-word pk_field resolves to the parent's stored (stripped)
    # key — ForeignKey AND OneToOneField both normalize pk_field via format_fild_name.
    ParentEnd = Model("parent_end_scratch", id=IDField(), _end=CharField(db_column="end_col"))
    @test ForeignKey(ParentEnd, pk_field="_end").pk_field == "end"
    @test OneToOneField(ParentEnd, pk_field="_end").pk_field == "end"
    @test fk_target_column(ForeignKey(ParentEnd, pk_field="_end")) == "end_col"
    @test fk_target_column(OneToOneField(ParentEnd, pk_field="_end")) == "end_col"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # model_column (guarded name→column) and model_has_db_column (fast-path gate).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "model_column / model_has_db_column helpers" begin
    @test model_column(Product, "sku")  == "product_sku"
    @test model_column(Product, "name") == "name"
    @test model_column(Product, "not_a_field") == "not_a_field"   # verbatim fallback
    @test model_has_db_column(Product)
    @test !model_has_db_column(Model("nocol_scratch", id=IDField(), name=CharField()))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DDL: column names use db_column; a field WITHOUT db_column keeps the field name
  # (non-breaking default); the table name is unchanged.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "create_table renders db_column (PG + SQLite)" begin
    for conn in (MockPostgresDbColumn(), MockSQLiteDbColumn())
      ddl = PormG.Dialect.create_table(conn, Product)
      @test occursin("\"product_sku\"", ddl)   # db_column column present
      @test !occursin("\"sku\"", ddl)           # field name does NOT leak as a column
      @test occursin("\"name\"", ddl)           # non-db_column field unchanged
      @test occursin("product_scratch", ddl)    # table name unchanged
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite FK constraint: local FK column = db_column ("drv"); referenced parent
  # column = the parent field's db_column ("driver_code"), via fk_target_column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite create_table FK constraint honors db_column both sides" begin
    ddl = PormG.Dialect.create_table(MockSQLiteDbColumn(), Entry)
    @test occursin("FOREIGN KEY (\"drv\")", ddl)         # local FK column = db_column
    @test occursin("(\"driver_code\")", ddl)             # referenced parent column resolved
    @test occursin("\"driverref_scratch\"", ddl)         # referenced table name
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # add_field (ALTER TABLE ADD COLUMN) renders the db_column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "add_field renders db_column" begin
    sql = PormG.Dialect.add_field(MockPostgresDbColumn(), "product_scratch", "sku", Product.fields["sku"])
    @test occursin("\"product_sku\"", sql)
    @test !occursin("\"sku\"", sql)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Reads: WHERE/SELECT/ORDER BY target the db_column; SELECT auto-aliases the
  # projection back to the field name so rows stay keyed by `sku`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "reads render db_column, alias back to field name" begin
    q = Product.objects
    q.filter("sku" => "ABC")
    q.values("sku", "name")
    insp = inspect_query(q)
    @test occursin("\"product_sku\" = \$1", insp[:sql_text])              # WHERE → db_column
    @test occursin("\"Tb\".\"product_sku\" as \"sku\"", insp[:sql_text])  # SELECT → "col as field"
    @test insp[:parameters] == ["ABC"]

    oq = Product.objects
    oq.order_by("sku")
    @test occursin("\"product_sku\"", inspect_query(oq)[:sql_text])       # ORDER BY → db_column

    aq = Product.objects
    aq.values("n" => Count("sku"))
    @test occursin("\"product_sku\"", inspect_query(aq)[:sql_text])       # aggregate over db_column
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Filter OPERATORS (not just `=`) on a db_column field resolve to the db_column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "filter operators resolve db_column" begin
    qin = Product.objects; qin.filter("sku__@in" => ["A", "B"])
    @test occursin("\"product_sku\"", inspect_query(qin)[:sql_text])      # IN (...)

    qlike = Product.objects; qlike.filter("sku__@contains" => "x")
    @test occursin("\"product_sku\"", inspect_query(qlike)[:sql_text])    # LIKE

    qgt = Product.objects; qgt.filter("sku__@gt" => "M")
    @test occursin("\"product_sku\"", inspect_query(qgt)[:sql_text])      # > comparison
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Writes: INSERT column list and UPDATE SET clause target the db_column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "INSERT and UPDATE render db_column" begin
    ins = Product.objects.create("sku" => "ABC", "name" => "n", show_query=:sql)
    @test occursin("INSERT INTO", uppercase(ins))
    @test occursin("\"product_sku\"", ins)
    @test !occursin("\"sku\"", ins)

    upd = Product.objects.filter("id" => 1).update("sku" => "NEW", show_query=:sql)
    @test occursin("UPDATE", uppercase(upd))
    @test occursin("\"product_sku\"", upd)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Bulk: bulk_insert + bulk_copy column lists use db_column. bulk_update applies the
  # SPLIT rule — the SET target uses db_column, but the source.* reference and the
  # VALUES/CTE source column list stay the FIELD name (they name the internal source).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "bulk paths honor db_column with source/target split" begin
    df = DataFrame(sku=["A", "B"], name=["n1", "n2"])

    bi = PormG.bulk_insert(Product.objects, df, show_query=:sql)
    bi_sql = bi isa AbstractString ? bi : join(string.(bi), "\n")
    @test occursin("\"product_sku\"", bi_sql)

    bc = PormG.bulk_copy(Product.objects, df, show_query=:sql)
    bc_sql = bc isa AbstractString ? bc : join(string.(bc), "\n")
    @test occursin("\"product_sku\"", bc_sql)             # COPY targets the db_column

    # bulk_update: SET "product_sku" = source."sku"; source column list is ("sku").
    up_df = DataFrame(id=[1], sku=["X"])
    bu = PormG.bulk_update(Product.objects, up_df, columns=["sku"], match_on=["id"], show_query=:sql)
    bu_sql = bu isa AbstractString ? bu : join(string.(bu), "\n")
    @test occursin("\"product_sku\" = source.\"sku\"", bu_sql)  # target db_column, source field name
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Comparison: adding a db_column IS a real model change (code-vs-code), so the diff
  # engine must report it — even though it produces no spurious migration churn
  # against an already-matching DB (that no-churn path is an integration test).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "are_model_fields_equal treats db_column as a real change" begin
    same  = Model("product_scratch", id=IDField(), sku=CharField(db_column="product_sku"), name=CharField())
    plain = Model("product_scratch", id=IDField(), sku=CharField(),                         name=CharField())
    @test are_model_fields_equal(Product, same)    # identical db_column → equal
    @test !are_model_fields_equal(Product, plain)  # db_column added/removed → not equal
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Serialization (migration snapshots): the field serializer emits db_column for a
  # scalar, a ForeignKey, and a OneToOneField, and omits it when unset.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Model_to_str serializes db_column" begin
    g = PormG.Models._model_to_str_general("sku", CharField(db_column="product_sku"), :CharField, String[], "")
    @test occursin("db_column=\"product_sku\"", g)

    fk = PormG.Models._model_to_str_foreign_key("driver", ForeignKey("Driver", db_column="drv"), :ForeignKey, String[], "")
    @test occursin("db_column=\"drv\"", fk)

    o2o = PormG.Models._model_to_str_foreign_key("prof", OneToOneField("Driver", db_column="prof_col"), :OneToOneField, String[], "")
    @test occursin("db_column=\"prof_col\"", o2o)

    plain = PormG.Models._model_to_str_general("sku", CharField(), :CharField, String[], "")
    @test !occursin("db_column", plain)   # omitted when unset
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #57 × #50: a mixed-case field NAME with a snake_case db_column. Case is preserved
  # for the field identity and the SELECT alias; the physical column is the db_column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "mixed-case field name with snake_case db_column (#57 × #50)" begin
    Legacy = Model("legacy_case_scratch",
      id       = IDField(),
      driverId = CharField(db_column="driver_id"),
    )
    Legacy.connect_key = "default"

    @test field_db_column(Legacy.fields["driverId"], "driverId") == "driver_id"

    ddl = PormG.Dialect.create_table(MockPostgresDbColumn(), Legacy)
    @test occursin("\"driver_id\"", ddl)
    @test !occursin("\"driverId\"", ddl)   # the mixed-case field name is not a column

    q = Legacy.objects
    q.filter("driverId" => "senna")
    q.values("driverId")
    insp = inspect_query(q)
    @test occursin("\"driver_id\" = \$1", insp[:sql_text])            # WHERE → db_column
    @test occursin("\"driver_id\" as \"driverId\"", insp[:sql_text])  # alias back to the mixed-case field
  end

end

# ════════════════════════════════════════════════════════════════════════════════════════
# #62 — string FK targets resolve to model objects, so `db_column` on a REFERENCED parent
# key is honored for string-declared FKs too (model-instance targets already worked in #50).
# ════════════════════════════════════════════════════════════════════════════════════════
@testset "db_column string FK targets (#62)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # _resolve_target_model: name string → model object; model passthrough; unknown
  # name → nothing (caller decides strictness).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "_resolve_target_model" begin
    @test PormG.Models._resolve_target_model("DriverRef", @__MODULE__) === DriverRef
    @test PormG.Models._resolve_target_model(DriverRef, @__MODULE__)   === DriverRef   # passthrough
    @test PormG.Models._resolve_target_model("NoSuchModelXYZ", @__MODULE__) === nothing
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The #62 gap: an UNRESOLVED string target falls back to the verbatim pk_field name;
  # once `.to` is a resolved model, fk_target_column returns the parent's db_column —
  # identical to the model-instance variant. (This tests the resolver ∘ fk_target_column
  # composition; the production write-back itself is guarded by the set_models test in
  # test_alignment_sqlite.jl and the integration join test.)
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "resolved string target → parent db_column (fk_target_column)" begin
    fk = ForeignKey("DriverRef", pk_field="code", db_column="drv")
    @test fk_target_column(fk) == "code"                       # before: verbatim pk name (the gap)
    fk.to = PormG.Models._resolve_target_model(fk.to, @__MODULE__)
    @test fk_target_column(fk) == "driver_code"                # after: parent's db_column
    @test fk_target_column(fk) == fk_target_column(ForeignKey(DriverRef, pk_field="code"))  # == model-instance

    # OneToOneField shares the resolution path (set_models / prelude branch on
    # `sForeignKey || sOneToOneField`) — a string-target O2O resolves identically.
    o2o = OneToOneField("DriverRef", pk_field="code", db_column="prof")
    @test fk_target_column(o2o) == "code"
    o2o.to = PormG.Models._resolve_target_model(o2o.to, @__MODULE__)
    @test fk_target_column(o2o) == "driver_code"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Render: once a string-target FK's `.to` is resolved, create_table renders the FK
  # constraint with the parent's db_column AND the real table name — matching a
  # model-instance FK. Fresh local fixture, so the subtest is re-runnable.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "create_table FK constraint renders a resolved string target" begin
    entry_str = Model("entry_str_local_scratch",
      id     = IDField(),
      driver = ForeignKey("DriverRef", pk_field="code", db_column="drv"),
    )
    entry_str.fields["driver"].to = PormG.Models._resolve_target_model(entry_str.fields["driver"].to, @__MODULE__)
    ddl = PormG.Dialect.create_table(MockSQLiteDbColumn(), entry_str)
    @test occursin("FOREIGN KEY (\"drv\")", ddl)       # local FK column = db_column
    @test occursin("(\"driver_code\")", ddl)           # referenced parent column resolved (the #62 fix)
    @test occursin("\"driverref_scratch\"", ddl)       # resolved → real table name, not "driverref"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The migration prelude proper: resolve `.to` AND default a missing pk_field, plus the
  # best-effort branch (unresolvable target → left as-is, no throw). Built in a throwaway
  # Module (the dup_test_module idiom) so it's isolated/re-runnable, and tested directly on
  # `_resolve_fk_targets_and_pk!` so it can't pass via an include-time set_models confound.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "migration prelude resolves string target + defaults pk_field" begin
    prelude_parent = Model("db62_prelude_parent", code = IDField(db_column="parent_code"), label = CharField(null=true))
    prelude_child  = Model("db62_prelude_child", id = IDField(),
      parent = ForeignKey("Db62PreludeParent", db_column="parent_fk", null=true),   # string target, NO pk_field
    )
    prelude_orphan = Model("db62_prelude_orphan", id = IDField(),
      ref = ForeignKey("NoSuchModelABC", db_column="ref_fk", null=true),            # unresolvable target
    )
    mod = Module(:db62_prelude_module)
    Core.eval(mod, :(const Db62PreludeParent = $prelude_parent))   # the FK string target must be a binding in `mod`
    Core.eval(mod, :(const Db62PreludeChild  = $prelude_child))
    Core.eval(mod, :(const Db62PreludeOrphan = $prelude_orphan))

    # Pre-conditions (fresh fixtures): unresolved string target, no pk_field.
    @test prelude_child.fields["parent"].to == "Db62PreludeParent"
    @test prelude_child.fields["parent"].pk_field === nothing

    current = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
      :db62_prelude_parent => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => prelude_parent, :exist => false),
      :db62_prelude_child  => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => prelude_child,  :exist => false),
      :db62_prelude_orphan => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => prelude_orphan, :exist => false),
    )
    PormG.Migrations._resolve_fk_targets_and_pk!(current, mod)

    # Resolvable string target → resolved model + defaulted pk_field + parent's db_column.
    @test prelude_child.fields["parent"].to === prelude_parent   # resolved to the model object
    @test prelude_child.fields["parent"].pk_field == "code"      # defaulted to the parent's PK field name
    @test fk_target_column(prelude_child.fields["parent"]) == "parent_code"  # → db_column, NOT the "id" fallback

    # Best-effort: an UNRESOLVABLE string target is left as-is (no throw); pk_field untouched.
    @test prelude_orphan.fields["ref"].to == "NoSuchModelABC"
    @test prelude_orphan.fields["ref"].pk_field === nothing
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Serializer: a model-instance `.to` serializes to the SAME string a user would have
  # declared (uppercasefirst(model.name)) — the write-back can't change snapshot output.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "serializer: model-instance .to == its string form" begin
    fk_model = PormG.Models._model_to_str_foreign_key("driver", ForeignKey(DriverRef, db_column="drv"), :ForeignKey, String[], "")
    fk_str   = PormG.Models._model_to_str_foreign_key("driver", ForeignKey("Driverref_scratch", db_column="drv"), :ForeignKey, String[], "")
    @test fk_model == fk_str                                       # byte-identical serialization
    @test occursin("Models.ForeignKey(\"Driverref_scratch\"", fk_model)
    @test occursin("db_column=\"drv\"", fk_model)
  end

end
