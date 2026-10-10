"""
The expression-kind matrix's read-back half (#1034, phase 1) — both engines.

`test/unit/test_expression_kind_matrix.jl` records what every type channel answers for each projected
shape, and pins the cells on which two channels disagree (`_EKM_DISAGREEMENTS`). This file projects
EVERY disagreeing cell on the seeded F1 fixture and records what the column actually reads back as —
its Julia type and its value — on whichever engine `PORMG_DB` selects. That is the evidence a
disagreement is worth consolidating: one that never changes what a caller receives (the same type on
both engines) is inert; one that does is live.

A disagreeing cell with no expectation below fails, and prints the row to add, so a new disagreement
in the unit matrix forces a read-back row here. Only the disagreeing cells are read back, by design;
the full read-back matrix, and the matrix's cross-context set, are follow-ups on #1034.

Rows are pinned by primary key: result 1 (race 18, the 2008 Australian Grand Prix, with a fastest lap
of `1:27.452`), race 1 (the 2009 Australian Grand Prix, `2009-03-29 06:00:00` UTC), constructor result
3835 (race 2, `5.5` points). A boolean column is read on a `New_join_position` row this file creates
under its own marker and deletes again, so the shared `test_cjoin.jl` rows are untouched.

Run (either engine; the SQLite pass needs `-t 1`):
  julia -t auto --project=test/integration test/integration/test_expression_kind_readback.jl
  PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_expression_kind_readback.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

include(joinpath(@__DIR__, "..", "unit", "helper_expression_kind_shapes.jl"))
include(joinpath(@__DIR__, "..", "unit", "fixtures", "expression_kind_matrix_expected.jl"))

const _EKR_ENGINE = PORMG_DB_FOLDER == "db_sl" ? :sqlite : :postgres

# The row each base model is read on. A constructor result with FRACTIONAL points (`5.5`): SQLite
# hands back an integral NUMERIC as an `Int64`, so a row holding `14` would report the value's storage
# class, not the shape's. `New_join_position` gets the id of the marker row, once it exists.
const _EKR_ROW = Dict{Symbol,Int}(:Result => 1, :Race => 1, :Constructor_results => 3835)
const _EKR_MARKER = "ekm-1034"

# The cell's label, shape and context, from its id ("<label> | <context>").
function _ekr_cell(id::String)
  label, ctx = split(id, " | ")
  i = findfirst(s -> s[1] == label, EKM_SHAPES)
  _, base, build = EKM_SHAPES[i]
  return String(label), base, build, Symbol(ctx)
end

# What the cell reads back as on the live engine: the value's type (by its bare name, which does not
# depend on whether `Main` has `using`-ed the defining package) and text, and the read kind the build
# recorded for it.
function _ekr_observe(id::String)
  label, base, build, ctx = _ekr_cell(id)
  q, name = ekm_query(M, base, build, ctx; prep! = get(EKM_PREP, label, nothing))
  q.filter(EKM_PK[base] => _EKR_ROW[base])
  # The read kind from a build of its own: `list()` builds a copy, so its record never reaches `q`.
  probe = deepcopy(q)
  PormG.QueryBuilder.query(probe; show_query = :sql)
  kind = get(probe.object.projection_kinds, name, nothing)
  v = only(q.list())[name]
  return (type = string(nameof(typeof(v))), value = string(v),
          read = kind === nothing ? nothing : replace(string(kind), "PormG.Kernel." => ""))
end

# Measured on both engines. `read` is the kind the build recorded (`nothing`: no read parser runs).
# An interval reads back `==` on both engines, in different units (PostgreSQL's driver delivers
# milliseconds, the SQLite parser nanoseconds), so only its printed text differs.
const _EKR_EXPECTED = Dict{Tuple{String,Symbol},Any}(
  ("Abs decimal | alone", :postgres) => (type = "Decimal", value = "5.5", read = nothing),
  ("Abs decimal | alone", :sqlite) => (type = "Float64", value = "5.5", read = nothing),
  ("Avg decimal | alone", :postgres) => (type = "Decimal", value = "5.5", read = nothing),
  ("Avg decimal | alone", :sqlite) => (type = "Float64", value = "5.5", read = nothing),
  ("Avg decimal | cte", :postgres) => (type = "Decimal", value = "5.5", read = nothing),
  ("Avg decimal | cte", :sqlite) => (type = "Float64", value = "5.5", read = nothing),
  ("Avg float | alone", :postgres) => (type = "Float64", value = "10.0", read = nothing),
  ("Avg float | alone", :sqlite) => (type = "Float64", value = "10.0", read = nothing),
  ("Avg float | cte", :postgres) => (type = "Float64", value = "10.0", read = nothing),
  ("Avg float | cte", :sqlite) => (type = "Float64", value = "10.0", read = nothing),
  ("Avg interval | alone", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Avg interval | alone", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Avg interval | cte", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Avg interval | cte", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Avg interval | subquery", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Avg interval | subquery", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("F comparison | cte", :postgres) => (type = "Bool", value = "false", read = "CBool()"),
  ("F comparison | cte", :sqlite) => (type = "Bool", value = "false", read = "CBool()"),
  ("F date - date | alone", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("F date - date | alone", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("F date - date | subquery", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("F date - date | subquery", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("F decimal * 2 | alone", :postgres) => (type = "Decimal", value = "11", read = nothing),
  ("F decimal * 2 | alone", :sqlite) => (type = "Float64", value = "11.0", read = nothing),
  ("F decimal * 2 | cte", :postgres) => (type = "Decimal", value = "11", read = nothing),
  ("F decimal * 2 | cte", :sqlite) => (type = "Float64", value = "11.0", read = nothing),
  ("Mod int | alone", :postgres) => (type = "Decimal", value = "1", read = nothing),
  ("Mod int | alone", :sqlite) => (type = "Float64", value = "1.0", read = nothing),
  ("Round decimal | alone", :postgres) => (type = "Decimal", value = "6", read = nothing),
  ("Round decimal | alone", :sqlite) => (type = "Float64", value = "6.0", read = nothing),
  ("Round float | alone", :postgres) => (type = "Decimal", value = "10", read = nothing),
  ("Round float | alone", :sqlite) => (type = "Float64", value = "10.0", read = nothing),
  ("Sum decimal | alone", :postgres) => (type = "Decimal", value = "5.5", read = nothing),
  ("Sum decimal | alone", :sqlite) => (type = "Float64", value = "5.5", read = nothing),
  ("Sum decimal | cte", :postgres) => (type = "Decimal", value = "5.5", read = nothing),
  ("Sum decimal | cte", :sqlite) => (type = "Float64", value = "5.5", read = nothing),
  ("Sum float | cte", :postgres) => (type = "Float64", value = "10.0", read = nothing),
  ("Sum float | cte", :sqlite) => (type = "Float64", value = "10.0", read = nothing),
  ("Sum interval | alone", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Sum interval | alone", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Sum interval | cte", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Sum interval | cte", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Sum interval | subquery", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Sum interval | subquery", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Value bool | alone", :postgres) => (type = "Bool", value = "true", read = nothing),
  ("Value bool | alone", :sqlite) => (type = "Int64", value = "1", read = nothing),
)

# The cells whose value comes back as a DIFFERENT TYPE on the two engines, by the table above. Every
# other disagreeing cell reads back the same type on both, with `==` values. Three families:
# - a number PostgreSQL computes as `numeric` — an aggregate, `Abs`, `Round` or arithmetic over a
#   `DecimalField` (the shapes #648 left untyped), and `Round`/`Mod` over a float or an integer — comes
#   back as a `Decimal` there and a `Float64` on SQLite. The textless channel already names each one
#   (`decimal` / `numeric`); no read kind records it;
# - a `Value(true)` literal comes back as a `Bool` on PostgreSQL and SQLite's stored `1`: the textless
#   channel names it `bool`, the read kind records nothing (#965 typed boolean COLUMNS and expressions);
# - `F date - date` records `CInt32`, which no read parser undoes, so each driver's integer width
#   comes through (`Int32` vs `Int64`).
const _EKR_TYPE_DIVERGENT = Set{String}([
  "Abs decimal | alone", "Avg decimal | alone", "Avg decimal | cte", "F decimal * 2 | alone",
  "F decimal * 2 | cte", "Mod int | alone", "Round decimal | alone", "Round float | alone",
  "Sum decimal | alone", "Sum decimal | cte",
  "Value bool | alone",
  "F date - date | alone", "F date - date | subquery",
])

const _EKR_CELLS = sort!([id for (id, backend) in keys(_EKM_DISAGREEMENTS) if backend === _EKR_ENGINE])

# ─────────────────────────────────────────────────────────────────────────────
# Expression-kind matrix: every disagreeing cell reads back as recorded, on this engine
# Each cell the unit matrix flags is projected on its pinned row and must come back with the recorded
# type, value and read kind. A cell with no row in `_EKR_EXPECTED` prints the row to add and fails.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Expression-kind matrix: the disagreeing cells read back (#1034)" begin
  @test !isempty(_EKR_CELLS)
  # The boolean shapes' row, created only when a disagreeing cell reads one, and always removed.
  needs_marker = any(id -> _ekr_cell(id)[2] === :New_join_position, _EKR_CELLS)
  purge() = (p = M.New_join_position.objects; p.filter("description" => _EKR_MARKER); p.exists() && p.delete())
  try
    if needs_marker
      purge()
      created = M.New_join_position.objects.create("description" => _EKR_MARKER, "boolean_field" => true, "result" => 1)
      _EKR_ROW[:New_join_position] = created[:id]
    end
    for id in _EKR_CELLS
      @testset "$id" begin
        got = _ekr_observe(id)
        expected = get(_EKR_EXPECTED, (id, _EKR_ENGINE), nothing)
        # Printed as a ready-to-paste row of the table above: the record step for a new disagreement.
        expected === nothing && println("unrecorded read-back:   ", repr((id, _EKR_ENGINE)), " => ", repr(got), ",")
        @test expected !== nothing
        expected === nothing && continue
        @test got.type == expected.type
        @test got.value == expected.value
        @test got.read == expected.read
      end
    end
  finally
    needs_marker && purge()
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Expression-kind matrix: the type-divergence verdict matches the recorded table
# A consistency check of the conclusion, not of behaviour (the testset above checks behaviour): the
# cells whose PostgreSQL and SQLite types differ in `_EKR_EXPECTED` must be exactly
# `_EKR_TYPE_DIVERGENT`, and every disagreeing cell must be recorded for both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Expression-kind matrix: which disagreements change the type read back (#1034)" begin
  ids = Set(id for (id, _) in keys(_EKM_DISAGREEMENTS))
  @test Set(id for (id, _) in keys(_EKR_EXPECTED)) == ids
  @test all(id -> haskey(_EKR_EXPECTED, (id, :postgres)) && haskey(_EKR_EXPECTED, (id, :sqlite)), ids)
  divergent = Set(id for id in ids
                  if haskey(_EKR_EXPECTED, (id, :postgres)) && haskey(_EKR_EXPECTED, (id, :sqlite)) &&
                     _EKR_EXPECTED[(id, :postgres)].type != _EKR_EXPECTED[(id, :sqlite)].type)
  @test divergent == _EKR_TYPE_DIVERGENT
end
