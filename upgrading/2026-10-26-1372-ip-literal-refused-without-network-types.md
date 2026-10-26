## `Value(ip"…")` on SQLite raises `BackendCapabilityError` while the query is built (#1372)

- **Version**: Unreleased
- **PormG ref**: #1372 ; `src/querybuilder/parameters.jl` (`add_parameter!(::SQLInstruction, ::Sockets.IPAddr)`)
- **Recorded**: 2026-10-26
- **Severity**: behavior change, SQLite only. A `Sockets.IPv4` / `Sockets.IPv6` literal raises `BackendCapabilityError` where it raised `InvalidValueError`. PostgreSQL is unchanged: it binds the literal as an `inet`. MySQL is unreleased.

### What changed

PostgreSQL is the only backend with network address types (`network_types` in the capability
table). A `GenericIPAddressField` column, an `inet` cast and every `@net_*` lookup were already
refused on the others through that table. A scalar `Sockets` literal was not. On SQLite it reached
the parameter bind, which refused it as a value SQLite cannot store (`InvalidValueError`,
"SQLite.jl would store it as a serialized Julia object"), and that message did not say the backend
has no network type.

The literal is now refused when the query is built, wherever it appears: projected
(`Value(ip"…")`, or a vector of addresses, `Value([ip"…", ip"…"])`), inside a function
(`Coalesce("relay", Value(ip"…"))`), in a `Case` branch, or in a function compared in a filter. The `BackendCapabilityError` names the feature, the backend at hand
and the backend that has it, and never shows the address.

`BackendCapabilityError` is not a `UsageError`, so a `catch e isa UsageError` (or
`isa InvalidValueError`) around such a query no longer matches.

| `values("p" => Value(ip"10.0.0.1"))` | before | now |
|---|---|---|
| PostgreSQL | `$1::inet`, bound `"10.0.0.1"` | unchanged |
| SQLite | `InvalidValueError` | `BackendCapabilityError` |

### How to find the calls to migrate

Look for `ip"` or `Sockets.IPv4(` / `Sockets.IPv6(` inside `Value(...)`, a function call or a
`Case(...)`, in code that runs on SQLite. Also look for a `catch` of `InvalidValueError` or
`UsageError` around such a query.

### Migrate your app

```julia
# ✗ before: caught as a usage error on SQLite
try
    q = M.Pit_stops.objects
    q.values("stop", "garage" => Value(ip"10.20.0.7"))
    q.list()
catch e
    e isa PormG.InvalidValueError || rethrow()
end

# ✓ after: the address as text, if text is all the query needs
q = M.Pit_stops.objects
q.values("stop", "garage" => Value(string(ip"10.20.0.7")))
q.list()

# ✓ after: or catch the capability refusal
try
    q = M.Pit_stops.objects
    q.values("stop", "garage" => Value(ip"10.20.0.7"))
    q.list()
catch e
    e isa PormG.BackendCapabilityError || rethrow()
end
```
