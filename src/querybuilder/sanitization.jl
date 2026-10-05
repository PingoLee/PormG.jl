
# ── Identifier contract (#394) ────────────────────────────────────────────────────────────────
# Two axes, not one. The user-facing statement is in `docs/src/schema_conventions.md` →
# *Identifier quoting*.
#
#   PHYSICAL names (a table, a column) → ESCAPE-ONLY. They are either pinned by the model author via
#     `db_table`/`db_column` — which are deliberately NOT shape-validated (#59/#50), because naming a
#     table PormG's own conventions could not produce is the entire point of the option — or read out
#     of the database catalog by introspection and round-tripped back into a `db_table`/`db_column`
#     pin by `Model_to_str`. Validating them meant PormG rendered a table with
#     `Dialect._quote_table_ddl`, which escapes and never validates, and then REFUSED to query the
#     table it had just created, because `quote_identifier` validated and never escaped. Doubling `"`
#     is the standard SQL escape on both backends and makes the identifier unterminatable, which is
#     the whole threat; there is nothing else to defend against inside a quoted identifier.
#
#   ALIASES and other query-time names → FAIL-CLOSED. A join alias, a `cjoin_on` alias, a
#     `.with(...)` CTE name and a `values("label" => ...)` SELECT alias are chosen while the query is
#     built, are frequently literals the caller typed, and name nothing that already exists — so
#     there is nothing to be faithful to and every reason to be strict.
#
# Do NOT collapse these back into one function. The split IS the fix: a single rule cannot be both
# permissive enough for a legacy table name and strict enough for a caller-supplied alias.
#
# `\A…\z`, not `^…$`, on both patterns here (#794): PCRE's `$` also matches before a final newline,
# so `^…$` accepted `"driver\n"`. `Dialect._is_json_array_index` is anchored the same way (#779).
const SAFE_IDENTIFIER_PATTERN = r"\A[\p{L}_][\p{L}\p{M}\p{N}_]*\z"

# #394: a JSON path segment is NOT a SQL identifier, and this constant is not duplication for its own
# sake. `_validate_json_key_segments` (build_joins.jl) interpolates a segment UNQUOTED into a path
# literal inside a single-quoted SQL string — PostgreSQL `'{a,b}'`, SQLite `'$.a.b'` — so it has no
# quoting to fall back on and the charset check IS the entire guard there. It is kept separate, with a
# body that merely happens to match the one above, so that relaxing the SQL-identifier rules can never
# widen the JSON guard by accident. If you touch `SAFE_IDENTIFIER_PATTERN`, this one does not move.
const SAFE_JSON_KEY_PATTERN = r"\A[\p{L}_][\p{L}\p{M}\p{N}_]*\z"

function _validate_identifier(identifier::String)::String
    if !occursin(SAFE_IDENTIFIER_PATTERN, identifier)
        # `repr`, so a refused newline or other control character is visible in the message (#794).
        throw(InvalidValueError(
            "Invalid SQL identifier: $(repr(identifier)). PormG requires a plain identifier here because " *
            "this name is used as a query ALIAS — a join alias, a `.with(...)` CTE name, a " *
            "`cjoin_on` alias, or a `values(\"label\" => ...)` label. A physical table or column may " *
            "carry any spelling; pin it with db_table / db_column instead."))
    end
    return identifier
end

# The escape shared by every physical-identifier path (#394). Doubling is the standard SQL escape on
# both backends and a no-op for every name that does not contain a quote. The DDL side has its own
# copy in `Dialect._quote_table_ddl`, which returns the INNER text because its call sites supply the
# surrounding quotes themselves.
_escape_identifier(name::AbstractString)::String = replace(String(name), "\"" => "\"\"")

"""
Quote a query ALIAS or other query-time name. Fail-closed: rejects anything outside
`SAFE_IDENTIFIER_PATTERN`. For a physical table or column use `safe_table_identifier` /
`safe_column_identifier` instead — validating those would refuse names PormG's own DDL creates (#394).
"""
function quote_identifier(identifier::String, conn)::String
    return "\"$(_validate_identifier(identifier))\""
end

"""
Escape LIKE patterns to prevent wildcard injection
"""
function escape_like_pattern(pattern::String)::String
    # Escape special LIKE characters
    escaped = replace(pattern, "\\" => "\\\\")
    escaped = replace(escaped, "%" => "\\%")
    escaped = replace(escaped, "_" => "\\_")
    return escaped
end

"""
Quote a PHYSICAL table name — escape-only, no charset validation (#394). The query-side mirror of
`Dialect._quote_table_ddl`, so a table PormG can create is a table PormG can address.
"""
function safe_table_identifier(table_name::String, conn)::String
    return "\"$(_escape_identifier(table_name))\""
end

"""
Quote a PHYSICAL column name — escape-only, no charset validation (#394). The column axis of
`safe_table_identifier`; `db_column` carries an arbitrary spelling for the same reason `db_table`
does (#50).
"""
function safe_column_identifier(column_name::String, conn)::String
    return "\"$(_escape_identifier(column_name))\""
end

# Escape-only and WITHOUT a `conn`, for interpolation into a SQL string literal that PostgreSQL then
# re-parses as an identifier — `setval`'s `regclass` argument, `to_regclass`. See
# `_table_ident_literal` in execution.jl, which composes this with `_sql_literal`. Lives here so the
# escape rule has exactly one definition on the query side (#394; was execution.jl, #59/#344).
_quote_ident_raw(name::AbstractString)::String = "\"$(_escape_identifier(name))\""

"""
    validate_field_data(model::PormGModel, field::String, value::Any, operation::String; allow_primary_key::Bool = true)

Validates that a value is compatible with the model field definition before SQL generation.
Checks:
1. Field existence in model.
2. Primary key modification protection (disabled if allow_primary_key is false).
3. Nullability, and the value's type for its field.
4. Max length for CharFields (characters) and BinaryFields (bytes).
5. DecimalField width: total digits (`max_digits`), fractional digits (`decimal_places`) and whole
   digits (`max_digits - decimal_places`), as Django's `DecimalValidator` checks (#761).

Returns `true` if valid. An unknown field **name** throws an `UnknownFieldError` (#462); every
other rejection — a bad **value**, a protected primary key, a many-to-many relation — throws an
`InvalidValueError` (#231; was `ErrorException`).
SQL expressions (SQLTypeF, SQLTypeFunction) skip data validation as they are evaluated by the DB.
"""
function _validation_error(operation::String, model::PormGModel, field::String, message::String; suggestion::Union{Nothing, String}=nothing)
    suffix = suggestion === nothing ? "" : " Suggested fix: $suggestion"
    throw(InvalidValueError("Error in $operation for model $(model.name), field \"$field\": $message$suffix"))
end

function _type_mismatch_error(operation::String, model::PormGModel, field::String, value::Any, expected::String; suggestion::Union{Nothing, String}=nothing)
    actual_type = value === nothing ? "Nothing" : ismissing(value) ? "Missing" : string(typeof(value))
    preview = value === nothing || ismissing(value) ? "" : " (value=$(repr(value)))"
    _validation_error(operation, model, field, "expected $expected, got $actual_type$preview"; suggestion=suggestion)
end

function _is_integer_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("INTEGER", "BIGINT")
end

function _is_decimal_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "DECIMAL"
end

function _is_float_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("FLOAT", "DOUBLE PRECISION")
end

function _is_decimal_like_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("DECIMAL", "FLOAT", "DOUBLE PRECISION")
end

function _is_date_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "DATE"
end

function _is_time_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "TIME"
end

function _is_duration_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "INTERVAL"
end

function _is_datetime_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("TIMESTAMPTZ", "TIMESTAMP")
end

function _is_uuid_field(f_meta)::Bool
    return getproperty(f_meta, :type) == "UUID"
end

function _is_json_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("JSON", "JSONB")
end

# `GenericIPAddressField` (`"INET"`) and `CIDRField` (`"CIDR"`), #28.
function _is_network_field(f_meta)::Bool
    return getproperty(f_meta, :type) in ("INET", "CIDR")
end

# Keyed on the STRUCT, not on `f_meta.type`, unlike every predicate above (#296). `ImageField` and
# `FileField` also carry `type == "BLOB"` — they are `sImageField` and store a filesystem *path* as
# text — so a `type`-based test would route their string values into the byte validator and reject
# them. `sBinaryField` is the only struct that actually holds bytes.
function _is_binary_field(f_meta)::Bool
    return f_meta isa sBinaryField
end

# `ArrayField` (#28). Keyed on the struct for the binary predicate's reason: its `type` tag,
# `"ARRAY"`, names no element type, and the base field is what every per-element check reads.
function _is_array_field(f_meta)::Bool
    return f_meta isa sArrayField
end

function _string_uses_scientific_notation(value::AbstractString)::Bool
    return occursin(r"^[+-]?(?:\d+\.?\d*|\.\d+)[eE][+-]?\d+$", strip(value))
end

const _MAX_EXPANDED_EXPONENT = 10_000

function _expand_scientific_notation(value::AbstractString)::String
    # Either side of the point may be empty — `"5.e3"` and `".5e3"` are numbers `format_number_sql`
    # accepts, and `_string_uses_scientific_notation` above already matches both. Requiring a digit on
    # each side left them unexpanded, so `"5.e3"` counted as 1 whole digit and the whole-digit bound
    # let 5000 into a `DecimalField(5, 2)` (#761).
    match_result = match(r"^([+-]?)(\d*)(?:\.(\d*))?[eE]([+-]?\d+)$", value)
    match_result === nothing && return value

    sign, integer_part, fractional_part, exponent_str = match_result.captures
    fractional_part = fractional_part === nothing ? "" : fractional_part
    isempty(integer_part) && isempty(fractional_part) && return value
    digits = integer_part * fractional_part
    # The exponent is caller-sized text, and expanding it literally is unbounded work. A zero mantissa
    # passes `format_number_sql` at any exponent (0.0 is finite) — `"0e9000000000000000000"` asked
    # `repeat` for 9e18 zeros, and one past Int64 raised `OverflowError` — and a zero-PADDED mantissa
    # lets a huge exponent through too, because the padding cancels it: `"0.000…0001e10004"` is 1000.
    # So zero is zero at any exponent, and what is clamped is where the point LANDS, never the
    # exponent alone (which would move the point short of the padding and miscount the value). No
    # `NUMERIC` holds more than 1000 digits (PostgreSQL's cap on a declared precision; SQLite's is 15,
    # #648), so a point that lands past the cap marks a value too wide either way, and every value
    # that could fit is expanded exactly — `_decimal_digit_counts` drops the padding as leading zeros.
    all(==('0'), digits) && return "0"
    decimal_index = length(integer_part)
    # Bound the exponent by a magnitude no input's padding reaches (an input string is far shorter
    # than 2^40), so the sum cannot overflow; an exponent past Int64 takes that bound's sign.
    parsed_exponent = tryparse(Int, exponent_str)
    exponent = parsed_exponent === nothing ?
        (startswith(exponent_str, '-') ? -(1 << 40) : 1 << 40) :
        clamp(parsed_exponent, -(1 << 40), 1 << 40)
    target_index = clamp(decimal_index + exponent, -_MAX_EXPANDED_EXPONENT, length(digits) + _MAX_EXPANDED_EXPONENT)

    if target_index <= 0
        return string(sign, "0.", repeat("0", -target_index), digits)
    elseif target_index >= length(digits)
        return string(sign, digits, repeat("0", target_index - length(digits)))
    end

    return string(sign, digits[1:target_index], ".", digits[target_index + 1:end])
end

function _trim_fixed_point(value::AbstractString)::String
    trimmed = value
    if occursin('.', trimmed)
        trimmed = replace(trimmed, r"0+$" => "")
        trimmed = replace(trimmed, r"\.$" => "")
    end
    return trimmed in ("-0", "+0", "") ? "0" : trimmed
end

function _normalized_numeric_string(value)::String
    base = if value isa AbstractString
        strip(Models.format_number_sql(value))
    elseif value isa Integer
        string(value)
    elseif value isa AbstractFloat || value isa Decimals.Decimal
        string(value)
    else
        formatted = Models.format_number_sql(value)
        formatted isa AbstractString ? strip(formatted) : string(formatted)
    end

    return _trim_fixed_point(_expand_scientific_notation(base))
end

# The digits a value occupies in a `NUMERIC(p, s)` column, split at the point (#761): `whole` is
# checked against `p - s`, `frac` against `s`, and their sum against `p`. Leading zeros of the
# integer part are not digits — PostgreSQL stores `0.55` in `NUMERIC(2, 2)` — which is the fit rule
# the SQLite read parser applies (`Dialect._parse_sqlite_decimal`) and Django's `DecimalValidator`
# checks. Counting them used to refuse `0.55` there while accepting `1.5`, which does not fit.
function _decimal_digit_counts(value)::Tuple{Int, Int}
    value_str = replace(_normalized_numeric_string(value), r"^[+-]" => "")
    point_index = findfirst(==('.'), value_str)
    int_part = point_index === nothing ? value_str : value_str[1:point_index - 1]
    frac_part = point_index === nothing ? "" : value_str[point_index + 1:end]
    return (length(lstrip(==('0'), int_part)), length(frac_part))
end

function _validate_integer_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="pass 0 or 1 as Int64, not Bool")
    elseif value isa Integer
        return true
    elseif value isa Decimals.Decimal
        try
            Int64(value)
            return true
        catch
            _type_mismatch_error(operation, model, field, value, "Int64, an integer-valued Decimal, or an integer string"; suggestion="round or convert the Decimal to Int64 before calling $operation")
        end
    elseif value isa AbstractString
        stripped = strip(value)
        if _string_uses_scientific_notation(stripped)
            _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="replace scientific notation with a literal integer string like \"123\"")
        end
        # The formatter binds the TEXT, so the check is its grammar (#773): the bare parser also reads
        # `0x`/`0b`/`0o`, and even with `base = 10` it takes a space after the sign (`"+ 1"`).
        if Models.has_non_decimal_prefix(stripped)
            _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="write the integer in base 10 — the 0x, 0b and 0o prefixes are not accepted")
        end
        if !Models.is_base10_number(stripped) || tryparse(Int64, stripped; base = 10) === nothing
            _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="convert the value to Int64 before calling $operation")
        end
        return true
    elseif value isa AbstractFloat
        _type_mismatch_error(operation, model, field, value, "Int64 or an integer string"; suggestion="convert the value with Int64(...) before calling $operation")
    else
        _type_mismatch_error(operation, model, field, value, "Int64, an integer-valued Decimal, or an integer string")
    end
end

function _validate_decimal_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "a numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a literal numeric string")
    elseif value isa Integer || value isa Decimals.Decimal
        return true
    elseif value isa AbstractFloat
        isfinite(value) || _validation_error(operation, model, field, "non-finite numeric values are not allowed"; suggestion="pass a finite Float64 value")
        return true
    elseif value isa AbstractString
        try
            Models.format_number_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a literal numeric string like \"123.45\" or a Julia numeric value")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a literal numeric string")
    end
end

function _validate_float_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Bool
        _type_mismatch_error(operation, model, field, value, "a finite numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a parseable numeric string")
    elseif value isa Integer || value isa Decimals.Decimal
        return true
    elseif value isa AbstractFloat
        isfinite(value) || _validation_error(operation, model, field, "non-finite numeric values are not allowed"; suggestion="pass a finite Float64 value")
        return true
    elseif value isa AbstractString
        stripped = strip(value)
        isempty(stripped) && _validation_error(operation, model, field, "the value is empty and cannot be used as a number"; suggestion="pass a parseable numeric string like \"123.45\"")
        if occursin(r"^[+-]?\d+,\d+$", stripped)
            _validation_error(operation, model, field, "comma decimal separators are not supported"; suggestion="use '.' as the decimal separator")
        end
        # `tryparse(Float64, …)` takes hex (`"0x10"`, `"0x1p4"`), and the formatter binds the text (#773).
        if Models.has_non_decimal_prefix(stripped)
            _type_mismatch_error(operation, model, field, value, "a finite numeric value or numeric string"; suggestion="write the number in base 10 — the 0x, 0b and 0o prefixes are not accepted")
        end
        parsed = Models.is_base10_number(stripped) ? tryparse(Float64, stripped) : nothing
        parsed === nothing && _type_mismatch_error(operation, model, field, value, "a finite numeric value or numeric string"; suggestion="pass a parseable numeric string like \"123.45\" or \"1.23e4\"")
        isfinite(parsed) || _validation_error(operation, model, field, "non-finite numeric values are not allowed"; suggestion="pass a finite Float64 value")
        return true
    else
        _type_mismatch_error(operation, model, field, value, "a finite numeric value or numeric string"; suggestion="pass an Int64, Float64, Decimals.Decimal, or a parseable numeric string")
    end
end

function _validate_date_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Union{Date, DateTime, ZonedDateTime}
        return true
    elseif value isa AbstractString
        try
            Models.format_date_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a Date, DateTime, ZonedDateTime, or a YYYY-MM-DD string")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a Date, DateTime, ZonedDateTime, or YYYY-MM-DD string"; suggestion="normalize the value to a calendar date before calling $operation")
    end
end

function _validate_time_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Time
        return true
    elseif value isa AbstractString
        # Standard HH:MM or HH:MM:SS
        if occursin(r"^\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?$", value)
            try
                # Try to parse as Time to validate ranges
                Time(value)
                return true
            catch e
                _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a Time object or a valid HH:MM:SS string")
            end
        else
            _validation_error(operation, model, field, "invalid time format: $value"; suggestion="pass a Time object or an HH:MM:SS string")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a Time object or time string"; suggestion="use Time(...) or normalize to HH:MM:SS")
    end
end

function _validate_duration_value(model::PormGModel, field::String, value::Any, operation::String)
    try
        Models.format_duration_sql(value)
        return true
    catch e
        if value isa Union{Period, Dates.CompoundPeriod, AbstractString}
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a Period, CompoundPeriod, or a duration string like \"1:27.452\"")
        else
            _type_mismatch_error(operation, model, field, value, "a Period, CompoundPeriod, or duration string"; suggestion="use Minute(1) + Second(27) + Millisecond(452) or a string like \"1:27.452\"")
        end
    end
end

function _validate_datetime_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Union{DateTime, ZonedDateTime}
        return true
    elseif value isa AbstractString
        try
            Models.format_timezone_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a DateTime, ZonedDateTime, or a datetime string matching the configured timestamp format")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a DateTime, ZonedDateTime, or timezone-aware datetime string"; suggestion="use DateTime(...) or ZonedDateTime(...)")
    end
end

function _validate_uuid_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa UUIDs.UUID
        return true
    elseif value isa AbstractString
        try
            Models.format_uuid_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a UUID or a string in the format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a UUID or UUID-formatted string"; suggestion="use UUIDs.uuid4() or a string like \"550e8400-e29b-41d4-a716-446655440000\"")
    end
end

# The family check lives here rather than in the formatter: `protocol` is a slot of the field, and the
# formatter is one named function per field shape (see `Models.check_ip_protocol`). Every writer calls
# `_validate_field_value`, so every writer gets it.
function _validate_network_value(model::PormGModel, field::String, f_meta, value::Any, operation::String)
    cidr = getproperty(f_meta, :type) == "CIDR"
    example = cidr ? "\"10.0.0.0/24\"" : "\"10.0.0.1\""
    if value isa Union{AbstractString, Sockets.IPAddr}
        try
            text = f_meta.formatter(value)
            hasproperty(f_meta, :protocol) && Models.check_ip_protocol(f_meta.protocol, text)
            return true
        catch e
            e isa InvalidValueError || rethrow()
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass an address string like $example or a Sockets.IPv4 / Sockets.IPv6")
        end
    else
        _type_mismatch_error(operation, model, field, value, cidr ? "a CIDR network string" : "an IP address string"; suggestion="pass a string like $example or a Sockets.IPv4 / Sockets.IPv6")
    end
end

# #28. The shape first (a one-dimensional vector, a tuple, or an array literal), then each element
# exactly as the base field validates a scalar — so `ArrayField(CharField(max_length = 3))` refuses
# `["abcd"]` with CharField's own max_length message, naming the element. A NULL element is the base
# field's `null` rule. The formatter re-checks all of this; running it here first is what puts the
# model and field in the message, as every other field's validator does.
function _validate_array_value(model::PormGModel, field::String, f_meta, value::Any, operation::String)
    value isa PormGArrayLiteral && return true
    elems = if value isa AbstractString
        try
            Models.parse_pg_array_literal(value)
        catch e
            e isa InvalidValueError || rethrow()
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a Vector, e.g. [1, 2]")
        end
    elseif value isa Union{AbstractVector, Tuple}
        value
    else
        _type_mismatch_error(operation, model, field, value, "a Vector (an ArrayField holds a one-dimensional array)";
                             suggestion=value isa AbstractArray ? "pass a one-dimensional Vector" : "wrap a single element as [x]")
    end
    size = f_meta.size
    if size !== nothing && length(elems) > size
        _validation_error(operation, model, field, "holds at most $size elements (size = $size), got $(length(elems))")
    end
    base = f_meta.base_field
    for (i, el) in enumerate(elems)
        value isa AbstractString && el !== nothing && continue   # literal text: the formatter types it
        if el isa Union{AbstractArray, Tuple} && !(el isa AbstractString)
            _validation_error(operation, model, field, "element $i is a $(typeof(el)): an ArrayField holds a one-dimensional array")
        end
        if (el === nothing || ismissing(el)) && !base.null
            _validation_error(operation, model, field, "element $i is null, and the base field does not allow null elements";
                              suggestion="declare the element field with null = true")
        end
        _validate_field_value(model, "$field[$i]", base, el, operation)
    end
    return true
end

function _validate_json_value(model::PormGModel, field::String, value::Any, operation::String)
    if value isa Union{AbstractDict, AbstractVector, NamedTuple, Bool, Integer, AbstractFloat}
        return true
    elseif value isa AbstractString
        try
            Models.format_json_sql(value)
            return true
        catch e
            _validation_error(operation, model, field, sprint(showerror, e); suggestion="pass a valid JSON string, Dict, Vector, or scalar value")
        end
    else
        _type_mismatch_error(operation, model, field, value, "a valid JSON value (Dict, Vector, String, Number, Bool)"; suggestion="serialize to a JSON string or use a Dict/Vector")
    end
end

function _validate_binary_value(model::PormGModel, field::String, value::Any, operation::String)
    # Raw bytes, or a String taken as its UTF-8 code units (#296). The string form is what keeps a
    # column that used to render as TEXT writable without an app edit, and it agrees byte-for-byte
    # with the `convert_to(col, 'UTF8')` cast the PostgreSQL migration applies to the old data.
    if value isa AbstractVector{UInt8} || value isa AbstractString
        return true
    end
    _type_mismatch_error(operation, model, field, value, "raw bytes (Vector{UInt8}) or a String stored as its UTF-8 code units";
                         suggestion="for a hex or Base64 string, decode it first with hex2bytes(s) or base64decode(s)")
end

# Byte count for a BinaryField value, matching what the DDL CHECK measures on each backend.
# `ncodeunits` is the UTF-8 byte length of a String — deliberately NOT `length`, which counts
# characters and was the pre-#296 behavior this fixes.
_binary_byte_length(value::AbstractVector{UInt8})::Int = length(value)
_binary_byte_length(value::AbstractString)::Int = ncodeunits(value)

# The text a text field's `max_length` is measured against: the text `format_text_sql` will write
# (#868). A String is that text already; an integer or a date/time is written as its base-10 or ISO
# text (#860), which is the length the column holds, so it is measured too. `nothing` means there is
# no one text to measure: a field with another formatter, or a value `format_text_sql` refuses, which
# `_format_single` reports with its own typed error. A `Bool` is one of those (#876) — it has no
# single text — and needs its own method only because `Bool <: Integer` would reach the one below,
# whose formatter call would raise that refusal here, as a length check, instead.
_written_text(f_meta, value::AbstractString) = value
_written_text(f_meta, value::Bool) = nothing
_written_text(f_meta, value::Union{Integer, Date, DateTime, ZonedDateTime, Time}) =
    f_meta.formatter === Models.format_text_sql ? Models.format_text_sql(value) : nothing
_written_text(f_meta, value) = nothing

# One write value, checked to be a single value before it binds — every writer, both backends, so
# they all raise alike (#672 bulk_insert/bulk_update, #712 create/update/get_or_create/
# update_or_create and bulk_copy).
# Only a text-like field lets a collection through validation (`format_text_sql` maps a `Vector`
# element-wise, for `__in`), and no column stores one faithfully: PostgreSQL binds it as one array
# parameter (stored as `{"a","b"}` text), and SQLite expands it into extra `?` placeholders.
const _CollectionValue = Union{AbstractArray, Tuple, AbstractDict, NamedTuple}
_single_value(value, ::AbstractString, ::AbstractString) = value
function _single_value(value::_CollectionValue, field::AbstractString, op::AbstractString)
  throw(InvalidValueError("Error in $op, field `$field` was given a $(typeof(value)): a column holds a single value, not a collection."))
end

# The fields whose formatter turns a collection into ONE value: a `JSONField` serializes it to one
# JSON string, a `BinaryField` wraps a `Vector{UInt8}` as one blob, an `ArrayField` prints it as one
# array literal (#28). The binary half is keyed on the
# field struct, so `ImageField`/`FileField` (`"BLOB"`, but they hold path text) are not among them.
_takes_collection(f_meta) = _is_json_field(f_meta) || _is_binary_field(f_meta) || _is_array_field(f_meta)

# The write path's format step, used at every bind site. The raw value is checked BEFORE the
# formatter for every other field (#716): `format_text_sql` maps a collection element-wise, so an
# element it cannot format — `[1.5, 2.5]`, `["a", nothing]`, a tuple — crashed there first, as a raw
# `MethodError` that named no field. The formatted value is checked AFTER it too (#712), which is what
# lets a `JSONField` vector through: it is one string by then.
function _format_single(f_meta, field::AbstractString, value, op::AbstractString)
  _refuse_collection(f_meta, field, value, op)
  return _single_value(f_meta.formatter(value), field, op)
end

# The raw-value half on its own, for a caller that runs the bare formatter to find the failing cell
# (the bulk writers' `_depuration_values_bulk_insert`), so it raises this refusal rather than its own.
function _refuse_collection(f_meta, field::AbstractString, value, op::AbstractString)
  value isa _CollectionValue && !_takes_collection(f_meta) && _single_value(value, field, op)
  return nothing
end

function validate_field_data(model::PormGModel, field::String, value::Any, operation::String; allow_primary_key::Bool = true)
    f_meta = _validate_field_name(model, field, operation; allow_primary_key = allow_primary_key)
    return _validate_field_value(model, field, f_meta, value, operation)
end

# `validate_field_data`, split at the seam between what depends on the field alone and what depends
# on the value (#704). The bulk writers run the name half once per column and the value half once per
# cell: repeating the name half per cell cost a linear `field_names` scan and two dict lookups for
# every one of a 100k-row frame's 800k cells. Together the two halves are `validate_field_data`,
# check for check and message for message, so every other caller is unchanged.

# Steps 1–2: the checks that depend only on `field`. Returns the field struct the value half reads.
function _validate_field_name(model::PormGModel, field::String, operation::String; allow_primary_key::Bool = true)
    if haskey(model.fields, field) && Models.is_many_to_many_field(model.fields[field])
        _validation_error(operation, model, field, "many-to-many relations are not physical columns"; suggestion="use the many-to-many manager add, remove, clear, or set methods")
    end

    # 1. Field existence
    #
    # #462: an unknown field NAME is not a bad value, so it does not go through
    # `_validation_error`'s `InvalidValueError` — it raises `UnknownFieldError`, which is what
    # `docs/src/api.md` promises and what every other unknown-name site in `src/` already does,
    # `get_or_create`/`update_or_create` (object_manager.jl) and the bulk writers included. Same
    # funnel as the read path (`_unknown_field`), so a typo in `create()` reads exactly like a typo
    # in `filter()` — minus the reverse accessors, which are not writable columns.
    if !(field in model.field_names)
        throw(_unknown_field(model, field; include_accessors = false))
    end
    
    f_meta = model.fields[field]
    
    # 2. Primary key protection
    if !allow_primary_key && f_meta.primary_key
        _validation_error(operation, model, field, "primary keys cannot be modified in this operation")
    end

    return f_meta
end

# Steps 3–9: the checks on one value, given the field struct `_validate_field_name` returned.
function _validate_field_value(model::PormGModel, field::String, f_meta, value::Any, operation::String)
    # 3. Nullability check
    if !f_meta.null && (value === nothing || ismissing(value))
        _validation_error(operation, model, field, "null values are not allowed")
    elseif value === nothing || ismissing(value)
        return true
    end

    # 4. Skip further validation for SQL expressions (F-expressions, Functions)
    if value isa SQLTypeF || value isa SQLTypeFunction
        return true
    end

    # 5. Type validation for numeric fields.
    if _is_integer_field(f_meta)
        _validate_integer_value(model, field, value, operation)
    elseif _is_decimal_field(f_meta)
        _validate_decimal_value(model, field, value, operation)
    elseif _is_float_field(f_meta)
        _validate_float_value(model, field, value, operation)
    elseif _is_date_field(f_meta)
        _validate_date_value(model, field, value, operation)
    elseif _is_time_field(f_meta)
        _validate_time_value(model, field, value, operation)
    elseif _is_duration_field(f_meta)
        _validate_duration_value(model, field, value, operation)
    elseif _is_datetime_field(f_meta)
        _validate_datetime_value(model, field, value, operation)
    elseif _is_decimal_like_field(f_meta)
        _validate_decimal_value(model, field, value, operation)
    elseif _is_uuid_field(f_meta)
        _validate_uuid_value(model, field, value, operation)
    elseif _is_json_field(f_meta)
        _validate_json_value(model, field, value, operation)
    elseif _is_network_field(f_meta)
        _validate_network_value(model, field, f_meta, value, operation)
    elseif _is_binary_field(f_meta)
        _validate_binary_value(model, field, value, operation)
    elseif _is_array_field(f_meta)
        # Every check below is a scalar's, so the whole of an array's validation is here, and it
        # returns: the column-level checks (max_length, the decimal width) are the ELEMENTS', run per
        # element through this same function against the base field.
        return _validate_array_value(model, field, f_meta, value, operation)
    end

    # 6. Max length validation.
    #
    #    For a BinaryField the bound is a BYTE count (#296), and it applies to byte vectors too —
    #    the AbstractString-only branch below would let a Vector{UInt8} past unchecked and would
    #    measure a String in characters, neither of which matches the DDL CHECK the column carries.
    if _is_binary_field(f_meta) && f_meta.max_length !== nothing
        byte_length = _binary_byte_length(value)
        if byte_length > f_meta.max_length
            _validation_error(operation, model, field, "max_length is $(f_meta.max_length) bytes, but the provided value is $(byte_length) bytes")
        end
    #    For text fields it is a CHARACTER count of the text written, so an integer or a date is
    #    measured as its text, not skipped (#868). A CharField with no max_length (nothing) is
    #    unlimited (TEXT), so skip the check rather than comparing length against nothing.
    elseif hasfield(typeof(f_meta), :max_length) && f_meta.max_length !== nothing &&
           (text = _written_text(f_meta, value)) !== nothing
        if length(text) > f_meta.max_length
            written = value isa AbstractString ? "" : " (the $(typeof(value)) is written as $(repr(text)))"
            _validation_error(operation, model, field, "max_length is $(f_meta.max_length), but the provided value has length $(length(text))$written")
        end
    end
    
    # 7–9. DecimalField width — Django's three `DecimalValidator` bounds, in its order (#761).
    if _is_decimal_field(f_meta) && hasfield(typeof(f_meta), :max_digits) && hasfield(typeof(f_meta), :decimal_places)
        whole_digits, decimal_places = _decimal_digit_counts(value)

        # 7. Total digits.
        digit_count = whole_digits + decimal_places
        if digit_count > f_meta.max_digits
            _validation_error(operation, model, field, "max_digits is $(f_meta.max_digits), but the normalized numeric value uses $digit_count digits")
        end

        # 8. Fractional digits.
        if decimal_places > f_meta.decimal_places
            _validation_error(operation, model, field, "decimal_places is $(f_meta.decimal_places), but the normalized numeric value uses $decimal_places fractional digits")
        end

        # 9. Whole digits. Without it `DecimalField(5, 2)` let `1234.5` through: 5 digits in total and
        #    1 fractional both fit, 4 whole ones do not. PostgreSQL then refused it as a driver
        #    `numeric field overflow`, and SQLite stored it — a cell #648's read parser cannot rebuild.
        max_whole = f_meta.max_digits - f_meta.decimal_places
        if whole_digits > max_whole
            _validation_error(operation, model, field, "max_digits - decimal_places is $max_whole, so at most $max_whole digits fit before the decimal point, but the normalized numeric value uses $whole_digits")
        end
    end

    return true
end
