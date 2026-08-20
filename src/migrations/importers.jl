# ==============================================================================
# IMPORTER UTILITIES
# High-level functions to import existing database schemas or Django models 
# into PormG model definitions.
# ==============================================================================

# ---
# Dialect Importers (SQLite / Postgres)
# ---

"""
    _plan_inspectdb_bindings!(models_array) -> Dict{String, String}

Pass 1 of an `inspectdb`-style import (#360): resolve every model's FINAL Julia binding **before** the
first model is rendered, then rewrite each `ForeignKey`/`OneToOneField` `.to` to the binding of the
model that owns its physical target table. Returns the physical table → binding map, which the caller
hands back to `Model_to_str` so the binding is derived exactly once.

This is the same move `_resolve_relation_targets!` already makes for the Django importer
(`field.to = target.binding`), which is why that path never had this bug.

Why a rewrite rather than a smarter resolver: a `.to` string is dereferenced by **binding lookup** in
seven places — `Models._resolve_target_model` plus six hand-rolled `getfield(mod, Symbol(field.to))`
sites (`querybuilder/build_joins.jl` 436/511/552, `querybuilder/ctes.jl` 185/349,
`querybuilder/execution.jl` 2056). Teaching one of them about physical tables leaves the other six
wrong; making `.to` correct at the source fixes all seven.

Why `to_table` has to exist at all: introspection knows the physical parent table, but `.to` is a
*binding*, and that derivation is lossy — `driver` and `Driver` both produce `Driver`, so the table
cannot be recovered from `.to` afterwards. The breadcrumb carries it across the gap.

The binding walk MUST match `Model_to_str`'s own: same seed
(`GENERATED_MODULE_RESERVED_BINDINGS`, what the generated file's boilerplate already imports), same
order (`models_array`, which the caller renders in sequence), same `_dedupe_taken` digit-suffix rule.
"""
function _plan_inspectdb_bindings!(models_array)::Dict{String, String}
  taken_bindings = Set{String}(GENERATED_MODULE_RESERVED_BINDINGS)
  binding_by_table = Dict{String, String}()
  for model in models_array
    binding = Models._dedupe_taken(Models._model_binding_name(String(model.name)), taken_bindings)
    push!(taken_bindings, binding)
    # Keyed on the PHYSICAL table, which is what `to_table` records. Table names are unique within a
    # schema, so this cannot overwrite — the collision this whole function exists for is two tables
    # arriving at one BINDING, which `_dedupe_taken` has already separated by the time we get here.
    binding_by_table[model_table_name(model)] = binding
  end

  for model in models_array
    for (field_name, field) in pairs(model.fields)
      (field isa Models.sForeignKey || field isa Models.sOneToOneField) || continue
      target_table = field.to_table
      # A hand-built model reaching an importer, or a relation introspection could not attribute to a
      # physical table. Nothing to improve on — leave the derived `.to` exactly as it was.
      target_table === nothing && continue
      binding = get(binding_by_table, target_table, nothing)
      if binding === nothing
        # The parent is not in this generated file — filtered out by `ignore_table`/`include_table`,
        # in another schema, or (on SQLite, whose identifiers are case-insensitive) spelled in the
        # `REFERENCES` clause with a case the `CREATE TABLE` did not use. `.to` keeps its derived
        # spelling, which is the pre-#360 behaviour: it will not resolve, and `set_models` says so
        # loudly.
        #
        # Deliberately NOT a case-insensitive fallback. "Exactly one case-insensitive candidate
        # among the IMPORTED models" is not the same question as "exactly one in the schema" — a
        # filter can hide the real target and leave a same-name-different-case sibling as the only
        # candidate, at which point this would silently bind the key to the WRONG table. Trading a
        # loud `ModelDefinitionError` for a silent wrong target is the exact defect class #360 is
        # about, so a miss stays a miss.
        @debug "inspectdb: foreign key target table is not among the imported models; leaving `.to` as derived" model=model.name field=field_name target_table=target_table
        continue
      end
      field.to = binding
    end
  end

  return binding_by_table
end

"""
    import_models_from_sqlite(db::String="db"; force_replace::Bool=false, ignore_schema::Vector{String}=sqlite_ignore_schema, include_table=nothing, file::String="automatic_models.jl")

Import models from a SQLite database and generate a Julia file with model definitions.

# Arguments
- `db::String="db"`: The database key from the configuration (must resolve to a registered SQLite connection).
- `force_replace::Bool=false`: Whether to overwrite the file if it already exists.
- `ignore_schema::Vector{String}=sqlite_ignore_schema`: Table name patterns to ignore.
- `include_table::Union{Vector{String},Nothing}=nothing`: When set, only these tables are imported.
- `file::String="automatic_models.jl"`: The output filename for the generated models.

# Description
Symmetric with [`import_models_from_postgres`](@ref): the database **key** resolves to its settings
via `Configuration.get_settings`, the output directory comes from that connection's `db_def_folder`,
and the connection object is taken from the same settings — so the key and its settings can never
drift apart. A missing/unregistered key raises a clear `ArgumentError` from `get_settings` (no silent
`MODEL_PATH` fallback); a key bound to a non-SQLite connection is rejected explicitly.

# Example
```julia
using PormG

# Load the SQLite configuration
PormG.Configuration.load("db_sl")

# Import models from the database
PormG.Migrations.import_models_from_sqlite("db_sl")
```
"""
function import_models_from_sqlite(db::String = "db";
                                  force_replace::Bool=false,
                                  ignore_schema::Vector{String} = sqlite_ignore_schema,
                                  include_table::Union{Vector{String}, Nothing} = nothing,
                                  file::String="automatic_models.jl")

  # Resolve the connection from its config key (mirrors import_models_from_postgres):
  # a missing/unregistered key throws a clear ArgumentError from get_settings, and the
  # output folder comes from the resolved connection's settings — never a hardcoded path.
  settings = Configuration.get_settings(db)
  conn = settings.connections
  conn isa PormGSQLite || throw(BackendCapabilityError(
    "Connection '$(db)' is not a SQLite connection (got $(typeof(conn))). Use import_models_from_postgres for PostgreSQL."))
  model_path = settings.db_def_folder

  # check if file already exists
  if isfile(joinpath(model_path, file)) && !force_replace
    @warn("The file '$(joinpath(model_path, file))' already exists, use force_replace=true to replace it")
    return nothing
  elseif !ispath(model_path)
    mkpath(model_path)
  end

  # Convert the database schema to models
  models_array = convert_schema_to_models(conn, ignore_table=ignore_schema, include_table=include_table)

  if isempty(models_array)
    @warn("No tables found in the database to import.")
    return nothing
  end

  # Collect all create instructions
  # #338: one binding/name registry PER GENERATED FILE, shared across every model rendered into it —
  # seeded with what the file's own boilerplate already imports, so a table literally named "models"
  # collides too. Without this, two tables that render the same binding silently shadow one another.
  # #360: pass 1 first — resolve every binding and rewrite each FK's `.to` to its target's FINAL
  # binding, then render with the bindings pass 1 already decided (one derivation, no drift).
  binding_by_table = _plan_inspectdb_bindings!(models_array)
  taken_bindings = Set{String}(GENERATED_MODULE_RESERVED_BINDINGS)
  taken_names = Set{String}()
  Instructions::Vector{Any} = []
  for model in models_array
    push!(Instructions, Models.Model_to_str(model; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names, binding=binding_by_table[model_table_name(model)]))
  end

  generate_models_from_db(file, Instructions, settings; path=model_path)

  @info(_emsg("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m"))
  @info("The models have been saved to '$(joinpath(model_path, file))'.")

  return nothing
end

"""
    import_models_from_postgres(db::String; force_replace::Bool=false, ignore_table::Vector{String}=postgres_ignore_table, file::String="automatic_models.jl")

Import models from a PostgreSQL database and generate a Julia file with model definitions.

# Arguments
- `db::String`: The database key from the configuration.
- `force_replace::Bool=false`: Whether to overwrite the file if it already exists.
- `ignore_table::Vector{String}=postgres_ignore_table`: A vector of table name patterns to ignore.
- `file::String="automatic_models.jl"`: The output filename for the generated models.

# Description
This function retrieves the database schema from PostgreSQL, converts each table to a PormG model,
and generates a Julia module file containing all the model definitions. The generated file can be
directly included in your project to work with the database tables.

# Example
```julia
using PormG

# Load the database configuration
PormG.Configuration.load("db")

# Import models from the database
PormG.Migrations.import_models_from_postgres("db")

# Or with options
PormG.Migrations.import_models_from_postgres("db", force_replace=true, file="my_models.jl")
```
"""
function import_models_from_postgres(db::String;
  force_replace::Bool=false, 
  ignore_table::Vector{String} = postgres_ignore_table,
  include_table::Union{Vector{String}, Nothing} = nothing,
  file::String="automatic_models.jl",
  config::Dict{String,PormGSettings} = config)
  
  settings = Configuration.get_settings(db)
  conn = settings.connections
  model_path = settings.db_def_folder
  
  # Check if the models file already exists
  if isfile(joinpath(model_path, file)) && !force_replace
      @warn("The file '$(joinpath(model_path, file))' already exists, use force_replace=true to replace it")
      return nothing
  end
  
  
  # Convert the database schema to models
  models_array = convert_schema_to_models(conn, ignore_table=ignore_table, include_table=include_table)

  if isempty(models_array)
      @warn("No tables found in the database to import.")
      return nothing
  end

  # Convert each model to string representation
  # #338: one binding/name registry per generated file — see import_models_from_sqlite for why.
  # #360: pass 1 first — see import_models_from_sqlite.
  binding_by_table = _plan_inspectdb_bindings!(models_array)
  taken_bindings = Set{String}(GENERATED_MODULE_RESERVED_BINDINGS)
  taken_names = Set{String}()
  Instructions::Vector{Any} = []
  for model in models_array
      push!(Instructions, Models.Model_to_str(model; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names, binding=binding_by_table[model_table_name(model)]))
  end
  
  # Generate the models file
  generate_models_from_db(file, Instructions, settings, path=model_path)
  
  @info(_emsg("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m"))
  @info("The models have been saved to '$(joinpath(model_path, file))'.")
  
  return nothing
end

function import_models_from_postgres(;db::PormGPostgres = connection(), 
                                  settings::PormGSettings,
                                  force_replace::Bool=false, 
                                  ignore_table::Vector{String} = postgres_ignore_table,
                                  include_table::Union{Vector{String}, Nothing} = nothing,
                                  file::String="automatic_models.jl")
  
  model_path = settings.db_def_folder
  
  # Check if the models file already exists
  if isfile(joinpath(model_path, file)) && !force_replace
      @warn("The file '$(joinpath(model_path, file))' already exists, use force_replace=true to replace it")
      return nothing
  end
    
  # Convert the database schema to models
  models_array = convert_schema_to_models(db, ignore_table=ignore_table, include_table=include_table)

  if isempty(models_array)
      @warn("No tables found in the database to import.")
      return nothing
  end

  # Convert each model to string representation
  # #338: one binding/name registry per generated file — see import_models_from_sqlite for why.
  # #360: pass 1 first — see import_models_from_sqlite.
  binding_by_table = _plan_inspectdb_bindings!(models_array)
  taken_bindings = Set{String}(GENERATED_MODULE_RESERVED_BINDINGS)
  taken_names = Set{String}()
  Instructions::Vector{Any} = []
  for model in models_array
      push!(Instructions, Models.Model_to_str(model; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names, binding=binding_by_table[model_table_name(model)]))
  end
  
  # Generate the models file
  generate_models_from_db(file, Instructions, settings, path=model_path)
  
  @info(_emsg("\e[32mSuccessfully imported $(length(models_array)) models from the database.\e[0m"))
  @info("The models have been saved to '$(joinpath(model_path, file))'.")
  
  return nothing
end

# ---
# Django Importer
# ---

"""
    django_to_string(path::String) -> Union{String, Nothing}

Read a Django `models.py` and return its text, ready for [`import_models_from_django`](@ref).

A missing file logs a warning and returns `nothing` rather than throwing.

Until #340 this also rewrote every apostrophe to a double quote so the line-based parser saw one
string delimiter. That was a blunt global `replace`: it broke any apostrophe inside a value (a
`help_text` reading `Don't` became `Don` + stray quote + `t`) and rewrote single-quoted Python
docstring delimiters as well. The scanner below tracks both delimiters, and both triple-quoted
forms, natively — so the text is now handed over verbatim.

```julia
django_to_string("/home/user/models.py") |> import_models_from_django
```
"""
function django_to_string(path::String)
  # check if db/models/automatic_models.jl exists
  if !isfile(path)
    @warn("The file $(path) does not exists")
    return
  end

  # Read the file. Line-ending normalization is owned by `_py_logical_lines`, which has to do it
  # anyway for source handed over as content rather than as a path; this is only so the string
  # this function *returns* is already in the canonical form callers see elsewhere.
  return replace(read(path, String), "\r\n" => "\n")
end

# ── Python source scanner (#340) ────────────────────────────────────────────────────────────────
# Fields used to be matched with a per-LINE regex that required `= models.X(...)` to open AND close
# on one physical line. A definition wrapped across lines — ordinary Django formatting, and what
# `black` produces — matched nothing, and there was no `else` branch, so it was dropped in silence:
#
#     created_by = models.ForeignKey(
#         settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, blank=True
#     )
#
# Everything below exists so that a field is a *logical statement* instead — text accumulated until
# bracket depth returns to zero outside any string.
#
# ONE scanner backs all of it. `split_field_options` and `_balanced_group` used to carry their own
# partial copies that tracked `(`/`)` only, with no `[`/`{` and no backslash escapes — which is why
# `choices=[("A","a"), ("B","b")], max_length=1` split at the comma BETWEEN the two tuples.

"""
    _PyScan

Character-level state for reading Python source: bracket `depth` outside strings, the active
string delimiter `delim` (`'\\0'` when not in a string), whether that string is `triple`-quoted,
and whether the previous character was an escaping backslash.

`delim` rather than the obvious `quote`: `quote` is a Julia keyword, so `quote::Char` in a struct
body opens a `quote ... end` block and silently swallows the rest of the file.
"""
mutable struct _PyScan
  depth::Int
  delim::Char
  triple::Bool
  escaped::Bool
end
_PyScan() = _PyScan(0, '\0', false, false)

_in_string(st::_PyScan)::Bool = st.delim != '\0'

# True when `s` holds `n` consecutive `c` starting at index `i` — how `"` is told from `"""`.
function _run_of(s::AbstractString, i::Int, c::Char, n::Int)::Bool
  idx = i
  for _ in 1:n
    (idx > lastindex(s) || s[idx] != c) && return false
    idx = nextind(s, idx)
  end
  return true
end

function _skip(s::AbstractString, i::Int, n::Int)::Int
  for _ in 1:n
    i = nextind(s, i)
  end
  return i
end

"""
    _py_step!(st, s, i) -> Int

Advance `st` past the token starting at index `i` of `s` and return the index of the next one.
A triple quote needs three characters of lookahead, so this consumes a *token* rather than a
character — callers must use the returned index instead of `nextind`.
"""
function _py_step!(st::_PyScan, s::AbstractString, i::Int)::Int
  c = s[i]

  if _in_string(st)
    if st.escaped
      st.escaped = false
    elseif c == '\\'
      st.escaped = true
    elseif c == st.delim
      if st.triple
        if _run_of(s, i, c, 3)
          st.delim = '\0'
          st.triple = false
          return _skip(s, i, 3)
        end
      else
        st.delim = '\0'
      end
    end
    return nextind(s, i)
  end

  if c == '"' || c == '\''
    st.triple = _run_of(s, i, c, 3)
    st.delim = c
    return st.triple ? _skip(s, i, 3) : nextind(s, i)
  elseif c == '(' || c == '[' || c == '{'
    st.depth += 1
  elseif c == ')' || c == ']' || c == '}'
    # Clamped: a malformed source must not drive depth negative and make every later `depth == 0`
    # test read as "still nested", which would swallow the rest of the file into one statement.
    st.depth = max(0, st.depth - 1)
  end
  return nextind(s, i)
end

"""
    PyStmt

One logical Python statement: its `text` (comments stripped, continuation lines folded to a single
space), the `indent` of its first physical line in spaces (a tab counts as four), and the 1-based
`lineno` it started on. `lineno` is what lets a diagnostic point at a line the author can open.
"""
struct PyStmt
  indent::Int
  text::String
  lineno::Int
end

"""
    _py_logical_lines(src) -> Vector{PyStmt}

Split Python source into logical statements.

A physical newline ends a statement only at bracket depth zero, outside any string, and with no
trailing line-continuation backslash — so a wrapped `models.ForeignKey(\\n … \\n)` arrives whole.

`#` starts a comment only *outside* a string. The regex this replaces stripped from the first `#`
unconditionally, so `default="#fff"` lost its value.
"""
function _py_logical_lines(src::AbstractString)::Vector{PyStmt}
  out = PyStmt[]
  # Normalized HERE rather than in `django_to_string`, because only the *path* branch of
  # `import_models_from_django` goes through that function — source handed over as content keeps its
  # `\r`, and a lone `\r` on an otherwise blank line used to read as a statement at indent 0, which
  # closed the enclosing class and discarded every field after it. Silently.
  src = replace(src, "\r\n" => "\n", "\r" => "\n")
  st = _PyScan()
  buf = IOBuffer()
  started = false        # the current statement has at least one significant character
  indent = 0             # indent of the started statement
  pending_indent = 0     # leading whitespace measured on the current physical line
  start_lineno = 1
  lineno = 1
  in_comment = false
  continued = false      # previous physical line ended with a backslash
  measuring = true       # still consuming this physical line's leading whitespace

  i = firstindex(src)
  stop = lastindex(src)
  while i <= stop
    c = src[i]

    if c == '\n'
      lineno += 1
      # A newline inside a triple-quoted string is content, not a terminator: fall through so the
      # scanner consumes it and the docstring stays one statement.
      if !(_in_string(st) && st.triple)
        in_comment = false
        if st.depth > 0 || continued
          started && print(buf, ' ')   # fold the break into a single separator
        elseif started
          _push_stmt!(out, indent, String(take!(buf)), start_lineno)
          started = false
        else
          take!(buf)
        end
        continued = false
        measuring = true
        pending_indent = 0
        i = nextind(src, i)
        continue
      end
    end

    if in_comment
      i = nextind(src, i)
      continue
    end

    if measuring && !_in_string(st)
      # Any whitespace counts as indentation, not as content. Matching only ' ' and '\t' let a
      # form feed (PEP 8's page separator) or a non-breaking space start an EMPTY statement at
      # indent 0 — which then closed the enclosing class, as `\r` did.
      if isspace(c)
        pending_indent += (c == '\t' ? 4 : 1)
        i = nextind(src, i)
        continue
      end
      measuring = false
    end

    if c == '#' && !_in_string(st)
      in_comment = true
      i = nextind(src, i)
      continue
    end

    if c == '\\' && !_in_string(st)
      continued = true
      i = nextind(src, i)
      continue
    end

    if !started
      started = true
      indent = pending_indent
      start_lineno = lineno
    end

    j = _py_step!(st, src, i)
    print(buf, src[i:prevind(src, j)])
    i = j
  end

  started && _push_stmt!(out, indent, String(take!(buf)), start_lineno)

  # An unterminated string or unbalanced bracket makes every following line fold into the current
  # statement, so the rest of the file disappears into one unusable blob. The line-based parser used
  # to lose exactly one line; say so rather than let a truncated file look fully imported.
  if _in_string(st) || st.depth > 0
    @warn "import: Python source ends inside an unterminated string or unclosed bracket; statements after the opening point may have been merged and lost" open_brackets=st.depth in_string=_in_string(st)
  end
  return out
end

# Never record an empty statement: `_py_classes` closes a class on any statement indented no further
# than its header, so a blank entry at indent 0 would silently truncate the class it sits in.
function _push_stmt!(out::Vector{PyStmt}, indent::Int, text::AbstractString, lineno::Int)
  t = String(strip(text))
  isempty(t) || push!(out, PyStmt(indent, t, lineno))
  return out
end

"""
    PyClass

A `class` block recovered from Django source: its `name`, the raw text of its base list (`bases`),
its own direct statements (`body`), the statements of a nested `class Meta:` block, and any other
nested classes.

Nested bodies are held separately rather than inlined into `body`, which is what retires the
`inside_class` flag: that flag was set once and never reset, so a nested `class Status(TextChoices)`
and any module-level code following the last model both leaked into the previous model's content.
"""
struct PyClass
  name::String
  bases::String
  lineno::Int
  body::Vector{PyStmt}
  meta::Vector{PyStmt}
  nested::Vector{PyClass}
end

const _CLASS_HEADER_RE = r"^class\s+(\w+)\s*(?:\((.*)\))?\s*:"
const _DEF_HEADER_RE = r"^(?:async\s+)?def\s+\w+"

"""
    _py_classes(stmts) -> Vector{PyClass}

Group logical statements into a class tree using indentation. A statement indented no further than
a class header closes that class, so nesting is derived from the source's own structure rather than
from a flag the caller has to remember to clear.
"""
function _py_classes(stmts::Vector{PyStmt})::Vector{PyClass}
  roots = PyClass[]
  # `nothing` marks a `def` body. A method's locals are not fields, and feeding them to the field
  # matcher is not merely noisy — a routine wrapped `cond = models.Q(\n … \n)` inside a queryset
  # helper resolved to `getfield(Models, :Q)` and aborted the ENTIRE import, taking every later
  # model with it. (The old line-based regex never matched the wrapped form, so this was a
  # regression introduced by making the parser see across lines.)
  stack = Tuple{Union{PyClass, Nothing}, Int}[]

  for s in stmts
    while !isempty(stack) && s.indent <= stack[end][2]
      pop!(stack)
    end
    inside_def = !isempty(stack) && stack[end][1] === nothing

    if match(_DEF_HEADER_RE, s.text) !== nothing
      push!(stack, (nothing, s.indent))
      continue
    end

    m = match(_CLASS_HEADER_RE, s.text)
    if m !== nothing
      if inside_def
        # A class declared inside a method is not importable; skip its whole body too.
        push!(stack, (nothing, s.indent))
        continue
      end
      cls = PyClass(String(m.captures[1]),
                    m.captures[2] === nothing ? "" : String(strip(m.captures[2])),
                    s.lineno, PyStmt[], PyStmt[], PyClass[])
      parent = isempty(stack) ? nothing : stack[end][1]
      parent === nothing ? push!(roots, cls) : push!(parent.nested, cls)
      push!(stack, (cls, s.indent))
    elseif !isempty(stack) && !inside_def
      push!(stack[end][1].body, s)
    end
    # A statement at module level that is not a class header is ignored outright — this is where
    # the trailing `def`s, signal wiring and constants of a real models.py now go.
  end

  # Lift `class Meta:` out of `nested` so callers read Meta options from a block that is provably
  # the Meta block. `parse_meta_unique_together` used to `occursin` over the whole class body, which
  # also matched the word inside a docstring or a sibling nested class.
  for cls in roots
    _lift_meta!(cls)
  end
  return roots
end

function _lift_meta!(cls::PyClass)
  idx = findfirst(n -> n.name == "Meta", cls.nested)
  if idx !== nothing
    append!(cls.meta, cls.nested[idx].body)
    deleteat!(cls.nested, idx)
  end
  return cls
end

"""
    _PyImports

The module-level `from … import …` bindings of one `models.py`.

`names` maps a name as it appears in a base list to `(module path, origin name)`, so
`from core.models import TimeStampedModel as TSM` records
`"TSM" => ("core.models", "TimeStampedModel")`. `stars` holds the module paths of
`from … import *`, which binds names no parser can enumerate without reading that module.

Read for ONE purpose: deciding whether a base name this app does not define may resolve against
another app's class (#370). A name the module never imported is not in scope in Python either, so
resolving it across apps invents an inheritance edge the project does not have — and when the other
app's class is concrete, that edge is read as multi-table inheritance and costs a whole table.
"""
struct _PyImports
  names::Dict{String, Tuple{String, String}}
  stars::Vector{String}
end

# `from <module> import <rest>`. The module may carry leading dots (a relative import) or be
# nothing but dots (`from . import models`), which is why it is `[.\w]+` and not a dotted name.
const _FROM_IMPORT_RE = r"^from\s+([.\w]+)\s+import\s+(.+)$"

"""
    _py_imports(stmts) -> _PyImports

The module-level `from … import …` bindings of a parsed `models.py`.

Only `indent == 0` statements count: an import inside `if TYPE_CHECKING:` or a `try/except
ImportError` is not an unconditional module-level binding, and a base arriving that way is reported
as unresolved rather than guessed at.

Plain `import x.y [as z]` is deliberately NOT recorded. It binds a MODULE, so the base it enables is
written dotted (`class Foo(x.y.Base)`) — and a dotted token has never matched the bare-name class
index (`_class_bases` keeps the token verbatim), so honouring it here would resolve nothing.
Supporting it means teaching base resolution about dotted tokens first; until then leaving it out is
neither a regression nor a gap this function could close on its own.
"""
function _py_imports(stmts::Vector{PyStmt})::_PyImports
  names = Dict{String, Tuple{String, String}}()
  stars = String[]
  for s in stmts
    s.indent == 0 || continue
    m = match(_FROM_IMPORT_RE, s.text)
    m === nothing && continue
    mod = String(m.captures[1])
    rest = strip(String(m.captures[2]))
    # `_py_logical_lines` folds a wrapped `from m import (\n  A,\n  B,\n)` into ONE statement, so
    # the brackets arrive inline. Stripping them here is what makes the parenthesised form — the
    # spelling every formatter produces once the list is long — behave like the flat one.
    if startswith(rest, "(")
      rest = strip(rest[nextind(rest, firstindex(rest)):end])
      endswith(rest, ")") && (rest = strip(rest[firstindex(rest):prevind(rest, lastindex(rest))]))
    end
    if rest == "*"
      mod in stars || push!(stars, mod)
      continue
    end
    for item in split(rest, ',')
      t = strip(item)
      isempty(t) && continue                        # the trailing comma of a parenthesised list
      parts = split(t, r"\s+as\s+")
      origin = String(strip(parts[1]))
      local_name = length(parts) > 1 ? String(strip(parts[end])) : origin
      (isempty(origin) || isempty(local_name)) && continue
      # LAST binding wins, because that is what Python does: a second `from b import X` rebinds the
      # name the first bound. The opposite of the first-wins rule the class index uses, and
      # deliberately so — that rule is about PRECEDENCE between apps, this one about rebinding
      # inside one module.
      names[local_name] = (mod, origin)
    end
  end
  return _PyImports(names, stars)
end


#═══════════════════════════════════════════════════════════════════════════════
# SECTION: The Django import engine — one or many apps (#346)
#═══════════════════════════════════════════════════════════════════════════════
# A Django project splits its models across apps, and PormG is structurally one models file per
# DATABASE, not per app: `planner.jl` resolves ONE `joinpath(db, settings.model_file)`, and
# `_load_current_models` includes that ONE file into ONE temp module. So every app in a project is
# emitted into a single module — which is also what makes a cross-app `ForeignKey("core.Pessoa")`
# resolvable at all, since `_resolve_target_model` is a BINDING lookup in one module and nothing else.
#
# Definition order inside that module is irrelevant: `ForeignKey` stores `.to` as a String and only
# resolves in `set_models`, after the whole module body has run.
#
# Both arities of `import_models_from_django` are this one engine. The single-app method is the
# one-app case, so the target resolution below fixes three spellings that were broken there too:
# `"self"`, `"myapp.Thing"` naming the file's own app, and `settings.AUTH_USER_MODEL`. All three used
# to reach the generated file verbatim and throw at `set_models` — there is no `"self"` handling
# anywhere in `src/`.

"""
    _DjangoApp

One app in an import run: its Django **app label** and the parsed class graph of its `models.py`.

`label === nothing` is the unlabelled single-app import (no `django_prefix`), where PormG derives the
physical table from the logical name and nothing is pinned as `db_table`. A label is never `""` —
`_django_app_label` normalizes an empty prefix to `nothing` before it reaches here, and the multi-app
method rejects an empty label outright.
"""
struct _DjangoApp
  label::Union{Nothing, String}
  graph::NamedTuple
end

"""
    _DjangoClass

One imported Python class and the identity the generated file gives it.

- `class` is the Python class name, verbatim — the name Django derives its own table and join columns
  from, so it stays available even when the emitted name diverges from it.
- `name` is what becomes `model.name`: the basis for BOTH the positional slot (`lowercase(name)`) and
  the binding (`uppercasefirst(name)`). Equal to `class` unless a cross-app collision forced an
  app-qualified name or `binding_overrides` renamed it.
- `binding` is the Julia binding, precomputed in pass 1 because a cross-app FK has to be rewritten to
  its target's binding before the target has been rendered.
- `overridden` records that `name` came from `binding_overrides`, which changes one thing: a residual
  collision is an ERROR rather than a silent digit suffix. You asked for that exact name.
"""
mutable struct _DjangoClass
  app_index::Int
  app::Union{Nothing, String}
  class::String
  name::String
  binding::String
  overridden::Bool
  # Whether this class will carry a `db_table`, which decides WHICH string `Model_to_str` dedups its
  # positional name on: `lstrip(lowercase(name), '_')` when a table is pinned, plain `lowercase(name)`
  # when it is not (`src/Models.jl`). The collision passes have to compare on the same relation, so
  # they read this rather than guess — guessing "always stripped" invented an order-dependent rename
  # for an unlabelled `_Internal`/`Internal` pair that collides on neither relation.
  #
  # Decidable here, and only here: an app label pins unconditionally, and the one other source is
  # `Meta.db_table`, which is readable from the graph at construction. It cannot be derived later
  # from `name` alone, because by then a rename may have moved it.
  pins_table::Bool
  # The built model, filled during emission. `nothing` until then. It exists so the ManyToMany
  # join-COLUMN pass can consult BOTH ends of a relation: a column's spelling depends on the
  # target's primary key, and the target is often built after its owner.
  model::Union{Nothing, PormGModel}
end

# How a class is spelled in a report — a `@warn`, an error, or a `# PormG:` marker — and in a
# `Meta`-style reference: `core.Pessoa` when the app is known, the bare class name otherwise.
#
# Split out of `_django_ref_label` for #371, because pass 2 reports on classes BEFORE it holds a
# `_DjangoClass`: a duplicate declaration, a proxy and a multi-table-inheritance child are all
# reported above the `index.by_ref` lookup, and those are the reports a reader has least other
# context for — a bare 'Pessoa' in a project where two apps declare one traces back to neither.
# The two spellings agree by construction: `_django_ref_label` reads `e.class`, which is the same
# verbatim Python class name pass 2 carries in `class_name`.
_django_class_label(app::Union{Nothing, String}, class_name::AbstractString)::String =
  app === nothing ? String(class_name) : string(app, ".", class_name)

_django_ref_label(e::_DjangoClass)::String = _django_class_label(e.app, e.class)

# Lookup key for an app label. `nothing` (unlabelled single-app import) and a label are one namespace
# — an unlabelled import has exactly one app, so there is nothing to collide with.
_django_app_key(app::Union{Nothing, String})::String = app === nothing ? "" : lowercase(app)

# The string `Model_to_str` will dedup this handle on — EXACTLY, not approximately. Under a pinned
# table it strips leading underscores, otherwise it does not (`src/Models.jl`, `_stripped_name`). The
# importer's collision passes must compare on the same relation in both directions:
#
#   - too FINE (plain `lowercase` everywhere) lets `_Foo`/`Foo` in one labelled app through, and
#     `Model_to_str` then renames one `foo`/`foo2` by declaration order, silently and unmarked;
#   - too COARSE (stripping everywhere) manufactures a conflict for an unlabelled `_Internal`/
#     `Internal` pair that collides on nothing, and — since step 1 skips unlabelled entries — routes
#     it to the digit backstop, whose outcome depends on which class was declared second.
#
# Both directions are order-dependent renames, which is the one property these passes exist to
# remove, so neither approximation is the safe one. `pins_table` is carried on the entry precisely so
# this can be exact.
_django_positional_key(name::AbstractString, pins_table::Bool)::String =
  pins_table ? String(lstrip(lowercase(String(name)), '_')) : lowercase(String(name))
_django_positional_key(e::_DjangoClass)::String = _django_positional_key(e.name, e.pins_table)

"""
    _DjangoClassIndex

Every class the run will emit, resolvable three ways: in emission order (`entries`), by
`(app, class)` for a Django `"app.Class"` reference, and by bare class name for an unqualified one.

`auth_candidates` are the classes that inherit `AbstractUser`; `settings.AUTH_USER_MODEL` resolves to
the single one, or errors naming all of them.
"""
struct _DjangoClassIndex
  entries::Vector{_DjangoClass}
  by_ref::Dict{Tuple{String, String}, _DjangoClass}
  by_class::Dict{String, Vector{_DjangoClass}}
  # A Django PROXY has no table of its own — it reads and writes its concrete parent's. So a
  # `ForeignKey("BaseProxy")` is perfectly expressible: it addresses the parent's table, and Django
  # builds it that way. Proxies are not in `by_ref` (they emit no model), so without this they were
  # reported as "not in the imported app set" — which was simply false, and degraded a relation that
  # did not need to be.
  by_proxy::Dict{Tuple{String, String}, _DjangoClass}
  auth_candidates::Vector{_DjangoClass}
  auth_user::Union{_DjangoClass, Nothing}
  # The `auth_user_model` the caller passed, verbatim, or `nothing`. Separates "you told me, and it
  # lives outside this import" (degrade, like any external target — a stock-Django `"auth.User"`)
  # from "I cannot tell which model it is" (hard error). Kept as the STRING so the degrade marker can
  # name the model the user actually meant instead of the `settings.AUTH_USER_MODEL` alias.
  auth_model_ref::Union{Nothing, String}
  # `# PormG:` lines for renames the USER did not ask for — the digit backstop firing on a residual
  # collision. They belong in the artifact, not only in a console warning, and they have no model
  # declaration of their own to sit above, so they are emitted as standalone comments at the top of
  # the generated module (the #70 convention, same as a skipped proxy).
  rename_notes::Vector{String}
end

"""
    _build_class_index(apps, binding_overrides, auth_user_model) -> _DjangoClassIndex

Pass 1 of the import: decide every class's emitted name and Julia binding **before** the first model
is rendered, because a cross-app `ForeignKey` has to name a binding that may not exist yet.

Collision policy, in order:

1. Start from the Python class name. Two classes that derive the same binding — `core.Pessoa` and
   `access.Pessoa` — are BOTH re-derived as `<app>_<lowercase class>`, never just the second one.
   Renaming only the loser hides which is which, makes the output depend on the order the apps were
   listed, and — because `set_models` keys a reverse accessor on `lowercase(model.name)` — would give
   one of them the accessor `pessoa` and the other `pessoa2`. `core_pessoa` / `access_pessoa` says
   what it is.
2. `binding_overrides` replaces the name outright, for a collision or not ("spell this one
   differently" is a legitimate ask).
3. Anything still colliding — two classes in ONE app differing only in case, an app label that
   reproduces another app's qualified name, or a name that lands on a reserved binding — gets a digit
   suffix on the NAME rather than on the binding alone, so `Model_to_str` re-derives exactly the
   binding recorded here and its own `taken_bindings` dedup (#338) is a no-op backstop.

   Honest about what that buys: with today's code the two agree either way, because pass 2 walks the
   same classes in the same order through the same `_dedupe_taken` against an identically-seeded set,
   so suffixing only the binding lands on the same string. Mutating it to do that is an EQUIVALENT
   mutation — no test can tell. The reason to adjust the name is that agreement then holds by
   construction instead of by two independent dedup runs happening to stay in step, and "these two
   sequences must not drift" is the failure mode this file has paid for more than once.
"""
function _build_class_index(apps::Vector{_DjangoApp},
                            binding_overrides::Dict{String, String},
                            auth_user_model::Union{Nothing, String})::_DjangoClassIndex
  entries = _DjangoClass[]
  for (i, app) in enumerate(apps)
    # Mirrors pass 2's duplicate handling, INCLUDING that the guard runs before the kind test: a
    # `class Foo(QuerySet)` followed by a `class Foo(models.Model)` leaves the model unimported
    # (Python binds the last, `graph.index` keeps the first), and pass 2 is where that is reported.
    seen = Set{String}()
    for cls in app.graph.classes
      cls.name in seen && continue
      push!(seen, cls.name)
      # `_is_emitted` is THE predicate for "this class becomes a `Models.Model(...)`", and pass 2's
      # skip block below is the same test spelled out with its reporting. Pass 1 assigns a binding to
      # exactly this set and pass 2 emits exactly this set, so a cross-app FK can never name a
      # binding the generated file does not define — and pass 2 hard-errors if the two ever disagree.
      _is_emitted(app.graph.info[cls.name]) || continue
      # An app label pins a table for every model it covers; without one the only other source is an
      # explicit `Meta.db_table`. `_effective_meta` rather than the raw `info[...].meta` so an
      # inherited `db_table` counts exactly as pass 2 will count it.
      pins_table = app.label !== nothing || haskey(_effective_meta(app.graph, cls), "db_table")
      push!(entries, _DjangoClass(i, app.label, cls.name, cls.name, "", false, pins_table, nothing))
    end
  end

  by_ref = Dict{Tuple{String, String}, _DjangoClass}()
  by_class = Dict{String, Vector{_DjangoClass}}()
  for e in entries
    key = (_django_app_key(e.app), lowercase(e.class))
    # `seen` above is case-SENSITIVE (it guards against the same name declared twice) while this key
    # is lowercased, because Django's own model lookup is. So `class Pessoa` and `class pessoa` in
    # one app reach here as two entries competing for one key: the second used to overwrite the
    # first, orphaning a binding that was still computed and emitted, and leaving two models pointing
    # at the one table `<app>_pessoa`. Django rejects such a project outright ("Conflicting 'pessoa'
    # models in application"), so there is nothing to disambiguate toward and erroring costs nothing
    # real.
    if haskey(by_ref, key)
      prior = by_ref[key]
      throw(InvalidMigrationError(
        "import: '$(_django_ref_label(prior))' and '$(_django_ref_label(e))' differ only in case, " *
        "so both name the model '$(lowercase(e.class))' and both derive the table " *
        "'$(e.app === nothing ? lowercase(e.class) : string(e.app, "_", lowercase(e.class)))'. " *
        "Django refuses this too — rename one of the classes."))
    end
    by_ref[key] = e
    push!(get!(by_class, lowercase(e.class), _DjangoClass[]), e)
  end

  # 1. App-qualify EVERY member of a colliding group.
  #
  # TWO equivalences, not one. The Julia binding is `uppercasefirst(name)` and the POSITIONAL name is
  # the coarser one `set_models` keys a reverse accessor on. So `core.Pessoa` and `legacy.PESSOA`
  # derive DIFFERENT bindings (`Pessoa` / `PESSOA`) and pass this step untouched, then collide on the
  # positional name downstream, where `Model_to_str`'s `taken_names` dedup renames one to `pessoa2`
  # with no warning and no marker — order-dependent, and exactly the outcome app-qualification exists
  # to prevent. Counting both closes it.
  #
  # The positional equivalence is `_django_positional_key`, NOT a plain `lowercase`. Every entry that
  # reaches the qualification below has a label, hence a pinned table, and under a pinned table
  # `Model_to_str` dedups on `lstrip(lowercase(name), '_')` (`src/Models.jl:1789`). Comparing on
  # `lowercase` alone made `_Foo` and `Foo` in one app look distinct here and identical there, so they
  # slipped past qualification and were renamed `foo`/`foo2` by declaration order — silently, which is
  # the defect this pass exists to remove (#346).
  #
  # The two counts CANNOT share one dictionary. Sharing one, a class whose binding and positional key
  # are the SAME string bumped that single key twice and then read its own contribution back as a
  # 2-way collision — `class _thing` alone in a project app-qualified itself to `Racing__thing` for
  # nothing. Separate tables make an entry structurally unable to collide with itself, whatever the
  # two keys happen to spell.
  binding_counts = Dict{String, Int}()
  name_counts = Dict{String, Int}()
  bump!(d, k) = (d[k] = get(d, k, 0) + 1)
  collides(e) = binding_counts[Models._model_binding_name(e.name)] > 1 ||
                name_counts[_django_positional_key(e)] > 1
  for e in entries
    bump!(binding_counts, Models._model_binding_name(e.name))
    bump!(name_counts, _django_positional_key(e))
  end
  for e in entries
    e.app === nothing && continue     # an unlabelled import has no label to qualify with
    collides(e) || continue
    e.name = string(e.app, "_", lowercase(e.class))
  end

  # 2. Explicit overrides.
  _apply_binding_overrides!(entries, by_ref, by_class, binding_overrides)

  rename_notes = String[]

  # 3. Final bindings, with the digit backstop applied to the NAME.
  #
  # OVERRIDES CLAIM FIRST, in a pass of their own. Doing it in one pass made the outcome depend on
  # the order the apps were listed: an override colliding with a class LATER in `entries` won and
  # silently digit-suffixed that class, while the same override against an EARLIER class raised. So
  # `binding_overrides = Dict("imports.Batch" => "Pessoa")` on a project that also has `core.Pessoa`
  # errored with the apps listed one way and quietly renamed `core.Pessoa` to `Pessoa2` the other —
  # renaming a model the user never mentioned, which is the order-dependence step 1 exists to avoid.
  # An explicit name is a claim on that name, so it is staked before anything can be derived onto it.
  # `taken` holds BOTH equivalences — the binding and `_django_positional_key` — because
  # `Model_to_str` dedups both and only one of them is the Julia identifier. Keeping them in one set
  # is safe: a binding is `uppercasefirst`, a positional key is lowercase with leading underscores
  # stripped, so the only string that could be mistaken for the other is an
  # all-lowercase-and-also-uppercasefirst name, which does not exist for any non-empty string.
  #
  # The positional half uses the SAME key as step 1 — `_django_positional_key`, per entry, which
  # reads `pins_table` rather than assuming. Assuming "always stripped" here was itself a defect: step
  # 1 skips unlabelled entries, so an unlabelled `_Internal`/`Internal` pair that collides on neither
  # relation fell through to the digit backstop below, and the backstop renames whichever class was
  # declared SECOND. That trades a silent order-dependent rename for a loud one; it does not remove
  # it.
  #
  # Honest about the rest: with step 1 counting the positional equivalence too, the positional check
  # HERE is unreachable for LABELLED entries. Two labelled names that collide on it are qualified to
  # `<app>_<class>` up there, which makes them distinct across apps; within one app they are refused
  # outright by the `by_ref` guard. It stays because the two checks encode one rule — "these two
  # strings must both stay unique" — and splitting the rule so that step 1 enforces it and step 3
  # assumes it is how the original defect got in: step 3 assumed step 1 had covered a case it never
  # checked.
  taken = Set{String}(GENERATED_MODULE_RESERVED_BINDINGS)
  # Keyed on BOTH equivalences, because `conflicts` tests both. Keyed on the binding alone, every
  # POSITIONAL conflict reported `nothing` for its claimant, and the two consumers below read that as
  # "a reserved binding": the marker and the `@warn` blamed the generated module's own imports for a
  # name a `binding_overrides` entry had taken, and — worse — the hard error guarding an override
  # collision never fired, so the caller got exactly the silent rename of an unmentioned model that
  # `docs/src/import_django.md` promises raises instead.
  claimed_by = Dict{String, _DjangoClass}()
  claim!(e, b) = (push!(taken, b); push!(taken, _django_positional_key(e));
                  claimed_by[b] = e; claimed_by[_django_positional_key(e)] = e; e.binding = b)
  conflicts(nm, pins) = Models._model_binding_name(nm) in taken ||
                        _django_positional_key(nm, pins) in taken
  # Whichever entry holds the key this one collided on — the binding if that is what clashed, else
  # the positional name. `nothing` now genuinely means "reserved by the module", not "keyed wrong".
  claimant(e, b) = get(claimed_by, b, get(claimed_by, _django_positional_key(e), nothing))
  for e in entries
    e.overridden || continue
    b = Models._model_binding_name(e.name)
    if conflicts(e.name, e.pins_table)
      other = claimant(e, b)
      owner = other === nothing ? "a binding the generated module reserves for PormG itself" :
                                  "another binding_overrides entry, for '$(_django_ref_label(other))'"
      throw(InvalidMigrationError(
        "import: binding_overrides asks for the Julia binding '$(b)' for " *
        "'$(_django_ref_label(e))', but it is already taken by $(owner). Two models cannot share " *
        "one binding in the generated module — choose another name."))
    end
    claim!(e, b)
  end
  for e in entries
    e.overridden && continue
    b = Models._model_binding_name(e.name)
    if conflicts(e.name, e.pins_table)
      # Colliding with an OVERRIDE is a user error with a user fix, so it is reported rather than
      # absorbed. The digit backstop exists for collisions nobody can avoid — two class names that
      # genuinely derive the same binding — not to quietly rename a model the caller never mentioned
      # because a keyword took its name. Order-independent either way now: overrides claim first, so
      # this fires whichever order the apps were listed in.
      other = claimant(e, b)
      if other !== nothing && other.overridden
        # Name the equivalence that actually clashed. An override can collide two ways and only one
        # of them is a binding: `"Circuit" => "Pessoa"` takes the BINDING `Pessoa`, while
        # `"Circuit" => "PESSOA"` takes the MODEL NAME `pessoa` that `PESSOA` lowers to. Reporting
        # both as "the Julia binding 'Pessoa'" sends the reader looking for a name nobody typed.
        took = b in taken ?
          "the Julia binding '$(b)', which is already the derived binding of" :
          "the model name '$(_django_positional_key(e))' — what '$(other.binding)' lowers to — " *
          "which is already derived by"
        throw(InvalidMigrationError(
          "import: binding_overrides gives '$(_django_ref_label(other))' $(took) " *
          "'$(_django_ref_label(e))'. Honouring it would rename '$(_django_ref_label(e))' to " *
          "something you did not choose — pick another name, or override both."))
      end
      base = e.name
      suffix = 2
      while conflicts(string(base, suffix), e.pins_table)
        suffix += 1
      end
      # A rename nobody asked for is reported (#70): the artifact carries a marker naming the class
      # it collided with, and the console gets a @warn. Before, `class CASCADE` quietly became
      # `CASCADE2` and nothing anywhere said why the binding you expected is not the binding you got.
      other = claimant(e, b)
      @warn "import: binding is already claimed; this model was renamed to keep the generated file loadable" class=_django_ref_label(e) wanted=b renamed_to=Models._model_binding_name(string(base, suffix)) taken_by=(other === nothing ? "a reserved binding" : _django_ref_label(other))
      push!(rename_notes, "# PormG: '$(_django_ref_label(e))' would be the Julia binding " *
                          "'$(b)', which is already " *
                          (other === nothing ? "reserved by the generated module's own imports" :
                                               "used by '$(_django_ref_label(other))'") *
                          " — emitted as '$(Models._model_binding_name(string(base, suffix)))' " *
                          "instead. Its db_table below still names the real table. Use " *
                          "binding_overrides to choose a different name.")
      e.name = string(base, suffix)
      b = Models._model_binding_name(e.name)
    end
    claim!(e, b)
  end

  # Proxy → the concrete model whose table it shares. Resolved AFTER `by_ref`/`by_class` are
  # complete, because the parent may live in another app. Iterated to a fixpoint so a proxy of a
  # proxy (legal Django) lands on the concrete model at the bottom rather than on an intermediate
  # that emits nothing either; the loop is bounded by the number of proxies, so a malformed cycle
  # stops instead of spinning.
  by_proxy = Dict{Tuple{String, String}, _DjangoClass}()
  pending = Tuple{String, String, Union{Nothing, String}, String}[]   # (app_key, class_lower, parent, app)
  for app in apps
    for cls in app.graph.classes
      ci = app.graph.info[cls.name]
      ci.proxy || continue
      push!(pending, (_django_app_key(app.label), lowercase(cls.name), ci.mti_parent,
                      app.label === nothing ? "" : app.label))
    end
  end
  for _ in 1:(length(pending) + 1)
    progressed = false
    for (app_key, class_lower, parent, app_label) in pending
      haskey(by_proxy, (app_key, class_lower)) && continue
      parent === nothing && continue
      home = isempty(app_label) ? nothing : app_label
      # `role` for the same reason `auth_user_model` and `binding_overrides` pass one: an ambiguous
      # proxy/MTI parent is named in a `class Meta`/base list, not in a relation, and telling the
      # reader to qualify a "relation target" sends them looking at fields that have nothing to do
      # with it.
      target = _lookup_class_ref(parent, home, by_ref, by_class; role = "proxy or inherited parent")
      if target === nothing
        # The parent is itself a proxy: take whatever it already resolved to. Searched in the
        # PARENT's app as well as this one — keying only on the child's app meant a proxy whose
        # parent proxy lives in another app never resolved, which also made the outer loop dead code
        # (within one app, Python's define-before-use ordering already resolves any chain in a single
        # inner pass). Same app first, then anywhere, matching `_lookup_class_ref`'s own precedence.
        target = get(by_proxy, (app_key, lowercase(parent)), nothing)
        if target === nothing
          for ((_, cls), resolved) in by_proxy
            cls == lowercase(parent) && (target = resolved; break)
          end
        end
      end
      target === nothing && continue
      by_proxy[(app_key, class_lower)] = target
      progressed = true
    end
    progressed || break
  end

  # Django's `AbstractUser` columns reach a class through abstract bases too, which is what
  # `_inherits_auth_user` walks. Collected here so `settings.AUTH_USER_MODEL` can resolve, and so the
  # error for an ambiguous project can NAME the candidates rather than just count them.
  auth_candidates = [e for e in entries
                     if _inherits_auth_user(apps[e.app_index].graph,
                                            apps[e.app_index].graph.index[e.class])]
  # An EXPLICIT `auth_user_model` that names nothing in this import is not an error — it is the
  # answer for a stock-Django project (#346). `AUTH_USER_MODEL = "auth.User"` is Django's default,
  # and `django.contrib.auth` is not a models.py anyone hands this importer, so there is no candidate
  # to find and no way to import one. Erroring left such a project — the most common shape there is —
  # with no way in at all: the auth branch threw before the degrade path could run, and the message
  # told the user to pass a keyword that then produced a different error.
  #
  # Saying "the user model is auth.User" is information, not a mistake: the importer now knows the
  # target is deliberately outside the set, so those relations degrade like any other external
  # target, with a marker each. The hard error is reserved for the case where the importer genuinely
  # CANNOT TELL — no keyword and not exactly one `AbstractUser` subclass.
  auth_user = if auth_user_model !== nothing
    found = _lookup_class_ref(auth_user_model, nothing, by_ref, by_class; role = "auth_user_model")
    # Deliberately external (`"auth.User"`) and a typo (`"access.Usuario"`) are indistinguishable
    # here — both name a model this import does not have. So it is not an error, and it is not
    # silent either: the console says it once, up front, and every relation it governs carries its
    # own `# PormG:` marker naming the model that was not found.
    found === nothing && @warn(
      "import: auth_user_model names no imported model, so every settings.AUTH_USER_MODEL relation " *
      "will be imported as a plain column. Expected for a stock-Django project (auth.User); a typo " *
      "otherwise.",
      auth_user_model = auth_user_model,
      imported = sort([_django_ref_label(e) for e in entries]))
    found
  elseif length(auth_candidates) == 1
    auth_candidates[1]
  else
    nothing            # 0 or >1 — an error only if something actually references AUTH_USER_MODEL
  end

  return _DjangoClassIndex(entries, by_ref, by_class, by_proxy, auth_candidates, auth_user,
                           auth_user_model, rename_notes)
end

# Resolve a `"app.Class"` / bare `"Class"` reference against the index, WITHOUT the `"self"` and
# `AUTH_USER_MODEL` special cases (which need a declaring class and the auth user respectively).
# `current_app` biases a bare name to the app that wrote it, exactly as Django does; `nothing` means
# "no home app", which is the case for `auth_user_model` and for `binding_overrides` keys.
#
# Django's own rule for the two-part form: the app label matches as written and the MODEL name is
# case-insensitive (`apps.get_model` lowercases it), so `"core.Pessoa"` and `"core.pessoa"` are the
# same reference. Matched case-insensitively on both halves here — app labels are lowercase by
# Django convention, so the extra tolerance can only help.
function _lookup_class_ref(ref::AbstractString, current_app::Union{Nothing, String},
                           by_ref::Dict{Tuple{String, String}, _DjangoClass},
                           by_class::Dict{String, Vector{_DjangoClass}};
                           role::String = "relation target")::Union{_DjangoClass, Nothing}
  text = strip(String(ref))
  isempty(text) && return nothing
  if occursin('.', text)
    parts = split(text, '.')
    length(parts) == 2 || return nothing
    return get(by_ref, (lowercase(strip(parts[1])), lowercase(strip(parts[2]))), nothing)
  end
  # Same app wins, then a globally unique class name.
  if current_app !== nothing
    same = get(by_ref, (_django_app_key(current_app), lowercase(text)), nothing)
    same === nothing || return same
  end
  candidates = get(by_class, lowercase(text), _DjangoClass[])
  length(candidates) == 1 && return candidates[1]
  if length(candidates) > 1
    # `role` because this function also resolves `auth_user_model` and `binding_overrides` keys, and
    # a message calling one of those a "relation target" sends the reader looking at their models
    # instead of at the keyword they typed.
    throw(InvalidMigrationError(
      "import: the $(role) '$(text)' is ambiguous — " *
      join(("'$(_django_ref_label(c))'" for c in candidates), " and ") *
      " both define it. Qualify it the way Django does, as \"<app_label>.$(text)\"."))
  end
  return nothing
end

# Validate and apply `binding_overrides`. Every rejection is a hard error on purpose: an override is
# an explicit instruction, and one that silently does nothing (a typo'd key, a value that cannot be
# the emitted binding) is the failure mode this importer exists to avoid.
function _apply_binding_overrides!(entries::Vector{_DjangoClass},
                                   by_ref::Dict{Tuple{String, String}, _DjangoClass},
                                   by_class::Dict{String, Vector{_DjangoClass}},
                                   binding_overrides::Dict{String, String})
  isempty(binding_overrides) && return nothing
  # Two keys can name ONE class — `"core.Pessoa"` and a bare `"Pessoa"` — and the second silently
  # won, discarding the first with no diagnostic. That is the exact failure this function's own
  # contract says it exists to prevent.
  claimed = Dict{_DjangoClass, String}()
  for key in sort(collect(keys(binding_overrides)))     # sorted: one bad key reports the same first
    value = binding_overrides[key]
    target = _lookup_class_ref(key, nothing, by_ref, by_class; role = "binding_overrides key")
    if target !== nothing && haskey(claimed, target)
      throw(InvalidMigrationError(
        "import: binding_overrides names '$(_django_ref_label(target))' twice — as \"$(claimed[target])\" " *
        "and as \"$(key)\" — asking for two different bindings for one model. Keep one key."))
    end
    target === nothing || (claimed[target] = key)
    target === nothing && throw(InvalidMigrationError(
      "import: binding_overrides key \"$(key)\" names no imported model. Spell it as Django does — " *
      "\"<app_label>.<ClassName>\", or the bare class name when it is unambiguous. Imported: " *
      "$(join(sort([_django_ref_label(e) for e in entries]), ", "))."))
    Base.isidentifier(value) || throw(InvalidMigrationError(
      "import: binding_overrides asks for '$(value)' as the Julia binding of " *
      "'$(_django_ref_label(target))', which is not a legal Julia identifier — the generated file " *
      "would not parse."))
    isempty(lstrip(value, '_')) && throw(InvalidMigrationError(
      "import: binding_overrides asks for '$(value)' as the Julia binding of " *
      "'$(_django_ref_label(target))'. An all-underscore identifier is write-only in Julia: the " *
      "file would load and the model would be invisible to every binding lookup, with no error."))
    # The binding is `uppercasefirst(model.name)` and the override BECOMES `model.name`, so a
    # value that is not already uppercase-first would be emitted as something else — silently not
    # the name that was asked for.
    uppercasefirst(value) == value || throw(InvalidMigrationError(
      "import: binding_overrides asks for '$(value)' as the Julia binding of " *
      "'$(_django_ref_label(target))', but a model binding is `uppercasefirst(name)` — so that " *
      "would be emitted as '$(uppercasefirst(value))'. Write it capitalized: " *
      "'$(uppercasefirst(value))'."))
    target.name = value
    target.overridden = true
  end
  return nothing
end

"""
    _resolve_relation_targets!(fields_dict, owner, index, strict_relations, markers) -> Nothing

Rewrite every FK/O2O/M2M target in `fields_dict` to the Julia BINDING of the model it names, and
degrade the ones that name nothing in this import.

Runs on the field `Dict` rather than on a built `Model_Type` so that degrading a field is a plain
replace-or-`delete!`, and so `model.field_names` is computed once from the final set.

Resolution order is Django's: `"self"` → `settings.AUTH_USER_MODEL` → `"<app>.<Class>"` → a bare
class name, same app first and then a globally unique one.

**Degrade, never drop.** A `ForeignKey("contenttypes.ContentType")` in a project that did not import
`django.contrib` keeps its column as a plain integer and says so in the artifact — the column is
real, only the relation metadata is gone, and PormG's import path is explicitly ETL. Hard-erroring
would make the importer unusable on any project that touches `django.contrib`; `strict_relations =
true` is there for when that is what you want. A ManyToManyField has no column of its own, so an
unresolvable one is dropped rather than degraded.
"""
function _resolve_relation_targets!(fields_dict::Dict{Symbol, Any},
                                    owner::_DjangoClass,
                                    index::_DjangoClassIndex,
                                    strict_relations::Bool,
                                    markers::Vector{String})
  for key in sort(collect(keys(fields_dict)))       # sorted: deterministic markers
    field = fields_dict[key]
    hasproperty(field, :to) || continue
    is_m2m = Models.is_many_to_many_field(field)
    raw = field.to
    raw isa AbstractString || continue              # already a model object; nothing to rewrite

    # `through` is a model reference too, and an unresolvable one is fatal at `set_models`
    # (`_resolve_model_reference` throws). Resolve it first so the M2M drops as a unit.
    if is_m2m && field.through isa AbstractString
      through, _ = _resolve_one_target(field.through, owner, index, strict_relations, markers,
                                       String(key), "through model")
      through === nothing && (delete!(fields_dict, key); continue)
      field.through = through.binding
    end

    target, via_proxy = _resolve_one_target(raw, owner, index, strict_relations, markers,
                                            String(key),
                                            is_m2m ? "ManyToManyField target" : "ForeignKey target")
    if target === nothing
      if is_m2m
        delete!(fields_dict, key)
      else
        fields_dict[key] = _degraded_relation_column(field, owner, String(key))
      end
      continue
    end
    field.to = target.binding
    # The join COLUMNS are not decided here: they depend on the TARGET model's primary key, and the
    # target may not be built yet. See `_pin_m2m_join_columns!`, which runs once every model exists.
    #
    # ONE exception, settled here because the information dies with `ref`: a ManyToManyField pointing
    # at a PROXY. `.to` becomes the concrete parent's binding — that is the table the relation reads
    # — but Django names the join column from the model the field NAMES
    # (`create_many_to_many_intermediary_model` uses `to_model._meta.model_name`), so it is
    # `baseproxy_id`, not `base_id`. Deriving it downstream from `target.class` would emit a column
    # Django never created, and quietly: before proxies resolved at all this M2M was DROPPED with a
    # marker, so getting it wrong here trades a loud failure for a silent one.
    if is_m2m && field.through === nothing && via_proxy !== nothing && field.target_field === nothing
      field.target_field = string(lowercase(String(via_proxy)), "_id")
    end
  end
  return nothing
end

"""
    _pin_m2m_join_columns!(index) -> Nothing

Pin `source_field` / `target_field` on every auto-derived `ManyToManyField` whose columns PormG would
otherwise spell differently from Django.

Django's join-table columns are **always** `<lowercased class name>_id` — the primary key's own name
never enters it. PormG's `_many_to_many_column_name` derives `<lowercased model.name>_<pk field>`, so
the two agree only while BOTH of these hold:

- the emitted `model.name` is still the class name — a cross-app collision rename or a
  `binding_overrides` entry breaks it;
- the model's primary key is called `id` — a legacy schema with `codigo = CharField(primary_key=True)`
  breaks it, and then PormG addresses `driver_codigo` where Django created `driver_id`.

Pinned exactly when one of those fails, never speculatively, so the common case stays clean. This
runs as a separate pass because the target's primary key is only knowable once the target model is
built, and models are built in app order.

A self-referential M2M is the one case where Django does not use `<class>_id` at all: one table
cannot carry the same column twice, so it names the ends `from_<class>_id` / `to_<class>_id`. That
case was unreachable before #346 — `ManyToManyField("self")` died at `set_models` — so resolving
`"self"` without this would have traded a loud failure for a join table with one column doing two
jobs.

The same defect for hand-written models was #364, now fixed in `_relation_from_many_to_many`, which
derives `from_<model>_<pk>` / `to_<model>_<pk>` for a self-relation. This pin is therefore no longer
load-bearing for an `id`-keyed model — the two derivations agree byte for byte — but it is still
required for any other primary key, because Django hardcodes `_id` where PormG carries the pk field
name. Pinning both ends here also routes the field down the explicit branch, which is what keeps the
importer's output independent of PormG's own derivation.
"""
function _pin_m2m_join_columns!(index::_DjangoClassIndex)
  by_binding = Dict{String, _DjangoClass}()
  for e in index.entries
    e.model === nothing || (by_binding[e.binding] = e)
  end
  # `get_model_pk_field` THROWS when a model carries more than one primary key, and a model still
  # can: a class that declares `primary_key=True` on two fields outright builds without complaint —
  # nothing counts primary keys at declaration — so the throw stays reachable from any models.py.
  # `set_models` raises it only for a model that OWNS a ManyToManyField (relation wiring reads the
  # key); otherwise the model registers cleanly and throws at the first read. (The commonest source
  # used to be an `AbstractUser` subclass with a key of its own, which this importer handed a second,
  # injected `id`; that is fixed at the root in `_import_django_apps` — #369.)
  # Calling it eagerly for every entry turned the throw into a raw `ModelDefinitionError` that
  # aborted the WHOLE import — no file, no marker, every other model lost — for a project that has
  # no ManyToManyField anywhere, on both arities. So it is called lazily, only for models that
  # actually own an auto-derived M2M, and a throw skips the pin rather than the import: the field
  # keeps PormG's own derivation, exactly as before this pass existed. The two-primary-key model is
  # broken either way; that is not this pass's to fix or to escalate.
  pk_cache = Dict{_DjangoClass, Union{Nothing, String}}()
  function pk_name(e)
    get!(pk_cache, e) do
      try
        s = Models.get_model_pk_field(e.model)
        s === nothing ? nothing : String(s)
      catch err
        err isa PormGError || rethrow()
        @warn "import: cannot read the primary key, so ManyToMany join columns are left derived" class=_django_ref_label(e) exception=err
        nothing
      end
    end
  end
  for owner in index.entries
    owner.model === nothing && continue
    for (field_name, field) in owner.model.fields
      Models.is_many_to_many_field(field) || continue
      field.through === nothing || continue
      target = field.to isa AbstractString ? get(by_binding, field.to, nothing) : nothing
      (target === nothing || target.model === nothing) && continue
      owner_pk = pk_name(owner)
      target_pk = pk_name(target)
      # An unreadable primary key means "do not know", not "not `id`" — pinning on a guess would
      # write a column name into the artifact with nothing behind it.
      if field.source_field === nothing && owner_pk !== nothing &&
         (lowercase(owner.name) != lowercase(owner.class) || owner_pk != "id")
        field.source_field = string(lowercase(owner.class), "_id")
      end
      if field.target_field === nothing && target_pk !== nothing &&
         (lowercase(target.name) != lowercase(target.class) || target_pk != "id")
        field.target_field = string(lowercase(target.class), "_id")
      end
      if target === owner
        field.source_field = string("from_", lowercase(owner.class), "_id")
        field.target_field = string("to_", lowercase(owner.class), "_id")
      end
    end
  end
  return nothing
end

# One target reference → its class entry, or `nothing` after reporting the degrade.
function _resolve_one_target(raw::AbstractString, owner::_DjangoClass, index::_DjangoClassIndex,
                             strict_relations::Bool, markers::Vector{String},
                             field_key::String, role::String)
  # `parse_field_args` strips the quotes off a plain `"core.Pessoa"`, but a value that reached here
  # through another path may still carry them.
  ref = strip(_strip_py_quotes(strip(String(raw))))

  # Django's own literal for a self-referential relation. Matched exactly, as Django does
  # (`RECURSIVE_RELATIONSHIP_CONSTANT`), so a class actually named `Self` is not shadowed.
  ref == "self" && return (owner, nothing)

  if ref == "settings.AUTH_USER_MODEL" || ref == "AUTH_USER_MODEL"
    index.auth_user === nothing && index.auth_model_ref === nothing && throw(InvalidMigrationError(
      "import: field '$(field_key)' on '$(_django_ref_label(owner))' points at " *
      "settings.AUTH_USER_MODEL, but this import cannot tell which model that is — " *
      (isempty(index.auth_candidates) ?
        "no imported class inherits AbstractUser" :
        "$(length(index.auth_candidates)) do: " *
        join(("'$(_django_ref_label(c))'" for c in index.auth_candidates), ", ")) *
      ". Pass auth_user_model = \"<app_label>.<ClassName>\" — including for a stock-Django project " *
      "that never subclassed AbstractUser, where it is auth_user_model = \"auth.User\" and those " *
      "relations then degrade to plain columns like any other target outside the import. This is a " *
      "hard error on purpose: one omitted keyword would otherwise quietly turn every user relation " *
      "in the project into a plain integer column."))
    # Told, and the answer is a model outside the import (`"auth.User"`): fall through to the
    # ordinary degrade path so the column survives and the artifact says the relation did not.
    index.auth_user === nothing || return (index.auth_user, nothing)
    ref = String(index.auth_model_ref)
  end

  resolved = _lookup_class_ref(ref, owner.app, index.by_ref, index.by_class)
  resolved === nothing || return (resolved, nothing)

  # A PROXY names a real, imported table — its concrete parent's. Django's own FK to a proxy
  # addresses that table, so this is a resolution, not a degrade. The PROXY'S OWN name is handed
  # back too: a ManyToManyField's join column is named from the model referenced, so a relation
  # written against `BaseProxy` gets `baseproxy_id` even though the table is the parent's.
  if !isempty(index.by_proxy)
    key = occursin('.', ref) ?
      (let parts = split(ref, '.'); length(parts) == 2 ?
         (lowercase(strip(parts[1])), lowercase(strip(parts[2]))) : ("\0", "\0") end) :
      (_django_app_key(owner.app), lowercase(ref))
    viaproxy = get(index.by_proxy, key, nothing)
    viaproxy === nothing || return (viaproxy, last(split(ref, '.')))
  end

  message = "field '$(field_key)' on '$(_django_ref_label(owner))' — $(role) '$(ref)' is not in " *
            "the imported app set"
  # A single-app import with NO app label cannot match an app-qualified reference at all — it does
  # not know its own label, so `"racing.Circuit"` looks exactly as foreign as `"auth.Permission"`,
  # even when `Circuit` is right there in the file. That is a one-keyword fix and the marker has to
  # say which keyword, or the reader is left staring at a class the file clearly defines.
  hint = (owner.app === nothing && occursin('.', ref)) ?
    " This connection sets no Django app label, so the importer cannot tell whether " *
    "'$(first(split(ref, '.')))' is this file's own app — pass django_prefix = " *
    "\"$(first(split(ref, '.')))\" if it is." : ""
  strict_relations && throw(InvalidMigrationError(
    "import: $(message), and strict_relations = true.$(hint) Import the app that defines it " *
    "alongside this one, or set strict_relations = false to import the column without its relation."))
  @warn "import: relation target is not in the imported app set; the relation is lost" field=field_key class=_django_ref_label(owner) target=ref role=role
  push!(markers, "# PormG: $(message); " *
                 (role == "ManyToManyField target" || role == "through model" ?
                   "the relation is DROPPED — a ManyToManyField has no column of its own." :
                   "imported as a plain column, the relation is lost.") * hint)
  return (nothing, nothing)
end

# An FK/O2O whose target this import cannot name, reduced to the column Django actually created.
# `BigIntegerField` because Django's default primary key has been `BigAutoField` since 3.2, and a
# too-wide integer column reads the same values a narrower one would.
#
# Every column-shaping option is carried over, not just `null`/`blank`. `unique` is the one that
# actually bites: a `OneToOneField` IS a unique column, so dropping the flag would emit a plain
# nullable bigint where the database has a UNIQUE constraint — and the next `makemigrations` would
# propose DROPPING it. `db_index` is the same story one severity down.
function _degraded_relation_column(field, owner::_DjangoClass, field_key::String)
  # A relation that is also the PRIMARY KEY has nowhere to degrade to: `BigIntegerField` cannot be
  # one (it hardcodes `primary_key = false`), and the implicit `id` was already decided in
  # `_import_django_apps` before this pass runs, so none is synthesized to replace it — this field
  # still counted as the key when that ran. Degrading would emit a model with NO primary key — which
  # breaks `save()`, every ManyToManyField touching it, and the migration planner, none of them where
  # a reader would look. Erroring is the honest outcome even under `strict_relations = false`.
  if field.primary_key
    throw(InvalidMigrationError(
      "import: field '$(field_key)' on '$(_django_ref_label(owner))' is BOTH a relation to a model " *
      "outside this import AND the model's primary key (Django's shared-primary-key pattern). It " *
      "cannot be degraded to a plain column: the column type PormG would fall back to cannot be a " *
      "primary key, so the model would come out with none at all. Import the app that defines the " *
      "target alongside this one, or declare the column by hand."))
  end
  kwargs = Dict{Symbol, Any}(:null => field.null, :blank => field.blank,
                             :unique => field.unique, :db_index => field.db_index,
                             :editable => field.editable)
  field.db_column === nothing || (kwargs[:db_column] = field.db_column)
  field.verbose_name === nothing || (kwargs[:verbose_name] = field.verbose_name)
  field.default === nothing || (kwargs[:default] = field.default)
  return Models.BigIntegerField(; kwargs...)
end

# The physical table for one imported class, by Django's rules. The ONE place that composes an app
# label with a class name (#346) — `Model_to_str` used to do it too, from `settings.django_prefix`,
# and the importer had to mirror its precedence to pin M2M join tables correctly.
#
# `Meta.db_table` is ABSOLUTE in Django and overrides the app label. Without a label the app is
# unknown, so nothing is pinned and PormG's own derivation stands — the status quo for an unprefixed
# single-app import.
#
# That status quo holds only while the handle still IS the class name. `Model_to_str` renders the
# positional slot as `lowercase(model.name)`, and `model.name` is `entry.name` — which pass 1 rewrites
# for a `binding_overrides` entry or for the digit backstop. Once it differs from the class, the
# derivation reproduces the RENAME rather than Django's table: `class Circuit` overridden to `Pista`
# emitted `Models.Model("pista")` and silently moved the model to a table Django never created, and
# `class CASCADE` emitted `Models.Model("cascade2")` where the pre-#346 importer correctly emitted
# `Models.Model("cascade")`.
#
# `Model_to_str` has defended against exactly this since #338 — "when dedup actually changes the
# string AND nothing already pinned the table, pin the PRE-dedup name explicitly"
# (`src/Models.jl:1818-1821`), because a rename with nothing pinned leaves the model loading cleanly
# while querying a table that does not exist. Moving the dedup into pass 1 bypassed that guard: the
# name `Model_to_str` now receives is already unique, so its own dedup never fires. Same rule, applied
# where the rename now happens.
function _django_physical_table(model, app_label::Union{Nothing, String},
                                class_name::AbstractString,
                                handle::AbstractString)::Union{Nothing, String}
  Models.model_has_db_table(model) && return Models.model_table_name(model)
  app_label !== nothing && return string(app_label, "_", lowercase(class_name))
  return lowercase(handle) == lowercase(class_name) ? nothing : lowercase(class_name)
end

"""
    _import_django_apps(apps, render_settings; kwargs...) -> Nothing

The shared body of both `import_models_from_django` methods: index every class, render every model
into one module, write the file.
"""
function _import_django_apps(apps::Vector{_DjangoApp}, render_settings::PormGSettings;
                             file::String,
                             model_path::String,
                             auth_user_model::Union{Nothing, String},
                             strict_relations::Bool,
                             binding_overrides::Dict{String, String},
                             autofields_ignore::Vector{String},
                             parameters_ignore::Vector{String})

  index = _build_class_index(apps, binding_overrides, auth_user_model)

  Instructions = Vector{Any}()
  # #338: two DIFFERENT class names can still sanitize/uppercasefirst to the same Julia binding. One
  # registry per generated file, shared across every class of every app rendered into it. Pass 1
  # already resolved every collision by adjusting `model.name`, so these are no-op backstops now —
  # kept because `Model_to_str` is also reached from `inspectdb`, where nothing pre-resolves.
  taken_bindings = Set{String}(GENERATED_MODULE_RESERVED_BINDINGS)
  taken_names = Set{String}()
  # #347: explicit UniqueConstraint / Index names claimed so far. An index name is unique per
  # database, and `CREATE … IF NOT EXISTS` turns a reused one into a SILENT no-op rather than an
  # error — see `_claim_index_name!`, which owns the rule and the reporting. One registry per
  # generated file, exactly like `taken_bindings` above.
  taken_index_names = Set{String}()
  pending_renders = Tuple{Int, PormGModel, Vector{String}}[]

  # Renames nobody asked for, at the top of the file: they have no declaration of their own to sit
  # above, and a reader who typed `M.Cascade` and got `Cascade2` needs to find out here rather than
  # by grepping the module.
  append!(Instructions, index.rename_notes)

  for app in apps
    graph = app.graph
    # An app that contributes no table gets a line in the ARTIFACT, not just a console warning
    # (#70): whoever opens this file in six months and wonders where `access`' models went needs to
    # see it here. Only when the app was named — a single-app import has nothing to say this about.
    if app.label !== nothing && !any(c -> _is_emitted(graph.info[c.name]), graph.classes)
      push!(Instructions, "# PormG: app '$(app.label)' contributed no model to this file — its " *
                          "models.py declares none the importer recognises. Any relation pointing " *
                          "into it is degraded below.")
    end
    # A class name defined twice at module level is pathological Python, but it used to emit TWO
    # `X = Models.Model(...)` assignments into one module: the file loads, the second silently wins,
    # and the first model is gone. `graph.index` already keeps the first definition for base
    # resolution; this keeps emission agreeing with it. Per app, not per run — two apps declaring the
    # same class name is a collision, handled by pass 1, not a duplicate definition.
    seen_names = Set{String}()

    for class in graph.classes
      class_name = class.name
      # Every report below NAMES this class with `class_label`, never `class_name` (#371). Two apps
      # of one project may each declare `Pessoa`, and the generated file then holds `Core_pessoa`
      # and `Access_pessoa` — so a marker saying `on 'Pessoa'` points at neither. Computed HERE,
      # before the index lookup, because the duplicate-declaration, proxy and MTI reports below all
      # `continue` before `entry` is bound.
      #
      # The rule, applied uniformly from here down: the class a report is ABOUT is app-qualified; a
      # name quoted because the source WROTE it — a base class, an enum, a field, `mti_parent` —
      # stays verbatim, because qualifying it would misquote the models.py.
      class_label = _django_class_label(app.label, class_name)
      ci = graph.info[class_name]

      # A class name declared twice at module level used to emit TWO `X = Models.Model(...)`
      # assignments into one module: the file loads, the second silently wins, and the first model is
      # gone. `graph.info` is memoized by NAME from the first definition, so the duplicate is never
      # classified on its own — which is why the test below is on the DUPLICATE'S OWN shape.
      #
      # Reporting is conditional on purpose. Two `class Foo(models.QuerySet)` blocks lose nothing that
      # reaches the schema, and a comment about a QuerySet in a module that never mentions it is
      # noise. But helper-first / model-second — a `QuerySet` and then the real model under one name —
      # loses a table, and the memoized kind says `:not_a_model`, so only the duplicate's own field
      # declarations reveal it.
      if class_name in seen_names
        if _is_emitted(ci) || _declares_fields(class)
          @warn "import: class name is declared more than once at module level; only the first declaration is used" class=class_label
          push!(Instructions, "# PormG: '$(class_label)' is declared more than once in this " *
                              "models.py — only the FIRST declaration is used here. Python binds the " *
                              "last one, so this may not be the class you expect.")
        end
        continue
      end
      push!(seen_names, class_name)

      # ── Classes that produce no table ──────────────────────────────────────────────────────────
      # A skipped model has no declaration for a marker to sit above, so the marker becomes a
      # standalone comment in the generated module. That is the #70 convention applied one level up:
      # the artifact itself shows what is missing, instead of the gap living only in a console warning
      # the reader of the file will never see.
      if ci.kind === :not_a_model && ci.ancestry_lost
        # NOT silent, unlike its neighbours below. Every base is unresolvable and the body declares
        # no column, so this is either a helper or a model whose every field lives in a base the
        # importer cannot see — and nothing in the source separates the two. Skipping was the right
        # call and saying nothing was not: a real model then left no trace anywhere.
        @warn "import: class skipped — no resolvable base and no field of its own" class=class_label bases=join(ci.unresolved, ", ")
        push!(Instructions, "# PormG: class '$(class_label)' inherits " *
                            join(("'$(b)'" for b in ci.unresolved), ", ") *
                            _bound_module_note(graph, ci.unresolved) *
                            ", and declares no field of its own — not imported. If it is a model, " *
                            "its columns all come from that base: " * _resolve_base_advice(app.label) *
                            _declaring_apps_hint(graph, [(b, graph.self) for b in ci.unresolved]))
        continue
      elseif ci.kind === :not_a_model || ci.kind === :abstract
        continue                       # a QuerySet/Manager/Form/enum/helper, or a base — silent
      end

      if ci.proxy
        @warn "import: proxy model shares its parent's table; not imported" class=class_label
        push!(Instructions, "# PormG: model '$(class_label)' is a Django proxy (Meta.proxy = True) — " *
                            "not imported, because it has no table of its own.")
        continue
      elseif ci.kind === :mti
        @warn "import: Django multi-table inheritance has no PormG equivalent; model not imported" class=class_label parent=ci.mti_parent
        push!(Instructions, "# PormG: model '$(class_label)' inherits the concrete model " *
                            "'$(ci.mti_parent)' (Django multi-table inheritance) — not imported. " *
                            "Django keys the child table on a '$(lowercase(String(ci.mti_parent)))_ptr_id' " *
                            "one-to-one to the parent, which PormG cannot express.")
        continue
      end

      # Pass 1 walked the same classes through the same predicate, so this lookup cannot miss. If it
      # ever does, the generated file would carry FKs naming a binding it does not define — fail here,
      # where the cause is one function away, rather than at the user's `set_models`.
      entry = get(index.by_ref, (_django_app_key(app.label), lowercase(class_name)), nothing)
      entry === nothing && throw(InvalidMigrationError(
        "import: internal — class '$(class_label)' is being emitted but was not indexed. This is a " *
        "PormG bug; please report it with the models.py that triggered it."))

      # `# PormG:` lines to emit directly above this model's declaration.
      markers = String[]

      # An abstract base declared elsewhere (`from core.models import TimeStampedModel`) cannot be
      # merged, so the model is imported WITHOUT its columns. Skipping instead would re-create the
      # vanishing-model bug this issue exists to close; importing with a loud marker keeps the table
      # and names exactly what is absent. Importing the defining app alongside this one resolves it —
      # which is what the multi-app arity is for.
      # Walked over the ABSTRACT ANCESTORS too, not just this class's own base list: an abstract base
      # with an unresolvable base of its own loses columns identically, and it emits nothing to hang a
      # marker on, so its gap would otherwise reach the file unannounced.
      unresolved_bases = _inherited_unresolved(graph, class)
      if !isempty(unresolved_bases)
        for (b, _) in unresolved_bases
          @warn "import: base class is not defined in this file; any fields it declares are missing from the imported model" class=class_label base=b
        end
        push!(markers, "# PormG: model '$(class_label)' inherits " *
                       join(("'$(b)'" for (b, _) in unresolved_bases), ", ") *
                       ", not defined in " *
                       (app.label === nothing ? "this file" : "any app of this import") *
                       " — any fields declared there are MISSING below. Add them by hand, or " *
                       (app.label === nothing ?
                         "pass every app of the project as \"<app_label>\" => \"<models.py>\" pairs " *
                         "so a base in another app is merged." :
                         "add the app that defines them to the pair list.") *
                       _declaring_apps_hint(graph, unresolved_bases))
      end

      # Django would hand this model its abstract base's `db_table`, giving every child of that base
      # the same physical table. Refused deliberately (see `_effective_meta`) — and reported, because
      # a silently different table name is the defect this issue is about.
      db_table_base = _abstract_db_table_base(graph, class)
      if db_table_base !== nothing
        @warn "import: db_table on an abstract base is not inherited; the child keeps its own derived table name" class=class_label base=db_table_base
        push!(markers, "# PormG: abstract base '$(db_table_base)' declares Meta.db_table — NOT " *
                       "inherited by '$(class_label)', because that would point every child of " *
                       "'$(db_table_base)' at one table. Declare db_table on this model if it really " *
                       "shares that table.")
      end

      # Abstract bases merge by CONCATENATION, ancestors first: process_class_fields! writes into a
      # Dict, so the last write wins and the child overrides its parents for free.
      class_content = vcat(_inherited_statements(graph, class), class.body)

      # Initialize fields_dict
      fields_dict = Dict{Symbol, Any}()

      # Process fields separately
      # `class_name` and `class_label` both go down, and they are not interchangeable: the first is
      # the enum scope key, the second is what the reports NAME (#371). See `process_class_fields!`.
      declared_pk = process_class_fields!(fields_dict, class_content, class_name,
                                          _inherits_auth_user(graph, class), autofields_ignore,
                                          parameters_ignore, markers, graph.enums,
                                          _enum_scopes(graph, class); class_label = class_label)

      # Django's implicit `id`, added only when nothing claimed the key — DERIVED, per field, from
      # what was built and from what the models.py declared, never tracked with a class-wide flag
      # (#369). Such a flag desynchronized from `fields_dict` in both directions: the `AbstractUser`
      # branch set it before a single field had been read, so a user table declaring its own key got
      # a SECOND primary key; and it stayed set when a class overrode a `primary_key=True` field
      # inherited from an abstract base with a plain one — legal Django — leaving a model with no key
      # and no `id` either.
      #
      # BOTH readings are needed, and they disagree in opposite directions:
      #   - the built field alone misses `codigo = models.IntegerField(primary_key=True)`, because
      #     most PormG field types refuse `primary_key` and construct with `false` — and injecting
      #     `id` there would name a column the Django table does not have;
      #   - the declaration alone misses `codigo = models.AutoField()`, which declares nothing but
      #     builds a field that IS the key, because PormG's `AutoField` defaults `primary_key = true`.
      # `get_model_pk_field`, which reads this model downstream, sees only the first.
      built_pk = any(f -> f.primary_key, values(fields_dict))
      if !built_pk && isempty(declared_pk)
          fields_dict[:id] = Models.IDField()
      end

      # Declared keys that did NOT survive into a built one — the field type refused `primary_key`
      # and the column came through plain. Tested per declaration rather than as "no key was built",
      # because a class can lose one key and still have another: PormG then keys the model on a
      # different column from the one Django keys its table on, and that disagreement is exactly as
      # worth reporting as having no key at all.
      lost_pk = sort(String[String(k) for k in declared_pk
                            if !(haskey(fields_dict, k) && fields_dict[k].primary_key)])
      if !isempty(lost_pk)
        @warn "import: a declared primary key is a field type PormG cannot key on; the column is imported without it" class=class_label fields=join(lost_pk, ", ") model_still_has_a_key=built_pk
        push!(markers, "# PormG: '$(class_label)' declares its primary key on " *
                       join(("'$(f)'" for f in lost_pk), ", ") *
                       " — a field type PormG cannot make a primary key (only IDField, AutoField, " *
                       "CharField, UUIDField, ForeignKey and OneToOneField can), so the column is " *
                       "imported WITHOUT it. " *
                       (built_pk ?
                          "Another field on this model is a primary key, so PormG keys it on that " *
                          "one while Django keys the table on the column above — they disagree." :
                          "This model therefore has NO primary key. No `id` was substituted, " *
                          "because Django's table has no such column — but that leaves the model " *
                          "unusable by anything that needs a key: a ManyToManyField pointing at it " *
                          "makes the WHOLE generated file fail to load, and a ForeignKey pointing " *
                          "at it loads and is silently wrong.") *
                       " Re-declare the key by hand as a CharField/UUIDField primary key.")
      end

      # Rewrite every relation target to the BINDING of the model it names, before the model is
      # built — degrading a field is a plain replace/`delete!` on this Dict, and `field_names` is
      # then computed once from the final set.
      _resolve_relation_targets!(fields_dict, entry, index, strict_relations, markers)

      # Collect all create instructions
      # THE symmetric half of the index guard above, and the more dangerous direction (#346). Pass 1
      # handed this class a binding, so every ForeignKey to it was rewritten to that binding; if pass
      # 2 then emits nothing, the generated file references a binding it does not define and
      # `set_models` throws in the consuming app, pointing at the wrong model.
      #
      # A TRIPWIRE, not a live guard: the one path that reached it — `autofields_ignore` claiming a
      # `primary_key=True` field and then dropping the column, leaving `fields_dict` empty — is fixed
      # at its root in the field loop, so mutation testing confirms this line is now unreachable and
      # deleting it fails nothing. It stays because the failure it catches is silent in the artifact
      # and only surfaces in the consuming app, and because `fields_dict` gains contributors over
      # time (inherited statements, synthetic keys, degraded relations) — any of which could empty it
      # again. A hard error rather than a marker: there is no such thing as a table with no columns,
      # so reaching this means the two passes disagree, and that has to be loud.
      isempty(fields_dict) && throw(InvalidMigrationError(
        "import: internal — '$(_django_ref_label(entry))' was indexed but has no field to emit, so " *
        "any relation pointing at it would name a binding this file does not define. This is a " *
        "PormG bug; please report it with the models.py that triggered it."))
      # `entry.name`, not `class_name`: a cross-app collision or a `binding_overrides` entry may
      # have renamed this model. `class_name` stays the source of every DJANGO-derived name below
      # (the table, the join columns), because those follow the Python class, not our handle.
      # `class_label` is the third spelling and does neither job — it only NAMES this class in a
      # report (#371), and like `class_name` it follows the Python class, so a renamed model is
      # still reported under the name its models.py actually uses.
      model = Models.Model(entry.name, fields_dict)
      meta_options = _effective_meta(graph, class)

      # `Meta.db_table` is ABSOLUTE in Django — it overrides the derived name, and it overrides a
      # configured app label too. Applied first so `_django_physical_table` below sees it.
      if haskey(meta_options, "db_table")
        dt = _meta_string_literal(meta_options["db_table"])
        if dt === nothing || isempty(dt)
          @warn "import: Meta.db_table is not a non-empty string literal; ignored" class=class_label value=meta_options["db_table"]
          push!(markers, "# PormG: Meta.db_table on '$(class_label)' is not a string literal — " *
                         "ignored; the table name below is derived from the class name.")
        else
          Models._apply_db_table!(model, dt)
        end
      end

      # The physical table, resolved HERE and nowhere else (#346). `Model_to_str` renders whatever
      # `db_table` the model carries and derives nothing of its own, so this is the single place
      # an app label becomes a table name — and the M2M pin below reads the result rather than
      # re-deriving it.
      physical_table = _django_physical_table(model, app.label, class_name, entry.name)
      physical_table === nothing || Models._apply_db_table!(model, physical_table)

      # Pin the join table of every AUTO-DERIVED ManyToManyField (#345). Django names it
      # `<owning model's db_table>_<field>` (`ManyToManyField._get_m2m_db_table`, which reads
      # `opts.db_table`); PormG's `_many_to_many_table_name` derives `<logical model>_<field>`
      # with the app label stripped, so on a prefixed app the two have never agreed and PormG
      # addressed a table Django did not create.
      #
      # Only when a table is pinned: without an app label the app is unknown, `model_table_name`
      # falls back to the logical name, and pinning that would freeze PormG's own derivation as if
      # it were Django's. A `db_table=` written on the field in the Django source is authoritative
      # and left alone — same precedence as `Meta.db_table` above.
      #
      # `through` fields are skipped because Django ignores `db_table` entirely when a through
      # model is given: the join table IS the through model's table. Emitting one anyway is inert
      # today (`_relation_from_many_to_many` overwrites it) but writes a false claim into the
      # artifact.
      if Models.model_has_db_table(model)
        owner_table = Models.model_table_name(model)
        for (field_name, field) in model.fields
          Models.is_many_to_many_field(field) || continue
          field.db_table === nothing || continue
          field.through === nothing || continue
          field.db_table = string(owner_table, "_", field_name)
        end
      end

      # The built model is stashed on its index entry so the join-COLUMN pass below can consult
      # both ends of every ManyToManyField. A column depends on the TARGET's primary key, and the
      # target may not be built yet when its owner is — which is the whole reason that pass is
      # deferred until every model exists.
      entry.model = model

      # Composite uniqueness from BOTH Django spellings (#19, #341). Each constraint is validated
      # on its own so one bad entry cannot take the others with it — which is what the coarse
      # try/catch around the whole apply used to do.
      constraints = Models.UniqueConstraint[]
      if haskey(meta_options, "unique_together")
        try
          append!(constraints, parse_meta_unique_together(meta_options["unique_together"], fields_dict, class_label, markers))
        catch e
          @warn "import: could not parse unique_together; skipping" class=class_label exception=e
          push!(markers, "# PormG: Meta.unique_together on '$(class_label)' could not be read — dropped.")
        end
      end
      if haskey(meta_options, "constraints")
        append!(constraints, _parse_meta_constraints(meta_options["constraints"], fields_dict, class_label, markers))
      end
      for c in constraints
        # The same duplicate-declaration collapse the index loop below does, for the same reason:
        # `unique_together = (('a','b'), ('a','b'))` — a copy-paste in a real models.py — derives ONE
        # index name twice, and the planner then refuses the model with advice ("give each a distinct
        # name") that cannot be followed. The generated file loads and is unmigratable.
        if any(p -> p.fields == c.fields && p.name == c.name, _existing_unique_constraints(model))
          @warn "import: duplicate unique constraint; keeping one" class=class_label fields=c.fields
          push!(markers, "# PormG: a duplicate constraint over ($(join(c.fields, ", "))) on " *
                         "'$(class_label)' was dropped — the same constraint is declared twice.")
          continue
        end
        # An explicit name reused across models is a silent no-op at migration time; surrender it and
        # let PormG derive one per table. See `_claim_index_name!`.
        kept = _claim_index_name!(taken_index_names, c.name, markers, class_label, "constraint", c.fields)
        kept === c.name || (c = Models.UniqueConstraint(fields = c.fields, name = kept))
        try
          Models._apply_unique_constraints!(model, vcat(_existing_unique_constraints(model), [c]))
        catch e
          # A declaration that never lands must not burn its name for every later model.
          kept === nothing || delete!(taken_index_names, kept)
          @warn "import: could not apply a unique constraint; skipping it" class=class_label fields=c.fields exception=e
          push!(markers, "# PormG: a constraint over ($(join(c.fields, ", "))) on '$(class_label)' " *
                         "was dropped — $(replace(sprint(showerror, e), "\n" => " "))")
        end
      end

      # Composite indexes from BOTH Django spellings (#347), the non-unique mirror of the block
      # above. `single` carries the one-column entries, which are `db_index = true` on the field
      # rather than a `Models.Index` — an exact translation, so nothing is reported for them.
      indexes = Models.Index[]
      single_column_indexes = String[]
      if haskey(meta_options, "indexes")
        ix, sc = _parse_meta_indexes(meta_options["indexes"], fields_dict, class_label, markers)
        append!(indexes, ix); append!(single_column_indexes, sc)
      end
      if haskey(meta_options, "index_together")
        ix, sc = _parse_meta_index_together(meta_options["index_together"], fields_dict, class_label, markers)
        append!(indexes, ix); append!(single_column_indexes, sc)
      end
      for ix in indexes
        # `Meta.indexes` and `Meta.index_together` can declare the SAME index — Django's own
        # index_together → indexes deprecation migration produces exactly that intermediate state,
        # and so does a `Meta.indexes` that simply repeats itself. Two identical unnamed declarations
        # derive ONE index name, which the planner then rejects with advice ("give each a distinct
        # name") that cannot be followed: there is no name to change, only a declaration to delete.
        # The generated file would load and be unmigratable. Collapse it here, where the Django
        # source is still in view to name in the report.
        if any(p -> p.fields == ix.fields && p.name == ix.name, _existing_indexes(model))
          @warn "import: duplicate index declaration; keeping one" class=class_label fields=ix.fields
          push!(markers, "# PormG: a duplicate index over ($(join(ix.fields, ", "))) on " *
                         "'$(class_label)' was dropped — the same index is declared twice " *
                         "(Meta.indexes and Meta.index_together can overlap).")
          continue
        end
        kept = _claim_index_name!(taken_index_names, ix.name, markers, class_label, "index", ix.fields)
        kept === ix.name || (ix = Models.Index(fields = ix.fields, name = kept))
        try
          Models._apply_indexes!(model, vcat(_existing_indexes(model), [ix]))
        catch e
          # A declaration that never lands must not burn its name for every later model.
          kept === nothing || delete!(taken_index_names, kept)
          @warn "import: could not apply an index; skipping it" class=class_label fields=ix.fields exception=e
          push!(markers, "# PormG: an index over ($(join(ix.fields, ", "))) on '$(class_label)' " *
                         "was dropped — $(replace(sprint(showerror, e), "\n" => " "))")
        end
      end
      for col in unique(single_column_indexes)
        f = get(model.fields, col, nothing)
        if f === nothing
          # Unreachable in practice — `col` was resolved against the same dict the model was built
          # from — but reporting "this field type has no db_index option" for a MISSING field would
          # name the wrong cause.
          @warn "import: single-column index names a field the model does not carry; dropped" class=class_label field=col
          push!(markers, "# PormG: a single-column index on '$(class_label)'.$(col) was dropped — " *
                         "that field is not on the imported model.")
        elseif hasproperty(f, :primary_key) && getproperty(f, :primary_key) === true
          # A primary key already carries an index on both backends, so Django's index on it is
          # REDUNDANT, not lost — nothing to report. It also must not fall through: `sIDField` is
          # the one IMMUTABLE field struct (src/models/fields.jl) and it does carry `db_index`, so
          # the assignment below raises a raw `setfield!` ErrorException that nothing catches — one
          # legal `Meta.indexes = [Index(fields=['id'])]` used to abort the entire import with no
          # marker, no warning and no models file.
          @debug "import: single-column index on a primary key is redundant; the key is already indexed" class=class_label field=col
        elseif ismutable(f) && hasproperty(f, :db_index)
          f.db_index = true
        else
          # `PasswordField` excludes `db_index` entirely (src/models/fields.jl), and any future
          # immutable field type lands here too rather than raising.
          @warn "import: single-column index maps to db_index, which this field cannot carry; dropped" class=class_label field=col
          push!(markers, "# PormG: a single-column index on '$(class_label)'.$(col) was dropped — " *
                         "that field type has no db_index option.")
        end
      end

      # Every remaining Meta option is REPORTED. An unrecognised key is a typo or a Django option
      # this importer has not met, and neither is safe to pass over quietly. Sorted so the
      # generated file is byte-stable across runs.
      for k in sort(collect(keys(meta_options)))
        k in _META_OPTIONS_CONSUMED && continue
        reason = get(_META_OPTION_REASONS, k, nothing)
        if reason === nothing
          @warn "import: unrecognised Meta option; dropped" option=k class=class_label
          push!(markers, "# PormG: Meta.$(k) on '$(class_label)' is not recognised — dropped.")
        else
          @warn "import: Meta option has no PormG equivalent; dropped" option=k class=class_label reason=reason
          push!(markers, "# PormG: Meta.$(k) on '$(class_label)' — dropped: $(reason).")
        end
      end

      # Rendering is DEFERRED, but its slot in the file is claimed now, so models and the
      # standalone `# PormG:` comments around them keep source order. `_pin_m2m_join_columns!`
      # below still has models to mutate, and it needs every one of them to exist first.
      push!(Instructions, "")
      push!(pending_renders, (length(Instructions), model, copy(markers)))

    end
  end

  # Every model exists now, so both ends of every ManyToManyField are readable.
  _pin_m2m_join_columns!(index)

  # Rendered in the order the slots were claimed, which is the order the models were built — so the
  # shared `taken_bindings` / `taken_names` sets see the same sequence they would have seen inline.
  #
  # The FILE's order comes from the slots, not from this loop, so reversing it is an equivalent
  # mutation today: pass 1 already made every binding unique, which makes `Model_to_str`'s own dedup
  # a no-op and leaves nothing for sequence to change. It stops being equivalent the moment two
  # emitted names differ only in case — distinct bindings, one positional name — where `taken_names`
  # does fire and the winner depends on who is rendered first. Keeping build order costs nothing and
  # keeps that outcome matching the file the reader sees.
  for (slot, model, markers) in pending_renders
    rendered = Models.Model_to_str(model; taken_bindings=taken_bindings, taken_names=taken_names)
    Instructions[slot] = isempty(markers) ? rendered : join(markers, "\n") * "\n" * rendered
  end

  generate_models_from_db(file, Instructions, render_settings, path=model_path)
end

# Resolve the config, then the render-only Settings that `output_path`/`django_prefix` override
# without mutating it, then the output path — the preamble both arities share. Returns `nothing` when
# the config key does not exist (both methods then return early, as before).
function _django_render_settings(db::String, output_path::Union{Nothing, String},
                                 django_prefix::Union{Nothing, String, Missing})
  settings::Union{Nothing, PormGSettings} = nothing
  try
    settings = Configuration.get_settings(db)
  catch e
    @error("The database $(db) does not exists in the config")
    return nothing
  end
  # `db` is the config key used to resolve Settings; by default the output directory and app label
  # come from that config (matching import_models_from_postgres). When importing a *foreign* Django
  # app staged elsewhere, `output_path`/`django_prefix` override those without mutating the shared
  # config — a throwaway render-only Settings (no DB connection) carries the overrides.
  # `django_prefix === missing` inherits the config's prefix; `nothing` emits unprefixed tables; a
  # String forces that prefix.
  return output_path === nothing && django_prefix === missing ? settings :
    Configuration.Settings(
      db_def_folder = output_path === nothing ? settings.db_def_folder : output_path,
      django_prefix = django_prefix === missing ? settings.django_prefix : django_prefix,
    )
end

# The existing-file / mkpath guard, shared by both arities. `true` means "go ahead".
function _django_output_ready(model_output_path::String, model_path::String, force_replace::Bool)::Bool
  if isfile(model_output_path) && !force_replace
      @warn(
          "The file '$(model_output_path)' already exists, use force_replace=true to replace it"
      )
      return false
  elseif !ispath(model_path)
      mkpath(model_path)
  end
  return true
end

# A `models.py` given as a PATH is read; given as source text it is used as is. The newline test is
# what tells them apart — a path never contains one.
function _django_source_text(model_py_string::String)::String
  if !occursin('\n', model_py_string) && isfile(model_py_string)
    return django_to_string(model_py_string)
  end
  return model_py_string
end

"""
  import_models_from_django(model_py_string::String; db::String = DB_PATH, force_replace::Bool = false, file::String = "automatic_models.jl", output_path::Union{Nothing, String} = nothing, django_prefix::Union{Nothing, String, Missing} = missing, auth_user_model::Union{Nothing, String} = nothing, strict_relations::Bool = false, binding_overrides::AbstractDict = Dict{String, String}(), autofields_ignore::Vector{String} = ["Manager"], parameters_ignore::Vector{String} = ["help_text"])

Imports Django models from a given `model.py` file content string and generates corresponding Julia models.

For a project whose models are split across several Django apps, pass `"<app_label>" => "<path>"`
pairs instead — see the [`Vector{Pair}` method](@ref import_models_from_django(::AbstractVector{<:Pair})).

# Arguments
- `model_py_string::String`: The content of the `model.py` file as a string; user django_to_string(path) to read the file; or insert the file path.
- `db::String`: The configuration key used to resolve settings (usually the db folder path). The generated file is written to that configuration's `db_def_folder` unless `output_path` overrides it, and the table-name prefix comes from that configuration's `django_prefix` unless `django_prefix` overrides it. Defaults to `DB_PATH`.
- `force_replace::Bool`: If `true`, forces replacement of the existing models file. Defaults to `false`.
- `file::String`: The name of the file to save the generated models. Defaults to `"automatic_models.jl"`.
- `output_path::Union{Nothing, String}`: Directory to write the generated file into, overriding the resolved config's `db_def_folder`. Use this to stage a *foreign* Django app's models next to their copied `model.py` (e.g. `"db_gal"`) while still resolving `db` for its Settings. Defaults to `nothing` (use `db_def_folder`).
- `django_prefix::Union{Nothing, String, Missing}`: The Django **app label** whose tables are being imported — in practice, the prefix Django puts on them. `missing` inherits the resolved config's `django_prefix`; `nothing` emits unprefixed table names; a `String` (e.g. `"estoque"`) forces `<prefix>_<table>`. Use this when the imported app uses a different Django `app_label` than the `db` config's. Defaults to `missing` (inherit).

  Since #345 the prefix is written into **`db_table`**, not into the positional model name:
  `class Dim_ibge` under `django_prefix = "estoque"` emits
  `Dim_ibge = Models.Model("dim_ibge", db_table = "estoque_dim_ibge", …)`. A `Meta.db_table` in the
  Django source still overrides it, exactly as in Django. An empty string is treated as no prefix.

  Each auto-derived `ManyToManyField` also gets its join table pinned to Django's spelling, which is
  `<the owning model's table>_<field>` — so `estoque_dim_ibge_ufs` normally, but
  `<Meta.db_table>_<field>` when the class declares one. PormG's own derivation
  (`<logical model>_<field>`) reproduces neither. A field carrying its own `db_table`, or a
  `through=`, is left alone.
- `auth_user_model::Union{Nothing, String}`: which model `settings.AUTH_USER_MODEL` refers to, spelled as Django spells it (`"access.User"`, or a bare `"User"` when unambiguous). Defaults to `nothing`, which auto-detects the single class inheriting `AbstractUser`. If a relation names `settings.AUTH_USER_MODEL` and there is not exactly one candidate, the import raises `InvalidMigrationError` naming them — deliberately hard, since one omitted keyword would otherwise turn every user relation in the project into a plain integer column.
- `strict_relations::Bool`: when `false` (the default), a relation whose target is not in this import keeps its column and loses only the relation metadata, with a `# PormG:` marker saying so. `true` raises `InvalidMigrationError` instead. The lenient default is what makes the importer usable on a project that touches `django.contrib`.
- `binding_overrides::AbstractDict`: `"<app_label>.<ClassName>" => "<JuliaBinding>"` (or a bare class name when unambiguous), to spell a generated binding differently from the derived one. The value must be a legal, capitalized Julia identifier that no other model claims; every violation is an error rather than a silent fallback.
- `autofields_ignore::Vector{String}`: Fields to ignore automatically. Defaults to `["Manager"]`.
- `parameters_ignore::Vector{String}`: Parameters to ignore during field processing. Defaults to `["help_text"]`.

# Description
This function checks if the specified models file already exists and creates it if necessary. It parses the provided `model.py` content string to extract Django model classes and their fields. For each class, it processes the fields, adds a primary key if none exists, and generates the corresponding Julia model code. The generated models are then saved to the specified file.

Relation targets are resolved to the Julia binding of the model they name (#346): `"self"`,
`"<app_label>.<ClassName>"` naming this file's own app, and `settings.AUTH_USER_MODEL` all work — all
three used to reach the generated file verbatim and throw at `set_models`.

`output_path` and `django_prefix` never mutate the shared `db` config: when either is set, a
throwaway render-only `Settings` (no database connection) drives the output directory and prefix.

# Example
import_models_from_django(django_to_string("/home/user/models.py"))

# Stage a foreign Django app (its models.py copied into db_gal/) with its own folder and prefix:
import_models_from_django("db_gal/models.py"; db="db", file="gal_models.jl",
                          output_path="db_gal", django_prefix="estoque", force_replace=true)
"""
function import_models_from_django(
    model_py_string::String;
    db::String = DB_PATH,
    force_replace::Bool = false,
    file::String = "automatic_models.jl",
    output_path::Union{Nothing, String} = nothing,
    django_prefix::Union{Nothing, String, Missing} = missing,
    auth_user_model::Union{Nothing, String} = nothing,
    strict_relations::Bool = false,
    binding_overrides::AbstractDict = Dict{String, String}(),
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
  )

  render_settings = _django_render_settings(db, output_path, django_prefix)
  render_settings === nothing && return
  model_path = render_settings.db_def_folder
  _django_output_ready(joinpath(model_path, file), model_path, force_replace) || return

  # Recover and classify every module-level class (#340 parses them, #341 resolves their bases).
  # The parser itself is the validity test: the regex that used to guard this required the class
  # header to sit on ONE physical line, so once the parser learned to read a wrapped header it was
  # rejecting files it could handle.
  graph = _django_class_graph(_django_source_text(model_py_string))

  # check if model_py_string is a model.py file content and not a path
  if !any(c -> _is_emitted(graph.info[c.name]), graph.classes)
    @warn("The string does not contain a valid model.py content")
    return
  end

  # One app, whose label is the configured/overridden `django_prefix`. `_django_app_label` rather
  # than the raw field: an EMPTY prefix is the absence of one, spelled badly (#345), and treating it
  # as a label derives `_dim_uf` for a table called `dim_uf`.
  apps = [_DjangoApp(Models._django_app_label(render_settings), graph)]

  _import_django_apps(apps, render_settings;
                      file = file, model_path = model_path,
                      auth_user_model = auth_user_model,
                      strict_relations = strict_relations,
                      binding_overrides = Dict{String, String}(String(k) => String(v) for (k, v) in binding_overrides),
                      autofields_ignore = autofields_ignore,
                      parameters_ignore = parameters_ignore)
end

"""
  import_models_from_django(apps::AbstractVector{<:Pair}; db::String = DB_PATH, force_replace::Bool = false, file::String = "automatic_models.jl", output_path::Union{Nothing, String} = nothing, auth_user_model::Union{Nothing, String} = nothing, strict_relations::Bool = false, binding_overrides::AbstractDict = Dict{String, String}(), autofields_ignore::Vector{String} = ["Manager"], parameters_ignore::Vector{String} = ["help_text"])

Import a **multi-app** Django project — `"<app_label>" => "<models.py path or source>"` pairs — into
one generated module.

```julia
import_models_from_django(
  ["core"    => "server/core/models.py",
   "access"  => "server/access/models.py",
   "imports" => "server/imports/models.py"];
  db = "sgrh", file = "models.jl", force_replace = true)
```

# Why one module and not one per app

A Django project with N apps is ONE database, and PormG is structurally one models file per
connection: `makemigrations`/`migrate` resolve a single `joinpath(db, settings.model_file)` and load
it into a single module. One module per app would not merely be unsupported — it would be invisible
to the migration engine. Emitting every app into one module also makes every cross-app foreign key a
same-module binding, which is the only thing `_resolve_target_model` can resolve.

Each model's physical table is `<app_label>_<lowercased class name>` (Django's own derivation), pinned
as `db_table`, so one file carries every app's tables. A `Meta.db_table` still overrides it.

# Class-name collisions

When two apps declare the same class name, **both** are renamed to `<app>_<class>` — binding
`Core_pessoa` and `Access_pessoa`, never `Pessoa` and `Pessoa2`. Renaming only the second would make
the output depend on the order the apps were listed, and `set_models` keys reverse accessors on the
logical name, so one model would answer to `pessoa` and the other to `pessoa2`. The rename is
lossless because `db_table` carries the real table either way. Use `binding_overrides` to choose a
different spelling.

# Arguments

Every keyword of the single-app method applies, except `django_prefix`: the app label now comes from
each pair. A `django_prefix` on the resolved config is **rejected**, not ignored — `get_model_name`
would strip that one prefix from *every* logical name, so `core_pessoa` would become `pessoa` while
`access_pessoa` survived intact, and the reverse lookup would then want `Pessoa` while the binding is
`Core_pessoa`. Cheap to detect here; near-impossible to diagnose at query time.

# Relation targets

`"self"`, `"<app_label>.<ClassName>"`, a bare `"<ClassName>"` (same app first, then a globally unique
one), and `settings.AUTH_USER_MODEL` all resolve. A target outside the imported app set keeps its
column and loses the relation, with a `# PormG:` marker — see `strict_relations`.

See also [`import_models_from_django(::String)`](@ref), [`django_to_string`](@ref).
"""
function import_models_from_django(
    apps::AbstractVector{<:Pair};
    db::String = DB_PATH,
    force_replace::Bool = false,
    file::String = "automatic_models.jl",
    output_path::Union{Nothing, String} = nothing,
    auth_user_model::Union{Nothing, String} = nothing,
    strict_relations::Bool = false,
    binding_overrides::AbstractDict = Dict{String, String}(),
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
  )

  isempty(apps) && throw(InvalidMigrationError(
    "import: the app list is empty. Pass at least one \"<app_label>\" => \"<models.py>\" pair."))

  # `django_prefix = nothing` on the render Settings: the app label is per pair now, and a
  # connection-level prefix is refused below rather than silently combined with it.
  render_settings = _django_render_settings(db, output_path, nothing)
  render_settings === nothing && return

  configured = Models._django_app_label(Configuration.get_settings(db))
  configured === nothing || throw(InvalidMigrationError(
    "import: connection '$(db)' sets django_prefix = \"$(configured)\", which a multi-app import " *
    "cannot honor — the app label is per model here, and one connection-level prefix would be " *
    "stripped from EVERY logical name by get_model_name, leaving half the project's reverse " *
    "lookups pointing at names that do not exist. Remove django_prefix from that connection's " *
    "config; a single-app import that still needs it can pass django_prefix = \"$(configured)\" to " *
    "that call instead."))

  labels = Set{String}()
  staged = _AppScope[]
  for pair in apps
    label = strip(String(first(pair)))
    isempty(label) && throw(InvalidMigrationError(
      "import: an app label is empty. Every pair needs the Django app_label its tables are prefixed " *
      "with, e.g. \"core\" => \"server/core/models.py\"."))
    # The label is composed straight into a table name, so its shape is not cosmetic: `"My.app"`
    # yields `db_table = "My.app_pessoa"`, and `_lookup_class_ref` splits `"<app>.<Class>"` on the
    # dot, so every qualified reference into such an app silently fails to resolve and degrades.
    # Django's own rule is that an app_label is a Python identifier.
    Base.isidentifier(label) || throw(InvalidMigrationError(
      "import: app label \"$(label)\" is not a valid Django app_label. A label is a Python " *
      "identifier — letters, digits and underscores, not starting with a digit — because Django " *
      "composes it into every table name and PormG splits \"<app_label>.<ClassName>\" on the dot."))
    lowercase(label) in labels && throw(InvalidMigrationError(
      "import: app label \"$(label)\" is listed more than once. Django app labels are unique within " *
      "a project, and two apps sharing one would collapse their tables onto the same names."))
    push!(labels, lowercase(label))
    source = String(last(pair))
    # A MISTYPED PATH is the silent-loss shape this arity invents, and it has to die here.
    # `_django_source_text` treats "no newline and not a file" as source text, so one wrong path out
    # of three parses to zero classes, contributes zero models, and turns every relation into that
    # app into a degraded column — three markers about missing models and not one line saying the
    # file does not exist. Source text always contains a newline, so the test has no false positive
    # worth the silence it would buy.
    if !occursin('\n', source) && !isfile(source)
      throw(InvalidMigrationError(
        "import: app \"$(label)\" points at \"$(source)\", which is not a file. A pair's value is " *
        "the path to that app's models.py, or its source text — and source text contains newlines, " *
        "so this is a path that does not exist."))
    end
    # The PATH is kept, not just its contents: it carries the app's package directory name, which is
    # the second key a Python module path may name this app by. Django's `AppConfig.label` is often
    # not the package directory (`server/core/models.py` imported as `from server.core.models import
    # …` while the label is `core`), so keeping both is what stops a legitimate import from reading
    # as third-party. Source text handed over inline has no path, and then the label is all there is.
    push!(staged, _app_scope(label, occursin('\n', source) ? nothing : source,
                             _py_logical_lines(_django_source_text(source))))
  end

  # Classification is deferred until every app is parsed, so each app's bases and enum references
  # resolve against the WHOLE project — its own classes first, then whatever this app's `models.py`
  # actually imports from the others. A shared abstract base in a `core` app is the shape that needs
  # it; see `_django_graph_from_scopes`.
  parsed = _DjangoApp[_DjangoApp(sc.label, _django_graph_from_scopes(staged, i))
                      for (i, sc) in enumerate(staged)]

  # An app that contributes no table is legal (a Django app can declare no models) but it is never
  # what you meant when the other apps reference it, so it is reported per app rather than only in
  # the all-empty case below.
  empty_apps = [app.label for app in parsed
                if !any(c -> _is_emitted(app.graph.info[c.name]), app.graph.classes)]
  for label in empty_apps
    @warn "import: this app declares no importable model" app=label
  end

  if length(empty_apps) == length(parsed)
    @warn("None of the given files contains valid model.py content")
    return
  end

  model_path = render_settings.db_def_folder
  _django_output_ready(joinpath(model_path, file), model_path, force_replace) || return

  _import_django_apps(parsed, render_settings;
                      file = file, model_path = model_path,
                      auth_user_model = auth_user_model,
                      strict_relations = strict_relations,
                      binding_overrides = Dict{String, String}(String(k) => String(v) for (k, v) in binding_overrides),
                      autofields_ignore = autofields_ignore,
                      parameters_ignore = parameters_ignore)
end

# The UniqueConstraints already stashed on a model by `_apply_unique_constraints!`. Applying
# constraints one at a time (so a rejection is per-constraint) means each call must carry the ones
# that already passed — the setter REPLACES the cache entry rather than appending to it.
function _existing_unique_constraints(model)::Vector{Models.UniqueConstraint}
  haskey(model.cache, "unique_constraints") || return Models.UniqueConstraint[]
  return get(model.cache["unique_constraints"], "constraints", Models.UniqueConstraint[])
end

# The composite-index sibling of the above (#347). `_apply_indexes!` replaces its cache entry the
# same way, so applying one index at a time has to carry the ones that already passed.
function _existing_indexes(model)::Vector{Models.Index}
  haskey(model.cache, "composite_indexes") || return Models.Index[]
  return get(model.cache["composite_indexes"], "indexes", Models.Index[])
end

# ── Class classification and inheritance (#341) ─────────────────────────────────────────────────
# Until #341 a class became a table iff its ENTIRE base list was one of two literals
# (`\((models\.Model|AbstractUser)\)`). That is a silent-loss shape, and the worst one in this file:
# `class Pedido(TimeStampedModel):` matched neither literal, so the model was not imported and
# NOTHING said so — the same failure #340 exists to remove, one level up.
#
# Widening it to "any base list" is not safe either. A real models.py is full of QuerySet, Manager,
# ModelForm and serializer subclasses that are emphatically not tables, and importing those is the
# mirror-image defect. So the base list is RESOLVED against the file instead of string-matched, and
# the residual guess — a base this file does not define — is gated on whether the class actually
# declares columns.

# Bases that make a class a table root on their own.
const _MODEL_ROOT_BASES = ("models.Model", "Model", "db.models.Model", "django.db.models.Model")

# Roots that ALSO carry Django's auth columns (see `process_class_fields!`). `AbstractBaseUser` is
# deliberately absent: its field set is a strict subset of `AbstractUser`'s — no `username`,
# `email`, `is_staff`, `date_joined` — so treating the two as one root emits a user table missing
# real columns. It falls through to the unresolved path instead, which imports the model and states
# what is missing rather than inventing it.
const _AUTH_USER_BASES = ("AbstractUser", "models.AbstractUser", "auth_models.AbstractUser")

# Bases that are definitively NOT tables. Skipped in silence — a warning here is pure noise, and
# noise is what buried the one real finding in #340.
#
# Load-bearing, not belt-and-braces: the field gate below cannot replace this list, because a
# non-model class may still declare field-shaped members. `class PlainHelper(object)` with a
# `models.CharField(...)` in its body is exactly that case, and it is already a test.
const _NON_MODEL_BASES = (
  "object",
  "models.TextChoices", "models.IntegerChoices", "models.Choices",
  "TextChoices", "IntegerChoices", "Choices",
  "models.Manager", "models.QuerySet", "Manager", "QuerySet",
  "Enum", "IntEnum", "StrEnum", "ABC", "Exception",
)

"""
    _ClassInfo

What the importer decided about one `class` in the source.

`kind` is one of:

- `:concrete` — becomes a table.
- `:abstract` — `Meta.abstract = True`: a base only. Emits nothing; its fields merge into children.
- `:mti` — Django *multi-table inheritance*, i.e. a base that itself becomes a table. Refused, and
  deliberately so: Django gives the child its own table keyed by a `<parent>_ptr_id` one-to-one to
  the parent, which PormG cannot express. Emitting the child with merged fields would duplicate the
  parent's columns; emitting it without them would lack the primary key Django actually created.
  Both put a schema on disk that does not match the database, so neither is emitted.
- `:not_a_model` — a QuerySet, Manager, Form, enum or plain helper. Skipped silently.

`unresolved` holds bases that name nothing this module can see (`from core.models import
TimeStampedModel` without that app in the run, or a base from a third-party library). The class is
still imported — dropping it would re-create the vanishing-model bug — but it carries a marker
saying whose fields are missing. Importing several apps together (#346) resolves these, provided
this module actually imports the name (#370).

`ancestry_lost` marks the ONE `:not_a_model` that is not a helper: a class whose entire base list is
unresolvable and which declares no column of its own, so nothing distinguishes it from a plain
`class Foo(SomeMixin)`. It is recorded at the point the decision is made rather than recomputed by
the reporter, because rederiving it there means two predicates that have to agree — and the reporter
would have to guess whether `:not_a_model` came from a blacklisted base, a `Meta.model`, or this.
"""
struct _ClassInfo
  kind::Symbol
  bases::Vector{String}
  parents::Vector{String}              # in-file ABSTRACT bases whose fields this class inherits
  unresolved::Vector{String}           # bases nothing in scope defines
  mti_parent::Union{String, Nothing}
  meta::Dict{String, String}
  is_auth_user::Bool
  proxy::Bool
  ancestry_lost::Bool
end

# A class this importer emits a `Models.Model(...)` for. A proxy is `:concrete` in every other
# respect but shares its parent's table, so emitting it would declare that table twice.
_is_emitted(ci::_ClassInfo)::Bool = ci.kind === :concrete && !ci.proxy

"""
    _class_bases(cls) -> Vector{String}

The base list of a class header, split on its top-level commas. A token carrying a top-level `=`
(`class Foo(Base, metaclass=abc.ABCMeta)`) is a class keyword, not a base, and is dropped.
"""
function _class_bases(cls::PyClass)::Vector{String}
  out = String[]
  isempty(strip(cls.bases)) && return out
  for t in split_field_options(cls.bases)
    tt = strip(t)
    isempty(tt) && continue
    _split_top_level_assign(tt) === nothing || continue
    push!(out, String(tt))
  end
  return out
end

# Namespaces a *database* field can be called through. `""` is the bare form
# (`from django.db.models import CharField` → `titulo = CharField(...)`), which is ordinary Django
# and also how third-party fields arrive (`ArrayField`, django-mptt's `TreeForeignKey`).
const _MODEL_FIELD_NAMESPACES = ("", "models", "db.models", "django.db.models")

# The dotted prefix of a call's target: `forms.CharField(` → "forms", `CharField(` → "", and
# `a.b.Thing(` → "a.b". `nothing` when `rhs` is not a call at all.
const _CALL_NAMESPACE_RE = r"^((?:[A-Za-z_]\w*\s*\.\s*)*)([A-Za-z_]\w*)\s*\("

function _field_call_namespace(rhs::AbstractString)::Union{String, Nothing}
  m = match(_CALL_NAMESPACE_RE, rhs)
  m === nothing && return nothing
  return String(strip(replace(rstrip(strip(m.captures[1]), '.'), r"\s+" => "")))
end

# True when the class's OWN body declares at least one DATABASE column. This is the gate that lets an
# unrecognised base list be treated as a model without a blacklist that has to be exhaustive.
#
# `models.X(...)` is not the only spelling — `from django.db.models import CharField` then
# `titulo = CharField(...)` is ordinary Django, and #340 already added `_looks_like_a_field_call` to
# recognise it. Matching only the dotted form made the gate and that reporter disagree, and the gate
# won: such a model was dropped in silence.
#
# But accepting *any* field-shaped call is the mirror defect, and a worse one — it puts junk in the
# schema instead of leaving it out. A plain `forms.Form` and a DRF `serializers.Serializer` have no
# `Meta.model` to exclude them and their members are `forms.CharField(...)` /
# `serializers.CharField(...)`, which `_looks_like_a_field_call` accepts because `_CALL_TARGET_RE`
# discards the namespace and tests only the suffix. Both imported as `id`-only tables that reach
# `makemigrations` as real `CREATE TABLE`s.
#
# So the namespace is the discriminator, and it is the one piece of information already in the
# source: `models.CharField` and `forms.CharField` differ by nothing else.
function _declares_fields(cls::PyClass)::Bool
  for s in cls.body
    p = _match_field_statement(s.text)
    p === nothing && continue
    p.type === nothing || return true           # `models.X(...)`, matched by _FIELD_CALL_RE
    _looks_like_a_field_call(p.args) || continue
    ns = _field_call_namespace(p.args)
    if ns !== nothing && ns in _MODEL_FIELD_NAMESPACES
      return true
    end
  end
  return false
end

# `abstract = True` / `proxy = True`, read off the raw right-hand side.
_meta_is_true(raw::AbstractString)::Bool = parse_value(raw) === true

"""
    _AppScope

One app's contribution to an import run: its `label`, the `keys` a Python module path may name it
by, its own `classes` in source order, the `own` name→class table (first-wins), and its
[`_PyImports`](@ref).

`keys` is EMPTY for the single-app arity. That is not a detail — it is what makes the one-app path
provably unchanged by #370: with no key, no module path can ever match an app, so import and star
resolution cannot fire and `_resolve_base` degenerates to a lookup in `own`, exactly the
`haskey(index, b)` the flat index used to perform.
"""
struct _AppScope
  label::String
  keys::Vector{String}
  pkg_path::Vector{String}             # lowercased package chain of this app's models.py; see below
  classes::Vector{PyClass}
  own::Dict{String, PyClass}
  imports::_PyImports
end

# The package chain leading to this app's models module: `server/core/models.py` and
# `server/core/models/__init__.py` both give `["server", "core"]`. Empty when the app was handed over
# as source text, which has no location to compare against.
#
# Absolute leading components (a temp dir, a checkout root) are harmless because the only thing that
# ever reads this is a SUFFIX comparison — how a Python import spells the path depends on where
# `sys.path` is rooted, and only the tail is knowable.
function _app_pkg_path(path::Union{Nothing, AbstractString})::Vector{String}
  path === nothing && return String[]
  d = dirname(String(path))
  lowercase(basename(d)) == "models" && (d = dirname(d))
  comps = [lowercase(c) for c in split(replace(d, '\\' => '/'), '/') if !isempty(c)]
  return comps
end

# Django's `AppConfig.label` is frequently not the package directory name, so the directory is
# carried as a SECOND key rather than as a replacement: whichever of the two an import spells, it
# resolves.
_app_package_key(path::Union{Nothing, AbstractString})::Union{Nothing, String} =
  (p = _app_pkg_path(path); isempty(p) ? nothing : p[end])

function _app_scope(label::AbstractString, path::Union{Nothing, AbstractString},
                    stmts::Vector{PyStmt})::_AppScope
  classes = _py_classes(stmts)
  own = Dict{String, PyClass}()
  for c in classes
    haskey(own, c.name) || (own[c.name] = c)   # first-wins; a module-level redefinition is pathological
  end
  keys = String[]
  pkg = String[]
  if !isempty(label)
    push!(keys, lowercase(label))
    pkg = _app_pkg_path(path)
    d = isempty(pkg) ? nothing : pkg[end]
    (d === nothing || d in keys) || push!(keys, d)
  end
  return _AppScope(String(label), keys, pkg, classes, own, _py_imports(stmts))
end

"""
    _app_for_module(scopes, mod) -> Union{Int, Nothing}

The app in `scopes` that a Python module path names, or `nothing`.

A component `c` names an app when `c` is one of that app's keys (its label or its package directory)
**and** the app's models module follows — `core.models`, `core.models.base` — or nothing follows,
which is the app package re-exporting through its `__init__.py` (`from core import …`). Components
are scanned RIGHT TO LEFT, because a nested app package is ordinary and a left-to-right first match
would stop at `apps`/`server` and resolve nothing.

**Anything in front of the key must be where the app actually lives.** That is the load-bearing
half, and matching the key plus a `models` tail alone is not enough: `from wagtail.core.models
import Page` — the canonical Wagtail import — has a key `core` followed by `models`, so a project
with a `core` app read a third-party base as its own and refused the child as multi-table
inheritance. #370 verbatim, one module name over. So `comps[1:i]` must be a SUFFIX of the app's
`pkg_path`; `apps.core.models` resolves for an app at `apps/core/`, and `wagtail.core.models` for
the same app does not. A key at position 1 needs no prefix to agree with, which is what keeps the
plain `core.models` spelling working — and what makes an app handed over as SOURCE TEXT (no path,
so no `pkg_path`) reachable only by that plain spelling.

`from core.forms import Pedido` is refused by the same rule: a sibling module is not the models
module, and binding a form to a model would be the same defect one file over.

The prefix check is deliberately NOT total: position 1 has nothing in front of it, so a *top-level*
distribution whose package name equals an app key (`from core.models import X` where `core` is a
third-party package) still resolves. Closing that would take the plain `<label>.models` spelling
with it, and that is the spelling an app handed over as source text can only be reached by.

`pkg_path` is read from the path the CALLER passed, not from an importable root, so how deeply the
path is spelled decides which qualified spellings match: an app passed as `"core/models.py"` cannot
match `apps.core.models` even when Python roots it there. It degrades to an unresolved base with a
marker, never to a wrong match.

**A SINGLE leading dot names this app's own package and can never name another app.** `from .base
import X` is `base.py` next to this `models.py`, and `from .core.models import X` is an internal
`core/` subpackage — both leave components that are perfectly ordinary app labels once the dot is
stripped, and reading them as another app is #370 again. **Two or more dots ascend** to a parent
package, which is exactly how a project laid out as `apps/{core,shop}/` writes a genuine cross-app
import (`from ..core.models import TimeStampedModel`), so those do resolve.
"""
function _app_for_module(scopes::Vector{_AppScope}, mod::AbstractString)::Union{Int, Nothing}
  dots = something(findfirst(!isequal('.'), mod), lastindex(mod) + 1) - 1
  dots == 1 && return nothing                          # this app's own package — never another app
  comps = [lowercase(c) for c in split(mod, '.') if !isempty(c)]
  isempty(comps) && return nothing
  for i in length(comps):-1:1
    # Either the app's models module follows the key, or nothing does (the package re-export).
    (get(comps, i + 1, "") == "models" || i == length(comps)) || continue
    key = comps[i]
    for (j, sc) in enumerate(scopes)
      key in sc.keys || continue
      # Position 1 has nothing in front of it to disagree with. Anything deeper must match where the
      # app's models.py actually sits, or a vendor package sharing the app's name resolves into it.
      (i == 1 || (length(sc.pkg_path) >= i && sc.pkg_path[end - i + 1:end] == comps[1:i])) || continue
      return j
    end
  end
  return nothing
end

"""
    _resolve_base(scopes, from_idx, token) -> Union{Tuple{Int, PyClass}, Nothing}

The class a base token names, as seen from app `from_idx`, with the app that owns it.

The app's OWN classes win — Django's rule for an unqualified reference, and the precedence #346
documents. Everything else has to be imported: a name this `models.py` never bound is not in scope
in Python, so resolving it against another app would invent an inheritance edge the project does not
have (#370).
"""
_resolve_base(scopes::Vector{_AppScope}, from_idx::Int, token::AbstractString) =
  haskey(scopes[from_idx].own, token) ? (from_idx, scopes[from_idx].own[token]) :
    _resolve_imported(scopes, from_idx, String(token), Set{Tuple{Int, String}}())

# `seen` is keyed by (app, NAME), not by app. The token changes across a re-export hop — an app
# reached for `Foo` may still have to be asked about `Bar` — so an app-keyed set makes a second,
# valid branch of the star-import loop below return `nothing` purely because an earlier branch had
# already visited that app for a different name. That made the result depend on the ORDER of two
# `from … import *` lines.
function _resolve_imported(scopes::Vector{_AppScope}, idx::Int, token::String,
                           seen::Set{Tuple{Int, String}})::Union{Tuple{Int, PyClass}, Nothing}
  (idx, token) in seen && return nothing
  push!(seen, (idx, token))
  imp = scopes[idx].imports
  entry = get(imp.names, token, nothing)
  if entry !== nothing
    (mod, origin) = entry
    a = _app_for_module(scopes, mod)
    # The name is BOUND, and bound to something outside the app set — a third-party base. Stopping
    # here rather than falling through to the star imports is the #370 fix itself.
    a === nothing && return nothing
    haskey(scopes[a].own, origin) && return (a, scopes[a].own[origin])
    # A re-export façade: `reports` imports from `access`, which imported it from `core`. Common
    # enough in projects with a "base app" that not following it would be a fresh silent loss.
    return _resolve_imported(scopes, a, origin, seen)
  end
  for mod in imp.stars
    a = _app_for_module(scopes, mod)
    a === nothing && continue
    haskey(scopes[a].own, token) && return (a, scopes[a].own[token])
    r = _resolve_imported(scopes, a, token, seen)
    r === nothing || return r
  end
  return nothing
end

"""
    _ClassifyState

The working tables of one classification run, all keyed by `(app index, class name)`.

Keying by app is not bookkeeping. A bare class name is ambiguous the moment two apps declare one —
which `_build_class_index`'s whole collision machinery exists because they DO — and both tables here
are consulted across app boundaries as the walk follows a base into the app that defines it.
`visiting` in particular reported a false inheritance cycle: `core.Bar(Foo)` reached from `L.Foo`
found `"Foo"` already in a bare-name set, refused `core.Bar`, poisoned `L.Foo`, and dropped the
model in silence.

`resolved` records the edge each `(app, token)` pair took, so the projection that builds the public
graph can follow exactly the chain classification followed.
"""
struct _ClassifyState
  scopes::Vector{_AppScope}
  info::Dict{Tuple{Int, String}, _ClassInfo}
  visiting::Set{Tuple{Int, String}}
  resolved::Dict{Tuple{Int, String}, Tuple{Int, PyClass}}
end

_ClassifyState(scopes::Vector{_AppScope}) =
  _ClassifyState(scopes, Dict{Tuple{Int, String}, _ClassInfo}(), Set{Tuple{Int, String}}(),
                 Dict{Tuple{Int, String}, Tuple{Int, PyClass}}())

function _classify_class!(st::_ClassifyState, app::Int, cls::PyClass)::_ClassInfo
  key = (app, cls.name)
  haskey(st.info, key) && return st.info[key]

  meta = _parse_meta_options(cls.meta)
  bases = _class_bases(cls)
  abstract = _meta_is_true(get(meta, "abstract", ""))
  proxy = _meta_is_true(get(meta, "proxy", ""))
  is_auth = any(b -> b in _AUTH_USER_BASES, bases)

  # An inheritance CYCLE is malformed Python. Refuse the class rather than recurse forever; not
  # memoized, because the in-progress outer call owns the entry for this name.
  if key in st.visiting
    return _ClassInfo(:not_a_model, bases, String[], String[], nothing, meta, is_auth, proxy, false)
  end

  is_root = is_auth || any(b -> b in _MODEL_ROOT_BASES, bases)
  # `Meta.model = X` is the definitive signature of a class that DESCRIBES a model rather than being
  # one — ModelForm, ModelSerializer, FilterSet. Django's own `ModelBase` rejects the attribute
  # ("class Meta got invalid attribute(s): model"), so a real model can never carry it. This is an
  # absolute exclusion, unlike the base-list blacklist below.
  describes_a_model = haskey(meta, "model")
  # Only consulted once nothing better is known — see the `kind` selection, where a model root, an
  # abstract parent and a concrete parent all outrank it. Filtering out bases this file defines
  # would be redundant here for exactly that reason; the in-file lookup that matters happens in the
  # resolution loop below.
  non_model = any(b -> b in _NON_MODEL_BASES, bases)

  parents = String[]
  unresolved = String[]
  mti_parent::Union{String, Nothing} = nothing
  poisoned = false

  # Bases are resolved even when one of them is blacklisted, because a blacklisted base no longer
  # decides the outcome on its own — see the `kind` selection below.
  #
  # A RESOLVED base is tested BEFORE `_NON_MODEL_BASES`, and that ordering is the whole fix for a
  # real silent loss: `Manager`, `Choices` and `Enum` are perfectly good model names — a Manager in
  # an HR schema is a person — and dismissing such a base by NAME made the class invisible as an
  # ancestor. Its children then resolved no parent, fell through to `non_model`, and were dropped
  # without a word, taking the base's columns with them. A definition always outranks a name on a
  # list — and now that resolution is import-aware, it is only the definition this module can
  # actually SEE, so `class Foo(Manager)` in an app that wrote `from django.db.models import
  # Manager` correctly falls to the blacklist instead of borrowing another app's `Manager` class.
  push!(st.visiting, key)
  try
    for b in bases
      (b in _MODEL_ROOT_BASES || b in _AUTH_USER_BASES) && continue
      r = _resolve_base(st.scopes, app, b)
      if r !== nothing
        (bapp, bcls) = r
        st.resolved[(app, b)] = r
        # Recursion carries the RESOLVED app, never the importing one. A base's own bases are names
        # in ITS module, so classifying `core.Auditavel` in the importing app's namespace loses
        # `TimeStampedModel`, makes `Auditavel` field-less and therefore `:not_a_model`, poisons the
        # child — and the child is then dropped with no marker at all, which is strictly worse than
        # the defect this change exists to remove.
        pk = _classify_class!(st, bapp, bcls).kind
        if pk === :abstract
          push!(parents, b)
        elseif pk === :concrete || pk === :mti
          # Inheriting anything that becomes a table IS multi-table inheritance. A `:mti` parent
          # is already refused above us, and refusing here too keeps the chain from emitting a
          # child whose parent never existed.
          mti_parent === nothing && (mti_parent = b)
        else  # :not_a_model — a Manager/QuerySet/helper base makes this one a helper too
          poisoned = true
        end
      elseif b in _NON_MODEL_BASES
        # A known non-model NAME that nothing in scope defines. Already reflected in `non_model`;
        # it is not an unresolved ancestor, so it must not be marked as one.
        continue
      else
        push!(unresolved, b)
      end
    end
  finally
    delete!(st.visiting, key)
  end

  kind = if describes_a_model || isempty(bases)
    :not_a_model
  elseif proxy
    # A proxy subclasses a CONCRETE model, which is otherwise the multi-table-inheritance shape —
    # but `proxy = True` is Django saying "no new table", not "a second table keyed to the parent".
    # Classified as a model so the caller reports it as a proxy; `_is_emitted` still refuses it.
    :concrete
  elseif mti_parent !== nothing
    :mti
  elseif is_root || !isempty(parents)
    # A recognised model root WINS over EVERY non-model base — both the blacklist (`non_model`) and
    # an in-file helper (`poisoned`). `class Servidor(models.Model, ExportMixin)` is ordinary
    # Django, and so is `class Servidor(models.Model, object)`, which is the only legal ordering
    # since `object` must come last. Testing either flag first dropped the whole model in SILENCE —
    # the shape this issue exists to close.
    #
    # Such a base contributes no columns either way: Django collects fields only from bases that
    # carry `_meta`, so a plain mixin's attributes are inherited as Python, never as schema.
    abstract ? :abstract : :concrete
  elseif non_model || poisoned
    # No model root and no abstract parent, and a base that is definitively not a model — a
    # `class PlainHelper(object)` or `class Foo(SomeQuerySet)`. A helper deriving from a helper.
    :not_a_model
  elseif !isempty(unresolved) && _declares_fields(cls)
    # Nothing in the base list is recognisable, but the body declares real columns — so this is a
    # model whose ancestry we cannot see, not a helper. Import it; the caller marks what is missing.
    abstract ? :abstract : :concrete
  else
    :not_a_model
  end

  # Reached the final `else` with bases nothing could resolve: every column this class has lives in a
  # base the importer cannot see, so there is no evidence either way and it is skipped. Recorded so
  # the reporter can say so — skipping it in silence is how a real model disappears without a trace.
  #
  # Restricted to BARE base names, using the same discriminator `_declares_fields` uses one screen
  # down: a namespace is the one piece of information already in the source. `forms.Form` and
  # `serializers.Serializer` are dotted, so they name a module this file never had and a dotted token
  # could not have resolved anyway — those are helpers, definitively, and marking them would be pure
  # noise on every `models.py` that also holds a ModelForm. A BARE `CustomUser` is the ambiguous one:
  # it is exactly what an `import` would have bound, which is what makes it worth a line.
  #
  # Deliberately NOT narrowed further by "the name was imported from a module naming no app". That
  # test cannot tell a third-party library from an app of this project the caller simply did not
  # pass — and those are the same string. Worse, the single-app arity has no app keys at all, so the
  # test is true for EVERY explicitly-imported base there and the marker never fired for the case it
  # exists for. The module name goes into the message instead: naming `model_utils.managers` lets a
  # reader dismiss a library in one glance, and naming `core.models` tells them which pair is
  # missing. A comment too many is recoverable; a model that vanished silently is not.
  ancestry_lost = kind === :not_a_model && !isempty(unresolved) &&
                  !describes_a_model && !non_model && !poisoned &&
                  all(b -> !occursin('.', b), unresolved)

  ci = _ClassInfo(kind, bases, parents, unresolved, mti_parent, meta, is_auth, proxy, ancestry_lost)
  st.info[key] = ci
  return ci
end

"""
    _django_class_graph(src) -> (classes, index, info)

Every module-level class in `src`, indexed by name and classified. `classes` keeps source order so
generated output is stable; `info[name]` is the [`_ClassInfo`](@ref).

Deliberately silent: classification emits no warnings, so `parse_class` can be called from a test
without side effects. The importer reads `info` and does the reporting.
"""
function _django_class_graph(model_py_string::AbstractString)
  stmts = _py_logical_lines(model_py_string)
  # No label and therefore no module keys: `_app_for_module` can never match, so import resolution
  # is inert and this path behaves exactly as it did when the index was one flat name→class table.
  return _django_graph_from_scopes([_app_scope("", nothing, stmts)], 1)
end

"""
    _django_graph_from_scopes(scopes, self) -> NamedTuple

Classify `scopes[self]`'s classes, resolving their bases and enum references across `scopes`.

`scopes` holds every app of the import run (#346); `self` says which one this graph is for. That is
what lets

```python
# core/models.py                       # imports/models.py
class TimeStampedModel(models.Model):  from core.models import TimeStampedModel
    class Meta: abstract = True        class ImportBatch(TimeStampedModel):
                                           note = models.CharField(max_length=40)
```

merge — a shared abstract base in a `core` app is one of the commonest shapes in a real Django
project, and importing the apps separately is exactly what `_inherited_unresolved`'s marker has been
telling people to stop doing since #341 ("import the app that defines them together with this one").

**Resolution follows the `import` statements, not the name (#370).** An app's own classes win, as
Django resolves an unqualified reference; anything else must have been imported by that module.
Matching purely by name meant a base one app inherited from a third-party library resolved against
an unrelated app's class of the same name — and when that class was concrete, the child was refused
as multi-table inheritance and its table vanished from the generated file. Adding an app to the
import removed a table from another app, which Python's per-module namespaces make impossible.

Cross-app inheritance still keeps Django's semantics rather than gaining new ones: an abstract base
merges its fields, and a CONCRETE base in another app — genuinely imported — is still multi-table
inheritance and still refused.

`index` and `info` describe **this app's own classes only**, name-keyed, which is what every caller
reading them by class name expects. The ancestor walkers cannot use a bare name (two apps may
declare one), so they read `byapp` and `resolved` instead: `byapp[(app, name)]` is the classified
info of any class the walk reached, and `resolved[(app, token)]` is the edge a base token took.
"""
function _django_graph_from_scopes(scopes::Vector{_AppScope}, self::Int)
  st = _ClassifyState(scopes)
  classes = scopes[self].classes
  for c in classes
    _classify_class!(st, self, c)
  end

  # Own classes, source order, first-wins — the invariant `_build_class_index` relies on when it
  # indexes `graph.index[e.class]` without a guard.
  index = Dict{String, PyClass}()
  info = Dict{String, _ClassInfo}()
  for c in classes
    haskey(index, c.name) && continue
    index[c.name] = c
    info[c.name] = st.info[(self, c.name)]
  end

  # Enum scope, keyed by `(app, scope)` — a class name, or `""` for module level.
  #
  # The app half is not bookkeeping. Keyed by bare scope name, two apps that each declare a `Base`
  # with a nested `Situacao` collapse into one entry, and `core.Base`'s own field silently takes
  # `shop.Base`'s members — a wrong enumeration in the schema with no marker anywhere. The base
  # resolved perfectly; only the scope table could not tell the two classes apart. `_enum_scopes`
  # hands back the `(app, name)` pairs it already resolved, so the lookup asks the right app.
  #
  # The MODULE scope of THIS app is the one place anything crosses: a top-level
  # `class Status(models.TextChoices)` referenced as `choices=Status.choices` is a Python name
  # lookup, so it is gated exactly like a base (#370). Every other app's module scope stays its own
  # and is reached only as an ancestor's, below.
  per_app = [_collect_enums(sc.classes) for sc in scopes]
  enums = Dict{Tuple{Int, String}, Dict{String, _PyEnum}}()
  for (i, t) in enumerate(per_app), (scope, members) in t
    enums[(i, scope)] = members
  end
  mod_scope = Dict{String, _PyEnum}()
  own_mod = get(per_app[self], "", nothing)
  own_mod === nothing || merge!(mod_scope, own_mod)      # own declarations always win
  for local_name in keys(scopes[self].imports.names)
    haskey(mod_scope, local_name) && continue
    e = _resolve_enum(scopes, per_app, self, local_name, Set{Tuple{Int, String}}())
    e === nothing || (mod_scope[local_name] = e)
  end
  # A star import cannot be enumerated, so it contributes the other app's own module-level names.
  # Not its re-exports: those have no name here to ask about, and inventing the closure of every
  # star-imported app's imports would bind names the source never mentions.
  for mod in scopes[self].imports.stars
    a = _app_for_module(scopes, mod)
    (a === nothing || a == self) && continue
    src = get(per_app[a], "", nothing)
    src === nothing && continue
    for (n, e) in src
      haskey(mod_scope, n) || (mod_scope[n] = e)
    end
  end
  enums[(self, "")] = mod_scope

  return (classes = classes, index = index, info = info, enums = enums,
          scopes = scopes, self = self, byapp = st.info, resolved = st.resolved)
end

# The base resolver's walk, for a module-level enumeration instead of a class: own declarations, then
# named imports, following a re-export façade exactly as `_resolve_imported` does.
#
# Kept as a second function rather than one generic because the tables differ — `own` versus the `""`
# scope of `_collect_enums` — but the RULES must not drift. They did in the first cut of #370: a base
# behind `shop → access → core` resolved and the enum behind the same façade did not, and the marker
# then told the reader to import a module they had already imported.
function _resolve_enum(scopes::Vector{_AppScope}, per_app, idx::Int, token::String,
                       seen::Set{Tuple{Int, String}})
  (idx, token) in seen && return nothing
  push!(seen, (idx, token))
  imp = scopes[idx].imports
  entry = get(imp.names, token, nothing)
  if entry !== nothing
    (mod, origin) = entry
    a = _app_for_module(scopes, mod)
    a === nothing && return nothing          # bound to something outside the app set
    src = get(per_app[a], "", nothing)
    src !== nothing && haskey(src, origin) && return src[origin]
    return _resolve_enum(scopes, per_app, a, origin, seen)
  end
  for mod in imp.stars
    a = _app_for_module(scopes, mod)
    a === nothing && continue
    src = get(per_app[a], "", nothing)
    src !== nothing && haskey(src, token) && return src[token]
    r = _resolve_enum(scopes, per_app, a, token, seen)
    r === nothing || return r
  end
  return nothing
end

# ── Django `TextChoices` / `IntegerChoices` (#342) ───────────────────────────────────────────────
# `choices=Status.choices` used to parse to the literal STRING "Status.choices", and
# `default=Status.DRAFT` to "Status.DRAFT". CharField then validated the default against the choices
# and threw FieldValidationError, which propagated out of `process_class_fields!` and killed the
# ENTIRE import — every other model in the file lost, output a stack trace.
#
# The enum classes were already being parsed: #340 put a nested `class Status(models.TextChoices)`
# into `PyClass.nested`, and `_lift_meta!` only ever removes `Meta`. This is the seam that consumes
# them.

# Bases that make a class a Django enumeration. Kept separate from `_NON_MODEL_BASES` — that list
# says "not a table", this one says "a symbol table entry" — but every entry here is also on it, so
# an enum is still never emitted as a model.
const _CHOICES_BASES = ("models.TextChoices", "TextChoices",
                        "models.IntegerChoices", "IntegerChoices",
                        "models.Choices", "Choices")

"""
    _PyEnum

One Django enumeration recovered from source: its `name` and its `members` as
`(MEMBER, value, label)`.

`value` is kept as the raw source text rather than parsed here, so the consumer can both test it
(`_is_py_literal`) and convert it (`parse_value`) — an `IntegerChoices` member stays `1` until
something asks for it. `label` is derived Django-style when omitted.

Text and Integer enums are deliberately NOT distinguished: `parse_choices` stringifies either, and
`CharField` coerces an `Int` default, so both land identically. A field recording which kind it was
would be written and never read.
"""
struct _PyEnum
  name::String
  members::Vector{Tuple{String, String, String}}
end

# Django derives an omitted label from the member name: `IN_PROGRESS` -> "In Progress".
_django_enum_label(member::AbstractString)::String = titlecase(replace(String(member), "_" => " "))

# True when the text is a plain Python literal the importer can carry into PormG. Anything else —
# `auto()`, `uuid.uuid4()`, a concatenation — is an expression whose VALUE this importer cannot know.
# Keeping such a value verbatim is worse than dropping it: `CARRO = auto()` gives every member the
# string "auto()", which is duplicate values that then PASS validation because the default is
# literally in the set.
function _is_py_literal(v::AbstractString)::Bool
  t = strip(v)
  isempty(t) && return false
  t in ("None", "True", "False") && return true
  _py_number(t) === nothing || return true
  # A quoted string, with no unescaped quote of the same kind inside it.
  return occursin(r"^\"(?:[^\"\\]|\\.)*\"$", t) || occursin(r"^'(?:[^'\\]|\\.)*'$", t)
end

"""
    _py_number(t) -> Union{Int, Float64, Nothing}

The NUMBER a Python numeric literal denotes, or `nothing` if `t` is not one.

Denotes, not spells. Django stores what the literal means: `ALTO = 1_000` is the integer 1000 and
`MEIO = 0x1F` is 31, so carrying the source text into `choices` and `default` declares an
enumeration no row can ever match. Both halves are wrong identically, which is precisely why
`CharField`'s default-in-choices validation passes and nothing is reported — a silent wrong value,
the one outcome this importer exists to prevent.

Handles Python's `_` digit separators, hex/octal/binary, exponents and a leading sign.
"""
function _py_number(t::AbstractString)::Union{Int, Float64, Nothing}
  s = replace(String(strip(t)), "_" => "")
  isempty(s) && return nothing
  m = match(r"^([+-]?)0([xXoObB])([0-9a-fA-F]+)$", s)
  if m !== nothing
    c = lowercase(m.captures[2])
    v = tryparse(Int, m.captures[3]; base = c == "x" ? 16 : c == "o" ? 8 : 2)
    v === nothing && return nothing
    return m.captures[1] == "-" ? -v : v
  end
  occursin(r"^[+-]?\d+$", s) && return tryparse(Int, s)
  occursin(r"^[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?$", s) && return tryparse(Float64, s)
  return nothing
end

# The text PormG should STORE for an enum member's value: a number in canonical form, or the
# quote-stripped literal.
function _py_scalar_text(v::AbstractString)::String
  n = _py_number(v)
  return n === nothing ? _strip_py_quotes(v) : string(n)
end

# `_("Azul")` / `gettext_lazy("Azul")` — the standard i18n spelling for a label. The wrapper carries
# no schema meaning, so the string inside it is the label; leaving it wrapped put `_("Azul")` into
# the generated file as the display text.
const _GETTEXT_CALL_RE = r"^(?:_|gettext|gettext_lazy|ugettext|ugettext_lazy)\s*\(\s*(.*?)\s*,?\s*\)$"

function _unwrap_gettext(s::AbstractString)::String
  m = match(_GETTEXT_CALL_RE, strip(s))
  return m === nothing ? String(strip(s)) : String(strip(m.captures[1]))
end

_is_enum_class(cls::PyClass)::Bool = any(b -> b in _CHOICES_BASES, _class_bases(cls))

"""
    _parse_enum(cls) -> _PyEnum

Read an enum class body into members.

Accepts all three Django spellings: `MEMBER = "VALUE", "Label"`, `MEMBER = "VALUE"` (label derived),
and the integer form `MEMBER = 1, "Label"`. A `__dunder__` name is skipped — Django's `__empty__`
declares the blank choice, which is not a member. Method bodies never reach here: `_py_classes`
already excludes `def` frames.
"""
function _parse_enum(cls::PyClass)::_PyEnum
  members = Tuple{String, String, String}[]
  for s in cls.body
    parts = _split_top_level_assign(s.text)
    parts === nothing && continue
    name, rhs = parts
    Base.isidentifier(name) || continue
    startswith(name, "__") && continue
    toks = split_field_options(rhs)
    isempty(toks) && continue
    value = String(strip(toks[1]))
    isempty(value) && continue
    label = length(toks) >= 2 ? String(strip(toks[2])) : ""
    # A label that is not a plain literal after unwrapping — `_("a") + _("b")`, an f-string, a
    # conditional — cannot be read, so fall back to the name Django itself would derive rather than
    # putting a fragment of Python into the generated file as display text. Only the LABEL degrades
    # this way; a non-literal VALUE is reported and drops the option, because a value is schema.
    unwrapped = isempty(label) ? "" : _unwrap_gettext(label)
    label_text = if isempty(label) || !_is_py_literal(unwrapped)
      _django_enum_label(name)
    else
      _strip_py_quotes(unwrapped)
    end
    push!(members, (String(name), value, label_text))
  end
  return _PyEnum(String(cls.name), members)
end

"""
    _collect_enums(classes) -> Dict{String, Dict{String, _PyEnum}}

Every enum in the file, keyed by OWNING class and then by enum name. `""` is the module-level scope.

Scoped rather than flat on purpose: two models may each nest a `Status` with different members, and
a flat table would silently give both the last one parsed.
"""
function _collect_enums(classes::Vector{PyClass})::Dict{String, Dict{String, _PyEnum}}
  out = Dict{String, Dict{String, _PyEnum}}()
  module_scope = Dict{String, _PyEnum}()
  for c in classes
    if _is_enum_class(c)
      module_scope[c.name] = _parse_enum(c)
      continue
    end
    nested = Dict{String, _PyEnum}()
    # Recursive, not one level: `class Outer: class Inner: class Status(TextChoices)` is legal, and
    # scanning only the roots' direct children reported such an enum as "not defined in this file"
    # while it sat two lines away.
    _collect_nested_enums!(nested, c)
    isempty(nested) || (out[c.name] = nested)
  end
  isempty(module_scope) || (out[""] = module_scope)
  return out
end


# Recursive, and each enum is registered under EXACTLY the name Python would bind it to: its path
# relative to the model. A direct child is `Situacao`; one nested a level deeper is
# `Grupo.Situacao`, and only that — because `Situacao` alone is not in the model body's namespace.
#
# Registering the bare name as well looked harmless and was not: a module-level `Situacao` is what
# Python actually resolves in the model body, and an invented bare key for a deep enum SHADOWED it,
# because `_lookup_enum` searches the class scope before the module scope. The field then imported
# the wrong enumeration in complete silence, with a marker claiming the real member did not exist.
function _collect_nested_enums!(into::Dict{String, _PyEnum}, cls::PyClass, prefix::AbstractString = "")
  for n in cls.nested
    if _is_enum_class(n)
      into[string(prefix, n.name)] = _parse_enum(n)
    else
      _collect_nested_enums!(into, n, string(prefix, n.name, "."))
    end
  end
  return into
end

"""
    _enum_scopes(graph, cls) -> Vector{Tuple{Int, String}}

The scopes an enum reference inside `cls` may name, as `(app, scope)` in precedence order: the class
itself, then its ABSTRACT BASES (nearest first), then module level — this app's first, then that of
each app an ancestor came from.

The abstract-base step is not optional. `_inherited_statements` merges a base's field statements
into the child and processes them under the CHILD's name, so a base declaring both
`class Status(TextChoices)` and a field using it hands the child a reference that is nowhere in the
child's own scope — which this importer then reported as "not defined in this file" while it sat
three lines above. An abstract base with an enumerated status column is mainstream Django.

The ancestor's module scope is in the list for the same reason one step further out: a base in
`core` may reference a MODULE-level `Status` that `core` declares, and once that statement has been
merged into a child in another app, nothing in the child's own scopes can see it.

Every entry carries the app it belongs to. Two apps may each declare a `Base` with a nested
`Situacao`, and a scope list of bare names cannot say which one a merged statement meant.

!!! warning "Known imprecision — the list is per CLASS, not per statement"
    `_inherited_statements` merges an ancestor's statements into the child and they are all
    processed under one scope list, so the ancestor-module tail is reachable from the child's OWN
    statements too, and this app's module scope outranks the ancestor's even for a statement that
    came out of the ancestor's body — where Python would resolve in the ancestor's module.

    Both are narrower than what preceded them: the enum table used to be one flat, app-blind
    dictionary, so every app's module scope was reachable from everywhere. Closing them properly
    means tagging each merged statement with the app it came from and resolving per statement, which
    is a change to the field pipeline rather than to this list.
"""
function _enum_scopes(graph, cls::PyClass)::Vector{Tuple{Int, String}}
  out = Tuple{Int, String}[(graph.self, cls.name)]
  ancestor_apps = Int[]
  seen = Set{Tuple{Int, String}}()
  function walk(a::Int, c::PyClass)
    key = (a, c.name)
    key in seen && return
    push!(seen, key)
    ci = get(graph.byapp, key, nothing)
    ci === nothing && return
    for b in ci.parents
      r = get(graph.resolved, (a, b), nothing)
      r === nothing && continue
      (pa, pc) = r
      (pa, pc.name) in seen && continue
      # The scope key is the ancestor's OWN name, because that is how `_collect_enums` keys a class
      # scope — not the token the child referred to it by, which an `as` alias makes a different
      # string entirely.
      push!(out, (pa, pc.name))
      pa == graph.self || pa in ancestor_apps || push!(ancestor_apps, pa)
      walk(pa, pc)
    end
    return
  end
  walk(graph.self, cls)
  push!(out, (graph.self, ""))                 # this app's module scope outranks any borrowed one
  for a in ancestor_apps
    push!(out, (a, ""))
  end
  return out
end

"""
    _lookup_enum(enums, scopes, ref) -> Union{_PyEnum, Nothing}

Resolve an enum NAME against an ordered list of `(app, scope)` keys. First match wins, so a nested
enum shadows a module-level one of the same name — Python's own rule. A qualified `Owner.Status` is
accepted last, since Django permits addressing a nested enum through its owner.

The qualified form is tried against the apps already in `scopes` and no others: `Owner` is a name in
one of those modules, so widening the search to every app would resolve it in a module the source
cannot see — the flat-table defect one level down.
"""
function _lookup_enum(enums, scopes::Vector{Tuple{Int, String}},
                      ref::AbstractString)::Union{_PyEnum, Nothing}
  for s in scopes
    scope = get(enums, s, nothing)
    scope === nothing && continue
    haskey(scope, ref) && return scope[ref]
  end
  idx = findlast('.', ref)
  if idx !== nothing
    owner = String(ref[firstindex(ref):prevind(ref, idx)])
    inner = ref[nextind(ref, idx):end]
    for (a, _) in scopes
      scope = get(enums, (a, owner), nothing)
      scope === nothing && continue
      haskey(scope, inner) && return scope[inner]
    end
  end
  return nothing
end

"""
    _inherited_statements(graph, cls) -> Vector{PyStmt}

The field statements `cls` inherits from its abstract bases, ancestors first. Concatenating these
before the class's own body is the whole merge: `process_class_fields!` writes into a `Dict`, so
**last write wins** gives child-overrides-parent for free.

Bases are walked in **reverse** declaration order, because Python resolves `class C(A, B)` left to
right — A must win, so A's statements have to be written last.
"""
# ── Walking the abstract-ancestor chain ──────────────────────────────────────────────────────────
# Every helper below follows `_ClassInfo.parents`, and none of them can do it with a bare class
# name. `graph.info` describes THIS app's own classes; a parent token is a name in the CHILD's
# module, two apps may each declare a `Base`, and an `as` alias makes the token differ from the
# class's own name. So they read `graph.resolved[(app, token)]` — the edge classification actually
# took — and `graph.byapp[(app, name)]`, which covers every class the walk reached, in any app.

function _inherited_statements(graph, cls::PyClass)::Vector{PyStmt}
  out = PyStmt[]
  seen = Set{Tuple{Int, String}}()
  function walk(a::Int, c::PyClass)
    ci = get(graph.byapp, (a, c.name), nothing)
    ci === nothing && return
    for b in Iterators.reverse(ci.parents)
      r = get(graph.resolved, (a, b), nothing)
      r === nothing && continue
      (pa, pc) = r
      (pa, pc.name) in seen && continue
      push!(seen, (pa, pc.name))
      walk(pa, pc)
      append!(out, pc.body)
    end
    return
  end
  walk(graph.self, cls)
  return out
end

# Django's `AbstractUser` columns reach a class through an abstract base too:
# `class BaseUser(AbstractUser): class Meta: abstract = True` then `class User(BaseUser)`.
function _inherits_auth_user(graph, cls::PyClass)::Bool
  function walk(a::Int, c::PyClass, seen::Set{Tuple{Int, String}})::Bool
    key = (a, c.name)
    key in seen && return false
    push!(seen, key)
    ci = get(graph.byapp, key, nothing)
    ci === nothing && return false
    ci.is_auth_user && return true
    for b in ci.parents
      r = get(graph.resolved, (a, b), nothing)
      r === nothing && continue
      walk(r[1], r[2], seen) && return true
    end
    return false
  end
  return walk(graph.self, cls, Set{Tuple{Int, String}}())
end

"""
    _effective_meta(graph, cls) -> Dict{String, String}

The `Meta` options that apply to `cls`.

Django installs an abstract base's **whole** `Meta` on a child that declares none of its own,
resetting `abstract` as it does. Two keys are withheld:

- `abstract`, because Django resets it — inheriting it would emit no table for the child either.
- `db_table`, because inheriting it points every child of one base at a single table. Django does
  inherit it; that is a documented Django footgun rather than something to reproduce, so the caller
  warns instead.

Everything else carries through, including options with no PormG equivalent — otherwise an
`ordering` declared on the base would be dropped without the report the child's own `ordering` gets.
The same rule is what makes a base's `indexes` (#347) reach the child at all, rather than only the
one the child spells out itself.
"""
const _META_KEYS_NOT_INHERITED = ("abstract", "db_table")

function _effective_meta(graph, cls::PyClass)::Dict{String, String}
  b = _inherited_meta_base(graph, cls)
  b === nothing && return graph.byapp[(graph.self, cls.name)].meta
  pm = graph.byapp[(b[1], b[2].name)].meta
  return Dict{String, String}(k => v for (k, v) in pm if !(k in _META_KEYS_NOT_INHERITED))
end

"""
    _inherited_meta_base(graph, cls) -> Union{Tuple{Int, PyClass}, Nothing}

The abstract base whose `Meta` Django installs on `cls`, as `(owning app, class)`: the nearest
ancestor declaring a `Meta` block at all. `nothing` when `cls` declares its own, or when no ancestor
has one. The owning app travels with the class because a bare name cannot address it — see the
ancestor-walk note above.

One walk, used by BOTH consumers — `_effective_meta` and the withheld-`db_table` report. They used
to walk separately and disagree: the reporter climbed the whole chain while `_effective_meta`
stopped at the first match, so a grandparent's `db_table` was reported as withheld from a child that
would never have inherited it (Django resolves `Meta` to one class, not a merge of the chain).

Gated on whether a Meta BLOCK was declared, not on whether it yielded options: `class Meta:`
carrying only a docstring is still a declaration, and Django does not inherit past one.
"""
function _inherited_meta_base(graph, cls::PyClass)::Union{Tuple{Int, PyClass}, Nothing}
  isempty(cls.meta) || return nothing
  seen = Set{Tuple{Int, String}}()
  function walk(a::Int, c::PyClass)::Union{Tuple{Int, PyClass}, Nothing}
    ci = get(graph.byapp, (a, c.name), nothing)
    ci === nothing && return nothing
    for b in ci.parents
      r = get(graph.resolved, (a, b), nothing)
      r === nothing && continue
      (pa, pc) = r
      (pa, pc.name) in seen && continue
      push!(seen, (pa, pc.name))
      isempty(pc.meta) || return (pa, pc)
      w = walk(pa, pc)
      w === nothing || return w
    end
    return nothing
  end
  return walk(graph.self, cls)
end

"""
    _inherited_unresolved(graph, cls) -> Vector{Tuple{String, Int}}

Bases that neither `cls` nor any of its abstract ancestors could resolve, each with the index of the
app whose `models.py` actually declares the class carrying that base.

An abstract base with its own unresolvable base (`class Auditavel(TimeStampedModel)` with
`abstract = True`) loses columns exactly as the child would, but the base emits nothing — so without
walking the chain its gap reaches the generated file with no marker at all.

The owning app travels with the token because the walk crosses apps: an unresolved base found on
`core.Auditavel` while emitting `shop.Pedido` needs its `import` line in **`core`**, and advice
pointing at `shop` would be advice that cannot work.
"""
function _inherited_unresolved(graph, cls::PyClass)::Vector{Tuple{String, Int}}
  out = Tuple{String, Int}[]
  seen = Set{Tuple{Int, String}}()
  function walk(a::Int, c::PyClass)
    ci = get(graph.byapp, (a, c.name), nothing)
    ci === nothing && return
    for b in ci.unresolved
      any(t -> first(t) == b, out) || push!(out, (b, a))
    end
    for b in ci.parents
      r = get(graph.resolved, (a, b), nothing)
      r === nothing && continue
      (pa, pc) = r
      (pa, pc.name) in seen && continue
      push!(seen, (pa, pc.name))
      walk(pa, pc)
    end
    return
  end
  walk(graph.self, cls)
  return out
end

# The fix to suggest for a base nothing in the run defines, in the vocabulary of the arity in use.
# Conditional on purpose: the same marker covers a base from a third-party library, where there is
# no app to add and nothing to do, and an unconditional "add the app" would be advice that cannot be
# followed.
_resolve_base_advice(label)::String =
  label === nothing ?
    "if that module is an app of this project, pass every app as \"<app_label>\" => " *
    "\"<models.py>\" pairs so a base in another app is merged." :
    "if that module is an app of this project, add it to the pair list."

"""
    _bound_module_note(graph, bases) -> String

`", imported from 'model_utils.managers'"` when the module bound these names from somewhere the
import table records, or a phrase saying nothing in the run defines them.

This is what replaced *suppressing* the skip marker for a name bound outside the app set. The two
things that test conflates — a third-party library, and an app of this project the caller did not
pass — are the same string, and the caller is the only one who can tell them apart. Printing the
module lets them: `model_utils.managers` is dismissed at a glance, `core.models` says which pair is
missing.
"""
function _bound_module_note(graph, bases::Vector{String})::String
  mods = String[]
  for b in bases
    entry = get(graph.scopes[graph.self].imports.names, b, nothing)
    entry === nothing && continue
    entry[1] in mods || push!(mods, entry[1])
  end
  isempty(mods) && return ", which nothing in this import defines and this models.py does not import"
  return ", imported from " * join(("'$(m)'" for m in mods), ", ") *
         ", which nothing in this import defines"
end

"""
    _declaring_apps_hint(graph, bases) -> String

A sentence naming the other apps of this run that DECLARE a class of one of these names, or `""`.

Since #370 a base resolves across apps only when the module imported it, so two very different
situations would otherwise print the same marker: a base nothing in the project defines, and a base
another app defines but this one never imported. The fixes differ — one wants a pair added to the
call, the other an `import` line in the source — and only naming the app tells them apart. This is
the part of the issue's "improve the marker" option worth keeping once the lookup itself is fixed.

It states only what the import table can back, because the two shapes want different advice and a
guess told users something false in testing:

- the name was never imported → the fix is an `import` line;
- the name WAS imported, from a module outside the app set (`from library.base import BaseReport`)
  → there is nothing to fix, and the useful thing to say is that the two are simply different
  classes. This is #370's own shape, and "does not import it" would have been a plain lie.

A star import can bind the name invisibly, so nothing is claimed there at all. And `bases` carries
the app that declares the class holding the base — for an inherited gap that is an ancestor's app,
not the one being emitted, and advice naming the wrong module cannot work.
"""
function _declaring_apps_hint(graph, bases::Vector{Tuple{String, Int}})::String
  parts = String[]
  for (b, owner) in bases
    apps = String[]
    for (i, sc) in enumerate(graph.scopes)
      (i == owner || isempty(sc.label)) && continue
      haskey(sc.own, b) && push!(apps, sc.label)
    end
    isempty(apps) && continue
    sc = graph.scopes[owner]
    where = isempty(sc.label) ? "this file" : "app '$(sc.label)'"
    declared = "'$(b)' is declared by app" * (length(apps) == 1 ? " " : "s ") *
               join(("'$(a)'" for a in apps), ", ")
    entry = get(sc.imports.names, b, nothing)
    if entry !== nothing && _app_for_module(graph.scopes, entry[1]) === nothing
      # NOT "so they are different classes" — they may well be the same one. A qualified path can
      # fail to match an app that was handed over as SOURCE TEXT, because there is no location to
      # check the prefix against, and asserting difference there is simply false.
      push!(parts, declared * ", but $(where) imports it from '$(entry[1])', which this import " *
                   "could not match to any app — so they were not treated as the same class. If " *
                   "they are, pass that app by PATH so its package can be matched")
    elseif entry === nothing && isempty(sc.imports.stars)
      push!(parts, declared * ", but $(where) does not import it — add the import if that is what " *
                   "you meant")
    end
  end
  return isempty(parts) ? "" : " Note: " * join(parts, "; ") * "."
end

# An abstract base declaring `db_table` is a Django footgun the importer refuses to reproduce (see
# `_effective_meta`). Reported on each child that would have inherited it — which is exactly the one
# base `_inherited_meta_base` picks, not every ancestor in the chain.
function _abstract_db_table_base(graph, cls::PyClass)::Union{String, Nothing}
  b = _inherited_meta_base(graph, cls)
  b === nothing && return nothing
  return haskey(graph.byapp[(b[1], b[2].name)].meta, "db_table") ? b[2].name : nothing
end

"""
    parse_class(model_py_string) -> Vector{PyClass}

Recover the model classes this importer emits a table for.

Statement- and indentation-driven (#340): a field spanning several physical lines arrives intact,
a nested `class Status(models.TextChoices)` stays in `nested` instead of leaking into the parent's
fields, `class Meta:` is isolated in `meta`, and module-level code after the last class is ignored
rather than appended to it.

Base lists are **resolved**, not string-matched (#341): an abstract base contributes its fields to
its children and emits nothing itself, a proxy emits nothing, and a class whose bases this file does
not define is still imported (its missing ancestry is reported by the caller).
"""
function parse_class(model_py_string::String)::Vector{PyClass}
  graph = _django_class_graph(model_py_string)
  return filter(c -> _is_emitted(graph.info[c.name]), graph.classes)
end

# Split `text` on its first TOP-LEVEL `=` — not inside a string or bracket, and not part of a
# comparison operator. Returns `(lhs, rhs)` or `nothing`.
function _split_top_level_assign(text::AbstractString)
  st = _PyScan()
  i = firstindex(text)
  stop = lastindex(text)
  while i <= stop
    c = text[i]
    j = _py_step!(st, text, i)
    if c == '=' && st.depth == 0 && !_in_string(st)
      nxt = j <= stop ? text[j] : '\0'
      prv = i > firstindex(text) ? text[prevind(text, i)] : '\0'
      if nxt != '=' && !(prv in ('=', '<', '>', '!'))
        return (String(strip(text[firstindex(text):prevind(text, i)])), String(strip(text[j:end])))
      end
    end
    i = j
  end
  return nothing
end

const _FIELD_CALL_RE = r"^models\.(\w+)\s*\("
# Captures the final identifier of a dotted call target (`a.b.ArrayField(` → `ArrayField`). Used only
# to decide whether an unrecognised assignment is FIELD-shaped and therefore worth reporting.
const _CALL_TARGET_RE = r"^(?:[A-Za-z_]\w*\s*\.\s*)*([A-Za-z_]\w*)\s*\("

# Suffixes that make a call target a column declaration by name. `Key` is not optional: Django's
# relation family splits across both — `OneToOneField`/`ManyToManyField` end in `Field`, but
# `ForeignKey` does not, and `from django.db.models import ForeignKey` is a normal idiom (as is
# django-mptt's `TreeForeignKey`). Matching only `Field` left the single most important field type
# dropping in silence — exactly the hole this issue exists to close.
const _FIELD_NAME_SUFFIXES = ("Field", "Key")

"""
    _looks_like_a_field_call(rhs) -> Bool

True when `rhs` is a call whose target names a column type — `ArrayField(...)`, `ForeignKey(...)`,
`TreeForeignKey(...)`: a field imported directly instead of through `models.`.

Deliberately narrow. Warning on *every* unreadable call buried the one real finding under
`objects = SomeQuerySet.as_manager()`, `history = HistoricalRecords()` and other class-body
assignments that have no PormG equivalent — and a warning nobody reads is the silent drop this
issue exists to remove, wearing a hat.
"""
function _looks_like_a_field_call(rhs::AbstractString)::Bool
  m = match(_CALL_TARGET_RE, rhs)
  m === nothing && return false
  return any(sfx -> endswith(m.captures[1], sfx), _FIELD_NAME_SUFFIXES)
end

"""
    _match_field_statement(text) -> nothing | (name, type, args)

Recognise `name = models.Type(args)` in a logical statement. `type === nothing` means the statement
*is* an assignment but not a `models.X(...)` call — the caller decides whether that is worth
reporting. Replaces the old `field_regex`, which could not see past one physical line.

A django-stubs annotation (`name: str = models.CharField(...)`) is accepted: the annotation is
dropped and the field imported, rather than failing the identifier check and vanishing.
"""
function _match_field_statement(text::AbstractString)
  parts = _split_top_level_assign(text)
  parts === nothing && return nothing
  lhs, rhs = parts
  ann = findfirst(':', lhs)
  ann === nothing || (lhs = String(strip(lhs[firstindex(lhs):prevind(lhs, ann)])))
  Base.isidentifier(lhs) || return nothing
  m = match(_FIELD_CALL_RE, rhs)
  m === nothing && return (name = lhs, type = nothing, args = rhs)
  args = _balanced_group(rhs)
  args === nothing && return (name = lhs, type = nothing, args = rhs)
  return (name = lhs, type = String(m.captures[1]), args = args)
end

# `class_name` and `class_label` are two different jobs and must NOT be collapsed into one (#371):
#
#   - `class_name` is half of the enum SCOPE KEY. `enums` is keyed by `(app_index, bare Python
#     class name)`, so the `enum_scopes` default below has to stay bare — an "app.Class" string in
#     that slot makes every `_lookup_enum` miss and silently drops the choices and defaults of every
#     `TextChoices` in a labelled import, which is precisely what #342 exists to make work. Note the
#     app is ALREADY carried, as the `Int`; spelling it again in the string would double-qualify.
#   - `class_label` is what a `# PormG:` marker and a `@warn` NAME. That has to be app-qualified, or
#     two apps' `Pessoa` produce reports the reader cannot tell apart.
#
# They coincide exactly when the import carries no app label, which is why the default is safe.
#
# (`enum_scopes` looks droppable — the sole production caller passes it explicitly, so its default
# is dead on the real path. Leave it: it is the only thing documenting how the vector is built, and
# removing it turns this comment into the next reader's silent enum regression.)
function process_class_fields!(fields_dict::Dict{Symbol, Any}, class_content::Vector{PyStmt},
                               class_name::AbstractString, is_auth_user::Bool,
                               autofields_ignore::Vector{String}, parameters_ignore::Vector{String},
                               markers::Vector{String} = String[],
                               enums = Dict{Tuple{Int, String}, Dict{String, _PyEnum}}(),
                               enum_scopes::Vector{Tuple{Int, String}} =
                                 Tuple{Int, String}[(1, String(class_name)), (1, "")];
                               class_label::AbstractString = class_name)
  # Django's `AbstractUser` columns. A Bool rather than the base-list STRING it used to compare
  # against (#341): the base list is now parsed, so `class User(AbstractUser, SomeMixin)` and a
  # class reaching `AbstractUser` through an abstract base both qualify — an equality test on the
  # whole base list matched neither.
  #
  # `id` is deliberately NOT one of them (#369). `AbstractUser` INHERITS Django's implicit `id`
  # from `models.Model` rather than owning it, so a declared `primary_key=True` suppresses it here
  # exactly as on any other model — and the caller already applies that rule to every class it
  # emits. Injecting one here instead claimed the key before a single field had been read, so a
  # legacy user table keyed on `matricula` came out with TWO primary keys and could never load.
  # Do not re-add it.
  #
  # Returns the field keys whose surviving declaration said `primary_key=True` — see the loop.
  declared_pk = Set{Symbol}()

  if is_auth_user
      fields_dict[:password] = Models.CharField()
      fields_dict[:last_login] = Models.DateTimeField()
      fields_dict[:is_superuser] = Models.BooleanField()
      fields_dict[:username] = Models.CharField()
      fields_dict[:first_name] = Models.CharField()
      fields_dict[:last_name] = Models.CharField()
      fields_dict[:email] = Models.CharField()
      fields_dict[:is_staff] = Models.BooleanField()
      fields_dict[:is_active] = Models.BooleanField()
      fields_dict[:date_joined] = Models.DateTimeField()
  end

  # Iterate over the fields in the class content. Each entry is a LOGICAL statement (#340), so a
  # field wrapped across physical lines is matched like any other.
  for stmt in class_content
    parsed = _match_field_statement(stmt.text)
    parsed === nothing && continue

    if parsed.type === nothing
      # #340's actual requirement: never drop a FIELD in silence. An assignment whose right-hand
      # side is a field-shaped call the importer cannot read (`tags = ArrayField(...)` — a field
      # imported directly rather than through `models.`) is reported with its source line so the
      # author can declare it by hand. Managers, constants and enum members are not fields and
      # stay quiet: see `_looks_like_a_field_call` for why the test is deliberately narrow.
      if _looks_like_a_field_call(parsed.args)
        @warn "import: field-shaped call the importer cannot read; not imported — declare it in PormG by hand" field=parsed.name class=class_label line=stmt.lineno
        # ...and a marker in the generated file, not the warning alone (#341). A console warning
        # scrolls away; whoever opens the generated file months later needs to see the gap there.
        push!(markers, "# PormG: field '$(parsed.name)' on '$(class_label)' (models.py line " *
                       "$(stmt.lineno)) is a field-shaped call the importer cannot read — NOT " *
                       "imported. Declare it in PormG by hand.")
      end
      continue
    end

    field_name = parsed.name
    # Django's spelling and PormG's are tracked SEPARATELY (#399), because only one of the two jobs
    # wants the mapped name. `django_type` is what the models.py actually wrote, and it is what every
    # path that REPORTS or IGNORES a field must name: `autofields_ignore` is documented in Django's
    # vocabulary (`["Manager"]`), and a marker naming a type the author never typed is #371 all over
    # again. `field_type` — the mapped name — exists for the CONSTRUCTOR lookup and nothing else.
    # They differ only for the names in `DJANGO_AUTO_KEY_TYPES`; for every other type the map is the
    # identity and the two are the same string. `AutoField` is why this separation is not academic:
    # it is a name BOTH vocabularies use, for two different field types.
    django_type = String(parsed.type)
    field_type = django_field_type(django_type)
    field_args_str = parsed.args

    # Parse field arguments
    options, related_model = parse_field_args(field_args_str, django_type, parameters_ignore;
                                              enums = enums, class_name = class_name,
                                              enum_scopes = enum_scopes, class_label = class_label,
                                              field_name = field_name, markers = markers)

    # An IGNORED field type contributes no column, so it cannot be the primary key either. Tested
    # BEFORE the primary-key bookkeeping below for that reason (#346): the other order let
    # `autofields_ignore = [… "CharField"]` claim the PK from a `CharField(primary_key=True)` and
    # then drop it, so the synthetic `id` was suppressed and the model came out with NO fields at
    # all. `_import_django_apps` then skipped it silently — while the class index had already handed
    # it a binding, so every ForeignKey to it named a binding the generated file never defined.
    #
    # Matched on `django_type`, NOT the mapped name: the option is documented as "Django field types
    # to ignore", so `autofields_ignore = ["BigAutoField"]` has to mean the name in the models.py.
    # Matching the mapped name would make that entry a silent no-op AND make `["AutoField"]` quietly
    # swallow types the caller never named.
    django_type in autofields_ignore && continue

    # A narrower Django key came through as the one PormG can round-trip — the key is faithful, the
    # declared width is not. Reported for the same reason every other degrade in this file is:
    # whoever opens the generated file months from now has no other way to learn that the models.py
    # said something narrower. Placed AFTER the ignore check, so a field the caller dropped is not
    # reported as imported.
    if haskey(DJANGO_DEGRADED_FIELD_TYPES, django_type)
      @warn "import: no PormG key type round-trips this Django field type; imported as IDField" class=class_label field=field_name django_type=django_type django_width=DJANGO_AUTO_KEY_TYPES[django_type]
      push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' is a Django " *
                     "$(django_type) ($(DJANGO_AUTO_KEY_TYPES[django_type])) — imported as " *
                     "$(field_type) (BIGINT). " * DJANGO_DEGRADED_FIELD_TYPES[django_type])
    end

    # The key this statement writes, computed up front so the bookkeeping below can name it without
    # restating the ForeignKey `_id` rule.
    field_key = field_type in ["ForeignKey", "OneToOneField"] ? Symbol("$(field_name)_id") :
                                                                Symbol(field_name)

    # Whether DJANGO called this field the primary key — recorded beside the built field because it
    # cannot be read back off it (#369). Most PormG field types do not accept `primary_key` at all:
    # `_common_kwargs` warns "Unexpected parameter" and constructs with `primary_key = false`, so a
    # legacy table keyed on `codigo = models.IntegerField(primary_key=True)` yields a field that
    # denies being the key. Deciding the implicit `id` from the built fields ALONE would then invent
    # an `id` column the Django table has not got. Mirrors `fields_dict`'s last-write-wins, so a
    # child overriding an inherited key with a plain field drops the claim along with the value.
    #
    # A ManyToManyField is excluded outright: it contributes no column, `sManyToManyField` hardcodes
    # `primary_key = false`, and Django rejects the combination anyway — so recording one would
    # report a lost column that never was a column.
    if field_type != "ManyToManyField" && get(options, :primary_key, false) == true
      push!(declared_pk, field_key)
    else
      delete!(declared_pk, field_key)
    end

    # Instantiate the field
    try
      # println(field_type)
      if field_type in ["ForeignKey", "OneToOneField"]
        # `field_key` already carries the "_id" suffix foreign keys take.
        # println(related_model, " ", related_model |> typeof)
        _normalize_django_set_default!(options, field_name, class_label)
        fields_dict[field_key] = getfield(Models, Symbol(field_type))(related_model; options...)
      elseif field_type == "ManyToManyField"
        fields_dict[field_key] = Models.ManyToManyField(related_model; options...)
      else
        fields_dict[field_key] = getfield(Models, Symbol(field_type))(; options...)
      end
    catch e
      @pormg_debug
      # #342's safety net. A choices/default disagreement is the ONE construction failure that used
      # to abort the entire import — every other model in the file lost to one enum. Retry once
      # without those two kwargs; the column survives, its enumeration does not, and the generated
      # file says so.
      #
      # Not redundant with the drop rules in `parse_field_args`: this catches the case where both
      # kwargs resolve perfectly well and the PAIR is invalid — `choices=Status.choices` with a
      # `default` that is not one of the members.
      #
      # The retry SUCCEEDING is the whole safety property, and no inspection of the error is needed
      # to get it. Removing exactly these two kwargs changes nothing else, so a construction that
      # starts working without them failed because of them; one that still fails falls through to
      # the normal path untouched. An unsupported field TYPE (#268) never reaches a different
      # outcome for the same reason — the retry fails identically and rethrows.
      #
      # The `haskey` test below is an OPTIMIZATION, not a guard: with neither kwarg present the
      # filter removes nothing and the retry would simply repeat the same failing call. Do not read
      # it as load-bearing — `recovered` is what makes this safe.
      if haskey(options, :choices) || haskey(options, :default)
        retry_options = filter(kv -> !(kv.first in (:choices, :default)), options)
        recovered = try
          if field_type in ["ForeignKey", "OneToOneField"]
            fields_dict[field_key] = getfield(Models, Symbol(field_type))(related_model; retry_options...)
          elseif field_type == "ManyToManyField"
            fields_dict[field_key] = Models.ManyToManyField(related_model; retry_options...)
          else
            fields_dict[field_key] = getfield(Models, Symbol(field_type))(; retry_options...)
          end
          true
        catch e2
          # A control-flow exception is not a field-validation failure and must not be swallowed
          # into `recovered = false` (#322's lesson: an interrupt in the wrong place leaves state
          # nobody can reason about).
          (e2 isa InterruptException || e2 isa StackOverflowError) && rethrow()
          false
        end
        if recovered
          reason = _one_line(sprint(showerror, e), 160)
          # Name only what was actually there. The blanket "choices and default … the enumeration
          # is not enforced" claimed an enumeration on fields that had none — an over-long `default`
          # on a plain CharField recovers through this same path.
          dropped = join(("`$(k)`" for k in (:choices, :default) if haskey(options, k)), " and ")
          tail = haskey(options, :choices) ? " The column is real; the enumeration is not enforced." :
                                             " The column is real, but its default is now unset here" *
                                             " while Django still declares one."
          @warn "import: field option rejected; field imported without it" class=class_label field=field_name dropped=dropped reason=reason
          push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' — $(dropped) rejected " *
                         "and dropped: $(reason).$(tail)")
          continue
        end
      end
      # A FieldValidationError/InvalidValueError from field construction is already the right
      # type — stringifying it into an ErrorException would eject it from the taxonomy (audit).
      e isa PormGError && rethrow()
      throw(InvalidMigrationError("Error processing field '$field_name' in class '$class_label': $(e)"))
    end
  end

  return declared_pk

end

# Django's auto-increment key types → the PormG constructor to call. ALL of them resolve to
# `IDField`, and the reason is not "closest match" — it is that `IDField` is the ONLY integer key
# type an imported model can be given without condemning it to a migration that never converges:
#
#   * `introspection.jl` force-converts every non-UUID primary key it reads to `IDField` (the
#     `elseif primary_key` branch — deliberate, see #334), so `IDField` is what the database will
#     ALWAYS appear to hold, whatever the column's real width;
#   * `Dialect.describes_same_column` returns `false` outright when either side declares a key, so
#     the "different Julia type, same physical column" escape hatch is closed for exactly this case;
#   * a model declaring anything else therefore never equals what introspection reports,
#     `planner.jl` pushes `:type`, and `makemigrations` proposes the same ALTER on that column on
#     every single run, forever.
#
# `AutoField` (#399) is the counter-intuitive entry: PormG HAS a field by that name, so mapping the
# Django type onto it is the obvious move and it is the wrong one — `sAutoField` is not a fixed
# point of the introspection above. The synthetic `id` this file injects has always used `IDField`
# for the same reason; these mappings just stop a DECLARED key from being treated worse than an
# undeclared one.
#
# `BigAutoField` and `SmallAutoField` had no PormG counterpart at all, and
# `getfield(Models, :BigAutoField)` used to abort the import of the WHOLE file — every other model
# in it lost to one column.
const DJANGO_AUTO_KEY_TYPES = Dict{String, String}(
  "AutoField"      => "INTEGER",   # Django: serial
  "BigAutoField"   => "BIGINT",    # Django: bigserial — 3.2+'s DEFAULT_AUTO_FIELD, an exact match
  "SmallAutoField" => "SMALLINT",  # Django: smallserial
)

# The subset whose substitution actually LOSES something a reader of the generated file would
# otherwise never learn. `BigAutoField` is absent on purpose: BIGINT auto-increment is precisely
# what `IDField` is, so reporting it would be noise, and a marker emitted for everything is a
# marker that means nothing.
const DJANGO_DEGRADED_FIELD_TYPES = Dict{String, String}(
  dj => "PormG has no $(width) auto-increment key it can round-trip: introspection reports EVERY " *
        "integer primary key as IDField, so any narrower type here would leave makemigrations " *
        "proposing the same ALTER on this column on every run. Your EXISTING column is not " *
        "re-typed; but a table PormG CREATES from this model gets BIGINT, not $(width)."
  for (dj, width) in DJANGO_AUTO_KEY_TYPES if width != "BIGINT"
)

function django_field_type(field_type::AbstractString)::String
  haskey(DJANGO_AUTO_KEY_TYPES, field_type) && return "IDField"
  return String(field_type)
end

# `class_name` seeds `enum_scopes` — the key vector into `enums`, which is keyed by `(app_index,
# BARE Python class name)` — so it must not be app-qualified; the app is already the `Int`.
# `class_label` only NAMES the class in a report and must be. See the note on
# `process_class_fields!` for why collapsing them silently kills enum resolution (#371, #342). On
# the production path the seeding is moot: the sole caller passes `enum_scopes` explicitly, so
# `class_name` reaches nothing but that default here.
#
# `class_label` is declared AFTER `enum_scopes` deliberately: a keyword default may reference only
# keywords listed before it, and putting `class_label = class_name` above `class_name` compiles
# cleanly and throws `UndefVarError(:class_name)` at call time — on the default path only. Keeping
# it last also leaves the `class_name` → `enum_scopes` coupling visually adjacent.
function parse_field_args(args_str::AbstractString, field_type::AbstractString, parameters_ignore::Vector{String};
                         enums = Dict{Tuple{Int, String}, Dict{String, _PyEnum}}(),
                         class_name::AbstractString = "",
                         enum_scopes::Vector{Tuple{Int, String}} = Tuple{Int, String}[(1, String(class_name)), (1, "")],
                         class_label::AbstractString = class_name,
                         field_name::AbstractString = "",
                         markers::Vector{String} = String[])
  # This function parses field arguments handling nested parentheses and commas
  # and returns a dictionary of options.
  options = Dict{Symbol, Any}()
  options_list = split_field_options(args_str)
  # println(options_list)
  related_model = missing
  # Enum references this file cannot resolve (`from .enums import Status`), as (option, enum) pairs.
  # Each one is dropped where it is found — the literal must never reach the field constructor,
  # since `default="Status.DRAFT"` against an empty `choices` is exactly the FieldValidationError
  # that aborted the whole import. This list only drives the REPORT, so one field yields one marker
  # naming every option it lost and why.
  unresolved_enums = Tuple{String, String}[]
  for option_str in options_list
      key_value = split(option_str, "=", limit=2)
      if length(key_value) == 2
          key = strip(key_value[1])
          value = strip(key_value[2])
          field_type == "ManyToManyField" && key == "blank" && continue
          key in parameters_ignore && continue
          # Django callable datetime defaults (e.g. default=timezone.now) have no
          # literal equivalent in PormG. Map them to auto_now_add, which sets the
          # column to the current timestamp on creation — the closest semantics.
          if key == "default" && field_type in DATETIME_FIELD_TYPES && is_current_time_default(value)
              options[:auto_now_add] = true
              continue
          end
          # Resolve `Status.choices` / `Status.DRAFT` BEFORE parse_value (#342), which would
          # otherwise hand the literal text through and let CharField reject the pair.
          resolved = _resolve_enum_reference(value, enums, enum_scopes, class_label, field_name, key, markers, unresolved_enums)
          # A DISTINCT sentinel, not `nothing`: `parse_value("None")` is `nothing`, so an enum
          # member declared `NENHUM = None, "Nenhum"` resolved to `nothing` and was read here as
          # "dropped" — the option vanished with no warn and no marker, which is the one thing this
          # importer promises never to do.
          resolved === _ENUM_DROP && continue       # dropped, and already reported
          if resolved !== _ENUM_NOT_A_REFERENCE
            options[Symbol(key)] = resolved
          elseif key == "choices"
            # Routed explicitly rather than through `parse_value`, whose bracket branch only takes
            # `(...)`. A `[...]` container fell through to a raw String and was re-parsed much later
            # by `Models.parse_choices`, which still keeps the quote characters — so one generated
            # model carried both spellings, the very thing the normalization exists to prevent.
            bad = String[]
            parsed = parse_choices(value, bad)
            for b in bad
              # Two shapes share this channel and a reader must be able to tell them apart: the
              # WHOLE option was unreadable (a bare name, nothing parsed), or ONE entry inside a
              # readable container was malformed and its siblings survived.
              whole = isempty(parsed) && length(bad) == 1 && b == _one_line(value)
              @warn "import: choices could not be read; dropped" class=class_label field=field_name entry=_one_line(b) whole_option=whole
              push!(markers, whole ?
                "# PormG: field '$(field_name)' on '$(class_label)' has `choices=$(_one_line(b))`, " *
                "which is a name rather than a literal — the whole option was dropped." :
                "# PormG: field '$(field_name)' on '$(class_label)' has a choices entry that is not " *
                "a (value, label) pair — that entry was dropped: $(_one_line(b))")
            end
            # Nothing readable means the option is DROPPED, not set to `()`. An empty tuple declares
            # an enumeration with no members, which is a stranger claim than declaring none — and it
            # round-trips into the generated file as a literal `choices=()`.
            isempty(parsed) || (options[Symbol(key)] = parsed)
          else
            options[Symbol(key)] = parse_value(value)
          end
      else
        if field_type in ["ForeignKey", "OneToOneField", "ManyToManyField"]
          related_model = replace(key_value[1], "\"" => "", "'" => "") |> string
          field_type in ["ForeignKey", "OneToOneField"] && (options[:pk_field] = "id")
        end
      end
  end

  # One marker per FIELD, not per option: a `choices=X.choices, default=X.MEMBER` pair naming the
  # same unknown enum is one problem, and saying it twice is noise. The options themselves were
  # already dropped at the point each was read.
  #
  # Deliberately NOT a blanket "drop both": if `choices` resolves and only `default` does not, the
  # field keeps its enumeration and loses just the default. Discarding the resolvable half would
  # throw away information the source actually gave us.
  if !isempty(unresolved_enums)
    names = join(("`$(e)`" for e in unique(last.(unresolved_enums))), ", ")
    opts = join(("`$(k)`" for k in unique(first.(unresolved_enums))), " and ")
    # "does not define", not "enum": the same shape catches a module constant
    # (`default=constants.MAX_QTD`), and calling that an enumeration in the artifact is a lie the
    # reader has no way to check.
    @warn "import: name is not defined in this file; option dropped" class=class_label field=field_name reference=unique(last.(unresolved_enums)) options=unique(first.(unresolved_enums))
    push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' references $(names), which " *
                   "this file does not define — $(opts) dropped. The column is real. If that is an " *
                   "enumeration, import the module defining it alongside this one, or declare the " *
                   "choices by hand.")
  end

  # `choices` only exists on CharField. Every other field type would take it to `_common_kwargs`,
  # which warns anonymously ("Unexpected parameter for TextField") and drops it — true but useless
  # for finding the field. Report it here, where the field, class and value are all known.
  if haskey(options, :choices) && field_type != "CharField"
    delete!(options, :choices)
    @warn "import: this field type has no choices slot; the option was dropped" class=class_label field=field_name field_type=field_type
    push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' declares choices, but " *
                   "$(field_type) has no choices slot in PormG (only CharField does) — dropped. " *
                   "The column is unaffected.")
  end

  return options, related_model
end

# Sentinels. Two distinct ones, because `nothing` is a legitimate RESOLVED value: an enum member
# declared `NENHUM = None, "Nenhum"` parses to `nothing`, and conflating that with "drop" made the
# option disappear with no warn and no marker.
const _ENUM_NOT_A_REFERENCE = :_enum_not_a_reference   # not a reference — parse it normally
const _ENUM_DROP = :_enum_drop                         # drop this option; already reported

# A dotted reference whose head could name an enum: `Status.choices`, `Status.DRAFT`,
# `ImportBatch.Status.DRAFT`. Anything with a call, a bracket or a quote is not one.
const _ENUM_REF_RE = r"^([A-Za-z_][\w.]*)\.([A-Za-z_]\w*)$"

# Django enum attributes that are not a single value and have no PormG equivalent.
const _ENUM_PLURAL_ATTRS = ("values", "labels", "names")

# The attribute shapes worth claiming as an enumeration when the head is NOT a name this file
# defines. `.choices` and its plural siblings are unambiguous, and a member of a Python `Enum` is
# conventionally SHOUTY_CASE.
#
# Without this test, EVERY dotted `default=` was captured: `default=uuid.uuid4`,
# `default=timezone.now` and `default=datetime.date.today` were all dropped and reported as
# enumerations — an undocumented behavior change on fields that have nothing to do with enums, with
# a diagnostic that named the wrong thing.
_looks_like_enum_attr(attr::AbstractString)::Bool =
  attr == "choices" || attr in _ENUM_PLURAL_ATTRS || attr in _ENUM_MEMBER_ATTRS ||
  occursin(r"^[A-Z][A-Z0-9_]*$", attr)

# Single-value attributes OF A MEMBER: `Status.NOVO.value`, `.label`, `.name`. Django's own
# `TextChoices` exposes all three, and `.value` is an ordinary way to spell a default.
const _ENUM_MEMBER_ATTRS = ("value", "label", "name")

"""
    _resolve_enum_reference(value, enums, enum_scopes, class_label, field_name, key, markers, unresolved) -> Any

Resolve a Django enum reference in a field option.

`enum_scopes` does the LOOKUP — it is the ordered list of keys into `enums`, which is keyed by
`(app_index, bare Python class name)`. `class_label` only NAMES the owning class in a report and is
app-qualified (#371); it never reaches a lookup, so the two must not be swapped.

Returns the resolved value, `_ENUM_NOT_A_REFERENCE` when `value` is not one, or `_ENUM_DROP` to mean
"drop this option" (already warned and marked).
"""
function _resolve_enum_reference(value::AbstractString, enums, enum_scopes::Vector{Tuple{Int, String}},
                                 class_label::AbstractString,
                                 field_name::AbstractString, key::AbstractString,
                                 markers::Vector{String},
                                 unresolved::Vector{Tuple{String, String}})
  m = match(_ENUM_REF_RE, strip(value))
  m === nothing && return _ENUM_NOT_A_REFERENCE
  head = String(m.captures[1])
  attr = String(m.captures[2])

  # `Status.NOVO.value` — a single-value attribute OF A MEMBER. Peel it so the rest of this
  # function sees the member reference it already knows how to resolve. `.label` and `.name` have
  # no PormG equivalent as a column default, so they are reported like the plural attributes.
  if attr in _ENUM_MEMBER_ATTRS
    inner = findlast('.', head)
    if inner !== nothing
      enum_ref = head[firstindex(head):prevind(head, inner)]
      member = head[nextind(head, inner):end]
      if _lookup_enum(enums, enum_scopes, enum_ref) !== nothing
        if attr != "value"
          @warn "import: enum member attribute has no PormG equivalent; the option was dropped" class=class_label field=field_name attribute="$(head).$(attr)"
          push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' uses " *
                         "`$(head).$(attr)`, which is the member's $(attr) rather than its stored " *
                         "value — PormG has no equivalent, so `$(key)` was dropped.")
          return _ENUM_DROP
        end
        head = String(enum_ref)
        attr = String(member)
      end
    end
  end

  enum = _lookup_enum(enums, enum_scopes, head)

  if enum === nothing
    # Only `choices`/`default` can carry an enum, and only an enum-SHAPED attribute is worth
    # DROPPING — `on_delete=models.CASCADE` and `default=timezone.now` must keep flowing to
    # `parse_value` exactly as before.
    (key == "choices" || key == "default") || return _ENUM_NOT_A_REFERENCE
    if !_looks_like_enum_attr(attr)
      # Kept verbatim, as before this change — but REPORTED. `default=Externo.ativo` is an enum
      # member spelled unconventionally, and it is indistinguishable from `default=uuid.uuid4` by
      # syntax alone. Guessing either way is wrong for the other, so the value is left untouched
      # and the reader is told a dotted expression landed in the schema as a literal.
      key == "default" || return _ENUM_NOT_A_REFERENCE
      @warn "import: dotted default kept verbatim; the importer cannot evaluate it" class=class_label field=field_name value=_one_line(value)
      push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' has " *
                     "`default=$(_one_line(value))`, an expression the importer cannot evaluate — " *
                     "kept verbatim as text. Check it: if it names an enum member or a constant, " *
                     "the stored default is the expression, not its value.")
      return _ENUM_NOT_A_REFERENCE
    end
    push!(unresolved, (String(key), head))
    return _ENUM_DROP
  end

  if attr == "choices"
    bad = [n for (n, v, _) in enum.members if !_is_py_literal(v)]
    if !isempty(bad)
      # `CARRO = auto()` is a documented Django idiom, and importing it verbatim gives every member
      # the value "auto()" — duplicates that then PASS validation, because the default is literally
      # in the set. Wrong metadata kept in silence is the mirror of a silent drop.
      @warn "import: enum has members whose values are not literals; choices dropped" class=class_label field=field_name enum=head members=bad
      push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' uses `$(head).choices`, but " *
                     "$(join(("`$(head).$(b)`" for b in bad), ", ")) " *
                     "$(length(bad) == 1 ? "has a value" : "have values") the importer cannot read " *
                     "(a call or an expression, not a literal) — `$(key)` was dropped.")
      return _ENUM_DROP
    end
    if isempty(enum.members)
      @warn "import: enum declares no members; choices dropped" class=class_label field=field_name enum=head
      push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' uses `$(head).choices`, " *
                     "but `$(head)` declares no members — `$(key)` was dropped.")
      return _ENUM_DROP
    end
    return Tuple((_py_scalar_text(v), l) for (_, v, l) in enum.members)
  elseif attr in _ENUM_PLURAL_ATTRS
    @warn "import: enum attribute has no PormG equivalent; the option was dropped" class=class_label field=field_name attribute="$(head).$(attr)"
    push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' uses `$(head).$(attr)`, " *
                   "which is a list of $(attr) rather than (value, label) pairs — PormG has no " *
                   "equivalent, so `$(key)` was dropped.")
    return _ENUM_DROP
  end

  idx = findfirst(t -> t[1] == attr, enum.members)
  if idx === nothing
    @warn "import: enum has no such member; the option was dropped" class=class_label field=field_name reference="$(head).$(attr)"
    push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' references " *
                   "`$(head).$(attr)`, which is not a member of `$(head)` — `$(key)` was dropped.")
    return _ENUM_DROP
  end
  member_value = enum.members[idx][2]
  if !_is_py_literal(member_value)
    @warn "import: enum member value is not a literal; the option was dropped" class=class_label field=field_name reference="$(head).$(attr)" value=_one_line(member_value)
    push!(markers, "# PormG: field '$(field_name)' on '$(class_label)' references " *
                   "`$(head).$(attr)`, whose value is `$(_one_line(member_value))` — a call or an " *
                   "expression the importer cannot read, not a literal. `$(key)` was dropped.")
    return _ENUM_DROP
  end
  # The member's VALUE, canonicalized the same way the `choices` tuple is — otherwise a `1_000`
  # default and a `"1_000"` choice agree with each other and with nothing in the database.
  # `parse_value` handles the non-numeric literals (quoted strings, `None`, booleans).
  n = _py_number(member_value)
  return n === nothing ? parse_value(member_value) : n
end

# Django field types that map to PormG date/time fields carrying auto_now_add.
const DATETIME_FIELD_TYPES = ["DateTimeField", "DateField", "TimeField"]

# Django callables that resolve to "the current moment" at row creation. Used as
# field defaults (e.g. default=timezone.now); they have no literal value to import.
const CURRENT_TIME_CALLABLES = Set([
  "timezone.now",
  "django.utils.timezone.now",
  "datetime.now",
  "datetime.datetime.now",
  "now",
])

function is_current_time_default(value::AbstractString)::Bool
  # Accept both `timezone.now` (callable reference) and `timezone.now()` (call).
  normalized = replace(strip(value), r"\(\s*\)$" => "")
  return normalized in CURRENT_TIME_CALLABLES
end

"""
    _normalize_django_set_default!(options, field_name, class_label) -> options

Rewrite Django's `on_delete=SET_DEFAULT, default=None` on a nullable FK to `SET_NULL` (#287).

Django accepts that combination and it denotes exactly one thing: on parent delete, set the
dependent FK to `None`, i.e. SQL `NULL`. PormG cannot express "SET_DEFAULT whose default is NULL" —
since #287 that pair is a rejected self-contradiction — so the faithful translation is `SET_NULL`.

Without this the importer emits a model file that raises `ModelDefinitionError` the moment it is
loaded through `@import_models`, and regenerating produces the identical unloadable file. Only the
nullable case is rewritten: `SET_DEFAULT` with no default on a **non**-nullable FK is genuinely
contradictory in both ORMs and is left to fail loudly at registration.
"""
function _normalize_django_set_default!(options::Dict, field_name, class_label::AbstractString)
  haskey(options, :on_delete) || return options
  # A malformed on_delete (e.g. Django's `SET(callable)`) throws here; let the field constructor
  # raise it in its usual place rather than from this helper.
  mode = try
    Models._get_on_delete_mode(options[:on_delete])
  catch
    return options
  end
  mode === Models.SET_DEFAULT || return options
  get(options, :default, nothing) === nothing || return options
  get(options, :null, false) === true || return options

  # Structured, and NAMING the class app-qualified like every other report (#371). It used to
  # carry the field name alone interpolated into the message — the one diagnostic in this file a
  # reader of a multi-app import could not attribute to a model.
  @warn "import: on_delete=SET_DEFAULT with default=None denotes SET NULL; importing it as on_delete=SET_NULL" class=class_label field=field_name
  options[:on_delete] = "SET_NULL"
  return options
end

function parse_value(value::AbstractString)
  value = strip(value)
  if value == "True"
      return true
  elseif value == "False"
      return false
  elseif value == "None"
      # Python's None literal (e.g. default=None) is a null value; map it to
      # Julia's `nothing`. Passing "None" verbatim would crash typed converters
      # such as ForeignKey's default (parse(Int64, "None")).
      return nothing
  elseif value == "list"
      return "[]"
  elseif value == "dict"
      return "{}"
  elseif occursin(r"^\d+$", value)
      return parse(Int, value)
  elseif (startswith(value, "\"") && endswith(value, "\"")) || (startswith(value, "'") && endswith(value, "'"))
      return String(value[2:end-1])  # Remove surrounding quotes
  elseif startswith(value, "(") && endswith(value, ")")
      # Handle nested tuples (e.g., choices)
      return parse_choices(value)
  else
      return String(value)  # Return as string or handle other types as needed
  end
end

"""
    _strip_py_quotes(s) -> String

Strip one layer of matching Python quotes, if present. `"UP"` -> `UP`; `UP` -> `UP`.

Not folded into `parse_value`: this is for text that is already known to be a bare literal, where
`parse_value`'s type inference (`True`, `None`, integers, nested tuples) would be wrong.
"""
function _strip_py_quotes(s::AbstractString)::String
  t = strip(s)
  if length(t) >= 2 &&
     ((startswith(t, '"') && endswith(t, '"')) || (startswith(t, '\'') && endswith(t, '\'')))
    return String(t[nextind(t, firstindex(t)):prevind(t, lastindex(t))])
  end
  return String(t)
end

"""
    parse_choices(choices_str, skipped = String[]) -> NTuple{N, Tuple{String, String}}

Django `choices=((value, label), …)` -> PormG's choices tuple. Both `(...)` and `[...]` containers,
and both bracket styles for the inner pairs.

Rebased on the shared scanner (#342), which fixes an abort of exactly the kind this issue exists to
remove. The old body found pairs with `r"\\(([^()]+)\\)"` and split them on EVERY comma, so an
ordinary human label — `("APPLIED", "Aplicado, com ressalvas")` — produced three fragments and threw
`InvalidMigrationError` from *outside* the field-construction `try`. Nothing caught it, no file was
written, and every model in the file was lost. `split_field_options` does not split inside a string,
so that label now parses correctly.

A genuinely malformed element (a bare value where a pair belongs, or a 3-tuple) is appended to
`skipped` rather than thrown, so the caller can report it and keep going. That also makes
`choices=[["A", "Alpha"]]` — a list of *lists*, valid Django — import correctly, where it used to
yield an empty `choices=()` with no warning.

Quotes are STRIPPED from both halves. They used to be kept as part of the value, so a Django
`("UP", "Upload")` imported as the four-character string `"UP"` — quote marks included. Nothing
downstream broke, because `choices` is Julia-side metadata that never reaches DDL and
`return_just_strings` strips quotes again before validating a default; but it is the wrong value, and
enum resolution produces the clean form, so one generated model would otherwise have carried two
spellings of the same concept.
"""
function parse_choices(choices_str::AbstractString, skipped::Vector{String} = String[])
  inner = _balanced_group(choices_str)
  if inner === nothing
    # `choices=STATUS_CHOICES` — a module-level constant, not a literal. There is nothing to read,
    # and returning an empty tuple in silence is how a field lost its entire enumeration with no
    # trace. The old docs called this out as the one shape to avoid; the code never did.
    push!(skipped, String(strip(choices_str)))
    return ()
  end
  choices = ()
  for element in split_field_options(inner)
    el = String(strip(element))
    isempty(el) && continue
    if !(startswith(el, '(') || startswith(el, '['))
      push!(skipped, el)          # a bare value where a (value, label) pair belongs
      continue
    end
    pair = _balanced_group(el)
    if pair === nothing
      push!(skipped, el)
      continue
    end
    parts = split_field_options(pair)
    if length(parts) != 2
      push!(skipped, el)
      continue
    end
    choices = (choices..., (_strip_py_quotes(parts[1]), _strip_py_quotes(parts[2])))
  end
  return choices
end

"""
    split_field_options(field_options) -> Vector{String}

Split a call's argument text on its top-level commas, preserving quotes for `parse_value`.

Rebased on the shared scanner (#340). The hand-rolled version it replaces tracked `(`/`)` only —
not `[` or `{` — and had no backslash-escape handling, so `choices=[("A","a"), ("B","b")]` split at
the comma *between* the two tuples and produced two unparseable fragments.

A **trailing comma** yields no token (#346). Python allows one on every call, and PEP 8 encourages it
on a wrapped argument list — which is exactly the shape this hit:

```python
actor = models.ForeignKey(
    CustomUser, on_delete=models.SET_NULL, null=True, blank=True,
    related_name='auditoria_acoes', db_constraint=False,
)
```

The whitespace between that last comma and the `)` left the buffer non-empty, so an all-blank token
was pushed. `parse_field_args` reads a token with no `=` as the POSITIONAL argument, so that blank
overwrote the relation target and emitted `Models.ForeignKey("", …)` — a declaration that throws at
`set_models`. Found in a real 434-model project, on two fields, silently. An empty argument does not
exist in Python, so dropping blank tokens is a correction with no legitimate case behind it; every
caller (`_class_bases`, the constraint parsers) was mis-reading them the same way.
"""
function split_field_options(field_options::AbstractString)
  tokens = String[]
  buffer = IOBuffer()
  st = _PyScan()

  i = firstindex(field_options)
  stop = lastindex(field_options)
  while i <= stop
    c = field_options[i]
    j = _py_step!(st, field_options, i)
    if c == ',' && st.depth == 0 && !_in_string(st)
      tok = String(strip(String(take!(buffer))))
      # This half is about the function's CONTRACT, not about a case anyone has hit: `f(a,,b)` is a
      # Python syntax error, so a blank token between two commas has no reachable source. Mutation-
      # tested and confirmed equivalent — deleting it fails nothing. It stays because "never emits a
      # blank token" is a rule every caller can rely on without asking where the blank came from,
      # whereas "drops a blank tail but keeps a blank middle" is a thing they would have to remember.
      # The TAIL guard below is the one with a real, tested case behind it.
      isempty(tok) || push!(tokens, tok)
    else
      # Copy the consumed span verbatim: a token may be several characters wide (`\"\"\"`), and the
      # quote characters themselves must survive for `parse_value` to strip them.
      print(buffer, field_options[i:prevind(field_options, j)])
    end
    i = j
  end

  if position(buffer) > 0
      # `position(buffer) > 0` is not the same question as "is there a token": the tail after a
      # trailing comma is the newline and indentation before the closing paren, which is bytes in
      # the buffer and nothing at all as an argument.
      tail = String(take!(buffer)) |> strip
      isempty(tail) || push!(tokens, String(tail))
  end

  return tokens
end

# ── Django `class Meta:` options (#19, #341) ──────────────────────────────────────────────────────
# `class Meta:` options are not field declarations, so they never reach `fields_dict`. These helpers
# read the isolated Meta block (`PyClass.meta`, #340) into an option table and map the three options
# that carry schema meaning — `db_table`, `constraints` and the legacy `unique_together` — onto
# PormG. Everything else is reported, never dropped in silence.

"""
    _parse_meta_options(meta) -> Dict{String, String}

Read a `class Meta:` block into `option => raw right-hand side`.

One pass over statements the block parser already isolated, rather than an `occursin` over the
class's whole text — which is what `parse_meta_unique_together` used to do, and why the word
`unique_together` appearing inside a docstring attached a constraint the model never declared.

A statement with no top-level `=` (the block's own docstring) is not an option and is skipped.
"""
function _parse_meta_options(meta::Vector{PyStmt})::Dict{String, String}
  out = Dict{String, String}()
  for s in meta
    parts = _split_top_level_assign(s.text)
    parts === nothing && continue
    lhs, rhs = parts
    Base.isidentifier(lhs) || continue
    out[lhs] = rhs
  end
  return out
end

"""
    _meta_string_literal(raw) -> Union{String, Nothing}

The value of a Meta option that must be a **literal** string, or `nothing`.

The literal check is not decoration. `parse_value` returns anything it cannot classify verbatim, so
a computed `db_table = f"{prefix}_matricula"` would otherwise be applied as the *text*
`f"{prefix}_matricula"` — a declaration pointing at a table whose name contains a brace.
"""
function _meta_string_literal(raw::AbstractString)::Union{String, Nothing}
  s = strip(raw)
  isempty(s) && return nothing
  (startswith(s, '"') || startswith(s, '\'')) || return nothing
  v = parse_value(s)
  v isa AbstractString || return nothing
  # A residual quote or a newline means the text was not a well-formed single-line literal, whatever
  # produced it. The case this actually catches is the TRIPLE-quoted one: `parse_value` strips
  # exactly one character per side, so `\"\"\"arq_legado\"\"\"` comes back as `\"\"arq_legado\"\"` —
  # a value that passes a naive starts-with-a-quote test and names a table no database has.
  (occursin('\n', v) || occursin('"', v) || occursin('\'', v)) && return nothing
  return String(v)
end

# Meta options with no PormG equivalent, each with the reason stated once so the warning and the
# generated file's marker say the same thing.
const _META_OPTION_REASONS = Dict{String, String}(
  "ordering"              => "PormG orders per query, not per model",
  "managed"               => "PormG migrations have no per-model opt-out",
  "verbose_name"          => "PormG models carry no display metadata",
  "verbose_name_plural"   => "PormG models carry no display metadata",
  "permissions"           => "PormG has no permission framework",
  "default_permissions"   => "PormG has no permission framework",
  "default_related_name"  => "PormG names reverse accessors per relation, not per model",
  "get_latest_by"         => "PormG orders per query, not per model",
  "base_manager_name"     => "PormG has no manager layer",
  "order_with_respect_to" => "PormG has no ordered-relation support",
  "app_label"             => "PormG resolves models per connection, not per app",
  "required_db_features"  => "PormG has no per-model backend gate",
  "select_on_save"        => "PormG has no per-model save strategy",
)

# Options this importer consumes itself, so they are never reported as dropped.
const _META_OPTIONS_CONSUMED = ("abstract", "proxy", "db_table", "constraints", "unique_together",
                                "indexes", "index_together")

# Django's `UniqueConstraint` arguments that PormG can honour. `violation_error_message` /
# `violation_error_code` only change Django's Python-side error text and have no effect on the
# index, so accepting and ignoring them is faithful.
const _UNIQUE_CONSTRAINT_KWARGS = ("fields", "name", "violation_error_message", "violation_error_code")

# Django's `models.Index` arguments PormG can honour (#347). Deliberately shorter than the
# UniqueConstraint whitelist: `Models.Index` is exactly `(fields, name)` and there is no Django
# `Index` kwarg that is a pure no-op on the emitted index. `db_tablespace=`, `condition=`,
# `include=`, `opclasses=` and `expressions=` all change WHAT gets indexed or where — the same
# reject-rather-than-reinterpret rule `_parse_meta_constraints` documents.
const _INDEX_KWARGS = ("fields", "name")

const _CONSTRAINT_CTOR_RE = r"^(?:[A-Za-z_]\w*\s*\.\s*)*([A-Za-z_]\w*)\s*\("

"""
    _one_line(s, limit = 120) -> String

Collapse whitespace and truncate, for text interpolated into a `# PormG:` marker.

A marker is a `#` comment in generated Julia, so it must be ONE line. Statement text is already
newline-folded by `_py_logical_lines`, but a *value* pulled out of one is not: a field name inside a
triple-quoted string keeps its newline, and a marker that spans two lines breaks the whole module.
Every site that interpolates source text into a marker goes through this — a file that will not
parse is a catastrophic outcome for a guard this cheap.
"""
_one_line(s::AbstractString, limit::Int = 120)::String =
  String(first(strip(replace(s, r"\s+" => " ")), limit))

function _drop_constraint!(markers::Vector{String}, class_label::AbstractString,
                           element::AbstractString, reason::AbstractString)
  short = _one_line(element)
  reason = _one_line(reason, 200)
  @warn "import: Meta.constraints entry dropped" class=class_label reason=reason constraint=short
  push!(markers, "# PormG: a constraint on '$(class_label)' was dropped — $(reason): $(short)")
  return markers
end

# The `Meta.indexes` sibling of `_drop_constraint!` (#347). Separate wording, because "a constraint
# was dropped" pointing at an index sends the reader to the wrong Meta option.
function _drop_index_decl!(markers::Vector{String}, class_label::AbstractString,
                           element::AbstractString, reason::AbstractString)
  short = _one_line(element)
  reason = _one_line(reason, 200)
  @warn "import: Meta.indexes entry dropped" class=class_label reason=reason index=short
  push!(markers, "# PormG: an index on '$(class_label)' was dropped — $(reason): $(short)")
  return markers
end

"""
    _claim_index_name!(taken, name, markers, class_label, kind, cols) -> Union{String, Nothing}

Reserve an explicit index name for one generated file, returning it — or `nothing` when another
model in the same import already claimed it, so PormG derives one per table instead (#347).

An index name is **unique per database** on SQLite and per schema on PostgreSQL, and both DDL
emitters render `CREATE [UNIQUE] INDEX IF NOT EXISTS`. So a name reused across two models does not
fail: the second `CREATE` is a **silent no-op** and that table simply never gets its index. Since
composite indexes are not diffed on an existing table, `makemigrations` never notices either.

Django makes this easy to hit without writing it. An abstract base's *whole* `Meta` is installed on
every child that declares none of its own (`_effective_meta`), so one
`Meta.indexes = [Index(fields=…, name="base_x")]` on a base with three children emits that same name
three times. Django rejects it at system-check time (`models.E030`); this importer has no check
framework, so the guard lives here.

Dropping the NAME rather than the declaration is the deliberate direction: every child keeps its
index, PormG derives `<table>_<cols>_idx` / `_uniq`, which is unique per table by construction, and
the report says which name was surrendered. It is what Django's own `%(app_label)s_%(class)s_…`
name placeholders exist to achieve.

Only EXPLICIT names are registered. A derived name already carries its table, so it cannot collide
with another model's derived name.
"""
function _claim_index_name!(taken::Set{String}, name::Union{String, Nothing},
                            markers::Vector{String}, class_label::AbstractString,
                            kind::AbstractString, cols::Vector{String})::Union{String, Nothing}
  name === nothing && return nothing
  if name in taken
    # Says "another declaration", not "another model": the registry is also consulted for two
    # declarations on the SAME class that share a name, and blaming a different model there would
    # send the reader to the wrong `models.py`.
    @warn "import: index name is already claimed in this import; importing with a derived name" name=name class=class_label kind=kind
    push!(markers, "# PormG: the $(kind) over ($(join(cols, ", "))) on '$(class_label)' kept its " *
                   "columns but LOST its name '$(_one_line(name))' — another declaration in this " *
                   "import already claims that name, and an index name is unique per database. " *
                   "PormG derives one from the table and columns instead.")
    return nothing
  end
  push!(taken, name)
  return name
end

"""
    _parse_meta_constraints(raw, fields_dict, class_label, markers) -> Vector{UniqueConstraint}

Django `Meta.constraints = [...]` → PormG composite uniqueness.

Argument acceptance is a **whitelist**, and that is the point of this function rather than an
incidental detail. `Models.UniqueConstraint` is exactly `(fields, name)`, so a Django
`UniqueConstraint(fields=…, condition=Q(active=True))` — a *partial* unique index — imported as an
unconditional one would start silently rejecting rows the live database accepts. The same holds for
`expressions=`, `nulls_distinct=` and `deferrable=`. Rejecting anything outside the whitelist means
a Django option this importer has never met is refused rather than quietly reinterpreted, which is
the only direction that fails safe.

Each entry is judged on its own: one rejected constraint never takes its siblings with it.
"""
function _parse_meta_constraints(raw::AbstractString, fields_dict::Dict{Symbol, Any},
                                 class_label::AbstractString, markers::Vector{String})
  out = Models.UniqueConstraint[]
  inner = _balanced_group(raw)
  if inner === nothing
    @warn "import: Meta.constraints is not a list or tuple literal; dropped" class=class_label
    push!(markers, "# PormG: Meta.constraints on '$(class_label)' could not be read — dropped.")
    return out
  end

  for element in split_field_options(inner)
    el = String(strip(element))
    isempty(el) && continue

    m = match(_CONSTRAINT_CTOR_RE, el)
    ctor = m === nothing ? "" : String(m.captures[1])
    if ctor != "UniqueConstraint"
      _drop_constraint!(markers, class_label, el,
        isempty(ctor) ? "it is not a constraint constructor" : "$(ctor) has no PormG equivalent")
      continue
    end

    args = _balanced_group(el)
    if args === nothing
      _drop_constraint!(markers, class_label, el, "its argument list could not be read")
      continue
    end

    kwargs = Dict{String, String}()
    reason::Union{String, Nothing} = nothing
    for tok in split_field_options(args)
      t = String(strip(tok))
      isempty(t) && continue
      kv = _split_top_level_assign(t)
      if kv === nothing
        # `UniqueConstraint(Lower("name"), name="x")` — an EXPRESSION constraint. Django indexes a
        # function of the column; PormG would index the column itself, which is a different index.
        reason = "it takes a positional expression (`$(t)`)"
        break
      end
      k, v = kv
      if !(k in _UNIQUE_CONSTRAINT_KWARGS)
        reason = "`$(k)=` changes what the index means and PormG cannot express it"
        break
      end
      kwargs[k] = v
    end
    if reason !== nothing
      _drop_constraint!(markers, class_label, el, reason)
      continue
    end

    if !haskey(kwargs, "fields")
      _drop_constraint!(markers, class_label, el, "it declares no `fields=`")
      continue
    end
    fields_inner = _balanced_group(kwargs["fields"])
    if fields_inner === nothing
      _drop_constraint!(markers, class_label, el, "its `fields=` is not a list or tuple literal")
      continue
    end

    declared = _clean_constraint_field_names(split_field_options(fields_inner))
    if isempty(declared)
      _drop_constraint!(markers, class_label, el, "its `fields=` is empty")
      continue
    end
    resolved = String[]
    unknown = nothing
    for name in declared
      r = _resolve_django_constraint_field(name, fields_dict)
      if r === nothing
        unknown = name
        break
      end
      push!(resolved, r)
    end
    if unknown !== nothing
      _drop_constraint!(markers, class_label, el, "field '$(unknown)' matches no imported field")
      continue
    end

    # Django requires `name=`; a computed one (an f-string, a call) is not a literal we can carry,
    # so the constraint is imported with an auto-derived name rather than dropped — the index is
    # what matters, its identifier is not.
    cname = haskey(kwargs, "name") ? _meta_string_literal(kwargs["name"]) : nothing
    if haskey(kwargs, "name") && cname === nothing
      @warn "import: UniqueConstraint name is not a string literal; importing with a derived name" class=class_label value=kwargs["name"]
    end
    try
      push!(out, Models.UniqueConstraint(fields = resolved, name = cname))
    catch e
      # A duplicate-field or empty-name rejection from the constructor: report THIS constraint and
      # keep the rest, rather than losing every constraint on the model to one bad entry.
      _drop_constraint!(markers, class_label, el, replace(sprint(showerror, e), "\n" => " "))
    end
  end
  return out
end

"""
    _resolve_index_group(declared, fields_dict, class_label, markers, element)
        -> Union{Vector{String}, Nothing}

Resolve one Django index's declared field names to imported PormG field names, or `nothing` when the
index cannot be imported (the caller drops it and moves on). Shared by `Meta.indexes` and
`Meta.index_together`, which differ only in how the names are spelled out.

Two rejections beyond "the field does not exist":

  * **A `-` prefix is descending order.** `Index(fields=["-year"])` is not the index over `year`;
    importing it as one would silently give the database a differently-ordered index and quietly
    fail to serve the query the developer wrote it for. Ordered index columns are #29.
  * **`Models.Index` needs two columns.** Django's one-field `Meta.indexes` entry is exactly
    `db_index = True`, so the caller translates it rather than dropping it — this function reports
    the arity back by returning the resolved vector and letting the caller branch on its length.
"""
function _resolve_index_group(declared::Vector{String}, fields_dict::Dict{Symbol, Any},
                              class_label::AbstractString, markers::Vector{String},
                              element::AbstractString)::Union{Vector{String}, Nothing}
  if isempty(declared)
    _drop_index_decl!(markers, class_label, element, "it names no fields")
    return nothing
  end
  resolved = String[]
  for name in declared
    if startswith(name, "-")
      _drop_index_decl!(markers, class_label, element,
        "'$(_one_line(name))' is a DESCENDING column and PormG indexes have no column order")
      return nothing
    end
    r = _resolve_django_constraint_field(name, fields_dict)
    if r === nothing
      _drop_index_decl!(markers, class_label, element,
        "field '$(_one_line(name))' matches no imported field")
      return nothing
    end
    push!(resolved, r)
  end
  return resolved
end

"""
    _parse_meta_indexes(raw, fields_dict, class_label, markers) -> (Vector{Index}, Vector{String})

Django `Meta.indexes = [...]` → PormG composite indexes (#347).

Returns **two** collections, because Django's one option covers two PormG spellings:

 1. the multi-column entries, as `Models.Index` objects;
 2. the field names of the *single*-column entries, which the caller marks `db_index = true` — an
    exact translation, not a degradation. `Models.Index` rejects one field on purpose (a one-column
    `CREATE INDEX` reads back as `db_index`, so declaring it as an `Index` would churn), and Django's
    `Index(fields=["x"])` and `x = models.CharField(db_index=True)` emit the same DDL anyway.

Argument acceptance is a **whitelist** (`_INDEX_KWARGS`), for the reason spelled out in
`_parse_meta_constraints`: an unrecognised Django kwarg is refused rather than reinterpreted. The
constructor is checked too — `GinIndex`, `BrinIndex` and friends (`django.contrib.postgres.indexes`)
are reported and skipped, since PormG emits only a default b-tree (#29).

Each entry is judged on its own: one rejected index never takes its siblings with it.
"""
function _parse_meta_indexes(raw::AbstractString, fields_dict::Dict{Symbol, Any},
                             class_label::AbstractString, markers::Vector{String})
  out = Models.Index[]
  single = String[]
  inner = _balanced_group(raw)
  if inner === nothing
    @warn "import: Meta.indexes is not a list or tuple literal; dropped" class=class_label value=_one_line(raw)
    push!(markers, "# PormG: Meta.indexes on '$(class_label)' could not be read — dropped.")
    return out, single
  end

  for element in split_field_options(inner)
    el = String(strip(element))
    isempty(el) && continue

    m = match(_CONSTRAINT_CTOR_RE, el)
    ctor = m === nothing ? "" : String(m.captures[1])
    if ctor != "Index"
      _drop_index_decl!(markers, class_label, el,
        isempty(ctor) ? "it is not an index constructor" : "$(ctor) has no PormG equivalent")
      continue
    end

    args = _balanced_group(el)
    if args === nothing
      _drop_index_decl!(markers, class_label, el, "its argument list could not be read")
      continue
    end

    kwargs = Dict{String, String}()
    reason::Union{String, Nothing} = nothing
    for tok in split_field_options(args)
      t = String(strip(tok))
      isempty(t) && continue
      kv = _split_top_level_assign(t)
      if kv === nothing
        # `Index(Lower("name"), name="x")` — a FUNCTIONAL index. PormG would index the column
        # itself, which is a different index.
        reason = "it takes a positional expression (`$(t)`)"
        break
      end
      k, v = kv
      if !(k in _INDEX_KWARGS)
        reason = "`$(k)=` changes what the index means and PormG cannot express it"
        break
      end
      kwargs[k] = v
    end
    if reason !== nothing
      _drop_index_decl!(markers, class_label, el, reason)
      continue
    end

    if !haskey(kwargs, "fields")
      _drop_index_decl!(markers, class_label, el, "it declares no `fields=`")
      continue
    end
    fields_inner = _balanced_group(kwargs["fields"])
    if fields_inner === nothing
      _drop_index_decl!(markers, class_label, el, "its `fields=` is not a list or tuple literal")
      continue
    end

    resolved = _resolve_index_group(
      _clean_constraint_field_names(split_field_options(fields_inner)),
      fields_dict, class_label, markers, el)
    resolved === nothing && continue

    if length(resolved) == 1
      # Django's single-field index IS `db_index=True`; translate rather than drop (see the
      # docstring). No marker: nothing was lost.
      push!(single, resolved[1])
      continue
    end

    # Django auto-derives a name when `name=` is absent, and a computed one is not a literal we can
    # carry — either way PormG derives `<table>_<cols>_idx`, so this is not a reason to drop.
    iname = haskey(kwargs, "name") ? _meta_string_literal(kwargs["name"]) : nothing
    if haskey(kwargs, "name") && iname === nothing
      @warn "import: Index name is not a string literal; importing with a derived name" class=class_label value=kwargs["name"]
    end
    try
      push!(out, Models.Index(fields = resolved, name = iname))
    catch e
      # A duplicate-field or empty-name rejection from the constructor: report THIS index and keep
      # the rest, rather than losing every index on the model to one bad entry.
      _drop_index_decl!(markers, class_label, el, replace(sprint(showerror, e), "\n" => " "))
    end
  end
  return out, single
end

"""
    _parse_meta_index_together(raw, fields_dict, class_label, markers) -> (Vector{Index}, Vector{String})

Django's legacy `Meta.index_together = (('a','b'), …)` → the same two collections
[`_parse_meta_indexes`](@ref) returns.

`index_together` is `unique_together`'s non-unique twin — identical literal shape, no names, no
options — so it reuses `_parse_unique_together_groups` outright rather than re-deriving the
flat-vs-grouped distinction a second time.
"""
function _parse_meta_index_together(raw::AbstractString, fields_dict::Dict{Symbol, Any},
                                    class_label::AbstractString, markers::Vector{String})
  out = Models.Index[]
  single = String[]
  inner = _balanced_group(raw)
  if inner === nothing
    @warn "import: Meta.index_together is not a tuple or list literal; dropped" class=class_label value=_one_line(raw)
    push!(markers, "# PormG: Meta.index_together on '$(class_label)' is not a tuple or list " *
                   "literal — dropped.")
    return out, single
  end
  skipped = String[]
  for group in _parse_unique_together_groups(inner, skipped)
    el = "index_together ($(join(group, ", ")))"
    resolved = _resolve_index_group(group, fields_dict, class_label, markers, el)
    resolved === nothing && continue
    if length(resolved) == 1
      push!(single, resolved[1])
      continue
    end
    try
      push!(out, Models.Index(fields = resolved))
    catch e
      # The same per-entry guard `_parse_meta_indexes` carries: report THIS group and keep the rest.
      # `('lap','lap')` is the obvious case, but the realistic one is a group naming BOTH spellings of
      # one foreign key — `('race', 'race_id')` — which `_resolve_django_constraint_field` collapses
      # to the same imported column. Unwrapped, either takes the whole import down.
      _drop_index_decl!(markers, class_label, el, replace(sprint(showerror, e), "\n" => " "))
    end
  end
  for s in skipped
    @warn "import: index_together entry is not a field group; dropped" class=class_label entry=s
    push!(markers, "# PormG: an index_together entry on '$(class_label)' is not a field group — " *
                   "dropped: $(_one_line(s))")
  end
  return out, single
end

# Return the text inside the FIRST balanced (...) or [...] group in `s` (Django allows tuples
# or lists), or nothing. Quote-aware so a paren inside a string literal is ignored.
function _balanced_group(s::AbstractString)::Union{String, Nothing}
  st = _PyScan()
  buf = IOBuffer()
  opened = false

  i = firstindex(s)
  stop = lastindex(s)
  while i <= stop
    c = s[i]
    was_in_string = _in_string(st)
    j = _py_step!(st, s, i)

    if !opened
      # The opening bracket is the first `(` or `[` seen outside a string.
      if !was_in_string && (c == '(' || c == '[')
        opened = true
      end
    elseif !was_in_string && st.depth == 0 && (c == ')' || c == ']' || c == '}')
      return String(take!(buf))
    else
      print(buf, s[i:prevind(s, j)])
    end
    i = j
  end
  return nothing
end

# Strip surrounding quotes/whitespace off each token, dropping empties (e.g. trailing-comma
# artifacts). Both delimiters are handled: since #340 the reader no longer rewrites `'` to `"`,
# so a single-quoted Django source arrives with its own quotes intact.
function _clean_constraint_field_names(tokens)::Vector{String}
  out = String[]
  for t in tokens
    n = strip(replace(String(t), "\"" => "", "'" => ""))
    isempty(n) || push!(out, String(n))
  end
  return out
end

# Split the inner text of a `unique_together` value into column groups. Handles both a flat
# single group `('a','b')` and a tuple/list of groups `(('a','b'),('c','d'))`.
#
# `skipped` collects any token in a grouped list that is not itself a group — Django's
# `(("a","b"), "c")` is malformed, and a bare `"c"` used to be `continue`d without a word.
function _parse_unique_together_groups(inner::AbstractString,
                                       skipped::Vector{String} = String[])::Vector{Vector{String}}
  tokens = split_field_options(inner)
  isempty(tokens) && return Vector{String}[]
  if any(t -> (st = strip(t); startswith(st, "(") || startswith(st, "[")), tokens)
    groups = Vector{String}[]
    for t in tokens
      st = strip(t)
      if !(startswith(st, "(") || startswith(st, "["))
        isempty(st) || push!(skipped, String(st))
        continue
      end
      innerg = _balanced_group(st)
      if innerg === nothing
        push!(skipped, String(st))
        continue
      end
      names = _clean_constraint_field_names(split_field_options(innerg))
      isempty(names) ? push!(skipped, String(st)) : push!(groups, names)
    end
    return groups
  else
    names = _clean_constraint_field_names(tokens)
    return isempty(names) ? Vector{String}[] : [names]
  end
end

# Map a Django field name to the imported PormG field name: FK/OneToOne fields gain an `_id`
# suffix at import (see process_class_fields!), so `item` in Django is `item_id` in PormG.
function _resolve_django_constraint_field(name::AbstractString, fields_dict::Dict{Symbol, Any})::Union{String, Nothing}
  haskey(fields_dict, Symbol(name)) && return String(name)
  haskey(fields_dict, Symbol("$(name)_id")) && return "$(name)_id"
  return nothing
end

# Build PormG UniqueConstraints from a class's `Meta.unique_together`, resolving each declared
# Django field to its imported PormG field name. Unresolvable groups are warned and skipped
# (lenient, matching the importer's philosophy) rather than aborting the whole import.
#
# `raw` is the option's right-hand side, taken straight from `_parse_meta_options` (#341). It used
# to be the Meta block's joined text, matched with `\bunique_together\s*=\s*(.*)`s — a regex whose
# `\b` anchor was there only because there was no real parse to lean on.
function parse_meta_unique_together(raw::AbstractString, fields_dict::Dict{Symbol, Any},
                                    class_label::AbstractString,
                                    markers::Vector{String} = String[])
  inner = _balanced_group(raw)
  if inner === nothing
    # `unique_together = CHAVE_EXTERNA` — a name, not a literal. This used to return an empty vector
    # and the composite key vanished without a word, while the SAME shape on `Meta.constraints` was
    # reported. Same loss, same report.
    @warn "import: Meta.unique_together is not a tuple or list literal; dropped" class=class_label value=_one_line(raw)
    push!(markers, "# PormG: Meta.unique_together on '$(class_label)' is not a tuple or list " *
                   "literal — dropped.")
    return Models.UniqueConstraint[]
  end
  constraints = Models.UniqueConstraint[]
  skipped = String[]
  for group in _parse_unique_together_groups(inner, skipped)
    resolved = String[]
    ok = true
    for name in group
      r = _resolve_django_constraint_field(name, fields_dict)
      if r === nothing
        @warn "import: unique_together field matches no imported field; skipping constraint" field=name class=class_label
        # Whitespace collapsed before interpolation, like every other marker: a field name can
        # carry a real newline (a triple-quoted string survives `_py_logical_lines` intact), and a
        # marker that spans two lines breaks the generated module outright. Verified: without this,
        # `unique_together = ("""nao\nexiste""", "a")` produces a file that will not parse.
        push!(markers, "# PormG: a unique_together group on '$(class_label)' was dropped — field " *
                       "'$(_one_line(name))' matches no imported field: " *
                       "($(_one_line(join(group, ", "))))")
        ok = false
        break
      end
      push!(resolved, r)
    end
    ok && !isempty(resolved) && push!(constraints, Models.UniqueConstraint(fields = resolved))
  end
  for s in skipped
    @warn "import: unique_together entry is not a field group; dropped" class=class_label entry=s
    push!(markers, "# PormG: a unique_together entry on '$(class_label)' is not a field group — " *
                   "dropped: $(_one_line(s))")
  end
  return constraints
end
