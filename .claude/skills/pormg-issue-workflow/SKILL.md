---
name: pormg-issue-workflow
description: Work a GitHub issue end-to-end at a chosen effort tier — check provenance, scope it, pick quick/standard/high from the escalation table, isolate it, implement, verify in the rungs that tier calls for, review it, land it through commit → push → PR without stopping, and clean up. Plan approval authorizes the whole run; the merge is the maintainer's. The orchestration layer above the subsystem skills.
---

# PormG Issue Workflow

**Read [`.github/skills/pormg-issue-workflow/SKILL.md`](../../../.github/skills/pormg-issue-workflow/SKILL.md) now, and follow it.**
That file is the skill. This one is a discovery stub and carries none of its rules.

Claude Code only registers skills found under `.claude/skills/`, but PormG keeps its rulesets
in `.github/skills/` so that every agent tool reads the same copy (`AGENTS.md` -> *Tool notes*;
Copilot picks up the sibling `.github/instructions/` automatically). Before these stubs existed,
`Skill(pormg-issue-workflow)` failed with `Unknown skill` and the session continued without the ruleset --
which for a skill with a stop rule is worse than a loud failure.

The stub deliberately holds no rules of its own: a second copy would drift, and
`general.instructions.md` forbids keeping one. Only the frontmatter is duplicated, because
discovery needs it -- and `test/unit/test_skill_stubs.jl` fails if it stops matching, or if a
skill exists in one tree and not the other.
