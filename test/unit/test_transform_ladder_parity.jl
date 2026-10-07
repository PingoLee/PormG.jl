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

julia --project=test/integration test/unit/test_transform_ladder_parity.jl
"""

using Test
using Dates
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

# The transforms the parity loops run over this model's date and time columns: every
# `PormGtransform` key but `@len` (#28), which counts an ArrayField's elements and refuses a date
# column by design — there is no date row for it to agree on. Its two-spelling parity is asserted on
# an array column, in `test_array_lookups.jl`. Still computed from the registry, so a new date
# transform joins the loops by itself.
const _TLP_DATE_TRANSFORMS = sort(filter(!=("len"), collect(keys(PormG.PormGtransform))))

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
    for key in _TLP_DATE_TRANSFORMS
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
    # #571: the PostgreSQL arms cast `::integer` so the read-back type matches SQLite's `Int`.
    (:postgres, "year")    => "EXTRACT(YEAR FROM \"Tb\".\"ts\")::integer",
    (:postgres, "month")   => "EXTRACT(MONTH FROM \"Tb\".\"ts\")::integer",
    (:postgres, "day")     => "EXTRACT(DAY FROM \"Tb\".\"ts\")::integer",
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
    (:postgres, "quarter")      => "EXTRACT(QUARTER FROM \"Tb\".\"ts\")::integer",   # #571 cast
    (:postgres, "quadrimester") => "CEIL(EXTRACT(MONTH FROM \"Tb\".\"ts\") / 4.0)::integer",
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
# silently matches nothing. The type WAS `InvalidValueError`, matching the sibling `@month`/`@day`
# formatters exactly, and this comment named #576 as the issue that would move the whole family to
# `FilterError`. #576 has landed and it did: `format_quarter_sql` still raises `InvalidValueError`,
# but the filter path converted it, so what a CALLER saw was `FilterError`. #971 moved it back: a
# refused value is an `InvalidValueError` on the filter path too, located on the transform. The
# refusal itself — the whole point of #579 — is unchanged, which is why only the type moved below.
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
# The time-part transforms (#636).
# `@hour` / `@minute` / `@second` reuse `Dialect.EXTRACT`, so the rendering is quoted literally here
# for the same reason as #562's controls above: the parity loops iterate `PormGtransform` and would be
# satisfied by both ladders rendering the wrong part together. `SECOND` is the one whose PostgreSQL
# arm differs from the rest — `trunc` first, because `numeric::integer` ROUNDS (45.6 → 46) where
# SQLite's `%S` truncates. Range refusal follows #579: a value no clock can show is refused (an
# `InvalidValueError` since #971),
# never a bound parameter that silently matches nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#636: the time-part transforms render and validate on both engines" begin
  expected = Dict(
    (:sqlite, "hour")   => "CAST(strftime('%H', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "minute") => "CAST(strftime('%M', \"Tb\".\"ts\") AS INTEGER)",
    (:sqlite, "second") => "CAST(strftime('%S', \"Tb\".\"ts\") AS INTEGER)",
    (:postgres, "hour")   => "EXTRACT(HOUR FROM \"Tb\".\"ts\")::integer",
    (:postgres, "minute") => "EXTRACT(MINUTE FROM \"Tb\".\"ts\")::integer",
    (:postgres, "second") => "trunc(EXTRACT(SECOND FROM \"Tb\".\"ts\"))::integer",
  )
  for (engine, conn) in ((:sqlite, _TLP_SL), (:postgres, _TLP_PG))
    for key in ("hour", "minute", "second")
      want = expected[(engine, key)]
      @test occursin(want, _tlp_string_route("ts", key, conn))
      @test occursin(want, _tlp_f_route("ts", key, conn))
    end
  end

  for (backend, conn) in _TLP_BACKENDS
    for (key, hi) in (("hour", 23), ("minute", 59), ("second", 59))
      build(v) = (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)" => v); q)
      # Out of range on either side, fractional, and not a number at all.
      for bad in (hi + 1, -1, 1.5, "abc")
        @test_throws PormG.InvalidValueError _tlp_sql(build(bad); conn = conn)
      end
      # Both ends of the range bind, as integers.
      @test _tlp_params(build(0); conn = conn) == [0]
      @test _tlp_params(build(hi); conn = conn) == [hi]
      # The check reaches inside a collection (same engine-specific `IN` shape as #579 above).
      @test _tlp_params(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [0, hi]); q);
        conn = conn) == (conn === _TLP_SL ? [0, hi] : [[0, hi]])
      @test_throws PormG.InvalidValueError _tlp_sql(
        (q = TLP.Tlp_row.objects; q.values("note"); q.filter("ts__@$(key)__@in" => [0, hi + 1]); q); conn = conn)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The label transforms bind correctly in every position (#586, #587).
# Two pre-existing parameter defects became reachable through a documented spelling once `@yyyy_q`
# and `@yyyy_quad` existed — a predicate rendered the expansion twice and kept both sets of
# parameters (#586); ORDER BY filed its parameters in a bucket that flattened before WHERE (#587).
# Both were pinned here as `@test_broken` while the docs carried a "projection-only" warning; the
# assertions below are the same statements, now expected to hold, so the contract is pinned rather
# than the symptom.
#
# The two engines failed differently, and asserting the same thing on both is how this testset would
# pass for the wrong reason. SQLite's `?` is positional at BIND time, so its criterion is the COUNT.
# PostgreSQL numbers `$n` at RENDER time, so its counts always agreed — 19 params and
# `max($n) == 19` — and its criterion is whether the `$n` sequence is CONTIGUOUS: the discarded
# render consumed `$10..$18`, which appeared nowhere in the text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#586/#587: a parameter-binding transform binds once, in text position" begin
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

    # #586 — a PREDICATE used to render the expansion twice and keep both sets of parameters. Now
    # the left-hand side renders once: the operands, then the comparison value, on both engines.
    for key in ("yyyy_q", "yyyy_quad")
      q = TLP.Tlp_row.objects
      q.values("note")
      q.filter("ts__@$(key)" => "1991-Q1")
      sql = _tlp_sql(q; conn = conn)
      params = _tlp_params(q; conn = conn)
      @test params[end] == "1991-Q1"
      if conn === _TLP_SL
        @test length(params) == _sqlite_placeholders(sql)
      else
        ns = _pg_refs(sql)
        # PostgreSQL's own arithmetic was always satisfied — this is NOT the defect, and asserting
        # only a count here would make the PG arm green for a reason PostgreSQL does not care about.
        @test maximum(ns) == length(params)
        # The defect was the gap the discarded render left behind.
        @test ns == collect(1:maximum(ns))
      end
    end

    # #587 — ORDER BY used to render under the `:join` context, which flushes BEFORE `where`, while
    # the text order is the reverse. It has its own `:order` bucket now (flattened last), so the
    # SQLite vector matches the text; PostgreSQL was always correct and is the control.
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
    # Both engines now agree; before #587 SQLite bound `["-Q", 3, …, 4, "x"]` — the WHERE value
    # last, so the predicate received the separator "-Q" and the ordering expression received "x".
    @test params == in_text_order
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #843: a transform in a function's STRING operand goes up the same ladder
# `Coalesce`, `Greatest`, `Least`, `NullIf`, `Power`, `Mod` and `Replace`'s column take their
# operands through `_function_operand`, which wrapped a string as `SQLField(x)`. The walk returns an
# `SQLField` untouched, so `Coalesce("ts__@date", "seen")` sent `__@date` to join resolution as a
# column and the build died ("does not have a 'how' property") — while `Max("ts__@date")` and
# `Coalesce(F("ts__@date"), "seen")` worked. Same shape as the #562 test above: iterate the
# constant, and require the string spelling to render exactly what the `F` spelling renders, SQL
# and parameters both, on each engine.
# ─────────────────────────────────────────────────────────────────────────────
const _TLP_843_CTORS = (
  ("Coalesce", op -> PormG.Functions.Coalesce(op, "seen")),
  ("Greatest", op -> PormG.Functions.Greatest(op, "seen")),
  ("Least",    op -> PormG.Functions.Least(op, "seen")),
  ("NullIf",   op -> PormG.Functions.NullIf(op, "seen")),
  ("Power",    op -> PormG.Functions.Power(op, 2)),
  ("Mod",      op -> PormG.Functions.Mod(op, 4)),
  ("Replace",  op -> PormG.Functions.Replace(op, "-", "/")),
)

@testset "#843: a transform in a function's string operand renders like its F spelling" begin
  for (backend, conn) in _TLP_BACKENDS, (name, ctor) in _TLP_843_CTORS
    for key in _TLP_DATE_TRANSFORMS, col in ("seen", "ts")
      path = "$(col)__@$(key)"
      a = TLP.Tlp_row.objects; a.values("x" => ctor(path))
      b = TLP.Tlp_row.objects; b.values("x" => ctor(F(path)))
      ia = inspect_query(a; connection = conn)
      ib = inspect_query(b; connection = conn)
      @test ia[:sql_text] == ib[:sql_text]
      @test ia[:parameters] == ib[:parameters]
    end
  end
  # The issue's own query, spelled out: the transform renders, the plain path stays a column.
  sql = _tlp_sql((q = TLP.Tlp_row.objects; q.values("c" => PormG.Functions.Coalesce("ts__@date", "seen")); q);
                 conn = _TLP_SL)
  @test occursin("COALESCE(strftime('%Y-%m-%d', \"Tb\".\"ts\"), \"Tb\".\"seen\")", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #843 controls: what a bare string operand must still do
# Storing the operand as a bare string hands it to the same walk every other string path takes,
# so three things are pinned. A CTE path (`"ev__seen"`) still resolves to the CTE column, as
# `CTE("ev", "seen")` does. A suffix that is an OPERATOR, not a transform, is refused with
# `FilterError` rather than reaching the join resolver. And a filter on the projection's alias
# binds the compared date exactly as the `F` spelling does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#843 controls: CTE paths, operator suffixes and alias filters" begin
  # A CTE column through the string path and through the explicit handle: one query.
  for (backend, conn) in _TLP_BACKENDS
    ev() = (c = TLP.Tlp_row.objects; c.values("id", "seen"); c)
    a = TLP.Tlp_row.objects
    a.with("ev" => ev(), join_field = "id" => "id")
    a.values("x" => PormG.Functions.Coalesce("ev__seen", "seen"))
    b = TLP.Tlp_row.objects
    b.with("ev" => ev(), join_field = "id" => "id")
    b.values("x" => PormG.Functions.Coalesce(CTE("ev", "seen"), "seen"))
    @test _tlp_sql(a; conn = conn) == _tlp_sql(b; conn = conn)
  end

  # `@gt` is an operator: in a function operand it is the ladder's FilterError, not a join crash.
  q = TLP.Tlp_row.objects
  @test_throws PormG.FilterError q.values("x" => PormG.Functions.Coalesce("ts__@gt", "seen"))

  # Filtering on the alias binds the same date, through either spelling.
  for (backend, conn) in _TLP_BACKENDS
    a = TLP.Tlp_row.objects
    a.values("c" => PormG.Functions.Coalesce("ts__@date", "seen"))
    a.filter("c__@gte" => Date(2020, 1, 1))
    b = TLP.Tlp_row.objects
    b.values("c" => PormG.Functions.Coalesce(F("ts__@date"), "seen"))
    b.filter("c__@gte" => Date(2020, 1, 1))
    @test _tlp_sql(a; conn = conn) == _tlp_sql(b; conn = conn)
    @test _tlp_params(a; conn = conn) == _tlp_params(b; conn = conn)
  end

  # The caller's handle is not rewritten by the build (#508). The walk resolves the transform into a
  # `DATE` node; before the operand list was copied, that node was written back into `h.column`.
  # The `h.column` assertion is the gate. The second is a control: the old write was idempotent, so
  # the reused handle rendered the same SQL either way, and it must keep doing so.
  h = PormG.Functions.Coalesce("ts__@date", "seen")
  sqls = map(_TLP_BACKENDS) do (backend, conn)
    _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => h); q); conn = conn)
  end
  @test h.column == Any["ts__@date", "seen"]
  @test sqls[1] == _tlp_sql((q = TLP.Tlp_row.objects; q.values("x" => h); q); conn = _TLP_PG)
end

# ─────────────────────────────────────────────────────────────────────────────
# #863: a transform resolves in a function wherever the function sits, not only in values(...)
# `_check_function` was the only walker that resolves `"col__@transform"`, it walked a function's
# `column` only, and only `values(...)` called it. So a transform inside a function on a filter's
# right-hand side, in a Case/When branch, in F arithmetic, in a window's `partition_by`, in a
# `Lag` default or in an `update` SET value reached join resolution as a column name, and the build
# died ("does not have a 'how' property"). Same oracle as #843: every position, with the string
# spelling and with the `F(path)` spelling, renders the same SQL and binds the same parameters.
# `yyyy_q` binds parameters of its own, which pins their order in each position.
# ─────────────────────────────────────────────────────────────────────────────
const _TLP_863_POSITIONS = let QB = PormG.QueryBuilder, Fn = PormG.Functions
  (
    ("filter right-hand side", (q, op) -> q.filter("seen__@gte" => Fn.Coalesce(op, "seen"))),
    ("Q right-hand side",      (q, op) -> q.filter(QB.Q("seen__@gte" => Fn.Coalesce(op, "seen")))),
    ("When condition",         (q, op) -> q.values("c" => Fn.Case([Fn.When("seen__@gte" => Fn.Coalesce(op, "seen"), then = 1)], default = 0))),
    ("Case then and default",  (q, op) -> q.values("c" => Fn.Case([Fn.When("id" => 1, then = Fn.Coalesce(op, "seen"))], default = Fn.Coalesce(op, "seen")))),
    ("When otherwise",         (q, op) -> q.values("c" => Fn.When("id" => 1, then = 1, otherwise = Fn.Coalesce(op, 0)))),
    ("then = Greatest (#844)", (q, op) -> q.values("c" => Fn.Case([Fn.When("id" => 1, then = Fn.Greatest(op, "seen"))]))),
    ("F arithmetic operand",   (q, op) -> q.values("x" => F("id") + Fn.Coalesce(op, 0))),
    ("F arithmetic filter",    (q, op) -> q.filter((F("id") + Fn.Coalesce(op, 0)) > 5)),
    ("window partition_by",    (q, op) -> q.values("id", "r" => QB.Rank(over = QB.WindowOver(partition_by = [Fn.Coalesce(op, 0)], order_by = ["id"])))),
    ("Lag default",            (q, op) -> q.values("id", "l" => QB.Lag("seen", default = Fn.Coalesce(op, "seen"), over = QB.WindowOver(order_by = ["id"])))),
  )
end

@testset "#863: a transform in a function resolves in every position, like its F spelling" begin
  for (backend, conn) in _TLP_BACKENDS, (label, position) in _TLP_863_POSITIONS
    @testset "$backend — $label" begin
      for key in ("date", "year", "yyyy_q"), col in ("seen", "ts")
        path = "$(col)__@$(key)"
        a = TLP.Tlp_row.objects; position(a, path)
        b = TLP.Tlp_row.objects; position(b, F(path))
        ia = inspect_query(a; connection = conn)
        ib = inspect_query(b; connection = conn)
        @test ia[:sql_text] == ib[:sql_text]
        @test ia[:parameters] == ib[:parameters]
      end
    end
  end

  # `Max(…) - Min(…)`: the expression is the arithmetic's LEFT side (`field_name`), not its operand.
  for (backend, conn) in _TLP_BACKENDS
    q = TLP.Tlp_row.objects
    q.values("span" => PormG.QueryBuilder.Max("ts__@year") - PormG.QueryBuilder.Min("ts__@year"))
    @test occursin(backend == "SQLite" ? "MAX(CAST(strftime('%Y', \"Tb\".\"ts\") AS INTEGER))" :
                                         "MAX(EXTRACT(YEAR FROM \"Tb\".\"ts\")::integer)", _tlp_sql(q; conn = conn))
  end

  # The issue's own query, and an `update` SET value (SQLite: `update` renders on the model's own
  # connection, which is this file's SQLite mock).
  # #895: the issue's query compared a plain column with `Max(…)` in WHERE, which both engines reject
  # and #895 now refuses at build time. The transform inside the aggregate is the thing pinned here,
  # so it is asked in the position where an aggregate on the right is legal: against an aggregate
  # alias, in HAVING.
  sql = _tlp_sql((q = TLP.Tlp_row.objects; q.values("id", "last_seen" => PormG.QueryBuilder.Max("seen"));
                  q.filter("last_seen__@gte" => PormG.QueryBuilder.Max("ts__@date")); q);
                 conn = _TLP_SL)
  @test occursin("HAVING MAX(\"Tb\".\"seen\") >= MAX(strftime('%Y-%m-%d', \"Tb\".\"ts\"))", sql)
  q = TLP.Tlp_row.objects
  q.filter("id" => 1)
  upd = q.update("seen" => PormG.Functions.Coalesce("ts__@date", "seen"), show_query = :dict)
  @test occursin("SET \"seen\" = COALESCE(strftime('%Y-%m-%d', \"Tb\".\"ts\"), \"Tb\".\"seen\")", upd[:sql_text])

  # An operator suffix in the operand is the ladder's FilterError, raised by filter() itself.
  q = TLP.Tlp_row.objects
  @test_throws PormG.FilterError q.filter("seen" => PormG.Functions.Coalesce("ts__@gt", "seen"))

  # A subquery operand is already resolved: these two died with a MethodError naming the walker.
  for (backend, conn) in _TLP_BACKENDS
    inner() = (i = TLP.Tlp_row.objects; i.filter("id" => PormG.QueryBuilder.OuterRef("id")); i)
    q = TLP.Tlp_row.objects
    q.values("id", "c" => PormG.Functions.Case([PormG.Functions.When(PormG.QueryBuilder.Q(PormG.QueryBuilder.Exists(inner())), then = 1)], default = 0))
    @test occursin("EXISTS", _tlp_sql(q; conn = conn))
    s = inner(); s.values("seen")
    q = TLP.Tlp_row.objects
    q.values("id", "g" => PormG.Functions.Greatest(PormG.QueryBuilder.Subquery(s), "seen"))
    @test occursin("SELECT", _tlp_sql(q; conn = conn))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #863: the walk constructs — a handle the caller still holds is never rewritten (#508)
# Every newly walked slot is a place a user's own node sits: a branch, a partition entry, an
# arithmetic operand, a right-hand side. The walk resolves into NEW nodes; the handles keep their
# unresolved `"ts__@…"` operand across two builds, and a shared WindowSpec is not written into.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#863: walked slots leave the caller's handles untouched" begin
  Fn = PormG.Functions; QB = PormG.QueryBuilder
  branch = Fn.Coalesce("ts__@date", "seen")
  case = Fn.Case([Fn.When("id" => 1, then = branch)])
  part = Fn.Coalesce("ts__@year", 0)
  spec = QB.WindowOver(partition_by = [part], order_by = ["id"])
  arith = F("id") + Fn.Coalesce("ts__@year", 0)
  rhs = Fn.Coalesce("ts__@date", "seen")
  for (backend, conn) in _TLP_BACKENDS, _ in 1:2
    q = TLP.Tlp_row.objects
    q.values("id", "c" => case, "r" => QB.Rank(over = spec), "x" => arith)
    q.filter("seen__@gte" => rhs)
    _tlp_sql(q; conn = conn)
  end
  @test branch.column[1] == "ts__@date"
  @test case.column[1].kwargs["then"] === branch
  @test part.column[1] == "ts__@year"
  @test spec.partition_by[1] === part
  @test arith.operand.column[1] == "ts__@year"
  @test rhs.column[1] == "ts__@date"
end

# ─────────────────────────────────────────────────────────────────────────────
# #863: every entry point that STORES a filter node walks it
# A filter node handed over directly — F arithmetic compared with a value, or an `OP` — is stored by
# eight call sites, and each one used to push it raw: `Q`, `Qor`, `push!` on both, `.on`, `.cjoin`,
# `.cjoin_on`, and `filter`. A pair whose right-hand side is F arithmetic takes its own method too.
# Each site is driven here with the string spelling and the `F(path)` spelling of the same transform,
# so a site that stops walking crashes the string spelling ("does not have a 'how' property") and
# fails this testset. A results/drivers pair supplies the relation the join entry points need.
# ─────────────────────────────────────────────────────────────────────────────
module TlpJoinModels
import PormG
import PormG.Models
Tlp_driver = Models.Model("tlp_driver", id = Models.IDField(), surname = Models.CharField(null = true),
  dob = Models.DateField(null = true))
Tlp_result = Models.Model("tlp_result", id = Models.IDField(),
  driver = Models.ForeignKey(Tlp_driver, on_delete = "CASCADE", related_name = "tlp_results", null = true),
  points = Models.IntegerField(null = true), grid = Models.IntegerField(null = true),
  ts = Models.DateTimeField(null = true))
PormG.Models.set_models(@__MODULE__, "tlp_mock")
end

@testset "#863: every entry point that stores a filter node walks it" begin
  QB = PormG.QueryBuilder; Fn = PormG.Functions; J = TlpJoinModels
  # The arithmetic node over the result's own `ts`, and over the joined driver's `dob`.
  node(op) = (F("id") + Fn.Coalesce(op, 0)) > 5
  entry_points = (
    ("filter",     "ts",  (q, op) -> q.filter(node(op))),
    ("Q",          "ts",  (q, op) -> q.filter(QB.Q("grid" => 1, node(op)))),
    ("Qor",        "ts",  (q, op) -> q.filter(QB.Qor("grid" => 1, node(op)))),
    ("push! Q",    "ts",  (q, op) -> (c = QB.Q("grid" => 1); push!(c, node(op)); q.filter(c))),
    ("push! Qor",  "ts",  (q, op) -> (c = QB.Qor("grid" => 1); push!(c, node(op)); q.filter(c))),
    ("cjoin_on",   "ts",  (q, op) -> q.cjoin_on("Tlp_driver", alias = "d", on = [Joined("d", "id") == F("driver"), node(op)])),
    # A pair whose right-hand side is F arithmetic (`_get_pair_to_oper(::SQLTypeF)`), both branches.
    ("pair F rhs, suffix", "ts", (q, op) -> q.filter("points__@gt" => F("id") + Fn.Coalesce(op, 0))),
    ("pair F rhs, =",      "ts", (q, op) -> q.filter("points" => F("id") + Fn.Coalesce(op, 0))),
    # A hand-built `OP` whose value is a function (`_check_function(::SQLTypeOper)` walks `values`).
    ("OP value",   "ts",  (q, op) -> q.filter(QB.OP("points", ">", Fn.Coalesce(op, 0)))),
  )
  for (backend, conn) in _TLP_BACKENDS, (label, col, entry!) in entry_points
    @testset "$backend — $label" begin
      path = "$(col)__@year"
      a = J.Tlp_result.objects; entry!(a, path)
      b = J.Tlp_result.objects; entry!(b, F(path))
      ia = inspect_query(a; connection = conn)
      ib = inspect_query(b; connection = conn)
      @test ia[:sql_text] == ib[:sql_text]
      @test ia[:parameters] == ib[:parameters]
    end
  end

  # `.on` and `.cjoin`: an F-arithmetic node goes through their join prefixer, which refuses it
  # whatever its operands, so they are driven with a hand-built `OP` node — stored by the same push
  # site — whose column is the joined model's and whose VALUE is the function to walk.
  op_node(op) = QB.OP("id", ">", Fn.Coalesce(op, 0))   # `id` is the joined driver's; the value is not prefixed
  joins = (
    ("on",    (q, op) -> (q.on("driver", op_node(op)); q.values("id", "driver__surname"))),
    ("cjoin", (q, op) -> (q.cjoin("driver" => "Tlp_driver", filters = [op_node(op)], warn = false); q.values("id"))),
  )
  for (backend, conn) in _TLP_BACKENDS, (label, entry!) in joins
    @testset "$backend — $label" begin
      a = J.Tlp_result.objects; entry!(a, "ts__@year")
      b = J.Tlp_result.objects; entry!(b, F("ts__@year"))
      @test _tlp_sql(a; conn = conn) == _tlp_sql(b; conn = conn)
      @test _tlp_params(a; conn = conn) == _tlp_params(b; conn = conn)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `@isnull`, `@range` and `@nrange` after a transform (#972, #886).
# The transform arm of `_get_filter_query(::SQLTypeOper)` bound every value with one `add_parameter!`,
# so `"date__@year__@range" => [1990, 1999]` and `"date__@year__@isnull" => true` were refused as
# "BETWEEN / ISNULL is not a supported operator", and `@yyyy_mm` / `@date` / `@quarter` sent the
# `@isnull` polarity through their own formatter and blamed the value (#886). Django renders
# `pub_date__year__isnull` as `EXTRACT(…) IS NULL`; PormG now does the same.
#
# The expected left-hand side is NOT written out here: it is read from the PROJECTION of the same
# transform, a render this change does not touch, so every key — and a key added later — is checked
# against an independent source rather than against a list copied from the new output. `@isnull`
# binds nothing; a range binds its two formatted operands after whatever the expression bound itself
# (`@yyyy_q` binds its `'-Q'` and CASE bounds).
#
# The two filter spellings are the pair and `Q(…)`: an `F` comparison overloads the comparison
# operators only, so there is no `F` spelling of `@isnull` or `@range` to agree with.
#
# Mutation gates: restore the arm's single `add_parameter!` (`_bind_transform_value` →
# `add_parameter!(instruc, _guarded_format(…))`) and every row fails as "not a supported operator";
# drop `expression = transform_lhs` at the tail and every `@isnull` row fails on the #197 refusal;
# format the `ISNULL` polarity again and the `@yyyy_mm` / `@date` / `@quarter` rows fail as #886.
# ─────────────────────────────────────────────────────────────────────────────

# The transform's own SQL, as the projection renders it, plus the parameters that SQL binds.
function _tlp_transform_lhs(col, key, conn)
  r = inspect_query((q = TLP.Tlp_row.objects; q.values("x" => "$(col)__@$(key)"); q); connection = conn)
  m = match(r"SELECT\s+(.*?)\s+as \"x\""s, r[:sql_text])
  return (m.captures[1], r[:parameters])
end

# The two year-qualified labels, the transforms that render a `Concat`.
const _TLP_LABEL_TRANSFORMS = ("yyyy_q", "yyyy_quad")

# The third slot is what precedes the predicate in WHERE: `Q(…)` parenthesizes its group.
_tlp_972_spellings = (
  ("pair", (q, path, v) -> q.filter(path => v),    "WHERE "),
  ("Q",    (q, path, v) -> q.filter(Q(path => v)), "WHERE ("),
)

# The two labels are in the loop since #997, which made them NULL for a NULL date on both engines;
# #972 refused `@isnull` after them until then.
@testset "#972: @isnull after a transform renders IS [NOT] NULL and binds nothing" begin
  for (backend, conn) in _TLP_BACKENDS, key in _TLP_DATE_TRANSFORMS, col in ("seen", "ts")
    lhs, lhs_params = _tlp_transform_lhs(col, key, conn)
    for (spelling, filter!, where) in _tlp_972_spellings, (polarity, tail) in ((true, "IS NULL"), (false, "IS NOT NULL"))
      @testset "$backend $(col)__@$(key) $spelling $polarity" begin
        r = inspect_query((q = TLP.Tlp_row.objects; filter!(q, "$(col)__@$(key)__@isnull", polarity); q);
                          connection = conn)
        @test occursin("$(where)$(lhs) $(tail)", r[:sql_text])
        @test r[:parameters] == lhs_params
      end
    end
  end
end

@testset "#886: the @isnull polarity never reaches the transform's formatter" begin
  # The three keys whose formatter refuses a `Bool`, so the polarity used to come back as a refused
  # VALUE — `InvalidValueError` on `@yyyy_mm`, the one #886 reported. The loop above already renders
  # them; this names the regression and pins that no value refusal is raised.
  for (backend, conn) in _TLP_BACKENDS, key in ("yyyy_mm", "date", "quarter"), polarity in (true, false)
    @test _tlp_params((q = TLP.Tlp_row.objects; q.filter("seen__@$(key)__@isnull" => polarity); q);
                      conn = conn) == _tlp_transform_lhs("seen", key, conn)[2]
  end
end

@testset "#972: @range / @nrange after a transform bind both operands, in order" begin
  operands(key) = key == "date" ? ([Date(2020, 1, 1), Date(2020, 2, 1)], ["2020-01-01", "2020-02-01"]) :
                  key == "yyyy_mm" ? (["2020-01", "2020-03"], ["2020-01", "2020-03"]) :
                  key in _TLP_LABEL_TRANSFORMS ? (["2020-Q1", "2020-Q2"], ["2020-Q1", "2020-Q2"]) :
                  ([1, 3], [1, 3])
  for (backend, conn) in _TLP_BACKENDS, key in _TLP_DATE_TRANSFORMS, col in ("seen", "ts")
    lhs, lhs_params = _tlp_transform_lhs(col, key, conn)
    given, bound = operands(key)
    n = length(lhs_params)
    ph1, ph2 = conn === _TLP_SL ? ("?", "?") : ("\$$(n + 1)", "\$$(n + 2)")
    for (spelling, filter!, where) in _tlp_972_spellings, (op, sql_op) in (("range", "BETWEEN"), ("nrange", "NOT BETWEEN"))
      @testset "$backend $(col)__@$(key)__@$(op) $spelling" begin
        r = inspect_query((q = TLP.Tlp_row.objects; filter!(q, "$(col)__@$(key)__@$(op)", given); q);
                          connection = conn)
        @test occursin("$(where)$(lhs) $(sql_op) $(ph1) AND $(ph2)", r[:sql_text])
        @test r[:parameters] == [lhs_params..., bound...]
      end
    end
  end
  # The operands still go through the transform's formatter: an hour no clock shows is refused,
  # not bound — the #579 / #636 contract, now reached through the range arm too.
  for (backend, conn) in _TLP_BACKENDS
    @test_throws PormG.InvalidValueError _tlp_sql(
      (q = TLP.Tlp_row.objects; q.filter("ts__@hour__@range" => [1, 25]); q); conn = conn)
  end
end

@testset "#972: the other places a filter pair is read take the same render" begin
  # A `When` condition and a joined path read the pair through the same parser and the same arms.
  # Pinned because they are the two routes most likely to grow their own binding later; the
  # expected text is again the projection's. `@yyyy_q` rides along since #997: its `@isnull` is
  # licensed in a different arm of `_get_filter_query` from `@year`'s, so it is a separate route.
  for (backend, conn) in _TLP_BACKENDS, key in ("year", "yyyy_q")
    lhs, _ = _tlp_transform_lhs("ts", key, conn)
    sql = _tlp_sql((q = TLP.Tlp_row.objects;
                    q.values("x" => PormG.Functions.Case([PormG.Functions.When("ts__@$(key)__@isnull" => true, then = 1)], default = 0)); q);
                   conn = conn)
    @test occursin("WHEN $(lhs) IS NULL THEN", sql)

    J = TlpJoinModels
    proj = _tlp_sql((q = J.Tlp_result.objects; q.values("x" => "driver__dob__@$(key)"); q); conn = conn)
    joined_lhs = match(r"SELECT\s+(.*?)\s+as \"x\""s, proj).captures[1]
    sql = _tlp_sql((q = J.Tlp_result.objects; q.filter("driver__dob__@$(key)__@isnull" => false); q); conn = conn)
    @test occursin("$(joined_lhs) IS NOT NULL", sql)
  end
end

@testset "#972: COUNT under @isnull stays refused on the internal OP route" begin
  # The two `PormGTypeField`-keyed arms are reached only by the internal `OP(Count(…), …)`. They
  # refused every `@isnull` before #972; `COUNT` keeps that refusal, because `COUNT(…) IS NULL` can
  # never match — the alias branch's #654 rule. Mutation gate: drop the `COUNT` check in
  # `_bind_transform_value` and this renders a predicate that is always false.
  QB = PormG.QueryBuilder; Fn = PormG.Functions
  for (backend, conn) in _TLP_BACKENDS
    err = try
      _tlp_sql((q = TLP.Tlp_row.objects;
                q.values("id", "x" => Fn.Case([Fn.When(QB.OP(Fn.Count("id"), "ISNULL", true), then = 1)], default = 0)); q);
               conn = conn)
      nothing
    catch e
      e
    end
    @test err isa PormG.FilterError
    @test occursin("COUNT never returns NULL", replace(sprint(showerror, err), r"\e\[[0-9;]*m" => ""))
  end
end

@testset "#997: @yyyy_q / @yyyy_quad join with || on both engines, so a NULL date is a NULL label" begin
  # PostgreSQL's `CONCAT` skips a NULL argument, so the label read `'-Q'` for a NULL date there and
  # NULL on SQLite, whose `||` propagates it. Both engines render `||` now. The operands and their
  # binding are unchanged, so the parameters agree across engines, separator first.
  for (backend, conn) in _TLP_BACKENDS, key in _TLP_LABEL_TRANSFORMS, col in ("seen", "ts")
    @testset "$backend $(col)__@$(key)" begin
      lhs, lhs_params = _tlp_transform_lhs(col, key, conn)
      @test !occursin("CONCAT(", lhs)
      @test count(" ||", lhs) == 2
      @test first(lhs_params) == "-Q"
      @test lhs_params == _tlp_transform_lhs(col, key, conn === _TLP_PG ? _TLP_SL : _TLP_PG)[2]
    end
  end
  # The flag belongs to the two labels only. A user's `Concat` still renders PostgreSQL's `CONCAT`;
  # its NULL handling is left to a separate decision.
  sql = _tlp_sql((q = TLP.Tlp_row.objects;
                  q.values("x" => PormG.Functions.Concat("note", PormG.Functions.Value(" "), "note")); q);
                 conn = _TLP_PG)
  @test occursin("CONCAT(", sql)
  @test !occursin(" ||", sql)
end
