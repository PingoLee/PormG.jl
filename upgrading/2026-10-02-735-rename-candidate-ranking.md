## `makemigrations`: rename candidates are ranked, and a join table follows its model's rename (#735)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #735; `src/migrations/planner.jl` (`_ranked_field_candidates`, `_ranked_table_candidates`, `_join_table_rename_source`, `_join_table_endpoint_renames`)
- **Severity**: behavior change, only to the interactive rename questions. A plan built from the
  same choices is the same SQL. What can change is **which number names which candidate**, the
  order the questions come in, and how many questions there are. A plan for an empty database also
  lists its tables in table-name order now, where it used to follow `Dict` order; the statements
  are the same.

### What changed

| | before | after |
|---|---|---|
| Field candidates | every removed column, by name | same-definition columns first, then the rest; each by name within its group, with its type, and the others say what the rename would also change |
| Table candidates | every vanished table, in catalog order, numbered by catalog position (a claimed one left a gap) | most matching columns first, ties in catalog order, numbered `1..n` with no gap, each with `(k of n columns match)` |
| Order of the table questions | `Dict` order | table-name order, the auto join tables last |
| An auto many-to-many join table when its model is renamed | asked as a model of its own, and its endpoint column as a field | renamed with its model, unasked, when exactly one vanished table fits; its endpoint column likewise |

The candidates offered are the same; none is filtered out.

### How to find the calls to migrate

Only code that pipes answers into `makemigrations` (or `get_migration_plan`) through `stdin` is
affected, because its numbers and its count of answers were written against the old order:

```bash
grep -rnE 'redirect_stdin|makemigrations\(.*interactive *= *true' --include=*.jl .
```

### Migrate your app

Run the script interactively once and read the new prompts, then rewrite the answers to match.
For example, a script that renamed a column with the second name-sorted candidate:

```julia
# before — "2" was the second removed column by name
redirect_stdin(answers_file("2\n")) do
  PormG.Migrations.makemigrations("db")
end

# after — same-definition candidates come first; read the prompt and answer its number
redirect_stdin(answers_file("1\n")) do
  PormG.Migrations.makemigrations("db")
end
```

A script that renamed a model with a `ManyToManyField` used to answer the join table's question and
its column's too. Drop those answers: an extra answer is read as the answer to the next question,
or is left unread.
