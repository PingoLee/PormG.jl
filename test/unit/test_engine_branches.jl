# ==============================================================================
# Engine branches are reviewed (#1129, ahead of #1130)
#
# `x isa PormGSQLite ? … : …` decides for two engines at once, and its `else` is what a THIRD backend
# silently gets: the other engine's SQL, the other engine's DDL, or no refusal. When the connection
# types widen for MySQL (#1130), each such branch is a decision to make — dispatch on the backend,
# read the capability table (`_supports`), or a refusal — not a default to inherit.
#
# This file holds the reviewed count per file. A new branch fails here: prefer an engine fact
# (`src/querybuilder/engine_facts.jl` — one method per engine, no fallback), dispatch, or
# `_supports(conn, :feature)`, and if a branch is still the right shape, raise the count with a word
# on why. A count that FALLS fails too, so the list stays exact (lower it in the same change).
#
# Since #1129 item 2 what remains is compliant (`if … elseif … else throw` chains that name both
# engines and refuse any other) or a recorded one-engine quirk whose other arm is the engine-neutral
# path — each listed with its reason beside the counts below. Engine facts live in
# `src/querybuilder/engine_facts.jl` and `src/migrations/engine_facts.jl`.
#
# Run: julia --project=test/integration test/unit/test_engine_branches.jl
# ==============================================================================

using Test
using PormG

# `x isa PormGSQLite`, `x isa Union{PormGPostgres, …}`, `isa(x, PormGSQLite)`, and an adapter string compare.
const _EB_PATTERN = r"isa\s+(PormG\.)?PormG(Postgres|SQLite)\b|isa\s+Union\{[^}]*PormG(Postgres|SQLite)|isa\([^,()]+,\s*(PormG\.)?PormG(Postgres|SQLite)\b|adapter == \"(SQLite|PostgreSQL)\""

const _EB_REVIEWED = Dict(
  # #1129 item 2 (PR B): ConnectionPool, Configuration and migrations ask engine facts too
  # (`migrations/engine_facts.jl`, and the lease/execute/transaction helpers in ConnectionPool.jl).
  # What remains:
  #   - Configuration: `_builtin_ignores_for_adapter` and `register_connection` name both adapters
  #     and refuse any other (two each); the `url:` / `postgres_driver:` warnings are SQLite-only
  #     advice that fires only for `adapter: SQLite`;
  #   - ConnectionPool: waiting for the SQLite worker before closing a handle, and SQLite's benign
  #     "no transaction is active" rollback — quirks whose other arm is the engine-neutral path;
  #   - planner: SQLite's reserved `sqlite_` index prefix, and its three `ADD COLUMN` limits, whose
  #     other arm is the plain `ADD COLUMN` every engine has;
  #   - importers: the SQLite-only importer's capability refusal; tools: the setup wizard's choice.
  "src/Configuration.jl" => 6,
  "src/ConnectionPool.jl" => 2,
  "src/migrations/importers.jl" => 1,
  "src/migrations/planner.jl" => 4,
  # #1129 item 2 (PR A): every silent branch in `Dialect.jl` and `src/querybuilder/` now asks an engine
  # fact (`querybuilder/engine_facts.jl`). What remains here is compliant or a recorded quirk:
  #   - `if isa PormGPostgres … elseif isa PormGSQLite … else throw(_unsupported_conn(…))` chains,
  #     which name both engines and refuse any other (execution_bulk, execution_write, many_to_many,
  #     expression_render — two per chain; execution_bulk 438 and execution_write 1202 are one-line
  #     `isa Union{…} ||` / `a || b` forms of the same refusal);
  #   - one-engine quirks whose other arm is the engine-neutral path: execution_write 75 (consume a
  #     reserved SQLite id), projection_types 16 (SQLite's literal affinity), select_nodes 166 (window
  #     frames, a gap in PormG on SQLite).
  "src/querybuilder/execution_bulk.jl" => 7,
  "src/querybuilder/execution_write.jl" => 11,
  "src/querybuilder/expression_render.jl" => 8,
  "src/querybuilder/many_to_many.jl" => 2,
  "src/querybuilder/projection_types.jl" => 1,
  "src/querybuilder/select_nodes.jl" => 1,
  "src/tools.jl" => 1,
)

# ─────────────────────────────────────────────────────────────────────────────
# Engine branches: every `isa PormGPostgres`/`isa PormGSQLite` in src/ and ext/ is a reviewed one
# A comment line is not a branch. The failure prints each line of a file whose count moved, so the
# new branch is read in the test output rather than hunted for.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: engine branches in src/ and ext/ match the reviewed counts" begin
  root = pkgdir(PormG)
  found = Dict{String,Int}()
  lines = Dict{String,Vector{String}}()
  for top in ("src", "ext"), (dir, _, files) in walkdir(joinpath(root, top)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(dir, f)
    hits = String[]
    open(path) do io
      for (i, l) in enumerate(eachline(io))
        startswith(lstrip(l), "#") && continue
        for _ in eachmatch(_EB_PATTERN, l)   # per match: two branches on one line are two
          push!(hits, "$(i): $(strip(l))")
        end
      end
    end
    isempty(hits) && continue
    key = replace(relpath(path, root), '\\' => '/')   # '/' on Windows too
    found[key] = length(hits)
    lines[key] = hits
  end
  for key in sort!(collect(union(keys(found), keys(_EB_REVIEWED))))
    got, want = get(found, key, 0), get(_EB_REVIEWED, key, 0)
    got == want || @info "engine branches in $(key): $(got), reviewed $(want)" lines = get(lines, key, String[])
    @test (key, got) == (key, want)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1129 item 2: no engine branch decides by a two-way choice whose other arm a third backend takes
# A ternary on the engine type (`conn isa PormGPostgres ? A : B`), or a Bool bound from one
# (`sqlite = conn isa PormGSQLite`, then read as "not SQLite"), hands any backend that is neither the
# second arm, silently: SQLite's SQL, PostgreSQL's casts, no refusal. Ask an engine fact instead —
# `src/querybuilder/engine_facts.jl`, one method per engine and no fallback, so a new backend gets a
# `MethodError` naming what it must decide. There is no allowance: since #1129 item 2 no file has one.
# A line scan, so it is a net, not a proof: a ternary whose `?` starts the next line, or a binding
# spelled `local x = …` / `x::Bool = …`, slips past, and a `'?'` later on a guard's line is a false
# positive to reword. A two-way `if … else … end` is the reviewed-count testset's job above.
# ─────────────────────────────────────────────────────────────────────────────
const _EB_TERNARY = r"isa\s+(PormG\.)?PormG(Postgres|SQLite)\b[^\n?]*\?|isa\([^,()]+,\s*(PormG\.)?PormG(Postgres|SQLite)\)[^\n?]*\?|^\s*\w+\s*=\s*[\w.]+\s+isa\s+(PormG\.)?PormG(Postgres|SQLite)\s*(#.*)?$"
@testset "#1129: no two-way engine ternary in src/ or ext/" begin
  root = pkgdir(PormG)
  found = String[]
  for top in ("src", "ext"), (dir, _, files) in walkdir(joinpath(root, top)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(dir, f)
    key = replace(relpath(path, root), '\\' => '/')   # '/' on Windows too
    open(path) do io
      for (i, l) in enumerate(eachline(io))
        startswith(lstrip(l), "#") && continue
        occursin(_EB_TERNARY, l) && push!(found, "$(key):$(i): $(strip(l))")
      end
    end
  end
  isempty(found) || @info "engine ternaries found" lines = found
  @test found == String[]
  # The scan itself sees what it is for — or the empty list above proves nothing.
  @test occursin(_EB_TERNARY, "  x = conn isa PormGPostgres ? 1 : 2")
  @test occursin(_EB_TERNARY, "  sqlite = instruc.connection isa PormGSQLite  # why")
  @test occursin(_EB_TERNARY, "  y = isa(conn, PormGSQLite) ? a : b")
  @test !occursin(_EB_TERNARY, "  conn isa PormGSQLite && foo()")
end
