## `IntegrityError` / `OperationalError` / `StatementError` — the rendered text no longer carries the database's DETAIL; the reason is data (#987)

- **Version**: Unreleased
- **PormG ref**: #987 ; `src/exceptions.jl` (`DatabaseError`), `src/Backend.jl` (`backend_error_fields`), `src/ConnectionPool.jl` (`_as_database_error`), the three `ext/` drivers
- **Recorded**: 2026-10-06
- **Severity**: behavior change. `error_message(e)`, `sprint(showerror, e)` and `string(e)` of a `DatabaseError` used to end with the driver's full text. They now render from structured fields only, and never contain the database's `DETAIL`, `HINT` or `LINE n:` excerpt, or the message of a SQLSTATE class `22` error. Those quote the row or the value. The driver's text is unchanged in `e.cause`.

### What changed

The three subtypes rendered their `cause` verbatim. On PostgreSQL that is the server's whole message,
and it quotes user data: a unique violation's `DETAIL:  Key (code)=(SEN) already exists.`, an
input-syntax error's `invalid input syntax for type uuid: "<value>"`. An app that returned
`error_message(e)` to a client, which the docs taught, returned the value to whoever it answered. #971
settled the same rule for PormG's own refusals.

Each subtype now carries the reason as data: `sqlstate`, `constraint`, `table`, `column`, and
`message` (the server's primary message, `nothing` for class 22). Every rendering is built from those
fields.

| `e` | `error_message(e)` before | `error_message(e)` after |
|---|---|---|
| unique violation (LibPQ) | `IntegrityError: PostgreSQL rejected the statement — a constraint was violated: UniqueViolation: ERROR:  duplicate key value violates unique constraint "driver_code_key"` + `DETAIL:  Key (code)=(SEN) already exists.` | `IntegrityError: PostgreSQL rejected the statement — a constraint was violated (SQLSTATE 23505, constraint "driver_code_key", table "driver"): duplicate key value violates unique constraint "driver_code_key" (the driver's full text is in `.cause`)` |
| the same on Postgres.jl | the driver's multi-line rendering, `Detail:` included | as above |
| bad uuid input (class 22) | `… could not be executed: InvalidTextRepresentation: ERROR:  invalid input syntax for type uuid: "<value>"` + `LINE 1: …` | `StatementError: the PostgreSQL statement could not be executed (SQLSTATE 22P02). The server's message quotes the input, so it is not shown (the driver's full text is in `.cause`)` |
| SQLite unique violation | `… a constraint was violated: UNIQUE constraint failed: driver.code` | `… a constraint was violated: UNIQUE constraint failed: driver.code (the driver's full text is in `.cause`)` |

The two-argument constructors still work, with every new field `nothing`. Such an error names its
cause by type alone. A `String` cause, which PormG passes for advisory-lock contention, is still the
message.

### Who this affects

Code that reads the database's text out of a `DatabaseError`'s rendering: a parse of `DETAIL`, a
search for the key value, or a test that asserts on the full driver message. Code that passes `sprint(showerror, error)` from a generic handler
straight into an HTTP response now returns the safe text with no edit, which is the exposure this
closes.

### How to find the calls to migrate

```bash
grep -rnE 'error_message\(|sprint\(showerror|\.cause\b|DETAIL|Key \(' --include=*.jl src/ test/
```

Read each hit that handles a `DatabaseError`. Text-parsing a constraint name or a SQLSTATE becomes a
field read.

### Migrate your app

```julia
# ✗ before — the DETAIL read out of the rendered text; it is no longer there, so `m` is `nothing`
catch e
    m = match(r"Key \((\w+)\)=", error_message(e))
    e isa IntegrityError && m !== nothing && return conflict("$(m[1]) is taken")
end

# ✓ after — the reason as data. Both PostgreSQL drivers report `constraint`, `table` and `column`
#   (#1000), and `error_message(e)` is now safe to return to the client
catch e
    e isa IntegrityError && e.sqlstate == "23505" && return conflict(error_message(e))
    e isa IntegrityError && e.constraint == "driver_code_key" && return conflict("code is taken")
end

# ✓ the full driver text, DETAIL and value included, for a trusted log sink only
@error "insert failed" driver_text = sprint(showerror, e.cause)
```
