# TODO — issue index

> **Open work now lives in [GitHub Issues](https://github.com/PingoLee/PormG.jl/issues).**
> This file is a curated index of **open work only**, grouped by the historical TODO sections, so the
> roadmap stays readable in-repo. Edit the **issues** for status/discussion; this file only needs
> updating when an issue is opened or closed. When an issue closes, its line is **removed** here —
> the history stays on the closed issue.

Focus on parity with Django-style ORM capabilities and PostgreSQL power features.

## 🚀 High Priority: Core ORM Parity

- [#25](https://github.com/PingoLee/PormG.jl/issues/25) — Advanced Query Expressions: F-expression date arithmetic (`Day(30)`/`Interval`) + cross-DB date/time test coverage
- [#48](https://github.com/PingoLee/PormG.jl/issues/48) — Query inspection tooling: `:inspection` mode, metadata enrichment, SQL formatting, EXPLAIN
- [#26](https://github.com/PingoLee/PormG.jl/issues/26) — Full Transaction Control: savepoints + row-level locking (`select_for_update`)

## 🐘 PostgreSQL Specific Enhancements

- [#27](https://github.com/PingoLee/PormG.jl/issues/27) — JSONB support: lookups + containment/overlap operators
- [#28](https://github.com/PingoLee/PormG.jl/issues/28) — Specialized data types: `ArrayField` + `INET`/`CIDR`
- [#29](https://github.com/PingoLee/PormG.jl/issues/29) — Advanced indexing: GIN/GiST/BRIN, functional, partial
- [#30](https://github.com/PingoLee/PormG.jl/issues/30) — Bulk upsert: `update_or_create` via `ON CONFLICT`
- [#31](https://github.com/PingoLee/PormG.jl/issues/31) — Full-Text Search (`tsvector`/`tsquery`)

## 🛠 Project Infrastructure & Quality

> ⚠️ **do BEFORE the first General-registry publish** — the items below lock in contracts that are
> cheap to settle now (zero published users) but become breaking/irreversible afterward.
> **Sequence:** **Tier 1** (irreversible user-data — migration-format / tracking-table contract and
> the frozen schema conventions) and **Tier 2** (#34 adapter decoupling → #35 export curation) are
> both settled and merged — as is field-name **case preservation** (#57), its lowercase
> **convention** (#58), and the full **`db_column` authority** family: authoritative DDL/queries
> (#50), string FK targets (#62), and ManyToMany/CTE join keys (#64) — all merged. Remaining gating
> work: the infrastructure items below.

- [#36](https://github.com/PingoLee/PormG.jl/issues/36) — Isolated PostgreSQL migration fixture (`db_test_migration_pg/`)
- [#37](https://github.com/PingoLee/PormG.jl/issues/37) — Investigate PG pool exhaustion under remote-latency integration runs

## 🏗 Phase 2: Operational Maturity

- [#38](https://github.com/PingoLee/PormG.jl/issues/38) — Advanced migration support (renames, targeted execution, rollback, deployment safety, data migrations, schema objects)
- [#65](https://github.com/PingoLee/PormG.jl/issues/65) — Unify the model-load lifecycle: one "load + resolve" entry point for runtime + migrations (Django `apps.populate()` analog; single-sources FK/O2O/M2M target resolution)
- [#39](https://github.com/PingoLee/PormG.jl/issues/39) — SQLite parity with PostgreSQL features
- [#60](https://github.com/PingoLee/PormG.jl/issues/60) — Add MySQL / MariaDB backend support (third driver via the weakdep-extension seam)
- [#40](https://github.com/PingoLee/PormG.jl/issues/40) — Documentation expansion (F1 examples, PostgreSQL power-user guide)
- [#41](https://github.com/PingoLee/PormG.jl/issues/41) — Performance & type stability (typed returns, fast JSON, IO allocation, benchmarking, thread-safety audit)

## 🔍 Review possible issues

- [#43](https://github.com/PingoLee/PormG.jl/issues/43) — ⚠️ Shared mutable state in read/copy path: `.list()` mutates the live query, `.copy()` aliases CTE state (pre-publish)
- [#44](https://github.com/PingoLee/PormG.jl/issues/44) — CTE ergonomics: reference CTE fields via `F()` in the main query
- [#68](https://github.com/PingoLee/PormG.jl/issues/68) — Refactor `_build_row_join`: collapse duplicated first-hop/loop join resolution (tech debt; behavior-preserving)
- [#70](https://github.com/PingoLee/PormG.jl/issues/70) — `Model_to_str` silently drops a field when rendering throws (swallowed catch)
- [#73](https://github.com/PingoLee/PormG.jl/issues/73) — `bulk_update` parameters snapshot/restore leaves partial state on mid-chunk failure
- [#80](https://github.com/PingoLee/PormG.jl/issues/80) — Dead identifier-whitelist helpers + skill-doc claims a contract the code doesn't exercise (`documentation`)
- [#108](https://github.com/PingoLee/PormG.jl/issues/108) — `getproperty` on a field object (`PormGField`) with an absent property infinitely recurses → `StackOverflowError`

## 🧮 SQL correctness & dialect alignment

- [#75](https://github.com/PingoLee/PormG.jl/issues/75) — ⚠️ `ORDER BY` NULL placement diverges PG vs SQLite (no `NULLS FIRST/LAST`) (pre-publish)
- [#76](https://github.com/PingoLee/PormG.jl/issues/76) — `SELECT DISTINCT … ORDER BY <unselected column>` errors on PG, runs on SQLite
- [#77](https://github.com/PingoLee/PormG.jl/issues/77) — `SQLOrder.orientation` interpolated unvalidated into `ORDER BY` (latent SQL injection; `security`)
- [#78](https://github.com/PingoLee/PormG.jl/issues/78) — Case-insensitive lookups (`icontains`/`istartswith`/`iendswith`) diverge PG vs SQLite on non-ASCII text
- [#79](https://github.com/PingoLee/PormG.jl/issues/79) — `DateTimeField` equality/range filters can diverge PG vs SQLite (format-sensitive TEXT comparison)

## 🧱 Migration apply / rollback safety

- [#81](https://github.com/PingoLee/PormG.jl/issues/81) — Migrations are not idempotent and checksum is never verified (re-apply landmine, no drift detection)
- [#82](https://github.com/PingoLee/PormG.jl/issues/82) — SQLite table-rebuild drops secondary indexes and runs with FK enforcement off (data-loss risk)
- [#83](https://github.com/PingoLee/PormG.jl/issues/83) — SQLite `drop_foreign_key` is broken (undefined `get_constraints`) and embeds `BEGIN/COMMIT` that breaks migration atomicity
- [#87](https://github.com/PingoLee/PormG.jl/issues/87) — `migrate()` defaults `interactive=true` and blocks on `readline()` in non-interactive/CI contexts
- [#89](https://github.com/PingoLee/PormG.jl/issues/89) — Migration statement ordering has no FK-dependency topological sort (`CREATE`/`DROP` order survives by accident)
- [#90](https://github.com/PingoLee/PormG.jl/issues/90) — Migration advisory lock keyed on config folder, not database identity (two configs on one DB don't mutually exclude)

## 📦 Bulk insert / update / copy

- [#84](https://github.com/PingoLee/PormG.jl/issues/84) — Bulk insert/update has no parameter-limit-aware chunking (overflows SQLite 999 / PG 65535)
- [#85](https://github.com/PingoLee/PormG.jl/issues/85) — `bulk_update` is non-atomic on SQLite (multi-chunk partial update on mid-chunk failure)
- [#86](https://github.com/PingoLee/PormG.jl/issues/86) — `bulk_copy` NULL/empty-string collision + formatter bypass (silent data divergence vs `create`/`bulk_insert`)
- [#88](https://github.com/PingoLee/PormG.jl/issues/88) — SQLite `allocate_primary_keys` is racy outside `run_in_transaction` (read-then-write; reservation no-op at tx depth 0)

## 🔗 Custom Join (`cjoin`) Gaps

- [#45](https://github.com/PingoLee/PormG.jl/issues/45) — `cjoin` gaps: arbitrary ON clauses, cross-table `F()` in ON, SQL functions in ON (`strftime`/`EXTRACT`)

## 🐞 SQLite worker / pool stability

- [#47](https://github.com/PingoLee/PormG.jl/issues/47) — SQLite connection / file-handle release at teardown (`close_pool!` leased-close + non-idempotent `_close_db!`)
- [#71](https://github.com/PingoLee/PormG.jl/issues/71) — Failed ROLLBACK returns a possibly-dirty connection to the pool
- [#72](https://github.com/PingoLee/PormG.jl/issues/72) — `acquire_connection` throws raw `String`s and spins ~30s on a permanently-bad connection

## 🔮 Future Considerations

- [#46](https://github.com/PingoLee/PormG.jl/issues/46) — Parameterize LIMIT/OFFSET
- [#59](https://github.com/PingoLee/PormG.jl/issues/59) — Model `db_table` option: pin an explicit (mixed/upper-case) table name (Django `Meta.db_table` analog; table-level sibling of #50, pairs with #57)
- [#92](https://github.com/PingoLee/PormG.jl/issues/92) — 💬 Design: explicit correlated-subquery aggregates (no auto-magic) — the supported fix for #74 fan-out

---

*Completed work is not listed here — see [closed issues](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aissue+is%3Aclosed). (Work that predates the issue tracker lives in git history.)*
