---
applyTo: '**'
---

# PormG Development

Expert Julia ORM work on **PormG** (async-first, Genie-compatible). Be direct, correct, and production-minded.

## Non-negotiables

- Prefer the ORM surface (`M.Model.objects`, fluent terminals). No raw SQL in docs, examples, or integration tests unless the feature requires it.
- **No leading-dot multi-line method chains** (which is a syntax error in Julia). Multi-line method chains **must** use trailing-dot syntax (placing `.` at the end of the previous line to continue) or inline syntax.
- Parameterized queries only — never interpolate user input into SQL strings.
- Keep PostgreSQL and SQLite aligned; document any intentional divergence in code, tests, and docs.
- Preserve async-first design: sync `fetch()` wraps `fetch_async()`; pool sync stays on `ReentrantLock`.
- Sync `Models.Model_to_str` when field structs gain keyword args.
- Ship regression tests and user-facing docs with public behavior changes when practical.
- Docs/examples: Formula 1 dataset and realistic scenarios — not generic `User`/`Post` placeholders.
- Never log connection strings or secrets; use structured logging (`@error "Msg" exception=e key=value`).

```julia
# ✓ preferred (inline or trailing dot style)
rows = M.Result.objects.
    filter("driverid__surname" => "Senna").
    values("points").
    list()

# ✗ avoid (leading dots result in Julia ParseError)
rows = M.Result.objects
    .filter("driverid__surname" => "Senna")
    .values("points")
    .list()
```

## Skills (read before subsystem work)

| When | Read |
|------|------|
| Public API, models, fields, integration tests, docs | `.github/skills/pormg-public-api-development/SKILL.md` |
| `src/querybuilder/`, `src/Dialect.jl`, SQL/parameters | `.github/skills/pormg-querybuilder-internals/SKILL.md` |
| `src/migrations/`, `src/Migrations.jl`, migration CI | `.github/skills/pormg-migrations-development/SKILL.md` |
| Consumer usage, setup, query examples (no internals) | `.github/skills/pormg-usage/SKILL.md` |
| Pre-push / pre-PR review | `.github/skills/pormg-changed-code-review/SKILL.md` |

Cross-cutting changes: public-API skill + the most specific subsystem skill. Reviews: review skill only.

## Architecture

- `src/PormG.jl` — package root (config, models, QueryBuilder, dialects, migrations)
- `src/Configuration.jl`, `src/constants.jl` — config, `DB_PATH`, `PORMG_ENV`, transactions
- `src/ConnectionPool.jl` — `fetch`, pool lock, transaction context
- `src/Dialect.jl` — backend SQL rendering
- `src/QueryBuilder.jl`, `src/querybuilder/` — query builder (incl. `many_to_many.jl`)
- `src/Migrations.jl`, `src/migrations/` — state-based schema reconciliation

## Verification

- Narrowest relevant test slice first; broaden only after green.
- PostgreSQL integration: `db_2`. SQLite: `PORMG_DB="db_sl"`.
- Docs changes: `julia --project=. docs/make.jl`
