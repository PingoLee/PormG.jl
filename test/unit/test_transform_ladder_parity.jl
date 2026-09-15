"""
`PormGtransform`: one ladder per key (#562), and one meaning per key (#579).

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

The second half of the file is #579: `@quarter` and `@quadrimester` denote the period NUMBER, the
year-qualified label lives under `@yyyy_q` / `@yyyy_quad`, and both number keys validate their
right-hand side. Before that split one name meant two things depending on where it appeared, so the
documented `filter("date__@quarter" => 1)` compared the integer `1` against the string `'1985-Q1'`
and matched nothing — silently, with a wrong-typed value accepted just as quietly.

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

# ─────────────────────────────────────────────────────────────────────────────
# `@quarter` / `@quadrimester` extract the period number (#579).
# The documented contract in `api.md`, `read/filters_and_aggregates.md` and
# `read/functions_and_dates.md` has always said "Extract quarter (1-4)" and shown `=> 1` as the
# filter value. The implementation rendered `CONCAT(year, '-Q', CASE …)`, so the predicate compared
# a string to an integer: valid SQL, zero rows, no error. Both the projection and the predicate are
# asserted, because it is the PREDICATE that was unusable and the projection that hid it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#579: @quarter and @quadrimester denote a number, in both positions" begin
  numeric = Dict(
    (:sqlite, "quarter")        => "((strftime('%m', \"Tb\".\"ts\") - 1) / 3) + 1",
    (:sqlite, "quadrimester")   => "((strftime('%m', \"Tb\".\"ts\") - 1) / 4) + 1",
    (:postgres, "quarter")      => "EXTRACT(QUARTER FROM \"Tb\".\"ts\")",
    (:postgres, "quadrimester") => "CEIL(EXTRACT(MONTH FROM \"Tb\".\"ts\") / 4.0)",
  )
  for (engine, conn) in ((:sqlite, _TLP_SL), (:postgres, _TLP_PG))
    for key in ("quarter", "quadrimester")
      want = numeric[(engine, key)]
      # Projected, through both spellings.
      @test occursin(want, _tlp_string_route("ts", key, conn))
      @test occursin(want, _tlp_f_route("ts", key, conn))
      # And in a predicate — the half that could never match. The label expansion is absent and the
      # bound parameter is the documented scalar, not nine `CASE` operands plus it.
      q = TLP.Tlp_row.objects
      q.values("note")
      q.filter("ts__@$(key)" => 1)
      @test occursin(want, _tlp_sql(q; conn = conn))
      @test !occursin("CASE", _tlp_sql(q; conn = conn))
      @test _tlp_params(q; conn = conn) == [1]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The year-qualified label kept its rendering, under its own name (#579).
# `@yyyy_q` / `@yyyy_quad` carry the `Concat`/`Case` expansion `@quarter` used to be, byte for byte
# — the split is a rename of the label half, not a redesign of it. `@yyyy_quad` still spells its
# separator `-Q`, sharing it with `@yyyy_q`; that predates #579 and is deliberately left alone here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#579: @yyyy_q and @yyyy_quad carry the year-qualified label" begin
  for (backend, conn) in _TLP_BACKENDS
    for key in ("yyyy_q", "yyyy_quad")
      sql = _tlp_string_route("ts", key, conn)
      # The expansion: a year cast, the literal separator as a bound parameter, and a CASE ladder.
      @test occursin("CASE", sql)
      @test occursin("-Q", string(_tlp_params((q = TLP.Tlp_row.objects; q.values("x" => "ts__@$(key)"); q); conn = conn)))
      @test occursin(conn === _TLP_SL ? "strftime('%Y'" : "EXTRACT(YEAR FROM", sql)
    end
    # Four branches for quarters, three for quadrimesters — the two are not the same expansion.
    n_branch(key) = count("WHEN", _tlp_string_route("ts", key, conn))
    @test n_branch("yyyy_q") == 4
    @test n_branch("yyyy_quad") == 3
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The right-hand side of a period comparison is validated (#579).
# The `Concat` node carried no formatter, so `filter("date__@quarter" => "abc")` bound the string
# and returned nothing. Naming the function let a formatter be attached; the range check follows
# `@year`'s precedent of refusing a value no bucket can express rather than building SQL that
# silently matches nothing. The type is `InvalidValueError`, matching the sibling `@month`/`@day`
# formatters exactly — #576 owns moving that whole family to `FilterError`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#579: a value no period can express is refused, not bound" begin
  for (backend, conn) in _TLP_BACKENDS
    for (key, over) in (("quarter", 5), ("quadrimester", 4))
      # Not a number at all.
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => "abc"); q); conn = conn)
      # A number, but outside the period range — the case a plain numeric formatter would accept
      # and then match nothing with.
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => over); q); conn = conn)
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => 0); q); conn = conn)
      # The in-range values all build.
      for v in 1:(key == "quarter" ? 4 : 3)
        @test _tlp_params(
          (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => v); q); conn = conn) == [v]
      end
      # And through `__@in`, which binds a collection: the range check has to reach INSIDE it, or a
      # list containing an impossible period is accepted one element at a time. The two engines
      # bind `IN` differently — SQLite expands `IN (?, ?)` with flat parameters, PostgreSQL renders
      # `= ANY($1)` with one array parameter — so the expected shape is engine-specific here. That
      # divergence predates #579 and is shared verbatim with the sibling `@month` / `@day`.
      @test _tlp_params(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [1, 2]); q);
        conn = conn) == (conn === _TLP_SL ? [1, 2] : [[1, 2]])
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [1, over]); q); conn = conn)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The label transforms are projection-only, and the docs say so (#586, #587).
# Two pre-existing parameter defects become reachable through a documented spelling once `@yyyy_q`
# and `@yyyy_quad` exist, so they are pinned here rather than left as prose in a warning box. Both
# reproduce identically on the pre-#579 tree under the old `@quarter` spelling — neither is a
# regression — but a doc claim with no test is how the claim rots.
#
# Written as `@test_broken`, following `helper_value_repr_cases.jl`: a `@test_broken` that PASSES is
# a Julia error, so these cannot go stale silently once #586/#587 land. Each one states the CORRECT
# behaviour, so the assertion itself documents the contract instead of the symptom.
#
# The two engines fail differently, and asserting the same thing on both is how this testset would
# pass for the wrong reason. SQLite's `?` is positional at BIND time, so its criterion is the COUNT.
# PostgreSQL numbers `$n` at RENDER time, so its counts always agree — measured, 19 params and
# `max($n) == 19` — and its criterion is whether the `$n` sequence is CONTIGUOUS: the discarded
# render consumes `$10..$18`, which appear nowhere in the text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#586/#587: a parameter-binding transform is projection-only, as documented" begin
  _sqlite_placeholders(sql) = count("?", sql)
  _pg_refs(sql) = sort(unique(parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", sql)))

  for (backend, conn) in _TLP_BACKENDS
    # The control, and it is a real one: a PROJECTION of the same label binds exactly what the text
    # references, on both engines. Asserted first so nothing below reads as "labels are broken".
    proj = TLP.Tlp_row.objects
    proj.values("x" => "ts__@yyyy_q")
    proj_sql = _tlp_sql(proj; conn = conn)
    proj_params = _tlp_params(proj; conn = conn)
    if conn === _TLP_SL
      @test _sqlite_placeholders(proj_sql) == length(proj_params)
    else
      @test _pg_refs(proj_sql) == collect(1:length(proj_params))
    end

    # #586 — a PREDICATE renders the expansion twice and keeps both sets of parameters.
    for key in ("yyyy_q", "yyyy_quad")
      q = TLP.Tlp_row.objects
      q.values("note")
      q.filter("ts__@$(key)" => "1991-Q1")
      sql = _tlp_sql(q; conn = conn)
      params = _tlp_params(q; conn = conn)
      if conn === _TLP_SL
        @test_broken length(params) == _sqlite_placeholders(sql)
      else
        ns = _pg_refs(sql)
        # PostgreSQL's own arithmetic is satisfied — this is NOT the defect, and asserting a count
        # here would make the PG arm green for a reason PostgreSQL does not care about.
        @test maximum(ns) == length(params)
        # The defect is the gap the discarded render leaves behind.
        @test_broken ns == collect(1:maximum(ns))
      end
    end

    # #587 — ORDER BY renders under the `:join` context, which flushes BEFORE `where`, while the text
    # order is the reverse. SQLite ONLY; PostgreSQL is the control and is genuinely correct.
    # The whole vector is asserted, not its ends: pinning `params[1]`/`params[end]` would still pass
    # a fix that reordered the middle, and would break spuriously if anything ever bound after the
    # WHERE value (a LIMIT operand).
    q = TLP.Tlp_row.objects
    q.values("note")
    q.filter("note" => "x")
    q.order_by("ts__@yyyy_q")
    params = _tlp_params(q; conn = conn)
    # Text order: the WHERE placeholder comes first, then the nine ordering operands.
    in_text_order = Any["x", "-Q", 3, 1, 6, 2, 9, 3, 12, 4]
    if conn === _TLP_SL
      @test_broken params == in_text_order
      # …and what it actually binds today: the WHERE value last, so the predicate receives the
      # separator "-Q" and the ordering expression receives "x". Wrong rows, no error.
      @test params == Any["-Q", 3, 1, 6, 2, 9, 3, 12, 4, "x"]
    else
      @test params == in_text_order
    end
  end
end
