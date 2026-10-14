# ==============================================================================
# The meaning departures classify every backend (#1170)
#
# `_MEANING_DEPARTURES` (`src/querybuilder/engine_departures.jl`) lists, per refusal target and operand
# kind, the engines that compute another value than the expression means (they refuse it) and the
# engines that compute the meaning (they build it). Until #1170 a row named only the engine that
# departs, and a backend with no row was taken to keep the meaning: a third backend (#1130) inherited
# "builds" for every divergence nobody had checked it against — a silently different value. Every row
# now names every backend in `_BACKENDS` in `departs` or in `keeps`, and this file fails for a backend
# in neither, so adding one to `_BACKENDS` lists the rows it must decide. The runtime rule is unchanged:
# an engine refuses only where its row says it departs. The integer-quotient departure is an engine
# fact instead (`_untyped_sum_departs`, #1034 phase 3 step 2a), which `test_engine_facts.jl` guards.
#
# Run: julia --project=test/integration test/unit/test_meaning_departures.jl
# ==============================================================================

using Test
using PormG

const _MD_QB = PormG.QueryBuilder
struct _MdPg <: PormG.PormGPostgres end
struct _MdSl <: PormG.PormGSQLite end
struct _MdOther <: PormG.PormGBackend end   # a backend that has decided nothing yet, as #1130 starts

# The rows that leave a backend of `backends` (`name => type` pairs, as `_BACKENDS` holds them)
# unclassified — in neither list — or classified both ways, as `(issue, targets, name, problem)`.
function _md_unclassified(rows, backends)
  out = Tuple{String,Tuple,String,Symbol}[]
  for row in rows, (name, T) in backends
    departs = any(D -> T <: D, row.departs)
    keeps = any(K -> T <: K, row.keeps)
    departs && keeps && push!(out, (row.issue, row.targets, name, :both))
    !departs && !keeps && push!(out, (row.issue, row.targets, name, :neither))
  end
  return out
end

# An instance of each shipped engine, to ask `_departure` with.
const _MD_CONN = Dict{Type,Any}(PormG.PormGPostgres => _MdPg(), PormG.PormGSQLite => _MdSl())

# ─────────────────────────────────────────────────────────────────────────────
# Meaning departures: every row decides every shipped backend, exactly once
# The table is not empty (the guard of the guard: an empty table passes every check below), and each
# row names each `_BACKENDS` engine in `departs` or in `keeps`, never both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1170: every meaning-departure row classifies every backend in _BACKENDS" begin
  rows = _MD_QB._MEANING_DEPARTURES
  @test length(rows) >= 4
  @test all(row -> !isempty(row.departs), rows)
  @test _md_unclassified(rows, PormG._BACKENDS) == []
  # The decisions themselves, stated rather than recomputed: every row is SQLite's departure
  # (#1028, #1040, #1087), as the single `engine` field said before #1170.
  @test [(row.issue, row.targets, row.departs, row.keeps) for row in rows] == [
    ("#1028", (:text,), (PormG.PormGSQLite,), (PormG.PormGPostgres,)),
    ("#1028", (:integer,), (PormG.PormGSQLite,), (PormG.PormGPostgres,)),
    ("#1040", (:scale,), (PormG.PormGSQLite,), (PormG.PormGPostgres,)),
    ("#1087", (:precision,), (PormG.PormGSQLite,), (PormG.PormGPostgres,)),
  ]
end

# ─────────────────────────────────────────────────────────────────────────────
# Meaning departures: a backend added to _BACKENDS without decisions fails, row by row
# The check run with a third backend appended: it reports that backend for every row, as unclassified,
# which is the to-do list #1130 starts from. One deciding both ways is reported too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1170: a third backend with no decisions is unclassified on every row" begin
  rows = _MD_QB._MEANING_DEPARTURES
  found = _md_unclassified(rows, (PormG._BACKENDS..., "Other" => _MdOther))
  @test length(found) == length(rows)
  @test all(f -> f[3] == "Other" && f[4] === :neither, found)
  @test Set(f[1] for f in found) == Set(row.issue for row in rows)
  # A row that lists its departing engine under `keeps` as well is reported for that engine only.
  row = first(rows)
  both = [merge(row, (keeps = (row.keeps..., row.departs...),))]
  @test _md_unclassified(both, PormG._BACKENDS) ==
        [(row.issue, row.targets, name, :both) for (name, T) in PormG._BACKENDS if any(D -> T <: D, row.departs)]
end

# ─────────────────────────────────────────────────────────────────────────────
# Meaning departures: the runtime rule reads the lists — `departs` refuses, `keeps` builds
# For every row and each of its (target, kind) pairs, `_departure` answers the row on an engine in
# `departs` and `nothing` on one in `keeps`: the same decisions as before #1170, by construction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1170: _departure refuses on the engines a row departs on and builds on the rest" begin
  for row in _MD_QB._MEANING_DEPARTURES, target in row.targets, kind in row.kinds
    for (_, T) in PormG._BACKENDS
      conn = _MD_CONN[only(k for k in keys(_MD_CONN) if T <: k)]
      expected = any(D -> T <: D, row.departs) ? row : nothing
      @test (row.issue, target, kind, T, _MD_QB._departure(conn, target, kind) === expected) ==
            (row.issue, target, kind, T, true)
    end
  end
  # The integer quotient is the engine fact's (#1034 phase 3 step 2a): PostgreSQL departs, SQLite
  # builds, and a backend that has not decided it gets a MethodError rather than "builds".
  @test _MD_QB._departure(_MdPg(), :integer, :numeric_whole_division) === _MD_QB._INTEGER_QUOTIENT_DEPARTURE
  @test _MD_QB._departure(_MdSl(), :integer, :numeric_whole_division) === nothing
  @test_throws MethodError _MD_QB._departure(_MdOther(), :integer, :numeric_whole_division)
end
