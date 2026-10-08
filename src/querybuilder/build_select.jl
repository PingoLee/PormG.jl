# Rendering the SELECT list and ORDER BY (#130): `get_select_query`, the projection kinds and
# output names it records, and `get_order_query` with its NULLS placement. `build` (in
# `build_query.jl`) calls both; the types a projection renders are `projection_types.jl`'s.

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
# #965 — the kind a model FIELD's values are READ as: its canonical kind, or `CBool` for a boolean.
# SQLite stores a boolean as 0/1 and its driver hands back the integer, while PostgreSQL's hands back a
# `Bool`; `value_parser(::CBool, ::PormGSQLite)` turns the one into the other. Read path only: the
# boolean stays out of `field_canonical_kind`, because that table also feeds the comparison binder and
# the CTE kind records (#882's reason), and none of them has a boolean representation to undo.
function _field_read_kind(f::PormGField)::Union{CanonicalType,Nothing}
  kind = field_canonical_kind(f)
  kind === nothing && f.formatter === Models.format_bool_sql && return CBool()
  return kind
end

# #979 — the read kind of a projection the memo can stand for: a path, a `Joined`/`CTE` handle, an
# outer reference (the `memo_node` gate in `get_select_query`). Asked AFTER the column resolved, so
# it is the same answer whether this projection rendered it or reused the entry an earlier render
# left under its name — a `When("finished" => true, …)` condition renders the bare column there.
# A path takes its column's unnarrowed kind (`_projection_column_kind`, not the arithmetic-narrowed
# `_operand_column_kind`: a `TimeField` or `DurationField` has a representation to undo even though
# neither can be the left of date arithmetic); a handle reads as `Max` over it does (#824). A
# boolean column reads as a `Bool` (#965), as `_field_read_kind` types it for a wildcard read; a
# transformed path is the transform's result, not the column, so it keeps the kind it was given.
function _memo_node_read_kind(original, instruc::SQLInstruction)::Union{CanonicalType,Nothing}
  kind = original isa String ? _projection_column_kind(original, instruc) :
         original isa Union{JoinedReference,CTEReference} ? _operand_kind(original, instruc) : nothing
  kind === nothing && !(original isa AbstractString && occursin("__@", original)) &&
    _expression_formatter(original, instruc) === Models.format_bool_sql && (kind = CBool())
  return kind
end

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
    kind = _field_read_kind(fmeta)
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
      # #979: the entry is not always an earlier PROJECTION's, whose kind is already recorded under
      # this name. A `When("finished" => true, …)` condition in an earlier projection renders the bare
      # column under the same key, and recording nothing here left the column reading raw on SQLite
      # (a 0/1 for a boolean, the stored text for a date). The memo already holds the resolution the
      # kind is read from, so the answer is the one the render branch gives.
      kind = _memo_node_read_kind(v_copy.field, instruc)
      kind === nothing || (instruc.projection_kinds[Symbol(_projection_output_name(cached))] = kind)
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
      # #932: the projection renders in the SELECT list's `:group` phase, under its own output name —
      # what the #194 message calls it. When the outer query groups by this projection's POSITION (the
      # push above, decided before the render), the whole expression is a GROUP BY key, so a correlated
      # subquery inside it is evaluated per input row to form the key and needs no grouped column.
      # Only while the position is TRUE: a `"*"` projection ahead of it expands to the model's columns
      # before the ordinals resolve, so `GROUP BY 3` would name some other column (review of #932).
      kind = with_scope(instruc; label = _projection_output_name(v_copy),
                        group_key = string(i) in instruc.group &&
                                    !any(_is_wildcard_projection, view(values, 1:i-1))) do
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
          # #965: a comparison is a boolean (`_expression_formatter` has typed it so since #949), and so
          # is a bare boolean `F`. On SQLite the 0/1 it evaluates to reads back as a `Bool` only when the
          # projection says so. The kind is recorded here, never returned by `_render_expr_typed`, whose
          # kind is the comparison binder's `left_kind`.
          kind === nothing && _expression_formatter(original, instruc) === Models.format_bool_sql && (kind = CBool())
        else
          # #894: `Max`/`Min` over an interval are computed on SQLite milliseconds and leave as the
          # interval text — the second door #881 describes, and typed the way a difference is, on
          # both engines. `_operand_kind` cannot type `Max(F("start_at") - F("date"))` (arithmetic
          # answers `nothing`), so the kind is taken from the same call that renders, as above.
          interval = false
          if _is_fts_node(original, "SEARCH_VECTOR")
            # #1021: a `SearchVector` may be projected under a name — what `"doc__@search"` filters on,
            # Django's annotate-then-filter — and reads as its `tsvector` text. Only HERE, at the top
            # of the SELECT list, past `_check_fts_render`: wrapped, compared or ordered by, it is still
            # refused, because every other site renders it through `_render_function_typed`.
            instruc.connection isa PormGSQLite && throw(Dialect.fts_capability_error("SearchVector"))
            v_copy.field = _render_fts_operand(original, instruc; _as = memo_name(v_copy))
          elseif original isa FObject
            # #1004: the memo NAME, not the output name. A transform's `_as` (`raceid__year`) spells
            # the related path, and the column render below refreshes the field memo under whatever
            # it is handed — so `_as` filed the FK's own field under the path to the race's `year`.
            sql, interval_ms, interval = _render_function_typed(original, instruc; _as = memo_name(v_copy))
            v_copy.field = interval_ms ? Dialect._sqlite_interval_text(sql) : sql
          else
            v_copy.field = _get_select_query(original, instruc, _as=memo_name(v_copy))   # #1004, as above
          end
          # Render first (above), THEN type — the memo ordering `_render_left_typed` documents. A
          # dotted join key cannot be typed before it has been resolved.
          if memo_node
            # A path or a `Joined(...)` / `CTE(...)` handle (a `"cte__col"` path is retagged to one
            # before this loop). One rule, shared with the reuse branch above (#979).
            kind = _memo_node_read_kind(original, instruc)
          else
            # #800: an extremum or a window value function has its operand's kind.
            original isa SQLTypeFunction &&
              (kind = interval ? CInterval() : _function_projection_kind(original, instruc))
            # #888: a `Subquery(...)` reads as its one column — rendered above, which is what
            # recorded its kind.
            original isa SubqueryObject && (kind = _operand_kind(original, instruc))
            # #965: a boolean value (a `Subquery` of one, an `Exists`) reads as a `Bool`. A function
            # has answered already, through `_function_projection_kind`, whose rule for one is
            # stricter than its formatter's (`_is_boolean_valued`).
            kind === nothing && !(original isa SQLTypeFunction) &&
              _expression_formatter(original, instruc) === Models.format_bool_sql && (kind = CBool())
          end
        end
        kind
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
      # above records under the same name, by the same rule (#979).
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
  nulls === nothing || throw(QueryBuildError("Invalid nulls placement $(repr(nulls)); use :first or :last"))  # refusal-value-ok: an order_by keyword argument
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
# base-model `raceid__@year` term share the `_as` text `raceid__year` and differ in both halves —
# the namespace (#474) and, since #1004, the name, whose `@` a transform keeps. For a field-path or
# transform projection the name half is the PATH as written (the chosen name lives in `custom_as`),
# so `values("q" => "date__@yyyy_q")` answers `"q"` for an `order_by("date__@yyyy_q")` term, and
# for nothing spelled `date__yyyy_q`.
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

# #1004 — is this term a transform (`"raceid__@year"`), whose memo name keeps the `@` its output name
# drops?
_is_transform_term(v::SQLField) = memo_name(v) != v._as

# #1004 — does `path` walk relations from the query's model to a real column? `"raceid__year"` does
# (the race's `year`); `"date__day"`, a transform's output name, does not. A pure walk: `_build_row_join`
# would answer too, but it APPENDS the join it resolves, and asking must not change the statement.
function _path_names_related_column(q::SQLObject, path::AbstractString)::Bool
  segs = split(path, "__")
  length(segs) > 1 || return false
  model = q.model
  for (i, seg) in enumerate(view(segs, 1:length(segs)-1))
    step = _relation_step(q, model, seg, i == 1)
    step === nothing && return false
    model = step[2]
  end
  return String(segs[end]) in model.field_names
end

function _refuse_order_alias_collision(path::String, projection)
  throw(AmbiguousFieldError(
    "\e[4m\e[31morder_by(\"$(path)\")\e[0m is ambiguous: \e[4m\e[31m$(path)\e[0m is the path to " *
    "a related column and also the name PormG gave the projection " *
    "\e[4m\e[31mvalues($(_projection_spelling(projection)))\e[0m, so the ordering has two meanings " *
    "and PormG will not choose one.\n  " *
    "Write \e[4m\e[32morder_by($(_describe_projection(projection)))\e[0m for the projection, or " *
    "name it — \e[4m\e[32mvalues($(_renamed_projection_spelling(path, projection)))\e[0m — and " *
    "\e[4m\e[32morder_by(\"$(path)\")\e[0m then means the column (#1004)."))
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
      # #1004: a GENERATED name can be one spelling of two things. `values("raceid__@year")` is output
      # as `raceid__year`, which is also the path to the related race's `year`, and the term here
      # matched on that name alone. Only a name nobody chose can collide (a chosen one is
      # `custom_as`), and only when the memo keys differ — the same key is the same expression.
      if value.custom_as === nothing && memo_key(value) != memo_key(v_field_copy)
        # A term that is not a plain path names its expression outright, so it is not the projection
        # that happens to share its output name: `values("raceid__year"); order_by("raceid__@year")`
        # matched the COLUMN and sorted by it, and `order_by(Joined("raceid", "year"))` beside it
        # sorted by the foreign key's column instead of the joined copy's. Rendered afresh below
        # instead — or matched by key through `_projected_output_name`.
        (_is_transform_term(v_field_copy) || !(v_field_copy.field isa String)) && continue
        # A plain path that reaches a related column, matched against a TRANSFORM's generated name,
        # means that column as much as it names the projection: refused, as #703 refuses the filter.
        # One that reaches nothing keeps the alias — `values("date__@day"); order_by("date__day")` is
        # documented and integration-tested. (A joined copy named after its foreign key reaches this
        # point too — the #484 shape — and keeps ordering by the copy, as it always has; #1004 is
        # about the transform's name.) The DECLARED projection is what the message spells:
        # `instruc.select[i]` holds it rendered, and `get_select_query` fills the two index for index.
        declared = object.values[i]
        declared isa SQLField && _is_transform_term(declared) &&
          _path_names_related_column(object, v_field_copy.field) &&
          _refuse_order_alias_collision(v_field_copy.field, declared)
      end

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
      # #932: a term rendered here is not projected, so it is pushed into GROUP BY whole below
      # (`push!(instruc.group, v_field_copy.field)`) — a GROUP BY key, like a grouped projection.
      # Not when it holds an aggregate or a window: neither is a valid grouping key (both engines
      # reject the statement), so the term keeps the clause's checked phase (review of #932). Resolved,
      # so an aggregate read through an alias (`When("n__@gt" => 1, …)` over `"n" => Count(…)`) counts.
      order_node = v_field_copy.field
      v_field_copy.field = with_scope(() -> _get_select_query(order_node, instruc), instruc;
                                      group_key = !_resolved_contains_agg(order_node, instruc) && !_is_window_expr(order_node))
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
    # (`filter_nodes.jl`) and can write this very key as it goes — so any read taken before the
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
