## A `CharField(max_length = n)` cast keeps its length; a sized text cast is refused on SQLite (#1252)

- **Version**: Unreleased
- **PormG ref**: #1252 ; `src/querybuilder/functions.jl` (`_field_cast_type`), `src/querybuilder/engine_departures.jl` (`:sized_text`), `src/models/fields.jl` (`sCharField.max_length_given`)
- **Recorded**: 2026-10-28
- **Severity**: behavior change. A cast to a `CharField` given a length now cuts the text on PostgreSQL and MySQL, and a cast to text of a declared length raises `QueryBuildError` on SQLite, where it built.

### What changed

A `CharField` object passed to `Cast` or `output_field` contributed only its type, so
`Cast(x, CharField(max_length = 3))` rendered an unbounded `::varchar` and returned every character.
It now declares its length, as a `DecimalField` declares its precision and scale (#1221) and as
Django's `Cast` does: it is `Cast(x, "varchar(3)")`. That includes an explicit `max_length = 250`, the
default's value. `CharField()` declares no length and stays the unbounded text it has always cast to,
although its column is `varchar(250)`.

A declared length means the text cut to `n` characters. PostgreSQL's cast cuts it, and so does
MySQL's `CHAR(n)`. SQLite enforces no length, so `CAST(x AS TEXT)` returned every character, a
different value. So SQLite refuses a cast to text of a declared length, `varchar(n)`,
`character varying(n)`, `char(n)`, `character(n)` and `CharField(max_length = n)` alike, and an
unsized `char` or `character`, which is one character on PostgreSQL and MySQL (`'H'`). The refusal
covers the `output_field` of `Coalesce`, `Greatest`, `Least` and `Case`, which render the same cast.
A `Concat`'s `output_field` renders no cast, so a length there cuts nothing and builds everywhere.

Examples on `Driver`, whose `surname` is a `CharField`:

| expression | before | now |
|---|---|---|
| `Cast("surname", CharField(max_length = 3))` | `::varchar`, every character, on PostgreSQL; `CHAR` on MySQL | `::varchar(3)` / `CHAR(3)`, `'Ham'` |
| `Cast("surname", CharField(max_length = 3))` on SQLite | every character | raises `QueryBuildError` (#1252) |
| `Cast("surname", "varchar(3)")` on SQLite | every character, where PostgreSQL gave `'Ham'` | raises `QueryBuildError` (#1252) |
| `Cast("surname", CharField())` | unbounded text | unchanged |
| `Cast("surname", "text")` | unbounded text | unchanged |
| `Cast("surname", "char")` on SQLite | every character, where PostgreSQL gave `'H'` | raises `QueryBuildError` (#1252) |
| `show(CharField(max_length = 250))`, `Models.Model_to_str` | `CharField()` | `CharField(max_length=250)` |

A field built with `max_length` now prints, and is written by `Model_to_str`, with that
`max_length`, the default 250 included, so it rebuilds as the same declaration. `inspectdb`
(`generate_models_from_db`) reads every `varchar(n)` column with its length, so regenerating a
models file over a `varchar(250)` column writes `CharField(max_length=250)` where it wrote
`CharField()`. The column, and the migration plan, are unchanged.

### Who this affects

Code that casts to a `CharField` with a `max_length`, or to a sized `varchar`/`char` string or an
unsized `char`, or declares one as an `output_field`. On SQLite each such call now raises. On
PostgreSQL and MySQL, a `CharField(max_length = n)` declaration now cuts values longer than `n`.

A models file regenerated with `generate_models_from_db` also changes: its diff gains
`max_length=250` on every `varchar(250)` column.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field' --include=*.jl src/ test/ | grep -iE 'CharField\(max_length|varchar\(|varying\(|"char(acter)?(\([0-9]+\))?"'
```

### Migrate your app

```julia
# ✗ before — every character on SQLite; now raises QueryBuildError there (#1252)
q = M.Driver.objects
q.values("code" => Cast("surname", "varchar(3)"))

# ✓ after — the whole text on every engine, cut in Julia
q = M.Driver.objects
q.values("code" => Cast("surname", "text"))
codes = [first(r["code"], 3) for r in q.list()]
```

To keep the old unbounded cast on PostgreSQL, declare no length: `CharField()` or `"text"`.
