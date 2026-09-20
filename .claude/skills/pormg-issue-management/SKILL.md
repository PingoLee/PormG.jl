---
name: pormg-issue-management
description: Manage the PormG backlog with the gh CLI — create/update/close GitHub issues and curate labels. Covers the label taxonomy, the draft-before-create safety flow, and cross-reference discipline.
---

# PormG Issue Management

**Read [`.github/skills/pormg-issue-management/SKILL.md`](../../../.github/skills/pormg-issue-management/SKILL.md) now, and follow it.**
That file is the skill. This one is a discovery stub and carries none of its rules.

Claude Code only registers skills found under `.claude/skills/`, but PormG keeps its rulesets
in `.github/skills/` so that every agent tool reads the same copy (`AGENTS.md` -> *Tool notes*;
Copilot picks up the sibling `.github/instructions/` automatically). Before these stubs existed,
`Skill(pormg-issue-management)` failed with `Unknown skill` and the session continued without the ruleset --
which for a skill with a stop rule is worse than a loud failure.

The stub deliberately holds no rules of its own: a second copy would drift, and
`general.instructions.md` forbids keeping one. Only the frontmatter is duplicated, because
discovery needs it -- and `test/unit/test_skill_stubs.jl` fails if it stops matching, or if a
skill exists in one tree and not the other.
