# PormG Board — Reference

The *why* behind the steps in [`SKILL.md`](SKILL.md). Load a section from here only when you reach
the step that points at it — the checklist in `SKILL.md` is complete on its own, and this file exists
so the rationale is not paid for on every invocation.

Most invocations of this skill are *"what should I pick up next?"* and never reach §4. Those runs
should not carry the write-back footguns in context at all.

Nothing here is optional-but-nice. Every section documents a failure that has actually bitten this
repo — or its sibling `Nitro.jl`, whose board skill this one mirrors, named where that is the case —
in a way that is invisible from reading the board.

---

## A. Why planning is its own deliverable (SKILL.md §0)

Board work and cluster work lived in one skill — `pormg-session-planning` — with no boundary between
them. In the sibling Nitro repo that shape produced the incident this rule was written from: a
session invoked to plan the board asked *"what should this session actually run?"* as part of
ranking, read the answer as authorization, and went on to write, test, review, and commit code the
user had not asked for. The board half of that session was what they wanted; the rest was
unrequested.

That is the whole reason §0 exists, and why the consent question has to be asked **in its own words,
after the board is written**. A ranking question and a work order look identical in a transcript once
the answer is a single word.

The hand-off costs more here than it did before the merge-gate change in
[`general.instructions.md`](../../instructions/general.instructions.md). A "yes" to *"shall I start
work on X?"* now runs all the way to an open PR without stopping again. The yes collected here is the
last one before a branch exists — which raises the bar on asking it cleanly, not lowers it.

---

## B. The sweep goes past board membership, and the label filter hid both halves (SKILL.md §1)

Reconciling board 7 on 2026-09-13 found **30 of 48 open issues on no board item at all** — more than
half the backlog invisible to every planning pass. The board looked healthy from the inside: 63
items, every open one carrying a `Session`, descriptions stamped with `RUN nth`.

The cause was the sweep itself. It was written as
`gh issue list --state open --label bug --limit 100`, and the skill *documented* the blind spot in
the next sentence ("that sweep cannot see an **unlabelled** issue") with an instruction to
cross-check bare "at least once per planning round". A documented blind spot with a manual
cross-check is not a guard; it is a note. The bare sweep is now the only form in `SKILL.md`, because
the filtered one costs exactly the same and answers a different question.

The sibling Nitro board hit the other half of this: **one** open issue off the board and **26** on it
with an empty `Session`. Membership and `Session`-emptiness are two independent ways for an issue to
be unschedulable, and §2 ranks neither — which is why the projection in §1 selects the `Session`
value alongside `state` and `Status`. It costs nothing extra once the query is projected.

---

## C. `updateProjectV2Field` replaces the entire option list (SKILL.md §4)

It does not append. Sending only the new option **deletes every existing one** and orphans every item
grouped under them. Board 7 carried 17 Session options and 30 items grouped under them on
2026-09-24; a careless mutation detaches all of them at once.

`ProjectV2SingleSelectFieldOptionInput` accepts an optional `id`, and that is what saves you: resend
every existing option with its `id`, `color`, and `description`, then append the new one without an
`id`. Matching ids keep items attached, and they also let you rename a group safely — a rename with
the id present is a rename, a rename without it is a delete plus a create.

This is why §4 builds the payload **file-to-file with `jq`** rather than by retyping the options. The
mechanical part — carrying twenty-eight options forward byte-for-byte — is exactly what an agent is
worst at and what `jq` is perfect at, and every description that passes through the transcript on its
way back to the API is a description that can come back subtly different.

`-f` cannot express a list of objects, so the mutation goes through `--input`.

---

## D. The 450-character cap, and why the grammar is ASCII (SKILL.md §4)

The API rejects the **whole mutation** over the limit — one long description fails *every* option in
the batch, not just its own. That is why §4 checks lengths before submitting instead of discovering
it in an error.

Board 7 is already at the edge: `Session 19: Introspection to IR (Phase 3)` sits at **exactly 450**
characters, and `Session 26` at 416. Any edit that touches those two has no headroom, and the
failure will name the cap rather than the option.

Stated honestly because it matters for how you count: the limit is known only from the API rejecting
a batch with the message *"Settings option description is too long (maximum is 450 characters)"*.
Whether it counts characters or bytes is **unconfirmed**.

Keeping descriptions ASCII makes the two identical, which is the real reason the grammar says ASCII,
`--` rather than an em-dash, and `->` rather than an arrow glyph. A 445-character description with a
dozen em-dashes is ~470 bytes and would fail the whole batch.

---

## E. The description is a struct in a string, and it mixes volatile with stable (SKILL.md §4)

`RUN 2nd | TIER standard | READY. FILES: … ORDER: … WHY: …` packs six fields into one string because
the board has nowhere else to put them. That works, but the fields have wildly different volatility:

| Field | Changes | Cost of that change today |
|---|---|---|
| `RUN nth` | every re-rank | rewrite **every** description, resend the full option list |
| state (`READY`/`BLOCKED`) | most sessions | same |
| `TIER` | rarely | same |
| `FILES:` / `ORDER:` / `WHY:` | when the cluster changes | same |

Every row pays the cost of the most volatile one. Re-ranking — the single most common board edit —
means reproducing several KB of description text that did not change, just to move a number.

The `jq` recipe in §4 removes most of that cost without changing the board: unchanged descriptions
are carried by `jq` from the API's own response and never enter the transcript. **That is a
mitigation, not a fix.**

The structural fix is to split by volatility — `RUN` becomes a ProjectV2 **Number** field and state a
**single-select**, leaving only `FILES:`/`ORDER:`/`WHY:` in the description. Re-ranking then becomes N
tiny `item-edit` calls that touch no description and never invoke the replace-all path at all, and the
board gains sortable/groupable rank and state columns for free — impossible today because both are
buried in a string.

It is not done because it is a one-way migration through the exact mutation described in §C, and the
`jq` recipe made it non-urgent. Do it deliberately, in its own session, not as a side effect of a
planning run.

---

## F. Parallel sessions: what survives filesystem isolation (SKILL.md §3)

Disjoint `FILES:` is the first gate and it is **necessary but not sufficient**. Three constraints
outlive the worktree boundary:

**`db_2` verification serializes, and it does so on purpose.** `common_setup.jl` takes a PostgreSQL
session-level advisory lock on the selected database, so a second session running against `db_2`
waits — logging who holds it every 30s — instead of interleaving its schema and fixture phases into
the first run. It sits in `common_setup.jl` rather than `runtests.jl` because all 40 integration
entry points include it and a single `test_*.jl` is the normal target. `PORMG_TEST_LOCK_WAIT=<secs>`
bounds the queue (default 900); `PORMG_TEST_LOCK=0` opts out; `release_suite_lock!()` frees it early.
The lock dies with the connection, so exit / Ctrl-C / crash all release it.

The scheduling consequence: two sessions can *edit* in parallel and must *queue* to verify against
`db_2`. It is also advisory, so a manual `psql` or a downstream app still writes underneath you.

**`db_sl` is exempt, and that is what makes hermetic issues schedulable.** `f1.sqlite` is copied
per-worktree, so a SQLite session contends with nothing. A session whose members all reproduce on
mock connections contends with even less. This is why
[`pormg-issue-management`](../pormg-issue-management/SKILL.md) → *Reproductions* makes every bug
issue state whether it needs a live database: it is the single best predictor of whether a session
can run alongside another, and it has to be recorded on the issue rather than re-derived at planning
time.

**A hostile repro is a different category from a hungry one.** The suite lock arbitrates *using*
`db_2`; it does not arbitrate *destroying* it. `pg_terminate_backend`, a server restart, a schema
drop or a fixture wipe kills every other session's connections, and those sessions report failures
that are not theirs. Such a session is `SOLO` — not schedulable in parallel with anything, including
a `db_sl` session that happens to share the machine.

**Uncommitted work is invisible.** Neither `git log` nor `git diff main...<branch>` shows it, so a
session can look idle while holding edits to the file you are about to plan onto. Receipt:
`fix/400-410-importer-degrades` and `fix/402-enum-scope-per-statement` sat in correct worktrees and
still both edited `src/migrations/importers.jl`, `docs/src/import_django.md` and
`test/unit/test_import_django_project.jl` simultaneously — the second branch owed a merge
(`ac0c57c`). Check what is actually in flight per
[`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Isolate*.

Why per-session `FILES:` rather than a conflict matrix: a pairwise matrix is O(n²) to maintain and
goes stale the moment a session is added, silently. Recording each session's own surface and deriving
the pairing keeps one source of truth per session.

---

## G. Two reporting failures worth not repeating (SKILL.md §5)

In the sibling Nitro repo, a session that had just written 19 ranked options echoed them all back in
full, **twice**, before the user asked plainly for a table of what fits in one Claude session. The
descriptions are written for the *next* session to read off the board, which already has a URL —
re-rendering them in the transcript is pure cost with no reader.

Separately, that board's first ten Session options were created with **empty descriptions**. With six
of them done or partly done and four untouched, nothing on the board said which ran next, and the
ranking had to be re-derived from scratch every session. Board 7 avoided that — its `DONE. #421,
#424, #423 - via PR #436, #440.` form is exactly the history that makes the next grouping decision
cheap — but its `Active` option still carries an empty description today. An option with no
description is not a plan, it is a label.
