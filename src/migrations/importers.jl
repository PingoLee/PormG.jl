# ==============================================================================
# IMPORTER UTILITIES
# High-level functions to import existing database schemas or Django models 
# into PormG model definitions.
# ==============================================================================

# ---
# Dialect Importers (SQLite / Postgres)
# ---

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
  Instructions::Vector{Any} = []
  for model in models_array
    push!(Instructions, Models.Model_to_str(model, settings; name_is_physical_table=true))
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
  Instructions::Vector{Any} = []
  for model in models_array
      push!(Instructions, Models.Model_to_str(model, settings; name_is_physical_table=true))
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
  Instructions::Vector{Any} = []
  for model in models_array
      push!(Instructions, Models.Model_to_str(model, settings; name_is_physical_table=true))
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
  import_models_from_django(model_py_string::String; db::String = DB_PATH, force_replace::Bool = false, ignore_table::Vector{String} = postgres_ignore_table, file::String = "automatic_models.jl", output_path::Union{Nothing, String} = nothing, django_prefix::Union{Nothing, String, Missing} = missing, autofields_ignore::Vector{String} = ["Manager"], parameters_ignore::Vector{String} = ["help_text"])

Imports Django models from a given `model.py` file content string and generates corresponding Julia models.

# Arguments
- `model_py_string::String`: The content of the `model.py` file as a string; user django_to_string(path) to read the file; or insert the file path.
- `db::String`: The configuration key used to resolve settings (usually the db folder path). The generated file is written to that configuration's `db_def_folder` unless `output_path` overrides it, and the table-name prefix comes from that configuration's `django_prefix` unless `django_prefix` overrides it. Defaults to `DB_PATH`.
- `force_replace::Bool`: If `true`, forces replacement of the existing models file. Defaults to `false`.
- `ignore_table::Vector{String}`: Tables to ignore during the import process. Defaults to `postgres_ignore_table`.
- `file::String`: The name of the file to save the generated models. Defaults to `"automatic_models.jl"`.
- `output_path::Union{Nothing, String}`: Directory to write the generated file into, overriding the resolved config's `db_def_folder`. Use this to stage a *foreign* Django app's models next to their copied `model.py` (e.g. `"db_gal"`) while still resolving `db` for its Settings. Defaults to `nothing` (use `db_def_folder`).
- `django_prefix::Union{Nothing, String, Missing}`: Overrides the generated table-name prefix. `missing` inherits the resolved config's `django_prefix`; `nothing` emits unprefixed table names; a `String` (e.g. `"estoque"`) forces `<prefix>_<table>`. Use this when the imported app uses a different Django `app_label` than the `db` config's. Defaults to `missing` (inherit).
- `autofields_ignore::Vector{String}`: Fields to ignore automatically. Defaults to `["Manager"]`.
- `parameters_ignore::Vector{String}`: Parameters to ignore during field processing. Defaults to `["help_text"]`.

# Description
This function checks if the specified models file already exists and creates it if necessary. It parses the provided `model.py` content string to extract Django model classes and their fields. For each class, it processes the fields, adds a primary key if none exists, and generates the corresponding Julia model code. The generated models are then saved to the specified file.

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
    ignore_table::Vector{String} = postgres_ignore_table,
    file::String = "automatic_models.jl",
    output_path::Union{Nothing, String} = nothing,
    django_prefix::Union{Nothing, String, Missing} = missing,
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
  )

  settings::Union{Nothing, PormGSettings} = nothing
  try
    settings = Configuration.get_settings(db)
  catch e
    @error("The database $(db) does not exists in the config")
    return
  end

  # `db` is the config key used to resolve Settings; by default the output directory
  # and table-name prefix come from that config (matching import_models_from_postgres).
  # When importing a *foreign* Django app staged elsewhere, `output_path`/`django_prefix`
  # override those without mutating the shared config — a throwaway render-only Settings
  # (no DB connection) carries the overrides. `django_prefix === missing` inherits the
  # config's prefix; `nothing` emits unprefixed tables; a String forces that prefix.
  render_settings = if output_path === nothing && django_prefix === missing
    settings
  else
    Configuration.Settings(
      db_def_folder = output_path === nothing ? settings.db_def_folder : output_path,
      django_prefix = django_prefix === missing ? settings.django_prefix : django_prefix,
    )
  end
  model_path = render_settings.db_def_folder
  model_output_path = joinpath(model_path, file)

  # Check if the generated models file already exists.
  if isfile(model_output_path) && !force_replace
      @warn(
          "The file '$(model_output_path)' already exists, use force_replace=true to replace it"
      )
      return
  elseif !ispath(model_path)
      mkpath(model_path)
  end

  # check if model_py_string is a path to file and if yes, call django_to_string
  if !occursin('\n', model_py_string) && isfile(model_py_string)
    model_py_string = django_to_string(model_py_string)
  end

  # Recover and classify every module-level class (#340 parses them, #341 resolves their bases).
  # The parser itself is the validity test: the regex that used to guard this required the class
  # header to sit on ONE physical line, so once the parser learned to read a wrapped header it was
  # rejecting files it could handle.
  graph = _django_class_graph(model_py_string)

  # check if model_py_string is a model.py file content and not a path
  if !any(c -> _is_emitted(graph.info[c.name]), graph.classes)
    @warn("The string does not contain a valid model.py content")
    return
  end

  Instructions = Vector{Any}()
  # A class name defined twice at module level is pathological Python, but it used to emit TWO
  # `X = Models.Model(...)` assignments into one module: the file loads, the second silently wins,
  # and the first model is gone. `graph.index` already keeps the first definition for base
  # resolution; this keeps emission agreeing with it.
  seen_names = Set{String}()

  for class in graph.classes
    class_name = class.name
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
        @warn "import: class name is declared more than once at module level; only the first declaration is used" class=class_name
        push!(Instructions, "# PormG: '$(class_name)' is declared more than once in this " *
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
    if ci.kind === :not_a_model || ci.kind === :abstract
      continue                       # a QuerySet/Manager/Form/enum/helper, or a base — silent
    end

    if ci.proxy
      @warn "import: proxy model shares its parent's table; not imported" class=class_name
      push!(Instructions, "# PormG: model '$(class_name)' is a Django proxy (Meta.proxy = True) — " *
                          "not imported, because it has no table of its own.")
      continue
    elseif ci.kind === :mti
      @warn "import: Django multi-table inheritance has no PormG equivalent; model not imported" class=class_name parent=ci.mti_parent
      push!(Instructions, "# PormG: model '$(class_name)' inherits the concrete model " *
                          "'$(ci.mti_parent)' (Django multi-table inheritance) — not imported. " *
                          "Django keys the child table on a '$(lowercase(String(ci.mti_parent)))_ptr_id' " *
                          "one-to-one to the parent, which PormG cannot express.")
      continue
    end

    # `# PormG:` lines to emit directly above this model's declaration.
    markers = String[]

    # An abstract base declared elsewhere (`from core.models import TimeStampedModel`) cannot be
    # merged, so the model is imported WITHOUT its columns. Skipping instead would re-create the
    # vanishing-model bug this issue exists to close; importing with a loud marker keeps the table
    # and names exactly what is absent. Importing the defining app alongside this one (#346)
    # resolves it.
    # Walked over the ABSTRACT ANCESTORS too, not just this class's own base list: an abstract base
    # with an unresolvable base of its own loses columns identically, and it emits nothing to hang a
    # marker on, so its gap would otherwise reach the file unannounced.
    unresolved_bases = _inherited_unresolved(graph, class)
    if !isempty(unresolved_bases)
      for b in unresolved_bases
        @warn "import: base class is not defined in this file; any fields it declares are missing from the imported model" class=class_name base=b
      end
      push!(markers, "# PormG: model '$(class_name)' inherits " *
                     join(("'$(b)'" for b in unresolved_bases), ", ") *
                     ", not defined in this file — any fields declared there are MISSING below. " *
                     "Add them by hand, or import the app that defines them together with this one.")
    end

    # Django would hand this model its abstract base's `db_table`, giving every child of that base
    # the same physical table. Refused deliberately (see `_effective_meta`) — and reported, because
    # a silently different table name is the defect this issue is about.
    db_table_base = _abstract_db_table_base(graph, class)
    if db_table_base !== nothing
      @warn "import: db_table on an abstract base is not inherited; the child keeps its own derived table name" class=class_name base=db_table_base
      push!(markers, "# PormG: abstract base '$(db_table_base)' declares Meta.db_table — NOT " *
                     "inherited by '$(class_name)', because that would point every child of " *
                     "'$(db_table_base)' at one table. Declare db_table on this model if it really " *
                     "shares that table.")
    end

    # Abstract bases merge by CONCATENATION, ancestors first: process_class_fields! writes into a
    # Dict, so the last write wins and the child overrides its parents for free.
    class_content = vcat(_inherited_statements(graph, class), class.body)

    # Initialize fields_dict
    fields_dict = Dict{Symbol, Any}()
    has_primary_key = Ref(false)  # Flag to check if a primary key exists

    # Process fields separately
    process_class_fields!(fields_dict, class_content, class_name, _inherits_auth_user(graph, class), has_primary_key, autofields_ignore, parameters_ignore, markers)

    # Insert IDField if no primary key is defined
    if !has_primary_key[]
        # println("No primary key found in class '$class_name'. Adding an IDField named 'id'.")
        fields_dict[:id] = Models.IDField()
    end

    # Collect all create instructions
    if !isempty(fields_dict)
        model = Models.Model(class_name, fields_dict)
        meta_options = _effective_meta(graph, class)

        # `Meta.db_table` is ABSOLUTE in Django — it overrides the derived name, and it overrides a
        # configured `django_prefix` too. `Model_to_str` renders both: the positional slot stays the
        # logical handle, `db_table=` carries the physical table (#59).
        if haskey(meta_options, "db_table")
          dt = _meta_string_literal(meta_options["db_table"])
          if dt === nothing || isempty(dt)
            @warn "import: Meta.db_table is not a non-empty string literal; ignored" class=class_name value=meta_options["db_table"]
            push!(markers, "# PormG: Meta.db_table on '$(class_name)' is not a string literal — " *
                           "ignored; the table name below is derived from the class name.")
          else
            Models._apply_db_table!(model, dt)
          end
        end

        # Composite uniqueness from BOTH Django spellings (#19, #341). Each constraint is validated
        # on its own so one bad entry cannot take the others with it — which is what the coarse
        # try/catch around the whole apply used to do.
        constraints = Models.UniqueConstraint[]
        if haskey(meta_options, "unique_together")
          try
            append!(constraints, parse_meta_unique_together(meta_options["unique_together"], fields_dict, class_name, markers))
          catch e
            @warn "import: could not parse unique_together; skipping" class=class_name exception=e
            push!(markers, "# PormG: Meta.unique_together on '$(class_name)' could not be read — dropped.")
          end
        end
        if haskey(meta_options, "constraints")
          append!(constraints, _parse_meta_constraints(meta_options["constraints"], fields_dict, class_name, markers))
        end
        for c in constraints
          try
            Models._apply_unique_constraints!(model, vcat(_existing_unique_constraints(model), [c]))
          catch e
            @warn "import: could not apply a unique constraint; skipping it" class=class_name fields=c.fields exception=e
            push!(markers, "# PormG: a constraint over ($(join(c.fields, ", "))) on '$(class_name)' " *
                           "was dropped — $(replace(sprint(showerror, e), "\n" => " "))")
          end
        end

        # Every remaining Meta option is REPORTED. An unrecognised key is a typo or a Django option
        # this importer has not met, and neither is safe to pass over quietly. Sorted so the
        # generated file is byte-stable across runs.
        for k in sort(collect(keys(meta_options)))
          k in _META_OPTIONS_CONSUMED && continue
          reason = get(_META_OPTION_REASONS, k, nothing)
          if reason === nothing
            @warn "import: unrecognised Meta option; dropped" option=k class=class_name
            push!(markers, "# PormG: Meta.$(k) on '$(class_name)' is not recognised — dropped.")
          else
            @warn "import: Meta option has no PormG equivalent; dropped" option=k class=class_name reason=reason
            push!(markers, "# PormG: Meta.$(k) on '$(class_name)' — dropped: $(reason).")
          end
        end

        rendered = Models.Model_to_str(model, render_settings)
        push!(Instructions, isempty(markers) ? rendered : join(markers, "\n") * "\n" * rendered)
    end

  end

  generate_models_from_db(file, Instructions, render_settings, path=model_path)
end

# The UniqueConstraints already stashed on a model by `_apply_unique_constraints!`. Applying
# constraints one at a time (so a rejection is per-constraint) means each call must carry the ones
# that already passed — the setter REPLACES the cache entry rather than appending to it.
function _existing_unique_constraints(model)::Vector{Models.UniqueConstraint}
  haskey(model.cache, "unique_constraints") || return Models.UniqueConstraint[]
  return get(model.cache["unique_constraints"], "constraints", Models.UniqueConstraint[])
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

`unresolved` holds bases that name nothing in this file (`from core.models import TimeStampedModel`).
The class is still imported — dropping it would re-create the vanishing-model bug — but it carries a
marker saying whose fields are missing. Importing several apps together (#346) resolves these.
"""
struct _ClassInfo
  kind::Symbol
  bases::Vector{String}
  parents::Vector{String}              # in-file ABSTRACT bases whose fields this class inherits
  unresolved::Vector{String}           # bases this file does not define
  mti_parent::Union{String, Nothing}
  meta::Dict{String, String}
  is_auth_user::Bool
  proxy::Bool
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

function _classify_class!(info::Dict{String, _ClassInfo}, index::Dict{String, PyClass},
                          visiting::Set{String}, cls::PyClass)::_ClassInfo
  haskey(info, cls.name) && return info[cls.name]

  meta = _parse_meta_options(cls.meta)
  bases = _class_bases(cls)
  abstract = _meta_is_true(get(meta, "abstract", ""))
  proxy = _meta_is_true(get(meta, "proxy", ""))
  is_auth = any(b -> b in _AUTH_USER_BASES, bases)

  # An inheritance CYCLE is malformed Python. Refuse the class rather than recurse forever; not
  # memoized, because the in-progress outer call owns the entry for this name.
  if cls.name in visiting
    return _ClassInfo(:not_a_model, bases, String[], String[], nothing, meta, is_auth, proxy)
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
  # `haskey(index, b)` is tested BEFORE `_NON_MODEL_BASES`, and that ordering is the whole fix for a
  # real silent loss: `Manager`, `Choices` and `Enum` are perfectly good model names — a Manager in
  # an HR schema is a person — and dismissing such a base by NAME made the class invisible as an
  # ancestor. Its children then resolved no parent, fell through to `non_model`, and were dropped
  # without a word, taking the base's columns with them. A definition in this file always outranks
  # a name on a list.
  push!(visiting, cls.name)
  try
    for b in bases
      (b in _MODEL_ROOT_BASES || b in _AUTH_USER_BASES) && continue
      if haskey(index, b)
        pk = _classify_class!(info, index, visiting, index[b]).kind
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
        # A known non-model NAME that this file does not define. Already reflected in `non_model`;
        # it is not an unresolved ancestor, so it must not be marked as one.
        continue
      else
        push!(unresolved, b)
      end
    end
  finally
    delete!(visiting, cls.name)
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

  ci = _ClassInfo(kind, bases, parents, unresolved, mti_parent, meta, is_auth, proxy)
  info[cls.name] = ci
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
  classes = _py_classes(_py_logical_lines(model_py_string))
  index = Dict{String, PyClass}()
  for c in classes
    # First definition wins; a name redefined at module level is pathological Python.
    haskey(index, c.name) || (index[c.name] = c)
  end
  info = Dict{String, _ClassInfo}()
  visiting = Set{String}()
  for c in classes
    _classify_class!(info, index, visiting, c)
  end
  return (classes = classes, index = index, info = info)
end

"""
    _inherited_statements(graph, cls) -> Vector{PyStmt}

The field statements `cls` inherits from its abstract bases, ancestors first. Concatenating these
before the class's own body is the whole merge: `process_class_fields!` writes into a `Dict`, so
**last write wins** gives child-overrides-parent for free.

Bases are walked in **reverse** declaration order, because Python resolves `class C(A, B)` left to
right — A must win, so A's statements have to be written last.
"""
function _inherited_statements(graph, cls::PyClass)::Vector{PyStmt}
  out = PyStmt[]
  seen = Set{String}()
  function walk(c::PyClass)
    ci = get(graph.info, c.name, nothing)
    ci === nothing && return
    for b in Iterators.reverse(ci.parents)
      b in seen && continue
      push!(seen, b)
      p = get(graph.index, b, nothing)
      p === nothing && continue
      walk(p)
      append!(out, p.body)
    end
    return
  end
  walk(cls)
  return out
end

# Django's `AbstractUser` columns reach a class through an abstract base too:
# `class BaseUser(AbstractUser): class Meta: abstract = True` then `class User(BaseUser)`.
function _inherits_auth_user(graph, cls::PyClass)::Bool
  ci = get(graph.info, cls.name, nothing)
  ci === nothing && return false
  ci.is_auth_user && return true
  for b in ci.parents
    p = get(graph.index, b, nothing)
    p === nothing && continue
    _inherits_auth_user(graph, p) && return true
  end
  return false
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
`indexes` declared on the base would be dropped without the report the child's own `indexes` gets.
"""
const _META_KEYS_NOT_INHERITED = ("abstract", "db_table")

function _effective_meta(graph, cls::PyClass)::Dict{String, String}
  b = _inherited_meta_base(graph, cls)
  b === nothing && return graph.info[cls.name].meta
  pm = graph.info[b].meta
  return Dict{String, String}(k => v for (k, v) in pm if !(k in _META_KEYS_NOT_INHERITED))
end

"""
    _inherited_meta_base(graph, cls) -> Union{String, Nothing}

The abstract base whose `Meta` Django installs on `cls`: the nearest ancestor declaring a `Meta`
block at all. `nothing` when `cls` declares its own, or when no ancestor has one.

One walk, used by BOTH consumers — `_effective_meta` and the withheld-`db_table` report. They used
to walk separately and disagree: the reporter climbed the whole chain while `_effective_meta`
stopped at the first match, so a grandparent's `db_table` was reported as withheld from a child that
would never have inherited it (Django resolves `Meta` to one class, not a merge of the chain).

Gated on whether a Meta BLOCK was declared, not on whether it yielded options: `class Meta:`
carrying only a docstring is still a declaration, and Django does not inherit past one.
"""
function _inherited_meta_base(graph, cls::PyClass)::Union{String, Nothing}
  isempty(cls.meta) || return nothing
  seen = Set{String}()
  function walk(c::PyClass)::Union{String, Nothing}
    ci = get(graph.info, c.name, nothing)
    ci === nothing && return nothing
    for b in ci.parents
      b in seen && continue
      push!(seen, b)
      p = get(graph.index, b, nothing)
      p === nothing && continue
      isempty(p.meta) || return b
      r = walk(p)
      r === nothing || return r
    end
    return nothing
  end
  return walk(cls)
end

"""
    _inherited_unresolved(graph, cls) -> Vector{String}

Bases that neither `cls` nor any of its abstract ancestors could resolve.

An abstract base with its own unresolvable base (`class Auditavel(TimeStampedModel)` with
`abstract = True`) loses columns exactly as the child would, but the base emits nothing — so without
walking the chain its gap reaches the generated file with no marker at all.
"""
function _inherited_unresolved(graph, cls::PyClass)::Vector{String}
  out = String[]
  seen = Set{String}()
  function walk(c::PyClass)
    ci = get(graph.info, c.name, nothing)
    ci === nothing && return
    for b in ci.unresolved
      b in out || push!(out, b)
    end
    for b in ci.parents
      b in seen && continue
      push!(seen, b)
      p = get(graph.index, b, nothing)
      p === nothing || walk(p)
    end
    return
  end
  walk(cls)
  return out
end

# An abstract base declaring `db_table` is a Django footgun the importer refuses to reproduce (see
# `_effective_meta`). Reported on each child that would have inherited it — which is exactly the one
# base `_inherited_meta_base` picks, not every ancestor in the chain.
function _abstract_db_table_base(graph, cls::PyClass)::Union{String, Nothing}
  b = _inherited_meta_base(graph, cls)
  b === nothing && return nothing
  return haskey(graph.info[b].meta, "db_table") ? b : nothing
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

function process_class_fields!(fields_dict::Dict{Symbol, Any}, class_content::Vector{PyStmt}, class_name::AbstractString, is_auth_user::Bool, has_primary_key::Base.RefValue{Bool}, autofields_ignore::Vector{String}, parameters_ignore::Vector{String}, markers::Vector{String} = String[])
  # Django's `AbstractUser` columns. A Bool rather than the base-list STRING it used to compare
  # against (#341): the base list is now parsed, so `class User(AbstractUser, SomeMixin)` and a
  # class reaching `AbstractUser` through an abstract base both qualify — an equality test on the
  # whole base list matched neither.
  if is_auth_user
      has_primary_key[] = true
      fields_dict[:id] = Models.IDField()
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
        @warn "import: field-shaped call the importer cannot read; not imported — declare it in PormG by hand" field=parsed.name class=class_name line=stmt.lineno
        # ...and a marker in the generated file, not the warning alone (#341). A console warning
        # scrolls away; whoever opens the generated file months later needs to see the gap there.
        push!(markers, "# PormG: field '$(parsed.name)' on '$(class_name)' (models.py line " *
                       "$(stmt.lineno)) is a field-shaped call the importer cannot read — NOT " *
                       "imported. Declare it in PormG by hand.")
      end
      continue
    end

    field_name = parsed.name
    field_type = django_field_type(parsed.type)
    field_args_str = parsed.args

    # Parse field arguments
    options, related_model = parse_field_args(field_args_str, field_type, parameters_ignore)

    # Check for primary key
    if haskey(options, :primary_key) && options[:primary_key] == true
        has_primary_key[] = true
    end

    # Instantiate the field
    try
      # println(field_type)
      if field_type in autofields_ignore
        continue
      elseif field_type in ["ForeignKey", "OneToOneField"]
        # Add "_id" suffix for foreign keys
        field_key = Symbol("$(field_name)_id")
        # println(related_model, " ", related_model |> typeof)
        _normalize_django_set_default!(options, field_name)
        fields_dict[field_key] = getfield(Models, Symbol(field_type))(related_model; options...)
      elseif field_type == "ManyToManyField"
        fields_dict[Symbol(field_name)] = Models.ManyToManyField(related_model; options...)
      else
        fields_dict[Symbol(field_name)] = getfield(Models, Symbol(field_type))(; options...)
      end
    catch e
      @pormg_debug
      # A FieldValidationError/InvalidValueError from field construction is already the right
      # type — stringifying it into an ErrorException would eject it from the taxonomy (audit).
      e isa PormGError && rethrow()
      throw(InvalidMigrationError("Error processing field '$field_name' in class '$class_name': $(e)"))
    end
  end

  return nothing

end

function django_field_type(field_type::AbstractString)::String
  return String(field_type)
end

function parse_field_args(args_str::AbstractString, field_type::AbstractString, parameters_ignore::Vector{String})
  # This function parses field arguments handling nested parentheses and commas
  # and returns a dictionary of options.
  options = Dict{Symbol, Any}()
  options_list = split_field_options(args_str)
  # println(options_list)
  related_model = missing
  for option_str in options_list
      key_value = split(option_str, "=", limit=2)
      if length(key_value) == 2
          key = strip(key_value[1])
          value = strip(key_value[2])
          value_parsed = parse_value(value)
          # println(value_parsed)
          field_type == "ManyToManyField" && key == "blank" && continue
          key in parameters_ignore && continue
          # Django callable datetime defaults (e.g. default=timezone.now) have no
          # literal equivalent in PormG. Map them to auto_now_add, which sets the
          # column to the current timestamp on creation — the closest semantics.
          if key == "default" && field_type in DATETIME_FIELD_TYPES && is_current_time_default(value)
              options[:auto_now_add] = true
              continue
          end
          options[Symbol(key)] = value_parsed
      else
        if field_type in ["ForeignKey", "OneToOneField", "ManyToManyField"]
          related_model = replace(key_value[1], "\"" => "", "'" => "") |> string
          field_type in ["ForeignKey", "OneToOneField"] && (options[:pk_field] = "id")
        end
      end
  end
  return options, related_model
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
    _normalize_django_set_default!(options, field_name) -> options

Rewrite Django's `on_delete=SET_DEFAULT, default=None` on a nullable FK to `SET_NULL` (#287).

Django accepts that combination and it denotes exactly one thing: on parent delete, set the
dependent FK to `None`, i.e. SQL `NULL`. PormG cannot express "SET_DEFAULT whose default is NULL" —
since #287 that pair is a rejected self-contradiction — so the faithful translation is `SET_NULL`.

Without this the importer emits a model file that raises `ModelDefinitionError` the moment it is
loaded through `@import_models`, and regenerating produces the identical unloadable file. Only the
nullable case is rewritten: `SET_DEFAULT` with no default on a **non**-nullable FK is genuinely
contradictory in both ORMs and is left to fail loudly at registration.
"""
function _normalize_django_set_default!(options::Dict, field_name)
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

  @warn "Django field $(field_name): on_delete=SET_DEFAULT with default=None denotes SET NULL; importing it as on_delete=SET_NULL."
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

function parse_choices(choices_str::AbstractString)
  # Parse a string into a tuple of tuples
  choices = ()
  pattern = r"\(([^()]+)\)"
  for m in eachmatch(pattern, choices_str)
      inner = m.captures[1]
      values = split(inner, ",")
      if length(values) == 2
          key = strip(values[1])
          value = strip(values[2])
          choices = (choices..., (key, value))
      else
          throw(InvalidMigrationError("Invalid choices format"))
      end
  end
  return choices
end

"""
    split_field_options(field_options) -> Vector{String}

Split a call's argument text on its top-level commas, preserving quotes for `parse_value`.

Rebased on the shared scanner (#340). The hand-rolled version it replaces tracked `(`/`)` only —
not `[` or `{` — and had no backslash-escape handling, so `choices=[("A","a"), ("B","b")]` split at
the comma *between* the two tuples and produced two unparseable fragments.
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
      push!(tokens, String(strip(String(take!(buffer)))))
    else
      # Copy the consumed span verbatim: a token may be several characters wide (`\"\"\"`), and the
      # quote characters themselves must survive for `parse_value` to strip them.
      print(buffer, field_options[i:prevind(field_options, j)])
    end
    i = j
  end

  if position(buffer) > 0
      push!(tokens, String(take!(buffer)) |> strip)
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
  "indexes"               => "PormG has no composite-index primitive (only per-field db_index)",
  "index_together"        => "PormG has no composite-index primitive (only per-field db_index)",
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
const _META_OPTIONS_CONSUMED = ("abstract", "proxy", "db_table", "constraints", "unique_together")

# Django's `UniqueConstraint` arguments that PormG can honour. `violation_error_message` /
# `violation_error_code` only change Django's Python-side error text and have no effect on the
# index, so accepting and ignoring them is faithful.
const _UNIQUE_CONSTRAINT_KWARGS = ("fields", "name", "violation_error_message", "violation_error_code")

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

function _drop_constraint!(markers::Vector{String}, class_name::AbstractString,
                           element::AbstractString, reason::AbstractString)
  short = _one_line(element)
  reason = _one_line(reason, 200)
  @warn "import: Meta.constraints entry dropped" class=class_name reason=reason constraint=short
  push!(markers, "# PormG: a constraint on '$(class_name)' was dropped — $(reason): $(short)")
  return markers
end

"""
    _parse_meta_constraints(raw, fields_dict, class_name, markers) -> Vector{UniqueConstraint}

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
                                 class_name::AbstractString, markers::Vector{String})
  out = Models.UniqueConstraint[]
  inner = _balanced_group(raw)
  if inner === nothing
    @warn "import: Meta.constraints is not a list or tuple literal; dropped" class=class_name
    push!(markers, "# PormG: Meta.constraints on '$(class_name)' could not be read — dropped.")
    return out
  end

  for element in split_field_options(inner)
    el = String(strip(element))
    isempty(el) && continue

    m = match(_CONSTRAINT_CTOR_RE, el)
    ctor = m === nothing ? "" : String(m.captures[1])
    if ctor != "UniqueConstraint"
      _drop_constraint!(markers, class_name, el,
        isempty(ctor) ? "it is not a constraint constructor" : "$(ctor) has no PormG equivalent")
      continue
    end

    args = _balanced_group(el)
    if args === nothing
      _drop_constraint!(markers, class_name, el, "its argument list could not be read")
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
      _drop_constraint!(markers, class_name, el, reason)
      continue
    end

    if !haskey(kwargs, "fields")
      _drop_constraint!(markers, class_name, el, "it declares no `fields=`")
      continue
    end
    fields_inner = _balanced_group(kwargs["fields"])
    if fields_inner === nothing
      _drop_constraint!(markers, class_name, el, "its `fields=` is not a list or tuple literal")
      continue
    end

    declared = _clean_constraint_field_names(split_field_options(fields_inner))
    if isempty(declared)
      _drop_constraint!(markers, class_name, el, "its `fields=` is empty")
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
      _drop_constraint!(markers, class_name, el, "field '$(unknown)' matches no imported field")
      continue
    end

    # Django requires `name=`; a computed one (an f-string, a call) is not a literal we can carry,
    # so the constraint is imported with an auto-derived name rather than dropped — the index is
    # what matters, its identifier is not.
    cname = haskey(kwargs, "name") ? _meta_string_literal(kwargs["name"]) : nothing
    if haskey(kwargs, "name") && cname === nothing
      @warn "import: UniqueConstraint name is not a string literal; importing with a derived name" class=class_name value=kwargs["name"]
    end
    try
      push!(out, Models.UniqueConstraint(fields = resolved, name = cname))
    catch e
      # A duplicate-field or empty-name rejection from the constructor: report THIS constraint and
      # keep the rest, rather than losing every constraint on the model to one bad entry.
      _drop_constraint!(markers, class_name, el, replace(sprint(showerror, e), "\n" => " "))
    end
  end
  return out
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
                                    class_name::AbstractString,
                                    markers::Vector{String} = String[])
  inner = _balanced_group(raw)
  if inner === nothing
    # `unique_together = CHAVE_EXTERNA` — a name, not a literal. This used to return an empty vector
    # and the composite key vanished without a word, while the SAME shape on `Meta.constraints` was
    # reported. Same loss, same report.
    @warn "import: Meta.unique_together is not a tuple or list literal; dropped" class=class_name value=_one_line(raw)
    push!(markers, "# PormG: Meta.unique_together on '$(class_name)' is not a tuple or list " *
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
        @warn "import: unique_together field matches no imported field; skipping constraint" field=name class=class_name
        # Whitespace collapsed before interpolation, like every other marker: a field name can
        # carry a real newline (a triple-quoted string survives `_py_logical_lines` intact), and a
        # marker that spans two lines breaks the generated module outright. Verified: without this,
        # `unique_together = ("""nao\nexiste""", "a")` produces a file that will not parse.
        push!(markers, "# PormG: a unique_together group on '$(class_name)' was dropped — field " *
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
    @warn "import: unique_together entry is not a field group; dropped" class=class_name entry=s
    push!(markers, "# PormG: a unique_together entry on '$(class_name)' is not a field group — " *
                   "dropped: $(_one_line(s))")
  end
  return constraints
end
