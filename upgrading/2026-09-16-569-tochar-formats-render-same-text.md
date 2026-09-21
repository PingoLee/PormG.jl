## `ToChar` formats render the same text on both engines; `HH` is 24-hour on PostgreSQL too (#569)

- **Version**: 0.6.0
- **PormG ref**: #569 ; `src/constants.jl`, `src/Dialect.jl`
- **Recorded**: 2026-09-16
- **Severity**: behavior change — on PostgreSQL, a `ToChar` format containing `HH` changes from the
  12-hour to the 24-hour clock; on both engines the `T`-separated and `.SSS` formats stop rendering
  garbage.

### What changed

`ToChar(x, format)` translated the format through a single map: the SQLite side was a `strftime`
mask, and the PostgreSQL side passed the *key* straight to `to_char`. Neither half had been evaluated
on its engine. Three SQLite masks spelled `%S.%f`, and `%f` is already `SS.SSS`, so the seconds
rendered twice (`…12:30:45.45.123`). On PostgreSQL the keys are not `to_char` templates: `HH` is the
12-hour clock there (`HH24` is 24-hour), a `T` before `H` parses as the ordinal-suffix pattern `TH`,
and `SSS` is `SS` plus a literal `S` — so `"YYYY-MM-DDTHH:MI:SS.SSS"` rendered `2031-07-04THH:30:45.45S`.

The map (`date_format_map`, formerly `sqlite_date_format_map`) now carries one spelling per engine,
and every key renders the same text on both for a given instant, with `HH` meaning the 24-hour
clock everywhere — which is what the SQLite half always meant. A format outside the map is still
passed through on PostgreSQL; on SQLite it now raises `BackendCapabilityError` naming the supported
formats, where it used to be a bare `KeyError`.

### How to find the calls to migrate

```bash
grep -rn 'ToChar(.*"[^"]*HH[^"]*"' --include='*.jl' .
```

Only a `ToChar` whose format contains `HH` and that ran against **PostgreSQL** can observe a change:
it rendered `01`–`12` and now renders `00`–`23`. Every other mapped format either renders identically
or was broken before.

### Migrate your app

```julia
# ✗ before — 12-hour on PostgreSQL, 24-hour on SQLite, for the same call
query.values("t" => ToChar("start_at", "HH:MI"))      # PostgreSQL: "06:00" at 18:00

# ✓ after — 24-hour on both; the portable format needs no change
query.values("t" => ToChar("start_at", "HH:MI"))      # both engines: "18:00"

# ✓ a 12-hour clock is a native PostgreSQL template, passed through (PostgreSQL-only)
query.values("t" => ToChar("start_at", "HH12:MI AM"))
```

`PormG.sqlite_date_format_map` no longer exists; it was never on the public surface and no consuming
app referenced it.
