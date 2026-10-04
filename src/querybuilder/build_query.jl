# #441: the name a projection is RENDERED under. `custom_as` holds it for an aliased field path
# (`"s" => "parent__sku"`); `_as` holds it for everything else. Same expression `_query_select` and
# `get_order_query` use to decide a slot's alias, so the three agree by construction.
_projection_output_name(v::SQLTypeField) = v.custom_as !== nothing ? v.custom_as : v._as
_projection_output_name(v::SQLTypeText) = v.custom_as !== nothing ? v.custom_as : v._as

# #564 — the SELECT-`*` half of the projection-kind map.
#
# `get_select_query` records a kind per PROJECTION, so a query whose result carries columns it never
# projected — `SELECT "Tb".*` — records none for them, and the read path would stop coercing columns
# it coerced before. This fills that case from the model.
#
# A static scan from the model is sound here because a star emits the PRIMARY MODEL's own columns and
# nothing else: `query()` refuses an un-projected joined query outright ("Joined queries must
# explicitly select fields using .values(...)"), and the explicit `values("*", "joined__field")`
# spelling still expands the star over the base table alone, with the joined column arriving as its
# own projection (which `get_select_query` has already typed).
#
# Keyed under BOTH the field name and its `db_column`, because `SELECT "Tb".*` returns PHYSICAL
# column names: the predecessor of this code keyed only on the field name, so a
# `DateTimeField(db_column = "created")` was silently never coerced. A key the row does not carry
# costs nothing — the read loop only visits keys the row has.
function _record_wildcard_projection_kinds!(instruc::SQLInstruction)
  # An EXPLICIT `"*"` counts too, not only an empty projection list. `values("*")` and
  # `values("*", "team__founded")` both put every model column in the result under its own name, and
  # the second spelling is the one PormG's own error message recommends for a joined query ("Tip: Use
  # .values(\"*\", \"joined_model__field_name\")"). Recording only the empty case left that spelling
  # returning a MIX — the joined alias typed, the wildcard columns raw — in one row.
  isempty(instruc.object.values) || any(_is_wildcard_projection, instruc.object.values) || return nothing
  # Every output name an EXPLICIT projection already owns — whether or not it recorded a kind. This
  # runs AFTER `get_select_query`, and this loop claims both a field's name and its `db_column` while
  # the duplicate-name guard only reserves the star's PHYSICAL columns, so an alias equal to a renamed
  # field's NAME is legal: `values("*", "moved" => "d")`. The explicit projection is the more specific
  # answer and wins; the model-derived kinds are only the fallback for names nothing else claimed.
  #
  # Kinded or not (#648). Guarding only against CLOBBERING a recorded kind (a `get!`) left an
  # untyped alias exposed: `values("*", "price" => Count("id"))`, with `price` a
  # `DecimalField(db_column = "price_eur")`, recorded nothing for `:price`, so the star claimed it as
  # `CDecimal` and SQLite turned the count into a `Decimal`. The temporal parsers never showed this —
  # they hand a number straight back — but the decimal parser converts one.
  claimed = Set{Symbol}()
  for i in eachindex(instruc.select)
    isassigned(instruc.select, i) || continue   # a preallocated `undef` buffer, not a list
    v = instruc.select[i]
    _is_wildcard_projection(v) && continue
    name = _projection_output_name(v)
    name === nothing || push!(claimed, Symbol(name))
  end
  for (fname, fmeta) in instruc.object.model.fields
    kind = field_canonical_kind(fmeta)
    kind === nothing && continue
    for key in unique((Symbol(fname), Symbol(Models.field_db_column(fmeta, fname))))
      key in claimed || get!(instruc.projection_kinds, key, kind)
    end
  end
  return nothing
end

"""
  get_select_query(values::Vector{Union{SQLTypeText,SQLTypeField}}, instruc::SQLInstruction)

  Iterates over the values of the object and generates the SELECT query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the values to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the SELECT query will be added.
"""
function get_select_query(values::Vector{Union{SQLTypeText,SQLTypeField}}, instruc::SQLInstruction)
  _guard_select_condition_collision(values, instruc)   # #706
  for i in eachindex(values) # linear indexing
    v_copy = deepcopy(values[i])

    # SQLText (from Value(x)) is a literal value, not a column reference.
    # Handle it separately: parameterize via _get_select_query(::SQLText) 
    # and use custom_as as the alias.
    if isa(v_copy, SQLTypeText)
      resolved = _get_select_query(v_copy, instruc)
      # Wrap into an SQLField for consistent SELECT rendering
      alias = v_copy.custom_as !== nothing ? v_copy.custom_as : v_copy._as
      instruc.select[i] = SQLField(resolved, alias)
      if alias !== nothing
        # #474: a `Value(x)` literal is never CTE-rooted — `Value(CTE(...))` is refused (#444).
        memo_projection!(instruc, memo_key(:base, alias), instruc.select[i])
        # #721: SQLite binds a date or time literal as its stored text, so it comes back as text;
        # record the literal's kind and the #564 read path parses it back into a typed value. That
        # is the type that went in for `Date`/`Time`; a naive `DateTime` comes back as a UTC
        # `ZonedDateTime`, exactly as a SQLite `DateTimeField` column reads (the canonical text
        # carries `+00:00`) — the column's behavior, not a new one. `nothing` for every non-temporal
        # literal. On PostgreSQL the kind is inert: every `value_parser` there is `nothing`.
        kind = literal_canonical_kind(v_copy.field)
        kind === nothing || (instruc.projection_kinds[Symbol(alias)] = kind)
      end
      continue
    end

    if isa(v_copy.field, Union{SQLTypeFunction, SQLTypeF})
      # #722: resolved, not read off the node — a condition that names an aggregate (or window)
      # alias makes the projection one too, and its own flag cannot see that. See `_reads_alias`.
      #
      # #756 review: the two questions are independent. A projection can be BOTH — `Rank(…) +
      # Sum(…)`, or a `Case` with an aggregate in one branch and a window in another — and it is
      # still an aggregate, so the statement needs GROUP BY for its plain columns. Answering "window"
      # first used to skip the flag and drop the GROUP BY altogether.
      #
      # #776: and "is an aggregate" is not the question the STATEMENT asks. A window over one —
      # `Lag(Sum(…))`, `PARTITION BY Sum(…)` — is a window, so it stays out of GROUP BY, yet it makes
      # the statement aggregate. Keyed on `_is_agg` alone the flag stayed unset, the plain columns
      # beside it were never grouped, and SQLite returned one arbitrary row. See `_contains_agg`.
      # Unlike the two questions around it, this one needs no `_reads_alias`: it is asked of the
      # STATEMENT, and an alias a condition reads is itself a projection in this same loop, which
      # sets the flag on its own turn.
      is_agg = _resolved_agg(v_copy.field, instruc)
      (is_agg || _contains_agg(v_copy.field)) && (instruc.aggregate = true)
      (is_agg || _resolved_window(v_copy.field, instruc)) || push!(instruc.group, i |> string)
    elseif isa(v_copy.field, Union{SubqueryObject, ExistsObject})
      # #92: a projected scalar subquery / EXISTS is a per-row expression — neither a groupable
      # column nor an outer aggregate. It must NOT be pushed into GROUP BY (in a mixed projection
      # with a real aggregate, that would otherwise emit the subquery's positional index into GROUP BY).
      nothing
    else
      push!(instruc.group, i |> string)
    end

    # #441: the memo is keyed on `_as`, which for a field-path projection is the PATH, not the name
    # the column is rendered under (that lives in `custom_as`). So a bare `haskey` hit collapsed
    # projections that share an expression but declare DIFFERENT names — `values("gg" => "note",
    # "hh" => "note")` rendered `as "gg"` twice and dropped `hh` entirely, silently. `_cache_join`
    # (`build_joins.jl`) writes into this same dict keyed by join path, so a projection can also hit
    # an entry that was never a projection at all.
    #
    # Reuse is only correct when the cached entry renders under the SAME output name. Otherwise
    # resolve independently, and leave the memo to whichever entry claimed the key first — the point
    # of the memo is to avoid re-resolving one expression, not to make two projections one.
    # #474: the memo key, not the output name — see `memo_key`. The output-name equality test below
    # is unchanged and still decides REUSE; this only decides which entry is consulted.
    #
    # #706: and only a node the memo can STAND FOR may reuse it — a path, a CTE or joined-copy
    # handle, an outer reference: the gate `_get_filter_query(::SQLTypeField)` applies (#586). A
    # function or `F` projection is keyed by its own alias, so an entry already under that key was
    # written by something else — a `When("points" => …)` condition that rendered the COLUMN — and
    # reusing it replaced `"points" => Sum("points")` with that column, silently. Such a projection
    # always renders its own expression, and then takes that entry over (below): the alias names
    # it, so every later reader — ORDER BY, an alias filter — must find it, not the stray column.
    # `_guard_select_condition_collision` refuses the shape that reached this; the gate is what
    # keeps a projection its own even if a future path writes first.
    cache_key = memo_key(v_copy)
    cached = memo_projection(instruc, cache_key)
    same_name = cached !== nothing &&
                _projection_output_name(cached) == _projection_output_name(v_copy)
    memo_node = v_copy.field isa Union{String,SQLTypeCTE,SQLTypeJoined,OuterRefObject}
    if same_name && memo_node
      instruc.select[i] = cached
    else
      @pormg_debug false
      # #564 — RENDER, AND CARRY OUT WHAT THE RESULT IS.
      #
      # The read path needs the canonical kind of every projection, and the only place that can
      # answer is here: resolving a path is what populates the memos the kind lookup reads, and the
      # rendered form is a bare `String` with nothing left to ask. So the kind is taken from the
      # SAME call that renders, never from a second walk over the node — a second walk is precisely
      # the duplication #564 exists to remove, and it would be free to drift.
      #
      # `FExpression` concretely, not the abstract `SQLTypeF`: `OuterRefObject` is also `<: SQLTypeF`
      # (#533) and has no typed renderer. A function is typed only when it returns its operand's own
      # value (`_function_projection_kind`, #800). Everything else — other functions, an `Exists` —
      # answers `nothing`, which means "no representation this table owns", and the read path then
      # leaves the column exactly as the driver delivered it.
      original = v_copy.field
      kind = nothing
      if original isa FExpression
        # #881: one of the renderer's two doors out — an interval it held in milliseconds on SQLite
        # arrives here as the stored text, typed `CInterval`.
        v_copy.field, kind = _set_update_query_typed(original, instruc)
        # #824: a bare `F("ts__@date")` is the transform's result, which the column lookup cannot
        # name. Since #814 `_set_update_query_typed` names it too (`_side_kind`), because the same
        # call types the sides of date arithmetic, and a transformed side has to be typed there. This
        # fallback stays for whatever else `_operand_kind` resolves on a bare `F` and that does not.
        kind === nothing && original.operation === nothing && (kind = _operand_kind(original, instruc))
      else
        # #894: `Max`/`Min` over an interval are computed on SQLite milliseconds and leave as the
        # interval text — the second door #881 describes, and typed the way a difference is, on
        # both engines. `_operand_kind` cannot type `Max(F("start_at") - F("date"))` (arithmetic
        # answers `nothing`), so the kind is taken from the same call that renders, as above.
        interval = false
        if original isa FObject
          sql, interval_ms, interval = _render_function_typed(original, instruc; _as = v_copy._as)
          v_copy.field = interval_ms ? Dialect._sqlite_interval_text(sql) : sql
        else
          v_copy.field = _get_select_query(original, instruc, _as=v_copy._as)
        end
        # A plain path: render first (above), THEN type — the memo ordering `_render_left_typed`
        # documents. A dotted join key cannot be typed before it has been resolved.
        # `_projection_column_kind`, not the arithmetic-narrowed `_operand_column_kind`: a projected
        # `TimeField` or `DurationField` has a representation to undo even though neither can be the
        # left of date arithmetic.
        original isa String && (kind = _projection_column_kind(original, instruc))
        # #800: an extremum or a window value function has its operand's kind. Same order: render,
        # then type.
        original isa SQLTypeFunction &&
          (kind = interval ? CInterval() : _function_projection_kind(original, instruc))
        # #824: a `Joined(...)` / `CTE(...)` handle (and a `"cte__col"` path, retagged to one before
        # this loop) reads as `Max` over it does — one rule, `_operand_kind`. #888: so does a
        # `Subquery(...)`, as its one column — rendered above, which is what recorded its kind.
        original isa Union{JoinedReference,CTEReference,SubqueryObject} &&
          (kind = _operand_kind(original, instruc))
      end
      instruc.select[i] = v_copy
      if v_copy._as === nothing
        throw(QueryBuildError("Field requires an alias: \e[4m\e[31m$(v_copy.field)\e[0m must have a name using the format \e[4m\e[32m\"field_name\" => $(v_copy.field)\e[0m or use \e[4m\e[32mSQLField($(v_copy.field), \"alias_name\")\e[0m"))
      end
      # `cache_key` is non-`nothing` here: it is `nothing` exactly when `_as` is, which the throw
      # above has already ruled out. Otherwise the first entry stays (#441), with one exception:
      # an entry under this projection's own output name that it was refused (#706). Only that one
      # is taken over — an entry under another name may be `_cache_join`'s, which is not ours.
      (cached === nothing || same_name) && memo_projection!(instruc, cache_key, instruc.select[i])
      # #564: keyed by the RESULT-ROW name, which is what the driver hands back. The reuse branch
      # above needs no equivalent — it is taken only when the output name is EQUAL, so the entry it
      # would write is the one already written under that key.
      if kind !== nothing
        name = _projection_output_name(v_copy)
        name === nothing || (instruc.projection_kinds[Symbol(name)] = kind)
      end
    end
  end

  # #194: the coarse warn that used to sit here is gone — the precise guard is
  # `_check_grouped_correlation`, called at the END of build(). It cannot run here: `get_order_query`
  # still adds to `instruc.group` afterwards, so at this point the group set is incomplete and a
  # legitimate query would be refused. See the guard's own comment.
end

# NULLS FIRST/LAST syntax landed in SQLite 3.30.0; older builds need the portable
# `(expr IS NULL)` prefix instead (#75).
const SQLITE_NULLS_ORDER_MIN_VERSION = 3030000

# Resolve NULL placement for one ORDER BY term (#75). The canonical default matches PostgreSQL
# (NULL sorts as the largest value): ASC → :last, DESC → :first — so ordering a nullable column
# returns the same rows on both backends. An explicit SQLOrder(...; nulls=:first|:last) overrides it.
function _nulls_placement(orientation::AbstractString, nulls::Union{Symbol,Nothing})
  nulls === :first && return :first
  nulls === :last  && return :last
  nulls === nothing || throw(QueryBuildError("Invalid nulls placement $(repr(nulls)); use :first or :last"))
  return uppercase(strip(String(orientation))) == "DESC" ? :first : :last
end

_emulates_nulls_order(conn) =
  conn isa PormGSQLite && backend_sqlite_version(conn) < SQLITE_NULLS_ORDER_MIN_VERSION

# Render one ORDER BY term with explicit NULL placement, portable across backends (#75).
#
# #894: `null_flag`, when given, is a SEPARATE render of the same node as `expr`, for a SQLite interval
# ordered by its re-rendered milliseconds. It binds its own copy of the term's values, identical to
# `expr`'s and in the same order, so the two copies align whichever prints first — the duplication
# the guard below refuses is one text bound once. It is an explicit argument, never compared with
# `expr`: the two texts are equal, and Julia's `===` compares strings by content. Not the projection
# alias: inside an expression SQLite resolves a name to a FROM column first, so
# `values("lap" => F("best") * 2)` would flag the raw `lap` column.
function _order_term_sql(expr, orientation::AbstractString, placement::Symbol, conn;
                         null_flag::Union{Nothing,AbstractString} = nothing)
  if _emulates_nulls_order(conn)
    # SQLite < 3.30 has no NULLS syntax → emulate placement by sorting on the null-flag first.
    # NULLS FIRST means nulls (flag 1) come first → DESC on the flag; NULLS LAST → ASC on the flag.
    # This references `expr` twice. A resolved ORDER BY column/alias is a bare identifier, but a
    # function-valued order term could render a positional `?` placeholder; duplicating that would
    # bind the value once yet reference it twice → parameter misalignment. Guard against it: only
    # emulate when `expr` is placeholder-free. For the rare parameterized order term on this ancient
    # SQLite, emit the plain term (native NULL placement) — normalization is skipped, never corrupted.
    if null_flag === nothing && occursin('?', string(expr))
      return string(expr, " ", orientation)
    end
    flag_dir = placement === :first ? "DESC" : "ASC"
    return string("(", something(null_flag, expr), " IS NULL) ", flag_dir, ", ", expr, " ", orientation)
  end
  return string(expr, " ", orientation, " ", placement === :first ? "NULLS FIRST" : "NULLS LAST")
end

# #587: the output name under which the expression with memo key `key` is projected, or `nothing`.
# The scan is the one `get_order_query` runs for the same-name case, keyed on the full `memo_key`
# — namespace AND name, never the bare `_as` string: a `Joined("raceid", "year")` projection and a
# base-model `raceid__@year` term share the `_as` text `raceid__year` and differ only in the
# namespace half, which is the #474 distinction. For a field-path or transform projection the name
# half is the PATH (the chosen name lives in `custom_as`), so `values("q" => "date__@yyyy_q")`
# answers `"q"` for an `order_by("date__@yyyy_q")` term.
function _projected_output_name(instruc::SQLInstruction, key)::Union{Nothing,String}
  key === nothing && return nothing
  for i in eachindex(instruc.select)
    isassigned(instruc.select, i) || continue
    value = instruc.select[i]
    memo_key(value) == key || continue
    return value.custom_as !== nothing ? value.custom_as : value._as
  end
  return nothing
end

# #894 — an ORDER BY term that is a bare `DurationField` column path, on SQLite. Typed after the term
# has been rendered, so the memo the kind lookup reads is populated.
_orders_as_sqlite_interval(term::SQLField, instruc::SQLInstruction) =
  instruc.connection isa PormGSQLite && term.field isa String && _is_bare_column(term.field) &&
  _operand_kind(term.field, instruc) isa CInterval
_orders_as_sqlite_interval(::Any, ::SQLInstruction) = false

function get_order_query(object::SQLObject, instruc::SQLInstruction)
  for v in object.order
    found_in_select = false
    v_field_copy = deepcopy(v.field)

    # Check if the ORDER BY target matches a selected alias. Only those aliases can be
    # referenced directly in ORDER BY. Cached join paths created while resolving CTE join_field
    # entries must reuse their resolved SQL selector instead of quoting the raw lookup string.
    #
    # Scan `instruc.select` — the RENDERED projections — not `object.values`, the declared ones.
    #
    # #441 changed WHY this matters, and the old reason is worth recording as retired rather than
    # left standing. Before it, `get_select_query` collapsed a projection whose `_as` was already
    # cached onto the cached `SQLField` and discarded its `custom_as`, so a declared name could fail
    # to reach the SQL at all — `values("note", "gg" => "note")` rendered `as "note"` twice and `gg`
    # never appeared. Emitting `ORDER BY "gg"` from the declared list then named neither an output
    # nor an input column: PostgreSQL raises, while SQLite degrades the unresolvable identifier to
    # the literal 'gg' — a constant sort key — and returns the rows UNSORTED with no error.
    #
    # That collapse is gone: the memo is now reused only when the cached entry renders under the
    # SAME output name, so every declared name IS rendered and the two sets agree. Scanning
    # `instruc.select` is still the right choice — it is what the SQL will actually contain, which
    # is the thing `order_by` must resolve against — but it is no longer load-bearing against a
    # silent-wrong-answer bug. Do not "simplify" it back to `object.values` on that basis; the sets
    # agreeing is a property of `get_select_query`, not of this function.
    #
    # `instruc.select` is authoritative and fully populated here: `build` calls `get_select_query`
    # before `get_order_query`, and that is its only writer, assigning contiguously over
    # `eachindex(values)`. The vector is sized up front, so the trailing slots are `undef` — hence
    # the `isassigned` guard. It is the same discipline `_query_select` uses, not the same
    # behavior: that one `return`s at the first gap, this one `continue`s. Equivalent only because
    # assignment is contiguous; `continue` is the safer of the two if that ever stops being true.
    #
    # An ORDER BY term with NO alias cannot name a projection, and must not be compared as if it
    # could: `selected_alias == v_field_copy._as` would reduce to `nothing == nothing` and match
    # every unaliased select entry, which then reaches `quote_identifier(nothing, …)`. Reachable
    # through the fluent surface — a bare `Value("hi")` in `values()` projects with no alias, and
    # `SQLOrder(SQLField(f, nothing))` is accepted by `order_by` — hence the empty-tuple guard.
    #
    # That shape was already broken before #423, raising `MethodError: Cannot convert an object of
    # type Nothing` from the resolution branch — a raw MethodError outside the error taxonomy
    # (#231/#239). Skipping the scan keeps it on exactly that pre-existing path rather than
    # replacing one untyped failure with a different one. The leak is tracked separately.
    #
    # The message has moved twice and the leak has not. #474 made the target type a `MemoKey`; #481
    # widened its namespace half to a `Symbol`; and #478 put the write behind `memo_projection!`,
    # which is typed on `::MemoKey` and so has no method for `nothing` at all. It now reads
    # `MethodError: no method matching memo_projection!(::InstructionObject, ::Nothing, ::SQLField)`
    # — no longer a `convert` error, and raised one frame higher. Same site, same class, same
    # tracked leak; re-quoted so the text does not read as stale.
    #
    # #441 also retired the ambiguity THROW that used to sit inside this loop. It refused
    # `order_by("x")` when `values(...)` projected `x` twice over two different expressions;
    # `values()` now refuses that declaration, so the throw was unreachable and was deleted rather
    # than kept as dead code behind a comment describing an impossible situation. What survives is
    # the loop itself, which answers only "is this name projected at all?" — and since no name can
    # now be projected twice, it could `break` on the first hit; it does not, only because running
    # to completion costs nothing over a projection list.
    for i in (v_field_copy._as === nothing ? () : eachindex(instruc.select))
      isassigned(instruc.select, i) || continue
      value = instruc.select[i]

      selected_alias = value.custom_as !== nothing ? value.custom_as : value._as
      selected_alias == v_field_copy._as || continue

      found_in_select = true
    end

    # #423: the projection test comes FIRST. It used to be nested inside the `instruc.cache` hit
    # below, and the two disagree about where a projection's chosen name is stored:
    #
    #     values("s" => "parent__sku")  ->  _as = "parent__sku"   custom_as = "s"
    #     values("c" => Count("id"))    ->  _as = "c"             custom_as = nothing
    #
    # For a field-path projection the PATH becomes `_as` and the chosen name goes to `custom_as`;
    # for a function the chosen name becomes `_as` outright. `get_select_query` caches under `_as`,
    # so the cache has no "s" entry, the `haskey` missed, and control fell through to
    # `_get_select_query("s")` — which resolves "s" as a physical column of the base model. That is
    # an `UnknownFieldError` for a name like "s", and something worse for a name that happens to
    # match a real column: `values("note" => "qty"); order_by("note")` silently emitted
    # `ORDER BY "Tb"."note"`, sorting a DIFFERENT column than the one projected under that name.
    # Aggregate and window aliases escaped only because their chosen name IS `_as`, so the cache
    # key happened to match — which is exactly the asymmetry users reported.
    #
    # The branch inversion itself changes exactly one combination — found_in_select && cache-miss,
    # which used to fall through to `_get_select_query`. The other three are byte-identical, and
    # both the #76 DISTINCT guard and the `instruc.group` push below stay gated on
    # `!found_in_select`, so neither is reachable from the new branch.
    #
    # #423 also moved a second combination — found_in_select && cache-HIT — via an ambiguity guard
    # that used to sit in the loop above: `values("note", "note" => "qty")` rendered two output
    # columns named "note" over different expressions and previously emitted `ORDER BY "note"`,
    # which PostgreSQL rejected at execution. #441 retired that guard and moved the refusal to
    # `values()` itself, so this combination is now unreachable from here — the declaration throws
    # before `order_by` is ever consulted. Recorded because the branch inversion's "exactly one
    # combination" claim above was true only alongside it.
    # #474: the memo key for this term, resolved once. It is `_as` for everything except a CTE
    # handle, whose `_as` is deliberately spelled like a field path (#444) and must not share an
    # entry with one. Note the branch below still emits `_as` — that is the SELECT alias the
    # database sees, which is a different thing from the key this build memoizes under.
    order_cache_key = memo_key(v_field_copy)
    # #587: the values this term binds, read back after rendering so the GROUP BY copy below can
    # carry them too. Empty on the alias and memo branches, which bind nothing; empty on PostgreSQL
    # always (`parameter_mark` holds no bucket there).
    order_params = Any[]
    # #894: what ORDER BY prints when it is not `v_field_copy.field` — a SQLite interval's
    # milliseconds. Kept apart from the field on purpose: the field is what the memo write and the
    # #76 DISTINCT guard below read, and neither may see an ordering-only rewrite.
    order_expr = nothing
    interval_name = nothing   # the alias `order_expr` re-renders, for the old-SQLite NULL flag
    if found_in_select
      # Use the alias name instead of the expression to avoid double parameterization.
      # Most databases (PG, SQLite, MySQL) support aliases in ORDER BY.
      #
      # #894: except an interval on SQLite, whose alias is its `HH:MM:SS` text — `"100:00:00"`
      # sorts before `"99:00:00"`. It orders by its milliseconds instead, rendered again here (and
      # bound again, under `:order`). Not `_sqlite_interval_ms` over the alias name: inside an ORDER
      # BY expression SQLite resolves a name to a FROM column BEFORE a result alias, so
      # `values("time" => Max("time")); order_by("time")` would sort by the raw column.
      interval = _render_projected_interval_ms(v_field_copy._as, instruc)
      interval === nothing || (order_expr = first(interval); interval_name = v_field_copy._as)
      v_field_copy.field = quote_identifier(v_field_copy._as, instruc.connection)
    # #478: bound INSIDE the condition, so the hit cannot outlive the branch that consumes it. The
    # `else` arm below resolves through `_get_select_query`, which reaches
    # `_get_filter_query(::SQLTypeField)` and can write this very key — so a read hoisted above the
    # branch would be stale by the time the write guard further down consults it. Keeping the
    # binding scoped is what makes that mistake unavailable rather than merely commented against.
    #
    # #587: the memo is reused ONLY for a node kind that never binds a parameter — a String path
    # (which must keep it: `_cache_join` files the resolved selectors of CTE `join_field` paths
    # under these keys), a CTE or joined-copy handle, an outer reference. A memoized expression that
    # DID bind (`values("q" => "ts__@yyyy_q"); order_by("ts__@yyyy_q")`) carries `?`s whose values
    # sit in `:select`; reusing its text here printed nine markers into ORDER BY with nothing bound
    # for them — SQLite refused the statement. Gated negatively so a future node type that binds
    # lands on the safe path by default.
    elseif v_field_copy.field isa Union{String,SQLTypeCTE,SQLTypeJoined,OuterRefObject} &&
           (order_cached = memo_projection(instruc, order_cache_key)) !== nothing
      v_field_copy.field = order_cached.field
    # #587: a binding expression that IS projected, under another output name, orders by that
    # name — the same thing the `found_in_select` branch does when the names agree. Rendering it
    # afresh would bind its operands a second time; on PostgreSQL that also renumbers the `$N`s,
    # so the ORDER BY term stops being byte-identical to the projection and a DISTINCT query the
    # #76 guard (and PostgreSQL itself) used to accept is refused. The alias binds nothing on either
    # engine and is legal under DISTINCT by construction. Only a binding node takes this branch:
    # a String path or a handle keeps its memoized selector above, so their SQL is unchanged.
    elseif (projected_as = _projected_output_name(instruc, order_cache_key)) !== nothing
      interval = _render_projected_interval_ms(projected_as, instruc)   # #894, as above
      interval === nothing || (order_expr = first(interval); interval_name = projected_as)
      v_field_copy.field = quote_identifier(projected_as, instruc.connection)
      found_in_select = true
    else
      # `_get_select_query(::SQLTypeFunction)` also records an `agg_sources` entry per render, so
      # a re-rendered aggregate term appears there twice — harmless to `_check_aggregate_fanout`,
      # which reasons per entry and reaches the same verdict for a duplicate.
      mark = parameter_mark(instruc)
      v_field_copy.field = _get_select_query(v_field_copy.field, instruc)
      order_params = bound_since(mark)
    end
    # #540: no render-time re-validation. `SQLOrder` is an immutable struct whose inner constructor
    # runs the #77 whitelist, so `v.orientation` is ASC or DESC by construction and nothing can have
    # rewritten it since — the constructor is the only writer.
    # #894: a `DurationField` column that is not projected orders by its stored text's milliseconds
    # on SQLite. The column reference binds nothing, so repeating it costs no parameter.
    if order_expr === nothing && !found_in_select && _orders_as_sqlite_interval(v.field, instruc)
      order_expr = Dialect._sqlite_interval_ms(v_field_copy.field)
    end
    orientation = v.orientation
    placement = _nulls_placement(orientation, v.nulls)
    # #894: before SQLite 3.30 the NULL placement is emulated with a flag. A re-rendered interval that
    # binds gets a second render of the same projection as that flag (see `_order_term_sql`); one that
    # binds nothing, and a bare column's millisecond parse, are their own flag.
    null_flag = nothing
    if interval_name !== nothing && occursin('?', order_expr) && _emulates_nulls_order(instruc.connection)
      null_flag = first(_render_projected_interval_ms(interval_name, instruc))
    end
    push!(instruc.order, order_expr === nothing ?
      _order_term_sql(v_field_copy.field, orientation, placement, instruc.connection) :
      _order_term_sql(order_expr, orientation, placement, instruc.connection; null_flag = null_flag))
    # Cache the resolved selector, but NEVER overwrite one that is already there (#404). The
    # `found_in_select` branch above deliberately degrades `field` to the bare SELECT alias — legal
    # in ORDER BY, invalid anywhere else — and since #404 moved this call ahead of
    # `build_row_join_sql_text`, that render reads this cache: Phase 1 resolves cjoin ON conditions
    # through `_get_filter_query(::SQLTypeField)`, which returns the memoized projection's `.field`
    # verbatim. Clobbering here put `"parent__sku"` (a projection alias) into an ON clause, which
    # both backends reject. The existing entry is the fully-qualified selector and is strictly
    # better for every reader; only a freshly resolved path has nothing to preserve.
    #
    # #423 adds the second half of the same rule. Inverting the branches above made
    # `found_in_select` reachable on a cache MISS, so this would newly write the degraded alias
    # under the caller's chosen name — the poisoned form the #404 clause above exists to keep out
    # of the join render, arriving by a new route. DEFENSIVE, not demonstrated: no query shape is
    # known that reads `instruc.cache` under a `custom_as` alias, so removing this would probably
    # not turn the suite red. It costs one boolean, and a bare alias is legal in ORDER BY and
    # nowhere else, so it is never worth caching under any circumstances.
    #
    # #478: this reads the memo HERE rather than reusing the branch's hit. The `else` arm above
    # resolves through `_get_select_query`, which reaches `_get_filter_query(::SQLTypeField)`
    # (`build_helpers.jl`) and can write this very key as it goes — so any read taken before the
    # branch is stale by now, and reusing one would clobber a fresh entry with the possibly-degraded
    # `v_field_copy`. That is exactly the poisoned-entry class the #404 and #423 clauses above exist
    # to prevent. One extra lookup on a path already doing several.
    # A `nothing` key reaching the write is a MethodError, deliberately: see the writer note in
    # `memos.jl`.
    (found_in_select || memo_projection(instruc, order_cache_key) !== nothing) ||
      memo_projection!(instruc, order_cache_key, v_field_copy)

    if !found_in_select
      # #76: Under DISTINCT, an ORDER BY term that is not part of the projection is rejected by
      # PostgreSQL and the SQL standard (SQL Server / Oracle / DB2 / default-mode MySQL all reject
      # it), while SQLite silently runs it with a nondeterministic DISTINCT/order interaction. Refuse
      # it on both backends so the two stay aligned. Match on the resolved SQL *expression*
      # (v_field_copy.field was resolved just above), not the base column: PG rejects `ORDER BY
      # DATE(x)` even when `x` is projected, yet accepts an aliased column (`SELECT x AS y ... ORDER
      # BY x`) — expression membership captures both. Skip when there is no explicit projection
      # (`SELECT DISTINCT *`) or the projection carries a `*` wildcard that already covers the column.
      if object.distinct && !isempty(object.values) && !any(_is_wildcard_projection, object.values)
        distinct_expr = string(v_field_copy.field)
        in_projection = false
        for i in eachindex(instruc.select)
          isassigned(instruc.select, i) || continue
          if string(instruc.select[i].field) == distinct_expr
            in_projection = true
            break
          end
        end
        if !in_projection
          # Keep the suggestion generic (`.values(...)`) rather than echoing v_field_copy._as: for a
          # transform order term the alias is the internal name (e.g. "created_at__date"), which is NOT
          # valid input syntax to paste back (the user wrote "created_at__@date"), so a specific token
          # would mislead. The offending term is still named in the diagnosis.
          throw(QueryBuildError(
            "DISTINCT query cannot ORDER BY \e[4m\e[31m$(v_field_copy._as)\e[0m: it is not in the " *
            "SELECT DISTINCT projection. PostgreSQL (and the SQL standard) rejects this; SQLite " *
            "would return rows in a nondeterministic order. Add the ordering column or expression " *
            "to \e[4m\e[32m.values(...)\e[0m so it is projected, or drop " *
            "\e[4m\e[32m.distinct()\e[0m and order by an aggregate if you meant one row per key."))
        end
      end
      push!(instruc.group, v_field_copy.field)
      # #587: GROUP BY prints this same string — `?`s included — BEFORE HAVING and ORDER BY, so on a
      # positional backend the values the term bound are needed a second time, under `:group`.
      # Gated on `instruc.aggregate`, which is final here (its only writer is `get_select_query`,
      # which ran first) and is the exact condition under which `query` prints a GROUP BY clause:
      # copying for a non-aggregate query would bind values no marker consumes — the mirror image
      # of the defect. No-op on PostgreSQL, which prints the same `$N` twice and binds it once.
      instruc.aggregate && copy_parameters_to!(instruc, :group, order_params)
    end

  end
  return nothing
end

# #789 — the columns a window READS join GROUP BY. Django's `Window.get_group_by_cols`.
#
# An aggregating statement must group every column it reads outside an aggregate, and a window's
# `PARTITION BY` / `ORDER BY` reads columns without projecting them. #776 made `Lag(Sum(…))` set the
# aggregate flag, so its projected neighbours were grouped, but a column named only inside `OVER (…)`
# was not: PostgreSQL raised `GroupingError`, and SQLite collapsed the statement onto one arbitrary
# row per group, silently. The same held for a plain `Rank()` beside a `Sum(…)`. This is the implicit
# grouping `get_order_query` already applies to a query-level ORDER BY term outside the projection
# (the `push!(instruc.group, …)` above), extended to the window's own ORDER BY and PARTITION BY.
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

# SQLite keeps a number compared with a NUMBER-typed alias native: an aggregate or arithmetic result
# has no column affinity there, and neither has a bound parameter, so `SUM(x) = '1.5'` — what
# `format_number_sql(1.5)` returns — is false. The same reasoning reverses for a TEXT alias (#851):
# `LOWER(…)`, `a || b`, `COALESCE(<text>, …)` have no affinity either, so a native `7` against
# `'7'` is false and the filter matched nothing where PostgreSQL bound `"7"` and matched. The value
# therefore stays native only for the formatters whose SQL type is a number or a boolean — a
# whitelist, because a node may carry its own formatter (`ToChar(…; formatter = …)`), and anything
# but a number must bind as its formatter wrote it, exactly as the WHERE path does for a column.
function _sqlite_preserve_native_parameter(raw_value, formatted_value, formatter, instruc::SQLInstruction)
  if instruc.connection isa PormGSQLite && raw_value isa Union{Number,Bool} &&
     (formatter === Models.format_number_sql || formatter === Models.format_bool_sql)
    return raw_value
  end
  return formatted_value
end

# `operator` (#411): this function has the SAME inverted formatter contract the three filter call
# sites in `build_helpers.jl` had — it handed `raw_value` straight to a formatter, so a
# membership list reached one whole. `filter("mx__@in" => [Date(...)])` on a `Max("happened")`
# alias therefore died with `InvalidValueError` exactly as the plain-field path did. The operator
# is what licenses mapping, for the same reason as there: a `Vector{UInt8}` is ONE binary value,
# so the value's type cannot decide it.
# #474: `alias` is a `MemoKey`. Its second half is the output name the fallback loop below compares
# against `custom_as`/`_as`; the first half selects the namespace for the `tab_field_cache` hit.
function _resolve_having_filter_value(alias::MemoKey, raw_value, instruc::SQLInstruction,
                                      operator::AbstractString)
  # #576: the formatter choice and the format CALL were one expression repeated seven times, and
  # not one of the seven was guarded — so every documented HAVING spelling reported a wrong-typed
  # value as the write path's `InvalidValueError`. Splitting the choice out leaves exactly one
  # format call to guard, and `_guarded_format` guards it.
  #
  # The message is alias-shaped on purpose. `_rethrow_as_filter_error`'s default wording names a
  # *field*, and there is no field here: `alias[2]` is an output name the user invented in
  # `values(...)`, and the type is whatever formatter the ladder below resolved for it.
  # #654: `@isnull`'s value is the predicate's polarity, not a value of the alias's type, so it is
  # not formatted — `format_number_sql(true)` would be a category error, not a check.
  operator == "ISNULL" && return raw_value
  # #903: a pattern lookup on an alias over an `inet`/`cidr` column takes a fragment, as on the column.
  formatter = _lookup_formatter(_having_alias_formatter(alias, instruc), operator)
  # #707: a type the ladder cannot name is not checked — the value binds as given, as it does on
  # the WHERE path for any column-less expression.
  formatter === nothing && return raw_value
  formatted_value = _guarded_format(formatter, raw_value, operator, alias[2],
                                    _formatter_type_label(formatter);
                                    subject = "projection alias")
  # #654: a range is two scalars formatted as one iterable lookup, so the SQLite native-value rule
  # applies per operand — exactly what each would get as the right-hand side of a `@gte`/`@lte`.
  # #851: so is a membership list. `@in`/`@nin` reached the scalar call below with a `Vector`, which
  # is never a `Number`, so `Sum("points")` filtered `@in => [25.5, 1.5]` bound `["25.5", "1.5"]` and
  # matched nothing on SQLite where `=` matched. Same condition as `_format_filter_value`'s
  # element-wise arm, so an element is kept native exactly when it was formatted on its own.
  operator in _ITERABLE_LOOKUP_OPERATORS && raw_value isa AbstractArray &&
    return [_sqlite_preserve_native_parameter(r, f, formatter, instruc) for (r, f) in zip(raw_value, formatted_value)]
  return _sqlite_preserve_native_parameter(raw_value, formatted_value, formatter, instruc)
end

# The formatter a HAVING/alias filter value must satisfy, resolved from whatever the alias projects.
#
# #576: the final `IntegerField().formatter` is a FALLBACK, and before this it was also the arm that
# caught every non-aggregate projection — the loop only ever inspected `SQLTypeFunction`, and
# `F("happened")` is an `FExpression`. So `values("id", "d2" => F("happened")).filter("d2" => ...)`
# forced `format_number_sql` onto a date, and did so for WELL-TYPED values too: a real `Date` raised
# "not a valid number". That half is not an error-type problem and no handler could have papered
# over it — it is simply wrong, which is why the bare-reference arm below exists.
#
# #707 retired the fallback itself: a type the ladder cannot name now means no check, not a number
# (see `_having_alias_formatter`). `F("a") + Day(1)` still gets no guess — its result type is not
# the column's.
# The projection an alias names, as the USER wrote it — the unrendered node.
#
# Three places hold a projection and only this one is the source: `instruc.select` holds rendered
# copies, `instruc.cache` (the memo) holds only their SQL TEXT, and `instruc.object.values` holds the
# originals. #595 needs the original, because reusing the text is exactly the defect there.
#
# #474: `alias` is a MemoKey; this matches on the OUTPUT name, which is its second half. Comparing
# the whole key would never match — the review flagged the String-vs-key mismatch as latent, and
# typing the key is what turns it into a compile-visible one.
#
# #707: a `Value(...)` projection (`SQLTypeText`) is a source too. Returning only `SQLField`
# projections left a literal alias sourceless, so `values("v" => Value(5)); filter("v" => 5)` kept the
# HAVING route and reprinted the SELECT's memoized `?` with no value behind it: `HAVING ? = ?`, three
# markers for two values on SQLite. Every caller reads `.field` through `_is_agg`/`_is_window_expr`/
# an `isa`, all of which answer the literal inside a `Value` correctly: not an aggregate, not a window.
function _projected_source(alias::MemoKey, instruc::SQLInstruction)
  for selected_value in instruc.object.values
    selected_alias = selected_value.custom_as !== nothing ? selected_value.custom_as : selected_value._as
    selected_alias == alias[2] || continue
    isa(selected_value, Union{SQLTypeField,SQLTypeText}) || continue
    return selected_value
  end
  return nothing
end

# #722 — is a projection an aggregate, or a window, once the aliases it reads are resolved?
#
# `aggregate` is set when a node is CONSTRUCTED (`_any_agg`, #702), and a condition that names an
# alias holds only the name: `Case([When("total__@gte" => 100, then = 1)])` over
# `"total" => Sum("points")` carries the string `"total"`, so its flag is `false`. The render
# resolves that key through the projection memo (`_get_filter_query(::SQLTypeField)` → `_alias_lhs`)
# and prints `CASE WHEN SUM(…) >= ?`, so every reader that trusted the flag treated an aggregate as
# a row expression: GROUP BY named it (both engines reject an aggregate there), and a filter on its
# alias went to WHERE. The window twin is the same shape: a `When("r" => 1)` over a `Rank(…)` alias
# was grouped beside an aggregate, and a filter on it escaped #685's refusal.
#
# So the build-time readers ask these instead of the node: the node's own answer, or the answer of
# any projection its conditions read by alias — the question Django answers with
# `contains_aggregate` on the RESOLVED expression. A static walk over the projection list, so it
# does not depend on declaration order or on what the memo holds at the moment of asking.
#
# Only a condition leaf reads an alias — the walk is `_each_condition_leaf`, whose note says why:
# the other spellings resolve a column without consulting the memo (measured for a String
# projection `"t2" => "total"` and for `F("total") + 1`: each raises `UnknownFieldError`). The alias
# test is the filter path's (`_alias_filter_key`): a plain key naming no model field. That covers
# every alias, because `values()` refuses one spelled with `__` (#757). `seen` stops a
# cycle — `"a"` reads `"b"` and `"b"` reads `"a"` — which only a statement that fails at render can
# spell, but the walk must return before that render gets to say so.
function _reads_alias(pred::Function, node, instruc::SQLInstruction,
                      seen::Set{String} = Set{String}())::Bool
  hit = false
  _each_condition_leaf(node) do leaf
    hit && return nothing
    key = _alias_filter_key(leaf.column, instruc)
    (key === nothing || key in seen) && return nothing
    push!(seen, key)
    source = _projected_source(memo_key(leaf.column), instruc)
    # A `Value(...)` literal is neither kind, and no source means the name is not a projection.
    source isa SQLTypeField || return nothing
    hit = pred(source.field) || _reads_alias(pred, source.field, instruc, seen)
    return nothing
  end
  return hit
end
_resolved_agg(node, instruc::SQLInstruction)::Bool =
  _is_agg(node) || _reads_alias(_is_agg, node, instruc)
_resolved_window(node, instruc::SQLInstruction)::Bool =
  _is_window_expr(node) || _reads_alias(_is_window_expr, node, instruc)
# #789: the same question for a window's OVER term, which `_build_over_clause` asks before grouping
# it. `partition_by = [Case([When("total__@gte" => 100, …)])]` over `"total" => Sum(…)` renders
# `CASE WHEN SUM(…)`, and an aggregate in GROUP BY is an error on both engines.
_resolved_contains_agg(node, instruc::SQLInstruction)::Bool =
  _contains_agg(node) || _reads_alias(_contains_agg, node, instruc)

# The left-hand side a HAVING/alias predicate renders against (#595).
#
# The branch used to take `memo_projection(...).field` unconditionally — the projection's already
# rendered SQL text. When the projected expression BINDS, that text carries placeholders whose values
# were filed under `:select`, and printing it again under HAVING emits markers with nothing behind
# them. `values("c" => Count(Case([When("year" => 1991, then = 1)]))).filter("c__@gt" => 0)` is two
# lines of exported API and produced five markers for three bound values: SQLite cannot bind the
# statement at all. (PostgreSQL numbers `$n` at render, so reprinting the text reuses `$1`/`$2` and
# is correct there — the same PG-is-fine/SQLite-is-broken split as #586 and #587.)
#
# The gate is the one `_get_filter_query(::SQLTypeField)` (#586, build_helpers.jl) and
# `get_order_query` (#587) already use, applied to the third and last consumer of the memo: reuse the
# text only for node kinds that cannot bind, and otherwise render the source afresh so the expression
# binds its own values in the clause it prints in. An aggregate legitimately appears twice in the
# statement, so binding twice is the correct reading, not a duplicate.
#
# #701: the WHERE path reads the memo through here too (`_get_filter_query(::SQLTypeField)`,
# build_helpers.jl). It had the #586 gate on the wrong node — the filter KEY, a plain `String` alias,
# rather than the projection behind it — so `Q("next_race" => 73)` over `F("raceid") + 1` reprinted
# the projection's `?` in WHERE with its value still in `:select`: three markers, two values on
# SQLite. Routing a row alias's top-level filter to WHERE (#701) would have inherited the same
# misbind, so the one gate now serves both clauses.
#
# That reader is keyed by more than aliases, and `_projected_source` matches on output NAME only, so
# two guards keep a key from finding a different projection that merely shares the name:
#
#   - the NAMESPACE. A projection alias lives in `:base`; a `:cte`/`:joined` key names a CTE or
#     joined-copy column, which binds nothing. Without this, `values("ev__grid" => F("grid") * 2)`
#     beside a CTE `ev` made the second `Qor("ev__grid" => 1, "ev__grid" => 2)` leaf render the
#     projection instead of the CTE column — valid SQL, aligned parameters, wrong rows. #757 now
#     refuses a `__` alias at `values()`, so that shape cannot be written (and #723's silent
#     CTE-wins pairing with it). The check stays as a backstop.
#   - the OUTPUT NAME. A field-path projection is memoized under its PATH (`values("r" => "points")`
#     under `"points"`); the entry is an alias only when it renders under the key.
#
# Any other hit is a column, and its memoized text is returned as it was.
#
# Callers must have switched to the clause the text prints in — the fresh render binds, and it must
# bind there.
function _alias_lhs(alias::MemoKey, cached, instruc::SQLInstruction)
  alias[1] === :base || return cached.field
  _projection_output_name(cached) == alias[2] || return cached.field
  source = _projected_source(alias, instruc)
  # No source (the memo was written by a non-projection path) or a kind that binds nothing: the
  # memoized text is safe, and reusing it keeps the common case byte-identical.
  source === nothing && return cached.field
  # #707: a `Value(...)` alias IS a binding — its memoized text is the SELECT's own `?`. Render the
  # literal again, so it binds in the clause it prints in (`WHERE ? = ?`, two values for two markers).
  source isa SQLTypeText && return _get_select_query(source, instruc)
  source.field isa Union{String,SQLTypeCTE,SQLTypeJoined,OuterRefObject} && return cached.field
  return _get_select_query(source.field, instruc, _as = source._as)
end

# `_guard_scalar_bytes`'s alias twin (#596). Same decision, different evidence: a projection alias has
# no `PormGField`, only whatever formatter `_having_alias_formatter` resolved for it, so binary-ness is
# read off that. `format_binary_sql` is what a projection over a `BinaryField` resolves to and is the
# only formatter that may carry a byte payload; every other alias refuses one, through the same funnel
# the WHERE arms use so the message is the one a user already knows.
function _guard_alias_scalar_bytes(v::SQLTypeOper, formatter, label::AbstractString)
  (v.operator == "=" && v.values isa Vector{UInt8}) || return nothing
  formatter === Models.format_binary_sql && return nothing
  _raise_invalid_filter_operator([String(label)], "vector",
                                 ["in", "nin", "range", "nrange", "has_any_keys", "has_keys", "jcontains"])
end

# The operators `_render_predicate` has no arm for, refused in the clause that cannot serve them (#618).
#
# #618 put `@range`, `@nrange` and `@isnull` here too: their WHERE arms returned above the shared
# ladder, so an alias filter reaching it got `"Invalid filter operator: BETWEEN is not a supported
# operator"`, naming a token the caller never typed. #654 moved those arms into the ladder, so only
# the JSON four remain. They never reach `_render_predicate` (`_resolve_having_filter_value` refuses
# first), but the message blamed the VALUE's type ("the c projection alias is the type number.
# Please check the value: {"a":1}") for what is really "this lookup has no alias renderer" — a JSONB
# operator over an aggregate has no obvious meaning, so refuse in the caller's own vocabulary.
const _ALIAS_UNSUPPORTED_OPERATORS = Dict("jcontains" => "@jcontains", "has_key" => "@has_key",
                                          "has_any_keys" => "@has_any_keys",
                                          "has_keys" => "@has_keys")
function _guard_alias_clause_operator(v::SQLTypeOper, label::AbstractString)
  spelling = get(_ALIAS_UNSUPPORTED_OPERATORS, v.operator, nothing)
  spelling === nothing && return nothing
  throw(FilterError(
    "The \e[31m$(spelling)\e[0m lookup is not supported on the projection alias " *
    "\e[31m$(label)\e[0m. It is available on a column — filter the underlying field instead, " *
    "or compare the alias with \e[32m@gt\e[0m / \e[32m@lt\e[0m / \e[32m@gte\e[0m / " *
    "\e[32m@lte\e[0m / \e[32m@in\e[0m / \e[32m@range\e[0m."))
end

# May `@isnull` put this alias's aggregate under `IS NULL`? (#654)
#
# `ISNULL` refuses any column text containing `(` (#197), and an aggregate alias renders as a call,
# so the alias branch has to say so explicitly — decided from the projection NODE, never sniffed from
# the rendered text. `MAX`/`MIN`/`SUM`/`AVG` return NULL exactly when every value in the group is
# NULL, which is a real question to ask. `COUNT` never returns NULL, so the lookup could never match
# — refused rather than rendered, because a filter that is silently always-false is the worse
# failure. Anything else (a bare `F("col")`, arithmetic, another function) answers `false`, which
# leaves `ISNULL`'s own guard to decide exactly as it does in `WHERE`.
const _ISNULL_AGGREGATES = ("MAX", "MIN", "SUM", "AVG")
function _alias_isnull_aggregate(alias::MemoKey, instruc::SQLInstruction)::Bool
  source = _projected_source(alias, instruc)
  source === nothing && return false
  projected = source.field
  projected isa SQLTypeFunction || return false
  projected.function_name == "COUNT" && throw(FilterError(
    "The \e[31m@isnull\e[0m lookup can never match the projection alias \e[31m$(alias[2])\e[0m: " *
    "COUNT never returns NULL — an empty group counts 0. Compare it with \e[32m$(alias[2])__@gt\e[0m " *
    "=> 0 or \e[32m$(alias[2])\e[0m => 0 instead."))
  return projected.function_name in _ISNULL_AGGREGATES
end

# #707: the ladder now walks the projection's node (`_expression_formatter`) instead of recognising
# a fixed list of shapes, and a type it cannot name answers `nothing` — NO check — where it used to
# answer `IntegerField().formatter`. The fallback was a guess, and a wrong one for every text
# function: `values("nm" => Lower("surname")); filter("nm" => "hamilton")` raised "the nm projection
# alias is the type number", while the same filter inside `Q(...)` worked. An unknown type now binds
# the value as given, which is what the WHERE path does for a column-less expression; a known one is
# checked on every spelling, because both route here.
function _having_alias_formatter(alias::MemoKey, instruc::SQLInstruction)
  memoized = memo_field(instruc, alias)
  memoized === nothing || return memoized.formatter
  source = _projected_source(alias, instruc)
  # A `Value(...)` alias is a literal compared with a literal: there is no column type to hold the
  # value to. Its `.field` is the literal itself, so it must not reach `_expression_formatter`,
  # whose `String` arm reads a string as a COLUMN PATH — `Value("points")` would be typed as the
  # `points` column.
  (source === nothing || source isa SQLTypeText) && return nothing
  formatter = _expression_formatter(source.field, instruc)
  # #900: a `Sum`/`Avg` over an interval is an interval, not the number `_expression_formatter` names
  # for every sum, and `"total__@gt" => Hour(1)` raised a `MethodError` from the number formatter. The
  # SELECT renders first, so the projection's kind is known here: the value is checked as a duration,
  # as `Max("time")`'s alias checks it, so a number is refused rather than compared with the text.
  formatter === Models.format_number_sql &&
    get(instruc.projection_kinds, Symbol(alias[2]), nothing) isa CInterval && return Models.format_duration_sql
  return formatter
end

# Functions whose result is text whatever their operands are. Checked BEFORE `output_field`: none of
# them renders a cast, and `Concat` — the one that takes `output_field` — refuses a non-text type when
# it is built (#835), so whenever a CTE body can type a `Concat` column (it needs an `output_field`
# there), it types it text too.
#
# `ToChar` (`EXTRACT_DATE`) is text too, but it is not listed: `PormGTypeField` types it, and that is
# checked first. #851 listed it here while the table keyed `TO_CHAR`, a name no node carries; #862
# keyed the table by the node's name instead, so the type has one home. A `ToChar` built with its own
# `formatter=` keeps it either way: `p.formatter` is checked before both.
const _TEXT_OUTPUT_FUNCTIONS = ("LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM", "REPLACE", "CONCAT")
# Functions whose result has the type of their operands — the first one that names a type decides.
const _OPERAND_TYPED_FUNCTIONS = ("MAX", "MIN", "COALESCE", "GREATEST", "LEAST", "NULLIF")

# The formatter a value compared with this expression must satisfy, or `nothing` when the
# expression's type cannot be named. Only a type that is KNOWN is returned — see
# `_having_alias_formatter`.
function _expression_formatter(p::SQLTypeFunction, instruc::SQLInstruction)
  p.formatter === nothing || return p.formatter
  name = p.function_name
  name == "AVG" && return Models.format_number_sql
  haskey(PormGTypeField, name) && return getfield(Models, PormGTypeField[name])
  name in ("SUM", "COUNT") && return Models.format_number_sql
  name in _TEXT_OUTPUT_FUNCTIONS && return Models.format_text_sql
  # `Cast` names its type; `Case`/`Coalesce`/`Greatest`/`Least` may (`output_field=`).
  declared = get(p.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  if declared isa AbstractString
    formatter = _sql_type_formatter(declared)
    formatter === nothing || return formatter
  end
  if name in _OPERAND_TYPED_FUNCTIONS
    for operand in (p.column isa AbstractVector ? p.column : (p.column,))
      formatter = _expression_formatter(operand, instruc)
      formatter === nothing || return formatter
    end
  end
  return nothing
end
# #576: a bare `F("col")` is the column. #707: arithmetic on a NUMBER stays a number; any other
# operation (`F("happened") + Day(1)`) keeps no type, rather than get the column's.
function _expression_formatter(p::FExpression, instruc::SQLInstruction)
  p.operation === nothing && return _expression_formatter(p.column, instruc)
  left = _expression_formatter(p.field_name, instruc)
  return left === Models.format_number_sql ? left : nothing
end
_expression_formatter(p::SQLField, instruc::SQLInstruction) = _expression_formatter(p.field, instruc)
function _expression_formatter(p::Union{String,CTEReference,JoinedReference}, instruc::SQLInstruction)
  column_field = _alias_column_field(p, instruc)
  return column_field === nothing ? nothing : column_field.formatter
end
_expression_formatter(::Any, ::SQLInstruction) = nothing

# #800 — the canonical kind a FUNCTION projection's value is stored as, for the #564 read path, or
# `nothing` when it is not one the representation table owns or cannot be named.
#
# Django's `output_field` question, answered only where the answer is not a guess: an extremum and
# the window VALUE functions return one of their operand's own values, so they have its kind — on
# SQLite that is the column's stored text, which the column's parser undoes. `SUM`/`AVG`/`COUNT` are
# computed and never inherit it: a sum of intervals is not an interval PormG wrote, and a decimal sum
# went through a double (#648's reason). Every other function answers `nothing` and its value stays
# as the driver delivered it — the fail-open default.
#
# Called AFTER the projection renders, like `_projection_column_kind`: resolving a joined path is
# what populates the memo `_alias_column_field` reads.
#
# #822: a `Cast(x, "date")`, or a `Case` whose `output_field` is a date, is a date because the SQL
# makes it one on both engines — `::date` on PostgreSQL, `date(…)` on SQLite — so it reads back as a
# `Date` on both, not a `Date` on one and a `String` on the other.
#
# #824: the `@date` transform is a date for the same reason — `(col)::date` on PostgreSQL,
# `strftime('%Y-%m-%d', …)` on SQLite (`Dialect.DATE`) — whatever its operand. `COALESCE`, `GREATEST`
# and `LEAST` declared `date` are dates for the `Cast` reason: since #852 they render the cast on both
# engines (`date(…)` on SQLite). Otherwise their value is one operand's own: they are typed only when
# every operand agrees (`_multi_operand_kind`). `NULLIF(a, b)` returns `a` or NULL, so it is `a`.
const _KIND_PRESERVING_FUNCTIONS = ("MAX", "MIN", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE")
const _AGREEING_OPERAND_FUNCTIONS = ("COALESCE", "GREATEST", "LEAST")
function _function_projection_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)::Union{CanonicalType,Nothing}
  if p isa FObject && p.function_name in ("CAST", "CASE", "COALESCE", "GREATEST", "LEAST")
    declared = get(p.kwargs, p.function_name == "CAST" ? "type" : "output_field", nothing)
    declared isa AbstractString && _sql_type_field(declared) isa Models.sDateField && return CDate()
  end
  p isa FObject && p.function_name == "DATE" && return CDate()
  p isa FObject && p.function_name in _AGREEING_OPERAND_FUNCTIONS && return _multi_operand_kind(p, instruc)
  p isa FObject && p.function_name == "NULLIF" && return _operand_kind(first(p.column), instruc)
  p.function_name in _KIND_PRESERVING_FUNCTIONS || return nothing
  return _operand_kind(p.column, instruc)
end
_function_projection_kind(::Any, ::SQLInstruction) = nothing

# #824 — the kind of a function whose value is one of several operands' own values. Typed only on
# agreement: every operand names the SAME kind (a `CDecimal` of the same width, a `CDateTime` of the
# same flavour). An operand with no kind — a text or number column, a number, arithmetic, a function
# PormG does not type — disqualifies the whole projection: the value may be that operand's, and a
# kind taken from the others would run text through a date parser (`Coalesce("note", Date(…))`). A
# NULL literal is skipped: it is never the value. A declared `output_field` other than `date` (which
# `_function_projection_kind` answers first) is kept only when it names the kind the operands agree on:
# the cast it renders (#852) is not a read kind of its own — `Cast(x, "numeric(10,2)")` records none
# either — so a declaration that disagrees with the operands records nothing.
function _multi_operand_kind(p::FObject, instruc::SQLInstruction)::Union{CanonicalType,Nothing}
  kind = nothing
  for operand in (p.column isa AbstractVector ? p.column : (p.column,))
    _is_null_literal(operand isa SQLText ? operand.field : operand) && continue   # the #812 `Case` rule
    k = _operand_kind(operand, instruc)
    (k === nothing || (kind !== nothing && k != kind)) && return nothing
    kind = k
  end
  declared = get(p.kwargs, "output_field", nothing)
  if kind !== nothing && declared isa AbstractString
    declared_field = _sql_type_field(declared)
    (declared_field === nothing || field_canonical_kind(declared_field) != kind) && return nothing
  end
  return kind
end

# The operand's kind: a column path is its field's; a bare `F(col)` is the column; a function is what
# `_function_projection_kind` says of it, so `Max(Coalesce(…))` and `Coalesce(Max("d"), …)` compose; a
# literal is its Julia type's (#721's rule, the kind a projected `Value(x)` records). Any other operand
# — arithmetic — answers `nothing`, rather than a kind the value may not have.
#
# #888: a `Subquery(...)` is its one projected column, as its own build typed it — see
# `_subquery_kind`.
#
# #824: a `Joined(...)` handle is the joined column, exactly as `Max(Joined(…))` reads it, so the two
# agree. A `CTE(...)` handle is NOT its inferred field: `_set_field_from_sql_function` hands an
# `Avg("amount")` column the operand's own `DecimalField`, which would run a computed double through
# the decimal parser (#648). It is the body's own read record instead — see `_cte_column_kind`.
function _operand_kind(p::String, instruc::SQLInstruction)
  # A transformed path (`"ts__@date"`) names the transform's result, not the column — through the one
  # transform ladder (#562), the call `_get_filter_query(::String)` renders with.
  occursin("__@", p) && return _function_projection_kind(_check_function(p), instruc)
  column_field = _alias_column_field(p, instruc)
  return column_field === nothing ? nothing : field_canonical_kind(column_field)
end
_operand_kind(p::FExpression, instruc::SQLInstruction) =
  p.operation === nothing ? _operand_kind(p.field_name, instruc) : nothing
_operand_kind(p::SQLField, instruc::SQLInstruction) = _operand_kind(p.field, instruc)
_operand_kind(p::SQLText, ::SQLInstruction) = literal_canonical_kind(p.field)
_operand_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction) = _function_projection_kind(p, instruc)
function _operand_kind(p::JoinedReference, instruc::SQLInstruction)
  column_field = _alias_column_field(p, instruc)
  return column_field === nothing ? nothing : field_canonical_kind(column_field)
end
_operand_kind(p::CTEReference, instruc::SQLInstruction) = _cte_column_kind(p, instruc)
_operand_kind(p::SubqueryObject, instruc::SQLInstruction) = _subquery_kind(p, instruc)
_operand_kind(::Any, ::SQLInstruction) = nothing

# #824 — the read kind of a CTE column. The body is built before the outer query (`build_cte_clause`
# runs first), and building it recorded the kind of each of its own projections under the same
# output name the CTE model gives the column — so that record IS the answer, by the same rule, on the
# same connection: a plain column has its kind, `Max` its operand's, a `Cast(…, "date")` `CDate`, and
# `Avg`/`Sum`/`Count`/arithmetic none. A path that hops on through the CTE column
# (`CTE("ev", "parent__x")`) ends at a real model field, which the join walk memoised. No record —
# a body not built in this pass — answers `nothing`, the fail-open default.
function _cte_column_kind(ref::CTEReference, instruc::SQLInstruction)::Union{CanonicalType,Nothing}
  if occursin("__", ref.path)
    column_field = _alias_column_field(ref, instruc)
    return column_field === nothing ? nothing : field_canonical_kind(column_field)
  end
  cte = get(instruc.object.ctes, ref.name, nothing)
  cte === nothing && return nothing
  body = get(cte, "query", nothing)
  body isa SQLObjectHandler || return nothing
  return get(body.object.projection_kinds, Symbol(ref.path), nothing)
end

# #888 — the read kind of a `Subquery(...)`: its one projected column's, by `_cte_column_kind`'s rule.
# The inner build typed that column the way it types any projection (a plain column has its kind,
# `Max` its operand's, a `Cast(…, "date")` `CDate`, and `Avg`/`Sum`/`Count`/arithmetic none), and
# `_get_select_query(::SubqueryObject)` filed it under the node when it rendered it. So this is read
# AFTER the render, like every kind lookup here; a node this build did not render — or an inner
# projection with no kind — answers `nothing`, the fail-open default, and the value stays as the
# driver delivered it.
_subquery_kind(p::SubqueryObject, instruc::SQLInstruction)::Union{CanonicalType,Nothing} =
  instruc.subquery_kinds === nothing ? nothing : get(instruc.subquery_kinds, p, nothing)

# The kind the inner build recorded. A subquery projects exactly one column (the render refuses any
# other count), but a wildcard over a one-field model can record that column under two names — its
# attribute and its `db_column` — so the answer is the kind they agree on, and none if they do not.
function _record_subquery_kind!(instruc::SQLInstruction, p::SubqueryObject, inner::SQLObjectHandler)
  kinds = unique(Base.values(inner.object.projection_kinds))
  length(kinds) == 1 || return nothing
  instruc.subquery_kinds === nothing && (instruc.subquery_kinds = IdDict{SubqueryObject,CanonicalType}())
  instruc.subquery_kinds[p] = only(kinds)
  return nothing
end

# The field a type name `output_field=` / `Cast` holds stands for — already validated and spelled by
# `Dialect.cast_type_name`, so only the canonical words need recognising. A name outside the text,
# number, boolean and date families (a timestamp, which has two representations, an array, `bytea`)
# answers `nothing`.
#
# #852: an ARRAY answers `nothing` whatever its element. The split on `(` below drops the suffix, so
# `"numeric(10,2)[]"` came back as a scalar `DecimalField` (and `"varchar(20)[]"` as `CharField`) while
# `"integer[]"` answered `nothing` — a `Cast` to an array typed as a scalar by both readers.
# `cast_type_name` writes every array suffix as a trailing `[]`, so the check is exact.
#
# #812: one table for both readers. A CTE column typed from `Case(…; output_field = …)` needs a FIELD
# (`_set_field_from_sql_function`, ctes.jl), a projection-alias filter only its formatter; answering
# the formatter off the same field is what keeps the two from ever disagreeing on a type name.
#
# #823: the names PormG's own fields produce (`PositiveIntegerField().type` is `INTEGER UNSIGNED`) and
# PostgreSQL's `int2`/`int4`/`int8`/`float4`/`float8` aliases. Each casts to the same affinity on SQLite
# (INT / FLOA in the name). `integer unsigned` is a plain integer: PostgreSQL renders it `integer`, and
# no cast enforces the sign. Widening this also widens the alias filter: a value compared with
# `Cast(x, "int8")` is now checked as a number, where it used to bind unchecked.
function _sql_type_field(type_name::AbstractString)::Union{PormGField,Nothing}
  Base.endswith(strip(type_name), "]") && return nothing
  base = lowercase(strip(first(split(type_name, '('))))
  base == "text" && return Models.TextField()
  base in ("varchar", "character varying", "char", "character") && return Models.CharField()
  base in ("smallint", "integer", "int", "int2", "int4", "integer unsigned") && return Models.IntegerField()
  base in ("bigint", "int8") && return Models.BigIntegerField()
  base in ("real", "double precision", "float", "float4", "float8") && return Models.FloatField()
  base in ("numeric", "decimal") && return Models.DecimalField()
  base in ("boolean", "bool") && return Models.BooleanField()
  base == "date" && return Models.DateField()
  return nothing
end

function _sql_type_formatter(type_name::AbstractString)
  field = _sql_type_field(type_name)
  return field === nothing ? nothing : field.formatter
end

# The field a `Max`/`Min` or bare-`F` projection's column names, or `nothing` when it names none.
#
# #652: #576 resolved only a key of `model.fields`, so `Max("driverid__surname")` — the most natural
# text aggregate there is — fell to the `IntegerField` fallback and refused every text term. The
# terminal field is not a guess: the join walk records it under the path's `MemoKey` while the
# SELECT renders (`build_joins.jl`, the `memo_field!` after the walk; `_build_row_join` for a
# CTE/joined handle), and `build()` renders the SELECT before the filters, so it is there when this
# runs — the same entry the WHERE path's joined-path arm reads. A `CTEReference`/`JoinedReference`
# column is what `_retag_cte_field!`/`_retag_joined_field!` leave behind, and `memo_key(ref)` names
# its namespace. Anything else names no single column, and `_expression_formatter` decides it.
_alias_column_field(column::String, instruc::SQLInstruction) =
  haskey(instruc.object.model.fields, column) ? instruc.object.model.fields[column] :
                                                memo_field(instruc, memo_key(:base, column))
_alias_column_field(column::Union{CTEReference,JoinedReference}, instruc::SQLInstruction) =
  memo_field(instruc, memo_key(column))
_alias_column_field(::Any, ::SQLInstruction) = nothing

# One projection-alias predicate: the guards, then the left-hand side, the bound value and the
# operator ladder. #692 lifted it out of the top-level alias branch in `get_filter_query` so that an
# aggregate alias inside `Q(...)`/`Qor(...)` renders through the same code (`_get_having_query`)
# rather than a second copy of it. #701 renders a top-level ROW alias through it too, in WHERE: the
# predicate is the same in either clause, and this is where the alias's value gets its type (#576).
#
# The caller must have switched to the clause the predicate prints in — `_alias_lhs` and
# `_bind_predicate_value` both bind — and must restore the context in a `finally`.
function _render_alias_predicate(v::SQLTypeOper, having_key::MemoKey, having_cached,
                                 instruc::SQLInstruction)::String
  # #685: a window alias reaches this branch exactly as an aggregate one does, and neither clause
  # is a home for it — see `_guard_window_alias_predicate`. First of the guards, so it refuses
  # before anything below resolves, renders or binds.
  _guard_window_alias_predicate(_projected_source(having_key, instruc), having_key[2], instruc)
  # The guards run BEFORE the left-hand side is resolved. None depends on anything the render
  # produces, and `_alias_lhs` can bind (#595) — so refusing afterwards would file a binding
  # projection's operands into the clause's bucket and then throw them away. Waste rather than a
  # defect, since the instruction is discarded with the throw, but the ordering is free.
  #
  # #596: an alias is a bare path too, so `values("c" => Count("id")); filter("c" => bytes)`
  # reaches here. There is no `PormGField` to hand the guard — the alias's type comes from
  # `_having_alias_formatter` — so decide on that formatter: `format_binary_sql` is what a
  # projection over a `BinaryField` resolves to, and only that one may carry a payload.
  # (`ImageField`/`FileField` share `type == "BLOB"` but carry `format_text_sql`, so the
  # formatter test is as tight as the WHERE side's `_is_binary_field` struct test.)
  _guard_alias_scalar_bytes(v, _having_alias_formatter(having_key, instruc), having_key[2])
  # #618: refuse, in this clause, the operators `_render_predicate` has no arm for — since #654
  # only the JSON four. Naming the user's own spelling matters here: the internal token is
  # `jcontains`, but nobody types that — they type `@jcontains`.
  _guard_alias_clause_operator(v, having_key[2])
  # #654: `@isnull` on a COUNT alias refuses here, ahead of any render, for the reason above.
  isnull_aggregate = v.operator == "ISNULL" && _alias_isnull_aggregate(having_key, instruc)
  # #894: an interval alias compared with a duration compares milliseconds on SQLite.
  interval = _render_interval_alias_predicate(v, having_key, instruc)
  interval === nothing || return interval
  # #903: the alias's own column type decides what a pattern lookup reads — `HOST(MAX(…))` for an alias
  # over an `inet`, exactly as `_get_filter_query(::SQLTypeOper)` wraps the column itself.
  field = _pattern_operand(string(_alias_lhs(having_key, having_cached, instruc)),
                           _having_alias_formatter(having_key, instruc), v.operator, instruc)
  # #618: `contains=` / `operator=` are what run `_apply_like_wildcards` (and with it
  # `escape_like_pattern`) inside `add_parameter!`. Without them a pattern lookup on an alias
  # bound its value undecorated AND unescaped — no `%`, and a user-supplied `%` or `_` in the
  # term matched as a wildcard. `_bind_predicate_value` applies that gate — membership in
  # `LIKE_WILDCARD_OPERATORS`, exactly as the WHERE binding arms in `build_helpers.jl` spell
  # it; the `*_exact` and regex (#635) pattern lookups take the value verbatim and must NOT be
  # decorated, which is why that tuple and `PATTERN_LOOKUP_OPERATORS` are deliberately
  # different sets (`constants.jl`). #654: it also binds a range's two operands, and nothing for `@isnull`.
  placeholder = _bind_predicate_value(instruc, v.operator,
                  _resolve_having_filter_value(having_key, v.values, instruc, v.operator))
  # #618: one ladder, shared with the WHERE path — see `_render_predicate`. It absorbs the #411
  # `IN`/`NOT IN` membership case this branch used to special-case, adds the
  # `PATTERN_LOOKUP_OPERATORS` → `Dialect` dispatch it never had, and brings the
  # unknown-operator refusal that was missing here entirely.
  return _render_predicate(string(field), v.operator, placeholder, instruc;
                           aggregate = isnull_aggregate)
end

# #894 — an interval alias compared with a duration compares milliseconds on SQLite: the alias's own
# value is its `HH:MM:SS` text, which orders wrongly at 100 hours and for negative values. The duration
# binds as milliseconds, as it does against a difference inside an expression (#881). `nothing`, having
# rendered and bound nothing, for every other predicate — a value that is not a duration, an operator
# that is not an ordering or a membership, PostgreSQL — which the caller renders as it always did.
#
# Two callers: `_render_alias_predicate`, for a filter on the alias (WHERE, HAVING, `Q`), and #907
# `_get_filter_query(::SQLTypeOper)`, for a `When` condition on it, which renders through that path and
# never reached this one, so `Case(When(Q("t__@gt" => Hour(1)); …))` compared the text with `"01:00:00"`.
#
# The projection renders exactly once, into the active bucket. When that render turns out to have no
# millisecond form, its text stands in for `_alias_lhs`, which would bind the same values, and the value
# binds as the alias's own formatter binds it — the predicate `_render_alias_predicate` renders below.
function _render_interval_alias_predicate(v::SQLTypeOper, having_key::MemoKey, instruc::SQLInstruction)::Union{String,Nothing}
  having_key[1] === :base || return nothing
  source = _projected_interval_source(having_key[2], instruc)
  source === nothing && return nothing
  ms_values = _predicate_duration_ms(v.operator, v.values)
  ms_values === nothing && return nothing
  sql, interval_ms = _render_interval_ms(source.field, instruc; _as = source._as)
  interval_ms && return _render_predicate(sql, v.operator, _bind_predicate_value(instruc, v.operator, ms_values), instruc)
  placeholder = _bind_predicate_value(instruc, v.operator,
                  _resolve_having_filter_value(having_key, v.values, instruc, v.operator))
  return _render_predicate(sql, v.operator, placeholder, instruc)
end

# The plain filter key a predicate compares — a `String` path with no `__` — or `nothing`.
#
# One definition for the alias test, which was spelled out three times (the top-level branch below,
# `_guard_window_alias_in_q`, `_aggregate_alias_leaf`), and for #703's collision guard, which asks the
# complementary question of the same key.
_plain_filter_key(col) =
  (col isa SQLTypeField && col.field isa String && !contains(col.field, "__")) ? col.field : nothing

# The alias test: a plain key that names no field of the model. It is a projection alias or a name
# that does not exist; the callers tell those apart through the memo.
function _alias_filter_key(col, instruc::SQLInstruction)
  key = _plain_filter_key(col)
  (key === nothing || key in instruc.object.model.field_names) && return nothing
  return key
end

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
          set_context!(instruc, clause)
          try
            push!(clause === :having ? instruc.having : instruc._where, _get_filter_query(v, instruc))
          finally
            set_context!(instruc, :where)
          end
          continue
        end
        # Switch to the clause's context for positional parameters. #595 moved this ABOVE the
        # left-hand side: resolving it can now RENDER, and a render binds — those values belong in
        # the clause's bucket with the comparison value, ahead of it, exactly as they print.
        # The restore is in a `finally` because the render can throw from several places — the
        # guards, the fresh render in `_alias_lhs` (#595), `_render_predicate`'s
        # unknown-operator `FilterError` and the SQLite-refusing `Dialect` arms'
        # `BackendCapabilityError` (#618). Leaving the clause's context active would file a later
        # clause's values in the wrong bucket. Harmless today — every such throw escapes `build()` and the
        # instruction is discarded — but it matches what `_get_select_query(::ExistsObject)` already
        # does for `correlated_projection`, and it stops the next caller who catches one of these
        # from inheriting a wrong context.
        set_context!(instruc, clause)
        try
          push!(clause === :having ? instruc.having : instruc._where,
                _render_alias_predicate(v, having_key, having_cached, instruc))
        finally
          set_context!(instruc, :where)
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
        set_context!(instruc, :having)
        try
          push!(instruc.having, _get_having_query(having_part, instruc))
        finally
          set_context!(instruc, :where)
        end
      end
    else
      throw(FilterError("Invalid filter entry: $(v) (::$(typeof(v))) is not a Q, Qor, or operator expression."))
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
# shape can no longer be written. The path half of the guard stays as a backstop.
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
# Recursive, in the shape of `_guard_no_handle` (ctes.jl) and with its depth cap, because `Q(...)`
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
  _expression_operand(v.values) && return _get_filter_query(v, instruc)
  having_key, having_cached = _aggregate_alias_leaf(v, instruc)
  return _render_alias_predicate(v, having_key, having_cached, instruc)
end
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
_expression_operand(x) = x isa Union{SQLTypeF,SQLTypeFunction,SQLTypeCTE,SQLTypeJoined,SQLObjectHandler}
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

# One resolved cjoin ON condition: the rendered SQL fragment and the positional parameter values it
# bound. The two MUST travel together (#421). Phase 1b below can move a fragment onto a different
# join, and on a positional backend a value's INDEX in the `:join` bucket IS its binding — so a
# fragment whose text moved while its values stayed put bound its neighbour's value. Silently wrong
# rows on SQLite; PostgreSQL was always correct, because `$N` numbering travels with the text.
struct OnExtra
  sql::String
  params::Vector{Any}
end

function build_row_join_sql_text(instruc::SQLInstruction)
  @pormg_debug false

  # --- Phase 1: pre-resolve ON conditions -----------------------------------
  # Filter resolution for deep paths (e.g. "raceid__circuitid__country") may
  # create additional join entries in instruc.row_join via _build_row_join.
  # By pre-resolving with an index-based loop we process newly created entries
  # in order and store the generated SQL fragments for Phase 2.
  on_clause_extras = Dict{Int, Vector{OnExtra}}()
  i = 1
  while i <= length(instruc.row_join)
    value = instruc.row_join[i]
    set_context!(instruc, :join)

    on_conditions = _on_conditions(value)
    # `!isempty`, not "has the slot" (#487): a `cjoin_on` declared with no predicates carries an
    # EMPTY vector, and recording an empty extras list for it — or for every CTE row, which has none
    # by construction — would make Phase 1c below refuse every `CrossJoin` and Phase 2 misreport
    # #435's "every predicate relocated" case as this one.
    if !isempty(on_conditions)
      alias_a_quoted = quote_identifier(value.alias_a, instruc.connection)
      original_alias = instruc.alias
      extras = OnExtra[]

      no_anchor = value isa AnchorlessJoin
      for condition in on_conditions
        # #421: lift the values this condition binds straight back out of the bucket. Phase 1b may
        # still move the fragment, so nothing resolved here has a final clause position yet; Phase 2
        # puts the values back at the point of emission.
        #
        # The mark/detach pair captures exactly this condition's run because the bucket it marks is
        # the bucket every value lands in. Being precise about WHY, since the obvious phrasing —
        # "nothing reachable from here switches context" — is false:
        #
        #   - The plain shapes (eq, @range, @contains, Q, Qor, F) never switch context at all. `@in`
        #     does when its right side is a SUBQUERY that itself declares a `.with(...)`: that renders
        #     through `build_cte_clause`, which switches to `:cte` and binds there. Both `?` end up in
        #     the JOIN text while both values end up in `:cte`, so the mark (holding the `:join`
        #     vector) correctly lifts NOTHING and the OnExtra carries markers with no params.
        #     >> CLOSED BY #433, not here. This described a live hole: an ON list of
        #        `["id__@gt" => 7, "parent__@in" => <subquery with a .with(...)>]` bound SQLite
        #        ["CTEVAL","SUBVAL",7] against PostgreSQL's [7,"CTEVAL","SUBVAL"], because `:cte`
        #        flattens before `:join` while the text order is the reverse. Different root cause
        #        from #421 (bucket choice, not fragment movement); `OnExtra` neither caused nor
        #        repaired it. #433 refuses the shape — a subquery consumed by `@in`,
        #        `Subquery(...)` or `Exists(...)` may no longer declare its own CTE. Note WHERE:
        #        such an ON list is still ACCEPTED at declaration and refused at build/render time,
        #        so the desynchronizing input can be constructed but never rendered. Kept as a
        #        record of WHY the refusal exists: if that guard is narrowed, this misbind returns.
        #   - `Exists(...)` — which a `cjoin_on` ON expression DOES accept, though a keyed cjoin's
        #     `filters` reject it — runs a NESTED build, and that build's own join render calls
        #     `set_context!(:join)` UNGATED even under `set_contexts=false`. So context does move.
        #     It is harmless here for a specific reason: the ambient context in this loop already IS
        #     `:join`, and `_build_exists_query` restores the ambient one in a `finally` on both the
        #     normal and the throwing exit. The invariant is therefore "the same bucket vector", not
        #     "no switching happened" — which is exactly why the mark holds the bucket VECTOR rather
        #     than the context symbol. A future shape that switched to a DIFFERENT bucket and failed
        #     to restore it detaches nothing here instead of lifting an unrelated run.
        #   - Nothing reachable from `_build_row_join` binds a parameter: `build_joins.jl` has no
        #     `add_parameter!` at all, and `ctes.jl`'s only binding site is `build_cte_clause`, which
        #     JOIN RESOLUTION never calls (its callers are in `execution.jl`, ahead of `build()`).
        #     Note the careful scope — `build_cte_clause` IS reachable from `_get_filter_query`, just
        #     not from join resolution: that is the `@in`-over-a-CTE-subquery case above.
        #
        # KNOWN LIMIT, neither caused nor repaired here: inside an `Exists(...)`, the nested query's
        # own ON and WHERE parameters are already bound in the wrong order relative to its rendered
        # text (same root cause — the ungated `:join` switch — but on the subquery's own values).
        # `OnExtra` carries that run faithfully, preserving whatever order it arrived in.
        mark = parameter_mark(instruc)
        condition_sql = _get_filter_query(condition, instruc)
        condition_params = detach_parameters!(mark)
        # #45: anchor-less cjoin_on conditions already carry explicit aliases (bare F = base alias,
        # Joined("b2","col") = the joined copy), so skip the single-side base-alias remap the FK path needs.
        if !no_anchor
          condition_sql = replace(condition_sql, "\"$(original_alias)\"." => "$alias_a_quoted.")
        end
        push!(extras, OnExtra(condition_sql, condition_params))
      end

      instruc.alias = original_alias
      on_clause_extras[i] = extras
    end
    i += 1
  end

  # --- Phase 1b: relocate forward-referencing ON extras ----------------------
  # An ON extra on join `idx` that names the alias of a join emitted LATER is a forward reference:
  # Phase 2 emits joins in `row_join` order, so `dep_idx`'s JOIN clause has not appeared yet and
  # both backends reject the reference. This happens when the ON condition walks a deep path
  # (e.g. raceid__circuitid__country) that chains through the current join's target table.
  #
  # Fix: move the extra onto the LAST join it references. That join is emitted after every alias
  # the extra names, and its own base ON already references its parent, so the ordering holds.
  #
  # The window is `idx+1 : end`, i.e. actual emission order — NOT "created during Phase 1"
  # (`dep_idx > n_before`), which is what it used to test. That snapshot only described *when* an
  # entry was appended, and a forward reference does not care: a join that already existed at entry
  # is just as unemitted when it sits at a higher index. Two ways to reach that case, one of them
  # pre-dating #404 — projecting the deep path (`values("parent__grandparent__code")`) builds the
  # deeper join up front, and since #404 ordering by it does the same. In both, Phase 1 dedups the
  # ON condition onto the existing entry instead of creating one, so the old window was empty and
  # the extra stayed on the wrong join. Keying on index order covers every case uniformly.
  #
  # Relocation changes the order extras are EMITTED in, and on a positional backend that used to
  # desynchronize the parameter bucket: Phase 1 bound in row_join order, Phase 2 emitted in
  # relocated order, and nothing reconciled the two, so a relocated extra bound its neighbour's
  # value (#421). Each extra now carries its own values and Phase 2 re-appends them as it emits,
  # which makes binding order and emission order the same thing by construction. PostgreSQL never
  # had the problem — `$N` numbering travels with the text.
  #
  # `relocated_to` exists only so a later failure can say WHERE a predicate went. `delete!` below
  # erases the fact that this join ever had extras, which left the `no_anchor` guard in Phase 2
  # reporting "cjoin_on produced no ON conditions" at a caller who had provided one (#435). The
  # dict is diagnostic; nothing reads it on a successful build.
  # Destination row_join INDICES, not alias names: the raise site needs the entry itself to tell a
  # model join (which the caller can project in `values(...)`) from another `cjoin_on` (which they
  # cannot — there is no path to project). Names are derived from the indices where needed.
  relocated_to = Dict{Int, Vector{Int}}()
  # …and whether any predicate that left ALSO named the join it left. That single bit decides which
  # advice is true when a `cjoin_on` is emptied, and the two are opposites:
  #
  #   named its own alias  — `Joined("b2","sku") == F("parent__grandparent__code")` — is a real
  #     correlation that moved only because its other side is not built yet. Projecting that path
  #     in `values(...)` builds it first, nothing relocates, and the join renders CORRECTLY
  #     (`ON ("b2"."sku" = "Tb_2"."code")`). Telling this caller to "add a predicate naming b2"
  #     is telling them to do what they already did.
  #   named no alias of its own — `"parent__grandparent__code" => "Z"` — has nothing correlating
  #     the join at all. Projecting makes it render `ON "Tb_2"."code" = ?`, an unconstrained join
  #     that multiplies rows silently. Here projecting is the WRONG fix and the raise is right.
  #
  # Phase 1b is the only place that knows which, because it is holding the fragment when it decides
  # to move it. Review of #435 caught the message asserting the second case's advice at both.
  relocated_self_ref = Set{Int}()
  for idx in 1:length(instruc.row_join)
    haskey(on_clause_extras, idx) || continue
    extras = on_clause_extras[idx]
    relocated = falses(length(extras))

    for (ei, extra) in enumerate(extras)
      # Search downwards, so the first hit is the LAST join this extra references and one move
      # reaches the fixed point. Ascending is NOT wrong — the outer loop above revisits relocation
      # targets, so an extra dropped on the nearest match would cascade the rest of the way one hop
      # per visit — it is just O(hops) moves for the same result, and it makes termination an
      # argument about convergence. Descending keeps that argument to one line: dep_idx is the
      # MAXIMUM match, so when the outer loop later reaches dep_idx its search range is a subset
      # already proven not to match, and no extra can move twice.
      for dep_idx in length(instruc.row_join):-1:(idx + 1)
        # The trailing dot is REQUIRED, not cosmetic. An extra renders every column reference as
        # `"alias"."col"`, so a bare `"name"` test also matches the COLUMN half — and a cjoin_on
        # alias that happens to share a column's name (`alias = "code"` against `"Tb_2"."code"`)
        # then drags an unrelated join's ON filter onto itself. That is valid SQL returning wrong
        # rows, silently. Phase 1 above already keys on the same `"alias".` form (:310).
        if occursin("\"$(instruc.row_join[dep_idx].alias_b)\".", extra.sql)
          haskey(on_clause_extras, dep_idx) || (on_clause_extras[dep_idx] = OnExtra[])
          push!(on_clause_extras[dep_idx], extra)
          relocated[ei] = true
          dests = get!(relocated_to, idx, Int[])
          dep_idx in dests || push!(dests, dep_idx)
          # Same `"alias".` form as every other alias test here, for the same reason.
          occursin("\"$(instruc.row_join[idx].alias_b)\".", extra.sql) &&
            push!(relocated_self_ref, idx)
          break
        end
      end
    end

    # Keep only the non-relocated extras on the original join
    if any(relocated)
      on_clause_extras[idx] = extras[.!relocated]
      isempty(on_clause_extras[idx]) && delete!(on_clause_extras, idx)
    end
  end

  # --- Phase 1c: refuse extras that landed where no ON clause can carry them --
  # #424: a CROSS-joined CTE is the one join shape with no ON clause to merge `on_clause_extras`
  # into, so a predicate that lands there simply vanishes — row multiplication, no error. #421 made
  # that worse before this made it better: once values travel with their text, the orphaned value
  # disappears too and the wrong query becomes perfectly well-formed. Fail closed, the same posture
  # `_get_join_condition_list` takes on this marker (#394).
  #
  # #435 hoisted this out of the Phase 2 CROSS branch. Phase 2 walks `row_join` in index order, so
  # whether it fired depended on where the CROSS entry sat: a `no_anchor` join at a LOWER index
  # reported its own symptom — "produced no ON conditions", the state after relocation rather than
  # the cause — and the accurate message never ran. Diagnosing before emitting makes the cause win
  # regardless of ordering.
  #
  # #474 REMOVED the name-collision half of this loop, and with it the second, KEYED-CTE branch
  # #447 had added. `on_clause_extras[idx]` used to reach a CROSS entry two ways: Phase 1b relocating
  # a fragment that names its alias, or the entry carrying its own `on_conditions` — which it did
  # exactly when `custom_join[<cte name>]` existed, because `_build_row_join`'s shared tail looked
  # a CTE hop up in the base model's join-config registry under the CTE's own name. That lookup is
  # gone (`build_joins.jl`, the `cte` gates in `_build_row_join`'s shared tail), so the second route
  # is unrepresentable rather than
  # diagnosed, and a CTE name colliding with a `cjoin` path / `cjoin_on` alias / `on()` path is now
  # simply two relations that happen to share a name — both emitted, both addressable.
  #
  # WHAT IS LEFT IS A BACKSTOP, NOT A DIAGNOSIS. The relocation route needs a predicate naming the
  # CTE's alias, and that alias is GENERATED (`_get_alias_name` → `R1_1`): no predicate in a join
  # clause can name a CTE — a `CTE(...)` handle is refused there (#444), and since #492 restored the
  # `__` string spelling, a CTE-rooted string is refused in the same three clauses too, at build
  # time (`_refuse_cte_string_in_join`) — so the only way to write that name is a `cjoin_on` alias
  # that impersonates
  # a generated one, and `row_join` always orders CTE joins ahead of `cjoin_on` entries, while
  # Phase 1b only ever relocates FORWARD. Nine shapes were built against this after the change (the
  # three former collision producers plus six relocation attempts, including two CROSS CTEs and an
  # alias impersonating `R1_1`); none reached it.
  #
  # It stays anyway, and the message below no longer mentions a collision, which would now be
  # measurably wrong. Do not "clean up" the unreachability by deleting the throw: the failure it
  # catches is a silently dropped predicate on a Cartesian join, and this file's own history is that
  # the reachable-shape list here was "written twice and wrong twice". If you can construct a
  # producer, it belongs in `test_order_by_joins.jl` next to the coexistence tests.
  for (idx, value) in enumerate(instruc.row_join)
    value isa CrossJoin || continue

    haskey(on_clause_extras, idx) && throw(QueryBuildError(
      "An ON predicate resolved onto \e[4m\e[31m$(value.alias_b)\e[0m, the CROSS-joined CTE " *
      "\e[4m\e[31m$(value.b)\e[0m (a \e[4m\e[32m.with(...)\e[0m declared without " *
      "\e[4m\e[32mjoin_field\e[0m). A CROSS JOIN has no ON clause to carry that predicate, so it " *
      "would be dropped and the join would match every row.\n  Move the predicate to " *
      "\e[4m\e[32m.filter(...)\e[0m, which is where a CROSS-joined CTE's correlation belongs " *
      "(#44, #424)."))
  end

  # --- Phase 2: emit JOIN SQL text in original order -------------------------
  for (idx, value) in enumerate(instruc.row_join)
    set_context!(instruc, :join)
    b_quoted = safe_table_identifier(value.b, instruc.connection)
    alias_b_quoted = quote_identifier(value.alias_b, instruc.connection)

    # #44: a CROSS-joined CTE (no join_field) has no key columns and no ON — the correlation is
    # supplied by the main query's F() filter(s) in WHERE. Emit it and move on. Phase 1c above has
    # already refused any entry here that picked up an ON predicate.
    if value isa CrossJoin
      push!(instruc.join, """ CROSS JOIN $b_quoted AS $alias_b_quoted """)
      continue
    end

    if value isa AnchorlessJoin
      # #45: anchor-less join — the ON clause is entirely the user's resolved extras (no equi-anchor).
      extras = get(on_clause_extras, idx, OnExtra[])
      if isempty(extras)
        # #435: two different causes reach this line, and they used to share one message that only
        # described the first. `row_join` still carries `on_conditions` — Phase 1b mutates only the
        # local `on_clause_extras` — so what the CALLER passed is still readable here, after
        # relocation has erased what the join is left holding. The same `!isempty` gate as Phase 1,
        # so the two cannot drift (#487).
        if !isempty(value.on_conditions)
          dest_idxs = get(relocated_to, idx, Int[])
          # Naming the destination is diagnosis, not a remedy: relocation targets are often joins
          # PormG built itself (`Tb_2`), and the caller cannot address those. So the message reports
          # where the predicates went, and every remedy it offers is written in terms the caller
          # CAN act on — their own alias, or `.filter(...)`.
          dests = [instruc.row_join[d].alias_b for d in dest_idxs]
          where_to = isempty(dests) ? "another join" :
                     join(("\e[4m\e[31m$d\e[0m" for d in dests), ", ", " and ")
          alias = value.alias_b

          # A destination that is itself a `cjoin_on` has NO path to project — `values("b2…")` is
          # not a thing — so "project it in values(...)" is unactionable there. The actionable move
          # is the opposite one: declare the predicate on the join PormG emits LATER, which turns
          # the forward reference into a backward one. Found in review: the self-ref remedy was
          # written for a model-path destination and asserted at both.
          projectable = filter(d -> !(instruc.row_join[d] isa AnchorlessJoin), dest_idxs)
          plural = length(projectable) > 1 ? "those paths" : "that path"
          reorder = [instruc.row_join[d].alias_b
                     for d in dest_idxs if instruc.row_join[d] isa AnchorlessJoin]

          self_ref_remedy =
            "Your predicate does correlate \e[4m\e[31m$alias\e[0m; it moved only because the " *
            "join on its other side is built later."
          if !isempty(projectable)
            self_ref_remedy *= " Project $plural in \e[4m\e[32mvalues(...)\e[0m so it is built " *
              "FIRST"
            # Only promise "nothing relocates" when projecting is the WHOLE fix. With a mixed set
            # of destinations the other predicate still moves, and claiming otherwise contradicts
            # the very next sentence.
            self_ref_remedy *= isempty(reorder) ?
              " — then nothing relocates and the ON clause renders as you wrote it." :
              (length(projectable) > 1 ? " — then those predicates stay." :
                                         " — then that predicate stays.")
          end
          if !isempty(reorder)
            others = join(("\e[4m\e[31m$d\e[0m" for d in reorder), ", ", " and ")
            # "Declare it on the other join" alone is a dead end: this branch fires only when the
            # relocated predicates were ALL of them, so moving them out leaves this `cjoin_on` with
            # an empty `on`, which `_cjoin_on` refuses — and simply dropping the call makes its
            # alias unresolvable in the predicate that referenced it. The rewrite needs a predicate
            # for THIS join too, and saying so is the difference between advice and a dead end.
            # (Round 2 fixed the same omission in the `.filter(...)` remedy; it came back here.)
            self_ref_remedy *= " $others is another \e[4m\e[32mcjoin_on\e[0m, so there is no path " *
              "to project — declare this predicate on $others instead, which PormG emits after " *
              "\e[4m\e[31m$alias\e[0m, so the reference points backwards and nothing moves. Give " *
              "\e[4m\e[31m$alias\e[0m an ON predicate of its own as well: it is still joined, and " *
              "\e[4m\e[32mcjoin_on\e[0m requires at least one."
          end

          remedy = idx in relocated_self_ref ? self_ref_remedy :
            ("No predicate you gave names \e[4m\e[31m$alias\e[0m at all, so there is nothing to " *
             "correlate it. Add one — for example " *
             "\e[4m\e[32mJoined(\"$alias\", \"<column>\") == F(\"<base column>\")\e[0m — or, if none of " *
             "these conditions was ever about this join, move them to " *
             "\e[4m\e[32m.filter(...)\e[0m and drop the \e[4m\e[32mcjoin_on\e[0m entirely.\n  " *
             # #448 changed the tail of this sentence, and the change is the point: projecting used
             # to RENDER the unconstrained join, which is why this warned so heavily. It is now
             # refused, so the advice stands but the consequence is a second error rather than
             # silent wrong rows. Do not restore the old wording — it describes behavior that no
             # longer exists.
             "Do NOT instead project the path in \e[4m\e[32mvalues(...)\e[0m: that stops the " *
             "relocation, but the ON clause then never mentions \e[4m\e[31m$alias\e[0m, and an " *
             "unconstrained join is refused in its own right (#448).")
          throw(QueryBuildError(
            "Every ON predicate given for \e[4m\e[31m$alias\e[0m resolved onto $where_to instead, " *
            "leaving this join with no ON clause of its own.\n  A \e[4m\e[32mcjoin_on\e[0m " *
            "predicate is moved onto the LAST join it references, because joins are emitted in " *
            "order and a predicate cannot name an alias that has not appeared yet. Here that is " *
            "every predicate you gave, so nothing is left to constrain \e[4m\e[31m$alias\e[0m " *
            "itself.\n  $remedy (#435)."))
        end
        throw(QueryBuildError("cjoin_on produced no ON conditions for alias '$(value.alias_b)'."))
      end
      on_clause = join((e.sql for e in extras), " AND ")

      # #448: having an ON clause is not the same as being CONSTRAINED by one. The check above only
      # asks whether anything SURVIVED relocation; a predicate list that names this join nowhere —
      # `on = ["note" => "Z"]`, or a path already built by `values(...)` so nothing relocated —
      # passes it and renders a well-formed, unconstrained join. Every row of the joined table pairs
      # with every matched base row, silently: the #44 Cartesian warning covers CROSS entries only.
      #
      # Same trailing-dot form as Phase 1b's relocation test (:550-567) and Phase 1's base remap, for
      # the same reason spelled out there: every reference renders as `"alias"."col"`, so a bare
      # alias test also matches the COLUMN half, and an alias sharing a column's name would look
      # constrained when it is not.
      #
      # Fail closed rather than warn, matching #424 and #435 next door. Stricter than SQLAlchemy,
      # Ecto and jOOQ, which all emit an unconstrained join without complaint; Django never has the
      # question because it exposes no arbitrary ON clause. Deliberate: a silently row-multiplied
      # result is the worst failure mode here, and there is an escape hatch.
      #
      # That escape hatch is an unkeyed `.with(...)` that is REFERENCED — `values("x" => CTE(n, c))`
      # — which is what the message points at. NOT `.with(...)` + `.filter(...)`, which an earlier
      # draft of this comment and of the message both claimed: since #444 a CTE is joined only when
      # referenced, so that spelling emits no join at all (measured: JOIN COUNT 0) and silently
      # returns N rows instead of N×M — the inverse of the bug this guard exists for.
      if !occursin("$alias_b_quoted.", on_clause)
        throw(QueryBuildError(
          "The ON clause built for \e[4m\e[31m$(value.alias_b)\e[0m never references " *
          "\e[4m\e[31m$(value.alias_b)\e[0m, so the join is not constrained by it: every " *
          "\e[4m\e[31m$(value.b)\e[0m row would pair with every matched base row.\n  " *
          "This is not #435's case: there, EVERY predicate was relocated onto another join and this " *
          "one was left with no ON clause at all. Here it has one — some of what you gave may well " *
          "have relocated, but what remains never names this alias.\n  Give it a predicate naming its " *
          "own alias, e.g. \e[4m\e[32mF(\"$(value.alias_b).<column>\") == F(\"<base column>\")\e[0m. " *
          "If the conditions were never about this join, move them to " *
          "\e[4m\e[32m.filter(...)\e[0m and drop the \e[4m\e[32mcjoin_on\e[0m; if you " *
          "genuinely want a cross product, declare the table as an unkeyed " *
          "\e[4m\e[32m.with(\"n\" => sub)\e[0m and REFERENCE it — e.g. " *
          "\e[4m\e[32mvalues(\"x\" => CTE(\"n\", \"col\"))\e[0m — which emits a real " *
          "\e[4m\e[32mCROSS JOIN\e[0m and warns that it is Cartesian (#44, #448)."))
      end

      for extra in extras
        reattach_parameters!(instruc, extra.params)   # #421: bind in EMISSION order
      end
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

      # Build base ON clause
      on_clause = "$alias_a_quoted.$key_a_quoted = $alias_b_quoted.$key_b_quoted"

      # Append pre-resolved ON condition fragments, re-binding each as it is emitted (#421). This
      # loop runs in `row_join` order across joins and in vector order within one, which is exactly
      # the order the rendered `?` markers appear in; nothing else in Phase 2 touches the bucket.
      if haskey(on_clause_extras, idx)
        for extra in on_clause_extras[idx]
          on_clause *= " AND $(extra.sql)"
          reattach_parameters!(instruc, extra.params)
        end
      end
    end

    push!(instruc.join, """ $(value.how) JOIN $b_quoted AS $alias_b_quoted ON $on_clause """)
  end
end

function build(object::SQLObject;
  table_alias::Union{Nothing,SQLTableAlias}=nothing,
  connection::Union{Nothing,PormGPostgres,PormGSQLite}=nothing,
  parameters::Union{Nothing,AbstractPormGParam}=nothing,
  set_contexts::Bool=true,
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

  # Switch context for each SQL section so positional-parameter backends
  # (SQLite) push values into the correct bucket.
  # Subqueries skip this to inherit the parent's current bucket.
  set_contexts && set_context!(instruct, :select)
  get_select_query(object.values, instruct)
  _record_wildcard_projection_kinds!(instruct)

  set_contexts && set_context!(instruct, :where)
  get_filter_query(object, instruct)

  # #404: ORDER BY resolves HERE, before build_row_join_sql_text renders row_join into SQL. A path
  # named ONLY by order_by() is resolved through _get_select_query → _build_row_join, which APPENDS
  # to row_join; running after the render left that entry un-emitted, so the ORDER BY referenced an
  # alias the query never joined — a loud failure on both backends ("missing FROM-clause entry" /
  # "no such column"). Ordering a path that is also projected or filtered was always fine: it takes
  # the instruc.cache branch and discovers nothing.
  #
  # Only the position relative to the RENDER matters for CORRECTNESS. Whether this sits before or
  # after the cjoin loops below is immaterial there — build_row_join_sql_text keys its
  # forward-reference relocation on row_join index order, not on when an entry was appended. It is
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
  # PostgreSQL numbers `$N` at render and was always right. `:where` is restored after, so the cjoin
  # loops below keep running under it. In a SUBQUERY (set_contexts=false) both switches are skipped
  # and the term inherits the parent's bucket — unreachable from the public surface, because every
  # nested render passes `own_contexts=true` (#432), and the `:order` values it files are lifted
  # into text order by `detach_nested_run!` like any other clause.
  set_contexts && set_context!(instruct, :order)
  get_order_query(object, instruct)
  set_contexts && set_context!(instruct, :where)
  _group_window_terms!(instruct)   # #789: after ORDER BY, which also extends GROUP BY

  # PATH loop — materialize `cjoin` joins that traversal did not already discover. This ensures
  # cjoin filters are applied even in UPDATE/DELETE without explicit field paths. `row_path` is the
  # membership test that avoids materializing one twice; an `on()`-only entry has no `field` to link
  # through and decorates whatever join traversal built for that path.
  for (path, config) in object.custom_join
    if path ∉ instruct.row_path && config.field !== nothing
      array = split(path, "__")
      push!(array, config.field.pk_field)
      _build_row_join(array, instruct)
    end
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
  for (user_alias, config) in object.alias_join
    _build_cjoin_on_row_join(config, user_alias, instruct)
  end

  set_contexts && set_context!(instruct, :join)
  build_row_join_sql_text(instruct)

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
function _check_grouped_correlation(instruct::SQLInstruction)
  instruct.aggregate || return nothing        # no aggregate ⇒ one output row per input row ⇒ safe
  isempty(instruct.outer_refs) && return nothing
  grouped = _grouped_expressions(instruct)
  for c in instruct.outer_refs
    c.expr in grouped && continue
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

# The path key a transform is matched on: `"born__@year"` and the `_as` a `values("born__@year")`
# projection carries (`"born__year"`) are one key.
_mixed_path_key(path::AbstractString)::String = replace(String(path), "__@" => "__")

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
  # `values("born__@year")` arrives as `SQLField(EXTRACT(born), _as = "born__year")`, and
  # `values(Joined("d", "seen__@year"))` as `SQLField(EXTRACT(Joined("d", "seen")), _as =
  # "d__seen__year")`. An alias cannot carry `__` (#757), so a `__` in `_as` is always the path.
  if f isa FObject && !f.aggregate && v._as isa AbstractString && occursin("__", v._as)
    return _reads_joined(f) ? string("joined:", v._as) : String(v._as)
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
