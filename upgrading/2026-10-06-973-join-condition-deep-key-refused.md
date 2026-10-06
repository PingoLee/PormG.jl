## `on()` / `cjoin(filters = …)` — a left-side key reaching past the hop raises (#973)

- **Version**: Unreleased
- **PormG ref**: #973, #977 ; `src/querybuilder/join_conditions.jl` (`_refuse_lhs_past_hop`)
- **Recorded**: 2026-10-06
- **Severity**: breaking. A join-condition key whose relation part went past the join path was accepted, and PormG silently added that relation's join, with the predicate in its `ON` clause. It now raises `FilterError`, on both engines: at the `on()` / `cjoin()` call, or when the query is built for a path through a `cjoin(field = …)` link, whose target is known only then. The deep-key spelling was documented as a tip on the custom-joins page.

### What changed

A condition's left side names the joined row: `"number"` in `on("driverid", …)` is the driver's
`number`. A key that went further — into a relation of the joined model — named a row of THAT
relation instead, and resolving it added the relation's join, which nothing in the query had asked
for:

| query | before | after |
|---|---|---|
| `on("driverid", "results__grid" => 1)` | adds `INNER JOIN "result"` (reverse: repeats base rows) with `"grid" = $1` in its `ON` | raises `FilterError` |
| `cjoin("raceid" => "Race", filters = ["circuitid__country" => "Italy"])` | adds the circuit join with `"country" = $1` in its `ON` | raises `FilterError` |
| `on("test_deletion", "just_a_nested_roll_back__description" => "x")` | adds the nested join with the predicate in its `ON` | raises `FilterError` |

Every spelling behaves the same way: a bare pair, `Q(...)`, `Qor(...)`, `OP(...)`, an `F` on the left,
a function or `Case` on the left. Keys that stay on the hop still render exactly as before, in both
spellings: `"country"` and the already-prefixed `"circuitid__country"` on `on("raceid__circuitid", …)`.
A ForeignKey column of the hop itself (`"circuitid"` on `on("raceid", …)`) is on the hop.

### Who this affects

Apps that write a join-condition key through a relation of the joined model. Measured on 2026-10-06:
**0** call sites in the consuming apps, which make no `on()` or `cjoin()` calls at all.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
past the join path
```

To find the candidates by hand, list join conditions whose key holds a `__` path. The pattern matches
`q.on(` as well as an `on(`/`cjoin(` that a trailing-dot chain starts on its own line; a lookup suffix
(`__@gte`) is a match too, so read each hit:

```bash
grep -rnE '(^|[.[:space:]])(on|cjoin)\(.*"[A-Za-z0-9_]+__[A-Za-z]' --include='*.jl' <your-app>/src
```

### Migrate your app

Write the predicate on the hop that owns the column, with `on()`. Since #977 `on()` builds that join
when nothing else in the query reaches the path, so the predicate cannot be dropped. Pass
`join_type = "INNER"` where the predicate is meant to restrict rows, as the deep `cjoin` filter did
under an `INNER` cjoin; or put it in `.filter(...)`.

```julia
# ✗ before: the circuit predicate rode inside the race cjoin's filters
M.Result.objects.
    cjoin("raceid" => "Race", join_type = "INNER",
          filters = ["circuitid__country" => "Italy", "year" => 2009], warn = false).
    values("resultid")

# ✓ after: one predicate per hop
M.Result.objects.
    cjoin("raceid" => "Race", join_type = "INNER", filters = ["year" => 2009], warn = false).
    on("raceid__circuitid", "country" => "Italy", join_type = "INNER").
    values("resultid")
```
