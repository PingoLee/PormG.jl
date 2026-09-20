---
name: pormg-issue-cluster
description: Work several issues as one group — build a cluster from contended files rather than shared labels, tier it by its worst member, order it by dependency then importance, land one commit and one UPGRADING entry per issue, and close out N issues at once. Sits above pormg-issue-workflow; run pormg-board first to decide which cluster is next.
---

# PormG Issue Cluster

**Read [`.github/skills/pormg-issue-cluster/SKILL.md`](../../../.github/skills/pormg-issue-cluster/SKILL.md) now, and follow it.**
That file is the skill. This one is a discovery stub and carries none of its rules.

Claude Code only registers skills found under `.claude/skills/`, but PormG keeps its rulesets
in `.github/skills/` so that every agent tool reads the same copy (`AGENTS.md` -> *Tool notes*;
Copilot picks up the sibling `.github/instructions/` automatically). Before these stubs existed,
`Skill(pormg-issue-cluster)` failed with `Unknown skill` and the session continued without the ruleset --
which for a skill with a stop rule is worse than a loud failure.

The stub deliberately holds no rules of its own: a second copy would drift, and
`general.instructions.md` forbids keeping one. Only the frontmatter is duplicated, because
discovery needs it -- and `test/unit/test_skill_stubs.jl` fails if it stops matching, or if a
skill exists in one tree and not the other.
