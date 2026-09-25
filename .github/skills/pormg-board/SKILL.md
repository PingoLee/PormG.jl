---
name: pormg-board
description: Reconcile the PormG project board against GitHub Issues, rank the sessions, and write the plan back so the next session does not recompute it. Answers "what should I pick up next?" and stops there — planning only, no implementation. Records each session's edit surface so parallel Claude sessions can be scheduled safely.
---

# PormG Board

## Purpose

The [PormG project board](https://github.com/users/PingoLee/projects/7) — *"PormG Bug Resolution &
Work Sessions"* — is where the *plan* lives. The **backlog** is GitHub Issues
([`pormg-issue-management`](../pormg-issue-management/SKILL.md)); the board is the derived view that
says what runs next, in what order, and why.

This skill owns that view end to end: reconcile it against the issues, rank the sessions, and write
the ranking back. It is the planning layer *underneath*
[`pormg-issue-cluster`](../pormg-issue-cluster/SKILL.md) — that skill builds and works a cluster and
links here rather than restating any of this.

The *rationale* behind the steps lives in [`reference.md`](reference.md) — each step points at the
section to open when you reach it. Most invocations are "what should I pick up next?" and never reach
§4, so the write-back footguns are not paid for on every run. **Every query below is projected
through `--jq` on purpose:** the raw GraphQL responses are deeply nested and an unprojected read is
the single largest cost in this skill.

## Use This Skill For

- **"What should I pick up next?"** — the most common reason to be here
- Reconciling the board after a batch of new issues (every session spawns 2–3 follow-ups, so this
  happens constantly)
- Recording an agreed cluster, its rank, and its edit surface
- Working out which sessions can run in **parallel Claude sessions**
- Any "update the board", "plan the session", "give me the implementation order" request

Not for: filing, labelling, or closing issues ([`pormg-issue-management`](../pormg-issue-management/SKILL.md));
implementing anything at all (see the stop rule immediately below).

## 0. This skill is a deliverable — stop when the board is written

**Reconciling and ranking is a complete unit of work. Do not continue into implementation.**

Report the ranking, write it back, stop. "What should I pick up next?", "update the board", "plan
the session" are answered *entirely* by this skill.

**A user choosing which work ranks first is answering a planning question. It is not authorization to
implement it.** Neither is approving a ranking, agreeing with a recommendation, or picking an option
from a list of candidate sessions.

**What "stop" forbids, concretely.** While in this skill, do not: create a branch, call
`EnterWorktree`, edit anything under `src/`, `test/`, `docs/`, or `ext/`, run any test suite, commit,
push, or open a PR. **And do not delegate any of it** — spawning a subagent, a worktree, or a
parallel session to do the work is doing the work. §3 is about *scheduling* parallel sessions, never
about launching them.

Reading is allowed, and bounded: enough to reconcile, rank, and fill in `FILES:` for a session.
`FILES:` is normally *recorded from an already-agreed cluster*, not derived from scratch — if you
find yourself opening `build_row_join_sql_text` to size a fix, you have left planning. Say what you
would need to look at, and stop.

Work begins when the user asks for it. Offer it as its own question, in those words — "shall I start
work on X?" — after the board is written; a yes to *that* is the authorization. Nothing else is.

If the ranking makes the next step obvious, say what it is and offer it. Do not take it. Hand off to
[`pormg-issue-cluster`](../pormg-issue-cluster/SKILL.md) for a multi-issue session or
[`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) for a single issue. Note what that
hand-off costs: under the merge gate in
[`general.instructions.md`](../../instructions/general.instructions.md), once the user says yes that
workflow runs to an open PR without stopping again — so the yes you collect here is the last one
before a branch exists.

## 1. Reconcile

### Reconciliation is one-way

The board holds a *plan*, so it may say things the issues do not — that #421 and #423 belong
together, that Session 8 runs third. It may **not** disagree with the issues about **facts**: whether
an issue is open, closed, labelled, or superseded.

**On any question of fact, GitHub Issues are the source of truth and the board is corrected — never
the reverse.** Never `gh issue close`, reopen, or relabel to make an issue agree with a board cell.

That boundary is what keeps this a planning tool rather than the backlog mirror
[`pormg-issue-management`](../pormg-issue-management/SKILL.md) → **Do Not** forbids. Cross it and you
have a second index that drifts, and it drifts fast: #400, #402 and #410 all sat at `In Progress`
after they were merged and closed. Both times the issues were right.

Always reconcile before planning; a stale board schedules closed and superseded issues at full cost.

```bash
gh api graphql --paginate -f query='query($endCursor: String) { user(login:"PingoLee"){ projectV2(number:7){
  items(first:100, after:$endCursor){ pageInfo{ hasNextPage endCursor }
    nodes{ id content{ ... on Issue { number state } }
    fieldValues(first:12){ nodes{ ... on ProjectV2ItemFieldSingleSelectValue {
      name field{ ... on ProjectV2SingleSelectField { name } } } } } } } } } }' \
  --jq '.data.user.projectV2.items.nodes[] | [
      .id,
      (.content.number // "-"),
      (.content.state  // "-"),
      ([.fieldValues.nodes[] | select(.field.name == "Status")  | .name] | first // "NO-STATUS"),
      ([.fieldValues.nodes[] | select(.field.name == "Session") | .name] | first // "NO-SESSION")
    ] | @tsv'
```

One line per item: `<item-id> <issue#> <state> <status> <session>`. **Never run this unprojected** —
the raw response is every item (180 on 2026-09-24) × its nested field values and it is the most
expensive read in the skill, for information that fits in five columns. `NO-SESSION` is not padding;
it is a count the sweep below actually cares about.

**Never drop `--paginate` or shrink it back to one page (#625).** GitHub returns at most 100 items
per page and says nothing when it truncates: 99 rows look exactly like "the first 99 of 180". Items
come back in the board's position order, which on this board is insertion order, so a single page
silently drops the **newest** items — the ones a planning pass is about. This recipe was
`items(first:99)` until the board had grown to 180 and 81 items were invisible to both queries in
this section. `--paginate` drives the `$endCursor` loop and runs `--jq` once per page, so the
projection is unchanged. Every piece of the loop is load-bearing: gh follows the **first**
`pageInfo` in the response, so it must be `items`' own, ahead of `nodes`, and carry `hasNextPage` —
drop either, or use `last:`, and gh stops after the first page exactly as before (each measured at
100 of 180 rows). `test/unit/test_skill_graphql_pagination.jl`
fails on any `gh api graphql` recipe under `.github/` that asks for `items` (or `issues` /
`pullRequests`) without the full cursor loop.

The nested `fieldValues(first:12)` here and `fields(first:20)` in §4 stay single-page on purpose:
they are bounded by the board's schema, not by how much work has been filed. On 2026-09-24 an item
carried at most 5 field values (7 to spare). The project had 14 fields, with **Session 14th** in
the `fields` order, so it drops off `fields(first:20)` only if seven or more fields come to be
ordered ahead of it. Re-measure before adding fields.

Then, for every item:

| Issue state | Board Status | Action |
|---|---|---|
| `CLOSED` | not `Done` | set `Done` |
| `OPEN` | `Done` | clear it — the issue was reopened, or the wrong item was marked |
| `OPEN` | `In Progress` you did not set | **leave it.** Another session is working it. A status you did not write is a signal, not an error |
| `OPEN`, superseded — see [`pormg-issue-management`](../pormg-issue-management/SKILL.md) → *Superseding an open issue* | on any session | take it off the session — a superseded issue is not work; it closes when the superseding change lands |

**An `In Progress` with no branch, PR, or worktree behind it is stale, not live.** Check before
leaving it alone — `git worktree list`, `gh pr list --state open`, and the issue's own assignees. Say
what you found and let the user decide; do not silently clear a marker another session may own.

### The membership sweep — run it bare, not by label

One self-contained command — it prints every open issue that is on no board item, and nothing when
the board is complete:

```bash
comm -23 \
  <(gh issue list --state open --limit 200 --json number -q '.[].number' | sort -u) \
  <(gh api graphql --paginate -f query='query($endCursor: String) { user(login:"PingoLee"){ projectV2(number:7){
        items(first:100, after:$endCursor){ pageInfo{ hasNextPage endCursor } nodes{ content{ ... on Issue { number } } } } } } }' \
      --jq '.data.user.projectV2.items.nodes[] | .content.number // empty' | sort -u) \
  | sort -n
```

(Keep it in one shell invocation. Splitting it across a temp file works only if both halves run in
the *same* shell — a path written from bash is not the path a Windows tool resolves.)

Both halves must see **every** row, or `comm` turns the gap into invented work: an on-board issue past
a truncated board page shows up here as "on no board item", and the `item-edit` that follows
overwrites a Session and Status another session owns (#625). The board half paginates for that
reason. The issue half's `--limit 200` is the same kind of cap — 30 open issues on 2026-09-24, so
it holds, but raise it before the open count approaches it rather than after.

**Every open issue belongs on the board.** An issue filed during a session — including follow-ups
this session just filed — is invisible to the next planning pass until it is added.

**Do not filter that sweep by `--label bug`.** It was written that way and it hid the problem it
existed to find: a reconcile on 2026-09-13 found **30 of 48 open issues on no board item at all**,
because a label filter cannot see an unlabelled issue and nobody ran the bare cross-check. Why the
membership number is the one that says whether the board is usable: [`reference.md`](reference.md) §B.

**Membership is not the whole sweep — also count the open items whose `Session` is empty.** They are
as invisible to §2 as an issue never added: nothing ranks them. The projection above already carries
it, so it is one `grep`, not a second query:

```bash
# ... | grep -c 'NO-SESSION'
```

## 2. Rank the sessions

Group display order on the board is option order, which is numeric (Session 5, 6, 7…). Execution
order is not, and neither the field nor the item ordering can say "run Session 19 before Session 10"
— so rank explicitly, in descending priority:

1. **Breaking changes, while the repo is pre-publish.** Cheapest now; every session built on the old
   shape raises the cost. A session that changes a public signature or a field contract outranks one
   that does not. #444 ranked first on this alone.
2. **The publish gate.** `gh issue list --state open --label pre-publish` — empty is the gate. Its
   size is a scheduling input: one issue from empty is worth finishing. This is the one place the
   label ranks anything; *inside* a session it is a classification, never a promotion.
3. **The importance ladder's top rung across members** (see
   [`pormg-issue-cluster`](../pormg-issue-cluster/SKILL.md) → *The importance ladder*, which owns
   it): a session holding a rung-1 or rung-2 member — silent wrong data, a misbound parameter, a
   dropped relation — outranks one whose members are all loud failures, performance, or docs.
4. **Leverage** — a session that taxes every other session. #430 is `priority:low` and blocked anyone
   touching the importers; #438 was `priority:medium` and broke `/pormg-cut-release`'s own tooling.
   A test-harness or fixture fix every session trips over ranks above its own severity.

**`priority:*` is severity in isolation, not blast radius.** Overriding it is normal — #430, #438,
#442 and #460 all needed it. State the override and the reason in the same line; an unexplained
override reads as an error.

**Say when you override the order itself.** The list above is descending priority, not a formula:
criterion 1 is an argument about *cost*, and a live rung-1 defect is an argument about *harm*. Those
can point opposite ways. Resolving it either way is fine; leaving the tension unstated is not.

## 3. Parallel sessions

Two Claude sessions can work the board at once — the user does this routinely. The board is what
makes it safe, because it records each session's **edit surface**.

**Disjoint `FILES:` is the first gate, and it is necessary but NOT sufficient.** Record the surface
per session (§4) and derive the gate from it — never store a pairwise conflict matrix, which is
O(n²) to maintain and silently goes stale the moment a session is added.

Three constraints survive filesystem isolation, so clear all of them before calling two sessions
parallel-safe:

| Constraint | What it means for scheduling |
|---|---|
| **`db_2` verification serializes** | `common_setup.jl` takes a PostgreSQL session-level advisory lock, so a second session against `db_2` *queues* rather than interleaving. That is correctness, not throughput: two `db_2`-needing sessions are sequential however disjoint their files |
| **Hermetic beats labelled** | A session whose members all reproduce on mock connections contends for nothing and can run alongside anything. One that needs `db_2` queues behind every other `db_2` session each time it verifies — [`pormg-issue-management`](../pormg-issue-management/SKILL.md) → *Reproductions* is where each issue records it. `db_sl` is per-worktree and cheap |
| **Uncommitted work is invisible** | `git log` and `git diff main...<branch>` do not show it — check what is in flight per [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Isolate* |

A repro that is *hostile* rather than merely hungry — `pg_terminate_backend`, a server restart, a
schema drop — cannot be scheduled in parallel with anything at all. Mark that session `SOLO` in its
description. The evidence behind each constraint, and why a per-session surface beats a conflict
matrix: [`reference.md`](reference.md) §F.

## 4. Write it back

**Authentication.** Board writes need the `project` scope, which the default token does not carry:

```bash
gh auth status                 # look for 'project' in Token scopes
gh auth refresh -s project     # interactive browser flow — the USER runs this, not you
```

**Discover the IDs — never hardcode them.** Project, field, and option IDs are opaque and change
with the board. Resolve them every run, and read only what you need to think with:

```bash
gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:7){ id
  fields(first:20){ nodes{ ... on ProjectV2SingleSelectField { id name options{ id name color description } } } } } } }' \
  --jq '.data.user.projectV2 | [ "PROJECT", .id ], (.fields.nodes[] | select(.name) | [ "FIELD", .name, .id ]) | @tsv'
```

Swap the `--jq` for the line below to list the Session options with their ids **and** the length the
cap needs, without a single description entering context:

```
.data.user.projectV2.fields.nodes[] | select(.name=="Session") | .options[] | [ .id, .name, (.description|length) ] | @tsv
```

You want the project `id`, the **Status** field (options `Todo` / `In Progress` / `Done`) and the
**Session** field with its full option list.

**`updateProjectV2Field` replaces the entire option list — it does not append.** Sending only the new
option deletes every existing one and orphans every item grouped under them — 17 options and 30 items
on 2026-09-24. The rule: resend every existing option **with its `id`, `color`, and
`description`**, then append the new one without an `id`. Full reasoning, including why a rename
needs the id: [`reference.md`](reference.md) §C.

**Build the payload in one call, never by retyping.** `gh api --jq` transforms the response on the
way to the file, so the twenty-eight unchanged descriptions are carried forward byte-for-byte and
none of them enters the transcript. **Use `gh api --jq`, not standalone `jq`** — `jq` is not
installed on this machine, and `gh`'s embedded engine covers everything this recipe needs.

`gh --jq` has no `--arg`, so pass the two variable parts through the environment and read them as
`env.NAME`. That also sidesteps every shell-quoting hazard in a description:

```bash
export BOARD_TARGET='Session 21: QueryBuilder Join Rows'
export BOARD_DESC='RUN 1st | TIER standard | READY. FILES: ... ORDER: ... WHY: ...'

printf '%s' "$BOARD_DESC" | wc -c          # guard 1: the new description must be <= 450

gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:7){ id
  fields(first:20){ nodes{ ... on ProjectV2SingleSelectField { id name options{ id name color description } } } } } } }' \
  --jq '{ query: "mutation($fid:ID!,$opts:[ProjectV2SingleSelectFieldOptionInput!]!){ updateProjectV2Field(input:{fieldId:$fid,singleSelectOptions:$opts}){ projectV2Field{ ... on ProjectV2SingleSelectField { options{ id name } } } } }",
      variables: {
        fid: (.data.user.projectV2.fields.nodes[] | select(.name=="Session") | .id),
        opts: [ .data.user.projectV2.fields.nodes[] | select(.name=="Session") | .options[]
                | {id, name, color, description}
                | if .name == env.BOARD_TARGET then .description = env.BOARD_DESC else . end ] } }' \
  > .claude/worktrees/payload.json          # gitignored scratch

gh api graphql --input .claude/worktrees/payload.json    # -f cannot express a list of objects
```

**Guard 2 — an option that is *already* over the cap fails your batch too.** Run this before
submitting; empty output is the pass:

```
.data.user.projectV2.fields.nodes[] | select(.name=="Session") | .options[] | select((.description|length) > 450) | [.name, (.description|length)] | @tsv
```

To **add** an option instead of editing one, append `+ [{name: env.BOARD_NEW, color: "GRAY", description: env.BOARD_DESC}]`
to `opts` — no `id` on the new entry, ids intact on every old one. Verify the response lists every
pre-existing option with its **original id** before moving on.

Re-ranking is the common case and it is the expensive one, because `RUN nth` lives inside a string
that is otherwise stable. The recipe above makes that cheap; the structural fix, and why it has not
been done, is [`reference.md`](reference.md) §E.

**Adding and stamping items.** `gh project item-add 7 --owner PingoLee --url <issue-url>` adds an
issue; then one `gh project item-edit` per field — Session and Status:

```bash
gh project item-edit --id <item-id> --project-id <project-id> \
  --field-id <field-id> --single-select-option-id <option-id>
gh project item-edit --id <item-id> --project-id <project-id> --field-id <field-id> --clear
```

Add issues **in the order you want them displayed** — row order is insertion order. To place one
between two existing rows, use `updateProjectV2ItemPosition` with `afterId`.

### The description grammar

The board cannot express rank, tier, or edit surface any other way, so each Session option's
description carries all three in a fixed shape. It surfaces on hover, so it has to stay scannable.

**Write it as one line of plain ASCII** — that is what the field actually renders, and it keeps the
length countable (see the cap below). Use `--`, not an em-dash, and `->`, not an arrow glyph:

```
RUN 2nd | TIER standard | READY. FILES: src/querybuilder/join.jl, src/Dialect.jl,
test/unit/test_join_rows.jl. ORDER: #487 -> #68 -> #488 (FORCED: #487 retypes the JoinDict key
that #68 reads). WHY: rung 2 + LEVERAGE -- JoinDict's string flattening taxes every join session
below it.
```

(Wrapped here for reading only; the stored value is a single line.)

- **`RUN nth`** — execution rank. Restamp **every** description when the ranking changes; a stale
  `RUN 1st` is worse than none.
- **`TIER`** — `quick` / `standard` / `high` from
  [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Pick the tier*, so the cost is
  visible before anyone opens the issues.
- **State** — `READY`, `IN PROGRESS`, `BLOCKED BY #N`, `NOT STARTABLE` (an open design question),
  `SOLO` (a hostile repro, §3), or `DONE`.
- **`FILES:`** — the edit surface. This is the parallel-safety key (§3); a session without it cannot
  be scheduled against another.
- **`ORDER:`** — member sequence, with *forced* (reversing it costs rework) vs *preferred* (a
  severity or warm-up tiebreak) named explicitly.
- **`WHY:`** — why this rank. The one line that stops the next session re-deriving it.

**Descriptions are capped at ~450, and one long one fails *every* option in the batch.** The two
guards above are the check — run them before submitting, not after the error. `Session 19` currently sits
at exactly 450, so the next edit that touches it has no headroom at all. Whether the API counts
characters or bytes is unconfirmed, which is the real reason the grammar is ASCII:
[`reference.md`](reference.md) §D.

Mark finished groups `DONE. #421, #424, #423 - via PR #436, #440.` rather than deleting them — which
issues shipped together, through which PR, is what makes the next grouping decision easier.

**The board records decisions, not speculation.** An option per agreed cluster; nothing for a
grouping you merely considered — and never an option with an empty description
([`reference.md`](reference.md) §G).

## 5. What to hand back

The board is the durable artifact; the table in the conversation is what the user reads. Write the
board back, then report **one ranked table, one row per session** — the question behind every
invocation is "what can I work in one sitting?", and a session is the unit that answers it.

| # | Issues (one session) | Session | Tier | Start now? |
|---|---|---|---|---|
| 1 | #531 → #532 → #522 | Introspection to IR (Phase 3) | high | Yes |
| 5 | #487 → #68 → #488 | QueryBuilder Join Rows | standard | After #531 lands the IR shape |

`→` is a forced order inside the session; a comma means any order. **`Start now?` carries the
blocker, never a bare yes/no.** Below the table add only what it cannot: which rows have disjoint edit
surfaces and which need `db_2` (§3), and any ranking tension you resolved (§2).

**Do not dump the board, and do not render a second copy of it.** The `FILES:`/`ORDER:`/`WHY:`
descriptions are written for the next session to read off the board, which already has a URL — and
with the §4 recipe they never enter the transcript in the first place, so echoing them back means
fetching them on purpose to do it. Receipt: [`reference.md`](reference.md) §G.

## Anti-Patterns

- **Do not implement anything from this skill** — §0 is the whole point
- Do not treat a user's answer about ranking, or their agreement with a recommendation, as
  authorization to start the work
- Do not plan on an unreconciled board — closed and superseded issues get scheduled at full cost
- Do not change an issue to agree with the board; the board is the derived view, always
- Do not overwrite an `In Progress` you did not set — but do check whether it is stale, and say so
- Do not run the membership sweep through a label filter — it cannot see an unlabelled issue, and
  that is how 30 of 48 open issues ended up off the board
- Do not stop the sweep at board membership — an open item with an empty `Session` is unschedulable
  in exactly the same way
- Do not read the board unprojected — `--jq` every query
- Do not call `updateProjectV2Field` without resending every existing option **with its id** — it
  replaces the list, and the items grouped under the dropped options are orphaned
- Do not hardcode project, field, or option ids into a script or a note — resolve them per run
- Do not exceed 450 characters in a description; the whole mutation fails, not just that option —
  and run both guards, since an option that was already over the cap fails your batch as well
- Do not reach for standalone `jq`; it is not installed — `gh api --jq` does the whole recipe
- Do not leave a `RUN nth` description stale after a re-rank
- Do not omit `FILES:` — a session without an edit surface cannot be scheduled in parallel
- Do not store a pairwise parallel-conflict matrix; record each session's files and derive it
- Do not promise two `db_2` sessions can verify in parallel — the advisory lock queues them
- Do not treat `priority:*` as the ranking — it is severity in isolation; override it and say why
- Do not rank a loud crash above a silent wrong answer because it looks more urgent
- Do not promote a session because a member carries `pre-publish` — that is a release gate, not a
  severity
- Do not leave an override of the ranking order unstated
- Do not report the board by echoing every option's description, or by rendering a second copy of it
  — §5's one-row-per-session table is the deliverable, and `Start now?` needs the blocker, not a bare
  yes/no
- Do not commit board-planning changes onto an unrelated feature branch
