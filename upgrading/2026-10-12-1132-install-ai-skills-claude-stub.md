## `install_ai_skills()` also writes a Claude Code discovery stub, and returns its path as `stub` (#1132)

- **Version**: Unreleased
- **PormG ref**: #1132 ; `src/tools.jl` (`install_ai_skills`, `_write_claude_stub`)
- **Recorded**: 2026-10-12
- **Severity**: behavior. `install_ai_skills()` now writes `.claude/skills/pormg-usage/SKILL.md` as well as `.github/skills/pormg-usage/`, and its named tuple gains a `stub` field.

### What changed

Claude Code registers a skill only from `.claude/skills/<name>/SKILL.md`. The installer wrote the
bundle to `.github/skills/pormg-usage/` alone, so in a consuming project `/pormg-usage` was an unknown
skill and Claude Code reached the bundle only if an instruction file pointed at it.

The installer now also writes a short stub at `.claude/skills/pormg-usage/SKILL.md`: the bundle's
front-matter and a link to the bundle's `SKILL.md`. It overwrites the stub on every run, as it does
the bundle. If any step of that path is a link (`.claude`, `.claude/skills`, the skill directory or
the file), no stub is written and a warning is logged: a skills tree shared between tools resolves
that path to the bundle's own `SKILL.md`.

| call | before | after |
|---|---|---|
| `PormG.install_ai_skills()` | writes `.github/skills/pormg-usage/` only | also writes `.claude/skills/pormg-usage/SKILL.md` (creating `.claude/` if needed) |
| its return value | `(; installed_dir, written, stale, referenced_in)` | `(; installed_dir, written, stale, referenced_in, stub)`, with `stub` the stub's path or `nothing` |

`written` still lists only the bundle's file names.

### Who this affects

- Projects that run `install_ai_skills()` and do not use Claude Code: a `.claude/skills/pormg-usage/`
  directory appears. Commit it, ignore it, or delete it; it is the only file written outside the
  bundle.
- Projects that keep their own `.claude/skills/pormg-usage/SKILL.md`: it is overwritten on the next
  run. Keep your notes in another skill, or make that path a link, which the installer does not
  write through.
- Code that destructures the returned tuple by position. Fields read by name are unchanged.

### How to find the calls to migrate

```bash
grep -rn 'install_ai_skills' --include=*.jl .
```

### Migrate your app

Nothing to change for a call that reads fields by name. Commit the new stub with the bundle so that
Claude Code finds `/pormg-usage` for everyone working in the repository.
