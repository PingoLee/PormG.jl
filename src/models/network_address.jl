# ─────────────────────────────────────────────────────────────────────────────
# Network-address formatting (#28) — `GenericIPAddressField` (`inet`) and `CIDRField` (`cidr`)
# ─────────────────────────────────────────────────────────────────────────────
#
# PostgreSQL only: these fields have no SQLite column (`Dialect._refuse_specialized_sqlite_type`), so
# nothing here exists to make SQLite imitate `inet`. It serves PostgreSQL, twice:
#
#   * VALIDATION, before a value reaches the server — Django's shape. A bad address is reported as
#     PormG's own `InvalidValueError` naming the field, on every writer, rather than as a driver error
#     from inside a transaction (or a whole `bulk_copy` chunk).
#   * The PRINTED FORM, which every value is written in: THE TEXT POSTGRESQL ITSELF PRINTS for it. A
#     column default is where this is load-bearing. The catalog stores a default as `inet_out` prints
#     it (`'2001:db8::1'::inet`), and the planner compares that against the declared one, so a
#     `default = "2001:DB8::1"` that was not normalized would plan a default change on every
#     `makemigrations`. Writing every VALUE in the same form keeps one definition of "the stored text"
#     — what `create` returns is what a re-read returns. The integration suite checks the form against
#     the server: each value of a golden corpus is written and read back, and must equal what these
#     functions produced.
#
# The parser is PormG's own rather than `Sockets`'. `parse(Sockets.IPv4, "10.1")` accepts the
# classful short forms (`10.1` is `10.0.0.1`), and the IPv6 parser lets an over-long group overflow
# into its neighbour; `print(::Sockets.IPv6)` never writes an embedded IPv4, so it cannot produce
# PostgreSQL's text either. This parser is STRICTER than the server — no short forms, no leading
# zeros, no zone id — which is the safe direction: a value refused here is one the user can respell,
# while one accepted here and refused by the server would fail inside a transaction.

# `family` is 4 or 6; an IPv4 address sits in the low 32 bits of `addr`. `bits` is the `/n` the text
# carried, or `nothing` when it had none — the two are kept apart because `GenericIPAddressField`
# refuses any prefix while `CIDRField` defaults a missing one to the full width.
struct _ParsedIP
  family::Int
  addr::UInt128
  bits::Union{Int, Nothing}
end

_ip_maxbits(family::Int)::Int = family == 4 ? 32 : 128

# `[0-9]`, not `\d`, which matches every Unicode digit. No leading zero: `010` is ten to PostgreSQL
# and eight to `inet_aton`, so the spelling is ambiguous and is refused rather than guessed.
const _IP_DECIMAL = r"^(?:0|[1-9][0-9]{0,2})$"
const _IPV6_GROUP = r"^[0-9A-Fa-f]{1,4}$"

_ip_invalid(raw, why::AbstractString) =
  throw(InvalidValueError("Invalid IP address: $why.", :format))

function _parse_ipv4(s::AbstractString)::Union{UInt32, Nothing}
  parts = split(s, '.')
  length(parts) == 4 || return nothing
  v = UInt32(0)
  for p in parts
    occursin(_IP_DECIMAL, p) || return nothing
    octet = parse(Int, p)
    octet <= 255 || return nothing
    v = (v << 8) | UInt32(octet)
  end
  return v
end

# One side of a `::` (or the whole address when there is none) as 16-bit words. Only the LAST group
# of the whole address may be a dotted IPv4, and it counts as two words.
function _ipv6_words(groups::AbstractVector, v4_last::Bool)::Union{Vector{UInt16}, Nothing}
  words = UInt16[]
  for (i, g) in enumerate(groups)
    if v4_last && i == length(groups) && occursin('.', g)
      v4 = _parse_ipv4(g)
      v4 === nothing && return nothing
      push!(words, UInt16(v4 >> 16), UInt16(v4 & 0xffff))
    else
      occursin(_IPV6_GROUP, g) || return nothing
      push!(words, parse(UInt16, g; base = 16))
    end
  end
  return words
end

function _parse_ipv6(s::AbstractString)::Union{UInt128, Nothing}
  occursin(":::", s) && return nothing
  halves = split(s, "::")
  length(halves) > 2 && return nothing
  compressed = length(halves) == 2
  _groups(h) = isempty(h) ? SubString{String}[] : split(h, ':')
  head = _ipv6_words(_groups(halves[1]), !compressed)
  head === nothing && return nothing
  tail = compressed ? _ipv6_words(_groups(halves[2]), true) : UInt16[]
  tail === nothing && return nothing
  n = length(head) + length(tail)
  # Without `::` the address is all eight words; with it, `::` stands for at least one zero word —
  # PostgreSQL refuses `1:2:3:4:5:6:7:8::` as a ninth word, and so does this.
  (compressed ? n <= 7 : n == 8) || return nothing
  words = vcat(head, zeros(UInt16, 8 - n), tail)
  addr = UInt128(0)
  for w in words
    addr = (addr << 16) | UInt128(w)
  end
  return addr
end

function _parse_ip(raw::AbstractString)::_ParsedIP
  s = strip(String(raw))
  isempty(s) && _ip_invalid(raw, "the value is empty")
  addr_text, bits = s, nothing
  if occursin('/', s)
    parts = split(s, '/')
    length(parts) == 2 || _ip_invalid(raw, "it contains more than one '/'")
    addr_text = parts[1]
    occursin(_IP_DECIMAL, parts[2]) ||
      _ip_invalid(raw, "the prefix length after '/' must be a whole number with no leading zero")
    bits = parse(Int, parts[2])
  end
  family, addr = if occursin(':', addr_text)
    a = _parse_ipv6(addr_text)
    a === nothing && _ip_invalid(raw, "it is not a valid IPv6 address")
    6, a
  else
    a = _parse_ipv4(addr_text)
    a === nothing && _ip_invalid(raw, "it is not a valid IPv4 address (four decimal octets 0-255, " *
                                      "with no leading zeros)")
    4, UInt128(a)
  end
  bits !== nothing && bits > _ip_maxbits(family) &&
    _ip_invalid(raw, "the prefix /$bits is longer than an IPv$family address ($(_ip_maxbits(family)) bits)")
  return _ParsedIP(family, addr, bits)
end

_parsed_ip(value::AbstractString)::_ParsedIP = _parse_ip(value)
_parsed_ip(value::Sockets.IPv4)::_ParsedIP = _ParsedIP(4, UInt128(value.host), nothing)
_parsed_ip(value::Sockets.IPv6)::_ParsedIP = _ParsedIP(6, value.host, nothing)

_render_ipv4(v::UInt32)::String = join((Int((v >> s) & 0xff) for s in (24, 16, 8, 0)), '.')

# A port of PostgreSQL's `inet_net_ntop_ipv6` (src/port/inet_net_ntop.c), which is what `inet_out`
# and `cidr_out` print through: the LONGEST run of zero words becomes `::` (the first one on a tie,
# and only a run of two or more), hex is lowercase without leading zeros, and the last 32 bits are
# printed as dotted IPv4 when the address is IPv4-compatible (`::a.b.c.d`) or IPv4-mapped
# (`::ffff:a.b.c.d`). The C source has a third embedding clause (a zero run of seven) that cannot be
# reached — the word it inspects is inside the run — so it has no counterpart here.
function _render_ipv6(addr::UInt128)::String
  words = [UInt16((addr >> (16 * (7 - i))) & 0xffff) for i in 0:7]
  best_base, best_len = -1, 0
  cur_base, cur_len = -1, 0
  for i in 0:7
    if words[i + 1] == 0
      if cur_base == -1
        cur_base, cur_len = i, 1
      else
        cur_len += 1
      end
    elseif cur_base != -1
      if best_base == -1 || cur_len > best_len
        best_base, best_len = cur_base, cur_len
      end
      cur_base = -1
    end
  end
  if cur_base != -1 && (best_base == -1 || cur_len > best_len)
    best_base, best_len = cur_base, cur_len
  end
  best_len < 2 && (best_base = -1)

  io = IOBuffer()
  for i in 0:7
    if best_base != -1 && best_base <= i < best_base + best_len
      i == best_base && print(io, ':')
      continue
    end
    i != 0 && print(io, ':')
    if i == 6 && best_base == 0 && (best_len == 6 || (best_len == 5 && words[6] == 0xffff))
      print(io, _render_ipv4(UInt32(addr & 0xffffffff)))
      return String(take!(io))
    end
    print(io, string(words[i + 1]; base = 16))
  end
  best_base != -1 && best_base + best_len == 8 && print(io, ':')
  return String(take!(io))
end

_render_ip(family::Int, addr::UInt128)::String =
  family == 4 ? _render_ipv4(UInt32(addr)) : _render_ipv6(addr)

# The host bits of a `/bits` network: everything to the right of the mask.
function _ip_host_mask(family::Int, bits::Int)::UInt128
  width = _ip_maxbits(family) - bits
  width == 0 && return UInt128(0)
  width == 128 && return typemax(UInt128)
  return (UInt128(1) << width) - UInt128(1)
end

function _inet_text(value, unpack_ipv4::Bool)::String
  p = _parsed_ip(value)
  p.bits === nothing || throw(InvalidValueError(
    "Invalid IP address: a GenericIPAddressField holds one host address, and a " *
    "'/$(p.bits)' prefix makes it a network. Store the address without the prefix, or use a " *
    "CIDRField for a network.", :format))
  # Django's `unpack_ipv4`: only the IPv4-MAPPED form (`::ffff:a.b.c.d`) is a v4 address in v6
  # clothing. The IPv4-compatible form (`::a.b.c.d`) is deprecated and is left as written, as Django
  # leaves it.
  if unpack_ipv4 && p.family == 6 && (p.addr >> 32) == 0xffff
    return _render_ipv4(UInt32(p.addr & 0xffffffff))
  end
  return _render_ip(p.family, p.addr)
end

const _NETWORK_VALUE_TYPES = "a String or a Sockets.IPv4 / Sockets.IPv6"

"""
    format_inet_sql(value) -> Union{String, Missing}

`GenericIPAddressField`'s formatter (#28): one host address — IPv4 or IPv6, as a String or a
`Sockets.IPAddr` — normalized to the text PostgreSQL's `inet` prints for it, which is the form the
catalog stores a column default in. A `/prefix` raises `InvalidValueError`: a network belongs in a
`CIDRField`.
"""
format_inet_sql(value::Union{Missing, Nothing}) = missing
format_inet_sql(value::Union{AbstractString, Sockets.IPAddr})::String = _inet_text(value, false)
format_inet_sql(value) =
  throw(InvalidValueError("An IP address must be $(_NETWORK_VALUE_TYPES), got $(typeof(value))."))

"""
    format_inet_unpacked_sql(value) -> Union{String, Missing}

`format_inet_sql` for a `GenericIPAddressField(unpack_ipv4 = true)`: an IPv4-mapped IPv6
address (`::ffff:10.0.0.1`) is stored as its IPv4 form (`10.0.0.1`), as Django's `unpack_ipv4` does.
"""
format_inet_unpacked_sql(value::Union{Missing, Nothing}) = missing
format_inet_unpacked_sql(value::Union{AbstractString, Sockets.IPAddr})::String = _inet_text(value, true)
format_inet_unpacked_sql(value) = format_inet_sql(value)

"""
    format_cidr_sql(value) -> Union{String, Missing}

`CIDRField`'s formatter (#28): one network in CIDR notation, normalized to the text PostgreSQL's
`cidr` prints — always with its `/prefix`, which defaults to the full width (`/32`, `/128`) when the
value has none. Bits set to the right of the mask raise `InvalidValueError`, as PostgreSQL refuses
them: `10.0.0.1/24` is a host inside `10.0.0.0/24`, not a network.
"""
format_cidr_sql(value::Union{Missing, Nothing}) = missing
function format_cidr_sql(value::Union{AbstractString, Sockets.IPAddr})::String
  p = _parsed_ip(value)
  bits = something(p.bits, _ip_maxbits(p.family))
  mask = _ip_host_mask(p.family, bits)
  if p.addr & mask != 0
    throw(InvalidValueError(
      "Invalid CIDR network: it has bits set to the right of the /$bits mask. Write the " *
      "network address, with those host bits zero. A single host address belongs in a " *
      "GenericIPAddressField.", :format))
  end
  return "$(_render_ip(p.family, p.addr))/$bits"
end
format_cidr_sql(value) =
  throw(InvalidValueError("A CIDR network must be $(_NETWORK_VALUE_TYPES), got $(typeof(value))."))

"""
    format_inet_network_sql(value) -> Union{String, Missing}

The value of a network containment lookup (`@net_contained`, `@net_contains`, …, #904): one `inet`
value, normalized to the text PostgreSQL's `inet` prints for it. Neither field's own formatter fits.
`format_inet_sql` refuses a `/prefix`, and the operand is usually a network. `format_cidr_sql`
refuses bits set to the right of the mask, and PostgreSQL's `<<` takes those on an `inet` operand.
So a prefix is allowed and the host bits are kept: `"10.20.0.9/16"` stays `"10.20.0.9/16"`. A
full-width prefix is dropped, as `inet_out` drops it (`"10.0.0.1/32"` prints `"10.0.0.1"`).
"""
format_inet_network_sql(value::Union{Missing, Nothing}) = missing
function format_inet_network_sql(value::Union{AbstractString, Sockets.IPAddr})::String
  p = _parsed_ip(value)
  text = _render_ip(p.family, p.addr)
  (p.bits === nothing || p.bits == _ip_maxbits(p.family)) && return text
  return "$text/$(p.bits)"
end
format_inet_network_sql(value) =
  throw(InvalidValueError("A network lookup value must be $(_NETWORK_VALUE_TYPES), got $(typeof(value))."))

"""
    check_ip_protocol(protocol, text) -> String

Refuse a normalized address whose family `GenericIPAddressField(protocol = …)` does not allow, and
return it unchanged otherwise. `protocol` is the field's lower-cased slot: `"both"`, `"ipv4"` or
`"ipv6"`. Raises `InvalidValueError`.

Kept out of the formatter on purpose: the formatter is one named function per field shape, which is
what lets `Model_to_str` and the kwargs snapshot treat it as a constant, and `protocol` is a slot.
"""
function check_ip_protocol(protocol::AbstractString, text::AbstractString)::String
  protocol == "both" && return String(text)
  family = occursin(':', text) ? "ipv6" : "ipv4"
  family == protocol && return String(text)
  _label(p) = p == "ipv4" ? "IPv4" : "IPv6"
  throw(InvalidValueError("The value is an $(_label(family)) address, but this field accepts " *
                          "$(_label(protocol)) addresses only (protocol = \"$protocol\").", :format))
end
