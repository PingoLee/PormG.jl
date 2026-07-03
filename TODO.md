# TODO — release-gating index

> **The backlog lives entirely in [GitHub Issues](https://github.com/PingoLee/PormG.jl/issues).**
> Browse by label for the subsystem views the old sections used to provide —
> [`migrations`](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Amigrations),
> [`bug`](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Abug),
> [`postgres`](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Apostgres),
> [`sqlite`](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Asqlite), etc.
>
> This file is **not** a mirror of the open backlog — it deliberately tracks **only** the
> release-gating items below, which a repo doc (`.github/instructions/general.instructions.md`)
> references. Ordinary issues never touch this file; only a `pre-publish` issue opening or closing does.

## ⚠️ do BEFORE the first General-registry publish

> These lock in contracts that are cheap to settle now (zero published users on Julia's General
> registry) but become breaking/irreversible afterward.
>
> **Settled & merged:** Tier 1 (migration-format / tracking-table contract, frozen schema
> conventions) · Tier 2 (#34 adapter decoupling → #35 export curation) · field-name case
> preservation (#57) + lowercase convention (#58) · the full `db_column` authority family —
> authoritative DDL/queries (#50), string FK targets (#62), ManyToMany/CTE join keys (#64).
>
> **Remaining gating work** — the `pre-publish` label is the source of truth, so this list is exactly
> [`gh issue list --label pre-publish`](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Apre-publish):

- [#36](https://github.com/PingoLee/PormG.jl/issues/36) — Isolated PostgreSQL migration fixture (`db_test_migration_pg/`)
- [#37](https://github.com/PingoLee/PormG.jl/issues/37) — Investigate PG pool exhaustion under remote-latency integration runs
- [#75](https://github.com/PingoLee/PormG.jl/issues/75) — `ORDER BY` NULL placement diverges PG vs SQLite (no `NULLS FIRST/LAST` normalization)
- [#107](https://github.com/PingoLee/PormG.jl/issues/107) — Reconsider `=>` direction/semantics across the query API (predicate vs projection vs mapping)
- [#112](https://github.com/PingoLee/PormG.jl/issues/112) — `.copy()` aliases custom_join state: extending `on()`/`cjoin()` on a copy mutates the original (build-time residual of #43)

---

*Release-gating index only. Full backlog: [open issues](https://github.com/PingoLee/PormG.jl/issues) ·
completed work: [closed issues](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aissue+is%3Aclosed)
(work predating the tracker lives in git history).*
