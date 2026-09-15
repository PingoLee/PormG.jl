"""
Value representation has an owner — the property test (#564, order item 1).

PormG has two independent producers of "the stored text for a temporal value": the field's Julia
`formatter` on the write path (`Models.format_timezone_sql`, `format_date_sql`, …) and whatever
the dialect renders on the read path (`Dialect._sqlite_canonical_datetime`, `date(...)`, the
`__@` transform ladders, `ToChar`). Nothing ties them together. On PostgreSQL a mismatch fails at
execution because `date`, `timestamp` and `text` are real types; on SQLite every temporal column
is TEXT compared lexicographically, so **every representation mistake becomes a wrong answer
rather than an error** — which is why the #527 family is SQLite-only, silent, and survives review.

This file asserts the PROPERTY rather than a spelling: for every temporal field kind, the value
an expression evaluates to on a real connection must equal what the column's own formatter
produces for the same Julia value (P1), must bind the same way when compared (P2), and must read
back as the same Julia type on both engines (P3). The cases live in
`helper_value_repr_cases.jl`, shared with the integration twin, and the `broken` marks on them
are MEASURED — each names the #564 sibling it belongs to, and a `@test_broken` that starts
passing is a Julia error, so a fixed renderer cannot leave a stale mark behind.

Why a dedicated file: the closest siblings each pin a spelling — `test_alignment_sqlite.jl` the
`strftime` wrapper, `test_date_functions_sql.jl` the per-function parity, `test_f_date_operands.jl`
the bound bytes. All three stayed green for the entire life of #527. None can fail on the NEXT
renderer someone adds; this one does, because the meta-guard at the bottom walks every temporal
`PormGField` subtype and demands a probe column and at least one case for each.

Hermetic: an in-memory SQLite database (`SQLiteConnectionPool(":memory:"; pool_size = 1)` — the
#545 rule, a wider `:memory:` pool is N databases) built through PormG's own DDL renderer. The
PostgreSQL arm lives in `test/integration/test_value_repr_property.jl`, which runs the same case
table against whichever engine `PORMG_DB` selects; CI runs no integration test, so that arm is
local only.

julia --project=. test/unit/test_value_repr_property.jl
"""

using Test
using PormG
using PormG.Models
using Dates
import TimeZones
import InteractiveUtils: subtypes

# Needs the real SQLite extension (runtests.jl loads it too; re-loading is idempotent).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
include(joinpath(@__DIR__, "helper_value_repr_cases.jl"))

const _VR_CP = PormG.ConnectionPool

# ── Scratch database ────────────────────────────────────────────────────────
# Registered in `config` under the SAME absolute path the models module below resolves to, so
# `set_models` finds it by exact path (rank 1 in `_resolve_connect_key`) rather than falling back
# to an implicit `Configuration.load` of a folder that does not exist.
const _VR_KEY = normpath(joinpath(@__DIR__, "pormg564_repr"))
const _VR_POOL = _VR_CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_VR_KEY] = PormG.Configuration.Settings(
    connections = _VR_POOL, change_data = true, db_def_folder = _VR_KEY)

# One probe column per temporal field kind. `tsn` is the `TIMESTAMP` (no-tz) flavour of
# `DateTimeField`, which shares the formatter but takes a different DDL arm and — on SQLite —
# falls through `sqlite_type_map` verbatim.
PormG.@models_module Repr564 "pormg564_repr" begin
  Probe = Models.Model("repr564_probe",
    id    = Models.IDField(),
    label = Models.CharField(max_length = 40, unique = true),
    ts    = Models.DateTimeField(null = true),
    tsn   = Models.DateTimeField(type = "TIMESTAMP", null = true),
    d     = Models.DateField(null = true),
    t     = Models.TimeField(null = true),
    dur   = Models.DurationField(null = true),
  )
end
import .Repr564 as VRM

# DDL through PormG's own renderer, so the column types under test are the ones a migration
# would create — not a hand-written approximation of them.
_VR_CP.fetch(_VR_POOL, PormG.Dialect.create_table(_VR_POOL, VRM.Probe))

const _VR_LABEL = "repr564_probe_row"
VRM.Probe.objects.create("label" => _VR_LABEL, "ts" => VR_INSTANT, "tsn" => VR_INSTANT,
                         "d" => VR_DATE, "t" => VR_TIME, "dur" => VR_DURATION)

_vr_base() = VRM.Probe.objects.filter("label" => _VR_LABEL)

@testset "Value representation property (#564)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # Property: render == formatter, bind == render, read-side type parity — per column kind.
  # Every case is evaluated on a live SQLite connection; the SQL shape is deliberately not
  # asserted, because the shape was never the defect.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "TIMESTAMP (timestamptz flavour)" begin
    vr_run_cases(_vr_base, "ts", VR_INSTANT, :sqlite; kind = :timestamp)
  end

  @testset "TIMESTAMP (no-tz flavour)" begin
    vr_run_cases(_vr_base, "tsn", VR_INSTANT, :sqlite; kind = :timestamp)
  end

  @testset "DATE" begin
    vr_run_cases(_vr_base, "d", VR_DATE, :sqlite; kind = :date)
  end

  @testset "TIME" begin
    vr_run_cases(_vr_base, "t", VR_TIME, :sqlite; kind = :time)
  end

  @testset "INTERVAL" begin
    vr_run_cases(_vr_base, "dur", VR_DURATION, :sqlite; kind = :interval)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #562: the two `__@` ladders must project the same value for every transform.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "transform ladder parity (#562)" begin
    vr_run_ladder_parity(_vr_base, "ts", VR_INSTANT, :sqlite)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Sibling 3: the one remaining `datetime('now')` writer. No `PormGField` can emit it —
  # `normalize_datetime_default` rejects a string it cannot parse, and the Django importer maps
  # `timezone.now` to a callable marker — so the only column that receives SQLite's own
  # `YYYY-MM-DD HH:MM:SS` form is the migrations audit table's `applied_at`. Internal, but it is
  # the same defect: text in a representation no PormG reader anchors on.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "pormg_migrations.applied_at is written in the canonical form" begin
    _VR_CP.fetch(_VR_POOL, PormG.Dialect.create_migrations_table(_VR_POOL))
    _VR_CP.fetch(_VR_POOL, """INSERT INTO pormg_migrations ("version", "name", "checksum")
                              VALUES ('20310704123045123', 'repr564_probe', 'x');""")
    rows = _VR_CP.fetch(_VR_POOL, "SELECT applied_at FROM pormg_migrations;") |> collect
    @test length(rows) == 1
    applied_at = String(rows[1].applied_at)
    canonical = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}\+00:00$"
    # Measured broken: `create_migrations_table(::PormGSQLite)` writes `DEFAULT (datetime('now'))`,
    # i.e. `YYYY-MM-DD HH:MM:SS` — no `T`, no fraction, no offset.
    @test_broken occursin(canonical, applied_at)
    # …and the shape it DOES write, so the mark above is about the defect and not a typo.
    @test occursin(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", applied_at)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Meta-guard: every temporal field kind is covered. Walks the real `PormGField` subtypes (the
  # `test_column_spec.jl` shape) so a new temporal field struct fails this file until it has a
  # probe column and a case row — the property must reach the NEXT renderer, not only these.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "every temporal field kind has a probe column and a case" begin
    kind_of(type::String) = type in ("TIMESTAMP", "TIMESTAMPTZ") ? :timestamp :
                            type == "DATE"                       ? :date :
                            type == "TIME"                       ? :time :
                            type == "INTERVAL"                   ? :interval : nothing
    concrete = filter(T -> isconcretetype(T) && parentmodule(T) === PormG.Models,
                      subtypes(PormG.PormGField))
    # The census, pinned exactly as `test_column_spec.jl` pins it: a 26th struct fails here until
    # it is classified below. No `try` around the constructor — a struct that cannot be built by
    # this table is a loud failure, not a silent skip.
    @test length(concrete) == 25
    instance(T) =
      T === Models.sForeignKey        ? Models.ForeignKey("Races") :
      T === Models.sOneToOneField     ? Models.OneToOneField("Races") :
      T === Models.sManyToManyField   ? Models.ManyToManyField("Races") :
      T === Models.sDecimalField      ? Models.DecimalField(max_digits = 8, decimal_places = 3) :
      getfield(Models, Symbol(String(nameof(T))[2:end]))()
    temporal = Dict{Type,Symbol}()
    for T in concrete
      k = kind_of(instance(T).type)
      k === nothing || (temporal[T] = k)
    end
    # Guard the guard: the four kinds this file knows about must all be present, or the census
    # above silently shrank.
    @test Set(values(temporal)) == Set([:timestamp, :date, :time, :interval])

    probe_kinds = Set(kind_of(f.type) for f in values(VRM.Probe.fields) if kind_of(f.type) !== nothing)
    case_kinds  = Set(c.kind for c in VR_CASES)
    for (T, k) in temporal
      @test k in probe_kinds
      @test k in case_kinds
      # #564 — and a populated cell in the representation table. Without this a new temporal field
      # struct could gain a probe column and a case row while the table still answered `nothing` for
      # it, which is the silent half: `value_formatter` returning `nothing` makes a renderer fall
      # back to whatever it did before the owner existed, rather than failing. Asserted on the
      # INSTANCE, so the field's own declared type decides — the same source `kind_of` reads.
      f = instance(T)
      @test PormG.field_canonical_kind(f) !== nothing
      @test PormG.value_formatter(PormG.field_canonical_kind(f), _VR_POOL) === f.formatter
    end
  end
end
