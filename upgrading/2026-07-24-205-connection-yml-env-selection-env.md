## `connection.yml` env selection: `env:` → `default_env:`; `load()` fails loud on a missing config (#205)

- **Version**: 0.3.0
- **PormG ref**: issue #205 ; `src/Configuration.jl`, `src/Generator.jl`,
  `src/querybuilder/{exceptions,execution,execution_bulk,many_to_many,deletion}.jl`,
  `README.md`, `docs/src/{index,configuration/connection_yml,configuration/setup}.md`
- **Recorded**: 2026-07-24
- **Severity**: **behavior change** — three parts, all with clear, cheap migrations. Most apps: just
  rename the yaml key. Part of the `0.3.x` pre-publish wave — roll it forward together with the
  other `0.3.*` entries.

### What changed

1. **`env:` → `default_env:` (yaml).** The top-level `env:` key was always **inert** — the code that
   read it had been commented out, so `env: prod` silently did nothing. It is renamed to
   `default_env:` and given a real job: the **lowest-priority** environment default. Resolution
   precedence, first wins: **`env=` kwarg › `ENV["PORMG_ENV"]` › file `default_env:` › `"dev"`.**
   A leftover bare `env:` key is ignored and PormG **warns once per file** to rename it. `default_env:`
   is optional — omit it and PormG uses `dev`.
2. **`load()` fails loud on a missing config.** `PormG.Configuration.load(path)` used to scaffold a
   skeleton, log an `@error`, and `return nothing` when the folder/yml was missing — a typo'd path
   became a silent no-op that resurfaced later as a confusing settings-lookup error. It now **throws**
   `MissingDatabaseConfigurationException` (newly defined; the name was previously thrown-but-undefined,
   so a missing env block raised `UndefVarError`). First-run scaffolding is now explicit:
   `PormG.setup(path)` or `load(path; scaffold=true)`. A missing env block error now lists the
   available blocks.
3. **Write-disabled message standardized.** The `change_data: false` guard's error is unified across
   all write paths (insert / update / delete / update_or_create / bulk_insert|copy|update /
   many-to-many add|remove|clear / primary-key allocation): it now reads *"…is not allowed to write.
   … set `change_data: true` under the `config:` block…"* Only code that **string-matched** the old
   per-operation wording (`not allowed to insert`/`update`/`delete`) is affected.

### How to find the calls to migrate

```
rg -n '^env:' <app>/**/connection.yml                    # 1. rename the dead key → default_env: (or delete)
rg -n 'Configuration\.load\(' <app>/src                  # 2. any load() that relied on auto-scaffold-on-missing (rare)
rg -n 'not allowed to (insert|update|delete)' <app>/src  # 3. catch blocks string-matching the old write message
```

### Migrate your app

```yaml
# ✗ before — inert; selected nothing
env: dev

# ✓ after — an optional lowest-priority default; omit it entirely and PormG uses `dev`
default_env: dev
```

```julia
# load() on a missing/typo'd path was a silent no-op (scaffold + nothing) → it now THROWS.
# If you relied on load() creating the skeleton, be explicit:
PormG.Configuration.load("db"; scaffold=true)      # or: PormG.setup("db")

# A catch that keyed on the old per-op write message → match the TYPE. #231 (same 0.3.0 train)
# retyped this error to `PormG.PermissionError`, which is deliberately NOT <: ArgumentError —
# so an `e isa ArgumentError` catch here would silently stop matching. No message check needed.
catch e
    e isa PormG.PermissionError && handle()
```

The recommended server pattern is unchanged and preferred: let the host resolve its environment and
pass it explicitly — `load(...; env=current_env())` — so `connection.yml` is identical across
environments. `default_env:` is a convenience for scripts/single-env apps.
