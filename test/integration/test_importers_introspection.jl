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

# Standalone guard, added with #414/#415. Every fixture in this file is created and dropped by the
# file itself, and the one table it borrows (`field_validation_scratch`, section 5) comes from the
# bootstrap — so against an ALREADY-BOOTSTRAPPED database this file runs on its own:
#
#   julia --project=test/integration test/integration/test_importers_introspection.jl
#   PORMG_DB=db_sl julia --project=test/integration test/integration/test_importers_introspection.jl
#
# It used to be the one file in the suite with no guard at all, which forced every change reaching
# introspection through the full `runtests.jl` prologue (~170 DDL statements plus a fixture reseed)
# to see a single assertion. A slice still does NO DDL and NO reseed: bootstrap the target database
# with a full run first.
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Schema Importer / Introspection ($(PORMG_DB_FOLDER))" begin
  settings = PormG.config[PORMG_DB_FOLDER]
  pool = settings.connections
  is_pg = adapter_name == "PostgreSQL"

  ddl(sql) = PormG.ConnectionPool.fetch(pool, sql)
  # Child before parent: since #276 SQLite enforces foreign keys, so dropping the parent while the
  # child still references it raises instead of silently succeeding.
  fixtures = ("pormg_it_fk_child", "pormg_it_fk_parent",
              "pormg_it_spaced",
              "pormg_it_MixedChild", "pormg_it_MixedParent",
              "pormg_it_comp_child", "pormg_it_comp_parent",
              "pormg_it_uq_child", "pormg_it_uq_parent",
              "pormg_it_nopk_child", "pormg_it_nopk_parent",
              "pormg_it_natural_key", "pormg_it_numeric_key", "pormg_it_ignored",
              "pormg_it_uniq",
              # #455, child before parent as above. The parent's NAME carries the comma on purpose:
              # that is what tore `foreign_tables`, which is a different aggregate from `columns`.
              "pormg_it_comma_child", "pormg_it_comma, parent", "pormg_it_comma_key",
              # #472: expression defaults on NON-text columns, which is the shape section 3i
              # deliberately avoided while the generic arm could still abort the read.
              "pormg_it_expr_defaults")
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
  # so the quoting hazard was invisible in all of them — which is exactly why the bug survived here.
  # When #389 landed, the schema query wrapped every aggregated identifier in `quote_ident`, and a
  # mixed-case parent PK (`"Id"`) is one it quotes; the mixed-case CHILD column (`"ParentId"`)
  # covered the `fk_cols` / `col_name` pairing that had to be normalized in the same change. Since
  # #455 nothing is quoted on the wire, so what this fixture pins is the outcome rather than the
  # transform: one identifier, one spelling, on every side.
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

  # #414 fixture: an identifier CONTAINING A SPACE, on the two axes that used to disagree about it.
  # The PostgreSQL `columns` aggregate WAS `quote_ident(name) || ' ' || format_type(…)` and the
  # reader split it on `" "`, so `"Parent Id" bigint` was torn into the phantom name `"Parent` and
  # the non-type `Id"`. `fk_map`, `pk_set` and `index_map` all keyed on names that survived a space
  # (they split on `", "`, or came from the one RAW aggregate), so the relation was LOST and every
  # `makemigrations` proposed `ADD COLUMN "\"Parent"` plus a DROP of the real column. #455 replaced
  # that wire format with JSON, so neither separator exists any more — see section 3i.
  #
  # `"Parent Id"` is the FK axis and `"driver ref"` the index axis; the latter is the exact spelling
  # #394's `Odd_identifier_scratch` fixture carries, and the reason that fixture could not use it as
  # a `db_column` until now. Reuses `pormg_it_MixedParent` as the parent so the spaced CHILD column
  # and a quoted mixed-case referenced column are exercised in one constraint.
  #
  # Both backends: SQLite reads `PRAGMA` output raw and was never affected, so asserting there is
  # what makes this a cross-engine agreement rather than an assumption.
  spaced_ddl = is_pg ?
    """CREATE TABLE "pormg_it_spaced" (
         id           BIGINT PRIMARY KEY,
         "driver ref" VARCHAR(30),
         "Parent Id"  BIGINT REFERENCES "pormg_it_MixedParent"("Id") ON DELETE CASCADE
       )""" :
    """CREATE TABLE "pormg_it_spaced" (
         id           INTEGER PRIMARY KEY,
         "driver ref" TEXT,
         "Parent Id"  INTEGER REFERENCES "pormg_it_MixedParent"("Id") ON DELETE CASCADE
       )"""

  # #415 fixture A: a foreign key that references a NON-PRIMARY-KEY unique column. Legal wherever
  # that column carries a UNIQUE constraint, and the shape the old CTE could not express at all —
  # it read the referenced column from the parent's PRIMARY KEY INDEX, never from `con.confkey`,
  # so this introspected as pointing at `id`. `pk_field` was then wrong and so was every consumer
  # of it, and the DDL PormG emitted named a different column than the live constraint does.
  uq_parent_ddl = is_pg ?
    """CREATE TABLE "pormg_it_uq_parent" (id BIGINT PRIMARY KEY, ukey VARCHAR(20) UNIQUE, label VARCHAR(50))""" :
    """CREATE TABLE "pormg_it_uq_parent" (id INTEGER PRIMARY KEY, ukey TEXT UNIQUE, label TEXT)"""
  uq_child_ddl = is_pg ?
    """CREATE TABLE "pormg_it_uq_child" (
         id         BIGINT PRIMARY KEY,
         parent_key VARCHAR(20) REFERENCES "pormg_it_uq_parent"(ukey) ON DELETE CASCADE
       )""" :
    """CREATE TABLE "pormg_it_uq_child" (
         id         INTEGER PRIMARY KEY,
         parent_key TEXT REFERENCES "pormg_it_uq_parent"(ukey) ON DELETE CASCADE
       )"""

  # #415 fixture B: a COMPOSITE-KEYED parent carrying both remaining shapes on one child table.
  #
  #   * `parent_a` — a SINGLE-column FK into that parent. The old CTE joined the parent's PK index
  #     with `attnum = ANY(pk_idx.indkey)`, yielding one row per parent key column and multiplying
  #     every aggregate; the LAST fanned-out entry won the `fk_map[...]` assignment. The referenced
  #     column is `a` and the parent's key is `(a, b)`, so the pre-fix answer was `b` — the fixture
  #     is ordered that way deliberately, since a parent keyed `(b, a)` would have made the wrong
  #     answer coincide with the right one and the test would pass on a defect.
  #   * `(ca, cb)` — a genuine MULTI-column FK, which PormG has no field type for and now skips on
  #     both engines rather than splitting into two plausible-looking single-column relations.
  #
  # Both on ONE table on purpose: `parent_a` is the control proving the skip is per-CONSTRAINT, not
  # per-table. `a` carries its own UNIQUE because a single-column FK requires one.
  comp_parent_ddl = is_pg ?
    """CREATE TABLE "pormg_it_comp_parent" (
         a BIGINT UNIQUE, b BIGINT, label VARCHAR(50), PRIMARY KEY (a, b)
       )""" :
    """CREATE TABLE "pormg_it_comp_parent" (
         a INTEGER UNIQUE, b INTEGER, label TEXT, PRIMARY KEY (a, b)
       )"""
  comp_child_ddl = is_pg ?
    """CREATE TABLE "pormg_it_comp_child" (
         id       BIGINT PRIMARY KEY,
         parent_a BIGINT REFERENCES "pormg_it_comp_parent"(a) ON DELETE SET NULL,
         ca       BIGINT,
         cb       BIGINT,
         FOREIGN KEY (ca, cb) REFERENCES "pormg_it_comp_parent"(a, b) ON DELETE CASCADE
       )""" :
    """CREATE TABLE "pormg_it_comp_child" (
         id       INTEGER PRIMARY KEY,
         parent_a INTEGER REFERENCES "pormg_it_comp_parent"(a) ON DELETE SET NULL,
         ca       INTEGER,
         cb       INTEGER,
         FOREIGN KEY (ca, cb) REFERENCES "pormg_it_comp_parent"(a, b) ON DELETE CASCADE
       )"""

  # #415 fixture C: a parent with NO PRIMARY KEY, only a UNIQUE column. Legal on both engines — a
  # referenced column needs uniqueness, not the key — and it used to be INVISIBLE to PostgreSQL
  # introspection: the old CTE joined `pg_index ... AND pk_idx.indisprimary` as an INNER join, so a
  # keyless parent matched no row and the whole foreign key dropped out of the aggregate. The child
  # column then introspected as an ordinary integer with no relation, while SQLite (whose
  # `PRAGMA foreign_key_list` never consulted a primary key) reported it correctly. Dropping that
  # join is what makes the two engines agree, and this is the fixture that says so.
  nopk_parent_ddl = is_pg ?
    """CREATE TABLE "pormg_it_nopk_parent" (ukey VARCHAR(20) UNIQUE, label VARCHAR(50))""" :
    """CREATE TABLE "pormg_it_nopk_parent" (ukey TEXT UNIQUE, label TEXT)"""
  nopk_child_ddl = is_pg ?
    """CREATE TABLE "pormg_it_nopk_child" (
         id         BIGINT PRIMARY KEY,
         parent_key VARCHAR(20) REFERENCES "pormg_it_nopk_parent"(ukey) ON DELETE RESTRICT
       )""" :
    """CREATE TABLE "pormg_it_nopk_child" (
         id         INTEGER PRIMARY KEY,
         parent_key TEXT REFERENCES "pormg_it_nopk_parent"(ukey) ON DELETE RESTRICT
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
  ddl(spaced_ddl)
  # The index axis of #414. NOT on the UNIQUE column: the `indexes` CTE excludes `indisunique`, so a
  # unique column's backing index never reaches `index_map` and the assertion would be vacuous.
  ddl("""CREATE INDEX "pormg_it_spaced_ref_idx" ON "pormg_it_spaced" ("driver ref")""")
  ddl(uq_parent_ddl)
  ddl(uq_child_ddl)
  ddl(comp_parent_ddl)
  ddl(comp_child_ddl)
  ddl(nopk_parent_ddl)
  ddl(nopk_child_ddl)
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

  # ── #455 fixtures: a comma-space is a legal substring of every identifier and of any
  # `pg_get_expr` DEFAULT, so the old `array_to_string(array_agg(...), ', ')` aggregates could be
  # torn BY THEIR OWN DATA. Four axes across two tables, because the four aggregates failed
  # DIFFERENTLY and no single fixture reaches all four:
  #
  #   * `columns`      — the real column vanished and two phantoms appeared (#414's failure, new
  #                      trigger), and `makemigrations` proposed add-phantom + drop-real forever.
  #   * `primary_keys` — tore on the SAME name as `columns`, so both sides agreed on both WRONG
  #                      names and BOTH phantoms came back marked as keys. Its own table below,
  #                      since the two tears have to coincide.
  #   * `foreign_keys` — six aggregates zipped POSITIONALLY. Measured on `main`: with the comma in
  #                      the PARENT TABLE name only, `columns` parses cleanly and `plain_id` still
  #                      comes back with `to_table == "parent\""`. `plain_parent` never appears.
  #                      That is why `plain_id` is declared AFTER the comma-named FK.
  #   * `indexes`      — the same zip; a shifted index NAME reaches `planner._drop_index`.
  #
  # Both engines: SQLite reads PRAGMA output raw and was never affected, which is what makes this
  # an AGREEMENT rather than an assumption — the same framing as the #414 spaced-identifier fixture.
  #
  # Every expression default here sits on a TEXT column deliberately, and that is now a scoping
  # choice rather than a constraint: while #455 was written the generic (non-FK) arm had no
  # `_fk_default_or_warn` equivalent, so an expression default on a TYPED column aborted the whole
  # read for reasons unrelated to #455. #472 closed that (`_field_or_drop_default`) and covers the
  # typed shape in its own fixture below — these columns stay TEXT so this section keeps testing
  # the aggregate delimiters it is about, with the default's VALUE still asserted.
  ddl(is_pg ?
      """CREATE TABLE "pormg_it_comma, parent" (
           id BIGINT PRIMARY KEY,
           "Ref, Key" VARCHAR(20) UNIQUE,
           label VARCHAR(50))""" :
      """CREATE TABLE "pormg_it_comma, parent" (
           id INTEGER PRIMARY KEY,
           "Ref, Key" TEXT UNIQUE,
           label TEXT)""")

  ddl(is_pg ?
      """CREATE TABLE "pormg_it_comma_child" (
           id BIGINT PRIMARY KEY,
           "Race, Total" VARCHAR(20) REFERENCES "pormg_it_comma, parent"("Ref, Key") ON DELETE CASCADE,
           plain_id      VARCHAR(20) REFERENCES "pormg_it_comma, parent"("Ref, Key") ON DELETE SET NULL,
           "Idx, Col"    VARCHAR(30),
           note          TEXT NOT NULL DEFAULT concat('a'::text, 'b'::text),
           team          TEXT DEFAULT 'Ferrari, Scuderia')""" :
      """CREATE TABLE "pormg_it_comma_child" (
           id INTEGER PRIMARY KEY,
           "Race, Total" TEXT REFERENCES "pormg_it_comma, parent"("Ref, Key") ON DELETE CASCADE,
           plain_id      TEXT REFERENCES "pormg_it_comma, parent"("Ref, Key") ON DELETE SET NULL,
           "Idx, Col"    TEXT,
           note          TEXT NOT NULL DEFAULT 'ab',
           team          TEXT DEFAULT 'Ferrari, Scuderia')""")

  ddl("""CREATE INDEX "pormg_it_comma_idx" ON "pormg_it_comma_child" ("Idx, Col")""")

  # The PK axis needs its own table: `pk_cols` and `columns` tore on the same name, so the two sides
  # agreed on the same wrong names and the table came back with TWO phantom keys and no real one.
  ddl(is_pg ?
      """CREATE TABLE "pormg_it_comma_key" ("Key, Col" BIGINT PRIMARY KEY, label VARCHAR(20))""" :
      """CREATE TABLE "pormg_it_comma_key" ("Key, Col" INTEGER PRIMARY KEY, label TEXT)""")

  # #472: expression defaults on columns that are NOT text — the shape that aborted the entire
  # `convert_schema_to_models` read, and therefore `inspectdb` and `makemigrations`, over a single
  # column. `DEFAULT now()` on a timestamptz is the most common expression default in existence,
  # so this is what pointing PormG at a third-party schema actually looks like.
  #
  # `ok` and `note` are controls in the SAME table: a representable default and a text column must
  # be unaffected by a sibling column's failure, which no per-table assertion could show if the
  # read aborted. The SQLite spellings are the same shapes in that engine's dialect (it has no
  # `now()` or `gen_random_uuid()`); `u` is PostgreSQL-only because SQLite has no UUID type.
  #
  # `note_expr` is #475's shape and the one this table deliberately lacked: a TEXTUAL column whose
  # default is an EXPRESSION. It is the case that used to be silent — `TextField` accepts any
  # `String`, so the expression was kept as a quoted literal and no warning was emitted — which is
  # exactly why a live fixture is worth having for it. The PostgreSQL spelling is `concat(...)`
  # rather than `now()` because PostgreSQL REFUSES `text DEFAULT now()`: there is no implicit cast
  # from timestamptz to text, so the fixture would fail to create.
  ddl(is_pg ?
      """CREATE TABLE "pormg_it_expr_defaults" (
           id BIGINT PRIMARY KEY,
           created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
           d          DATE DEFAULT CURRENT_DATE,
           n          INTEGER DEFAULT (random() * 10)::integer,
           u          UUID DEFAULT gen_random_uuid(),
           ok         INTEGER DEFAULT 5,
           note       TEXT DEFAULT 'Ferrari',
           note_expr  TEXT DEFAULT concat('a'::text, 'b'::text))""" :
      """CREATE TABLE "pormg_it_expr_defaults" (
           id INTEGER PRIMARY KEY,
           created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
           d          DATE DEFAULT CURRENT_DATE,
           n          INTEGER DEFAULT (abs(random()) % 10),
           ok         INTEGER DEFAULT 5,
           note       TEXT DEFAULT 'Ferrari',
           note_expr  TEXT DEFAULT CURRENT_TIMESTAMP)""")

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

    # ── 3d. Mixed-case FK/PK identifiers keep one spelling on every side (#389) ──────────
    # PostgreSQL used to aggregate `fk_cols`, `fk_tables` and `referenced_primary_keys` through
    # `quote_ident`, so a mixed-case name arrived with the `"` characters as part of the string.
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

    # The parent's mixed-case PRIMARY KEY is detected as the key. `pk_set` and `col_name` come from
    # two different aggregates and are compared to each other, so they have to agree about spelling;
    # they used to agree only because both were `quote_ident`-ed, and normalizing one without the
    # other left the table keyless. Both are raw since #455.
    @test haskey(mixed_parent.fields, "Id")
    @test mixed_parent.fields["Id"] isa PormG.Models.sIDField

    # The mixed-case CHILD column is still recognised as a foreign key. `fk_map`'s keys and the
    # column name come from two different aggregates and are compared to each other, so this is the
    # mutation gate for any change that normalizes one side without the other — it was the
    # `fk_cols` / `col_name` de-quoting pair in #389, and it is the raw-on-both-sides contract now.
    @test haskey(mixed_child.fields, "ParentId")
    @test mixed_child.fields["ParentId"] isa PormG.Models.sForeignKey

    # THE defect: the referenced parent column, unquoted, both raw and resolved.
    @test mixed_child.fields["ParentId"].pk_field == "Id"
    @test PormG.Models.fk_target_column(mixed_child.fields["ParentId"]) == "Id"

    # The #360 half still holds for a mixed-case parent table.
    @test mixed_child.fields["ParentId"].to_table == "pormg_it_MixedParent"
    @test mixed_child.fields["ParentId"].on_delete === PormG.Models.CASCADE

    # ── 3e. An identifier containing a SPACE survives the columns parse (#414) ──
    # THE live half of this issue, and the only one that executes the PostgreSQL `columns`
    # aggregate. The reader split that aggregate on `" "` to separate the name from the type, so a
    # spaced identifier was destroyed before any de-quoting could help — the column arrived under
    # the phantom name `"Parent` (the leading quote survived, because the de-quoter correctly
    # refused to strip a lone unbalanced one), its type read as `Id"` so it degraded to `TextField`,
    # and the foreign key was LOST because `fk_map`'s key — from an aggregate split on `", "` — was the
    # correct `Parent Id` and no longer matched.
    #
    # Since #394 this was the last layer where a spaced `db_column` broke; `Dialect.field_to_column`
    # escapes it in DDL and `safe_column_identifier` renders it in queries. Asserted on BOTH engines
    # because SQLite was never affected — that is what makes this an agreement rather than an
    # assumption, and it is the same PG/SQLite divergence #414 reports.
    spaced_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_spaced", "pormg_it_MixedParent"])
    spaced = Dict(lowercase(string(m.name)) => m for m in spaced_models)["pormg_it_spaced"]

    # Exact key set: the phantom name must not appear under ANY spelling, and the real names must
    # be the only ones present. A bare `haskey` would pass while a phantom sat beside it.
    @test Set(keys(spaced.fields)) == Set(["id", "driver ref", "Parent Id"])

    # The FK axis — the relation, not the TextField the torn type produced.
    @test spaced.fields["Parent Id"] isa PormG.Models.sForeignKey
    @test spaced.fields["Parent Id"].pk_field == "Id"
    @test spaced.fields["Parent Id"].to_table == "pormg_it_MixedParent"
    @test spaced.fields["Parent Id"].on_delete === PormG.Models.CASCADE

    # The index axis — `index_map`'s key comes from the one RAW aggregate and was therefore already
    # `driver ref`, so it stopped matching `col_name` the moment the name was torn. `db_index=true`
    # reading back false is the #325 churn, in a new place.
    @test spaced.fields["driver ref"].db_index
    @test spaced.cache["index"]["driver ref"] == "pormg_it_spaced_ref_idx"
    if is_pg
      # The type survived too: `col_parts[2]` was `Id"`-shaped for the FK column and equally wrong
      # here, so a sized textual column degraded to TextField and lost its length.
      @test spaced.fields["driver ref"] isa PormG.Models.sCharField
      @test spaced.fields["driver ref"].max_length == 30
    end

    # ── 3f. An FK reads the column its constraint names, not the parent's PK (#415) ──
    # The PostgreSQL `foreign_keys` CTE derived the referenced column from the parent's PRIMARY KEY
    # INDEX; `con.confkey` — the array saying which parent columns the FK actually references — was
    # never selected anywhere in the file. `REFERENCES parent(ukey)` is legal wherever that column
    # carries a UNIQUE constraint, and it introspected as pointing at `id`.
    #
    # Live-only by construction: this is a SQL change, and a `DataFrameRow` fixture cannot execute
    # SQL. The hermetic block in test/unit/test_introspection_guards.jl pins the consumer contract
    # this relies on (one entry per FK, aggregates paired by position) and says so explicitly.
    uq_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_uq_parent", "pormg_it_uq_child"])
    uq_child = Dict(lowercase(string(m.name)) => m for m in uq_models)["pormg_it_uq_child"]

    @test uq_child.fields["parent_key"] isa PormG.Models.sForeignKey
    @test uq_child.fields["parent_key"].pk_field == "ukey"      # pre-fix: "id"
    @test uq_child.fields["parent_key"].to_table == "pormg_it_uq_parent"
    @test uq_child.fields["parent_key"].on_delete === PormG.Models.CASCADE
    # …and resolved the same way, since `pk_field` is what every consumer of the relation reads.
    @test PormG.Models.fk_target_column(uq_child.fields["parent_key"]) == "ukey"

    # ── 3g. A composite parent key no longer fans the aggregates out (#415) ──
    # `attnum = ANY(pk_idx.indkey)` yielded one row per parent PK column, multiplying every
    # aggregate in the CTE — and the LAST fanned-out entry silently won the `fk_map[...]`
    # assignment. The parent's key is `(a, b)` and the constraint references `a`, so the pre-fix
    # answer was `b`: a single-column FK bound to an arbitrary one of the parent's key columns, with
    # no warning. The same fan-out duplicated `delete_rules`, breaking the alignment #292
    # established.
    comp_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_comp_parent", "pormg_it_comp_child"])
    comp_child = Dict(lowercase(string(m.name)) => m for m in comp_models)["pormg_it_comp_child"]

    @test comp_child.fields["parent_a"] isa PormG.Models.sForeignKey
    @test comp_child.fields["parent_a"].pk_field == "a"          # pre-fix: "b"
    @test comp_child.fields["parent_a"].to_table == "pormg_it_comp_parent"
    # The action survived the de-fan: read off a duplicated position it was still `n` here, so this
    # is a no-regression pin for #292 rather than a mutation gate on its own.
    @test comp_child.fields["parent_a"].on_delete === PormG.Models.SET_NULL

    # The genuine MULTI-column foreign key is SKIPPED, not split. PormG has no composite-FK field
    # type, so the alternatives are both wrong: pick one column and pretend, or emit two independent
    # single-column relations that regenerate as two constraints the parent cannot accept (neither
    # `a` nor `b` is unique on its own — `a` is here only so `parent_a` above is legal, and `b` is
    # not). A skipped constraint reads as "no relation" on both sides of the diff, so the schema
    # still converges.
    #
    # Both engines: PostgreSQL excludes it in the CTE (`array_length(con.conkey, 1) = 1`), SQLite by
    # grouping `PRAGMA foreign_key_list` on `id`. Before this SQLite split it into two relations and
    # PostgreSQL fanned it out — one schema, two wrong answers.
    @test !(comp_child.fields["ca"] isa PormG.Models.sForeignKey)
    @test !(comp_child.fields["cb"] isa PormG.Models.sForeignKey)
    # The TYPE the member falls back to, not merely "not a relation". `UPGRADING.md` tells a
    # consuming app to redeclare these columns by hand, so the type it names has to be the one
    # introspection actually reports — `bigint` maps to `BigIntegerField` (src/constants.jl), and
    # advising `IntegerField` would trade the lost relation for a permanent `:type` proposal.
    # PostgreSQL only: the SQLite fixture declares `INTEGER`, which is a different (correct) answer.
    if is_pg
      @test comp_child.fields["ca"] isa PormG.Models.sBigIntegerField
      @test comp_child.fields["cb"] isa PormG.Models.sBigIntegerField
    end

    # ── 3h. A foreign key into a PRIMARY-KEY-LESS parent is visible at all (#415) ──
    # The third consequence of correlating through `confkey`, and the one that is a pure gain. The
    # old CTE reached the referenced column through `JOIN pg_index … AND pk_idx.indisprimary` — an
    # INNER join — so a parent with no primary key matched no row and the foreign key dropped out of
    # the aggregate entirely. The child column introspected as a plain integer with no relation.
    #
    # That schema is legal: a referenced column needs a UNIQUE constraint, not the key. SQLite read
    # it correctly all along (`PRAGMA foreign_key_list` never consults a primary key), so this is
    # another case of one schema reading two ways — asserted on both engines for that reason.
    nopk_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_nopk_parent", "pormg_it_nopk_child"])
    nopk_child = Dict(lowercase(string(m.name)) => m for m in nopk_models)["pormg_it_nopk_child"]

    @test nopk_child.fields["parent_key"] isa PormG.Models.sForeignKey
    @test nopk_child.fields["parent_key"].pk_field == "ukey"
    @test nopk_child.fields["parent_key"].to_table == "pormg_it_nopk_parent"
    @test nopk_child.fields["parent_key"].on_delete === PormG.Models.RESTRICT

    # ── 3i. A comma-space in an identifier or a DEFAULT tears nothing (#455) ──
    # THE LIVE HALF, and the only place the new `json_build_object` KEY NAMES are exercised at all:
    # every unit fixture writes the same keys the reader reads, so a typo in the SQL is invisible
    # there. This section is the mutation gate for the schema query itself.
    #
    # #414 fixed the FIELD separator inside one entry. The ENTRY separator was `", "`, which is a
    # legal substring of every identifier and of any `pg_get_expr` DEFAULT — so the tear needed no
    # unusual schema at all, and `makemigrations` never converged once it happened. The aggregates
    # are JSON now, which makes it unrepresentable rather than guarded.
    comma_models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_comma, parent", "pormg_it_comma_child", "pormg_it_comma_key"])
    comma_by_name = Dict(lowercase(string(m.name)) => m for m in comma_models)
    # `comma_child`, not `child`: section 3a binds `child` to the #292 fixture and section 4 READS
    # it to derive a generated-module binding name, so reusing the name here silently repointed
    # that lookup at this table — a failure that surfaces two sections away from its cause.
    comma_child = comma_by_name["pormg_it_comma_child"]

    # 1. The column keeps its real name. Measured pre-fix: `"Race` and `Total"`, with the real
    #    column absent — so the key set, not just the presence of one key, is what to assert.
    @test Set(keys(comma_child.fields)) ==
          Set(["id", "Race, Total", "plain_id", "Idx, Col", "note", "team"])

    # 2. …and its relation. The FK aggregates tore on the PARENT TABLE's name here, which `columns`
    #    never sees, so this is a genuinely separate failure from the phantom column above.
    @test comma_child.fields["Race, Total"] isa PormG.Models.sForeignKey
    @test comma_child.fields["Race, Total"].pk_field == "Ref, Key"
    @test comma_child.fields["Race, Total"].to_table == "pormg_it_comma, parent"
    @test comma_child.fields["Race, Total"].on_delete === PormG.Models.CASCADE

    # 3. THE MISALIGNMENT GATE. `plain_id` is declared AFTER the comma-named FK precisely so the
    #    positional zip shifted it: measured on `main`, it came back with `to_table == "parent\""`
    #    — a name no table has — while the real `pormg_it_comma, parent` never appeared for it.
    #    A relation re-pointed at the wrong parent is worse than a phantom column: the planner
    #    diffs a live, correct constraint and proposes DROP + ADD against a different table.
    @test comma_child.fields["plain_id"].to_table == "pormg_it_comma, parent"
    @test comma_child.fields["plain_id"].pk_field == "Ref, Key"
    @test comma_child.fields["plain_id"].on_delete === PormG.Models.SET_NULL

    # 4. The index pair, the other zip. A shifted index NAME reaches `planner._drop_index`.
    @test comma_child.fields["Idx, Col"].db_index
    @test comma_child.cache["index"]["Idx, Col"] == "pormg_it_comma_idx"

    # 5. A DEFAULT containing `, `. Two distinct defects had to be fixed for this: the aggregate
    #    tear (pre-fix this produced the phantom field key `Scuderia'::text`) AND the reader's
    #    whitespace-terminated DEFAULT regex, which truncated the value to `'Ferrari` even from an
    #    intact entry. Asserting the VALUE is what separates the two — a fix to the aggregate alone
    #    still fails here.
    @test comma_child.fields["team"].default == "Ferrari, Scuderia"

    # 6. The silent case, and the one most likely in a real schema: PostgreSQL renders a
    #    multi-argument default with a `, `, and such a column is usually NOT NULL. Scoped to the
    #    COLUMN, not the default's value — PormG has no representation for an expression default.
    #    SQLite has no `concat()` of this shape, so its fixture carries the plain literal and only
    #    the NOT NULL half is cross-engine.
    #
    #    The tear evidence is that the column is HERE, under its real name, with `NOT NULL` intact:
    #    the aggregate tear produced the phantom key `Scuderia'::text` and lost `note` entirely, so
    #    a surviving `note` is what rules it out. This used to also assert the retained default
    #    value, which #475 removed — an expression default is now dropped on every column type,
    #    textual ones included. Item 5 above is the assertion that still pins the VALUE through a
    #    `, `, and it is the stronger one for a tear because it compares the text byte for byte.
    @test haskey(comma_child.fields, "note")
    @test !comma_child.fields["note"].null
    if is_pg
      @test comma_child.fields["note"].default === nothing
    end

    # 7. The PK axis. `primary_keys` and `columns` tore on the SAME name, so the two sides agreed
    #    on both wrong names and the table came back with two phantom keys and no real column.
    comma_key = comma_by_name["pormg_it_comma_key"]
    @test Set(keys(comma_key.fields)) == Set(["Key, Col", "label"])
    @test comma_key.fields["Key, Col"] isa PormG.Models.sIDField
    @test comma_key.fields["Key, Col"].primary_key

    # 8. …and the name survives regeneration, as a legal Julia binding pinned by `db_column`
    #    (#317/#394). That is what makes the recovered name usable rather than merely reported.
    @test occursin("db_column=\"Race, Total\"", PormG.Models.Model_to_str(comma_child))

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

    # ── 6. An expression column DEFAULT is dropped uniformly (#472, #475) ────────
    # THE regression this section exists for. Before #472 a single `created_at TIMESTAMPTZ
    # DEFAULT now()` raised `FieldValidationError` from inside `convertSQLToModel`, which aborted
    # `convert_schema_to_models` for the WHOLE database — `inspectdb` produced nothing and
    # `makemigrations` reported "no plan generated". #292 had given the five foreign-key arms the
    # warn-and-drop policy; the other seven arms never got it.
    #
    # Live rather than hermetic on purpose: the unit twin builds the row itself, so it cannot show
    # that the value `pg_get_expr` ACTUALLY renders for `now()` / `CURRENT_DATE` / a parenthesized
    # numeric expression is one the guard handles. Two entirely separate readers are covered here,
    # a `json_agg` schema query on PostgreSQL and PRAGMA output on SQLite.
    expr_logs, expr_models = Test.collect_test_logs() do
      PormG.Migrations.convert_schema_to_models(pool;
          include_table = ["pormg_it_expr_defaults"])
    end
    expr_by_name = Dict(lowercase(string(m.name)) => m for m in expr_models)
    @test haskey(expr_by_name, "pormg_it_expr_defaults")
    expr_model = expr_by_name["pormg_it_expr_defaults"]

    # 1. Every column arrived. Pre-fix, none did — there was no model at all to look at.
    expected_cols = is_pg ? ["id", "created_at", "d", "n", "u", "ok", "note", "note_expr"] :
                            ["id", "created_at", "d", "n", "ok", "note", "note_expr"]
    @test Set(keys(expr_model.fields)) == Set(expected_cols)

    # 2. The unrepresentable defaults are dropped, and the COLUMN keeps its real type — dropping
    #    the default must not degrade `timestamptz` to text, which would be a different way to
    #    "not crash" while still corrupting the imported schema.
    @test expr_model.fields["created_at"] isa PormG.Models.sDateTimeField
    @test expr_model.fields["created_at"].default === nothing
    @test expr_model.fields["d"].default === nothing
    @test expr_model.fields["n"].default === nothing

    # 3. …and NOT NULL survived. The guard rebuilds the field without the default, so a retry that
    #    lost the other kwargs would report this column nullable and make every `makemigrations`
    #    propose an ALTER to "fix" it.
    @test expr_model.fields["created_at"].null == false

    # 4. Controls in the same table: a representable default and a text LITERAL are untouched.
    @test expr_model.fields["ok"].default == 5
    @test expr_model.fields["note"].default == "Ferrari"

    # 4b. #475: and the textual column whose default is an EXPRESSION is dropped like any other.
    #     This used to be kept as a quoted literal, silently — decided by `TextField` accepting any
    #     `String` rather than by anything about the schema, so the same expression reached opposite
    #     outcomes on `note_expr` and on `created_at` in this very table. The pair of assertions is
    #     the point: one column of each kind, same type, same table, and they now differ only in
    #     whether the DDL quoted the value.
    @test expr_model.fields["note_expr"] isa PormG.Models.sTextField
    @test expr_model.fields["note_expr"].default === nothing

    # 5. PostgreSQL-only: `gen_random_uuid()` on a UUID column, the most common uuid default there
    #    is. It reaches a DIFFERENT arm from the generic one (the `uuid` branch), which is why the
    #    fix covers seven call sites rather than the one the issue named.
    if is_pg
      @test expr_model.fields["u"] isa PormG.Models.sUUIDField
      @test expr_model.fields["u"].default === nothing
    end

    # 6. The failure is REPORTED, naming the table and each column — not silent. This is the half
    #    a "does not crash" assertion cannot reach.
    expr_warns = filter(l -> l.level == Logging.Warn &&
                             occursin("could not be represented", l.message), expr_logs)
    @test length(expr_warns) == (is_pg ? 5 : 4)
    expr_warned_cols = Set(string(Dict(w.kwargs)[:column]) for w in expr_warns)
    @test expr_warned_cols == Set(is_pg ? ["created_at", "d", "n", "u", "note_expr"] :
                                          ["created_at", "d", "n", "note_expr"])
    @test all(string(Dict(w.kwargs)[:table]) == "pormg_it_expr_defaults" for w in expr_warns)

    # 7. The generated model file carries no default for the dropped columns. `Model_to_str` is
    #    what `inspectdb` writes to disk, so this is the artifact the user actually gets — and a
    #    `default=` re-emitted here would be a quoted literal, silently changing the semantics on
    #    the next migration.
    expr_src = PormG.Models.Model_to_str(expr_model)
    @test occursin("created_at", expr_src)
    @test !occursin(r"created_at\s*=[^\n]*default", expr_src)
    @test occursin(r"ok\s*=[^\n]*default\s*=\s*5", expr_src)   # …while a real default IS emitted

    # 7b. #475, at the artifact the user actually gets. The generated file must carry NO default
    #     for the textual expression column — that line used to read `default="CURRENT_TIMESTAMP"`
    #     (or `default="concat(...)"`), which re-renders as `DEFAULT '<text>'` and stores those
    #     characters in every new row. And it must STILL carry the textual literal, because the two
    #     assertions together are what distinguish "fixed" from "dropped every text default".
    @test !occursin(r"note_expr\s*=[^\n]*default", expr_src)
    @test occursin(r"note\s*=[^\n]*default\s*=\s*\"Ferrari\"", expr_src)

    # ── 6b. check() reports the same columns, against the live engine (#475) ─────
    # The unit twin proves the two agree on a temp SQLite database. This proves it on whichever
    # engine the suite is running, through the real schema query rather than PRAGMA output alone —
    # and it is the only coverage of `check`'s PostgreSQL arm against a live server.
    chk = PormG.Migrations.check(pool, settings; include_table = ["pormg_it_expr_defaults"])
    @test chk.backend === (is_pg ? :postgres : :sqlite)
    chk_cols = Set(only(f.columns) for f in chk.findings)
    @test chk_cols == expr_warned_cols            # the importer and the report cannot disagree
    @test all(f.kind === :expression_default for f in chk.findings)
    @test all(f.table == "pormg_it_expr_defaults" for f in chk.findings)
    # The literal-defaulted columns are absent from the report, not merely outnumbered by it.
    @test isempty(intersect(chk_cols, Set(["ok", "note", "id"])))
  finally
    PormG._EXTRA_IGNORE_TABLES[] = saved_ignore   # never leak registry state
    drop_fixtures()
  end
end
