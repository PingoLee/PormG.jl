# ─────────────────────────────────────────────────────────────────────────────
# Shared value-representation property cases (#564)
#
# The property this family keeps escaping through, stated once:
#
#     for a value `v` stored in a column of temporal kind K, and an expression `e` over that
#     column whose Julia meaning is `e_j(v)`, evaluating `e` on a REAL connection must yield the
#     same representation the column's own formatter gives `e_j(v)`.
#
# Three halves, each asserted separately because each fails on its own:
#
#   P1  render == formatter   the projected value, as text on SQLite, is byte-identical to
#                             `formatter(e_j(v))`; on PostgreSQL the typed value denotes it.
#   P2  bind == render        `filter(e(col) == e_j(v))` returns exactly the probe row, and a
#                             nudged `e_j(v)` returns none.
#   P3  read-side parity      the projected value has the same Julia type on both engines.
#
# The oracle is always Julia-side arithmetic on `v` pushed through the field's OWN formatter —
# never a spelled SQL string. `test_alignment_sqlite.jl` pins which function name a renderer
# emits; that assertion stayed green for the whole life of #527, because `datetime(...)` was
# emitted exactly as pinned and its output could still never equal a stored value. Pinning the
# spelling proves nothing about comparability. This table asserts comparability.
#
# `broken` is MEASURED, not guessed: every case starts green-by-claim, is run on both engines,
# and only the `(case, engine)` pairs that actually failed are marked — each with the #564 sibling
# it belongs to, or "new" when no sibling explains it. A `@test_broken` that passes is a Julia
# error, so this list cannot go stale silently once a renderer is fixed.
#
# Included by both `test/unit/test_value_repr_property.jl` (hermetic in-memory SQLite) and
# `test/integration/test_value_repr_property.jl` (the seeded F1 fixture, whichever engine
# `PORMG_DB` selects). No database access happens here; the runner below takes a query factory.
# ─────────────────────────────────────────────────────────────────────────────

using Test
using Dates
import TimeZones
import PormG
import PormG.Models
using PormG.QueryBuilder: F
import PormG.QueryBuilder   # `query_list` + its `Tables`, for the raw read below (no new test dependency)
using PormG.Functions: ToChar

# ── Probe values ────────────────────────────────────────────────────────────
# Milliseconds are deliberate: the canonical timestamp mask carries `.sss`, and a probe with
# `.000` would let a renderer that drops or doubles the fraction pass by coincidence.
const VR_INSTANT  = TimeZones.ZonedDateTime(2031, 7, 4, 12, 30, 45, 123, TimeZones.tz"UTC")
const VR_DATE     = Date(2031, 7, 4)
const VR_TIME     = Time(12, 30, 45, 123)
const VR_DURATION = Minute(1) + Second(49) + Millisecond(88)   # lap 1 of race 1: "1:49.088"

# ── Which formatter owns which representation ───────────────────────────────
# One table, keyed by the kind an expression EVALUATES to. `:text` and `:integer` are
# expression-only results (`ToChar`, `__@year`) with no field formatter to consult.
const VR_FORMATTER = Dict{Symbol,Function}(
  :timestamp => Models.format_timezone_sql,
  :date      => Models.format_date_sql,
  :time      => Models.format_text_sql,
  :interval  => Models.format_duration_sql,
)

# What each formatter accepts — the gate `vr_observed_text` uses before canonicalizing.
const VR_FORMATTER_INPUT = Dict{Symbol,Type}(
  :timestamp => Union{DateTime, TimeZones.ZonedDateTime},
  :date      => Union{Date, DateTime, TimeZones.ZonedDateTime},
  :time      => Time,
  :interval  => Union{Dates.Period, Dates.CompoundPeriod},
)

# The Julia type each kind is expected to READ BACK as, on either engine. PostgreSQL delivers
# these natively through the driver; SQLite delivers TEXT unless PormG coerces on the way out.
const VR_JULIA_TYPE = Dict{Symbol,Type}(
  :timestamp => Union{DateTime, TimeZones.ZonedDateTime},
  :date      => Date,
  :time      => Time,
  :interval  => Dates.AbstractTime,        # `Period` and `CompoundPeriod` both subtype it
  :text      => AbstractString,
  :integer   => Integer,
)

# A value that must NOT match, per kind — the P2 negative control.
const VR_NUDGE = Dict{Symbol,Function}(
  :timestamp => v -> v + Minute(1),
  :date      => v -> v + Day(1),
  :time      => v -> v + Minute(1),
  :interval  => v -> v + Second(1),
  :integer   => v -> v + 1,
  # No `:text` entry: the only text-valued case (`ToChar`) has no P2 today.
)

"""
    vr_expected_text(kind, value) -> String | Integer

The representation the column's own formatter gives `value` — the oracle side of P1.
"""
function vr_expected_text(kind::Symbol, value)
  kind === :integer && return Int(value)
  kind === :text && return String(value)
  return VR_FORMATTER[kind](value)
end

"""
    vr_observed_text(kind, x) -> String | Integer

The projected value, normalized for comparison. A `String` is compared AS IS — that is the
byte-identity claim on SQLite. A typed value (PostgreSQL) is pushed through the same formatter
as the oracle, so both sides canonicalize identically.

SIBLING 4 IS FIXED, AND P1 NO LONGER READS THROUGH THIS FUNCTION ON THE COERCED PATH.

The warning this paragraph used to carry came true exactly as written: the byte comparison made
P1 strong on SQLite only BECAUSE P3 was broken there, so every expression alias arrived as raw
text. Now that expression aliases are coerced, `x` on the coerced path is a `DateTime`, and
`_parse_sqlite_timestamp` accepts a `T`-separated, fraction-less string — a rendering that
dropped the `.sss` and the offset would canonicalize to the right text here and P1 would prove
nothing.

So P1 reads `vr_raw_value` instead (below): `query_list`, which is `_list_raw` minus exactly the
coercion step, and therefore the raw read DEFINED AT the seam it guards rather than approximating
it. **Do not "simplify" P1 back to `list(:dict)`** — that is the hollow version.

This function still normalizes the P1 comparison for a value that arrives typed anyway
(PostgreSQL's driver delivers one on the raw path too), and it is still the right shape for that.
"""
function vr_observed_text(kind::Symbol, x)
  x isa VRRefused && return x
  x isa AbstractString && return String(x)
  kind === :integer && return x isa Number ? Int(x) : x
  kind === :text && return x
  # Only a value the formatter ACCEPTS is canonicalized. Anything else — the integer `2031`
  # that `CAST(col AS DATE)` yields on SQLite, the `2034` numeric addition on TEXT produces — is
  # returned as is, so the comparison FAILS and names the value instead of raising inside the
  # normalizer and hiding it.
  x isa VR_FORMATTER_INPUT[kind] || return x
  return VR_FORMATTER[kind](x)
end

# ── The case table ──────────────────────────────────────────────────────────
struct VRCase
  id::String
  kind::Symbol                       # the column kind the case is rooted in
  expr::Function                     # col::String -> something `values("x" => …)` accepts
  expect::Function                   # stored value -> the Julia value the expression denotes
  result_kind::Symbol                # the kind the expression EVALUATES to
  compare_f::Bool                    # P2 through `filter(expr(col) == expect(v))`
  pair::Union{Nothing,Function}      # P2 through the pair spelling: col -> lookup key
  sibling::Union{Nothing,String}     # the #564 table row this case probes, or `nothing` (control)
  # The measured failure SHAPE, asserted plainly: `(x, engine) -> Bool`. A `@test_broken` turns any
  # exception and any `false` into Broken, so without this a harness regression (the expression
  # failing to build, a driver starting to refuse what it used to evaluate) would keep the mark
  # green-broken while the comment beside it drifted from reality.
  shape::Union{Nothing,Function}
  # Engines on which each half is MEASURED broken: P1, P2 through the F spelling, P2 through the
  # pair spelling, P3. The two P2 halves are separate because #562 is precisely the case where
  # one spelling is right and the other wrong.
  broken::NamedTuple{(:p1, :p2f, :p2pair, :p3), NTuple{4, Tuple{Vararg{Symbol}}}}
end

function vrcase(id, kind, expr, expect; result_kind = kind, compare_f = true, pair = nothing,
                sibling = nothing, shape = nothing, p1 = (), p2f = (), p2pair = (), p3 = ())
  VRCase(id, kind, expr, expect, result_kind, compare_f, pair, sibling, shape,
         (p1 = p1, p2f = p2f, p2pair = p2pair, p3 = p3))
end

# `_utc_naive` — the instant as a naive UTC `DateTime`, which is what `Dates.format` needs and
# what the stored text spells before its `+00:00`.
_vr_utc_naive(v::TimeZones.ZonedDateTime) = DateTime(TimeZones.astimezone(v, TimeZones.tz"UTC"))
_vr_utc_naive(v::DateTime) = v

const VR_CASES = VRCase[
  # ── TIMESTAMP ────────────────────────────────────────────────────────────
  # Identity: the write path and the read path agree on the column itself. P3 here is the
  # sibling-4 probe — an expression alias is never in the SQLite DateTime-coercion set, which
  # only covers aliases naming a plain column, so `values("x" => F(c))` reads back as `String`.
  vrcase("identity", :timestamp, c -> F(c), v -> v,
         sibling = "4 — FIXED: the alias is coerced by the kind it evaluates to"),
  # #527 controls: the canonical `strftime` wrapper, whole-day and sub-day.
  vrcase("plus_day",  :timestamp, c -> F(c) + Day(1),  v -> v + Day(1)),
  vrcase("minus_day", :timestamp, c -> F(c) - Day(1),  v -> v - Day(1)),
  vrcase("plus_hour", :timestamp, c -> F(c) + Hour(1), v -> v + Hour(1)),
  # Integer days — the other #527 branch, and the one #563's name collision produced.
  vrcase("plus_int_days", :timestamp, c -> F(c) + 7, v -> v + Day(7)),
  # Sibling 1, FIXED by #568. Both integer-days guards required `field_name isa String`, so a NESTED
  # left fell through to plain numeric addition on TEXT — a silent integer on SQLite, and
  # `timestamptz + bigint` (no such operator) on PostgreSQL. A bare integer is now normalized into
  # `Day(n)` and rendered by the one temporal renderer, so it composes at any depth.
  #
  # The marks are now identical to `plus_int_days` above, which is the point: the single-link and
  # nested spellings of one expression should not differ, and the only mark left is the SQLite
  # read-back (sibling 4), which every expression alias shares. The `shape` lambda is GONE rather
  # than rewritten — it recorded a measured FAILURE, and there is no longer a failure to record.
  vrcase("nested_int_days", :timestamp, c -> (F(c) + 7) + 3, v -> v + Day(10),
         sibling = "1 — fixed by #568; nested integer days compose"),
  # #494 control: a zero-length link short-circuits to the bare left side; the outer call must
  # still resolve the column's kind rather than sniff the (now absent) marker.
  vrcase("zero_link_chain", :timestamp, c -> F(c) + Day(0) + Day(1), v -> v + Day(1)),
  # Sibling 2, FIXED by #569. `sqlite_date_format_map` spelled this mask `%S.%f` — SQLite's `%f`
  # is already `SS.SSS`, so the seconds rendered twice (`…:45.45.123`) — and the PostgreSQL arm
  # passed the KEY through to `to_char`, where `TH` is the ordinal-suffix pattern, `HH` is 12-hour
  # and `SSS` is `SS` plus a literal `S` (`…THH:00:00.00S`). The map is now `date_format_map`, one
  # spelling per engine, and this row is the one `SQLITE_CANONICAL_DATETIME_MASK` derives from.
  # Every other key is measured by `vr_run_tochar_formats` below; this case stays in the table as
  # the canonical row and the P3 control for a text-valued expression.
  vrcase("tochar_canonical_mask", :timestamp, c -> ToChar(c, "YYYY-MM-DDTHH:MI:SS.SSS"),
         v -> Dates.format(_vr_utc_naive(v), "yyyy-mm-ddTHH:MM:SS.sss"),
         result_kind = :text, compare_f = false,
         sibling = "2 — fixed by #569; one spelling per engine"),
  # #562 FIXED: the `F` route used to resolve `@date` through `Dialect` into `CAST(col AS DATE)` —
  # NUMERIC affinity on SQLite text, so it yielded the integer year — while the pair route resolved
  # it through `QueryBuilder` into `strftime('%Y-%m-%d', …)`. There is one ladder now, and `@date`
  # is a named function the dialect renders per engine, so both spellings denote the same `Date`.
  vrcase("at_date_f", :timestamp, c -> F("$(c)__@date"), v -> Date(_vr_utc_naive(v)),
         result_kind = :date, pair = c -> "$(c)__@date",
         # P3 is still broken on SQLite, and it is a DIFFERENT defect from the one #562 fixed: the
         # value is right (`'2031-07-04'`, agreeing with the string spelling) but arrives as TEXT,
         # because `build_query.jl` records a projection kind only for a plain path — a FUNCTION
         # projection deliberately answers `nothing`, so the read path leaves it as the driver
         # delivered it. On SQLite `strftime` delivers text; PostgreSQL's `(col)::date` delivers a
         # real `Date`, which is why the mark is one-sided. Typing function projections belongs to
         # #564's read table, not to the ladder.
         shape = (x, engine) -> engine === :sqlite ? x isa AbstractString : x isa Date,
         p3 = (:sqlite,)),
  # New finding (P3): `EXTRACT(YEAR FROM …)` is `numeric` on PostgreSQL ≥ 14, delivered as a
  # `Decimal`; SQLite's `CAST(strftime('%Y', …) AS INTEGER)` is an `Int`. Same value, two types.
  vrcase("at_year_f", :timestamp, c -> F("$(c)__@year"), v -> year(_vr_utc_naive(v)),
         result_kind = :integer, p3 = (:postgres,)),
  # ── DATE ─────────────────────────────────────────────────────────────────
  # `date(...)` == `format_date_sql` is asserted only in a comment today (`Dialect.jl:83`); this
  # is that claim as a measurement.
  vrcase("identity", :date, c -> F(c), v -> v),
  # P3 on PostgreSQL: `date + interval` is a `timestamp` in SQL, so a whole-day shift reads back
  # as a `DateTime` there and as `YYYY-MM-DD` text (a date) on SQLite. P1 and P2 hold on both —
  # PormG binds the calendar date and PostgreSQL coerces — so this is the "sub-day-only
  # promotion is discontinuous" item from the #564 design review, measured: the two engines
  # give the expression different TYPES for the same whole-day arithmetic.
  vrcase("plus_day", :date, c -> F(c) + Day(1), v -> v + Day(1), p3 = (:postgres,)),
  vrcase("plus_int_days", :date, c -> F(c) + 7, v -> v + Day(7), p3 = (:postgres,)),
  # Sibling 1's DATE branch, fixed by #568 alongside the timestamp one. Marks match `plus_int_days`
  # above: SQLite reads the alias back as text (sibling 4), and PostgreSQL returns a `DateTime`
  # because `date + interval` is a `timestamp` in SQL — the promotion split tracked as #572, which
  # this change deliberately does not touch.
  vrcase("nested_int_days", :date, c -> (F(c) + 7) + 3, v -> v + Day(10),
         sibling = "1 — fixed by #568; nested integer days compose (date branch)",
         p3 = (:postgres,)),
  # #527 control: a sub-day duration on a DATE column promotes to a timestamp on both engines.
  vrcase("plus_hour6", :date, c -> F(c) + Hour(6), v -> DateTime(v) + Hour(6),
         result_kind = :timestamp),
  # #562 FIXED, on a DATE column: same collapse, and the same one-sided P3 remainder as the
  # TIMESTAMP case above — a function projection carries no kind for the read path to undo.
  vrcase("at_date_f", :date, c -> F("$(c)__@date"), v -> v, pair = c -> "$(c)__@date",
         shape = (x, engine) -> engine === :sqlite ? x isa AbstractString : x isa Date,
         p3 = (:sqlite,)),
  vrcase("at_year_f", :date, c -> F("$(c)__@year"), v -> year(v), result_kind = :integer,
         p3 = (:postgres,)),
  # ── TIME ─────────────────────────────────────────────────────────────────
  # `TimeField` has no dedicated formatter — it rides `format_text_sql(::Time)` — and no SQL
  # canonicalizer or read-side parser at all. `F(time) ± duration` raises `InvalidValueError`
  # by design (a duration only applies to a DATE/TIMESTAMP column), so identity is the whole
  # surface.
  vrcase("identity", :time, c -> F(c), v -> v),
  # ── INTERVAL ─────────────────────────────────────────────────────────────
  # `DurationField` writes `HH:MM:SS.sss` through `format_duration_sql`; identity plus the pair
  # spelling is the whole surface (no arithmetic, no transforms).
  vrcase("identity", :interval, c -> F(c), v -> v, compare_f = false, pair = c -> c),
]

# A rendered expression the engine REFUSED. Carried as a value so the comparison below fails (or
# is recorded broken) with the engine's message, instead of the exception escaping the testset:
# PostgreSQL rejects `timestamptz + bigint` where SQLite silently adds the integer to the text,
# and both answers belong in the same table.
struct VRRefused
  message::String
end
Base.show(io::IO, r::VRRefused) = print(io, "VRRefused(", repr(r.message), ")")
# Two identically-refused ladder routes must NOT count as agreeing, so refusal never equals
# refusal. Against any other right-hand side Base's `===` fallback already answers `false`; a
# `(::VRRefused, ::Any)` pair would only add an ambiguity with `missing`.
Base.:(==)(::VRRefused, ::VRRefused) = false

_vr_try(f) = try
  f()
catch e
  (e isa InterruptException || e isa StackOverflowError) && rethrow()
  VRRefused(sprint(showerror, e))
end

# ── The raw read (#564, sibling 4) ────────────────────────────────────────────
"""
    vr_raw_value(q, key) -> the driver's value, BEFORE the read-side coercion

P1 asks whether the RENDERED expression produces the representation the column's own formatter
produces. Once PormG coerces temporal aliases on the way out, `list(:dict)` can no longer answer
that: it would hand back a value PormG had already parsed and re-canonicalized, and a rendering
that dropped the fraction and the offset would survive the round trip unnoticed.

`_list_raw` is literally `query_list` plus that coercion, so reading `query_list` is the raw read
DEFINED AT the seam it guards, not an approximation of it — it cannot drift away from what
`_list_raw` does, because it is the thing `_list_raw` is built on.

Not `Cast(…, "TEXT")`, which was the obvious candidate and does not work: on PostgreSQL
`(x)::TEXT` yields PostgreSQL's own session-timezone rendering (`2031-07-04 12:30:45.123+00`),
not `format_timezone_sql`'s canonical form, so every currently-green PostgreSQL timestamp case
would start failing. Not `DataFrame(q)` either: it is uncoerced by ACCIDENT rather than by
contract, and the day that divergence is closed P1 would go hollow a second time with no mark to
force the visit.

On PostgreSQL this is a provable no-op — `value_parser` answers `nothing` for every kind there, so
the coerced and raw paths return the same object.
"""
function vr_raw_value(q, key::Symbol)
  rows = QueryBuilder.Tables.rowtable(QueryBuilder.query_list(q)) |> collect
  length(rows) == 1 || return VRRefused("expected one row, got $(length(rows))")
  return getproperty(rows[1], key)
end

# ── Runner ───────────────────────────────────────────────────────────────────
"""
    vr_run_cases(base, col, stored, engine; kind)

Run every case of `kind` against the probe row. `base()` must return a FRESH query already
filtered to exactly one row whose `col` holds `stored`; `engine` is `:sqlite` or `:postgres`.
"""
function vr_run_cases(base::Function, col::String, stored, engine::Symbol; kind::Symbol)
  engine in (:sqlite, :postgres) || throw(ArgumentError("engine must be :sqlite or :postgres"))
  for case in filter(c -> c.kind === kind, VR_CASES)
    @testset "$(kind) · $(case.id)" begin
      expected_value = case.expect(stored)

      # P1 — render == formatter, read RAW (#564): before PormG's own read-side coercion, so the
      # claim is about what the ENGINE produced and not about what PormG then parsed it into.
      q = base()
      q.values("x" => case.expr(col))
      raw = _vr_try(() -> vr_raw_value(q, :x))
      observed = vr_observed_text(case.result_kind, raw)
      expected = vr_expected_text(case.result_kind, expected_value)
      if engine in case.broken.p1
        @test_broken observed == expected
      else
        @test observed == expected
      end
      # The measured failure shape, where one is recorded — a plain `@test`, so it cannot drift.
      # Also on the RAW value: every recorded shape (`x isa Integer`, `x isa VRRefused`) is a
      # statement about what the engine returned, not about what PormG made of it.
      case.shape === nothing || @test case.shape(raw, engine)

      # P3 — read-side type parity, on the COERCED path, which is the one a user sees.
      qc = base()
      qc.values("x" => case.expr(col))
      rows = _vr_try(() -> qc.list(:dict))
      x = rows isa VRRefused ? rows : (length(rows) == 1 ? rows[1][:x] : VRRefused("expected one row, got $(length(rows))"))
      T = VR_JULIA_TYPE[case.result_kind]
      if engine in case.broken.p3
        @test_broken x isa T
      else
        @test x isa T
      end

      # P2 — bind == render, through the F spelling…
      if case.compare_f
        hit = base()
        hit.filter(case.expr(col) == expected_value)
        miss = base()
        miss.filter(case.expr(col) == VR_NUDGE[case.result_kind](expected_value))
        n_hit  = _vr_try(hit.count)
        n_miss = _vr_try(miss.count)
        if engine in case.broken.p2f
          @test_broken n_hit == 1 && n_miss == 0
        else
          @test n_hit == 1
          @test n_miss == 0
        end
      end
      # …and through the pair spelling, where one exists.
      if case.pair !== nothing
        key = case.pair(col)
        hit = base()
        hit.filter(key => expected_value)
        miss = base()
        miss.filter(key => VR_NUDGE[case.result_kind](expected_value))
        n_hit  = _vr_try(hit.count)
        n_miss = _vr_try(miss.count)
        if engine in case.broken.p2pair
          @test_broken n_hit == 1 && n_miss == 0
        else
          @test n_hit == 1
          @test n_miss == 0
        end
      end
    end
  end
end

# ── ToChar formats (#569) ─────────────────────────────────────────────────────
# `date_format_map` (`src/constants.jl`) carries one spelling per engine for every portable
# `ToChar` format, and its contract is that both spellings evaluate to the SAME text for a fixed
# instant. Neither half had ever been evaluated on its engine before #569 — the rendering tests
# pinned a spelling, and a pinned spelling proves nothing about what the engine makes of it (the
# `%S.%f` mask sat green in a render pin for the whole life of the map).
#
# The oracle is Julia's own `Dates.format` over the stored instant — a third source, neither the
# map nor the engine. `HH` is 24-hour here on purpose: that is what the SQLite `%H` half always
# meant, so the PostgreSQL half must say `HH24` to agree with it.
#
# Every key of the map MUST have a row here (asserted below), so a key cannot be added with an
# unverified half. And every row here must be a key, so the oracle cannot drift past the map.
const VR_TOCHAR_ORACLE = Dict{String,String}(
  "YYYY" => "yyyy",
  "MM"   => "mm",
  "DD"   => "dd",
  "HH"   => "HH",
  "MI"   => "MM",
  "SS"   => "SS",
  "YYYY-MM-DD" => "yyyy-mm-dd",
  "YYYY-MM"    => "yyyy-mm",
  "YYYY-MM-DD HH:MI:SS"     => "yyyy-mm-dd HH:MM:SS",
  "YYYY-MM-DD HH:MI:SS.SSS" => "yyyy-mm-dd HH:MM:SS.sss",
  "YYYY-MM-DDTHH:MI:SS"     => "yyyy-mm-ddTHH:MM:SS",
  "YYYY-MM-DDTHH:MI:SS.SSS" => "yyyy-mm-ddTHH:MM:SS.sss",
  "HH:MI:SS"     => "HH:MM:SS",
  "HH:MI:SS.SSS" => "HH:MM:SS.sss",
  "HH:MI"        => "HH:MM",
  "DD/MM/YYYY" => "dd/mm/yyyy",
  "DD-MM-YYYY" => "dd-mm-yyyy",
)

"""
    vr_run_tochar_formats(base, col, stored, engine)

Evaluate `ToChar(col, key)` on the live engine for EVERY key of `date_format_map` and compare the
text the engine produced to `Dates.format` of the stored instant through the oracle above. `base()`
must return a fresh query filtered to exactly one row whose `col` holds `stored`, a timestamp.

Read raw (`vr_raw_value`), for the same reason P1 is: the claim is about what the ENGINE rendered,
not about what PormG then parsed it into.
"""
function vr_run_tochar_formats(base::Function, col::String, stored, engine::Symbol)
  engine in (:sqlite, :postgres) || throw(ArgumentError("engine must be :sqlite or :postgres"))
  # The two tables name the same keys — a map row without an oracle, or an oracle row without a
  # map entry, is a hole in this measurement and fails here rather than being skipped.
  @test Set(keys(VR_TOCHAR_ORACLE)) == Set(keys(PormG.date_format_map))
  naive = _vr_utc_naive(stored)
  for key in sort(collect(keys(PormG.date_format_map)))
    @testset "ToChar · $(key)" begin
      q = base()
      q.values("x" => ToChar(col, key))
      raw = _vr_try(() -> vr_raw_value(q, :x))
      # A refusal fails with the engine's message in the assertion, never as an escaped exception.
      @test vr_observed_text(:text, raw) == Dates.format(naive, VR_TOCHAR_ORACLE[key])
    end
  end
end

# ── Ladder parity (#562) ──────────────────────────────────────────────────────
# `PormGtransform` is resolved by TWO ladders — `_check_function(::Vector{String})` into
# `QueryBuilder`'s constructors, and the `contains(v, "@")` branch into `Dialect` — and they are
# reached by different spellings of the same transform. Both must project the same value.
#
# #562 collapsed the two ladders into one: the `F` spelling now delegates into
# `_check_function`, so both routes build the same node and no transform can drift again. The
# marks below are kept as an empty record on purpose — the loop is the guard, and an entry added
# here would be a measurement, not a waiver.
#
# Every transform now denotes something this table can name. `quarter` and `quadrimester` were
# parity-only while one spelling yielded `'YYYY-Qn'` text and the other an integer — #579 settled
# that: the plain names extract the period number, and the label moved to `@yyyy_q` / `@yyyy_quad`.
const VR_LADDER_ORACLE = Dict{String,Function}(
  "date"    => v -> Date(_vr_utc_naive(v)),
  "year"    => v -> year(_vr_utc_naive(v)),
  "month"   => v -> month(_vr_utc_naive(v)),
  "day"     => v -> day(_vr_utc_naive(v)),
  "yyyy_mm" => v -> Dates.format(_vr_utc_naive(v), "yyyy-mm"),
  # #579: the period NUMBER, not the label. Quarters are 3 months, quadrimesters 4 — the same
  # arithmetic the dialect renders, restated from the calendar rather than from the SQL.
  "quarter"      => v -> cld(month(_vr_utc_naive(v)), 3),
  "quadrimester" => v -> cld(month(_vr_utc_naive(v)), 4),
  # …and the year-qualified labels those two used to be. Both spell the separator `-Q`; that
  # collision predates #579, which moved the expansion without touching it.
  "yyyy_q"    => v -> string(year(_vr_utc_naive(v)), "-Q", cld(month(_vr_utc_naive(v)), 3)),
  "yyyy_quad" => v -> string(year(_vr_utc_naive(v)), "-Q", cld(month(_vr_utc_naive(v)), 4)),
)

# Per engine: which transforms DISAGREE between the two spellings (parity), and for which the `F`
# spelling is also WRONG against the oracle. Both were populated before #562 — `date`, `quarter`
# and `quadrimester` on both engines for parity, and `date` on SQLite for the oracle, where
# `CAST(col AS DATE)` delivered the integer 2031. One ladder resolves all of them now, so both
# tables are empty and every transform is asserted plainly.
const VR_LADDER_BROKEN = Dict{String,Tuple{Vararg{Symbol}}}()
const VR_LADDER_ORACLE_BROKEN = Dict{String,Tuple{Vararg{Symbol}}}()

"""
    vr_run_ladder_parity(base, col, stored, engine)

For every `PormGtransform` key, project `F("col__@key")` (the `Dialect` ladder) and
`"col__@key"` (the `QueryBuilder` ladder) and assert the two agree — and, where an oracle
exists, that both equal it.
"""
function vr_run_ladder_parity(base::Function, col::String, stored, engine::Symbol)
  for key in sort!(collect(keys(PormG.PormGtransform)))
    @testset "ladder parity · @$(key)" begin
      via_f = base(); via_f.values("x" => F("$(col)__@$(key)"))
      via_s = base(); via_s.values("x" => "$(col)__@$(key)")
      xf = _vr_try(() -> via_f.list(:dict)[1][:x])
      xs = _vr_try(() -> via_s.list(:dict)[1][:x])
      broken = engine in get(VR_LADDER_BROKEN, key, ())
      if broken
        @test_broken isequal(xf, xs)
      else
        @test isequal(xf, xs)
      end
      if haskey(VR_LADDER_ORACLE, key)
        oracle = VR_LADDER_ORACLE[key](stored)
        norm(x) = x isa AbstractString ? x : (x isa Number ? Int(x) : x)
        want = oracle isa Date ? string(oracle) : (oracle isa Number ? Int(oracle) : oracle)
        # A `Date` oracle is compared as text on both engines — SQLite delivers text, and the
        # PostgreSQL `to_char` path does too, while `(col)::date` delivers a `Date`.
        got_f = xf isa Date ? string(xf) : norm(xf)
        got_s = xs isa Date ? string(xs) : norm(xs)
        # The `F` route (the `Dialect` ladder) is the one that can be wrong; the string route is
        # the reference and is always asserted plainly.
        if engine in get(VR_LADDER_ORACLE_BROKEN, key, ())
          @test_broken got_f == want
        else
          @test got_f == want
        end
        @test got_s == want
      end
    end
  end
end
