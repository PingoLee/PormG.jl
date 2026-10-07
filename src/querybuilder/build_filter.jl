# Rendering a filter (#130): `get_filter_query`, the split of a filter into WHERE and HAVING, and
# the guards a predicate passes first — field/alias collisions, an aggregate or a window where a
# row predicate stands. Predicates on a projection alias render through `projection_types.jl`.

"""
  get_filter_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the filter of the object and generates the WHERE query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the filter to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the WHERE query will be added.
"""
function get_filter_query(object::SQLObject, instruc::SQLInstruction)::Nothing
  # [isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? push!(instruc._where, _get_filter_query(v, instruc)) : throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper") for v in object.filter]
  @pormg_debug false
  for v in object.filter
    _guard_no_aggregate_predicate(v, instruc)   # #537
    _guard_field_alias_collision(v, instruc)   # #703
    if isa(v, ExistsObject)
      push!(instruc._where, _get_filter_query(v, instruc))
    elseif isa(v, SQLTypeOper)
      @pormg_debug false
      if _alias_filter_key(v.column, instruc) !== nothing
        # #446. This branch is reached by a PLAIN filter key — no `__` — that is not a field on the
        # model, which means it is either a projection alias (the documented HAVING spelling) or a
        # name that does not exist. The `try`/`catch` here only rethrew: it was a debug hook, not a
        # guard, so an unknown name escaped as a bare `KeyError` naming an internal dict. That made
        # the simplest possible mistake — `filter("nope" => 1)` — the one PormG reported worst, and
        # it shadowed the `UnknownFieldError` further down this same function, which could never be
        # reached for a plain String column.
        #
        # Guard immediately above the raw index and leave the index plain, the shape #433 settled:
        # the membership test is what makes it total.
        # #474: `memo_key` here is uniform-with-its-neighbours, not CTE support. This branch is gated
        # on `v.column.field isa String && !contains(field, "__")`, and `_retag_cte_field!` always
        # replaces `field` with a `CTEReference` or an `SQLTypeFunction`, so `root` is always `:base`
        # on this path. It is read through the key helper anyway so that a CTE arriving here later is
        # namespaced like everywhere else rather than silently sharing a base-model entry.
        having_key = memo_key(v.column)
        having_cached = memo_projection(instruc, having_key)
        having_cached === nothing &&
          # #474: report the aliases the CALLER could have written — `memo_projection_names` yields
          # exactly that spelling, and never the internal namespace half.
          throw(_unknown_field(instruc.object.model, v.column.field;
                               aliases = memo_projection_names(instruc)))
        # #701: only an AGGREGATE alias filters groups. A row alias — `F("raceid") + 1`, a bare
        # `F("code")` — has one value per row, so its predicate belongs in WHERE; sending every
        # alias to HAVING printed `HAVING` on a query with no GROUP BY, which both engines reject.
        # #692's `_aggregate_alias_leaf` draws the same line for `Q`, on the same test: #702 made the
        # flag true for a wrapped aggregate, and #722 resolves it through an alias the projection's
        # conditions read (`Case([When("total__@gte" => 100, …)])` over `"total" => Sum(…)`), which
        # no flag set at construction can see. No projection source keeps the HAVING route it always
        # had; since #707 a `Value(...)` alias has one, so a literal filters in WHERE (`? = ?`, both
        # values bound) instead of printing `HAVING ? = ?`.
        #
        # Only the CLAUSE moves. The predicate still renders through `_render_alias_predicate`, not
        # through the WHERE path the `Q` spelling takes, because that is where the alias's value is
        # typed from the projection (#576): a `Date` on a date alias formats as the column does, and
        # `"not-a-date"` raises `FilterError` naming the alias. The untyped path binds the value as
        # given — which went unnoticed while this statement could not execute, and would not once it
        # can. `test_operators.jl` pins it.
        source = _projected_source(having_key, instruc)
        clause = (source === nothing || _resolved_agg(source.field, instruc)) ? :having : :where
        # #707: an EXPRESSION on the right (`F("grid")`, `Lower("forename")`, `Max("grid")`) has no
        # value to type — it is a comparison between two expressions, which the WHERE path renders:
        # `_get_filter_query(::SQLTypeField)` resolves the alias through `_alias_lhs` (re-rendering
        # a binding aggregate in the current clause) and the right-hand side renders as SQL. The
        # typed renderer would hand the node to a value formatter and die with a `MethodError`, as
        # this spelling always did, over a row alias (WHERE) and an aggregate one (HAVING) alike.
        # Same rule as `_row_alias_leaf` and `_get_having_query`, so both spellings agree.
        if _expression_operand(v.values)
          _guard_window_alias_predicate(source, having_key[2], instruc)   # #685, as the typed path does
          clause === :where && _guard_where_operand(v, instruc)   # #895: a row alias against an aggregate
          with_bucket(instruc, clause) do
            push!(clause === :having ? instruc.having : instruc._where,
                  _in_clause_phase(() -> _get_filter_query(v, instruc), instruc, clause, having_key[2]))
          end
          continue
        end
        # Switch to the clause's context for positional parameters. #595 moved this ABOVE the
        # left-hand side: resolving it can now RENDER, and a render binds — those values belong in
        # the clause's bucket with the comparison value, ahead of it, exactly as they print.
        # `with_bucket` restores on throw too, and the render can throw from several places — the
        # guards, the fresh render in `_alias_lhs` (#595), `_render_predicate`'s unknown-operator
        # `FilterError` and the SQLite-refusing `Dialect` arms' `BackendCapabilityError` (#618). It
        # RESTORES the ambient bucket rather than resetting to `:where` (#936, #939): the two agree
        # only while this runs under `build()`'s `:where`, and nothing enforced that.
        with_bucket(instruc, clause) do
          push!(clause === :having ? instruc.having : instruc._where,
                _in_clause_phase(() -> _render_alias_predicate(v, having_key, having_cached, instruc),
                                 instruc, clause, having_key[2]))
        end
        continue
      end
      _guard_where_operand(v, instruc)   # #895
      push!(instruc._where, _get_filter_query(v, instruc))
    elseif isa(v, Union{SQLTypeQor,SQLTypeQ,SQLTypeF})
      _guard_window_alias_in_q(v, instruc)   # #685
      # #692: an aggregate alias inside `Q`/`Qor` belongs in HAVING, as it does unwrapped. The split
      # hands back the original object on whichever side takes all of it, so a filter with no
      # aggregate-alias term renders exactly as it did before.
      where_part, having_part = _split_having(v, instruc)
      where_part === nothing || push!(instruc._where, _get_where_query(where_part, instruc))
      if having_part !== nothing
        with_bucket(instruc, :having) do
          push!(instruc.having, with_scope(() -> _get_having_query(having_part, instruc), instruc;
                                           phase = :group, label = _having_subquery_label(string(_having_leaf_label(having_part)))))
        end
      end
    else
      throw(FilterError("Invalid filter entry: a $(typeof(v)) is not a Q, Qor, or operator expression."))
    end
  end
  return nothing
end

# #703 — a plain filter key that names a model field AND the output name of a projection that is
# not that column. `values("raceid", "points" => Sum("points")); filter("points" => 1.0)` rendered
# `WHERE SUM("Tb"."points") = ?`: the key names a field, so neither the top-level alias branch nor
# #692's `Q` routing took it as an alias — but `_get_filter_query(::SQLTypeField)` looks the key up in
# the projection memo before resolving it as a column, and the alias had claimed that entry. The
# filter neither filtered the column nor the projection.
#
# There is no right guess. A caller who wrote `"points" => Sum("points")` and then filters "points"
# most likely means the sum — HAVING — and routing it to the column would filter rows before
# aggregation: silently wrong totals. Routing it to the alias would silently stop the key meaning
# the field. So the key is refused, as #492 refuses a `__` path whose first segment names both a CTE
# and a model field: loud, never guessed. The DECLARATION stays legal — `values("casos" =>
# Sum("casos"))` is common in consuming apps and harmless until something filters on the name —
# which is where this departs from Django, whose `annotate()` refuses the alias outright.
#
# A `__` path is a model name too. `values("driverid__surname" => Upper("driverid__forename"))`
# followed by `filter("driverid__surname" => …)` read the alias through the same memo, silently; the
# key names the related column as much as `"points"` names the local one. So a path whose first
# segment is on the model (`_segment1_on_model`, the #492 test) counts. #757 later refused a `__`
# alias at `values()` altogether, because no router could see one, so the aliased half of this
# shape can no longer be written. The path half is still LIVE (#777), through names PormG generates
# rather than ones the caller chooses:
#
#   - a transform on a foreign key. `values("raceid__@year")` is named `raceid__year`, the path to
#     the related `year`, and projects `EXTRACT(YEAR FROM raceid)`.
#   - a joined copy named after the relation (#484). `cjoin_on(…; alias = "raceid")` plus
#     `SQLField(Joined("raceid", "year"), "raceid__year")` shares the FK path's `:base` memo key, so
#     the filter would read the joined copy, whatever its own ON says, and never emit the FK's join.
#
# Without the guard each renders one meaning and says nothing. The joined copy runs on both engines.
# The transform's `EXTRACT` over an integer key fails when PostgreSQL executes it, but SQLite's
# `strftime` returns a value, and a key whose column is itself a date runs on both. #706's twin
# below reaches the same names
# through `_model_filter_key`. The guard compares OUTPUT names, so a RENAMED transform
# (`"yr" => "raceid__@year"`) still escapes it while keeping the `raceid__year` memo key — #1004.
#
# Not ambiguous, and so not refused: a projection that IS the column — `values("points")`,
# `values("points" => "points")`, `values("points" => F("points"))`. Recursive, with the depth cap of
# `_guard_no_aggregate_predicate`, because `Q`/`Qor` admit the same leaf.
function _guard_field_alias_collision(filter, instruc::SQLInstruction, depth::Int = 0)
  depth > 32 && return nothing
  if filter isa SQLTypeOper
    key = _model_filter_key(filter.column, instruc)
    key === nothing && return nothing
    for projection in instruc.object.values
      _projection_output_name(projection) == key || continue
      _projects_column(projection, key) && return nothing
      _refuse_field_alias_collision(key, projection, instruc)
    end
  elseif filter isa SQLTypeQ
    for f in filter.filters
      _guard_field_alias_collision(f, instruc, depth + 1)
    end
  elseif filter isa SQLTypeQor
    for f in filter.or
      _guard_field_alias_collision(f, instruc, depth + 1)
    end
  end
  return nothing
end

# #706 — #703's question, asked of a condition INSIDE a projection. A `When("points" => 4, …)` or a
# `Q(...)` in a `Case` resolves its key through `_get_filter_query(::SQLTypeField)`, which reads the
# same projection memo a filter does, so the key met the same two meanings — and got whichever one
# had claimed the memo first:
#
#   values("f" => Case([When("points" => 4, then = 1)]), "points" => Sum("points"))
#
# rendered the condition on the column and then, under #441's reuse rule, replaced the SUM
# projection with that column entry: the aggregate the caller asked for vanished, silently. Declare
# the SUM first and the condition compared the SUM instead. Declaration order is not a meaning.
#
# So the same refusal, as a pass over the whole projection list BEFORE anything renders — a static
# scan, which is what takes the order out of it. Only a `SQLTypeOper` leaf reaches the memo this way;
# arithmetic (`F("points") * 2`), `Coalesce("points", …)` and the other functions resolve a column
# without consulting it, and were measured unaffected.
#
# Only OTHER projections count. `"status" => Case([When("status" => 1, then = "F")])` names itself
# inside its own definition, where the name can only mean the column — no SQL reads an alias in the
# expression that defines it. A key that names no model column (`When("dbl" => 4)` over
# `"dbl" => F("points") * 2`) is a plain alias read with one meaning, and is not this guard's business.
# Over an AGGREGATE alias that read makes the reading projection an aggregate, and `_reads_alias`
# (#722) is what tells GROUP BY and the HAVING routing so.
function _guard_select_condition_collision(projections, instruc::SQLInstruction)
  for (i, owner) in pairs(projections)
    owner isa SQLTypeField || continue
    owner_name = _projection_output_name(owner)
    _each_condition_leaf(owner.field) do leaf
      key = _model_filter_key(leaf.column, instruc)
      key === nothing && return nothing
      for (j, projection) in pairs(projections)
        j == i && continue
        _projection_output_name(projection) == key || continue
        _projects_column(projection, key) && return nothing
        _refuse_field_alias_collision(key, projection, instruc; condition_in = owner_name)
      end
      return nothing
    end
  end
  return nothing
end

# Every `SQLTypeOper` leaf reachable from a projection's expression: a `When` condition, a `Q`/`Qor`
# in a `Case`, and anything nested in a function's operands or keyword slots (`Case(default = Case(…))`),
# in a window's `partition_by`/`order_by`, or inside an explicit `SQLField(…)` wrap.
# A subquery or `Exists` is its own instruction with its own projection list, so it is not entered.
# Depth cap as in `_guard_no_aggregate_predicate`.
function _each_condition_leaf(f::Function, node, depth::Int = 0)
  depth > 32 && return nothing
  if node isa SQLTypeOper
    f(node)
  elseif node isa SQLTypeQ
    foreach(x -> _each_condition_leaf(f, x, depth + 1), node.filters)
  elseif node isa SQLTypeQor
    foreach(x -> _each_condition_leaf(f, x, depth + 1), node.or)
  elseif node isa AbstractVector
    foreach(x -> _each_condition_leaf(f, x, depth + 1), node)
  elseif node isa Union{FObject,WindowFunction}
    _each_condition_leaf(f, node.column, depth + 1)
    foreach(x -> _each_condition_leaf(f, x, depth + 1), values(node.kwargs))
    # A window's PARTITION BY and ORDER BY can hold a `Case` too, and resolve through the same
    # memo. ORDER BY refuses a bare function node, but not one wrapped in `SQLField(…)`.
    if node isa WindowFunction
      _each_condition_leaf(f, node.over.partition_by, depth + 1)
      _each_condition_leaf(f, node.over.order_by, depth + 1)
    end
  elseif node isa Union{SQLField,SQLOrder}
    # An explicit `SQLField(Case(…), "k")` wrap, or an ordering term around one.
    _each_condition_leaf(f, node.field, depth + 1)
  elseif node isa FExpression
    _each_condition_leaf(f, node.field_name, depth + 1)
    _each_condition_leaf(f, node.operand, depth + 1)
  end
  return nothing
end

# The filter key when it names something on the model — a field, or a `__` path whose first segment
# is on the model — or `nothing`. Only a plain path: a transform (`__@year`) builds a function node,
# and a CTE or joined-copy reference is a handle rather than a `String`.
function _model_filter_key(col, instruc::SQLInstruction)
  (col isa SQLTypeField && col.field isa String && !contains(col.field, "__@")) || return nothing
  key = col.field
  contains(key, "__") || return key in instruc.object.model.field_names ? key : nothing
  return _segment1_on_model(instruc.object, first(split(key, "__"))) ? key : nothing
end

# Is this projection the column `key` itself, under its own name? `isa String` before each `==`:
# `F` overloads `==` to BUILD a comparison node (#457), so comparing an `FExpression` to a string
# answers an expression, not a `Bool`.
_projects_column(p::SQLTypeField, key::String) =
  (p.field isa String && p.field == key) ||
  (p.field isa FExpression && p.field.operation === nothing &&
   p.field.field_name isa String && p.field.field_name == key)
_projects_column(::Any, ::String) = false

function _refuse_field_alias_collision(key::String, projection, instruc::SQLInstruction;
                                       condition_in::OptionalString = nothing)
  # #706: the same two meanings, met by a condition inside a projection rather than by a filter.
  condition_in === nothing || throw(AmbiguousFieldError(
    "The condition on \e[4m\e[31m\"$(key)\"\e[0m inside " *
    "\e[4m\e[31mvalues(\"$(condition_in)\" => …)\e[0m is ambiguous: \e[4m\e[31m$(key)\e[0m names " *
    "both a column of \e[4m\e[32m$(instruc.object.model.name)\e[0m (a field, or a path through " *
    "one) and the projection alias " *
    "\e[4m\e[31mvalues(\"$(key)\" => $(_describe_projection(projection)))\e[0m, so the condition " *
    "has two meanings and PormG will not choose one.\n  " *
    "Rename the alias — \e[4m\e[32mvalues(\"$(key)_value\" => …)\e[0m — then write " *
    "\e[4m\e[32m\"$(key)_value\"\e[0m in the condition for the projection, or " *
    "\e[4m\e[32m\"$(key)\"\e[0m for the column (#706)."))
  throw(AmbiguousFieldError(
    "\e[4m\e[31mfilter(\"$(key)\" => …)\e[0m is ambiguous: \e[4m\e[31m$(key)\e[0m names " *
    "both a column of \e[4m\e[32m$(instruc.object.model.name)\e[0m (a field, or a path through " *
    "one) and the projection alias " *
    "\e[4m\e[31mvalues(\"$(key)\" => $(_describe_projection(projection)))\e[0m, so the filter " *
    "has two meanings and PormG will not choose one.\n  " *
    "Rename the alias — \e[4m\e[32mvalues(\"$(key)_value\" => …)\e[0m — then filter " *
    "\e[4m\e[32m\"$(key)_value\"\e[0m for the projection, or \e[4m\e[32m\"$(key)\"\e[0m " *
    "for the column (#703)."))
end

# #537 — an aggregate or window function cannot be a WHERE predicate, and `OP(::SQLTypeFunction, …)`
# lets one be written: `filter(OP(Count("id"), ">", 3))` rendered `WHERE COUNT(...)`, which both
# backends reject at EXECUTION, and `OP(Sum(…), …)` died earlier still with a raw `FieldError`.
# Refused at build time instead, naming the spelling that puts the same predicate in the clause SQL
# evaluates it in: an aggregate through the projection alias (HAVING — the alias branch in
# `get_filter_query` above), a window through a CTE, because SQL evaluates windows after WHERE.
#
# Recursive, in the shape of `_guard_no_handle` (join_conditions.jl) and with its depth cap, because `Q(...)`
# and `Qor(...)` admit an `OperObject` directly (functions.jl): a flat check on the top-level entry
# would let `Q(OP(Count("id"), ">", 3))` through. `_is_agg(::WindowFunction)` is `false` by design —
# a window is not an aggregate, even over one (#776 asks `_contains_agg` for GROUP BY instead) — hence
# the explicit `isa` beside it. A SELECT-side CASE
# (`When(OP(...))`) never enters this walk; it renders through `_get_select_query(::SQLTypeOper)`.
function _guard_no_aggregate_predicate(filter, instruc::SQLInstruction, depth::Int = 0)
  depth > 32 && return nothing
  if filter isa SQLTypeOper
    col = filter.column
    if col isa WindowFunction
      throw(QueryBuildError(
        "\e[4m\e[31mOP($(col.function_name)(…), …)\e[0m — a window function cannot be a WHERE " *
        "predicate: SQL evaluates windows after WHERE. " * _WINDOW_PREDICATE_ADVICE * " (#537)."))
    elseif col isa SQLTypeFunction && _is_agg(col)
      throw(QueryBuildError(
        "\e[4m\e[31mOP($(col.function_name)(…), …)\e[0m — an aggregate cannot be a WHERE predicate. " *
        "Project it under an alias and filter on the alias, which renders as HAVING — " *
        "\e[4m\e[32mvalues(\"total\" => Sum(\"qty\")); filter(\"total__@gt\" => 1)\e[0m (#537)."))
    end
  elseif filter isa FExpression
    # #895: the same predicate spelled as an expression — `(Count("id") + 1) > 2`, `Max(…) - Min(…) >
    # Hour(1)`, and since #895 a bare `Count("id") > 1`. It rendered in WHERE, with no GROUP BY, and
    # failed at the driver. An `F` leaf never routes to HAVING (`_split_having` keeps it in WHERE), so
    # every one is WHERE-bound, and refused as `OP(...)` is rather than moved: moving it would also
    # turn on GROUP BY from a filter. The window check runs first, because `_contains_agg` also
    # answers `true` for a window over an aggregate, and that one needs the CTE advice. Both are
    # asked after aliases resolve (#722, #789): `Case([When("total__@gt" => 1, then = 1)]) == 1` over
    # `"total" => Sum(…)` renders `CASE WHEN SUM(…)`, which no flag set at construction can see.
    _resolved_window(filter, instruc) && throw(QueryBuildError(
      "\e[4m\e[31mfilter(…)\e[0m — an expression containing a window function cannot be a WHERE " *
      "predicate: SQL evaluates windows after WHERE. " * _WINDOW_PREDICATE_ADVICE * " (#895)."))
    _resolved_contains_agg(filter, instruc) && throw(QueryBuildError(_AGGREGATE_EXPRESSION_ADVICE))
  elseif filter isa SQLTypeQ
    for f in filter.filters
      _guard_no_aggregate_predicate(f, instruc, depth + 1)
    end
  elseif filter isa SQLTypeQor
    for f in filter.or
      _guard_no_aggregate_predicate(f, instruc, depth + 1)
    end
  end
  return nothing
end

# The spelling that DOES filter on an aggregate expression, shared by the two #895 refusals.
const _AGGREGATE_EXPRESSION_ADVICE =
  "\e[4m\e[31mfilter(…)\e[0m — an expression containing an aggregate cannot be a WHERE predicate, " *
  "and PormG does not move it to HAVING. Project the expression under an alias and filter on the " *
  "alias, which renders as HAVING — \e[4m\e[32mvalues(\"raceid\", \"span\" => Max(\"milliseconds\") - " *
  "Min(\"milliseconds\")); filter(\"span__@gt\" => 1000)\e[0m (#895)."

# #895 — the right-hand side of a WHERE-bound pair: `filter("grid" => Max("grid"))` rendered
# `WHERE "Tb"."grid" = MAX("Tb"."grid")`, the left-hand twin of the `F` arm above. Called where a pair
# is pushed into WHERE — the top-level column and row-alias sites in `get_filter_query`, and
# `_get_where_query` for a split `Q` — and NOT in `_get_filter_query(::SQLTypeOper)`, which also
# renders a SELECT-side `When(...)`, where an aggregate is legal. An aggregate alias compared with an
# aggregate is not WHERE-bound (`HAVING COUNT(…) > MAX(…)` is legal), so the routing decides first and
# this never sees it. Asked after aliases resolve, as the `F` arm is.
function _guard_where_operand(v::SQLTypeOper, instruc::SQLInstruction)
  _expression_operand(v.values) || return nothing
  _resolved_window(v.values, instruc) && throw(QueryBuildError(
    "\e[4m\e[31mfilter(\"$(_filter_path_label(v))\" => …)\e[0m — the right-hand side contains a window " *
    "function, which cannot be a WHERE predicate: SQL evaluates windows after WHERE. " *
    _WINDOW_PREDICATE_ADVICE * " (#895)."))
  _resolved_contains_agg(v.values, instruc) && throw(QueryBuildError(
    "\e[4m\e[31mfilter(\"$(_filter_path_label(v))\" => …)\e[0m — the right-hand side contains an " *
    "aggregate, which cannot be a WHERE predicate, and PormG does not move it to HAVING. Project " *
    "the left-hand side as an aggregate alias and compare that, which renders as HAVING — " *
    "\e[4m\e[32mvalues(\"raceid\", \"worst\" => Max(\"milliseconds\")); " *
    "filter(\"worst__@gt\" => Min(\"milliseconds\") * 2)\e[0m (#895)."))
  return nothing
end

# #917 — the join-condition twin of `_guard_no_aggregate_predicate`. A join's ON conditions render
# through their own loop in `build_row_join_sql_text`, which never meets the `filter()` refusals, so
# `cjoin_on(…; on = [Count("resultid") > 1])` rendered `ON … AND (COUNT("Tb"."resultid") > ?)`, which
# both engines reject at execution. `on(…)` and `cjoin(…; filters = …)` reach the same loop through a
# `ModelJoin`'s `on_conditions` and had the same gap (`OP(Count("grid"), ">", 1)`,
# `"number" => Max("grid")`).
#
# A guard of its own rather than a clause label on the WHERE one: that guard's advice is an alias
# filter, which renders HAVING — wrong for an ON clause, where no clause at this query level can hold
# the predicate. Unlike WHERE there is no routing question, so both operands are asked alike, after
# aliases resolve, window first, as #895 does: `_contains_agg` also answers `true` for a window over an
# aggregate, and that one needs the window wording. Both walks enter an `OperObject` now (#928 taught
# `_is_window_expr` to); the operands are still asked one by one beside the whole pair, which is
# harmless and keeps each operand's own alias resolution. A subquery or `Exists(…)` is never
# entered: its aggregates belong to the inner statement. Depth cap as in `_guard_no_aggregate_predicate`.
function _guard_no_aggregate_on_condition(condition, row::JoinRow, instruc::SQLInstruction, depth::Int = 0)
  depth > 32 && return nothing
  if condition isa SQLTypeQ
    foreach(f -> _guard_no_aggregate_on_condition(f, row, instruc, depth + 1), condition.filters)
  elseif condition isa SQLTypeQor
    foreach(f -> _guard_no_aggregate_on_condition(f, row, instruc, depth + 1), condition.or)
  else
    # The pair itself is asked too: a plain key naming a projection alias renders that projection,
    # and only the whole pair is a condition leaf `_reads_alias` resolves — `"n" => 1` over
    # `"n" => Count(…)` rendered `ON … AND COUNT(…) = ?` with the operands asked alone (review of #917).
    operands = condition isa SQLTypeOper ? (condition, condition.column, condition.values) : (condition,)
    any(x -> _resolved_window(x, instruc), operands) && throw(QueryBuildError(
      "$(_on_condition_label(row)) — a window function cannot appear in a join's ON clause: SQL " *
      "evaluates windows after the join. " * _ON_CONDITION_ADVICE))
    any(x -> _resolved_contains_agg(x, instruc), operands) && throw(QueryBuildError(
      "$(_on_condition_label(row)) — an aggregate cannot appear in a join's ON clause: SQL joins " *
      "rows before it groups them. " * _ON_CONDITION_ADVICE))
  end
  return nothing
end

# The join the caller declared, in the spelling they wrote. A `ModelJoin` does not keep the path
# `on()`/`cjoin()` was given, only the table it reaches.
_on_condition_label(row::AnchorlessJoin) = "\e[4m\e[31mcjoin_on(alias = \"$(row.alias_b)\")\e[0m"
_on_condition_label(row::JoinRow) =
  "\e[4m\e[31mon(…) / cjoin(…; filters = …)\e[0m on the join to \"$(row.b)\""

# The spelling that DOES join on an aggregate or a window: materialize it one query level down, then
# join on the column it becomes. Separate from `_WINDOW_PREDICATE_ADVICE` on purpose — that one ends
# in a WHERE filter, this one is about the join.
const _ON_CONDITION_ADVICE =
  "Compute it in a CTE and join on its column — " *
  "\e[4m\e[32m.with(\"race_size\" => Result.objects.values(\"raceid\", \"n\" => Count(\"resultid\")), " *
  "join_field = \"raceid\" => \"raceid\")\e[0m, then \e[4m\e[32mfilter(\"race_size__n__@gt\" => 1)\e[0m (#917)."

# The spelling that DOES filter on a window, shared by the #537 refusal above and the #685 one below
# so they cannot drift. It
# was advice nobody could follow until #685: a window in a CTE body died typing its column
# (`_set_field_from_sql_function(::WindowFunction, …)`, ctes.jl), so the #537 message named a route
# that raised. The CTE materializes the window one query level down, where the outer WHERE can see it.
const _WINDOW_PREDICATE_ADVICE =
  "Compute it in a CTE and filter on its column — " *
  "\e[4m\e[32m.with(\"ranked\" => q, join_field = \"<pk>\" => \"<pk>\")\e[0m, joined on the primary key, then " *
  "\e[4m\e[32mfilter(\"ranked__rk\" => 1)\e[0m — or filter the fetched rows in Julia"

# #685 — `values("r" => Rank(…)); filter("r" => 1)` is the alias spelling of #537's window case. A
# plain key that names a projection alias is routed to HAVING (the documented aggregate spelling), and
# nothing looked at WHAT the alias projects, so a window rendered `HAVING RANK() OVER (…) = ?`: a
# `StatementError` on both engines, after the SQL was already sent. No placement at this query level
# is right — SQL evaluates windows after WHERE *and* HAVING — so refuse at build time and name the
# level where it is: a CTE. (Django ≥ 4.2 wraps the query in a subquery instead; #685 chose the
# explicit route, per the less-magic half of the design stance.)
#
# `_is_window_expr` walks `FExpression`/`FObject`, so `Rank(…) + 1` refuses too — it rendered the
# same HAVING. #722: and the question is asked after aliases resolve, so a projection whose condition
# reads a window alias — `"top" => Case([When("r" => 1, then = 1)])` over `"r" => Rank(…)`, which
# renders `CASE WHEN RANK() OVER (…) = ?` — refuses as the window alias itself does. `source` is
# `nothing` when the memo was written by a non-projection path; that is not a window, and the
# existing ladder handles it.
function _guard_window_alias_predicate(source, label::AbstractString, instruc::SQLInstruction)
  (source !== nothing && _resolved_window(source.field, instruc)) || return nothing
  throw(QueryBuildError(
    "\e[4m\e[31mfilter(\"$(label)\" => …)\e[0m — \e[31m$(label)\e[0m projects a window function, " *
    "and a window cannot be filtered in the query that computes it: SQL evaluates windows after " *
    "WHERE and HAVING. " * _WINDOW_PREDICATE_ADVICE * " (#685)."))
end

# #685 — the same refusal for an alias inside `Q(...)`/`Qor(...)`. Only a TOP-LEVEL alias key takes
# the HAVING branch in `get_filter_query`; inside a `Q` the key resolves through
# `_get_filter_query(::SQLTypeField)`, which reuses the projection's memoized text, so a window alias
# printed `RANK() OVER (…)` straight into WHERE — the same late driver error by another spelling.
#
# The check lives HERE, on the predicate walk, and not in `_get_filter_query(::SQLTypeField)` where
# the text is reused: that function also renders a SELECT-side `When("r" => 1)`, and
# `CASE WHEN RANK() OVER (…) = 1 …` in the select list is legal SQL. The clause cannot be told apart
# there on PostgreSQL, whose parameter object keeps no context. The alias test is the top-level
# branch's — a plain key naming no model field. A key that names a model field AND a window alias
# (`values("r" => "points", "points" => Rank(…)); filter(Q("points" => 5.0))`) never reaches here:
# #703's `_guard_field_alias_collision` refuses it first. This comment used to say such a key
# "still filters the column" — true only because `"r" => "points"` had claimed the memo entry
# first; with an aggregate alias the same key printed `SUM(…)` into WHERE. Recursive with
# `_guard_no_aggregate_predicate`'s depth cap.
function _guard_window_alias_in_q(filter, instruc::SQLInstruction, depth::Int = 0)
  depth > 32 && return nothing
  if filter isa SQLTypeOper
    col = filter.column
    _alias_filter_key(col, instruc) === nothing && return nothing
    key = memo_key(col)
    memo_projection(instruc, key) === nothing && return nothing
    _guard_window_alias_predicate(_projected_source(key, instruc), col.field, instruc)
  elseif filter isa SQLTypeQ
    for f in filter.filters
      _guard_window_alias_in_q(f, instruc, depth + 1)
    end
  elseif filter isa SQLTypeQor
    for f in filter.or
      _guard_window_alias_in_q(f, instruc, depth + 1)
    end
  end
  return nothing
end

# #692 — `values("c" => Count("id")); filter(Q("c" => 1))` printed `WHERE (COUNT(…) = ?)`, which both
# engines reject at execution. Only a TOP-LEVEL alias key took the HAVING branch in
# `get_filter_query`; inside a `Q` the key resolved through `_get_filter_query(::SQLTypeField)`, which
# reuses the projection's memoized text — #685's window defect, with an aggregate in it.
#
# `(key, cached)` when `v` compares an alias whose projection is an aggregate, `nothing` otherwise.
# The alias test is `_guard_window_alias_in_q`'s. Only an AGGREGATE alias is routed: a plain alias
# (`values("yr" => "date__@year"); filter(Q("yr" => 2020))`) renders correctly in WHERE today, and
# must stay there. The node's own flag is set by arithmetic (`Count(…) + 1`) and, since #702, by every
# wrapping constructor — `Coalesce(Sum(…), Value(0))` is an aggregate alias (`_any_agg`, types.jl).
# #722: that flag is set at construction and cannot see an aggregate reached through an alias a
# condition reads, so this gate asks `_resolved_agg` — the same test the top-level branch and the
# GROUP BY decision ask, so the three cannot disagree about one projection.
function _aggregate_alias_leaf(v::SQLTypeOper, instruc::SQLInstruction)
  col = v.column
  _alias_filter_key(col, instruc) === nothing && return nothing
  key = memo_key(col)
  cached = memo_projection(instruc, key)
  cached === nothing && return nothing
  source = _projected_source(key, instruc)
  (source !== nothing && _resolved_agg(source.field, instruc)) || return nothing
  return (key, cached)
end

# Split one `Q`/`Qor`/`F` filter into `(where_part, having_part)`, either of which may be `nothing`.
#
# - A leaf goes to HAVING when it is an aggregate-alias comparison, and to WHERE otherwise. An
#   `ExistsObject` or an `F` expression is a WHERE leaf.
# - A `Q` is an AND, so it splits the way the top-level `filter("c" => 1, "raceid" => 5)` always has:
#   the row terms filter rows before grouping, the aggregate terms filter groups. Django's
#   `WhereNode.split_having_qualify` splits an AND node the same way.
# - A `Qor` cannot be split — `a OR b` is not `WHERE a` plus `HAVING b` — so a mixed one is refused.
#   Django moves the whole OR to HAVING instead, which only works when every row term names a
#   grouped column and fails at the driver when one does not. The refusal names the explicit way to
#   put a grouped column in the same OR.
#
# A node that goes wholly to one side is returned as it was, not rebuilt, so its render is
# byte-identical to the one before #692. Depth cap as in `_guard_no_aggregate_predicate`; past it
# a node stays in WHERE, which is where every node went before.
function _split_having(filter, instruc::SQLInstruction, depth::Int = 0)
  depth > 32 && return (filter, nothing)
  if filter isa SQLTypeOper
    return _aggregate_alias_leaf(filter, instruc) === nothing ? (filter, nothing) : (nothing, filter)
  elseif filter isa Union{SQLTypeQ,SQLTypeQor}
    parts = [_split_having(f, instruc, depth + 1) for f in (filter isa SQLTypeQ ? filter.filters : filter.or)]
    all(p -> p[2] === nothing, parts) && return (filter, nothing)
    all(p -> p[1] === nothing, parts) && return (nothing, filter)
    if filter isa SQLTypeQor
      label = _having_leaf_label(first(p[2] for p in parts if p[2] !== nothing))
      throw(QueryBuildError(
        "\e[4m\e[31mQor(…)\e[0m mixes the aggregate alias \e[31m\"$(label)\"\e[0m with a condition on " *
        "rows. An aggregate alias filters groups (HAVING) and a column filters rows (WHERE), and an " *
        "OR cannot be split between the two clauses. To test a grouped column in the same OR, " *
        "project it as an aggregate alias as well, so every term filters groups — " *
        "\e[4m\e[32mvalues(\"raceid\", \"n\" => Count(\"resultid\"), \"race\" => Max(\"raceid\")); " *
        "filter(Qor(\"n\" => 20, \"race\" => 1))\e[0m (#692)."))
    end
    return (_and_of(FilterType[p[1] for p in parts if p[1] !== nothing]),
            _and_of(FilterType[p[2] for p in parts if p[2] !== nothing]))
  end
  return (filter, nothing)
end

# One side of a split `Q`. A single term is returned bare, so `Q("c" => 1, "raceid" => 5)` renders
# `HAVING COUNT(…) = ?` — the text the unwrapped `filter("c" => 1)` prints — not `HAVING (COUNT(…) = ?)`.
_and_of(terms::Vector{FilterType}) = length(terms) == 1 ? only(terms) : QObject(filters = terms)

# The alias the first HAVING leaf of a split part compares — for the mixed-`Qor` message.
_having_leaf_label(v::SQLTypeOper) = v.column.field
_having_leaf_label(q::SQLTypeQ) = _having_leaf_label(first(q.filters))
_having_leaf_label(q::SQLTypeQor) = _having_leaf_label(first(q.or))

# Render the HAVING half of a split. Every leaf in it passed `_aggregate_alias_leaf`, so it renders
# through the top-level alias branch's own code, `_render_alias_predicate`. The parentheses match
# `_get_filter_query(::SQLTypeQ/::SQLTypeQor)`. The caller holds the `:having` context.
function _get_having_query(v::SQLTypeOper, instruc::SQLInstruction)::String
  # #707: an expression on the right is a comparison, not a value to type — see the top-level branch.
  if _expression_operand(v.values)
    # #926 (review): a subquery on the right is evaluated after GROUP BY here — see `RenderScope`. The
    # caller set the `:group` phase; this names the alias the predicate compares.
    return with_scope(() -> _get_filter_query(v, instruc), instruc;
                      phase = :group, label = _having_subquery_label(something(_plain_filter_key(v.column), "?")))
  end
  having_key, having_cached = _aggregate_alias_leaf(v, instruc)
  return _render_alias_predicate(v, having_key, having_cached, instruc)
end
# What the #194 message calls the correlated subquery of a HAVING predicate on `alias`.
_having_subquery_label(alias::AbstractString) = "Subquery(…) in the HAVING filter on \"$(alias)\""
# #932: an alias predicate renders in the phase of the clause it was routed to — HAVING is evaluated
# after GROUP BY, a row alias's WHERE before it (the caller's `:row` phase stands).
_in_clause_phase(f, instruc::SQLInstruction, clause::Symbol, alias::AbstractString) =
  clause === :having ? with_scope(f, instruc; phase = :group, label = _having_subquery_label(alias)) : f()
_get_having_query(q::SQLTypeQ, instruc::SQLInstruction)::String =
  "(" * join([_get_having_query(v, instruc) for v in q.filters], " AND ") * ")"
_get_having_query(q::SQLTypeQor, instruc::SQLInstruction)::String =
  "(" * join([_get_having_query(v, instruc) for v in q.or], " OR ") * ")"

# #707 — the WHERE half of a split, rendered so a ROW-alias leaf takes the typed renderer the
# top-level spelling takes. `Q("nm" => "hamilton")` over `Lower("surname")` rendered through
# `_get_filter_query(::SQLTypeOper)`, which has no field to type the value against: the value bound
# unchecked (`Q("pts" => "not-a-number")` over `F("points")` reached the driver), and neither the
# #596 bytes guard nor the #618 JSON-operator refusal ran. The top-level `filter("pts" => …)` had all
# three. Now both spellings reach `_render_alias_predicate`, so there is one typing rule.
#
# This lives on the FILTER walk, not in `_get_filter_query(::SQLTypeOper)`: that function also
# renders a SELECT-side `When("r" => 1)`, where reading a window or aggregate alias is legal SQL
# (`_guard_window_alias_in_q`'s note), and `_render_alias_predicate` would refuse it. Parentheses
# match `_get_filter_query(::SQLTypeQ/::SQLTypeQor)`, so a `Q` with no alias leaf renders as before.
# The caller holds the `:where` context.
function _get_where_query(v::SQLTypeOper, instruc::SQLInstruction)::String
  _guard_where_operand(v, instruc)   # #895: every leaf here is WHERE-bound
  hit = _row_alias_leaf(v, instruc)
  hit === nothing && return _get_filter_query(v, instruc)
  return _render_alias_predicate(v, hit[1], hit[2], instruc)
end
_get_where_query(q::SQLTypeQ, instruc::SQLInstruction)::String =
  "(" * join([_get_where_query(v, instruc) for v in q.filters], " AND ") * ")"
_get_where_query(q::SQLTypeQor, instruc::SQLInstruction)::String =
  "(" * join([_get_where_query(v, instruc) for v in q.or], " OR ") * ")"
_get_where_query(v, instruc::SQLInstruction)::String = _get_filter_query(v, instruc)

# Is a predicate's right-hand side an expression (rendered as SQL) rather than a value (bound)?
# The node kinds `OperObject.values` admits besides literals, and a membership list holding one.
# #926 added `SubqueryObject` with its slot: a scalar subquery renders as SQL, so an alias compared with
# one takes the WHERE renderer, not the typed binder, which handed the node to a value formatter.
_expression_operand(x) = x isa Union{SQLTypeF,SQLTypeFunction,SQLTypeCTE,SQLTypeJoined,SQLObjectHandler,SubqueryObject}
_expression_operand(x::AbstractVector) = any(_expression_operand, x)

# `(key, cached)` when `v` compares a projection alias the WHERE half of a split holds — a plain key
# naming no field, memoized under its own output name. `_split_having` has already moved every
# aggregate-alias leaf out, so what remains here is a row alias. The output-name test is
# `_alias_lhs`'s: a path projection is memoized under its PATH, and is a column, not an alias.
function _row_alias_leaf(v::SQLTypeOper, instruc::SQLInstruction)
  # An expression on the right is a column comparison, not a value to type: the WHERE path renders
  # it (`WHERE ("Tb"."points" = "Tb"."grid")`), and did before #707. Routing it here handed the
  # node to a value formatter — a `MethodError`, or worse, the node bound as a parameter.
  _expression_operand(v.values) && return nothing
  col = v.column
  _alias_filter_key(col, instruc) === nothing && return nothing
  key = memo_key(col)
  cached = memo_projection(instruc, key)
  (cached === nothing || _projection_output_name(cached) != key[2]) && return nothing
  return (key, cached)
end
