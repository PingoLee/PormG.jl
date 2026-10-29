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
using TimeZones

# The primary key of each base model, which the CTE and Subquery contexts correlate on.
const EKM_PK = Dict(:Result => "resultid", :Race => "raceid", :Constructor_results => "constructorresultsid",
                    :New_join_position => "id", :Field_validation_scratch => "id")

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
# #1200: a zoned literal, 2021-01-01 00:30 at UTC+2 (2020-12-31 22:30 UTC).
const _EKM_ZDT = ZonedDateTime(DateTime(2021, 1, 1, 0, 30), FixedTimeZone("UTC+2", 7200))

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
  # #1337: QUARTER, an integer on every engine that has it (SQLite has no `EXTRACT` quarter)
  ("Extract quarter",         :Race,                m -> _EKM_FN.Extract("date", "quarter")),
  ("Sum Extract quarter",     :Race,                m -> _EKM_FN.Sum(_EKM_FN.Extract("date", "quarter"))),
  ("Extract quarter / 2",     :Race,                m -> _EKM_FN.Extract("date", "quarter") / 2),
  # ── F: bare, arithmetic, comparison ───────────────────────────────────────────────────────────
  ("F bare float",            :Result,              m -> _EKM_Q.F("points")),
  ("F bare hop date",         :Result,              m -> _EKM_Q.F("raceid__date")),
  ("F int + int",             :Result,              m -> _EKM_Q.F("grid") + _EKM_Q.F("laps")),
  ("F float * 2",             :Result,              m -> _EKM_Q.F("points") * 2),
  ("F decimal * 2",           :Constructor_results, m -> _EKM_Q.F("points") * 2),
  ("F date + Day(1)",         :Race,                m -> _EKM_Q.F("date") + Day(1)),
  ("F datetime - datetime",   :Race,                m -> _EKM_Q.F("start_at") - _EKM_Q.F("start_at")),
  ("F date - date",           :Race,                m -> _EKM_Q.F("date") - _EKM_Q.F("date")),
  # #1460 (review): the day count with a date literal on the right
  ("F date - date literal",   :Race,                m -> _EKM_Q.F("date") - Date(2009, 3, 1)),
  ("F comparison",            :Result,              m -> _EKM_Q.F("grid") > _EKM_Q.F("points")),
  # #1034 step 5a: each arm of the render's F temporal arithmetic, so the walk's answer for it is a cell
  ("F date + Hour(1)",        :Race,                m -> _EKM_Q.F("date") + Hour(1)),
  ("F datetime - Hour(1)",    :Race,                m -> _EKM_Q.F("start_at") - Hour(1)),
  ("F date + 1",              :Race,                m -> _EKM_Q.F("date") + 1),
  ("F date + int col",        :Race,                m -> _EKM_Q.F("date") + _EKM_Q.F("year")),
  ("F date - int col",        :Race,                m -> _EKM_Q.F("date") - _EKM_Q.F("year")),
  ("F interval + interval",   :Result,              m -> _EKM_Q.F("fastestlaptime") + _EKM_Q.F("fastestlaptime")),
  ("F interval * 2",          :Result,              m -> _EKM_Q.F("fastestlaptime") * 2),
  ("F interval / int col",    :Result,              m -> _EKM_Q.F("fastestlaptime") / _EKM_Q.F("grid")),
  ("F int col * interval",    :Result,              m -> _EKM_Q.F("grid") * _EKM_Q.F("fastestlaptime")),
  ("F hop date + interval",   :Result,              m -> _EKM_Q.F("raceid__date") + _EKM_Q.F("fastestlaptime")),
  ("F hop datetime + interval", :Result,            m -> _EKM_Q.F("raceid__start_at") + _EKM_Q.F("fastestlaptime")),
  ("F @year + 1",             :Race,                m -> _EKM_Q.F("start_at__@year") + 1),
  ("Max F datetime - datetime", :Race,              m -> _EKM_FN.Max(_EKM_Q.F("start_at") - _EKM_Q.F("start_at"))),
  ("Abs F date - date",       :Race,                m -> _EKM_FN.Abs(_EKM_Q.F("date") - _EKM_Q.F("date"))),
  ("Coalesce F date + Hour(1), date", :Race,        m -> _EKM_FN.Coalesce(_EKM_Q.F("date") + Hour(1), "date")),
  # ── literals ───────────────────────────────────────────────────────────────────────────────────
  ("Value int",               :Result,              m -> _EKM_FN.Value(1)),
  ("Value float",             :Result,              m -> _EKM_FN.Value(1.5)),
  ("Value date",              :Result,              m -> _EKM_FN.Value(Date(2009, 3, 29))),
  ("Value text",              :Result,              m -> _EKM_FN.Value("pole")),
  ("Value bool",              :Result,              m -> _EKM_FN.Value(true)),
  ("Value datetime",          :Result,              m -> _EKM_FN.Value(DateTime(2009, 3, 29, 6))),
  # #1316: a duration literal, ordered or filtered by its alias; a month has no fixed length
  ("Value interval",          :Result,              m -> _EKM_FN.Value(Hour(100))),
  ("Value interval month",    :Result,              m -> _EKM_FN.Value(Month(1))),
  ("Case interval literals",  :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = Hour(100))], default = Hour(2))),
  # ── declared types ─────────────────────────────────────────────────────────────────────────────
  ("Cast datetime to date",   :Race,                m -> _EKM_FN.Cast("start_at", "date")),
  ("Cast float to integer",   :Result,              m -> _EKM_FN.Cast("points", "integer")),
  ("Cast int to text",        :Result,              m -> _EKM_FN.Cast("grid", "text")),
  ("Case declared date",      :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("raceid__date"))], output_field = "date")),
  ("Case untyped bool",       :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = true)], default = false)),
  ("Case untyped int",        :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1)], default = 0)),
  ("Case untyped float col",  :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("points"))], default = _EKM_Q.F("points"))),
  # #1262: a `Case` with no `output_field` over one stored kind has that kind, as `Coalesce` over it has
  ("Case untyped interval col", :Result,            m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("fastestlaptime"))])),
  ("Case untyped date col",   :Race,                m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("date"))])),
  ("Case untyped zoned col",  :Race,                m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("start_at"))])),
  ("Case untyped time col",   :Race,                m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("time"))])),
  ("Case untyped decimal col", :Constructor_results, m -> _EKM_FN.Case([_EKM_FN.When("constructorresultsid" => 3835, then = _EKM_Q.F("points"))])),
  # #1194: the temporal and binary cast names, which `_sql_type_field` maps to no field yet
  ("Cast datetime to timestamp", :Race,             m -> _EKM_FN.Cast("start_at", "timestamp")),
  ("Cast datetime to timestamptz", :Race,           m -> _EKM_FN.Cast("start_at", "timestamptz")),
  ("Cast datetime to time",   :Race,                m -> _EKM_FN.Cast("start_at", "time")),
  ("Cast interval to interval", :Result,            m -> _EKM_FN.Cast("fastestlaptime", "interval")),
  ("Cast text to bytea",      :Result,              m -> _EKM_FN.Cast("positiontext", "bytea")),
  ("Cast text to blob",       :Result,              m -> _EKM_FN.Cast("positiontext", "blob")),
  ("Coalesce declared timestamp", :Race,            m -> _EKM_FN.Coalesce("start_at", "start_at"; output_field = "timestamp")),
  # #1311: intervals SQLite holds only as their text, with no millisecond form, ordered or filtered by alias
  ("Lag interval",            :Result,              m -> _EKM_FN.Lag("fastestlaptime", over = _ekm_over(:Result))),
  ("NullIf interval",         :Result,              m -> _EKM_FN.NullIf("fastestlaptime", _EKM_Q.F("fastestlaptime"))),
  ("Max Case interval col",   :Result,              m -> _EKM_FN.Max(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("fastestlaptime"))]))),
  # #1459: a side of F arithmetic the render types through `_side_function_kind` — a window value
  # function over a temporal value, and a time cast or `Case` beside a duration — recorded before the
  # side readers moved from the read-kind policy onto the walk.
  ("Lag Cast ts + 1",         :Result,              m -> _EKM_FN.Lag(_EKM_FN.Cast("raceid__start_at", "timestamp"), over = _ekm_over(:Result)) + 1),
  ("Lag Case date col + 1",   :Result,              m -> _EKM_FN.Lag(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("raceid__date"))]), over = _ekm_over(:Result)) + 1),
  ("Lag Cast interval * 2",   :Result,              m -> _EKM_FN.Lag(_EKM_FN.Cast("fastestlaptime", "interval"), over = _ekm_over(:Result)) * 2),
  ("Lag Case interval col * grid", :Result,         m -> _EKM_FN.Lag(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("fastestlaptime"))]), over = _ekm_over(:Result)) * _EKM_Q.F("grid")),
  ("grid * Lag Case interval col", :Result,         m -> _EKM_Q.F("grid") * _EKM_FN.Lag(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("fastestlaptime"))]), over = _ekm_over(:Result))),
  ("Lag F ts - ts * 2",       :Result,              m -> _EKM_FN.Lag(_EKM_Q.F("raceid__start_at") - _EKM_Q.F("raceid__start_at"), over = _ekm_over(:Result)) * 2),
  ("F interval * Cast time",  :Result,              m -> _EKM_Q.F("fastestlaptime") * _EKM_FN.Cast("raceid__start_at", "time")),
  ("Cast time * F interval",  :Result,              m -> _EKM_FN.Cast("raceid__start_at", "time") * _EKM_Q.F("fastestlaptime")),
  ("F interval * Case time col", :Result,           m -> _EKM_Q.F("fastestlaptime") * _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("raceid__time"))])),
  ("F interval / Cast time",  :Result,              m -> _EKM_Q.F("fastestlaptime") / _EKM_FN.Cast("raceid__start_at", "time")),
  # #1307: such a `Case` as the date side of F temporal arithmetic, as `F("date")` is above
  ("Case untyped date col + 1", :Race,              m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("date"))]) + 1),
  ("Case untyped date col - date", :Race,           m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("date"))]) - _EKM_Q.F("date")),
  ("Case untyped zoned col + interval", :Race,      m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("start_at"))]) + (_EKM_Q.F("start_at") - _EKM_Q.F("start_at"))),
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
  # a `default` stands in for the rows with no previous value; the window keeps its operand's kind
  ("Lag date default date",   :Race,                m -> _EKM_FN.Lag("date", default = _EKM_Q.F("date"), over = _ekm_over(:Race))),
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
  # #1147: the `:promoting` functions over an integer, whose PostgreSQL cell is the one phase 3 checks
  ("Abs int",                 :Result,              m -> _EKM_FN.Abs("grid")),
  ("Abs bigint",              :Result,              m -> _EKM_FN.Abs("resultid")),
  ("Floor int",               :Result,              m -> _EKM_FN.Floor("grid")),
  ("Ceil int",                :Result,              m -> _EKM_FN.Ceil("grid")),
  # #1196: `Round` over an integer means that integer (its operand's type, as for a float or a decimal)
  ("Round int",               :Result,              m -> _EKM_FN.Round("grid")),
  ("Round int places",        :Result,              m -> _EKM_FN.Round("grid", 1)),
  ("Round bigint",            :Result,              m -> _EKM_FN.Round("resultid")),
  ("Round int / 2",           :Result,              m -> _EKM_FN.Round("grid") / 2),
  ("Floor year part",         :Race,                m -> _EKM_FN.Floor(_EKM_FN.Extract("date", "year"))),
  # #1121: the rest of the computed-number family — over a float, a decimal and an integer — whose
  # type is Django's `output_field`: its operand's for `Floor`/`Ceil`, a float or a decimal for the
  # `NumericOutputFieldMixin` functions (`Avg`, `Sqrt`, `Exp`, `Ln`, `Power`)
  ("Avg int",                 :Result,              m -> _EKM_FN.Avg("grid")),
  ("Floor float",             :Result,              m -> _EKM_FN.Floor("points")),
  ("Ceil float",              :Result,              m -> _EKM_FN.Ceil("points")),
  ("Floor decimal",           :Constructor_results, m -> _EKM_FN.Floor("points")),
  ("Sqrt float",              :Result,              m -> _EKM_FN.Sqrt("points")),
  ("Sqrt int",                :Result,              m -> _EKM_FN.Sqrt("grid")),
  ("Exp int",                 :Result,              m -> _EKM_FN.Exp("grid")),
  ("Ln float",                :Result,              m -> _EKM_FN.Ln("points")),
  ("Power float",             :Result,              m -> _EKM_FN.Power("points", 2)),
  ("Power int",               :Result,              m -> _EKM_FN.Power("grid", 2)),
  # #1147 step 2: each refusal against the engine that departs from its meaning, and `Sum` of a
  # `bigint`, which PostgreSQL widens to `numeric`
  ("Cast bool to text",       :New_join_position,   m -> _EKM_FN.Cast("boolean_field", "text")),
  ("Cast float to text",      :Result,              m -> _EKM_FN.Cast("points", "text")),
  ("Cast decimal to text",    :Constructor_results, m -> _EKM_FN.Cast("points", "text")),
  ("Cast decimal to integer", :Constructor_results, m -> _EKM_FN.Cast("points", "integer")),
  ("Cast float to scale 1",   :Result,              m -> _EKM_FN.Cast("points", "numeric(10,1)")),
  ("Concat float",            :Result,              m -> _EKM_FN.Concat("positiontext", "points")),
  ("Sum bigint",              :Result,              m -> _EKM_FN.Sum("resultid")),
  ("Sum bigint / 2",          :Result,              m -> _EKM_FN.Sum("resultid") / 2),
  ("Cast Sum bigint / 2 int", :Result,              m -> _EKM_FN.Cast(_EKM_FN.Sum("resultid") / 2, "integer")),
  ("Sum Case int",            :Result,              m -> _EKM_FN.Sum(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1)], default = 0))),
  ("Sum F int + 1",           :Result,              m -> _EKM_FN.Sum(_EKM_Q.F("grid") + 1)),
  ("F int / int",             :Result,              m -> _EKM_Q.F("grid") / _EKM_Q.F("laps")),
  ("Floor F int + 1",         :Result,              m -> _EKM_FN.Floor(_EKM_Q.F("grid") + 1)),
  # #1153: the bitwise operators and shifts are integers to the walk, and so is a `Subquery` over one
  ("F int & int",             :Result,              m -> _EKM_Q.F("grid") & 3),
  ("F int << 1",              :Result,              m -> _EKM_Q.F("grid") << 1),
  ("Floor F int & 3",         :Result,              m -> _EKM_FN.Floor(_EKM_Q.F("grid") & 3)),
  ("Sum F bigint << 1",       :Result,              m -> _EKM_FN.Sum(_EKM_Q.F("resultid") << 1)),
  # #1111, #1034 phase 3 step 2a: a `Sum` over an operand the walk does not type (`EXTRACT(EPOCH …)`
  # has no stated type; SQLite has no such part), divided — whether PostgreSQL's quotient is the
  # integer one depends on a type the walk cannot name
  ("Sum F bigint + epoch / 2", :Race,               m -> _EKM_FN.Sum(_EKM_Q.F("raceid") + _EKM_FN.Extract("start_at", "EPOCH")) / 2),
  ("Sum F int + epoch / 2",   :Race,                m -> _EKM_FN.Sum(_EKM_Q.F("year") + _EKM_FN.Extract("start_at", "EPOCH")) / 2),
  ("Cast Sum F bigint + epoch / 2 int", :Race,      m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("raceid") + _EKM_FN.Extract("start_at", "EPOCH")) / 2, "integer")),
  ("Cast Sum F int + epoch / 2 int", :Race,         m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("year") + _EKM_FN.Extract("start_at", "EPOCH")) / 2, "integer")),
  ("Cast Sum F bigint + epoch / 2.0 int", :Race,    m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("raceid") + _EKM_FN.Extract("start_at", "EPOCH")) / 2.0, "integer")),
  # … a rounding function between the quotient and the cast, and a divisor that is no literal
  ("Cast Round Sum F int + epoch / 2 int", :Race,   m -> _EKM_FN.Cast(_EKM_FN.Round(_EKM_FN.Sum(_EKM_Q.F("year") + _EKM_FN.Extract("start_at", "EPOCH")) / 2), "integer")),
  ("Cast Sum F int + epoch / Count int", :Race,     m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("year") + _EKM_FN.Extract("start_at", "EPOCH")) / _EKM_FN.Count("raceid"), "integer")),
  # … and a `Sum` the walk does not type because it is TEMPORAL arithmetic: an interval or a
  # timestamp difference, which the render types and no integer quotient can be
  ("Cast Sum F interval + interval / 2 text", :Result, m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("fastestlaptime") + _EKM_Q.F("fastestlaptime")) / 2, "text")),
  ("Concat Sum F interval + interval / 2", :Result, m -> _EKM_FN.Concat("positiontext", _EKM_FN.Sum(_EKM_Q.F("fastestlaptime") + _EKM_Q.F("fastestlaptime")) / 2)),
  ("Cast Sum F interval * 2 / 2 text", :Result,     m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("fastestlaptime") * 2) / 2, "text")),
  ("Cast Sum F datetime - datetime / 2 text", :Race, m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("start_at") - _EKM_Q.F("start_at")) / 2, "text")),
  ("Cast Sum F int * interval / 2 text", :Result,   m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("grid") * _EKM_Q.F("fastestlaptime")) / 2, "text")),
  # … but a date difference is a day count, a number: rooted in a date, summed with a `bigint` it is
  # a `sum(bigint)` on PostgreSQL
  ("Cast Sum F date - date + bigint / 2 int", :Race, m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("date") - _EKM_Q.F("date") + _EKM_Q.F("raceid")) / 2, "integer")),
  ("Cast Sum F date - date / 2 int", :Race,         m -> _EKM_FN.Cast(_EKM_FN.Sum(_EKM_Q.F("date") - _EKM_Q.F("date")) / 2, "integer")),
  ("Floor Subquery int",      :Result,              m -> _EKM_FN.Floor(_EKM_Q.Subquery(_ekm_sub(m, :Result, "grid")))),
  # #1150: a quotient over a decimal or a float side is one, and SQLite divides it as REAL
  ("F decimal / 2",           :Constructor_results, m -> _EKM_Q.F("points") / 2),
  ("F float / 2",             :Result,              m -> _EKM_Q.F("points") / 2),
  ("Coalesce int float / 2",  :Result,              m -> _EKM_FN.Coalesce("grid", "points") / 2),
  ("Case int float / 2",      :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1.5)], default = 0) / 2),
  ("Cast int numeric / 2",    :Result,              m -> _EKM_FN.Cast("grid", "numeric") / 2),
  ("NullIf int float / 2",    :Result,              m -> _EKM_FN.NullIf("grid", 0.5) / 2),
  ("Lag int default float / 2", :Result,            m -> _EKM_FN.Lag("grid", default = 1.5, over = _ekm_over(:Result)) / 2),
  # #1151: a `Case` with a float branch is a float, so its cast to an integer departs on SQLite
  ("Cast Case int float to integer", :Result,       m -> _EKM_FN.Cast(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1.5)], default = 0), "integer")),
  # #1187: the other rules read a `Case` branch by branch too — a scale, a decimal branch, `Concat`
  ("Cast Case float col to scale 0", :Result,       m -> _EKM_FN.Cast(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("points"))], default = 0), "numeric(10,0)")),
  ("Cast Case float literal to scale 2", :Result,   m -> _EKM_FN.Cast(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1.5)], default = 0), "numeric(10,2)")),
  ("Cast Case decimal to integer", :Constructor_results, m -> _EKM_FN.Cast(_EKM_FN.Case([_EKM_FN.When("status" => "x", then = _EKM_Q.F("points"))], default = 0), "integer")),
  ("Concat Case float",       :Result,              m -> _EKM_FN.Concat("positiontext", _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1.5)], default = 0))),
  # #1200: operands of different temporal types, or a temporal and a text one, with no `output_field`
  ("Coalesce date zoned literal", :Race,            m -> _EKM_FN.Coalesce("date", _EKM_ZDT)),
  ("Greatest date zoned literal", :Race,            m -> _EKM_FN.Greatest("date", _EKM_ZDT)),
  ("Least date zoned literal", :Race,               m -> _EKM_FN.Least("date", _EKM_ZDT)),
  ("NullIf date zoned literal", :Race,              m -> _EKM_FN.NullIf("date", _EKM_ZDT)),
  ("Case date branch zoned default", :Race,         m -> _EKM_FN.Case([_EKM_FN.When("year" => 0, then = _EKM_Q.F("date"))], default = _EKM_ZDT)),
  ("Case zoned naive literals", :Race,              m -> _EKM_FN.Case([_EKM_FN.When("year" => 0, then = _EKM_FN.Value(_EKM_ZDT))], default = _EKM_FN.Value(DateTime(2021, 1, 1)))),
  ("Lag date default zoned",  :Race,                m -> _EKM_FN.Lag("date", default = _EKM_ZDT, over = _ekm_over(:Race))),
  ("Coalesce date zoned column", :Race,             m -> _EKM_FN.Coalesce("date", "start_at")),
  ("Coalesce zoned naive literal", :Race,           m -> _EKM_FN.Coalesce("start_at", DateTime(2021, 1, 1))),
  ("Coalesce text zoned literal", :Result,          m -> _EKM_FN.Coalesce("positiontext", _EKM_ZDT)),
  ("Coalesce time interval",  :Result,              m -> _EKM_FN.Coalesce("raceid__time", "fastestlaptime")),
  # … and the spellings that say which type is meant, which build
  ("Coalesce date Date(zoned)", :Race,              m -> _EKM_FN.Coalesce("date", Date(_EKM_ZDT))),
  ("Coalesce zoned zoned",    :Race,                m -> _EKM_FN.Coalesce("start_at", _EKM_ZDT)),
  ("Coalesce date zoned output date", :Race,        m -> _EKM_FN.Coalesce("date", _EKM_ZDT; output_field = "date")),
  # #1212: a declared decimal — a `Cast` over arithmetic, a decimal column and an integer, an
  # `output_field` on `Coalesce`/`Greatest`/`Case`, an extremum over one — and the float spellings
  ("Cast F float * 1.5 numeric", :Result,           m -> _EKM_FN.Cast(_EKM_Q.F("points") * 1.5, "numeric")),
  ("Cast decimal to scale 2", :Constructor_results, m -> _EKM_FN.Cast("points", "numeric(10,2)")),
  ("Cast int DecimalField",   :Result,              m -> _EKM_FN.Cast("grid", PormG.Models.DecimalField())),
  ("Coalesce F float output decimal", :Result,      m -> _EKM_FN.Coalesce(_EKM_Q.F("points") * 1.5, 0; output_field = PormG.Models.DecimalField())),
  ("Greatest float int output decimal", :Result,    m -> _EKM_FN.Greatest("points", "grid"; output_field = PormG.Models.DecimalField())),
  ("Case float output decimal", :Result,            m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1.5)], default = 0, output_field = PormG.Models.DecimalField())),
  ("Max Cast F float numeric", :Result,             m -> _EKM_FN.Max(_EKM_FN.Cast(_EKM_Q.F("points") * 1.5, "numeric"))),
  ("Cast int float8",         :Result,              m -> _EKM_FN.Cast("grid", "float8")),
  ("Cast int FloatField",     :Result,              m -> _EKM_FN.Cast("grid", PormG.Models.FloatField())),
  ("Cast float real",         :Result,              m -> _EKM_FN.Cast("points", "real")),
  # #1217: a declared `output_field` of a scale, an integer or text — on `Case`, read branch by branch,
  # and on `Coalesce`/`Greatest`/`Least` — over an operand the declaration rounds, and the ones it fits
  ("Case F float * 1.5 output scale 1", :Result,    m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("points") * 1.5)], default = 0, output_field = "numeric(10,1)")),
  ("Case decimal output scale 1", :Constructor_results, m -> _EKM_FN.Case([_EKM_FN.When("status" => "x", then = _EKM_Q.F("points"))], default = 0, output_field = "numeric(10,1)")),
  ("Case float literal output integer", :Result,    m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1.5)], default = 0, output_field = "integer")),
  ("Case bool output text",   :New_join_position,   m -> _EKM_FN.Case([_EKM_FN.When("result" => 1, then = _EKM_Q.F("boolean_field"))], output_field = "text")),
  # #1222: a literal default beside a typed branch under an `output_field`; the date one is a control
  ("Case bool output text default false", :New_join_position, m -> _EKM_FN.Case([_EKM_FN.When("result" => 1, then = _EKM_Q.F("boolean_field"))], default = false, output_field = "text")),
  ("Case int output text default text", :Result,    m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("laps"))], default = "none", output_field = "text")),
  ("Case float output text default text", :Result,  m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("points"))], default = "none", output_field = "text")),
  ("Case int output integer default float", :Result, m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("laps"))], default = 1.5, output_field = "integer")),
  ("Case date output date default text", :Race,     m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("date"))], default = "2009-01-01", output_field = "date")),
  ("Coalesce F float * 1.5 output scale 1", :Result, m -> _EKM_FN.Coalesce(_EKM_Q.F("points") * 1.5, 0; output_field = "numeric(10,1)")),
  ("Greatest float int output scale 1", :Result,    m -> _EKM_FN.Greatest("points", "grid"; output_field = "numeric(10,1)")),
  ("Least float int output scale 1", :Result,       m -> _EKM_FN.Least("points", "grid"; output_field = "numeric(10,1)")),
  ("Case Round output scale 1", :Result,            m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_FN.Round("points", 1))], default = 0, output_field = "numeric(10,1)")),
  ("Case int output scale 1", :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("laps"))], default = 0, output_field = "numeric(10,1)")),
  ("Case decimal output scale 2", :Constructor_results, m -> _EKM_FN.Case([_EKM_FN.When("status" => "x", then = _EKM_Q.F("points"))], default = 0, output_field = "numeric(10,2)")),
  ("Case Floor output integer", :Result,            m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_FN.Floor("points"))], default = 0, output_field = "integer")),
  ("Cast Case output scale 1 to scale 2", :Result,  m -> _EKM_FN.Cast(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_FN.Round("points", 1))], default = 0, output_field = "numeric(10,1)"), "numeric(10,2)")),
  # #1034 phase 3 step 2b: the scale a nested declaration or an extremum carries into a scaled cast
  ("Cast Cast Round scale 2 to scale 1", :Result,   m -> _EKM_FN.Cast(_EKM_FN.Cast(_EKM_FN.Round("points", 2), "numeric(10,2)"), "numeric(10,1)")),
  ("Cast Cast Round scale 1 to scale 2", :Result,   m -> _EKM_FN.Cast(_EKM_FN.Cast(_EKM_FN.Round("points", 1), "numeric(10,1)"), "numeric(10,2)")),
  ("Cast Max decimal to scale 1", :Constructor_results, m -> _EKM_FN.Cast(_EKM_FN.Max("points"), "numeric(10,1)")),
  ("Cast decimal to scale 1", :Constructor_results, m -> _EKM_FN.Cast("points", "numeric(10,1)")),
  ("Cast int to scale 1",     :Result,              m -> _EKM_FN.Cast("grid", "numeric(10,1)")),
  # #1110: a declared precision a row's value can overflow, which only reading the row can tell
  ("Cast int to numeric(2,0)", :Result,             m -> _EKM_FN.Cast("driverid", "numeric(2,0)")),
  ("Cast decimal to numeric(3,2)", :Constructor_results, m -> _EKM_FN.Cast("points", "numeric(3,2)")),
  ("Cast float to numeric(3,1)", :Result,           m -> _EKM_FN.Cast("points", "numeric(3,1)")),
  ("Cast F int * 10 to numeric(2,0)", :Result,      m -> _EKM_FN.Cast(_EKM_Q.F("grid") * 10, "numeric(2,0)")),
  ("Coalesce decimal output numeric(4,2)", :Constructor_results, m -> _EKM_FN.Coalesce("points", 0; output_field = "numeric(4,2)")),
  # #1215: a single-precision cast — `real`, `float4`, `float(p)` up to 24 — and `float(25)`, a double
  ("Cast float float4",       :Result,              m -> _EKM_FN.Cast("points", "float4")),
  ("Cast float float(24)",    :Result,              m -> _EKM_FN.Cast("points", "float(24)")),
  ("Cast float float(25)",    :Result,              m -> _EKM_FN.Cast("points", "float(25)")),
  ("Cast int real",           :Result,              m -> _EKM_FN.Cast("grid", "real")),
  ("Coalesce float int output real", :Result,       m -> _EKM_FN.Coalesce("points", "grid"; output_field = "real")),
  ("Case float literal output real", :Result,       m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1.5)], default = 0, output_field = "real")),
  # #1221: a `DecimalField(max_digits, decimal_places)` declaration, each beside its `"numeric(p,s)"` twin
  ("Cast float DecimalField(10,1)", :Result,        m -> _EKM_FN.Cast("points", PormG.Models.DecimalField(max_digits = 10, decimal_places = 1))),
  ("Cast int DecimalField(10,1)", :Result,          m -> _EKM_FN.Cast("grid", PormG.Models.DecimalField(max_digits = 10, decimal_places = 1))),
  ("Cast decimal DecimalField(10,1)", :Constructor_results, m -> _EKM_FN.Cast("points", PormG.Models.DecimalField(max_digits = 10, decimal_places = 1))),
  ("Coalesce F float * 1.5 output DecimalField(10,1)", :Result, m -> _EKM_FN.Coalesce(_EKM_Q.F("points") * 1.5, 0; output_field = PormG.Models.DecimalField(max_digits = 10, decimal_places = 1))),
  ("Case F float * 1.5 output DecimalField(10,1)", :Result, m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.F("points") * 1.5)], default = 0, output_field = PormG.Models.DecimalField(max_digits = 10, decimal_places = 1))),
  ("Cast Case output DecimalField(10,1) to scale 2", :Result, m -> _EKM_FN.Cast(_EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_FN.Round("points", 1))], default = 0, output_field = PormG.Models.DecimalField(max_digits = 10, decimal_places = 1)), "numeric(10,2)")),
  ("Cast Cast Round DecimalField(10,2) to scale 1", :Result, m -> _EKM_FN.Cast(_EKM_FN.Cast(_EKM_FN.Round("points", 2), PormG.Models.DecimalField(max_digits = 10, decimal_places = 2)), "numeric(10,1)")),
  # #1034 phase 3 step 2c: a CTE column under a scaled cast, its scale declared in the body (`EKM_PREP`)
  ("Cast CTE scale 1 col to scale 2", :Result,      m -> _EKM_FN.Cast(PormG.CTE("c", "r1"), "numeric(10,2)")),
  ("Cast CTE scale 3 col to scale 2", :Result,      m -> _EKM_FN.Cast(PormG.CTE("c", "r3"), "numeric(10,2)")),
  ("Cast CTE decimal col to scale 2", :Constructor_results, m -> _EKM_FN.Cast(PormG.CTE("c", "p"), "numeric(10,2)")),
  ("Cast CTE decimal col to scale 1", :Constructor_results, m -> _EKM_FN.Cast(PormG.CTE("c", "p"), "numeric(10,1)")),
  # #1259: an interval cast to an integer
  ("Cast interval int",       :Result,              m -> _EKM_FN.Cast("fastestlaptime", "integer")),
  ("Cast Sum interval int",   :Result,              m -> _EKM_FN.Cast(_EKM_FN.Sum("fastestlaptime"), "integer")),
  ("Cast Avg interval int",   :Result,              m -> _EKM_FN.Cast(_EKM_FN.Avg("fastestlaptime"), "integer")),
  # #1276: a declared decimal over `DecimalField()` (10, 2) columns, at their width and at others
  ("Coalesce decimal output numeric(10,2)", :Constructor_results, m -> _EKM_FN.Coalesce("points", "points"; output_field = "numeric(10,2)")),
  ("Coalesce decimal output DecimalField()", :Constructor_results, m -> _EKM_FN.Coalesce("points", "points"; output_field = PormG.Models.DecimalField())),
  ("Coalesce decimal output numeric(12,4)", :Constructor_results, m -> _EKM_FN.Coalesce("points", "points"; output_field = "numeric(12,4)")),
  ("Coalesce decimal output numeric", :Constructor_results, m -> _EKM_FN.Coalesce("points", "points"; output_field = "numeric")),
  ("Greatest decimal output numeric(12,4)", :Constructor_results, m -> _EKM_FN.Greatest("points", "points"; output_field = "numeric(12,4)")),
  ("Least decimal output numeric", :Constructor_results, m -> _EKM_FN.Least("points", "points"; output_field = "numeric")),
  # #1260: a date, a timestamp and a time cast to a number; the day count and a part stay numbers
  ("Cast date int",           :Race,                m -> _EKM_FN.Cast("date", "integer")),
  ("Cast datetime int",       :Race,                m -> _EKM_FN.Cast("start_at", "integer")),
  ("Cast time int",           :Race,                m -> _EKM_FN.Cast("time", "integer")),
  ("Cast date numeric(10,2)", :Race,                m -> _EKM_FN.Cast("date", "numeric(10,2)")),
  ("Cast datetime float",     :Race,                m -> _EKM_FN.Cast("start_at", "float8")),
  ("Cast F date + Day(1) int", :Race,               m -> _EKM_FN.Cast(_EKM_Q.F("date") + Day(1), "integer")),
  ("Cast F date - date int",  :Race,                m -> _EKM_FN.Cast(_EKM_Q.F("date") - _EKM_Q.F("date"), "integer")),
  ("Cast transform @year int", :Race,               m -> _EKM_FN.Cast("start_at__@year", "integer")),
  # ── subqueries ─────────────────────────────────────────────────────────────────────────────────
  ("Subquery Max hop date",   :Result,              m -> _EKM_Q.Subquery(_ekm_sub(m, :Result, _EKM_FN.Max("raceid__date")))),
  ("Subquery Avg float",      :Result,              m -> _EKM_Q.Subquery(_ekm_sub(m, :Result, _EKM_FN.Avg("points")))),
  ("Subquery path decimal",   :Constructor_results, m -> _EKM_Q.Subquery(_ekm_sub(m, :Constructor_results, "points"))),
  ("Exists",                  :Result,              m -> _EKM_Q.Exists(_ekm_sub(m, :Result, "resultid"))),
  # ── a condition as a function's operand (#1034 step 4): a `Q`/`Qor` is a boolean ───────────────
  ("Max Q",                   :Result,              m -> _EKM_FN.Max(_EKM_Q.Q("grid__@gt" => 1))),
  ("Min Qor",                 :Result,              m -> _EKM_FN.Min(_EKM_Q.Qor("grid" => 1, "grid" => 2))),
  ("Coalesce Q false",        :Result,              m -> _EKM_FN.Coalesce(_EKM_Q.Q("grid__@gt" => 1), false)),
  ("Sum Q",                   :Result,              m -> _EKM_FN.Sum(_EKM_Q.Q("grid__@gt" => 1))),
  ("Case then Q",             :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = _EKM_Q.Q("points__@gt" => 10))], default = false)),
  # ── #1327, #1321: a conditional over operands of two classes (text, number, date, interval) ─────
  ("Coalesce text int",       :Result,              m -> _EKM_FN.Coalesce("positiontext", "grid")),
  ("Greatest text int literal", :Result,            m -> _EKM_FN.Greatest("positiontext", _EKM_FN.Value(9))),
  ("Case int text literal",   :Result,              m -> _EKM_FN.Case([_EKM_FN.When("grid" => 1, then = 1)], default = "x")),
  ("NullIf text int",         :Result,              m -> _EKM_FN.NullIf("positiontext", _EKM_Q.F("grid"))),
  ("Coalesce text int output text", :Result,        m -> _EKM_FN.Coalesce("positiontext", "grid"; output_field = "text")),
  ("Coalesce int hop date",   :Result,              m -> _EKM_FN.Coalesce("grid", "raceid__date")),
  ("Coalesce date int",       :Race,                m -> _EKM_FN.Coalesce("date", "year")),
  ("Coalesce int interval",   :Result,              m -> _EKM_FN.Coalesce("grid", "fastestlaptime")),
  # ── #1323: a time of day in arithmetic, or beside it ─────────────────────────────────────────────
  ("F time + 1",              :Race,                m -> _EKM_Q.F("time") + 1),
  ("F time * 2",              :Race,                m -> _EKM_Q.F("time") * 2),
  ("Case time int + 1",       :Race,                m -> _EKM_FN.Case([_EKM_FN.When("year" => 2009, then = _EKM_Q.F("time"))], default = 0) + 1),
  ("Coalesce time int * 2",   :Race,                m -> _EKM_FN.Coalesce("time", 0) * 2),
  ("F time > Time literal",   :Race,                m -> _EKM_Q.F("time") > Time(12)),
  # ── #1324: a math function over a duration ───────────────────────────────────────────────────────
  ("Round interval",          :Result,              m -> _EKM_FN.Round("fastestlaptime")),
  ("Round interval places",   :Result,              m -> _EKM_FN.Round("fastestlaptime", 2)),
  ("Floor interval",          :Result,              m -> _EKM_FN.Floor("fastestlaptime")),
  ("Ceil interval",           :Result,              m -> _EKM_FN.Ceil("fastestlaptime")),
  ("Sqrt interval",           :Result,              m -> _EKM_FN.Sqrt("fastestlaptime")),
  ("Exp interval",            :Result,              m -> _EKM_FN.Exp("fastestlaptime")),
  ("Ln interval",             :Result,              m -> _EKM_FN.Ln("fastestlaptime")),
  ("Power interval 2",        :Result,              m -> _EKM_FN.Power("fastestlaptime", 2)),
  ("Mod interval 3",          :Result,              m -> _EKM_FN.Mod("fastestlaptime", 3)),
  ("Abs interval",            :Result,              m -> _EKM_FN.Abs("fastestlaptime")),
  ("Round F interval * 2",    :Result,              m -> _EKM_FN.Round(_EKM_Q.F("fastestlaptime") * 2)),
  ("Extract hour F datetime - datetime", :Race,     m -> _EKM_FN.Extract(_EKM_Q.F("start_at") - _EKM_Q.F("start_at"), "hour")),
  ("Extract minute F interval * 2", :Result,        m -> _EKM_FN.Extract(_EKM_Q.F("fastestlaptime") * 2, "minute")),
  ("Extract epoch F interval * 2", :Result,         m -> _EKM_FN.Extract(_EKM_Q.F("fastestlaptime") * 2, "epoch")),
  # ── #1388: a date part over a duration expression ─────────────────────────────────────────────────
  # A calendar part: a duration has no calendar date on any engine.
  ("Extract quarter F datetime - date", :Race,      m -> _EKM_FN.Extract(_EKM_Q.F("start_at") - _EKM_Q.F("date"), "quarter")),
  ("Extract year F interval * 2", :Result,          m -> _EKM_FN.Extract(_EKM_Q.F("fastestlaptime") * 2, "year")),
  ("Extract month F interval * 2", :Result,         m -> _EKM_FN.Extract(_EKM_Q.F("fastestlaptime") * 2, "month")),
  ("Extract century F interval * 2", :Result,       m -> _EKM_FN.Extract(_EKM_Q.F("fastestlaptime") * 2, "century")),
  ("Extract dow Sum interval", :Result,             m -> _EKM_FN.Extract(_EKM_FN.Sum("fastestlaptime"), "dow")),
  ("Extract week F datetime - datetime", :Race,     m -> _EKM_FN.Extract(_EKM_Q.F("start_at") - _EKM_Q.F("start_at"), "week")),
  ("DATE F interval * 2",     :Result,              m -> _EKM_Q.DATE(_EKM_Q.F("fastestlaptime") * 2)),
  ("DATE CTE interval col",   :Result,              m -> _EKM_Q.DATE(PormG.CTE("c", "d"))),
  ("WEEK_DAY Sum interval",   :Result,              m -> _EKM_Q.WEEK_DAY(_EKM_FN.Sum("fastestlaptime"))),
  ("QUARTER F interval * 2",  :Result,              m -> _EKM_Q.QUARTER(_EKM_Q.F("fastestlaptime") * 2)),
  ("QUADRIMESTER F datetime - datetime", :Race,     m -> _EKM_Q.QUADRIMESTER(_EKM_Q.F("start_at") - _EKM_Q.F("start_at"))),
  ("ToChar YYYY-MM F interval * 2", :Result,        m -> _EKM_FN.ToChar(_EKM_Q.F("fastestlaptime") * 2, "YYYY-MM")),
  # A clock part reads the duration's components on PostgreSQL; it is not decided here. And a date plus
  # a duration is a timestamp, which has a calendar date.
  ("Extract hour F interval * 2", :Result,          m -> _EKM_FN.Extract(_EKM_Q.F("fastestlaptime") * 2, "hour")),
  ("Extract second Sum interval", :Result,          m -> _EKM_FN.Extract(_EKM_FN.Sum("fastestlaptime"), "second")),
  ("Extract year F hop date + interval", :Result,   m -> _EKM_FN.Extract(_EKM_Q.F("raceid__date") + _EKM_Q.F("fastestlaptime"), "year")),
  ("Extract second F interval * 2", :Result,        m -> _EKM_FN.Extract(_EKM_Q.F("fastestlaptime") * 2, "second")),
  ("Extract hour Sum interval", :Result,            m -> _EKM_FN.Extract(_EKM_FN.Sum("fastestlaptime"), "hour")),
  ("Extract minute F datetime - date", :Race,       m -> _EKM_FN.Extract(_EKM_Q.F("start_at") - _EKM_Q.F("date"), "minute")),
  # ── #1406: a time of day minus a time of day ─────────────────────────────────────────────────────
  ("F time - time",           :Race,                m -> _EKM_Q.F("time") - _EKM_Q.F("time")),
  ("Max F time - time",       :Race,                m -> _EKM_FN.Max(_EKM_Q.F("time") - _EKM_Q.F("time"))),
  ("Extract year F time - time", :Race,             m -> _EKM_FN.Extract(_EKM_Q.F("time") - _EKM_Q.F("time"), "year")),
  ("Extract hour F time - time", :Race,             m -> _EKM_FN.Extract(_EKM_Q.F("time") - _EKM_Q.F("time"), "hour")),
  ("Extract epoch F time - time", :Race,            m -> _EKM_FN.Extract(_EKM_Q.F("time") - _EKM_Q.F("time"), "epoch")),
  ("Round F time - time",     :Race,                m -> _EKM_FN.Round(_EKM_Q.F("time") - _EKM_Q.F("time"))),
  ("Coalesce F time - time int", :Race,             m -> _EKM_FN.Coalesce(_EKM_Q.F("time") - _EKM_Q.F("time"), "year")),
  # ── #1386: a boolean beside another type in a conditional ───────────────────────────────────────
  ("Coalesce bool int",       :New_join_position,   m -> _EKM_FN.Coalesce("boolean_field", "result")),
  ("Coalesce bool int literal", :New_join_position, m -> _EKM_FN.Coalesce("boolean_field", 0)),
  ("Greatest int bool",       :New_join_position,   m -> _EKM_FN.Greatest("result", "boolean_field")),
  ("Case then true default 0", :New_join_position,  m -> _EKM_FN.Case([_EKM_FN.When("result" => 1, then = true)], default = 0)),
  ("Coalesce bool text",      :New_join_position,   m -> _EKM_FN.Coalesce("boolean_field", "description")),
  ("Coalesce bool comparison", :New_join_position,  m -> _EKM_FN.Coalesce("boolean_field", _EKM_Q.F("result") > 1)),
  # ── #1387: a number function over a date, a timestamp, a time or a UUID ─────────────────────────
  ("Round date",              :Race,                m -> _EKM_FN.Round("date")),
  ("Floor datetime",          :Race,                m -> _EKM_FN.Floor("start_at")),
  ("Ceil time",               :Race,                m -> _EKM_FN.Ceil("time")),
  ("Sqrt date",               :Race,                m -> _EKM_FN.Sqrt("date")),
  ("Exp datetime",            :Race,                m -> _EKM_FN.Exp("start_at")),
  ("Ln time",                 :Race,                m -> _EKM_FN.Ln("time")),
  ("Power date 2",            :Race,                m -> _EKM_FN.Power("date", 2)),
  ("Mod datetime 3",          :Race,                m -> _EKM_FN.Mod("start_at", 3)),
  ("Abs date",                :Race,                m -> _EKM_FN.Abs("date")),
  ("Abs time",                :Race,                m -> _EKM_FN.Abs("time")),
  ("Sum date",                :Race,                m -> _EKM_FN.Sum("date")),
  ("Avg datetime",            :Race,                m -> _EKM_FN.Avg("start_at")),
  ("Sum time",                :Race,                m -> _EKM_FN.Sum("time")),
  ("Round hop date",          :Result,              m -> _EKM_FN.Round("raceid__date")),
  ("Round F date + Day(1)",   :Race,                m -> _EKM_FN.Round(_EKM_Q.F("date") + Day(1))),
  ("Floor Max date",          :Race,                m -> _EKM_FN.Floor(_EKM_FN.Max("date"))),
  ("Round uuid",              :Field_validation_scratch, m -> _EKM_FN.Round("uuid_token")),
  ("Sum uuid",                :Field_validation_scratch, m -> _EKM_FN.Sum("uuid_token")),
  # The spellings the refusal names keep building: a calendar part and a clock part (a day count is
  # `Abs F date - date`, above).
  ("Round Extract year",      :Race,                m -> _EKM_FN.Round(_EKM_FN.Extract("date", "year"))),
  ("Sum Extract hour time",   :Race,                m -> _EKM_FN.Sum(_EKM_FN.Extract("time", "hour"))),
  # #1319: a boolean cast to a number other than an integer; the integer cast is `1` / `0` everywhere
  ("Cast bool float8",        :New_join_position,   m -> _EKM_FN.Cast("boolean_field", "float8")),
  ("Cast bool numeric",       :New_join_position,   m -> _EKM_FN.Cast("boolean_field", "numeric")),
  ("Cast bool to scale 2",    :New_join_position,   m -> _EKM_FN.Cast("boolean_field", "numeric(10,2)")),
  ("Cast bool to integer",    :New_join_position,   m -> _EKM_FN.Cast("boolean_field", "integer")),
  # #1325: a cast to a date of a duration or of a time, which have no date
  ("Cast interval to date",   :Result,              m -> _EKM_FN.Cast("fastestlaptime", "date")),
  ("Cast time to date",       :Race,                m -> _EKM_FN.Cast("time", "date")),
  # #1336: `ToChar` over a time, with a date in its format and with a time-only one
  ("ToChar time YYYY-MM-DD",  :Race,                m -> _EKM_FN.ToChar("time", "YYYY-MM-DD")),
  ("ToChar time HH:MI",       :Race,                m -> _EKM_FN.ToChar("time", "HH:MI")),
  # #1167: a whole number cast to an unscaled `numeric`, then to an integer or a scale
  ("Cast Cast int numeric to integer", :Result,     m -> _EKM_FN.Cast(_EKM_FN.Cast("grid", "numeric"), "integer")),
  ("Cast Cast int numeric to scale 2", :Result,     m -> _EKM_FN.Cast(_EKM_FN.Cast("grid", "numeric"), "numeric(10,2)")),
  # #1416: `ToChar` over a duration, with a date-writing format and with a clock-only one
  ("ToChar interval YYYY",    :Result,              m -> _EKM_FN.ToChar("fastestlaptime", "YYYY")),
  ("ToChar interval HH24:MI", :Result,              m -> _EKM_FN.ToChar("fastestlaptime", "HH24:MI")),
  # #1293: a number function over text, `Round` at `d = 0` included
  ("Floor text",              :Result,              m -> _EKM_FN.Floor("positiontext")),
  ("Round text",              :Result,              m -> _EKM_FN.Round("positiontext")),
  ("Round text places 0",     :Result,              m -> _EKM_FN.Round("positiontext", 0)),
  # #1417: a number cast to a date, which SQLite reads as a Julian day and MySQL as a date's digits
  ("Cast int to date",        :Result,              m -> _EKM_FN.Cast("grid", "date")),
  # #1252: a cast to text of a declared length, by name and by a `CharField` declaration; an
  # undeclared `CharField()` length and a `Concat` declaring one, which renders no cast
  ("Cast text varchar(3)",    :Result,              m -> _EKM_FN.Cast("positiontext", "varchar(3)")),
  ("Cast text CharField(3)",  :Result,              m -> _EKM_FN.Cast("positiontext", PormG.Models.CharField(max_length = 3))),
  ("Cast int CharField(250)", :Result,              m -> _EKM_FN.Cast("grid", PormG.Models.CharField(max_length = 250))),
  ("Cast text CharField",     :Result,              m -> _EKM_FN.Cast("positiontext", PormG.Models.CharField())),
  ("Concat output varchar(3)", :Result,             m -> _EKM_FN.Concat(["positiontext", _EKM_FN.Value("x")]; output_field = "varchar(3)")),
  # #1438: the declarations #1252 did not reach — a `SlugField`/`URLField` (sized, as their columns
  # are), an `EmailField` (no length), PostgreSQL's `bpchar(n)`/`nchar(n)` spellings and an `ArrayField`
  ("Cast text SlugField",     :Result,              m -> _EKM_FN.Cast("positiontext", PormG.Models.SlugField())),
  ("Cast text URLField(20)",  :Result,              m -> _EKM_FN.Cast("positiontext", PormG.Models.URLField(max_length = 20))),
  ("Cast text EmailField",    :Result,              m -> _EKM_FN.Cast("positiontext", PormG.Models.EmailField())),
  ("Cast text bpchar(3)",     :Result,              m -> _EKM_FN.Cast("positiontext", "bpchar(3)")),
  ("Cast text nchar(3)",      :Result,              m -> _EKM_FN.Cast("positiontext", "nchar(3)")),
  # #1439: a cast to an array reads back as the `Vector` an `ArrayField` of its element does; an array
  # of an element `ArrayField` cannot declare (`smallint`), or of more than one dimension, names nothing.
  # Each casts an array literal, so the read-back (`test_expression_kind_readback.jl`) can run it on
  # PostgreSQL: a scalar column has no cast to an array there.
  ("Cast text ArrayField(CharField(3))", :Result,   m -> _EKM_FN.Cast(_EKM_FN.Value("{SOFT,MEDIUM}"), PormG.Models.ArrayField(PormG.Models.CharField(max_length = 3)))),
  ("Cast text varchar[]",     :Result,              m -> _EKM_FN.Cast(_EKM_FN.Value("{SOFT,MEDIUM}"), "varchar[]")),
  ("Cast int integer[]",      :Result,              m -> _EKM_FN.Cast(_EKM_FN.Value("{7,8}"), "integer[]")),
  ("Cast decimal numeric(10,2)[]", :Result,         m -> _EKM_FN.Cast(_EKM_FN.Value("{1.5,2}"), "numeric(10,2)[]")),
  ("Cast int smallint[]",     :Result,              m -> _EKM_FN.Cast(_EKM_FN.Value("{7,8}"), "smallint[]")),
  ("Cast float real[]",       :Result,              m -> _EKM_FN.Cast(_EKM_FN.Value("{0.5}"), "real[]")),
  ("Cast int integer[][]",    :Result,              m -> _EKM_FN.Cast(_EKM_FN.Value("{{7,8}}"), "integer[][]")),
  # #1458: a JSON document and a key lookup into it. The lookup's value is the data's scalar, whose type
  # PormG cannot know, so every reader must treat it as unnamed, and the bare document as the document.
  ("json document",           :Field_validation_scratch, m -> "payload"),
  ("json key",                :Field_validation_scratch, m -> "payload__n"),
  ("F json key + 1",          :Field_validation_scratch, m -> _EKM_Q.F("payload__n") + 1),
  ("F json key / 2",          :Field_validation_scratch, m -> _EKM_Q.F("payload__n") / 2),
  ("Sum json key",            :Field_validation_scratch, m -> _EKM_FN.Sum("payload__n")),
  ("Sum json key / 2",        :Field_validation_scratch, m -> _EKM_FN.Sum("payload__n") / 2),
  ("Max json key",            :Field_validation_scratch, m -> _EKM_FN.Max("payload__n")),
  ("Floor json key / 2",      :Field_validation_scratch, m -> _EKM_FN.Floor("payload__n") / 2),
  ("Cast json key integer",   :Field_validation_scratch, m -> _EKM_FN.Cast("payload__n", "integer")),
  ("Concat json key",         :Field_validation_scratch, m -> _EKM_FN.Concat(_EKM_FN.Value("n="), "payload__n")),
]

# What a shape needs declared on the query that projects it, keyed by label: a `Joined` handle names
# the alias of a `cjoin_on` join, so every query projecting one — the base query, a CTE body, a
# `Subquery`'s inner query — declares that join first.
_ekm_join_race!(q, mod) = q.cjoin_on(mod.Race; alias = "rc",
                                     on = [_EKM_Q.Joined("rc", "raceid") == _EKM_Q.F("raceid")])
# A CTE `c` whose columns declare their scale: two casts of a rounded float (each builds on both
# engines, #1061), and a `DecimalField(10,2)` path.
_ekm_cte_scaled!(q, mod) = q.with("c" => mod.Result.objects.values("resultid",
                                    "r1" => _EKM_FN.Cast(_EKM_FN.Round("points", 1), "numeric(10,1)"),
                                    "r3" => _EKM_FN.Cast(_EKM_FN.Round("points", 3), "numeric(10,3)")),
                                  join_field = "resultid" => "resultid")
_ekm_cte_decimal!(q, mod) = q.with("c" => mod.Constructor_results.objects.values("constructorresultsid", "p" => "points"),
                                   join_field = "constructorresultsid" => "constructorresultsid")
# #1388: a CTE `c` whose column `d` is a duration expression.
_ekm_cte_interval!(q, mod) = q.with("c" => mod.Result.objects.values("resultid", "d" => _EKM_FN.Cast(_EKM_Q.F("fastestlaptime") * 2, "interval")),
                                    join_field = "resultid" => "resultid")
const EKM_PREP = Dict{String,Function}(
  "DATE CTE interval col" => _ekm_cte_interval!,
  "Joined date" => _ekm_join_race!, "Joined datetime" => _ekm_join_race!, "Max Joined date" => _ekm_join_race!,
  "Cast CTE scale 1 col to scale 2" => _ekm_cte_scaled!, "Cast CTE scale 3 col to scale 2" => _ekm_cte_scaled!,
  "Cast CTE decimal col to scale 2" => _ekm_cte_decimal!, "Cast CTE decimal col to scale 1" => _ekm_cte_decimal!)

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
