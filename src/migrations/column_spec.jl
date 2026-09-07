# ==============================================================================
# CANONICAL COLUMN IR (#507, phase 1)
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
# PHASE 1 SCOPE. The introspection readers are NOT touched: they still produce `PormGField` structs,
# and `column_spec` is applied to both sides. Compiling introspection's raw facts straight to a
# `ColumnSpec` — which is what finally deletes the lossy reverse type map — is a later change.
# The plan ACTIONS are not touched either: `alter_attrs` adapts the typed delta back to the
# `colect_not_equal::Vector{Symbol}` `Dialect.alter_field` and the FK helpers already consume.
# Deriving actions from the delta directly is #507 phase 2.
# ==============================================================================

# ── CanonicalType ────────────────────────────────────────────────────────────────────────────────
#
# A CLOSED set, deliberately, rather than "the rendered string plus an equivalence relation" (what
# `Dialect._column_signature` did). The string form is what made `TEXT` vs `text` a bug: PormG's own
# rendering is not self-consistent, because `_get_column_type`'s `else` fallthrough returns the
# literal `"TEXT"` while `TextField` goes through the map and returns `"text"`.
#
# `CUnsupported` is the degradation path, and it is what makes this safe to roll out: a rendered type
# nothing here recognises keeps its lower-cased raw string and compares by that — which is EXACTLY
# what `_column_signature` did for every type. So the worst case of an unrecognised type is the
# behaviour that shipped before this file existed, never an abort.
abstract type CanonicalType end

struct CInt16   <: CanonicalType end
struct CInt32   <: CanonicalType end
struct CInt64   <: CanonicalType end
struct CFloat64 <: CanonicalType end
struct CBool    <: CanonicalType end
struct CText    <: CanonicalType end
struct CDate    <: CanonicalType end
struct CTime    <: CanonicalType end
struct CInterval<: CanonicalType end
struct CUUID    <: CanonicalType end
struct CJSON    <: CanonicalType end
struct CBytes   <: CanonicalType end

# `nothing` = the type carried no length modifier. PormG always renders one for a char-family field,
# so `nothing` only arises for a spelling PormG did not write (a hand-made table, an imported one).
# It is kept distinct from any concrete length rather than defaulted, because guessing 250 here would
# silently equate an unbounded `varchar` with a `varchar(250)`.
struct CVarChar <: CanonicalType
  length::Union{Int, Nothing}
end

struct CDecimal <: CanonicalType
  precision::Union{Int, Nothing}
  scale::Union{Int, Nothing}
end

# PostgreSQL distinguishes `timestamptz` from `timestamp` and PormG renders both (`DateTimeField`'s
# `type` kwarg picks). SQLite has no timezone concept at all — `TIMESTAMPTZ` and `DATETIME` both go
# through `sqlite_type_map_reverse` to the same `DATETIME` — so the SQLite parse collapses the flag.
# That collapse is an engine fact, which is why it lives in `parse_canonical_type` and not here.
struct CDateTime <: CanonicalType
  with_timezone::Bool
end

struct CUnsupported <: CanonicalType
  raw::String
end

# ── ColumnDefault (the #475 classification, kept) ─────────────────────────────────────────────────
abstract type ColumnDefault end

struct NoDefault <: ColumnDefault end

struct LiteralDefault <: ColumnDefault
  value::Any
end

"""
    ExpressionDefault(sql) <: ColumnDefault

A database-side expression default (`DEFAULT now()`, `DEFAULT gen_random_uuid()`).

**Not reachable from `column_spec` today**, and that is deliberate rather than an oversight: no
`PormGField` has a slot that can spell one, so the declared side can never produce it, and
introspection *drops* an expression default it cannot represent (`_field_or_drop_default`, #472/#475)
rather than carrying it. The variant exists because #496 — a `db_default` slot — is exactly the
change that makes it reachable, and having the IR half already defined means #496 is a pure addition
here instead of a re-shaping. It is constructible and compares correctly; that much is covered.
"""
struct ExpressionDefault <: ColumnDefault
  sql::String
end

# `isequal`, not `==`: a `missing` default would make `==` return `missing`, and `if missing` throws.
# The old attribute loop in `_alter_table_fields` had no `catch` around its `!=`, so that was a live
# (if unlikely) crash path; the IR closes it rather than inheriting it.
Base.:(==)(a::LiteralDefault, b::LiteralDefault)::Bool = isequal(a.value, b.value)
# Every custom `==` in this file carries a matching `hash`. Julia's default hash is field-wise, so a
# type whose `==` ignores a field (or compares it with `isequal`) breaks the `a == b ⇒ hash(a) ==
# hash(b)` contract and misbehaves the moment one lands in a `Set` or a `Dict` key. Nothing hashes
# these today; #507 phase 2 keys plan actions off the delta, which is exactly when it would start.
Base.hash(d::LiteralDefault, h::UInt) = hash(d.value, hash(:LiteralDefault, h))

# ── CHECK-expressed bounds ───────────────────────────────────────────────────────────────────────
#
# Two column facts neither backend can express in the type itself, so both are rendered as a CHECK
# and both must ride in the IR or the diff would call two different columns the same:
#   * a positive-integer field on PostgreSQL renders plain `integer` — only the `>= 0` CHECK
#     separates `IntegerField` from `PositiveIntegerField`;
#   * `BinaryField`'s `max_length` is a BYTE bound and neither `bytea` nor `BLOB` takes a length
#     parameter (#296).
# This is the same pair `Dialect._column_signature` carried, read through the same two predicates so
# there is one definition of "does this field need that CHECK".
abstract type CheckKind end
struct NonNegativeCheck <: CheckKind end
struct ByteLengthCheck <: CheckKind
  max_bytes::Int
end

# ── Identity ─────────────────────────────────────────────────────────────────────────────────────
#
# Kept as its own slot rather than as `Serial` / `BigSerial` variants of `CanonicalType`. Two reasons:
# the type axis stays about what the column HOLDS (an identity `bigint` holds exactly what a plain
# `bigint` holds), and the adapter can emit the precise `:generated` / `:generated_always` symbols
# `Dialect.alter_field` already branches on. `parse_canonical_type` still understands `serial` /
# `bigserial` as `CInt32` / `CInt64` for a table PormG did not create.
struct ColumnIdentity
  generated::Bool         # PostgreSQL: GENERATED … AS IDENTITY
  always::Bool            # PostgreSQL: … ALWAYS (as opposed to BY DEFAULT)
  auto_increment::Bool    # SQLite: INTEGER PRIMARY KEY AUTOINCREMENT
end

# ── ForeignKeyRef ────────────────────────────────────────────────────────────────────────────────

"""
    ForeignKeyRef(table, binding, column, on_delete)

The `FOREIGN KEY` constraint a column carries — present in a [`ColumnSpec`](@ref) only when the
constraint actually exists in the database, i.e. when the declaring field has `db_constraint = true`.

`on_delete` is **part of this**, and that is the single answer to a question the planner used to
answer three different ways (`_compare_model_field` skipped it, `_NON_SCHEMA_FIELD_ATTRS` skipped it,
`_fk_constraint_action` diffed it). A change to it is a **constraint delta — never a column ALTER**:
it reaches the plan as DROP + ADD CONSTRAINT, which is why `alter_attrs` emits `:on_delete` into the
difference set while `_FK_IDENTITY_ATTRS` keeps it away from `Dialect.alter_field`.

This matches Django rather than departing from it, which is worth stating because the planning notes
for #507 assumed the opposite. `on_delete` is **not** in Django's `Field.non_db_attrs` (the tuple is
`blank`, `choices`, `db_column`, `editable`, `error_messages`, `help_text`, `limit_choices_to`,
`related_name`, `related_query_name`, `validators`, `verbose_name`), so on released Django it counts
as schema-affecting; on Django `main`, `ForeignObject.non_db_attrs` skips it only when the action is
*not* a `DatabaseOnDelete` variant — *"Database-level on_delete options are part of the column
definition."* PormG renders `ON DELETE <action>` into every foreign-key constraint
(`Dialect.add_foreign_key`, #292), so it only ever has the database-level flavour and Django's
condition is always true here.

The value stored is the **rendered** clause, produced by `Models._foreign_key_on_delete_sql` — the
same function `Models._fk_on_delete_equal` renders both sides through, so comparing two stored values
with `==` is that predicate by construction rather than a second copy of it. It is what folds the
pairs that mean the same clause: `PROTECT` ≡ `RESTRICT`, `DO_NOTHING` ≡ `nothing` ≡ `NO ACTION`
(#498). On the introspected side the readers have already normalised the raw catalog value through
`_normalize_introspected_on_delete` before the field was built, so both sides reach this rendering
from the same vocabulary.

`table` is the physical parent table when either side can name one; `binding` is the
`format_model_name`-folded Julia binding, used only as the fallback axis — see `reference_delta` for
why both are carried.
"""
struct ForeignKeyRef
  table::Union{String, Nothing}
  binding::Union{String, Nothing}
  column::String
  on_delete::Union{String, Nothing}
end

"""
    reference_delta(a::ForeignKeyRef, b::ForeignKeyRef) -> Vector{Symbol}

Which parts of two foreign-key references differ, as the planner's own symbols (`:to`, `:pk_field`,
`:on_delete`).

The target comparison is **conditional** — exact physical table when both sides can name one (#390),
folded Julia binding otherwise — and this function does **not** reimplement that rule. It calls
`Models._fk_targets_equal`, the single definition `Models._compare_field_foreign_key` also calls, so
the planner's fast path and the column IR cannot answer "same parent?" differently. Two copies of
that rule drifting apart is the defect class #507 exists to end; introducing one here to build the
thing that ends it would have been the same mistake in a new place.

Both axes have to be carried into the `ForeignKeyRef` because the two sides are asymmetric by
construction — introspection sets `to_table` to the live parent table while `Model_to_str` never
emits it, and a declared `.to` may still be an unresolved binding string.

Similarly, `on_delete` is compared with `==` on values both sides rendered through
`Models._foreign_key_on_delete_sql`, which is exactly what `Models._fk_on_delete_equal` does; the
rendering happens once at compile time instead of on every comparison.

That conditional is why `ForeignKeyRef` does not get field-wise `==`: `==` is defined as
`isempty(reference_delta(a, b))`.
"""
function reference_delta(a::ForeignKeyRef, b::ForeignKeyRef)::Vector{Symbol}
  deltas = Symbol[]
  Models._fk_targets_equal(a.table, a.binding, b.table, b.binding) || push!(deltas, :to)
  a.column == b.column || push!(deltas, :pk_field)
  a.on_delete == b.on_delete || push!(deltas, :on_delete)
  return deltas
end

Base.:(==)(a::ForeignKeyRef, b::ForeignKeyRef)::Bool = isempty(reference_delta(a, b))

# Hashes only the axes `reference_delta` ALWAYS compares. `table` and `binding` are deliberately
# excluded: which of the two decides equality is conditional, so two equal refs can differ in either
# one, and hashing either would break `a == b ⇒ hash(a) == hash(b)`. Colliding on the target axis is
# correct and cheap — `==` still separates them.
Base.hash(r::ForeignKeyRef, h::UInt) = hash(r.column, hash(r.on_delete, hash(:ForeignKeyRef, h)))

# ── ColumnSpec ───────────────────────────────────────────────────────────────────────────────────

"""
    ColumnSpec

What the database can hold in one column, and nothing else — the canonical form both sides of a
migration diff compile to (#507).

`name` and `raw` are carried for diagnostics and are **excluded from equality**:

  * `name` — a physical-column change is a RENAME, planned by `_resolve_table_fields` from the
    add/drop key sets, not by the column diff. (Django excludes `db_column` from
    `_field_should_be_altered` for the same reason.)
  * `raw` — comparing rendered type strings verbatim is the `TEXT`-vs-`text` bug this replaces.

`db_index` is deliberately **not a field here at all**. An index is not part of the column: it is
created and dropped by `CREATE INDEX` / `DROP INDEX`, which `_alter_table_fields` plans separately
through its `index_actions` list. Keeping it out is load-bearing rather than tidy — on SQLite a
non-empty column delta means a full table REBUILD, and the rebuild re-emits every existing secondary
index, so an index-only difference that reached this struct would plan a rebuild *and* a
`CREATE INDEX` the rebuild then duplicates (#82/#325).
"""
struct ColumnSpec
  name::String
  type::CanonicalType
  nullable::Bool
  primary_key::Bool
  unique::Bool
  default::ColumnDefault
  reference::Union{Nothing, ForeignKeyRef}
  checks::Vector{CheckKind}
  identity::Union{Nothing, ColumnIdentity}
  raw::String
end

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
  * `on_update`, `deferrable`, `initially_deferred` — declared API that **no renderer emits**:
    `Dialect.add_foreign_key` writes no `ON UPDATE` clause and hardcodes
    `DEFERRABLE INITIALLY DEFERRED`, and neither reader reads them back. They therefore cannot be a
    schema delta. Before #507 a declared `deferrable = true` churned forever — an empty `ALTER` plus
    a permanent "not implemented" warning on PostgreSQL, a full table rebuild on SQLite. Silence here
    is the lesser evil, not the right answer: **#516** tracks rendering them or rejecting them at
    declaration time, and removes the warning below when it lands.
  * `through`, `db_table`, `source_field`, `target_field` — `sManyToManyField` only, which is not a
    physical column at all (`column_spec` refuses it).
"""
const NON_DB_ATTRS = (:blank, :choices, :db_index, :editable, :verbose_name, :related_name,
                      :how, :formatter,
                      :auto_now, :auto_now_add, :auto_add, :auto_hash,
                      :on_update, :deferrable, :initially_deferred,
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

# Decision 6 of #507, and the reason it is not silent. These three slots are declared API that no
# renderer emits: `Dialect.add_foreign_key` writes no `ON UPDATE` clause and hardcodes
# `DEFERRABLE INITIALLY DEFERRED` regardless of what was declared, and SQLite's rebuild renders no
# deferrability clause at all. Classifying them as non-schema stops them churning a plan forever —
# but dropping a declared intent WITHOUT a report is the exact shape #501 just closed in the
# importer, so the classification says it out loud instead. Tracked by #516.
#
# Only a NON-DEFAULT value warns. The introspected side always carries the constructor defaults
# (`on_update = nothing`, `deferrable = false`, `initially_deferred = false`) because neither reader
# reads these back, so this can only ever fire for something a models file actually declared.
# `maxlog` keeps a wide schema from emitting one line per foreign key.
function _warn_unrendered_fk_options(field::PormGField, name::AbstractString)
  field isa Models.sRelationalColumn || return nothing
  declared = Symbol[]
  field.on_update === nothing || push!(declared, :on_update)
  field.deferrable && push!(declared, :deferrable)
  field.initially_deferred && push!(declared, :initially_deferred)
  isempty(declared) && return nothing
  @warn "Foreign-key options declared that PormG does not render; they cannot appear in a migration " *
        "plan and are ignored by the schema diff. Every constraint is emitted DEFERRABLE INITIALLY " *
        "DEFERRED on PostgreSQL and with no deferrability clause on SQLite, and no ON UPDATE clause " *
        "is rendered on either." declared column=(name === "" ? "<unnamed>" : name) maxlog = 1
  return nothing
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
  _warn_unrendered_fk_options(field, name)
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

# ── The diff ─────────────────────────────────────────────────────────────────────────────────────

_references_equal(a::Nothing, b::Nothing)::Bool = true
_references_equal(a::ForeignKeyRef, b::ForeignKeyRef)::Bool = a == b
_references_equal(a, b)::Bool = false

"""
    column_delta(new_spec, old_spec) -> Vector{Symbol}

Which facets of the column differ, as IR-level names: `:type`, `:nullable`, `:primary_key`,
`:unique`, `:default`, `:reference`, `:checks`, `:identity`.

This is the typed delta #507 phase 2 derives plan actions from. Phase 1 hands it to [`alter_attrs`](@ref),
which adapts it back to the field-attribute symbols the existing action code consumes.
"""
function column_delta(new_spec::ColumnSpec, old_spec::ColumnSpec)::Vector{Symbol}
  deltas = Symbol[]
  new_spec.type        == old_spec.type        || push!(deltas, :type)
  new_spec.nullable    == old_spec.nullable    || push!(deltas, :nullable)
  new_spec.primary_key == old_spec.primary_key || push!(deltas, :primary_key)
  new_spec.unique      == old_spec.unique      || push!(deltas, :unique)
  new_spec.default     == old_spec.default     || push!(deltas, :default)
  _references_equal(new_spec.reference, old_spec.reference) || push!(deltas, :reference)
  new_spec.checks      == old_spec.checks      || push!(deltas, :checks)
  new_spec.identity    == old_spec.identity    || push!(deltas, :identity)
  return deltas
end

# `name` and `raw` are excluded by construction — see the `ColumnSpec` docstring.
Base.:(==)(a::ColumnSpec, b::ColumnSpec)::Bool = isempty(column_delta(a, b))

# Excludes `name` and `raw` to match `==` above; the default field-wise hash would include both and
# break the `a == b ⇒ hash(a) == hash(b)` contract for exactly the pairs this IR exists to call equal.
Base.hash(s::ColumnSpec, h::UInt) = hash(s.type, hash(s.nullable, hash(s.primary_key,
  hash(s.unique, hash(s.default, hash(s.reference, hash(s.checks, hash(s.identity,
  hash(:ColumnSpec, h)))))))))

_has_non_negative(spec::ColumnSpec)::Bool = any(c -> c isa NonNegativeCheck, spec.checks)
_byte_bound(spec::ColumnSpec)::Union{Int, Nothing} =
  (i = findfirst(c -> c isa ByteLengthCheck, spec.checks); i === nothing ? nothing : spec.checks[i].max_bytes)

function _type_attrs(new_spec::ColumnSpec, old_spec::ColumnSpec)::Vector{Symbol}
  new_type, old_type = new_spec.type, old_spec.type
  # A length-only or precision-only change emits the narrow symbol rather than `:type`, because that
  # is what the pre-#507 diff emitted for the same change (both sides were the same struct, so only
  # `max_length` / `max_digits` differed) and `Dialect.alter_field` gates its char and decimal
  # branches on either symbol. Keeping the emitted set identical is what lets the whole action path
  # stay untouched in phase 1.
  if new_type isa CVarChar && old_type isa CVarChar
    return [:max_length]
  elseif new_type isa CDecimal && old_type isa CDecimal
    attrs = Symbol[]
    new_type.precision == old_type.precision || push!(attrs, :max_digits)
    new_type.scale     == old_type.scale     || push!(attrs, :decimal_places)
    return attrs
  end
  return [:type]
end

function _reference_attrs(new_spec::ColumnSpec, old_spec::ColumnSpec)::Vector{Symbol}
  new_ref, old_ref = new_spec.reference, old_spec.reference
  # A constraint appearing or disappearing (a `db_constraint` flip) is reported as `:to`: it has to
  # open the alteration gate, and `_FK_IDENTITY_ATTRS` then keeps it out of `Dialect.alter_field`,
  # which has no branch for it. The DROP/ADD CONSTRAINT itself comes from `_fk_constraint_action`,
  # which inspects the fields directly and is untouched by this file.
  (new_ref === nothing || old_ref === nothing) && return [:to]
  return reference_delta(new_ref, old_ref)
end

function _identity_attrs(new_spec::ColumnSpec, old_spec::ColumnSpec)::Vector{Symbol}
  none = ColumnIdentity(false, false, false)
  new_id = new_spec.identity === nothing ? none : new_spec.identity
  old_id = old_spec.identity === nothing ? none : old_spec.identity
  attrs = Symbol[]
  new_id.generated      == old_id.generated      || push!(attrs, :generated)
  new_id.always         == old_id.always         || push!(attrs, :generated_always)
  # `:auto_increment` is not in `Dialect.alter_field`'s implemented list, but it can only be emitted
  # on SQLite, where `alter_field` ignores the vector entirely and rebuilds the table from the model.
  # So it opens the gate (correctly — the rebuild is how SQLite changes a key) without ever reaching
  # the PostgreSQL warning path.
  new_id.auto_increment == old_id.auto_increment || push!(attrs, :auto_increment)
  return attrs
end

"""
    alter_attrs(new_spec, old_spec, deltas) -> Vector{Symbol}

Adapt the typed [`column_delta`](@ref) back to the `colect_not_equal::Vector{Symbol}` the existing
plan actions consume — `Dialect.alter_field`'s per-symbol branches, and the
`_FK_IDENTITY_ATTRS` filter that keeps FK identity out of a column ALTER.

Phase 1 of #507 exists to change how *changed / unchanged* is decided, not what is emitted once the
answer is "changed". This function is the seam that keeps that promise: every symbol below is one the
action path already received before the IR existed. **Phase 2 deletes it** and derives actions from
`column_delta` directly.
"""
function alter_attrs(new_spec::ColumnSpec, old_spec::ColumnSpec, deltas::Vector{Symbol})::Vector{Symbol}
  attrs = Symbol[]
  :type in deltas && append!(attrs, _type_attrs(new_spec, old_spec))
  :nullable    in deltas && push!(attrs, :null)
  :unique      in deltas && push!(attrs, :unique)
  :primary_key in deltas && push!(attrs, :primary_key)
  :default     in deltas && push!(attrs, :default)
  if :checks in deltas
    # Each CHECK maps to the symbol `Dialect.alter_field` already gates that constraint's DROP/ADD on:
    # the non-negative CHECK moves with `:type`, the byte-length CHECK with `:max_length` (#296).
    _has_non_negative(new_spec) == _has_non_negative(old_spec) || push!(attrs, :type)
    _byte_bound(new_spec)       == _byte_bound(old_spec)       || push!(attrs, :max_length)
  end
  :reference in deltas && append!(attrs, _reference_attrs(new_spec, old_spec))
  :identity  in deltas && append!(attrs, _identity_attrs(new_spec, old_spec))
  return unique!(attrs)
end

"""
    column_attrs_changed(new_field, old_field, conn; name = "") -> Vector{Symbol}

Compile both fields and report the difference as the planner's attribute symbols — the one entry
point `_alter_table_fields` uses, replacing `Models.are_model_fields_equal`'s detailed fallback,
`_diffs_attribute_wise`, `Dialect.describes_same_column` and the #408 `db_constraint = false` escape.

An empty result means the two fields describe the same physical column, whatever structs they are.

**Fails SAFE, not open (#69).** A schema diff must never answer "equal" because something threw:
"equal" means "no change", so a real change whose comparison raised would be silently dropped and no
migration generated. Any unexpected error is therefore reported as `[:type]` — changed — with
structured context, exactly the rule `Models._compare_model_field` has carried since #69. That rule
has to be restated here rather than inherited: `_alter_table_fields` has no `catch` of its own, and
the fast path that used to hold the only copy of it is now bypassed for every column that is not
already equal. The IR also does strictly more work per column than the attribute loop it replaces —
it renders a type and resolves a foreign key's parent — so there is more that *can* raise.

`InterruptException` and `StackOverflowError` are rethrown: those signal interrupted or corrupted
program state rather than an ordinary comparison failure, and a `StackOverflowError` here would be a
symptom of the `getproperty` recursion of #108.
"""
function column_attrs_changed(new_field::PormGField, old_field::PormGField,
                              conn::Union{PormGPostgres, PormGSQLite};
                              name::AbstractString = "")::Vector{Symbol}
  try
    new_spec = column_spec(new_field, conn; name = name)
    old_spec = column_spec(old_field, conn; name = name)
    return alter_attrs(new_spec, old_spec, column_delta(new_spec, old_spec))
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    @warn "Column comparison raised; treating the column as changed so a migration is generated" column=(name === "" ? "<unnamed>" : name) new_field_type=typeof(new_field) old_field_type=typeof(old_field) exception=e
    return [:type]
  end
end
