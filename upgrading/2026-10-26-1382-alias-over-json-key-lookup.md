## A filter on a projection alias over a JSON key lookup compares as the key lookup does (#1382)

- **Version**: Unreleased
- **PormG ref**: #1382 ; `src/querybuilder/projection_types.jl` (`_having_alias_formatter`, `_alias_projects_json_key`)
- **Recorded**: 2026-10-26
- **Severity**: bug fix that changes a value. A filter on an alias over a JSON key lookup (`values("wins" => F("metadata__wins"))`, then `filter("wins" => …)`) now matches the rows `filter("metadata__wins" => …)` matches. A string compared with it no longer raises. A number compared with it matched no row on SQLite, and an ordering compared text on PostgreSQL and SQLite. MySQL is unreleased.

### What changed

An alias over a key lookup holds the key's value: text on PostgreSQL and MySQL, the JSON scalar on
SQLite. PormG typed it as the JSONField, so a filter on it ran the value through the JSON
formatter:

- a plain string (`"Toto Wolff"`) raised `InvalidValueError` ("The text is not valid JSON") on
  every engine;
- a number was formatted to the text `"121"`, which SQLite compares with the number `121` that
  `json_extract` returns, so no row matched;
- an ordering (`@gt`, `@gte`, `@lt`, `@lte`) compared with that text: on PostgreSQL the extracted
  text against it, so `'9' > '10'`, where the path lookup casts to `numeric`; on SQLite the number
  `json_extract` returns against text, which sorts above every number, so `@gt`/`@gte` matched no row
  and `@lt`/`@lte` every row.

A comparison on the alias (`=`, `@ne`, the orderings, `@isnull`) now renders as the path lookup's
own: the value bound as text on PostgreSQL and MySQL and as itself on SQLite, an ordering as a number.
An expression on the right (`filter("principal" => F("name"))`) renders as it did.
`@isnull` on the alias, which raised `FilterError` on SQLite, renders `IS NULL`. A pattern lookup or
a membership list on the alias binds the value as given, as before, and no longer checks it as a JSON
document. An alias over the whole document (`F("metadata")`) is unchanged.

| `values("wins" => F("metadata__wins"))` then | before | now |
|---|---|---|
| `filter("wins" => 121)`, SQLite | bound `"121"`: no row | bound `121`: the rows with 121 |
| `filter("wins__@gte" => 100)`, PostgreSQL | `… #>> '{"wins"}' >= '100'` (text) | `(… #>> '{"wins"}')::numeric >= 100` |
| `filter("wins__@gte" => 100)`, SQLite | `json_extract(…) >= '100'` | `json_extract(…) >= 100` |
| `filter("principal" => "Toto Wolff")` (alias over `metadata__principal`) | `InvalidValueError` | the rows with that principal |

### How to find the calls to migrate

Look for `values(... => F("<json_field>__<key>"))` followed by a `filter`, `Q` or `Qor` on that alias
with a number, an ordering lookup or `@isnull`, or a `try` around such a filter that expects an
`InvalidValueError`.

### Migrate your app

```julia
q = M.Constructor.objects
q.values("name", "principal" => F("metadata__principal"))

# ✗ before: raised InvalidValueError (and JSON text, "\"Toto Wolff\"", compared the quotes too)
q.filter("principal" => "Toto Wolff")

# ✓ now: the same call matches the rows with that principal, as the path lookup does
q.filter("principal" => "Toto Wolff")
```
