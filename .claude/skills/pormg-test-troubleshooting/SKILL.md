---
name: pormg-test-troubleshooting
description: Diagnose and mitigate failing, flaky, or environment-dependent PormG tests (unit + integration, PostgreSQL + SQLite) — pool exhaustion, backend divergence, fixture isolation, aliasing bugs. Read when a test is red and the cause isn't an obvious code regression.
---

# PormG Test Troubleshooting

**Read [`.github/skills/pormg-test-troubleshooting/SKILL.md`](../../../.github/skills/pormg-test-troubleshooting/SKILL.md) now, and follow it.**
That file is the skill. This one is a discovery stub and carries none of its rules.

Claude Code only registers skills found under `.claude/skills/`, but PormG keeps its rulesets
in `.github/skills/` so that every agent tool reads the same copy (`AGENTS.md` -> *Tool notes*;
Copilot picks up the sibling `.github/instructions/` automatically). Before these stubs existed,
`Skill(pormg-test-troubleshooting)` failed with `Unknown skill` and the session continued without the ruleset --
which for a skill with a stop rule is worse than a loud failure.

The stub deliberately holds no rules of its own: a second copy would drift, and
`general.instructions.md` forbids keeping one. Only the frontmatter is duplicated, because
discovery needs it -- and `test/unit/test_skill_stubs.jl` fails if it stops matching, or if a
skill exists in one tree and not the other.
