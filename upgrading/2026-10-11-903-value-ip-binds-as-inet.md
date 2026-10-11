## PostgreSQL: `Value(ip)` binds an IP address typed `::inet` (#903)

- **Version**: Unreleased
- **PormG ref**: #903 ; `src/querybuilder/parameters.jl` (the PostgreSQL scalar `add_parameter!` arm)
- **Recorded**: 2026-10-11
- **Severity**: behavior change, PostgreSQL only. The rendered SQL changes, and an expression that
  mixed an IP literal with text now fails PostgreSQL's type check.

### What changed

`Value(ip"10.0.0.1")` (any `Sockets.IPAddr`) pushed the Julia struct as an untyped parameter, which
the driver sent as text and the server typed from context. It now binds the address's canonical
text with an explicit `::inet`:

| Expression | before | after |
|---|---|---|
| `Value(ip"10.0.0.1")` rendered | `$1` (untyped) | `$1::inet` |
| `Coalesce("circuitref", Value(ip"10.0.0.1"))` — a text column and an IP literal | ran, typed as text | PostgreSQL refuses it (text vs inet) |

SQLite does not take an IP value; that is unchanged.

### Who this affects

Queries that pass a `Sockets.IPv4` / `IPv6` value through `Value(…)` on PostgreSQL, and golden
tests that pin their SQL.

### How to find the calls to migrate

```bash
grep -rnE 'Value\((ip"|IPv4\(|IPv6\(|Sockets\.)' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — the IP literal was typed as text from context
M.Circuit.objects.values("c" => Coalesce("circuitref", Value(ip"10.0.0.1")))

# ✓ after — when you mean text, pass text
M.Circuit.objects.values("c" => Coalesce("circuitref", Value(string(ip"10.0.0.1"))))
```
