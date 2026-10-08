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

# The EXPLAIN statement for `sql`. Every option is a fixed keyword chosen by a `Bool` — nothing the
# caller passes is ever spliced into the SQL.
function _explain_sql(connection::Union{PormGPostgres, PormGSQLite}, sql::AbstractString;
                      analyze::Bool, buffers::Bool, verbose::Bool)
  if connection isa PormGSQLite
    if analyze || buffers || verbose
      requested = join([name for (name, on) in (("analyze", analyze), ("buffers", buffers), ("verbose", verbose)) if on], ", ")
      throw(BackendCapabilityError("explain($(requested) = true) is PostgreSQL-only: SQLite has no EXPLAIN ANALYZE, BUFFERS or VERBOSE, only EXPLAIN QUERY PLAN. Call explain() without them on SQLite, or run on PostgreSQL."))
    end
    return "EXPLAIN QUERY PLAN " * sql
  end
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

| Key | PostgreSQL | SQLite |
|-----|------------|--------|
| `:explain_sql` | the `EXPLAIN (FORMAT JSON …)` statement run | the `EXPLAIN QUERY PLAN` statement run |
| `:plan` | the parsed JSON plan document | `Vector{Dict}` of `:id`, `:parent`, `:detail` rows |
| `:indexes_used` | every `Index Name` in the plan tree | each `USING [COVERING] INDEX` name; `"INTEGER PRIMARY KEY"` / `"PRIMARY KEY"` for a key lookup; `"AUTOMATIC INDEX"` for a transient index SQLite builds for the statement |
| `:seq_scans` | each relation read by a `Seq Scan` | each `SCAN` step that uses no index |
| `:total_cost`, `:estimated_rows` | the root node's estimates | `nothing` |
| `:planning_time_ms`, `:execution_time_ms` | measured, with `analyze = true` | `nothing` |
| `:analyze` | whether the query was executed | always `false` |

The facts are what the plan states. PormG does not guess whether an index is *missing*: a sequential
scan of a small table is the right plan.

- `analyze = true` **executes the query** (`EXPLAIN ANALYZE`) to measure real timing.
- A `select_for_update()` query needs a transaction on PostgreSQL to be explained at all — with or
  without `analyze` — exactly as it does to run.
- `buffers` / `verbose` add PostgreSQL's `BUFFERS` / `VERBOSE` detail to `:plan`.
- SQLite has only `EXPLAIN QUERY PLAN`: any of the three options raises `BackendCapabilityError`
  there. SQLite names a table in `:seq_scans` / `:plan` by the alias the query gives it.

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
                       connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing)
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
  facts = if conn isa PormGPostgres
    _explain_facts_postgres(Base.first(values(Base.first(rows))))
  else
    _explain_facts_sqlite(rows)
  end
  result = _show_query_result(:inspection, sql, conn, q.object.model.name, :select; parameters = q.object.parameters)
  merge!(result, facts)
  result[:explain_sql] = explain_sql
  result[:analyze] = analyze
  return result
end
explain_query(; kwargs...) = (objct) -> explain_query(objct; kwargs...)
