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

- Findings first, ordered by severity — never lead with a summary
- Each finding should name the concrete risk, why it matters, and where it appears
- Keep summaries brief and secondary
- With no findings, say so **and** call out residual testing gaps or uncertainty — a clean report is a claim, not an absence of one

## Diff Collection Workflow

### Pick the target from where the work lives

Single maintainer, but **two** landing modes, and they need different diffs:

- **Issue work** — a `fix/<N>-<slug>` branch in a worktree → PR → merge into `main`
  ([`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md)). This is most code review.
- **Instruction, skill and doc commits** — often straight onto `main`, no branch.

So **check where you are before choosing a command** — `git branch --show-current` and
`git status --porcelain`. A branch with commits on it needs a *branch* diff; `git diff` alone shows
only the working tree and will report "no changes" on a fully-committed branch, which reads as
"nothing to review" when the entire PR is sitting there unreviewed.

| Situation | Target |
|---|---|
| Uncommitted work, either mode **(default)** | `git diff` |
| Staged, user says so | `git diff --staged` |
| Staged + unstaged together | `git diff HEAD` |
| **On a `fix/…` branch, work committed — the pre-PR review** | `git diff main...HEAD` |
| **An open PR** | `gh pr diff <N>` |
| Just pushed to `main` directly | `git diff origin/main~1 origin/main` |

**Three dots, not two.** `main...HEAD` diffs from the **merge base** — what the branch actually
adds. `main..HEAD` diffs tip-to-tip, so every commit that landed on `main` after you branched shows
up *reversed*, as though your branch deleted it. Measured on this repo: against a branch tip that
`main` has since moved past, `main...<tip>` reports **0** files and `main..<tip>` reports **39** —
39 files of someone else's merged work, presented as your diff. The two forms agree only while
`main` has not moved, which is exactly when you would not notice picking the wrong one.

**A branch review covers committed work *and* whatever is still uncommitted.** If
`git status --porcelain` is dirty on a `fix/…` branch, review `git diff main...HEAD` **and**
`git diff` — the PR gets both once you commit, so reviewing only one half is a gap.

If every target you tried is empty, say so and stop — but say *which* you tried, so "clean tree" is
never mistaken for "branch reviewed".

### Ordered diff slices

Review in this exact order to save context:

1. `src`
2. `test`
3. every other changed folder

Do not start with a whole-repo patch if the change can be reviewed in slices.

### Recommended commands

Use `git diff --name-only` first to learn the surface area, then inspect patches in ordered slices.
One recipe, every shell — `:(exclude)` pathspecs work in bash, Git Bash **and Windows PowerShell**
when single-quoted:

```
# unstaged review (default)
git diff -- src
git diff -- test
git diff -- . ':(exclude)src' ':(exclude)test'
```

**Slice 3 must be an exclusion, never a hand-written folder list.** A list like
`git diff -- docs ext .github db` silently drops every changed file at the repo root — including
`Project.toml` and `UPGRADING.md`, the two this skill has explicit heuristics for (see *Other
folders* below and the `UPGRADING.md` non-negotiable). Reconcile slice 3 against the
`--name-only` output before moving on: every path not under `src` or `test` must have appeared.

**The slicing is independent of the target** — take whichever target the table gave you and append
the same three pathspecs:

```
git diff --staged -- src                              # staged
git diff HEAD -- src                                  # staged + unstaged
git diff main...HEAD -- src                           # branch, pre-PR
git diff main...HEAD -- . ':(exclude)src' ':(exclude)test'
```

`gh pr diff <N>` is the exception: it takes no pathspec. Either fetch the branch and slice it with
`git diff main...<branch>`, or read `gh pr diff <N> --name-only` first and keep the same
src → test → everything-else reading order by hand.

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

A `test` pass is **not** a box-tick on "are there tests?" — it is a critical judgement of whether each
new or changed test actually *constrains behavior*, or is just **green-theater**: present so the suite
goes green without proving the change is correct. For every added/modified test apply the **mutation
test** — *if the source change were reverted (or the bug it guards reintroduced), would this test
fail?* If it would still pass, the test is decorative; report that as a finding, because a behavior
change with only decorative coverage carries the same risk as no coverage.

Verify:

- changed behavior has regression coverage that genuinely exercises the changed code path
- tests validate public behavior first when the change is user-visible
- assertions check the real contract / the actual value — not merely that code ran
- new tests do not weaken field contracts to accommodate dirty fixtures when normalization belongs in import/setup code

Flag these **green-theater smells** explicitly, and propose the assertion that would actually fail if the behavior broke:

- **"It ran" assertions** — `@test (q |> DataFrame) isa DataFrame`, `@test !isnothing(x)`, `@test true`, or asserting a return *type/shape* when the test's intent is a *value*. These pass as long as nothing throws and prove almost nothing. Demand the real value: recompute it independently and assert equality (the live-data recipe in [`../pormg-public-api-development/SKILL.md`](../pormg-public-api-development/SKILL.md), "Verify the value, not just execution").
- **`@test_throws` with no cause check** — `@test_throws ArgumentError f()` passes for *any* `ArgumentError`, including an unrelated one (a typo'd field, a different validator). When the point is a *specific* failure, assert on the message/condition (e.g. `try f(); @test false catch e; @test occursin("fan-out", e.msg) end`) so a different error can't masquerade as a pass.
- **Tautologies** — `@test x == x`, or comparing a value to a constant the code under test just produced.
- **Weak bounds when the exact answer is knowable** — `@test n > 0` / `@test !isempty(rows)` where a precise count or row set could be asserted. Acceptable only when the value is genuinely nondeterministic.
- **No discrimination** — a guard/branch test that exercises only one side (only the raise, or only the allow). It cannot prove the behavior fires *and only* when it should; require both the positive and negative case.
- **Snapshot drift** — an expected SQL string / output edited to match new code without confirming the new output is itself correct (see Anti-Patterns).
- **Dead tests** — over-mocking, the wrong fixture, or a skipped path means the test never reaches the changed code and would pass against the old code too.

### Other folders

In the final pass, review `docs`, `ext`, `.github`, `db`, and any remaining changed paths for:

- docs that promise unsupported behavior
- workflow or CI changes that hide failures or leak secrets
- generated files that drift from source-of-truth files
- configuration changes that alter runtime or migration behavior without matching tests
- **`Project.toml` comment lines** — flag a diff that *removes* a `#` line (CompatHelper ate it) or *adds* one (it will be eaten next bump). The rationale moves to `README.md` / `general.instructions.md`; never restore it in place. Full rule: the `Project.toml` non-negotiable in [`general.instructions.md`](../../instructions/general.instructions.md)
- **A widened `[compat]` bound is a claim, not a fact — and for a weakdep, green CI is not evidence.** An extension only loads when its trigger package does, so confirm the extension is actually exercised at the new major. Check `[targets].test` **and** the subprocess tests that build their own `Project.toml` (`test/unit/test_reload.jl` covers `PormGReviseExt` that way; `[targets].test` alone would not reveal it). If nothing loads it, verify by hand or say in the PR that you didn't
- **changed query examples in `docs/`, `README.md`, or `src/*.md`** that were not verified against the live `db_sl` data — confirm the SQL shape, execute the example, and cross-check the value per the verification recipe in [`../pormg-public-api-development/SKILL.md`](../pormg-public-api-development/SKILL.md) ("Verifying doc examples against the live database"). Flag query paths whose case doesn't match the declared field — lookups are case-sensitive (#57); that skill's *Verifying doc examples* section states the rule and the F1 lowercase convention.

## Review Method

1. Read `.github/instructions/general.instructions.md` to get the current architecture checkpoints and subsystem map before starting — this ensures heuristics cover newly added subsystems automatically.
2. Establish **where the work lives** — `git branch --show-current` + `git status --porcelain` — and pick the target from *Pick the target from where the work lives*. On a `fix/…` branch that is the branch diff, not the working tree.
3. Identify the changed file set with that target's `--name-only` (e.g. `git diff main...HEAD --name-only`), and reconcile slice 3 against it.
4. Read the `src` diff first and understand the behavior change.
5. Read the `test` diff to confirm the changed behavior is covered correctly.
6. Read the remaining diffs for configuration, docs, CI, or packaging risks.
7. Report findings before any summary.

## PormG-Specific Heuristics

The bullets below are permanent baselines, not an exhaustive list — Review Method step 1 keeps them current with newly added subsystems.

- Prefer findings that catch raw SQL drift away from the ORM surface
- Flag any change that makes PostgreSQL and SQLite differ without an explicit justification
- Flag any public field-struct change that does not update `Models.Model_to_str`
- Flag migration changes that weaken destructive safeguards or skip `dry_run()` discipline
- Flag docs or examples that regress to generic domains instead of Formula 1 scenarios
- **Flag a new public surface that resolves something implicitly** — a caller-supplied name landing in a shared namespace, action at a distance, a hidden state machine — against *Design stance* in [`general.instructions.md`](../../instructions/general.instructions.md). #444 is the precedent: the fix was an explicit object with its own namespace, **not** a guard on the implicit form. A guard on a magic shape is the smell; say so rather than reviewing the guard's correctness
- **Flag a new `isa sForeignKey` (or `isa sOneToOneField`) gate that does not cover its twin.** They are sibling structs, not a subtype pair, and four subsystems have each missed the second one — the DDL renderer (#408), the schema readers (#409), the query builder (#418), the migration planner (#437). The spelling is `Models.sRelationalColumn` (`src/models/fields.jl`); a bare gate on one of them is the fifth instance waiting to happen
- **Flag a new comparator escape in the migration planner's field diff** — another `_NON_SCHEMA_FIELD_ATTRS` entry, a `typeof` / `isa` escape, or a reconciliation branch in `_alter_table_fields` / `describes_same_column` / `_compare_model_field`. That is the convergence class #507 exists to close; say so and point at #507 rather than reviewing the escape's correctness. Background: [`../pormg-migrations-development/SKILL.md`](../pormg-migrations-development/SKILL.md) → *Planner internals: column identity*
- **Flag an operator or build step that writes into an expression node it was handed** — `f.column = …`, `x.custom_as = …`, `g.operand = …` on an `FExpression` / `FObject` / `SQLText` / `OperObject` / `CTEReference` argument. Since #493 every operator constructs a new node, and #508 measured what one in-place write costs (a `Value` handle shared by two queries rewrote the first query's alias). Contract in [`../pormg-querybuilder-internals/SKILL.md`](../pormg-querybuilder-internals/SKILL.md) → *Expression nodes: construct, never mutate*
- When a new subsystem file appears in `src/` **or `ext/`** that is not yet listed in `general.instructions.md`, flag it as an architecture-checkpoint gap. `ext/` counts: the checkpoint read `src/`-only while `ext/PormGReviseExt.jl` sat unlisted and two skills referenced it
- Flag any identifier-quoting change that breaks the #394 partition — silent stripping reintroduced (`replace(id, r"[^a-zA-Z0-9_]" => "")` before quoting), a physical table/column routed through `quote_identifier`, or an alias routed through `safe_*_identifier`. Which function owns which kind of name, and why collapsing the split re-opens #394, is in [`../pormg-querybuilder-internals/SKILL.md`](../pormg-querybuilder-internals/SKILL.md) → *Identifier sanitization contract*: read the contract there rather than judging from a paraphrase here
- **Flag raw ANSI (`\e[`) anywhere it can reach a non-TTY sink** — `throw`/`error` messages, `@info`/`@warn`/`@error` logging, `print`/`println`. All of them route through a taxonomy subtype's constructor or `_emsg` (`src/exceptions.jl` / `src/Kernel.jl`). Logging is **not** exempt: Julia clears `Base.have_color` off-TTY, so an unwrapped log leaks escapes into CI output and log files — `src/` already routes ~21 logging sites through `_emsg`. `test_error_message_ansi.jl` does not cover the logging macros, so this review is the only thing that catches a new one
- Flag any new `throw(ArgumentError(...))` in `src/` — since #239 every PormG domain error is a `PormGError` subtype. `ArgumentError` is correct **only** for Julia-level API misuse (a missing kwarg, a missing path), not for a field, model, config, query, or migration problem

## After Reporting Findings

After reporting:

- If findings are blocking (bugs, security issues, missing tests for changed behavior): offer to fix them inline in the same conversation.
- If findings are advisory only (style, doc gaps, architecture notes): state the residual risk clearly and let the developer decide.
- Do **not** generate a review markdown file in the project root unless the user explicitly asks for one — it adds repo noise for a solo workflow. Keep findings in the chat.

## Anti-Patterns

- Do not lead with a summary when concrete findings exist
- **Do not report "clean tree, nothing to review" from `git diff` alone.** On a `fix/…` branch with the work committed, `git diff` is empty and the whole PR is still unreviewed. Check `git branch --show-current` first and use `git diff main...HEAD`
- Do not review only the committed half of a dirty branch, or only the uncommitted half — the PR will carry both
- Do not review only tests while skipping the paired `src` change
- Do not rely on a single giant diff when ordered slices are available
- Do not treat generated docs or build artifacts as the primary source of truth
- Do not approve sensitive logging, SQL interpolation, or weakened destructive guards as minor issues
- Do not report a performance finding measured **cold**. Julia compiles on first call, so an unwarmed timing is dominated by compilation and every variant reads roughly the same. Call it once, then time a loop, and report both the warm number and the size you measured at — a claim of "44x slower" in one review was 4.3x warm, and the author's restatement of it inherited the error. A wrong perf number is worse than none, because it gets acted on
- Do not count green-theater tests as coverage — a type/shape-only "it ran" assertion, a `@test_throws` with no cause check, a tautology, or a weak bound where the exact value is knowable is a **finding**, not a pass; name it and give the assertion that would actually fail if the behavior regressed
