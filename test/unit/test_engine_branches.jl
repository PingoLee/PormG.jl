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
# The last testset holds the same count for test/integration/ (#1179), where a branch is a test
# expectation a third backend would inherit rather than a code path.
#
# Run: julia --project=test/integration test/unit/test_engine_branches.jl
# ==============================================================================

using Test
using PormG

# `x isa PormGSQLite`, `x isa Union{PormGPostgres, …}`, `isa(x, PormGSQLite)`, and an adapter string compare.
# MySQL (#1130) counts like the other two: a branch naming it is one more engine decided by name.
const _EB_PATTERN = r"isa\s+(PormG\.)?PormG(Postgres|SQLite|MySQL)\b|isa\s+Union\{[^}]*PormG(Postgres|SQLite|MySQL)|isa\([^,()]+,\s*(PormG\.)?PormG(Postgres|SQLite|MySQL)\b|adapter == \"(SQLite|PostgreSQL|MySQL)\""

const _EB_REVIEWED = Dict(
  # #1129 item 2 (PR B): ConnectionPool, Configuration and migrations ask engine facts too
  # (`migrations/engine_facts.jl`, and the lease/execute/transaction helpers in ConnectionPool.jl).
  # What remains:
  #   - Configuration: `_builtin_ignores_for_adapter` names each adapter and refuses any other (three);
  #     `register_connection` names PostgreSQL and SQLite and refuses MySQL (#1130: no connection URL
  #     yet) and any other (three); the `url:` / `postgres_driver:` warnings are SQLite-only advice
  #     that fires only for `adapter: SQLite`; `_peek_driver` (#1232) names each adapter to pick the
  #     driver extension `load` checks, and leaves any other adapter to the reader that refuses it
  #     (three);
  #   - ConnectionPool: waiting for the SQLite worker before closing a handle, and SQLite's benign
  #     "no transaction is active" rollback — quirks whose other arm is the engine-neutral path;
  #   - planner: SQLite's reserved `sqlite_` index prefix, and its three `ADD COLUMN` limits, whose
  #     other arm is the plain `ADD COLUMN` every engine has;
  #   - importers: the SQLite-only importer's capability refusal; tools: the setup wizard's choice.
  "src/Configuration.jl" => 11,
  "src/ConnectionPool.jl" => 2,
  "src/migrations/importers.jl" => 1,
  "src/migrations/planner.jl" => 4,
  # #1129 item 2 (PR A): every silent branch in `Dialect.jl` and `src/querybuilder/` now asks an engine
  # fact (`querybuilder/engine_facts.jl`). What remains here is compliant or a recorded quirk:
  #   - `if isa PormGPostgres … elseif isa PormGSQLite … else throw(_unsupported_conn(…))` chains,
  #     which name both engines and refuse any other (execution_bulk, execution_write, many_to_many,
  #     expression_render's `xor` — two per chain; execution_bulk 438 is a one-line `isa Union{…} ||`
  #     form of the same refusal). expression_render's three
  #     temporal chains (a shift, a difference, a day-count shift) became one method per engine when
  #     MySQL gained its own (#1130 phase 2b), 8 → 2. execution_write's `insert` read-back, joined
  #     `update` and `update` count became engine facts when MySQL gained writes (#1130 phase 3a),
  #     11 → 5: the two upsert chains (phase 3b) and the SQLite id reservation remain;
  #   - one-engine quirks whose other arm is the engine-neutral path: execution_write 75 (consume a
  #     reserved SQLite id), projection_types 16 (SQLite's literal affinity), select_nodes 166 (window
  #     frames, a gap in PormG on SQLite).
  "src/querybuilder/execution_bulk.jl" => 7,
  "src/querybuilder/execution_write.jl" => 5,
  "src/querybuilder/expression_render.jl" => 2,
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
const _EB_TERNARY = r"isa\s+(PormG\.)?PormG(Postgres|SQLite|MySQL)\b[^\n?]*\?|isa\([^,()]+,\s*(PormG\.)?PormG(Postgres|SQLite|MySQL)\)[^\n?]*\?|^\s*\w+\s*=\s*[\w.]+\s+isa\s+(PormG\.)?PormG(Postgres|SQLite|MySQL)\s*(#.*)?$"
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

# ─────────────────────────────────────────────────────────────────────────────
# #1179: engine branches in test/integration/ match the reviewed counts
# A test that branches on the engine by name gives a backend added later (#1130) one engine's DDL,
# text or expectation through its `else`, without anyone deciding it — the same risk as in src/, on
# the test side. Each such branch is classified (#1147's four categories) and becomes:
#   - a feature: `requires(:feature)`, with the refusal asserted in its `else` (common_setup.jl);
#   - representation or engine mechanics: `by_engine(postgres = …, sqlite = …)`, which has no
#     fallback, or `only_on(:engine, why)` for a testset that drives one engine's own machinery;
#   - meaning: no engine branch on the value; the engine that departs refuses, stated as data.
# What is left is counted here per file, with the reason. `PORMG_DB_FOLDER ==`, `adapter_name ==`
# and an inspected query's `[:dialect] ==` count like an `isa`, and so does comparing `engine_key()`
# to a symbol, which would only respell `is_pg ?`. A line scan, so it counts lines, not decisions: a flag bound once and
# read sixty times is one hit, so a count is a file's bindings, not its reads.
# ─────────────────────────────────────────────────────────────────────────────
const _EB_INTEGRATION_PATTERN = Regex(_EB_PATTERN.pattern *
  raw"|PORMG_DB_FOLDER\s*[!=]=|adapter_name\s*[!=]=|\[:dialect\]\s*[!=]=|engine_key\([^)]*\)\s*(===?|!==?)\s*:")

const _EB_INTEGRATION_REVIEWED = Dict(
  # Each test database folder ships its own models file and `@import_models` takes a literal path,
  # so the loader names each folder (a folder, not an engine) and errors on any other.
  # Three folders: db_2 (PostgreSQL), db_sl (SQLite), db_my (MySQL, #1130).
  "test/integration/common_setup.jl" => 3,
  # Not in runtests.jl: a run against another folder is a usage error it refuses, not a skip.
  "test/integration/test_allocate_primary_keys_sqlite.jl" => 1,
)

@testset "#1179: engine branches in test/integration/ match the reviewed counts" begin
  dir = joinpath(pkgdir(PormG), "test", "integration")
  found = Dict{String,Int}()
  lines = Dict{String,Vector{String}}()
  for f in readdir(dir)
    endswith(f, ".jl") || continue
    hits = String[]
    open(joinpath(dir, f)) do io
      for (i, l) in enumerate(eachline(io))
        startswith(lstrip(l), "#") && continue
        for _ in eachmatch(_EB_INTEGRATION_PATTERN, l)
          push!(hits, "$(i): $(strip(l))")
        end
      end
    end
    isempty(hits) && continue
    key = "test/integration/$(f)"
    found[key] = length(hits)
    lines[key] = hits
  end
  for key in sort!(collect(union(keys(found), keys(_EB_INTEGRATION_REVIEWED))))
    got, want = get(found, key, 0), get(_EB_INTEGRATION_REVIEWED, key, 0)
    got == want || @info "engine branches in $(key): $(got), reviewed $(want)" lines = get(lines, key, String[])
    @test (key, got) == (key, want)
  end
  # The scan sees each spelling it is for — or a clean directory proves nothing.
  for l in ("if pool isa PormG.PormGPostgres", "if PORMG_DB_FOLDER == \"db_sl\"",
            "if adapter_name != \"SQLite\"", "x = engine_key() === :postgres ? a : b",
            "engine_key(conn) == :sqlite && f()", "if insp[:dialect] == :sqlite")
    @test occursin(_EB_INTEGRATION_PATTERN, l)
  end
  @test !occursin(_EB_INTEGRATION_PATTERN, "if by_engine(postgres = true, sqlite = false)")
  @test !occursin(_EB_INTEGRATION_PATTERN, "if only_on(:postgres, \"why\")")
end
