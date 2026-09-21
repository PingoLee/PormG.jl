## SQLite date arithmetic now renders in the stored timestamp format, and rows written by the old one need a one-time repair (#527)

- **Version**: 0.6.0
- **PormG ref**: #527 ; `src/Dialect.jl`, `src/querybuilder/execution.jl`
- **Recorded**: 2026-09-14
- **Severity**: behavior change

### What changed

On SQLite, `F(col) ± <duration>` used to render through SQLite's own `datetime(...)`, which emits
`YYYY-MM-DD HH:MM:SS`. A `DateTimeField` stores the canonical UTC form `YYYY-MM-DDTHH:MM:SS.sss+00:00`
(#79), and SQLite compares timestamps as **text** — so the expression could never equal a stored
value, and because a space sorts below `T` it always compared *less* than one. `<` and `>` were
systematically biased rather than occasionally wrong, with no error. PostgreSQL was unaffected, so
the same query returned different rows on the two engines.

The timestamp wrapper is now `strftime('%Y-%m-%dT%H:%M:%f+00:00', ...)`, whose output **is** the
stored format. Three behaviors follow:

| before | after |
|---|---|
| `filter(F("ts") + Day(1) == <instant>)` on SQLite | matched **nothing**, ever → returns the right rows |
| `values("next" => F("ts") + Day(1))` on SQLite | `"2024-01-02 10:00:00"` → `"2024-01-02T10:00:00.000+00:00"` |
| `update("ts" => F("ts") + Day(1))` on SQLite | **wrote** the non-canonical string into the column → writes the canonical one |

`F(ts) + <whole days as a bare integer>` on a `DateTimeField` was doing the same thing *and*
truncating the time-of-day; it now keeps both. Plain `DateField` arithmetic still renders `date(...)`
and is unchanged. A sub-day duration on a `DateField` now evaluates to a timestamp (as `date +
interval` does in standard SQL), so a date/datetime literal compared against it is promoted to match
— that comparison previously returned zero rows on **both** engines.

### Who this affects

SQLite apps only, and only those that have run `update("<a DateTimeField>" => F(...) ± <duration>)`.
PostgreSQL apps need nothing. Code that asserts on generated SQL text is the other affected case.

### How to find the calls to migrate

There are no calls to migrate — the API is unchanged. What to look for is **data** written by the old
renderer, and any test pinning the old SQL:

```bash
grep -rn 'update(.*F(.*[+-].*\(Day\|Week\|Month\|Year\|Hour\|Minute\|Second\|Interval\)' src/
grep -rn "datetime(" test/          # assertions on the old SQLite rendering
```

### Migrate your app

A `DateTimeField` row written by the old path holds a non-canonical string. It no longer matches any
filter, and `list()` hands it back as a `String` instead of a `ZonedDateTime`. Repair it once per
affected table, in SQL, by rewriting exactly those rows through the same mask PormG now emits:

```sql
UPDATE "my_table"
   SET "ts" = strftime('%Y-%m-%dT%H:%M:%f+00:00', "ts")
 WHERE "ts" IS NOT NULL
   AND typeof("ts") = 'text'
   AND "ts" NOT GLOB '*T*'
   AND strftime('%Y-%m-%dT%H:%M:%f+00:00', "ts") IS NOT NULL;
```

All three extra clauses are load-bearing, and every shorter spelling of this statement destroys data.
Measured against SQLite 3.53.4, running it twice over a `DATETIME`-declared column:

- **`typeof("ts") = 'text'`** — without it, any INTEGER or REAL in the column is reinterpreted as a
  **Julian day** and overwritten: `0` becomes `-4713-11-24T12:00:00.000+00:00`, `2460000.5` becomes
  `2023-02-25T00:00:00.000+00:00`. This is reachable rather than theoretical, because a
  `DateTimeField` is declared `DATETIME`, which has NUMERIC affinity — so a numeric-looking *string*
  written by a non-PormG client is converted to an integer on insert. `'12345'` stored that way came
  back as `-4679-09-12T12:00:00.000+00:00`. (Unix-epoch integers such as `1700000000` fall outside
  the Julian range and are saved by the clause below, but do not rely on that.)
- **`NOT GLOB '*T*'`, not `NOT LIKE '%T%'`** — canonical values all carry the `T` separator, and
  skipping them is what makes the statement idempotent. SQLite's `LIKE` is ASCII case-insensitive,
  so `'%T%'` also matches a lowercase `t` anywhere in the value; `GLOB` is the case-sensitive
  operator.
- **`strftime(...) IS NOT NULL`** — `strftime` returns `NULL` for anything it cannot parse, including
  an empty string, and without this clause the `UPDATE` writes that `NULL` over the original. A row
  holding `''` is silently emptied.

**Two cases the repair cannot fully fix.**

- `update("ts" => F("ts") ± <a bare integer>)` did not merely mis-format: it rendered `date(...)`, so
  the stored value is a bare `YYYY-MM-DD` and the time-of-day is already gone. The statement above
  rewrites it to `...T00:00:00.000+00:00` — canonical, matchable, and wrong by up to a day. Restore
  those from a backup if they matter.
- Rows written with a `Dates` duration kept their time-of-day, but only to the **second**: SQLite's
  `datetime()` has no sub-second resolution, so `…T12:30:00.123+00:00` was written back as
  `2031-07-05 12:30:00` and the repair restores `.000`. Do not reconcile a sub-second drift against
  this paragraph.
