---
name: pormg-changed-code-review
description: Review changed PormG code before push or PR by reading git diff in ordered slices for src, test, and remaining folders, then report bugs, security issues, regressions, and missing coverage.
---

# PormG Changed Code Review

## Purpose

Use this skill when the user wants a review of local changes before pushing, opening a pull request, or sending code to GitHub.

This is a review workflow, not an implementation workflow. The default job is to inspect the diff efficiently and report concrete risks.

## Use This Skill For

- Reviewing uncommitted or staged local changes before push
- Reviewing a feature branch before opening a pull request
- Inspecting changed files while keeping context small and ordered
- Looking specifically for bugs, regressions, security issues, and missing tests

## Primary Output

- Findings first, ordered by severity
- Each finding should name the concrete risk, why it matters, and where it appears
- Use file references when available
- Keep summaries brief and secondary
- If no findings are discovered, state that explicitly and call out residual testing gaps or uncertainty

## Diff Collection Workflow

### Default review target

This project uses a single-developer workflow: unstaged changes are reviewed first, then staged, committed, and pushed directly to `main`. Review targets in priority order:

1. **Unstaged (default):** working tree changes not yet staged — use `git diff`
2. **Staged:** when the user explicitly says they have already staged — use `git diff --staged`
3. **All local (staged + unstaged):** when the user wants a full picture — use `git diff HEAD`
4. **Already pushed:** when the user wants to review what was just pushed — use `git diff origin/main~1 origin/main`

If the working tree is clean and nothing is staged, state that and stop.

### Ordered diff slices

Review in this exact order to save context:

1. `src`
2. `test`
3. every other changed folder

Do not start with a whole-repo patch if the change can be reviewed in slices.

### Recommended commands

Use `git diff --name-only` first to learn the surface area.

Then inspect patches in ordered slices. The `:(exclude)` pathspec syntax works on Linux/bash and Git Bash; on Windows PowerShell use separate per-folder calls instead of exclusion patterns.

**Linux / bash / Git Bash:**
```bash
# unstaged review (default)
git diff -- src
git diff -- test
git diff -- . ':(exclude)src' ':(exclude)test'
```

**Windows PowerShell:**
```powershell
# unstaged review (default)
git diff -- src
git diff -- test
git diff -- docs ext .cursor db
```

For staged review, add `--staged` (e.g. `git diff --staged -- src`). For all local changes, use `git diff HEAD -- src`.

If one slice is empty, skip it and continue to the next slice.

## Review Priorities

### Bugs and regressions

Prioritize:

- incorrect control flow or missing edge-case handling
- contract drift between source code, tests, and docs
- PostgreSQL versus SQLite behavior divergence
- missing updates to migrations or model serialization when public field behavior changes
- transaction, concurrency, or async-safety regressions
- broken assumptions in deletion, query generation, or data coercion

### Security issues

Check aggressively for:

- SQL interpolation instead of parameterized queries
- logging of secrets, raw connection strings, tokens, or credentials
- unsafe shell execution or command construction from dynamic input
- unsafe file path handling, path traversal, or implicit trust of filesystem input
- unvalidated deserialization or unsafe parsing of external content
- CI or workflow changes that accidentally broaden secret exposure or permissions

### Tests

In the `test` pass, verify:

- changed behavior has regression coverage
- tests validate public behavior first when the change is user-visible
- assertions still match the real contract instead of just the current implementation detail
- new tests do not weaken field contracts to accommodate dirty fixtures when normalization belongs in import/setup code

### Other folders

In the final pass, review `docs`, `ext`, `.github`, `.cursor`, `db`, and any remaining changed paths for:

- docs that promise unsupported behavior
- workflow or CI changes that hide failures or leak secrets
- generated files that drift from source-of-truth files
- configuration changes that alter runtime or migration behavior without matching tests
- **changed query examples in `docs/`, `README.MD`, or `src/*.md`** that were not verified against the live `db_sl` data — confirm the SQL shape, execute the example, and cross-check the value per the verification recipe in [`../pormg-public-api-development/SKILL.md`](../pormg-public-api-development/SKILL.md) ("Verifying doc examples against the live database"). Flag camelCase join paths (`driverId__surname`) — query paths must be lowercase or they throw at build time.

## Review Method

1. Read `.github/instructions/general.instructions.md` to get the current architecture checkpoints and subsystem map before starting — this ensures heuristics cover newly added subsystems automatically.
2. Identify the changed file set with `git diff --name-only`.
3. Read the `src` diff first and understand the behavior change.
4. Read the `test` diff to confirm the changed behavior is covered correctly.
5. Read the remaining diffs for configuration, docs, CI, or packaging risks.
6. Report findings before any summary.

## PormG-Specific Heuristics

Always re-read `.github/instructions/general.instructions.md` (step 1 of Review Method) so that new subsystems added to the architecture checkpoints are automatically included in the review. The bullets below are permanent baselines, not an exhaustive list.

- Prefer findings that catch raw SQL drift away from the ORM surface
- Flag any change that makes PostgreSQL and SQLite differ without an explicit justification
- Flag any public field-struct change that does not update `Models.Model_to_str`
- Flag migration changes that weaken destructive safeguards or skip `dry_run()` discipline
- Flag docs or examples that regress to generic domains instead of Formula 1 scenarios
- When a new subsystem file appears in `src/` that is not yet listed in `general.instructions.md`, flag it as an architecture-checkpoint gap
- Flag any reintroduction of silent identifier stripping (e.g. `replace(id, r"[^a-zA-Z0-9_]" => "")` before quoting) — the correct contract is fail-closed: `_validate_identifier` throws on invalid input and never silently rewrites identifiers
- Flag raw ANSI escape codes (`\e[`) embedded in `throw(...)` / `error(...)` messages — these must route through `_argerr` / `_emsg` (`src/querybuilder/exceptions.jl`) so color degrades off-TTY; `@info`/`@warn`/`@error` logging may keep ANSI

## After Reporting Findings

This project is single-developer: unstaged changes are reviewed first, then staged, committed, and pushed directly to `main`. After reporting:

- If findings are blocking (bugs, security issues, missing tests for changed behavior): offer to fix them inline in the same conversation.
- If findings are advisory only (style, doc gaps, architecture notes): state the residual risk clearly and let the developer decide.
- Do **not** generate a review markdown file in the project root unless the user explicitly asks for one — it adds repo noise for a solo workflow. Keep findings in the chat.

## Anti-Patterns

- Do not lead with a summary when concrete findings exist
- Do not review only tests while skipping the paired `src` change
- Do not rely on a single giant diff when ordered slices are available
- Do not treat generated docs or build artifacts as the primary source of truth
- Do not approve sensitive logging, SQL interpolation, or weakened destructive guards as minor issues
