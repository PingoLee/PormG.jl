## A model holds PormG's own field types only; `ModelType.name` is a `String` (#1604)

- **Version**: Unreleased
- **PormG ref**: #1604, #1599 ; `src/Models.jl`
- **Recorded**: 2026-11-07
- **Severity**: breaking, for code that defines its own `PormGField` subtype and puts it in a model, or that assigns a non-`String` to `ModelType.name`. Models built from PormG's field constructors are unaffected.

### What changed

`ModelType.fields` holds the closed union of PormG's field types (`Models.AnyField`), so a read of a
slot every field carries — `field.type`, `field.primary_key` — has one concrete type, which a
`juliac --trim` binary needs (#1599). `ModelType.related_objects` holds the union of its two relation
types, and `ModelType.name` is a `String`.

| | before | now |
|---|---|---|
| `Model(…)`, `Model(name, dict)`, `add_field!` with a field whose type is your own `PormGField` subtype | accepted; it failed later, when PormG rendered or migrated it | `ModelDefinitionError` naming the field and its type |
| `ModelType(name = SubString(…), …)` / `model.name = s` | kept the `AbstractString` as given | converted to a `String` (`String(s)`); a value with no conversion to `String` raises |
| `typeof(model.fields)` | `OrderedDict{String, PormGField}` | `OrderedDict{String, Models.AnyField}` |
| `typeof(model.related_objects)` | `Dict{String, Any}` | `Dict{String, Union{ReverseRelation, ManyToManyRelation}}` |

PormG never documented user field types, and its code already treated the set as closed (a field's
constructor is found from its struct name). A field-type extension point, if one is added, will be an
explicit API rather than an open abstract type.

### How to find the calls to migrate

```
grep -rnE "<:\s*(PormG\.)?(Models\.)?PormGField" --include=*.jl .
grep -rnE "\.name\s*=" --include=*.jl <code that edits models>
```

### Migrate your app

```julia
# ✗ before: a field type of your own
struct LapTimeField <: PormG.PormGField
  # …
end
Lap::Models.ModelType = Models.Model(lapid = Models.IDField(), time = LapTimeField())

# ✓ after: one of PormG's field types
Lap::Models.ModelType = Models.Model(lapid = Models.IDField(), time = Models.DurationField())
```
