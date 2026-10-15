## Postgres.jl driver: an unsupported `sslmode` or `gssencmode` is refused before connecting (#1242)

- **Version**: Unreleased
- **PormG ref**: #1242 ; `ext/PormGPostgresExt.jl` (`_checked_params`)
- **Recorded**: 2026-10-15
- **Severity**: behavior change, on the Postgres.jl driver only (`postgres_driver: Postgres`). The
  LibPQ.jl driver is unchanged.

### What changed

Postgres.jl reads any `sslmode` or `gssencmode` value when it parses a connection string. It
refuses an unsupported one only when it connects: `gssencmode` before dialling, `sslmode` once
the socket is open. Its message echoes the value. In a URL whose password was not percent-encoded,
that value can be the tail of the password. PormG now checks both settings on what the driver
parsed, before any I/O:

| `sslmode` / `gssencmode` on the Postgres.jl driver | before | now |
|---|---|---|
| `allow`, `verify-ca`, or any other value Postgres.jl does not support | each attempt failed with the driver's `invalid sslmode: <value>` / `invalid gssencmode: <value>`, and the pool retried until its timeout | `PoolConnectError` whose `cause` is an `InvalidConfigurationError` naming the setting and the values it accepts, never the value. It is raised before any I/O and fails fast, as a permanent error |
| empty (`sslmode=''`, `?gssencmode=`, an unexpanded `${PGSSLMODE}`) | the same connect-time failure | the same `InvalidConfigurationError`, saying the setting is empty |
| a `sslmode` the driver does not support, with `gssencmode=prefer` and a Kerberos ticket | connected over GSS when the server offered it; otherwise the connect-time failure | refused, as in the first row |
| a `sslmode` the driver does not support, with `gssencmode=require` | connected over GSS, or failed on GSS: the driver never reads `sslmode` | unchanged: not checked |
| `disable`, `prefer`, `require`, `verify-full` (`sslmode`); `disable`, `prefer`, `require` (`gssencmode`), in any case | connected | unchanged |
| unset | connected | unchanged |

The setting is checked wherever it came from: the connection string, `connection.yml`, or
`PGSSLMODE` / `PGGSSENCMODE`.

### Who this affects

Configurations that use the Postgres.jl driver with a libpq-only TLS mode (`allow`, `verify-ca`)
or an empty one. Without GSS encryption, neither ever connected. The one configuration that did
connect and is now refused is an unsupported `sslmode` alongside `gssencmode=prefer`, connecting
over GSS. Set `sslmode` to a supported value, or use `gssencmode=require`. Otherwise what changes
is the error: code that inspected the driver's connect-time error for these strings now sees an
`InvalidConfigurationError` as the `PoolConnectError` cause, raised before any I/O.

### How to find the calls to migrate

```bash
grep -rn 'sslmode\|gssencmode\|PGSSLMODE\|PGGSSENCMODE' --include=*.jl --include=*.yml --include=*.env .
```

For each match on a Postgres.jl connection, check that the value is one listed above.

### Migrate your app

```yaml
# ✗ before: refused (the driver has no verify-ca)
dev:
  adapter: PostgreSQL
  database: f1
  postgres_driver: Postgres
  sslmode: verify-ca

# ✓ after: verify-full, which also checks the host name, or the LibPQ.jl driver for verify-ca
dev:
  adapter: PostgreSQL
  database: f1
  postgres_driver: Postgres
  sslmode: verify-full
```
