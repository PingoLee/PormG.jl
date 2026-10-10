## `Concat` — a boolean, float or decimal operand is refused (#1027)

- **Version**: Unreleased
- **PormG ref**: #1027 ; `src/querybuilder/functions.jl` (`Concat`), `src/querybuilder/projection_types.jl` (`_concat_textless_operand`), `src/querybuilder/select_nodes.jl`
- **Recorded**: 2026-10-07
- **Severity**: breaking. A `Concat` with a boolean, float or decimal operand raises `QueryBuildError` where it used to render.

### What changed

Each engine turns a non-text operand into text its own way. PostgreSQL's `CONCAT` calls the type's
output function. SQLite's `||` uses its own number formatting, applied to what PormG stores there
(a boolean as `0`/`1`, a decimal as an integer or a REAL). So the same `Concat` read differently per
engine:

| operand | PostgreSQL | SQLite |
|---|---|---|
| `BooleanField` `true` | `t` | `1` |
| `FloatField` `25.0` | `25` | `25.0` |
| `DecimalField(decimal_places = 2)` `1.50` / `3` | `1.50` / `3.00` | `1.5` / `3` |
| `Mod(7, 3)`, `Avg(…)`, `Round(…)` | `numeric` (`1`) | a REAL (`1.0`) |

A test suite on SQLite asserted a string production never produced, and a filter on the
concatenated value matched different rows per engine. `Concat` now refuses such an operand, as
#860/#876 already refuse a float, a decimal or a `Bool` as a text value:

- a literal (`true`, `1.5`, `Value(Decimal(…))`) when the `Concat` is built;
- a `BooleanField`, `FloatField` or `DecimalField` column (a joined path too; a `DecimalField` with
  `decimal_places = 0` holds whole numbers and passes unless it is divided, #1087; so do `Floor`/`Ceil`/`Abs`
  over an integer and `Sum` of a BIGINT column, #1111), or an expression of
  one of those types (a comparison, a `Cast` or `output_field` naming a float or decimal type,
  arithmetic or an extremum over a float, `Avg`/`Round`/`Mod`/`Sqrt`/`Exp`/`Ln`/`Power`) when the
  query is built.

Text, integer and date operands are unchanged, and so are the `@yyyy_q` / `@yyyy_quad` labels.

### Who this affects

Code that concatenates a boolean, float or decimal value in SQL. Measured on 2026-10-07: **0**
`Concat(` call sites in the consuming apps' Julia code.

### How to find the calls to migrate

```bash
grep -rn 'Concat(' --include=*.jl src/ test/
```

Read each hit for an operand that is a boolean, float or decimal column, or such a literal. Running
the query is the definitive check: the refusal message names the operand and cites #1027.

### Migrate your app

`Cast(…, CharField())` does not fix this. It writes `25` on PostgreSQL and `25.0` on SQLite. Write
the text you mean:

```julia
# ✗ before — 'hamilton-10' on PostgreSQL, 'hamilton-10.0' on SQLite
q = M.Result.objects
q.values("label" => Concat("driverid__driverref", Value("-"), "points"))

# ✓ after — a number: fetch it and format it in Julia
q = M.Result.objects
q.values("driverid__driverref", "points")
df = q |> DataFrame
df.label = df.driverid__driverref .* "-" .* string.(df.points)

# ✓ after — a boolean: name its two texts with a Case
q = M.Result.objects
q.values("outcome" => Concat("driverid__driverref", Value(": "),
                             Case(When("points__@gt" => 0, then = Value("scored")), default = "no points")))
```
