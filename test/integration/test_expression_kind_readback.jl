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

const _EKR_ENGINE = engine_key()   # no fallback: a backend added later has no row to borrow (#1179)

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
# milliseconds, the SQLite parser nanoseconds), so only its printed text differs. The CTE columns that
# were flagged only because the CTE model typed them another field than they mean (`Sum` of a float, a
# decimal or an interval, `Avg` of integers, a decimal quotient, a comparison) left the set when #1034
# phase 3 typed that field from what the column means.
const _EKR_EXPECTED = Dict{Tuple{String,Symbol},Any}(
  ("Avg interval | alone", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Avg interval | alone", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Avg interval | cte", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Avg interval | cte", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Avg interval | subquery", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Avg interval | subquery", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("F date - date | alone", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("F date - date | alone", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("F date - date | subquery", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("F date - date | subquery", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("Sum interval | alone", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Sum interval | alone", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
  ("Sum interval | subquery", :postgres) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452 milliseconds", read = "CInterval()"),
  ("Sum interval | subquery", :sqlite) => (type = "CompoundPeriod", value = "1 minute, 27 seconds, 452000000 nanoseconds", read = "CInterval()"),
)

# The cells whose value comes back as a DIFFERENT TYPE on the two engines, by the table above. Every
# other disagreeing cell reads back the same type on both, with `==` values. One family is left,
# representation, not meaning (#1196): `F date - date` is an integer on both engines and records
# `CInt32`, which no read parser undoes, so each driver's integer WIDTH comes through (`Int32` vs
# `Int64`) — the same value spelled in two widths, as an `IntegerField` column itself reads on each.
# An integer's width follows the engine, for a column and a computed value alike; the testset after
# the computed-number one pins it for the integer-valued functions, which the unit matrix does not flag. The `numeric` family that was here — an aggregate, `Abs`, `Round` or
# arithmetic over a `DecimalField`, `Round`/`Mod` over a float or an integer, `Avg` over an integer,
# `Sqrt`/`Exp`/`Ln`/`Power` — reads back as the type it means on both engines since #1121, and the
# testset below the table checks it cell by cell. So does the declared-decimal family that followed it
# here — a `Cast` to `numeric(p, s)`, `numeric` or `DecimalField()`, an `output_field` naming a decimal
# — which reads as a `Decimal` on both engines since #1212.
const _EKR_TYPE_DIVERGENT = Set{String}([
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
# `_EKR_TYPE_DIVERGENT`, and every disagreeing cell must be recorded on every engine that builds it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Expression-kind matrix: which disagreements change the type read back (#1034)" begin
  ids = Set(id for (id, _) in keys(_EKM_DISAGREEMENTS))
  @test Set(id for (id, _) in keys(_EKR_EXPECTED)) == ids
  # #1147: a cell the engine that departs from its meaning refuses has nothing to read back there
  # (`Cast(points, "numeric(10,1)")` on SQLite); every engine that builds it is recorded.
  builds(id, engine) = _EKM_EXPECTED[(id, engine)].stage === :ok
  @test all(id -> all(e -> !builds(id, e) || haskey(_EKR_EXPECTED, (id, e)), (:postgres, :sqlite)), ids)
  divergent = Set(id for id in ids
                  if haskey(_EKR_EXPECTED, (id, :postgres)) && haskey(_EKR_EXPECTED, (id, :sqlite)) &&
                     _EKR_EXPECTED[(id, :postgres)].type != _EKR_EXPECTED[(id, :sqlite)].type)
  @test divergent == _EKR_TYPE_DIVERGENT
end

# ─────────────────────────────────────────────────────────────────────────────
# A Bool literal reads back as a Bool, in every context (#1122)
# `Value(true)` / `Value(false)` projected alone, under a CTE, inside a `Subquery` and as a `When`
# branch, on result 1. SQLite binds a boolean as 0/1 and hands the integer back unless the build
# recorded `CBool`; before #1122 it did so only under a CTE, so the literal read back as `1` alone and
# inside a `Subquery` while PostgreSQL's driver delivered `true`. Its cell left the disagreement set
# with the fix, so this testset is what keeps it read back on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Expression-kind matrix: a Bool literal reads back as a Bool (#1122)" begin
  for b in (true, false)
    for ctx in (:alone, :cte, :subquery)
      @testset "Value($b) | $ctx" begin
        q, name = ekm_query(M, :Result, m -> _EKM_FN.Value(b), ctx)
        q.filter("resultid" => _EKR_ROW[:Result])
        v = only(q.list())[name]
        @test v isa Bool
        @test v === b
      end
    end
    @testset "When(..., then = Value($b))" begin
      q = M.Result.objects
      q.filter("resultid" => _EKR_ROW[:Result])
      q.values("resultid", "c" => _EKM_FN.Case([_EKM_FN.When("resultid" => _EKR_ROW[:Result], then = _EKM_FN.Value(b))], default = !b))
      v = only(q.list())[:c]
      @test v isa Bool
      @test v === b
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A computed number reads back as the type it means, on every engine (#1121, #1212)
# Each shape of the computed-number family, projected alone, under a CTE (where the CTE builds it) and
# inside a `Subquery`, on its pinned row: the Julia type is Django's `output_field` for the call — a
# `Decimal` over a `DecimalField`, a `Float64` for `Avg`/`Mod`/`Sqrt`/`Exp`/`Ln`/`Power` over an
# integer and for every function over a float — and the same on both engines. Before #1121 PostgreSQL
# read every `numeric`-computed cell as a `Decimal` and SQLite as a `Float64`. Most of these cells are
# not flagged by the unit matrix (a float column's textless is the float), so this testset, not the
# read-back table, is what keeps them; the value is compared to 12 significant digits, because the
# two engines compute `Sqrt`/`Ln` in different arithmetic (`numeric` against a double). A declared
# decimal (#1212: a `Cast` to one, a decimal `output_field`) is a `Decimal` the same way; its cells
# left the read-back table when the fix gave them a read kind, so they are kept here.
# ─────────────────────────────────────────────────────────────────────────────
const _EKR_MEANING = [
  # label                       type        value      builds under a CTE
  ("Sum decimal",               "Decimal",  5.5,       true),
  ("Avg decimal",               "Decimal",  5.5,       true),
  ("Abs decimal",               "Decimal",  5.5,       false),
  ("Round decimal",             "Decimal",  6.0,       false),
  ("Floor decimal",             "Decimal",  5.0,       false),
  ("F decimal * 2",             "Decimal",  11.0,      true),
  ("F decimal / 2",             "Decimal",  2.75,      true),
  ("Cast int numeric / 2",      "Decimal",  0.5,       true),
  ("Sum float",                 "Float64",  10.0,      true),
  ("Avg float",                 "Float64",  10.0,      true),
  ("Avg int",                   "Float64",  1.0,       true),
  ("Abs float",                 "Float64",  10.0,      false),
  ("Round float",               "Float64",  10.0,      false),
  ("Mod int",                   "Float64",  1.0,       false),
  ("Floor float",               "Float64",  10.0,      false),
  ("Ceil float",                "Float64",  10.0,      false),
  ("Sqrt float",                "Float64",  sqrt(10),  false),
  ("Sqrt int",                  "Float64",  1.0,       false),
  ("Exp int",                   "Float64",  exp(1),    false),
  ("Ln float",                  "Float64",  log(10),   false),
  ("Power float",               "Float64",  100.0,     false),
  ("Power int",                 "Float64",  1.0,       false),
  ("F float * 2",               "Float64",  20.0,      true),
  ("Case int float / 2",        "Float64",  0.75,      true),
  ("Lag int default float / 2", "Float64",  0.75,      true),
  ("Max of arithmetic",         "Float64",  20.0,      true),
  ("Subquery Avg float",        "Float64",  10.0,      false),
  # #1212: a declared decimal is the number the caller said it means. SQLite computed each as a REAL,
  # or as an INTEGER over a whole operand (`Cast("grid", DecimalField())` read an `Int64`).
  ("Cast F float * 1.5 numeric", "Decimal", 15.0,      true),
  ("Cast decimal to scale 2",   "Decimal",  5.5,       true),
  ("Cast int DecimalField",     "Decimal",  1.0,       true),
  ("Cast Case float literal to scale 2", "Decimal", 1.5, true),
  ("Coalesce F float output decimal", "Decimal", 15.0, true),
  ("Greatest float int output decimal", "Decimal", 10.0, true),
  ("Case float output decimal", "Decimal",  1.5,       true),
  ("Max Cast F float numeric",  "Decimal",  15.0,      true),
]
@testset "A computed number reads back as the type it means (#1121, #1212)" begin
  for (label, type, value, in_cte) in _EKR_MEANING
    i = findfirst(s -> s[1] == label, EKM_SHAPES)
    @test i !== nothing
    i === nothing && continue
    _, base, build = EKM_SHAPES[i]
    for ctx in (in_cte ? (:alone, :cte, :subquery) : (:alone, :subquery))
      @testset "$label | $ctx" begin
        q, name = ekm_query(M, base, build, ctx; prep! = get(EKM_PREP, label, nothing))
        q.filter(EKM_PK[base] => _EKR_ROW[base])
        v = only(q.list())[name]
        @test string(nameof(typeof(v))) == type
        @test isapprox(parse(Float64, string(v)), value; rtol = 1e-12)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A scaled cast SQLite refuses reads back as a `Decimal` where it builds (#1212)
# `Cast("points", "numeric(10,1)")` and `Cast(Case(When(…, then = F("points")), default = 0),
# "numeric(10,0)")` render `(…)::numeric(10,1)` / `(CASE … END)::numeric(10,0)` on PostgreSQL, which
# rounds a float to the scale, and are refused on SQLite (#1040, #1187), which would keep every digit.
# Where they build they record the declared decimal's read kind, so they are kept here, not in the
# both-engine table above. A `Case`'s own `output_field = "numeric(10,1)"` over `F("points") * 1.5` is
# the same cast taken on a branch (#1217): `15.0` on result 1 (grid `1`, points `10`) on PostgreSQL,
# refused on SQLite. Why: the cells left the read-back table with the fix, and nothing else reads
# them back on a live engine.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A scaled cast reads back as a Decimal where it builds, and is refused where it departs (#1212)" begin
  for (label, value) in ("Cast float to scale 1" => 10, "Cast Case float col to scale 0" => 10,
                         "Case F float * 1.5 output scale 1" => 15)
    _, base, build = EKM_SHAPES[findfirst(s -> s[1] == label, EKM_SHAPES)]
    for ctx in (:alone, :cte, :subquery)
      @testset "$label | $ctx" begin
        q, name = ekm_query(M, base, build, ctx)
        q.filter(EKM_PK[base] => _EKR_ROW[base])
        # Each engine's expectation, stated: a backend added later gets a missing-row error (#1179).
        if by_engine(postgres = false, sqlite = true)
          # The #1040 refusal itself, not any build error a CTE or Subquery wrapping could raise.
          err = try q.list(); nothing catch e; e end
          @test err isa PormG.QueryBuildError
          @test occursin("rounded to the scale of numeric(10,", sprint(showerror, err))
        else
          v = only(q.list())[name]
          @test string(nameof(typeof(v))) == "Decimal"
          @test v == value
        end
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A computed integer reads back as an integer, on every engine (#1196)
# `Round` over an integer means that integer (Django's `output_field` is its operand's), and so do
# `Abs`/`Floor`/`Ceil` over one (#1147). Projected alone and inside a `Subquery` on result 1 (grid
# `1`, resultid `1`), each must come back as an integer with the exact value. Before #1196 `Round("grid")`
# read a `Decimal` on PostgreSQL and a `Float64` on SQLite, and `Round("grid") / 2` was `0.5` on both
# where the integer it rounds divides to `0`. The width is each engine's own (representation, not
# meaning): PostgreSQL keeps the column's `integer`/`bigint`, SQLite has one 64-bit integer.
# ─────────────────────────────────────────────────────────────────────────────
const _EKR_INTEGER = [
  # label               value  width on PostgreSQL
  ("Round int",         1,     "Int32"),
  ("Round int places",  1,     "Int32"),
  ("Round bigint",      1,     "Int64"),
  ("Round int / 2",     0,     "Int64"),
  ("Abs int",           1,     "Int32"),
  ("Floor int",         1,     "Int32"),
  ("Ceil int",          1,     "Int32"),
]
@testset "A computed integer reads back as an integer (#1196)" begin
  for (label, value, pg_width) in _EKR_INTEGER
    i = findfirst(s -> s[1] == label, EKM_SHAPES)
    @test i !== nothing
    i === nothing && continue
    _, base, build = EKM_SHAPES[i]
    for ctx in (:alone, :subquery)
      @testset "$label | $ctx" begin
        q, name = ekm_query(M, base, build, ctx; prep! = get(EKM_PREP, label, nothing))
        q.filter(EKM_PK[base] => _EKR_ROW[base])
        v = only(q.list())[name]
        @test v isa Integer
        @test v == value
        @test string(nameof(typeof(v))) == by_engine(postgres = pg_width, sqlite = "Int64")
      end
    end
  end
end
