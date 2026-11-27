## A reverse many-to-many hop reads the model the relation recorded, not a model found by name (#1689)

- **Version**: Unreleased
- **PormG ref**: #1689 ; `src/querybuilder/join_conditions.jl`
- **Recorded**: 2026-11-27
- **Severity**: behavior change, only for a many-to-many declared across two model modules, traversed from the
  target's side. A relation declared within one module renders exactly as before.

### What changed

A path through a many-to-many's reverse accessor (from `Driver` back to `Race` when `Race` declares
`drivers = ManyToManyField(Driver, related_name = "races")`) took its next model by looking the owner up by its binding
name (`Race`) in the **target's** module, the one that defines `Driver`. When the two models live in different modules:

| the case | before | now |
|---|---|---|
| the target's module binds no `Race`: `M.Driver.objects.filter("races__year" => 2009).values("surname").distinct()` | `QueryBuildError`: `No model is bound as `Race` in the models module of driver. …` | renders and returns the drivers |
| the target's module declares a different model as `Race` (or one whose name reads as `race`): a path that walks on past the hop, such as `on("races__circuitid", …)` | `QueryBuildError` naming the other model: `… The segment 'circuitid' is not a relation on model '<other model's name>'.` | the error for what the path is: `on()` across a many-to-many is refused (`… crosses the ManyToMany relation 'races' …`, #977) |
| the same, wherever PormG walks a path to tell which tables a statement reaches (MySQL's `ORDER BY` alias check, a `values()` path that names a related column) | the walk continued from the other model | the walk continues from the model the relation recorded |

The hop now reads the model registration recorded on the relation (#1601), as the forward hops already did.

The models PormG considers for the `ORDER BY` alias check (on MySQL, and SQLite below 3.30, where PormG emulates
`NULLS FIRST`/`LAST`) now come from the module's model set, not a scan of its names. They are the same models, with two
exceptions. A model **imported** from another module and listed in the importer's `@models` is now considered, where the
scan left imported bindings out. A models module **redefined in place** is read through its set, as every other lookup
through the module is. This only matters for a table joined by a `cjoin` link to such a model, ordered by an alias the
check must tell apart from that table's columns: the null ordering is now decided from the projection, where it was
decided from the column of the same name.

### How to find the calls to migrate

Look for a `catch` that expects a `QueryBuildError` around a query through a many-to-many's reverse accessor, where the
many-to-many is declared in another module than its target:

```
grep -rn "ManyToManyField" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before: a cross-module reverse many-to-many raised, so the query was written from the owner's side
M.Race.objects.filter("drivers__surname" => "Button").values("year").distinct()
# ✓ after: the reverse accessor works from the target's side too
M.Driver.objects.filter("races__year" => 2009).values("surname").distinct()
```
