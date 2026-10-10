# ==============================================================================
# The expression shapes of the expression-kind matrix (#1034), shared by the unit matrix
# (`test/unit/test_expression_kind_matrix.jl`, mock connections) and its integration read-back
# (`test/integration/test_expression_kind_readback.jl`, the seeded F1 fixture).
#
# A shape is `(label, base, build)`: `base` names the model the query starts from, and `build(mod)`
# returns the node projected — a path `String` or an expression. Written against model names and
# fields that exist in BOTH places, so one table drives both halves: the integration models
# (`test/integration/db_2/models.jl`) and the unit file's mock module, which declares the same models
# with the same field types. A shape is projected in several contexts (alone, after a `When`, under a
# CTE, inside a `Subquery`); a path shape is the one kind the `When` context applies to, because only
# a path can reuse the memo entry a condition leaves (#979).
# ==============================================================================

using Dates

# The primary key of each base model, which the CTE and Subquery contexts correlate on.
const EKM_PK = Dict(:Result => "resultid", :Race => "raceid", :Constructor_results => "constructorresultsid",
                    :New_join_position => "id")

_ekm_over(base) = PormG.QueryBuilder.WindowOver(order_by = EKM_PK[base])

# One correlated single-column subquery over the base model: the row's own value of `e`. `prep!`
# declares what the node needs on the query that projects it (a `Joined` handle's join).
function _ekm_sub(mod, base, e; prep! = nothing)
  s = getfield(mod, base).objects
  prep! === nothing || prep!(s, mod)
  s.filter(EKM_PK[base] => PormG.QueryBuilder.OuterRef(EKM_PK[base]))
  s.values("t" => e)
  s.limit(1)
  return s
end

const _EKM_FN = PormG.Functions
const _EKM_Q = PormG.QueryBuilder

const EKM_SHAPES = Tuple{String,Symbol,Function}[
  # ── column paths: one per stored kind, on the base model and across a foreign key ──────────────
  ("path int",                :Result,              m -> "grid"),
  ("path float",              :Result,              m -> "points"),
  ("path text",               :Result,              m -> "positiontext"),
  ("path interval",           :Result,              m -> "fastestlaptime"),
  ("path decimal",            :Constructor_results, m -> "points"),
  ("path bool",               :New_join_position,   m -> "boolean_field"),
  ("path date",               :Race,                m -> "date"),
  ("path datetime",           :Race,                m -> "start_at"),
  ("path time",               :Race,                m -> "time"),
  ("hop date",                :Result,              m -> "raceid__date"),
  ("hop datetime",            :Result,              m -> "raceid__start_at"),
  ("hop time",                :Result,              m -> "raceid__time"),
  # ── a `Joined(...)` handle (#824): the join it names is declared by `EKM_PREP` ──────────────────
  ("Joined date",             :Result,              m -> _EKM_Q.Joined("rc", "date")),
  ("Joined datetime",         :Result,              m -> _EKM_Q.Joined("rc", "start_at")),
  ("Max Joined date",         :Result,              m -> _EKM_FN.Max(_EKM_Q.Joined("rc", "date"))),
  # ── transforms ─────────────────────────────────────────────────────────────────────────────────
  ("transform @year",         :Race,                m -> "start_at__@year"),
  ("transform @date",         :Race,                m -> "start_at__@date"),
  ("transform @hour",         :Race,                m -> "start_at__@hour"),
  ("ToChar YYYY-MM",          :Race,                m -> _EKM_FN.ToChar("date", "YYYY-MM")),
  ("Extract year",            :Race,                m -> _EKM_FN.Extract("date", "year")),
  # ── F: bare, arithmetic, comparison ───────────────────────────────────────────────────────────
  ("F bare float",            :Result,              m -> _EKM_Q.F("points")),
  ("F bare hop date",         :Result,              m -> _EKM_Q.F("raceid__date")),
  ("F int + int",             :Result,              m -> _EKM_Q.F("grid") + _EKM_Q.F("laps")),
  ("F float * 2",             :Result,              m -> _EKM_Q.F("points") * 2),
  ("F decimal * 2",           :Constructor_results, m -> _EKM_Q.F("points") * 2),
  ("F date + Day(1)",         :Race,                m -> _EKM_Q.F("date") + Day(1)),
  ("F datetime - datetime",   :Race,                m -> _EKM_Q.F("start_at") - _EKM_Q.F("start_at")),
  ("F date - date",           :Race,                m -> _EKM_Q.F("date") - _EKM_Q.F("date")),
  ("F comparison",            :Result,              m -> _EKM_Q.F("grid") > _EKM_Q.F("points")),
  # ── literals ───────────────────────────────────────────────────────────────────────────────────
  ("Value int",               :Result,              m -> _EKM_FN.Value(1)),
  ("Value float",             :Result,              m -> _EKM_FN.Value(1.5)),
  ("Value date",              :Result,              m -> _EKM_FN.Value(Date(2009, 3, 29))),
  ("Value text",              :Result,              m -> _EKM_FN.Value("pole")),
  ("Value bool",              :Result,              m -> _EKM_FN.Value(true)),
  ("Value datetime",          :Result,              m -> _EKM_FN.Value(DateTime(2009, 3, 29, 6))),
  # ── declared types ─────────────────────────────────────────────────────────────────────────────
  ("Cast datetime to date",   :Race,                m -> _EKM_FN.Cast("start_at", "date")),
  ("Cast float to integer",   :Result,              m -> _EKM_FN.Cast("points", "integer")),
  ("Cast int to text",        :Result,              m -> _EKM_FN.Cast("grid", "text")),
  ("Case declared date",      :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("raceid__date"))], output_field = "date")),
  ("Case untyped bool",       :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = true)], default = false)),
  ("Case untyped int",        :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1)], default = 0)),
  ("Case untyped float col",  :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("points"))], default = _EKM_Q.F("points"))),
  # ── aggregates ─────────────────────────────────────────────────────────────────────────────────
  ("Sum int",                 :Result,              m -> _EKM_FN.Sum("grid")),
  ("Sum float",               :Result,              m -> _EKM_FN.Sum("points")),
  ("Sum decimal",             :Constructor_results, m -> _EKM_FN.Sum("points")),
  ("Sum interval",            :Result,              m -> _EKM_FN.Sum("fastestlaptime")),
  ("Avg float",               :Result,              m -> _EKM_FN.Avg("points")),
  ("Avg decimal",             :Constructor_results, m -> _EKM_FN.Avg("points")),
  ("Avg interval",            :Result,              m -> _EKM_FN.Avg("fastestlaptime")),
  ("Count",                   :Result,              m -> _EKM_FN.Count("resultid")),
  ("Max hop date",            :Result,              m -> _EKM_FN.Max("raceid__date")),
  ("Max decimal",             :Constructor_results, m -> _EKM_FN.Max("points")),
  ("Max bool",                :New_join_position,   m -> _EKM_FN.Max("boolean_field")),
  ("Min float",               :Result,              m -> _EKM_FN.Min("points")),
  ("Max of arithmetic",       :Result,              m -> _EKM_FN.Max(_EKM_Q.F("points") * 2)),
  # ── operand-agreeing functions ─────────────────────────────────────────────────────────────────
  ("Coalesce date date",      :Result,              m -> _EKM_FN.Coalesce("raceid__date", "driverid__dob")),
  ("Coalesce float int",      :Result,              m -> _EKM_FN.Coalesce("points", "grid")),
  ("Coalesce int float",      :Result,              m -> _EKM_FN.Coalesce("grid", "points")),
  ("Coalesce bool literal",   :New_join_position,   m -> _EKM_FN.Coalesce("boolean_field", false)),
  ("Greatest datetime",       :Race,                m -> _EKM_FN.Greatest("start_at", "start_at")),
  ("Least decimal",           :Constructor_results, m -> _EKM_FN.Least("points", "points")),
  ("NullIf date",             :Result,              m -> _EKM_FN.NullIf("raceid__date", "driverid__dob")),
  # ── window functions ───────────────────────────────────────────────────────────────────────────
  ("Lag hop date",            :Result,              m -> _EKM_FN.Lag("raceid__date", over = _ekm_over(:Result))),
  ("Lag bool",                :New_join_position,   m -> _EKM_FN.Lag("boolean_field", over = _ekm_over(:New_join_position))),
  ("FirstValue float",        :Result,              m -> _EKM_FN.FirstValue("points", over = _ekm_over(:Result))),
  ("FirstValue decimal",      :Constructor_results, m -> _EKM_FN.FirstValue("points", over = _ekm_over(:Constructor_results))),
  ("Lead hop date",           :Result,              m -> _EKM_FN.Lead("raceid__date", over = _ekm_over(:Result))),
  ("LastValue float",         :Result,              m -> _EKM_FN.LastValue("points", over = _ekm_over(:Result))),
  ("Rank",                    :Result,              m -> _EKM_FN.Rank(over = _ekm_over(:Result))),
  # ── text and numeric functions ─────────────────────────────────────────────────────────────────
  ("Concat text",             :Result,              m -> _EKM_FN.Concat("positiontext", "positiontext")),
  ("Upper text",              :Result,              m -> _EKM_FN.Upper("positiontext")),
  ("Length text",             :Result,              m -> _EKM_FN.Length("positiontext")),
  ("Round float",             :Result,              m -> _EKM_FN.Round("points")),
  ("Round decimal",           :Constructor_results, m -> _EKM_FN.Round("points")),
  ("Abs float",               :Result,              m -> _EKM_FN.Abs("points")),
  ("Abs decimal",             :Constructor_results, m -> _EKM_FN.Abs("points")),
  ("Mod int",                 :Result,              m -> _EKM_FN.Mod("grid", 2)),
  # #1147: over a whole number `Abs`/`Floor`/`Ceil` keep it whole on every engine — a bigint column, and
  # an integer date part (#1135) as well as an integer column.
  ("Abs int",                 :Result,              m -> _EKM_FN.Abs("grid")),
  ("Floor int",               :Result,              m -> _EKM_FN.Floor("grid")),
  ("Ceil int",                :Result,              m -> _EKM_FN.Ceil("grid")),
  ("Floor bigint",            :Result,              m -> _EKM_FN.Floor("resultid")),
  ("Floor year part",         :Race,                m -> _EKM_FN.Floor("date__@year")),
  # ── subqueries ─────────────────────────────────────────────────────────────────────────────────
  ("Subquery Max hop date",   :Result,              m -> _EKM_Q.Subquery(_ekm_sub(m, :Result, _EKM_FN.Max("raceid__date")))),
  ("Subquery Avg float",      :Result,              m -> _EKM_Q.Subquery(_ekm_sub(m, :Result, _EKM_FN.Avg("points")))),
  ("Subquery path decimal",   :Constructor_results, m -> _EKM_Q.Subquery(_ekm_sub(m, :Constructor_results, "points"))),
  ("Exists",                  :Result,              m -> _EKM_Q.Exists(_ekm_sub(m, :Result, "resultid"))),
]

# What a shape needs declared on the query that projects it, keyed by label: a `Joined` handle names
# the alias of a `cjoin_on` join, so every query projecting one — the base query, a CTE body, a
# `Subquery`'s inner query — declares that join first.
_ekm_join_race!(q, mod) = q.cjoin_on(mod.Race; alias = "rc",
                                     on = [_EKM_Q.Joined("rc", "raceid") == _EKM_Q.F("raceid")])
const EKM_PREP = Dict{String,Function}(
  "Joined date" => _ekm_join_race!, "Joined datetime" => _ekm_join_race!, "Max Joined date" => _ekm_join_race!)

"""`true` for a shape whose node is a column path — the shapes the `When` context applies to (#979)."""
ekm_is_path(build, mod) = (n = build(mod); n isa AbstractString && !occursin("__@", n))

"""
    ekm_query(mod, base, build, context; prep! = nothing)

The queryset one matrix cell projects, and the output name its value comes back under. Contexts:
- `:alone` — the shape as the only projection (besides the primary key, which orders the windows);
- `:after_when` — a `Case(When(<path>__@isnull …))` first, so the path reuses the memo entry the
  condition rendered (#979); `nothing` for a non-path shape;
- `:cte` — projected inside a CTE body, read back through the CTE column;
- `:subquery` — projected as the single column of a correlated `Subquery`.
"""
function ekm_query(mod, base::Symbol, build, context::Symbol; prep! = nothing)
  pk = EKM_PK[base]
  model = getfield(mod, base)
  node = build(mod)
  q = model.objects
  prepared(h) = (prep! === nothing || prep!(h, mod); h)
  if context === :alone
    prepared(q)
    q.values(pk, "v" => node)
    return q, :v
  elseif context === :after_when
    node isa AbstractString && !occursin("__@", node) || return nothing
    cond = "c" => _EKM_FN.Case([_EKM_FN.When(node * "__@isnull" => true, then = 1)], default = 0)
    prepared(q)
    q.values(pk, cond, node)
    return q, Symbol(node)
  elseif context === :cte
    q.with("g" => prepared(model.objects).values(pk, "v" => node), join_field = pk => pk, join_type = "INNER")
    q.values(pk, "w" => "g__v")
    return q, :w
  elseif context === :subquery
    q.values(pk, "w" => _EKM_Q.Subquery(_ekm_sub(mod, base, node; prep! = prep!)))
    return q, :w
  end
  error("unknown context $context")
end

const EKM_CONTEXTS = (:alone, :after_when, :cte, :subquery)
