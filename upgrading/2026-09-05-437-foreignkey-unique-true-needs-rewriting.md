## `ForeignKey(…, unique=true)` no longer needs rewriting to `OneToOneField` (#437)

- **Version**: 0.6.0
- **PormG ref**: #437 (retracts the migration advised by #417, below under `0.5.0`);
  `src/migrations/planner.jl`, `src/models/fields.jl`
- **Recorded**: 2026-09-05
- **Severity**: **behavior change** — it *removes* required work. Nothing to migrate; this entry
  exists to cancel an instruction an earlier one gave.

### What changed

The `0.5.0` entry for #417 (further down this file) told you to rewrite every
`ForeignKey(…, unique=true)` as `OneToOneField(…)`, because the migration planner compared the
declared field to the live column **by Julia struct type** and so proposed an endless no-op `ALTER`
— a full table rebuild on SQLite — whenever any other column in that table changed.

The planner now diffs that pair **attribute by attribute** instead, so both spellings converge
against the same live column and neither churns. `OneToOneField` remains the spelling to *prefer*
(it is what introspection reports on both backends), but it is a readability preference, not a
correctness requirement.

Note for anyone who read the #417 entry closely: it predicted this would be fixed by making
`Dialect.describes_same_column` accept a pair where both sides are relational. It was not.
That predicate still refuses **every** relational field, deliberately — an `sForeignKey` and an
`sBigIntegerField` both render `bigint`, and equating them would silently stop planning the foreign
key constraint add/drop. The fix sits one branch earlier, in the planner.

### How to find the calls to migrate

None. If you already did the #417 rewrite, keep it — it is still the preferred spelling and nothing
about it is wrong. If you have not, you no longer need to: **skip grep recipe (4) in the #417 entry.**

### Migrate your app

```julia
# Both spellings are correct, and both converge against the same live column.
profile_id = Models.ForeignKey(Driver, unique = true)   # no longer churns
profile_id = Models.OneToOneField(Driver)               # preferred, unchanged
```
