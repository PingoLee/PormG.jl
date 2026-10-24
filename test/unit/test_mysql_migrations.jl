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
  @test occursin("DROP TABLE IF EXISTS `driver`;", _MD.drop_table(_mm_my, "driver"))   # with the key checks off (4b)
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
  # `lock_timeout` is MySQL's `lock_wait_timeout`; a statement's run time has no DDL bound there, so
  # `statement_timeout` is refused through the capability table, not ignored.
  @test _MM._require_migration_timeouts(_mm_my, _MM._migration_timeouts(30, 5, nothing)) === nothing
  e = _mm_err(() -> _MM._require_migration_timeouts(_mm_my, _MM._migration_timeouts(30, nothing, 5)))
  @test e isa PormG.BackendCapabilityError && occursin("statement_timeout", sprint(showerror, e)) &&
        occursin("MySQL", sprint(showerror, e))
  @test _MM._require_migration_timeouts(MmMockPostgres(), _MM._migration_timeouts(30, nothing, 5)) === nothing
  @test _MM._require_migration_timeouts(_mm_my, _MM._migration_timeouts(30)) === nothing
  # An entry holding several statements counts each, the session `SET`s aside.
  @test _MM._plan_statement_count(_mm_my, [_MD.drop_table(_mm_my, "driver")]) == 1
  @test _MM._plan_statement_count(_mm_my, ["UPDATE `driver` SET `code` = 'a;b'; UPDATE `driver` SET `code` = 'c'"]) == 2
  @test _MM._split_mysql_statements("UPDATE `a;b` SET `c` = 'x;y' -- one; two\n; SELECT \"q;\" /* ; */ ;") ==
        ["UPDATE `a;b` SET `c` = 'x;y' -- one; two", "SELECT \"q;\" /* ; */"]
  @test _MM._split_mysql_statements("SELECT 'it\\'s; ok', 'a''b;'") == ["SELECT 'it\\'s; ok', 'a''b;'"]
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
end

# The catalog lookups a plan on a table that exists asks, answered for the mock as MySQL would for the
# tables these tests describe: MySQL names a CHECK itself, a column's `db_index` index and its foreign key
# are PormG's names, and InnoDB's own index for a key is named after it.
_MM.get_constraints_checks(::MmMockMySQL, table::String, column::String) = ["$(table)_chk_1"]
_MM.get_constraints_byte_length_checks(::MmMockMySQL, table::String, column::String) = ["$(table)_chk_2"]
_MM.get_constraints_index(::MmMockMySQL, table::Symbol, column::String) = "$(table)_$(column)_idx"
_MM.get_constraints_fk(::MmMockMySQL, table::Symbol, column::String) = "$(table)_$(column)_fk"
_MM._foreign_key_leaves_index(::MmMockMySQL, table, name::AbstractString) = true
# A column with nothing beyond what the model states.
PormG._column_attributes(::MmMockMySQL, table::AbstractString, column::AbstractString) = nothing

# A delta between two fields of the fixtures, as the planner builds it.
_mm_delta(new, old; name = "c", old_name = name) =
  _MM.column_delta(new, _MM.column_spec(old, _mm_my; name = old_name), _mm_my; name = name)

# What: each change to a column of a MySQL table that exists, as the one statement it renders.
# SQL: `ALTER TABLE `t` <clause>, …;` — `MODIFY COLUMN` restating the column's whole body, `DROP CHECK` by
#      the catalog's name and `ADD CHECK` in the reader's shape, `ADD UNIQUE INDEX `c` (`c`)` / `DROP INDEX`,
#      `ADD`/`DROP PRIMARY KEY` beside the `AUTO_INCREMENT`.
# Why: MODIFY replaces what it does not restate (a default, `AUTO_INCREMENT`, `NOT NULL`) and keeps the
# indexes and CHECKs, so restating `UNIQUE` there adds a second index; one statement per change keeps a
# change whole on an engine whose DDL commits each statement (#1268).
@testset "#1130: a column change is one MySQL ALTER TABLE" begin
  alter(new, old; kw...) = _MD.alter_field(_mm_my, _MmDriver, "c", new, _mm_delta(new, old; kw...))
  @test alter(Models.CharField(max_length = 12), Models.CharField(max_length = 8)) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` VARCHAR(12) NOT NULL;"
  # A unique column keeps its index through MODIFY, so `UNIQUE` is not restated (it would add `c_2`).
  @test alter(Models.CharField(max_length = 12, unique = true), Models.CharField(max_length = 8, unique = true)) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` VARCHAR(12) NOT NULL;"
  # A descending index carries PormG's bare marker as its COMMENT, so a later plan may drop it.
  @test _MD.create_index(_mm_my, "`a_idx`", "`driver`", ["`abbr`", "`pts`"]; descending = [false, true],
                         marker = PormG.INDEX_MARKER) ==
        "CREATE INDEX `a_idx` ON `driver` (`abbr`, `pts` DESC) COMMENT 'pormg:index';"
  # A default change is a MODIFY too (`SET DEFAULT ('x')` on a LONGTEXT is error 1101), the default restated.
  @test alter(Models.TextField(default = "x"), Models.TextField()) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` LONGTEXT NOT NULL DEFAULT ('x');"
  @test alter(Models.IntegerField(null = true), Models.IntegerField()) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` INT NULL;"
  # PormG's CHECK follows the type: dropped by its catalog name, added in the reader's shape.
  @test alter(Models.IntegerField(), Models.PositiveIntegerField()) ==
        "ALTER TABLE `driver` DROP CHECK `driver_chk_1`;"
  @test alter(Models.PositiveIntegerField(), Models.IntegerField()) ==
        "ALTER TABLE `driver` ADD CHECK (`c` >= 0);"
  @test alter(Models.PositiveIntegerField(), Models.BigIntegerField()) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` INT NOT NULL, ADD CHECK (`c` >= 0);"
  @test alter(Models.BinaryField(max_length = 16), Models.BinaryField(max_length = 8)) ==
        "ALTER TABLE `driver` DROP CHECK `driver_chk_2`, ADD CHECK (LENGTH(`c`) <= 16);"
  # The column's own unique index carries its name, so adding and dropping it name the column.
  @test alter(Models.CharField(max_length = 8, unique = true), Models.CharField(max_length = 8)) ==
        "ALTER TABLE `driver` ADD UNIQUE INDEX `c` (`c`);"
  @test alter(Models.CharField(max_length = 8), Models.CharField(max_length = 8, unique = true)) ==
        "ALTER TABLE `driver` DROP INDEX `c`;"
  # A foreign key added to a column that has none is the planner's `ADD CONSTRAINT`: nothing to alter.
  fk = _MmResult.fields["driverid"]
  bare = Models.BigIntegerField()
  @test _MD.alter_field(_mm_my, _MmResult, "driverid", fk, _mm_delta(fk, bare; name = "driverid")) == ""
  # A renamed column: the CHECK MySQL will not let it take along is dropped and added back, its unique
  # index renamed with it, in the one statement.
  old_spec = _MM.column_spec(Models.PositiveIntegerField(unique = true), _mm_my; name = "number")
  new_spec = _MM.column_spec(Models.PositiveIntegerField(unique = true), _mm_my; name = "num")
  @test _MD.rename_field(_mm_my, "driver", "number", "num"; old_spec = old_spec, new_spec = new_spec) ==
        "ALTER TABLE `driver` DROP CHECK `driver_chk_1`, RENAME COLUMN `number` TO `num`, " *
        "RENAME INDEX `number` TO `num`, ADD CHECK (`num` >= 0);"
  @test _MD.rename_field(_mm_my, "driver", "code", "abbr") == "ALTER TABLE `driver` RENAME COLUMN `code` TO `abbr`;"
  # Added and dropped columns; the inline keys and CHECKs of `CREATE TABLE`.
  @test _MD.add_field(_mm_my, "driver", "number", Models.PositiveSmallIntegerField(null = true)) ==
        "ALTER TABLE `driver` ADD COLUMN `number` SMALLINT NULL CHECK (`number` >= 0);"
  @test _MD.drop_field(_mm_my, "driver", "number") == "ALTER TABLE `driver` DROP COLUMN `number`;"
  # Keys, indexes and tables: each names its table, as MySQL scopes an index per table.
  @test _MD.drop_foreign_key(_mm_my, :result, "result_driverid_fk"; with_index = true) ==
        "ALTER TABLE `result` DROP FOREIGN KEY `result_driverid_fk`, DROP INDEX `result_driverid_fk`;"
  @test _MD.drop_foreign_key(_mm_my, :result, "result_driverid_fk") ==
        "ALTER TABLE `result` DROP FOREIGN KEY `result_driverid_fk`;"
  @test _MD.drop_index(_mm_my, "driver_code_idx"; table = "driver") == "DROP INDEX `driver_code_idx` ON `driver`;"
  @test _MD.rename_index(_mm_my, "a_idx", "b_idx"; table = "driver") ==
        "ALTER TABLE `driver` RENAME INDEX `a_idx` TO `b_idx`;"
  @test _MD.rename_table(_mm_my, "driver", "pilot") == "RENAME TABLE `driver` TO `pilot`;"
  @test _MD.drop_table(_mm_my, "driver") ==
        "SET FOREIGN_KEY_CHECKS = 0;\nDROP TABLE IF EXISTS `driver`;\nSET FOREIGN_KEY_CHECKS = 1;"
  # PostgreSQL and SQLite take the keywords only MySQL reads, and render as before.
  @test _MD.drop_index(MmMockPostgres(), "driver_code_idx"; table = "driver") == "DROP INDEX IF EXISTS \"driver_code_idx\";"
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
  return _MM.get_migration_plan(live, _mm_schema(declared_src), conn,
                                PormG.Configuration.Settings(connections = conn); interactive = false)
end
_mm_driver(extra = "", tail = "") =
  "Driver = Models.Model(\"driver\", driverid = Models.IDField(), forename = Models.CharField(max_length = 100, db_index = true), " *
  "code = Models.CharField(max_length = 8)$(extra)$(tail))"

# What: the planner, run on a MySQL table that exists, for each kind of change to it.
# SQL: each step's MySQL statement, as asserted per case.
# Why: until phase 4b every one of these was refused (#1268); each must now reach MySQL's own renderer —
# a dropped index naming its table, a removed column its `DROP COLUMN`, a renamed index `RENAME INDEX` —
# and a declared CheckConstraint, phase 4c's, is still refused.
@testset "#1130: a change to an existing MySQL table plans MySQL's DDL" begin
  base = _mm_driver()
  indexed(n) = _mm_driver("", "; indexes = [Models.Index(fields = (\"forename\", \"code\"), name = \"$(n)\")]")
  cases = ["a removed field" => (base, "Driver = Models.Model(\"driver\", driverid = Models.IDField(), forename = Models.CharField(max_length = 100, db_index = true))",
                                 "Remove field: code" => "ALTER TABLE `driver` DROP COLUMN `code`;"),
           "an added field" => (base, _mm_driver(", nick = Models.CharField(max_length = 8, null = true)"),
                                "Add field: nick" => "ALTER TABLE `driver` ADD COLUMN `nick` VARCHAR(8) NULL;"),
           "a retyped field" => (base, replace(base, "max_length = 8" => "max_length = 9"),
                                 "Alter field: code" => "ALTER TABLE `driver` MODIFY COLUMN `code` VARCHAR(9) NOT NULL;"),
           "a dropped db_index" => (base, replace(base, ", db_index = true" => ""),
                                    "Remove index on forename" => "DROP INDEX `driver_forename_idx` ON `driver`;"),
           "a dropped Index" => (indexed("drv_fc_idx"), base,
                                 "Remove composite index: drv_fc_idx" => "DROP INDEX `drv_fc_idx` ON `driver`;"),
           "a renamed Index" => (indexed("a_idx"), indexed("b_idx"),
                                 "Rename composite index: a_idx" => "ALTER TABLE `driver` RENAME INDEX `a_idx` TO `b_idx`;")]
  for (label, (live_src, declared_src, (step, sql))) in cases
    plan = _mm_plan(_mm_my, live_src, declared_src)
    @test (label, get(plan[:driver], step, nothing)) == (label, sql)
  end
  e = _mm_err(() -> _mm_plan(_mm_my, base, _mm_driver("", "; constraints = [Models.CheckConstraint(condition = \"code <> ''\", name = \"code_nonempty\")]")))
  @test e isa PormG.UnsupportedConnectionError && occursin("phase 4c", sprint(showerror, e))
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

# What: the rows a column change would fail, counted in MySQL's own SQL, kind by kind.
# SQL: `SELECT COUNT(*) AS n FROM `driver` WHERE <predicate>`, each value bound.
# Why: under strict mode a row that does not convert or fit fails the ALTER part-way through a plan
# (#1268), so each must be counted first and exactly: a string too long counts its trailing spaces
# (MySQL refuses them, where PostgreSQL trims), and text into a number, a date or JSON is MySQL's own
# grammar — no `pg_input_is_valid`, no `::numeric`.
@testset "#1130: the rows a column change fails are counted on MySQL" begin
  q(kind; old = "varchar(8)", new = "varchar(8)", kw...) =
    _MM._precheck_sql(_mm_my, _MM.LossyAlter(kind, "driver", "c", old, new; kw...))
  @test q(:varchar_length; bound = 3) == ("SELECT COUNT(*) AS n FROM `driver` WHERE CHAR_LENGTH(CAST(`c` AS CHAR)) > ?", Any[3])
  @test q(:set_not_null) == ("SELECT COUNT(*) AS n FROM `driver` WHERE `c` IS NULL", Any[])
  @test q(:add_not_null) == ("SELECT COUNT(*) AS n FROM `driver`", Any[])
  @test q(:non_negative_check) == ("SELECT COUNT(*) AS n FROM `driver` WHERE `c` < 0", Any[])
  @test q(:byte_length_check; bound = 16) == ("SELECT COUNT(*) AS n FROM `driver` WHERE LENGTH(`c`) > ?", Any[16])
  @test q(:integer_range; bound = 16) ==
        ("SELECT COUNT(*) AS n FROM `driver` WHERE ROUND(CAST(`c` AS DECIMAL(65, 30))) NOT BETWEEN ? AND ?", Any[-32768, 32767])
  @test last(q(:integer_range; bound = 8)) == Any[-128, 127]   # a TINYINT(1), MySQL's boolean
  @test q(:decimal_precision; bound = 4, scale = 2) ==
        ("SELECT COUNT(*) AS n FROM `driver` WHERE ABS(ROUND(CAST(`c` AS DECIMAL(65, 30)), ?)) >= " *
         "CAST(CONCAT('1', REPEAT('0', ?)) AS DECIMAL(65, 0))", Any[2, 4])
  int_sql, int_params = q(:text_cast; old = "longtext", new = "INT")
  @test int_sql == "SELECT COUNT(*) AS n FROM `driver` WHERE `c` IS NOT NULL AND " *
                   "NOT (REGEXP_LIKE(`c`, ?) AND CAST(TRIM(`c`) AS DECIMAL(65, 0)) BETWEEN ? AND ?)"
  @test int_params[2:3] == Any[-2147483648, 2147483647]
  @test occursin("CAST(`c` AS DATE) IS NULL", first(q(:text_cast; old = "longtext", new = "DATE")))
  @test occursin("NOT JSON_VALID(`c`)", first(q(:text_cast; old = "longtext", new = "JSON")))
  @test occursin("NOT REGEXP_LIKE(`c`, ?)", first(q(:text_cast; old = "longtext", new = "CHAR(36)")))
  # A change MySQL applies and changes values with is reported, not counted.
  @test q(:decimal_scale; scale = 1) === nothing && q(:to_date) === nothing
  # The classifier: under strict mode, text into a number fails its rows; a shorter string too.
  found(old, new) = sort!([f.kind for f in _MM._lossy_type_alters(_MM.parse_canonical_type(old, _mm_my),
                                                                  _MM.parse_canonical_type(new, _mm_my), _mm_my,
                                                                  (k; kw...) -> _MM.LossyAlter(k, "t", "c", old, new; kw...))])
  @test found("longtext", "INT") == [:text_cast]
  @test found("varchar(10)", "VARCHAR(3)") == [:varchar_length]
  @test found("int", "SMALLINT") == [:integer_range]
  @test found("int", "TINYINT(1)") == [:integer_range, :to_boolean]
  @test found("decimal(10,3)", "DECIMAL(10,1)") == [:decimal_scale]
  @test found("datetime(3)", "DATE") == [:to_date]
  @test found("int", "BIGINT") == Symbol[]
end

# What: the destructive guard over MySQL's statements, and the statements `ensure_table!` runs there.
# SQL: ``ALTER TABLE `t` ALTER COLUMN `c` DROP DEFAULT`` is not destructive; a `DROP COLUMN`, `DROP CHECK`,
#      `DROP INDEX` or `DROP FOREIGN KEY` is. `ensure_table!` runs the CREATE TABLE and the keys a migration
#      would, in MySQL's spelling.
# Why: the guard recognised a property drop only on a double-quoted or bare name, so a backticked one read
# as a destructive `DROP`; and `ensure_table!` had no MySQL statements.
@testset "#1130: the destructive guard and ensure_table! on MySQL" begin
  @test !_MM.is_destructive("ALTER TABLE `driver` ALTER COLUMN `code` DROP DEFAULT;")
  @test !_MM.is_destructive("ALTER TABLE `driver` ALTER COLUMN `co``de` DROP NOT NULL;")
  for sql in ("ALTER TABLE `driver` DROP COLUMN `code`;", "ALTER TABLE `driver` DROP CHECK `driver_chk_1`;",
              "DROP INDEX `a_idx` ON `driver`;", "ALTER TABLE `result` DROP FOREIGN KEY `k`, DROP INDEX `k`;")
    @test (sql, _MM.is_destructive(sql)) == (sql, true)
  end
  stmts = _MM._ensure_table_statements(_mm_my, _MmResult)
  @test startswith(first(stmts), "CREATE TABLE IF NOT EXISTS `result`")
  @test count(st -> occursin("ADD CONSTRAINT", st), stmts) == 2 && !any(st -> occursin('"', st), stmts)
  @test !any(st -> startswith(st, "CREATE INDEX"), _MM._ensure_table_statements(_mm_my, _MmResult; indexes = false))
  @test _MD.drop_table_only(_mm_my, "result") == "DROP TABLE IF EXISTS `result`;"
end

# What: a model-level index name PormG derives, fitted to MySQL's 64-character limit.
# SQL: `CREATE UNIQUE INDEX `<first 55>_<8 hex>` …` for a derived name past 64 characters.
# Why: a many-to-many join table's derived name (`<table>_<col>_<col>_uniq`) runs past 64 characters,
# which MySQL refuses (1059) where PostgreSQL cuts it itself; the fitted name must be the same on every
# plan, and a name the model wrote is left as written.
@testset "#1130: a long derived index name fits MySQL" begin
  long = "m2m_driver_endorsement_scratch_sponsors_m2m_driver_endorsement_scratch_id_m2m_sponsor_scratch_id_uniq"
  d = _MM.DeclaredComposite(long, ["a", "b"], true, false, true)
  fitted = _MM._fit_derived_name(_mm_my, d)
  @test length(fitted.name) == 64 && startswith(fitted.name, first(long, 55) * "_")
  @test fitted.name == _MM._fit_derived_name(_mm_my, d).name                 # the same on every plan
  @test fitted.columns == d.columns && fitted.unique && fitted.auto
  @test _MM._fit_derived_name(_mm_my, _MM.DeclaredComposite(long, ["a"], true, true, false)).name == long   # explicit
  @test _MM._fit_derived_name(_mm_my, _MM.DeclaredComposite("short_uniq", ["a"], true, false, false)).name == "short_uniq"
  @test _MM._fit_derived_name(MmMockPostgres(), d).name == long
end

# A column whose catalog holds what no model states: a COMMENT, INVISIBLE, ON UPDATE, its own collation and
# an expression default. Its CHECK lookups answer as `MmMockMySQL`'s do.
struct MmMockMySQLAttr <: PormG.PormGMySQL end
PormG._column_attributes(::MmMockMySQLAttr, table::AbstractString, column::AbstractString) =
  (comment = "it's", invisible = true, on_update = true, collation = "utf8mb4_0900_ai_ci", default_expression = "uuid()",
   generated = false)
# A generated column made by hand, which the reader takes for a plain one.
struct MmMockMySQLGen <: PormG.PormGMySQL end
PormG._column_attributes(::MmMockMySQLGen, table::AbstractString, column::AbstractString) =
  (comment = "", invisible = false, on_update = false, collation = nothing, default_expression = nothing, generated = true)

# What: a MODIFY on MySQL restates what the column holds that the model does not state.
# SQL: `MODIFY COLUMN `c` VARCHAR(8) NULL DEFAULT (uuid()) INVISIBLE COMMENT 'it''s' COLLATE utf8mb4_0900_ai_ci`;
#      `DATETIME(3) NULL ON UPDATE CURRENT_TIMESTAMP(3) INVISIBLE COMMENT 'it''s'` on a timestamp.
# Why: MODIFY resets what it does not restate (measured), where PostgreSQL's per-slot ALTER changes only the
# slot; an expression default the model does not declare is kept unless the type changes, and a retype that
# drops it records `:drop_default`, which takes `destructive = true`, as PostgreSQL's `USING` retype does.
@testset "#1130: a MySQL MODIFY keeps what the model does not state" begin
  at = MmMockMySQLAttr()
  with_uuid(field) = _MM._with_default(_MM.column_spec(field, at; name = "c"), PormG.ExpressionDefault("uuid()"))
  delta(new, old_spec) = _MM.column_delta(new, old_spec, at; name = "c")
  nullable = delta(Models.CharField(max_length = 8, null = true), with_uuid(Models.CharField(max_length = 8)))
  @test _MD.alter_field(at, _MmDriver, "c", Models.CharField(max_length = 8, null = true), nullable) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` VARCHAR(8) NULL DEFAULT (uuid()) INVISIBLE COMMENT 'it''s' " *
        "COLLATE utf8mb4_0900_ai_ci;"
  @test !any(f -> f.kind === :drop_default, _MM._lossy_alters(nullable, at; table = "driver", column = "c"))
  retyped = delta(Models.CharField(max_length = 12), with_uuid(Models.CharField(max_length = 8)))
  @test _MD.alter_field(at, _MmDriver, "c", Models.CharField(max_length = 12), retyped) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` VARCHAR(12) NOT NULL INVISIBLE COMMENT 'it''s' COLLATE utf8mb4_0900_ai_ci;"
  @test any(f -> f.kind === :drop_default, _MM._lossy_alters(retyped, at; table = "driver", column = "c"))
  # ON UPDATE at the column's own precision on a timestamp, and no collation on a column that is not text;
  # the catalog's expression default is not restated over a column the delta says has none.
  stamp = _mm_delta(Models.DateTimeField(null = true), Models.DateTimeField())
  @test _MD.alter_field(at, _MmDriver, "c", Models.DateTimeField(null = true), stamp) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` DATETIME(3) NULL ON UPDATE CURRENT_TIMESTAMP(3) INVISIBLE COMMENT 'it''s';"
  @test _MD._mysql_restated_default("CURRENT_TIMESTAMP(3)") == "DEFAULT CURRENT_TIMESTAMP(3)"
  # A MODIFY would end a generated column's generation (STORED) or fail (VIRTUAL, 3106): refused.
  gen = MmMockMySQLGen()
  e = _mm_err(() -> _MD.alter_field(gen, _MmDriver, "c", Models.IntegerField(null = true),
                                    _MM.column_delta(Models.IntegerField(null = true),
                                                     _MM.column_spec(Models.IntegerField(), gen; name = "c"), gen; name = "c")))
  @test e isa PormG.UnsupportedConnectionError && occursin("generated column \"c\"", sprint(showerror, e))
  # A column with nothing else, as before.
  @test _MD.alter_field(_mm_my, _MmDriver, "c", Models.CharField(max_length = 8, null = true),
                        _mm_delta(Models.CharField(max_length = 8, null = true), Models.CharField(max_length = 8))) ==
        "ALTER TABLE `driver` MODIFY COLUMN `c` VARCHAR(8) NULL;"
end

# What: a CHECK dropped in the plan that also renames the table.
# SQL: `ALTER TABLE `pilot` DROP CHECK `pilot_chk_1``, the catalog read under `driver`.
# Why: the table rename runs first, and MySQL renames the CHECKs it named itself with the table (measured);
# the name read before the plan must be the one the table has when the DROP runs, or the plan fails part-way
# (3821, and 3959 for a renamed column) after `RENAME TABLE` committed.
@testset "#1130: a CHECK's name follows the table's rename on MySQL" begin
  pilot = Models.Model("pilot", id = Models.IDField(), c = Models.IntegerField())
  @test _MD.alter_field(_mm_my, pilot, "c", Models.IntegerField(),
                        _mm_delta(Models.IntegerField(), Models.PositiveIntegerField()); catalog_table = "driver") ==
        "ALTER TABLE `pilot` DROP CHECK `pilot_chk_1`;"
  old_spec = _MM.column_spec(Models.PositiveIntegerField(), _mm_my; name = "number")
  new_spec = _MM.column_spec(Models.PositiveIntegerField(), _mm_my; name = "num")
  @test _MD.rename_field(_mm_my, "pilot", "number", "num"; old_spec = old_spec, new_spec = new_spec,
                         catalog_table = "driver") ==
        "ALTER TABLE `pilot` DROP CHECK `pilot_chk_1`, RENAME COLUMN `number` TO `num`, ADD CHECK (`num` >= 0);"
  # Every `<table>_chk_` name follows the table, one a constraint was given included; another name, and
  # one under a table the plan does not rename, are kept.
  @test _MD._mysql_check_after_rename("mine", "driver", "pilot") == "mine"
  @test _MD._mysql_check_after_rename("driver_chk_x", "driver", "pilot") == "pilot_chk_x"
  @test _MD._mysql_check_after_rename("driver_chk_2", "driver", "driver") == "driver_chk_2"
end

# What: the MySQL retypes whose conversion gives every value another meaning, or fails on rows nothing counts.
# SQL: none — the plan is refused (`:no_implicit_cast`), before any statement.
# Why: MySQL turns a DATE into a TIME as midnight, a TIME into today's date, a date into its digits, a
# number into a date read from such digits, a number into a UUID's CHAR(36) as text (measured on 8.4);
# PostgreSQL has no cast for these pairs and refuses them, so the engine that departs refuses on itself.
# The pairs that keep the value build.
@testset "#1130: the MySQL retypes that change every value are refused" begin
  kinds(new, old) = [f.kind for f in _MM._lossy_alters(_mm_delta(new, old), _mm_my; table = "driver", column = "c")]
  for (old, new) in ((Models.DateField(), Models.TimeField()), (Models.TimeField(), Models.DateField()),
                     (Models.TimeField(), Models.DateTimeField()), (Models.DateField(), Models.IntegerField()),
                     (Models.DateTimeField(), Models.BigIntegerField()), (Models.IntegerField(), Models.DateField()),
                     (Models.BooleanField(), Models.DateField()), (Models.IntegerField(), Models.UUIDField()),
                     (Models.JSONField(), Models.IntegerField()), (Models.UUIDField(), Models.JSONField()),
                     (Models.DateField(), Models.JSONField()), (Models.BooleanField(), Models.JSONField()),
                     (Models.BinaryField(), Models.IntegerField()), (Models.IntegerField(), Models.BinaryField()),
                     (Models.DateField(), Models.BinaryField()), (Models.BinaryField(), Models.JSONField()))
    @test (typeof(old), typeof(new), kinds(new, old)) == (typeof(old), typeof(new), [:no_implicit_cast])
  end
  @test kinds(Models.DateTimeField(), Models.DateField()) == Symbol[]
  @test kinds(Models.JSONField(), Models.IntegerField()) == Symbol[]
  @test kinds(Models.DateField(), Models.CharField(max_length = 20)) == [:text_cast]
  @test kinds(Models.DateField(), Models.DateTimeField()) == [:to_date]
end

# What: a composite index over a column the plan drops, on MySQL.
# SQL: `DROP INDEX `drv_fc_idx` ON `driver``, then `ALTER TABLE `driver` DROP COLUMN `code``.
# Why: MySQL narrows such an index to the columns that remain (a `UNIQUE (a, b)` becomes `UNIQUE (a)`, and
# the DROP COLUMN fails on its duplicates), where PostgreSQL drops it with the column; it is dropped first.
@testset "#1130: an index over a dropped column is dropped first on MySQL" begin
  live = _mm_driver("", "; indexes = [Models.Index(fields = (\"forename\", \"code\"), name = \"drv_fc_idx\")]")
  declared = "Driver = Models.Model(\"driver\", driverid = Models.IDField(), forename = Models.CharField(max_length = 100, db_index = true))"
  steps = collect(keys(_mm_plan(_mm_my, live, declared)[:driver]))
  index_at, field_at = findfirst(==("Remove composite index: drv_fc_idx"), steps), findfirst(==("Remove field: code"), steps)
  @test index_at !== nothing && field_at !== nothing && index_at < field_at
  # Every other step keeps its place: the old key's column still goes before the key moves (1068 otherwise).
  moved = "Driver = Models.Model(\"driver\", legacyid = Models.IDField(), driverid = Models.BigIntegerField(), " *
          "forename = Models.CharField(max_length = 100), code = Models.CharField(max_length = 8); " *
          "indexes = [Models.Index(fields = (\"forename\", \"code\"), name = \"drv_fc_idx\")])"
  steps = collect(keys(_mm_plan(_mm_my, moved, "Driver = Models.Model(\"driver\", driverid = Models.IDField(), " *
                                                 "forename = Models.CharField(max_length = 100))")[:driver]))
  at(k) = findfirst(==(k), steps)
  @test at("Remove composite index: drv_fc_idx") < at("Remove field: legacyid") < at("Alter field: driverid")
  # A non-unique index led by a foreign-key column that stays is left to MySQL's narrowing: it is the key's
  # index (dropping it is 1553). A unique one is dropped.
  lap(n, tail) = "Circuit = Models.Model(\"circuit\", circuitid = Models.IDField())\n" *
                 "Lap = Models.Model(\"lap\", lapid = Models.IDField(), circuitid = Models.ForeignKey(Circuit, pk_field = \"circuitid\")$(n)$(tail))"
  n = ", n = Models.IntegerField()"
  keeps = _mm_plan(_mm_my, lap(n, "; indexes = [Models.Index(fields = (\"circuitid\", \"n\"), name = \"lap_cn_idx\")]"), lap("", ""))
  @test haskey(keeps[:lap], "Remove field: n") && !haskey(keeps[:lap], "Remove composite index: lap_cn_idx")
  drops = _mm_plan(_mm_my, lap(n, "; constraints = [Models.UniqueConstraint(fields = (\"circuitid\", \"n\"), name = \"lap_cn_uniq\")]"), lap("", ""))
  @test haskey(drops[:lap], "Remove composite index: lap_cn_uniq")
end

# What: the refusal of a plan that cannot apply whole counts statements, not plan entries.
# SQL: none.
# Why: a hand-written step holding two statements is two commits on MySQL, as two entries are.
@testset "#1130: one entry of two statements is not atomic on MySQL" begin
  e = _mm_err(() -> _MM._require_atomic_plan(_mm_my, ["UPDATE a SET x = 1; UPDATE b SET y = 2"], true))
  @test e isa PormG.BackendCapabilityError && occursin("2 statements", sprint(showerror, e))
  @test _MM._require_atomic_plan(_mm_my, ["UPDATE a SET x = 1"], true) === nothing
  @test _MM._require_atomic_plan(_mm_my, ["UPDATE a SET x = 1; UPDATE b SET y = 2"], false) === nothing
end
