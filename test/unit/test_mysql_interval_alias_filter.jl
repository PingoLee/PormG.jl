using Test
using Dates
using PormG
using PormG.Models: Model, IDField, IntegerField, DurationField
using PormG.QueryBuilder: inspect_query, F, Max
using PormG.Functions: Cast, Case, When

# ─────────────────────────────────────────────────────────────────────────────
# #1456: a filter on an alias over an interval binds MySQL's microseconds, whatever spells the interval.
#
# MySQL stores a `DurationField` as a BIGINT count of microseconds (#1130), so a duration a filter
# compares with it is bound as that count. An alias over `Cast(<duration>, "interval")` bound the
# duration as its `HH:MM:SS` text instead: the function arm of `_render_interval_operand` asked the read
# kind, which names no interval for the cast. MySQL compares the BIGINT with `'00:01:00'` as the number
# 0, so `> Minute(1)` matched every positive duration — a silent wrong row set. The arm now asks the
# type walk, which names the cast, a `Case` over durations and `Max(Case(…))` an interval.
#
# MySQL only: SQLite refuses the cast (#822), and PostgreSQL binds an interval; both are pinned in the
# expression-kind matrix's bind channel.
# ─────────────────────────────────────────────────────────────────────────────
struct IntervalAliasMockMySQL <: PormG.PormGMySQL end

PormG.config["interval_alias_my"] = PormG.Configuration.Settings(connections = IntervalAliasMockMySQL(), change_data = true)

const _INTERVAL_ALIAS_RESULT = let m = Model("interval_alias_results", resultid = IDField(), grid = IntegerField(),
                                              fastestlaptime = DurationField(null = true))
  m.connect_key = "interval_alias_my"
  m
end

# The duration `Minute(1)` as MySQL stores it: sixty million microseconds.
const _ONE_MINUTE_US = 60_000_000

# ─────────────────────────────────────────────────────────────────────────────
# MySQL: every spelling of an interval alias binds the compared duration as microseconds.
# Expected: `filter("<alias>__@gt" => Minute(1))` renders `<the interval> > ?` (WHERE, or HAVING over an
# aggregate) and binds `60000000::Int64` as its last parameter, as a filter on the column itself does.
# Before #1456 the `Cast` alias bound the `String` `"00:01:00"`. Why it matters: the BIGINT compared
# with that text matches every positive duration, and nothing reports it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1456: MySQL binds a duration filter on an interval alias as microseconds" begin
  dur_case() = Case([When("grid" => 1, then = F("fastestlaptime"))])
  spellings = [
    # the column, and an aggregate over it: the binds the aliases below must match
    ("the column",          q -> q.filter("fastestlaptime__@gt" => Minute(1)), "WHERE"),
    ("Max of the column",   q -> (q.values("v" => Max("fastestlaptime")); q.filter("v__@gt" => Minute(1))), "HAVING"),
    # the defect: the read kind named no interval for these three
    ("Cast to interval",    q -> (q.values("v" => Cast("fastestlaptime", "interval")); q.filter("v__@gt" => Minute(1))), "WHERE"),
    ("Case over durations", q -> (q.values("v" => dur_case()); q.filter("v__@gt" => Minute(1))), "WHERE"),
    ("Max of that Case",    q -> (q.values("v" => Max(dur_case())); q.filter("v__@gt" => Minute(1))), "HAVING"),
  ]
  for (label, build!, clause) in spellings
    @testset "$label" begin
      q = _INTERVAL_ALIAS_RESULT.objects
      build!(q)
      insp = inspect_query(q; connection = IntervalAliasMockMySQL())
      bound = last(insp[:parameters])
      # The compared duration is the integer count of microseconds, never the `HH:MM:SS` text.
      @test bound isa Int64
      @test bound == _ONE_MINUTE_US
      @test occursin(clause, insp[:sql_text])
      @test occursin(" > ?", insp[:sql_text])
    end
  end
end
