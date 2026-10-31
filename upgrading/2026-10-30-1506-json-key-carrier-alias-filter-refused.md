## A filter on an alias over a value that carries an uncast JSON key is refused on every engine (#1506)

- **Version**: Unreleased
- **PormG ref**: #1506 ; `src/querybuilder/projection_types.jl` (`_refuse_json_key_carrier_filter`, `_render_alias_predicate_node`), `src/querybuilder/filter_operators.jl` (`_json_key_carrier_refusal`), `src/querybuilder/filter_nodes.jl`
- **Recorded**: 2026-10-30
- **Severity**: behavior change on every engine. A filter that built now raises `FilterError`. Over a key holding a number, it matched no row on SQLite and raised no error, and it failed at the server on PostgreSQL. Over a key holding text, with a text default, it returned the right rows, and it is refused too.

### What changed

A filter on a projection alias over a JSON key (`values("wins" => F("metadata__wins"))`) compares as
the key lookup does (#1382). An alias over a value that *carries* the key without being it did not:
`Coalesce("metadata__wins", 0)`, a `Case` branch, `Abs`/`Floor`/`Ceil` of the key, or a `Subquery`
projecting one of these. (`NullIf` over the key is refused earlier, where it is built, by #1510's
entry, so no alias, CTE column or `Subquery` holds it any more.) The compared value was bound through the
alias's own formatter, as text. SQLite's `json_extract` hands over the integer, and an integer is never equal to
or greater than text, so the filter matched no row and raised no error. On PostgreSQL
`COALESCE(text, bigint)` is a server error. A key that holds text, with a text default
(`Coalesce("metadata__principal", Value("none"))`), compared correctly. It is refused all the same,
because the query does not say the key holds text.

Such a filter now raises `FilterError` on every engine when the query is built. That covers `filter`,
`Q`, a `When` condition on the alias and a column on the right. The message names the alias, what it
holds and the cast to write inside the expression. `@isnull` on the alias is unchanged. An `order_by`
on the same alias was already refused earlier in this train (#1497), and so was arithmetic over the key
(#1483).

| filter, an alias `wins => Coalesce("metadata__wins", 0)`, a row holding `15` | before | now |
|---|---|---|
| `filter("wins__@gt" => 9)` on SQLite | not matched (bound `"9"`) | `FilterError` |
| `filter("wins" => 15)` on SQLite | not matched (bound `"15"`) | `FilterError` |
| `filter("wins__@gt" => 9)` on PostgreSQL | a server error when it ran | `FilterError` when it is built |
| `filter("wins__@gt" => F("constructorid"))` on any engine | built | `FilterError` |
| `filter("p" => "Senna")`, an alias `p => Coalesce("metadata__principal", Value("none"))` | matched | `FilterError` |

### Who this affects

Code that filters an alias over `Coalesce`, `Case`, `Abs`, `Floor` or `Ceil` with a
JSONField path among its operands, or a `Subquery` alias projecting one.

### How to find the calls to migrate

```bash
grep -rnE '(Coalesce|NullIf|Case|When|Abs|Floor|Ceil)\(' --include=*.jl src/ test/
```

For each hit inside a `values(…)` whose alias is later filtered, check whether an operand is a
JSONField path (`"metadata__wins"`).

### Migrate your app

Cast the key inside the expression:

```julia
q = M.Constructor.objects
q.values("name", "wins" => Coalesce(Cast("metadata__wins", "numeric"), 0))
q.filter("wins__@gt" => 9)                 # numbers, on every engine
```

Use `Cast("metadata__principal", "text")` to compare text:
`Coalesce(Cast("metadata__principal", "text"), Value("none"))`.
