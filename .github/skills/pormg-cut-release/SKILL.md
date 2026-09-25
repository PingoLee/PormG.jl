---
name: pormg-cut-release
description: "Cut a PormG release train — bump Project.toml once, stamp the Unreleased entry files under upgrading/ with the new version, then date, record and tag it. Maintainer-invoked, typically right before rolling changes into a consuming app."
---

# PormG — Cut a Release Train

## Purpose

PormG versions **per release train, not per PR** (see the *Versioning* non-negotiable in
[`general.instructions.md`](../../instructions/general.instructions.md) and the
[`UPGRADING.md`](../../../UPGRADING.md) contract). During a train, breaking/behavior PRs only add a
**new file** to [`upgrading/`](../../../upgrading/) carrying `- **Version**: Unreleased`, and never
touch `Project.toml`. This skill performs the **cut**: the single, deliberate, maintainer-triggered
step where the accumulated `Unreleased` work becomes a numbered, tagged release.

**Invoke it only when the maintainer asks** (`/pormg-cut-release`, "cut a release", "cut the train").
The natural trigger is *"I'm about to roll these changes into a consuming app"* — the version marks
that migration checkpoint. Never cut as a side effect of another task, and never bump `Project.toml`
outside this skill.

## Preconditions (check first, stop if unmet)

1. On the default branch (or a dedicated release branch), **clean working tree**.
2. **At least one entry is uncut** — `grep -l '\*\*Version\*\*: Unreleased' upgrading/*.md` must
   list a file. **If nothing is uncut, stop** — an empty train is not a release.
3. The full unit suite is green on this commit (or run it as step 5).
4. **The full integration suite is green on both engines** — see below. This is the cut's blocking
   gate, and the only place it runs in full.

### Precondition 4 — the integration gate

Per-issue work runs an *integration slice*, not the suite
([`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → rung 4). The cut is where the full
suite runs, on both backends, because that is where a train's worth of changes meets the shared
prologue — real DDL from empty, a full fixture reseed, the ordering effects no slice can surface.

```bash
julia -t auto --project=test/integration test/integration/runtests.jl                  # db_2 (PostgreSQL)
PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/runtests.jl      # SQLite — -t 1 required
```

**The `-t 1` on the SQLite run is not optional.** SQLite does not tolerate `-t auto`
(`test/integration/common_setup.jl`, above the connection setup). Julia defaults to one thread, so
omitting it passes right up until `JULIA_NUM_THREADS` is set in the shell — and the release gate is
the single worst place to inherit a flake from an unstated default.

- **Ask the maintainer before running** — a full suite is one of the integration runs that stays
  gated ([`general.instructions.md`](../../instructions/general.instructions.md) → *Merge gate*): minutes of load, and a
  truncate-and-reseed that leaves the fixture half-seeded for every later slice if it is cut short.
  This is the standing rule; a cut does not waive it.
- **Both engines, not one.** *"Keep PostgreSQL and SQLite aligned"* is a non-negotiable, and the
  slice-per-issue model means engine divergence can accumulate for a whole train without anyone
  noticing. The cut is the only thing that catches it.
- **Do not pipe through `tail`** — it masks Julia's exit code.
- **Red means stop.** Do not stamp the entries or bump `Project.toml` over a failing suite. Fix
  it as its own issue and PR first, then cut. A version tag asserts the train works; making that
  assertion false to save a re-run is the one thing this gate exists to prevent.
- If the maintainer waives the run (a docs-only train, a `z` bump touching nothing executable), say
  so explicitly in the cut report. A skipped gate is a fine outcome; a silently skipped one is not.

## Steps

1. **List the wave — through the parser, not by eye.** Show every uncut entry title and its
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

   Then **cross-check that count against the log directory** — if they disagree, an entry is
   invisible to the guide and cutting would ship it unannounced:

   ```bash
   grep -l '^- \*\*Version\*\*: Unreleased' upgrading/*.md | wc -l   # one file per entry, exactly
   ```

   **No fudge factor any more** (#638): the authoring template lives in `UPGRADING.md`, which is not
   parsed and is not in `upgrading/`, so this count is the wave count with nothing to subtract.

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

4. **Stamp the uncut entries** (use today's real date, `YYYY-MM-DD`):
   - For **each** file the precondition grep listed, replace its `- **Version**: Unreleased` bullet
     with `- **Version**: <new>`. That is the whole stamp — there is no section heading to rewrite
     and no fresh `## Unreleased` to open, because an entry's release lives only in its own bullet
     (#638).
   - **Record the train** in the *Release trains* table in [`UPGRADING.md`](../../../UPGRADING.md):
     change the ``Unreleased — next `<x>` `` row to `` `<new>` | <YYYY-MM-DD> `` and add a fresh
     ``Unreleased — next `<next-y>` `` row above it. **That table is the only place a release date
     is recorded now, so skipping it loses the date for good** — `test/unit/test_upgrade_guide.jl`
     fails when a cut version has no dated row.
   - **Never rename an entry file while stamping.** The filename carries the `- **Recorded**:` date,
     not the release, and the suite asserts the two agree.
   - **Add a `- **Recorded**: <date-the-entry-landed>` bullet to any entry missing one** (between
     `- **PormG ref**:` and `- **Severity**:`, as the template has it). `Recorded` is the date the
     change landed, **not** the cut date — and it is what the file is named after, so an entry
     missing one has no name the sort can trust. Recover it from the commit that ADDED the file:

     ```bash
     git log --reverse --format='%as' --diff-filter=A -- upgrading/<the file> | head -1
     ```

   - **Sweep the prose.** Stamping the `- **Version**:` bullet does *not* fix an entry **body** that
     refers to itself as unreleased — that ships stale:

     ```bash
     grep -l '^- \*\*Version\*\*: <new>' upgrading/*.md |
       while read -r f; do grep -Hn 'Unreleased' "$f"; done     # expect: no hits
     ```

     The loop, not `$(...)` or `xargs -r`: an empty file list would leave a bare `grep` reading
     stdin and the step would hang rather than report, and `xargs -r` is a GNU extension that
     BSD/macOS `xargs` rejects outright. `-H` so a hit names its file even when only one matched.
     Prefer version-neutral phrasing when *writing* an entry (`Part of the `<y>.x` pre-publish wave —
     roll it forward with the other `<y>.*` entries`) so there is nothing to sweep. Caught in #201,
     which shipped in 0.3.0 still telling apps to wait for a cut that had already happened.
   - Leave already-stamped (older) entries untouched.

5. **Verify the parser.** Run `julia --project=test/integration test/unit/test_upgrade_guide.jl` — that
   env carries the drivers, which `--project=.` cannot (#624). Then assert the stamp actually landed — the count
   must match step 1's, at the new version, with nothing left uncut:

   ```bash
   julia --project=. -e 'using PormG
     println("at <new>  : ", length(PormG.upgrade_guide(from = v"<previous>", to = v"<new>", structured = true)))
     println("uncut     : ", count(e -> e.version == PormG._UNRELEASED_VERSION, PormG._read_upgrading_entries()))'
   ```

   Expect `at <new>` == the step-1 count and `uncut` == 0. Fix any mismatch before committing —
   before #438 this step read *"the stamped entries must now parse"* with nothing to check it, and
   the precondition passed while being false.

6. **Commit** — stage explicitly: `git add upgrading/ UPGRADING.md Project.toml`, then
   `chore(release): cut <new>` with the entry titles in the body. A release cut is
   maintainer-invoked, so the invocation authorizes the commit and the PR — but **not** the tag,
   which is outward-facing and gated on its own (step 7), like every other item on the merge gate's
   still-gated list in [`general.instructions.md`](../../instructions/general.instructions.md).

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
- **Never cut a train with no `Unreleased` entries.**
- **Never cut over a red or unrun integration suite.** Per-issue work only runs slices, so the cut is
  the *first and only* time a train is validated end-to-end on both engines. Skipping it does not
  defer the cost — it ships it.
- **`Unreleased` is a literal token**, not a version — `_parse_upgrading` maps it to a high sentinel
  (`_UNRELEASED_VERSION`) so uncut entries sort newest and `upgrade_guide` surfaces them by default.
  Stamping replaces that token with the real `VersionNumber`.
- **Do not write a `## <new> — <date>` release marker into an entry file.** Release markers no
  longer exist in the log (#638); the release lives in each entry's `- **Version**:` bullet and its
  date in the *Release trains* table. The parser still filters marker-shaped headings, so one added
  by hand would not become an entry title — it would simply be ignored, silently.
- **One entry per file.** Asserted by `test/unit/test_upgrade_guide.jl`; a second entry in one file
  is the swallow shape #438 was filed for.
- The date is **today's real date** — never invent one; if unsure, ask.
