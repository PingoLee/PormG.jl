# `build` — one query object to one `InstructionObject` (#130 split the rest of this file out):
# it drives `build_select.jl` and `build_filter.jl`, renders the JOIN clauses row by row, groups
# the columns a window reads, and refuses an aggregate fan-out or a mixed grouping before any SQL
# runs.

# #789 — the columns a window READS join GROUP BY. Django's `Window.get_group_by_cols`.
#
# An aggregating statement must group every column it reads outside an aggregate, and a window's
# `PARTITION BY` / `ORDER BY` reads columns without projecting them. #776 made `Lag(Sum(…))` set the
# aggregate flag, so its projected neighbours were grouped, but a column named only inside `OVER (…)`
# was not: PostgreSQL raised `GroupingError`, and SQLite collapsed the statement onto one arbitrary
# row per group, silently. The same held for a plain `Rank()` beside a `Sum(…)`. This is the implicit
# grouping `get_order_query` already applies to a query-level ORDER BY term outside the projection
# (its `push!(instruc.group, …)`, in `build_select.jl`), extended to the window's own ORDER BY and
# PARTITION BY.
#
# Runs after `get_order_query`, so the group set it deduplicates against is complete, and before
# `_check_grouped_correlation`, which reads the final set. `instruc.aggregate` is final by then (its
# only writer is `get_select_query`). The terms were recorded by `_build_over_clause` as they
# rendered, so each keeps that render's text and values: on a positional backend the values are
# needed a second time under `:group`, exactly as #587's are, and a second render would bind them twice.
#
# A term is left out when grouping it again would change nothing, and only when that is provable:
#   - placeholder-free text already grouped — a projected column (`GROUP BY 1`), or an ORDER BY term.
#     Text alone cannot decide it for a binding term: `F("points") + 1` and `+ 2` render the same `?`.
#   - an exact repeat, text and values, of a term this pass already grouped.
# A missed duplicate is legal and merely noisy; a wrong one would drop a grouping.
function _group_window_terms!(instruc::SQLInstruction)
  instruc.aggregate || return nothing
  isempty(instruc.window_group_terms) && return nothing
  grouped_text = Set(_grouped_expressions(instruc))
  seen = Set{Tuple{String,Vector{Any}}}()
  for term in instruc.window_group_terms
    sql, params = term
    term in seen && continue
    push!(seen, term)
    binds = occursin('?', sql) || occursin(r"\$\d", sql)
    (!binds && sql in grouped_text) && continue
    push!(instruc.group, sql)
    copy_parameters_to!(instruc, :group, params)
  end
  return nothing
end

# The JOIN clauses, one row at a time in `row_join` order. Each row's ON conditions render where the
# row is emitted, so on a positional backend their values bind in the order their markers appear
# (#421) by construction: a condition renders in exactly one place, and nothing it renders can land on
# another row.
#
# That used to be false. A `cjoin_on` condition naming a path (`"driverid__code"`) joined that path
# WHILE it rendered, after its own row. So every condition was pre-rendered first (Phase 1), the SQL
# text was scanned for each alias and a forward reference moved onto the later join it named
# (Phase 1b), and each fragment carried its own values so SQLite still bound in text order
# (`OnExtra`). Binding retired all three — #977 for path joins, #982 for `cjoin_on`: every row a
# condition can name is built before this runs, and `_assert_condition_added_no_join` raises when one
# is not, for every row kind.
#
# Context: every value lands in `:join`, under one `with_bucket` that restores the caller's bucket
# on return (#936, #939). It used to be set ungated per row, a belt-and-braces switch: the nested
# renders a condition can hold already restored the bucket by hand. They now restore through
# `with_bucket` structurally, so one scope covers the loop. A subquery consumed by `@in`,
# `Subquery(...)` or `Exists(...)` may not declare its own CTE (#433): that was the one shape whose
# values went to `:cte` while its markers sat in this text.
function build_row_join_sql_text(instruc::SQLInstruction)
  @pormg_debug false
  with_bucket(instruc, :join) do
    for idx in 1:length(instruc.row_join)
      value = instruc.row_join[idx]
      b_quoted = safe_table_identifier(value.b, instruc.connection)
      alias_b_quoted = quote_identifier(value.alias_b, instruc.connection)

      # #44: a CROSS-joined CTE (no join_field) has no key columns and no ON — the correlation is
      # supplied by the main query's F() filter(s) in WHERE. The row kind carries no conditions, and no
      # condition can move onto it any more (#424 was a predicate relocated here and dropped).
      if value isa CrossJoin
        push!(instruc.join, """ CROSS JOIN $b_quoted AS $alias_b_quoted """)
        continue
      end

      # #985: under the row's join scope, so every column the conditions render is checked against the
      # rows this ON clause may name (`_record_join_column`).
      conditions = _join_scope(() -> _render_on_conditions(instruc, value), instruc, idx, value)
      if value isa AnchorlessJoin
        # #45: anchor-less join — the ON clause is entirely the caller's conditions (no equi-anchor).
        # Never empty: binding refuses an ON clause that never names this alias (#448), which an empty
        # one cannot, and `_cjoin_on` refuses an empty `on` at the call.
        on_clause = join(conditions, " AND ")
      else
        alias_a_quoted = quote_identifier(value.alias_a, instruc.connection)
        # #394: escape-only, because on every model-join branch these are PHYSICAL columns
        # (`Models.model_column`). The one exception is a CTE join, where `key_b` is the CTE's
        # projection ALIAS (`build_joins.jl` builds the `CteJoin` with `key_b = cte_table_key`). That name is
        # not unguarded: `_build_row_join` raises `UnknownFieldError` unless it matches a field of
        # the CTE model, and that field came from a `values()` alias, which `_query_select` renders
        # through the fail-closed `quote_identifier`. So the strict check happens where the caller
        # wrote the name, exactly as it does for the CTE name itself since #394.
        # Only the two keyed kinds reach this branch (#487): `CrossJoin` and `AnchorlessJoin` left above.
        value = value::Union{ModelJoin,CteJoin}
        key_a_quoted = safe_column_identifier(value.key_a, instruc.connection)
        key_b_quoted = safe_column_identifier(value.key_b, instruc.connection)
        on_clause = "$alias_a_quoted.$key_a_quoted = $alias_b_quoted.$key_b_quoted"
        for sql in conditions
          on_clause *= " AND $(sql)"
        end
      end

      push!(instruc.join, """ $(value.how) JOIN $b_quoted AS $alias_b_quoted ON $on_clause """)
    end
  end
  return nothing
end

# One row's ON conditions, rendered in vector order — the order their markers appear in. `instruc.alias`
# is not remapped (#946): binding put each column on its row, and what is still under the base alias
# genuinely names the base row, above all an `OuterRef` in a nested `Subquery`.
function _render_on_conditions(instruc::SQLInstruction, value::JoinRow)::Vector{String}
  out = String[]
  for condition in _on_conditions(value)
    _guard_no_aggregate_on_condition(condition, value, instruc)   # #917
    rows_before = length(instruc.row_join)
    push!(out, _get_filter_query(condition, instruc))
    # #977/#982: binding built every row a condition can name before anything rendered, so a row
    # appearing now is a binding gap, not a join to emit.
    _assert_condition_added_no_join(instruc, value, rows_before)
  end
  return out
end

function build(object::SQLObject;
  table_alias::Union{Nothing,SQLTableAlias}=nothing,
  connection::Union{Nothing,PormGPostgres,PormGSQLite}=nothing,
  parameters::Union{Nothing,AbstractPormGParam}=nothing,
  outer::Union{Nothing,SQLInstruction}=nothing)

  settings, connection, conn_key = get_settings(object, connection=connection)
  ensure_transaction_scope(object.model, connection)

  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters === nothing && (parameters = get_parameter(connection))
  @pormg_debug false
  instruct = InstructionObject(text="",
    object=object,
    table_alias=table_alias === nothing ? SQLTbAlias() : table_alias,
    alias=get_alias(table_alias),
    connection=connection,
    # `_django_app_label` rather than a bare `=== nothing` check (#345): an empty prefix is the
    # absence of one, and this must agree with `Model_to_str`/`get_model_name` or the two disagree
    # about the same connection. With `django_prefix: ''` the old spelling produced `django == "_"`,
    # so the reverse-join table fallback below prefixed every unpinned table with an underscore.
    django=(_app_label = Models._django_app_label(settings); _app_label === nothing ? nothing : _app_label * "_"), # TODO, remover
    parameters=parameters,
    outer=outer,
  )

  # #492: resolve `"<cte>__<col>"` string paths into `CTE(...)` handles, and refuse a name that is
  # ambiguous. This runs HERE — after the instruction exists, before anything reads a projection or
  # a predicate — because it is the first moment the CTE registry is final. Doing it at `.filter()` /
  # `.values()` / `.on()` time instead makes the answer depend on whether `.with()` was called first,
  # which is precisely the #434 defect whose call-time check `_on` records removing. Read entry
  # points deepcopy the handler before `build()`, so this mutates a per-call copy.
  _resolve_cte_string_paths!(object)
  # #977: same moment, same reason — every relation and `cjoin` link the join conditions could name
  # is declared now, so this is where they are bound onto their paths and checked (#962, #974).
  _bind_join_conditions!(instruct)

  # Each SQL section binds under its own bucket, so positional-parameter backends (SQLite) file every
  # value under the clause its `?` prints in. Every section is a `with_bucket` scope, so `build()`
  # hands its caller back the bucket it was entered with (#936, #939). A NESTED build is no exception:
  # it files its values under its own clauses too, which is what lets the nested render that called it
  # lift them out as one clause-ordered run (#432, `detach_nested_run!`). That replaced the old
  # `set_contexts=false` mode, in which a subquery inherited its parent's bucket and so lost the
  # clause roles the run sorts by; nothing reached that mode after #432.
  # #932 — the evaluation phase of each clause, for the #194 guard. Only clauses set it (see
  # `RenderScope`): the SELECT list and ORDER BY are evaluated after GROUP BY, WHERE and ON before it.
  # HAVING sets its own inside `get_filter_query`, and a grouping aggregate's argument in
  # `_render_function_typed`.
  with_bucket(instruct, :select) do
    with_scope(() -> get_select_query(object.values, instruct), instruct; phase = :group)
  end
  _record_wildcard_projection_kinds!(instruct)

  with_bucket(instruct, :where) do
    with_scope(() -> get_filter_query(object, instruct), instruct; phase = :row, label = "a filter")
  end

  # #404: ORDER BY resolves HERE, before build_row_join_sql_text renders row_join into SQL. A path
  # named ONLY by order_by() is resolved through _get_select_query → _build_row_join, which APPENDS
  # to row_join; running after the render left that entry un-emitted, so the ORDER BY referenced an
  # alias the query never joined — a loud failure on both backends ("missing FROM-clause entry" /
  # "no such column"). Ordering a path that is also projected or filtered was always fine: it takes
  # the instruc.cache branch and discovers nothing.
  #
  # Only the position relative to the RENDER matters for CORRECTNESS. Whether this sits before or
  # after the cjoin loops below is immaterial there: every row a join condition names is built before
  # build_row_join_sql_text runs (#977, #982), whichever step appended it. It is
  # placed before them so the three "resolve everything" steps (select, filter, order) read as one
  # block. It is not free to move, though: the order joins are appended in decides ALIAS NUMBERING,
  # and test/unit/test_order_by_joins.jl pins concrete Tb_1/Tb_2/Tb_3 names, so a reorder rewrites
  # those expectations rather than passing silently.
  #
  # Context (#587): ORDER BY binds under its OWN bucket, `:order`, which `_BUCKET_ORDER`
  # (parameters.jl) flattens last — where the clause prints. It used to render under `:join` because
  # no bucket existed, and `:join` flattens BEFORE `:where`: an ordering expression that binds (the
  # `@yyyy_q` / `@yyyy_quad` labels bind nine operands) shifted every WHERE value by that many
  # positions, the counts still matched, and SQLite returned the wrong rows without an error.
  # PostgreSQL numbers `$N` at render and was always right. In a nested build the `:order` values are
  # lifted into text order by `detach_nested_run!` like any other clause's.
  with_bucket(instruct, :order) do
    with_scope(() -> get_order_query(object, instruct), instruct; phase = :group, label = "an order_by term")
  end
  _group_window_terms!(instruct)   # #789: after ORDER BY, which also extends GROUP BY

  # PATH loop — materialize the `cjoin` and `on()` joins that traversal did not already discover. This
  # ensures their conditions apply even in UPDATE/DELETE without explicit field paths. `row_path` is the
  # membership test that avoids materializing one twice.
  #
  # #977: an `on()`-only entry is built too. It used to only decorate whatever join traversal built
  # for the path, so with nothing else reaching it the predicate — and an explicit `join_type =
  # "INNER"` — vanished from the statement with no error. `on(path, …)` names its join; it now
  # declares it.
  # #932: join conditions — a `cjoin` filter, an `on()`, a `cjoin_on` ON — are evaluated per row.
  # The two loops below run under `:where`, the bucket they always ran under (ORDER BY used to reset to
  # it). Materializing a row binds nothing itself (`build_joins.jl` has no `add_parameter!`; every ON
  # value binds in `build_row_join_sql_text`, under `:join`), and the explicit scope keeps anything
  # they ever do bind where it was, instead of in `build()`'s caller's bucket.
  with_scope(instruct; phase = :row, label = "a join condition") do
    with_bucket(instruct, :where) do
      for (path, config) in object.custom_join
        _refuse_many_to_many_join_path(object, path)
        # Membership by CANONICAL path (#977): `row_path` holds each traversal's own spelling, so
        # `on("status", …)` must recognise a join `values("status_id__name")` built.
        key = _join_key(instruct, path)
        any(p -> _join_key(instruct, p) == key, instruct.row_path) && continue
        _build_row_join(_join_path_columns(object, path, config), instruct)
      end

      # ALIAS loop (#45) — materialize the anchor-less `cjoin_on` joins: no equi-anchor, explicit alias,
      # user-supplied ON.
      #
      # It does NOT consult `row_path` (#484). `row_path` records JOIN PATHS, and an alias is not one —
      # while both namespaces shared `custom_join`, an alias equal to a traversed ForeignKey path was
      # found there and the join was skipped entirely, leaving the statement naming a range variable it
      # never declared. The path loop above still needs the test, because a `cjoin` path IS what
      # traversal records. Two loops rather than one because the two namespaces materialize differently
      # — and the alias loop runs second, which is what keeps a `cjoin_on` join's generated-alias
      # numbering behind the joins traversal built (#480 reserves the declared aliases so they cannot
      # collide in either direction).
      #
      # #982: first the relation paths a `cjoin_on` ON clause names, so every row it can name precedes
      # it; then the aliases in dependency order (`_bind_cjoin_on_conditions!`). Each path goes through
      # the same `_build_row_join` call its column's render makes, so that render finds the row and adds
      # none.
      for segments in instruct.cjoin_on_paths
        _build_row_join(segments, instruct, as = false)
      end
      for user_alias in instruct.cjoin_on_order
        _build_cjoin_on_row_join(object.alias_join[user_alias], user_alias, instruct)
      end
    end

    build_row_join_sql_text(instruct)
  end

  _check_aggregate_fanout(instruct)      # #74: refuse silently-inflated aggregates over to-many joins
  _check_grouped_correlation(instruct)   # #194: refuse a correlated projection on an ungrouped column
  _check_mixed_grouping(instruct)        # #798: refuse a mixed column+aggregate term on an ungrouped column

  return instruct
end

# #74 fan-out guard ------------------------------------------------------------------------------
# A to-many join (reverse FK / many-to-many) repeats base-table rows, so COUNT/SUM/AVG over a column
# from a row-multiplied table silently inflates the result. We refuse those at build time rather than
# return a confidently-wrong number. The legitimate case — aggregating the to-many table's OWN column
# (the sole many-side) — is preserved. MAX/MIN are immune; `distinct=true` is an explicit opt-in.
function _check_aggregate_fanout(instruct::SQLInstruction)
  isempty(instruct.agg_sources) && return nothing
  # Derive the many-side aliases from the *deduped* row_join. A join can be built more than once
  # (e.g. _cache_join pre-builds a filter join, then it is built again for real); _insert_join keeps
  # only one entry, so deriving here counts each actual to-many join exactly once.
  many = Set{String}()
  for r in instruct.row_join
    _to_many(r) && push!(many, r.alias_b)
  end
  isempty(many) && return nothing
  n = length(many)
  for a in instruct.agg_sources
    a.distinct && continue
    ambiguous = a.alias == "\0AMBIGUOUS"
    # Safe only when the aggregate targets the sole to-many table's own column.
    (!ambiguous && a.alias in many && n == 1) && continue
    throw(QueryBuildError(_fanout_error_msg(a, many, ambiguous)))
  end
  return nothing
end

function _fanout_error_msg(a, many, ambiguous::Bool)
  paths = join(sort!(collect(many)), ", ")
  reason = ambiguous ?
    "the aggregated expression spans more than one source, so it cannot be proven safe under a row-multiplying (to-many) join" :
    "it aggregates a column from a table that a to-many join row-multiplies"
  string(
    "PormG fan-out guard (#74): the aggregate \e[4m\e[31m", a.label, "\e[0m is inflated because ", reason, ".\n",
    "  A to-many join (reverse foreign key or many-to-many) repeats base-table rows, so ", a.func,
    " would count/sum each base row once per related row.\n",
    "  To-many table alias(es) in this query: \e[33m", paths, "\e[0m.\n",
    "  Fix one of:\n",
    "    \e[32m1.\e[0m Aggregate the RELATED table's own column instead (e.g. count related rows: Count(\"reverse_relation__id\")).\n",
    "    \e[32m2.\e[0m Pass \e[32mdistinct=true\e[0m to the aggregate if de-duplicated counting is what you want.\n",
    "    \e[32m3.\e[0m Compute the aggregate in a correlated \e[32mSubquery(...)\e[0m projected in values() " *
    "(correlate the inner query with \e[32mOuterRef(...)\e[0m) so the base rows are not multiplied.\n")
end

# #194 grouped-correlation guard -------------------------------------------------------------------
# A correlated Subquery/Exists projected in a query that AGGREGATES is only meaningful when the outer
# column it correlates on has one value per output row. When it does not, the backends diverge:
# PostgreSQL refuses ("subquery uses ungrouped column ... from outer query"), while SQLite runs it
# against an ARBITRARY row of each group and returns a plausible-looking wrong number. Both measured
# on PostgreSQL 16 and SQLite 3.45. Same fail-loud stance as the #74 guard above.
#
# WHY IT RUNS AT THE END OF build() and not where the old #194 warn sat (end of get_select_query):
# `get_order_query` pushes into `instruct.group` too, for an ORDER BY term the projection does not
# contain. So
#     values("nationality", "n" => Count("driverid"), "s" => Subquery(<correlates on surname>))
#     order_by("surname")
# emits `GROUP BY 1, "Tb"."surname"` — the correlation IS grouped, reached only through order_by.
# Guarding at the select site refuses that query. `test_alignment_sqlite.jl` pins it.
#
# It deliberately does NOT require a non-empty group set. A whole-table aggregate
# (`values("n" => Count(...), "s" => Subquery(...))`) renders with no GROUP BY at all and is the most
# broken shape of the lot — PostgreSQL rejects it outright (measured) — yet the old warn, which
# tested `!isempty(group)`, never fired on it.
#
# WHICH refs it checks (#932): the recorder keeps every rendered OuterRef with the phase of the clause
# it was evaluated in, and only those read AFTER grouping need a grouped column. It used to decide by
# which render entry point the subquery reached — a different question that agreed most of the time,
# and each disagreement had become a patch (#194's projected arms, #926's split, its HAVING fix).
function _check_grouped_correlation(instruct::SQLInstruction)
  instruct.aggregate || return nothing        # no aggregate ⇒ one output row per input row ⇒ safe
  isempty(instruct.outer_refs) && return nothing
  grouped = _grouped_expressions(instruct)
  for c in instruct.outer_refs
    c.phase === :row && continue              # WHERE, ON, an aggregate's argument: before GROUP BY
    c.group_key && continue                   # inside an expression grouped whole: evaluated per row
    c.expr in grouped && continue             # the correlated column is grouped
    throw(QueryBuildError(_ungrouped_correlation_error_msg(c, grouped)))
  end
  return nothing
end

# `instruct.group` is a MIXED vector, and this is the whole reason the guard needs a derivation step
# rather than a direct membership test:
#   - get_select_query pushes a POSITIONAL INDEX into `object.values` ("1", "2", …)
#   - get_order_query pushes an ALREADY RENDERED expression (`"Tb"."surname"`)
# Resolving the index through `instruct.select[i].field` puts both kinds into the same vocabulary the
# recorder stores — rendered SQL — so no semantic bookkeeping is needed on either side.
#
# WHY THE TWO SIDES AGREE, precisely — they do NOT come from one function, and assuming they do is
# how this would rot. A group entry is rendered by `_get_select_query(::String, …)`; the recorder's
# `expr` by `_get_filter_query(::String, …)`. Those are different methods with different heads (the
# select arm has a `"*"` fast path and a `memo_field!` write; the filter arm peels `__@` transforms),
# but they share the resolution tail, and the `as` kwarg that appears to separate them is never read
# in `_build_row_join`. Join-alias numbering matches for a `__` path in either render order because
# `_build_row_join` memoizes on `row_path`. Measured: a joined path and a `__@`-transform column both
# compare equal from the two sides. If the two String arms ever diverge in the tail, this guard gets
# false positives — pin it with a test there rather than widening the comparison here.
#
# `all(isdigit, g)` distinguishes the two: the order_by push only happens on its `!found_in_select`
# branch, where `field` is a resolved expression and always carries a non-digit. If that branch ever
# changes to push the degraded bare alias instead, a one-character alias could collide here.
function _grouped_expressions(instruct::SQLInstruction)::Vector{String}
  out = String[]
  for g in instruct.group
    if !isempty(g) && all(isdigit, g)
      i = parse(Int, g)
      (1 <= i <= length(instruct.select) && isassigned(instruct.select, i)) || continue
      push!(out, string(instruct.select[i].field))
    else
      push!(out, g)
    end
  end
  return out
end

# The actionable lines name `c.column`, never `c.ref` or a rendered expression. The two differ for
# `OuterRef("pk")`, where `ref` is the literal "pk" and `column` is the resolved key name — and "add
# \"pk\" to values(...)" is not merely unhelpful, it is a second error (`UnknownFieldError`: there is
# no column named `pk`). Same rule the #76 DISTINCT throw states in `get_order_query`: a diagnosis
# line may carry an internal name, a *fix* line must be something the user can paste back. That is
# also why fix 2 does not echo the `Grouped by:` expressions — those are rendered SQL
# (`"Tb"."nationality"`), which is not valid `OuterRef(...)` input.
function _ungrouped_correlation_error_msg(c::CorrelatedRef, grouped::Vector{String})
  groups = isempty(grouped) ?
    "(none — this query aggregates the whole table into a single row)" :
    join(grouped, ", ")
  string(
    "PormG grouped-correlation guard (#194): the projected correlated column \e[4m\e[31m", c.label,
    "\e[0m correlates on \e[4m\e[31m", c.column, "\e[0m, which this query does not GROUP BY.\n",
    "  The outer query aggregates, so each output row stands for many input rows and ", c.column,
    " has no single value to correlate against. PostgreSQL refuses this (\"subquery uses ungrouped ",
    "column ... from outer query\"); SQLite runs it against an ARBITRARY row of each group and returns ",
    "a plausible-looking wrong number, so PormG refuses it on both backends.\n",
    "  Grouped by: \e[33m", groups, "\e[0m.\n",
    "  Correlated on: \e[33m", c.expr, "\e[0m.\n",
    "  Fix one of:\n",
    "    \e[32m1.\e[0m Project the correlated column so it joins the group set — add \e[32m\"", c.column,
    "\"\e[0m to \e[32mvalues(...)\e[0m. This is needed even when the query already groups by the ",
    "primary key: PostgreSQL would accept that shape (every column is functionally dependent on the ",
    "key), but PormG does not infer the dependency and refuses it on both backends rather than let ",
    "the rule differ per engine.\n",
    "    \e[32m2.\e[0m Correlate on a column the query already groups by — change \e[32mOuterRef(\"",
    c.ref, "\")\e[0m to name one of them.\n",
    "    \e[32m3.\e[0m Drop the outer aggregate: a scalar \e[32mSubquery(...)\e[0m already returns one ",
    "value per outer row and needs no outer GROUP BY — that is the fan-out-safe #92 shape.\n")
end

# #798 mixed-grouping guard -----------------------------------------------------------------------
# A MIXED term is a column expression with an aggregate inside it: `F("raceid") + Sum("points")`,
# `Coalesce("raceid", Sum(…))`, a `Case` whose condition reads a column and whose branch aggregates,
# or a window term of that shape (`partition_by = [F("raceid") + Sum("points")]`). It is computed once
# per group, so every column it reads OUTSIDE its aggregate calls must have one value per group.
# Nothing grouped them: the projection loop leaves an aggregate-bearing projection out of GROUP BY
# whole, and `_build_over_clause` leaves a mixed OVER term out whole (#789 — grouping `SUM(…)` is an
# error on both engines). PostgreSQL then refused the statement (`GroupingError`); SQLite ran it and
# answered with an ARBITRARY row's value per group — the #776/#789 silent failure mode again.
#
# Refused rather than grouped (maintainer's call on #798, the "less magic" side of the design stance):
# Django walks into the term and groups what it finds, which picks the grouping granularity for the
# user. Refusing names the column and the two fixes, and a term whose columns ARE grouped still builds.
#
# A window's PLAIN argument is the same read (#809): `LAG("Tb"."raceid") OVER (…)` beside a `SUM` is
# computed per group, and neither #789 (OVER terms only) nor the projection loop groups `raceid`.
# Refused too — the maintainer's call on #809, where Django agrees for once: `Window.get_group_by_cols`
# groups the partition and order terms, never the source expression.
#
# It runs beside #194, at the end of `build()`, for #194's reason: `get_order_query` and
# `_group_window_terms!` extend GROUP BY after the projection loop, so only the end sees the final set.
# The one render it performs — a leaf's BASE column, to compare against that set — binds nothing and
# re-resolves a path the mixed term's own render already resolved, so the join memo adds no join.
# A transformed leaf is never rendered whole — `date__@yyyy_q` binds nine values, and PostgreSQL's
# `$N` counter cannot be rewound — and that holds for a `Joined("d", "seen__@year")` handle too, whose
# base is peeled to `Joined("d", "seen")`. A transform is matched structurally instead: by its path
# key (rule 2 in `_mixed_leaf_grouped`), or, where the transform already arrives built inside a
# function argument (`Concat("born__@year", …)` holds `EXTRACT(born)`), by `_mixed_node_signature`
# against the grouped projections' nodes. A transform that BINDS (`@yyyy_q`) and is matched this way
# still fails on PostgreSQL, whose two copies carry different `$N` — loudly, at execution, as it did
# before; SQLite reads it correctly. Refusing it would break a correct SQLite query to make the
# engines agree on an error, so it is left as it was.
#
# Like #194, PormG does not infer functional dependency on a grouped primary key: PostgreSQL accepts
# `values("resultid", "x" => F("raceid") + Sum(…))`, PormG refuses it on both backends rather than let
# the rule differ per engine. Relaxing that later would only widen what is accepted.
function _check_mixed_grouping(instruct::SQLInstruction)
  instruct.aggregate || return nothing
  projections = instruct.object.values
  grouped_positions = Set{Int}()
  for g in instruct.group
    (!isempty(g) && all(isdigit, g)) && push!(grouped_positions, parse(Int, g))
  end
  grouped_keys = Set{String}()
  grouped_nodes = Set{Any}()
  for i in grouped_positions
    1 <= i <= length(projections) || continue
    key = _grouped_projection_key(projections[i])
    key === nothing || push!(grouped_keys, key)
    sig = projections[i] isa SQLTypeField ? _mixed_node_signature(projections[i].field) : nothing
    sig === nothing || push!(grouped_nodes, sig)
  end
  covered = node -> !isempty(grouped_nodes) && _mixed_node_signature(node) in grouped_nodes
  grouped_text = nothing   # rendered lazily: most mixed terms read a column that is projected as-is
  for (i, v) in enumerate(projections)
    i in grouped_positions && continue
    v isa SQLTypeField || continue
    v.field isa Union{SQLTypeFunction,SQLTypeF} || continue
    _each_bare_column(v.field, instruct, ""; covered) do clause, leaf
      grouped_text === nothing && (grouped_text = Set(_grouped_expressions(instruct)))
      _mixed_leaf_grouped(leaf, grouped_keys, grouped_text, instruct) && return nothing
      throw(QueryBuildError(_ungrouped_mixed_error_msg(_projection_output_name(v), clause, leaf,
                                                       _grouped_expressions(instruct))))
    end
  end
  return nothing
end

# The path key a leaf is matched on: the path as written, `@` kept. It used to fold `__@` into `__`
# so a `"born__@year"` leaf matched the `_as` a `values("born__@year")` projection carries
# (`"born__year"`) — which made it match the plain path `"born__year"` too, the related column when
# `born` is a foreign key: `values("raceid__@year", "x" => F("raceid__year") + Sum(…))` passed as
# grouped and read an ungrouped `"Tb_1"."year"` (#1004). The projection side now keys by its memo
# name, which keeps the `@` too, so the two spellings match each other and nothing else.
_mixed_path_key(path::AbstractString)::String = String(path)

# The keys of the three namespaces a leaf can live in, kept apart so a `Joined("d", "seen")` and a
# ForeignKey path `"d__seen"` can never match each other.
_joined_path_key(alias::AbstractString, path::AbstractString)::String =
  string("joined:", alias, "__", _mixed_path_key(path))
_cte_path_key(name::AbstractString, path::AbstractString)::String =
  string("cte:", name, "__", _mixed_path_key(path))

# The path a GROUPED projection groups, when it is a column or a transform of one — what rule 2 and
# the render-free half of rule 1 match against. `nothing` for anything else (a grouped `F` arithmetic
# projection is still compared by rendered text).
function _grouped_projection_key(v)::Union{Nothing,String}
  v isa SQLTypeField || return nothing
  f = v.field
  f isa AbstractString && return _mixed_path_key(f)
  f isa JoinedReference && return _joined_path_key(f.alias, f.path)
  f isa CTEReference && return _cte_path_key(f.name, f.path)
  f isa FExpression && f.operation === nothing && f.field_name isa AbstractString &&
    return _mixed_path_key(f.field_name)
  # `values("born__@year")` arrives as `SQLField(EXTRACT(born), _as = "born__year")` with the memo
  # name `"born__@year"`, and `values(Joined("d", "seen__@year"))` as `SQLField(EXTRACT(Joined("d",
  # "seen")))` named `"d__seen__@year"`. Keyed by the memo name, which keeps the `@` (#1004).
  if f isa FObject && !f.aggregate && v isa SQLField && _is_transform_term(v)
    return _reads_joined(f) ? string("joined:", memo_name(v)) : memo_name(v)
  end
  return nothing
end

# Does a built transform read a joined-copy column? A composite label (`@yyyy_q`) nests it several
# calls deep, so the whole node is searched, not only its `column`.
function _reads_joined(x, depth::Int = 0)::Bool
  depth > 32 && return false
  x isa JoinedReference && return true
  x isa AbstractVector && return any(v -> _reads_joined(v, depth + 1), x)
  x isa SQLTypeField && return _reads_joined(x.field, depth + 1)
  x isa FObject && return _reads_joined(x.column, depth + 1) ||
                          any(v -> _reads_joined(v, depth + 1), values(x.kwargs))
  return false
end

# A structural fingerprint of a node, so a grouped projection reused inside a mixed term is
# recognised: `values("rp" => F("raceid") * F("points"), "x" => Coalesce(F("raceid") * F("points"),
# Sum(…)))` groups the first and reads it whole in the second. It is also how a transform that
# arrives already BUILT is matched: a `"born__@year"` argument inside `Concat`/`Lower`/… is
# `EXTRACT(born)` by the time the projection list holds it, exactly the node a grouped
# `values("born__@year")` holds. A fingerprint, never `==`: on `F` and condition nodes `==` BUILDS a
# predicate (#541). Both sides are read against the same model, so an `F` operand `String` has the
# same path-or-literal reading in each. `nothing` for anything else — aggregates, windows,
# subqueries, handles it cannot describe — and such a node is simply not matched (over-refusal, never
# a wrong accept): a covered node therefore reads exactly the columns of the grouped one.
function _mixed_node_signature(x, depth::Int = 0)
  depth > 32 && return nothing
  _is_aggregate_call(x) && return nothing   # a grouped projection never holds one
  x isa AbstractString && return (:path, String(x))
  x isa JoinedReference && return (:joined_ref, x.alias, x.path)
  x isa CTEReference && return (:cte_ref, x.name, x.path)
  x isa SQLTypeText && return (:value, repr(x.field))
  x isa SQLTypeField && return _mixed_node_signature(x.field, depth + 1)
  x isa Union{Number,Symbol,Nothing,Missing} && return (:literal, repr(x))
  if x isa AbstractVector
    parts = Any[_mixed_node_signature(v, depth + 1) for v in x]
    return any(isnothing, parts) ? nothing : (:list, parts...)
  end
  if x isa FObject
    col = _mixed_node_signature(x.column, depth + 1)
    col === nothing && return nothing
    kws = Any[]
    for k in sort!(collect(keys(x.kwargs)))
      s = _mixed_node_signature(x.kwargs[k], depth + 1)
      s === nothing && return nothing
      push!(kws, (k, s))
    end
    return (:fn, x.function_name, col, kws...)
  end
  if x isa FExpression
    parts = Any[_mixed_node_signature(x.field_name, depth + 1), _mixed_node_signature(x.operand, depth + 1)]
    any(isnothing, parts) && return nothing
    return (:f, x.operation === nothing ? "" : x.operation, parts...)
  end
  if x isa OperObject
    parts = Any[_mixed_node_signature(x.column, depth + 1), _mixed_node_signature(x.values, depth + 1)]
    any(isnothing, parts) && return nothing
    return (:op, x.operator, parts...)
  end
  if x isa Union{QObject,QorObject}
    inner = _mixed_node_signature(x isa QObject ? x.filters : x.or, depth + 1)
    return inner === nothing ? nothing : (x isa QObject ? :q : :qor, inner)
  end
  return nothing
end

# One column a mixed term reads outside its aggregate calls:
#   - `base`: what grouping it would group — a path with any `__@` transform peeled, or a CTE /
#     joined-copy handle, peeled the same way. Rule 1 RENDERS it, so it must never carry a transform.
#   - `base_key` / `key`: the path keys of the base and of the transform (`nothing` without one).
#   - `spelled`: what the user wrote, as Julia source — the message's fix lines paste it back.
function _mixed_leaf(path::AbstractString)
  base = String(first(split(path, "__@")))
  (base = base, base_key = base, spelled = repr(String(path)),
   key = occursin("__@", path) ? _mixed_path_key(path) : nothing)
end
function _mixed_leaf(ref::JoinedReference)
  base = String(first(split(ref.path, "__@")))
  (base = JoinedReference(ref.alias, base, false), base_key = _joined_path_key(ref.alias, base),
   spelled = string("Joined(\"", ref.alias, "\", \"", ref.path, "\")"),
   key = occursin("__@", ref.path) ? _joined_path_key(ref.alias, ref.path) : nothing)
end
# A CTE handle cannot carry `__@` here: `_cte_join_path` refuses it in the projection's own render.
_mixed_leaf(ref::CTEReference) =
  (base = ref, base_key = _cte_path_key(ref.name, ref.path),
   spelled = string("CTE(\"", ref.name, "\", \"", ref.path, "\")"), key = nothing)

# A leaf is grouped when (1) its base column is — then any expression over it has one value per
# group — or (2) the transform it applies is itself a grouped projection. Rule 1 compares path keys
# first and falls back to the rendered text, which covers grouping reached through `order_by` or a
# #789 window term.
function _mixed_leaf_grouped(leaf, grouped_keys::Set{String}, grouped_text::Set{String},
                             instruct::SQLInstruction)::Bool
  leaf.key !== nothing && leaf.key in grouped_keys && return true
  leaf.base_key in grouped_keys && return true
  return string(_get_filter_query(leaf.base, instruct)) in grouped_text
end

# Call `f(clause, leaf)` for each column `node` reads OUTSIDE an aggregate call. The arms mirror how
# each node RENDERS, because the question is which text ends up bare in the statement:
#   - a `String` is a path wherever a function or `F` argument holds one; a `String` in a keyword slot
#     is not (a `When`'s `then`/`else` binds it as a value), so only `SQLType` kwargs are entered;
#   - an `F` operand `String` is a path only by the renderer's own test (`_set_update_query_operand`);
#   - a condition's column naming a projection ALIAS (#722) is not a column — that projection is
#     grouped, aggregated, a window, or checked on its own turn;
#   - a window's OVER terms are entered only when they hold an aggregate — a plain PARTITION BY/ORDER BY
#     term is grouped by #789 — but its argument and `default` always are (#809);
#   - `OuterRef` is constant per inner row (#194 owns the outer side), a subquery aggregates in its
#     own statement, and `Value`/literals read no column.
# `clause` names where the leaf sits, for the message. `covered(node)` answers whether a function or `F` node
# is itself a grouped projection (see `_mixed_node_signature`); nothing inside it is then visited.
# Depth cap as in `_contains_agg`.
function _each_bare_column(f::Function, node, instruc::SQLInstruction, clause::String, depth::Int = 0;
                           covered::Function = _ -> false)
  depth > 32 && return nothing
  walk(x, c = clause; cover = covered) = _each_bare_column(f, x, instruc, c, depth + 1; covered = cover)
  if node isa Union{AbstractString,CTEReference,JoinedReference}
    f(clause, _mixed_leaf(node))
  elseif node isa AbstractVector
    foreach(walk, node)
  elseif _is_aggregate_call(node)
    return nothing
  elseif node isa WindowFunction
    # An OVER term only when it holds an aggregate: a plain one is grouped by #789. Resolved, so an
    # aggregate reached through an alias (#722) counts.
    for term in node.over.partition_by
      _resolved_contains_agg(term, instruc) && walk(term, "PARTITION BY")
    end
    for term in node.over.order_by
      t = term isa SQLTypeOrder ? term.field : term
      _resolved_contains_agg(t, instruc) && walk(t, "ORDER BY")
    end
    # The argument always (#809): nothing groups a plain one — `LAG("Tb"."raceid")` beside a `SUM` reads
    # `raceid` once per group exactly as `raceid + SUM(…)` does. `Rank()` and its kin carry none.
    node.column !== nothing && walk(node.column, "argument")
    for (k, v) in node.kwargs   # `Lag`/`Lead`'s `default`, which renders beside the argument
      v isa SQLType && walk(v, k == "default" ? "default" : "argument")
    end
  elseif node isa FObject
    covered(node) && return nothing
    walk(node.column)
    for v in values(node.kwargs)
      v isa SQLType && walk(v)
    end
  elseif node isa FExpression
    covered(node) && return nothing
    node.field_name isa Integer || walk(node.field_name)
    op = node.operand
    if op isa AbstractString
      (occursin("__", op) || op in instruc.object.model.field_names) && f(clause, _mixed_leaf(op))
    elseif op isa Union{FExpression,SQLTypeFunction,CTEReference,JoinedReference}
      walk(op)
    end
  elseif node isa SQLTypeField
    walk(node.field)
  elseif node isa SQLTypeOrder
    walk(node.field)
  elseif node isa OperObject
    # A condition's column is never matched structurally: a transformed one
    # (`When("born__@year__@gt" => …)`) arrives as `SQLField(EXTRACT(born), …)`, but the #352 sargable
    # rewrite renders it as `"Tb"."born" >= ?`, so a grouped `born__@year` does not cover it. Its base
    # column is yielded with no path key, and only a grouped `born` does.
    _alias_filter_key(node.column, instruc) === nothing && walk(node.column; cover = _ -> false)
    node.values isa Union{FExpression,SQLTypeFunction,CTEReference,JoinedReference} && walk(node.values)
  elseif node isa QObject
    walk(node.filters)
  elseif node isa QorObject
    walk(node.or)
  end
  return nothing
end

# Same shape and rules as `_ungrouped_correlation_error_msg`: the fix lines name what the user
# wrote (`leaf.spelled`), never rendered SQL; the `Grouped by:` line is diagnosis and may carry it.
function _ungrouped_mixed_error_msg(label, clause::String, leaf, grouped::Vector{String})
  where_ = clause == "" ? "in its expression" :
           clause == "argument" ? "in its window function's argument" :
           clause == "default" ? "in its window function's default" :
           string("in its window's ", clause, " term")
  groups = isempty(grouped) ?
    "(none — this query aggregates the whole table into a single row)" :
    join(grouped, ", ")
  string(
    "PormG mixed-grouping guard (#798): the projection \e[4m\e[31m", label, "\e[0m reads the column ",
    "\e[4m\e[31m", leaf.spelled, "\e[0m outside an aggregate (", where_, "), and this query does not ",
    "GROUP BY it.\n",
    "  This query aggregates, so the projection is computed once per group — beside an aggregate, ",
    "or over one inside a window — and ", leaf.spelled, " has no single value in a group. ",
    "PostgreSQL refuses this (\"must appear in the ",
    "GROUP BY clause or be used in an aggregate function\"); SQLite answers with an ARBITRARY row's ",
    "value, so PormG refuses it on both backends rather than group a column you did not ask to group.\n",
    "  Grouped by: \e[33m", groups, "\e[0m.\n",
    "  Fix one of:\n",
    "    \e[32m1.\e[0m Project the column so it joins the group set — add \e[32m", leaf.spelled,
    "\e[0m to \e[32mvalues(...)\e[0m. PormG does not infer functional dependency on a grouped ",
    "primary key, so this is needed even then.\n",
    "    \e[32m2.\e[0m Aggregate it inside the expression — e.g. \e[32mMax(", leaf.spelled,
    ")\e[0m where the column stands, if one value per group is what you mean.\n")
end
