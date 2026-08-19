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
using InteractiveUtils: subtypes   # #376: walk every field TYPE, not a hand-maintained list

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

    # A reserved-word column declared the #317 way — legal Julia identity, real column pinned
    # with db_column — resolves through pk_field on both ForeignKey and OneToOneField.
    ParentEnd = Model("parent_end_scratch", id=IDField(), end_=CharField(db_column="end_col"))
    @test ForeignKey(ParentEnd, pk_field="end_").pk_field == "end_"
    @test OneToOneField(ParentEnd, pk_field="end_").pk_field == "end_"
    @test fk_target_column(ForeignKey(ParentEnd, pk_field="end_")) == "end_col"
    @test fk_target_column(OneToOneField(ParentEnd, pk_field="end_")) == "end_col"

    # pk_field is a REFERENCE, not a declaration: `format_fild_name` passes it through
    # verbatim (#317), so it can name a `_id`-style key on a Dict-built (introspected)
    # model. The declaration guard deliberately does not reach here.
    @test ForeignKey(ParentEnd, pk_field="_end").pk_field == "_end"
    @test OneToOneField(ParentEnd, pk_field="_end").pk_field == "_end"
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
  # field_without_db_column (#376): the same field as a DERIVED table exposes it.
  # A CTE's columns are its `values()` projection ALIASES, so the field object that TYPES a CTE
  # column must stop claiming the base table's physical name. Two guards: a STRUCTURAL one over
  # every field type (the rebuild goes through the default positional constructor, which only
  # exists while no field struct declares an inner one), and a BEHAVIORAL round-trip.
  # Rendering coverage for the CTE itself lives in `test_cte_db_column.jl`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "field_without_db_column strips the physical name (#376)" begin

    # Structural: the helper rebuilds `T(getfield(f, 1), …)`, so every concrete field type must
    # still be a plain struct with only Julia's two AUTO-GENERATED constructors (the `::Any` one
    # and the field-typed one). An inner constructor would sit in front of the rebuild and could
    # normalize, reorder or reject the arguments — silently changing what the CTE model holds.
    #
    # Counting methods, NOT `hasmethod(T, Tuple{fieldtypes(T)...})`: the auto-generated `::Any`
    # constructor makes that true for ANY same-arity tuple (measured: it also accepts N `Int`s),
    # so it detects nothing except an arity change. `SQLOrder` in `querybuilder/types.jl` shows a
    # same-arity inner constructor is a shape this repo actually uses.
    concrete = filter(isconcretetype, subtypes(PormG.PormGField))
    @test length(concrete) == 26                        # fails loudly when a field type is added —
    for T in concrete                                   # exactly when this helper wants re-reading
      @test length(methods(T)) == 2                     # no inner constructor in front of the rebuild
    end
    # Every field type carries a `db_column` slot except ManyToMany, which adds no physical column
    # to the owning table at all. A NEW slot-less type would make the helper a silent no-op there.
    @test [T for T in concrete if !(:db_column in fieldnames(T))] == [PormG.Models.sManyToManyField]

    # Behavioral: a renamed field is rebuilt as the SAME type with db_column cleared and every
    # other slot preserved — checked field-by-field, so a constructor-argument-order slip (which
    # would silently swap two same-typed slots) cannot pass.
    renamed = CharField(db_column = "product_sku", null = true, max_length = 42)
    stripped = PormG.Models.field_without_db_column(renamed)
    @test typeof(stripped) === typeof(renamed)
    @test stripped.db_column === nothing
    @test field_db_column(stripped, "sku") == "sku"     # ... so it now answers the ALIAS
    for f in fieldnames(typeof(renamed))
      f === :db_column && continue
      @test getfield(stripped, f) === getfield(renamed, f)
    end

    # sIDField is the one IMMUTABLE field struct — the reason the helper rebuilds instead of
    # mutating, since `id` appears in nearly every CTE projection.
    @test !ismutabletype(PormG.Models.sIDField)
    stripped_id = PormG.Models.field_without_db_column(IDField(db_column = "pk_code"))
    @test stripped_id isa PormG.Models.sIDField && stripped_id.db_column === nothing

    # A ForeignKey keeps its resolved target BY REFERENCE — the copy must not deep-copy the model
    # graph, or `fk_target_column` would read a detached parent.
    fk = ForeignKey(DriverRef, pk_field = "code", db_column = "drv")
    fk_stripped = PormG.Models.field_without_db_column(fk)
    @test fk_stripped.db_column === nothing
    @test fk_stripped.to === DriverRef                    # same model object, not a copy
    @test fk_target_column(fk_stripped) == "driver_code"  # parent's own db_column still resolves

    # JSONField: the base column of a `payload__key` extraction goes through the same helper.
    json_stripped = PormG.Models.field_without_db_column(PormG.Models.JSONField(db_column = "meta_json", null = true))
    @test json_stripped.db_column === nothing

    # No-op cases return the IDENTICAL object — this is what makes the fix allocate nothing and
    # render byte-identically for the overwhelmingly common db_column-free model.
    plain = CharField(null = true)
    @test PormG.Models.field_without_db_column(plain) === plain
    empty_dbc = CharField(db_column = "")                 # already a no-op for field_db_column
    @test PormG.Models.field_without_db_column(empty_dbc) === empty_dbc
    m2m = PormG.Models.ManyToManyField(DriverRef)          # no db_column slot at all
    @test PormG.Models.field_without_db_column(m2m) === m2m
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
  # #65: `resolve_fk_target!` is the SINGLE source of FK/O2O resolution + pk_field
  # defaulting that BOTH load lifecycles (runtime `set_models`, the migration prelude)
  # call. These assertions lock the two axes that matter: (A) on a resolvable target the
  # strict and best-effort modes are byte-for-byte equivalent — the anti-drift guarantee;
  # if a future edit lets the runtime and migration paths diverge, (A) breaks. (B)
  # strictness is the ONLY behavioral difference, and only on an unresolvable target.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "resolve_fk_target! single-sources FK resolution (#65)" begin
    rfk = PormG.Models.resolve_fk_target!

    # Parent whose PK carries a db_column, plus two IDENTICAL children (string FK target,
    # no pk_field) — one driven strict (runtime mode), one best-effort (migration mode).
    r65_parent   = Model("r65_parent", code = IDField(db_column="parent_code"), label = CharField(null=true))
    r65_child_s  = Model("r65_child_s", id = IDField(), parent = ForeignKey("R65Parent", db_column="pfk", null=true))
    r65_child_b  = Model("r65_child_b", id = IDField(), parent = ForeignKey("R65Parent", db_column="pfk", null=true))
    r65_orphan_s = Model("r65_orphan_s", id = IDField(), ref = ForeignKey("R65NoSuch", db_column="rfk", null=true))
    r65_orphan_b = Model("r65_orphan_b", id = IDField(), ref = ForeignKey("R65NoSuch", db_column="rfk", null=true))
    mod = Module(:r65_resolver_module)
    Core.eval(mod, :(const R65Parent = $r65_parent))   # the only resolvable binding in `mod`

    # (A) Anti-drift: strict=true (runtime) and strict=false (migration) agree on a resolvable target.
    gs = rfk(r65_child_s.fields["parent"], "parent", "r65_child_s", mod; strict=true)
    gb = rfk(r65_child_b.fields["parent"], "parent", "r65_child_b", mod; strict=false)
    @test gs === r65_parent === gb                                       # same resolved model object
    @test r65_child_s.fields["parent"].to === r65_child_b.fields["parent"].to === r65_parent
    @test r65_child_s.fields["parent"].pk_field == r65_child_b.fields["parent"].pk_field == "code"
    @test fk_target_column(r65_child_s.fields["parent"]) == fk_target_column(r65_child_b.fields["parent"]) == "parent_code"

    # Idempotent: re-resolving an already-resolved field is a no-op (safe on set_models re-runs / reload).
    @test rfk(r65_child_s.fields["parent"], "parent", "r65_child_s", mod; strict=true) === r65_parent
    @test r65_child_s.fields["parent"].to === r65_parent
    @test r65_child_s.fields["parent"].pk_field == "code"

    # (B) Strictness is the only axis of difference — and only on an UNRESOLVABLE target.
    #  best-effort: nothing returned, `.to` left a string, pk_field NOT defaulted (the continue-skip).
    @test rfk(r65_orphan_b.fields["ref"], "ref", "r65_orphan_b", mod; strict=false) === nothing
    @test r65_orphan_b.fields["ref"].to == "R65NoSuch"
    @test r65_orphan_b.fields["ref"].pk_field === nothing
    #  strict: throws ModelDefinitionError naming the target, the field, and the model — and does NOT write back
    #  (the message must still name the originally-declared string, so the throw precedes the write-back).
    err = try; rfk(r65_orphan_s.fields["ref"], "ref", "r65_orphan_s", mod; strict=true); nothing; catch e; e; end
    @test err isa PormG.ModelDefinitionError
    @test occursin("R65NoSuch", err.msg) && occursin("field ref", err.msg) && occursin("model r65_orphan_s", err.msg)
    @test r65_orphan_s.fields["ref"].to == "R65NoSuch"                   # strict throw did NOT mutate the field
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
