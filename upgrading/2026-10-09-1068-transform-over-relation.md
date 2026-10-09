## A date part over a foreign key is checked against the related key (#1068)

- **Version**: Unreleased
- **PormG ref**: #1068 ; `src/querybuilder/select_nodes.jl` (`_relation_key_field`, `_check_temporal_operand`)
- **Recorded**: 2026-10-09
- **Severity**: behavior. A date part over a `ForeignKey` or `OneToOneField` whose key is not a date now raises `QueryBuildError` when the query is built. Before, PostgreSQL refused it when it ran, and SQLite answered from the key's text.

### What changed

A foreign key's column holds the related row's key. #955 checked a date transform's column but
passed every relation through, so `"raceid__@year"` over an integer `raceid` built
`EXTRACT(YEAR FROM "Tb"."raceid")`. The check now follows the relation to the field it points at,
its `pk_field` or the target's primary key, and classifies that field. A key that is itself a
relation is followed in turn.

| call | before | after |
|---|---|---|
| `values("y" => "raceid__@year")`, `raceid` a foreign key to an integer id | built; failed on PostgreSQL, SQLite read the integer as text | `QueryBuildError` naming `raceid`, the related key and its type |
| `values("y" => Extract("raceid", "YEAR"))` | the same | the same `QueryBuildError` |
| `filter("raceid__@month" => 3)` | the same | `QueryBuildError` |
| `values("y" => "weekend__@year")`, `weekend` a foreign key to a **date** key | built | builds, unchanged |
| `values("y" => "raceid__date__@year")` | built | builds, unchanged: the part reads the joined date |

A many-to-many relation has no column and is still passed through, as is a relation whose target
PormG cannot resolve where the query is built.

### Who this affects

Code that applies a date part — a `__@` transform or `Extract` — directly to a foreign key whose key
is a number or text. On PostgreSQL every such query already failed when it ran.

### How to find the calls to migrate

```bash
grep -rnE '__@(year|month|day|date|quarter|quadrimester|week|week_day|iso_week_day|iso_year|yyyy_mm|yyyy_q|yyyy_quad|hour|minute|second)\b' --include=*.jl src/ test/
```

For each hit, check whether the field right before the `__@` is a `ForeignKey` or a
`OneToOneField`. Running the query is the definitive check: the refusal says the column is a
relation whose value is the related key, and names that key's type.

### Migrate your app

```julia
# ✗ before — `raceid` holds the race's integer id: PostgreSQL refused it when it ran
M.Result.objects.values("season" => "raceid__@year")
# ✓ after — read the year of the race's date, through the relation
M.Result.objects.values("season" => "raceid__date__@year")
```
