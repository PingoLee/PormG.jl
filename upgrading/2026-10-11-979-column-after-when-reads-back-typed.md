## A column projected after a `When` on the same column reads back as its field's type (#979)

- **Version**: Unreleased
- **PormG ref**: #979 ; `src/querybuilder/build_select.jl` (`get_select_query`, `_memo_node_read_kind`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. The same query returns a different Julia type in one column.

### What changed

When a `Case`/`When` condition earlier in `values()` named a column, a later projection of that same
column skipped the step that records how to read it back, so it came back raw:

| Projection | before | after |
|---|---|---|
| SQLite: `values("c" => Case([When("date__@lt" => Date(2000), then = 1)], default = 0), "date")` on `Race` | `date` read as a `String` (`"1950-05-13"`) | `Date(1950, 5, 13)` |
| SQLite: the same shape over a `BooleanField` | `0` / `1` | `false` / `true` |
| PostgreSQL: the same shape over a `DurationField` | the raw driver value | the parsed duration, as without the `When` |

It applies to a plain column, a joined path and a CTE handle alike. The column now reads back with
the same type whatever is projected before it.

### Who this affects

Code that projects a `Case`/`When` over a column and that same column in one `values()` call, and
that handled the raw type it got back (parsing a date string, comparing with `1`).

### How to find the calls to migrate

```bash
grep -rnE 'values\(.*Case\(' --include=*.jl .
```

For each hit, check whether a column named in a `When` condition is also projected on its own.

### Migrate your app

```julia
rows = M.Race.objects.
    values("old" => Case([When("date__@lt" => Date(2000), then = 1)], default = 0), "date").
    list()

# ✗ before — SQLite handed back text, so the caller parsed it
d = Date(rows[1]["date"])

# ✓ after — it is already a Date
d = rows[1]["date"]
```
