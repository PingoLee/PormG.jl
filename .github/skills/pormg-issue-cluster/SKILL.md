---
name: pormg-issue-cluster
description: Work several issues as one group — build a cluster from contended files rather than shared labels, tier it by its worst member, order it by dependency then importance, land one commit and one UPGRADING entry per issue, and close out N issues at once. Sits above pormg-issue-workflow; run pormg-board first to decide which cluster is next.
---

# PormG Issue Cluster

## Purpose

**This is a batching technique, not a backlog list.** The premise: issues that share a *cause* are
far cheaper to fix together than apart, because the expensive part of an issue is not the diff — it
is loading the subsystem into your head, building the repro shape, and getting the review context
right. Fix two issues in the same function and the second one pays almost none of that.

A *cluster* (the board calls it a *session*) is a group of 2–4 open issues chosen so they share one
worktree, one test slice and one review. Grouping them is what makes a sitting close three issues
instead of one.

The evidence is the board's own history. Session 5 closed #421, #424 and #423 together; #424's fix
was a three-line fail-closed `throw` that would never have justified its own session, but cost
almost nothing while already inside `build_row_join_sql_text` for #421. Session 4 closed #400 and
#410 on a single branch, which is what made #410 — a documented-contract change — tractable at all.

This skill owns **which issues go together, in what order, and what "done" means for a group**.
*Which* cluster runs next is [`pormg-board`](../pormg-board/SKILL.md), not this skill. It does not
restate [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) — that skill still owns
provenance, isolation, implementation, the verify rungs, review, and the merge gate. Read this one to
build the group; read that one for every step inside it. It does not create, edit or close issues
either — that is [`pormg-issue-management`](../pormg-issue-management/SKILL.md).

## Use This Skill For

- Two or more open issues whose fixes touch the same file, and ideally the same function
- A set of issues that turn on **one design decision** made once (a namespace model, a keying scheme)
- Mopping up the remainder of a subsystem right after a related fix merged

Not for: **"what should I pick up next?", "update the board", or "plan the session" — those are
[`pormg-board`](../pormg-board/SKILL.md), which answers them and stops.** Also not for: a single
issue (use [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md)), filing or closing an issue
(use [`pormg-issue-management`](../pormg-issue-management/SKILL.md)), issues that merely share a
label, or a "let's clear the backlog" sweep across unrelated subsystems.

## 0. Reconcile and rank the board

**Canonical: [`pormg-board`](../pormg-board/SKILL.md).** Reconciling the board against GitHub Issues,
ranking the sessions, and writing the plan back live there — including the `Session` description
grammar, the `updateProjectV2Field` replace-the-whole-list footgun, the 450-character cap, and the
rules for scheduling parallel Claude sessions. Do not restate any of it here.

Run it **before** §1. A stale board schedules closed and superseded issues at full cost, and §1's
cluster is only meaningful once the ranking says this is the session that runs next.

**`pormg-board` is also a complete deliverable on its own.** If the request was "what should I pick
up next?", "update the board", or "plan the session", that skill answers it and **stops** — see its
§0. Continue into §1 below only when the user has asked to *work* an issue. Their agreeing with a
ranking is not that request.

## 1. Build the cluster

### The grouping key is the edit surface, not the label

**Group by file locality, not by topic.** What makes a session cheap is one worktree, one test slice
and one review — a property of *where the fix lands*, not of what the bug is about. Two issues that
sound related but live in different subsystems are two sessions; two that sound unrelated but both
land in `src/migrations/importers.jl` are one.

A shared label says nothing about whether two issues are co-solvable: `bug` alone spans the query
builder, migrations, the connection pool, the importers and docs. Area labels (`postgres`, `sqlite`,
`migrations`, `cjoin`, `performance`, `connection-pool`) are a cheap **prefilter**, not the grouping
key. Use them to narrow, then confirm against the code.

```bash
# 1. Prefilter by area label
gh issue list --state open --limit 100 --json number,title,labels \
  --jq '.[] | select([.labels[].name] | index("migrations")) | [.number, .title] | @tsv'

# 2. Pull the symbols and paths each candidate names
gh issue view <N> --json body --jq .body | grep -oE '(src|test)/[A-Za-z0-9/_.]+[.]jl' | sort -u

# 3. Confirm the overlap is real, in the code — not just in the titles
grep -rn "<symbol>" src/ --include=*.jl | cut -d: -f1 | sort | uniq -c | sort -rn
```

Step 3 is the one that decides. **Read the issue's own "Cause" section, not its title** — titles
cluster by symptom, causes cluster by file. Two issues that *sound* related but resolve to different
files are two sessions, not one.

### Admission tests

Every candidate must pass all four, or it does not join the group:

| Test | Fails when |
|---|---|
| **Contended edit** — a single PR touches the same file as another member | The overlap was in the titles, not the code |
| **One subsystem** — all members map to the same row of the architecture map in [`general.instructions.md`](../../instructions/general.instructions.md) | The group inherits an escalation trigger it does not need (§2) |
| **Independently landable** — each member is a complete fix, testable on its own | It is really one issue split in two; fix it as one, close the other as duplicate |
| **No open design question** — nothing in the group needs a decision the user has not made | That member stalls the whole branch mid-session |

**One more admission signal, specific to this repo: does the member's repro need a live database?**
The rule is in [`pormg-issue-management`](../pormg-issue-management/SKILL.md) → *Reproductions*, and
every bug issue states it near the top. A cluster of hermetic members verifies at rung 1 in seconds
and can run alongside another session; a single `db_2`-needing member makes the whole group queue on
the integration advisory lock ([`pormg-board`](../pormg-board/SKILL.md) §3). That does not disqualify
it — it changes what the group costs and whether it can be scheduled in parallel, so record it.

**Cap the group at 4 issues.** "One session" is bounded by context, not by ambition: a six-issue
group runs out of room halfway and lands a partial branch, which is strictly worse than two clean
sessions. The cap is this board's own observed ceiling, not an aspiration — across 27 sessions the
common size is **3**, and the one session that held four (Session 11: #444, #433, #431, #434) only
worked because two of those four closed as *superseded*, not fixed. Treat a proposed group of five as
evidence the overlap analysis was too loose. When more than four qualify, keep the four that score
highest on **overlap first, importance second** (§2) — tight overlap is what makes the group cheaper
than four separate sessions, so it outranks importance at selection time. Say which candidates you
left out and why.

### Third strike → a design issue, not a fourth patch

When the candidate you are grouping is the **third** to land in a cause-cluster that two merged fixes
already touched, stop scheduling patches. File (or find) the design issue that makes the cluster
unrepresentable, mark the open members superseded
([`pormg-issue-management`](../pormg-issue-management/SKILL.md) → *Superseding an open issue*), and
plan the design issue as the session.

Each patch in such a cluster is correct and local, and the cluster keeps reopening anyway, because
the cause is a representation rather than a branch. The evidence is the last two clusters: the
join/CTE namespace took **seven** PRs (#444 → #447 → #474 → #477 → #480 → #481 → #484/#486) before
the config map was split into typed namespaces, and relational column identity took three "converges
forever" fixes (#417 → #437 → #503) before #507 was filed. A design issue ranks by the sum of what it
supersedes ([`pormg-board`](../pormg-board/SKILL.md) §2).

### Confirm before starting

Present the proposed cluster to the user — the members, the shared file, the order, the derived tier,
whether it needs `db_2`, and anything you excluded. **A cluster is a scope proposal, so it needs the
user's agreement before implementation**, the same way a plan does. Do not expand a group
mid-session because a fifth issue "is right there".

### Record the agreed cluster on the board

Cluster identity is expensive to derive — steps 1–3 above — and worthless if it is recomputed from
scratch next session. Once the user agrees, persist it as a `Session` option on the
[project board](https://github.com/users/PingoLee/projects/7), named
`Session <N>: <Edit Surface>` after the code it contends for, never after the label its members
share. The existing names are the model: *QueryBuilder (#404 Fallout)*, *Importer Field-Key
Collisions*, *SQLite Parameter Alignment*.

The mechanics — resolving ids, the replace-the-whole-list footgun, the 450-character cap, and the
`RUN / TIER / FILES / ORDER / WHY` description grammar — are in
[`pormg-board`](../pormg-board/SKILL.md) §4. Stamp the new option the moment it exists; an option
with no `RUN nth` is a session nobody can place, and one with no `FILES:` cannot be scheduled
against a parallel session.

A member dropped under §4 loses its `Session` value and returns to the unassigned pool — leaving it
stamped implies work that did not happen.

## 2. Tier, then order

### Tier is the maximum over members, never the average

Run the escalation table in [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Pick the
tier* against every member and take the highest result. One member touching the `src/PormG.jl`
include chain puts the whole branch at `high`.

This is itself an argument for tight clusters: a docs issue riding along with a migrations issue
inherits a full integration run and a mandatory delta re-review it did not need. If a cheap member is
dragging cost onto itself, drop it and run it separately at `quick`.

### Order = dependency first (hard), importance second (tiebreak)

**Order decides what survives.** A cluster can end early — context runs out, a member stalls under
§4, review sends one back. Whatever landed first is what you keep, so ordering is a risk decision,
not a convenience.

Two rules, applied in this sequence:

1. **Dependency depth is a hard constraint** — the *forced* order. If one member rewrites a keying
   scheme and another adjusts a value that scheme computes, the rewrite goes first; otherwise you
   edit your own work twice. Receipts: *"#414 fixes the `fk_map` keying that #415's CTE rewrite
   builds on."* *"#449 first: `custom_join` is an unordered `Dict`, so any test for #448/#447 is
   hash-order dependent until it is fixed."* Importance never reorders across a real dependency.
2. **Importance breaks every remaining tie** — the *preferred* order. Among members with no
   dependency between them, the most important goes first, so an early abort keeps the fix that
   mattered most. Say it is preferred, so a future reader can reorder freely.

### The importance ladder

Score each member on the first rung it matches, highest wins:

| Rung | What | Why it ranks here |
|---|---|---|
| 1 | **Silent wrong data** — wrong rows, a misbound parameter, a dropped relation, a filter that quietly matches nothing | Ships. The user never learns to distrust the output |
| 2 | **Silent wrong schema** — a migration that converges forever, an identity column that reconciles wrong, a destructive plan that reads as additive | Same failure mode, against state you cannot re-derive |
| 3 | **Loud failure** — a throw, a `MethodError`, a visibly wrong error type | Bad, but self-announcing and diagnosable |
| 4 | **Performance, tech-debt, docs** | Real, but nothing is incorrect while it waits |

Rungs 1 and 2 outrank rung 3 on purpose, and it is the ordering most likely to feel wrong: a
`BoundsError` looks more urgent than a quietly-ignored keyword argument. It is not. A crash is
reported, reproduced, and fixed; a silent wrong answer ships — #432 found an integration test
*asserting* a parameter misbind as the expected vector, with comments documenting it as design.

**`priority:*` is severity in isolation, not blast radius**, and it does not override the ladder.
Overriding the label is normal — #430, #438, #442 and #460 all needed it — but state the override and
the reason in the same line.

**`pre-publish` is not on this ladder, and must not be added to it.** It is a *release-gating* label:
it answers "must this be settled before the first General-registry publish", which is a question
about scheduling, not about how much harm the defect does. Treat it exactly like `bug` or
`migrations`. The publish gate is real, but it applies to **which cluster you pick next**
([`pormg-board`](../pormg-board/SKILL.md) §2), not to the order *inside* one.

State the resulting order and the reason for it before the first commit. Where a dependency forced a
low-importance member to the front, say that explicitly — it is the one case where the branch's
riskiest work is not its most valuable.

## 3. Run the members

Work each member through [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Scope* and
*Implement*. **Provenance is per issue, not per group**: check the author of every member from
metadata before reading any body, and quarantine any non-maintainer one. A single third-party member
puts the group at `high` and needs its scope confirmed separately.

Isolate **once** for the whole group: one worktree, one branch, named for the cluster rather than a
single issue.

```bash
# from inside the worktree, after EnterWorktree
bash scripts/worktree_setup.sh
git branch -m fix/cluster-<subsystem>-<slug>
```

### Commit discipline — this is what makes the group reviewable

**One commit per issue, and one `UPGRADING.md` entry per issue that owes one.** Never a single
squashed "fix querybuilder bugs" commit.

- Each commit message references its own issue: `fix(querybuilder): <what> (#487)`.
- Each commit is self-contained — its code *and* its tests *and* its docs.
- A member that owes an upgrade entry gets its **own** entry prepended to `## Unreleased`, carrying
  its own concrete `before → after`. The [`UPGRADING.md`](../../../UPGRADING.md) contract is per
  behavior change, not per branch — merging two changes into one entry makes `upgrade_guide` describe
  a migration nobody can follow. Only a **breaking or behavior** change earns one; additive members
  get none, and no member ever bumps `Project.toml`.

This is the whole reason a 4-issue PR stays reviewable: it reads commit by commit, and any single
member can be reverted without unpicking the others.

### Verify: per-issue narrow, per-group broad

The efficiency win of clustering is paying the expensive rungs **once**. Split the rung table in
[`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Verify* accordingly:

| Rung | Scope | When |
|---|---|---|
| 1 — the new or changed test file alone | **Per issue** | Before that issue's commit |
| 2 — guard tests the change could trip | **Per issue** | Before that issue's commit |
| 3 — full unit suite | Per group | Once, after the last commit |
| 4 — integration slice (**ask first**) | Per group | Once, over the union of files the group's diff reaches |
| 5 — full integration suite | Per group | Once, if **any** member triggers it |

Rungs 1 and 2 stay per issue on purpose. A member committed without its own narrow run is a member
whose failure you will attribute to the next one.

**Rung 2 is the union across members**, not the intersection — a guard that only one member could
trip still has to run. So is rung 4's file list: the slice covers every file any member's diff
reaches, in one invocation, under one permission ask.

## 4. The abort rule

**A group is not a commitment to finish all of it.** If a member turns out to need a design decision,
a much larger change than the issue described, or an unrelated prerequisite:

1. **Stop that member.** Do not implement a half-fix to keep the group intact.
2. **Land the members already complete.** They are independently landable — that was an admission
   test — and ordered by importance, so the remainder is the cheapest part of the group to lose.
3. **Drop the rest back to the backlog**, with a comment recording what you found, via
   [`pormg-issue-management`](../pormg-issue-management/SKILL.md), and clear its board `Session`.
4. **Say so explicitly** in the report and the PR body: which members landed, which did not, why.

Holding a finished fix hostage to an unfinished sibling is the failure mode this rule exists to
prevent. A stale cluster branch decays against `main` far faster than a single-issue one.

## 5. Review, land, close out

Review per [`pormg-changed-code-review`](../pormg-changed-code-review/SKILL.md) at the group's tier.
Give the reviewer **the member list and the commit-per-issue structure**, and ask it to review the
diff commit by commit — a reviewer handed a 4-issue diff as one blob reviews none of them well.

Then land it without stopping: commit (one per member) → push → open the PR → report. The plan that
authorized the cluster authorized all of it; the merge gate in
[`general.instructions.md`](../../instructions/general.instructions.md) is the only stop, and it is
the maintainer's. A cluster makes the no-stopping rule matter more, not less — asking per member
would be four interruptions for one review. The integration-run ask is the exception that stays, and
at group scope it is **one** ask covering the whole slice.

**The PR body carries one `Closes #N` line per member**, plus the group's tier, the order you worked
in, which rungs CI is covering, and any member dropped under §4.

```
Closes #487
Closes #68
Closes #488
```

Close-out follows [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Close out*, with
three additions:

- **Verify every member actually closed.** A missing or malformed `Closes` line leaves a fixed issue
  open; worse, a member you dropped under §4 must **not** appear in that list. Check the final state
  of all N.
- **Reconcile the board.** The group's items go to `Done`; a dropped member loses its `Session`.
  Mark the option `DONE. #487, #68 - via PR #NNN.` per
  [`pormg-board`](../pormg-board/SKILL.md) §4.
- **Re-check the cluster.** Fixing three issues in a subsystem often makes a fourth trivial or
  obsolete — and if this was the third strike, the design issue is now the next session, not a fourth
  patch. Say so; file or close follow-ups via
  [`pormg-issue-management`](../pormg-issue-management/SKILL.md) rather than extending the branch.

## Anti-Patterns

- Do not plan on an unreconciled board — run [`pormg-board`](../pormg-board/SKILL.md) first
- Do not continue past §0 into a cluster unless the user asked to *work* an issue; agreeing with a
  ranking is a planning answer, not authorization
- Do not restate the board mechanics here — `pormg-board` owns them, in one copy
- Do not schedule a third patch into a cause-cluster two merged fixes already touched — file the
  design issue and supersede the members
- Do not group by shared label — `bug` is not an edit surface
- Do not group by topic when the fixes land in different files, or split issues that land in the
  same one
- Do not group across subsystems to "clear more backlog"
- Do not exceed four members, however well they overlap
- Do not average the tier across members, or let a cheap member argue the group down
- Do not let a docs-tier member ride a `high` branch — split it out and run it at `quick`
- Do not order by importance across a real dependency — the rewrite still goes first
- Do not rank a loud crash above a silent wrong answer because it looks more urgent
- Do not promote a member because it carries `pre-publish` — that is a release gate, not a severity
- Do not leave the ordering unstated, or the one case where a dependency demoted the important work
- Do not start implementing before the user has agreed to the cluster
- Do not add a fifth issue mid-session because it is adjacent
- Do not squash the group into one commit, or merge two members into one `UPGRADING.md` entry
- Do not skip a member's rung 1 and 2 because the group's full suite will run later
- Do not run the integration slice per member — one ask, one invocation, the union of the files
- Do not implement a half-fix to avoid breaking up the group
- Do not hold completed members back because a sibling stalled
- Do not hand a reviewer the whole group diff as one undifferentiated blob
- Do not put `Closes #N` on the PR for a member you dropped
