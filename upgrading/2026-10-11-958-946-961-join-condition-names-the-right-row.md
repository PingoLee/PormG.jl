## `on()` / `cjoin(filters = …)`: each side of a join condition names the row it should, in every spelling (#958, #946, #961)

- **Version**: 0.8.0
- **PormG ref**: #958, #946, #961 ; `src/querybuilder/join_conditions.jl` (`_prefix_join_filter`, `_prefix_join_column`), `src/querybuilder/build_query.jl` (`build_row_join_sql_text`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. The same `on()` / `cjoin(filters = …)` call renders a different
  `ON` clause and can return different rows. A few spellings that rendered now raise.

### What changed

The rule is now the same for every spelling and every hop depth: **the key, and every column on the
left side, names the joined row; a right-side `F` names the base row** (the query's own model). The
bare pair `"number" => F("number")` already worked this way on a first hop. The other spellings did
not:

| Condition | before | after |
|---|---|---|
| `on("driverid", Q("number" => F("number")))` — and `Qor(…)`, `OP(…)`, `F("number") == F("number")` (#958) | `"Tb_1"."number" = "Tb_1"."number"` — true on every row, so the predicate was silently dropped | `"Tb_1"."number" = "Tb"."number"`, as the bare pair renders |
| `on("driverid", Q("number" => 5))` while `values()` also selects the base `number` — and a transform key (`"dob__@year"`) or a function on the left of an `F` comparison (#961) | the predicate landed on the **base** row (`"Tb"."number"`) | it applies to the joined row (`"Tb_1"."number"`) |
| Deep hop: `on("driverid__result", "grid" => F("number"))` (#946) | the bare `F` named the hop's left table (the driver's `number`) | it names the base row; the left table is still reachable as `F("driverid__number")` |
| An `OuterRef` inside a `Subquery` in a deep-hop `on()` (#946) | retargeted onto the hop's left table | correlates with the owning query |
| A bare column string in a left-side expression that names only a base-model column (#961) | rendered on the base row | raises `FilterError`, as `F("grid")` there already did |
| `on("driverid", (F("number") + F("number")) > F("number"))` (#958) | raised `"Invalid cjoin filter field ''"` | builds |

### Who this affects

Queries that pass a condition to `on()` or `cjoin(filters = …)` written as `Q`, `Qor`, `OP` or an
`F` comparison, that compare across a deep hop, or whose `values()` selects a base column with the
same name as the joined column a condition names. The rows those queries return may change:
predicates that used to be no-ops now filter the join.

### How to find the calls to migrate

```bash
grep -rnE '\.on\(|cjoin\(' --include=*.jl . | grep -E 'Q\(|Qor\(|OP\(|F\('
grep -rnE '\.on\("[a-z_]+__[a-z_]+' --include=*.jl .
```

Check each hit against the rule above: the key side is the joined row, a right-side `F` the base
row.

### Migrate your app

```julia
# Results where the car number equals the driver's permanent number.

# ✗ before — the Q spelling compared the driver's number with itself; every result came back
M.Result.objects.on("driverid", Q("number" => F("number")), join_type = "INNER")

# ✓ after — the same call compares the two tables (as the bare pair always did)
M.Result.objects.on("driverid", Q("number" => F("number")), join_type = "INNER")

# ✗ before — on a deep hop, F("number") meant the hop's left table (Driver)
M.Result.objects.on("driverid__result", "grid" => F("number"))
# ✓ after — say so explicitly
M.Result.objects.on("driverid__result", "grid" => F("driverid__number"))
```
