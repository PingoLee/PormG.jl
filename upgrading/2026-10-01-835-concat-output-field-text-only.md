## `Concat(…; output_field = …)` now raises unless the type is text (#835)

- **Version**: Unreleased
- **PormG ref**: #835 ; `src/querybuilder/functions.jl`
- **Recorded**: 2026-10-01
- **Severity**: breaking (narrow) — a spelling that built now raises. A non-text `output_field` on `Concat` was never applied to the SQL; it now raises `InvalidValueError` when the expression is built.

### What changed

`Concat` renders `CONCAT(…)` on PostgreSQL and `a || b` on SQLite, with **no cast** on either
engine, so its result is always text. Its `output_field` was nevertheless accepted with any type,
and the two places that read a declared type disagreed about it:

| where the `Concat` is projected | before | after |
|---|---|---|
| a CTE body (`.with(…)`), filtered as `c__x` | typed as the declared type: `output_field = "integer"` refused `"abc"` against a text column, and bound `7` as a number against text — **on SQLite, no rows** | the constructor raises `InvalidValueError`, so the column is always text |
| the same query, filtered as a projection alias | checked as text whatever the declared type | unchanged: text |

A text type (`CharField()`, `TextField()`, `"text"`, `"varchar(20)"`) is still accepted, and still
renders no cast. The value already is text.

### Who this affects

Apps that pass a non-text type (`IntegerField()`, `"integer"`, `"date"`, `"boolean"`, …) to
`Concat`'s `output_field`. Measured before the change: the consuming apps have **0** such call
sites, so none needs an edit.

### How to find the calls to migrate

```bash
grep -rn 'Concat(' --include='*.jl' <your-app>/src | grep 'output_field'
```

A multi-line `Concat([...], output_field = …)` can hide from that grep. The error is raised when the
expression is built, so a test run surfaces every remaining one:
`Concat returns text on both engines and renders no cast, so its output_field cannot be …`.

### Migrate your app

Cast the result, which renders the cast `output_field` never did:

```julia
# ✗ before: declared integer, rendered as text
M.Race.objects.values("raceid", "season_round" => Concat("year", Value("0"), "round"; output_field = "integer"))

# ✓ after: (CONCAT(…))::integer on PostgreSQL, CAST(… AS INTEGER) on SQLite
M.Race.objects.values("raceid", "season_round" => Cast(Concat("year", Value("0"), "round"), "integer"))
```
