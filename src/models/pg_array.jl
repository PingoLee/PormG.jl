# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL array literals (#28) — `ArrayField`
# ─────────────────────────────────────────────────────────────────────────────
#
# PostgreSQL only: an array column has no SQLite counterpart (`Dialect._refuse_unsupported_type`),
# so nothing here makes SQLite imitate one. Three jobs, all for PostgreSQL:
#
#   * WRITE — an `ArrayField` value becomes ONE text parameter in PostgreSQL's own array syntax
#     (`{1,2}`, `{"a b",NULL}`), wrapped in `PormGArrayLiteral`. PormG prints the literal itself
#     rather than handing a Julia vector to the driver, because the two drivers disagree: LibPQ writes
#     `nothing` and `Inf` as those words, and Postgres.jl spaces its elements differently. One printer
#     means one stored text on both.
#   * READ — the drivers disagree here too. LibPQ parses only the numeric arrays (as a possibly
#     multi-dimensional, possibly offset-indexed array) and hands every other array back as its raw
#     `{…}` text; Postgres.jl returns a typed `Vector` for the common element types and a `Vector{Any}`
#     for the rest. `normalize_pg_array` turns every one of those shapes into the same 1-based
#     `Vector{T}`, `T` being what a scalar read of the base field returns.
#   * DEFAULTS — the catalog stores a column default as PostgreSQL prints it (`'{1.50}'::numeric(5,2)[]`),
#     and the planner compares that against the declared one. Both sides go through
#     `canonical_array_literal`, so `default = [1.5]` meets the catalog's `{1.50}` instead of planning a
#     default change on every `makemigrations` — the `inet` precedent in `network_address.jl`.
#
# Every element kind here is a `CanonicalType` (`column_ir.jl`), so the one table of what an array
# may hold is `array_element_kind` (`fields.jl`) and the per-kind behaviour below dispatches on it.

# A dimension-bounds decoration: `[0:2]={1,2,3}` is how PostgreSQL prints an array whose lower bound
# is not 1. PormG reads every array 1-based, as psycopg does, so the bounds are dropped.
const _PG_ARRAY_BOUNDS = r"^\s*(?:\[\s*[+-]?\d+\s*:\s*[+-]?\d+\s*\])+\s*="

# The whitespace PostgreSQL's array syntax skips — `scanner_isspace`, the six ASCII characters. Not
# Julia's `isspace`, which also matches U+00A0, U+3000 and the rest: PostgreSQL prints an element that
# starts with one of those UNQUOTED, so stripping it here would change the text that was stored.
_pg_array_space(c::Char)::Bool = c in (' ', '\t', '\n', '\r', '\v', '\f')

_pg_array_invalid(raw, why::AbstractString) =
  throw(InvalidValueError("Invalid PostgreSQL array literal: $why.", :format))

"""
    parse_pg_array_literal(s) -> Vector{Union{Nothing, String}}

The elements of a one-dimensional PostgreSQL array literal, as text: `nothing` for an unquoted
`NULL` (any case), the unescaped string otherwise. A quoted `"NULL"` is the four-letter string. A
leading bounds decoration (`[0:2]=`) is dropped. A nested (multi-dimensional) literal and a malformed
one raise `InvalidValueError`.
"""
function parse_pg_array_literal(s::AbstractString)::Vector{Union{Nothing, String}}
  raw = String(s)
  str = replace(raw, _PG_ARRAY_BOUNDS => ""; count = 1)
  chars = collect(str)
  n = length(chars)
  out = Union{Nothing, String}[]
  i = 1
  skip_ws() = (while i <= n && _pg_array_space(chars[i]); i += 1; end)

  skip_ws()
  (i <= n && chars[i] == '{') || _pg_array_invalid(raw, "it must start with `{`")
  i += 1
  skip_ws()
  if i <= n && chars[i] == '}'
    i += 1
  else
    while true
      skip_ws()
      i > n && _pg_array_invalid(raw, "it ends before its closing `}`")
      c = chars[i]
      if c == '{'
        _pg_array_invalid(raw, "it is multi-dimensional, and an ArrayField holds a one-dimensional array")
      elseif c == '"'
        # Quoted: everything up to the closing quote, with `\x` meaning `x`.
        i += 1
        buf = IOBuffer()
        closed = false
        while i <= n
          ch = chars[i]
          if ch == '\\'
            i += 1
            i > n && break
            print(buf, chars[i])
          elseif ch == '"'
            closed = true
            i += 1
            break
          else
            print(buf, ch)
          end
          i += 1
        end
        closed || _pg_array_invalid(raw, "a quoted element is not closed")
        push!(out, String(take!(buf)))
      else
        # Unquoted: up to the next `,` or `}`. Surrounding whitespace is not part of the element, and
        # a backslash still escapes the next character.
        buf = IOBuffer()
        escaped = false
        while i <= n && !(chars[i] in (',', '}'))
          ch = chars[i]
          if ch == '\\'
            i += 1
            i > n && break
            escaped = true
            print(buf, chars[i])
          elseif ch == '{' || ch == '"'
            _pg_array_invalid(raw, "an unquoted element contains `$ch`")
          else
            print(buf, ch)
          end
          i += 1
        end
        text = String(take!(buf))
        text = escaped ? text : String(strip(_pg_array_space, text))
        isempty(text) && _pg_array_invalid(raw, "it has an empty unquoted element")
        push!(out, !escaped && lowercase(text) == "null" ? nothing : text)
      end
      skip_ws()
      i > n && _pg_array_invalid(raw, "it ends before its closing `}`")
      if chars[i] == ','
        i += 1
      elseif chars[i] == '}'
        i += 1
        break
      else
        _pg_array_invalid(raw, "expected `,` or `}` after an element, found `$(chars[i])`")
      end
    end
  end
  skip_ws()
  i <= n && _pg_array_invalid(raw, "it has text after its closing `}`")
  return out
end

# PostgreSQL's `array_out` rule: an element is quoted when it is empty, holds a character the literal
# syntax reserves (`{`, `}`, `,`, `"`, `\`) or whitespace, or reads as `NULL`. Quoting is what makes a
# stored `"NULL"` string, a space or an empty string round-trip.
function _pg_array_element_quoted(text::AbstractString)::String
  needs = isempty(text) || lowercase(text) == "null" ||
          any(c -> c in ('{', '}', ',', '"', '\\') || isspace(c), text)
  needs || return String(text)
  return "\"" * replace(String(text), "\\" => "\\\\", "\"" => "\\\"") * "\""
end

"""
    print_pg_array_literal(texts) -> String

The PostgreSQL array literal holding `texts` — each a `String`, or `nothing`/`missing` for a NULL
element — quoted as PostgreSQL's own `array_out` quotes them.
"""
function print_pg_array_literal(texts)::String
  parts = String[(t === nothing || t === missing) ? "NULL" : _pg_array_element_quoted(t) for t in texts]
  return "{" * join(parts, ",") * "}"
end


# ── The element kinds ────────────────────────────────────────────────────────────────────────────
#
# One method per kind for each of the three questions: the Julia type a read returns, how any
# accepted input becomes that value, and the text it is written as. An element is converted to its
# VALUE first and printed from that, so a written literal and a canonicalized default share one
# printer — two spellings of one value cannot print differently.

const _PG_ARRAY_UTC = TimeZone("UTC")

pg_array_element_type(::CInt32) = Int32
pg_array_element_type(::CInt64) = Int64
pg_array_element_type(::CFloat64) = Float64
pg_array_element_type(::CDecimal) = Decimals.Decimal
pg_array_element_type(::CBool) = Bool
pg_array_element_type(::Union{CText, CVarChar, CUUID}) = String
pg_array_element_type(::CDate) = Date
pg_array_element_type(k::CDateTime) = k.with_timezone ? ZonedDateTime : DateTime

_pg_element_invalid(kind, x) =
  throw(InvalidValueError("A $(typeof(x)) value is not a valid $(_pg_kind_label(kind)) array element.", :format))

_pg_kind_label(::CInt32) = "integer"
_pg_kind_label(::CInt64) = "bigint"
_pg_kind_label(::CFloat64) = "double precision"
_pg_kind_label(::CDecimal) = "numeric"
_pg_kind_label(::CBool) = "boolean"
_pg_kind_label(::Union{CText, CVarChar}) = "text"
_pg_kind_label(::CUUID) = "uuid"
_pg_kind_label(::CDate) = "date"
_pg_kind_label(k::CDateTime) = k.with_timezone ? "timestamptz" : "timestamp"

"""
    pg_array_element_value(kind, x) -> value

Element `x` — a Julia value, or the text a field formatter or PostgreSQL produced — as the Julia
value an `ArrayField` of `kind` holds. Raises `InvalidValueError` for a value that is not one.
"""
function pg_array_element_value end

function _pg_integer_element(T::Type, kind, x)
  x isa Bool && _pg_element_invalid(kind, x)
  n = x isa Integer ? x : x isa AbstractString ? tryparse(Int64, strip(x)) : nothing
  n === nothing && _pg_element_invalid(kind, x)
  typemin(T) <= n <= typemax(T) ||
    throw(InvalidValueError("The value is out of range for a $(_pg_kind_label(kind)) array element ($(typemin(T)) to $(typemax(T))).", :range))
  return T(n)
end
pg_array_element_value(k::CInt32, x) = _pg_integer_element(Int32, k, x)
pg_array_element_value(k::CInt64, x) = _pg_integer_element(Int64, k, x)

function pg_array_element_value(k::CFloat64, x)
  x isa Bool && _pg_element_invalid(k, x)
  x isa Real && return Float64(x)
  x isa AbstractString || _pg_element_invalid(k, x)
  f = tryparse(Float64, strip(x))
  f === nothing && _pg_element_invalid(k, x)
  return f
end

function pg_array_element_value(k::CDecimal, x)
  x isa Decimals.Decimal && return x
  (x isa Bool || !(x isa Union{Real, AbstractString})) && _pg_element_invalid(k, x)
  x isa AbstractFloat && !isfinite(x) &&
    throw(InvalidValueError("A NaN or infinite value cannot be stored in a numeric array element: PormG reads numeric arrays as Decimal, which has no NaN or infinity.", :range))
  text = x isa AbstractString ? String(strip(x)) : string(x)
  occursin(r"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", text) || _pg_element_invalid(k, x)
  return try
    parse(Decimals.Decimal, text)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()   # #472
    _pg_element_invalid(k, x)
  end
end

function pg_array_element_value(k::CBool, x)
  x isa Bool && return x
  x isa AbstractString || _pg_element_invalid(k, x)
  t = lowercase(strip(x))
  t in ("t", "true") && return true
  t in ("f", "false") && return false
  _pg_element_invalid(k, x)
end

function pg_array_element_value(k::Union{CText, CVarChar}, x)
  x isa AbstractString || _pg_element_invalid(k, x)
  return String(x)
end

function pg_array_element_value(k::CUUID, x)
  x isa UUID && return string(x)
  x isa AbstractString || _pg_element_invalid(k, x)
  return try
    string(UUID(strip(x)))
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()   # #472
    _pg_element_invalid(k, x)
  end
end

function pg_array_element_value(k::CDate, x)
  x isa Date && return x
  x isa AbstractString || _pg_element_invalid(k, x)
  occursin(r"^\d{4}-\d{2}-\d{2}$", strip(x)) || _pg_element_invalid(k, x)
  return try
    Date(strip(x))
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()   # #472
    _pg_element_invalid(k, x)
  end
end

# Both spellings a timestamp element arrives in: PostgreSQL's `2024-03-02 14:00:00.25+00` (a space, a
# variable fraction, an offset of hours with optional minutes and seconds) and PormG's own
# `format_timezone_sql` text (`2024-03-02T14:00:00.250+00:00`). Sub-millisecond digits are dropped,
# as a `DateTime` holds milliseconds.
const _PG_TIMESTAMP_TEXT =
  r"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(?:([+-])(\d{2})(?::?(\d{2}))?(?::?(\d{2}))?|(Z))?$"

function _pg_timestamp_parts(k, x)::Tuple{DateTime, Union{Int, Nothing}}
  m = match(_PG_TIMESTAMP_TEXT, strip(x))
  m === nothing && _pg_element_invalid(k, x)
  ms = m[7] === nothing ? 0 : parse(Int, rpad(first(m[7], 3), 3, '0'))
  dt = try
    DateTime(parse.(Int, (m[1], m[2], m[3], m[4], m[5], m[6]))..., ms)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()   # #472
    _pg_element_invalid(k, x)
  end
  offset = if m[12] !== nothing
    0
  elseif m[8] === nothing
    nothing
  else
    secs = parse(Int, m[9]) * 3600 + parse(Int, something(m[10], "0")) * 60 + parse(Int, something(m[11], "0"))
    m[8] == "-" ? -secs : secs
  end
  return dt, offset
end

function pg_array_element_value(k::CDateTime, x)
  if k.with_timezone
    x isa ZonedDateTime && return astimezone(x, _PG_ARRAY_UTC)
    x isa DateTime && return ZonedDateTime(x, _PG_ARRAY_UTC)   # a naive DateTime is UTC, as on a scalar write
    x isa AbstractString || _pg_element_invalid(k, x)
    dt, offset = _pg_timestamp_parts(k, x)
    return ZonedDateTime(dt - Second(something(offset, 0)), _PG_ARRAY_UTC)
  else
    # A `timestamp` holds wall-clock time. A scalar `DateTimeField(type = "TIMESTAMP")` write sends the
    # UTC text and PostgreSQL drops its offset, so an element converts to UTC the same way.
    x isa DateTime && return x
    x isa ZonedDateTime && return DateTime(astimezone(x, _PG_ARRAY_UTC))
    x isa AbstractString || _pg_element_invalid(k, x)
    dt, offset = _pg_timestamp_parts(k, x)
    return offset === nothing ? dt : dt - Second(offset)
  end
end

pg_array_element_value(k::CanonicalType, x) =
  throw(InvalidValueError("an ArrayField cannot hold $(k) elements.", :type))

"""
    pg_array_element_text(kind, value) -> String

The text `value` (as [`pg_array_element_value`](@ref) returns it) is written as inside an array
literal, before quoting.
"""
pg_array_element_text(::Union{CInt32, CInt64}, v::Integer) = string(v)
function pg_array_element_text(::CFloat64, v::Float64)
  isnan(v) && return "NaN"
  isinf(v) && return v > 0 ? "Infinity" : "-Infinity"
  return repr(v)
end
pg_array_element_text(::CDecimal, v::Decimals.Decimal) = _pg_decimal_text(v)
pg_array_element_text(::CBool, v::Bool) = v ? "t" : "f"
pg_array_element_text(::Union{CText, CVarChar, CUUID}, v::AbstractString) = String(v)
pg_array_element_text(::CDate, v::Date) = string(v)
pg_array_element_text(::CDateTime, v::ZonedDateTime) = _canonicalize_datetime_utc(v)
pg_array_element_text(::CDateTime, v::DateTime) = Dates.format(v, dateformat"yyyy-mm-ddTHH:MM:SS.sss")

# A `Decimal` in plain fixed-point text with no trailing fractional zeros: `1.50` and `1.5` are one
# value, and the catalog prints a default at the column's scale. Built from the coefficient and the
# exponent rather than `string(d)`, whose spelling differs between the two Decimals majors PormG
# supports (`Decimals = "0.4, 0.5"`).
function _pg_decimal_text(d::Decimals.Decimal)::String
  c, q = BigInt(d.c), Int(d.q)
  iszero(c) && return "0"
  digits = string(c)
  text = if q >= 0
    digits * repeat("0", q)
  elseif length(digits) > -q
    digits[1:end + q] * "." * digits[end + q + 1:end]
  else
    "0." * repeat("0", -q - length(digits)) * digits
  end
  if occursin('.', text)
    text = rstrip(rstrip(text, '0'), '.')
  end
  return (d.s == 1 ? "-" : "") * text
end


# ── Whole arrays ─────────────────────────────────────────────────────────────────────────────────

# The elements of a value an `ArrayField` is handed: a one-dimensional vector or a tuple. Anything
# else is refused here, before an element is looked at — a `Matrix` because PostgreSQL arrays are
# rectangular and an `ArrayField` holds one dimension, a scalar because it is not an array (pass a
# vector, `[1]`, not `1`). A String never reaches here: the formatter reads it as an array literal.
function _pg_array_elements(value)
  value isa Tuple && return collect(Any, value)
  value isa AbstractVector && return value
  value isa AbstractArray &&
    throw(InvalidValueError("an ArrayField holds a one-dimensional array; got a $(ndims(value))-dimensional $(typeof(value)).", :type))
  throw(InvalidValueError("an ArrayField value must be a Vector (or a Tuple), got $(typeof(value)). " *
                          "Wrap a single element as a one-element vector: [x].", :type))
end

"""
    canonical_array_literal(x, kind) -> String

`x` — a vector, a tuple, or an array literal String — as the one literal PormG writes for it. Every
element is converted to its value and printed back, so any two spellings of one array give the same
text. Used for both sides of a default comparison. Raises `InvalidValueError` for an element that is
not a `kind` value.
"""
function canonical_array_literal(x, kind::CanonicalType)::String
  elems = x isa AbstractString ? parse_pg_array_literal(x) : _pg_array_elements(x)
  return print_pg_array_literal(
    [(e === nothing || e === missing) ? nothing : pg_array_element_text(kind, pg_array_element_value(kind, e))
     for e in elems])
end

"""
    normalize_pg_array(v, kind)

A value a PostgreSQL driver returned for an `ArrayField` column, as a 1-based `Vector{T}` (or
`Vector{Union{Missing, T}}` when an element is NULL), `T` being [`pg_array_element_type`](@ref).
Accepts every shape either driver produces: the raw literal text, a typed or `Vector{Any}` vector, an
offset-indexed array. Fail-open like every `value_parser`: a multi-dimensional array, or a value it
cannot read, is returned unchanged rather than approximated.
"""
function normalize_pg_array(v, kind::CanonicalType)
  (v === missing || v === nothing) && return v
  elems = if v isa AbstractString
    try
      parse_pg_array_literal(v)
    catch e
      e isa InvalidValueError || rethrow()
      return v
    end
  elseif v isa AbstractArray
    ndims(v) == 1 || return v
    any(e -> e isa AbstractArray, v) && return v
    v
  else
    return v
  end
  T = pg_array_element_type(kind)
  out = Vector{Union{Missing, T}}(undef, length(elems))
  i = 0
  for e in elems   # iteration, not indexing: an offset-indexed array iterates in order from its first index
    i += 1
    if e === nothing || e === missing
      out[i] = missing
    else
      out[i] = try
        pg_array_element_value(kind, e)
      catch err
        err isa InvalidValueError || rethrow()
        return v
      end
    end
  end
  return any(ismissing, out) ? out : Vector{T}(out)
end
