---
name: pormg-cut-release
description: Cut a PormG release train — bump Project.toml once, stamp the ## Unreleased UPGRADING.md entries with the new version, date and tag it, and open a fresh ## Unreleased. Maintainer-invoked, typically right before rolling changes into a consuming app.
---

# PormG — Cut a Release Train

## Purpose

PormG versions **per release train, not per PR** (see the *Versioning* non-negotiable in
[`general.instructions.md`](../../instructions/general.instructions.md) and the `UPGRADING.md`
header). During a train, breaking/behavior PRs only append to the **`## Unreleased`** section of
`UPGRADING.md` and never touch `Project.toml`. This skill performs the **cut**: the single,
deliberate, maintainer-triggered step where the accumulated `Unreleased` work becomes a numbered,
tagged release.

**Invoke it only when the maintainer asks** (`/pormg-cut-release`, "cut a release", "cut the train").
The natural trigger is *"I'm about to roll these changes into a consuming app"* — the version marks
that migration checkpoint. Never cut as a side effect of another task, and never bump `Project.toml`
outside this skill.

## Preconditions (check first, stop if unmet)

1. On the default branch (or a dedicated release branch), **clean working tree**.
2. `UPGRADING.md` has at least one entry under `## Unreleased` (grep `- \*\*Version\*\*: Unreleased`).
   **If `## Unreleased` is empty, stop** — there is nothing to cut.
3. The full unit suite is green on this commit (or run it as step 5).

## Steps

1. **List the wave.** Show every `## Unreleased` entry title and its `**Severity**`, so the maintainer
   sees exactly what's shipping. Count them.

2. **Choose the new version.** Read the current `version` in `Project.toml`.
   - **Default: bump the `y` slot** (`0.a.z → 0.(a+1).0`) — a train that carries any
     `**Severity**: breaking` or `behavior` entry is a migration checkpoint.
   - **`z` bump** (`0.a.z → 0.a.(z+1)`) only if **every** entry is `additive` / `no-action`.
   - Show `current → proposed` and **confirm with the maintainer** before editing anything.

3. **Bump `Project.toml`.** Set `version = "<new>"` (this is the *only* place the version moves).

4. **Stamp `UPGRADING.md`** (use today's real date, `YYYY-MM-DD`):
   - For **each** entry currently under `## Unreleased`: replace its
     `- **Version**: Unreleased` line with `- **Version**: <new>`.
   - Replace the `## Unreleased — next \`<x>\`` heading (and its italic placeholder note) with
     `## <new> — <YYYY-MM-DD>`.
   - Insert a **fresh empty** `## Unreleased — next \`<next-y>\`` block at the very top of the entries
     (above the just-stamped section), carrying the same placeholder note the previous one had.
   - Leave already-stamped (older) entries untouched.

5. **Verify the parser.** Run `julia --project=. test/unit/test_upgrade_guide.jl` (via a runner that
   loads drivers, or the full `test/runtests.jl`). The stamped entries must now parse at `<new>` and
   the empty `## Unreleased` must produce no entries. Fix any mismatch before committing.

6. **Commit** (respect the commit gate — show the diff, get explicit approval):
   `chore(release): cut <new>` with the entry titles in the body.

7. **Tag** (confirm first — tagging/pushing is a separate outward step). Tag the commit on `main`
   that carries the new `Project.toml` version — the merge commit of the release PR, not the branch
   commit:
   `git tag -a v<new> <sha> -m "PormG v<new>"` + the entry titles in the body, then
   `git push origin v<new>` (a plain `git push` does **not** carry tags).

   The **`v` prefix is required**: once PormG is registered in General, `JuliaRegistries/TagBot`
   (already wired in `.github/workflows/TagBot.yml`) takes over tagging and emits `vX.Y.Z`. Matching
   it now keeps one continuous series instead of two parallel ones. Pre-publish, TagBot never fires —
   nothing comments as `JuliaTagBot` — so tags are manual until then. Tag history starts at `v0.3.0`;
   earlier versions are deliberately untagged (per-PR bumps, and `0.3.0`–`0.3.3` were burned and
   reclaimed before the release-train policy landed).

8. **Roll it out.** The reason you cut: work each consuming app through the newly-stamped entries
   (`PormG.upgrade_guide(from = v"<app's pinned version>")`), then bump that app's PormG dependency
   pin to `<new>` — the pin *is* the app's rollout state (there are no per-entry rollout tables).

## Guardrails

- **One bump per cut.** If you find yourself editing `Project.toml`'s version outside this skill, stop
  — that's the per-PR churn this model removes.
- **Never cut an empty `## Unreleased`.**
- **`Unreleased` is a literal token**, not a version — `_parse_upgrading` maps it to a high sentinel
  (`_UNRELEASED_VERSION`) so uncut entries sort newest and `upgrade_guide` surfaces them by default.
  Stamping replaces that token with the real `VersionNumber`.
- The date is **today's real date** — never invent one; if unsure, ask.
