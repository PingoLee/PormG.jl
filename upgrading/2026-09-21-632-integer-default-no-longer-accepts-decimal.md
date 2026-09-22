## An integer field's `default=` no longer accepts a `Decimals.Decimal` (#632)

- **Version**: Unreleased
- **Recorded**: 2026-09-21
- **PormG ref**: #632; `src/Models.jl` (`format2int64`)
- **Severity**: breaking — a `default=` spelling that constructed a field now raises

### What changed

`format2int64` had a `Decimals.Decimal` method, so the seven constructors that share it — `IDField`,
`ForeignKey`, `OneToOneField`, `IntegerField`, `PositiveSmallIntegerField`, `PositiveIntegerField`
and `BigIntegerField` — accepted a `Decimal` as `default=` and stored its `Int64` value. The
introspected side never did: `Migrations._coerce_default` refused one on an integer column, and that
helper exists precisely so the two sides land on the same Julia value. The method is gone; both
sides now refuse, with `FieldValidationError`.

`FloatField` and `DecimalField` are **unchanged** and still take a `Decimal`, as does
`_coerce_default` on a float column. The asymmetry is deliberate: a float column can hold a scaled
value and an integer column cannot.

The old acceptance was also spelling-dependent rather than value-dependent, which is why it reads as
an accident. `Int64(::Decimal)` only succeeds at scale `0`, and nothing normalized on the way in:

```julia
Decimal(0,  5,  0)        # = 5     accepted, stored 5
Decimal(0, 50, -1)        # = 5.0   integral — and refused anyway
Decimal(0,  5, -1)        # = 0.5   refused, correctly
parse(Decimal, "5.0")     # normalizes to scale 0, so this one DID work
```

Whether a value was accepted depended on how the `Decimal` was built, not on what it denoted.

**This is `default=` only.** Passing an integer-valued `Decimal` as a *value* — in `create`,
`update`, `bulk_*` or a filter — is unchanged and still accepted, and a fractional one is still
refused. That path has its own coercion and never used the method removed here.

### How to find the calls to migrate

```bash
grep -rn 'Field(.*default *=.*Decimal' --include=*.jl .
```

At runtime the refusal reads:

```
Invalid default value for IntegerField. Expected type: Union{Nothing, Int64}, got: Decimal.
```

### Migrate your app

```julia
# ✗ before — a Decimal on an integer column
laps = Models.IntegerField(default = Decimal(0, 5, 0))

# ✓ after — write the integer, or its decimal text
laps = Models.IntegerField(default = 5)
laps = Models.IntegerField(default = "5")     # if the value arrives as text

# ✓ unchanged — a Decimal on a float/decimal column is still accepted
points = Models.FloatField(default = Decimal(0, 5, -1))     # 0.5
```

If the value is computed and genuinely a `Decimal`, convert at the call site — `Int64(d)` raises on
a non-integral value, which is the check the field used to perform implicitly.
