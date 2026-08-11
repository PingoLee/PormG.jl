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

  # Recover the importable classes as structured blocks (#340). The parser itself is the validity
  # test: the regex that used to guard this required the class header to sit on ONE physical line,
  # so once the parser learned to read a wrapped header it was rejecting files it could handle.
  class_colector = parse_class(model_py_string)

  # check if model_py_string is a model.py file content and not a path
  if isempty(class_colector)
    @warn("The string does not contain a valid model.py content")
    return
  end

  Instructions = Vector{Any}()
  for class in class_colector
    class_name = class.name
    base_class = class.bases          # "models.Model" or "AbstractUser"
    class_content = class.body        # this class's OWN statements; nested bodies excluded

    # Initialize fields_dict
    fields_dict = Dict{Symbol, Any}()
    has_primary_key = Ref(false)  # Flag to check if a primary key exists

    # Process fields separately
    process_class_fields!(fields_dict, class_content, class_name, base_class, has_primary_key, autofields_ignore, parameters_ignore)

    # Insert IDField if no primary key is defined
    if !has_primary_key[]
        # println("No primary key found in class '$class_name'. Adding an IDField named 'id'.")
        fields_dict[:id] = Models.IDField()
    end

    # Collect all create instructions
    if !isempty(fields_dict)
        model = Models.Model(class_name, fields_dict)
        # Recover Django `Meta.unique_together` → composite UniqueConstraints (#19). Lenient:
        # BOTH parsing and validation are wrapped — a malformed `unique_together` (e.g. duplicate
        # fields) is warned and skipped, never aborting the whole multi-class import.
        try
          # `class.meta`, not the whole body (#340): the Meta block is now isolated, so the word
          # `unique_together` appearing in a docstring or a sibling nested class no longer matches.
          constraints = parse_meta_unique_together(class.meta, fields_dict, class_name)
          isempty(constraints) || Models._apply_unique_constraints!(model, constraints)
        catch e
          @warn "import: could not parse/apply unique_together; skipping" class=class_name exception=e
        end
        push!(Instructions, Models.Model_to_str(model, render_settings))
    end

  end

  generate_models_from_db(file, Instructions, render_settings, path=model_path)
end

# Base lists the importer recognises as "this class becomes a table". Deliberately unchanged from the
# regex it replaces (`\((models\.Model|AbstractUser)\)`) — widening it to arbitrary/abstract bases is
# #341, and doing it here would silently change which classes get imported.
const _MODEL_BASES = ("models.Model", "AbstractUser")

"""
    parse_class(model_py_string) -> Vector{PyClass}

Recover the importable model classes from Django source.

Statement- and indentation-driven (#340): a field spanning several physical lines arrives intact,
a nested `class Status(models.TextChoices)` stays in `nested` instead of leaking into the parent's
fields, `class Meta:` is isolated in `meta`, and module-level code after the last class is ignored
rather than appended to it.
"""
function parse_class(model_py_string::String)::Vector{PyClass}
  classes = _py_classes(_py_logical_lines(model_py_string))
  return filter(c -> strip(c.bases) in _MODEL_BASES, classes)
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

function process_class_fields!(fields_dict::Dict{Symbol, Any}, class_content::Vector{PyStmt}, class_name::AbstractString, base_class::AbstractString, has_primary_key::Base.RefValue{Bool}, autofields_ignore::Vector{String}, parameters_ignore::Vector{String})
  # Initialize fields for AbstractUser
  if base_class == "AbstractUser"
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

# ── Django `Meta.unique_together` → PormG `UniqueConstraint` (#19) ────────────────────────
# `class Meta:` options are not field declarations, so they never reach `fields_dict`. These helpers
# recover `unique_together` from the isolated Meta block (`PyClass.meta`) and map it to PormG's
# composite-uniqueness declaration. Django `Meta.constraints=[UniqueConstraint(...)]` (the newer
# named form) is not parsed here yet — `unique_together` is the concrete #19 need.

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
function _parse_unique_together_groups(inner::AbstractString)::Vector{Vector{String}}
  tokens = split_field_options(inner)
  isempty(tokens) && return Vector{String}[]
  if any(t -> (st = strip(t); startswith(st, "(") || startswith(st, "[")), tokens)
    groups = Vector{String}[]
    for t in tokens
      st = strip(t)
      (startswith(st, "(") || startswith(st, "[")) || continue
      innerg = _balanced_group(st)
      innerg === nothing && continue
      names = _clean_constraint_field_names(split_field_options(innerg))
      isempty(names) || push!(groups, names)
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
function parse_meta_unique_together(meta_content, fields_dict::Dict{Symbol, Any}, class_name::AbstractString)
  content = join((s isa PyStmt ? s.text : string(s) for s in meta_content), "\n")
  occursin("unique_together", content) || return Models.UniqueConstraint[]
  # `\b` anchors to a word boundary so a longer identifier ending in `unique_together`
  # (e.g. `not_unique_together = ...`) is not mis-parsed as the Meta option.
  m = match(r"\bunique_together\s*=\s*(.*)"s, content)
  m === nothing && return Models.UniqueConstraint[]
  inner = _balanced_group(m.captures[1])
  inner === nothing && return Models.UniqueConstraint[]
  constraints = Models.UniqueConstraint[]
  for group in _parse_unique_together_groups(inner)
    resolved = String[]
    ok = true
    for name in group
      r = _resolve_django_constraint_field(name, fields_dict)
      if r === nothing
        @warn "import: unique_together field matches no imported field; skipping constraint" field=name class=class_name
        ok = false
        break
      end
      push!(resolved, r)
    end
    ok && !isempty(resolved) && push!(constraints, Models.UniqueConstraint(fields = resolved))
  end
  return constraints
end
