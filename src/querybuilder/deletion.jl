# ---
# Django like function to build a delete query with cascade, restrict, set null, set default and set value (AI please don't delete this code)
#

"""
    delete(objct::SQLObjectHandler; show_query=:execute, allow_delete_all=false) -> (total::Int, Dict{String,Integer})

Delete every row the query matches, cascading through foreign-key relationships according to each
referencing field's `on_delete` action. The root delete and every dependent statement run inside one
transaction, so a failure part-way through leaves the database untouched.

# Arguments
- `objct::SQLObjectHandler`: the handler carrying the query and its model.
- `show_query::Symbol = :execute`: `:execute` runs the delete. `:sql`, `:dict`, `:inspection` and
  `:params` build the statements and return them instead of executing them, and `:none` builds and
  discards them — see [`show_query`](@ref). An unrecognized value raises `QueryBuildError` when the
  statements are rendered, which is *after* the guards below have run.
- `allow_delete_all::Bool = false`: permit a delete whose query carries no filter. Off by default;
  see the guard table below.
- `table_alias::Union{Nothing, SQLTableAlias} = nothing`: accepted for call-signature compatibility
  with the other terminals; the delete path does not read it.
- `connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing`: execute against this connection
  pool instead of the one on the model's settings (those two abstract types are the backend markers
  the concrete pools subtype). Only the pool is overridden; the settings, and therefore the dialect
  and the `change_data` flag, still come from the model's `connect_key`. Whether the delete joins a
  surrounding transaction is decided by the task-local transaction context, not by this argument.

# Returns
- Under `:execute`: `Tuple{Integer, Dict{String, Integer}}` — the total rows deleted and a per-table
  breakdown, e.g. `(1, Dict("just_a_test_deletion" => 1))`. A query matching nothing returns
  `(0, Dict())`; a delete that ran but removed no rows warns.
- Under `:sql`, `:dict`, `:inspection` or `:params`: the built statement(s) — one per statement the
  plan emits, returned bare when the plan is a single statement and as a `Vector` otherwise. A
  cascade can emit several statements for the same table (one `UPDATE` per `SET_NULL` /
  `SET_DEFAULT` field, plus its `DELETE`), so the count tracks statements, not tables.
- Under `:none`: `nothing`.

# Behavior

Every check below runs before any SQL is generated:

| Guard | Raises |
|-------|--------|
| A transaction is open on a connection other than the model's | `TransactionError` |
| The connection is configured `change_data: false` | [`WritesDisabledError`](@ref) |
| The query has `limit()`, `offset()` or `order_by()` set | [`UnsafeMutationError`](@ref) |
| The query has `distinct()` set | [`UnsafeMutationError`](@ref) |
| The query carries `group_by()` / aggregate annotations | [`UnsafeMutationError`](@ref) |
| The query has no filter and `allow_delete_all` is `false` | [`UnsafeMutationError`](@ref) |

The three query-shape guards share one rationale: the deletion collector walks the *complete*
filtered set so row counts, cascades and constraint handling stay deterministic. Any shape that
truncates or collapses that set is refused rather than quietly applied to part of it — there is no
"delete the first N rows" form, so filter by primary key to bound a delete.

Dependent rows are then resolved per referencing field, by that field's `on_delete`:

- `CASCADE`: the dependents are collected and deleted too, recursing into their own dependents.
- `PROTECT` / `RESTRICT`: raises [`ProtectedError`](@ref), naming the referencing model and field.
  The two behave identically apart from the word in the message. The check is existence-driven — it
  fires only when referencing rows are actually present, so an empty reverse relation does not block
  the delete.
- `SET_NULL`: issues `UPDATE ... SET <column> = NULL` over the dependents instead of deleting them.
  Declaring it on a `null = false` field is a contradiction the schema cannot satisfy, and raises
  [`ModelDefinitionError`](@ref).
- `SET_DEFAULT`: issues `UPDATE ... SET <column> = <the field's default>` over the dependents.
  Declaring it on a field with no `default` is the mirror-image contradiction, and raises
  [`ModelDefinitionError`](@ref) too.
- `DO_NOTHING`: PormG emits nothing for the relation and defers to the database's own constraint.

Only `CASCADE` walks further down the graph; `SET_NULL` and `SET_DEFAULT` do not recurse.

Both contradictions are normally caught earlier, at `set_models` registration; the checks here are the
backstop for models that never passed through it.

An **unset** `on_delete` — the default for `ForeignKey` — produces no ORM statement for that relation,
leaving the reference entirely to the database's own constraint. It renders `ON DELETE NO ACTION` in
DDL, so a dependent row is *not* cascaded by PormG unless its field says so explicitly.

A model reachable by several cascade paths is scoped by all of them: its statement carries one
predicate per path, `OR`ed together, and that holds for the `UPDATE` a `SET_NULL` /
`SET_DEFAULT` emits just as it does for a `DELETE`.

Every statement puts the filters on the row being deleted or updated — `DELETE FROM "t" AS "Tb"
WHERE "Tb"."status" = \$1` — rather than only in a `pk IN (SELECT …)` subquery. A filter that
crosses a relation keeps that `pk IN (…)` as its index-driven selection and adds the same filter as a
correlated `EXISTS` on the row. That makes a filter a **fence** on PostgreSQL: if a concurrent
transaction changes a row so it no longer matches while the delete waits on its lock, the row is left
alone (#765). See *Filters are a fence on PostgreSQL* in [Deleting Records](write/delete.md).

On PostgreSQL, before any child statement runs, every collected model that is the parent of an
emitted `DELETE` or `UPDATE` is locked top-down with `SELECT … FOR UPDATE` over the same predicate
its `DELETE` uses, so a parent's own columns cannot change after its children are gone (#770). A
root filter across a relation (`"circuitid__name" => …`) also locks the rows it reads in each
joined table, `SELECT … FOR SHARE`, right after the root's own lock (#771) — except a table of an
unmanaged model (`managed = false`, e.g. a view), which `FOR SHARE` may not be able to lock. A
filter that reads another table through a subquery (`"x__@in" => M.Other.objects…`) is not
pinned. Those lock statements appear in `show_query` and [`inspect_query`](@ref) output as
`:operation => :lock` steps. A delete with nothing to cascade emits no lock, and SQLite emits none
at all.

The cascade descends at most 50 levels. Beyond that it raises `QueryBuildError` naming the models it
walked. Usually that means a foreign-key cycle — two models declaring `on_delete = CASCADE` at each
other, or self-referencing rows that form a loop — which would otherwise make the collector descend
forever. A genuinely acyclic hierarchy deeper than the ceiling hits it too, and the ceiling is fixed;
delete such a graph in stages, from the far end inward.

The collected statements then execute in dependency order inside a single transaction (`BEGIN` on
PostgreSQL, `BEGIN IMMEDIATE TRANSACTION` on SQLite), so any failure rolls the whole set back.
Planning happens inside that transaction too, but on PostgreSQL a concurrent writer can still insert
onto a path the planner probed and pruned — see *Concurrency* in
[Deleting Records](write/delete.md).

# Examples

```julia
# Delete objects from a model with a specific filter
query = M.Status.objects
query.filter("status" => "Engine")
total, dict = delete(query)

# Build the SQL without executing it
query = M.Just_a_test_deletion.objects
query.filter("test_result__constructorid__name" => "Williams")
sql = delete(query, show_query = :sql)

# Delete related tables (cascading delete)
query = M.Result.objects
query.filter("resultid" => 1)
total, dict = delete(query)

# Delete all objects from a model (use with caution)
query = M.Just_a_test_deletion.objects
total, dict = delete(query; allow_delete_all = true)
```

See also [`show_query`](@ref), [`inspect_query`](@ref), and [Deleting Records](write/delete.md).
"""
function delete(objct::SQLObjectHandler; 
    table_alias::Union{Nothing, SQLTableAlias} = nothing, 
    connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, 
    show_query::Symbol = :execute,
    allow_delete_all::Bool = false)
  model = objct.object.model
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
  ensure_transaction_scope(model, connection)
    
  # check if is allowed to delete
  !settings.change_data && throw(_write_not_allowed("delete", conn_key))

  if objct.object.limit > 0 || objct.object.offset > 0 || !isempty(objct.object.order)
    throw(UnsafeMutationError(
      "Cannot call delete() on a query that has limit(), offset(), or order_by() set. " *
      "The deletion collector operates on complete filtered object sets so counts, cascades, " *
      "and constraint handling stay deterministic. Filter by primary key explicitly to delete " *
      "a bounded set."
    ))
  end

  if objct.object.distinct
    throw(UnsafeMutationError(
      "Cannot call delete() on a query with distinct(). " *
      "DISTINCT collapses the result set, making the deletion collector's " *
      "cascade counting unreliable. Remove distinct() or filter by primary key."
    ))
  end

  if any(v -> isa(v, SQLTypeField) && isa(v.field, Union{SQLTypeFunction, SQLTypeF}) && v.field.aggregate, objct.object.values)
    throw(UnsafeMutationError(
      "Cannot call delete() on a query with group_by() / annotate aggregations. " *
      "GROUP BY collapses rows, making cascade counting and constraint handling " *
      "unreliable. Remove the aggregation or filter by primary key."
    ))
  end

  # #433: a CTE-scoped delete is refused here, at the entry, rather than at either render site.
  #
  # The deletion collector re-uses THIS queryset in two ways: for a model with dependents it
  # synthesizes `"<fk>__@in" => objct` (`find_related_objects!`), a nested subquery; and every model,
  # leaf or not, renders its own statement from it (`_collector_predicate` — since #765 its filters
  # on the target row, before that `WHERE pk IN (<objct>)`). Those paths reach different amounts of
  # the query builder, so guarding downstream made the SAME user code succeed or fail depending on
  # whether the target model happened to have a reverse relation — an invisible, schema-dependent
  # split. (The root statement emits no `WITH` either, so a CTE has nowhere to live there.)
  #
  # Refusing rather than exempting is deliberate. An exemption scoped to "anything rendered under a
  # delete" was measured to re-open the very misbind #433 exists to prevent: with a filter bound
  # before the nested CTE, SQLite bound ["CTEVAL","INNERVAL","NOTEVAL"] against a text order of
  # NOTEVAL, CTEVAL, INNERVAL — a silent WRONG DELETE, the worst failure mode in the package. A
  # narrower origin-tracking exemption is possible but is the same "trust where this subquery came
  # from" reasoning that produced this bug class.
  #
  # UnsafeMutationError, not the QueryBuildError the rest of the #433 family throws. The
  # discriminator is not the query SHAPE — the identical query is legal on a read path and renders
  # its `WITH` fine — it is that this is a MUTATION, which is the axis `UnsafeMutationError` names
  # ("an UPDATE or DELETE ... in another unsafe shape"). `QueryBuildError` is the default bucket for
  # what has no sharper category, and this has one. It also keeps the type uniform across the five
  # guards in this function, so a caller catching `UnsafeMutationError` to mean "refine this delete"
  # has no blind spot. (`update()`'s CTE refusal is a `QueryBuildError` only incidentally: it is
  # raised deep in `_build_row_join`, where the statement kind is not known.)
  if !isempty(objct.object.ctes)
    throw(UnsafeMutationError(
      "Cannot call \e[4m\e[32mdelete()\e[0m on a query that declares a CTE " *
      "(\e[4m\e[31m$(join(collect(keys(objct.object.ctes)), ", "))\e[0m). The delete re-uses this " *
      "query as a scoping subquery, where a nested \e[4m\e[32mWITH\e[0m binds into the " *
      "\e[4m\e[31m:cte\e[0m bucket ahead of values whose text comes first — on SQLite that deletes " *
      "the wrong rows with no error.\n  " *
      "Resolve the CTE first and filter on its result, e.g. " *
      "\e[4m\e[32m.filter(\"pk__@in\" => ids)\e[0m (#433)."
    ))
  end

  # don't allow to delete without filter
  if !allow_delete_all && objct.object.filter |> isempty
    throw(UnsafeMutationError(
      "Error in delete, the delete must have a filter. " *
      "To delete every row, pass \e[4m\e[31mallow_delete_all = true\e[0m explicitly, e.g. " *
      "Model.objects.delete(allow_delete_all = true) or delete(query; allow_delete_all = true)."
    ))
  end
  
  # If no objects to delete, return early (unless we're just inspecting the query)
  #
  # #452: this probe deliberately stays OUTSIDE the transaction, unlike the per-path probes in
  # `find_related_objects!` (moved inside, below). The asymmetry is the failure mode, not the cost:
  # being wrong here yields a delete that found nothing, which is indistinguishable from the delete
  # having run an instant earlier and can never produce a PARTIAL cascade. Being wrong there deletes
  # the root and skips a dependent path. Keeping this one out also avoids opening a transaction —
  # and, on SQLite, taking the process-wide write lock — for every no-op delete.
  if show_query === :execute && objct |> !_exists
    return 0, Dict{String, Integer}()
  end

  # We'll track deletion counts
  deleted_counter = Dict{String, Integer}()

  # Definition of run_deletions (backend agnostic)
  results = []
  run_deletions = function(conn)
    # Plan INSIDE the transaction (#452).
    #
    # `find_related_objects!` probes every cascade path with `_exists` and DROPS the ones that come
    # back empty. That planning used to run before `BEGIN`, so a row inserted on a pruned path
    # between the probe and the DELETE was never deleted: the root went, the dependent stayed. It is
    # also what kept #452 itself invisible — the F1 fixture declares two CASCADE paths into
    # `just_a_test_deletion`, and the second was always pruned because nothing populates it.
    #
    # On SQLite this closes the window: `BEGIN IMMEDIATE` plus the process-wide write lock means no
    # other writer can commit while planning runs.
    #
    # On PostgreSQL it only NARROWS it, and the comment says so rather than implying otherwise:
    # READ COMMITTED gives every statement a fresh snapshot even inside a transaction, so a
    # concurrent insert between a probe and its DELETE is still possible.
    #
    # #460 took that decision and it is CLOSED as accepted, not open: PormG keeps pruning and
    # documents the window (`docs/src/write/delete.md`, "Concurrency").
    #
    # Read the reason carefully, because #460's own issue body gets it wrong and so did the first
    # draft of this comment. Both said the deferred foreign key makes a pruned path RAISE at COMMIT.
    # It does not.
    #
    # MEASURED here: `Dialect._foreign_key_on_delete_sql` emits the field's OWN on_delete into the
    # DDL, and `db_constraint` defaults TRUE (`Models.ForeignKey`), so the constraint carries the
    # action rather than a bare reference. Confirmed by reading the deployed fixture's schema —
    # `lap_times.raceid` is `ON DELETE CASCADE`, `lap_times.driverid` is `ON DELETE RESTRICT`.
    #
    # INFERRED, not measured (no PostgreSQL was available): that the database then performs the
    # skipped CASCADE / SET NULL / SET DEFAULT at COMMIT. That is PostgreSQL's documented
    # deferred-referential-action behavior, and it is the half worth re-checking on a live two-session
    # setup before anyone leans further on it. If it holds, a pruned path costs only the per-table
    # count in the return value, which tallies statements PormG itself issued.
    #
    # Note pruning is NOT limited to the actions that emit statements. The `_exists` probe below runs
    # for EVERY reverse relation, before `handle_on_delete!` sees the action — that is exactly what
    # makes PROTECT existence-driven. So a pruned PROTECT path means ProtectedError is not raised and
    # the DELETE meets the DDL's `ON DELETE RESTRICT` instead, which PostgreSQL cannot defer: still a
    # refusal, reported as the driver's error rather than ours.
    #
    # The exposed shapes are the ones with no database action to fall back on: `db_constraint=false`,
    # and hand-written models over tables PormG did not create. That is a much narrower surface than
    # "every delete", which is what makes accepting it the right call at this stage rather than
    # merely the cheap one.
    #
    # Do not "fix" this by reaching for one of the alternatives without re-reading #460: raising the
    # isolation level to REPEATABLE READ does NOT close it (the DELETE then misses the row too, it
    # merely agrees with the probe); SERIALIZABLE closes it by making every delete retryable by
    # contract; parent-row FOR UPDATE closes it at the cost of a lock per collected level. Each was
    # weighed there and rejected for this pre-publish stage.
    #
    # #770 has since adopted the parent-row lock, but for a DIFFERENT gap — a parent that stops
    # matching after its children are gone (`lock_objects`) — and it runs AFTER this planning. It does
    # not un-prune a path: a row inserted on a path the probe dropped is still #460's residue, as above.
    #
    # Two costs, both accepted deliberately: SQLite now holds the write lock across the probe
    # SELECTs, and a `ProtectedError` / `ModelDefinitionError` raised while planning now costs a
    # BEGIN + ROLLBACK instead of throwing before any transaction existed.
    collector = DeletionCollector(model, settings, show_query)
    add_objects_to_collector!(collector, objct |> deepcopy, model)
    process_collector!(collector)

    # #770: lock every parent, top-down, BEFORE any statement below reads it. See `lock_objects`.
    # PostgreSQL only: SQLite's writers are already serialized for the whole transaction (the
    # `BEGIN IMMEDIATE` + write-lock comment above), so no parent can change under the cascade there.
    #
    # #771: right after the root's own lock, the tables its filter JOINs are locked `FOR SHARE`, so a
    # root filter across a relation cannot change mid-cascade either. See `lock_related_objects`.
    if connection isa PormGPostgres
      for lock_model in _models_to_lock(collector)
        res = lock_objects(connection, lock_model, collector.objects[lock_model], show_query, conn)
        push!(results, res)
        lock_model === model &&
          append!(results, lock_related_objects(connection, collector.objects[lock_model], show_query, conn))
      end
    end

    # Process fast deletes first (objects that can be deleted directly).
    # Named `fast_model` rather than `model`: the enclosing `model` is now read inside this closure
    # (the collector is built here since #452), and two meanings for one name in one scope is a
    # reading hazard even where Julia's loop scoping makes it harmless.
    for (fast_model, fast_keys) in collector.fast_deletes
      res = delete_objects(connection, fast_model, fast_keys, show_query, deleted_counter, conn)
      push!(results, res)
      # Remove from objects to prevent double deletion
      delete!(collector.objects, fast_model)
    end

    # Process field updates (for SET_NULL, SET_DEFAULT, etc.). `path_keys` is one entry per cascade
    # path reaching this model (#459 (a)); `update_field` ORs them into a single UPDATE, so the
    # statement count is still one per (field, value, model).
    for ((field, value), affected_models) in collector.field_updates
      for (affected_model, path_keys) in affected_models
        res = update_field(connection, affected_model, field, value, path_keys, show_query, conn)
        push!(results, res)
      end
    end
    
    # Execute deletions in the sorted order
    for model_to_delete in collector.sorted_models
      _array = get(collector.objects, model_to_delete, [])        
      if !isempty(_array)
        res = delete_objects(connection, model_to_delete, _array, show_query, deleted_counter, conn)
        push!(results, res)
      end
    end
  end

  tx_conn = transaction_connection_for(settings)
  if show_query !== :execute
    run_deletions(nothing)
  elseif tx_conn !== nothing
    run_deletions(tx_conn)
  else
    # Start transaction (backend specific SQL)
    begin_sql = if connection isa PormGPostgres
        "BEGIN;"
    else
        # Use BEGIN IMMEDIATE for SQLite to prevent deadlocks
        "BEGIN IMMEDIATE TRANSACTION;"
    end
    # Serialize SQLite writers around the whole BEGIN..COMMIT, matching
    # run_in_transaction, so a concurrent delete/create never races on
    # `BEGIN IMMEDIATE` (which would deadlock the single async worker). No-op on
    # PostgreSQL. See ConnectionPool.with_sqlite_write_lock.
    with_sqlite_write_lock(settings) do
      _, conn = with_transaction(settings, begin_sql)
      # Release/renew the connection exactly once in a single terminal finally, so a failed
      # COMMIT never returns it to the pool before the cleanup ROLLBACK has run on it (#139).
      local rollback_error = nothing
      try
        # #276: same deferral as run_in_transaction — PormG's PG foreign keys are DEFERRABLE
        # INITIALLY DEFERRED, so the collector's intermediate states (a child DELETEd before its
        # parent, a SET_NULL applied mid-sweep) are legal there. Defer on SQLite too, or enforcement
        # would reject an ordering PostgreSQL accepts. Resets at COMMIT; no-op on PostgreSQL.
        #
        # INSIDE the try, not between it and the BEGIN: `with_transaction(…, conn=conn)` releases
        # nothing on failure (conn_acquired = false), so a throw in that gap would skip the terminal
        # finally entirely and strand this connection out of the pool holding an open
        # BEGIN IMMEDIATE — i.e. the database write lock. The #139/#71 class.
        connection isa PormGSQLite &&
          with_transaction(settings, "PRAGMA defer_foreign_keys = ON;", conn=conn)
        with_tx_context(settings.connections, conn) do
          run_deletions(conn)
        end
        # Commit — release_conn=false: the finally owns the single release.
        with_transaction(settings, "COMMIT;", conn=conn, release_conn=false)
      catch e
        # Roll back on the still-leased connection. A rollback failure must not mask the body's
        # error — capture it so the finally renews/discards the dirty connection instead of
        # releasing it (#71), then rethrow the original.
        try
          with_transaction(settings, "ROLLBACK;", conn=conn, release_conn=false)
        catch rollback_err
          rollback_error = rollback_err
          @error "Failed to rollback delete transaction" exception=rollback_err
        end
        rethrow(e)
      finally
        finalize_transaction_connection!(settings, conn; rollback_error=rollback_error)
      end
    end
  end

  if show_query !== :execute
    return length(results) == 1 ? results[1] : results
  end

  total_deleted = sum(values(deleted_counter))
  if total_deleted == 0
    @warn("Warning in delete, no objects were deleted")  
  end
  
  return total_deleted, deleted_counter
end
delete(; kwargs...) = (objct) -> delete(objct; kwargs...)

# Ceiling on how deep `find_related_objects!` will descend before refusing (#459). See the guard
# itself for why this is a depth cap rather than a cycle-membership test.
const MAX_CASCADE_DEPTH = 50

# Sentinel returned by resolve_delete_key when a keyless model should be deleted directly
# (bare DELETE FROM table, no WHERE clause). Chosen to be an impossible SQL identifier so
# accidental equality checks against real column names always fail.
const DIRECT_DELETE_KEY_SENTINEL = "__pormg_direct_delete__"

function resolve_delete_key(model::PormGModel; fallback::Union{Nothing,String}=nothing, allow_direct::Bool=false)
  pk_field = get_model_pk_field(model)
  if pk_field !== nothing
    # Preserve the declared case (#57): field_names and column names are case-sensitive,
    # so the delete key must match the field's declared case verbatim.
    return string(pk_field)
  end

  if fallback !== nothing
    # Match the user-supplied fallback verbatim — field lookup is case-sensitive (#57).
    fallback in model.field_names || throw(UnknownFieldError("The fallback delete field $(fallback) was not found in $(model.name)"))
    return fallback
  end

  allow_direct && return DIRECT_DELETE_KEY_SENTINEL

  throw(QueryBuildError("Delete on $(model.name) requires a primary key or an explicit fallback delete field"))
end

# Shared helper: resolves the delete key for a related model and returns a properly filtered
# copy of the parent query so all three on_delete branches (CASCADE, SET_NULL, SET_DEFAULT) stay in sync.
function prepare_related_query(keys::Dict{Symbol, Union{String, SQLObjectHandler}}, related_model::PormGModel, field_name::Union{String, Symbol})
  delete_key = resolve_delete_key(related_model; fallback=string(field_name))
  _query = deepcopy(keys[:objct])
  delete_key != DIRECT_DELETE_KEY_SENTINEL && _query.values(delete_key)
  return Dict{Symbol, Union{String, SQLObjectHandler}}(:key => delete_key, :objct => _query)
end

function add_objects_to_collector!(collector::DeletionCollector, objct::SQLObjectHandler, model::PormGModel)
  # Extract IDs from objects - handle NamedTuples or Dict structures
  @pormg_debug false
  delete_key = resolve_delete_key(model; allow_direct=isempty(objct.object.filter))
  delete_key != DIRECT_DELETE_KEY_SENTINEL && objct.values(delete_key)
  add_objects_to_collector!(collector, model, delete_key, objct)
end


function add_objects_to_collector!(collector::DeletionCollector, model::PormGModel, key::String, objct::SQLObjectHandler)
  # Add to collector
  # @info objct |> query
  @pormg_debug false
  if !haskey(collector.objects, model)
    collector.objects[model] = []
  end
 
  push!(collector.objects[model], Dict(:key => key, :objct => objct))
  
  # Add model to the list of models to process
  if !haskey(collector.dependencies, model)
    collector.dependencies[model] = Set{PormGModel}()
  end
end


function process_collector!(collector::DeletionCollector)
  # The SEED set: the models present before any traversal runs. Today that is exactly one — the root,
  # put there by `delete()`'s `add_objects_to_collector!` call — but the snapshot is the contract,
  # not an optimization for a one-element Dict.
  #
  # #459: this used to iterate `collector.objects` directly, while the body inserted into it
  # (`find_related_objects!` -> `handle_on_delete!` -> `add_objects_to_collector!`). Julia neither
  # raises nor snapshots on that, so the loop walked entries it had just created.
  #
  # RE-VISITING is the failure, not skipping, and the direction matters because it decides the fix.
  # Every model inserted here was inserted BY the recursion at the `handle_on_delete!` CASCADE
  # branch, which descends into it at insertion time — so an entry the outer loop never reaches has
  # already been traversed and nothing is lost. Reaching it again re-walks it with its COMPLETE key
  # vector, pushing a duplicate entry into each of its children, which then re-walk theirs. Measured
  # on a 14-link CASCADE chain, mock connections: 105 collected entries where 14 are correct, the
  # last statement rendering 14 `OR` arms and binding 67 values for a plan that needs 1. A second
  # run gave 87 — the count is hash-order dependent, which is the whole complaint.
  #
  # NOT a `visited::Set{PormGModel}`, which is what the issue proposed. That would be a correctness
  # regression: a model reachable by two cascade paths legitimately gets two entries, each carrying
  # its own scoping query, and each needs its own descent. Suppressing the second descent leaves
  # that path's grandchildren uncollected — the silent orphan #459 exists to prevent.
  seeds = collect(collector.objects)
  for (model, keys) in seeds
    # `copy` because a self-referential CASCADE pushes into the very vector `find_related_objects!`
    # enumerates in its `Qor` branch. Shallow on purpose: the entry Dicts are read, never mutated.
    find_related_objects!(collector, model, copy(keys))
  end

  # Identify objects that can be fast-deleted
  collect_fast_deletes!(collector)
  
  # Topologically sort models for deletion
  collector.sorted_models = topological_sort(collector.dependencies)
end

function should_check_related_existence(collector::DeletionCollector)::Bool
  pool = collector.settings.connections
  connection_pool = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  return pool isa connection_pool.PostgresConnectionPool || pool isa connection_pool.SQLiteConnectionPool
end

function find_related_objects!(collector::DeletionCollector, model::PormGModel, dict::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}})
  # For each foreign key in the model (model has FK -> related_model)
  @pormg_debug false

  push!(collector.traversal_path, model)
  try
    _find_related_objects!(collector, model, dict)
  finally
    pop!(collector.traversal_path)
  end
end

function _find_related_objects!(collector::DeletionCollector, model::PormGModel, dict::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}})
  # A cascade cannot descend forever. Measured before this guard, on two models with a CASCADE FK
  # each way: `StackOverflowError` after ~5s, preceded by Julia's own
  # "detected a stack overflow; program state may be corrupted" — inside the delete transaction, on
  # a corrupted runtime. A `QueryBuildError` rolls back cleanly and names the loop instead.
  #
  # A DEPTH CAP, deliberately, and not the obvious "this model is already on the path" test:
  #
  #   - A self-referential CASCADE foreign key (category tree, org chart) is a legitimate Django
  #     shape that PormG supports today, and it puts the same model on the path at every level. A
  #     membership test refuses it outright.
  #   - A membership test is not sufficient either. Termination is a property of the DATA, not the
  #     schema: cyclic rows keep every `_exists` probe non-empty while the nested subquery grows
  #     without bound, so even the probing path needs a ceiling.
  #
  # 50 is generous for anything real — every level adds one more nested SELECT, and both backends
  # are planning badly long before that.
  if length(collector.traversal_path) > MAX_CASCADE_DEPTH
    tail = join([m.name for m in collector.traversal_path[max(1, end - 9):end]], " -> ")
    throw(QueryBuildError(
      "Error in delete: the cascade exceeded $(MAX_CASCADE_DEPTH) levels while collecting dependents of " *
      "\e[4m\e[31m$(collector.model.name)\e[0m. The last models walked were " *
      "\e[4m\e[31m$(tail)\e[0m. Usually a foreign-key cycle: two models declared " *
      "\e[4m\e[32mon_delete = CASCADE\e[0m at each other, or self-referencing rows that form a " *
      "loop, make the collector descend without end — break the cycle, or give one side a " *
      "different on_delete and remove its rows first. If the chain above is genuinely acyclic, it " *
      "is simply deeper than \e[4m\e[32mMAX_CASCADE_DEPTH\e[0m, the fixed ceiling in " *
      "src/querybuilder/deletion.jl; delete it in stages, from the far end inward."
    ))
  end

  # For models with foreign keys pointing to this model (related_model has FK -> model)
  for (related_name, related_value) in model.related_objects
    # Skip many-to-many reverse accessors — these are handled by the through
    # table's own CASCADE FK on the owner side, not by this loop.
    related_value isa Models.ManyToManyRelation && continue
    # #343: read the resolved child. This used to respell the binding with `capitalize_symbol`,
    # which cannot produce an internal capital, so a cascade through `Dim_CNES` threw UndefVarError.
    # Its django-prefix strip went with it: `get_model_name` strips the prefix at REGISTRATION, so
    # the stored name never carried one and the strip was a guaranteed no-op. The tuple's `pk_field`
    # and `pk_model` slots were destructured here and never read — both are gone with the tuple.
    rel = related_value::Models.ReverseRelation
    field_name = rel.fk_field
    related_model = rel.model_resolved

    _query = related_model |> object;
    if size(dict, 1) == 1
      _query.filter("$(field_name)__@in" => dict[1][:objct]);
    else
      or_object = Qor("$(field_name)__@in" => dict[1][:objct])
      for (index, dict_) in enumerate(dict)
        if index == 1
          continue # already added via Qor constructor
        end
        push!(or_object, "$(field_name)__@in" => dict_[:objct])
      end
      _query.filter(or_object)
    end
    
    @pormg_debug false
    # For live pools, inspection should still reflect actual reverse-row presence so
    # PROTECT/RESTRICT do not raise false positives. Mock/unit-test connections keep
    # the previous behavior and assume related rows exist because no database is available.
    should_check_existence = collector.show_query === :execute || should_check_related_existence(collector)
    should_check_existence && (_query |> !_exists) && continue
     
    # @info _query |> query

    # THE ORDER IS correctly set?
    if !haskey(collector.dependencies, related_model)
      collector.dependencies[related_model] = Set{PormGModel}()
    end  
    push!(collector.dependencies[related_model], model)

    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}(
      :key => resolve_delete_key(related_model; fallback=string(field_name)),
      :objct => _query
    )

    field = related_model.fields[String(field_name)]
    handle_on_delete!(collector, field_name, field, model, _keys, related_model)

  end
end

# APPEND a SET_NULL / SET_DEFAULT path, never overwrite one (#459 (a)).
#
# `handle_on_delete!` fires once per cascade path, so a child of a MULTI-PATH parent reaches this
# twice with two different scoping queries — the same shape `collector.objects` handles by pushing.
# This slot assigned instead, so the second path silently replaced the first and its rows were never
# written. Measured on `root -CASCADE(owner|backup)-> mid -SET_NULL-> leaf`: the emitted UPDATE
# scoped through `"owner"` only, and which of the two survived was `related_objects` Dict order —
# arbitrary, exactly like the `keys[1][:key]` defect #452 removed from `delete_objects`.
#
# Loud rather than silent wherever the FK constraint exists: the un-nulled rows still point at
# `mid` rows the cascade then deletes, so PostgreSQL's DEFERRABLE INITIALLY DEFERRED check (and
# SQLite's deferred pragma) raises at COMMIT and the whole delete rolls back. Silent only against a
# table with no constraint.
function _push_field_update!(collector::DeletionCollector, bucket::Tuple{String, Any},
  related_model::PormGModel, keys::Dict{Symbol, Union{String, SQLObjectHandler}}, field_name::Union{String, Symbol})
  per_model = collector.field_updates[bucket]
  entries = get!(() -> Vector{Dict{Symbol, Union{String, SQLObjectHandler}}}(), per_model, related_model)
  push!(entries, prepare_related_query(keys, related_model, field_name))
  return entries
end

function handle_on_delete!(collector::DeletionCollector, field_name::Union{String, Symbol}, field::PormGField, model::PormGModel, 
  keys::Dict{Symbol, Union{String, SQLObjectHandler}}, related_model::PormGModel)
  @pormg_debug false
  if field.on_delete == CASCADE
    @pormg_debug false
    _keys = prepare_related_query(keys, related_model, field_name)
    add_objects_to_collector!(collector, related_model, _keys[:key], _keys[:objct])
    @pormg_debug false
    find_related_objects!(collector, related_model, [_keys]) # Recursively find related objects for the related model
  elseif field.on_delete in [PROTECT, RESTRICT]    
    # More descriptive error with field name, constraint type, and sample IDs
    constraint_type = field.on_delete == PROTECT ? "PROTECT" : "RESTRICT"
    throw(ProtectedError("Cannot delete \e[4m\e[31m$(model.name)\e[0m because it is referenced by \e[4m\e[31m$(related_model.name).$(field_name)\e[0m with ON DELETE \e[4m\e[31m$(constraint_type)\e[0m constraint"))
  elseif field.on_delete == SET_NULL
    @pormg_debug false
    # Backstop copy of `set_models`' SET_NULL guard, for models that never passed registration —
    # see the fixtures in test/integration/common_delete_setup.jl, which register a VALID model and
    # then flip the field, so this path is the only thing left to catch it.
    #
    # This one stays PER-FIELD and IMMEDIATE. Do NOT "unify" it with the aggregating collector
    # `set_models` grew in #303. There, N models are being registered at once and reporting all N
    # contradictions in one error saves N import cycles — the whole point. Here we are inside one
    # delete, resolving one referencing field, with nothing to aggregate: deferring the throw would
    # only let the collector keep building statements against a schema already known to be
    # unsatisfiable, and then report them alongside an error we could have raised immediately.
    # Fail on the field in hand.
    if !field.null
      throw(ModelDefinitionError("Error in delete: ON DELETE SET_NULL is declared on \e[4m\e[31m$(field_name)\e[0m, but the field has null=false — the schema contradicts itself. Declare the FK with null=true or use a different on_delete."))
    end

    # Add field update to set field to NULL
    if !haskey(collector.field_updates, (field_name |> string, nothing))
      @pormg_debug false
      collector.field_updates[(field_name |> string, nothing)] = Dict{PormGModel, Vector{Dict{Symbol, Union{String, SQLObjectHandler}}}}()
    end
    
    # Add to field updates using _query object like CASCADE — one entry per cascade path.
    _push_field_update!(collector, (field_name |> string, nothing), related_model, keys, field_name)

  elseif field.on_delete == SET_DEFAULT
    # check that there is a default to set — symmetric with the SET_NULL guard above (#287), and
    # per-field/immediate for the same reason spelled out there (#303).
    # Without it `field.default === nothing` flows into update_field, which renders a bare NULL,
    # so SET_DEFAULT silently behaved as SET_NULL and then died on the column's NOT NULL constraint.
    if field.default === nothing
      throw(ModelDefinitionError("Error in delete: ON DELETE SET_DEFAULT is declared on \e[4m\e[31m$(field_name)\e[0m, but the field has no default — the schema contradicts itself. Give the FK a default= or use a different on_delete."))
    end

    # Add field update to set field to default value
    default_value = field.default
    if !haskey(collector.field_updates, (field_name |> string, default_value))
      collector.field_updates[(field_name |> string, default_value)] = Dict{PormGModel, Vector{Dict{Symbol, Union{String, SQLObjectHandler}}}}()
    end    
    
    # Add to field updates using _query object like CASCADE — one entry per cascade path.
    _push_field_update!(collector, (field_name |> string, default_value), related_model, keys, field_name)
  end
end

function topological_sort(dependencies::Dict{PormGModel, Set{PormGModel}})
  result = Vector{PormGModel}()
  temp_mark = Set{PormGModel}()
  perm_mark = Set{PormGModel}()
  
  function visit(node)
    if node in temp_mark
      throw(QueryBuildError("Circular dependency detected in model relationships"))
    end
    
    if !(node in perm_mark)
      push!(temp_mark, node)
      for dep in get(dependencies, node, Set{PormGModel}())
        visit(dep)
      end
      delete!(temp_mark, node)
      push!(perm_mark, node)
      push!(result, node)
    end
  end
  
  for node in keys(dependencies)
    if !(node in perm_mark)
      visit(node)
    end
  end
  
  return reverse(result)
end

function collect_fast_deletes!(collector::DeletionCollector)
  # Find models that have no dependencies (nothing depends on them)
  
  # First, identify all models that have something depending on them
  models_with_dependents = Set{PormGModel}()  
  # A model is a dependent if it appears as a key in the dependencies dict
  # AND has a non-empty set of dependencies
  for (model, dependencies) in collector.dependencies
    if !isempty(dependencies)
      # This model depends on something, so it's not a leaf node
      push!(models_with_dependents, model)
      
      # Also add the models it depends on (they have dependents)
      union!(models_with_dependents, dependencies)
    end
  end
  
  # Models that can be fast-deleted are those that:
  # 1. Have objects to delete
  # 2. Don't appear in models_with_dependents
  for (model, keys) in collector.objects
    if !(model in models_with_dependents)
      @pormg_debug false
      collector.fast_deletes[model] = keys
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Rows a statement actually removed (#452)
#
# Taken from the driver, not from a `SELECT COUNT(*)` issued just before the DELETE. That pre-count
# was one extra round trip per table, and on PostgreSQL it was not even atomic: READ COMMITTED gives
# every statement a fresh snapshot *inside* a transaction, so a row committed between the COUNT and
# the DELETE was removed and not counted.
#
# This is `update()`'s contract rather than a new one (see execution.jl): PostgreSQL exposes the
# count on the driver result; SQLite needs `changes()` on the SAME connection, which `conn`
# guarantees here because every delete statement runs inside the collector's transaction on the
# pinned connection. RETURNING is deliberately not used — `insert()` documents why SQLite RETURNING
# is avoided (it can hang inside libsqlite3 for some table shapes).
#
# The bulk terminals count their chunks through this too (#670). They pass
# `transaction_connection_for(settings)`: every bulk loop executes inside `run_in_transaction` or the
# caller's transaction (#85), so that is the connection the chunk statement just ran on.
#
# Only ever called under `show_query === :execute`, which is also the only state in which `conn` is
# non-nothing. The guard below keeps that structural rather than documentary: on SQLite, with
# `conn = nothing`, `with_transaction` leases a connection with `release_conn = false` and this call
# site discards the handle, so every delete would leak a pool slot until `acquire_connection` began
# timing out. A silent leak is worth one comparison to rule out.
#
# Two things about that guard that the obvious reading gets wrong:
#
#   - It sits ABOVE the PostgreSQL return, so it refuses `conn = nothing` on a backend where nothing
#     leases and nothing can leak. Deliberate: "keep PostgreSQL and SQLite aligned" applies to
#     preconditions too, and a contract that holds on one backend only is the kind of divergence
#     that gets discovered by a bug report rather than by a test.
#   - It is an ASSERTION, not a precondition — it runs after the DELETE has already executed. If it
#     ever fired, the enclosing transaction would roll the statement back, which is the outcome we
#     want; but do not read it as guarding the write.
# ─────────────────────────────────────────────────────────────────────────────
function _affected_row_count(connection::Union{PormGPostgres, PormGSQLite}, result, conn)::Int
  conn === nothing && error(_emsg("PormG internal error: _affected_row_count needs the statement's connection — this should not happen; please report it."))
  connection isa PormGPostgres && return backend_num_affected_rows(connection, result)
  changes, _ = with_transaction(connection, "SELECT changes();", conn=conn)
  return Int((changes |> DataFrames.DataFrame)[1, 1])
end

# ─────────────────────────────────────────────────────────────────────────────
# One row predicate per cascade path, ORed (#452, #765)
#
# The WHERE of every statement the collector emits — `delete_objects` and `update_field` both — and
# the ONLY thing that renders into that statement's `parameters`. Returns `(where_sql, parameters,
# alias)`; `where_sql` is empty when an arm has no predicate at all (a root delete under
# `allow_delete_all`), because an empty arm in an OR matches every row.
#
# #765: each arm is the entry's OWN predicates on the target alias (`_mutation_predicate`), never
# only `"<key>" IN (SELECT "Tb"."<key>" FROM <t> AS "Tb" WHERE …)`. A join-free arm is its conjuncts;
# a joined one (only the root can be) is `"Tb"."pk" IN (<selection>) AND EXISTS (<fence>)` — the IN
# for the index, the EXISTS for the re-check (`_target_pk_selection`). PostgreSQL does not re-check a
# self-subquery when the statement waits on a row lock, so every filter — the user's fence on the
# root, and the `"<fk>" IN (<parent>)` scope on a cascaded child — was selection only: a row a
# concurrent transaction had just changed to stop matching was deleted (or nulled) anyway. The
# nested `"<fk>__@in" => parent` subquery INSIDE an arm is still a subquery; what matters is that the
# child's own `fk` is compared on the target row, so a re-parented child no longer matches.
#
# A side effect: `:key` no longer renders. Each arm now reads its own column straight off the target,
# which makes #452's wrong-key misbind (`"owner" IN (SELECT … "backup" …)`, one arm addressed through
# another arm's key) unrepresentable here rather than merely avoided. The key still matters — it is
# the entry's PROJECTION, which a child's `"<fk>__@in" => parent` reads — so the projection is
# stripped only from this private copy (the #668 move `update()` makes).
#
# #452 still binds: one renderer and one collector. The multi-path case once built these arms, threw
# the text away and re-rendered the subqueries through a `Qor` into the same collector — twice the
# values its markers asked for.
#
# The #432 mark/detach wrap lifts each build's values into ONE clause-ordered run under `:where`, at
# its text position. Since #765 it is LOAD-BEARING, where before it was insurance: a joined root arm
# is built twice (the IN's build, then the EXISTS's), and both bind their ON values in `:join`.
# Unwrapped, `:join` would flatten BOTH builds' ON values ahead of the first build's WHERE values — a
# positional misbind on SQLite (text order is ON₁ WHERE₁ ON₂ WHERE₂). Only the root arm can bind in
# `:join` at all (every cascade arm is a join-free `"<fk>__@in"` filter). It does move
# `:parameter_buckets` (a root's ON value reports under `:where`), which is public `:dict` output.
# ─────────────────────────────────────────────────────────────────────────────
function _collector_predicate(connection::Union{PormGPostgres, PormGSQLite},
    keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}})
  parameters = get_parameter(connection)
  set_context!(parameters, :where)
  arms = String[]
  alias = ""
  for key in keys
    build_one = () -> begin
      instruction = _build_entry(connection, key, parameters)
      alias = quote_identifier(instruction.alias, connection)
      instruction
    end
    push!(arms, _mutation_predicate(build_one, parameters))
  end

  if any(isempty, arms)
    # Only a lone, genuinely UNFILTERED root arm may be empty (`allow_delete_all`). An empty arm beside
    # others would drop a WHERE whose other arms had already bound values — markers and values out of
    # step — and a filtered root that rendered no predicate would delete every row. Refuse both.
    (length(arms) == 1 && isempty(keys[1][:objct].object.filter)) || error(_emsg("PormG internal error in delete(): a path rendered no row predicate (one of $(length(arms)) collected) — this should not happen; please report it."))
    return "", parameters, alias
  end
  where_sql = length(arms) == 1 ? arms[1] : join(("($(arm))" for arm in arms), " OR ")
  return where_sql, parameters, alias
end

# ─────────────────────────────────────────────────────────────────────────────
# Lock the parents before touching their children (#770)
#
# The collector deletes children BEFORE their parent, and a child's statement picks its parents
# through `"Tb"."<fk>" IN (<parent query>)` — read when THAT statement runs. #765 fences each
# statement on its own row, which is exactly why this gap is left: if a concurrent transaction changes
# a parent so it stops matching after its children have gone, the parent's own DELETE re-checks,
# correctly skips it, and the children are already deleted (or nulled). Measured on db_2 before this
# lock existed, at both depths `test_mutation_fence_concurrency.jl` stages: a race renamed out of the
# root filter, and a race moved to another circuit under a circuit delete — the race survived both
# times and its result did not.
#
# So every model that is a PARENT of an emitted statement is locked first, `FOR UPDATE`, top-down, in
# one statement per model, through the same `_collector_predicate` its DELETE renders. Top-down is
# what makes it hold at every depth: level L+1 is selected from level-L rows that are already locked
# and can no longer change until COMMIT. A lock that waits re-checks its row's new version the same way
# the #765 DELETE does, so a parent that changed meanwhile is simply not locked, and the child
# statements that follow read it as not matching either.
#
# What it costs. The ROW SET is unchanged — `FOR UPDATE` is the lock each parent's own DELETE takes
# anyway — but not the rest:
#   - DURATION: parent rows are held from the first statement instead of only for the tail of the
#     cascade, so a concurrent child INSERT (its FK check takes `FOR KEY SHARE`), a parent UPDATE or a
#     `select_for_update` waits for the whole cascade rather than its last statements.
#   - I/O: one statement per parent level, and a row-lock write (xmax + WAL record) per parent row
#     that the DELETE then writes again.
#   - ORDER: parents first, where the DELETEs alone went children first. A writer that locks
#     child-then-parent can now deadlock against a delete, which PostgreSQL detects and raises rather
#     than hangs on.
#
# This lock pins the parent's OWN row. A root filter that reads another table through a JOIN (a
# `"circuitid__name" => …`) is pinned by `lock_related_objects`, which runs right after it — staged
# on db_2 in the #770 review and closed by #771. Still NOT covered, and documented in delete.md: a
# filter that reads another table through a SUBQUERY (`"x__@in" => subquery`), re-read by every later
# statement on a fresh snapshot, a JOIN into an unmanaged model (skipped there on purpose), and a
# parent set that GROWS (a row that starts matching mid-cascade).
#
# Leaves are never locked, so a delete with nothing to cascade emits exactly the statements it did
# before. The `count(*)` wrapper keeps a large cascade from shipping one row per locked parent back to
# the client; the inner SELECT is what carries `FOR UPDATE`, and only its `"Tb"` rows are locked,
# because a joined root keeps its joins inside the predicate's IN/EXISTS subqueries.
#
# PostgreSQL only — the caller skips it on SQLite, whose writers are serialized for the whole
# transaction. Visible in `show_query` / `inspect_query` as `:operation => :lock` steps, because a
# statement that runs belongs in the inspection of what runs.
# ─────────────────────────────────────────────────────────────────────────────
"""
The collected models that are a parent of an emitted statement — a CASCADE child in
`collector.objects` or a SET_NULL / SET_DEFAULT target in `collector.field_updates` — parent first.
"""
function _models_to_lock(collector::DeletionCollector)::Vector{PormGModel}
  emitters = Set{PormGModel}(keys(collector.objects))
  for affected in values(collector.field_updates)
    union!(emitters, keys(affected))
  end
  parents = Set{PormGModel}()
  for child in emitters
    union!(parents, get(collector.dependencies, child, Set{PormGModel}()))
  end
  # `sorted_models` is children-first (`topological_sort`), so its reverse is the top-down order.
  return [m for m in reverse(collector.sorted_models) if m in parents && haskey(collector.objects, m)]
end

function lock_objects(connection::PormGPostgres, model::PormGModel, keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}},
    show_query::Symbol, conn)
  isempty(keys) && error(_emsg("PormG internal error in delete(): lock_objects was called with no keys for $(model.name) — this should not happen; please report it."))
  where_sql, parameters, alias = _collector_predicate(connection, keys)
  sql = "SELECT count(*) FROM (SELECT 1 FROM $(safe_table_identifier(Models.model_table_name(model), connection)) AS $(alias)" *
    (isempty(where_sql) ? "" : " WHERE $(where_sql)") *
    " FOR UPDATE) AS $(quote_identifier("__pormg_lock", connection))"
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :lock, parameters=parameters)
  end
  with_transaction(connection, sql, conn=conn, params=parameters)
  return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Lock the tables a joined filter reads (#771)
#
# `lock_objects` pins a parent's OWN row. A root filter that crosses a relation —
# `M.Race.objects.filter("raceid" => r, "circuitid__name" => n)` — also reads `circuit`, and every
# statement of the cascade re-reads it on a fresh READ COMMITTED snapshot. Staged on db_2 in the #770
# review: a concurrent rename of the circuit mid-cascade let the results go, then the race's own
# fenced DELETE re-read the new name and skipped the race. So right after the root's own lock, every
# table its filter JOINs is locked `FOR SHARE` too — one statement per hop, in chain order — and a
# rename (or delete) of a row the filter read now waits for the whole cascade.
#
# The statement is `SELECT 1 FROM <hop table> AS "__pormg_locked" WHERE "__pormg_locked".<key_b> IN
# (SELECT DISTINCT <alias_b>.<key_b> FROM <root> … <joins> WHERE …) FOR SHARE`, not a `FOR SHARE OF`
# on the root's own joined SELECT: across a nullable foreign key the join is a LEFT JOIN, PostgreSQL
# refuses to lock the nullable side of one, and it must stay LEFT (`_target_predicate`'s header says
# why). The lock sits on a plain single-table scan instead, and the joins print verbatim inside the IN.
#
# Why it holds, and in which order:
#   - The root's own FOR UPDATE runs FIRST, so its foreign keys are pinned, and the hops follow in
#     chain order, each pinning the key the next hop is reached through. Locking the related rows
#     first would let a root row re-pointed in between reach an unlocked row.
#   - The IN set is computed once, on the statement's snapshot. A lock that waited re-checks the new
#     version only against that cached set — so a hop row whose join key changed drops out, and one
#     whose other columns changed (the rename) is locked as it now stands. Either way every later
#     statement of the cascade reads the same version, so the parent and its children agree on
#     whether it matches.
#   - `FOR SHARE`, not `FOR KEY SHARE`: a rename is a non-key update, and only `FOR SHARE` blocks it.
#
# What it costs, beyond one statement per hop:
#   - LOCK ORDER: a forward hop locks a parent table (circuit) after its child (race) — the reverse
#     of #770's parents-first order. A joined race delete and a circuit delete, or a transaction that
#     updates a circuit and then one of its races, can now deadlock with it. PostgreSQL detects that
#     and aborts one transaction.
#   - PRIVILEGE: `FOR SHARE` needs UPDATE privilege on the locked table, where the delete needed only
#     SELECT on it before.
#   - BREADTH: keyed on the hop's join column, a reverse or many-to-many hop locks every child (or
#     through row) of each matching root, not only the ones the filter tests; a `cjoin(join_type =
#     "RIGHT")` hop also locks rows that pair with no root. Contention only — never a wrong row set.
#
# Skipped on purpose: a hop into an UNMANAGED model (`ModelJoin.target_managed`). Those are views and
# tables another system owns — `docs/src/models.md` recommends exactly that for a view — and
# `FOR SHARE` fails outright on an aggregating or materialized view, and on a table the role may only
# read. Locking them would turn a delete that works into an error; leaving them unpinned keeps #770's
# documented behavior for that hop.
#
# Also NOT covered, and delete.md says so: a filter that reads another table through a SUBQUERY
# (`"x__@in" => M.Other.objects…`, `Subquery`, `Exists`), an anchorless `cjoin_on` (no key column to
# lock by), and a parent set that GROWS mid-cascade (a lock pins the rows it found, not the rows that
# may start matching).
#
# Called for the ROOT only: every cascade entry below it is a join-free `"<fk>__@in"` filter, and
# building each one just to find no hop would cost a build per level of a deep cascade, each nesting
# its whole ancestor chain. (A self-referential root still builds its own join-free child entries
# once each — they are entries of the root model.)
# ─────────────────────────────────────────────────────────────────────────────
function lock_related_objects(connection::PormGPostgres, keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}},
    show_query::Symbol, conn)
  results = Any[]
  locked = quote_identifier("__pormg_locked", connection)
  for key in keys
    # One fresh build per statement, into its own collector: the hop statement is standalone, so its
    # `$N` numbering starts at 1. The first build doubles as the probe — an entry with no lockable
    # hop costs exactly one.
    hop = 1
    while true
      parameters = get_parameter(connection)
      instruction = _build_entry(connection, key, parameters)
      rows = [r for r in instruction.row_join if r isa ModelJoin && r.target_managed]
      hop > length(rows) && break
      row = rows[hop]
      sql = "SELECT count(*) FROM (SELECT 1 FROM $(safe_table_identifier(row.b, connection)) AS $(locked)" *
        " WHERE $(_joined_key_selection(instruction, row, locked))" *
        " FOR SHARE) AS $(quote_identifier("__pormg_lock", connection))"
      if show_query !== :execute
        # `:model` is the hop's physical table, which is all a `ModelJoin` carries — for a
        # many-to-many hop it is the join table's name.
        push!(results, _show_query_result(show_query, sql, connection, row.b, :lock, parameters=parameters))
      else
        with_transaction(connection, sql, conn=conn, params=parameters)
      end
      hop += 1
    end
  end
  return results
end

"""
A collected entry's query, built fresh into `parameters` for a row predicate. The projection is
stripped from a private copy: the entry's `:key` projection is what a child's `"<fk>__@in"` reads,
but a row predicate has no projection (#765, the #668 move).
"""
function _build_entry(connection::Union{PormGPostgres, PormGSQLite}, key::Dict{Symbol, Union{String, SQLObjectHandler}}, parameters)
  work = deepcopy(key[:objct].object)
  empty!(work.values)
  return build(work, connection=connection, parameters=parameters)
end

function delete_objects(connection::Union{PormGPostgres, PormGSQLite}, model::PormGModel, keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}},
   show_query::Symbol, deleted_counter::Dict{String, Integer}, conn)
  @pormg_debug false
  isempty(keys) && error(_emsg("PormG internal error in delete(): delete_objects was called with no keys for $(model.name) — this should not happen; please report it."))

  if size(keys, 1) == 1 && keys[1][:key] == DIRECT_DELETE_KEY_SENTINEL
    objct = keys[1][:objct]
    isempty(objct.object.filter) || throw(QueryBuildError("Delete on keyless model $(model.name) with filters is not supported; define a primary key or delete all rows explicitly"))

    sql = "DELETE FROM $(safe_table_identifier(Models.model_table_name(model), connection))"

    if show_query !== :execute
      return _show_query_result(show_query, sql, connection, model, :delete, parameters=nothing)
    end

    result, _ = with_transaction(connection, sql, conn=conn, params=nothing)
    deleted_counter[model.name] = _affected_row_count(connection, result, conn)
    return deleted_counter
  end

  # Checked over EVERY entry, not just the first. Entries for one model do NOT necessarily share a
  # resolved key: `resolve_delete_key` falls back to the referencing FIELD name when the model has no
  # primary key, so a keyless child reached by two foreign keys resolves two different keys. The
  # sentinel means "no key at all", which no WHERE fragment can address.
  any(k -> k[:key] == DIRECT_DELETE_KEY_SENTINEL, keys) &&
    throw(QueryBuildError("Multi-path delete on keyless model $(model.name) is not supported; define a primary key"))

  where_sql, parameters, alias = _collector_predicate(connection, keys)
  sql::String = "DELETE FROM $(safe_table_identifier(Models.model_table_name(model), connection)) AS $(alias)" *
    (isempty(where_sql) ? "" : " WHERE $(where_sql)")

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :delete, parameters=parameters)
  end
  @pormg_debug false
  result, _ = with_transaction(connection, sql, conn=conn, params=parameters)
  deleted_counter[model.name] = _affected_row_count(connection, result, conn)
  return deleted_counter  # Return count of deleted objects
end

function update_field(connection::Union{PormGPostgres, PormGSQLite}, model::PormGModel, field::String, value::Any, keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}}, show_query::Symbol, conn)
  # Update field values using query object like CASCADE
  @pormg_debug false
  isempty(keys) && error(_emsg("PormG internal error in delete(): update_field was called with no keys for $(model.name) — this should not happen; please report it."))

  # Defensive, and unreachable today — do NOT copy `delete_objects`' rationale onto it. There the
  # multi-entry sentinel check is load-bearing, because `add_objects_to_collector!` can store an
  # entry whose key came from `resolve_delete_key(..., allow_direct=true)`. Here every entry is built
  # by `prepare_related_query`, which always passes a `fallback` and never `allow_direct`, so
  # `resolve_delete_key` returns a primary key, returns the fallback, or throws — it cannot yield the
  # sentinel. Kept because the two renderers should fail the same way if that ever changes.
  any(k -> k[:key] == DIRECT_DELETE_KEY_SENTINEL, keys) &&
    throw(QueryBuildError("Cannot update field on keyless model $(model.name); define a primary key"))

  value_sql = value === nothing ? "NULL" : model.fields[field].formatter(value)

  # One predicate per cascade path, ORed together — the same renderer, and the same single-collector
  # discipline, as `delete_objects` (#452). Before #459 (a) this function took ONE entry because the
  # collector could only hold one: a SET_NULL child of a multi-path parent had its first path
  # overwritten by its second. #765 is why it is a predicate on the target rather than `pk IN (…)`:
  # a child re-parented by a concurrent UPDATE must not be nulled on the old parent's account.
  where_sql, parameters, alias = _collector_predicate(connection, keys)
  # Every entry here is `child.filter("<fk>__@in" => parent)`, so an empty predicate cannot arise —
  # and if it ever did, dropping the WHERE would rewrite the whole table. Refuse instead; only the
  # root DELETE (`allow_delete_all`) legitimately has no predicate.
  isempty(where_sql) && error(_emsg("PormG internal error in delete(): the $(field) update for $(model.name) has no row predicate — this should not happen; please report it."))

  # SET column is physical (db_column) — #50. Unqualified: SET names a column of the target, and
  # PostgreSQL rejects an alias-qualified SET column outright.
  sql = "UPDATE $(safe_table_identifier(Models.model_table_name(model), connection)) AS $(alias) SET $(safe_column_identifier(Models.model_column(model, field), connection)) = $(value_sql) WHERE $(where_sql)"
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :update, parameters=parameters)
  end
  # LibPQ.execute(connection, sql)
  with_transaction(connection, sql, conn=conn, params=parameters)
end
