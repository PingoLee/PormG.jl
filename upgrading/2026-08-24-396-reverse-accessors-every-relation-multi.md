## Reverse accessors — every relation in a multi-relation group is disambiguated (#396)

- **Version**: 0.5.0
- **PormG ref**: #396; `src/Models.jl`, `docs/src/many_to_many.md`,
  `docs/src/read/values_and_joins.md`, `docs/src/fields.md`, `src/models/fields.jl`
- **Recorded**: 2026-08-24
- **Severity**: **breaking (narrow, source-visible)** — a model declaring **two or more** relations to
  the same target model, with `related_name` omitted on any of them, now installs different reverse
  accessors on that target. A lookup path or a `related_objects[…]` read using the old key raises
  `UnknownFieldError`. A model with one relation per target is untouched, and an explicit
  `related_name` always wins. Part of the `0.5.x` pre-publish wave.

### What changed

The accessor a relation installs on its target was derived *while* `set_models` walked
`pairs(model.fields)`, accumulating a per-target counter as it went. So in a group of N relations to
one target, the field **visited first** kept the bare model name and the rest were suffixed
`<model>_<field>`. `Model_Type.fields` is an unordered `Dict`, so which one that was is hash order —
and adding an unrelated field to the model rehashed it.

`ManyToManyField` never entered the counter at all. A model declaring both a self-`ForeignKey` and a
self-`ManyToManyField` therefore derived the bare model name twice: a foreign-key-first walk raised
`ModelDefinitionError`, and a many-to-many-first walk **silently replaced** the registered
`ManyToManyRelation` with a `ReverseRelation` — the many-to-many reverse end disappeared with no
error, and the manager filtering on it answered the opposite question.

Three rules replace it:

> **The count is taken before anything is registered, and it counts every relation — `ForeignKey`,
> `OneToOneField` and `ManyToManyField` — that the model declares to that target.**
>
> **In a group of two or more, no relation keeps the bare model name.** Every member is
> `<model>_<field>`, lowercased. A model with a single relation to a target is unchanged.
>
> **The accessor is checked against the target's field names and its existing accessors, on every
> registration path.** A clash raises `ModelDefinitionError` naming both colliding ends and the name
> they collide on — never a silent overwrite.

The messages changed with it. They used to name the model twice and neither field ("The related_name
X in the model Y is already defined"), which on a self-relation read as the model colliding with
itself; they now name `Model.field` for both ends, say whether PormG or you chose the name, and end
with the remedy.

Also, and unlikely to force anything: PormG no longer writes a derived name back onto
`field.related_name`. That write-back used to be the idempotency latch; the derivation is a pure
function now, so it is dead weight. `related_name === nothing` again means *"the declaration named
none"*, which is what stops `Models.Model_to_str` baking a PormG-invented accessor into a regenerated
model file. If you read `field.related_name` expecting the derived string, read
`target.related_objects` instead — that is where the accessor actually lives.

### How to find the calls to migrate

Only a model with **two or more relations to one target and at least one omitted `related_name`** is
affected. Find the groups first, then the reads.

```bash
# 1. Candidate groups — the same target named twice inside one model. Read the hits: a group whose
#    members all pin related_name explicitly is NOT affected.
rg -n --glob '**/*models*.jl' 'ForeignKey\(|OneToOneField\(|ManyToManyField\('

# 2. Then the reads of the OLD bare key, for each affected child model. Substitute its lowercase
#    logical name (django_prefix stripped, as get_model_name derives it).
rg -n --glob '**/*.jl' '"tb_cidadao__|related_objects\["tb_cidadao"\]'
```

You do not have to derive the new names by hand: `set_models` logs every one it derives at `@info` —
`<model>.<field> declares no related_name and is one of N relations to <target>; its reverse accessor
is <name>` — so loading the models once prints the complete list.

### Migrate your app

```julia
# Tb_cidadao declares TWO foreign keys to Tb_localidade and names neither:
#   co_localidade          = Models.ForeignKey(Tb_localidade, …)
#   co_localidade_endereco = Models.ForeignKey(Tb_localidade, …)

# ✗ BEFORE — one of the two answered to the bare model name, and which one was hash order.
rows = eM.Tb_localidade.objects.
    filter("tb_cidadao__no_cidadao" => "Senna").
    values("no_localidade").
    list()

# ✓ AFTER — each is named after the field that carries it.
rows = eM.Tb_localidade.objects.
    filter("tb_cidadao_co_localidade__no_cidadao" => "Senna").
    values("no_localidade").
    list()
```

Or pin the names in the model and never think about it again — an explicit `related_name` is
unaffected by any of this:

```julia
co_localidade          = Models.ForeignKey(Tb_localidade, …, related_name = "cidadaos"),
co_localidade_endereco = Models.ForeignKey(Tb_localidade, …, related_name = "cidadaos_endereco"),
```
