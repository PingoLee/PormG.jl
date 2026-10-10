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
# - `operand`   — `_operand_kind`, the read-kind reader and comparison binder's view;
# - `function_` — `_function_projection_kind`, the function arm of the same;
# - `column`    — `_projection_column_kind`, the temporal-arithmetic view. For `F` arithmetic it answers
#                 the ROOTED column's kind by contract (the left column, not the result), so there it is
#                 recorded as `"rooted: <kind>"` and is no claim about the expression;
# - `formatter` — `_expression_formatter`, the value formatter filters and binds use;
# - `textless`  — `_concat_textless_operand`, the #1027/#1028 refusals' classifier;
# - `cte_field` / `cte_textless` — under a CTE: the field the CTE model gives the column
#                 (`_set_field_from_sql_function`) and the body's textless record (`cte["textless"]`);
# - `kind`      — `_expression_kind`, the one total inference (#1034, phase 2). Recorded, not compared:
#                 the disagreement rule maps no family for it, so it joins neither pinned set until a
#                 reader is moved onto it.
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
# - `:unparsed` — a read kind is recorded that no SQLite read parser undoes (`read_parsed`, asked of
#                 the parser table itself), so each driver's own representation comes through.
# A second pinned set compares ACROSS contexts (`_ekm_cross_context`): one shape whose channel answers
# differently alone, under a CTE and inside a `Subquery` — the #979 class, which a within-cell rule
# cannot see. It is a measurement only, and not a defect count: a `drops` entry (an answer in one
# context, none in another) includes absences that are by design. The read-back covers the flagged set.
# `test/integration/test_expression_kind_readback.jl` projects every disagreeing cell on the seeded
# F1 fixture and records what it actually reads back as, on both engines.
#
# Regenerating: `PORMG_EKM_RECORD=1 julia --project=test/integration test/unit/test_expression_kind_matrix.jl`
# rewrites the fixture from the current code. Only do that for a change you intend, and read the diff:
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
PormG.backend_sqlite_version(::EkmMockSQLite) = 3045000   # the SQLite window renderer asks for it

PormG.config["ekm_pg"] = PormG.Configuration.Settings(
  connections = EkmMockPostgres(), change_data = true, db_def_folder = "ekm_pg")
PormG.config["ekm_sl"] = PormG.Configuration.Settings(
  connections = EkmMockSQLite(), change_data = true, db_def_folder = "ekm_sl")

# One model set per engine, identical: the subset of the integration F1 models
# (`test/integration/db_2/models.jl`) the shape table names, with the same field types and keys.
for (modname, key) in ((:EkmPGModels, "ekm_pg"), (:EkmSLModels, "ekm_sl"))
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
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

include(joinpath(@__DIR__, "helper_expression_kind_shapes.jl"))

const _EKM_MODELS = ((:postgres, EkmPGModels), (:sqlite, EkmSLModels))

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
_ekm_show(k::PormG.CanonicalType) = replace(string(k), "PormG.Kernel." => "")   # `CDate()`, not its module path
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
    operand   = _ekm_ask(() -> _EKM_QB._operand_kind(node, instr)),
    function_ = _ekm_ask(() -> _EKM_QB._function_projection_kind(node, instr)),
    column    = _ekm_rooted(node, _ekm_ask(() -> _EKM_QB._projection_column_kind(node, instr))),
    formatter = _ekm_ask(() -> _EKM_QB._expression_formatter(node, instr)),
    textless  = _ekm_ask(() -> _EKM_QB._concat_textless_operand(node, instr)),
  )
  cte = get(instr.object.ctes, "g", nothing)
  if cte !== nothing
    ch = merge(ch, (
      cte_field    = _ekm_ask(() -> nameof(typeof(cte["model"].fields["v"]))),
      cte_textless = _ekm_ask(() -> get(cte["textless"], "v", nothing)),
    ))
  end
  # Last, so adding it moved no other channel's text in the fixture. It is no family claim: phase 3 of
  # #1034 moves readers onto it, and each move is then a diff of the channel it replaces.
  return merge(ch, (kind = _ekm_ask(() -> _EKM_QB._expression_kind(node, instr)),))
end

# What one cell does on one engine: every channel, or the error and the stage it fired at. `nothing`
# for a context the shape does not apply to.
function _ekm_observe(mod, label, base, build, context)
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
  # Whether SQLite's read path undoes the recorded kind: asked of the parser table, so a parser added
  # for a kind moves the cell rather than a list here going stale.
  read_parsed = kind === nothing ? nothing : PormG.value_parser(kind, EkmMockSQLite()) !== nothing
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
  "CJSON()" => :json, "CUUID()" => :uuid)
function _ekm_kind_family(s::String)
  haskey(_EKM_KIND_FAMILY, s) && return _EKM_KIND_FAMILY[s]
  startswith(s, "CDecimal(") && return :decimal
  startswith(s, "CDateTime(") && return :datetime
  startswith(s, "CVarChar(") && return :text
  return :other
end
# `format_number_sql` formats every number column (integer, float and decimal alike) and
# `format_text_sql` both a text and a TIME column, so those two name a coarser family.
const _EKM_FORMATTER_FAMILY = Dict(
  "format_number_sql" => :number, "format_bool_sql" => :bool, "format_text_sql" => :text_or_time,
  "format_date_sql" => :date, "format_timezone_sql" => :datetime, "format_duration_sql" => :interval,
  "format_json_sql" => :json, "format_uuid_sql" => :uuid,
  # the date-part range formatters (`@year`, `@hour`, …) format an integer
  "format_year_sql" => :int, "format_hour_sql" => :int, "format_minute_sql" => :int,
  "format_second_sql" => :int, "format_month_sql" => :int, "format_day_sql" => :int,
  "format_quarter_sql" => :int, "format_week_sql" => :int, "format_week_day_sql" => :int,
  "format_yyyy_mm" => :text)   # `ToChar(…, "YYYY-MM")`
const _EKM_TEXTLESS_FAMILY = Dict(
  "bool" => :bool, "float" => :float, "decimal" => :decimal, "numeric" => :numeric,
  # #1111: a whole number PostgreSQL types `numeric`, divided — an engine-dependent number too.
  "integer_division" => :numeric,
  "timestamp" => :datetime, "interval" => :interval, "json" => :json, "json_value" => :json)
const _EKM_FIELD_FAMILY = Dict(
  "sIntegerField" => :int, "sBigIntegerField" => :int, "sSmallIntegerField" => :int, "sFloatField" => :float,
  "sDecimalField" => :decimal, "sBooleanField" => :bool, "sCharField" => :text, "sTextField" => :text,
  "sDateField" => :date, "sDateTimeField" => :datetime, "sTimeField" => :time, "sDurationField" => :interval,
  "sJSONField" => :json, "sUUIDField" => :uuid)

const _EKM_KIND_CHANNELS = (:read, :render, :operand, :function_, :column)

function _ekm_family(channel::Symbol, answer)
  answer isa String || return nothing
  (startswith(answer, "error: ") || startswith(answer, "rooted: ")) && return nothing
  channel in _EKM_KIND_CHANNELS && return _ekm_kind_family(answer)
  channel === :formatter && return get(_EKM_FORMATTER_FAMILY, answer, :other)
  channel in (:textless, :cte_textless) && return get(_EKM_TEXTLESS_FAMILY, answer, :other)
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
function _ekm_disagreements(obs)
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
      push!(out, (:unparsed, "read=$(_ekm_family(:read, obs.read)) has no SQLite read parser"))
  end
  return sort!(out)
end

# Channels compared across contexts. `read` and the formatter/textless views are asked of the node
# itself alone and of the CTE handle or the `Subquery` node elsewhere, so a difference between them is
# what a caller sees change when it moves the same expression into a CTE or a subquery. Left out:
# `column` (it reads the column a path roots in, not the context), `operand` (it answers nothing for an
# `Exists` or an aggregate by design, while the CTE and `Subquery` arms read the filed read kind), and
# the CTE-only channels.
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
    o = _ekm_observe(mod, label, base, build, ctx)
    o === nothing || (obs[(id, backend)] = o)
  end
  return obs
end

if get(ENV, "PORMG_EKM_RECORD", "") == "1"
  # Record mode: write the fixture from the current code and stop. Not a test run.
  obs = _ekm_observations()
  ids = [(id, backend) for (id, _, _, _, _) in _EKM_CELLS for (backend, _) in _EKM_MODELS if haskey(obs, (id, backend))]
  cross = _ekm_cross_context(obs)
  cross_ids = [(label, backend) for (label, _, _) in EKM_SHAPES for (backend, _) in _EKM_MODELS
               if haskey(cross, (label, backend))]
  disagreeing = [(k, _ekm_disagreements(obs[k])) for k in ids]
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
  @info "expression-kind matrix recorded" path = _EKM_FIXTURE cells = length(ids) disagreeing = length(disagreeing) cross_context = length(cross_ids)
else
  include(_EKM_FIXTURE)

  # ─────────────────────────────────────────────────────────────────────────────
  # Expression-kind matrix: every channel answers what it was recorded answering
  # Each (cell, engine) pair builds at the recorded stage, and every type channel gives the recorded
  # answer for the projected column. The fixture holds exactly the cells this file defines — no stale
  # rows, none missing — so a deleted cell cannot leave its expectation behind unchecked.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1034: expression-kind matrix" begin
    obs = _ekm_observations()
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
  # Expression-kind matrix: the disagreement set is the one recorded
  # Re-derived from the fixture's own observations by `_ekm_disagreements`, so this testset checks the
  # recorded set against the rule; a channel that moves fails the matrix testset above instead, until
  # the fixture is re-recorded, which rewrites both. A cell leaving this set is the evidence that a
  # consolidation fixed it; a cell joining it is a new disagreement.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1034: expression-kind matrix, disagreement set" begin
    derived = Dict(k => d for (k, o) in _EKM_EXPECTED for d in (_ekm_disagreements(o),) if !isempty(d))
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
    @test isempty(_ekm_disagreements(obs(read = "CDate()", operand = "error: MethodError")))
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
