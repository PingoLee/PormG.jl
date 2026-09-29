## AI skill bundle restructured — re-run `install_ai_skills()` after bumping, delete the stale files (#253, #689)

- **Version**: 0.7.0
- **Recorded**: 2026-09-29
- **PormG ref**: #253 (PR #690), #689; `.github/skills/pormg-usage/`, `src/tools.jl` (`install_ai_skills`)
- **Severity**: behavior change (tooling only) — no runtime API changed. The file layout of the
  `pormg-usage` bundle an app vendors under `.github/skills/` did, and the installer does not
  clean up after the old one.

### What changed

`install_ai_skills()` copies PormG's `pormg-usage` skill into
`<app>/.github/skills/pormg-usage/`, where an AI coding assistant reads it. The bundle an app
installed before this change is one long guide: `SKILL.md` with eleven numbered sections, plus
`reference.md` (field types) and `writing.md`. It is now a short router plus one file per topic:

| Old location | New location |
|---|---|
| `SKILL.md` §1 *Project Setup*, §2 *Defining Models*; `reference.md` (*Field Types Reference*) | `models.md` |
| `SKILL.md` §3 *Reading Data — Query Patterns*, §4 *Joins and Lookups*, §5 *Complex Filters: Q Objects*, §6 *F-Expressions*, §7 *Aggregations* | `reading.md` |
| `SKILL.md` *Writing & Mutating Data*; `writing.md` | `writing.md` |
| `SKILL.md` §8 *Query Inspection & Debugging* | `debugging.md` |
| `SKILL.md` §9 *Multi-Database & Multi-Tenancy* | `advanced.md` |
| `SKILL.md` §10 *Aliases & Error Types* | `errors.md` |
| `SKILL.md` §11 *Anti-Patterns* | `SKILL.md` → *Anti-patterns* |
| — | `async.md` (new) |

Three consequences for an app that vendors the bundle:

1. **`reference.md` survives the refresh.** The installer overwrites the files it ships and never
   deletes one, so the old `reference.md` stays beside `models.md` and an assistant browsing the
   directory still reads its outdated content.
2. **Links into the old `SKILL.md` dangle.** Its numbered sections are gone, so an app's own
   skills or `AGENTS.md` linking `pormg-usage/SKILL.md#5-complex-filters-q-objects`,
   `…#8-query-inspection--debugging` and the like now land on the router's top.
3. **A hand-edited bundle file is overwritten.** The installer copies with `force = true`, as it
   always has. Before, a refresh left most of `SKILL.md` as it was and a local addition stood out
   in the diff; now the whole file is replaced by a different one, so a local addition is easy to
   lose in it. The same holds for `writing.md`, and for `reference.md` once you delete it.

`install_ai_skills()` itself now reports what it finds instead of claiming success. It returns
`(; installed_dir, written, stale, referenced_in)` on success, where it used to return
`nothing`, lists the files already in the directory that this PormG version does not ship
(`stale`) without deleting them, and prints a one-line pointer to add when no `AGENTS.md`,
`CLAUDE.md`, `.github/copilot-instructions.md` or `.github/instructions/*.md` mentions
`pormg-usage`. It takes an `io` keyword for that report.

### How to find the calls to migrate

From the app root:

```bash
ls .github/skills/pormg-usage/                                 # reference.md present → old bundle
grep -rn 'pormg-usage/SKILL.md#' --include='*.md' .            # anchors into the old sections
grep -rn 'pormg-usage/reference.md' --include='*.md' .         # links to the renamed file
grep -ls pormg-usage AGENTS.md CLAUDE.md .github/copilot-instructions.md .github/instructions/*.md
```

The last line printing nothing means no instruction file points an assistant at the bundle; the
installer will print the line to add. A project that never installed the bundle has nothing to
migrate and runs the installer once.

To find **local edits** worth keeping, compare the vendored files with the copies PormG shipped at
your old pin: the tag of the pinned version (`v0.6.0` here), or the `rev` under `[sources]` if
the app pins one. The app's own `git log` cannot tell you this — every earlier installer run is a
commit on those paths too:

```bash
for f in SKILL.md reference.md writing.md; do
  curl -fsS "https://raw.githubusercontent.com/PingoLee/PormG.jl/v0.6.0/.github/skills/pormg-usage/$f" |
    diff -u - ".github/skills/pormg-usage/$f"
done
```

No output means nothing local. A difference is either a local edit or a bundle installed by an
older PormG than the pin and never refreshed; read the diff to tell which. Two messages are not
differences:

- a `curl:` error means the tag or `rev` is wrong, or you are offline. The diff printed under it is
  then the whole local file and means nothing — fix the ref and re-run;
- `diff: … No such file or directory` means that file was never installed, or is already gone.

### Migrate your app

Do it **once the project resolves the new PormG** — the session in which `upgrade_guide` showed you
this entry. The installer copies the bundle of the PormG version the project resolves, so running it
against the old one reinstalls the old bundle.

1. If the `diff` above showed local edits, move them into a skill of your own first.
2. Run the installer from the app root, and delete the stale files that an older PormG installed —
   for a `0.6` bundle, `reference.md`. `stale` lists **every** file PormG does not ship, so a file
   your project added to that directory appears there too; keep those.

   ```julia
   # ✗ before — old bundle; SKILL.md holds everything
   # .github/skills/pormg-usage/{SKILL.md, reference.md, writing.md}

   # ✓ after
   julia> PormG.install_ai_skills()
   PormG AI skill installed → …/.github/skills/pormg-usage
     wrote: SKILL.md, advanced.md, async.md, debugging.md, errors.md, models.md, reading.md, writing.md
     not shipped by this PormG version (left in place): reference.md
       Delete them if an older PormG installed them — their content is outdated.
     Nothing in this project points an assistant at the skill yet.
     Add this line to AGENTS.md, CLAUDE.md, or your agent instructions:
       - Using PormG (models, queries, writes, errors, async): read `.github/skills/pormg-usage/SKILL.md` first.
   ```

   The last three lines appear only when no instruction file mentions `pormg-usage`; otherwise the
   installer prints `referenced from:` and the files that do.

   ```bash
   git rm .github/skills/pormg-usage/reference.md
   ```

3. Repoint dangling links with the table above:

   ```markdown
   <!-- ✗ before -->
   see [pormg-usage](../pormg-usage/SKILL.md#5-complex-filters-q-objects)
   <!-- ✓ after -->
   see [pormg-usage](../pormg-usage/reading.md)
   ```

4. If the installer printed a pointer line, add it to `AGENTS.md` (or whichever instruction file
   the project uses).
5. So the next bump does not skip this step again, add to the same file:

   ```markdown
   Before bumping PormG, run `PormG.upgrade_guide(from = …)` and apply what it lists.
   Once the project resolves the new PormG, run `PormG.install_ai_skills()` to refresh the bundle.
   ```
