# Rendering the specialised lookup operators (#130): JSON paths and operators, network (`inet`)
# operators, array operators, and the sargable rewrite of a date-bucket filter (`@yyyy_mm`,
# `@year`, …) into a range on the column.

# Coerce a JSON numeric-comparison RHS to an actual Julia number, so BOTH dialects compare
# numerically (PostgreSQL casts the extracted text `::numeric`; SQLite's json_extract returns a
# native number). Binding a string here would make SQLite compare number-vs-text and silently
# invert every comparison.
#
# #988: the RHS is bound, so a refusal is an `InvalidValueError` with the reason alone; the caller
# locates it through `_locate_filter_refusal`, as a formatter refusal is.
function _json_numeric_rhs(value)
  value isa Bool && return Int(value)
  value isa Integer && return value
  value isa AbstractFloat && return value
  s = strip(string(value))
  # Base 10 only, as on every other numeric path (#773): the bare parsers read `"0x10"` as 16.
  Models.is_base10_number(s) ||
    throw(InvalidValueError("A numeric JSON comparison requires a base-10 number", :format))
  n = tryparse(Int, s); n !== nothing && return n
  f = tryparse(Float64, s); (f !== nothing && isfinite(f)) && return f
  # Base-10 text that overflows `Float64` (`"1e400"`) parses to `Inf`: refused rather than bound as a
  # value the caller never wrote. (A `Float64` the caller passes, `Inf` included, binds as it is.)
  throw(InvalidValueError("A numeric JSON comparison requires a finite number", :range))
end

# #27: render a comparison against a JSON path lookup (e.g. `payload__driver`). The RHS binds
# dialect-aware — NOT through the JSON field's formatter (which would reject a plain string like
# "hamilton"):
#   - PostgreSQL `#>>` always yields TEXT, so equality binds text and `<`/`>` cast the LHS
#     `::numeric`.
#   - SQLite `json_extract` returns the value's NATIVE type, so equality binds the raw Julia value
#     (a JSON number stays a number → `5 = 5`, not `5 = '5'`) and comparisons need no cast.
function _render_json_lookup_comparison(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  op = v.operator
  # #596: a JSON path lookup (`payload__kind`) is a bare path, so admitting a flat `Vector{UInt8}` at
  # parse made it reachable here — and this is the one arm where it was SILENT: the PostgreSQL branch
  # does `string(v.values)`, which stringified the payload's Julia `repr` into
  # `#>> '{"kind"}' = 'UInt8[0x01, 0x02]'` — valid SQL, zero rows, no error. A JSON value is never a
  # byte payload, so the refusal is unconditional.
  _guard_vector_equality(v, nothing)
  # #811: the same silent arm, reached by a column expression. `"payload__kind" => F("grid")` bound
  # the `FExpression`'s `repr` as text on PostgreSQL — zero rows, no error — while SQLite refused it as
  # an unbindable value. Comparing extracted JSON against a column needs a per-engine cast nobody has
  # designed, so it is refused on both engines. It has to be here, not at parse: whether a path is a
  # JSON path is only known once its column resolves. `@isnull` never gets this far (#808's parse check).
  v.values isa SQLType && throw(FilterError(
    "Error in filter '$(_filter_path_label(v))': a JSON path lookup compares the extracted value " *
    "against a value, not a column expression"))
  is_pg = instruc.connection isa PormGPostgres
  if op == "ISNULL"
    # Render IS NULL directly — the shared ISNULL() rejects any column containing "(", which a
    # legitimate SQLite json_extract(...) expression trips.
    return string(column, v.values == true ? " IS NULL" : " IS NOT NULL")
  elseif op in ("=", "!=", "<>")
    # PG: bind text (LHS is text). SQLite: bind the native value (LHS keeps its JSON type).
    ph = add_parameter!(instruc, is_pg ? string(v.values) : v.values)
    return string(column, " ", op, " ", ph)
  elseif op in (">", ">=", "<", "<=")
    lhs = is_pg ? "($(column))::numeric" : column
    rhs = try
      _json_numeric_rhs(v.values)
    catch e
      _locate_filter_refusal(e, _filter_path_label(v), nothing)
    end
    ph = add_parameter!(instruc, rhs)
    return string(lhs, " ", op, " ", ph)
  else
    throw(FilterError("The operator \e[31m$(op)\e[0m is not supported on a JSON path lookup. Use =, !=, <, <=, >, >=, or __@isnull."))
  end
end

# #27: render a JSONB containment/overlap operator (@>, ?, ?|, ?&). The LHS must be a JSON COLUMN
# (terminal), not a nested key path. Binds the RHS per operator (jsonb document / text key /
# text[] key array) and dispatches to the per-dialect Dialect renderer (PG emits the operator;
# SQLite throws PG-only).
function _render_json_operator(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  col_as = isa(v.column, SQLTypeField) ? v.column._as : nothing
  # #474: the memo is keyed by namespace, the MESSAGE by what the caller wrote.
  col_key = isa(v.column, SQLTypeField) ? memo_key(v.column) : nothing
  if memo_json_lookup(instruc, col_key)
    throw(FilterError("The \e[31m@$(v.operator)\e[0m operator applies to a JSON column, not a nested key path (\e[31m$(col_as)\e[0m); this is not supported in v1."))
  end
  base = _resolve_json_operator_field(v, instruc)
  (base !== nothing && Models.is_json_field(base)) ||
    throw(FilterError("The \e[31m@$(v.operator)\e[0m operator requires a JSONField column; \e[31m$(something(col_as, "the target"))\e[0m is not JSON."))
  op = v.operator
  ph = if op == "jcontains"
    add_parameter!(instruc, Models.format_json_sql(v.values); sql_type="jsonb")
  elseif op == "has_key"
    add_parameter!(instruc, string(v.values))
  else  # has_any_keys / has_keys
    v.values isa AbstractVector ||
      throw(FilterError("The \e[31m@$(op)\e[0m operator requires an array of keys, e.g. filter(\"col__@$(op)\" => [\"a\", \"b\"]); got a single value."))
    add_parameter!(instruc, String.(v.values); sql_type="text[]")
  end
  return getfield(Dialect, Symbol(op))(instruc.connection, column, ph)
end

# #904: render a PostgreSQL network operator (`<<`, `<<=`, `>>`, `>>=`, `&&`, `family()`,
# `masklen()`). The left-hand side must be a `GenericIPAddressField` or `CIDRField` column — the
# model's own or a joined path's terminal field — which is the same evidence a pattern lookup reads
# (`_pattern_text_kind`). A projection alias never gets here from a filter
# (`_ALIAS_UNSUPPORTED_OPERATORS`), and a `When` condition on one has no field, so it is refused below.
#
# The containment operand binds through `format_inet_network_sql`, not the column's own formatter: it
# is a network, which `format_inet_sql` refuses, and its host bits may be set, which `format_cidr_sql`
# refuses. It binds typed (`::inet`), because `<<` is ambiguous on an untyped parameter; a `cidr` column
# meets it through PostgreSQL's implicit `cidr → inet` cast. A column on the right (`F`, a CTE or a
# joined column) is compared as it is, uncast. Any other expression is refused: none was asked for, and
# an unvalidated one would fail at the server instead.
function _render_network_operator(v::SQLTypeOper, column::String, operand_field, field_label::AbstractString,
                                  instruc::SQLInstruction)::String
  op = v.operator
  # The path the caller wrote, for the messages. Without a field it is a projection alias (reached
  # through a `When` condition) or a transform (`happened__@year`). A transform node keeps neither the
  # caller's `@year` spelling nor a path to quote, so its refusal names the column it transforms and
  # quotes no path, rather than one the caller never wrote or the SQL it renders.
  label, subject = if operand_field !== nothing
    field_label, field_label
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, AbstractString)
    v.column.field, v.column.field
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) &&
         isa(v.column.field.column, AbstractString)
    nothing, "$(v.column.field.column), under a transform,"
  else
    column, column
  end
  where_ = label === nothing ? "Error in filter" : "Error in filter '$(label)__@$(op)'"
  (operand_field !== nothing && _pattern_text_kind(operand_field.formatter) in (:inet, :cidr)) ||
    throw(FilterError("$(where_): the @$(op) lookup requires a GenericIPAddressField " *
                      "or CIDRField column, and $(subject) is not one."))
  lookup = "$(label)__@$(op)"
  ph = if isa(v.values, Union{SQLTypeF,SQLTypeCTE,SQLTypeJoined})
    _on_join_right(() -> _get_filter_query(v.values, instruc), instruc)   # #985: the right side
  elseif isa(v.values, Union{SQLType,SubqueryObject,SQLObjectHandler})
    throw(FilterError("Error in filter '$(lookup)': the @$(op) lookup takes a value or a column " *
                      "(F(\"…\")), not this expression."))
  elseif op in NETWORK_CONTAINMENT_OPERATORS
    add_parameter!(instruc, _guarded_format(Models.format_inet_network_sql, v.values, op, label,
                                            operand_field.type); sql_type = "inet")
  else  # family / prefixlen
    # #988: the value is bound, so a refusal is an `InvalidValueError`, located like a formatter's.
    # A `Bool` is an `Integer` in Julia, and `true` is not a family (#949's reasoning).
    allowed, what = op == "family" ? ((4, 6), "4 or 6") : (0:128, "a whole number from 0 to 128")
    kind = !(v.values isa Integer) || v.values isa Bool ? :type :
           v.values in allowed ? nothing : :range
    kind === nothing ||
      throw(with_location(InvalidValueError("The @$(op) lookup takes $(what)", kind);
                          op = "filter", field = label, field_type = _opt_label(operand_field.type)))
    add_parameter!(instruc, Int(v.values))
  end
  return getfield(Dialect, Symbol(op))(instruc.connection, column, ph)
end

# Resolve the base PormGField a JSON operator targets: a bare column name lives on the model;
# an FK-reached terminal JSON column was cached in tab_field_cache when `column` resolved.
function _resolve_json_operator_field(v::SQLTypeOper, instruc::SQLInstruction)
  isa(v.column, SQLTypeField) || return nothing
  fld = v.column.field
  if fld isa String && !contains(fld, "__")
    return get(instruc.object.model.fields, fld, nothing)
  end
  # #474: the memo key, like every other `tab_field_cache` reader. Missing this one made a JSONB
  # containment operator over a CTE column — `filter(CTE("evc", "payload__@has_key") => "driver")` —
  # miss the entry `_build_row_join` had just written under the namespaced key and fail closed with
  # "evc__payload is not JSON", a shape that rendered before #474. The mirror hazard is worse: with
  # a base-model path spelled the same, the un-namespaced lookup could return the OTHER namespace's
  # field and license a jsonb operator against a CTE's text column.
  return memo_field(instruc, memo_key(v.column))
end

# #28: render an array containment/overlap lookup (`@acontains` @>, `@contained_by` <@, `@overlap` &&)
# on an `ArrayField` column — a bare one, one reached through a ForeignKey or a CTE, or a slice
# (`tags__0_2`), whose memo entry is the array field itself. Read AFTER `column` renders, which is
# what fills the memo for a joined path.
#
# The value goes through the column's `ArrayFormatter`, so every element is checked and converted by
# the ELEMENT field's own formatter and the whole list binds as ONE array literal — exactly what an
# equality binds — but with the field's `size` lifted: `size` bounds what the column may STORE, and
# `@contained_by`/`@overlap` legitimately ask about a longer list (`"tyre_compounds__@contained_by"
# => [all five compounds]` against a `size = 3` column). No cast: the operators are polymorphic, so
# the server types the parameter from the column, as it does for `=` (measured on both drivers).
function _render_array_operator(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  field, _ = _operand_field(v, instruc)
  (field !== nothing && _is_array_field(field)) ||
    throw(FilterError("The \e[31m@$(v.operator)\e[0m lookup requires an ArrayField column; " *
                      "\e[31m$(_array_lookup_label(v))\e[0m is not one."))
  # The parse ladder admits only a vector here (`_check_fixed_shape_lookup` refuses a scalar, and
  # `_check_column_rhs_lookup` a column); this is the fail-safe for a spelling that bypasses it.
  v.values isa AbstractVector ||
    throw(FilterError("The \e[31m@$(v.operator)\e[0m lookup takes a list of elements."))
  formatter = field.formatter::Models.ArrayFormatter
  unbounded = Models.ArrayFormatter(formatter.base, formatter.kind, nothing)
  literal = _guarded_format(unbounded, v.values, v.operator, _array_lookup_label(v), field.type)
  placeholder = add_parameter!(instruc, literal)
  return getfield(Dialect, Symbol(v.operator))(instruc.connection, column, placeholder)
end

# #31: render the `@search` lookup — `to_tsvector(<config>, col) @@ <tsquery>` — on a text column: a
# bare one, or one reached through a ForeignKey or a CTE (read after `column` renders, as the array
# lookups are). The value is the search text, parsed as a plain `SearchQuery` with no config as in
# Django, or a `SearchQuery`, whose config the column is parsed with too.
#
# #1021: a `SearchVectorField` column is already a document, so it is searched as it is — `col @@
# query`, no `to_tsvector` — and the query's config applies to the query alone. That is the branch on
# `field.type` below. A config that differs from the one the column was filled with is the caller's to
# match, as in Django: the stored document does not say which it was built with.
function _render_search_operator(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  instruc.connection isa PormGSQLite && throw(Dialect.fts_capability_error("The @search lookup"))
  field, _ = _operand_field(v, instruc)
  (field !== nothing && field.type in ("VARCHAR", "TEXT", "TSVECTOR")) ||
    throw(FilterError("The \e[31m@search\e[0m lookup searches a text column (a CharField or " *
                      "TextField) or a SearchVectorField, and \e[31m$(_array_lookup_label(v))\e[0m is " *
                      "not one. To search several columns, or an expression, project a SearchVector and " *
                      "search its name: \e[4m\e[32mvalues(\"doc\" => SearchVector(…)).filter(\"doc__@search\" => …)\e[0m (#1021)."))
  # The parse ladder admits only these two (`_check_fixed_shape_lookup`); this is the fail-safe for a
  # spelling that bypasses it.
  query = v.values isa AbstractString ? SearchQuery(v.values) : v.values
  _is_fts_node(query, "SEARCH_QUERY") ||
    throw(FilterError("The \e[31m@search\e[0m lookup takes the search text or a SearchQuery(...) (#31)."))
  vector = field.type == "TSVECTOR" ? column : Dialect.ts_vector_sql(column, query.kwargs["config"], instruc.connection)
  rendered = _on_join_right(() -> _render_fts_operand(query, instruc), instruc)
  return Dialect.search(instruc.connection, vector, rendered)
end

# The path an array lookup names, for its messages: the field path the caller wrote, or the memo
# key's path for a joined or CTE column. `"this expression"` for an operand with neither (`@len`).
# The `@search` lookup's messages use it too (#31).
function _array_lookup_label(v::SQLTypeOper)::String
  c = v.column
  c isa SQLField && c.field isa String && return c.field
  k = c isa Union{SQLField,CTEReference,JoinedReference} ? memo_key(c) : nothing
  return k === nothing ? "this expression" : k[2]
end

# #352: sargable rewrite for `col__@yyyy_mm` / `col__@year` / `col__@date` comparisons.
#
# `to_char(col, 'YYYY-MM') <= $1` (and the EXTRACT(YEAR ...) equivalent) puts a function call on
# the indexed column: no index on `col` applies, and PostgreSQL cannot estimate selectivity
# through it (issue #352 measured a 193x row-count misestimate cascading into an 18+ minute plan).
# Rewritten as a plain comparison/range on the raw column:
#
#   @exact (bare `=`)  col >= F AND col < N
#   @gte               col >= F
#   @gt                col >= N
#   @lte               col < N
#   @lt                col < F
#
# where F = first day of the bucket period and N = first day of the following period. `@date`
# needs no range at all (F == the literal) since to_char at day granularity on a DATE column
# preserves chronological order exactly — the rewrite there is just "drop the to_char".
#
# #373 extended the rewrite to a JOINED path (`fk__col__@yyyy_mm`), which #352 had left out
# because the terminal field's TYPE — what the DATE-only gate below needs — is not readable off
# `instruc.object.model`. See `_resolve_bucket_column` for how that is answered.
#
# Scope:
#   - Only a plain DATE column (`_is_date_field`) — TIMESTAMPTZ/TIMESTAMP are excluded because
#     to_char renders in the session TimeZone, so naively computing F/N would shift the boundary
#     around midnight. Left on the existing rendering.
#   - Only a plain scalar RHS (String/Number) — an F()/subquery/Case RHS falls through unchanged.
#
# Returns the rendered SQL string, or `nothing` to fall through to the existing rendering.
function _render_sargable_date_range(v::SQLTypeOper, instruc::SQLInstruction)::Union{String,Nothing}
  isa(v.column, SQLTypeField) || return nothing
  fobj = v.column.field
  isa(fobj, FObject) || return nothing
  raw_field = fobj.column
  # #444: a CTE-scoped bucket column arrives as a handle rather than a `"<cte>__col"` string. It
  # must be admitted here or the rewrite silently stops firing for every CTE date filter — the exact
  # failure mode #376 describes two paragraphs down in `_resolve_bucket_column`, reached by a
  # different route. Measured against main by rendering both spellings: without this line
  # `filter(CTE("ev","seen__@yyyy_mm__@lte") => "1991-10")` degraded from `"seen" < '1991-11-01'`
  # back to `to_char("seen",'YYYY-MM') <= '1991-10'`.
  # #481: `JoinedReference` for the same reason, one namespace over.
  isa(raw_field, Union{String,CTEReference,JoinedReference}) || return nothing
  v.operator in ("=", ">=", ">", "<=", "<") || return nothing
  (v.values isa AbstractString || v.values isa Number) || return nothing

  # The bucket gate runs BEFORE the column is resolved: resolving a joined path renders its join,
  # and a non-bucket transform (`@month`, `@quarter`, …) must never reach that.
  bucket = if fobj.function_name == "EXTRACT_DATE" && get(fobj.kwargs, "format", nothing) == "YYYY-MM"
    :yyyy_mm
  elseif fobj.function_name == "DATE"
    # #562: `@date` used to be a `ToChar(x, "YYYY-MM-DD")`, i.e. an `EXTRACT_DATE` node carrying the
    # mask. It is now a named `DATE` function so the dialect can pick the per-engine spelling. This
    # arm moves with it, and it is load-bearing in a way no correctness test can see: on a plain
    # `DateField` the rewrite DROPS the transform entirely, so a stale marker here does not render
    # wrong SQL — it silently stops rewriting, the #376 failure mode.
    :date
  elseif fobj.function_name == "EXTRACT" && get(fobj.kwargs, "part", nothing) == "YEAR"
    :year
  else
    return nothing
  end

  f_meta, column_sql = _resolve_bucket_column(raw_field, instruc)
  f_meta === nothing && return nothing
  _is_date_field(f_meta) || return nothing                          # DATE only, not TIMESTAMP(TZ)

  # #576: this rewrite runs AHEAD of every branch in `_get_filter_query`, so for `@date` / `@yyyy_mm`
  # / `@year` on a plain `DateField` it — not the transform ladder — is what formats the user's
  # value, and it was the leak nobody had named. `raw_field` is the spelling the user wrote (a
  # String, or a `CTEReference`/`JoinedReference` that prints as one) and `f_meta` is the terminal
  # field, so both message labels are real here rather than synthesised.
  bind(x) = add_parameter!(instruc, _guarded_format(f_meta.formatter, x, "=", raw_field, f_meta.type))

  if bucket == :date
    # Same granularity as the column: no range, operator unchanged — just drop the to_char.
    # This `bind` is the only one handed the RAW value; the range arms below bind computed `Date`s.
    return string(column_sql, " ", v.operator, " ", bind(v.values))
  end

  # Both helpers refuse a value with an `InvalidValueError` carrying the reason alone — their own
  # checks since #988, and `Models.format_yyyy_mm`'s on a bad shape — and neither has a field to
  # name, so the location is attached here.
  first_of_period, next_period = try
    bucket == :yyyy_mm ? _yyyy_mm_bucket_bounds(v.values) : _year_bucket_bounds(v.values)
  catch e
    _locate_filter_refusal(e, raw_field, f_meta.type)
  end

  if v.operator == ">="
    return string(column_sql, " >= ", bind(first_of_period))
  elseif v.operator == ">"
    return string(column_sql, " >= ", bind(next_period))
  elseif v.operator == "<="
    return string(column_sql, " < ", bind(next_period))
  elseif v.operator == "<"
    return string(column_sql, " < ", bind(first_of_period))
  else # "="
    p1, p2 = bind(first_of_period), bind(next_period)
    return string("(", column_sql, " >= ", p1, " AND ", column_sql, " < ", p2, ")")
  end
end

# Terminal field metadata + rendered SQL for the column a date-bucket comparison targets, or
# `(nothing, "")` to fall through to the existing rendering.
#
# A bare column reads its metadata straight off the queried model. A JOINED path (#373) cannot:
# `FObject.column` still holds the unsplit dotted string at this point, and the terminal field only
# becomes knowable once the path has actually been walked. So the path is RENDERED first and the
# type read back out of `tab_field_cache`, which `_build_row_join` populates as it goes.
#
# Rendering first is the design, not a compromise. `_build_row_join` is the only authority on which
# model and field a dotted path resolves to — forward FK, reverse relation, many-to-many, and the
# `driver` → `driver_id` short-form rewrite whose ambiguity against a declared `related_name` is
# documented on `_resolve_fk_short_form`. Re-deriving that walk here would be a SECOND resolver able
# to disagree with the renderer, and a disagreement puts the date range on a different table's
# column with no error and wrong rows. Nothing is saved by not rendering, either: the rewritten
# predicate references the joined column, so the join is built either way.
#
# The early render is side-effect-free in every way that matters here: `build_joins.jl` binds no
# parameters, and `_insert_join` dedups on (a, b, key_a, key_b, alias_a) — so when the DATE gate
# rejects the field, the fall-through renders the same path again and gets the same alias back.
# Identical SQL, one extra traversal.
function _resolve_bucket_column(raw_field::String, instruc::SQLInstruction)
  if !contains(raw_field, "__")
    f_meta = get(instruc.object.model.fields, raw_field, nothing)
    f_meta === nothing && return (nothing, "")
    return _checked_bucket_column(f_meta, raw_field, _get_select_query(raw_field, instruc), instruc)
  end

  # A CTE-rooted reference now takes the `::CTEReference` method below (#444) rather than this
  # branch, but the reasoning that makes the DATE gate trustworthy over a CTE is the same and is
  # recorded here because it is not obvious.
  # A CTE model's column types are INFERRED (`_set_field_from_sql_function`, ctes.jl), so the
  # question is whether one can ever be typed DATE while the column holds something else. It cannot:
  # a plain-column projection reads the real field; COUNT/SUM yield IntegerField; CASE/WHEN route
  # through `_case_output_field`, which types a CASE as DATE only when every non-NULL branch is
  # itself a date column (#812) or `output_field` names `date`, which the SQL casts to a date on
  # both engines (`date(…)` on SQLite since #822, and for `Coalesce` & co. since #852);
  # MIN/MAX carry the base DateField and genuinely produce a date; and every OTHER function —
  # `ToChar` included, which is what would actually produce a "1991-10" text column — is rejected
  # outright when the CTE model is built unless it declares its type. So the DATE gate is as
  # trustworthy here as anywhere else.
  #
  # #376: the drift guard below still MATCHES on a CTE path. It matched before the fix too — both
  # sides read the SAME field object, so they agreed on the physical name and the rewrite was
  # applied to a column the CTE does not expose. What changed is WHICH name they agree on: the CTE
  # model's fields now carry no db_column (`Models.field_without_db_column`, applied in
  # `_build_cte_custom_model`), so `field_db_column(f_meta, <alias>)` and the rendered column both
  # answer the projection ALIAS. Resolving the alias at the REFERENCE site instead would have left
  # `f_meta` claiming the physical name while the render answered the alias — failing this guard
  # closed and silently dropping the #352/#373 rewrite for every CTE date-bucket filter, with no
  # other symptom. That is why the fix belongs at construction.
  column_sql = _get_select_query(raw_field, instruc)
  # #474: a String path reaching HERE is base-model. #492 restored `"<cte>__<col>"`, so that is no
  # longer true by construction — it is true because `_resolve_cte_string_paths!` (`ctes.jl`) has
  # already rewritten every CTE-rooted string into a `CTEReference` by the time `build()` renders
  # anything. Rewriting rather than gating is exactly what keeps this line correct: had the string
  # stayed a string and been resolved here, it would read `:base` while the join builder wrote
  # `:cte`, silently dropping the #352/#373 rewrite on one spelling only. Its CTE twin below asks
  # for the same entry under the other half of the namespace.
  f_meta = memo_field(instruc, memo_key(:base, raw_field))
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, String(last(split(raw_field, "__"))), column_sql, instruc)
end

# #444 — the CTE-handle twin of the joined-path branch above, and deliberately identical to it in
# every step: render first (only `_build_row_join` is authority on what a path resolves to), read
# the terminal field back out of `tab_field_cache`, then run the same drift guard. The cache key is
# `_cte_as(ref)` — `"<name>__<path>"` — which is precisely the key `_build_row_join` writes, because
# the segment vector it walks is the one the pre-#444 string produced. All the reasoning above about
# why the DATE gate can be trusted over a CTE (inferred column types, #376's db_column stripping)
# applies here unchanged.
function _resolve_bucket_column(ref::CTEReference, instruc::SQLInstruction)
  column_sql = _get_select_query(ref, instruc)
  f_meta = memo_field(instruc, memo_key(ref))   # #474: namespaced memo
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, String(last(split(ref.path, "__"))), column_sql, instruc)
end

# #481 — the joined-copy twin. `_resolve_joined` writes the memo entry as it renders, so the read
# below always hits; the same drift guard then applies.
function _resolve_bucket_column(ref::JoinedReference, instruc::SQLInstruction)
  column_sql = _get_select_query(ref, instruc)
  f_meta = memo_field(instruc, memo_key(ref))
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, ref.path, column_sql, instruc)
end

# Drift guard: the rewrite may only range on a column that IS the one `f_meta` describes. That holds
# by construction on every branch today — `_build_row_join` renders the terminal column through
# `_solve_field` and caches `last_field` from the same model and segment — which is precisely why it
# is worth pinning. If the correspondence ever breaks, the rewrite falls back to the existing
# (correct, merely non-sargable) rendering instead of quietly ranging on some other column.
# Fail-safe, never fail-loud: a mismatch is a PormG-internal invariant, not a user error.
function _checked_bucket_column(f_meta, last_segment::String, column_sql::String, instruc::SQLInstruction)
  expected = safe_column_identifier(Models.field_db_column(f_meta, last_segment), instruc.connection)
  endswith(column_sql, string(".", expected)) || return (nothing, "")
  return (f_meta, column_sql)
end

# Reuses Models.format_yyyy_mm for shape/type validation (String "YYYY-MM" regex, or 6-digit
# Integer YYYYMM), then parses the normalized string for range math. format_yyyy_mm does NOT
# validate the month is 01-12 (only the regex shape) — Dates.Date(y, m, 1) does, and its
# ArgumentError is caught and rethrown as an `InvalidValueError` so a bad month is not a bare
# Dates.jl exception.
#
# #988: every refusal in these three helpers is an `InvalidValueError`, because the value they check
# is bound. They used to raise `FilterError`, which made `"date" => "2026-13-45"` and
# `"date__@yyyy_mm" => "1991-13"` two error types for one failure: a bad value. `FilterError` is for
# what shapes the SQL — a lookup, an operator — and none of these does.
# A year outside 1..9999 cannot be expressed as a date bound: `Dates.Date` happily accepts year 0
# and negatives and stringifies them as "0000-01-01" / "-0005-01-01", which both backends reject at
# execution with an opaque server-side error — and `format_date_sql(::Date)` is a bare `string(...)`
# that validates nothing. Takes any `Real` so it can run before `Int(...)` narrowing.
function _check_year_bound(y::Real)
  (1 <= y <= 9999) || throw(InvalidValueError("The year is out of the range a date bound can express (1-9999)", :range))
  return nothing
end

function _yyyy_mm_bucket_bounds(value)::Tuple{Dates.Date,Dates.Date}
  normalized = Models.format_yyyy_mm(value)   # throws InvalidValueError on bad shape/type
  y = parse(Int, normalized[1:4])
  m = parse(Int, normalized[6:7])
  # The regex admits "0000-01", which would render the unusable "0000-01-01". Same bound as @year.
  _check_year_bound(y)
  try
    first_of_period = Dates.Date(y, m, 1)
    return first_of_period, first_of_period + Dates.Month(1)
  catch e
    throw(InvalidValueError("The value is not a valid YYYY-MM bucket: it is not a calendar month", :range))
  end
end

# Resolve `@year`'s RHS to a calendar year, accepting every value shape the pre-#352 rendering
# accepted via `Models.format_number_sql` — Integer, Decimal, and a whole-valued Float (an ETL
# app pulling a year out of a Float64 DataFrame column is the common case), plus a numeric
# String. Narrowing this would be a breaking change for consuming apps, not a tightening.
#
# What IS rejected, because the range rewrite cannot express it while `EXTRACT(YEAR ...)` could:
#   - Bool (`Bool <: Integer` in Julia; format_number_sql carries a ::Bool overload for exactly
#     this trap) — `false` would silently become year 0.
#   - a fractional year (1991.7) — no single date bound represents it.
#   - a year outside 1..9999 — `Dates.Date` accepts year 0 and negatives and renders them
#     "0000-01-01" / "-0005-01-01", which both backends reject at execution with an opaque
#     server-side error; `format_date_sql(::Date)` is a bare `string(...)` and validates nothing.
# The string branch parses base-10 explicitly: `tryparse(Int, "0x10")` returns 16 in Julia, so
# the default would silently accept a hex literal as a year.
function _year_bucket_bounds(value)::Tuple{Dates.Date,Dates.Date}
  # The range check runs BEFORE `Int(...)` narrowing on every numeric branch: `Int(big(10)^20)`
  # and `Int(1e30)` throw a raw `InexactError`, which is not a PormGError at all and whose message
  # never mentions a year filter. `isinteger(1e30)` is `true`, so the whole-year guard alone does
  # not stop it. Comparing first works on any Real — BigInt, BigFloat, Rational, Decimal.
  y = if value isa Bool
    throw(InvalidValueError("A __@year filter requires a year, not a Bool", :type))
  elseif value isa Integer
    _check_year_bound(value)
    Int(value)
  elseif value isa Real
    isinteger(value) || throw(InvalidValueError("The value is not a whole year for a __@year filter", :range))
    _check_year_bound(value)
    Int(value)
  elseif value isa AbstractString
    n = tryparse(Int, strip(value), base=10)
    n === nothing && throw(InvalidValueError("The value is not a valid year for a __@year filter", :format))
    _check_year_bound(n)
    n
  else
    throw(InvalidValueError("A __@year filter requires a year as an Integer, a whole Real, or a numeric String; got a $(typeof(value))", :type))
  end
  first_of_period = Dates.Date(y, 1, 1)
  return first_of_period, first_of_period + Dates.Year(1)
end
