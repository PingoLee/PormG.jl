## A pattern lookup on a `UUIDField` matches its canonical text as written (#902)

- **Version**: 0.8.0
- **PormG ref**: #902 ; `src/querybuilder/filter_nodes.jl` (`_pattern_text_kind`), `src/Dialect.jl` (`_pattern_text_operand`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A pattern lookup given a whole UUID that is not lowercase and
  hyphenated now returns no rows, on both engines. Before, SQLite normalized an uppercase one and
  matched, and PormG refused a braced or unhyphenated one with `FilterError`.

### What changed

`@contains`, `@startswith`, `@endswith` (and their `i` / `n` forms) on a `UUIDField` ran the value
through the strict UUID formatter, which accepts only a whole UUID and rewrites it to lowercase with
hyphens. A fragment such as `"550e"` was refused, a braced or unhyphenated UUID too, and an
uppercase one was lowercased before the `LIKE`. The value is now a text fragment, matched against
the column's canonical text (lowercase, hyphenated) — the form SQLite stores and PostgreSQL prints:

| `filter("token__@contains" => v)` on `token = UUIDField()` | before | after |
|---|---|---|
| a fragment, `"550e"` (`@startswith`) | `FilterError` | matches |
| the whole UUID, lowercase and hyphenated | SQLite: matched; PostgreSQL: `"token" LIKE $1`, refused by the server (no `LIKE` for `uuid`) | matches on both: PostgreSQL reads `CAST("token" AS text)` |
| the whole UUID in uppercase | SQLite: normalized to lowercase, matched; PostgreSQL: refused by the server | bound as written: **no rows** on both (`LIKE` is case-sensitive; `@icontains` folds case and matches) |
| the whole UUID in braces, or without hyphens | `FilterError` (not a UUID) | bound as written: **no rows** on both |
| a `UUID` value | SQLite: matched | matches on both |
| `"token" => …`, `"token__@in" => […]` — equality and `@in` | any spelling, normalized | unchanged |

### Who this affects

Code that runs a case-sensitive pattern lookup on a `UUIDField` with a whole UUID string that may
not be lowercase and hyphenated — on SQLite it used to match an uppercase one; a braced or
unhyphenated one used to raise and now silently matches nothing.

### How to find the calls to migrate

```bash
grep -rnE '__@n?i?(contains|startswith|endswith)"' --include=*.jl . | grep -iE 'uuid|token'
```

Check whether the field before the lookup is a `UUIDField`, and what spelling its value can have.

### Migrate your app

```julia
# token = Models.UUIDField() on some model M.Tok

# ✗ before — SQLite matched an uppercase whole UUID
q = M.Tok.objects.filter("token__@contains" => uppercase(token_text))

# ✓ after — use equality for a whole UUID (it normalizes any spelling), or lowercase a fragment
q = M.Tok.objects.filter("token" => token_text)
q = M.Tok.objects.filter("token__@startswith" => lowercase(prefix))
```
