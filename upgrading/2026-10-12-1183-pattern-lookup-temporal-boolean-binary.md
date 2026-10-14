## A pattern lookup on a time column matches its text; on a timestamp, duration, boolean or binary column it is refused (#1183)

- **Version**: 0.8.0
- **PormG ref**: #1183 ; `src/querybuilder/filter_nodes.jl` (`_pattern_text_kind`, `_pattern_kind_read`, `_pattern_operand_kind`, `_pattern_operand`), `src/querybuilder/projection_types.jl` (`_having_alias_kind`, `_render_alias_predicate`), `src/Dialect.jl` (`_pattern_text_operand`)
- **Recorded**: 2026-10-12
- **Severity**: behavior. A pattern lookup on a `DateTimeField`, `DurationField`, `BooleanField` or `BinaryField` column, or on an alias over one, now raises `FilterError` on both engines, where SQLite matched the text it stored. A pattern lookup on a `TimeField` now runs on PostgreSQL, where the server rejected it.

### What changed

A pattern lookup (`@contains`, `@startswith`, `@endswith`, `@iexact`, `@regex` and their variants)
matches a fragment of the column's text. PostgreSQL has no `LIKE` for a `time`, `timestamptz`,
`interval` or `boolean`, so it rejected each of them at the server, while SQLite ran the `LIKE` over
whatever text it had stored. Each kind is now decided by whether the two engines print the same text:

| call | before | after |
|---|---|---|
| `M.Race.objects.filter("time__@startswith" => "14:")` on a `TimeField` | SQLite matched the stored text; PostgreSQL failed at the server | matches on both: PostgreSQL reads `CAST(time AS text)`, `HH:MM:SS` with a fraction only when the time has one, as SQLite stores it |
| `M.Race.objects.filter("start_at__@startswith" => "2009")` on a `DateTimeField` | SQLite matched `2009-03-29T06:00:00.000+00:00`; PostgreSQL failed at the server | `FilterError` on both: PostgreSQL prints a timestamp in the session's time zone |
| `M.Pit_stops.objects.filter("duration__@contains" => "22")` on a `DurationField` | SQLite matched its stored `HH:MM:SS` text; PostgreSQL failed at the server | `FilterError` on both: PostgreSQL's interval text follows `IntervalStyle` |
| `filter("<boolean column>__@contains" => "1")` on a `BooleanField` | SQLite matched `1`/`0`; PostgreSQL failed at the server | `FilterError` on both: PostgreSQL prints `true`/`false` |
| `filter("<binary column>__@contains" => "ab")` on a `BinaryField` | a `LIKE` over the stored bytes, where the engine accepted one | `FilterError` on both: a binary column holds bytes, not text |

An alias over one of these kinds takes the same rule: `values("m" => Max("start_at"))` then
`filter("m__@startswith" => "2009")` is refused, and so are a `Value(true)` alias and a
`Cast(…, "boolean")` alias. A `Max("time")` alias is matched as its text. Every other lookup on these
columns (`=`, `@in`, `@gte`, `@range`, `@isnull`) is unchanged.

`@regex`/`@iregex` on one of the refused columns raises the `FilterError` on SQLite too, where it
raised `BackendCapabilityError` (SQLite has no regex operator): the pattern is refused before the
feature is looked up. On a time or text column it still raises `BackendCapabilityError` there.

### Who this affects

Code that runs a pattern lookup on a `DateTimeField`, `DurationField`, `BooleanField` or
`BinaryField` column, a relation path ending in one, or an alias over one, and relied on SQLite
answering it. On PostgreSQL every such call on a timestamp, duration or boolean column already
failed when it ran. Code that catches `BackendCapabilityError` around a `@regex`/`@iregex` lookup on
one of these columns on SQLite now sees `FilterError`.

### How to find the calls to migrate

```bash
grep -rnE '__@[a-z_]*(contains|startswith|endswith|iexact|regex)"\)?\s*=>' --include=*.jl src/ test/
```

For each match, check whether the column (or the last field of the path) is a `DateTimeField`,
`DurationField`, `BooleanField` or `BinaryField`, or whether the alias projects one. Running the query
is the definitive check: the refusal names the column and what it is, and cites #1183.

### Migrate your app

```julia
# ✗ before — SQLite matched its stored UTC text, PostgreSQL failed at the server
M.Race.objects.filter("start_at__@startswith" => "2009-03")

# ✓ after — match a part of the timestamp, or compare it as one
M.Race.objects.filter("start_at__@date__@startswith" => "2009-03")
M.Race.objects.filter("start_at__@gte" => DateTime(2009, 3, 1), "start_at__@lt" => DateTime(2009, 4, 1))

# ✓ the engine's own text, explicitly — each engine's text, so the rows can differ per engine
M.Race.objects.values("raceid", "t" => Cast("start_at", "text")).filter("t__@startswith" => "2009")
```
