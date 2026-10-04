---
name: pormg-migrations-development
description: "Implement or refactor migration planning and execution in src/Migrations.jl and src/migrations/: schema reconciliation, migration history, dry-run/status, destructive guards, migration docs, and CI workflows."
---

# PormG Migrations Development

## Purpose

Use this skill for work on schema reconciliation, migration planning, runtime history, dry-run output, destructive guards, repair flows, and migration-related documentation.

This skill is for the migration subsystem itself, not for ordinary ORM query behavior.

## Use This Skill For

- Editing `src/Migrations.jl`
- Editing `src/Generator.jl` when the work affects migration/bootstrap setup
- Editing `src/migrations/introspection.jl`
- Editing `src/migrations/planner.jl`
- Editing `src/migrations/runner.jl`
- Updating migration docs and migration-focused tests
- Investigating `init_migrations()`, `status()`, `dry_run()`, `makemigrations()`, `migrate()`, `mark_applied()`, `mark_failed()`, and `remove_migration_record()`

## Bootstrap and system model

- Treat `Generator.create_db_folder_and_yml()` as the expected bootstrap path for creating `db/connection.yml` before migration workflows touch project config
- PormG uses a state-based migration engine that reconciles current Julia model state against the live database schema via introspection
- **State-based, not Django-graph — do not port Django assumptions.** `makemigrations` computes `diff(live-DB introspection, models file)` and **never reads previous migration files**; there is no dependency graph or replay. `applied_migrations/` is an **inert audit trail**, not a source of truth — editing an applied file changes nothing downstream. The *pending* plan is not inert in the same way: its SQL is what `migrate` runs, and its header comments are read and enforced (see *Plan-header comments* below). "Drift" that matters is live-schema-vs-models (surfaced by `check(db; kinds = [:schema_drift])` and the next `makemigrations`), not migration-file checksum divergence. `status()` reports history-table health only, never schema drift (#733). Concept doc: `docs/src/migrations/index.md` → *What this means in practice*.
- Keep docs, tests, and CLI guidance explicit about unsupported or partial behavior (the rule lives under *Unsupported behavior* below)

## Core Rules

### Runtime source of truth

- Treat `pormg_migrations` as the canonical runtime history table
- `run_once` data steps live in their own table, `pormg_migrations_data` (#740), so the frozen
  `pormg_migrations` v1 column set stays untouched
- Files in `applied_migrations/` are useful artifacts, but not the primary state source

### Recommended operator flow

Keep docs, tests, and implementation aligned with this sequence:

1. `init_migrations()`
2. `status()`
3. `makemigrations()`
4. `dry_run()`
5. `migrate()`
6. `run_once()` for a Julia data step — a backfill after `migrate()`, an index step before it

`status()` and `dry_run()` are part of the normal operator flow, not optional extras.

### Destructive actions

- If `dry_run()` reports destructive SQL, require explicit `destructive=true`
- Tests and docs must reflect that guard
- Never normalize destructive behavior as implicit or safe by default

### Plan-header comments

The plan is read as data, never executed (#710). Everything `makemigrations` knows that the SQL
cannot carry rides in `#` comments between the `# pormg-migration-format:` marker and the first
`import`, which `dry_run` and `migrate` read back by line scan:

| Line | Issue | Read by |
|---|---|---|
| `# pormg-models-file:` / `# pormg-models-sha256:` | #736 | `_plan_models_file` — which models file to snapshot |
| `# pormg-lossy-alter:` | #803 | `_plan_lossy_alters` — the row pre-check and the destructive opt-in |
| `# pormg-schema-table:` | #739 | `_plan_schema_tables` — the schema precondition `migrate` enforces |

A new kind of header line follows the same contract, or it breaks one of them:

- **Constants beside the others** in `src/migrations/runner.jl` (`*_HEADER` plus an anchored, CRLF-tolerant `*_RE`).
- **Outside the checksum.** The checksum covers the ordered SQL only; a header must never change it.
- **Values escaped** with `escape_string`, so a catalog name cannot end the field or the comment line.
- **Read with `open(path) do io … eachline(io)`**, stopping at the first `import `. A bare
  `eachline(path)` that breaks early leaks the handle and fails every later `mv` with EBUSY on Windows.
- **Fail closed.** A damaged line raises `InvalidMigrationError`. Detect loosely and parse strictly
  (`SCHEMA_TABLE_HEADER_LOOSE_RE`), so a mangled line is refused instead of skipped.
- **Absent means "as before".** A plan without the line — every plan written before it existed —
  must behave exactly as it did. That is what keeps it additive within format v1.
- **Document it** in `docs/src/migrations/stability.md`, next to the existing header paragraph.

Tests that pin the exact header layout (`test_makemigrations_models_file.jl`) must expect the
`# pormg-schema-table:` lines that every `makemigrations` plan now carries.

### The schema fingerprint is a persisted format

`_schema_table_fingerprint` digests a `LiveTable` through an explicit serialization: every
`ColumnSpec` field except `raw`, plus indexes, composites and CHECKs, names included. Plans in flight
carry those digests, and `migrate` compares them in another process, maybe on another PormG version.
So:

- **Adding, removing or renaming a field** in `ColumnSpec`, `LiveTable`, `LiveComposite`, `LiveCheck`
  or any column-IR struct (`src/column_ir.jl`) changes every fingerprint. The pinned digest in
  `test/unit/test_plan_schema_fingerprint.jl` then fails, on purpose. **Do not just re-pin it.** Bump
  `_SCHEMA_FINGERPRINT_VERSION` and add an upgrade-log entry: every reviewed plan generated before
  the upgrade will be refused after it, and its users must regenerate.
- Never serialize through `repr` or `Base.hash`. Neither is stable across processes or package
  versions (`repr(::ZonedDateTime)` belongs to TimeZones). Write each value out explicitly.
- The fingerprint is deliberately **stricter than the planner's diff**: names count, because the
  plan's statements name the objects. Do not loosen it to match `==` on `ColumnSpec`.

### `migrate` ordering invariants

- **The #81 guard runs before the precondition**, inside the lock (PostgreSQL: before `BEGIN`;
  SQLite: inside `BEGIN IMMEDIATE`). A plan that is already applied has changed its own tables, so
  it is archived as `:already_applied`, never refused.
- **A pre-lock check reads the schema first and the history second.** Read the other way round, a
  second instance booting with the same plan can miss the first one's `applied` row and still see
  its committed DDL — and refuse an applied plan. Both engines commit the DDL and the history row
  together, which is what makes schema-then-history safe.
- **A refusal before any plan statement runs writes no `failed` row** (SQLite: `attempted` stays false).
- **Reads inside the SQLite migration transaction go through `Configuration.with_tx_context(pool, conn)`**,
  never `fetch(...; conn = conn)`, which hands the connection back to the pool mid-transaction (#139).

### Data steps (#740)

Two homes, both settled by the maintainer: a hand-written plan entry labelled `Data (pre): …` /
`Data (post): …`, or `Migrations.run_once(f, db, name)` outside the plan. A `RunPython`-style plan
entry stays ruled out: the plan is data, never executed (#710).

**Plan data steps.**

- `_order_statements` is a thin wrapper over `_ordered_entries`, which keeps each label beside its
  SQL. `Data (pre)` is the first bucket and `Data (post)` the last, after `Create index`. A new bucket
  goes between them, never outside.
- The data checks come **first** in the label `if` chain: `"Data (pre): Rename field …"` must not
  reach the `contains("Rename field")` arm.
- A plan with no data label must order — and so checksum — byte-for-byte as before;
  `test_migration_format_v1` pins it.
- **The planner must never generate a label matching `DATA_STEP_LOOSE_RE`** (`^\s*data\s*\(`,
  case-insensitive). It would be refused, or moved to the data bucket.
- Detection is loose, parsing strict (`_data_step_kind`): a near-miss is `InvalidMigrationError`,
  never the catch-all bucket.
- **Every path that replaces or discards the pending plan calls `_refuse_overwriting_data_steps`.**
  Today that is both arms of `_write_pending_plan`. Data steps exist only in that file, and the
  empty-diff arm is the likely one: models and database already agree.
- **`handled=pre` (#897, maintainer's pick of option (d)).** `migrate`'s lossy row pre-check (#803)
  counts on the live database before any statement runs, so a `Data (pre)` step cannot satisfy it on
  its own. The operator marks the finding's header line `handled=pre`. The finding is still counted
  and shown (`dry_run`'s *HANDLED* section), and `_failing_alters` skips it, so the database enforces
  the change after the step. The rules, each fail-closed: `pre` is the only value; only a `:rows`
  kind can carry it, and not `:add_not_null` (a `pre` step runs before the column exists); a
  near-miss key or a `handled=` swallowed into another field (spaces typed for the tab) is refused
  as damaged; a plan marking one with no `Data (pre):` entry is refused (`_refuse_unbacked_handled`).
  `makemigrations` never writes it. A PormG that predates the field ignores it as an unknown key,
  so it still refuses: the safe direction. Do not widen it into parsing the step's SQL to infer
  which tables it fixes (option (c), rejected on #897).

**`run_once` invariants.**

- Validate the name and `lock_wait` before the `change_db` gate, then refuse inside an open
  transaction on the same pool (`TransactionError`, the `atomic(durable = true)` rule). It needs no
  `_require_folder_backed`: it reads no files.
- PostgreSQL: everything under `_migration_lock_key(settings)`, the **same key as `migrate`**.
- SQLite with `transaction = true`: the record check runs **inside** `run_in_transaction`'s
  `BEGIN IMMEDIATE` (the #737 shape). `test_data_migrations.jl` pins it with a real cross-process race.
- SQLite with `transaction = false` is deliberately **not** serialized. Do not wrap `f` in
  `with_sqlite_write_lock`: it stalls every writer in the process and deadlocks on a task `f` waits
  for. A runner that loses the race to record the name gets `IntegrityError` on the UNIQUE name, and
  that maps to `:already_applied`.
- The record is written with `fetch(pool, sql; params)` and **no `conn`**, so inside the transaction
  context it commits or rolls back with `f`.
- A PormG-owned table must sit under the `pormg_migrations` ignore prefix, as
  `pormg_migrations_data` does, or be added to every ignore list. Otherwise `makemigrations` plans
  to DROP it. The lists match by prefix (`_is_ignored_table`).
- An index a step creates must be declared on the model (`db_index = true`), or the next
  `makemigrations` drops it. The schema fingerprint counts indexes, so such a step runs **before**
  `migrate` at boot. The docs say so; keep them saying it.

### Unsupported behavior

- Do not ship a public verb that cannot succeed. `migrate_to(version)` was exported and documented
  while it could only throw: the state-based engine has one pending plan, so there is no version to
  migrate "to". It was removed rather than kept as a stub (#732). Leave a feature unexported until it works
- If a feature is partial, keep the contract explicit instead of implying Django-like completeness

### CI and automation

- Use `interactive=false` to bypass rename confirmation prompts in non-interactive environments
- If the generated plan contains destructive SQL, CI must opt in explicitly with `destructive=true`

## Test Strategy

### Integration scope

Use integration tests when validating:

- migration status behavior
- dry-run output semantics
- destructive guard behavior
- real schema reconciliation against PostgreSQL or SQLite
- end-to-end migration lifecycle behavior

Likely files:

- `test/integration/test_migration_bootstrap.jl`
- `test/integration/common_migration_setup.jl`

### Unit scope

Use unit tests when validating:

- diff planning
- rename detection hints
- destructive classification
- checksum generation
- dry-run result shaping
- internal ordering logic
- plan-header round trips, the schema precondition and `status()` supersede
  (`test/unit/test_plan_schema_fingerprint.jl` — hermetic SQLite; its PostgreSQL twin is a testset in
  `test/integration/test_migrate_boot.jl`)
- data-step buckets, the `makemigrations` refusal and `run_once`
  (`test/unit/test_data_migrations.jl` — hermetic SQLite, including a cross-process race against a
  child process holding `BEGIN IMMEDIATE`; the PostgreSQL lock, rollback and `CONCURRENTLY` cases are
  a testset in `test/integration/test_migrate_boot.jl`)

### Isolation discipline

- Use isolated migration environments for destructive tests
- Prefer `db_test_migration_pg/` or equivalent dedicated fixtures for PostgreSQL migration cycling

### Test Writing Standard

Follow the canonical [PormG Test Writing Standard](../../instructions/test-writing.md): standardized `@testset` header comments and heavily commented test logic.

## Documentation Rules

- Keep migration docs synchronized with implementation in the same change when practical
- If docs claim a public API, verify it exists in `src/Migrations.jl` and is exercised by at least one test
- Keep limitations explicit, especially for destructive rollback and unsupported targeted execution paths
- Build docs when migration-facing public behavior or examples change

## Planner internals: column identity

`makemigrations` decides *changed / unchanged* on a canonical column IR — never by comparing
`PormGField` structs, and since #522 never by *building* one for the live side either. The IR's
nouns are `ColumnSpec` / `ColumnDelta` (`src/column_ir.jl`, layer 1). The **declared** side compiles
through `column_spec(field, conn)` (`src/migrations/column_spec.jl`); the **live** side is read
straight into a `LiveTable` of `ColumnSpec`s by the readers (`read_live_schema`,
`src/migrations/introspection.jl`), and the planner's whole field diff is one call to
`column_delta(field, old_spec, conn)` inside `_alter_table_fields`. Since #507 phase 2 every plan
ACTION derives from that same delta — see *From delta to actions* below.

**Why an IR at all, and why the readers had to change.** Introspection used to reconstruct a
`PormGField` from the live schema through a type map that returned *one* struct per rendered type,
so the declared struct could never be recovered: `CharField` / `URLField` / `SlugField` all came
back as one struct, and on SQLite a `BIGINT` column came back as `sIntegerField`. Struct identity is
therefore not column identity. Phase 1 closed the gap by construction — `column_spec` renders
through `Dialect._get_column_type`, the same function the DDL path uses, so **every struct that
renders the same column compiles to the same spec** — and phase 3 (#522) removed the round trip: the
readers compile catalog facts (`format_type` / `PRAGMA table_info`, the CHECK clauses, `attidentity`,
the constraint tables) directly, the forward type maps are gone, and **no reader choice can be a
schema opinion the planner acts on**. The one place a struct is still chosen from a spec is
`field_from_spec` — `inspectdb`'s compiler, which has to write a models file — and it is off the
diff path by design; where the declaration vocabulary cannot say what a column is (a lengthless
`varchar`, a type outside the closed set) it picks the constructor default and **warns**, never
silently. Both readers share `_key_arm` (the uuid-key / relation / sized-textual-key / `IDField`
arm order of #409) and the default coercion `_coerce_default`, so the two engines describe one
schema the same way, and `Migrations.check` asks those same helpers instead of mirroring them.

Two consequences worth knowing when reading a reader:

- **A live fact is read, not inferred.** A `SMALLINT` without its `>= 0` CHECK compiles without the
  check; a relational column's `db_index` is whether the catalog lists a single-column index; a
  catalog type PormG never renders (`character(n)`, an array) is `CUnsupported` and does not equate
  to a declared `TextField`. Each surfaces as a one-time plan on an adopted schema; tables PormG
  wrote always carry the facts. The exception is stated once, beside `_column_identity(::PormGSQLite)`:
  a SQLite integer key compiles to the identity whether or not it carries `AUTOINCREMENT`, because
  `IDField` is the only declarable integer key and it always renders the token — a rowid key without
  it has no declaration that could ever equal it.
- **The planner's live side is a `LiveTable`, and a `PormGModel` is only an adapter for it.**
  `get_migration_plan(::Vector{PormGModel}, …)` compiles each model through `live_table` (the
  declared-side compiler plus `db_index` / `cache["index"]`); the unit tests and the golden plan
  corpus hand-build the live side that way, `makemigrations` never does.

**Three rules worth knowing before editing it:**

1. **Engine equivalence is decided in `parse_canonical_type`, once** — Atlas's per-driver normalizer,
   run on both sides before the diff — and since #522 it is also the readers' whole type
   vocabulary, so the catalog aliases in it (`int4`, `bigserial`, `character varying`,
   `timestamp(6) with time zone`) are load-bearing, not conveniences. A collapse belongs there only
   when it is *forced*: two spellings become one `CanonicalType` when PormG renders both as the same
   string, so the database cannot tell them apart. SQLite `BIGINT ≡ INTEGER` qualifies
   (`sqlite_type_map_reverse` maps both to `INTEGER`); SQLite `SMALLINT` vs `INTEGER UNSIGNED` does
   **not**, because PormG writes both verbatim and a change between them is observable. Collapsing
   what the engine merely *stores* alike would silently stop planning a real change.
2. **`on_delete` is a schema fact**, carried in `ForeignKeyRef(table, binding, column, on_delete)`.
   A change there is a **constraint delta, never a column ALTER** — it reaches the plan as DROP +
   ADD CONSTRAINT. It used to be answered four different ways (`_compare_model_field` skipped it,
   `_NON_SCHEMA_FIELD_ATTRS` skipped it, `_fk_definition_changed` and `_fk_constraint_action` each
   diffed it); all four are gone, the compiler answers it once, and one function acts on it. It matches Django: `on_delete` is not in `Field.non_db_attrs`, and on Django `main`
   `ForeignObject` skips it only when the action is *not* a `DatabaseOnDelete` variant — *"Database-
   level on_delete options are part of the column definition."* PormG renders `ON DELETE` into every
   constraint (#292), so it only ever has that flavour.
3. **`db_index` is not in the IR at all.** `index_actions` owns it, and on SQLite a non-empty column
   delta means a full table rebuild that re-emits every secondary index — so an index-only
   difference must leave the delta empty or the rebuild would duplicate the `CREATE INDEX` beside it
   (#82/#325).

**One classification, one place.** `NON_DB_ATTRS` (no DDL expresses it) and `SCHEMA_ATTRS` (the
compiler reads it) replace `_NON_SCHEMA_FIELD_ATTRS` and the two other lists that disagreed with it.
Named after Django's `Field.non_db_attrs`. `test/unit/test_column_spec.jl` fails when a `PormGField`
gains a slot in neither — the same guarantee `field_kwargs_snapshot.txt` gives `Model_to_str`, with
no snapshot to regenerate.

**From delta to actions.** `column_delta(new_field, old_field, conn)` returns a `ColumnDelta` — both
sides' `ColumnSpec` plus the facets that differ, a subset of `COLUMN_DELTA_SLOTS` — and **that value
is the whole input to every action the plan takes about a column.** Phase 1 translated it back into
field-attribute symbols through an `alter_attrs` adapter so the action code could stay untouched;
phase 2 deleted the adapter, and with it each action site's private opinion of a fact the compiler
had already settled. Four bugs in one week came from those opinions: #498 (a re-pointed key planned
nothing), #504 (a rename added a second constraint), #514, #515.

Four rules follow, and they are the ones to check a change against:

1. **`Dialect.alter_field` renders one fragment per changed slot.** The decision of *which* fragments
   comes only from the delta; the SQL text may still read the field (a column type, a `USING` cast,
   a decimal precision). Reading a field to *re-decide* whether to emit something is the regression.
   There is no `IMPLEMENTED` allowlist and no "not implemented" warning any more — the slot set is
   closed by type (`ColumnDelta` validates its facets), and `test_plan_actions_golden.jl` walks
   `COLUMN_DELTA_SLOTS` and calls the renderer for each.
2. **`:reference` is a constraint action, never a column ALTER.** `alter_field` has no branch for it
   and needs none: a slot with no branch renders nothing, so a reference-only delta returns `""` and
   the step is dropped, while `_fk_constraint_action(new_spec, old_spec)` plans DROP + ADD CONSTRAINT.
   That absence replaced the `_FK_IDENTITY_ATTRS` filter every call site had to remember. One
   function answers `:add` / `:drop` / `:repoint` / `:none` for the alteration path, the rename
   branch and the deletion loop alike; `nothing` on the new side is the deletion path.
3. **A rename is the same column change with a new name.** `_plan_column_change!` is the one ordered
   path — FK drop → RENAME COLUMN → the column ALTER or SQLite rebuild if the delta is non-empty →
   FK add. `_alter_table_fields` and the rename branch both call it. An empty delta reduces it to
   RENAME and nothing else; a non-empty one carries the alteration, which is a fix rather than a
   refactor (a rename that also retyped a column used to plan the RENAME alone and defer the retype
   to the next run). Do not re-grow a private copy of this sequence in the rename branch.

   Two contracts inside it are load-bearing, and both were learned by shipping the bug first:

   - **`delta.old_spec.name` is the single source for "the column the live catalog knows".** At plan
     time nothing has executed, so on a rename that is the PRE-rename column — and the FK drop plus
     all four `get_constraints_*` lookups in `Dialect.alter_field` must key on it. A fifth statement
     that needs a constraint name has to read the same field: asking for `field_name` there is how a
     renamed column silently lost its UNIQUE / PRIMARY KEY / CHECK drop, and how a renamed
     `PositiveIntegerField` becoming a `TextField` emitted the retype with a stale `>= 0` CHECK that
     PostgreSQL refuses. `column_delta`'s `old_name` is what puts the name there.
   - **On SQLite the rebuild entry is RELOCATED to the end of the table's plan on every
     registration.** It copies by the DESIRED column names, so it must follow every `RENAME COLUMN`
     and every `ADD COLUMN`; `_configure_order_dict_migration_plan` overwrites a key in place, so
     re-registering without `delete!` leaves it at the first registration's position. A plan-time
     refusal was tried first and rejected: `colect_addition` is a `Set`, so it fired on hash order.
     Since **#556** the `column_renames` map is owned by `_alter_table_fields`, one per table, and
     handed to all **four** producers of that key -- the rename branch, the alteration loop,
     `_add_new_field`, and the rebuild the deletion loop emits when a column cannot be dropped in
     place -- so whichever registration lands last renders with the UNION of the renames. Count the
     producers before trusting that sentence: the first pass at #556 found three and shipped a
     fourth still broken.
     Before that each call carried only its own, and a rename co-occurring with another change to
     that table silently lost the renamed column's index.
4. **`db_index` stays outside the delta**, with `index_actions` (see rule 3 of the previous section).
   That separation is unchanged; what used to follow from it is not. `index_actions` was declared
   AFTER `_alter_table_fields` called `_resolve_table_fields`, so the rename branch had no sink and a
   rename that also flipped `db_index` planned its index action one run later. **#556** moved the
   declaration above that call and threads the list in, so the flip is planned in the same migration
   on both engines. An UNCHANGED `db_index` still plans nothing at all -- `RENAME COLUMN` carries the
   index with it, and re-creating it on every rename is the #515 regression
   `test_rename_unique_index.jl` guards against.

**Where the types live, and why it is not tidiness.** The IR's nouns are layer 1 (`src/column_ir.jl`,
included from `Kernel`) because `Dialect` renders from a `ColumnDelta` and is included *before*
`Migrations` — each submodule resolves `import PormG: …` at include time, so a type defined in
`Migrations` does not exist yet when `Dialect` compiles. That is #239 verbatim. The compiler stays at
layer 3, where `Models` and `Dialect` are reachable: **Kernel holds the nouns, the submodules keep the
verbs.**

**Three review flags, all sharper than what they replace:**

- **An action site that re-inspects the field structs instead of reading the delta.** A
  `field.null` / `field.unique` / `hasproperty(field, :generated)` read used to *decide* whether to
  emit a statement, a second `_fk_constraint_action`, a private copy of the alteration path in the
  rename branch. Reading a field to render SQL text is fine; reading one to re-decide is the flag —
  the fix is to read the `ColumnDelta`, and if it cannot express the fact, the missing fact belongs
  in `ColumnSpec`.
- **A new `isa` on a field struct inside the planner's field diff.** There is now none: the planner
  does no field-type dispatch at all. A new one is a regression against the IR, not a fix —
  `column_spec` is where a field type is interpreted. (Its predecessor rule was "route it to #507";
  #507 phase 1 has landed, so the routing is into the compiler.)
- **A reader building a `PormGField`, or choosing a struct, on the diff path.** Since #522 the
  readers produce `ColumnSpec`s from catalog facts and nothing else; a struct is chosen only in
  `field_from_spec`, for `inspectdb`. A reader that infers a fact from a type spelling (a CHECK from
  `SMALLINT`, an index from a foreign key) has re-created the class the IR closed — read the
  catalog, and if the catalog cannot say it, the fact does not belong in the spec.
- **A new entry in `NON_DB_ATTRS` that hides a real fact.** The list is legitimate for things no DDL
  path emits. It is *not* a place to park an inconvenient difference — check that no renderer writes
  it before adding one, and say so in the comment. The cautionary case is `on_update` / `deferrable`
  / `initially_deferred`: #507 classified them here (correctly — nothing rendered them) with a
  `maxlog` warning so the dropped intent was never silent, and #516 then asked the question the
  classification had deferred and **removed the three keywords outright**. Classifying an attribute
  non-schema answers "can this be a column delta?"; it does not answer "should this be declarable at
  all?" — if the honest answer to the second is no, the entry is a stopgap and needs an issue.

**The two classes this closed.** Convergence churn is the first (below). The second is the ACTION
class — a plan that emits the wrong DDL, or none, for a change it correctly detected: #498, #504,
#514, #515, all inside a week. A new issue in *that* class is a defect in `_plan_column_change!`,
`_fk_constraint_action` or `alter_field`'s per-slot gates, and it is fixed by making the action read
the delta — never by giving one site a private test.

**The churn class this closed.** "`makemigrations` plans DDL forever" / "plans nothing" for a column
nobody changed was one bug shape seen seven times — #325 → #408 → #409 → #417 → #437 → #498 → #503 —
each fixed with a new `isa` escape, a new skip-list entry or a new reconciliation branch. A new issue
in this class is now a **defect in the compiler or in `parse_canonical_type`**, and it is fixed
there. If you find yourself adding a fifth comparator, that is the signal the IR is missing a fact,
not that it needs an exception.

**The missing-subtype shape.** `sForeignKey` and `sOneToOneField` are sibling structs, not a subtype
pair. Four subsystems each missed the second one behind an `isa sForeignKey` gate — the DDL renderer
(#408), the schema readers (#409), the query builder (#418), the planner (#437). Spell the pair once:
`Models.sRelationalColumn` (`src/models/fields.jl`). A new bare `isa sForeignKey` gate is a review
flag. (In the planner's diff the shape is now unrepresentable: the FK/O2O pair over one parent simply
compiles to one `ColumnSpec`.)

## Triage

Identify which stage the issue lives in — **planning, execution, introspection, history tracking,
or convergence** — before editing. That choice picks both the file and the test layer, and they fail
in different ways: a planner bug produces wrong SQL, an introspection bug produces a wrong *diff*
from correct SQL, a history bug leaves the DB right and `pormg_migrations` wrong — and a
convergence bug leaves the DB right *and* the SQL right, yet the next `makemigrations` plans it
again. Convergence is the class described above, and since #507 it has a single home: fix it in
`column_spec` / `parse_canonical_type`, never by adding a comparator or an escape to the planner.

## Verification Commands

Narrowest first. Migration diffs are one of the cases that genuinely owe the **full** suite rather
than a slice (the DDL path only executes in `test_migration_bootstrap.jl`) — see the rung-5 table in
[`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Verify* — and **the full suite needs
the user's explicit permission, every time** ([`general.instructions.md`](../../instructions/general.instructions.md) → *Merge gate*).

```powershell
julia -O0 --project=. -e 'using Pkg; Pkg.test()'                                           # unit — no permission needed
julia -t auto --project=test/integration test/integration/runtests.jl                      # rung 5 — ask first
$env:PORMG_DB="db_sl"; julia -t 1 --project=test/integration test/integration/runtests.jl  # rung 5, SQLite — ask (-t 1 required)
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include("docs/make.jl")'
```

Two traps in this block specifically:

- **`test_migration_bootstrap.jl` cannot be run standalone.** It guards on `:reset_database!`, not
  `:PormG`, so `common_setup.jl` never loads — its own header says it is included from `runtests.jl`
  *after* setup. Reach it through the suite, not by naming the file.
- **The docs build needs `--project=docs`** — the package env carries no Documenter, so
  `--project=. docs/make.jl` fails. Same rule as
  [`general.instructions.md`](../../instructions/general.instructions.md) → *Verification*.

## Anti-Patterns

- Do not treat filesystem archives as the only migration truth
- Do not assume a Django-style migration graph: no ordered dependencies, no file replay, and migration files are audit artifacts (see *Bootstrap and system model*)
- Do not silently allow destructive SQL
- Do not broaden docs ahead of implementation
- Do not test unsupported migration targeting as if it were complete
