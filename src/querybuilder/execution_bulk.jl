# ---
# Execute bulk insert and update
#

# ---
# Helpers for bulk operations
#

function _normalize_bulk_columns(columns)
  _columns::Vector{Union{String, Pair{String, String}}} = []
  if columns === nothing
  elseif columns isa AbstractString
    push!(_columns, columns)
  elseif columns isa Pair{String, String}
    push!(_columns, columns)
  elseif columns isa Vector
    for column in columns
      if column isa AbstractString
        push!(_columns, column)
      elseif column isa Pair{String, String}
        push!(_columns, column)
      else
        throw(QueryBuildError("Invalid column specification: $column"))
      end
    end
  else
    throw(QueryBuildError("Invalid columns argument: $columns"))
  end
  return _columns
end

# #132: the bulk pipeline never mutates the caller's DataFrame — and never copies its
# data either. The working frame is a zero-copy wrapper (`copycols=false` shares the
# column vectors); every internal write is a WHOLE-COLUMN replacement or addition
# (`df[!, col] = ...`), which rebinds only the wrapper's column slot and leaves the
# caller's frame untouched. INVARIANT for future writers: never broadcast-assign
# (`.=`), `push!`, or `deleteat!` into an existing column/row of the working frame —
# that would write through the shared vectors into the caller's data. Only
# whole-column replacement/addition is safe here.
_bulk_working_frame(df_o::DataFrames.DataFrame) = DataFrames.select(df_o, :; copycols = false)

# #335: the name space PormG's own injected fill columns live in, kept disjoint from the caller's.
# `_prepare_bulk_df!` fills a whole column for every field the frame has no column for; before
# #335 it wrote to `df[!, field]` — the FIELD's name — which destroyed caller data whenever an
# explicit `columns=` Pair mapped some OTHER field to a source column of that name. The rule now
# is unconditional and needs no reachability argument: **a fill never takes a caller-supplied
# column name.** See `inject_fill_column!` inside `_prepare_bulk_df!`.
#
# The `:` is a TRIPWIRE, not decoration. It fails `SAFE_IDENTIFIER_PATTERN` (`sanitization.jl`),
# so if a future refactor ever pipes a `mapping` VALUE into `quote_identifier` the build throws
# instead of silently emitting a wrong column name into SQL. Today nothing does: every SQL column
# list is built from `fields_df`/`joined_columns` through `Models.model_column`, never from
# `names(df)`.
const _BULK_FILL_PREFIX = "__pormg:fill:"

# True for a working-frame column PormG injected rather than the caller supplying it. Used by the
# three places that would otherwise treat an internal name as the caller's own column:
# `_resolve_match_column!`'s SOURCE PRECEDENCE test (`declared`) and its not-found message, and
# `_depuration_values_bulk_insert`'s error.
#
# Deliberately a bare prefix test, and deliberately asymmetric with the WRITE side: the injection
# uniquifies against `names(df)` so a caller column named like the prefix is never overwritten,
# while these readers would misread it.
#
# #379 CHANGED WHAT THAT MISREADING COSTS, so the old "it is only cosmetic text" note is gone
# rather than edited. Two of the three readers still only shape a message — a column omitted from
# an error list, or a caller's own column reported as a "PormG-supplied default/auto value". The
# first is now BEHAVIORAL: `declared` decides whether a `columns=` mapping is honored at all, so a
# caller who both supplies a column named `__pormg:fill:<field>` AND maps it in `columns=` has
# that mapping silently ignored and is told PormG auto-populates the field. Pre-#379 the same
# false positive only suppressed a warning while the mapping still won.
#
# Still accepted, on a narrower argument than before: the name is one no caller writes by accident
# (the `:` makes it fail `SAFE_IDENTIFIER_PATTERN`, so it cannot even be a real column being
# mirrored from a database), and the escape — threading the actual injected-name set out of
# `_prepare_bulk_df!` and through three call sites — buys nothing for any reachable frame. If a
# caller-facing feature ever makes such a name reachable, this is the assumption that breaks first.
_is_injected_fill_column(name::AbstractString) = startswith(name, _BULK_FILL_PREFIX)

# #107 "one border crossing": `columns=` is the ONLY place a DataFrame column is mapped
# to a model field. `match_on=` selects merge keys by bare model-field name; its old
# `"df_col" => "model_field"` pair form is rejected with a migration error below.
function _normalize_bulk_match_on(match_on)::Vector{String}
  _match_on = String[]
  if match_on === nothing
  elseif match_on isa AbstractString
    push!(_match_on, match_on)
  elseif match_on isa Pair
    throw(QueryBuildError(_match_on_pair_migration_msg(match_on)))
  elseif match_on isa Vector
    for key in match_on
      if key isa AbstractString
        push!(_match_on, key)
      elseif key isa Pair
        throw(QueryBuildError(_match_on_pair_migration_msg(key)))
      else
        throw(QueryBuildError("Invalid match_on specification: $key"))
      end
    end
  else
    throw(QueryBuildError("Invalid match_on argument: $match_on"))
  end
  return _match_on
end

# ============================================================================
# DEPRECATION SHIM — TEMPORARY (remove once the pre-#107 pair grammar is retired)
#
# Before #107, `match_on=` accepted the same `"df_col" => "model_field"` grammar as
# `columns=`, so the df→field mapping could be declared in two places. The PERMANENT
# contract is: mappings live in `columns=` only; `match_on=` is bare model-field names.
# This helper only turns the removed pair form into an actionable migration error.
#
# TO REMOVE after the deprecation window: delete this helper and let the pair fall
# through to `_normalize_bulk_match_on`'s generic "Invalid match_on specification" error.
# ============================================================================
function _match_on_pair_migration_msg(pair::Pair)
  shown = "\"$(pair.first)\" => \"$(pair.second)\""
  return """
  bulk_update: `match_on=` no longer accepts `"df_col" => "model_field"` pairs (DEPRECATED API).
  `columns=` is the single place a DataFrame column is mapped to a model field; `match_on=`
  selects the merge keys by model field name. A field listed in both is used only for
  matching — match keys are never SET.

    Change:  match_on = [$(shown)]
    To:      columns  = [..., $(shown)], match_on = ["$(pair.second)"]

  This migration error is temporary and will be removed in a future release.
  """
end
# ============================================================================
# end deprecation shim
# ============================================================================

function _normalize_bulk_filters(filters)
  _filters::Vector{Union{String, Pair{String, <:Any}}} = []
  if filters === nothing
  elseif filters isa AbstractString
    push!(_filters, filters)
  elseif filters isa Pair{String, <:Any}
    push!(_filters, filters)
  elseif filters isa Vector
    for f in filters
      if f isa Union{String, Pair{String, <:Any}}
        push!(_filters, f)
      else
        throw(QueryBuildError("Invalid filter specification: $f"))
      end
    end
  else
    throw(QueryBuildError("Invalid filters argument: $filters"))
  end
  return _filters
end

function _is_blank_bulk_primary_key_value(value)
  if value === nothing || ismissing(value)
    return true
  end

  return value isa AbstractString && isempty(strip(value))
end

function _is_auto_generated_bulk_primary_key(field_meta)
  return field_meta.primary_key &&
    hasfield(typeof(field_meta), :auto_increment) &&
    getfield(field_meta, :auto_increment)
end

# #334: a UUIDField(primary_key = true, auto_add = true) is also PormG-minted, but through
# `auto_add` rather than `auto_increment`. `_is_auto_generated_bulk_primary_key` alone must stay
# auto_increment-only — `allocate_primary_keys` uses it to find a pk to reserve sequence values
# for, and a UUID pk has no sequence to reserve from. This is the wider "the DataFrame may leave
# this pk column out or blank; PormG can mint it" check, used only by the blank-rescue below.
function _is_pormg_minted_bulk_primary_key(field_meta)
  return _is_auto_generated_bulk_primary_key(field_meta) ||
    (field_meta.primary_key && field_meta.type == "UUID" && field_meta.auto_add)
end

# The single deliberate exception to the #331 rule ("a column the DataFrame carries is caller data;
# PormG never rewrites its cells"): a PormG-minted primary key column — auto-increment, or a UUID
# `auto_add` (#334) — whose values are ALL blank counts as ABSENT and is dropped from
# `mapping`/`fields_df` entirely, so the backend/PormG allocates the ids. Note it REMOVES the
# column rather than rewriting cells, so the rule itself still holds — a blank the caller wrote is
# never silently replaced by a different value. Mixed blank/explicit stays a hard error. Documented
# for users in docs/src/write/bulk.md → Auto-Generated Primary Keys.
#
# #334 exception-type note: before this fix, a UUID `auto_add` pk never reached this function at
# all (the old narrow predicate excluded it), so a mixed blank/explicit UUID pk column fell through
# to the ordinary NOT NULL sweep and raised `InvalidValueError`. It now hits the SAME mixed-value
# guard below as an auto-increment pk always has, and raises `QueryBuildError` — intentional, not a
# regression: the two pk kinds now agree on both the error type and the message shape.
function _drop_blank_auto_primary_keys!(df::DataFrames.DataFrame,
  model::PormGModel,
  fields_df::Vector{String},
  mapping::Dict{String, String},
  operation::Symbol)

  operation in (:insert, :copy) || return nothing

  for field in copy(fields_df)
    haskey(mapping, field) || continue

    f_meta = model.fields[field]
    _is_pormg_minted_bulk_primary_key(f_meta) || continue

    col_name = mapping[field]
    blank_mask = map(_is_blank_bulk_primary_key_value, df[!, col_name])

    if all(blank_mask)
      delete!(mapping, field)
      filter!(mapped_field -> mapped_field != field, fields_df)
    elseif any(blank_mask)
      throw(QueryBuildError("Error in bulk_$(operation), the auto-generated primary key field \e[4m\e[31m$(field)\e[0m has mixed blank and explicit values; either remove the column or provide a value for every row"))
    end
  end

  return nothing
end

"""
    allocate_primary_keys(objct::SQLObjectHandler, df::DataFrame; clone=true) -> DataFrame

Pre-allocate sequential primary key values for rows in `df` that are missing an
auto-generated primary key, and return the DataFrame with the pk column populated.

Use this when you need the assigned ids **before** inserting—for example, to wire up
foreign key columns in related tables that must be bulk-inserted in the same transaction.

If `df` already contains the primary key column with at least one non-blank value it is
returned unchanged and no ids are reserved. If the column is absent, or **every** value in
it is blank (`missing`, `nothing`, or an empty string), ids are reserved from the database.

If the column contains **mixed** values—some rows have explicit pk values and some are
blank—a `@warn` is emitted and the DataFrame is still returned unchanged. The blank rows
are left as-is and will raise a `QueryBuildError` when `bulk_insert` is called. To resolve
this you can: (1) provide a pk value for every row, (2) remove the pk column so all ids
are allocated automatically, or (3) pre-fill the blank rows before calling this function.

# PostgreSQL
Uses `nextval(pg_get_serial_sequence(...))` to atomically consume N values from the
identity/serial sequence. The reserved ids are guaranteed not to collide with concurrent
inserts. Note that if the subsequent bulk insert is never executed (e.g. the transaction
is rolled back), the consumed sequence values are **not** returned—this is normal
PostgreSQL sequence behaviour; gaps are harmless.

# SQLite
Reads the starting point from `max(MAX(pk), sqlite_sequence.seq)`, assigns the next
`N` ids from there, and bumps the table's `sqlite_sequence` counter to the end of the
reserved range. That keeps both later autoincrement inserts and later
`allocate_primary_keys()` calls from reusing ids that were reserved but not yet
inserted. This read-then-write is self-protecting: if it is not already running inside a
transaction on this connection it auto-opens one (`run_in_transaction`, i.e. `BEGIN
IMMEDIATE` + the in-process write lock) so no concurrent writer can claim the same range
in between — mirroring `bulk_insert`/`bulk_copy`/`bulk_update`. Wrapping the whole
pre-allocation **and** insert together in `run_in_transaction` is still recommended: then a
rolled-back insert also releases the reserved ids, whereas a standalone allocation whose
later insert fails durably burns its range (a harmless gap, exactly like PostgreSQL).

# Arguments
- `objct`: A `SQLObjectHandler` (typically `M.Model.objects`). Only the underlying model
  is consulted — any filters, ordering, or annotations attached to the handler are
  **ignored**, since pk allocation is a table-level operation independent of any query.
- `df`: The `DataFrame` that will be bulk-inserted.
- `clone::Bool = true`: When `true` (default) the returned DataFrame is a genuine copy
  with independent column vectors — the new pk column exists only on the returned frame,
  the caller's DataFrame is left untouched, and element writes on either frame never
  reach the other. Set to `false` to write the new pk column into the caller's DataFrame
  in place and skip the copy.

# Notes
- The returned pk column is a plain `Vector{Int}`. If the input DataFrame had a
  `Vector{Union{Missing,Int}}` pk column, the missing-able element type is dropped after
  allocation.
- The PostgreSQL backend currently assumes the model lives in the default search path
  (typically `public`). Models in other schemas are not supported by this helper.
  (`_update_sequence` no longer shares the limitation: since #344 it resolves the sequence
  through the table's own `relnamespace`.)

# Example
```julia
# Allocate driver ids before building the results table
drivers_df = CSV.File("f1/drivers.csv") |> DataFrame

PormG.run_in_transaction("db_2") do
    drivers_df = allocate_primary_keys(M.Driver.objects, drivers_df)

    results_df = DataFrame(
        driverid  = repeat(drivers_df.driverid, inner=10),
        raceid    = ...,
        ...
    )

    bulk_insert(M.Driver.objects, drivers_df)
    bulk_insert(M.Result.objects, results_df)
end
```
"""
function allocate_primary_keys(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; clone::Bool=true)
  model = objct.object.model
  settings, connection, conn_key = get_settings(objct)
  !settings.change_data && throw(_write_not_allowed("allocate_primary_keys", conn_key))

  # NOT the #132 zero-copy wrapper: unlike the bulk ops' internal working frames, this
  # frame is RETURNED to the caller, so shared vectors would be user-visible aliasing —
  # "clone" must mean independent columns (element writes on one frame never reach the
  # other). clone=false remains the explicit opt-in for in-place pk writing.
  df = clone ? Base.copy(df_o) : df_o
  n = DataFrames.nrow(df)
  n == 0 && return df

  # Find the single auto-generated primary key for this model
  pk_fields = [f for f in model.field_names
               if _is_auto_generated_bulk_primary_key(model.fields[f])]

  isempty(pk_fields) && return df

  if length(pk_fields) > 1
    throw(QueryBuildError("allocate_primary_keys: model $(model.name) has multiple auto-generated primary keys ($(join(pk_fields, ", "))); only models with a single auto-generated pk are supported"))
  end

  pk_field = pk_fields[1]

  # Already has explicit values — return unchanged
  if pk_field in DataFrames.names(df)
    col = df[!, pk_field]
    has_any = any(!_is_blank_bulk_primary_key_value(v) for v in col)
    if has_any
      has_blank = any(_is_blank_bulk_primary_key_value(v) for v in col)
      if has_blank
        n_blank = count(_is_blank_bulk_primary_key_value, col)
        @warn "allocate_primary_keys: column '$pk_field' in model $(model.name) has mixed values — $n_blank blank row(s) alongside explicit pk values. " *
              "The DataFrame is returned unchanged. Those blank rows will raise a QueryBuildError at bulk_insert time. " *
              "Options: (1) supply a pk value for every row, (2) remove the column so all ids are allocated automatically, " *
              "or (3) pre-fill the blank rows before calling allocate_primary_keys."
      end
      return df
    end
  end

  ids = if connection isa PormGPostgres
    _allocate_pg_ids(model, connection, pk_field, n)
  elseif connection isa PormGSQLite
    # #88: SQLite id reservation is a read-then-write on sqlite_sequence and must run under
    # BEGIN IMMEDIATE / with_sqlite_write_lock so concurrent writers can't claim the same range.
    # Reuse the caller's transaction if one is open on this pool (the reservation overlay stays
    # active); otherwise auto-wrap — same idiom as bulk_insert/bulk_copy/bulk_update.
    if transaction_connection_for(settings) !== nothing
      _allocate_sqlite_ids(model, connection, pk_field, n, settings)
    else
      run_in_transaction(settings) do
        _allocate_sqlite_ids(model, connection, pk_field, n, settings)
      end
    end
  else
    throw(_unsupported_conn("allocate_primary_keys", connection))
  end

  df[!, pk_field] = ids
  return df
end

allocate_primary_keys(model::PormGModel, df::DataFrames.DataFrame; kwargs...) =
  allocate_primary_keys(model |> object, df; kwargs...)

"""
    resync_sequences(objct::SQLObjectHandler) -> Vector{String}
    resync_sequences(model::PormGModel) -> Vector{String}
    resync_sequences(models::AbstractVector{<:PormGModel}) -> Nothing

Explicitly repair `model`'s primary-key sequence(s) to `MAX(pk) + 1`, without performing an
insert (#358).

`bulk_insert`/`bulk_copy` still resynchronize automatically after a bulk write with explicit
primary keys — that is where sequence drift is actually produced in volume. The row-level
writers (`create`/`insert`, `update_or_create`, `get_or_create`) do **not** auto-resync:
call this explicitly after one of them writes an explicit primary key, or after any
out-of-band load that can leave a sequence behind — a `pg_restore`, a manual `COPY`, or
data seeded outside PormG entirely.

# Arguments
- `objct` / `model`: the model (or its `SQLObjectHandler`, e.g. `M.Model.objects`) whose
  declared primary-key field(s) should be resynchronized. `models`: a collection, resynced
  one at a time.

# Returns
The names of the pk fields the repair was attempted for (empty if the model has none) —
`nothing` for the plural form. Per-field failure is not raised as an exception here; it
follows `_update_sequence`'s own reporting (`@warn` outside a transaction, propagates inside
one — see [Sequence synchronisation](@ref) in `schema_conventions.md`).

# Example
```julia
# A migration replays historical drivers with their original ids.
for row in eachrow(legacy_drivers)
    M.Driver.objects.create("driverid" => row.id, "forename" => row.forename)
end
resync_sequences(M.Driver)   # once, after the batch — not per row

# A later ordinary create() is safe again:
M.Driver.objects.create("forename" => "Auto")
```
"""
function resync_sequences(objct::SQLObjectHandler)
  model = objct.object.model
  ensure_model_transaction_scope(model)
  settings, connection, conn_key = get_settings(objct)
  !settings.change_data && throw(_write_not_allowed("resync_sequences", conn_key))

  # ALL of the model's declared pk fields — unlike _prepare_row_insert!'s pk_field (built from
  # one specific insert dict), resync_sequences has no "this call" to condition on. Iterate
  # model.field_names (the canonical ordered field list every other call site in this file uses
  # for this purpose), not `keys(model.fields)`, which is an unordered Dict.
  pk_field = String[f for f in model.field_names if model.fields[f].primary_key]
  isempty(pk_field) && return pk_field

  connection isa Union{PormGPostgres, PormGSQLite} ||
    throw(_unsupported_conn("resync_sequences()", connection))
  _update_sequence(model, connection, pk_field, settings)
  return pk_field
end
resync_sequences(model::PormGModel) = resync_sequences(model |> object)
resync_sequences(models::AbstractVector{<:PormGModel}) = (foreach(resync_sequences, models); nothing)

function _single_auto_generated_primary_key(model::PormGModel)
  pk_fields = [field for field in model.field_names if _is_auto_generated_bulk_primary_key(model.fields[field])]
  isempty(pk_fields) && return nothing

  if length(pk_fields) > 1
    throw(QueryBuildError("allocate_primary_keys: model $(model.name) has multiple auto-generated primary keys ($(join(pk_fields, ", "))); only models with a single auto-generated pk are supported"))
  end

  return pk_fields[1]
end

# Reserves n ids from the PostgreSQL sequence associated with pk_field.
# Uses nextval() inside generate_series so the allocation is a single atomic roundtrip.
function _allocate_pg_ids(model::PormGModel, connection::PormGPostgres, pk_field::String, n::Int)
  # `pg_get_serial_sequence` re-parses its first argument as an identifier, so an unquoted
  # mixed-case table folds to lowercase and resolves to nothing. Bind the DOUBLE-QUOTED form; it is
  # equally correct for an all-lowercase name (#59). Still a bound parameter, not interpolation.
  safe_table = "\"$(replace(Models.model_table_name(model), "\"" => "\"\""))\""
  parameters = get_parameter(connection)
  set_context!(parameters, :select)
  table_placeholder = add_parameter!(parameters, safe_table)
  field_placeholder = add_parameter!(parameters, Models.model_column(model, pk_field))  # db_column (#50)
  count_placeholder = add_parameter!(parameters, n)
  sql = """
  SELECT nextval(pg_get_serial_sequence($(table_placeholder), $(field_placeholder))) AS reserved_id
  FROM generate_series(1, $(count_placeholder))
  ORDER BY 1
  """
  result = fetch(connection, sql, parameters) |> DataFrames.DataFrame
  return result[!, :reserved_id]
end

# Reads the starting point for SQLite allocation from the larger of:
#   1. MAX(pk) already present in the table
#   2. sqlite_sequence.seq, which may already reflect a previously reserved range
#      that has not been inserted yet.
# This prevents a second allocate_primary_keys() call from reusing ids that were
# already handed out. INSERT OR REPLACE handles the case where the sqlite_sequence
# row does not yet exist (empty AUTOINCREMENT table). This read-then-write must run
# inside a transaction on this connection (BEGIN IMMEDIATE + with_sqlite_write_lock) to
# avoid concurrent races — a future direct caller MUST preserve that invariant. Both
# current callers do: allocate_primary_keys auto-wraps this in run_in_transaction whenever
# one isn't already active (#88), and the create() path (execution.jl) reaches here only
# when get_sqlite_reserved_primary_key_max returned non-nothing, which already implies an
# open transaction (reservation overlay is a no-op at depth 0).
function _allocate_sqlite_ids(model::PormGModel, connection::PormGSQLite, pk_field::String, n::Int, settings::PormGSettings)
  safe_table = Models.model_table_name(model)
  safe_table_name = safe_table_identifier(safe_table, connection)
  safe_table_literal = replace(safe_table, "'" => "''")
  safe_field = safe_column_identifier(Models.model_column(model, pk_field), connection)  # db_column (#50)
  sql = """
  SELECT MAX(candidate) AS max_id
  FROM (
    SELECT COALESCE(MAX($(safe_field)), 0) AS candidate FROM $(safe_table_name)
    UNION ALL
    SELECT COALESCE(seq, 0) AS candidate FROM sqlite_sequence WHERE name = '$(safe_table_literal)'
  ) AS allocation_state
  """
  result = fetch(settings, sql) |> DataFrames.DataFrame
  max_id = result[1, :max_id]
  max_id = (ismissing(max_id) || isnothing(max_id)) ? Int64(0) : Int64(max_id)
  reserved_max = get_sqlite_reserved_primary_key_max(model, pk_field)
  max_id = max(max_id, something(reserved_max, Int64(0)))
  new_max = max_id + n

  bump_sql = "INSERT OR REPLACE INTO sqlite_sequence(name, seq) VALUES('$(safe_table_literal)', $(new_max));"
  fetch(settings, bump_sql)
  register_sqlite_reserved_primary_key_max!(model, pk_field, new_max)

  return collect((max_id + 1):new_max)
end

# ---
# Case-sensitive bulk column matching
#
# Bulk operations match DataFrame columns to model fields EXACTLY (case-sensitive).
# The helpers below turn a near-miss — a name that differs only in case — into a loud,
# actionable error instead of a silent, order-dependent case-fold. This matters once a
# model legitimately carries mixed-case identifiers (commit 9958a16, "mandatory quoting
# to support Unicode and mixed-case identifiers"): folding case could map the wrong
# column or mask a real mismatch, and `findfirst` would silently pick the first of two
# columns differing only in case.

# Return every name in `candidates` that differs from `target` ONLY by case — i.e. not
# an exact match, but equal after lowercasing. Empty when the match is exact or nothing
# is close.
function _case_fold_candidates(target::AbstractString, candidates)
  target_lc = lowercase(target)
  return String[c for c in candidates if c != target && lowercase(c) == target_lc]
end

# Build the actionable error raised when bulk matching finds no exact match but a
# case-only-differing name exists. `looked_for` is the name searched for, `candidates`
# the case-only matches, and `map_hint` a ready-to-paste `"df_col" => "field"` example.
function _bulk_case_mismatch_msg(operation::Symbol, looked_for::AbstractString,
                                 candidates, map_hint::AbstractString)
  names_str = join(("\e[4m\e[31m$(c)\e[0m" for c in candidates), ", ")
  return """
  Error in bulk_$(operation): bulk column matching is case-sensitive, and \e[4m\e[31m$(looked_for)\e[0m has no exact match — but these names differ only in case: $(names_str).
  Fix it either by renaming so the names match exactly (e.g. rename!(df, lowercase.(names(df)))) or by mapping the column explicitly (e.g. $(map_hint)).
  """
end

function _prepare_bulk_df!(df::DataFrames.DataFrame, model::PormGModel,
                          normalized_columns::Vector, operation::Symbol,
                          settings=nothing)
  fields = model.field_names
  fields_df::Vector{String} = []
  mapping = Dict{String, String}() # model_field => df_column

  # What PormG fills into a column the DataFrame does NOT carry: a static `default`, an
  # auto_now/auto_now_add timestamp, or a UUID `auto_add` value. Returns
  # (should_fill, value_or_values, per_row). `per_row` is true only for the UUID `auto_add` case,
  # where `value_or_values` is already a Vector sized to `DataFrames.nrow(df)` — one fresh UUID
  # per row. For every other fill kind `per_row` is false and `value_or_values` is the single
  # value broadcast across the whole batch, unchanged from before #334.
  #
  # #331: this is consulted ONLY where the field has no mapped source column in the frame — both
  # call sites below are guarded on exactly that (`!haskey(mapping, field)` in one arm, the
  # not-in-`fields_df` arm in the other, where `mapping ⊆ fields_df` makes it equivalent). A column
  # the field IS mapped to holds caller-authored data and is never rewritten, so there is nothing
  # to ask about it — hence the name. The pre-#331 signature re-declared `operation`/`settings` as
  # parameters that shadowed the enclosing ones with the same values, which read as if a caller
  # could vary them; they come from the enclosing scope now.
  #
  # #335 (fixed): the injection sites used to write to `df[!, field]`, using the field's own name
  # as the frame column. If an explicit `columns=` Pair mapped some OTHER field to a source column
  # that happened to be named `field`, that write landed on the column the other field reads from
  # and destroyed the caller's values — e.g. `columns = ["laps" => "pit_stops"]` on a model that
  # also declares a defaulted `laps` made `pit_stops` bind `laps`'s default instead of the frame's
  # numbers, silently. Both sites now route through `inject_fill_column!` below, which never writes
  # to a caller-supplied name at all.
  #
  # #334 (fixed): the UUID branch below used to call `uuid4()` ONCE per field, and the two
  # injection sites broadcast that single value across the whole frame — every row of an
  # absent `auto_add` UUID column got the SAME value, colliding immediately on a primary or
  # unique column. It now returns one fresh UUID PER ROW (`per_row = true`), while the
  # temporal fills stay deliberately ONE value per batch (one `now()` per batch is
  # intentional, matching `_prepare_row_insert!`'s comment above). The two injection sites
  # stay generic: they branch on `per_row`, never on field type.
  #
  # The chain is deliberately EXCLUSIVE and default-first, mirroring `_prepare_row_insert!`
  # (execution.jl:557-572): a field carrying BOTH a static `default` and `auto_now` takes the
  # default, on the single-row and bulk paths alike.
  function resolve_absent_column_fill(f_meta)
    if f_meta.default !== nothing
      return true, f_meta.default, false
    elseif f_meta.type == "TIMESTAMPTZ"
      if operation in [:insert, :copy] && (f_meta.auto_now_add || f_meta.auto_now)
        value = settings === nothing ? now(TimeZone("UTC")) : f_meta.formatter(now(TimeZone(settings.time_zone)))
        return true, value, false
      elseif operation == :update && f_meta.auto_now
        value = settings === nothing ? now(TimeZone("UTC")) : f_meta.formatter(now(TimeZone(settings.time_zone)))
        return true, value, false
      end
    elseif f_meta.type == "DATE"
      if operation in [:insert, :copy] && (f_meta.auto_now_add || f_meta.auto_now)
        # NOTE: `today()` is returned as a bare `Date` object without calling
        # `f_meta.formatter` here. The DATE formatter (`format_date_sql`) only
        # converts Date → String and does not transform the value (no time_zone
        # argument), unlike the TIMESTAMPTZ formatter which returns a ZonedDateTime.
        # Sanitization handles both `Date` objects and date strings correctly, so
        # bypassing the formatter is intentional. If `DateField` ever gains a
        # custom value-transforming formatter, this path must be updated to call it.
        return true, today(), false
      elseif operation == :update && f_meta.auto_now
        return true, today(), false
      end
    elseif f_meta.type == "UUID" && f_meta.auto_add
      if operation in [:insert, :copy]
        # #334: one distinct UUID per row, not one for the whole batch.
        return true, [UUIDs.uuid4() for _ in 1:DataFrames.nrow(df)], true
      end
    end

    return false, nothing, false
  end

  # Inject one whole column of `fill_value` for a field the frame has no column for, and point
  # `mapping` at it. Returns `true` when a column was injected, `false` when the explicit-scope
  # UPDATE guard suppressed it. Captures `df`/`mapping`/`operation`/`normalized_columns` from the
  # enclosing scope, like `resolve_absent_column_fill` above.
  #
  # #335: the destination is ALWAYS a private `_BULK_FILL_PREFIX` column, never the field's own
  # name and never any name the caller supplied. That is the whole fix, and it is deliberately
  # UNCONDITIONAL: a redirect that fired only on a detected collision would carry a reachability
  # proof ("no other field reads this name") that a later edit to the `columns=` handling above
  # could silently invalidate. One rule, one code path, nothing to re-derive.
  #
  # No VALUE read of the working frame is affected: `_drop_blank_auto_primary_keys!`, the three
  # per-row loops in `bulk_insert`/`bulk_copy`/`bulk_update`, `_ensure_unique_bulk_update_keys!`
  # and `_depuration_values_bulk_insert` all index through `mapping[field]`, and every SQL column
  # list comes from `fields_df`/`joined_columns` → `Models.model_column`. A same-named column the
  # caller supplied but `columns=` excluded therefore keeps its values in the working frame
  # instead of being overwritten, with no change to what is bound — see the scope note in the
  # second arm below.
  #
  # What the redirect DOES change is the frame's NAME SET, and one predicate reads it:
  # `_is_legacy_dynamic_filter` tests `f.first in names(df)`. An injected field no longer puts its
  # own name there, so `filters = ["<auto-populated-field>" => "<model-field>"]` — pre-#335 caught
  # by the `filters=` deprecation error, because the injection had just put that name in the frame
  # — is now classified as the constant predicate the caller literally wrote.
  #
  # Be precise about the cost, because it is NOT error-for-error: on a field whose formatter
  # accepts the right-hand string the call now RUNS, adding a `WHERE <field> = '<model-field>'`
  # predicate that matches nothing, where before it raised "move this to match_on=". Accepted for
  # one reason only — `_is_legacy_dynamic_filter` is half of a shim already marked for deletion
  # (see the DEPRECATION SHIM block below), so #335 narrows the reach of a helper that is on its
  # way out rather than degrading permanent behavior. No `UPGRADING.md` entry is owed: the bar
  # there is a change that FORCES a consuming-app source edit, and a call that was raising a
  # migration error was already being told to change.
  #
  # Whole-column ADDITION only, never a write into an existing slot — the #132 zero-copy invariant
  # (see `_bulk_working_frame`). The uniquifying loop is what keeps it an addition: a caller column
  # already named like the prefix would otherwise be clobbered, which is #335 over again.
  function inject_fill_column!(field::String, f_meta, fill_value, per_row::Bool)
    # For an explicit-scope UPDATE (columns= was provided), a static `default` must NOT be
    # synthesized: that would overwrite live rows merely because the DataFrame lacks the column.
    # Temporal auto_now/auto_now_add injections are always allowed — an intentional ORM
    # side-effect. Unchanged by #331; #335 folded it in from both call sites so the two arms are
    # provably identical rather than only visually identical.
    operation == :update && !isempty(normalized_columns) && f_meta.default !== nothing &&
      return false

    target = "$(_BULK_FILL_PREFIX)$(field)"
    suffix = 1
    while target in names(df)
      suffix += 1
      target = "$(_BULK_FILL_PREFIX)$(field):$(suffix)"
    end

    # #334: `per_row` means fill_value is already a Vector, one distinct value per row (currently
    # only the UUID auto_add case) — otherwise broadcast the one value. `nrow` replaced a `ref_col`
    # pick that grabbed an arbitrary `mapping` key purely for its length and indexed `df[!, 1]`
    # when `mapping` was empty (a latent `BoundsError` on a column-less frame).
    df[!, target] = per_row ? fill_value : fill(fill_value, DataFrames.nrow(df))
    mapping[field] = target
    return true
  end

  # Record one `columns=` entry's claim: model field `field` reads from DataFrame column `source`.
  # Captures `mapping`/`fields_df`/`operation` from the enclosing scope, like the two closures
  # above. Both `columns=` branches route through here so the rule and its message exist once.
  #
  # #380: the SAME model field claimed from DIFFERENT source columns used to be last-wins and
  # silent — one of the two columns the caller named was dropped without a word, and WHICH one
  # survived depended on list position, so an innocuous reorder changed what got written. That is
  # never a meaningful instruction; it is a typo, a copy-paste slip, or a programmatically built
  # `columns=` carrying a duplicate. It is also the only `columns=` mistake this loop used to
  # swallow: an absent source column is a hard error, and a case-only near-miss is a hard error
  # with a paste-ready hint.
  #
  # An EXACT repeat stays legal — nothing is being chosen between and nothing is lost — which keeps
  # one uniform rule across both branches instead of a separate policy per entry shape. The
  # duplicate `push!` it leaves in `fields_df` is absorbed by the `|> unique` that builds
  # `final_fields` at the end of this function; without that, a repeat would emit the same column
  # twice in the SET list and PostgreSQL would reject it ("multiple assignments to same column").
  #
  # THE KEY IS `mapping`, NOT `fields_df`, and that is load-bearing. The bare-string branch below
  # pushes to `fields_df` WITHOUT writing `mapping` when the frame has no column of that name (the
  # "may be auto-populated later" path). A guard written as `field in fields_df` would therefore
  # fire on `columns = ["laps", "c2" => "laps"]` over a frame with no `laps` column and reject a
  # legal call: the string claimed no source at all, so the Pair is the only claim on frame data.
  function claim_field!(field::AbstractString, source::AbstractString)
    if haskey(mapping, field) && mapping[field] != source
      throw(QueryBuildError("Error in bulk_$(operation), the field \e[4m\e[31m$(field)\e[0m is mapped from two different columns in columns=: \e[4m\e[31m$(mapping[field])\e[0m and \e[4m\e[31m$(source)\e[0m. Keep only the mapping you want."))
    end
    mapping[field] = source
    push!(fields_df, field)
    return nothing
  end

  # 1. Identify mappings and check required columns
  if !isempty(normalized_columns)
    for column in normalized_columns
      if column isa Pair
        # Explicit "df_col" => "model_field" mapping. column.first is the DF column,
        # column.second the model field. The source column must exist EXACTLY — a
        # mismatch is a hard error, not a silent log (the old @error left a bad mapping
        # in place and crashed cryptically downstream).
        if column.first in names(df)
          claim_field!(column.second, column.first)
        else
          # Offer the case hint when the only near-miss differs solely in case,
          # consistent with the string/auto-detect/match_on paths above.
          candidates = _case_fold_candidates(column.first, names(df))
          isempty(candidates) ||
            throw(UnknownFieldError(_bulk_case_mismatch_msg(operation, column.first, candidates,
              "\"$(candidates[1])\" => \"$(column.second)\"")))
          throw(UnknownFieldError("Error in bulk_$(operation), the column \e[4m\e[31m$(column.first)\e[0m mapped to field \e[4m\e[31m$(column.second)\e[0m is not in the DataFrame; available columns: \e[4m\e[32m$(names(df))\e[0m"))
        end
      else
        # String column: match the DataFrame column name EXACTLY (case-sensitive).
        if column in names(df)
          # Identity claim: the frame column and the model field share the name. A conflict here
          # therefore always comes from an EARLIER Pair that pointed the same field elsewhere.
          claim_field!(column, column)
        else
          # No exact match. If a column differs only in case, fail loudly instead of
          # silently case-folding (see the case-sensitive matching contract above).
          candidates = _case_fold_candidates(column, names(df))
          isempty(candidates) ||
            throw(UnknownFieldError(_bulk_case_mismatch_msg(operation, column, candidates,
              "\"$(candidates[1])\" => \"$(column)\"")))
          # Truly absent — it may be an auto-populated field added later (e.g. updated_at).
          push!(fields_df, column)
        end
      end
    end
  else
    # Auto-detect: a DataFrame column maps to a model field only on an EXACT
    # (case-sensitive) name match. A column that differs only in case from a model
    # field is a likely-intended typo, so fail loudly rather than fold or ignore it.
    for col_name in names(df)
      if col_name in fields
        mapping[col_name] = col_name
        push!(fields_df, col_name)
      else
        candidates = _case_fold_candidates(col_name, fields)
        isempty(candidates) ||
          throw(UnknownFieldError(_bulk_case_mismatch_msg(operation, col_name, candidates,
            "\"$(col_name)\" => \"$(candidates[1])\"")))
      end
    end
  end

  _drop_blank_auto_primary_keys!(df, model, fields_df, mapping, operation)

  # 2. Defaults, auto-population and basic constraints
  pk_exist = false
  pk_field = String[]
  
  for field in fields
    f_meta = model.fields[field]
    
    if in(field, fields_df)
      # ────────────────────────────────────────────────────────────────────────────────────────
      # #331 — THE ONE RULE, for a field that TAKES PART in the write: PormG fills a value only
      # when the DataFrame has no column for that field. A column that IS present is
      # caller-authored data, and PormG never rewrites its cells — not for a static `default`,
      # not for `auto_now`/`auto_now_add`, not for a UUID `auto_add`; on :insert, :copy and
      # :update alike; nullable or not.
      #
      # "Takes part in the write" is what `in(field, fields_df)` above means: auto-detected from
      # the frame, or named in an explicit `columns=`. A field `columns=` left out is out of
      # scope by the caller's own instruction and is handled in the other arm — see the scope
      # note there for why it is filled rather than read from the frame.
      #
      # So a blank cell (`missing`/`nothing`) in a present column means the caller asked for NULL,
      # exactly as `create()` reads an explicit `"field" => nothing`: `_prepare_row_insert!`
      # (execution.jl:557) fills only when `!haskey(real_obj.insert, field)`. On a NOT NULL field
      # the blank then surfaces the ORM's own "null values are not allowed" from the per-row
      # `validate_field_data` sweep every path already runs (:insert below, :copy and :update in
      # their own loops) — the same error `create()` raises — instead of being silently papered
      # over with the default.
      #
      # Pre-#331 a fourth fill site lived here, keyed on `haskey(mapping, field)`:
      #     df[!, col_name] = map(x -> ismissing(x) || isnothing(x) ? fill_value : x, df[!, col_name])
      # It carried no `is_explicit_update && is_static_default` guard (unlike the two absent-column
      # sites below), so all three bulk ops disagreed with `create()` on the same input and turned
      # an intentional NULL into the model default. Deleting it left this arm with a single
      # branch, so the condition is inverted: what remains reads as "the DataFrame has no column
      # for this field", which is the rule spelled by the control flow.
      #
      # Narrow known consequence: `bulk_update` exempts match keys and static-filter fields from
      # the per-row null check, so a blank cell in a DEFAULTED match-key column is no longer
      # back-filled — it now matches nothing rather than matching the default-valued row. That is
      # the rule applied consistently, not an oversight.
      # ────────────────────────────────────────────────────────────────────────────────────────
      if !haskey(mapping, field)
        # ABSENT column: the field was requested via `columns=` but the DataFrame has no column
        # for it. The fill rule applies — inject one whole column of the fill value.
        #
        # Reachable only through the bare-string branch of `columns=` whose column is NOT in
        # `names(df)` (the `push!(fields_df, column)` above), so `field ∉ names(df)` holds here
        # unconditionally: this site never had a name to collide with, and its `inject_fill_column!`
        # call is for symmetry with the other arm, not because #335 could bite here. Stated
        # explicitly so a later edit to that branch does not read this as a guarantee it provides.
        should_auto_populate, fill_value, per_row = resolve_absent_column_fill(f_meta)

        if should_auto_populate
          inject_fill_column!(field, f_meta, fill_value, per_row)
        elseif f_meta.primary_key
          # It's a PK, we'll collect it later
        elseif !f_meta.null && operation in [:insert, :copy]
          throw(InvalidValueError("Error in bulk_$operation, the field \e[4m\e[31m$(field)\e[0m does not allow null and has no default value"))
        end
      end

      if f_meta.primary_key
        pk_exist = true
        push!(pk_field, field)
      end
    else
      # Field not in fields_df — it takes no part in the write, either because the DataFrame has
      # no column for it or because an explicit `columns=` left it out. See if we should
      # auto-populate it anyway (e.g. updated_at).
      #
      # #331 scope note: this branch can fire for a field whose same-named column IS in the
      # DataFrame, when `columns=` excluded it. That is NOT the rewrite #331 removed. `columns=`
      # is the caller saying "do not write this field", so those cells were never going to be
      # persisted; injecting the default here is what lets a partial `columns=` insert still
      # satisfy the model's NOT NULL columns (pinned by test_bulk_update_column_scope.jl). The
      # #331 rule governs the cells of a field that DOES take part in the write — see the comment
      # in the other arm.
      #
      # Deferring to the frame here instead — reading the excluded column's values — was
      # considered and rejected: it would make `columns=` stop deciding what gets written, which
      # is a worse contract than the one above.
      #
      # #335 changed WHERE the injection lands, not WHAT gets bound: the excluded field still
      # binds its default, but the fill goes to a private column, so the caller's same-named
      # column now keeps its values in the working frame instead of being overwritten. Nothing
      # reads it — every consumer goes through `mapping` — so the SQL and the parameters are
      # identical either way. (This is also why the "narrow deferral" once sketched here is moot:
      # it proposed reading `df[!, field]` when `field in names(df)`, which is exactly the
      # aliasing #335 removed.)
      should_auto_populate, fill_value, per_row = resolve_absent_column_fill(f_meta)

      if should_auto_populate
        # A suppressed static default returns false, so the field stays out of fields_df — the
        # explicit-scope UPDATE rule, now enforced inside the helper for both arms at once.
        inject_fill_column!(field, f_meta, fill_value, per_row) && push!(fields_df, field)
      elseif f_meta.primary_key
        push!(pk_field, field)
      end
    end
  end
  
  # Final sanity check for fields_df existence in model
  for field in fields_df
    in(field, fields) || throw(UnknownFieldError("Error in bulk_$operation, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m"))
  end

  # Return fields_df cleaned up (unique and existing in mapping)
  final_fields = [f for f in fields_df if haskey(mapping, f)] |> unique

  return mapping, final_fields, pk_exist, pk_field
end

function _ensure_unique_bulk_update_keys!(df::DataFrames.DataFrame,
  mapping::Dict{String, String},
  dynamic_filters::Vector{String})

  isempty(dynamic_filters) && return nothing

  seen_keys = Dict{Tuple, Int}()
  for (index, row) in enumerate(eachrow(df))
    key = Tuple(row[mapping[field]] for field in dynamic_filters)
    if haskey(seen_keys, key)
      filters_text = join(dynamic_filters, ", ")
      throw(QueryBuildError("Error in bulk_update, duplicate dynamic filter key values detected for filters [$filters_text] at rows $(seen_keys[key]) and $(index): $(collect(key))"))
    end
    seen_keys[key] = index
  end

  return nothing
end

# Name the fill kind for `_no_match_source_msg` below. Deliberately mirrors
# `resolve_absent_column_fill`'s own default-first branch order and its TYPE-keyed dispatch, so
# the two can never describe the same field differently — and type-keyed is not a stylistic
# choice: `auto_now`/`auto_now_add` are fields of DateField/DateTimeField only and `auto_add` of
# UUIDField only, so a bare `f_meta.auto_now` would be a `FieldError` on every other field type.
# The final fallback is unreachable today (a fill exists only because that chain returned true)
# and is here so a future fill kind degrades to vague text instead of throwing inside an error path.
function _bulk_fill_kind_label(f_meta)
  f_meta.default !== nothing && return "a static `default`"
  f_meta.type in ("TIMESTAMPTZ", "DATE") && f_meta.auto_now && return "`auto_now`"
  f_meta.type in ("TIMESTAMPTZ", "DATE") && f_meta.auto_now_add && return "`auto_now_add`"
  f_meta.type == "UUID" && f_meta.auto_add && return "`auto_add`"
  return "an ORM-supplied value"
end

# #379: a merge key that PormG would auto-populate but that the caller gave no source for.
# `kind` is "match_on" or "primary key"; the closing advice differs by kind — see below.
function _no_match_source_msg(kind::AbstractString, field::AbstractString, f_meta)
  # The escape differs by kind, and BOTH forms name a replacement key rather than only a place to
  # move the predicate to. Advising `filters=` alone would be a half-fix: dropping the field from
  # `match_on=` empties it, the primary-key fallback takes over, and the caller lands on the same
  # error for the pk instead. A pk fallback has no `filters=` route at all — a constant predicate
  # on the pk still leaves no per-row key — so it is offered a different `match_on=` key only.
  escape = kind == "match_on" ?
    "move it to `filters=` as a constant predicate and name a real per-row key in `match_on=`" :
    "name a different merge key in `match_on=`"
  # "no columns= ENTRY supplies a source column", not "no columns= mapping targets it": a bare
  # string in `columns=` naming a field the frame has no column for DOES target the field (it is
  # the "may be auto-populated later" path), so the narrower wording reads as false to that caller.
  return """
  bulk_update: $(kind) field \e[4m\e[31m$(field)\e[0m has no source column — the DataFrame has no column of that name, and no columns= entry supplies one for it.
  PormG auto-populates \e[4m\e[31m$(field)\e[0m ($(_bulk_fill_kind_label(f_meta))), but a merge key must come from your data: an auto-populated value is minted once per call, so it would match no rows.
  Add a DataFrame column named \e[4m\e[32m$(field)\e[0m, map one in columns= (e.g. columns = [..., \"my_col\" => \"$(field)\"]), or $(escape).
  """
end

# Map one match key (a bare MODEL FIELD name — #107) into mapping / fields_df /
# dynamic_filters. Unlike the legacy `filters=` path, a missing source column is a hard
# error rather than a silent fall-through to a static predicate.
#
# SOURCE PRECEDENCE (#379): a DECLARED `columns=` mapping → the caller's own same-named column
# → raise.
#
# The first arm is mapping-first by design (#107): a `columns=` Pair is a caller instruction and
# is authoritative for its field, so a same-named column loses to it. (Pre-#107 the order was
# reversed — an exact df column won over the mapping — which made a same-named column silently
# override the declared mapping.)
#
# An INJECTED FILL is not a caller instruction. It is PormG's own side effect for a field
# `columns=` left out of scope, and #379 demotes it below the caller's column: it used to satisfy
# a bare `haskey(mapping, field)` and win the first arm, binding a `now()` minted microseconds ago
# as the merge key, so the UPDATE matched zero rows and reported success — silently, with no
# warning and no error. A fill now loses to a caller column and, with no caller column at all,
# raises rather than matching on a per-call constant.
#
# The fill is left in place rather than suppressed at the injection site (the issue's fix B),
# because rebinding `mapping[field]` below ORPHANS it and nothing reads an orphan:
#   - every VALUE read goes through `mapping` — `_ensure_unique_bulk_update_keys!`,
#     `bulk_update`'s row loop, `_depuration_values_bulk_insert`;
#   - every SQL column list comes from `fields_df`/`joined_columns` → `Models.model_column`,
#     never from `names(df)`;
#   - `deny_fields` already excludes match keys from the SET clause, so the fill is never written;
#   - the working frame is a `copycols = false` wrapper (#132), so the stray column never reaches
#     the caller's own DataFrame.
# Suppressing it would instead mean threading `match_on`/the pk fallback into `_prepare_bulk_df!`,
# which `bulk_insert` and `bulk_copy` share — a wider blast radius for no behavior change.
function _resolve_match_column!(df::DataFrames.DataFrame, model::PormGModel,
  mapping::Dict{String, String}, fields_df::Vector{String},
  dynamic_filters::Vector{String}, field::String;
  kind::String="match_on")

  field in model.field_names ||
    throw(UnknownFieldError("bulk_update: $(kind) field \e[4m\e[31m$(field)\e[0m is not a field of model $(model.name)"))

  # A mapping the CALLER declared in `columns=`, as opposed to one `_prepare_bulk_df!` injected.
  declared = haskey(mapping, field) && !_is_injected_fill_column(mapping[field])

  resolved = if declared
    # `columns=` mapping wins. If the df ALSO carries a column named exactly like the
    # field, it is ignored in favor of the declared mapping — surface that loudly.
    #
    # #335 added `!_is_injected_fill_column(mapping[field])` to this condition, to keep the
    # warning quiet for an auto-populated field whose `mapped_source` the caller never wrote.
    # #379 moved that test up into `declared`, so an injected fill can no longer reach this arm
    # at all and the condition reduces to what it always meant. Deliberately NO warning on the
    # new fill-loses-to-caller-column path: that is the documented behavior (`write/bulk.md` →
    # *Mapping-first match keys*), and a warning for behaving as documented is noise.
    if mapping[field] != field && field in names(df)
      @warn "bulk_update: $(kind) resolved through the columns= mapping; the same-named DataFrame column is ignored" field=field mapped_source=mapping[field] ignored_column=field
    end
    mapping[field]
  elseif field in names(df)
    field                                 # identity: the caller's own column, over any fill
  else
    # No declared mapping and no exact same-named column. A column differing only in case is a
    # loud error, not a silent fold (see the case-sensitive matching contract above).
    #
    # #335: this runs AFTER `_prepare_bulk_df!`, so the working frame also carries PormG's own
    # fill columns. Report — and offer as "did you mean" candidates — only what the caller
    # actually supplied; a `columns:` list containing `__pormg:fill:updated_at` reads as a bug in
    # PormG, not as help. Filtering the CANDIDATE source matters more than the message: a
    # candidate is interpolated into a paste-ready `columns = [..., "X" => "field"]` suggestion,
    # so a leaked internal name there would be actively wrong advice rather than noise.
    #
    # The rule for post-injection `names(df)` readers is LISTINGS, not membership: any reader that
    # SHOWS the frame's columns owes this filter, while the two membership tests above
    # (`field in names(df)` at the warn condition and at the identity fallback) are provably
    # exempt and deliberately left lazy — `field` comes from `model.field_names`, and #317 forbids
    # a model field name from starting with `_`, so it can never equal an injected name.
    caller_columns = filter(!_is_injected_fill_column, names(df))
    candidates = _case_fold_candidates(field, caller_columns)
    # Case near-miss first: it is the more specific diagnosis and carries a paste-ready fix. A
    # frame with a `Updated_At` column reads as a typo whether or not the field auto-populates,
    # and the fill message below would send the caller looking for a column they already have.
    isempty(candidates) ||
      throw(UnknownFieldError(_bulk_case_mismatch_msg(:update, field, candidates,
        "columns = [..., \"$(candidates[1])\" => \"$(field)\"]")))
    # #379: `haskey(mapping, field)` here means an INJECTED fill — `declared` already consumed
    # every caller-declared mapping, and `inject_fill_column!` is the only other PormG writer of
    # `mapping`. "PormG writer" is the honest form of the claim: a caller who supplies a column
    # literally named `__pormg:fill:<field>` and maps it in `columns=` also lands here, because
    # `declared` reads the fill prefix off the VALUE and cannot tell the two apart. That frame is
    # unreachable in practice — see the note on `_is_injected_fill_column` — and the message it
    # gets is wrong rather than the resolution being unsafe.
    # Before #379 this arm was unreachable for such a field: the fill won the first arm and the
    # call quietly matched on a per-call constant. Raising is the point — say why the value that
    # exists is not usable as a key, instead of reporting the column as merely "not found".
    haskey(mapping, field) &&
      throw(UnknownFieldError(_no_match_source_msg(kind, field, model.fields[field])))
    throw(UnknownFieldError("bulk_update: $(kind) column \e[4m\e[31m$(field)\e[0m not found in the DataFrame (columns: \e[4m\e[32m$(caller_columns)\e[0m) and no columns= mapping targets that field"))
  end

  mapping[field] = resolved
  field in fields_df || push!(fields_df, field)
  field in dynamic_filters || push!(dynamic_filters, field)
  return nothing
end

# ============================================================================
# DEPRECATION SHIM — TEMPORARY (remove once the pre-`match_on` API is retired)
#
# Before `match_on=` existed, `bulk_update(filters=...)` carried BOTH per-row
# match keys and constant predicates. The two helpers below exist only to turn
# that now-removed usage into an actionable migration error. The PERMANENT
# contract is simply: `filters=` entries are constant `field => value` predicates
# (enforced by `_bulk_update_static_only_msg`).
#
# TO REMOVE after the deprecation window:
#   1. delete `_is_legacy_dynamic_filter` and `_bulk_update_migration_msg`;
#   2. delete the marked shim block in `_resolve_bulk_update_keys!`.
# After that, a bare string or dynamic pair in `filters=` falls through to the
# generic static-only error, which is the intended end state.
# ============================================================================
function _is_legacy_dynamic_filter(f, df::DataFrames.DataFrame, model::PormGModel)
  f isa Pair || return true                       # a bare string was always a dynamic key
  return f.second isa AbstractString &&
         !occursin("__", f.first) &&              # not a lookup such as points__@in
         f.first in names(df) &&
         f.second in model.field_names
end

function _bulk_update_migration_msg(f)
  shown = f isa Pair ? "\"$(f.first)\" => \"$(f.second)\"" : "\"$(f)\""
  # #107: match_on= takes bare field names only, so a pair's rewrite is two-part —
  # the mapping moves to columns=, the bare field name goes to match_on=. Advising
  # `match_on = [pair]` here would send the caller straight into the pair error.
  to = f isa Pair ?
    "columns  = [..., $(shown)], match_on = [\"$(f.second)\"]" :
    "match_on = [$(shown)]"
  return """
  bulk_update: `filters=` no longer accepts per-row match keys (DEPRECATED API).
  $(shown) references a DataFrame column, so it is a match key — match keys live in
  `match_on=` (bare model field names), with any `"df_col" => "field"` mapping declared
  in `columns=`. `filters=` is now for constant predicates only.

    Change:  filters  = [$(shown)]
    To:      $(to)

  Use `filters=` only for constant predicates, e.g. filters = ["category_id" => 172100].
  This migration error is temporary and will be removed in a future release.
  """
end
# ============================================================================
# end deprecation shim
# ============================================================================

_bulk_update_static_only_msg(f) =
  "bulk_update: `filters=` entry $(repr(f)) is not a constant predicate. " *
  "Every `filters=` entry must be `field => value`; move row-matching columns to `match_on=`."

# Classify `match_on` into per-row merge keys (dynamic_filters) and `filters` into
# constant predicates (static_filters). Returns (dynamic_filters, static_filters).
#
# - `match_on` entries are bare model-field names (#107); each resolves to a per-row
#   merge key whose source column comes from the `columns=` mapping or, failing that,
#   a DataFrame column with the field's own name.
# - `filters` entries are constant `field => value` predicates.
# - When `match_on` is omitted and no key is produced, the model primary key(s) are used.
# - TEMPORARY: when `match_on` is absent, the old dynamic-in-`filters` usage raises a
#   migration error (see the deprecation-shim banner above).
function _resolve_bulk_update_keys!(df::DataFrames.DataFrame, model::PormGModel,
  mapping::Dict{String, String}, fields_df::Vector{String},
  match_on::Vector{String},
  filters::Vector{Union{String, Pair{String, <:Any}}},
  pks::Vector{String})

  dynamic_filters = String[]
  static_filters = Pair{String, Any}[]
  match_on_given = !isempty(match_on)

  # match_on: per-row merge keys, selected by model field name
  for key in match_on
    _resolve_match_column!(df, model, mapping, fields_df, dynamic_filters, key)
  end

  # filters: permanent contract is constant `field => value` predicates.
  for f in filters
    # ── TEMPORARY deprecation shim (see banner above; delete with the helpers) ──
    # Only meaningful when match_on is absent: turn the old dynamic-in-`filters`
    # usage into an actionable migration error instead of the generic one.
    if !match_on_given && _is_legacy_dynamic_filter(f, df, model)
      throw(QueryBuildError(_bulk_update_migration_msg(f)))
    end
    # ── end shim ───────────────────────────────────────────────────────────────

    f isa Pair || throw(QueryBuildError(_bulk_update_static_only_msg(f)))
    push!(static_filters, f.first => f.second)
  end

  # Fallback: nothing to match on => use the model primary key(s)
  if isempty(dynamic_filters)
    isempty(pks) && throw(QueryBuildError(
      "bulk_update: no match_on= given and model $(model.name) has no primary key to match on"))
    for pk in pks
      _resolve_match_column!(df, model, mapping, fields_df, dynamic_filters, pk; kind="primary key")
    end
  end

  return dynamic_filters, static_filters
end


# ─────────────────────────────────────────────────────────────────────────────
# Parameter-limit-aware chunking (#84)
#
# Each bulk row binds one parameter per mapped field, so a flushed statement carries
# `chunk_rows × ncols` bind parameters. Backends cap that per statement, and the fixed
# `chunk_size = 1000` default ignores column count — a wide table (PG) or the SQLite
# 999-variable build silently overflows with only a raw driver error. We derive the
# *effective* chunk from the column count and the backend's ceiling so the caller never
# has to hand-tune `chunk_size` per table width. `bulk_copy` is exempt (it streams CSV
# over COPY, not bind params).
# ─────────────────────────────────────────────────────────────────────────────

# SQLITE_MAX_VARIABLE_NUMBER default: 999 before 3.32.0, 32766 from 3.32.0 on. Split out as a
# pure function of the packed library version (e.g. 3039000) so the boundary is unit-testable
# without an old SQLite build.
_sqlite_param_limit(version_number::Integer) = version_number >= 3032000 ? 32766 : 999

# Max bind parameters one prepared statement accepts, dispatched on the pool MARKER type so
# core never names a concrete driver (see src/Backend.jl). PostgreSQL: 65535 (the Int16 param
# count in the wire-protocol Bind message). SQLite: probed from the library version.
_backend_parameter_limit(::PormGPostgres) = 65535
_backend_parameter_limit(conn::PormGSQLite) = _sqlite_param_limit(backend_sqlite_version(conn))

# Cap the requested chunk so that `fixed + effective × per_row` never exceeds `limit` (#84).
# `per_row` is the parameters each row binds; `fixed` is the per-statement constant params
# (bulk_update WHERE filters; 0 for insert). If a single row already blows the budget, no
# chunk_size can help, so we fail closed with an actionable error naming the counts and limit.
#
# Note: array-valued fields on SQLite expand to multiple positional params per value
# (parameters.jl `add_parameter!(::PormGSQLiteParam, ::AbstractArray)`), so `per_row = ncols`
# under-counts them. That is a rare edge case outside #84's "one parameter per field" framing
# and is not handled here.
function _effective_chunk_size(requested::Integer, per_row::Integer, fixed::Integer,
                               limit::Integer, op::Symbol, backend::AbstractString)
  per_row <= 0 && return requested            # nothing bound per row → no cap possible or needed
  max_rows = fld(limit - fixed, per_row)
  if max_rows < 1
    throw(QueryBuildError("Error in $op: each row binds $per_row parameter(s)" *
      (fixed > 0 ? " plus $fixed constant filter parameter(s)" : "") *
      ", exceeding the $backend limit of $limit bind parameters per statement — no chunk_size " *
      "can fit a single row. Reduce the columns per $op call (split the column set or the table)."))
  end
  # A non-positive `requested` (degenerate chunk_size) must still be capped to the
  # backend-safe maximum, not collapse to a single un-chunked statement that overflows.
  return requested < 1 ? max_rows : min(requested, max_rows)
end

# Backend label used only in the error text above.
_backend_label(::PormGPostgres) = "PostgreSQL"
_backend_label(::PormGSQLite) = "SQLite"


"""
Inserts multiple rows into the database in bulk from a DataFrame.

  #### Arguments
  - `objct::SQLObjectHandler`: The SQL object handler to use for the operation.
  - `df_o::DataFrames.DataFrame`: The DataFrame containing the data to be inserted.
  - `columns`: Optional. Specifies the columns to insert and their mappings. Can be `nothing`, a `String`, a `Pair{String, String}`, or a `Vector` of these. If `nothing`, all columns from the DataFrame are used.
  - `chunk_size::Integer`: Optional. The number of rows to insert in each batch (default: 1000).
  - `show_query::Symbol`: Optional. Return the generated SQL instead of executing it — `:sql`,
    `:dict`, `:inspection`, or `:params` (see Query Inspection). Defaults to `:execute` (run it).
  - `on_conflict`: Optional (#123). Attaches an `ON CONFLICT` clause so duplicate rows are
    skipped or merged instead of erroring (PostgreSQL and SQLite share the syntax). Accepts:
    - `nothing` (default): no clause — a duplicate key raises, as before.
    - `:nothing`: `ON CONFLICT DO NOTHING` (untargeted — any unique violation skips the row).
    - `(action = :nothing, target = ["field"])`: `ON CONFLICT (col) DO NOTHING`.
    - `(action = :update, target = ["field"], set = ["field"])`:
      `ON CONFLICT (col) DO UPDATE SET col = EXCLUDED.col, …` (upsert).
    `target`/`set` take logical model field names (resolved through `db_column`). `set` fields
    must participate in the INSERT column list. `target` is not required to be declared unique
    in the model — the database is the source of truth for matching constraints. When
    `on_conflict` is set, the duplicate-key → sequence-resync retry is skipped: a conflict is
    expected there, not a sequence desync, so any duplicate-key error that still surfaces
    (a different constraint than the target) propagates.

  The caller's DataFrame is never mutated (and never copied — the pipeline works on a
  zero-copy wrapper), so there is no `copy=` knob to think about.

  #### Examples
  ```julia
  include("models.jl")
  import models as mdl

  # Basic usage
  query = mdl.User |> object
  df = DataFrame(name=["Alice", "Bob"], age=[30, 25])
  bulk_insert(query, df)

  # With column mapping and excluding unwanted variables
  query = mdl.Boook |> object
  df = DataFrame(title=["Book A", "Book B"], author_name=["Alice", "Bob"], year=[2020, 2021], ignore_me=["x", "y"])
  # Map DataFrame column "author_name" to model field "author"
  # Exclude "ignore_me" by not including it in the columns argument
  bulk_insert(query, df, columns=["title", "year", "author_name" => "author"])
  # Only "title", "year", and "author_name" (as field "author") participate in the INSERT;
  # the DataFrame's columns are never renamed or removed — the mapping is internal.
  ```
"""
function bulk_insert(objct::SQLObjectHandler, df_o::DataFrames.DataFrame;
    columns = nothing,
    chunk_size::Integer = 1000,
    show_query::Symbol = :execute,
    on_conflict = nothing
  )
  model = objct.object.model
  ensure_model_transaction_scope(model)

  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  # check if is allowed to insert
  !settings.change_data && throw(_write_not_allowed("bulk_insert", conn_key))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_insert, the DataFrame is empty")
    return nothing
  end

  df = _bulk_working_frame(df_o)   # #132: zero-copy, never mutates df_o (see helper)

  # Prepare columns and DataFrame using centralized helpers
  _columns = _normalize_bulk_columns(columns)
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, _columns, :insert, settings)

  # Normalize/validate on_conflict against the participating insert columns (#123), then render
  # the clause once here — it is identical for every chunk, and its `nothing`-ness is the flag
  # that gates the sequence-resync retry inside _bulk_insert. Purely local (no DB round-trip),
  # so :sql/:dict/:params modes validate and render identically.
  _on_conflict = _normalize_on_conflict(on_conflict, model, fields_df, connection)
  on_conflict_sql = _on_conflict === nothing ? nothing :
    Dialect.on_conflict_clause(_on_conflict.action, _on_conflict.target, _on_conflict.set, connection)

  # Cap the chunk so `effective_chunk × ncols` stays under the backend's bind-parameter limit
  # (#84). Each INSERT row binds one param per field and adds nothing else, so per_row = ncols
  # and there is no fixed per-statement overhead.
  effective_chunk = _effective_chunk_size(chunk_size, length(fields_df), 0,
    _backend_parameter_limit(connection), :bulk_insert, _backend_label(connection))
  effective_chunk < chunk_size &&
    @debug "bulk_insert: capped chunk_size $chunk_size → $effective_chunk to respect the backend bind-parameter limit" model = model.name

  # Build a list of row value strings by applying each model field formatter.
  results = []
  insert_loop = () -> begin
    rows = String[]
    count::Integer = 0
    total::Integer = size(df, 1)
    # Security: Create parameterized query
    parameters = get_parameter(connection)
    # For INSERT, all params go into :select bucket (VALUES clause)
    set_context!(parameters, :select)
    param_placeholders::Vector{String} = String[]
    for (index, row) in enumerate(eachrow(df))
      values = String[]
      try
        # Validation checks consistent with single insert()
        for field in fields_df
          validate_field_data(model, field, row[mapping[field]], "bulk_insert"; allow_primary_key = true)
        end

        param_placeholders = [add_parameter!(parameters, model.fields[field].formatter(row[mapping[field]])) for field in fields_df]
        # param_placeholders = add_parameter!(parameters, values)
      catch e
        _depuration_values_bulk_insert(fields_df, mapping, model, row, index)
        e isa PormGError && rethrow()   # keep the taxonomy type; the depuration log above carries the row context
        throw(InvalidValueError("Error in bulk_insert, row $(index) for model $(model.name) failed validation or formatting: $(e)"))
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == effective_chunk || index == total
        # @pormg_debug
        res = _bulk_insert(model, connection, fields_df, rows, pk_exist, pk_field, settings, show_query, parameters; on_conflict_sql = on_conflict_sql)
        push!(results, res)
        count = 0
        rows = String[]
        parameters = get_parameter(connection)
        set_context!(parameters, :select)
        param_placeholders = String[]
      end
    end
  end

  if show_query !== :execute || transaction_connection_for(settings) !== nothing
    insert_loop()
  else
    run_in_transaction(insert_loop, settings)
  end

  if show_query !== :execute
    return length(results) == 1 ? results[1] : results
  end

  return nothing
  
end
bulk_insert(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_insert(model |> object, df; kwargs...)
bulk_insert(df::DataFrames.DataFrame; kwargs...) = (objct) -> bulk_insert(objct, df; kwargs...)
bulk_insert(objct::SQLObjectHandler; kwargs...) = (df) -> bulk_insert(objct, df; kwargs...)

"""
    _bulk_copy_cell(value)

Render one already-formatted value for the COPY stream.

Only binary payloads need translating: a field formatter hands back a [`PormGBytes`](@ref), which
`CSV.write` would serialize through `show` as the Julia literal `PormGBytes(UInt8[0x01, …])` (#296).
The COPY statement uses `FORMAT CSV`, where backslash is *not* an escape character, so PostgreSQL's
hex input syntax passes through the CSV layer untouched and `byteain` decodes it — the same wire
form the parameterized `add_parameter!` path uses, so `bulk_copy` and `bulk_insert` store identical
bytes.

`bulk_copy` is PostgreSQL-only (guarded at the top of `bulk_copy`), so one dialect's spelling is all
that is needed here.
"""
_bulk_copy_cell(value::PormGBytes) = "\\x" * bytes2hex(value.bytes)
_bulk_copy_cell(value) = value

"""
    _pg_bulk_cast_type(field, conn::PormGPostgres) -> String

The PostgreSQL type name used to cast a `source.<col>` reference in `bulk_update`'s CTE.

Delegates to `Dialect._get_column_type` — the same function that renders the column's actual DDL
type — rather than re-deriving a cast from `field.type` (the SQLite-flavoured spelling). That
independent re-derivation is what caused #296 (`BinaryField.type == "BLOB"` cast to the nonexistent
`::blob`) and its untouched sibling #309 (`ImageField`/`FileField` share `.type == "BLOB"` but
render as `TEXT`, and were still cast to `::blob`). Keying on the rendered type instead of `.type`
means a field's type rendering can never drift out of sync with its `bulk_update` cast again — there
is nothing left in this file to keep in step by hand.

A length/precision modifier (`VARCHAR(250)`, `DECIMAL(10,2)`) is stripped: the bare type is
sufficient for a `source.<col>::<type>` cast and keeps prior behavior for `CharField`/`URLField`/
`SlugField`/`DecimalField` unchanged.
"""
function _pg_bulk_cast_type(field::PormGField, conn::PormGPostgres)::String
  rendered = Dialect._get_column_type(field, conn)
  return lowercase(replace(rendered, r"\(.*\)" => ""))
end

# bulk_copy NULL sentinel (#86) — PostgreSQL's conventional NULL marker. Safe because bulk_copy
# force-quotes every string value (CSV.write quotestrings=true): a genuine string equal to this
# sentinel is written *quoted* and read back as the literal string, while a `missing`/`nothing`
# is written *unquoted* and read as NULL. So "" (quoted) ≠ NULL (unquoted \N). The COPY `NULL '…'`
# clause and CSV.write's `missingstring` must use this same value.
const _BULK_COPY_NULL = "\\N"

"""
    bulk_copy(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; kwargs...)

Performs a high-speed bulk insert operation using PostgreSQL's `COPY` protocol.
This is significantly faster than `bulk_insert` for large datasets.

# Arguments
- `objct::SQLObjectHandler`: The database handler object (e.g., `M.Model`).
- `df_o::DataFrames.DataFrame`: The DataFrame containing the data to be inserted.
- `columns`: (Optional) Specifies which columns to insert. Can be a `String`, a `Pair{String, String}`, or a `Vector` of these.
- `show_query::Bool = false`: If `true`, prints the `COPY` command (note: data stream is not printed).

The caller's DataFrame is never mutated (and never copied — the pipeline works on a
zero-copy wrapper).

The COPY protocol cannot express `ON CONFLICT` — rows that violate a unique constraint make
the whole COPY fail. To skip or merge duplicates, use `bulk_insert(...; on_conflict = ...)` (#123).

# Example
```julia
bulk_copy(M.Driver, df)
```
"""
function bulk_copy(objct::SQLObjectHandler, df_o::DataFrames.DataFrame;
    columns = nothing,
    show_query::Symbol = :execute
  )
  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  !(connection isa PormGPostgres) && throw(BackendCapabilityError("bulk_copy is only supported for PostgreSQL. Use bulk_insert for SQLite."))

  # check if is allowed to insert
  !settings.change_data && throw(_write_not_allowed("bulk_copy", conn_key))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_copy, the DataFrame is empty")
    return nothing
  end

  df = _bulk_working_frame(df_o)   # #132: zero-copy, never mutates df_o (see helper)

  # Prepare columns and DataFrame using centralized helpers
  _columns = _normalize_bulk_columns(columns)
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, _columns, :copy, settings)

  # Security: Quote table name and physical column names (db_column when set, #50).
  # The CSV is positional (HEADER FALSE), so the data order still matches.
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  quoted_fields = [safe_column_identifier(Models.model_column(model, string(field)), connection) for field in fields_df]

  # Construct the COPY command (CSV format for safety). NULL marker disambiguates ""
  # (quoted, an empty string) from missing (unquoted sentinel, NULL) — see _BULK_COPY_NULL (#86).
  sql = "COPY $(safe_table_name) ($(join(quoted_fields, ", "))) FROM STDIN WITH (FORMAT CSV, HEADER FALSE, NULL '$(_BULK_COPY_NULL)')"
  
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, Symbol("bulk_copy"))
  end

  # Process in chunks
  chunk_size = 10000
  total_rows = size(df, 1)

  copy_loop = () -> begin
    for i in 1:chunk_size:total_rows
      end_idx = min(i + chunk_size - 1, total_rows)

      # Build a FORMATTED chunk so COPY stores the SAME values as bulk_insert/create().
      # Each cell is validated and then serialized through the field formatter (as bulk_insert
      # does) — missing/nothing stays missing (every formatter returns missing for it) and is
      # written as the NULL sentinel. Columns are built in fields_df order so they align
      # positionally with the COPY column list (HEADER FALSE). #86
      formatted = DataFrames.DataFrame()
      for field in fields_df
        src = df[i:end_idx, mapping[field]]
        formatted[!, field] = map(eachindex(src)) do offset
          value = src[offset]
          row_index = i + offset - 1
          try
            validate_field_data(model, field, value, "bulk_copy"; allow_primary_key = true)
            # `_bulk_copy_cell` translates a binary payload into PostgreSQL's hex input syntax;
            # every other value passes through unchanged (#296).
            _bulk_copy_cell(model.fields[field].formatter(value))
          catch e
            e isa PormGError && rethrow()   # keep the taxonomy type (bulk_copy logs no per-row depuration; the message below carries the row index only for the wrapped case)
            throw(InvalidValueError("Error in bulk_copy, row $(row_index) for model $(model.name) failed validation or formatting: $(e)"))
          end
        end
      end

      # Force-quote strings and mark missing with the NULL sentinel so an empty string ("")
      # round-trips as "" (quoted) while missing round-trips as NULL (unquoted \N). #86
      io = IOBuffer()
      CSV.write(io, formatted; header=false, quotestrings=true, missingstring=_BULK_COPY_NULL)
      csv_data = String(take!(io))

      fetch_copy(settings, sql, [csv_data])
    end

    # Update sequence if PK was provided
    pk_exist && _update_sequence(model, connection, pk_field, settings)
  end

  try
    has_active_tx = transaction_connection_for(settings) !== nothing
    if has_active_tx
      copy_loop()
    else
      run_in_transaction(copy_loop, settings)
    end
  catch e
    @error "Error in bulk_copy" exception=e sql=sql
    rethrow(e)
  end

  return nothing
  
end
bulk_copy(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_copy(model |> object, df; kwargs...)

function _depuration_values_bulk_insert(fields::Vector{String}, mapping::Dict{String, String}, model::PormGModel, row::DataFrames.DataFrameRow, index::Integer)
  for field in fields
    # Check if field exists in the mapping and row
    col_name = get(mapping, field, field)
    if !(col_name in names(row))
      continue
    end
    try
      model.fields[field].formatter(row[col_name])
    catch e
      # #335: `col_name` is PormG's own private fill column whenever the value was auto-populated,
      # and printing that name would point the caller at a DataFrame column they never wrote. Name
      # the source of the value instead.
      source = _is_injected_fill_column(col_name) ?
        "PormG-supplied default/auto value" : "col: $(col_name)"
      throw(InvalidValueError("Error in bulk processing, the field \e[4m\e[31m$(field)\e[0m ($(source)) in row \e[4m\e[31m$(index)\e[0m has a value that can't be formatted: \e[4m\e[31m$(row[col_name])\e[0m"))
    end
  end  
end

# Normalize/validate `bulk_insert`'s `on_conflict` kwarg into the canonical
# `(action, target, set)` NamedTuple consumed by `_bulk_insert` (#123), where `target`/`set`
# are already-quoted physical column identifiers. Returns `nothing` when no clause is wanted.
# `fields_df` is the participating insert column list from `_prepare_bulk_df!` — `set` must be
# a subset of it, because `EXCLUDED.col` for a non-inserted column silently yields the column
# default instead of a caller value.
function _normalize_on_conflict(on_conflict, model::PormGModel, fields_df::Vector{String},
    connection::Union{PormGPostgres, PormGSQLite})
  on_conflict === nothing && return nothing

  local action::Symbol
  local target::Vector{String}
  local set::Vector{String}

  if on_conflict isa Symbol
    on_conflict === :nothing ||
      throw(QueryBuildError("Error in bulk_insert, on_conflict Symbol form only accepts :nothing " *
        "(got :$(on_conflict)); use (action = :update, target = [...], set = [...]) for upserts"))
    action, target, set = :nothing, String[], String[]
  elseif on_conflict isa NamedTuple
    extra = setdiff(keys(on_conflict), (:action, :target, :set))
    isempty(extra) ||
      throw(QueryBuildError("Error in bulk_insert, on_conflict has unknown key(s) $(join(extra, ", ")); " *
        "accepted keys are action, target and set"))
    haskey(on_conflict, :action) ||
      throw(QueryBuildError("Error in bulk_insert, on_conflict NamedTuple requires an action key " *
        "(:nothing or :update)"))
    action = on_conflict.action
    action in (:nothing, :update) ||
      throw(QueryBuildError("Error in bulk_insert, on_conflict action must be :nothing or :update, " *
        "got :$(action)"))
    target = _on_conflict_column_list(on_conflict, :target)
    set = _on_conflict_column_list(on_conflict, :set)
  else
    throw(QueryBuildError("Error in bulk_insert, on_conflict must be nothing, :nothing or a NamedTuple " *
      "like (action = :nothing, target = [\"field\"]), got $(typeof(on_conflict))"))
  end

  if action === :update
    isempty(target) &&
      throw(QueryBuildError("Error in bulk_insert, on_conflict action :update requires a non-empty target " *
        "column list (the conflicting unique/primary-key columns)"))
    isempty(set) &&
      throw(QueryBuildError("Error in bulk_insert, on_conflict action :update requires a non-empty set " *
        "column list (the columns to overwrite with EXCLUDED values)"))
  elseif on_conflict isa NamedTuple && haskey(on_conflict, :set)
    throw(QueryBuildError("Error in bulk_insert, on_conflict set is only valid with action :update — " *
      "DO NOTHING never writes columns"))
  end

  insert_cols = Set(fields_df)
  for (kind, cols) in ((:target, target), (:set, set))
    length(unique(cols)) == length(cols) ||
      throw(QueryBuildError("Error in bulk_insert, on_conflict $kind has duplicate column entries"))
    for col in cols
      haskey(model.fields, col) ||
        throw(UnknownFieldError("Error in bulk_insert, on_conflict $kind column $(col) is not a field of " *
          "model $(model.name)"))
      kind === :set && !(col in insert_cols) &&
        throw(QueryBuildError("Error in bulk_insert, on_conflict set column $(col) does not participate " *
          "in this INSERT (not in the DataFrame/columns selection), so EXCLUDED.$(col) would be " *
          "the column default — include it in the insert or drop it from set"))
    end
  end
  # `target` columns are deliberately NOT required to be declared unique/primary_key on the
  # model: the database is the source of truth (partial indexes, constraints created outside
  # PormG). A non-matching target surfaces as the backend's own clear error.

  # Explicit `String[...]` comprehensions (not `map`) so the element type is Vector{String}
  # even for an empty target/set, which the typed `on_conflict_clause` signature requires.
  quoted(col) = safe_column_identifier(Models.model_column(model, col), connection)
  return (action = action,
          target = String[quoted(col) for col in target],
          set = String[quoted(col) for col in set])
end

# Fetch `key` from the on_conflict NamedTuple as a Vector{String}, tolerating any
# AbstractString/AbstractVector flavor; a missing key means "no columns".
function _on_conflict_column_list(on_conflict::NamedTuple, key::Symbol)
  haskey(on_conflict, key) || return String[]
  value = on_conflict[key]
  value isa AbstractVector && all(v -> v isa AbstractString, value) ||
    throw(QueryBuildError("Error in bulk_insert, on_conflict $key must be a vector of field-name strings, " *
      "got $(typeof(value))"))
  return String[string(v) for v in value]
end

function _bulk_insert(model::PormGModel, connection::Union{PormGPostgres, PormGSQLite},
  fields::Vector{String}, rows::Vector{String},
  pk_exist::Bool, pk_field::Vector{String}, settings::PormGSettings,
  show_query::Symbol, parameters:: AbstractPormGParam;
  on_conflict_sql::Union{Nothing, String} = nothing)

  # Security: Quote table name and physical column names (db_column when set, #50).
  # VALUES rows are positional and built in `fields` order, so they still align.
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  quoted_fields = [safe_column_identifier(Models.model_column(model, string(field)), connection) for field in fields]

  # Construct the bulk insert SQL. The ON CONFLICT clause (#123) is rendered once by the caller
  # and binds no parameters, so the chunk-size math and the VALUES placeholders are untouched;
  # appending it before the show_query branch means every show mode carries the clause. A
  # non-`nothing` clause also means "on_conflict active" and gates the sequence-resync retry below.
  sql = """
  INSERT INTO $(safe_table_name) ($(join(quoted_fields, ", ")))
  VALUES $(join(rows, ", "))
  """
  if on_conflict_sql !== nothing
    sql *= on_conflict_sql * "\n"
  end

  # Execute the query or just show it
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :insert, parameters=parameters)
  else
    # Execute the query for the given connection type.
    if connection isa PormGPostgres
      # Use a savepoint when inside an active transaction and the model has a PK field.
      # This lets the sequence-sync retry stay on the same TX connection. With on_conflict
      # active there is no retry (see below), so the savepoint is skipped too.
      use_savepoint = !isempty(pk_field) && on_conflict_sql === nothing
      try
        if use_savepoint
          with_savepoint(settings, "pormg_bulk_insert_retry") do
            fetch(settings, sql, parameters)
          end
        else
          fetch(settings, sql, parameters)
        end
      catch e
        # With ON CONFLICT active a surviving duplicate-key error means a DIFFERENT constraint
        # than the clause target conflicted — the values came from the DataFrame, not a stale
        # sequence, so the resync-and-retry below would fail identically. Propagate instead.
        #
        # `sprint(showerror, e)`, not `string(e)` (#268): since the pool wraps driver failures,
        # `e` is normally an `IntegrityError` here, and `string()` on a struct renders the struct
        # literal rather than calling `showerror`. It happens to still contain the driver text
        # because Julia's default `show` recurses into `.cause` — an accident that would evaporate
        # the moment anyone gave the wrapper a `Base.show`, silently disabling the sequence resync.
        # `showerror` is the contract for both wrapped and raw errors. Kept as a message match
        # rather than `e isa IntegrityError`: the sequence-resync retry is specific to a PostgreSQL
        # *duplicate-key* failure, not to constraint violations in general.
        if on_conflict_sql === nothing && occursin("duplicate key value violates unique constraint", sprint(showerror, e))
          if !isempty(pk_field)
            # with_savepoint already rolled back and released the savepoint; the outer
            # transaction is still usable. Fix the sequence and retry without a savepoint.
            _update_sequence(model, connection, pk_field, settings)
            fetch(settings, sql, parameters)
          else
            # #197: keep the original driver exception (it carries the constraint detail and is a
            # real Exception type); the String throw this replaces destroyed both. The diagnostic
            # hint moves to the log.
            @error "bulk_insert: duplicate key and no primary-key sequence to resync — the conflicting values came from the DataFrame" model=model.name exception=e
            rethrow()
          end
        elseif occursin("violates foreign key constraint", sprint(showerror, e))
          @error "bulk_insert: foreign key constraint violated — a referenced row is missing" model=model.name exception=e
          rethrow()
        else
          rethrow()
        end
      end
    elseif connection isa PormGSQLite
      # Use fetch() to properly acquire/release a connection from the pool
      # and pass the parameterized query with correct bucket ordering
      fetch(settings, sql, parameters)
    else
      throw(_unsupported_conn("bulk_insert()", connection))
    end

    pk_exist && _update_sequence(model, connection, pk_field, settings)
  end
end


"""
Performs a bulk update operation on a database table using the provided `DataFrame` and a query object.

# Arguments
- `objct::SQLObjectHandler`: The database handler object.
- `df::DataFrames.DataFrame`: The DataFrame containing the data to be used for the update.
- `columns`: (Optional) The **participating fields and their mappings** — the single place a DataFrame column is mapped to a model field. Each entry is a `String` (DataFrame column == model field) or a `Pair{String, String}` of `"df_col" => "model_field"`. A `Vector` of these is accepted. If `nothing`, columns are auto-detected from the DataFrame. Fields selected by `match_on` are used for matching only and are **not** SET.
- `match_on`: (Optional) The **per-row match keys** that identify which row each DataFrame row updates (the SQL merge condition `Tb.field = source.col`). Bare **model field names** only — the source column is the `columns=` mapping for that field **when you declared one**, otherwise a DataFrame column with the field's own name. A value PormG auto-populates for a field left out of `columns=` (`auto_now`, or a static `default` when `columns=` is omitted — an explicit `columns=` already suppresses static defaults on an update) is not a declared mapping: your same-named column outranks it, and with no caller source at all the call raises `UnknownFieldError` rather than matching every row against one per-call constant. If omitted, the model primary key(s) are used and must be present in the DataFrame, under the same precedence. A match key is **matched, never written** — it stays out of the `SET` clause, so using an `auto_now` field as a key does not refresh that timestamp.
- `filters`: (Optional) **Constant** predicates AND'd onto the `WHERE` clause, applied to every row. Each entry is a `Pair{String, T}` of `"model_field" => value` (e.g. `"category_id" => 172100`, `"points__@in" => [18, 25]`). When `match_on` is provided, every `filters` entry must be such a constant predicate. A per-row match key in `filters` is rejected with a migration error — move it to `match_on`.
- `show_query::Bool`: (Optional) If `true`, prints the generated SQL query. Defaults to `false`.
- `chunk_size::Integer`: (Optional) Number of rows to process per chunk. Defaults to `1000`.

The caller's DataFrame is never mutated (and never copied — the pipeline works on a
zero-copy wrapper), so the operation is safe in asynchronous contexts without a `copy=` knob.

# Example
```julia
# Update by primary key inferred from the DataFrame
bulk_update(objct, df)

# Set name/dof, matching rows on security_id
bulk_update(objct, df, columns=["name", "dof"], match_on=["security_id"])

# Map differing DataFrame names and add a constant scope guard. ALL df→field
# mappings live in columns=; match_on selects merge keys by model field name
# (a field listed in both is used only for matching — it is not SET).
bulk_update(objct, df,
    columns  = ["new_score" => "points",     # df "new_score" → field "points" (SET)
                "record_id" => "id"],        # df "record_id" → field "id" (match key)
    match_on = ["id"],                       # match Tb.id = source.id
    filters  = ["category_id" => 172100])    # constant: only this category
```
"""
function bulk_update(objct::SQLObjectHandler, df::DataFrames.DataFrame;
    columns=nothing,
    match_on=nothing,
    filters=nothing,
    show_query::Symbol=:execute,
    chunk_size::Integer=1000)

  _columns  = _normalize_bulk_columns(columns)
  _match_on = _normalize_bulk_match_on(match_on)  # bare model-field names only (#107)
  _filters  = _normalize_bulk_filters(filters)

  _bulk_update(objct, df, _columns, _match_on, _filters, show_query, chunk_size)

end
bulk_update(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_update(model |> object, df; kwargs...)
bulk_update(df::DataFrames.DataFrame; kwargs...) = (objct) -> bulk_update(objct, df; kwargs...)
bulk_update(objct::SQLObjectHandler; kwargs...) = (df) -> bulk_update(objct, df; kwargs...)

function _bulk_update(objct::SQLObjectHandler, df_o::DataFrames.DataFrame,
  columns::Vector{Union{String, Pair{String, String}}},
  match_on::Vector{String},
  filters::Vector{Union{String, Pair{String, <:Any}}},
  show_query::Symbol,
  chunk_size::Integer=1000)

  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  # check if is allowed to insert
  !settings.change_data && throw(_write_not_allowed("bulk_update", conn_key))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_update, the DataFrame is empty")
    return nothing
  end

  df = _bulk_working_frame(df_o)   # #132: zero-copy, never mutates df_o (see helper)

  # Prepare columns and DataFrame using centralized helpers
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, columns, :update, settings)

  # Resolve row-matching keys (match_on) and static predicates (filters).
  pks = [field for field in model.field_names if model.fields[field].primary_key]
  dinanic_filters, static_filters =
    _resolve_bulk_update_keys!(df, model, mapping, fields_df, match_on, filters, pks)

  _ensure_unique_bulk_update_keys!(df, mapping, dinanic_filters)

  objct.object.filter = [] # clear the filters
  if size(static_filters, 1) > 0
    for filter in static_filters
      objct.filter(filter)
    end
  end
  instruction = build(objct.object, connection=connection)

  # Build a list of row value strings by applying each model field formatter.
  rows = String[]
  # deny_fields = vcat(pks, dinanic_filters, [filter.first for filter in static_filters]) |> unique # colect all keys that are not allowed/need to update
  deny_fields = vcat(dinanic_filters, [filter.first for filter in static_filters]) |> unique # colect all keys that are not allowed/need to update
  # set_columns = join([ "$(field) = source.$(field)::$(model.fields[field].type |> lowercase)" for field in fields_df if !(field in deny_fields) ], ", ")

  # Security: Build safe SET clause with quoted identifiers
  safe_set_parts = []
  for field in fields_df
    if !(field in deny_fields)
      # @pormg_debug
      # SET target uses the physical column (db_column) and is quoted escape-only like any physical
      # name; the source.* reference and the VALUES/CTE source column list stay the FIELD name (#50)
      # and are therefore ALIASES — they name columns of a derived table PormG invents here, not
      # anything that exists in the schema — so they keep the fail-closed `quote_identifier` (#394).
      quoted_field = safe_column_identifier(Models.field_db_column(model.fields[field], field), connection)
      quoted_source_field = quote_identifier(field, connection)
      if connection isa PormGPostgres
        field_type = _pg_bulk_cast_type(model.fields[field], connection)
        push!(safe_set_parts, "$quoted_field = source.$quoted_source_field::$field_type")
      else
        push!(safe_set_parts, "$quoted_field = source.$quoted_source_field")
      end
    end
  end
  safe_set_clause = join(safe_set_parts, ", ")

  # Security: Create parameterized query
  parameters_initial =  deepcopy(instruction.parameters)
  joined_columns = unique(vcat(fields_df, dinanic_filters))

  # Cap the chunk so `fixed + effective_chunk × ncols` stays under the backend's bind-parameter
  # limit (#84). Each row binds one param per set column *and* per match key (joined_columns);
  # the static-filter WHERE params in `parameters_initial` are re-included on every chunk, so
  # they are the per-statement fixed overhead.
  effective_chunk = _effective_chunk_size(chunk_size, length(joined_columns),
    parameters_initial.parameter_count, _backend_parameter_limit(connection), :bulk_update,
    _backend_label(connection))
  effective_chunk < chunk_size &&
    @debug "bulk_update: capped chunk_size $chunk_size → $effective_chunk to respect the backend bind-parameter limit" model = model.name

  results = []
  update_loop = () -> begin
    count::Integer = 0
    total::Integer = size(df, 1)
    rows = String[]
    # For bulk update VALUES, use :select context
    set_context!(instruction.parameters, :select)
    param_placeholders::Vector{String} = String[]
    for (index, row) in enumerate(eachrow(df))
      try
        # Validation checks consistent with single update()
        for field in fields_df
            # Skip fields used as filters or primary keys (they aren't being updated)
            field in deny_fields && continue
            
            # Centralized validation using mapping
            validate_field_data(model, field, row[mapping[field]], "bulk_update"; allow_primary_key = false)
        end

        param_placeholders = [add_parameter!(instruction.parameters, model.fields[field].formatter(row[mapping[field]])) for field in joined_columns]
      catch e
        _depuration_values_bulk_insert(fields_df, mapping, model, row, index)
        e isa PormGError && rethrow()   # keep the taxonomy type; the depuration log above carries the row context
        throw(InvalidValueError("Error in bulk_update, row $(index) for model $(model.name) failed validation or formatting: $(e)"))
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == effective_chunk || index == total
        res = _bulk_update(model, settings, connection, joined_columns, rows, safe_set_clause, dinanic_filters, show_query, instruction)
        push!(results, res)
        count = 0
        rows = String[]
        instruction.parameters = deepcopy(parameters_initial) # reset parameters to initial state
        set_context!(instruction.parameters, :select) # restore context for next chunk
        param_placeholders = String[]
      end
    end
  end

  # Wrap the whole chunk loop in one transaction on BOTH backends so a mid-chunk
  # failure rolls back every already-flushed chunk (#85). This mirrors bulk_insert
  # (`:749`) and bulk_copy (`:873`); a prior `!(connection isa PormGPostgres)` term
  # here routed SQLite to the bare loop, leaving chunks 1…K-1 committed on a chunk-K
  # failure. Skip the wrap only for dry-runs (`show_query !== :execute`) or when an
  # outer transaction is already open (`has_active_tx`, to avoid a nested BEGIN).
  has_active_tx = transaction_connection_for(settings) !== nothing
  if show_query !== :execute || has_active_tx
    update_loop()
  else
    run_in_transaction(update_loop, settings)
  end

  if show_query !== :execute
    return length(results) == 1 ? results[1] : results
  end

  return nothing
  
end

function _bulk_update(model::PormGModel,
  settings::PormGSettings,
  connection::Union{PormGPostgres, PormGSQLite}, 
  fields::Vector{String}, 
  rows::Vector{String}, 
  safe_set_clause::String, 
  dinanic_filters::Vector{String}, 
  show_query::Symbol,
  instruction::Union{SQLInstruction, Nothing})

  @pormg_debug false
  if instruction !== nothing && instruction.join |> length > 0
    throw(QueryBuildError("bulk_update() does not allow joined field paths (\"__\") — restrict filters and update columns to the model's own fields."))
  end

  # Security: Quote table name and field names. `quoted_fields` is the column list of the `source`
  # derived table (PostgreSQL) / CTE (SQLite) below — an alias position, so fail-closed (#394).
  safe_table_name = safe_table_identifier(Models.model_table_name(model), connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields]

  # Security: Build safe WHERE conditions with quoted identifiers
  safe_where_conditions::Vector{String} = []
  for filter in dinanic_filters
    # WHERE target (Tb.) uses the physical column (db_column), escape-only; the source.* reference
    # and the source column list stay the field name (#50) and are ALIASES on a derived table, so
    # they stay fail-closed (#394). All three must agree byte-for-byte with the list emitted below.
    quoted_tb_field = safe_column_identifier(Models.field_db_column(model.fields[filter], filter), connection)
    quoted_source_field = quote_identifier(filter, connection)
    if connection isa PormGPostgres
      field_type = _pg_bulk_cast_type(model.fields[filter], connection)
      push!(safe_where_conditions, "\"Tb\".$quoted_tb_field = source.$quoted_source_field::$field_type")
    else
      push!(safe_where_conditions, "\"Tb\".$quoted_tb_field = source.$quoted_source_field")
    end
  end
  # # Construct the bulk update SQL.
  # _where::Vector{String} = []
  # for filter in dinanic_filters
  #   push!(_where, "Tb.$(filter) = source.$(filter)::$(model.fields[filter].type |> lowercase)")
  # end
  if instruction !== nothing    
    for filter in instruction._where
      push!(safe_where_conditions, filter)
    end
  end

  if connection isa PormGPostgres
    sql = """
    UPDATE $safe_table_name AS "Tb"
    SET $(safe_set_clause)
    FROM (VALUES $(join([join(split(row, ", "), ", ") for row in rows], ","))) AS source ($(join(quoted_fields, ",")))
    WHERE $(join(safe_where_conditions, " AND \n   "))
    """
  else # SQLite
    # SQLite 3.33+ supports UPDATE FROM. We use a CTE to define the source clearly.
    sql = """
    WITH source($(join(quoted_fields, ", "))) AS (
      VALUES $(join(rows, ", "))
    )
    UPDATE $safe_table_name
    SET $(safe_set_clause)
    FROM source
    WHERE $(join(replace.(safe_where_conditions, "\"Tb\"." => "$safe_table_name."), " AND "))
    """
  end

  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :update, parameters=instruction.parameters)
  else 
    # Execute the query for the given connection type.
    fetch(connection, sql, instruction.parameters)
  end  
end
