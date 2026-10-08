# What a projection renders as, and predicates on it (#130): the formatter and kind inferred for a
# projected expression (`_expression_formatter`, `_operand_kind`, `_function_projection_kind`, the
# subquery and CTE-column kinds), what an alias reads, and rendering a filter that compares a
# projection alias. Shared across the query builder: the SELECT and filter renderers, `build`,
# `expression_render.jl`, `select_nodes.jl`, `filter_nodes.jl`, `ctes.jl` and `functions.jl`.

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
# sites in `filter_nodes.jl` had — it handed `raw_value` straight to a formatter, so a
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
  # The message is alias-shaped on purpose. `_locate_filter_refusal`'s default wording names a
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
# The gate is the one `_get_filter_query(::SQLTypeField)` (#586, filter_nodes.jl) and
# `get_order_query` (#587) already use, applied to the third and last consumer of the memo: reuse the
# text only for node kinds that cannot bind, and otherwise render the source afresh so the expression
# binds its own values in the clause it prints in. An aggregate legitimately appears twice in the
# statement, so binding twice is the correct reading, not a duplicate.
#
# #701: the WHERE path reads the memo through here too (`_get_filter_query(::SQLTypeField)`,
# filter_nodes.jl). It had the #586 gate on the wrong node — the filter KEY, a plain `String` alias,
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
#     refuses a `__` alias at `values()`, so that spelling cannot be written (and #723's silent
#     CTE-wins pairing with it). The check is still LIVE (#777): a name PormG generates can collide
#     too. A transform is named `<field>__<transform>`, and a CTE or `cjoin_on` copy may be named
#     after a model field (#492, #484), so `values("race_date__@year")` beside
#     `CTE("race_date", "year")` or `Joined("race_date", "year")` shares the name `race_date__year`
#     across namespaces. That collision is reachable in WHERE and, through `fresh = true`, in a
#     `cjoin_on` ON clause. (Since #1004 the transform's memo key is `race_date__@year`, so the KEY
#     no longer collides; `_projected_source` matches on the output name, which still does.)
#   - the OUTPUT NAME. A field-path projection is memoized under its PATH (`values("r" => "points")`
#     under `"points"`); the entry is an alias only when it renders under the key.
#
# Any other hit is a column, and its memoized text is returned as it was.
#
# Callers must have switched to the clause the text prints in — the fresh render binds, and it must
# bind there.
#
# #985: `fresh = true` is the ON-clause reading. A projection alias renders its source afresh whatever
# its kind, so every column in it reaches `_record_join_column`; anything that is not an alias answers
# `nothing`, and the caller renders the column itself.
function _alias_lhs(alias::MemoKey, cached, instruc::SQLInstruction; fresh::Bool = false)
  not_alias = fresh ? nothing : cached.field
  alias[1] === :base || return not_alias
  _projection_output_name(cached) == alias[2] || return not_alias
  source = _projected_source(alias, instruc)
  # No source (the memo was written by a non-projection path) or a kind that binds nothing: the
  # memoized text is safe, and reusing it keeps the common case byte-identical.
  source === nothing && return not_alias
  # #707: a `Value(...)` alias IS a binding — its memoized text is the SELECT's own `?`. Render the
  # literal again, so it binds in the clause it prints in (`WHERE ? = ?`, two values for two markers).
  source isa SQLTypeText && return _get_select_query(source, instruc)
  !fresh && source.field isa Union{String,SQLTypeCTE,SQLTypeJoined,OuterRefObject} && return cached.field
  return _get_select_query(source.field, instruc, _as = source._as)
end

# `_guard_vector_equality`'s alias twin (#596, #28). Same decision, different evidence: a projection
# alias has no `PormGField`, only whatever formatter `_having_alias_formatter` resolved for it, so the
# column's kind is read off that. `format_binary_sql` (a projection over a `BinaryField`) may carry a
# byte payload and an `ArrayFormatter` (over an `ArrayField`) any vector; every other alias refuses a
# vector, through the same funnel the WHERE arms use so the message is the one a user already knows.
function _guard_alias_vector_equality(v::SQLTypeOper, formatter, label::AbstractString)
  (v.operator == "=" && v.values isa AbstractVector) || return nothing
  formatter isa Models.ArrayFormatter && return nothing
  (v.values isa Vector{UInt8} && formatter === Models.format_binary_sql) && return nothing
  _raise_invalid_filter_operator([String(label)], "vector", _VECTOR_VALUE_OPERATORS)
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
#
# #28 adds the array three for the same reason: their renderer reads an `ArrayField` off the column,
# and a projection alias has none to read. #904 adds the network operators: their operand is a
# network column, and an alias has no field to say it projects one.
const _ALIAS_UNSUPPORTED_OPERATORS = Dict("jcontains" => "@jcontains", "has_key" => "@has_key",
                                          "has_any_keys" => "@has_any_keys",
                                          "has_keys" => "@has_keys",
                                          "acontains" => "@acontains",
                                          "contained_by" => "@contained_by",
                                          "overlap" => "@overlap",
                                          # #31: `@search` parses a text COLUMN, and an alias has no
                                          # field to say it projects one. #1021: a `SearchVector`
                                          # alias is the exception, and is routed before this guard
                                          # (`_render_alias_search`).
                                          "search" => "@search",
                                          (op => "@$(op)" for op in NETWORK_LOOKUP_OPERATORS)...)
function _guard_alias_clause_operator(v::SQLTypeOper, label::AbstractString)
  spelling = get(_ALIAS_UNSUPPORTED_OPERATORS, v.operator, nothing)
  spelling === nothing && return nothing
  v.operator == "search" && throw(FilterError(
    "The \e[31m@search\e[0m lookup is not supported on the projection alias \e[31m$(label)\e[0m: it " *
    "searches a text column, or an alias that projects a SearchVector — " *
    "\e[32mvalues(\"doc\" => SearchVector(\"forename\", \"surname\")).filter(\"doc__@search\" => \"senna\")\e[0m. " *
    "Filter the underlying field instead (#1021)."))
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
    formatter = _declared_type_formatter(declared, instruc)
    formatter === nothing || return formatter
  end
  # #965: an untyped `Case` over booleans is a boolean. PostgreSQL already reads it as one (the render
  # binds a `Bool` branch `::boolean`), so `Max` of it failed there as `max(boolean)` did before #953,
  # and `Sum` of it added up SQLite's 0/1.
  name == "CASE" && declared === nothing && _boolean_case(p, instruc) && return Models.format_bool_sql
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
  # #942: a comparison is not a number. It used to fall into the arithmetic rule below, so
  # `F("lap") > 0` typed as a NUMBER and `When(Coalesce(F("lap") > 0, false))` was refused. #949: it
  # is a boolean — #942 left it untyped only while `format_bool_sql` read any non-1 integer as
  # `false`, so an alias filter `"ahead" => 5` now fails loudly instead of binding `false`.
  p.operation in _COMPARISON_OPERATIONS && return Models.format_bool_sql
  left = _expression_formatter(p.field_name, instruc)
  return left === Models.format_number_sql ? left : nothing
end
_expression_formatter(p::SQLField, instruc::SQLInstruction) = _expression_formatter(p.field, instruc)
function _expression_formatter(p::Union{String,CTEReference,JoinedReference}, instruc::SQLInstruction)
  column_field = _alias_column_field(p, instruc)
  return column_field === nothing ? nothing : column_field.formatter
end
# #929: a `Subquery(...)` alias compares as its one projected column — the formatter the inner build
# resolved for it (`_render_scalar_subquery` files it). Read AFTER the SELECT renders, as the kind is;
# a node this build did not render answers `nothing`, the untyped default.
_expression_formatter(p::SubqueryObject, instruc::SQLInstruction) =
  instruc.subquery_formatters === nothing ? nothing : get(instruc.subquery_formatters, p, nothing)
# #965: `EXISTS (…)` is a boolean on both engines; SQLite evaluates it to 0/1, which a projection reads
# back as a `Bool` once this types it.
_expression_formatter(::ExistsObject, ::SQLInstruction) = Models.format_bool_sql
_expression_formatter(::Any, ::SQLInstruction) = nothing

# #965 — whether a `Case` is a boolean: every branch value (each `When`'s `then`, and the `ELSE`) is
# one. A string `then` is a literal, never a column path, so it is not looked up.
function _boolean_case(p::SQLTypeFunction, instruc::SQLInstruction)::Bool
  values = Any[]
  for branch in (p.column isa AbstractVector ? p.column : (p.column,))
    (branch isa SQLTypeFunction && branch.function_name == "WHEN") || return false
    push!(values, get(branch.kwargs, "then", nothing))
  end
  push!(values, get(p.kwargs, "else", nothing))
  return _all_boolean(values, instruc; paths = false)
end

# #965 — whether a value is a boolean only when ALL of its candidate values are: a `Bool` literal, or
# an expression `_expression_formatter` types as one. A NULL is no value and is skipped; NULLs alone
# are untyped. Every value must agree, as `_multi_operand_kind` requires: PostgreSQL refuses a CASE or
# COALESCE mixing boolean and integer, and on SQLite the result would be a boolean on some rows and an
# integer on others, so a mixed one is no boolean to type. `paths`: whether a string is a column path
# (a `Coalesce` operand) or a literal (a `Case` branch).
function _all_boolean(values, instruc::SQLInstruction; paths::Bool)::Bool
  typed = false
  for value in values
    literal = value isa SQLText ? value.field : value
    _is_null_literal(literal) && continue
    boolean = literal isa Bool ||
      ((value isa Union{SQLObject,SQLType} || (paths && value isa AbstractString)) && !(value isa SQLText) &&
       _expression_formatter(value, instruc) === Models.format_bool_sql)
    boolean || return false
    typed = true
  end
  return typed
end

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
  # #953, #965: a boolean value is typed a boolean, whichever function produced it. PostgreSQL's
  # driver types it already; SQLite delivers the 0/1 it stores, which `value_parser(::CBool, …)` turns
  # back into a `Bool`. `field_canonical_kind` names no boolean kind (the table also feeds the
  # comparison binder: #882's reason), so the formatter the build already gives the value decides: an
  # extremum over a boolean, a `Cast`/`output_field` naming one, `Coalesce` or `Case` over booleans. A
  # window value function returns its operand's own value, so its operand decides.
  _is_boolean_valued(p, instruc) && return CBool()
  p isa FObject && p.function_name in _AGREEING_OPERAND_FUNCTIONS && return _multi_operand_kind(p, instruc)
  p isa FObject && p.function_name == "NULLIF" && return _operand_kind(first(p.column), instruc)
  p.function_name in _KIND_PRESERVING_FUNCTIONS || return nothing
  return _operand_kind(p.column, instruc)
end
_function_projection_kind(::Any, ::SQLInstruction) = nothing
function _is_boolean_valued(p::FObject, instruc::SQLInstruction)
  # `_expression_formatter` takes the FIRST operand that names a type, which is right for a filter
  # value but would type `Coalesce("is_active", "points")` a boolean. A declared `output_field` is
  # the cast's type and decides alone.
  if p.function_name in _AGREEING_OPERAND_FUNCTIONS && !(get(p.kwargs, "output_field", nothing) isa AbstractString)
    return _all_boolean(p.column isa AbstractVector ? p.column : (p.column,), instruc; paths = true)
  end
  return _expression_formatter(p, instruc) === Models.format_bool_sql
end
_is_boolean_valued(p::WindowFunction, instruc::SQLInstruction) =
  p.function_name in _KIND_PRESERVING_FUNCTIONS && _expression_formatter(p.column, instruc) === Models.format_bool_sql

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

# #1027 — a `Concat` operand that has no single text: `(kind, what)`, `kind` one of `:bool`, `:float`,
# `:decimal`, `:numeric`, or `nothing`. PostgreSQL's `CONCAT` writes each operand through its type's
# output function and SQLite's `||` through its own number formatting, on top of PormG's SQLite
# storage (a boolean is `0`/`1`, a decimal an integer or a REAL, #648): `true` reads `t` and `1`, a
# float `25` and `25.0`, a decimal `3.00` and `3`. #860/#876 refused these three as a TEXT value for
# that reason, and `Concat` makes text from its operands, so it refuses the same three as operands.
#
# Only a type that is KNOWN is answered, as everywhere in this file: an operand whose type cannot be
# named (a `Subquery`, an untyped `Case`, a function PormG does not type) is let through, not guessed
# at. Read after the operands render, so a joined path's field memo exists (`_alias_column_field`).
#
# #1028 adds three kinds, measured on PostgreSQL 16.15 and SQLite 3.45.1 through the F1 fixture:
# `:timestamp` (`2009-03-29 06:00:00+00` against the stored `2009-03-29T06:00:00.000+00:00`),
# `:interval` (PostgreSQL writes its `IntervalStyle`, `PT25.021S` on the test server, SQLite the
# stored `00:00:26.898`) and `:json` (`jsonb` re-renders `{"a": [1, 2]}`, SQLite keeps `{"a":[1,2]}`).
# A date, a time and a uuid read the same text on both, and pass. A CTE column is classified by its
# body's own projection (`_cte_textless_record`), not by the field `_set_field_from_sql_function`
# gives it: that types a `Sum` column as an integer and an `Avg` one as its operand's field.
#
# `:numeric` is the functions PostgreSQL computes as `numeric` whatever the operand (`Dialect` casts
# each operand `::numeric`, and `avg` of an integer is numeric too) while SQLite answers a REAL:
# `Mod(7, 3)` reads `1` and `1.0`. Measured on SQLite 3.45.1 for #1027.
const _FRACTIONAL_FUNCTIONS = ("AVG", "ROUND", "MOD", "SQRT", "EXP", "LN", "POWER")
# Functions whose value has their operands' type: one boolean, float or decimal operand makes the
# result one (PostgreSQL's numeric promotion for a number), so any operand decides. `FLOOR`/`CEIL` are
# `numeric` on PostgreSQL but agree with SQLite's integer over an integer operand, so they are here,
# not above.
const _NUMERIC_OPERAND_FUNCTIONS = ("MAX", "MIN", "SUM", "ABS", "FLOOR", "CEIL", "COALESCE", "GREATEST",
                                    "LEAST", "NULLIF", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE")
function _concat_textless_operand(p, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  p isa SQLText && return _textless_literal(p.field)
  # A `Q(...)` / `Qor(...)` renders a predicate, which is a boolean.
  p isa Union{SQLTypeQ,SQLTypeQor} && return (:bool, "a Q(…) condition")
  # A boolean column, a comparison, `Exists`, a boolean `Case`, an extremum over one: the one reader
  # that already types all of them.
  if p isa Union{SQLObject,SQLType,AbstractString}
    if _expression_formatter(p, instruc) === Models.format_bool_sql
      label = _concat_operand_label(p)
      return (:bool, label === nothing ? "a boolean expression" : "the BooleanField `$(label)`")
    end
    recorded = _cte_textless_record(p, instruc)
    recorded === nothing || return recorded
    temporal = _textless_temporal(p, instruc)
    temporal === nothing || return temporal
  end
  return _textless_number(p, instruc)
end

# #1028 — a timestamp, an interval or a JSON document: each has a text of its own on each engine (the
# measurements above). The kind comes from `_operand_kind`, which already names it for a column, a
# joined or CTE handle, a transform and a typed function (`Max("start_at")`, `Max("lap")`). Arithmetic
# over a timestamp or a duration, and `Sum(duration)`, have no kind there: the renderer says those are
# intervals (`_render_function_body` passes it to both refusals).
#
# A JSON operand is refused as the WHOLE document only. A key lookup (`"payload__driver"`) resolves to
# the same field, but renders `#>>` / `json_extract`, the value at that key. That value has one text
# when it is a string; a boolean or a nested value can still differ (`'true'` vs `1`), but PormG cannot
# know which a key holds, so a lookup is let through, as an operand of unknown type is.
function _textless_temporal(p, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  label = _concat_operand_label(p)
  kind = _operand_kind(p, instruc)
  kind isa CDateTime && return (:timestamp, label === nothing ? "a timestamp expression" : "the DateTimeField `$(label)`")
  kind isa CInterval && return (:interval, label === nothing ? "an interval expression" : "the DurationField `$(label)`")
  _json_document_operand(p, instruc) && return (:json, "the JSONField `$(label)`")
  return nothing
end
_json_document_operand(p::SQLField, instruc::SQLInstruction) = _json_document_operand(p.field, instruc)
_json_document_operand(p::FExpression, instruc::SQLInstruction) =
  p.operation === nothing && _json_document_operand(p.field_name, instruc)
function _json_document_operand(p::Union{String,CTEReference,JoinedReference}, instruc::SQLInstruction)
  _alias_column_field(p, instruc) isa Models.sJSONField || return false
  # A CTE column the body projected as a key lookup holds that value; its field is the JSONField all
  # the same, so the body's record says which (`_build_cte_custom_model`).
  p isa CTEReference && _cte_record_kind(p, instruc) === :json_value && return false
  # The join walk records every key lookup it renders (`_render_json_lookup`); any other path to a
  # JSONField names the column. A handle whose path goes on past the column is let through.
  p isa String || occursin("__", p.path) && return false
  return !memo_json_lookup(instruc, p isa String ? memo_key(:base, p) : memo_key(p))
end
_json_document_operand(::Any, ::SQLInstruction) = false

# #1028 — the classification of a CTE column, as `_build_cte_custom_model` recorded it from the body's
# own projection while the body's instruction was live. `nothing` for anything else, for a path that
# hops on through the column (it ends at a real model field, which the field memo answers), and for a
# column the record has no entry for (a body not built in this pass, or a column with a single text).
function _cte_textless_record(p::CTEReference, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  occursin("__", p.path) && return nothing
  cte = get(instruc.object.ctes, p.name, nothing)
  cte === nothing && return nothing
  record = get(cte, "textless", nothing)
  record isa Dict || return nothing
  side = get(record, p.path, nothing)
  (side === nothing || side[1] === :json_value) && return nothing
  return (side[1], "the CTE column `$(_concat_operand_label(p))` ($(side[2]))")
end
_cte_textless_record(p::SQLField, instruc::SQLInstruction) = _cte_textless_record(p.field, instruc)
function _cte_record_kind(p::CTEReference, instruc::SQLInstruction)::Union{Symbol,Nothing}
  cte = get(instruc.object.ctes, p.name, nothing)
  record = cte === nothing ? nothing : get(cte, "textless", nothing)
  record isa Dict || return nothing
  side = get(record, p.path, nothing)
  return side === nothing ? nothing : side[1]
end
_cte_textless_record(::Any, ::SQLInstruction) = nothing

# #1028 — the declared casts a function renders: `Cast`'s type and the `output_field` of the three that
# apply theirs (`Dialect._output_field_cast`). `Case` casts its `output_field` too, but its value is a
# branch, which this does not type, so it stays fail-open; `Concat` renders no cast (#835).
const _DECLARED_CAST_FUNCTIONS = ("CAST", "COALESCE", "GREATEST", "LEAST")
# The operands whose value is a whole number on both engines, so a cast to an integer has nothing to
# round: `Floor`/`Ceil`, and `Round` to no digits. Measured equal on PostgreSQL and SQLite for every
# `Result.points` row and for ±0.5, ±1.5, ±2.5 (PostgreSQL's `round` is the `numeric` one PormG renders,
# half away from zero, as SQLite's is). `Round(x, 2)` keeps a fraction, so it is not here.
#
# A whole number stays one through `Mod` and through `+`, `-`, `*`: PostgreSQL's `numeric` and SQLite's
# REAL only SPELL `1` differently (`1` vs `1.0`), which a cast to an integer removes. So
# `Cast(Mod("number", 3), IntegerField())` and `Cast(Floor("points") * 2, IntegerField())` pass. An
# operand counts as whole when it is one of these, or has no fractional kind (an integer column, an
# integer literal, a type PormG cannot name, which is let through anyway).
function _integral_valued(p, instruc::SQLInstruction)
  if p isa FObject
    p.function_name in ("FLOOR", "CEIL") && return true
    if p.function_name == "ROUND"
      precision = get(p.kwargs, "precision", 0)
      return precision isa Integer && precision == 0
    end
    p.function_name == "MOD" && p.column isa AbstractVector && return all(x -> _whole_number(x, instruc), p.column)
    return false
  end
  p isa SQLField && return _integral_valued(p.field, instruc)
  p isa FExpression && p.operation in ("+", "-", "*") &&
    return _whole_number(p.field_name, instruc) && _whole_number(p.operand, instruc)
  return false
end
_whole_number(x, instruc::SQLInstruction) = _integral_valued(x, instruc) || _concat_textless_operand(x, instruc) === nothing

# #1040 — the scale a declared numeric type rounds to, or `nothing` for a type with none. PostgreSQL
# rounds a value cast to `numeric(p, s)` to `s` digits (half away from zero) and `numeric(p)` to a
# whole number; SQLite reads either as a type name with NUMERIC affinity and keeps every digit.
# Measured on PostgreSQL 16.15 and SQLite 3.45.1: `1.5` at `numeric(10,0)` is `2` and `1.5`, `1.555`
# at `numeric(10,2)` is `1.56` and `1.555`. An unscaled `numeric` (and `DecimalField().type`,
# `"DECIMAL"`) keeps the value on both, and an array is not a number, so neither has a scale here.
# The name is `Dialect.cast_type_name`'s validated spelling, so the size is plain digits.
function _numeric_cast_scale(type_name::AbstractString)::Union{Int,Nothing}
  # `dec` is PostgreSQL's third spelling of `numeric` (its grammar's `DEC opt_type_modifiers`).
  m = match(r"^(?i:numeric|decimal|dec)\((\d+)(?:,(\d+))?\)$", type_name)
  m === nothing && return nothing
  return m.captures[2] === nothing ? 0 : parse(Int, m.captures[2])
end

# #1040 — an operand of a cast to `numeric(p, s)` that can carry more than `s` fractional digits, as
# `(kind, what)`, or `nothing` when PostgreSQL's rounding cannot change it. Rounding first is NOT an
# escape beyond whole numbers: `Round(x, 2)` is `ROUND(x::numeric, 2)` on PostgreSQL, which rounds the
# float's 15-digit decimal form, and `ROUND(x, 2)` on SQLite, which rounds the binary double, so
# `2.675` is `2.68` on one and `2.67` on the other (`1.555`, `1.005` likewise). It is classified as the
# `numeric` function it is. `Round(x)`, `Floor` and `Ceil` agree (every `Result.points` row, ±0.5,
# ±1.5, ±2.5), so a whole number passes any scale.
#
# Bounded: a whole number (`_integral_valued`, and any operand with no fractional kind — an integer
# column, a type PormG cannot name), a `DecimalField` column of at most `s` places, a `Decimal`
# literal of at most `s` digits, a `Float64` literal whose shortest form has at most `s` places and 15
# significant digits (#1050: `1.5` at scale 2 reads `1.5` on both engines, there is nothing to round),
# and a nested cast to a scale of at most `s`. Unbounded: a float column, a float literal with more
# places or digits, a `numeric` function, a decimal of unknown scale, and text — PostgreSQL
# parses `'1.555'` and rounds it, SQLite converts it and keeps it — including a JSON value. An operand
# PormG cannot type (an untyped `Case`, a `Subquery`) passes, as it does for #1028.
const _SCALE_PRESERVING_FUNCTIONS = ("MAX", "MIN", "ABS", "COALESCE", "GREATEST", "LEAST", "NULLIF")
function _scale_divergent_operand(p, scale::Int, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  _integral_valued(p, instruc) && return nothing
  operand = p isa SQLField ? p.field : p isa FExpression && p.operation === nothing ? p.field_name : p
  if operand isa SQLText
    x = operand.field
    x isa AbstractString && return (:text, "the string literal $(repr(x))")
    if x isa Float64 && isfinite(x)
      places, significant = _float_literal_digits(x)
      places <= scale && significant <= 15 && return nothing
      return (:float, significant > 15 ? "the Float64 literal $(x) ($(significant) significant digits)" :
                                         "the Float64 literal $(x) ($(places) decimal places)")
    end
    # Another float type binds through its own type, which was not measured: a whole one passes, as a
    # whole number does anywhere here, and a fraction is refused below.
    x isa AbstractFloat && isinteger(x) && return nothing
    if x isa Decimals.Decimal
      digits = _decimal_scale(x)
      return digits <= scale ? nothing : (:decimal, "the Decimal literal $(x) ($(digits) decimal places)")
    end
  end
  if operand isa Union{String,JoinedReference,CTEReference}
    field = _alias_column_field(operand, instruc)
    # A JSON value is text to PostgreSQL's cast (`#>>` returns text, and `jsonb::numeric` parses the
    # scalar), which rounds it; SQLite's `json_extract` hands over the number, which keeps every digit.
    field isa Models.sJSONField && return (:text, "the JSONField `$(_concat_operand_label(operand))`")
  end
  if operand isa Union{String,JoinedReference}
    field = _alias_column_field(operand, instruc)
    if field isa Models.sDecimalField
      places = field.decimal_places
      return places <= scale ? nothing :
        (:decimal, "the DecimalField `$(_concat_operand_label(operand))` ($(places) decimal places)")
    end
  end
  if operand isa FObject && operand.function_name in _DECLARED_CAST_FUNCTIONS
    declared = get(operand.kwargs, operand.function_name == "CAST" ? "type" : "output_field", nothing)
    inner = declared isa AbstractString ? _numeric_cast_scale(declared) : nothing
    inner === nothing || return inner <= scale ? nothing : (:decimal, "a value cast to $(declared)")
  end
  # A function whose value is one of its operands' values gains no digits: `Max("price")` of a
  # two-place DecimalField has two. With an `output_field` it is a cast, read above or below.
  if operand isa FObject && operand.function_name in _SCALE_PRESERVING_FUNCTIONS &&
     !(get(operand.kwargs, "output_field", nothing) isa AbstractString)
    for x in (operand.column isa AbstractVector ? operand.column : (operand.column,))
      side = _scale_divergent_operand(x, scale, instruc)
      side === nothing || return (side[1], "`$(operand.function_name)(…)` over $(side[2])")
    end
    return nothing
  end
  # A cast to an integer or a float is typed here too (`_textless_number` reads its declared type). A
  # boolean, a timestamp or an interval is not rounded: PostgreSQL has no cast from one to `numeric`.
  side = _concat_textless_operand(p, instruc)
  side !== nothing && side[1] in (:float, :decimal, :numeric) && return side
  # Text: a text column or function (`_expression_formatter` names every one), or a text CTE column.
  _expression_formatter(p, instruc) === Models.format_text_sql && return (:text, _text_operand_label(p))
  return nothing
end
# The digits a `Decimal` needs after the point: `1.50` needs one, `25` none.
function _decimal_scale(x::Decimals.Decimal)::Int
  c, q = x.c, x.q
  while q < 0 && !iszero(c) && iszero(c % 10)
    c, q = c ÷ 10, q + 1
  end
  return max(0, -q)
end
# #1050 — the digits a float literal's shortest decimal form needs, `(places, significant)`: `1.5` is
# `(1, 2)`, `2.675` `(3, 4)`, `1.0e-5` `(5, 1)`, `12345678901234.56` `(2, 16)`. That form is the value
# both engines read, as long as it has at most 15 significant digits: PostgreSQL converts `float8` to
# `numeric` at 15 (`12345678901234.56` becomes `12345678901234.6` before any scale applies), and
# SQLite keeps the double.
function _float_literal_digits(x::Float64)::Tuple{Int,Int}
  m = match(r"^-?(\d+)(?:\.(\d+))?(?:e(-?\d+))?$", string(x))
  whole, frac = m.captures[1], rstrip(something(m.captures[2], ""), '0')
  exponent = m.captures[3] === nothing ? 0 : parse(Int, m.captures[3])
  digits = rstrip(lstrip(whole * frac, '0'), '0')
  return (max(0, length(frac) - exponent), max(1, length(digits)))
end
_text_operand_label(p) = (l = _concat_operand_label(p); l === nothing ? "a text expression" : "the text column `$(l)`")

# #1028 — a declared cast to text or to an integer over an operand the engines convert differently:
# `(kind, what, target, flag)`, or `nothing`. To text, every operand `Concat` refuses (the conversion
# is the same output function: `true::varchar` is `'true'` on PostgreSQL and `'1'` on SQLite, a float
# `'25'` and `'25.0'`). To an integer, a fractional number only: PostgreSQL rounds it (`float8` half to
# even, `numeric` half away from zero) and SQLite truncates, so `1.5` is `2` on one and `1` on the
# other. A boolean is `1`/`0` on both, and passes.
#
# #1040 adds a third target, `:scale`: a `numeric(p, s)` cast over an operand with more than `s`
# fractional digits (`_scale_divergent_operand`). Its fourth slot is the declared type, which the
# message names, instead of a column flag.
#
# The OPERAND is classified, not the node: the node's own declared type is what makes it a text or an
# integer, which `_textless_number` reads as an acceptable `Concat` operand once this has passed it.
_declared_cast_label(v::FObject) = v.function_name == "CAST" ? "Cast" :
  "$(uppercasefirst(lowercase(v.function_name)))(…; output_field = \"$(v.kwargs["output_field"])\")"
#
# `rendered` holds each operand's kind as its render computed it (`_render_operand_kind`): a timestamp
# or an interval no type reader names (arithmetic, `Sum(duration)`), which matters to a text target.
function _cast_divergent_operand(v::FObject, instruc::SQLInstruction; rendered::AbstractVector = Any[])
  declared = get(v.kwargs, v.function_name == "CAST" ? "type" : "output_field", nothing)
  (declared isa AbstractString && !isempty(declared)) || return nothing
  # #1040: a scaled numeric target rounds on PostgreSQL only.
  scale = _numeric_cast_scale(declared)
  if scale !== nothing
    for operand in (v.column isa AbstractVector ? v.column : (v.column,))
      side = _scale_divergent_operand(operand, scale, instruc)
      side === nothing || return (side[1], side[2], :scale, declared)
    end
    return nothing
  end
  target = _sql_type_field(declared)
  to_integer = target isa Union{Models.sIntegerField,Models.sBigIntegerField}
  (to_integer || target isa Union{Models.sCharField,Models.sTextField}) || return nothing
  for (i, operand) in enumerate(v.column isa AbstractVector ? v.column : (v.column,))
    to_integer && _integral_valued(operand, instruc) && continue
    side = _concat_textless_operand(operand, instruc)
    side === nothing && !to_integer && (side = _rendered_kind_textless(get(rendered, i, nothing)))
    side === nothing && continue
    to_integer && !(side[1] in (:float, :decimal, :numeric)) && continue
    return (side[1], side[2], to_integer ? :integer : :text, _concat_flag(operand))
  end
  return nothing
end
# A rendered kind no type reader gave (`_render_operand_kind`), as a `_concat_textless_operand` answer.
_rendered_kind_textless(kind) =
  kind isa CDateTime ? (:timestamp, "a timestamp expression") :
  kind isa CInterval ? (:interval, "an interval expression") : nothing
_textless_literal(x::Bool) = (:bool, "the literal $(x)")
_textless_literal(x::AbstractFloat) = (:float, "the $(typeof(x)) literal $(x)")
_textless_literal(x::Decimals.Decimal) = (:decimal, "the Decimal literal $(x)")
# #1028: PostgreSQL binds a timestamp as `$1::timestamp` and writes `2009-03-29 06:00:00`, SQLite binds
# the stored text `2009-03-29T06:00:00.000+00:00`; a duration is an `interval` on one and the
# `HH:MM:SS` text on the other. A `Date` and a `Time` bind the same text on both, and pass.
_textless_literal(x::Union{DateTime,ZonedDateTime}) = (:timestamp, "the $(nameof(typeof(x))) literal $(x)")
_textless_literal(x::Union{Dates.Period,Dates.CompoundPeriod,Interval}) = (:interval, "the duration literal $(x)")
_textless_literal(::Any) = nothing

# The column an operand names, as the caller spelled it, or `nothing` for any other expression.
# `_concat_flag` hands a path to the refusal's `Case(When("<path>" => true, …))` suggestion.
_concat_operand_label(p::AbstractString) = String(p)
_concat_operand_label(p::CTEReference) = "CTE(\"$(p.name)\", \"$(p.path)\")"
_concat_operand_label(p::JoinedReference) = "Joined(\"$(p.alias)\", \"$(p.path)\")"
_concat_operand_label(p::SQLField) = _concat_operand_label(p.field)
_concat_operand_label(p::FExpression) = p.operation === nothing ? _concat_operand_label(p.field_name) : nothing
_concat_operand_label(::Any) = nothing
_concat_flag(p) = (l = _concat_operand_label(p); l isa String && !occursin('(', l) ? l : "<flag>")

function _textless_number(p::Union{String,CTEReference,JoinedReference}, instruc::SQLInstruction)
  field = _alias_column_field(p, instruc)
  field isa Models.sFloatField && return (:float, "the FloatField `$(_concat_operand_label(p))`")
  field isa Models.sDecimalField && return (:decimal, "the DecimalField `$(_concat_operand_label(p))`")
  return nothing
end
_textless_number(p::SQLField, instruc::SQLInstruction) = _textless_number(p.field, instruc)
function _textless_number(p::FExpression, instruc::SQLInstruction)
  p.operation === nothing && return _textless_number(p.field_name, instruc)
  side = something(_textless_number(p.field_name, instruc), _textless_number(p.operand, instruc), Some(nothing))
  return side === nothing ? nothing : (side[1], "arithmetic over $(side[2])")
end
function _textless_number(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  name = p.function_name
  # A declared type is the cast the SQL renders, so it decides alone: `Cast(points, IntegerField())`
  # is an integer whatever `points` is.
  declared = get(p.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  if declared isa AbstractString && !isempty(declared)
    field = _sql_type_field(declared)
    field isa Models.sFloatField && return (:float, "a value cast to $(declared)")
    field isa Models.sDecimalField && return (:decimal, "a value cast to $(declared)")
    return nothing
  end
  name in _FRACTIONAL_FUNCTIONS && return (:numeric, "`$(name)(…)`")
  name in _NUMERIC_OPERAND_FUNCTIONS || return nothing
  # The whole classifier, not only the number half: `Lag("active")` is the boolean's own value, and
  # `_expression_formatter` does not type a window value function.
  for operand in (p.column isa AbstractVector ? p.column : (p.column,))
    side = _concat_textless_operand(operand, instruc)
    side === nothing || return (side[1], "`$(name)(…)` over $(side[2])")
  end
  return nothing
end
_textless_number(x::Union{Bool,AbstractFloat,Decimals.Decimal}, ::SQLInstruction) = _textless_literal(x)
_textless_number(p::SQLText, ::SQLInstruction) = _textless_literal(p.field)
_textless_number(::Any, ::SQLInstruction) = nothing

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

# #929 — the formatter of a subquery's one projected column, asked of the INNER instruction while
# `query()` still holds it (its `built` callback): the inner memos are what resolve a joined path, and
# they do not outlive the inner build. `nothing` when the projection names no type.
function _subquery_projection_formatter(handler::SQLObjectHandler, inner::SQLInstruction)
  vals = handler.object.values
  length(vals) == 1 || return nothing
  return _expression_formatter(only(vals), inner)
end
function _record_subquery_formatter!(instruc::SQLInstruction, p::SubqueryObject, formatter)
  formatter isa Function || return nothing
  instruc.subquery_formatters === nothing && (instruc.subquery_formatters = IdDict{SubqueryObject,Function}())
  instruc.subquery_formatters[p] = formatter
  return nothing
end

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
  # #929: the types a pattern lookup must read as text (`_pattern_text_kind`). Without them a
  # `Cast(x, "uuid")` alias had no formatter, so `@startswith` rendered `LIKE` on a uuid, which
  # PostgreSQL has no operator for, and an equality value on it bound unchecked. All three are typed
  # on PostgreSQL only: SQLite renders each cast as `CAST(x AS TEXT)`, so the readers that know the
  # engine ignore or refuse them there (`_declared_type_formatter`, `_declared_type`).
  base == "uuid" && return Models.UUIDField()
  base == "inet" && return Models.GenericIPAddressField()
  base == "cidr" && return Models.CIDRField()
  return nothing
end

function _sql_type_formatter(type_name::AbstractString)
  field = _sql_type_field(type_name)
  return field === nothing ? nothing : field.formatter
end

# The formatter a declared type (`Cast`'s type, an `output_field=`) gives a value compared with the
# expression, on this engine. A uuid or network type names none on SQLite: there `Cast(x, "uuid")`
# renders `CAST(x AS TEXT)`, so the value compares with that text, and running it through the type's
# formatter would normalize it (`ABCDEF01-…` → `abcdef01-…`, `2001:DB8::1` → `2001:db8::1`) away
# from what the column holds — a silent no-match (review of #929). A `UUIDField` column there holds
# the canonical text already, which is why a subquery over one IS typed (`subquery_formatters`).
function _declared_type_formatter(type_name::AbstractString, instruc::SQLInstruction)
  field = _sql_type_field(type_name)
  field === nothing && return nothing
  instruc.connection isa PormGSQLite && _text_cast_on_sqlite(field) && return nothing
  return field.formatter
end
# The declared types SQLite renders as `CAST(x AS TEXT)` (predicates in value_validation.jl).
_text_cast_on_sqlite(field::PormGField) = _is_uuid_field(field) || _is_network_field(field)

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
  # #1021: an alias projecting a `SearchVector` takes `@search` and nothing else.
  searched = _render_alias_search(v, _projected_source(having_key, instruc), having_key[2], instruc)
  searched === nothing || return searched
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
  _guard_alias_vector_equality(v, _having_alias_formatter(having_key, instruc), having_key[2])
  # #618: refuse, in this clause, the operators `_render_predicate` has no arm for — since #654
  # the JSON four, joined by the array three (#28) and the network operators (#904). Naming the
  # user's own spelling matters here: the internal token is `jcontains`, but nobody types that —
  # they type `@jcontains`.
  _guard_alias_clause_operator(v, having_key[2])
  # #654: `@isnull` on a COUNT alias refuses here, ahead of any render, for the reason above.
  isnull_aggregate = v.operator == "ISNULL" && _alias_isnull_aggregate(having_key, instruc)
  # #894: an interval alias compared with a duration compares milliseconds on SQLite.
  interval = _render_interval_alias_predicate(v, having_key, instruc)
  interval === nothing || return interval
  # #903: the alias's own column type decides what a pattern lookup reads — `HOST(MAX(…))` for an alias
  # over an `inet`, exactly as `_get_filter_query(::SQLTypeOper)` wraps the column itself.
  field = _pattern_operand(string(_alias_lhs(having_key, having_cached, instruc)),
                           _having_alias_formatter(having_key, instruc), v.operator, instruc;
                           label = having_key[2])
  # #618: `contains=` / `operator=` are what run `_apply_like_wildcards` (and with it
  # `escape_like_pattern`) inside `add_parameter!`. Without them a pattern lookup on an alias
  # bound its value undecorated AND unescaped — no `%`, and a user-supplied `%` or `_` in the
  # term matched as a wildcard. `_bind_predicate_value` applies that gate — membership in
  # `LIKE_WILDCARD_OPERATORS`, exactly as the WHERE binding arms in `filter_nodes.jl` spell
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
                           expression = isnull_aggregate)
end

# #1021 — `values("doc" => SearchVector(…)).filter("doc__@search" => q)`, Django's multi-column search.
# The vector renders again in the predicate's clause (it binds there, if it binds at all — a
# `Value(…)` inside it), then the query: `<vector> @@ <query>`, in text order. A query written as a
# String takes the vector's config, as `SearchRank`'s does; a sum of vectors with mixed configs has
# none to lend it. `nothing` for an alias that is not a SearchVector, which the caller renders as it
# always did — `@search` on one is refused by `_guard_alias_clause_operator`.
#
# An index serves this when it is declared on the same document: `Models.search_vector_expression`
# with the vector's columns and config renders it.
function _render_alias_search(v::SQLTypeOper, source, label::AbstractString, instruc::SQLInstruction)
  (source isa SQLTypeField && _is_fts_node(source.field, "SEARCH_VECTOR")) || return nothing
  vector = source.field
  v.operator == "search" || throw(FilterError(
    "The projection alias \e[31m$(label)\e[0m is a SearchVector, and the only lookup on it is " *
    "\e[32m@search\e[0m: \e[32m\"$(label)__@search\" => SearchQuery(…)\e[0m. A tsvector has no order or " *
    "equality worth filtering on (#1021)."))
  instruc.connection isa PormGSQLite && throw(Dialect.fts_capability_error("The @search lookup"))
  query = v.values
  if query isa AbstractString
    get(vector.kwargs, "mixed_config", false) === true && throw(FilterError(
      "The SearchVector projected as \e[31m$(label)\e[0m adds vectors with different configs, so a " *
      "query written as a String has no config to be parsed with. Pass a SearchQuery(text; config = …) (#1021)."))
    query = SearchQuery(query; config = vector.kwargs["config"])
  end
  _is_fts_node(query, "SEARCH_QUERY") || throw(FilterError(
    "The \e[31m@search\e[0m lookup takes the search text (a String) or a SearchQuery(...) (#1021)."))
  rendered_vector = _render_fts_operand(vector, instruc; _as = source._as)
  return Dialect.search(instruc.connection, rendered_vector, _render_fts_operand(query, instruc))
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
# One definition for the alias test, which was spelled out three times (`get_filter_query`'s
# top-level branch, `_guard_window_alias_in_q`, `_aggregate_alias_leaf` — all in `build_filter.jl`),
# and for #703's collision guard, which asks the complementary question of the same key.
_plain_filter_key(col) =
  (col isa SQLTypeField && col.field isa String && !contains(col.field, "__")) ? col.field : nothing

# The alias test: a plain key that names no field of the model. It is a projection alias or a name
# that does not exist; the callers tell those apart through the memo.
function _alias_filter_key(col, instruc::SQLInstruction)
  key = _plain_filter_key(col)
  (key === nothing || key in instruc.object.model.field_names) && return nothing
  return key
end
