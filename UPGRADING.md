# Upgrading PormG — consumer-app rollout log

Tracks **breaking / behavior changes in PormG** that require source-code changes in the internal apps that depend on it. PormG is pre-publish (single maintainer, ~4 internal apps, no external users), so breaking changes are intentional and cheap on the *PormG* side — but each one still has to be rolled out by hand in every consuming app. This file is that rollout checklist.

> ⚠️ **Not database migrations.** This file is about migrating **app source code** to keep up with the PormG API. It is unrelated to the `makemigrations` / `migrate` schema engine that manages your database tables.

> 🚀 **Upgrading an app? Don't read this file top to bottom.** Run
> `PormG.upgrade_guide(from = v"<your pinned version>")` — it renders only the entries newer than
> your pin, newest-first. The full how-to (versioning model, the apply recipe, driving it with an AI
> agent) lives in the docs: **[Upgrading PormG](https://pingolee.github.io/PormG.jl/dev/upgrading/)**.
> This file is the change log those tools read; the sections below are the rules for *writing* an
> entry.

## Writing an entry

- One `##` entry per breaking change, **newest first**. New entries land in **`## Unreleased`** with
  `- **Version**: Unreleased` and **no `Project.toml` bump**; the maintainer stamps them with a
  release number when cutting a train (`/pormg-cut-release`).
- Each entry records: the PormG **version** it shipped in, what changed, why, a *"How to find the
  calls to migrate"* grep, and the concrete **before → after** code edit.
- **Not for additive features.** This log is only what **forces** an app edit. A new opt-in
  capability (operator, kwarg, function) requires no change to keep an app working → document it in
  `docs/`, not here.
- **No per-entry rollout tables.** An app's own PormG dependency pin *is* its rollout state, and
  `upgrade_guide(from = <that pin>)` derives what it still needs — so there is nothing to maintain
  per app.
- **Keep the prose version-neutral.** Write *"part of the `0.3.x` pre-publish wave"*, never *"part of
  the current `## Unreleased` wave"* — stamping rewrites the `- **Version**:` bullet, not the body,
  so self-referential prose ships stale (this bit #201).
- Entries are version-stamped from **`0.2.0`** onward; those below the `pre-0.2 history` marker
  predate the versioning policy and are unstamped (treat them as already shipped before `0.2.0`).

---

## Unreleased — next `0.4.0`

_Changes merged but not yet cut into a release. A consumer dev'ing PormG at HEAD is running these,
and `PormG.upgrade_guide` surfaces them by default. When the maintainer next rolls changes into a
consuming app, `/pormg-cut-release` stamps every entry below with `0.4.0`, dates them, and tags it._

---

## Read a caught `PormGError` with `error_message`, not `e.msg` (#261)

- **Version**: Unreleased
- **PormG ref**: issue #261 ; `src/exceptions.jl` (`error_message`, `PoolError`), `src/Kernel.jl`
  and `src/PormG.jl` (exports), `src/ConnectionPool.jl` (reparenting), `docs/src/api.md`
- **Recorded**: 2026-07-29
- **Severity**: **corrective** — no PormG behavior changed, so nothing that worked before stops
  working. It is logged here rather than treated as an additive feature (which this file excludes)
  because **apps that followed #239's advice may already carry a latent bug**: #239 told you to
  `catch PormGError`, and the natural next line, `e.msg`, throws a `FieldError` on four of the
  sixteen subtypes. Fixing that is a real app edit, which is what this entry exists to prompt.

### What changed

**1. `error_message(e)` is the uniform way to read any PormG error.**

#239 told you to `catch PormGError`. The obvious next line is `e.msg` — and that works for 12 of
the 16 concrete subtypes, then throws a `FieldError` on the four built from structured fields:
`DoesNotExist`, `MultipleObjectsReturned`, `PoolTimeoutError`, `PoolConnectError`. Those four
carry richer data (`model_name`, `adapter`, `pool_size`, `attempts`, …) instead of a flat string,
which is better design — there was just no uniform way to get text out of them.

`error_message` is defined through `showerror`, which every subtype implements, so it also stays
correct for subtypes added later. It never returns less than `e.msg` did: for most subtypes it is
exactly that field, and for the few with their own `showerror` it returns the richer rendering.

**2. `PoolError` is the new abstract umbrella over `PoolTimeoutError` / `PoolConnectError`.**

Matching `ConfigurationError` and `MigrationError`. `catch PoolError` now handles pool saturation
and connect failure without naming both; catching either concrete type still works unchanged.

### How to find the calls to migrate

```
rg -n '\.msg' <app> | rg -i 'catch|err|exception'
```

Look for anything reading `.msg` off a **caught** PormG error. A site that catches a specific
`msg`-carrying subtype (`FilterError`, `QueryBuildError`, …) is fine as-is; the risk is a site that
catches the broad `PormGError` and then reads `.msg`, because that path can now receive one of the
four structured types.

### Migrate your app

```julia
# ✗ before — throws FieldError if `e` is a pool/cardinality error
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError && @error "write failed" msg=e.msg
    rethrow()
end

# ✓ after — one accessor, every subtype
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError && @error "write failed" msg=error_message(e) type=typeof(e)
    rethrow()
end
```

And, optionally, collapse a two-branch pool catch:

```julia
# ✗ before
catch e
    (e isa PoolTimeoutError || e isa PoolConnectError) && back_off()

# ✓ after
catch e
    e isa PoolError && back_off()
```

---

## The `PormGError` taxonomy now covers all of PormG — not just the query builder (#239)

- **Version**: Unreleased
- **PormG ref**: issue #239 ; `src/exceptions.jl` (the taxonomy), `src/models/fields.jl`,
  `src/Models.jl`, `src/Dialect.jl`, `src/Configuration.jl`, `src/ConnectionPool.jl`,
  `src/migrations/*`, `src/PormG.jl`, `src/querybuilder/execution.jl`, `docs/src/api.md`
- **Recorded**: 2026-07-28
- **Severity**: **breaking (error contract)** — completes what #231 started. Field constructors,
  model definition, configuration, the SQL dialect, the connection pool and the migration engine now
  raise `PormGError` subtypes instead of bare `ArgumentError`. Part of the `0.3.x` pre-publish wave.

### What changed

#231 typed the query builder and explicitly left the rest as `ArgumentError`. That half-migrated state
was the worst of both worlds: `catch PormGError` *looked* like it covered PormG, then a model-definition
mistake sailed straight past it. Every `throw(ArgumentError(...))` in `src/` is now a semantic type,
except two genuine Julia-level API misuses in `src/tools.jl` (a missing kwarg, a missing path).

| Subtype | Now raised by |
|---------|---------------|
| `ModelDefinitionError` | model/schema definition — more than one primary key, duplicate `related_name`, illegal field name, a `UniqueConstraint` naming an unknown or M2M field, an unresolvable `ForeignKey`/`ManyToManyField` target, `Model(...)` given a non-`PormGField` |
| `FieldValidationError` | **every** field-constructor rejection — a kwarg of the wrong type (`unique="yes"`), an out-of-range `max_length`, a `default=` violating the field's own contract, a malformed `choices`, `decimal_places > max_digits`, or a `FloatField`/`DecimalField` used as a primary key |
| `InvalidValueError` | the `Models.format_*_sql` coercion family — duration, UUID, JSON, number, bool, date, timezone, `yyyy_mm` — plus `Dialect`'s "the value must be a String" guards |
| `ConfigurationError` *(abstract)* | umbrella; `InvalidConfigurationError` for an unsupported adapter, unknown connection key, malformed `extensions`, a pool that was never built; `MissingDatabaseConfigurationException` is now **inside** this bucket |
| `MigrationError` *(abstract)* | umbrella; `InvalidMigrationError` for a duplicate index name, an invalid interactive `makemigrations` answer, an unimplemented `migrate_to(version)`; `DestructiveMigrationError` is now **inside** this bucket |
| `UnsupportedConnectionError` | backend-capability rejections — the PG-only JSONB `@jcontains`/`@has_key`/`@has_any_keys`/`@has_keys` lookups, `iunaccent_*`/`niunaccent_*`, an extract part SQLite lacks, too old a SQLite library, an importer pointed at the wrong backend |
| `QueryBuildError` | `on_conflict_clause` argument shape; `atomic(durable=true)` nested inside another transaction |

**Definition-time vs value-time.** `FieldValidationError` fires while *defining* a model
(`IntegerField(unique="yes")`, `UUIDField(default="nope")`); `InvalidValueError` fires while coercing a *value* on the insert/update
path (`Models.format_uuid_sql("nope")`). Both were `ArgumentError` before, so an app that lumped them
together must now decide which it meant.

### How to find the calls to migrate

```
rg -n 'catch|@test_throws|isa' <app> | rg 'ArgumentError|ErrorException'
```

After #231 you were told to leave field- and model-definition catches alone. **Revisit exactly those** —
they are what changed here. Also check `catch` blocks around `Configuration.load`, `register_connection`,
`makemigrations`/`migrate`, `import_models_from_*`, `pool_stats`, and any model-definition module.

Field constructors are the largest single group (248 throw sites across the 26 `*Field` types), so any
app that builds models dynamically and guards the call is affected:

```julia
# ✗ before
try; Models.CharField(max_length = user_supplied); catch e; e isa ArgumentError && fallback(); end
# ✓ after
try; Models.CharField(max_length = user_supplied); catch e; e isa PormG.FieldValidationError && fallback(); end
```

### Migrate your app

```julia
# ✗ before — model/config/migration failures were plain ArgumentErrors
try
    PormG.Configuration.load("db_2")
    include("db/models.jl")
    PormG.Migrations.migrate("db_2")
catch e
    e isa ArgumentError && @error "setup failed" exception=e
    rethrow(e)
end

# ✓ after — catch the category, or PormGError for anything PormG rejected
try
    PormG.Configuration.load("db_2")
    include("db/models.jl")
    PormG.Migrations.migrate("db_2")
catch e
    e isa PormG.ConfigurationError    && return fix_connection_yml(e)   # incl. a missing connection.yml
    e isa PormG.ModelDefinitionError  && return report_bad_model(e)
    e isa PormG.MigrationError        && return halt_deploy(e)          # incl. a refused destructive plan
    e isa PormG.PormGError            && return handle_pormg_error(e)
    rethrow(e)
end
```

The two abstract umbrellas are deliberate: `catch ConfigurationError` also catches a missing
`connection.yml`, and `catch MigrationError` also catches `DestructiveMigrationError`. Catching the
bucket has no holes.

---

## 0.3.0 — 2026-07-24

## Query-builder errors are a typed `PormGError` taxonomy — stop catching `ArgumentError` (#231)

- **Version**: 0.3.0
- **PormG ref**: issue #231 ; `src/PormG.jl` (abstract root + exports), `src/querybuilder/exceptions.jl`
  (subtypes + `showerror` + `_write_not_allowed`), the throw sites across `src/querybuilder/*.jl`,
  `docs/src/api.md`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (error contract)** — every query-builder misuse now raises a subtype of
  `PormGError` (`<: Exception`) instead of a bare `ArgumentError`/`ErrorException`. The subtypes are
  **NOT** `<: ArgumentError` (a clean break), so `catch ArgumentError` / `occursin(text, e.msg)` blocks
  around PormG query calls stop matching. Part of the `0.3.x` pre-publish wave; extends the #197
  typed-exception lineage. **Supersedes the type in the #205 entry below:** the standardized
  write-disabled error is now `PermissionError`, not `ArgumentError`.

### What changed

Query-builder failures now carry a semantic **type**, so callers react programmatically instead of
matching a message string. The root is `PormGError <: Exception`; catch it for any query-builder
failure, or a specific subtype:

| Subtype | Raised when |
|---------|-------------|
| `UnknownFieldError` / `LazyTraversalError` (both `<: FieldAccessError`) | field/column/`__`-path not found; or an unprojected `ForeignKey` read off a fetched row (steer to `values(...)`) |
| `FilterError` | invalid filter argument/shape; operator misuse on a JSON/subquery column |
| `QueryBuildError` | structural/API misuse (joins, CTEs, projection, ordering, window/bulk config) — the long-tail default |
| `UnsafeMutationError` | `update()`/`delete()` without a filter (or another unsafe shape) |
| `InvalidValueError` | value coercion/type mismatch on insert/update; identifier-safety guard; interval/duration parse |
| `PermissionError` | connection not allowed to insert/update/delete (`change_data=false`) — this is the #205 write-disabled error, now typed |
| `UnsupportedConnectionError` | connection is neither PostgreSQL nor SQLite, or a model is not bound to a connection |
| `DoesNotExist` / `MultipleObjectsReturned` | `get()` found zero / more than one row (reparented under `PormGError`) |

**Out of scope in `0.3.0` (still `ArgumentError` at the time):** field-constructor validation
(`src/models/fields.jl`) and model/schema-definition errors (`src/Models.jl`). ⚠️ **This is no longer
true** — #239 migrated them; see *"The `PormGError` taxonomy now covers all of PormG"* above. Do not
plan a migration from this paragraph.

### How to find the calls to migrate

```
rg -n 'catch|@test_throws|isa' <app> | rg 'ArgumentError|ErrorException'
```

Focus on blocks wrapping PormG query calls (`filter`/`values`/`update`/`delete`/`get`/row access/`bulk_*`).
Field-definition and model-definition errors still throw `ArgumentError` — leave those. ⚠️ **This is no
longer true** — #239 retyped them to `FieldValidationError` / `ModelDefinitionError`. If you already
migrated on this instruction, revisit exactly those catches; see *"The `PormGError` taxonomy now covers
all of PormG"* above.

### Migrate your app

```julia
# ✗ before — coupled to the message wording (incl. the #205 write-disabled catch)
try
    run_query()
catch e
    e isa ArgumentError && occursin("not allowed to write", e.msg) && fall_back_to_readonly()
    rethrow(e)
end

# ✓ after — catch the semantic type, or the abstract root for any query-builder misuse
try
    run_query()
catch e
    e isa PormG.PermissionError    && return fall_back_to_readonly()  # the #205 write-disabled case
    e isa PormG.LazyTraversalError && return steer_to_projection()    # unprojected FK read
    e isa PormG.PormGError         && return handle_pormg_error(e)    # anything the QB rejected
    rethrow(e)
end
```

---

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

---

## Public naming settled — ToChar, formatter, aggregate, M2M `add`/`remove`/`clear`/`set`, setup unexported (#201)

- **Version**: 0.3.0
- **PormG ref**: issue #201 ; `src/querybuilder/{functions,types,many_to_many}.jl`, `src/models/fields.jl`,
  `src/PormG.jl` exports, `docs/src/{api,many_to_many,import_django}.md`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (renames)** — pre-publish naming pass; every rename is old-name-gone, no aliases.
  Part of the `0.3.x` pre-publish wave — roll it forward together with the other `0.3.*` entries.

### What changed

| Old | New | Surface |
|-----|-----|---------|
| `To_char(x, fmt; formater=…)` | `ToChar(x, fmt; formatter=…)` | `PormG.Functions` export (only non-PascalCase name in the library) |
| `formater` (kwarg + struct field) | `formatter` | `Extract`/`ToChar`/math-function kwarg; fields on `FObject`/`WindowFunction` **and** all model-field structs |
| `agregate` (struct field) | `aggregate` | `InstructionObject`/`FExpression`/`FObject`/`WindowFunction` internals |
| `manager.add!/remove!/clear!/set!` | `manager.add/remove/clear/set` | M2M manager mutators (Django parity; bang implied "mutates a Julia arg", which these don't — they mutate the DB; see the rationale note in `docs/src/many_to_many.md`) |
| `setup` / `install_ai_skills` (exported) | `PormG.setup()` / `PormG.install_ai_skills()` (qualified-only) | top-level exports removed; behavior unchanged |
| `InstrucObject` | `InstructionObject` | internal QB struct (public-adjacent docstrings) |

**Deliberate non-change:** `bulk_insert` keeps its name (Django's `bulk_create` is a different API —
DataFrame-first, `on_conflict=` kwarg; documented in `docs/src/import_django.md`, "API Naming
Differences from Django").

### How to find the calls to migrate

```
rg -n 'To_char|formater|agregate|InstrucObject'        # renames: mechanical old → new
rg -n '\.(add|remove|clear|set)!\('                    # M2M mutators: drop the !
rg -n '(^|[^.\w])(setup|install_ai_skills)\('           # bare calls → prefix with PormG.
```

The first two are safe find-and-replace (whole-word). For the third, only *unqualified* calls need
the `PormG.` prefix — `PormG.setup()` calls keep working as-is.

---

## `PormG.QueryBuilder` export prune — `query`/`update`/`page` no longer dumped; `OP` internal; `With` import-only (#202)

- **Version**: 0.3.0
- **PormG ref**: issue #202 (follow-up to #35) ; `src/QueryBuilder.jl`, `src/documentation/querybuilder.jl`, `docs/src/{api,read/subqueries_and_ctes}.md`
- **Recorded**: 2026-07-25
- **Severity**: **breaking (submodule export surface)** — affects only code that does a **bare**
  `using PormG.QueryBuilder` and relied on the dumped names, or imported `OP`. The top-level
  `using PormG` surface is unchanged, and the idiomatic `.with()` / `"field__@op"` forms are unchanged.

### What changed

Curating the `#35` export surface one level deeper, inside the `PormG.QueryBuilder` submodule:

- **`query`, `update`, `page` are no longer exported** — a bare `using PormG.QueryBuilder` no longer
  dumps these three generic names into scope (the exact collision class `#35` removed at top level).
  They stay **defined**: explicit `import PormG.QueryBuilder: page` / `using PormG.QueryBuilder: update`
  still work, and the fluent `.page()` / `.update()` methods are unaffected.
- **`OP` is now internal** — un-exported *and* un-documented. Build operator predicates with the
  public string form `"field__@op" => value`; `OP` stays reachable as `PormG.QueryBuilder.OP` for the
  rare function-expression case.
- **`With` is import-only** — reachable via `using PormG.QueryBuilder: With` (the docs teach this); the
  idiomatic form is the fluent `.with(name => subquery; join_field=…)`.

### How to find the calls to migrate

```
rg -n 'using +PormG\.QueryBuilder\s*$' <app>/src     # bare submodule dump that relied on query/update/page
rg -n '\bOP\(' <app>/src                              # OP used after a bare submodule `using`
```

### Migrate your app

```julia
# ✗ before — the bare dump brought query/update/page (+ OP/With) into scope
using PormG.QueryBuilder

# ✓ after — import exactly the names you use
using PormG.QueryBuilder: page, With        # (whichever you actually reference)
q.filter("points__@gte" => 20)              # operator predicates: prefer the string form over OP(...)
```

Apps that use only the top-level `using PormG` surface, or the fluent `.page()` / `.update()` /
`.with()` methods, need **no** change.

---

## Removed `Base.first` type piracy — curried `first(; kwargs…)` form (#200)

- **Version**: 0.3.0
- **PormG ref**: issue #200 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (method removal)** — but the removed form was undocumented, unexported, and
  used nowhere in-repo, so real impact is expected to be nil. Bumped `y` anyway because the method was
  globally reachable, so `compat = "0.2"` should reject it.

### What changed

The convenience method

```julia
first(; kwargs...) = (objct) -> first(objct; kwargs...)   # removed
```

was **type piracy**: a zero-positional method on `Base.first` with no PormG type in its signature, so
after `using PormG` it claimed the global `Base.first(; kwargs…)` call for every module in the process.
There is no piracy-free version (a nullary method on someone else's function has no owned type to
anchor it), so it was removed. The normal ergonomics are unaffected — only passing keywords *inside a
pipe* is gone, and it has a direct equivalent:

```julia
# ✗ before — curried, kwargs-in-a-pipe (the only removed form):
sql = M.Driver.objects.filter("nationality" => "British") |> first(show_query = :sql)

# ✓ after — pass the handler explicitly (or use the method form):
sql = first(M.Driver.objects.filter("nationality" => "British"); show_query = :sql)
sql = M.Driver.objects.filter("nationality" => "British").first(show_query = :sql)
```

Still valid, untouched: `q.first()`, `first(q)`, `q.first(show_query=:sql)`, the bare pipe
`q |> first` (that's `first(q)`), and `list() |> first` (that's `Base.first(::Vector)`). The sibling
curried forms `delete(; kwargs…)` / `inspect_query(; kwargs…)` are **not** affected — those functions
are package-owned, so a kwargs-only method on them is not piracy.

### How to find the calls to migrate

Grep each app for a `first` that is piped **with keyword arguments** (bare `|> first` is fine):

```
rg -n '\|>\s*first\(' <app>/src        # curried first(...) in a pipe — the only form to change
```

---

## `first()` / `get()` no longer mutate the handler (#199)

- **Version**: 0.2.3
- **PormG ref**: issue #199 ; `src/querybuilder/execution.jl` (`first`, `get`),
  `docs/src/read/index.md` (new *Handler Mutation Model* section)
- **Recorded**: 2026-07-24
- **Severity**: footgun fix — **no action expected**. Classified non-breaking: the only affected
  code exploits `first()`'s documented limit-leak workaround or `get()`'s *undocumented*
  filter-persistence side effect.

### What changed

All read terminals now share one contract: they execute on an internal copy and never mutate the
handler. Previously `first()` permanently set `limit(1)` on the handler and `get(q, filters...)`
permanently appended its inline filters to it — `count`/`exists`/`list` already copied. Re-call
semantics of chain methods are unchanged (and now documented): `filter` accumulates,
`values`/`order_by` replace their previous call.

```julia
# ✗ before — handler reuse after first()/get() silently carried leaked state:
q = M.Driver.objects.filter("nationality" => "British")
q.first()                                # left limit=1 on q
q.list()                                 # returned 1 row (leaked limit)
q.update("nationality" => "English")     # threw: UPDATE with LIMIT is not supported

r = M.Result.objects
r.get("resultid" => 1)                   # appended the inline filter to r
r.count()                                # counted WHERE resultid = 1 (leaked filter)

# ✓ after — the handler is untouched; same calls, no leaked state:
q.first()                                # q unchanged (limit stays 0)
q.list()                                 # all matching rows
q.update("nationality" => "English")     # valid on the same handler

r.get("resultid" => 1)                   # r unchanged
r.count()                                # counts ALL results
```

### How to find the calls to migrate

Nothing to migrate unless an app **reuses a handler after** `.first()`/`.get()` *and relies on the
leaked state* (a limit-1 `list()`, or inline `get` filters narrowing later calls). Grep each app for
a handler variable used again after one of these terminals:

```
rg -n '\.(first|get)\(' <app>/src        # then eyeball: is that handler variable used again below?
```

One-handler-per-query code (the documented style) is unaffected.

---

## Typed exceptions across the query surface — raw-`String` throws are now `ArgumentError`/`ErrorException` (#197)

- **Version**: 0.2.0
- **PormG ref**: issue #197 ; `src/querybuilder/` (`build_helpers.jl`, `build_joins.jl`, `build_query.jl`,
  `ctes.jl`, `deletion.jl`, …), `src/Configuration.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-07-23
- **Severity**: **breaking (error type)** — ~46 raw-string `throw("...")` sites now raise typed
  exceptions. No new exported types (existing `ArgumentError`/`ErrorException` +
  `DoesNotExist`/`MultipleObjectsReturned`/pool errors cover the surface).

### What changed

Every `throw("...")` in the query builder — a bare `String`, which is **not** an `Exception` — plus
stragglers in `Configuration.jl` and `migrations/planner.jl` now throws a typed exception:

- `ArgumentError` for user misuse (bad args, unsupported `values()` pairs, malformed lookups, …);
- `ErrorException` (via the internal `_unsupported_conn` helper) for internal dispatch fallbacks;
- `bulk_insert`'s catch blocks now `@error` + `rethrow()`, so the original driver exception survives
  instead of being reduced to a string.

A raw `String` throw escaped every `catch e; e isa Exception` a package user could write — so any
error handling that expected a real exception silently failed to match. Now `e isa Exception` (and
`e isa ArgumentError`) behave as expected.

### How to find the calls to migrate

Grep each app for `catch` blocks that **string-match** a PormG error rather than catching a type:

```
rg -n "catch" <app>/src | rg -iE "isa String|occursin\("
```

Only handlers that string-matched a PormG throw are affected. A `catch e … rethrow()`, or a handler
already keyed on `ArgumentError`/`ErrorException`/`DoesNotExist`/`PoolTimeoutError`, needs no change.

### Migrate your app

```julia
# ✗ before — the throw was a bare String; `e isa String` was the only way to match, and
#            `e isa Exception` never fired
catch e
    e isa String && occursin("<PormG error text>", e) && handle()

# ✓ after — catch the typed exception; read the text off `.msg`
catch e
    e isa ArgumentError && occursin("<PormG error text>", e.msg) && handle()
```

If a handler only needs "PormG rejected this call", `e isa Exception` (or the narrower
`e isa ArgumentError`) now suffices — no string matching required.

---

<!-- ───────────────────────── pre-0.2 history (unstamped) ───────────────────────── -->

## Scalar correlated subqueries: `Subquery(...)` in `values()`; unsupported `values()` pairs now throw (#92)

- **PormG ref**: issue #92 (the supported fix for the #74 fan-out guard) ; `src/querybuilder/types.jl`,
  `src/querybuilder/object_manager.jl`, `src/querybuilder/build_query.jl`, `src/querybuilder/build_helpers.jl`,
  `src/QueryBuilder.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-22
- **Severity**: **additive feature + one latent-bug fix to check.** New top-level export `Subquery`;
  `Exists(...)` is now also projectable in `values()`. The check: `values()` used to **silently drop** an
  unsupported `"alias" => <value>` pair — that column just vanished from the result. It now throws an
  `ArgumentError`. Only code that was already getting a wrong/missing column is affected.

### What changed

- **New:** `"alias" => Subquery(inner)` inside `values()` projects a scalar correlated subquery as a
  column. The inner query correlates via `OuterRef(...)` and must project exactly **one** column; an
  aggregate (`Count`, `Sum`, …) or a plain column with `order_by` + `limit(1)` both work. This is the
  fan-out-safe way to attach related-set aggregates — the construct the #74 guard's error message points
  to. Multiple independent `Subquery` columns compose in one query with no fan-out interaction.
- **New:** `"alias" => Exists(inner)` inside `values()` projects a per-row boolean column (SQLite `0`/`1`,
  PostgreSQL booleans). Previously `Exists` was filter-only.
- **Fail-loud fix:** an unsupported right side in a `values()` pair (e.g. `"x" => 42`, or any type the
  projection doesn't handle) now raises `ArgumentError` at `values()` time instead of being silently
  dropped from the SELECT list. Likewise, a **function pair that fails validation** (e.g.
  `"x" => Concat("surname", 42)` — constructs, but `_check_function` rejects the `Int`) used to be
  logged and silently dropped; it now propagates the original error (typically a `MethodError`) after
  logging the failing alias.
- Guard rails: the inner query must project exactly one column (else `ArgumentError`); the alias is
  mandatory (bare `Subquery(...)` throws); a `Subquery`/`Exists` projected *inside another subquery*
  throws (`OuterRef` resolves one level only); a non-aggregate inner with no `LIMIT` emits a build-time
  `@warn` (possible multi-row scalar).

### How to find the calls to migrate

Nothing to migrate for the new feature (additive). For the silent-drop fix, look for `values()` pairs whose
right side is not a field name, SQL function, `Value(x)`, `Subquery(...)`, or `Exists(...)`:

```
rg -n 'values\(' <app> | rg '=>'      # then eyeball non-standard right-hand sides
```

An affected call site was already broken (the column silently missing from results) — the throw makes it
visible.

### Migrate your app

- Nothing required. Optionally adopt `Subquery` where an app worked around the #74 guard with a
  CTE-aggregate join that only needed one scalar per row.

---

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

---

## Connect fast-fail (`PoolConnectError`, `fail_fast_on_connect`)

- **PormG ref**: issue #72 (AC2; follow-up to #37/#124) ; `src/ConnectionPool.jl`, `src/Configuration.jl`,
  `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-18
- **Severity**: **mostly additive** (new exported `PoolConnectError`, opt-in `fail_fast_on_connect`, default
  on). **One behavior change to check:** an unopenable pool now raises `PoolConnectError`, not
  `PoolTimeoutError`. Only apps that *catch `PoolTimeoutError` specifically* around a connection failure
  need a look.

### What changed

`acquire_connection` used to treat "can't open a connection" (bad password, missing role/database,
unopenable SQLite path) the same as "healthy pool saturated": it waited the full `pool_timeout` (~30 s),
then threw `PoolTimeoutError` ("raise pool_size"). It now:

- **classifies** the driver error via a new backend hook (`backend_is_permanent_connect_error`): permanent
  = PostgreSQL auth / missing role|database, SQLite `unable to open database file`;
- **fast-fails** a permanent error immediately with a new catchable **`PoolConnectError`** (exported)
  carrying the driver `cause` + a redacted connection string (remedy: fix credentials, not `pool_size`);
- surfaces `PoolConnectError` (not `PoolTimeoutError`) for *any* connect failure that reaches the deadline,
  including ambiguous host/DNS errors (which are still waited out, not fast-failed);
- adds a `fail_fast_on_connect` config key (`connection.yml` + `register_connection` kwarg; default `true`)
  to opt out;
- (fix) redacts the connection string in SQLite pool logs, matching the PostgreSQL path.

A healthy-but-saturated pool still raises `PoolTimeoutError` — unchanged.

### How to find the calls to migrate

Grep each app for a `catch` that special-cases pool saturation on a connection acquire/fetch:

```
rg -n "PoolTimeoutError" <app>/src
```

If a handler means "the database is unreachable / misconfigured", widen it to also catch
`PoolConnectError` (or catch both). If it only means "pool is saturated, back off and retry", leave it —
`PoolConnectError` is intentionally a *different*, non-retryable signal.

---

## Connection-pool wait is now direct-handoff (event-driven), not a busy-poll

- **PormG ref**: issue #124 (follow-up to #37) ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-16
- **Severity**: internal mechanism — **no action needed**. `acquire_connection`'s signature
  (`timeout_seconds`, `max_retries`, SQLite `mode`) and the `PoolTimeoutError` fields are unchanged.

### What changed

When the pool is saturated, `acquire_connection` used to `sleep(0.1)` and rescan (up to the
timeout/retry budget). It now **parks** the caller and is woken the instant a connection is
released — the returner hands the freed slot *directly* to the oldest compatible waiter (FIFO, no
barging; HikariCP / Go `database/sql` style). Handoff latency drops from up to ~100 ms to
sub-millisecond, waiters are served fairly, and there is no more per-100 ms rescan spam. A genuine
saturation still throws the same catchable `PoolTimeoutError`.

### Nothing to grep

No API changed. One **diagnostic** nuance: `PoolTimeoutError.attempts` now counts scan iterations
(typically `1` on a clean saturated timeout) rather than the old ~`timeout/0.1s` poll count. If you
log or assert on `attempts`, expect a much smaller number; it remains `>= 1`.

---

## `create()` / `insert()` return a `PormGRow` (was `Dict`)

- **PormG ref**: issue #166 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-07-16
- **Severity**: **breaking (return type)** / behavior improvement — the row surface is now uniform.

### What changed

`create()` / `insert()` now return a **`PormGRow`** on the execute path — the same row object
`get()`, `first()`, `list()`, and `update_or_create()` already return — instead of a bare
`Dict{Symbol,Any}`. This makes the row surface consistent and lets a created row be mutated and
`.save()`d:

```julia
row = M.Driver.objects.create("forename" => "Ayrton", "surname" => "Senna")
row[:driverid]        # unchanged — PormGRow delegates indexing/haskey/keys/get/pairs/iterate
row.surname           # now also works (dot-access)
row.surname = "SENNA"; row.save()   # and it round-trips
```

`show_query=:sql/:dict/:params` still return their inspection shapes (String/Dict/Vector) — only the
`:execute` return changed. `list(:dict)` and `values()` still return plain dicts. `update()` still
returns a matched-row count.

### How to find the calls to migrate

Because `PormGRow` delegates `getindex`/`haskey`/`get`/`keys`/`values`/`pairs`/`iterate`, the common
patterns (`row[:id]`, `haskey(row, :x)`, iterating pairs) keep working unchanged. Only these break:

```
# 1. Type checks that assumed a Dict:
grep -rn "create(" src/ | grep -i "isa Dict"
grep -rn "= .*\.create(" src/            # then check for `isa Dict`, `merge(`, `delete!(`

# 2. Dict-only MUTATION of a create() result (PormGRow has no setindex!):
grep -rn "\.create(" src/ | ...          # then look for `result[:x] = ...` on that result
```

### Migrate your app

- `@assert result isa Dict` → `@assert result isa PormG.QueryBuilder.PormGRow` (or drop the type
  check — field access is unchanged).
- Adding/overwriting a key on the result: `result[:x] = v` → `result.x = v` (dot-assign), and
  `result.save()` if you want it persisted. (Read access `result[:x]` is unchanged.)
- Passing the result somewhere typed `::Dict`, or `merge(result, …)` / `collect(result)` /
  `length(result)` / `result == Dict(…)`: convert first with `Dict(pairs(result))`.

---

## Connection errors inside `run_in_transaction` now propagate (no silent statement retry)

- **PormG ref**: issue #138 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (error now surfaces instead of a silent, broken retry)

### What changed

`fetch()`'s lost-connection recovery (renew the pooled connection, re-run the statement once)
no longer fires **inside a transaction context** or on a caller-pinned `conn`. Previously a
connection drop during e.g. `q.create(...)` inside `run_in_transaction` silently re-ran the
statement on a **fresh autocommit session** — committing a write that should have died with the
transaction — and released the transaction's pooled connection to the pool mid-transaction. Now
the connection error propagates out of the transaction block like any other failure; the wrapper
rolls back and renews/discards the pooled connection (#71). Plain `fetch()` outside transactions
keeps the transparent one-shot retry. This matches Django / SQLAlchemy / Rails 7.1 /
Go `database/sql`: never retry a statement inside a transaction — the application retries the
whole transaction.

### How to find the calls to migrate

Nothing to grep — no API changed. Only code that (unknowingly) relied on the mid-transaction
retry is affected: if a transaction block now fails with a driver connection error where it
previously appeared to succeed (with silently corrupted transactional semantics), wrap the
**whole** `run_in_transaction` call in an application-level retry.

### Migrate your app

```julia
# ✗ before: a connection drop mid-block silently committed the create OUTSIDE the transaction
# ✓ after: the block raises; retry the whole transaction if the work must survive reconnects
for attempt in 1:3
  try
    PormG.run_in_transaction("db_2") do
      (M.Pit_stops.objects).create(
        "raceid" => 841, "driverid" => 153, "stop" => 3, "lap" => 42,
        "time" => "17:05:23", "duration" => "22.500", "milliseconds" => 22500,
      )
    end
    break   # committed
  catch e
    attempt == 3 && rethrow()
  end
end
```

---

## `DateTimeField` values are canonicalized to UTC — existing **SQLite** rows must be re-normalized once

- **PormG ref**: issue #79 ; `src/Models.jl` (`format_timezone_sql` / `validate_timezone`)
- **Recorded**: 2026-07-13
- **Severity**: breaking (SQLite stored-data format) / behavior fix
- **This is a data change, not a code change** — the PormG API is unchanged; there are no call
  sites to edit. The rollout is a one-time SQLite data re-normalization.

### What changed

`DateTimeField` values are now canonicalized to a single UTC ISO-8601 string
(`yyyy-mm-ddTHH:MM:SS.sss+00:00`) on **both** the write/bind path and the filter path — the
convention Django (`USE_TZ=True`), Rails, and SQLAlchemy already use. Previously PormG stored
offset-bearing strings verbatim (e.g. `auto_now` under `America/Sao_Paulo` was written as
`…-03:00`, and a `Z` / `.0` filter value was passed through unchanged).

- **PostgreSQL** is transparent: `TIMESTAMPTZ` compares by instant, so filters were already
  correct and stored data is unaffected — nothing to do.
- **SQLite** stores datetimes as TEXT and compares them lexicographically, so the old
  non-canonical strings made equality/range filters **diverge from PostgreSQL** whenever the
  filter value's spelling differed from the stored spelling (issue #79). Going forward both the
  stored value and the filter value are canonical UTC, so the comparison is correct — **but
  rows written by the old code are still in their old spelling** and must be re-normalized once.

### Who is affected

- PostgreSQL-only apps → mark `—`.
- SQLite apps whose `DateTimeField` columns are empty or freshly created after this bump → mark `—`.
- SQLite apps with **pre-existing** `DateTimeField` data → run the one-time re-normalization below.

### Re-normalize existing SQLite data (one time)

The read path already reconstructs the correct instant from any offset spelling, so a
read-modify-write through PormG reuses PormG's own parser/formatter and is the safest recipe.
For each SQLite model + `DateTimeField` column:

```julia
# `col` is any DateTimeField column on `M.Thing` (SQLite backend).
for row in M.Thing.objects.values("id", "col").list()
    (ismissing(row[:col]) || row[:col] === nothing) && continue   # skip SQL NULL (surfaces as missing)
    q = M.Thing.objects
    q.filter("id" => row[:id])
    q.update("col" => row[:col])                # re-writing stores the canonical UTC form
end
```

(An equivalent single SQL `UPDATE` that converts each value to canonical UTC works too, but the
read-modify-write above avoids hand-rolling the offset math.) Verify with a `Z`-spelled value
that previously missed on SQLite:

```julia
@assert M.Thing.objects.filter("col" => "2020-01-01T10:00:00Z").exists()  # a known stored instant
```

---

## `distinct().order_by()` — the sort key must be in the projection (raises otherwise)

- **PormG ref**: issue #76 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (new `ArgumentError`)

### What changed

A `DISTINCT` query that orders by a column outside its projection —
`.values("a").distinct().order_by("b")` with `b` not in `values(...)` — now raises a clear
`ArgumentError` on **both** backends. Previously PostgreSQL rejected it with a raw DB error while
SQLite silently ran it, returning rows in a nondeterministic `DISTINCT`/order interaction. Ordering a
`DISTINCT` result by an unprojected column is rejected by PostgreSQL and the SQL standard (SQL Server,
Oracle, DB2, and default-mode MySQL all reject it); PormG now makes SQLite conform too. The guard
matches the resolved SQL *expression*, so ordering by a *function of* a projected column
(`order_by("created_at__@date")` while only `created_at` is selected) is likewise rejected — that too
is a PostgreSQL error.

### How to find the calls to migrate

Run the app or its tests: the new error reads
`DISTINCT query cannot ORDER BY <col>: it is not in the SELECT DISTINCT projection`. Grep for
`.distinct()` and check each one's `order_by(...)` — every ordered column (or the exact ordering
expression) must also appear in `values(...)`. **Postgres-backed apps already errored on these; only
SQLite-tested queries could have been running silently.**

### Migrate your app

```julia
# ✗ raises: surname is ordered but not projected
M.Driver.objects.values("nationality").distinct().order_by("surname").list()

# ✓ include the sort key in values() (distinct is now over both columns) …
M.Driver.objects.values("nationality", "surname").distinct().order_by("surname").list()

# ✓ … or drop distinct() if you meant "one row per nationality, ordered by an aggregate"
M.Driver.objects.values("nationality", "n" => Count("driverid")).order_by("n").list()
```

---

## bulk ops `copy=` kwarg removed — the pipeline never mutates (and never copies) your DataFrame

- **PormG ref**: issue #132 / PR #137 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking (kwarg removed) / behavior improvement

### What changed

`bulk_insert`, `bulk_copy`, and `bulk_update` no longer accept `copy::Bool`. The old
default (`copy=true`) deep-copied the entire DataFrame on every call; `copy=false` let
ORM-side normalization (default fills, `auto_now` columns) leak into the caller's frame.
The pipeline now works on a **zero-copy wrapper** (shared column vectors): the caller's
DataFrame is **never mutated and never copied**, unconditionally — strictly better than
both old modes. `allocate_primary_keys` is unchanged: `clone=true` still returns an
independent copy (that frame is *returned* to the caller, so it must not alias your
data), and `clone=false` still writes the pk column in place.

### How to find the calls to migrate

Grep each app for `copy=` / `copy =` on `bulk_insert`/`bulk_copy`/`bulk_update` calls
(or just run the app: passing the removed kwarg raises
`MethodError: ... got unsupported keyword argument "copy"`).

### Migrate your app

```julia
# ✗ before
bulk_insert(query, df, copy=true)    # paid a full deepcopy
bulk_update(query, df, columns=["points"], match_on=["id"], copy=false)  # mutated df

# ✓ after — just drop the kwarg; no-mutation is now the unconditional contract
bulk_insert(query, df)
bulk_update(query, df, columns=["points"], match_on=["id"])
```

If an app relied on `copy=false` to *receive* the injected columns (e.g. reading
`df.updated_at` after the call), that back-channel is gone — read the values back
through a query instead.

One subtle semantics shift: the old `copy=true` gave the bulk op a private *snapshot*
of your data; the zero-copy wrapper reads your live column vectors **during** the call.
Don't mutate the DataFrame from another task while a bulk op is executing on it (this
was never supported — it just happened to be masked by the default deepcopy).

---

## `bulk_update(match_on=)` — pairs removed; `columns=` is the single df→field mapping point

- **PormG ref**: issue #107 / PR #135 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking

### What changed

`match_on=` no longer accepts `"df_col" => "model_field"` pairs. It takes **bare model
field names** only; `columns=` is now the **single place** a DataFrame column is mapped
to a model field ("one border crossing"). A field listed in both `columns=` and
`match_on=` is used for **matching only — it is never SET** (this was already true).
A bare `match_on` name resolves its source column **mapping-first**: the `columns=`
mapping when declared (authoritative — a same-named DataFrame column is ignored with a
warning), otherwise a DataFrame column with the field's own name.

### How to find the calls to migrate

Run the app or its tests: every old pair raises
`bulk_update: match_on= no longer accepts "df_col" => "model_field" pairs (DEPRECATED API)`
with the exact rewrite. Or grep for `match_on` and inspect any entry containing `=>`.

### Migrate your app

```julia
# ✗ before
bulk_update(query, df,
    columns  = ["new_score" => "points"],
    match_on = ["record_id" => "id"])

# ✓ after — the pair moves to columns=; match_on keeps the bare field name
bulk_update(query, df,
    columns  = ["new_score" => "points", "record_id" => "id"],
    match_on = ["id"])
```

Bare-name calls (`match_on = ["id"]` with an `id` DataFrame column, or relying on the
primary-key fallback) need no change.

---

## `SQLOrder` orientation is now whitelisted — only `"ASC"`/`"DESC"` (case-insensitive) construct and render

- **PormG ref**: issue #77 / PR #133 ; `src/querybuilder/types.jl`, `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (new `ArgumentError`; closes an injection seam)

### What changed

A directly constructed `SQLOrder` used to accept **any** string as `orientation` and interpolate
it verbatim into the rendered `ORDER BY` — a SQL-injection seam for apps forwarding a
user-controlled sort direction. Every construction path (and render, guarding post-construction
mutation) now normalizes (`uppercase` + `strip`) and whitelists against `"ASC"`/`"DESC"`, raising
`ArgumentError` for anything else. The documented string API — `.order_by("field")` /
`.order_by("-field")` — was always safe and is unchanged.

### How to find the calls to migrate

Grep the app for direct `SQLOrder(` construction. Only call sites passing a *dynamic*
(user- or data-derived) `orientation` need action; literal `"ASC"`/`"DESC"` in any case keep
working.

### Migrate your app

```julia
# ✗ before — a user-controlled direction string reached the SQL verbatim
dir = params["dir"]   # e.g. "ASC; DROP TABLE results" used to render as-is
query.order_by(SQLOrder(SQLField("points", "points"); orientation = dir))

# ✓ after — map untrusted input onto the whitelist yourself (or handle the ArgumentError)
query.order_by(SQLOrder(SQLField("points", "points");
    orientation = lowercase(dir) == "desc" ? "DESC" : "ASC"))
```

---

## Pool exhaustion now raises typed `PoolTimeoutError`; expansion ceiling raised to `pool_size × 10`

- **PormG ref**: issue #37 / PR #129 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (error type changed; pool sizing change)

### What changed

Exhausting the connection pool used to throw a **bare `String`** after a noisy busy-retry loop.
Both the PostgreSQL and SQLite acquire paths now throw `PormG.PoolTimeoutError` (exported; fields
`adapter` / `pool_size` / `max_size` / `attempts` / `elapsed`, with a "raise pool_size" remedy in
`showerror`). The lazy expansion ceiling grew from `pool_size × 5` to `pool_size × 10` (default
pool: 3 base → up to 30 on demand; idle footprint unchanged), and per-retry logging dropped to
`@debug` — a single actionable `@warn` fires only when the pool hits its ceiling.

### How to find the calls to migrate

Grep the app for `catch` blocks that match the old exhaustion message as a string
(e.g. `occursin("No available"` …). Most apps have none — then there is nothing to change; the
new error type and quieter logs just apply.

### Migrate your app

```julia
# ✗ before — the only way to detect exhaustion was string-matching a bare String throw
catch e
    e isa String && occursin("No available", e) && back_off()

# ✓ after — catch the typed error; consider raising pool_size in connection.yml if it fires
catch e
    e isa PormG.PoolTimeoutError || rethrow()
    back_off()
```

---

## `order_by` on nullable columns — NULL placement normalized to PostgreSQL's convention on both backends

- **PormG ref**: issue #75 / PR #120 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (result order can change on SQLite)

### What changed

Top-level `ORDER BY` used to render a bare `expr ASC|DESC`, and PostgreSQL and SQLite default
NULLs to **opposite ends** — so ordering a nullable column returned different rows per backend,
and with `.first()` / `.page()` that changed *which* rows you got. PormG now emits an explicit
NULLS clause matching PostgreSQL's default on **both** backends: ASC → `NULLS LAST`,
DESC → `NULLS FIRST` (SQLite < 3.30.0 gets an equivalent portable `(expr IS NULL)` prefix).
Per-term override: `SQLOrder(field; nulls = :first | :last)`. Window `OVER(...)` ordering is
**not** yet normalized (follow-up pending).

**PostgreSQL-backed apps see no change.** SQLite-backed apps: any `order_by` on a nullable key
may now sort NULL rows to the other end.

### How to find the calls to migrate

No API change and nothing errors. In SQLite-backed apps, review `order_by` calls on **nullable**
columns whose consumers depend on row order — `.first()`, pagination, "top N" reports.

### Migrate your app

```julia
# Only if the app depended on SQLite's old NULLS-first-on-ASC ordering — pin it explicitly:
using PormG.QueryBuilder: SQLOrder, SQLField

M.Driver.objects.values("surname", "nationality").order_by(
    SQLOrder(SQLField("nationality", "nationality"); orientation = "ASC", nulls = :first)
).list()
```

---

## `bulk_copy` — field formatters now applied; `""` and `missing` no longer collapse to NULL

- **PormG ref**: issue #86 / PR #115 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (persisted values can differ)

### What changed

`bulk_copy` wrote **raw** DataFrame values (each field's formatter result was validated, then
discarded), so datetime/bool/float values could silently diverge from what `bulk_insert` /
`create()` store; and the COPY payload carried no NULL marker, collapsing `""` and `missing`
into the same NULL. It now formats every cell exactly like `bulk_insert` and serializes with a
`\N` NULL sentinel: `missing` → SQL `NULL`, `""` → empty string, and the two round-trip
distinctly.

### How to find the calls to migrate

No API change. Review `bulk_copy` call sites that (a) pre-formatted datetimes/bools/floats to
compensate for the old raw write — the workaround is now redundant (but harmless), or
(b) relied on empty strings being stored as NULL.

### Migrate your app

```julia
# The old behavior stored NULL for BOTH of these; they now persist differently:
df = DataFrames.DataFrame(surname = ["Senna", "Prost"], code = ["", missing])
bulk_copy(M.Driver.objects, df)   # row 1 code → '' (empty string), row 2 code → NULL

# Keep the NULL semantics only where you actually want it — coerce before the call:
df[!, :code] = map(x -> !ismissing(x) && x == "" ? missing : x, df[!, :code])
```

---

## Template for new entries

<!--
Copy the block below into the `## Unreleased` section at the top of the log for each new
breaking/behavior change. Do NOT bump `Project.toml` — the version moves once, at cut time
(the `/pormg-cut-release` skill rewrites `Version: Unreleased` → the release number).

## `<api>` — <one-line summary of the change>

- **Version**: Unreleased
- **PormG ref**: <issue / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```

-->
