## A filter on a Subquery alias over a JSON key compares as the key lookup does (#1492)

- **Version**: Unreleased
- **PormG ref**: #1492 ; `src/querybuilder/projection_types.jl` (`_json_key_lookup_operand`, its `Subquery` arm)
- **Recorded**: 2026-10-30
- **Severity**: behavior change on every engine. An ordering filter (`@gt`, `@gte`, `@lt`, `@lte`) on such an alias returns different rows, and so does an equality with a number on SQLite; an equality on text that raised now builds.

### What changed

A `Subquery` is its one projected column, so one that projects a JSON key lookup
(`s.values("w" => "metadata__wins")`) holds the key's value, not a document. A filter on its
projection alias bound the value through the document's JSON formatter, as a CTE column over a key did
before #1472 (in this train):

- an ordering bound the number as text: on PostgreSQL `(SELECT … #>> '{"wins"}' …) > $1` with `'100'`,
  a text comparison (`'99' > '100'` is true); on SQLite a number compared with text is never greater;
- equality with a number bound it as text (`"121"`), which SQLite's integer never equals;
- equality on plain text raised `InvalidValueError` ("The text is not valid JSON").

The filter now binds as `filter("metadata__wins" => …)` does (#1382): a numeric comparison for an
ordering (`((SELECT …))::numeric > $1` on PostgreSQL, the number bound as it is on SQLite and MySQL),
and plain text for an equality on PostgreSQL and MySQL, the native value on SQLite. A `When` condition
on the alias compares the same way. A `Subquery` over the whole document keeps the JSON formatter.

| filter on an alias `wins => Subquery(… values("w" => "metadata__wins"))` | before | now |
|---|---|---|
| `filter("wins__@gt" => 100)` on PostgreSQL, a row holding `99` | matched (text `'99' > '100'`) | not matched |
| `filter("wins__@gt" => 100)` on SQLite, a row holding `121` | not matched | matched |
| `filter("wins" => 121)` on SQLite, a row holding `121` | not matched | matched |
| `filter("principal" => "Toto Wolff")` over `metadata__principal` | `InvalidValueError` | matches the row |

### Who this affects

Code that projects a `Subquery` whose one column is a JSON key lookup and filters on its alias: with an
ordering comparison on any engine, or with a number for equality on SQLite. Equality filters on text
that raised before now run.

### How to find the calls to migrate

```bash
grep -rn 'Subquery(' --include=*.jl src/ test/
```

For each `Subquery`, check whether its projection is a JSONField path (`"w" => "metadata__wins"`) and
whether the outer query filters its alias with `@gt`, `@gte`, `@lt` or `@lte`, or compares it with a
number.

### Migrate your app

No code change is needed: the filter now means what it says. Where code relied on the text comparison,
compare text explicitly by casting in the subquery, `"w" => Cast("metadata__wins", "text")`.
