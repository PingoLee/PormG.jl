## Temporal columns and expressions now read back as Julia values on SQLite (#564)

- **Version**: 0.6.0
- **PormG ref**: #564 ; `src/querybuilder/execution.jl`, `src/querybuilder/build_query.jl`, `src/value_repr.jl`, `src/Dialect.jl`
- **Recorded**: 2026-09-15
- **Severity**: behavior change

### What changed

On SQLite, `list()` used to return a Julia temporal value for exactly one shape: an alias naming a
**bare, unjoined `DateTimeField` column on the primary model**. Everything else came back as the raw
`String` SQLite stores — every expression alias, every joined column, and **every** `DateField`,
`TimeField` and `DurationField`, which had no read-side parser at all. PostgreSQL's driver delivered
typed values for all of them, so the same query returned different Julia types on the two engines.

The read path now resolves the canonical kind each projection *evaluates to* at build time and parses
by that, so SQLite matches what PostgreSQL already delivered. Three classes of alias change type:

| projection (SQLite) | before | after |
|---|---|---|
| `values("x" => F("start_at"))` | `"2009-03-29T06:00:00.000+00:00"` | `ZonedDateTime(…)` |
| `values("x" => F("start_at") + Day(1))` | `String` | `ZonedDateTime(…)` |
| `values("x" => "driverid__dob")` (joined) | `String` | `Date(…)` |
| `values("x" => F("date"))` on a `DateField` | `"2009-03-29"` | `Date(2009, 3, 29)` |
| `values("x" => F("time"))` on a `TimeField` | `"06:00:00"` | `Time(6, 0, 0)` |
| `values("x" => F("lap"))` on a `DurationField` | `"00:01:49.088"` | `Dates.CompoundPeriod(…)` |

`list(:json)` serializes a coerced value as the text its formatter writes, so a `DurationField`
renders `"00:01:49.088"` rather than the Julia struct.

**Parsing is fail-open and never lossy.** An expression PormG cannot type comes back exactly as the
driver delivered it, and so does a value in a shape the parser does not recognise — so the worst case
is the old behaviour, never a wrong typed value.

### What this does NOT cover

Worth knowing, because the boundary is not where you might guess:

- **Aggregates and SQL functions over a temporal column still read back raw on SQLite** —
  `values("m" => Max("start_at"))`, `Coalesce(...)`, `Cast(...)` and friends. PormG types an `F`
  expression and a plain column path; a `SQLTypeFunction` alias answers "no kind", which is the
  fail-open case above. What `Max(a_date_column)` evaluates to is a real design question and is not
  settled here.
- **`DataFrame(query)` was unchanged in this wave**, so the two APIs disagreed for four field
  types rather than one: `DataFrames.DataFrame(::SQLObjectHandler)` bypassed the read path, and a
  temporal column arrived as the driver's raw value there while `list()` gave a typed one. Most
  documentation examples end in `|> DataFrame`. #582 closed that divergence in the coercing
  direction — see its own entry above.

PostgreSQL is unaffected in every case — it already returned typed values.

### How to find the calls to migrate

```bash
# row keys on temporal columns
grep -rnE '\[:\w*(date|time|_at|dur)\w*\]' src/

# anything that re-parses, or compares against a string literal, a value PormG read back
grep -rnE '(Date|DateTime|Time)\(row\[|parse\(.*row\[' src/
```

The shape to look for is an app that compensated for the old behaviour by parsing the string itself.

### Migrate your app

```julia
row = M.Race.objects.filter("raceid" => 1).
    values("d" => F("date"), "t" => F("time")).
    list()[1]

# ✗ before — SQLite handed back text, so the app re-parsed it
d    = Date(row[:d])
late = row[:t] > "12:00:00"

# ✓ after — the value is already typed, and identically on both engines
d    = row[:d]              # ::Date
late = row[:t] > Time(12)

# ✓ or, to tolerate both pins while rolling out
d = row[:d] isa AbstractString ? Date(row[:d]) : row[:d]
```

No data migration is needed: nothing about what is STORED changed, only what `list()` hands back.
