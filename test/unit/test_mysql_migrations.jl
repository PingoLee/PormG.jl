# ============================================================
# test/unit/test_mysql_migrations.jl
#
# MySQL migrations, phase 4a (#1130, #1268): a schema created from nothing, on mock connections.
#
# CONTRACT being tested:
#   A model renders MySQL DDL: backtick-quoted names, the type map, `AUTO_INCREMENT` on an `IDField`
#   key, a literal default written as an expression where MySQL takes no other, PormG's own CHECKs, and
#   the InnoDB/utf8mb4 table options. The schema reader compiles what `information_schema` reports for
#   that DDL to the spec the declared side compiles, so a table PormG created reads back as its
#   declaration. A plan of more than one statement is refused unless `atomic = false`, because MySQL's
#   DDL is not transactional; what phase 4a does not plan is refused naming its phase.
#
# DB-free: mock connections and synthetic catalog rows. The same schema is created, read back, re-planned
# and stopped part-way against a live MySQL in `test/integration/test_mysql_migrations.jl`.
#
# Run: julia --project=test/integration test/unit/test_mysql_migrations.jl
# ============================================================

using Test
using PormG
using PormG.Models
using OrderedCollections
import MySQL

const _MM = PormG.Migrations
const _MD = PormG.Dialect

struct MmMockMySQL <: PormG.PormGMySQL end
struct MmMockPostgres <: PormG.PormGPostgres end
const _mm_my = MmMockMySQL()

# The F1 shapes the DDL below names, one field of each type the map spells.
_MmCircuit = Models.Model("circuit", circuitid = Models.IDField(), name = Models.CharField(max_length = 255),
  location = Models.TextField(null = true), alt = Models.IntegerField(default = 0),
  url = Models.URLField(unique = true), circuitref = Models.CharField(max_length = 40, db_index = true))
_MmDriver = Models.Model("driver", driverid = Models.IDField(), forename = Models.CharField(max_length = 100),
  dob = Models.DateField(null = true), active = Models.BooleanField(default = true),
  created = Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"), number = Models.PositiveSmallIntegerField(null = true),
  rating = Models.DecimalField(max_digits = 6, decimal_places = 3, null = true),
  code = Models.CharField(max_length = 8, default = "a\\b'c"))
_MmResult = Models.Model("result", resultid = Models.IDField(),
  driverid = Models.ForeignKey(_MmDriver, pk_field = "driverid", on_delete = "CASCADE"),
  circuitid = Models.ForeignKey(_MmCircuit, pk_field = "circuitid", null = true, on_delete = "SET_NULL"),
  laptime = Models.TimeField(null = true), fastest = Models.DurationField(null = true),
  uid = Models.UUIDField(null = true), meta = Models.JSONField(null = true), blob = Models.BinaryField(null = true),
  notes = Models.TextField(default = "it's"), points = Models.FloatField(default = 0.0),
  laps = Models.BigIntegerField(default = 0), grid = Models.PositiveIntegerField(default = 0),
  today = Models.DateField(db_default = "CURRENT_DATE"))

_mm_err(f) = try; f(); nothing; catch e; e; end

# ─────────────────────────────────────────────────────────────────────────────
# DDL: one table per model, in MySQL's own spelling
# ─────────────────────────────────────────────────────────────────────────────

# What: the CREATE TABLE a model renders on MySQL, whole.
# SQL: the statements below, byte for byte.
# Why: a double-quoted name is a string literal under MySQL's `sql_mode` (no `ANSI_QUOTES`), a missing
# `AUTO_INCREMENT` makes every insert without a key fail, and a bare literal default on a LONGTEXT is
# error 1101; each would surface only at `migrate`.
@testset "#1268: a model renders MySQL DDL" begin
  @test _MD.create_table(_mm_my, _MmDriver) == "CREATE TABLE IF NOT EXISTS `driver` (\n  " * join([
    "`driverid` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY",
    "`forename` VARCHAR(100) NOT NULL",
    "`dob` DATE NULL",
    "`active` TINYINT(1) NOT NULL DEFAULT TRUE",
    "`created` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)",
    "`number` SMALLINT NULL CHECK (`number` >= 0)",
    "`rating` DECIMAL(6,3) NULL",
    "`code` VARCHAR(8) NOT NULL DEFAULT 'a\\\\b''c'"], ",\n  ") *
    "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;"
  ddl = _MD.create_table(_mm_my, _MmResult)
  for col in ("`resultid` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY", "`driverid` BIGINT NOT NULL",
              "`circuitid` BIGINT NULL", "`laptime` TIME(6) NULL", "`fastest` BIGINT NULL", "`uid` CHAR(36) NULL",
              "`meta` JSON NULL", "`blob` LONGBLOB NULL", "`notes` LONGTEXT NOT NULL DEFAULT ('it''s')",
              "`points` DOUBLE NOT NULL DEFAULT 0.0", "`laps` BIGINT NOT NULL DEFAULT 0",
              "`grid` INT NOT NULL DEFAULT 0 CHECK (`grid` >= 0)", "`today` DATE NOT NULL DEFAULT (CURRENT_DATE)")
    @test (col, occursin(col, ddl)) == (col, true)
  end
  # No foreign key in the table: the planner adds each once every table exists, as on PostgreSQL.
  @test !occursin("REFERENCES", ddl) && !occursin('"', ddl)
  @test occursin("`url` VARCHAR(200) NOT NULL UNIQUE", _MD.create_table(_mm_my, _MmCircuit))
  # InnoDB has no deferrable key (#1272); SET_NULL is MySQL's own action.
  @test _MD.add_foreign_key(_mm_my, "result", "`result_circuitid_fk`", "`circuitid`", "`circuit`", "`circuitid`";
                            on_delete = "SET NULL") ==
        "ALTER TABLE `result` ADD CONSTRAINT `result_circuitid_fk` FOREIGN KEY (`circuitid`) REFERENCES `circuit` (`circuitid`) ON DELETE SET NULL;"
  # MySQL has no `CREATE INDEX IF NOT EXISTS`; a descending member keeps its direction.
  @test _MD.create_index(_mm_my, "`driver_forename_dob_desc_idx`", "`driver`", ["`forename`", "`dob`"];
                         descending = [false, true]) ==
        "CREATE INDEX `driver_forename_dob_desc_idx` ON `driver` (`forename`, `dob` DESC);"
  @test _MD.create_unique_index(_mm_my, "`driver_forename_code_uniq`", "`driver`", ["`forename`", "`code`"]) ==
        "CREATE UNIQUE INDEX `driver_forename_code_uniq` ON `driver` (`forename`, `code`);"
  @test _MD.drop_table(_mm_my, "driver") == "DROP TABLE IF EXISTS `driver`;"
  # A name with a backtick doubles it, as a `"` is doubled on the other engines.
  @test _MD._ddl_ident(_mm_my, "odd`name") == "`odd``name`"
  @test _MD._ddl_ident(MmMockPostgres(), "odd\"name") == "\"odd\"\"name\""
end

# What: the history and data-step tables, and every statement that reads or writes them.
# SQL: backtick-quoted names, `?` markers, `DATABASE()`-scoped catalog probes.
# Why: `migrate` reads `pormg_migrations` on every run; a double-quoted `"version"` there would order
# and filter by a constant, and an unscoped probe would see another database's history table.
@testset "#1268: the migration history SQL is MySQL's" begin
  stmts = [_MD.create_migrations_table(_mm_my), _MD.insert_migration_record_sql(_mm_my),
           _MD.update_migration_status_sql(_mm_my), _MD.select_all_migrations_sql(_mm_my),
           _MD.select_migration_by_version_sql(_mm_my), _MD.delete_migration_record_sql(_mm_my),
           _MD.migrations_table_exists_sql(_mm_my), _MD.add_format_version_column_sql(_mm_my),
           _MD.migrations_table_info_sql(_mm_my), _MD.create_data_steps_table(_mm_my),
           _MD.data_steps_table_exists_sql(_mm_my), _MD.insert_data_step_sql(_mm_my),
           _MD.select_data_step_sql(_mm_my), _MD.select_all_data_steps_sql(_mm_my)]
  for s in stmts
    @test (s, occursin('"', s) || occursin(r"\$\d", s)) == (s, false)
  end
  @test occursin("`sql_content` LONGTEXT NOT NULL DEFAULT ('')", stmts[1])
  @test occursin("`applied_at` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)", stmts[1])
  @test stmts[2] == "INSERT INTO `pormg_migrations` (`version`, `name`, `checksum`, `sql_content`, `status`, `is_destructive`, `format_version`) VALUES (?, ?, ?, ?, ?, ?, ?);"
  @test occursin("TABLE_SCHEMA = DATABASE()", stmts[7]) && occursin("TABLE_SCHEMA = DATABASE()", stmts[11])
end

# ─────────────────────────────────────────────────────────────────────────────
# The reader: what information_schema reports compiles to the declaration
# ─────────────────────────────────────────────────────────────────────────────

# What: `parse_canonical_type` over every type the MySQL map writes, as `COLUMN_TYPE` reports it.
# SQL: none.
# Why: the diff compares the two sides by canonical type; a reported spelling that parsed to another
# type than its rendering would re-plan the column forever, and a spelling PormG never writes
# (`tinyint(4)`, `datetime(6)`, an unsigned integer) must not equal a declaration.
@testset "#1268: a reported MySQL type parses as its rendering does" begin
  for model in (_MmCircuit, _MmDriver, _MmResult), (name, field) in model.fields
    rendered = _MD._get_column_type(field, _mm_my)
    @test (name, _MM.parse_canonical_type(lowercase(rendered), _mm_my)) ==
          (name, _MM.parse_canonical_type(rendered, _mm_my))
    @test (name, _MM.parse_canonical_type(rendered, _mm_my) isa PormG.CUnsupported) == (name, false)
  end
  for foreign in ("tinyint(4)", "tinyint", "datetime(6)", "datetime", "time", "char(10)", "text", "mediumtext",
                  "int unsigned", "bigint unsigned", "float", "blob", "timestamp")
    @test (foreign, _MM.parse_canonical_type(foreign, _mm_my)) == (foreign, PormG.CUnsupported(foreign))
  end
  # Each spelling the map writes, against the type it means: a deleted arm reads both sides of the law
  # above as the same `CUnsupported`, which only this table catches.
  for (spelling, want) in ("bigint" => PormG.CInt64(), "int" => PormG.CInt32(), "smallint" => PormG.CInt16(),
                           "tinyint(1)" => PormG.CBool(), "double" => PormG.CFloat64(),
                           "decimal(6,3)" => PormG.CDecimal(6, 3), "varchar(100)" => PormG.CVarChar(100),
                           "longtext" => PormG.CText(), "date" => PormG.CDate(),
                           "datetime(3)" => PormG.CDateTime(false), "time(6)" => PormG.CTime(),
                           "char(36)" => PormG.CUUID(), "json" => PormG.CJSON(), "longblob" => PormG.CBytes())
    @test (spelling, _MM.parse_canonical_type(spelling, _mm_my)) == (spelling, want)
    @test (spelling, _MM.parse_canonical_type(uppercase(spelling), _mm_my)) == (spelling, want)
  end
end

# What: a column default as `information_schema.COLUMNS` reports it, cleaned.
# SQL: none.
# Why: MySQL re-prints `CURRENT_TIMESTAMP(3)`, `curdate()`, and a literal written as an expression
# (`_utf8mb4\'…\'`, escaped twice); each must read back as what the declaration compiles to.
@testset "#1268: a reported MySQL default reads as its declaration" begin
  clean(text, generated, ctype = PormG.CText()) =
    _MM._clean_default(_MM._MySQLColumnDefault(text, generated), ctype, _mm_my)
  @test clean("CURRENT_TIMESTAMP(3)", true) == PormG._ExpressionDefault("CURRENT_TIMESTAMP")
  @test clean("curdate()", true) == PormG._ExpressionDefault("CURRENT_DATE")
  # As measured on 8.4 for `DEFAULT ('it''s a \\ b')`: the value is `it's a \ b`.
  @test clean("_utf8mb4\\'it\\\\\\'s a \\\\\\\\ b\\'", true) == "it's a \\ b"
  @test clean("_utf8mb4\\'{\"k\": 1}\\'", true) == "{\"k\": 1}"
  @test clean("lower(`x`)", true) == PormG._ExpressionDefault("lower(`x`)")
  @test clean("1", false, PormG.CBool()) === true && clean("0", false, PormG.CBool()) === false
  @test clean("a\\b'c", false, PormG.CVarChar(8)) == "a\\b'c"   # a literal is reported unescaped
  @test _MM._clean_default(nothing, PormG.CText(), _mm_my) === nothing
  # The literal written: MySQL reads a backslash as an escape, so it is doubled with the quote.
  @test _MD._format_default_sql_value("a\\b'c", _mm_my) == "'a\\\\b''c'"
end

# Synthetic catalog rows for the tables above, as MySQL 8.4 reports them after `migrate`.
_mm_col(tbl, col, ctype, nullable, dflt, extra, key) =
  (tbl = tbl, col = col, ctype = ctype, nullable = nullable, dflt = dflt, extra = extra, ckey = key)
_mm_stat(tbl, idx, non_unique, col, coll = "A"; sub_part = missing) =
  (tbl = tbl, idx = idx, non_unique = non_unique, col = col, coll = coll, sub_part = sub_part)

# What: `_mysql_live_table` over the rows MySQL reports for the DDL above, against `column_spec`.
# SQL: none.
# Why: this is the reader-equals-compiler law the whole diff rests on (#507): a table PormG just
# created must compile to the specs its declaration compiles to, or the next `makemigrations` re-plans
# it. Two MySQL-only facts ride on it: InnoDB's index for a foreign key is named after the constraint
# and declares nothing, and an inline `UNIQUE` is an index named after its column.
@testset "#1268: a table PormG created reads back as its declaration" begin
  cols = [_mm_col("result", "resultid", "bigint", "NO", missing, "auto_increment", "PRI"),
          _mm_col("result", "driverid", "bigint", "NO", missing, "", "MUL"),
          _mm_col("result", "circuitid", "bigint", "YES", missing, "", "MUL"),
          _mm_col("result", "laptime", "time(6)", "YES", missing, "", ""),
          _mm_col("result", "fastest", "bigint", "YES", missing, "", ""),
          _mm_col("result", "uid", "char(36)", "YES", missing, "", ""),
          _mm_col("result", "meta", "json", "YES", missing, "", ""),
          _mm_col("result", "blob", "longblob", "YES", missing, "", ""),
          _mm_col("result", "notes", "longtext", "NO", "_utf8mb4\\'it\\\\\\'s\\'", "DEFAULT_GENERATED", ""),
          _mm_col("result", "points", "double", "NO", "0", "", ""),
          _mm_col("result", "laps", "bigint", "NO", "0", "", ""),
          _mm_col("result", "grid", "int", "NO", "0", "", ""),
          _mm_col("result", "today", "date", "NO", "curdate()", "DEFAULT_GENERATED", "")]
  stats = [_mm_stat("result", "PRIMARY", 0, "resultid"),
           _mm_stat("result", "result_driverid_ab_fk", 1, "driverid"),        # InnoDB's own, for the key
           _mm_stat("result", "result_circuitid_cd_idx", 1, "circuitid")]
  fks = [(tbl = "result", name = "result_driverid_ab_fk", col = "driverid", parent = "driver", parent_col = "driverid", on_delete = "CASCADE"),
         (tbl = "result", name = "result_circuitid_cd_fk", col = "circuitid", parent = "circuit", parent_col = "circuitid", on_delete = "SET NULL")]
  checks = [(tbl = "result", name = "result_chk_1", clause = "(`grid` >= 0)")]
  live = _MM._mysql_live_table(_mm_my, "result", cols, stats, fks, checks)
  for (name, field) in _MmResult.fields
    @test (name, live.columns[String(name)]) == (name, _MM.column_spec(field, _mm_my; name = String(name)))
  end
  # The key's own index is not `db_index`'s; the declared index is.
  @test live.indexes == Dict{String, Union{String, Nothing}}("circuitid" => "result_circuitid_cd_idx")
  @test isempty(live.composites) && isempty(live.checks)

  # An inline UNIQUE is the column's; a descending composite and a named unique index are model-level.
  dstats = [_mm_stat("driver", "PRIMARY", 0, "driverid"), _mm_stat("driver", "forename", 0, "forename"),
            _mm_stat("driver", "driver_f_d_idx", 1, "forename"), _mm_stat("driver", "driver_f_d_idx", 1, "dob", "D"),
            _mm_stat("driver", "driver_code_uniq", 0, "code"),
            _mm_stat("driver", "driver_prefix_idx", 1, "code"; sub_part = 3)]   # a prefix index: not PormG's
  dcols = [_mm_col("driver", "driverid", "bigint", "NO", missing, "auto_increment", "PRI"),
           _mm_col("driver", "forename", "varchar(100)", "NO", missing, "", "UNI"),
           _mm_col("driver", "dob", "date", "YES", missing, "", ""),
           _mm_col("driver", "code", "varchar(8)", "NO", "a\\b'c", "", "")]
  dlive = _MM._mysql_live_table(_mm_my, "driver", dcols, dstats, Any[], Any[])
  @test dlive.columns["forename"].unique && !dlive.columns["code"].unique
  @test dlive.columns["code"].default == PormG.LiteralDefault("a\\b'c")
  @test isempty(dlive.indexes)
  @test sort!([(c.name, c.columns, c.unique, c.descending) for c in dlive.composites]) ==
        [("driver_code_uniq", ["code"], true, [false]), ("driver_f_d_idx", ["forename", "dob"], false, [false, true])]
  # A CHECK that is not one of PormG's two column shapes is the table's.
  other = _MM._mysql_live_table(_mm_my, "driver", dcols, Any[], Any[],
                                [(tbl = "driver", name = "driver_chk_1", clause = "(`dob` > _utf8mb4'1950-01-01')")])
  @test [(c.name, c.sql) for c in other.checks] == [("driver_chk_1", "(`dob` > _utf8mb4'1950-01-01')")]
end

# ─────────────────────────────────────────────────────────────────────────────
# What phase 4a refuses, and the #1268 atomic refusal
# ─────────────────────────────────────────────────────────────────────────────

# What: `migrate`'s promise that a plan applies whole, on a backend without transactional DDL.
# SQL: none — refused before the lock.
# Why: each MySQL DDL statement commits on its own, so a failure part-way leaves a part-applied schema;
# `migrate` must not run such a plan without the caller accepting that (#1268), and must not refuse a
# plan that is atomic anyway (one statement), nor any plan where the DDL is transactional.
@testset "#1268: a multi-statement plan on MySQL needs atomic = false" begin
  e = _mm_err(() -> _MM._require_atomic_plan(_mm_my, ["CREATE TABLE a (x INT)", "CREATE TABLE b (x INT)"], true))
  @test e isa PormG.BackendCapabilityError
  msg = sprint(showerror, e)
  @test occursin("2 statements", msg) && occursin("MySQL", msg) && occursin("atomic = false", msg) &&
        occursin("makemigrations", msg)
  @test _MM._require_atomic_plan(_mm_my, ["CREATE TABLE a (x INT)", "CREATE TABLE b (x INT)"], false) === nothing
  @test _MM._require_atomic_plan(_mm_my, ["CREATE TABLE a (x INT)"], true) === nothing
  @test _MM._require_atomic_plan(MmMockPostgres(), ["CREATE TABLE a (x INT)", "CREATE TABLE b (x INT)"], true) === nothing
  # The latest applied plan (the #81 re-archive) runs no statement again, so it is not refused; where DDL
  # is transactional the history is never asked.
  @test _MM._require_atomic_plan(_mm_my, ["CREATE TABLE a (x INT)", "CREATE TABLE b (x INT)"], true;
                                 applied = () -> true) === nothing
  @test _MM._require_atomic_plan(MmMockPostgres(), ["CREATE TABLE a (x INT)", "CREATE TABLE b (x INT)"], true;
                                 applied = () -> error("the history was asked")) === nothing
  @test !PormG._supports(_mm_my, :transactional_ddl) && PormG._supports(MmMockPostgres(), :transactional_ddl)
  # The PostgreSQL timeouts have no MySQL counterpart for DDL: refused, not ignored.
  e = _mm_err(() -> _MM._require_migration_timeouts(_mm_my, _MM._migration_timeouts(30, 5, nothing)))
  @test e isa PormG.UnsupportedConnectionError && occursin("phase 4b", sprint(showerror, e))
  @test _MM._require_migration_timeouts(_mm_my, _MM._migration_timeouts(30)) === nothing
end

# What: the declarations phase 4a cannot render for MySQL, each refused before any DDL.
# SQL: none.
# Why: each one would otherwise be written as another engine's DDL, or re-planned forever, because
# MySQL re-prints an expression and has nowhere to keep the marker that says PormG owns it (phase 4c).
@testset "#1268: what phase 4a does not render is refused, naming its phase" begin
  refused(f) = (e = _mm_err(f); e isa PormG.UnsupportedConnectionError ? sprint(showerror, e) : e)
  m = refused(() -> _MD.field_to_column("lowered", Models.CharField(db_default = (postgres = "lower('X')", sqlite = nothing)), _mm_my))
  @test m isa String && occursin("phase 4c", m) && occursin("lowered", m)
  @test occursin("phase 4c", refused(() -> _MD.create_index(_mm_my, "`i`", "`driver`", String[];
                                                            expressions = ["lower(`forename`)"])))
  checked = Models.Model("checked_driver", id = Models.IDField(), grid = Models.IntegerField();
                         constraints = [Models.CheckConstraint(condition = "grid >= 0", name = "grid_nonneg")])
  @test occursin("CheckConstraint", refused(() -> _MD.create_table(_mm_my, checked)))
  e = _mm_err(() -> _MD.create_index(_mm_my, "`i`", "`driver`", ["`dob`"]; condition = "dob IS NOT NULL"))
  @test e isa PormG.BackendCapabilityError && occursin("MySQL", sprint(showerror, e))
  e = _mm_err(() -> _MD.create_index(_mm_my, "`i`", "`driver`", ["`dob`"]; method = "gin"))
  @test e isa PormG.BackendCapabilityError
  @test occursin("phase 4b", refused(() -> PormG.Migrations.run_once(() -> nothing, _mm_my,
                                                                     PormG.Configuration.Settings(connections = _mm_my), "step")))
end

# What: the plan steps phase 4a writes on MySQL — a new table, and on a table that exists only a foreign
# key or an index it lacks — and the refusal of every other step.
# SQL: none.
# Why: a re-run after a stopped `migrate` (#1268) re-plans the part-applied schema, which is exactly a
# missing key or index on a table that exists; any other change to an existing table is phase 4b's and
# would otherwise reach a renderer MySQL lacks.
@testset "#1268: a MySQL plan on an existing table adds keys and indexes only" begin
  live = [PormG.Migrations.LiveTable("result", OrderedDict{String, PormG.ColumnSpec}(), Dict{String, Union{String, Nothing}}())]
  plan(steps...) = OrderedDict{Symbol, OrderedDict{String, String}}(:result => OrderedDict{String, String}(steps...),
                                                                    :driver => OrderedDict{String, String}("New model" => "CREATE …"))
  @test _MM._refuse_mysql_alter_plan(plan("New foreign key: driverid" => "ALTER …", "Create index on driverid" => "CREATE …",
                                          "Create index: result_idx" => "CREATE …"), live) === nothing
  for label in ("Remove field: grid", "Alter field: grid", "Drop table", "Rename field: grid", "New model",
                "Remove composite index: result_idx")
    e = _mm_err(() -> _MM._refuse_mysql_alter_plan(plan(label => "…"), live))
    @test (label, e isa PormG.UnsupportedConnectionError && occursin("phase 4b", sprint(showerror, e))) == (label, true)
  end
  # A column step: only a foreign key added to a column that has none.
  fk = _MmResult.fields["driverid"]
  declared = _MM.column_spec(fk, _mm_my; name = "driverid")
  bare = PormG.ColumnSpec(declared.name, declared.type, declared.nullable, declared.primary_key, declared.unique,
                          declared.default, nothing, declared.checks, declared.identity, declared.raw)
  add_key = PormG.ColumnDelta(declared, bare, [:reference])
  @test _MM._require_column_alters(_mm_my, :result, "driverid"; delta = add_key) === nothing
  @test _MD.alter_field(_mm_my, _MmResult, "driverid", fk, add_key) == ""
  retyped = PormG.ColumnDelta(declared, bare, [:type])
  for kw in ((delta = retyped,), (delta = add_key, renamed = true), (added = true,))
    e = _mm_err(() -> _MM._require_column_alters(_mm_my, :result, "driverid"; kw...))
    @test (kw, e isa PormG.UnsupportedConnectionError) == (kw, true)
  end
  @test _mm_err(() -> _MD.alter_field(_mm_my, _MmResult, "driverid", fk, retyped)) isa PormG.UnsupportedConnectionError
  @test _MM._require_column_alters(MmMockPostgres(), :result, "driverid"; delta = retyped) === nothing
  # Dropping a table is refused where the planner collects it.
  e = _mm_err(() -> _MM._refuse_dropped_table_dependents(_mm_my, Set(["lap_times"])))
  @test e isa PormG.UnsupportedConnectionError && occursin("lap_times", sprint(showerror, e))
  @test _MM._refuse_dropped_table_dependents(_mm_my, Set{String}()) === nothing
end

# A models file loaded as `makemigrations` loads it, and the plan the planner builds for it on a mock.
_mm_dir = mktempdir()
function _mm_schema(src)
  path = joinpath(_mm_dir, "m_$(time_ns()).jl")
  write(path, "module models\nimport PormG.Models\n" * src * "\nend\n")
  return _MM._load_current_models(path)
end
function _mm_plan(conn, live_src, declared_src)
  live = _MM.LiveTable[_MM.live_table(e[:model], conn) for (_, e) in _mm_schema(live_src)]
  plan = _MM.get_migration_plan(live, _mm_schema(declared_src), conn,
                                PormG.Configuration.Settings(connections = conn); interactive = false)
  conn isa PormG.PormGMySQL && _MM._refuse_mysql_alter_plan(plan, live)
  return plan
end
_mm_driver(extra = "", tail = "") =
  "Driver = Models.Model(\"driver\", driverid = Models.IDField(), forename = Models.CharField(max_length = 100, db_index = true), " *
  "code = Models.CharField(max_length = 8)$(extra)$(tail))"

# What: the planner, run on a MySQL table that exists, for each change phase 4a does not plan.
# SQL: none — each is refused while the plan is built.
# Why: the planner reaches a renderer or a catalog lookup for these before any plan-level check, and on
# MySQL each must name its phase (#1268), not fall into a `MethodError`; the changes 4a does plan (a
# missing key or index) still build.
@testset "#1268: a change to an existing MySQL table is refused while it is planned" begin
  base = _mm_driver()
  cases = ["a removed field" => (base, "Driver = Models.Model(\"driver\", driverid = Models.IDField(), forename = Models.CharField(max_length = 100, db_index = true))", "4b"),
           "an added field" => (base, _mm_driver(", nick = Models.CharField(max_length = 8, null = true)"), "4b"),
           "a retyped field" => (base, replace(base, "max_length = 8" => "max_length = 9"), "4b"),
           "a dropped db_index" => (base, replace(base, ", db_index = true" => ""), "4b"),
           "a dropped Index" => (_mm_driver("", "; indexes = [Models.Index(fields = (\"forename\", \"code\"), name = \"drv_fc_idx\")]"), base, "4b"),
           "an added CheckConstraint" => (base, _mm_driver("", "; constraints = [Models.CheckConstraint(condition = \"code <> ''\", name = \"code_nonempty\")]"), "4c"),
           "a renamed Index" => (_mm_driver("", "; indexes = [Models.Index(fields = (\"forename\", \"code\"), name = \"a_idx\")]"),
                                 _mm_driver("", "; indexes = [Models.Index(fields = (\"forename\", \"code\"), name = \"b_idx\")]"), "4b")]
  for (label, (live_src, declared_src, phase)) in cases
    e = _mm_err(() -> _mm_plan(_mm_my, live_src, declared_src))
    @test (label, e isa PormG.UnsupportedConnectionError && occursin("phase $(phase)", sprint(showerror, e))) == (label, true)
  end
  # A declared CHECK the table already holds, as the MySQL reader reports it: with no ownership marker, so
  # the planner would stamp one (`comment_check_constraint`), which is phase 4c's too.
  checked = _mm_driver("", "; constraints = [Models.CheckConstraint(condition = \"code <> ''\", name = \"code_nonempty\")]")
  live = [let t = _MM.live_table(e[:model], _mm_my)
            _MM.LiveTable(t.name, t.columns, t.indexes, t.composites,
                          [_MM.LiveCheck(c.name, c.sql, nothing) for c in t.checks])
          end for (_, e) in _mm_schema(checked)]
  e = _mm_err(() -> _MM.get_migration_plan(live, _mm_schema(checked), _mm_my,
                                           PormG.Configuration.Settings(connections = _mm_my); interactive = false))
  @test e isa PormG.UnsupportedConnectionError && occursin("phase 4c", sprint(showerror, e))
  # A table that lost its index and its composite (a stopped plan) is completed, not refused.
  plan = _mm_plan(_mm_my, replace(base, ", db_index = true" => ""),
                  _mm_driver("", "; indexes = [Models.Index(fields = (\"forename\", \"code\"), name = \"drv_fc_idx\")]"))
  @test sort!(collect(keys(plan[:driver]))) == ["Create index on forename", "Create index: drv_fc_idx"]
end

# What: a key or index over a column MySQL indexes only by a prefix — a TextField, a BinaryField, a
# JSONField — refused for the whole models file before the diff.
# SQL: none.
# Why: left to MySQL the `CREATE INDEX` fails (error 1170, 3152) after the table committed, and the fix is
# a retype phase 4a cannot plan; PostgreSQL and SQLite index such columns, so there it builds.
@testset "#1130: a key over unbounded text is refused on MySQL, before the plan" begin
  for (label, src) in ("a unique TextField" => "Lap = Models.Model(\"lap\", id = Models.IDField(), note = Models.TextField(unique = true))",
                       "an indexed BinaryField" => "Lap = Models.Model(\"lap\", id = Models.IDField(), raw = Models.BinaryField(db_index = true))",
                       "a unique EmailField" => "Lap = Models.Model(\"lap\", id = Models.IDField(), mail = Models.EmailField(unique = true))",
                       "a JSONField in an Index" => "Lap = Models.Model(\"lap\", id = Models.IDField(), meta = Models.JSONField(), n = Models.IntegerField(); indexes = [Models.Index(fields = (\"meta\", \"n\"))])")
    e = _mm_err(() -> _mm_plan(_mm_my, "", src))
    msg = e isa PormG.BackendCapabilityError ? sprint(showerror, e) : ""
    @test (label, occursin("MySQL", msg) && occursin("CharField", msg)) == (label, true)
    label == "a unique EmailField" && @test occursin("\"mail\"", msg) && occursin("(EmailField)", msg)
    @test (label, _mm_plan(MmMockPostgres(), "", src) isa AbstractDict) == (label, true)
  end
  # The same columns without a key or index build.
  @test haskey(_mm_plan(_mm_my, "", "Lap = Models.Model(\"lap\", id = Models.IDField(), note = Models.TextField(), raw = Models.BinaryField(null = true))"), :lap)
end

# What: the rows a key added to a table that exists would reject, counted in MySQL's own SQL.
# SQL: `SELECT CAST((SELECT COALESCE(SUM(n), 0) AS n FROM (SELECT COUNT(*) … GROUP BY … HAVING COUNT(*) > 1)
#      AS pormg_duplicates) AS SIGNED) AS n`, backtick names; a primary key also counts its NULLs.
# Why: a plan that finishes a stopped one adds a `UniqueConstraint` to a table that exists (#1268), and its
# pre-check must count on MySQL: the 4a counter refused every kind but a foreign key's, so `dry_run` and
# `migrate` raised. `BIGINT` is no MySQL `CAST` target, and a double-quoted name is a string literal there.
@testset "#1130: the rows a new key rejects are counted on MySQL" begin
  sqlof(kind; kw...) = first(_MM._precheck_sql(_mm_my, _MM.LossyAlter(kind, "driver", "code", "varchar(8)", "varchar(8)"; kw...)))
  dup(cols) = "SELECT COALESCE(SUM(n), 0) AS n FROM (SELECT COUNT(*) AS n FROM `driver` WHERE " *
              join(("$c IS NOT NULL" for c in cols), " AND ") * " GROUP BY $(join(cols, ", ")) HAVING COUNT(*) > 1) AS pormg_duplicates"
  @test sqlof(:add_unique) == "SELECT CAST(($(dup(["`code`"]))) AS SIGNED) AS n"
  @test sqlof(:add_composite_unique; columns = ("forename", "code")) ==
        "SELECT CAST(($(dup(["`forename`", "`code`"]))) AS SIGNED) AS n"
  # A MySQL primary key makes its column NOT NULL, so a NULL fails it too.
  @test sqlof(:add_primary_key) ==
        "SELECT CAST(($(dup(["`code`"]))) + (SELECT COUNT(*) FROM `driver` WHERE `code` IS NULL) AS SIGNED) AS n"
  @test occursin("FROM `driver` AS pormg_child WHERE pormg_child.`code` IS NOT NULL AND NOT EXISTS (SELECT 1 FROM `circuit`",
                 sqlof(:add_foreign_key; references = ("circuit", "circuitid")))
  @test _MM._pk_precheck_counts_nulls(_mm_my)
end
