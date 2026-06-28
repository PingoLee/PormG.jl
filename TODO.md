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
> **convention** (#58), and **`db_column` authority** (#50), now extended to **string FK targets**
> (#62 — referenced-parent-key resolution). Remaining gating work: the `db_column` completeness
> follow-up (#64 — ManyToMany/CTE join keys) plus the infrastructure items below.

- [#64](https://github.com/PingoLee/PormG.jl/issues/64) — ⚠️ Honor `db_column` on ManyToMany through-table + CTE join keys when a participating model's primary key is renamed (db_column completeness follow-up to #50/#62)
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

- [#43](https://github.com/PingoLee/PormG.jl/issues/43) — `deepcopy(ctes)` → `copy(ctes)` shared-state risk
- [#44](https://github.com/PingoLee/PormG.jl/issues/44) — CTE ergonomics: reference CTE fields via `F()` in the main query

## 🔗 Custom Join (`cjoin`) Gaps

- [#45](https://github.com/PingoLee/PormG.jl/issues/45) — `cjoin` gaps: arbitrary ON clauses, cross-table `F()` in ON, SQL functions in ON (`strftime`/`EXTRACT`)

## 🐞 SQLite worker / pool stability

- [#47](https://github.com/PingoLee/PormG.jl/issues/47) — SQLite connection / file-handle release at teardown (`close_pool!` leased-close + non-idempotent `_close_db!`)

## 🔮 Future Considerations

- [#46](https://github.com/PingoLee/PormG.jl/issues/46) — Parameterize LIMIT/OFFSET
- [#59](https://github.com/PingoLee/PormG.jl/issues/59) — Model `db_table` option: pin an explicit (mixed/upper-case) table name (Django `Meta.db_table` analog; table-level sibling of #50, pairs with #57)

---

*Completed work is not listed here — see [closed issues](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aissue+is%3Aclosed). (Work that predates the issue tracker lives in git history.)*
