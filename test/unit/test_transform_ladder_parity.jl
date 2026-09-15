"""
`PormGtransform` resolves through ONE ladder (#562).

`__@date`, `__@year`, `__@month`, `__@day`, `__@yyyy_mm`, `__@quarter`, `__@quadrimester` and the
year-qualified `__@yyyy_q` / `__@yyyy_quad` can each be reached by two spellings that used to take
two different code paths:

  q.values("x" => "created_at__@date")     # the string spelling
  q.values("x" => F("created_at__@date"))  # the F / update-expression spelling

The first resolved the name with `getfield(@__MODULE__, …)` into `QueryBuilder`'s own constructors;
the second resolved the SAME `PormGtransform` entry with `getfield(Dialect, …)` and string-concatenated
the result. Both read one table and emitted different SQL — and for `@date` on SQLite one of them was
not merely different but wrong: `CAST(col AS DATE)` applies NUMERIC affinity, so
`'2026-04-07T21:30:23'` came back as the integer `2026`, projected and compared, silently.

Four of the seven transforms agreed through either ladder, which is exactly what made this hard to
notice — so the guard here is deliberately NOT a list of hand-written expectations. It iterates
`PormGtransform` itself: a transform added to one ladder only fails this file by construction, and so
does a transform whose two spellings drift apart later.

Everything renders through mock connections — no live database, no fixture.

julia --project=. test/unit/test_transform_ladder_parity.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct TlpMockSQLite <: PormG.PormGSQLite end
struct TlpMockPostgres <: PormG.PormGPostgres end
const _TLP_SL = TlpMockSQLite()
const _TLP_PG = TlpMockPostgres()
PormG.backend_sqlite_version(::TlpMockSQLite) = 3045000

PormG.config["tlp_mock"] = PormG.Configuration.Settings(
  connections = _TLP_SL, change_data = true, db_def_folder = "tlp_mock",
)

# Both temporal column kinds. The distinction matters here: the #352/#373 sargable rewrite only
# fires on a plain `DateField`, so `seen` and `ts` exercise different filter paths for the same
# transform while sharing the projection path.
module TlpModels
import PormG
import PormG.Models

Tlp_row = Models.Model("tlp_row",
  id   = Models.IDField(),
  seen = Models.DateField(null = true),
  ts   = Models.DateTimeField(null = true),
  note = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "tlp_mock")
end

const TLP = TlpModels

_tlp_sql(q; conn)    = inspect_query(q; connection = conn)[:sql_text]
_tlp_params(q; conn) = inspect_query(q; connection = conn)[:parameters]

const _TLP_BACKENDS = (("PostgreSQL", _TLP_PG), ("SQLite", _TLP_SL))

# The projection through each spelling, aliased identically so only the EXPRESSION can differ.
_tlp_string_route(col, key, conn) =
  _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => "$(col)__@$(key)"); q); conn = conn)
_tlp_f_route(col, key, conn) =
  _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => F("$(col)__@$(key)")); q); conn = conn)

# ─────────────────────────────────────────────────────────────────────────────
# One ladder: every `PormGtransform` key renders identically through both spellings (#562).
# Iterating the constant rather than a hand-written list is the point — this is the test the issue
# asks for, the one that fails when a future transform is wired into only one of the two routes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: both spellings of a transform render the same SQL" begin
  for (backend, conn) in _TLP_BACKENDS
    for key in sort(collect(keys(PormG.PormGtransform)))
      for col in ("seen", "ts")
        string_sql = _tlp_string_route(col, key, conn)
        f_sql      = _tlp_f_route(col, key, conn)
        @test string_sql == f_sql
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `@date` on SQLite: a date, not the year (#562).
# The regression that motivated the collapse. `CAST(col AS DATE)` is valid SQLite that returns the
# WRONG VALUE — `DATE` carries no affinity keyword, so NUMERIC affinity turns the stored text into
# the leading integer. Both halves are asserted: the correct call is present and the CAST spelling
# is absent, because a test for only the first would pass against a render that emitted both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: @date renders strftime on SQLite, never CAST(... AS DATE)" begin
  for col in ("seen", "ts")
    for sql in (_tlp_string_route(col, "date", _TLP_SL), _tlp_f_route(col, "date", _TLP_SL))
      @test occursin("strftime('%Y-%m-%d', \"Tb\".\"$(col)\")", sql)
      @test !occursin("AS DATE", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `@date` on PostgreSQL: the real cast, on both spellings (#562).
# PostgreSQL HAS a `date` type, so the engine-correct rendering differs from SQLite's — which is
# why `@date` is a named function rather than a `to_char` mask. The string spelling used to render
# `to_char(col, 'YYYY-MM-DD')`, i.e. text; it now yields a `date` like the `F` spelling always did.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: @date renders a real cast on PostgreSQL" begin
  for col in ("seen", "ts")
    for sql in (_tlp_string_route(col, "date", _TLP_PG), _tlp_f_route(col, "date", _TLP_PG))
      @test occursin("(\"Tb\".\"$(col)\")::date", sql)
      @test !occursin("to_char", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Regression controls: the four transforms that already agreed must still render as they did.
# These are quoted literally rather than derived, so a change of rendering shows up here as a
# failing expectation instead of silently satisfying the parity loop above — parity alone is
# satisfied by BOTH ladders drifting together.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: the four transforms that already agreed are unchanged" begin
  expected = Dict(
    (:sqlite, "year")    => "CAST(strftime('%Y', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "month")   => "CAST(strftime('%m', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "day")     => "CAST(strftime('%d', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "yyyy_mm") => "strftime('%Y-%m', \"Tb\".\"ts\")",
    (:postgres, "year")    => "EXTRACT(YEAR FROM \"Tb\".\"ts\")",
    (:postgres, "month")   => "EXTRACT(MONTH FROM \"Tb\".\"ts\")",
    (:postgres, "day")     => "EXTRACT(DAY FROM \"Tb\".\"ts\")",
    (:postgres, "yyyy_mm") => "to_char(\"Tb\".\"ts\", 'YYYY-MM')",
  )
  for (engine, conn) in ((:sqlite, _TLP_SL), (:postgres, _TLP_PG))
    for key in ("year", "month", "day", "yyyy_mm")
      want = expected[(engine, key)]
      @test occursin(want, _tlp_string_route("ts", key, conn))
      @test occursin(want, _tlp_f_route("ts", key, conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The sargable date-range rewrite still recognises `@date` (#562 × #352/#373).
# `@date` stopped being a `ToChar` node carrying a `"YYYY-MM-DD"` mask and became a named `DATE`
# function, so the bucket matcher in `_render_sargable_date_range` had to move with it. This is the
# one part of the collapse no correctness assertion can catch: on a plain `DateField` the rewrite
# DROPS the transform, so a stale matcher renders correct-but-unindexable SQL, silently — the #376
# failure mode. The rewrite is asserted by its shape (bare column, no function call) and the
# `DateTimeField` control proves the gate still excludes timestamps.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#562: @date still collapses to a bare-column comparison on a DateField" begin
  for (backend, conn) in _TLP_BACKENDS
    q = TLP.Tlp_row.objects
    q.values("note")
    q.filter("seen__@date" => "1991-10-27")
    sql = _tlp_sql(q; conn = conn)
    # The rewrite dropped the transform: the comparison is on the raw column.
    @test occursin("\"Tb\".\"seen\" = ", sql)
    @test !occursin("strftime", sql)
    @test !occursin("::date", sql)

    # The control: a TIMESTAMP column is deliberately excluded from the rewrite, so the transform
    # is still rendered there. If this ever renders bare too, the DATE-only gate has been widened.
    q2 = TLP.Tlp_row.objects
    q2.values("note")
    q2.filter("ts__@date" => "1991-10-27")
    sql2 = _tlp_sql(q2; conn = conn)
    @test occursin(conn === _TLP_SL ? "strftime('%Y-%m-%d'" : "::date", sql2)
  end
end
