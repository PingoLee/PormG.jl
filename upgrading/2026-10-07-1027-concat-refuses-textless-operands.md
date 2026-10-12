## `Concat` — a boolean, float or decimal operand is refused (#1027)

- **Version**: Unreleased
- **PormG ref**: #1027, amended by #1147 ; `src/querybuilder/functions.jl` (`Concat`, `_concat_textless_refusal`), `src/querybuilder/projection_types.jl` (`_concat_textless_operand`), `src/querybuilder/select_nodes.jl`
- **Recorded**: 2026-10-07
- **Severity**: breaking. A `Concat` with a boolean, float or decimal operand raises `QueryBuildError` on every engine where it used to render.

### What changed

`Concat` joins text. A boolean, a float or a decimal has a text only once the query says which, and
each engine writes its own: PostgreSQL's `CONCAT` calls the type's output function, and SQLite's
`||` uses its own number formatting over what PormG stores there (a boolean as `0`/`1`, a decimal as
an integer or a REAL):

| operand | PostgreSQL | SQLite |
|---|---|---|
| `BooleanField` `true` | `t` | `1` |
| `FloatField` `25.0` | `25` | `25.0` |
| `DecimalField(decimal_places = 2)` `1.50` / `3` | `1.50` / `3.00` | `1.5` / `3` |
| `Mod(7, 3)`, `Avg(…)`, `Round(…)` over a float or a decimal | `numeric` (`1`) | a REAL (`1.0`) |

The query does not say which of these it means, so `Concat` now refuses such an operand on every
engine and asks for the explicit spelling, as Django asks for an `output_field` over mixed types
(#1147). This follows #860/#876, which already refuse a float, a decimal or a `Bool` as a text
value:

- a literal (`true`, `1.5`, `Value(Decimal(…))`) when the `Concat` is built;
- a `BooleanField`, `FloatField` or `DecimalField` column, a joined path too, when the query is
  built. A `DecimalField` with `decimal_places = 0` holds whole numbers and passes, as an integer
  column does (#1087);
- an expression of one of those types, when the query is built: a comparison, a `Cast` or
  `output_field` naming a float or decimal type, arithmetic or an extremum over a float, or
  `Avg`/`Round`/`Mod`/`Sqrt`/`Exp`/`Ln`/`Power`. `Round` over an integer is that integer and passes
  (#1196).

Text, integer and date operands are unchanged, and so are the `@yyyy_q` / `@yyyy_quad` labels.

### Who this affects

Code that concatenates a boolean, float or decimal value in SQL.

### How to find the calls to migrate

```bash
grep -rn 'Concat(' --include=*.jl src/ test/
```

Read each hit for an operand that is a boolean, float or decimal column, or such a literal. Running
the query is the definitive check: the refusal message names the operand and cites #1027.

### Migrate your app

Say which text you mean. A cast to text writes the engine's own text for the number. A `Case` names
a boolean's two texts. Julia formatting lets you choose the digits.

```julia
# ✗ before — refused: which text of `points` is meant?
q = M.Result.objects
q.values("label" => Concat("driverid__driverref", Value("-"), "points"))

# ✓ after — the engine's own text: 'hamilton-10' on PostgreSQL, 'hamilton-10.0' on SQLite
q = M.Result.objects
q.values("label" => Concat("driverid__driverref", Value("-"), Cast("points", "text")))

# ✓ after — the digits you choose: fetch it and format it in Julia
q = M.Result.objects
q.values("driverid__driverref", "points")
df = q |> DataFrame
df.label = df.driverid__driverref .* "-" .* string.(df.points)

# ✓ after — a boolean: name its two texts with a Case
q = M.Result.objects
q.values("outcome" => Concat("driverid__driverref", Value(": "),
                             Case(When("points__@gt" => 0, then = Value("scored")), default = "no points")))
```
