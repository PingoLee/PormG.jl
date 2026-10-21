## PostgreSQL: a declared `Case` over literals binds its default as their type (#1316)

- **Version**: Unreleased
- **PormG ref**: #1316 ; `src/querybuilder/field_resolution.jl` (`_case_default_bind_type`)
- **Recorded**: 2026-10-21
- **Severity**: behavior change, PostgreSQL only. A `Case` with an `output_field` whose branches are all literals runs where the statement failed when it ran (`CASE types text and bigint cannot be matched`). A `Case` over duration literals cast to text returns PostgreSQL's interval text where it returned the literal's own text. SQLite is unchanged.

### What changed

A `Case` with an `output_field` casts its value, `(CASE … END)::<type>`. Each literal branch binds as
its own type (`$2::bigint` for an integer, `$2::date` for a date, `$2::interval` for a duration since
#1316), and when a branch was a column or an expression the literal default bound as the branches'
type (#1222). When **every** branch was a literal, the default still bound as the `output_field` type,
so the two disagreed whenever that type was another kind:

```sql
(CASE WHEN "Tb"."resultid" = $1 THEN $2::bigint ELSE $3::text END)::text   -- rejected by PostgreSQL
```

The default now binds as the literals' type there too, and the `output_field` casts the result:

```sql
(CASE WHEN "Tb"."resultid" = $1 THEN $2::bigint ELSE $3::bigint END)::text
```

Literals with no shared type (an integer or a duration beside a text default) keep the
`output_field` type, as before, and still fail when they run: write both branches as the same type.

Measured on the F1 fixture, `Case(When("resultid" => 1, then = a), default = b, output_field = "text")`
over results 1 and 2:

| `a`, `b` | before | now |
|---|---|---|
| `1`, `0` | raised `StatementError` (SQLSTATE 42804) | `["1", "0"]` |
| `Date(2020, 1, 1)`, `Date(2021, 1, 1)` | raised `StatementError` | `["2020-01-01", "2021-01-01"]` |
| `Hour(1)`, `Hour(2)` | `["1 hour", "2 hours"]` (the literals' text, untyped) | `["PT1H", "PT2H"]` (PostgreSQL's interval text) |

The SQL of a declared `Case` with a fractional `then` and an integer default moves too
(`ELSE $3::double precision` where it was `ELSE $3::<output_field>`); PostgreSQL resolved that
`CASE` to `double precision` either way, so its value does not change.

### Who this affects

Code on PostgreSQL that declares an `output_field` on a `Case` whose `then` and `default` are all
literals. Code that reads a `Case` over duration literals cast to text and parses that text.

### How to find the calls to migrate

```bash
grep -rnE 'Case\(.*output_field' --include=*.jl src/ test/
```

For each match, check whether every `then` and the `default` are literals.

### Migrate your app

```julia
# ✗ before — failed when it ran on PostgreSQL
q = M.Result.objects
q.values("c" => Case(When("resultid" => 1, then = 1), default = 0, output_field = "text"))

# ✓ after — the same call returns "1" and "0". A duration cast to text is PostgreSQL's interval text;
# to keep a duration, declare it: output_field = "interval" reads back a Dates.CompoundPeriod.
```
