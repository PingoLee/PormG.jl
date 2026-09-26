"""
The aggregate flag through wrapping constructors (#702).

`aggregate` is a flag STORED on each function node, and three readers trust it without looking
inside: the GROUP BY decision in `get_select_query`, the HAVING routing of an alias filter
(`_aggregate_alias_leaf`, #692), and the `update()`/`delete()` refusals. Only `F` arithmetic and the
numeric wrappers (`Abs`, `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`) propagated it from their
argument, so `Coalesce(Sum("points"), Value(0))` — the ordinary way to turn an empty group's NULL
into 0 — projected with NO `GROUP BY`. SQLite answered with one row for the whole table, silently;
PostgreSQL rejected the ungrouped column.

Every constructor that wraps an argument now sets `aggregate = _any_agg(args...)` (`types.jl`).
Three things are pinned:

  1. **The enumeration guard.** Every export of `PormG.Functions` is classified — aggregate,
     wrapper, or not a wrapper — and every wrapper must carry the flag over an aggregate argument
     and not over a plain column. A NEW export fails here until it is classified, so a future
     wrapper cannot silently miss the flag the way seven did.
  2. **The SQL.** A wrapped aggregate is grouped, and a filter on its alias renders in HAVING —
     unwrapped and inside `Q` alike — with every marker bound in text order on SQLite.
  3. **The other readers.** `update()`/`delete()` refuse a wrapped-aggregate projection as they
     refuse a bare one, and `.aggregate()` accepts one.

**#722 — an aggregate reached through an alias.** A condition that names a projection alias holds the
NAME: `Case([When("total__@gte" => 100, then = 1)])` over `"total" => Sum("points")` carries the string
`"total"`, so no flag set at construction can see the `SUM` it renders as. It was grouped — `GROUP BY
1, 3`, which both engines reject — and a filter on its alias went to WHERE. The build-time readers now
ask `_resolved_agg`, which adds the aliases a projection's conditions read; the second half of this
file pins the SQL for every spelling of that, and the row-alias control that must stay grouped.

Everything renders through mock connections — no live database.

julia --project=test/integration test/unit/test_aggregate_flag_propagation.jl
"""

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField, CharField, DateField
using PormG.QueryBuilder: inspect_query, _is_agg, OP
using PormG.Functions

include("helper_marker_alignment.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Fixtures: one standalone results model per mock backend. #702 reproduced on both — the missing
# GROUP BY is a wrong answer on SQLite and a driver error on PostgreSQL — and the HAVING copy of a
# binding projection is a positional-parameter question only SQLite can get wrong silently.
# ─────────────────────────────────────────────────────────────────────────────
struct AggFlagMockPostgres <: PormG.PormGPostgres end
struct AggFlagMockSQLite <: PormG.PormGSQLite end

PormG.config["agg_flag_pg"] = PormG.Configuration.Settings(connections = AggFlagMockPostgres(), change_data = true)
PormG.config["agg_flag_sl"] = PormG.Configuration.Settings(connections = AggFlagMockSQLite(), change_data = true)

_agg_flag_model(key) = (m = Model("agg_flag_results", resultid = IDField(), raceid = IntegerField(),
                                   points = FloatField(), surname = CharField(), born = DateField());
                        m.connect_key = key; m)
const _AGG_FLAG_MODELS = ((:postgres, _agg_flag_model("agg_flag_pg")), (:sqlite, _agg_flag_model("agg_flag_sl")))

# ─────────────────────────────────────────────────────────────────────────────
# The classification of `PormG.Functions`
#
# `_AGG_WRAPPERS` maps each wrapping constructor to a builder that puts `inner` in its FIRST
# argument position. `_AGG_WRAPPER_OTHER_SLOTS` covers the wrappers that take the aggregate in some
# other slot too — a later variadic argument, the second operand, a `When`'s `then`/`otherwise`, a
# `Case`'s `default` — because "the flag reads only the first argument" is a mistake a per-argument
# implementation can make.
# ─────────────────────────────────────────────────────────────────────────────
const _AGG_AGGREGATES = (:Sum, :Avg, :Count, :Max, :Min)

const _AGG_WRAPPERS = Dict{Symbol,Function}(
  :Cast     => inner -> Cast(inner, "integer"),
  :Concat   => inner -> Concat(inner, Value("-")),
  :Extract  => inner -> Extract(inner, "year"),
  :ToChar   => inner -> ToChar(inner, "YYYY-MM"),
  :Coalesce => inner -> Coalesce(inner, Value(0)),
  :Greatest => inner -> Greatest(inner, Value(0)),
  :Least    => inner -> Least(inner, Value(0)),
  :Lower    => inner -> Lower(inner),
  :Upper    => inner -> Upper(inner),
  :Length   => inner -> Length(inner),
  :Abs      => inner -> Abs(inner),
  :Round    => inner -> Round(inner, 1),
  :NullIf   => inner -> NullIf(inner, Value(0)),
  :Replace  => inner -> Replace(inner, "a", "b"),
  :Trim     => inner -> Trim(inner),
  :LTrim    => inner -> LTrim(inner),
  :RTrim    => inner -> RTrim(inner),
  :Floor    => inner -> Floor(inner),
  :Ceil     => inner -> Ceil(inner),
  :Sqrt     => inner -> Sqrt(inner),
  :Exp      => inner -> Exp(inner),
  :Ln       => inner -> Ln(inner),
  :Power    => inner -> Power(inner, Value(2)),
  :Mod      => inner -> Mod(inner, Value(2)),
  :When     => inner -> When("raceid" => 1, then = inner),
  :Case     => inner -> Case([When("raceid" => 1, then = inner)]),
)

const _AGG_WRAPPER_OTHER_SLOTS = (
  ("Coalesce, a later argument",  inner -> Coalesce(Value(0), inner)),
  ("Greatest, a later argument",  inner -> Greatest(Value(0), inner)),
  ("Least, a later argument",     inner -> Least(Value(0), inner)),
  ("Concat, a later argument",    inner -> Concat(Value("-"), inner)),
  ("NullIf, the second operand",  inner -> NullIf(Value(0), inner)),
  ("Power, the exponent",         inner -> Power(Value(2), inner)),
  ("Mod, the divisor",            inner -> Mod(Value(10), inner)),
  ("Replace, the search value",   inner -> Replace("surname", inner, "b")),
  ("When, otherwise",             inner -> When("raceid" => 1, then = 0, otherwise = inner)),
  ("Case, default",               inner -> Case([When("raceid" => 1, then = 0)], default = inner)),
)

# Exports that wrap nothing an aggregate can reach: a literal, a window spec, and the window family —
# a window function is never an aggregate (`_is_agg(::WindowFunction) = false`), it is evaluated
# after GROUP BY rather than defining one.
const _AGG_NOT_WRAPPERS = (:Value, :WindowOver, :WindowSpec, :Rank, :DenseRank, :RowNumber, :Lag,
                           :Lead, :FirstValue, :LastValue, :NthValue)

# ─────────────────────────────────────────────────────────────────────────────
# Enumeration guard: every `PormG.Functions` export is classified
# The guard that stops the next wrapper from missing the flag. Adding an export to
# `PormG.Functions` without placing it in exactly one of the three lists above fails here, naming
# it — the same shape as `test_column_spec.jl`'s "a slot it neither reads nor classifies".
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: every PormG.Functions export is classified" begin
  exported = Set(n for n in names(PormG.Functions) if n !== :Functions)
  classified = union(Set(_AGG_AGGREGATES), Set(keys(_AGG_WRAPPERS)), Set(_AGG_NOT_WRAPPERS))
  # An unclassified export is the failure this file exists for; a stale entry is a typo.
  @test setdiff(exported, classified) == Set{Symbol}()
  @test setdiff(classified, exported) == Set{Symbol}()
  # The three lists are disjoint, so no export is classified twice.
  @test length(classified) == length(_AGG_AGGREGATES) + length(_AGG_WRAPPERS) + length(_AGG_NOT_WRAPPERS)
end

# ─────────────────────────────────────────────────────────────────────────────
# Every wrapper carries the flag over an aggregate argument, and only then
# Both halves: `true` over `Sum("points")` is the fix, and `false` over the plain column is what keeps
# a wrapped column grouped — a constructor hard-coding `aggregate = true` would pass the first half
# and put every `Lower("surname")` projection outside GROUP BY.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: a wrapper is an aggregate exactly when its argument is" begin
  for name in _AGG_AGGREGATES
    @testset "$name is an aggregate" begin
      @test _is_agg(getfield(PormG.Functions, name)("points")) === true
    end
  end
  for (name, build) in sort!(collect(_AGG_WRAPPERS), by = first)
    @testset "$name" begin
      @test _is_agg(build(Sum("points"))) === true
      @test _is_agg(build("points")) === false
      # Nested: the flag survives a second wrapper, which is how `Round(Coalesce(Sum(…), 0))` reads.
      @test _is_agg(Round(build(Max("points")))) === true
    end
  end
  for (label, build) in _AGG_WRAPPER_OTHER_SLOTS
    @testset "$label" begin
      @test _is_agg(build(Sum("points"))) === true
      @test _is_agg(build(Value(1))) === false
    end
  end
  @testset "window functions stay non-aggregate" begin
    @test _is_agg(Rank()) === false
    @test _is_agg(Lag("points")) === false
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A `When` condition and the internal transform constructors
# A condition can hold the aggregate — `CASE WHEN COUNT(x) > 3 …` is an aggregate expression, and it
# arrives as an operator, bare or inside `Q`/`Qor`. `DATE`/`QUARTER`/`QUADRIMESTER` are the
# unexported transforms `__@date` etc. build; they wrap an argument the same way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: a When condition and the transform constructors" begin
  agg_cond = OP(Count("resultid"), ">", 3)
  @test _is_agg(When(agg_cond, then = 1)) === true
  @test _is_agg(When(Q(agg_cond), then = 1)) === true
  @test _is_agg(When(Qor(agg_cond, "raceid" => 1), then = 1)) === true
  @test _is_agg(Case([When(agg_cond, then = 1)])) === true
  # A condition on a plain column is not an aggregate.
  @test _is_agg(When("points__@gt" => 10, then = 1)) === false
  @test _is_agg(When(Q("points__@gt" => 10), then = 1)) === false
  for f in (PormG.QueryBuilder.DATE, PormG.QueryBuilder.QUARTER, PormG.QueryBuilder.QUADRIMESTER)
    @test _is_agg(f(Max("born"))) === true
    @test _is_agg(f("born")) === false
  end
  # A self-containing `Q` is a user-buildable cycle (`push!` is documented API): the walk is capped,
  # so building a `When` over one terminates instead of overflowing the stack.
  cyc = Q("raceid" => 1); push!(cyc.filters, cyc)
  @test _is_agg(When(cyc, then = 1)) === false
end

# ─────────────────────────────────────────────────────────────────────────────
# The #702 repro: a wrapped aggregate is grouped
# `values("raceid", "t" => Coalesce(Sum("points"), Value(0)))` printed no GROUP BY. It must print
# `GROUP BY 1` — the one non-aggregate projection — and bind the `Value(0)` once.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: Coalesce over an aggregate groups" begin
  for (backend, Model_) in _AGG_FLAG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("raceid", "t" => Coalesce(Sum("points"), Value(0)))
      insp = inspect_query(q)
      @test occursin(r"GROUP BY 1\s*$", insp[:sql_text])
      assert_marker_count(insp, backend)
      @test insp[:parameters] == [0]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Every wrapper, rendered: the aggregate projection is left out of GROUP BY
# The flag tests above check the node; this checks the reader that turned the missing flag into
# wrong rows. Each wrapper over `Max(...)` projects beside `raceid`, and the statement must group by
# `raceid` alone. `Max` rather than `Sum` so the text and date wrappers get an argument of their
# own type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: every wrapper over an aggregate is left out of GROUP BY" begin
  # The argument each wrapper is rendered over: a column of a type the function accepts.
  arg_for = Dict(:Extract => "born", :ToChar => "born", :Lower => "surname", :Upper => "surname",
                 :Length => "surname", :Replace => "surname", :Trim => "surname",
                 :LTrim => "surname", :RTrim => "surname", :Concat => "surname")
  for (backend, Model_) in _AGG_FLAG_MODELS
    for (name, build) in sort!(collect(_AGG_WRAPPERS), by = first)
      @testset "$backend — $name" begin
        q = Model_.objects
        q.values("raceid", "x" => build(Max(get(arg_for, name, "points"))))
        insp = inspect_query(q)
        # Grouped by the first projection only: the wrapped aggregate is not a grouping key.
        @test occursin(r"GROUP BY 1\s*$", insp[:sql_text])
        assert_marker_count(insp, backend)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A filter on a wrapped-aggregate alias renders in HAVING — unwrapped and inside Q
# Before #702 the two spellings disagreed: the top-level key printed `HAVING` with no GROUP BY,
# and `Q(...)` — which #692 routes by the flag — printed the aggregate into WHERE. Both must now
# print the same HAVING predicate, with the projection's `Value(0)` bound again for the HAVING copy,
# in text order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: a wrapped-aggregate alias filters in HAVING" begin
  for (backend, Model_) in _AGG_FLAG_MODELS
    for (label, pred) in (("top-level", "t__@gt" => 10), ("Q", Q("t__@gt" => 10)))
      @testset "$backend — $label" begin
        q = Model_.objects
        q.values("raceid", "t" => Coalesce(Sum("points"), Value(0)))
        q.filter(pred)
        insp = inspect_query(q)
        sql = insp[:sql_text]
        @test !occursin("WHERE", sql)
        @test occursin(r"GROUP BY 1\s+HAVING \(?COALESCE\(SUM\(\"Tb\"\.\"points\"\), \S+\) > \S+\)?\s*$", sql)
        assert_marker_count(insp, backend)
        # SELECT's `0`, HAVING's own `0`, then the comparison value.
        backend === :sqlite && assert_bound_in_text_order(insp, Any[0, 0, 10])
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The other readers of the flag: update()/delete() refuse, aggregate() accepts
# `update()` and `delete()` refuse a grouped projection because GROUP BY makes their target
# ambiguous; a wrapped aggregate groups exactly as a bare one does, so it is refused the same way.
# `.aggregate(...)` required the flag and refused `Coalesce(Sum(…), 0)` as "not an aggregate
# function"; it is accepted now, and renders with no GROUP BY.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: update/delete refuse and aggregate() accepts a wrapped aggregate" begin
  for (backend, Model_) in _AGG_FLAG_MODELS
    @testset "$backend" begin
      # Filtered, so the refusal under test is the GROUP BY one — an unfiltered update()/delete() is
      # refused for "requires a filter" whether or not the flag is set, and would prove nothing.
      q = Model_.objects
      q.filter("raceid" => 1)
      q.values("t" => Coalesce(Sum("points"), Value(0)))
      err = @test_throws UnsafeMutationError q.update("points" => 1.0)
      @test occursin("GROUP BY", err.value.msg)
      q = Model_.objects
      q.filter("raceid" => 1)
      q.values("t" => Coalesce(Sum("points"), Value(0)))
      err = @test_throws UnsafeMutationError q.delete()
      @test occursin("GROUP BY", err.value.msg)

      sql = Model_.objects.aggregate("t" => Coalesce(Sum("points"), Value(0)); show_query = :sql)
      @test occursin(r"COALESCE\(SUM\(\"Tb\"\.\"points\"\), \S+\)", sql)
      @test !occursin("GROUP BY", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #722 fixtures: a condition that reads an aggregate ALIAS
# `_big()` is the issue's own projection — a `Case` whose `When` names the alias `total`, which the
# render resolves to `SUM("Tb"."points")`. `_flat` puts the multi-line CASE the renderer prints on
# one line, so a pattern can span it. `_pg_text_order` is the querybuilder skill's cross-backend
# differential: PostgreSQL numbers `$N` as it binds, so its markers read left to right are the
# authoritative text order, and SQLite's flattened vector must equal it.
# ─────────────────────────────────────────────────────────────────────────────
_big() = Case([When("total__@gte" => 100, then = 1)], default = 0)
_flat(insp) = replace(insp[:sql_text], r"\s+" => " ")
_pg_text_order(insp) = [insp[:parameters][parse(Int, m.match[2:end])] for m in eachmatch(r"\$\d+", insp[:sql_text])]

# ─────────────────────────────────────────────────────────────────────────────
# #722: a projection whose condition reads an aggregate alias is not grouped
# The issue printed `GROUP BY 1, 3` — position 3 is `CASE WHEN SUM(…)`, and both engines reject an
# aggregate in GROUP BY. Every spelling that reaches the alias must group by the plain column alone:
# the condition bare or inside `Q`, a standalone `When(otherwise=)`, a wrapper around the `Case`, a
# chain of two aliases, and — with no plain column at all — no GROUP BY, as for a bare aggregate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#722: a projection reading an aggregate alias is not grouped" begin
  shapes = (
    ("Case over the alias", r"GROUP BY 1\s*$",
     q -> q.values("raceid", "total" => Sum("points"), "big" => _big())),
    ("standalone When(otherwise=)", r"GROUP BY 1\s*$",
     q -> q.values("raceid", "total" => Sum("points"),
                   "big" => When("total__@gte" => 100, then = 1, otherwise = 0))),
    ("the condition inside Q", r"GROUP BY 1\s*$",
     q -> q.values("raceid", "total" => Sum("points"),
                   "big" => Case([When(Q("total__@gte" => 100), then = 1)], default = 0))),
    ("a wrapper around the Case", r"GROUP BY 1\s*$",
     q -> q.values("raceid", "total" => Sum("points"), "big" => Coalesce(_big(), Value(0)))),
    # `flag` reads `big`, which reads `total`: the aggregate is two aliases away.
    ("a chain of two aliases", r"GROUP BY 1\s*$",
     q -> q.values("raceid", "total" => Sum("points"), "big" => _big(),
                   "flag" => Case([When("big" => 1, then = 5)], default = 6))),
  )
  for (backend, Model_) in _AGG_FLAG_MODELS
    for (label, grouped, build) in shapes
      @testset "$backend — $label" begin
        q = Model_.objects
        build(q)
        insp = inspect_query(q)
        @test occursin(grouped, insp[:sql_text])
        # The aggregate really is in the statement, read through the alias — not dropped. A `Q`
        # condition prints parenthesized: `WHEN (SUM(…) >= ?)`.
        @test occursin(r"CASE WHEN \(?SUM\(\"Tb\"\.\"points\"\) >= ", _flat(insp))
        assert_marker_count(insp, backend)
      end
    end
    @testset "$backend — no plain column: no GROUP BY at all" begin
      # `GROUP BY 2` before: a statement of aggregates alone is one row for the whole table.
      q = Model_.objects
      q.values("total" => Sum("points"), "big" => _big())
      insp = inspect_query(q)
      @test !occursin("GROUP BY", insp[:sql_text])
      assert_marker_count(insp, backend)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #722 control: a condition that reads a ROW alias stays grouped
# The resolver must look at what the alias projects, not merely that an alias is read. `yr` is
# `F("raceid") + 1`, one value per row, so a `Case` over it is a row expression and is grouped
# exactly as before: `GROUP BY 1, 3, 4`. A resolver that treated every alias read as an aggregate
# would drop 3 and 4 and pass every test above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#722 control: a condition on a row alias stays grouped" begin
  for (backend, Model_) in _AGG_FLAG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("raceid", "total" => Sum("points"), "yr" => F("raceid") + 1,
               "c" => Case([When("yr" => 2, then = 1)], default = 0))
      insp = inspect_query(q)
      @test occursin(r"GROUP BY 1, 3, 4\s*$", insp[:sql_text])
      assert_marker_count(insp, backend)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #722: a filter on that alias filters groups — top-level and inside Q
# Before, both spellings printed the `CASE WHEN SUM(…)` into WHERE, which both engines reject. It is
# an aggregate, so it goes to HAVING, where the projection renders afresh (#595) and binds its three
# values again ahead of the comparison value: SELECT's 100/1/0, HAVING's 100/1/0, then 1. The
# cross-backend differential checks that order independently of the literal list.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#722: a filter on an alias that reads an aggregate goes to HAVING" begin
  for (label, pred) in (("top-level", "big" => 1), ("Q", Q("big" => 1)))
    insp = Dict{Symbol,Any}()
    for (backend, Model_) in _AGG_FLAG_MODELS
      @testset "$backend — $label" begin
        q = Model_.objects
        q.values("raceid", "total" => Sum("points"), "big" => _big())
        q.filter(pred)
        insp[backend] = inspect_query(q)
        sql = _flat(insp[backend])
        @test !occursin("WHERE", sql)
        @test occursin(r"GROUP BY 1 HAVING \(?CASE WHEN SUM\(\"Tb\"\.\"points\"\) >= \S+ THEN \S+ ELSE \S+ END = \S+\)?\s*$", sql)
        assert_marker_count(insp[backend], backend)
        backend === :sqlite && assert_bound_in_text_order(insp[backend], Any[100, 1, 0, 100, 1, 0, 1])
      end
    end
    @testset "$label — SQLite binds in PostgreSQL's text order" begin
      @test insp[:sqlite][:parameters] == _pg_text_order(insp[:postgres])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #722: a mixed Q splits between WHERE and HAVING; a mixed Qor is refused
# #692's split reads the same test as the top-level branch, so the row term filters rows and the
# alias term filters groups — the `raceid` value binds in WHERE, between the SELECT and HAVING runs.
# An OR cannot be split between the two clauses, so a mixed `Qor` is refused at build time with
# #692's message rather than printed into WHERE.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#722: a mixed Q splits and a mixed Qor is refused" begin
  insp = Dict{Symbol,Any}()
  for (backend, Model_) in _AGG_FLAG_MODELS
    @testset "$backend — Q" begin
      q = Model_.objects
      q.values("raceid", "total" => Sum("points"), "big" => _big())
      q.filter(Q("big" => 1, "raceid" => 5))
      insp[backend] = inspect_query(q)
      sql = _flat(insp[backend])
      @test occursin(r"WHERE \"Tb\"\.\"raceid\" = \S+ GROUP BY 1 HAVING CASE WHEN SUM\(", sql)
      assert_marker_count(insp[backend], backend)
      backend === :sqlite && assert_bound_in_text_order(insp[backend], Any[100, 1, 0, 5, 100, 1, 0, 1])
    end
    @testset "$backend — Qor" begin
      q = Model_.objects
      q.values("raceid", "total" => Sum("points"), "big" => _big())
      q.filter(Qor("big" => 1, "raceid" => 5))
      err = @test_throws QueryBuildError inspect_query(q)
      @test occursin("#692", err.value.msg)
    end
  end
  @testset "Q — SQLite binds in PostgreSQL's text order" begin
    @test insp[:sqlite][:parameters] == _pg_text_order(insp[:postgres])
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #722: an alias cycle terminates before the render reports it
# `a` reads `b` and `b` reads `a`. No statement can mean that — whichever renders first names an
# alias not yet projected, and the render raises `UnknownFieldError` — but the resolver runs BEFORE
# that render, at the GROUP BY decision, so it must return rather than recurse forever and turn the
# real error into a `StackOverflowError`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#722: an alias cycle terminates" begin
  for (backend, Model_) in _AGG_FLAG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("raceid", "a" => Case([When("b" => 1, then = 1)], default = 0),
               "b" => Case([When("a" => 1, then = 1)], default = 0))
      err = @test_throws UnknownFieldError inspect_query(q)
      # The render's own report: `a` renders first and names `b`, not yet projected. The name is
      # colorized in the message, so strip ANSI before matching — CI renders with color on.
      @test occursin("the column b not found", replace(err.value.msg, r"\e\[[0-9;]*m" => ""))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #722 side effect: a projected OuterRef reaches the renderer
# The GROUP BY decision read `.aggregate` straight off the node, and `OuterRefObject` has no such
# slot, so `values("x" => OuterRef(…))` died there with a raw `FieldError`. The resolver asks
# `_is_agg`, which answers `false` for it, so the projection now reaches the renderer: outside a
# subquery that is the typed `QueryBuildError` the renderer owns, and inside one the outer column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#722: a projected OuterRef is refused or rendered, not a FieldError" begin
  for (backend, Model_) in _AGG_FLAG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("raceid", "x" => OuterRef("raceid"))
      err = @test_throws QueryBuildError inspect_query(q)
      # The renderer's refusal, not some other `QueryBuildError` a projection can raise.
      @test occursin("correlated subquery", err.value.msg)

      # `limit(1)`, so the subquery is a scalar and does not warn that it may match several rows.
      inner = Model_.objects
      inner.filter("raceid" => OuterRef("raceid"))
      inner.values("o" => OuterRef("points"))
      inner.limit(1)
      q = Model_.objects
      q.values("raceid", "s" => Subquery(inner))
      @test occursin(r"\(SELECT \"Tb\"\.\"points\" as \"o\" FROM", _flat(inspect_query(q)))
    end
  end
end
