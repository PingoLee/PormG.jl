## `NullIf` over an uncast JSON key is refused on every engine (#1510)

- **Version**: Unreleased
- **PormG ref**: #1510 ; `src/querybuilder/select_nodes.jl` (the function render, beside the #1491/#1497 checks), `src/querybuilder/projection_types.jl` (`_refuse_json_key_operand`)
- **Recorded**: 2026-10-31
- **Severity**: behavior change on every engine. A `NullIf` that built now raises `QueryBuildError`. On PostgreSQL a numeric second operand failed at the server. On SQLite it compared the value the document holds, and a key holding text compared correctly on both.

### What changed

`NullIf(a, b)` compares its operands for equality. With an uncast JSON key in either operand
(`NullIf("metadata__wins", 0)`, `NullIf("constructorid", "metadata__wins")`, `NullIf(Coalesce(key, 0), 0)`),
the query does not say whether the comparison is between numbers or text:

- PostgreSQL extracts the key as text: `NULLIF("Tb"."metadata" #>> '{"wins"}', $1::bigint)` is
  `text = bigint`, a server error.
- SQLite's `json_extract` hands over the number the document holds and compared it with `0`.

The same expression also answered differently depending on where it sat. A filter on its projection
alias was refused as a carrier of the key (#1506), while a CTE column or a `Subquery` over it compared
as the key itself (#1472, #1492).

It now raises `QueryBuildError` where it is built, on every engine: in a projection, a CTE body, a
`Subquery`, a filter value, an `update()` value, or under another function. This is the same
explicit-intent rule `Max`/`Min` over a key follow (#1491). The message names the cast to write. A
key holding text (`NullIf("metadata__principal", Value(""))`) compared correctly on both engines,
and it is refused all the same, because the query does not say the key holds text.

| expression | before | now |
|---|---|---|
| `values("w" => NullIf("metadata__wins", 0))` on PostgreSQL | a server error when it ran | `QueryBuildError` when it is built |
| `values("w" => NullIf("metadata__wins", 0))` on SQLite | `NULL` for no wins | `QueryBuildError` |
| `values("p" => NullIf("metadata__principal", Value("")))` on any engine | `NULL` for an empty principal | `QueryBuildError` |
| a CTE column `w => NullIf("metadata__wins", 0)`, then `filter("m__w__@gt" => 100)` | compared as the key | `QueryBuildError` |
| `values("w" => NullIf(Cast("metadata__wins", "numeric"), 0))` | built | builds (unchanged) |

### Who this affects

Code that calls `NullIf` with a JSONField key path (`"metadata__wins"`) as either operand, or with a
value built over one (`Coalesce`, a `Case` branch).

### How to find the calls to migrate

```bash
grep -rnE 'NullIf\(' --include=*.jl src/ test/
```

For each hit, check whether an operand is a JSONField path or a function over one.

### Migrate your app

Cast the key to the type you mean:

```julia
q = M.Constructor.objects
q.values("name", "wins" => NullIf(Cast("metadata__wins", "numeric"), 0))                # numbers
q.values("name", "principal" => NullIf(Cast("metadata__principal", "text"), Value(""))) # text
```
