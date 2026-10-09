using Test
using DataFrames
using PormG
import PormG.ConnectionPool: fetch
using PormG.QueryBuilder: explain_query, inspect_query
import PormG.QueryBuilder: _explain_facts_postgres, _explain_facts_sqlite

# ─────────────────────────────────────────────────────────────────────────────
# explain_query / .explain() (#48)
#
# DB-free: the mock connections answer `fetch` with a scripted plan and record the statement and
# parameters they were handed, so the EXPLAIN text, the binding and the fact extraction are all
# assertable without a database. The plans below are trimmed copies of real output — the PostgreSQL
# one from `EXPLAIN (FORMAT JSON, ANALYZE)` on db_2, the SQLite rows from `EXPLAIN QUERY PLAN` on
# f1.sqlite — and test/integration/test_explain.jl runs the same calls against both databases.
# ─────────────────────────────────────────────────────────────────────────────

struct MockPgExplain <: PormG.PormGPostgres end
struct MockSqliteExplain <: PormG.PormGSQLite end
# A second PostgreSQL pool — a replica, say — to pass as `connection =`.
struct MockPgExplainReplica <: PormG.PormGPostgres end

# A nested-loop plan: a Seq Scan of `race` driving an Index Scan of `result`, plus the timings
# ANALYZE adds. The index name appears twice to prove `:indexes_used` is de-duplicated.
const PG_PLAN_JSON = """
[{"Plan": {"Node Type": "Nested Loop", "Total Cost": 227.38, "Plan Rows": 381,
   "Plans": [
     {"Node Type": "Seq Scan", "Relation Name": "race", "Alias": "Tb_1", "Total Cost": 20.5, "Plan Rows": 16},
     {"Node Type": "Bitmap Heap Scan", "Relation Name": "result", "Alias": "Tb",
      "Plans": [{"Node Type": "Bitmap Index Scan", "Index Name": "result_raceid_idx"}]},
     {"Node Type": "Index Scan", "Relation Name": "result", "Index Name": "result_raceid_idx"}
   ]},
  "Planning Time": 0.343, "Execution Time": 0.231}]
"""

# SQLite names each table by the query's alias; a pk lookup reports INTEGER PRIMARY KEY.
const SQLITE_PLAN_ROWS = [
  (id = 4, parent = 0, notused = 0, detail = "SCAN Tb_1"),
  (id = 8, parent = 0, notused = 0, detail = "SEARCH Tb USING INDEX result_driverid_idx (driverid=?)"),
  (id = 9, parent = 0, notused = 0, detail = "SEARCH Tb_2 USING INTEGER PRIMARY KEY (rowid=?)"),
  (id = 11, parent = 0, notused = 0, detail = "SCAN Tb_3 USING COVERING INDEX race_year_idx"),
  (id = 12, parent = 0, notused = 0, detail = "SCAN CONSTANT ROW"),
  (id = 14, parent = 0, notused = 0, detail = "USE TEMP B-TREE FOR ORDER BY"),
  (id = 15, parent = 0, notused = 0, detail = "SEARCH Tb_4 USING AUTOMATIC COVERING INDEX (raceid=?)"),
  (id = 16, parent = 0, notused = 0, detail = "SCAN (subquery-1)"),
  (id = 17, parent = 0, notused = 0, detail = "SCAN TABLE Tb_5"),   # SQLite before 3.36
]

# Every statement and parameter object the mocks are handed, newest last.
const EXPLAIN_CALLS = Tuple{String, Any}[]

function fetch(connection::MockPgExplain, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false)
  push!(EXPLAIN_CALLS, (sql, params))
  # The driver hands a json column back as text, under PostgreSQL's own column name.
  return DataFrame("QUERY PLAN" => [PG_PLAN_JSON])
end
function fetch(connection::MockPgExplainReplica, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false)
  push!(EXPLAIN_CALLS, ("replica: " * sql, params))
  return DataFrame("QUERY PLAN" => [PG_PLAN_JSON])
end
function fetch(connection::MockSqliteExplain, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false)
  push!(EXPLAIN_CALLS, (sql, params))
  return DataFrame(SQLITE_PLAN_ROWS)
end

PormG.config["explain_pg"] = PormG.Configuration.Settings(
  connections = MockPgExplain(), change_data = true, db_def_folder = "explain_pg")
PormG.config["explain_sqlite"] = PormG.Configuration.Settings(
  connections = MockSqliteExplain(), change_data = true, db_def_folder = "explain_sqlite")

const EXPLAIN_MODELS = quote
  import PormG
  import PormG.Models
  Driver = Models.Model("driver",
    driverid = Models.IDField(),
    surname = Models.CharField(),
    nationality = Models.CharField(),
  )
end
module ExplainPG end
module ExplainSL end
Core.eval(ExplainPG, EXPLAIN_MODELS)
Core.eval(ExplainSL, EXPLAIN_MODELS)
PormG.Models.set_models(ExplainPG, "explain_pg")
PormG.Models.set_models(ExplainSL, "explain_sqlite")

# The inspection keys every explain result carries, and the plan facts it adds — the same set on both
# engines, so a caller never branches on which keys exist.
const INSPECTION_KEYS = Set([:sql_text, :parameters, :dialect, :model, :operation, :bucketing,
                             :parameter_count, :parameter_buckets])
const EXPLAIN_KEYS = union(INSPECTION_KEYS, Set([:explain_sql, :analyze, :plan, :indexes_used, :seq_scans,
                                                 :total_cost, :estimated_rows, :planning_time_ms, :execution_time_ms]))

# ─────────────────────────────────────────────────────────────────────────────
# explain: PostgreSQL plan facts
# Walks the whole JSON plan tree — children under "Plans", at any depth — collecting each
# "Index Name" once and each Seq Scan's relation, and reads the root estimates and ANALYZE timings.
# An already-decoded document (a driver that parses json itself) gives the same facts as the text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: PostgreSQL plan facts" begin
  facts = _explain_facts_postgres(PG_PLAN_JSON)
  @test facts[:indexes_used] == ["result_raceid_idx"]   # nested two levels down, de-duplicated
  @test facts[:seq_scans] == ["race"]                   # the relation name, not the alias
  @test facts[:total_cost] === 227.38
  @test facts[:estimated_rows] === 381
  @test facts[:planning_time_ms] === 0.343
  @test facts[:execution_time_ms] === 0.231
  @test facts[:plan]["Plan"]["Node Type"] == "Nested Loop"
  # Same facts from a pre-parsed document.
  parsed = _explain_facts_postgres(PormG.QueryBuilder.JSON.parse(PG_PLAN_JSON))
  @test parsed[:indexes_used] == facts[:indexes_used] && parsed[:seq_scans] == facts[:seq_scans]
  # Without ANALYZE there are no timings: the keys stay, the values are nothing.
  plain = _explain_facts_postgres("""[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "driver", "Total Cost": 3, "Plan Rows": 848}}]""")
  @test plain[:planning_time_ms] === nothing && plain[:execution_time_ms] === nothing
  @test plain[:total_cost] === 3.0 && plain[:seq_scans] == ["driver"] && isempty(plain[:indexes_used])
end

# ─────────────────────────────────────────────────────────────────────────────
# explain: SQLite plan facts
# SQLite states its access path in `detail`: a plain SCAN is a table scan; SEARCH/SCAN "USING
# [COVERING] INDEX x" names the index; a rowid lookup is "INTEGER PRIMARY KEY". Rows that are not an
# access path (a temp B-tree, a constant row) contribute nothing. SQLite has no cost or timing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: SQLite plan facts" begin
  facts = _explain_facts_sqlite(SQLITE_PLAN_ROWS)
  # A transient index is reported as one, never as a schema index; a subquery is not a table.
  @test facts[:indexes_used] == ["result_driverid_idx", "INTEGER PRIMARY KEY", "race_year_idx", "AUTOMATIC INDEX"]
  @test facts[:seq_scans] == ["Tb_1", "Tb_5"]           # a covering-index SCAN is not a table scan
  @test all(facts[k] === nothing for k in (:total_cost, :estimated_rows, :planning_time_ms, :execution_time_ms))
  @test facts[:plan][2] == Dict(:id => 8, :parent => 0, :detail => "SEARCH Tb USING INDEX result_driverid_idx (driverid=?)")
end

# ─────────────────────────────────────────────────────────────────────────────
# explain: the statement sent on PostgreSQL
# explain() runs EXPLAIN over exactly the SELECT show_query renders, binds that query's own
# parameters, and adds only fixed option keywords — FORMAT JSON always, ANALYZE / BUFFERS / VERBOSE
# when asked. The result is the inspection Dict plus the plan facts, under one fixed key set.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: PostgreSQL statement and result" begin
  q = ExplainPG.Driver.objects.filter("nationality" => "Brazilian").values("surname")
  sql = show_query(q, :sql)
  empty!(EXPLAIN_CALLS)
  res = q.explain()
  explain_sql, params = only(EXPLAIN_CALLS)
  @test explain_sql == "EXPLAIN (FORMAT JSON) " * sql
  # The query's own parameter object is bound, not a copy of its values spliced into the text.
  @test params isa PormG.PormGPostgresParam && params.parameters == ["Brazilian"]
  @test !occursin("Brazilian", explain_sql)
  @test Set(keys(res)) == EXPLAIN_KEYS
  @test res[:explain_sql] == explain_sql && res[:sql_text] == sql
  @test res[:operation] === :select && res[:dialect] === :postgresql && res[:analyze] === false
  @test res[:indexes_used] == ["result_raceid_idx"] && res[:seq_scans] == ["race"]
  # The options, in a fixed order, each a literal keyword.
  empty!(EXPLAIN_CALLS)
  @test q.explain(analyze = true, buffers = true, verbose = true)[:analyze] === true
  @test Base.first(only(EXPLAIN_CALLS)) == "EXPLAIN (FORMAT JSON, ANALYZE, BUFFERS, VERBOSE) " * sql
  # The free function, its curried form and the fluent method are one call.
  @test explain_query(q)[:explain_sql] == (q |> explain_query())[:explain_sql] == res[:explain_sql]
  # The handler is not mutated: the build writes its parameters and projection kinds back onto the
  # handler it is given, so those slots must still hold the very objects they held before.
  params_before, kinds_before = q.object.parameters, q.object.projection_kinds
  q.explain()
  @test q.object.parameters === params_before
  @test q.object.projection_kinds === kinds_before
  @test show_query(q, :sql) == sql
end

# ─────────────────────────────────────────────────────────────────────────────
# explain: a `connection =` override is explained on that pool
# The statement is built for the override and must be sent to it — a replica's plan, not the model's
# default pool's. The #48 review found it built for one pool and fetched on the other.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: connection override" begin
  q = ExplainPG.Driver.objects.filter("nationality" => "Brazilian").values("surname")
  empty!(EXPLAIN_CALLS)
  res = q.explain(connection = MockPgExplainReplica())
  @test startswith(Base.first(only(EXPLAIN_CALLS)), "replica: EXPLAIN (FORMAT JSON) ")
  @test res[:indexes_used] == ["result_raceid_idx"]
end

# ─────────────────────────────────────────────────────────────────────────────
# explain: SQLite runs EXPLAIN QUERY PLAN and refuses the PostgreSQL-only options
# SQLite has no EXPLAIN ANALYZE/BUFFERS/VERBOSE. Asking for one is a BackendCapabilityError raised
# before anything is fetched — not a silently ignored flag. Without them the result has the same key
# set as on PostgreSQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: SQLite statement and refusals" begin
  q = ExplainSL.Driver.objects.filter("nationality" => "Brazilian").values("surname")
  empty!(EXPLAIN_CALLS)
  res = q.explain()
  explain_sql, params = only(EXPLAIN_CALLS)
  @test explain_sql == "EXPLAIN QUERY PLAN " * show_query(q, :sql)
  @test params isa PormG.PormGSQLiteParam && params.parameters == ["Brazilian"]
  @test Set(keys(res)) == EXPLAIN_KEYS
  @test res[:dialect] === :sqlite && res[:analyze] === false
  for opt in (:analyze, :buffers, :verbose)
    empty!(EXPLAIN_CALLS)
    err = try q.explain(; opt => true); nothing catch e; e end
    @test err isa PormG.BackendCapabilityError
    @test occursin("$(opt) = true", sprint(showerror, err))
    @test isempty(EXPLAIN_CALLS)   # refused before the statement was sent
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# explain: a locked read keeps its transaction requirement
# explain() builds the statement on the execute path, so select_for_update() outside a transaction
# raises exactly as running it would — with or without ANALYZE, which would execute the query and
# take the lock.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explain: select_for_update outside a transaction" begin
  q = ExplainPG.Driver.objects.filter("driverid" => 1).values("surname").select_for_update()
  for analyze in (true, false)   # the guard is the build's, so it holds without ANALYZE too
    empty!(EXPLAIN_CALLS)
    err = try q.explain(analyze = analyze); nothing catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("must run inside a transaction", sprint(showerror, err))
    @test isempty(EXPLAIN_CALLS)
  end
end
