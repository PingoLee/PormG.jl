struct ManyToManyDescriptor
  owner_model::PormGModel
  accessor::String
  relation::Models.ManyToManyRelation
end

struct ManyToManyManager
  owner_model::PormGModel
  related_model::PormGModel
  relation::Models.ManyToManyRelation
  owner_id::Any
end

function _m2m_model_from_binding(_module::Module, binding::String, table_name::String)::PormGModel
  binding_symbol = Symbol(binding)
  if isdefined(_module, binding_symbol)
    candidate = Base.invokelatest(getfield, _module, binding_symbol)
    candidate isa PormGModel && return candidate
  end

  target_name = Models.format_model_name(table_name)
  for model in Models.get_all_models(_module)
    Models.format_model_name(model.name) == target_name && return model
  end

  throw(QueryBuildError("The many-to-many related model $(binding) is not defined"))
end

function _m2m_extract_pk(value, pk_field::String)
  if value isa PormGRow
    return value[pk_field]
  end
  if value isa AbstractDict
    haskey(value, Symbol(pk_field)) && return value[Symbol(pk_field)]
    haskey(value, pk_field) && return value[pk_field]
  elseif value isa NamedTuple
    pk_symbol = Symbol(pk_field)
    pk_symbol in keys(value) && return getfield(value, pk_symbol)
  end
  return value
end

function _m2m_items(values)
  if length(values) == 1 && values[1] isa AbstractVector
    return collect(values[1])
  end
  return collect(values)
end

function _m2m_settings(manager::ManyToManyManager)
  conn_key = manager.owner_model.connect_key
  if conn_key === nothing
    if length(config) == 1
      conn_key = first(keys(config))
    else
      throw(InvalidConfigurationError("Model '$(manager.owner_model.name)' is not bound to a database connection key. Call set_models() before using a many-to-many manager."))
    end
  end
  settings = get_configuration_settings(conn_key)
  # Every manager operation resolves its database here, so this is the one place the
  # transaction-scope rule covers add/remove/clear/set and the id read (#838). They issue raw
  # `fetch` calls, which would otherwise run in autocommit on a database with no open transaction.
  ensure_transaction_scope(manager.owner_model, settings.connections)
  return settings, settings.connections, conn_key
end

function _m2m_format_owner(manager::ManyToManyManager)
  return manager.owner_model.fields[manager.relation.owner_pk].formatter(manager.owner_id)
end

function _m2m_format_related(manager::ManyToManyManager, related_id)
  return manager.related_model.fields[manager.relation.related_pk].formatter(related_id)
end

function _m2m_target_ids(manager::ManyToManyManager, targets)::Vector{Any}
  ids = Any[]
  for target in _m2m_items(targets)
    push!(ids, _m2m_format_related(manager, _m2m_extract_pk(target, manager.relation.related_pk)))
  end
  return ids
end

# Does the through table carry columns beyond `id` and the two relationship FKs? `true` disables the
# direct mutators below — PormG cannot invent values for a column it does not know about.
#
# #363 made this STRUCTURAL. It used to re-resolve the through model out of the owner's module by
# name and read a `QueryBuildError` as "not registered ⇒ auto-generated ⇒ safe to mutate", which is
# fail-OPEN: any relation whose through model the scan could not reach silently unlocked the
# mutators. That was reachable, not theoretical — `through = <a PormGModel object>` is taken inline
# by `_relation_from_many_to_many`'s `field.through isa PormGModel` arm, with no module lookup at
# all (it does not even reach `Models._resolve_model_reference`), so a model that
# is not reachable BY NAME from the owner's module was invisible here while its extra columns were
# very real. (Only by name: `Models.get_all_models` makes a second pass with `usings=true` since
# #354, so a `using`-brought binding did resolve. A qualified `Other.Membership` reference, or a
# model built and passed by value, did not.)
#
# The relation now records the model itself (`through_model_resolved`, `Models.jl`), so the question
# is answered from the relation alone: no module, no reflection, no exception-as-signal. `nothing`
# means the join table is synthesized by the migration planner, which builds it as exactly `id` plus
# the two FKs — so `false` there is a fact about how that table is constructed, not an assumption
# about a lookup that failed.
#
# `_m2m_model_from_binding` keeps one caller (the descriptor below), where a `QueryBuildError` is now
# just an error rather than a signal; retiring that last reflection against `related_model_resolved`
# is #68/#41.
function _m2m_has_extra_fields(manager::ManyToManyManager)::Bool
  through_model = manager.relation.through_model_resolved
  through_model === nothing && return false

  # The FIELD names, not the columns (#377). This is the one reader of the pair that asks a question
  # about the through MODEL's shape rather than about SQL, so it takes the field slot while the four
  # mutators below take the column slot. Reading `*_column` here would report a through model whose
  # foreign keys declare a `db_column` as carrying two extra fields, and lock its mutators.
  owner_col = manager.relation.owner_field
  related_col = manager.relation.related_field

  for field_name in keys(through_model.fields)
    clean_name = strip(field_name, '"')
    if clean_name != "id" && clean_name != owner_col && clean_name != related_col
      return true
    end
  end
  return false
end

function (descriptor::ManyToManyDescriptor)(owner)
  owner_id = _m2m_extract_pk(owner, descriptor.relation.owner_pk)
  owner_module = descriptor.owner_model._module
  owner_module === nothing && throw(InvalidConfigurationError("Many-to-many descriptor $(descriptor.accessor) requires initialized models. Call set_models() before using it."))
  related_model = _m2m_model_from_binding(owner_module, descriptor.relation.related_binding, descriptor.relation.related_model)
  return ManyToManyManager(descriptor.owner_model, related_model, descriptor.relation, owner_id)
end

# #1002: the related rows linked to the owner, as a semi-join — `<related pk> IN (SELECT <related pk> …
# through the link table … WHERE <owner pk> = $1)`. Filtering the related rows through the inverse
# accessor directly joins the link table onto them, a to-many join the cardinality check refuses: it
# cannot know the link pair is unique. The `IN` asks the question the manager means, and returns one row
# per related row whatever the link table holds, so `all()` stays a queryset a caller can chain.
function _m2m_query(manager::ManyToManyManager)
  linked = object(manager.related_model)
  linked.object.connect_key = manager.owner_model.connect_key
  linked.filter("$(manager.relation.inverse_accessor)__$(manager.relation.owner_pk)" => manager.owner_id)
  linked.values(manager.relation.related_pk)
  q = object(manager.related_model)
  q.object.connect_key = manager.owner_model.connect_key
  q.filter("$(manager.relation.related_pk)__@in" => linked)
  q.values("*")
  return q
end

function add(manager::ManyToManyManager, targets...)
  _m2m_has_extra_fields(manager) && throw(QueryBuildError("Cannot use direct many-to-many manager mutators (add, remove, clear, set) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  target_ids = _m2m_target_ids(manager, targets)
  isempty(target_ids) && return nothing

  settings, connection, conn_key = _m2m_settings(manager)
  !settings.change_data && throw(_write_not_allowed("many-to-many add", conn_key))

  table_name = safe_table_identifier(manager.relation.through_table, connection)
  owner_column = safe_column_identifier(manager.relation.owner_column, connection)
  related_column = safe_column_identifier(manager.relation.related_column, connection)
  owner_value = _m2m_format_owner(manager)
  # The related key's field: PostgreSQL types the targets' array from it, and the dedupe below compares
  # an integer key's text as its number (#1413).
  related_pk_field = manager.related_model.fields[manager.relation.related_pk]

  _m2m_add!(connection, settings, table_name, owner_column, related_column, owner_value, target_ids,
            related_pk_field)
  return nothing
end

# #1355: the target ids of one write in groups that each fit one statement under the connection's bind
# limit (`_backend_parameter_limit`, as the bulk writers size theirs, #84) — `per_target` parameters for
# each id plus `fixed` for the statement. A write of more groups than one runs them in one transaction,
# the caller's if one is open (`transaction_connection_for`), so a later group that fails leaves none
# of them behind.
function _m2m_id_chunks(connection, target_ids::Vector{Any}, per_target::Int, fixed::Int, op::Symbol)
  per_statement = _effective_chunk_size(0, per_target, fixed, _backend_parameter_limit(connection), op,
                                        _backend_name(connection))
  return collect(Iterators.partition(target_ids, per_statement))
end
function _m2m_in_one_transaction(f, settings, statements::Int)
  statements <= 1 && return f()
  transaction_connection_for(settings) === nothing || return f()
  return run_in_transaction(f, settings)
end

# Insert each (owner, target) pair that is not there yet, one method per engine and one statement per
# add, or per group of targets where the engine's bind limit splits it (#1413). Every engine inserts
# with `INSERT … SELECT … WHERE NOT EXISTS`, idempotent whether or not the through table has a unique
# constraint (auto-generated through tables have one; explicit through models typically do not).
# SQLite's `INSERT OR IGNORE` skipped a link only on that unique key, so an explicit through model
# without one got a row per repeat (#1473). Groups run in one transaction, the caller's if one is open,
# so a target that fails (an id with no row) leaves none of them linked (#1399).
#
# One statement does not see the rows it inserts itself, so a target repeated within one add would
# pass `NOT EXISTS` twice: two rows on a through table without a unique key, an `IntegrityError` on
# one with it. The per-target statements this replaced each saw the one before, so repeats linked
# once; `_m2m_distinct_ids` keeps that, before the targets are split into groups.
#
# An integer key's integer text is bound as its integer. The formatter keeps `"5"` as text, which the
# column compares as its number (`"5.0"` stays text, as before): two spellings of one target would otherwise both pass the dedupe, and
# on MySQL a `VALUES` column mixing numbers and text becomes text, compared with the key as a double.
function _m2m_distinct_ids(target_ids::AbstractVector, related_pk_field::PormGField)::Vector{Any}
  integer_key = _m2m_integer_key(related_pk_field)
  seen = Set{Any}()
  out = Any[]
  for raw in target_ids
    id = _m2m_bound_id(raw, integer_key)
    id in seen && continue
    push!(seen, id)
    push!(out, id)
  end
  return out
end
_m2m_integer_key(field::PormGField)::Bool = getproperty(field, :type) in ("INTEGER", "BIGINT", "SMALLINT", "INTEGER UNSIGNED")
_m2m_bound_id(id::AbstractString, integer_key::Bool) = integer_key ? something(tryparse(Int64, id), id) : id
_m2m_bound_id(id, ::Bool) = id

# PostgreSQL: one statement per add, whatever the number of targets — three parameters, the targets in
# one array typed as the related key's column is (`_pg_bulk_param_type`, as the bulk writers type their
# `unnest` arrays, #672), each element as the bulk writers bind it (`_pg_array_element`).
function _m2m_add!(connection::PormGPostgres, settings, table_name, owner_column, related_column,
                   owner_value, target_ids, related_pk_field::PormGField)
  ids = _m2m_distinct_ids(target_ids, related_pk_field)
  parameters = get_parameter(connection)
  set_context!(parameters, :select)
  owner_ph = add_parameter!(parameters, owner_value)
  targets_ph = add_parameter!(parameters, Any[_pg_array_element(id) for id in ids];
                              sql_type = "$(_pg_bulk_param_type(related_pk_field, connection))[]")
  owner_ph2 = add_parameter!(parameters, owner_value)
  sql = "INSERT INTO $table_name ($owner_column, $related_column) " *
        "SELECT $owner_ph, \"u\".\"x\" FROM unnest($targets_ph) AS \"u\"(\"x\") " *
        "WHERE NOT EXISTS (" *
          "SELECT 1 FROM $table_name AS \"e\" " *
          "WHERE \"e\".$owner_column = $owner_ph2 AND \"e\".$related_column = \"u\".\"x\"" *
        ");"
  fetch(settings, sql, parameters)
  return nothing
end

# MySQL: one statement per group of targets, two parameters a target, the groups split under the
# driver's bind limit (`_m2m_id_chunks`, 4096 by default) and run in one transaction. The statement
# reads its own target table in the `NOT EXISTS`, which MySQL accepts for an INSERT (measured on 8.4,
# #1130 phase 3c-2).
function _m2m_add!(connection::PormGMySQL, settings, table_name, owner_column, related_column,
                   owner_value, target_ids, related_pk_field::PormGField)
  chunks = _m2m_id_chunks(connection, _m2m_distinct_ids(target_ids, related_pk_field), 2, 0, :many_to_many_add)
  _m2m_in_one_transaction(settings, length(chunks)) do
    for chunk in chunks
      parameters = get_parameter(connection)
      set_context!(parameters, :select)
      rows = String[]
      for target_id in chunk
        owner_placeholder = add_parameter!(parameters, owner_value)
        target_placeholder = add_parameter!(parameters, target_id)
        push!(rows, "ROW($owner_placeholder, $target_placeholder)")
      end
      sql = "INSERT INTO $table_name ($owner_column, $related_column) " *
            "SELECT `v`.`o`, `v`.`r` FROM (VALUES $(join(rows, ", "))) AS `v` (`o`, `r`) " *
            "WHERE NOT EXISTS (" *
              "SELECT 1 FROM $table_name AS `e` WHERE `e`.$owner_column = `v`.`o` AND `e`.$related_column = `v`.`r`" *
            ");"
      fetch(settings, sql, parameters)
    end
  end
  return nothing
end

# SQLite: one statement per group of targets, two parameters a target, the groups split under the bind
# limit (#1355) and run in one transaction. The pairs are a CTE with named columns, as SQLite's
# `bulk_update` names its `source` (#1473). SQLite serializes writers, so nothing links a pair between
# the `NOT EXISTS` and the insert.
function _m2m_add!(connection::PormGSQLite, settings, table_name, owner_column, related_column, owner_value,
                   target_ids, related_pk_field::PormGField)
  chunks = _m2m_id_chunks(connection, _m2m_distinct_ids(target_ids, related_pk_field), 2, 0, :many_to_many_add)
  _m2m_in_one_transaction(settings, length(chunks)) do
    for chunk in chunks
      parameters = get_parameter(connection)
      set_context!(parameters, :select)
      groups = String[]
      for target_id in chunk
        owner_placeholder = add_parameter!(parameters, owner_value)
        target_placeholder = add_parameter!(parameters, target_id)
        push!(groups, "($owner_placeholder, $target_placeholder)")
      end
      sql = "WITH \"v\"(\"o\", \"r\") AS (VALUES $(join(groups, ", "))) " *
            "INSERT INTO $table_name ($owner_column, $related_column) SELECT \"v\".\"o\", \"v\".\"r\" FROM \"v\" " *
            "WHERE NOT EXISTS (" *
              "SELECT 1 FROM $table_name AS \"e\" WHERE \"e\".$owner_column = \"v\".\"o\" AND \"e\".$related_column = \"v\".\"r\"" *
            ");"
      fetch(settings, sql, parameters)
    end
  end
  return nothing
end

function remove(manager::ManyToManyManager, targets...)
  _m2m_has_extra_fields(manager) && throw(QueryBuildError("Cannot use direct many-to-many manager mutators (add, remove, clear, set) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  target_ids = _m2m_target_ids(manager, targets)
  isempty(target_ids) && return nothing

  settings, connection, conn_key = _m2m_settings(manager)
  !settings.change_data && throw(_write_not_allowed("many-to-many remove", conn_key))

  table_name = safe_table_identifier(manager.relation.through_table, connection)
  owner_column = safe_column_identifier(manager.relation.owner_column, connection)
  related_column = safe_column_identifier(manager.relation.related_column, connection)
  owner_value = _m2m_format_owner(manager)

  # #1355: one `DELETE … IN (…)` per group of targets, one parameter each plus the owner's.
  chunks = _m2m_id_chunks(connection, target_ids, 1, 1, :many_to_many_remove)
  _m2m_in_one_transaction(settings, length(chunks)) do
    for chunk in chunks
      parameters = get_parameter(connection)
      set_context!(parameters, :where)
      owner_placeholder = add_parameter!(parameters, owner_value)
      target_placeholders = String[add_parameter!(parameters, target_id) for target_id in chunk]
      sql = "DELETE FROM $table_name WHERE $owner_column = $owner_placeholder AND " *
            "$related_column IN ($(join(target_placeholders, ", ")));"
      fetch(settings, sql, parameters)
    end
  end
  return nothing
end

function clear(manager::ManyToManyManager)
  _m2m_has_extra_fields(manager) && throw(QueryBuildError("Cannot use direct many-to-many manager mutators (add, remove, clear, set) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  settings, connection, conn_key = _m2m_settings(manager)
  !settings.change_data && throw(_write_not_allowed("many-to-many clear", conn_key))

  parameters = get_parameter(connection)
  set_context!(parameters, :where)
  owner_placeholder = add_parameter!(parameters, _m2m_format_owner(manager))
  table_name = safe_table_identifier(manager.relation.through_table, connection)
  owner_column = safe_column_identifier(manager.relation.owner_column, connection)
  fetch(settings, "DELETE FROM $table_name WHERE $owner_column = $owner_placeholder;", parameters)
  return nothing
end

function _m2m_current_ids(manager::ManyToManyManager)::Vector{Any}
  settings, connection, _ = _m2m_settings(manager)
  parameters = get_parameter(connection)
  set_context!(parameters, :where)
  owner_placeholder = add_parameter!(parameters, _m2m_format_owner(manager))
  table_name = safe_table_identifier(manager.relation.through_table, connection)
  owner_column = safe_column_identifier(manager.relation.owner_column, connection)
  related_column = safe_column_identifier(manager.relation.related_column, connection)
  sql = "SELECT $related_column FROM $table_name WHERE $owner_column = $owner_placeholder;"
  rows = fetch(settings, sql, parameters) |> Tables.rowtable
  isempty(rows) && return Any[]
  return Any[row[Symbol(manager.relation.related_column)] for row in rows]
end

function set(manager::ManyToManyManager, targets...)
  _m2m_has_extra_fields(manager) && throw(QueryBuildError("Cannot use direct many-to-many manager mutators (add, remove, clear, set) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  desired_ids = Set(_m2m_target_ids(manager, targets))
  settings, _, _ = _m2m_settings(manager)

  return run_in_transaction(settings) do
    current_ids = Set(_m2m_current_ids(manager))
    to_remove = collect(setdiff(current_ids, desired_ids))
    to_add = collect(setdiff(desired_ids, current_ids))

    !isempty(to_remove) && remove(manager, to_remove)
    !isempty(to_add) && add(manager, to_add)
    return (added=length(to_add), removed=length(to_remove))
  end
end

function Base.getproperty(manager::ManyToManyManager, sym::Symbol)
  if sym === :all
    return () -> _m2m_query(manager)
  elseif sym === :add
    return (targets...) -> add(manager, targets...)
  elseif sym === :remove
    return (targets...) -> remove(manager, targets...)
  elseif sym === :clear
    return () -> clear(manager)
  elseif sym === :set
    return (targets...) -> set(manager, targets...)
  else
    return getfield(manager, sym)
  end
end
