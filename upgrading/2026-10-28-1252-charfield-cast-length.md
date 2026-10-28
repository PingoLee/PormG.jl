## A `CharField(max_length = n)`, `SlugField` or `URLField` cast keeps its length; a sized text cast is refused on SQLite (#1252, #1438)

- **Version**: 0.9.0
- **PormG ref**: #1252, #1438 ; `src/querybuilder/functions.jl` (`_field_cast_type`), `src/querybuilder/engine_departures.jl` (`:sized_text`), `src/querybuilder/projection_types.jl` (`_sized_text_length`), `src/models/fields.jl` (`sCharField.max_length_given`)
- **Recorded**: 2026-10-28
- **Severity**: behavior change. A cast to a `CharField` given a length, a `SlugField` or a `URLField` now cuts the text on PostgreSQL and MySQL, and a cast to text of a declared length raises `QueryBuildError` on SQLite, where it built. A cast to an `ArrayField` now raises `BackendCapabilityError` on SQLite, where it cast to text. Each holds for the same field given as the `output_field` of `Coalesce`, `Greatest`, `Least` or `Case`.

### What changed

A `CharField` object passed to `Cast` or `output_field` contributed only its type, so
`Cast(x, CharField(max_length = 3))` rendered an unbounded `::varchar` and returned every character.
It now declares its length, as a `DecimalField` declares its precision and scale (#1221) and as
Django's `Cast` does: it is `Cast(x, "varchar(3)")`. That includes an explicit `max_length = 250`, the
default's value. `CharField()` declares no length and stays the unbounded text it has always cast to,
although its column is `varchar(250)`.

A `SlugField` and a `URLField` declare their length too (#1438), the one their column has: `SlugField()`
is `varchar(50)`, `URLField()` is `varchar(200)`, and either given `max_length = n` is `varchar(n)`, as
Django's are. Unlike `CharField`, the default is part of the declaration, because these defaults are
Django's own. An `EmailField` has no `max_length` in PormG (its column is `TEXT`), so it stays unbounded.

An `ArrayField` declares its element's cast type with `[]` (#1438): `ArrayField(CharField(max_length = 3))`
is `varchar(3)[]` and `ArrayField(IntegerField())` is `integer[]`. It rendered `::array` on PostgreSQL,
which is no type, so the query failed at the server; it now runs. SQLite cast it to `TEXT`, and now
raises `BackendCapabilityError` naming arrays, as it does for the column; MySQL raised
`UnsupportedConnectionError`, and now raises the same `BackendCapabilityError`.

A declared length means the text cut to `n` characters. PostgreSQL's cast cuts it, and so does
MySQL's `CHAR(n)`. SQLite enforces no length, so `CAST(x AS TEXT)` returned every character, a
different value. So SQLite refuses a cast to text of a declared length, `varchar(n)`,
`character varying(n)`, `char(n)`, `character(n)`, PostgreSQL's `bpchar(n)` and `nchar(n)` (#1438),
`CharField(max_length = n)`, `SlugField` and `URLField` alike, and an unsized `char` or `character`,
which is one character on PostgreSQL and MySQL (`'H'`), and an unsized `nchar`, one character on
PostgreSQL. An unsized `bpchar` declares no length on PostgreSQL and still builds. PormG renders
`bpchar` and `nchar` for no MySQL CAST target, so MySQL refuses them with `UnsupportedConnectionError`,
as it did before. The refusal
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
| `Cast("surname", SlugField(max_length = 3))` | unbounded text | `::varchar(3)` / `CHAR(3)`, `'Ham'`; raises `QueryBuildError` on SQLite |
| `Cast("surname", SlugField())`, `URLField()` | unbounded text | `varchar(50)` / `varchar(200)`; raises `QueryBuildError` on SQLite |
| `Cast("surname", "bpchar(3)")`, `"nchar(3)"` on SQLite | every character, where PostgreSQL gave `'Ham'` | raises `QueryBuildError` (#1252) |
| `Cast("surname", EmailField())` | unbounded text | unchanged |
| `Cast(x, ArrayField(CharField(max_length = 3)))` on PostgreSQL | `::array`, an error at the server | `::varchar(3)[]`, each element cut to 3 |
| `Cast(x, ArrayField(…))` on SQLite / MySQL | `CAST(x AS TEXT)` / `UnsupportedConnectionError` | raises `BackendCapabilityError` (arrays) |
| `show(CharField(max_length = 250))`, `Models.Model_to_str` | `CharField()` | `CharField(max_length=250)` |

A field built with `max_length` now prints, and is written by `Model_to_str`, with that
`max_length`, the default 250 included, so it rebuilds as the same declaration. `inspectdb`
(`generate_models_from_db`) reads every `varchar(n)` column with its length, so regenerating a
models file over a `varchar(250)` column writes `CharField(max_length=250)` where it wrote
`CharField()`. The column, and the migration plan, are unchanged.

### Who this affects

Code that casts to a `CharField` with a `max_length`, a `SlugField` or a `URLField`, or to a sized
`varchar`/`char`/`bpchar`/`nchar` string or an unsized `char`/`nchar`, or declares one as an
`output_field`. On SQLite each such call now raises. On PostgreSQL and MySQL, a `CharField`, `SlugField` or
`URLField` declaration now cuts values longer than its length. Code that casts to an `ArrayField` on SQLite now raises
`BackendCapabilityError` instead of reading text. The same holds for any of these fields given as the
`output_field` of `Coalesce`, `Greatest`, `Least` or `Case`, which renders the same cast:
`output_field = ArrayField(IntegerField())` was `"ARRAY"` and is now `integer[]`.

A models file regenerated with `generate_models_from_db` also changes: its diff gains
`max_length=250` on every `varchar(250)` column.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field' --include=*.jl src/ test/ | grep -iE 'CharField\(max_length|SlugField|URLField|ArrayField|varchar\(|varying\(|bpchar\(|"n?char(acter)?(\([0-9]+\))?"'
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

To keep the old unbounded cast on PostgreSQL, declare no length: `CharField()` or `"text"`, in place
of a `CharField(max_length = n)`, a `SlugField` or a `URLField`.
