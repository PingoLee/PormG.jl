## A `Bool` written to or compared with a text field raises (#876)

- **Version**: Unreleased
- **PormG ref**: #876 ; `src/Models.jl` (`format_text_sql(::Bool)`)
- **Recorded**: 2026-10-02
- **Severity**: breaking (narrow). A `Bool` in a text field used to be written and filtered. It now raises `InvalidValueError` on a write and `FilterError` in a filter.

### What changed

`format_text_sql` is the formatter of every plain text field: `CharField`, `TextField`, `EmailField`,
`URLField`, `SlugField`, `PasswordField`, `FileField` and `ImageField`. It returned a `Bool`
unformatted, so each driver chose the text that was stored:

| call | PostgreSQL before | SQLite before | after, both engines |
|---|---|---|---|
| `create("code" => true)` | stores `"true"` | stores `"1"` | raises `InvalidValueError` |
| `filter("code" => true)` | matches `"true"` | matches `"1"` | raises `FilterError` |
| `CharField(max_length = 3)` given `true` | an untyped driver error | stores `"1"` | raises `InvalidValueError` |

A `Bool` has no single text, so PormG now refuses it as it refuses a float (#860) and asks for the
text you mean. `TimeField` formats through the same function, so a `Bool` compared with a time
(`filter("t" => true)`) now raises `FilterError` too, where it bound `true`. A text field's
`default = true` was already a `FieldValidationError` when the model was defined. Text values,
integers, dates and times behave exactly as before.

### Who this affects

Apps that write or filter a Julia `Bool` against a text column: a flag column declared as
`CharField` instead of `BooleanField`, a DataFrame column of `Bool`s going to `bulk_insert` /
`bulk_update` / `bulk_copy`, or a filter built from a computed value. The value is a runtime type, so a grep cannot find every call site.

### How to find the calls to migrate

Run the app's tests. Every remaining call raises with this message:

```
A text value must be a String, an integer, a date, or a time. Got a Bool
```

Then check the text fields that hold flag-like values:

```bash
grep -rnE '(Char|Text|Email|URL|Slug|Password|File|Image)Field\(' --include='*.jl' <your-app>/src
```

### Migrate your app

Write the text the column already holds. For rows written on PostgreSQL that is `"true"`/`"false"`;
for rows written on SQLite it is `"1"`/`"0"`. If the column is really a flag, the cleaner fix is to
declare it as a `BooleanField`.

```julia
# A race calendar loaded from a feed keeps its sprint flag in a text column, `sprint = CharField()`.

# ✗ before: stored "true" on PostgreSQL, "1" on SQLite
M.Race.objects.create("name" => "Brazilian Grand Prix", "sprint" => has_sprint)

# ✓ after: the text the column holds, spelled explicitly
M.Race.objects.create("name" => "Brazilian Grand Prix", "sprint" => string(has_sprint))   # "true" / "false"
M.Race.objects.create("name" => "Brazilian Grand Prix", "sprint" => has_sprint ? "1" : "0")

# ✓ or, when the column really is a flag, declare it `sprint = BooleanField()` and keep the Bool
```
