## `migrate()` is non-interactive-safe — throws `DestructiveMigrationError` in CI instead of hanging (#87)

- **PormG ref**: issue #87 ; `src/migrations/runner.jl`, `src/Migrations.jl`
- **Recorded**: 2026-07-21
- **Severity**: **behavior change (automation only)** — new exported `DestructiveMigrationError`. Affects
  only code that calls `migrate()` in a **non-interactive** context (CI, `Pkg.test`, deploy/cron script,
  piped stdin). Interactive `migrate()` at a real terminal is unchanged.

### What changed

`migrate()` defaulted `interactive=true` and called a bare `readline()` to confirm — with **no TTY
detection**. In a non-interactive process that either **hung** on stdin or read EOF and **silently applied
nothing** ("Migrations were not applied"). The safe-looking workaround `migrate(...; interactive=false,
destructive=true)` disabled *both* guardrails at once.

Now:

- The confirmation prompt shows **only when stdin is a real terminal** (`interactive && stdin isa
  Base.TTY`). `migrate()` never blocks on `readline()` in CI / `Pkg.test` / a deploy script.
- A **non-destructive** plan applies directly in a non-interactive context (previously a silent no-op).
- A **destructive** plan in a non-interactive context now **throws `DestructiveMigrationError`** (exported)
  unless `destructive=true` is passed — instead of silently returning `nothing`. Automation fails loudly
  with an actionable message.
- **Piped stdin** (`echo yes | julia … migrate("db")`) counts as non-interactive — it no longer bypasses
  the destructive gate; pass `destructive=true`.

Interactive terminal behavior is unchanged: you still get the yes/no prompt, and a destructive plan without
`destructive=true` still prints a red `@error` and aborts.

### How to find the calls to migrate

Grep each app for `migrate(` in automated contexts — CI steps, deploy/bootstrap scripts, anything run
without a TTY:

```
rg -n "migrate\(" <app>                 # focus on CI / deploy / cron entry points
rg -n "interactive\s*=\s*false" <app>
```

Two things to check at each non-interactive call site:

1. A `catch` / return-value check that assumed a destructive plan **silently returns `nothing`** — it now
   throws `DestructiveMigrationError`.
2. A call that passed `interactive=false` only to avoid a hang — that is now optional (auto-detected), but
   harmless to keep.

### Migrate your app

- Automated apply of a plan that *may* be destructive: pass the explicit opt-in —
  `migrate("db"; destructive=true)`. CI no longer hangs, and a missing opt-in is now a loud error, not a
  silent skip.
- If a script must tolerate "destructive plan present → skip, don't fail", catch it:
  ```julia
  try
      migrate("db")
  catch e
      e isa PormG.Migrations.DestructiveMigrationError || rethrow()
      @warn "Destructive migration skipped; apply manually with destructive=true" exception=e
  end
  ```
- Non-destructive automated migrations need no change — `migrate("db")` now applies them instead of
  silently no-op'ing.
