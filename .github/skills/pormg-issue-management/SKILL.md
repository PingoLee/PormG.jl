---
name: pormg-issue-management
description: Manage the PormG backlog with the gh CLI — create/update/close GitHub issues and curate labels. Covers the label taxonomy, the draft-before-create safety flow, and cross-reference discipline.
---

# PormG Issue Management

## Purpose

Use this skill for any work on the project backlog: creating or editing GitHub issues, or curating
labels. It encodes the conventions settled when the backlog was first migrated so the tracker stays
consistent.

This is a process skill, not a code skill — it does not touch `src/`.

## Use This Skill For

- Creating one or many GitHub issues
- Editing, closing, commenting on, or relabeling existing issues
- Adding or adjusting labels

## Release gating

- **GitHub Issues are the source of truth for the entire backlog.** Subsystem/priority views come from
  labels (`gh issue list --label migrations`), and the **`pre-publish` label is the sole release-gating
  tracker** — the gate check is `gh issue list --label pre-publish` (empty = clear to publish).
- The former `TODO.md` release-gating index was retired in July 2026 when its list emptied (#92 was the
  last item; history in git). If an old doc or issue references `TODO.md`, read that as "the
  `pre-publish` label query".

## Tooling

- Use the **`gh` CLI** (authenticated as the maintainer). Confirm with `gh auth status` and
  `gh repo view --json nameWithOwner,hasIssuesEnabled` before acting. Repo: `PingoLee/PormG.jl`
  (public — see safety note below).
- Common ops: `gh issue create`, `gh issue edit`, `gh issue close`, `gh issue comment`,
  `gh issue list --state open --label <l>`, `gh issue view <n> --json title,labels,body`.
- Always pass rich markdown bodies via `--body-file <path>`, never inline `--body "…"` — heredocs
  and shell escaping mangle backticks, `$`, and code fences. Write the body to a file first.

## Label taxonomy

Reuse the GitHub defaults that fit (`enhancement`, `bug`, `documentation`); create the project
ones idempotently with `gh label create <name> --color <hex> --description "…" --force`.

| Kind | Labels |
|------|--------|
| Type | `enhancement`, `bug`, `documentation`, `tech-debt` |
| Subsystem | `postgres`, `sqlite`, `migrations`, `cjoin`, `performance`, `infrastructure`, `connection-pool` |
| Release gating | `pre-publish` (must be settled before the first General-registry publish) |

## Safety: issues are public and outward-facing

Creating issues publishes content on a public repo and notifies watchers — it is noisy to undo.
**For any bulk creation (more than a couple of issues), draft first and get explicit confirmation
before hitting the API.** A single targeted issue the user asked for can be created directly.

## Bulk migration / creation workflow

1. **Draft, then confirm.** Write every proposed issue (title, labels, full body) to a review file
   and show the user the plan (a title/label table is enough). Create nothing public until they
   approve. Surface grouping decisions (e.g. merging related sub-items into one issue) so they can
   adjust.
2. **One issue per top-level item.** Nested sub-items become a markdown task list (`- [ ]`) in the
   body; preserve the original context (the "why now", blockers, file references).
3. **Verify the parse before the API.** If you split a source file (e.g. a legacy TODO list) into per-issue
   bodies programmatically, print the parsed title/labels/first-body-line for every issue and eyeball
   it before any `gh` call — a malformed public issue is the cost of a parse bug.
4. **Labels first, then issues.** Create/refresh labels (idempotent `--force`), then loop:
   `gh issue create --title "<t>" --label "<comma,separated>" --body-file <f>`.
5. **Capture the real numbers.** You do not know an issue's number until it is created — record each
   returned URL/number into a map.
6. **Fix cross-references.** Never hardcode draft/sequence numbers in bodies. After creation, rewrite
   any `#N` sibling references to the **real** issue numbers (`gh issue edit <n> --body-file …`),
   otherwise `#11` etc. silently links to an unrelated old issue or PR.
7. **Verify after.** Check the open count, label assignment, and spot-check that a rich body (task
   lists, blockquotes, code fences) rendered: `gh issue view <n> --json body -q '.body'`.

## Reproductions: say whether one needs a database

Every bug issue states, near the top, whether reproducing it needs a live database — the established
wording is **"No live database needed (mock connections)"**, followed by an inline model module, or
a hermetic constructor call such as `convertSQLToModel(_introspection_row(...))`.

This is scheduling metadata, not a courtesy. A hermetic repro verifies at rung 1 in seconds and
contends for nothing, so the issue can be worked alongside other sessions; one that needs `db_2` or
`f1.sqlite` costs a fixture negotiation every time anyone touches it. In practice it has been the
single best predictor of whether an issue closes in one sitting. If you build a hermetic repro while
investigating, put it **in the issue**, not only in the PR.

## Superseding an open issue

A design or refactor issue frequently makes an open bug **unrepresentable** rather than fixed. That
relationship has to exist somewhere a query can see, because a superseded issue that still reads as
ordinary open work gets scheduled and planned around at full cost — #431 and #434 stayed live on the
board after #444 superseded them, since the only record was #444's opening line.

When you file (or notice) one issue superseding another:

1. **The superseding issue names them up front** — `**Supersedes:** #A, #B — <what happens to them>`.
   Say whether they become unrepresentable, merely lower priority, or still need a guard if the
   proposal is rejected.
2. **Edit each superseded issue** to point back: `gh issue comment <A> --body "Superseded by #C: …"`.
   A back-reference the other direction is what makes it visible to anyone reading #A alone.
3. **Do not close them on the strength of the proposal.** A `discussion` issue is not a decision.
   They close when the superseding work actually lands — with `Closes #A` in that PR — or they come
   back if the user rejects the design.

## Closing a resolved issue

1. **Link the fix.** Prefer letting GitHub auto-close: put `Closes #N` (or `Fixes #N`) in the PR
   description or the commit message that lands the work, so the issue closes on merge *with a
   back-reference to the commit*. For a direct close, use
   `gh issue close <n> --comment "Fixed in <commit/PR>: <one-line summary>"` — always say what fixed
   it, never close silently.
2. **Partial progress ≠ closed.** If only some task-list items are done, do **not** close. Check the
   finished boxes (`- [ ]` → `- [x]`) in the body via `gh issue edit <n> --body-file …` and comment
   on what landed. Close only when every box is done — or split the remainder into a new issue and
   close the original with a pointer to it.
3. **Verify.** Confirm the issue is closed (`gh issue view <n> --json state,closed`).

## Do Not

- Bulk-create issues without showing a draft and getting confirmation first.
- Close an issue that still has unfinished task-list items — check them off or split them out first.
- Close an issue without a comment/PR/commit reference saying what resolved it.
- Recreate a `TODO.md` backlog mirror — the `pre-publish` label query is the only gating tracker.
- Put draft/placeholder numbers in issue bodies and leave them — resolve to real `#numbers`.
- Inline rich bodies on the command line — use `--body-file`.
