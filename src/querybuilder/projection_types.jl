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
  # #1382: an alias over a JSON key lookup holds the key's value, text or a JSON scalar, not a document:
  # the JSON formatter refused every plain string compared with it. The comparisons bind as the key
  # lookup's own filter binds them (`_render_json_lookup_comparison`); any other operator, as given.
  _json_key_lookup_operand(source.field, instruc) && return nothing
  formatter = _expression_formatter(source.field, instruc)
  # #900: a `Sum`/`Avg` over an interval is an interval, not the number `_expression_formatter` names
  # for every sum, and `"total__@gt" => Hour(1)` raised a `MethodError` from the number formatter. The
  # SELECT renders first, so the projection's kind is known here: the value is checked as a duration,
  # as `Max("time")`'s alias checks it, so a number is refused rather than compared with the text.
  formatter === Models.format_number_sql &&
    get(instruc.projection_kinds, Symbol(alias[2]), nothing) isa CInterval && return Models.format_duration_sql
  return formatter
end

# #1168: the alias's `_expression_kind`, the evidence `_having_alias_formatter` cannot give — an integer,
# a float and a decimal all resolve to `format_number_sql`. Same two sources, in the same order: the
# column an alias projects, then the projected expression. #1183: a `Value(x)` alias is its literal's
# kind, as the walk types it anywhere else — `Value(1)` an integer, `Value(2.5)` a float.
function _having_alias_kind(alias::MemoKey, instruc::SQLInstruction)
  memoized = memo_field(instruc, alias)
  memoized === nothing || return _field_kind(memoized)
  source = _projected_source(alias, instruc)
  source === nothing && return nothing
  return _expression_kind(source, instruc)
end

# Functions whose result is text whatever their operands are, for the `When` condition check made at
# construction (`_function_condition_kind`, `filter_pairs.jl`), which has no instruction to walk. The
# formatter reads the same fact from their `_result_rule` (`CText()`, `functions.jl`). `Concat` — the
# one that takes `output_field` — refuses a non-text type when it is built (#835).
#
# `ToChar` (`EXTRACT_DATE`) is text too, but it is not listed: `PormGTypeField` types it, and that is
# checked first. #851 listed it here while the table keyed `TO_CHAR`, a name no node carries; #862
# keyed the table by the node's name instead, so the type has one home.
const _TEXT_OUTPUT_FUNCTIONS = ("LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM", "REPLACE", "CONCAT", "LPAD", "RPAD")

# #1070: a date part's formatter holds a value to the part's RANGE — an hour 0–23, a month 1–12, a
# `"YYYY-MM"` label. The range belongs to the part, not to an expression computed from it: `hour + 1`
# reaches 24, and `Coalesce("ts__@month", 0)` is 0 for a NULL date. Such an expression keeps the
# family (a number, a text) and drops the range.
_unranged(f) = f in Models.PERIOD_FORMATTERS ? Models.format_number_sql :
               f === Models.format_yyyy_mm   ? Models.format_text_sql : f

# #1034 step 4 — the formatter a value compared with this expression must satisfy, or `nothing` when
# its type cannot be named. Only a type that is KNOWN is returned — see `_having_alias_formatter`.
#
# It is a VIEW of the type walk: the formatter of the kind `_expression_kind` names (`_kind_formatter`,
# `expression_kind.jl`). Before, it was its own inference, with its own function lists, and it typed
# less than the walk: a `Case` with no `output_field`, a window value function and `Rank` had no
# formatter, a `Sum`/`Avg` of a duration was a number (#900 patched the alias binder for it), and a
# condition as an operand (`Max(Q(…))`) was untyped while the walk named it a boolean. What stays
# here is what is not a kind:
#
# - a node's own `formatter=` (a date part's range, `ToChar`), and a column's field, whose formatter
#   holds more than its kind (an array's element rules, a full-text vector);
# - a declared type (`Cast`, `output_field`), through its field: `_declared_type_formatter` knows that
#   SQLite renders a uuid or network cast as text;
# - a value that is one of its operands' own (`Max`, `Coalesce`, `Lag`, `NullIf`): the FIRST operand
#   that names a formatter decides, where the walk demands that every operand agree. A filter value
#   needs one to be checked by, and `Coalesce("finished", 5)` is checked as the first operand (#1034
#   proposal 2). A `Coalesce` may be its fallback, so it drops a date part's range (`_unranged`);
# - arithmetic the walk does not type (`Extract(x, "EPOCH")`, whose type is not stated, #1034 step
#   5a typed the temporal arithmetic): a number when its left side is one, and a `Sum`/`Avg` of it a
#   number, as before. A fallback, so no filter that checked its value stops checking it.
function _expression_formatter(p::SQLTypeFunction, instruc::SQLInstruction)
  p.formatter === nothing || return p.formatter
  name = p.function_name
  declared = get(p.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  if declared isa AbstractString
    formatter = _declared_type_formatter(declared, instruc)
    formatter === nothing || return formatter
  end
  if _result_rule(p) in (:operand, :one_of, :first_operand)
    for operand in (p.column isa AbstractVector ? p.column : (p.column,))
      formatter = _expression_formatter(operand, instruc)
      # `Max`/`Min` of a part is still that part; a `Coalesce` may be its fallback (`0`, `"n/a"`).
      formatter === nothing || return name in ("MAX", "MIN") ? formatter : _unranged(formatter)
    end
    return nothing
  end
  formatter = _kind_formatter(_expression_kind(p, instruc), instruc)
  formatter === nothing || return formatter
  return name in ("SUM", "AVG") ? Models.format_number_sql : nothing   # an operand the walk cannot type
end
# #576: a bare `F("col")` is the column. #707: arithmetic on a NUMBER stays a number; any other
# operation (`F("happened") + Day(1)`) keeps no type, rather than get the column's. #942, #949: a
# comparison is a boolean, which the walk names.
function _expression_formatter(p::FExpression, instruc::SQLInstruction)
  p.operation === nothing && return _expression_formatter(p.column, instruc)
  formatter = _kind_formatter(_expression_kind(p, instruc), instruc)
  formatter === nothing || return formatter
  # #1070: `Extract("start_at", "HOUR") + 1` is a plain number — it was one while `Extract` carried no
  # formatter. See `_unranged`. Only what the walk does not type reaches here (`Extract(…, "EPOCH")`).
  return _unranged(_expression_formatter(p.field_name, instruc)) === Models.format_number_sql ?
    Models.format_number_sql : nothing
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
# back as a `Bool` once this types it. A `Q`/`Qor` condition is one too, as an operand (`Max(Q(…))`,
# `Coalesce(Q(…), false)`), as the walk names it.
_expression_formatter(::Union{ExistsObject,SQLTypeQ,SQLTypeQor}, ::SQLInstruction) = Models.format_bool_sql
_expression_formatter(::Any, ::SQLInstruction) = nothing


# #965 — whether a value is a boolean only when ALL of its candidate values are: a `Bool` literal, or
# an expression `_expression_formatter` types as one. A NULL is no value and is skipped; NULLs alone
# are untyped. Every value must agree, as `_agreeing_kind` requires: PostgreSQL refuses a CASE or
# COALESCE mixing boolean and integer, and on SQLite the result would be a boolean on some rows and an
# integer on others, so a mixed one is no boolean to type. A string is a column path: the values are a
# `Coalesce`'s operands. (A `Case`'s branch values are typed by the walk, `_case_kind`.)
function _all_boolean(values, instruc::SQLInstruction)::Bool
  typed = false
  for value in values
    literal = value isa SQLText ? value.field : value
    _is_null_literal(literal) && continue
    boolean = literal isa Bool ||
      ((value isa Union{SQLObject,SQLType,AbstractString}) && !(value isa SQLText) &&
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
# every operand agrees (`_agreeing_kind`). `NULLIF(a, b)` returns `a` or NULL, so it is `a`.
#
# #1034: the read POLICY of the one walk in `expression_kind.jl`, where each of these rules is stated
# once; `_expression_kind` is the same walk asked for every kind.
_function_projection_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)::Union{CanonicalType,Nothing} =
  _infer_function_kind(p, instruc, _ReadKinds())
_function_projection_kind(::Any, ::SQLInstruction) = nothing

function _is_boolean_valued(p::FObject, instruc::SQLInstruction)
  # `_expression_formatter` takes the FIRST operand that names a type, which is right for a filter
  # value but would type `Coalesce("is_active", "points")` a boolean. A declared `output_field` is
  # the cast's type and decides alone.
  if _result_rule(p) === :one_of && !(get(p.kwargs, "output_field", nothing) isa AbstractString)
    return _all_boolean(p.column isa AbstractVector ? p.column : (p.column,), instruc)
  end
  return _expression_formatter(p, instruc) === Models.format_bool_sql
end
_is_boolean_valued(p::WindowFunction, instruc::SQLInstruction) =
  _result_rule(p) === :operand && _expression_formatter(p.column, instruc) === Models.format_bool_sql

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
#
# #1034: the read policy of the walk in `expression_kind.jl`.
_operand_kind(p, instruc::SQLInstruction) = _infer_kind(p, instruc, _ReadKinds())

# #1027 — a `Concat` operand that has no single text: `(kind, what)`, `kind` one of `:bool`, `:float`,
# `:decimal`, `:numeric`, or `nothing`. PostgreSQL's `CONCAT` writes each operand through its type's
# output function and SQLite's `||` through its own number formatting, on top of PormG's SQLite
# storage (a boolean is `0`/`1`, a decimal an integer or a REAL, #648): `true` reads `t` and `1`, a
# float `25` and `25.0`, a decimal `3.00` and `3`. #860/#876 refused these three as a TEXT value for
# that reason, and `Concat` makes text from its operands, so it refuses the same three as operands.
#
# Only a type that is KNOWN is answered, as everywhere in this file: an operand whose type cannot be
# named (a function PormG does not type, a `Case` whose branches are all such values) is let through,
# not guessed at. A `Case` with no `output_field` is known through its branch values (#1187,
# `_case_textless_branch`), and a `Subquery` through its one projection, which the inner build
# classified (#1124). Read
# after the operands render, so a joined path's field memo exists (`_alias_column_field`).
#
# #1028 adds three kinds, measured on PostgreSQL 16.15 and SQLite 3.45.1 through the F1 fixture:
# `:timestamp` (`2009-03-29 06:00:00+00` against the stored `2009-03-29T06:00:00.000+00:00`),
# `:interval` (PostgreSQL writes its `IntervalStyle`, `PT25.021S` on the test server, SQLite the
# stored `00:00:26.898`) and `:json` (`jsonb` re-renders `{"a": [1, 2]}`, SQLite keeps `{"a":[1,2]}`).
# A date, a time and a uuid read the same text on both, and pass. A CTE column is read from what its
# body recorded (`_cte_textless_record`): an integer quotient from the division record, otherwise the
# kind it means — an `Avg` column is a float, a decimal or an interval, as `Avg` is — ahead of the
# field the CTE model gives it, which can be narrower; a kind with one text falls to the field.
#
# `:numeric` is the functions PostgreSQL computes as `numeric` whatever the operand (`Dialect` casts
# each operand `::numeric`, and `avg` of an integer is numeric too) while SQLite answers a REAL:
# `Mod(7, 3)` reads `1` and `1.0`. Measured on SQLite 3.45.1 for #1027. They are the `:numeric`
# `_result_rule`s; the functions whose value has their operands' type are `_OPERAND_TYPED_RULES`
# (`functions.jl`, #1034). `FLOOR`/`CEIL`/`ABS` keep an integer operand's type on both engines (#1147),
# so they are `:promoting`, not `:numeric`. Over a whole number PormG does not type as an integer they
# are `numeric` on PostgreSQL, which agrees with SQLite's integer until divided, and that
# `_whole_numeric_operand` names (#1111): a division an engine departs on (`_untyped_sum_departs`).
function _concat_textless_operand(p, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  p isa SQLText && return _textless_literal(p.field)
  # A `Q(...)` / `Qor(...)` renders a predicate, which is a boolean.
  p isa Union{SQLTypeQ,SQLTypeQor} && return (:bool, "a Q(…) condition")
  # #1124: a `Subquery` answers what its one projected expression answers alone — the inner build
  # recorded it (`_subquery_projection_textless`). Read before the formatter and the kind below, so
  # the subquery agrees with the expression it wraps: `Avg(duration)` is `:interval` both ways, the kind
  # the walk gives it (#1034 step 5c). A node with no record — an inner projection with one text, or a
  # build that did not render the node — falls through, and the kind below still names a timestamp or
  # an interval.
  if p isa SubqueryObject
    recorded = _subquery_textless(p, instruc)
    recorded === nothing || return (recorded[1], "a Subquery projecting $(recorded[2])")
  end
  # A boolean column, a comparison, `Exists`, a boolean `Case`, an extremum over one: the one reader
  # that already types all of them.
  if p isa Union{SQLObject,SQLType,AbstractString}
    if _expression_formatter(p, instruc) === Models.format_bool_sql
      label = _concat_operand_label(p)
      label === nothing || return (:bool, "the BooleanField `$(label)`")
      # A function whose value is its operand's (`Lag`, `Max`) names the operand it is over.
      if p isa SQLTypeFunction && !(p.column isa AbstractVector) && p.column !== nothing
        inner = _concat_textless_operand(p.column, instruc)
        inner !== nothing && inner[1] === :bool && return (:bool, "`$(p.function_name)(…)` over $(inner[2])")
      end
      return (:bool, "a boolean expression")
    end
    recorded = _cte_textless_record(p, instruc)
    recorded === nothing || return recorded
    temporal = _textless_temporal(p, instruc)
    temporal === nothing || return _temporal_textless_named(temporal, p, instruc)
  end
  _undeclared_case(p) && return _case_textless_branch(p, instruc)
  return _textless_number(p, instruc)
end

# #1034 step 5c — an operand the walk types a timestamp or an interval, as the classifier names it. What
# the operand's structure answers (its branches, its function's operands, its arithmetic's sides) is
# read first, for two things the kind at the top cannot say:
# - an integer quotient the structure answers (`_DIVISION_KINDS`) answers as that division:
#   `Sum(…) / 2 * Max("laptime")` is an interval at the top, but PostgreSQL's `numeric` quotient keeps
#   the half its `bigint` sum drops on SQLite, so it stays refused there (#1111), as it was before this
#   step. The structure finds the quotient on whichever side it sits (`_division_first`, #1305):
#   `Max("laptime") * (Sum(…) / 2)` too. Only where the division departs (`_untyped_sum_departs`):
#   on another engine the value is the interval, and a cast of it to a number is refused there (#1259);
# - a function, or a `Case` with no `output_field`, is named by its structure when that names it
#   (`` `SUM(…)` over the DurationField `laptime` ``, `` `AVG(…)` ``), with the walk's kind: a column has
#   its own label, and arithmetic keeps "an interval expression", as the render's kind named it.
function _temporal_textless_named(temporal::Tuple{Symbol,String}, p, instruc::SQLInstruction)
  p isa Union{FExpression,FObject,WindowFunction} || return temporal
  named = _undeclared_case(p) ? _case_textless_branch(p, instruc) : _textless_number(p, instruc)
  named === nothing && return temporal
  named[1] in _DIVISION_KINDS && return _untyped_sum_departs(instruc.connection) ? named : temporal
  return p isa FExpression ? temporal : (temporal[1], named[2])
end

# #1187 — a `Case` with no `output_field` has one of its branch values on each row, so it has the text
# of a float, a decimal or a timestamp when one of its branches does: each `then` and the default is
# classified as an operand of its own, the first such branch answering for the `Case` (an integer
# quotient answering wherever it is, `_division_first`). A float branch
# makes it a `float8` on PostgreSQL (`Cast` to an integer rounds there and truncates on SQLite); a
# `DecimalField` branch keeps its own places, which the type walk drops (`_unify_kinds`), so a
# zero-scale one is whole here, as the column is. With an `output_field` the cast it renders decides
# (`_textless_number`), and that cast is checked against the branches (#1217, `_declared_case`).
_undeclared_case(p) = p isa FObject && p.function_name == "CASE" && !(get(p.kwargs, "output_field", nothing) isa AbstractString)
_declared_case(p) = p isa FObject && p.function_name == "CASE" && !_undeclared_case(p) && !isempty(p.kwargs["output_field"])
function _case_textless_branch(p::FObject, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  side = _division_first((_concat_textless_operand(value, instruc) for value in _case_values(p)), instruc.connection)
  return side === nothing ? nothing : (side[1], "`CASE(…)` over $(side[2])")
end
# #1305 — the answer of several sides, operands or branches. Every side is asked: before, the first
# that answered decided, so a quotient on another side was not found. An integer quotient the engines
# divide differently (`_DIVISION_KINDS`) answers wherever it sits, since its half reaches the value
# whatever the other sides are (`Max("laptime") * (Sum(…) / 2)` keeps it on PostgreSQL). Beside
# another answer it decides only where it departs (`_untyped_sum_departs`): elsewhere it divides as
# the expression means, and the other answer is still what the value is — an interval cast to a
# number is still refused on SQLite (#1259). Otherwise the first answer, so a message names what it
# always named.
function _division_first(answers, conn)::Union{Tuple{Symbol,String},Nothing}
  found, division = nothing, nothing
  for answer in answers
    answer === nothing && continue
    if answer[1] in _DIVISION_KINDS
      division === nothing && (division = answer)
    else
      found === nothing && (found = answer)
    end
  end
  return division === nothing ? found : found === nothing || _untyped_sum_departs(conn) ? division : found
end
# The values a `Case` can take: each branch's `then` and its default, NULLs left out (never the value).
# A raw value is a literal — a string too, not a path (`_case_kind`) — so it is wrapped as one.
function _case_values(p::FObject)
  values = Any[]
  for branch in (p.column isa AbstractVector ? p.column : (p.column,))
    branch isa SQLTypeFunction && branch.function_name == "WHEN" && push!(values, get(branch.kwargs, "then", nothing))
  end
  push!(values, get(p.kwargs, "else", nothing))
  return Any[v isa Union{SQLObject,SQLType} ? v : SQLText(v) for v in values if !_is_null_literal(v isa SQLText ? v.field : v)]
end

# #1200 — a value that is one of several operands' (`Coalesce`, `Greatest`, `Least`, `NullIf`, a `Case`
# with no `output_field`, a `Lag`/`Lead` and its `default`) over operands of two different temporal
# types, or of a temporal type and text, does not say which type it has. Measured with a `DateField`
# beside a zoned literal: PostgreSQL resolves `timestamptz` and reads every row as an instant, SQLite
# hands back each row's own text, and a text column beside one fails at the PostgreSQL server. That is
# explicit intent (#1147): refused on every engine, naming the spellings that say the type, as
# Django refuses mixed types without an `output_field`. A naive and a zoned timestamp are two types
# here, as the issue sets it. A number beside a number is not this rule's (#1150 normalizes it): an
# integer, a float and a decimal are one class, `:number`.
#
# #1327 — text beside a number is the same question. Measured: SQLite answers the row's own value
# (`MAX` by its type order, any text above any number), MySQL compares as strings (`GREATEST('10', 9)`
# is `'9'`) and returns a VARCHAR, PostgreSQL fails at the server. Refused on every engine, naming the
# `Cast` that says which one is meant.
#
# #1321 — and a number beside a date, a time, an interval or a UUID. PostgreSQL has no common type for
# them and fails at the server; SQLite returns whichever operand is not NULL, so `update("grid" =>
# Coalesce("grid", "racedate"))` stored the date's text in the INTEGER column. Every two classes that
# differ are a mix, as Django's `Expression contains mixed types` holds for any two field types, with
# one exception: a UUID beside text. SQLite and MySQL hold a UUID as its text and type a cast to `uuid`
# as text, so there the explicit spelling, `Coalesce("token", Cast(x, "uuid"))`, is text beside a
# UUID column; refusing the pair would refuse it on those engines only. They answer the UUID's text,
# its meaning, and PostgreSQL raises at the server for a text column beside one (the #1087
# tie-breaker). A boolean and a JSON value have no class here: a boolean beside a number is its own
# meaning question (#1147), and a JSON key's type is the data's.
#
# Typed by the walk (`_AllKinds`), after the operands render. An operand the walk cannot type, a NULL,
# and a kind of any other family are let through, and a conflict between two typed operands is refused
# whatever the untyped one is. `(class, what, literal)` names each side by its type and its label, never
# a value, and says whether it is a literal. No departure table is read; the walk's kinds are the
# engine's own, so a cast the engine renders as text (a uuid cast on SQLite) is text there.
_temporal_mix_class(::CDate) = :date
_temporal_mix_class(k::CDateTime) = k.with_timezone ? :timestamptz : :timestamp
_temporal_mix_class(::CTime) = :time
_temporal_mix_class(::CInterval) = :interval
_temporal_mix_class(::Union{CText,CVarChar}) = :text
_temporal_mix_class(::Union{CInt16,CInt32,CInt64,CFloat64,CDecimal}) = :number
_temporal_mix_class(::CUUID) = :uuid
_temporal_mix_class(::Any) = nothing
const _TEMPORAL_MIX_FUNCTIONS = ("COALESCE", "GREATEST", "LEAST", "NULLIF", "CASE", "LAG", "LEAD")

# The pairs of classes that are a mix: any two that differ (#1200, #1327, #1321), except a UUID beside
# text (above).
_is_mix(a::Symbol, b::Symbol) = a !== b && !(a in (:uuid, :text) && b in (:uuid, :text))
# #1327 — a declared `output_field` casts the value OUTSIDE the function (#852), so the engine still
# meets both operands inside it: PostgreSQL raises, MySQL's `GREATEST('10', 9)` compares as strings
# before the cast. It lifts the #1200 pairs, as it did; a pair with a number or a UUID side (#1321) is
# refused under one too, since the declaration would not make the engines agree.
_declaration_lifts(a::Symbol, b::Symbol) = !(:number in (a, b) || :uuid in (a, b))
_declares_mix_type(p::FObject) = get(p.kwargs, "output_field", nothing) isa AbstractString
_declares_mix_type(::WindowFunction) = false

"""
    _temporal_mix(p, instruc) -> Union{Tuple{Tuple{Symbol,String,Bool},Tuple{Symbol,String,Bool}}, Nothing}

The first two values of `p` (one of `_TEMPORAL_MIX_FUNCTIONS`) whose classes are a mix (`_is_mix`)
that its `output_field`, if it declares one, does not lift (`_declaration_lifts`), as
`((class, what, literal), …)`; or `nothing`. Read after `p`'s operands render.
"""
function _temporal_mix(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  p.function_name in _TEMPORAL_MIX_FUNCTIONS || return nothing
  # SQLite's NULL-skipping rotations of a `Greatest`/`Least` (`_null_skipping_operands`): that node
  # checks its own operands, under its own name.
  haskey(p.kwargs, "rotation_of") && return nothing
  declared = _declares_mix_type(p)
  sides = Tuple{Symbol,String,Bool}[]
  for value in _temporal_mix_values(p)
    class = _temporal_mix_class(_infer_kind(value, instruc, _AllKinds()))
    class === nothing && continue
    side = (class, _temporal_mix_label(value), value isa SQLText)
    for seen in sides
      _is_mix(seen[1], class) && !(declared && _declaration_lifts(seen[1], class)) && return (seen, side)
    end
    any(s -> s[1] === class, sides) || push!(sides, side)
  end
  return nothing
end
# The values the function can take. A `Case`'s branches and a window `default` hold a string as a text
# literal (`_case_values`, `_with_window_default`); the operands of the others hold it as a path.
function _temporal_mix_values(p::Union{FObject,WindowFunction})
  p.function_name == "CASE" && return _case_values(p)
  values = Any[]
  if p isa WindowFunction
    push!(values, p.column isa AbstractVector ? first(p.column) : p.column)
    default = get(p.kwargs, "default", nothing)
    default === nothing || push!(values, default isa Union{SQLObject,SQLType} ? default : SQLText(default))
  else
    append!(values, p.column isa AbstractVector ? p.column : (p.column,))
  end
  return Any[v isa Union{SQLObject,SQLType,AbstractString} ? v : SQLText(v) for v in values
             if !_is_null_literal(v isa SQLText ? v.field : v)]
end
function _temporal_mix_label(p::SQLText)
  t = string(nameof(typeof(p.field)))
  return "$(first(t) in "AEIO" ? "an" : "a") $(t) literal"
end
function _temporal_mix_label(p)
  label = _concat_operand_label(p)
  label === nothing || return "`$(label)`"
  p isa Union{FObject,WindowFunction} && return "`$(p.function_name)(…)`"
  return "an expression"
end

"""
    _check_temporal_mix(p, instruc)

Throws `_temporal_mix_refusal` when `_temporal_mix` finds two values of `p` whose types do not say
which one the value has (#1200, #1327), on every engine.
"""
function _check_temporal_mix(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  mix = _temporal_mix(p, instruc)
  mix === nothing || throw(_temporal_mix_refusal(p.function_name, mix...; declared = _declares_mix_type(p)))
  return nothing
end

# #1324 — a number function over a duration (`_operand_domain` without `:interval`) has no meaning on
# any engine, so it is refused on every one when the query is built, as `Abs` was (#900): PostgreSQL
# raised at the server, SQLite computed on the `HH:MM:SS` text (`Round` read `0.0`, `Sqrt` NULL), MySQL
# on the count of microseconds. Read after the operands render, from the type walk, so a column, a
# `Sum` of one, interval arithmetic and a CTE column holding one are all seen. An operand the walk
# cannot type is let through.
#
# #1387 — a date, a timestamp, a time and a UUID are not numbers either, under any number function,
# `Sum` and `Avg` included (their domain holds `:interval`, never these). PostgreSQL raised at the
# server (`round(date)` does not exist), SQLite computed on the stored text (a date's leading year
# digits), MySQL on the number a date's digits spell. Refused on every engine, as a duration is. Text
# and a JSON key lookup keep their own rules (#1061, #1279), and a boolean its own (#1386): neither
# kind is checked here.
function _check_operand_domain(p::FObject, instruc::SQLInstruction)
  domain = _operand_domain(p)
  domain === nothing && return nothing
  for x in (p.column isa AbstractVector ? p.column : (p.column,))
    _is_null_literal(x isa SQLText ? x.field : x) && continue
    kind = _expression_kind(x, instruc)
    if kind isa CInterval
      :interval in domain || throw(_duration_math_refusal(p.function_name, instruc.connection))
    elseif kind isa _NonNumberKind
      throw(_non_number_math_refusal(p.function_name, kind, _concat_operand_label(x), instruc.connection))
    end
  end
  return nothing
end
const _NonNumberKind = Union{CDate,CDateTime,CTime,CUUID}
_non_number_operand(x, instruc::SQLInstruction) = _expression_kind(x, instruc) isa _NonNumberKind
_check_operand_domain(::Any, ::SQLInstruction) = nothing
# The reason holds on every engine; the spelling it names is the engine's (`_duration_seconds_spelling`).
function _duration_math_refusal(function_name::AbstractString, conn)
  name = uppercasefirst(lowercase(function_name))
  remedy = if function_name == "ABS"
    "For the magnitude of a duration d, write Greatest(d, d * -1)."
  else
    spelling = _duration_seconds_spelling(conn)
    spelling === nothing ? "$(_backend_name(conn)) has no spelling for a duration's seconds." :
      "For a duration's seconds, write $(spelling), and apply `$(name)` to that."
  end
  return QueryBuildError("`$(name)` of a duration is not supported: a duration is not a number, so `$(name)` " *
                         "has no meaning over one on any engine (#1324). $(remedy)")
end
# #1387 — the same reason over a date, a timestamp, a time or a UUID. The remedy names the numbers a
# caller may mean: a calendar part (and the column's own `__@year` transform, when the operand is a
# column path with no transform of its own), a clock part, a day count between two dates, and the seconds where the engine's
# `EPOCH` reads that kind (`_extracts_epoch_of`). A UUID holds no number, so it names none.
function _non_number_math_refusal(function_name::AbstractString, kind::CanonicalType,
                                  label::Union{String,Nothing}, conn)
  name = uppercasefirst(lowercase(function_name))
  noun = _non_number_noun(kind)
  head = "`$(name)` of $(noun) is not supported: $(noun) is not a number, so `$(name)` has no meaning " *
         "over one on any engine (#1387)."
  kind isa CUUID && return QueryBuildError("$(head) A UUID holds no number to compute `$(name)` over.")
  letter = kind isa CTime ? "t" : "d"
  # A column path only: a handle (`CTE(…)`) or a path that already ends in a transform has none.
  transform = label === nothing || occursin('(', label) || occursin("__@", label) ? "" : ", or \"$(label)__@year\""
  spellings = String[]
  kind isa CTime || push!(spellings, "a calendar part (Extract(d, \"year\")$(transform))")
  kind isa CDate || push!(spellings, "a clock part (Extract($(letter), \"hour\"))")
  kind isa CDate && push!(spellings, "a day count (the difference of two DateFields, F(a) - F(b))")
  _extracts_epoch_of(conn, kind) &&
    push!(spellings, "its seconds since $(kind isa CTime ? "midnight" : "1970") (Extract($(letter), \"epoch\"))")
  return QueryBuildError("$(head) For a number from $(noun) $(letter), write $(join(spellings, ", ", ", or ")), " *
                         "and apply `$(name)` to that.")
end
_non_number_noun(::CDate) = "a date"
_non_number_noun(::CDateTime) = "a timestamp"
_non_number_noun(::CTime) = "a time"
_non_number_noun(::CUUID) = "a UUID"

# #1028 — a timestamp, an interval or a JSON document: each has a text of its own on each engine (the
# measurements above). The kind comes from the type walk (`_expression_kind`, #1034 step 5c): a column,
# a joined or CTE handle, a transform, a typed function (`Max("start_at")`, `Max("lap")`), and, since
# the walk types them (step 5a), `F` arithmetic over a timestamp or a duration and `Sum`/`Avg` of an
# interval. Before step 5c it came from `_operand_kind`, which names none of the last two, so only the
# render's kind caught them; that fallback was removed in #1304, once it no longer fired.
#
# A JSON operand is refused as the WHOLE document only. A key lookup (`"payload__driver"`) resolves to
# the same field, but renders `#>>` / `json_extract`, the value at that key. That value has one text
# when it is a string; a boolean or a nested value can still differ (`'true'` vs `1`), but PormG cannot
# know which a key holds, so a lookup is let through, as an operand of unknown type is.
function _textless_temporal(p, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  label = _concat_operand_label(p)
  kind = _expression_kind(p, instruc)
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
  # the same, so its kind says which: only the document records `CJSON` (`_build_cte_custom_model`).
  p isa CTEReference && !(_expression_kind(p, instruc) isa CJSON) && return false
  # The join walk records every key lookup it renders (`_render_json_lookup`); any other path to a
  # JSONField names the column. A handle whose path goes on past the column is let through.
  p isa String || occursin("__", p.path) && return false
  return !memo_json_lookup(instruc, p isa String ? memo_key(:base, p) : memo_key(p))
end
_json_document_operand(::Any, ::SQLInstruction) = false

# #1382: the other half — an operand that is a KEY LOOKUP into a JSONField (`F("payload__driver")`), the
# key's value rather than the document. Its field is the JSONField all the same (`_render_json_lookup`
# memoizes it so), so the field alone cannot tell the two apart; the record of rendered key lookups can,
# and for a CTE column the kind its body recorded (only the document records `CJSON`). Decided by that
# evidence, never as "not known to be the document": a handle `_json_document_operand` lets through is
# not thereby a key.
_json_key_lookup_operand(p::SQLField, instruc::SQLInstruction) = _json_key_lookup_operand(p.field, instruc)
_json_key_lookup_operand(p::FExpression, instruc::SQLInstruction) =
  p.operation === nothing && _json_key_lookup_operand(p.field_name, instruc)
_json_key_lookup_operand(p::String, instruc::SQLInstruction) =
  _alias_column_field(p, instruc) isa Models.sJSONField && memo_json_lookup(instruc, memo_key(:base, p))
_json_key_lookup_operand(p::JoinedReference, instruc::SQLInstruction) =
  _alias_column_field(p, instruc) isa Models.sJSONField && memo_json_lookup(instruc, memo_key(p))
_json_key_lookup_operand(p::CTEReference, instruc::SQLInstruction) =
  _alias_column_field(p, instruc) isa Models.sJSONField && !(_expression_kind(p, instruc) isa CJSON)
_json_key_lookup_operand(::Any, ::SQLInstruction) = false

# #1382: whether a projection alias holds a JSON key's value — what `filter("payload__driver" => …)`
# compares, through `_render_json_lookup_comparison`, for the operators that renders.
function _alias_projects_json_key(having_key::MemoKey, instruc::SQLInstruction)::Bool
  source = _projected_source(having_key, instruc)
  return source isa SQLTypeField && _json_key_lookup_operand(source.field, instruc)
end

# #1127, #1034 phase 3 step 2c — the classification of a CTE column, from what its body recorded:
# - an integer quotient an engine departs on (`_DIVISION_KINDS`), from the division record
#   (`CTEDivision`): the walk names no kind for it;
# - otherwise the column's kind as it means it (`_MeaningKinds`: the body's numeric read record, else
#   `cte["kinds"]`): a timestamp, an interval, a float, or a decimal with places or of no declared
#   width. Read before the field, which can be narrower than the kind: a `Case` takes its first
#   branch's field (a zero-scale `DecimalField` beside one with places), and an `Avg` of a zero-scale
#   decimal keeps its operand's. Named by the field that spells the kind.
# A kind that has one text (an integer, text, a date) and a JSON document are left to the column's
# own arms below. `nothing` for a path that hops on through the column (it ends at a real model field,
# which the field memo answers).
function _cte_textless_record(p::CTEReference, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  side = _cte_division(p, instruc, :quotient)
  side === nothing || return (side[1], "the CTE column `$(_concat_operand_label(p))` ($(side[2]))")
  occursin("__", p.path) && return nothing
  k = _infer_kind(p, instruc, _MeaningKinds())
  tag = k isa CDateTime ? :timestamp : k isa CInterval ? :interval : k isa CFloat64 ? :float :
        k isa CDecimal && k.scale != 0 ? :decimal : nothing
  tag === nothing && return nothing
  return (tag, "the $(_field_label(_kind_field(k))) `$(_concat_operand_label(p))`")
end
_cte_textless_record(p::SQLField, instruc::SQLInstruction) = _cte_textless_record(p.field, instruc)
_cte_textless_record(::Any, ::SQLInstruction) = nothing
# One of the CTE column's recorded division answers (`:divided` or `:quotient`), or `nothing`: no
# answer, a path past the column, or a CTE this query does not name.
function _cte_division(p::CTEReference, instruc::SQLInstruction, question::Symbol)
  occursin("__", p.path) && return nothing
  cte = get(instruc.object.ctes, p.name, nothing)
  divisions = cte === nothing ? nothing : get(cte, "divisions", nothing)
  divisions isa AbstractDict || return nothing
  record = get(divisions, p.path, nothing)
  return record === nothing ? nothing : getfield(record, question)
end

# #1028 — the declared casts a function renders: `Cast`'s type and the `output_field` of the three that
# apply theirs (`Dialect._output_field_cast`). `Case` casts its `output_field` too (`Dialect.CASE`),
# but its operands are its branch values (`_case_values`), not `v.column`, so it is not one of these:
# they are read without an `output_field` (#1187) and checked against one (#1217, `_declared_case`,
# after the default renders); `Concat` renders no cast (#835).
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
# integer literal, a type PormG cannot name, which is let through anyway). `/` is not among the
# operators: a quotient has a fraction, and over a `numeric` whole number only on PostgreSQL
# (`_whole_numeric_operand`, #1111).
function _integral_valued(p, instruc::SQLInstruction)
  if p isa FObject
    # #1111: rounding a quotient PostgreSQL computed as `numeric` and SQLite as an integer gives `8`
    # and `7`: the half to round exists on one engine only, so such an operand is not whole here.
    p.function_name in ("FLOOR", "CEIL") && return _divided_whole_operand(p, instruc) === nothing
    if p.function_name == "ROUND"
      precision = get(p.kwargs, "precision", 0)
      return precision isa Integer && precision == 0 && _divided_whole_operand(p, instruc) === nothing
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
# at `numeric(10,2)` is `1.56` and `1.555`. An unscaled `numeric` (or `"decimal"`; a `DecimalField`
# object declares its scale, #1221) keeps the value on both, and an array is not a number, so neither has a scale here.
# The name is `Dialect.cast_type_name`'s validated spelling, so the size is plain digits.
function _numeric_cast_scale(type_name::AbstractString)::Union{Int,Nothing}
  size = _numeric_cast_size(type_name)
  return size === nothing ? nothing : size[2]
end
# `(p, s)` of a sized numeric type, or `nothing`; `numeric(p)` has scale 0.
function _numeric_cast_size(type_name::AbstractString)::Union{Tuple{Int,Int},Nothing}
  # `dec` is PostgreSQL's third spelling of `numeric` (its grammar's `DEC opt_type_modifiers`).
  m = match(r"^(?i:numeric|decimal|dec)\((\d+)(?:,(\d+))?\)$", type_name)
  m === nothing && return nothing
  # PostgreSQL takes a precision and a scale of at most 1000 and rejects the type otherwise. The name
  # may be request input, and `_precision_overflow_operand` sizes a BigInt by it, so a larger size
  # reads as 1001 — past the bound — rather than parsed (`numeric(99999999999999999999)` overflowed
  # `parse`). The scale rule still sees the declared scale; the overflow check leaves 1001 to the server.
  bounded(c) = ncodeunits(c) > 4 ? 1001 : min(parse(Int, c), 1001)
  return (bounded(m.captures[1]), m.captures[2] === nothing ? 0 : bounded(m.captures[2]))
end
# #1215 — whether a declared type is PostgreSQL's 4-byte float: `real`, `float4`, or `float(p)` for
# 1 ≤ p ≤ 24, which PostgreSQL resolves to `real` (`float(25)` to `float(53)` is a double).
function _single_precision_cast(type_name::AbstractString)::Bool
  occursin(r"^(?i:real|float4)$", type_name) && return true
  m = match(r"^(?i:float)\((\d+)\)$", type_name)
  m === nothing && return false
  # Leading zeros are the same precision to PostgreSQL (`float(0024)` is `real`); a long digit string
  # is past 53, which PostgreSQL rejects, so it is not parsed.
  digits = lstrip(m.captures[1], '0')
  return 1 <= ncodeunits(digits) <= 2 && parse(Int, digits) <= 24
end

# #1087 — a literal `Cast` operand that does not fit `numeric(p, s)`: rounded to `s` places, it has
# more than `p − s` digits before the point (`100`, or `9.999`, which rounds to `10.00`, at
# `numeric(3,2)`). PostgreSQL raises a numeric field overflow and SQLite stores the value as it is,
# so by the #1087 tie-breaker SQLite departs (a silent different answer); PostgreSQL's error is the
# meaning, left to raise when the query runs (`_MEANING_DEPARTURES`).
# Only a literal is certain to overflow: a column or a computed value overflows on the rows that
# hold a large value and not on the others, which nothing can know before the query runs. That is
# why `Coalesce`/`Greatest`/`Least` are not checked either: their literal is one candidate value.
#
# `(kind, what)` names the literal by its type and its digit count, never its value (#971).
function _precision_overflow_operand(p, precision::Int, scale::Int)::Union{Tuple{Symbol,String},Nothing}
  x = p isa SQLField ? p.field : p isa FExpression && p.operation === nothing ? p.field_name : p
  x isa SQLText && (x = x.field)
  value = _literal_exact_value(x)
  value === nothing && return nothing
  # Half away from zero, as PostgreSQL's `numeric` rounds; the magnitude decides, so the sign is dropped.
  rounded = floor(BigInt, abs(value) * big(10)^scale + 1//2)
  rounded < big(10)^precision && return nothing
  whole = rounded < big(10)^scale ? 0 : ndigits(rounded ÷ big(10)^scale)
  type = string(nameof(typeof(x)))
  article = first(type) in "AEIO" ? "an" : "a"   # `a UInt8`: the U is said "you"
  return (:overflow, "$(article) $(type) literal with $(whole > 2000 ? "more than 2000 digits" : _digit_count(whole)) before the point")
end
_digit_count(n::Integer) = n == 1 ? "1 digit" : "$(n) digits"
# The exact value each engine is handed, or `nothing` for a literal this does not read. A `Float64`
# is the value PostgreSQL converts `float8` to: 15 significant digits (`%.15g`, as its `float8_numeric`
# does). A `Float32` or `Float16` binds as `double precision` on PostgreSQL and a REAL on SQLite,
# so it is read as the `Float64` it widens to, exactly.
_literal_exact_value(::Bool) = nothing
_literal_exact_value(x::Integer) = Rational{BigInt}(x)
function _literal_exact_value(x::Float64)
  isfinite(x) || return nothing
  m = match(r"^-?(\d)\.(\d+)e([+-]\d+)$", Printf.@sprintf("%.14e", x))
  mantissa, exponent = parse(BigInt, m.captures[1] * m.captures[2]), parse(Int, m.captures[3]) - length(m.captures[2])
  return exponent >= 0 ? Rational{BigInt}(mantissa * big(10)^exponent) : mantissa // big(10)^(-exponent)
end
_literal_exact_value(x::Union{Float16,Float32}) = _literal_exact_value(Float64(x))
function _literal_exact_value(x::Decimals.Decimal)
  iszero(x.c) && return big(0) // 1
  # The exponent is the caller's (a bound value may be request input), so it is bounded before a
  # BigInt is sized by it. A precision and a scale are at most 1000 (`_numeric_cast_size`), so past
  # 2000 digits either way the answer is decided: an overflow above, a zero below.
  x.q > 2000 && return (iszero(x.s) ? 1 : -1) * big(10)^2001 // 1
  x.q + ndigits(x.c) < -2000 && return big(0) // 1
  magnitude = x.q >= 0 ? Rational{BigInt}(big(x.c) * big(10)^x.q) : big(x.c) // big(10)^(-x.q)
  return iszero(x.s) ? magnitude : -magnitude
end
_literal_exact_value(::Any) = nothing

# #1040 — an operand of a cast to `numeric(p, s)` that can carry more than `s` fractional digits, as
# `(kind, what)`, or `nothing` when PostgreSQL's rounding cannot change it. Rounding first is the
# escape: `Round(x, d)` has at most `d` places on both engines, so it passes a scale of at least `d`.
# The engines can round a tie apart (`ROUND(x::numeric, 2)` rounds the decimal form, SQLite's `ROUND`
# the double: `2.675` is `2.68` and `2.67`), a last-digit difference #1061 follows Django on rather
# than refusing. `Round(x)`, `Floor` and `Ceil` agree (every `Result.points` row, ±0.5, ±1.5, ±2.5),
# so a whole number passes any scale. `_render_function_body` asks this classifier of `Round(x, d)`
# itself only to refuse text, which neither engine rounds the same way.
#
# A literal is named by its type and its digits, never its value: it is a bound value, and a refusal
# never prints one (#971).
#
# Bounded: a whole number (`_integral_valued`, and any operand with no fractional kind — an integer
# column, a type PormG cannot name), a `DecimalField` column of at most `s` places, a `Decimal`
# literal of at most `s` digits, a `Float64` literal whose shortest form has at most `s` places
# (#1050: `1.5` at scale 2 reads `1.5` on both engines, there is nothing to round), and a nested cast
# to a scale of at most `s`. Unbounded: a float column, a float literal with more places, a `numeric`
# function, a decimal of unknown scale, and text — PostgreSQL
# parses `'1.555'` and rounds it, SQLite converts it and keeps it — including a JSON value. A `Case`
# with no `output_field` is read branch by branch (#1187); an operand PormG cannot type (a JSON key
# lookup) passes, as it does for #1028; a `Subquery` is read as its projection (#1124).
const _SCALE_PRESERVING_FUNCTIONS = ("MAX", "MIN", "ABS", "COALESCE", "GREATEST", "LEAST", "NULLIF")
function _scale_divergent_operand(p, scale::Int, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing}
  _integral_valued(p, instruc) && return nothing
  operand = p isa SQLField ? p.field : p isa FExpression && p.operation === nothing ? p.field_name : p
  if operand isa SQLText
    x = operand.field
    x isa AbstractString && return (:text, "a string literal")
    if x isa Float64 && isfinite(x)
      places = _float_literal_places(x)
      return places <= scale ? nothing : (:float, "a Float64 literal with $(places) decimal places")
    end
    # Ahead of the float line below: a `Decimal` is an `AbstractFloat`, and Base's `isinteger` for one
    # answers `true` for `Decimal(0, 1, -30)` (1e-30), which let it past the scale (#1087's review).
    if x isa Decimals.Decimal
      iszero(x.c) && return nothing   # `0.00000` is zero on both engines, whatever its exponent
      digits = _decimal_scale(x)
      return digits <= scale ? nothing : (:decimal, "a Decimal literal with $(digits) decimal places")
    end
    # Another float type binds through its own type, which was not measured: a whole one passes, as a
    # whole number does anywhere here, and a fraction is refused below.
    x isa AbstractFloat && isinteger(x) && return nothing
  end
  if operand isa Union{String,JoinedReference,CTEReference}
    field = _alias_column_field(operand, instruc)
    # A JSON value is text to PostgreSQL's cast (`#>>` returns text, and `jsonb::numeric` parses the
    # scalar), which rounds it; SQLite's `json_extract` hands over the number, which keeps every digit.
    field isa Models.sJSONField && return (:text, "the JSONField `$(_concat_operand_label(operand))`")
  end
  # A `DecimalField` column and a nested declaration (a `Cast`, an `output_field`) carry their scale
  # in the type walk, `CDecimal(p, s)` (#1034 phase 3 step 2b); a decimal of no declared width is read
  # below. Only these two: an extremum's scale is read operand by operand further down, which names
  # the column it comes from. A CTE column is the first (#1034 phase 3 step 2c): its kind is its body
  # expression's, so a `DecimalField(10,2)` path or a `numeric(10,1)` cast in the body keeps its scale
  # through the CTE (`cte["kinds"]`), and a decimal the body computes has none.
  declared = operand isa FObject ? _declared_cast(operand) : nothing
  if operand isa Union{String,JoinedReference,CTEReference} || (declared isa AbstractString && !isempty(declared))
    k = _expression_kind(operand, instruc)
    if k isa CDecimal && k.scale !== nothing
      k.scale <= scale && return nothing
      return declared === nothing ?
        (:decimal, "the DecimalField `$(_concat_operand_label(operand))` ($(k.scale == 1 ? "1 decimal place" : "$(k.scale) decimal places"))") :
        (:decimal, "a value cast to $(declared)")
    end
  end
  # #1061: `Round(x, d)` has at most `d` places on both engines, whatever its operand, so it passes a
  # scale of at least `d`; a wider `d` is still a `numeric` function's value, read below.
  if operand isa FObject && operand.function_name == "ROUND"
    d = get(operand.kwargs, "precision", 0)
    # #1111: unless what it rounds is an integer division, which has no places on SQLite at all.
    d isa Integer && 0 < d <= scale && _divided_whole_operand(operand, instruc) === nothing && return nothing
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
  # #1187: a `Case` with no `output_field` is one of its branch values on each row, so each `then` and
  # the default is read as an operand of its own, before the shared classifier below: it would name
  # `then = 1.5` a float at any scale, where #1050 bounds a float literal by its own places, and a
  # `DecimalField` branch keeps its places only here (the type walk drops them).
  if _undeclared_case(operand)
    for x in _case_values(operand)
      side = _scale_divergent_operand(x, scale, instruc)
      side === nothing || return (side[1], "`CASE(…)` over $(side[2])")
    end
    return nothing
  end
  # A cast to an integer or a float is typed here too (`_textless_number` reads its declared type). A
  # boolean, a timestamp or an interval is not rounded: PostgreSQL has no cast from one to `numeric`.
  side = _concat_textless_operand(p, instruc)
  side !== nothing && side[1] in _FRACTIONAL_KINDS && return side
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
# #1050 — the places a float literal's shortest decimal form needs after the point: `1.5` needs 1,
# `2.675` 3, `1.0e-5` 5, `1.0e20` none. That form is the value SQLite keeps. PostgreSQL converts
# `float8` to `numeric` at 15 significant digits first (`12345678901234.56` becomes
# `12345678901234.6`), a difference in the 16th digit where PostgreSQL is the less exact side: the
# representation, documented beside `Round`'s tie rather than refused (#1087, #1147).
function _float_literal_places(x::Float64)::Int
  m = match(r"^-?(\d+)(?:\.(\d+))?(?:e(-?\d+))?$", string(x))
  frac = rstrip(something(m.captures[2], ""), '0')
  exponent = m.captures[3] === nothing ? 0 : parse(Int, m.captures[3])
  return max(0, length(frac) - exponent)
end
_text_operand_label(p) = (l = _concat_operand_label(p); l === nothing ? "a text expression" : "the text column `$(l)`")

# #1028 — a declared cast over an operand on which the connection's engine departs from what the cast
# means (#1147 step 2, `_MEANING_DEPARTURES`): `(kind, what, target, flag, declared, row)`, or
# `nothing` — the cast builds as written. The operand is classified once, and the table decides who
# departs. (One fact the classifier reads itself: where an integer quotient sits beside an interval
# or a fraction, it answers only on an engine whose untyped sum departs, `_division_first`, #1305.)
# - to text: a boolean's text is `true`/`false`, which SQLite (`1`/`0`) departs from. A float, a
#   decimal, a timestamp, an interval or a JSON document is written in each engine's own text — the
#   same value, so no row, and the cast builds everywhere;
# - to an integer: a fractional number means the nearest integer, and SQLite's cast truncates (`1.5`
#   is `1`). A boolean is `1`/`0` on both, and passes;
# - `:integer` and `:number` (#1259): an interval is no number, so its cast to any number type is an
#   error, and SQLite reads its stored text's hours;
# - `:number` over a boolean (#1319): a boolean is a number only as the integer `1` / `0`, so its cast
#   to a float or a `numeric` is an error, which SQLite and MySQL compute from the integer they store;
# - `:scale` (#1040): a `numeric(p, s)` cast over an operand with more than `s` fractional digits
#   (`_scale_divergent_operand`) means the value rounded to `s`; SQLite keeps every digit;
# - `:precision` (#1087): a literal `Cast` operand too large for `p` (`_precision_overflow_operand`)
#   overflows; SQLite stores it as it is;
# - an integer quotient PostgreSQL computes with a fraction (`_DIVISION_KINDS`) departs there under
#   every target it lists.
#
# The OPERAND is classified, not the node: the node's own declared type is what makes it a text or an
# integer, which `_textless_number` reads as an acceptable `Concat` operand once this has passed it.
_declared_cast_label(v::FObject) = v.function_name == "CAST" ? "Cast(…, \"$(v.kwargs["type"])\")" :
  "$(uppercasefirst(lowercase(v.function_name)))(…; output_field = \"$(v.kwargs["output_field"])\")"
#
# Each operand's type is the walk's. Until #1304 the kind its render computed was read where the
# classifier named none; since #1034 step 5c the classifier reads temporal arithmetic and
# `Sum(duration)` from the walk, and that fallback no longer fired over the unit suite.
# A declared `Case` (#1217) is cast as each row takes a branch, so its operands are its branch values.
function _cast_divergent_operand(v::FObject, instruc::SQLInstruction)
  declared = get(v.kwargs, v.function_name == "CAST" ? "type" : "output_field", nothing)
  (declared isa AbstractString && !isempty(declared)) || return nothing
  operands = v.function_name == "CASE" ? _case_values(v) : v.column isa AbstractVector ? v.column : (v.column,)
  conn = instruc.connection
  # #1147 step 2: an operand is refused only on the engine that departs from what the cast means
  # (`_departure`); the others build it as written. A divergence that is only each engine's text is
  # no departure at all, so it has no row and builds everywhere.
  departs(kind, what, target, flag) = (row = _departure(conn, target, kind);
    row === nothing ? nothing : (kind = kind, what = what, target = target, flag = flag, declared = declared, row = row))
  # #1215: a single-precision target rounds whatever it casts, so the node is checked once, not per
  # operand. On an engine that keeps single precision the operands are still read below: a date or an
  # interval is no number whatever the float's width (#1259, #1260), and MySQL reads the digits of one
  # (`CAST(DATE '2009-03-29' AS FLOAT)` is `20090329`). The other rules below do not apply to a float.
  if _single_precision_cast(declared)
    d = departs(:value, "any value", :single_precision, "<flag>")
    d === nothing || return d
  end
  size = _numeric_cast_size(declared)
  target = _sql_type_field(declared)
  # #1259: an interval is no number, whatever number the target is: an integer, a float, a `numeric`,
  # scaled or not; nor is a date, a time or a timestamp (#1260). Checked ahead of the number rules,
  # which read a fraction, not a duration or a date.
  if size !== nothing || target isa Union{Models.sIntegerField,Models.sBigIntegerField,Models.sFloatField,Models.sDecimalField}
    numeric_target = target isa Union{Models.sIntegerField,Models.sBigIntegerField} ? :integer : :number
    for operand in operands
      side = _temporal_number_operand(operand, instruc)
      side === nothing || (d = departs(side[1], side[2], numeric_target, _concat_flag(operand)); d === nothing || return d)
      # #1319: a boolean is a number only as an integer; its cast to a float or a `numeric` is no value.
      numeric_target === :number || continue
      side = _concat_textless_operand(operand, instruc)
      (side !== nothing && side[1] === :bool) || continue
      d = departs(:bool, side[2], :number, _concat_flag(operand))
      d === nothing || return d
    end
  end
  # #1040: a scaled numeric target rounds on PostgreSQL only.
  if size !== nothing
    precision, scale = size
    for operand in operands
      # #1087: a literal that overflows the precision, checked first — it fails on PostgreSQL
      # whatever its scale. A `Cast` only: an `output_field` literal is one candidate value.
      if v.function_name == "CAST" && precision <= 1000 && scale <= 1000   # past the bound PostgreSQL rejects the type
        side = _precision_overflow_operand(operand, precision, scale)
        side === nothing || (d = departs(side[1], side[2], :precision, _concat_flag(operand)); d === nothing || return d)
      end
      side = _scale_divergent_operand(operand, scale, instruc)
      side === nothing || (d = departs(side[1], side[2], :scale, _concat_flag(operand)); d === nothing || return d)
    end
    return nothing
  end
  to_integer = target isa Union{Models.sIntegerField,Models.sBigIntegerField}
  (to_integer || target isa Union{Models.sCharField,Models.sTextField}) || return nothing
  for operand in operands
    to_integer && _integral_valued(operand, instruc) && continue
    side = _concat_textless_operand(operand, instruc)
    # #1151: an operand the classifier leaves untyped is read through the type walk, which names a
    # float `float8` on PostgreSQL, whose cast rounds where SQLite's truncates. A `Case` is classified
    # branch by branch above since #1187 (`_case_textless_branch`), which also reads a decimal branch's
    # places — the walk drops them; this stays the fallback for a float the classifier cannot name.
    # The whole-number functions passed above.
    if side === nothing && to_integer && _expression_kind(operand, instruc) isa CFloat64
      side = (:float, operand isa Union{FObject,WindowFunction} ? "`$(operand.function_name)(…)` with a float value" : "a float value")
    end
    side === nothing && continue
    to_integer && !(side[1] in _FRACTIONAL_KINDS) && continue
    d = departs(side[1], side[2], to_integer ? :integer : :text, _concat_flag(operand))
    d === nothing || return d
  end
  return nothing
end
# #1259 — an operand that is an interval, as `(kind, what)`, or `nothing`: one the classifier names
# (a `DurationField` column, its `Sum` and `Avg`, a duration literal, and since #1034 step 5c temporal
# arithmetic and a `Sum` of it), or one whose meaning is an interval though the classifier tags it
# otherwise (`_MeaningKinds`): a function PostgreSQL computes as a `numeric` (`:numeric`) whose meaning
# is an interval, `Round(Avg("laptime"))` or `Sqrt("laptime")`, keeps the classifier's name. A
# timestamp is not this rule's.
function _interval_operand(operand, instruc::SQLInstruction)
  side = _concat_textless_operand(operand, instruc)
  side !== nothing && side[1] === :interval && return side
  if side === nothing || side[1] === :numeric
    _infer_kind(operand, instruc, _MeaningKinds()) isa CInterval &&
      return (:interval, side === nothing ? "an interval expression" : side[2])
  end
  return nothing
end
# #1260 — an operand cast to a number that is an interval (`_interval_operand`) or a date, a time or a
# timestamp, as `(kind, what)`, or `nothing`. SQLite stores each as text, and its cast reads the
# text's leading digits: a date's year, a time's hour. The kind comes from the type walk (a column, a
# CTE column, `Max("date")`, `Cast(x, "date")`, a literal, and since #1034 step 5a date arithmetic,
# `F("date") + Day(1)`). A part (`@year`, `Extract`) and a day count (`F("date") - F("date")`) are
# numbers, and pass.
function _temporal_number_operand(operand, instruc::SQLInstruction)
  side = _interval_operand(operand, instruc)
  side === nothing || return side
  kind = operand isa Union{Dates.TimeType,ZonedDateTime} ? literal_canonical_kind(operand) :
         _infer_kind(operand, instruc, _MeaningKinds())
  tag = kind isa CDate ? :date : kind isa CTime ? :time : kind isa CDateTime ? :timestamp : nothing
  tag === nothing && return nothing
  literal = operand isa SQLText ? operand.field : operand
  literal isa Union{Dates.TimeType,ZonedDateTime} && return (tag, "a $(nameof(typeof(literal))) literal")
  label = _concat_operand_label(operand)
  label === nothing && return (tag, "a $(tag === :timestamp ? "timestamp" : String(tag)) expression")
  field = tag === :date ? "DateField" : tag === :time ? "TimeField" : "DateTimeField"
  return (tag, "the $(field) `$(label)`")
end
# A literal is named by its type, never its value: it is a bound value, and a refusal never prints
# one (#971). Every label built over this one inherits it (`arithmetic over a Float64 literal`), so
# printing the value here leaked it through `Concat`, `Cast` and `Round` alike (#1057).
_textless_literal(::Bool) = (:bool, "a Bool literal")
_textless_literal(x::AbstractFloat) = (:float, "a $(typeof(x)) literal")
_textless_literal(::Decimals.Decimal) = (:decimal, "a Decimal literal")
# #1028: PostgreSQL binds a timestamp as `$1::timestamp` and writes `2009-03-29 06:00:00`, SQLite binds
# the stored text `2009-03-29T06:00:00.000+00:00`; a duration is an `interval` on one and the
# `HH:MM:SS` text on the other. A `Date` and a `Time` bind the same text on both, and pass.
_textless_literal(x::Union{DateTime,ZonedDateTime}) = (:timestamp, "a $(nameof(typeof(x))) literal")
_textless_literal(::Union{Dates.Period,Dates.CompoundPeriod,Interval}) = (:interval, "a duration literal")
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
  # #1087: a zero-scale DecimalField holds whole numbers, which read `14` on both engines, as an
  # integer column's do.
  field isa Models.sDecimalField && field.decimal_places > 0 &&
    return (:decimal, "the DecimalField `$(_concat_operand_label(p))`")
  return nothing
end
_textless_number(p::SQLField, instruc::SQLInstruction) = _textless_number(p.field, instruc)
function _textless_number(p::FExpression, instruc::SQLInstruction)
  p.operation === nothing && return _textless_number(p.field_name, instruc)
  side = _division_first((_textless_number(p.field_name, instruc), _textless_number(p.operand, instruc)), instruc.connection)
  if p.operation == "/" && side === nothing
    # #1111: a whole number that PostgreSQL types `numeric` reads like an integer column until it is
    # divided: PostgreSQL's `numeric / int` is `7.5` where SQLite divides its integer as an integer.
    # A float on the other side (`x / 2.0`, `x / Avg(…)`) makes SQLite divide as floats too, and
    # PostgreSQL's `numeric / float8` is a float: no engine drops the fraction.
    left, right = _whole_numeric_operand(p.field_name, instruc), _whole_numeric_operand(p.operand, instruc)
    real(x, side) = side === nothing && (k = _concat_textless_operand(x, instruc); k !== nothing && k[1] in (:float, :numeric))
    side = left !== nothing && !real(p.operand, right) ? left :
           right !== nothing && !real(p.field_name, left) ? right : nothing
    # #1150: a quotient the walk names a decimal or a float is one on every engine — SQLite casts its
    # dividend to REAL (`_division_sql`) — so it reads as the number it is: a zero-scale decimal, a
    # whole one to every other rule, has a fraction once divided.
    if side === nothing
      kind = _operation_kind(p, instruc, _AllKinds())
      kind isa CDecimal && return (:decimal, "a decimal quotient")
      kind isa CFloat64 && return (:float, "a float quotient")
    end
  end
  return side === nothing ? nothing : (side[1], "arithmetic over $(side[2])")
end
# #1111 — an operand that is a whole number on both engines but whose quotient PostgreSQL computes
# as a `numeric`: its `(kind, what)`, the `:numeric_whole_division` kind (`_INTEGER_QUOTIENT_DEPARTURE`).
# Read only under `/` (above): under `+`, `-`, `*` and in a bare cast the whole number is the same on
# both. The functions whose value has an operand's type carry it, as arithmetic does
# (`Max(Abs("n")) / 2`, `(Floor("n") + 1) / 2`). (A decimal quotient, and a value mixing whole numbers
# with fractions, was SQLite's departure until #1150: SQLite now divides them as REAL, `_division_sql`.)
# - `FLOOR`, `CEIL`, `ABS` (#1111) over a whole number: over an integer they keep it on both engines
#   (#1147, `_integer_operand_kind`), so `Floor("grid") / 2` divides as an integer on both. Over a
#   whole number the walk does not name an integer, they rendered `FLOOR((x)::numeric)`, a quotient
#   PostgreSQL kept the half of; since #1157 a whole number IS one the walk names an integer
#   (`_integer_operand_kind`), so that case is gone, and the function only carries its operand's answer;
# - `SUM` of an operand the type walk cannot type at all (#1111, #1141): PostgreSQL's `sum(bigint)` is
#   `numeric`. Every `bigint` the walk names — a BIGINT column, an integer literal (bound
#   `$n::bigint`), an integer `Case` or `Coalesce`, integer, bitwise or shifted arithmetic — renders
#   `SUM(x)::bigint` there since #1147 step 2 (`_sums_bigint`), an integer on both engines, and a sum
#   the walk names otherwise (`Sum(F("id") + F("points"))`, a `float8`) is no integer quotient (#1157).
#   What remains is a sum the walk cannot type, `:numeric_whole_division`: its type is unknown, so it
#   fails closed on an engine where such a sum departs (#1034 phase 3 step 2a). Until then a separate
#   classifier looked inside it for a `bigint` and let the rest through.
# A CTE column built from any of these answers as it did in the body (#1127), and so does a
# `Subquery` projecting one (#1124): each is a record the inner build kept, not its typed field.
# Measured on PostgreSQL 16 and SQLite 3.45 through the F1 fixture: `Floor("grid") / 2` over grid
# 1, 5, 7 read `0.5`, `2.5`, `3.5` and `0`, `2`, `3` before #1147; `Sum("resultid") / 2` over two rows
# `1.5` and `1` before #1147 step 2. The refusal names the division, not a decimal's text, and advises
# saying which division is meant (`_INTEGER_QUOTIENT_DEPARTURE`): rounding afterwards cannot bring the half back.
const _NUMERIC_WHOLE_FUNCTIONS = ("FLOOR", "CEIL", "ABS")
# #1196 — the functions that keep an integer operand that integer on every engine (`integer_kind`,
# `_integer_operand_kind`): the three above, and `Round`, whose places add nothing to an integer (a
# negative precision is refused when the expression is built, #1044). `Round` is not one of the three:
# over any other operand it is a `numeric` function's value, not its operand's, so it carries no
# operand's division answer (`_whole_numeric_operand`).
const _INTEGER_KEEPING_FUNCTIONS = (_NUMERIC_WHOLE_FUNCTIONS..., "ROUND")
# The division by the engine that departs from the quotient the expression means
# (`_untyped_sum_departs`): an integer quotient PostgreSQL computes as a `numeric` (a `Sum` the walk
# cannot type, which may be a `sum(bigint)`), a number with a fraction
# there only.
const _DIVISION_KINDS = (:numeric_whole_division,)
const _FRACTIONAL_KINDS = (:float, :decimal, :numeric, _DIVISION_KINDS...)
# #1127 — a CTE column answers as its body's expression did, recorded while the body built
# (`CTEDivision`): its field cannot say it, since a `Sum` column is typed as an integer whatever it
# sums, and its kind cannot either. A column with no answer — a plain path, a body not built in this
# pass — has none.
function _whole_numeric_operand(p::CTEReference, instruc::SQLInstruction)
  side = _cte_division(p, instruc, :divided)
  return side === nothing ? nothing : (side[1], "the CTE column `$(_concat_operand_label(p))` ($(side[2]))")
end
_whole_numeric_operand(p::SQLField, instruc::SQLInstruction) = _whole_numeric_operand(p.field, instruc)
_whole_numeric_operand(p::FExpression, instruc::SQLInstruction) =
  something(_whole_numeric_operand(p.field_name, instruc),
            p.operation === nothing ? nothing : _whole_numeric_operand(p.operand, instruc), Some(nothing))
function _whole_numeric_operand(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  name = p.function_name
  # A declared type is the cast the SQL renders, so it decides alone. (A declared decimal over an
  # integer, divided, was SQLite's departure until #1150: its kind is a decimal, which SQLite now
  # divides as REAL, `_division_sql`.) `Coalesce`/`Greatest`/`Least` always carry the key.
  declared = get(p.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  declared isa AbstractString && !isempty(declared) && return nothing
  if name in _NUMERIC_WHOLE_FUNCTIONS
    # Over a whole number BY TYPE only. An operand PormG cannot type (an untyped `Case`, a JSON key
    # lookup) is let through, not guessed at: a float under `FLOOR` is a REAL on SQLite, which
    # divides as one, so the engines agree there and the integer answer would be a false refusal.
    operand = p.column isa AbstractVector ? first(p.column) : p.column
    # #1147: over an integer the function is that integer on both engines, so it is `numeric` on
    # PostgreSQL only when its operand is. Asked first, because the operand's integer kind is the one
    # fact that differs per engine here, and its answer is the same on both.
    side = _whole_numeric_operand(operand, instruc)
    return side === nothing ? nothing : (side[1], "`$(name)(…)` over $(side[2])")
  end
  # (A value that is one of several, some whole and some fractional — `Coalesce("grid", 0.5)`, a `Case`
  # with an integer and a float branch, a window's fractional `default` — was SQLite's departure until
  # #1150: the walk names it a float, which SQLite now divides as REAL, `_division_sql`.)
  _result_rule(p) in _OPERAND_TYPED_RULES || return nothing
  for operand in (p.column isa AbstractVector ? p.column : (p.column,))
    # #1147 step 2: a `Sum` the walk names a `bigint` renders `::bigint` on PostgreSQL
    # (`_sums_bigint`), an integer on both engines. #1157: one the walk names another kind is that
    # kind's sum (a `float8`, a `numeric`), no integer quotient. One it cannot type at all may be a
    # `sum(bigint)` there, a `numeric`: unknown, so it fails closed (#1034 phase 3 step 2a, the
    # division row of phase 4) — refused where the engine fact says such a sum departs
    # (`_untyped_sum_departs`), whether or not a `bigint` can be seen inside it. A sum of TEMPORAL
    # arithmetic is no such sum: the walk types it since #1034 step 5a, an interval, no integer quotient.
    side = name == "SUM" && _infer_kind(operand, instruc, _AllKinds()) === nothing ?
           (:numeric_whole_division, "a value PormG cannot type") : nothing
    side === nothing && (side = _whole_numeric_operand(operand, instruc))
    side === nothing || return (side[1], "`$(name)(…)` over $(side[2])")
  end
  return nothing
end

# #1124's record for a subquery: its projection's answer, asked of the inner build. No operator
# takes a `Subquery` directly, so this is reached through a function that carries its operand's
# value (`Coalesce(Subquery(Floor("id")), 0) / 2`); an aggregate refuses a `Subquery` argument.
function _whole_numeric_operand(p::SubqueryObject, instruc::SQLInstruction)
  instruc.subquery_whole_numeric === nothing && return nothing
  side = get(instruc.subquery_whole_numeric, p, nothing)
  return side === nothing ? nothing : (side[1], "a Subquery projecting $(side[2])")
end
_whole_numeric_operand(::Any, ::SQLInstruction) = nothing
# #1111 — the first operand of a rounding function that is an integer division (`Round(Floor("n") / 2)`,
# `Ceil(Sum("id") / 2)`): its `(kind, what)`, or `nothing`. The function cannot bring the half back —
# PostgreSQL rounds `7.5` and SQLite rounds `7` — so it is the division's split, read wherever the
# function would otherwise count as whole (`_integral_valued`, the `ROUND` scale arm) or as a
# `numeric` function's text (`_textless_number`).
function _divided_whole_operand(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  operand = p.column isa AbstractVector ? first(p.column) : p.column
  side = _concat_textless_operand(operand, instruc)
  return side !== nothing && side[1] in _DIVISION_KINDS ? side : nothing
end
# #1135 — a date part both engines compute as an integer, whatever its operand's type: `Dialect`
# renders `EXTRACT(… FROM x)::integer` (`trunc(…)::integer` for `SECOND`) on PostgreSQL and
# `CAST(strftime(…) AS INTEGER)` or integer arithmetic on SQLite, and `QUARTER`, `QUADRIMESTER` and
# `WEEK_DAY` are integer arithmetic on both. A part SQLite cannot render (`CENTURY`, `TIMEZONE_HOUR`,
# `@len`) raises `BackendCapabilityError` there; it is listed only where every engine that renders it
# answers an integer, since the list types the value, not a comparison between engines (#1147). #1337:
# an `EXTRACT` `QUARTER` is one, `EXTRACT(QUARTER FROM x)::integer` on PostgreSQL and MySQL's
# `QUARTER(x)` an INT, as the `@quarter` transform already was.
# `EPOCH` and the sub-second parts are fractional on PostgreSQL besides. Stated here because
# `_result_rule` answers `:unknown` for these until #1034's phase 3 states their type — the place
# this list belongs once it does.
const _INTEGER_TRANSFORMS = ("QUARTER", "QUADRIMESTER", "WEEK_DAY")
const _INTEGER_EXTRACT_PARTS = ("YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "DOW", "DOY",
                                "WEEK", "ISOYEAR", "ISODOW", "QUARTER")
function _integer_transform(p::Union{FObject,WindowFunction})::Bool
  p.function_name in _INTEGER_TRANSFORMS && return true
  p.function_name == "EXTRACT" || return false
  part = get(p.kwargs, "part", nothing)
  return part isa AbstractString && Dialect.extract_part(part) in _INTEGER_EXTRACT_PARTS
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
  # #1111: `ROUND` over an integer division is the division's split, not a `numeric` function's
  # text — `ROUND(7.5)` is `8` on PostgreSQL and `round(7)` is `7` on SQLite, whatever the places.
  # `FLOOR`/`CEIL`/`ABS` reach the same answer through the operand loop below.
  if name == "ROUND"
    side = _divided_whole_operand(p, instruc)
    side === nothing || return (side[1], "`ROUND(…)` over $(side[2])")
    # #1196: over an integer it is that integer on both engines (`Dialect.ROUND`), no `numeric`.
    _integer_operand_kind(p, instruc) === nothing || return nothing
  end
  rule = _result_rule(p)
  rule === :numeric && return (:numeric, "`$(name)(…)`")
  rule in _OPERAND_TYPED_RULES || return nothing
  # The whole classifier, not only the number half: `Lag("active")` is the boolean's own value, and
  # `_expression_formatter` does not type a window value function. A `Lag`/`Lead` `default` is one of
  # its values too (#1147 step 2, `_with_window_default`): `Lag("number"; default = 3.5)` is a float.
  # `NullIf(a, b)` is `a` (its `:first_operand` rule): PostgreSQL's promotion to `b`'s type is cast
  # back to `a`'s (#1150, `Dialect.NULLIF`), so `NullIf("number", 0.5)` is the integer on both engines.
  operands = rule === :first_operand ? Any[_first_operand(p)] : Any[(p.column isa AbstractVector ? p.column : (p.column,))...]
  if p isa WindowFunction
    default = get(p.kwargs, "default", nothing)
    literal = default isa SQLText ? default.field : default
    (literal === nothing || literal isa AbstractString || _is_null_literal(literal)) || push!(operands, default)
  end
  side = _division_first((_concat_textless_operand(operand, instruc) for operand in operands), instruc.connection)
  return side === nothing ? nothing : (side[1], "`$(name)(…)` over $(side[2])")
end
_textless_number(x::Union{Bool,AbstractFloat,Decimals.Decimal}, ::SQLInstruction) = _textless_literal(x)
_textless_number(p::SQLText, ::SQLInstruction) = _textless_literal(p.field)
_textless_number(::Any, ::SQLInstruction) = nothing

# #888 — the read kind of a `Subquery(...)`: its one projected column's, by `_cte_column_kind`'s rule.
# The inner build typed that column the way it types any projection (a plain column has its kind,
# `Max` its operand's, a `Cast(…, "date")` `CDate`, and `Avg`/`Sum`/`Count`/arithmetic none), and
# `_get_select_query(::SubqueryObject)` filed it under the node when it rendered it. So this is read
# AFTER the render, like every kind lookup here; a node this build did not render — or an inner
# projection with no kind — answers `nothing`, the fail-open default, and the value stays as the
# driver delivered it.
# #1121: a computed number's numeric read kind is the read path's alone (`_without_numeric_read`);
# the projection reads the whole record through `_read_kind` (#1034 step 3). This view is the binder's
# and the render's side typing (`_render_side_kind`, kept narrow on purpose, #1034 step 5b).
_subquery_kind(p::SubqueryObject, instruc::SQLInstruction)::Union{CanonicalType,Nothing} =
  _reads_unapplied_declaration(p, instruc) ? nothing :   # #1110: a declared width is a numeric read kind
  _without_numeric_read(instruc.subquery_kinds === nothing ? nothing : get(instruc.subquery_kinds, p, nothing))

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

# #1124 — the textless classification of a subquery's one projected expression, asked of the INNER
# instruction in the same `built` window as the formatter (#929): the inner memos are what resolve a
# joined path, and `_concat_textless_operand` reads the field memo. Asked of the expression itself,
# not the `SQLField` around it, as `_build_cte_custom_model` asks for a CTE column; a `Value` is its
# `SQLText`. Filed under the node by `_render_scalar_subquery`, read by the classifier's
# `SubqueryObject` arm once the enclosing projection has rendered. `nothing` — the expression has
# one text, or names no type — is not recorded, so the arm falls through to the read kind.
function _subquery_projection_textless(handler::SQLObjectHandler, inner::SQLInstruction)
  vals = handler.object.values
  length(vals) == 1 || return nothing
  v = only(vals)
  return _concat_textless_operand(v isa SQLText ? v : v.field, inner)
end
function _record_subquery_textless!(instruc::SQLInstruction, p::SubqueryObject, side)
  side isa Tuple{Symbol,String} || return nothing
  instruc.subquery_textless === nothing && (instruc.subquery_textless = IdDict{SubqueryObject,Tuple{Symbol,String}}())
  instruc.subquery_textless[p] = side
  return nothing
end
# #1111 — and the `_whole_numeric_operand` answer for the same expression, so `Subquery(…) / 2` is
# refused where the projection divided would be.
function _subquery_projection_whole_numeric(handler::SQLObjectHandler, inner::SQLInstruction)
  vals = handler.object.values
  length(vals) == 1 || return nothing
  v = only(vals)
  return _whole_numeric_operand(v isa SQLText ? v : v.field, inner)
end
function _record_subquery_whole_numeric!(instruc::SQLInstruction, p::SubqueryObject, side)
  side isa Tuple{Symbol,String} || return nothing
  instruc.subquery_whole_numeric === nothing && (instruc.subquery_whole_numeric = IdDict{SubqueryObject,Tuple{Symbol,String}}())
  instruc.subquery_whole_numeric[p] = side
  return nothing
end
_subquery_textless(p::SubqueryObject, instruc::SQLInstruction)::Union{Tuple{Symbol,String},Nothing} =
  instruc.subquery_textless === nothing ? nothing : get(instruc.subquery_textless, p, nothing)

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
  # #1078: `dec` is the third spelling `_numeric_cast_scale` already reads; SQLite gives it NUMERIC
  # affinity, as it does `decimal`. Unnamed, `Cast(Cast(x, "dec"), IntegerField())` passed the
  # #1028 rule that refuses the same cast through `"decimal"`.
  base in ("numeric", "decimal", "dec") && return Models.DecimalField()
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
  # #1194: the temporal and binary types, so a pattern lookup on such a cast follows the #1183 rule
  # (a time reads as its text, the others are refused) and an equality value on it is checked. SQLite
  # refuses every one of these casts but `blob` (`Dialect.sqlite_cast_sql`, #822), so they type the
  # PostgreSQL cast; `blob` is `BinaryField`'s own type, which SQLite casts exactly. The precision of a
  # time or timestamp (`timestamp(3)`) is dropped first, so the zone that follows it still counts.
  words = replace(lowercase(strip(type_name)), r"\s*\(\s*\d+\s*\)" => "")
  words in ("time", "time without time zone") && return Models.TimeField()
  words in ("timestamp", "timestamp without time zone") && return Models.DateTimeField(type = "TIMESTAMP")
  words in ("timestamptz", "timestamp with time zone") && return Models.DateTimeField()
  words == "interval" && return Models.DurationField()
  base in ("bytea", "blob") && return Models.BinaryField()
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
  _cast_renders_text(field, instruc.connection) && return nothing
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
  # #1310: an ordering on an alias is checked as one on the expression it projects.
  return _checking_unnamed_temporal(instruc) do pending
    sql = _render_alias_predicate_node(v, having_key, having_cached, instruc)
    pending === nothing ||
      _queue_unnamed_temporal!(pending, _projected_source(having_key, instruc).field, _filter_value_node(v.values), v.operator)
    return sql
  end
end
function _render_alias_predicate_node(v::SQLTypeOper, having_key::MemoKey, having_cached,
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
  # #1382: an alias over a JSON key lookup compares as the key lookup does — text on PostgreSQL and
  # MySQL, the native value on SQLite, a number ordered as a number — for the operators that comparison
  # renders, against a value. A pattern lookup, a membership list or an expression or a queryset on the
  # right (`_expression_operand`) renders as it did.
  _alias_projects_json_key(having_key, instruc) && v.operator in _JSON_KEY_COMPARISON_OPERATORS &&
    !_expression_operand(v.values) &&
    return _render_json_lookup_comparison(v, string(_alias_lhs(having_key, having_cached, instruc)), instruc)
  # #903: the alias's own column type decides what a pattern lookup reads — `HOST(MAX(…))` for an alias
  # over an `inet`, exactly as `_get_filter_query(::SQLTypeOper)` wraps the column itself.
  alias_formatter = _having_alias_formatter(having_key, instruc)
  field = _pattern_operand(string(_alias_lhs(having_key, having_cached, instruc)),
                           alias_formatter, v.operator, instruc;
                           label = having_key[2],
                           # #1168/#1183: the alias's kind — a number's width, a time, a type
                           # with no formatter — only where it decides the read.
                           operand_kind = v.operator in PATTERN_LOOKUP_OPERATORS ?
                                          _having_alias_kind(having_key, instruc) : nothing)
  # #618: `contains=` / `operator=` are what run `_apply_like_wildcards` (and with it
  # `escape_like_pattern`) inside `add_parameter!`. Without them a pattern lookup on an alias
  # bound its value undecorated AND unescaped — no `%`, and a user-supplied `%` or `_` in the
  # term matched as a wildcard. `_bind_predicate_value` applies that gate — membership in
  # `LIKE_WILDCARD_OPERATORS`, exactly as the WHERE binding arms in `filter_nodes.jl` spell
  # it; the `*_exact` and regex (#635) pattern lookups take the value verbatim and must NOT be
  # decorated, which is why that tuple and `PATTERN_LOOKUP_OPERATORS` are deliberately
  # different sets (`constants.jl`). #654: it also binds a range's two operands, and nothing for `@isnull`.
  placeholder = _bind_alias_value(v, having_key, instruc)
  # #618: one ladder, shared with the WHERE path — see `_render_predicate`. It absorbs the #411
  # `IN`/`NOT IN` membership case this branch used to special-case, adds the
  # `PATTERN_LOOKUP_OPERATORS` → `Dialect` dispatch it never had, and brings the
  # unknown-operator refusal that was missing here entirely.
  return _render_predicate(string(field), v.operator, placeholder, instruc;
                           expression = isnull_aggregate)
end

# The value of one predicate on a projection alias, formatted and checked as the alias's type and
# bound in the current clause: what a `filter`/`Q` on the alias binds (`_render_alias_predicate_node`)
# and, since #1381, a `When` condition on it (`_render_filter_oper`), which bound the value raw.
function _bind_alias_value(v::SQLTypeOper, having_key::MemoKey, instruc::SQLInstruction)
  placeholder = _bind_predicate_value(instruc, v.operator,
                  _resolve_having_filter_value(having_key, v.values, instruc, v.operator))
  # #1360: an alias over the whole JSON document compares as JSON, as the column's own filter arm does
  # (`filter_nodes.jl`); a pattern lookup binds text. A range binds a pair and `@isnull` a Bool, so
  # only a marker string is wrapped. An alias over a key lookup holds that key's value, not a document.
  source = _projected_source(having_key, instruc)
  placeholder isa AbstractString && !(v.operator in PATTERN_LOOKUP_OPERATORS) &&
    source isa SQLTypeField && _json_document_operand(source.field, instruc) &&
    (placeholder = _json_document_marker(instruc.connection, placeholder))
  return placeholder
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
  _supports(instruc.connection, :full_text_search) || throw(Dialect.fts_capability_error(instruc.connection, "The @search lookup"))
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
  # #1311: an interval alias with no millisecond form would be ordered by its text, whatever the value.
  v.operator in _INTERVAL_ORDERING_LOOKUPS &&
    _refuse_unordered_interval_alias("An ordering filter (`$(v.operator)`)", having_key[2], instruc)
  source = _projected_interval_source(having_key[2], instruc)
  source === nothing && return nothing
  units = _stores_interval_as_units(instruc.connection)
  compares = v.operator in _INTERVAL_MS_PREDICATES || v.operator in _INTERVAL_MS_LIST_PREDICATES
  # #1130: where the interval IS its integer (MySQL), a `Subquery` or a CTE column compared with the
  # alias is an interval or it is not: rendered once, typed, and refused when it is a number.
  if units && compares && v.values isa Union{SubqueryObject,CTEReference}
    sql, _ = _render_interval_source_ms(source, instruc)
    rhs, _, interval = _on_join_right(() -> _render_interval_operand(v.values, instruc), instruc)
    interval || _refuse_interval_against_number(v.operator, instruc)
    return _render_column_rhs(sql, v.operator, rhs, instruc)
  end
  ms_values = _predicate_duration_units(v.operator, v.values, instruc.connection)
  # #1130: and a compared VALUE that is no duration has no text comparison to fall back to: the
  # duration formatter refuses it, as the alias's own formatter does for any other interval alias,
  # rather than a `Value(Hour(1))` alias comparing its count with `10`. An expression (a queryset for
  # `@in`) is left to the path that renders it.
  if ms_values === nothing && units && compares && !(v.values isa Union{SQLType,SQLObjectHandler})
    formatter = value_formatter(CInterval(), instruc.connection)
    _guarded_format(formatter, v.values, v.operator, having_key[2], _formatter_type_label(formatter);
                    subject = "projection alias")
  end
  ms_values === nothing && return nothing
  sql, interval_ms = _render_interval_source_ms(source, instruc)
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
