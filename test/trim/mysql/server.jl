# The MySQL server the fixture talks to, read from the environment at run time (#1599, #1614). Included by
# `main.jl` (the trimmed entry) and `prep.jl` (the JIT seeding script), so both point at the same database.
#
#   PORMG_TRIM_HOST      default 127.0.0.1
#   PORMG_TRIM_PORT      default 1: nothing listens there, so the read stops at the connect
#   PORMG_TRIM_USER      default f1
#   PORMG_TRIM_DATABASE  default f1
#   PORMG_TRIM_PASSWORD  default f1; read from the environment only, never printed
#
# With none of them set the URL is `mysql://f1:f1@127.0.0.1:1/f1`, the fixture's port-1 default, so a run
# without a server behaves as it always has. The variables are read inside a function, at run time: a read
# at the top level of the entry would be frozen into the image when juliac writes it.

"The environment variable `name`, or `default` when it is unset or empty."
function trim_env(name::String, default::String)::String
    v = get(ENV, name, "")
    return isempty(v) ? default : v
end

struct TrimServer
    host::String
    port::String
    user::String
    password::String
    database::String
end

trim_server() = TrimServer(trim_env("PORMG_TRIM_HOST", "127.0.0.1"), trim_env("PORMG_TRIM_PORT", "1"),
    trim_env("PORMG_TRIM_USER", "f1"), trim_env("PORMG_TRIM_PASSWORD", "f1"),
    trim_env("PORMG_TRIM_DATABASE", "f1"))

const _HEX = b"0123456789ABCDEF"

"`s` percent-encoded for one part of a URL: every byte except the unreserved ones (RFC 3986)."
function trim_urlencode(s::String)::String
    io = IOBuffer(sizehint = ncodeunits(s))
    for b in codeunits(s)
        if UInt8('A') <= b <= UInt8('Z') || UInt8('a') <= b <= UInt8('z') || UInt8('0') <= b <= UInt8('9') ||
           b == UInt8('-') || b == UInt8('.') || b == UInt8('_') || b == UInt8('~')
            write(io, b)
        else
            write(io, UInt8('%'), _HEX[(b >> 4) + 1], _HEX[(b & 0x0f) + 1])
        end
    end
    return String(take!(io))
end

"The connection URL `register_connection` takes (#1769). It holds the password: never print it."
trim_url(s::TrimServer) = string("mysql://", trim_urlencode(s.user), ":", trim_urlencode(s.password), "@",
    s.host, ":", s.port, "/", trim_urlencode(s.database))

"What a step line may say about the server: where it is, never who connects or with what."
trim_where(s::TrimServer) = string(s.host, ":", s.port, "/", s.database)
