---
name: pormg-session-planning
description: Plan the work order on the "PormG Bug Resolution & Work Sessions" project board — reconcile it against the issues, group open issues into single-sitting sessions, rank those sessions, and write the result back through the ProjectV2 GraphQL API.
---

# PormG Session Planning

## Purpose

**This is a batching technique, not a backlog list.** The premise: issues that share a *cause* are
far cheaper to fix together than apart, because the expensive part of an issue is not the diff — it
is loading the subsystem into your head, building the repro shape, and getting the review context
right. Fix two issues in the same function and the second one pays almost none of that.

A *session* is a group of 2–3 open issues chosen so they share one worktree, one test slice and one
review. Grouping them is what makes a sitting close three issues instead of one.

The evidence is in the board's own history. Session 5 closed #421, #424 and #423 together; #424's fix
was a three-line fail-closed `throw` that would never have justified its own session, but cost
almost nothing while already inside `build_row_join_sql_text` for #421. Session 4 closed #400 and
#410 on a single branch, which is what made #410 — a documented-contract change — tractable at all.

So the goal of a planning round is **speed through batching**, and everything below serves it: group
by shared cause, order within a group so nothing is redone, and rank the groups so the highest-value
batch runs first.

The [project board](https://github.com/users/PingoLee/projects/7) is where that plan is recorded —
its **Session** field holds the grouping, and execution order is stamped into each option's
description. The board is the *plan's* home, not the backlog's.

This is a process skill, not a code skill. It does **not** create, edit or close issues — that is
[`pormg-issue-management`](../pormg-issue-management/SKILL.md) — and it does not implement anything —
that is [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md). It links to both rather than
restating them.

## Use This Skill For

- "What should I pick up next?" / "Give me the implementation order"
- Re-classifying the board after a batch of new issues (every session spawns 2–3 follow-ups, so this
  happens constantly)
- Adding, regrouping or reordering board items

Not for: filing or closing an issue, or working one.

## The golden rule: reconciliation is one-way

The board holds a *plan*, so it is allowed to say things the issues do not — that #421 and #423
belong together, that Session 8 runs third. What it is **not** allowed to do is disagree about
**facts**: whether an issue is open, closed, labelled or superseded.

**On any question of fact, GitHub Issues are the source of truth and the board is corrected — never
the reverse.**

That boundary is what keeps this a planning tool rather than the backlog mirror
`pormg-issue-management` → **Do Not** forbids. Cross it and you have a second index that drifts, and
it drifts fast: #400, #402 and #410 all sat at `In Progress` after they were merged and closed, and
a separate batch moved to `In Progress` out of band. Both times the issues were right.

So: never `gh issue close` / `reopen` / relabel to make an issue agree with a board cell. And never
plan a session around a board row without checking the issue still says what the row implies.

## 1. Reconcile before you plan

Always the first step. Planning on a stale board wastes a whole round — superseded and already-closed
issues get scheduled at full cost.

```bash
gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:7){
  items(first:99){ nodes{ id content{ ... on Issue { number state } }
    fieldValues(first:12){ nodes{ ... on ProjectV2ItemFieldSingleSelectValue {
      name field{ ... on ProjectV2SingleSelectField { name } } } } } } } } } }'
```

Then, for every item:

| Issue state | Board Status | Action |
|---|---|---|
| `CLOSED` | not `Done` | set `Done` |
| `OPEN` | `Done` | clear it — the issue was reopened, or the wrong item was marked |
| `OPEN` | `In Progress` you did not set | **leave it.** Someone is working it. Status you did not write is a signal, not an error |

Also check for open issues that are on no board item at all:

```bash
gh issue list --state open --label bug --limit 100 --json number -q '.[].number' | sort > /tmp/bugs
# ...diff against the item numbers from the query above
```

Note the blind spot: that sweep cannot see an **unlabelled** issue. Cross-check with a bare
`gh issue list --state open` at least once per planning round.

## 2. Group open issues into sessions

**Group by file locality, not by topic.** What makes a session cheap is one worktree, one test slice
and one review — which is a property of *where the fix lands*, not of what the bug is about. Two
issues that sound related but live in different subsystems are two sessions; two that sound unrelated
but both land in `src/migrations/importers.jl` are one.

Then:

- **Read the "Cause" section, not the title.** Titles cluster by symptom; causes cluster by file.
- **Note whether each repro is hermetic** — the rule and its consequences are in
  [`pormg-issue-management`](../pormg-issue-management/SKILL.md) → *Reproductions*. A session of
  hermetic issues can run alongside others; one that needs `db_2` cannot.
- **Check for supersession before grouping** ([same skill](../pormg-issue-management/SKILL.md) →
  *Superseding an open issue*). A superseded issue is not work.
- **2–3 issues.** Three has closed in one sitting repeatedly; four has not been tried.

Record the **order inside** the session, and say which kind it is:

- **Forced** — reversing it costs rework. *"#414 fixes the `fk_map` keying that #415's CTE rewrite
  builds on."* *"#449 first: `custom_join` is an unordered `Dict`, so any test for #448/#447 is
  hash-order dependent until it is fixed."*
- **Preferred** — severity or a cheap warm-up first. Say so, so a future reader can reorder freely.

## 3. Rank the sessions

In descending priority:

1. **Breaking changes, while the repo is pre-publish.** Cheapest now; every session built on the old
   shape raises the cost. #444 ranked first on this alone.
2. **The publish gate.** `gh issue list --state open --label pre-publish` — empty is the gate. Its
   size is a scheduling input: one issue from empty is worth finishing.
3. **Silent wrong data** — wrong rows, misbound parameters, dropped relations. Above loud failures,
   which at least announce themselves.
4. **Leverage** — an issue that taxes every other session. #430 is `priority:low` and blocks anyone
   touching the importers; #438 was `priority:medium` and broke `/pormg-cut-release`'s tooling.

**`priority:*` is severity in isolation, not blast radius.** Overriding it is normal — #430, #438,
#442 and #460 all needed it. State the override and the reason in the same line; an unexplained
override reads as an error.

## 4. Write it back

### Authentication

Board writes need the `project` scope, which the default token does not carry:

```bash
gh auth status                 # look for 'project' in Token scopes
gh auth refresh -s project     # interactive browser flow — the USER runs this, not you
```

### Discover the IDs — never hardcode them

Project, field and option IDs are opaque and change with the board. Resolve them every run:

```bash
gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:7){ id
  fields(first:20){ nodes{ ... on ProjectV2SingleSelectField { id name options{ id name color description } } } } } } }'
```

You want the project `id`, the **Status** field (options `Todo` / `In Progress` / `Done`) and the
**Session** field with its full option list — ids, colors and descriptions included. You need all
three of those per option for the next step.

### Adding a Session option — the footgun

`updateProjectV2Field` **replaces the entire option list**. It does not append. Sending only the new
options deletes every existing one and orphans every item grouped under them.

`ProjectV2SingleSelectFieldOptionInput` accepts an optional `id`, and that is what saves you: resend
every existing option **with its `id`, `color` and `description`**, then append the new ones without
an `id`. Matching ids keeps items attached and lets you rename a group safely.

Pass it as a file — `-f` cannot express a list of objects:

```bash
gh api graphql --input payload.json      # {"query": "...", "variables": {...}}
```

Verify the response lists every pre-existing option with its **original id** before moving on.

### Adding items

`addProjectV2ItemById` returns the item id; then one `updateProjectV2ItemFieldValue` per field
(Session, Status). Add issues **in the order you want them displayed** — row order is insertion
order. To place one between two existing rows, use `updateProjectV2ItemPosition` with `afterId`.

### Encoding rank, which the board cannot express

Group display order follows the *option* order, which is numeric (Session 5, 6, 7…). Execution order
is not. Neither the field nor the item ordering can say "run Session 8 before Session 6".

Stamp it into each option's **description** — `RUN 3rd. #411 -> #420 -> #446. #420 is half the
publish gate.` It surfaces on hover, and it carries the forced-vs-preferred note with it. Restamp
every description when the ranking changes; a stale `RUN 1st` is worse than none.

Mark finished groups `DONE.` rather than deleting them — the history of what shipped together is
what makes the next grouping decision easier.

## Do Not

- Do not change an issue to agree with the board — the board is the derived view, always
- Do not plan on an unreconciled board; closed and superseded issues get scheduled at full cost
- Do not overwrite an `In Progress` you did not set
- Do not call `updateProjectV2Field` without resending every existing option **with its id** — it
  replaces the list, and the items grouped under the dropped options are orphaned
- Do not hardcode project, field or option ids into a script or a note — resolve them per run
- Do not group by topic when the fixes land in different files, or split issues that land in the same one
- Do not leave a `RUN nth` description stale after a re-rank
- Do not treat `priority:*` as the ranking — it is severity in isolation; override it and say why
- Do not commit board-planning changes onto an unrelated feature branch
