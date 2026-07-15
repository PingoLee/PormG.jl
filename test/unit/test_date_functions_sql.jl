"""
Unit tests for cross-database SQL generation parity of the date/time functions in
`src/Dialect.jl` (issue #25, part 2).

Each of these functions renders DIFFERENTLY on PostgreSQL vs SQLite — PG has native
`EXTRACT(... FROM ...)` / `to_char(...)`, SQLite must emulate with `strftime(...)` /
integer math — and several (`QUARTER`, `QUADRIMESTER`) hand-roll a per-engine formula.
That divergence is exactly where a one-sided edit silently breaks the other backend,
so the two forms are pinned here side by side. No live database required: `Dialect`'s
date functions are pure `(column, format, conn) -> String` renderers, dispatched on the
connection type, so we call them directly with mock connections.

Sibling coverage:
  - `test_date_bucket_operator.jl` → the `__@yyyy_mm` *filter operator* end-to-end (PG).
  - `test_operators.jl` / `test_alignment_sqlite.jl` → F-expression *date arithmetic* (#25 part 1).
  - This file → the raw date-part / date-format function renderers, both engines.
"""

using Test
using PormG
import PormG.Dialect

# Mock connections — only their type matters (dispatch selects the PG vs SQLite body).
struct _PgDateFnConn <: PormG.PormGPostgres end
struct _SlDateFnConn <: PormG.PormGSQLite end
const _PG    = _PgDateFnConn()
const _SL    = _SlDateFnConn()
const _COL   = "\"t\".\"d\""            # a pre-quoted column reference
const _EMPTY = Dict{String, Any}()

@testset "Date/time function cross-DB SQL parity (#25)" begin

  # ===========================================================================
  # QUARTER / QUADRIMESTER — hand-rolled, per-engine formulas (highest drift risk)
  # ===========================================================================
  @testset "QUARTER" begin
    @test Dialect.QUARTER(_COL, _EMPTY, _PG) == "EXTRACT(QUARTER FROM $(_COL))"
    @test Dialect.QUARTER(_COL, _EMPTY, _SL) == "((strftime('%m', $(_COL)) - 1) / 3) + 1"
  end

  @testset "QUADRIMESTER" begin
    @test Dialect.QUADRIMESTER(_COL, _EMPTY, _PG) == "CEIL(EXTRACT(MONTH FROM $(_COL)) / 4.0)"
    @test Dialect.QUADRIMESTER(_COL, _EMPTY, _SL) == "((strftime('%m', $(_COL)) - 1) / 4) + 1"
  end

  # ===========================================================================
  # EXTRACT — PG EXTRACT(part FROM col) vs SQLite CAST(strftime(code, col) AS INTEGER).
  # This borders the new sub-day date arithmetic (HOUR/MINUTE/SECOND), so lock every part.
  # ===========================================================================
  @testset "EXTRACT parts" begin
    # (part, SQLite strftime code)
    for (part, slcode) in [
        ("YEAR",   "%Y"), ("MONTH",  "%m"), ("DAY",    "%d"), ("HOUR",   "%H"),
        ("MINUTE", "%M"), ("SECOND", "%S"), ("DOW",    "%w"), ("DOY",    "%j"),
      ]
      fmt = Dict{String, Any}("part" => part)
      @test Dialect.EXTRACT(_COL, fmt, _PG) == "EXTRACT($part FROM $(_COL))"
      @test Dialect.EXTRACT(_COL, fmt, _SL) == "CAST(strftime('$slcode', $(_COL)) AS INTEGER)"
    end
    # The SQLite whitelist is fail-closed: an unsupported part must throw, not emit garbage.
    @test_throws ArgumentError Dialect.EXTRACT(_COL, Dict{String, Any}("part" => "WEEK"), _SL)
  end

  # ===========================================================================
  # EXTRACT_DATE — PG to_char() vs SQLite strftime(); the format mask maps through
  # sqlite_date_format_map. "YYYY-MM" must resolve to "%Y-%m" (byte-identical logical mask).
  # ===========================================================================
  @testset "EXTRACT_DATE Y_M mask" begin
    fmt = Dict{String, Any}("format" => "YYYY-MM")
    @test occursin("to_char($(_COL), 'YYYY-MM')", Dialect.EXTRACT_DATE(_COL, fmt, _PG))
    @test occursin("strftime('%Y-%m', $(_COL))",  Dialect.EXTRACT_DATE(_COL, fmt, _SL))
  end

  # ===========================================================================
  # YEAR/MONTH/DAY/Y_M wrappers — thin delegators; verify they carry the divergence through.
  # ===========================================================================
  @testset "Date-part wrappers delegate to EXTRACT / EXTRACT_DATE" begin
    @test Dialect.YEAR(_COL, _EMPTY, _PG)  == "EXTRACT(YEAR FROM $(_COL))"
    @test Dialect.YEAR(_COL, _EMPTY, _SL)  == "CAST(strftime('%Y', $(_COL)) AS INTEGER)"
    @test Dialect.MONTH(_COL, _EMPTY, _PG) == "EXTRACT(MONTH FROM $(_COL))"
    @test Dialect.MONTH(_COL, _EMPTY, _SL) == "CAST(strftime('%m', $(_COL)) AS INTEGER)"
    @test Dialect.DAY(_COL, _EMPTY, _PG)   == "EXTRACT(DAY FROM $(_COL))"
    @test Dialect.DAY(_COL, _EMPTY, _SL)   == "CAST(strftime('%d', $(_COL)) AS INTEGER)"
    @test occursin("to_char($(_COL), 'YYYY-MM')", Dialect.Y_M(_COL, _EMPTY, _PG))
    @test occursin("strftime('%Y-%m', $(_COL))",  Dialect.Y_M(_COL, _EMPTY, _SL))
  end
end
