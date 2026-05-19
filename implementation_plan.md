# PormGRow Wrapper + `.get()` Implementation Plan

## Goal

Improve PormG's ergonomics by introducing two related features:

1. **`PormGRow`** — a model-aware row object returned by `list()`, `first()`, and `get()`. It enables dot-access for fields (`row.id`) and M2M relationship accessors (`driver.sponsors.all()`), bridging the gap between "Dict-returning query builder" and "true ORM."
2. **`list(format)`** — a unified output-format API replacing the old standalone `list()` and `list_json()`. Accepts an optional positional `Symbol` to select the return type: `:row` (default), `:dict`, or `:json`.
3. **`.get()`** — a Django-style single-row fetcher that raises typed exceptions when zero or multiple rows match.

---

## Design Decisions (Resolved)

**`list(format)` is the sole public list API** — the old standalone `list(query)` function, the `query |> list` pipe form, and `list_json()` are all removed from the public API. The only supported form is the fluent `query.list()` / `query.list(:dict)` / `query.list(:json)`. Since PormG has no external published users, the removal is safe.

**`list(format)` uses `Val` dispatch for type stability and typo safety** — each format method has a concrete return type. A catch-all `Val{F}` method converts unknown symbols into a clear `ArgumentError` at runtime rather than a cryptic `MethodError`.

**`first()` and `get()` always return `PormGRow`** — no format argument. Consistent with Django: `get()` and `first()` return a model instance, period. They are for single-record ORM work, not bulk serialization.

**`query |> DataFrame` is unaffected** — confirmed by code inspection. `DataFrames.DataFrame(objct::SQLObjectHandler)` calls `query_list(objct)` directly, which goes straight to `fetch()` without touching `list()`. The two paths are fully isolated.

**`DataFrame(list_result)` requires three `Tables.jl` methods** — `Tables.isrowtable`, `Tables.columnnames`, and `Tables.getcolumn(row, nm::Symbol)`. Do **not** implement `Tables.schema` or `Tables.getcolumn(row, i::Int)`: the integer overload calls `collect(values(dict))` on every cell access, yielding O(R·C²) total allocations, and `Dict` iteration order is not guaranteed consistent across rows, so schema-derived column ordering can silently misalign columns in the resulting `DataFrame`. Schemaless row-table ingestion via `columnnames` + `getcolumn(nm::Symbol)` is both correct and allocation-efficient (see Component 2).

**`.get()` accepts inline filter args** — `M.Driver.objects.get("driverRef" => "hamilton")` is equivalent to `M.Driver.objects.filter("driverRef" => "hamilton").get()`, matching Django's `Driver.objects.get(driverRef="hamilton")` semantics. The only syntactic difference from Django is that PormG uses pairs (`"field" => value`) instead of kwargs (`field=value`), because field names in PormG can contain characters that are not valid Julia identifiers. Both forms work: inline filters or a pre-filtered chain.

**`.get()` is a method on `ObjectHandler`** — consistent with `.first()`.

---

## Proposed Changes

### Component 1: Exception Types

New typed exceptions needed for `.get()`.

#### [NEW] `src/querybuilder/exceptions.jl`

```julia
# Two new exception types, inspired by Django
struct DoesNotExist <: Exception
    model_name::String
    filters::String
end

struct MultipleObjectsReturned <: Exception
    model_name::String
    count::Int
    filters::String
end

Base.showerror(io::IO, e::DoesNotExist) =
    print(io, "$(e.model_name).DoesNotExist: No record found matching filters: $(e.filters)")

Base.showerror(io::IO, e::MultipleObjectsReturned) =
    print(io, "$(e.model_name).MultipleObjectsReturned: Expected 1 record, got $(e.count) for filters: $(e.filters)")
```

Export `DoesNotExist` and `MultipleObjectsReturned` from `PormG.jl`.

---

### Component 2: `PormGRow` Struct

The core of the feature.

#### [MODIFY] `src/querybuilder/types.jl`

Add the `PormGRow` struct **after** `ObjectHandler` is defined (since it references `PormGModel` and `ManyToManyDescriptor`):

```julia
"""
A model-aware row returned by `list()`, `first()`, and `get()`.

Wraps a `Dict{Symbol, Any}` and "remembers" which model it came from,
enabling dot-access to fields and M2M relationship accessors.

## Field access
```julia
row.id        # equivalent to row[:id]
row[:id]      # Dict-compat access still works
```

## M2M access
```julia
driver.sponsors.all() |> DataFrame
sponsor.drivers.add!(1, 2)
```

## Tables.jl / DataFrame compat
```julia
query |> DataFrame  # still works exactly as before
```
"""
struct PormGRow
  _data::Dict{Symbol, Any}
  _model::PormGModel
end

"""Normalize row-facing symbols to the lowercase storage keys used internally."""
function _normalize_row_symbol(sym::Symbol)::Symbol
  s = String(sym)
  if occursin("__", s)
    parts = split(s, "__")
    length(parts) == 2 || throw(ArgumentError("Invalid projected row field '$sym'. Expected exactly one '__'."))
    lhs = Models.format_fild_name(parts[1])
    rhs = lowercase(parts[2])
    return Symbol("$(lhs)__$(rhs)")
  end
  return Symbol(Models.format_fild_name(s))
end

# Dict-compatible index access
Base.getindex(row::PormGRow, key::Symbol) = getfield(row, :_data)[_normalize_row_symbol(key)]
Base.getindex(row::PormGRow, key::String) = getfield(row, :_data)[_normalize_row_symbol(Symbol(key))]
Base.haskey(row::PormGRow, key::Symbol)   = haskey(getfield(row, :_data), _normalize_row_symbol(key))
Base.keys(row::PormGRow)                  = keys(getfield(row, :_data))
Base.values(row::PormGRow)                = values(getfield(row, :_data))
Base.pairs(row::PormGRow)                 = pairs(getfield(row, :_data))
Base.iterate(row::PormGRow, args...)      = iterate(getfield(row, :_data), args...)

# Dot-access to fields and M2M accessors
function Base.getproperty(row::PormGRow, sym::Symbol)
    # Expose internal fields via getfield (avoids infinite recursion)
    sym === :_data  && return getfield(row, :_data)
    sym === :_model && return getfield(row, :_model)

    data  = getfield(row, :_data)
    model = getfield(row, :_model)
  normalized = _normalize_row_symbol(sym)

    # 1. Direct field access
  haskey(data, normalized) && return data[normalized]

    # 2. M2M accessor (forward or reverse via related_name)
  if Models.has_many_to_many_accessor(model, String(normalized))
    descriptor = ManyToManyDescriptor(model, String(normalized), Models.get_many_to_many_relation(model, String(normalized)))
        return descriptor(data)  # Returns ManyToManyManager
    end

    # 3. FK lazy traversal — intentionally refused
  if haskey(model.fields, String(normalized)) && model.fields[String(normalized)] isa Models.sForeignKey
        throw(ArgumentError(
      "$(model.name).$(normalized) is a ForeignKey. Lazy FK traversal is not supported in PormG. " *
      "Use `.on(\"$(normalized)\")` in your query to eagerly join the related table."
        ))
    end

    throw(ArgumentError("$(model.name) row has no field or accessor '$(sym)'"))
end

# Tables.jl interface — enables `DataFrame([row1, row2, ...])`
# Only three methods are needed. Do NOT add Tables.schema or getcolumn(row, i::Int):
#   - getcolumn(i::Int) calls collect(values(dict)) on every cell → O(R·C²) allocs.
#   - Dict iteration order is not guaranteed stable across rows; schema-derived column
#     ordering can silently misalign columns in the resulting DataFrame.
# Schemaless row-table ingestion (columnnames + getcolumn(nm::Symbol)) is correct and fast.
Tables.isrowtable(::Type{Vector{PormGRow}}) = true
Tables.columnnames(row::PormGRow) = collect(keys(getfield(row, :_data)))
Tables.getcolumn(row::PormGRow, nm::Symbol) = getfield(row, :_data)[nm]
```

---

### Component 3: Rewrite `list()` with format dispatch; remove `list_json()`

#### [MODIFY] `src/querybuilder/execution.jl`

Replace the existing `list()` and `list_json()` with three `Val`-dispatched methods plus a catch-all:

```julia
# ── internal helper ──────────────────────────────────────────────────────────
# Shared first stage: execute query, return raw Dict rows with SQLite
# datetime normalisation applied.
# NOTE: if you ever add a new output format below, call _list_raw() and apply
# your transformation to its result — do NOT duplicate the normalisation logic.
function _list_raw(objct::SQLObjectHandler)
  result = query_list(objct)  # raw DB result (Tables.jl source)
  rows = Tables.rowtable(result) |> collect |>
         x -> [Dict(Symbol(k) => v for (k, v) in pairs(row)) for row in x]

  # SQLite returns DATETIME columns as raw strings. Normalise here so all
  # backends return the same Julia types. PostgreSQL does this natively.
  # If you add a new format path, ensure it also goes through this normalisation.
  _, connection, _ = get_settings(objct)
  if connection isa PormGSQLite
    dt_cols = _sqlite_datetime_aliases(objct)
    if !isempty(dt_cols)
      rows = [Dict(k => (k in dt_cols && v isa AbstractString ? _parse_sqlite_datetime(v) : v)
                   for (k, v) in row) for row in rows]
    end
  end
  return rows
end

# ── public format methods (Val dispatch) ─────────────────────────────────────

"""Return model-aware `PormGRow` objects. Default format."""
function list(objct::SQLObjectHandler, ::Val{:row}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  model = objct.object.model
  return [PormGRow(row, model) for row in _list_raw(objct)]
end

"""Return plain `Dict{Symbol,Any}` rows. Use when a framework requires a real Dict."""
function list(objct::SQLObjectHandler, ::Val{:dict}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  return _list_raw(objct)
end

"""Return a JSON string. Skips PormGRow allocation entirely — fastest path for API endpoints."""
function list(objct::SQLObjectHandler, ::Val{:json}; show_query::Symbol = :execute)
  show_query !== :execute && return query_list(objct, show_query=show_query)
  # Build JSON directly from raw dicts — no PormGRow overhead.
  # Symbol keys must be converted to String for valid JSON.
  return JSON.json([Dict(String(k) => v for (k, v) in row) for row in _list_raw(objct)])
end

# Catch-all: unknown format → clear error instead of cryptic MethodError
function list(objct::SQLObjectHandler, ::Val{F}; kwargs...) where F
  throw(ArgumentError("Unknown list format :$F. Expected :row, :dict, or :json."))
end

# Runtime-symbol bridge — converts a caller-supplied Symbol to Val at the call site.
# Without this, any direct function call (not via the ObjectHandler functor) such as
# `list(query, :json)` would produce a MethodError instead of the intended dispatch.
list(objct::SQLObjectHandler, format::Symbol; kwargs...) = list(objct, Val(format); kwargs...)

# Default (no format arg) → :row
list(objct::SQLObjectHandler; kwargs...) = list(objct, Val(:row); kwargs...)
```

#### [MODIFY] `src/querybuilder/object_manager.jl`

Update the `:list` functor binding to accept an optional positional format symbol:

```julia
elseif sym === :list
  # format is a positional Symbol; defaults to :row.
  # Val(format) dispatch gives each branch a concrete return type and
  # routes unknown symbols to the catch-all ArgumentError method.
  return (format::Symbol=:row; show_query::Symbol=:execute) ->
      list(q, Val(format); show_query=show_query)
```

#### [REMOVE] `list_json()` from `src/querybuilder/execution.jl`

Delete the `list_json` function entirely. Its functionality is now `query.list(:json)`.

#### [REMOVE] `:all` alias from `src/querybuilder/object_manager.jl`

Remove `sym === :all` from the `getproperty` dispatch. Two reasons:
1. **Format args won't forward**: the new `list(format)` binding uses a positional `Symbol`, which `kwargs...` does not capture. `query.all(:json)` would silently ignore `:json` or error.
2. **Semantic mismatch with Django**: Django's `.all()` returns a *lazy* queryset clone (still chainable). PormG's `.all()` executes immediately and terminates the chain — a misleading name for anyone coming from Django.

`query.list()` (default `:row`) replaces it entirely.

#### [REMOVE] `list_json` from exports in `src/QueryBuilder.jl` and `src/PormG.jl`

> [!NOTE]
> **Confirmed by code inspection**: `DataFrames.DataFrame(objct::SQLObjectHandler)` calls `query_list(objct) |> DataFrames.DataFrame` directly — it never touches `list()`. The `query |> DataFrame` path has zero overhead from `PormGRow` and requires no changes.

> [!NOTE]
> `first()` calls `list()` internally and returns the first `PormGRow`. No format argument is added to `first()` or `get()` — they always return `PormGRow`, consistent with Django's behaviour for single-record accessors.

---

### Component 4: Add `.get()` Method

> [!NOTE]
> **Django parity**: `M.Driver.objects.get("driverRef" => "hamilton")` maps to Django's `Driver.objects.get(driverRef="hamilton")`. The only syntactic difference is pairs vs kwargs — required because PormG field names can contain characters that are not valid Julia identifiers. Both inline and chained forms are supported.

#### [MODIFY] `src/querybuilder/execution.jl`

Add the `get` function alongside `first`:

```julia
"""
    get(objct::SQLObjectHandler, filters...; show_query=:execute) -> PormGRow

Return exactly one row matching the query filters.

Filters can be passed inline (Django-style) or applied via `.filter()` first —
both forms are equivalent:

```julia
# Inline — matches Django's Driver.objects.get(driverRef="hamilton")
driver = M.Driver.objects.get("driverRef" => "hamilton")

# Chained — same result
driver = M.Driver.objects.filter("driverRef" => "hamilton").get()
```

Raises:
- `DoesNotExist` if no record matches the filters.
- `MultipleObjectsReturned` if more than one record matches.
"""
function get(objct::SQLObjectHandler, filters...; show_query::Symbol = :execute)
  # Apply any inline filters (Django-style: objects.get("field" => value))
  if !isempty(filters)
    up_filter!(objct.object, filters)
  end

  # Fetch limit=2 to detect MultipleObjectsReturned efficiently.
  # limit=1 would silently hide the error case.
  q = deepcopy(objct)
  q = q.limit(2)  # NOTE: must reassign — limit() returns a new query, does not mutate

  # Dry-run / show_query: delegate to query_list so the return type is consistent
  # (a SQL string, not a Vector). Never return a Vector from get().
  if show_query !== :execute
    return query_list(q, show_query=show_query)
  end

  rows = list(q)

  model_name = objct.object.model.name
  # Serialize active filters for the error message so it is actionable in production.
  filter_repr = isempty(objct.object.filter) ? "(none)" :
      join(["$(f.field) $(f.operator) $(f.value)" for f in objct.object.filter], ", ")

  if isempty(rows)
    throw(DoesNotExist(model_name, filter_repr))
  elseif length(rows) > 1
    throw(MultipleObjectsReturned(model_name, length(rows), filter_repr))
  end

  return rows[1]
end
```

#### [MODIFY] `src/querybuilder/object_manager.jl`

Add `:get` to the `Base.getproperty(q::ObjectHandler, sym::Symbol)` dispatch:

```julia
# In CATEGORY 2: Terminal methods
elseif sym === :get
  return (args...; show_query=:execute) -> get(q, args...; show_query=show_query)
```

---

### Component 5: Update Documentation

#### [MODIFY] `docs/src/many_to_many.md`

- Replace aspirational `driver.sponsors.all()` examples with the actual correct syntax using `PormGRow`.
- Add a new section explaining the difference between Model-level access (`.objects`) and instance-level access (via `PormGRow`).
- Show the full flow: **Define Model → Fetch Row → Use Accessor**.

---

### Component 6: Update exports

#### [MODIFY] `src/QueryBuilder.jl`

```julia
export get          # new
# remove: list_json  (deleted from public API)
```

#### [MODIFY] `src/PormG.jl`

```julia
import .QueryBuilder: ..., get  # add get
export ..., get, DoesNotExist, MultipleObjectsReturned  # add all three
# remove: list_json from import and export
```

---

### Component 7: Integration Tests

#### [NEW] `test/integration/test_row_and_get.jl` *(Phase 1 only)*

New test file covering Phase 1 behavior:

1. **`list()` default (`:row`)**: returns `Vector{PormGRow}`; `row.id`, `row[:id]`, `row["id"]` are all equivalent.
2. **`list(:dict)`**: returns `Vector{Dict{Symbol,Any}}`; no `PormGRow` wrapping.
3. **`list(:json)`**: returns a `String`; valid JSON; Symbol keys are stringified.
4. **`list(:typo)`**: throws `ArgumentError` with a message naming the bad symbol.
5. **`PormGRow` M2M access**: `driver.sponsors.all()` returns an `ObjectHandler`.
6. **`PormGRow` FK refusal**: `standings.driverId` throws `ArgumentError` on a `Driver_standings` row because lazy FK traversal is intentionally unsupported.
7. **`.get()` success**: returns exactly one `PormGRow`.
8. **`.get()` DoesNotExist**: throws `DoesNotExist`.
9. **`.get()` MultipleObjectsReturned**: throws `MultipleObjectsReturned`.
10. **`query |> DataFrame` compat**: still works unchanged.
11. **`DataFrame(list_result)` compat**: `DataFrame(query.list())` works via `Tables.jl` interface.
12. **SQLite datetime normalisation**: all three `list` formats return proper `DateTime`/`ZonedDateTime` on the SQLite backend.
13. **Row field-name normalization (read path)**: `row.driverId`, `row.driverid`, `row[:driverId]`, and `row["driverId"]` all resolve to the same stored field.

> **Tests 14–21 are Phase 2 only.** They depend on `Base.setproperty!`, `_dirty::Set{Symbol}`, and `save()` — none of which exist in Phase 1. Running them against a Phase 1 build fails because `PormGRow` is still an immutable `struct` and `save()` is not yet defined. These tests live in `test_row_mutation.jl`, created as part of the Phase 2 deliverable.

#### [NEW] `test/integration/test_row_mutation.jl` *(Phase 2)*

14. **Row field-name normalization (write path)**: assigning through `row.driverId = value` updates the same `_data[:driverid]` entry as `row.driverid = value`.
15. **Unknown plain field assignment**: `row.unknownField = 1` throws `ArgumentError` immediately.
16. **Projected-field FK validation**: `row.badFk__name = "x"` throws `ArgumentError` when `badFk` is not a declared `ForeignKey`.
17. **PK mutation rejection**: assigning to the model PK on a `PormGRow` throws `ArgumentError`.
18. **FK race guard**: mutating both `driverId` and `driverId__forename` before one `save()` throws `ArgumentError`.
19. **Inspection-mode save contract**: `row.save(show_query=:sql)` returns a `Vector` of inspection payloads, does not execute, and leaves `_dirty` unchanged.
20. **Keyless model save rejection**: calling `save()` on a row for a model with no PK (for example `Lap_times`) throws `ArgumentError`.
21. **Multiple-PK model save rejection**: calling `save()` on a row for a dedicated scratch model with two primary-key fields throws `ArgumentError`.

---

## Verification Plan

### Automated Tests

```bash
# Run full integration suite to check for regressions
julia --project=. test/integration/runtests.jl

# Run new test file specifically
julia --project=. -e "include(\"test/integration/test_row_and_get.jl\")"
```

### Manual Verification

1. Confirm `query |> DataFrame` still works for all existing test queries.
2. Confirm `row[:id]` Dict-compat access still works on `PormGRow`.
3. Confirm `query.list(:json)` returns valid JSON in a Genie.jl request handler.
4. Confirm `driver.sponsors.all()` syntax works end-to-end with a real database.
5. Confirm `Model.objects.get()` raises correct exception types.
6. Confirm `query.list(:bad)` produces a readable `ArgumentError`, not a `MethodError`.
7. Confirm mixed-case row writes normalize correctly, e.g. `row.driverId = 1` and `row.driverid = 1` target the same stored field.
8. Confirm `save(show_query=:sql)` leaves `_dirty` unchanged and returns a `Vector` even when only one `UPDATE` is planned.
9. Confirm `save()` rejects both keyless rows and a dedicated two-primary-key scratch model with `ArgumentError`.
10. Update `docs/src/many_to_many.md` examples and visually verify they are accurate.

---

## Phase 2: Instance Mutation (`driver.save()`)

> **Deferred.** Implement only after Phase 1 ships and is stable.

### Goal

Allow a `PormGRow` to be mutated in-place and persisted back to the database, matching Django's pattern:

```julia
# Django: driver.nationality = "Brazilian"; driver.save()
driver = M.Driver.objects.get("driverRef" => "hamilton")
driver.nationality = "Brazilian"
driver.save()
```

### Required changes

#### 1. Switch `PormGRow` to `mutable struct` and add dirty tracking

```julia
mutable struct PormGRow
  _data::Dict{Symbol,Any}
  _model::PormGModel
  _dirty::Set{Symbol}         # tracks which fields have been mutated
end
```

`_dirty` starts empty. Switching from `struct` to `mutable struct` is backward-compatible because the existing `_data` / `_model` layout stays intact.

Why `_dirty` is needed:
- `save()` should update only fields the caller actually changed, not every projected column on the row.
- Cross-table projected fields (`driverid__forename`) must be grouped by FK owner; `_dirty` tells `save()` which projected values are intended writes versus read-only query output.
- Inspection modes (`show_query=:sql`, `:dict`, `:inspection`, etc.) must leave pending changes intact; `_dirty` is the source of truth for what is still unsaved.

#### 2. Implement `Base.setproperty!`

Cross-table projected fields (`driverid__forename`) are mutable. `save()` is
responsible for routing each group to the correct table. The `__` prefix already
encodes the FK path, so no information is lost.

Field-name normalization applies here too: `row.driverId`, `row.driverid`, and
`row.driverId__forename` are normalized to the lowercase storage keys used in
`_data` (`:driverid`, `:driverid__forename`).

PK mutation is blocked — changing a PK through a row instance is never valid.
`Models.get_model_pk_field(model)` already exists in `src/Models.jl` and returns
the PK field name as a `Symbol` (lowercase).

Unknown plain fields are rejected immediately. Projected `__` fields remain allowed,
but only when the FK prefix exists on the model.

```julia
function Base.setproperty!(row::PormGRow, sym::Symbol, value)
  sym in (:_model, :_data, :_dirty) && return setfield!(row, sym, value)
  normalized = _normalize_row_symbol(sym)
  model = getfield(row, :_model)
    # Block PK mutation — the PK identifies this row and must not change in-place.
  normalized === Models.get_model_pk_field(model) &&
    throw(ArgumentError("Cannot mutate primary key field '$normalized' on a PormGRow."))

  if occursin("__", String(normalized))
    fk_name = first(split(String(normalized), "__", limit=2))
    haskey(model.fields, fk_name) && model.fields[fk_name] isa Models.sForeignKey ||
      throw(ArgumentError("Cannot assign to '$sym': '$fk_name' is not a ForeignKey field on $(model.name)."))
  elseif !haskey(model.fields, String(normalized))
    throw(ArgumentError("$(model.name) row has no writable field '$sym'."))
  end

  getfield(row, :_data)[normalized] = value
    push!(getfield(row, :_dirty), normalized)
end
```

#### 3. Add `save()` terminal method

`save()` groups dirty fields by their table owner and issues one `UPDATE` per
affected table, all within a single `run_in_transaction` block.

- Fields with no `__` → own model table
- Fields like `driverid__forename` → split on first `__`: FK column `driverid` →
  `model.fields["driverid"]` returns the `sForeignKey` struct directly →
  `.to` is the related model, `.pk_field` is the PK column name (String, lowercase) →
  issue `UPDATE` on that table

`save()` is supported only for models with exactly one primary key. Models with no
PK, or with more than one PK, remain read-only row objects in Phase 2.

**Key facts verified against the codebase:**
- `run_in_transaction(f, settings)` is the correct transaction API (`ConnectionPool.jl` line 934).
  All `object(...).filter(...).update(...)` calls inside it share the same connection.
  Settings are obtained via `get_settings(object(model))`.
- All keys in `PormGRow._data` are lowercase `Symbol`s. `format_fild_name` lowercases
  every field name at model construction time, and `list()` converts DB column names to
  `Symbol(k)` — PostgreSQL also returns lowercase column names. So rows store `:driverid`,
  not `:driverId`; `_normalize_row_symbol` bridges the user-facing mixed-case form.
- `Models.get_model_pk_field(model)` already exists — no new helper needed.
- `model.fields[String(fk_name)]` returns the `sForeignKey` struct directly — no
  new helper needed. The struct has `.to` (related `PormGModel`) and `.pk_field`
  (lowercase `String` of the PK column in the related table, normalized by
  `format_fild_name` in the FK constructor).
- Blocking PK writes does **not** solve the FK race. The problematic case is mutating
  an FK field itself (for example `driverid`) and also mutating projected fields under
  the same prefix (`driverid__forename`) before one save. Phase 2 should reject that
  combination explicitly.
- Inspection modes must not mutate row state. `save(show_query=:sql)` and other non-
  execute modes return inspection data and leave `_dirty` unchanged.

```julia
function save(row::PormGRow; show_query::Symbol = :execute)
    dirty = getfield(row, :_dirty)
    isempty(dirty) && return row   # no-op if nothing changed

    data  = getfield(row, :_data)
    model = getfield(row, :_model)

    pk_sym = try
      Models.get_model_pk_field(model)
    catch e
      e isa ArgumentError || rethrow(e)
      throw(ArgumentError(
        "save() requires exactly one primary key field; $(model.name) is not supported."
      ))
    end
    pk_sym === nothing && throw(ArgumentError(
      "save() requires exactly one primary key field; $(model.name) is not supported."
    ))

    # Partition dirty fields: own-table vs FK-prefixed (cross-table)
    own_updates = Dict{String,Any}()
    fk_updates  = Dict{Symbol, Dict{String,Any}}()  # fk_sym => {col => value}
    touched_fk_fields = Set{Symbol}()

    for sym in dirty
        normalized = _normalize_row_symbol(sym)
        s = String(normalized)
        idx = findfirst("__", s)
        if idx === nothing
            own_updates[s] = data[normalized]
            if haskey(model.fields, s) && model.fields[s] isa Models.sForeignKey
                push!(touched_fk_fields, normalized)
            end
        else
            fk_sym = Symbol(s[1:first(idx)-1])   # e.g. :driverid
            col    = s[last(idx)+1:end]           # e.g. "forename"
            bucket = get!(fk_updates, fk_sym, Dict{String,Any}())
            bucket[col] = data[normalized]
        end
    end

    conflict = intersect(touched_fk_fields, Set(keys(fk_updates)))
    isempty(conflict) || throw(ArgumentError(
        "Cannot save() a row after mutating both FK field(s) $(collect(conflict)) and projected '__' fields under the same prefix. Save the FK change separately first."
    ))

    # Obtain connection pool — same pattern used by all execution functions
    settings, _, _ = get_settings(object(model))

    if show_query !== :execute
        inspections = Any[]
        if !isempty(own_updates)
            pk_value = data[pk_sym]
            push!(inspections,
                object(model).filter(String(pk_sym) => pk_value).update(own_updates; show_query=show_query)
            )
        end
        for (fk_sym, cols) in fk_updates
            fk_meta  = model.fields[String(fk_sym)]
            fk_value = data[fk_sym]
            push!(inspections,
                object(fk_meta.to)
                    .filter(fk_meta.pk_field => fk_value)
                    .update(cols; show_query=show_query)
            )
        end
        return inspections
    end

    run_in_transaction(settings) do
        if !isempty(own_updates)
            pk_value = data[pk_sym]
            object(model).filter(String(pk_sym) => pk_value).update(own_updates; show_query=show_query)
        end
        for (fk_sym, cols) in fk_updates
            fk_meta  = model.fields[String(fk_sym)]   # sForeignKey struct
            fk_value = data[fk_sym]                   # the stored FK integer
            object(fk_meta.to)
                .filter(fk_meta.pk_field => fk_value)
                .update(cols; show_query=show_query)
        end
    end

    empty!(dirty)
    return row
end
```

Inspection-mode contract:
- `save(show_query=:execute)` executes updates, clears `_dirty`, and returns the row.
- `save(show_query=:sql | :dict | :inspection | :params | :none)` does **not** execute,
  does **not** clear `_dirty`, and returns a vector with one inspection payload per
  planned `UPDATE` statement, even if only one `UPDATE` would be emitted. The return
  shape is intentionally always `Vector` so callers do not need to branch on
  "one table updated" versus "multiple tables updated".

And add `:save` to `Base.getproperty(q::PormGRow, sym::Symbol)`:

```julia
sym === :save && return (; show_query=:execute) -> save(row; show_query=show_query)
```

### Out of scope for Phase 2 (Phase 3 candidates)

- `driver.delete()` — delete the specific row this instance represents
- `driver.refresh_from_db()` — re-read all fields from the DB into the existing instance
- Optimistic concurrency / version fields

---

## Phase 3: Explicitly Not Planned — Lazy FK Traversal

**Decision: lazy FK traversal (`standings.driverId.forename`) will not be implemented.**

Reason: it introduces the N+1 problem by design. Every FK field access in a loop
fires a hidden SELECT. This is a well-known Django footgun that PormG deliberately
avoids.

The supported patterns for cross-table reads are:

```julia
# 1. Explicit join (recommended for bulk reads)
M.Driver_standings.objects
    .cjoin("driverId" => "Driver")
    .values("driverStandingsId", "driverId__forename")
    .list()

# 2. Two explicit queries (recommended for single-row reads)
standings = M.Driver_standings.objects.get("driverStandingsId" => 1)
driver    = M.Driver.objects.get("driverId" => standings.driverId)
forename  = driver.forename
```

Cross-table writes via `__` fields on a fetched `PormGRow` are handled by Phase 2
`save()` without requiring lazy traversal.
