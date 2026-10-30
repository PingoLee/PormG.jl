## A filter on a CTE column over a JSON key compares as the key lookup does (#1472)

- **Version**: Unreleased
- **PormG ref**: #1472 ; `src/querybuilder/filter_nodes.jl` (the key-value arm beside `_render_json_lookup_comparison`)
- **Recorded**: 2026-10-30
- **Severity**: behavior change on every engine. An ordering filter (`@gt`, `@gte`, `@lt`, `@lte`) on such a column returns different rows, and so does an equality with a number on SQLite; an equality on text that raised now builds.

### What changed

A CTE column whose body projects a JSON key lookup (`"wins" => "metadata__wins"`) holds the key's
value, not a document. (A body `Max` or `Min` of a key raises since #1491, in this train.) A filter on it from the outer query bound the value through
the document's JSON formatter:

- equality on plain text raised `InvalidValueError` ("The text is not valid JSON");
- equality with a number bound it as text (`"121"`), which SQLite's integer never equals, so
  `filter("m__wins" => 121)` matched no row there;
- an ordering bound the number as text: on PostgreSQL `"R1_1"."wins" > '100'`, a text comparison
  (`'121' > '100'` is true, but `'99' > '100'` is true as well); on SQLite a number compared with text
  is never greater; MySQL compared it as a JSON value.

The filter now binds as `filter("metadata__wins" => …)` does (#1382): plain text for an equality on
PostgreSQL and MySQL and the native value on SQLite, and a numeric comparison for an ordering (`("R1_1"."wins")::numeric > $1` on PostgreSQL, the number bound
as it is on SQLite and MySQL). A CTE column over the whole document keeps the JSON formatter.

| filter on a CTE column `m__wins` over `metadata__wins` | before | now |
|---|---|---|
| `filter("m__wins__@gt" => 100)` on PostgreSQL, a row holding `99` | matched (text `'99' > '100'`) | not matched |
| `filter("m__wins__@gt" => 100)` on SQLite, a row holding `121` | not matched | matched |
| `filter("m__wins" => 121)` on SQLite, a row holding `121` | not matched | matched |
| `filter("m__principal" => "Toto Wolff")` | `InvalidValueError` | matches the row |

### Who this affects

Code that filters on a CTE column whose body projects a JSON key lookup: with
an ordering comparison on any engine, or with a number for equality on SQLite. Equality filters on
text that raised before now run.

### How to find the calls to migrate

```bash
grep -rnE '\.with\(' --include=*.jl src/ test/
```

For each CTE, check whether a body column is a JSONField path (`"x" => "metadata__wins"`), and whether the outer query filters that column with `@gt`, `@gte`, `@lt` or `@lte`, or
compares it with a number.

### Migrate your app

No code change is needed: the filter now means what it says. Where code relied on the text comparison,
compare text explicitly by casting in the body, `"wins" => Cast("metadata__wins", "text")`.
