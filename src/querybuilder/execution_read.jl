# Executing a read (#130): `query` and the statement it prints, `count` / `exists` / `aggregate`,
# `inspect_query`, the row-returning terminals — `list`, `query_list`, `first` / `last` / `earliest` /
# `latest` and `get` — and the Tables.jl source `DataFrame(query)` reads (#1344). Writes are in
# `execution_write.jl`, bulk writes in `execution_bulk.jl`, and rendering an `F(...)` expression in
# `expression_render.jl`.

# `instruction` is the SELECT build's (#1624), which only `query()` hands over: it is what `:struct`
# reads (#1632). Every other caller — `count()`, `exists()`, the writes, a `delete()` step — has rows of
# no shape to declare, and `:struct` refuses there.
function _show_query_result(mode::Symbol, sql::String, connection::Union{Nothing, _SQLEngine}, model::Union{PormGModel, String}, operation::Symbol;
                          parameters::Union{Nothing, AbstractPormGParam} = nothing,
                          instruction::Union{Nothing, SQLInstruction} = nothing)

  if mode === :none
    return nothing # Zero-allocation mode for benchmarking the builder
  elseif mode === :sql
    return sql # Simplicity: just the SQL string (fast benchmarking)
  elseif mode === :pretty
    return _format_sql(sql) # #48: one clause per line, for logs and the REPL; whitespace only
  elseif mode === :struct
    instruction === nothing && throw(_struct_mode_refusal())
    return _row_struct_text(instruction)
  elseif mode === :execute
    # Safety check: this function shouldn't be called with :execute,
    # but we return SQL just in case to avoid a crash.
    return sql
  end

  # Resolve model name
  model_name = model isa PormGModel ? model.name : String(model)

  # For formats requiring parameters, prepare the list
  params_list = if parameters === nothing
    []
  elseif hasproperty(parameters, :parameters)
    parameters.parameters
  else
    # Fallback for AbstractPormGParam if it doesn't have .parameters field
    []
  end
  
  if mode === :params
    return params_list
  elseif mode === :dict || mode === :inspection
    # Rich metadata format used by inspect_query() or advanced debugging
    dialect, bucketing = _inspection_dialect(connection)
    
    bucket_breakdown = Dict{Symbol, Vector{Any}}()
    if parameters isa PormGPositionalParam
      # Every slot `_BUCKET_ORDER` names, so a bucket added there is reported here without a second
      # list. This was a hand-written copy, and #46's `:limit` would have been missing from it.
      for ctx in _BUCKET_ORDER
        bucket_breakdown[ctx] = _bucket_for(parameters, ctx)
      end
    end

    return Dict(
        :sql_text => sql, 
        :parameters => params_list,
        :dialect => dialect,
        :model => model_name,
        :operation => operation,
        :bucketing => bucketing,
        :parameter_count => length(params_list),
        :parameter_buckets => bucket_breakdown
    )
  else
    throw(QueryBuildError("Invalid show_query mode: $mode. Must be one of: :sql, :pretty, :dict, :inspection, :params, :struct, :none"))
  end
end

# ── #1632: `show_query = :struct` — the struct a typed read needs, as source text ─────────────────────

# The terminals that return no rows to declare: `count()` (its column form and `aggregate()` build a
# SELECT through `query()`, so they ask for this before it), `exists()`, the writes, a `delete()` step.
_struct_mode_refusal() = QueryBuildError(
  "show_query = :struct writes the struct a read's rows need, so it applies to the terminals that " *
  "return rows: list(), first(), last(), get(), earliest(), latest() and query_list(). This call " *
  "returns no rows to declare.")

#
# The build already knows what each projected column is: the walk names its kind (`_expression_kind`,
# or the read view the build recorded, `projection_kinds`, where a parser changes the value), the
# value-representation table names the Julia type the read delivers for that kind (`julia_type`, slot
# 4), and the typed read's conversion rules say what a field should declare for it
# (`_typed_declaration`). This writes those three answers down as a struct to paste. It returns TEXT:
# a library function cannot create a struct in the caller's module without `eval` (#1599 I3), and a
# struct the caller pastes is reviewed, renamed and owned like any other code.
#
# `projection_kinds` is not enough on its own: it is the READ view, and records no kind for an integer,
# a float column, text or a uuid, which a driver delivers as they are (#1034 step 3). The walk does.
#
# NULL is CONSERVATIVE: a column is `Union{Nothing, T}` unless the build proves it never NULL — a column
# whose field is not `null = true`, read from the base table or through an INNER join, a `COUNT`, a
# literal, a `Coalesce` with an operand that is never NULL. A field that admits `nothing` takes every
# non-NULL value too, so a wrong `Union` costs an edit; a missing one fails the read.
#
# Off the warm path: the read terminals render through `_render_select` and never reach
# `_show_query_result`, so nothing here runs when a query executes.

# One field of the struct: its name, its declaration (`""` when the table names no type, which writes a
# `# TODO` line instead of a field) and the comment that says where the column comes from.
struct _StructField
  name::String
  decl::String
  nullable::Bool
  note::String
end

function _row_struct_text(instruction::SQLInstruction)::String
  obj = instruction.object
  conn = instruction.connection
  usings = Set{Symbol}()
  fields = _StructField[]
  # A RIGHT or FULL join puts the tables before it on the nullable side, the base table included, and
  # which tables those are depends on emission order (`_refuse_lock_targets_beside_right_joins`), so
  # every column is nullable when one is present.
  outer = any(r -> hasproperty(r, :how) && uppercase(getproperty(r, :how)) in ("RIGHT", "FULL"), instruction.row_join)
  if isempty(obj.values)
    _push_model_struct_fields!(fields, obj.model, conn, outer, usings)
  else
    # A typed read refuses `values("*")` (`_typed_projection!`), so a struct for it is one `list(T)`
    # could never read: refused here too, with the same way out.
    any(_is_wildcard_projection, obj.values) && throw(QueryBuildError(
      "show_query = :struct writes the struct list(T) reads, and a typed read cannot project values(\"*\"). " *
      "Drop values(\"*\") for the struct of the model's fields, or name every column in values(...)."))
    for (i, v) in enumerate(obj.values)
      rendered = isassigned(instruction.select, i) ? instruction.select[i] : nothing
      push!(fields, _projection_struct_field(v, rendered, instruction, conn, outer, usings))
    end
  end
  return _render_struct_text(_struct_identifier(uppercasefirst(String(obj.model.name)) * "Row"), fields,
                             _backend_name(conn), usings)
end

# A wildcard: the model's own columns, in declaration order, under the field names `list(T)` projects
# (a `db_column` field is keyed by its field name there). A many-to-many field has no column.
function _push_model_struct_fields!(fields::Vector{_StructField}, model::PormGModel, conn, outer::Bool,
                                    usings::Set{Symbol})
  for (fname, f) in model.fields
    Models.is_many_to_many_field(f) && continue
    kind = something(_field_read_kind(f), _field_kind(f), Some(nothing))
    null = _struct_field_null(f)
    note = _struct_field_type_name(f) * (null ? "; null = true" : "")
    outer && (note *= "; a RIGHT or FULL join can make it NULL")
    push!(fields, _struct_field(String(fname), kind, conn, null || outer, note, usings))
  end
  return fields
end

function _projection_struct_field(v::Union{SQLTypeText,SQLTypeField}, rendered, instruction::SQLInstruction,
                                  conn, outer::Bool, usings::Set{Symbol})::_StructField
  name = String(something(_projection_output_name(v), ""))
  node = v isa SQLTypeText ? v : v.field
  # The read view first: where a parser changes the value (a SQLite date, a computed float) it is the
  # kind the cell arrives as. Otherwise the walk's, which is the engine's own type.
  kind = get(instruction.projection_kinds, Symbol(name), nothing)
  kind === nothing && (kind = _struct_walk_kind(node, instruction))
  never_null, note = _struct_source(node, rendered isa SQLTypeField ? rendered.field : nothing, instruction)
  outer && (never_null = false; note *= "; a RIGHT or FULL join can make it NULL")
  return _struct_field(name, kind, conn, !never_null, note, usings)
end

# The walk can refuse a shape the render accepted only through another door; a display never raises
# for that, and the column becomes a `# TODO` line.
function _struct_walk_kind(node, instruction::SQLInstruction)
  try
    return _expression_kind(node, instruction)
  catch e
    e isa PormGError || rethrow()
    return nothing
  end
end

function _struct_field(name::String, kind, conn, nullable::Bool, note::String, usings::Set{Symbol})::_StructField
  # No kind (the walk names none), or a kind with no single type on this engine (a JSON key's value,
  # whose type is the data's; a PostgreSQL array; a SQLite decimal too wide to parse exactly).
  T = kind === nothing ? nothing : _typed_declaration(julia_type(kind, conn))
  T === nothing && return _StructField(name, "", nullable,
    "PormG cannot name one type for this column on $(_backend_name(conn)). Cast it to the type you mean " *
    "(`Cast(path, \"integer\")`), or declare the field by hand")
  decl = _struct_type_text(T, usings)
  _struct_engine_specific(kind, conn, T) &&
    (note *= "; this is $(_backend_name(conn))'s type: another engine reads it as another, or as one PormG does not name")
  return _StructField(name, nullable ? "Union{Nothing, " * decl * "}" : decl, nullable, note)
end

# Whether another engine declares this kind differently: a struct written against one engine must say
# so before it surprises a reader on another. Names only the engine at hand.
function _struct_engine_specific(kind, conn, T)::Bool
  here = _backend_name(conn)
  for e in _JULIA_TYPE_ENGINES
    _backend_name(e) == here && continue
    _typed_declaration(julia_type(kind, e)) === T || return true
  end
  return false
end

# The type as source text, adding the `using` its module needs. `Base`/`Core` types need none; a name
# its module does not export is written qualified (`Dates.CompoundPeriod`).
function _struct_type_text(T::Type, usings::Set{Symbol})::String
  T <: AbstractVector && return "Vector{" * _struct_type_text(eltype(T), usings) * "}"
  root = Base.moduleroot(parentmodule(T))
  (root === Core || root === Base) && return String(nameof(T))
  push!(usings, nameof(root))
  return Base.isexported(root, nameof(T)) ? String(nameof(T)) : String(nameof(root)) * "." * String(nameof(T))
end

_struct_field_null(f::PormGField)::Bool = hasproperty(f, :null) && getproperty(f, :null) === true
_struct_field_type_name(f::PormGField)::String = begin
  s = String(nameof(typeof(f)))   # `sCharField` -> `CharField`
  length(s) > 1 && s[1] == 's' && isuppercase(s[2]) ? s[2:end] : s
end

# A field name or the struct name as Julia source: `var"…"` when it does not parse as that name on its
# own, which still names the field `list(T)` matches by. A projection alias is a plain SQL identifier,
# so the case that reaches this is a Julia keyword (`end`, `begin`): `Base.isidentifier` accepts those,
# and only the parse refuses them.
_struct_identifier(name::String)::String =
  Base.isidentifier(name) && Meta.parse(name; raise = false) === Symbol(name) ? name :
    "var\"" * Base.escape_raw_string(name) * "\""

# ── Where a column comes from, and whether it can be NULL: `(never_null, comment)` ────────────────
#
# One method per node a projection holds. `rendered` is the column's rendered SQL, which names the
# table alias it reads from: the join row with that alias says whether the column is on the outer side
# of a LEFT join.
function _struct_source(node::String, rendered, instruction::SQLInstruction)::Tuple{Bool,String}
  obj = instruction.object
  occursin("__@", node) && return (false, "$(node): a transform; PormG does not track NULL through it")
  field = _alias_column_field(node, instruction)
  field === nothing && return (false, node)
  type_name = _struct_field_type_name(field)
  null = _struct_field_null(field)
  # A base-table column: only a key of the model's own fields. Anything else that names no relation is
  # a value INSIDE a column — an array element (`tags__0`), a JSON key — which is NULL when it is absent,
  # whatever the column's own `null`.
  haskey(obj.model.fields, node) && return (!null, type_name * (null ? "; null = true" : ""))
  # A joined column likewise: exactly ONE segment after the relations, a field of the model they reach.
  # More (`constructorid__tags__0`) is a value inside that column, NULL when absent, through any join.
  prefix = _relation_prefix(obj, node)
  inside = (false, "$(node): a value inside a column; NULL when it is absent")
  isempty(prefix) && return inside
  rest = split(node, "__")[length(split(prefix, "__")) + 1:end]
  model = _struct_path_model(obj, node)
  (length(rest) == 1 && model !== nothing && haskey(model.fields, String(only(rest)))) || return inside
  target = uppercasefirst(String(model.name))
  how = _struct_join_how(rendered, instruction)
  # RIGHT and FULL are not explained here: they put the EARLIER tables on the nullable side, which the
  # caller's "a RIGHT or FULL join can make it NULL" covers for every column.
  note = "$(node): $(type_name) on $(target)" * (null ? "; null = true" : "") *
         (how == "LEFT" ? "; LEFT JOIN: NULL when there is no $(target) row" :
          how == ""     ? "; read through a join PormG cannot place, so NULL is assumed" : "")
  return (!null && how == "INNER", note)
end

function _struct_source(node::FObject, ::Any, instruction::SQLInstruction)::Tuple{Bool,String}
  fname = node.function_name
  col = node.column   # a local, so the `isa` narrows it: no `string` of an uninferred value (#1346)
  what = col isa String ? "$(fname) over $(col)" : fname
  fname == "COUNT" && return (true, what)
  if fname == "COALESCE" && col isa AbstractVector
    any(x -> _struct_never_null_operand(x, instruction), col) && return (true, what * ": an operand is never NULL")
    return (false, what * ": NULL when every operand is")
  end
  node.aggregate && return (false, what * ": NULL when no row matches")
  return (false, what * ": NULL when an operand is NULL")
end
_struct_source(node::WindowFunction, ::Any, ::SQLInstruction) =
  (false, "$(node.function_name) window: NULL on a row the window gives no value")
_struct_source(::FExpression, ::Any, ::SQLInstruction) = (false, "an F expression: NULL when an operand is NULL")
_struct_source(::SubqueryObject, ::Any, ::SQLInstruction) = (false, "Subquery: NULL when it matches no row")
_struct_source(::ExistsObject, ::Any, ::SQLInstruction) = (true, "Exists")
_struct_source(node::CTEReference, ::Any, ::SQLInstruction) =
  (false, "CTE $(node.name), column $(node.path): PormG does not track NULL through a CTE")
function _struct_source(node::JoinedReference, ::Any, instruction::SQLInstruction)::Tuple{Bool,String}
  i = findfirst(r -> r.alias_b == node.alias, instruction.row_join)
  inner = i !== nothing && hasproperty(instruction.row_join[i], :how) &&
          uppercase(getproperty(instruction.row_join[i], :how)) == "INNER"
  field = _alias_column_field(node, instruction)
  null = field === nothing || _struct_field_null(field)
  note = "Joined $(node.alias), column $(node.path)" * (field === nothing ? "" : ": " * _struct_field_type_name(field)) *
         (inner ? "" : "; an outer join: NULL when there is no joined row")
  return (inner && !null, note)
end
_struct_source(node::SQLTypeText, ::Any, ::SQLInstruction) =
  _is_null_literal(node.field) ? (false, "Value(nothing)") : (true, "Value literal")
_struct_source(::Any, ::Any, ::SQLInstruction) = (false, "computed: PormG does not track NULL through it")

# A `Coalesce` operand that is never NULL: a literal, or a base-table column whose field is not nullable.
function _struct_never_null_operand(x, instruction::SQLInstruction)::Bool
  x isa Number && return true
  x isa SQLTypeText && return !_is_null_literal(x.field)
  if x isa String
    fields = instruction.object.model.fields
    return haskey(fields, x) && !_struct_field_null(fields[x])
  end
  return false
end

# The type of the join a joined column is read through — the row whose alias its rendered SQL names
# (`"Tb_2"."name"`) — or `""` when no row matches, which the caller treats as nullable: a path the
# build joined but this cannot place must not be declared non-NULL by default.
function _struct_join_how(rendered, instruction::SQLInstruction)::String
  rendered isa AbstractString || return ""
  for r in instruction.row_join
    startswith(rendered, quote_identifier(r.alias_b, instruction.connection) * ".") || continue
    return hasproperty(r, :how) ? uppercase(String(getproperty(r, :how))) : ""
  end
  return ""
end

# The model at the end of a column path's relations (`constructorid__name` -> Constructor).
function _struct_path_model(obj::SQLObject, path::String)
  segments = split(path, "__")
  model = obj.model
  for (i, seg) in enumerate(segments[1:end-1])
    step = _relation_step(obj, model, seg, i == 1)
    step === nothing && return nothing
    model = step[2]
  end
  return model
end

function _render_struct_text(struct_name::String, fields::Vector{_StructField}, engine::String,
                             usings::Set{Symbol})::String
  io = IOBuffer()
  for m in sort!(collect(usings))
    print(io, "using ", m, "\n")
  end
  isempty(usings) || print(io, "\n")
  print(io, "# show_query = :struct, rendered for ", engine, ": the row type list(T) accepts. Review it before pasting.\n")
  print(io, "struct ", struct_name, "\n")
  width = maximum((length(_struct_identifier(f.name)) + 2 + length(f.decl) for f in fields if !isempty(f.decl)); init = 0)
  for f in fields
    note = replace(f.note, r"[\r\n]+" => " ")
    if isempty(f.decl)
      print(io, "    # TODO ", _struct_identifier(f.name), ": ", note, "\n")
    else
      decl = _struct_identifier(f.name) * "::" * f.decl
      print(io, "    ", rpad(decl, width), "  # ", note, "\n")
    end
  end
  print(io, "end\n")
  return String(take!(io))
end

"""
    inspect_query(q::SQLObjectHandler) -> Dict

Comprehensive query inspection API that provides full metadata about a query without executing it.
Returns a rich dictionary with SQL, parameters, dialect information, and structural metadata.

This is the explicit API for query inspection - use this when you want to examine a query's structure
and generated SQL without ambiguity.

# Arguments
- `q::SQLObjectHandler`: The query object to inspect
- `operation::Union{Nothing, Symbol} = nothing`: Optional operation override (:select, :insert, :update, :delete).
  If not provided, the operation is detected automatically based on the query structure.

# Returns
- `Dict`: A dictionary containing:
  - `:sql_text` (String): The generated SQL query
  - `:parameters` (Vector): The parameterized values in bucket order
  - `:dialect` (Symbol): The database dialect (`:postgresql`, `:sqlite` or `:mysql`)
  - `:model` (String): The model/table name
  - `:operation` (Symbol): The query operation type (`:select`, `:insert`, `:update`, `:delete`).
    A cascading `:delete` returns a Vector of steps; on PostgreSQL that Vector starts with one
    `:lock` step (`SELECT … FOR UPDATE`) per parent model (#770)
  - `:bucketing` (Symbol): The parameter bucketing strategy (`:numbered` for PostgreSQL, `:positional` for SQLite and MySQL)
  - `:parameter_count` (Int): Number of parameters
  - `:parameter_buckets` (Dict): Breakdown of parameters by bucket (for positional strategies)

# Example
```julia
q = M.Driver.objects
q.filter("nationality" => "British")
q.order_by("surname")

inspection = q |> inspect_query()
# Dict with:
# :sql_text => "SELECT ... WHERE drivers.nationality = \$1 ORDER BY ..."
# :parameters => ["British"]
# :dialect => :postgresql
# :model => "drivers"
# :operation => :select
# :bucketing => :numbered
```
"""
function inspect_query(q::SQLObjectHandler; connection::Union{Nothing, _SQLEngine} = nothing, operation::Union{Nothing, Symbol} = nothing)
  # #43: inspection must not mutate the caller. A SELECT dry run builds on the caller's handler
  # itself, because the build writes nothing (#1624). The insert/update/delete dry runs still write
  # into what they are handed — `insert()` fills defaults and `update()` its auto-now fields into
  # `q.object.insert` — so they get a copy, below.

  # Force builder to run without execution
  # We reuse the internal query building logic
  settings, conn, conn_key = get_settings(q, connection=connection)
  
  # 1. Operation detection heuristic
  if operation === nothing
    if !isempty(q.object.insert)
      # If it has data in the 'insert' field, it's either an INSERT or an UPDATE.
      # UPDATE typically has filters (WHERE), INSERT typically does not.
      operation = isempty(q.object.filter) ? :insert : :update
    else
      # Default to :select (safe, most common)
      # Note: :delete is ambiguous with :select if only filters are present,
      # so it must be explicitly requested via inspect_query(operation=:delete)
      operation = :select
    end
  end
  
  # 2. Delegate to appropriate dry-run
  operation === :select && return query(q, show_query=:inspection, connection=conn)
  q = deepcopy(q)
  if operation === :insert
      return insert(q.object, show_query=:inspection, connection=conn)
  elseif operation === :update
      return update(q.object, show_query=:inspection, connection=conn)
  elseif operation === :delete
      res = delete(q, show_query=:inspection, connection=conn)
      # delete() returns (total_deleted, counter_dict) when executing.
      # In inspection mode it returns a single Dict (simple delete) or a
      # Vector of Dicts (cascaded delete with SET_NULL / SET_DEFAULT / CASCADE
      # steps).  Return the result as-is so callers can inspect every step.
      return res isa Tuple ? res[2] : res
  else
      throw(QueryBuildError("Unsupported or unknown operation for inspection: $operation"))
  end
end
inspect_query(; kwargs...) = (objct) -> inspect_query(objct; kwargs...)

# #46: the LIMIT / OFFSET tail of a SELECT, bound like every other user value. Both bind under
# `:limit`, the last bucket in `_BUCKET_ORDER`, because their text is the last that carries a marker —
# and in a nested render (a `Subquery`, an `__@in` list, a CTE body) the caller lifts the run out in
# that same clause order, so an inner LIMIT lands inside its parent's run, not at the statement's
# tail. A `nothing` limit is "no LIMIT" and binds nothing; `0` binds, and is zero rows — SQL's and
# Django's meaning (#1049; it used to be the no-limit sentinel and returned every row). An offset of
# `0` binds nothing because OFFSET 0 is a no-op anyway.
function _limit_offset_sql(limit::Union{Nothing,Integer}, offset::Integer, parameters::AbstractPormGParam,
                           connection::_SQLEngine)::String
  (limit === nothing && offset == 0) && return ""
  return with_bucket(parameters, :limit) do
    limit_sql = limit === nothing ? nothing : add_parameter!(parameters, limit)
    offset_sql = offset == 0 ? nothing : add_parameter!(parameters, offset)
    Dialect.limit_offset_clause(limit_sql, offset_sql, connection)
  end
end

# #169: `select_for_update(of = …)` targets → the QUOTED FROM-clause aliases `FOR UPDATE OF` names.
#
# Runs after `build()`, because only then does every join the targets may name exist, and on BOTH
# engines — SQLite renders no lock, but a target that cannot resolve is a bug in the caller's code,
# and the development engine is where it should surface. A name is only ever a lookup key: what is
# rendered is the alias the build generated (or a `cjoin_on` alias `_validate_identifier` accepted at
# declaration), so no caller text reaches the SQL.
#
# Three kinds of target, each in its own namespace — `"self"`, a relation path, a `cjoin_on` alias.
# A name in more than one is refused rather than ranked (#492): the alias namespace exists precisely
# because an alias may be spelled like a relation (#484), and guessing which was meant would lock
# the wrong table silently. A relation the query never joins is refused too, not joined on the spot:
# a reverse relation joined only to be locked would multiply the rows the read returns.
function _lock_target_aliases(instruction::SQLInstruction, names::Vector{String})::Vector{String}
  obj = instruction.object
  by_path = something(instruction.join_alias_by_path, Dict{String,String}())
  _refuse_lock_targets_beside_right_joins(instruction)
  aliases = String[]
  for name in names
    segments = split(name, "__")
    canonical = _canonical_join_path(obj, name)
    # Every segment must be a relation: `driverid__surname` canonicalizes to `driverid`, which would
    # otherwise lock the driver while the caller named a column.
    is_path = !isempty(canonical) && length(split(canonical, "__")) == length(segments)
    is_alias = haskey(obj.alias_join, name)
    is_self = name == "self"
    if count((is_self, is_path, is_alias)) > 1
      meanings = String[]
      is_self && push!(meanings, "the base model's own target")
      is_path && push!(meanings, "a relation path on $(obj.model.name)")
      is_alias && push!(meanings, "a cjoin_on alias")
      # The only remedy PormG can offer is renaming the alias; a model relation literally named
      # "self" has no spelling in `of` at all, and saying so beats advice that does not apply.
      remedy = is_alias ? "Rename the cjoin_on alias." :
        "A relation named \"self\" cannot be told apart from the base model in `of`."
      throw(AmbiguousFieldError(
        "select_for_update(of = …): \"$(name)\" is ambiguous — it names $(join(meanings, " and ")), " *
        "so PormG will not choose which table to lock. $(remedy)"))
    end
    alias = if is_self
      instruction.alias
    elseif is_alias
      name
    elseif is_path && haskey(by_path, canonical)
      by_path[canonical]
    else
      # Only what would be accepted: a LEFT-joined path or alias would be refused the moment the
      # caller took the suggestion.
      lockable(a) = (i = findfirst(r -> r.alias_b == a, instruction.row_join);
                     i === nothing || !hasproperty(instruction.row_join[i], :how) ||
                     uppercase(instruction.row_join[i].how) != "LEFT")
      choices = vcat(["self"], sort!([p for (p, a) in by_path if lockable(a)]),
                     [a for a in keys(obj.alias_join) if lockable(a)])
      what = is_path ? "is a relation on $(obj.model.name) that this query does not join" :
                       "is not a relation path or cjoin_on alias of this query"
      throw(QueryBuildError(
        "select_for_update(of = …): \"$(name)\" $(what). A lock target must name a table the query " *
        "already reads. Choices: $(join(choices, ", "))."))
    end
    _refuse_nullable_lock_target(instruction, name, alias)
    alias in aliases || push!(aliases, alias)
  end
  return [quote_identifier(a, instruction.connection) for a in aliases]
end

# PostgreSQL refuses `FOR UPDATE OF` the nullable side of an outer join. A nullable foreign key and
# every hop after one render LEFT (`build_joins.jl`), so this is ordinary input, not an edge case —
# refused here, on both engines, so it fails during development on SQLite too.
function _refuse_nullable_lock_target(instruction::SQLInstruction, name::String, alias::String)
  i = findfirst(r -> r.alias_b == alias, instruction.row_join)
  i === nothing && return nothing   # the base relation, which no join row describes
  row = instruction.row_join[i]
  hasproperty(row, :how) || return nothing
  # FULL never reaches here: `_refuse_lock_targets_beside_right_joins` refused the statement first.
  uppercase(row.how) == "LEFT" || return nothing
  throw(QueryBuildError(
    "select_for_update(of = …): \"$(name)\" is joined $(uppercase(row.how)) — a nullable foreign " *
    "key, a hop after one, a reverse or ManyToMany relation an OR arm or `__@isnull => true` reads, " *
    "or an explicit join_type — and PostgreSQL cannot lock the nullable side " *
    "of an outer join. Leave it out of `of` — of = (\"self\",) locks the base rows alone — or lock " *
    "that table with a query of its own."))
end

# A RIGHT or FULL join puts what is joined BEFORE it on the nullable side — the base table included —
# which a per-row check cannot see: the target's own row may be INNER. Which tables that reaches
# depends on emission order, which `cjoin_on` dependencies and ON-clause relocation reorder after
# the rows are built, so `of` is refused for the whole statement rather than guessed at per target.
# That also refuses a target PostgreSQL would accept (the right side of a lone RIGHT join): the
# cost of not tracking the order, and a loud one.
function _refuse_lock_targets_beside_right_joins(instruction::SQLInstruction)
  for row in instruction.row_join
    hasproperty(row, :how) || continue
    how = uppercase(row.how)
    how in ("RIGHT", "FULL") || continue
    throw(QueryBuildError(
      "select_for_update(of = …) cannot be used on a query with a $(how) JOIN (to \"$(row.b)\"): it " *
      "puts the tables joined before it, the base table included, on the nullable side of an outer " *
      "join, which PostgreSQL cannot lock. Use INNER or LEFT joins, or lock the rows with a query " *
      "of their own."))
  end
  return nothing
end

# #1106: a lock WITHOUT `of` locks every table the statement reads, so beside an outer join it
# reaches PostgreSQL only to fail there with `FOR UPDATE cannot be applied to the nullable side of an
# outer join`, a message that does not point at the fix. Refused here instead, on both engines like
# the `of` checks above: the query is a bug in the call, and SQLite is where it should surface.
#
# RIGHT/FULL first: it puts the base table itself on the nullable side, so `of` cannot help, and a
# statement that also has a LEFT join must not be told that `of = ("self",)` would. A LEFT join to a
# CTE is not refused: PostgreSQL does not lock a WITH query, so its nullable side holds nothing to
# lock. Every other LEFT row targets a table — a `cjoin_on` target is always a model.
#
# Refused even when PostgreSQL would run it: a WHERE filter that is strict on the nullable side
# (`filter("nullable_fk__col" => x)`) lets the planner reduce the join to INNER first, and then the
# lock succeeds. PormG does not guess what the planner reduces. The message names the explicit
# spelling of that reduction, an INNER join — the same rows under such a filter, and lockable — beside
# `of = ("self",)`, which leaves the table unlocked.
function _refuse_plain_lock_beside_outer_joins(instruction::SQLInstruction)
  for row in instruction.row_join
    hasproperty(row, :how) || continue
    how = uppercase(row.how)
    how in ("RIGHT", "FULL") || continue
    throw(QueryBuildError(
      "select_for_update() cannot be used on a query with a $(how) JOIN (to \"$(row.b)\"): it puts " *
      "the tables joined before it, the base table included, on the nullable side of an outer join, " *
      "which PostgreSQL cannot lock, and no `of` target avoids that. Use INNER or LEFT joins, or lock " *
      "the rows with a query of their own."))
  end
  for row in instruction.row_join
    row isa CteJoin && continue
    (hasproperty(row, :how) && uppercase(row.how) == "LEFT") || continue
    label, inner = _lock_join_label(instruction, row)
    throw(QueryBuildError(
      "select_for_update() locks every table the query reads, and $(label) is joined LEFT — a " *
      "nullable foreign key, a hop after one, a reverse or ManyToMany relation an OR arm or " *
      "`__@isnull => true` reads, or an explicit join_type — so it is on the nullable " *
      "side of an outer join, which PostgreSQL cannot lock. Pass of = (\"self\",) to lock the base " *
      "rows alone, leaving that table unlocked$(inner), or lock it with a query of its own."))
  end
  return nothing
end

# How the caller spelled the join — its `cjoin_on` alias, or the relation path that reached it —
# and the INNER spelling that keeps it locked. A hop that no path names (one out of a CTE) falls
# back to its table, with no INNER spelling to offer.
function _lock_join_label(instruction::SQLInstruction, row::JoinRow)::Tuple{String,String}
  inner_tail = " (the same rows when a filter already requires a match)"
  row isa AnchorlessJoin && return ("the cjoin_on alias \"$(row.alias_b)\"",
    "; join it with join_type = \"INNER\" to lock it too$(inner_tail)")
  by_path = something(instruction.join_alias_by_path, Dict{String,String}())
  paths = sort!([p for (p, a) in by_path if a == row.alias_b])
  isempty(paths) && return ("the table \"$(row.b)\"", "")
  path = first(paths)
  return ("the relation \"$(path)\"",
    "; on(\"$(path)\", join_type = \"INNER\") locks it too$(inner_tail)")
end

function query(q::SQLObjectHandler;
  table_alias::Union{Nothing, SQLTableAlias} = nothing,
  connection::Union{Nothing, _SQLEngine} = nothing,
  parameters::Union{Nothing, AbstractPormGParam} = nothing,
  outer::Union{Nothing, SQLInstruction} = nothing,
  show_query::Symbol = :execute,
  built::Union{Nothing,Function} = nothing,
  semi_join::Bool = false,
  cte_body::String = "",
  cte_body_correlated::Bool = false)
  rendered = _render_select(q; table_alias, connection, parameters, outer, show_query, built, semi_join,
                            cte_body, cte_body_correlated)
  instruction = rendered.instruction
  if show_query !== :execute
    return _show_query_result(show_query, rendered.sql, instruction.connection, q.object.model.name, :select;
                            parameters=instruction.parameters, instruction=instruction)
  end
  _refuse_lock_outside_transaction(q, instruction)
  return rendered.sql
end

# #26: a locked read executed OUTSIDE a transaction is a footgun — the lock is taken then
# immediately released at autocommit. Fail loudly (Django's TransactionManagementError analog).
# Guarded on the execute path only, so inspect_query/show_query still render FOR UPDATE without a
# live transaction. On both engines (#1237): SQLite takes no row lock, but inside a transaction its
# writers are serialized, which is the exclusion the caller asked for — and a missing transaction
# is a bug in the call that would otherwise surface only in production on PostgreSQL.
# The transaction must be on the pool this read runs on (#831): a transaction open on another
# database does not hold this lock. Inside one, `build`'s `ensure_transaction_scope` already
# refuses a read routed to a pool with no transaction (#838), so what reaches here unguarded is
# a read with no transaction open anywhere.
function _refuse_lock_outside_transaction(q::SQLObjectHandler, instruction::SQLInstruction)
  if q.object.for_update !== nothing && transaction_connection_for(instruction.connection) === nothing
    throw(QueryBuildError("select_for_update() must run inside a transaction (run_in_transaction/atomic): under autocommit a locked read holds nothing once it returns."))
  end
  return nothing
end

# #1624 — the SELECT render, which WRITES NOTHING into `q`: it returns the SQL and the build's
# instruction, and the instruction carries what the build produced — the parameter collector
# (`instruction.parameters`), the kind of each projection (`instruction.projection_kinds`, #564), the
# CTE state (`instruction.cte_state`) — where `query()` used to write the first two back into
# `q.object` and the CTE state into `q.object.ctes`. That write-back is why every read deep-copied the
# caller's handler (#43, #199), and why a membership subquery's handler, which is not copied, was
# written into (#1625). `query()` is this plus the inspection modes and the execute-only checks.
function _render_select(q::SQLObjectHandler;
  table_alias::Union{Nothing, SQLTableAlias} = nothing,
  connection::Union{Nothing, _SQLEngine} = nothing,
  parameters::Union{Nothing, AbstractPormGParam} = nothing,
  outer::Union{Nothing, SQLInstruction} = nothing,
  show_query::Symbol = :execute,
  # #929: called with the inner build's instruction right after `build()`, while its memos still hold
  # what the render resolved — the one window in which a nested render can ask about its own
  # projection. `_render_scalar_subquery` reads the projected column's formatter through it.
  built::Union{Nothing,Function} = nothing,
  # #1002: passed through to `build()` — a membership subquery (`__@in`) is a semi-join.
  semi_join::Bool = false,
  # #1557: passed through to `build()` — the CTE whose body `build_cte_clause` renders here, and
  # whether the query declaring it is correlated.
  cte_body::String = "",
  cte_body_correlated::Bool = false
  )

  @pormg_debug false

  # Create a shared table alias counter for both CTEs and main query
  table_alias === nothing && (table_alias = SQLTbAlias())
  
  settings, connection, conn_key = get_settings(q, connection=connection)

  # Track if this is a subquery. A nested render passes the shared collector (PostgreSQL needs one
  # sequential `$N` counter); its build still files values under its OWN clauses, and `build()`
  # restores the ambient bucket on return (#936, #939), so the caller lifts them as one clause-ordered
  # run (#432, `detach_nested_run!`). That restore used to be a save/restore here, beside an
  # `own_contexts` opt-in; `with_bucket` made both structural.
  is_subquery = parameters !== nothing

  # IMPORTANT: Create the shared parameters object BEFORE building CTEs
  # This ensures all CTEs and the main query use sequential parameter numbering
  if parameters === nothing
    parameters = get_parameter(connection)
  end

  # Build WITH clause - passes the SAME parameters object
  # CTE context is set inside build_cte_clause
  !is_subquery && set_context!(parameters, :cte)
  with_clause, cte_state = build_cte_clause(q.object.ctes, connection, parameters, table_alias; correlated = outer !== nothing)

  @pormg_debug false

  # Main query uses the SAME parameters object (will continue numbering from where CTEs left off)
  # Context switching for select/where/join happens inside build()
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters, outer=outer,
                      semi_join=semi_join, cte_body=cte_body, cte_body_correlated=cte_body_correlated,
                      cte_state=cte_state)
  built === nothing || built(instruction)
  
  # Prevent SELECT * across JOINs which causes DataFrame column collisions downstream.
  # Only enforce during actual execution (:execute) — inspection/dry-run modes (:dict, :sql,
  # :inspection, etc.) must be allowed to build joined queries without .values() so that
  # inspect_query() and show_query=:dict work on un-projected joined queries.
  if isempty(q.object.values) && !isempty(instruction.join) && show_query === :execute
    throw(QueryBuildError("PormG: Joined queries must explicitly select fields using .values(...) to prevent duplicate column names. Tip: Use .values(\"*\", \"joined_model__field_name\") to select all main table fields alongside specific joined fields."))
  end

  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)  
  
  io = IOBuffer()
  print(io, with_clause)
  print(io, "SELECT\n    ")
  if q.object.distinct
    print(io, "DISTINCT ")
  end
  _query_select(io, instruction.select, instruction.connection)
  print(io, "\nFROM ", safe_table_name, " as ", safe_alias, "\n")
  
  for j in instruction.join
    print(io, j, "\n")
  end

  if !isempty(instruction._where)
    print(io, "WHERE ")
    for (i, w) in enumerate(instruction._where)
      i > 1 && print(io, " AND \n   ")
      print(io, w)
    end
    print(io, "\n")
  end
  
  if instruction.aggregate && !isempty(instruction.group)
    print(io, "GROUP BY ")
    for (i, g) in enumerate(instruction.group)
      i > 1 && print(io, ", ")
      print(io, g)
    end
    print(io, " \n")
  end
  
  if !isempty(instruction.having)
    print(io, "HAVING ")
    for (i, h) in enumerate(instruction.having)
      i > 1 && print(io, " AND \n   ")
      print(io, h)
    end
    print(io, "\n")
  end
  
  if !isempty(instruction.order)
    print(io, "ORDER BY ")
    for (i, o) in enumerate(instruction.order)
      i > 1 && print(io, ", \n  ")
      print(io, o)
    end
    print(io, "\n")
  end
  
  print(io, _limit_offset_sql(q.object.limit, q.object.offset, parameters, instruction.connection))

  # #26: row-level locking clause (FOR UPDATE …) must follow ORDER BY / LIMIT / OFFSET. No-op on
  # SQLite (Dialect.for_update_clause renders "" there). PostgreSQL rejects FOR UPDATE with
  # DISTINCT, so fail early with a friendly message rather than a raw DB error.
  let fu = q.object.for_update
    if fu !== nothing
      # PostgreSQL rejects FOR UPDATE + DISTINCT; fail early with a friendly message. SQLite is
      # exempt — there the lock renders "" (pure no-op), so DISTINCT does not raise (#26). An `of`
      # target that does not resolve raises on both engines (#169): that is a bug in the call, not
      # a lock the engine lacks — and so does a lock without `of` beside an outer join (#1106).
      if q.object.distinct && _locks_rows(instruction.connection)
        throw(QueryBuildError("select_for_update() cannot be combined with distinct() — a locking read must return concrete rows."))
      end
      isempty(fu.of) && _refuse_plain_lock_beside_outer_joins(instruction)
      of_aliases = isempty(fu.of) ? String[] : _lock_target_aliases(instruction, fu.of)
      print(io, Dialect.for_update_clause(fu.nowait, fu.skip_locked, fu.no_key, of_aliases, instruction.connection))
    end
  end

  resposta = String(take!(io))

  # #44: warn once per CTE that is CROSS JOINed (no join_field) yet is never constrained by a
  # WHERE/HAVING predicate — that is an unintended Cartesian product. The correlation is expected
  # to come from a `filter("main_col" => F("<cte>__col"))` (which renders in WHERE). No false
  # positive on the intended usage, where the alias appears in the WHERE fragment.
  if any(rj -> rj isa CrossJoin, instruction.row_join)
    predicate_text = string(
      isempty(instruction._where) ? "" : join(instruction._where, " AND "),
      isempty(instruction.having) ? "" : join(instruction.having, " AND "),
    )
    for rj in instruction.row_join
      rj isa CrossJoin || continue
      cte_alias = rj.alias_b
      if !occursin(quote_identifier(cte_alias, instruction.connection), predicate_text)
        @warn _emsg("PormG: CTE \e[31m$(rj.b)\e[0m is CROSS JOINed with no correlating filter — this is a Cartesian product. Add a correlation such as \e[32mfilter(\"main_col\" => F(\"$(rj.b)__col\"))\e[0m, or pass \e[32mjoin_field=\e[0m to .with().")
      end
    end
  end

  # #1624: nothing is written back into `q`. The parameters and the projection kinds are the
  # instruction's (`instruction.parameters`, `instruction.projection_kinds`), and the caller reads them
  # there.
  return (sql = resposta, instruction = instruction)
end
"""
    show_query(q::SQLObjectHandler, mode::Symbol = :sql)

Render a `SELECT` query without executing it. The default `:sql` mode returns just the SQL string,
which makes it the quickest way to see what a chain builds.

| `mode` | Returns |
|--------|---------|
| `:sql` | `String` — the generated SQL |
| `:pretty` | `String` — the same SQL reflowed one clause per line; only whitespace changes |
| `:params` | `Vector` — the parameterized values, in bucket order |
| `:dict` / `:inspection` | `Dict` — the full metadata shape of [`inspect_query`](@ref) |
| `:struct` | `String` — the struct a typed read (`list(T)`) accepts for this query, as source text to paste (#1632) |
| `:none` | `nothing` — builds and discards, for benchmarking the builder |

```julia
query = M.Driver.objects.filter("nationality" => "British").values("forename", "surname")

println(show_query(query))              # SELECT "Tb"."forename" … WHERE "Tb"."nationality" = \$1
params = show_query(query, :params)     # ["British"]
```

Inspection writes nothing into the query you pass (#43, #1624) — the same chain can be inspected
and then executed.

For `INSERT`/`UPDATE`/`DELETE`, pass `show_query=` to the terminal method itself
(`query.delete(show_query = :sql)`); this function always renders a `SELECT`. Use
[`inspect_query`](@ref) when you want the metadata `Dict` with an explicit operation override.
"""
show_query(q::SQLObjectHandler, mode::Symbol = :sql) = query(q; show_query=mode)   # #1624: no copy, the build writes nothing

# ---
# Count or check if exists
#

# #1053: the caller's slice, as the read terminals see it. A terminal runs on a copy, and before
# #1053 each one overwrote the copy's `limit` with its own probe size or cleared it, so
# `q.limit(0).exists()` answered `true` for the rows `q.limit(0).list()` does not return. The same
# predicate `update()`/`delete()` refuse a sliced handler on.
_is_sliced(object::SQLObject)::Bool = object.limit !== nothing || object.offset > 0

# The limit a terminal probing `k` rows applies on top of the caller's — Django's
# `set_limits(high=k)`: the smaller of the two, with the caller's offset left where it is.
_probe_limit(limit::Union{Nothing,Integer}, k::Integer)::Integer = limit === nothing ? k : min(limit, k)

# #1066: does the `values()` projection decide which rows `list()` returns? `count()`, `exists()` and
# `Exists(...)` clear the projection before they build, which is safe for a plain column list: it
# returns one row per matching row either way. Two projections change the row set, and clearing them
# made the terminal disagree with `list()`:
# - a DISTINCT one collapses duplicates of the projected columns, not of `*` (`count()` counted
#   `SELECT DISTINCT *`, and an offset `exists()` skipped rows `list()` collapses);
# - an aggregating one returns a row per group (`count()` counted the rows, and a HAVING filter on the
#   alias raised `UnknownFieldError` because the alias was gone).
# Asked before the build, from `_contains_agg` (the predicate `get_select_query` sets the aggregate
# flag from), because a kept projection binds its values under `:select` and must then be printed. `distinct` is
# the caller's choice: `exists()` without an offset gets the same answer from the non-distinct rows.
#
# #1082: except an aggregate with no GROUP BY and no HAVING (`values("t" => Count("id"))`). It is one
# row whatever matched — `COUNT` over no rows is 0, not zero rows — so keeping it made `Exists(sub)`
# always true. `Exists(sub)` clears such a projection (`clear_degenerate`), as Django's `Exists` clears
# the SELECT and keeps grouping and HAVING, so it asks whether any row matched. A HAVING (a filter on
# the alias) makes the row optional, so that projection is kept; `_refuse_degenerate_probe` catches a
# shape this cannot predict.
#
# #1100: the terminals do not clear it. Answering for the matched rows made `count()` return N where
# `list()` returns one row, and 1 once a true HAVING was added — two kinds of answer in one query
# family. They keep it, build it, and `_refuse_constant_terminal` refuses what builds as that one row,
# so `count() == length(list())` holds with no exception and `exists() == (count() > 0)` still does:
# both raise. Building first also makes a projection `list()` refuses (#798's mixed grouping) raise
# the same error from them.
#
# #1074: and a projection a filter names by alias is kept too, whatever it projects. The filter
# resolves the alias through the projection (`get_filter_query` → the projection memo), so clearing
# it raised `UnknownFieldError` for `values("pts1" => F("points") + 1).filter("pts1__@gt" => 2)`,
# which `list()` runs. Kept, each alias takes `list()`'s route: a row alias renders in WHERE, an
# aggregate one in HAVING, and a window one reaches #685's refusal. Re-rendering a row alias in WHERE
# without the projection (Django inlines it the same way) gives the same rows with leaner SQL, but
# alias resolution needs the memo entry only the printed SELECT creates. Keeping it was chosen for
# cost and safety, not on concept.
_projection_shapes_rows(object::SQLObject; distinct::Bool, clear_degenerate::Bool = true)::Bool =
  !isempty(object.values) && !(clear_degenerate && _degenerate_aggregate(object)) &&
  (distinct || _contains_agg(object.values) || _filters_name_alias(object))

# #1082: does any filter name a projection by its output name? Asked of the declaration, before the
# build, with the filter path's own two tests:
# - a plain key that names no model field (`_alias_filter_key`): an alias, or an unknown name. An alias
#   is the only way into HAVING — #537 refuses an aggregate written in a filter;
# - a model key that a projection also names without being that column (#703's
#   `_guard_field_alias_collision`): `values("points" => Sum("points")).filter("points__@gt" => 5)`.
#   That guard reads the projection list, so a cleared projection let the key silently mean the
#   column; kept, the build refuses it as `list()` does (review of #1082).
# `Exists(...)` in a filter is its own query.
function _filters_name_alias(object::SQLObject)::Bool
  instruc = _declaration_instruction(object)
  hit = false
  for f in object.filter
    f isa ExistsObject && continue
    _each_condition_leaf(f) do leaf
      hit && return nothing
      key = _plain_filter_key(leaf.column)
      if key !== nothing && !(key in object.model.field_names)
        hit = true
      elseif (mkey = _model_filter_key(leaf.column, instruc)) !== nothing
        hit = any(p -> _projection_output_name(p) == mkey && !_projects_column(p, mkey), object.values)
      end
      return nothing
    end
    hit && return true
  end
  return false
end

# An instruction over the declaration alone, for the pre-build questions above and below: `_resolved_agg`,
# `_model_filter_key` and `_projected_source` read only `object` (its values, filters and model). Nothing
# is built with it, so nothing binds.
_declaration_instruction(object::SQLObject) =
  InstructionObject(text = "", table_alias = SQLTbAlias(), alias = "Tb", object = object)

# #1082: is the projection an aggregate that the build will neither group nor filter with HAVING?
# Each entry's part in GROUP BY is `_group_role`'s answer, the one `get_select_query` builds from
# (#1099): degenerate when every entry is an aggregate or adds no term, and at least one aggregates.
# A window is not answered (its OVER terms can be grouped), nor any filter on an alias (a HAVING, or a
# literal's WHERE). Each unanswered shape keeps the projection, and `_refuse_degenerate_probe` refuses
# it if the build turns out ungrouped after all.
#
# `order_by()` terms are the one part still decided here, conservatively: `get_order_query` tells a
# projected term from one it groups by matching the RENDERED projection and the memo, which do not
# exist before the build. A term is taken as projected only when its name is an entry's output name,
# a literal's included; any other term keeps the projection. A labelled term
# (`SQLOrder(SQLField(Count("id"), "n"))`) never counts (#1138): the build renders what it holds,
# whatever the label. The drift guard in `test_fluent_parity_208.jl` compares this answer with the built
# instruction's.
function _degenerate_aggregate(object::SQLObject)::Bool
  isempty(object.values) && return false
  _filters_name_alias(object) && return false
  instruc = _declaration_instruction(object)
  names = String[]
  any_agg = false
  for v in object.values
    role = _group_role(v, instruc)
    role === :group && return false
    # A window's OVER terms can be grouped, and an aggregate can be a window too (`Rank(…) + Sum(…)`,
    # #756), so this is asked apart from the role.
    role !== :none && _resolved_window(v.field, instruc) && return false
    any_agg |= role === :aggregate
    name = v.custom_as !== nothing ? v.custom_as : v._as
    name === nothing || push!(names, String(name))
  end
  any_agg || return false
  return all(o -> o.field._as !== nothing && !_is_labelled_term(o.field) &&
                  String(o.field._as) in names, object.order)
end

# A kept projection that built as an aggregate with no GROUP BY and no HAVING: exactly one row whatever
# matched, so any answer about its rows is a constant.
_builds_one_row(instruction::SQLInstruction, keep_values::Bool)::Bool =
  keep_values && instruction.aggregate && isempty(instruction.group) && isempty(instruction.having)

# #1082: the check behind `_degenerate_aggregate`, for `Exists(...)`, which clears the shape it
# predicts. One it could not predict that still builds as one row is refused rather than answered.
function _refuse_degenerate_probe(instruction::SQLInstruction, keep_values::Bool, terminal::AbstractString)
  _builds_one_row(instruction, keep_values) || return nothing
  throw(QueryBuildError(
    "$(terminal) cannot answer for this query: its values() projection aggregates with no GROUP BY " *
    "and no HAVING, so it is exactly one row whatever matched, and the answer would be a constant. " *
    "Drop the aggregate from values() to ask about the matched rows, or filter on its alias to keep " *
    "only the row that passes (#1082)."))
end

# #1100: `count()` and `exists()` keep that projection and refuse it, whether or not it was predicted:
# its only honest answer is the constant `list()` gives, one row.
function _refuse_constant_terminal(instruction::SQLInstruction, keep_values::Bool, terminal::AbstractString)
  _builds_one_row(instruction, keep_values) || return nothing
  ask = terminal == "count()" ? "count the matched rows" : "ask whether any row matched"
  throw(QueryBuildError(
    "$(terminal) cannot answer for this query: its values() projection is an aggregate with no GROUP BY " *
    "and no HAVING, so it is exactly one row whatever matched (list() returns that one row, or none under " *
    "a slice), and the " *
    "answer would be a constant. To $(ask), drop the aggregate from values(); to keep the aggregate row " *
    "only when it passes a condition, filter on its alias; to read the aggregate's value, use " *
    ".aggregate(\"n\" => Count(...)) instead (#1100)."))
end

# #1066: an aggregating projection keeps its ordering too. An `order_by()` on a column it does not
# project is a GROUP BY term as well (`get_order_query`), so clearing it merged groups `list()` keeps
# apart. A kept ordering is printed, because its values bind under `:order`; elsewhere it is cleared.
_keeps_order(object::SQLObject, keep_values::Bool)::Bool = keep_values && _contains_agg(object.values)

# What an existence probe selects: `1`, or the kept projection — `DISTINCT` when the query is — whose
# GROUP BY names projection positions. Shared by `exists()` and `Exists(...)`. An unprojected
# `distinct()` probed past an offset skips the model's rows, as `count()` counts them (#1359): the base
# table's columns, `DISTINCT "Tb".*`, since `1` repeats a row once per related row across a to-many join.
function _exists_projection(object::SQLObject, instruction::SQLInstruction, keep::Bool)::String
  if keep
    io = IOBuffer()
    object.distinct && print(io, "DISTINCT ")
    _query_select(io, instruction.select, instruction.connection)
    return String(take!(io))
  end
  object.distinct && object.offset > 0 && return "DISTINCT $(quote_identifier(instruction.alias, instruction.connection)).*"
  return "1"
end

# The terminals that cannot honor a slice refuse it instead of ignoring it. `last()`, `earliest()` and
# `latest()` reorder the rows, which changes which rows the slice holds — Django refuses them too.
# `count(column)` and `aggregate()` refuse it by design (#1066): Django's `aggregate()` (its spelling of
# both) computes over the slice through a derived table, but here the same result is one call away —
# aggregate the query before slicing it — so the derived table is not worth building.
function _refuse_sliced(object::SQLObject, terminal::AbstractString, why::AbstractString)
  _is_sliced(object) || return nothing
  throw(QueryBuildError(
    "$(terminal) cannot run on a query with limit() or offset() set: $(why). " *
    "Call it on the query before slicing it, or clear the slice with limit(nothing).offset(0) first."))
end

function _count(oq::SQLObjectHandler; column::Union{Nothing, AbstractString} = nothing, distinct::Bool = false,
                  table_alias::Union{Nothing, SQLTableAlias} = nothing, show_query::Symbol = :execute)
  # Column form: COUNT([DISTINCT] column). Reuse the Count() aggregate so column
  # resolution, joins and dialect rendering are shared with values(Count(...)); we
  # return the scalar rather than a row. COUNT(DISTINCT col) is valid SQL (unlike
  # COUNT(DISTINCT *)), so no subquery is needed for this form.
  if column !== nothing
    _refuse_sliced(oq.object, "count(column)", "the column is counted over every matching row, not over the slice")
    cq = _terminal_copy(oq)   # #1624: shallow; the build writes nothing
    cq.object.order = []
    cq.object.distinct = false      # DISTINCT belongs to COUNT(col), not the row set
    cq.object.limit = nothing
    cq.object.offset = 0
    # No `__` in the alias: `_values!` refuses one (#757). The result is read positionally below.
    _values!(cq.object, Any["pormg_count" => Count(String(column); distinct = distinct)])
    show_query === :struct && throw(_struct_mode_refusal())   # #1632: a count is no row
    show_query !== :execute && return query(cq; table_alias = table_alias, show_query = show_query)
    rows = _list_owned(cq, Val(:dict))
    return isempty(rows) ? 0 : Base.first(values(Base.first(rows)))
  end

  # Resolve settings
  settings, connection, conn_key = get_settings(oq)
  
  q = _terminal_copy(oq)   # #1624: its own changes (order, values) stay off the caller's handler
  # #1066: the projection is kept when it decides which rows `list()` returns — see
  # `_projection_shapes_rows`. Otherwise it is cleared, and a plain `values(...)` counts as before.
  is_distinct = distinct || q.object.distinct
  keep_values = _projection_shapes_rows(q.object; distinct = is_distinct, clear_degenerate = false)
  _keeps_order(q.object, keep_values) || (q.object.order = []) # clear order_by
  keep_values || (q.object.values = [])

  # Create shared table alias and parameters BEFORE building CTEs
  # so CTE parameters are numbered first (critical for positional backends).
  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters = get_parameter(connection)

  # Build WITH clause first — CTE params land in :cte bucket before main params.
  set_context!(parameters, :cte)
  with_clause, cte_state = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

  # Main query continues from where CTE numbering left off. #1002: `count()` counts the rows `list()`
  # returns, so a projection cleared above still declares the joins it reaches.
  instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters,
                      cte_state = cte_state, distinct_rows = is_distinct,
                      declared_paths = keep_values ? String[] : _projected_paths(oq.object.values))
  _refuse_constant_terminal(instruction, keep_values, "count()")
  
  # Quote table name and alias to prevent SQL injection
  safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)
  
  # Shared FROM / JOIN / WHERE / GROUP BY / HAVING body for every count form. GROUP BY and HAVING
  # are only ever filled for a kept, aggregating projection (#1066); the guard matches `query()`'s, as
  # a whole-table aggregate (`values("n" => Count("id"))`) groups by nothing.
  body = """FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    $(instruction.aggregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", ")) \n" : "")$(isempty(instruction.having) ? "" : "HAVING $(join(instruction.having, " AND \n   "))\n")$(isempty(instruction.order) ? "" : "ORDER BY $(join(instruction.order, ", "))\n")
    """
  if is_distinct || keep_values
    # COUNT(DISTINCT *) is invalid SQL in both PostgreSQL and SQLite, and a grouped projection has one
    # row per group, not per matching row. Either way the rows `list()` would return are counted from
    # a derived table, so count() == length(list()). With no values() an unprojected `distinct()` counts
    # the model's rows, as Django's does: `SELECT DISTINCT "Tb".*`, the base table's columns only. A bare
    # `*` also took every joined table's columns, so across a to-many join no row was ever a duplicate and
    # the count was one per (row, related row) pair; on MySQL two joined columns of the same name are
    # error 1060 in a derived table. A kept projection's GROUP BY names projection positions, which is
    # why that projection is printed rather than replaced by `1`.
    # Any CTEs stay at the top level and remain in scope for the subquery; the projection's values bind
    # under `:select`, ahead of the WHERE ones, which is where its text sits.
    # #1074: a projection kept because a filter names its alias counts the same way, named for what it is.
    # #1053: a slice applies after DISTINCT and GROUP BY, so its tail goes inside the subquery. Its
    # markers are the last in the text and bind under `:limit`, the last bucket, so the order holds on
    # both engines.
    projection = keep_values ? _query_select(instruction.select, instruction.connection) : "$(safe_alias).*"
    resposta = """$(with_clause)SELECT COUNT(*) FROM (
    SELECT $(is_distinct ? "DISTINCT " : "")$(projection)
    $body$(_limit_offset_sql(q.object.limit, q.object.offset, parameters, instruction.connection))) as $(quote_identifier(is_distinct ? "__pormg_distinct_count" : instruction.aggregate ? "__pormg_grouped_count" : "__pormg_projected_count", instruction.connection))
    """
  elseif _is_sliced(q.object)
    # #1053: count the rows the slice returns, as Django's `qs[:5].count()` does. The ordering was
    # cleared above, and that is safe: how many rows a slice holds does not depend on which they are.
    resposta = """$(with_clause)SELECT COUNT(*) FROM (
    SELECT 1
    $body$(_limit_offset_sql(q.object.limit, q.object.offset, parameters, instruction.connection))) as $(quote_identifier("__pormg_sliced_count", instruction.connection))
    """
  else
    resposta = """$(with_clause)SELECT
      COUNT(*)
    $body"""
  end
  # Inspection short-circuit: return SQL/metadata without hitting the database.
  if show_query !== :execute
    return _show_query_result(show_query, resposta, instruction.connection, q.object.model.name, :select;
                            parameters=instruction.parameters)
  end
  query_result = fetch(settings, resposta, instruction.parameters)
  # PostgreSQL returns a LibPQ.Result that supports scalar [row, col] indexing.
  # SQLite returns a materialized rowtable (Vector{<:NamedTuple}); a Vector *also* has a
  # (Int, Int) getindex method (trailing-singleton dimension), so exclude vectors explicitly
  # and take the Tables path, which extracts the scalar from the single COUNT row.
  if !(query_result isa AbstractVector) &&
     (query_result isa AbstractMatrix || hasmethod(getindex, Tuple{typeof(query_result), Int, Int}))
    return query_result[1, 1]
  else
    row = Tables.rowtable(query_result) |> Base.first
    return Base.first(values(row))
  end
end

# Whole-queryset aggregation (#208). Django's aggregate(): compute one or more aggregate scalars
# over the ENTIRE queryset (no GROUP BY) and return them as a single-row NamedTuple keyed by alias.
# Built on the same column-form path as _count() — inject the aggregate projections via values(),
# read the single row back — but generalized to multiple aggregates and a dot-accessible result.
function _aggregate(oq::SQLObjectHandler; pairs, show_query::Symbol = :execute)
  isempty(pairs) &&
    throw(QueryBuildError("aggregate() requires at least one \"alias\" => AggregateFunction(...) pair, e.g. aggregate(\"total\" => Sum(\"points\"))."))
  # aggregate() is whole-queryset only. If the caller already projected grouping columns via
  # values(), that is a DIFFERENT operation (grouped aggregation) — refuse rather than silently
  # discard their grouping. Steer them to values(...) + list() for the grouped form.
  isempty(oq.object.values) ||
    throw(QueryBuildError("aggregate() computes a single whole-queryset result and cannot combine with values() grouping columns. Use values(...) + list() for grouped aggregation, or call aggregate() on an unprojected queryset."))

  aliases = Symbol[]
  for p in pairs
    (p isa Pair && p.first isa AbstractString) ||
      throw(QueryBuildError("aggregate() arguments must be \"alias\" => AggregateFunction(...) pairs; got $(typeof(p))."))
    val = p.second
    (val isa SQLTypeFunction && hasproperty(val, :aggregate) && getproperty(val, :aggregate) === true) ||
      throw(QueryBuildError("aggregate() value for \"$(p.first)\" must be an aggregate function (Sum/Avg/Count/Max/Min); got $(typeof(val)). For per-row expressions use values(...)."))
    push!(aliases, Symbol(p.first))
  end
  _refuse_sliced(oq.object, "aggregate()", "the aggregate is computed over every matching row, not over the slice")

  cq = _terminal_copy(oq)   # #1624: shallow; the build writes nothing
  cq.object.order = []
  cq.object.limit = nothing
  cq.object.offset = 0
  cq.object.distinct = false
  # Inject the aggregate projections through the shared values() path (column resolution, joins and
  # dialect rendering stay identical to values(Sum(...))). With ONLY aggregates projected, no
  # non-aggregate column is present, so the builder emits no GROUP BY (same as _count).
  _values!(cq.object, collect(Any, pairs))

  if show_query !== :execute
    show_query === :struct && throw(_struct_mode_refusal())   # #1632: one NamedTuple, not rows to declare
    return query(cq; show_query=show_query)
  end

  rows = _list_owned(cq, Val(:dict))
  # A SQL aggregate over an empty set still returns one row (COUNT→0, others→NULL); guard anyway.
  row = isempty(rows) ? Dict{Symbol,Any}() : Base.first(rows)
  return NamedTuple{Tuple(aliases)}(Tuple(get(row, a, nothing) for a in aliases))
end

function _exists(oq::SQLObjectHandler; table_alias::Union{Nothing, SQLTableAlias} = nothing, show_query::Symbol = :execute)
  try
    # Resolve settings
    settings, connection, conn_key = get_settings(oq)
    
    q = _terminal_copy(oq)   # #1624: its own changes (order, values) stay off the caller's handler
    # #1066: a kept projection is probed as `list()` would run it — see `_projection_shapes_rows`.
    keep_values = _projection_shapes_rows(q.object; distinct = q.object.distinct && q.object.offset > 0, clear_degenerate = false)
    _keeps_order(q.object, keep_values) || (q.object.order = []) # clear order_by
    keep_values || (q.object.values = [])

    # Create shared table alias and parameters BEFORE building CTEs
    # so CTE parameters are numbered first (critical for positional backends).
    table_alias === nothing && (table_alias = SQLTbAlias())
    parameters = get_parameter(connection)

    # Build WITH clause first — CTE params land in :cte bucket before main params.
    set_context!(parameters, :cte)
    with_clause, cte_state = build_cte_clause(q.object.ctes, connection, parameters, table_alias)

    # Main query continues from where CTE numbering left off. #1002: `exists()` is a semi-join unless an
    # OFFSET counts the rows; then it answers for the rows `list()` returns, whose cleared projection
    # still declares its joins.
    instruction = build(q.object, table_alias=table_alias, connection=connection, parameters=parameters,
                        cte_state = cte_state, semi_join = q.object.offset <= 0,
                        declared_paths = keep_values ? String[] : _projected_paths(oq.object.values))
    _refuse_constant_terminal(instruction, keep_values, "exists()")
    # `LIMIT 1` is this query's own shape, not a user value, so it stays literal; the OFFSET the
    # caller set binds (#46). A non-positive offset was always dropped here, and still is.
    # #1053: a caller's `limit(0)` makes it `LIMIT 0` — the probe is the smaller of the two, so it is
    # one of two literals the code chooses, never the caller's value interpolated.
    limit_clause = _probe_limit(q.object.limit, 1) == 0 ? "LIMIT 0" : "LIMIT 1"
    offset_clause = q.object.offset > 0 ?
      with_bucket(() -> "OFFSET " * add_parameter!(parameters, q.object.offset), parameters, :limit) : ""
    
    # Quote table name and alias to prevent SQL injection
    safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
    safe_alias = quote_identifier(instruction.alias, instruction.connection)
    
    sql = """
    $(with_clause)SELECT $(_exists_projection(q.object, instruction, keep_values))
    FROM $safe_table_name as $safe_alias
    $(join(instruction.join, "\n"))
    $(isempty(instruction._where) ? "" : "WHERE " * join(instruction._where, " AND \n   "))
    $(instruction.aggregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", "))" : "")$(isempty(instruction.having) ? "" : "\nHAVING " * join(instruction.having, " AND \n   "))$(isempty(instruction.order) ? "" : "\nORDER BY " * join(instruction.order, ", "))
    $limit_clause
    $offset_clause
    """
    # Inspection short-circuit: return SQL/metadata without hitting the database.
    if show_query !== :execute
      return _show_query_result(show_query, sql, instruction.connection, q.object.model.name, :select;
                              parameters=instruction.parameters)
    end
    @pormg_debug false
    result = fetch(settings, sql, instruction.parameters) |> Tables.rowtable
    @pormg_debug false
    return length(result) > 0
  catch e
    @pormg_debug false
    # Rethrow unconditionally. Silently returning false would mask connection failures, SQL errors
    # and permission errors as "does not exist", which is incorrect and dangerous; the only
    # legitimate false return is from `length(result) > 0` above.
    # #1107: and do not log first. The caller gets the exception, and logging it is the
    # application's call — as for `count()` and `list()`. The `@error` this replaced printed a
    # backtrace ahead of every build-time refusal, even under `show_query = :sql`.
    rethrow(e)
  end
end

# #564 — the shared body of `query_list`, returning the build's instruction alongside the result: the
# read path needs the kind of each projection (`instruction.projection_kinds`) after the build to pick
# its parsers (`_projection_parsers`). Until #1624 the build wrote that map back onto the handler,
# and this function returned the copy it had built on; now the instruction carries it.
#
# #612: the docstring that used to sit above this comment belongs to `query_list`, not to
# this helper — its example ends `query |> DataFrame`. The split left it stranded here, so
# BOTH functions were undocumented: this one by accident, `query_list` by omission.
#
# #1624: no copy. The read path never writes into the caller's handler (#43, #199) because the build
# writes into nothing (`_render_select`): it used to write back `parameters`, the projection kinds and
# the CTE state, and this function deep-copied the handler for that reason. It returns the build's
# instruction, which carries what the read needs afterwards (`_projection_parsers`).
function _execute_select(q::SQLObjectHandler)
  settings, connection, conn_key = get_settings(q)
  rendered = _render_select(q, connection=connection, show_query=:execute)
  _refuse_lock_outside_transaction(q, rendered.instruction)
  return fetch(settings, rendered.sql, rendered.instruction.parameters), rendered.instruction, connection
end

# #1624 — the copy a read terminal makes so its OWN changes (a limit, an ordering, inline filters, a
# projection) never reach the caller's handler (#43, #199). Since the build writes nothing, it no longer
# needs to be deep: a new handler and query struct, every slot shared with the caller's, and fresh
# containers only where a terminal changes one in place — `filter` (`_get`'s inline filters are pushed
# by `_filter!`) and `order` (`_last` inverts it with `map!`). Every other change a terminal makes
# assigns a slot of the new struct (`limit`, `offset`, `distinct`, the vector `_values!` and
# `_order_by!` replace). One `deepcopy(handler)` was ~27 µs of a primary-key read on Postgres.jl (#41).
function _terminal_copy(h::SQLObjectHandler)::SQLObjectHandler
  q = h.object
  return ObjectHandler(object = SQLObjectQuery(model=q.model, connect_key=q.connect_key, values=q.values,
    filter=copy(q.filter), insert=q.insert, limit=q.limit, offset=q.offset, order=copy(q.order), group=q.group,
    having=q.having, list_joins=q.list_joins, distinct=q.distinct, for_update=q.for_update, ctes=q.ctes,
    custom_join=q.custom_join, alias_join=q.alias_join, parameters=nothing, projection_kinds=q.projection_kinds))
end

"""
Fetches a list of records from the database for the given `SQLObjectHandler`.

# Returns
- The result of the database query as returned by `fetch`.

# Example
```julia
query = M.Result |> object
query.filter("raceid__year" => 2020)
query.values("driverid__forename", "constructorid__name", "laps" => Count("laps"))
query.order_by("-laps")
df = query |> DataFrame
```
"""
function query_list(objct::SQLObjectHandler; show_query::Symbol = :execute)
  show_query !== :execute && return _show_select(objct, show_query)
  return first(_execute_select(objct))
end

# The inspection render (`show_query = :sql`, `:dict`, …). No copy since #1624: the build writes nothing.
function _show_select(q::SQLObjectHandler, show_query::Symbol)
  settings, connection, conn_key = get_settings(q)
  return query(q, connection=connection, show_query=show_query)
end

# #1344 — a query is a Tables.jl source. `DataFrame(query)` is DataFrames' own `DataFrame(table)`, and
# `CSV.write(io, query)`, `Tables.rowtable(query)` or any other sink reads a query the same way, with no
# PormG method on any of them, and PormG does not depend on DataFrames (#1344 phase 6). The contract
# a user reads is on `SQLObjectHandler`'s docstring.
#
# Column access only: `Tables.rows` falls back to the columns, and the columns are the cheap read
# (#1073 measured a row walk of a `LibPQ.Result` at 20× the column read). Each call executes the query
# once; a source that executed on `istable` or `schema` would hit the database for a question about type.
Tables.istable(::Type{<:SQLObjectHandler}) = true
Tables.columnaccess(::Type{<:SQLObjectHandler}) = true

function Tables.columns(objct::SQLObjectHandler)
  result, built, connection = _execute_select(objct)
  columns = Tables.columns(result)
  parsers = _projection_parsers(built, connection)
  # Nothing to coerce (PostgreSQL unless an INTERVAL, an ARRAY or a computed float is projected): the
  # driver's own columns, exactly what `DataFrame(result)` read before #1344, so that frame is unchanged
  # by construction.
  parsers === nothing && return columns
  return _parsed_columns(columns, parsers)
end

# #564 / #582 — the driver's columns with each parsed one replaced by `map(parser, column)`; the others
# are passed through uncopied. A parser whose name is not a result column never fires: the wildcard
# recorder registers both a field's name and its `db_column`, and only one of them is in any given
# result (the same guard as `_rows_from_result`). `map` widens a column from `Union{Missing,String}` to
# `Union{Missing,T}`; the parsers pass `missing` through untouched.
#
# Columns Tables.jl built from rows (SQLite's materialized result) arrive as `CopiedColumns`, which tells
# a sink not to copy them again; rewrapping keeps that, so `DataFrame(query)` on SQLite copies nothing it
# did not copy before. A driver's own columns (LibPQ, MySQL) are not copies and are not wrapped.
function _parsed_columns(columns, parsers::Dict{Symbol,Function})
  names = Tuple(Symbol(name) for name in Tables.columnnames(columns))
  parsed = map(names) do name
    column = Tables.getcolumn(columns, name)
    parser = Base.get(parsers, name, nothing)
    parser === nothing ? column : map(parser, column)
  end
  table = NamedTuple{names}(parsed)
  return columns isa Tables.CopiedColumns ? Tables.CopiedColumns(table) : table
end

# #564 / #582 — which result-row columns need a read-side parser on THIS connection, or `nothing`
# when none does. The one selection the row terminals (`_list_raw`), the typed read (`list(T)`, #1544)
# and the Tables.jl source (`Tables.columns(query)`, which `DataFrame(query)` reads) consult, so they
# cannot disagree about what is coerced.
#
# The build records the canonical kind of each projection (`projection_kinds`), and the
# representation table (`value_repr.jl`) says which parser undoes that kind on this backend. Django
# resolves its own read coercion the same way — off `expression.output_field`, never off the
# alias's spelling. There is no `connection isa PormGSQLite` test here: the backend dimension
# belongs to the table, so a third backend becomes table entries rather than a branch. On
# PostgreSQL only INTERVAL (#581 pins that one type across drivers), an ARRAY (#28) and a computed
# number that means a float (#1121) have a parser, so a query projecting none of those returns
# `nothing` after one dispatch per projection.
function _projection_parsers(built::SQLInstruction, connection)::Union{Nothing,Dict{Symbol,Function}}
  parsers = nothing
  for (name, kind) in built.projection_kinds   # #1624: the build's own record, not a write-back
    parser = value_parser(kind, connection, name)   # #1110: a parser that raises names the projection
    parser === nothing && continue
    parsers === nothing && (parsers = Dict{Symbol,Function}())
    parsers[name] = parser
  end
  return parsers
end

function _list_raw(q::SQLObjectHandler)
  result, built, connection = _execute_select(q)
  # #564 — COERCE BY WHAT EACH PROJECTION EVALUATES TO, not by whether its alias happens to name a
  # plain column.
  #
  # What this replaces (`_sqlite_datetime_aliases`) had four gates, ALL of which had to pass: the
  # projection had to be an `SQLTypeField`, its `.field` had to be a plain `String`, that string had
  # to contain no `__`, and the field had to be an `sDateTimeField`. So the coercion set was exactly
  # "bare, unjoined, primary-model `DateTimeField` columns" — every expression alias, every joined
  # column, and every `DateField`/`TimeField`/`DurationField` fell outside it and came back as raw
  # text, while PostgreSQL's driver delivered typed values for all of them.
  #
  # The parser selection lives in `_projection_parsers` (above), shared with the Tables.jl source
  # since #582 so the row and tabular terminals coerce the same columns.
  return _rows_from_result(result, _projection_parsers(built, connection))
end

# #1073 — a driver result as `Dict{Symbol,Any}` rows, read COLUMN-WISE, the way `DataFrame(query)`
# reads it. This used to be `Tables.rowtable(result)` and a `Dict` per row, and on LibPQ the row walk
# was about 40% of a `list()` call — 2.57 ms and 16 636 allocations for 361 two-column rows, against
# 0.12 ms and 4 733 read by column (`test/performance/read_path_list.jl`): iterating a `LibPQ.Result`
# by row resolves each cell's type at run time, while a column has one element type.
# `_fill_column!` is the function barrier — one dynamic dispatch per column, then a loop typed on
# the column — and it applies the #564 parser to the column it fills, once per column.
#
# `Dict{Symbol,Any}` EXPLICITLY, and it is an ENABLING choice rather than a style one: a `Dict`
# narrowed to its values' type (`Dict{Symbol,String}` for an all-TEXT projection) throws when a
# parser writes a `ZonedDateTime` into it, and it makes `list(:dict)` return what its docstring
# promises. Each `Dict` is sized and filled exactly as `Dict{Symbol,Any}(generator)` sized and
# filled it before (a `sizehint!` to the column count, keys in column order), so its key iteration
# order — and the key order `list(:json)` writes — is unchanged.
#
# A parser whose name is not a result column never fires: the wildcard recorder registers both a
# field's name and its `db_column`, and only one of them is in any given result.
function _rows_from_result(result, parsers::Union{Nothing,Dict{Symbol,Function}})::Vector{Dict{Symbol,Any}}
  columns = Tables.columntable(result)
  names = keys(columns)
  rows = Vector{Dict{Symbol,Any}}(undef, Tables.rowcount(columns))
  for i in eachindex(rows)
    row = Dict{Symbol,Any}()
    sizehint!(row, length(names))
    rows[i] = row
  end
  for name in names
    parser = parsers === nothing ? nothing : Base.get(parsers, name, nothing)
    _fill_column!(rows, name, columns[name], parser)
  end
  return rows
end

# A result that is already rows — the SQLite extension's (`_sqlite_execute_materialized`) — is walked
# as rows. SQLite types each cell, so its `Vector` has an abstract element type (every row its own
# `NamedTuple` type) and reading it by column re-derives each column's type by widening: 1 026
# four-column rows took 922 µs that way against 625 µs as rows. The body is the row walk `_list_raw`
# did before #1073, so a SQLite read is unchanged.
function _rows_from_result(result::AbstractVector{<:NamedTuple}, parsers::Union{Nothing,Dict{Symbol,Function}})::Vector{Dict{Symbol,Any}}
  rows = [Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row)) for row in result]
  parsers === nothing && return rows
  for row in rows, (name, parser) in parsers
    haskey(row, name) && (row[name] = parser(row[name]))
  end
  return rows
end

function _fill_column!(rows::Vector{Dict{Symbol,Any}}, name::Symbol, column, ::Nothing)
  for (row, value) in zip(rows, column)
    row[name] = value
  end
  return rows
end

function _fill_column!(rows::Vector{Dict{Symbol,Any}}, name::Symbol, column, parser::Function)
  for (row, value) in zip(rows, column)
    row[name] = parser(value)
  end
  return rows
end

"""Return model-aware `PormGRow` objects. Default format."""
list(objct::SQLObjectHandler, ::Val{:row}; show_query::Symbol = :execute) =
  _list_owned(objct, Val(:row); show_query=show_query)

"""Return plain `Dict{Symbol,Any}` rows for framework integrations that need real dictionaries."""
list(objct::SQLObjectHandler, ::Val{:dict}; show_query::Symbol = :execute) =
  _list_owned(objct, Val(:dict); show_query=show_query)

# Every `list` format's body. #1589 named it for the copy it was handed; since #1624 the build writes
# nothing, so the public `list` hands it the caller's handler as is, and a terminal (`_get`, `_first`,
# `_count`, …) hands it the copy it made for its own changes (limit, ordering, inline filters).
function _list_owned(q::SQLObjectHandler, ::Val{:row}; show_query::Symbol = :execute)
  show_query !== :execute && return _show_select(q, show_query)
  model = q.object.model
  return [PormGRow(row, model) for row in _list_raw(q)]
end

function _list_owned(q::SQLObjectHandler, ::Val{:dict}; show_query::Symbol = :execute)
  show_query !== :execute && return _show_select(q, show_query)
  return _list_raw(q)
end

# #564 — a temporal value is serialized as the TEXT its own formatter writes, not by whatever
# `JSON.json` makes of the Julia type.
#
# `Date`, `Time` and `ZonedDateTime` all have a `JSON` representation that happens to be right, but
# `Dates.CompoundPeriod` does not: `JSON.json` has no method for it and falls back to struct
# reflection, which emits `{"periods":[{"value":1},{"value":49}]}` — **the units are gone**, and no
# consumer can reconstruct a duration from that. On PostgreSQL that has always been the shape (LibPQ
# delivers a `CompoundPeriod`); on SQLite it became reachable when #564 started coercing
# `DurationField`. Parity with a lossy shape is not the parity this table is for.
#
# So the JSON arm asks the same owner every other representation question goes through. For the three
# kinds that already serialized correctly this is a no-op that now HOLDS rather than coincides.
# FAIL-OPEN, like every parser in this table, and for a sharper reason here: `format_duration_sql`
# REFUSES a month or year component ("Months and years are ambiguous"), because `DurationField`
# deliberately does not store one. But this function dispatches on the Julia VALUE, not on a column
# kind — so a PostgreSQL `interval` holding `'1 month'`, from a column PormG did not write or a
# database it introspected, reaches it. Formatting unconditionally would turn a working
# `list(:json)` into a hard error, which is a worse regression than the lossy shape this fixes.
#
# So: format what the formatter accepts, hand back anything else untouched. The `JSON` fallback for
# an unformattable period is still poor, but it is what shipped before and it is not an exception.
_json_value(v) = v
function _json_value(v::Union{Dates.Period, Dates.CompoundPeriod})
  try
    return Models.format_duration_sql(v)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    return v
  end
end

# #644 — a `DecimalField` serializes as its EXACT decimal digits, emitted as a JSON number.
#
# The issue reported `{"s":0,"c":12345,"q":-2}` from struct reflection. That is NOT what happens, and
# the truth is worse in one direction and much narrower in another. `Decimals.Decimal <: AbstractFloat`,
# so `JSON` takes its number path and routes the value through a `Float64`:
#
#   exact 12345678901234567.89  ->  1.2345678901234568e16   (the last digits are wrong)
#   exact 5                     ->  5.0
#
# So a `DecimalField(10, 2)` — the constructor default, and every width up to ~16 significant digits —
# is CORRECT today; the defect appears only past what a `Float64` holds. That is exactly the drift
# `DecimalField` exists to prevent (`docs/src/index.md` promises it), so it is still silent wrong
# data — just not by the mechanism, nor at the width, the issue describes.
#
# At the declared `[compat] JSON = "1"` FLOOR it is not lossy but fatal: measured, JSON 1.0.0 raises
# `MethodError: no method matching +(::Nothing, ::Int64)` on any `Decimal`, so `list(:json)` over a
# PostgreSQL `DecimalField` cannot run at all there; 1.1.0 onward emits the lossy number. CI's
# `floor-resolve` job resolves that floor, and this arm is what makes it honest: every path a real
# value can take now hands `JSON` a `JSONText` or a `String`, both of which render at 1.0.0. Only the
# degenerate paths below — the formatter returning a non-string, or throwing — still pass the `Decimal`
# through, and neither is reachable from a driver. That distinction is not academic: the first version
# of this arm returned the `Decimal` on the rejected-text path too, and `floor-resolve` went red.
#
# `JSON.JSONText`, not a string: it splices the digits UNQUOTED, so the column stays a JSON NUMBER on
# both engines — SQLite's NUMERIC affinity hands back an `Int64`/`Float64`, which already serialized as
# a number, and a string here would have changed the column's JSON TYPE on PostgreSQL only. Django's
# `DjangoJSONEncoder` and DRF's `COERCE_DECIMAL_TO_STRING` both choose a string, which is exact
# end-to-end but obliges every consumer to parse; the maintainer chose the number on that trade (#644).
#
# Be precise about what that buys, because the first version of this comment over-claimed it: on its
# own, this arm made the two engines agree on the JSON *type*, not on the TEXT. Julia prints a
# `Float64` at or above 1e6 in exponent form, so from a million up SQLite emitted `1.23456789e6` where
# PostgreSQL emitted `1234567.89`. #648 closed that for every column PormG creates: SQLite reads a
# `DecimalField` of at most 15 digits back as a `Decimal` too (`Dialect._parse_sqlite_decimal`), so
# both engines reach this arm and emit the same text. What still arrives as a `Float64` — a wider
# column created outside PormG, an aggregate or arithmetic result, a `create()` row — keeps SQLite's
# rendering. `docs/src/read/index.md` states the boundary user-facing.
#
# GUARDED, because `JSONText` is a raw splice with no escaping: text that is not a JSON number would
# produce an INVALID DOCUMENT, strictly worse than the lossy value this fixes.
#
# The guard is not hypothetical across the declared `Decimals = "0.4, 0.5"` range, because the two
# majors do not print the same text. 0.4.1 renders positionally via `Base.print`; 0.5.x renders via
# `Base.string` -> `scientific_notation`, which uses exponent form whenever the exponent is positive.
# Measured: 0.4.1 prints `Decimal(0, 1, -20)` as `0.00000000000000000001` where 0.5.0 prints `1E-20`.
# Both are valid JSON numbers, which is the point — the pattern is the JSON spec's own number
# production rather than "whatever Decimals printed when this was written".
#
# The SHAPE is therefore version-dependent even though the VALUE is not, and the difference is not
# confined to extremes: `parse` normalises, so PostgreSQL's `"10.00"` from a `NUMERIC(10,2)` arrives as
# `Decimal(0, 1, 1)` — exponent 1 — which 0.4.1 prints `10` and 0.5.x would print `1E+1`. Numerically
# equal, valid JSON either way, and unreachable today because every LibPQ release pins `Decimals 0.4`
# (see `test/unit/test_compat_guards.jl`), and the `Decimal` SQLite yields since #648 is built with a
# non-positive exponent on purpose (`Decimal(0, 10, 0)`, which prints `10` on both). Worth knowing
# before anyone widens that pin: the engines would still agree with each other, but the emitted text
# would change. `Project.toml` cannot carry this note — CompatHelper strips comments — so it is here.
#
# FAIL-OPEN like the arm above: anything the guard rejects, and any throw, hands back the untouched
# value, which serializes exactly as it did before.
# `\A` and `\z`, NOT `^` and `$`. PCRE's `$` matches before a trailing newline, so the `^…$` spelling
# accepts `"1\n"` — verified. That particular string splices to `{"v":1\n}`, which is still valid JSON
# (a newline is whitespace there), and `Decimals` cannot produce it anyway, so this is not a live
# hole. It is tightened regardless: this guard's entire job is to answer "is this PROVABLY valid JSON
# number text", and a pattern that accepts a string it was not meant to accept cannot answer that.
# `[0-9]` rather than `\d`, and this one is LOAD-BEARING rather than stylistic — do not "simplify" it.
# Julia compiles regexes with PCRE's UCP flag, so `\d` is UNICODE-aware here: measured,
# `occursin(r"\A\d+\z", "١٢٣")` is `true`. With `\d` the pattern would accept `"1٢"` — the ASCII `[1-9]`
# satisfies the lead and `\d*` swallows the Arabic-Indic digit — and splice it raw as a JSON number,
# which is exactly the invalid document this guard exists to prevent. `[0-9]` rejects it.
const _JSON_NUMBER_RE = r"\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?\z"

# The rejected-text fallback is the decimal's TEXT, not the `Decimal` — and CI's `floor-resolve` job is
# what established that it has to be. Handing the value back unchanged looks like the obvious fail-open
# and is the opposite of one at the declared floor: JSON 1.0.0 raises
# `MethodError: no method matching +(::Nothing, ::Int64)` on any `Decimal`, so the "safe" path was a
# HARD ERROR there — precisely the regression the #564 arm above refuses to introduce. The text is
# exact, always renders, and renders at every version in the range; it is a JSON string rather than a
# number only for a value whose text is not a JSON number in the first place, so there is no consistency
# being given up. Unreachable from a driver either way (`parse` normalises), which is why only a
# constructed value and a CI job resolving the floor could find it.
#
# The two remaining `return v` paths — no text at all, because the formatter returned a non-string or
# threw — keep the pre-#644 behavior, since there is nothing better to hand over than what shipped.
function _json_value(v::Decimals.Decimal)
  try
    txt = Models.format_number_sql(v)
    txt isa AbstractString || return v
    return occursin(_JSON_NUMBER_RE, txt) ? JSON.JSONText(txt) : String(txt)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    return v
  end
end

# The ONE row -> JSON shape, and the only place it is written. Two emitters call it: `list(:json)`
# below, on a raw `_list_raw` dict, and the `lower` hook further down, on a `PormGRow`'s `_data`.
#
# One function rather than the same comprehension in both, because "the same JSON either way" is the
# contract and a restated rule drifts silently while still type-checking (the #474 defect shape).
_json_row(data::Dict{Symbol, Any}) = Dict(String(k) => _json_value(v) for (k, v) in data)

"""Return a JSON string without allocating `PormGRow` wrappers."""
list(objct::SQLObjectHandler, ::Val{:json}; show_query::Symbol = :execute) =
  _list_owned(objct, Val(:json); show_query=show_query)

function _list_owned(q::SQLObjectHandler, ::Val{:json}; show_query::Symbol = :execute)
  show_query !== :execute && return _show_select(q, show_query)
  return JSON.json([_json_row(row) for row in _list_raw(q)])
end

# #641 — a `PormGRow` handed to `JSON.json` used to serialize the SCHEMA, not the row.
#
# JSON.jl has no method for `PormGRow`, so it reflects over all three slots and walks into
# `_model::PormGModel` — the model graph, which is a dense, cyclic DAG (`Model_Type.fields` ->
# `sForeignKey.to` -> `Model_Type.related_objects` -> `ReverseRelation.model_resolved` -> ...). The
# writer breaks true cycles with an ANCESTOR stack, so it terminates, but it memoizes nothing: every
# distinct PATH through the graph is serialized again. That is exponential in the schema's density,
# and it is the whole bug — a 26-character row measured 1,843,565 characters and 5.3s of CPU on the
# 14-model F1 fixture, and an application schema OOM-killed the process at 28.5 GB.
#
# Exactly the defect `src/display.jl` (#534) fixed for `Base.show`, one hop over: same graph, same
# absence of a method, serialization instead of display. And like that fix it is cheap, because ONE
# method on the type a user actually hands to a serializer bounds the whole thing.
#
# `getfield(r, :_data)`, never `r.x` — display.jl's rule 3, for the same reason: `PormGRow` overloads
# `getproperty`, so property access would run the many-to-many / lazy-traversal dispatch from inside
# a serializer.
#
# `::JSON.JSONStyle` (the abstract parent of the read and write styles) and `StructUtils` both exist
# from JSON 1.0.0, which JSON exports — so this holds at the declared `JSON = "1"` floor and needs no
# new dependency.
JSON.StructUtils.lower(::JSON.JSONStyle, r::PormGRow) = _json_row(getfield(r, :_data))

function list(objct::SQLObjectHandler, ::Val{F}; kwargs...) where F
  throw(QueryBuildError("Unknown list format :$F. Expected :row, :dict, or :json."))
end

list(objct::SQLObjectHandler, format::Symbol; kwargs...) = list(objct, Val(format); kwargs...)
list(objct::SQLObjectHandler; kwargs...) = list(objct, Val(:row); kwargs...)

"""
    first(objct::SQLObjectHandler; show_query::Symbol = :execute)

Return the first `PormGRow` matching the current query, or `nothing` if no records match.

A slice the caller set is honored: `first` takes the first row of the slice, so
`q.limit(0).first()` is `nothing` and `q.offset(10).first()` is the eleventh row (#1053).

Like every read terminal (`count`, `exists`, `list`, `get`), `first` executes on an
internal copy of the handler — the `limit(1)` it needs is applied to that copy, never
to `objct`. The handler is reusable afterwards, including for `.update()`:

```julia
q = M.Driver.objects
q.filter("nationality" => "British")
driver = q.first()                      # q is unchanged — no limit leaks in
q.update("nationality" => "English")    # still valid on the same handler
```
"""
first(objct::SQLObjectHandler; show_query::Symbol = :execute) = _first(objct, Val(:row); show_query=show_query)

# #1352: `format` is `Val(:row)` or a typed-read `T` — the one body both `first()` and `first(T)` run,
# so the slice rule (#1053) and the copy rule (#199) cannot drift between them.
Base.@constprop :aggressive function _first(objct::SQLObjectHandler, format; show_query::Symbol)
  # #199: copy-first like count/exists/list — limit(1) must not leak into the caller's handler
  q = _terminal_copy(objct)
  q.limit(_probe_limit(q.object.limit, 1))   # #1053: within the caller's slice, not instead of it
  res = _list_owned(q, format; show_query=show_query)
  if show_query !== :execute
    return res
  end
  return isempty(res) ? nothing : res[1]
end
# NOTE (#200): the curried `first(; kwargs...) = (objct) -> first(objct; kwargs...)` form
# was removed — a zero-positional method on Base.first with no PormG type is type piracy.
# `q.first(...)`, `first(q; kw...)` and `q |> first` are unaffected. See the piracy guard in
# test/unit/test_public_exports.jl. (`delete`/`inspect_query` keep their curried forms — those
# functions are package-owned, so a kwargs-only method on them is not piracy.)

# Reverse a single ORDER BY term by CONSTRUCTING the reversed one — the reverse of an ORDER BY
# yields the last row (#208). Flip ASC↔DESC, and any EXPLICIT nulls placement (an unset `nothing`
# stays default so the renderer keeps its orientation-derived NULLS placement). #540: `SQLOrder` is
# an immutable struct, so this cannot write into the caller's term — which is the point: the term
# is a value the caller may still hold, and `last()` works on a copy of the handler anyway.
# Non-SQLOrder ordering terms are returned as-is (best effort).
function _invert_order(o::SQLOrder)::SQLOrder
  # One conditional, NOT two flips in sequence: :first→:last followed by :last→:first is a no-op.
  nulls = o.nulls === :first ? :last : o.nulls === :last ? :first : o.nulls
  return SQLOrder(o.field, o.order, o.orientation == "DESC" ? "ASC" : "DESC", o._as, nulls)
end
_invert_order(o) = o

"""
    last(objct::SQLObjectHandler; show_query::Symbol = :execute)

Return the last `PormGRow` matching the current query, or `nothing` if no records match.

The mirror of [`first`](@ref): it inverts the query's ordering and takes one row. When an
`order_by(...)` is set, `last()` returns the row that `first()` would return under the reversed
ordering. When **no** ordering is set, it falls back to **primary-key descending**, so `last()`
is always well-defined (matching Django). Like every read terminal, it runs on an internal copy —
the inverted ordering and `limit(1)` never leak into the caller's handler.

On a query with `limit()` or `offset()` set, `last` raises `QueryBuildError`, as Django's does:
reversing the ordering changes which rows the slice holds (#1053).
"""
last(objct::SQLObjectHandler; show_query::Symbol = :execute) = _last(objct, Val(:row); show_query=show_query)

Base.@constprop :aggressive function _last(objct::SQLObjectHandler, format; show_query::Symbol)
  _refuse_sliced(objct.object, "last()", "it reverses the ordering, which changes which rows the slice holds")
  # #199: copy-first like first/count/list — the ordering flip and limit(1) apply to the copy only.
  q = _terminal_copy(objct)
  if isempty(q.object.order)
    # No ordering: fall back to primary-key DESC so last() is meaningful (Django parity).
    model = q.object.model
    pk_sym = try
      Models.get_model_pk_field(model)
    catch e
      # get_model_pk_field throws ModelDefinitionError on a composite pk (#239; was
      # ArgumentError). Re-home it as an actionable QueryBuildError.
      e isa ModelDefinitionError || rethrow(e)
      throw(QueryBuildError("last() with no order_by() needs a single-column primary key to order by, but $(model.name) has none — add an explicit order_by(...)."))
    end
    pk_sym === nothing &&
      throw(QueryBuildError("last() with no order_by() needs a single-column primary key to order by, but $(model.name) has none — add an explicit order_by(...)."))
    q.order_by("-" * String(pk_sym))
  else
    # Reverse the existing ordering; the reversed ORDER BY's first row is the original's last.
    # #540: rebuild the copy's own order list from constructed terms — nothing is written into an
    # `SQLOrder`, which is a `struct` now.
    map!(_invert_order, q.object.order, q.object.order)
  end
  q.limit(1)
  res = _list_owned(q, format; show_query=show_query)
  if show_query !== :execute
    return res
  end
  return isempty(res) ? nothing : res[1]
end

# Shared body for earliest()/latest(): apply the (already-oriented) ordering fields, take one row,
# and raise DoesNotExist on an empty queryset (Django parity — these behave like get(), not first()).
# `format` is `Val(:row)` or a typed-read `T` (#1352).
Base.@constprop :aggressive function _extreme(objct::SQLObjectHandler, order_fields, opname::String; show_query::Symbol, format = Val(:row))
  _refuse_sliced(objct.object, "$(opname)()", "it replaces the ordering, which changes which rows the slice holds")
  q = _terminal_copy(objct)
  q.order_by(order_fields...)
  q.limit(1)
  show_query !== :execute && return _list_owned(q, format; show_query=show_query)
  rows = _list_owned(q, format)
  # The message is rendered only when it is thrown. The build left `q`'s filters as the caller wrote
  # them (#1624: a CTE-path filter is resolved in the build's view, not rewritten in place).
  isempty(rows) && throw(DoesNotExist(q.object.model.name, "$(opname): $(_filters_repr(q))"))
  return rows[1]
end

# Flip a single order token's direction for latest() (the ASC↔DESC inverse of what the user wrote):
# "field" → "-field" (DESC), "-field" → "field" (ASC). Matches Django's latest("-f") == earliest("f").
_invert_order_token(f::AbstractString) = startswith(f, "-") ? String(f[2:end]) : "-" * String(f)
_invert_order_token(f) = throw(QueryBuildError("earliest()/latest() fields must be field-name Strings (\"-field\" for the opposite direction); got $(typeof(f))."))

"""
    earliest(objct::SQLObjectHandler, fields...; show_query = :execute) -> PormGRow

Return the earliest row ordered by `fields` (ascending; a `"-field"` flips that term to
descending). Requires at least one field and raises `DoesNotExist` when no rows match — the
extreme-row counterpart of [`get`](@ref), matching Django's `earliest()`. On a query with
`limit()` or `offset()` set it raises `QueryBuildError`, as Django's does (#1053).
"""
function earliest(objct::SQLObjectHandler, fields...; show_query::Symbol = :execute)
  isempty(fields) &&
    throw(QueryBuildError("earliest() requires at least one field to order by, e.g. earliest(\"dob\")."))
  return _extreme(objct, fields, "earliest"; show_query=show_query)
end

"""
    latest(objct::SQLObjectHandler, fields...; show_query = :execute) -> PormGRow

Return the latest row ordered by `fields` (descending; a `"-field"` flips that term to
ascending). Requires at least one field and raises `DoesNotExist` when no rows match. Django's
`latest()`; `latest("f") == earliest("-f")`. A sliced query raises `QueryBuildError`, as for
[`earliest`](@ref).
"""
function latest(objct::SQLObjectHandler, fields...; show_query::Symbol = :execute)
  isempty(fields) &&
    throw(QueryBuildError("latest() requires at least one field to order by, e.g. latest(\"dob\")."))
  return _extreme(objct, _invert_order_token.(fields), "latest"; show_query=show_query)
end

# The filters a `DoesNotExist` / `MultipleObjectsReturned` message names.
_filters_repr(q::SQLObjectHandler)::String =
  isempty(q.object.filter) ? "(none)" : join(_get_filter_repr.(q.object.filter), ", ")

function _get_filter_repr(filter::SQLTypeOper)::String
  column = filter.column isa SQLTypeField ? filter.column.field : filter.column
  return "$(column) $(filter.operator) $(filter.values)"
end

function _get_filter_repr(filter::SQLTypeQ)::String
  return "(" * join(_get_filter_repr.(filter.filters), " AND ") * ")"
end

function _get_filter_repr(filter::SQLTypeQor)::String
  return "(" * join(_get_filter_repr.(getfield(filter, :or)), " OR ") * ")"
end

_get_filter_repr(filter) = sprint(show, filter)

"""
    get(objct::SQLObjectHandler, filters...; show_query=:execute) -> PormGRow

Return exactly one row matching the query filters.

Filters can be passed inline or applied with `.filter()` before calling `.get()`:

```julia
driver = M.Driver.objects.get("driverref" => "hamilton")
driver = M.Driver.objects.filter("driverref" => "hamilton").get()
```

Raises `DoesNotExist` when no rows match and `MultipleObjectsReturned` when more
than one row matches.

Like every read terminal, `get` executes on an internal copy of the handler: inline
filters do **not** persist on `objct`, so the handler can be reused afterwards with
its original filter list intact.

A slice the caller set is honored: `get` looks for its one row inside the slice, so
`q.limit(0).get()` raises `DoesNotExist` (#1053). Inline filters join the `WHERE`
clause before the slice applies, the same as a `filter()` call after `limit()`.
"""
get(objct::SQLObjectHandler, filters...; show_query::Symbol = :execute) = _get(objct, Val(:row), filters; show_query=show_query)

# #1352: `format` is `Val(:row)` or a typed-read `T`; one body, so `get(T, …)` raises the same
# `DoesNotExist` / `MultipleObjectsReturned` from the same probe.
Base.@constprop :aggressive function _get(objct::SQLObjectHandler, format, filters; show_query::Symbol)
  # #199: copy-first — inline filters and the limit(2) probe apply to the copy only,
  # so they never leak into the caller's handler.
  q = _terminal_copy(objct)
  !isempty(filters) && _filter!(q.object, filters)
  q = q.limit(_probe_limit(q.object.limit, 2))   # #1053: within the caller's slice, not instead of it

  if show_query !== :execute
    return _list_owned(q, format; show_query=show_query)
  end

  rows = _list_owned(q, format)
  # #1624: the messages are rendered only when one is thrown. The build left `q`'s filters as the
  # caller wrote them (a CTE-path filter is resolved in the build's view, not rewritten in place), so
  # they name `agg__total`, not the `CTEReference` the build resolved it to.
  length(rows) == 1 && return rows[1]
  isempty(rows) && throw(DoesNotExist(q.object.model.name, _filters_repr(q)))
  throw(MultipleObjectsReturned(q.object.model.name, length(rows), _filters_repr(q)))
end
