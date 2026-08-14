# ==============================================================================
# INTROSPECTION LOGIC
# Functions for reading database schemas and converting them to PormG models.
# Handles both SQLite and PostgreSQL.
# ==============================================================================

# ---
# Shared FK helpers (both backends)
# ---

# A foreign key's column default, coerced to what `ForeignKey`/`OneToOneField` accept, or `nothing`.
#
# FAILURE POLICY (#292): introspection NEVER throws over a default it cannot represent. The field
# constructors run `validate_default(default, Union{Int64, Nothing}, …, format2int64)`, which raises
# `FieldValidationError` on anything non-numeric — a text default on a text FK column, a PostgreSQL
# expression default like `nextval(...)`. Letting that escape would abort an entire
# `convert_schema_to_models` run over one odd column, with no way to skip past it. So: warn, naming
# the table, column and raw value, and emit the FK without a `default=`.
#
# THE RESIDUAL, stated rather than hidden. This policy covers the *default*, not a self-contradictory
# *action*, so `set_models` still rejects two shapes — deliberately, because the database really is
# in a state PormG cannot express and silently dropping the action would hide it:
#
#   1. `SET_DEFAULT` on a column with no default (or an unrepresentable one) — #287's guard.
#   2. `SET_NULL` on a NOT NULL column — #287's other guard.
#
# Both are legal DDL on both backends (the action is only enforced at delete time), and PostgreSQL
# reaches them for the first time as of #292, because before it the PostgreSQL path never emitted
# `on_delete` at all and so could not contradict anything. The `@warn` above is what names the
# column for case 1; case 2 surfaces at registration with the model and field named. See the
# `## Unreleased` entry in UPGRADING.md.
#
# Shared by all three FK branches — the two SQLite ones and the PostgreSQL one. Before #292 the
# SQLite branches dropped the default silently and PostgreSQL passed it through unguarded, so this
# closes an existing PostgreSQL exposure as well as the SQLite gap it was written for.
function _fk_default_or_warn(default_val, table_name, column_name)
  default_val === nothing && return nothing
  ismissing(default_val) && return nothing

  try
    # `Bool <: Integer`, so a SQLite 0/1 boolean default converts to 0/1 — which is what the
    # column actually stores. Inside the `try` on purpose: `Int64(::UInt64)` past `typemax(Int64)`
    # raises `InexactError`, and the whole point of this helper is that no input escapes as a throw.
    default_val isa Integer && return Int64(default_val)
    return Models.format2int64(default_val)
  catch e
    # Program-state failures are not "this default is unrepresentable" — same carve-out the
    # `Model_to_str` render-failure path uses (Models.jl), so Ctrl-C during a large
    # `convert_schema_to_models` run aborts instead of being reported as a bad default.
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    # The value is shown as introspection received it. On PostgreSQL that is the column regex's
    # already-cleaned form, so an expression default can appear truncated at a `::` cast — enough
    # to identify the column, not a faithful reproduction of the DDL.
    @warn "Foreign key default could not be represented as a field default; emitting the relation without it." table = string(table_name) column = string(column_name) default = string(default_val)
    return nothing
  end
end

# PormG's `on_delete === nothing` and `DO_NOTHING` both render as SQL `ON DELETE NO ACTION`
# (`_foreign_key_on_delete_sql`, Dialect.jl), so a "NO ACTION" read back out of a database is
# ambiguous — and `NO ACTION` is also what a backend stores when no action was declared at all.
# Introspecting it as `DO_NOTHING` would therefore stamp an explicit `on_delete=DO_NOTHING` onto
# EVERY plain foreign key in every generated model. Mapping it to `nothing` is lossless (the
# re-emitted DDL is identical either way) and keeps the two backends agreeing: PostgreSQL stores
# `confdeltype = 'a'` for the same two cases.
#
# `PROTECT` is not recoverable — it renders as SQL `RESTRICT`, so a round trip can only ever return
# `RESTRICT`. One-way by construction, not an oversight.
#
# PostgreSQL stores the action as a single char in `pg_constraint.confdeltype`. `'a'` (NO ACTION)
# maps to `nothing` for the reason above; an empty/unknown code does too, so a schema-query result
# predating #292 degrades to today's behaviour instead of erroring.
function _pg_confdeltype_to_on_delete(code)
  code === nothing && return nothing
  ismissing(code) && return nothing
  c = strip(string(code))
  c == "c" && return "CASCADE"
  c == "r" && return "RESTRICT"
  c == "n" && return "SET NULL"
  c == "d" && return "SET DEFAULT"
  return nothing   # 'a' (NO ACTION) and anything unrecognised
end

function _normalize_introspected_on_delete(action)
  action === nothing && return nothing
  ismissing(action) && return nothing
  normalized = uppercase(replace(strip(string(action)), r"\s+" => "_"))
  (isempty(normalized) || normalized == "NO_ACTION") && return nothing
  return normalized
end

# ---
# SQLite Introspection
# ---

function _strip_sqlite_default_wrapper(default_val)
  default_val === nothing && return nothing
  ismissing(default_val) && return nothing

  stripped = strip(String(default_val))
  while length(stripped) >= 2 && startswith(stripped, "(") && endswith(stripped, ")")
    inner = strip(stripped[2:end-1])
    inner == stripped && break
    stripped = inner
  end

  return stripped
end

"""
    _sqlite_blob_literal_bytes(s) -> Union{Vector{UInt8}, Nothing}

Decode SQLite's `X'0102'` blob-literal syntax into bytes, or `nothing` if `s` is not one.

Normalizing here rather than loosening `BinaryField(default = …)` is deliberate: introspection is
the import layer, and the repo's rule is to normalize dirty inputs there instead of weakening a
field contract to accept them.
"""
function _sqlite_blob_literal_bytes(s::AbstractString)::Union{Vector{UInt8}, Nothing}
  m = match(r"^[Xx]'([0-9A-Fa-f]*)'$", strip(s))
  m === nothing && return nothing
  hex = m.captures[1]
  isodd(length(hex)) && return nothing   # malformed; treat as "no recoverable default"
  return hex2bytes(hex)
end

"""
    _pg_bytea_literal_bytes(s) -> Union{Vector{UInt8}, Nothing}

Decode PostgreSQL's hex `bytea` output form (`\\x0102`) into bytes, or `nothing` if `s` is not one.

The PostgreSQL twin of [`_sqlite_blob_literal_bytes`](@ref); see there for why the normalization
belongs in introspection rather than in the field constructor.
"""
function _pg_bytea_literal_bytes(s::AbstractString)::Union{Vector{UInt8}, Nothing}
  m = match(r"^\\\\?x([0-9A-Fa-f]*)$", strip(s))
  m === nothing && return nothing
  hex = m.captures[1]
  isodd(length(hex)) && return nothing
  return hex2bytes(hex)
end

function _normalize_sqlite_default(default_val, type_sym::Symbol)
  stripped = _strip_sqlite_default_wrapper(default_val)
  stripped === nothing && return nothing

  uppercase(stripped) == "NULL" && return nothing

  # A BinaryField default is written as `X'…'` and must come back as bytes (#296). Before this,
  # every branch below returned a String, and `BinaryField(default = <String>)` raises — so
  # introspecting a BLOB column with a DEFAULT would have crashed the whole schema read. That was
  # unreachable only while PormG never emitted a BLOB column.
  #
  # An unrecognized literal degrades to `nothing` (no default) rather than raising: a hand-written
  # or foreign table must stay introspectable, matching how `Model_to_str` degrades a field it
  # cannot render instead of failing the run.
  if type_sym == :BinaryField
    return _sqlite_blob_literal_bytes(stripped)
  end

  if type_sym == :BooleanField
    lowered = lowercase(replace(stripped, "'" => "", "\"" => ""))
    lowered in ["1", "true", "t"] && return true
    lowered in ["0", "false", "f"] && return false
  end

  if length(stripped) >= 2 && startswith(stripped, "'") && endswith(stripped, "'")
    return replace(stripped[2:end-1], "''" => "'")
  elseif length(stripped) >= 2 && startswith(stripped, "\"") && endswith(stripped, "\"")
    return replace(stripped[2:end-1], "\"\"" => "\"")
  end

  return stripped
end

function get_database_schema(db::PormGSQLite)
  # Query the sqlite_master table to get the schema information
  schema_query = "SELECT type, name, sql FROM sqlite_master WHERE type='table' OR type='index';"
  schema_info = fetch(db, schema_query)

  # Initialize a dictionary to hold the schema data
  schema_data = Dict{String, Any}()

  for row in schema_info
      # For each row, store the type, name, and SQL in the schema_data dictionary
      table_name = row[:name]
      schema_data[table_name] = Dict(
          "type" => row[:type],
          "sql" => row[:sql]
      )
  end

  return schema_data
end

"""
  convertSQLToModel(sql::String)

Converts a SQL CREATE TABLE statement into a model definition in PormGModel.

# Arguments
- `sql::String`: The SQL CREATE TABLE statement.

# Returns
- `PormGModel`: The model definition.

# Example"""
function convertSQLToModel(sql::String; type_map::Dict{String, Symbol} = sqlite_type_map)
  # NOTE (#318): this DDL-regex reader does NOT populate `field.unique`, unlike the PRAGMA reader
  # (`convertSQLToModel(::PormGSQLite, …)`) that #318 fixed. Deliberate: `convert_schema_to_models`
  # reaches the PRAGMA method, so this one is off the production introspection path. Reading it here
  # would mean regex-parsing inline and table-level UNIQUE clauses out of the DDL text — strictly
  # worse than the pragma. If this path is ever put back on the live route, close that gap first.

  # Extract table name
  table_name_match = match(r"CREATE TABLE \"(.+?)\"", sql)
  table_name = table_name_match !== nothing ? table_name_match.captures[1] :
    throw(InvalidMigrationError("Cannot introspect: CREATE TABLE statement has no double-quoted table name (table created outside PormG?): $(first(sql, 120))"))

  # Define a dictionary to map SQL types to Models.jl field types
  fk_map::Dict{String, Any} = Dict{String, Any}()
  pk_map::Dict{String, Any} = Dict{String, Any}()

  # Extract any primary key constraints
  # primary_key_regex = eachmatch(r"PRIMARY KEY\s*\((.+?)\)", sql)
  primary_key_regex = eachmatch(r"PRIMARY KEY\s*\((.+?)\)?\s*(AUTOINCREMENT)?\)", sql)
  for match in primary_key_regex
    primary_keys = match.captures[1]
    primary_keys = replace(primary_keys, r"\"" => "") 
    primary_keys = split(primary_keys, ",")
    auto_increment = isnothing(match.captures[2]) ? false : true
    # println(primary_keys)
    for key in primary_keys
      key = strip(key) |> String
      pk_map[key] = Dict("primary_keys" => key, "auto_increment" => auto_increment)
    end
  end

  # Extract any foreign key constraints
  foreign_key_matches = eachmatch(r"FOREIGN KEY\(\"(\w+)\"\) REFERENCES \"(\w+)\"\(\"(\w+)\"\)(?: ON DELETE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: ON UPDATE (CASCADE|SET NULL|NO ACTION|RESTRICT|SET DEFAULT))?(?: DEFERRABLE INITIALLY (DEFERRED|IMMEDIATE))?", sql)
  for match in foreign_key_matches
    column_name, fk_table, fk_column, on_delete, on_update, on_deferable = match.captures
    # println(match.captures)
    # typeof(column_name |> String) |> println
    fk_map[column_name |> String] = Dict("column_name" => column_name, "fk_table" => fk_table, "fk_column" => fk_column, "on_delete" => on_delete, "on_update" => on_update, "on_deferable" => on_deferable)
  end

  
  # Byte bounds for BinaryField columns, read from the CHECK clauses in the same DDL text (#296).
  byte_bounds = _sqlite_byte_length_bounds(sql)

  # Extend regex to capture PRIMARY KEY and FOREIGN KEY constraints.
  # The type group allows a trailing UNSIGNED so the two-word declared type of
  # PositiveIntegerField ("INTEGER UNSIGNED") round-trips instead of degrading
  # to IntegerField.
  #
  # The DEFAULT alternation enumerates the literal shapes explicitly instead of using a catch-all,
  # because a column can be followed by a CHECK clause with no comma between them: in
  # `"c" BLOB NOT NULL DEFAULT X'0102' CHECK (length("c") <= 4)` the previous `[^,]*` branch
  # swallowed ` CHECK (length("c") <= 4)` into the default (#296).
  #
  # The branches, in order: a quoted string; a blob literal; a parenthesized expression (SQLite
  # allows `DEFAULT (expr)`, e.g. `(datetime('now'))`, which `_strip_sqlite_default_wrapper` exists
  # to unwrap — one nesting level is enough for every form SQLite emits); then a bare token. The
  # bare-token branch must exclude `(` so it cannot run into a trailing CHECK.
  #
  # The single-integer length suffix (`TEXT(120)`) is captured because it is what distinguishes a
  # CharField from a TextField on SQLite (#325) — see the note by `type_sym` below. A two-argument
  # suffix (`DECIMAL(10,2)`) deliberately does not match: `\s*(NOT NULL)?` then matches empty and
  # the match ends before it, exactly as it did before the group existed.
  column_matches = eachmatch(r"[^(]\"(\w+)\"\s+([A-Z]+(?: UNSIGNED)?)(?:\(\s*(\d+)\s*\))?\s*(NOT NULL)?\s*(?:DEFAULT\s+('[^']*'|[Xx]'[0-9A-Fa-f]*'|\([^()]*(?:\([^()]*\)[^()]*)*\)|[^,()\s]+))?", sql)
  # Initialize fields dictionary
  fields_dict = Dict{Symbol, Any}()
  str_fields_dict = Dict{String, Any}()
  for match in column_matches
    # println(match.captures)
    column_name, column_type, declared_length, nullable, default_value = match.captures
    type_sym = get(type_map, column_type, :TextField)
    # #325: keep this reader's CharField/TextField split identical to the PRAGMA reader's. A bare
    # textual column has no length, and `CharField()` would invent `max_length = 250`.
    if type_sym == :CharField && declared_length === nothing
      type_sym = :TextField
    end
    normalized_default = _normalize_sqlite_default(default_value, type_sym)
    # check if column_name is a primary key
    if haskey(pk_map, column_name)
      field_instance = Models.IDField(null=(nullable === nothing), auto_increment=pk_map[column_name]["auto_increment"])
    elseif haskey(fk_map, column_name)
      # `default=` was computed above but never reached this branch before #292, so an FK declared
      # ON DELETE SET DEFAULT introspected to `SET_DEFAULT` with no default — which since #287
      # throws `ModelDefinitionError` at `set_models`, and regenerating produced the identical
      # broken file. Routed through `_fk_default_or_warn` so an unrepresentable default warns
      # rather than throwing from inside introspection.
      # #338: this `uppercasefirst` must match the BINDING `Model_to_str` derives for the target
      # table — `_resolve_target_model` resolves `.to` by binding lookup alone. If that binding
      # collides with a sibling table's and gets suffixed with a digit, `.to` still names this
      # un-suffixed spelling and can resolve to the wrong model. Pre-existing ambiguity, not
      # introduced by #338's dedup — see docs/src/schema_conventions.md → "Generated files:
      # colliding bindings and names are disambiguated".
      field_instance = Models.ForeignKey(uppercasefirst(fk_map[column_name]["fk_table"] |> string); pk_field=fk_map[column_name]["fk_column"] |> string,
      on_delete=_normalize_introspected_on_delete(fk_map[column_name]["on_delete"]),
      on_update=fk_map[column_name]["on_update"], deferrable=!(fk_map[column_name]["on_deferable"] === nothing), null=(nullable === nothing),
      default=_fk_default_or_warn(normalized_default, table_name, column_name))
    else
      field_instance = getfield(Models, type_sym)(null=(nullable === nothing), default=normalized_default)
      # BLOB carries no length suffix, so a BinaryField's byte bound comes from its CHECK (#296).
      if type_sym == :BinaryField && haskey(byte_bounds, column_name)
        field_instance.max_length = byte_bounds[column_name]
      elseif type_sym == :CharField && declared_length !== nothing
        # #325: carry the declared length instead of letting CharField default it to 250.
        field_instance.max_length = parse(Int, declared_length)
      end
    end

    fields_dict[Symbol(column_name)] = field_instance
  end

  # Construct and return the model
  # Dict(:models => Models.Model(table_name, fields_dict), :str_models => Models.Model(table_name, str_fields_dict))
  # println(fields_dict)
  # println(typeof(table_name))
  return Models.Model(table_name, fields_dict)
end

"""
    _sqlite_byte_length_bounds(create_sql) -> Dict{String, Int}

Recover each column's BinaryField byte bound from the `CHECK (length("col") <= n)` clauses in a
table's `CREATE TABLE` text (#296).

`PRAGMA table_info` — which `convertSQLToModel` otherwise relies on — does not report CHECK
constraints at all, and `max_length` is part of the field state the migration planner diffs. Without
this, every `makemigrations` against a bounded BinaryField would see the live column as unbounded
and propose the same ALTER forever. On SQLite that is especially costly: any field alteration
rebuilds the whole table.
"""
function _sqlite_byte_length_bounds(create_sql::Union{AbstractString, Nothing})::Dict{String, Int}
  bounds = Dict{String, Int}()
  create_sql === nothing && return bounds
  for m in eachmatch(r"CHECK\s*\(\s*length\s*\(\s*\"([^\"]+)\"\s*\)\s*<=\s*(\d+)\s*\)", create_sql)
    bounds[m.captures[1]] = parse(Int, m.captures[2])
  end
  return bounds
end

function convertSQLToModel(db::PormGSQLite, table_name::String; type_map::Dict{String, Symbol} = sqlite_type_map)
  # Use PRAGMA instead of Regex for more reliable introspection
  cols = fetch(db, "PRAGMA table_info(\"$table_name\")") |> DataFrame
  fks = fetch(db, "PRAGMA foreign_key_list(\"$table_name\")") |> DataFrame

  # PRAGMA cannot see CHECK constraints, so the byte bounds come from the stored DDL text (#296).
  # Parameterized, not interpolated: `table_name` is caller-supplied (convertSQLToModel is public),
  # and unlike the PRAGMA calls above — which interpolate into a *quoted identifier* — this value
  # lands inside a single-quoted literal, where an embedded `'` would break out.
  _bounds_rows = fetch(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?", [table_name]) |> DataFrame
  byte_bounds = _sqlite_byte_length_bounds(nrow(_bounds_rows) == 0 || ismissing(_bounds_rows[1, :sql]) ? nothing : _bounds_rows[1, :sql])

  # #318: `PRAGMA table_info` above has no uniqueness column, so `unique` was never populated at all.
  # Read it once per table here; the per-column branches below test membership.
  unique_cols = _sqlite_single_column_unique_columns(db, table_name)
  # #325: the same gap for `db_index` — PRAGMA table_info has no index column either. Column ⇒ index
  # name, so the model can also carry `cache["index"]` for the planner's DROP INDEX path.
  indexed_cols = _sqlite_single_column_indexed_columns(db, table_name)
  # #347: and the multi-column half of the same set, which the reader above excludes by arity. These
  # become model-level `Models.Index` declarations rather than a per-field attribute.
  composite_idxs = _sqlite_composite_indexes(db, table_name)

  fields_dict = Dict{Symbol, Any}()
  fk_map = Dict{String, Any}()
  if !isempty(fks)
    for fk_row in eachrow(fks)
      fk_map[fk_row.from] = fk_row
    end
  end
  
  for col_row in eachrow(cols)
    col_name = col_row.name
    col_type = col_row.type |> uppercase
    # Handle types with length/precision like VARCHAR(255)
    base_type = split(col_type, '(')[1] |> strip
    
    nullable = col_row.notnull == 0
    default_val = ismissing(col_row.dflt_value) ? nothing : col_row.dflt_value
    is_pk = col_row.pk > 0
    
    if is_pk
      if base_type == "UUID"
        # #334: a UUID primary key is the ONE non-integer pk type this reader can safely
        # reconstruct as its real field type, mirroring the same narrow carve-out in the
        # PostgreSQL reader just above in this file (see its comment for why this is NOT
        # generalized to "any non-integer pk" — `UUIDField` uniquely carries neither the
        # max_length/max_digits hazard nor a construction-time refusal that other non-integer
        # field types can hit when forced into `primary_key = true`).
        #
        # UNREACHABLE today for a table PormG itself created: `sqlite_type_map_reverse` (below,
        # DDL-generation direction) renders every `UUIDField` column — pk or not — as bare `TEXT`,
        # same as CharField/TextField/JSONField/ImageField (the collapse the `else` branch of the
        # non-pk arm already documents), never as a literal `UUID` column type. This branch exists
        # for a hand-written or foreign SQLite schema that DOES declare a column type as `UUID`
        # (SQLite accepts any type name), and costs nothing to keep. It does NOT close the gap for
        # PormG-generated schemas — `test/integration/db_2/models.jl`'s comment on
        # `Bulk_uuid_pk_scratch` explains why that fixture has no SQLite counterpart instead.
        field = Models.UUIDField(null=false, primary_key=true,
            default=_normalize_sqlite_default(default_val, :UUIDField))
      else
        # In SQLite, INTEGER PRIMARY KEY often implies AUTOINCREMENT behavior
        field = Models.IDField(null=false, primary_key=true, auto_increment=(base_type == "INTEGER"))
      end
    elseif haskey(fk_map, col_name)
        fk_info = fk_map[col_name]
        # Same #292 gap as the DDL-regex path above: `default_val` was in scope and used two
        # branches down, but never passed to the FK. This is the path the live
        # `convert_schema_to_models(::PormGSQLite)` actually reaches. The FK column's declared type
        # drives normalization the same way a non-FK column's does.
        fk_type_sym = get(type_map, base_type, :TextField)
        # A UNIQUE foreign key is conceptually a one-to-one, and PostgreSQL introspection returns
        # `OneToOneField` for it — but SQLite deliberately does NOT follow suit here (#318). PormG
        # cannot currently materialize a OneToOneField: `Dialect._get_column_type` has no branch for
        # it, so it renders `TEXT` rather than the referenced key's type, and (on SQLite) the inline
        # `FOREIGN KEY … REFERENCES` clause is gated on `isa sForeignKey`, so no constraint is emitted
        # at all. Returning O2O here would therefore make the inspectdb round trip strictly WORSE:
        # with the `unique` flag below, a live `INTEGER UNIQUE REFERENCES parent(id)` now regenerates
        # LOSSLESSLY as `INTEGER UNIQUE` + the foreign key, where an O2O would regenerate as `TEXT`
        # with no foreign key. The flag is what #318 is actually about; the field type is not.
        # #338: same binding-collision caveat as the FK path above — `.to` resolves by binding
        # lookup alone, so a suffixed sibling binding can leave this pointing at the wrong model.
        field = Models.ForeignKey(uppercasefirst(fk_info.table); pk_field=fk_info.to,
            on_delete=_normalize_introspected_on_delete(fk_info.on_delete), null=nullable,
            default=_fk_default_or_warn(_normalize_sqlite_default(default_val, fk_type_sym), table_name, col_name))
    else
        type_sym = get(type_map, base_type, :TextField)
        # #325: a BARE textual column carries no length, but `CharField()` INVENTS `max_length = 250`
        # (models/fields.jl) — which then renders `TEXT(250)` and can never match the live `TEXT`.
        # SQLite collapses UUIDField, JSONField, ImageField and TextField all onto bare `TEXT`, so
        # every one of them read back as `CharField(250)` and churned forever. Only a declared `(n)`
        # is a CharField here; a lengthless textual column is a TextField.
        if type_sym == :CharField && !occursin("(", col_type)
            type_sym = :TextField
        end
        # Handle decimal precision if present
      field = getfield(Models, type_sym)(null=nullable, default=_normalize_sqlite_default(default_val, type_sym))
        if type_sym == :CharField && occursin("(", col_type)
            m = match(r"\((\d+)\)", col_type)
            if m !== nothing
                field.max_length = parse(Int, m.captures[1])
            end
        elseif type_sym == :BinaryField && haskey(byte_bounds, col_name)
            # Byte bound recovered from the CHECK clause — `BLOB` carries no length suffix, so it
            # cannot come from `col_type` the way CharField's does (#296).
            field.max_length = byte_bounds[col_name]
        end
    end
    # #318: set post-construction, matching the `field.max_length = …` mutations just above — that
    # avoids threading a kwarg through three different constructors.
    #
    # `!is_pk` is required, not defensive, on two independent counts: `sIDField` is the ONE immutable
    # field struct (models/fields.jl), so `setfield!` would throw; and it already defaults
    # `unique=true`, which must survive an `INTEGER PRIMARY KEY` rowid alias that has no backing index
    # at all. Hence the rule everywhere here: only ever set TRUE, never clear it.
    if !is_pk && col_name in unique_cols && hasfield(typeof(field), :unique) && !field.unique
      field.unique = true
    end
    # #325: same treatment for `db_index`, and for the same three reasons `!is_pk` is required —
    # sIDField is immutable, it already defaults `db_index=true`, and only ever setting TRUE keeps a
    # ForeignKey's constructor-forced `db_index` intact.
    if !is_pk && haskey(indexed_cols, col_name) && hasfield(typeof(field), :db_index) && !field.db_index
      field.db_index = true
    end
    fields_dict[Symbol(col_name)] = field
  end

  model_resp = Models.Model(table_name, fields_dict)
  # The planner reads `cache["index"]` to name the index it must DROP when a model stops declaring
  # `db_index`. PostgreSQL's reader has always populated it; SQLite's never did, which was harmless
  # only while `db_index` could not be true on this side (#325).
  #
  # #347: writes the one KEY rather than assigning the whole `cache` field. `_attach_composite_indexes!`
  # below writes a second key, and while the current order happens to be safe, a whole-field assign
  # makes the two writers order-dependent for no reason. Defensive, not a bug fix.
  if !isempty(indexed_cols)
    model_resp.cache["index"] = indexed_cols
  end
  _attach_composite_indexes!(model_resp, composite_idxs)
  return model_resp
end

"""
    _is_ignored_table(table_name, ignore_table) -> Bool

Whether `table_name` is skipped by the introspection ignore list — matched as a **prefix**, on both
backends (#325).

Every entry in `postgres_ignore_table` / `sqlite_ignore_schema` is a framework prefix
(`"django_"`, `"auth_"`, `"celery_"`, `"sqlite_autoindex"`) or a whole table name
(`"pormg_migrations"`), and a prefix test covers both. The two backends used to disagree, and both
were wrong in different directions:

  * PostgreSQL used `occursin`, so a user table merely *containing* an entry was silently dropped
    from the live schema — `company_admin_log` matched `"admin_"`, `oauth_tokens` matched `"auth_"`.
    A dropped table does not read as "ignored" downstream, it reads as "does not exist", so
    `makemigrations` proposed `CREATE TABLE` for it on every single run.
  * SQLite used `==`, so `"sqlite_autoindex"` — a prefix of `sqlite_autoindex_<table>_<n>`, never a
    table name in its own right — could never match. Harmless only because the table query already
    filters `name NOT LIKE 'sqlite_%'`.
"""
_is_ignored_table(table_name, ignore_table)::Bool =
  any(ignored -> startswith(String(table_name), ignored), ignore_table)

function convert_schema_to_models(db::PormGSQLite; ignore_table::Vector{String} = sqlite_ignore_schema, include_table::Union{Vector{String}, Nothing} = nothing)
  # Always skip consumer-registered framework tables (e.g. Nitro's), on top of the caller's list.
  ignore_table = unique(vcat(ignore_table, _EXTRA_IGNORE_TABLES[]))
  # Query the sqlite_master table to get the table names
  tables_query = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
  tables = fetch(db, tables_query) |> DataFrame
  
  models_array::Vector{PormGModel} = []
  for row in eachrow(tables)
    table_name = row.name
    # If include_table is specified, only include those tables
    if include_table !== nothing
      !any(included -> table_name == included, include_table) && continue
    end
    _is_ignored_table(table_name, ignore_table) && continue

    push!(models_array, convertSQLToModel(db, table_name))
  end  
  return models_array
end

# ---
# PostgreSQL Introspection
# ---

"""
    _pg_composite_indexes(db::PormGPostgres; schema = "public") -> Dict{String, Vector{Pair{String, Vector{String}}}}

Every MULTI-column non-unique index in `schema`, as `table_name => [index_name => ordered columns]` —
the PostgreSQL half of #347 and the exact mirror of [`_sqlite_composite_indexes`](@ref).

The predicates are the `indexes` CTE's in `get_database_schema`, with the arity inverted
(`indnkeyatts > 1` instead of `= 1`), so the two readers partition the same index set: nothing feeds
both a per-field `db_index` and a model-level `Index`. `NOT indisunique` keeps a composite
`UniqueConstraint` (a `CREATE UNIQUE INDEX`) out; `indpred IS NULL` keeps a partial index out.

Run **once for the whole schema**, not per table, and joined to the models by name in
`convert_schema_to_models`. It is a separate query rather than another CTE on the schema dump because
that query returns one row per table and would need a second aggregation level — and any delimiter
chosen to serialize `(index, columns)` pairs into one string is a legal character in a PostgreSQL
identifier.

Everything PormG cannot re-emit is excluded, never read partially or approximately. Reading it
"close enough" would regenerate a **different** index under the developer's name, which is the one
failure a schema dump must not have — the same reject-rather-than-reinterpret rule the Django
importer applies to `Meta.indexes`. Beyond the shared predicates:

  * `am.amname = 'btree'` — `Dialect.create_index` emits a default b-tree and nothing else. A GIN,
    GiST, BRIN or hash index read back as an `Index` would regenerate as a b-tree (#29).
  * `NOT i.indisexclusion` — an `EXCLUDE USING gist (…)` constraint's backing index is non-unique,
    non-primary and unfiltered, so it passes every other predicate. Regenerating it as a plain index
    would drop a constraint the database was enforcing.
  * `indoption`, `indclass` and `indcollation`, selected per column and filtered in Julia alongside
    the NULL check: a **non-default sort** (`indoption != 0` — descending *or* `NULLS FIRST`), a
    non-default **operator class** (`varchar_pattern_ops`), or an explicit **collation**
    (`COLLATE "C"`) each makes a different index. PormG can express none of them, and the importer
    already refuses Django's `Index(fields=["-year"])` and `opclasses=` on the same grounds.

    The collation test answers the same *question* as the SQLite reader's non-BINARY `coll` filter
    but is not the same *test*, and the difference is deliberate rather than drift — do not "fix"
    one to match the other. This one is RELATIVE (did the index override the column's collation?);
    SQLite's is ABSOLUTE (is the effective collation `BINARY`?), because `pragma_index_xinfo` cannot
    distinguish an index-level `COLLATE` from one declared on the column. They agree on the case
    both exist for — an explicit `COLLATE` in the index — and diverge only on a column *declared*
    with a non-default collation, which PostgreSQL keeps (re-emitting the index reproduces it
    exactly) and SQLite drops for want of the information to do better.

    Both are subscripted `[k.ord - 1]`, and the `- 1` is load-bearing. `indkey`/`indoption`/`indclass`
    are `int2vector`/`oidvector`, which PostgreSQL builds with **lower bound 0**; the `::int2[]` cast
    is binary-coercible (`pg_cast.castmethod = 'b'`, no function runs), so the 0-based bound survives
    it. `WITH ORDINALITY` numbers rows from 1 regardless. Without the offset every row reads the
    *next* column's option — so a `DESC` or non-default opclass on the **first** key column, the
    canonical case, went undetected while the last row read out of range and came back NULL.
    Measured on a live server: `array_lower(indoption::int2[], 1)` is `0`, and
    `CREATE INDEX … (a DESC, b)` read back as a plain ascending index. There are no false positives,
    which is why nothing failed.

Two details the naive query gets wrong:

  * `unnest(indkey) WITH ORDINALITY` rather than `attnum = ANY(indkey)`: an index's column ORDER is
    part of its identity, and `ANY` returns them in table order. `ord <= indnkeyatts` then drops an
    `INCLUDE` clause's non-key columns, which are payload, not index keys.
  * the `LEFT JOIN` to `pg_attribute` is deliberate: an expression member has `attnum = 0` and matches
    no row. It surfaces as a NULL column name, and the caller drops that index whole rather than
    declaring the remaining columns as if they were the index (functional indexes are #29).

`indnkeyatts` is PostgreSQL 11+, which the pre-existing `indexes` CTE already requires, so this adds
no floor of its own.

The partition with the `db_index` reader is per INDEX (`indnkeyatts = 1` there, `> 1` here), not per
column: the older CTE still selects its column with `attnum = ANY(indkey)`, so a covering
`CREATE INDEX ON t (a) INCLUDE (b, c)` marks `b`/`c` as `db_index` too. That is pre-existing and
untouched here — no index reaches both readers.
"""
function _pg_composite_indexes(db::PormGPostgres; schema::Union{String, Nothing} = "public")::Dict{String, Vector{Pair{String, Vector{String}}}}
  # Parameterized rather than interpolated: `schema` is a keyword argument, so it is caller-supplied
  # by contract even though every call site today passes the default.
  schema_clause = schema === nothing ? "" : "AND n.nspname = \$1"
  params = schema === nothing ? String[] : String[schema]
  query = """
    SELECT c.relname AS table_name,
           ic.relname AS index_name,
           a.attname AS column_name,
           (i.indoption::int2[])[k.ord - 1] AS opt,
           (i.indcollation::oid[])[k.ord - 1] AS idx_coll,
           a.attcollation AS col_coll,
           oc.opcdefault AS opc_default
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_am am ON am.oid = ic.relam
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
      ON k.ord <= i.indnkeyatts
    LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    LEFT JOIN pg_opclass oc ON oc.oid = (i.indclass::oid[])[k.ord - 1]
    WHERE c.relkind = 'r'
      AND am.amname = 'btree'
      AND NOT i.indisprimary
      AND NOT i.indisunique
      AND NOT i.indisexclusion
      AND i.indpred IS NULL
      AND i.indnkeyatts > 1
      $(schema_clause)
    ORDER BY c.relname, ic.relname, k.ord;
    """
  rows = DataFrame(fetch(db, query, params))
  out = Dict{String, Vector{Pair{String, Vector{String}}}}()
  nrow(rows) == 0 && return out
  # index name ⇒ its column list, per table; `ORDER BY … k.ord` above means push order IS index order.
  # `nothing` marks a member PormG cannot express; the whole index is then skipped below.
  grouped = OrderedDict{Tuple{String, String}, Vector{Union{String, Nothing}}}()
  for r in eachrow(rows)
    (r.table_name === missing || r.index_name === missing) && continue
    key = (string(r.table_name), string(r.index_name))
    # Every test defaults to UNUSABLE on a NULL, which is the safe direction: after the `k.ord - 1`
    # fix the subscripts are always in range, so a NULL here means something unexpected, and this
    # reader's whole contract is that it never reads an index approximately.
    #
    #   * `indoption != 0`, not `& 1`. Bit 0 is DESC and bit 1 is NULLS FIRST (`access/skey.h`), and
    #     `DESC` implies `NULLS FIRST` — a live `(a DESC, b)` measures 3, not 1. Masking bit 0 alone
    #     therefore lets `(a NULLS FIRST, b)` (value 2) through, and PormG would re-emit it as
    #     NULLS LAST. `Dialect.create_index` only ever emits the all-default 0.
    #   * `opcdefault = false` is an explicit operator class (`varchar_pattern_ops`).
    #   * `indcollation` differing from the COLUMN's own collation is an explicit `COLLATE` in the
    #     index — a different comparison, so a different index. 0 means no collation applies (an
    #     integer column). Deliberately RELATIVE, unlike SQLite's absolute non-BINARY test — see the
    #     docstring; a PormG-created index can never trip this, since PormG emits no `COLLATE` at all.
    unusable = r.column_name === missing ||
               r.opt === missing || Int(r.opt) != 0 ||
               r.opc_default === missing || r.opc_default == false ||
               r.idx_coll === missing ||
               (r.idx_coll != 0 && (r.col_coll === missing || r.idx_coll != r.col_coll))
    push!(get!(grouped, key, Union{String, Nothing}[]), unusable ? nothing : string(r.column_name))
  end
  for ((tbl, idx), cols) in grouped
    length(cols) > 1 || continue                 # arity 1 is `db_index`, read by the schema dump
    any(c -> c === nothing, cols) && continue    # a member PormG cannot re-emit ⇒ drop it whole
    push!(get!(out, tbl, Pair{String, Vector{String}}[]), idx => String[String(c) for c in cols])
  end
  return out
end

"""
  convert_schema_to_models(db::PormGPostgres; ignore_table::Vector{String} = postgres_ignore_table)

Convert the database schema to models.

# Arguments
- `db::PormGPostgres`: The database connection.
- `ignore_table::Vector{String}`: A vector of table names to ignore. Defaults to `postgres_ignore_table`.

# Returns
- `models_array::Vector{Any}`: A vector containing the converted models.

# Description
This function retrieves the database schema and converts it to models. It collects all create instructions and skips tables specified in the `ignore_table` vector. The function prints the type of each schema and returns the schema for debugging purposes. It stops processing after the fifth schema.
"""
function convert_schema_to_models(db::PormGPostgres; ignore_table::Vector{String} = postgres_ignore_table, include_table::Union{Vector{String}, Nothing} = nothing)
  # Always skip consumer-registered framework tables (e.g. Nitro's), on top of the caller's list.
  ignore_table = unique(vcat(ignore_table, _EXTRA_IGNORE_TABLES[]))
  # Get all schema
  schemas = get_database_schema(db)
  # #347: composite indexes come from their own schema-wide query — see `_pg_composite_indexes` for
  # why they cannot ride along on the dump above. Keyed by physical table name.
  composite_idx_by_table = _pg_composite_indexes(db)
  # Colect all create instructions

  # println("-----------------------------------------")
  
  models_array::Vector{PormGModel} = []
  for (index, schema) in enumerate(eachrow(schemas))
    # println(schema |> typeof)
    # println(schema)
    # If include_table is specified, only include those tables
    if include_table !== nothing
      !any(included -> schema.table_name == included, include_table) && continue
    end
    _is_ignored_table(schema.table_name, ignore_table) && continue
    # println(typeof(schema), " ", convertSQLToModel(schema) |> println)

    model = convertSQLToModel(schema)
    # #347: attach this table's composite indexes. `model.name` IS the live table name on this path,
    # which is the key `_pg_composite_indexes` groups by.
    _attach_composite_indexes!(model, get(composite_idx_by_table, String(model.name), Pair{String, Vector{String}}[]))
    push!(models_array, model)
    # index > 4 && break
  end
  # println(models_array)
  # @pormg_debug 
  return models_array
end

function get_database_schema(db::PormGPostgres; schema::Union{String, Nothing} = "public", table::Union{String, Nothing} = nothing)
  # Get PostgreSQL version to check for attidentity support
  version_df = DataFrame(fetch(db, "SELECT split_part(version(), ' ', 2) AS version"))
  pg_version = version_df[1, :version]
  major_version = parse(Int, split(pg_version, ".")[1])
  
  # Build the identity case conditionally
  identity_case = if major_version >= 10
    """
            || CASE
                WHEN a.attidentity = 'a' THEN ' GENE_ALWAYS_IDENTITY'
                WHEN a.attidentity = 'd' THEN ' GENE_BY_DEF_IDENTITY'
                ELSE ''
               END
    """
  else
    ""
  end
  
  # Modified query that adds identity info (if supported) and checks single-column UNIQUE constraints
  query = """
    WITH unique_constraints AS (
        SELECT
            con.conrelid AS table_oid,
            array_agg(a.attname) AS unique_cols
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'u'
          -- #318: the single-column test belongs HERE, per CONSTRAINT — not on the aggregate below.
          -- This CTE groups by TABLE, so it merged every unique constraint's columns into ONE array:
          -- a table with two SEPARATE single-column UNIQUEs produced {slug, uuid_token}, and the
          -- consumer's `array_length(...) = 1` guard then rejected BOTH. Every such column
          -- introspected as `unique=false`, never matched its own declaration, and makemigrations
          -- proposed the same alteration forever.
          --
          -- Multi-column constraints stay excluded on purpose: PormG models composite uniqueness as
          -- a model-level UniqueConstraint (#19), never as a per-field `unique`, so marking a member
          -- column would churn in the opposite direction. `CREATE UNIQUE INDEX` — how #19 is
          -- materialized — has no pg_constraint row at all and is excluded for free.
          --
          -- Grouping by `con.oid` instead would be wrong: the CTE must stay ONE ROW PER TABLE, or the
          -- LEFT JOIN below fans out and every table yields N duplicate models.
          AND array_length(con.conkey, 1) = 1
        GROUP BY con.conrelid
    ),
    foreign_keys AS (
        SELECT
            con.conrelid,
            array_to_string(array_agg(quote_ident(att2.attname)), ', ') AS fk_cols,
            array_to_string(array_agg(quote_ident(cf.relname)), ', ') AS fk_tables,
            array_to_string(array_agg(quote_ident(pk_att.attname)), ', ') AS referenced_primary_keys,
            array_to_string(array_agg(con.condeferrable::text), ', ') AS deferrable,
            array_to_string(array_agg(con.condeferred::text), ', ') AS initially_deferred,
            -- #292: the referential action was never selected, so every introspected PostgreSQL FK
            -- came back claiming no ON DELETE. Single-char codes: a=NO ACTION, r=RESTRICT,
            -- c=CASCADE, n=SET NULL, d=SET DEFAULT. Aggregated in the same order as fk_cols so the
            -- zip in convertSQLToModel stays aligned.
            array_to_string(array_agg(con.confdeltype::text), ', ') AS delete_rules
        FROM pg_constraint con
        JOIN pg_attribute att2 ON att2.attnum = ANY(con.conkey) AND att2.attrelid = con.conrelid
        JOIN pg_class cf ON cf.oid = con.confrelid
        JOIN pg_namespace nf ON nf.oid = cf.relnamespace
        JOIN pg_index pk_idx ON pk_idx.indrelid = cf.oid AND pk_idx.indisprimary
        JOIN pg_attribute pk_att ON pk_att.attrelid = pk_idx.indrelid AND pk_att.attnum = ANY(pk_idx.indkey)
        WHERE con.contype = 'f'
        GROUP BY con.conrelid
    ),
    -- Secondary indexes, filtered down to exactly what `field.db_index = true` emits: ONE
    -- `CREATE INDEX` over ONE column (`planner._add_constrains` → `Dialect.create_index`). #325
    -- made this feed `db_index` on read-back, which the three added predicates are what makes
    -- safe — without them a model declaring only `unique=true` (or a composite `UniqueConstraint`,
    -- #19) would read back as `db_index=true` and churn in the opposite direction:
    --   * NOT indisunique — a UNIQUE constraint's backing index is `field.unique`, already read
    --     from `pg_constraint` by the `unique_constraints` CTE above. Keeps the backends symmetric
    --     with SQLite's `il."unique" = 0` filter.
    --   * indpred IS NULL — a partial index constrains rows, not the column; PormG cannot declare
    --     one, so reading it would be permanent churn.
    --   * indnkeyatts = 1 — a composite index marks no single column, mirroring #318's
    --     `HAVING COUNT(*) = 1` for composite UNIQUE.
    -- An expression index joins no `pg_attribute` row (its `indkey` entry is 0) and so drops out
    -- on its own.
    indexes AS (
        SELECT
            i.indrelid AS table_oid,
            array_to_string(array_agg(a.attname), ', ') AS index_columns,
            array_to_string(array_agg(quote_ident(c.relname)), ', ') AS index_names
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE NOT i.indisprimary
          AND NOT i.indisunique
          AND i.indpred IS NULL
          AND i.indnkeyatts = 1
        GROUP BY i.indrelid
    ),
    non_negative_checks AS (
        SELECT
            con.conrelid AS table_oid,
            array_agg(a.attname) AS check_cols
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'c'
          AND array_length(con.conkey, 1) = 1
          AND pg_get_constraintdef(con.oid) LIKE '%>= 0%'
        GROUP BY con.conrelid
    ),
    -- BinaryField byte bounds (#296). Unlike non_negative_checks this is per-COLUMN and carries a
    -- VALUE, because `max_length` is part of the field state the planner diffs — a boolean marker
    -- would leave every makemigrations proposing the same ALTER forever. `bytea` has no length
    -- parameter, so the CHECK is the only place the bound exists in the schema.
    byte_length_checks AS (
        SELECT
            con.conrelid AS table_oid,
            a.attname AS col_name,
            -- pg_get_constraintdef renders it as `CHECK ((octet_length(col) <= 4))`. Matching on
            -- digits after `<=` avoids backslash escapes surviving both Julia and SQL quoting.
            --
            -- `substring(… from …)` rather than `regexp_match`: the latter is PostgreSQL 10+, and
            -- this CTE sits in the schema query that EVERY introspection runs, so depending on it
            -- would break `makemigrations`/`inspectdb` wholesale on 9.x — not just for binary
            -- columns. `substring` with a capturing group returns the same first capture and has
            -- been available since long before any version this package targets.
            --
            -- min() collapses to ONE row per (table, column). This CTE is joined per-column, not
            -- per-table like non_negative_checks above, so without the GROUP BY two matching CHECKs
            -- on the same column (a hand-written extra bound, or a stale one) would fan the outer
            -- row out and emit that column twice into the string_agg — after which the recovered
            -- max_length would depend on row order, which is exactly the drift this CTE prevents.
            -- min() also picks the tightest bound, which is the one actually enforced.
            min(substring(pg_get_constraintdef(con.oid) from '<= ([0-9]+)')::bigint) AS byte_limit
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'c'
          AND array_length(con.conkey, 1) = 1
          AND pg_get_constraintdef(con.oid) LIKE '%octet_length%'
          AND pg_get_constraintdef(con.oid) ~ '<= [0-9]+'
        GROUP BY con.conrelid, a.attname
    )
    SELECT
        n.nspname AS table_schema,
        c.relname AS table_name,
        array_to_string(array_agg(
            quote_ident(a.attname)
            || ' ' || format_type(a.atttypid, a.atttypmod)
            || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
            || CASE WHEN ad.adbin IS NOT NULL THEN ' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid) ELSE '' END
            $(identity_case)
            -- #318: plain membership now. `unique_cols` already holds ONLY single-column constraints
            -- (filtered per-constraint in the CTE above), so the old `array_length(...) = 1` guard
            -- here was testing the wrong thing — the merged per-table array — and rejected every
            -- column on any table with more than one unique constraint. `unique_cols` is NULL when a
            -- table has none (LEFT JOIN) and `x = ANY(NULL)` is NULL, so this still falls through.
            || CASE WHEN a.attname = ANY(u.unique_cols) THEN ' UNIQUE' ELSE '' END
            || CASE
                WHEN nn.check_cols IS NOT NULL
                     AND a.attname = ANY(nn.check_cols) THEN ' NON_NEGATIVE_CHECK'
                ELSE ''
               END
            -- Space-delimited and comma-free by construction: the caller splits this aggregate on
            -- ", " to get columns and then on " " to get tokens, so a marker containing either
            -- separator would corrupt the parse.
            || CASE
                WHEN bl.byte_limit IS NOT NULL THEN ' BYTE_LIMIT_' || bl.byte_limit
                ELSE ''
               END
        ), ', ') AS columns,
        pk.pk_cols AS primary_keys,
        fk.fk_cols AS foreign_keys,
        fk.fk_tables AS foreign_tables,
        fk.referenced_primary_keys AS referenced_primary_keys,
        fk.deferrable AS deferrable,
        fk.initially_deferred AS initially_deferred,
        fk.delete_rules AS delete_rules,
        ix.index_columns AS index_columns,
        ix.index_names AS index_names
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    LEFT JOIN (
        SELECT i.indrelid, array_to_string(array_agg(quote_ident(a.attname)), ', ') AS pk_cols
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indisprimary
        GROUP BY i.indrelid
    ) pk ON pk.indrelid = c.oid
    LEFT JOIN foreign_keys fk ON fk.conrelid = c.oid
    LEFT JOIN indexes ix ON ix.table_oid = c.oid
    LEFT JOIN unique_constraints u ON u.table_oid = c.oid
    LEFT JOIN non_negative_checks nn ON nn.table_oid = c.oid
    LEFT JOIN byte_length_checks bl ON bl.table_oid = c.oid AND bl.col_name = a.attname
    WHERE c.relkind = 'r'
      $(schema === nothing ? "" : "AND n.nspname = '$(schema)'")
      $(table === nothing ? "" : "AND c.relname = '$(table)'")
      AND a.attnum > 0
      AND NOT a.attisdropped
    GROUP BY n.nspname, c.relname, pk.pk_cols, fk.fk_cols, fk.fk_tables, fk.referenced_primary_keys, fk.deferrable, fk.initially_deferred, fk.delete_rules, ix.index_columns, ix.index_names, u.unique_cols, nn.check_cols
    ORDER BY table_schema, table_name;
    """

  df = DataFrame(fetch(db, query))
  # @pormg_debug false
  if nrow(df) == 0
      @warn("No tables found in the database.")
  end

  # println(df)

  return df
end

function get_database_schema(;pickup::Union{PormGSQLite, PormGPostgres} = connection())  
  return get_database_schema(pickup)
end

function get_constraints_fk(conn::PormGPostgres, table_name::Symbol, field_name::String )
  query = """
  SELECT
      tc.constraint_name, kcu.column_name,
      ccu.table_name AS foreign_table_name,
      ccu.column_name AS foreign_column_name
  FROM 
      information_schema.table_constraints AS tc 
      JOIN information_schema.key_column_usage AS kcu
        ON tc.constraint_name = kcu.constraint_name
      JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_name = tc.constraint_name
  WHERE tc.table_name = '$table_name' AND tc.constraint_type = 'FOREIGN KEY' AND kcu.column_name = '$field_name';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

function get_constraints_index(conn::PormGPostgres, table_name::Symbol, field_name::String)
  query = """
  SELECT indexname
  FROM pg_indexes
  WHERE tablename = '$table_name' AND indexdef LIKE '%$field_name%';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :indexname]
end

function get_constraints_index(conn::PormGSQLite, table_name::Symbol, field_name::String)
  # table_name is Symbol like :migrationtest
  tname = string(table_name)
  idx_list = fetch(conn, "PRAGMA index_list(\"$tname\")") |> DataFrame
  if isempty(idx_list)
    return nothing
  end
  
  for row in eachrow(idx_list)
    idx_name = row.name
    idx_info = fetch(conn, "PRAGMA index_info(\"$idx_name\")") |> DataFrame
    if !isempty(idx_info) && field_name in idx_info.name
      return idx_name
    end
  end
  return nothing
end

# #151: probe the live schema for a UNIQUE index of ANY arity covering `field_name`. That covers the
# column-level UNIQUE auto-index (`sqlite_autoindex_…`, which `DROP INDEX` can't remove), a table-level
# `UNIQUE (a, b)`, and any `CREATE UNIQUE INDEX`. Such a column is refused by `ALTER TABLE DROP COLUMN`,
# so its deletion must route through a table rebuild (same remedy #116 uses for FK columns).
#
# STILL REQUIRED after #318 gave introspection a `unique` flag, and deliberately BROADER than it: this
# answers "would SQLite refuse to drop this column?", which is true for a composite-unique member and
# for a `CREATE UNIQUE INDEX` column — neither of which sets `field.unique`. Do not collapse the two.
function _sqlite_column_is_unique(conn::PormGSQLite, table_name, field_name::String)::Bool
  idx_list = fetch(conn, "PRAGMA index_list(\"$(string(table_name))\")") |> DataFrame
  isempty(idx_list) && return false
  for row in eachrow(idx_list)
    row.unique == 1 || continue
    idx_info = fetch(conn, "PRAGMA index_info(\"$(row.name)\")") |> DataFrame
    (!isempty(idx_info) && field_name in idx_info.name) && return true
  end
  return false
end

"""
    _sqlite_single_column_unique_columns(conn::PormGSQLite, table_name) -> Set{String}

Physical columns of `table_name` carrying a SINGLE-column `UNIQUE` **constraint** — exactly the set for
which `field.unique` must introspect back as `true` (#318).

`PRAGMA table_info` has no uniqueness column at all, so `convertSQLToModel(::PormGSQLite)` never
populated `unique`: every `unique=true` field compared unequal to its own live table and
`makemigrations` proposed the same rebuild forever.

Deliberately NARROWER than [`_sqlite_column_is_unique`](@ref) above, which answers the different
question `ALTER TABLE DROP COLUMN` asks. Two filters make the difference, and both are load-bearing:

  * `origin = 'u'` keeps only the auto-index SQLite creates for a `UNIQUE` clause inside
    `CREATE TABLE` — the one and only thing `field.unique` emits (`Dialect.field_to_column`). It
    excludes `origin = 'c'` (`CREATE UNIQUE INDEX`), which is how a model-level `UniqueConstraint`
    (#19) is materialized, and `origin = 'pk'` (a primary key is already an IDField). Arity alone is
    NOT enough here: a `UniqueConstraint` may name a single field, and marking that column would
    churn in the opposite direction. This also keeps the backends symmetric — PostgreSQL reads
    `pg_constraint` (`contype='u'`), which likewise cannot see a bare `CREATE UNIQUE INDEX`.
  * `HAVING COUNT(*) = 1` drops a table-level `UNIQUE (a, b)`, whose origin is also `'u'`.

`partial = 0` is belt-and-braces rather than load-bearing: SQLite only produces a partial index via
`CREATE INDEX … WHERE`, which is always `origin = 'c'` and therefore already excluded. Kept so the
predicate stays correct if that ever changes.

Known, accepted gap: a hand-written `CREATE UNIQUE INDEX` in a foreign schema introspects as
`unique=false`. Reading it would restore inspectdb fidelity at the cost of permanent churn for
single-field `UniqueConstraint` — the exact bug class #318 fixes.

ONE query per table (the table-valued-pragma idiom `get_secondary_index_ddls` also uses), not one probe
per column: callers test membership. An unknown table yields an empty set rather than throwing.
"""
function _sqlite_single_column_unique_columns(conn::PormGSQLite, table_name)::Set{String}
  rows = fetch(conn, """
    SELECT ii.name AS col
    FROM pragma_index_list(?) AS il
    JOIN pragma_index_info(il.name) AS ii
    WHERE il."unique" = 1 AND il.origin = 'u' AND il.partial = 0
    GROUP BY il.name
    HAVING COUNT(*) = 1
    """, [string(table_name)]) |> DataFrame
  # An empty frame's column is eltype Missing, so guard before touching `rows.col`.
  nrow(rows) == 0 && return Set{String}()
  return Set{String}(string(c) for c in rows.col if c !== missing)
end

"""
    _sqlite_single_column_indexed_columns(conn::PormGSQLite, table_name) -> Dict{String, String}

Physical column ⇒ index name, for every SINGLE-column non-unique secondary index on `table_name` —
exactly the set for which `field.db_index` must introspect back as `true` (#325).

The `unique` sibling above and this one are the same shape for the same reason: `PRAGMA table_info`
carries neither attribute, so `convertSQLToModel(::PormGSQLite)` never populated `db_index` at all.
Every `db_index=true` field therefore compared unequal to its own live table, and — because
`Dialect.alter_field` has no `db_index` branch — `makemigrations` proposed a rebuild that emitted no
DDL for it, forever. `src/migrations/planner.jl` carried a workaround for one symptom of this
(a duplicated `CREATE INDEX`); the cause is here.

The three filters mirror the `unique` reader's, each excluding an index that is NOT `db_index`:

  * `il."unique" = 0` — a UNIQUE index is `field.unique`, read by
    [`_sqlite_single_column_unique_columns`](@ref). Marking it here would make a model declaring
    only `unique=true` churn in the opposite direction. Symmetric with PostgreSQL's
    `NOT i.indisunique`.
  * `il.origin = 'c'` — only a `CREATE INDEX`, which is the one and only thing `db_index=true`
    emits (`planner._add_constrains` → `Dialect.create_index`). Excludes `'u'` (a `UNIQUE` clause's
    auto-index) and `'pk'`.
  * `HAVING COUNT(*) = 1` — a composite index marks no single column, exactly as for composite
    UNIQUE (#318). PormG only ever indexes one column per `db_index`.

`il.partial = 0` IS load-bearing here, unlike in the `unique` reader: a partial index is created by
`CREATE INDEX … WHERE` and so shares this reader's `origin = 'c'`. It constrains rows rather than
the column, PormG cannot declare one, and reading it would be permanent churn.

Returns the index NAME as well as the column because the planner needs it to drop an index the model
no longer declares (`model.cache["index"]`); the PostgreSQL path builds the same mapping from its
`indexes` CTE. ONE query per table; an unknown table yields an empty dict rather than throwing.
"""
function _sqlite_single_column_indexed_columns(conn::PormGSQLite, table_name)::Dict{String, String}
  rows = fetch(conn, """
    SELECT MIN(ii.name) AS col, il.name AS idx
    FROM pragma_index_list(?) AS il
    JOIN pragma_index_info(il.name) AS ii
    WHERE il."unique" = 0 AND il.origin = 'c' AND il.partial = 0
    GROUP BY il.name
    HAVING COUNT(*) = 1
    """, [string(table_name)]) |> DataFrame
  # An empty frame's columns are eltype Missing, so guard before touching them.
  nrow(rows) == 0 && return Dict{String, String}()
  out = Dict{String, String}()
  for r in eachrow(rows)
    (r.col === missing || r.idx === missing) && continue
    # First index wins if two single-column indexes cover the same column — the duplicate is
    # redundant, and `db_index` is a boolean either way.
    get!(out, string(r.col), string(r.idx))
  end
  return out
end

"""
    _attach_composite_indexes!(model, idxs) -> model

Stash introspected composite indexes (#347) on `model` under the same cache key
`Models._apply_indexes!` writes, so `Model_to_str` re-emits them as `indexes = [Models.Index(…)]` and
an `inspectdb` of a live database no longer drops every multi-column index it finds.

Shared by both backend readers, which is the whole point: the SQLite and PostgreSQL sides produce the
same `index_name => ordered physical columns` shape and hand it here.

Deliberately NOT routed through `Models._apply_indexes!`. That function is the *declaration* guard and
raises `ModelDefinitionError` on anything it cannot accept — which on this path would abort the
introspection of an entire table over one odd index. Introspection is best-effort by convention
(`convertSQLToModel` degrades a field it cannot read rather than throwing), so an index this model
cannot express is skipped with a `@debug` and the rest of the table still comes back. Two ways that
happens, both real:

  * a column the field reader did not produce (it degraded, or the index covers a dropped column);
  * a column name `format_fild_name` rejects — `a__b` (the lookup separator) or one containing `@`.
    A live PostgreSQL schema can legally have either.

The cache is written only when at least one index survives, so a table with none is byte-identical to
before this existed.
"""
function _attach_composite_indexes!(model, idxs::Vector{Pair{String, Vector{String}}})
  isempty(idxs) && return model
  kept = Models.Index[]
  for (idx_name, cols) in idxs
    if !all(c -> haskey(model.fields, c), cols)
      @debug "introspection: composite index skipped — column not on the introspected model" table=model.name index=idx_name columns=cols
      continue
    end
    ix = try
      Models.Index(fields = cols, name = idx_name)
    catch e
      e isa ModelDefinitionError || rethrow()
      @debug "introspection: composite index skipped — PormG cannot name it" table=model.name index=idx_name columns=cols exception=e
      continue
    end
    push!(kept, ix)
  end
  isempty(kept) || (model.cache["composite_indexes"] = Dict{String, Any}("indexes" => kept))
  return model
end

"""
    _sqlite_composite_indexes(conn::PormGSQLite, table_name) -> Vector{Pair{String, Vector{String}}}

Every MULTI-column non-unique secondary index on `table_name`, as `index_name => ordered columns` —
exactly what a model-level `Models.Index` (#347) materializes, and the mirror image of
[`_sqlite_single_column_indexed_columns`](@ref) above.

The three `WHERE` filters are that function's, unchanged and load-bearing for the same reasons
(`il."unique" = 0` keeps `field.unique` and a composite `UniqueConstraint` out; `il.origin = 'c'`
keeps a `UNIQUE` clause's auto-index and the primary key out; `il.partial = 0` keeps a
`CREATE INDEX … WHERE` out, which PormG cannot declare). Only the arity flips: `> 1` column here,
`= 1` there — so the two readers partition the same index set and no index feeds both `db_index` and
an `Index`.

Three things this reader needs that the single-column one does not:

  * **Column ORDER is part of the index.** An index over `(raceid, lap)` is not the index over
    `(lap, raceid)`, so the columns come back ordered by `seqno` rather than aggregated.
    `MIN(ii.name)` was fine for arity 1; here it would silently reorder the declaration.
  * **`pragma_index_xinfo`, not `index_info`.** `xinfo` carries three columns `info` does not, and
    each gates an index PormG cannot reproduce. `key = 1` drops the rowid/PK columns SQLite appends
    to every index — they are not part of the declaration.
  * **Anything PormG cannot re-emit is dropped WHOLE, never partially.** Emitting a subset, or the
    same columns under different semantics, would declare a *different* index under the developer's
    name — the same reject-rather-than-reinterpret rule the Django importer applies to
    `Meta.indexes`. Three shapes qualify:
      - an **expression** member (`lower(name)`) has a NULL `ii.name` — functional indexes are #29;
      - a **descending** member (`"desc" = 1`) — PormG indexes carry no per-column order, and the
        importer already *refuses* Django's `Index(fields=["-year"])` for exactly this reason;
      - a non-**BINARY** collation (`COLLATE NOCASE`) — a different comparison, so a different index.

ONE query per table; an unknown table yields an empty vector rather than throwing.
"""
function _sqlite_composite_indexes(conn::PormGSQLite, table_name)::Vector{Pair{String, Vector{String}}}
  rows = fetch(conn, """
    SELECT il.name AS idx, ii.name AS col, ii."desc" AS is_desc, ii.coll AS coll
    FROM pragma_index_list(?) AS il
    JOIN pragma_index_xinfo(il.name) AS ii
    WHERE il."unique" = 0 AND il.origin = 'c' AND il.partial = 0 AND ii."key" = 1
    ORDER BY il.name, ii.seqno
    """, [string(table_name)]) |> DataFrame
  # An empty frame's columns are eltype Missing, so guard before touching them.
  nrow(rows) == 0 && return Pair{String, Vector{String}}[]
  # `nothing` marks a member PormG cannot express; the whole index is then skipped below.
  grouped = OrderedDict{String, Vector{Union{String, Nothing}}}()
  for r in eachrow(rows)
    r.idx === missing && continue
    unusable = r.col === missing ||                                    # expression member
               (r.is_desc !== missing && r.is_desc != 0) ||            # DESC member
               (r.coll !== missing && uppercase(string(r.coll)) != "BINARY")   # non-default collation
    push!(get!(grouped, string(r.idx), Union{String, Nothing}[]), unusable ? nothing : string(r.col))
  end
  out = Pair{String, Vector{String}}[]
  for (idx, cols) in grouped
    length(cols) > 1 || continue                 # arity 1 is `db_index`, read by the sibling above
    any(c -> c === nothing, cols) && continue    # a member PormG cannot re-emit ⇒ drop it whole
    push!(out, idx => String[String(c) for c in cols])
  end
  return out
end

"""
    get_secondary_index_ddls(conn::PormGSQLite, table_name) -> Vector{String}

Return the `CREATE INDEX` DDL for every *user-created* secondary index on `table_name`, verbatim from
`sqlite_master`. Auto-indexes backing column-level `UNIQUE` constraints have a NULL `sql` and are excluded —
they are recreated automatically by the rebuilt `CREATE TABLE`. Used by the SQLite table-rebuild path to
re-create the indexes that the rebuild's `DROP TABLE` would otherwise silently lose (#82).

`column_renames` (old ⇒ new physical name) supports the rename-with-FK-change rebuild (#150): the DDL is
snapshotted from the LIVE schema at planning time (old column name), but the rebuilt table carries the new
name, so each renamed column is mapped through this dict both when testing `surviving_columns` membership
(else the renamed column's index would be wrongly filtered out and lost) and when rewriting the emitted DDL.
Default empty ⇒ no rewriting, so every existing #82/#116 call site is unaffected.
"""
function get_secondary_index_ddls(conn::PormGSQLite, table_name::Union{String,Symbol};
                                  surviving_columns::Union{Nothing,Set{String}} = nothing,
                                  column_renames::Dict{String,String} = Dict{String,String}())::Vector{String}
  tname = replace(string(table_name), "'" => "''")
  # `name` is fetched alongside `sql` so we can probe each index's columns via pragma_index_info
  # when filtering (#116). Auto-created indexes (UNIQUE/PK) carry a NULL `sql` and are excluded here,
  # exactly as before — they belong to the CREATE TABLE the rebuild already re-emits.
  rows = fetch(conn, "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = '$(tname)' AND sql IS NOT NULL") |> DataFrame
  isempty(rows) && return String[]
  ddls = String[]
  for r in eachrow(rows)
    s = r.sql
    s === missing && continue
    stmt = strip(string(s))
    isempty(stmt) && continue
    # #116: when the caller is rebuilding a table with columns removed (FK-field deletion), an index on a
    # dropped column must NOT be re-created — SQLite would raise "no such column". `pragma_index_info`
    # gives the index's exact indexed-column membership (robust vs. substring-matching the DDL text); drop
    # the index if any of its columns is no longer present in the rebuilt table. No filtering when the
    # kwarg is `nothing`, so every existing rebuild call site keeps its current behavior.
    #
    # Known limitation: `pragma_index_info` reports NULL for an *expression* column and does not list a
    # *partial* index's WHERE-clause columns, so a user-created expression/partial index over a dropped
    # column would slip through and fail the rebuild. Accepted for #116: PormG only ever emits plain
    # single/multi-column indexes (create_index in Dialect.jl), which pragma_index_info covers exactly.
    if surviving_columns !== nothing
      idxname = replace(string(r.name), "'" => "''")
      cols = fetch(conn, "SELECT name FROM pragma_index_info('$(idxname)')") |> DataFrame
      # #150: the live index references the OLD column name; map it to the rebuilt table's new name
      # before the membership test so a renamed-but-surviving column keeps its index.
      referenced = String[get(column_renames, string(c), string(c)) for c in cols.name if c !== missing]
      any(c -> !(c in surviving_columns), referenced) && continue
    end
    # #150: rewrite renamed columns in the snapshotted DDL. PormG emits quoted identifiers
    # (create_index in Dialect.jl), so replacing the quoted `"old"` token is precise — it can't
    # touch the index name or table name. Empty dict ⇒ no-op for the #82/#116 call sites.
    for (oldc, newc) in column_renames
      stmt = replace(stmt, "\"$oldc\"" => "\"$newc\"")
    end
    push!(ddls, endswith(stmt, ";") ? stmt : stmt * ";")
  end
  return ddls
end

# `table_name::String` — NOT Symbol. This was the odd one out of the four `get_constraints_*`
# helpers, and since `alter_field`'s model-based overload always resolves the table to
# `model.name |> lowercase` (a String), a Symbol signature could never be dispatched to (#283).
function get_constraints_pk(conn::PormGPostgres, table_name::String, field_name::String)
  # Joins carry `table_schema` as well as `constraint_name`: constraint names are unique per
  # SCHEMA, not per database, so joining on the name alone can splice rows from a same-named
  # table in another schema and return a constraint that does not exist on the table the DDL
  # targets. Same shape as get_constraints_check below, which is the exercised sibling. This
  # query was unreachable until #283 (its only caller passed the wrong arity), so it had never
  # run to expose the defect.
  # Filters on `tc.table_name` rather than `ccu.table_name` — `tc` IS the constrained table.
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
  WHERE tc.table_name = '$table_name'
    AND tc.constraint_type = 'PRIMARY KEY'
    AND kcu.column_name = '$field_name';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Returns `nothing` when no UNIQUE constraint matches — the annotation must admit it, or Julia
# converts the `return nothing` below and raises instead of letting callers test it (#284).
#
# #325: the SINGLE-column UNIQUE on `field_name`, and nothing else. The caller is
# `Dialect.alter_field`, dropping a constraint because the model stopped declaring `unique=true` —
# and `field.unique` is only ever read back from a single-column constraint (#318), so a composite
# one must never be droppable through this path. It was: the query matched every constraint the
# column merely *belongs to* and returned `result[1, …]` from an unordered result, so a column in
# both `UNIQUE(a)` and `UNIQUE(a, b)` dropped whichever row PostgreSQL happened to return first.
#
# Three changes make that deterministic:
#   * `key_column_usage`, not `constraint_column_usage` — the former lists a constraint's OWN
#     columns, which is what lets `COUNT(*) = 1` mean "single-column constraint". (The latter is
#     equivalent for UNIQUE, but only by accident of PostgreSQL's implementation; the sibling
#     `get_constraints_pk` above already uses `kcu`.)
#   * `GROUP BY` + `HAVING COUNT(*) = 1` — the arity filter, mirroring the CTE #318 added.
#   * `ORDER BY` — with the arity filter two matches are already pathological (two single-column
#     UNIQUEs on the same column), but "whichever came first" is not an answer.
#
# Parameterized and search-path-restricted, like `get_constraints_byte_length_check` below; the
# unparameterized siblings predate the rule and are left alone, but an edited query does not
# inherit the exemption.
function get_constraints_unique(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
  WHERE tc.table_name = \$1
    AND tc.constraint_type = 'UNIQUE'
    AND tc.table_schema = ANY(current_schemas(false))
  GROUP BY tc.constraint_name, tc.table_schema
  HAVING COUNT(*) = 1 AND bool_or(kcu.column_name = \$2)
  ORDER BY tc.constraint_name, tc.table_schema;
  """
  result = fetch(conn, query, [table_name, field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Find the non-negative CHECK constraint backing a positive integer column.
# PostgreSQL has no unsigned integer type, so PormG enforces `col >= 0` with a
# CHECK constraint; on a type transition away from a positive integer field the
# migration engine needs the constraint's auto-generated name to drop it. We
# match by column and the `>= 0` clause rather than assuming a name, so it works
# even for constraints PormG created anonymously at CREATE TABLE time. Returns
# `nothing` when no such constraint exists.
function get_constraints_check(conn::PormGPostgres, table_name::String, field_name::String)
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
  JOIN information_schema.check_constraints cc
    ON cc.constraint_name = tc.constraint_name AND cc.constraint_schema = tc.constraint_schema
  WHERE tc.table_name = '$table_name'
    AND tc.constraint_type = 'CHECK'
    AND ccu.column_name = '$field_name'
    AND cc.check_clause ILIKE '%>= 0%';
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Find the byte-length CHECK backing a bounded BinaryField (#296) — the `octet_length` sibling of
# `get_constraints_check` above. `bytea` takes no length parameter, so `max_length` can only be a
# CHECK, and on a transition away from a bounded BinaryField the migration engine needs the
# auto-generated name to drop it. Matched on the clause rather than the name, for the same reason.
#
# Deliberately a separate generic rather than a parameter on `get_constraints_check`: a table can
# carry both kinds, and matching the wrong one would drop a live constraint.
function get_constraints_byte_length_check(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  # Parameterized, unlike the `get_constraints_*` siblings above, which interpolate. Those predate
  # the parameterized-queries-only rule and are left alone here; a new query has no excuse to
  # inherit the pattern, and both values land inside single-quoted literals where an embedded `'`
  # would break out.
  #
  # `table_schema` is restricted to the search path: an unqualified table name in the DDL this
  # feeds resolves the same way, so without it a same-named table in another schema can hand back
  # a constraint name that does not exist on the target table, and the ALTER then fails.
  #
  # Residual ambiguity, deliberately left: a *hand-written* CHECK using `octet_length` on the same
  # column is indistinguishable from PormG's own by clause alone. Matching the auto-generated name
  # instead would be worse — the name is not stable across the paths that create it.
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
  JOIN information_schema.check_constraints cc
    ON cc.constraint_name = tc.constraint_name AND cc.constraint_schema = tc.constraint_schema
  WHERE tc.table_name = \$1
    AND tc.constraint_type = 'CHECK'
    AND ccu.column_name = \$2
    AND tc.table_schema = ANY(current_schemas(false))
    AND cc.check_clause ILIKE '%octet_length%'
    AND cc.check_clause ~ '<= [0-9]+';
  """
  result = fetch(conn, query, [table_name, field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Same empty-result contract as `get_constraints_unique` above (#284).
function get_sequence_name(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  query = """
  SELECT pg_get_serial_sequence('$table_name', '$field_name');
  """
  result = fetch(conn, query) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :pg_get_serial_sequence]
end

function convertSQLToModel(row::DataFrameRow{DataFrame, DataFrames.Index}; type_map::Dict{String, Symbol} = postgres_type_map)
  table_name = row[:table_name]
  columns = split(row[:columns], ", ")
  # println("Table Name: ", table_name)
  # println("Columns: ", columns)
  # println("Row", row)
    
  # Initialize fields dictionary
  fields_dict = Dict{String, PormGField}()

  # Extract primary key constraints
  # row[:primary_keys] is missing for keyless tables (e.g., Lap_times, Pit_stops that have no IDField)
  pk_set = ismissing(row[:primary_keys]) ? Set{String}() : Set(split(row[:primary_keys], ", "))
    
  # Extract foreign key constraints
  # Widened past `(table, pk)` for #292 to carry the referential action, which the schema query
  # never selected — so every introspected FK claimed no ON DELETE and a migration generated from
  # it silently dropped the action from the schema.
  fk_map = Dict{String, NamedTuple{(:table, :pk, :on_delete), Tuple{String, String, Union{String, Nothing}}}}()
  if row[:foreign_keys] |> !ismissing
    fk_columns = split(row[:foreign_keys], ", ")
    fk_tables = split(row[:foreign_tables], ", ")
    fk_pk_columns = split(row[:referenced_primary_keys], ", ")
    # `delete_rules` is absent on a schema-query result produced before #292 (and on the synthetic
    # rows some unit tests build), so degrade to "no action recorded" rather than throwing.
    delete_rules = (:delete_rules in propertynames(row) && !ismissing(row[:delete_rules])) ?
      split(row[:delete_rules], ", ") : fill("", length(fk_columns))
    for (i, (fk_col, fk_table, fk_pk)) in enumerate(zip(fk_columns, fk_tables, fk_pk_columns))
        rule = i <= length(delete_rules) ? delete_rules[i] : ""
        fk_map[fk_col] = (table = String(fk_table), pk = String(fk_pk),
                          on_delete = _pg_confdeltype_to_on_delete(rule))
    end
  end

  # Extract index information — physical column ⇒ index name, for the single-column secondary
  # indexes the `indexes` CTE keeps. Both halves are stored UNQUOTED (#325): the key has to match
  # `fields_dict`, which is keyed by the de-quoted column name below, and the value is re-quoted by
  # `_drop_index`. A mixed-case name (#57) arrived here wrapped in `"` and matched neither.
  index_map = Dict{String, String}()
  if !ismissing(row[:index_columns])
    indexes = split(row[:index_columns], ", ")
    index_names = split(row[:index_names], ", ")
    for (index, index_name) in zip(indexes, index_names)
      index_map[replace(index, "\"" => "")] = replace(index_name, "\"" => "")
    end
  end
   
  # Parse each column definition
  for col in columns    
      col_parts = split(replace(col, "double precision" => "double_precision")
      , " ")
      col_name = col_parts[1]
      col_type = lowercase(col_parts[2])
      generated::Bool = false
      max_length = nothing
      max_digits = nothing
      decimal_places = nothing

      # Detect if the column is indexed. #325: this probed a `Dict{String,String}` with a `Symbol`
      # key, which `haskey` never matches — so `db_index` was a hard `false` for every plain
      # PostgreSQL column, and every `db_index=true` field re-proposed its own CREATE INDEX on every
      # `makemigrations`. `col_name` is de-quoted to match `index_map`'s keys.
      db_index = haskey(index_map, replace(String(col_name), "\"" => ""))

      @pormg_debug false

      # Extract max_length if it exists
      if occursin(r"varchar\((\d+)\)", col_type) || occursin(r"char\((\d+)\)", col_type) 
        max_length_match = match(r"\((\d+)\)", col_type)
        if max_length_match !== nothing
          max_length = parse(Int, max_length_match.captures[1])
          col_type = "varchar"
        end
      elseif occursin(r"character varying\((\d+)\)", col)
        max_length_match = match(r"character varying\((\d+)\)", col)
        if max_length_match !== nothing
          max_length = parse(Int, max_length_match.captures[1])
          col_type = "varchar"
        end
      elseif col_type == "bytea"
        # A BinaryField's byte bound lives in its CHECK, not in the column type — the schema query
        # surfaces it as a BYTE_LIMIT_<n> marker (#296).
        byte_limit_match = match(r"BYTE_LIMIT_(\d+)", col)
        if byte_limit_match !== nothing
          max_length = parse(Int, byte_limit_match.captures[1])
        end
      end

      # Extract max_digits and decimal_places if it exists
      if occursin(r"decimal\((\d+),(\d+)\)", col_type) || occursin(r"numeric\((\d+),(\d+)\)", col_type)
        decimal_match = match(r"\((\d+),(\d+)\)", col_type)
        if decimal_match !== nothing
          max_digits = parse(Int, decimal_match.captures[1])
          decimal_places = parse(Int, decimal_match.captures[2])
          col_type = "decimal"
        end
      end
      
      # Determine field type. format_type() reports a PositiveIntegerField column as
      # plain "integer", so the schema query appends a NON_NEGATIVE_CHECK marker when
      # the column carries a `>= 0` CHECK constraint — that marker is what tells a
      # PositiveIntegerField apart from an IntegerField on round-trip.
      field_type = getfield(Models, haskey(type_map, col_type) ? type_map[col_type] : :TextField)
      if col_type == "integer" && occursin("NON_NEGATIVE_CHECK", col)
        field_type = Models.PositiveIntegerField
      end
      
      # Determine field constraints
      primary_key::Bool = col_name in pk_set
      # #318: token match, not a substring test. `col` is the whole rendered column string, so
      # `occursin` also fired on a column *named* `UNIQUE_CODE` (mixed-case names are supported, #57)
      # or a `DEFAULT 'UNIQUE'` literal — inventing uniqueness that would then be diffed forever.
      # The CTE appends ' UNIQUE' as its own space-separated token, so membership is exact.
      unique::Bool = "UNIQUE" in col_parts
      not_null::Bool = occursin("NOT NULL", col)
      default_value = nothing
      if occursin("DEFAULT", col)
        # Match DEFAULT followed by value, handling type casts like ::numeric
        default_match = match(r"DEFAULT\s+((?:\([^)]+\)|[^:\s]+)(?:::[a-zA-Z_]+)?)", col)
        if default_match !== nothing
          raw_default = default_match.captures[1]
          # Clean up the default value: remove type casts and parentheses for simple values
          # e.g., "(0)::numeric" -> "0", "'value'::text" -> "value"
          # TODO: store the type cast if necessary
          cleaned_default = replace(raw_default, r"::[a-zA-Z_]+" => "")  # Remove type cast
          cleaned_default = replace(cleaned_default, r"^\((.+)\)$" => s"\1")  # Remove outer parentheses
          cleaned_default = replace(cleaned_default, r"^'(.+)'$" => s"\1")  # Remove quotes
          default_value = cleaned_default
        end
      end

      # A bytea DEFAULT survives the cleanup above as PostgreSQL's hex text (`\x0102`), and
      # `BinaryField(default = <String>)` raises — so without this, introspecting any BLOB column
      # that has a DEFAULT would abort the schema read (#296). Same import-layer normalization as
      # `_normalize_sqlite_default`; an unrecognized literal degrades to "no default".
      if default_value !== nothing && field_type === Models.BinaryField
        default_value = _pg_bytea_literal_bytes(default_value)
      end
      if primary_key
        if occursin("GENE_BY_DEF_IDENTITY", col)
          generated = true
          generated_always = false
        elseif occursin("GENE_ALWAYS_IDENTITY", col)
          generated = true
          generated_always = true
        else 
          generated = false
          generated_always = false
        end
      end

      # @pormg_debug col == "qt_referencia bigint DEFAULT (0)::numeric"

      # println(col)

      # Create field instance
      field = if primary_key && col_type == "uuid"
          # #334: a UUID primary key is the ONE non-integer pk type this reader can safely
          # reconstruct as its real field type. Force-converting EVERY primary key to IDField
          # (the `elseif primary_key` branch below) silently discarded it, so `makemigrations`
          # proposed re-typing it back to bigint on every single run against a model that never
          # declared an IDField at all. No existing fixture exercised a UUID primary key before
          # #334, which is why this went unnoticed. Deliberately NOT generalized to "any
          # non-integer pk": `test_introspection_guards.jl` pins IDField as the correct fallback
          # for a VARCHAR/NUMERIC primary key specifically BECAUSE those can crash otherwise — a
          # `NUMERIC` pk parsed as `DecimalField(primary_key=true)` refuses construction outright
          # (`models/fields.jl`, "DecimalField cannot be used as a Primary Key"), and a VARCHAR pk
          # would try to assign `max_length` onto whatever field resulted. `UUIDField` carries
          # neither hazard: no `max_length`/`max_digits`, and `primary_key=true` is always legal.
          # `db_index` is the literal `true`, not the `db_index` variable, matching the IDField
          # branch: the `indexes` CTE above explicitly excludes primary-key indexes
          # (`NOT i.indisprimary`), so `db_index` would read back `false` for any primary key.
          #
          # `unique` is the COMPUTED local variable here, deliberately NOT the literal `true` the
          # IDField branch hardcodes. IDField's own constructor defaults `unique=true`, so hardcoding
          # it there always agrees with a plain `IDField()` declaration; UUIDField's constructor
          # defaults `unique=false` (uniqueness on a pk column comes from the PRIMARY KEY constraint
          # itself, not a separate `UNIQUE` one), so a declared `UUIDField(primary_key=true, ...)`
          # with no explicit `unique=true` would otherwise permanently disagree with a hardcoded
          # `true` here — the primary-key branch of `_NON_SCHEMA_FIELD_ATTRS`'s comparison (above in
          # `planner.jl`) has no exception for `:unique`, so that mismatch alone would keep
          # `makemigrations` proposing an alteration regardless of the `:auto_add` exemption below.
          Models.UUIDField(primary_key=true, unique=unique, null=false, db_index=true, default=default_value)
      elseif primary_key
          Models.IDField(generated=generated, generated_always=generated_always, unique=true, null=false, db_index=true)
      elseif haskey(fk_map, col_name)
        fk_info = fk_map[col_name]
        # #338: same binding-collision caveat as the other FK introspection paths in this file.
        fk_table = uppercasefirst(fk_info.table)
        fk_column = fk_info.pk
        # #292: `on_delete` is now carried (it was never even queried), and `default_value` goes
        # through the shared failure policy — this branch passed it unguarded, so a column default
        # that cannot be an Int64 raised FieldValidationError from inside introspection.
        # `OneToOneField` had the identical omission and is fixed with `ForeignKey`.
        fk_default = _fk_default_or_warn(default_value, table_name, col_name)
        fk_on_delete = _normalize_introspected_on_delete(fk_info.on_delete)
        if unique
          Models.OneToOneField(fk_table, pk_field=fk_column, null=!not_null, default=fk_default, on_delete=fk_on_delete, db_index=true)
        else
          Models.ForeignKey(fk_table, pk_field=fk_column, null=!not_null, default=fk_default, on_delete=fk_on_delete, db_index=true)
        end
      else
        field_type(unique=unique, null=!not_null, default=default_value, db_index=db_index)
      end

      # Only fields that actually carry these attributes get them. A primary-key column
      # is mapped to an IDField (above), which has no max_length/max_digits — guard the
      # assignments so such columns don't raise FieldError during introspection.
      # #325: unconditional. This used to retype any `varchar(n > 255)` to TextField and DROP the
      # length, because CharField refused a max_length above 255 — so a live `varchar(500)` read
      # back as `text`, never matched the model that declared it, and `makemigrations` proposed the
      # same widening on every run. CharField no longer carries that ceiling (models/fields.jl), so
      # `varchar(n)` now always round-trips as `CharField(n)`, symmetric with `text` ⇒ `TextField`.
      # (The sBinaryField branch that used to sidestep the ceiling for byte bounds, #296, is what
      # this generalizes.)
      if max_length !== nothing && hasfield(typeof(field), :max_length)
        field.max_length = max_length
      end

      if max_digits !== nothing && hasfield(typeof(field), :max_digits)
        field.max_digits = max_digits
        field.decimal_places = decimal_places
      end
      
      # Add field to fields dictionary
      fields_dict[replace(col_name, "\"" => "")] = field
  end

  # Construct and return the model
  # check if index_map is empty
  model_resp = Models.Model(table_name, fields_dict)
  # #347: writes the one KEY rather than assigning the whole `cache` field — `convert_schema_to_models`
  # attaches composite indexes onto the same dict afterwards, so a whole-field assign here would make
  # the two writers order-dependent. Same change as the SQLite reader above; defensive, not a fix.
  if !isempty(index_map)
    model_resp.cache["index"] = index_map
  end
  @pormg_debug false
  return model_resp

end