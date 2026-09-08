# ==============================================================================
# CANONICAL COLUMN IR (#507) — THE COMPILER
#
# `makemigrations` used to decide "did this column change?" by comparing two `PormGField` STRUCTS —
# one from the models file, one reconstructed from the live schema by the introspection readers. The
# reader side is lossy by construction: a type map returns exactly ONE struct per rendered type, so
# `CharField` / `URLField` / `SlugField` all come back as one struct, and on SQLite a `BIGINT` column
# comes back as `sIntegerField`. Struct identity is therefore NOT column identity, and the planner
# grew three comparators plus an escape hatch trying to bridge the gap — #325, #408, #409, #417,
# #437, #498, #503 are all the same bug wearing different clothes.
#
# This file is the bridge, replacing all four: both sides compile to a `ColumnSpec` describing what
# the DATABASE can hold, and the diff runs on that. The reader's lossy struct choice stops mattering
# because **every struct that renders the same compiles the same** — which is true by construction,
# not by coincidence, because `column_spec` renders through `Dialect._get_column_type`, the very
# function the DDL path uses.
#
# WHAT LIVES WHERE (#507 phase 2). The IR itself — `ColumnSpec`, `ColumnDelta`, `CanonicalType` and
# the diff over them — is `src/column_ir.jl`, at layer 1, because `Dialect` renders an ALTER from a
# `ColumnDelta` and is included BEFORE this file. What stays here is everything that has to know what
# a `PormGField` is: the per-engine type parse, the attribute classification, and the compiler. The
# split is by dependency, not by taste — this half calls `Models` and `Dialect`, that half calls
# nothing.
#
# Prior art (checked, not assumed — see the decisions comment on #507):
#   * Prisma Migrate — schema and live database both compile to one `SqlSchema`; a differ produces
#     the steps. "Two compilers, one diff".
#   * Atlas — a per-driver NORMALIZER run on both sides before `Diff`. That is where engine
#     equivalence belongs, and it is why `parse_canonical_type` is per-engine and everything after
#     it is not.
#   * Alembic — `compare_type` is a hook precisely because type equivalence is the one
#     engine-specific part. A closed `CanonicalType` set makes that data instead of a callback.
#   * Django — one skip list in one place (`Field.non_db_attrs`, subtracted by
#     `_field_should_be_altered`), which `NON_DB_ATTRS` below is named after.
#
# STILL OUT OF SCOPE, and now the only phase left. The introspection readers are NOT touched: they
# produce `PormGField` structs and `column_spec` is applied to both sides. Compiling introspection's
# raw facts straight to a `ColumnSpec` — which is what finally deletes the lossy reverse type map —
# is phase 3, and phase 1 was written so that it is a substitution rather than a redesign.
# ==============================================================================

# ── The attribute classification, in ONE place ───────────────────────────────────────────────────
#
# This replaces `_NON_SCHEMA_FIELD_ATTRS` and the two other lists that disagreed with it. Named after
# Django's `Field.non_db_attrs` — *"Attributes that don't affect a column definition. These attributes
# are ignored when altering the field."* — so a reader arriving from Django recognises the concept.
#
# The drift guard in `test/unit/test_column_spec.jl` asserts that every slot of every concrete
# `PormGField` appears in exactly one of these two tuples. A new field slot that the compiler neither
# reads nor classifies fails the suite, instead of silently becoming a column difference nobody meant.

"""
    NON_DB_ATTRS

Field attributes no DDL path expresses, so a difference in one can never be a column change.

  * `blank`, `editable`, `verbose_name`, `related_name`, `how`, `formatter`, `choices` — model-layer
    only. (`choices` is on Django's list too, and was *unclassified* here before #507, which is why a
    declared `CharField(choices = …)` could reach `alter_field`'s "not implemented" warning.)
  * `db_index` — materialized by CREATE/DROP INDEX and planned separately; see `ColumnSpec`.
  * `auto_now`, `auto_now_add`, `auto_add`, `auto_hash` — PormG computes these in Julia on write.
    None is a column DEFAULT and none is a trigger, so introspection always reads them back as the
    constructor default no matter what was declared (#325, #334).
  * `through`, `db_table`, `source_field`, `target_field` — `sManyToManyField` only, which is not a
    physical column at all (`column_spec` refuses it).

`on_update`, `deferrable` and `initially_deferred` were on this list from #507 until **#516** removed
the three keywords outright. There is no slot left to classify — they are gone from `sForeignKey` and
`sOneToOneField`, and `_common_kwargs` refuses them at declaration time instead.
"""
const NON_DB_ATTRS = (:blank, :choices, :db_index, :editable, :verbose_name, :related_name,
                      :how, :formatter,
                      :auto_now, :auto_now_add, :auto_add, :auto_hash,
                      :through, :db_table, :source_field, :target_field)

"""
    SCHEMA_ATTRS

Field attributes `column_spec` reads. Being here means "the compiler consults it", which is not quite
the same as "a difference in it is a delta" — two entries are read to *resolve* something rather than
to be compared:

  * `db_column` resolves `ColumnSpec.name`, which is excluded from equality (a rename is planned
    elsewhere);
  * `to_table` resolves `ForeignKeyRef.table`, the physical parent — it is never compared on its own,
    which is what stopped every foreign key reporting a difference on every run (#360).
"""
const SCHEMA_ATTRS = (:type, :primary_key, :unique, :null, :default, :db_column,
                      :max_length, :max_digits, :decimal_places,
                      :to, :to_table, :pk_field, :on_delete, :db_constraint,
                      :generated, :generated_always, :auto_increment)

# ── Type parsing: where engine equivalence lives, once ───────────────────────────────────────────

# Split `varchar(120)` / `decimal(10, 2)` / `bigint` into a lower-cased base and its arguments.
function _split_rendered_type(raw::AbstractString)
  s = strip(String(raw))
  open_paren = findfirst('(', s)
  open_paren === nothing && return (lowercase(s), Int[])
  base = lowercase(strip(s[1:prevind(s, open_paren)]))
  close_paren = findlast(')', s)
  inner = close_paren === nothing ? s[nextind(s, open_paren):end] :
                                    s[nextind(s, open_paren):prevind(s, close_paren)]
  args = Int[]
  for part in split(inner, ',')
    parsed = tryparse(Int, strip(part))
    parsed === nothing && return (base, Int[])   # a non-numeric modifier: treat as unparameterized
    push!(args, parsed)
  end
  return (base, args)
end

_arg(args::Vector{Int}, i::Int) = length(args) >= i ? args[i] : nothing

"""
    parse_canonical_type(raw, conn) -> CanonicalType

Map a rendered SQL type onto the closed `CanonicalType` set for `conn`'s engine.

**This is the only place engine equivalence is expressed** — Atlas's per-driver normalizer, run on
both sides before the diff. Every collapse below is FORCED by what `Dialect._get_column_type` writes,
never chosen for convenience: two spellings collapse only when PormG renders both as the same string,
so the database genuinely cannot tell them apart and introspection has no way to recover which was
declared. Two spellings PormG writes distinctly must stay distinct, or a real declaration change
would stop being planned.

Unrecognised input degrades to `CUnsupported(lowercased raw)`, which compares by that string — the
behaviour `Dialect._column_signature` had for every type — so an exotic column loses precision, never
correctness, and never aborts `makemigrations`.
"""
function parse_canonical_type(raw::AbstractString, ::PormGPostgres)::CanonicalType
  base, args = _split_rendered_type(raw)
  base == "smallint"                      && return CInt16()
  base in ("integer", "int", "int4", "serial")         && return CInt32()
  base in ("bigint", "int8", "bigserial")              && return CInt64()
  # PormG has a single float field, so `real`/`float4` is unrepresentable in a model and the
  # precision distinction cannot be declared, let alone changed.
  base in ("float", "float8", "float4", "real", "double precision") && return CFloat64()
  base in ("decimal", "numeric")          && return CDecimal(_arg(args, 1), _arg(args, 2))
  base in ("boolean", "bool")             && return CBool()
  base in ("varchar", "character varying") && return CVarChar(_arg(args, 1))
  base == "text"                          && return CText()
  base == "date"                          && return CDate()
  base in ("timestamptz", "timestamp with time zone")    && return CDateTime(true)
  base in ("timestamp", "timestamp without time zone")   && return CDateTime(false)
  base in ("time", "timetz", "time without time zone")   && return CTime()
  base == "interval"                      && return CInterval()
  base == "uuid"                          && return CUUID()
  base in ("json", "jsonb")               && return CJSON()
  base == "bytea"                         && return CBytes()
  return CUnsupported(lowercase(strip(String(raw))))
end

function parse_canonical_type(raw::AbstractString, ::PormGSQLite)::CanonicalType
  base, args = _split_rendered_type(raw)
  # THE #503 EQUIVALENCE. `sqlite_type_map_reverse` maps BOTH "BIGINT" and "INTEGER" to the literal
  # `INTEGER`, so a foreign key, an IDField, a BigIntegerField and an IntegerField all write the same
  # word and read back as one struct. There is no second spelling for the diff to recover, so
  # collapsing them is forced. This is what made a `db_constraint=false` foreign key rebuild its
  # SQLite table on every makemigrations, forever.
  base in ("integer", "int", "bigint", "int8", "serial", "bigserial") && return CInt64()
  # NOT collapsed into the above, deliberately. PormG writes "SMALLINT" and "INTEGER UNSIGNED"
  # verbatim on SQLite and `sqlite_type_map` reads both back, so a change between them IS observable
  # and must still be planned — even though SQLite gives all three the same INTEGER affinity. The
  # rule is "collapse what the renderer makes indistinguishable", not "collapse what the engine
  # stores alike".
  base == "smallint"                      && return CInt16()
  base == "integer unsigned"              && return CInt32()
  base in ("real", "float", "double", "double precision") && return CFloat64()
  base in ("decimal", "numeric")          && return CDecimal(_arg(args, 1), _arg(args, 2))
  base in ("boolean", "bool")             && return CBool()
  # `TEXT(n)` is what a CharField/URLField/SlugField renders here; bare `TEXT` is what UUIDField,
  # JSONField, TextField and the `else`-arm fields all collapse to through `sqlite_type_map_reverse`.
  base in ("varchar", "char", "character", "text", "nvarchar", "clob") &&
    return _arg(args, 1) === nothing ? CText() : CVarChar(_arg(args, 1))
  base == "date"                          && return CDate()
  # SQLite has no timezone type: `TIMESTAMPTZ` and `DATETIME` both render `DATETIME` through
  # `sqlite_type_map_reverse`, so collapsing those two is forced by the renderer like every other
  # collapse above.
  #
  # `TIMESTAMP` is the ONE case knowingly outside that rule, and the reason is the READER, not
  # affinity. It reaches here only from `DateTimeField(type = "TIMESTAMP")` — the reverse map has no
  # key, so the string passes through verbatim — and `sqlite_type_map` has no `"TIMESTAMP"` key
  # either, so a column declared that way is read back as a `TextField`. There is therefore NO
  # spelling of the declared side that can ever equal the live side for such a column: refusing the
  # collapse would buy a distinction the diff can never act on while adding a second permanent churn
  # for the far more common "database says DATETIME, model says TIMESTAMP" pair, which describes one
  # physical column. Collapsing converges that pair and changes nothing else. (Do not read this as
  # licence for the affinity argument the SMALLINT comment above rejects — the justification here is
  # that the reader cannot distinguish them at all, not that the engine stores them alike.)
  base in ("datetime", "timestamp", "timestamptz") && return CDateTime(false)
  base == "time"                          && return CTime()
  base == "interval"                      && return CInterval()
  base == "uuid"                          && return CUUID()
  base in ("json", "jsonb")               && return CJSON()
  base == "blob"                          && return CBytes()
  return CUnsupported(lowercase(strip(String(raw))))
end

# ── The compiler ─────────────────────────────────────────────────────────────────────────────────

# Render through the SAME function the DDL path uses. That identity is the whole mechanism: it is why
# "two structs that render the same column compile to the same spec" is true by construction rather
# than by a table someone has to keep in sync.
#
# Guarded, because the IR compiles EVERY column while the old attribute-wise branch rendered none —
# so a field whose `.type` is missing from `postgres_type_map_reverse` (a `KeyError` there) would
# newly abort a `makemigrations` that used to survive. Degrading to the raw `.type` keeps such a
# column comparable with itself, which is exactly the "degrades instead of aborting" the #507
# decision asks of `CUnsupported`.
function _render_column_type(field::PormGField, conn::Union{PormGPostgres, PormGSQLite})::String
  try
    return Dialect._get_column_type(field, conn)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    fallback = hasfield(typeof(field), :type) ? String(getfield(field, :type)) : string(nameof(typeof(field)))
    # Reported, not swallowed. Degrading to the declared type string keeps the column comparable with
    # itself, but it means the diff is no longer reasoning about the real column — and dropping that
    # on `@debug`, invisible by default, is the same silent-drop shape this file refuses for the
    # unrendered foreign-key options below (and that #501 closed in the importer).
    @warn "Could not render a column type; the migration diff will compare this column by its " *
          "declared type instead, which may miss a real change" field_type=typeof(field) fallback exception=e maxlog = 1
    return fallback
  end
end

_slot(field::PormGField, name::Symbol, fallback) =
  hasfield(typeof(field), name) ? getfield(field, name) : fallback

function _column_default(field::PormGField)::ColumnDefault
  value = _slot(field, :default, nothing)
  value === nothing && return NoDefault()
  return LiteralDefault(value)
end

function _column_checks(field::PormGField)::Vector{CheckKind}
  # Built in a fixed order so plain `==` on the vector is a set comparison in practice. Both
  # predicates are `Dialect`'s, so "does this column carry that CHECK" has one definition shared with
  # `field_to_column` and `alter_field`.
  checks = CheckKind[]
  Dialect._requires_non_negative_check(field) && push!(checks, NonNegativeCheck())
  Dialect._requires_byte_length_check(field) && push!(checks, ByteLengthCheck(getfield(field, :max_length)))
  return checks
end

# Identity is engine-specific in a way the field struct is not: `sIDField` carries `generated`,
# `generated_always` AND `auto_increment` at all times, but PostgreSQL renders only the first two and
# SQLite renders only the third (`PRIMARY KEY AUTOINCREMENT`, and only for `sIDField`). Reading the
# slots the engine cannot express would manufacture a difference out of a constructor default.
function _column_identity(field::PormGField, ::PormGPostgres)::Union{Nothing, ColumnIdentity}
  _slot(field, :generated, false)::Bool || return nothing
  return ColumnIdentity(true, _slot(field, :generated_always, false)::Bool, false)
end

function _column_identity(field::PormGField, ::PormGSQLite)::Union{Nothing, ColumnIdentity}
  # THE CONDITION IS THE RENDERER'S, verbatim. `field_to_column(::PormGSQLite)` emits
  # `PRIMARY KEY AUTOINCREMENT` for `field isa sIDField && primary_key` and plain `PRIMARY KEY`
  # otherwise — it does NOT consult the `auto_increment` slot at all. Reading that slot here instead
  # made the IR disagree with the DDL in both directions: `IDField(auto_increment = false)` renders
  # AUTOINCREMENT but compiled to no identity (so it compared EQUAL to a plain `PRIMARY KEY` column —
  # two different columns, one spec), while `IDField()` vs `IDField(auto_increment = false)` render
  # byte-identical DDL yet compiled to a permanent `:auto_increment` delta, which on SQLite is a full
  # table rebuild forever.
  #
  # That is the "two answers to one fact" shape this whole file exists to remove, so it is spelled
  # once, here, against the renderer. If `field_to_column` ever learns to honour the slot, this moves
  # with it.
  (field isa Models.sIDField && _slot(field, :primary_key, false)::Bool) || return nothing
  return ColumnIdentity(false, false, true)
end

function _column_reference(field::PormGField)::Union{Nothing, ForeignKeyRef}
  # `sRelationalColumn` rather than a bare `isa sForeignKey`: the FK/O2O pair is spelled ONCE in
  # `src/models/fields.jl` precisely so a gate cannot silently miss half of it (#408/#409/#418/#437).
  field isa Models.sRelationalColumn || return nothing
  # No CONSTRAINT in the database means nothing for the diff to compare — which is the whole of #503
  # and #408: a `db_constraint = false` key is physically just its integer column, and the live side
  # reads back as exactly that (`sIntegerField` on SQLite, `sBigIntegerField` on PostgreSQL).
  field.db_constraint || return nothing
  return ForeignKeyRef(Models._fk_reference_table(field),
                       Models._fk_target_binding(field),
                       Models.fk_target_column(field),
                       Models._foreign_key_on_delete_sql(field.on_delete))
end

"""
    column_spec(field::PormGField, conn; name = "") -> ColumnSpec

Compile one field into the canonical column description the migration diff runs on (#507).

Applied to **both** sides of the diff — the declared field from the models file and the field the
introspection readers reconstructed from the live schema. That is what makes the readers' lossiness
stop mattering: they may pick a different struct than was declared, but if it renders the same column
it compiles to the same `ColumnSpec`.

Throws `InvalidMigrationError` for a `ManyToManyField`, which is a join table rather than a column on
this model.
"""
function column_spec(field::PormGField, conn::Union{PormGPostgres, PormGSQLite};
                     name::AbstractString = "")::ColumnSpec
  Models.is_many_to_many_field(field) &&
    throw(InvalidMigrationError("a ManyToManyField declares a join table, not a column, so it has " *
                                "no ColumnSpec (field: $(name === "" ? "<unnamed>" : name))"))
  raw = _render_column_type(field, conn)
  return ColumnSpec(Models.field_db_column(field, String(name)),
                    parse_canonical_type(raw, conn),
                    _slot(field, :null, false)::Bool,
                    _slot(field, :primary_key, false)::Bool,
                    _slot(field, :unique, false)::Bool,
                    _column_default(field),
                    _column_reference(field),
                    _column_checks(field),
                    _column_identity(field, conn),
                    raw)
end

# ── The entry point, and the #69 fail-safe ───────────────────────────────────────────────────────

"""
    _degraded_spec(field, marker; name = "") -> ColumnSpec

The spec for a column the compiler could not compile: every cheap slot read straight off the field,
`CUnsupported(marker)` for the type, no checks and no identity.

**This is how the #69 fail-closed rule is expressed since #507 phase 2.** The rule — *a schema diff
must never answer "equal" because something threw* — used to be spelled as "return `[:type]`", which
worked only because the FK helpers then re-read the fields to decide the constraint action. Phase 2
takes that second opinion away, so the failure path has to produce a *spec*, not a symbol: an action
that reads the delta must still get a truthful-enough delta when half of it could not be built.

Two properties are load-bearing:

  * **Against a spec that DID compile, the diff reports `:type`** — the markers below are not a
    rendered type, so `parse_canonical_type`'s output can never equal them. That is exactly the
    answer the pre-phase-2 fail-safe gave, which is why the plan text does not move.
  * **Two simultaneously failing sides still compare UNEQUAL**, because the caller passes a
    different marker for each. A single shared marker would make them equal and the diff empty —
    fail *open*, silently planning nothing for a column it could not read. That is the one outcome a
    schema diff may never have, so the asymmetry is deliberate rather than incidental.

The reference is reduced to its PRESENCE (`sRelationalColumn` with `db_constraint`), with an
unresolvable target. Presence is what `_fk_constraint_action` needs to tell `:add` from `:drop`; an
unresolvable target then compares unequal to any real one, so a constraint that may have moved is
re-issued rather than assumed intact. `sRelationalColumn`, never a bare `isa sForeignKey` — the
FK/O2O pair is spelled once in `src/models/fields.jl` (#408/#409/#418/#437) — and `sManyToManyField`
is outside that union, which is what keeps a join table from being reported as a column reference.
"""
function _degraded_spec(field::PormGField, marker::String; name::AbstractString = "")::ColumnSpec
  reference = (field isa Models.sRelationalColumn && field.db_constraint) ?
              ForeignKeyRef(nothing, nothing, "<unresolved>", nothing) : nothing
  return ColumnSpec(String(name),
                    CUnsupported(marker),
                    _slot(field, :null, false)::Bool,
                    _slot(field, :primary_key, false)::Bool,
                    _slot(field, :unique, false)::Bool,
                    _column_default(field),
                    reference,
                    CheckKind[],
                    nothing,
                    marker)
end

# `column_spec` is total for every field the planner can actually reach — `_render_column_type`
# already guards the one lookup that can raise, and `_column_reference` only touches slots every
# `sRelationalColumn` carries. This wrapper is therefore for the UNFORESEEN failure, which is the
# only kind worth a fail-safe: it reports the column as changed and says why, out loud.
#
# `InterruptException` and `StackOverflowError` are rethrown: those signal interrupted or corrupted
# program state rather than an ordinary comparison failure, and a `StackOverflowError` here would be
# a symptom of the `getproperty` recursion of #108.
#
# A `ManyToManyField` reaching here degrades instead of raising, and that is a knowing trade: the
# deliberate refusal in `column_spec` stays the guard for direct callers, while every planner call
# site filters m2m upstream (`_alter_table_fields` skips it, `_add_constrains` and `_add_new_field`
# early-return). It is also strictly safer than what it replaced — `sManyToManyField` has no
# `db_constraint` slot at all, so the pre-phase-2 `_fk_constraint_action` would have raised a
# `FieldError` on the same input.
function _spec_or_degraded(field::PormGField, conn::Union{PormGPostgres, PormGSQLite},
                           marker::String; name::AbstractString = "")::ColumnSpec
  try
    return column_spec(field, conn; name = name)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    @warn "Could not compile a column for the migration diff; treating it as changed so a " *
          "migration is generated" column=(name === "" ? "<unnamed>" : name) field_type=typeof(field) exception=e
    return _degraded_spec(field, marker; name = name)
  end
end

"""
    column_delta(new_field, old_field, conn; name = "", old_name = name) -> ColumnDelta

Compile both fields and report what differs — the one entry point the planner's field diff uses.

An empty delta means the two fields describe the same physical column, whatever structs they are.
Everything the plan then does about that column is a function of the returned [`ColumnDelta`](@ref)
and nothing else (#507 phase 2): which ALTER fragments `Dialect.alter_field` emits, whether
`_fk_constraint_action` says `:add` / `:drop` / `:repoint` / `:none`, and whether a rename carries an
alteration behind it.

`old_name` is the column the LIVE side is spelled with, and it differs from `name` for exactly one
caller: the rename branch. That is not bookkeeping — it is a fact the actions need. Several
statements in `Dialect.alter_field` name a constraint they can only learn by ASKING the catalog
(`get_constraints_unique`, `get_constraints_pk`, the two CHECK lookups), and at plan time nothing has
run yet, so the catalog still knows the column by its PRE-rename name. Carrying both names in the
specs is what lets the renderer ask the right question without being told twice; `ColumnSpec.name` is
excluded from equality, so a differing name never manufactures a delta.

**Fails SAFE, not open (#69).** "Equal" means "no change", so a real change whose comparison raised
would be silently dropped and no migration generated. A side that cannot be compiled therefore
degrades to [`_degraded_spec`](@ref) — which reports `:type` against anything real, exactly the
pre-phase-2 answer — rather than aborting or comparing equal.
"""
function column_delta(new_field::PormGField, old_field::PormGField,
                      conn::Union{PormGPostgres, PormGSQLite};
                      name::AbstractString = "",
                      old_name::AbstractString = name)::ColumnDelta
  new_spec = _spec_or_degraded(new_field, conn, "<uncompilable:new>"; name = name)
  old_spec = _spec_or_degraded(old_field, conn, "<uncompilable:old>"; name = old_name)
  return ColumnDelta(new_spec, old_spec, column_delta(new_spec, old_spec))
end
