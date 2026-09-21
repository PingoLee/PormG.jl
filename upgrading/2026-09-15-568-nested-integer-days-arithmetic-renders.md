## Nested integer-days arithmetic now renders temporally, and PostgreSQL's integer-days SQL changed shape (#568)

- **Version**: 0.6.0
- **PormG ref**: #568 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-09-15
- **Severity**: behavior change

### What changed

`F(col) ± <a bare integer>` means whole days, and always has (#25). But the two places that
implemented it both required the left operand to be a plain column name, while the *duration*
spelling (`± Day(n)`) keys off the operand's type instead. So a duration composed over nesting and an
integer did not: the first link rendered correctly and the second was emitted as plain arithmetic on
whatever the first produced.

```julia
q.values("x" => (F("start_at") + 7) + 3)
```

| | before | after |
|---|---|---|
| SQLite | the **integer** `2012` for a 2009 timestamp — the inner `strftime(...)` text has NUMERIC affinity, so `'2009-…' + 3` is `2012`. Silent; `filter((F(c)+7)+3 == d)` matched nothing | the correct shifted instant |
| PostgreSQL | `StatementError: operator does not exist: timestamp with time zone + bigint` | the correct shifted instant |
| `(F("date") + 7) + Day(1)` (mixed chain) | the inner link escaped, then the outer wrapped an already-wrong left | correct |
| `F("date") + (-3)` on SQLite | `date(d, '+' || ? || ' days')` bound with `-3`, i.e. the modifier `'+-3 days'` — SQLite does not parse it and `date()` returns **NULL**, silently | `date(d, '-' || ? || ' days')` bound with `3` |

A single link (`F(c) + 7`) was already correct on both engines since #527 and is unchanged.

**The PostgreSQL SQL text changed shape.** Integer days rendered as `($1::bigint || ' days')::interval`
— a second implementation of what `Day(n)` already did. Both spellings now render
`make_interval(days => $1::integer)`. The two are equivalent to PostgreSQL, so **no query returns
different rows because of this**; only code that asserts the generated SQL *text* is affected.

### How to find the calls to migrate

```bash
# tests or snapshots pinning the old PostgreSQL text
grep -rn "days')::interval" .

# nested integer arithmetic on a date/timestamp column — the shape that was silently wrong
grep -rnE 'F\("[^"]+"\)[^)]*\+ *[0-9]+ *\) *[+-]' .
```

### Migrate your app

Nothing to change in application code — the expressions that were wrong are now right. Two things to
check:

```julia
# ✗ a test pinning the OLD PostgreSQL rendering
@test occursin("(\$1::bigint || ' days')::interval", sql)

# ✓ the rendering both spellings now share
@test occursin("make_interval(days => \$1::integer)", sql)
```

…and, if your app worked around the nested bug by pre-computing the offset, the workaround is now
redundant and can be collapsed back:

```julia
# ✗ before — the workaround for the escape
q.values("x" => F("start_at") + 10)

# ✓ after — the natural spelling composes correctly
q.values("x" => (F("start_at") + 7) + 3)
```

### Data repair

**On SQLite, rows written through the broken path are not repaired by this change, and some of them
cannot be repaired by any SQL.** `update("ts" => (F("ts") + 7) + 3)` stored the numeric result — a
bare integer such as `2012` — into the column.

The one-time repair published with #527 does **not** cover these rows, and that is deliberate rather
than an oversight: it is gated on `typeof("ts") = 'text'`, and these values are stored as integers.
Removing that clause would be worse than leaving them — it would reinterpret an integer as a Julian
day and destroy the evidence that the row is broken.

To find them:

```sql
SELECT rowid, "ts" FROM "my_table"
 WHERE "ts" IS NOT NULL AND typeof("ts") != 'text';
```

Rows this returns must be restored from a backup or recomputed from their source; there is no
in-place fix. PostgreSQL is unaffected — it refused the statement rather than writing it, which is
the one case where the loud failure was the better one.
