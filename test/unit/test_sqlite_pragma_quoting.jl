# =============================================================================
# SQLite introspection binds table and index names into the pragmas (#832)
#
# `db_table` accepts any spelling (#59, #394), and every DDL site escapes it. The SQLite reader, its
# `_sqlite_column_is_unique` probe and `check()`'s mirror of the reader did not: they interpolated a
# catalog name between double quotes, `PRAGMA table_info("$table_name")`, so a table or index whose
# name holds a `"` made the statement a syntax error. `makemigrations`, `check()` and `inspectdb`
# then failed on a schema PormG itself had created. They now call the table-valued pragma functions
# with the name as a bound parameter, `pragma_table_info(?)`, which no name can reshape.
#
# Hermetic: temporary SQLite files and folders, no live database.
# =============================================================================
# julia --project=test/integration test/unit/test_sqlite_pragma_quoting.jl

using Test
using Logging
using PormG
# The testsets open real (temporary) SQLite files, so they need the weakdep extension. `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations
import PormG.ConnectionPool: close_pool!, SQLiteConnectionPool
import PormG.ConnectionPool

_pq832_quiet(f) = with_logger(f, NullLogger())

# The parent table, its composite UNIQUE and its composite index all carry a `"` in their names; the
# child's foreign key is what makes the reader call `pragma_foreign_key_list` on the quoted parent.
# `with_code = false` drops `code` from the parent and from its unique constraint — the drop-column
# path, which is where the planner asks `_sqlite_column_is_unique`.
function _pq832_write_models(path::AbstractString; with_code::Bool = true)
  code_field = with_code ? "    code = Models.CharField(max_length = 8, null = true),\n" : ""
  uniq_fields = with_code ? "(\"name\", \"code\")" : "(\"name\", \"season\")"
  write(path, """
  module models
  import PormG.Models
  Team832 = Models.Model(
      db_table = "Te\\"am832",
      id = Models.IDField(),
      name = Models.CharField(max_length = 40, null = true),
  $(code_field)    season = Models.IntegerField(null = true),
      constraints = [Models.UniqueConstraint(fields = $(uniq_fields), name = "uq\\"832")],
      indexes = [Models.Index(fields = ("name", "season"), name = "ix\\"832")],
  )
  Driver832 = Models.Model(
      id = Models.IDField(),
      surname = Models.CharField(max_length = 40, null = true),
      team = Models.ForeignKey(Team832, on_delete = "CASCADE", null = true),
  )
  end
  """)
end

function _pq832_migrate!(pool, settings, models_path; destructive::Bool = false)
  _pq832_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
  _pq832_quiet(() -> Migrations.migrate(pool, settings; interactive = false, destructive = destructive))
end

# A temporary SQLite project with the models above planned and applied once.
function _pq832_applied_project(f, tag::String)
  dir = mktempdir()
  pool = nothing
  try
    cd(dir) do
      mkpath(tag)
      pool = SQLiteConnectionPool(joinpath(dir, "$(tag).sqlite"); pool_size = 1)
      settings = Configuration.Settings(connections = pool, db_def_folder = tag)
      settings.change_db = true
      models_path = joinpath(dir, tag, settings.model_file)
      _pq832_write_models(models_path)
      _pq832_migrate!(pool, settings, models_path)
      f(pool, settings, models_path)
    end
  finally
    pool === nothing || close_pool!(pool)
    rm(dir; recursive = true, force = true)
  end
end

_pq832_check(pool, settings) =
  _pq832_quiet(() -> Migrations.check(pool, settings; kinds = [:expression_default, :schema_drift]))

_pq832_live(pool, name) = only(filter(t -> t.name == name, Migrations.read_live_schema(pool)))

# ─────────────────────────────────────────────────────────────────────────────
# SQLite introspection: a table, unique constraint and index named with a `"`
# The reader, the FK resolution and `check()` read the schema back whole and plan nothing. Before
# #832 each read raised `near "am832": syntax error`: the name closed the quoted PRAGMA argument.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a quoted table, unique constraint and index round-trip (#832)" begin
  _pq832_applied_project("db832a") do pool, settings, _
    team = _pq832_live(pool, "Te\"am832")
    @test collect(keys(team.columns)) == ["id", "name", "code", "season"]

    uniq = only(filter(c -> c.unique, team.composites))
    @test uniq.name == "uq\"832" && uniq.columns == ["name", "code"]
    idx = only(filter(c -> !c.unique, team.composites))
    @test idx.name == "ix\"832" && idx.columns == ["name", "season"]

    # The child's key resolves to the quoted parent through `pragma_foreign_key_list`.
    driver = _pq832_live(pool, "driver832")
    ref = only(c.reference for c in values(driver.columns) if c.reference !== nothing)
    @test ref.table == "Te\"am832" && ref.column == "id"

    # The next `makemigrations` would plan nothing, and `check()` — whose `:expression_default` arm
    # reads the pragmas itself rather than through the reader — agrees.
    @test isempty(_pq832_check(pool, settings))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite drop column: a member of a quoted unique constraint
# SQLite refuses `ALTER TABLE DROP COLUMN` on a column a UNIQUE index covers, so the planner asks
# `_sqlite_column_is_unique` and routes the drop through a rebuild. That probe interpolated both
# the table's name and each index's.
# ─────────────────────────────────────────────────────────────────────────────
@testset "dropping a member of a quoted unique constraint (#832)" begin
  _pq832_applied_project("db832b") do pool, settings, models_path
    @test Migrations._sqlite_column_is_unique(pool, "Te\"am832", "code")
    @test Migrations._sqlite_column_is_unique(pool, "Te\"am832", "name")
    @test !Migrations._sqlite_column_is_unique(pool, "Te\"am832", "season")
    @test !Migrations._sqlite_column_is_unique(pool, "Te\"am832", "no_such_column")

    # The drop rebuilds the table (its DROP of the old copy is what needs `destructive`).
    _pq832_write_models(models_path; with_code = false)
    _pq832_migrate!(pool, settings, models_path; destructive = true)

    team = _pq832_live(pool, "Te\"am832")
    @test collect(keys(team.columns)) == ["id", "name", "season"]
    @test only(filter(c -> c.unique, team.composites)).columns == ["name", "season"]
    @test isempty(_pq832_check(pool, settings))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite drop column: a table carrying a UNIQUE expression index
# `pragma_index_info` reports an expression member as `name = NULL`. The old loop tested
# `field_name in names` against that, got `missing` for any column not otherwise found, and threw a
# `TypeError` — so dropping any column from such a table crashed `makemigrations`. The bound join
# compares in SQL, where NULL simply never equals the column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the unique probe on a table with a unique expression index (#832)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "expr832.sqlite"); pool_size = 1)
    try
      # PormG cannot declare an expression index, so the hand-made one a DBA would add is raw DDL.
      ConnectionPool.fetch(pool, "CREATE TABLE circuit832 (id INTEGER PRIMARY KEY, name TEXT, ref TEXT UNIQUE)")
      ConnectionPool.fetch(pool, "CREATE UNIQUE INDEX circuit832_lower_name ON circuit832 (lower(name), id)")
      @test Migrations._sqlite_column_is_unique(pool, "circuit832", "ref")
      @test Migrations._sqlite_column_is_unique(pool, "circuit832", "id")
      # `name` is only inside the expression, which the pragma cannot attribute to it; the drop still
      # rebuilds, through `_sqlite_indexes_referencing_column`, which reads the index DDL.
      @test !Migrations._sqlite_column_is_unique(pool, "circuit832", "name")
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite introspection: no pragma argument is interpolated in src/ or ext/
# The bound form is `fetch(conn, "SELECT … FROM pragma_table_info(?)", [name])`. One interpolation
# is legitimate — the rebuild's `PRAGMA foreign_key_check("…")` is migration TEXT, with no parameter
# to bind, so it escapes the name itself (`safe_tbl`) — and it is pinned as the only match, so the
# allowance neither outlives that line nor covers a second one beside it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no pragma argument is interpolated in src/ or ext/ (#832)" begin
  root = pkgdir(PormG)
  # Either spelling — `PRAGMA [schema.]name` or the table-valued `pragma_name` — in any case, then
  # `(` or `=`, then a `$x` / `$(x)` anywhere before the closing paren on that line: quoted with
  # `\"` or `'`, bare inside a `"""` string, or behind a literal prefix.
  pattern = r"(?i)\bpragma(?:_|\s+(?:\w+\.)?)(\w+)\s*(?:\(|=)[^)\n]*?\$\(?(\w+)"
  found = Tuple{String, String}[]
  for dir in ("src", "ext"), (base, _, files) in walkdir(joinpath(root, dir)), file in files
    endswith(file, ".jl") || continue
    path = joinpath(base, file)
    rel = replace(relpath(path, root), '\\' => '/')
    text = open(read, path) |> String
    for m in eachmatch(pattern, text)
      push!(found, (rel, String(m.captures[2])))
    end
  end
  @test found == [("src/migrations/planner.jl", "safe_tbl")]

  # The pattern itself, against the spellings it exists to catch and one it must not.
  for bad in ("PRAGMA table_info(\\\"\$t\\\")", "PRAGMA index_info(\\\"\$(row.name)\\\")",
              "\"\"\"PRAGMA table_info(\"\$t\")\"\"\"", "pragma_table_info('\$t')",
              "PRAGMA main.table_info(\"x_\$t\")", "PRAGMA table_info = '\$t'")
    @test occursin(pattern, bad)
  end
  @test !occursin(pattern, "fetch(db, \"SELECT * FROM pragma_table_info(?)\", [table_name])")
end
