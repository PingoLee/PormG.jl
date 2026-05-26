# PormG — agent instructions

**PormG** is an async-first Julia ORM (Genie-compatible). Full standards live in [`.cursor/rules/pormg-general.mdc`](.cursor/rules/pormg-general.mdc). Read subsystem skills before changing those areas.

## Non-negotiables

- Use the ORM surface (`M.Model.objects`, fluent terminals). No raw SQL in docs, examples, or integration tests unless the feature requires it.
- **Julia chains:** multi-line method chains must use **trailing-dot** syntax (`.` at end of line) or stay inline — leading-dot lines are a `ParseError`.
- Parameterized queries only; never interpolate user input into SQL strings.
- Keep PostgreSQL and SQLite aligned; document intentional divergence in code, tests, and docs.
- Async-first: sync `fetch()` wraps `fetch_async()`; pool sync uses `ReentrantLock`.
- Sync `Models.Model_to_str` when field structs gain keyword args.
- Ship regression tests and user-facing docs with public behavior changes when practical.
- Docs/examples: Formula 1 dataset and realistic scenarios — not generic `User`/`Post` placeholders.
- Never log connection strings or secrets; use structured logging (`@error "Msg" exception=e key=value`).

```julia
# ✓ trailing dot or inline
rows = M.Result.objects.
    filter("driverid__surname" => "Senna").
    list()

# ✗ leading dot (ParseError)
rows = M.Result.objects
    .filter("driverid__surname" => "Senna")
    .list()
```

## Skills (read before subsystem work)

| When | Read |
|------|------|
| Public API, models, fields, integration tests, docs | [`.cursor/skills/pormg-public-api-development/SKILL.md`](.cursor/skills/pormg-public-api-development/SKILL.md) |
| `src/querybuilder/`, `src/Dialect.jl`, SQL/parameters | [`.cursor/skills/pormg-querybuilder-internals/SKILL.md`](.cursor/skills/pormg-querybuilder-internals/SKILL.md) |
| `src/migrations/`, `src/Migrations.jl`, migration CI | [`.cursor/skills/pormg-migrations-development/SKILL.md`](.cursor/skills/pormg-migrations-development/SKILL.md) |
| Consumer usage, setup, query examples (no internals) | [`.cursor/skills/pormg-usage/SKILL.md`](.cursor/skills/pormg-usage/SKILL.md) |
| Pre-push / pre-PR review | [`.cursor/skills/pormg-changed-code-review/SKILL.md`](.cursor/skills/pormg-changed-code-review/SKILL.md) |

Cross-cutting changes: public-API skill + the most specific subsystem skill. Reviews: review skill only.

## Layout

| Path | Role |
|------|------|
| `src/PormG.jl` | Package root |
| `src/QueryBuilder.jl`, `src/querybuilder/` | Query builder |
| `src/Models.jl`, `src/models/` | Models and fields |
| `src/Dialect.jl` | Backend SQL rendering |
| `src/Migrations.jl`, `src/migrations/` | State-based migrations |
| `test/integration/` | DB integration tests (`db_2` = PostgreSQL, `db_sl` = SQLite via `PORMG_DB`) |
| `docs/src/` | User documentation |

## Verification

- Run the narrowest relevant test slice first; broaden only after green.
- PostgreSQL integration: `db_2`. SQLite: `PORMG_DB=db_sl`.
- Docs: `julia --project=. docs/make.jl`

## Tool notes

- **Cursor:** `.cursor/rules/`, `.cursor/skills/` (canonical). `.github/skills/` mirrors skills for GitHub/Copilot.
- **Indexing:** large F1 CSVs, generated artifacts, and secrets are listed in [`.cursorignore`](.cursorignore).
