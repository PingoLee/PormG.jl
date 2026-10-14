## `Concat` and `Cast` classify a `Subquery` operand by the expression it projects (#1124)

- **Version**: 0.8.0
- **PormG ref**: #1124, amended by #1147 ; `src/querybuilder/projection_types.jl` (`_concat_textless_operand`, `_subquery_projection_textless`), `src/querybuilder/filter_nodes.jl` (`_render_scalar_subquery`), `src/querybuilder/types.jl` (`subquery_textless`)
- **Recorded**: 2026-10-10
- **Severity**: breaking. A `Concat` with a `Subquery` operand whose projection is a boolean, a float, a decimal or a `numeric` function raises `QueryBuildError` on every engine where it used to render; a `Cast` (or `output_field` cast) over such a subquery raises where the projection's own cast would (on SQLite, for a boolean to text, a fraction to an integer, and `numeric(p, s)`).

### What changed

#1027, #1028 and #1040 refuse an operand each engine turns into text, or rounds, differently. The
rules read one classifier, and a `Subquery(...)` had no arm in it: a subquery was typed only
through the read kind and the formatter its render records, and neither names a float, a decimal
or a literal. So the same operand was refused directly and let through wrapped:

```julia
avg_pts = M.Result.objects.filter("driverid" => OuterRef("driverid")).values("a" => Avg("points"))
M.Driver.objects.values("label" => Concat("surname", Value(": "), Avg("points")))     # refused (#1027)
M.Driver.objects.values("label" => Concat("surname", Value(": "), Subquery(avg_pts)))  # built
```

and the built one read `hamilton: 10` on PostgreSQL and `hamilton: 10.0` on SQLite, the divergence
#1027 exists to prevent: `Concat` refuses a number until the query says which text it means.

The subquery's inner build now records the classification of its one projected expression under
the node, the way #929 records its formatter, and the outer classifier reads it. A `Subquery` is
refused exactly where its projection would be:

| `Subquery` projecting | `Concat` | `Cast` to text | `Cast` to an integer | `Cast` to `numeric(p, s)` |
|---|---|---|---|---|
| a `FloatField`, a `DecimalField` with places, `Max`/`Min`/`Sum`/`Coalesce` of one | refused (#1027) | builds | refused on SQLite (#1028) | refused on SQLite (#1040) |
| `Avg`, `Round` (not over an integer, #1196), `Mod`, … (a `numeric` function) | refused (#1027) | builds | refused on SQLite (#1028) | refused on SQLite (#1040) |
| a `BooleanField` or a `Bool` literal | refused (#1027) | refused on SQLite (#1028) | builds | — |
| a text or integer column, `Count`, `Cast(Round(x), IntegerField())` | builds | builds | builds | builds |

Which engine refuses follows #1147: the engine that computes something other than what the cast
means (see the #1028 and #1040 entries). A `Concat` over a number is refused on every engine.

Unchanged: a timestamp or interval projection was already refused through the read kind, and an
operand PormG still cannot type (an untyped `Case`) still passes.

### Who this affects

Code that puts a `Subquery(...)` inside a `Concat(...)`, or casts one to text, to an integer or to
a scaled numeric, where the subquery projects a number with a fraction or a boolean. Running the
query is the definitive check: the refusal message names the operand as
`a Subquery projecting …` and cites the rule (#1027, #1028 or #1040).

### How to find the calls to migrate

```bash
grep -rn 'Subquery(' --include=*.jl src/ test/
```

Read each hit that is an operand of `Concat`, `Cast`, or a `Coalesce`/`Greatest`/`Least` with an
`output_field`, and check what the subquery's `values(...)` projects.

### Migrate your app

The way out is the same as for the expression alone, applied inside the subquery, or a cast to text around it,
as the #1028 rules describe:

```julia
# ✗ before — refused: which text of the average is meant?
avg_pts = M.Result.objects.filter("driverid" => OuterRef("driverid")).values("a" => Avg("points"))
M.Driver.objects.values("label" => Concat("surname", Value(": "), Subquery(avg_pts)))

# ✓ after — a whole number reads the same: round it to an integer inside the subquery
avg_pts = M.Result.objects.filter("driverid" => OuterRef("driverid")).
    values("a" => Cast(Round(Avg("points")), IntegerField()))
M.Driver.objects.values("label" => Concat("surname", Value(": "), Subquery(avg_pts)))

# ✓ after — the engine's own text: cast it inside the Concat
M.Driver.objects.values("label" => Concat("surname", Value(": "), Cast(Subquery(avg_pts), "text")))

# ✓ after — the digits you mean: fetch the number and format it in Julia
df = M.Driver.objects.values("surname", "avg" => Subquery(avg_pts)) |> DataFrame
df.label = df.surname .* ": " .* string.(round.(df.avg; digits = 1))
```
