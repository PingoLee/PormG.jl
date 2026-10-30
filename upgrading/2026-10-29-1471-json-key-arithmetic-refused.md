## Arithmetic, `Sum`, `Avg`, `Max` and `Min` over an uncast JSON key are refused on every engine (#1471, #1482, #1483, #1491)

- **Version**: Unreleased
- **PormG ref**: #1471, #1482, #1483, #1491 ; `src/querybuilder/projection_types.jl` (`_json_number_side`, `_refuse_json_key_arithmetic`), `src/querybuilder/ctes.jl` (`CTEDivision.json_key`), `src/querybuilder/expression_render.jl` (`_render_expr_node`), `src/querybuilder/select_nodes.jl` (`Sum`/`Avg`/`Max`/`Min`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change on every engine. A query that built now raises `QueryBuildError` when it is built. On SQLite and MySQL some of these returned a value. On PostgreSQL most raised a server error when the query ran, and `Floor(key) / 2` returned a value. A `Max` or `Min` of a key returned a value on every engine: the text's order on PostgreSQL, the number's on SQLite.

### What changed

A JSON key's value has no declared type: the document decides, row by row, whether it is an integer,
a float or text. Arithmetic on it does not say which number it computes on, and the engines answered
differently. SQLite's `json_extract` returns the integer the document holds, so over
`{"wins": 121}`, `Floor("metadata__wins") / 2` returned `60` where the quotient means `60.5`, and
nothing reported the difference (#1471). PostgreSQL extracts the key as text: `F("metadata__wins") / 2`
and `Sum("metadata__wins")` built, and the server rejected them when they ran
(`invalid input syntax for type bigint`, `function sum(text) does not exist`), naming neither the key
nor the cast to write (#1483).

PormG now refuses, on every engine, arithmetic (`+`, `-`, `*`, `/`) with a side that carries an uncast
JSON key, and a `Sum` or an `Avg` of one. "Carries" means the key itself, or a value that holds it:
the functions whose value is their operand's (`Floor`, `Ceil`, `Abs`, `Max`, `Min`, `Coalesce`,
`Greatest`, `Least`, `Lag` and its `default`), a `Case` branch, `NullIf`'s first operand, and
arithmetic over any of them. A CTE column or a `Subquery` whose body carries the key carries it too,
even where its type does not say so: a CTE column `Lag("id"; default = F("metadata__wins"))` is typed
by `id`, and `Coalesce(CTE("c", "w"), 0) / 2` over it divided the key's integer as one on SQLite
(#1482). The message names the cast to write. A value that names its number still
builds: a `Cast`, an `output_field`, `Round`. A function over the key with nothing computed on it
(`Floor("metadata__wins")`) and a comparison (`"metadata__wins__@gte" => 100`) build as before.

A `Max` or a `Min` over an uncast key (or over a value that carries one, as above) is refused too
(#1491). It computes nothing, but it orders the value, and the query does not say whether as numbers or
as text. PostgreSQL extracts the key as text, so over `{"wins": 9}` and `{"wins": 10}`,
`Max("metadata__wins")` returned `"9"` (`'9' > '10'`) and `Min` returned `"10"`, while SQLite's
`json_extract` returned the numbers `10` and `9`. MySQL renders the key unquoted to text, as
PostgreSQL does (read from its SQL; not measured on a server). The message names both spellings:
`Cast(key, "numeric")` orders numbers, and `Cast(key, "text")` orders text in each engine's own
collation.

An ordering over a key (`order_by("metadata__wins")`) and `Greatest`/`Least` over one have the same
split, and are refused in this train too (#1497): see `2026-10-30-1497-json-key-ordering-refused.md`.

Earlier in this train (#1471), only SQLite refused, and only a `/`; a float divisor (`/ 2.0`) and
arithmetic beside a float literal (`F("metadata__wins") * 1.0`) built there. Those are refused now
too: on PostgreSQL they reach the same server error.

| query (`metadata` holds `{"wins": 121}`) | before | now |
|---|---|---|
| `values("v" => Floor("metadata__wins") / 2)` on SQLite | `60` | `QueryBuildError` |
| `values("v" => Floor("metadata__wins") / 2)` on PostgreSQL | `60.5` | `QueryBuildError` |
| `values("v" => F("metadata__wins") / 2)` on PostgreSQL | server error (22P02) | `QueryBuildError` |
| `values("v" => F("metadata__wins") + 1)` on SQLite or MySQL | `122` | `QueryBuildError` |
| `values("v" => Sum("metadata__wins"))` on SQLite or MySQL | the sum | `QueryBuildError` |
| `values("v" => Sum("metadata__wins"))` on PostgreSQL | server error (42883) | `QueryBuildError` |
| `values("v" => Coalesce(Subquery(…values("w" => Coalesce("metadata__wins", 0))…), 0) / 2)` on SQLite | `60` | `QueryBuildError` |
| `values("v" => Cast("metadata__wins", "numeric") / 2)` | `60.5` | `60.5` (unchanged) |
| `values("v" => Max("metadata__wins"))` over `9` and `10` on PostgreSQL | `"9"` | `QueryBuildError` |
| `values("v" => Max("metadata__wins"))` over `9` and `10` on SQLite | `10` | `QueryBuildError` |
| `values("v" => Max(Cast("metadata__wins", "numeric")))` over `9` and `10` | `10` | `10` (unchanged) |

### Who this affects

Code that computes on a value taken from a JSON key, or takes its `Max` or `Min`, directly or
through one of the functions above, wherever the arithmetic or the extremum appears: a projection, a filter value
(`"constructorid__@gt" => F("metadata__wins") / 2`), an `update()` value, an ordering, a CTE body, a
`Subquery`. An `order_by` over a key itself is #1497's entry.

### How to find the calls to migrate

```bash
grep -rnE '(Sum|Avg|Max|Min)\("[A-Za-z_0-9]+__[A-Za-z_0-9]+"|"[A-Za-z_0-9]+__[A-Za-z_0-9]+".*[-+*/]|[-+*/].*"[A-Za-z_0-9]+__' --include=*.jl src/ test/
```

It over-matches on purpose (any `__` path on a line with an operator): read each hit and keep those
where a JSONField path sits inside the arithmetic or the `Sum`/`Avg`/`Max`/`Min`, directly or
inside a function.
The error message reads `` … over the JSON key `…` is not supported: a JSON key's value has no
declared type``.

### Migrate your app

```julia
# ✗ before: SQLite divided the integer the key holds; PostgreSQL rejected the text
q = M.Constructor.objects
q.values("name", "half" => Floor("metadata__wins") / 2)

# ✓ after: state the number type; this keeps the fraction on every engine
q = M.Constructor.objects
q.values("name", "half" => Floor(Cast("metadata__wins", "numeric")) / 2)
```

If integer arithmetic is what the code meant, say so: `Cast("metadata__wins", BigIntegerField()) / 2`
divides as integers on every engine. A total is `Sum(Cast("metadata__wins", "numeric"))`, and the
largest number is `Max(Cast("metadata__wins", "numeric"))`; `Max(Cast("metadata__principal", "text"))`
orders a key that holds text.
