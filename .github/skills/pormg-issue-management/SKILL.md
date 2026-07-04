---
name: pormg-issue-management
description: Manage the PormG backlog with the gh CLI — create/update/close GitHub issues, curate labels, and keep the TODO.md release-gating index (pre-publish issues only) in sync. Covers the label taxonomy, the draft-before-create safety flow, and cross-reference discipline.
---

# PormG Issue Management

## Purpose

Use this skill for any work on the project backlog: creating or editing GitHub issues, curating
labels, or syncing the `TODO.md` **release-gating index** when a `pre-publish` issue changes. It
encodes the conventions settled when the backlog was first migrated so the tracker stays consistent.

This is a process skill, not a code skill — it does not touch `src/`.

## Use This Skill For

- Creating one or many GitHub issues (especially bulk migration from `TODO.md`)
- Editing, closing, commenting on, or relabeling existing issues
- Keeping the `TODO.md` release-gating index in sync (pre-publish issues only)
- Adding or adjusting labels

## The TODO.md ↔ Issues model

- **GitHub Issues are the source of truth for the entire backlog; `TODO.md` is a release-gating index
  only.** It lists just the `pre-publish`-labeled issues (under the required `⚠️ do BEFORE the first
  General-registry publish` heading), each linking to its `#issue`. Subsystem/priority views come from
  GitHub labels (`gh issue list --label migrations`), not from sections in this file.
- **The `pre-publish` label decides what's in the index — nothing else.** The `TODO.md` list must equal
  `gh issue list --label pre-publish`: add the label → add the line; remove the label → remove the
  line. Opening, closing, or relabeling an ordinary (non-`pre-publish`) issue needs **no `TODO.md` edit
  at all**.
- **Do not delete `TODO.md`.** `.github/instructions/general.instructions.md` references it for the
  `⚠️ do BEFORE the first General-registry publish` release-gating tag. That exact phrase and the
  pre-publish items must remain visible in the index (linking to their issues) so the reference
  resolves.

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
8. **Update the release-gating index — only for `pre-publish` items.** If any newly-created issue is
   `pre-publish`-labeled, add its line to `TODO.md` under the `⚠️` heading. Non-gating issues are not
   listed there — GitHub Issues + labels are their only home.

## Closing a resolved issue

Closing a `pre-publish`-labeled issue and syncing the index are **one operation** — see step 3.

1. **Link the fix.** Prefer letting GitHub auto-close: put `Closes #N` (or `Fixes #N`) in the PR
   description or the commit message that lands the work, so the issue closes on merge *with a
   back-reference to the commit*. For a direct close, use
   `gh issue close <n> --comment "Fixed in <commit/PR>: <one-line summary>"` — always say what fixed
   it, never close silently.
2. **Partial progress ≠ closed.** If only some task-list items are done, do **not** close. Check the
   finished boxes (`- [ ]` → `- [x]`) in the body via `gh issue edit <n> --body-file …` and comment
   on what landed. Close only when every box is done — or split the remainder into a new issue and
   close the original with a pointer to it.
3. **Sync the gating index — only if the issue was `pre-publish`.** If the closed issue carried the
   `pre-publish` label, delete its line from `TODO.md` in the same pass (its history is the closed
   GitHub issue). Ordinary issues don't appear there, so skip this for them. If closing spawned a
   `pre-publish` follow-up, add that new one. Keep the `⚠️ do BEFORE the first General-registry
   publish` note even as its gated items close.
4. **Verify.** Confirm the issue is closed (`gh issue view <n> --json state,closed`); for a
   `pre-publish` issue, also confirm the index no longer lists it.

## Do Not

- Bulk-create issues without showing a draft and getting confirmation first.
- Close an issue that still has unfinished task-list items — check them off or split them out first.
- Close an issue without a comment/PR/commit reference saying what resolved it.
- Close or open a `pre-publish` issue without syncing the `TODO.md` gating index in the same pass.
  (Ordinary issues do **not** touch `TODO.md` — do not re-add per-issue mirror lines.)
- Delete `TODO.md` or drop the `⚠️ do BEFORE the first General-registry publish` tag from it.
- Put draft/placeholder numbers in issue bodies and leave them — resolve to real `#numbers`.
- Inline rich bodies on the command line — use `--body-file`.
- Commit `TODO.md` (or any) changes unless the user asks; backlog edits follow the normal
  commit-only-when-asked rule.
