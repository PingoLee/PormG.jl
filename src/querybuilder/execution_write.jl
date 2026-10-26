# Executing a write (#130): `insert` and the `update_or_create` / `get_or_create` paths, with the
# field-keyed rows they hand back; the sequence sync that `execution_bulk.jl` and
# `resync_sequences` call (single-row `insert` does not resync); `update`, with the join and
# mutation-predicate machinery `deletion.jl` and `execution_bulk.jl` share; and a `PormGRow`'s
# `save` / `delete`. Reads are in `execution_read.jl`, bulk writes in `execution_bulk.jl`.

# #800 — the read parser a model FIELD's values need on this connection, or `nothing`. The per-field
# twin of `_projection_parsers`: a row a write hands back carries no projection record, but its
# columns are the model's own, so the field says what each one is. `_pg_bulk_returned!` shares it.
function _field_value_parser(f::PormGField, connection, name)::Union{Function,Nothing}
  kind = _field_read_kind(f)   # #965: a boolean reads as a `Bool` on SQLite too
  return kind === nothing ? nothing : value_parser(kind, connection, name)   # #1110: a raise names the field
end

# Build a Dict{Symbol,Any} from a result row, mapping physical column names back to the
# declared field names so callers always see field-name keys even when a field maps to a
# differently-named column via db_column (#50). No-op shape on the common path.
#
# #800: and parse each field's value through the #564 read table, as `list()` does for the same
# column. This is the row `create()` / `update_or_create` / `get_or_create` hand back (`RETURNING *`
# on PostgreSQL, the `SELECT *` read-back on SQLite), and before this it arrived exactly as the driver
# delivered it — text for every temporal column on SQLite, a bare `Period` for a one-component
# INTERVAL on Postgres.jl — so re-reading the row through a query changed its types. A key that is
# not a field (`__pormg_created`) is left alone.
function _row_to_field_keyed_dict(row, model::PormGModel, connection)::Dict{Symbol,Any}
  dict = if !Models.model_has_db_column(model)
    Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row))
  else
    rev = Dict{String,Symbol}(Models.field_db_column(f, string(k)) => Symbol(k) for (k, f) in model.fields)
    Dict{Symbol,Any}(get(rev, string(k), Symbol(k)) => v for (k, v) in pairs(row))
  end
  for (fname, f) in model.fields
    key = Symbol(fname)
    haskey(dict, key) || continue
    parser = _field_value_parser(f, connection, fname)
    parser === nothing || (dict[key] = parser(dict[key]))
  end
  return dict
end

# Shared row-level INSERT marshalling, extracted from insert() (#30) so insert() and
# _update_or_create() build the identical VALUES body from one place. Fills each missing field
# (default → auto_now/auto_now_add → UUID → skip-if-null-or-pk → else error), reserves a SQLite id
# when the transaction pre-allocated one, then validates every field and collects the quoted physical
# columns and bound params. MUTATES `real_obj.insert` (fills) and `parameters` (binds). Returns
# (quoted_field_columns, param_values, pk_exist, pk_field). The change_data guard stays with the
# caller so it fires before any fill.
function _prepare_row_insert!(real_obj, model::PormGModel, settings, connection, parameters)
  fields = model.field_names

  # check if the fields are in objct.insert
  for field in fields
    if !haskey(real_obj.insert, field)
      # #1032: a generated column is computed by PostgreSQL, never filled or required here.
      Models.is_generated_field(model.fields[field]) && continue
      # check if field allow null or if exist a default value
      if model.fields[field].default !== nothing
        real_obj.insert[field] = model.fields[field].default
      elseif model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formatter(now(TimeZone(settings.time_zone)))
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now_add || model.fields[field].auto_now)
        real_obj.insert[field] = model.fields[field].formatter(today())
      elseif model.fields[field].type == "UUID" && model.fields[field].auto_add
        real_obj.insert[field] = model.fields[field].formatter(UUIDs.uuid4())
      elseif model.fields[field].null || model.fields[field].primary_key
        continue
      else
        throw(InvalidValueError("Error in insert, the field \e[4m\e[31m$(field)\e[0m not allow null"))
      end
    end
  end

  # SQLite reservation handling: if this transaction already pre-allocated ids for the
  # table, consume the next id explicitly instead of relying on AUTOINCREMENT.
  if connection isa PormGSQLite
    auto_pk_fields = [field for field in fields if _is_auto_generated_bulk_primary_key(model.fields[field])]
    if length(auto_pk_fields) == 1
      pk_name = auto_pk_fields[1]
      reserved_max = get_sqlite_reserved_primary_key_max(model, pk_name, connection)
      if reserved_max !== nothing && !haskey(real_obj.insert, pk_name)
        reserved_id = _allocate_sqlite_ids(model, connection, pk_name, 1, settings)[1]
        real_obj.insert[pk_name] = reserved_id
      end
    end
  end

  quoted_field_columns = []
  param_values = []
  pk_exist::Bool = false
  pk_field::Vector{String} = []
  for field in keys(real_obj.insert)
    # Validation checks
    validate_field_data(model, field, real_obj.insert[field], "insert"; allow_primary_key = true)
    Models.is_many_to_many_field(model.fields[field]) && throw(QueryBuildError("ManyToManyField $(model.name).$(field) cannot be written in create(); use $(model.name).$(field)(source_id).add(target_id) after creating the source row"))

    # check if the field is a primary key
    model.fields[field].primary_key && (pk_exist = true; push!(pk_field, field))

     # Add safely quoted physical column (db_column when set) to columns list (#50)
    push!(quoted_field_columns, safe_column_identifier(Models.field_db_column(model.fields[field], field), connection))

    # Format and add value to parameters — one value, never a collection (#712)
    formatted = _format_single(model.fields[field], field, real_obj.insert[field], "insert"; conn = connection)
    push!(param_values, add_parameter!(parameters, formatted))

  end

  return quoted_field_columns, param_values, pk_exist, pk_field
end

function insert(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, _SQLEngine} = nothing, show_query::Symbol = :execute)
real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
  ensure_transaction_scope(model, connection)
  
  # Collect column names and parameter values
  parameters = get_parameter(connection)
  # For INSERT, all params go into :select bucket (VALUES clause is the only positioned section)
  set_context!(parameters, :select)

  # check if is allowed to insert
  !settings.change_data && throw(_write_not_allowed("insert", conn_key))

  # Fill defaults/auto_now/auto_now_add/UUID, reserve SQLite ids, validate, and collect the quoted
  # physical columns + bound VALUES params. Shared with _update_or_create (#30) so both build the
  # identical INSERT body from one place.
  quoted_field_columns, param_values, _, _ =
    _prepare_row_insert!(real_obj, model, settings, connection, parameters)

  # construct the SQL statement
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  sql = """
  INSERT INTO $(safe_table_name) (
    $(join(quoted_field_columns, ", "))
  ) VALUES (
    $(join(param_values, ", "))
  )
  """

  # What executes, so inspection shows it (#48): PostgreSQL appends `RETURNING *`, SQLite runs the
  # plain INSERT and reads the row back out-of-band (see below). `_update_or_create` already showed
  # its RETURNING; this terminal showed SQL it never sent.
  exec_sql = _insert_returns_rows(connection) ? sql * " RETURNING *;" : sql
  if show_query !== :execute
    return _show_query_result(show_query, exec_sql, connection, model.name, :insert;
                            parameters=parameters)
  end

  # Execute safely. create()/insert() return a PormGRow (#166) — the same object get()/first()/
  # list()/update_or_create() return — so a created row supports dot-access and create → mutate →
  # .save(). `_row_to_field_keyed_dict` still builds the Dict; we wrap it. RETURNING */SELECT *
  # include every column (incl. the pk), so the row is .save()-able; `_dirty` starts empty.
  if _insert_returns_rows(connection)
    result = fetch(settings, exec_sql, parameters)
    # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
    # write supplied an explicit primary key.
    return PormGRow(_row_to_field_keyed_dict(Tables.rowtable(result) |> Base.first, model, connection), model)
  end
  # SQLite and MySQL: a plain INSERT, then the inserted row read back with a SELECT on the SAME
  # connection (`_inserted_row_query`). MySQL has no `RETURNING` (#1266). SQLite deliberately avoids
  # `INSERT ... RETURNING *`: it can hang indefinitely inside SQLite/libsqlite3 for some table shapes
  # (observed: an AUTOINCREMENT primary key that migrations left in a non-first column position). The
  # previous broad `catch` masked that hang/error by re-running a plain INSERT, which then tripped a
  # spurious UNIQUE violation because the first INSERT had already written the row. Reading the whole
  # row keeps the returned row consistent with the Postgres `RETURNING *` path — all columns present,
  # including nullable ones the caller did not set.
  #
  # The empty-rows fallback (no key to read by, or the read-back returned nothing, which should not
  # happen after a successful INSERT) builds the dict from real_obj.insert only, so it may omit an
  # unreserved AUTOINCREMENT pk, and its values are the caller's inputs, not parsed reads (#800 types
  # only a row the database handed back). The wrapped PormGRow is still returned; if that degenerate
  # row is later mutated and .save()d, save() throws a clear "required key" error — no regression over
  # the previous incomplete-Dict return.
  do_insert = () -> begin
    result = fetch(settings, sql, parameters)
    read_back = _inserted_row_query(connection, model, real_obj.insert, result, safe_table_name)
    rows = read_back === nothing ? () :
      (read_back[2] === nothing ? fetch(settings, read_back[1]) : fetch(settings, read_back[1], read_back[2])) |>
      Tables.rowtable
    isempty(rows) ?
      Dict{Symbol, Any}(Symbol(k) => v for (k, v) in pairs(real_obj.insert)) :
      _row_to_field_keyed_dict(rows[1], model, connection)
  end

  # INSERT and the row read-back must run on one connection (last_insert_rowid() and the OK packet's
  # id are per statement on that connection). Reuse the active transaction if there is one; otherwise
  # pin a connection for the pair.
  result_dict = transaction_connection_for(settings) !== nothing ?
    do_insert() : run_in_transaction(do_insert, settings)

  # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
  # write supplied an explicit primary key.
  return PormGRow(result_dict, model)

end

# The unique keys a row of `model` can collide on (#1267): the primary key, each `unique` field
# (a `OneToOneField` included), each declared `UniqueConstraint`, and the `(owner, related)` index of
# an auto many-to-many join table. `kind` is `:pk`, `:field` or `:constraint`, or `:text` for a
# functional or partial constraint, whose SQL text PormG cannot evaluate against a row.
function _unique_keys(model::PormGModel)::Vector{@NamedTuple{fields::Vector{String}, kind::Symbol}}
  keys = @NamedTuple{fields::Vector{String}, kind::Symbol}[]
  for name in model.field_names
    f = model.fields[name]
    if f.primary_key
      push!(keys, (fields = [name], kind = :pk))
    elseif hasproperty(f, :unique) && f.unique === true
      push!(keys, (fields = [name], kind = :field))
    end
  end
  for c in Models._declared_unique_constraints(model)
    push!(keys, (fields = c.fields, kind = Models._unique_holds_text(c) ? :text : :constraint))
  end
  # The join table's own index is not a declared constraint: its columns name its two fields.
  auto = Models._auto_join_unique_columns(model)
  if auto !== nothing
    by_column = Dict(Models.model_column(model, f) => f for f in model.field_names)
    push!(keys, (fields = [by_column[auto[1]], by_column[auto[2]]], kind = :constraint))
  end
  return keys
end

# Whether the rows about to be inserted can conflict on `key`. A key over SQL text always can. A member
# PormG mints and the caller left out (an auto id, a UUID `auto_add`) is a new value, so the key cannot
# (`minted`). Otherwise every member must hold a value (`holds`): one the INSERT binds that is not
# NULL, or a database default. A NULL member never conflicts. (A generated column is PostgreSQL's,
# #1032, so no MySQL row reaches here with one.) The predicates read one row (`_row_conflict_reading`)
# or a whole frame (`_frame_conflict_reading`, `bulk_insert`).
function _can_conflict(key, holds, minted)::Bool
  key.kind === :text && return true
  any(minted, key.fields) && return false
  return all(holds, key.fields)
end

_has_db_default(f)::Bool = hasproperty(f, :db_default) && f.db_default !== nothing

# One row (`insert`, after `_prepare_row_insert!` filled its defaults; `given`, the fields the caller
# wrote before that fill).
function _row_conflict_reading(model::PormGModel, insert::AbstractDict, given)
  holds = name -> haskey(insert, name) ? !(insert[name] === nothing || insert[name] === missing) :
                                         _has_db_default(model.fields[name])
  minted = name -> !(name in given) && _is_minted_value(model.fields[name])
  return holds, minted
end

# A value no other row holds when the caller leaves it out: an id the database generates, or a UUID
# PormG mints (`auto_add`), primary key or not.
_is_minted_value(f)::Bool = _is_pormg_minted_bulk_primary_key(f) ||
  (f.type == "UUID" && hasproperty(f, :auto_add) && f.auto_add === true)

# MySQL's upsert names no target (no `upsert_conflict_target` row), so before any SQL (#1267):
#   - the lookup must be one of the model's unique keys, exactly. PostgreSQL and SQLite raise for any
#     other lookup when the INSERT runs; MySQL would insert a duplicate without a word;
#   - for `update_or_create`, no other key may be one the row can conflict on: `ON DUPLICATE KEY UPDATE`
#     would update the row THAT key matched (measured: a conflict on `code` rewrote another driver).
# `get_or_create` never updates a row, so a conflict on another key raises `IntegrityError` there, as
# on PostgreSQL.
function _refuse_unnamed_upsert_target(op::String, model::PormGModel, target_fields::Vector{String},
                                       insert::AbstractDict, given, connection)
  holds, minted = _row_conflict_reading(model, insert, given)
  _refuse_unnamed_target(model, target_fields, holds, minted, connection;
    what = "$(op) on $(model.name)", noun = "lookup field(s)", others = op == "update_or_create",
    not_unique = "For a lookup that is not unique, use filter(...).first(), then create(...).",
    subject = "This row", effect = "update the row that key matches",
    alternative = "Leave those fields NULL or unset, or use filter(...).first(), then update(...) or create(...).")
end

# The check itself, for one row or a frame (`bulk_insert`, `_refuse_unnamed_bulk_target`): the target
# must be a declared plain unique key, and when `others`, no other key may be one the rows can conflict
# on. A key over the target's fields and more can only match the target's own row: not another conflict.
function _refuse_unnamed_target(model::PormGModel, target_fields::Vector{String}, holds, minted, connection;
                                what::String, noun::String, others::Bool, not_unique::String,
                                subject::String, effect::String, alternative::String)
  _supports(connection, :upsert_conflict_target) && return nothing
  keys = _unique_keys(model)
  target = Set(target_fields)
  any(k -> k.kind !== :text && Set(k.fields) == target, keys) || throw(QueryBuildError(
    "$(what) requires its $(noun) ($(join(target_fields, ", "))) to be a unique key " *
    "of the model: the primary key, a `unique = true` field, or a plain (not partial or functional) " *
    "UniqueConstraint over exactly those fields. $(_backend_name(connection)) finds the existing row by " *
    "its unique keys. $(not_unique)"))
  others || return nothing
  conflicting = [k for k in keys if !(target ⊆ Set(k.fields)) && _can_conflict(k, holds, minted)]
  isempty(conflicting) && return nothing
  names = join(unique(k.kind === :text ? "a functional or partial UniqueConstraint" :
                      "($(join(k.fields, ", ")))" for k in conflicting), ", ")
  throw(_capability_error(connection, :upsert_conflict_target, what;
    why = "$(subject) can also conflict on $(names), and $(_backend_name(connection))'s ON DUPLICATE KEY " *
          "UPDATE would $(effect). $(alternative)"))
end

# Row-level upsert (#30) behind `objects.update_or_create`. Builds the same INSERT body as insert()
# via _prepare_row_insert!, appends `ON CONFLICT (target) DO UPDATE SET set…` (reusing #123's
# Dialect.on_conflict_clause), and returns `(PormGRow, created::Bool)`.
#
# `target_fields` (the lookup keys) and `set_fields` (defaults + auto_now) are LOGICAL field names,
# resolved to quoted physical columns here (like bulk_insert). Caller (_update_or_create!) has
# already merged lookup+defaults into real_obj.insert and validated the fields.
#
# created detection per backend:
#   PostgreSQL — single atomic `... RETURNING *, (xmax = 0) AS "__pormg_created"`; xmax = 0 ⇒ inserted.
#   SQLite     — RETURNING is avoided (see insert()) and last_insert_rowid() is unreliable on DO
#                UPDATE, so: pre-check existence by the target, run the upsert, read the row back by
#                the target — all on one pinned connection under BEGIN IMMEDIATE + the writer lock,
#                which serializes writers so `existed` is race-free.
#   MySQL      — no RETURNING; the statement's own report, then the row read back by the target
#                (`_run_update_or_create(::PormGMySQL, …)`).
function _update_or_create(objct::SQLObject; target_fields::Vector{String},
    set_fields::Vector{String}, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model

  settings, connection, conn_key = get_settings(objct)
  ensure_transaction_scope(model, connection)

  parameters = get_parameter(connection)
  set_context!(parameters, :select)

  !settings.change_data && throw(_write_not_allowed("update_or_create", conn_key))

  given = Set{String}(keys(real_obj.insert))
  quoted_field_columns, param_values, _, _ =
    _prepare_row_insert!(real_obj, model, settings, connection, parameters)
  _refuse_unnamed_upsert_target("update_or_create", model, target_fields, real_obj.insert, given, connection)

  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)

  # Logical → quoted physical (db_column-aware), exactly as bulk_insert renders its clause.
  qtarget = String[safe_column_identifier(Models.model_column(model, f), connection) for f in target_fields]
  qset    = String[safe_column_identifier(Models.model_column(model, f), connection) for f in set_fields]
  clause  = Dialect.on_conflict_clause(:update, qtarget, qset, connection)

  sql = """
  INSERT INTO $(safe_table_name) (
    $(join(quoted_field_columns, ", "))
  ) VALUES (
    $(join(param_values, ", "))
  )
  $(clause)
  """

  return _run_update_or_create(connection, settings, real_obj, model, sql, parameters, safe_table_name,
                               target_fields, show_query)
end

# Run the upsert `sql` built above and return `(PormGRow, created)`, one method per engine.
function _run_update_or_create(connection::PormGPostgres, settings, real_obj, model, sql, parameters,
                               safe_table_name, target_fields, show_query)
  # Atomic upsert; `(xmax = 0)` distinguishes the inserted vs updated tuple version.
  exec_sql = sql * " RETURNING *, (xmax = 0) AS \"__pormg_created\";"
  if show_query !== :execute
    return _show_query_result(show_query, exec_sql, connection, model.name, :insert; parameters=parameters)
  end
  result = fetch(settings, exec_sql, parameters)
  dict = _row_to_field_keyed_dict(Tables.rowtable(result) |> Base.first, model, connection)
  # Strip the sentinel so it isn't a phantom field; fail safe (false) if it is ever absent.
  created_raw = pop!(dict, Symbol("__pormg_created"), false)
  created = created_raw === true || created_raw == 1   # always a Bool (xmax = 0 → PG boolean)
  # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
  # write supplied an explicit primary key.
  return (PormGRow(dict, model), created)
end

function _run_update_or_create(connection::PormGSQLite, settings, real_obj, model, sql, parameters,
                               safe_table_name, target_fields, show_query)
  if show_query !== :execute
    # Honest to what executes: INSERT + ON CONFLICT, no RETURNING (created detection is out-of-band).
    return _show_query_result(show_query, sql, connection, model.name, :insert; parameters=parameters)
  end

  # Conflict-target WHERE on the physical target columns. The placeholder is a positional `?`
  # (this branch is SQLite-only), so the WHERE text is stable and is built once; the pre-check and
  # read-back each bind a FRESH parameter object (no cross-fetch reuse). The bound values are the
  # formatted lookup values — matching exactly what the INSERT bound.
  target_where = join(
    ["$(safe_column_identifier(Models.model_column(model, f), connection)) = ?" for f in target_fields],
    " AND ")
  precheck_sql = "SELECT 1 FROM $(safe_table_name) WHERE $(target_where) LIMIT 1;"
  readback_sql = "SELECT * FROM $(safe_table_name) WHERE $(target_where) LIMIT 1;"
  make_target_params = () -> begin
    tp = get_parameter(connection)
    set_context!(tp, :where)
    for f in target_fields
      add_parameter!(tp, real_obj.insert[f] |> _write_formatter(model.fields[f], connection))
    end
    tp
  end

  do_upsert = () -> begin
    existed = !isempty(fetch(settings, precheck_sql, make_target_params()) |> Tables.rowtable)
    fetch(settings, sql, parameters)
    rows = fetch(settings, readback_sql, make_target_params()) |> Tables.rowtable
    dict = isempty(rows) ?
      Dict{Symbol, Any}(Symbol(k) => v for (k, v) in pairs(real_obj.insert)) :
      _row_to_field_keyed_dict(rows[1], model, connection)
    (dict, !existed)
  end

  # Pre-check + upsert + read-back must share one connection under one BEGIN IMMEDIATE.
  dict, created = transaction_connection_for(settings) !== nothing ?
    do_upsert() : run_in_transaction(do_upsert, settings)

  # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
  # write supplied an explicit primary key.
  return (PormGRow(dict, model), created)
end

# MySQL (#1267): `INSERT … AS __pormg_new ON DUPLICATE KEY UPDATE`, whose target
# `_refuse_unnamed_upsert_target` has checked is the one key the row can conflict on. `created` comes
# from the statement's own report, measured on 8.4 under the `found_rows` flag the pool connects with:
# an insert counts 1, a duplicate it changed 2, a duplicate already holding those values 1. The OK
# packet's id is the inserted row's AUTO_INCREMENT value (generated or supplied), the matched row's
# id on a changed duplicate, and 0 on an unchanged one. So with an AUTO_INCREMENT primary key,
# `count == 1 && id != 0` is an insert, exactly (`_odku_created`). Without one the OK packet says 0 for
# both an insert and an unchanged duplicate, and two plain reads by the target decide: a pre-check, and
# after the statement a read that misses a row committed after the snapshot. Neither takes a lock (a
# `FOR UPDATE` on a missing key deadlocked two sessions creating different keys, measured). Under
# REPEATABLE READ they leave one race: a row another session deletes between the pre-check and the
# statement, which then inserts it again, is reported as existing.
function _run_update_or_create(connection::PormGMySQL, settings, real_obj, model, sql, parameters,
                               safe_table_name, target_fields, show_query)
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model.name, :insert; parameters=parameters)
  end
  pk = get_model_pk_field(model)
  # A row that writes 0 into the AUTO_INCREMENT key stores 0 (the session's `NO_AUTO_VALUE_ON_ZERO`), and
  # the OK packet's id is then 0 for the insert too, so the reads decide, as without AUTO_INCREMENT.
  counts_insert = pk !== nothing && _is_auto_generated_bulk_primary_key(model.fields[String(pk)]) &&
                  !_writes_zero_key(real_obj.insert, model, String(pk))
  do_upsert = () -> begin
    existed = counts_insert ? false :
      !isempty(fetch(settings, _select_by_target("SELECT 1", real_obj, model, target_fields,
                                                 safe_table_name, connection)...) |> Tables.rowtable)
    result = fetch(settings, sql, parameters)
    count = backend_num_affected_rows(connection, result)
    # Without AUTO_INCREMENT, a count of 1 is an insert or an unchanged hit. A plain read tells them apart
    # for a row the pre-check could not see (committed after this transaction's REPEATABLE READ snapshot):
    # it misses that row and sees this transaction's own insert (measured).
    if !counts_insert && !existed && count == 1
      existed = isempty(fetch(settings, _select_by_target("SELECT 1", real_obj, model, target_fields,
                                                          safe_table_name, connection)...) |> Tables.rowtable)
    end
    created = _odku_created(counts_insert, existed, count,
                            counts_insert ? backend_last_insert_id(connection, result) : 0)
    # A locking read: under REPEATABLE READ a plain one reads the transaction's snapshot, which misses
    # a row another session committed after it, when this statement hit it unchanged (measured). The
    # ODKU already locked that row, so the read waits on nothing.
    rows = fetch(settings, _select_by_target("SELECT *", real_obj, model, target_fields,
                                             safe_table_name, connection; lock = true)...) |> Tables.rowtable
    isempty(rows) && throw(StatementError(_backend_name(connection),
      "update_or_create: the statement reported success, but the $(model.name) row could not be read " *
      "back: a trigger may have dropped it, or the lookup does not match what was stored."))
    (_row_to_field_keyed_dict(rows[1], model, connection), created)
  end
  # The statement and its read-back share one connection, so the report and the row are this call's.
  dict, created = transaction_connection_for(settings) !== nothing ?
    do_upsert() : run_in_transaction(do_upsert, settings)
  return (PormGRow(dict, model), created)
end

# Whether one row's `ON DUPLICATE KEY UPDATE` inserted, from its report (the table above): with an
# AUTO_INCREMENT primary key (`counts_insert`), a count of 1 and a non-zero id; otherwise the pre-check
# found no row, and the count is not the 2 of a duplicate it changed.
_odku_created(counts_insert::Bool, existed::Bool, count::Integer, id::Integer)::Bool =
  counts_insert ? (count == 1 && id != 0) : (!existed && count != 2)

# Whether the row writes 0 into its key `name`, as the INSERT binds it: a number, or text that reads as
# one (`"00"` stores 0, measured through update_or_create).
function _writes_zero_key(insert, model, name::String)::Bool
  haskey(insert, name) || return false
  bound = _format_single(model.fields[name], name, insert[name], "insert")
  bound isa Number && return iszero(bound)
  number = bound isa AbstractString ? tryparse(Float64, strip(bound)) : nothing
  return number !== nothing && iszero(number)
end

# `<head> FROM <table> WHERE <target> = <the value the INSERT bound> … LIMIT 1`, on a fresh parameter
# object each call: a statement's parameters are never reused across fetches. `lock` makes it a
# locking read (`FOR SHARE`), which reads the latest committed row rather than the snapshot.
function _select_by_target(head, real_obj, model, target_fields, safe_table_name, connection; lock::Bool = false)
  params = get_parameter(connection)
  set_context!(params, :where)
  # A JSON column's document compares as JSON (`_json_document_marker`): on MySQL a bare marker is a
  # JSON string, which no stored document equals.
  marker(f) = (ph = add_parameter!(params, real_obj.insert[f] |> _write_formatter(model.fields[f], connection));
               _is_json_field(model.fields[f]) ? _json_document_marker(connection, ph) : ph)
  where_sql = join(["$(safe_column_identifier(Models.model_column(model, f), connection)) = $(marker(f))"
                    for f in target_fields], " AND ")
  return ("$(head) FROM $(safe_table_name) WHERE $(where_sql) LIMIT 1$(lock ? " FOR SHARE" : "");", params)
end

# A missing unique constraint on the ON CONFLICT target surfaces as a driver error at execution
# ("no unique or exclusion constraint matching the ON CONFLICT specification" on PostgreSQL; "ON
# CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint" on SQLite). Re-raise it as an
# actionable PormGError — this is the one place a Django user is surprised, because Django's
# get_or_create does SELECT-then-INSERT and needs no unique constraint (#208).
function _rethrow_conflict_target_error(e, model::PormGModel, target_fields::Vector{String})
  if _is_conflict_target_error(e)
    throw(QueryBuildError(
      "get_or_create on $(model.name) requires a UNIQUE constraint on the lookup field(s) " *
      "(\e[4m\e[31m$(join(target_fields, ", "))\e[0m) — they are the ON CONFLICT target. Add a unique " *
      "constraint/index on them, or for non-unique lookups use filter(...).first() then create(...)."))
  end
  rethrow(e)
end

# PostgreSQL by its SQLSTATE, `42P10` (invalid_column_reference): the message is localized by
# `lc_messages`, so a `pt_BR` server never matched the text (#1001). SQLite reports no SQLSTATE and
# does not localize, so its message stays the signal.
function _is_conflict_target_error(e)
  e isa DatabaseError && e.sqlstate !== nothing && return e.sqlstate == "42P10"
  low = lowercase(sprint(showerror, e))
  # server-text-match-ok: SQLite's arm (a PostgreSQL error with a SQLSTATE returned above); SQLite has no SQLSTATE and never localizes
  return occursin("on conflict", low) && (occursin("unique", low) || occursin("exclusion", low) ||
         occursin("does not match", low) || occursin("no primary key", low))
end

# get_or_create's get() by the conflict target, unexecuted: through the fluent builder for
# dialect-correct binding, and inside a transaction on the pinned connection (same pattern as save()).
#
# A `JSONField` collection is handed to `filter()` already serialized (#717). `filter()` refused a
# bare vector with no operator at parse time, where it has no model to tell a JSON column from a
# text one (#596's constraint), so `get_or_create("payload" => ["a", "b"])` failed before any SQL.
# (Since #28 a bare vector parses as an equality and is refused at render for any column but an
# `ArrayField`; the serialization below is still what a JSON column needs.)
# As a string it takes the scalar arm and binds the exact text the miss INSERT binds, so the hit read
# matches by the same column equality as the ON CONFLICT target (and `update_or_create`): `jsonb`
# equality on PostgreSQL, the serialized text on SQLite.
function _get_or_create_lookup(model::PormGModel, target_fields::Vector{String}, target_values::AbstractDict)
  q = object(model)
  for f in target_fields
    v = target_values[f]
    if v isa _CollectionValue && _is_json_field(model.fields[f])
      v = Models.format_json_sql(v)
    end
    q.filter(f => v)
  end
  return q
end

# Django-style get_or_create (#208): match-or-insert with NO update on a hit. This is Django's own
# algorithm — get() FIRST, and only on a miss build+run the INSERT — so that columns beyond the
# lookup (NOT NULL fields with no default) are required ONLY when a row is actually created, never
# on a plain hit. `ON CONFLICT (target) DO NOTHING` on the create path is the concurrency guard: if
# a competing writer inserts the same key between our SELECT and INSERT, the insert is skipped (no
# duplicate-key crash) and we re-read the winner. Returns `(PormGRow, created::Bool)`. The lookup
# must be a UNIQUE constraint for the create path to be safe — `_rethrow_conflict_target_error`
# turns the missing-constraint driver error into an actionable message.
function _get_or_create(objct::SQLObject; target_fields::Vector{String}, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model

  settings, connection, conn_key = get_settings(objct)
  ensure_transaction_scope(model, connection)
  !settings.change_data && throw(_write_not_allowed("get_or_create", conn_key))

  # Capture the raw lookup values BEFORE any INSERT marshalling mutates real_obj.insert.
  target_values = Dict{String,Any}(f => real_obj.insert[f] for f in target_fields)

  # A collection lookup value would be refused by the INSERT on a miss, but a hit never builds one:
  # `fetch_by_target` hands it to `filter()`, which raises `FilterError` instead. Refuse it here, the
  # same way on both paths (#712). A `JSONField` collection formats to one string, so it passes, and
  # `_get_or_create_lookup` matches it by that string (#717). A non-collection value is left entirely
  # to the paths below.
  for f in target_fields
    v = target_values[f]
    v isa _CollectionValue || continue
    validate_field_data(model, f, v, "get_or_create"; allow_primary_key = true)
    _format_single(model.fields[f], f, v, "get_or_create")
  end

  # `lock` makes it a locking read (`FOR SHARE`), which reads the latest committed row: MySQL's re-read
  # after a duplicate inside a transaction, whose snapshot may predate the winner (#1267). The failed
  # INSERT already holds that lock on the duplicate, so it waits on nothing; `FOR UPDATE` would ask for
  # more, and two sessions that lost the same race deadlocked on it (measured, 1213).
  fetch_by_target = (; lock::Bool = false) -> begin
    lock || return _get_or_create_lookup(model, target_fields, target_values).first()
    table = safe_table_identifier(Models.model_table_name(model), connection)
    rows = fetch(settings, _select_by_target("SELECT *", real_obj, model, target_fields, table, connection;
                                             lock = true)...) |> Tables.rowtable
    isempty(rows) ? nothing : PormGRow(_row_to_field_keyed_dict(rows[1], model, connection), model)
  end

  # Build the `INSERT ... ON CONFLICT (target) DO NOTHING` a MISS would run. `_prepare_row_insert!`
  # validates/fills the row and requires every NOT NULL column — so this fires (create-time) only
  # when we actually insert. MySQL has no targeted DO NOTHING (no `upsert_conflict_target` row): its
  # miss is a plain INSERT, and the lookup must be a unique key of the model, checked here (#1267).
  build_insert = (parameters) -> begin
    set_context!(parameters, :select)
    given = Set{String}(keys(real_obj.insert))
    quoted_field_columns, param_values, _, _ =
      _prepare_row_insert!(real_obj, model, settings, connection, parameters)
    _refuse_unnamed_upsert_target("get_or_create", model, target_fields, real_obj.insert, given, connection)
    safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
    qtarget = String[safe_column_identifier(Models.model_column(model, f), connection) for f in target_fields]
    clause  = _supports(connection, :upsert_conflict_target) ?
      Dialect.on_conflict_clause(:nothing, qtarget, String[], connection) : ""
    """
    INSERT INTO $(safe_table_name) (
      $(join(quoted_field_columns, ", "))
    ) VALUES (
      $(join(param_values, ", "))
    )
    $(clause)"""
  end

  if show_query !== :execute
    # Honest to what a miss executes: the INSERT + ON CONFLICT DO NOTHING (the get() + read-back are
    # out-of-band SELECTs). Mirrors _update_or_create's inspect contract.
    parameters = get_parameter(connection)
    insert_sql = build_insert(parameters)
    # #48: PostgreSQL sends it with `RETURNING *` (below), so that is what inspection shows.
    shown_sql = _insert_returns_rows(connection) ? insert_sql * " RETURNING *;" : insert_sql
    return _show_query_result(show_query, shown_sql, connection, model.name, :insert; parameters = parameters)
  end

  do_goc = () -> begin
    # Hit → return the existing row WITHOUT building an INSERT (no NOT NULL columns needed).
    existing = fetch_by_target()
    existing !== nothing && return (existing, false)

    # Miss → create, guarded against a concurrent insert of the same key (`_create_on_miss`).
    parameters = get_parameter(connection)
    insert_sql = build_insert(parameters)
    return _create_on_miss(connection, settings, model, insert_sql, parameters, fetch_by_target, target_fields)
  end

  # SQLite: serialize get + insert + read-back so `created` is correct and the create race-guard
  # holds. PostgreSQL's ON CONFLICT is atomic on its own; running inside an ambient tx is fine.
  if _serializes_get_or_create(connection)
    return transaction_connection_for(settings) !== nothing ? do_goc() : run_in_transaction(do_goc, settings)
  end
  return do_goc()
end

# get_or_create's miss: run `insert_sql` and return `(PormGRow, created)`, one method per engine.
function _create_on_miss(connection::PormGPostgres, settings, model, insert_sql, parameters, fetch_by_target,
                         target_fields)
  exec_sql = insert_sql * " RETURNING *;"
  result = try
    fetch(settings, exec_sql, parameters)
  catch e
    _rethrow_conflict_target_error(e, model, target_fields)
  end
  rows = Tables.rowtable(result)
  if !isempty(rows)
    dict = _row_to_field_keyed_dict(Base.first(rows), model, connection)
    # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if
    # this write supplied an explicit primary key.
    return (PormGRow(dict, model), true)
  end
  # Lost the insert race → the row exists now; return the winner, created == false.
  raced = fetch_by_target()
  # #1299: not the caller's call, so not a `UsageError`. The usual cause is a race: the conflicting
  # row was there when the INSERT skipped and another session deleted it before this read (a
  # winner not yet visible to a REPEATABLE READ snapshot is PostgreSQL's own serialization
  # failure). The same call retried can succeed, which is what `OperationalError` signals. A
  # trigger or rule that skips the insert leaves the same empty RETURNING and fails every retry,
  # so the message names it rather than claiming the race.
  raced === nothing &&
    throw(OperationalError(_backend_name(connection),
      "get_or_create: the insert returned no row, and the $(model.name) row could not be read back. " *
      "Usually another session deleted the conflicting row in between, and retrying the call can " *
      "succeed; a trigger or rule that skips the insert gives the same result on every retry."))
  return (raced, false)
end

function _create_on_miss(connection::PormGSQLite, settings, model, insert_sql, parameters, fetch_by_target,
                         target_fields)
  try
    fetch(settings, insert_sql, parameters)         # INSERT ... ON CONFLICT DO NOTHING
  catch e
    _rethrow_conflict_target_error(e, model, target_fields)
  end
  row = fetch_by_target()
  # #1299: not the caller's call, so not a `UsageError`, and no race either: the serialized write
  # lock (`_get_or_create`'s transaction) keeps every other writer out between the INSERT and this read. So the insert
  # stored nothing the lookup finds (a trigger that drops the row, or a PormG fault), and a retry
  # fails the same way: `StatementError`, the landing type for such a fault on the statement path.
  row === nothing &&
    throw(StatementError(_backend_name(connection),
      "get_or_create: the insert reported success, but the $(model.name) row could not be read back: " *
      "a trigger may have dropped it, or the lookup does not match what was stored."))
  # Under the serialized write lock (`_get_or_create`'s transaction) no writer can interleave between the
  # miss-check and this insert, so a fetched-nothing-then-insert is always a real creation.
  # No automatic sequence resync here (#358) — call resync_sequences(Model) explicitly if this
  # write supplied an explicit primary key.
  return (row, true)
end

# MySQL (#1267): a plain INSERT, guarded by the unique index the lookup must be. A concurrent insert of
# the same key makes it raise `IntegrityError`; the row is then re-read by the lookup and returned with
# `created = false`, Django's own recovery. MySQL rolls back only the failed statement, so an open
# transaction stays usable (measured). Inside a transaction the re-read is a locking one: a plain read
# sees the transaction's REPEATABLE READ snapshot, which misses a winner committed after it (measured).
# When the re-read finds nothing, the conflict was on another key, and the `IntegrityError` is the
# answer, as PostgreSQL gives for a conflict on a key that is not the target.
function _create_on_miss(connection::PormGMySQL, settings, model, insert_sql, parameters, fetch_by_target,
                         target_fields)
  try
    fetch(settings, insert_sql, parameters)
  catch e
    e isa IntegrityError || rethrow()
    raced = fetch_by_target(; lock = transaction_connection_for(settings) !== nothing)
    raced === nothing && rethrow()
    return (raced, false)
  end
  row = fetch_by_target()
  # The INSERT succeeded and this read sees it (it committed, or it is the open transaction's own), so
  # a row the lookup does not find was dropped by a trigger, or the lookup does not match what was
  # stored (#1299), as on SQLite.
  row === nothing &&
    throw(StatementError(_backend_name(connection),
      "get_or_create: the insert reported success, but the $(model.name) row could not be read back: " *
      "a trigger may have dropped it, or the lookup does not match what was stored."))
  return (row, true)
end

# Escape a value for interpolation inside a single-quoted SQL literal (#59). `db_table` is
# user-supplied and deliberately not shape-validated, so an embedded `'` would otherwise close the
# literal early. A no-op for every name that does not contain one.
_sql_literal(value::AbstractString)::String = replace(String(value), "'" => "''")

# `_quote_ident_raw` moved to `sanitization.jl` with #394, where it now shares one definition of the
# escape rule with `safe_table_identifier` / `safe_column_identifier`. It stays escape-only for the
# reason it always was (#59): the identifiers reaching it come from the database catalog or from a
# model's own `db_table`, neither of which is free-form user input.
#
# Load-bearing for the unowned-sequence fallback (#344): `setval`'s first argument is `regclass`, so
# PostgreSQL re-parses it as an identifier and CASE-FOLDS any unquoted part. A catalog row reading
# `public | Db_Table_id_seq` interpolated bare becomes `public.db_table_id_seq`, which does not
# exist. `pg_get_serial_sequence` returns its answer already quoted, which is why the owned path
# never needed this.

# A model's physical table as a SQL *string literal* holding a *quoted identifier* — `'"Db_Table"'`.
# The shape both `pg_get_serial_sequence` and `to_regclass` need: each takes TEXT that it re-parses
# as an identifier, so an unquoted mixed-case name folds to lowercase and resolves to nothing (#59).
# Correct for an all-lowercase name too. The two escapes are disjoint — `_quote_ident_raw` only
# touches `"`, `_sql_literal` only `'` — so composing them cannot double-process.
_table_ident_literal(model::PormGModel)::String =
  _sql_literal(_quote_ident_raw(Models.model_table_name(model)))

function _get_owned_sequence_name(connection::PormGPostgres, model::PormGModel, field::String; ignore_tx::Bool = false)
  table_literal = _table_ident_literal(model)
  sequence_df = fetch(
    connection,
    "SELECT pg_get_serial_sequence('$(table_literal)', '$(_sql_literal(field))');";
    ignore_tx=ignore_tx,
  ) |> DataFrames.DataFrame

  if size(sequence_df, 1) == 0 || !("pg_get_serial_sequence" in names(sequence_df))
    return nothing
  end

  sequence_name = sequence_df[1, :pg_get_serial_sequence]
  return ismissing(sequence_name) || isnothing(sequence_name) ? nothing : sequence_name
end

function _update_sequence(model::PormGModel, connection::PormGPostgres, pk_field::Vector{String}, settings::PormGSettings; ignore_tx::Bool = false)
  @pormg_debug true

  # There is deliberately NO configuration gate here (#344) — do not add one back.
  #
  # `!(settings.change_db || settings.django_prefix !== nothing) && return nothing` used to sit on
  # this line, and it was a second guard for an outcome the call sites already decide. A PostgreSQL
  # sequence can only drift when the INSERT supplied an explicit primary key, and every caller
  # already tests exactly that: `pk_exist` (set in `_prepare_row_insert!` only when the insert dict
  # contains a pk field), or — in `execution_bulk.jl`'s recovery path — a duplicate-key error that
  # actually happened. So the old line could never prevent a wasted sync, only suppress a needed one.
  #
  # What it suppressed: every connection with `change_db: false` (the documented production posture)
  # and every connection built by `register_connection`, which defaults both flags off. Those
  # silently accumulated sequence drift, and the bulk duplicate-key self-heal — resync, then retry
  # the same INSERT — re-ran an unrepaired statement and failed identically.
  #
  # `settings` is still read below — but only to ask whether we are inside the caller's
  # transaction when a repair fails, never to decide whether to attempt one.
  for field in pk_field
    # Resolve the PK field to its physical column (db_column when set) — #50.
    col = Models.model_column(model, field)
    sequence_name = nothing

    # The WHOLE body is guarded, not just `setval` (#344). The two catalog reads below run on every
    # explicit-pk insert now that the gate is gone, and they can fail the same ways `setval` can —
    # a pool timeout on the extra acquisition, a connection dropped between the INSERT and the
    # resync. Outside a transaction those would otherwise raise *after* the row was durably
    # committed, which is the exact "successful create() looks failed" outcome this design avoids.
    try
      sequence_name = _get_owned_sequence_name(connection, model, col; ignore_tx=ignore_tx)

      if isnothing(sequence_name)
        # Fallback for a PK column with no OWNED sequence — a Django-managed table, or a natural
        # key. Matched on PostgreSQL's conventional `<table>_<column>_seq` and restricted to the
        # search path.
        #
        # NOT `LIKE '<table>%'`, which is what this used to be: that matches any sequence sharing
        # the prefix — `f1_driver` and `f1_driverstanding` both answer `LIKE 'f1_driver%'` — and the
        # result was unordered with row 1 taken blind, so a resync could `setval` a NEIGHBOURING
        # table's sequence to this table's MAX(pk). With `is_called=false` the victim table then
        # hands out a colliding id on its next insert. Removing the gate above made that path
        # reachable on every connection, so it is tightened here rather than left to widen.
        #
        # NOT lowercased (#59): PostgreSQL names the implicit sequence for a quoted `"Db_Table"` as
        # `Db_Table_id_seq`, and the comparison is case-sensitive — folding would match nothing.
        # Constrained to the TABLE'S OWN namespace, not merely to some schema on the search path.
        # A membership test (`schemaname = ANY(current_schemas(…))`) is not equivalent, and the gap
        # is the same corruption in schema form: with `search_path = tenant, public`, a
        # `tenant.drivers` whose own sequence is absent would match `public.drivers_id_seq` — which
        # belongs to `public.drivers` — and the `setval` below would set it from
        # `MAX(tenant.drivers.id)`, because the table in that statement is referenced unqualified.
        #
        # `to_regclass` resolves by exactly the same search_path rule as that unqualified reference,
        # so pinning the sequence to its `relnamespace` makes the two agree by construction — as
        # strict as the table, not stricter. It also yields at most one row (`relname` is unique per
        # namespace), so no ordering or tiebreak is needed. `to_regclass` returns NULL rather than
        # raising for a missing relation, so a vanished table degrades to zero rows and the
        # `continue` below.
        conventional = string(Models.model_table_name(model), "_", col, "_seq")
        seqs_df = fetch(
          connection,
          "SELECT n.nspname AS schemaname, c.relname AS sequencename " *
          "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " *
          "WHERE c.relkind = 'S' AND c.relname = '$(_sql_literal(conventional))' " *
          "AND c.relnamespace = (SELECT relnamespace FROM pg_class WHERE oid = to_regclass('$(_table_ident_literal(model))'))";
          ignore_tx=ignore_tx,
        ) |> DataFrames.DataFrame

        if size(seqs_df, 1) == 0
          # Not an error: a natural-key PK legitimately has no sequence, and `pk_exist` fires for
          # those too, so @debug rather than @warn keeps ordinary inserts quiet.
          #
          # `expected=` is what makes the other case diagnosable. PostgreSQL truncates a generated
          # object name at 63 bytes, so a table+column pair longer than that owns a sequence whose
          # real name is shorter than `conventional` and will not be found here. Logging the name we
          # searched for is the difference between a puzzling non-sync and an obvious one.
          @debug "No sequence to resync for this primary key" table=Models.model_table_name(model) column=col expected=conventional
          continue
        end
        # Quoted, not interpolated bare: `setval` takes regclass and case-folds unquoted parts, so
        # `public.Db_Table_id_seq` would be looked up as `public.db_table_id_seq` and fail.
        sequence_name = string(_quote_ident_raw(seqs_df[1, :schemaname]), ".",
                               _quote_ident_raw(seqs_df[1, :sequencename]))
      end

      safe_field_name = safe_column_identifier(col, connection)
      safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
      fetch(
        connection,
        "SELECT setval('$(_sql_literal(sequence_name))', COALESCE((SELECT MAX($safe_field_name) FROM $safe_table_name), 0) + 1, false)";
        ignore_tx=ignore_tx,
      )
    catch e
      # A cancellation is never ours to swallow. `e isa InterruptException` would NOT catch it:
      # every driver failure crosses `_as_database_error`, which wraps the interrupt in a
      # `StatementError`. `_await_abandoned` sees through that wrapper.
      #
      # This MUST stay ahead of the allowlist below, and the order is not stylistic: a cancellation
      # arrives as `StatementError(…, InterruptException())`, which IS a `DatabaseError`, so an
      # allowlist running first would swallow every Ctrl-C on this path.
      _await_abandoned(e) && rethrow()

      # Swallow ONLY what this block set out to tolerate: a failure of the database round-trip
      # itself. Widening the `try` to the whole loop body also brought `quote_identifier` and
      # `safe_table_identifier` inside it, and those are PormG's fail-closed identifier guards —
      # they raise `InvalidValueError`, which is a `PormGError` but NOT a `DatabaseError`. Reporting
      # a rejected `db_column` as "sequence resync failed, check your GRANTs" would bury the real
      # error and break the fail-closed contract.
      #
      # An allowlist, not "rethrow non-DatabaseError PormGErrors": `PoolTimeoutError <: PoolError`
      # is also outside the `DatabaseError` branch and IS one we mean to tolerate. `PoolError` is
      # the one family that reaches here un-wrapped, because `acquire_connection` runs outside
      # `fetch`'s own try and so never crosses `_as_database_error`.
      #
      # Anything raised on THIS task — a bug in this function, PormG's fail-closed identifier
      # guards — propagates. Note the limit of that claim: a failure raised inside the driver task
      # is wrapped into a `DatabaseError` before it arrives, so it is tolerated regardless of what
      # it originally was. That is the intended reading of "the round-trip failed".
      !(e isa DatabaseError || e isa PoolError) && rethrow()

      # Inside a transaction this failure is NOT recoverable and must propagate. PostgreSQL poisons
      # a transaction the moment any statement in it errors: every later statement returns "current
      # transaction is aborted, commands ignored until end of transaction block", and the COMMIT is
      # answered with ROLLBACK. Swallowing would hand the caller a PormGRow for a row that is
      # already doomed, which is strictly worse than raising.
      #
      # This is the common path for the bulk writers: `bulk_insert` and `bulk_copy` ALWAYS run
      # inside a transaction (`execution_bulk.jl:1004`, `:1176` — ambient, or their own
      # `run_in_transaction`). On PostgreSQL the row-level writers are the opposite: `insert`,
      # `_update_or_create` and `_get_or_create` deliberately run transaction-free (`ON CONFLICT` is
      # atomic on its own; their `run_in_transaction` wraps above are SQLite-only), so they take the
      # warn path unless the caller opened an `atomic` block.
      #
      # `!ignore_tx` is currently always true — no call site overrides the kwarg — but the condition
      # belongs with the check: `ignore_tx=true` makes `fetch` take a separate pooled connection,
      # which leaves the caller's transaction untouched and the failure genuinely recoverable.
      if !ignore_tx && transaction_connection_for(settings) !== nothing
        rethrow()
      end

      # Outside a transaction the INSERT was its own committed statement, so the row is durable and
      # only the NEXT auto-generated key is at risk. Report and carry on.
      #
      # The message names the LIKELY cause without asserting it: a role holding USAGE but not UPDATE
      # on the sequence hits this every time (PostgreSQL requires UPDATE for `setval` while
      # `nextval` accepts either, so such a role inserts rows fine and can never resync) — but a
      # pool timeout or a dropped connection lands here too, and sending that operator to GRANT
      # would be a wild goose chase. `exception=e` carries the truth.
      @warn "Sequence resync failed — the next auto-generated primary key may collide. If the cause is a permission error, the role needs UPDATE on the sequence." model=model.name table=Models.model_table_name(model) column=col sequence=something(sequence_name, "unresolved") exception=e
    end
  end
end

# SQLite creates `sqlite_sequence` lazily, the first time the database creates an AUTOINCREMENT
# table, so a database with none has no table to read or write (#674). PormG's own DDL always emits
# AUTOINCREMENT; a legacy or imported schema often does not. Without the table there is no counter to
# keep in step: SQLite assigns the next rowid as `MAX(rowid) + 1`. Asked on every call rather than
# cached, because an AUTOINCREMENT table created later in the session brings the table into being.
function _sqlite_has_sequence_table(settings::PormGSettings)::Bool
  df = fetch(settings, "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence';") |> DataFrames.DataFrame
  return DataFrames.nrow(df) > 0
end

# sqlite_sequence.name has no UNIQUE constraint, so `INSERT OR REPLACE` appends a duplicate row
# instead of overwriting. Upsert by hand: UPDATE the existing row (collapsing any duplicates a prior
# buggy run left, all to the same value), then INSERT only if no row exists yet. `table_literal` is
# the physical table name with single quotes already doubled.
function _sqlite_sequence_upsert!(settings::PormGSettings, table_literal::AbstractString, value::Int64)
  fetch(settings, "UPDATE sqlite_sequence SET seq = $(value) WHERE name = '$(table_literal)';")
  fetch(settings, "INSERT INTO sqlite_sequence (name, seq) SELECT '$(table_literal)', $(value) " *
                  "WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = '$(table_literal)');")
  return nothing
end

# MySQL has no sequence to fall behind: an explicit id moves AUTO_INCREMENT past it (measured on 8.4:
# 500 written, the next generated id is 501), so there is nothing to resync (#1266).
_update_sequence(model::PormGModel, connection::PormGMySQL, pk_field::Vector{String}, settings::PormGSettings;
                 ignore_tx::Bool = false) = nothing

function _update_sequence(model::PormGModel, connection::PormGSQLite, pk_field::Vector{String}, settings::PormGSettings)
  _sqlite_has_sequence_table(settings) || return nothing   # no AUTOINCREMENT table, nothing to resync (#674)
  for field in pk_field
    safe_field_name = safe_column_identifier(Models.model_column(model, field), connection)  # db_column (#50)
    safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
    # Matched against `sqlite_sequence.name`, which holds the table's ACTUAL name — so it must be
    # the resolved physical name (db_table when set, #59), not a fold of the logical one.
    safe_table_literal = replace(Models.model_table_name(model), "'" => "''")
    max_id_query = "SELECT MAX($(safe_field_name)) as m FROM $(safe_table_name);"
    # Execute query and convert to DataFrame to safely access the result
    df = fetch(connection, max_id_query) |> DataFrames.DataFrame
    
    if size(df, 1) > 0
      max_id = df[1, :m]
      if !ismissing(max_id) && !isnothing(max_id)
        # MAX(pk) is normally an Int64, but coerce defensively: a Float ("5.0") must still
        # resolve to its integer seq value instead of being silently skipped
        # (tryparse(Int64, "5.0") === nothing). A non-numeric value yields `nothing` → skipped.
        parsed_id = max_id isa Real ? floor(Int64, max_id) : tryparse(Int64, string(max_id))
        parsed_id !== nothing && _sqlite_sequence_upsert!(settings, safe_table_literal, parsed_id)
      end
    end
  end
end

function _build_from_tables(row_join::Vector{JoinRow}, connection::_SQLEngine)
  tables = String[]
  for row in row_join
    # #394: no try/catch. This used to `@error` and CONTINUE, which dropped a table from a correlated
    # FROM list and left the surviving aliases unconstrained — a wrong query emitted as a warning.
    # Everything that can raise here is a defect, not a tolerable condition: an `InvalidValueError`
    # means an INTERNALLY generated alias is not an identifier, and it has to surface. (A row with a
    # missing slot used to be the other case; since #487 a `JoinRow` cannot be constructed without
    # its relation and alias, so that one is unrepresentable rather than caught.)
    b = safe_table_identifier(row.b, connection)
    alias_b = quote_identifier(row.alias_b, connection)
    push!(tables, "$b AS $alias_b")
  end
  return join(unique(tables), ", ")
end

# The WHERE half of a correlated UPDATE … FROM: one equi-anchor per path join, and each `cjoin_on`
# alias's ON conditions as `build()` already rendered them (`rendered_on`, keyed by alias). Emitted in
# `row_join` order, so the `cjoin_on` markers sit in the order their values were bound into `:join`,
# and the caller prints all of it before `_where` — SET, ON, WHERE: `_BUCKET_ORDER`'s order (#174).
function _get_join_condition_list(row_join::Vector{JoinRow}, connection;
                                  rendered_on::Dict{String,Vector{String}} = Dict{String,Vector{String}}())
  has_cjoin_on = any(r -> r isa AnchorlessJoin, row_join)
  for row in row_join
    # #174: a LEFT path join turns inner here too — its anchor lands in WHERE — and a `cjoin_on` ON
    # clause may lean on its NULL row (`Qor(…, "fk__col__@isnull" => true)`), which then matches
    # nothing: fewer rows updated, silently. With a `cjoin_on` in the statement, refused. (The same
    # flattening without one predates #174 and stays as it was.)
    if has_cjoin_on && row isa ModelJoin && row.how != "INNER"
      throw(QueryBuildError(
        "The $(row.how) join to \"$(row.b)\" (alias \"$(row.alias_b)\") cannot be carried into a correlated " *
        "UPDATE ... FROM beside a cjoin_on: that statement joins in its WHERE clause, so it would act as an " *
        "INNER join and drop the rows it was declared to keep, which a cjoin_on ON clause may match on. " *
        "Scope the mutation with a filter instead (#174)."))
    end
    # #1002: the same rule for a path join. A reverse, ManyToMany or non-unique-link join in the FROM
    # list matches several rows per updated row, so SET reads an arbitrary one — `build()` lets it
    # through because `update()` builds as a semi-join, which holds only for the `pk IN (…)` form.
    if row isa ModelJoin && row.to_many
      throw(QueryBuildError(
        "The join to \"$(row.b)\" (alias \"$(row.alias_b)\") may match more than one row per updated row " *
        "(a reverse or ManyToMany relation, or a link to a column that is not unique), so a correlated " *
        "UPDATE ... FROM setting a column from a joined table would SET from an arbitrary match. Scope the " *
        "rows with a correlated Exists(...) filter instead, or set from a to-one path (#1002)."))
    end
    # #174: a `cjoin_on` join's ON clause moves into this statement's WHERE, which is an INNER join by
    # construction, and SET reads one joined row per updated row. Both hold only for an INNER alias
    # proven to-one; anything else is refused rather than rendered differently from what it says.
    # The rule covers EVERY alias in the FROM list, not just the ones SET reads: deliberately
    # conservative, and no wider than the blanket refusal it replaced.
    if row isa AnchorlessJoin
      row.how == "INNER" || throw(QueryBuildError(
        "cjoin_on alias \"$(row.alias_b)\" is a $(row.how) join, which a correlated UPDATE ... FROM cannot " *
        "carry: that statement joins in its WHERE clause, so it would act as an INNER join and skip the rows " *
        "with no match instead of keeping them. Declare it with join_type = \"INNER\", or scope the mutation " *
        "with a filter instead (#174)."))
      row.to_many && throw(QueryBuildError(
        "cjoin_on alias \"$(row.alias_b)\" may match more than one row per updated row, so a correlated " *
        "UPDATE ... FROM would SET from an arbitrary match. Its ON clause must equate, at the top level " *
        "(not inside Qor) and with one value per base row, the target's primary key, a unique = true " *
        "column, or every column of a plain UniqueConstraint, e.g. " *
        "Joined(\"$(row.alias_b)\", \"<key>\") == F(\"<column>\") (#174)."))
      haskey(rendered_on, row.alias_b) || error(_emsg(
        "PormG internal error: cjoin_on alias \"$(row.alias_b)\" reached a correlated UPDATE ... FROM with no " *
        "rendered ON clause; refusing to emit the join unconstrained."))
    end
    # #394: the same rule, for a CTE. `update()` emits no `WITH` prefix — `build_cte_clause` is
    # reached only from the three READ paths — so a row_join entry naming a CTE renders
    # `FROM "<cte>" AS "Tb_N"` against a relation this statement never declares. That is as true of a
    # KEYED CTE as of a CROSS-joined one, which is why the check is on the entry being a CTE rather
    # than on the shape of its keys — `_joins_cte` is true for both kinds. The cross-joined case has
    # no key columns at all (its dict row carried SENTINEL empty strings, which used to raise inside
    # the loop below and be swallowed by a `catch` that dropped the ON condition entirely). Both fail
    # here now, before any SQL is built.
    if _joins_cte(row)
      throw(QueryBuildError("A CTE cannot be joined in a correlated UPDATE ... FROM: the statement emits " *
                    "no WITH clause, so the CTE it references is never declared. Scope the mutation with " *
                    "a filter or a subquery instead."))
    end
    # #977: the same rule, for an `on(...)` / `cjoin(filters = ...)` condition on a path join. The
    # loop below renders equi-anchors only, so the condition was dropped from the statement — while
    # its values were still bound by the join render, so since `on()` builds its own join the
    # statement carried more values than markers and the driver refused it. Before that the
    # predicate was simply ignored: an UPDATE wider than the query that described it.
    if row isa ModelJoin && !isempty(row.on_conditions)
      throw(QueryBuildError("An on(...) / cjoin(filters = ...) condition cannot be carried into a correlated " *
                    "UPDATE ... FROM (setting a column from a joined table): that statement joins in its WHERE " *
                    "clause on the key columns only, so the condition would be dropped. Scope the mutation " *
                    "with a filter instead (#977)."))
    end
  end
  conditions = String[]
  for row in row_join
    # #394: no try/catch either — the guards above refuse to drop an ON clause, and until now the
    # loop below dropped one anyway on any failure, with nothing but an `@error`. An UPDATE ... FROM
    # missing its ON condition matches every row of the joined table, so this is the one place a
    # swallowed identifier error corrupts data rather than returning wrong rows.
    # Both CTE shapes are refused above, so a row is a `ModelJoin` (an equi-anchor) or an INNER,
    # to-one `AnchorlessJoin` with its ON already rendered (#174).
    if row isa AnchorlessJoin
      append!(conditions, rendered_on[row.alias_b])
      continue
    end
    row = row::ModelJoin
    alias_a = quote_identifier(row.alias_a, connection)
    key_a = safe_column_identifier(row.key_a, connection)
    alias_b = quote_identifier(row.alias_b, connection)
    key_b = safe_column_identifier(row.key_b, connection)
    push!(conditions, "$alias_a.$key_a = $alias_b.$key_b")
  end
  return conditions
end

function _build_join_conditions(row_join::Vector{JoinRow}, connection::_SQLEngine;
                                rendered_on::Dict{String,Vector{String}} = Dict{String,Vector{String}}())
  return _get_join_condition_list(row_join, connection; rendered_on = rendered_on)
end

function _set_clause_uses_join_aliases(set_clause::String,
  row_join::Vector{JoinRow},
  connection::_SQLEngine)::Bool
  for row in row_join
    alias_b = quote_identifier(row.alias_b, connection)
    occursin("$alias_b.", set_clause) && return true
  end
  return false
end

# ─────────────────────────────────────────────────────────────────────────────
# The mutation fence (#765)
#
# Every UPDATE/DELETE that scopes rows through a query renders that query's predicates HERE, against
# the statement's own target alias — `UPDATE "t" AS "Tb" … WHERE <this>`, `DELETE FROM "t" AS "Tb"
# WHERE <this>` — never ONLY as `"pk" IN (SELECT "Tb"."pk" FROM "t" AS "Tb" WHERE …)`. (A joined
# statement keeps that IN as its index-driven selection, ANDed with this — `_target_pk_selection`.)
#
# The distinction is invisible in a quiet database and decisive in a busy one. Under PostgreSQL READ
# COMMITTED a statement that waits on a row lock re-checks the row's NEW version against its quals
# (EvalPlanQual) — but a self-subquery over the target is an independent scan of that table, read on
# the statement's snapshot, so its predicates are never re-evaluated. A filter written as a fence
# (`.filter("id" => k, "status__@in" => terminal).delete()`, a compare-and-delete) was therefore
# ignored whenever a concurrent UPDATE committed while the DELETE waited: the row went even though
# its new version matched nothing. Reproduced through Nitro.jl#379, on PostgreSQL 16.
#
# Two shapes, one rule — every predicate reaches the target through the OUTER alias:
#
#   - no joins → the WHERE conjuncts, verbatim. They are already written against "Tb".
#   - joins    → `EXISTS (SELECT 1 FROM (SELECT 1) AS "__pormg_anchor" <joins> WHERE <conjuncts>)`.
#     The joins' ON clauses reference the outer "Tb", which makes the subplan CORRELATED — PostgreSQL
#     re-evaluates it against the new row version, where it never re-runs an uncorrelated one.
#
# Why the one-row anchor rather than `FROM <first joined table>` with its ON moved into WHERE (the
# flattening `UPDATE … FROM` does): the joins are LEFT JOINs, and flattening turns them inner. A row
# with no parent must still produce its null-extended row, or `"parent__col__@isnull" => true` stops
# matching exactly the rows it exists for. With the anchor the join tree is the text the read builder
# rendered, so the row set is the one `pk IN (…)` selected, and both engines run it as is.
#
# One rewrite keeps that equivalence exact: RIGHT → INNER and FULL → LEFT. The chain is left-deep and
# rooted at the target, so a RIGHT/FULL hop null-extends the TARGET side — rows `pk IN (SELECT
# "Tb"."pk" …)` always dropped (a NULL pk is in no set), which is precisely INNER/LEFT. Verbatim, the
# anchor stands where the target stood and a RIGHT JOIN keeps every right-side row, so the EXISTS is
# true for every target row once one match exists anywhere — a silent widening of the write; and a
# FULL JOIN whose ON names only the outer row is not hash/merge-joinable, which PostgreSQL refuses.
#
# A joined fence is NOT used alone where it can be avoided — see `_target_pk_selection`.
#
# SQLite is not exposed to the race (writers are serialized), but runs the identical text: the fix is
# a shape, not a PostgreSQL branch, so there is no divergence to document.
#
# Parameters: the text order is JOIN-ON then WHERE, which is `_BUCKET_ORDER`'s order, so a statement
# built by `build()` flattens in text order with no extra step. A caller splicing several of these
# into one statement (the deletion collector) wraps each in the #432 nested-run mark/detach.
#
# GROUP BY / HAVING have no place in a row predicate. Both terminals refuse the shapes that produce
# them before building (`_reject_unsafe_mutation_shape`, `delete()`'s guards), so reaching one here is
# an internal error — raised rather than dropped, because dropping HAVING widens the statement.
#
# An empty result means "no predicate": the caller must omit the WHERE, not print `WHERE ` or
# `WHERE ()`.
# ─────────────────────────────────────────────────────────────────────────────
const _TARGET_ANCHOR_ALIAS = "__pormg_anchor"

function _target_predicate(instruction::SQLInstruction)::String
  # `group` alone is not the signal: every projection is pushed into it, and it only PRINTS under
  # `aggregate` (the read renderer's own condition).
  (isempty(instruction.having) && !(instruction.aggregate && !isempty(instruction.group))) || error(_emsg(
    "PormG internal error: a mutation's row predicate carries GROUP BY / HAVING, which the " *
    "UPDATE/DELETE guards should have refused — this should not happen; please report it."))

  conjuncts = join(instruction._where, " AND ")
  isempty(instruction.row_join) && return conjuncts

  io = IOBuffer()
  print(io, "EXISTS (SELECT 1 FROM (SELECT 1) AS ", quote_identifier(_TARGET_ANCHOR_ALIAS, instruction.connection))
  for j in instruction.join
    # Every rendered join opens with ` <how> JOIN ` (build_row_join_sql_text); see the header.
    print(io, "\n  ", replace(j, r"^ RIGHT JOIN " => " INNER JOIN ", r"^ FULL JOIN " => " LEFT JOIN "))
  end
  isempty(conjuncts) || print(io, "\n  WHERE ", conjuncts)
  print(io, ")")
  return String(take!(io))
end

# ─────────────────────────────────────────────────────────────────────────────
# The selection half of a JOINED mutation (#765)
#
# A joined fence alone costs a full scan. PostgreSQL cannot flatten an EXISTS whose correlation sits
# in a JOIN's ON (only a top-level-WHERE correlation is pulled up into a semi-join), so it stays a
# per-row SubPlan — and with every conjunct inside it, the outer statement has nothing indexable:
# `M.Result.objects.filter("resultid" => 1, "driverid__nationality" => "British").update(…)` scanned
# the whole table where the pre-#765 `pk IN (SELECT …)` semi-joined through the primary-key index.
#
# So a joined statement carries BOTH: `"Tb"."pk" IN (<this>) AND EXISTS (<the fence>)`. The IN is the
# pre-#765 selection, planned exactly as before; the EXISTS is what PostgreSQL re-checks on the new
# row version, and it only runs for rows the IN let through. On the snapshot the two agree, so the
# conjunction selects what either did; after a concurrent change, the EXISTS decides.
#
# The two halves come from TWO builds of the same query into one parameter collector — each value is
# bound twice, once per half, in text order — never from one build printed twice: a second print of
# one build's text would reuse its markers, and on SQLite a positional marker is consumed once.
#
# `nothing` for a keyless model: there is no pk to select through, so it takes the fence alone.
# ─────────────────────────────────────────────────────────────────────────────
function _target_pk_selection(instruction::SQLInstruction)::Union{Nothing,String}
  model = instruction.object.model
  pk_field_sym = get_model_pk_field(model)
  pk_field_sym === nothing && return nothing

  connection = instruction.connection
  safe_alias = quote_identifier(instruction.alias, connection)
  quoted_pk = safe_column_identifier(Models.model_column(model, String(pk_field_sym)), connection)  # db_column (#50)
  return _key_selection(instruction, safe_alias, safe_alias, quoted_pk;
                        materialize = _materializes_target_key_set(connection))
end

# `<outer_alias>.<column> IN (SELECT DISTINCT <source_alias>.<column> FROM <target> as <alias> <joins>
# WHERE <conjuncts>)`: the query's row set, projected onto one column of one of its aliases. Every
# argument arrives quoted. The joins print verbatim, so the row set is exactly the one the read builder
# rendered, LEFT JOINs included.
#
# `materialize` wraps the subquery in a derived table, `IN (SELECT * FROM (SELECT DISTINCT …) AS
# `__pormg_keys`)`, for an engine that refuses a statement reading the table it writes
# (`_materializes_target_key_set`). Same row set, same markers in the same order.
function _key_selection(instruction::SQLInstruction, outer_alias::String, source_alias::String, column::String;
                        materialize::Bool = false)::String
  connection = instruction.connection
  io = IOBuffer()
  print(io, outer_alias, ".", column, " IN (")
  materialize && print(io, "SELECT * FROM (")
  print(io, "SELECT DISTINCT ", source_alias, ".", column)
  print(io, "\n  FROM ", safe_table_identifier(Models.model_table_name(instruction.object.model), connection),
    " as ", quote_identifier(instruction.alias, connection))
  for j in instruction.join
    print(io, "\n  ", j)
  end
  isempty(instruction._where) || print(io, "\n  WHERE ", join(instruction._where, " AND "))
  materialize && print(io, ") AS ", quote_identifier("__pormg_keys", connection))
  print(io, ")")
  return String(take!(io))
end

# The row predicate of one arm the deletion collector splices into a shared statement: the fence
# alone when the query has no joins (or no primary key), `<pk selection> AND <fence>` otherwise.
# `build_one()` builds a FRESH copy of the query into `parameters`; it is called once, or twice for a
# joined arm. Each build is wrapped in the #432 mark/detach and re-emitted under `:where` in text
# order, so several arms can share one collector.
#
# `update()` does not come through here: its statement is built once at top level before the guards
# run, so it reuses THAT build as the selection half and builds only the fence a second time —
# the top-level buckets (`:join`, `:where`) already flatten in the IN's text order.
function _mutation_predicate(build_one::Function, parameters)::String
  mark = nested_parameter_mark(parameters)
  first_build = build_one()
  first_run = detach_nested_run!(parameters, mark)
  selection = isempty(first_build.row_join) ? nothing : _target_pk_selection(first_build)

  if selection === nothing
    set_context!(parameters, :where)
    reattach_parameters!(parameters, first_run)
    return _target_predicate(first_build)
  end

  mark = nested_parameter_mark(parameters)
  fence_build = build_one()
  fence_run = detach_nested_run!(parameters, mark)
  set_context!(parameters, :where)
  reattach_parameters!(parameters, first_run)   # the IN, first in the text
  reattach_parameters!(parameters, fence_run)   # then the EXISTS
  return selection * "\n  AND " * _target_predicate(fence_build)
end

# Shape guards shared by `update()` and `bulk_update()` (#665): the query state an `UPDATE`
# statement cannot express. Each one is refused rather than dropped, because dropping it widens
# the statement past what the caller built — `query.limit(5).update(...)` would mutate every
# matching row, not five. `op` names the terminal in the message; `update()`'s wording is pinned.
function _reject_unsafe_mutation_shape(q::SQLObject, op::String)
  # limit(), offset(), and order_by(): standard SQL UPDATE does not support these clauses. To
  # update a bounded set of rows, filter by primary key explicitly or compose a subquery.
  if q.limit !== nothing || q.offset > 0 || !isempty(q.order)
    throw(UnsafeMutationError(
      "Cannot call $op on a query that has limit(), offset(), or order_by() set. " *
      "Standard SQL UPDATE does not support these clauses, and silently dropping them " *
      "risks updating more rows than intended. " *
      "Filter by primary key explicitly or compose a subquery to update a bounded set."
    ))
  end

  if q.distinct
    throw(UnsafeMutationError(
      "Cannot call $op on a query with distinct(). " *
      "DISTINCT collapses the result set, which would cause UPDATE to target " *
      "different rows than intended. Remove distinct() or filter by primary key."
    ))
  end

  if any(v -> isa(v, SQLTypeField) && isa(v.field, Union{SQLTypeFunction, SQLTypeF}) && v.field.aggregate, q.values)
    throw(UnsafeMutationError(
      "Cannot call $op on a query with group_by() / annotate aggregations. " *
      "GROUP BY collapses rows, making the UPDATE target ambiguous. " *
      "Remove the aggregation or filter by primary key."
    ))
  end

  # #668: a filter that resolves through a `values()` projection. The terminals build without the
  # projection (an UPDATE has none), so such a filter cannot mean what it meant on a read: a plain
  # alias key routed to HAVING was dropped (the #74 shape), and a key that also names a model field
  # (`values("points" => F("points") - 100)`) silently filtered the raw column instead.
  alias = _first_projection_alias_filter(q)
  alias === nothing || throw(UnsafeMutationError(
    "Cannot call $op with a filter on the values() alias \"$(alias)\". An UPDATE has no " *
    "projection, so the filter cannot resolve through it — PormG would have to drop it or apply it " *
    "to a different expression. Filter on the underlying field, or resolve the rows first and " *
    "pass .filter(\"pk__@in\" => ids)."
  ))
  return nothing
end

# The names a filter key resolves through the projection memo instead of the model (#668). A read
# looks a filter column up by `memo_key` — as the HAVING alias in `get_filter_query`, and as the
# memoized left-hand side in `_get_filter_query(::SQLTypeField)`, nested in `Q`/`Qor` or not. Only
# base-rooted names are reachable from a filter key, and a plain path projected under its own name
# (`values("points")`) renders the column itself, so dropping it changes nothing.
function _projection_filter_names(q::SQLObject)::Set{String}
  names = Set{String}()
  for v in q.values
    if v isa SQLTypeText   # `Value(x)`: memoized under its output name (`get_select_query`)
      name = _projection_output_name(v)
      name === nothing || push!(names, name)
    elseif v isa SQLField
      key = memo_key(v)
      (key === nothing || key[1] !== :base) && continue
      (v.field isa String && v.field == key[2]) && continue
      push!(names, key[2])
    end
  end
  return names
end

function _first_projection_alias_filter(q::SQLObject)::Union{Nothing,String}
  names = _projection_filter_names(q)
  isempty(names) && return nothing
  for f in q.filter
    hit = _projection_alias_in_filter(f, names)
    hit === nothing || return hit
  end
  return nothing
end

# Recursive in the shape of `_guard_no_aggregate_predicate` (build_filter.jl), with its depth cap.
function _projection_alias_in_filter(f, names::Set{String}, depth::Int = 0)::Union{Nothing,String}
  depth > 32 && return nothing
  if f isa SQLTypeOper
    col = f.column
    (col isa SQLTypeField && col.field isa String && col.field in names) && return col.field
  elseif f isa Union{SQLTypeQ,SQLTypeQor}
    for g in (f isa SQLTypeQ ? f.filters : f.or)
      hit = _projection_alias_in_filter(g, names, depth + 1)
      hit === nothing || return hit
    end
  end
  return nothing
end

# #1279 — an expression written into a `DecimalField(p, s)` is assigned to a `numeric(p, s)` column,
# which means the value rounded to `s` places: PostgreSQL's assignment cast rounds it, and SQLite's
# NUMERIC affinity keeps every digit its double arithmetic produced (`1.10 - 1` is stored as
# `0.10000000000000009` and read back as a `Float64`). That is the #1040 cast's meaning exactly, so
# the operand is classified by the cast's own `_scale_divergent_operand` and the engine is decided by
# its `:scale` row; only the message is the write's, naming the `Round` that gives the same value on
# every engine. A literal never reaches here: `DecimalValidator`'s width check refuses it everywhere
# (#761). Called after the SET value renders, so a joined path's column is resolved.
function _refuse_update_scale_departure(f_meta, field::AbstractString, value, instruction::SQLInstruction)
  f_meta isa Models.sDecimalField || return nothing
  side = _scale_divergent_operand(value, f_meta.decimal_places, instruction)
  side === nothing && return nothing
  row = _departure(instruction.connection, :scale, side[1])
  row === nothing && return nothing
  places = f_meta.decimal_places
  # `Round(x)` for a scale of 0, the whole-number spelling #1061 documents. Text (a text or JSON
  # column, a text function) is no number to round: #1061 refuses `Round` over it, so the spelling
  # names the cast to a number that its own refusal names.
  x = side[1] === :text ? "Cast(x, FloatField())" : "x"
  spelling = places == 0 ? "Round($(x))" : "Round($(x), $(places))"
  # The #1111 integer-quotient row keeps its own fix, which names the division to write.
  row.issue == "#1040" && (row = merge(row, (issue = "#1279", fix = (_, _) ->
    "Round it to the field's $(places == 1 ? "1 decimal place" : "$(places) decimal places") first: " *
    "\e[32mupdate(\"$(field)\" => $(spelling))\e[0m, which stores the same value on every engine.")))
  throw(_meaning_refusal("update(\"$(field)\" => …)", side[2], row, instruction.connection;
    declared = "DecimalField(max_digits = $(f_meta.max_digits), decimal_places = $(places))"))
end

# #1297 — an expression of a type that is no number, written into a numeric field. SQLite stores the
# value's text (or a blob's bytes) in the INTEGER, REAL or NUMERIC column, and PostgreSQL has no
# assignment cast from one to a number, so it fails only when the statement runs. No engine gives the
# call a meaning, so this is explicit intent, refused on every engine before any SQL rather than a
# departure row. Nor is there a `Cast` to name: PostgreSQL has none from these types to a number.
# Left out on purpose: a boolean (`true` against `1` is a #1147 meaning question), and text and JSON,
# which #1279 reads as numbers to round. Typed by the walk (`_AllKinds`), after the SET value renders,
# so a joined path's column is resolved.
const _NON_NUMBER_KINDS = (
  (CUUID, "a UUID"), (CDate, "a date"), (CDateTime, "a timestamp"), (CTime, "a time of day"),
  (CInterval, "an interval"), (CBytes, "binary data"), (CInet, "a network address"),
  (CCidr, "a network address"), (CTsVector, "a full-text document"))
const _NUMBER_FIELD_KINDS = Union{CInt16,CInt32,CInt64,CFloat64,CDecimal}
function _refuse_update_non_number(f_meta, field::AbstractString, value, instruction::SQLInstruction)
  _field_kind(f_meta) isa _NUMBER_FIELD_KINDS || return nothing
  kind = _expression_kind(value, instruction)
  # A declared type is read by its name, the same on every engine: the walk types a uuid or network
  # cast on SQLite as the text it renders (`_declared_kind`), and it still means a UUID there.
  declared_type = value isa FObject ? _declared_cast(value) : nothing
  if declared_type isa AbstractString && !isempty(declared_type)
    declared_field = _sql_type_field(declared_type)
    declared_field === nothing || (kind = _field_kind(declared_field))
  end
  i = findfirst(((K, _),) -> kind isa K, _NON_NUMBER_KINDS)
  i === nothing && return nothing
  what = last(_NON_NUMBER_KINDS[i])
  label = _concat_operand_label(value)
  named = label === nothing ? "the expression" : "`$(label)`"
  declared = replace(String(nameof(typeof(f_meta))), r"^s" => "")
  throw(QueryBuildError(
    "\e[4m\e[31mupdate(\"$(field)\" => …)\e[0m writes $(named), which is $(what), into the " *
    "$(declared) `$(field)`. That is no number on any engine, so PormG refuses it (#1297). " *
    "Write a numeric expression into `$(field)`, or write the value into a field of its own type."))
end

# #1130: an UPDATE whose SET reads a column another item of the same SET writes, on an engine that
# assigns SET items in order (`_assigns_set_in_order`, MySQL). Every item means the row as it was: a
# swap `update("laps" => F("grid"), "grid" => F("laps"))` exchanges the two on PostgreSQL and SQLite.
# MySQL's single-table UPDATE reads an item already assigned at its new value (measured on 8.4: the
# swap writes `grid` into both), and leaves the order of a multi-table one unspecified. So an item that
# reads a column written EARLIER in the SET is refused, or, in the multi-table form, written anywhere
# else in it. An item that reads its own column (`"laps" => F("laps") + 1`), or one written later in a
# single-table SET, reads the old value and builds. A column is read when its alias-qualified name is
# in the item's SQL, the only spelling PormG renders a target column in.
function _refuse_set_reading_assigned(fields::Vector{String}, parts::Vector{String}, alias::String,
                                      multi_table::Bool, connection)
  columns = [first(split(p, " = "; limit = 2)) for p in parts]
  for (i, part) in enumerate(parts)
    rhs = last(split(part, " = "; limit = 2))
    for (j, column) in enumerate(columns)
      (j == i || (!multi_table && j > i)) && continue
      occursin(string(alias, ".", column), rhs) || continue
      throw(QueryBuildError("update(\"$(fields[i])\" => …) reads `$(fields[j])`, which the same update() also " *
        "writes. $(_backend_name(connection)) assigns an UPDATE's SET items in order, so it may read the new " *
        "value of `$(fields[j])`, where the update means the row as it was. Split it into two update() calls, " *
        "or write the value both items mean."))
    end
  end
  return nothing
end

# The `UPDATE … FROM` text PostgreSQL and SQLite share (`_update_from_sql`).
_update_from_clause_sql(table, alias, set_parts, from_clause, where_sql) = """
  UPDATE $(table) AS $(alias)
  SET $(join(set_parts, ", "))
  FROM $(from_clause)
  WHERE $(where_sql)
  """

function update(objct::SQLObject; table_alias::Union{Nothing, SQLTableAlias} = nothing, connection::Union{Nothing, _SQLEngine} = nothing, show_query::Symbol = :execute)
  real_obj = objct isa SQLObjectHandler ? objct.object : objct
  model = real_obj.model

  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
  ensure_transaction_scope(model, connection)

  # Check if is allowed to update
  !settings.change_data && throw(_write_not_allowed("update", conn_key))

  _reject_unsafe_mutation_shape(real_obj, "update()")

  # #668: an UPDATE has no projection, so the statement is built from a private copy with `values()`
  # emptied — the #665 shape `bulk_update` uses. Built as-is, a binding projection (`Value(5)`,
  # `F("points") * 2`) filed its operands into the `:select` bucket, which flattens ahead of SET and
  # WHERE: a positional misbind on SQLite (wrong value, wrong rows, no error), and bound-but-unused
  # `$N` on PostgreSQL. Aggregates and alias filters were refused above, so emptying drops nothing.
  work = deepcopy(real_obj)
  empty!(work.values)
  # `get_alias` is a counter: a second build on the SAME alias object would name its target "R1",
  # not "Tb". A joined update builds twice (#765 — selection, then fence), so the fence gets an
  # untouched copy of whatever the caller passed; `nothing` makes a fresh one either way.
  fence_alias = deepcopy(table_alias)
  # #1002: the rows are scoped by `pk IN (SELECT DISTINCT …) AND EXISTS (…)`, where a repeated row is
  # invisible. A SET reading a joined column takes UPDATE … FROM instead, which refuses a to-many join
  # itself (`_get_join_condition_list`).
  instruction = build(work, table_alias=table_alias, connection=connection, semi_join=true, mutation=true)

  # Don't allow to update a field without filter
  instruction._where |> isempty && throw(UnsafeMutationError("update() requires a filter — refusing to update every row. Add .filter(...) before .update(...)."))
  
  parameters = instruction.parameters
  fields = model.field_names

  # Check if the fields need to be updated automatically
  for field in fields
    if !haskey(objct.insert, field)
      if model.fields[field].type == "TIMESTAMPTZ" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formatter(now(TimeZone(settings.time_zone)))
      elseif model.fields[field].type == "DATE" && (model.fields[field].auto_now)
        objct.insert[field] = model.fields[field].formatter(today())
      end
    end
  end

  # Handle F expressions in SET clause
  # Switch context to :update for SET clause params (SET appears before WHERE/JOIN in SQL)
  set_context!(parameters, :update)
  set_clause_parts = String[]
  set_fields = String[]   # #1130: the field each SET item writes, item for item
  for field in keys(objct.insert)    
    # Validation checks
    validate_field_data(model, field, objct.insert[field], "update"; allow_primary_key = false)
    Models.is_many_to_many_field(model.fields[field]) && throw(QueryBuildError("ManyToManyField $(model.name).$(field) cannot be written in update(); use the many-to-many manager add, remove, clear, or set methods"))
    
    quoted_field = safe_column_identifier(Models.field_db_column(model.fields[field], field), connection)  # db_column (#50)

    # #444: a `CTE(...)` handle joins this branch rather than the value branch below. It is
    # unambiguously a COLUMN reference — never a literal — so binding it as a value was never right;
    # it reached `field.formatter` and died with a bare `MethodError` (outside the #231 taxonomy).
    # Routed here, it resolves as a column and `update()`'s own "this statement emits no WITH
    # clause" refusal (#433) fires with the accurate message, which is exactly what the pre-#444
    # `F("<cte>__col")` spelling produced.
    # #1021: a `SearchVector` fills a `SearchVectorField` — Django's
    # `update(search=SearchVector(…))` — and is rendered as the document it is, past the "operand,
    # not a value" refusal every other value position keeps. Into any other column it is refused, as
    # is a `SearchQuery` anywhere: neither is a value a column of another type could hold.
    if _is_fts_operand(objct.insert[field])
      value = objct.insert[field]
      (_is_fts_node(value, "SEARCH_VECTOR") && model.fields[field] isa Models.sSearchVectorField) ||
        throw(QueryBuildError(
          "update(\"$(field)\" => $(_is_fts_node(value, "SEARCH_VECTOR") ? "SearchVector" : "SearchQuery")(…)): " *
          "a SearchVector fills a SearchVectorField column, and nothing else is written from a full-text " *
          "operand (#1021)."))
      _supports(connection, :full_text_search) || throw(Dialect.fts_capability_error(connection, "SearchVector"))
      push!(set_fields, field); push!(set_clause_parts, "$(quoted_field) = $(_render_fts_operand(value, instruction))")
    # #174: a `Joined(...)` handle is a column of a `cjoin_on` copy — never a literal, so it must not
    # reach the field formatter (#481). It renders `"<alias>"."<col>"`, which sends the statement down
    # the correlated UPDATE … FROM branch below, where the alias's rendered ON clause joins it.
    elseif isa(objct.insert[field], SQLTypeF) || isa(objct.insert[field], SQLTypeFunction) ||
       isa(objct.insert[field], SQLTypeCTE) || isa(objct.insert[field], SQLTypeJoined)
      f_value = _set_update_query(objct.insert[field], instruction)
      _refuse_update_non_number(model.fields[field], field, objct.insert[field], instruction)
      _refuse_update_scale_departure(model.fields[field], field, objct.insert[field], instruction)
      push!(set_fields, field); push!(set_clause_parts, "$(quoted_field) = $(f_value)")
    else
      formatted_value = _format_single(model.fields[field], field, objct.insert[field], "update"; conn = connection)
      placeholder = add_parameter!(parameters, formatted_value)
      push!(set_fields, field); push!(set_clause_parts, "$(quoted_field) = $(placeholder)")
    end
  end
   
  set_clause = join(set_clause_parts, ", ")   

  # Build secure UPDATE SQL with JOIN support
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  safe_alias = quote_identifier(instruction.alias, connection)

  has_joins = !isempty(instruction.row_join)
  multi_table = false   # #1130: MySQL's multi-table UPDATE, whose SET order is unspecified
  sql = ""
  
  if has_joins
    begin
      # The SET-clause loop above can reach _build_row_join (e.g. update("x" => F("fk__col"))), so
      # row_join may have grown AFTER build() rendered instruction.join — the same late-discovery
      # hazard #404 fixed in build(). Exactly one UPDATE branch reads the stale instruction.join:
      # `_target_predicate`, which prints it into the EXISTS. This check is what excludes it — a
      # SET-discovered join necessarily puts its alias in set_clause, so the check returns true and
      # the UPDATE … FROM branch below rebuilds FROM/ON from instruction.row_join instead. Do NOT
      # drop this guard on the theory that the UPDATE path ignores instruction.join — it does not.
      # (#404's own trigger cannot reach here regardless: update() refuses a query carrying
      # order_by() in `_reject_unsafe_mutation_shape`.)
      set_uses_join_aliases = _set_clause_uses_join_aliases(set_clause, instruction.row_join, connection)

      if !set_uses_join_aliases && isempty(real_obj.ctes)
        # #765: `"Tb"."pk" IN (SELECT DISTINCT …) AND EXISTS (<fence>)`. The IN alone was the
        # pre-#765 shape, and PostgreSQL never re-checks it when the UPDATE waits on a row lock, so a
        # filter used as a fence was ignored; the correlated EXISTS is what it re-checks. The IN stays
        # as the index-driven selection (`_target_pk_selection`). The top-level build above is its
        # half — its `:join`/`:where` values flatten in the IN's text order — and the fence is a SECOND
        # build, lifted as one run behind them. A keyless model has no pk to select through and takes
        # the fence alone, bound through the top-level buckets directly (it used to take UPDATE …
        # FROM, which flattened its LEFT JOINs to inner and dropped `.on()` conditions).
        selection = _target_pk_selection(instruction)
        predicate = if selection === nothing
          _target_predicate(instruction)
        else
          fence_work = deepcopy(real_obj)
          empty!(fence_work.values)
          mark = nested_parameter_mark(parameters)
          fence = build(fence_work, table_alias=fence_alias, connection=connection, parameters=parameters, semi_join=true,
                        mutation=true)
          fence_run = detach_nested_run!(parameters, mark)
          set_context!(parameters, :where)
          reattach_parameters!(parameters, fence_run)
          selection * "\n  AND " * _target_predicate(fence)
        end
        sql = """
        UPDATE $(safe_table_name) AS $(safe_alias)
        SET $(set_clause)
        WHERE $(predicate)
        """
      else
        # PostgreSQL & SQLite 3.33+ support UPDATE FROM syntax; MySQL lists the tables after UPDATE
        # (`_update_from_sql`).
        from_clause = _build_from_tables(instruction.row_join, connection)
        join_conditions = _build_join_conditions(instruction.row_join, connection;
                                                 rendered_on = instruction.cjoin_on_rendered)

        # Structural joins, then the filters: SET → ON → WHERE is the bucket order (#174). Not
        # deduplicated: two anchors can never coincide (`_insert_join` dedups the rows, each with its
        # own alias), and a fragment that carries a marker must print once per bound value — `unique`
        # here dropped a repeated `"Tb"."c" = ?` on SQLite and left a value with no marker.
        final_where = [join_conditions; instruction._where]
        
        sql = _update_from_sql(connection, safe_table_name, safe_alias, set_clause_parts, from_clause,
                               join(final_where, " AND "))
        multi_table = true
      end
    end
  else
    # No joins - simple UPDATE
    sql = """
    UPDATE $(safe_table_name) AS $(safe_alias)
    SET $(set_clause)
    WHERE $(join(instruction._where, " AND \n   "))
    """
  end

  _assigns_set_in_order(connection) &&
    _refuse_set_reading_assigned(set_fields, set_clause_parts, safe_alias, multi_table, connection)

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model.name, :update; 
                            parameters=parameters)
  end

  # @pormg_debug

  # return nothing

  # Execute with parameters and return affected row count (Django matched-rows semantics).
  try
    return _update_row_count(connection, settings, sql, parameters)
  catch e
    @error "Error executing UPDATE query" exception=(e, catch_backtrace()) sql=sql
    rethrow(e)
  end
end

function _row_update_pairs(updates::Dict{String,Any})
  return [field => updates[field] for field in sort(collect(keys(updates)))]
end

function _row_related_model(model::PormGModel, fk_meta::Models.sRelationalColumn)::PormGModel
  fk_meta.to isa PormGModel && return fk_meta.to

  model._module !== nothing || throw(QueryBuildError("Cannot resolve related model $(fk_meta.to) for $(model.name); model module is not initialized."))
  related = Base.invokelatest(getfield, model._module, Symbol(fk_meta.to))
  related isa PormGModel && return related
  throw(QueryBuildError("Related model $(fk_meta.to) for $(model.name) is not a PormG model."))
end

function _row_require_data_key(data::Dict{Symbol,Any}, key::Symbol, context::String)
  haskey(data, key) && return data[key]
  throw(QueryBuildError("Cannot save() $(context): row data does not include required key '$(key)'. Select it before mutating and saving the row."))
end

"""
    save(row::PormGRow; show_query=:execute) -> PormGRow | Vector

Persist dirty fields assigned on a `PormGRow`.

Direct fields update the row's own table. Projected fields like
`driverid__forename` update the related table identified by the `driverid`
foreign key value already present on the row.
"""
function save(row::PormGRow; show_query::Symbol = :execute)
  dirty = getfield(row, :_dirty)
  isempty(dirty) && return row

  data = getfield(row, :_data)
  model = getfield(row, :_model)

  pk_sym = try
    Models.get_model_pk_field(model)
  catch e
    # `get_model_pk_field` throws `ModelDefinitionError` on a composite pk (#239 migrated the
    # Models error contract; it was `ArgumentError` under #231). The re-thrown save() error below
    # stays a QueryBuildError — the caller's mistake is the save(), not the model definition.
    e isa ModelDefinitionError || rethrow(e)
    throw(QueryBuildError("save() requires exactly one primary key field; $(model.name) is not supported."))
  end
  pk_sym === nothing && throw(QueryBuildError("save() requires exactly one primary key field; $(model.name) is not supported."))

  own_updates = Dict{String,Any}()
  fk_updates = Dict{Symbol,Dict{String,Any}}()
  touched_fk_fields = Set{Symbol}()

  for dirty_sym in dirty
    normalized = _normalize_row_symbol(dirty_sym)
    normalized_string = String(normalized)
    separator = findfirst("__", normalized_string)

    if separator === nothing
      own_updates[normalized_string] = data[normalized]
      if haskey(model.fields, normalized_string) && model.fields[normalized_string] isa Models.sRelationalColumn
        push!(touched_fk_fields, normalized)
      end
    else
      fk_sym = Symbol(normalized_string[1:first(separator)-1])
      column = normalized_string[last(separator)+1:end]
      fk_bucket = get!(fk_updates, fk_sym, Dict{String,Any}())
      fk_bucket[column] = data[normalized]
    end
  end

  conflict = intersect(touched_fk_fields, Set(keys(fk_updates)))
  isempty(conflict) || throw(QueryBuildError(
    "Cannot save() a row after mutating both FK field(s) $(collect(conflict)) and projected '__' fields under the same prefix. Save the FK change separately first."
  ))

  settings, _, _ = get_settings(object(model))

  function planned_updates(show_mode::Symbol)
    inspections = Any[]

    if !isempty(own_updates)
      pk_value = _row_require_data_key(data, pk_sym, "own-table updates for $(model.name)")
      own_pairs = _row_update_pairs(own_updates)
      push!(inspections, object(model).filter(String(pk_sym) => pk_value).update(own_pairs...; show_query=show_mode))
    end

    for fk_sym in sort(collect(keys(fk_updates)); by=String)
      fk_meta = model.fields[String(fk_sym)]::Models.sRelationalColumn
      if fk_meta.pk_field === nothing
        throw(QueryBuildError(
          "save() cannot update projected fields under '$(fk_sym)' because the FK's " *
          "target primary key has not been resolved. Call set_models() to initialize " *
          "the model before using save() with projected FK fields."
        ))
      end
      fk_value = _row_require_data_key(data, fk_sym, "projected updates under '$(fk_sym)' for $(model.name)")
      related_model = _row_related_model(model, fk_meta)
      fk_pairs = _row_update_pairs(fk_updates[fk_sym])
      related_query = object(related_model)
      related_query.filter(String(fk_meta.pk_field) => fk_value)
      push!(inspections, related_query.update(fk_pairs...; show_query=show_mode))
    end

    return inspections
  end

  if show_query !== :execute
    return planned_updates(show_query)
  end

  run_in_transaction(settings) do
    planned_updates(:execute)
  end

  empty!(dirty)
  return row
end

"""
    delete(row::PormGRow; show_query=:execute) -> (total::Int, Dict{String,Integer})

Delete this fetched row from its table, cascading through the **same** `DeletionCollector` as
`Model.objects.filter(...).delete()` — so `on_delete` behaviour (CASCADE / SET_NULL / PROTECT)
is identical whether you delete one fetched row or a filtered set. Returns the
`(total_deleted, per-model counts)` tuple of the underlying queryset delete.

The row is located by its primary key, which must have been projected onto the row (it is, for
rows from `list()`/`first()`/`get()`). The in-memory `row` is not mutated — its data becomes
stale after the delete.
"""
function delete(row::PormGRow; show_query::Symbol = :execute)
  model = getfield(row, :_model)
  pk_sym = try
    Models.get_model_pk_field(model)
  catch e
    # get_model_pk_field throws ModelDefinitionError on a composite pk (#239; mirrors save()/pk()).
    e isa ModelDefinitionError || rethrow(e)
    throw(QueryBuildError("delete() requires exactly one primary key field; $(model.name) is not supported."))
  end
  pk_sym === nothing &&
    throw(QueryBuildError("delete() requires exactly one primary key field; $(model.name) is not supported."))

  data = getfield(row, :_data)
  haskey(data, pk_sym) ||
    throw(QueryBuildError("Cannot delete() this $(model.name) row: its primary-key column '$(pk_sym)' was not projected. Select it before deleting the row."))

  # Route the single pk through the queryset delete — one collector/cascade path, no drift (#208).
  return object(model).filter(String(pk_sym) => data[pk_sym]).delete(show_query=show_query)
end
