## A filter on an alias over a JSON key refuses the lookups the key lookup refuses (#1499)

- **Version**: Unreleased
- **PormG ref**: #1499 ; `src/querybuilder/filter_operators.jl` (`_json_key_operator_refusal`), `src/querybuilder/projection_types.jl` (`_render_alias_predicate_node`), `src/querybuilder/filter_nodes.jl`
- **Recorded**: 2026-10-30
- **Severity**: behavior change on every engine. A filter that built now raises `FilterError`; on PostgreSQL one of them (`@range`) returned the wrong rows.

### What changed

A filter on a JSON key lookup (`"metadata__wins__@range" => …`) takes `=`, `@ne`, `@gt`, `@gte`, `@lt`,
`@lte` and `@isnull`, and refuses every other lookup with `FilterError`. A filter on something that
holds the key's value took those comparisons as the key lookup does (#1382, #1472, #1492), but let
the other lookups through, binding their values as given. That covers a projection alias over the key
(`values("wins" => F("metadata__wins"))`), a CTE column whose body projects the key, and a `Subquery`
alias projecting it. PostgreSQL extracts a key as text, so `@range` there compared text: a row holding
`15` is not between `'9'` and `'100'`, and it was skipped without an error.

Those lookups (`@in`, `@nin`, `@range`, `@nrange` and the pattern lookups `@contains`, `@startswith`,
`@iexact`, …) now raise `FilterError` on all three handles and on every engine, as on the key lookup.
The same holds for a `When` condition on such an alias. The message names the lookup as written and
the spelling that states a type. The key lookup's own message changed too: it names the lookup as
written (`@startswith`, where it named the internal `startswith`) and the path.

| filter, an alias `wins => F("metadata__wins")`, a row holding `15` | before | now |
|---|---|---|
| `filter("wins__@range" => (9, 100))` on PostgreSQL | not matched | `FilterError` |
| `filter("wins__@range" => (9, 100))` on SQLite | matched | `FilterError` |
| `filter("wins__@in" => [15, 99])` on any engine | matched | `FilterError` |
| `filter("wins__@startswith" => "1")` on any engine | built | `FilterError` |

### Who this affects

Code that filters a projection alias, a CTE column or a `Subquery` alias over a JSON key with `@in`,
`@nin`, `@range`, `@nrange` or a pattern lookup. A filter on the key itself is unchanged: it already
refused them.

### How to find the calls to migrate

```bash
grep -rnE '__@(n?in|n?range|n?i?(contains|startswith|endswith|exact|regex)|n?iunaccent_(contains|exact))"' --include=*.jl src/ test/
```

For each hit, check whether the name before the lookup is an alias, a CTE column or a `Subquery` whose
projection is a JSONField path (`F("metadata__wins")`, `"w" => "metadata__wins"`).

### Migrate your app

Project the key with the type you mean and filter that name:

```julia
q = M.Constructor.objects
q.values("name", "wins" => Cast("metadata__wins", "numeric"))
q.filter("wins__@range" => (9, 100))       # numbers on every engine
```

Use `Cast("metadata__principal", "text")` for a pattern lookup or for a membership list of text.
