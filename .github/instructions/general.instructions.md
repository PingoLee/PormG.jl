---
applyTo: '**'
---

# PormG Development

Expert Julia ORM work on **PormG** (async-first, Genie-compatible).

> **Single source of truth.** This file is the canonical agent ruleset. `AGENTS.md` (and `CLAUDE.md` → `AGENTS.md`) import this file rather than restate it. Edit rules **here** — never keep a second copy.

## Non-negotiables

- **Pre-publish — prefer the right API over compatibility, but *measure* "cheap" first.** Not on Julia General; single maintainer, ~4 internal apps, no external users. Before trading correctness away for compatibility, clone/grep the consuming apps for the call pattern and **report the number** — zero real call sites costs nothing to redesign, and choosing a guard without that number is how an avoidable wart becomes permanent (#444: the CTE API had **0** `.with(` call sites, which is what made the redesign the cheap option).
  - Deprecation shims (e.g. the `bulk_update` legacy-`filters` error) are internal migration aids — remove before publish.
  - Release gating: the [`pre-publish` label](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Apre-publish); the gate is that query coming back empty. *(Remove this bullet once published.)*
- **Versioning (`0.y.z`) — release trains, not per-PR bumps.** A breaking/behavior PR is **done** when it ships code + tests + docs **and** prepends an entry to `## Unreleased` in [`UPGRADING.md`](../../UPGRADING.md) marked `- **Version**: Unreleased`. **It does not bump `Project.toml`.**
  - Entry form: concrete `before → after`, and **no** per-app rollout table — the app's pin is its state.
  - The maintainer cuts a train via `/pormg-cut-release`: bump `y` **once**, stamp every `Unreleased` entry, date + `git tag`, open a fresh `## Unreleased`. `z` = a purely-additive train, or a hotfix to a tagged one.
  - One changelog only: `UPGRADING.md` holds entries plus the rules for writing them — **never mirror it into a second file**. The user-facing explanation of the model lives in [`docs/src/upgrading.md`](../../docs/src/upgrading.md); extend that page instead of restating it. Entries are version-stamped from `0.2.0`; older ones are pre-`0.2` history.
- **Commit/push gate — three separate approvals: commit, then push, then open/update the PR.** Never run `git commit`/`git push` or touch a PR without the user's explicit go-ahead **at that step**. Plan approval (including `ExitPlanMode`) authorizes *implementing* only — finish the work, show the diff, then ask. Backlog operations (issue create/edit/close) and docs edits follow the same rule.
- Use the ORM surface (`M.Model.objects`, fluent terminals). No raw SQL in docs, examples, or integration tests unless the feature requires it.
- **Julia chains:** multi-line method chains **must** use **trailing-dot** syntax (placing `.` at the end of the previous line to continue) or stay inline — leading-dot lines are a Julia `ParseError`.
- **No runtime side effects in module bodies — put them in `__init__()`.** A cached module body runs **only in the precompile worker**; loading from cache never re-runs it, so top-level `atexit`, `ENV` mutation, hook/callback registration and service wiring silently never happen at runtime. Regressed once already (#203, the dead `atexit` pool cleanup).
- **Never put a comment in `Project.toml`** — CompatHelper's TOML round-trip silently drops **every** comment line and no flag disables it, so rationale parked there survives only until the next dependency bump (#244–#246 ate the Julia-floor note this way). Put reasoning here or in `README.md`, and never "fix" a stripped comment by restoring it.
  - The standing case it kept eating: **the `julia = "1.12"` floor is intentional — do not lower it to the 1.10 LTS.** `@import_models`/`set_models` world-age handling depends on 1.12 semantics (#211); `README.md` → *Requirements* states it user-facing.
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

## Design stance

**This fires at design time** — choosing an API shape, a schema, a name — which in practice means
*in the plan, before code exists*: a magic-shaped surface costs minutes to change then and a
breaking release afterwards. It is a review trigger too, for anything that got past planning.

**Django-shaped by default** — model/field vocabulary, the `objects` manager, `__` traversal,
migrations. Reach for Django's answer first; someone arriving from Django should be able to guess.
Two deliberate departures from that default:

- **Good ideas from any framework are welcome — and PormG already takes them.** The async contract
  follows Ecto's `Task.async` (`docs/src/async.md`); state-based migrations follow Prisma / Atlas /
  Flyway declarative diffing rather than Django's ordered chain (`docs/src/migrations/index.md`);
  explicit subqueries sit in the jOOQ / SQLAlchemy camp. Check the prior art before inventing —
  recipe in [`pormg-public-api-development`](../skills/pormg-public-api-development/SKILL.md) →
  *Before designing a guard, check the prior art*.
- **Prefer less magic than Django, not more.** Where Django resolves something implicitly — a shared
  namespace, action at a distance, a hidden state machine — prefer the explicit object, the named
  parameter, the visible call. Settled practice, not aspiration:
  - **#74** — Django's `annotate(Count(…))` silently row-multiplies when two annotations combine.
    PormG ships **only** the explicit `Subquery`/`OuterRef` path and makes the silent-fan-out form a
    hard error; correlation is always spelled out, never inferred.
  - **#444** — CTE names moved out of the field-path namespace into a CTE object with its own
    namespace, which is why #431/#434 became *unrepresentable* rather than guarded.
  - **Migrations** — no dependency graph, no file replay; `applied_migrations/` is an inert audit trail.

  The worked statement is `docs/src/read/subqueries_and_ctes.md` → *Positioning: explicit, not magic*.

When the two pull against each other — Django familiarity vs less magic — say so in the issue or PR
and let the maintainer choose. Do not settle it silently in either direction.

## Skills (read before subsystem work)

| When | Read |
|------|------|
| Working a GitHub issue end-to-end — scope, worktree, verify, independent review, land, clean up | `.github/skills/pormg-issue-workflow/SKILL.md` |
| Editing PormG itself — public API, models, fields, integration tests, in-repo docs | `.github/skills/pormg-public-api-development/SKILL.md` |
| `src/QueryBuilder.jl`, `src/querybuilder/`, `src/Dialect.jl`, SQL/parameters | `.github/skills/pormg-querybuilder-internals/SKILL.md` |
| `src/migrations/`, `src/Migrations.jl`, migration CI | `.github/skills/pormg-migrations-development/SKILL.md` |
| Consuming PormG in a downstream app — setup, queries, examples (no internals) | `.github/skills/pormg-usage/SKILL.md` |
| Pre-push / pre-PR review | `.github/skills/pormg-changed-code-review/SKILL.md` |
| Managing the backlog — creating/updating/closing GitHub issues and curating labels | `.github/skills/pormg-issue-management/SKILL.md` |
| Deciding **what to work on next** — batching open issues into single-sitting sessions, ranking them, recording it on the project board | `.github/skills/pormg-session-planning/SKILL.md` |
| Tests failing, flaky, or environment-dependent (pool exhaustion, PG/SQLite divergence, fixture isolation) | `.github/skills/pormg-test-troubleshooting/SKILL.md` |
| Cutting a release train — bump the version, stamp `## Unreleased`, tag (maintainer-invoked) | `.github/skills/pormg-cut-release/SKILL.md` |
| **Writing any test** (all subsystems) — `@testset` headers, comment density, fixture isolation | `.github/instructions/test-writing.md` — an instruction file, not a skill; the subsystem skills link to it rather than restate it |

Cross-cutting changes: public-API skill + the most specific subsystem skill. Reviews: review skill only — **except doc-content reviews** ("review the doc/examples in …"), which read the review skill **and** the public-API skill, so the live-database example-verification recipe applies.

## Architecture

The subsystem map below is also the review **architecture checkpoint**: when a new subsystem file appears in `src/` **or `ext/`** that is not listed here, flag it and add it. `ext/` is in scope deliberately — the checkpoint was `src/`-only until `ext/PormGReviseExt.jl` sat unlisted while two skills referenced it.

**Layering (enforced by include order in `src/PormG.jl`).** `Kernel` is layer 1 and imports nothing from `PormG`; `Backend.jl` is layer 2 (behavior `PormG` must own — see below); the submodules are layer 3; `tools.jl` is layer 4. Shared vocabulary — an abstract type, a constant, an exception type — belongs in `Kernel`, **not** part-way down the chain, or the submodules included before it cannot name it. That is not hypothetical: the #231 error taxonomy was defined at include step 11, which is why `Models`/`Configuration`/`Dialect` could not use a single one of its types (#239).

`Backend.jl` stays in `PormG` on purpose. The weakdep extensions define `PormG.backend_execute(…) = …`, and Julia only accepts a qualified method definition on the module that *owns* the binding — moving those generics into `Kernel` breaks every extension method, and it fails at `using LibPQ` / `using SQLite`, not at `using PormG`, so precompiling the package does not catch it. **Kernel holds the nouns; `PormG` keeps the verbs.**

| Path | Role |
|------|------|
| `src/PormG.jl` | Package root — include chain and the public `export` surface |
| `src/Kernel.jl`, `src/constants.jl` | Layer 1: shared vocabulary — abstract types, constants, `PormGError` root, `_emsg`, `config`. Imports nothing from `PormG` |
| `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl` | Layer 2: backend interface: `backend_*` generics + friendly fallbacks; driver bodies live in the weakdep extensions (`LibPQ`/`SQLite`). Core never names a concrete driver type |
| `src/Generator.jl` | Model file generation (`generate_models_from_db`): module envelope, `import` lines, and sentinel imports for every generated model file |
| `src/Configuration.jl` | Config, `DB_PATH`, `PORMG_ENV`, transactions |
| `src/ConnectionPool.jl` | `fetch`, pool lock, transaction context (driver-agnostic; untyped connection storage) |
| `src/Models.jl`, `src/models/` | Models and fields |
| `src/Utils.jl`, `ext/PormGReviseExt.jl` | Model loader macros (`@import_models`, `@models_module`) and the world-age loading machinery the 1.12 floor exists for (#211); the Revise weakdep extension wires hot reload back into `Utils.reload_module_contents!` / `Models.set_models` |
| `src/Dialect.jl` | Backend SQL rendering |
| `src/AdvisoryLock.jl` | `with_advisory_lock` — cross-process advisory locking (migrations serialize on it) |
| `src/QueryBuilder.jl`, `src/querybuilder/` | Query builder (incl. `many_to_many.jl`) |
| `src/Migrations.jl`, `src/migrations/` | State-based schema reconciliation |
| `src/tools.jl` | Layer 4: user-facing lifecycle helpers (`setup`, `install_ai_skills`, `upgrade_guide`) |
| `test/integration/` | DB integration tests (`db_2` = PostgreSQL, `db_sl` = SQLite via `PORMG_DB`) |
| `docs/src/` | User documentation |

## Verification

- Run the narrowest relevant test slice first; broaden only after green.
- **Threads:** `db_2` (PostgreSQL) under `-t auto`; `db_sl` (SQLite) **always `-t 1`** — SQLite does not tolerate `-t auto` (`common_setup.jl`, above the connection setup). Julia's one-thread default hides an omitted `-t 1` until `JULIA_NUM_THREADS` is set, so write it explicitly every time.
- **Write `--project=test/integration` in every integration command.** It carries `LibPQ` + `SQLite`, which the package env cannot (`[weakdeps]` by design, and `Manifest.toml` is gitignored so a checkout has no installed copy). `--project=.` also works — `common_setup.jl` redirects the package env and "no project" — but that is a rescue for a wrong invocation, not the spelling to teach, and a scratch script without `common_setup.jl` gets no redirect and fails outright. Fresh clone: `julia --project=test/integration -e 'using Pkg; Pkg.instantiate()'` once. An explicit `--project=<other>` is left alone.
- **A single integration file is a valid target — the full suite is a release gate, not a per-issue tax.** Most `test/integration/test_*.jl` open with `if !isdefined(Main, :PormG) include("common_setup.jl") end`, so naming one file runs it against the already-seeded database and skips the ~170-statement DDL bootstrap and fixture reseed `runtests.jl` repeats every time. Which files are exempt, and which diffs still owe a full run: [`pormg-issue-workflow`](../skills/pormg-issue-workflow/SKILL.md) → *Verify*. The full-suite-on-both-engines gate is precondition 4 of [`pormg-cut-release`](../skills/pormg-cut-release/SKILL.md).
- **Concurrent integration runs queue — there is nothing to coordinate by hand.** `common_setup.jl` takes a PostgreSQL session-level advisory lock on the selected database, so a second session running against `db_2` waits (logging who holds it every 30s) instead of interleaving its schema and fixture phases into the first run. It sits in `common_setup.jl`, not `runtests.jl`, because all 40 integration entry points include it and a single `test_*.jl` is the normal target. The lock dies with the connection, so exit / Ctrl-C / crash all release it — no stale state to reap. `PORMG_TEST_LOCK_WAIT=<secs>` bounds the queue (default 900); `PORMG_TEST_LOCK=0` opts out; `release_suite_lock!()` frees it early in an interactive session. SQLite is exempt — `f1.sqlite` is already per-worktree. It is advisory, so a manual `psql` or a downstream app still writes underneath you.
- **Local green ≠ CI green.** `Manifest.toml` is gitignored, so you reuse versions resolved once while CI resolves fresh onto the newest `[compat]` allows — how OrderedCollections 2 broke CI for a day with every local suite passing (#263). Check the CI run before calling a change green, or resolve into a scratch env to see what CI will.
- Docs: `julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include("docs/make.jl")'` (the package env has no Documenter — `--project=.` fails)

## Tool notes

- **Canonical source:** this file (`.github/instructions/general.instructions.md`) holds the general rules and `.github/instructions/test-writing.md` the test standard; `.github/skills/` holds subsystem skills. All are readable by any agent.
- **GitHub Copilot:** picks up this file automatically via `applyTo: '**'`.
- **Claude Code / AGENTS.md:** `CLAUDE.md` imports `AGENTS.md`, which imports this file — so the rules reach every tool from one copy.
- **Exclude from indexing:** `db/`, `*connection.yml`, `.env*`, `test/integration/f1/*.csv`, `docs/build/`, `test/integration/db_sl/migrations/`, `test/integration/db_2/migrations/`, `test/integration/db_test_migration*/`, `.github/thinking/`.
