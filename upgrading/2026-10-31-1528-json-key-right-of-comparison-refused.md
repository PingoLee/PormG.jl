## A JSON key on the right of a comparison is refused on every engine (#1528)

- **Version**: Unreleased
- **PormG ref**: #1528 ; `src/querybuilder/json_key_refusal.jl` (`_JSONKeyRightOperand`, `_refuse_json_key_right_operand`), `src/querybuilder/expression_render.jl` (`_render_expr_node`), `src/querybuilder/filter_nodes.jl` (`_render_column_rhs`)
- **Recorded**: 2026-10-31
- **Severity**: behavior change on every engine. A comparison with a JSON key, or a value that carries one, on its right now raises `FilterError` when the query is built. On PostgreSQL it was a server error; on SQLite it compared the key's native value with the column.

### What changed

Since #1511 a JSON key on the **left** of a comparison compares as its lookup does, against a value. A
key on the **right** still compared without a declared type, in both spellings:

- the operator, `F("constructorid") == F("metadata__wins")`;
- the filter pair, `"constructorid" => F("metadata__wins")` (and `"constructorid__@gt" => …`);
- a value that carries the key (since #1514 a function can sit on the right of an operator), as in
  `F("grid") > Coalesce("metadata__wins", 0)` and the pair `"grid__@gt" => Coalesce("metadata__wins", 0)`.

Each spelling is now refused on every engine. This includes a projection
(`values("b" => F("constructorid") == F("metadata__wins"))`), a `Q`, a `When` condition, and a field
path string on the right (`F("name") == "metadata__principal"`).

| expression | before | now |
|---|---|---|
| `F("constructorid") == F("metadata__wins")` on PostgreSQL | `bigint = text`, a server error when it ran | `FilterError` when it is built |
| `F("constructorid") == F("metadata__wins")` on SQLite | compared `json_extract`'s native value | `FilterError` |
| `"constructorid" => F("metadata__wins")` on any engine | the same as the operator | `FilterError` |
| `F("name") == F("metadata__principal")` (text = text) on any engine | built and compared text | `FilterError` |
| `F("date") > F("metadata__round")` on SQLite | `QueryBuildError` (#1310) | `FilterError` |
| `F("date") > F("metadata__round")` on PostgreSQL | `date > text`, a server error | `FilterError` |
| `F("grid") > Coalesce("metadata__wins", 0)` on PostgreSQL | `COALESCE(text, bigint)`, a server error | `FilterError` |
| `"constructorid" => Subquery(<a queryset projecting "metadata__wins">)`, and `F("constructorid") == Subquery(…)` | as the operator above: a server error on PostgreSQL against a non-text column, the native value on SQLite | `FilterError` |
| `"constructorid" => CTE("c", "wins")`, where the CTE column projects the key | the same | `FilterError` |
| `"constructorid" => OuterRef("metadata__wins")` inside a `Subquery` or an `Exists` | the same | `FilterError` |
| a join condition, `on("constructorid", "constructorid" => F("metadata__wins"))` | the same | `FilterError` |

On MySQL, a duration column compared with a key on its right (`F("fastestlaptime") <= F("metadata__wins")`)
keeps the interval refusal it already raised (`QueryBuildError`, #1130), because that refusal fires first.

A key cast on the right (`F("constructorid") == Cast("metadata__wins", BigIntegerField())`) states
what it compares and builds, as does a text value that is not a field path (`F("name") == "Senna"`).

### Who this affects

Code that compares a column, or any expression, with a JSONField key path (or a function over one) on
the right of `==`, `!=`, `<`, `<=`, `>` or `>=`, or that filters a column against `F("<json>__<key>")`.
On PostgreSQL the query already failed at the server, unless both sides were text. On SQLite it ran and
compared the key's native value.

### How to find the calls to migrate

```bash
grep -rnE '(==|!=|<=|>=|<|>) *F\("[A-Za-z0-9_]+__[A-Za-z0-9_]+"\)' --include=*.jl src/ test/
grep -rnE '=> *(F|Coalesce|NullIf|Abs|Floor|Ceil|Case)\("[A-Za-z0-9_]+__[A-Za-z0-9_]+"' --include=*.jl src/ test/
grep -rnE '(=>|==|!=|<=|>=|<|>) *(Subquery|CTE|OuterRef)\(' --include=*.jl src/ test/
```

For each hit, check whether the right-hand path ends in a JSONField key, or (for a `Subquery` or a CTE
column) whether the value it projects is one.

### Migrate your app

Cast the key on the right to the type you mean:

```julia
q = M.Constructor.objects
q.filter(F("constructorid") == Cast("metadata__wins", BigIntegerField()))   # integers, every engine
q.filter("name" => Cast("metadata__principal", "text"))                    # text, every engine
```
