## `Concat` — a NULL operand is skipped on SQLite too, so the result is never NULL (#1006)

- **Version**: Unreleased
- **PormG ref**: #1006 ; `src/Dialect.jl` (`CONCAT`, SQLite arm)
- **Recorded**: 2026-10-07
- **Severity**: behavior change. On SQLite, a `Concat` with a NULL operand reads the other operands joined, where it read `missing`. PostgreSQL already skipped a NULL operand, so nothing changes there.

### What changed

PostgreSQL renders `Concat` as `CONCAT(…)`, which skips a NULL argument. SQLite rendered
`a || b || …`, which makes the whole result NULL when any operand is. The two engines therefore
disagreed on any row with a NULL operand. SQLite now wraps each operand in `COALESCE(operand, '')`,
so both engines skip it, as Django's `Concat` does on every backend. No parameter is added: the
`''` is a SQL literal.

The `@yyyy_q` / `@yyyy_quad` labels are not affected. They stay NULL for a NULL date on both engines
(#997).

| SQLite, a driver whose `number` is NULL | before | after |
|---|---|---|
| `values("n" => Concat(Value("#"), "number", Value(" "), "surname"))` | `missing` | `"# Senna"` |

### Who this affects

Code on SQLite that relies on a `Concat` reading `missing` when an operand is NULL. Measured on
2026-10-07: **0** `Concat(` call sites in the consuming apps.

### How to find the calls to migrate

```bash
grep -rn 'Concat(' --include=*.jl src/ test/
```

Read each hit that has a nullable operand.

### Migrate your app

```julia
# before — SQLite only: NULL when the driver has no number
q = M.Driver.objects
q.values("n" => Concat(Value("#"), "number"))

# after — NULL on both engines when the driver has no number, said explicitly
q = M.Driver.objects
q.values("n" => Case(When("number__@isnull" => false, then = Concat(Value("#"), "number"))))
```
