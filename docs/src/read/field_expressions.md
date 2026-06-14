# Field Expressions (F Objects)

`F()` expressions enable database-side field references and arithmetic. They let you compare fields to other fields, perform calculations in SQL, and create computed columns — all without pulling data into Julia.

> [!NOTE]
> **For Django users:** PormG's `F()` is inspired by Django but leverages Julia's operator overloading (e.g., `F("a") + F("b")`). It also allows seamless mixing with aggregate functions like `Sum()` and `Count()`, and the engine automatically detects aggregates to generate `HAVING` clauses.

---

## When to Use F Expressions

| Task | Preferred Style | F Expression |
| :--- | :--- | :--- |
| Compare field to a **constant** | `"points__@gt" => 10` | Avoid — use the filter suffix API |
| Compare **field to field** | — | `F("grid") == F("positionOrder")` |
| **Arithmetic** in SELECT | — | `F("points") * 0.1` |
| **Aggregate ratios** | — | `Sum("points") / Count("resultId")` |
| **Atomic updates** | — | `F("points") + 1` |

> [!TIP]
> Reserve `F()` for column-to-column or column-to-expression operations. For scalar comparisons like `points > 10`, prefer the suffix syntax `"points__@gt" => 10` — it's clearer and idiomatic.

---

## Core Syntax

```julia
using PormG: F, Count, Sum

# Field reference
F("grid")

# Arithmetic
F("points") + 5                   # Addition
F("points") - F("grid")          # Subtraction
F("points") * F("laps")          # Multiplication
F("points") / 2.0                # Division
Sum("points") / Count("resultId") # Aggregate ratios
```

**Supported arithmetic operators:** `+`, `-`, `*`, `/`

---

## Comparison Operators

`F()` expressions support standard Julia comparison operators, translated directly to SQL:

| Julia | SQL | Use Case |
| :--- | :--- | :--- |
| `==` | `=` | Field-to-field equality |
| `!=` | `<>` | Field-to-field inequality |
| `>` | `>` | Greater than |
| `<` | `<` | Less than |
| `>=` | `>=` | Greater than or equal |
| `<=` | `<=` | Less than or equal |

These are most useful when the comparison involves **two columns** or a **computed expression** — cases where the suffix filter API cannot help.

---

## F Expressions in Filters

### Field-to-Field Comparison

Find results where the starting grid position matches the finishing position:

```julia
query = M.Result.objects
query.filter(F("grid") == F("positionOrder"))
df = query |> DataFrame
```

Generated SQL:
```sql
WHERE "Tb"."grid" = "Tb"."positionorder"
```

### Relationship-Aware Comparison

Compare fields across joined tables. Find results where the driver's birth month matches the race month:

```julia
query = M.Result.objects
query.filter(
    F("driverId__dob__@month") == F("raceId__date__@month")
)
df = query |> DataFrame
```

PormG resolves the `__` paths, creates the necessary joins, and applies the `EXTRACT(MONTH FROM ...)` transform on both sides.

### Mixing F and Standard Filters

Combine `F()` comparisons with ordinary filter pairs when only part of the predicate needs an expression:

```julia
query = M.Result.objects
query.filter(
    F("driverId__dob__@day") == F("raceId__date__@day"),
    F("driverId__dob__@month") == F("raceId__date__@month"),
    "positionOrder__@lte" => 10,   # Standard scalar filter
)
df = query |> DataFrame
```

### Date Arithmetic

Find results within 30 days of the driver's birthday:

```julia
query = M.Result.objects
query.filter(
    F("raceId__date") > F("driverId__dob"),
    F("raceId__date") <= F("driverId__dob") + 30
)
```

### When NOT to Use F

For plain scalar comparisons, always prefer the suffix filter API:

```julia
# ✅ Preferred
query.filter("points__@gt" => 20, "grid" => 1)

# ❌ Works but not idiomatic
query.filter(F("points") > 20, F("grid") == 1)
```

---

## F Expressions in `values()`

Use `F()` inside `values()` to create **computed columns** directly in the SQL `SELECT`:

```julia
query = M.Result.objects
query.filter("statusId__status" => "Finished")
query.values(
    "driverId__surname",
    "points",
    "bonus" => F("points") * 0.1,
    "total" => F("points") + (F("points") * 0.1)
)
df = query |> DataFrame
```

This generates:
```sql
SELECT
    "Tb_1"."surname" as driverid__surname,
    "Tb"."points" as points,
    "Tb"."points" * 0.1 as bonus,
    "Tb"."points" + ("Tb"."points" * 0.1) as total
FROM ...
```

---

## Aliasing and Calculated Columns

In PormG, you don't need a separate `.annotate()` method (like Django). Aliases and computed columns are both created in `values()` using the `"alias" => expression` pair syntax.

### Simple Column Alias (Rename)

```julia
query = M.Driver.objects
query.values(
    "full_name" => "surname",   # Rename "surname" to "full_name"
    "code"
)
df = query |> DataFrame
# DataFrame columns: :full_name, :code
```

### Calculated Column (Expression)

```julia
query = M.Result.objects
query.values(
    "driverId__surname",
    "bonus_pts" => F("points") * 0.1   # Computed in the database
)
df = query |> DataFrame
```

### Reference vs. Calculation

| Syntax | What It Does | SQL |
| :--- | :--- | :--- |
| `"alias" => "field"` | Rename column | `SELECT "surname" AS "full_name"` |
| `"alias" => F("field") * 1.5` | Compute value | `SELECT "points" * 1.5 AS "alias"` |
| `"alias" => Sum("field")` | Aggregate | `SELECT SUM("points") AS "alias"` |

> [!TIP]
> Aliasing happens at the SQL level. This is significantly more efficient than renaming columns in a Julia DataFrame after the query finishes.

---

## Aggregate Arithmetic

Aggregate functions (`Sum`, `Count`, `Avg`, `Max`, `Min`) can participate in arithmetic. PormG automatically handles the `GROUP BY` and `HAVING` implications.

### In Projections

```julia
query = M.Result.objects
query.values(
    "driverId__surname",
    "points_per_result" => Sum("points") / Count("resultId")
)
df = query |> DataFrame
```

### In Filters (Auto-HAVING)

When a filter references an aggregate alias, PormG moves it to the `HAVING` clause:

```julia
query = M.Result.objects
query.values(
    "constructorId__name",
    "avg_perf" => Sum("points") / Count("resultId")
)
query.filter("avg_perf__@gt" => 5)
df = query |> DataFrame
```

PormG generates:
```sql
SELECT "constructorid__name", SUM("points") / COUNT("resultid") as avg_perf
FROM ...
GROUP BY 1
HAVING SUM("points") / COUNT("resultid") > $1
```

---

## F Expressions in Updates (Write Side)

F expressions are essential for **atomic updates** — modifying a column based on its current value without a read-modify-write cycle. This prevents race conditions and is usually more performant.

### Simple Arithmetic

```julia
# Increment points by 1
M.Result.objects.filter("resultId" => 1).update("points" => F("points") + 1)

# Apply a 10% penalty
M.Result.objects.filter("points__@gt" => 10).update("points" => F("points") * 0.9)
```

### Copy Column Values

Set one column equal to another column in the same row:

```julia
M.Just_a_test_deletion.objects.
    filter("id" => 5).
    update("test_result2" => F("test_result"))
```

### Complex Expressions

Combine multiple `F()` expressions in a single update:

```julia
M.Just_a_test_deletion.objects.update(
    "test_result2" => (F("test_result2") * 2) + F("test_result")
)
```

### Updates with Join-Based Filters

Filter by joined fields while updating the main table:

```julia
# Add 10 bonus points for all British drivers in result 1
M.Result.objects.filter(
    "driverId__nationality" => "British",
    "resultId" => 1
).update("points" => F("points") + 10)
```

> [!WARNING]
> You can **filter** by joined fields during an update, but you generally cannot **set** a column using a value from a joined table (e.g., `update("col" => F("joined__col"))`). Stick to expressions involving columns from the table being updated for maximum cross-database compatibility.

---

## Bitwise Operations

PormG supports direct database-side bitwise operations on integer columns through `F()` expressions, aggregate `FObject`s, and `WindowFunction`s. This is extremely useful for atomic updates, bitwise filtering, and projection of bitmask or flag fields directly within the database without transferring entire tables into memory.

### What is a Bitmask?

A **bitmask** is a technique that uses the individual bits of a single integer value to store multiple, independent boolean flags (yes/no states) simultaneously. Since each bit can be either `0` or `1`, an 8-bit integer can store 8 separate flags, and a 64-bit integer can store 64 flags!

Each flag is assigned a specific bit position corresponding to a power of 2:
* **Bit 1** (value $1 = 2^0$): Flag A (e.g. `is_active`)
* **Bit 2** (value $2 = 2^1$): Flag B (e.g. `is_verified`)
* **Bit 3** (value $4 = 2^2$): Flag C (e.g. `is_admin`)
* **Bit 4** (value $8 = 2^3$): Flag D (e.g. `has_billing`)

#### How Binary Columns Work Under the Hood

In standard decimal (base-10), we count using powers of 10 (ones, tens, hundreds, thousands...). In binary (base-2), computers count using powers of 2. 

An 8-bit integer is represented as 8 binary slots counted from right to left:

```text
Bit Position:    8th   7th   6th   5th   4th   3rd   2nd   1st
Power of 2:      2^7   2^6   2^5   2^4   2^3   2^2   2^1   2^0
Decimal Value:   128    64    32    16     8     4     2     1
               ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
Binary Slots:  │  0  │  0  │  0  │  0  │  1  │  0  │  0  │  0  │
               └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                                          ▲
                                      This is Bit 4!
                                      (Value = 8)
```

If a user has both `is_active` (value `1`) and `has_billing` (value `8`) enabled, their `status` integer value in the database will be:
$$8 + 1 = 9$$

In binary representation, `status = 9` looks like this:
```text
Bit Position:    8th   7th   6th   5th   4th   3rd   2nd   1st
Decimal Value:   128    64    32    16     8     4     2     1
               ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
User's Status: │  0  │  0  │  0  │  0  │  1  │  0  │  0  │  1  │
               └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                                          ▲                 ▲
                                      has_billing       is_active
                                        (True)           (True)
```

#### How We Operate on Bitmasks:

1. **Checking flags (Bitwise AND - `&`)**: To isolate and read a specific bit, we perform a bitwise AND between the integer column and the flag value.
   - For example, checking if a user has billing: `status & 8`.
   - If `status = 9` (binary `00001001`): `9 & 8` $\rightarrow$ `00001001 & 00001000` = `00001000` (decimal `8`). Since `8 > 0`, the flag is active.
   - If `status = 5` (binary `00000101` - active and admin, no billing): `5 & 8` $\rightarrow$ `00000101 & 00001000` = `00000000` (decimal `0`). The flag is inactive.

2. **Setting flags (Bitwise OR - `|`)**: To turn a specific flag ON without affecting other flags, we use bitwise OR with the flag value.
   - For example, enabling billing: `status | 8`.
   - If `status = 5` (active and admin): `5 | 8` $\rightarrow$ `13` (binary `00001101` $\rightarrow$ active, admin, AND has billing).

3. **Toggling flags (Bitwise XOR - `xor` / `⊻`)**: To flip a flag from 0 to 1 or 1 to 0, we use bitwise XOR.
   - For example, toggling billing: `status ⊻ 8`.
   - If `status = 9` (active and billing): `9 ⊻ 8` $\rightarrow$ `1` (binary `00000001` $\rightarrow$ active, billing disabled).
   - If `status = 1` (active, no billing): `1 ⊻ 8` $\rightarrow$ `9` (binary `00001001` $\rightarrow$ active, billing enabled).

All examples in this section are **100% real and executable** directly against the standard Formula 1 dataset schema using the `Driver` model's `number` integer field.

### Supported Operators

| Julia | SQL | Description |
| :--- | :--- | :--- |
| `&` | `&` | Bitwise AND |
| `\|` | `\|` | Bitwise OR |
| `~` | `~` | Unary Bitwise NOT (negation) |
| `<<` | `<<` | Bitwise Shift Left |
| `>>` | `>>` | Bitwise Shift Right |
| `xor` / `⊻` | `#` (Postgres) / emulated (SQLite) | Bitwise XOR |

> [!NOTE]
> **XOR Dialect Support:**
> - In standard Julia, `^` represents exponentiation, which aligns with PostgreSQL's `^`. PormG preserves this by keeping `^` for mathematical exponentiation.
> - For bitwise XOR, PormG overloads Julia's idiomatic `xor` and `⊻` functions.
> - PormG handles dialect differences transparently: rendering `(a # b)` on PostgreSQL, and emulating it via `((a | b) - (a & b))` on SQLite while correctly duplicating any internal parameters to preserve positional alignment.

### Real-World F1 Case Study: The "Clean vs. Dirty" Grid Side Analysis

In Formula 1, starting grid slots are staggered in two rows:
* **Clean Side (Odd grid positions: 1, 3, 5, 7...)**: Positioned directly on the racing line where high rubber laydown provides maximum traction at the start.
* **Dirty Side (Even grid positions: 2, 4, 6, 8...)**: Positioned off the racing line where dust, marbles, and debris significantly reduce launching grip.

By checking the lowest bit of the `grid` integer column (`grid & 1`), you can instantly classify clean/odd vs. dirty/even grid starts directly in the database.

For example, to find all podium finishers (top 3) who successfully fought their way up from a **dirty starting slot** (where `(grid & 1) == 0`):

```julia
query = M.Result.objects.values(
    "raceid__name",
    "driverid__surname",
    "grid",
    "position"
).filter(
    "position__@lte" => 3,     # Podium finisher
    (F("grid") & 1) == 0      # Started on the dirty (even) side
);
df = query |> DataFrame
@info (query |> inspect_query)[:sql_text]
```

**Generated PostgreSQL SQL:**
```sql
SELECT
    "Tb_1"."name" as raceid__name,
    "Tb_2"."surname" as driverid__surname,
    "Tb"."grid" as grid,
    "Tb"."position" as position
FROM "result" as "Tb"
 INNER JOIN "race" AS "Tb_1" ON "Tb"."raceid" = "Tb_1"."raceid"
 INNER JOIN "driver" AS "Tb_2" ON "Tb"."driverid" = "Tb_2"."driverid"
WHERE "Tb"."position" <= $1 AND (("Tb"."grid" & $2::bigint) = $3::bigint)
-- Parameters: $1 = 3 (Podium), $2 = 1 (Bitmask), $3 = 0 (Dirty side)
```

### Dynamic Bitmasks & Scalar Left-Shift Operations

In advanced status and permission query models, you may store a **bit index** (an integer like $0, 1, 2...$) representing a flag's index, rather than storing a pre-computed bitmask. 

PormG fully supports **left-hand scalar bitwise shifts** (e.g. `1 << F("field")`) to dynamically generate one-hot bitmasks directly on the database server:

```julia
# Dynamically generate a bitmask from a stored bit index column:
query = M.Driver.objects.values(
    "surname",
    "index_mask" => 1 << F("number")
)
@info (query |> inspect_query)[:sql_text]
```

**Generated PostgreSQL SQL:**
```sql
SELECT
    "Tb"."surname" as surname,
    ($1::integer << "Tb"."number") as index_mask
FROM "drivers" as "Tb"
-- Parameters: $1 = 1
```

> [!TIP]
> **Dialect Optimization:**
> When generating left-hand shifts (`<<` or `>>`), PormG automatically types the left-side scalar parameter as `integer` (4-byte) on PostgreSQL, avoiding type-signature compiler mismatch errors.

### In Projections (`values()`)

Mask or extract bits dynamically in a SELECT statement:

```julia
# Project a boolean column indicating if the driver has an odd racing number
query = M.Driver.objects.values(
    "surname",
    "number",
    "is_odd" => F("number") & 1
);
df = query |> DataFrame
@info (query |> inspect_query)[:sql_text]
```

**Generated PostgreSQL SQL:**
```sql
SELECT
    "Tb"."surname" as surname,
    "Tb"."number" as number,
    ("Tb"."number" & $1::bigint) as is_odd
FROM "drivers" as "Tb"
-- Parameters: $1 = 1
```

### In Filters (`filter()`)

Filter rows directly on server-side bitmasks:

```julia
# Find all drivers with odd racing numbers
query = M.Driver.objects.filter(
    (F("number") & 1) > 0
)
df = query |> DataFrame
@info (query |> inspect_query)[:sql_text]
```

**Generated PostgreSQL SQL:**
```sql
SELECT *
FROM "drivers" as "Tb"
WHERE (("Tb"."number" & $1::bigint) > $2::bigint)
-- Parameters: $1 = 1, $2 = 0
```

### In Atomic Updates (`update()`)

Atomically update bitmask columns:

```julia
# Toggle the lowest bit of a driver's racing number:
@info M.Driver.objects.
    filter("driverid" => 1).
    update("number" => F("number") ⊻ 1, show_query = :dict)[:sql_text]
```

**Generated PostgreSQL SQL:**
```sql
UPDATE "drivers" AS "Tb"
SET "number" = ("Tb"."number" # $2::bigint)
WHERE "Tb"."driverid" = $1
-- Parameters: $1 = 1 (driverId), $2 = 1 (xor mask)
```

```julia
# Ensure the racing number is odd by setting the lowest bit:
M.Driver.objects.
    filter("driverId" => 2).
    update("number" => F("number") | 1)
```

**Generated PostgreSQL SQL:**
```sql
UPDATE "drivers" AS "Tb"
SET "number" = ("Tb"."number" | $2::bigint)
WHERE "Tb"."driverid" = $1
-- Parameters: $1 = 2 (driverId), $2 = 1 (or mask)
```
---

## Summary

| Feature | Example | Where |
| :--- | :--- | :--- |
| Field comparison | `F("grid") == F("positionOrder")` | `filter()` |
| Cross-join comparison | `F("driverId__dob__@month") == F("raceId__date__@month")` | `filter()` |
| Arithmetic column | `"bonus" => F("points") * 0.1` | `values()` |
| Aggregate ratio | `Sum("points") / Count("resultId")` | `values()` |
| Aggregate filter | `"avg__@gt" => 5` on an aggregate alias | `filter()` → HAVING |
| Column alias | `"name" => "surname"` | `values()` |
| Atomic update | `F("points") + 1` | `update()` |
| Column copy | `F("other_field")` | `update()` |

---

## Next Steps

- **[Q Objects](q_objects.md)** — Complex AND/OR logic with `Q()` and `Qor()`.
- **[Filters and Aggregates](filters_and_aggregates.md)** — Lookup operators and grouping.
- **[Writing: Updating Records](../write/update.md)** — Full update documentation.
