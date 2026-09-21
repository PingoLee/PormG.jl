## bulk ops `copy=` kwarg removed — the pipeline never mutates (and never copies) your DataFrame

- **PormG ref**: issue #132 / PR #137 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking (kwarg removed) / behavior improvement

### What changed

`bulk_insert`, `bulk_copy`, and `bulk_update` no longer accept `copy::Bool`. The old
default (`copy=true`) deep-copied the entire DataFrame on every call; `copy=false` let
ORM-side normalization (default fills, `auto_now` columns) leak into the caller's frame.
The pipeline now works on a **zero-copy wrapper** (shared column vectors): the caller's
DataFrame is **never mutated and never copied**, unconditionally — strictly better than
both old modes. `allocate_primary_keys` is unchanged: `clone=true` still returns an
independent copy (that frame is *returned* to the caller, so it must not alias your
data), and `clone=false` still writes the pk column in place.

### How to find the calls to migrate

Grep each app for `copy=` / `copy =` on `bulk_insert`/`bulk_copy`/`bulk_update` calls
(or just run the app: passing the removed kwarg raises
`MethodError: ... got unsupported keyword argument "copy"`).

### Migrate your app

```julia
# ✗ before
bulk_insert(query, df, copy=true)    # paid a full deepcopy
bulk_update(query, df, columns=["points"], match_on=["id"], copy=false)  # mutated df

# ✓ after — just drop the kwarg; no-mutation is now the unconditional contract
bulk_insert(query, df)
bulk_update(query, df, columns=["points"], match_on=["id"])
```

If an app relied on `copy=false` to *receive* the injected columns (e.g. reading
`df.updated_at` after the call), that back-channel is gone — read the values back
through a query instead.

One subtle semantics shift: the old `copy=true` gave the bulk op a private *snapshot*
of your data; the zero-copy wrapper reads your live column vectors **during** the call.
Don't mutate the DataFrame from another task while a bulk op is executing on it (this
was never supported — it just happened to be masked by the default deepcopy).
