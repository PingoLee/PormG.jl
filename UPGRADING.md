# Upgrading PormG — consumer-app rollout log

Tracks **breaking / behavior changes in PormG** that require source-code changes in the internal
apps that depend on it. PormG is pre-publish (single maintainer, ~4 internal apps, no external
users), so breaking changes are intentional and cheap on the *PormG* side — but each one still has
to be rolled out by hand in every consuming app. This file is the contract for *writing* that
rollout log; the log itself lives in [`upgrading/`](upgrading/).

> ⚠️ **Not database migrations.** This log is about migrating **app source code** to keep up with
> the PormG API. It is unrelated to the `makemigrations` / `migrate` schema engine that manages your
> database tables.

> 🚀 **Upgrading an app? Don't read the log by hand.** Run
> `PormG.upgrade_guide(from = v"<your pinned version>")` — it renders only the entries newer than
> your pin, newest-first. The full how-to (versioning model, the apply recipe, driving it with an AI
> agent) lives in the docs: **[Upgrading PormG](https://pingolee.github.io/PormG.jl/dev/upgrading/)**.

## Where the entries live

**One file per change, under [`upgrading/`](upgrading/)**, named `YYYY-MM-DD-<slug>.md` — the date
from the entry's own `- **Recorded**:` bullet, so the directory sorts chronologically, and a slug
leading with the issue number when there is one (`2026-09-20-576-every-read-path-raises-filtererror.md`).
**The slug is lowercase** — digits, dots and dashes only; `test/unit/test_upgrade_guide.jl` pins the
whole name against `^\d{4}-\d{2}-\d{2}-[a-z0-9.-]+\.md$`, and the extension must be `.md`.

This used to be one `UPGRADING.md` with every entry prepended under a single `## Unreleased`
header. That header was **one anchor line**, so any two concurrent sessions that both owed an entry
conflicted *every time*, in the one file whose whole job is to be the compatibility story
([#638](https://github.com/PingoLee/PormG.jl/issues/638) — 14 merge commits touch the file on
`main`, 5 of them recording a conflict resolution). A file per entry makes the conflict
unrepresentable rather than merely resolvable.

Consequences worth knowing before you add one:

- **Every `.md` in `upgrading/` is an entry.** There is no name-pattern filter in the reader, on
  purpose — one would make a mis-named entry vanish from `upgrade_guide` silently, which is exactly
  the failure class [#438](https://github.com/PingoLee/PormG.jl/issues/438) was about. Put nothing
  else in the directory; this contract and the template stay here, and this file is **not** parsed.
- **There are no `## <version> — <date>` release markers any more.** An entry states its own release
  in its `- **Version**:` bullet, which is the only thing `upgrade_guide` ever scoped by. Release
  dates are recorded in *Release trains* below.
- **Order inside one version is presentation only.** `upgrade_guide(from = …)` scopes by version,
  never by position; entries sharing a version render newest `Recorded` date first.
- **A directory listing is not the reading order.** `ls`, GitHub's tree view and Explorer all sort
  *ascending*, so browsing `upgrading/` shows the OLDEST entry first. `upgrade_guide` reverses it
  and then sorts by version; read its output, or read the listing bottom-up.

## Writing an entry

- **One `##` entry per breaking change, in a new file.** It carries `- **Version**: Unreleased` and
  **no `Project.toml` bump**; the maintainer stamps it with a release number when cutting a train
  (`/pormg-cut-release`).
- **What makes it an entry, for `upgrade_guide`:** its `##` heading, plus a `- **Version**:` bullet
  at the **start of a line**. Nothing else. (#438: the parser used to require `---` **and**
  `- **Recorded**:`, which these rules never asked for. Nine headings written to spec were lost.)
- **One entry per file, and only one `## ` heading at column 0.** The parser segments on `## `
  headings, so a second entry in the same file parses as a second entry *from that file* — and
  `test/unit/test_upgrade_guide.jl` fails on it, because a file that holds two entries is the
  merge-conflict shape this layout exists to remove. A fenced example showing a literal markdown
  heading must indent it.
- Each entry records: the PormG **version** it shipped in, what changed, why, a *"How to find the
  calls to migrate"* grep, and the concrete **before → after** code edit.
- **Every entry needs a `- **Recorded**:` bullet.** Its date is what names the file, and the suite
  asserts the filename prefix equals it. Without it the entry still parses, but under a name the
  sort cannot trust.
- **Not for additive features.** This log is only what **forces** an app edit. A new opt-in
  capability (operator, kwarg, function) requires no change to keep an app working → document it in
  `docs/`, not here.
- **No per-entry rollout tables.** An app's own PormG dependency pin *is* its rollout state, and
  `upgrade_guide(from = <that pin>)` derives what it still needs — so there is nothing to maintain
  per app.
- **Keep the prose version-neutral.** Write *"part of the `0.3.x` pre-publish wave"*, never *"part of
  the current unreleased wave"* — stamping rewrites the `- **Version**:` bullet, not the body, so
  self-referential prose ships stale (this bit #201).
- Entries are version-stamped from **`0.2.0`** onward. The fourteen entries with no `- **Version**:`
  bullet predate the versioning policy and are unstamped (treat them as already shipped before
  `0.2.0`); that set is closed, and the suite pins it by filename, so a new entry that omits the
  bullet fails loudly instead of sorting below every consumer's pin.

## Release trains

Cut by the maintainer via `/pormg-cut-release`, which stamps every `Unreleased` entry with the new
number and adds its row here. Entries not listed under a number are uncut — a consumer dev'ing
PormG at HEAD is running them, and `upgrade_guide` surfaces them by default.

| Train | Cut |
|---|---|
| Unreleased — next `0.7.0` | — |
| `0.6.0` | 2026-09-18 |
| `0.5.0` | 2026-09-04 |
| `0.4.0` | 2026-08-10 |
| `0.3.0` | 2026-07-24 |
| `0.2.3` | 2026-07-24 |
| `0.2.0` | 2026-07-23 |

`0.2.0` and `0.2.3` predate the release-train policy — they were per-PR bumps, and are listed only
because an entry carries each of them. Tag history starts at `v0.3.0`.

## Template for new entries

Copy the block below into a **new file** `upgrading/<YYYY-MM-DD>-<slug>.md` for each new
breaking/behavior change. Do NOT bump `Project.toml` — the version moves once, at cut time
(the `/pormg-cut-release` skill rewrites `Version: Unreleased` → the release number).

<!--
## `<api>` — <one-line summary of the change>

- **Version**: Unreleased
- **PormG ref**: <issue / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```
-->
