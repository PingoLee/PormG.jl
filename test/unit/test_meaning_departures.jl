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
struct _MdMy <: PormG.PormGMySQL end
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
const _MD_CONN = Dict{Type,Any}(PormG.PormGPostgres => _MdPg(), PormG.PormGSQLite => _MdSl(),
                                PormG.PormGMySQL => _MdMy())

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
  # The decisions themselves, stated rather than recomputed. Every row is SQLite's departure (#1028,
  # #1040, #1087, #1215, #1259, #1260, #1319, #1325, #1471), as the single `engine` field said before #1170. MySQL's were
  # measured on 8.4.11 with literal casts (#1130 phase 2b): it departs where it reads a boolean as
  # `1`, a temporal value as the number its digits spell (`20090329`) and an overflow as the largest
  # value the type holds (`99.99`); it keeps a rounding cast to an integer, a cast to a scale and
  # single precision (`CAST(… AS FLOAT)` reads back as a `Float32`), and a declared text length, which
  # its `CHAR(n)` cuts (#1252).
  Pg, Sl, My = PormG.PormGPostgres, PormG.PormGSQLite, PormG.PormGMySQL
  @test [(row.issue, row.targets, row.departs, row.keeps) for row in rows] == [
    ("#1028", (:text,), (Sl, My), (Pg,)),
    ("#1028", (:integer,), (Sl,), (Pg, My)),
    ("#1259", (:integer, :number), (Sl, My), (Pg,)),
    ("#1260", (:integer, :number), (Sl, My), (Pg,)),
    ("#1260", (:integer, :number), (Sl, My), (Pg,)),
    ("#1319", (:number,), (Sl, My), (Pg,)),
    ("#1325", (:date,), (Sl, My), (Pg,)),
    ("#1325", (:date,), (Sl, My), (Pg,)),
    ("#1417", (:date,), (Sl, My), (Pg,)),
    ("#1040", (:scale,), (Sl,), (Pg, My)),
    ("#1087", (:precision,), (Sl, My), (Pg,)),
    ("#1215", (:single_precision,), (Sl,), (Pg, My)),
    ("#1252", (:sized_text,), (Sl,), (Pg, My)),
    ("#1471", (:division,), (Sl,), (Pg, My)),
  ]
end

# ─────────────────────────────────────────────────────────────────────────────
# Meaning departures: every engine a row departs on says what it computes instead
# `computes` is per departing engine, so a refusal names the value that engine gives (MySQL's
# `20090329`, not SQLite's "the year"). A `departs` engine with no `computes` pair would fail only when
# the refusal is built; a pair for an engine that does not depart is a stale text. Both fail here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1130: every departing engine has its own computes text, and only those do" begin
  for row in (_MD_QB._MEANING_DEPARTURES..., _MD_QB._INTEGER_QUOTIENT_DEPARTURE)
    departs = row === _MD_QB._INTEGER_QUOTIENT_DEPARTURE ?
      Tuple(T for (_, T) in PormG._BACKENDS if _MD_QB._untyped_sum_departs(_MD_CONN[T])) : row.departs
    @test (row.issue, Set(first.(row.computes))) == (row.issue, Set(departs))
    for T in departs
      text = _MD_QB._computes(row, _MD_CONN[T])(nothing)
      @test text isa String && !isempty(text)
    end
  end
  # The engine at hand's own text reaches the message: MySQL's digits, SQLite's leading digits.
  row = _MD_QB._MEANING_DEPARTURES[4]   # #1260, a date or a timestamp
  msg(conn) = replace(sprint(showerror, _MD_QB._meaning_refusal("Cast", "x", row, conn)), r"\e\[[0-9;]*m" => "")
  @test occursin("MySQL computes its digits read as one number (`2009-03-29` → `20090329`), so PormG refuses it on MySQL", msg(_MdMy()))
  @test occursin("SQLite computes the leading digits of its text, the year, so PormG refuses it on SQLite", msg(_MdSl()))
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
  # builds, and a backend that has not decided it gets a MethodError rather than "builds". MySQL
  # departs: its `SUM` of integers is a DECIMAL and `/` keeps the fraction (`SUM(15) / 2` is `7.5`).
  @test _MD_QB._departure(_MdPg(), :integer, :numeric_whole_division) === _MD_QB._INTEGER_QUOTIENT_DEPARTURE
  @test _MD_QB._departure(_MdSl(), :integer, :numeric_whole_division) === nothing
  @test _MD_QB._departure(_MdMy(), :integer, :numeric_whole_division) === _MD_QB._INTEGER_QUOTIENT_DEPARTURE
  @test_throws MethodError _MD_QB._departure(_MdOther(), :integer, :numeric_whole_division)
end
