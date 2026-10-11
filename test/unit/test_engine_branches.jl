# ==============================================================================
# Engine branches are reviewed (#1129, ahead of #1130)
#
# `x isa PormGSQLite ? … : …` decides for two engines at once, and its `else` is what a THIRD backend
# silently gets: the other engine's SQL, the other engine's DDL, or no refusal. When the connection
# types widen for MySQL (#1130), each such branch is a decision to make — dispatch on the backend,
# read the capability table (`_supports`), or a refusal — not a default to inherit.
#
# This file holds the reviewed count per file. A new branch fails here: prefer dispatch or
# `_supports(conn, :feature)`, and if a branch is still the right shape, raise the count with a word
# on why. A count that FALLS fails too, so the list stays exact (lower it in the same change).
#
# What the branches decide, by file (the track-B inventory's groups): planner — the SQLite table
# rebuild and which DDL each engine runs; ConnectionPool/Configuration — transactions, pool and
# adapter wiring; expression_render/filter_nodes/build_select/select_nodes — interval arithmetic,
# NULL ordering and dialect spelling; execution_* — RETURNING, upserts, sequences and bulk paths;
# column_spec/runner/introspection — type equivalence and introspection; deletion — row locks.
#
# Run: julia --project=test/integration test/unit/test_engine_branches.jl
# ==============================================================================

using Test
using PormG

# `x isa PormGSQLite`, `x isa Union{PormGPostgres, …}`, `isa(x, PormGSQLite)`, and an adapter string compare.
const _EB_PATTERN = r"isa\s+(PormG\.)?PormG(Postgres|SQLite)\b|isa\s+Union\{[^}]*PormG(Postgres|SQLite)|isa\([^,()]+,\s*(PormG\.)?PormG(Postgres|SQLite)\b|adapter == \"(SQLite|PostgreSQL)\""

const _EB_REVIEWED = Dict(
  "src/Configuration.jl" => 6,
  "src/ConnectionPool.jl" => 16,
  "src/Dialect.jl" => 2,
  "src/migrations/column_spec.jl" => 7,
  "src/migrations/importers.jl" => 1,
  "src/migrations/introspection.jl" => 1,
  "src/migrations/planner.jl" => 29,
  "src/migrations/runner.jl" => 7,
  "src/querybuilder/build_select.jl" => 2,
  "src/querybuilder/ctes.jl" => 1,
  "src/querybuilder/deletion.jl" => 4,
  "src/querybuilder/execution_bulk.jl" => 14,
  "src/querybuilder/execution_read.jl" => 4,
  "src/querybuilder/execution_write.jl" => 14,
  "src/querybuilder/explain.jl" => 2,
  "src/querybuilder/expression_kind.jl" => 1,
  "src/querybuilder/expression_render.jl" => 19,
  "src/querybuilder/field_resolution.jl" => 2,
  "src/querybuilder/filter_nodes.jl" => 3,
  "src/querybuilder/filter_operators.jl" => 1,
  "src/querybuilder/many_to_many.jl" => 2,
  "src/querybuilder/projection_types.jl" => 2,
  "src/querybuilder/select_nodes.jl" => 4,
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
