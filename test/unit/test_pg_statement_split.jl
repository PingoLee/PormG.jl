# ============================================================
# test/unit/test_pg_statement_split.jl
#
# PostgreSQL plan entries run one statement per driver call (#841).
#
# CONTRACT being tested:
#   A PostgreSQL plan entry can hold several statements: `alter_field` joins every change to one
#   column, and `add_check_constraint` adds the constraint and then its ownership comment. LibPQ
#   accepts that in one call (a parameterless string goes over the simple query protocol), but
#   Postgres.jl prepares every statement, and PostgreSQL refuses a prepared statement holding more
#   than one command (`42601`). So `_execute_statements_pg` cuts each entry with
#   `_split_pg_statements` and sends the pieces one by one on the migration's connection.
#
#   The splitter reads PostgreSQL's lexical rules: a `;` inside a string literal (`'…'`, `E'…'`),
#   a quoted identifier, a dollar quote, a comment (block comments nest) or parentheses does not end a
#   statement. It fails closed — any of those left open raises `InvalidMigrationError` rather than
#   letting a fragment run.
#
# Deterministic and DB-free: the executor test records what a mock PostgreSQL pool is handed. The
# live half — the same plans applied under `PORMG_POSTGRES_DRIVER=Postgres` — is
# `test/integration/test_lossy_alter.jl`, cases (m) and (o).
# ============================================================

using Test
using PormG
using PormG.Models
import PormG: PormGPostgres, InvalidMigrationError, check_marker
import PormG.Migrations: _split_pg_statements, _execute_statements_pg

# PostgreSQL stand-in for the Dialect renderers: they dispatch on the marker type only.
struct SplitMockPg841 <: PormGPostgres end
const SPLIT_PG = SplitMockPg841()

# PostgreSQL stand-in for the executor: records every statement and the connection it ran on, and
# refuses — as Postgres.jl does — a call holding more than one command. (Structs live at file top
# level; Julia forbids type definitions inside `@testset`.)
mutable struct RecordingPg841 <: PormGPostgres
  executed::Vector{Tuple{Any, String}}
end
function PormG.backend_execute_async(pool::RecordingPg841, conn, sql::String, params)
  push!(pool.executed, (conn, sql))
  multi = occursin(r";\s*\S", sql)
  return @async begin
    multi && error("mock 42601: cannot insert multiple commands into a prepared statement")
    NamedTuple[]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: a top-level `;` ends a statement, and only that
# Plain DDL cuts at each `;`, the terminating `;` is not kept, and pieces holding nothing but
# whitespace or comments are dropped — a trailing `;` or a comment-only line sends nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG split: top-level semicolons end statements (#841)" begin
  @test _split_pg_statements("ALTER TABLE \"t\" DROP COLUMN \"a\";\nALTER TABLE \"t\" DROP COLUMN \"b\";") ==
        ["ALTER TABLE \"t\" DROP COLUMN \"a\"", "ALTER TABLE \"t\" DROP COLUMN \"b\""]
  # One statement, with or without its `;`, is passed through whole.
  @test _split_pg_statements("SELECT 1;") == ["SELECT 1"]
  @test _split_pg_statements("SELECT 1") == ["SELECT 1"]
  # Empty, whitespace-only and comment-only text sends nothing at all.
  @test isempty(_split_pg_statements(""))
  @test isempty(_split_pg_statements(" ;\n ; "))
  @test _split_pg_statements("-- note; still a note\nSELECT 1;\n/* trailing; */") == ["-- note; still a note\nSELECT 1"]
  @test isempty(_split_pg_statements("/* only; a comment */;"))
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: a `;` inside a quoted construct or parentheses is text, not a terminator
# One case per construct PostgreSQL quotes with. Every one carries a `;` the old one-call path sent
# as-is; a naive split on `;` would run each as two broken fragments.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG split: semicolons inside literals, identifiers, dollar quotes, comments and parentheses (#841)" begin
  # Standard string literal, with a doubled quote right before the `;`.
  @test _split_pg_statements("ALTER TABLE \"t\" ALTER COLUMN \"c\" SET DEFAULT 'it''s; fine'; SELECT 2") ==
        ["ALTER TABLE \"t\" ALTER COLUMN \"c\" SET DEFAULT 'it''s; fine'", "SELECT 2"]
  # Standard-conforming strings: a backslash is an ordinary character, so `'C:\'` is complete.
  @test _split_pg_statements("SELECT 'C:\\'; SELECT 2") == ["SELECT 'C:\\'", "SELECT 2"]
  # `E'…'` takes backslash escapes: `\'` does not close it, so the `;` after it stays inside.
  @test _split_pg_statements("SELECT E'a\\'; b'; SELECT 2") == ["SELECT E'a\\'; b'", "SELECT 2"]
  @test _split_pg_statements("SELECT e'x\\\\'; SELECT 2") == ["SELECT e'x\\\\'", "SELECT 2"]
  # A trailing `e` of an identifier is not the `E` prefix: `name'…'` stays a standard literal.
  @test _split_pg_statements("SELECT note'a\\'; SELECT 2") == ["SELECT note'a\\'", "SELECT 2"]
  # Quoted identifier, with a doubled `"`.
  @test _split_pg_statements("ALTER TABLE \"odd;\"\"name\" DROP COLUMN \"a\"; SELECT 2") ==
        ["ALTER TABLE \"odd;\"\"name\" DROP COLUMN \"a\"", "SELECT 2"]
  # Dollar quotes, anonymous and tagged; a different tag inside does not close it.
  @test _split_pg_statements("DO \$\$ BEGIN PERFORM 1; END \$\$; SELECT 2") ==
        ["DO \$\$ BEGIN PERFORM 1; END \$\$", "SELECT 2"]
  @test _split_pg_statements("SELECT \$fn\$ a; \$x\$ b; \$fn\$; SELECT 2") ==
        ["SELECT \$fn\$ a; \$x\$ b; \$fn\$", "SELECT 2"]
  # `$1` is a parameter and `a$b` an identifier: neither opens a dollar quote. An identifier may
  # hold `$`s back to back (`a$$$`), and none of them opens one either.
  @test _split_pg_statements("SELECT \$1; SELECT a\$b\$; SELECT 3") == ["SELECT \$1", "SELECT a\$b\$", "SELECT 3"]
  @test _split_pg_statements("SELECT a\$\$\$; SELECT 2") == ["SELECT a\$\$\$", "SELECT 2"]
  # A literal opening the text: the `E` prefix at the first character still takes escapes.
  @test _split_pg_statements("E'a\\'; b'; SELECT 2") == ["E'a\\'; b'", "SELECT 2"]
  # A dollar-quote tag may be any identifier, and PostgreSQL counts every non-ASCII character as an
  # identifier character, letter or not (`€` is not a letter to Julia).
  @test _split_pg_statements("SELECT \$€\$ a; b \$€\$; SELECT 2") == ["SELECT \$€\$ a; b \$€\$", "SELECT 2"]
  # Line comment; block comments, which nest on PostgreSQL (SQLite's would end at the first `*/`).
  @test _split_pg_statements("SELECT 1 -- a; b\n; SELECT 2") == ["SELECT 1 -- a; b", "SELECT 2"]
  @test _split_pg_statements("SELECT 1 /* a /* b; */ c; */; SELECT 2") == ["SELECT 1 /* a /* b; */ c; */", "SELECT 2"]
  # A bare `\r` ends a line comment too, as PostgreSQL's lexer has it — reading on to the next `\n`
  # would swallow the statements after it.
  @test _split_pg_statements("SELECT 1; -- note\rSELECT 2; SELECT 3") == ["SELECT 1", "-- note\rSELECT 2", "SELECT 3"]
  # Inside parentheses a `;` is not a terminator either (psql's rule): a rule's action list stays whole.
  @test _split_pg_statements("CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2)); SELECT 3") ==
        ["CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2))", "SELECT 3"]
  # A stray `)` does not push the depth below zero, so the statements after it still cut.
  @test _split_pg_statements("SELECT 1); SELECT 2") == ["SELECT 1)", "SELECT 2"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: fails closed on an unterminated quote or comment
# Everything after an opener that never closes would be read as quoted, so the split could run a
# fragment and silently skip the rest. Each form raises InvalidMigrationError before anything runs —
# an unclosed parenthesis too, which would otherwise merge the rest of the entry into one call.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG split: an unterminated literal, identifier, dollar quote, comment or parenthesis raises (#841)" begin
  for sql in ("SELECT 'open; SELECT 2", "SELECT E'open\\'; SELECT 2", "SELECT \"open; SELECT 2",
              "DO \$\$ BEGIN; SELECT 2", "SELECT \$t\$ a \$x\$; SELECT 2",
              "SELECT 1 /* open; SELECT 2", "SELECT 1 /* a /* b */ still open; SELECT 2",
              "ALTER TABLE t ADD CHECK (a > (0);\nCOMMENT ON TABLE t IS 'x';")
    @test_throws InvalidMigrationError _split_pg_statements(sql)
  end
  # The message names the problem and quotes where it starts.
  err = try _split_pg_statements("SELECT 'open; SELECT 2") catch e; e end
  @test err isa InvalidMigrationError
  @test occursin("unterminated string literal", sprint(showerror, err))
  @test occursin("'open; SELECT 2", sprint(showerror, err))
  err = try _split_pg_statements("SELECT \$t\$ a \$x\$; SELECT 2") catch e; e end
  @test occursin("unterminated dollar quote (\$t\$)", sprint(showerror, err))
  err = try _split_pg_statements("SELECT 1; SELECT (1; SELECT 2") catch e; e end
  @test occursin("unterminated parenthesis", sprint(showerror, err))
  # It quotes the statement the parenthesis is in, not the ones before it.
  @test occursin("SELECT (1; SELECT 2", sprint(showerror, err))
  # A `--` comment running to the end of the text is complete, not unterminated.
  @test _split_pg_statements("SELECT 1; -- trailing; note") == ["SELECT 1"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter over PormG's own PostgreSQL plan entries
# The two multi-statement producers: `add_check_constraint` (ADD CONSTRAINT + marker COMMENT, the
# issue's case) and `alter_field` (one entry per column — the golden `identity_cross/PG` shape from
# test_plan_actions_golden.jl). Each splits into exactly its statements, and a `;` inside a CHECK
# condition, a kept DBA comment or a SET DEFAULT literal stays in its statement.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG split: PormG's own multi-statement plan entries (#841)" begin
  ck = Models.CheckConstraint(condition = "grid >= 0 AND grid <= 40", name = "result_grid_range")
  entry = PormG.Dialect.add_check_constraint(SPLIT_PG, "result", ck)
  @test _split_pg_statements(entry) == [
    "ALTER TABLE \"result\" ADD CONSTRAINT \"result_grid_range\" CHECK (grid >= 0 AND grid <= 40)",
    "COMMENT ON CONSTRAINT \"result_grid_range\" ON \"result\" IS '$(check_marker(ck.condition))'",
  ]

  # A `;` in the condition and in the kept comment (with a doubled quote) cuts nothing.
  semi = Models.CheckConstraint(condition = "status <> ';'", name = "result_status_ok")
  parts = _split_pg_statements(PormG.Dialect.add_check_constraint(SPLIT_PG, "result", semi))
  @test length(parts) == 2
  @test parts[1] == "ALTER TABLE \"result\" ADD CONSTRAINT \"result_status_ok\" CHECK (status <> ';')"
  adopt = PormG.Dialect.comment_check_constraint(SPLIT_PG, "result", semi; keep = "FIA's rule; see the doc")
  @test _split_pg_statements(adopt) == [chop(adopt)]

  # alter_field's joined statements, as the golden plan pins them for a cross to identity.
  joined = "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE bigint;\nALTER TABLE \"child_t\" ADD UNIQUE (\"col\");\n" *
           "ALTER TABLE \"child_t\" ADD PRIMARY KEY (\"col\");\nALTER TABLE \"child_t\" ALTER COLUMN \"col\" ADD GENERATED BY DEFAULT AS IDENTITY;"
  pieces = _split_pg_statements(joined)
  @test length(pieces) == 4
  # Nothing is lost or reordered: the pieces rejoin to the entry byte for byte.
  @test join(pieces .* ";", "\n") == joined

  # The #828 retype shape: drop the default, retype, restore a default whose literal holds a `;`.
  retype = "ALTER TABLE \"t\" ALTER COLUMN \"c\" DROP DEFAULT;\n" *
           "ALTER TABLE \"t\" ALTER COLUMN \"c\" TYPE integer USING \"c\"::integer;\n" *
           "ALTER TABLE \"t\" ALTER COLUMN \"c\" SET DEFAULT 'a;b';"
  @test _split_pg_statements(retype)[3] == "ALTER TABLE \"t\" ALTER COLUMN \"c\" SET DEFAULT 'a;b'"
  @test length(_split_pg_statements(retype)) == 3
end

# ─────────────────────────────────────────────────────────────────────────────
# Executor: one driver call per statement, all on the migration's connection
# `_execute_statements_pg` is what `migrate` runs inside its BEGIN … COMMIT. The mock refuses a
# multi-command call the way Postgres.jl does, so sending a whole entry (the pre-#841 behavior)
# fails here; the fixed executor sends each statement alone, in order, on the one connection —
# which is what keeps the CHECK and its marker in the same transaction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PG executor: each statement of an entry is its own call on the same connection (#841)" begin
  ck = Models.CheckConstraint(condition = "laps >= 0", name = "result_laps_non_negative")
  entries = [PormG.Dialect.add_check_constraint(SPLIT_PG, "result", ck),
             "ALTER TABLE \"result\" ALTER COLUMN \"laps\" DROP DEFAULT;\nALTER TABLE \"result\" ALTER COLUMN \"laps\" SET NOT NULL;",
             "DROP INDEX IF EXISTS \"result_laps_idx\";"]
  pool = RecordingPg841(Tuple{Any, String}[])
  conn = :migration_conn
  _execute_statements_pg(pool, entries; conn = conn)
  # Five statements from three entries, in plan order.
  @test last.(pool.executed) == [
    "ALTER TABLE \"result\" ADD CONSTRAINT \"result_laps_non_negative\" CHECK (laps >= 0)",
    "COMMENT ON CONSTRAINT \"result_laps_non_negative\" ON \"result\" IS '$(check_marker("laps >= 0"))'",
    "ALTER TABLE \"result\" ALTER COLUMN \"laps\" DROP DEFAULT",
    "ALTER TABLE \"result\" ALTER COLUMN \"laps\" SET NOT NULL",
    "DROP INDEX IF EXISTS \"result_laps_idx\"",
  ]
  # Every call ran on the connection the migration's transaction holds.
  @test all(==(conn), first.(pool.executed))

  # A plan entry with an unterminated quote runs nothing at all — not even the statements before it.
  empty!(pool.executed)
  @test_throws InvalidMigrationError _execute_statements_pg(pool, ["SELECT 1; SELECT 'open"]; conn = conn)
  @test isempty(pool.executed)
end
