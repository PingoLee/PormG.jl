# ── Field-validation throw funnel (#239) ────────────────────────────────────
# Every failure in this file is one category: the caller got a field CONSTRUCTOR argument wrong —
# a kwarg of the wrong type, an out-of-range `max_length`, a `default` that violates the field's
# own contract, a malformed `choices`, or a field type that cannot serve as a primary key. So a
# call site changes only `ArgumentError(` → `_fielderr(` and lands on `FieldValidationError`.
# It lives here rather than in `querybuilder/error_funnels.jl` because it is used by exactly this
# file — that is the placement rule stated in that file's header. The constructor applies `_emsg`, so
# messages degrade correctly off-TTY without a second wrap.
#
# NOT for value coercion: `Models.format_*_sql` raises `InvalidValueError`, because there the
# caller is inserting a bad *value* rather than defining a bad *field*. Where a constructor calls
# one of those helpers on a `default=` (UUIDField/JSONField/DurationField), it re-raises as
# FieldValidationError so the whole constructor surface reports one category.
_fielderr(msg::AbstractString) = FieldValidationError(msg)

# ── BinaryField `default=` helpers (#296) ───────────────────────────────────
# `_binary_default_bytes` is handed to `validate_default`, which only calls it when the value is
# not already `Union{Vector{UInt8}, Nothing}` — so it normalizes the other byte-vector spellings
# (`codeunits`, reinterpreted buffers, views) into a plain `Vector{UInt8}`. It must throw rather
# than return a wrong type: `validate_default` does not re-check its converter's result, and
# before #296 that hole let a `Vector{UInt8}` through into a `Union{String,Nothing}` field,
# surfacing as a raw `MethodError` outside the error taxonomy.
#
# `BinaryField` rejects non-byte defaults itself, before calling `validate_default`, so that this
# message survives — `validate_default`'s bare `catch` would otherwise replace it.
# Composes the MESSAGE, not the exception: the call sites throw `_fielderr(...)` themselves, which
# is the convention `test_docs_error_type_drift.jl` pins — a helper that merely maps a message to a
# type is an alias, not an abstraction, and hiding the `throw` inside invites the mirror-image
# mistake at a returning funnel.
function _binary_default_message(value)::String
  # A String gets the extra sentence: it is the near-miss worth explaining, because the write path
  # DOES accept one and the two plausible readings (its own bytes vs. a decoded encoding) disagree.
  hint = value isa AbstractString ?
    " A String is not accepted here because its meaning is ambiguous — pass " *
    "`Vector{UInt8}(codeunits(s))` for the text's own bytes, or `hex2bytes(s)` / " *
    "`base64decode(s)` to store the decoded payload." : ""
  return "BinaryField: 'default' must be a Vector{UInt8} or nothing, got $(typeof(value)).$hint"
end

function _binary_default_bytes(value)
  value isa AbstractVector{UInt8} && return collect(UInt8, value)
  throw(_fielderr(_binary_default_message(value)))
end

# ── Common keyword handling (#260) ──────────────────────────────────────────
# Every field constructor used to open with the same four blocks copy-pasted: an `accepted` Set, an
# unexpected-keyword `@warn` loop, a `get(kwargs, :x, default)` per keyword, and a type guard per
# keyword. Across 27 constructors that was 27 accepted-sets, 27 warn loops, 254 extractions and 187
# guards — roughly a fifth of this file, and the reason a single wording fix had to be applied by hand
# in 26 places (which is how three different messages for the same check arose).
#
# `_common_kwargs` does all four jobs once and returns the extracted values.
#
# ## Defaults are NOT uniform — this is the part that bites
#
# Four keywords carry a different default in some constructors, so the helper takes overrides rather
# than assuming the majority:
#
#     unique       true in IDField, OneToOneField, AutoField
#     db_index     true in IDField, OneToOneField, SlugField
#     editable     true in CharField, PasswordField, FileField, UUIDField, URLField, SlugField, JSONField
#     primary_key  true in IDField, AutoField      (`nothing` = the constructor does not accept it)
#
# Passing them explicitly makes each deviation visible at the call site, where previously it hid
# inside a `get(kwargs, …)` line identical to its neighbours. `test_field_kwargs_equivalence.jl`
# pins every constructor's resulting struct against a frozen snapshot, so a flipped default fails
# loudly instead of silently.
#
# ## Contract: accepted keyword NAMES are frozen
#
# `Model_to_str` generates model files that reload through this kwargs form (see the round-trip seam
# at `Models.jl`'s `Model(name; fields...)`), so this helper may reorganize validation but must never
# rename, add or drop an accepted keyword.
#
# ## Validation order (deliberate)
#
# Common keywords validate first (in `_COMMON_FIELD_KWARGS` order), then the constructor's declared
# Booleans, then constructor-specific checks (`validate_default`, `max_length`, …). Pre-#260 each
# constructor interleaved these ad hoc, so when a call has SEVERAL invalid keywords, the one
# reported first may differ from before. The raised type is `FieldValidationError` either way.
#
# `bools` declares the constructor's own Boolean keywords with their defaults — they get the same
# extraction and guard treatment. `extra` lists keywords the caller validates itself (`max_length`,
# `choices`, `on_delete`, …), which are accepted but passed through untouched. `exclude` drops a
# common keyword a constructor genuinely does not take (`PasswordField` has no `unique`, `db_index`
# or `default`).
const _COMMON_FIELD_KWARGS = (:verbose_name, :unique, :blank, :null, :db_index, :db_column, :default, :editable)

function _common_kwargs(field_type::AbstractString, kwargs;
                        bools::NamedTuple = NamedTuple(),
                        extra::Tuple = (),
                        exclude::Tuple = (),
                        unique::Bool = false,
                        db_index::Bool = false,
                        editable::Bool = false,
                        primary_key::Union{Bool,Nothing} = nothing)
  accepted = Set{Symbol}(k for k in _COMMON_FIELD_KWARGS if !(k in exclude))
  primary_key === nothing || push!(accepted, :primary_key)
  for k in keys(bools); push!(accepted, k); end
  for k in extra;        push!(accepted, k); end

  for (k, v) in kwargs
    if !(k in accepted)
      @warn "Unexpected parameter for $field_type. It will be ignored." field=field_type param=k value=v
    end
  end

  _bool(name::Symbol, value) = value isa Bool ? value :
    throw(_fielderr("$field_type: '$name' must be a Boolean, got $(typeof(value))"))
  _str_or_nothing(name::Symbol, value) = value isa Union{Nothing,String} ? value :
    throw(_fielderr("$field_type: '$name' must be a String or nothing, got $(typeof(value))"))

  # Read a keyword from kwargs ONLY if this constructor accepts it. An unaccepted keyword was
  # warned about above and must be GENUINELY ignored — the pre-#260 preambles never extracted it,
  # so even a wrongly-typed value slid by with just the warning. Consulting kwargs here would turn
  # "warn and ignore" into "warn then throw", making the warning a lie
  # (test_field_kwargs_equivalence.jl pins this).
  _take(key::Symbol, default) = key in accepted ? get(kwargs, key, default) : default

  common = (
    verbose_name = _str_or_nothing(:verbose_name, _take(:verbose_name, nothing)),
    unique       = _bool(:unique,   _take(:unique,   unique)),
    blank        = _bool(:blank,    _take(:blank,    false)),
    null         = _bool(:null,     _take(:null,     false)),
    db_index     = _bool(:db_index, _take(:db_index, db_index)),
    db_column    = _str_or_nothing(:db_column, _take(:db_column, nothing)),
    editable     = _bool(:editable, _take(:editable, editable)),
    primary_key  = _bool(:primary_key, _take(:primary_key, primary_key === nothing ? false : primary_key)),
  )
  # The constructor's own Boolean keywords, same extraction and guard.
  declared = NamedTuple{keys(bools)}(map(k -> _bool(k, get(kwargs, k, bools[k])), keys(bools)))
  return merge(common, declared)
end


struct sIDField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  auto_increment::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formatter::Function
  generated::Bool  # New field to indicate GENERATED ... AS IDENTITY
  generated_always::Bool # New field to indicate GENERATED ALWAYS AS IDENTITY
end

"""
    IDField(; kwargs...)

A field type for auto-incrementing integer primary keys, equivalent to PostgreSQL's BIGSERIAL or GENERATED AS IDENTITY columns.

The `IDField` is typically used as the primary key for models and automatically generates unique integer values for each record. It maps to a PostgreSQL BIGINT column with auto-increment capabilities.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `primary_key::Bool = true`: Whether this field is the primary key for the table
- `auto_increment::Bool = true`: Whether the field should auto-increment (generate values automatically)
- `unique::Bool = true`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms (not applicable for ID fields)
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = true`: Whether to create a database index on this field
- `default::Union{Int64, Nothing} = nothing`: Default value for the field (rarely used with auto-increment)
- `editable::Bool = false`: Whether the field should be editable in forms (typically false for ID fields)
- `generated::Bool = true`: Whether to use PostgreSQL's GENERATED AS IDENTITY feature
- `generated_always::Bool = false`: Whether to use GENERATED ALWAYS AS IDENTITY (stricter than regular GENERATED)

# Database Mapping
- **PostgreSQL Type**: BIGINT with GENERATED AS IDENTITY or GENERATED ALWAYS AS IDENTITY
- **Auto-increment**: Supported through PostgreSQL's identity columns
- **Index**: Automatically indexed as primary key

# Examples

Basic usage (most common):
```julia
User = Models.Model(
    _id::PormGField = IDField()
    name::PormGField = CharField(max_length=100)
    email::PormGField = EmailField()
)
```

Using GENERATED ALWAYS (stricter identity):
```julia
Order = Models.Model(
    _id::PormGField = IDField(generated_always=true)
    customer_id::PormGField = ForeignKey("Customer")
    order_date::PormGField = DateTimeField()
)
```

# Notes
- The `IDField` is designed to be the primary key and should typically be the first field in your model
- Values are automatically generated by the database, so you don't need to provide them when creating records
- The field uses BIGINT type to support large ranges of ID values
- When `generated_always=true`, the database will reject any attempts to manually insert ID values
- This field type is PostgreSQL-specific and optimized for PormG's PostgreSQL backend

# Validation
- All boolean parameters are validated to ensure type safety
- The `verbose_name` must be a String or nothing
- The `default` value, if provided, must be convertible to Int64
- Invalid parameters will trigger warnings but won't cause errors (they'll be ignored)
"""
function IDField(; kwargs...)
  (; verbose_name, primary_key, auto_increment, unique, blank, null, db_index, db_column, editable,
     generated, generated_always) =
    _common_kwargs("IDField", kwargs;
      primary_key = true, unique = true, db_index = true,
      bools = (auto_increment = true, generated = true, generated_always = false))

  default = validate_default(get(kwargs, :default, nothing), Union{Int64, Nothing}, "IDField", format2int64)

  return sIDField(
    verbose_name, primary_key, auto_increment, unique, blank, null, db_index, db_column, default,
    editable, "BIGINT", format_number_sql, generated, generated_always
  )
end

mutable struct sForeignKey <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  to::Union{String, PormGModel, Nothing}
  pk_field::Union{String, Symbol, Nothing}
  on_delete::Union{Function, Nothing}
  on_update::Union{String, Nothing}
  deferrable::Bool
  how::Union{String, Nothing}  # INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN used in _build_row_join
  related_name::Union{String, Nothing}
  type::String
  formatter::Function
  db_constraint::Bool
  initially_deferred::Bool
end

"""
    ForeignKey(to::Union{String, PormGModel}; kwargs...)

A field that creates a many-to-one relationship to another model, similar to Django's ForeignKey.

The `ForeignKey` field represents a relationship where many records in the current model can reference a single record in the target model. It creates a foreign key constraint in the database and enables efficient querying of related data.

# Required Arguments
- `to::Union{String, PormGModel}`: The target model that this field references. Can be either:
  - A string with the model name (e.g., "User", "Category")  
  - A direct reference to a PormGModel instance

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `primary_key::Bool = false`: Whether this field is the primary key (rarely used with ForeignKey)
- `unique::Bool = false`: Whether values must be unique (creates a one-to-one relationship if true)
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = true`: Whether to create a database index on this field (recommended for performance)
- `default::Union{Int64, Nothing} = nothing`: Default value for the field (ID of the referenced record)
- `editable::Bool = false`: Whether the field should be editable in forms
- `pk_field::Union{String, Symbol, Nothing} = nothing`: Which field in the target model to reference (defaults to primary key)
- `on_delete::Union{Function, String, Nothing} = nothing`: Action when the referenced object is deleted
- `on_update::Union{String, Nothing} = nothing`: Action when the referenced object's key is updated
- `deferrable::Bool = false`: Whether the constraint check can be deferred until transaction commit
- `initially_deferred::Bool = false`: Whether constraint checking is initially deferred
- `how::Union{String, Nothing} = nothing`: Join type for queries ("INNER JOIN", "LEFT JOIN", etc.)
- `related_name::Union{String, Nothing} = nothing`: Name for the reverse relation
- `db_constraint::Bool = true`: Whether to create a database foreign key constraint
- `db_column::Union{String, Nothing} = nothing`: Map the local FK column to a differently-named physical column (#50). The *referenced* parent column follows `pk_field` (resolved through the parent field's own `db_column` when the target is a resolved model). Defaults to the field name

# Database Mapping
- **PostgreSQL Type**: BIGINT with foreign key constraint
- **Constraint**: Creates `FOREIGN KEY` constraint linking to target table
- **Index**: Automatically indexed for query performance

# On Delete Options
The `on_delete` parameter controls what happens when the referenced object is deleted:
- `CASCADE`: Delete this object when referenced object is deleted
- `RESTRICT`: Prevent deletion of referenced object if this object exists
- `SET_NULL`: Set this field to NULL (requires `null=true`)
- `SET_DEFAULT`: Set this field to its default value (requires `default` to be set)
- `PROTECT`: Raise an error to prevent deletion
- `DO_NOTHING`: Take no action (may cause database integrity errors)

Omitting `on_delete` is also valid and is the default: PormG then emits no statement for the relation
and renders `ON DELETE NO ACTION`, leaving the reference to the database's own constraint.

The two "requires" above are enforced, not advisory — `set_models` raises `ModelDefinitionError` for a
`SET_NULL` field declared `null=false` or a `SET_DEFAULT` field with no `default` (#287).

# Examples

Basic foreign key relationship:
```julia
Article = Models.Model(
    _id = IDField()
    title = CharField(max_length=200)
    author = ForeignKey("User")
    category = ForeignKey("Category", on_delete=CASCADE)
)
```

Foreign key allowing NULL values:
```julia
Product = Models.Model(
    _id = IDField()
    _id = IDField()
    name = CharField(max_length=100)
    category = ForeignKey("Category", null=true, blank=true, on_delete=SET_NULL)
)
```

Multiple foreign keys to same model (requires related_name):
```julia
Message = Models.Model(
    _id = IDField()
    sender = ForeignKey("User", related_name="sent_messages")
    recipient = ForeignKey("User", related_name="received_messages")
    content = TextField()
)
```

# Related Names and Reverse Relations
- If `related_name` is not specified, PormG automatically generates one
- When multiple ForeignKeys point to the same model, `related_name` must be explicitly set
- The related name allows querying from the target model back to this model
- If you can't remember the related name, you can type `your_query.objects.related_objects` or `your_model.related_objects` to see all related names

# Database Constraints
- When `db_constraint=true` (default), creates actual foreign key constraints in PostgreSQL
- When `db_constraint=false`, no database constraint is created (useful for legacy databases)
- Database constraints ensure referential integrity but may impact performance

# Validation
- The `to` parameter must be a valid model name or PormGModel instance
- All boolean parameters are validated for type safety
- The `on_delete` parameter is validated against allowed values
- Invalid parameters trigger warnings but don't cause errors

# Notes
- The field stores the primary key value of the referenced object
- Uses BIGINT type to match IDField primary keys
- Supports deferred constraint checking for complex transactions
- Compatible with PostgreSQL's foreign key features

# See Also
- Django's ForeignKey documentation for conceptual understanding
"""
function ForeignKey(to::Union{String, PormGModel}; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, deferrable, initially_deferred, db_constraint) =
    _common_kwargs("ForeignKey", kwargs; primary_key = false, db_index = true,
      bools = (deferrable = false, initially_deferred = false, db_constraint = true),
      extra = (:pk_field, :on_delete, :on_update, :how, :related_name))

  default = get(kwargs, :default, nothing)
  pk_field = get(kwargs, :pk_field, nothing)
  on_delete = get(kwargs, :on_delete, nothing)
  on_update = get(kwargs, :on_update, nothing)
  how = get(kwargs, :how, nothing)
  related_name = get(kwargs, :related_name, nothing)

  # Validate 'to' parameter
  !(to isa Union{String, PormGModel}) && throw(_fielderr("The 'to' parameter must be a String or PormGModel"))

  # Validate boolean parameters

  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "ForeignKey", format2int64)

  # Validate optional string parameters
  !(pk_field isa Union{Nothing, AbstractString, Symbol}) &&
    throw(_fielderr("The 'pk_field' must be a String, Symbol, or nothing"))
  on_delete = _get_on_delete_mode(on_delete)
  !(on_update isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'on_update' must be a String or nothing"))
  !(how isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'how' must be a String or nothing"))
  !(related_name isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'related_name' must be a String or nothing"))

  # Resolve db_index based on db_constraint
  db_index = db_index || !db_constraint 
  pk_field = format_fild_name(pk_field)  

  return sForeignKey(
    verbose_name,
    primary_key,
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    to,
    pk_field,
    on_delete,
    on_update,
    deferrable,
    how,
    related_name,
    "BIGINT",
    format_number_sql,
    db_constraint,
    initially_deferred
  )
end

function _get_on_delete_mode(on_delete::Nothing)
  return nothing
end
function _get_on_delete_mode(on_delete::AbstractString)
  raw = strip(on_delete)
  on_delete = uppercase(raw)
  on_delete = replace(on_delete, r"\s+" => "_")
  # Django's callable sentinel, e.g. `models.SET(get_sentinel_user)` (#287). PormG's `on_delete`
  # holds a bare sentinel with nowhere to carry a value, so the callable cannot be represented.
  # Until #287 this fell through to a `contains(…, "SET")` branch that silently discarded the
  # callable and produced a FK emitting the invalid `ON DELETE SET`.
  #
  # This is checked FIRST, before the substring branches: the callable's name is arbitrary text,
  # so `models.SET(protect_sentinel)` matches `contains(…, "PROTECT")` and
  # `models.SET(set_default_team)` matches `contains(…, "SET_DEFAULT")`. Ordering it last made the
  # branch unreachable for exactly the plausible sentinel names and reinstated the silent
  # mistranslation. Safe at the top: no legitimate input contains `(` — introspection emits
  # CASCADE / SET NULL / NO ACTION / RESTRICT / SET DEFAULT, the Django importer emits `models.<NAME>`.
  if occursin(r"\bSET_*\(", on_delete)
    throw(_fielderr("The on_delete value \e[4m\e[31m$(raw)\e[0m is not supported: Django's SET(...) " *
      "sentinel carries a value or callable, which PormG's on_delete cannot represent. Use " *
      "SET_DEFAULT together with a `default=` on the field, or SET_NULL if the column is nullable."))
  elseif contains(on_delete, "CASCADE")
    return CASCADE
  elseif contains(on_delete, "RESTRICT")
    return RESTRICT
  elseif contains(on_delete, "SET_NULL")
    return SET_NULL
  elseif contains(on_delete, "SET_DEFAULT")
    return SET_DEFAULT
  elseif contains(on_delete, "NO_ACTION") || contains(on_delete, "DO_NOTHING")
    return DO_NOTHING
  elseif contains(on_delete, "PROTECT")
    return PROTECT
  else
    throw(_fielderr("The on_delete parameter must be CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, DO_NOTHING or PROTECT"))
  end
end
function _get_on_delete_mode(on_delete::Function)
  # check if the function is one of the valid functions
  check_function = on_delete |> string |> uppercase
  if !(check_function in ["CASCADE", "RESTRICT", "SET_NULL", "SET_DEFAULT", "DO_NOTHING", "PROTECT"])
    throw(_fielderr("The on_delete parameter must be CASCADE, RESTRICT, SET_NULL, SET_DEFAULT, DO_NOTHING or PROTECT"))
  end
  return on_delete
end


mutable struct sManyToManyField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  to::Union{String, PormGModel, Nothing}
  through::Union{String, PormGModel, Nothing}
  related_name::Union{String, Nothing}
  db_table::Union{String, Nothing}
  source_field::Union{String, Nothing}
  target_field::Union{String, Nothing}
  type::String
  formatter::Function
end

"""
    ManyToManyField(to::Union{String, PormGModel}; kwargs...)

Declare a many-to-many relationship without adding a physical column to the
owning model table. When `through` is omitted, migrations synthesize a join
table with two foreign keys and a composite unique index.

# Keyword Arguments
- `through::Union{String, PormGModel, Nothing} = nothing`: explicit through model; skips auto table synthesis.
- `related_name::Union{String, Nothing} = nothing`: reverse accessor on the target model.
- `db_table::Union{String, Nothing} = nothing`: auto-through table name override.
- `source_field::Union{String, Nothing} = nothing`: through-table column pointing to the source model.
- `target_field::Union{String, Nothing} = nothing`: through-table column pointing to the target model.
"""
function ManyToManyField(to::Union{String, PormGModel}; kwargs...)
  accepted = Set([
    :verbose_name, :through, :related_name, :db_table, :source_field, :target_field
  ])

  for (k, v) in kwargs
    if !(k in accepted)
      @warn "Unexpected parameter for ManyToManyField. It will be ignored." field="ManyToManyField" param=k value=v
    end
  end

  verbose_name = get(kwargs, :verbose_name, nothing)
  through = get(kwargs, :through, nothing)
  related_name = get(kwargs, :related_name, nothing)
  db_table = get(kwargs, :db_table, nothing)
  source_field = get(kwargs, :source_field, nothing)
  target_field = get(kwargs, :target_field, nothing)

  !(to isa Union{String, PormGModel}) && throw(_fielderr("The 'to' parameter must be a String or PormGModel"))
  !(verbose_name isa Union{Nothing, String}) && throw(_fielderr("The 'verbose_name' must be a String or nothing"))
  !(through isa Union{Nothing, String, PormGModel}) && throw(_fielderr("The 'through' parameter must be a String, PormGModel, or nothing"))
  !(related_name isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'related_name' must be a String or nothing"))
  !(db_table isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'db_table' must be a String or nothing"))
  !(source_field isa Union{Nothing, AbstractString, Symbol}) && throw(_fielderr("The 'source_field' must be a String, Symbol, or nothing"))
  !(target_field isa Union{Nothing, AbstractString, Symbol}) && throw(_fielderr("The 'target_field' must be a String, Symbol, or nothing"))

  return sManyToManyField(
    verbose_name,
    false,
    to,
    through,
    related_name === nothing ? nothing : String(related_name),
    # Case-PRESERVING (#59): this used to run through `format_model_name`, which silently lowercased
    # (and stripped a leading underscore from) a user-supplied physical through-table name — the
    # opposite policy from model-level `db_table`, which carries an arbitrary legacy spelling
    # verbatim. Both seams express the same intent ("this table is called X"), so they now behave the
    # same way. Empty-string-as-unset mirrors `_apply_db_table!`.
    db_table === nothing ? nothing : (isempty(String(db_table)) ? nothing : String(db_table)),
    source_field === nothing ? nothing : format_fild_name(source_field),
    target_field === nothing ? nothing : format_fild_name(target_field),
    "MANYTOMANY",
    identity
  )
end


mutable struct sOneToOneField <: PormGField
  unique::Bool
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  to::Union{String, PormGModel, Nothing}
  pk_field::Union{String, Symbol, Nothing}
  on_delete::Union{Function, Nothing}
  on_update::Union{String, Nothing}
  deferrable::Bool
  how::Union{String, Nothing}  # INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN used in _build_row_join
  related_name::Union{String, Nothing}
  type::String
  formatter::Function
  db_constraint::Bool
  initially_deferred::Bool
end

"""
    OneToOneField(to::Union{String, PormGModel}; kwargs...)

A field that creates a one-to-one relationship to another model, similar to Django's OneToOneField.

The `OneToOneField` represents a strict one-to-one relationship where each record in the current model corresponds to exactly one record in the target model, and vice versa. It's essentially a ForeignKey with a unique constraint that ensures no two records can reference the same target record.

# Required Arguments
- `to::Union{String, PormGModel}`: The target model that this field references. Can be either:
  - A string with the model name (e.g., "UserProfile", "Settings")  
  - A direct reference to a PormGModel instance

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `primary_key::Bool = false`: Whether this field is the primary key (rarely used with OneToOneField)
- `unique::Bool = true`: Whether values must be unique (always true for one-to-one relationships)
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = true`: Whether to create a database index on this field (recommended for performance)
- `default::Union{Int64, Nothing} = nothing`: Default value for the field (ID of the referenced record)
- `editable::Bool = false`: Whether the field should be editable in forms
- `pk_field::Union{String, Symbol, Nothing} = nothing`: Which field in the target model to reference (defaults to primary key)
- `on_delete::Union{Function, String, Nothing} = nothing`: Action when the referenced object is deleted
- `on_update::Union{String, Nothing} = nothing`: Action when the referenced object's key is updated
- `deferrable::Bool = false`: Whether the constraint check can be deferred until transaction commit
- `initially_deferred::Bool = false`: Whether constraint checking is initially deferred
- `how::Union{String, Nothing} = nothing`: Join type for queries ("INNER JOIN", "LEFT JOIN", etc.)
- `related_name::Union{String, Nothing} = nothing`: Name for the reverse relation
- `db_constraint::Bool = true`: Whether to create a database foreign key constraint
- `db_column::Union{String, Nothing} = nothing`: Map the local column to a differently-named physical column (#50); defaults to the field name

# Database Mapping
- **PostgreSQL Type**: BIGINT with unique foreign key constraint
- **Constraint**: Creates `FOREIGN KEY` constraint with `UNIQUE` constraint
- **Index**: Automatically indexed for query performance and uniqueness enforcement

# One-to-One Relationship Characteristics
- **Uniqueness**: Each target record can only be referenced by one record in the current model
- **Bidirectional**: The relationship can be traversed in both directions
- **Inheritance**: Often used to extend models without modifying the original table
- **Profile Pattern**: Commonly used for user profiles, settings, or detailed information tables

# On Delete Options
The `on_delete` parameter controls what happens when the referenced object is deleted:
- `CASCADE`: Delete this object when referenced object is deleted
- `RESTRICT`: Prevent deletion of referenced object if this object exists
- `SET_NULL`: Set this field to NULL (requires `null=true`)
- `SET_DEFAULT`: Set this field to its default value (requires `default` to be set)
- `PROTECT`: Raise an error to prevent deletion
- `DO_NOTHING`: Take no action (may cause database integrity errors)

Omitting `on_delete` is also valid and is the default: PormG then emits no statement for the relation
and renders `ON DELETE NO ACTION`, leaving the reference to the database's own constraint.

The two "requires" above are enforced, not advisory — `set_models` raises `ModelDefinitionError` for a
`SET_NULL` field declared `null=false` or a `SET_DEFAULT` field with no `default` (#287).

# Examples

Basic one-to-one relationship (User Profile pattern):
```julia
User = Models.Model(
    _id = IDField()
    username = CharField(max_length=150, unique=true)
    email = EmailField()
)

UserProfile = Models.Model(
    _id = IDField()
    user = OneToOneField("User", on_delete=CASCADE)
    bio = TextField(blank=true)
    avatar = ImageField(blank=true)
    birth_date = DateField(null=true, blank=true)
)
```

One-to-one with null values allowed:
```julia
Employee = Models.Model(
    _id = IDField()
    name = CharField(max_length=100)
    department = CharField(max_length=50)
)

EmployeeSettings = Models.Model(
    _id = IDField()
    employee = OneToOneField("Employee", null=true, blank=true, on_delete=SET_NULL)
    email_notifications = BooleanField(default=true)
    theme_preference = CharField(max_length=20, default="light")
)
```

Extending a model without modifying it:
```julia
Product = Models.Model(
    _id = IDField()
    name = CharField(max_length=200)
    price = DecimalField(max_digits=10, decimal_places=2)
)

ProductDetails = Models.Model(
    _id = IDField()
    product = OneToOneField("Product", on_delete=CASCADE, related_name="details")
    detailed_description = TextField()
    technical_specs = TextField()
    warranty_info = TextField()
)
```

# Database Constraints vs. Unique ForeignKey
OneToOneField is equivalent to:
```julia
# These are functionally identical:
user = OneToOneField("User")
user = ForeignKey("User", unique=true)
```

However, OneToOneField is more explicit about the intended relationship type and provides better semantic meaning.

# Validation
- The `to` parameter must be a valid model name or PormGModel instance
- All boolean parameters are validated for type safety
- The `on_delete` parameter is validated against allowed values
- Uniqueness is automatically enforced at the database level
- Invalid parameters trigger warnings but don't cause errors

# See Also
- Django's OneToOneField documentation for conceptual understanding
- Database normalization principles for when to use one-to-one relationships
"""
function OneToOneField(to::Union{String, PormGModel}; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, deferrable, initially_deferred, db_constraint) =
    _common_kwargs("OneToOneField", kwargs; primary_key = false, unique = true, db_index = true,
      bools = (deferrable = false, initially_deferred = false, db_constraint = true),
      extra = (:pk_field, :on_delete, :on_update, :how, :related_name))

  default = get(kwargs, :default, nothing)
  pk_field = get(kwargs, :pk_field, nothing)
  on_delete = get(kwargs, :on_delete, nothing)
  on_update = get(kwargs, :on_update, nothing)
  how = get(kwargs, :how, nothing)
  related_name = get(kwargs, :related_name, nothing)

  # Validate 'to' parameter
  !(to isa Union{String, PormGModel}) && throw(_fielderr("The 'to' parameter must be a String or PormGModel"))

  # Validate boolean parameters

  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "OneToOneField", format2int64)

  # Validate optional string parameters
  !(pk_field isa Union{Nothing, String, Symbol}) && throw(_fielderr("The 'pk_field' must be a String, Symbol, or nothing"))
  !(on_update isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'on_update' must be a String or nothing"))
  !(how isa Union{Nothing, String}) && throw(_fielderr("The 'how' must be a String or nothing"))
  !(related_name isa Union{Nothing, String}) && throw(_fielderr("The 'related_name' must be a String or nothing"))

  # Resolve on_delete using similar logic as ForeignKey
  on_delete = _get_on_delete_mode(on_delete)

  # Resolve db_index based on db_constraint
  db_index = db_index || !db_constraint
  # Normalize pk_field (strip one leading underscore for reserved-word escaping), matching
  # ForeignKey — so a referenced parent field resolves to its stored (stripped) key (#50).
  pk_field = format_fild_name(pk_field)

  return sOneToOneField(
    unique,
    verbose_name,
    primary_key,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    to,
    pk_field,
    on_delete,
    on_update,
    deferrable,
    how,
    related_name,
    "BIGINT",
    format_number_sql,
    db_constraint,
    initially_deferred
  )
end

mutable struct sAutoField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  auto_increment::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    AutoField(; kwargs...)

A field type for auto-incrementing integer primary keys, equivalent to PostgreSQL's SERIAL columns.

The `AutoField` is designed for auto-incrementing integer primary keys and automatically generates unique integer values for each record. Unlike `IDField` which uses BIGINT, `AutoField` uses INTEGER type and is suitable for applications that don't require the extended range of BIGINT values.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `primary_key::Bool = true`: Whether this field is the primary key for the table
- `auto_increment::Bool = true`: Whether the field should auto-increment (generate values automatically)
- `unique::Bool = true`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms (not applicable for auto fields)
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field (primary keys are automatically indexed)
- `default::Union{Int64, Nothing} = nothing`: Default value for the field (rarely used with auto-increment)
- `editable::Bool = false`: Whether the field should be editable in forms (typically false for auto fields)

# Database Mapping
- **PostgreSQL Type**: INTEGER with SERIAL auto-increment
- **Auto-increment**: Supported through PostgreSQL's SERIAL type (sequence-based)
- **Index**: Automatically indexed as primary key
- **Range**: 32-bit signed integers (-2,147,483,648 to 2,147,483,647)

# AutoField vs IDField Comparison
| Feature | AutoField | IDField |
|---------|-----------|---------|
| **Database Type** | INTEGER (SERIAL) | BIGINT (BIGSERIAL/IDENTITY) |
| **Range** | 32-bit (-2B to 2B) | 64-bit (-9Q to 9Q) |
| **Storage** | 4 bytes | 8 bytes |
| **Generation** | Sequence-based | Identity columns or sequence |
| **Use Case** | Small to medium apps | Large-scale applications |


# When to Use AutoField vs IDField

**Use AutoField when:**
- Building small to medium-sized applications
- You don't expect more than ~2 billion records
- Storage efficiency is important (4 bytes vs 8 bytes per ID)
- Working with legacy systems that expect INTEGER primary keys
- Building lookup tables, categories, or reference data

**Use IDField when:**
- Building large-scale applications with potential for massive growth
- You need the extended range of 64-bit integers
- Working with data warehouses or analytics platforms
- Future-proofing against scale requirements
- Using modern PostgreSQL features like identity columns
"""
function AutoField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, auto_increment) =
    _common_kwargs("AutoField", kwargs; primary_key = true, unique = true, bools = (auto_increment = true,))

  default = get(kwargs, :default, nothing)

  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "AutoField", format2int64)
  # Return the field instance

  return sAutoField(verbose_name, primary_key, auto_increment, unique, blank, null, db_index, db_column, default, editable, "INTEGER", format_number_sql)
end

mutable struct sCharField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  max_length::Int
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
  choices::Union{NTuple{N, Tuple{AbstractString, AbstractString}}, Nothing} where N
end


function parse_choices(choices_str::String)
  # Parse a string into a tuple of tuples
  # println(choices_str)
  choices = ()
  pattern = r"\(([^()]+)\)"
  for m in eachmatch(pattern, choices_str)
    inner = m.captures[1]
    values = split(inner, ",")
    if length(values) == 2
      key = strip(values[1]) |> string
      value = strip(values[2]) |> string
      choices = (choices..., (key, value))
    else
      throw(_fielderr("Invalid choices format"))
    end
  end
  return choices
end

function count_just_strings(key_value::AbstractString)
  count = 0
  pattern = r"^\s*['\"](.*)['\"]\s*$"
  for line in split(key_value, '\n')
    if occursin(pattern, line)
      count += 1
    end
  end
  return count
end

function return_just_strings(key_value::AbstractString)
  pattern = r"^\s*['\"](.*)['\"]\s*$"
  m = match(pattern, key_value |> String)
  if m !== nothing
    return m.captures[1]
  end  
  return key_value
end

"""
    CharField(; kwargs...)

A field for storing short to medium-length strings, equivalent to PostgreSQL's VARCHAR columns.

The `CharField` is the most commonly used field for storing textual data with a limited length. It maps to a PostgreSQL VARCHAR column and supports validation, indexing, choices, and various constraints. This field is ideal for names, titles, codes, and other string data with known maximum lengths.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `max_length::Int = 250`: Maximum number of characters allowed (1 or greater)
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `db_column::Union{String, Nothing} = nothing`: Map this field to a differently-named physical column (Django `db_column`). Authoritative across DDL, queries, and migrations (#50); defaults to the field name
- `default::Union{String, Nothing} = nothing`: Default value for the field
- `choices::Union{NTuple{N, Tuple{AbstractString, AbstractString}}, Nothing} = nothing`: Restricted set of valid values
- `editable::Bool = true`: Whether the field should be editable in forms

# Length Constraints
- **Minimum**: 1 character
- **Maximum**: bounded by the backend, not by PormG — PostgreSQL's `varchar` accepts up to
  10,485,760 characters and SQLite ignores the declared length entirely
- **Validation**: Automatically enforced at the field level
- **Storage**: Efficient variable-length storage in PostgreSQL

# Examples

Basic string field:
```julia
User = Models.Model(
    _id = IDField(),
    username = CharField(max_length=150, unique=true),
    first_name = CharField(max_length=50),
    last_name = CharField(max_length=50)
)
```

String field with choices (enumeration):
```julia
Order = Models.Model(
    _id = IDField()
    status = CharField(
        max_length=20,
        choices=(
            ("1", "Pending"),
            ("2", "Processing"),
            ("3", "Shipped"),
            ("4", "Delivered"),
            ("5", "Cancelled")
        ),
        default="1"
    )
    customer_name = CharField(max_length=200)
)
```

Field with a human-readable label (the column name follows the field name, "sku"):
```julia
Product = Models.Model(
    _id = IDField(),
    name = CharField(max_length=200),
    sku = CharField(
        max_length=50,
        unique=true,
        verbose_name="Stock Keeping Unit"
    )
    category = CharField(max_length=100, null=true, blank=true)
)
```

Indexed field for performance:
```julia
Article = Models.Model(
    _id = IDField(),
    title = CharField(max_length=200, db_index=true),
    slug = CharField(max_length=200, unique=true, db_index=true),
    content = TextField()
)
```

# Choices Feature
The `choices` parameter allows you to restrict field values to a predefined set:

```julia
# Define choices as tuples of (value, display_name)
priority_choices = (
    ("low", "Low Priority"),
    ("medium", "Medium Priority"),
    ("high", "High Priority"),
    ("urgent", "Urgent")
)

Task = Models.Model(
    _id = IDField(),
    title = CharField(max_length=200),
    priority = CharField(max_length=10, choices=priority_choices, default="medium")
)
```

**Choice Format Options:**
1. **Tuple of Tuples**: `(("value1", "Display 1"), ("value2", "Display 2"))`
2. **String Format**: `"(value1, Display 1)(value2, Display 2)"`

# Default Values
- **Static Default**: `default="some_value"`
- **Must Match Choices**: If choices are specified, default must be one of the choice values
- **Length Validation**: Default value must not exceed `max_length`

# Database Column Naming
- **Conventions**: Follow PostgreSQL naming conventions (lowercase, underscores)

# CharField vs TextField
| Feature | CharField | TextField |
|---------|-----------|-----------|
| **Length** | Bounded (`max_length`) | Unlimited |
| **Database Type** | VARCHAR | TEXT |
| **Use Case** | Short strings | Long content |
| **Indexing** | Efficient | Less efficient |
| **Performance** | Fast queries | Slower for large content |

# Migration Considerations
- **Increasing Length**: Safe operation
- **Decreasing Length**: Requires data validation
- **Adding Choices**: Application-level change only
- **Changing Column Name**: rename the field — the column follows the field name; `db_column` is not currently honored by schema generation

# Notes
- The field uses VARCHAR type which is efficient for short to medium strings
- Choices are validated at the Julia application level, not in the database
- The `editable=true` default makes this field suitable for user input forms
- Database indexing is optional but recommended for frequently queried fields
- Compatible with PostgreSQL's text search and pattern matching features

# See Also
- `TextField` for unlimited length text content
- `EmailField` for email address validation
- Database design best practices for string field sizing
"""
function CharField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key) =
    _common_kwargs("CharField", kwargs; primary_key = false, editable = true, extra = (:max_length, :choices))

  max_length = get(kwargs, :max_length, 250)
  default = get(kwargs, :default, nothing)
  choices = get(kwargs, :choices, nothing)

  max_length isa AbstractString && (max_length = parse(Int, max_length))
  max_length isa Int || throw(_fielderr("The max_length must be an integer"))
  # No upper bound (#325). The old 255 ceiling was a MySQL-ism — PostgreSQL's `varchar` takes up to
  # 10,485,760 characters and SQLite ignores the declared length. Worse, it was LOSSY on read-back:
  # introspecting a live `varchar(500)` had to retype the column to TextField and drop the length,
  # so the declared model never matched its own table and `makemigrations` churned forever. A future
  # MySQL backend enforces its own limit at render time (#60), not here.
  max_length < 1 && throw(_fielderr("The max_length must be greater than 1"))
  default isa Int && (default = string(default))
  if !(default isa Nothing) && !(default isa AbstractString) 
    throw(_fielderr("The default value must be a string, but got $(default) ($(typeof(default)))"))
  end
  if !(default isa Nothing) && length(default) > max_length
    throw(_fielderr("The default value exceeds the max_length, but got $(length(default)) and max_length is $(max_length)"))
  end
  if choices isa AbstractString
    choices = parse_choices(choices)
  elseif !(choices isa Union{Nothing, NTuple{N, Tuple{AbstractString, AbstractString}} where N })
    println(choices)
    println(choices |> typeof)
    throw(_fielderr("The 'choices' must be a String or Tuple{Tuple{String,String}}, but got $(choices) ($(typeof(choices)))"))
  end
  if choices !== nothing
    for choice in choices
      if !(choice[1] isa AbstractString)
        throw(_fielderr("Choice values must be strings"))
      end
      if count_just_strings(choice[1]) > max_length
        throw(_fielderr("Choices cannot exceed max_length"))
      end
    end
    if default !== nothing
      valid_defaults = choices isa Vector{String} ? return_just_strings(choices) : [return_just_strings(c[1]) for c in choices]
      if !(default in valid_defaults)
        throw(_fielderr("The default value must be one of the choices"))
      end
    end
  end
  return sCharField(verbose_name, primary_key, max_length, unique, blank, null, db_index, db_column, default, editable, "VARCHAR", format_text_sql, choices)
end


mutable struct sIntegerField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    IntegerField(; kwargs...)

A field for storing 32-bit signed integers, equivalent to PostgreSQL's INTEGER columns.

The `IntegerField` stores whole numbers within the 32-bit signed integer range (-2,147,483,648 to 2,147,483,647). It's ideal for counts, quantities, ratings, and other numeric data that doesn't require decimal places or extremely large values.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{Int64, Nothing} = nothing`: Default value for the field
- `editable::Bool = false`: Whether the field should be editable in forms

# Examples

Basic integer field:
```julia
Product = Models.Model(
    _id = IDField(),
    name = CharField(max_length=200),
    quantity = IntegerField(default=0),
    price_cents = IntegerField()  # Store price in cents to avoid decimals
)
```

Integer field with constraints:
```julia
User = Models.Model(
    _id = IDField(),
    username = CharField(max_length=150, unique=true),
    age = IntegerField(null=true, blank=true),
    score = IntegerField(default=0, db_index=true)
)
```

Rating system:
```julia
Review = Models.Model(
    _id = IDField(),
    product = ForeignKey("Product"),
    rating = IntegerField(default=5),  # 1-5 star rating
    helpful_votes = IntegerField(default=0)
)
```

# Validation and Constraints
- **Range**: Automatically validates within INTEGER bounds
- **Type**: Accepts integers, numeric strings (converted automatically)
- **Default**: Must be an integer or convertible to integer
- **Null**: When `null=true`, accepts NULL values

# Migration Considerations
- **Range Changes**: Changing to BigIntegerField is safe
- **Adding Constraints**: Adding uniqueness or indexes is safe
- **Default Values**: Can be added or modified safely
- **Null Constraints**: Removing null constraint requires data validation

"""
function IntegerField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("IntegerField", kwargs)

  default = validate_default(get(kwargs, :default, nothing), Union{Int64, Nothing}, "IntegerField", format2int64)

  return sIntegerField(
    verbose_name, false, unique, blank, null, db_index, db_column, default, editable,
    "INTEGER", format_number_sql
  )
end

mutable struct sPositiveSmallIntegerField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

# Upper bound of a signed 2-byte integer; matches Django's PositiveSmallIntegerField range (0..32767).
const POSITIVE_SMALL_INTEGER_MAX = 32767

"""
    PositiveSmallIntegerField(; kwargs...)

A field for storing small, non-negative whole numbers, equivalent to PostgreSQL's
SMALLINT columns guarded by a `CHECK (col >= 0)` constraint. Mirrors Django's
`PositiveSmallIntegerField`.

Values are restricted to the range 0..32767. On PostgreSQL the column is declared
`smallint`; on SQLite it is declared `SMALLINT` (INTEGER affinity), which preserves
the declared type so the migration engine round-trips the field without drift. The
non-negative constraint is enforced both at construction (rejecting negative
defaults) and at the database level via a `CHECK` constraint. The migration engine
keeps that constraint in sync with the model: on PostgreSQL it is added or dropped
when a column's type transitions into or out of this field, and on SQLite it is
re-derived whenever the table is recreated during an alter.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{Int64, Nothing} = nothing`: Default value for the field (must be 0..32767)
- `editable::Bool = false`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: SMALLINT + `CHECK ("col" >= 0)`
- **SQLite Type**: SMALLINT (INTEGER affinity) + `CHECK ("col" >= 0)`
- **Range**: 0 to 32767

# Examples
```julia
Standing = Models.Model(
    _id = IDField(),
    position = PositiveSmallIntegerField(default=1),
    points = PositiveSmallIntegerField(default=0)
)
```
"""
function PositiveSmallIntegerField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("PositiveSmallIntegerField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default using validate_default, then enforce the non-negative range
  default = validate_default(default, Union{Int64, Nothing}, "PositiveSmallIntegerField", format2int64)
  if default !== nothing && !(0 <= default <= POSITIVE_SMALL_INTEGER_MAX)
    throw(_fielderr("The default value for PositiveSmallIntegerField must be between 0 and $(POSITIVE_SMALL_INTEGER_MAX), got: $default"))
  end

  return sPositiveSmallIntegerField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "SMALLINT",
    format_number_sql
  )
end

mutable struct sPositiveIntegerField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

# Upper bound of a signed 4-byte integer; matches Django's PositiveIntegerField range (0..2147483647).
const POSITIVE_INTEGER_MAX = 2147483647

"""
    PositiveIntegerField(; kwargs...)

A field for storing non-negative whole numbers, equivalent to PostgreSQL's
INTEGER columns guarded by a `CHECK (col >= 0)` constraint. Mirrors Django's
`PositiveIntegerField`.

Values are restricted to the range 0..2147483647. On PostgreSQL the column is
declared `integer`; on SQLite it is declared `INTEGER UNSIGNED` (INTEGER affinity),
which keeps the declared type distinct from `IntegerField` so the migration engine
round-trips the field without drift. On PostgreSQL the introspection layer instead
detects the column's non-negative CHECK constraint to tell the two fields apart.
The non-negative constraint is enforced both at construction (rejecting negative
defaults) and at the database level via a `CHECK` constraint, which the migration
engine adds or drops when a column's type transitions into or out of this field.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{Int64, Nothing} = nothing`: Default value for the field (must be 0..2147483647)
- `editable::Bool = false`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: INTEGER + `CHECK ("col" >= 0)`
- **SQLite Type**: INTEGER UNSIGNED (INTEGER affinity) + `CHECK ("col" >= 0)`
- **Range**: 0 to 2147483647

# Examples
```julia
Lap_times = Models.Model(
    _id = IDField(),
    lap = PositiveIntegerField(default=1),
    milliseconds = PositiveIntegerField()
)
```
"""
function PositiveIntegerField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("PositiveIntegerField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default using validate_default, then enforce the non-negative range
  default = validate_default(default, Union{Int64, Nothing}, "PositiveIntegerField", format2int64)
  if default !== nothing && !(0 <= default <= POSITIVE_INTEGER_MAX)
    throw(_fielderr("The default value for PositiveIntegerField must be between 0 and $(POSITIVE_INTEGER_MAX), got: $default"))
  end

  return sPositiveIntegerField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "INTEGER UNSIGNED",
    format_number_sql
  )
end

mutable struct sBigIntegerField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Int64, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    BigIntegerField(; kwargs...)

A field for storing 64-bit signed integers, equivalent to PostgreSQL's BIGINT columns.

The `BigIntegerField` stores large whole numbers within the 64-bit signed integer range (-9,223,372,036,854,775,808 to 9,223,372,036,854,775,807). It's ideal for large identifiers, timestamps, population counts, and other numeric data requiring extended range beyond regular integers.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{Int64, Nothing} = nothing`: Default value for the field
- `editable::Bool = false`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: BIGINT
- **Storage**: 8 bytes per value
- **Range**: -9,223,372,036,854,775,808 to 9,223,372,036,854,775,807
- **Index**: Optional, recommended for frequently queried fields

# Examples

Large identifier field:
```julia
Analytics = Models.Model(
    _id = IDField(),
    user_id = BigIntegerField(db_index=true),
    session_id = BigIntegerField(),
    timestamp_ms = BigIntegerField()  # Unix timestamp in milliseconds
)
```

Population and statistics:
```julia
Country = Models.Model(
    _id = IDField(),
    name = CharField(max_length=100),
    population = BigIntegerField(null=true),
    gdp_usd = BigIntegerField(null=true),  # GDP in USD cents
    area_sq_meters = BigIntegerField()
)
```

Large external identifiers:
```julia
SocialMedia = Models.Model(
    _id = IDField(),
    user = ForeignKey("User"),
    twitter_id = BigIntegerField(unique=true, null=true),
    facebook_id = BigIntegerField(unique=true, null=true),
    follower_count = BigIntegerField(default=0)
)
```

# Common Use Cases
1. **Large Identifiers**: External API IDs, social media IDs
2. **Timestamps**: Unix timestamps in milliseconds or microseconds
3. **Population Data**: Country populations, large counts
4. **Financial Data**: Large monetary values in smallest units
5. **Scientific Data**: Large measurements, particle counts
6. **Analytics**: Large user IDs, session identifiers

# Migration Considerations
- **From IntegerField**: Safe upgrade, no data loss
- **To IntegerField**: Requires validation that all values fit in 32-bit range
- **Index Changes**: Indexes will be recreated with new size
- **Application Code**: May need updates if expecting different ranges
"""
function BigIntegerField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("BigIntegerField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default using validate_default
  default = validate_default(default, Union{Int64, Nothing}, "BigIntegerField", format2int64)
  

  return sBigIntegerField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "BIGINT",
    format_number_sql
  )  
end

mutable struct sBooleanField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Bool, Nothing}
  editable::Bool
  type::String
  formatter::Function
end


"""
    BooleanField(; kwargs...)

A field for storing boolean (true/false) values, equivalent to PostgreSQL's BOOLEAN columns.

The `BooleanField` stores binary true/false values and is ideal for flags, switches, status indicators, and any field that represents a yes/no or on/off state. It maps directly to PostgreSQL's BOOLEAN type and Julia's Bool type.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `unique::Bool = false`: Whether values in this field must be unique (rarely used with booleans)
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{Bool, Nothing} = nothing`: Default value for the field (true or false)
- `editable::Bool = false`: Whether the field should be editable in forms

# Examples

Basic boolean flags:
```julia
User = Models.Model(
    _id = IDField(),
    username = CharField(max_length=150),
    is_active = BooleanField(default=true),
    is_staff = BooleanField(default=false),
    email_verified = BooleanField(default=false)
)
```

# Boolean Values and Conversion
The field handles various input formats:
- **Julia Bool**: `true`, `false`
- **Integers**: `1` (true), `0` (false)
- **Strings**: `"true"`, `"false"`, `"1"`, `"0"`, `"yes"`, `"no"`
- **NULL**: When `null=true`, accepts `NULL`/`nothing`
"""
function BooleanField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("BooleanField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = validate_default(default, Union{Bool, Nothing}, "BooleanField", x -> parse(Bool, string(x)))
  # Return the field instance
  return sBooleanField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "BOOLEAN",
    format_bool_sql
  )  
end

mutable struct sDateField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Date, Nothing}
  editable::Bool
  auto_now::Bool
  auto_now_add::Bool
  type::String
  formatter::Function
end

"""
    DateField(; kwargs...)

A field for storing date values (without time), equivalent to PostgreSQL's DATE columns.

The `DateField` stores calendar dates in YYYY-MM-DD format and is ideal for birth dates, event dates, deadlines, and any date information that doesn't require time precision. It maps to PostgreSQL's DATE type and Julia's Date type.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{String, Nothing} = nothing`: Default value for the field (YYYY-MM-DD format)
- `editable::Bool = false`: Whether the field should be editable in forms
- `auto_now::Bool = false`: Whether to automatically set to current date on every save
- `auto_now_add::Bool = false`: Whether to automatically set to current date on creation only

# Examples

Basic date fields:
```julia
User = Models.Model(
    _id = IDField(),
    username = CharField(max_length=150),
    birth_date = DateField(null=true, blank=true),
    join_date = DateField(auto_now_add=true),
    last_login_date = DateField(null=true)
)
```

Event and scheduling:
```julia
Event = Models.Model(
    _id = IDField(),
    title = CharField(max_length=200),
    event_date = DateField(db_index=true),
    registration_deadline = DateField(),
    created_date = DateField(auto_now_add=true)
)
```

Business dates:
```julia
Invoice = Models.Model(
    _id = IDField(),
    customer = ForeignKey("Customer"),
    issue_date = DateField(auto_now_add=true),
    due_date = DateField(),
    paid_date = DateField(null=true, blank=true)
)
```

# Auto Date Features

## auto_now_add
Sets the date automatically when the record is first created:
```julia
created_date = DateField(auto_now_add=true)
# Automatically set to today's date on creation
# Never changes after initial creation
```

## auto_now  
Updates the date automatically every time the record is saved:
```julia
last_modified_date = DateField(auto_now=true)
# Set to today's date on every save operation
# Useful for tracking last update dates
```

# Date Input Formats
The field accepts various input formats:
- **Julia Date**: `Date(2024, 7, 28)`
- **DateTime**: `DateTime(2024, 7, 28, 10, 30)` (time ignored)
- **String ISO**: `"2024-07-28"`
- **String formats**: Various date strings parseable by Julia
"""
function DateField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, auto_now, auto_now_add) =
    _common_kwargs("DateField", kwargs; bools = (auto_now = false, auto_now_add = false))

  default = get(kwargs, :default, nothing)

  # Validate default
  default = validate_default(default, Union{Date, Nothing}, "DateField", format_date_sql)
  # Return the field instance
  return sDateField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    auto_now,
    auto_now_add,
    "DATE",
    format_date_sql
  )  
end

mutable struct sDateTimeField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{ZonedDateTime, DateTime, Nothing}
  editable::Bool
  auto_now::Bool
  auto_now_add::Bool
  type::String
  formatter::Function
end

"""
    DateTimeField(; kwargs...)

A field for storing date and time values with timezone information.

# Keyword Arguments
- `verbose_name::Union{String, Nothing}`: Human-readable name for the field. Default: `nothing`
- `unique::Bool`: If `true`, ensures field values are unique across the table. Default: `false`
- `blank::Bool`: If `true`, allows empty values in forms/validation. Default: `false`
- `null::Bool`: If `true`, allows NULL values in the database. Default: `false`
- `db_index::Bool`: If `true`, creates a database index for faster queries. Default: `false`
- `default::Union{DateTime, Nothing, String}`: Default value for the field. Can be a DateTime object, ISO string, or `nothing`. Default: `nothing`
- `editable::Bool`: If `true`, field can be edited in forms. Default: `false`
- `auto_now::Bool`: If `true`, automatically updates to current datetime on every save. Default: `false`
- `auto_now_add::Bool`: If `true`, automatically sets to current datetime when record is created. Default: `false`
- `type::String`: The database column type. Can be either `"TIMESTAMPTZ"` (default) or `"TIMESTAMP"`. Default: `"TIMESTAMPTZ"`

# Important Note: TIMESTAMPTZ vs TIMESTAMP
By default, `DateTimeField` uses `TIMESTAMPTZ`. 
- **TIMESTAMPTZ** (Recommended): Stores values in UTC internally and converts them to your session's timezone upon retrieval. This ensures consistency across different geographical regions.
- **TIMESTAMP**: Stores the exact date and time provided without any timezone conversion.

# Examples
```julia
# Basic datetime field
created_at = DateTimeField()

# Auto-timestamp fields
created_at = DateTimeField(auto_now_add=true)
updated_at = DateTimeField(auto_now=true)

# Indexed datetime for queries
event_time = DateTimeField(db_index=true, verbose_name="Event Timestamp")

# With default value
scheduled_at = DateTimeField(default=DateTime(2024, 1, 1, 12, 0, 0))

# Optional datetime field
deadline = DateTimeField(null=true, blank=true)```
```
"""
function DateTimeField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, auto_now, auto_now_add) =
    _common_kwargs("DateTimeField", kwargs; bools = (auto_now = false, auto_now_add = false), extra = (:type,))

  default = get(kwargs, :default, nothing)
  #TIMESTAMPTZ
  type = get(kwargs, :type, "TIMESTAMPTZ") |> uppercase

  normalize_datetime_default(value) = begin
    if value === nothing
      nothing
    elseif value isa Union{ZonedDateTime, DateTime}
      value
    elseif value isa AbstractString
      try
        ZonedDateTime(value, DATETIME_FORMAT)
      catch
        try
          DateTime(value, DATETIME_FORMAT)
        catch
          DateTime(value)
        end
      end
    else
      throw(_fielderr("Invalid default value for DateTimeField. Expected a DateTime, ZonedDateTime, or parseable datetime string."))
    end
  end

  # Validate default
  default = validate_default(default, Union{ZonedDateTime, DateTime, Nothing}, "DateTimeField", normalize_datetime_default)
  !(type isa String) && throw(_fielderr("The 'type' must be a String"))
  if type != "TIMESTAMPTZ" && type != "TIMESTAMP"
    throw(_fielderr("The 'type' must be either 'TIMESTAMPTZ' or 'TIMESTAMP'"))
  end
  # Return the field instance
  return sDateTimeField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    auto_now,
    auto_now_add,
    type,
    format_timezone_sql
  )  
end

mutable struct sDecimalField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Float64, Nothing}
  editable::Bool
  max_digits::Int
  decimal_places::Int
  type::String
  formatter::Function
end

"""
    DecimalField(; kwargs...)

A field for storing decimal numbers with fixed precision and scale.

# Keyword Arguments
- `verbose_name::Union{String, Nothing}`: Human-readable name for the field. Default: `nothing`
- `unique::Bool`: If `true`, ensures field values are unique across the table. Default: `false`
- `blank::Bool`: If `true`, allows empty values in forms/validation. Default: `false`
- `null::Bool`: If `true`, allows NULL values in the database. Default: `false`
- `db_index::Bool`: If `true`, creates a database index for faster queries. Default: `false`
- `default::Union{Float64, Nothing}`: Default value for the field. Default: `nothing`
- `editable::Bool`: If `true`, field can be edited in forms. Default: `false`
- `max_digits::Int`: Maximum number of digits allowed (including decimal places). Default: `10`
- `decimal_places::Int`: Number of decimal places to store. Default: `2`

# Examples
```julia
# Currency field (2 decimal places)
price = DecimalField(max_digits=10, decimal_places=2)

# High precision scientific values
measurement = DecimalField(max_digits=15, decimal_places=6)

# Percentage with 4 decimal places
rate = DecimalField(max_digits=7, decimal_places=4, default=0.0)

# Financial calculation field
amount = DecimalField(
    max_digits=12, 
    decimal_places=2, 
    verbose_name="Transaction Amount",
    db_index=true
)

# Optional decimal field
discount = DecimalField(
    max_digits=5, 
    decimal_places=2, 
    null=true, 
    blank=true
)
```
"""
function DecimalField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key) =
    _common_kwargs("DecimalField", kwargs; primary_key = false, extra = (:max_digits, :decimal_places))

  default = get(kwargs, :default, nothing)
  max_digits = get(kwargs, :max_digits, 10)
  decimal_places = get(kwargs, :decimal_places, 2)

  # Validate primary_key rejection for Decimal (Best practice)
  if primary_key === true
    throw(_fielderr("DecimalField cannot be used as a Primary Key due to precision comparison risks. Use IDField or CharField instead."))
  end

  
  # Validate default using validate_default
  default = validate_default(default, Union{Float64, Nothing}, "DecimalField", format2float64)
  max_digits = validate_default(max_digits, Int, "DecimalField", format2int64)
  decimal_places = validate_default(decimal_places, Int, "DecimalField", format2int64)
  
  # Validate scale vs precision
  if decimal_places > max_digits
    throw(_fielderr("DecimalField 'decimal_places' ($decimal_places) cannot be greater than 'max_digits' ($max_digits)"))
  end

  return sDecimalField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    max_digits,
    decimal_places,
    "DECIMAL",
    format_number_sql
  )
end

mutable struct sEmailField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    EmailField(; kwargs...)

A field for storing and validating email addresses.

# Keyword Arguments
- `verbose_name::Union{String, Nothing}`: Human-readable name for the field. Default: `nothing`
- `unique::Bool`: If `true`, ensures field values are unique across the table. Default: `false`
- `blank::Bool`: If `true`, allows empty values in forms/validation. Default: `false`
- `null::Bool`: If `true`, allows NULL values in the database. Default: `false`
- `db_index::Bool`: If `true`, creates a database index for faster queries. Default: `false`
- `default::Union{String, Nothing}`: Default email address. Default: `nothing`
- `editable::Bool`: If `true`, field can be edited in forms. Default: `false`

# Examples
```julia
# Basic email field
email = EmailField()

# Unique email for user accounts
user_email = EmailField(unique=true, verbose_name="User Email")

# Optional contact email
contact_email = EmailField(null=true, blank=true)

# Email with default value
notification_email = EmailField(default="admin@example.com")

# Indexed email for fast lookups
primary_email = EmailField(
    unique=true, 
    db_index=true, 
)
```
"""
function EmailField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("EmailField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = validate_default(default, Union{String, Nothing}, "EmailField", x -> parse(String, x))
  # Return the field instance
  return sEmailField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "VARCHAR",
    format_text_sql
  )  
end

# ============================================================================
# Password Field 
# ============================================================================

# Password Field Definition

mutable struct sPasswordField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
  max_length::Int  # Length of stored hash (Django uses VARCHAR(128))
  auto_hash::Bool  # Accepted for Django compat; PormG performs no hashing
end

"""
    PasswordField(; kwargs...)

A `VARCHAR(128)` field for storing a Django-format password hash.

`PasswordField` is a storage type only: PormG does not hash or verify passwords. Produce the
hash in your application and assign the resulting string to this field. The stored format
matches Django's authentication system, so tables written this way stay compatible with
Django's own auth code.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values  
- `editable::Bool = true`: Whether the field should be editable in forms
- `max_length::Int = 128`: Maximum length for stored hash (Django default)
- `auto_hash::Bool = true`: Accepted for Django compatibility; PormG performs no hashing

# Database Mapping
- **PostgreSQL Type**: VARCHAR(128)
- **Storage Format**: `pbkdf2_sha256\$iterations\$salt\$base64hash`
- **Index**: Not indexed by default (passwords shouldn't be queried)

# Stored Format
The password is stored in Django-compatible format:
```
pbkdf2_sha256\$720000\$salt\$base64encodedHash
```

Where:
- `pbkdf2_sha256`: Algorithm identifier
- `720000`: Number of iterations
- `salt`: Random 22-character salt
- `base64encodedHash`: The derived key in base64

# Examples

Basic password field:
```julia
# Define a User model with password
User = Models.Model(
    _id = Models.IDField(),
    username = Models.CharField(max_length=150, unique=true),
    email = Models.EmailField(unique=true),
    password = Models.PasswordField()
)
```

Hashing and verification live in your application, not in PormG — generate the Django-format
hash there and assign the resulting string to the field.

# Migration from Django
If you're migrating from a Django application, password hashes are fully compatible.
Users can continue to log in without any password reset.

# See Also
- `CharField` for generic string storage
- Django's password management documentation
"""
function PasswordField(; kwargs...)
  (; verbose_name, blank, null, db_column, editable, auto_hash) =
    _common_kwargs("PasswordField", kwargs; editable = true, exclude = (:unique, :db_index, :default), extra = (:max_length,), bools = (auto_hash = true,))

  max_length = get(kwargs, :max_length, 128)

  !(max_length isa Int) && throw(_fielderr("The 'max_length' must be an Integer"))
  max_length < 64 && throw(_fielderr("The 'max_length' must be at least 64 to store password hashes"))
  
  # Return the field instance
  return sPasswordField(
    verbose_name,
    false, # primary_key - passwords should never be primary keys
    false, # unique - passwords should not be unique (allows same password for different users)
    blank,
    null,
    false, # db_index - never index passwords
    db_column,
    nothing, # default - no default password
    editable,
    "VARCHAR",
    format_text_sql,
    max_length,
    auto_hash
  )
end

mutable struct sFloatField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Float64, String, Int64, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    FloatField(; kwargs...)

A field for storing floating-point numbers with double precision.

# Keyword Arguments
- `verbose_name::Union{String, Nothing}`: Human-readable name for the field. Default: `nothing`
- `unique::Bool`: If `true`, ensures field values are unique across the table. Default: `false`
- `blank::Bool`: If `true`, allows empty values in forms/validation. Default: `false`
- `null::Bool`: If `true`, allows NULL values in the database. Default: `false`
- `db_index::Bool`: If `true`, creates a database index for faster queries. Default: `false`
- `default::Union{Float64, String, Int64, Nothing}`: Default value for the field. Default: `nothing`
- `editable::Bool`: If `true`, field can be edited in forms. Default: `false`

# Examples
```julia
# Basic float field
temperature = FloatField()

# Scientific measurement with default
ph_level = FloatField(default=7.0)

# Optional measurement
weight = FloatField(null=true)
```
"""
function FloatField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key) =
    _common_kwargs("FloatField", kwargs; primary_key = false)

  default = get(kwargs, :default, nothing)

  # Validate primary_key rejection for Float (Best practice)
  if primary_key === true
    throw(_fielderr("FloatField cannot be used as a Primary Key due to precision comparison risks. Use IDField or CharField instead."))
  end

  
  # Validate default using validate_default
  default = validate_default(default, Union{Float64, Nothing}, "FloatField", format2float64)
  

  return sFloatField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "FLOAT",
    format_number_sql
  )  
end

mutable struct sImageField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    ImageField(; kwargs...)

A field for storing image file references and metadata.

# Keyword Arguments
- `verbose_name::Union{String, Nothing}`: Human-readable name for the field. Default: `nothing`
- `unique::Bool`: If `true`, ensures field values are unique across the table. Default: `false`
- `blank::Bool`: If `true`, allows empty values in forms/validation. Default: `false`
- `null::Bool`: If `true`, allows NULL values in the database. Default: `false`
- `db_index::Bool`: If `true`, creates a database index for faster queries. Default: `false`
- `default::Union{String, Nothing}`: Default image path or URL. Default: `nothing`
- `editable::Bool`: If `true`, field can be edited in forms. Default: `false`

# Examples
```julia
# Basic image field
avatar = ImageField()

# Product image with default
product_image = ImageField(
    default="/static/images/default-product.jpg",
    verbose_name="Product Image"
)

# Optional profile picture
profile_pic = ImageField(null=true)

# Unique banner image
banner = ImageField(
    unique=true,
    db_index=true
)
```
"""
function ImageField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("ImageField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = validate_default(default, Union{String, Nothing}, "ImageField", x -> parse(String, x))
  # Return the field instance
  return sImageField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "BLOB",
    format_text_sql
  )  
end

"""
    FileField(; kwargs...)

Django-compatibility alias for storing file upload paths. Behaves identically to `ImageField`.
Accepted kwargs: `verbose_name`, `unique`, `blank`, `null`, `db_index`, `default`, `editable`, `upload_to`, `max_length`.
"""
function FileField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("FileField", kwargs; editable = true, extra = (:upload_to, :max_length))

  default = get(kwargs, :default, nothing)
  default = validate_default(default, Union{String, Nothing}, "FileField", x -> parse(String, x))

  return sImageField(
    verbose_name,
    false,
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "BLOB",
    format_text_sql
  )
end

mutable struct sTextField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    TextField(; kwargs...)

A field for storing large amounts of text without length restrictions.

# Keyword Arguments
- `verbose_name::Union{String, Nothing}`: Human-readable name for the field. Default: `nothing`
- `unique::Bool`: If `true`, ensures field values are unique across the table. Default: `false`
- `blank::Bool`: If `true`, allows empty values in forms/validation. Default: `false`
- `null::Bool`: If `true`, allows NULL values in the database. Default: `false`
- `db_index::Bool`: If `true`, creates a database index for faster queries. Default: `false`
- `default::Union{String, Nothing}`: Default text content. Default: `nothing`
- `editable::Bool`: If `true`, field can be edited in forms. Default: `false`

# Examples  
```julia
# Basic text field for long content
description = TextField()

# Blog post content
content = TextField(blank=true)

# Optional notes field
notes = TextField(null=true, blank=true)

# Indexed text field for search
searchable_content = TextField(
    db_index=true
)

# Text field with default content
template = TextField(
    default="Enter your text here...",
    verbose_name="Template Content"
)
```
"""
function TextField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("TextField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = validate_default(default, Union{String, Nothing}, "TextField", x -> parse(String, x))
  # Return the field instance
  return sTextField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "TEXT",
    format_text_sql
  )  
end

mutable struct sTimeField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Time, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    TimeField(; kwargs...)

Time of day with no date component — SQL `TIME`.

`default` accepts a `Time` or anything `Time(x)` parses (e.g. `"09:30:00"`); an invalid value raises
`FieldValidationError` at model-definition time rather than on the first insert.

# Examples
```julia
Team_store = Models.Model("team_store",
  id           = Models.IDField(),
  name         = Models.CharField(max_length = 100),
  opening_time = Models.TimeField(),
  closing_time = Models.TimeField(null = true),
)
```

See also [`DateField`](@ref), [`DateTimeField`](@ref), [`DurationField`](@ref).
"""
function TimeField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("TimeField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = validate_default(default, Union{Time, Nothing}, "TimeField", x -> Time(x))
  # Return the field instance
  return sTimeField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "TIME",
    format_text_sql
  )  
end

mutable struct sBinaryField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{Vector{UInt8}, Nothing}
  editable::Bool
  type::String
  formatter::Function
  max_length::Union{Int, Nothing}
end

"""
    BinaryField(; max_length = nothing, kwargs...)

A column for raw binary payloads — images, compressed blobs, encrypted content.

**Database Type**: `BYTEA` on PostgreSQL, `BLOB` on SQLite.

Values are **raw bytes in and raw bytes out**: write a `Vector{UInt8}` and read a `Vector{UInt8}`
back. Arbitrary byte sequences round-trip intact, including `0x00` and payloads that are not valid
UTF-8.

An `AbstractString` is also accepted on write and stored as its **UTF-8 code units** — the form
that keeps a column which used to be `TEXT` writable without an app edit. To store the *decoded*
bytes of an encoded string, decode it yourself: `hex2bytes(s)`, `base64decode(s)`.

# Keyword Arguments
- `max_length::Union{Int, Nothing} = nothing`: maximum payload size in **bytes** (not characters).
  Enforced both before the query is built and by a `CHECK` constraint in the DDL —
  `octet_length` on PostgreSQL, `length` on SQLite. `nothing` means unbounded.
- `default::Union{Vector{UInt8}, Nothing} = nothing`: rendered into the DDL as a byte literal
  (`'\\x…'::bytea` / `X'…'`). Must be a `Vector{UInt8}`; a `String` raises
  `FieldValidationError` rather than guessing whether you meant its code units or a decoded
  encoding. Keep it small — it is written verbatim into generated model files.
- Plus the common field kwargs: `verbose_name`, `unique`, `blank`, `null`, `db_index`,
  `db_column`, `editable`.

# Examples
```julia
Technical_document = Models.Model("technical_document",
  id        = Models.IDField(),
  name      = Models.CharField(max_length = 200),
  file_data = Models.BinaryField(max_length = 5_000_000),   # BYTEA / BLOB, ≤ 5 MB
  mime_type = Models.CharField(max_length = 100),
)

Technical_document.objects.create(
  "name"      => "2024 Monza aero package",
  "file_data" => read("aero.pdf"),      # Vector{UInt8}
  "mime_type" => "application/pdf",
)
```

!!! note "SQLite reads a blob written by another Julia process"
    SQLite.jl stores unrecognized Julia values by serializing them into a BLOB, and its reader
    deserializes any blob carrying that serialization header. A payload PormG wrote is returned
    verbatim; one written by a different Julia program via `sqlserialize` may come back as the
    original object instead of bytes. Inherent to the driver, not to PormG.

See also [`FileField`](@ref), [`TextField`](@ref), [`CharField`](@ref).
"""
function BinaryField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("BinaryField", kwargs; extra = (:max_length,))

  default = get(kwargs, :default, nothing)
  max_length = get(kwargs, :max_length, nothing)

  # Validate default (#296). The reject case is checked HERE rather than left to
  # `validate_default`, whose bare `catch` discards the converter's exception and substitutes a
  # generic "Expected type: …" message — the same reason UUIDField and JSONField pre-check their
  # string defaults. `validate_default` still runs, to normalize the other byte-vector spellings
  # (`codeunits`, reinterpreted buffers, views) into a plain `Vector{UInt8}`.
  #
  # A String is rejected on purpose, even though the WRITE path accepts one as UTF-8 code units:
  # here the caller is defining a model, and `default = "0102"` is far more likely to mean the two
  # bytes `0x01 0x02` than the four characters. Guessing either way silently writes the wrong
  # DEFAULT into the schema, so name the two decodings instead.
  if !(default isa Union{Nothing, AbstractVector{UInt8}})
    throw(_fielderr(_binary_default_message(default)))
  end
  default = validate_default(default, Union{Vector{UInt8}, Nothing}, "BinaryField", _binary_default_bytes)
  if max_length isa AbstractString
    if occursin(r"\d+", max_length)
      max_length = validate_default(max_length, Int, "BinaryField", format2int64)
    else
      max_length = nothing
    end
  end
  if !(max_length isa Union{Nothing, Int})
    throw(_fielderr("The 'max_length' must be an integer or nothing"))
  elseif max_length isa Int && max_length <= 0
    throw(_fielderr("The 'max_length' must be a positive integer"))
  end
  # Return the field instance
  return sBinaryField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    # The canonical (SQLite) spelling. Each backend's reverse type map translates it —
    # `sqlite_type_map_reverse["BLOB"] == "BLOB"`, `postgres_type_map_reverse["BLOB"] == "bytea"` —
    # the same way "TIMESTAMPTZ" becomes DATETIME on SQLite. Keeping one canonical string is what
    # lets the migration planner diff two BinaryFields without knowing the backend.
    "BLOB",
    format_binary_sql,
    max_length
  )
end

mutable struct sDurationField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    DurationField(; kwargs...)

An elapsed time span — `INTERVAL` on both PostgreSQL and SQLite.

`default` is validated at model-definition time and re-raised as `FieldValidationError`, so a bad
`default=` surfaces where the mistake is rather than on the insert path (where the same coercion
raises `InvalidValueError`).

# Examples
```julia
Pit_task = Models.Model("pit_task",
  id                 = Models.IDField(),
  name               = Models.CharField(max_length = 200),
  estimated_duration = Models.DurationField(),
  actual_duration    = Models.DurationField(null = true),
)
```

See also [`TimeField`](@ref), [`DateTimeField`](@ref).
"""
function DurationField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("DurationField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default. `format_duration_sql` raises InvalidValueError — correct on the insert/update
  # path, but here the caller's mistake is the `default=` kwarg at model-definition time. Re-raise as
  # FieldValidationError so every field constructor reports the same category (#239), matching the
  # UUIDField/JSONField string-default paths and validate_default's converter branch.
  default = if default === nothing
    nothing
  else
    try
      format_duration_sql(default)
    catch e
      e isa InvalidValueError || rethrow(e)
      throw(FieldValidationError("Invalid default value for DurationField: $(e.msg)"))
    end
  end
  # Return the field instance
  return sDurationField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "INTERVAL",
    format_duration_sql
  )
end

# ============================================================================
# UUID Field
# ============================================================================

mutable struct sUUIDField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
  auto_add::Bool
end

"""
    UUIDField(; kwargs...)

A field for storing universally unique identifiers (UUIDs).

Maps to PostgreSQL's native `UUID` type and stores as `TEXT` in SQLite.
Values are validated against the standard UUID format (8-4-4-4-12 hex digits).

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `primary_key::Bool = false`: Whether this field is the primary key for the table
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{String, Nothing} = nothing`: Default UUID value as a string
- `editable::Bool = true`: Whether the field should be editable in forms
- `auto_add::Bool = false`: If true, automatically generates a UUID (`uuid4()`) when creating a new record without a provided value.

# Database Mapping
- **PostgreSQL Type**: UUID
- **SQLite Type**: TEXT

# Examples
```julia
using UUIDs

Session = Models.Model(
    _id = IDField(),
    session_token = UUIDField(unique=true, db_index=true),
    user_id = ForeignKey("User")
)
```
"""
function UUIDField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, auto_add) =
    _common_kwargs("UUIDField", kwargs; primary_key = false, editable = true, bools = (auto_add = false,))

  default = get(kwargs, :default, nothing)

  # Validate UUID format for string defaults (validate_default won't invoke the
  # converter when the value already matches Union{String, Nothing})
  if default isa AbstractString
    # `format_uuid_sql` raises InvalidValueError — correct on the insert/update path, but here the
    # caller's mistake is the `default=` kwarg at model-definition time. Re-raise as
    # FieldValidationError so every field constructor reports the same category (#239);
    # validate_default (the `else` branch) already does this for non-String defaults.
    default = try
      format_uuid_sql(default)
    catch e
      e isa InvalidValueError || rethrow(e)
      throw(FieldValidationError("Invalid default value for UUIDField: $(e.msg)"))
    end
  else
    default = validate_default(default, Union{String, Nothing}, "UUIDField", x -> format_uuid_sql(x))
  end

  return sUUIDField(
    verbose_name,
    primary_key,
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "UUID",
    format_uuid_sql,
    auto_add
  )
end

# ============================================================================
# URL Field
# ============================================================================

mutable struct sURLField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  max_length::Int
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    URLField(; kwargs...)

A field for storing URLs, validated against a basic URL pattern.

Maps to `VARCHAR(max_length)` in the database. Values are validated to start
with `http://`, `https://`, or `ftp://`.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `max_length::Int = 200`: Maximum number of characters allowed
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{String, Nothing} = nothing`: Default URL value
- `editable::Bool = true`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: VARCHAR(max_length)
- **SQLite Type**: TEXT(max_length)

# Examples
```julia
Circuit = Models.Model(
    _id = IDField(),
    name = CharField(max_length=200),
    wiki_url = URLField(null=true, blank=true, verbose_name="Wikipedia Link")
)
```
"""
function URLField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("URLField", kwargs; editable = true, extra = (:max_length,))

  max_length = get(kwargs, :max_length, 200)
  default = get(kwargs, :default, nothing)

  max_length isa AbstractString && (max_length = parse(Int, max_length))
  max_length isa Int || throw(_fielderr("The max_length must be an integer"))
  max_length < 1 && throw(_fielderr("The max_length must be greater than 0"))

  default = validate_default(default, Union{String, Nothing}, "URLField", x -> string(x))

  return sURLField(
    verbose_name,
    false, # primary_key
    max_length,
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "VARCHAR",
    format_text_sql
  )
end

# ============================================================================
# Slug Field
# ============================================================================

mutable struct sSlugField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  max_length::Int
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    SlugField(; kwargs...)

A field for storing URL-friendly slug strings.

Slugs may contain only lowercase letters, numbers, hyphens, and underscores.
Maps to `VARCHAR(max_length)` in the database. Typically used for
human-readable URL fragments derived from titles or names.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `max_length::Int = 50`: Maximum number of characters allowed
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = true`: Whether to create a database index on this field (true by default for slugs)
- `default::Union{String, Nothing} = nothing`: Default slug value
- `editable::Bool = true`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: VARCHAR(max_length)
- **SQLite Type**: TEXT(max_length)

# Examples
```julia
Race = Models.Model(
    _id = IDField(),
    name = CharField(max_length=200),
    slug = SlugField(unique=true, verbose_name="URL Slug")
)
```
"""
function SlugField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("SlugField", kwargs; db_index = true, editable = true, extra = (:max_length,))

  max_length = get(kwargs, :max_length, 50)
  default = get(kwargs, :default, nothing)

  max_length isa AbstractString && (max_length = parse(Int, max_length))
  max_length isa Int || throw(_fielderr("The max_length must be an integer"))
  max_length > 255 && throw(_fielderr("The max_length must be less than or equal to 255"))
  max_length < 1 && throw(_fielderr("The max_length must be greater than 0"))

  default = validate_default(default, Union{String, Nothing}, "SlugField", x -> string(x))

  return sSlugField(
    verbose_name,
    false, # primary_key
    max_length,
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "VARCHAR",
    format_text_sql
  )
end

# ============================================================================
# JSON Field
# ============================================================================

mutable struct sJSONField <: PormGField
  verbose_name::Union{String, Nothing}
  primary_key::Bool
  unique::Bool
  blank::Bool
  null::Bool
  db_index::Bool
  db_column::Union{String, Nothing}
  default::Union{String, Nothing}
  editable::Bool
  type::String
  formatter::Function
end

"""
    JSONField(; kwargs...)

A field for storing JSON-encoded data.

Maps to PostgreSQL's native `JSONB` type (binary JSON with indexing support)
and stores as `TEXT` in SQLite. Values are validated as parseable JSON before
being sent to the database.

# Keyword Arguments
- `verbose_name::Union{String, Nothing} = nothing`: A human-readable name for the field
- `unique::Bool = false`: Whether values in this field must be unique across all records
- `blank::Bool = false`: Whether the field can be left blank in forms
- `null::Bool = false`: Whether the database column can store NULL values
- `db_index::Bool = false`: Whether to create a database index on this field
- `default::Union{String, Nothing} = nothing`: Default JSON value as a string
- `editable::Bool = true`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: JSONB
- **SQLite Type**: TEXT

# Examples
```julia
Race = Models.Model(
    _id = IDField(),
    name = CharField(max_length=200),
    metadata = JSONField(null=true, blank=true, verbose_name="Extra Data")
)
```

# Notes
- Values must be valid JSON strings when passed as strings.
- Dict and Vector values are automatically serialized to JSON strings.
- PostgreSQL JSONB supports GIN indexing for efficient key/value lookups.
"""
function JSONField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable) =
    _common_kwargs("JSONField", kwargs; editable = true)

  default = get(kwargs, :default, nothing)

  # Validate JSON format for string defaults (validate_default won't invoke the
  # converter when the value already matches Union{String, Nothing})
  if default isa AbstractString
    # `format_json_sql` raises InvalidValueError — correct on the insert/update path, but here the
    # caller's mistake is the `default=` kwarg at model-definition time. Re-raise as
    # FieldValidationError so every field constructor reports the same category (#239);
    # validate_default (the `else` branch) already does this for non-String defaults.
    default = try
      format_json_sql(default)
    catch e
      e isa InvalidValueError || rethrow(e)
      throw(FieldValidationError("Invalid default value for JSONField: $(e.msg)"))
    end
  else
    default = validate_default(default, Union{String, Nothing}, "JSONField", x -> format_json_sql(x))
  end

  return sJSONField(
    verbose_name,
    false, # primary_key
    unique,
    blank,
    null,
    db_index,
    db_column,
    default,
    editable,
    "JSONB",
    format_json_sql
  )
end

