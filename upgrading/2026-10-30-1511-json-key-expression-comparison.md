## A comparison expression over a JSON key compares as the key lookup does (#1511)

- **Version**: Unreleased
- **PormG ref**: #1511 ; `src/querybuilder/expression_render.jl` (`_render_expr_node_sql`), `src/querybuilder/projection_types.jl` (`_render_json_key_expression_comparison`), `src/querybuilder/filter_operators.jl` (`_render_json_key_comparison`, `_json_key_carrier_refusal`)
- **Recorded**: 2026-10-30
- **Severity**: behavior change on every engine. A comparison over a key returns different rows on SQLite and PostgreSQL. A comparison of the key with a column on its right, or of a value that carries the key, now raises `FilterError` where it built.

### What changed

The filter pair over a JSON key (`filter("metadata__wins" => 5)`) binds the value as the key needs it
(#27). SQLite gets the value itself, because `json_extract` hands over the key's own type. PostgreSQL
and MySQL get text, and an ordering casts the key `::numeric` on PostgreSQL. The comparison operators
over the same key (`F("metadata__wins") == 5`) went through the generic operator path instead, and
bound the text `"5"` on every engine:

- On SQLite the integer `json_extract` returns is never equal to text, so `F("metadata__wins") == 5`
  matched no row, with no error.
- On PostgreSQL `F("metadata__wins") > 5` compared text, so `"9"` was greater than `"10"`.

The comparison now renders as the filter pair does, under the same operators and refusals. That covers
`filter`, `Q`/`Qor`, a `When` condition, a projection (`values("b" => F("metadata__wins") == 5)`) and an
ON clause. A column on the right of the key is refused, as the filter pair refuses it (#811):
`F("metadata__wins") > F("constructorid")`, and `F("metadata__wins") == "name"` where `"name"` is a
field. A value that carries the key without being it (`Coalesce("metadata__wins", 0) > 5`, a `Case`
branch) is refused, as a filter on its alias is (#1506). A key on the right of a column
(`F("constructorid") == F("metadata__wins")`) is unchanged: it renders as the filter pair
`"constructorid" => F("metadata__wins")` does.

| expression | before | now |
|---|---|---|
| `F("metadata__wins") == 5` on SQLite | bound `"5"`: no row | binds `5`: the rows whose key is 5 |
| `F("metadata__wins") > 5` on PostgreSQL | `#>> '{"wins"}' > $1`, text order | `(#>> '{"wins"}')::numeric > $1`, numbers |
| `F("metadata__wins") == "5"` on PostgreSQL | `= $1::text` | `= $1` (the same rows) |
| `F("metadata__wins") > F("constructorid")` on PostgreSQL | a server error when it ran (`text > bigint`) | `FilterError` when it is built |
| `F("metadata__wins") > F("constructorid")` on SQLite | compared the values | `FilterError` |
| `F("metadata__wins") > F("date")` (a date, time or interval column) on SQLite | `QueryBuildError` (#1310) | `FilterError` |
| `F("metadata__wins") > Date(2009, 1, 1)` on any engine | bound `"2009-01-01"` as text (SQLite: #1310's `QueryBuildError`) | `InvalidValueError`, as `"metadata__wins__@gt" => Date(2009, 1, 1)` |
| `Coalesce("metadata__wins", 0) > 5` on any engine | built (a server error on PostgreSQL) | `FilterError` |

A key cast to a type (`Cast("metadata__wins", "numeric") > 5`) states what it compares and is
unchanged, and so is a whole document (`F("metadata") == "{…}"`).

### Who this affects

Code that compares a JSONField key path with `==`, `!=`, `<`, `<=`, `>` or `>=`: in a filter, a `Q`, a
`When`, a projection or a join condition. On SQLite, such a comparison against a number now returns the
rows it was meant to return. On PostgreSQL, an ordering now compares numbers. Comparing the key with a
column on its right, or comparing a value that holds the key, now raises when the query is built.

### How to find the calls to migrate

```bash
grep -rnE 'F\("[A-Za-z0-9_]+__[A-Za-z0-9_]+"\) *(==|!=|<=|>=|<|>)' --include=*.jl src/ test/
grep -rnE '(Coalesce|NullIf|Abs|Floor|Ceil|Case)\(.*\) *(==|!=|<=|>=|<|>)' --include=*.jl src/ test/
```

For each hit, check whether the path ends in a JSONField key.

### Migrate your app

A comparison with a value needs no change. To compare the key with a column, or to compare a value
built from it, cast the key to the type you mean:

```julia
q = M.Constructor.objects
q.filter(Cast("metadata__wins", BigIntegerField()) > F("constructorid"))    # integers, on every engine
q.filter(Coalesce(Cast("metadata__wins", "numeric"), 0) > 5)
```
