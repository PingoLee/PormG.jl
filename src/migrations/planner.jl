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
# No-op for PostgreSQL (real ALTER COLUMN, no rebuild) or an empty block. The check is SCOPED to the
# rebuilt table (not the whole DB) so an unrelated pre-existing orphan elsewhere can't fail this
# migration; the rename preserves the table name + PKs, so children of this table stay valid and need no
# check.
#
# `catalog_table` (#615) is the name the index snapshot asks `sqlite_master` for, which differs from
# `table_name` only for a table being RENAMED in the same migration: the rename runs first, so the
# rebuild and its `foreign_key_check` name the new table, while at plan time the catalog still holds
# the old one. The snapshotted DDL then says `ON "<old>"`, so it is re-targeted at `table_name`.
#
# `before` and `after` (#729) carry the rest of SQLite's twelve-step procedure: the views and foreign
# triggers that would fail the rebuild's RENAME are dropped first, and they and the table's own
# triggers are re-created after the indexes, before the foreign-key gate. Its only caller is
# `_finalize_sqlite_rebuilds!`, which works both lists out once the whole plan is known.
function _sqlite_rebuild_preserving_indexes(conn, table_name::String, rebuild_sql::AbstractString;
                                            surviving_columns::Union{Nothing,Set{String}} = nothing,
                                            column_renames::Dict{String,String} = Dict{String,String}(),
                                            catalog_table::String = table_name,
                                            before::Vector{String} = String[],
                                            after::Vector{String} = String[])::String
  (!(conn isa PormGSQLite) || isempty(rebuild_sql)) && return String(rebuild_sql)
  # #116: when the rebuild removes columns (FK-field deletion), pass the rebuilt table's columns so an
  # index on a just-dropped column isn't re-created ("no such column"). `nothing` (the default) preserves
  # every live index, i.e. the pre-#116 behavior for pure alterations where no column disappears.
  # #150: `column_renames` (old ⇒ new physical name) maps a renamed column so its live index survives the
  # filter and is re-created under the new name; empty (the default) for every non-rename rebuild.
  idx_ddls = get_secondary_index_ddls(conn, catalog_table; surviving_columns = surviving_columns, column_renames = column_renames,
                                      rename_table_to = catalog_table == table_name ? nothing : table_name)
  safe_tbl = replace(table_name, "\"" => "\"\"")
  return join(String[before; String(rebuild_sql); idx_ddls; after; "PRAGMA foreign_key_check(\"$(safe_tbl)\");"], "\n")
end

"""
    _finalize_sqlite_rebuilds!(conn, migration_plan, current_schema, rebuild_context;
                               live, table_renames, dropped_tables) -> Nothing

Render every SQLite table rebuild in the plan, ONCE, after the whole plan is known (#729).

The producers of a table's `"Alter table: <model>"` step register the bare `Dialect.rebuild_table`
SQL and nothing else. This pass wraps each one with what the rebuild would otherwise lose: the
secondary indexes (#82), the triggers ON the table, and the views and foreign triggers that name it
and would fail its RENAME. It runs last for three reasons, each of which a per-registration render
got wrong:

  * **The rename map is complete only now.** `_resolve_table_fields` fills it inside the new-column
    loop, so a rebuild registered by `_add_new_field` for an earlier column rendered without a rename
    answered later — and a pure rename registers no rebuild of its own to repair it (#556's gap).
  * **Staleness is migration-wide.** `migrate` runs the rename buckets before any rebuild, and the
    rebuilds of different tables in binding-name order, so whether a snapshotted view is still right
    depends on every table's renames and drops, not only its own.
  * **Each object is re-created from one text.** A view that names two rebuilt tables is dropped and
    re-created by both blocks; computing its statement once (see `_sqlite_recreated_ddl`) makes the
    order they run in irrelevant.

`rebuild_context` maps each table `_alter_table_fields` diffed to `(catalog name, rename map)`; the
map is the same object the producers filled. Every producer runs inside `_alter_table_fields`, so
every step has an entry; one that does not is still rendered — under its own name, with no renames —
because a step left bare would drop the table's indexes and skip the foreign-key gate in silence.
PostgreSQL has no rebuild, so this returns at once.

Raises `InvalidMigrationError` — at plan time, so `makemigrations` writes no plan — when a trigger or
view would be re-created stale; see `_sqlite_recreated_ddl` for exactly when. Logs one warning per
rebuilt table that carries clauses the rebuild drops because no model can declare them
(`_sqlite_unmodellable_table_clauses`).
"""
function _finalize_sqlite_rebuilds!(conn, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                                    current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}},
                                    rebuild_context::Dict{Symbol, Tuple{Symbol, Dict{String, String}}};
                                    live::Vector{LiveTable} = LiveTable[],
                                    table_renames::Dict{String, String} = Dict{String, String}(),
                                    dropped_tables::Set{String} = Set{String}())::Nothing
  conn isa PormGSQLite || return nothing
  rebuilt = Symbol[t for (t, steps) in migration_plan if haskey(steps, "Alter table: $t")]
  isempty(rebuilt) && return nothing
  for t in rebuilt
    haskey(rebuild_context, t) || (rebuild_context[t] = (t, Dict{String, String}()))
  end
  objects = _sqlite_schema_objects(conn)
  # No view or trigger anywhere: nothing to carry, so no further catalog reads.
  ctx = isempty(objects) ? nothing :
        _sqlite_recreate_context(conn, rebuilt, current_schema, rebuild_context, objects;
                                 live = live, table_renames = table_renames, dropped_tables = dropped_tables)
  # rowid ⇒ the object's one re-create statement. Not keyed by name: a trigger and a view may share one.
  recreated = Dict{Int, String}()
  for t in rebuilt
    key = "Alter table: $t"
    catalog, renames = rebuild_context[t]
    model = current_schema[t][:model]
    before, after = String[], String[]
    if ctx !== nothing
      on_table, dependents = _sqlite_rebuild_dependents(objects, string(catalog);
                                                        dropped_tables = ctx.dropped_tables)
      before = String[_sqlite_drop_object_sql(o) for o in Iterators.reverse(dependents)]
      after = String[get!(() -> _sqlite_recreated_ddl(o, ctx; rebuilt_table = string(t)), recreated, o.rowid)
                     for o in sort!(vcat(on_table, dependents); by = o -> o.rowid)]
    end
    # What the rebuild re-renders away because no model declaration can hold it — a hand-written
    # CHECK, a COLLATE, a composite or DEFERRABLE key, STRICT… Said once per table, since this pass
    # renders each rebuild exactly once. Structured kwargs and no `maxlog`, like the #519 index
    # warning: the call site is bounded by the number of rebuilt tables.
    clauses = _sqlite_unmodellable_table_clauses(conn, string(catalog);
                declared_checks = Set{String}(c.name for c in Models.declared_check_constraints(model)))
    isempty(clauses) ||
      @warn "SQLite table rebuild will DROP clauses no model declaration can express: the table is " *
            "re-created from its model, which cannot hold them. Re-create them by hand after the " *
            "migration if you still need them." table = string(t) clauses = clauses
    # In place: an existing key keeps its position, which the producers chose (after every ADD and
    # RENAME COLUMN on the table).
    migration_plan[t][key] = _sqlite_rebuild_preserving_indexes(conn, string(model_table_name(model)),
      migration_plan[t][key];
      surviving_columns = _model_physical_columns(model),
      column_renames = renames,
      catalog_table = string(catalog),
      before = before, after = after)
  end
  return nothing
end

# The `_SQLiteRecreateContext` for this plan: everything in it that can make a snapshotted view or
# trigger stale. Case-only renames are dropped — SQLite resolves names case-insensitively, so they
# change nothing a definition says.
function _sqlite_recreate_context(conn::PormGSQLite, rebuilt::Vector{Symbol},
                                  current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}},
                                  rebuild_context::Dict{Symbol, Tuple{Symbol, Dict{String, String}}},
                                  objects::Vector{_SQLiteSchemaObject};
                                  live::Vector{LiveTable}, table_renames::Dict{String, String},
                                  dropped_tables::Set{String})::_SQLiteRecreateContext
  table_moves = Dict{String, String}(lowercase(old) => new for (old, new) in table_renames
                                     if lowercase(old) != lowercase(new))
  column_moves = Dict{String, Dict{String, String}}()
  for (_, (catalog, renames)) in rebuild_context
    moves = Dict{String, String}(lowercase(old) => new for (old, new) in renames
                                 if lowercase(old) != lowercase(new))
    isempty(moves) || (column_moves[lowercase(string(catalog))] = moves)
  end
  # What each rebuild removes: every live column (generated ones included — `table_xinfo`) whose
  # post-rename name the declared model no longer has.
  dropped_columns = Dict{String, Set{String}}()
  for t in rebuilt
    catalog, renames = rebuild_context[t]
    declared = Set{String}(lowercase(c) for c in _model_physical_columns(current_schema[t][:model]))
    renamed_to = Dict{String, String}(lowercase(old) => new for (old, new) in renames)
    gone = Set{String}(lowercase(c) for c in _sqlite_table_xinfo_columns(conn, string(catalog))
                       if !(lowercase(get(renamed_to, lowercase(c), c)) in declared))
    isempty(gone) || (dropped_columns[lowercase(string(catalog))] = gone)
  end
  live_tables = Set{String}(lowercase(t.name) for t in live)
  return _SQLiteRecreateContext(table_moves, column_moves, dropped_columns,
                                Set{String}(lowercase(t) for t in dropped_tables),
                                live_tables, _sqlite_view_tables(objects, live_tables))
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

function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_spec::Union{ColumnSpec, Nothing}, old_spec::ColumnSpec; catalog_table::Symbol = model_name)::Nothing
  # #498: the precondition is `_fk_constraint_action`, not a locally-spelled XOR. Both `:drop` (the
  # constraint is going away) and `:repoint` (it stays, but must be re-issued against a new
  # definition) need the live one dropped first. Deriving it rather than accepting it as an argument
  # keeps a caller from passing an action that disagrees with the specs it also passes.
  #
  # `field_name` is the column to look the LIVE constraint up by, which on a rename is the PRE-rename
  # name: nothing has run yet when the plan is built, so the catalog still knows the old column.
  # `catalog_table` is the same rule for the TABLE (#615): on a table rename the lookup asks for the
  # old name, while the DROP names `model_name` — it executes after the rename.
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
    
    constraint_name = get_constraints_fk(conn, catalog_table, field_name)
    if constraint_name === nothing
      return nothing
    end
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove foreign key: $field_name", 
    Dialect.drop_foreign_key(conn, model_name, constraint_name))
  end
  return nothing
end
function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol, new_spec::Union{ColumnSpec, Nothing}, old_spec::ColumnSpec; catalog_table::Symbol = model_name)
  _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name |> string, new_spec, old_spec; catalog_table = catalog_table)
end

function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String; index_name::Union{String, Nothing} = nothing, catalog_table::Symbol = model_name)::Nothing
  if index_name === nothing
    # By `catalog_table`, the table's name as the catalog holds it at plan time (#615).
    index_name = get_constraints_index(conn, catalog_table, field_name)
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
function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol; index_name::Union{String, Nothing} = nothing, catalog_table::Symbol = model_name)
  _drop_index(conn, migration_plan, model_name, field_name |> string, index_name=index_name, catalog_table=catalog_table)
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

# ── Model-level composite indexes: one emitter for creation and the diff (#19, #347, #161) ─────────
#
# `UniqueConstraint`, `Index` and the synthesized ManyToManyField join-table index used to be
# materialized ONLY when their table was first created — three add-only emitters called from
# `_add_new_table`, so adding, removing or changing one on an existing table planned nothing, and
# nothing read composite uniqueness back to notice. `_plan_composite_actions!` replaced all three:
# `_add_new_table` hands it an empty live side, `_alter_table_fields` hands it the table's
# `LiveTable.composites`, and one body decides for both.

"""
    _catalog_index_name(conn, name) -> String

`name` as the catalog will store it. PostgreSQL truncates an identifier to 63 bytes
(`NAMEDATALEN - 1`) on a character boundary and says so only in a `NOTICE`; SQLite stores it as
written. Every comparison between a declared name and a live one goes through here, or a long
explicit name would read as renamed on every run and be re-planned forever.
"""
_catalog_index_name(::PormGSQLite, name::String)::String = name
function _catalog_index_name(::PormGPostgres, name::String)::String
  ncodeunits(name) <= 63 && return name
  out = IOBuffer()
  n = 0
  for c in name
    n + ncodeunits(c) > 63 && break
    print(out, c)
    n += ncodeunits(c)
  end
  return String(take!(out))
end

# The key a model-level index name is unique under, as the catalog will store it: PostgreSQL's
# 63-byte truncation, and SQLite's case-insensitive identifiers (PormG quotes every name, so
# PostgreSQL compares exactly). Every name comparison in the composite path goes through here.
_composite_name_key(conn::Union{PormGPostgres, PormGSQLite}, name::String)::String =
  conn isa PormGSQLite ? lowercase(_catalog_index_name(conn, name)) : _catalog_index_name(conn, name)

"""
    _claim_composite_target!(conn, targets, name, table; auto = false) -> Nothing

The plan-level name registry for model-level indexes (#161): every name this plan will CREATE, or
RENAME an index TO, on any table, keyed as the catalog stores it (`_composite_name_key`).

Per PLAN, not per table, because that is the scope the database enforces: an index name is unique
per schema on PostgreSQL (shared with tables and sequences) and per database on SQLite, and the
per-table registry `_add_new_table` used to keep saw only one table. **Only a target is claimed.** A
declaration the live schema already satisfies creates nothing and cannot collide with anything;
checking every DECLARED name instead refused schemas that plan fine — two long derived names from a
Django `unique_together` that share their first 63 bytes, both already present under Django's own
names, made the whole app unplannable, with an error no `name=` could answer for a join table.

Raises `InvalidMigrationError` on a second claim of one key, and on SQLite on a `sqlite_` name,
which SQLite reserves and refuses to create. Warns on a PostgreSQL name longer than 63 bytes — it is
stored truncated, and every comparison already accounts for that — except for the synthesized
join-table index, which has no `name=` to shorten.
"""
function _claim_composite_target!(conn::Union{PormGPostgres, PormGSQLite},
                                  targets::Dict{String, Tuple{String, String}},
                                  name::String, table::String; auto::Bool = false)::Nothing
  if conn isa PormGSQLite && startswith(lowercase(name), "sqlite_")
    throw(InvalidMigrationError(
      "Index name '$(name)' on table '$(table)' starts with 'sqlite_', which SQLite reserves for its " *
      "own objects; give the UniqueConstraint or Index another name"))
  end
  stored = _catalog_index_name(conn, name)
  stored == name || auto || @warn "makemigrations: an index name exceeds PostgreSQL's 63-byte identifier limit and is stored truncated; consider a shorter explicit `name=`" table = table name = name stored = stored
  key = _composite_name_key(conn, name)
  if haskey(targets, key)
    throw(InvalidMigrationError(
      "Duplicate index name '$(stored)' (tables '$(targets[key][2])' and '$(table)'); index names are " *
      "unique per schema on PostgreSQL and per database on SQLite, so give each UniqueConstraint and " *
      "Index a distinct name"))
  end
  targets[key] = (stored, table)
  return nothing
end

"""
    _check_composite_targets_free(conn, targets, live, gone, table_renames) -> Nothing

The half of the name registry that needs the whole plan (#161): a name this plan creates, or renames
an index to, must not be held by a live composite on ANOTHER table.

Refused at plan time rather than left to the database because the order is not the plan's to
promise: every composite DROP, RENAME and unique CREATE shares one `_order_statements` bucket in
table order, so whether table B's `DROP INDEX "n"` runs before table A's `CREATE … "n"` depends on
which table was diffed first. Moving a name between tables therefore takes two migrations — free it,
then claim it — and this says so instead of failing mid-migration on some orders and not others.
A table the plan drops entirely is exempt: `Drop table` runs before every index statement. The same
table is exempt too: its own pass orders the drop before the create.
"""
function _check_composite_targets_free(conn::Union{PormGPostgres, PormGSQLite},
                                       targets::Dict{String, Tuple{String, String}},
                                       live::Vector{LiveTable}, gone::Set{String},
                                       table_renames::Dict{String, String})::Nothing
  isempty(targets) && return nothing
  for t in live
    t.name in gone && continue
    table = get(table_renames, t.name, t.name)
    for lc in t.composites
      key = _composite_name_key(conn, lc.name)
      haskey(targets, key) || continue
      stored, target_table = targets[key]
      target_table == table && continue
      throw(InvalidMigrationError(
        "Index name '$(stored)' for table '$(target_table)' is already held by an index on table " *
        "'$(table)'. Index names are unique per schema on PostgreSQL and per database on SQLite: give " *
        "the UniqueConstraint or Index another name, or free the name in a separate migration first"))
    end
  end
  return nothing
end

"""
    _refuse_dropped_table_dependents(conn, dropped_tables) -> Nothing

Raise `InvalidMigrationError` — at plan time, so `makemigrations` writes no plan — when a view or a
trigger still reads a table the plan drops (#754). Every offender across every dropped table goes
into the one error, so a single pass of hand-written `DROP VIEW`s clears it.

PormG manages neither views nor triggers, so it refuses rather than drop them, like #729's rebuild
refusals. Without it each engine lost the object a different way:

  * **PostgreSQL** — `Dialect.drop_table` is `DROP TABLE … CASCADE` and stays so for the foreign
    keys (#89), which silently took every dependent view with the table. After this check `CASCADE`
    removes only foreign keys, barring an object created between `makemigrations` and `migrate`.
    What is found is [`_pg_drop_table_dependents`](@ref).
  * **SQLite** — the objects stayed, dangling, and the next `ALTER TABLE … RENAME` anywhere in the
    database failed on the missing table — the end of every later table rebuild.
    What is found is [`_sqlite_drop_table_dependents`](@ref).
"""
function _refuse_dropped_table_dependents(conn::PormGPostgres, dropped_tables::Set{String})::Nothing
  isempty(dropped_tables) && return nothing
  found = _pg_drop_table_dependents(conn, sort!(collect(dropped_tables)))
  isempty(found) && return nothing
  _throw_dropped_table_dependents(found,
    "PostgreSQL drops a table with CASCADE, which would remove them too without the plan saying so")
end

function _refuse_dropped_table_dependents(conn::PormGSQLite, dropped_tables::Set{String})::Nothing
  isempty(dropped_tables) && return nothing
  objects = _sqlite_schema_objects(conn)
  isempty(objects) && return nothing
  found = _sqlite_drop_table_dependents(objects, dropped_tables)
  isempty(found) && return nothing
  described = Tuple{String, String}[
    (t, o.type == "trigger" ? "trigger \"$(o.name)\" on \"$(o.tbl_name)\"" : "$(o.type) \"$(o.name)\"")
    for (t, o) in found]
  _throw_dropped_table_dependents(described,
    "SQLite would keep them naming a missing table, and every later ALTER TABLE … RENAME in the " *
    "database — every table rebuild ends in one — would then fail")
end

# `found` holds one `(dropped table, object)` pair per table an object reads, so an object reading two
# dropped tables arrives twice; it is listed once, naming both, and both head the message.
function _throw_dropped_table_dependents(found::Vector{Tuple{String, String}}, consequence::AbstractString)
  tables = unique(first.(found))
  reads = OrderedDict{String, Vector{String}}()
  for (t, dep) in found
    t in get!(reads, dep, String[]) || push!(reads[dep], t)
  end
  one = length(tables) == 1
  it = one ? "it" : "them"
  quoted(ts) = join(("\"$t\"" for t in ts), ", ")
  listed = join(("  - $(dep) reads $(quoted(ts))" for (dep, ts) in reads), "\n")
  throw(InvalidMigrationError(
    "Cannot drop $(one ? "table" : "tables") $(quoted(tables)): this migration drops $(it) because no " *
    "model declares $(it) any more, but other objects still read $(it):\n$(listed)\n" *
    "PormG manages tables, not the views, triggers and other objects built on them, so it will not " *
    "drop them for you: $(consequence). Drop them yourself before running makemigrations (re-create " *
    "them against the new schema afterwards if you still need them), or keep the $(one ? "model" : "models"). " *
    "If a model was renamed rather than deleted, run makemigrations interactively and answer its " *
    "rename question: a rename on its own keeps them. (On SQLite, a rename in the same migration as " *
    "a table rebuild is refused when a view or trigger the rebuild carries names the renamed table; " *
    "apply the rename as a migration of its own first.)"))
end

"""
    _plan_composite_actions!(conn, migration_plan, model_name, model, live; column_renames, catalog_table) -> Set{String}

Plan every model-level index statement for one table: the declared composites of `model` against
the `live` ones, as [`LiveComposite`](@ref)s. Returns the names of the live indexes it drops, which
the `db_index` flush in `_alter_table_fields` needs (see there).

**Identity is the index's shape, never the name** ([`composite_shape_matches`](@ref)): unique or
not, the ordered physical columns and — since #29 — the access method, each member's direction and
each member's operator class. A declared composite matches a live one of the same shape, whatever
either is called and whichever backing the live one has — so a Django-adopted `UNIQUE (a, b)`
satisfies a declared `UniqueConstraint` rather than being duplicated by a second index. Then, in this
order:

  * **Drop** every readable live composite nothing declares that PormG owns
    ([`composite_is_owned`](@ref)). State-based for a plain composite, like the single-column
    `db_index` path: the models file is the schema. An ADVANCED one (#29) is dropped only when it
    carries the `pormg:index` marker; a hand-made GIN index is kept, and its name is then refused to
    any create or rename on the table, which would otherwise fail with "already exists". A bare index
    is `DROP INDEX`; a constraint-backed one is `ALTER TABLE … DROP CONSTRAINT` on PostgreSQL
    (`DROP INDEX` on an index a constraint owns is refused) and a table rebuild on SQLite (an
    autoindex cannot be dropped at all). An index the readers refuse — a unique `INCLUDE` one, an
    extension's method, … — never reaches `live`, so it is never dropped. A functional or partial
    index is advanced (#29 part 2): it is PormG's only under the hashed marker of its text; so is a
    covering one (#934), under the bare marker.
  * **Adopt** a match that is advanced and carries no marker: on PostgreSQL a `COMMENT ON INDEX`
    appends the marker to whatever comment the index has, and from then on it is PormG's — for a
    text-holding index the hash of the DECLARED text, which is what every later plan compares. On SQLite
    nothing — an index cannot be commented there, and a drop and re-create would make the first plan
    after `inspectdb` destructive — so an adopted SQLite index stays unowned until something re-creates
    it (an explicit rename does).
  * **Rename** a match whose declaration spells a `name=` the live index does not carry: `ALTER INDEX`
    / `RENAME CONSTRAINT` on PostgreSQL, drop-and-create for a bare SQLite index. A DERIVED name is
    not intent — a table renamed under #615 keeps its `<old>_a_b_uniq` — and SQLite's
    `sqlite_autoindex_*` has no name of its own to change, so neither renames.
  * **Create** every declaration nothing matched, without `IF NOT EXISTS` (see
    `Dialect.create_index`) — the join-table index included, now that it is diffed on every run.

Every create and rename target is claimed in the plan-level registry (`_claim_composite_target!`).
And a live index whose name some declaration EXPLICITLY writes is kept only by that declaration:
otherwise a nameless declaration matching its columns would keep it, and the rename or create that
needs the name would fail with "already exists" on every run.

Drops are planned before creates because a changed column set under a REUSED explicit name is a drop
and a create of one name; `_order_statements` keeps them in plan order (both in its fifth bucket), and
a non-unique create lands in the last bucket regardless.

**Live columns first go through `column_renames`** (live ⇒ declared; filled on both engines), so a
composite over a renamed column matches its declaration — `RENAME COLUMN` carries the index. A live
composite over a column the declared model no longer has is SKIPPED, not dropped: PostgreSQL's
`DROP COLUMN` takes the index or constraint with it, and the SQLite rebuild's `surviving_columns`
filters it, so a planned drop would name something that no longer exists by the time it ran.

**The SQLite rebuild is decided before anything is emitted.** A rebuild re-creates every live bare
index from its plan-time snapshot and none of the table-level `UNIQUE` clauses (`rebuild_table`
renders none). So when one is registered for this table — by a column change earlier, or here, to
remove an undeclared clause — every constraint-backed composite counts as gone: an undeclared one
needs no statement, and a declared one is re-created as a `CREATE UNIQUE INDEX` after the rebuild.
Deciding it first is what keeps a table with one undeclared and one declared `UNIQUE (…)` from
losing the declared one. Registering it here makes this the FIFTH producer of the
`"Alter table: <model>"` key. Like the others it registers the bare rebuild, and
[`_finalize_sqlite_rebuilds!`](@ref) renders the snapshot around it once the plan is complete (#729).
"""
function _plan_composite_actions!(conn::Union{PormGPostgres, PormGSQLite},
                                  migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                                  model_name::Symbol, model::PormGModel,
                                  live_composites::Vector{LiveComposite};
                                  column_renames::Dict{String, String} = Dict{String, String}(),
                                  catalog_table::Symbol = model_name,
                                  targets::Dict{String, Tuple{String, String}} = Dict{String, Tuple{String, String}}(),
                                  # #830: the table's live columns, and the lossy-ALTER sink a new
                                  # `UniqueConstraint` records into. `nothing` for a table this plan
                                  # creates — it is empty, so nothing can fail.
                                  live_columns = nothing,
                                  lossy_alters::Vector{LossyAlter} = LossyAlter[],
                                  # #934: the live columns this plan retypes, which a partial
                                  # UniqueConstraint's condition cannot be counted over.
                                  retyped::Set{String} = Set{String}())::Set{String}
  declared = declared_composites(model)
  table = String(model_table_name(model))
  declared_cols = _model_physical_columns(model)

  # The live side in the declared model's terms: renamed columns mapped, composites over a column
  # that is going away skipped (the docstring says why that is not a drop).
  # #934: a covering index's payload columns are mapped and checked the same way — PostgreSQL's
  # `DROP COLUMN` takes the index with an INCLUDE column as well.
  live = Tuple{LiveComposite, Vector{String}, Vector{String}}[]
  for lc in live_composites
    cols = String[get(column_renames, c, c) for c in lc.columns]
    inc = String[get(column_renames, c, c) for c in lc.include]
    all(c -> c in declared_cols, cols) && all(c -> c in declared_cols, inc) && push!(live, (lc, cols, inc))
  end

  # Match declared ⇒ live by kind and columns. Two passes, so that when the live side carries two
  # identical indexes the one the declaration NAMES is the one kept, and the other is the drop. The
  # second pass never hands a declaration a live index whose name another declaration WRITES — that
  # index is dropped instead, so the name is free by the time its claimant renames or creates it.
  samename(a, b) = _composite_name_key(conn, a) == _composite_name_key(conn, b)
  claimed = Set{String}(_composite_name_key(conn, d.name) for d in declared if d.explicit)
  matched = Vector{Union{Int, Nothing}}(nothing, length(declared))
  taken = falses(length(live))
  for by_name in (true, false), (i, d) in enumerate(declared)
    matched[i] === nothing || continue
    j = findfirst(eachindex(live)) do j
      !taken[j] && composite_shape_matches(live[j][1], d; columns = live[j][2], include = live[j][3]) &&
        (by_name ? samename(live[j][1].name, d.name) :
                   !(_composite_name_key(conn, live[j][1].name) in claimed))
    end
    j === nothing && continue
    matched[i] = j
    taken[j] = true
  end

  # SQLite: the rebuild decision comes first (see the docstring).
  rebuild_key = "Alter table: $model_name"
  rebuilding = false
  if conn isa PormGSQLite
    if any(j -> !taken[j] && live[j][1].constraint, eachindex(live)) &&
       !(haskey(migration_plan, model_name) && haskey(migration_plan[model_name], rebuild_key))
      _configure_order_dict_migration_plan(migration_plan, model_name, rebuild_key,
                                           Dialect.rebuild_table(conn, model))
    end
    rebuilding = haskey(migration_plan, model_name) && haskey(migration_plan[model_name], rebuild_key)
  end

  drops = LiveComposite[]
  renames = Tuple{LiveComposite, DeclaredComposite}[]
  creates = DeclaredComposite[]
  adopts = Tuple{LiveComposite, DeclaredComposite}[]
  for (i, d) in enumerate(declared)
    j = matched[i]
    if j === nothing
      push!(creates, d)
      # #830: a UniqueConstraint the table does not have yet fails on duplicate tuples already there.
      # Counted under the catalog's column names — a member renamed by this plan under its old one, a
      # member it adds under none (then there is no finding: the column cannot be counted).
      # #934: a partial one counts only the rows its condition matches — when every column the
      # condition names can be counted now (`_sql_text_countable`, the CHECK rule); a functional one
      # has no columns to group by, so no finding, and the database checks it when the plan runs.
      if d.unique && !d.auto && live_columns !== nothing && isempty(d.expressions) &&
         (d.condition === nothing || _sql_text_countable(d.condition, model, live_columns, retyped))
        live_name(c) = something(findfirst(==(c), column_renames),
                                 c in live_columns ? c : nothing, Some(nothing))
        append!(lossy_alters, _lossy_composite_unique(String(catalog_table), d.name,
                                                      Union{String, Nothing}[live_name(c) for c in d.columns];
                                                      condition = d.condition))
      end
      continue
    end
    lc = live[j][1]
    if rebuilding && lc.constraint
      push!(creates, d)                              # the rebuild takes it; put it back as an index
    elseif d.explicit && !d.auto && !samename(lc.name, d.name) &&
           !(conn isa PormGSQLite && lc.constraint)  # an autoindex has no name of its own to change
      push!(renames, (lc, d))
    end
    # #29: a hand-made advanced index the declaration matches becomes PormG's (see the docstring).
    conn isa PormGPostgres && !composite_is_owned(lc) && push!(adopts, (lc, d))
  end
  unowned = Dict{String, LiveComposite}()
  for (j, (lc, _)) in enumerate(live)
    taken[j] && continue
    conn isa PormGSQLite && lc.constraint && continue   # removed by the rebuild registered above
    if composite_is_owned(lc)
      push!(drops, lc)
    else
      unowned[_composite_name_key(conn, lc.name)] = lc  # #29: hand-made, never planned away
    end
  end

  # A name this pass creates, or renames an index TO, must not still be held on this table by an
  # index the pass KEEPS. `_check_composite_targets_free` exempts this table on the promise that its
  # own drop runs first — true for an index dropped, renamed away or lost to the rebuild, and false
  # for one kept because it matched its own declaration by name. There the CREATE would fail with
  # "already exists" on every run: two declarations on one table sharing a name, or an explicit
  # `name=` equal to a sibling's derived one while the sibling is live under it.
  renamed_away = Set{String}(lc.name for (lc, _) in renames)
  kept = Dict{String, LiveComposite}()
  for (j, (lc, _)) in enumerate(live)
    taken[j] || continue
    (rebuilding && lc.constraint) && continue
    lc.name in renamed_away && continue
    kept[_composite_name_key(conn, lc.name)] = lc
  end
  for d in Iterators.flatten((creates, (d for (_, d) in renames)))
    stranger = get(unowned, _composite_name_key(conn, d.name), nothing)
    stranger === nothing || throw(InvalidMigrationError(
      "Index name '$(d.name)' on table '$(table)' is held by an index $(_describe_live_composite(stranger)) " *
      "that PormG does not own — it carries no pormg:index marker, " *
      "so it is never planned away: one written by hand, or one a declaration adopted on SQLite, " *
      "where adopting writes no marker. Drop it by hand to give the name to a different index, " *
      "or give this one another name" * _adoption_hint(stranger)))
    holder = get(kept, _composite_name_key(conn, d.name), nothing)
    holder === nothing && continue
    throw(InvalidMigrationError(
      "Index name '$(d.name)' on table '$(table)' is already the name of the index " *
      "$(_describe_live_composite(holder)), which this model also declares; give each UniqueConstraint " *
      "and Index a distinct name"))
  end

  dropped = Set{String}()
  drop!(lc::LiveComposite) = begin
    sql = conn isa PormGPostgres && lc.constraint ? Dialect.drop_unique_constraint(conn, table, lc.name) :
                                                    Dialect.drop_index(conn, lc.name)
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove composite index: $(lc.name)", sql)
    push!(dropped, lc.name)
  end
  foreach(drop!, drops)
  # Before the renames: the comment belongs to the index, not its name, so a rename after it carries
  # the marker along — and the label sits in the same `_order_statements` bucket, so plan order holds.
  for (lc, d) in adopts
    # #29 part 2: a text-holding index is adopted under the hash of its DECLARED text, which is what
    # every later plan compares — the catalog's rewritten form would never hash to it.
    _configure_order_dict_migration_plan(migration_plan, model_name,
      "Adopt index: $(replace(lc.name, "Rename field" => "Rename_field"))",
      Dialect.comment_index(conn, "\"$(Dialect._quote_table_ddl(lc.name))\""; keep = lc.comment,
                            marker = something(composite_marker(d), INDEX_MARKER)))
  end
  for (lc, d) in renames
    if conn isa PormGPostgres
      _claim_composite_target!(conn, targets, d.name, table)
      _configure_order_dict_migration_plan(migration_plan, model_name, "Rename composite index: $(lc.name)",
        lc.constraint ? Dialect.rename_constraint(conn, table, lc.name, d.name) :
                        Dialect.rename_index(conn, lc.name, d.name))
    else
      drop!(lc)                                      # SQLite cannot rename an index
      push!(creates, d)
    end
  end

  quoted(x) = "\"$(Dialect._quote_table_ddl(x))\""
  for d in creates
    _claim_composite_target!(conn, targets, d.name, table; auto = d.auto)
    cols = String[quoted(c) for c in d.columns]
    if d.auto
      # The join table keeps its historical step label; since #161 it is diffed on every run, so it
      # loses `IF NOT EXISTS` like every other composite create.
      _configure_order_dict_migration_plan(migration_plan, model_name, "Create many-to-many unique index",
        Dialect.create_unique_index(conn, quoted(d.name), quoted(table), cols; if_not_exists = false))
    elseif d.unique
      # #934: a partial or functional one carries its text and the hashed marker; a plain one neither.
      _configure_order_dict_migration_plan(migration_plan, model_name, "Create unique constraint: $(d.name)",
        Dialect.create_unique_index(conn, quoted(d.name), quoted(table), cols; if_not_exists = false,
                                    expressions = d.expressions, condition = d.condition,
                                    marker = composite_marker(d)))
    else
      # "Create index…" puts it in `_order_statements`' last bucket, after every same-table rebuild
      # (#152) — correct, since a CREATE INDEX only needs its table to exist.
      #
      # #29: an advanced index carries its method, directions and classes, and the ownership marker;
      # since part 2 also its expressions and condition, under the hashed marker of their text.
      _configure_order_dict_migration_plan(migration_plan, model_name, "Create index: $(d.name)",
        Dialect.create_index(conn, quoted(d.name), quoted(table), cols; if_not_exists = false,
                             method = d.method, descending = d.descending, opclasses = d.opclasses,
                             expressions = d.expressions, condition = d.condition,
                             marker = composite_marker(d), include = String[quoted(c) for c in d.include]))
    end
  end
  return dropped
end

# What a live composite indexes, for a message: `over (a, b)`, `over expressions (lower(a))`, and the
# condition of a partial one.
function _describe_live_composite(lc::LiveComposite)::String
  what = isempty(lc.expressions) ? "over ($(join(lc.columns, ", ")))" :
                                   "over expressions ($(join(lc.expressions, ", ")))"
  isempty(lc.include) || (what *= " INCLUDE ($(join(lc.include, ", ")))")
  return lc.condition === nothing ? what : "$(what) WHERE $(lc.condition)"
end

# #29 part 2: a hand-made functional or partial index can be adopted only by declaring the catalog's
# own text, which PostgreSQL rewrites — so the refusal hands that declaration over, ready to paste.
function _adoption_hint(lc::LiveComposite)::String
  composite_holds_text(lc) || return ""
  # Catalog text the declaration validator refuses (#934 — a literal ending in a backslash, say) would
  # make the pasted declaration throw: advice that errors when followed. Say why instead.
  texts = lc.condition === nothing ? lc.expressions : [lc.expressions; lc.condition]
  all(is_valid_db_default_sql, texts) ||
    return ". PormG cannot adopt it: its definition holds SQL text a declaration refuses (see " *
           "`Models.Index`), so give the declaration another name, or drop the index by hand"
  members = isempty(lc.expressions) ?
    "fields = ($(join((repr((d ? "-" : "") * c) for (c, d) in zip(lc.columns, lc.descending)), ", ")),)" :
    "expressions = ($(join((repr(e) for e in lc.expressions), ", ")),)"
  cond = lc.condition === nothing ? "" : ", condition = $(repr(lc.condition))"
  method = lc.method == "btree" ? "" : ", method = $(repr(lc.method))"
  opcs = isempty(lc.expressions) && !all(lc.opclass_default) ?
    ", opclasses = ($(join((d ? "nothing" : repr(o) for (o, d) in zip(lc.opclasses, lc.opclass_default)), ", ")),)" : ""
  inc = isempty(lc.include) ? "" : ", include = ($(join((repr(c) for c in lc.include), ", ")),)"
  # #934: a unique one is a `UniqueConstraint`, which has no method, classes or payload to add.
  decl = lc.unique ? "Models.UniqueConstraint($(members)$(cond), name = $(repr(lc.name)))" :
                     "Models.Index($(members)$(cond), name = $(repr(lc.name))$(method)$(opcs)$(inc))"
  return ". To keep it as PormG's own instead, declare it with the database's text: " * decl *
         (isempty(lc.expressions) ? " (the columns as the database names them — inspectdb writes the field names)" : "")
end

# ── Table-level CHECK constraints (#742) ─────────────────────────────────────────────────────────
#
# A declared `Models.CheckConstraint` is diffed against the table's `LiveCheck`s by NAME, and whether
# it changed is read off the ownership marker PormG stored beside it (see `LiveCheck`). The plan is
# computed once per table, before the column pass, and emitted in two halves at two points of
# `_alter_table_fields` — the timing is the whole difficulty, and it is engine-specific:
#
#   * SQLite has no `ALTER TABLE … ADD/DROP CONSTRAINT`: any change is the table rebuild, which renders
#     the declared CHECKs. It is registered BEFORE `_resolve_table_fields`, so the deletion branch sees
#     it and folds a `DROP COLUMN` into it (SQLite refuses to drop a column a table CHECK names) and the
#     composite pass sees `rebuilding` and re-creates the table-level UNIQUEs the rebuild does not
#     render. Registered early, it still RUNS after every `ADD COLUMN` — the rebuild copies each
#     declared column out of the old table — because `_add_new_field` moves an already-queued rebuild
#     behind the column it adds.
#   * PostgreSQL drops (the drop half of a replace included) are planned BEFORE the column pass, so
#     they run ahead of a `DROP COLUMN` — which would take a CHECK naming the column with it — and of
#     an `ALTER COLUMN … TYPE`, which re-checks every constraint on the column against the new type.
#     Adds and renames are planned after the composite pass, behind every `ADD COLUMN` they may name.
#     All three are in `_order_statements`' general bucket, where plan order is execution order.

# What one table's declared CHECKs need, against its live ones. `drops` are live names; `adds` are
# declarations; `renames` pair a live name with the declaration now carrying its condition; `stamps`
# are declarations ADOPTING an unmarked live CHECK of the same text, which PostgreSQL marks with a
# `COMMENT ON CONSTRAINT` — non-destructive, and not a change on SQLite, which writes the marker the
# next time it rebuilds the table anyway. So `stamps` never makes a plan non-empty for the rebuild.
struct _CheckPlan
  drops::Vector{String}
  adds::Vector{Models.CheckConstraint}
  renames::Vector{Tuple{String, Models.CheckConstraint}}
  stamps::Vector{Tuple{Models.CheckConstraint, Union{String, Nothing}}}   # + the comment to keep
end
_check_plan_isempty(p::_CheckPlan)::Bool = isempty(p.drops) && isempty(p.adds) && isempty(p.renames)

"""
    _diff_checks(model, live_checks) -> _CheckPlan

A declaration and the live CHECK of the same name are unchanged when the live marker is the hash of
the declared condition, or when their canonical texts agree — the adoption case, where `inspectdb`
wrote the declaration from the catalog's own text, which on PostgreSQL never hashes to a marker.
Otherwise the live CHECK is replaced, whether PormG owns it or not: the declaration claims the name.
An unchanged CHECK with NO marker is adopted: `stamps` gives it PormG's, so the engines agree about
who owns it from then on — without that, removing or renaming the declaration would drop or rename
it on SQLite (whose next rebuild writes the marker) and leave it behind on PostgreSQL.

A live CHECK carrying PormG's marker that no declaration names is either renamed — a declaration
under a new name carries its condition, by marker or by canonical text — or dropped. One without a
marker is left alone.
"""
function _diff_checks(model::PormGModel, live_checks::Vector{LiveCheck})::_CheckPlan
  declared = Models.declared_check_constraints(model)
  plan = _CheckPlan(String[], Models.CheckConstraint[], Tuple{String, Models.CheckConstraint}[],
                    Tuple{Models.CheckConstraint, Union{String, Nothing}}[])
  isempty(declared) && all(lc -> lc.marker === nothing, live_checks) && return plan
  declared_names = Set{String}(c.name for c in declared)
  live_by_name = Dict{String, LiveCheck}(lc.name => lc for lc in live_checks)
  unchanged(c, lc) = (lc.marker !== nothing && lc.marker == check_marker(c.condition)) ||
                     canonical_check_condition(lc.sql) == canonical_check_condition(c.condition)
  orphans = LiveCheck[lc for lc in live_checks if lc.marker !== nothing && !(lc.name in declared_names)]
  for c in declared
    lc = get(live_by_name, c.name, nothing)
    if lc === nothing
      k = findfirst(o -> o.marker == check_marker(c.condition) ||
                         canonical_check_condition(o.sql) == canonical_check_condition(c.condition), orphans)
      if k === nothing
        push!(plan.adds, c)
      else
        push!(plan.renames, (orphans[k].name, c))
        deleteat!(orphans, k)
      end
    elseif !unchanged(c, lc)
      push!(plan.drops, lc.name)
      push!(plan.adds, c)
    elseif lc.marker === nothing
      push!(plan.stamps, (c, lc.comment))
    end
  end
  append!(plan.drops, (o.name for o in orphans))
  return plan
end

# The step label of a CHECK statement. The constraint name is the developer's, and
# `_order_statements` buckets any label CONTAINING "Rename field" ahead of the general bucket this step
# belongs in, so that one phrase is defused in the label — never in the SQL.
_check_step_label(verb::AbstractString, name::AbstractString)::String =
  "$(verb) check constraint: $(replace(name, "Rename field" => "Rename_field"))"

# First half — see the section note. SQLite: register the rebuild. PostgreSQL: the drops.
function _plan_check_drops!(conn::Union{PormGPostgres, PormGSQLite},
                            migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                            model_name::Symbol, model::PormGModel, plan::_CheckPlan)::Nothing
  _check_plan_isempty(plan) && return nothing
  if conn isa PormGSQLite
    key = "Alter table: $model_name"
    (haskey(migration_plan, model_name) && haskey(migration_plan[model_name], key)) ||
      _configure_order_dict_migration_plan(migration_plan, model_name, key, Dialect.rebuild_table(conn, model))
  else
    for name in plan.drops
      _configure_order_dict_migration_plan(migration_plan, model_name, _check_step_label("Remove", name),
                                           Dialect.drop_check_constraint(conn, string(model_name), name))
    end
  end
  return nothing
end

# Second half, PostgreSQL only — SQLite's rebuild already carries every declared CHECK. Renames, the
# adoption stamps, then adds; a name the table already holds for another constraint is refused before
# the plan is written.
function _plan_check_adds!(conn::Union{PormGPostgres, PormGSQLite},
                           migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                           model_name::Symbol, model::PormGModel, plan::_CheckPlan;
                           catalog_table::Union{Symbol, Nothing} = model_name)::Nothing
  conn isa PormGPostgres || return nothing
  table = string(model_name)
  for (old, c) in plan.renames
    _refuse_check_name_clash(conn, model, table, catalog_table, c.name)
    _configure_order_dict_migration_plan(migration_plan, model_name, _check_step_label("Rename", old),
                                         Dialect.rename_constraint(conn, table, old, c.name))
  end
  for (c, existing) in plan.stamps
    _configure_order_dict_migration_plan(migration_plan, model_name, _check_step_label("Adopt", c.name),
                                         Dialect.comment_check_constraint(conn, table, c; keep = existing))
  end
  for c in plan.adds
    c.name in plan.drops || _refuse_check_name_clash(conn, model, table, catalog_table, c.name)
    _configure_order_dict_migration_plan(migration_plan, model_name, _check_step_label("Create", c.name),
                                         Dialect.add_check_constraint(conn, table, c))
  end
  return nothing
end

# A PostgreSQL constraint name is unique per TABLE, across every kind — so a declared CHECK must not
# take one another constraint holds, or the plan is written and `migrate` fails on "already exists".
# Two sources. For a table this plan CREATES: the names PormG's own `CREATE TABLE` gives its primary
# key and its column CHECKs (`<table>_<column>_check` for a `PositiveIntegerField` / bounded
# `BinaryField`) — the only names knowable before the table exists. For a table that exists
# (`catalog_table`): every constraint the catalog holds, except an unmarked CHECK of exactly PormG's own
# column shape that the column pass will DROP — because the declared field for its column no longer
# carries that fact (or the column goes) — before this CHECK is added. One the column pass keeps still
# holds the name, whatever it is called. A name this cannot see (a UNIQUE the composite pass drops in
# this plan, a name PostgreSQL truncated) fails the migration loudly, inside its transaction.
function _refuse_check_name_clash(conn::PormGPostgres, model::PormGModel, table::AbstractString,
                                  catalog_table::Union{Symbol, Nothing}, name::AbstractString)::Nothing
  own = Set{String}(["$(table)_pkey"])
  for (key, field) in model.fields
    Models.is_many_to_many_field(field) && continue
    (Dialect._requires_non_negative_check(field) || Dialect._requires_byte_length_check(field)) &&
      push!(own, "$(table)_$(Models.field_db_column(field, string(key)))_check")
  end
  taken = name in own
  if !taken && catalog_table !== nothing
    # One row per constraint holding the name, with — for an unmarked single-column CHECK of PormG's
    # own shape — its column and which shape it is. `own_shape` is spliced once per shape.
    own_shape(match) = """(con.contype = 'c' AND array_length(con.conkey, 1) = 1 AND EXISTS (
              SELECT 1 FROM pg_attribute a WHERE a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
                AND $(match) AND $(_PG_UNMARKED_CHECK)))"""
    rows = DataFrame(fetch(conn, """
      SELECT (SELECT a.attname FROM pg_attribute a
              WHERE a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
                AND array_length(con.conkey, 1) = 1) AS col,
             $(own_shape(_PG_NON_NEGATIVE_CHECK_MATCH)) AS nonneg,
             $(own_shape(_PG_BYTE_LENGTH_CHECK_MATCH)) AS bytelen
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = \$1 AND con.conname = \$2 AND n.nspname = ANY(current_schemas(false));""",
      [string(catalog_table), String(name)]))
    taken = any(r -> !_column_pass_frees(model, r), eachrow(rows))
  end
  taken && throw(InvalidMigrationError(
    "CheckConstraint name '$(name)' on table '$(table)' is already the name of another constraint on " *
    "that table — its primary key, the CHECK PostgreSQL names for a positive-integer or bounded binary " *
    "column, or (on a table that exists) any other constraint it holds. Constraint names are unique " *
    "per table on PostgreSQL; give the CheckConstraint another name."))
  return nothing
end

# Will the column pass drop this constraint before the CHECK is added? Only for an unmarked CHECK of
# PormG's own column shape (`nonneg` / `bytelen` from `_refuse_check_name_clash`'s query) on a column
# the declared model drops, or declares WITHOUT that fact — the column diff then removes it as a
# stray. A column still carrying the fact keeps its CHECK, and the name stays taken.
function _column_pass_frees(model::PormGModel, r)::Bool
  nonneg, bytelen = r.nonneg === true, r.bytelen === true
  (nonneg || bytelen) && r.col !== missing && r.col !== nothing || return false
  col = string(r.col)
  for (key, field) in model.fields
    Models.is_many_to_many_field(field) && continue
    Models.field_db_column(field, string(key)) == col || continue
    return nonneg ? !Dialect._requires_non_negative_check(field) : !Dialect._requires_byte_length_check(field)
  end
  return true   # the column goes, and PostgreSQL drops its CHECK with it
end

# A declared CHECK whose condition still names a live column this plan renames away or removes (#742).
# Renamed: PostgreSQL rewrites the stored expression on `RENAME COLUMN`, so the hash still matches and
# nothing would be planned — the stale text would surface only when something renders the declaration
# again (the next SQLite rebuild, a replace). Removed: PostgreSQL drops the CHECK with the column and
# the next plan fails to re-add it, and SQLite refuses the `DROP COLUMN`. Refused here, both.
# `renames` maps old ⇒ new physical column; `live_columns` are the table's columns as the catalog has
# them. A token followed by `(` is a function name, never a column; bare tokens compare
# case-insensitively, as both engines resolve them. A column name used as a keyword (`EXTRACT(year
# FROM …)` while a `year` column is removed) is refused too — the scan reads names, not SQL grammar.
function _refuse_stale_check_conditions(model::PormGModel, renames::Dict{String, String},
                                        live_columns)::Nothing
  declared = Models.declared_check_constraints(model)
  # Every text-holding composite as (kind, name, expressions, condition): an `Index` (#29 part 2) or,
  # since #934, a partial or functional `UniqueConstraint`.
  text_indexes = Tuple{String, String, Vector{String}, Union{String, Nothing}}[
    ("Index", String(ix.name), ix.expressions, ix.condition)
    for ix in get(get(model.cache, "composite_indexes", Dict{String, Any}()), "indexes", Models.Index[])
    if Models._index_holds_text(ix)]
  for uc in Models._declared_unique_constraints(model)
    Models._unique_holds_text(uc) && push!(text_indexes, ("UniqueConstraint", String(uc.name), uc.expressions, uc.condition))
  end
  isempty(declared) && isempty(text_indexes) && return nothing
  declared_cols = Set{String}(lowercase(c) for c in _model_physical_columns(model))
  # Each live column the declared model no longer has ⇒ what it was renamed to, or `nothing` if removed.
  gone = Dict{String, Union{String, Nothing}}(String(col) => get(renames, String(col), nothing)
                                              for col in live_columns if !(lowercase(String(col)) in declared_cols))
  isempty(gone) && return nothing
  for c in declared, t in _sqlite_identifier_tokens(c.condition)
    t.called && continue
    for (old, new) in gone
      (t.quoted ? t.name == old : lowercase(t.name) == lowercase(old)) || continue
      throw(InvalidMigrationError(new === nothing ?
        "CheckConstraint '$(c.name)' on '$(model_table_name(model))' names column '$(old)', which this " *
        "migration removes. Take it out of the condition, or remove the CheckConstraint — PostgreSQL " *
        "would drop the CHECK together with the column and the next migration would fail to re-create " *
        "it, and SQLite refuses to drop a column a CHECK names." :
        "CheckConstraint '$(c.name)' on '$(model_table_name(model))' still names column '$(old)', which " *
        "this migration renames to '$(new)'. Update its condition to the new name — PostgreSQL would " *
        "keep the old condition working, but the next time the declaration is rendered (a SQLite " *
        "table rebuild, a replaced CHECK) it would name a column that no longer exists."))
    end
  end
  # #29 part 2: an expression or partial index's text, read with the exclusions the SQLite rebuild's
  # rename splice applies (`_sql_text_column_tokens`), so this refusal and that rewrite agree about
  # what a column reference is. Renamed: PostgreSQL rewrites the stored index on `RENAME COLUMN` and
  # the marker's hash still matches, so the stale declaration would surface only when something
  # re-creates the index. Removed: both engines drop or refuse the index with the column, and the
  # declaration would then plan to re-create it over a column that is gone.
  for (kind, ixname, exprs, cond) in text_indexes
    texts = cond === nothing ? exprs : vcat(exprs, cond)
    for (k, text) in enumerate(texts)
      for t in _sql_text_column_tokens(text), (old, new) in gone
        (t.quoted ? t.name == old : lowercase(t.name) == lowercase(old)) || continue
        what = k > length(exprs) ? "condition" : "expression $(repr(text))"
        throw(InvalidMigrationError(new === nothing ?
          "$(kind) '$(ixname)' on '$(model_table_name(model))' names column '$(old)' in its $(what), " *
          "which this migration removes. Take it out of the index, or remove the $(kind) — the database " *
          "drops (PostgreSQL) or refuses to drop (SQLite) a column an index still names." :
          "$(kind) '$(ixname)' on '$(model_table_name(model))' still names column '$(old)' in its $(what), " *
          "which this migration renames to '$(new)'. Update the index's text to the new name — PormG " *
          "does not rewrite your SQL, and the declaration would otherwise re-create the index over a " *
          "column that no longer exists."))
      end
    end
  end
  return nothing
end

# The identifier tokens of an index's SQL text that can be column references: not a function name
# (followed by `(`), not an unquoted `_SQLITE_INDEX_SYNTAX_WORDS` member, and not the collation after
# an unquoted `COLLATE` — the three exclusions `_sqlite_rewrite_index_columns` applies (#29 part 2).
function _sql_text_column_tokens(text::AbstractString)
  out = _SQLiteIdentifierToken[]
  after_collate = false
  for t in _sqlite_identifier_tokens(text)
    if after_collate
      after_collate = false
      continue
    end
    if !t.quoted && uppercase(t.name) == "COLLATE"
      after_collate = true
      continue
    end
    t.called && continue
    (!t.quoted && uppercase(t.name) in _SQLITE_INDEX_SYNTAX_WORDS) && continue
    push!(out, t)
  end
  return out
end

# #830: can a CHECK this plan adds be counted against the table as it is now? Only when every column
# its condition names is a live column the plan does not retype. A name the declared model has but
# the catalog does not is a column this plan adds (or the new side of a rename), which the count
# cannot see. Names are read with the same token scan `_refuse_stale_check_conditions` uses: a token
# followed by `(` is a function, bare tokens compare case-insensitively, and a token that names no
# declared column (a keyword, a literal's neighbour) is ignored.
_check_countable(c::Models.CheckConstraint, model::PormGModel, live::LiveTable, retyped::Set{String})::Bool =
  _sql_text_countable(c.condition, model, keys(live.columns), retyped)

# The same question for any condition text — since #934 also a partial `UniqueConstraint`'s `WHERE`,
# which the duplicate count filters by.
function _sql_text_countable(text::AbstractString, model::PormGModel, live_cols, retyped::Set{String})::Bool
  declared_cols = _model_physical_columns(model)
  for t in _sqlite_identifier_tokens(text)
    t.called && continue
    for name in declared_cols
      (t.quoted ? t.name == name : lowercase(t.name) == lowercase(name)) || continue
      (name in live_cols && !(name in retyped)) || return false
    end
  end
  return true
end

function _add_new_table(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel;
                        composite_targets::Dict{String, Tuple{String, String}} = Dict{String, Tuple{String, String}}())::Nothing
  _configure_order_dict_migration_plan(migration_plan, model_name, "New model", Dialect.create_table(conn, model))
  for (field_name, field) in model.fields
    name = _hash_field_name(model_name, field_name)
    _add_constrains(conn, migration_plan, model_name, model, field_name, field, name)
  end
  # A new table has no live side, so every declared composite is a create — the same emitter the
  # diff uses, which is what keeps a table created here and one altered later converging on one
  # set of statements.
  _plan_composite_actions!(conn, migration_plan, model_name, model, LiveComposite[];
                           targets = composite_targets)
  # #742: likewise every declared CHECK. PostgreSQL adds each after the CREATE TABLE; SQLite plans
  # nothing, because `create_table` rendered them inline — a rebuild here would make a create-only
  # migration destructive.
  _plan_check_adds!(conn, migration_plan, model_name, model, _diff_checks(model, LiveCheck[]);
                    catalog_table = nothing)
  return nothing
end

# One of the four producers of the shared SQLite "Alter table: <model>" key. It registers the BARE
# rebuild; the indexes, triggers and views around it are rendered once the whole plan is known, by
# `_finalize_sqlite_rebuilds!` (#729). Until then the table's rename map is still growing (#556).
function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::String; temporary_default_value::Any = nothing,
                        # #829: the table as the catalog knows it at plan time (`model_name` except on
                        # a table rename, #615), and the lossy-ALTER sink the finding goes into.
                        catalog_table::Union{Symbol, Nothing} = nothing,
                        lossy_alters::Vector{LossyAlter} = LossyAlter[])::Nothing
  field = model.fields[field_name]
  Models.is_many_to_many_field(field) && return nothing
  name = _hash_field_name(model_name, field_name)
  # #829: a NOT NULL column with no default cannot be added to a table that has rows, on either
  # engine. It has no `ColumnDelta`, so `_plan_column_change!` never sees it; the finding is recorded
  # here, from the declared column's spec, and counted by `migrate` before anything is written.
  append!(lossy_alters, _lossy_add_column(_spec_or_degraded(field, conn, "<uncompilable:new>"; name = field_name), conn;
                                          table = String(something(catalog_table, model_name)),
                                          temporary_default = temporary_default_value))
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
  # `ADD COLUMN`, and SQLite refuses `ADD COLUMN … UNIQUE` whether or not a foreign key is involved,
  # so a `unique` key (an `sOneToOneField`) still aborts on the first statement — exactly as it did
  # before #514, since that refusal is about the column, not the constraint. The other half of this
  # note, a NOT NULL key with no default, is #829's and is no longer a limit: such a column is added
  # nullable and tightened by the rebuild below (`needs_sqlite_not_null_rebuild`).
  needs_sqlite_fk_rebuild = conn isa PormGSQLite && field isa Models.sRelationalColumn &&
                            field.db_constraint &&
                            !Dialect.sqlite_add_column_can_inline_fk(field, temporary_default_value)
  # #496, and the third reason SQLite rebuilds after an ADD COLUMN. SQLite refuses `ADD COLUMN` with
  # a NON-CONSTANT default on a table that has rows — measured on 3.53.4, `Cannot add a column with
  # non-constant default`, for `CURRENT_TIMESTAMP` and a parenthesised expression alike. An EMPTY
  # table accepts both, but the planner has no way to know which it faces and must not query to find
  # out, so any `db_default` takes the safe route: `Dialect.add_field` renders the column WITHOUT its
  # default and as nullable (`defer_db_default`), and the rebuild below restores both.
  #
  # The backfill in between is what keeps the two engines equal. PostgreSQL's
  # `ADD COLUMN … DEFAULT expr` fills existing rows by itself; SQLite's deferred column arrives all
  # NULL, so without the UPDATE a NOT NULL rebuild would fail on the copy and a nullable one would
  # leave a silent divergence. `WHERE … IS NULL` rather than an unconditional SET because the plan is
  # a list of statements that may be re-run against a partially-migrated database.
  needs_sqlite_db_default_rebuild = conn isa PormGSQLite &&
                                    Dialect.db_default_sql(field, conn) !== nothing
  # #829, the fourth reason. SQLite refuses `ADD COLUMN … NOT NULL` with no default on EVERY table,
  # even an empty one, so `Dialect.add_field` renders such a column nullable (the same predicate) and
  # the rebuild below declares it NOT NULL. That fails on the copy exactly when PostgreSQL's
  # `ADD COLUMN` fails — when the table has rows — and the `:add_not_null` finding recorded above
  # refuses that case before any write.
  needs_sqlite_not_null_rebuild = conn isa PormGSQLite &&
                                  Dialect.sqlite_add_column_defers_not_null(field, temporary_default_value)
  if needs_sqlite_db_default_rebuild
    physical = Models.field_db_column(field, field_name)
    expr = Dialect.db_default_sql(field, conn)
    _configure_order_dict_migration_plan(migration_plan, model_name,
      "Backfill db_default: $field_name",
      """UPDATE "$(Dialect._quote_table_ddl(string(model_name)))" """ *
      """SET "$(Dialect._quote_table_ddl(physical))" = $expr """ *
      """WHERE "$(Dialect._quote_table_ddl(physical))" IS NULL;""")
  end
  if temporary_default_value !== nothing || needs_sqlite_fk_rebuild || needs_sqlite_db_default_rebuild ||
     needs_sqlite_not_null_rebuild
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
    # existing secondary indexes too. `_finalize_sqlite_rebuilds!` wraps the bare rebuild registered
    # below once the plan is complete (#729); on PostgreSQL this is the column ALTER itself.
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
    # That case is now unreachable rather than merely unlikely — since #607
    # `_get_temporary_default_value` returns a value only for a NOT NULL column with NO declared
    # default, so there is no declared default for the temporary one to equal — but "unreachable and
    # harmless" is still a reason to keep the behaviour pinned, not a reason to let it drift.
    #
    # PostgreSQL DOES reach here (a new NOT NULL, defaultless `sDateTimeField` / `sDateField` gets a
    # temporary default on both engines; a nullable one, or one with a `default`, gets none — #607)
    # and renders `DROP DEFAULT` from `new_spec.default`, which is `NoDefault` for a defaultless
    # declared field. SQLite ignores the delta and rebuilds from the desired model.
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
      Dialect.alter_field(conn, model, field_name, field,
        ColumnDelta(temp_spec,
                    ColumnSpec(temp_spec.name, temp_spec.type, temp_spec.nullable,
                               temp_spec.primary_key, temp_spec.unique,
                               live_default, temp_spec.reference,
                               temp_spec.checks, temp_spec.identity, temp_spec.raw),
                    [:default])))
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
function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::Symbol; kwargs...)::Nothing
  _add_new_field(conn, migration_plan, model_name, model, field_name |> string; kwargs...)
end

"""
    _plan_column_change!(conn, migration_plan, model_name, declared_model, field_name,
                         new_field, delta, hashed_name;
                         old_column = nothing, catalog_table = model_name)

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

**`catalog_table` is the same rule for the table (#615).** On a table rename every statement here
names `model_name`, the NEW table, because `_order_statements` runs the `RENAME TABLE` first — but the
catalog still holds the old name when the plan is built, so every lookup (the FK drop's and the four
in `Dialect.alter_field`) asks for `catalog_table` instead. The caller passes `live.name`; everywhere
but a table rename it equals `model_name`, which is its default.

On SQLite this registers the BARE rebuild. The index snapshot, the table's triggers and the views
that read it are rendered around it by [`_finalize_sqlite_rebuilds!`](@ref) once the whole plan is
known (#729), because only then is the table's rename map complete: a rename answered after this
registration still has to reach the snapshot (#150/#556). The rebuild entry is also relocated to the
end of the table's plan on every registration, because it copies by the DESIRED column names and so
must follow every `RENAME COLUMN` and every `ADD COLUMN`.

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
                              delta::ColumnDelta,
                              hashed_name::String;
                              old_column::Union{String, Nothing} = nothing,
                              catalog_table::Symbol = model_name,
                              lossy_alters::Vector{LossyAlter} = LossyAlter[])::Nothing
  isempty(delta) && old_column === nothing && return nothing
  # #1032: a generated column is re-created, never altered, and only under its own name
  # (`_generated_recreates`). Reached here, it is a renamed column that is also made generated or given
  # another expression — two steps PormG will not guess an order for.
  if :default in delta && delta.new_spec.default isa GeneratedExpression
    throw(InvalidMigrationError(
      "Column \"$(field_name)\" of table \"$(model_name)\" is renamed and made generated (or given " *
      "another generation expression) in one plan. Rename it first and migrate, then change " *
      "generated_from, config or weights in a second migration (#1032)."))
  end
  # ONE source for "the column the live catalog knows", shared with the four constraint-name lookups
  # inside `Dialect.alter_field` (which read `delta.old_spec.name` for the same reason). On a rename
  # that is the PRE-rename column, because nothing has executed when the plan is built. The
  # `old_column` fallback covers a delta whose specs were built without names.
  drop_column = !isempty(delta.old_spec.name) ? delta.old_spec.name :
                (old_column === nothing ? field_name : old_column)

  # 1. Drop the live constraint when it is going away or has to be re-issued.
  _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, drop_column,
                                    delta.new_spec, delta.old_spec; catalog_table = catalog_table)

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
    # The surviving rebuild is whichever registration lands LAST. #556 made all four producers of
    # this key render with one shared rename map, so the winner carried every rename registered
    # BEFORE it — but not one answered after it (a pure rename registers nothing), and each
    # registration also snapshotted the catalog for nothing. Since #729 the producers register the
    # bare rebuild and `_finalize_sqlite_rebuilds!` renders the block once, with the complete map.
    if conn isa PormGSQLite && haskey(migration_plan, model_name) &&
       haskey(migration_plan[model_name], alter_key)
      delete!(migration_plan[model_name], alter_key)
    end
    # On PostgreSQL this is the per-slot ALTER; on SQLite the bare rebuild, wrapped later (#729).
    alter_sql = Dialect.alter_field(conn, declared_model, field_name, new_field, delta;
                                    catalog_table = string(catalog_table))
    _configure_order_dict_migration_plan(migration_plan, model_name, alter_key, alter_sql)
    # #803: what this change can do to the rows already there, read off the same delta. Keyed on the
    # catalog's names, because the pre-check that counts those rows runs before the plan does.
    append!(lossy_alters, _lossy_alters(delta, conn; table = String(catalog_table), column = drop_column))
  end

  # 4. Add the constraint for an `:add` or a `:repoint` — and #830's finding for it: the rows whose
  #    value no parent holds fail the new key, on either engine.
  append!(lossy_alters, _lossy_foreign_key(delta; table = String(catalog_table), column = drop_column))
  _add_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name, new_field, delta,
                                   hashed_name; drop_key_column = drop_column)
  return nothing
end

# #734: the `renames =` hints, parsed once (`_parse_rename_hints`). `tables` maps an old physical table
# to its new one, and `columns` maps (declared table, old column) to the new column. `nothing` on the
# new side says "not a rename": the old one is dropped, and it is offered to nothing. The names are
# PHYSICAL — `db_table`, `db_column` — because both sides of the diff are keyed by them, and a column
# hint names its table by the declared (new) name, the one the plan's statements use.
struct RenameHints
  tables::Dict{String, Union{String, Nothing}}
  columns::Dict{String, Dict{String, Union{String, Nothing}}}
end
RenameHints() = RenameHints(Dict{String, Union{String, Nothing}}(), Dict{String, Dict{String, Union{String, Nothing}}}())

# ── Generated columns: re-created, never altered (#1032) ─────────────────────────────────────────
#
# PostgreSQL has no ALTER that makes a column generated, and none that changes a generation
# expression before 17 (`SET EXPRESSION`). So a declared generated column whose live column is not
# that expression is DROPPED and ADDED again, in one plan:
#
#   * the live column is plain (or a default), and the declaration now has `generated_from`;
#   * the live column is generated from another expression — a changed `generated_from`, `config` or
#     `weights`, or a hand-made one whose deparsed text the declaration does not match;
#   * a SOURCE column is retyped. PostgreSQL refuses `ALTER COLUMN … TYPE` on a column a generated
#     one reads, so the generated column has to be out of the way first and back afterwards.
#
# PostgreSQL refuses `DROP COLUMN` on a source as well (SQLSTATE 2BP01, measured on 16: it does not
# drop the generated column with it). That case needs no arm of its own: the model refuses a
# `generated_from` naming a column it does not have, so a removed source is a changed expression,
# and the generated column is dropped ahead of the `Remove field` step.
#
# The drop is registered before anything else on the table and the re-add after the column loop, so
# within the table's entries (one bucket, registration order) a source retype, a source removal or a
# new source column lands between them. `DROP COLUMN` takes the column's indexes and CHECKs with it, so the planner reads
# a PRUNED live table from then on: those indexes are missing and are planned again, from the
# declaration. The plan is destructive — the regex flags the `DROP` — so `migrate` runs it only with
# `destructive = true`, and every stored document is recomputed by the `ADD COLUMN`.
#
# The other direction needs none of this: a generated column that is no longer declared generated is
# `ALTER COLUMN … DROP EXPRESSION` (`Dialect.alter_field`), which keeps its data.
function _generated_recreates(conn::PormGPostgres, model::PormGModel, live::LiveTable)::OrderedDict{String, String}
  out = OrderedDict{String, String}()
  columns = Dict{String, Tuple{String, PormGField}}()
  for (key, field) in model.fields
    Models.is_many_to_many_field(field) && continue
    columns[Models.field_db_column(field, string(key))] = (string(key), field)
  end
  for (col, (key, field)) in columns
    Models.is_generated_field(field) || continue
    haskey(live.columns, col) || continue
    changed = :default in column_delta(field, live.columns[col], conn; name = col)
    source_retyped = any(field.generated_from) do src
      haskey(columns, src) && haskey(live.columns, src) &&
        :type in column_delta(last(columns[src]), live.columns[src], conn; name = src)
    end
    (changed || source_retyped) && (out[col] = key)
  end
  return out
end
_generated_recreates(::PormGSQLite, ::PormGModel, ::LiveTable) = OrderedDict{String, String}()

# Does an index, CHECK or generation expression's SQL text name `col`? The same token scan the
# CHECK-countability pass uses — a quoted token compares exactly, a bare one case-insensitively — on
# the text with every cast's TYPE NAME removed first. PostgreSQL's deparser casts everywhere
# (`(title)::text`, `'A'::"char"`, `'simple'::regconfig`), and read as a token that type would name a
# column called `text`, `char` or `regconfig` (review of #1032).
const _CAST_TYPE_NAME_RE = r"::\s*(?:\"[^\"]*\"|[A-Za-z_][A-Za-z0-9_]*(?:\s+(?:varying|precision|with(?:out)?\s+time\s+zone))?)(?:\s*\[\])*"
_text_names_column(text::Nothing, col::AbstractString)::Bool = false
_text_names_column(text::AbstractString, col::AbstractString)::Bool =
  any(t -> t.quoted ? t.name == col : lowercase(t.name) == lowercase(col),
      _sql_text_column_tokens(replace(text, _CAST_TYPE_NAME_RE => "")))

# The live table as it will be once the re-created columns are dropped: same columns, without the
# indexes, composites and CHECKs `DROP COLUMN` removes with them.
function _prune_recreated(live::LiveTable, cols)::LiveTable
  isempty(cols) && return live
  gone = Set{String}(cols)
  touches(c::LiveComposite) = any(in(gone), c.columns) || any(in(gone), c.include) ||
                              any(e -> any(g -> _text_names_column(e, g), gone), c.expressions) ||
                              any(g -> _text_names_column(c.condition, g), gone)
  indexes = Dict{String, Union{String, Nothing}}(k => v for (k, v) in live.indexes if !(k in gone))
  composites = filter(!touches, live.composites)
  checks = filter(c -> !any(g -> _text_names_column(c.sql, g), gone), live.checks)
  return LiveTable(live.name, live.columns, indexes, composites, checks)
end

function _alter_table_fields(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, live::LiveTable, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, settings::PormGSettings; interactive::Bool = true,
                             composite_targets::Dict{String, Tuple{String, String}} = Dict{String, Tuple{String, String}}(),
                             sqlite_rebuild_context::Dict{Symbol, Tuple{Symbol, Dict{String, String}}} =
                               Dict{Symbol, Tuple{Symbol, Dict{String, String}}}(),
                             lossy_alters::Vector{LossyAlter} = LossyAlter[],
                             # #734: see `_resolve_table_fields`.
                             hints::RenameHints = RenameHints(),
                             fail_closed::Bool = true,
                             rename_problems::Vector{String} = String[])::Nothing
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
  # The live side's physical columns, in catalog order (#544). Since #522 they arrive as the keys of
  # `live.columns` — already the physical names, nothing to strip — and the map is kept only so the
  # code below reads symmetrically with `current_fields_map`, whose VALUES are the model's field keys.
  # Ordered, both of them: every consumer below either ITERATES these (the deletion/addition loops,
  # the deferred index pass at the end of this function) or asks them for membership; `OrderedSet`
  # answers both, so the order reaches the rendered DDL and the interactive rename prompts intact.
  model_fields_map = OrderedDict{String, String}(col => col for col in keys(live.columns))
  stripped_model_fields = OrderedSet(keys(model_fields_map))

  # Do the same for current_schema model fields, but key by the PHYSICAL column name
  # (db_column when set, else the field name) so the code side aligns with the
  # column-keyed introspected DB side — otherwise a field whose db_column differs from
  # its name would churn as a spurious DROP + ADD (#50). The value stays the real
  # field-name key for accessing model.fields.
  # Element type spelled out, like `model_fields_map` above — NOT inferred from the generator.
  # `_resolve_table_fields` types this parameter `::AbstractDict{String, String}`, and
  # `OrderedDict(gen)` only infers `{String, String}` from OrderedCollections 1.3; on 1.0-1.2 it
  # yields `{Any, Any}` and the call is a MethodError. PormG declares `OrderedCollections = "1, 2"`
  # and that floor is load-bearing for two consuming apps (#560), so the fix belongs here rather
  # than in the bound — the #549 rule, and CI's floor-resolve job (#574) is what caught it.
  current_fields_map = OrderedDict{String, String}(Models.field_db_column(field, String(strip(String(key), '"'))) => String(key) for (key, field) in current_schema[model_name][:model].fields)
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

  # #325: index create/drop is DEFERRED to after the whole field loop, not emitted inline.
  # `stripped_current_fields` is a `Set`, so field order is arbitrary — and on SQLite the table
  # rebuild re-creates every live secondary index verbatim (#82). A `DROP INDEX` emitted before
  # the rebuild is therefore undone by it, and whether that happened depended on which field the
  # Set yielded first. Collecting the actions here and flushing them below puts them after any
  # rebuild, deterministically. Each entry is `(:create | :drop, physical column, hashed name,
  # live index name or nothing)`.
  #
  # DECLARED BEFORE `_resolve_table_fields` since #556, and that placement is the whole fix for the
  # first of its two gaps. The rename branch lives inside `_resolve_table_fields`, which used to run
  # BEFORE this list existed — so a rename that also flipped `db_index` had nowhere to record the
  # index action and simply planned none, deferring it to the next `makemigrations`. It is a plain
  # mutable `Vector`, so a `push!` from in there lands in the list the flush loop below drains.
  index_actions = Tuple{Symbol, String, String, Union{String, Nothing}}[]

  # One rename map per TABLE (#150/#556): old ⇒ new physical column, filled by the rename branch.
  # The SQLite rebuild re-creates the table's indexes and triggers against the NEW names, so it must
  # see every rename — including one answered after the rebuild was registered. Since #729 it is read
  # once, by `_finalize_sqlite_rebuilds!`, after every table has been diffed; the producers of the
  # "Alter table: <model>" step no longer render with it at all.
  sqlite_rename_map = Dict{String, String}()

  @pormg_debug false
  # `model_name` is the table as the DDL must name it; `live.name` is the table as the catalog knows it
  # at plan time. They differ only on a table rename (#615), where `get_migration_plan` passes the
  # declared (new) name with the old `LiveTable` — so every lookup below asks for `catalog_table`, and
  # every statement names `model_name`.
  catalog_table = Symbol(live.name)
  # For the rebuild pass at the end of the plan — the map object itself, which is still filling.
  conn isa PormGSQLite && (sqlite_rebuild_context[model_name] = (catalog_table, sqlite_rename_map))

  # #1032: generated columns that are re-created rather than altered — dropped FIRST, and read as gone
  # by everything below. See `_generated_recreates`.
  regenerated = _generated_recreates(conn, current_schema[model_name][:model], live)
  for col in keys(regenerated)
    _configure_order_dict_migration_plan(migration_plan, model_name, "Drop generated field: $col",
      """ALTER TABLE "$(Dialect._quote_table_ddl(string(model_name)))" DROP COLUMN "$(Dialect._quote_table_ddl(col))";""")
  end
  live = _prune_recreated(live, keys(regenerated))

  # #742: the table CHECKs, first half — BEFORE the column pass. See the note above `_CheckPlan`.
  check_plan = _diff_checks(current_schema[model_name][:model], live.checks)
  _plan_check_drops!(conn, migration_plan, model_name, current_schema[model_name][:model], check_plan)

  # #830: the columns this plan retypes. A CHECK over one cannot be counted before the plan runs —
  # its condition would be evaluated against the OLD type.
  retyped = Set{String}()

  # #735: a join table's endpoint columns follow their end's rename without a question. #734: a hint
  # wins over that, and over the prompt.
  preset_renames = _join_table_endpoint_renames(current_schema[model_name][:model], colect_deletion, colect_addition,
                                                live, model_fields_map, current_fields_map, conn)
  hinted, hint_dropped = _resolve_column_hints(hints, String(model_name), model_fields_map, current_fields_map)
  hinted_olds = Set{String}(values(hinted))
  filter!(p -> !(Symbol(last(p)) in hint_dropped) && !(last(p) in hinted_olds), preset_renames)
  merge!(preset_renames, hinted)

  # Pass maps to resolve fields so original keys can be used for accessing model.fields
  _resolve_table_fields(conn, model_name, live, current_schema[model_name][:model], colect_deletion, colect_addition, migration_plan, settings, model_fields_map, current_fields_map, interactive=interactive, index_actions=index_actions, sqlite_rename_map=sqlite_rename_map,
                        lossy_alters=lossy_alters, preset_renames=preset_renames, excluded=hint_dropped,
                        fail_closed=fail_closed, rename_problems=rename_problems)
  # #742: every rename is answered now — refuse a declared condition naming a column that goes away.
  _refuse_stale_check_conditions(current_schema[model_name][:model], sqlite_rename_map, keys(live.columns))

  for field_name_stripped in stripped_current_fields
    original_code_key = current_fields_map[field_name_stripped]
    if haskey(model_fields_map, field_name_stripped)
      original_db_key = model_fields_map[field_name_stripped]

      field = current_schema[model_name][:model].fields[original_code_key]
      old_spec = live.columns[original_db_key]

      # A ManyToManyField is not a physical column and `sManyToManyField` is the one field struct
      # with no `db_index` at all, so the index blocks below would raise on it. It cannot normally
      # be matched here (a live column is never one), but the guard is what makes that explicit —
      # `_add_new_field` / `_add_constrains` both early-return on m2m for the same reason.
      Models.is_many_to_many_field(field) && continue

      name::String = _hash_field_name(model_name, field_name_stripped)

      # #507: ONE comparator. The declared field compiles to a `ColumnSpec` — what the database can
      # hold — and the live column arrived as one from the readers (#522), so the difference is read
      # off two specs and no struct is reconstructed on the live side. This replaced four code paths
      # that each answered "same column?" with their own reconciliations and disagreed at the edges:
      # the attribute-wise loop, `Dialect.describes_same_column` (#325), the `db_constraint = false`
      # escape (#408) and the `push!(:type)` fallthrough.
      #
      # Phase 2 made the delta TYPED and made it the only input to what follows. Phase 1 adapted it
      # back into field-attribute symbols so the action code could stay untouched; that adapter is
      # gone, and with it every action site's private opinion of a fact decided right here.
      delta = column_delta(field, old_spec, conn; name = field_name_stripped)

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
      # #1032: a re-created generated column has no ALTER — it is dropped above and added below —
      # and no lossy finding, since nothing is converted. Its indexes still go through the blocks
      # below, against the pruned live table, so the ones `DROP COLUMN` takes are planned again.
      if !haskey(regenerated, field_name_stripped)
        _plan_column_change!(conn, migration_plan, model_name, current_schema[model_name][:model],
                             field_name_stripped, field, delta, name;
                             catalog_table = catalog_table, lossy_alters = lossy_alters)
        :type in delta && push!(retyped, field_name_stripped)
      end

      # Index differences are RECORDED here and emitted after the loop — see `index_actions`.

      # #522: the live side's index facts sit on the `LiveTable`, outside the column spec (see
      # `ColumnSpec` for why `db_index` is not a column fact). The flag is the key's presence; the
      # value is the live index name `_drop_index` needs, or `nothing` when only the fact is known,
      # which routes `_drop_index` through `get_constraints_index` rather than raising. The readers
      # now record what the catalog holds — the old ones stamped `db_index = true` on every
      # relational column — so an adopted foreign key with no index plans its `CREATE INDEX` once.
      old_indexed = haskey(live.indexes, original_db_key)

      # Check if the field is also indexed
      if !field.primary_key && field.db_index && !old_indexed
        @pormg_debug false
        push!(index_actions, (:create, field_name_stripped, name, nothing))
      end

      # Check if is need to remove the index
      if !field.primary_key && old_indexed && !field.db_index
        @pormg_debug
        push!(index_actions, (:drop, field_name_stripped, name, live.indexes[original_db_key]))
      end
    end
  end

  # #1032: the re-created generated columns go back, and every NEW generated column moves behind the
  # table's other column steps: both read columns this plan may add or retype, and PostgreSQL resolves
  # a generation expression when the column is created. `_configure_order_dict_migration_plan` keeps a
  # key where it was first registered, so a moved step is deleted and registered again.
  _readd_generated_fields!(conn, migration_plan, model_name, current_schema[model_name][:model], regenerated)
  # …and every OTHER live generated column stops reading its sources before any of them changes.
  _release_generated_first!(conn, migration_plan, model_name, live, regenerated, sqlite_rename_map, retyped)

  # #161: the model-level composites — UniqueConstraint, Index, the join-table index — diffed against
  # `live.composites`. BEFORE the flush below, not after it: this may register the table's SQLite
  # rebuild (to remove an undeclared `UNIQUE (a, b)` clause), and a rebuild re-creates every live
  # index from its plan-time snapshot, so one registered after the flush's `DROP INDEX`es would put
  # those indexes straight back (#325).
  dropped_composites = _plan_composite_actions!(conn, migration_plan, model_name,
                                                current_schema[model_name][:model], live.composites;
                                                column_renames = sqlite_rename_map,
                                                catalog_table = catalog_table,
                                                targets = composite_targets,
                                                live_columns = Set{String}(keys(live.columns)),
                                                lossy_alters = lossy_alters, retyped = retyped)

  # #830: each CHECK this plan adds fails on the rows already there whose condition is false — on
  # both engines (SQLite adds it through the rebuild `_plan_check_drops!` registered).
  for c in check_plan.adds
    append!(lossy_alters, _lossy_check(String(catalog_table), c,
                                       _check_countable(c, current_schema[model_name][:model], live, retyped)))
  end

  # #742: the table CHECKs, second half — PostgreSQL's renames and adds, behind every column they name.
  _plan_check_adds!(conn, migration_plan, model_name, current_schema[model_name][:model], check_plan;
                    catalog_table = catalog_table)

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
      #
      # The probe also answers for a composite MEMBER (it is pinned to, by
      # `test_rename_unique_index.jl`), so an index the composite pass above is dropping in this same
      # plan must not count: the column would end up with no index at all (#161). A partial, an
      # expression-member or a marked index never answers (#934): it is not a plain index on `col`,
      # so a declared one over the column used to leave `db_index = true` with no index of its own.
      probe = conn isa PormGSQLite ? get_constraints_index(conn, catalog_table, col) : nothing
      if probe === nothing || probe in dropped_composites
        index_name = "$(hashed)_idx"
        # `model_name`, not `live.name`: this is DDL, and it runs after a table rename (#615).
        _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $col",
        Dialect.create_index(conn, "\"$(Dialect._quote_table_ddl(index_name))\"", "\"$(Dialect._quote_table_ddl(string(model_name)))\"", ["\"$(Dialect._quote_table_ddl(col))\""]))
      end
    else
      _drop_index(conn, migration_plan, model_name, col, index_name=live_index_name, catalog_table=catalog_table)
    end
  end
end

# A live generated column the plan does not re-create still reads its sources while the table's other
# steps run, and PostgreSQL refuses to retype or drop a column a generated one reads. Three cases:
#
#   * its expression is dropped (`generated_from` removed: `alter_field`'s DROP EXPRESSION) — that
#     whole `Alter field:` entry moves to the front of the table's steps. Everything in it concerns the
#     column itself, so it depends on no other step;
#   * it is removed, and one of its sources is retyped or removed too — a `DROP EXPRESSION` is added at
#     the front, so the source change no longer depends on which column the deletion loop meets first.
#     Only then: an ordinary removal needs no extra statement;
#   * it stays generated — renamed, or a hand-made column under a plain declaration — and one of its
#     sources is retyped or removed: refused, because no order of this plan's steps can apply it.
#
# Its sources are read off the live expression with the same token scan the CHECK and index passes
# use. A false positive (a token that names a column the expression does not read) can only add a
# harmless `DROP EXPRESSION` or refuse a plan; it cannot reorder anything else.
function _release_generated_first!(conn::PormGPostgres,
                                   migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                                   model_name::Symbol, live::LiveTable, regenerated::AbstractDict{String, String},
                                   renames::AbstractDict{String, String}, retyped::Set{String})::Nothing
  haskey(migration_plan, model_name) || return nothing
  steps = migration_plan[model_name]
  removed = Set{String}(chopprefix(k, "Remove field: ") for k in keys(steps) if startswith(k, "Remove field: "))
  # A renamed column's change is planned by the rename branch, not the column loop, so `retyped` does
  # not hold it: read it off its `Alter field:` step. And the live expression names columns by their
  # PRE-rename names, so every changed name is compared as the catalog knows it (review of #1032).
  previous = Dict{String, String}(new => old for (old, new) in renames)
  renamed_retyped = (new for new in keys(previous)
                     if occursin(" TYPE ", get(steps, "Alter field: $(new)", "")))
  changed = Set{String}(get(previous, c, c) for c in Iterators.flatten((removed, retyped, renamed_retyped)))
  front = Pair{String, String}[]
  for (col, spec) in live.columns
    spec.default isa GeneratedExpression || continue
    haskey(regenerated, col) && continue
    reads_changed = any(c -> _text_names_column(spec.default.sql, c), setdiff(changed, (col,)))
    alter_key = "Alter field: $(get(renames, col, col))"
    if haskey(steps, alter_key) && occursin("DROP EXPRESSION", steps[alter_key])
      push!(front, alter_key => steps[alter_key])
      delete!(steps, alter_key)
    elseif col in removed
      reads_changed && push!(front, "Release generated field: $col" =>
        """ALTER TABLE "$(Dialect._quote_table_ddl(string(model_name)))" ALTER COLUMN "$(Dialect._quote_table_ddl(col))" DROP EXPRESSION;""")
    elseif reads_changed
      throw(InvalidMigrationError(
        "Column \"$(col)\" of table \"$(model_name)\" is a generated column that reads a column this plan " *
        "retypes or removes ($(join(sort([c for c in changed if c != col && _text_names_column(spec.default.sql, c)]), ", "))), " *
        "and PostgreSQL refuses that while it reads it. Declare it with generated_from (PormG then drops it and " *
        "adds it back around the change), or make the change in two migrations, the renamed or generated " *
        "column first (#1032)."))
    end
  end
  isempty(front) && return nothing
  rest = collect(steps)
  empty!(steps)
  for (k, v) in Iterators.flatten((front, rest))
    steps[k] = v
  end
  return nothing
end
_release_generated_first!(::PormGSQLite, args...) = nothing

function _readd_generated_fields!(conn::Union{PormGPostgres, PormGSQLite},
                                  migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                                  model_name::Symbol, model::PormGModel, regenerated::AbstractDict{String, String})::Nothing
  for (col, key) in regenerated
    _configure_order_dict_migration_plan(migration_plan, model_name, "Re-add generated field: $col",
      Dialect.add_field(conn, model_name, key, model.fields[key]; model = model))
  end
  haskey(migration_plan, model_name) || return nothing
  steps = migration_plan[model_name]
  for (key, field) in model.fields
    Models.is_generated_field(field) || continue
    label = "Add field: $key"
    haskey(steps, label) || continue
    sql = steps[label]
    delete!(steps, label)
    steps[label] = sql
  end
  return nothing
end

function _resolve_table_fields(
                                conn::Union{PormGPostgres, PormGSQLite}, 
                                model_name::Symbol, 
                                live::LiveTable, 
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
                                interactive::Bool = true,
                                # Both owned by `_alter_table_fields` since #556 — see the comments
                                # at their declarations there. `index_actions` is the sink this
                                # function's rename branch records a `db_index` flip into; it is
                                # flushed by the caller AFTER the whole field pass, so an index
                                # action recorded here still lands after any table rebuild.
                                # `sqlite_rename_map` is the per-table rename map the rename
                                # branch fills; the SQLite rebuild pass reads it at the end.
                                # Defaulted so the function stays callable on its own.
                                index_actions::Vector{Tuple{Symbol, String, String, Union{String, Nothing}}} =
                                  Tuple{Symbol, String, String, Union{String, Nothing}}[],
                                sqlite_rename_map::Dict{String, String} = Dict{String, String}(),
                                # #803: the lossy-ALTER sink, owned by `get_migration_plan`'s caller.
                                lossy_alters::Vector{LossyAlter} = LossyAlter[],
                                # #735: answers known before anything is asked — added physical
                                # column ⇒ the removed column it is renamed from. A column listed here
                                # is never asked about; the rename then goes through the same branch
                                # a typed answer does.
                                preset_renames::AbstractDict{String, String} = Dict{String, String}(),
                                # #734: removed columns a `=> nothing` hint says are not a rename —
                                # offered to no question and to no fail-closed check.
                                excluded::Set{Symbol} = Set{Symbol}(),
                                # #734: with `interactive = false`, an unhinted pair that has the same
                                # definition is recorded here instead of guessed, and
                                # `get_migration_plan` raises with all of them. `fail_closed = false`
                                # is `check`'s: it reports drift, it does not refuse it.
                                fail_closed::Bool = true,
                                rename_problems::Vector{String} = String[]
                              )::Nothing
  # The catalog's name for this table at plan time — `model_name` except on a table rename (#615).
  # Lookups ask for it; DDL names `model_name`. See `_alter_table_fields`.
  catalog_table = Symbol(live.name)
  # Check by rename field
  while !isempty(colect_addition)
    field_name_sym = colect_addition[1]
    field_name = field_name_sym |> string
    if colect_deletion |> isempty
      # `field_name` here is the physical column; pass the real field key so _add_new_field's
      # model.fields lookup resolves (the DDL re-derives the db_column from the field) (#50).
      _add_new_field(conn, migration_plan, model_name, current_model, current_fields_map[field_name], temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings),
                     catalog_table = catalog_table, lossy_alters = lossy_alters)
    else
      # Only the answer is parsed inside the reader; the rename work below propagates its own
      # failures as themselves (#197).
      old_field_sym::Union{Symbol, Nothing} = nothing
      # A removed column another added column's hint or preset already claims is offered to nothing
      # else — or an earlier field could take it, or fail closed on it, before its own claim is read.
      claimed = Set{Symbol}(Symbol(old) for (new, old) in preset_renames if new != field_name)
      candidates = Symbol[old for old in colect_deletion if !(old in excluded) && !(old in claimed)]
      new_field = current_model.fields[current_fields_map[field_name]]
      if haskey(preset_renames, field_name) && Symbol(preset_renames[field_name]) in candidates
        old_field_sym = Symbol(preset_renames[field_name])
      elseif !interactive
        if fail_closed
          for old in _same_definition_candidates(new_field, field_name, candidates, live, model_fields_map, conn)
            push!(rename_problems, "  - column \"$model_name.$old\" → \"$model_name.$field_name\": pass " *
                                   _rename_hint_fix("$model_name.$old", "$model_name.$field_name"))
          end
        end
      elseif !isempty(candidates)
        colect_numbered, list_to_question = _ranked_field_candidates(
          new_field, field_name, candidates, live, model_fields_map, conn)
        old_field_sym = _read_rename_answer(
            _emsg("Is the field \"\e[4m\e[31m$field_name\e[0m\" from table \"\e[4m\e[34m$model_name\e[0m\" the same as one of the following fields: \e[4m\e[33m$list_to_question\e[0m? If yes, please enter the corresponding number; otherwise, type 'no':"),
            "one of the listed numbers, or 'no'") do response
          response in ("no", "n") && return (:new, nothing)
          old = _numbered_choice(response, colect_numbered)
          return old === nothing ? nothing : (:rename, old)
        end |> last
      end

      if old_field_sym === nothing
        # `field_name` is the physical column; pass the real field key (see above) (#50).
        _add_new_field(conn, migration_plan, model_name, current_model, current_fields_map[field_name], temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings),
                       catalog_table = catalog_table, lossy_alters = lossy_alters)
      else
        old_field_name = old_field_sym |> string
        old_spec = live.columns[model_fields_map[old_field_name]]
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
        # `db_index` is outside the IR on purpose — `index_actions` owns it, because on SQLite a
        # non-empty delta means a rebuild that re-emits every live index. Until #556 that also meant
        # a rename which ALSO flipped `db_index` planned no index action at all, because
        # `index_actions` was declared AFTER this function ran; it self-healed one `makemigrations`
        # later. `_alter_table_fields` now declares the list first and passes it in, and the flip is
        # recorded below, after the column change. The common case (an unchanged `db_index`) still
        # correctly plans nothing at all, where the pre-#507 code dropped and re-created the index
        # under a fresh hashed name.
        #
        # The SQLite rebuild receives the ACCUMULATED `column_renames`, so every renamed-but-surviving
        # column keeps its secondary indexes (#150) — and `_plan_column_change!` relocates the entry
        # to the end of the table's plan, so it executes after every RENAME. That closes what #150
        # documented as unsupported: two renames on one table now plan one correct rebuild, and a
        # rename co-occurring with a new column does too (whichever registers last, both relocate).
        #
        # Closed by #556: the map is owned by `_alter_table_fields`, one per table, and handed to
        # ALL FOUR producers of that key — this branch, the alteration loop, `_add_new_field`'s
        # rebuild (#514, or a temporary default), and the rebuild the deletion loop emits when a
        # column cannot be dropped in place. Whichever registration lands last therefore renders with
        # the union of the renames, so a rename co-occurring with a column alteration, a new column
        # or a rebuild-forcing deletion no longer loses the renamed column's index.
        # The live spec's own `name` is the PRE-rename column — the catalog still knows it by that
        # name at plan time, and four statements in `Dialect.alter_field` can only learn a constraint's
        # name by asking it — which is what makes the alteration correct rather than merely present.
        # Found in review: before that, a renamed column's UNIQUE / PRIMARY KEY / CHECK drop was
        # silently omitted, and a renamed `PositiveIntegerField` becoming a `TextField` emitted the
        # retype with the stale `>= 0` CHECK still in place, which PostgreSQL rejects. Since #522 the
        # readers put that name there directly; nothing is threaded through as `old_name` any more.
        delta = column_delta(new_field, old_spec, conn; name = field_name)
        # `delta.old_spec.name` IS the pre-rename physical column, so the rename map reads it off the
        # same single source the constraint lookups use rather than recomputing it.
        sqlite_rename_map[delta.old_spec.name] = field_name
        hashed_new_name = _hash_field_name(model_name, field_name)
        _plan_column_change!(conn, migration_plan, model_name, current_model, field_name,
                             new_field, delta,
                             hashed_new_name;
                             old_column = old_field_name,
                             catalog_table = catalog_table,
                             lossy_alters = lossy_alters)

        # #556: a rename that ALSO flips `db_index` now plans the index action in THIS migration.
        # The read is identical to the alteration loop's in `_alter_table_fields` — presence of the
        # key in `live.indexes` is the live flag, its value the index name a DROP needs — with one
        # difference that matters: the live side must be keyed by the PRE-rename column, which is
        # `delta.old_spec.name`, the same single source the FK drop and the four constraint lookups
        # use. Asking for `field_name` here would read the post-rename name the catalog has never
        # heard of, report "not indexed", and plan a CREATE INDEX on top of an index that already
        # exists.
        #
        # `index_actions` is drained by `_alter_table_fields` AFTER the whole field pass, so these
        # land after any table rebuild the rename registered; `_order_statements` then defers every
        # "Create index on …" to the very end (#152), after the RENAME COLUMN. An UNCHANGED
        # `db_index` still plans nothing at all — neither branch fires — which is what keeps the
        # index following the column across a plain rename (#515) instead of being dropped and
        # re-created under a fresh hashed name.
        old_indexed = haskey(live.indexes, delta.old_spec.name)
        if !new_field.primary_key && new_field.db_index && !old_indexed
          push!(index_actions, (:create, field_name, hashed_new_name, nothing))
        end
        if !new_field.primary_key && old_indexed && !new_field.db_index
          # Resolve the index NAME here, keyed on the PRE-rename column, instead of letting
          # `_drop_index` fall back to `get_constraints_index`. That fallback asks the catalog about
          # the column it is given -- which on this path is the POST-rename name the catalog has not
          # heard of yet, so it answers `nothing` and `_drop_index` plans nothing at all. Measured:
          # the drop direction of a rename+flip silently planned an empty migration.
          live_index_name = live.indexes[delta.old_spec.name]
          if live_index_name === nothing
            live_index_name = get_constraints_index(conn, catalog_table, delta.old_spec.name)
          end
          push!(index_actions, (:drop, field_name, hashed_new_name, live_index_name))
        end
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
        if live.columns[model_fields_map[string(fsym)]].primary_key
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
    # the live spec's `unique` does not. `primary_key` and the reference are read off the live spec (#522).
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
        spec = live.columns[model_fields_map[fname]]
        # A constraint in the database is a non-`nothing` reference (#522); a `db_constraint = false`
        # key has none and is physically just its integer column, exactly as before.
        spec.reference !== nothing ||
          spec.primary_key ||
          _sqlite_column_is_unique(conn, catalog_table, fname) ||
          !isempty(_sqlite_indexes_referencing_column(conn, catalog_table, fname))
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
      # The stable "Alter table:" key means a co-occurring alteration/add-default collapses into this
      # one idempotent recreation from the same desired model. It is the FOURTH producer of the key
      # (#556), reached when a rename co-occurs with a deletion that forces a rebuild AND the rename's
      # own delta was empty (a pure rename registers no rebuild, so `sqlite_rename_rebuild` does not
      # skip this branch). Registered bare: `_finalize_sqlite_rebuilds!` renders the index snapshot
      # and the triggers and views around it once the plan is complete (#729), with
      # `surviving_columns` keeping the dropped columns' indexes off the preserved set and the
      # table's full rename map keeping a renamed column's index on it.
      _configure_order_dict_migration_plan(migration_plan, model_name, "Alter table: $model_name",
        Dialect.rebuild_table(conn, current_model))
    else
      # PostgreSQL, or SQLite with no blocking column: plain DROP COLUMN works (the FK drop runs first on
      # PostgreSQL). Since #519 a SQLite column reaching here is referenced by no index at all, so the
      # `_drop_index` below is a no-op on this backend and the pre-drop is no longer what makes the
      # deletion legal — the fourth disjunct above is. It stays for PostgreSQL, where `get_constraints_index`
      # still names a droppable index and dropping it explicitly is harmless (PostgreSQL would drop it with
      # the column anyway).
      for field_name_sym in colect_deletion
        field_name = field_name_sym |> string
        # `nothing` on the new side IS the deletion path: `_fk_constraint_action` reads it as "the
        # reference is going away" and answers `:drop`. The live column arrived as a spec from the
        # readers (#522) — nothing is compiled here any more, so the fail-safe this call used to go
        # through has no failure left to guard; `get_constraints_fk` inside the helper remains the
        # authority on whether a constraint is really there.
        _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name, nothing,
                                          live.columns[model_fields_map[field_name]];
                                          catalog_table = catalog_table)
        _drop_index(conn, migration_plan, model_name, field_name, catalog_table = catalog_table)
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

# #735: what renaming the live column `old_spec` into the declared `new_field` would ALSO change — the
# `ColumnDelta` slots, empty when the definition is the same and only the name differs. The one
# answer to "is this a likely rename?" that the prompts rank by: the column IR already decides whether
# two columns are the same, so there is no second compatibility notion to drift from it.
_rename_changes(new_field::PormGField, old_spec::ColumnSpec, conn, name::AbstractString)::Vector{Symbol} =
  column_delta(new_field, old_spec, conn; name = name).changed

# A live column as a rename prompt shows it: its type as the catalog renders it, and its parent when
# it is a key — enough to judge a candidate without opening the model. Read off the spec alone.
function _describe_live_column(spec::ColumnSpec)::String
  ref = spec.reference
  (ref === nothing || ref.table === nothing) && return spec.raw
  return "$(spec.raw), FK → $(ref.table)"
end

# The field-rename candidates for the declared column `field_name`, numbered for the prompt (#735).
# Every removed column is still offered — the maintainer chose ranking over Django's filter, so a
# rename that also retypes stays one plan — but the same-definition ones come first, and each other
# one says what renaming it would change. Name order inside each group keeps the numbering
# deterministic across runs (it used to be name order alone). Sorting a copy leaves the caller's
# `colect_deletion` untouched; it is still needed for the later `filter!`.
function _ranked_field_candidates(new_field::PormGField, field_name::AbstractString, colect::Vector{Symbol},
                                  live::LiveTable, model_fields_map::AbstractDict{String, String}, conn)
  changes = Dict{Symbol, Vector{Symbol}}(
    old => _rename_changes(new_field, live.columns[model_fields_map[string(old)]], conn, field_name) for old in colect)
  ranked = sort(colect, by = old -> (!isempty(changes[old]), string(old)))
  numbered = Dict{Int64, Symbol}(index => old for (index, old) in enumerate(ranked))
  labels = map(enumerate(ranked)) do (index, old)
    what = _describe_live_column(live.columns[model_fields_map[string(old)]])
    isempty(changes[old]) ? "$index - $old ($what)" :
                            "$index - $old ($what; renaming also changes: $(join(changes[old], ", ")))"
  end
  return numbered, join(labels, ", ")
end

# The removed columns that `field_name` could be renamed from with nothing else changing (#735).
_same_definition_candidates(new_field::PormGField, field_name::AbstractString, colect::Vector{Symbol},
                            live::LiveTable, model_fields_map::AbstractDict{String, String}, conn)::Vector{Symbol} =
  Symbol[old for old in colect
         if isempty(_rename_changes(new_field, live.columns[model_fields_map[string(old)]], conn, field_name))]

# #735: an auto many-to-many join table's endpoint columns follow their end's table rename, unasked.
# The join table is synthesized (`Models.synthesize_many_to_many_through_models`) with one column per
# end, named after that end's model — so renaming a model renames the column, and the user, who never
# declared the column, was asked about it. Once `get_migration_plan` has retargeted the live
# references, the old endpoint column and the new one have the same definition: same type, same
# parent. A pair is taken only when it is the ONLY same-definition pair for both columns, so a
# self-relation whose two ends both moved (`from_…`/`to_…`) is asked rather than guessed.
function _join_table_endpoint_renames(current_model::PormGModel, colect_deletion::Vector{Symbol},
                                      colect_addition::Vector{Symbol}, live::LiveTable,
                                      model_fields_map::AbstractDict{String, String},
                                      current_fields_map::AbstractDict{String, String}, conn)::Dict{String, String}
  renames = Dict{String, String}()
  (current_model.cache !== nothing && haskey(current_model.cache, "many_to_many_auto")) || return renames
  same = Dict{Symbol, Vector{Symbol}}(
    added => _same_definition_candidates(current_model.fields[current_fields_map[string(added)]], string(added),
                                         colect_deletion, live, model_fields_map, conn)
    for added in colect_addition)
  for (added, olds) in same
    length(olds) == 1 || continue
    count(other -> only(olds) in other, values(same)) == 1 || continue
    renames[string(added)] = string(only(olds))
  end
  return renames
end

# The one reader for every rename question `makemigrations` asks (#726). `parse_answer` maps the
# normalised answer to a decision, or to `nothing` when it does not recognise it — and an
# unrecognised answer RAISES, so no question can fall through without recording a decision. The table
# question used to be an `if yes / elseif no` with no `else`: every other answer, the candidate's
# number included, recorded nothing, and the plan kept the old table's DROP TABLE while losing the
# new model's CREATE TABLE.
#
# End of input is `readline(keep = true)` returning "" — an empty LINE comes back as "\n", so the two
# stay distinct. It raises rather than guessing an answer. That is what a script or CI job without a
# terminal hits, and there is no `stdin isa Base.TTY` gate the way `migrate` has one, because scripted
# answers arrive through exactly that kind of stdin: a gate would refuse them too.
function _read_rename_answer(parse_answer::Function, question::AbstractString, expected::AbstractString)
  print(question)
  line = readline(stdin; keep = true)
  isempty(line) && throw(InvalidMigrationError(
    "makemigrations reached the end of input at a rename question, so there is no answer to read. " *
    "Run it at a terminal, or pass `interactive = false` with the renames named in `renames = [...]`."))
  response = strip(lowercase(line))
  answer = parse_answer(response)
  answer === nothing && throw(InvalidMigrationError(
    "Invalid choice \"$(response)\" — answer $(expected); please try makemigrations again"))
  return answer
end

# The candidate a typed number names, or `nothing` — a non-number and an unlisted number alike.
_numbered_choice(response::AbstractString, numbered::AbstractDict{Int64, Symbol}) =
  (n = tryparse(Int64, response); n === nothing ? nothing : get(numbered, n, nothing))

# The table-rename question (#726), asked only when `candidates` — the vanished tables no earlier
# answer has claimed, numbered in live-catalog order (#615) — is not empty. `yes` is a new table and
# the number of a candidate is a rename, directly. `no` asks for that number on its own: that is the
# two-step answer (`no`, then `<n>`) which scripts and the tests already feed, and it keeps its
# meaning. Returns the old table's name, or `nothing` for a new table.
function _ask_table_rename(model_name::Symbol, candidates::AbstractDict{Int64, Symbol},
                           list_to_question::AbstractString = join([string(index, " - ", candidates[index]) for index in sort(collect(keys(candidates)))], ", "))::Union{Symbol, Nothing}
  kind, old = _read_rename_answer(
      "The table $model_name has no match in the database. Is it a new table? Answer yes, or no / the number of the table it was renamed from: $list_to_question: ",
      "yes, no, or one of the listed numbers") do response
    response in ("yes", "y") && return (:new, nothing)
    response in ("no", "n") && return (:ask, nothing)
    old = _numbered_choice(response, candidates)
    return old === nothing ? nothing : (:rename, old)
  end
  kind === :ask || return old
  return last(_read_rename_answer(
      "Which table was $model_name renamed from? $list_to_question — enter its number, or 'no' for a new table: ",
      "one of the listed numbers, or 'no'") do response
    response in ("no", "n") && return (:new, nothing)
    old = _numbered_choice(response, candidates)
    return old === nothing ? nothing : (:rename, old)
  end)
end

# #735: how many of `model`'s declared columns `live` already holds under the same name with the same
# definition — `(matching, declared)`. The table-rename prompt ranks its candidates by it, so the table
# a model was most likely renamed from is listed first. The same predicate as the field prompt's.
function _table_match_count(model::PormGModel, live::LiveTable, conn)::Tuple{Int, Int}
  matching = declared = 0
  for (key, field) in model.fields
    Models.is_many_to_many_field(field) && continue
    declared += 1
    col = Models.field_db_column(field, String(strip(String(key), '"')))
    spec = get(live.columns, col, nothing)
    spec === nothing || isempty(_rename_changes(field, spec, conn, col)) && (matching += 1)
  end
  return matching, declared
end

# The table-rename candidates for `model`, numbered for the prompt (#735): most matching columns first,
# ties in live-catalog order — the order the candidates used to be numbered in (#615). Numbered 1..n
# in that order, so a table an earlier answer claimed leaves no gap.
function _ranked_table_candidates(model::PormGModel, unclaimed::Vector{Symbol},
                                  drop_table::AbstractDict{Symbol, Any}, conn)
  counts = Dict{Symbol, Tuple{Int, Int}}(old => _table_match_count(model, drop_table[old]["model"], conn) for old in unclaimed)
  ranked = sort(unclaimed, by = old -> -first(counts[old]))   # stable: ties keep catalog order
  numbered = Dict{Int64, Symbol}(index => old for (index, old) in enumerate(ranked))
  labels = ["$index - $old ($(counts[old][1]) of $(counts[old][2]) columns match)" for (index, old) in enumerate(ranked)]
  return numbered, join(labels, ", ")
end

_hint_error(msg::AbstractString) = InvalidMigrationError("Invalid `renames` hint: " * msg)

function _parse_rename_hints(renames::AbstractVector)::RenameHints
  hints = RenameHints()
  new_tables = Set{String}()
  new_columns = Set{Tuple{String, String}}()
  for hint in renames
    (hint isa Pair && first(hint) isa AbstractString && (last(hint) isa AbstractString || last(hint) === nothing)) ||
      throw(_hint_error("$(repr(hint)) is not `\"old\" => \"new\"` or `\"old\" => nothing`."))
    old, new = String(first(hint)), last(hint) === nothing ? nothing : String(last(hint))
    if occursin('.', old)
      table, old_col = split(old, '.'; limit = 2)
      new_col = nothing
      if new !== nothing
        occursin('.', new) || throw(_hint_error("\"$old\" => \"$new\" names a column on the left and a table on the right."))
        new_table, new_col = split(new, '.'; limit = 2)
        new_table == table || throw(_hint_error("\"$old\" => \"$new\" moves a column to another table; a rename keeps its table " *
                                                "(name it by its new name on both sides)."))
        (String(table), String(new_col)) in new_columns && throw(_hint_error("two hints rename a column into \"$new\"."))
        push!(new_columns, (String(table), String(new_col)))
      end
      cols = get!(hints.columns, String(table), Dict{String, Union{String, Nothing}}())
      haskey(cols, old_col) && throw(_hint_error("\"$old\" is named by two hints."))
      cols[String(old_col)] = new_col === nothing ? nothing : String(new_col)
    else
      new !== nothing && occursin('.', new) && throw(_hint_error("\"$old\" => \"$new\" names a table on the left and a column on the right."))
      haskey(hints.tables, old) && throw(_hint_error("\"$old\" is named by two hints."))
      if new !== nothing
        new in new_tables && throw(_hint_error("two hints rename a table into \"$new\"."))
        push!(new_tables, new)
      end
      hints.tables[old] = new
    end
  end
  return hints
end

# The table hints against the two sides (#734), resolved before any question: `renamed` is new ⇒ old
# for every hint that applies, and `dropped` the old tables a `=> nothing` hint takes out of every
# candidate list. A hint whose old table is gone and whose new one exists is STALE and does nothing —
# the rename ran already, as Atlas and sqldef treat it — so a hint list can stay in a script after it
# applied. With neither table there, it warns: the old name is more likely mistyped.
function _resolve_table_hints(hints::RenameHints, live_names::Set{String},
                              current_schema::AbstractDict{Symbol, <:Any})
  renamed = Dict{Symbol, Symbol}()
  dropped = Set{Symbol}()
  # Sorted, so with two bad hints the same one is reported on every run.
  for (old, new) in sort!(collect(hints.tables), by = first)
    haskey(current_schema, Symbol(old)) &&
      throw(_hint_error("\"$old\" is a declared model's table, so it is not being removed and cannot be renamed from."))
    if new === nothing
      old in live_names && push!(dropped, Symbol(old))
      continue
    end
    haskey(current_schema, Symbol(new)) ||
      throw(_hint_error("\"$old\" => \"$new\": no declared model has the table \"$new\"."))
    # Stale — the rename ran already — only when the NEW table is there. With neither, the old name
    # is more likely a typo than history, and the hint the caller relies on would do nothing.
    if !(old in live_names)
      new in live_names ||
        @warn("The `renames` hint \"$old\" => \"$new\" names a table the database does not have, and \"$new\" does not exist yet either; check the old name — nothing is renamed.")
      continue
    end
    new in live_names && throw(_hint_error("\"$old\" => \"$new\": both tables exist in the database."))
    renamed[Symbol(new)] = Symbol(old)
  end
  for table in keys(hints.columns)
    haskey(current_schema, Symbol(table)) ||
      throw(_hint_error("no declared model has the table \"$table\" (a column hint names its table by its new name)."))
  end
  return renamed, dropped
end

# The column hints for one table against its two sides (#734): `preset` is new ⇒ old column, and
# `dropped` the old columns a `=> nothing` hint takes out of every candidate list. Same rules as the
# tables', one level down.
function _resolve_column_hints(hints::RenameHints, table::AbstractString,
                               live_cols::AbstractDict{String, String}, declared_cols::AbstractDict{String, String})
  preset = Dict{String, String}()
  dropped = Set{Symbol}()
  for (old, new) in sort!(collect(get(hints.columns, String(table), Dict{String, Union{String, Nothing}}())), by = first)
    haskey(declared_cols, old) &&
      throw(_hint_error("\"$table.$old\" is a declared column, so it is not being removed and cannot be renamed from."))
    if new === nothing
      haskey(live_cols, old) && push!(dropped, Symbol(old))
      continue
    end
    haskey(declared_cols, new) ||
      throw(_hint_error("\"$table.$old\" => \"$table.$new\": the model of \"$table\" declares no column \"$new\"."))
    # Stale only when the new column is there; see `_resolve_table_hints`.
    if !haskey(live_cols, old)
      haskey(live_cols, new) ||
        @warn("The `renames` hint \"$table.$old\" => \"$table.$new\" names a column \"$table\" does not have, and \"$new\" does not exist yet either; check the old name — nothing is renamed.")
      continue
    end
    haskey(live_cols, new) && throw(_hint_error("\"$table.$old\" => \"$table.$new\": both columns exist in the database."))
    preset[new] = old
  end
  return preset, dropped
end

# The hint a failing-closed run asks for (#734), shown with the pair it would have guessed.
_rename_hint_fix(old::AbstractString, new::AbstractString) = "\"$old\" => \"$new\" to rename, or \"$old\" => nothing to drop it"

# Whether `model` is an auto many-to-many join table — synthesized, never declared (#735).
_is_auto_join_table(model::PormGModel)::Bool =
  model.cache !== nothing && haskey(model.cache, "many_to_many_auto")

# #735: the live table an auto join table was renamed from, when one of its ends was renamed — or
# `nothing`. Its name is derived from its owner (`<model>_<field>`), so renaming the owner renames
# it, and it used to be asked about as a model of its own: three correct answers for one rename, and
# with `interactive = false` every link row dropped. It is matched by SHAPE, not by re-deriving the
# old name — the derivation has a `db_table` pin and a Django app prefix in it, and the shape has
# neither: the same number of columns, keys to the same parents once the renames decided so far are
# applied, and at least one of those parents among the renamed tables. Taken only when exactly one
# unclaimed table fits; otherwise the model is asked about like any other.
#
# #911: and the old name must be the new one with the owner renamed — `<old owner>_<field>`, the same
# `<field>`. Shape alone cannot tell the same relation from ANOTHER one to the same target: renaming
# the owner while swapping `drivers` for `reserves` in the same change gave `team_t_drivers` the shape
# of `squad_t_reserves`, and its link rows moved to the new relation with one `@info` line as the only
# signal. A suffix check alone is not enough either, since `team_reserve_drivers` ends in `_drivers`.
# So the name is split at the declaring field, and the two stems must be the OWNER's decided rename:
# the name is derived from the owner alone (`_many_to_many_table_name`), so no other rename — the
# target's included — can account for a change in it. The owner's table may carry a prefix the stem
# lacks (`get_model_name` strips a Django app label), so the rename is matched up to a prefix both of
# its sides share. Still no derivation: nothing re-builds the old name. A join table whose field was
# renamed too, or whose new name is a `db_table` pin that does not follow `<model>_<field>`, is asked
# about — that is a second decision, not a consequence of the first.
function _join_table_rename_source(model::PormGModel, unclaimed::Vector{Symbol}, drop_table::AbstractDict{Symbol, Any},
                                   renames::Dict{String, String}, conn)::Union{Symbol, Nothing}
  parents(specs) = sort!(String[s.reference.table for s in specs if s.reference !== nothing && s.reference.table !== nothing])
  declared = parents(column_spec(field, conn; name = String(key)) for (key, field) in model.fields)
  any(p -> p in values(renames), declared) || return nothing
  # `_many_to_many_table_name` lowercases the whole `<model>_<field>` string, so the suffix is too.
  # A join table that does not say which field declared it is never followed — it is asked about.
  field = get(model.cache["many_to_many_auto"], "field", nothing)
  field === nothing && return nothing
  suffix = "_" * lowercase(String(field))
  new_name = String(model_table_name(model))
  endswith(new_name, suffix) || return nothing
  new_stem = chopsuffix(new_name, suffix)
  # The owner end's table, as the join table declares it — the new name, when the owner was renamed.
  owner_column = get(model.cache["many_to_many_auto"], "owner_column", nothing)
  owner_specs = [column_spec(f, conn; name = String(k)) for (k, f) in model.fields if String(k) == owner_column]
  length(owner_specs) == 1 && only(owner_specs).reference !== nothing || return nothing
  owner = only(owner_specs).reference.table
  owner === nothing && return nothing
  # `old_stem → new_stem` is the owner's decided rename, give or take a prefix both of its sides share,
  # ending at a `_` (an app label is `<label>_`).
  prefix = chopsuffix(owner, new_stem)
  (endswith(owner, new_stem) && (isempty(prefix) || endswith(prefix, "_"))) || return nothing
  renamed_stem(old_stem) = !isempty(old_stem) && any(((o, n),) -> n == owner && o == prefix * old_stem, renames)
  fits = filter(unclaimed) do old
    endswith(String(old), suffix) && renamed_stem(chopsuffix(String(old), suffix)) || return false
    live = _retarget_references(drop_table[old]["model"], renames)
    length(live.columns) == length(model.fields) && parents(values(live.columns)) == declared
  end
  return length(fits) == 1 ? only(fits) : nothing
end
# The value `_add_new_field` writes into `ADD COLUMN … DEFAULT` for a new temporal column, and then
# drops again. It exists for ONE reason: a NOT NULL column with no declared default cannot be added to
# a populated table — SQLite refuses the statement outright, PostgreSQL refuses it once the table has
# rows — so the migration needs some value to backfill the existing rows with. Two shapes never need
# it, and both used to get it anyway (#607):
#
#   * a `null = true` column is added as NULL, and the temporary value was written into EVERY existing
#     row as data indistinguishable from a real timestamp afterwards (1125 of 1125 `race` rows on the
#     fixture, 731 of which should have stayed NULL). Django adds a nullable column as NULL and asks
#     for a one-off default only when the column is NOT NULL;
#   * a column with a declared `default` backfills through that default — `field_to_column` already
#     prefers `field.default` over the temporary value — so the cleanup step `_add_new_field` queues
#     behind the temporary default was a redundant `SET DEFAULT` on PostgreSQL and a needless full
#     table rebuild on SQLite.
#
# `nothing` sends `_add_new_field` down its no-temporary-default branch, the same one the #514
# SQLite-FK-rebuild caller already exercises.
function _get_temporary_default_value(field::PormGField, settings::PormGSettings)
  field isa Union{Models.sDateTimeField, Models.sDateField} || return nothing
  # `db_default` joins `default` here for the same reason the comment above gives for `default`
  # (#496): the column already backfills from its OWN `DEFAULT`, so a temporary one is a redundant
  # `SET DEFAULT` on PostgreSQL and a needless full table rebuild on SQLite. It is not merely
  # wasteful — the temporary default EXISTS TO BE DROPPED, and the cleanup step forces a `[:default]`
  # delta whose new side is `NoDefault`, so leaving this out would have `_add_new_field` queue a
  # `DROP DEFAULT` that destroys the real expression default it had just rendered.
  (field.null || field.default !== nothing || field.db_default !== nothing) && return nothing
  # `now(TimeZone(…))` and one pass through the formatter — the same expression the insert path uses
  # for `auto_now_add` (`querybuilder/execution_write.jl`). This used to be `field.formatter(now(),
  # settings.time_zone) |> field.formatter`, calling a two-argument `format_timezone_sql` arm that
  # #602 deleted as having "zero callers": the call goes through the `formatter` SLOT, not the
  # function name, so a grep by name could not see it, and every NOT NULL temporal ADD COLUMN raised
  # `MethodError` from the moment #602 merged until #607 rewrote this line. CI runs no integration
  # test, and the unit suite had nothing on this path — `test_temporal_temporary_default.jl`'s
  # NOT NULL control is that guard now.
  field isa Models.sDateTimeField && return field.formatter(now(TimeZone(settings.time_zone)))
  return field.formatter(today())
end


"""
    _retarget_references(table::LiveTable, renames::Dict{String, String}) -> LiveTable

`table` as the catalog will describe it once the table renames in `renames` (old ⇒ new) have run:
every foreign key whose parent is an old name points at the new one (#678).

Both engines carry a constraint across `RENAME TO` — PostgreSQL follows the table's OID, and SQLite
(3.26 and later, with `legacy_alter_table` off, which PormG never sets) rewrites the child's
`REFERENCES` clause itself. So the retargeted live side is what the next introspection reads, and a
child whose only change is the rename diffs as converged instead of as a `:repoint`.

The binding is re-derived from the new table exactly as both readers derive it, so the reference is
the one a reader would build. The table is matched exactly, case included — the rule
`_fk_targets_equal` compares by (#390). Only `reference` changes; every other slot is copied.

A reference with no physical `table` is left alone: it compares by binding, and neither schema reader
ever produces one — only the `live_table` adapter can, from an unresolved String target, which is why
the planner's tests give their live keys a `to_table`.
"""
function _retarget_references(table::LiveTable, renames::Dict{String, String})::LiveTable
  isempty(renames) && return table
  retarget(spec::ColumnSpec) = begin
    ref = spec.reference
    (ref === nothing || ref.table === nothing || !haskey(renames, ref.table)) && return spec
    parent = renames[ref.table]
    moved = ForeignKeyRef(parent, format_model_name(Models._model_binding_name(parent)), ref.column, ref.on_delete)
    # Slot-generic, so a slot added to `ColumnSpec` later is carried rather than silently dropped.
    return ColumnSpec((f === :reference ? moved : getfield(spec, f) for f in fieldnames(ColumnSpec))...)
  end
  columns = OrderedDict{String, ColumnSpec}(name => retarget(spec) for (name, spec) in table.columns)
  # Every slot but `columns` carried as it is — `checks` included (#742): dropping it would read every
  # declared CHECK on every table of a plan with a table rename as missing.
  return LiveTable(table.name, columns, table.indexes, table.composites, table.checks)
end

"""
    _exclude_unmanaged_models!(current_schema) -> Set{String}

Remove every `managed = false` model (#741) from `current_schema` and return their table names — the
keys `current_schema` held them under, which are the physical names the live side is matched by.

This is the whole of #741's planner half, because every decision `get_migration_plan` makes starts
from one of two lists. An unmanaged model out of `current_schema` is never created, altered, given a
composite, or named as a rename target; its table out of the live list the planner classifies is
never dropped and never offered as a rename candidate. Called AFTER
`synthesize_many_to_many_through_models`, which resolves many-to-many targets against the full
schema and marks an auto join table unmanaged when both of its ends are. The dict is the one that
function returned, never the caller's.
"""
function _exclude_unmanaged_models!(current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}})::Set{String}
  unmanaged = Set{String}(String(key) for (key, entry) in current_schema if !model_is_managed(entry[:model]))
  for table in unmanaged
    delete!(current_schema, Symbol(table))
  end
  return unmanaged
end

"""
    _refuse_managed_models_on_ignored_tables(current_schema, conn, settings)

Raise `InvalidConfigurationError` when a managed model's table matches an ignore list that
`makemigrations` reads with. There are three: the connection's own `ignore_tables:` (#749), the
`register_ignore_tables!` registry, and the backend default (`_backend_ignore_tables`) (#805). Each
one contradicts the model: the model asks PormG to migrate the table, and the list asks PormG never
to read it. An ignored table reads as absent, so the planner would emit `CREATE TABLE IF NOT EXISTS`,
a no-op against the existing table, planned again on every run. Every offending model is listed,
so they can all be fixed in one pass.

Each line names every list the table matches, because the fix depends on all of them. Two lists
have a per-connection off switch: an `ignore_tables:` entry can be removed, and a default entry can be
listed under `unignore_defaults:` (#818). Either only helps a table the registry does not also hide,
and the default entry is the one the connection already reads with, so a table it lists under
`unignore_defaults:` is never reported here at all. The registry, and the default's own entries
(`pormg_migrations`, the engine's tables), cannot be switched off, so under them the fix is
`managed = false`, or a table name outside the prefix. A renamed table is a new, empty table, and the
existing rows are not moved.

These are the configuration lists and nothing else. `check`'s per-call `ignore_table=` stays a
live-side filter (#738), so `check(kinds = [:schema_drift])` refuses exactly what `makemigrations`
would. Called after `_exclude_unmanaged_models!`, so a `managed = false` model, the sanctioned way to
query a table PormG does not migrate, is never reported.
"""
function _refuse_managed_models_on_ignored_tables(current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}},
                                                  conn, settings::PormGSettings)::Nothing
  # #818: the default this connection reads with — the built-in list less its `unignore_defaults:`.
  default_list = _backend_ignore_tables(conn, settings)
  default_name = _backend_ignore_tables(conn) === sqlite_ignore_schema ? "sqlite_ignore_schema" : "postgres_ignore_table"
  # Most specific first, which is the order each line names its matches in.
  sources = (
    (:connection, Configuration._configured_ignore_tables(settings),
     entry -> "ignore_tables entry \"$(entry)\" (connection.yml)"),
    (:registry, _EXTRA_IGNORE_TABLES[],
     entry -> "\"$(entry)\", registered with `register_ignore_tables!`"),
    (:default, default_list,
     entry -> "\"$(entry)\" in PormG's default ignore list (`$(default_name)`)"),
  )
  problems = String[]
  declared = false       # whether any problem is a model the user wrote, rather than a synthesized one
  join_table = false
  removable = false      # a table only `ignore_tables:` hides, so removing the entry fixes it
  unignore = String[]    # default entries that alone (with `ignore_tables:`) hide a table, and can be switched off (#818)
  locked = Set{Symbol}() # the lists with no off switch that hide a declared model
  locked_defaults = Set{String}()   # built-in entries no connection may remove that hide a declared model
  for (table, entry) in current_schema
    hits = Tuple{Symbol, String}[]
    default_entries = String[]
    for (source, prefixes, describe) in sources
      if source === :default
        # Every match, not the first: built-in entries overlap (`django_` and `django_celery_`), and
        # `unignore_defaults:` must name all of them before the table comes back (#818).
        default_entries = [prefix for prefix in prefixes if startswith(String(table), prefix)]
        isempty(default_entries) || push!(hits, (source, join(describe.(default_entries), " and ")))
      else
        matched = findfirst(prefix -> startswith(String(table), prefix), prefixes)
        matched === nothing || push!(hits, (source, describe(prefixes[matched])))
      end
    end
    isempty(hits) && continue
    # A default entry no connection may remove leaves the default list locked for this table.
    locked_entries = filter(e -> e in Configuration._UNREMOVABLE_IGNORES, default_entries)
    default_locked = !isempty(locked_entries)
    model = entry[:model]
    # A ManyToManyField's auto join table is synthesized, so `managed = false` cannot be written on
    # it: it is managed whenever either end is. Its own fix is a `db_table` outside the prefix.
    what = if haskey(model.cache, "many_to_many_auto")
      join_table = true
      "the auto join table of a ManyToManyField (table \"$(table)\"; give the field a `db_table` outside the prefix, or declare an explicit `through` model)"
    else
      declared = true
      any(hit -> hit[1] === :registry, hits) && push!(locked, :registry)
      union!(locked_defaults, locked_entries)
      "$(model.name) (table \"$(table)\")"
    end
    all(hit -> hit[1] === :connection, hits) && (removable = true)
    # Switchable on this connection alone: no registry hit, and a default entry `unignore_defaults:`
    # accepts. Any `ignore_tables:` entry for the same table has to go too, which the fix says.
    if !isempty(default_entries) && !default_locked && !any(hit -> hit[1] === :registry, hits)
      append!(unignore, default_entries)
    end
    push!(problems, "  - $(what) matches $(join(last.(hits), " and "))")
  end
  isempty(problems) && return nothing
  fixes = String[]
  declared && push!(fixes, "declare each model with `managed = false` to query its table without migrating it")
  join_table && push!(fixes, "apply the fix named on a join-table line")
  if !isempty(locked) || !isempty(locked_defaults)
    names = String[]
    :registry in locked && push!(names, "`register_ignore_tables!`")
    isempty(locked_defaults) || push!(names,
      "the built-in $(join(("\"$(e)\"" for e in sort!(collect(locked_defaults))), " and ")) " *
      (length(locked_defaults) == 1 ? "entry" : "entries"))
    push!(fixes, "give the model a table name (or `db_table`) outside the prefix, since " *
                 "$(join(names, " and ")) cannot be switched off (a new, empty table: the existing rows are not moved)")
  end
  removable && push!(fixes, "remove the entry from `ignore_tables:` for a table no other list names, to let PormG migrate it")
  if !isempty(unignore)
    entries = join(("\"$(e)\"" for e in sort!(unique(unignore))), ", ")
    push!(fixes, "list $(entries) under `unignore_defaults:` in this connection's connection.yml, and drop any " *
                 "`ignore_tables:` entry for the same table, to let PormG read and migrate it; every other table " *
                 "under a listed prefix becomes visible too, and one no model declares is planned for removal")
  end
  fix = length(fixes) == 1 ? only(fixes) :
    join(fixes[1:end-1], ", ") * ", or " * fixes[end]
  throw(InvalidConfigurationError(
    "Cannot plan the migration: a managed model's table matches an ignore list, so PormG would " *
    "never read it and would plan to create it on every run:\n" *
    "$(join(sort!(problems), "\n"))\n" * _emsg(uppercasefirst(fix) * ".")))
end

"""
    _refuse_constrained_keys_into_unmanaged(current_schema)

Raise `InvalidMigrationError` when a managed model's foreign key into an unmanaged model would render
a database constraint (#741) — `Models.constrained_key_into_unmanaged`, the predicate `set_models`
applies at registration. The planner needs its own copy of the check because `makemigrations` never
calls `set_models` (`_load_current_models`), and without it the plan would carry a `REFERENCES` into
a table PormG does not own, or into a view, which the database refuses at `migrate`. Every offending
key is listed, so they can all be fixed in one pass.

A target still held as an unresolved String is skipped: `_resolve_fk_targets_and_pk!` is best-effort,
and such a key fails on its own terms where its parent is rendered.
"""
function _refuse_constrained_keys_into_unmanaged(current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}})::Nothing
  problems = String[]
  for (_, entry) in current_schema
    model = entry[:model]
    for (field_name, field) in pairs(model.fields)
      field isa Models.sRelationalColumn || continue
      Models.constrained_key_into_unmanaged(model, field, field.to) || continue
      push!(problems, "  - $(model.name).$(field_name) $(Models._unmanaged_key_problem(field.to))")
    end
  end
  isempty(problems) && return nothing
  throw(InvalidMigrationError(
    "Cannot plan the migration: a managed model's foreign key would render a constraint into a table " *
    "PormG does not migrate:\n$(join(sort!(problems), "\n"))\n" * _emsg(Models._UNMANAGED_KEY_FIX)))
end

# ---
# Public API (makemigrations)
# ---

# #28: a specialized PostgreSQL type declared on a SQLite connection is refused HERE, for every
# managed model, before anything is diffed. `Dialect.field_to_column` refuses the same fields, but it
# only runs for a column the plan renders — and on SQLite these fields compile to `CText` (their
# column spec exists for the compiler only), so re-declaring an existing `TEXT` column as one is an
# empty delta that renders nothing. The model would then run on SQLite with text semantics, which is
# exactly the emulation the rule forbids. The rule is "a model that DECLARES one cannot be planned on
# SQLite", not "a column that is RENDERED". Sorted, so the field it names does not depend on Dict order.
# #1129: on every backend, not SQLite by name — each declared field is asked of the capability
# table (`Dialect._refuse_unsupported_type`), so a backend that has the feature passes and one that
# lacks it refuses the first declaration.
function _refuse_unsupported_fields(current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}},
                                   conn)::Nothing
  conn isa PormGBackend || return nothing
  for table in sort!(collect(keys(current_schema)))
    model = current_schema[table][:model]
    for name in sort!(collect(keys(model.fields)))
      Dialect._refuse_unsupported_type(conn, Models.field_db_column(model.fields[name], string(name)), model.fields[name])
    end
  end
  return nothing
end

# #29: an `Index` with an access method or an operator class is PostgreSQL-only, and on SQLite it is
# refused HERE, for every managed model, before anything is diffed — the planner half of the #648 rule
# above. `Dialect.create_index(::PormGSQLite)` refuses the same declaration, but only for an index the
# plan creates: one that matches nothing live renders nothing, and the model would then run on SQLite
# as if it had the index it declared. A descending column is core and is not refused. Sorted by table,
# then in declaration order, so the index it names does not depend on Dict order.
function _refuse_unsupported_indexes(current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}},
                                    conn)::Nothing
  # #1129: any backend without the feature, not SQLite by name.
  (conn isa PormGBackend && !_supports(conn, :index_methods)) || return nothing
  for table in sort!(collect(keys(current_schema)))
    model = current_schema[table][:model]
    for ix in get(get(model.cache, "composite_indexes", Dict{String, Any}()), "indexes", Models.Index[])
      what = ix.method != "btree" ? "method = \"$(ix.method)\"" :
             any(!isnothing, ix.opclasses) ? "opclasses = $(Tuple(ix.opclasses))" :
             !isempty(ix.include) ? "include = $(Tuple(ix.include))" : nothing   # #934
      what === nothing && continue
      throw(_capability_error(conn, :index_methods,
        "The Index over $(Models._index_label(ix)) on model '$(model.name)', declared with $(what),";
        why = "PormG refuses it rather than create a different index."))
    end
  end
  return nothing
end

"""
    get_migration_plan(live::Vector{LiveTable}, current_schema, conn, settings; interactive = true, renames = [])
    get_migration_plan(models::Vector{PormGModel}, current_schema, conn, settings; interactive = true, renames = [])

Diff the model definitions against the live database schema and return the DDL that would
reconcile them, as an `OrderedDict{Symbol, OrderedDict{String, String}}` — model name ⇒
ordered (human description ⇒ SQL statement). It only *computes* the plan; nothing is written
or executed. [`makemigrations`](@ref) is the entry point that drives it.

!!! warning "The two schema arguments read backwards"
    `models` is the **old** schema, reverse-engineered from the database. `current_schema` is
    the **new** state defined in your `models.jl`. The names predate the current terminology
    and are kept to avoid churning the planner's unit tests.

The live side is a vector of `LiveTable`s — what `read_live_schema` returns — and the diff
runs on their `ColumnSpec`s directly (#522): no `PormGField` is reconstructed from the catalog. The
`Vector{PormGModel}` form reads each model as a live table through `live_table`; it exists
for callers that already hold models (the planner's own tests hand-build the live side that way) and
is not what `makemigrations` uses.

An empty live side means an empty database, so every model becomes a `CREATE TABLE`.

With `interactive = true` (the default) a model with no matching table prompts whether it is
new or a rename of a table that disappeared, so a rename keeps its data. Answer `yes` for a new
table, or the number of the table it was renamed from; `no` asks for that number on its own. A model
is not asked when every vanished table has already been claimed by an earlier answer. A field with no
matching column is asked the same way, by number or `no`.

The candidates are ranked by the column IR (#735). A table is listed by how many of the model's
columns it holds with the same definition, most first, so `(k of n columns match)`. A field lists the
removed columns with the same definition first, and every other one names what renaming it would
also change. Nothing is filtered out. The models are asked about in table-name order, and their fields
in declaration order. An auto many-to-many join table, and the column named after a renamed end,
follow that end's rename without a question when exactly one vanished table or column fits.

`renames` names renames without a question (#734): `"old_table" => "new_table"`, and
`"table.old_column" => "table.new_column"` with the table's new name. Every name is physical
(`db_table`, `db_column`). A hint wins over the prompt. A hint whose old name is gone and whose new
one exists has already run, and does nothing; one naming neither warns. `InvalidMigrationError` is raised for a hint that contradicts the schema: both names exist,
the old one is still declared, the new one is not declared, or two hints share a name.
`"old" => nothing` says the old one is not a rename: it is dropped and offered to no question.

`interactive = false` answers "new table" and "not a rename" for every unhinted pair, except a pair
with the **same definition**: a vanished table holding exactly the model's columns (one besides its key, at least), or a removed
column identical to the added one. That is the shape of a rename, so the run raises
`InvalidMigrationError` listing every such pair and the hint that decides it, rather than dropping
the rows. `fail_closed = false` turns that off; `check(kinds = [:schema_drift])` uses it, because it
reports such a pair as drift.

Any answer the prompt does not recognise — an empty line, a typo, an unlisted number — raises
`InvalidMigrationError`, and so does reaching the end of input (#726). The prompts read `stdin`
whenever `interactive = true`; unlike [`migrate`](@ref), nothing checks for a terminal, because
answers piped in through a non-terminal stdin are read like typed ones. A script or CI job that has
no answers to give passes `interactive = false`.

A chosen rename plans `ALTER TABLE "<old>" RENAME TO "<new>"` under the new model's key, plus that
table's column changes diffed against the old live table (#615). The rename executes before every
column statement (see `_order_statements`), so those changes name the new table; only the plan-time
catalog lookups ask for the old one.

Tables whose foreign key points at the renamed model plan nothing for it (#678): both engines carry
the constraint across the rename, so the live references are retargeted to the new name before any
table is diffed (see `_retarget_references`). That is why every table-rename question is asked
before any field-rename question. A child that also changes its key — a different `on_delete`, say —
still re-points, against the new name, after the rename has run.
"""
function get_migration_plan(models::Vector{PormGModel}, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, conn, settings::PormGSettings; interactive::Bool = true,
                            lossy_alters::Vector{LossyAlter} = LossyAlter[],
                            schema_scope::Union{Set{String}, Nothing} = nothing,
                            renames::AbstractVector = Pair{String, Union{String, Nothing}}[],
                            fail_closed::Bool = true)
  # The adapter (#522): a `PormGModel` read as a live table — see `live_table` for what it keeps.
  return get_migration_plan(LiveTable[live_table(model, conn) for model in models], current_schema,
                            conn, settings; interactive = interactive, lossy_alters = lossy_alters,
                            schema_scope = schema_scope, renames = renames, fail_closed = fail_closed)
end

function get_migration_plan(live::Vector{LiveTable}, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, conn, settings::PormGSettings; interactive::Bool = true,
                            lossy_alters::Vector{LossyAlter} = LossyAlter[],
                            schema_scope::Union{Set{String}, Nothing} = nothing,
                            renames::AbstractVector = Pair{String, Union{String, Nothing}}[],
                            fail_closed::Bool = true)
# `live` is the schema as the database holds it; `current_schema` is the models file (see the docstring).

# #734: parsed before anything else, so a malformed hint is refused even when nothing would use it.
hints = _parse_rename_hints(renames)
migration_plan = OrderedDict{Symbol, OrderedDict{String, String}}()
futher_processing = Dict{Symbol, OrderedDict{Symbol, Any}}()
current_schema = Models.synthesize_many_to_many_through_models(current_schema, settings)
# #741: an unmanaged model leaves the plan here — out of `current_schema` and, below, its table out of
# the live list the planner classifies. After the synthesis on purpose: it resolves many-to-many
# targets against the whole schema and decides whether an auto join table is itself unmanaged.
# `all_live` keeps the unfiltered side for the whole-plan checks at the end, which must still see an
# unmanaged table's index names and a SQLite view that reads it.
unmanaged_tables = _exclude_unmanaged_models!(current_schema)
_refuse_constrained_keys_into_unmanaged(current_schema)
_refuse_managed_models_on_ignored_tables(current_schema, conn, settings)
_refuse_unsupported_fields(current_schema, conn)
_refuse_unsupported_indexes(current_schema, conn)
all_live = live
isempty(unmanaged_tables) || (live = LiveTable[t for t in all_live if !(t.name in unmanaged_tables)])
# #739: the tables this diff compares — every managed declared table (many-to-many join tables
# included, synthesized above) and every live table it classifies. Reported to `makemigrations`,
# which records the fingerprint of each in the plan header as `migrate`'s precondition. An
# unmanaged table is in neither set: the plan never touches it, so it is no part of what the plan
# assumes. `current_schema` is keyed by physical table name (#59), like the live side.
schema_scope === nothing ||
  union!(schema_scope, (String(k) for k in keys(current_schema)), (t.name for t in live))
# #161: every model-level index name the plan creates or renames to, across all tables — the scope
# the database enforces. See `_claim_composite_target!`.
composite_targets = Dict{String, Tuple{String, String}}()

# an empty live side: every declared model is a new table. `all_live`, not `live`: a database holding
# only unmanaged tables is not empty, and takes the full path below so the whole-plan checks run.
if isempty(all_live)
  # By table name, not `Dict` order (#735), so two runs over one models file write one plan.
  for model_name in sort!(collect(keys(current_schema)), by = String)
    _add_new_table(conn, migration_plan, model_name, current_schema[model_name][:model]; composite_targets = composite_targets)
  end
  return migration_plan
end

@pormg_debug false

# #678: the plan is built in three passes — classify the live tables, DECIDE every table rename, then
# diff. The diff used to run inside this first loop, before any rename was known, so a table whose key
# pointed at a renamed one compared live `REFERENCES "<old>"` against declared `REFERENCES "<new>"` and
# re-pointed a constraint the rename carries along anyway — a `DROP CONSTRAINT` (or a SQLite child
# rebuild) that made a pure rename destructive. Deciding first costs one thing: the table-rename
# questions are now all asked before any field-rename question. The plan's insertion order is unchanged.
matched = LiveTable[]
for table in live
  # The live table's catalog name, symmetric with how `get_all_models` keys `current_schema` by the
  # resolved physical name (#59) — so the two sides of the diff are keyed the same way.
  model_name = Symbol(table.name)
  @pormg_debug false
  if haskey(current_schema, model_name)
    current_schema[model_name][:exist] = true
    push!(matched, table)
  else
    # Ordered (#615): the rename prompt numbers these candidates, so they enumerate in the live
    # catalog's order rather than in `Dict` hash order. The printed list and the number→table lookup
    # always agreed within one run; what hash order broke was scripted answers (and the tests), since
    # "1" could name a different table from one run to the next.
    if !haskey(futher_processing, :drop_table)
      futher_processing[:drop_table] = OrderedDict{Symbol, Any}(model_name => Dict{String, Any}("model" => table, "exist" => false))
    else
      futher_processing[:drop_table][model_name] = Dict{String, Any}("model" => table, "exist" => false)
    end
  end
end

@pormg_debug false

# Check for models in the current schema that are not in the models. This pass only DECIDES (#678):
# `decisions` holds `model => nothing` for a new table and `model => <old name>` for a rename, in the
# order the questions were answered, and the plan is emitted from it below — after the diff, exactly
# where it used to be written.
decisions = Pair{Symbol, Union{Symbol, Nothing}}[]
# #735: asked in a FIXED order — the declared models by table name, then the auto join tables, which
# can follow a rename decided for one of their ends. It used to be `current_schema`'s `Dict` order, so
# adding an unrelated model could reorder the questions under a script's answers. Declaration order
# is not recoverable here: `get_all_models` reads the bindings through `names`, which sorts them.
unmatched = sort!([name for (name, entry) in current_schema if entry[:exist] == false],
                  by = name -> (_is_auto_join_table(current_schema[name][:model]), String(name)))
# #734: the table hints, resolved against both sides. A hinted rename source is reserved for its model
# and a `=> nothing` one is dropped, so neither is offered to any other model, or to `fail_closed`.
hint_renamed, hint_dropped = _resolve_table_hints(hints, Set{String}(t.name for t in live), current_schema)
reserved = union(Set{Symbol}(values(hint_renamed)), hint_dropped)
# #734: every likely rename `interactive = false` refuses to guess, reported together at the end.
rename_problems = String[]
for model_name in unmatched
  model = current_schema[model_name][:model]
  # The vanished tables no earlier answer has claimed. With none left there is nothing to rename FROM:
  # the model is a new table, and nothing is asked (#726).
  unclaimed = haskey(futher_processing, :drop_table) ?
    Symbol[name for (name, info) in futher_processing[:drop_table] if !info["exist"] && !(name in reserved)] : Symbol[]
  # Every hinted rename is known up front, so it is applied whatever the order: a child of a table
  # hinted later in the name order must still compare its keys against the parent's new name.
  renames_so_far = Dict{String, String}(string(old) => string(new) for (new, old) in hint_renamed)
  merge!(renames_so_far, Dict{String, String}(string(old) => string(new) for (new, old) in decisions if old !== nothing))
  old_model_name = nothing
  if haskey(hint_renamed, model_name)
    # A hint wins over every question (#734).
    old_model_name = hint_renamed[model_name]
  elseif !isempty(unclaimed) && _is_auto_join_table(model)
    old_model_name = _join_table_rename_source(model, unclaimed, futher_processing[:drop_table], renames_so_far, conn)
    old_model_name === nothing ||
      @info("The join table \"$(model_name)\" follows its model's rename: renaming \"$(old_model_name)\" to it.")
  end
  if old_model_name === nothing && interactive && !isempty(unclaimed)
    # Ranked against the references as the renames decided so far leave them (#735).
    candidates, list_to_question = _ranked_table_candidates(model, unclaimed,
      OrderedDict{Symbol, Any}(name => Dict{String, Any}("model" => _retarget_references(futher_processing[:drop_table][name]["model"], renames_so_far))
                               for name in unclaimed), conn)
    # Only the answer is parsed inside `_ask_table_rename`; a genuine planner failure later propagates
    # as itself, not as "invalid choice" (#197).
    old_model_name = _ask_table_rename(model_name, candidates, list_to_question)
  elseif old_model_name === nothing && !interactive && fail_closed && !haskey(hint_renamed, model_name)
    # #734: a vanished table holding exactly the model's columns, each with the same definition, is
    # almost certainly the model under its old name. Dropping it would lose its rows, so it is not
    # guessed in either direction: the run refuses, and names the hint that decides it. A model
    # declaring nothing but its key is no such signal — every table has one — so it is not refused.
    key_only = !any(f -> !_slot(f, :primary_key, false), values(model.fields))
    for old in (key_only ? Symbol[] : unclaimed)
      live_old = _retarget_references(futher_processing[:drop_table][old]["model"], renames_so_far)
      matching, declared = _table_match_count(model, live_old, conn)
      (matching == declared && length(live_old.columns) == declared) || continue
      push!(rename_problems, "  - table \"$old\" → \"$model_name\": pass " * _rename_hint_fix(String(old), String(model_name)))
    end
  end
  push!(decisions, model_name => old_model_name)
  # Marked now, not when the plan is emitted: the next model's candidate list must not
  # offer a table this one has already claimed.
  old_model_name === nothing || (futher_processing[:drop_table][old_model_name]["exist"] = true)
end

# #678: every rename is known now, so retarget the live references before anything is diffed. A
# child whose key points at a renamed table then compares converged — the rename carries its
# constraint — and one that ALSO changed its key still differs, and re-points against the new name.
# The rename sources are retargeted too: a table can reference itself, or another renamed table.
table_renames = Dict{String, String}(string(old) => string(new) for (new, old) in decisions if old !== nothing)
retarget(t::LiveTable) = _retarget_references(t, table_renames)

# #729: each diffed table's catalog name and rename map, for the SQLite rebuild pass at the end.
sqlite_rebuild_context = Dict{Symbol, Tuple{Symbol, Dict{String, String}}}()

for table in matched
  _alter_table_fields(conn, migration_plan, Symbol(table.name), retarget(table), current_schema, settings, interactive=interactive,
                      composite_targets = composite_targets, sqlite_rebuild_context = sqlite_rebuild_context,
                      lossy_alters = lossy_alters, hints = hints, fail_closed = fail_closed,
                      rename_problems = rename_problems)
end

for (model_name, old_model_name) in decisions
  if old_model_name === nothing
    _add_new_table(conn, migration_plan, model_name, current_schema[model_name][:model]; composite_targets = composite_targets)
  else
    # #615: the rename runs FIRST (its own bucket in `_order_statements`, whose docstring
    # records why), so the table's column work is planned against the NEW name — `model_name`,
    # which is also the key `current_schema` holds it under — and diffed against the OLD live
    # table, whose `name` is what `_alter_table_fields` hands every catalog lookup. The old
    # code passed the old name here, and `current_schema[old]` raised before anything was
    # planned; the call below also passed `(new::Symbol, old)` to a `(old::String, new::String)`
    # method. Registered under `model_name`, like the column work it precedes.
    _alter_table_fields(conn, migration_plan, model_name, retarget(futher_processing[:drop_table][old_model_name]["model"]), current_schema, settings, interactive=interactive,
                        composite_targets = composite_targets, sqlite_rebuild_context = sqlite_rebuild_context,
                        lossy_alters = lossy_alters, hints = hints, fail_closed = fail_closed,
                        rename_problems = rename_problems)
    _configure_order_dict_migration_plan(migration_plan, model_name, "Rename table", Dialect.rename_table(conn, string(old_model_name), string(model_name)))
  end
end

# #734: refused as a whole, before anything is written. Django never renames under `--noinput`, and
# PormG used to do the same: drop + add, which loses the rows. A pair with the same definition is the
# shape of a rename, so a non-interactive run no longer picks a side for the user.
isempty(rename_problems) || throw(InvalidMigrationError(
  "makemigrations(interactive = false) will not guess a rename. These look like one — the same " *
  "definition under a new name:\n$(join(rename_problems, "\n"))\n" *
  _emsg("Add the hints to `renames = [...]` and run it again.")))

@pormg_debug false

# at last check all models in futher_processing to drop
dropped_tables = Set{String}()
if haskey(futher_processing, :drop_table)
  for (model_name, model_info) in futher_processing[:drop_table]
    if model_info["exist"] == false
      _configure_order_dict_migration_plan(migration_plan, model_name, "Drop table", Dialect.drop_table(conn, model_name))
      push!(dropped_tables, string(model_name))
    end
  end
end

# #754: a table the plan drops must not still be read by a view or a trigger. First of the whole-plan
# refusals, so a rebuild whose carried view names the dropped table is reported by its cause.
_refuse_dropped_table_dependents(conn, dropped_tables)

# #161: a name this plan creates must not still be held by another table's index.
_check_composite_targets_free(conn, composite_targets, all_live, dropped_tables, table_renames)

# #729: every rename and drop is known now, so each SQLite rebuild can be rendered with its indexes,
# triggers and views — and refused here, before a plan is written, where one of them would go stale.
_finalize_sqlite_rebuilds!(conn, migration_plan, current_schema, sqlite_rebuild_context;
                           live = all_live, table_renames = table_renames, dropped_tables = dropped_tables)

# println(migration_plan)


return migration_plan
end

"""
    makemigrations(db::String; models_file = nothing, interactive = true, renames = [])
    makemigrations(connection, settings::PormGSettings; path = "db/models.jl", interactive = true, renames = [])

Compare your `models.jl` against the live database and **write** the pending migration plan.
The first form is the one to call: `db` is a connection key from your configuration, e.g.
`makemigrations("db")`.

It does **not** touch the schema. The generated DDL lands in
`<db_def_folder>/migrations/pending_migrations.jl` for review; apply it with
`PormG.Migrations.migrate(db)`.

# Keyword arguments
- `models_file` (`String` form): the models file to diff against. Defaults to
  `<db>/<settings.model_file>`; a relative path resolves against the working directory. Name an
  **older** models file — one checked out from git, say — and the plan takes the database back to
  that state: that is how PormG reverts, since it has no `rollback`. The plan header records a
  non-default file, and `migrate` snapshots that file as the applied migration's `_old_models.jl`.
  See [Reverting by declaring the old state](@ref).
- `path` (connection form): the models file, as given.
- `interactive`: when `true`, a model with no matching table prompts whether it is a new
  table or a rename of one that disappeared — a rename preserves the data. Answer `yes`, or the
  number of the old table. An unrecognised answer, or the end of input, raises
  `InvalidMigrationError`; no terminal is detected, so a script or CI job with no answers to give
  must pass `false`. `false` asks nothing: an unhinted pair is planned as new, except a pair with
  the same definition (a likely rename), which raises `InvalidMigrationError` naming the hint that
  decides it (#734).
- `renames`: the renames to plan without a question, e.g.
  `renames = ["drivers" => "driver", "result.statusid" => "result.racestatusid"]` — physical
  names, a column with its table's new name. `"old" => nothing` drops the old one instead. A hint
  that has already run does nothing; one that contradicts the schema raises
  `InvalidMigrationError`. See [`get_migration_plan`](@ref).

Returns `nothing`. Logs and returns early — writing no plan — when the connection has
`change_db: false`. An up-to-date schema logs that no migrations are pending, and moves an earlier
`pending_migrations.jl` aside to `pending_migrations.jl.discarded` (through
[`discard_pending_migration`](@ref)), since that plan no longer describes any change (#727). The one
exception is a plan a previous `migrate` already applied but failed to archive — its checksum
matches the latest applied migration — which is kept, with a warning, for the next `migrate` to
archive without re-applying. A missing models file raises `MissingConfigurationError` (the
`String` form). A failure reading the live schema raises the read's own error and writes no plan
(#1018); an empty database is not a failure — it reads as no tables, and every model is planned.

On PostgreSQL, reading the schema needs PostgreSQL 11, and a plan holding a statement the server
cannot run raises `BackendCapabilityError` and writes nothing (#1146): adding a generated column
(`generated_from`) needs PostgreSQL 12, and removing `generated_from` (`DROP EXPRESSION`) needs 13.

A pending plan holding hand-written data steps — entries labelled `Data (pre): …` or
`Data (post): …` — is neither overwritten nor moved aside: those steps exist only in that file, so
`makemigrations` raises `InvalidMigrationError` naming them instead (#740). Apply the plan with
[`migrate`](@ref) first, or move the steps out of it, then plan again.

See also [`migrate`](@ref), [`get_migration_plan`](@ref), and the
[Database Migrations in PormG](@ref) guide.
"""
function makemigrations(connection::PormGPostgres, settings::PormGSettings; path::String = "db/models.jl", interactive::Bool = true,
                        renames::AbstractVector = Pair{String, Union{String, Nothing}}[])
# #683: the plan is written under `db_def_folder`, which a `register_connection` entry only labels.
Configuration._require_folder_backed(settings, "makemigrations")
if !settings.change_db
  @warn("Schema changes are disabled (`change_db: false`). Set `change_db: true` in your db/connection.yml under the active environment to allow migrations.")
  return
end
@pormg_debug false
# #522: the live side is read straight into `LiveTable`s; `convert_schema_to_models` (which builds
# `PormGModel`s on top of them) is `inspectdb`'s form and is not called here.
# #749: the connection's own `ignore_tables:` rides on top of the backend default, less the entries its
# `unignore_defaults:` removes (#818).
ignore = _with_connection_ignores(_backend_ignore_tables(connection, settings), settings)
# #1018: a failed read raises, as it does for `migrate`'s precondition and `check()`. It used to be
# logged and swallowed — `nothing`, the value a successful run returns — under a text match for an
# "empty database" error nothing raised: an empty database reads as no tables, and plans them all.
live_schema = read_live_schema(connection; ignore_table = ignore)

# get module from the path (load + resolve FK targets + default pk_field — #62)
current_models = _load_current_models(path)

@pormg_debug false

# #803: the plan's lossy column changes, recorded where each delta becomes an action.
lossy_alters = LossyAlter[]
# #739: the tables the diff compares, and their fingerprints as read — before the planner runs.
schema_scope = Set{String}()
live_fingerprints = _schema_table_fingerprints(live_schema, (t.name for t in live_schema))
migration_plan = get_migration_plan(live_schema, current_models, connection, settings, interactive=interactive,
                                    lossy_alters = lossy_alters, schema_scope = schema_scope, renames = renames)
# #1146: a plan this server cannot run is refused before it is written, not when `migrate` reaches it.
# Here and not in `get_migration_plan`: `check(kinds = [:schema_drift])` plans the same diff, and
# reports the step as drift rather than raising.
_refuse_statements_above_server(connection, String[sql for steps in values(migration_plan) for sql in values(steps)])

@pormg_debug false

_write_pending_plan(connection, settings, migration_plan; models_path = path, lossy_alters = lossy_alters,
                    schema_tables = _scoped_fingerprints(live_fingerprints, schema_scope))
return nothing
end

function makemigrations(connection::PormGSQLite, settings::PormGSettings; path::String = "db/models.jl", interactive::Bool = true,
                        renames::AbstractVector = Pair{String, Union{String, Nothing}}[])
  Configuration._require_folder_backed(settings, "makemigrations")
  if !settings.change_db
    @warn("Schema changes are disabled (`change_db: false`). Set `change_db: true` in your db/connection.yml under the active environment to allow migrations.")
    return
  end
  
  # #522: the live side is read straight into `LiveTable`s (see the PostgreSQL method above).
  ignore = _with_connection_ignores(_backend_ignore_tables(connection, settings), settings)
  live_schema = read_live_schema(connection; ignore_table = ignore)   # #1018: raises, see above

  # get module from the path (load + resolve FK targets + default pk_field — #62)
  current_models = _load_current_models(path)

  lossy_alters = LossyAlter[]   # #803: see the PostgreSQL method above
  schema_scope = Set{String}()  # #739: see the PostgreSQL method above
  live_fingerprints = _schema_table_fingerprints(live_schema, (t.name for t in live_schema))
  migration_plan = get_migration_plan(live_schema, current_models, connection, settings, interactive=interactive,
                                      lossy_alters = lossy_alters, schema_scope = schema_scope, renames = renames)

  _write_pending_plan(connection, settings, migration_plan; models_path = path, lossy_alters = lossy_alters,
                      schema_tables = _scoped_fingerprints(live_fingerprints, schema_scope))
  return nothing
end

# The tail both `makemigrations` methods end with (#727): afterwards the pending file describes the
# current diff and nothing else. A non-empty plan overwrites it. An EMPTY plan used to only log "No
# migrations are pending" and leave any earlier plan on disk, so `status().pending` stayed true and
# a later `migrate()` applied changes the models no longer declare. It is now moved aside through the
# same `discard_pending_migration` a user would call, so it stays recoverable as `.discarded`. One
# helper for both engines: the tail used to be copied into each method, which is how one could be
# fixed and the other not.
#
# One pending plan is NOT stale on an empty diff: the one a `migrate()` COMMITted and then failed to
# archive (#81). The empty diff is that plan's own effect, and the next `migrate()` recognises it by
# checksum and archives it without re-applying — under the advisory lock, which `makemigrations`
# does not take. So it is left where it is, and the message says what to do; discarding it would
# lose its `applied_migrations/` archive and models snapshot.
function _write_pending_plan(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                             migration_plan::OrderedDict{Symbol, OrderedDict{String, String}};
                             models_path::Union{String, Nothing} = nothing,
                             lossy_alters::Vector{LossyAlter} = LossyAlter[],
                             schema_tables::Union{AbstractDict{String, String}, Nothing} = nothing)::Nothing
  folder = joinpath(settings.db_def_folder, "migrations")
  if isempty(migration_plan)
    if isfile(joinpath(folder, "pending_migrations.jl"))
      if _pending_plan_already_applied(connection, settings)
        @warn("No changes detected. The pending plan was already applied by a previous migrate(), which failed to archive it (its checksum matches the latest applied migration), so it is kept: run migrate() to archive it — with destructive = true if the plan is destructive, since that guard runs first. It is archived, not applied again.")
        return nothing
      end
      # #740: an empty diff is the LIKELY case for a plan holding only data steps — the models and
      # the database already agree, and the steps are the plan's whole point.
      _refuse_overwriting_data_steps(settings)
      @warn("No changes detected, so the earlier pending plan no longer describes anything; moving it aside.")
      discard_pending_migration(settings; backup = true)
    end
    @info(_emsg("\e[32mYour database schema is already up-to-date. No migrations are pending.\e[0m"))
    return nothing
  end
  ispath(folder) || mkdir(folder)
  _refuse_overwriting_data_steps(settings)   # #740
  header = _models_file_header_value(settings, models_path)
  generate_migration_plan("pending_migrations.jl", migration_plan, folder; models_file = header,
                          models_file_sha256 = header === nothing ? nothing : _models_file_digest(models_path),
                          lossy_alters = lossy_alters, schema_tables = schema_tables)
  # #803: named here, at plan time, as well as by `dry_run` and `migrate` — which also count the rows.
  if !isempty(lossy_alters)
    @warn("The plan has $(length(lossy_alters)) change(s) that can fail on, or change, existing rows. Run dry_run() to see which, and how many rows each would fail on.",
          findings = [_lossy_alter_summary(f) for f in lossy_alters])
  end
  @warn("The migration plan has been saved to '$(settings.db_def_folder)/migrations/pending_migrations.jl'. Review the plan before applying the migrations.")
  # The KEY, not the folder: `migrate(db::String)` looks its argument up as a key, and under
  # `load(…; root)` the folder is an absolute path no entry is keyed by (#857).
  key = Configuration._settings_key(settings)
  @info(_emsg("\e[32mMigration plan generated successfully. Run 'PormG.Migrations.migrate($( key == DB_PATH ? "" : string("\"", key, "\"")))' to apply the migrations.\e[0m"))
  return nothing
end

# The plan header's schema precondition (#739): the fingerprint of every table in `scope`, the
# live one when the database held it and `absent` when it did not. Sorted by name, so two runs over
# one schema write the same header.
_scoped_fingerprints(live::AbstractDict{String, String}, scope::Set{String})::OrderedDict{String, String} =
  OrderedDict{String, String}(name => get(live, name, SCHEMA_TABLE_ABSENT) for name in sort!(collect(scope)))

# What the plan header records as the models file the plan was diffed against (#736): `nothing` when
# that is the connection's own `<db_def_folder>/<model_file>` — the default plan stays byte-identical
# — else a path relative to `db_def_folder` when the file sits under it, or absolute when it does not.
# Relative so a plan generated beside its models file still resolves when `migrate` runs from another
# working directory; `_plan_models_file` in runner.jl is the reader.
function _models_file_header_value(settings::PormGSettings, models_path::Union{String, Nothing})::Union{String, Nothing}
  models_path === nothing && return nothing
  file = abspath(models_path)
  file == abspath(joinpath(settings.db_def_folder, settings.model_file)) && return nothing
  rel = relpath(file, abspath(settings.db_def_folder))
  return first(splitpath(rel)) == ".." ? file : rel
end

# #740: refuse to replace a pending plan that holds hand-written data steps. They exist only in that
# file — the diff can never regenerate them — so overwriting it, or moving it aside on an empty diff,
# would silently drop work someone wrote by hand. Any label that reads like one counts
# (`DATA_STEP_LOOSE_RE`), a misspelt one included: it is hand-written either way, and `migrate` refuses it, so it has to be fixed by hand.
# A plan that does not parse is not refused here: it is not a plan anyone can apply, so the existing
# overwrite or discard (with its `.discarded` backup) goes ahead, as `_pending_plan_already_applied`
# lets it.
function _refuse_overwriting_data_steps(settings::PormGSettings)::Nothing
  isfile(_pending_plan_path(settings)) || return nothing
  plan = try
    _load_migration_plan(settings)
  catch e
    e isa InvalidMigrationError || rethrow()
    return nothing
  end
  labels = String[label for entries in plan for label in keys(entries) if occursin(DATA_STEP_LOOSE_RE, label)]
  isempty(labels) && return nothing
  throw(InvalidMigrationError(
    "The pending plan holds $(length(labels)) hand-written data step(s) — $(join(repr.(labels), ", ")) — " *
    "which makemigrations() cannot regenerate, so it did not overwrite or discard the plan. Apply it " *
    "first with migrate(), or move the steps out of it (or discard it with discard_pending_migration()), " *
    "then run makemigrations() again."))
end

# Whether the pending plan is the latest applied migration — the file a `migrate()` COMMITted and then
# failed to archive (#81). Compared exactly the way `migrate` compares it: the checksum of the ordered
# SQL against `_latest_applied_checksum`. A plan that does not parse (#710's `InvalidMigrationError`)
# is not that file, so it answers `false` and is discarded with a backup; a database error propagates.
function _pending_plan_already_applied(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings)::Bool
  _migrations_table_exists(connection) || return false
  latest = _latest_applied_checksum(connection)
  latest === nothing && return false
  plan = try
    _load_migration_plan(settings)
  catch e
    e isa InvalidMigrationError || rethrow()
    return false
  end
  _, all_sql = _order_statements(plan)
  return compute_checksum(all_sql) == latest
end

function makemigrations(db::String; models_file::Union{AbstractString, Nothing} = nothing,
                        config::Dict{String,PormGSettings} = config, interactive::Bool = true,
                        renames::AbstractVector = Pair{String, Union{String, Nothing}}[])
settings = Configuration.get_settings(db)
# Here as well as in the methods below, and unconditionally: the plan is written under the folder
# whichever models file it is diffed against.
Configuration._require_folder_backed(settings, "makemigrations")
# #736: the resolution `check(kinds = [:schema_drift])` gives its own `models_file` — absolute, so
# `Base.include` cannot resolve it against the calling source file instead of the cwd.
path = _resolve_models_file(settings, models_file, "makemigrations(\"$(db)\")")
makemigrations(settings.connections, settings, path=path, interactive=interactive, renames=renames)
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
# lifecycles can no longer drift. Both backends call this, and so does `check(kinds = [:schema_drift])`.
# #762: many-to-many targets are resolved here as well — see `_resolve_fk_targets_and_pk!`.
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
# Many-to-many targets are resolved here too, by binding only (#762, below).
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
#
# #762: many-to-many targets are resolved here too, and for the same reason. `.to` names a BINDING,
# but `synthesize_many_to_many_through_models` can only look a String up in the schema dict, whose
# keys are physical tables (#59) and whose models' `name` is the table for `Binding = Model("table", …)`.
# The binding appears in neither, so every app-prefixed M2M target was "not defined" on this path
# alone. Binding lookup only, through the same `_resolve_target_model` the FK arm uses: a name that
# is not a model binding (unbound, or bound to something else, like `Base.position`) returns `nothing`
# and stays a String, which leaves it to the join-table builder's own name lookup, as before.
function _resolve_fk_targets_and_pk!(current_models::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, models_module::Module)::Nothing
  for (_, entry) in current_models
    model = entry[:model]
    model isa PormGModel || continue
    for (field_name, field) in pairs(model.fields)
      if Models.is_many_to_many_field(field)
        field.to isa AbstractString || continue
        target = Models._resolve_target_model(field.to, models_module)
        target === nothing || (field.to = target)
        continue
      end
      field isa Models.sRelationalColumn || continue
      # #65: delegate to the single shared resolver. Best-effort (strict=false): an unresolvable
      # string target is left as-is with a @debug (its verbatim db-column fallback stays correct),
      # and the pk_field default is skipped — identical to the pre-#65 migration behavior.
      Models.resolve_fk_target!(field, string(field_name), model.name, models_module; strict=false)
    end
  end
  return nothing
end
