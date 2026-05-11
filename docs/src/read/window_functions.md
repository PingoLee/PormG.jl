# Window Functions

Window functions compute values over a sliding frame of rows without collapsing them the way `GROUP BY` aggregates do. Each row keeps its identity in the result while gaining an extra computed column derived from its surrounding rows.

> [!NOTE]
> **For Django users:** PormG's `WindowOver` / `Rank` / `Lag` / … mirror Django's `Window(expression, partition_by=..., order_by=...)` API. The main difference is that PormG passes the `WindowSpec` directly to the function constructor rather than wrapping it in a separate `Window()` call.

---

## Core Concepts

| Concept | What It Does |
| :--- | :--- |
| `WindowOver(partition_by=..., order_by=...)` | Defines the window frame — which rows each call can see |
| Window function call (`Rank(over=...)`) | Performs the computation over that frame |
| No `GROUP BY` collapse | Every input row appears in the result, each with its computed window value |

---

## Quick Start

The goal: for every 1991 race, assign each driver a rank based on their points — 1st place gets rank 1, 2nd place gets rank 2, and so on. Crucially, the ranking **restarts for each race** (not across all 1991 races combined).

```julia
using PormG
using PormG: WindowOver, Rank

query = M.Driver_standings.objects
query.filter(
    "raceid__@in" => [305, 306],  # only two races
    "points__@gt"  => 0,       # skip drivers who have not scored yet
)
query.values(
    "raceid",
    "driverid__surname",
    "points",
    "race_rank" => Rank(over=WindowOver(
        partition_by=["raceid"],   # restart the ranking for each race
        order_by=["-points"]       # highest points = rank 1
    ))
)
query.order_by("raceid", "race_rank")
df = query |> DataFrame
```

Result:

```
15×4 DataFrame
 Row │ raceid  driverid__surname  points   race_rank
     │ Int64   String             Float64  Int64
─────┼───────────────────────────────────────────────
   1 │    305  Senna                 10.0          1
   2 │    305  Prost                  6.0          2
   3 │    305  Piquet                 4.0          3
   4 │    305  Modena                 3.0          4
   5 │    305  Nakajima               2.0          5
   6 │    305  Suzuki                 1.0          6
   7 │    306  Senna                 20.0          1
   8 │    306  Prost                  9.0          2
   9 │    306  Piquet                 6.0          3
  10 │    306  Patrese                6.0          3
  11 │    306  Berger                 4.0          5
  12 │    306  Modena                 3.0          6
  13 │    306  Nakajima               2.0          7
  14 │    306  Suzuki                 1.0          8
  15 │    306  Alesi                  1.0          8
```

**Why does `raceid=305` show ranks 1, 2, 3 …?**

- `partition_by=["raceid"]` tells the window function to treat each distinct `raceid` as a separate group. `Rank()` counts from 1 inside each group and **never looks outside it**.
- `order_by=["-points"]` sorts rows within each group by `points` descending (the `-` prefix means DESC). So the driver with the most points in race 305 gets rank 1, the next gets rank 2, and so on.
- The final `query.order_by("raceid", "race_rank")` is just the output sort — it has no effect on how ranks are computed.

The three pieces together:

| Piece | What you write | What SQL generates | Effect |
| :--- | :--- | :--- | :--- |
| Window frame | `WindowOver(partition_by=["raceid"], order_by=["-points"])` | `OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."points" DESC)` | defines the per-race, points-descending frame |
| Function | `Rank(over=...)` | `RANK() OVER (...)` | assigns 1, 2, 3 … with gaps on ties |
| Alias | `"race_rank" => Rank(...)` | `... as race_rank` | names the new column |

**What about ties?** `Rank` leaves a gap: in race 306 above, Piquet and Patrese both scored `6.0` and both receive rank **3**. The next driver (Berger, `4.0`) gets rank **5** — rank 4 is skipped to account for the two drivers tied at 3. The same happens at the bottom: Suzuki and Alesi both score `1.0` and share rank **8**. Use `DenseRank` to avoid these gaps (Berger would get rank 4, not 5).

Generated SQL:

```sql
SELECT
    "Tb"."raceid" as raceid,
    "Tb_1"."surname" as driverid__surname,
    "Tb"."points" as points,
    RANK() OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."points" DESC) as race_rank
FROM "driver_standings" as "Tb"
  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
WHERE "Tb"."raceid" IN (?, ?)
  AND "Tb"."points" > ?
ORDER BY "raceid" ASC,
  "race_rank" ASC
```

> [!NOTE]
> `?` placeholders are SQLite syntax. On PostgreSQL the same query uses `$1`, `$2`, `$3`.

---

## WindowOver — Defining the Frame

`WindowOver` builds a `WindowSpec` that every window function accepts via its `over` keyword. It controls two things:

- **`partition_by`** — which column(s) split the rows into independent groups. The window function resets and recomputes from scratch inside each group.
- **`order_by`** — how rows are sorted *within* each group before the function runs. This determines which row is "first", "previous", etc.

### Example 1 — partition only

Rank drivers within their constructor by race points. `constructorid` lives in the `result` table (not `driver_standings`), so this example uses `M.Result.objects`. Each constructor is an independent group; the ranking never crosses constructor boundaries.

```julia
using PormG: Rank, WindowOver

# Each constructor is a separate window — ranks restart per constructor
spec = WindowOver(partition_by=["constructorid"], order_by=["-points"])

query = M.Result.objects
query.filter("raceid" => 306)
query.values(
    "constructorid",
    "driverid__surname",
    "points",
    "constructor_rank" => Rank(over=spec)
)
query.order_by("constructorid", "constructor_rank")
df = query |> DataFrame
```

Result (truncated):

```
34×4 DataFrame
 Row │ constructorid  driverid__surname  points   constructor_rank
     │ Int64          String             Float64  Int64
─────┼──────────────────────────────────────────────────────────────
   1 │             1  Senna                 10.0                 1
   2 │             1  Berger                 4.0                 2
   3 │             3  Patrese                6.0                 1
   4 │             3  Mansell                0.0                 2
   5 │             6  Prost                  3.0                 1
   6 │             6  Alesi                  1.0                 2
   7 │            17  Gachot                 0.0                 1
   8 │            17  de Cesaris             0.0                 1
   ⋮ │      ⋮              ⋮                ⋮            ⋮
```

Three things to notice:

- **Ranks restart per constructor.** McLaren (id 1): Senna → rank 1, Berger → rank 2. Williams (id 3): Patrese → rank 1, Mansell → rank 2. Ferrari (id 6): Prost → rank 1, Alesi → rank 2. Each constructor is its own independent group.
- **Zeros tie at rank 1.** Jordan (id 17): both Gachot and de Cesaris scored 0.0 — identical values, so `Rank` gives both rank 1. This is the same gap behaviour as the Quick Start example.
- **No `points__@gt` filter here.** Unlike the Quick Start, this example keeps all finishers including 0-point entries, which is why most constructors show two drivers at rank 1.

### Example 2 — order only (no partition)

When there is no `partition_by`, all rows form a single group. `Lag` reaches back one row within that group — here, the previous lap for the same driver.

```julia
using PormG: Lag, WindowOver

# All laps in one window, ordered by lap number
spec = WindowOver(order_by=["lap"])

query = M.Lap_times.objects
query.filter("raceid" => 841, "driverid" => 1, "lap__@lte" => 8)
query.values(
    "lap",
    "milliseconds",
    "prev_ms" => Lag("milliseconds", over=spec)
)
query.order_by("lap")
df = query |> DataFrame
```

Result:

```
8×3 DataFrame
 Row │ lap    milliseconds  prev_ms
     │ Int64  Int64         Int64?
─────┼──────────────────────────────
   1 │     1        100573  missing
   2 │     2         93774   100573
   3 │     3         92900    93774
   4 │     4         92582    92900
   5 │     5         92471    92582
   6 │     6         92434    92471
   7 │     7         92447    92434
   8 │     8         92310    92447
```

Row by row: `prev_ms` on each row holds the `milliseconds` value from the row *above* it. Lap 1 has no previous row, so `prev_ms` is `missing` (SQL `NULL`). From lap 2 onward, `prev_ms` is exactly the previous lap's time — useful for computing lap-over-lap deltas (see [Arithmetic on Window Results](#arithmetic-on-window-results)).

Generated SQL (SQLite):

```sql
SELECT
    "Tb"."lap" as lap,
    "Tb"."milliseconds" as milliseconds,
    LAG("Tb"."milliseconds", ?) OVER (ORDER BY "Tb"."lap" ASC) as prev_ms
FROM "lap_times" as "Tb"
WHERE "Tb"."raceid" = ?
  AND "Tb"."driverid" = ?
  AND "Tb"."lap" <= ?
ORDER BY "lap" ASC
```

The `?` for the `LAG` offset is the default `1` — one row back. There is no `PARTITION BY` clause, so the entire filtered result set is one window.

### Example 3 — global frame (broadcast a value to every row)

No `partition_by`. The window covers the **entire result set** as one group. `FirstValue` ordered by `positionorder` always picks the race winner's points and repeats it on every output row — no self-join needed.

```julia
using PormG: FirstValue, WindowOver

query = M.Result.objects
query.filter("raceid" => 306, "positionorder__@lte" => 8)
query.values(
    "driverid__surname",
    "positionorder",
    "points",
    # Broadcast winner's points to every row for inline comparison
    "winner_pts" => FirstValue("points", over=WindowOver(order_by=["positionorder"]))
)
query.order_by("positionorder")
df = query |> DataFrame
```

Result:

```
8×4 DataFrame
 Row │ driverid__surname  positionorder  points   winner_pts
     │ String             Int64          Float64  Float64
─────┼───────────────────────────────────────────────────────
   1 │ Senna                          1     10.0        10.0
   2 │ Patrese                        2      6.0        10.0
   3 │ Berger                         3      4.0        10.0
   4 │ Prost                          4      3.0        10.0
   5 │ Piquet                         5      2.0        10.0
   6 │ Alesi                          6      1.0        10.0
   7 │ Moreno                         7      0.0        10.0
   8 │ Morbidelli                     8      0.0        10.0
```

`winner_pts` is `10.0` on every row — Senna's score. The window has no `PARTITION BY`, so all 8 rows form one group and `FirstValue` always sees the same first row (position 1).

Generated SQL (SQLite):

```sql
SELECT
    "Tb_1"."surname" as driverid__surname,
    "Tb"."positionorder" as positionorder,
    "Tb"."points" as points,
    FIRST_VALUE("Tb"."points") OVER (ORDER BY "Tb"."positionorder" ASC) as winner_pts
FROM "result" as "Tb"
  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
WHERE "Tb"."raceid" = ?
  AND "Tb"."positionorder" <= ?
ORDER BY "positionorder" ASC
```

Notice: **no `PARTITION BY`** in the `OVER` clause. That is the global-frame pattern.

> [!TIP]
> The primary use for a fully empty frame (`WindowOver()`) is **aggregate window functions** such as `SUM(...) OVER ()` or `AVG(...) OVER ()` — broadcasting a total or average to every row. These are not yet implemented in PormG. Use a CTE to achieve the same result for now.

### Summary

```julia
# restart per race, highest points first
WindowOver(partition_by=["raceid"],        order_by=["-points"])

# restart per constructor, highest points first
WindowOver(partition_by=["constructorid"], order_by=["-points"])

# all laps in sequence, no partitioning
WindowOver(order_by=["lap"])

# all rows, no order — one global frame
WindowOver()
```

### `order_by` Convention

Follow the same `"-field"` → `DESC` convention used everywhere in PormG:

| Expression | SQL |
| :--- | :--- |
| `order_by=["points"]` | `ORDER BY "Tb"."points" ASC` |
| `order_by=["-points"]` | `ORDER BY "Tb"."points" DESC` |
| `order_by=["-points", "driverid"]` | `ORDER BY "Tb"."points" DESC, "Tb"."driverid" ASC` |

### Frame Specifications (PostgreSQL only)

Explicit frames are needed when the SQL default frame is wrong for your use case. The most common trap: **`LastValue` with `ORDER BY` but no explicit frame.**

SQL's default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — it includes only rows up to and including the current one. For `LastValue`, that means "the last row I can see is the current row," so it silently returns the current row's own value instead of the partition's actual last row.

```julia
using PormG: LastValue, WindowOver

# Default frame: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
# LastValue sees only up to the current row → returns each row's own points
spec_default = WindowOver(
    partition_by=["constructorid"],
    order_by=["positionorder"]
)

# Full frame: every row in the partition is visible
# LastValue now correctly returns the last-placed driver's points on every row
spec_full = WindowOver(
    partition_by=["constructorid"],
    order_by=["positionorder"],
    frame="ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"  # PostgreSQL only
)

query = M.Result.objects
query.filter("raceid" => 841, "constructorid__@in" => [1, 3])
query.values(
    "constructorid",
    "driverid__surname",
    "positionorder",
    "points",
    "last_default" => LastValue("points", over=spec_default),
    "last_full"    => LastValue("points", over=spec_full)
)
query.order_by("constructorid", "positionorder")
df = query |> DataFrame
```

Result (PostgreSQL):

```
4×6 DataFrame
 Row │ constructorid  driverid__surname  positionorder  points    last_default  last_full
     │ Int64?         String?            Int32?         Float64?  Float64?      Float64?
─────┼────────────────────────────────────────────────────────────────────────────────────
   1 │             1  Hamilton                       2      18.0          18.0        8.0
   2 │             1  Button                         6       8.0           8.0        8.0
   3 │             3  Barrichello                   16       0.0           0.0        0.0
   4 │             3  Maldonado                     20       0.0           0.0        0.0
```

For McLaren (constructor 1): `last_default` mirrors each driver's own `points` — Hamilton sees `18.0` because the default frame only reaches as far as the current row; Button sees `8.0` for the same reason. `last_full` correctly broadcasts `8.0` (Button's points — the last row in the partition) to both McLaren rows. For Williams (constructor 3) both drivers scored `0.0`, so the frame choice makes no visible difference here.

Generated SQL (PostgreSQL):

```sql
SELECT
    "Tb"."constructorid" as constructorid,
    "Tb_1"."surname" as driverid__surname,
    "Tb"."positionorder" as positionorder,
    "Tb"."points" as points,
    LAST_VALUE("Tb"."points") OVER (
        PARTITION BY "Tb"."constructorid"
        ORDER BY "Tb"."positionorder" ASC
    ) as last_default,
    LAST_VALUE("Tb"."points") OVER (
        PARTITION BY "Tb"."constructorid"
        ORDER BY "Tb"."positionorder" ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) as last_full
FROM "result" as "Tb"
  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
WHERE "Tb"."raceid" = $1
  AND "Tb"."constructorid" = ANY($2)
ORDER BY "constructorid" ASC, "positionorder" ASC
```

> [!WARNING]
> Explicit frame strings are PostgreSQL-only. Passing `frame=` on a SQLite connection throws `ArgumentError` with a helpful message.

**Frame unit — `ROWS` vs `RANGE`**

The first keyword controls what "distance" means:

| Unit | Counts by | When to use |
| :--- | :--- | :--- |
| `ROWS` | Physical row position | Almost always — predictable, index-friendly |
| `RANGE` | Logical value of the `ORDER BY` column | Ties get the same frame boundary; slower and rarely needed |

SQL defaults to `RANGE` when `ORDER BY` is present and no frame is specified. That is almost never what you want for `LastValue` or moving windows — use `ROWS` explicitly.

**Common frame strings:**

| Frame string | Use case |
| :--- | :--- |
| `"ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW"` | **Cumulative total up to here.** The SQL default when `ORDER BY` is present — also the right choice for running sums/counts once aggregate-over-window is supported. |
| `"ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"` | **Whole partition visible.** Required for `LastValue` to return the actual last row rather than the current row. |
| `"ROWS BETWEEN 2 PRECEDING AND CURRENT ROW"` | **3-row moving window** (current + 2 before). Change `2` for wider windows. |
| `"ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING"` | **Centred window** — one row on each side of the current row. Useful for smoothing. |
| `"ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING"` | **Remaining rows** — from here to the end of the partition. |

---

## Ranking Functions

These functions assign a rank or row number to each row. They take no column argument — only a `WindowSpec`.

| Function | SQL | Behaviour |
| :--- | :--- | :--- |
| `Rank(over=...)` | `RANK() OVER (...)` | Leaves gaps after ties (1, 1, 3, …) |
| `DenseRank(over=...)` | `DENSE_RANK() OVER (...)` | No gaps after ties (1, 1, 2, …) |
| `RowNumber(over=...)` | `ROW_NUMBER() OVER (...)` | Unique sequential number per row |

```julia
using PormG: Rank, DenseRank, RowNumber, WindowOver

# Race 306 has two tie groups: Piquet/Patrese (6.0) and Suzuki/Alesi (1.0)
spec = WindowOver(partition_by=["raceid"], order_by=["-points"])

query = M.Driver_standings.objects
query.filter("raceid" => 306, "points__@gt" => 0)
query.values(
    "driverid__surname",
    "points",
    "rank"       => Rank(over=spec),
    "dense_rank" => DenseRank(over=spec),
    "row_number" => RowNumber(over=spec)
)
query.order_by("rank")
df = query |> DataFrame
```

Result:

```
9×5 DataFrame
 Row │ driverid__surname  points   rank   dense_rank  row_number
     │ String             Float64  Int64  Int64       Int64
─────┼─────────────────────────────────────────────────────────────
   1 │ Senna                 20.0      1           1           1
   2 │ Prost                  9.0      2           2           2
   3 │ Piquet                 6.0      3           3           3
   4 │ Patrese                6.0      3           3           4   ← tie: same rank & dense_rank, unique row_number
   5 │ Berger                 4.0      5           4           5   ← rank skips 4; dense_rank does not
   6 │ Modena                 3.0      6           5           6
   7 │ Nakajima               2.0      7           6           7
   8 │ Suzuki                 1.0      8           7           8
   9 │ Alesi                  1.0      8           7           9   ← tie: same rank & dense_rank, unique row_number
```

The three tie-handling strategies are now clearly visible:

| Rows | Situation | `Rank` | `DenseRank` | `RowNumber` |
| :--- | :--- | :--- | :--- | :--- |
| Piquet / Patrese | Tied at `6.0` | both `3` | both `3` | `3` / `4` |
| Berger | First after the tie | `5` — skips 4 | `4` — no skip | `5` |
| Suzuki / Alesi | Tied at `1.0` | both `8` | both `7` | `8` / `9` |

- **`Rank`** — shared rank, then a gap. The gap size equals the number of tied rows (two drivers tied at rank 3 → next rank is 5).
- **`DenseRank`** — shared rank, no gap. Berger gets rank 4, not 5.
- **`RowNumber`** — always unique, even for ties. The ordering between tied rows (`Piquet=3` vs `Patrese=4`) is **non-deterministic** unless you add a tiebreaker column to the window `order_by`.

> [!TIP]
> To make `RowNumber` deterministic for tied rows, add a unique column as a secondary sort: `WindowOver(partition_by=["raceid"], order_by=["-points", "driverid"])`.

Generated SQL (SQLite):

```sql
SELECT
    "Tb_1"."surname" as driverid__surname,
    "Tb"."points" as points,
    RANK()       OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."points" DESC) as rank,
    DENSE_RANK() OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."points" DESC) as dense_rank,
    ROW_NUMBER() OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."points" DESC) as row_number
FROM "driver_standings" as "Tb"
  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
WHERE "Tb"."raceid" = ?
  AND "Tb"."points" > ?
ORDER BY "rank" ASC
```

---

## Offset Functions — `Lag` and `Lead`

`Lag` reads from a previous row; `Lead` reads from a following row. Both accept a column reference, an optional `offset` (default `1`), and an optional `default` value returned when no such row exists.

```julia
using PormG: Lag, Lead, WindowOver

query = M.Lap_times.objects
query.filter("raceid" => 841, "driverid" => 1)
query.values(
    "lap",
    "milliseconds",
    # Previous lap time (offset=1, default 0 for the first lap)
    "prev_ms"  => Lag("milliseconds",  offset=1, default=0,
                      over=WindowOver(order_by=["lap"])),
    # Next lap time (default 0 for the final lap)
    "next_ms"  => Lead("milliseconds", offset=1, default=0,
                       over=WindowOver(order_by=["lap"]))
)
query.order_by("lap")
df = query |> DataFrame
```

Result (PostgreSQL, 58 laps — truncated):

```
58×4 DataFrame
 Row │ lap     milliseconds  prev_ms  next_ms
     │ Int32?  Int32?        Int64?   Int64?
─────┼────────────────────────────────────────
   1 │      1        100573        0    93774   ← no previous lap → default 0; next lap is lap 2
   2 │      2         93774   100573    92900   ← prev = lap 1 time; next = lap 3 time
   3 │      3         92900    93774    92582
  ⋮  │   ⋮          ⋮           ⋮        ⋮
  56 │     56         91813    91766    92184
  57 │     57         92184    91813    94576
  58 │     58         94576    92184        0   ← no next lap → default 0; prev = lap 57 time
                               52 rows omitted
```

`prev_ms` on row 2 (`100573`) matches `milliseconds` on row 1 — `Lag` looks back one row. `next_ms` on row 2 (`92900`) matches `milliseconds` on row 3 — `Lead` looks forward one row. Row 1 has no previous row and row 58 has no next row; both return `0` because `default=0` was specified. Without a `default`, those positions would return `missing`.

Generated SQL (PostgreSQL):

```sql
SELECT
    "Tb"."lap" as lap,
    "Tb"."milliseconds" as milliseconds,
    LAG("Tb"."milliseconds",  $1::integer, $2::bigint) OVER (ORDER BY "Tb"."lap" ASC) as prev_ms,
    LEAD("Tb"."milliseconds", $3::integer, $4::bigint) OVER (ORDER BY "Tb"."lap" ASC) as next_ms
FROM "lap_times" as "Tb"
WHERE "Tb"."raceid" = $5
  AND "Tb"."driverid" = $6
ORDER BY "lap" ASC
```

> [!TIP]
> The `offset` and `default` values are **parameterized** — `$1`/`$3` are the offsets (`1`), `$2`/`$4` are the defaults (`0`). They are never interpolated raw into the SQL string. The `::integer` and `::bigint` casts are PostgreSQL type-inference artefacts; SQLite omits them.

---

## Value Functions — `FirstValue`, `LastValue`, `NthValue`

These functions return the value of a column at a specific position within the window frame.

```julia
using PormG: FirstValue, LastValue, NthValue, WindowOver

spec = WindowOver(partition_by=["raceid"], order_by=["positionorder"])

query = M.Result.objects
query.filter("raceid" => 841)
query.values(
    "raceid",
    "driverid",
    "positionorder",
    # First finisher's points in this race
    "winner_pts"   => FirstValue("points", over=spec),
    # Last finisher's points (subject to default-frame trap — see below)
    "last_pts"     => LastValue("points",  over=spec),
    # Points of whoever finished second
    "second_pts"   => NthValue("points", 2, over=spec)
).limit(10)
df = query |> DataFrame
```

Result (PostgreSQL, first 10 of 24 finishers):

```
10×6 DataFrame
 Row │ raceid  driverid  positionorder  winner_pts  last_pts  second_pts
     │ Int64?  Int64?    Int32?         Float64?    Float64?  Float64?
─────┼───────────────────────────────────────────────────────────────────
   1 │    841        20              1        25.0      25.0   missing
   2 │    841         1              2        25.0      18.0      18.0
   3 │    841       808              3        25.0      15.0      18.0
   4 │    841         4              4        25.0      12.0      18.0
   5 │    841        17              5        25.0      10.0      18.0
   6 │    841        18              6        25.0       8.0      18.0
   7 │    841        13              7        25.0       6.0      18.0
   8 │    841        67              8        25.0       4.0      18.0
   9 │    841        16              9        25.0       2.0      18.0
  10 │    841       814             10        25.0       1.0      18.0
```

Three behaviours are visible at once:

**`winner_pts` (`FirstValue`)** — `25.0` on every row. The first row in the partition (position 1) scored 25 points; `FirstValue` always picks that value and broadcasts it to every row in the partition, regardless of where the frame ends.

**`last_pts` (`LastValue`)** — decreasing row by row: `25.0`, `18.0`, `15.0`, `12.0`, … This looks wrong but it is the SQL default. Without an explicit `frame=`, SQL uses `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — the frame only reaches up to and including the *current* row. At each row, the "last" value the function can see is the current row's own `points`, so it just echoes that value. To get the true last finisher's points broadcast to every row, pass `frame="ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"` — see [Frame Specifications](#frame-specifications-postgresql-only) for a side-by-side comparison.

**`second_pts` (`NthValue(2)`)** — `missing` on row 1, then `18.0` for all remaining rows. When processing row 1 the frame contains only one row (position 1), so there is no 2nd element — SQL returns `NULL`. Once row 2 enters the frame (position 2, driver 1, 18 points), `NthValue` finds that element and returns `18.0`. From row 3 onward the 2nd element never changes, so `second_pts` stays at `18.0` for every remaining row.

Generated SQL (PostgreSQL):

```sql
SELECT
    "Tb"."raceid" as raceid,
    "Tb"."driverid" as driverid,
    "Tb"."positionorder" as positionorder,
    FIRST_VALUE("Tb"."points") OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."positionorder" ASC) as winner_pts,
    LAST_VALUE("Tb"."points")  OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."positionorder" ASC) as last_pts,
    NTH_VALUE("Tb"."points", 2) OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."positionorder" ASC) as second_pts
FROM "result" as "Tb"
WHERE "Tb"."raceid" = $1
```

> [!NOTE]
> The `n` argument in `NthValue` is rendered as a **SQL literal integer** — notice `NTH_VALUE(..., 2)` above, not `NTH_VALUE(..., $2)`. PostgreSQL and SQLite do not accept a placeholder in that position.

---

## Arithmetic on Window Results

Window function results support the same arithmetic operators as `F()` expressions:

```julia
using PormG: RowNumber, Lag, WindowOver

spec = WindowOver(order_by=["lap"])

query = M.Lap_times.objects
query.filter("raceid" => 841, "driverid" => 1)
query.values(
    "lap",
    "milliseconds",
    # Convert to 0-based index
    "zero_based" => RowNumber(over=spec) - 1,
    # Lap-over-lap delta: positive → this lap was faster than the previous one
    "delta_ms"   => Lag("milliseconds", over=spec) - F("milliseconds")
)
df = query |> DataFrame
```

Result (PostgreSQL, 58 laps — truncated):

```
58×4 DataFrame
 Row │ lap     milliseconds  zero_based  delta_ms
     │ Int32?  Int32?        Int64?      Int32?
─────┼────────────────────────────────────────────
   1 │      1        100573           0   missing   ← lap 1: no previous row, Lag returns NULL
   2 │      2         93774           1      6799   ← 100573 - 93774 = 6799 ms gained vs lap 1
   3 │      3         92900           2       874   ← 93774 - 92900 = 874 ms gained
  ⋮  │   ⋮          ⋮            ⋮          ⋮
  56 │     56         91813          55       -47   ← 47 ms lost vs lap 55
  57 │     57         92184          56      -371   ← slowing
  58 │     58         94576          57     -2392   ← final lap: driver backs off after the line
                     52 rows omitted
```

`milliseconds` is the raw lap time in milliseconds — having it visible makes `delta_ms` immediately verifiable: row 2 gives `100573 − 93774 = 6799`, which matches the column exactly. `zero_based` starts at 0 because `ROW_NUMBER()` starts at 1 and we subtract 1. `delta_ms` is `prev_lap_time − current_lap_time`: positive means the current lap was faster (shorter), negative means it was slower.

Generated SQL (PostgreSQL):

```sql
SELECT
    "Tb"."lap" as lap,
    "Tb"."milliseconds" as milliseconds,
    (ROW_NUMBER() OVER (ORDER BY "Tb"."lap" ASC) - $1::bigint) as zero_based,
    (LAG("Tb"."milliseconds", $2::integer) OVER (ORDER BY "Tb"."lap" ASC) - "Tb"."milliseconds") as delta_ms
FROM "lap_times" as "Tb"
WHERE "Tb"."raceid" = $3
  AND "Tb"."driverid" = $4
```

The arithmetic is pushed inside the `SELECT` expression — `(ROW_NUMBER() OVER (...) - $1::bigint)` — so the subtraction happens in the database, not in Julia. The `::bigint` and `::integer` casts are PostgreSQL type-inference artefacts; on SQLite the same query omits them.

Supported operators: `+`, `-`, `*`, `/`

---

## Mixing with Aggregates

Window functions and aggregate functions can coexist in the same `values()` call. PormG correctly includes plain fields in `GROUP BY` while keeping window function aliases out of it.

```julia
using PormG: Count, Rank, WindowOver

# Per constructor: total results count + within-constructor ranking by points
query = M.Result.objects.filter("driverid__@in" => [846, 817], "points__@gt" => 0).values(
    "constructorid",
    "driverid__surname",
    "points",
    "total_results" => Count("resultid"),                          # aggregate
    "pts_rank"      => Rank(over=WindowOver(                       # window
        partition_by=["constructorid"],
        order_by=["-points"]
    ))
).filter("total_results__@gt" => 8)
df = query |> DataFrame
```

Result (PostgreSQL):

```
8×5 DataFrame
 Row │ constructorid  driverid__surname  points    total_results  pts_rank
     │ Int64?         String?            Float64?  Int64?         Int64?
─────┼─────────────────────────────────────────────────────────────────────
   1 │             1  Norris                 18.0             11         1   ← McLaren: highest pts value in this partition
   2 │             1  Norris                 10.0             12         2
   3 │             1  Norris                  6.0             13         3
   4 │             1  Norris                  4.0             10         4
   5 │             1  Norris                  2.0              9         5   ← lowest that cleared the HAVING > 8 threshold
   6 │             9  Ricciardo              15.0             16         1   ← constructor 9: pts_rank resets to 1
   7 │             9  Ricciardo              12.0             17         2
   8 │             9  Ricciardo              10.0             10         3
```

Each `(constructorid, driverid__surname, points)` combination is one group after `GROUP BY 1, 2, 3`. `total_results` counts how many race entries produced that exact points value. The `HAVING` clause (generated by the second `.filter("total_results__@gt" => 8)`) drops groups where that points value was scored 8 or fewer times. `pts_rank` is then computed inside each constructor's partition over the surviving rows — notice it resets from 5 back to 1 when the constructor changes at row 6.

Generated SQL (PostgreSQL):

```sql
SELECT
    "Tb"."constructorid" as constructorid,
    "Tb_1"."surname" as driverid__surname,
    "Tb"."points" as points,
    COUNT("Tb"."resultid") as total_results,
    RANK() OVER (PARTITION BY "Tb"."constructorid" ORDER BY "Tb"."points" DESC) as pts_rank
FROM "result" as "Tb"
  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
WHERE "Tb"."driverid" = ANY($1)
  AND "Tb"."points" > $2
GROUP BY 1, 2, 3
HAVING COUNT("Tb"."resultid") > $3
```

The second `.filter()` call after `.values()` targets a `Count` alias, so PormG promotes it to a `HAVING` clause rather than a `WHERE` clause.

> [!WARNING]
> **Semantic trap:** if the window `PARTITION BY` key matches the `GROUP BY` key exactly, each partition holds exactly one row after grouping — making `RANK()` always return `1`. Choose a partition key that differs from the grouping key, or use a subquery / CTE to apply the window after aggregation.

---

## Ordering Results by a Window Alias

Pass a window alias to `order_by()` exactly as you would any other alias:

```julia
query = M.Driver_standings.objects.filter("raceid__@lt" => 3, "points__@gt" => 0).values(
    "raceid",
    "driverid",
    "points",
    "race_rank" => Rank(over=WindowOver(partition_by=["raceid"], order_by=["-points"]))
)
query.order_by("driverid", "race_rank")  # ← window alias used in ORDER BY
df = query |> DataFrame
```

Result (PostgreSQL):

```
19×4 DataFrame
 Row │ raceid  driverid  points    race_rank
     │ Int64?  Int64?    Float64?  Int64?
─────┼───────────────────────────────────────
   1 │      2         1       1.0         10
   2 │      2         2       4.0          5
   3 │      1         3       3.0          6
   4 │      2         3       3.5          7
   5 │      2         4       4.0          5
   6 │      1         4       4.0          5
   7 │      1         7       1.0          8
   8 │      2         7       1.0         10
   9 │      1        10       5.0          4
  10 │      2        10       8.0          4
  11 │      1        15       6.0          3
  12 │      2        15       8.5          3
  13 │      2        17       1.5          9
  14 │      1        18      10.0          1
  15 │      2        18      15.0          1
  16 │      2        22      10.0          2
  17 │      1        22       8.0          2
  18 │      1        67       2.0          7
  19 │      2        67       2.0          8
```

The rows are sorted by `driverid` then `race_rank` — the window alias works as a plain sort key. Ranks are computed per `raceid` (partition restarts between races 1 and 2), and comparing the same driver across races shows the cumulative nature of `driver_standings`: driver 18 (Hamilton/Schumacher) holds rank 1 in both races but with different raw points (`10.0` in race 1, `15.0` in race 2).

Generated SQL (PostgreSQL):

```sql
SELECT
    "Tb"."raceid" as raceid,
    "Tb"."driverid" as driverid,
    "Tb"."points" as points,
    RANK() OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."points" DESC) as race_rank
FROM "driver_standings" as "Tb"
WHERE "Tb"."raceid" < $1
  AND "Tb"."points" > $2
ORDER BY "driverid" ASC,
  "race_rank" ASC
```

PormG quotes the alias in `ORDER BY` and never adds it to `GROUP BY`.

---

## SQLite Support

All window functions work on SQLite **3.25.0 and later** (released 2018-09-15). PormG checks the SQLite library version at query time and throws a clear `ArgumentError` if the library is too old.

```julia
# SQLite version check happens automatically — you do not need to call it yourself.
# If the library is too old, you will see:
# ArgumentError: SQLite window functions require SQLite >= 3.25.0; current SQLite library is 3.24.0.
```

The only SQLite limitation is **explicit frame specifications** (`frame=` argument). These are PostgreSQL-only for now.

---

## Function Reference

| Function | Arguments | SQL |
| :--- | :--- | :--- |
| `Rank(; over)` | — | `RANK() OVER (...)` |
| `DenseRank(; over)` | — | `DENSE_RANK() OVER (...)` |
| `RowNumber(; over)` | — | `ROW_NUMBER() OVER (...)` |
| `Lag(col; offset=1, default=nothing, over)` | column, offset, default | `LAG(col, offset, default) OVER (...)` |
| `Lead(col; offset=1, default=nothing, over)` | column, offset, default | `LEAD(col, offset, default) OVER (...)` |
| `FirstValue(col; over)` | column | `FIRST_VALUE(col) OVER (...)` |
| `LastValue(col; over)` | column | `LAST_VALUE(col) OVER (...)` |
| `NthValue(col, n; over)` | column, integer n | `NTH_VALUE(col, n) OVER (...)` |

### Current Limitations

- **Aggregate-over-window** (`SUM(...) OVER (...)`) is not yet implemented. Use a CTE to aggregate first, then apply the window in the outer query.
- **Named `WINDOW` clauses** (`WINDOW w AS (...)`) are not supported. Each function carries its own inline `OVER`.
- **SQLite explicit frame specs** throw `ArgumentError`. Use PostgreSQL for frame-bound queries.

---

## Next Steps

- **[Field Expressions](field_expressions.md)** — `F()` arithmetic that composes with window results.
- **[Subqueries and CTEs](subqueries_and_ctes.md)** — Wrap aggregated CTEs and apply window functions in the outer query.
- **[Filters and Aggregates](filters_and_aggregates.md)** — Aggregate functions and `HAVING` clause details.
