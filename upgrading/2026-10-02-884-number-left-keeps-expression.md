## `n * expr`, `n + expr` — a number on the left keeps the whole expression (#884)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #884; `src/querybuilder/types.jl` (`Base.:+` / `Base.:*` with a number on the left)
- **Severity**: behavior change. A silently wrong result on both engines becomes the right one.

### What changed

A number on the **left** of an `F` expression used to keep only the expression's left-most column.
The rest of the expression was dropped, with no error, on PostgreSQL and SQLite alike.

| Expression | before | after |
|---|---|---|
| `2 * (F("points") - F("amount"))` | `"points" * 2` | `("points" - "amount") * 2` |
| `1 + (F("points") * F("amount"))` | `"points" + 1` | `("points" * "amount") + 1` |
| `2 * F("points")`, `(F("a") - F("b")) * 2` | correct | unchanged |

`n + expr` and `n * expr` are now built exactly as `expr + n` and `expr * n`.

### How to find the calls to migrate

A number followed by `*` or `+` and a parenthesised expression that starts with `F(`:

```bash
grep -rnP '\b\d+(\.\d+)?\s*[*+]\s*\(\s*F\(' src/
```

A match on a bare column in parentheses (`2 * (F("x"))`) was always right. The grep cannot see an
expression held in a variable (`d = F("a") - F("b"); 2 * d`), so also look for numbers multiplying
or added to such variables.

### Migrate your app

No source edit is needed for the new result. Remove any workaround that compensated for the old one:

```julia
# ✗ before: the number moved to the right to dodge the bug
values("gap" => (F("points") - F("amount")) * 2)
# ✓ after: either order gives the same SQL
values("gap" => 2 * (F("points") - F("amount")))
```

Check any stored or reported value that was computed with the number on the left: it held the
left-most column's value, not the expression's.
