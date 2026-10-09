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
# An ORDER BY on SQLite asks the backend's version for its NULLS placement (#798's order_by case);
# the mock has no driver behind it, so pin one — the stub `test_window_functions.jl` uses.
PormG.backend_sqlite_version(::AggFlagMockSQLite) = 3045000

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
  :LPad     => inner -> LPad(inner, 3, "0"),   # #122
  :RPad     => inner -> RPad(inner, 3, "0"),
  :Floor    => inner -> Floor(inner),
  :Ceil     => inner -> Ceil(inner),
  :Sqrt     => inner -> Sqrt(inner),
  :Exp      => inner -> Exp(inner),
  :Ln       => inner -> Ln(inner),
  :Power    => inner -> Power(inner, Value(2)),
  :Mod      => inner -> Mod(inner, Value(2)),
  # #964: with its own `otherwise`, since a bare `When` is a Case branch and the GROUP BY testset
  # below renders each wrapper as a value. The flag still comes from the WHEN node, through the
  # CASE `_make_when` wraps it in.
  :When     => inner -> When("raceid" => 1, then = inner, otherwise = 0),
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
  ("LPad, the fill",              inner -> LPad("surname", 3, inner)),   # #122
  ("When, otherwise",             inner -> When("raceid" => 1, then = 0, otherwise = inner)),
  ("Case, default",               inner -> Case([When("raceid" => 1, then = 0)], default = inner)),
)

# Exports that wrap nothing an aggregate can reach: a literal, a window spec, and the window family —
# a window function is never an aggregate (`_is_agg(::WindowFunction) = false`), it is evaluated
# after GROUP BY rather than defining one.
const _AGG_NOT_WRAPPERS = (:Value, :WindowOver, :WindowSpec, :Rank, :DenseRank, :RowNumber, :Lag,
                           :Lead, :FirstValue, :LastValue, :NthValue,
                           # #31: a `SearchQuery` wraps the search TEXT, a literal, never a column.
                           :SearchQuery)

# #31: the full-text wrappers. They carry the flag like every wrapper above, but they are PostgreSQL
# only — SQLite refuses them at build — so the rendered GROUP BY check runs them on the PostgreSQL mock
# alone, in a testset of their own.
const _AGG_PG_ONLY_WRAPPERS = Dict{Symbol,Function}(
  :SearchVector   => inner -> SearchVector(inner),
  :SearchRank     => inner -> SearchRank(SearchVector(inner), "senna"),
  :SearchHeadline => inner -> SearchHeadline(inner, "senna"),
)

# ─────────────────────────────────────────────────────────────────────────────
# Enumeration guard: every `PormG.Functions` export is classified
# The guard that stops the next wrapper from missing the flag. Adding an export to
# `PormG.Functions` without placing it in exactly one of the three lists above fails here, naming
# it — the same shape as `test_column_spec.jl`'s "a slot it neither reads nor classifies".
# ─────────────────────────────────────────────────────────────────────────────
@testset "#702: every PormG.Functions export is classified" begin
  exported = Set(n for n in names(PormG.Functions) if n !== :Functions)
  classified = union(Set(_AGG_AGGREGATES), Set(keys(_AGG_WRAPPERS)), Set(_AGG_NOT_WRAPPERS),
                     Set(keys(_AGG_PG_ONLY_WRAPPERS)))
  # An unclassified export is the failure this file exists for; a stale entry is a typo.
  @test setdiff(exported, classified) == Set{Symbol}()
  @test setdiff(classified, exported) == Set{Symbol}()
  # The three lists are disjoint, so no export is classified twice.
  @test length(classified) == length(_AGG_AGGREGATES) + length(_AGG_WRAPPERS) + length(_AGG_NOT_WRAPPERS) +
                              length(_AGG_PG_ONLY_WRAPPERS)
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
  for (name, build) in sort!(collect(_AGG_PG_ONLY_WRAPPERS), by = first)
    @testset "$name (PostgreSQL only)" begin
      @test _is_agg(build(Max("surname"))) === true
      @test _is_agg(build("surname")) === false
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
                 :LTrim => "surname", :RTrim => "surname", :Concat => "surname",
                 :LPad => "surname", :RPad => "surname",   # #122: a number is refused
                 :Cast => "raceid",   # #1028: a float cast to an integer is refused
                 :Round => "raceid")  # #1044: a float rounded to places is refused
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

# #31: the same check for the PostgreSQL-only full-text wrappers, on the PostgreSQL mock.
@testset "#31: a full-text wrapper over an aggregate is left out of GROUP BY" begin
  Model_ = _AGG_FLAG_MODELS[1][2]
  # A bare `SearchVector` is an operand, never a projection; it is rendered here inside `SearchRank`.
  for (name, build) in sort!(collect(_AGG_PG_ONLY_WRAPPERS), by = first)
    name === :SearchVector && continue
    @testset "postgres — $name" begin
      q = Model_.objects
      q.values("raceid", "x" => build(Max("surname")))
      insp = inspect_query(q)
      @test occursin(r"GROUP BY 1\s*$", insp[:sql_text])
      assert_marker_count(insp, :postgres)
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

# ─────────────────────────────────────────────────────────────────────────────
# #798 fixtures. `_plain` strips colour, which is on under CI and off a TTY. `_mixed_err` builds and
# renders, returning the exception or `nothing`.
# ─────────────────────────────────────────────────────────────────────────────
_plain(msg) = replace(msg, r"\e\[[0-9;]*m" => "")
_mixed_err(q) = try
  inspect_query(q)
  nothing
catch e
  e
end

# ─────────────────────────────────────────────────────────────────────────────
# #798: a projection mixing a column and an aggregate needs that column grouped
# The flag above leaves an aggregate-bearing projection out of GROUP BY whole — right for
# `Coalesce(Sum(…), 0)`, wrong for `raceid + SUM(points)`, whose `raceid` is read per group. Beside
# `surname` nothing grouped it: PostgreSQL raised `GroupingError` and SQLite answered with an
# arbitrary row's `raceid`. Each spelling is now refused naming the column, and the same projection
# beside a grouped `raceid` still renders `GROUP BY 1`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#798: a mixed projection reads a column that must be grouped" begin
  shapes = (
    ("arithmetic", () -> F("raceid") + Sum("points")),
    ("Coalesce over F", () -> Coalesce(F("raceid"), Sum("points"))),
    ("Coalesce over a path", () -> Coalesce("raceid", Sum("points"))),
    # The column is in the condition, the aggregate in the branch.
    ("a Case condition", () -> Case([When("raceid__@gt" => 0, then = Sum("points"))], default = 0)),
  )
  for (backend, Model_) in _AGG_FLAG_MODELS
    for (label, mixed) in shapes
      @testset "$backend — $label: refused beside an ungrouped column" begin
        q = Model_.objects
        q.values("surname", "x" => mixed())
        err = _mixed_err(q)
        @test err isa QueryBuildError
        msg = _plain(PormG.error_message(err))
        @test occursin("#798", msg)
        @test occursin("projection x reads the column \"raceid\" outside an aggregate (in its expression)", msg)
        @test occursin("Grouped by: \"Tb\".\"surname\"", msg)
        @test occursin("add \"raceid\" to values(...)", msg)
        @test occursin("Max(\"raceid\")", msg)
      end
      @testset "$backend — $label: builds once the column is grouped" begin
        q = Model_.objects
        q.values("raceid", "x" => mixed())
        insp = inspect_query(q)
        @test occursin(r"GROUP BY 1\s*$", insp[:sql_text])
        assert_marker_count(insp, backend)
      end
    end

    @testset "$backend — a Case branch reading a column over an aggregate alias" begin
      # The condition names the alias `total` (#722, not a column); the branch reads `raceid`.
      q = Model_.objects
      q.values("surname", "total" => Sum("points"),
               "x" => Case([When("total__@gte" => 100, then = Abs("raceid"))], default = 0))
      err = _mixed_err(q)
      @test err isa QueryBuildError
      @test occursin("reads the column \"raceid\"", _plain(PormG.error_message(err)))
    end

    @testset "$backend — a literal is not a column" begin
      # `Value(0)` is bound, and so is a String in a `When`'s `then`/`Case`'s `default` slot — it is
      # a value there, not a path. Nothing to group beside `surname`.
      q = Model_.objects
      q.values("surname", "total" => Sum("points"),
               "x" => Coalesce(Sum("points"), Value(0)),
               "y" => Case([When("total__@gte" => 100, then = "raceid")], default = "none"))
      @test occursin(r"GROUP BY 1\s*$", inspect_query(q)[:sql_text])
    end

    @testset "$backend — a transform: its path or its base column groups it" begin
      q = Model_.objects
      q.values("surname", "x" => F("born__@year") + Max("points"))
      err = _mixed_err(q)
      @test err isa QueryBuildError
      # Spelled as written, so the fix line pastes back.
      @test occursin("add \"born__@year\" to values(...)", _plain(PormG.error_message(err)))
      for grouped in ("born__@year", "born")
        q = Model_.objects
        q.values(grouped, "x" => F("born__@year") + Max("points"))
        @test occursin(r"GROUP BY 1\s*$", inspect_query(q)[:sql_text])
      end
    end

    @testset "$backend — a transform built inside a function argument" begin
      # `Concat("born__@year", …)` holds `EXTRACT(born)` by the time the projection list does — the
      # node a grouped `values("born__@year")` holds, so it is covered. A different transform is not.
      mixed = () -> Concat(Lower("born__@yyyy_mm"), Value(": "), Count("resultid"))
      q = Model_.objects
      q.values("born__@yyyy_mm", "x" => mixed())
      insp = inspect_query(q)
      @test occursin(r"GROUP BY 1\s*$", insp[:sql_text])
      assert_marker_count(insp, backend)
      q = Model_.objects
      q.values("born__@year", "x" => mixed())
      @test _mixed_err(q) isa QueryBuildError
    end

    @testset "$backend — a grouped expression reused whole inside a mixed one" begin
      # Grouped as `rp`, then read whole beside an aggregate: PostgreSQL accepts the grouped
      # expression as a subexpression, so this ran before #798 and must keep building. The match is
      # structural (never `==`, which builds a predicate on these nodes — #541), so a copy that
      # differs by a literal or an operator is still refused.
      for (grouped, mixed, builds) in (
          (() -> F("raceid") * F("points"), () -> F("raceid") * F("points"), true),
          (() -> F("raceid") * F("points"), () -> F("raceid") + F("points"), false),
          (() -> F("raceid") * 2, () -> F("raceid") * 3, false),
          (() -> Case([When("raceid__@gt" => 1, then = 1)], default = 0),
           () -> Case([When("raceid__@gt" => 1, then = 1)], default = 0), true),
          (() -> Case([When("raceid__@gt" => 1, then = 1)], default = 0),
           () -> Case([When("raceid__@gt" => 2, then = 1)], default = 0), false),
          # A binding label built inside a function argument: `born__@yyyy_q` binds nine values.
          (() -> "born__@yyyy_q", () -> Concat("born__@yyyy_q", Value(" "), Count("resultid")), true),
        )
        q = Model_.objects
        q.values("g" => grouped(), "x" => Coalesce(mixed(), Sum("points")))
        if builds
          insp = inspect_query(q)
          @test occursin(r"GROUP BY 1\s*$", insp[:sql_text])
          assert_marker_count(insp, backend)
        else
          @test _mixed_err(q) isa QueryBuildError
        end
      end
    end

    @testset "$backend — a transformed condition needs its base column" begin
      # The #352 sargable rewrite renders `born__@year__@gt` as `"Tb"."born" >= ?`, so a grouped
      # `born__@year` does not cover it — a grouped `born` does.
      mixed = () -> Case([When("born__@year__@gt" => 2000, then = Sum("points"))], default = 0)
      q = Model_.objects
      q.values("born__@year", "x" => mixed())
      err = _mixed_err(q)
      @test err isa QueryBuildError
      @test occursin("reads the column \"born\"", _plain(PormG.error_message(err)))
      q = Model_.objects
      q.values("born", "x" => mixed())
      @test occursin(r"GROUP BY 1\s*$", inspect_query(q)[:sql_text])
    end

    @testset "$backend — a grouped primary key does not cover it" begin
      # PostgreSQL would accept this (functional dependency); PormG does not infer it, as for #194.
      q = Model_.objects
      q.values("resultid", "x" => F("raceid") + Sum("points"))
      @test _mixed_err(q) isa QueryBuildError
    end

    @testset "$backend — a query-level order_by groups it" begin
      q = Model_.objects
      q.values("surname", "x" => F("raceid") + Sum("points"))
      q.order_by("raceid")
      @test occursin("GROUP BY 1, \"Tb\".\"raceid\"", inspect_query(q)[:sql_text])
    end

    @testset "$backend — aggregate() has no group set at all" begin
      err = try
        Model_.objects.aggregate("x" => Coalesce(F("raceid"), Sum("points")); show_query = :sql)
        nothing
      catch e
        e
      end
      @test err isa QueryBuildError
      @test occursin("Grouped by: (none", _plain(PormG.error_message(err)))
    end
  end

  # The guard stops walking at an aggregate CALL, so its list must name every aggregate constructor
  # — a missing one would over-refuse. `_is_agg` is not the question: it is true for a wrapper too.
  @testset "_is_aggregate_call names every aggregate constructor, and no wrapper" begin
    for name in _AGG_AGGREGATES
      @test PormG.QueryBuilder._is_aggregate_call(getfield(PormG.Functions, name)("points"))
    end
    for (name, build) in _AGG_WRAPPERS
      @test !PormG.QueryBuilder._is_aggregate_call(build(Sum("points")))
    end
    @test !PormG.QueryBuilder._is_aggregate_call(F("raceid") + Sum("points"))
  end
end
