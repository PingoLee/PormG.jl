# ─────────────────────────────────────────────────────────────────────────────
# The live side of the migration diff is read straight into ColumnSpecs (#522, phase 3 of #507)
#
# Until #522 the introspection readers rebuilt a `PormGField` from the catalog through a type map
# that returned ONE struct per rendered type, and only then compiled it into a `ColumnSpec`. Phase 1
# made that lossiness stop mattering; phase 3 removes the round trip: `read_live_schema` returns
# `LiveTable`s of specs and `get_migration_plan` diffs against them, while `inspectdb` picks its
# struct from the spec through `field_from_spec`. Two laws pin the substitution, both hermetic:
#
#   1. READER ≡ COMPILER — a table PormG creates from a declared model reads back as the specs the
#      declared model compiles to, so a second makemigrations plans nothing. That IS convergence.
#   2. INSPECTDB ROUND-TRIPS — for every spec the reader produced, the field `field_from_spec`
#      chooses compiles back to that spec (where the declaration vocabulary can say it).
#
# SQLite runs both against a real temporary file; PostgreSQL's decoder runs against the synthetic
# rows `test_introspection_guards.jl` also uses (its live query is exercised by the integration
# suite). Mutation gates are stated per testset.
# ─────────────────────────────────────────────────────────────────────────────
using Test
using Logging
using PormG
using DataFrames
using JSON
using Dates
using TimeZones
import OrderedCollections: OrderedDict
import PormG: Models, Migrations, Dialect, PormGModel
import PormG: ColumnSpec, LiteralDefault, NoDefault, ExpressionDefault, CheckKind, NonNegativeCheck, ByteLengthCheck,
              ColumnIdentity, ForeignKeyRef
import PormG: CInt16, CInt32, CInt64, CFloat64, CDecimal, CBool, CText, CVarChar, CDate, CDateTime,
              CTime, CInterval, CUUID, CJSON, CBytes, CUnsupported
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: LiveTable, read_live_schema, live_table, model_from_live, field_from_spec,
                         column_spec, column_delta, parse_canonical_type, convertSQLToModel,
                         convert_schema_to_models, get_migration_plan, _pg_live_table, _key_arm,
                         _integer_key_arm, _coerce_default, _PostgresEngine, _SQLiteEngine,
                         _sqlite_column_checks, check, _sqlite_user_table_names,
                         _PG_OWNABLE_TABLE_FILTER, _get_live_table_names, _PG_NON_NEGATIVE_CHECK_MATCH
# The SQLite laws open a real (temporary) file. `runtests.jl` loads the weakdep extension for the
# whole suite; this guard is what makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# Dispatch-only engines, the shape every planner unit test uses for its mocks — here the ones the
# readers themselves use when no connection is at hand.
const PG522 = _PostgresEngine()
const SL522 = _SQLiteEngine()

_settings522() = (s = PormG.Configuration.Settings(); s.change_db = true; s)
_schema522(models...) = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
  Symbol(PormG.Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormGModel}}(:model => m, :exist => false)
  for m in models)

# Create the models' tables from PormG's OWN plan — `CREATE TABLE`, the per-field indexes, the
# constraints — so the catalog holds exactly what a real `migrate` would have left behind.
function _create_from_plan!(pool, models...)
  plan = get_migration_plan(LiveTable[], _schema522(models...), pool, _settings522(); interactive = false)
  for m in models
    for (_, sql) in get(plan, Symbol(PormG.Models.model_table_name(m)), OrderedDict{String, String}())
      fetch(pool, sql)
    end
  end
  return plan
end

# The parent every foreign key below points at, and the model the SQLite laws run over: every
# concrete field type PormG can put in a column (the 25 structs minus ManyToMany, a join table),
# each with the kwargs that make it a distinct column, plus a literal default of every family —
# the default is the slot where the live side has to land on the exact Julia value a declaration
# stores, and a naive `DateTime` is the case that never converged before (#522).
_races522() = Models.Model("races"; id = Models.IDField(), year = Models.IntegerField())
_probe522(races) = Models.Model("probe";
  id          = Models.IDField(),
  n_int       = Models.IntegerField(default = 7),
  n_big       = Models.BigIntegerField(null = true),
  n_pos       = Models.PositiveIntegerField(default = 3),
  n_small     = Models.PositiveSmallIntegerField(),
  s_char      = Models.CharField(max_length = 40, default = "x"),
  s_char_ix   = Models.CharField(max_length = 12, db_index = true),
  s_url       = Models.URLField(max_length = 60),
  s_slug      = Models.SlugField(max_length = 30, unique = true),
  s_text      = Models.TextField(null = true),
  s_email     = Models.EmailField(),
  s_image     = Models.ImageField(),
  b_bool      = Models.BooleanField(default = true),
  d_date      = Models.DateField(default = Date(2024, 1, 2)),
  d_datetime  = Models.DateTimeField(default = DateTime(2024, 1, 2, 3, 4, 5)),
  d_time      = Models.TimeField(default = Time(12, 30)),
  d_duration  = Models.DurationField(null = true),
  f_dec       = Models.DecimalField(max_digits = 8, decimal_places = 3, default = 2.5),
  f_float     = Models.FloatField(default = 1.5),
  u_uuid      = Models.UUIDField(default = "123e4567-e89b-12d3-a456-426614174000"),
  j_json      = Models.JSONField(null = true),
  y_blob      = Models.BinaryField(max_length = 4, null = true),
  y_blob_free = Models.BinaryField(null = true),
  race        = Models.ForeignKey(races, pk_field = "id", on_delete = PormG.CASCADE),
  race_unique = Models.OneToOneField(races, pk_field = "id", null = true, on_delete = PormG.DO_NOTHING),
  race_loose  = Models.ForeignKey(races, pk_field = "id", db_constraint = false, null = true))

# ─────────────────────────────────────────────────────────────────────────────
# Law 1 on SQLite: the reader agrees with the compiler for every field PormG can write
# The table is created from PormG's own plan, read back through the production entry point
# (`read_live_schema`, no model in sight), and every column's spec is compared to what the
# declaration compiles to — naming the column AND the facet on failure. Then the whole thing goes
# through `get_migration_plan` the way `makemigrations` calls it, and must plan nothing.
# Mutation gate: revert `_sqlite_column_checks` to the byte-bound-only parser and `n_pos`/`n_small`
# report `:checks`; drop `_literal_default`'s UTC fold and `d_datetime` reports `:default`; read
# `db_index` off a struct default again and `race_loose`'s index set changes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a table PormG created reads back as the specs its model compiles to (#522)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "law1.sqlite"); pool_size = 1)
    try
      races = _races522()
      probe = _probe522(races)
      _create_from_plan!(pool, races, probe)

      live = read_live_schema(pool; include_table = ["races", "probe"])
      by = Dict(t.name => t for t in live)
      @test Set(keys(by)) == Set(["races", "probe"])
      probe_live = by["probe"]

      # Column by column — the failure names the column and the facet, not just "differs".
      for (key, field) in probe.fields
        col = Models.field_db_column(field, key)
        @test haskey(probe_live.columns, col)
        haskey(probe_live.columns, col) || continue
        @test (col, column_delta(field, probe_live.columns[col], pool; name = col).changed) == (col, Symbol[])
        @test column_spec(field, pool; name = col) == probe_live.columns[col]
      end
      # Physical order survives (#544): the catalog order is the declaration order.
      @test collect(keys(probe_live.columns)) == [Models.field_db_column(f, k) for (k, f) in probe.fields]
      # The index facts: every non-key `db_index` column has its index, nothing else does, and the
      # relational columns are there because `_add_constrains` created one, not because a reader
      # stamped `db_index = true` on them.
      expected_ix = Set(Models.field_db_column(f, k) for (k, f) in probe.fields if f.db_index && !f.primary_key)
      @test Set(keys(probe_live.indexes)) == expected_ix
      @test all(v -> v !== nothing, values(probe_live.indexes))

      # THE convergence assertion, through the production entry point: nothing to plan.
      plan = get_migration_plan(live, _schema522(races, probe), pool, _settings522(); interactive = false)
      @test all(isempty, values(plan))

      # ── Law 2: inspectdb round-trips every spec the reader produced ──
      for (col, spec) in probe_live.columns
        field = field_from_spec(spec, probe_live, pool)
        @test (col, column_spec(field, pool; name = col) == spec) == (col, true)
      end
      # …and the regenerated models converge against their own database, as `inspectdb` promises.
      regenerated = convert_schema_to_models(pool; include_table = ["races", "probe"])
      plan2 = get_migration_plan(live, _schema522(regenerated...), pool, _settings522(); interactive = false)
      @test all(isempty, values(plan2))
      # The struct choices, on this engine: an integer key is an IDField; `INTEGER` is IntegerField.
      regen = Dict(m.name => m for m in regenerated)["probe"]
      @test regen.fields["id"] isa Models.sIDField
      @test regen.fields["n_big"] isa Models.sIntegerField
      @test regen.fields["race"] isa Models.sForeignKey && regen.fields["race"].to_table == "races"
      @test regen.fields["race_unique"] isa Models.sOneToOneField
      @test regen.fields["y_blob"].max_length == 4
      @test regen.fields["d_datetime"].default == ZonedDateTime(DateTime(2024, 1, 2, 3, 4, 5), tz"UTC")
    finally
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      close_pool!(pool)
    end
  end
end

# ── Synthetic PostgreSQL rows, the same shape `test_introspection_guards.jl` builds (#455) ──────
_col522(name, type; notnull = false, default = nothing, identity = "", unique = false,
        non_negative_check = false, byte_limit = nothing) =
  Dict{String, Any}("name" => name, "type" => type, "notnull" => notnull, "default" => default,
                    "identity" => identity, "unique" => unique,
                    "non_negative_check" => non_negative_check, "byte_limit" => byte_limit)
_fk522(column, table, pk; on_delete = "a") =
  Dict{String, Any}("column" => column, "table" => table, "pk" => pk, "on_delete" => on_delete)
_ix522(column, name) = Dict{String, Any}("column" => column, "name" => name)
function _row522(; table_name, columns, primary_keys, foreign_keys = missing, indexes = missing)
  df = DataFrame(
    table_name   = [table_name],
    columns      = [JSON.json(columns)],
    primary_keys = [JSON.json(primary_keys)],
    foreign_keys = [foreign_keys isa AbstractVector ? JSON.json(foreign_keys) : foreign_keys],
    indexes      = [indexes isa AbstractVector ? JSON.json(indexes) : indexes])
  return df[1, :]
end

# ─────────────────────────────────────────────────────────────────────────────
# Law 1 on PostgreSQL: the row decoder compiles to the specs the declared side compiles to
# Hermetic — the decoder is fed the JSON the schema query transports, as `format_type` spells the
# types and `pg_get_expr` spells the defaults. The live query itself is the integration suite's job.
# Mutation gate: route the type through the old alias table and `d_tz` reports `:type` (both
# timestamp spellings folded to a naive `timestamp`); drop `attidentity` from the id_pk arm and
# `id` reports `:identity`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: the row decoder compiles to the specs the declared side compiles to (#522)" begin
  row = _row522(table_name = "probe",
    columns = [_col522("id", "bigint"; notnull = true, identity = "d"),
               _col522("n_int", "integer"; notnull = true, default = "7"),
               _col522("n_pos", "integer"; notnull = true, non_negative_check = true),
               _col522("n_small", "smallint"; notnull = true, non_negative_check = true),
               _col522("s_char", "character varying(40)"; notnull = true, default = "'x'::character varying"),
               _col522("s_text", "text"),
               _col522("b_bool", "boolean"; notnull = true, default = "true"),
               _col522("d_date", "date"; notnull = true, default = "'2024-01-02'::date"),
               _col522("d_tz", "timestamp with time zone"; notnull = true,
                       default = "'2024-01-02 03:04:05+00'::timestamp with time zone"),
               _col522("d_naive", "timestamp without time zone"; notnull = true,
                       default = "'2024-01-02 03:04:05'::timestamp without time zone"),
               _col522("d_time", "time without time zone"; notnull = true),
               _col522("d_dur", "interval"),
               _col522("f_dec", "numeric(8,3)"; notnull = true),
               _col522("f_float", "double precision"; notnull = true),
               _col522("u_uuid", "uuid"; notnull = true),
               _col522("j_json", "jsonb"),
               _col522("y_blob", "bytea"; byte_limit = 4),
               _col522("race_id", "bigint"; notnull = true),
               _col522("twin_id", "bigint"; unique = true)],
    primary_keys = ["id"],
    foreign_keys = [_fk522("race_id", "races", "id"; on_delete = "c"), _fk522("twin_id", "races", "id")],
    indexes = [_ix522("race_id", "probe_race_id_idx")])
  live = _pg_live_table(row)
  races = _races522()
  declared = Dict(
    "id"      => Models.IDField(),
    "n_int"   => Models.IntegerField(default = 7),
    "n_pos"   => Models.PositiveIntegerField(),
    "n_small" => Models.PositiveSmallIntegerField(),
    "s_char"  => Models.CharField(max_length = 40, default = "x"),
    "s_text"  => Models.TextField(null = true),
    "b_bool"  => Models.BooleanField(default = true),
    "d_date"  => Models.DateField(default = Date(2024, 1, 2)),
    # Declared naive: PormG's convention is UTC, and the catalog renders the stored instant its own
    # way (space separator, `+00`, no milliseconds) — the shape that never converged before #522.
    "d_tz"    => Models.DateTimeField(default = DateTime(2024, 1, 2, 3, 4, 5)),
    "d_naive" => Models.DateTimeField(type = "TIMESTAMP", default = DateTime(2024, 1, 2, 3, 4, 5)),
    "d_time"  => Models.TimeField(),
    "d_dur"   => Models.DurationField(null = true),
    "f_dec"   => Models.DecimalField(max_digits = 8, decimal_places = 3),
    "f_float" => Models.FloatField(),
    "u_uuid"  => Models.UUIDField(),
    "j_json"  => Models.JSONField(null = true),
    "y_blob"  => Models.BinaryField(max_length = 4, null = true),
    "race_id" => Models.ForeignKey(races, pk_field = "id", on_delete = PormG.CASCADE),
    "twin_id" => Models.OneToOneField(races, pk_field = "id", null = true, on_delete = PormG.DO_NOTHING))
  @test Set(keys(live.columns)) == Set(keys(declared))
  for (col, field) in declared
    @test (col, column_delta(field, live.columns[col], PG522; name = col).changed) == (col, Symbol[])
  end
  @test live.indexes == Dict("race_id" => "probe_race_id_idx")
  @test live.columns["id"].identity == ColumnIdentity(true, false, false)
  @test live.columns["race_id"].reference == ForeignKeyRef("races", "races", "id", "CASCADE")
  # inspectdb's struct choices on THIS engine: `bigint` is a BigIntegerField, the naive timestamp
  # keeps its flavour, and the defaults come back as the values a declaration holds.
  m = convertSQLToModel(row)
  @test m.fields["id"] isa Models.sIDField && m.fields["id"].generated
  @test m.fields["race_id"] isa Models.sForeignKey && m.fields["twin_id"] isa Models.sOneToOneField
  @test m.fields["d_naive"].type == "TIMESTAMP" && m.fields["d_tz"].type == "TIMESTAMPTZ"
  @test m.fields["n_int"].default == 7 && m.fields["d_date"].default == Date(2024, 1, 2)
  @test m.fields["b_bool"].default === true
  @test m.cache["index"] == Dict{String, Any}("race_id" => "probe_race_id_idx")
end

# ─────────────────────────────────────────────────────────────────────────────
# The type vocabulary: catalog spellings parse to concrete types; the unsupported list is deliberate
# `parse_canonical_type` is the readers' whole type map now, so every spelling the retired forward
# maps and alias table accepted is asserted here as the canonical type it becomes — and the
# spellings PormG never renders are asserted as `CUnsupported`, because a declared `CharField` must
# NOT silently equate to a `char(8)` column the way the old reverse map made it.
# Mutation gate: drop the tail-after-paren fix in `_split_rendered_type` and the
# `timestamp(6) with time zone` case parses naive.
# ─────────────────────────────────────────────────────────────────────────────
@testset "catalog spellings parse to concrete types; the unsupported ones are the deliberate list (#522)" begin
  pg = raw -> parse_canonical_type(raw, PG522)
  # PostgreSQL `format_type` output, including the aliases the retired table used to rewrite.
  @test pg("smallint") == CInt16() && pg("int2") == CInt16()
  @test pg("integer") == CInt32() && pg("int4") == CInt32() && pg("serial") == CInt32()
  @test pg("bigint") == CInt64() && pg("int8") == CInt64() && pg("bigserial") == CInt64()
  @test pg("character varying(120)") == CVarChar(120)
  @test pg("character varying") == CVarChar(nothing)            # lengthless: read as it is, not as 250
  @test pg("text") == CText()
  @test pg("timestamp with time zone") == CDateTime(true)
  @test pg("timestamp(6) with time zone") == CDateTime(true)     # precision in the MIDDLE
  @test pg("timestamp without time zone") == CDateTime(false)
  @test pg("timestamp(3) without time zone") == CDateTime(false)
  @test pg("time without time zone") == CTime() && pg("time with time zone") == CTime() && pg("timetz") == CTime()
  @test pg("interval") == CInterval() && pg("interval day to second") == CInterval()
  @test pg("double precision") == CFloat64() && pg("real") == CFloat64()
  @test pg("numeric(10,2)") == CDecimal(10, 2)
  @test pg("numeric") == CDecimal(nothing, nothing)               # unparameterised: read as it is
  @test pg("boolean") == CBool() && pg("date") == CDate() && pg("uuid") == CUUID()
  @test pg("json") == CJSON() && pg("jsonb") == CJSON() && pg("bytea") == CBytes()
  # Deliberately unsupported — PormG never renders them, so a declaration must not match them.
  for raw in ("character(8)", "bpchar", "integer[]", "bit(1)", "inet", "citext")
    @test (raw, pg(raw) isa CUnsupported) == (raw, true)
  end

  sl = raw -> parse_canonical_type(raw, SL522)
  # SQLite declared types as `PRAGMA table_info` reports them (the reader upper-cases first).
  @test sl("INTEGER") == CInt64() && sl("INT") == CInt64() && sl("BIGINT") == CInt64()
  @test sl("INTEGER UNSIGNED") == CInt32() && sl("SMALLINT") == CInt16()
  @test sl("TEXT") == CText() && sl("VARCHAR") == CText() && sl("CLOB") == CText()
  @test sl("TEXT(20)") == CVarChar(20) && sl("VARCHAR(255)") == CVarChar(255) && sl("NVARCHAR(10)") == CVarChar(10)
  @test sl("NUMERIC") == CDecimal(nothing, nothing) && sl("DECIMAL(10,2)") == CDecimal(10, 2)
  @test sl("REAL") == CFloat64() && sl("DOUBLE") == CFloat64() && sl("FLOAT") == CFloat64()
  @test sl("BOOLEAN") == CBool() && sl("BOOL") == CBool()
  @test sl("DATE") == CDate() && sl("TIME") == CTime() && sl("INTERVAL") == CInterval()
  @test sl("DATETIME") == CDateTime(false) && sl("TIMESTAMP") == CDateTime(false)
  @test sl("UUID") == CUUID() && sl("JSON") == CJSON() && sl("JSONB") == CJSON() && sl("BLOB") == CBytes()
  for raw in ("", "MEDIUMINT", "BIT")
    @test (raw, sl(raw) isa CUnsupported) == (raw, true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The CHECK facts are read from the DDL, however the column is spelled
# `PRAGMA table_info` cannot see a CHECK, and the two PormG renders are schema facts the diff
# compares. Read as facts (an adopted `SMALLINT` without its `>= 0` compiles without it), keyed
# lower-case (#531) and in all four identifier spellings, because an adopted schema wrote them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_sqlite_column_checks reads the two CHECK facts, however the column is spelled (#522)" begin
  ddl = """CREATE TABLE "t" ("a" INTEGER UNSIGNED CHECK ("a" >= 0), [b] SMALLINT CHECK ([B] >= 0), c BLOB CHECK (length(c) <= 8), "d" TEXT CHECK (length("d") <= 3), e INTEGER)"""
  checks = _sqlite_column_checks(ddl)
  @test checks["a"] == [NonNegativeCheck()]
  @test checks["b"] == [NonNegativeCheck()]          # spelled `[B]` in the CHECK, `[b]` in the definition
  @test checks["c"] == [ByteLengthCheck(8)]
  @test checks["d"] == [ByteLengthCheck(3)]          # found here; the reader keeps it only on a BLOB
  @test !haskey(checks, "e")
  @test _sqlite_column_checks(nothing) == Dict{String, Vector{CheckKind}}()
end

# ─────────────────────────────────────────────────────────────────────────────
# Defaults: the fix that rides along, and the standing drop policy — with check() in agreement
# A `DATE … DEFAULT '2024-01-02'` column used to abort the WHOLE schema read (a `MethodError` out of
# `DateField`'s converter, which is not the `FieldValidationError` the drop guard catches). It reads
# as a `Date` now.
#
# #496 SPLIT THE TWO REMAINING CASES APART, and keeping them distinguishable is the point of this
# testset. A LITERAL the type cannot hold (`INTEGER DEFAULT 'abc'`) is still dropped, still out
# loud. A SQL EXPRESSION is no longer dropped at all — it is carried as an `ExpressionDefault` and
# reaches the models file as `db_default=`. They used to share an outcome and a warning; they now
# differ in both, which is the whole of #496, and a test that could not tell them apart would miss
# a regression in either direction. `check` reports the expression from the same classification and
# warns nothing itself.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a DATE literal default reads; a bad literal drops; an expression is carried (#522, #496)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "defaults.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "d" ("id" INTEGER PRIMARY KEY AUTOINCREMENT,
                                      "day" DATE DEFAULT '2024-01-02',
                                      "n" INTEGER DEFAULT 'abc',
                                      "created" DATETIME DEFAULT CURRENT_TIMESTAMP,
                                      "note" TEXT DEFAULT 'n');""")
      # ONE column warns now: `n`, a literal an INTEGER column cannot hold. `created` used to warn
      # beside it and no longer does — it is an EXPRESSION, and #496 represents those.
      live = @test_logs (:warn, r"could not be represented") match_mode=:all read_live_schema(pool; include_table = ["d"])
      cols = live[1].columns
      @test cols["day"].default == LiteralDefault(Date(2024, 1, 2))
      @test cols["n"].default == NoDefault()
      # The #496 half: carried, canonical, and NOT a literal — a `LiteralDefault("CURRENT_TIMESTAMP")`
      # here would be the exact corruption #475 removed, re-rendering as `DEFAULT 'CURRENT_TIMESTAMP'`.
      @test cols["created"].default == ExpressionDefault("CURRENT_TIMESTAMP")
      @test cols["note"].default == LiteralDefault("n")
      # The declared side converges with the fixed read.
      @test isempty(column_delta(Models.DateField(default = Date(2024, 1, 2), null = true), cols["day"], pool; name = "day").changed)
      # inspectdb hands the Date to the constructor.
      @test convertSQLToModel(pool, "d").fields["day"].default == Date(2024, 1, 2)
      # `check` reports exactly the expression, from the readers' own classifier, and warns nothing.
      result = @test_logs min_level = Logging.Warn check(pool, _settings522(); include_table = ["d"])
      @test [(f.table, f.columns) for f in result.findings] == [("d", ["created"])]
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review finding: a non-integer key is read as its declaration compiles, and inspectdb keeps it
# A `UUIDField(primary_key = true)` renders a bare `TEXT PRIMARY KEY` on SQLite. The first cut of the
# reader gave EVERY fall-through key the `IDField`'s identity and `unique = true` — so this table
# rebuilt on every run, and `inspectdb` regenerated the key as an `IDField` whose plan poured uuids
# into a rowid. Now only an INTEGER key on that arm takes the literals; a TEXT key compiles no
# identity and the pragma's `unique`, and `inspectdb` picks the one declaration that renders it.
# Mutation gate: drop the `_integer_key_arm` gate in `_sqlite_live_table` and `sid` reports
# `[:unique, :identity]`; drop the `CText` arm in `_inspectdb_field` and the regenerated key is an
# `IDField`, whose plan is a rebuild.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a UUID or CharField key reads as its declaration compiles, and inspectdb keeps it (#522)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "keys.sqlite"); pool_size = 1)
    try
      session = Models.Model("session"; sid = Models.UUIDField(primary_key = true), who = Models.CharField(max_length = 10))
      natural = Models.Model("natural"; code = Models.CharField(primary_key = true, max_length = 8), label = Models.CharField(max_length = 20))
      _create_from_plan!(pool, session, natural)
      live = read_live_schema(pool; include_table = ["session", "natural"])
      by = Dict(t.name => t for t in live)

      sid = by["session"].columns["sid"]
      @test sid.primary_key && sid.identity === nothing && sid.unique == false
      @test !_integer_key_arm(_key_arm(true, sid.type, false), sid.type)
      @test isempty(column_delta(session.fields["sid"], sid, pool; name = "sid").changed)
      @test isempty(column_delta(natural.fields["code"], by["natural"].columns["code"], pool; name = "code").changed)
      plan = get_migration_plan(live, _schema522(session, natural), pool, _settings522(); interactive = false)
      @test all(isempty, values(plan))

      # inspectdb: the one lengthless textual key PormG can declare is `UUIDField`; a sized one is a
      # `CharField` — and the regenerated file converges against its own database.
      regen = Dict(m.name => m for m in convert_schema_to_models(pool; include_table = ["session", "natural"]))
      @test regen["session"].fields["sid"] isa Models.sUUIDField && regen["session"].fields["sid"].primary_key
      @test regen["natural"].fields["code"] isa Models.sCharField && regen["natural"].fields["code"].max_length == 8
      plan2 = get_migration_plan(live, _schema522(regen["session"], regen["natural"]), pool, _settings522(); interactive = false)
      @test all(isempty, values(plan2))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Review finding: a catalog-rendered timestamp default coerces to the instant a declaration stores
# PostgreSQL deparses a stored `timestamptz` default as `2024-05-06 07:08:09+00` — a spelling the
# constructor's converter never parsed, so a declared `DateTimeField(default = …)` planned
# `SET DEFAULT` on every run. `_parse_catalog_timestamp` reads that shape (and the naive one) ahead
# of the constructor's ladder; PormG's own `T…+00:00` spelling matches the same regex and lands on
# the same instant, and anything else falls through to the ladder.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a catalog-rendered timestamp default coerces to the instant a declaration stores (#522)" begin
  utc = ZonedDateTime(DateTime(2024, 5, 6, 7, 8, 9), tz"UTC")
  @test _coerce_default("2024-05-06 07:08:09+00", CDateTime(true)) == utc
  @test _coerce_default("2024-05-06 07:08:09.5-03", CDateTime(true)) == ZonedDateTime(DateTime(2024, 5, 6, 10, 8, 9, 500), tz"UTC")
  @test _coerce_default("2024-05-06 07:08:09+05:30", CDateTime(true)) == ZonedDateTime(DateTime(2024, 5, 6, 1, 38, 9), tz"UTC")
  @test _coerce_default("2024-05-06 07:08:09", CDateTime(false)) == DateTime(2024, 5, 6, 7, 8, 9)
  @test _coerce_default("2024-05-06T07:08:09.000+00:00", CDateTime(true)) == utc
  # …and through `_literal_default`, both spellings of one instant are one default.
  @test Migrations._literal_default(_coerce_default("2024-05-06 07:08:09+00", CDateTime(true))) ==
        Migrations._literal_default(DateTime(2024, 5, 6, 7, 8, 9))
end

# ─────────────────────────────────────────────────────────────────────────────
# Loose end 3 of #522: every producer of the SQLite rebuild renders the same SQL for one model
# The `"Alter table: <model>"` entry survives as whichever registration lands LAST, and three
# producers register it — the column alteration, a new SQLite foreign-key column (#514) and the
# deletion of a constrained column. Each renders from the DESIRED model, so they are equivalent
# today; nothing enforced it. This does: the rebuild core (index DDL and the foreign-key check
# stripped) is byte-identical across the three, and equal to `Dialect.rebuild_table` itself.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every producer of the SQLite rebuild renders the same SQL for one desired model (#522)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "rebuild.sqlite"); pool_size = 1)
    try
      races = _races522()
      _create_from_plan!(pool, races)
      desired = Models.Model("car"; id = Models.IDField(), name = Models.CharField(max_length = 20),
                             race = Models.ForeignKey(races, pk_field = "id"))
      variants = (
        # the alteration producer: `name` is narrower live
        "alter"  => Models.Model("car"; id = Models.IDField(), name = Models.CharField(max_length = 10),
                                 race = Models.ForeignKey(races, pk_field = "id")),
        # the add-field producer: a new foreign-key column on SQLite needs the rebuild (#514)
        "add"    => Models.Model("car"; id = Models.IDField(), name = Models.CharField(max_length = 20)),
        # the deletion producer: an extra constrained column goes away
        "delete" => Models.Model("car"; id = Models.IDField(), name = Models.CharField(max_length = 20),
                                 race = Models.ForeignKey(races, pk_field = "id"),
                                 extra = Models.ForeignKey(races, pk_field = "id", null = true)))
      core(sql) = join(filter(l -> !(startswith(l, "CREATE INDEX") || startswith(l, "PRAGMA")),
                              split(String(sql), "\n")), "\n")
      cores = Dict{String, String}()
      for (label, live_model) in variants
        fetch(pool, "DROP TABLE IF EXISTS \"car\";")
        _create_from_plan!(pool, live_model)
        live = read_live_schema(pool; include_table = ["car", "races"])
        plan = get_migration_plan(live, _schema522(races, desired), pool, _settings522(); interactive = false)
        @test haskey(plan, :car) && haskey(plan[:car], "Alter table: car")
        haskey(plan, :car) && haskey(plan[:car], "Alter table: car") || continue
        cores[label] = core(plan[:car]["Alter table: car"])
      end
      @test length(Set(values(cores))) == 1
      @test all(c -> c == core(Dialect.rebuild_table(pool, desired)), values(cores))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The adapter: a hand-built model is read as a live table, index names included
# `get_migration_plan(::Vector{PormGModel}, …)` is how the planner's tests and the golden corpus
# hand-build the live side; it must carry the same facts the readers would — the specs, `db_index`
# as index presence, `cache["index"]` as the live index name — and agree with the LiveTable form.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a hand-built live model reads as a LiveTable, and both plan entry points agree (#522)" begin
  races = _races522()
  m = Models.Model("car"; id = Models.IDField(), name = Models.CharField(max_length = 20, db_index = true),
                   race = Models.ForeignKey(races, pk_field = "id"), tag = Models.CharField(max_length = 5))
  m.cache["index"] = Dict{String, Any}("name" => "car_name_idx")
  t = live_table(m, PG522)
  @test t.name == "car"
  @test collect(keys(t.columns)) == ["id", "name", "race", "tag"]
  # `name` has a known index name; `race` is indexed by constructor default with no name known;
  # `tag` declares none; the key is never listed.
  @test t.indexes == Dict{String, Union{String, Nothing}}("name" => "car_name_idx", "race" => nothing)
  @test t.columns["name"] == column_spec(m.fields["name"], PG522; name = "name")
  @test t.columns["race"].reference == ForeignKeyRef("races", "races", "id", "NO ACTION")
  # The two entry points agree on a converged pair — the diff is empty either way.
  settings = _settings522()
  p1 = get_migration_plan(PormGModel[m], _schema522(m), PG522, settings; interactive = false)
  p2 = get_migration_plan(LiveTable[t], _schema522(m), PG522, settings; interactive = false)
  @test p1 == p2
  @test all(isempty, values(p1))
end

# ─────────────────────────────────────────────────────────────────────────────
# The adapter compiles DECLARED composites the way the planner will (#161)
# `live_table(model)` is how the planner's tests hand-build a live side, so its composites must be
# what a table created from `model` reads back as: physical columns (a `db_column` is the column,
# not the field key), the derived name when the declaration gives none, every `UniqueConstraint`
# beside every `Index`, and the synthesized join table's own unique index. Before #161 it read
# `cache["composite_indexes"]` alone, by field key, and threw a MethodError on `name = nothing`.
# Mutation gate: pass field keys instead of `Models.model_column` and `("race", "yr")` reads
# `("race", "year")`; drop the `unique_constraints` loop and the first two entries vanish.
# ─────────────────────────────────────────────────────────────────────────────
@testset "live_table carries the declared composites in physical terms (#161)" begin
  races = _races522()
  m = Models.Model("lap";
    id    = Models.IDField(),
    race  = Models.ForeignKey(races, pk_field = "id"),
    year  = Models.IntegerField(db_column = "yr"),
    lap   = Models.IntegerField(),
    constraints = [Models.UniqueConstraint(fields = ("race", "lap")),                 # derived name
                   Models.UniqueConstraint(fields = ("lap",), name = "lap_only_uq")],  # explicit, one field
    indexes = [Models.Index(fields = ("race", "year"))])                                # derived, db_column
  t = live_table(m, PG522)
  @test [(c.name, c.columns, c.unique, c.constraint) for c in t.composites] == [
    ("lap_race_lap_uniq", ["race", "lap"], true,  false),
    ("lap_only_uq",       ["lap"],         true,  false),
    ("lap_race_yr_idx",   ["race", "yr"],  false, false)]
  # The declared side's compiler agrees, and it records which names were WRITTEN — the only ones a
  # live name mismatch may rename.
  @test [(d.name, d.explicit) for d in Migrations.declared_composites(m)] ==
        [("lap_race_lap_uniq", false), ("lap_only_uq", true), ("lap_race_yr_idx", false)]

  # A synthesized ManyToManyField join table: its unique index is declared, and DERIVED — PormG
  # chose that name, so a join table adopted from Django under Django's name must not be renamed.
  through = Models.Model("car_driver"; id = Models.IDField(),
                         car_id = Models.IntegerField(), driver_id = Models.IntegerField())
  through.cache["many_to_many_auto"] = Dict{String, Any}(
    "owner_column" => "car_id", "related_column" => "driver_id",
    "unique_index" => "car_driver_car_id_driver_id_uniq")
  @test [(d.name, d.columns, d.unique, d.explicit) for d in Migrations.declared_composites(through)] ==
        [("car_driver_car_id_driver_id_uniq", ["car_id", "driver_id"], true, false)]
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: `_pg_composite_indexes` classifies what the catalog returns (#161)
# The live query runs only in the integration suite, so the Julia half — which shapes are read, as
# what, and which are refused WHOLE — is pinned here over synthetic catalog rows, one per (index,
# key column), exactly as the query returns them. Three unique shapes partition against the column
# readers: a bare unique index is read at any arity, a constraint-backed one only above arity 1
# (arity 1 is the field's `unique`), and a non-unique one only above arity 1 (that is `db_index`).
# The query text is asserted for the two predicates no synthetic row can exercise: the backing
# constraint must be joined on the index's OWN table and kind — a foreign key also records
# `conindid`, the PARENT's unique index — and `indnullsnotdistinct` must not be named at all, as
# it is PostgreSQL 15+ and the stated floor is 11.
# Mutation gate: drop the `(unique && !constraint)` arm and `ux_g` vanishes; drop the refusal line
# and all four refused indexes come back.
# ─────────────────────────────────────────────────────────────────────────────
struct CompositeMockPg161 <: PormG.PormGPostgres end
const PG161_ROWS = Ref(DataFrame())
const PG161_SQL = Ref("")
fetch(::CompositeMockPg161, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
  (PG161_SQL[] = sql; PG161_ROWS[])

@testset "PostgreSQL: the composite reader reads three unique shapes and refuses four (#161)" begin
  rows = NamedTuple[]
  # One row per key column. Every flag defaults to the value a plain PormG-created index carries.
  add(idx, cols; unique = false, contype = missing, deferrable = missing, valid = true,
      include = false, nnd = false, opt = 0, tbl = "lap") =
    for c in cols
      push!(rows, (table_name = tbl, index_name = idx, is_unique = unique, contype = contype,
                   is_deferrable = deferrable, is_valid = valid, has_include = include,
                   nulls_not_distinct = nnd, column_name = c, opt = opt, idx_coll = 0,
                   col_coll = 0, opc_default = true))
    end
  add("ix_ba",   ["b", "a"])                                            # Index, declared order
  add("ix_solo", ["s"])                                                 # arity 1: db_index's
  add("ux_cd",   ["c", "d"]; unique = true)                             # bare CREATE UNIQUE INDEX
  add("ux_g",    ["g"];      unique = true)                             # one-field UniqueConstraint
  add("uq_fe",   ["f", "e"]; unique = true, contype = "u", deferrable = false)   # Django's UNIQUE (f, e)
  add("uq_h",    ["h"];      unique = true, contype = "u", deferrable = false)   # the field's `unique`
  add("ux_incl", ["c", "d"]; unique = true, include = true)             # INCLUDE payload
  add("ux_bad",  ["c", "d"]; unique = true, valid = false)              # failed CONCURRENTLY build
  add("uq_def",  ["c", "d"]; unique = true, contype = "u", deferrable = true)    # DEFERRABLE
  add("ux_nnd",  ["c", "d"]; unique = true, nnd = true)                 # NULLS NOT DISTINCT
  add("ix_desc", ["c", "d"]; opt = 3)                                   # (pre-existing) DESC key
  add("ux_other", ["x", "y"]; unique = true, tbl = "pit")               # keyed by its own table
  PG161_ROWS[] = DataFrame(rows)

  out = Migrations._pg_composite_indexes(CompositeMockPg161())
  lap = Dict(lc.name => lc for lc in out["lap"])
  @test sort(collect(keys(lap))) == ["ix_ba", "uq_fe", "ux_cd", "ux_g"]
  @test (lap["ix_ba"].columns, lap["ix_ba"].unique, lap["ix_ba"].constraint) == (["b", "a"], false, false)
  @test (lap["ux_cd"].unique, lap["ux_cd"].constraint) == (true, false)
  @test (lap["ux_g"].columns, lap["ux_g"].unique) == (["g"], true)
  @test (lap["uq_fe"].columns, lap["uq_fe"].unique, lap["uq_fe"].constraint) == (["f", "e"], true, true)
  @test [lc.name for lc in out["pit"]] == ["ux_other"]

  # The query shape no synthetic row can reach (see the header).
  sql = PG161_SQL[]
  @test occursin("con.conindid = i.indexrelid AND con.conrelid = i.indrelid", sql)
  @test occursin("con.contype IN ('u', 'p', 'x')", sql)
  @test !occursin("indnullsnotdistinct", sql)
  @test occursin("pg_get_indexdef(i.indexrelid) LIKE '%NULLS NOT DISTINCT%'", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# `convertSQLToModel(sql)` is the live reader over a scratch file
# The regex reader it replaced never read `unique` and wrote a non-canonical `to_table`; running the
# statement in a throwaway SQLite file and reading THAT closes both gaps by construction. The
# "no double-quoted table name" refusal is unchanged (`test_error_taxonomy.jl` pins its type).
# ─────────────────────────────────────────────────────────────────────────────
@testset "convertSQLToModel(sql) is the live reader over a scratch file, unique included (#522)" begin
  m = convertSQLToModel("""CREATE TABLE "kit" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "code" TEXT(8) UNIQUE NOT NULL, "n" INTEGER DEFAULT 3);""")
  @test m.name == "kit"
  @test m.fields["code"] isa Models.sCharField && m.fields["code"].max_length == 8
  @test m.fields["code"].unique          # the regex reader never populated this; the live one does
  @test m.fields["n"].default == 3
  @test_throws PormG.InvalidMigrationError convertSQLToModel("CREATE TABLE kit (id INTEGER)")
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: relations PormG cannot own are never read, so never dropped (#730)
# `sqlite_master` lists an FTS5 or R*Tree virtual table — and every SHADOW table its module keeps
# its data in — as `type = 'table'`. No model declares them, so `makemigrations` planned a
# `Drop table` for each (six for one FTS5 index), and the destructive guard then blocked every
# migration on that database. The readers now enumerate `_sqlite_user_table_names`, which leaves
# out what `pragma_table_list` labels `virtual` / `shadow`. A view was never read; it is pinned too.
# Mutation gate: put the bare `sqlite_master` query back in `_sqlite_user_table_names` and every
# assertion after the precondition fails — the two virtual tables and their eight shadows come
# back, and the plan carries a `Drop table` for each.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: virtual tables, their shadow tables and views are not read, so not dropped (#730)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "own730.sqlite"); pool_size = 1)
    try
      driver = Models.Model("driver"; id = Models.IDField(), surname = Models.CharField(max_length = 50))
      _create_from_plan!(pool, driver)
      # What an app adds by hand beside its models: a full-text index over a model's column, a
      # spatial index, and a view. None of them has, or could have, a model.
      fetch(pool, "CREATE VIRTUAL TABLE driver_fts USING fts5(surname)")
      fetch(pool, "CREATE VIRTUAL TABLE pit_box USING rtree(id, min_x, max_x)")
      fetch(pool, "CREATE VIEW driver_names AS SELECT surname FROM driver")

      # Precondition — the catalog the old reader scanned really lists them as tables. Without it a
      # SQLite build lacking fts5 or rtree would make every assertion below pass vacuously.
      raw = String.((fetch(pool, "SELECT name FROM sqlite_master WHERE type = 'table'") |> DataFrame).name)
      @test "driver_fts" in raw && "driver_fts_data" in raw && "driver_fts_config" in raw
      @test "pit_box" in raw && "pit_box_node" in raw && "pit_box_rowid" in raw

      # The shared enumeration, then each reader built on it. `read_live_schema` is called with NO
      # `include_table`: naming the tables to read is exactly the filter that would hide the bug.
      @test _sqlite_user_table_names(pool) == ["driver"]
      live = read_live_schema(pool)
      @test [t.name for t in live] == ["driver"]
      @test [m.name for m in convert_schema_to_models(pool)] == ["driver"]     # inspectdb
      @test _get_live_table_names(pool) == ["driver"]                            # status()'s drift probe

      # THE user-visible assertion: an up-to-date `driver` plus an FTS index plans nothing.
      plan = get_migration_plan(live, _schema522(driver), pool, _settings522(); interactive = false)
      @test all(isempty, values(plan))
    finally
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: shadow tables SQLite cannot confirm are skipped by its own naming rule, loudly (#730)
# `pragma_table_list` labels a table `shadow` only when the virtual table's MODULE is registered on
# the connection and claims the suffix, so an extension an app loads on its own connection only
# (sqlite-vec, SpatiaLite) leaves its shadow tables reading as plain tables — the #730 symptom
# again. Simulated here by renaming the FTS5 module in the stored DDL and reopening. For such a
# virtual table, and below 3.37 where `pragma_table_list` does not exist, the `<vtab>_` namespace is
# skipped and a warning names every table skipped. With the module registered the rule never fires,
# so a user table named `driver_fts_notes` beside a working FTS5 index is still read.
# A registered `driver_fts_title` sits beside `driver_fts` on purpose: its confirmed shadows share
# `driver_fts_`'s prefix and must vouch only for the longest name they extend.
# Mutation gate: drop the `guessed` exclusion and the shadow tables come back in both unconfirmed
# cases; stop vouching at all and `driver_fts_notes` vanishes, with a warning, while the module is
# registered; let a shadow vouch for ANY prefix it extends and `driver_fts`'s shadows come back once
# its module is gone.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: shadow tables SQLite cannot confirm are skipped by its naming rule, loudly (#730)" begin
  mktempdir() do dir
    path = joinpath(dir, "shadow730.sqlite")
    skipped = (:warn, r"Introspection skips these tables")
    pool = SQLiteConnectionPool(path; pool_size = 1)
    try
      fetch(pool, "CREATE TABLE driver (id INTEGER PRIMARY KEY, surname TEXT)")
      fetch(pool, "CREATE VIRTUAL TABLE driver_fts USING fts5(surname)")
      # A second FTS5 index whose NAME extends the first's. It stays registered throughout, and its
      # confirmed shadows (`driver_fts_title_data`, …) sit inside `driver_fts_`'s namespace — they
      # must not vouch for `driver_fts` once that one's module is gone.
      fetch(pool, "CREATE VIRTUAL TABLE driver_fts_title USING fts5(surname)")
      # A user table inside the virtual table's namespace — the one shape the naming rule costs.
      fetch(pool, "CREATE TABLE driver_fts_notes (id INTEGER PRIMARY KEY, note TEXT)")

      # Module registered: SQLite confirms the five shadows itself, nothing is guessed, no warning,
      # and the user table is read.
      @test (@test_logs min_level = Logging.Warn _sqlite_user_table_names(pool)) == ["driver", "driver_fts_notes"]

      # Below 3.37 (no `pragma_table_list`): the virtual table is still known from its stored DDL, and
      # the naming rule skips its whole namespace — the user table included, which the warning names.
      @test (@test_logs skipped _sqlite_user_table_names(pool; sqlite_version = 3_036_000)) == ["driver"]

      # Unregister the module: rename it in the stored DDL, then reopen so SQLite re-reads the schema.
      fetch(pool, "PRAGMA writable_schema = ON")
      fetch(pool, "UPDATE sqlite_master SET sql = replace(sql, 'fts5', 'pormg_absent_module') WHERE name = 'driver_fts'")
      fetch(pool, "PRAGMA writable_schema = OFF")
    finally
      close_pool!(pool)
    end
    pool = SQLiteConnectionPool(path; pool_size = 1)
    try
      # Precondition — SQLite now reports the shadows as plain tables. Without this, a SQLite that
      # still confirmed them would make the assertions below pass on the confirmed path.
      labels = Dict(String(r.name) => String(r.type) for r in
                    eachrow(fetch(pool, "SELECT name, type FROM pragma_table_list WHERE schema = 'main'") |> DataFrame))
      @test (labels["driver_fts"], labels["driver_fts_data"], labels["driver_fts_config"]) == ("virtual", "table", "table")
      @test labels["driver_fts_title_data"] == "shadow"    # the longer-named index is still confirmed

      @test (@test_logs skipped _sqlite_user_table_names(pool)) == ["driver"]
      @test [t.name for t in (@test_logs skipped read_live_schema(pool))] == ["driver"]
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: every query that enumerates live tables carries the ownership filter (#730)
# `relkind = 'r'` admitted a partition (the partitioned parent is `'p'`, but each partition is
# `'r'`) and a table an extension owns (PostGIS's `spatial_ref_sys`), so `makemigrations` planned a
# `DROP TABLE` for each. One constant, `_PG_OWNABLE_TABLE_FILTER`, now closes both, and this pins
# that all three enumerations interpolate it — the schema dump, the composite-index reader, and
# `status()`'s drift probe — since CI runs no PostgreSQL. The live half, a real partition and a real
# extension member, is `test/integration/test_importers_introspection.jl`.
# Mutation gate: drop the interpolation from any one of the three queries and the `all` fails; drop
# either clause from the constant and its own assertion fails.
# ─────────────────────────────────────────────────────────────────────────────
struct OwnershipMockPg730 <: PormG.PormGPostgres end
const PG730_SQL = String[]
fetch(::OwnershipMockPg730, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
  (push!(PG730_SQL, sql); DataFrame())

@testset "PostgreSQL: every live-table enumeration carries the ownership filter (#730)" begin
  empty!(PG730_SQL)
  # An empty dump warns "No tables found in the database" — expected from a mock that returns nothing.
  with_logger(NullLogger()) do
    Migrations.get_database_schema(OwnershipMockPg730())
  end
  Migrations._pg_composite_indexes(OwnershipMockPg730())
  _get_live_table_names(OwnershipMockPg730())
  @test length(PG730_SQL) == 3
  @test all(sql -> occursin(_PG_OWNABLE_TABLE_FILTER, sql), PG730_SQL)
  # What the filter has to say, clause by clause.
  @test occursin("NOT c.relispartition", _PG_OWNABLE_TABLE_FILTER)
  @test occursin(r"NOT EXISTS \(SELECT 1 FROM pg_depend dep\s+WHERE dep\.classid = 'pg_class'::regclass AND dep\.objid = c\.oid\s+AND dep\.deptype = 'e'\)",
                 _PG_OWNABLE_TABLE_FILTER)
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: PormG's non-negative CHECK is recognised by its exact clause, reader and dropper alike (#731)
# The `non_negative_checks` CTE matched `pg_get_constraintdef … LIKE '%>= 0%'` and
# `get_constraints_check` matched `check_clause ILIKE '%>= 0%'`, so a user's
# `CHECK (grid >= 0 AND grid <= 30)` — or `CHECK (price >= 0.5)` — read as the one a
# `PositiveIntegerField` renders, and the planner could propose dropping it. Both now interpolate
# ONE predicate, `_PG_NON_NEGATIVE_CHECK_MATCH`: the constraint text must equal what PostgreSQL
# deparses `CHECK ("col" >= 0)` to, the same exactness the SQLite reader's anchored regex has.
# The live half (a real range check read, a real PormG check still matched) is
# `test/integration/test_importers_introspection.jl`.
# Mutation gate: put `LIKE '%>= 0%'` back in either query and its assertion fails.
# ─────────────────────────────────────────────────────────────────────────────
struct NonNegSqlMockPg731 <: PormG.PormGPostgres end
const PG731_CALLS = Tuple{String, Any}[]
fetch(::NonNegSqlMockPg731, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
  (push!(PG731_CALLS, (sql, params)); DataFrame())

@testset "PostgreSQL: PormG's >= 0 CHECK is matched by its exact clause, in the reader and the dropper (#731)" begin
  # The predicate is the deparsed form of `Dialect._non_negative_check_clause`: PostgreSQL
  # re-parenthesises the expression and quotes the column only when it must — which is exactly
  # what `quote_ident` does, since both call the same quoting routine.
  @test _PG_NON_NEGATIVE_CHECK_MATCH ==
        "pg_get_constraintdef(con.oid) = 'CHECK ((' || quote_ident(a.attname) || ' >= 0))'"
  @test occursin("\"col\" >= 0", Dialect._non_negative_check_clause("col"))   # what PormG writes

  empty!(PG731_CALLS)
  with_logger(NullLogger()) do                 # an empty dump warns "No tables found"
    Migrations.get_database_schema(NonNegSqlMockPg731())
  end
  @test Migrations.get_constraints_check(NonNegSqlMockPg731(), "lap_times", "grid") === nothing
  (dump_sql, _), (drop_sql, _) = PG731_CALLS
  for sql in (dump_sql, drop_sql)
    @test occursin(_PG_NON_NEGATIVE_CHECK_MATCH, sql)
    @test !occursin(">= 0%", sql)              # neither substring spelling survives
  end
  # The dropper is scoped the way the DDL it feeds is: one column, and the table an unqualified
  # name resolves to — the first schema on the search path that holds it.
  @test occursin("array_length(con.conkey, 1) = 1", drop_sql)
  @test occursin("n.nspname = ANY(current_schemas(false))", drop_sql)
  @test occursin("ORDER BY array_position(current_schemas(false), n.nspname)", drop_sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: the get_constraints_* lookups bind the names they are given (#731)
# `get_constraints_check`, `get_constraints_pk` and `get_sequence_name` spliced the table and
# column into single-quoted literals, so a quote in a name broke the query and the family broke
# the parameterized-queries-only rule. Every one now sends `$1`/`$2`, and the names travel in
# `params`. `get_constraints_unique` / `_byte_length_check` / `_fk` / `_index` already did.
# Mutation gate: interpolate the name back into any one query and its `!occursin` fails; drop the
# `kcu` table join or the search-path order from `pk` / `unique` and the last loop fails.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: the get_constraints_* lookups bind table and column, never splice them (#731)" begin
  table, column = "o'connor_laps", "o'grid"   # a quote a spliced literal cannot survive
  lookups = (Migrations.get_constraints_check, Migrations.get_constraints_pk, Migrations.get_sequence_name,
             Migrations.get_constraints_unique, Migrations.get_constraints_byte_length_check)
  for lookup in lookups
    empty!(PG731_CALLS)
    @test lookup(NonNegSqlMockPg731(), table, column) === nothing
    sql, params = only(PG731_CALLS)
    @test (nameof(lookup), occursin("\$1", sql) && occursin("\$2", sql)) == (nameof(lookup), true)
    @test (nameof(lookup), occursin("o'", sql)) == (nameof(lookup), false)
    @test (nameof(lookup), collect(params)) == (nameof(lookup), [table, column])
  end
  # The two `information_schema` lookups join `kcu` on the TABLE as well — a foreign key elsewhere
  # may share the constraint's name (#498) — and, like `get_constraints_check`, put the first schema
  # on the search path first, the one an unqualified `ALTER TABLE` binds to.
  for lookup in (Migrations.get_constraints_pk, Migrations.get_constraints_unique)
    empty!(PG731_CALLS)
    lookup(NonNegSqlMockPg731(), table, column)
    sql, _ = only(PG731_CALLS)
    @test (nameof(lookup), occursin("AND tc.table_name = kcu.table_name", sql)) == (nameof(lookup), true)
    @test (nameof(lookup), occursin("ORDER BY array_position(current_schemas(false), tc.table_schema::name)", sql)) ==
          (nameof(lookup), true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The planner acts on whatever the reader says about a CHECK — which is why the misread mattered (#731)
# Hermetic, over the PostgreSQL row decoder. A declared `IntegerField` against a live column the
# reader marks with PormG's `>= 0` check plans a `DROP CONSTRAINT` of the name `get_constraints_check`
# returns — the user's range check, before the fix. Against the same column read correctly (no
# PormG check) it plans nothing. This pins the planner's half of the contract; it passes before the
# fix too, and the SQL assertions above are the ones that fail on the old reader.
# ─────────────────────────────────────────────────────────────────────────────
struct NonNegPlanMockPg731 <: PormG.PormGPostgres end
PormG.get_constraints_check(::NonNegPlanMockPg731, t::String, f::String) = f == "grid" ? "lap_times_grid_range" : nothing
fetch(::NonNegPlanMockPg731, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

@testset "an IntegerField column converges unless the reader claims PormG's >= 0 check on it (#731)" begin
  laps = Models.Model("lap_times"; id = Models.IDField(), grid = Models.IntegerField())
  live(non_negative) = _pg_live_table(_row522(table_name = "lap_times",
    columns = [_col522("id", "bigint"; notnull = true, identity = "d"),
               _col522("grid", "integer"; notnull = true, non_negative_check = non_negative)],
    primary_keys = ["id"]))
  plan(non_negative) = get_migration_plan(LiveTable[live(non_negative)], _schema522(laps),
                                          NonNegPlanMockPg731(), _settings522(); interactive = false)

  # The fixed reader's view of a user range check: no PormG check, nothing to do.
  @test all(isempty, values(plan(false)))
  # The old reader's view: PormG's check "found", so the planner drops the constraint it names.
  stmts = join(values(plan(true)[:lap_times]), "\n")
  @test occursin("DROP CONSTRAINT \"lap_times_grid_range\"", stmts)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite parity: only PormG's exact `CHECK ("col" >= 0)` reads as the non-negative check (#731)
# The SQLite reader already matched the rendered clause with an anchored regex; the PostgreSQL
# reader did not, so the same schema read differently on each engine. Pinned here so the engines
# stay aligned: a range check, a fractional bound and a zero-padded literal read as nothing, and
# PormG's own clause — in any of the four identifier spellings an adopted schema might use — reads.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite parity: a user range check on an integer is not PormG's >= 0 check (#731)" begin
  checks = _sqlite_column_checks("""CREATE TABLE "lap_times" (
    "grid"  INTEGER CHECK (grid >= 0 AND grid <= 30),
    "price" INTEGER CHECK (price >= 0.5),
    "lap"   INTEGER CHECK (lap >= 05),
    "pos"   INTEGER CHECK ("pos" >= 0),
    "Mixed" INTEGER CHECK ([Mixed] >= 0))""")
  @test !haskey(checks, "grid") && !haskey(checks, "price") && !haskey(checks, "lap")
  @test checks["pos"] == CheckKind[NonNegativeCheck()]
  @test checks["mixed"] == CheckKind[NonNegativeCheck()]    # keys are lower-cased (#531)
end
