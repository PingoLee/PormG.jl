## `DateTimeField` values are canonicalized to UTC — existing **SQLite** rows must be re-normalized once

- **PormG ref**: issue #79 ; `src/Models.jl` (`format_timezone_sql` / `validate_timezone`)
- **Recorded**: 2026-07-13
- **Severity**: breaking (SQLite stored-data format) / behavior fix
- **This is a data change, not a code change** — the PormG API is unchanged; there are no call
  sites to edit. The rollout is a one-time SQLite data re-normalization.

### What changed

`DateTimeField` values are now canonicalized to a single UTC ISO-8601 string
(`yyyy-mm-ddTHH:MM:SS.sss+00:00`) on **both** the write/bind path and the filter path — the
convention Django (`USE_TZ=True`), Rails, and SQLAlchemy already use. Previously PormG stored
offset-bearing strings verbatim (e.g. `auto_now` under `America/Sao_Paulo` was written as
`…-03:00`, and a `Z` / `.0` filter value was passed through unchanged).

- **PostgreSQL** is transparent: `TIMESTAMPTZ` compares by instant, so filters were already
  correct and stored data is unaffected — nothing to do.
- **SQLite** stores datetimes as TEXT and compares them lexicographically, so the old
  non-canonical strings made equality/range filters **diverge from PostgreSQL** whenever the
  filter value's spelling differed from the stored spelling (issue #79). Going forward both the
  stored value and the filter value are canonical UTC, so the comparison is correct — **but
  rows written by the old code are still in their old spelling** and must be re-normalized once.

### Who is affected

- PostgreSQL-only apps → mark `—`.
- SQLite apps whose `DateTimeField` columns are empty or freshly created after this bump → mark `—`.
- SQLite apps with **pre-existing** `DateTimeField` data → run the one-time re-normalization below.

### Re-normalize existing SQLite data (one time)

The read path already reconstructs the correct instant from any offset spelling, so a
read-modify-write through PormG reuses PormG's own parser/formatter and is the safest recipe.
For each SQLite model + `DateTimeField` column:

```julia
# `col` is any DateTimeField column on `M.Thing` (SQLite backend).
for row in M.Thing.objects.values("id", "col").list()
    (ismissing(row[:col]) || row[:col] === nothing) && continue   # skip SQL NULL (surfaces as missing)
    q = M.Thing.objects
    q.filter("id" => row[:id])
    q.update("col" => row[:col])                # re-writing stores the canonical UTC form
end
```

(An equivalent single SQL `UPDATE` that converts each value to canonical UTC works too, but the
read-modify-write above avoids hand-rolling the offset math.) Verify with a `Z`-spelled value
that previously missed on SQLite:

```julia
@assert M.Thing.objects.filter("col" => "2020-01-01T10:00:00Z").exists()  # a known stored instant
```
