# ==============================================================================
# UNIT TESTS: the expression-kind matrix (#1034, phase 1)
#
# "What type does this expression have?" is answered by several functions, each written for one
# consumer. This file records, for every shape × context × engine, what EACH of them answers — as
# data — so that a change to any one shows up as a diff to `fixtures/expression_kind_matrix_expected.jl`,
# and so that the cells where two of them disagree are a list rather than the next issue in the
# #564 … #979 line. It is the measurement #1034 asks for before deciding on one total inference.
#
# The channels recorded per cell:
# - `read`      — the kind the build recorded for the column (`projection_kinds`, #564): what the read path
#                 parses the value with;
# - `render`    — the kind the render computed (`_render_operand_kind`, #1028);
# - `column`    — `_projection_column_kind`, the temporal-arithmetic view. For `F` arithmetic it answers
#                 the ROOTED column's kind by contract (the left column, not the result), so there it is
#                 recorded as `"rooted: <kind>"` and is no claim about the expression;
# - `formatter` — `_expression_formatter`, the value formatter filters and binds use;
# - `textless`  — `_concat_textless_operand`, the #1027/#1028 refusals' classifier;
# - `cte_field` — under a CTE: the field the CTE model gives the column (`_set_field_from_sql_function`).
#                 The column's textless classification as the outer query reads it is `textless` itself,
#                 asked of the CTE column. A `cte_textless` channel beside it recorded only the body
#                 record behind that answer, which #1034 phase 3 step 2c replaces;
# - `kind`      — `_expression_kind`, the one total inference (#1034, phase 2). Recorded, not compared:
#                 the disagreement rule maps no family for it, so it joins neither pinned set until a
#                 reader is moved onto it;
# - `whole_numeric` — the integer-division classifier (`_whole_numeric_operand`, #1111/#1127): a sum
#                 the walk cannot type, under any value-carrying wrapper, which PostgreSQL may compute as
#                 `numeric`. Recorded, not compared, as `kind` is; under a CTE it is what the CTE column
#                 answers, which pins phase 3 step 1 (#1034) moving the CTE's records. (A `bigint`
#                 channel beside it recorded the classifier #1034 phase 3 step 2a deleted.)
# (`operand` and `function_` recorded the read-kind readers `_operand_kind` and
# `_function_projection_kind` until #1459 deleted them with their policy, `_ReadKinds`.)
#
# The BIND CHANNEL is recorded beside the cells, in its own fixture (`fixtures/expression_kind_bind_expected.jl`):
# each `:ok` cell built again with a filter on its column, and what that build renders (the WHERE or
# HAVING predicate) and binds (every parameter and its Julia type). It was the oracle for #1034 phase 3
# step 4, which made the formatter the binder reads a view of the walk; see "The bind channel" below.
# The ORDER CHANNEL beside it (`fixtures/expression_kind_order_expected.jl`, #1285) records what an
# `order_by` on each `:ok` cell sorts by: SQLite sorts an interval by its milliseconds where the render
# finds a millisecond form, and by its text elsewhere; see "The order channel" below.
#
# A limit of the probe, by construction: every channel but `read` is asked AFTER the build, of the node
# as the build saw it, and not at its own call site mid-build, so a channel whose answer depends on the
# render scope it runs in is seen from the outside. The node is rendered again on the built instruction
# first (`render`, the render-then-type order the build itself follows); measured when this file was
# written, that changes no other channel's answer in any cell, and it is kept as a safeguard for a
# channel that reads a record the render files under the node (a `Subquery`'s kind).
#
# The FLAGGED SET (`_EKM_DISAGREEMENTS`) is derived from the observations by a fixed rule
# (`_ekm_disagreements`) and pinned too, so it moves only when a channel does. Three classes, all
# within one cell; the first two are disagreements between channels, the third a property of `read`:
# - `:conflict` — two channels both name a type family, and the families are incompatible;
# - `:gap`      — no read kind is recorded while another channel names a family whose value may read
#                 back differently per engine: one with a read parser (bool, date, datetime, time,
#                 interval, decimal), or `numeric` — a function PostgreSQL computes as `numeric` and
#                 SQLite as a REAL (`textless`'s `:numeric`, #1028);
# - `:unparsed` — a read kind is recorded that no read parser undoes (`read_parsed`, asked of the
#                 parser table itself), so each driver's own representation comes through. A MySQL
#                 cell asks MySQL's parsers; a PostgreSQL cell asks SQLite's, as it has since phase 1.
# A second pinned set compares ACROSS contexts (`_ekm_cross_context`): one shape whose channel answers
# differently alone, under a CTE and inside a `Subquery` — the #979 class, which a within-cell rule
# cannot see. It is a measurement only, and not a defect count: a `drops` entry (an answer in one
# context, none in another) includes absences that are by design. The read-back covers the flagged set.
# `test/integration/test_expression_kind_readback.jl` projects every disagreeing cell on the seeded
# F1 fixture and records what it actually reads back as, on PostgreSQL, SQLite and MySQL (#1130).
#
# Regenerating: `PORMG_EKM_RECORD=1 julia --project=test/integration test/unit/test_expression_kind_matrix.jl`
# rewrites both fixtures from the current code. Only do that for a change you intend, and read the diff:
# it IS the review of that change.
# DB-free: mock connections.
# ==============================================================================

using Test
using PormG
using PormG.Models
using Dates

const _EKM_QB = PormG.QueryBuilder

struct EkmMockPostgres <: PormG.PormGPostgres end
struct EkmMockSQLite <: PormG.PormGSQLite end
struct EkmMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::EkmMockSQLite) = 3045000   # the SQLite window renderer asks for it

PormG.config["ekm_pg"] = PormG.Configuration.Settings(
  connections = EkmMockPostgres(), change_data = true, db_def_folder = "ekm_pg")
PormG.config["ekm_sl"] = PormG.Configuration.Settings(
  connections = EkmMockSQLite(), change_data = true, db_def_folder = "ekm_sl")
PormG.config["ekm_my"] = PormG.Configuration.Settings(
  connections = EkmMockMySQL(), change_data = true, db_def_folder = "ekm_my")

# One model set per engine, identical: the subset of the integration F1 models
# (`test/integration/db_2/models.jl`) the shape table names, with the same field types and keys.
for (modname, key) in ((:EkmPGModels, "ekm_pg"), (:EkmSLModels, "ekm_sl"), (:EkmMYModels, "ekm_my"))
  @eval module $modname
  import PormG
  import PormG.Models
  Race = Models.Model(
    raceid = Models.IDField(),
    year = Models.IntegerField(),
    date = Models.DateField(),
    time = Models.TimeField(null = true),
    start_at = Models.DateTimeField(null = true),
  )
  Driver = Models.Model(
    driverid = Models.IDField(),
    surname = Models.CharField(),
    dob = Models.DateField(),
  )
  Constructor = Models.Model(
    constructorid = Models.IDField(),
    name = Models.CharField(),
  )
  Constructor_results = Models.Model(
    constructorresultsid = Models.IDField(),
    raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
    constructorid = Models.ForeignKey(Constructor, pk_field = "constructorid", on_delete = "RESTRICT"),
    points = Models.DecimalField(),
    status = Models.CharField(),
  )
  Result = Models.Model(
    resultid = Models.IDField(),
    raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
    driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "RESTRICT"),
    grid = Models.IntegerField(),
    positiontext = Models.CharField(),
    points = Models.FloatField(),
    laps = Models.IntegerField(),
    fastestlaptime = Models.DurationField(null = true),
  )
  New_join_position = Models.Model(
    id = Models.IDField(),
    description = Models.CharField(),
    result = Models.IntegerField(null = true),
    boolean_field = Models.BooleanField(null = true),
  )
  # #1387: the F1 fixture's one UUID column; #1458: and its one JSON column.
  Field_validation_scratch = Models.Model("field_validation_scratch",
    id = Models.IDField(),
    uuid_token = Models.UUIDField(unique = true),
    payload = Models.JSONField(null = true),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

include(joinpath(@__DIR__, "helper_expression_kind_shapes.jl"))

# MySQL's column (#1130 phase 2b) was recorded before 2b rendered any expression on it, so each cell 2b
# and 2c make build is a reviewed diff of that column.
const _EKM_MODELS = ((:postgres, EkmPGModels), (:sqlite, EkmSLModels), (:mysql, EkmMYModels))

# The parser table `read_parsed` asks, per engine, and the name the `:unparsed` class gives it. A
# PostgreSQL cell asks SQLite's, as the class was defined in phase 1; MySQL's cells ask its own.
const _EKM_PARSER_ENGINE = Dict(:postgres => (EkmMockSQLite(), "SQLite"), :sqlite => (EkmMockSQLite(), "SQLite"),
                                :mysql => (EkmMockMySQL(), "MySQL"))

# The first line of an error, ANSI-stripped and cut to a stable length (as the #977 matrix does).
function _ekm_message(e)
  msg = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  line = first(split(msg, '\n'))
  return length(line) > 120 ? first(line, 120) : String(line)
end

# One channel's answer as stable text: `nothing` for "no answer", the error type for a channel that
# cannot be asked about this node.
_ekm_show(::Nothing) = nothing
_ekm_show(f::Function) = String(nameof(f))
_ekm_show(t::Tuple{Symbol,String}) = String(first(t))   # a textless classification's kind, not its label
# `CDate()`, not its module path; `CJSONValue()` (#1458) is the walk's own, in `QueryBuilder`
_ekm_show(k::PormG.CanonicalType) = replace(string(k), "PormG.Kernel." => "", "PormG.QueryBuilder." => "")
_ekm_show(x) = string(x)
function _ekm_ask(f)
  try
    return _ekm_show(f())
  catch e
    return "error: " * string(nameof(typeof(e)))
  end
end

# `_projection_column_kind` answers an `F` arithmetic node with the kind of the column it roots in, by
# contract: marked, so it is kept as data but never read as the expression's type.
_ekm_rooted(node, c) =
  node isa _EKM_QB.FExpression && node.operation !== nothing && c !== nothing ? "rooted: " * c : c

# Every channel, asked of the projection named `name` on a built instruction.
function _ekm_channels(instr, name::Symbol)
  i = findfirst(v -> _EKM_QB._projection_output_name(v) == String(name), instr.object.values)
  v = instr.object.values[i]
  node = v isa _EKM_QB.SQLTypeText ? v : v.field
  render = _ekm_ask(() -> last(_EKM_QB._render_operand_kind(node, instr; _as = "ekm_probe")))
  ch = (
    render    = render,
    column    = _ekm_rooted(node, _ekm_ask(() -> _EKM_QB._projection_column_kind(node, instr))),
    formatter = _ekm_ask(() -> _EKM_QB._expression_formatter(node, instr)),
    textless  = _ekm_ask(() -> _EKM_QB._concat_textless_operand(node, instr)),
  )
  cte = get(instr.object.ctes, "g", nothing)
  if cte !== nothing
    ch = merge(ch, (
      cte_field    = _ekm_ask(() -> nameof(typeof(cte["model"].fields["v"]))),
    ))
  end
  # Last, so adding it moved no other channel's text in the fixture. It is no family claim: phase 3 of
  # #1034 moves readers onto it, and each move is then a diff of the channel it replaces.
  ch = merge(ch, (kind = _ekm_ask(() -> _EKM_QB._expression_kind(node, instr)),))
  # The division classifier (#1111, #1127), after `kind` for the same reason. Under a CTE it is asked
  # of the CTE column, so it reads what the body answered for it (#1034 phase 3, step 1).
  return merge(ch, (
    whole_numeric = _ekm_ask(() -> _EKM_QB._whole_numeric_operand(node, instr)),
  ))
end

# What one cell does on one engine: every channel, or the error and the stage it fired at. `nothing`
# for a context the shape does not apply to.
function _ekm_observe(backend, mod, label, base, build, context)
  cell = try
    ekm_query(mod, base, build, context; prep! = get(EKM_PREP, label, nothing))
  catch e
    return (stage = :call, error = string(nameof(typeof(e))), message = _ekm_message(e))
  end
  cell === nothing && return nothing
  q, name = cell
  probe = Ref{Any}(nothing)
  try
    _EKM_QB.query(q; show_query = :sql, built = instr -> (probe[] = _ekm_channels(instr, name)))
  catch e
    return (stage = :build, error = string(nameof(typeof(e))), message = _ekm_message(e))
  end
  kind = get(q.object.projection_kinds, name, nothing)
  # Whether the read path undoes the recorded kind: asked of the parser table, so a parser added for a
  # kind moves the cell rather than a list here going stale.
  read_parsed = kind === nothing ? nothing : PormG.value_parser(kind, first(_EKM_PARSER_ENGINE[backend])) !== nothing
  return merge((stage = :ok, read = _ekm_show(kind), read_parsed = read_parsed), probe[])
end

_ekm_cell_id(label, context) = "$label | $context"

# Every (cell id, label, base, build, context) the matrix defines.
const _EKM_CELLS = [(_ekm_cell_id(label, ctx), label, base, build, ctx)
                    for (label, base, build) in EKM_SHAPES for ctx in EKM_CONTEXTS
                    if ctx !== :after_when || ekm_is_path(build, EkmPGModels)]

# ── The disagreement rule ─────────────────────────────────────────────────────────────────────────
# Each channel's answer, mapped to a type family. `nothing` is "no claim", never a family: the read
# kind is absent for an integer or a text column by design (#564 types only what has a parser), and
# a textless `nothing` means "has one text", not "unknown".
const _EKM_KIND_FAMILY = Dict(
  "CInt16()" => :int, "CInt32()" => :int, "CInt64()" => :int, "CFloat64()" => :float, "CBool()" => :bool,
  "CText()" => :text, "CDate()" => :date, "CTime()" => :time, "CInterval()" => :interval,
  "CJSON()" => :json, "CUUID()" => :uuid, "CBytes()" => :binary)
function _ekm_kind_family(s::String)
  haskey(_EKM_KIND_FAMILY, s) && return _EKM_KIND_FAMILY[s]
  startswith(s, "CDecimal(") && return :decimal
  startswith(s, "CDateTime(") && return :datetime
  startswith(s, "CVarChar(") && return :text
  startswith(s, "CArray(") && return :array   # #1439: a cast to an array, PostgreSQL only
  return :other
end
# `format_number_sql` formats every number column (integer, float and decimal alike) and
# `format_text_sql` both a text and a TIME column, so those two name a coarser family.
const _EKM_FORMATTER_FAMILY = Dict(
  "format_number_sql" => :number, "format_bool_sql" => :bool, "format_text_sql" => :text_or_time,
  "format_date_sql" => :date, "format_timezone_sql" => :datetime, "format_duration_sql" => :interval,
  "_format_mysql_duration" => :interval,   # #1130: MySQL's DurationField, a BIGINT of microseconds
  "format_json_sql" => :json, "format_uuid_sql" => :uuid, "format_binary_sql" => :binary,   # #1194
  # the date-part range formatters (`@year`, `@hour`, …) format an integer
  "format_year_sql" => :int, "format_hour_sql" => :int, "format_minute_sql" => :int,
  "format_second_sql" => :int, "format_month_sql" => :int, "format_day_sql" => :int,
  "format_quarter_sql" => :int, "format_week_sql" => :int, "format_week_day_sql" => :int,
  "format_dow_sql" => :int, "format_quadrimester_sql" => :int,   # #1388
  "format_yyyy_mm" => :text)   # `ToChar(…, "YYYY-MM")`
const _EKM_TEXTLESS_FAMILY = Dict(
  "bool" => :bool, "float" => :float, "decimal" => :decimal, "numeric" => :numeric,
  # #1111: a whole number PostgreSQL types `numeric`, divided — an engine-dependent number too.
  "numeric_whole_division" => :numeric,
  # D5 (#1034): a zero-scale cast SQLite does not round, a decimal there and a whole decimal elsewhere.
  "zero_scale_decimal" => :decimal,
  "timestamp" => :datetime, "interval" => :interval, "json" => :json, "json_value" => :json)
const _EKM_FIELD_FAMILY = Dict(
  "sIntegerField" => :int, "sBigIntegerField" => :int, "sSmallIntegerField" => :int, "sFloatField" => :float,
  "sDecimalField" => :decimal, "sBooleanField" => :bool, "sCharField" => :text, "sTextField" => :text,
  "sDateField" => :date, "sDateTimeField" => :datetime, "sTimeField" => :time, "sDurationField" => :interval,
  "sJSONField" => :json, "sUUIDField" => :uuid, "sBinaryField" => :binary)   # #1194: a `bytea`/`blob` cast

const _EKM_KIND_CHANNELS = (:read, :render, :column)

function _ekm_family(channel::Symbol, answer)
  answer isa String || return nothing
  (startswith(answer, "error: ") || startswith(answer, "rooted: ")) && return nothing
  channel in _EKM_KIND_CHANNELS && return _ekm_kind_family(answer)
  channel === :formatter && return get(_EKM_FORMATTER_FAMILY, answer, :other)
  channel === :textless && return get(_EKM_TEXTLESS_FAMILY, answer, :other)
  channel === :cte_field && return get(_EKM_FIELD_FAMILY, answer, :other)
  return nothing
end

# A coarse family is compatible with each of the finer ones it covers. `:other` is a name this table
# does not map, never a conflict. `:numeric` (an engine-dependent number) is still a number.
const _EKM_COVERS = Dict(:number => (:int, :float, :decimal, :numeric), :numeric => (:int, :float, :decimal),
                         :text_or_time => (:text, :time))
_ekm_compatible(a, b) = a === b || a === :other || b === :other ||
  b in get(_EKM_COVERS, a, ()) || a in get(_EKM_COVERS, b, ())

# A missing read kind beside one of these is a `:gap`.
const _EKM_GAP_FAMILIES = (:bool, :date, :datetime, :time, :interval, :decimal, :numeric)

"""The disagreements one observation shows: `(class, description)` pairs, sorted."""
function _ekm_disagreements(obs, backend::Symbol = :sqlite)
  obs === nothing && return Tuple{Symbol,String}[]
  obs.stage === :ok || return Tuple{Symbol,String}[]
  claims = [(ch, fam) for ch in keys(obs) if ch ∉ (:stage,)
            for fam in (_ekm_family(ch, obs[ch]),) if fam !== nothing]
  out = Tuple{Symbol,String}[]
  for i in eachindex(claims), j in (i+1):lastindex(claims)
    (a, fa), (b, fb) = claims[i], claims[j]
    _ekm_compatible(fa, fb) || push!(out, (:conflict, "$a=$fa vs $b=$fb"))
  end
  if obs.read === nothing
    for (ch, fam) in claims
      fam in _EKM_GAP_FAMILIES && push!(out, (:gap, "read=none vs $ch=$fam"))
    end
  else
    get(obs, :read_parsed, true) === false &&
      push!(out, (:unparsed, "read=$(_ekm_family(:read, obs.read)) has no $(last(_EKM_PARSER_ENGINE[backend])) read parser"))
  end
  return sort!(out)
end

# Channels compared across contexts. `read` and the formatter/textless views are asked of the node
# itself alone and of the CTE handle or the `Subquery` node elsewhere, so a difference between them is
# what a caller sees change when it moves the same expression into a CTE or a subquery. Left out:
# `column` (it reads the column a path roots in, not the context) and the CTE-only channels.
const _EKM_CROSS_CHANNELS = (:read, :formatter, :textless)

"""
One shape's cross-context entries, from its `(context, observation)` rows: per channel, `"conflict
<channel>: ctx=family, …"` when two contexts name incompatible families, else `"drops <channel>: …"`
when some contexts answer and others do not.
"""
function _ekm_cross_entries(rows)
  found = String[]
  for ch in _EKM_CROSS_CHANNELS
    fams = [(ctx, something(_ekm_family(ch, get(o, ch, nothing)), :none)) for (ctx, o) in rows]
    named = [f for (_, f) in fams if f !== :none]
    class = any(!_ekm_compatible(a, b) for a in named for b in named) ? "conflict" :
            0 < length(named) < length(fams) ? "drops" : nothing
    class === nothing || push!(found, "$class $ch: " * join(("$ctx=$f" for (ctx, f) in fams), ", "))
  end
  return found
end

"""For each (shape label, engine) whose contexts that build answer differently: its entries."""
function _ekm_cross_context(obs)
  out = Dict{Tuple{String,Symbol},Vector{String}}()
  for (label, _, _) in EKM_SHAPES, (backend, _) in _EKM_MODELS
    rows = [(ctx, obs[k]) for ctx in EKM_CONTEXTS for k in ((_ekm_cell_id(label, ctx), backend),)
            if haskey(obs, k) && obs[k].stage === :ok]
    length(rows) < 2 && continue
    found = _ekm_cross_entries(rows)
    isempty(found) || (out[(label, backend)] = found)
  end
  return out
end

const _EKM_FIXTURE = joinpath(@__DIR__, "fixtures", "expression_kind_matrix_expected.jl")

function _ekm_observations()
  obs = Dict{Tuple{String,Symbol},Any}()
  for (id, label, base, build, ctx) in _EKM_CELLS, (backend, mod) in _EKM_MODELS
    o = _ekm_observe(backend, mod, label, base, build, ctx)
    o === nothing || (obs[(id, backend)] = o)
  end
  return obs
end

# ── The bind channel (#1034 phase 3, recorded before step 4) ──────────────────────────────────────
# The `formatter` channel names the formatter `_expression_formatter` picks, which is not what a filter
# on the column binds: the alias binder asks a memo first (`_having_alias_formatter`), overrides an
# interval sum (#900), drops a range for an operator other than `=`, keeps a raw number or Bool on SQLite
# (`_sqlite_preserve_native_parameter`), and SQLite compares an interval as milliseconds before any
# formatter runs; a CTE column filtered by its own path takes the #474 memo arm instead. So each `:ok`
# cell is built AGAIN, with a filter on its column, and the channel records what that build renders and
# binds: the WHERE or HAVING predicate (from the built instruction, never grepped from the SQL text, in
# which a `Subquery`'s inner WHERE also appears) and every parameter with its Julia type, or the error.
# The query the other channels probe never carries the filter, so they cannot move with it.
#
# Spellings: alone and in a `Subquery` the projection's alias (`v__@gt`, `w__@gt`); under a CTE the CTE
# column's own path (`g__v__@gt`). The outer `w` there renames that path, and a filter cannot name a
# renamed path (it raises `UnknownFieldError`, as `v__@gt` does over a path shape alone, which is
# recorded). The `When` context projects a path, so a filter there is a column filter, which no channel
# here is about: skipped. Probes, both `@gt`: a
# universal `10`, which shows which formatter acts (a raw value, its text, or a refusal), and a value of
# the cell's own `kind` family, which shows the bind a caller writes. `kind` is the walk, which step 4
# reads and does not change, so a probe moves only with a cell whose `formatter` channel moves.
const _EKM_BIND_FIXTURE = joinpath(@__DIR__, "fixtures", "expression_kind_bind_expected.jl")
const _EKM_BIND_PROBES = Dict(
  :int => ("int 10", 10), :float => ("float 10.5", 10.5),
  :decimal => ("decimal 10.50", parse(_EKM_QB.Decimals.Decimal, "10.50")), :text => ("text pole", "pole"),
  :bool => ("bool true", true), :date => ("date 2009-03-29", Date(2009, 3, 29)),
  :datetime => ("datetime 2009-03-29T06:00", DateTime(2009, 3, 29, 6)), :time => ("time 06:00", Time(6)),
  :interval => ("interval Minute(1)", Minute(1)))
_ekm_bind_spellings(ctx::Symbol, name::Symbol) =
  ctx === :after_when ? () : ctx === :cte ? ("g__v__@gt",) : ("$(name)__@gt",)
function _ekm_bind_probes(o)
  probes = Tuple{String,Any}[("10", 10)]
  family = o.kind isa String && !startswith(o.kind, "error: ") ? _ekm_kind_family(o.kind) : nothing
  fitting = get(_EKM_BIND_PROBES, family, nothing)
  fitting === nothing || family === :int || push!(probes, fitting)
  return probes
end
# A bound value as stable text, and its type's name: `("60000", "Int64")`, `("\"00:01:00\"", "String")`.
# A string or a plain number by `repr`, which tells `"10"` from `10`; any other value by `string`
# (`"10.5"`, `"1 minute"`), since `repr` names a type through whatever `Main` imports — a `Decimal`
# printed `Decimals.Decimal(…)` alone and `Decimal(…)` after a file that does `using Decimals`.
_ekm_bind_param(p) = (p isa Union{AbstractString,Bool,Integer,Base.IEEEFloat} ? repr(p) : string(p),
                      String(nameof(typeof(p))))

# One filter on one cell: the predicate it renders and the parameters it binds, or the error.
function _ekm_bind(mod, label, base, build, ctx, spelling, value)
  q, _ = ekm_query(mod, base, build, ctx; prep! = get(EKM_PREP, label, nothing))
  clauses = Ref{Any}(nothing)
  try
    q.filter(spelling => value)
  catch e
    return (stage = :call, error = string(nameof(typeof(e))), message = _ekm_message(e))
  end
  insp = try
    _EKM_QB.query(q; show_query = :inspection,
                  built = i -> (clauses[] = (where = copy(i._where), having = copy(i.having))))
  catch e
    return (stage = :build, error = string(nameof(typeof(e))), message = _ekm_message(e))
  end
  c = clauses[]
  clause = !isempty(c.having) ? :having : :where
  return (stage = :ok, clause = clause, sql = join(clause === :having ? c.having : c.where, " AND "),
          params = [_ekm_bind_param(p) for p in insp[:parameters]])
end

# Every bind observation, keyed `(cell id, engine, spelling, probe)`, over the cells `obs` built.
function _ekm_bind_observations(obs)
  out = Dict{Tuple{String,Symbol,String,String},Any}()
  for (id, label, base, build, ctx) in _EKM_CELLS, (backend, mod) in _EKM_MODELS
    o = get(obs, (id, backend), nothing)
    (o === nothing || o.stage !== :ok) && continue
    name = ctx === :alone ? :v : :w
    for spelling in _ekm_bind_spellings(ctx, name), (plabel, value) in _ekm_bind_probes(o)
      out[(id, backend, spelling, plabel)] = _ekm_bind(mod, label, base, build, ctx, spelling, value)
    end
  end
  return out
end
# The bind keys in the matrix's own order: cell, engine, spelling, probe.
function _ekm_bind_ids(binds)
  order = Dict(id => i for (i, (id, _, _, _, _)) in enumerate(_EKM_CELLS))
  return sort!(collect(keys(binds)); by = k -> (order[k[1]], k[2], k[3], k[4] == "10" ? "" : k[4]))
end

# ── The order channel (#1285, recorded before its fix) ────────────────────────────────────────────
# What `order_by` on a cell's column renders: SQLite sorts an interval by its milliseconds, not by the
# `HH:MM:SS` text it projects (#894), and the render decides that per shape and per context
# (`_render_projected_interval_ms`, `_orders_as_sqlite_interval`), so the same expression can sort by
# its text in one context and by its length in another. Each `:ok` cell is built again with an
# `order_by`, and the channel records the ORDER BY terms (from the built instruction, never grepped from
# the SQL text) and every parameter the statement binds, or the error.
#
# Spellings: alone the alias `v`, in a `Subquery` the alias `w`; under a CTE both the outer alias `w`
# and the CTE column's own path `g__v`, which the outer query also projects under `w`. The `When`
# context projects a path, a column ordering no channel here is about: skipped. Its own fixture
# (`fixtures/expression_kind_order_expected.jl`), written by the same `PORMG_EKM_RECORD=1` run, so the
# bind fixture's entries are untouched by its arrival.
const _EKM_ORDER_FIXTURE = joinpath(@__DIR__, "fixtures", "expression_kind_order_expected.jl")
_ekm_order_spellings(ctx::Symbol, name::Symbol) =
  ctx === :after_when ? () : ctx === :cte ? ("w", "g__v") : (String(name),)

# One `order_by` on one cell: the ORDER BY terms it renders and the parameters it binds, or the error.
function _ekm_order(mod, label, base, build, ctx, spelling)
  q, _ = ekm_query(mod, base, build, ctx; prep! = get(EKM_PREP, label, nothing))
  terms = Ref{Any}(nothing)
  try
    q.order_by(spelling)
  catch e
    return (stage = :call, error = string(nameof(typeof(e))), message = _ekm_message(e))
  end
  insp = try
    _EKM_QB.query(q; show_query = :inspection, built = i -> (terms[] = copy(i.order)))
  catch e
    return (stage = :build, error = string(nameof(typeof(e))), message = _ekm_message(e))
  end
  return (stage = :ok, sql = join(terms[], ", "), params = [_ekm_bind_param(p) for p in insp[:parameters]])
end

# Every order observation, keyed `(cell id, engine, spelling)`, over the cells `obs` built, in the
# matrix's own order.
function _ekm_order_observations(obs)
  out = Dict{Tuple{String,Symbol,String},Any}()
  for (id, label, base, build, ctx) in _EKM_CELLS, (backend, mod) in _EKM_MODELS
    o = get(obs, (id, backend), nothing)
    (o === nothing || o.stage !== :ok) && continue
    for spelling in _ekm_order_spellings(ctx, ctx === :alone ? :v : :w)
      out[(id, backend, spelling)] = _ekm_order(mod, label, base, build, ctx, spelling)
    end
  end
  return out
end
function _ekm_order_ids(orders)
  order = Dict(id => i for (i, (id, _, _, _, _)) in enumerate(_EKM_CELLS))
  return sort!(collect(keys(orders)); by = k -> (order[k[1]], k[2], k[3]))
end

if get(ENV, "PORMG_EKM_RECORD", "") == "1"
  # Record mode: write the fixture from the current code and stop. Not a test run.
  obs = _ekm_observations()
  ids = [(id, backend) for (id, _, _, _, _) in _EKM_CELLS for (backend, _) in _EKM_MODELS if haskey(obs, (id, backend))]
  cross = _ekm_cross_context(obs)
  cross_ids = [(label, backend) for (label, _, _) in EKM_SHAPES for (backend, _) in _EKM_MODELS
               if haskey(cross, (label, backend))]
  disagreeing = [(k, _ekm_disagreements(obs[k], k[2])) for k in ids]
  filter!(p -> !isempty(last(p)), disagreeing)
  open(_EKM_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_expression_kind_matrix.jl with PORMG_EKM_RECORD=1 — do not edit by hand.")
    println(io, "# One entry per (cell, engine): what every type channel answers for the projected column (#1034).")
    println(io, "# A diff here is a change in what some channel infers.")
    println(io, "const _EKM_EXPECTED = Dict{Tuple{String,Symbol},Any}(")
    for k in ids
      println(io, "  ", repr(k), " =>\n    ", repr(obs[k]), ",")
    end
    println(io, ")")
    println(io)
    println(io, "# The cells on which two channels disagree, by `_ekm_disagreements`' rule. Derived from the entries")
    println(io, "# above; pinned so the measurement itself is reviewable, and iterated by the integration read-back.")
    println(io, "const _EKM_DISAGREEMENTS = Dict{Tuple{String,Symbol},Vector{Tuple{Symbol,String}}}(")
    for (k, d) in disagreeing
      println(io, "  ", repr(k), " =>\n    ", repr(d), ",")
    end
    println(io, ")")
    println(io)
    println(io, "# The shapes whose channels answer differently across contexts, by `_ekm_cross_context`' rule.")
    println(io, "const _EKM_CROSS_CONTEXT = Dict{Tuple{String,Symbol},Vector{String}}(")
    for k in cross_ids
      println(io, "  ", repr(k), " =>\n    ", repr(cross[k]), ",")
    end
    println(io, ")")
  end
  binds = _ekm_bind_observations(obs)
  open(_EKM_BIND_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_expression_kind_matrix.jl with PORMG_EKM_RECORD=1 — do not edit by hand.")
    println(io, "# The bind channel (#1034): per (cell, engine, filter spelling, probe), what a filter on the cell's")
    println(io, "# column renders (the WHERE or HAVING predicate) and binds (each parameter and its Julia type).")
    println(io, "# A diff here is a change in what a filter binds.")
    println(io, "const _EKM_BINDS = Dict{Tuple{String,Symbol,String,String},Any}(")
    for k in _ekm_bind_ids(binds)
      println(io, "  ", repr(k), " =>\n    ", repr(binds[k]), ",")
    end
    println(io, ")")
  end
  orders = _ekm_order_observations(obs)
  open(_EKM_ORDER_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_expression_kind_matrix.jl with PORMG_EKM_RECORD=1 — do not edit by hand.")
    println(io, "# The order channel (#1285): per (cell, engine, order_by spelling), the ORDER BY terms an order_by")
    println(io, "# on the cell's column renders and every parameter the statement binds.")
    println(io, "# A diff here is a change in what an ordering sorts by.")
    println(io, "const _EKM_ORDERS = Dict{Tuple{String,Symbol,String},Any}(")
    for k in _ekm_order_ids(orders)
      println(io, "  ", repr(k), " =>\n    ", repr(orders[k]), ",")
    end
    println(io, ")")
  end
  @info "expression-kind matrix recorded" path = _EKM_FIXTURE cells = length(ids) disagreeing = length(disagreeing) cross_context = length(cross_ids) binds = length(binds) orders = length(orders)
else
  include(_EKM_FIXTURE)
  include(_EKM_BIND_FIXTURE)
  include(_EKM_ORDER_FIXTURE)

  # ─────────────────────────────────────────────────────────────────────────────
  # Expression-kind matrix: every channel answers what it was recorded answering
  # Each (cell, engine) pair builds at the recorded stage, and every type channel gives the recorded
  # answer for the projected column. The fixture holds exactly the cells this file defines — no stale
  # rows, none missing — so a deleted cell cannot leave its expectation behind unchecked.
  # ─────────────────────────────────────────────────────────────────────────────
  # Built once: the bind channel's cells and probes are read from the same observations.
  const _EKM_OBS = _ekm_observations()

  @testset "#1034: expression-kind matrix" begin
    obs = _EKM_OBS
    @test Set(keys(obs)) == Set(keys(_EKM_EXPECTED))
    for (id, _, _, _, _) in _EKM_CELLS, (backend, _) in _EKM_MODELS
      haskey(obs, (id, backend)) || continue
      @testset "$backend: $id" begin
        expected = get(_EKM_EXPECTED, (id, backend), nothing)
        got = obs[(id, backend)]
        @test expected !== nothing
        expected === nothing && continue
        # Field by field, so a failure names the channel that moved.
        @test keys(got) == keys(expected)
        for k in keys(expected)
          @test get(got, k, missing) == expected[k]
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Expression-kind matrix, bind channel: every filter renders and binds what it was recorded binding
  # Each `:ok` cell filtered by each spelling and probe (see the bind channel above). Expected, e.g. a
  # duration CTE column on SQLite: `"R1_1"."v" > ?` with `("\"00:01:00\"", "String")` today, the #1219
  # text comparison. The fixture holds exactly these keys, so a cell that stops building or a spelling
  # that is added cannot leave a stale expectation. Why: the formatter the binder reads is a view of the
  # walk (step 4), and every change to what a filter binds must show here as a reviewed fixture diff.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1034: expression-kind matrix, bind channel" begin
    binds = _ekm_bind_observations(_EKM_OBS)
    @test Set(keys(binds)) == Set(keys(_EKM_BINDS))
    for k in _ekm_bind_ids(binds)
      expected = get(_EKM_BINDS, k, nothing)
      expected === nothing && continue
      got = binds[k]
      @testset "$(k[2]): $(k[1]) | $(k[3]) | $(k[4])" begin
        @test keys(got) == keys(expected)
        for f in keys(expected)
          @test get(got, f, missing) == expected[f]
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Expression-kind matrix, order channel: every order_by renders what it was recorded rendering
  # Each `:ok` cell ordered by each spelling (see the order channel above). Expected, e.g. a duration
  # column alone on SQLite: its milliseconds, `((CASE WHEN substr(…` (#894); PostgreSQL orders by the
  # alias, `"v" ASC NULLS LAST`. The fixture holds exactly these keys. Why: SQLite sorts an interval's
  # text wrongly at 100 hours and for negative values, and whether a shape sorts by its length is
  # decided per context, so a context that loses the millisecond form silently reorders rows (#1285).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1285: expression-kind matrix, order channel" begin
    orders = _ekm_order_observations(_EKM_OBS)
    @test Set(keys(orders)) == Set(keys(_EKM_ORDERS))
    for k in _ekm_order_ids(orders)
      expected = get(_EKM_ORDERS, k, nothing)
      expected === nothing && continue
      got = orders[k]
      @testset "$(k[2]): $(k[1]) | order_by $(k[3])" begin
        @test keys(got) == keys(expected)
        for f in keys(expected)
          @test get(got, f, missing) == expected[f]
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Expression-kind matrix: the disagreement set is the one recorded
  # Re-derived from the fixture's own observations by `_ekm_disagreements`, so this testset checks the
  # recorded set against the rule; a channel that moves fails the matrix testset above instead, until
  # the fixture is re-recorded, which rewrites both. A cell leaving this set is the evidence that a
  # consolidation fixed it; a cell joining it is a new disagreement.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1034: expression-kind matrix, disagreement set" begin
    derived = Dict(k => d for (k, o) in _EKM_EXPECTED for d in (_ekm_disagreements(o, k[2]),) if !isempty(d))
    @test Set(keys(derived)) == Set(keys(_EKM_DISAGREEMENTS))
    for (k, d) in _EKM_DISAGREEMENTS
      @test get(derived, k, nothing) == d
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Expression-kind matrix: the cross-context set is the one recorded
  # The same shape moved under a CTE or into a `Subquery` and asked the same question: the channels
  # that answer differently there are pinned, re-derived from the fixture as the set above is.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1034: expression-kind matrix, cross-context set" begin
    derived = _ekm_cross_context(_EKM_EXPECTED)
    @test Set(keys(derived)) == Set(keys(_EKM_CROSS_CONTEXT))
    for (k, d) in _EKM_CROSS_CONTEXT
      @test get(derived, k, nothing) == d
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The disagreement rule maps every answer the matrix observes
  # `:other` is compatible with everything, so an answer the family tables do not name would hide a
  # conflict instead of reporting one. Every answer recorded must therefore have a family.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1034: every observed answer has a type family" begin
    unmapped = Set{Tuple{Symbol,String}}()
    for o in values(_EKM_EXPECTED), ch in keys(o)
      _ekm_family(ch, o[ch]) === :other && push!(unmapped, (ch, o[ch]))
    end
    @test isempty(unmapped)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The disagreement rule, on hand-written observations
  # The rule's own cases, independent of what the code answers today: a coarse formatter family
  # covers the finer ones; `nothing` and an error are no claim; a missing read kind is a gap only
  # beside a family that has a read parser.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1034: the disagreement rule" begin
    obs(; kw...) = merge((stage = :ok, read = nothing, formatter = nothing, textless = nothing), (; kw...))
    @test isempty(_ekm_disagreements(obs(read = "CDecimal(12, 2)", formatter = "format_number_sql")))
    @test isempty(_ekm_disagreements(obs(read = "CTime()", formatter = "format_text_sql")))
    @test isempty(_ekm_disagreements(obs(formatter = "format_number_sql")))          # int/float: no parser
    @test isempty(_ekm_disagreements(obs(read = "CDate()", render = "error: MethodError")))
    @test _ekm_disagreements(obs(cte_field = "sIntegerField", textless = "float")) ==
          [(:conflict, "textless=float vs cte_field=int")]
    @test _ekm_disagreements(obs(formatter = "format_bool_sql")) == [(:gap, "read=none vs formatter=bool")]
    @test _ekm_disagreements(obs(read = "CDate()", formatter = "format_timezone_sql")) ==
          [(:conflict, "read=date vs formatter=datetime")]
    @test isempty(_ekm_disagreements((stage = :build, error = "QueryBuildError", message = "x")))
    # an engine-dependent number is a gap beside no read kind, and still compatible with a number
    @test _ekm_disagreements(obs(formatter = "format_number_sql", textless = "numeric")) ==
          [(:gap, "read=none vs textless=numeric")]
    # a rooted column under arithmetic is no claim; a read kind with no parser is `:unparsed`
    @test _ekm_disagreements(obs(read = "CInt32()", read_parsed = false, column = "rooted: CDate()")) ==
          [(:unparsed, "read=int has no SQLite read parser")]
    @test isempty(_ekm_disagreements(obs(read = "CDate()", read_parsed = true)))
    # across contexts: an answer beside none drops; two incompatible answers conflict; compatible
    # answers in every context are no entry
    rows(answers...) = [(ctx, obs(textless = a)) for (ctx, a) in zip((:alone, :cte, :subquery), answers)]
    @test _ekm_cross_entries(rows("float", "float", nothing)) ==
          ["drops textless: alone=float, cte=float, subquery=none"]
    @test _ekm_cross_entries(rows("float", "bool", "float")) ==
          ["conflict textless: alone=float, cte=bool, subquery=float"]
    @test isempty(_ekm_cross_entries(rows("numeric", "numeric", "numeric")))
    @test isempty(_ekm_cross_entries(rows(nothing, nothing, nothing)))
  end
end
