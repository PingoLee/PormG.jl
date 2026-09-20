---
name: pormg-board
description: Reconcile the PormG project board against GitHub Issues, rank the sessions, and write the plan back so the next session does not recompute it. Answers "what should I pick up next?" and stops there — planning only, no implementation. Records each session's edit surface so parallel Claude sessions can be scheduled safely.
---

# PormG Board

**Read [`.github/skills/pormg-board/SKILL.md`](../../../.github/skills/pormg-board/SKILL.md) now, and follow it.**
That file is the skill. This one is a discovery stub and carries none of its rules.

Claude Code only registers skills found under `.claude/skills/`, but PormG keeps its rulesets
in `.github/skills/` so that every agent tool reads the same copy (`AGENTS.md` -> *Tool notes*;
Copilot picks up the sibling `.github/instructions/` automatically). Before these stubs existed,
`Skill(pormg-board)` failed with `Unknown skill` and the session continued without the ruleset --
which for a skill with a stop rule is worse than a loud failure.

The stub deliberately holds no rules of its own: a second copy would drift, and
`general.instructions.md` forbids keeping one. Only the frontmatter is duplicated, because
discovery needs it -- and `test/unit/test_skill_stubs.jl` fails if it stops matching, or if a
skill exists in one tree and not the other.
