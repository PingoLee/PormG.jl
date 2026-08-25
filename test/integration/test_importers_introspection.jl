# ==============================================================================
# SCHEMA IMPORTER / INTROSPECTION — Live-Database Integration Tests
#
# Included from runtests.jl AFTER common_setup.jl, against the selected DB
# (PORMG_DB_FOLDER; db_2 = PostgreSQL by default, db_sl = SQLite).
#
# Why integration: every importer/introspection UNIT test uses a hermetic temp
# SQLite database or a synthetic DataFrameRow. The real PostgreSQL introspection
# path — `convert_schema_to_models(::PormGPostgres)` → `get_database_schema` →
# `convertSQLToModel(::DataFrameRow)` — is exercised by NOTHING at the unit level.
# This file closes that gap against a real engine:
#
#   1. Edge-case primary keys (VARCHAR / NUMERIC PRIMARY KEY) introspect without
#      crashing and map to an IDField. On PostgreSQL this exercises the
#      `hasfield(field, :max_length/:max_digits)` guards directly — before them,
#      assigning those attributes onto the PK's IDField raised FieldError.
#   2. `register_ignore_tables!` is honoured by the live introspection (the same
#      registry the Nitro extension uses), not just by the hermetic SQLite test.
#
# The file-writing layer (`Model_to_str` / `generate_models_from_db`) already has
# hermetic unit coverage (test/unit/test_importers.jl); here we target the
# introspection core where the real-DB behaviour lives. Fixture tables use a
# `pormg_it_` prefix and are dropped in a `finally`, leaving the schema untouched.
# ==============================================================================

@testset "Schema Importer / Introspection ($(PORMG_DB_FOLDER))" begin
  settings = PormG.config[PORMG_DB_FOLDER]
  pool = settings.connections
  is_pg = adapter_name == "PostgreSQL"

  ddl(sql) = PormG.ConnectionPool.fetch(pool, sql)
  # Child before parent: since #276 SQLite enforces foreign keys, so dropping the parent while the
  # child still references it raises instead of silently succeeding.
  fixtures = ("pormg_it_fk_child", "pormg_it_fk_parent",
              "pormg_it_MixedChild", "pormg_it_MixedParent",
              "pormg_it_natural_key", "pormg_it_numeric_key", "pormg_it_ignored",
              "pormg_it_uniq")
  drop_fixtures() = for t in fixtures
    try; ddl("DROP TABLE IF EXISTS \"$(t)\""); catch; end
  end

  # Adapter-appropriate DDL. The VARCHAR/NUMERIC primary keys only stress the
  # Postgres max_length/max_digits guard; on SQLite they degrade to TEXT/INTEGER
  # (still a valid "PK → IDField, no crash" check on the SQLite introspection path).
  natural_pk_ddl = is_pg ?
    """CREATE TABLE "pormg_it_natural_key" (code VARCHAR(20) PRIMARY KEY, label VARCHAR(100))""" :
    """CREATE TABLE "pormg_it_natural_key" (code TEXT PRIMARY KEY, label TEXT)"""
  numeric_pk_ddl = is_pg ?
    """CREATE TABLE "pormg_it_numeric_key" (id NUMERIC(10,0) PRIMARY KEY, amount NUMERIC(8,2))""" :
    """CREATE TABLE "pormg_it_numeric_key" (id INTEGER PRIMARY KEY, amount REAL)"""
  ignored_ddl = is_pg ?
    """CREATE TABLE "pormg_it_ignored" (id INTEGER PRIMARY KEY, note VARCHAR(50))""" :
    """CREATE TABLE "pormg_it_ignored" (id INTEGER PRIMARY KEY, note TEXT)"""

  # #292 fixture: one parent plus a child carrying one FK per referential action. The SET DEFAULT
  # column has a REAL column default, which is the combination #287 made a hard failure and #291
  # documented a hand-edit remedy for. `fk_o2o` is UNIQUE so both readers build an OneToOneField
  # for it (#417) — it had the identical on_delete omission as ForeignKey.
  fk_parent_ddl = is_pg ?
    """CREATE TABLE "pormg_it_fk_parent" (id BIGINT PRIMARY KEY, label VARCHAR(50))""" :
    """CREATE TABLE "pormg_it_fk_parent" (id INTEGER PRIMARY KEY, label TEXT)"""
  fk_child_ddl = is_pg ?
    """CREATE TABLE "pormg_it_fk_child" (
         id            BIGINT PRIMARY KEY,
         fk_cascade    BIGINT REFERENCES "pormg_it_fk_parent"(id) ON DELETE CASCADE,
         fk_restrict   BIGINT REFERENCES "pormg_it_fk_parent"(id) ON DELETE RESTRICT,
         fk_setnull    BIGINT REFERENCES "pormg_it_fk_parent"(id) ON DELETE SET NULL,
         fk_setdefault BIGINT DEFAULT 1 REFERENCES "pormg_it_fk_parent"(id) ON DELETE SET DEFAULT,
         fk_plain      BIGINT REFERENCES "pormg_it_fk_parent"(id),
         fk_o2o        BIGINT UNIQUE REFERENCES "pormg_it_fk_parent"(id) ON DELETE CASCADE
       )""" :
    """CREATE TABLE "pormg_it_fk_child" (
         id            INTEGER PRIMARY KEY,
         fk_cascade    INTEGER REFERENCES "pormg_it_fk_parent"(id) ON DELETE CASCADE,
         fk_restrict   INTEGER REFERENCES "pormg_it_fk_parent"(id) ON DELETE RESTRICT,
         fk_setnull    INTEGER REFERENCES "pormg_it_fk_parent"(id) ON DELETE SET NULL,
         fk_setdefault INTEGER DEFAULT 1 REFERENCES "pormg_it_fk_parent"(id) ON DELETE SET DEFAULT,
         fk_plain      INTEGER REFERENCES "pormg_it_fk_parent"(id),
         fk_o2o        INTEGER UNIQUE REFERENCES "pormg_it_fk_parent"(id) ON DELETE CASCADE
       )"""

  # #389 fixture: the ONLY mixed-case identifiers in this file. Every other fixture is lowercase,
  # so PostgreSQL's `quote_ident` returns them unquoted and the whole quoting hazard is invisible —
  # which is exactly why the bug survived here. A quoted mixed-case parent PK (`"Id"`) is what the
  # `referenced_primary_keys` aggregate wraps in `"`, and the mixed-case CHILD column (`"ParentId"`)
  # covers the `fk_cols` / `col_name` pairing that has to be normalized in the same change.
  mixed_parent_ddl = is_pg ?
    """CREATE TABLE "pormg_it_MixedParent" ("Id" BIGINT PRIMARY KEY, "Label" VARCHAR(50))""" :
    """CREATE TABLE "pormg_it_MixedParent" ("Id" INTEGER PRIMARY KEY, "Label" TEXT)"""
  mixed_child_ddl = is_pg ?
    """CREATE TABLE "pormg_it_MixedChild" (
         id         BIGINT PRIMARY KEY,
         "ParentId" BIGINT REFERENCES "pormg_it_MixedParent"("Id") ON DELETE CASCADE
       )""" :
    """CREATE TABLE "pormg_it_MixedChild" (
         id         INTEGER PRIMARY KEY,
         "ParentId" INTEGER REFERENCES "pormg_it_MixedParent"("Id") ON DELETE CASCADE
       )"""

  # #318: TWO separate single-column UNIQUEs on one table plus a composite. This is the ONLY place
  # PostgreSQL's `unique_constraints` CTE actually runs, and the two-uniques shape is precisely what
  # it got wrong (it merged both constraints' columns into one per-table array, then rejected both
  # for being length 2). The composite pins the must-NOT-mark half on both backends.
  uniq_ddl = is_pg ?
    """CREATE TABLE "pormg_it_uniq" (
         id BIGINT PRIMARY KEY, slug VARCHAR(60) UNIQUE, token VARCHAR(60) UNIQUE,
         a INT, b INT, plain TEXT, UNIQUE (a, b)
       )""" :
    """CREATE TABLE "pormg_it_uniq" (
         id INTEGER PRIMARY KEY, slug TEXT UNIQUE, token TEXT UNIQUE,
         a INTEGER, b INTEGER, plain TEXT, UNIQUE (a, b)
       )"""

  drop_fixtures()                      # clean slate if a prior run aborted mid-test
  ddl(natural_pk_ddl)
  ddl(numeric_pk_ddl)
  ddl(ignored_ddl)
  ddl(fk_parent_ddl)
  ddl(fk_child_ddl)
  ddl(mixed_parent_ddl)
  ddl(mixed_child_ddl)
  ddl(uniq_ddl)
  # #347: a composite NON-unique index on the same table, deliberately in the REVERSE column order
  # of the composite UNIQUE declared above. Both backends excluded every multi-column index from
  # introspection, so `inspectdb` on a legacy schema silently dropped them; reading them back is
  # what makes `Models.Index` a round trip rather than a one-way declaration. The reversed order is
  # the mutation gate — a reader aggregating by attribute number returns (a, b) here.
  ddl("""CREATE INDEX "pormg_it_uniq_ba_idx" ON "pormg_it_uniq" (b, a)""")
  # …and one composite index PormG must REFUSE to read: a DESC key. PormG indexes carry no per-column
  # order, so reading this back would regenerate an ascending index under the developer's name — the
  # same reinterpretation the Django importer refuses on `Index(fields=["-year"])`.
  #
  # The LEADING column is descending on purpose. That is the case the PostgreSQL reader got wrong:
  # `indoption` is an `int2vector` with lower bound 0 while `WITH ORDINALITY` counts from 1, so an
  # off-by-one subscript examined the NEXT column's flags and missed a descending first column
  # entirely — with no false positives, so every other test stayed green.
  ddl("""CREATE INDEX "pormg_it_uniq_desc_idx" ON "pormg_it_uniq" (b DESC, a)""")
  # PostgreSQL only: three more shapes that must not regenerate as a plain b-tree, each reached by a
  # different per-column catalog vector.
  #   opc  — a non-default operator class (`indclass`), the other half of the same subscript bug.
  #   nf   — ASCENDING but `NULLS FIRST` (`indoption` = 2). Bit 0 alone is not enough: DESC implies
  #          NULLS FIRST, so a descending key measures 3 and a `& 1` mask lets this one through,
  #          re-emitting it as NULLS LAST.
  #   coll — an explicit `COLLATE` (`indcollation`), the PostgreSQL twin of SQLite's non-BINARY
  #          `coll` filter. Without it the two backends disagree on the same schema.
  if is_pg
    ddl("""CREATE INDEX "pormg_it_uniq_opc_idx"  ON "pormg_it_uniq" (plain text_pattern_ops, slug)""")
    ddl("""CREATE INDEX "pormg_it_uniq_nf_idx"   ON "pormg_it_uniq" (b NULLS FIRST, a)""")
    ddl("""CREATE INDEX "pormg_it_uniq_coll_idx" ON "pormg_it_uniq" (plain COLLATE "C", slug)""")
  end

  saved_ignore = copy(PormG._EXTRA_IGNORE_TABLES[])
  try
    # ── 1. Introspection survives edge-case primary keys (Finding 3.1) ──────
    # Not throwing IS the regression guard: before the hasfield guards, a
    # VARCHAR/NUMERIC PK crashed convertSQLToModel on the Postgres path.
    models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_natural_key", "pormg_it_numeric_key"])
    by_name = Dict(lowercase(string(m.name)) => m for m in models)

    @test haskey(by_name, "pormg_it_natural_key")
    @test haskey(by_name, "pormg_it_numeric_key")

    # #409: a sized textual key is reconstructed as the CharField it actually is, against a REAL
    # engine. It used to flatten to IDField, which meant a model declaring
    # `code = CharField(primary_key=true, max_length=20)` could never equal its own live table and
    # `makemigrations` proposed the same ALTER on every run. This is the live half of
    # test/unit/test_key_type_round_trip.jl.
    #
    # Both backends, deliberately: the PostgreSQL fixture is `VARCHAR(20)` and the SQLite one is
    # `TEXT`, and the two readers reach the reconstruction by different routes (`col_type ==
    # "varchar"` with a parsed `max_length` vs. `base_type == "TEXT"` with a `(n)` suffix). The
    # SQLite fixture declares no length, so it exercises the documented LENGTHLESS fallback rather
    # than the reconstruction — which is the behaviour that would otherwise be untested anywhere.
    code_field = by_name["pormg_it_natural_key"].fields["code"]
    if is_pg
      @test code_field isa PormG.Models.sCharField
      @test code_field.primary_key
      @test code_field.max_length == 20
      # The COMPUTED unique marker, not a hardcoded `true`: `CharField` defaults `unique=false` and
      # `:unique` has no exemption in `_NON_SCHEMA_FIELD_ATTRS`, so hardcoding it here would keep a
      # plain declaration permanently unequal — the #334 trap, in a new place.
      @test code_field.unique == false
    else
      # `code TEXT PRIMARY KEY` — no declared length, so there is no CharField to reconstruct it as
      # (`CharField()` would invent `max_length = 250` and never match the live bare `TEXT`), and it
      # keeps the IDField fallback. Documented in `convertSQLToModel`, not an oversight.
      @test code_field isa PormG.Models.sIDField
    end

    # NUMERIC keeps the IDField fallback on both backends: `DecimalField` refuses `primary_key`
    # outright, so there is nothing to reconstruct it as. Not throwing is still the guard here.
    @test by_name["pormg_it_numeric_key"].fields["id"] isa PormG.Models.sIDField

    # A non-PK sized column keeps its max_length — the guard skipped only the PK.
    if is_pg
      @test by_name["pormg_it_natural_key"].fields["label"].max_length == 100
    end

    # ── 2. register_ignore_tables! honoured by live introspection (Finding 4) ──
    PormG.register_ignore_tables!(["pormg_it_ignored"])
    models2 = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_ignored", "pormg_it_natural_key"])
    names2 = Set(lowercase(string(m.name)) for m in models2)

    @test "pormg_it_natural_key" in names2     # ordinary table still imported
    @test !("pormg_it_ignored" in names2)      # registered table skipped on the real path

    # ── 3. FK round-trip: on_delete AND the column default survive (#292) ────
    # The two halves of the bug were mirror images. PostgreSQL never QUERIED the delete rule, so
    # every FK introspected as "no action" and a migration generated from the model silently
    # dropped the cascade. SQLite carried the action but dropped the default, so a SET DEFAULT FK
    # produced a model that #287 rejects at `set_models` — and regenerating produced the identical
    # broken file. Run against a real engine on both backends because the PostgreSQL half is a SQL
    # query change that nothing hermetic can exercise.
    fk_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_fk_parent", "pormg_it_fk_child"])
    fk_by_name = Dict(lowercase(string(m.name)) => m for m in fk_models)
    @test haskey(fk_by_name, "pormg_it_fk_child")
    child = fk_by_name["pormg_it_fk_child"]

    # Each declared action comes back as the PormG sentinel it was declared with.
    @test child.fields["fk_cascade"].on_delete === PormG.Models.CASCADE
    @test child.fields["fk_restrict"].on_delete === PormG.Models.RESTRICT
    @test child.fields["fk_setnull"].on_delete === PormG.Models.SET_NULL
    @test child.fields["fk_setdefault"].on_delete === PormG.Models.SET_DEFAULT

    # A foreign key that declared NO action must not gain one. Both backends store this
    # indistinguishably from an explicit NO ACTION, so introspecting it as DO_NOTHING would stamp
    # an on_delete onto every plain FK in every regenerated model file.
    @test child.fields["fk_plain"].on_delete === nothing

    # The SQLite half: SET DEFAULT keeps the column default, which is exactly what makes the pair
    # self-consistent enough to register.
    @test child.fields["fk_setdefault"].default == 1

    # OneToOneField had the identical omission and is fixed with ForeignKey.
    #
    # Asserted on BOTH backends since #417. It was PostgreSQL-only under #318, which withheld the
    # O2O on SQLite because PormG could not materialize one (`Dialect._get_column_type` had no
    # branch for it and the inline FK clause was gated on `isa sForeignKey`), so returning one
    # regenerated `TEXT` with no foreign key where a plain ForeignKey regenerated `INTEGER` + the
    # constraint. #408 fixed both halves; #417 took the decision. Dropping the `is_pg` guard here IS
    # the cross-engine assertion — the fixture DDL above creates the identical column on each.
    @test child.fields["fk_o2o"] isa PormG.Models.sOneToOneField
    @test child.fields["fk_o2o"].on_delete === PormG.Models.CASCADE
    # A one-to-one, not the pk-fk shape #409 covers — `fk_o2o` is UNIQUE but the table's key is `id`.
    @test !child.fields["fk_o2o"].primary_key
    # The uniqueness itself is read on both backends, which is what #318 fixed.
    @test child.fields["fk_o2o"].unique
    # Control: the non-unique foreign keys in the same table must NOT have been promoted.
    @test child.fields["fk_plain"] isa PormG.Models.sForeignKey
    @test !(child.fields["fk_plain"] isa PormG.Models.sOneToOneField)

    # ── 3b. Single-column UNIQUE round-trips; composite does not (#318) ──────
    # Introspection never read UNIQUE back, so every `unique=true` field diffed as changed on every
    # makemigrations — forever. This is the ONLY coverage that executes PostgreSQL's
    # `unique_constraints` CTE, which is where the PG half of the bug lived: it grouped by TABLE, so
    # `pormg_it_uniq`'s two separate single-column UNIQUEs merged into one length-2 array and the
    # consumer's `array_length(...) = 1` guard rejected BOTH.
    uniq_models = PormG.Migrations.convert_schema_to_models(pool)
    uniq = Dict(lowercase(string(m.name)) => m for m in uniq_models)["pormg_it_uniq"]

    @test uniq.fields["slug"].unique
    @test uniq.fields["token"].unique     # the mutation gate for the per-table-array bug
    @test !uniq.fields["plain"].unique    # no over-marking

    # Composite uniqueness is a model-level UniqueConstraint (#19), never a per-field attribute —
    # marking a member would churn in the opposite direction. Excluded on both backends: PostgreSQL
    # by `array_length(conkey,1) = 1`, SQLite by `HAVING COUNT(*) = 1`.
    @test !uniq.fields["a"].unique
    @test !uniq.fields["b"].unique

    # ── 3c. Composite NON-unique indexes round-trip as Models.Index (#347) ──
    # The multi-column half of the same index set, which both readers used to discard by arity.
    # This is the only coverage that executes PostgreSQL's `_pg_composite_indexes` query at all.
    @test haskey(uniq.cache, "composite_indexes")
    live_ix = uniq.cache["composite_indexes"]["indexes"]
    live_ix_names = [i.name for i in live_ix]
    # EXACTLY one: the composite UNIQUE above must not also arrive here. On PostgreSQL it is a
    # `pg_constraint` row whose backing index is `indisunique`; on SQLite `il."unique" = 1`. Either
    # filter failing would re-declare a uniqueness guarantee as a plain index.
    @test length(live_ix) == 1
    # Named individually as well, so a failure says WHICH shape leaked rather than only that the
    # count moved. The DESC one is the discriminating case for the `indoption` subscript.
    @test !("pormg_it_uniq_desc_idx" in live_ix_names)
    if is_pg
      @test !("pormg_it_uniq_opc_idx" in live_ix_names)
      @test !("pormg_it_uniq_nf_idx" in live_ix_names)     # ASC + NULLS FIRST: indoption == 2
      @test !("pormg_it_uniq_coll_idx" in live_ix_names)   # explicit COLLATE: indcollation differs
    end
    @test live_ix[1].name == "pormg_it_uniq_ba_idx"
    @test live_ix[1].fields == ["b", "a"]        # declared order, not attribute order
    # Members are not marked `db_index` either — the single-column reader must stay disjoint.
    @test !uniq.fields["a"].db_index
    @test !uniq.fields["b"].db_index

    # …and it survives the model → source → module round trip a user actually performs, which is
    # the whole point of reading it back: `inspectdb` writes through `Model_to_str`.
    uniq_src = PormG.Models.Model_to_str(uniq)
    @test occursin("indexes = [Models.Index(fields = (\"b\", \"a\",), name = \"pormg_it_uniq_ba_idx\")]", uniq_src)
    uniq_mod = Module()
    Core.eval(uniq_mod, :(import PormG.Models))
    uniq_reloaded = Core.eval(uniq_mod, Meta.parse(uniq_src))
    @test uniq_reloaded.cache["composite_indexes"]["indexes"][1].fields == ["b", "a"]

    # ── 3d. Mixed-case FK/PK identifiers survive quote_ident (#389) ──────────
    # PostgreSQL aggregates `fk_cols`, `fk_tables` and `referenced_primary_keys` through
    # `quote_ident`, so a mixed-case name arrives with the `"` characters as part of the string.
    # #360 de-quoted the table half; the referenced PK stayed quoted and landed verbatim on
    # `pk_field` (an introspected field's `.to` is a String binding, so `fk_target_column` returns
    # it unchanged). That one value made `Dialect.add_foreign_key` emit
    # `REFERENCES "parent"(""Id"")` — two quote pairs, because the caller adds one around a value
    # that already carries one — made `_compare_field_foreign_key` report the key as changed on
    # every makemigrations, and made the query builder throw `InvalidValueError`
    # (before #394; a physical column is escaped rather than validated now).
    #
    # This is the live half of test/unit/test_introspection_guards.jl's #389 block. It runs on both
    # backends even though only PostgreSQL has the hazard: SQLite reads FK metadata from
    # `PRAGMA foreign_key_list`, whose identifiers come back raw, so this pins that the two engines
    # agree on the same schema rather than assuming it.
    mixed_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_MixedParent", "pormg_it_MixedChild"])
    mixed_by_name = Dict(lowercase(string(m.name)) => m for m in mixed_models)

    @test haskey(mixed_by_name, "pormg_it_mixedchild")
    @test haskey(mixed_by_name, "pormg_it_mixedparent")
    mixed_child  = mixed_by_name["pormg_it_mixedchild"]
    mixed_parent = mixed_by_name["pormg_it_mixedparent"]

    # The parent's mixed-case PRIMARY KEY is detected as the key. `pk_set` is `quote_ident`-ed too,
    # and is compared against `col_name`; normalizing one without the other leaves the table keyless.
    @test haskey(mixed_parent.fields, "Id")
    @test mixed_parent.fields["Id"] isa PormG.Models.sIDField

    # The mixed-case CHILD column is still recognised as a foreign key — the mutation gate for
    # moving `fk_cols` and `col_name` together.
    @test haskey(mixed_child.fields, "ParentId")
    @test mixed_child.fields["ParentId"] isa PormG.Models.sForeignKey

    # THE defect: the referenced parent column, unquoted, both raw and resolved.
    @test mixed_child.fields["ParentId"].pk_field == "Id"
    @test PormG.Models.fk_target_column(mixed_child.fields["ParentId"]) == "Id"

    # The #360 half still holds for a mixed-case parent table.
    @test mixed_child.fields["ParentId"].to_table == "pormg_it_MixedParent"
    @test mixed_child.fields["ParentId"].on_delete === PormG.Models.CASCADE

    # ── 4. The regenerated module registers via set_models (#287/#291) ───────
    # THE regression assertion. Before #292 this threw ModelDefinitionError ("declares on_delete
    # SET_DEFAULT but has no default"), with no way out but editing the generated source by hand —
    # the remedy #291 had to document. Goes through `Model_to_str`, so it also proves the default
    # and the action survive the model → source → module round trip a user actually performs.
    instructions = [PormG.Models.Model_to_str(fk_by_name[t])
                    for t in ("pormg_it_fk_parent", "pormg_it_fk_child")]
    src = join(instructions, "\n\n")
    @test occursin("SET_DEFAULT", src)          # the action reached the generated source…
    @test occursin(r"default\s*=\s*1", src)     # …and so did the default that makes it valid

    mod_name = "PormGIt292Models"
    generated = include_string(Main, """
      module $(mod_name)
      import PormG.Models
      import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING, PROTECT
      $(src)
      end
      """)
    try
      # EVERY access to the generated module goes through `invokelatest`, and that is load-bearing
      # rather than decoration. `include_string` defined the module DURING this call, so its
      # bindings are newer than the world age this block is running in — the same world-age
      # constraint `set_models` handles internally and that pins the Julia 1.12 floor (#211).
      #
      # Getting this wrong is silent, not loud. Without `invokelatest` here, `set_models`'
      # `get_all_models(generated)` sees ZERO models, so it iterates nothing, validates nothing and
      # returns `nothing` anyway — the assertion passes while checking absolutely nothing. Verified
      # by mutation: with a plain call, deleting the `default=` fix from the SQLite FK branch left
      # this line green.
      #
      # `set_models` is where #287's SET_DEFAULT guard lives, so this is the real check rather than
      # a re-implementation of it: it must not throw.
      @test Base.invokelatest(PormG.Models.set_models, generated, PORMG_DB_FOLDER) === nothing

      # …and registration preserved the action rather than merely tolerating it. `Model_to_str`
      # emits the binding as `uppercasefirst(model.name)`, so derive the name from the model
      # rather than hard-coding a spelling that would drift.
      registered = Base.invokelatest(getglobal, generated, Symbol(uppercasefirst(child.name)))

      # PROOF THAT `set_models` ACTUALLY RAN OVER THESE MODELS, asserted through side effects it
      # leaves behind. A separate `get_all_models(generated)` call cannot do this job: it resolves
      # in the latest world either way and returns 2 even when `set_models` iterated nothing, so it
      # would pass while the assertion above was still vacuous. Both fields below are `nothing`/
      # `false` on a no-op registration and set on a real one — measured both ways.
      @test registered.connect_key == PORMG_DB_FOLDER
      # Doubles as coverage for `resolve_fk_target!`: registration resolves the FK's string target
      # to the actual parent model object.
      @test registered.fields["fk_cascade"].to isa PormG.PormGModel
      @test registered.fields["fk_setdefault"].on_delete === PormG.Models.SET_DEFAULT
      @test registered.fields["fk_setdefault"].default == 1
      @test registered.fields["fk_cascade"].on_delete === PormG.Models.CASCADE
    finally
      # `set_models` records the module for lazy self-healing; drop it so a later test in the same
      # session cannot resolve models through this throwaway module.
      delete!(PormG.Models.REGISTERED_MODULES, generated)
    end

    # ── 5. BinaryField byte bounds survive the round trip (#296) ─────────────
    # `bytea`/`BLOB` take no length parameter, so a BinaryField's `max_length` exists in the
    # schema ONLY as a CHECK constraint. If introspection cannot read it back, every
    # `makemigrations` proposes the same ALTER forever — the phantom drift this recovery exists
    # to prevent.
    #
    # Deliberately routed through `convert_schema_to_models`, the entry point `makemigrations`
    # actually calls. The unit coverage exercises the SQLite *string* parser
    # (`convertSQLToModel(::String)`), which the production SQLite flow never reaches — it goes
    # through the PRAGMA path instead. Only a live run covers the wiring on both backends: a
    # `substring(… from '<= ([0-9]+)')` CTE on PostgreSQL, a regex over the stored CREATE TABLE
    # text on SQLite. Two entirely separate implementations of one contract.
    bin_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["field_validation_scratch"])
    bin_by_name = Dict(lowercase(string(m.name)) => m for m in bin_models)
    @test haskey(bin_by_name, "field_validation_scratch")
    scratch_model = bin_by_name["field_validation_scratch"]

    # Both columns come back as BinaryField — i.e. the column type itself round-trips, which is
    # what a TEXT fallback would break.
    @test scratch_model.fields["blob_payload"] isa PormG.Models.sBinaryField
    @test scratch_model.fields["bounded_blob"] isa PormG.Models.sBinaryField

    # The bound itself. `8` is the value declared on the model in db_2/db_sl models.jl; reading
    # back anything else (including `nothing`) is exactly the phantom-drift failure.
    @test scratch_model.fields["bounded_blob"].max_length == 8
    # And an unbounded binary column must NOT acquire a bound — the mirror-image drift, where
    # every regeneration would add a CHECK the user never asked for.
    @test scratch_model.fields["blob_payload"].max_length === nothing
  finally
    PormG._EXTRA_IGNORE_TABLES[] = saved_ignore   # never leak registry state
    drop_fixtures()
  end
end
