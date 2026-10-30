## An ordering over an uncast JSON key is refused on every engine (#1497)

- **Version**: Unreleased
- **PormG ref**: #1497 ; `src/querybuilder/projection_types.jl` (`_refuse_json_key_ordering`), `src/querybuilder/build_select.jl` (`get_order_query`), `src/querybuilder/select_nodes.jl` (window ordering, `Greatest`/`Least`)
- **Recorded**: 2026-10-30
- **Severity**: behavior change on every engine. A query that built now raises `QueryBuildError` when it is built. On PostgreSQL and MySQL it ordered the key's text, on SQLite its numbers.

### What changed

A JSON key's value has no declared type: the document decides, row by row, whether it is a number or
text. An ordering over it does not say which order it means, and the engines picked differently.
PostgreSQL (`#>>`) and MySQL (`JSON_UNQUOTE`) extract text, so over `{"wins": 9}` and `{"wins": 10}`
a descending order put `9` first. SQLite's `json_extract` hands over the number and put `10` first.
`Greatest`/`Least` over a key took the text as an operand on PostgreSQL and MySQL: PostgreSQL refused
it at the server beside a number column, and compared text beside a text one.
Earlier in this train, `Max`/`Min` over a key were refused for the same reason (#1491).

Each of these now raises `QueryBuildError` on every engine when the query is built, naming both
spellings:

- an `order_by` term over a key (`order_by("-metadata__wins")`);
- an `order_by` on a projection alias over a key (`values("w" => F("metadata__wins")).order_by("w")`),
  or over a value that carries one (`Coalesce("metadata__wins", 0)`, a `Case` branch);
- an `order_by` on a CTE column or a `Subquery` alias that holds a key's value;
- a labelled expression (`order_by(SQLOrder(SQLField(F("metadata__wins"), "o")))`);
- a window's `order_by` over a key;
- `Greatest`/`Least` with a key among their operands, with or without an `output_field`, which casts
  the result after the comparison.

| call, rows holding `wins` 9 and 10 | before | now |
|---|---|---|
| `order_by("-metadata__wins")` on PostgreSQL or MySQL | 9, then 10 | `QueryBuildError` |
| `order_by("-metadata__wins")` on SQLite | 10, then 9 | `QueryBuildError` |
| `values("g" => Greatest("metadata__wins", "constructorid"))` on PostgreSQL | a server error when it ran (`GREATEST types text and bigint cannot be matched`) | `QueryBuildError` when it is built |
| `order_by("metadata__principal")`, a key holding text | the text's order | `QueryBuildError` |

### Who this affects

Code that orders by a JSONField path, or by anything that projects one, and code that passes a JSONField
path to `Greatest` or `Least`. A key that holds text is affected too: the query does not say it is text.

### How to find the calls to migrate

```bash
grep -rnE 'order_by\(|Greatest\(|Least\(|WindowOver\(' --include=*.jl src/ test/
```

For each hit, check whether a term or an operand is a JSONField path (`"metadata__wins"`), or a name
projected from one.

### Migrate your app

`order_by` takes a path or a projected name, so project the cast and order by its name:

```julia
q = M.Constructor.objects
q.values("name", "wins" => Cast("metadata__wins", "numeric"))
q.order_by("-wins")                       # numbers, on every engine

q = M.Constructor.objects
q.values("name", "principal" => Cast("metadata__principal", "text"))
q.order_by("principal")                   # text, in each engine's collation
```

Cast each key operand of `Greatest`/`Least`: `Greatest(Cast("metadata__wins", "numeric"), "constructorid")`.
