"""
Unit coverage for the SQL identifier contract (#394).

PormG had two rules for one job. `Dialect._quote_table_ddl` **escaped** `"` and never validated, so
the DDL renderer accepted any spelling; `quote_identifier` **validated** against
`SAFE_IDENTIFIER_PATTERN` and never escaped, so the query builder refused most of them. The result
was a schema PormG would migrate and then could not query — reachable without anyone hand-writing a
hostile string, because `db_table`/`db_column` are deliberately unvalidated (#59/#50) and the
importers pin arbitrary catalog names into them.

#394 replaces it with one rule per axis:

  * a PHYSICAL name (table, column) is **escape-only** — `safe_table_identifier` /
    `safe_column_identifier`, mirroring `Dialect._quote_table_ddl`;
  * an ALIAS or other query-time name stays **fail-closed** — `quote_identifier`, because a join
    alias, a `.with(...)` CTE name and a `values("label" => ...)` label are chosen at build time,
    are often literals the caller typed, and name nothing that already exists;
  * a JSON path segment keeps its own pattern, because it is interpolated **unquoted** into a path
    literal and has no quoting to fall back on.

All assertions render via mock connections; no live database is required.
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, model_table_name
import OrderedCollections
using PormG.QueryBuilder: inspect_query, quote_identifier, safe_table_identifier,
                          safe_column_identifier, _escape_identifier, _validate_identifier,
                          _sql_literal

struct MockPostgresIdent <: PormG.PormGPostgres end
struct MockSQLiteIdent <: PormG.PormGSQLite end
PormG.config["ident_mock"] = PormG.Configuration.Settings(
  connections = MockPostgresIdent(),
  change_data = true,
)

# ─────────────────────────────────────────────────────────────────────────────
# 1. The partition, over the exact set of hostile names the importer already round-trips.
#
# This list is copied from `test/unit/test_model_to_str_identifiers.jl`, which asserts that a
# physical table carrying any of these spellings is preserved verbatim and pinned as `db_table` in
# the generated model file. That equivalence IS #394: a name `Model_to_str` will write into a
# `db_table` has to be a name the query builder can address, or `inspectdb` emits a model that
# cannot be used.
# ─────────────────────────────────────────────────────────────────────────────
const HOSTILE_NAMES = ["we\"ird", "2fast", "driver profile", "cost\$usd", "_", "___", "end",
                       "db_table", "admin--", "user name", "localização"]

@testset "physical identifiers are escaped, never validated (#394)" begin
  for name in HOSTILE_NAMES
    # Neither raises, on either axis.
    t = safe_table_identifier(name, nothing)
    c = safe_column_identifier(name, nothing)
    @test t == c                                  # one rule, two entry points
    @test startswith(t, "\"") && endswith(t, "\"")
    # The only transformation is quote doubling.
    @test t == "\"" * replace(name, "\"" => "\"\"") * "\""
  end

  # Spelled out for the case that matters, so a reader does not have to evaluate the loop.
  @test safe_table_identifier("driver profile", nothing) == "\"driver profile\""
  @test safe_table_identifier("we\"ird", nothing) == "\"we\"\"ird\""
  @test safe_column_identifier("Say\"Hi", nothing) == "\"Say\"\"Hi\""
  @test safe_table_identifier("2fast", nothing) == "\"2fast\""

  # An ordinary name is untouched — escaping is a no-op for everything without a quote.
  @test safe_table_identifier("drivers", nothing) == "\"drivers\""
  @test safe_column_identifier("driverid", nothing) == "\"driverid\""
end

@testset "aliases stay fail-closed (#394)" begin
  # Every name the escape-only path now accepts is still refused as an ALIAS, except the ones that
  # were always legal identifiers.
  for name in ["we\"ird", "2fast", "driver profile", "cost\$usd", "admin--", "user name", ""]
    @test_throws PormG.InvalidValueError quote_identifier(name, nothing)
  end
  for name in ["_", "___", "end", "db_table", "localização", "driverid"]
    @test quote_identifier(name, nothing) == "\"$(name)\""
  end

  # The message points at the option that carries an arbitrary spelling, rather than leaving the
  # caller to guess that aliases and physical names have different rules.
  err = @test_throws PormG.InvalidValueError quote_identifier("driver profile", nothing)
  @test occursin("ALIAS", err.value.msg)
  @test occursin("db_table", err.value.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. The defect itself: DDL and query must render the SAME spelling.
#
# Asserting each side in isolation is what let the split survive — both halves were individually
# "correct". This compares them.
# ─────────────────────────────────────────────────────────────────────────────
const OddIdent = Model("odd_ident_scratch",
  db_table  = "Odd Identifier",
  id        = IDField(),
  driverref = CharField(max_length = 30, db_column = "driver ref"),
  points    = IntegerField(null = true),
)
OddIdent.connect_key = "ident_mock"

@testset "a name the DDL renders is a name the query builder addresses (#394)" begin
  for conn in (MockPostgresIdent(), MockSQLiteIdent())
    ddl = PormG.Dialect.create_table(conn, OddIdent)
    @test occursin("\"Odd Identifier\"", ddl)
    @test occursin("\"driver ref\"", ddl)
  end

  q = OddIdent.objects
  q.filter("driverref" => "senna")
  q.values("driverref", "points")
  sql = inspect_query(q)[:sql_text]

  # The same two spellings, from the other layer. Before #394 this call raised
  # `InvalidValueError: Invalid SQL identifier: Odd Identifier`.
  @test occursin("FROM \"Odd Identifier\"", sql)
  @test occursin("\"driver ref\"", sql)

  # The value is still parameterized — loosening the identifier rule did not loosen anything about
  # values, which is where user input actually flows.
  @test !occursin("senna", sql)
end

@testset "an embedded quote is escaped identically on both layers (#394)" begin
  evil = Model("evil_ident_scratch",
    db_table = "Ev\"il",
    id       = IDField(),
    label    = CharField(max_length = 10, db_column = "Say\"Hi"),
  )
  evil.connect_key = "ident_mock"

  for conn in (MockPostgresIdent(), MockSQLiteIdent())
    ddl = PormG.Dialect.create_table(conn, evil)
    @test occursin("\"Ev\"\"il\"", ddl)
    # The column half is what #394 added to the DDL side — without it the query builder would start
    # accepting a column the renderer still emits unescaped, moving the split instead of closing it.
    @test occursin("\"Say\"\"Hi\"", ddl)
  end

  q = evil.objects
  q.values("label")
  sql = inspect_query(q)[:sql_text]
  @test occursin("\"Ev\"\"il\"", sql)
  @test occursin("\"Say\"\"Hi\"", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. The query-time surfaces that must NOT have been loosened along with the rest.
# ─────────────────────────────────────────────────────────────────────────────
const IdentDriver = Model("ident_driver_scratch",
  id       = IDField(),
  surname  = CharField(max_length = 30),
  points   = IntegerField(null = true),
)
IdentDriver.connect_key = "ident_mock"

@testset "a CTE name is refused at the .with() call, not at render (#394)" begin
  sub = IdentDriver.objects
  sub.values("surname")

  # #394 moved this check to declaration. `row_join["b"]` carries a physical table on every branch
  # but the CTE ones, and that slot quotes escape-only now — so validating the CTE name only at
  # render time would leave the guard depending on which renderer ran first.
  q = IdentDriver.objects
  @test_throws PormG.InvalidValueError q.with("bad name" => sub)
  @test_throws PormG.InvalidValueError q.with("2fast" => sub)

  # A legal name still works, and still renders.
  ok = IdentDriver.objects
  ok.with("recent" => sub)
  ok.values("surname")
  @test occursin("WITH \"recent\" AS", inspect_query(ok)[:sql_text])
end

@testset "a SELECT label is refused (#394)" begin
  q = IdentDriver.objects
  q.values("bad name" => "points")
  @test_throws PormG.InvalidValueError inspect_query(q)
end

@testset "JSON path segments keep their own guard (#394)" begin
  # `SAFE_JSON_KEY_PATTERN` is a separate constant from `SAFE_IDENTIFIER_PATTERN` precisely so a
  # future relaxation of the identifier rules cannot widen this one. A segment is interpolated
  # UNQUOTED into a path literal, so the charset check is the whole guard.
  @test PormG.QueryBuilder.SAFE_JSON_KEY_PATTERN !== PormG.QueryBuilder.SAFE_IDENTIFIER_PATTERN

  segs = PormG.QueryBuilder._validate_json_key_segments(["driver", "0", "team_name"])
  @test segs == ["driver", "0", "team_name"]

  for bad in ["a b", "a'b", "a}b", "a,b", "a.b", ""]
    @test_throws PormG.InvalidValueError PormG.QueryBuilder._validate_json_key_segments([bad])
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. The two swallowing catches (#394).
#
# `_build_from_tables` used to drop a table from a correlated FROM list and `_get_join_condition_list`
# used to drop an ON condition from a correlated UPDATE ... FROM / DELETE ... USING — both on any
# exception, both reported only as an `@error`. A mutation missing its ON condition matches every row
# of the joined table, so this is the one place a swallowed error corrupts data.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a malformed row_join raises instead of emitting wrong SQL (#394)" begin
  RowJoin = Dict{String, Union{String, Vector{PormG.QueryBuilder.FilterType}}}

  @test_throws KeyError PormG.QueryBuilder._build_from_tables(
    [RowJoin("alias_b" => "Tb_1")], MockPostgresIdent())          # no "b"

  @test_throws KeyError PormG.QueryBuilder._get_join_condition_list(
    [RowJoin("alias_a" => "Tb", "alias_b" => "Tb_1", "key_b" => "id")], MockPostgresIdent())  # no "key_a"

  # The other half of what the comment on those loops claims: an INTERNALLY generated alias that is
  # not an identifier must surface too. A wrong fix that re-wrapped only the `quote_identifier`
  # calls in a try/catch passes the `KeyError` cases above and fails this one.
  @test_throws PormG.InvalidValueError PormG.QueryBuilder._get_join_condition_list(
    [RowJoin("alias_a" => "bad alias", "alias_b" => "Tb_1", "key_a" => "id", "key_b" => "x")],
    MockPostgresIdent())
  @test_throws PormG.InvalidValueError PormG.QueryBuilder._build_from_tables(
    [RowJoin("b" => "drivers", "alias_b" => "bad alias")], MockPostgresIdent())

  # A CTE cannot be joined here at all: a correlated UPDATE ... FROM emits no WITH clause, so the
  # relation the FROM list names is never declared. Both CTE shapes are refused before any SQL is
  # built — the cross-joined one (which also carries sentinel empty key columns) and the keyed one.
  @test_throws PormG.QueryBuildError PormG.QueryBuilder._get_join_condition_list(
    [RowJoin("b" => "fast_laps", "cte" => "1", "cross" => "1", "alias_a" => "Tb",
             "alias_b" => "Tb_1", "key_a" => "", "key_b" => "")], MockPostgresIdent())
  @test_throws PormG.QueryBuildError PormG.QueryBuilder._get_join_condition_list(
    [RowJoin("b" => "fast_laps", "cte" => "1", "alias_a" => "Tb", "alias_b" => "Tb_1",
             "key_a" => "raceid", "key_b" => "raceid")], MockPostgresIdent())

  # The well-formed case still builds, so the assertions above are about the failure path only.
  good = RowJoin("b" => "drivers", "alias_a" => "Tb", "alias_b" => "Tb_1",
                 "key_a" => "id", "key_b" => "driverid")
  @test PormG.QueryBuilder._build_from_tables([good], MockPostgresIdent()) == "\"drivers\" AS \"Tb_1\""
  @test PormG.QueryBuilder._get_join_condition_list([good], MockPostgresIdent()) ==
        ["\"Tb\".\"id\" = \"Tb_1\".\"driverid\""]
end

# ─────────────────────────────────────────────────────────────────────────────
# 5. The third layer: the migration PLAN FILE.
#
# `makemigrations` writes `pending_migrations.jl`, which is Julia source, and each table becomes a
# BINDING in it (`Generator.generate_migration_plan`). So a physical name that is not a legal Julia
# identifier produced a file that could not be parsed: `makemigrations` succeeded and `migrate` then
# died on its own output with a `ParseError`. Every spelling `db_table` exists to carry is such a
# name, which is why the DDL/query fix above is not the whole story.
#
# `var"..."` is Julia's raw-identifier syntax and accepts any string. The reader
# (`Migrations.get_all_dicts`) walks `names(mod)` and `getfield`, so it never sees the spelling.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a migration plan file parses for any physical table name (#394)" begin
  bind = PormG.Generator._plan_binding

  # An ordinary name is emitted unchanged, so existing plan files stay byte-identical.
  @test bind("db_table_scratch") == "db_table_scratch"
  @test bind(:db_table_scratch) == "db_table_scratch"

  # Anything else takes the raw-identifier form, with both string escapes applied.
  @test bind("Odd Identifier Scratch") == "var\"Odd Identifier Scratch\""
  @test bind("2fast") == "var\"2fast\""
  @test bind("Ev\"il") == "var\"Ev\\\"il\""

  # An all-underscore name is the one case `var"..."` cannot rescue: Julia discards it at any
  # spelling. It gets a prefix, which is harmless because the reader never looks at the name.
  @test bind("_") == "var\"pormg_plan__\""
  @test bind("___") == "var\"pormg_plan____\""
  # `Base.isidentifier` accepts reserved words, which are a ParseError in assignment position.
  @test bind("end") == "var\"end\""

  # What actually has to hold for every one of them: the entry PARSES and the dict is reachable the
  # way `_load_migration_plan` reaches it — by value, not by name.
  for name in HOSTILE_NAMES
    probe = Module(Symbol("PlanBindProbe"))
    Core.eval(probe, Meta.parse(string("import OrderedCollections")))
    Core.eval(probe, Meta.parse(string(
      bind(name), " = OrderedCollections.OrderedDict{String,String}(\"New model\" => \"CREATE TABLE\")")))
    found = Base.invokelatest(PormG.Migrations.get_all_dicts, probe)
    @test length(found) == 1
  end

  # End to end: write a plan naming a spaced table, include it back, and read the dict out the way
  # `_load_migration_plan` does. Before #394 the `include` raised a ParseError.
  mktempdir() do dir
    plan = OrderedCollections.OrderedDict{Symbol, OrderedCollections.OrderedDict{String, String}}(
      Symbol("Odd Identifier Scratch") => OrderedCollections.OrderedDict{String, String}(
        "New model" => "CREATE TABLE IF NOT EXISTS \"Odd Identifier Scratch\" (\"id\" bigint);"),
      :plain_table => OrderedCollections.OrderedDict{String, String}(
        "New model" => "CREATE TABLE IF NOT EXISTS \"plain_table\" (\"id\" bigint);"),
    )
    PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, dir)
    written = read(joinpath(dir, "pending_migrations.jl"), String)
    @test occursin("var\"Odd Identifier Scratch\" = ", written)
    @test occursin("\nplain_table = ", written)   # untouched, no var"..." wrapper

    mod = include(joinpath(dir, "pending_migrations.jl"))
    dicts = Base.invokelatest(PormG.Migrations.get_all_dicts, mod)
    @test length(dicts) == 2
    @test any(d -> occursin("Odd Identifier Scratch", d["New model"]), dicts)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 6. The two escapes are disjoint, so composing them cannot double-process.
#
# `_table_ident_literal` composes them to build `'"Db_Table"'` for `pg_get_serial_sequence` /
# `to_regclass`, which take TEXT they re-parse as an identifier.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the identifier escape and the literal escape do not overlap (#394)" begin
  @test _escape_identifier("a'b") == "a'b"        # identifier escape ignores single quotes
  @test _sql_literal("a\"b") == "a\"b"            # literal escape ignores double quotes
  @test _escape_identifier("a\"b") == "a\"\"b"
  @test _sql_literal("a'b") == "a''b"

  # Composed in either order, each escape sees only its own character.
  both = "he said \"it's fine\""
  @test _sql_literal(_escape_identifier(both)) ==
        replace(replace(both, "\"" => "\"\""), "'" => "''")
end
