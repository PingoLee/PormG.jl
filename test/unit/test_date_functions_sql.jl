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
    @test_throws PormG.BackendCapabilityError Dialect.EXTRACT(_COL, Dict{String, Any}("part" => "WEEK"), _SL)
  end

  # ===========================================================================
  # EXTRACT_DATE — PG to_char() vs SQLite strftime(); the format mask maps through
  # date_format_map. "YYYY-MM" must resolve to "%Y-%m" (byte-identical logical mask).
  # ===========================================================================
  @testset "EXTRACT_DATE Y_M mask" begin
    fmt = Dict{String, Any}("format" => "YYYY-MM")
    @test occursin("to_char($(_COL), 'YYYY-MM')", Dialect.EXTRACT_DATE(_COL, fmt, _PG))
    @test occursin("strftime('%Y-%m', $(_COL))",  Dialect.EXTRACT_DATE(_COL, fmt, _SL))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXTRACT_DATE (#569): every `date_format_map` key renders ITS OWN engine's spelling
  # Until #569 the map held one string per row, used as the SQLite mask AND passed through to
  # `to_char` as the key itself — so `HH` was 12-hour on PostgreSQL, `T` before `H` parsed as the
  # `TH` ordinal suffix, and three SQLite masks spelled `%S.%f` (seconds twice). The rows now carry
  # a `postgres` and a `sqlite` half; this pins that each arm reads its own half and never the key.
  # What the halves EVALUATE to is measured in-engine by `vr_run_tochar_formats`
  # (`helper_value_repr_cases.jl`); this file only pins the rendering.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "EXTRACT_DATE renders each engine's own template (#569)" begin
    for (key, entry) in PormG.date_format_map
      fmt = Dict{String, Any}("format" => key)
      # The PostgreSQL arm renders the `postgres` half — never the key.
      @test occursin("to_char($(_COL), '$(entry.postgres)')", Dialect.EXTRACT_DATE(_COL, fmt, _PG))
      # The SQLite arm renders the `sqlite` half.
      @test occursin("strftime('$(entry.sqlite)', $(_COL))", Dialect.EXTRACT_DATE(_COL, fmt, _SL))
      # Neither half may carry the two defects the issue measured: `%S.%f` on SQLite, and a
      # 12-hour `HH` (an `HH` not followed by `24`) or a bare `T` before `H` on PostgreSQL.
      # These two regexes are deliberately blunt: a future row spelling `HH12` or carrying a
      # bare `T` inside a word (`MONTH`, `TH`) would trip them too. That is the point of a
      # portable whitelist — such a row is not portable, so add it to the oracle and to these
      # pins together rather than loosening the regex.
      @test !occursin("%S.%f", entry.sqlite)
      @test !occursin(r"HH(?!24)", entry.postgres)
      @test !occursin(r"(?<!\")T(?!\")", entry.postgres)
    end
    # The row the canonical timestamp mask derives from, spelled out so a regression is readable.
    fmt = Dict{String, Any}("format" => "YYYY-MM-DDTHH:MI:SS.SSS")
    @test occursin("to_char($(_COL), 'YYYY-MM-DD\"T\"HH24:MI:SS.MS')", Dialect.EXTRACT_DATE(_COL, fmt, _PG))
    @test occursin("strftime('%Y-%m-%dT%H:%M:%f', $(_COL))", Dialect.EXTRACT_DATE(_COL, fmt, _SL))
    # One canonical spelling: the mask date arithmetic canonicalizes through IS that row plus the
    # UTC suffix — derived, so the two cannot drift apart again.
    @test Dialect.SQLITE_CANONICAL_DATETIME_MASK == "'" * PormG.date_format_map["YYYY-MM-DDTHH:MI:SS.SSS"].sqlite * "+00:00'"
    @test Dialect.SQLITE_CANONICAL_DATETIME_MASK == "'%Y-%m-%dT%H:%M:%f+00:00'"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXTRACT_DATE (#569): a format outside the map
  # PostgreSQL passes it through as a native `to_char` template (the documented PostgreSQL-only
  # escape), with the single quote escaped so the format can never close the SQL literal it sits
  # in. SQLite has no way to spell an arbitrary template, so the whitelist is fail-closed — a
  # `BackendCapabilityError` naming the supported keys, like `EXTRACT`'s part whitelist above —
  # where it used to be a bare `KeyError` outside the taxonomy.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "EXTRACT_DATE unmapped format: PG passes through escaped, SQLite refuses (#569)" begin
    # A native template the map does not carry — the 12-hour clock PostgreSQL users may want.
    fmt = Dict{String, Any}("format" => "HH12:MI AM")
    @test occursin("to_char($(_COL), 'HH12:MI AM')", Dialect.EXTRACT_DATE(_COL, fmt, _PG))
    @test_throws PormG.BackendCapabilityError Dialect.EXTRACT_DATE(_COL, fmt, _SL)
    # The refusal names the supported formats, so the user can pick a portable one.
    err = try
      Dialect.EXTRACT_DATE(_COL, fmt, _SL)
    catch e
      e
    end
    @test occursin("HH12:MI AM", PormG.error_message(err))
    @test occursin("YYYY-MM-DD", PormG.error_message(err))
    # A quote inside the pass-through is doubled, not written raw into the literal.
    quoted = Dict{String, Any}("format" => "YYYY'MM")
    @test occursin("to_char($(_COL), 'YYYY''MM')", Dialect.EXTRACT_DATE(_COL, quoted, _PG))
    @test !occursin("'YYYY'MM'", Dialect.EXTRACT_DATE(_COL, quoted, _PG))
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
