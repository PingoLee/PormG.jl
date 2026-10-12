"""
#1183 — a pattern lookup (`@contains`, `@startswith`, …) on a time, timestamp, duration, boolean or
binary column, and the number shapes #1168 did not reach.

Since #1086 the value of a pattern lookup is a text fragment on every column, but the operand was read
as text only for the kinds `_pattern_text_kind` named; every other one rendered a bare `LIKE`, which
PostgreSQL rejects for a `time`, `timestamptz`, `interval` or `boolean` while SQLite matched the text it
stored. Each kind is now decided by whether the two engines print the same text:

- a time prints `HH:MM:SS[.f]`, trailing zeros dropped, on both, so it reads as that text —
  `CAST(col AS text)` on PostgreSQL, the column itself on SQLite;
- a timestamp (PostgreSQL's session zone against SQLite's UTC text), a duration (`IntervalStyle`
  against `26:00:00`) and a boolean (`true` against `1`) do not, and a binary column holds bytes, so
  each is refused with `FilterError` on both engines;
- an alias with no formatter — a `Case` without `output_field`, a `Value`, arithmetic over a date part —
  is decided by its kind, like #1168's number columns: an integer reads as its digits, a float is
  refused.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_pattern_temporal_column.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, F, Q, Subquery, OuterRef
using PormG.Functions: Max, Sum, Cast, Case, When, Value
using Dates

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct PtcMockSQLite <: PormG.PormGSQLite end
struct PtcMockPostgres <: PormG.PormGPostgres end
const _PTC_SL = PtcMockSQLite()
const _PTC_PG = PtcMockPostgres()
PormG.backend_sqlite_version(::PtcMockSQLite) = 3045000

PormG.config["ptc_mock"] = PormG.Configuration.Settings(
  connections = _PTC_SL, change_data = true, db_def_folder = "ptc_mock",
)

# The F1 race shape, with one column of each kind the issue names, plus an integer and a float for the
# number-shape arms and a date for the date-part arithmetic.
module PtcModels
import PormG
import PormG.Models

Ptc_race = Models.Model("ptc_race",
  raceid   = Models.IDField(),
  round    = Models.IntegerField(),
  date     = Models.DateField(null = true),
  time     = Models.TimeField(null = true),
  start_at = Models.DateTimeField(null = true),
  duration = Models.DurationField(null = true),
  sprint   = Models.BooleanField(default = false),
  snapshot = Models.BinaryField(null = true),
  speed    = Models.FloatField(null = true),
)

# A pit stop, one relation hop from the race, for the joined-path arm.
Ptc_pit = Models.Model("ptc_pit",
  pitid    = Models.IDField(),
  raceid   = Models.ForeignKey(Ptc_race, pk_field = "raceid", on_delete = "CASCADE"),
  duration = Models.DurationField(null = true),
)

PormG.Models.set_models(@__MODULE__, "ptc_mock")
end

const PTC = PtcModels
const _PTC_BACKENDS = (("PostgreSQL", _PTC_PG), ("SQLite", _PTC_SL))

_ptc_inspect(f, conn) = inspect_query((q = PTC.Ptc_race.objects; f(q); q); connection = conn)
_ptc_sql(f, conn)     = _ptc_inspect(f, conn)[:sql_text]
_ptc_params(f, conn)  = _ptc_inspect(f, conn)[:parameters]
_ptc_refusal(f, conn) = try _ptc_sql(f, conn); nothing catch e; e end

# The text a pattern lookup reads from `col` on each engine.
_ptc_read(col, conn) = conn isa PormG.PormGPostgres ? "CAST($(col) AS text)" : col

# ─────────────────────────────────────────────────────────────────────────────
# A time column reads as its text on both engines. PostgreSQL prints a `time` as `HH:MM:SS[.f]` with
# the fraction's trailing zeros dropped under every DateStyle — the text Julia's `string(::Time)`
# writes on SQLite — so the fragment matches the same rows. Before #1183 PostgreSQL got
# `"Tb"."time" LIKE $1`, a server error (no `LIKE` for `time`). Expected SQL on PostgreSQL:
# `CAST("Tb"."time" AS text) LIKE $1 ESCAPE '\'`; on SQLite the column as written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1183: a pattern lookup on a time column reads its text" begin
  for (backend, conn) in _PTC_BACKENDS
    @testset "$backend" begin
      read = _ptc_read("\"Tb\".\"time\"", conn)
      @test occursin("WHERE $(read) LIKE ", _ptc_sql(q -> q.filter("time__@startswith" => "14:"), conn))
      @test _ptc_params(q -> q.filter("time__@startswith" => "14:"), conn) == ["14:%"]
      @test occursin("$(read) NOT LIKE ", _ptc_sql(q -> q.filter("time__@ncontains" => ":30"), conn))
      @test occursin(read, _ptc_sql(q -> q.filter("time__@iendswith" => "00"), conn))
      @test occursin(read, _ptc_sql(q -> q.filter("time__@iexact" => "14:00:00"), conn))
      conn isa PormG.PormGPostgres &&
        @test occursin("$(read) ~ ", _ptc_sql(q -> q.filter("time__@regex" => "^14"), conn))
      # An aggregate alias over a time column takes the same read, in HAVING.
      sql = _ptc_sql(q -> (q.values("round", "t" => Max("time")); q.filter("t__@startswith" => "14")), conn)
      @test occursin("HAVING " * _ptc_read("MAX(\"Tb\".\"time\")", conn) * " LIKE ", sql)
      # A non-pattern lookup still compares the time itself: no cast.
      sql = _ptc_sql(q -> q.filter("time" => Time(14)), conn)
      @test occursin("\"Tb\".\"time\" = ", sql)
      @test !occursin("CAST", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A timestamp, a duration, a boolean and a binary column are refused on both engines, with
# `FilterError`. Their text differs per engine (a timestamp's zone and separator, an interval's style,
# `true` against `1`), and a binary column holds bytes, so one fragment would select different rows.
# Before #1183 PostgreSQL failed at the server and SQLite matched its stored text. The refusal names
# the column, what it is, and the explicit spelling; it never quotes the value (#971).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1183: a pattern lookup on a timestamp, duration, boolean or binary column is refused" begin
  cases = (("start_at", "a timestamp", "__@date__@startswith"),
           ("duration", "a duration", "Dates.Period"),
           ("sprint",   "a boolean", "=> true"),
           ("snapshot", "a BinaryField, which holds bytes", "Compare it whole"))
  for (backend, conn) in _PTC_BACKENDS
    @testset "$backend" begin
      for (col, what, instead) in cases, op in ("contains", "startswith", "nicontains", "iexact")
        e = _ptc_refusal(q -> q.filter("$(col)__@$(op)" => "2009-03-29"), conn)
        @test e isa PormG.FilterError
        msg = sprint(showerror, e)
        @test occursin("'$(col)'", msg)
        @test occursin("this is $(what)", msg)
        @test occursin(instead, msg)
        @test occursin("#1183", msg)
        @test !occursin("2009-03-29", msg)
        # The engine's own text is the explicit spelling for a timestamp and a duration. A boolean's
        # text cast is itself refused on SQLite (#1028), so its spelling is the text written out with
        # a `Case`; bytes have no text to name.
        @test occursin("Cast(", msg) == (col in ("start_at", "duration"))
        @test occursin("Case([When(", msg) == (col == "sprint")
      end
      # A comparison on the same columns still builds: only the pattern lookups are refused.
      @test occursin("\"Tb\".\"start_at\" >= ", _ptc_sql(q -> q.filter("start_at__@gte" => DateTime(2009)), conn))
      @test occursin("\"Tb\".\"sprint\" = ", _ptc_sql(q -> q.filter("sprint" => true), conn))
      @test occursin("\"Tb\".\"snapshot\" IS NULL", _ptc_sql(q -> q.filter("snapshot__@isnull" => true), conn))
      # A transform over a timestamp is the explicit spelling the message names, and builds: `@date`
      # reads its `YYYY-MM-DD` text (#1086).
      @test occursin("LIKE", _ptc_sql(q -> q.filter("start_at__@date__@startswith" => "2009-03"), conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# An alias over one of those kinds is refused the same way, in HAVING and in WHERE: a `Max` over a
# timestamp, a `Value(true)` and a `Cast` to boolean. The alias has no field; its formatter, or its
# expression's kind where it has no formatter, is what names the type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1183: an alias over a timestamp or a boolean is refused" begin
  for (backend, conn) in _PTC_BACKENDS
    @testset "$backend" begin
      for (alias, expr) in (("m", Max("start_at")), ("v", Value(true)), ("c", Cast("round", "boolean")))
        e = _ptc_refusal(q -> (q.values("round", alias => expr); q.filter("$(alias)__@startswith" => "t")), conn)
        @test e isa PormG.FilterError
        @test occursin("'$(alias)'", sprint(showerror, e))
        @test occursin("#1183", sprint(showerror, e))
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The other routes to the same operand take the same rule (found in review): a joined path, a `Q`, a
# `Subquery` alias, a HAVING alias over an interval `Sum`, and a `When` condition inside `values()`.
# Each reaches `_pattern_operand` from a different caller, so each is pinned on its own. `@regex` on
# SQLite is refused as a pattern on a refused kind before the missing feature is named; on a time
# column, which reads as text, the feature refusal is what remains.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1183: a joined path, Q, Subquery, interval Sum and When take the same rule" begin
  sub(agg) = Subquery(PTC.Ptc_race.objects.filter("raceid" => OuterRef("raceid")).values("m" => agg))
  for (backend, conn) in _PTC_BACKENDS
    @testset "$backend" begin
      pit(f) = inspect_query((q = PTC.Ptc_pit.objects; f(q); q); connection = conn)[:sql_text]
      e = try pit(q -> q.filter("raceid__start_at__@startswith" => "2009")); nothing catch err; err end
      @test e isa PormG.FilterError
      @test occursin("raceid__start_at", sprint(showerror, e))
      sql = pit(q -> q.filter("raceid__time__@startswith" => "14"))
      @test occursin(_ptc_read("\"Tb_1\".\"time\"", conn) * " LIKE ", sql)

      sql = _ptc_sql(q -> q.filter(Q("time__@startswith" => "14")), conn)
      @test occursin(_ptc_read("\"Tb\".\"time\"", conn) * " LIKE ", sql)
      @test _ptc_refusal(q -> q.filter(Q("start_at__@startswith" => "2009")), conn) isa PormG.FilterError

      for agg in (Max("start_at"), Max("sprint"))
        e = _ptc_refusal(q -> (q.values("raceid", "s" => sub(agg)); q.filter("s__@startswith" => "1")), conn)
        @test e isa PormG.FilterError
      end
      sql = _ptc_sql(q -> (q.values("raceid", "s" => sub(Max("time"))); q.filter("s__@startswith" => "14")), conn)
      @test occursin(conn isa PormG.PormGPostgres ? r"WHERE CAST\(\(SELECT\s.*\) AS text\) LIKE"s : r"\) LIKE \?"s, sql)

      e = _ptc_refusal(q -> (q.values("round", "d" => Sum("duration")); q.filter("d__@contains" => "1")), conn)
      @test e isa PormG.FilterError
      @test occursin("a duration", sprint(showerror, e))

      e = _ptc_refusal(q -> q.values("raceid", "w" => Case([When("start_at__@startswith" => "2009", then = 1)], default = 0)), conn)
      @test e isa PormG.FilterError

      if conn isa PormG.PormGSQLite
        @test _ptc_refusal(q -> q.filter("start_at__@iregex" => "^20"), conn) isa PormG.FilterError
        @test _ptc_refusal(q -> q.filter("time__@regex" => "^14"), conn) isa PormG.BackendCapabilityError
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The number shapes #1168 left as written, now decided by their kind. An integer `Case` alias with no
# `output_field`, a `Value(1)` alias and arithmetic over a date part read as their digits —
# `CAST(… AS text)` on PostgreSQL, where they were a bare `LIKE` and a server error. A `Case` with a
# float default and a `Value(2.5)` are refused on both engines, as a float column is (#1168).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1183: a Case, Value or date-part arithmetic alias reads or refuses by its kind" begin
  for (backend, conn) in _PTC_BACKENDS
    @testset "$backend" begin
      int_case = Case([When("round" => 1, then = 1)], default = 0)
      for (alias, expr, rendered) in (
          ("c", int_case, r"CASE\s.*END"s),
          ("v", Value(1), conn isa PormG.PormGPostgres ? r"\$\d+::bigint" : r"\?"),
          ("y", F("date__@year") + 1, r"\(.*date.*\)"))
        f = q -> (q.values("raceid", alias => expr); q.filter("$(alias)__@startswith" => "1"))
        sql = _ptc_sql(f, conn)
        where = sql[findfirst("WHERE ", sql).stop+1:end]
        if conn isa PormG.PormGPostgres
          @test startswith(where, "CAST(")
          @test occursin(r"AS text\) LIKE \$\d+ ESCAPE"s, where)
        else
          @test !occursin("AS text", where)
          @test occursin(r"LIKE \? ESCAPE"s, where)
        end
        @test occursin(rendered, where)
        @test last(_ptc_params(f, conn)) == "1%"
      end
      for (alias, expr) in (("c", Case([When("round" => 1, then = 1)], default = Value(2.5))), ("v", Value(2.5)))
        e = _ptc_refusal(q -> (q.values("raceid", alias => expr); q.filter("$(alias)__@startswith" => "1")), conn)
        @test e isa PormG.FilterError
        @test occursin("not an integer", sprint(showerror, e))
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A `When` condition inside `values()` on a CTE column takes the rule a `filter()` on the same path
# does. Before #1183 the condition rendered `"R1_1"."best" LIKE $1` on PostgreSQL whatever the CTE
# column held: an integer one now reads as its digits, a float one is refused on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1183: a When on a CTE column inside values() reads or refuses like filter()" begin
  with_best(q, agg) = q.with("best" => PTC.Ptc_race.objects.values("raceid", "best" => agg),
                             join_field = "raceid" => "raceid", join_type = "INNER")
  cond = Case([When("best__best__@contains" => "1", then = 1)], default = 0)
  for (backend, conn) in _PTC_BACKENDS
    @testset "$backend" begin
      sql = _ptc_sql(q -> (with_best(q, Max("round")); q.values("raceid", "w" => cond)), conn)
      @test occursin("WHEN " * _ptc_read("\"R1_1\".\"best\"", conn) * " LIKE ", sql)
      e = _ptc_refusal(q -> (with_best(q, Max("speed")); q.values("raceid", "w" => cond)), conn)
      @test e isa PormG.FilterError
      @test occursin("not an integer", sprint(showerror, e))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The classifier itself: the formatter decides where it names a type, the kind decides the rest. A
# time column's formatter is `format_text_sql`, a `CharField`'s, so only its kind says it is a time —
# and a text operand of unknown kind stays as written (a mutant reading `nothing` as anything else
# would cast or refuse every `CharField` pattern lookup).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1183: _pattern_text_kind decides by formatter, then by kind" begin
  QB = PormG.QueryBuilder
  M = PormG.Models
  @test QB._pattern_text_kind(M.format_text_sql; kind = QB.CTime()) === :time
  @test QB._pattern_text_kind(M.format_text_sql; kind = nothing) === nothing
  @test QB._pattern_text_kind(M.format_text_sql; kind = QB.CText()) === nothing
  @test QB._pattern_text_kind(M.format_timezone_sql) === :timestamp
  @test QB._pattern_text_kind(M.format_duration_sql) === :interval
  @test QB._pattern_text_kind(M.format_bool_sql) === :boolean
  @test QB._pattern_text_kind(M.format_binary_sql) === :binary
  @test QB._pattern_text_kind(nothing; kind = QB.CDateTime(true)) === :timestamp
  @test QB._pattern_text_kind(nothing; kind = QB.CInterval()) === :interval
  @test QB._pattern_text_kind(nothing; kind = QB.CBool()) === :boolean
  @test QB._pattern_text_kind(nothing; kind = QB.CBytes()) === :binary
  @test QB._pattern_text_kind(nothing; kind = QB.CInt64()) === :integer
  @test QB._pattern_text_kind(nothing; kind = QB.CFloat64()) === :inexact_number
  @test QB._pattern_text_kind(nothing; kind = QB.CDate()) === :date
  @test QB._pattern_text_kind(nothing; kind = nothing) === nothing
end
