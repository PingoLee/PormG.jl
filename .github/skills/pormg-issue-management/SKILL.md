---
name: pormg-issue-management
description: Manage the PormG backlog with the gh CLI — create/update/close GitHub issues, bulk-migrate TODO.md items to issues, and keep TODO.md as a linked index. Covers the label taxonomy, the draft-before-create safety flow, and cross-reference discipline.
---

# PormG Issue Management

## Purpose

Use this skill for any work on the project backlog: creating or editing GitHub issues,
migrating `TODO.md` items into issues, syncing the `TODO.md` index after issues change, or
curating labels. It encodes the conventions settled when the backlog was first migrated so the
tracker stays consistent.

This is a process skill, not a code skill — it does not touch `src/`.

## Use This Skill For

- Creating one or many GitHub issues (especially bulk migration from `TODO.md`)
- Editing, closing, commenting on, or relabeling existing issues
- Keeping `TODO.md` in sync with the issue tracker
- Adding or adjusting labels

## The TODO.md ↔ Issues model

- **GitHub Issues are the source of truth.** `TODO.md` is a *curated linked index of OPEN work
  only*: one line per open item, grouped by the historical sections, each linking to its `#issue`.
- **When an item is solved, remove its line from `TODO.md`** — do not keep a completed list. The full
  history (discussion, linked commits/PRs, close reason, timestamps) already lives in GitHub's closed
  issues: `gh issue list --state closed`. A parallel archive in `TODO.md` only duplicates that and
  drifts. (Work completed *before* the issue tracker existed lives in git history, not GitHub issues.)
- **Do not delete `TODO.md`.** `.github/instructions/general.instructions.md` references it for the
  `⚠️ do BEFORE the first General-registry publish` release-gating tag. That exact phrase and the
  pre-publish items must remain visible in the index (linking to their issues) so the reference
  resolves.
- Edit **issues** for status/discussion; touch `TODO.md` only when an item is opened or closed.

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
| Subsystem | `postgres`, `sqlite`, `migrations`, `cjoin`, `performance`, `infrastructure` |
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
3. **Verify the parse before the API.** If you split a source file (e.g. `TODO.md`) into per-issue
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
8. **Update the index.** Rewrite `TODO.md` to link each item to its issue, keep the section grouping
   and the `⚠️` gating note, and move shipped work to the Completed archive.

## Closing a resolved issue

Closing the issue and syncing the index are **one operation**, not two — never close an issue
without updating `TODO.md` in the same pass.

1. **Link the fix.** Prefer letting GitHub auto-close: put `Closes #N` (or `Fixes #N`) in the PR
   description or the commit message that lands the work, so the issue closes on merge *with a
   back-reference to the commit*. For a direct close, use
   `gh issue close <n> --comment "Fixed in <commit/PR>: <one-line summary>"` — always say what fixed
   it, never close silently.
2. **Partial progress ≠ closed.** If only some task-list items are done, do **not** close. Check the
   finished boxes (`- [ ]` → `- [x]`) in the body via `gh issue edit <n> --body-file …` and comment
   on what landed. Close only when every box is done — or split the remainder into a new issue and
   close the original with a pointer to it.
3. **Remove it from `TODO.md`.** Delete the item's line from its section in the same pass — do not
   archive it in `TODO.md`; its history is the closed GitHub issue. If closing spawned a
   residual/follow-up issue, make sure that new one is listed in the index. Keep the `⚠️` pre-publish
   note even as its gated items close.
4. **Verify.** Confirm the issue is closed (`gh issue view <n> --json state,closed`) and the index no
   longer lists it.

## Do Not

- Bulk-create issues without showing a draft and getting confirmation first.
- Close an issue that still has unfinished task-list items — check them off or split them out first.
- Close an issue without a comment/PR/commit reference saying what resolved it.
- Close or open an issue without syncing the `TODO.md` index in the same pass.
- Delete `TODO.md` or drop the `⚠️ do BEFORE the first General-registry publish` tag from it.
- Put draft/placeholder numbers in issue bodies and leave them — resolve to real `#numbers`.
- Inline rich bodies on the command line — use `--body-file`.
- Commit `TODO.md` (or any) changes unless the user asks; backlog edits follow the normal
  commit-only-when-asked rule.
