## `DurationField`: a duration string is stored in canonical `HH:MM:SS` (#891)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #891; `src/Models.jl` (`_duration_string_nanoseconds`, `_normalize_duration_string`)
- **Severity**: behavior change. The SQL is unchanged. What changes is the text a duration string is
  written and bound as, and on SQLite that text is the stored value.

### What changed

A duration string was written as it was spelled, with only a missing leading field added. So no
field past its range was carried over. Now every accepted form is written as the `HH:MM:SS` text of
the same length, which is what a `Dates.Period` was always written as:

| Input | before | after |
|---|---|---|
| `"125:30"` | `"00:125:30"` | `"02:05:30"` |
| `"90"` | `"00:00:90"` | `"00:01:30"` |
| `"120"` | `"00:00:120"` | `"00:02:00"` |
| `"01:75:00"` | `"01:75:00"` | `"02:15:00"` |
| `"1:27:30.5"` | `"1:27:30.5"` | `"01:27:30.5"` |
| `Interval("120").period` | `Second(120)` (with the other fields zero) | `Minute(2)` (the same length) |

The forms accepted are unchanged. A count too large for `Int64` now raises `InvalidValueError`
instead of being written.

**On SQLite this matters for rows written before.** A `DurationField` there holds the text, so rows
written by the old writer keep their old spelling.
- `"00:125:30"` does not read back as a duration at all. #881 and #894 parse it as **12:05** when
  they compare or sort it.
- A filter that spells a value the old way no longer matches those rows.
  `filter("time" => "1:27:30")` now binds `"01:27:30"`, and a stored `"1:27:30"` is a different text.

PostgreSQL stores an `interval`, so its rows are unaffected.

### How to find the calls to migrate

Only SQLite databases written to before this change are affected, and only through their
`DurationField` columns. The re-save below is idempotent, because a canonical row is written back
unchanged, so run it over every row rather than hunting for the old ones. Filters that spell a
duration as a string literal are the code to look at:

```bash
grep -rnP '=>\s*"-?\d+(:\d|(\.\d+)?")|Interval\("' src/
```

### Migrate your app

Re-save the old rows once, through the ORM, so the writer stores them canonically:

```julia
using Dates
# A stored value reads back as a Dates.CompoundPeriod, or as the raw String when it is not HH:MM:SS
# (`00:125:30`). Rebuild the period from the String; the writer then stores the canonical text.
function _duration_of(v)
  v isa Dates.CompoundPeriod && return v
  m = match(r"^(-?)(\d+):(\d+):(\d+)(?:\.(\d+))?$", v)
  p = Hour(parse(Int, m[2])) + Minute(parse(Int, m[3])) + Second(parse(Int, m[4])) +
      Nanosecond(m[5] === nothing ? 0 : parse(Int, rpad(first(m[5], 9), 9, '0')))
  return m[1] == "-" ? -p : p
end

rows = M.Result.objects.
    filter("fastestlaptime__@isnull" => false).
    values("resultid", "fastestlaptime").
    list(:dict)
for row in rows
  M.Result.objects.
      filter("resultid" => row[:resultid]).
      update("fastestlaptime" => _duration_of(row[:fastestlaptime]))
end
```

Then spell filter strings either way. `"1:27:30"` and `"01:27:30"` now bind the same text.
