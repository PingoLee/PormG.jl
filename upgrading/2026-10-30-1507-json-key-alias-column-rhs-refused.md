## A column expression compared with an alias, CTE column or Subquery over a JSON key is refused as on the key (#1507)

- **Version**: Unreleased
- **PormG ref**: #1507 ; `src/querybuilder/projection_types.jl` (`_render_alias_predicate_node`), `src/querybuilder/filter_nodes.jl` (`_render_filter_oper`), `src/querybuilder/filter_operators.jl` (`_render_json_lookup_comparison`)
- **Recorded**: 2026-10-30
- **Severity**: behavior change on every engine. A filter that built now raises `FilterError`. On PostgreSQL it failed at the server. On SQLite it compared the values.

### What changed

A filter on a JSON key lookup refuses a column expression on the right (#811):
`filter("metadata__wins" => F("constructorid"))` raises `FilterError` ("a JSON path lookup compares
the extracted value against a value, not a column expression"). A filter on something that holds the
key's value compares as the key lookup does (#1382, #1472, #1492, #1499). That covers a projection alias
over the key (`values("wins" => F("metadata__wins"))`), a CTE column whose body projects it and a
`Subquery` alias projecting it. On this one shape they did not: they skipped any expression or
queryset on the right and rendered a column comparison. PostgreSQL then compared the key's text with a
bigint, which is a server error.

All three handles now raise the key's own `FilterError` on every engine. That applies to an `F`, a
function and a `Subquery` on the right, under any operator, and to a `filter`, a `Q` and a `When`
condition on the alias. A queryset under `@in`/`@nin` on these handles built `IN (SELECT …)`. It now
raises the #1499 refusal, as on the key.

This reverses one sentence of the #1382 entry (0.9.0): "An expression on the right
(`filter("principal" => F("name"))`) renders as it did." For an alias over a JSON key, it is now
refused. An alias over any other column still compares with an expression. The expression comparison
`F("metadata__wins") == F("constructorid")` is refused the same way (#1511).

| filter, an alias `wins => F("metadata__wins")` | before | now |
|---|---|---|
| `filter("wins__@gt" => F("constructorid"))` on PostgreSQL | a server error when it ran (`text > bigint`) | `FilterError` when it is built |
| `filter("wins__@gt" => F("constructorid"))` on SQLite | compared the values | `FilterError` |
| `filter("wins__@in" => M.Constructor.objects.values("constructorid"))` on any engine | built `IN (SELECT …)` | `FilterError` |

### Who this affects

Code that compares a projection alias, a CTE column or a `Subquery` alias over a JSONField path with an
`F`, a function, a `Subquery` or a queryset. A comparison with a value is unchanged.

### How to find the calls to migrate

```bash
grep -rnE 'filter\(.*=> *(F|Subquery|Coalesce|Abs|Cast)\(' --include=*.jl src/ test/
```

For each hit, check whether the name on the left is an alias, a CTE column or a `Subquery` whose
projection is a JSONField path.

### Migrate your app

Project the key with the type you mean and compare that name:

```julia
q = M.Constructor.objects
q.values("name", "wins" => Cast("metadata__wins", BigIntegerField()))
q.filter("wins__@gt" => F("constructorid"))       # integers, on every engine
```
