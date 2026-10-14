## `get_constraints_check` → `get_constraints_checks` (and the byte-length twin): a CHECK dropper returns every matching name (#752)

- **Version**: 0.8.0
- **PormG ref**: #752 ; `src/Kernel.jl` (the generics), `src/migrations/introspection.jl` (`get_constraints_checks`, `get_constraints_byte_length_checks`), `src/Dialect.jl` (`alter_field`)
- **Recorded**: 2026-10-11
- **Severity**: breaking for code that calls or extends the old names; a behavior change in the
  plans for a column that carries two CHECKs in PormG's form.

### What changed

A column can carry two CHECKs in PormG's exact form — a hand-written copy with another bound, or one
an interrupted change left behind. The droppers returned **one** name, so a plan dropped one,
re-added it, and planned the same pair on every run while the other kept rejecting values the model
allows. They now return every matching name, and were renamed so that a stale method returning a
`String` fails loudly instead of being iterated character by character:

| | before | after |
|---|---|---|
| `PormG.get_constraints_check(…)` | a `String` (one name) | removed: `UndefVarError` |
| `PormG.get_constraints_checks(…)` | — | a `Vector{String}` (every matching name) |
| `PormG.get_constraints_byte_length_check(…)` | a `String` | removed: `UndefVarError` |
| `PormG.get_constraints_byte_length_checks(…)` | — | a `Vector{String}` |
| A column with two PormG-form CHECKs (`octet_length(x) <= 8` and `<= 4`, or two `>= 0`) | the plan dropped one per run and never converged | one plan drops them all and converges |
| SQLite: the byte bound read back from two such CHECKs | the first in the DDL | the tightest, as PostgreSQL reads it |

The released `0.4.0` entry for #274 promised the old names as qualified, extensible calls; it notes
the rename, but `upgrade_guide(from = "0.7.0")` does not show that entry, so it is restated here.

### Who this affects

Code that calls `get_constraints_check` / `get_constraints_byte_length_check`, or adds methods to
them for a custom backend.

### How to find the calls to migrate

```bash
grep -rnE 'get_constraints_(byte_length_)?check\b' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
name = PormG.get_constraints_check(conn, "result", "points")
drop!(name)

# ✓ after — a vector; drop each
for name in PormG.get_constraints_checks(conn, "result", "points")
    drop!(name)
end
```
