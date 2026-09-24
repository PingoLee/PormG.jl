"""
Unit tests for #713: the frame clause in `WindowOver(frame=)` is validated and re-spelled.

A frame clause is SQL grammar, not a value, so it cannot be a bind parameter — the same defect class
as #691's `Extract` part and #696's `Cast` type names. Until #713 `WindowOver` stored the caller's
string and `_build_over_clause` wrote it into `OVER (...)` after only a `strip`, so
`frame = "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS x FROM race; --"` closed the window and
rewrote the statement. `Dialect.window_frame_sql` is the one grammar; `WindowOver` parses at build
time, and `_build_over_clause` parses again because `WindowSpec` is exported and mutable.

The sibling in the same family: `Dialect.EXTRACT_DATE` interpolated `format["locale"]` /
`format["nlsparam"]` raw. No public constructor set either key, so they are removed, not validated.

Hermetic: mock connections and an inline model module, no live database.

Sibling coverage:
  - `test_window_functions.jl` → SQLite refuses any explicit frame (`BackendCapabilityError`).
  - `test_constructor_abstractstring.jl` → a `SubString` frame is stored as a `String`.
  - `test/integration/test_window_functions.jl` → a full frame changes `LastValue` on PostgreSQL.
"""

using Test
using PormG
import PormG.Dialect
using PormG.QueryBuilder: inspect_query, WindowSpec
using PormG.Functions: WindowOver, LastValue, RowNumber

# Mock connections — only their type matters (dispatch selects the PG vs SQLite body).
struct _PgFrameConn <: PormG.PormGPostgres end
struct _SlFrameConn <: PormG.PormGSQLite end
const _FPG = _PgFrameConn()
const _FSL = _SlFrameConn()
# SQLite window support is gated behind a live version probe; pin one so the file runs standalone.
PormG.backend_sqlite_version(::_SlFrameConn) = 3045000
PormG.config["frame713_pg"] = PormG.Configuration.Settings(connections = _FPG, change_data = true)
PormG.config["frame713_sl"] = PormG.Configuration.Settings(connections = _FSL, change_data = true)

Frame713Pg = PormG.Models.Model("frame713_result",
  resultid = PormG.Models.IDField(),
  constructorid = PormG.Models.IntegerField(),
  positionorder = PormG.Models.IntegerField(),
  points = PormG.Models.FloatField())
Frame713Pg.connect_key = "frame713_pg"
Frame713Sl = PormG.Models.Model("frame713_result",
  resultid = PormG.Models.IDField(),
  constructorid = PormG.Models.IntegerField(),
  positionorder = PormG.Models.IntegerField(),
  points = PormG.Models.FloatField())
Frame713Sl.connect_key = "frame713_sl"

# `LastValue` is the function the docs pair with a frame; any window function reaches the same sink.
_f713_q(model, spec) = model.objects.values("resultid", "last" => LastValue("points", over = spec))
_f713_sql(model, spec) = inspect_query(_f713_q(model, spec))[:sql_text]

# (caller's text, PormG's rebuilt spelling). Every frame string the docs show is here, plus the
# grammar's corners: the one-bound form, GROUPS, the four EXCLUDE forms, and the two RANGE-only
# offsets. The caller's case and spacing are not kept — the rebuilt spelling is what reaches SQL.
const _ACCEPTED = [
  # docs/src/read/window_functions.md → "Common frame strings", and the LastValue example
  "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" => "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW",
  "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING" => "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING",
  "ROWS BETWEEN 2 PRECEDING AND CURRENT ROW" => "ROWS BETWEEN 2 PRECEDING AND CURRENT ROW",
  "ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING" => "ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING",
  "ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING" => "ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING",
  # the one-bound form (test_constructor_abstractstring.jl's probe) and the docs' short example
  "ROWS UNBOUNDED PRECEDING" => "ROWS UNBOUNDED PRECEDING",
  "ROWS 2 PRECEDING" => "ROWS 2 PRECEDING",
  "rows current row" => "ROWS CURRENT ROW",
  # case, surrounding and inner whitespace, newlines: all re-spelled
  "  rows   between 1 preceding\n and current row  " => "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW",
  "Range Between Unbounded Preceding And Current Row" => "RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW",
  "GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING" => "GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING",
  # two offsets on the same side, in either order — PostgreSQL accepts both (an empty frame is legal)
  "ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING" => "ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING",
  "ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING" => "ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING",
  # EXCLUDE, all four forms
  "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW" =>
    "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW",
  "groups 1 preceding exclude group" => "GROUPS 1 PRECEDING EXCLUDE GROUP",
  "RANGE UNBOUNDED PRECEDING EXCLUDE TIES" => "RANGE UNBOUNDED PRECEDING EXCLUDE TIES",
  "ROWS 1 PRECEDING EXCLUDE NO OTHERS" => "ROWS 1 PRECEDING EXCLUDE NO OTHERS",
  # RANGE-only offsets: a decimal, and an interval with a plain unit (singular or plural)
  "RANGE BETWEEN 0.5 PRECEDING AND CURRENT ROW" => "RANGE BETWEEN 0.5 PRECEDING AND CURRENT ROW",
  "range between interval '7 DAYS' preceding and current row" =>
    "RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW",
  "RANGE BETWEEN INTERVAL ' 1  hour ' PRECEDING AND INTERVAL '30 minutes' FOLLOWING" =>
    "RANGE BETWEEN INTERVAL '1 hour' PRECEDING AND INTERVAL '30 minutes' FOLLOWING",
]

# Refused, each for its own reason. The first is the issue's own reproduction.
const _REFUSED = [
  "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS x FROM race; --",   # #713's repro
  "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW; DROP TABLE race",
  "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW --",
  "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW /* x */",
  "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW OR TRUE",               # no `;` and no `--`, still extra SQL
  "ROWS BETWEEN (SELECT 1) PRECEDING AND CURRENT ROW",               # an expression offset
  "ROWS BETWEEN \$1 PRECEDING AND CURRENT ROW",                     # a placeholder offset
  "ROWS BETWEEN -1 PRECEDING AND CURRENT ROW",                       # negative
  "ROWS BETWEEN 1.5 PRECEDING AND CURRENT ROW",                      # a decimal is RANGE-only
  "GROUPS BETWEEN INTERVAL '1 day' PRECEDING AND CURRENT ROW",       # an interval is RANGE-only
  "RANGE BETWEEN INTERVAL '1 fortnight' PRECEDING AND CURRENT ROW",  # unit outside the closed set
  "RANGE BETWEEN INTERVAL '1 day'' PRECEDING AND CURRENT ROW",       # a quote-doubling escape attempt
  "RANGE BETWEEN INTERVAL '1 day' || 'x' PRECEDING AND CURRENT ROW",
  "RANGE BETWEEN INTERVAL 1 PRECEDING AND CURRENT ROW",
  "RANGE BETWEEN '1 day' PRECEDING AND CURRENT ROW",                 # a bare literal is no bound
  "ROWS BETWEEN 1 PRECEDING",                                        # missing AND
  "ROWS BETWEEN 1 PRECEDING OR CURRENT ROW",
  "ROWS 1",                                                          # missing direction
  "ROWS CURRENT",
  "BETWEEN 1 PRECEDING AND CURRENT ROW",                             # missing unit
  "ORDER BY points ROWS 1 PRECEDING",
  "ROWS 1 PRECEDING EXCLUDE OTHERS",
  "ROWS 1 PRECEDING EXCLUDE CURRENT ROW EXCLUDE TIES",
  "ROWS 1 PRECEDING 1",                                              # trailing token
  # PostgreSQL's own ordering rules
  "ROWS UNBOUNDED FOLLOWING",
  "ROWS BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING",
  "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED PRECEDING",
  "ROWS BETWEEN CURRENT ROW AND 1 PRECEDING",
  "ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW",
  "ROWS BETWEEN 1 FOLLOWING AND 1 PRECEDING",
  "ROWS 1 FOLLOWING",                                                # one bound ends at CURRENT ROW
  # shape
  "",
  "   ",
  "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW\0",
  "ROWS BETWEEN 1 PRECEDING AND\u00a0CURRENT ROW",                   # U+00A0: PCRE's `\s` matches it, only `isascii` refuses
  "ROWS BETWEEN 1 PRECEDİNG AND CURRENT ROW",                       # dotted İ — the tokenizer splits the word
  "ROWS BETWEEN " * repeat("0", 200) * " PRECEDING AND CURRENT ROW",  # over the length cap
]

# ─────────────────────────────────────────────────────────────────────────────
# #713: every documented frame is accepted and re-spelled
# `WindowOver` stores PormG's rebuilt spelling, and that spelling is exactly what lands inside
# `OVER (...)` — so the SQL is written from parsed pieces, never from the caller's string.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#713: accepted frames render PormG's own spelling" begin
  for (given, canonical) in _ACCEPTED
    @testset "$(repr(given))" begin
      @test Dialect.window_frame_sql(given) == canonical
      # The constructor stores the rebuilt spelling, not the caller's text.
      spec = WindowOver(order_by = ["positionorder"], frame = given)
      @test spec.frame == canonical
      # ... and that spelling is the whole frame clause of the rendered window.
      @test occursin("ORDER BY \"Tb\".\"positionorder\" ASC $(canonical))", _f713_sql(Frame713Pg, spec))
    end
  end
  # The docs' LastValue example, end to end: partition, order, and the full frame.
  spec = WindowOver(partition_by = ["constructorid"], order_by = ["positionorder"],
                    frame = "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING")
  @test occursin("LAST_VALUE(\"Tb\".\"points\") OVER (PARTITION BY \"Tb\".\"constructorid\" ORDER BY " *
                 "\"Tb\".\"positionorder\" ASC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)",
                 _f713_sql(Frame713Pg, spec))
  # A frame is SQL text, never a parameter: rendering one binds nothing. A pin, not a #713 gate —
  # the unpatched code bound nothing either.
  @test isempty(inspect_query(_f713_q(Frame713Pg, spec))[:parameters])
end

# ─────────────────────────────────────────────────────────────────────────────
# #713: a frame outside the grammar is refused when `WindowOver` is called
# The refusal happens before any SQL exists, so it does not depend on which engine eventually renders
# the node — a hostile frame on a SQLite model is `InvalidValueError` too, not the capability error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#713: WindowOver refuses a frame outside the grammar" begin
  for bad in _REFUSED
    @testset "$(repr(bad))" begin
      @test_throws PormG.InvalidValueError Dialect.window_frame_sql(bad)
      @test_throws PormG.InvalidValueError WindowOver(order_by = ["positionorder"], frame = bad)
      # The keyword-only method forwards to the positional one; both are guarded.
      @test_throws PormG.InvalidValueError WindowOver(["constructorid"], ["positionorder"]; frame = bad)
    end
  end
  # `frame = nothing` still means "the SQL default frame" and renders no frame clause at all.
  @test WindowOver(order_by = ["positionorder"]).frame === nothing
  @test occursin("OVER (ORDER BY \"Tb\".\"positionorder\" ASC)",
                 _f713_sql(Frame713Pg, WindowOver(order_by = ["positionorder"])))
end

# ─────────────────────────────────────────────────────────────────────────────
# #713: the render sink refuses on its own
# `WindowSpec` is exported and mutable, and documented as assemblable by hand — so a frame can reach
# `_build_over_clause` without passing through `WindowOver`. The sink parses again, on both engines,
# and parses BEFORE the SQLite capability check so that check never echoes unparsed text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#713: _build_over_clause refuses a frame that skipped WindowOver" begin
  bad = "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS x FROM race; --"
  # Assembled directly through the `@kwdef` constructor.
  direct = WindowSpec(order_by = ["positionorder"], frame = bad)
  @test_throws PormG.InvalidValueError _f713_sql(Frame713Pg, direct)
  @test_throws PormG.InvalidValueError _f713_sql(Frame713Sl, direct)
  # Mutated after a valid `WindowOver`.
  mutated = WindowOver(order_by = ["positionorder"], frame = "ROWS 1 PRECEDING")
  mutated.frame = bad
  @test_throws PormG.InvalidValueError _f713_sql(Frame713Pg, mutated)
  # A directly-assembled VALID frame is re-spelled at the sink the same way.
  lower = WindowSpec(order_by = ["positionorder"], frame = "rows 2 preceding")
  @test occursin("ASC ROWS 2 PRECEDING)", _f713_sql(Frame713Pg, lower))
  # A valid frame on SQLite is still the capability refusal it always was, now naming PormG's spelling.
  err = try _f713_sql(Frame713Sl, lower); nothing catch e; e end
  @test err isa PormG.BackendCapabilityError
  @test occursin("\"ROWS 2 PRECEDING\"", PormG.error_message(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# #713: the refusal message is safe to log and says what is accepted
# It echoes the caller's text escaped, so a newline or a terminal sequence cannot split a log line,
# quotes only the start of a long input, and names the grammar.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#713: the refusal message is escaped, bounded and actionable" begin
  err = try WindowOver(frame = "ROWS 1 PRECEDING\e[31m\n; --"); nothing catch e; e end
  @test err isa PormG.InvalidValueError
  msg = PormG.error_message(err)
  @test !occursin('\e', msg) && !occursin('\n', msg)
  @test startswith(msg, "frame:")
  @test occursin("UNBOUNDED PRECEDING", msg) && occursin("EXCLUDE", msg)
  # The specific reason is named — here PostgreSQL's ordering rule — not just "invalid".
  err = try WindowOver(frame = "ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW"); nothing catch e; e end
  @test occursin("the frame end comes before its start", PormG.error_message(err))
  # A long input is refused by the length cap, quickly, and quoted only by its start.
  for long in ("ROWS " * repeat("1 ", 50_000) * "PRECEDING", repeat("x", 100_000))
    err = try WindowOver(frame = long); nothing catch e; e end
    @test err isa PormG.InvalidValueError
    @test length(PormG.error_message(err)) < 1000
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #713 sibling: EXTRACT_DATE no longer interpolates `locale` / `nlsparam`
# No public constructor ever set either key — `ToChar` builds `format` alone — and the text they made
# (`to_char(x, 'fmt') <locale> <nlsparam>`) was not valid PostgreSQL. A hand-built node carrying them
# now renders exactly what `ToChar` renders.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#713: EXTRACT_DATE ignores locale / nlsparam" begin
  col = "\"Tb\".\"date\""
  hostile = Dict{String,Any}("format" => "YYYY-MM", "locale" => "; DROP TABLE race; --", "nlsparam" => "OR TRUE")
  @test Dialect.EXTRACT_DATE(col, hostile, _FPG) == "to_char($(col), 'YYYY-MM')"
  @test Dialect.EXTRACT_DATE(col, hostile, _FSL) == "strftime('%Y-%m', $(col))"
end
