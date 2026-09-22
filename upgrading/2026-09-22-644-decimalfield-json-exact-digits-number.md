## `list(:json)` emits a `DecimalField` as an exact JSON number (#644)

- **Version**: Unreleased
- **Recorded**: 2026-09-22
- **PormG ref**: #644; `src/querybuilder/execution.jl` (`_json_value`)
- **Severity**: behavior change — the JSON text for a `DecimalField` column changes

### What changed

`_json_value` had no `Decimals.Decimal` arm, so nothing normalized a decimal on the way out. Because
`Decimals.Decimal <: AbstractFloat`, `JSON` took its **number** path and routed the value through a
`Float64`. It now receives the digits `sDecimalField`'s own formatter writes, spliced as a raw JSON
number, so the column stays a number and carries its exact value.

Both emitters change together — `query.list(:json)` and `JSON.json(query.list())` share one row
shape, and the documented equality between them still holds.

Three classes of value move; everything else is byte-identical:

```
whole value        14.0                   ->  14
small scale        1.0e-6                 ->  0.000001
fractional >= 1e6  1.23456789e6           ->  1234567.89
past Float64       1.2345678901234568e16  ->  12345678901234567.89
```

The third row is the one most likely to be in a recorded response body: any fractional decimal at or
above a million was rendered in exponent form and now is not. A seven-figure money amount hits it.

A `DecimalField(10, 2)` — the constructor default — never drifted, because every width up to about
sixteen significant digits round-trips through a `Float64` exactly. So if your decimal columns are
narrow and fractional, the only change you will see is the loss of a trailing `.0` on whole values.

It is **not** a string. Django's `DjangoJSONEncoder` and DRF's `COERCE_DECIMAL_TO_STRING` both
serialize a decimal as `"99.99"`; PormG emits `99.99` instead, so consumers need no parsing step and
the column keeps one JSON **type** on both engines. PostgreSQL hands back a `Decimals.Decimal` for
every value while SQLite's `NUMERIC` affinity hands back an `Int64` for a whole one and a `Float64` for
a fractional one — three Julia types, one JSON type.

The **text** is a different claim, and a narrower one: it agrees while the value SQLite stored prints
the digits the decimal has, which covers every whole value and fractional values below about a million.
Past that PostgreSQL emits `1234567.89` where SQLite emits `1.23456789e6`. Before this change they
agreed there — on SQLite's rendering — so if you compare response text across engines, this is where
that stops working. Both still parse to the same number.

**Two limits, both narrower than "decimals are exact now".**

*Scalars only.* A decimal that is the column's own value is covered. One nested inside a container — a
PostgreSQL `numeric[]`, delivered as a `Vector{Decimal}` — is not reached and still goes through a
`Float64`. That is the same boundary the `DurationField` formatter has had since it shipped.

*PostgreSQL only, past ~15 digits.* SQLite has no exact decimal type: a `DECIMAL(p, s)` column takes
`NUMERIC` affinity, which converts the value **as it is stored**, so `12345678901234567.89` becomes the
integer `12345678901234568` before PormG ever reads it. Nothing on the read path can recover that. On
SQLite a `DecimalField` is precise only within what an `Int64`/`Float64` holds.

Exactness is otherwise a property of the *document*. A consumer whose JSON parser converts every number
to a double — JavaScript's `JSON.parse` does — still rounds past about sixteen significant digits. What
changed is that PormG is no longer the party losing the digits.

One repair rides along: at the declared `[compat] JSON = "1"` floor, JSON `1.0.0` raised
`MethodError: no method matching +(::Nothing, ::Int64)` on any `Decimal`, so `list(:json)` over a
PostgreSQL `DecimalField` could not run at all there. It now works at every version in the range,
because every value a driver can deliver reaches `JSON` as spliced number text or as a string, never as
a `Decimal`.

### How to find the calls to migrate

Find the reads whose output shape moved:

```bash
grep -rn 'list(:json)\|JSON.json(' --include=*.jl .
```

Then check whether any of them projects a `DecimalField`:

```bash
grep -rn 'DecimalField' --include=*.jl .
```

Nothing raises and nothing warns — if a response body is asserted anywhere, the assertion is what
tells you.

### Migrate your app

Only recorded response text needs touching. A snapshot or a literal comparison over a whole value
loses its `.0`:

```julia
# ✗ before
@test query.list(:json) == """[{"points":14.0}]"""

# ✓ after
@test query.list(:json) == """[{"points":14}]"""
```

Parsing consumers need no change — the column was a JSON number before and is one now:

```julia
# unchanged, both before and after
JSON.parse(query.list(:json))[1]["points"]      # => 14
```

If you had worked around the drift by projecting a cast or formatting the column yourself, that
workaround can go:

```julia
# ✗ before — casting to text to keep the digits
query.annotate("points_txt" => Cast("points", "TEXT")).values("points_txt").list(:json)

# ✓ after — the column carries its own digits
query.values("points").list(:json)
```
