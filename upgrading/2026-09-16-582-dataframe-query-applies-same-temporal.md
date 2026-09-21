## `DataFrame(query)` now applies the same temporal coercion as `list()` on SQLite (#582)

- **Version**: 0.6.0
- **Recorded**: 2026-09-16
- **PormG ref**: #582; `src/querybuilder/execution.jl` (`DataFrames.DataFrame(::SQLObjectHandler)`,
  `_projection_parsers`)
- **Severity**: behavior change — SQLite only. PostgreSQL DataFrames are unchanged.

### What changed

`query |> DataFrame` used to call the raw read directly and so skipped the read-side coercion
[#564](#temporal-columns-and-expressions-now-read-back-as-julia-values-on-sqlite-564) gave
`list()`. On SQLite that meant `list()` and `DataFrame(query)` disagreed on the type of every
temporal column — and most documentation examples end in `|> DataFrame`. Both terminals now select
their parsers from one place, so a DataFrame column holds the same Julia values a `PormGRow` does.

| Column | `eltype(df[!, col])` before (SQLite) | after |
|---|---|---|
| `DateTimeField` (`start_at`) | `Union{Missing, String}` | `Union{Missing, ZonedDateTime}` (`DateTime` for a `TIMESTAMP` column) |
| `DateField` (`date`) | `Union{Missing, String}` | `Union{Missing, Date}` |
| `TimeField` (`time`) | `Union{Missing, String}` | `Union{Missing, Time}` |
| `DurationField` | `Union{Missing, String}` | `Union{Missing, Dates.CompoundPeriod}` |
| a typed expression alias (`"x" => F("start_at") + Day(1)`, a joined temporal column) | `Union{Missing, String}` | the same typed value `list()` gives |

`missing` cells stay `missing`. A `SQLTypeFunction` alias (`Max("start_at")`, `Cast(...)`) still
reads back raw on SQLite, exactly as in `list()` — the #564 fail-open case is unchanged.

### How to find the calls to migrate

```bash
# every DataFrame read
grep -rnE '\|>\s*DataFrame|DataFrame\(.*\.objects' src/
# the parsing an app did itself because the column arrived as text
grep -rnE '(Date|DateTime|Time|ZonedDateTime)\.\(\s*df|parse\.\((Date|DateTime|Time)' src/
```

Only the second grep needs an edit; the first is the list of DataFrames whose column eltypes
changed (a `CSV.write`, a plot recipe or a `join` on a temporal column may now see a typed value
rather than text).

### Migrate

```julia
# before — the column was text on SQLite, so the app parsed it
df = M.Race.objects.filter("year" => 2009).values("name", "date") |> DataFrame
df.date = Date.(df.date)

# after — it is already a `Date`; the parse line goes
df = M.Race.objects.filter("year" => 2009).values("name", "date") |> DataFrame

# tolerant, while the app runs against both a pre- and post-#582 PormG
df.date = eltype(df.date) <: Union{Missing, AbstractString} ? Date.(df.date) : df.date
```

To keep the engine's own text on purpose, project it as text — `values("d" => ToChar("date",
"YYYY-MM-DD"))` or `Cast(F("date"), "TEXT")` — rather than relying on the DataFrame path being raw.
