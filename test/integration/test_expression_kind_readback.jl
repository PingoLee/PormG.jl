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

# The rows the F1 fixture does not seed, per base model: how to remove them, and how to create one
# (returning its id). A boolean row, and (#1458) a JSON document `{"n": 7}` for the key-lookup shapes.
function _ekr_purge(model, field)
  p = model.objects
  p.filter(field => _EKR_MARKER)
  p.exists() && p.delete()
  return nothing
end
const _EKR_MARKERS = Dict{Symbol,NamedTuple}(
  :New_join_position => (
    purge = () -> _ekr_purge(M.New_join_position, "description"),
    create = () -> M.New_join_position.objects.create("description" => _EKR_MARKER, "boolean_field" => true,
                                                      "result" => 1)[:id]),
  :Field_validation_scratch => (
    purge = () -> _ekr_purge(M.Field_validation_scratch, "slug"),
    create = () -> M.Field_validation_scratch.objects.create(
      "uuid_token" => UUIDs.UUID("10340000-0000-4000-8000-000000001458"),
      "canonical_url" => "https://example.com/ekm-1034", "slug" => _EKR_MARKER,
      "payload" => Dict("n" => 7))[:id]),
)

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
  read = kind === nothing ? nothing : replace(string(kind), "PormG.Kernel." => "")
  # #1439: an array prints its element type qualified or not by what `Main` has `using`-ed
  # (`Decimals.Decimal[…]`), so it is recorded by bare names too: its element type (each member of a
  # `Union{Missing, T}`) and each element.
  if v isa AbstractVector
    names = sort!([string(nameof(t)) for t in Base.uniontypes(eltype(v))])
    T = length(names) == 1 ? only(names) : "Union{$(join(names, ", "))}"
    return (type = "Vector{$(T)}", value = "[" * join(string.(v), ", ") * "]", read = read)
  end
  return (type = string(nameof(typeof(v))), value = string(v), read = read)
end

# Measured on every engine (MySQL's rows on 8.4, #1130 phase 5c). `read` is the kind the build recorded
# (`nothing`: no read parser runs).
# An interval reads back `==` on both engines, in different units (PostgreSQL's driver delivers
# milliseconds, the SQLite parser nanoseconds), so only its printed text differs. The CTE columns that
# were flagged only because the CTE model typed them another field than they mean (`Sum` of a float, a
# decimal or an interval, `Avg` of integers, a decimal quotient, a comparison) left the set when #1034
# phase 3 typed that field from what the column means, and an `Avg` of an interval left it in step 2c,
# when `Concat` and the casts read the column by the kind it means rather than the body's `:numeric` tag.
# A `Sum` of an interval left it in step 4, when its formatter became the duration its kind names. An
# `Avg` of an interval projected alone or through a `Subquery` left it in step 5c, when the `Concat`
# classifier read its kind from the walk (an interval) rather than the `AVG` rule's `:numeric`; it read
# back the same interval on both engines (`1 minute, 27 seconds, 452 milliseconds`), as before.
const _EKR_EXPECTED = Dict{Tuple{String,Symbol},Any}(
  ("F date - date | alone", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("F date - date | alone", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("F date - date | alone", :mysql) => (type = "Int64", value = "0", read = "CInt32()"),
  ("F date - date | subquery", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("F date - date | subquery", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("F date - date | subquery", :mysql) => (type = "Int64", value = "0", read = "CInt32()"),
  # #1307: a `Case` over a date column minus a date is the same day count, through the `DateField`
  # column's render, so it reads back as `F date - date` does.
  ("Case untyped date col - date | alone", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | alone", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | alone", :mysql) => (type = "Int64", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | subquery", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | subquery", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | subquery", :mysql) => (type = "Int64", value = "0", read = "CInt32()"),
  # #1460 (review): the day count with a date literal, race 1 (2009-03-29) minus 2009-03-01.
  ("F date - date literal | alone", :postgres) => (type = "Int32", value = "28", read = "CInt32()"),
  ("F date - date literal | alone", :sqlite) => (type = "Int64", value = "28", read = "CInt32()"),
  ("F date - date literal | alone", :mysql) => (type = "Int64", value = "28", read = "CInt32()"),
  ("F date - date literal | subquery", :postgres) => (type = "Int32", value = "28", read = "CInt32()"),
  ("F date - date literal | subquery", :sqlite) => (type = "Int64", value = "28", read = "CInt32()"),
  ("F date - date literal | subquery", :mysql) => (type = "Int64", value = "28", read = "CInt32()"),
  ("F date - date literal | cte", :postgres) => (type = "Int32", value = "28", read = "CInt32()"),
  ("F date - date literal | cte", :sqlite) => (type = "Int64", value = "28", read = "CInt32()"),
  ("F date - date literal | cte", :mysql) => (type = "Int64", value = "28", read = "CInt32()"),
  # #1460: both day counts are CTE columns now (the walk names them `CInt32`), read back as above.
  ("F date - date | cte", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("F date - date | cte", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("F date - date | cte", :mysql) => (type = "Int64", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | cte", :postgres) => (type = "Int32", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | cte", :sqlite) => (type = "Int64", value = "0", read = "CInt32()"),
  ("Case untyped date col - date | cte", :mysql) => (type = "Int64", value = "0", read = "CInt32()"),
  # (`Floor`, `Ceil` and `Abs` over a JSON key, divided by 2, read back `Decimal 3.5` on PostgreSQL
  # here until #1483, which refuses arithmetic over an uncast key on every engine: no cell to read.)
  # #1471: `Round` is a `numeric` on PostgreSQL and MySQL and a REAL on SQLite, which `_division_sql`
  # casts, so all three keep the fraction. `Round` names its number, so #1483 lets it build. The read path records no kind for it, so each driver's type
  # comes through (`Decimal` vs `Float64`, the same value).
  ("Round json key / 2 | alone", :postgres) => (type = "Decimal", value = "3.5", read = nothing),
  ("Round json key / 2 | alone", :sqlite) => (type = "Float64", value = "3.5", read = nothing),
  ("Round json key / 2 | alone", :mysql) => (type = "Decimal", value = "3.5", read = nothing),
  ("Round json key / 2 | subquery", :postgres) => (type = "Decimal", value = "3.5", read = nothing),
  ("Round json key / 2 | subquery", :sqlite) => (type = "Float64", value = "3.5", read = nothing),
  ("Round json key / 2 | subquery", :mysql) => (type = "Decimal", value = "3.5", read = nothing),
  # #1460: `Extract(x, "EPOCH")` (a decimal since #1457) is a CTE column now, typed `DecimalField` from
  # the walk; it was refused there before. Twice result 1's fastest lap (87.452 s), and a time minus
  # itself. SQLite has no `EPOCH` part.
  ("Extract epoch F interval * 2 | cte", :postgres) => (type = "Decimal", value = "174.904", read = nothing),
  ("Extract epoch F interval * 2 | cte", :mysql) => (type = "Decimal", value = "174.904", read = nothing),
  ("Extract epoch F time - time | cte", :postgres) => (type = "Decimal", value = "0", read = nothing),
  # #1034 (the #1457 leftover): alone and in a `Subquery` the classifier reads the walk's decimal now, as
  # the CTE column above does, so these cells are flagged a read gap (no read kind is recorded). They
  # read back the same `Decimal` the CTE column does, on both engines.
  ("Extract epoch F interval * 2 | alone", :postgres) => (type = "Decimal", value = "174.904", read = nothing),
  ("Extract epoch F interval * 2 | alone", :mysql) => (type = "Decimal", value = "174.904", read = nothing),
  ("Extract epoch F interval * 2 | subquery", :postgres) => (type = "Decimal", value = "174.904", read = nothing),
  ("Extract epoch F interval * 2 | subquery", :mysql) => (type = "Decimal", value = "174.904", read = nothing),
  ("Extract epoch F time - time | alone", :postgres) => (type = "Decimal", value = "0", read = nothing),
  ("Extract epoch F time - time | subquery", :postgres) => (type = "Decimal", value = "0", read = nothing),
  # (#1457: the `Sum F int|bigint + epoch / 2` rows left this table when `EPOCH` became a decimal: the
  # walk names the sum, so the cells no longer disagree. They read back `Decimal` on PostgreSQL, as
  # recorded here before; `test_sql_functions.jl` reads `EPOCH` itself back against Julia.)
  # (#1465: the `grid * Lag Case interval col` rows left this table when a window function on the RIGHT
  # of `*` was typed as it is on the left: an interval on PostgreSQL and MySQL, refused on SQLite. They
  # read back `missing` here, on a first row whose `Lag` is NULL; the testset "A duration window on the
  # right of `*`" below reads a row whose `Lag` is not.)
  # #1439: a cast to an array reads back as the `Vector` an `ArrayField` of its element does. Flagged
  # `:unparsed` only because a PostgreSQL cell asks SQLite's parser table, which has no array parser
  # (SQLite and MySQL refuse the cast, so there is nothing to read back there). Before #1439 LibPQ
  # returned the text cells as their `{…}` literal, a `String`.
  ("Cast text varchar[] | alone", :postgres) => (type = "Vector{String}", value = "[SOFT, MEDIUM]", read = "CArray(CVarChar(nothing))"),
  ("Cast text varchar[] | subquery", :postgres) => (type = "Vector{String}", value = "[SOFT, MEDIUM]", read = "CArray(CVarChar(nothing))"),
  ("Cast text ArrayField(CharField(3)) | alone", :postgres) => (type = "Vector{String}", value = "[SOF, MED]", read = "CArray(CVarChar(3))"),
  ("Cast text ArrayField(CharField(3)) | subquery", :postgres) => (type = "Vector{String}", value = "[SOF, MED]", read = "CArray(CVarChar(3))"),
  ("Cast int integer[] | alone", :postgres) => (type = "Vector{Int32}", value = "[7, 8]", read = "CArray(CInt32())"),
  ("Cast int integer[] | subquery", :postgres) => (type = "Vector{Int32}", value = "[7, 8]", read = "CArray(CInt32())"),
  ("Cast decimal numeric(10,2)[] | alone", :postgres) => (type = "Vector{Decimal}", value = "[1.5, 2]", read = "CArray(CDecimal(10, 2))"),
  ("Cast decimal numeric(10,2)[] | subquery", :postgres) => (type = "Vector{Decimal}", value = "[1.5, 2]", read = "CArray(CDecimal(10, 2))"),
)

# The cells whose value comes back as a DIFFERENT TYPE on two engines, by the table above. Every
# other disagreeing cell reads back the same type on every engine, with `==` values. One family is left,
# representation, not meaning (#1196): `F date - date` (and, since #1307, the same day count through a
# `Case` over a date column) is an integer on every engine and records
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
  # #1307: the same day count through a `Case` over a date column, so the same two widths.
  "Case untyped date col - date | alone", "Case untyped date col - date | subquery",
  "F date - date | cte", "Case untyped date col - date | cte",   # #1460: as CTE columns too
  "F date - date literal | alone", "F date - date literal | subquery", "F date - date literal | cte",
  # #1471: `Round` over a JSON key, divided, is the same value on every engine, a REAL on SQLite
  # (representation). (`Floor`/`Ceil`/`Abs` over one left this set with #1471, and #1483 refuses them
  # on every engine.)
  "Round json key / 2 | alone", "Round json key / 2 | subquery",
])

const _EKR_CELLS = sort!([id for (id, backend) in keys(_EKM_DISAGREEMENTS) if backend === _EKR_ENGINE])

# ─────────────────────────────────────────────────────────────────────────────
# Expression-kind matrix: every disagreeing cell reads back as recorded, on this engine
# Each cell the unit matrix flags is projected on its pinned row and must come back with the recorded
# type, value and read kind. A cell with no row in `_EKR_EXPECTED` prints the row to add and fails.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Expression-kind matrix: the disagreeing cells read back (#1034)" begin
  @test !isempty(_EKR_CELLS)
  # A marker row (`_EKR_MARKERS`), created only when a disagreeing cell reads its model, and always removed.
  needs_marker = intersect(Set(_ekr_cell(id)[2] for id in _EKR_CELLS), keys(_EKR_MARKERS))
  purge() = foreach(b -> _EKR_MARKERS[b].purge(), needs_marker)
  try
    purge()
    for b in needs_marker
      _EKR_ROW[b] = _EKR_MARKERS[b].create()
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
    purge()
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Expression-kind matrix: the type-divergence verdict matches the recorded table
# A consistency check of the conclusion, not of behaviour (the testset above checks behaviour): the
# cells whose engines' types differ in `_EKR_EXPECTED` must be exactly
# `_EKR_TYPE_DIVERGENT`, and every disagreeing cell must be recorded on every engine that builds it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Expression-kind matrix: which disagreements change the type read back (#1034)" begin
  # Every engine this file reads back on, MySQL's included since its F1 fixture seeds (#1130 phase 5).
  ids = Set(id for (id, engine) in keys(_EKM_DISAGREEMENTS) if engine in ENGINE_KEYS)
  @test Set(id for (id, _) in keys(_EKR_EXPECTED)) == ids
  # #1147: a cell the engine that departs from its meaning refuses has nothing to read back there
  # (`Cast(points, "numeric(10,1)")` on SQLite); every engine that builds it is recorded.
  builds(id, engine) = _EKM_EXPECTED[(id, engine)].stage === :ok
  @test all(id -> all(e -> !builds(id, e) || haskey(_EKR_EXPECTED, (id, e)), ENGINE_KEYS), ids)
  # A cell is divergent when two engines that read it back give different types.
  divergent = Set(id for id in ids
                  if length(unique(_EKR_EXPECTED[(id, e)].type for e in ENGINE_KEYS if haskey(_EKR_EXPECTED, (id, e)))) > 1)
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
  ("Case float output decimal", "Decimal",  1.5,       true),
  ("Max Cast F float numeric",  "Decimal",  15.0,      true),
  # #1221: a `DecimalField(10, 1)` declaration over operands that fit its scale
  ("Cast int DecimalField(10,1)", "Decimal", 1.0,      true),
  ("Cast Case output DecimalField(10,1) to scale 2", "Decimal", 10.0, true),
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
  # #1221: a `DecimalField` declaration is its `numeric(max_digits, decimal_places)`, so a float under
  # `DecimalField()` (`numeric(10,2)`) or `DecimalField(10, 1)` is the same scaled cast.
  for (label, value) in ("Cast float to scale 1" => 10, "Cast Case float col to scale 0" => 10,
                         "Case F float * 1.5 output scale 1" => 15,
                         "Coalesce F float output decimal" => 15, "Greatest float int output decimal" => 10,
                         "Cast float DecimalField(10,1)" => 10, "Coalesce F float * 1.5 output DecimalField(10,1)" => 15)
    _, base, build = EKM_SHAPES[findfirst(s -> s[1] == label, EKM_SHAPES)]
    for ctx in (:alone, :cte, :subquery)
      @testset "$label | $ctx" begin
        q, name = ekm_query(M, base, build, ctx)
        q.filter(EKM_PK[base] => _EKR_ROW[base])
        # Each engine's expectation, stated: a backend added later gets a missing-row error (#1179).
        if by_engine(postgres = false, sqlite = true, mysql = false)   # MySQL's DECIMAL rounds to the scale
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
        @test string(nameof(typeof(v))) == by_engine(postgres = pg_width, sqlite = "Int64", mysql = "Int64")
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A Case with no output_field reads back as the column its branches are, on every engine (#1262)
# `Case(When(…, then = F(col)))` over a `DurationField`, a `DateField`, a `DateTimeField`, a
# `TimeField` and a `DecimalField`, each `When` true on its pinned row (result 1 has grid `1`, race 1
# is the 2009 race, constructor result 3835 is its own key), projected alone, under a CTE and inside a
# `Subquery`. It must read back as the column itself does: the same Julia type, `==` to it. Before
# #1262 the `Case` recorded no read kind, so SQLite handed back each value's stored text (the interval
# as `"00:01:27.452"`) while PostgreSQL's driver delivered the typed value. Why: the cells agree in the
# unit matrix, so the read-back table above does not visit them.
# ─────────────────────────────────────────────────────────────────────────────
const _EKR_CASE_COLUMN = [
  # label                       column            type
  ("Case untyped interval col", "fastestlaptime", "CompoundPeriod"),
  ("Case untyped date col",     "date",           "Date"),
  ("Case untyped zoned col",    "start_at",       "ZonedDateTime"),
  ("Case untyped time col",     "time",           "Time"),
  ("Case untyped decimal col",  "points",         "Decimal"),
]
@testset "A Case with no output_field reads back as its branches' column (#1262)" begin
  for (label, column, type) in _EKR_CASE_COLUMN
    i = findfirst(s -> s[1] == label, EKM_SHAPES)
    @test i !== nothing
    i === nothing && continue
    _, base, build = EKM_SHAPES[i]
    pk = EKM_PK[base]
    plain = getfield(M, base).objects
    plain.filter(pk => _EKR_ROW[base])
    plain.values("c" => column)
    stored = only(plain.list())[:c]
    for ctx in (:alone, :cte, :subquery)
      @testset "$label | $ctx" begin
        q, name = ekm_query(M, base, build, ctx)
        q.filter(pk => _EKR_ROW[base])
        v = only(q.list())[name]
        @test string(nameof(typeof(v))) == type
        @test v == stored
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A condition as a function's operand reads back as a Bool, on every engine (#1034 step 4)
# `Max(Q(…))`, `Min(Qor(…))`, `Coalesce(Q(…), false)` and a `Case` branch that is a `Q`, projected alone
# and inside a `Subquery` on result 1. Each must come back as a `Bool`, equal to the condition worked
# out in Julia from the row's own `grid` and `points`. Before step 4 the formatter typed no `Q`/`Qor`
# operand, so the read path recorded no kind: SQLite handed back its 0/1 as an `Int64`, and
# PostgreSQL could not run `Max(Q(…))` at all (`max(boolean)` does not exist; it is `BOOL_OR` now).
# Why: the unit matrix records the kind, not what the driver hands back.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A condition as an operand reads back as a Bool (#1034 step 4)" begin
  plain = M.Result.objects
  plain.filter("resultid" => _EKR_ROW[:Result])
  plain.values("grid", "points")
  row = only(plain.list())
  ahead = row[:grid] > 1
  expected = Dict("Max Q" => ahead, "Min Qor" => row[:grid] in (1, 2), "Coalesce Q false" => ahead,
                  "Case then Q" => row[:grid] == 1 ? row[:points] > 10 : false)
  for (label, want) in expected
    i = findfirst(s -> s[1] == label, EKM_SHAPES)
    @test i !== nothing
    i === nothing && continue
    _, base, build = EKM_SHAPES[i]
    for ctx in (:alone, :subquery)
      @testset "$label | $ctx" begin
        q, name = ekm_query(M, base, build, ctx)
        q.filter(EKM_PK[base] => _EKR_ROW[base])
        v = only(q.list())[name]
        @test v isa Bool
        @test v == want
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Date arithmetic is typed outside its render, on every engine (#1034 step 5a)
# On race 1: `Greatest("date", F("date") + 1)` agrees on a date, so it reads back as a `Date` equal to
# the race date plus one day (SQLite's text before); a filter on an alias of `F("date") + Day(1)` binds
# a `Date` as a date and matches the row it should, and refuses a number. Why: the walk's type reaches
# the read path and the binder, so both must hold against a live engine, not only in the SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Date arithmetic reads back and binds as a date (#1034 step 5a)" begin
  plain = M.Race.objects
  plain.filter("raceid" => _EKR_ROW[:Race])
  plain.values("date")
  day = only(plain.list())[:date]
  q = M.Race.objects
  q.filter("raceid" => _EKR_ROW[:Race])
  q.values("g" => PormG.Functions.Greatest("date", PormG.F("date") + 1))
  g = only(q.list())[:g]
  @test g isa Date
  @test g == day + Day(1)
  hit(value) = (q = M.Race.objects; q.filter("raceid" => _EKR_ROW[:Race]);
                q.values("raceid", "next" => PormG.F("date") + Day(1)); q.filter("next__@gt" => value); length(q.list()))
  @test hit(day) == 1
  @test hit(day + Day(1)) == 0
  err = try hit(10); nothing catch e; e end
  @test err isa PormG.InvalidValueError
  @test occursin("projection alias (date)", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# A sized text cast cuts the text where it builds, and is refused on SQLite (#1252)
# On the driver `hamilton`: `Cast("surname", "varchar(3)")` and `Cast("surname", CharField(max_length = 3))`
# render `("Tb"."surname")::varchar(3)` on PostgreSQL and `CAST(… AS CHAR(3))` on MySQL, and read back
# `"Ham"`, and an unsized `char` is one character, `"H"`; SQLite enforces no length, so it refuses
# each. `char(10)` reads back `"Hamilton"` unpadded. `CharField()` declares none and reads back
# the whole `"Hamilton"` on every engine. Why: the unit tests see the SQL, not that the engine cuts it,
# which is the meaning the SQLite refusal stands on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A sized text cast cuts the text where it builds, and is refused on SQLite (#1252)" begin
  surname(target) = (q = M.Driver.objects; q.filter("driverref" => "hamilton");
                     q.values("s" => PormG.Functions.Cast("surname", target)); q)
  for (target, cut) in ("varchar(3)" => "Ham", PormG.Models.CharField(max_length = 3) => "Ham",
                        "char(3)" => "Ham", "char" => "H", "char(10)" => "Hamilton")
    # Each engine's expectation, stated: a backend added later gets a missing-row error (#1179).
    if by_engine(postgres = false, sqlite = true, mysql = false)
      err = try surname(target).list(); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("(#1252)", sprint(showerror, err))
    else
      @test only(surname(target).list())[:s] == cut
    end
  end
  @test only(surname(PormG.Models.CharField()).list())[:s] == "Hamilton"
end

# ─────────────────────────────────────────────────────────────────────────────
# The sized text declarations #1252 did not reach, read back (#1438)
# On the driver `hamilton`: a `SlugField`/`URLField` given `max_length = 3` renders `::varchar(3)` /
# `CHAR(3)` and reads back `"Ham"`; `SlugField()` is `varchar(50)`, which keeps `"Hamilton"`.
# PostgreSQL's `bpchar(3)` and `nchar(3)` are `char(3)` and read back `"Ham"`; MySQL has no such CAST
# target and refuses the name, and SQLite refuses each by #1252. An `EmailField` declares no length and
# reads back the whole `"Hamilton"` on every engine. Why: `nchar` is PostgreSQL grammar, not a catalog
# type, and this is where its meaning is measured rather than assumed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "The Slug/URL, bpchar and nchar casts cut the text where they build (#1438)" begin
  surname(target) = (q = M.Driver.objects; q.filter("driverref" => "hamilton");
                     q.values("s" => PormG.Functions.Cast("surname", target)); q)
  outcome(target) = try only(surname(target).list())[:s] catch e; e end
  for (target, cut) in (PormG.Models.SlugField(max_length = 3) => "Ham", PormG.Models.URLField(max_length = 3) => "Ham",
                        PormG.Models.SlugField() => "Hamilton")
    got = outcome(target)
    if by_engine(postgres = false, sqlite = true, mysql = false)
      @test got isa PormG.QueryBuildError && occursin("(#1252)", sprint(showerror, got))
    else
      @test got == cut
    end
  end
  for target in ("bpchar(3)", "nchar(3)")
    got = outcome(target)
    expect = by_engine(postgres = :cuts, sqlite = :refuses, mysql = :unmapped)
    if expect === :cuts
      @test got == "Ham"
    elseif expect === :refuses
      @test got isa PormG.QueryBuildError && occursin("(#1252)", sprint(showerror, got))
    else
      @test got isa PormG.UnsupportedConnectionError
    end
  end
  @test outcome(PormG.Models.EmailField()) == "Hamilton"
end

# ─────────────────────────────────────────────────────────────────────────────
# A duration window on the right of `*` reads back as the duration it is (#1465)
# On results 1 and 2 (race 18), ordered by `resultid`: result 2's `F("grid") * Lag("fastestlaptime")` is
# its grid times result 1's fastest lap (`1:27.452`). Expected: on PostgreSQL and MySQL it reads back a
# duration equal to that product, as `Lag(…) * F("grid")` does; on SQLite both orders raise
# `QueryBuildError` (#881: a window over a duration has no millisecond form). Why: before #1465 the
# right-hand order was untyped, so SQLite multiplied the duration's `HH:MM:SS` text and returned a
# number, and the read-back rows above could not see it, since their row's `Lag` is NULL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A duration window on the right of `*` reads back as the duration it is (#1465)" begin
  ns(x) = Dates.tons(x)   # a fixed period or a `CompoundPeriod`, whichever the driver delivers
  plain(id, field) = (q = M.Result.objects; q.filter("resultid" => id); q.values(field); only(q.list())[Symbol(field)])
  grid2, lap1 = plain(2, "grid"), plain(1, "fastestlaptime")
  @test lap1 !== missing   # the premise: the row before has a lap time, so `Lag` is not NULL
  window() = PormG.Functions.Lag("fastestlaptime", over = PormG.QueryBuilder.WindowOver(order_by = "resultid"))
  for (side, expr) in (("right", () -> PormG.F("grid") * window()), ("left", () -> window() * PormG.F("grid")))
    @testset "$side" begin
      q = M.Result.objects
      q.filter("resultid__@in" => [1, 2])
      q.values("resultid", "v" => expr())
      q.order_by("resultid")
      if _EKR_ENGINE === :sqlite
        @test_throws PormG.QueryBuildError q.list()
      else
        v = last(q.list())[:v]
        @test v isa Union{Dates.Period,Dates.CompoundPeriod}
        @test ns(v) == grid2 * ns(lap1)
      end
    end
  end
end
