---
name: pormg-usage
description: Answer PormG usage questions and write consumer-style examples for model definitions, @import_models, migration flow, fluent queries, joins, F/Q/Qor expressions, aggregations, and bulk operations.
---

# PormG.jl — AI Usage Guide

**Read [`.github/skills/pormg-usage/SKILL.md`](../../../.github/skills/pormg-usage/SKILL.md) now, and follow it.**
That file is the skill. This one is a discovery stub and carries none of its rules.

Claude Code only registers skills found under `.claude/skills/`, but PormG keeps its rulesets
in `.github/skills/` so that every agent tool reads the same copy (`AGENTS.md` -> *Tool notes*;
Copilot picks up the sibling `.github/instructions/` automatically). Before these stubs existed,
`Skill(pormg-usage)` failed with `Unknown skill` and the session continued without the ruleset --
which for a skill with a stop rule is worse than a loud failure.

The stub deliberately holds no rules of its own: a second copy would drift, and
`general.instructions.md` forbids keeping one. Only the frontmatter is duplicated, because
discovery needs it -- and `test/unit/test_skill_stubs.jl` fails if it stops matching, or if a
skill exists in one tree and not the other.
