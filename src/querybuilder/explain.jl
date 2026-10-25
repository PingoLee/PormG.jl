# `explain_query` / `.explain()` (#48): the database's plan for the SELECT a handler builds.
#
# Django-shaped (`QuerySet.explain`): read-only, and ANALYZE is opt-in because it EXECUTES the query.
# It explains exactly what `show_query(q)` renders — the handler's SELECT — so a write is never
# reachable: `.update()` / `.delete()` / `.create()` are terminals, not handler state.
#
# The result is the `:inspection` Dict plus the plan, and the plan facts are reported as the database
# states them — which indexes it used, which tables it scanned sequentially, its cost and timing. No
# heuristic "add an index" advice: a sequential scan of a 20-row table is the right plan, and a
# guess that says otherwise is noise the caller has to learn to ignore.

# `Number` or `nothing` → `Float64` or `nothing` (PG reports costs as JSON numbers, Int or Float).
_explain_float(v) = v === nothing ? nothing : Float64(v)

function _explain_walk_postgres!(node, indexes::Vector{String}, seq_scans::Vector{String})
  haskey(node, "Index Name") && push!(indexes, String(node["Index Name"]))
  if get(node, "Node Type", "") == "Seq Scan" && haskey(node, "Relation Name")
    push!(seq_scans, String(node["Relation Name"]))
  end
  for child in get(node, "Plans", Any[])
    _explain_walk_postgres!(child, indexes, seq_scans)
  end
  return nothing
end

# The facts of one `EXPLAIN (FORMAT JSON …)` document: a one-element array whose object holds the
# root `"Plan"` node (children under `"Plans"`) and, with ANALYZE, the planning/execution times.
# `raw` is the JSON text, or an already-parsed value when the driver decoded the json column itself.
function _explain_facts_postgres(raw)
  doc = raw isa AbstractString ? JSON.parse(raw) : raw
  top = doc isa AbstractVector ? Base.first(doc) : doc
  root = top["Plan"]
  indexes, seq_scans = String[], String[]
  _explain_walk_postgres!(root, indexes, seq_scans)
  rows = get(root, "Plan Rows", nothing)
  return Dict{Symbol, Any}(
    :plan => top,
    :indexes_used => unique(indexes),
    :seq_scans => unique(seq_scans),
    :total_cost => _explain_float(get(root, "Total Cost", nothing)),
    :estimated_rows => rows === nothing ? nothing : Int(rows),
    :planning_time_ms => _explain_float(get(top, "Planning Time", nothing)),
    :execution_time_ms => _explain_float(get(top, "Execution Time", nothing)),
  )
end

# The facts of `EXPLAIN QUERY PLAN` rows (`id`, `parent`, `detail`). SQLite states its access path in
# `detail` — `SCAN t`, `SEARCH t USING INDEX ix (col=?)`, `SCAN t USING COVERING INDEX ix`,
# `SEARCH t USING INTEGER PRIMARY KEY (rowid=?)` — and reports no cost or timing at all.
function _explain_facts_sqlite(rows)
  plan = [Dict{Symbol, Any}(:id => r.id, :parent => r.parent, :detail => String(r.detail)) for r in rows]
  indexes, seq_scans = String[], String[]
  for step in plan
    detail = step[:detail]
    # `SCAN TABLE t` before SQLite 3.36, `SCAN t` since.
    access = match(r"^(SCAN|SEARCH) (?:TABLE )?(\S+)", detail)
    access === nothing && continue
    index = match(r"USING (?:COVERING )?INDEX (\S+)", detail)
    if index !== nothing
      push!(indexes, String(index.captures[1]))
    elseif occursin(r"USING AUTOMATIC (?:PARTIAL )?(?:COVERING )?INDEX", detail)
      # A transient index SQLite builds for this one statement — it reads the whole table to build
      # it, so it is reported as exactly that, never as an index the schema has.
      push!(indexes, "AUTOMATIC INDEX")
    elseif occursin("USING INTEGER PRIMARY KEY", detail)
      push!(indexes, "INTEGER PRIMARY KEY")
    elseif occursin("USING PRIMARY KEY", detail)
      push!(indexes, "PRIMARY KEY")
    elseif access.captures[1] == "SCAN" && access.captures[2] != "CONSTANT" && !startswith(access.captures[2], "(")
      push!(seq_scans, String(access.captures[2]))
    end
  end
  return Dict{Symbol, Any}(
    :plan => plan,
    :indexes_used => unique(indexes),
    :seq_scans => unique(seq_scans),
    :total_cost => nothing,
    :estimated_rows => nothing,
    :planning_time_ms => nothing,
    :execution_time_ms => nothing,
  )
end

# The facts of one `EXPLAIN FORMAT=JSON` document (MySQL, #1130 phase 5b). Each table the plan reads is
# an object with a `table_name` — the query's alias, as on SQLite — and an `access_type`: its `key` is the
# index it reads through (`PRIMARY` for the primary key), and `ALL` is a full scan (measured on 8.4).
# Tables sit under a query block's `table` or `nested_loop`, and inside subqueries and the ordering and
# grouping steps, so the walk visits every object. The block's `query_cost` is the total cost, which
# MySQL states as text; the row estimate is what the top block's last table produces. MySQL reports no
# planning or execution time without ANALYZE, which PormG does not run there (`:explain_options`).
# A name in angle brackets is one MySQL made for the statement — a derived table or a materialized
# subquery (`<derived2>`, `<subquery2>`, `<union1,2>`), or an index it built on one (`<auto_key0>`,
# `<auto_distinct_key>`) — never a table or an index of the schema: such a table is not a scan of one,
# and such an index is reported as SQLite's transient one is, `"AUTOMATIC INDEX"`.
function _explain_walk_mysql!(node, indexes::Vector{String}, seq_scans::Vector{String})
  if node isa AbstractDict
    if haskey(node, "table_name") && haskey(node, "access_type")
      key = get(node, "key", nothing)
      key === nothing || push!(indexes, startswith(String(key), "<") ? "AUTOMATIC INDEX" : String(key))
      name = String(node["table_name"])
      node["access_type"] == "ALL" && !startswith(name, "<") && push!(seq_scans, name)
    end
    foreach(v -> _explain_walk_mysql!(v, indexes, seq_scans), values(node))
  elseif node isa AbstractVector
    foreach(v -> _explain_walk_mysql!(v, indexes, seq_scans), node)
  end
  return nothing
end
function _explain_block_rows_mysql(block)
  for step in ("ordering_operation", "grouping_operation", "duplicates_removal")
    haskey(block, step) && return _explain_block_rows_mysql(block[step])
  end
  haskey(block, "table") && return get(block["table"], "rows_produced_per_join", nothing)
  haskey(block, "nested_loop") && return get(get(last(block["nested_loop"]), "table", Dict()), "rows_produced_per_join", nothing)
  return nothing
end
function _explain_facts_mysql(raw)
  raw isa AbstractVector{UInt8} && (raw = String(raw))
  doc = raw isa AbstractString ? JSON.parse(raw) : raw
  # Version 1 of MySQL's JSON plan, the default; a server set to `explain_json_format_version = 2` (8.3+)
  # writes another shape, which PormG does not read.
  (doc isa AbstractDict && haskey(doc, "query_block")) || throw(QueryBuildError(
    "explain() on MySQL reads the version 1 shape of EXPLAIN FORMAT=JSON (a query_block), and this " *
    "server returned another; set explain_json_format_version = 1 for the session to read the plan."))
  block = doc["query_block"]
  indexes, seq_scans = String[], String[]
  _explain_walk_mysql!(block, indexes, seq_scans)
  cost = get(get(block, "cost_info", Dict()), "query_cost", nothing)
  rows = _explain_block_rows_mysql(block)
  return Dict{Symbol, Any}(
    :plan => doc,
    :indexes_used => unique(indexes),
    :seq_scans => unique(seq_scans),
    :total_cost => cost isa AbstractString ? tryparse(Float64, cost) : _explain_float(cost),
    :estimated_rows => rows === nothing ? nothing : Int(rows),
    :planning_time_ms => nothing,
    :execution_time_ms => nothing,
  )
end

# The EXPLAIN statement for `sql`. Every option is a fixed keyword chosen by a `Bool` — nothing the
# caller passes is ever spliced into the SQL. A backend without `:explain_options` refuses each of them
# rather than ignoring it.
function _refuse_explain_options(connection, analyze::Bool, buffers::Bool, verbose::Bool)
  (analyze || buffers || verbose) || return nothing
  requested = join([name for (name, on) in (("analyze", analyze), ("buffers", buffers), ("verbose", verbose)) if on], ", ")
  throw(_capability_error(connection, :explain_options, "explain($(requested) = true)";
                           why = "Call explain() without them for the plan this backend gives."))
end
function _explain_sql(connection::PormGSQLite, sql::AbstractString; analyze::Bool, buffers::Bool, verbose::Bool)
  _refuse_explain_options(connection, analyze, buffers, verbose)
  return "EXPLAIN QUERY PLAN " * sql
end
# MySQL's plan as a JSON document. Its `EXPLAIN ANALYZE` prints a text tree with no other format, and
# MySQL has no BUFFERS or VERBOSE, so the capability table gives MySQL no `:explain_options`.
function _explain_sql(connection::PormGMySQL, sql::AbstractString; analyze::Bool, buffers::Bool, verbose::Bool)
  _refuse_explain_options(connection, analyze, buffers, verbose)
  return "EXPLAIN FORMAT=JSON " * sql
end
function _explain_sql(connection::PormGPostgres, sql::AbstractString; analyze::Bool, buffers::Bool, verbose::Bool)
  options = ["FORMAT JSON"]
  analyze && push!(options, "ANALYZE")
  buffers && push!(options, "BUFFERS")
  verbose && push!(options, "VERBOSE")
  return "EXPLAIN ($(join(options, ", "))) " * sql
end

"""
    explain_query(q::SQLObjectHandler; analyze = false, buffers = false, verbose = false, connection = nothing) -> Dict

Ask the database how it would run the `SELECT` that `q` builds, and return the plan with its facts.
The fluent form is `q.explain(; …)`, as `q.inspect()` is for [`inspect_query`](@ref).

It explains the same statement [`show_query`](@ref) renders, so it is **read-only**: writes are
terminals (`.update()`, `.delete()`, `.create()`), not something a handler can be explained as.

The result is the [`inspect_query`](@ref) `Dict` — `:sql_text`, `:parameters`, `:dialect`, … — plus:

| Key | PostgreSQL | SQLite | MySQL |
|-----|------------|--------|-------|
| `:explain_sql` | the `EXPLAIN (FORMAT JSON …)` statement run | the `EXPLAIN QUERY PLAN` statement run | the `EXPLAIN FORMAT=JSON` statement run |
| `:plan` | the parsed JSON plan document | `Vector{Dict}` of `:id`, `:parent`, `:detail` rows | the parsed JSON plan document |
| `:indexes_used` | every `Index Name` in the plan tree | each `USING [COVERING] INDEX` name; `"INTEGER PRIMARY KEY"` / `"PRIMARY KEY"` for a key lookup; `"AUTOMATIC INDEX"` for a transient index SQLite builds for the statement | every table's `key`; `"PRIMARY"` for the primary key |
| `:seq_scans` | each relation read by a `Seq Scan` | each `SCAN` step that uses no index | each table read in full (`access_type` `ALL`) |
| `:total_cost`, `:estimated_rows` | the root node's estimates | `nothing` | the query block's cost, and the rows its last table produces |
| `:planning_time_ms`, `:execution_time_ms` | measured, with `analyze = true` | `nothing` | `nothing` |
| `:analyze` | whether the query was executed | always `false` | always `false` |

The facts are what the plan states. PormG does not guess whether an index is *missing*: a sequential
scan of a small table is the right plan.

- `analyze = true` **executes the query** (`EXPLAIN ANALYZE`) to measure real timing.
- A `select_for_update()` query needs a transaction to be explained at all, on every engine — with or
  without `analyze` — exactly as it does to run.
- `buffers` / `verbose` add PostgreSQL's `BUFFERS` / `VERBOSE` detail to `:plan`.
- SQLite has only `EXPLAIN QUERY PLAN`, and MySQL's `EXPLAIN ANALYZE` has no format PormG reads: any
  of the three options raises `BackendCapabilityError` on both. Each names a table in `:seq_scans` /
  `:plan` by the alias the query gives it.

```julia
plan = M.Result.objects.
    filter("driverid__surname" => "Senna").
    values("raceid", "points").
    explain()
plan[:indexes_used]   # ["result_driverid_lunjedbf_idx"] — results found through the driverid index
plan[:seq_scans]      # ["driver"] — the surname filter reads the driver table in full

timed = M.Result.objects.filter("raceid__year" => 1991).values("points").explain(analyze = true)   # PostgreSQL
timed[:execution_time_ms]   # e.g. 0.352
```

A joined query must still select its columns with `.values(...)` — `explain()` builds exactly the
statement `.list()` would run, and refuses the same shapes.
"""
function explain_query(q::SQLObjectHandler; analyze::Bool = false, buffers::Bool = false, verbose::Bool = false,
                       connection::Union{Nothing, _SQLEngine} = nothing)
  # #43: never mutate the caller — `query()` writes the bound parameters back onto the handler.
  q = deepcopy(q)
  _, conn, _ = get_settings(q, connection = connection)
  # Refuse an unsupported option before the build, so nothing is rendered or fetched for it.
  _explain_sql(conn, ""; analyze, buffers, verbose)
  # `:execute` so the SELECT FOR UPDATE outside-a-transaction guard applies, as it does to running it.
  sql = query(q, connection = conn, show_query = :execute)
  explain_sql = _explain_sql(conn, sql; analyze, buffers, verbose)
  # On `conn`, the pool the statement was built for: a `connection =` override must be explained
  # where it points, not on the model's default pool. `fetch` still reuses an open transaction's
  # connection on that pool.
  rows = fetch(conn, explain_sql, q.object.parameters) |> Tables.rowtable
  facts = _explain_facts(conn, rows)
  result = _show_query_result(:inspection, sql, conn, q.object.model.name, :select; parameters = q.object.parameters)
  merge!(result, facts)
  result[:explain_sql] = explain_sql
  result[:analyze] = analyze
  return result
end
explain_query(; kwargs...) = (objct) -> explain_query(objct; kwargs...)

# The plan's facts, read from the rows each engine's EXPLAIN returns.
_explain_facts(::PormGPostgres, rows) = _explain_facts_postgres(Base.first(values(Base.first(rows))))
_explain_facts(::PormGSQLite, rows) = _explain_facts_sqlite(rows)
_explain_facts(::PormGMySQL, rows) = _explain_facts_mysql(Base.first(values(Base.first(rows))))
