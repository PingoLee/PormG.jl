# Turning a filter pair into an operator (#130): `"field__op" => value` parsed by the
# `_get_pair_to_oper` family and `_normalize_filter_pair`, the invalid-operator diagnostics with
# their did-you-mean suggestion (#98), the membership-subquery and boolean-condition guards, and
# `_check_filter`.

# ─────────────────────────────────────────────────────────────────────────────
# Invalid filter-operator diagnostics (#98)
#
# The scalar/function path (_check_function) already emits a rich "valid function
# / valid operator" message. The vector, subquery, and tuple value paths used to
# throw a terse message that neither listed the valid operators nor distinguished
# a typo (unknown operator, e.g. @notin) from a known operator that simply is not
# valid for that value shape (e.g. @gte with a vector). _raise_invalid_filter_operator
# gives all three shapes one consistent, actionable error, with a nearest-match
# "did you mean" suggestion for typos.
# ─────────────────────────────────────────────────────────────────────────────

# Nearest valid operator suffix to `suffix`, or nothing when nothing is close enough
# to be a plausible typo (so garbage input does not get a nonsense suggestion).
# Uses the shared Kernel `_suggest_name` helper with the same threshold (#365).
_suggest_operator(suffix::AbstractString)::Union{Nothing,String} =
  _suggest_name(suffix, keys(PormGsuffix))

# Consistent, actionable error for a filter operator that is not valid for the given
# value shape. `field_path` is the split lookup (…, suffix); `shape` is a human word
# ("vector", "subquery", "tuple"); `allowed` is the operator subset valid for that shape.
function _raise_invalid_filter_operator(field_path::Vector{String}, shape::AbstractString, allowed::Vector{String})
  all_opers = join(map(k -> "@" * k, sort!(collect(keys(PormGsuffix)))), ", ")
  allowed_opers = join(map(a -> "@" * a, allowed), ", ")
  if length(field_path) < 2
    # No __@ suffix at all: a bare field was paired with a $shape value.
    field = field_path[end]
    examples = join(map(a -> "$(field)__@" * a, allowed), ", ")
    throw(FilterError("Error in filter: field \e[31m$(field)\e[0m was given a $(shape) value but no operator.\n" *
                  "With a $(shape) value, use one of: $(examples)"))
  end
  suffix = field_path[end]
  if !haskey(PormGsuffix, suffix)
    # Unknown operator — typo or nonexistent. List every valid operator and, when the
    # input looks like a near-miss, suggest the intended one (e.g. @notin → @nin).
    suggestion = _suggest_operator(suffix)
    hint = suggestion === nothing ? "" : " Did you mean \e[32m@$(suggestion)\e[0m?"
    throw(FilterError("Error in filter: \e[31m@$(suffix)\e[0m is not a valid operator.$(hint)\n" *
                  "Valid operators: $(all_opers)\n" *
                  "With a $(shape) value, use one of: $(allowed_opers)"))
  else
    # Known operator, but not valid for this value shape (e.g. @gte with a vector).
    throw(FilterError("Error in filter: operator \e[31m@$(suffix)\e[0m is not valid with a $(shape) value.\n" *
                  "With a $(shape) value, use one of: $(allowed_opers)"))
  end
end

# #654: the two lookups whose value SHAPE is fixed, checked where the vector arm checks range
# arity. A scalar `@range` reached the renderer and indexed `[2]` into it — a raw `BoundsError`
# in WHERE, and in HAVING once #654 let an alias reach the range binder. A non-`Bool` `@isnull`
# reached `ISNULL` as a `MethodError`, and once that arm joined the shared ladder, as
# "ISNULL is not a supported operator" — a token nobody types, blaming the operator for the value.
#
# #808: every single-value arm calls it, not only the scalar one. The column-reference arms (`F`,
# a function, `Joined`, `CTE`) skipped it, so `"points__@isnull" => F("grid")` rendered
# `ISNULL "Tb"."grid"` and `@range => F(…)` a one-sided `BETWEEN` — both invalid SQL, surfacing at
# the database — and on a JSON path `@isnull` reached `v.values == true`, which on an expression
# builds a predicate (#541) and raised `TypeError: non-boolean`.
function _check_fixed_shape_lookup(suffix::AbstractString, value)
  suffix in ("range", "nrange") &&
    throw(FilterError("Error in filter, '$(suffix)' operator requires exactly 2 values, got 1"))
  suffix == "isnull" && !(value isa Bool) &&
    throw(FilterError("Error in filter, 'isnull' takes true or false, got $(value isa SQLType ? "a column expression" : "a $(typeof(value))")"))
  # #28: an array lookup compares two arrays, so its value is a list even for one element. A scalar is
  # refused rather than wrapped — and a bare String would otherwise be read as array-literal text
  # (`"SOFT"` is not one). A column expression is left to `_check_column_rhs_lookup`, which owns that
  # message on the column arms.
  suffix in ARRAY_CONTAINMENT_OPERATORS && !(value isa SQLType) &&
    throw(FilterError("Error in filter, '$(suffix)' takes a list of elements, even for one: " *
                      "wrap the value in a Vector, \e[4m\e[32m[value]\e[0m; got a single $(typeof(value))"))
  return nothing
end

# #997: true for the `@yyyy_q` / `@yyyy_quad` label column — a `Concat` node that `Y_Q` / `Y_QUAD`
# flagged `propagate_null`, so it renders `||` on both engines and is NULL exactly when its date is.
# That is what makes `<label> IS NULL` mean "the date is NULL", and so what licenses it in `ISNULL`.
# The narrowness is a fail-safe no test can pin: no other public spelling reaching that arm renders
# a call today, so a licence granted to every column would render the same SQL.
_is_null_propagating_label(c) =
  c isa SQLTypeField && c.field isa FObject && get(c.field.kwargs, "propagate_null", false) === true

# #811: the lookups whose right-hand side is never a single column, refused on the column-reference
# arms only (`F`, a function, `Joined`, `CTE`) — the scalar arm's `@in` binds a one-element list, which
# is fine. A column is not a list, so `"points__@in" => F("grid")` rendered `IN "Tb"."grid"`, invalid
# SQL found by the server; `IN CASE WHEN … END` likewise. Refused here, at parse, rather than in the
# renderer: every spelling — `filter`, `Q`/`Qor`, `When`, `cjoin_on(on = …)`, a HAVING alias — reaches
# these arms, so they all refuse the same way, on both engines.
#
# #793: the LIKE family, for the same reason one step removed. Its value is a text fragment that
# `add_parameter!` wraps in `%` and LIKE-escapes, and neither can happen to a column, so the arm
# concatenated the lookup NAME — `"Tb"."surname" contains "Tb"."forename"`, and no
# `BackendCapabilityError` for `iunaccent_contains` on SQLite. Rendering `'%' || col || '%'` would
# work, but the column's own `%` and `_` would then match as wildcards, unescaped. Refused instead
# (the maintainer's call on #793). Every name in `LIKE_WILDCARD_OPERATORS` is also its own
# `PormGsuffix` key, so the suffix is the membership test. The verbatim pattern lookups
# (`@regex`, `@iunaccent_exact`) take a column as-is and are not refused (#635).
function _check_column_rhs_lookup(path::Vector{String})
  suffix = path[end]
  lookup = join(path, "__@")
  suffix in ("in", "nin") &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a list of values or a subquery, " *
                      "not a column expression"))
  suffix in LIKE_WILDCARD_OPERATORS &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' matches a text value, " *
                      "not a column expression"))
  # #811, found in review: the JSON containment operators render in `_render_json_operator`, ahead of
  # every column-RHS arm, and `has_key` bound `string(v.values)` — the expression's `repr` as the key,
  # zero rows on PostgreSQL. Each takes a key, a key list or a document, never a column.
  suffix in JSON_CONTAINMENT_OPERATORS &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a JSON key or document value, " *
                      "not a column expression"))
  # #28: the array lookups bind their value as one array literal (`_render_array_operator`), which a
  # column cannot become. Comparing two array COLUMNS (`@>` against another `ArrayField`) is valid SQL
  # and Django has it; PormG does not render it yet, so it is refused here rather than bound as a value.
  suffix in ARRAY_CONTAINMENT_OPERATORS &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a list of element values, " *
                      "not a column expression"))
  return nothing
end

"""
  _get_pair_to_oper(x::Pair)

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__@gte", "__@lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

  ## Arguments
  - `x::Pair`: A Pair object to be converted to an OperObject.

  ## Returns
  - `OperObject`: An OperObject with the corresponding operator and values.

"""
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:Union{AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID}
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  else
    return OperObject(operator="=", values=x.second, column=_path_sqlfield(x.first)) # TODO, maybe I need to check if the column is valid and process the function before store
  end
end
# `Sockets.IPAddr` (#28): a network-address field takes one on write, so a filter — and the lookup
# `get_or_create` builds from its pairs — must take one too. It used to fall off this ladder as a raw
# `MethodError`, and `get_or_create` failed on a hit where `create` succeeded. Taken as its printed
# text (`format_inet_sql`) — `OperObject` carries no address type of its own. The printed form, not
# `string(ip)`: Sockets prints `::ffff:1.2.3.4` as `::ffff:102:304`, which a network field's formatter
# would re-normalize but a text column compared against it would not match.
_get_pair_to_oper(x::Pair{Vector{String},T}) where T<:Sockets.IPAddr =
  _get_pair_to_oper(x.first => Models.format_inet_sql(x.second))
_get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:Sockets.IPAddr =
  _get_pair_to_oper(x.first => String[Models.format_inet_sql(v) for v in x.second])
# #635: a Julia `Regex` is PCRE, while the `@regex` family is evaluated by PostgreSQL as POSIX ARE.
# Accepting the object would reinterpret its pattern in the other dialect — the divergence #635
# refused to ship — so it is refused with the spelling that works. It used to fall off this ladder
# as a bare `MethodError` naming an internal function.
function _get_pair_to_oper(x::Pair{Vector{String},Regex})
  key = join(x.first, "__@")
  op = x.first[end]
  # Suggest the pattern spelling only where it is the pattern lookup the user already chose; on any
  # other lookup a `@regex` suggestion would be a detour into a PostgreSQL-only feature.
  if op in ("regex", "iregex", "nregex", "niregex")
    # A string carries no flags, so `r"^sen"i` must be suggested as the case-insensitive twin —
    # echoing `@regex` would silently turn it case-sensitive.
    caseless = (x.second.compile_options & Base.PCRE.CASELESS) != 0
    suggested = caseless && op in ("regex", "nregex") ?
      join([x.first[1:end-1]..., op == "regex" ? "iregex" : "niregex"], "__@") : key
    hint = "Pass the pattern as a String, e.g. \"$(suggested)\" => $(repr(x.second.pattern)); " *
           "PostgreSQL evaluates it as a POSIX regular expression"
  else
    hint = "Pass the value as a String"
  end
  throw(FilterError("Error in filter '$(key)': a Julia Regex is not a filter value. $(hint)"))
end
function _get_pair_to_oper(x::Pair{String,T}) where T<:Union{AbstractString,Number,Bool,Dates.Date,Dates.DateTime,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# A FLAT `Vector{UInt8}` is one binary payload, not a list of small numbers (#596).
#
# `UInt8 <: Number`, so a byte payload used to land in the vector arm below, whose every branch
# slices `x.first[1:end-1]` — it assumes the last path segment is the operator. With a bare path
# nothing matched and the pair was refused as "a vector value but no operator", which is the
# spelling #411's own error message had prescribed as the workaround for `blob__@in`. It never worked.
#
# This method is strictly more specific than that arm, so it wins dispatch, and it mirrors the scalar
# shape above exactly: a `PormGsuffix` key in the last segment delegates back to the ladder (so
# `blob__@in => UInt8[1, 2]` keeps meaning a two-element IN list of the numbers 1 and 2), and a bare
# path builds the equality the scalar arm builds.
#
# It deliberately does NOT decide whether the field is binary. It cannot: `_check_filter` is handed
# only the pair, and the `Q` / `Qor` / `When` routes reach it with no model at all — a parse-time
# decision would fix `filter("blob" => bytes)` and leave `filter(Q("blob" => bytes))` refused. The
# render path already resolves the field, applies `format_binary_sql` and binds one blob through the
# scalar `PormGBytes` collector arms; the type check for a NON-binary field lives there with it, so
# every spelling behaves the same.
#
# The distinction is unambiguous by type: `Vector{Vector{UInt8}}` (a list of payloads, #466) and
# `Vector{Int}` are different types and still take the vector arm.
#
# ONLY the bare-path case is this method's business. A suffixed path goes to
# `_vector_oper_from_suffix` — the vector arm's own ladder, shared rather than restated, because
# restating it is how the first cut of this fix lost the `@range` arity check and the
# wrong-operator refusal. `PormGsuffix` is the right membership test for "is the last segment an
# operator": a TRANSFORM segment (`@year`, `@yyyy_mm`) is not in it, so `date__@year => bytes` stays a
# bare-path equality over a transform column and is refused at render like any other non-binary field.
function _get_pair_to_oper(x::Pair{Vector{String},Vector{UInt8}})
  haskey(PormGsuffix, x.first[end]) && return _vector_oper_from_suffix(x)
  return OperObject(operator="=", values=x.second, column=_path_sqlfield(x.first))
end
function _get_pair_to_oper(x::Pair{String,Vector{UInt8}})
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Widened alongside its `Pair{Vector{String},…}` twin below (#411). Not reachable from
# `_check_filter`, which splits the key at `__@` first — but leaving one of a matched pair behind
# is the drift that bites whoever calls it directly next.
function _get_pair_to_oper(x::Pair{String,Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID,AbstractVector{UInt8}}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Store SQLObject, to use __@in operator
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLObjectHandler
  if x.first[end] in ["in", "nin"]
    # @pormg_debug
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  else
    _raise_invalid_filter_operator(x.first, "subquery", ["in", "nin"])
  end
end
# #444 — `filter("raceid" => CTE("r91", "raceid"))`: the RHS is a COLUMN reference, not a value.
# Same shape as the SQLTypeF method below it (that is the idiom `F("r91__raceid")` used pre-#444).
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeCTE
  _reject_cte_desc(x.second, "a filter comparison")
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  else
    return OperObject(operator="=", values=x.second, column=_path_sqlfield(x.first))
  end
end
# #481 — the same shape for a joined-copy handle on the RHS:
# `filter("driverid" => Joined("d", "driverid"))` compares two columns.
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeJoined
  _reject_joined_desc(x.second, "a filter comparison")
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  else
    return OperObject(operator="=", values=x.second, column=_path_sqlfield(x.first))
  end
end
# #863: the right-hand side is walked like a projection (`_walk_slot`), so a transform inside it
# resolves: `filter("seen__@gte" => Max("ts__@date"))` and `F("id") + Coalesce("ts__@year", 0)`. Every
# pair spelling reaches these two methods — `filter`, `Q`/`Qor`, `When` conditions, CTE- and
# Joined-keyed pairs, `.on`/`.cjoin`/`.cjoin_on` — so this is the one place to do it.
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeF
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=_walk_slot(x.second), column=_path_sqlfield(x.first[1:end-1]))
  else
    return OperObject(operator="=", values=_walk_slot(x.second), column=_path_sqlfield(x.first))
  end
end
# #926: a scalar `Subquery(...)` is a filter value — `filter("grid" => Subquery(…))` renders
# `WHERE "grid" = (SELECT …)`, Django's `filter(grid=Subquery(…))`. It raised a raw `MethodError`
# naming this function on every pair spelling (`filter`, `Q`/`Qor`, `When`, `on`, `cjoin_on`). Shaped
# like the function arm below: a subquery is one value per row, not a list and not a text fragment,
# so the column-RHS refusals apply — except that `@in` gets its own hint, because the membership
# spelling already takes a subquery: the query itself, unwrapped (the `SQLObjectHandler` arm above).
function _get_pair_to_oper(x::Pair{Vector{String},SubqueryObject})
  suffix = x.first[end]
  if suffix in ("in", "nin")
    lookup = join(x.first, "__@")
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes the query itself, not a scalar " *
                      "Subquery(...) — pass it unwrapped, \e[4m\e[32m\"$(lookup)\" => query\e[0m."))
  end
  if haskey(PormGsuffix, suffix)
    _check_fixed_shape_lookup(suffix, x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  else
    return OperObject(operator="=", values=x.second, column=_path_sqlfield(x.first))
  end
end
# Allow Case/When and other FObject expressions as filter RHS values
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeFunction
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=_check_function(x.second), column=_path_sqlfield(x.first[1:end-1]))
  else
    return OperObject(operator="=", values=_check_function(x.second), column=_path_sqlfield(x.first))
  end
end
# `Base.UUID` and `AbstractVector{UInt8}` (#411, #466): without them a `Vector{UUID}` or a
# `Vector{Vector{UInt8}}` right-hand side never reached this method at all, so `__@in` on a UUIDField
# or a BinaryField failed at PARSE time with a MethodError — before any formatter ran, which is why
# mapping the formatter at the call site does not fix those two on its own. #411 admitted the UUID
# and refused the binary list by name, because the ARRAY collectors did not unwrap `PormGBytes`;
# #466 taught them to, so a binary list takes the ordinary vector arm below.
# A FLAT `Vector{UInt8}` — one payload rather than a list of them — does NOT take that arm: #596 gave
# it its own, strictly more specific method above, because every branch here slices off a trailing
# operator segment that a bare field path does not have.
# `Vector{Any}` (#411). `[]` — the way anyone writes an empty list, and what `ids = []` gives you
# before the first `push!` — is `Vector{Any}`, and `Any` satisfies none of the element bounds the
# methods below dispatch on. So the most natural spelling of an empty membership list raised a
# `MethodError` naming `_get_pair_to_oper` and a tuple type nobody typed: the exact untyped-error
# class this pair of issues exists to remove, on the one shape the documentation shows.
#
# `_normalize_filter_pair`'s comprehension already narrows a NON-empty `Any[…]` whose elements share
# a type, which is why `Any[UInt8[1], UInt8[2]]` reaches the binary guard correctly. It cannot narrow
# an empty one — there is nothing to infer from — so that case is handled here.
function _get_pair_to_oper(x::Pair{Vector{String},Vector{Any}})
  # Empty: no element type to preserve, because nothing is ever bound. `String[]` is as good as any.
  isempty(x.second) && return _get_pair_to_oper(x.first => String[])
  narrowed = identity.(x.second)
  # Genuinely heterogeneous — narrowing changed nothing, so re-dispatching would recurse forever.
  # Report it as what it is rather than looping or leaking a MethodError.
  narrowed isa Vector{Any} && throw(FilterError(
    "The filter \e[4m\e[31m$(join(x.first, "__"))\e[0m was given a list whose values do not share " *
    "a type: \e[4m\e[31m$(join(unique(typeof.(x.second)), ", "))\e[0m. A membership list must be " *
    "homogeneous — build it as a typed vector, e.g. \e[1mInt[…]\e[0m or \e[1mString[…]\e[0m."))
  return _get_pair_to_oper(x.first => narrowed)
end

# #918: a list of query NODES — `"grid__@in" => [F("raceid")]`, `[Lower("surname")]`, `[Max("grid")]`,
# a `CTE`/`Joined` handle, a subquery — matched no arm above and raised a raw `MethodError` naming this
# function. Refused, typed, as #793/#811 refuse ONE column expression on `@in` (`_check_column_rhs_lookup`):
# a membership list holds values, and accepting columns would reopen that decision and give the
# membership renderer — which binds the whole list — an inline-column arm on each engine.
#
# The element bound is the node families, not `PormGAbstractType`, because `PormGBytes` is one too and
# a binary payload is a value. `Vector{PormGAbstractType}` is admitted by name: it is what Julia infers
# for `[F("a"), subquery]`, whose two node families share nothing narrower. A mixed node/value list
# (`[1, F("a")]`) is `Vector{Any}` and keeps the heterogeneity refusal above.
function _get_pair_to_oper(x::Pair{Vector{String},<:Union{AbstractVector{<:Union{SQLType,SQLObject}},Vector{PormGAbstractType}}})
  # An empty list binds nothing, whatever its element type — the `Vector{Any}` arm's reasoning.
  isempty(x.second) && return _get_pair_to_oper(x.first => String[])
  suffix = x.first[end]
  lookup = join(x.first, "__@")
  kinds = join(unique(string.(nameof.(typeof.(x.second)))), ", ")
  if suffix in ("in", "nin") && all(v -> v isa SQLObjectHandler, x.second)
    # A subquery wrapped in a list — the fix is to unwrap it, not to compare columns (#918, review).
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a subquery directly, not inside a " *
                      "list — pass it as \e[4m\e[32m\"$(lookup)\" => subquery\e[0m."))
  elseif suffix in ("in", "nin")
    # The spelling that works, per polarity: IN is an OR of equalities, NOT IN an AND of inequalities.
    f = "F(\"$(join(x.first[1:end-1], "__@"))\")"
    hint = suffix == "in" ?
      "OR the equalities — \e[4m\e[32mQor($(f) == F(\"a\"), $(f) == F(\"b\"))\e[0m" :
      "AND the inequalities — \e[4m\e[32mQ($(f) != F(\"a\"), $(f) != F(\"b\"))\e[0m"
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a list of values or a subquery, " *
                      "not a list of column expressions ($(kinds)). To compare against several columns, " *
                      "$(hint)."))
  end
  throw(FilterError("Error in filter '$(lookup)': a list of column expressions ($(kinds)) is not a " *
                    "filter value. A list right-hand side holds literal values."))
end

function _get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID,AbstractVector{UInt8}}
  return _vector_oper_from_suffix(x)
end

# #28: every other vector right-hand side — in practice a list of vectors, `"tags__@in" => [[1], [2]]`,
# the shape an `ArrayField` membership list would take. It used to match no method and leak a raw
# `MethodError`. A membership list of whole arrays is not supported: the PostgreSQL membership render
# binds the list as ONE array parameter, and an array of arrays is a single two-dimensional value, not
# a list of them. Strictly less specific than every arm above, so it only catches what they do not.
function _get_pair_to_oper(x::Pair{Vector{String},<:AbstractVector})
  lookup = join(x.first, "__@")
  path = join(haskey(PormGsuffix, x.first[end]) ? x.first[1:end-1] : x.first, "__")
  # A `nothing` among values is the other shape that lands here (`["SOFT", nothing]` is a
  # `Vector{Union{Nothing, String}}`). In a filter value a NULL element is spelled `missing` — except
  # in an array lookup, which takes no NULL element in either spelling (`_refuse_null_array_element`).
  x.first[end] in ARRAY_CONTAINMENT_OPERATORS && _refuse_null_array_element(x.second, lookup)
  any(isnothing, x.second) && throw(FilterError(
    "Error in filter '$(lookup)': a filter value cannot hold `nothing`; write a NULL element as " *
    "`missing` — \e[4m\e[32m\"$(path)\" => [\"SOFT\", missing]\e[0m."))
  kinds = join(unique(string.(typeof.(x.second))), ", ")
  throw(FilterError("Error in filter '$(lookup)': a list of $(kinds) values is not a filter value. " *
                    "To match an ArrayField against several whole arrays, OR the equalities: " *
                    "\e[4m\e[32mQor(\"$(path)\" => [1, 2], \"$(path)\" => [3])\e[0m."))
end

# The suffix ladder for a VECTOR right-hand side, extracted so the `Vector{UInt8}` method above can
# reach it (#596). It cannot get here by delegation — a `Pair{Vector{String},Vector{UInt8}}` dispatches
# to its own, more specific method — and the first cut of #596 reimplemented the two-branch SCALAR
# shape instead. That silently dropped all four guards below: `blob__@gt => UInt8[1,2]` built a
# comparison against a vector (`WHERE "n" > ?, ?`, a syntax error), `@icontains` reached
# `format_text_sql(::UInt8)` as an untyped `MethodError`, and `@range => UInt8[1,2,3]` rendered a
# silently TRUNCATED `BETWEEN` over the first two bytes — the exact silent-wrong-query shape #596 set
# out to remove, reintroduced one method up. One body, two callers, so a guard cannot be missing from
# one of them.
function _vector_oper_from_suffix(x::Pair{Vector{String},<:AbstractVector})
  suffix = x.first[end]
  # #28: a bare path — the last segment is no operator — is an equality against the WHOLE vector, the
  # meaning an `ArrayField` gives it. Built here without knowing the field, as the `Vector{UInt8}` arm
  # above builds a binary equality, and for the same reason: `Q`/`Qor`/`When` reach this ladder with
  # no model. The render resolves the field and refuses the vector for any other column
  # (`_guard_vector_equality`), with the "no operator" message this ladder used to give at parse time.
  #
  # Only a path with no `__@` segment, whose last `__` segment is not an operator name: `surname__in`
  # is a typo for `surname__@in`, and keeps the "no operator" message that names the fix.
  if length(x.first) == 1 && !haskey(PormGsuffix, last(split(x.first[1], "__")))
    return OperObject(operator="=", values=x.second, column=_path_sqlfield(x.first))
  end
  if suffix in ["in", "nin"]
    @pormg_debug false
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  elseif suffix in ("range", "nrange")   # #207: nrange = NOT BETWEEN, same 2-value shape
    if length(x.second) != 2
      throw(FilterError("Error in filter, '$(suffix)' operator requires exactly 2 values, got $(length(x.second))"))
    end
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  elseif suffix in ("has_any_keys", "has_keys")
    # #27: JSONB overlap operators (?| / ?&) take an array of keys; the render branch binds the
    # vector as a single text[] parameter.
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  elseif suffix == "jcontains"
    # #27: JSONB array containment (@>) with a vector RHS — serialize to a JSON document string at
    # parse time so OperObject.values stays a String (no downstream type-union change).
    return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=_path_sqlfield(x.first[1:end-1]))
  elseif suffix in ARRAY_CONTAINMENT_OPERATORS
    # #28: the vector stays as written — formatting it needs the ELEMENT field, which only the render
    # knows (`_render_array_operator`). A NULL element is refused now, while the lookup is in hand.
    _refuse_null_array_element(x.second, join(x.first, "__@"))
    return OperObject(operator=suffix, values=x.second, column=_path_sqlfield(x.first[1:end-1]))
  else
    _raise_invalid_filter_operator(x.first, "vector", _VECTOR_VALUE_OPERATORS)
  end
end

# The lookups that take a vector right-hand side — the `allowed` list every "a vector needs one of
# these operators" refusal names. One list, because it was restated as a literal at three sites (here,
# `_guard_vector_equality`, and its alias twin in `projection_types.jl`) and #28 had to grow all three.
const _VECTOR_VALUE_OPERATORS = ["in", "nin", "range", "nrange", "has_any_keys", "has_keys", "jcontains",
                                 ARRAY_CONTAINMENT_OPERATORS...]

# #28: a NULL element in an array lookup's value. PostgreSQL's `@>`, `<@` and `&&` compare elements
# with `=`, so a NULL never matches anything — not even a NULL element of the column. Rendering it
# would be a filter that silently drops what the caller asked for; `@isnull` is the NULL test.
function _refuse_null_array_element(values::AbstractVector, lookup::AbstractString)
  any(v -> v === missing || v === nothing, values) || return nothing
  throw(FilterError("Error in filter '$(lookup)': an array lookup cannot match a NULL element " *
                    "(`missing`/`nothing`) — PostgreSQL compares elements with `=`, so a NULL never " *
                    "matches. Remove it from the list."))
end
# #27: JSONB document containment (@>) with a Dict / NamedTuple RHS — serialize at parse time so
# OperObject.values stays a String.
function _get_pair_to_oper(x::Pair{Vector{String},<:AbstractDict})
  x.first[end] == "jcontains" || _raise_invalid_filter_operator(x.first, "dict", ["jcontains"])
  return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=_path_sqlfield(x.first[1:end-1]))
end
function _get_pair_to_oper(x::Pair{Vector{String},<:NamedTuple})
  x.first[end] == "jcontains" || _raise_invalid_filter_operator(x.first, "namedtuple", ["jcontains"])
  return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=_path_sqlfield(x.first[1:end-1]))
end
function _get_pair_to_oper(x::Pair{Vector{String},Tuple{T,T}}) where T
  if x.first[end] in ("range", "nrange")   # #207: nrange = NOT BETWEEN, same 2-value shape
    return OperObject(operator=PormGsuffix[x.first[end]], values=[x.second[1], x.second[2]], column=_path_sqlfield(x.first[1:end-1]))
  elseif x.first[end] in ARRAY_CONTAINMENT_OPERATORS
    _refuse_array_lookup_tuple(x)
  else
    _raise_invalid_filter_operator(x.first, "tuple", ["range", "nrange"])
  end
end
# #28: every other Tuple — three elements, one, mixed types (`("SOFT", "MEDIUM", "HARD")`, `(12,)`,
# `("S", 1)`). None matched a method, so each leaked a raw `MethodError` naming this function. Strictly
# less specific than the 2-tuple arm above, so it only catches what that arm does not.
function _get_pair_to_oper(x::Pair{Vector{String},<:Tuple})
  suffix = x.first[end]
  suffix in ARRAY_CONTAINMENT_OPERATORS && _refuse_array_lookup_tuple(x)
  suffix in ("range", "nrange") &&
    throw(FilterError("Error in filter, '$(suffix)' operator requires exactly 2 values, got $(length(x.second))"))
  _raise_invalid_filter_operator(x.first, "tuple", ["range", "nrange"])
end
# #28: an `ArrayField` WRITE takes a Tuple, so a caller reaches for one in an array lookup too. In a
# filter a 2-tuple is `@range`'s pair (#944 kept that meaning), so the refusal names the Vector
# spelling the lookup takes rather than pointing at `@range`.
function _refuse_array_lookup_tuple(x::Pair{Vector{String},<:Tuple})
  lookup = join(x.first, "__@")
  throw(FilterError("Error in filter '$(lookup)': '$(x.first[end])' takes a Vector of elements, not a " *
                    "Tuple — \e[4m\e[32m\"$(lookup)\" => [a, b, …]\e[0m."))
end
function _get_pair_to_oper(x::Pair{Vector{String},Date})
  _get_pair_to_oper(x.first => x.second |> string)
end



# Normalize filter values at the public boundary so _get_pair_to_oper and
# OperObject always receive concrete String (not SubString or other AbstractString
# subtypes that fail the Union constraint and hold parent-string references).
function _normalize_filter_pair(value::AbstractString)
  return String(value)
end
function _normalize_filter_pair(values::AbstractVector)
  return [v isa AbstractString ? String(v) : v for v in values]
end
_normalize_filter_pair(value) = value

function _is_wildcard_projection(value)
  return false
end

function _is_wildcard_projection(value::Union{SQLTypeText,SQLTypeField})
  value isa SQLTypeText && return false
  if value.custom_as == "*" || value._as == "*"
    return true
  end
  return value.field isa String && (value.field == "*" || endswith(value.field, ".*"))
end

function _subquery_projection_labels(subquery::SQLObjectHandler)
  if isempty(subquery.object.values)
    return subquery.object.model.field_names
  end

  labels = String[]
  for value in subquery.object.values
    if _is_wildcard_projection(value)
      append!(labels, subquery.object.model.field_names)
      continue
    end

    alias = value.custom_as !== nothing ? value.custom_as : value._as

    if alias !== nothing && !isempty(alias)
      push!(labels, alias)
    elseif value isa SQLTypeField && value.field isa String
      push!(labels, value.field)
    else
      push!(labels, "<expression>")
    end
  end
  return labels
end

function _summarize_projection_labels(labels::Vector{String}; max_items::Integer=4)
  shown = labels[1:min(length(labels), max_items)]
  summary = join(shown, ", ")
  if length(labels) > max_items
    summary *= ", ..."
  end
  return summary
end

function _validate_membership_subquery(v::SQLTypeOper)
  v.values isa SQLObjectHandler || return nothing
  v.operator in ["IN", "NOT IN"] || return nothing

  subquery = v.values
  projection_labels = _subquery_projection_labels(subquery)
  projection_count = length(projection_labels)
  projection_count == 1 && return nothing

  filter_field = v.column isa SQLTypeField && v.column.field isa String ? v.column.field : "field"
  operator_suffix = v.operator == "IN" ? "in" : "nin"
  lookup = string(filter_field, "__@", operator_suffix)
  detail = if isempty(subquery.object.values)
    "The subquery currently selects all columns from '$(subquery.object.model.name)' because .values(...) was not called."
  else
    "The subquery currently selects $(projection_count) columns: $(_summarize_projection_labels(projection_labels))."
  end

  throw(FilterError(
    "PormG: '$lookup' requires a subquery that returns exactly one column. " *
    detail * " Fix: call .values(\"field_name\") on the subquery so it projects only the key used by the filter."
  ))
end

# #863 — a filter NODE handed over directly (`filter((F("id") + Coalesce("ts__@year", 0)) > 5)`,
# `OP(Max("ts__@date"), …)`) is walked like a pair's right-hand side. A `Q`/`Qor` container is not
# re-entered: its pairs were resolved when it was built, and a container can hold itself
# (`push!(q, q)`, pinned by test_cte_reference.jl). `Exists` resolves its own inner query.
_check_filter_node(v::SQLTypeOper) = _check_function(v)
function _check_filter_node(v::FExpression)
  _guard_boolean_condition(v)   # #931
  return _check_function(v)
end
_check_filter_node(v) = v

# #931 — an expression used as a CONDITION must be boolean. A top-level arithmetic or bitwise node
# (`F("lap") + 1`, `~F("flag")`, `F("a") & 4`) rendered as written: PostgreSQL rejects it ("argument of
# WHERE/CASE must be type boolean"), SQLite reads the number for truthiness and returns rows. Refused
# here, at construction, because every condition position funnels through `_check_filter_node` —
# `filter`, `Q`/`Qor` and their `push!`, `When(expr)` (via `Q`), `on`/`cjoin`/`cjoin_on` — while a
# projection or a right-hand side never does. A bare handle (`operation === nothing`) is left alone: it
# is how a `BooleanField` is tested (`filter(F("flag"))`), and no column type is known at this point.
function _guard_boolean_condition(v::FExpression)
  op = v.operation
  (op === nothing || op in _COMPARISON_OPERATIONS) && return nothing
  throw(_non_boolean_condition(op))
end
function _non_boolean_condition(op::String)
  written, fix = if op in _ARITHMETIC_OPERATIONS
    "an arithmetic expression (`$(op)`)", "compare it, e.g. \e[4m\e[32m(F(\"lap\") + 1) > 0\e[0m"
  elseif op == "~"
    "a bitwise NOT (`~`)", "compare the column instead, e.g. \e[4m\e[32mF(\"flag\") == false\e[0m"
  else
    "a bitwise expression (`$(op)`)",
    "combine conditions with \e[4m\e[32mQ(…)\e[0m / \e[4m\e[32mQor(…)\e[0m, or compare the bitwise value, " *
    "e.g. \e[4m\e[32m(F(\"points\") & 4) > 0\e[0m"
  end
  return _condition_not_boolean(written, "a number", fix, 931)
end
# The sentence #931 and #942 share: what was written, why the engines disagree, and how to fix it.
_condition_not_boolean(written::String, value::String, fix::String, issue::Int) = QueryBuildError(  # refusal-value-ok: `value` here is explanatory text, not a bound value
  "\e[4m\e[31m$(written) used as a condition\e[0m — a condition must be boolean. PostgreSQL rejects " *
  "$(value) there and SQLite reads it for truthiness, so the two engines disagree; $(fix) (#$(issue)).")

# #942 — a FUNCTION used as a `When` condition. `When(Lower("chassis"))` rendered
# `CASE WHEN LOWER(…) THEN …`: PostgreSQL rejects it, SQLite coerces the text to a number and reads it
# for truthiness, so the query silently took the default on every row. `When` is the only condition
# position that admits a bare function — `filter`/`Q`/`on` refuse one by type (`FilterType`) — but
# #931's node-type rule cannot decide it, because a function CAN be boolean (`Cast(x, "boolean")`,
# `output_field = "boolean"`, `Coalesce` over a `BooleanField`). The result type decides instead:
#
# - `:boolean` / `:non_boolean` when the node alone names its type — a declared `Cast` type or
#   `output_field`, a formatter the constructor set, or a name whose result type is fixed;
# - `:unknown` when only the operands can say (`Coalesce`, `Max`, `Lag`, an untyped `Case`). `When`
#   builds those, and `_render_function_body` asks `_expression_formatter` once the columns resolve.
#
# Only a type that is KNOWN to be non-boolean is refused, as `_expression_formatter` only answers a
# known type: an expression whose type cannot be named builds, unchecked, as it did before.
const _NUMBER_RESULT_FUNCTIONS = ("SUM", "AVG", "RANK", "DENSE_RANK", "ROW_NUMBER")
function _function_condition_kind(v::SQLTypeFunction)
  name = v.function_name
  # A declared type names the result outright, including one `_sql_type_field` has no field for
  # (`jsonb`, `timestamp`, an array): only `boolean` itself is a condition.
  declared = get(v.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  if declared isa AbstractString
    base = Base.endswith(strip(declared), "]") ? "" : lowercase(strip(first(split(declared, '('))))
    return base in ("boolean", "bool") ? :boolean : :non_boolean
  end
  v.formatter === nothing || return v.formatter === Models.format_bool_sql ? :boolean : :non_boolean
  # A `WHEN` branch is not a value at all; the rest have one fixed result type.
  (name == "WHEN" || name in _NUMBER_RESULT_FUNCTIONS || name in _TEXT_OUTPUT_FUNCTIONS ||
    haskey(PormGTypeField, name)) && return :non_boolean
  return :unknown
end
function _boolean_sum_refusal(v::SQLTypeFunction)
  written = v.function_name == "SUM" ? "Sum" : "Avg"
  # The caller's own column when the operand is one; a placeholder for anything else.
  op = v.column isa FExpression && v.column.operation === nothing ? v.column.field_name : v.column
  path = op isa SQLField ? op.field : op
  path = path isa AbstractString ? path : "is_active"
  return QueryBuildError(
    "`$(written)` over a boolean is not supported: PostgreSQL has no $(lowercase(v.function_name))(boolean), " *
    "and SQLite would silently compute it over the stored 0/1. Turn the flag into a number explicitly, e.g. " *
    "\e[4m\e[32m$(written)(When(\"$(path)\" => true, then = 1, otherwise = 0))\e[0m" *
    (written == "Avg" ? " for the share of true rows." : " to count the true rows."))
end
function _non_boolean_function_condition(v::SQLTypeFunction)
  _condition_not_boolean("`$(v.function_name)(…)`", "a non-boolean value",
    "compare it, e.g. \e[4m\e[32mWhen(Lower(\"surname\") == \"senna\")\e[0m — a function whose result is " *
    "boolean (\e[4m\e[32mCast(…, \"boolean\")\e[0m, \e[4m\e[32moutput_field = \"boolean\"\e[0m) is accepted", 942)
end

function _check_filter(x::Pair)
  # #444: a CTE-scoped LHS. Delegate on `ref.path` so the whole String pipeline runs — the `__@`
  # peel, `_check_function`'s transform construction, and whichever of the fifteen RHS-typed
  # `_get_pair_to_oper` methods matches (with its `in`/`range`/`jcontains`/arity validation intact) —
  # then retag the column it produced. Reusing the ladder is the point: a hand-written CTE branch
  # would have to re-derive every one of those checks and would drift from them.
  if isa(x.first, CTEReference)
    ref = _reject_cte_desc(x.first, "filter(...)")
    oper = _check_filter(ref.path => x.second)
    isa(oper, SQLTypeOper) && isa(oper.column, SQLField) && _retag_cte_field!(oper.column, ref.name)
    return oper
  end
  # #481: the joined-copy twin, for exactly the reason above. Delegating on `ref.path` is also what
  # makes an ALIAS-QUALIFIED OPERATOR PAIR work — `filter(Joined("d","points__@gte") => 3)` — which
  # the removed `F("d.points")` spelling could never express: the `__@` peel and the RHS-typed
  # `_get_pair_to_oper` ladder run on the path, and only the column it produced is retagged.
  if isa(x.first, JoinedReference)
    ref = _reject_joined_desc(x.first, "filter(...)")
    oper = _check_filter(ref.path => x.second)
    isa(oper, SQLTypeOper) && isa(oper.column, SQLField) && _retag_joined_field!(oper.column, ref.alias)
    return oper
  end
  if isa(x.first, AbstractString)
    key = String(x.first)
    check = String.(split(key, "__@"))
    normalized_value = _normalize_filter_pair(x.second)
    try
      # @pormg_debug
      return _get_pair_to_oper(check => normalized_value)
    catch e
      @pormg_debug false
      @error "Error in filter processing '$(key)'" exception = (e, catch_backtrace())
      rethrow(e)
    end
  else
    throw(FilterError("Error in filter: '$(x.first) => ...' must use a String key, got $(typeof(x.first))"))
  end
end
