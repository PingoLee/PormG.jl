---
name: pormg-usage
description: Answer PormG usage questions and write consumer-style code — model definitions, @import_models, migrations, fluent queries, joins, F/Q/Qor, aggregations, SQL functions, subqueries/CTEs, window functions, writes and bulk operations, transactions, async, and PormGError handling.
---

# PormG.jl — AI Usage Guide

**Read [`.github/skills/pormg-usage/SKILL.md`](../../../.github/skills/pormg-usage/SKILL.md) now, and follow it.**
That file is the skill. This one is a discovery stub and carries none of its rules.

Claude Code only registers skills found under `.claude/skills/`, but the canonical copy lives in
`.github/skills/` because `install_ai_skills()` ships that tree into consuming projects. Before this
stub existed, `Skill(pormg-usage)` failed with `Unknown skill` and the session continued without the
ruleset -- which for a skill with a stop rule is worse than a loud failure.

The stub deliberately holds no rules of its own: a second copy would drift. Only the frontmatter is
duplicated, because discovery needs it -- and `test/unit/test_skill_stubs.jl` fails if it stops
matching, if the stub grows past a size ceiling, or if a skill exists in one tree and not the other.
