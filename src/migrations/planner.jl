# ==============================================================================
# MIGRATION PLANNER
# Logic for diffing current code models against database state and generating
# migration plans (makemigrations).
# ==============================================================================

# ---
# Internal Helpers
# ---

# The attribute classification that used to live here — `_NON_SCHEMA_FIELD_ATTRS` — moved to
# `src/migrations/column_spec.jl` as `NON_DB_ATTRS` / `SCHEMA_ATTRS` when #507 replaced the
# attribute-wise field diff with the canonical column IR. It is stated ONCE there, next to the
# compiler that reads it, and a drift guard fails the suite when a `PormGField` gains a slot the
# compiler neither reads nor classifies. Do not reintroduce a skip list here: three lists that
# disagreed with each other is the defect #507 closed.

# #498 defined `_FK_IDENTITY_ATTRS = (:to, :pk_field, :on_delete)` here — the attributes a FOREIGN
# KEY constraint carries and a column ALTER cannot say. They had to enter the difference set (they
# ARE schema, and they are what opened the alteration gate) but never reach `Dialect.alter_field`,
# which has no branch for any of them, so every call site that handed the vector to the renderer had
# to remember to filter them out first.
#
# #507 phase 2 deleted the constant because there is nothing left to filter. The IR carries the whole
# constraint as ONE facet, `:reference`, and `alter_field` simply has no branch for it: a slot with no
# branch renders nothing, and `_fk_constraint_action` below renders it as DROP + ADD CONSTRAINT off
# the same slot. A filter someone has to remember became an absence that cannot be forgotten.
#
# `on_update`, `deferrable` and `initially_deferred` are not on this path, and since #516 they do not
# exist: `add_foreign_key` renders no `ON UPDATE` clause and hardcodes `DEFERRABLE INITIALLY
# DEFERRED`, so nothing ever emitted them and neither reader read them back. #507 classified them
# non-schema to stop them churning an empty ALTER — a full table rebuild on SQLite — on every run;
# #516 removed the keywords instead, so `_common_kwargs` now refuses them at declaration time.

# #437 / #507: `_diffs_attribute_wise` lived here — the predicate that decided whether two field
# structs shared an attribute vocabulary and could be diffed attribute by attribute. It is gone with
# the rest of the struct-comparison machinery: `Migrations.column_spec` compiles BOTH sides to a
# `ColumnSpec` and the FK/O2O pair it existed to admit is simply two fields that compile the same.
#
# The missing-subtype shape it warned about still stands, though, and now has a sharper form: the
# planner's field diff performs NO `isa` dispatch on field structs at all. A new one here is a
# regression against the IR, not a fix — `column_spec` is where a field type is interpreted.

function _hash_field_name(model_name::Symbol, field_name::Union{String, Symbol}; apend_number::Int64=5)::String
  _hash = randstring(8) 
  name = "$(model_name)_$field_name"
  if sizeof(name) + 8 + apend_number > 63
    max_prefix_length = max(1, 63 - length(_hash) - apend_number)
    if sizeof(name) > max_prefix_length
      safe_name = ""
      for c in name
        if sizeof(safe_name) + sizeof(c) <= max_prefix_length
          safe_name *= c
        else
          break
        end
      end
      name = safe_name
    end
  end
  return "$(name)_$_hash" |> lowercase
end

function _configure_order_dict_migration_plan(migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, key::String, value::String)
  value == "" && return
  if !haskey(migration_plan, model_name)
    migration_plan[model_name] = OrderedDict{String, String}(key => value)
  else
    migration_plan[model_name][key] = value
  end
end

# #82: wrap a SQLite table-rebuild block so it re-creates the table's existing secondary indexes (the
# rebuild's DROP TABLE drops them) and gates on `PRAGMA foreign_key_check(<table>)`. The CREATE INDEX DDL
# is taken verbatim from sqlite_master, so names / uniqueness / partial clauses are preserved exactly.
# No-op for PostgreSQL (real ALTER COLUMN, no rebuild) or an empty block — callers invoke it
# unconditionally so every rebuild path (field alteration AND add-NOT-NULL-with-default) is covered the
# same way. The check is SCOPED to the rebuilt table (not the whole DB) so an unrelated pre-existing orphan
# elsewhere can't fail this migration; the rename preserves the table name + PKs, so children of this table
# stay valid and need no check.
function _sqlite_rebuild_preserving_indexes(conn, table_name::String, rebuild_sql::AbstractString;
                                            surviving_columns::Union{Nothing,Set{String}} = nothing,
                                            column_renames::Dict{String,String} = Dict{String,String}())::String
  (!(conn isa PormGSQLite) || isempty(rebuild_sql)) && return String(rebuild_sql)
  # #116: when the rebuild removes columns (FK-field deletion), pass the rebuilt table's columns so an
  # index on a just-dropped column isn't re-created ("no such column"). `nothing` (the default) preserves
  # every live index, i.e. the pre-#116 behavior for pure alterations where no column disappears.
  # #150: `column_renames` (old ⇒ new physical name) maps a renamed column so its live index survives the
  # filter and is re-created under the new name; empty (the default) for every non-rename rebuild.
  idx_ddls = get_secondary_index_ddls(conn, table_name; surviving_columns = surviving_columns, column_renames = column_renames)
  safe_tbl = replace(table_name, "\"" => "\"\"")
  return join(String[String(rebuild_sql); idx_ddls; "PRAGMA foreign_key_check(\"$(safe_tbl)\");"], "\n")
end

# Physical column names (db_column when set, else field name) of a model's rebuilt table — the exact set
# `alter_field(::PormGSQLite, model, …)` writes into the new CREATE TABLE / INSERT (see Dialect.jl). Passed
# as `surviving_columns` to `_sqlite_rebuild_preserving_indexes` so index preservation stays column-aware
# across a rebuild that drops a column (#116).
_model_physical_columns(model::PormGModel)::Set{String} =
  Set(Models.field_db_column(f, string(k)) for (k, f) in model.fields)

"""
    _fk_constraint_action(new_spec, old_spec) -> Symbol

The four things that can happen to one column's FOREIGN KEY constraint: `:add`, `:drop`, `:repoint`
or `:none` (#498).

**Read off the column IR, and therefore stated once for the whole planner** (#507 phase 2). Every
caller — the alteration path, the rename branch, the field-deletion loop — asks this one function,
so no two of them can disagree about whether a reference moved:

  * a reference that **appears** is `:add`;
  * one that **disappears** is `:drop`, which is also what `new_spec === nothing` means (the
    field-DELETION path: the column is going, so its constraint is going with it);
  * two references present whose [`reference_delta`](@ref) is non-empty is `:repoint` — a different
    parent table, a different parent column, or a different `ON DELETE`. PostgreSQL has no way to
    re-point a constraint in place (`ALTER TABLE … ALTER CONSTRAINT` only changes deferrability), so
    that can only be expressed as DROP followed by ADD;
  * anything else is `:none`.

This replaced TWO functions that computed the same thing independently. `_fk_definition_changed`
(#150, the SQLite rename-rebuild gate) was `_compare_field_foreign_key` + `fk_target_column` +
`_fk_on_delete_equal` — which is `reference_delta` by another name, reached through three field reads
instead of one spec comparison. Before that, the decision lived as two MIRRORED XOR GUARDS inside the
drop and add helpers, each asking only "is a constraint appearing or disappearing?"; between them
they could not express the fourth state, so a key re-pointed at a different parent satisfied neither
and planned nothing at all on PostgreSQL, forever.

`db_constraint` is not consulted here and does not need to be: `column_spec` gives a
`db_constraint = false` key no reference at all, because there is no constraint in the database to
compare (#503/#408). A flip either way therefore lands as `:add` or `:drop` on its own.
"""
function _fk_constraint_action(new_spec::Union{ColumnSpec, Nothing}, old_spec::ColumnSpec)::Symbol
  old_ref = old_spec.reference
  new_ref = new_spec === nothing ? nothing : new_spec.reference
  old_ref !== nothing && new_ref === nothing && return :drop
  new_ref !== nothing && old_ref === nothing && return :add
  (new_ref !== nothing && old_ref !== nothing) || return :none
  return isempty(reference_delta(new_ref, old_ref)) ? :none : :repoint
end

# The delta-shaped spelling, for the call sites that hold one. Same decision, one argument.
_fk_constraint_action(delta::ColumnDelta)::Symbol =
  _fk_constraint_action(delta.new_spec, delta.old_spec)

function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_spec::Union{ColumnSpec, Nothing}, old_spec::ColumnSpec)::Nothing
  # #498: the precondition is `_fk_constraint_action`, not a locally-spelled XOR. Both `:drop` (the
  # constraint is going away) and `:repoint` (it stays, but must be re-issued against a new
  # definition) need the live one dropped first. Deriving it rather than accepting it as an argument
  # keeps a caller from passing an action that disagrees with the specs it also passes.
  #
  # `field_name` is the column to look the LIVE constraint up by, which on a rename is the PRE-rename
  # name: nothing has run yet when the plan is built, so the catalog still knows the old column.
  if _fk_constraint_action(new_spec, old_spec) in (:drop, :repoint)
    if conn isa PormGSQLite
      # SQLite has no `ALTER TABLE DROP CONSTRAINT`; an FK can only be removed by rebuilding the
      # table. On the field-alteration path this is a no-op ON PURPOSE: `_alter_table_fields`
      # already emits a full table rebuild (Dialect.alter_field wrapped by
      # _sqlite_rebuild_preserving_indexes) from the DESIRED model, and that rebuild simply omits
      # the FOREIGN KEY clause when the desired field dropped it — so the constraint is already
      # gone, data + indexes are preserved, and no separate FK-drop DDL exists to emit. (#83)
      # NOTE: field DELETION (drop_field → DROP COLUMN) and column RENAME do NOT get a rebuild, so
      # removing an FK *there* is still unsupported on SQLite — tracked separately.
      return nothing
    end
    
    constraint_name = get_constraints_fk(conn, model_name, field_name)
    if constraint_name === nothing
      return nothing
    end
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove foreign key: $field_name", 
    Dialect.drop_foreign_key(conn, model_name, constraint_name))
  end
  return nothing
end
function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol, new_spec::Union{ColumnSpec, Nothing}, old_spec::ColumnSpec)
  _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name |> string, new_spec, old_spec)
end

function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String; index_name::Union{String, Nothing} = nothing)::Nothing
  if index_name === nothing
    index_name = get_constraints_index(conn, model_name, field_name)
  end
  
  if index_name === nothing
    return nothing
  end
  # #515: this used to emit, on PostgreSQL only, an `ALTER TABLE … DROP CONSTRAINT IF EXISTS` ahead
  # of the `DROP INDEX`, because a `UNIQUE` constraint is IMPLEMENTED BY an index of the same name
  # and PostgreSQL refuses to drop that index while the constraint owns it. It worked. That is the
  # problem: on an ordinary indexed column it was a harmless `NOTICE`, and on a `unique = true`
  # column it silently destroyed the constraint — with nothing on any of this function's three call
  # sites (the rename branch, the deleted-`db_index` flush, the field-deletion loop) to put it back,
  # and introspection reading `unique` correctly afterwards, so the model compared converged and
  # `makemigrations` never mentioned it again.
  #
  # It is gone rather than gated, and the gate is one level up instead: `get_constraints_index` now
  # refuses to return any constraint-backing index on either backend (`NOT indisunique` plus a
  # `pg_constraint` probe; `origin = 'c' AND "unique" = 0`), so the lookup path cannot reach here
  # with such a name. The one caller passing an explicit `index_name` — the deleted-`db_index` flush
  # in `_alter_table_fields` — reads it from `model.cache["index"]`, which introspection populates
  # from a CTE that already filters `NOT indisunique`.
  #
  # Removing it also changes the failure mode for anything that slips past both: a constraint-backed
  # name now makes `DROP INDEX` fail LOUDLY (*"cannot drop index … because constraint … requires
  # it"*, and the runner's transaction rolls the migration back) instead of quietly succeeding by
  # destroying the constraint first. Loud beats silent — keeping the statement would leave the bug
  # armed for the next caller to re-discover.
  #
  # Both backends now render the same single statement, so there is no longer a backend branch here.
  # `model_name` is already the RESOLVED physical table name (db_table when set, #59) and needs no
  # re-normalization through `format_model_name`; `Dialect.drop_index` does the quoting (#394).
  _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name",
  Dialect.drop_index(conn, index_name))
  return nothing
end
function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol; index_name::Union{String, Nothing} = nothing)
  _drop_index(conn, migration_plan, model_name, field_name |> string, index_name=index_name)
end

# `drop_key_column` is the column the matching DROP was keyed by, which differs from `field_name`
# only on the rename path (the drop looks the live constraint up by the PRE-rename name, while the
# ADD must name the column as it will exist once the RENAME above it has run). Defaulting it to
# `field_name` keeps every other call site reading as it did.
function _add_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_field::PormGField, delta::ColumnDelta, name::String; drop_key_column::String = field_name)::Nothing
  # to alterations
  # #498: the mirror of the drop above, and derived from the same single decision. `:add` is a
  # constraint that did not exist; `:repoint` is one that did and has just been dropped a few lines
  # earlier in the same plan — both end in the identical `ADD CONSTRAINT`, against the DESIRED field.
  action = _fk_constraint_action(delta)
  # #498: on PostgreSQL a `:repoint` re-adds ONLY if the matching DROP was actually planned. The drop
  # side returns silently when `get_constraints_fk` finds no live constraint name — harmless for a
  # plain `:drop` (nothing follows it) but not here: adding without dropping leaves the OLD constraint
  # in place and a SECOND one beside it, so every row would have to satisfy both parents and the next
  # `makemigrations` would see a converged model with a stale constraint it can never remove. That
  # state is reachable whenever introspection and the catalog lookup disagree about which table is
  # meant — a `search_path` that excludes `public` is the obvious way, since `get_database_schema`
  # reads `public` explicitly while the lookup restricts to `current_schemas(false)`.
  #
  # SCOPED to PostgreSQL, and that is load-bearing rather than defensive: SQLite's drop side is a
  # no-op that writes no plan key at all, so an unscoped check would be true for EVERY SQLite
  # `:repoint` and return here — leaving the branch below documenting a state it could never reach.
  # The guard is about a DROP that was expected and did not happen; on SQLite none is ever expected.
  #
  # Only `:repoint` needs this. An `:add` by definition had no constraint to drop.
  if conn isa PormGPostgres && action === :repoint &&
     !(haskey(migration_plan, model_name) && haskey(migration_plan[model_name], "Remove foreign key: $drop_key_column"))
    @warn "Foreign key on $(model_name).$(field_name) changed, but its live constraint could not be found; skipping the re-point rather than adding a duplicate" action
    return nothing
  end
  if action in (:add, :repoint)
    if conn isa PormGSQLite
       # `:repoint` is a SILENT no-op here, exactly as it is in `_drop_fk_constraint_in_alteration`:
       # `_alter_table_fields` already emits a full rebuild from the desired model, and that rebuild
       # re-renders the whole `FOREIGN KEY … REFERENCES … ON DELETE` clause — so the key IS
       # re-pointed on SQLite, with no separate DDL to emit and nothing for a user to act on.
       #
       # #505: `:add` says the same thing at `@info`, because the same argument applies to it. This
       # function is called from ONE place, `_plan_column_change!`, which emits the rebuild a few
       # lines earlier in the same call whenever the delta is non-empty — and a non-empty delta is
       # exactly what an `:add` or a `:repoint` implies, since a reference that moved IS a delta. So
       # by construction the rebuild has already been planned by the time this line runs. Measured on a real temp SQLite file: the rebuild renders the
       # `FOREIGN KEY … REFERENCES` clause for a newly-declared key too. The old text told the
       # operator to do by hand something that had already happened ("requires recreation. This is
       # not fully automated yet."), which is why it is gone rather than merely quieter.
       #
       # The message is deliberately scoped to THIS call site instead of claiming that adding a
       # foreign key rebuilds the table on SQLite generally — which would still be FALSE, though for
       # a smaller reason than it was. A key gained by a column that already exists reaches here; a
       # key arriving as a NEW column never does, and takes `_add_new_field` instead.
       #
       # #514 closed that second path, so the sentence this block used to end with — "a new SQLite
       # column declared `ForeignKey` silently gets no constraint" — is no longer true. A nullable,
       # defaultless new column now carries an INLINE `REFERENCES` on its `ADD COLUMN`, and every
       # other shape is routed by `_add_new_field` through a rebuild of its own. What survives of the
       # old warning is narrower and lives there: SQLite refuses `ADD COLUMN … UNIQUE` and
       # `ADD COLUMN … NOT NULL`-without-a-default outright, so those two shapes still fail. Do not
       # let this message imply it covers the new-column path either way — it does not, and the two
       # paths report differently on purpose.
       #
       # It stays a log line rather than nothing at all (option 1 in #505) because the rebuild is a
       # real cost on a large table, and a line at plan time is cheaper to notice than the DDL
       # itself — which IS visible either way, in `pending_migrations.jl` under the `Alter table:`
       # key and in `dry_run()`. The drop counterpart (#83) rebuilds just as much and reports
       # nothing; that asymmetry is a choice, not a difference in cost, and #505 deliberately did
       # not go re-open it.
       action === :add && @info "SQLite adds this foreign key through the table rebuild already planned for this alteration" table=model_name column=field_name
       return nothing
    end
    constraint_name = "$(name)_fk" |> lowercase
    # Local FK column and referenced parent column both honor db_column (#50).
    resolved_pk = Models.fk_target_column(new_field)
    local_col = Models.field_db_column(new_field, string(field_name))
    on_delete_sql = hasfield(typeof(new_field), :on_delete) ? Dialect._foreign_key_on_delete_sql(new_field.on_delete) : nothing
    _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name",
    # `_quote_table_ddl` on the referenced table (#388): `add_foreign_key` interpolates
    # `ref_table_name` verbatim — every identifier it receives is pre-quoted HERE — so an embedded
    # `"` in a parent's `db_table` would close the identifier early and corrupt the ALTER.
    Dialect.add_foreign_key(conn, model_name, "\"$(Dialect._quote_table_ddl(constraint_name))\"", "\"$(Dialect._quote_table_ddl(local_col))\"",  "\"$(Dialect._quote_table_ddl(fk_target_table(new_field; column = field_name, model = model_name)))\"", "\"$(Dialect._quote_table_ddl(resolved_pk))\"", on_delete=on_delete_sql))
  end
  return nothing
end

# Constraints and indexes for a column that is being CREATED — `_add_new_table` and
# `_add_new_field`, and nothing else.
#
# #504 gave this function an `old_field` kwarg so that the rename branch, which also called it,
# could skip adding a second FOREIGN KEY when nothing about the reference had moved (PostgreSQL's
# `RENAME COLUMN` carries the existing constraint along with the column, so an unconditional ADD
# left TWO identical constraints on one column — inserts and deletes behaved the same and only a
# doubled `information_schema` row showed it).
#
# #507 phase 2 DELETED that parameter instead of making it delta-aware, because the rename branch no
# longer calls this function at all: it routes through `_plan_column_change!`, the same ordered path
# the alteration loop uses, whose `_add_fk_constraint_in_alteration` already derives `:add` /
# `:repoint` / `:none` from the delta. So there is no longer a caller that CAN hand this function a
# column with a live constraint — #504 is unrepresentable by construction rather than declined by a
# guard. Every remaining caller is creating the column in this same migration, which is exactly why
# the key is added unconditionally here.
function _add_constrains(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::Union{String, Symbol}, field::PormGField, name::String)::Nothing
  Models.is_many_to_many_field(field) && return nothing

  # to new fields
  # If the new field is a foreign key.
  #
  # `sRelationalColumn`, not `hasfield(typeof(field), :to)`: the FK/O2O pair is spelled once in
  # `src/models/fields.jl` (#408/#409/#418/#437), and the `hasfield` form was also true for
  # `sManyToManyField` — which has a `.to` but NO `db_constraint` slot, so it only avoided a
  # `FieldError` here because of the early return above it. One predicate, no reliance on the order
  # of two guards.
  if field isa Models.sRelationalColumn && field.db_constraint
    if conn isa PormGPostgres
      constraint_name = name * "_fk" |> lowercase
      # Local FK column and referenced parent column both honor db_column (#50).
      resolved_pk = Models.fk_target_column(field)
      local_col = Models.field_db_column(field, string(field_name))
      on_delete_sql = hasfield(typeof(field), :on_delete) ? Dialect._foreign_key_on_delete_sql(field.on_delete) : nothing
      _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name",
      # Referenced table escaped as in `_add_fk_constraint_in_alteration` above (#388).
      Dialect.add_foreign_key(conn, model_table_name(model), "\"$(Dialect._quote_table_ddl(constraint_name))\"", "\"$(Dialect._quote_table_ddl(local_col))\"",  "\"$(Dialect._quote_table_ddl(fk_target_table(field; column = field_name, model = model)))\"", "\"$(Dialect._quote_table_ddl(resolved_pk))\"", on_delete=on_delete_sql))
    # No `else`, and that is now correct rather than a gap. SQLite has no `ALTER TABLE ADD
    # CONSTRAINT`, so it cannot express this statement at all — its foreign key is declared with the
    # column. #514 put both spellings where the column is written: `Dialect.add_field` renders an
    # inline `REFERENCES` when SQLite will accept one, and `_add_new_field` routes every other shape
    # through the table rebuild. This block stays PostgreSQL-only because PostgreSQL is the only
    # backend with a separate constraint to add. (Prior comment here read "we might need recreation
    # if it's a FK" — a `# TODO` in prose, and the only record the gap had.)
    end
  end

  # If the new field is also indexed (index targets the physical column, db_column #50)
  if !field.primary_key && field.db_index
    index_name = name * "_idx" |> lowercase
    index_col = Models.field_db_column(field, string(field_name))
    _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name",
    Dialect.create_index(conn, "\"$(Dialect._quote_table_ddl(index_name))\"", "\"$(Dialect._quote_table_ddl(model_table_name(model)))\"", ["\"$(Dialect._quote_table_ddl(index_col))\""]))
  end
  nothing
end

function _add_many_to_many_auto_constraints(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel)::Nothing
  haskey(model.cache, "many_to_many_auto") || return nothing

  metadata = model.cache["many_to_many_auto"]
  owner_column = metadata["owner_column"]::String
  related_column = metadata["related_column"]::String
  unique_index = metadata["unique_index"]::String
  _configure_order_dict_migration_plan(
    migration_plan,
    model_name,
    "Create many-to-many unique index",
    Dialect.create_unique_index(conn, "\"$(Dialect._quote_table_ddl(unique_index))\"", "\"$(Dialect._quote_table_ddl(model_table_name(model)))\"", ["\"$(Dialect._quote_table_ddl(owner_column))\"", "\"$(Dialect._quote_table_ddl(related_column))\""])
  )
  return nothing
end

# User-declared composite uniqueness (#19). Emits one `CREATE UNIQUE INDEX` per
# `UniqueConstraint` in `model.cache["unique_constraints"]`, generalizing the add-only
# ManyToManyField auto-index pipeline above. Called ONLY from `_add_new_table` (like the M2M
# sibling), so the index is materialized when its table is first created and never re-emitted —
# no false "pending" churn. Adding/removing a constraint on an already-migrated table (which
# needs composite-unique introspection PormG does not have yet) is out of scope for this pass.
function _add_unique_constraints(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel; seen::Set{String} = Set{String}())::Nothing
  haskey(model.cache, "unique_constraints") || return nothing
  constraints = get(model.cache["unique_constraints"], "constraints", nothing)
  constraints === nothing && return nothing
  table = model_table_name(model)
  for c in constraints
    # Resolve declared field names to physical columns (honors db_column #50; PormG adds no
    # `_id` suffix for FKs — the field name IS the column).
    cols = String[Models.model_column(model, f) for f in c.fields]
    index_name = c.name === nothing ? "$(table)_$(join(cols, "_"))_uniq" : c.name
    # The step label (and thus the plan slot) keys on index_name; a collision — same explicit
    # name, or two constraints deriving the same name — would silently overwrite. Fail loudly.
    # `seen` is OWNED BY `_add_new_table` and shared with `_add_indexes` (#347): an Index and a
    # UniqueConstraint landing on the same name are two `CREATE … INDEX` statements the database
    # rejects, and their step labels differ, so the plan would not catch it on its own.
    index_name in seen && throw(InvalidMigrationError(
      "Duplicate index name '$(index_name)' on table '$(table)'; " *
      "give each UniqueConstraint and Index a distinct name"))
    push!(seen, index_name)
    _configure_order_dict_migration_plan(
      migration_plan,
      model_name,
      "Create unique constraint: $(index_name)",
      Dialect.create_unique_index(conn, "\"$(Dialect._quote_table_ddl(index_name))\"", "\"$(Dialect._quote_table_ddl(table))\"", ["\"$(Dialect._quote_table_ddl(col))\"" for col in cols])
    )
  end
  return nothing
end

# User-declared composite indexes (#347). The plain sibling of `_add_unique_constraints` above: one
# `CREATE INDEX` per `Index` in `model.cache["composite_indexes"]`, over the same
# `Dialect.create_index` primitive the per-field `db_index` path uses — that one just never passes
# more than one column. Called ONLY from `_add_new_table`, so like its unique sibling the index is
# materialized when its table is first created and never re-emitted; adding or removing one on an
# already-migrated table is out of scope for this pass (introspection reads composite indexes back,
# but nothing diffs them yet).
#
# The step label starts with "Create index", which puts it in `runner._order_statements`' deferred
# index bucket — correct, since a CREATE INDEX only needs its table to exist.
function _add_indexes(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel; seen::Set{String} = Set{String}())::Nothing
  haskey(model.cache, "composite_indexes") || return nothing
  indexes = get(model.cache["composite_indexes"], "indexes", nothing)
  indexes === nothing && return nothing
  table = model_table_name(model)
  for ix in indexes
    cols = String[Models.model_column(model, f) for f in ix.fields]
    index_name = ix.name === nothing ? "$(table)_$(join(cols, "_"))_idx" : ix.name
    index_name in seen && throw(InvalidMigrationError(
      "Duplicate index name '$(index_name)' on table '$(table)'; " *
      "give each UniqueConstraint and Index a distinct name"))
    push!(seen, index_name)
    _configure_order_dict_migration_plan(
      migration_plan,
      model_name,
      "Create index: $(index_name)",
      Dialect.create_index(conn, "\"$(Dialect._quote_table_ddl(index_name))\"", "\"$(Dialect._quote_table_ddl(table))\"", ["\"$(Dialect._quote_table_ddl(col))\"" for col in cols])
    )
  end
  return nothing
end

function _add_new_table(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel)::Nothing
  _configure_order_dict_migration_plan(migration_plan, model_name, "New model", Dialect.create_table(conn, model))
  for (field_name, field) in model.fields
    name = _hash_field_name(model_name, field_name)
    _add_constrains(conn, migration_plan, model_name, model, field_name, field, name)
  end
  _add_many_to_many_auto_constraints(conn, migration_plan, model_name, model)
  # ONE name registry across both model-level index emitters (#347) — see `_add_unique_constraints`.
  declared_index_names = Set{String}()
  _add_unique_constraints(conn, migration_plan, model_name, model; seen = declared_index_names)
  _add_indexes(conn, migration_plan, model_name, model; seen = declared_index_names)
  return nothing
end

function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::String; temporary_default_value::Any = nothing)::Nothing
  field = model.fields[field_name]
  Models.is_many_to_many_field(field) && return nothing
  name = _hash_field_name(model_name, field_name)
  # #514: `model` lets `Dialect.add_field` resolve the parent table and render SQLite's `REFERENCES`
  # clause inline. PostgreSQL accepts and ignores it — its key is added separately, by
  # `_add_constrains` on the next line.
  _configure_order_dict_migration_plan(migration_plan, model_name, "Add field: $field_name", Dialect.add_field(conn, model_name, field_name, field, temporary_default = temporary_default_value, model = model))
  _add_constrains(conn, migration_plan, model_name, model, field_name, field, name)
  # #514: the other half. SQLite takes the inline clause only for a nullable, defaultless, non-unique
  # column (`sqlite_add_column_can_inline_fk` — SQLite's own `ADD COLUMN` rule, and Django's test
  # before it falls back to `_remake_table`). Any other shape has to reach its constraint through the
  # rebuild below, which re-renders every `FOREIGN KEY` clause from the DESIRED model and so needs no
  # new renderer. One predicate, asked here and in `add_field`, so the two halves cannot disagree.
  #
  # STATED LIMIT, because this repairs less than it looks like: the rebuild is queued AFTER the
  # `ADD COLUMN`, and SQLite refuses `ADD COLUMN … UNIQUE` and `ADD COLUMN … NOT NULL` without a
  # default whether or not a foreign key is involved. So of the ineligible shapes only NOT NULL WITH
  # a default is actually fixed here; a `unique` key (an `sOneToOneField`) and a NOT NULL key with no
  # default still abort on the first statement — exactly as they did before #514, since that refusal
  # is about the column, not the constraint. Pre-existing, unchanged, and filed separately rather
  # than widened into here.
  needs_sqlite_fk_rebuild = conn isa PormGSQLite && field isa Models.sRelationalColumn &&
                            field.db_constraint &&
                            !Dialect.sqlite_add_column_can_inline_fk(field, temporary_default_value)
  if temporary_default_value !== nothing || needs_sqlite_fk_rebuild
    # SQLite requires a full table recreation to drop the temporary default.
    # Use the same stable "Alter table:" key so multiple datetime fields being
    # added at once don't produce duplicate recreation statements.
    alter_key = conn isa PormGSQLite ? "Alter table: $model_name" : "Alter field: $field_name"
    # Delete existing recreation entry so re-insertion moves it to the END of
    # the OrderedDict — after ALL ADD COLUMNs.  Without this, the recreation
    # keeps its original position and later ADD COLUMNs hit "duplicate column".
    if conn isa PormGSQLite && haskey(migration_plan, model_name) && haskey(migration_plan[model_name], alter_key)
      delete!(migration_plan[model_name], alter_key)
    end
    # #82: this add-NOT-NULL-with-default path also rebuilds the table on SQLite, so it must preserve the
    # existing secondary indexes too (no-op on PostgreSQL).
    #
    # THE ONE DECLARED DELTA in the planner, and the only place a `ColumnDelta` is constructed rather
    # than diffed. Everywhere else the delta answers "what differs between the models file and the
    # live schema?"; here it states an instruction: *the column this migration just added carries a
    # TEMPORARY default, and the declared column does not want it.* That fact is real — the
    # `ADD COLUMN` a few lines up wrote it — but no `ColumnSpec` can hold it, because neither side of
    # the diff has a temporary default. So `old_spec` is the new column's own spec with the temporary
    # value substituted in, and `:default` is forced rather than derived.
    #
    # Forcing it is what keeps the plan byte-identical: were it diffed, a declared default that
    # happened to EQUAL the temporary one would produce an empty delta and no cleanup step at all.
    # That case is vanishingly unlikely (`_get_temporary_default_value` returns `now()` / `today()`)
    # and harmless if it happened — but "unlikely and harmless" is a reason to keep the behaviour
    # pinned, not a reason to let it drift.
    #
    # PostgreSQL DOES reach here (a new `sDateTimeField` / `sDateField` gets a temporary default on
    # both engines) and renders `DROP DEFAULT` from `new_spec.default`, which is `NoDefault` for a
    # defaultless declared field. SQLite ignores the delta and rebuilds from the desired model.
    # `_spec_or_degraded`, not `column_spec`: every other planner site compiles through the #69
    # fail-safe, and this one is reachable with an unresolved foreign key (the SQLite
    # `needs_sqlite_fk_rebuild` path), where a raise would abort `makemigrations` at a call site that
    # previously compiled nothing at all. Flagged in review.
    temp_spec = _spec_or_degraded(field, conn, "<uncompilable:new>"; name = field_name)
    # `NoDefault` when there is no temporary value to undo — the #514 SQLite-FK-rebuild caller, which
    # reaches this block with `temporary_default_value === nothing` and never reads the delta at all.
    # Writing `LiteralDefault(nothing)` there would be inert but false, and a false spec is the kind
    # of thing a later reader believes.
    live_default = temporary_default_value === nothing ? NoDefault() : LiteralDefault(temporary_default_value)
    # NOTE, because `Dialect.alter_field` now trusts `old_spec.name` as "the column the catalog
    # knows": this is the one `ColumnSpec` in the codebase whose name is NOT a live column — the
    # column is being CREATED by this same migration, so at plan time the catalog has never heard of
    # it. Harmless by construction rather than by luck: the delta's only facet is `:default`, and
    # none of the four constraint-name lookups sits in that branch.
    _configure_order_dict_migration_plan(migration_plan, model_name, alter_key,
      _sqlite_rebuild_preserving_indexes(conn, model_table_name(model),
        Dialect.alter_field(conn, model, field_name, field, nothing,
          ColumnDelta(temp_spec,
                      ColumnSpec(temp_spec.name, temp_spec.type, temp_spec.nullable,
                                 temp_spec.primary_key, temp_spec.unique,
                                 live_default, temp_spec.reference,
                                 temp_spec.checks, temp_spec.identity, temp_spec.raw),
                      [:default]));
        surviving_columns = _model_physical_columns(model)))
  elseif conn isa PormGSQLite
    # The other half of the same invariant, and the reason the block above was not enough. The
    # rebuild's `CREATE TABLE` is rendered from the DESIRED model, so it already declares every new
    # column, and its `INSERT … SELECT` reads every model column from the OLD table — which means
    # EVERY `ADD COLUMN` for this table has to run BEFORE it, not merely every *rebuilding* one.
    #
    # The delete-and-reinsert above maintains that only while the field being processed is itself
    # rebuild-triggering. A plain new column processed AFTERWARDS appended its `Add field:` step past
    # the rebuild, and `ALTER TABLE … ADD COLUMN` then hit `duplicate column name` on a column the
    # rebuild had just created — aborting the migration and rolling it back. `colect_addition` is
    # built from a `Set`, so which field lands first is hash order: the same two-column migration
    # failed or passed depending on the column names.
    #
    # Pre-existing (the only trigger was a new `sDateTimeField`/`sDateField`), but #514 widened the
    # trigger set to every new SQLite foreign key that cannot be inlined, and "add a keyed column and
    # an ordinary column in one migration" is routine — so it is fixed here rather than left for the
    # wider trigger to find. Moving the SAME statement keeps the plan otherwise identical; the SQL
    # needs no regeneration because it was always rendered from the whole desired model.
    alter_key = "Alter table: $model_name"
    if haskey(migration_plan, model_name) && haskey(migration_plan[model_name], alter_key)
      queued_rebuild = migration_plan[model_name][alter_key]
      delete!(migration_plan[model_name], alter_key)
      _configure_order_dict_migration_plan(migration_plan, model_name, alter_key, queued_rebuild)
    end
  end
  return nothing
end
function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::Symbol; temporary_default_value::Any = nothing)::Nothing
  _add_new_field(conn, migration_plan, model_name, model, field_name |> string, temporary_default_value=temporary_default_value)
end

"""
    _plan_column_change!(conn, migration_plan, model_name, declared_model, field_name,
                         new_field, old_field, delta, hashed_name;
                         old_column = nothing, column_renames = Dict{String,String}())

Plan everything one existing column needs, in the one order that works, from the one delta.

**There is exactly one of these, and that is the point of #507 phase 2.** Two call sites reach it —
the alteration loop in [`_alter_table_fields`](@ref) and the rename branch of
[`_resolve_table_fields`](@ref) — and before this function existed the second one carried its own
copy of the sequence, with its own opinion of when a constraint had moved. #504 (a rename adding a
second FOREIGN KEY) and #515 (a rename destroying the index backing a UNIQUE constraint) both lived
in that copy, and #150 needed a third predicate to decide when a rename also had to rebuild a SQLite
table. A rename is not a different kind of change; it is the same column change with a new name.

The order is fixed and each step's reason is a different one:

 1. **FK DROP**, keyed by the PRE-rename column, because at plan time the catalog still holds the old
    name and `get_constraints_fk` is what learns the live constraint's generated name.
 2. **RENAME COLUMN**, so that everything after it can name the column as it will then exist.
 3. **The column ALTER** — a real `ALTER COLUMN` on PostgreSQL, a whole-table rebuild on SQLite —
    only when the delta is non-empty.
 4. **FK ADD**, keyed by the new column, since a `:repoint`'s constraint must reference it.

`old_column === nothing` means "not a rename": step 2 is skipped. Pass it and the same four steps
plan a rename, which is how decision 5 of #507 gets its two halves for free:

  * an **empty** delta reduces this to `RENAME COLUMN` and nothing else — steps 1 and 4 are `:none`
    by construction (equal specs cannot have an unequal reference) and step 3 is gated on the delta;
  * a **non-empty** delta emits the same alteration the loop would have emitted for a column that
    kept its name. Measured on the base commit, that is a genuine fix: a rename that also retyped
    the column used to plan the `RENAME` alone and drop the type change on the floor, converging only
    on the NEXT `makemigrations`.

**ONE source for "the column the live catalog knows": `delta.old_spec.name`.** Steps 1 and 4 key on
it, and so do the four `get_constraints_*` lookups inside `Dialect.alter_field` — which is the point,
because on a rename that is the PRE-rename column and nothing has executed when the plan is built.
A fifth statement that needs a constraint name must read the same field; asking for `field_name`
there is the defect this function was reshaped to prevent (a renamed column silently lost its UNIQUE
/ PRIMARY KEY / CHECK drop, and a renamed `PositiveIntegerField` becoming a `TextField` emitted the
retype with the stale `>= 0` CHECK in place, which PostgreSQL rejects). `column_delta`'s `old_name`
is what puts it there.

`column_renames` is passed through to the SQLite rebuild so a renamed column's secondary indexes are
re-created against the new name (#150), and `_resolve_table_fields` ACCUMULATES it across the rename
loop so a table renaming two columns keeps both indexes. On SQLite the rebuild entry is also
relocated to the end of the table's plan on every registration, because it copies by the DESIRED
column names and so must follow every `RENAME COLUMN` and every `ADD COLUMN`.

`db_index` deliberately plays no part here — `index_actions` in `_alter_table_fields` owns it,
because on SQLite a non-empty delta means a rebuild that re-emits every live index, and a
`CREATE INDEX` beside it would duplicate what the rebuild just made (#82/#325).
"""
function _plan_column_change!(conn::Union{PormGPostgres, PormGSQLite},
                              migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                              model_name::Symbol,
                              declared_model::PormGModel,
                              field_name::String,
                              new_field::PormGField,
                              old_field::PormGField,
                              delta::ColumnDelta,
                              hashed_name::String;
                              old_column::Union{String, Nothing} = nothing,
                              column_renames::Dict{String, String} = Dict{String, String}())::Nothing
  isempty(delta) && old_column === nothing && return nothing
  # ONE source for "the column the live catalog knows", shared with the four constraint-name lookups
  # inside `Dialect.alter_field` (which read `delta.old_spec.name` for the same reason). On a rename
  # that is the PRE-rename column, because nothing has executed when the plan is built. The
  # `old_column` fallback covers a delta whose specs were built without names.
  drop_column = !isempty(delta.old_spec.name) ? delta.old_spec.name :
                (old_column === nothing ? field_name : old_column)

  # 1. Drop the live constraint when it is going away or has to be re-issued.
  _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, drop_column,
                                    delta.new_spec, delta.old_spec)

  # 2. The rename itself.
  old_column === nothing ||
    _configure_order_dict_migration_plan(migration_plan, model_name, "Rename field: $field_name",
                                         Dialect.rename_field(conn, model_name, old_column, field_name))

  # 3. The column change. On SQLite this is a full table rebuild from the DESIRED model, which is
  #    also what re-points a foreign key there; on PostgreSQL it is the per-slot ALTER. An empty
  #    delta means there is no column change — only a rename — so nothing is emitted.
  if !isempty(delta)
    # For SQLite every field alteration requires a full table recreation. Use a single stable key
    # ("Alter table: <model>") so repeated calls for the same table overwrite each other, producing
    # exactly one recreation statement instead of one per changed field.
    alter_key = conn isa PormGSQLite ? "Alter table: $model_name" : "Alter field: $field_name"
    # …but on SQLite the rebuild's POSITION matters as much as its content, and a rename is what
    # makes that bite. The rebuild is rendered from the DESIRED model and its `INSERT … SELECT`
    # copies by the NEW column names, so it can only execute after every RENAME on this table — and
    # `_configure_order_dict_migration_plan` overwrites a key IN PLACE, keeping the position of the
    # FIRST registration. So the entry is deleted and re-registered here, which moves it to the end
    # of the table's plan.
    #
    # That is the same delete-and-reinsert `_add_new_field` performs for the same reason (its
    # `ADD COLUMN`s must all precede the rebuild), and it replaced a plan-time refusal I had written
    # first. The refusal was never wrong, but it was ORDER-DEPENDENT: `colect_addition` is a `Set`,
    # so a rename co-occurring with a new NOT NULL column planned correctly or raised depending on
    # field-name hash order — the same logical change, two outcomes. Relocating is deterministic and
    # strictly better, because it makes the case CORRECT rather than refused: once the rebuild is
    # last, every RENAME and every `ADD COLUMN` has run, so the columns it copies all exist.
    #
    # Pre-phase-2 only an FK-definition change registered a rebuild from the rename path, which is
    # why two renames on one table could be documented as unsupported; any non-empty delta reaches
    # here now, so it is fixed instead.
    #
    # The surviving rebuild is whichever registration lands LAST, and it carries only the
    # `column_renames` THAT call was given. `_resolve_table_fields` accumulates them across the
    # rename loop, so a table renaming two columns keeps both indexes — but the alteration loop in
    # `_alter_table_fields` and `_add_new_field` register the same key with no rename map at all, so
    # a rename combined with one of those can still lose the renamed column's index. Index loss, not
    # a broken plan; the limitation is stated in full at the rename call site. (This comment claimed
    # "every renamed column keeps its secondary indexes" until review falsified it by execution —
    # inside the very function that fixed the previous overstatement.)
    if conn isa PormGSQLite && haskey(migration_plan, model_name) &&
       haskey(migration_plan[model_name], alter_key)
      delete!(migration_plan[model_name], alter_key)
    end
    # #82: on SQLite this preserves the table's secondary indexes across the rebuild and gates on
    # foreign_key_check (no-op on PostgreSQL). See _sqlite_rebuild_preserving_indexes.
    alter_sql = _sqlite_rebuild_preserving_indexes(conn, model_table_name(declared_model),
      Dialect.alter_field(conn, declared_model, field_name, new_field, old_field, delta);
      surviving_columns = _model_physical_columns(declared_model),
      column_renames = column_renames)
    _configure_order_dict_migration_plan(migration_plan, model_name, alter_key, alter_sql)
  end

  # 4. Add the constraint for an `:add` or a `:repoint`.
  _add_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name, new_field, delta,
                                   hashed_name; drop_key_column = drop_column)
  return nothing
end

function _alter_table_fields(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, settings::PormGSettings; interactive::Bool = true)::Nothing
  # @pormg_debug model_name == :new_join_position
  # #507 phase 2: NO whole-model early-out. `Models.are_model_fields_equal` used to short-circuit
  # this whole function when every field compared equal, and it was a second answer to a question
  # the column IR already answers per column — kept in phase 1 only because it was conservative by
  # construction. It is gone: the loop below always runs, and an EMPTY `ColumnDelta` is the
  # "nothing changed" answer. One comparator, one place, and no fast path left that could disagree
  # with it.
  #
  # The cost is a compilation per column on every run — a couple of dictionary lookups and one
  # rendered type string each. What it buys is that a converged schema and a changed one travel
  # the same code path, so "converged" can no longer be right by accident.
  # Compare fields
  @pormg_debug false
  # Convert keys(model.fields) to an array of stripped strings and keep mapping to original key
  # Ordered, both of them (#544). `model.fields` is an `OrderedDict` now, but a plain `Dict`
  # comprehension over it re-hashes immediately and a `Set` of those keys hashes again — so the
  # order the model declared survived into `fields` and was thrown away two lines later. Every
  # consumer below either ITERATES these (the deletion/addition loops, the deferred index pass at
  # the end of this function) or asks them for membership; `OrderedSet` answers both, so the
  # declared order now reaches the rendered DDL and the interactive rename prompts intact.
  model_fields_map = OrderedDict(String(strip(key, '"')) => String(key) for key in keys(model.fields))
  stripped_model_fields = OrderedSet(keys(model_fields_map))

  # Do the same for current_schema model fields, but key by the PHYSICAL column name
  # (db_column when set, else the field name) so the code side aligns with the
  # column-keyed introspected DB side — otherwise a field whose db_column differs from
  # its name would churn as a spurious DROP + ADD (#50). The value stays the real
  # field-name key for accessing model.fields.
  current_fields_map = OrderedDict(Models.field_db_column(field, String(strip(String(key), '"'))) => String(key) for (key, field) in current_schema[model_name][:model].fields)
  stripped_current_fields = OrderedSet(keys(current_fields_map))

  # check the field are not in current_schema (deletion)
  colect_deletion::Vector{Symbol} = []
  for field_name in stripped_model_fields
    if !(field_name in stripped_current_fields)
      push!(colect_deletion, Symbol(field_name))
    end
  end

  colect_addition::Vector{Symbol} = []
  for field_name in stripped_current_fields
    if !(field_name in stripped_model_fields)
      push!(colect_addition, Symbol(field_name))
    end
  end    

  @pormg_debug false
  # Pass maps to resolve fields so original keys can be used for accessing model.fields
  _resolve_table_fields(conn, model_name, model, current_schema[model_name][:model], colect_deletion, colect_addition, migration_plan, settings, model_fields_map, current_fields_map, interactive=interactive)

  # #325: index create/drop is DEFERRED to after the whole field loop, not emitted inline.
  # `stripped_current_fields` is a `Set`, so field order is arbitrary — and on SQLite the table
  # rebuild re-creates every live secondary index verbatim (#82). A `DROP INDEX` emitted before
  # the rebuild is therefore undone by it, and whether that happened depended on which field the
  # Set yielded first. Collecting the actions here and flushing them below puts them after any
  # rebuild, deterministically. Each entry is `(:create | :drop, physical column, hashed name,
  # live index name or nothing)`.
  index_actions = Tuple{Symbol, String, String, Union{String, Nothing}}[]

  for field_name_stripped in stripped_current_fields
    original_code_key = current_fields_map[field_name_stripped]
    if haskey(model_fields_map, field_name_stripped)
      original_db_key = model_fields_map[field_name_stripped]

      field = current_schema[model_name][:model].fields[original_code_key]
      old_field = model.fields[original_db_key]

      # A ManyToManyField is not a physical column and `sManyToManyField` is the one field struct
      # with no `db_index` at all, so the index blocks below would raise on it. It cannot normally
      # be matched here (it is never a live column), but the guard is what makes that explicit —
      # `_add_new_field` / `_add_constrains` both early-return on m2m for the same reason.
      (Models.is_many_to_many_field(field) || Models.is_many_to_many_field(old_field)) && continue

      name::String = _hash_field_name(model_name, field_name_stripped)

      # #507: ONE comparator. Both fields compile to a `ColumnSpec` — what the database can hold —
      # and the difference is read off that. This replaced four code paths that each answered
      # "same column?" with their own reconciliations and disagreed at the edges: the attribute-wise
      # loop, `Dialect.describes_same_column` (#325), the `db_constraint = false` escape (#408) and
      # the `push!(:type)` fallthrough.
      #
      # Phase 2 made the delta TYPED and made it the only input to what follows. Phase 1 adapted it
      # back into field-attribute symbols so the action code could stay untouched; that adapter is
      # gone, and with it every action site's private opinion of a fact decided right here.
      delta = column_delta(field, old_field, conn; name = field_name_stripped)

      # if field_name == "time"
      #   @pormg_debug
      # end

      # #325: the column ALTER is CONDITIONAL, but the index blocks below are not. `db_index` is in
      # `NON_DB_ATTRS` and is not a `ColumnSpec` field at all, so an index-only difference leaves the
      # delta EMPTY — which is the point (on SQLite a non-empty delta means a FULL TABLE REBUILD, for
      # something a CREATE/DROP INDEX expresses on its own). Before #325 this was an early
      # `continue`, so an index-only difference would now be planned as nothing at all.
      #
      # #507 note: the index blocks are now reachable for one pair that never reached them. The
      # retired #408 escape answered a `db_constraint = false` relational field against a live
      # `sBigIntegerField` with `continue`, which skipped the REST OF THE LOOP BODY — the two index
      # blocks included — so such a column could neither gain nor lose an index here. That was an
      # accident of the escape's shape, not a decision. It is expected to be inert in practice:
      # the FK constructors force `db_index = db_index || !db_constraint`, so a
      # `db_constraint = false` key always declares an index, and introspection reports the one
      # PormG created for it — both sides `true`, no action.
      # The FK drop, the column ALTER (or SQLite rebuild) and the FK add, in that order, all from
      # `delta` — and through the SAME function the rename branch calls, which is what stops the two
      # from drifting apart again (#504/#515). An empty delta plans nothing.
      #
      # There is no `column_attrs` filter here any more. `_FK_IDENTITY_ATTRS` existed because the
      # difference set had to carry the foreign key (it is real schema, and it is what opened this
      # gate) while `Dialect.alter_field` had no branch for it and would otherwise warn and emit
      # nothing. The IR carries the whole constraint as one `:reference` facet, `alter_field` has no
      # branch for that facet and needs none, and `_fk_constraint_action` reads it directly — so the
      # filter has nothing left to remove.
      _plan_column_change!(conn, migration_plan, model_name, current_schema[model_name][:model],
                           field_name_stripped, field, old_field, delta, name)

      # Index differences are RECORDED here and emitted after the loop — see `index_actions`.

      # Check if the field is also indexed
      if !field.primary_key && field.db_index && !old_field.db_index
        @pormg_debug false
        push!(index_actions, (:create, field_name_stripped, name, nothing))
      end

      # Check if is need to remove the index
      if !field.primary_key && old_field.db_index && !field.db_index
        @pormg_debug
        # The live model's index cache maps physical column ⇒ index name. `db_index=true` on the
        # live side means introspection saw exactly such an index, so the key is present; the
        # `nothing` fallback routes `_drop_index` through `get_constraints_index` rather than
        # raising a KeyError from inside makemigrations.
        live_index_name = get(get(model.cache, "index", Dict{String,Any}()), original_db_key, nothing)
        push!(index_actions, (:drop, field_name_stripped, name, live_index_name === nothing ? nothing : string(live_index_name)))
      end
    end
  end

  # Flush the deferred index actions — always after any "Alter table:"/"Alter field:" step the
  # loop above registered, whichever field produced it.
  for (kind, col, hashed, live_index_name) in index_actions
    if kind === :create
      # #82/#325: the SQLite rebuild already re-emits every existing index, so a CREATE INDEX
      # alongside one would duplicate it (the random suffix defeats IF NOT EXISTS). Introspection
      # now reads `db_index` back on both backends, so this branch no longer fires merely because
      # SQLite could not see the index — but the probe stays: the rebuild is emitted from the
      # DECLARED model, which can carry an index the live schema is only about to gain.
      # Genuinely-new indexes still get created.
      if !(conn isa PormGSQLite && get_constraints_index(conn, model_name, col) !== nothing)
        index_name = "$(hashed)_idx"
        _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $col",
        Dialect.create_index(conn, "\"$(Dialect._quote_table_ddl(index_name))\"", "\"$(Dialect._quote_table_ddl(model_table_name(model)))\"", ["\"$(Dialect._quote_table_ddl(col))\""]))
      end
    else
      _drop_index(conn, migration_plan, model_name, col, index_name=live_index_name)
    end
  end
end

function _resolve_table_fields(
                                conn::Union{PormGPostgres, PormGSQLite}, 
                                model_name::Symbol, 
                                model::PormGModel, 
                                current_model::PormGModel, 
                                colect_deletion::Vector{Symbol}, 
                                colect_addition::Vector{Symbol}, 
                                migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                                settings::PormGSettings,
                                # `AbstractDict` since #544: the caller now builds these as
                                # `OrderedDict` so field order survives to the DDL and the rename
                                # prompts. Only looked up here, never iterated, so the widening
                                # costs nothing and keeps a plain `Dict` caller working.
                                model_fields_map::AbstractDict{String, String},
                                current_fields_map::AbstractDict{String, String};
                                interactive::Bool = true
                              )::Nothing
  # #150/#507: the SQLite rebuild that a renamed-and-altered column needs is registered under ONE
  # key per table, so a second rename has to re-render it rather than add another — and to preserve
  # both columns' secondary indexes it needs BOTH renames. Accumulated here and passed whole to
  # every `_plan_column_change!` call, so whichever registration lands last carries all of them.
  sqlite_rename_map = Dict{String, String}()
  # Check by rename field  
  while !isempty(colect_addition)
    field_name_sym = colect_addition[1]
    field_name = field_name_sym |> string       
    colect_numbered, list_to_question = _colect_numbered_fields(colect_deletion)
    if colect_deletion |> isempty
      # `field_name` here is the physical column; pass the real field key so _add_new_field's
      # model.fields lookup resolves (the DDL re-derives the db_column from the field) (#50).
      _add_new_field(conn, migration_plan, model_name, current_model, current_fields_map[field_name], temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings))
    else       
      response = "no"
      if interactive
        print(_emsg("Is the field \"\e[4m\e[31m$field_name\e[0m\" from table \"\e[4m\e[34m$model_name\e[0m\" the same as one of the following fields: \e[4m\e[33m$list_to_question\e[0m? If yes, please enter the corresponding number; otherwise, type 'no':"))
        response = readline()
        response = strip(lowercase(response))
      end
      
      if response in ["no", "n"]
        # `field_name` is the physical column; pass the real field key (see above) (#50).
        _add_new_field(conn, migration_plan, model_name, current_model, current_fields_map[field_name], temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings))
      else
        old_field_sym::Union{Symbol,Nothing} = nothing
        try
          response_idx = parse(Int, response)
          old_field_sym = colect_numbered[response_idx]          
        catch e
          throw(InvalidMigrationError("Invalid choice \"$(response)\" — enter one of the listed option numbers; please try makemigrations again"))
        end
        old_field_name = old_field_sym |> string
        new_field = current_model.fields[current_fields_map[field_name]]
        old_field = model.fields[model_fields_map[old_field_name]]
        # #507 phase 2: a rename is the SAME column change with a new name, so it goes through the
        # same `_plan_column_change!` the alteration loop uses — FK drop (by the pre-rename column,
        # because the catalog has not been renamed yet), RENAME COLUMN, the column ALTER or SQLite
        # rebuild if the delta is non-empty, then the FK add. This branch used to hold a private copy
        # of that sequence, split in two by a `_fk_definition_changed` test, and three of the four
        # action-path bugs of the last week lived in the copy:
        #
        #   * #504 — the ADD was unconditional, so a rename whose reference had NOT moved left two
        #     identical FOREIGN KEYs on one column. Now the ADD is `_fk_constraint_action`'s `:none`
        #     and emits nothing; the pre-rename field is not even passed to `_add_constrains` any
        #     more, which is what makes the bug unrepresentable rather than declined.
        #   * #515 — the `_drop_index(old_field_name)` that stood here dropped the index BACKING a
        #     UNIQUE constraint (PostgreSQL implements one with the other), destroying the constraint
        #     silently. It is gone entirely, not merely guarded: on both engines RENAME COLUMN takes
        #     the column's existing indexes with it, so there was never anything to re-create. The
        #     narrow fix in `get_constraints_index` stays where it is, for the other callers.
        #   * #150 — `_fk_definition_changed` existed to decide when a rename ALSO needed the SQLite
        #     rebuild. A non-empty delta is that answer, and a strictly wider one: it is now also
        #     true when the rename changes the column's TYPE, which the old branch missed. Measured
        #     on the base commit, a rename-plus-retype planned the RENAME alone and dropped the type
        #     change on the floor until the next `makemigrations` re-proposed it.
        #
        # STATED LIMIT (#507 phase 2, deliberate): a rename that ALSO flips `db_index` plans no index
        # action in this migration. `db_index` is outside the IR on purpose — `index_actions` owns
        # it, because on SQLite a non-empty delta means a rebuild that re-emits every live index —
        # and a renamed column never reaches the loop that reads it. The next `makemigrations` sees
        # the column on both sides and plans the CREATE/DROP INDEX normally, so this self-heals one
        # run later. The common case (an unchanged `db_index`) now correctly plans nothing at all,
        # where the old code dropped and re-created the index under a fresh hashed name.
        #
        # The SQLite rebuild receives the ACCUMULATED `column_renames`, so every renamed-but-surviving
        # column keeps its secondary indexes (#150) — and `_plan_column_change!` relocates the entry
        # to the end of the table's plan, so it executes after every RENAME. That closes what #150
        # documented as unsupported: two renames on one table now plan one correct rebuild, and a
        # rename co-occurring with a new column does too (whichever registers last, both relocate).
        #
        # What REMAINS a limitation, narrower than before: a co-occurring column ALTERATION on the
        # same table (a field present on both sides, handled by the loop in `_alter_table_fields`)
        # re-registers the same key with an EMPTY rename map, so a renamed column can still lose its
        # index to that. And `_add_new_field`'s own rebuild (#514, or a temporary default) carries no
        # rename map either. Both are index loss on a rare combination, not a broken plan — the
        # rebuild itself is correct in every ordering — and both are a #150 follow-up.
        # `old_name` is what makes the alteration correct rather than merely present: the live
        # catalog knows this column by its PRE-rename name, and four statements in
        # `Dialect.alter_field` can only learn a constraint's name by asking it. Found in review —
        # before this, a renamed column's UNIQUE / PRIMARY KEY / CHECK drop was silently omitted, and
        # a renamed `PositiveIntegerField` becoming a `TextField` emitted the retype with the stale
        # `>= 0` CHECK still in place, which PostgreSQL rejects.
        delta = column_delta(new_field, old_field, conn; name = field_name, old_name = old_field_name)
        # `delta.old_spec.name` IS `field_db_column(old_field, old_field_name)` — the pre-rename
        # physical column — so the rename map reads it off the same single source the constraint
        # lookups use rather than recomputing it.
        sqlite_rename_map[delta.old_spec.name] = field_name
        _plan_column_change!(conn, migration_plan, model_name, current_model, field_name,
                             new_field, old_field, delta,
                             _hash_field_name(model_name, field_name);
                             old_column = old_field_name,
                             column_renames = sqlite_rename_map)
        # Update model.fields to reflect rename to avoid double processing if needed
        model.fields[model_fields_map[old_field_name]] = model.fields[model_fields_map[old_field_name]] # effectively stays same but we can update key if we want to sync
        # remove the old field from colect_deletion
        filter!(x -> x != old_field_sym, colect_deletion)
      end
    end      
    filter!(x -> x != field_name_sym, colect_addition)
  end
  # #151: the PK loud-fail guard runs for ANY SQLite deletion on this table, and BEFORE the rename-rebuild
  # skip below — otherwise a #150 rename-rebuild co-scheduled in the same migration would skip the deletion
  # block and silently rebuild a PK-less rowid table from `current_model`. Deleting a primary-key column
  # that would leave the desired table with NO primary key is not auto-migratable on SQLite; fail loudly
  # rather than produce a rowid table (or a raw DROP COLUMN error). When the desired model still declares a
  # PK (the primary key moved to another column), the rebuild handles it normally.
  #
  # INTENTIONAL PG/SQLite DIVERGENCE: PostgreSQL's `ALTER TABLE DROP COLUMN` drops a primary-key column and
  # its constraint natively, so removing the sole PK succeeds there; SQLite has no such path, and this guard
  # makes it fail loudly instead of silently degrading the table to rowid. Removing the only primary key is
  # therefore rejected on SQLite but allowed on PostgreSQL — a deliberate, backend-capability-driven
  # difference (see the #151 Phase 4g test, which gates this case to SQLite).
  if conn isa PormGSQLite && !isempty(colect_deletion)
    desired_has_pk = any(f -> hasfield(typeof(f), :primary_key) && f.primary_key, values(current_model.fields))
    if !desired_has_pk
      for fsym in colect_deletion
        f = model.fields[model_fields_map[string(fsym)]]
        if hasfield(typeof(f), :primary_key) && f.primary_key
          throw(InvalidMigrationError("Cannot auto-migrate on SQLite: deleting primary-key column \"$(fsym)\" from table " *
                "\"$(model_name)\" would leave it with no primary key. Declare a replacement primary key, " *
                "or make this change manually."))
        end
      end
    end
  end
  # #150: a rename-with-FK-change may already have scheduled a full SQLite rebuild for this model (keyed
  # "Alter table: $model_name"). That rebuild is generated from `current_model`, which omits EVERY deleted
  # field, so it already drops this table's remaining deletions. Running the per-column deletion handling
  # below as well would emit `DROP COLUMN "<other>"` for a column the rebuild already removed ("no such
  # column"), so defer to the rebuild when it is present (SQLite only; PostgreSQL uses plain DROP COLUMN).
  sqlite_rename_rebuild = conn isa PormGSQLite && haskey(migration_plan, model_name) &&
    haskey(migration_plan[model_name], "Alter table: $model_name")
  if !isempty(colect_deletion) && !sqlite_rename_rebuild
    # #116/#151: SQLite refuses `ALTER TABLE DROP COLUMN` for an FK-with-constraint, a UNIQUE, or a PRIMARY
    # KEY column (and a UNIQUE column's `sqlite_autoindex_…` can't be pre-dropped), so deleting any of those
    # needs a full table rebuild. The rebuild is generated from `current_model` (which omits EVERY deleted
    # field), so ONE rebuild drops all of this table's deleted columns + their indexes at once — hence if ANY
    # deleted field forces a rebuild, route the WHOLE table's deletions through it and skip the per-column
    # DROP COLUMNs (emitting both would race: the rebuild removes the column, then a stray `DROP COLUMN` for a
    # sibling deletion fails "no such column"). `unique` is probed live, and STILL must be after #318 gave
    # SQLite introspection a `unique` flag: that flag is deliberately narrow (single-column UNIQUE constraints
    # only), whereas SQLite refuses DROP COLUMN for a column in ANY unique index — a composite-unique member
    # or a `CREATE UNIQUE INDEX` column included. `_sqlite_column_is_unique` answers that broader question;
    # `old_field.unique` does not. `primary_key` IS populated by introspection.
    #
    # #519 ADDS THE FOURTH DISJUNCT, and it deliberately overwrites what this comment used to promise:
    # *"Ordinary indexed columns still take the cheap DROP COLUMN path below (their plain index is
    # pre-dropped)."* They no longer do — an index of ANY kind referencing the column now routes the
    # deletion here, the way uniqueness already does. The cheap path's pre-drop could not carry the
    # promise:
    #
    #   * `get_constraints_index` cannot SEE an expression index (`pragma_index_info` reports `name = NULL`
    #     for an expression member) or a partial index's WHERE-clause column, so nothing was pre-dropped
    #     and SQLite refused the `DROP COLUMN` — #519 as filed;
    #   * and it returns `result[1, …]`, ONE name, so a column carrying two plain non-unique indexes got
    #     one of them pre-dropped and was refused for the other.
    #
    # Both are the same defect — the pre-drop has to be exhaustive to be safe, and it is not. The rebuild
    # already drops every index with the table and re-creates the ones the declared model still wants
    # (`_sqlite_rebuild_preserving_indexes` + `surviving_columns`), so routing here is correct for all of
    # them rather than for the subset the pre-drop happens to cover. It costs a data copy on a deletion
    # that used to be a metadata-only `DROP COLUMN`; the end state is identical either way, and an
    # end state that the database accepts beats a cheaper one it refuses.
    rebuild_delete_idx = nothing
    if conn isa PormGSQLite
      rebuild_delete_idx = findfirst(colect_deletion) do fsym
        fname = string(fsym)
        f = model.fields[model_fields_map[fname]]
        (hasfield(typeof(f), :to) && f.db_constraint) ||
          (hasfield(typeof(f), :primary_key) && f.primary_key) ||
          _sqlite_column_is_unique(conn, model_name, fname) ||
          !isempty(_sqlite_indexes_referencing_column(conn, model_name, fname))
      end
    end
    if rebuild_delete_idx !== nothing
      # `Dialect.rebuild_table` rather than `alter_field`: this is a rebuild with NO column diff at
      # all — the table is re-created precisely because `current_model` no longer has these columns.
      # It used to call `alter_field` with an empty `Symbol[]` plus, in this comment's own words, "a
      # representative deleted field … only to satisfy the shared signature". #507 phase 2 made that
      # spelling untenable rather than merely ugly: an empty `ColumnDelta` now MEANS "this column did
      # not change, plan nothing", so fabricating one here would say the opposite of what is meant.
      # `rebuild_table` is the same body and emits identical SQL, minus the three fake arguments.
      #
      # `surviving_columns` keeps the dropped columns' indexes off the preserved set (see
      # _sqlite_rebuild_preserving_indexes). The stable "Alter table:" key means a co-occurring
      # alteration/add-default collapses into this one idempotent recreation from the same desired model.
      _configure_order_dict_migration_plan(migration_plan, model_name, "Alter table: $model_name",
        _sqlite_rebuild_preserving_indexes(conn, model_table_name(current_model),
          Dialect.rebuild_table(conn, current_model);
          surviving_columns = _model_physical_columns(current_model)))
    else
      # PostgreSQL, or SQLite with no blocking column: plain DROP COLUMN works (the FK drop runs first on
      # PostgreSQL). Since #519 a SQLite column reaching here is referenced by no index at all, so the
      # `_drop_index` below is a no-op on this backend and the pre-drop is no longer what makes the
      # deletion legal — the fourth disjunct above is. It stays for PostgreSQL, where `get_constraints_index`
      # still names a droppable index and dropping it explicitly is harmless (PostgreSQL would drop it with
      # the column anyway).
      for field_name_sym in colect_deletion
        field_name = field_name_sym |> string
        old_field = model.fields[model_fields_map[field_name]]
        # `nothing` on the new side IS the deletion path: `_fk_constraint_action` reads it as "the
        # reference is going away" and answers `:drop`. The live column is compiled through the
        # fail-safe entry point on purpose — a field being deleted is often a foreign key whose
        # PARENT has just been removed from the models file too, which is the shape most likely to
        # make a compile fail, and aborting `makemigrations` there would be a regression against the
        # pre-phase-2 planner (which read two slots off the struct and compiled nothing). Degrading
        # keeps the DROP planned, and `get_constraints_fk` inside the helper is the authority on
        # whether a constraint is really there.
        _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name, nothing,
                                          _spec_or_degraded(old_field, conn, "<uncompilable:old>"; name = field_name))
        _drop_index(conn, migration_plan, model_name, field_name)
        _configure_order_dict_migration_plan(migration_plan, model_name, "Remove field: $field_name",
        Dialect.drop_field(conn, model_name, field_name))
      end
    end
  end
  # `_configure_order_dict_migration_plan` returns the created OrderedDict when it makes a fresh table
  # entry; the FK-rebuild branch above ends on that call, so return `nothing` explicitly to satisfy this
  # function's `::Nothing` contract (otherwise Julia tries to `convert(Nothing, OrderedDict)` and errors).
  return nothing
end

function _colect_numbered_fields(colect::Vector{Symbol})
  # Number the rename candidates in a deterministic (name-sorted) order so the prompt — and the index the
  # user answers with — is stable across runs regardless of the underlying set-iteration order. Sorting a
  # copy leaves the caller's `colect_deletion` untouched (it's still needed for the later `filter!`).
  colect = sort(colect, by = string)
  colect_numbered = Dict{Int64, Symbol}()
  for (index, field_name) in enumerate(colect)
    colect_numbered[index] = field_name
  end
  return colect_numbered, join([string(index, " - ", colect_numbered[index]) for index in sort(collect(keys(colect_numbered)))], ", ")
end
function _get_temporary_default_value(field::PormGField, settings::PormGSettings)
  if field |> typeof == Models.sDateTimeField
    return field.formatter(now(), settings.time_zone) |> field.formatter
  elseif field |> typeof == Models.sDateField
    return field.formatter(today())    
  else
    return nothing
  end
end


# ---
# Public API (makemigrations)
# ---

"""
    get_migration_plan(models, current_schema, conn, settings; interactive = true)

Diff the model definitions against the live database schema and return the DDL that would
reconcile them, as an `OrderedDict{Symbol, OrderedDict{String, String}}` — model name ⇒
ordered (human description ⇒ SQL statement). It only *computes* the plan; nothing is written
or executed. [`makemigrations`](@ref) is the entry point that drives it.

!!! warning "The two schema arguments read backwards"
    `models` is the **old** schema, reverse-engineered from the database. `current_schema` is
    the **new** state defined in your `models.jl`. The names predate the current terminology
    and are kept to avoid churning the planner's unit tests.

An empty `models` means an empty database, so every model becomes a `CREATE TABLE`.

With `interactive = true` (the default) a model with no matching table prompts whether it is
new or a rename of a table that disappeared, so a rename keeps its data. `interactive = false`
answers "new table" and "not a rename" for everything — a non-interactive run therefore
**never renames**, it drops and creates. Choosing a nonexistent option at the prompt raises
`InvalidMigrationError`.
"""
function get_migration_plan(models::Vector{PormGModel}, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, conn, settings::PormGSettings; interactive::Bool = true)
# models is olds models

migration_plan = OrderedDict{Symbol, OrderedDict{String, String}}()
futher_processing = Dict{Symbol, Dict{Symbol, Any}}()
current_schema = Models.synthesize_many_to_many_through_models(current_schema, settings)

# models is empty set all models to migration_plan
if isempty(models)
  for (model_name, model) in current_schema
    _add_new_table(conn, migration_plan, model_name, model[:model])
  end
  return migration_plan  
end

@pormg_debug false

for model in models # models is olds models
  # Resolved physical name (#59), symmetric with how `get_all_models` keys `current_schema`. A no-op
  # for genuinely-introspected models (they carry no db_table, so this is `model.name` — already the
  # exact live table name), but it keeps the two sides of the diff keyed the same way.
  model_name = Symbol(model_table_name(model))
  @pormg_debug false
  if haskey(current_schema, model_name)
    current_schema[model_name][:exist] = true
    _alter_table_fields(conn, migration_plan, model_name, model, current_schema, settings, interactive=interactive)
  else
    if !haskey(futher_processing, :drop_table)
      futher_processing[:drop_table] = Dict{Symbol, Any}(model_name => Dict{String, Any}("model" => model, "exist" => false))
    else
      futher_processing[:drop_table][model_name] = Dict{String, Any}("model" => model, "exist" => false)
    end
  end
end

@pormg_debug false

# Check for models in the current schema that are not in the models
for (model_name, model) in current_schema
  if model[:exist] == false
    if haskey(futher_processing, :drop_table) # TODO: i need test this
      
      response = "yes"
      if interactive
        print("The table $model_name is a new table? (yes/no): ")
        response = readline()
        response = strip(lowercase(response))
      end

      if response in ["yes", "y"]
        _add_new_table(conn, migration_plan, model_name, model[:model])
      elseif response in ["no", "n"]
        dict_rename = Dict{Int64, Symbol}()
        for (index, (m_name, m_info)) in enumerate(futher_processing[:drop_table])
          !m_info["exist"] && (dict_rename[index] = m_name )           
        end         
        if isempty(dict_rename)
          _add_new_table(conn, migration_plan, model_name, model[:model])
        else 
          list_to_question = join([string(index, " - ", dict_rename[index]) for index in keys(dict_rename)], ", ")
          
          response = "no"
          if interactive
            print("Please choice what is the older name from table $model_name: $list_to_question (choice a number) or type 'no': ")
            response = readline()
            response = strip(lowercase(response))
          end

          if response in ["no", "n"]
            _add_new_table(conn, migration_plan, model_name, model[:model])
          else
            # Only the input parse/lookup is guarded (mirrors the field-rename prompt above) — a
            # genuine planner failure below must propagate as itself, not as "invalid choice" (#197).
            local old_model_name
            try
              res_idx = parse(Int, response)
              old_model_name = dict_rename[res_idx]
            catch
              throw(InvalidMigrationError("Invalid choice \"$(response)\" — enter one of the listed option numbers; please try makemigrations again"))
            end
            # first i need to alter the fields from old table named in postgres
            _alter_table_fields(conn, migration_plan, old_model_name, futher_processing[:drop_table][old_model_name]["model"], current_schema, settings, interactive=interactive)
            _configure_order_dict_migration_plan(migration_plan, model_name, "Rename table", Dialect.rename_table(conn, model_name, old_model_name |> string))
            futher_processing[:drop_table][old_model_name]["exist"] = true
          end
        end         
      end    
    else 
      _add_new_table(conn, migration_plan, model_name, model[:model])    
    end
  end
 
end

@pormg_debug false

# at last check all models in futher_processing to drop
if haskey(futher_processing, :drop_table)
  for (model_name, model_info) in futher_processing[:drop_table]
    if model_info["exist"] == false
      _configure_order_dict_migration_plan(migration_plan, model_name, "Drop table", Dialect.drop_table(conn, model_name))
    end
  end
end

# println(migration_plan)


return migration_plan
end

"""
    makemigrations(db::String; interactive = true)
    makemigrations(connection, settings::PormGSettings; path = "db/models.jl", interactive = true)

Compare your `models.jl` against the live database and **write** the pending migration plan.
The first form is the one to call: `db` is a connection key from your configuration, e.g.
`makemigrations("db")`.

It does **not** touch the schema. The generated DDL lands in
`<db_def_folder>/migrations/pending_migrations.jl` for review; apply it with
`PormG.Migrations.migrate(db)`.

# Keyword arguments
- `path`: the models file. Defaults to `<db>/<settings.model_file>` in the `String` form.
- `interactive`: when `true`, a model with no matching table prompts whether it is a new
  table or a rename of one that disappeared — a rename preserves the data. `false` answers
  "new table" for everything and so **never renames**; use it in CI, not on real data.

Returns `nothing`. Logs and returns early — writing no plan — when the connection has
`change_db: false`. An up-to-date schema logs that no migrations are pending. A missing models
file raises `MissingConfigurationError`.

See also [`migrate`](@ref), [`get_migration_plan`](@ref), and the
[Database Migrations in PormG](@ref) guide.
"""
function makemigrations(connection::PormGPostgres, settings::PormGSettings; path::String = "db/models.jl", interactive::Bool = true)
if !settings.change_db
  @warn("Schema changes are disabled (`change_db: false`). Set `change_db: true` in your db/connection.yml under the active environment to allow migrations.")
  return
end
@pormg_debug false
models_array::Vector{PormGModel} = []
try
  models_array = convert_schema_to_models(connection)
catch e
  error_message = sprint(showerror, e)
  if occursin("Table definition not found", error_message)
    @info("The database is empty, that is migrate all tables") # TODO, impruve this message
  else
    println("Error: ", e)
    @error("Error: ", e)
    return
  end
end

# get module from the path (load + resolve FK targets + default pk_field — #62)
current_models = _load_current_models(path)

@pormg_debug false

migration_plan = get_migration_plan(models_array, current_models, connection, settings, interactive=interactive)

@pormg_debug false

# store migration_plan as pending_migrations.jl file
if migration_plan |> isempty
  @info(_emsg("\e[32mYour database schema is already up-to-date. No migrations are pending.\e[0m"))    
else     
  path = joinpath(settings.db_def_folder, "migrations")
  if !ispath(path)
    mkdir(path)
  end
  generate_migration_plan("pending_migrations.jl", migration_plan, path)
  @warn("The migration plan has been saved to '$(settings.db_def_folder)/migrations/pending_migrations.jl'. Review the plan before applying the migrations.")
  @info(_emsg("\e[32mMigration plan generated successfully. Run 'PormG.Migrations.migrate($( settings.db_def_folder == "db" ? "" : string("\"", settings.db_def_folder, "\"")))' to apply the migrations.\e[0m"))
end

end

function makemigrations(connection::PormGSQLite, settings::PormGSettings; path::String = "db/models.jl", interactive::Bool = true)
  if !settings.change_db
    @warn("Schema changes are disabled (`change_db: false`). Set `change_db: true` in your db/connection.yml under the active environment to allow migrations.")
    return
  end
  
  models_array::Vector{PormGModel} = []
  try
    models_array = convert_schema_to_models(connection)
  catch e
    @error("Error converting schema to models: ", e)
    return
  end

  # get module from the path (load + resolve FK targets + default pk_field — #62)
  current_models = _load_current_models(path)

  migration_plan = get_migration_plan(models_array, current_models, connection, settings, interactive=interactive)

  # store migration_plan as pending_migrations.jl file
  if migration_plan |> isempty
    @info(_emsg("\e[32mYour database schema is already up-to-date. No migrations are pending.\e[0m"))    
  else     
    path = joinpath(settings.db_def_folder, "migrations")
    if !ispath(path)
      mkdir(path)
    end
    generate_migration_plan("pending_migrations.jl", migration_plan, path)
    @warn("The migration plan has been saved to '$(settings.db_def_folder)/migrations/pending_migrations.jl'. Review the plan before applying the migrations.")
    @info(_emsg("\e[32mMigration plan generated successfully. Run 'PormG.Migrations.migrate($( settings.db_def_folder == "db" ? "" : string("\"", settings.db_def_folder, "\"")))' to apply the migrations.\e[0m"))
  end
end

function makemigrations(db::String; config::Dict{String,PormGSettings} = config, interactive::Bool = true)
settings = Configuration.get_settings(db)
path = joinpath(db, settings.model_file)
isfile(path) || throw(MissingConfigurationError("The models file $(path) does not exist for connection '$(db)'."))
makemigrations(settings.connections, settings, path=path, interactive=interactive)
end

function get_all_models(mod::Module)::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}
# Get all models from a module
models = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()
for name in names(mod, all = true)
  if isdefined(mod, name)
    obj = getfield(mod, name)
    if isa(obj, PormGModel)
      if obj.name == ""
        obj.name = name |> string |> format_model_name
      end
      # Key by the RESOLVED PHYSICAL table name (#59): `db_table` when the model sets one, else the
      # (now-filled) `obj.name`. The old key was the lowercased Julia BINDING name, which only ever
      # agreed with the physical name by convention — a `db_table` model would key as `:driver_races`
      # (binding) while its live table is `Driver_Races`, so the diff below would find no match and
      # drop+recreate a live table that had not structurally changed. Keying both sides on
      # `model_table_name` also retires the long-standing "lowercase model.name everywhere" TODO that
      # sat on this line: the identity is now the resolved name, not an ad hoc fold of the binding.
      models[Symbol(model_table_name(obj))] = Dict{Symbol, Union{Bool, PormGModel}}(:model => obj, :exist => false)
    end
  end
end
return models
end

# #62/#65: Shared makemigrations prelude — load the code models for a schema diff, then
# resolve string FK/O2O targets to model objects and default `pk_field`. The planner
# loads models into a throwaway module via `Base.include` and never runs `set_models`
# (deliberately, to keep diffing free of `set_models`' global side effects), so the
# resolution `set_models` does at runtime must be reproduced here — otherwise a
# string-declared FK, or any FK with an omitted `pk_field`, would not honor a referenced
# parent's `db_column` in the generated DDL. #65: that resolution is now single-sourced —
# both this prelude and `set_models` call `Models.resolve_fk_target!`, so the two load
# lifecycles can no longer drift. Both backends call this.
function _load_current_models(path::String)::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}
  temp_module = Module(:TemporaryModels)
  Base.include(temp_module, path)
  models_module = Base.invokelatest(getfield, temp_module, :models)
  current_models = Base.invokelatest(get_all_models, models_module)
  Base.invokelatest(_resolve_fk_targets_and_pk!, current_models, models_module)
  return current_models
end

# Resolve each code model's FK/O2O targets against `models_module` (write-back) and default a
# missing `pk_field`, by delegating each field to the shared `Models.resolve_fk_target!` (#65).
# Best-effort (strict=false): an unresolvable string target is left as-is with a `@debug` rather
# than aborting the whole load, so a diff can still be computed for every OTHER model in the file.
# The runtime path's strict throw lives in `set_models`, so typos surface loudly there first.
#
# #388 changed what "left as-is" costs. This comment used to justify the tolerance by saying the
# unresolved string's "verbatim fallback is already correct" and that it "never breaks the run" —
# both are now false. There is no fallback: `fk_target_table` refuses an unresolved target, because
# `.to` is a Julia BINDING and the lowercase that used to stand in for a table name was only ever
# right by accident. So the run does break, deliberately, at the point where the parent would have
# been rendered into a `REFERENCES` clause.
#
# What is NOT a reason to defer: making the failure narrower. It is not narrower — `makemigrations`
# puts no `try` around `get_migration_plan` (the guarded call in both arms is `convert_schema_to_models`),
# so the throw aborts the whole run exactly as a `strict=true` throw here would. The reason to defer
# is the one above: most models never reach a `REFERENCES` clause at all, so an unresolved target on a
# model with no pending DDL costs nothing, and the diff for every other model still gets computed.
function _resolve_fk_targets_and_pk!(current_models::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, models_module::Module)::Nothing
  for (_, entry) in current_models
    model = entry[:model]
    model isa PormGModel || continue
    for (field_name, field) in pairs(model.fields)
      field isa Models.sRelationalColumn || continue
      # #65: delegate to the single shared resolver. Best-effort (strict=false): an unresolvable
      # string target is left as-is with a @debug (its verbatim db-column fallback stays correct),
      # and the pk_field default is skipped — identical to the pre-#65 migration behavior.
      Models.resolve_fk_target!(field, string(field_name), model.name, models_module; strict=false)
    end
  end
  return nothing
end
