# PormG — agent instructions

**PormG** is an async-first Julia ORM (Genie-compatible). Full standards live in [`.github/instructions/general.instructions.md`](.github/instructions/general.instructions.md). Read subsystem skills before changing those areas.

## Non-negotiables

- **Pre-publish (not yet on Julia General; single maintainer, ~4 internal apps, no external users):** breaking changes are cheap — get the API/schema/naming *right* over backward compatibility; deprecation shims (e.g. the `bulk_update` legacy-`filters` error) are internal migration aids to remove before publish; release-gating decisions are tagged `⚠️ do BEFORE the first General-registry publish` in [`TODO.md`](TODO.md). *(Remove this bullet once published.)*
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
| Public API, models, fields, integration tests, docs | [`.github/skills/pormg-public-api-development/SKILL.md`](.github/skills/pormg-public-api-development/SKILL.md) |
| `src/querybuilder/`, `src/Dialect.jl`, SQL/parameters | [`.github/skills/pormg-querybuilder-internals/SKILL.md`](.github/skills/pormg-querybuilder-internals/SKILL.md) |
| `src/migrations/`, `src/Migrations.jl`, migration CI | [`.github/skills/pormg-migrations-development/SKILL.md`](.github/skills/pormg-migrations-development/SKILL.md) |
| Consumer usage, setup, query examples (no internals) | [`.github/skills/pormg-usage/SKILL.md`](.github/skills/pormg-usage/SKILL.md) |
| Pre-push / pre-PR review | [`.github/skills/pormg-changed-code-review/SKILL.md`](.github/skills/pormg-changed-code-review/SKILL.md) |

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

- **Canonical source:** `.github/instructions/` (general rules) and `.github/skills/` (subsystem skills) — readable by any agent.
- **GitHub Copilot:** picks up `.github/instructions/general.instructions.md` automatically via `applyTo: '**'`.
- **Exclude from indexing:** `db/`, `*connection.yml`, `.env*`, `test/integration/f1/*.csv`, `docs/build/`, `test/integration/db_sl/migrations/`, `test/integration/db_2/migrations/`, `test/integration/db_test_migration*/`, `.github/thinking/`.
