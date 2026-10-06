"""
Unit coverage for the `ArrayField` lookups (#28, part 2): the containment/overlap operators
`__@acontains` (@>), `__@contained_by` (<@) and `__@overlap` (&&), the `__@len` transform, and the
index and slice path segments (`tyre_compounds__0`, `pit_laps__0_2`).

PostgreSQL only, as the field itself is: SQLite has no array type, and every one of these raises
`BackendCapabilityError` there instead of being emulated. The value side reuses the field's
`ArrayFormatter`, so an element is checked by the ELEMENT field's own formatter and the whole list
binds as ONE array literal — what an equality binds.

Sibling coverage: `test_array_field.jl` (the field, its values, equality and the writers);
`test/integration/test_array_field.jl` (the live lookups, on both PostgreSQL drivers).
"""
# julia --project=test/integration test/unit/test_array_lookups.jl

using Test
using PormG
using PormG.Models
import PormG.QueryBuilder: inspect_query

struct _MockPgArrLk28 <: PormG.PormGPostgres end
struct _MockSlArrLk28 <: PormG.PormGSQLite end
const _AL_PG = _MockPgArrLk28()
const _AL_SL = _MockSlArrLk28()

PormG.config["arr_lookup28"] = PormG.Configuration.Settings(
  connections = _AL_PG, change_data = true, db_def_folder = "arr_lookup28",
)

# A race's tyre plan, and the stints run under it: an array column on the base model and one reached
# through a ForeignKey, so both gates in the path walker are exercised.
module ArrayLookupModels
import PormG
import PormG.Models
Race_strategy = Models.Model("race_strategy",
  id             = Models.IDField(),
  team           = Models.CharField(max_length = 100),   # not an array: every type guard's subject
  tyre_compounds = Models.ArrayField(Models.CharField(max_length = 12); size = 3),
  pit_laps       = Models.ArrayField(Models.IntegerField(null = true), default = Int[]),
)
Stint = Models.Model("stint",
  id       = Models.IDField(),
  strategy = Models.ForeignKey("Race_strategy"),
  lap      = Models.IntegerField(),
)
PormG.Models.set_models(@__MODULE__, "arr_lookup28")
end

const _AL = ArrayLookupModels

# Error messages carry ANSI colour on a TTY (and on CI); strip it before matching text.
_plain_al(msg::AbstractString) = replace(msg, r"\e\[[0-9;]*m" => "")
_err_al(f) = try f(); nothing catch e; e end
_msg_al(f) = (e = _err_al(f); e === nothing ? "" : _plain_al(sprint(showerror, e)))

# Build `filter(pairs...)` on the strategy model, project `vals`, and inspect it on PostgreSQL.
function _pg_al(pairs...; vals = ["id"], model = _AL.Race_strategy)
  q = model.objects
  isempty(pairs) || q.filter(pairs...)
  q.values(vals...)
  return inspect_query(q; connection = _AL_PG)
end
# The same build, inspected on SQLite.
function _sl_al(pairs...; vals = ["id"])
  q = _AL.Race_strategy.objects
  isempty(pairs) || q.filter(pairs...)
  q.values(vals...)
  return inspect_query(q; connection = _AL_SL)
end

@testset "ArrayField lookups (#28)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Containment: the three operators render PostgreSQL's array operators
  # Each binds ONE parameter, the array literal of the given list, with no cast: the operators are
  # polymorphic, so the server types it from the column. An empty list is a legal array (`'{}'`).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "@acontains, @contained_by and @overlap render @>, <@ and &&" begin
    r = _pg_al("tyre_compounds__@acontains" => ["SOFT", "MEDIUM"])
    @test occursin("WHERE \"Tb\".\"tyre_compounds\" @> \$1", r[:sql_text])
    @test r[:parameters] == ["{SOFT,MEDIUM}"]

    r = _pg_al("tyre_compounds__@contained_by" => ["SOFT", "MEDIUM", "HARD"])
    @test occursin("WHERE \"Tb\".\"tyre_compounds\" <@ \$1", r[:sql_text])
    @test r[:parameters] == ["{SOFT,MEDIUM,HARD}"]

    r = _pg_al("pit_laps__@overlap" => [12, 30])
    @test occursin("WHERE \"Tb\".\"pit_laps\" && \$1", r[:sql_text])
    @test r[:parameters] == ["{12,30}"]

    # The empty list: every array contains it, and nothing overlaps it — PostgreSQL's answers.
    @test _pg_al("pit_laps__@acontains" => Int[])[:parameters] == ["{}"]
    # A Q node reaches the same render.
    r = _pg_al(PormG.Q("pit_laps__@acontains" => [3]))
    @test occursin("\"Tb\".\"pit_laps\" @> \$1", r[:sql_text]) && r[:parameters] == ["{3}"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Containment: the value is checked by the element field, but `size` is lifted
  # `size` bounds what the column may STORE. `@contained_by` and `@overlap` legitimately ask about a
  # longer list — "does this plan use only dry compounds?" names all three of them and more.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the value goes through the element formatter, without the size bound" begin
    five = ["SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET"]   # tyre_compounds has size = 3
    @test _pg_al("tyre_compounds__@contained_by" => five)[:parameters] ==
          ["{SOFT,MEDIUM,HARD,INTERMEDIATE,WET}"]
    @test _pg_al("tyre_compounds__@overlap" => five)[:parameters] == ["{SOFT,MEDIUM,HARD,INTERMEDIATE,WET}"]
    # An element the element field refuses is a FilterError, as for any bad filter value.
    @test_throws PormG.FilterError _pg_al("pit_laps__@acontains" => ["x"])
    # A text element is quoted by the literal printer where PostgreSQL needs it.
    @test _pg_al("tyre_compounds__@acontains" => ["a b"])[:parameters] == ["{\"a b\"}"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Containment: the value-shape refusals
  # A scalar (even for one element), a NULL element (it never matches under `=`), and a column
  # expression (the operators bind a literal) are each refused at `filter()`, naming the fix.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "value-shape refusals" begin
    e = _err_al(() -> _AL.Race_strategy.objects.filter("tyre_compounds__@acontains" => "SOFT"))
    @test e isa PormG.FilterError
    @test occursin("[\"SOFT\"]", _plain_al(sprint(showerror, e)))
    for nul in ([12, missing], Union{Int,Nothing}[12, nothing])
      e = _err_al(() -> _AL.Race_strategy.objects.filter("pit_laps__@overlap" => nul))
      @test e isa PormG.FilterError
      @test occursin("NULL element", _plain_al(sprint(showerror, e)))
    end
    e = _err_al(() -> _AL.Race_strategy.objects.filter("tyre_compounds__@acontains" => PormG.F("team")))
    @test e isa PormG.FilterError
    @test occursin("not a column expression", _plain_al(sprint(showerror, e)))
    # A 2-tuple — what an ArrayField WRITE accepts — is `@range`'s pair in a filter; the refusal
    # names the Vector spelling instead of pointing at `@range`.
    e = _err_al(() -> _AL.Race_strategy.objects.filter("pit_laps__@overlap" => (12, 30)))
    @test e isa PormG.FilterError
    m = _plain_al(sprint(showerror, e))
    @test occursin("takes a Vector", m) && occursin("[12, 30]", m) && !occursin("@range", m)
    # Every other tuple shape — the three-compound one is the natural spelling — gets the same
    # refusal rather than a raw `MethodError` (none of them matched a method before).
    for t in (("SOFT", "MEDIUM", "HARD"), ("SOFT",), ("SOFT", 1))
      e = _err_al(() -> _AL.Race_strategy.objects.filter("tyre_compounds__@acontains" => t))
      @test e isa PormG.FilterError
      @test occursin("takes a Vector", _plain_al(sprint(showerror, e)))
    end
    # Off the array lookups, a tuple keeps its own refusals: `@range` counts, anything else names it.
    e = _err_al(() -> _AL.Race_strategy.objects.filter("id__@range" => (1, 2, 3)))
    @test e isa PormG.FilterError && occursin("exactly 2 values, got 3", _plain_al(sprint(showerror, e)))
    @test _err_al(() -> _AL.Race_strategy.objects.filter("id__@gt" => (1, 2, 3))) isa PormG.FilterError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Containment: the column must be an array
  # The operators are refused on any other column, and on an INDEX — an element is not an array —
  # while a SLICE is one, so it takes them.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the column must be an ArrayField" begin
    e = _err_al(() -> _pg_al("team__@acontains" => ["Ferrari"]))
    @test e isa PormG.FilterError
    @test occursin("requires an ArrayField column; team is not one", _plain_al(sprint(showerror, e)))
    @test occursin("pit_laps__0 is not one", _msg_al(() -> _pg_al("pit_laps__0__@acontains" => [12])))
    r = _pg_al("pit_laps__0_2__@acontains" => [12])
    @test occursin("\"Tb\".\"pit_laps\"[1:2] @> \$1", r[:sql_text]) && r[:parameters] == ["{12}"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Containment on a projection alias is refused in the caller's own words
  # The renderer reads an ArrayField off the column; a projection alias has none (#618's table).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an alias filter refuses the array operators" begin
    for op in PormG.ARRAY_CONTAINMENT_OPERATORS
      q = _AL.Race_strategy.objects
      q.values("id", "laps" => PormG.QueryBuilder.Count("id"))
      q.filter("laps__@$(op)" => [1])
      e = _err_al(() -> inspect_query(q; connection = _AL_PG))
      @test e isa PormG.FilterError
      @test occursin("@$(op) lookup is not supported on the projection alias", _plain_al(sprint(showerror, e)))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `@len`: `cardinality`, chained like any transform
  # `cardinality` rather than `array_length(col, 1)`, which is NULL for an empty array — so
  # `"pit_laps__@len" => 0` can match one. It projects and orders like the date parts do.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "@len renders cardinality and chains" begin
    r = _pg_al("pit_laps__@len" => 0)
    @test occursin("WHERE cardinality(\"Tb\".\"pit_laps\") = \$1", r[:sql_text]) && r[:parameters] == [0]
    r = _pg_al("pit_laps__@len__@gte" => 2)
    @test occursin("WHERE cardinality(\"Tb\".\"pit_laps\") >= \$1", r[:sql_text]) && r[:parameters] == [2]
    r = _pg_al(vals = ["id", "stops" => "pit_laps__@len"])
    @test occursin("cardinality(\"Tb\".\"pit_laps\") as \"stops\"", r[:sql_text])
    # Over a slice: the slice is an array.
    @test occursin("cardinality(\"Tb\".\"pit_laps\"[2:3]) = \$1", _pg_al("pit_laps__1_3__@len" => 2)[:sql_text])
    # Its right-hand side is a count.
    @test_throws PormG.FilterError _pg_al("pit_laps__@len" => "two")
    # Over a column that is not an array: refused at build, naming the path, before the server could.
    e = _err_al(() -> _pg_al("team__@len" => 2))
    @test e isa PormG.FilterError
    @test occursin("@len transform counts the elements of an ArrayField, and team is not one",
                   _plain_al(sprint(showerror, e)))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `@len`: both spellings render through one ladder (#562, #843)
  # `test_transform_ladder_parity.jl` runs every OTHER transform over date columns, which `@len`
  # refuses by design; this is its row there, on an array column. The string path, `F(...)`, and a
  # transform inside a function's string operand must produce the same SQL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "@len renders the same through both spellings" begin
    via_s = _pg_al(vals = ["id", "x" => "pit_laps__@len"])
    via_f = _pg_al(vals = ["id", "x" => PormG.F("pit_laps__@len")])
    @test via_s[:sql_text] == via_f[:sql_text]
    in_s = _pg_al(vals = ["id", "x" => PormG.Functions.Coalesce("pit_laps__@len", 0)])
    in_f = _pg_al(vals = ["id", "x" => PormG.Functions.Coalesce(PormG.F("pit_laps__@len"), 0)])
    @test in_s[:sql_text] == in_f[:sql_text] && in_s[:parameters] == in_f[:parameters]
    @test occursin("cardinality(\"Tb\".\"pit_laps\")", in_s[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Index and slice: 0-based segments, 1-based subscripts
  # `__0` is the first element (`[1]`) and `__0_2` the half-open slice of the first two (`[1:2]`),
  # as in Django. The bounds are literals, never parameters — only the compared value binds.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an index and a slice render 1-based subscripts" begin
    r = _pg_al("tyre_compounds__0" => "SOFT")
    @test occursin("WHERE \"Tb\".\"tyre_compounds\"[1] = \$1", r[:sql_text]) && r[:parameters] == ["SOFT"]
    r = _pg_al("pit_laps__2" => 30)
    @test occursin("\"Tb\".\"pit_laps\"[3] = \$1", r[:sql_text]) && r[:parameters] == [30]
    r = _pg_al("pit_laps__0_2" => [12, 30])
    @test occursin("\"Tb\".\"pit_laps\"[1:2] = \$1", r[:sql_text]) && r[:parameters] == ["{12,30}"]
    # An out-of-range index is NULL in PostgreSQL; `@isnull` is the way to ask for it.
    @test occursin("\"Tb\".\"pit_laps\"[6] IS NULL", _pg_al("pit_laps__5__@isnull" => true)[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Index: the expression is an ELEMENT, so the element field decides everything after it
  # The value is checked by the element's formatter (an integer element refuses text); a pattern
  # lookup works on a text element, where it is refused on the whole array.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an index takes the element field's lookups and value" begin
    @test_throws PormG.FilterError _pg_al("pit_laps__0" => "x")
    r = _pg_al("tyre_compounds__0__@icontains" => "so")
    @test occursin("\"Tb\".\"tyre_compounds\"[1] ILIKE \$1", r[:sql_text]) && r[:parameters] == ["%so%"]
    r = _pg_al("pit_laps__0__@gte" => 10)
    @test occursin("\"Tb\".\"pit_laps\"[1] >= \$1", r[:sql_text]) && r[:parameters] == [10]
    # The pattern refusal on the whole array now names the lookups that exist — and suggests an index
    # only where that spelling is valid and reads text: not after a slice (a second subscript is
    # refused), and not on a number array (an integer element has no LIKE).
    m = _msg_al(() -> _pg_al("tyre_compounds__@contains" => "SOFT"))
    @test occursin("tyre_compounds__@acontains", m) && occursin("tyre_compounds__0__@contains", m)
    @test !occursin("not available yet", m)
    m = _msg_al(() -> _pg_al("tyre_compounds__0_2__@contains" => "SOFT"))
    @test occursin("tyre_compounds__0_2__@acontains", m) && !occursin("__0_2__0", m)
    m = _msg_al(() -> _pg_al("pit_laps__@contains" => "1"))
    @test occursin("pit_laps__@acontains", m) && !occursin("pit_laps__0__@contains", m)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Index and slice in values(), order_by(), and through a ForeignKey or a CTE
  # The gate sits at both places the walker resolves a column — the first segment and the loop — so a
  # joined or CTE-rooted array takes the same segments as one on the base model.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "projections, ordering, ForeignKey and CTE paths" begin
    r = _pg_al(vals = ["id", "tyre_compounds__0", "pit_laps__0_2"])
    @test occursin("\"Tb\".\"tyre_compounds\"[1] as \"tyre_compounds__0\"", r[:sql_text])
    @test occursin("\"Tb\".\"pit_laps\"[1:2] as \"pit_laps__0_2\"", r[:sql_text])

    q = _AL.Race_strategy.objects; q.values("id"); q.order_by("-pit_laps__0")
    @test occursin("ORDER BY \"Tb\".\"pit_laps\"[1] DESC", inspect_query(q; connection = _AL_PG)[:sql_text])

    r = _pg_al("strategy__pit_laps__0" => 12; vals = ["id", "strategy__tyre_compounds__1"], model = _AL.Stint)
    @test occursin("WHERE \"Tb_1\".\"pit_laps\"[1] = \$1", r[:sql_text]) && r[:parameters] == [12]
    @test occursin("\"Tb_1\".\"tyre_compounds\"[2] as \"strategy__tyre_compounds__1\"", r[:sql_text])
    r = _pg_al("strategy__pit_laps__@overlap" => [12]; model = _AL.Stint)
    @test occursin("\"Tb_1\".\"pit_laps\" && \$1", r[:sql_text]) && r[:parameters] == ["{12}"]
    r = _pg_al("strategy__pit_laps__@len__@gt" => 1; model = _AL.Stint)
    @test occursin("cardinality(\"Tb_1\".\"pit_laps\") > \$1", r[:sql_text])

    q = _AL.Stint.objects
    q.with("st" => _AL.Race_strategy.objects.values("id", "pit_laps"))
    q.filter("st__pit_laps__0" => 12); q.values("id")
    r = inspect_query(q; connection = _AL_PG)
    @test occursin(r"\"R1_1\"\.\"pit_laps\"\[1\] = \$1", r[:sql_text]) && r[:parameters] == [12]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Index and slice: the path refusals
  # One segment only (an element has no path, and a second subscript after a slice is a second
  # DIMENSION to PostgreSQL), digits only, a non-empty slice, and a bound PostgreSQL's integer holds.
  # A lookup missing its `@` keeps the shared hint.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "path refusals" begin
    for (path, needle) in (
        "pit_laps__0__1"          => "takes ONE index",
        "pit_laps__0_2__1"        => "takes ONE index",
        "pit_laps__first"         => "is neither an index",
        "pit_laps__-1"            => "is neither an index",
        "pit_laps__2_1"           => "the slice `2_1` is empty",
        "pit_laps__2_2"           => "the slice `2_2` is empty",
        "pit_laps__99999999999"   => "is out of range",
        "pit_laps__2147483647"    => "is out of range",
      )
      e = _err_al(() -> _pg_al(path => 1))
      @test e isa PormG.QueryBuildError
      @test occursin(needle, _plain_al(sprint(showerror, e)))
    end
    # The largest index that fits: 2147483646 is subscript 2147483647, PostgreSQL's integer maximum.
    @test occursin("[2147483647]", _pg_al("pit_laps__2147483646" => 1)[:sql_text])
    # A slice's upper bound is exclusive and renders as written, so it may BE that maximum — and no
    # more. (The first cut capped it one lower, refusing a valid slice.)
    @test occursin("[1:2147483647]", _pg_al("pit_laps__0_2147483647" => [1])[:sql_text])
    @test occursin("is out of range", _msg_al(() -> _pg_al("pit_laps__0_2147483648" => [1])))
    # `pit_laps__isnull` is a lookup missing its `@`: the shared hint, not the index message.
    @test occursin("requires '@' prefix", _msg_al(() -> _pg_al("pit_laps__isnull" => true)))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A path segment after a column that is not a relation
  # It used to die with "The field 'CharField()' does not have a 'how' property" — the field's
  # display and an internal slot. It now names the column and the segment, and what CAN follow.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a non-relation column names the path it cannot continue" begin
    e = _err_al(() -> _pg_al("team__0" => "x"))
    @test e isa PormG.QueryBuildError
    m = _plain_al(sprint(showerror, e))
    @test occursin("team is not a relation", m) && occursin("with 0", m)
    @test occursin("ArrayField takes an index or slice", m)
    @test !occursin("'how' property", m)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A model never registered through `set_models` takes an index
  # `_build_row_join` read the model's `_module` on entry, typed `::Module`, so a model built by
  # `Models.Model(...)` alone — `_module === nothing` — died with a TypeError before the array gate
  # could answer. The read now sits at its one use, past both gates.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an unregistered model takes an index and a slice" begin
    m = Models.Model("unregistered_strategy_28", id = Models.IDField(),
                     pit_laps = Models.ArrayField(Models.IntegerField()))
    m.connect_key = "arr_lookup28"
    @test m._module === nothing
    q = m.objects; q.filter("pit_laps__0" => 12); q.values("id", "pit_laps__0_2")
    r = inspect_query(q; connection = _AL_PG)
    @test occursin("\"Tb\".\"pit_laps\"[1] = \$1", r[:sql_text]) && r[:parameters] == [12]
    @test occursin("\"Tb\".\"pit_laps\"[1:2] as \"pit_laps__0_2\"", r[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite refuses every one of them
  # SQLite has no array type, so the model cannot be created there; a build against one still
  # reaches these renderers through an unmanaged table, and each refuses by name.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite raises BackendCapabilityError" begin
    for op in PormG.ARRAY_CONTAINMENT_OPERATORS
      @test_throws PormG.BackendCapabilityError _sl_al("pit_laps__@$(op)" => [1])
    end
    @test occursin("@len transform", _msg_al(() -> _sl_al("pit_laps__@len" => 1)))
    @test _err_al(() -> _sl_al("pit_laps__@len" => 1)) isa PormG.BackendCapabilityError
    @test occursin("ArrayField index (`__0`)", _msg_al(() -> _sl_al("pit_laps__0" => 1)))
    @test _err_al(() -> _sl_al("pit_laps__0" => 1)) isa PormG.BackendCapabilityError
    @test occursin("ArrayField slice (`__0_2`)", _msg_al(() -> _sl_al("pit_laps__0_2" => [1])))
    @test _err_al(() -> _sl_al(vals = ["id", "pit_laps__1"])) isa PormG.BackendCapabilityError
  end
end
