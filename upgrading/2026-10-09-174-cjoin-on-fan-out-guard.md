## `cjoin_on` + `Count`/`Sum`/`Avg` — a join not proven to-one meets the fan-out guard (#174)

- **Version**: Unreleased
- **PormG ref**: #174 ; `src/querybuilder/join_conditions.jl` (`_cjoin_on_to_many`), `src/querybuilder/build_query.jl` (`_check_aggregate_fanout`)
- **Recorded**: 2026-10-09
- **Severity**: behavior change. A query that aggregates a base column next to a `cjoin_on` join that can match more than one row per base row used to return a silently multiplied number. It now raises `QueryBuildError` from the #74 fan-out guard, as a reverse foreign key or a many-to-many join already did.

### What changed

A `cjoin_on` join was invisible to the fan-out guard. PormG now decides from the `ON` clause whether
the join is **to-one**: top-level `==` conditions (not inside `Qor`) pin the target's primary key, a
`unique = true` column, or every column of a plain `UniqueConstraint` to one value per base row.
Every other `cjoin_on` join counts as to-many.

| query | before | after |
|---|---|---|
| `cjoin_on("Driver", alias = "d2", on = [Joined("d2", "nationality") == F("nationality")])` + `values("nationality", "n" => Count("driverid"))` | each driver counted once per driver of the same nationality | raises `QueryBuildError` |
| the same join on a column that is unique in the data but not declared unique | correct, by luck of the data | raises `QueryBuildError` |
| `cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid")])` + `Count("resultid")` | correct | unchanged |

`Max`/`Min`, an aggregate with `distinct = true`, and an aggregate over the joined copy's own column
(`Count(Joined("d2", "driverid"))`) are exempt, as they are for every to-many join.

### Who this affects

Queries that declare a `cjoin_on` and project `Count`, `Sum` or `Avg` over a column of the base model
(or over an expression spanning both sides).

### How to find the calls to migrate

`grep -rn "cjoin_on" --include=*.jl .`, then read the same query for `Count(`, `Sum(` or `Avg(`. At
run time each remaining call raises with a message containing:

```
count as to-many because their ON clause does not prove at most one match per base row
```

### Migrate your app

If the join really is one-to-one, declare the key, and the join becomes to-one with no query change.
On a managed model that is a schema change: the next migration adds the constraint, and fails if the
table holds duplicates.

```julia
# ✓ in the model: the column the ON clause matches on is unique
driverref = Models.CharField(unique = true)
```

Otherwise, say which count you want:

```julia
# ✗ before: each driver counted once per driver of the same nationality
query = M.Driver.objects
query.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "nationality") == F("nationality")])
query.values("nationality", "n" => Count("driverid"))

# ✓ after: distinct base rows
query.values("nationality", "n" => Count("driverid", distinct = true))
# ✓ or: the joined rows themselves
query.values("nationality", "n" => Count(Joined("d2", "driverid")))
```
