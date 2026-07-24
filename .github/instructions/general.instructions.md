---
applyTo: '**'
---

# PormG Development

Expert Julia ORM work on **PormG** (async-first, Genie-compatible). Be direct, correct, and production-minded.

> **Single source of truth.** This file is the canonical agent ruleset. `AGENTS.md` (and `CLAUDE.md` → `AGENTS.md`) import this file rather than restate it. Edit rules **here** — never keep a second copy.

## Non-negotiables

- **Pre-publish (not yet on Julia General; single maintainer, ~4 internal apps, no external users):** breaking changes are cheap — get the API/schema/naming *right* over backward compatibility; deprecation shims (e.g. the `bulk_update` legacy-`filters` error) are internal migration aids to remove before publish; release-gating decisions carry the [`pre-publish` label](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Apre-publish); the publish gate is that query coming back empty. *(Remove this bullet once published.)*
- **Versioning (`0.y.z`) — release trains, not per-PR bumps.** Pre-publish, consuming apps `dev`/path-dep PormG (they track the git commit, not the registry), so the version number is a **migration-checkpoint label** — one bump per *rollout*, never per PR. A breaking/behavior PR is **done** when it ships code + tests + docs **and** prepends its entry (concrete `before → after` + per-app rollout table) to the **`## Unreleased`** section of [`UPGRADING.md`](../../UPGRADING.md) with `- **Version**: Unreleased` — **it does not bump `Project.toml`.** The maintainer **cuts a train** — via the `/pormg-cut-release` skill, when about to roll the changes into a consuming app: bump the `y` slot **once** in `Project.toml`, stamp every `Unreleased` entry with that version, date + `git tag` it, and open a fresh `## Unreleased`. `z` is reserved for a purely-additive train or a hotfix to a tagged one. `UPGRADING.md` is the single source of truth for consuming-app agents (its header carries the apply recipe, and `PormG.upgrade_guide(from=…)` renders it — its default scope includes `## Unreleased`); do not mirror it into a second changelog file. Entries are version-stamped from `0.2.0` onward; older entries are pre-`0.2` history.
- **Commit/push gate — review first:** never run `git commit`, `git push`, or open/update a PR without the user's **explicit approval at that step**. Plan approval (including `ExitPlanMode`) authorizes *implementing* the change, **not** committing it — finish the work, show the diff/summary, and wait for an explicit go-ahead to commit; treat pushing and opening PRs as a *separate* confirmation again. Backlog operations (issue create/edit/close — outward-facing) and docs edits follow the same rule.
- Use the ORM surface (`M.Model.objects`, fluent terminals). No raw SQL in docs, examples, or integration tests unless the feature requires it.
- **Julia chains:** multi-line method chains **must** use **trailing-dot** syntax (placing `.` at the end of the previous line to continue) or stay inline — leading-dot lines are a Julia `ParseError`.
- **No runtime side effects in module bodies.** Cached precompilation runs a module body **only in the precompile worker** — loading from cache does not re-run it. So top-level `atexit`, `ENV` mutation, hook/callback registration, and service wiring never run at runtime; put them in a `__init__()` function (the established home for load-time runtime wiring). Regressed silently once already — see #203, which fixed the dead `atexit` pool cleanup.
- Parameterized queries only; never interpolate user input into SQL strings.
- Keep PostgreSQL and SQLite aligned; document intentional divergence in code, tests, and docs.
- Async-first: sync `fetch()` wraps `fetch_async()`; pool sync uses `ReentrantLock`.
- Sync `Models.Model_to_str` when field structs gain keyword args.
- Ship regression tests and user-facing docs with public behavior changes when practical.
- Docs/examples: Formula 1 dataset and realistic scenarios — not generic `User`/`Post` placeholders.
- Never log connection strings or secrets; use structured logging (`@error "Msg" exception=e key=value`).

```julia
# ✓ preferred (inline or trailing-dot style)
rows = M.Result.objects.
    filter("driverid__surname" => "Senna").
    values("points").
    list()

# ✗ avoid (leading dots result in a Julia ParseError)
rows = M.Result.objects
    .filter("driverid__surname" => "Senna")
    .values("points")
    .list()
```

## Skills (read before subsystem work)

| When | Read |
|------|------|
| Editing PormG itself — public API, models, fields, integration tests, in-repo docs | `.github/skills/pormg-public-api-development/SKILL.md` |
| `src/QueryBuilder.jl`, `src/querybuilder/`, `src/Dialect.jl`, SQL/parameters | `.github/skills/pormg-querybuilder-internals/SKILL.md` |
| `src/migrations/`, `src/Migrations.jl`, migration CI | `.github/skills/pormg-migrations-development/SKILL.md` |
| Consuming PormG in a downstream app — setup, queries, examples (no internals) | `.github/skills/pormg-usage/SKILL.md` |
| Pre-push / pre-PR review | `.github/skills/pormg-changed-code-review/SKILL.md` |
| Managing the backlog — creating/updating/closing GitHub issues and curating labels | `.github/skills/pormg-issue-management/SKILL.md` |
| Tests failing, flaky, or environment-dependent (pool exhaustion, PG/SQLite divergence, fixture isolation) | `.github/skills/pormg-test-troubleshooting/SKILL.md` |
| Cutting a release train — bump the version, stamp `## Unreleased`, tag (maintainer-invoked) | `.github/skills/pormg-cut-release/SKILL.md` |

Cross-cutting changes: public-API skill + the most specific subsystem skill. Reviews: review skill only — **except doc-content reviews** ("review the doc/examples in …"), which read the review skill **and** the public-API skill, so the live-database example-verification recipe applies.

## Architecture

The subsystem map below is also the review **architecture checkpoint**: when a new subsystem file appears in `src/` that is not listed here, flag it and add it.

| Path | Role |
|------|------|
| `src/PormG.jl` | Package root (config, models, QueryBuilder, dialects, migrations) |
| `src/Configuration.jl`, `src/constants.jl` | Config, `DB_PATH`, `PORMG_ENV`, transactions |
| `src/ConnectionPool.jl` | `fetch`, pool lock, transaction context (driver-agnostic; untyped connection storage) |
| `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl` | Backend interface: `backend_*` generics + friendly fallbacks; driver bodies live in the weakdep extensions (`LibPQ`/`SQLite`). Core never names a concrete driver type |
| `src/Models.jl`, `src/models/` | Models and fields |
| `src/QueryBuilder.jl`, `src/querybuilder/` | Query builder (incl. `many_to_many.jl`) |
| `src/Dialect.jl` | Backend SQL rendering |
| `src/Migrations.jl`, `src/migrations/` | State-based schema reconciliation |
| `test/integration/` | DB integration tests (`db_2` = PostgreSQL, `db_sl` = SQLite via `PORMG_DB`) |
| `docs/src/` | User documentation |

## Verification

- Run the narrowest relevant test slice first; broaden only after green.
- PostgreSQL integration: `db_2`. SQLite: `PORMG_DB="db_sl"`.
- Docs: `julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include("docs/make.jl")'` (the main project env has no Documenter — `--project=.` fails)

## Tool notes

- **Canonical source:** this file (`.github/instructions/general.instructions.md`) holds the general rules; `.github/skills/` holds subsystem skills. Both are readable by any agent.
- **GitHub Copilot:** picks up this file automatically via `applyTo: '**'`.
- **Claude Code / AGENTS.md:** `CLAUDE.md` imports `AGENTS.md`, which imports this file — so the rules reach every tool from one copy.
- **Exclude from indexing:** `db/`, `*connection.yml`, `.env*`, `test/integration/f1/*.csv`, `docs/build/`, `test/integration/db_sl/migrations/`, `test/integration/db_2/migrations/`, `test/integration/db_test_migration*/`, `.github/thinking/`.
