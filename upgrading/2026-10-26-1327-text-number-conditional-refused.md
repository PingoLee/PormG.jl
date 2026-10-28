## A conditional over text and a number is refused on every engine (#1327)

- **Version**: 0.9.0
- **PormG ref**: #1327 ; `src/querybuilder/projection_types.jl` (`_temporal_mix`, `_temporal_mix_class`, `_declaration_lifts`), `src/querybuilder/functions.jl` (`_temporal_mix_refusal`)
- **Recorded**: 2026-10-26
- **Severity**: behavior change. On SQLite, a `Coalesce`, `Greatest`, `Least`, `NullIf`, `Case`, or a `Lag`/`Lead` with a `default`, whose values include both text and a number used to build and return a value that depended on the engine. It now raises `QueryBuildError` when the query is built. On PostgreSQL the same query used to fail at the server and now fails at build time.

### What changed

A function whose value is one of its operands' does not say which type it has when one operand is
text and another a number. Each engine answered by its own coercion:

| shape | SQLite | MySQL | PostgreSQL |
|---|---|---|---|
| `Greatest(F("driverid__surname"), "grid")` | any text above any number | compared as strings: `GREATEST('10', 9)` is `'9'` | fails at the server |
| `Case(When(…, then = 1), default = "x")` | the row's own value, `1` or `"x"` | a VARCHAR, `"1"` or `"x"` | fails at the server |
| `Coalesce("positiontext", 0)` | the row's own value | a VARCHAR | fails at the server |

The query does not say whether the text is compared as text or the number as a number, nor what type
the result has. PormG now refuses the shape on every engine when the query is built (#1200 refuses a
date beside text the same way). The message names both operands and the `Cast` that states the intent.

A declared `output_field` does **not** lift this refusal. `output_field` casts the result outside the
call (`(COALESCE("positiontext", 0))::text`), so the engine still meets text and a number inside it:
PostgreSQL still raises, and MySQL still compares as strings before the cast. A shape that built only
because it declared an `output_field`, such as `Case(When(…, then = F("laps")), default = "none",
output_field = "text")`, is refused too. On PostgreSQL that shape already failed at the server.

These keep building:

- an integer beside a float or a decimal (the widening they have today);
- an operand PormG cannot type (raw SQL, a JSON key lookup) beside either;
- a `NULL` operand;
- text beside text, and a number beside a number.

| expression | SQLite before | now, every engine |
|---|---|---|
| `values("v" => Coalesce("positiontext", 0))` | each row's own value | `QueryBuildError` |
| `values("v" => Greatest("positiontext", "grid"))` | the text on every row | `QueryBuildError` |
| `values("v" => Case(When("grid" => 1, then = 1), default = "x"))` | `1` or `"x"` | `QueryBuildError` |
| `values("v" => Coalesce("positiontext", 0; output_field = "text"))` | the row's value as text | `QueryBuildError` |
| `values("v" => Coalesce("positiontext", Cast(Value(0), "text")))` | built | builds, unchanged |
| `values("v" => Coalesce("grid", 1.5))` | built | builds, unchanged |

### Who this affects

Code that puts a text value and a number in the same `Coalesce`, `Greatest`, `Least`, `NullIf`, `Case`
(its branches and its `default`), or `Lag`/`Lead` `default`. A string literal counts as text there: a
`Case` branch or a window `default`, or `Value("…")` anywhere.

### How to find the calls to migrate

```bash
grep -rnE '\b(Case|Coalesce|Greatest|Least|NullIf|Lag|Lead)\(' --include=*.jl src/ test/
```

For each match, check whether one operand is a text column, a string literal, or a text expression
(`Concat`, `ToChar`, a cast to text), while another is a number column or a numeric literal.

### Migrate your app

```julia
# ✗ before — SQLite returned each row's own value, a number or a string
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "pos" => Coalesce("positiontext", 0))

# ✓ after — cast the number to text, so every row is text on every engine
q = M.Result.objects
q.filter("raceid__year" => 2009)
q.values("driverid__surname", "pos" => Coalesce("positiontext", Cast(Value(0), "text")))
```

To compare or return numbers instead, cast the text: `Coalesce(Cast("positiontext", "integer"), 0)`.
