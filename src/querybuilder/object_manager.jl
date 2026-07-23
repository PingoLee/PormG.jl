
# ---
# Build the object
#

# Why Vector{String}
function _up_values(str::String)
  check = String.(split(str, "__@"))
  if size(check, 1) == 1
    return SQLField(str, str)
  elseif haskey(PormGsuffix, check[end])
    throw(_argerr("Invalid values() field \"$(str)\": operator suffixes (__@lte, __@gte, __@contains, …) are not allowed in a projection — use them in filter() instead."))
  else
    @pormg_debug false
    return SQLField(_check_function(check), join(check, "__"))
  end
end

function up_values!(q::SQLObject, values)
  # every call of values, reset the values
  q.values = []
  for v in values
    isa(v, Symbol) && (v = String(v))
    if isa(v, SQLTypeText) || isa(v, SQLTypeField)
      push!(q.values, _check_function(v))
    elseif isa(v, SQLTypeFunction)
      push!(q.values, SQLField(_check_function(v), v._as))
    elseif isa(v, Pair)
      if !isa(v.first, String)
        throw(_argerr("Invalid values() pair key: $(v.first) (::$(typeof(v.first))) — use a String alias as the key in \"alias\" => expr."))
      end
      if isa(v.second, Union{SQLTypeFunction,SQLTypeF})
        try
          push!(q.values, SQLField(_check_function(v.second), v.first))
        catch e
          # #92: this used to swallow the error and continue — the column silently vanished from
          # the result while values() returned normally. Log the failing alias for context (the
          # underlying error may not name it), then propagate: an invalid projection must surface
          # at values() time, consistent with the fail-loud branches below.
          @error "Invalid values pair" alias = v.first exception = (e, catch_backtrace())
          rethrow()
        end
      elseif isa(v.second, Union{SubqueryObject,ExistsObject})
        # #92: project a scalar subquery / EXISTS as an aliased column, e.g.
        # "total" => Subquery(inner)  or  "has_x" => Exists(inner). The alias goes in _as; the
        # subquery is rendered by _get_select_query(::SubqueryObject/::ExistsObject) during build.
        push!(q.values, SQLField(v.second, v.first))
      elseif isa(v.second, SQLTypeText)
        # Support Value(x) as an aliased pair: "label" => Value("hello")
        v.second.custom_as = v.first
        push!(q.values, v.second)
      elseif isa(v.second, String)
        z = _up_values(v.second)
        z.custom_as = v.first
        push!(q.values, z)
      else
        # #92: previously an unhandled pair value was silently dropped — the column just vanished from
        # the result. Fail loud instead so a wrong projection surfaces at build time.
        throw(_argerr("Invalid values pair \"$(v.first)\" => ::$(typeof(v.second)): the right side must be a field name, a function (Count, Sum, …), Value(x), Subquery(inner), or Exists(inner)."))
      end
    elseif isa(v, String)
      push!(q.values, _up_values(v))
    else
      throw(_argerr("Invalid argument: $(v) (::$(typeof(v)))); use a string field name, a function (Count, Sum, Day, …), or an aliased pair \"alias\" => expr (e.g. \"total\" => Subquery(inner))."))
    end
  end

  return q
end

function up_create!(q::SQLObject, values; kwargs...)
  # OrderedDict so the rendered INSERT column list follows call order deterministically (#97)
  q.insert = OrderedCollections.OrderedDict{String,Any}()
  for (k, v) in values
    q.insert[k] = v
  end

  return insert(q; kwargs...)
end

function up_update!(q::SQLObject, values; kwargs...)
  # check if kwargs is not empty and check if kwargs just contains show_query
  show_query = :execute
  if !isempty(kwargs)
    for (k, v) in kwargs
      if k == :show_query
        show_query = v
      else
        throw(_argerr("Invalid keyword argument for update(): $(k) — the only supported keyword is show_query."))
      end
    end
  end
  # OrderedDict so the rendered UPDATE SET list follows call order deterministically (#97)
  q.insert = OrderedCollections.OrderedDict{String,Any}()
  for (k, v) in values
    q.insert[k] = v
  end

  return update(q, show_query=show_query)
end

# Coerce a lookup/defaults argument into a Vector{Pair}, tolerating a tuple (positional args),
# a vector, or a single bare Pair; reject any non-Pair element with an actionable error.
function _normalize_uoc_pairs(x, what::AbstractString)
  items = x isa Pair ? (x,) : x
  out = Pair[]
  for item in items
    item isa Pair ||
      throw(_argerr("Error in update_or_create, each $what entry must be a `field => value` pair, got $(typeof(item))"))
    push!(out, item)
  end
  return out
end

# Django-style row-level upsert (#30). `lookup` pairs identify the row — their fields become the
# ON CONFLICT target and their values the INSERT match values; `defaults` are the columns SET on a
# conflict (via EXCLUDED) and are merged into the INSERT. Returns `(PormGRow, created::Bool)`.
# All validation fires here, before any DB work, so `show_query=:dict` surfaces it.
function up_update_or_create!(q::SQLObject, lookup; defaults = Pair[], show_query::Symbol = :execute)
  model = q.model
  lookup_pairs  = _normalize_uoc_pairs(lookup, "lookup")
  default_pairs = _normalize_uoc_pairs(defaults, "defaults")

  isempty(lookup_pairs) &&
    throw(_argerr("Error in update_or_create, at least one lookup pair is required (it becomes the ON CONFLICT target)"))
  isempty(default_pairs) &&
    throw(_argerr("Error in update_or_create, `defaults` must be non-empty — ON CONFLICT DO UPDATE needs a SET; a no-update get_or_create is a planned follow-up (#30)"))

  lookup_keys  = String[string(k) for (k, _) in lookup_pairs]
  default_keys = String[string(k) for (k, _) in default_pairs]

  for k in lookup_keys
    haskey(model.fields, k) ||
      throw(_argerr("Error in update_or_create, lookup field \e[4m\e[31m$(k)\e[0m is not a field of $(model.name)"))
  end
  for k in default_keys
    haskey(model.fields, k) ||
      throw(_argerr("Error in update_or_create, defaults field \e[4m\e[31m$(k)\e[0m is not a field of $(model.name)"))
  end
  length(unique(lookup_keys)) == length(lookup_keys) ||
    throw(_argerr("Error in update_or_create, duplicate lookup field(s)"))
  length(unique(default_keys)) == length(default_keys) ||
    throw(_argerr("Error in update_or_create, duplicate defaults field(s)"))
  overlap = intersect(Set(lookup_keys), Set(default_keys))
  isempty(overlap) ||
    throw(_argerr("Error in update_or_create, field(s) $(join(sort(collect(overlap)), ", ")) appear in both lookup and defaults; put each in one (lookup = match key, defaults = updated on conflict)"))

  # Merge into the insert map (lookup then defaults; order preserved for deterministic SQL, #97).
  q.insert = OrderedCollections.OrderedDict{String,Any}()
  for (k, v) in lookup_pairs;  q.insert[string(k)] = v; end
  for (k, v) in default_pairs; q.insert[string(k)] = v; end

  # target = lookup keys; SET = defaults, plus every auto_now field (refresh on conflict, matching
  # update()) that isn't already a default and isn't a lookup key. auto_now_add is create-only and
  # deliberately excluded; a lookup key is the conflict target and must never be in the SET.
  target_fields = lookup_keys
  auto_now_fields = String[f for f in model.field_names
    if hasproperty(model.fields[f], :auto_now) && model.fields[f].auto_now === true &&
       !(f in default_keys) && !(f in lookup_keys)]
  set_fields = vcat(default_keys, auto_now_fields)

  return _update_or_create(q; target_fields = target_fields, set_fields = set_fields, show_query = show_query)
end

"""
  up_filter!(q::SQLObject, filter)
  Add filters to the SQLObject query.
# Arguments
- `q::SQLObject`: The SQL object to add filters to.
- `filter`: A collection of filters to add. Each filter can be a `Pair`, `SQLTypeQ`, `SQLTypeQor`, `SQLTypeOper`, or `SQLTypeF`.
# Returns
- The modified SQLObject with the new filters added.
"""
function up_filter!(q::SQLObject, filter)
  for v in filter
    if isa(v, FilterType)
      push!(q.filter, v) # TODO I need process the Qor and Q with _check_filter
    elseif isa(v, Pair)
      push!(q.filter, _check_filter(v))
    else
      # ArgumentError (not ErrorException) so filter() misuse matches the values()/order_by()
      # siblings — this call site was the two-era inconsistency #197 calls out explicitly.
      throw(_argerr("Invalid filter argument: $(v) (::$(typeof(v))) — use a \"field\" => value pair, a Q(key => value, …), or a Qor(key => value, …)."))
    end
  end
  return q
end

function up_db!(q::SQLObject, keys)
  if isempty(keys) || length(keys) > 1 || !isa(keys[1], String)
    throw(ArgumentError("db() expects exactly one String argument (the database key). Received: $(keys)"))
  end
  q.connect_key = keys[1]
  return q
end

function distinct!(q::SQLObject, value::Bool) #::Union{Bool, Nothing}) 
  q.distinct = value
  return q
end
distinct!(q::SQLObject, value::Tuple{}) = distinct!(q, true) # if no value is passed, distinct is true
distinct!(q::SQLObject, value::Tuple{Bool}) = distinct!(q, value[1]) # if a value is passed, distinct is the value
function distinct!(q::SQLObject, value)
  throw(_argerr("Invalid distinct() argument: $(value) (::$(typeof(value))) — use a Bool (true or false)."))
end

# #26: mark the query for row-level locking. Renders `FOR [NO KEY] UPDATE [NOWAIT|SKIP LOCKED]`
# on PostgreSQL; a silent no-op on SQLite. `nowait` and `skip_locked` are mutually exclusive
# (Django parity). Always builds a fresh ForUpdateClause (set-once semantics). (An `of=` target
# is a deferred follow-up — it must name the query's generated FROM alias, not yet exposed.)
function select_for_update!(q::SQLObject; nowait::Bool=false, skip_locked::Bool=false, no_key::Bool=false)
  if nowait && skip_locked
    throw(_argerr("select_for_update: `nowait` and `skip_locked` are mutually exclusive — pass at most one."))
  end
  q.for_update = ForUpdateClause(nowait, skip_locked, no_key)
  return q
end

# function distinct!(q::SQLObject, value)
#   throw("Invalid argument: $(value) (::$(typeof(value))); please use a boolean value (true or false)")
# end


# Build the SELECT part of the string final query
function _query_select(array::Vector{SQLTypeField}, connection)
  if !isassigned(array, 1, 1)
    return "*"
  else
    colect = []
    for i in 1:size(array, 1)
      if !isassigned(array, i, 1)
        return join(colect, ", \n  ")
      else
        field = array[i, 1]
        field_str = string(field.field)
        
        # Exclude wildcard projections from receiving an `AS alias` suffix (e.g., `Tb.* AS *` is invalid SQL)
        if field._as == "*" || endswith(field_str, ".*") || field_str == "*"
          push!(colect, field_str)
        elseif isa(field, SQLField) && field.custom_as !== nothing
          push!(colect, "$(field_str) as $(quote_identifier(field.custom_as, connection))")
        elseif field._as !== nothing && field._as != ""
          push!(colect, "$(field_str) as $(quote_identifier(field._as, connection))")
        else
          push!(colect, field_str)
        end
      end
    end
    return join(colect, ", \n  ")
  end
end


function order_by!(q::SQLObject, values::NTuple{N,Union{String,SQLTypeOrder}} where N)
  q.order = [] # every call of order_by, reset the order
  for v in values
    if isa(v, String)
      # check if v constains - in the first position
      v[1:1] == "-" ? (orientation = "DESC"; v = v[2:end]) : orientation = "ASC"
      check = String.(split(v, "__@"))
      if size(check, 1) == 1
        push!(q.order, SQLOrder(SQLField(v, v), orientation=orientation))
      elseif haskey(PormGsuffix, check[end])
        throw(_argerr("Invalid order_by() field \"$(v)\": operator suffixes (__@lte, __@gte, __@contains, …) are not allowed in ordering."))
      else
        push!(q.order, SQLOrder(SQLField(_check_function(check), join(check, "__")), orientation=orientation))
      end
    else
      push!(q.order, v)
    end
  end
  return q
end
function order_by!(q::SQLObject, values)
  throw(_argerr("Invalid order_by() argument: $(values) (::$(typeof(values))) — use field-name Strings (\"-field\" for DESC) or SQLTypeOrder values."))
end



# ---
# The "Functor" for chainable methods
# ---

struct ChainCaller{F,T}
  func::F
  handler::T
end

# When called (e.g., query.filter(...)), it executes and returns the handler itself
function (c::ChainCaller)(args...)
  c.func(c.handler.object, args)
  return c.handler
end

function Base.getproperty(q::ObjectHandler, sym::Symbol)
  # === CATEGORY 1: Chainable methods (return 'q') ===
  # Allows: query.filter(...).order_by(...)
  if sym === :filter
    return ChainCaller(up_filter!, q)
  elseif sym === :db
    return ChainCaller(up_db!, q)
  elseif sym === :values
    return ChainCaller(up_values!, q)
  elseif sym === :order_by
    return ChainCaller(order_by!, q)
  elseif sym === :limit
    return ChainCaller(limit!, q)
  elseif sym === :offset
    return ChainCaller(offset!, q)
  elseif sym === :page
    return ChainCaller(page!, q)
  elseif sym === :distinct
    return ChainCaller(distinct!, q)
  elseif sym === :select_for_update
    # Chainable: query.select_for_update(; nowait=false, skip_locked=false, no_key=false)
    # Closure (not ChainCaller) so keyword arguments are forwarded correctly (#26).
    return (; kwargs...) -> (select_for_update!(q.object; kwargs...); q)
  elseif sym === :with
    # Chainable: query.with("cte_name" => sub_query; join_field=..., join_type=...)
    # Uses closure (not ChainCaller) so keyword arguments are forwarded correctly.
    return (args...; kwargs...) -> (With(q, args...; kwargs...); q)
  elseif sym === :cjoin
    # Chainable: query.cjoin("field" => "Model"; filters=[...], join_type=...)
    return (args...; kwargs...) -> (cjoin(q, args...; kwargs...); q)
  elseif sym === :on
    # Chainable: query.on("join_path", "field" => value; join_type="INNER")
    return (args...; kwargs...) -> (on(q, args...; kwargs...); q)
  elseif sym === :cjoin_on
    # Chainable: query.cjoin_on("Model"; alias="b2", on=[Qor(...)], join_type="INNER")
    # Anchor-less full-control join (#45): the `on` expressions are the ENTIRE ON clause.
    return (args...; kwargs...) -> (cjoin_on(q, args...; kwargs...); q)
  elseif sym === :copy
    return () -> deepcopy(q)

  # === CATEGORY 2: Terminal methods (return result) ===
  # End the chain. E.g.: query.create(...) returns a PormGRow.
  elseif sym === :create
    # `args...` is intentionally untyped: the execute path returns a PormGRow (#166), while
    # show_query=:sql/:dict/:params/:none return String/Dict/Vector/nothing. A typed
    # signature would force the inspect contract to fork, so the return stays `Any`.
    return (args...; kwargs...) -> up_create!(q.object, args; kwargs...)
  elseif sym === :update
    # Same dual execute/inspect return contract as :create — see the note above.
    return (args...; kwargs...) -> up_update!(q.object, args; kwargs...)
  elseif sym === :update_or_create
    # Row-level upsert (#30). Execute path returns (row::PormGRow, created::Bool);
    # show_query=:sql/:dict/:params return the inspection shape (String/Dict/Vector), same dual
    # contract as :create/:update. `args` = lookup pairs; `defaults=`/`show_query=` via kwargs.
    return (args...; kwargs...) -> up_update_or_create!(q.object, args; kwargs...)
  elseif sym === :count
    # count()                         -> COUNT(*)              (total rows)
    # count(distinct=true)            -> distinct rows         (subquery COUNT(*) over SELECT DISTINCT *)
    # count("col")                    -> COUNT("col")          (non-null values of a column)
    # count("col", distinct=true)     -> COUNT(DISTINCT "col") (distinct values of a column, scalar)
    return (column=nothing; distinct::Bool=false, show_query::Symbol=:execute) ->
      do_count(q; column=column, distinct=distinct, show_query=show_query)
  elseif sym === :exists
    return (; show_query=:execute) -> do_exists(q; show_query=show_query)
  elseif sym === :first
    return (; kwargs...) -> first(q; kwargs...)
  elseif sym === :get
    return (args...; show_query=:execute) -> get(q, args...; show_query=show_query)
  elseif sym === :list
    return (format::Symbol=:row; show_query::Symbol=:execute) -> list(q, Val(format); show_query=show_query)
  elseif sym === :inspect
    return (; kwargs...) -> inspect_query(q; kwargs...)
  elseif sym === :delete
    return (; kwargs...) -> delete(q; kwargs...)

  # === CATEGORY 3: Internal fields ===
  else
    return getfield(q, sym)
  end
end

# Dispatches on the concrete Model_Type (the sole concrete PormGModel). It was on `::PormGModel` and
# carried a `hasfield(…, :cache)` guard only because fields used to be `<: PormGModel` and would recurse
# into their absent `.cache` (a StackOverflowError, #108). Fields are no longer `<: PormGModel` (#186),
# so that guard is gone and field property access uses Julia's default getproperty.
function Base.getproperty(m::Models.Model_Type, sym::Symbol)
  if sym === :objects
    # Self-healing: Ensure models are initialized before returning objects
    Models.ensure_model_initialized(m)
    return object(m)
  elseif sym in fieldnames(typeof(m))
    # IMPORTANT: struct fields MUST be intercepted here via getfield before the M2M
    # accessor check below.  has_many_to_many_accessor() itself accesses m.cache and
    # m.related_objects; if those go through getproperty again we get infinite recursion.
    # M2M accessor names are validated through format_fild_name which rejects reserved
    # names, so a user-defined M2M field cannot shadow a Model_Type struct field.
    return getfield(m, sym)
  elseif Models.has_many_to_many_accessor(m, String(sym))
    Models.ensure_model_initialized(m)
    return ManyToManyDescriptor(m, String(sym), Models.get_many_to_many_relation(m, String(sym)))
  else
    return getfield(m, sym)
  end
end

@doc """
    filter(args...)

Apply filters to the query. Chainable method that returns the query object.

Usage: `query.filter("field" => value)`

See [Read documentation](read/index.md) for detailed filter syntax and examples.
""" ChainCaller(up_filter!, q)
