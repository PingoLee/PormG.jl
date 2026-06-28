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
