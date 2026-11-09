## Every relation resolves to a model at `set_models`, or registration refuses (#1601)

- **Version**: 0.10.0
- **PormG ref**: #1601, #1599, #354, #1689 ; `src/Models.jl`, `src/querybuilder/build_joins.jl`, `src/querybuilder/many_to_many.jl`, `src/querybuilder/execution_write.jl`
- **Recorded**: 2026-11-06
- **Severity**: breaking, for a models module with a relation whose target is not one of the models a registered module declares. A module whose `ForeignKey` / `OneToOneField` / `ManyToManyField` targets are models it declares (`Models.@models`, #1602), or models a module registered before it declares, is unaffected.

### What changed

Registration resolves every relation target — a `ForeignKey`, `OneToOneField` or `ManyToManyField`
`to`, and a many-to-many `through` — against the declared model sets, and refuses there when it
cannot. A `to` given as a string names a model the module declares, by its binding or its table
name, and is replaced on the field by the model. The three query-time fallbacks that looked a
related model up by name (a projected `save()`, the forward many-to-many join and its manager) read
the model registration recorded instead, and the `uppercasefirst(model.name)` guess at a many-to-many side's
Julia binding is gone.

| | before | now |
|---|---|---|
| a `to` string naming no model the module declares (a typo, a model defined elsewhere) | many-to-many: a `QueryBuildError` at the first join; `save()` of a projected FK: a `QueryBuildError` | `ModelDefinitionError` at `set_models`, naming the field, the target and the models the module declares |
| a relation to a model object no registered module declares (a `using`-scoped model left out of `Models.@models`, a bare `Models.Model(…)`, a model only `bind!` bound) | registered, with the target left without a connection (#354) | `ModelDefinitionError` at `set_models`, naming the target and both fixes |
| a many-to-many side whose binding the module could not find | its binding guessed as `uppercasefirst(name)` | the binding read from the declared set; a model with none is refused |
| `ManyToManyRelation.owner_model_resolved` / `related_model_resolved` | could be `nothing` | always the model |

A cross-module relation still registers: the target's own module must be registered first, **or** the
target listed in this module's `Models.@models` line — either, not both. A model listed by two
registered modules belongs to the one registered last, and registering it again clears the reverse
accessors the other module's models had installed on it.

One hop is not resolved at registration yet: a many-to-many traversed from the **target's** side.
The reverse accessor still looks the owner model up by its binding in the target's module, so with
`Race.drivers = ManyToManyField(Driver, related_name = "races")` in one module and `Driver` in another,
`Driver.objects.filter("races__year" => 2009)` raises `UndefVarError` unless the target's module binds
`Race` too — and if it binds a *different* model under that name, the hop joins that model's table,
with no error. Registration accepts the relation, so either shows only at the first such query. #1689
moves that lookup onto the model registration recorded.

### How to find the calls to migrate

Register each module and read the error; nothing changes for a module that registers cleanly. The
shapes that are refused:

```
grep -rnE "(ForeignKey|OneToOneField|ManyToManyField)\(\"" --include=*.jl <your models folders>
grep -rn "^\s*using \.\." --include=*.jl <your models folders>
```

### Migrate your app

```julia
# ✗ before: Championship reaches the module through `using`, and is not declared
module models
import PormG.Models
using ..Shared                      # exports Championship
Driver::Models.ModelType = Models.Model(driverid = Models.IDField(),
  championships = Models.ManyToManyField(Championship))
Models.@models Driver
end

# ✓ after: declare it here (or, instead, register `Shared`, declaring it there, before this module)
module models
import PormG.Models
using ..Shared
Driver::Models.ModelType = Models.Model(driverid = Models.IDField(),
  championships = Models.ManyToManyField(Championship))
Models.@models Driver Championship
end
```
