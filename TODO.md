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
> authoritative DDL/queries (#50), string FK targets (#62), ManyToMany/CTE join keys (#64) ·
> isolated PG migration fixture (#36) · pool-exhaustion investigation (#37 → follow-ups
> #124–#128) · `ORDER BY` NULL placement (#75) · `.copy()` state aliasing (#43 → #112) ·
> bulk mapping contract, `columns=` as the single df→model border (#107).
>
> **Remaining gating work** — the `pre-publish` label is the source of truth, so this list is exactly
> [`gh issue list --label pre-publish`](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aopen+label%3Apre-publish):

- [#132](https://github.com/PingoLee/PormG.jl/issues/132) — Bulk ops: drop the `copy=` deepcopy default — non-mutating zero-copy pipeline

---

*Release-gating index only. Full backlog: [open issues](https://github.com/PingoLee/PormG.jl/issues) ·
completed work: [closed issues](https://github.com/PingoLee/PormG.jl/issues?q=is%3Aissue+is%3Aclosed)
(work predating the tracker lives in git history).*
