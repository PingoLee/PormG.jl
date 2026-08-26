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
4. **The full integration suite is green on both engines** — see below. This is the cut's blocking
   gate, and the only place it runs in full.

### Precondition 4 — the integration gate

Per-issue work runs an *integration slice*, not the suite
([`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → rung 4). The cut is where the full
suite runs, on both backends, because that is where a train's worth of changes meets the shared
prologue — real DDL from empty, a full fixture reseed, the ordering effects no slice can surface.

```bash
julia --project=test/integration test/integration/runtests.jl                  # db_2 (PostgreSQL)
PORMG_DB=db_sl julia --project=test/integration test/integration/runtests.jl   # SQLite
```

- **Ask the maintainer before running** — `db_2` is one shared PostgreSQL server and other sessions
  may be mid-issue on it. Ask which database is free. This is the standing rule; a cut does not
  waive it.
- **Both engines, not one.** *"Keep PostgreSQL and SQLite aligned"* is a non-negotiable, and the
  slice-per-issue model means engine divergence can accumulate for a whole train without anyone
  noticing. The cut is the only thing that catches it.
- **Do not pipe through `tail`** — it masks Julia's exit code.
- **Red means stop.** Do not stamp `UPGRADING.md` or bump `Project.toml` over a failing suite. Fix
  it as its own issue and PR first, then cut. A version tag asserts the train works; making that
  assertion false to save a re-run is the one thing this gate exists to prevent.
- If the maintainer waives the run (a docs-only train, a `z` bump touching nothing executable), say
  so explicitly in the cut report. A skipped gate is a fine outcome; a silently skipped one is not.

## Steps

1. **List the wave — through the parser, not by eye.** Show every `## Unreleased` entry title and its
   `**Severity**`, so the maintainer sees exactly what's shipping. Get the list from
   `upgrade_guide`, which is what a consumer will actually run:

   ```bash
   julia --project=. -e 'using PormG
     w = PormG.upgrade_guide(from = pkgversion(PormG), structured = true)
     println(length(w), " entries")
     for e in w
       sev = match(r"(?m)^-[ \t]+\*\*Severity\*\*:[ \t]*(.+)$", e.body)
       println("  ", e.title, "\n      ", sev === nothing ? "(no Severity bullet)" : sev[1])
     end'
   ```

   Then **cross-check that count against the headings** — if they disagree, an entry is invisible to
   the guide and cutting would ship it unannounced:

   ```bash
   grep -c '^- \*\*Version\*\*: Unreleased' UPGRADING.md   # template block adds 1
   ```

   This is #438: of an 11-entry wave, `upgrade_guide` returned **3** — three entries never reached
   any guide, and five more were merged into a neighbour's body and rendered under its title.
   Every step below passed anyway. `test/unit/test_upgrade_guide.jl` now fails on that state —
   run it here if the counts disagree, it will name the heading.

2. **Choose the new version.** Read the current `version` in `Project.toml`.
   - **Default: bump the `y` slot** (`0.a.z → 0.(a+1).0`) — a train that carries any
     `**Severity**: breaking` or `behavior` entry is a migration checkpoint.
   - **`z` bump** (`0.a.z → 0.a.(z+1)`) only if **every** entry is `additive` / `no-action`.
   - Show `current → proposed` and **confirm with the maintainer** before editing anything.

3. **Bump `Project.toml`.** Set `version = "<new>"` (this is the *only* place the version moves).

4. **Stamp `UPGRADING.md`** (use today's real date, `YYYY-MM-DD`):
   - For **each** entry currently under `## Unreleased`: replace its
     `- **Version**: Unreleased` line with `- **Version**: <new>`.
   - **Add a `- **Recorded**: <date-the-entry-landed>` bullet to any entry missing one** (between
     `- **PormG ref**:` and `- **Severity**:`, as the template has it). `Recorded` is the date the
     change landed, **not** the cut date. Recover it from the **oldest** pickaxe match, not the
     newest — a later reword of the heading would otherwise hand you its edit date:

     ```bash
     git log --reverse --format='%as' -S'<the entry heading line>' -- UPGRADING.md | head -1
     ```

     Every entry carries one as of #438; keep it that way, because the file header promises this
     step "dates them".
   - Replace the `## Unreleased — next \`<x>\`` heading (and its italic placeholder note) with
     `## <new> — <YYYY-MM-DD>`.
   - Insert a **fresh empty** `## Unreleased — next \`<next-y>\`` block at the very top of the entries
     (above the just-stamped section), carrying the same placeholder note the previous one had.
   - **Sweep the prose.** Stamping the `- **Version**:` bullet does *not* fix an entry **body** that
     refers to itself as unreleased. Grep the just-stamped section for `Unreleased` and rewrite every
     prose hit — "Part of the current `## Unreleased` wave … when the train is cut" is false the
     moment it ships, and points readers at a section that is now empty:
     ```bash
     awk '/^## <new> —/,/^## [0-9]/' UPGRADING.md | grep -n 'Unreleased'   # expect: no prose hits
     ```
     Prefer version-neutral phrasing when *writing* an entry (`Part of the `<y>.x` pre-publish wave —
     roll it forward with the other `<y>.*` entries`) so there is nothing to sweep. Caught in #201,
     which shipped in 0.3.0 still telling apps to wait for a cut that had already happened.
   - Leave already-stamped (older) entries untouched.

5. **Verify the parser.** Run `julia --project=. test/unit/test_upgrade_guide.jl` (via a runner that
   loads drivers, or the full `test/runtests.jl`). Then assert the stamp actually landed — the count
   must match step 1's, at the new version, with `## Unreleased` now empty:

   ```bash
   julia --project=. -e 'using PormG
     println("at <new>  : ", length(PormG.upgrade_guide(from = v"<previous>", to = v"<new>", structured = true)))
     println("uncut     : ", count(e -> e.version == PormG._UNRELEASED_VERSION, PormG._read_upgrading_entries()))'
   ```

   Expect `at <new>` == the step-1 count and `uncut` == 0. Fix any mismatch before committing —
   before #438 this step read *"the stamped entries must now parse"* with nothing to check it, and
   the precondition passed while being false.

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
- **Never cut over a red or unrun integration suite.** Per-issue work only runs slices, so the cut is
  the *first and only* time a train is validated end-to-end on both engines. Skipping it does not
  defer the cost — it ships it.
- **`Unreleased` is a literal token**, not a version — `_parse_upgrading` maps it to a high sentinel
  (`_UNRELEASED_VERSION`) so uncut entries sort newest and `upgrade_guide` surfaces them by default.
  Stamping replaces that token with the real `VersionNumber`.
- The date is **today's real date** — never invent one; if unsure, ask.
