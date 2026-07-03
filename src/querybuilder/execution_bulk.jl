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
        throw(ArgumentError("Invalid column specification: $column"))
      end
    end
  else
    throw(ArgumentError("Invalid columns argument: $columns"))
  end
  return _columns
end

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
        throw(ArgumentError("Invalid filter specification: $f"))
      end
    end
  else
    throw(ArgumentError("Invalid filters argument: $filters"))
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

function _drop_blank_auto_primary_keys!(df::DataFrames.DataFrame,
  model::PormGModel,
  fields_df::Vector{String},
  mapping::Dict{String, String},
  operation::Symbol)

  operation in (:insert, :copy) || return nothing

  for field in copy(fields_df)
    haskey(mapping, field) || continue

    f_meta = model.fields[field]
    _is_auto_generated_bulk_primary_key(f_meta) || continue

    col_name = mapping[field]
    blank_mask = map(_is_blank_bulk_primary_key_value, df[!, col_name])

    if all(blank_mask)
      delete!(mapping, field)
      filter!(mapped_field -> mapped_field != field, fields_df)
    elseif any(blank_mask)
      throw(_argerr("Error in bulk_$(operation), the auto-generated primary key field \e[4m\e[31m$(field)\e[0m has mixed blank and explicit values; either remove the column or provide a value for every row"))
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
are left as-is and will raise an `ArgumentError` when `bulk_insert` is called. To resolve
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
inserted. Wrap the whole pre-allocation + insert workflow in `run_in_transaction` so
no concurrent writer can claim the same range in between.

# Arguments
- `objct`: A `SQLObjectHandler` (typically `M.Model.objects`). Only the underlying model
  is consulted — any filters, ordering, or annotations attached to the handler are
  **ignored**, since pk allocation is a table-level operation independent of any query.
- `df`: The `DataFrame` that will be bulk-inserted.
- `clone::Bool = true`: When `true` (default) the returned DataFrame is a fresh shallow
  copy and the caller's DataFrame is left untouched. Set to `false` to write the new pk
  column in place and avoid the extra allocation.

# Notes
- The returned pk column is a plain `Vector{Int}`. If the input DataFrame had a
  `Vector{Union{Missing,Int}}` pk column, the missing-able element type is dropped after
  allocation.
- The PostgreSQL backend currently assumes the model lives in the default search path
  (typically `public`). Models in other schemas are not supported by this helper — the
  same limitation applies to `_update_sequence`.

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
  !settings.change_data && throw(_argerr("Error in allocate_primary_keys, the connection \e[4m\e[31m$conn_key\e[0m not allowed to insert"))

  df = clone ? Base.copy(df_o) : df_o
  n = DataFrames.nrow(df)
  n == 0 && return df

  # Find the single auto-generated primary key for this model
  pk_fields = [f for f in model.field_names
               if _is_auto_generated_bulk_primary_key(model.fields[f])]

  isempty(pk_fields) && return df

  if length(pk_fields) > 1
    throw(ArgumentError("allocate_primary_keys: model $(model.name) has multiple auto-generated primary keys ($(join(pk_fields, ", "))); only models with a single auto-generated pk are supported"))
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
              "The DataFrame is returned unchanged. Those blank rows will raise an ArgumentError at bulk_insert time. " *
              "Options: (1) supply a pk value for every row, (2) remove the column so all ids are allocated automatically, " *
              "or (3) pre-fill the blank rows before calling allocate_primary_keys."
      end
      return df
    end
  end

  ids = if connection isa PormGPostgres
    _allocate_pg_ids(model, connection, pk_field, n)
  elseif connection isa PormGSQLite
    _allocate_sqlite_ids(model, connection, pk_field, n, settings)
  else
    throw(ArgumentError("allocate_primary_keys: unsupported connection type $(typeof(connection))"))
  end

  df[!, pk_field] = ids
  return df
end

allocate_primary_keys(model::PormGModel, df::DataFrames.DataFrame; kwargs...) =
  allocate_primary_keys(model |> object, df; kwargs...)

function _single_auto_generated_primary_key(model::PormGModel)
  pk_fields = [field for field in model.field_names if _is_auto_generated_bulk_primary_key(model.fields[field])]
  isempty(pk_fields) && return nothing

  if length(pk_fields) > 1
    throw(ArgumentError("allocate_primary_keys: model $(model.name) has multiple auto-generated primary keys ($(join(pk_fields, ", "))); only models with a single auto-generated pk are supported"))
  end

  return pk_fields[1]
end

# Reserves n ids from the PostgreSQL sequence associated with pk_field.
# Uses nextval() inside generate_series so the allocation is a single atomic roundtrip.
function _allocate_pg_ids(model::PormGModel, connection::PormGPostgres, pk_field::String, n::Int)
  safe_table = string(model.name |> lowercase)
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
# row does not yet exist (empty AUTOINCREMENT table). Caller should be inside
# run_in_transaction to avoid concurrent races.
function _allocate_sqlite_ids(model::PormGModel, connection::PormGSQLite, pk_field::String, n::Int, settings::SQLConn)
  safe_table = string(model.name |> lowercase)
  safe_table_name = safe_table_identifier(safe_table, connection)
  safe_table_literal = replace(safe_table, "'" => "''")
  safe_field = quote_identifier(Models.model_column(model, pk_field), connection)  # db_column (#50)
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

  function resolve_fill_value(f_meta, operation::Symbol, settings)
    if f_meta.default !== nothing
      return true, f_meta.default
    elseif f_meta.type == "TIMESTAMPTZ"
      if operation in [:insert, :copy] && (f_meta.auto_now_add || f_meta.auto_now)
        value = settings === nothing ? now(TimeZone("UTC")) : f_meta.formater(now(TimeZone(settings.time_zone)))
        return true, value
      elseif operation == :update && f_meta.auto_now
        value = settings === nothing ? now(TimeZone("UTC")) : f_meta.formater(now(TimeZone(settings.time_zone)))
        return true, value
      end
    elseif f_meta.type == "DATE"
      if operation in [:insert, :copy] && (f_meta.auto_now_add || f_meta.auto_now)
        # NOTE: `today()` is returned as a bare `Date` object without calling
        # `f_meta.formater` here. The DATE formatter (`format_date_sql`) only
        # converts Date → String and does not transform the value (no time_zone
        # argument), unlike the TIMESTAMPTZ formatter which returns a ZonedDateTime.
        # Sanitization handles both `Date` objects and date strings correctly, so
        # bypassing the formatter is intentional. If `DateField` ever gains a
        # custom value-transforming formatter, this path must be updated to call it.
        return true, today()
      elseif operation == :update && f_meta.auto_now
        return true, today()
      end
    elseif f_meta.type == "UUID" && f_meta.auto_add
      if operation in [:insert, :copy]
        return true, UUIDs.uuid4()
      end
    end

    return false, nothing
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
          mapping[column.second] = column.first
          push!(fields_df, column.second)
        else
          # Offer the case hint when the only near-miss differs solely in case,
          # consistent with the string/auto-detect/match_on paths above.
          candidates = _case_fold_candidates(column.first, names(df))
          isempty(candidates) ||
            throw(_argerr(_bulk_case_mismatch_msg(operation, column.first, candidates,
              "\"$(candidates[1])\" => \"$(column.second)\"")))
          throw(_argerr("Error in bulk_$(operation), the column \e[4m\e[31m$(column.first)\e[0m mapped to field \e[4m\e[31m$(column.second)\e[0m is not in the DataFrame; available columns: \e[4m\e[32m$(names(df))\e[0m"))
        end
      else
        # String column: match the DataFrame column name EXACTLY (case-sensitive).
        if column in names(df)
          mapping[column] = column
          push!(fields_df, column)
        else
          # No exact match. If a column differs only in case, fail loudly instead of
          # silently case-folding (see the case-sensitive matching contract above).
          candidates = _case_fold_candidates(column, names(df))
          isempty(candidates) ||
            throw(_argerr(_bulk_case_mismatch_msg(operation, column, candidates,
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
          throw(_argerr(_bulk_case_mismatch_msg(operation, col_name, candidates,
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
      if haskey(mapping, field)
        # Field exists in mapping (and DF). Check if we should fill nulls with defaults.
        col_name = mapping[field]
        should_apply_default, fill_value = resolve_fill_value(f_meta, operation, settings)

        if should_apply_default
          # Mutate the column to replace missing/nothing with default
          # We only do this if it's already there or if we really need it
          df[!, col_name] = map(x -> x |> ismissing || x |> isnothing ? fill_value : x, df[!, col_name])
        end
      else
        # Field is in fields_df (requested) but not in mapping (missing in DF)
        # Check if we can auto-populate it
        should_auto_populate, fill_value = resolve_fill_value(f_meta, operation, settings)

        if should_auto_populate
          is_static_default = f_meta.default !== nothing
          is_explicit_update = operation == :update && !isempty(normalized_columns)
          if !(is_explicit_update && is_static_default)
            # Add new column to DF and update mapping
            # Use first mapped column as a length reference
            ref_col = isempty(mapping) ? 1 : mapping[collect(keys(mapping))[1]]
            df[!, field] = map(x -> fill_value, df[!, ref_col])
            mapping[field] = field
          end
        elseif f_meta.primary_key
          # It's a PK, we'll collect it later
        elseif !f_meta.null && operation in [:insert, :copy]
          throw(_argerr("Error in bulk_$operation, the field \e[4m\e[31m$(field)\e[0m does not allow null and has no default value"))
        end
      end

      if f_meta.primary_key
        pk_exist = true
        push!(pk_field, field)
      end
    else
      # Field not in fields_df. See if we should auto-populate it anyway (e.g. updated_at)
      should_auto_populate, fill_value = resolve_fill_value(f_meta, operation, settings)

      if should_auto_populate
        # For an explicit-scope UPDATE (columns= was provided), a static `default`
        # must NOT leak into fields_df.  Temporal auto_now/auto_now_add injections
        # are always allowed because they are an intentional ORM side-effect.
        # For INSERT/COPY, or UPDATE with columns=nothing, behavior is unchanged.
        is_static_default = f_meta.default !== nothing
        is_explicit_update = operation == :update && !isempty(normalized_columns)
        if !(is_explicit_update && is_static_default)
          ref_col = isempty(mapping) ? 1 : mapping[collect(keys(mapping))[1]]
          df[!, field] = map(x -> fill_value, df[!, ref_col])
          mapping[field] = field
          push!(fields_df, field)
        end
      elseif f_meta.primary_key
        push!(pk_field, field)
      end
    end
  end
  
  # Final sanity check for fields_df existence in model
  for field in fields_df
    in(field, fields) || throw(_argerr("Error in bulk_$operation, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(model.name)\e[0m"))
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
      throw(ArgumentError("Error in bulk_update, duplicate dynamic filter key values detected for filters [$filters_text] at rows $(seen_keys[key]) and $(index): $(collect(key))"))
    end
    seen_keys[key] = index
  end

  return nothing
end

# Map one match key into mapping / fields_df / dynamic_filters. Unlike the legacy
# `filters=` path, a missing DataFrame column is a hard error rather than a silent
# fall-through to a static predicate.
#
# `allow_reuse` lets a bare key (and the PK fallback) fall back to a mapping already
# established by `columns=` when `df_col` is not a DataFrame column on its own. It MUST
# stay `false` for an explicit `"df_col" => "field"` pair, otherwise a typoed source
# column would be silently swallowed by the existing `columns=` mapping instead of
# raising the documented hard error.
function _resolve_match_column!(df::DataFrames.DataFrame, model::PormGModel,
  mapping::Dict{String, String}, fields_df::Vector{String},
  dynamic_filters::Vector{String}, field::String, df_col::String;
  kind::String="match_on", allow_reuse::Bool=true)

  field in model.field_names ||
    throw(_argerr("bulk_update: $(kind) field \e[4m\e[31m$(field)\e[0m is not a field of model $(model.name)"))

  resolved = if df_col in names(df)
    df_col                                # exact (case-sensitive) match wins
  elseif allow_reuse && haskey(mapping, field)
    mapping[field]                        # bare key / PK fallback: reuse the columns= mapping
  else
    # No exact match and nothing to reuse. A column differing only in case is a loud
    # error, not a silent fold (see the case-sensitive matching contract above).
    candidates = _case_fold_candidates(df_col, names(df))
    isempty(candidates) ||
      throw(_argerr(_bulk_case_mismatch_msg(:update, df_col, candidates,
        "\"$(candidates[1])\" => \"$(field)\"")))
    throw(_argerr("bulk_update: $(kind) column \e[4m\e[31m$(df_col)\e[0m not found in the DataFrame (columns: $(names(df)))"))
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
  return """
  bulk_update: `filters=` no longer accepts per-row match keys (DEPRECATED API).
  $(shown) references a DataFrame column, so it is a match key — move it to `match_on=`.
  `filters=` is now for constant predicates only.

    Change:  filters  = [$(shown)]
    To:      match_on = [$(shown)]

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
# - `match_on` resolves to per-row merge keys; explicit pairs must exist in the df.
# - `filters` entries are constant `field => value` predicates.
# - When `match_on` is omitted and no key is produced, the model primary key(s) are used.
# - TEMPORARY: when `match_on` is absent, the old dynamic-in-`filters` usage raises a
#   migration error (see the deprecation-shim banner above).
function _resolve_bulk_update_keys!(df::DataFrames.DataFrame, model::PormGModel,
  mapping::Dict{String, String}, fields_df::Vector{String},
  match_on::Vector{Union{String, Pair{String, String}}},
  filters::Vector{Union{String, Pair{String, <:Any}}},
  pks::Vector{String})

  dynamic_filters = String[]
  static_filters = Pair{String, Any}[]
  match_on_given = !isempty(match_on)

  # match_on: always per-row merge keys ("df_col" => "model_field")
  for key in match_on
    if key isa Pair
      # Explicit column: it must exist in the DataFrame — no reuse of a columns= mapping.
      _resolve_match_column!(df, model, mapping, fields_df, dynamic_filters, key.second, key.first; allow_reuse=false)
    else
      # Bare key: match on this field using whatever column already maps to it.
      _resolve_match_column!(df, model, mapping, fields_df, dynamic_filters, key, key; allow_reuse=true)
    end
  end

  # filters: permanent contract is constant `field => value` predicates.
  for f in filters
    # ── TEMPORARY deprecation shim (see banner above; delete with the helpers) ──
    # Only meaningful when match_on is absent: turn the old dynamic-in-`filters`
    # usage into an actionable migration error instead of the generic one.
    if !match_on_given && _is_legacy_dynamic_filter(f, df, model)
      throw(ArgumentError(_bulk_update_migration_msg(f)))
    end
    # ── end shim ───────────────────────────────────────────────────────────────

    f isa Pair || throw(ArgumentError(_bulk_update_static_only_msg(f)))
    push!(static_filters, f.first => f.second)
  end

  # Fallback: nothing to match on => use the model primary key(s)
  if isempty(dynamic_filters)
    isempty(pks) && throw(ArgumentError(
      "bulk_update: no match_on= given and model $(model.name) has no primary key to match on"))
    for pk in pks
      _resolve_match_column!(df, model, mapping, fields_df, dynamic_filters, pk, pk; kind="primary key")
    end
  end

  return dynamic_filters, static_filters
end


"""
Inserts multiple rows into the database in bulk from a DataFrame.

  #### Arguments
  - `objct::SQLObjectHandler`: The SQL object handler to use for the operation.
  - `df_o::DataFrames.DataFrame`: The DataFrame containing the data to be inserted.
  - `columns`: Optional. Specifies the columns to insert and their mappings. Can be `nothing`, a `String`, a `Pair{String, String}`, or a `Vector` of these. If `nothing`, all columns from the DataFrame are used.
  - `chunk_size::Integer`: Optional. The number of rows to insert in each batch (default: 1000).
  - `show_query::Bool`: Optional. If true, prints the generated SQL query (default: false).
  - `copy::Bool`: Optional. If true, creates a copy of the DataFrame before processing (default: false).

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
  # the df will be modified to only include the columns "title", "year", and "author_name" (renamed to "author").

  # If you want to copy the DataFrame before processing, set `copy=true`:
  bulk_insert(query, df, columns=["title", "year", "author_name" => "author"], copy=true)
    
  ```
"""
function bulk_insert(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; 
    columns = nothing, 
    chunk_size::Integer = 1000,
    show_query::Symbol = :execute,
    copy::Bool = true
  ) 
  model = objct.object.model
  ensure_model_transaction_scope(model)

  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  django_prefix = settings.django_prefix === nothing ? false : true

  

  # check if is allowed to insert
  !settings.change_data && throw(_argerr("Error in bulk_insert, the connection \e[4m\e[31m$conn_key\e[0m not allowed to insert"))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_insert, the DataFrame is empty")
    return nothing
  end

  df = copy ? deepcopy(df_o) : df_o 

  # Prepare columns and DataFrame using centralized helpers
  _columns = _normalize_bulk_columns(columns)
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, _columns, :insert, settings)

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

        param_placeholders = [add_parameter!(parameters, model.fields[field].formater(row[mapping[field]])) for field in fields_df]
        # param_placeholders = add_parameter!(parameters, values)
      catch e
        _depuration_values_bulk_insert(fields_df, mapping, model, row, index, django_prefix)
        throw(ErrorException("Error in bulk_insert, row $(index) for model $(model.name) failed validation or formatting: $(e)"))
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == chunk_size || index == total
        # @pormg_debug
        res = _bulk_insert(model, connection, fields_df, rows, pk_exist, pk_field, settings, django_prefix, show_query, parameters)
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
- `copy::Bool = true`: If `true`, creates a copy of the DataFrame before processing.
- `show_query::Bool = false`: If `true`, prints the `COPY` command (note: data stream is not printed).

# Example
```julia
bulk_copy(M.Driver, df)
```
"""
function bulk_copy(objct::SQLObjectHandler, df_o::DataFrames.DataFrame; 
    columns = nothing, 
    show_query::Symbol = :execute,
    copy::Bool = true
  ) 
  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  !(connection isa PormGPostgres) && throw(ArgumentError("bulk_copy is only supported for PostgreSQL. Use bulk_insert for SQLite."))

  # check if is allowed to insert
  !settings.change_data && throw(_argerr("Error in bulk_copy, the connection \e[4m\e[31m$conn_key\e[0m not allowed to insert"))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_copy, the DataFrame is empty")
    return nothing
  end

  df = copy ? deepcopy(df_o) : df_o 

  # Prepare columns and DataFrame using centralized helpers
  _columns = _normalize_bulk_columns(columns)
  mapping, fields_df, pk_exist, pk_field = _prepare_bulk_df!(df, model, _columns, :copy, settings)

  # Security: Quote table name and physical column names (db_column when set, #50).
  # The CSV is positional (HEADER FALSE), so the data order still matches.
  safe_table_name = safe_table_identifier(string(model.name), connection)
  quoted_fields = [quote_identifier(Models.model_column(model, string(field)), connection) for field in fields_df]

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
            model.fields[field].formater(value)
          catch e
            throw(ErrorException("Error in bulk_copy, row $(row_index) for model $(model.name) failed validation or formatting: $(e)"))
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

function _depuration_values_bulk_insert(fields::Vector{String}, mapping::Dict{String, String}, model::PormGModel, row::DataFrames.DataFrameRow, index::Integer, django_prefix::Bool)
  for field in fields
    # Check if field exists in the mapping and row
    col_name = get(mapping, field, field)
    if !(col_name in names(row))
      continue
    end
    try
      model.fields[field].formater(row[col_name])
    catch e
      throw(_argerr("Error in bulk processing, the field \e[4m\e[31m$(field)\e[0m (col: $(col_name)) in row \e[4m\e[31m$(index)\e[0m has a value that can't be formatted: \e[4m\e[31m$(row[col_name])\e[0m"))
    end
  end  
end

function _bulk_insert(model::PormGModel, connection::Union{PormGPostgres, PormGSQLite}, 
  fields::Vector{String}, rows::Vector{String}, 
  pk_exist::Bool, pk_field::Vector{String}, settings::SQLConn, 
  django_prefix::Bool, show_query::Symbol, parameters:: AbstractPormGParam)

  # Security: Quote table name and physical column names (db_column when set, #50).
  # VALUES rows are positional and built in `fields` order, so they still align.
  safe_table_name = safe_table_identifier(string(model.name), connection)
  quoted_fields = [quote_identifier(Models.model_column(model, string(field)), connection) for field in fields]

  # Construct the bulk insert SQL.
  sql = """
  INSERT INTO $(safe_table_name) ($(join(quoted_fields, ", ")))
  VALUES $(join(rows, ", "))
  """

  # Execute the query or just show it
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :insert, parameters=parameters)
  else
    # Execute the query for the given connection type.
    if connection isa PormGPostgres
      # Use a savepoint when inside an active transaction and the model has a PK field.
      # This lets the sequence-sync retry stay on the same TX connection.
      use_savepoint = !isempty(pk_field)
      try
        if use_savepoint
          with_savepoint(settings, "pormg_bulk_insert_retry") do
            fetch(settings, sql, parameters)
          end
        else
          fetch(settings, sql, parameters)
        end
      catch e
        if occursin("duplicate key value violates unique constraint", e |> string)
          if !isempty(pk_field)
            # with_savepoint already rolled back and released the savepoint; the outer
            # transaction is still usable. Fix the sequence and retry without a savepoint.
            _update_sequence(model, connection, pk_field, settings)
            fetch(settings, sql, parameters)
          else
            throw("Error in bulk_insert, the row has a duplicate key value and no primary key sequence can be synchronized")
          end
        elseif occursin("violates foreign key constraint", e |> string)
          throw("Error in bulk_insert, the row has a foreign key constraint")
        else
          throw(e)
        end
      end
    elseif connection isa PormGSQLite
      # Use fetch() to properly acquire/release a connection from the pool
      # and pass the parameterized query with correct bucket ordering
      fetch(settings, sql, parameters)
    else
      throw("Unsupported connection type")
    end

    pk_exist && _update_sequence(model, connection, pk_field, settings)
  end
end


"""
Performs a bulk update operation on a database table using the provided `DataFrame` and a query object.

# Arguments
- `objct::SQLObjectHandler`: The database handler object.
- `df::DataFrames.DataFrame`: The DataFrame containing the data to be used for the update.
- `columns`: (Optional) Which columns to **SET**. Each entry is a `String` (DataFrame column == model field) or a `Pair{String, String}` of `"df_col" => "model_field"`. A `Vector` of these is accepted. If `nothing`, columns are auto-detected from the DataFrame.
- `match_on`: (Optional) The **per-row match keys** that identify which row each DataFrame row updates (the SQL merge condition `Tb.field = source.df_col`). Same grammar as `columns`: a `String` or `"df_col" => "model_field"`. If omitted, the model primary key(s) are used and must be present in the DataFrame.
- `filters`: (Optional) **Constant** predicates AND'd onto the `WHERE` clause, applied to every row. Each entry is a `Pair{String, T}` of `"model_field" => value` (e.g. `"category_id" => 172100`, `"points__@in" => [18, 25]`). When `match_on` is provided, every `filters` entry must be such a constant predicate. A per-row match key in `filters` is rejected with a migration error — move it to `match_on`.
- `show_query::Bool`: (Optional) If `true`, prints the generated SQL query. Defaults to `false`.
- `chunk_size::Integer`: (Optional) Number of rows to process per chunk. Defaults to `1000`.
- `copy::Bool`: (Optional) If `true`, creates a copy of the DataFrame before processing. Defaults to `true`. Set to `false` to modify the original DataFrame and improve performance, but this may lead to unintended side effects when the operation is performed in asynchronous contexts.

# Example
```julia
# Update by primary key inferred from the DataFrame
bulk_update(objct, df)

# Set name/dof, matching rows on security_id
bulk_update(objct, df, columns=["name", "dof"], match_on=["security_id"])

# Map differing DataFrame names and add a constant scope guard
bulk_update(objct, df,
    columns  = ["new_score" => "points"],   # df "new_score" → field "points"
    match_on = ["record_id" => "id"],        # match Tb.id = source.record_id
    filters  = ["category_id" => 172100])    # constant: only this category
```
"""
function bulk_update(objct::SQLObjectHandler, df::DataFrames.DataFrame;
    columns=nothing,
    match_on=nothing,
    filters=nothing,
    show_query::Symbol=:execute,
    chunk_size::Integer=1000,
    copy::Bool=true)

  _columns  = _normalize_bulk_columns(columns)
  _match_on = _normalize_bulk_columns(match_on)   # same grammar as columns: "df_col" => "model_field"
  _filters  = _normalize_bulk_filters(filters)

  _bulk_update(objct, df, _columns, _match_on, _filters, show_query, chunk_size, copy)

end
bulk_update(model::PormGModel, df::DataFrames.DataFrame; kwargs...) = bulk_update(model |> object, df; kwargs...)
bulk_update(df::DataFrames.DataFrame; kwargs...) = (objct) -> bulk_update(objct, df; kwargs...)
bulk_update(objct::SQLObjectHandler; kwargs...) = (df) -> bulk_update(objct, df; kwargs...)

function _bulk_update(objct::SQLObjectHandler, df_o::DataFrames.DataFrame,
  columns::Vector{Union{String, Pair{String, String}}},
  match_on::Vector{Union{String, Pair{String, String}}},
  filters::Vector{Union{String, Pair{String, <:Any}}},
  show_query::Symbol,
  chunk_size::Integer=1000,
  copy::Bool=true)

  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct)

  # check if is allowed to insert
  !settings.change_data && throw(_argerr("Error in bulk_update, the connection \e[4m\e[31m$conn_key\e[0m not allowed to update"))

  # If no rows then nothing to do
  if size(df_o, 1) == 0
    @warn("Warning in bulk_update, the DataFrame is empty")
    return nothing
  end

  df = copy ? deepcopy(df_o) : df_o 

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
      # SET target uses the physical column (db_column); the source.* reference and the
      # VALUES/CTE source column list stay the field name (#50).
      quoted_field = quote_identifier(Models.field_db_column(model.fields[field], field), connection)
      quoted_source_field = quote_identifier(field, connection)
      field_type = model.fields[field].type |> lowercase
      if connection isa PormGPostgres
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

        param_placeholders = [add_parameter!(instruction.parameters, model.fields[field].formater(row[mapping[field]])) for field in joined_columns]
      catch e
        _depuration_values_bulk_insert(fields_df, mapping, model, row, index, settings.django_prefix !== nothing)
        throw(ErrorException("Error in bulk_update, row $(index) for model $(model.name) failed validation or formatting: $(e)"))
      end
      push!(rows, "($(join(param_placeholders, ", ")))")
      count += 1
      if count == chunk_size || index == total      
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

  has_active_tx = transaction_connection_for(settings) !== nothing
  if show_query !== :execute || !(connection isa PormGPostgres) || has_active_tx
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
  settings::SQLConn,
  connection::Union{PormGPostgres, PormGSQLite}, 
  fields::Vector{String}, 
  rows::Vector{String}, 
  safe_set_clause::String, 
  dinanic_filters::Vector{String}, 
  show_query::Symbol,
  instruction::Union{SQLInstruction, Nothing})

  @pormg_debug false
  if instruction !== nothing && instruction.join |> length > 0
    throw("Error in bulk_update, the join is not allowed in bulk_update")
  end

  # Security: Quote table name and field names
  safe_table_name = safe_table_identifier(model.name, connection)
  quoted_fields = [quote_identifier(field, connection) for field in fields]

  # Security: Build safe WHERE conditions with quoted identifiers
  safe_where_conditions::Vector{String} = []
  for filter in dinanic_filters
    # WHERE target (Tb.) uses the physical column (db_column); the source.* reference
    # and the source column list stay the field name (#50).
    quoted_tb_field = quote_identifier(Models.field_db_column(model.fields[filter], filter), connection)
    quoted_source_field = quote_identifier(filter, connection)
    field_type = model.fields[filter].type |> lowercase
    if connection isa PormGPostgres
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