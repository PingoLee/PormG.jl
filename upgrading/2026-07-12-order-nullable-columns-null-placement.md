## `order_by` on nullable columns — NULL placement normalized to PostgreSQL's convention on both backends

- **PormG ref**: issue #75 / PR #120 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (result order can change on SQLite)

### What changed

Top-level `ORDER BY` used to render a bare `expr ASC|DESC`, and PostgreSQL and SQLite default
NULLs to **opposite ends** — so ordering a nullable column returned different rows per backend,
and with `.first()` / `.page()` that changed *which* rows you got. PormG now emits an explicit
NULLS clause matching PostgreSQL's default on **both** backends: ASC → `NULLS LAST`,
DESC → `NULLS FIRST` (SQLite < 3.30.0 gets an equivalent portable `(expr IS NULL)` prefix).
Per-term override: `SQLOrder(field; nulls = :first | :last)`. Window `OVER(...)` ordering is
**not** yet normalized (follow-up pending).

**PostgreSQL-backed apps see no change.** SQLite-backed apps: any `order_by` on a nullable key
may now sort NULL rows to the other end.

### How to find the calls to migrate

No API change and nothing errors. In SQLite-backed apps, review `order_by` calls on **nullable**
columns whose consumers depend on row order — `.first()`, pagination, "top N" reports.

### Migrate your app

```julia
# Only if the app depended on SQLite's old NULLS-first-on-ASC ordering — pin it explicitly:
using PormG.QueryBuilder: SQLOrder, SQLField

M.Driver.objects.values("surname", "nationality").order_by(
    SQLOrder(SQLField("nationality", "nationality"); orientation = "ASC", nulls = :first)
).list()
```
