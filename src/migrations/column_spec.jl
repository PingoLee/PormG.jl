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
# PHASE 3 (#522) closed the loop from the other side. The introspection readers compile the catalog
# straight into a `LiveTable` of `ColumnSpec`s (`migrations/introspection.jl`), so the diff never
# passes through a reconstructed `PormGField` at all, and the lossy reverse type maps
# (`sqlite_type_map` / `postgres_type_map`) are gone with the round trip. The one place a struct is
# still chosen FROM a spec is `field_from_spec` at the bottom of this file — `inspectdb`'s compiler,
# which has to write a models file — and it is deliberately not on the diff path, so a choice made
# there can no longer become a schema opinion the planner acts on.
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
const SCHEMA_ATTRS = (:type, :primary_key, :unique, :null, :default, :db_default, :db_column,
                      :max_length, :max_digits, :decimal_places,
                      :to, :to_table, :pk_field, :on_delete, :db_constraint,
                      :generated, :generated_always, :auto_increment)

# ── Type parsing: where engine equivalence lives, once ───────────────────────────────────────────

# Split `varchar(120)` / `decimal(10, 2)` / `bigint` into a lower-cased base and its arguments.
#
# The text AFTER the closing paren is part of the base (#522). PostgreSQL's `format_type` renders a
# datetime precision in the middle — `timestamp(6) with time zone` — and dropping the tail read that
# as a plain `timestamp`, i.e. `CDateTime(false)` for a column that is timezone-aware. Whitespace
# is normalised so the two halves join as one spelling. A rendered type never has a tail, so the
# declared side is unaffected.
function _split_rendered_type(raw::AbstractString)
  s = strip(String(raw))
  open_paren = findfirst('(', s)
  open_paren === nothing && return (lowercase(join(split(s), " ")), Int[])
  head = s[1:prevind(s, open_paren)]
  close_paren = findlast(')', s)
  inner = close_paren === nothing ? s[nextind(s, open_paren):end] :
                                    s[nextind(s, open_paren):prevind(s, close_paren)]
  tail = close_paren === nothing ? "" : s[nextind(s, close_paren):end]
  base = lowercase(join(split(head * " " * tail), " "))
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

Map a SQL type — as `Dialect._get_column_type` renders it for a declared field, or as the catalog
spells it for a live column (`format_type` on PostgreSQL, `PRAGMA table_info` on SQLite) — onto the
closed `CanonicalType` set for `conn`'s engine.

**This is the only place engine equivalence is expressed** — Atlas's per-driver normalizer, run on
both sides before the diff. Since #522 it is also the only type map the readers have: the live
spelling comes here directly, so the catalog aliases below (`int4`, `bigserial`, `character
varying`, `timestamp with time zone`) are not conveniences but the reader's whole vocabulary.
Every collapse below is FORCED by what `Dialect._get_column_type` writes, never chosen for
convenience: two spellings collapse only when PormG renders both as the same string, so the
database genuinely cannot tell them apart. Two spellings PormG writes distinctly must stay
distinct, or a real declaration change would stop being planned — and a catalog spelling PormG
never writes (`character(n)`, an array, `bit(n)`) stays `CUnsupported` on purpose, so a declared
`CharField` no longer silently equates to a `char(8)` column the way the old reverse map made it.

Unrecognised input degrades to `CUnsupported(lowercased raw)`, which compares by that string — the
behaviour `Dialect._column_signature` had for every type — so an exotic column loses precision, never
correctness, and never aborts `makemigrations`.
"""
function parse_canonical_type(raw::AbstractString, ::PormGPostgres)::CanonicalType
  base, args = _split_rendered_type(raw)
  base in ("smallint", "int2")            && return CInt16()
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
  # `timetz` was always folded in here, so its long spelling folds the same way.
  base in ("time", "timetz", "time without time zone", "time with time zone") && return CTime()
  # `interval day to second` and the other field-restricted spellings: PormG renders a bare
  # `interval` and has no way to declare the restriction, so the catalog form is the same column.
  startswith(base, "interval")            && return CInterval()
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
  # verbatim on SQLite and the reader hands both back verbatim, so a change between them IS
  # observable and must still be planned — even though SQLite gives all three the same INTEGER affinity. The
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
  # `TIMESTAMP` is the ONE case knowingly outside that rule. `DateTimeField(type = "TIMESTAMP")`
  # renders the word verbatim (the reverse map has no key for it) while the default flavour renders
  # `DATETIME`, so PormG does write the two distinctly and the strict rule would keep them apart.
  # They are collapsed anyway, and the reason is the DECLARATION, not affinity: the `type` kwarg is
  # documented as a PostgreSQL choice (`timestamptz` vs `timestamp`), SQLite has no timezone concept
  # for it to express, and refusing the collapse would plan a full table rebuild to swap two names
  # SQLite treats identically for a declaration that never meant anything on this engine. Until
  # #522 the reader could not even see the difference (its type map had no `TIMESTAMP` key); now it
  # can, and the collapse is kept as a decision rather than an accident. (Do not read this as licence
  # for the affinity argument the SMALLINT comment above rejects — that pair IS a PostgreSQL-visible
  # width change; this one is a spelling of the same thing.)
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

function _column_default(field::PormGField, conn::Union{PormGPostgres, PormGSQLite})::ColumnDefault
  # #496: a `db_default` wins, and it is asked FIRST for two reasons. It is mutually exclusive with
  # `default` at construction, so there is no precedence question to get wrong; and
  # `Dialect.db_default_sql` is where an expression pinned to the other engine raises, so routing
  # the declared side through it makes the engine check unskippable on the diff path too — not only
  # when DDL is finally rendered.
  #
  # The text stored is the CANONICAL one — `canonical_db_default` strips the outer parentheses
  # `db_default_sql` just added for SQLite's grammar, so the IR holds the bare expression on both
  # engines. That is the point rather than a wasted round trip: the live side stores what the
  # catalog reports, and `PRAGMA table_info` reports those same parens already stripped, so passing
  # both sides through one normaliser is what makes the two spellings meet.
  db_expr = Dialect.db_default_sql(field, conn)
  db_expr === nothing || return ExpressionDefault(canonical_db_default(db_expr))
  value = _slot(field, :default, nothing)
  value === nothing && return NoDefault()
  return _literal_default(value)
end

"""
    _literal_default(value) -> LiteralDefault

The `LiteralDefault` for a default VALUE, on either side of the diff (#522).

One representation per fact: a `DateTimeField` may hold a naive `DateTime` or a `ZonedDateTime`,
PormG writes both as the same UTC instant (`format_timezone_sql`, #79) and the catalog reads back a
zoned one, so comparing the raw values called one default two different things — a declared naive
`DateTime` never converged with its own live column. Folded to a UTC `ZonedDateTime` here, which is
also what `Dialect` renders for `SET DEFAULT`, so the fold changes no SQL. Everything else is
carried as the constructor stored it; the readers coerce the catalog literal to that same Julia
type per `CanonicalType` (`_coerce_default`, `migrations/introspection.jl`) before calling this.
"""
_literal_default(value::DateTime)::LiteralDefault = LiteralDefault(ZonedDateTime(value, tz"UTC"))
_literal_default(value::ZonedDateTime)::LiteralDefault = LiteralDefault(astimezone(value, tz"UTC"))
_literal_default(value)::LiteralDefault = LiteralDefault(value)

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

# THE LIVE SIDE'S HALF of the same rule (#522), stated here so the two cannot drift. The SQLite
# reader (`_sqlite_live_table`) compiles `ColumnIdentity(false, false, true)` for a column on the
# `IDField` arm whose type is an integer — `_integer_key_arm` — and for nothing else. It deliberately
# does NOT read the catalog's `AUTOINCREMENT` token: `IDField` is the only integer key PormG can
# declare and it always renders the token, so a rowid key without it has no declaration that could
# ever equal it, and reading the token would make such a key churn forever. A TEXT key (what
# `UUIDField(primary_key = true)` renders here) compiles no identity and takes the pragma's `unique`,
# which is this function's and `column_spec`'s answer for that declaration.

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

Applied to the **declared** side of the diff — the field from the models file. The live side has
arrived from the introspection readers as a `ColumnSpec` already (#522, [`LiveTable`](@ref)), so no
struct is reconstructed for it and nothing on that side can be a reader's opinion. The one other
caller is [`live_table`](@ref), the adapter that reads a hand-built `PormGModel` as a live table
for the planner's tests; there the property phase 1 established still holds — two structs that
render the same column compile to the same spec.

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
                    _column_default(field, conn),
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
function _degraded_spec(field::PormGField, conn::Union{PormGPostgres, PormGSQLite}, marker::String;
                        name::AbstractString = "")::ColumnSpec
  reference = (field isa Models.sRelationalColumn && field.db_constraint) ?
              ForeignKeyRef(nothing, nothing, "<unresolved>", nothing) : nothing
  return ColumnSpec(String(name),
                    CUnsupported(marker),
                    _slot(field, :null, false)::Bool,
                    _slot(field, :primary_key, false)::Bool,
                    _slot(field, :unique, false)::Bool,
                    # `_column_default` can RAISE since #496 (a `db_default` pinned to the other
                    # engine), and this function is reached from inside `_spec_or_degraded`'s
                    # `catch` — so an unguarded call would let a second exception escape the
                    # fail-safe and mask the original one. Degrading to `NoDefault()` does not fail
                    # open: the spec already carries `CUnsupported(marker)` for its type, so the
                    # diff reports `:type` and the column is planned as changed regardless of what
                    # the default facet says. Found in review.
                    (try
                       _column_default(field, conn)
                     catch e
                       # The same carve-out `_spec_or_degraded` and `Model_to_str`'s render-failure
                       # path both make: interrupted or corrupted program state is not "this
                       # default is unrepresentable", so Ctrl-C during a large read must abort
                       # rather than be swallowed into a `NoDefault()`. A bare `catch` here would
                       # have eaten it; flagged in the delta review.
                       (e isa InterruptException || e isa StackOverflowError) && rethrow()
                       NoDefault()
                     end),
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
    # `BackendCapabilityError` joins the rethrow list for #496, and it is a different KIND of
    # exception from the two above it — not corrupted program state, but a user contract violation
    # this wrapper must not launder. It means a `db_default` is pinned to the other engine, which is
    # foreseen and has exactly one remedy (name this engine's spelling, or `nothing`). Degrading it
    # would turn a precise, actionable refusal into a silent `CUnsupported` column, and
    # `makemigrations` would then plan DDL for a column whose default it had just refused to render.
    # That is the opposite of what the fail-safe is for: this wrapper's own comment above says it
    # exists for the UNFORESEEN failure.
    #
    # The rethrow is a TYPE catch, and it is correctly scoped today by fact rather than by
    # construction: `db_default_sql` is the only `BackendCapabilityError` producer reachable from
    # `column_spec` (the others — `ToChar`, window frames, JSONB lookups, `unaccent` — are all
    # query-builder paths). If a type renderer ever grew one, it would abort `makemigrations` where
    # it used to degrade, so a new throw of this type under `column_spec` needs a look at this line.
    (e isa InterruptException || e isa StackOverflowError || e isa BackendCapabilityError) && rethrow()
    @warn "Could not compile a column for the migration diff; treating it as changed so a " *
          "migration is generated" column=(name === "" ? "<unnamed>" : name) field_type=typeof(field) exception=e
    return _degraded_spec(field, conn, marker; name = name)
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

# ══════════════════════════════════════════════════════════════════════════════════════════════
# THE LIVE SIDE (#522, phase 3 of #507)
#
# The readers used to reconstruct a `PormGField` from the catalog through a type map that returned
# ONE struct per rendered type, and only then compiled that struct into a `ColumnSpec`. Phase 1 made
# the lossiness stop mattering; phase 3 removes the round trip: the readers produce `LiveTable`s of
# `ColumnSpec`s and the planner diffs against those. What is left below is the vocabulary of that
# live side, the adapter that lets a `PormGModel` still stand in for one, and the ONE remaining
# place a struct is chosen from a spec — `inspectdb`, which has to write a models file.
# ══════════════════════════════════════════════════════════════════════════════════════════════

"""
    LiveComposite

One model-level index as the catalog holds it (#161): the live `name`, the key `columns` in index
order (physical names), whether it is `unique`, and whether a table `constraint` backs it rather
than a bare `CREATE [UNIQUE] INDEX`.

`constraint` is PostgreSQL `pg_constraint.contype = 'u'` or SQLite `pragma_index_list.origin = 'u'`
— what Django's `unique_together` and a table-level `UNIQUE (a, b)` produce. It changes how the
index is dropped (`ALTER TABLE … DROP CONSTRAINT` on PostgreSQL, a table rebuild on SQLite, whose
`sqlite_autoindex_*` cannot be dropped at all) and whether it survives an SQLite rebuild (it does
not: `rebuild_table` renders no table-level constraint). It does NOT change identity: a declared
`UniqueConstraint` is satisfied by either backing, so an adopted Django constraint is never
duplicated by a second index over the same columns.

What reaches this struct is exactly what PormG can re-emit — a readers' contract, stated on
[`_pg_composite_indexes`](@ref) and [`_sqlite_composite_indexes`](@ref). A partial, functional,
non-b-tree, `DESC`, `INCLUDE` or explicitly-collated index is never read, so it is never matched,
never dropped and never renamed.

The arities partition with the column readers, so no index has two owners: a non-unique index here
has more than one column (one column is `db_index`), a constraint-backed unique one has more than
one column (one column is the field's `unique`), and a bare unique index may have one — nothing
else reads that shape, and it is what a one-field `UniqueConstraint` materializes.
"""
struct LiveComposite
  name::String
  columns::Vector{String}
  unique::Bool
  constraint::Bool
end

"""
    LiveTable

One table as the introspection readers describe it (#522): its catalog `name`, its `columns` as
[`ColumnSpec`](@ref)s in physical order, the single-column non-unique `indexes` it carries
(physical column ⇒ live index name, or `nothing` when only the fact of an index is known), and its
model-level `composites` ([`LiveComposite`](@ref)), which `inspectdb` reproduces as `Models.Index` /
`Models.UniqueConstraint` and the planner diffs against the declared ones (#161).

This is the LIVE side of every migration diff: the readers compile the catalog straight into it and
`get_migration_plan` diffs the declared `PormGField`s against its specs, so no `PormGField` is ever
reconstructed on the way to a plan. It is also the one input `inspectdb` needs —
[`model_from_live`](@ref) compiles a `PormGModel` from it through [`field_from_spec`](@ref).

`db_index` lives here and not in `ColumnSpec` for the reason recorded on that struct: an index is
not part of the column, and on SQLite a non-empty column delta means a rebuild that re-emits every
index (#82/#325). Read `haskey(indexes, col)` for the flag and the value for the name the planner's
`DROP INDEX` needs; `nothing` routes that lookup through `get_constraints_index`, as before.
"""
struct LiveTable
  name::String
  columns::OrderedDict{String, ColumnSpec}
  indexes::Dict{String, Union{String, Nothing}}
  composites::Vector{LiveComposite}
end

LiveTable(name::AbstractString, columns::OrderedDict{String, ColumnSpec},
          indexes::Dict{String, Union{String, Nothing}}) =
  LiveTable(String(name), columns, indexes, LiveComposite[])

"""
    DeclaredComposite

One model-level index as the models file declares it, compiled to physical terms (#161) — the
declared-side twin of [`LiveComposite`](@ref). `name` is the one PormG creates it under: the
declaration's own `name=` when it has one (`explicit`), else [`composite_index_name`](@ref).

`explicit` is what decides a rename. Identity is `(unique, columns)` and never the name, so a derived
name accepts whatever the live index is called — a table renamed under #615 keeps its
`<old>_a_b_uniq`, and that must not read as a different index. Only a name the developer WROTE is a
fact the planner has to make true.
"""
struct DeclaredComposite
  name::String
  columns::Vector{String}
  unique::Bool
  explicit::Bool
end

"""
    composite_index_name(table, columns, unique) -> String

The name PormG derives for a model-level index that declares none: `<table>_<cols>_uniq` for a
`UniqueConstraint`, `<table>_<cols>_idx` for an `Index` — physical table and column names, joined
by `_`, case kept. One spelling for the create path and the diff alike.
"""
composite_index_name(table::AbstractString, columns::Vector{String}, unique::Bool)::String =
  "$(table)_$(join(columns, "_"))_$(unique ? "uniq" : "idx")"

"""
    declared_composites(model::PormGModel) -> Vector{DeclaredComposite}

Every model-level index `model` declares, in physical terms: the synthesized `ManyToManyField` join
table's unique index first, then each `UniqueConstraint`, then each `Index`, in declaration order.

The join-table index counts as DERIVED (`explicit = false`) although it carries a fixed name. PormG
chose that name, not the developer, and a join table adopted from Django keeps Django's own
`…_uniq` constraint — reading PormG's spelling as intent would plan a rename on every such table.
"""
function declared_composites(model::PormGModel)::Vector{DeclaredComposite}
  out = DeclaredComposite[]
  table = String(model_table_name(model))
  auto = get(model.cache, "many_to_many_auto", nothing)
  if auto !== nothing
    push!(out, DeclaredComposite(String(auto["unique_index"]),
                                 String[String(auto["owner_column"]), String(auto["related_column"])],
                                 true, false))
  end
  for (cache_key, list_key, unique) in (("unique_constraints", "constraints", true),
                                        ("composite_indexes", "indexes", false))
    for decl in get(get(model.cache, cache_key, Dict{String, Any}()), list_key, Any[])
      cols = String[Models.model_column(model, f) for f in decl.fields]
      name = decl.name === nothing ? composite_index_name(table, cols, unique) : String(decl.name)
      push!(out, DeclaredComposite(name, cols, unique, decl.name !== nothing))
    end
  end
  return out
end

"""
    live_table(model::PormGModel, conn) -> LiveTable

A `PormGModel` read as a description of a LIVE table — the adapter behind
`get_migration_plan(::Vector{PormGModel}, …)`.

It is the declared-side compiler applied to a model: every physical column is compiled with
`_spec_or_degraded` under the `<uncompilable:old>` marker (the #69 fail-safe keeps its asymmetry —
a live column that cannot be compiled must still compare UNEQUAL to a declared one), `db_index`
plus `cache["index"]` fill `indexes`, and [`declared_composites`](@ref) fills `composites` — as bare
indexes, since that is what PormG itself creates. Not a second
representation of the schema: the planner's unit tests and the golden plan corpus hand-build the
live side as models, and this is what lets them keep doing so while `makemigrations` itself never
builds one. A `ManyToManyField` is skipped, as it is a join table and not a column.

The composites go through the planner's own compiler on purpose. This adapter used to hand-roll
them from `cache["composite_indexes"]` alone — field keys where the catalog holds physical columns,
no `UniqueConstraint`, and `String(ix.name)`, which throws on the `name = nothing` every derived
declaration carries.
"""
function live_table(model::PormGModel, conn::Union{PormGPostgres, PormGSQLite})::LiveTable
  columns = OrderedDict{String, ColumnSpec}()
  indexes = Dict{String, Union{String, Nothing}}()
  live_index_names = get(model.cache, "index", Dict{String, Any}())
  for (key, field) in model.fields
    Models.is_many_to_many_field(field) && continue
    field_key = String(key)
    col = String(strip(Models.field_db_column(field, String(strip(field_key, '"'))), '"'))
    columns[col] = _spec_or_degraded(field, conn, "<uncompilable:old>"; name = col)
    # The planner only ever asks about a NON-key column's index (a key's index is the key), so a
    # primary key is not recorded here — `IDField` defaults `db_index = true` and would otherwise
    # read as an index the catalog does not list separately.
    if _slot(field, :db_index, false) === true && _slot(field, :primary_key, false) !== true
      name = get(live_index_names, field_key, get(live_index_names, col, nothing))
      indexes[col] = name === nothing ? nothing : string(name)
    end
  end
  composites = LiveComposite[LiveComposite(d.name, d.columns, d.unique, false) for d in declared_composites(model)]
  return LiveTable(String(model_table_name(model)), columns, indexes, composites)
end

"""
    column_delta(new_field, old_spec::ColumnSpec, conn; name = "") -> ColumnDelta

The planner's entry point since #522: the declared side is a `PormGField` and compiles here, the
live side arrived from the readers already compiled, so nothing is reconstructed for it. The live
spec's own `name` is the catalog column — on a rename, the PRE-rename one — which is exactly what
`delta.old_spec.name` has to carry (see the field/field method above for why that matters), so
there is no `old_name` to thread any more.
"""
function column_delta(new_field::PormGField, old_spec::ColumnSpec,
                      conn::Union{PormGPostgres, PormGSQLite};
                      name::AbstractString = "")::ColumnDelta
  new_spec = _spec_or_degraded(new_field, conn, "<uncompilable:new>"; name = name)
  return ColumnDelta(new_spec, old_spec, column_delta(new_spec, old_spec))
end

# ── inspectdb's compiler: ColumnSpec → PormGField ──────────────────────────────────────────────

# Dispatch-only engines for the one reader that has no connection in hand — the PostgreSQL row
# decoder, which is handed a `DataFrameRow` and asked for a model. `field_from_spec` chooses structs
# per ENGINE (`CInt64` is `BigIntegerField` on PostgreSQL and `IntegerField` on SQLite, because that
# is what renders back to the same column) and never touches a connection, so a subtype with no
# fields is enough. The same shape every planner unit test uses for its mock connections.
struct _PostgresEngine <: PormGPostgres end
struct _SQLiteEngine <: PormGSQLite end

"""
    _inspectdb_key_arm(spec::ColumnSpec) -> Symbol

Which of the readers' four key arms a column lands on — `:uuid_pk`, `:reference`, `:varchar_pk`,
`:id_pk` — or `:generic` for a column that is none of them. The order is the contract both readers
have kept in lockstep since #409 (uuid key, then relation, then sized textual key, then the
`IDField` fallback), stated ONCE so [`field_from_spec`](@ref), the SQLite identity rule in the
reader and `Migrations.check` cannot drift apart on it — `check` used to mirror this selection with
a private copy per engine, and said in its own comment that it could therefore drift.
"""
_inspectdb_key_arm(spec::ColumnSpec)::Symbol = _key_arm(spec.primary_key, spec.type, spec.reference !== nothing)

# The same rule over the raw facts, for the readers — which need the arm BEFORE the spec exists,
# because the arm decides how the column's default is read and whether it carries the SQLite identity.
function _key_arm(primary_key::Bool, ctype::CanonicalType, has_reference::Bool)::Symbol
  primary_key && ctype isa CUUID && return :uuid_pk
  has_reference && return :reference
  primary_key && ctype isa CVarChar && ctype.length !== nothing && return :varchar_pk
  primary_key && return :id_pk
  return :generic
end

# The bare-`IDField` key, precisely: the fall-through key arm on an INTEGER column. It is the one arm
# that never reads a default (its slot is `Union{Int64, Nothing}`, and a legacy `serial` key's
# `nextval(…)` could not be declared there) and, on SQLite, the one that compiles the identity. A
# TEXT or REAL key also lands on `:id_pk` — PormG can declare a lengthless textual key only as
# `UUIDField(primary_key = true)`, which renders bare `TEXT` on SQLite — and must take neither, or a
# `UUIDField` key would rebuild its table on every run (found in review; the retired reader had the
# same defect, flattening every such key to an `IDField`).
_integer_key_arm(arm::Symbol, ctype::CanonicalType)::Bool =
  arm === :id_pk && ctype isa Union{CInt16, CInt32, CInt64}

"""
    _arm_carries_db_default(arm, ctype, conn) -> Bool

Whether the field [`field_from_spec`](@ref) builds for this arm has a `db_default` slot to put an
expression default into (#496).

**Asked by both sides, so `Migrations.check` and the importer cannot disagree** — `check`'s
`_expression_default_finding` decides whether to report a column with it, and `field_from_spec`
gates the slot it passes on it. That second call is what makes this a shared rule rather than a
mirror of the if/else below; a mirror is the `_pg_key_arm_ignores_default` shape #522 deleted for
drifting, and the same reason [`_key_arm`](@ref) is stated once.

The arms that do NOT carry it are exactly the ones that compile to an `sIDField`, and `sIDField` has
no slot on purpose: PostgreSQL rejects a column that is both `GENERATED … AS IDENTITY` and carries a
`DEFAULT`, so giving it one would make invalid DDL declarable.

That is broader than `_integer_key_arm`, and the gap it closes was a live defect: a `BLOB PRIMARY
KEY DEFAULT (randomblob(16))` lands on `:id_pk`, compiles to `IDField` on the `else` branch below
— discarding the expression — yet `check` still reported it and told the user to *"declare it as
`db_default=`"*. `IDField` does not accept the keyword, so following that advice produced an
"Unexpected parameter … will be ignored" warning and changed nothing. Found in review.

The one `:id_pk` arm that DOES carry it is a lengthless `TEXT` key on SQLite, which
`_inspectdb_field` compiles to `UUIDField(primary_key = true)` — the single lengthless textual key
PormG can declare.
"""
_arm_carries_db_default(arm::Symbol, ctype::CanonicalType,
                        conn::Union{PormGPostgres, PormGSQLite})::Bool =
  arm !== :id_pk || (conn isa PormGSQLite && ctype isa CText)

# The inverse of `Models._foreign_key_on_delete_sql` for the values a catalog can hold: the stored
# clause back to the spelling a models file declares. `NO ACTION` is `nothing` — lossless, because
# `nothing` and `DO_NOTHING` both render it (#292, `_pg_confdeltype_to_on_delete`) — and `RESTRICT`
# is what a declared `PROTECT` comes back as, one way, as documented on the render function.
function _on_delete_from_clause(clause::Union{String, Nothing})::Union{String, Nothing}
  clause === nothing && return nothing
  action = uppercase(strip(clause))
  (isempty(action) || action == "NO ACTION") && return nothing
  return replace(action, " " => "_")
end

"""
    field_from_spec(spec::ColumnSpec, table::LiveTable, conn) -> PormGField

`inspectdb`'s compiler (#522): the field a models file should DECLARE for a live column, chosen so
that `column_spec(field_from_spec(spec, table, conn), conn) == spec` wherever a declaration can say
what the column is. This is the one place a struct is picked from a `ColumnSpec`, and it is
deliberately off the diff path — `makemigrations` compares specs, so a choice made here can no
longer become a schema opinion the planner acts on (#408, #409, #418 and #437 were all that shape).

The key arms and their order are [`_inspectdb_key_arm`](@ref)'s. Where the declaration vocabulary
cannot say what the column is, the choice is made here, once, and said out loud rather than made
silently:

  * a lengthless `varchar` or an unparameterised `numeric` has no declarable form — `CharField`
    always renders a length and `DecimalField` a precision — so the constructor default is emitted
    and a warning names the column; the first `makemigrations` then plans the width, visibly,
    instead of the two sides pretending to agree (the old reader fabricated `varchar(250)` and
    `numeric(10, 2)` and said nothing);
  * a type outside the closed `CanonicalType` set is emitted as `TextField` with a warning naming
    the raw type — the old reader's silent `:TextField` fallback made a declared `TextField` equal
    to an `inet` column forever;
  * an integer key is `IDField` on both engines, the only integer key PormG can declare, carrying
    the catalog's identity on PostgreSQL; `PROTECT` comes back as `RESTRICT` and `DO_NOTHING` as no
    action, the folds `_foreign_key_on_delete_sql` documents.

The struct per type is per ENGINE only where the renderer is: `CInt64` is `BigIntegerField` on
PostgreSQL (`bigint`) but `IntegerField` on SQLite, where both write `INTEGER` and the reverse map
has always read `IntegerField`; `CDateTime(false)` is `DateTimeField(type = "TIMESTAMP")` on
PostgreSQL and the default flavour on SQLite, which has no other. On the uuid-key, sized-textual-key
and generic arms `unique` and `db_index` are the COMPUTED facts, never a literal `true` — the rule
every key arm of the old readers had to re-learn (#334): a literal that disagrees with the struct's
own constructor default manufactures a permanent disagreement with a plain declaration. The
`IDField` arm and a pk-fk `OneToOneField` pass the literals their constructors default to (`unique =
true`, `db_index = true`), which is the same rule from the other side.

A default the constructor refuses degrades through `_field_or_drop_default`, with the same warning
the readers have always emitted — the readers coerce every literal per `CanonicalType` first, so
this is a second line of defence, not the policy.
"""
function field_from_spec(spec::ColumnSpec, table::LiveTable,
                         conn::Union{PormGPostgres, PormGSQLite})::PormGField
  default = spec.default isa LiteralDefault ? spec.default.value : nothing
  # #496: an expression default becomes a `db_default=` in the generated models file instead of
  # being discarded. The PIN is recorded here rather than in the reader, because `ColumnSpec` carries
  # no engine — and it does not need to: the connection that read the column IS its origin engine,
  # by construction. A portable spelling comes back as a bare `String` so a models file generated
  # from SQLite still works on PostgreSQL; anything else is pinned to the engine it was read from,
  # which is what "pinned to its origin engine" means operationally.
  # GATED on the same predicate `Migrations.check` asks, so the two are one rule rather than two
  # readings of one. The arms that answer `false` all compile to an `sIDField` below and would drop
  # the keyword anyway — `_inspectdb_field`'s `:id_pk` branches simply do not pass it — so this
  # changes no output today. What it changes is the failure mode: re-pointing one of those branches
  # at a slot-bearing field now disagrees with `check` HERE, at one line, instead of in the gap
  # between two files. The mirror it replaces is the `_pg_key_arm_ignores_default` /
  # `_sqlite_key_arm_ignores_default` shape #522 deleted for drifting; flagged in the delta review
  # before it could grow back.
  db_default = _arm_carries_db_default(_inspectdb_key_arm(spec), spec.type, conn) ?
               _db_default_from_spec(spec, conn) : nothing
  indexed = haskey(table.indexes, spec.name)
  # `db_default` sits OUTSIDE the retry closure while `default` is inside it, and the asymmetry is
  # deliberate rather than an oversight: `_field_or_drop_default` exists to rebuild the field when a
  # constructor REFUSES a literal, and a `db_default` cannot cause that. It is already canonical and
  # already passed `is_valid_db_default_sql` in `_default_or_drop`; the portable/pinned refusal
  # cannot fire because introspection always supplies a pin or a vocabulary spelling; and both
  # cannot be set at once because `_default_or_drop` returns either a literal or an expression,
  # never both.
  return _field_or_drop_default(table.name, spec.name, default) do d
    _inspectdb_field(spec, table.name, conn, indexed, d, db_default)
  end
end

# The `db_default` an introspected column declares, or `nothing`.
_db_default_from_spec(spec::ColumnSpec, conn::Union{PormGPostgres, PormGSQLite}) =
  if !(spec.default isa ExpressionDefault)
    nothing
  elseif db_default_is_portable(spec.default.sql)
    canonical_db_default(spec.default.sql)
  elseif conn isa PormGPostgres
    (postgres = spec.default.sql,)
  else
    (sqlite = spec.default.sql,)
  end

function _inspectdb_field(spec::ColumnSpec, table_name::AbstractString,
                          conn::Union{PormGPostgres, PormGSQLite}, indexed::Bool, default,
                          db_default = nothing)::PormGField
  ctype = spec.type
  nullable = spec.nullable
  arm = _inspectdb_key_arm(spec)
  if arm === :uuid_pk
    return Models.UUIDField(primary_key = true, unique = spec.unique, null = false,
                            db_index = indexed, default = default, db_default = db_default)
  elseif arm === :reference
    ref = spec.reference
    # The physical parent table is what the readers record; the binding is DERIVED from it, exactly
    # as both readers derived `.to` (#360/#390), so `_fk_target_binding` of the field agrees with
    # `ForeignKeyRef.binding` by construction.
    parent_table = ref.table === nothing ? something(ref.binding, "") : ref.table
    binding = Models._model_binding_name(parent_table)
    on_delete = _on_delete_from_clause(ref.on_delete)
    field = if spec.primary_key
      # A pk-fk is a `OneToOneField(primary_key = true)`, the Django profile-table shape (#409).
      # `null = false`: a key is conceptually NOT NULL, whatever SQLite happens to permit.
      Models.OneToOneField(binding; pk_field = ref.column, primary_key = true, unique = true,
                           null = false, on_delete = on_delete, default = default,
                           db_default = db_default, db_index = true)
    elseif spec.unique
      # A UNIQUE non-key foreign key IS a one-to-one (#417); both readers have said so since #409.
      Models.OneToOneField(binding; pk_field = ref.column, unique = true, null = nullable,
                           on_delete = on_delete, default = default, db_default = db_default,
                           db_index = indexed)
    else
      Models.ForeignKey(binding; pk_field = ref.column, null = nullable, on_delete = on_delete,
                        default = default, db_default = db_default, db_index = indexed)
    end
    field.to_table = parent_table
    return field
  elseif arm === :varchar_pk
    return Models.CharField(primary_key = true, max_length = ctype.length, unique = spec.unique,
                            null = false, db_index = indexed, default = default,
                            db_default = db_default)
  elseif arm === :id_pk
    if conn isa PormGPostgres
      # INTENTIONAL ENGINE DIVERGENCE, documented: on PostgreSQL every fall-through key stays an
      # `IDField`, because PostgreSQL renders PormG's own non-integer keys as `uuid` / `varchar(n)` —
      # which take the arms above — so a bare `text` or `numeric` key here can only be adopted, and
      # no declaration renders one. SQLite (below) maps a bare `TEXT` key to `UUIDField`, because
      # that IS what `UUIDField(primary_key = true)` renders there. Both engines say so when they
      # flatten, never silently.
      if !_integer_key_arm(arm, ctype)
        @warn "inspectdb: no PormG field declares a primary key of this type on PostgreSQL; emitting " *
              "IDField. A declared IDField will NOT match this column, so makemigrations plans a " *
              "retype unless the column is declared by hand." table = string(table_name) column = spec.name type = spec.raw
      end
      identity = spec.identity
      return Models.IDField(generated = identity !== nothing,
                            generated_always = identity !== nothing && identity.always,
                            unique = true, null = false, db_index = true)
    elseif _integer_key_arm(arm, ctype)
      # `auto_increment` is cosmetic on SQLite (`_column_identity` reads the renderer's condition,
      # not this slot) and is kept as the readers always set it: only an exact `INTEGER` is a rowid
      # alias, which is the one spelling that can carry AUTOINCREMENT.
      return Models.IDField(null = false, primary_key = true,
                            auto_increment = uppercase(strip(spec.raw)) == "INTEGER")
    elseif ctype isa CText
      # A bare `TEXT PRIMARY KEY` is what `UUIDField(primary_key = true)` renders on SQLite (the
      # reverse map writes `TEXT` for `UUID`), and it is the ONE lengthless textual key PormG can
      # declare — `TextField` does not accept `primary_key`. Computed `unique`/`db_index`, matching
      # that constructor's defaults; the retired reader flattened this key to an `IDField`, which
      # regenerated a models file that rebuilt the table (an `INSERT … SELECT` of uuids into a rowid).
      # Said out loud like every other lossy choice here: the column may hold text that is not a
      # UUID, and `UUIDField` validates every write — that is a runtime error a warning at import
      # time can prevent.
      @warn "inspectdb: a lengthless TEXT primary key is emitted as UUIDField(primary_key = true), " *
            "the one declaration that renders it on SQLite. If the key holds text that is not a " *
            "UUID, declare the column by hand." table = string(table_name) column = spec.name
      return Models.UUIDField(primary_key = true, unique = spec.unique, null = false,
                              db_index = indexed, default = default, db_default = db_default)
    else
      @warn "inspectdb: no PormG field declares a primary key of this type; emitting IDField. A " *
            "declared IDField will NOT match this column, so makemigrations plans a retype unless " *
            "the column is declared by hand." table = string(table_name) column = spec.name type = spec.raw
      return Models.IDField(null = false, primary_key = true, auto_increment = false)
    end
  end

  # `:generic` — by canonical type. `base` is the kwarg set every constructor accepts, so #496's
  # `db_default` reaches all sixteen generic types through this one line.
  base = (unique = spec.unique, null = nullable, default = default, db_default = db_default,
          db_index = indexed)
  if ctype isa CInt16
    return Models.PositiveSmallIntegerField(; base...)
  elseif ctype isa CInt32
    return any(c -> c isa NonNegativeCheck, spec.checks) ? Models.PositiveIntegerField(; base...) :
                                                            Models.IntegerField(; base...)
  elseif ctype isa CInt64
    return conn isa PormGPostgres ? Models.BigIntegerField(; base...) : Models.IntegerField(; base...)
  elseif ctype isa CFloat64
    return Models.FloatField(; base...)
  elseif ctype isa CDecimal
    if ctype.precision !== nothing && ctype.scale !== nothing
      return Models.DecimalField(; base..., max_digits = ctype.precision, decimal_places = ctype.scale)
    end
    @warn "inspectdb: the column's numeric type carries no precision, which no DecimalField can " *
          "declare; emitting the constructor default. The first makemigrations will plan that width." table = string(table_name) column = spec.name type = spec.raw
    return Models.DecimalField(; base...)
  elseif ctype isa CBool
    return Models.BooleanField(; base...)
  elseif ctype isa CVarChar
    if ctype.length === nothing
      @warn "inspectdb: the column is a varchar without a length, which no CharField can declare; " *
            "emitting the constructor default. The first makemigrations will plan that length." table = string(table_name) column = spec.name type = spec.raw
      return Models.CharField(; base...)
    end
    return Models.CharField(; base..., max_length = ctype.length)
  elseif ctype isa CText
    return Models.TextField(; base...)
  elseif ctype isa CDate
    return Models.DateField(; base...)
  elseif ctype isa CDateTime
    return (conn isa PormGPostgres && !ctype.with_timezone) ?
           Models.DateTimeField(; base..., type = "TIMESTAMP") : Models.DateTimeField(; base...)
  elseif ctype isa CTime
    return Models.TimeField(; base...)
  elseif ctype isa CInterval
    return Models.DurationField(; base...)
  elseif ctype isa CUUID
    return Models.UUIDField(; base...)
  elseif ctype isa CJSON
    return Models.JSONField(; base...)
  elseif ctype isa CBytes
    bound = findfirst(c -> c isa ByteLengthCheck, spec.checks)
    return bound === nothing ? Models.BinaryField(; base...) :
                               Models.BinaryField(; base..., max_length = spec.checks[bound].max_bytes)
  end
  # `CUnsupported`: nothing in PormG's vocabulary declares this column. Said out loud — the old
  # reader's silent `:TextField` fallback is how a declared `TextField` came to equal an `inet`.
  @warn "inspectdb: the column's type has no PormG field type; emitting it as TextField. A declared " *
        "TextField will NOT match this column, so makemigrations plans a retype unless the column is " *
        "excluded or declared by hand." table = string(table_name) column = spec.name type = spec.raw
  return Models.TextField(; base...)
end

"""
    model_from_live(table::LiveTable, conn) -> PormGModel

The model `inspectdb` writes for a live table — every column through [`field_from_spec`](@ref), in
physical order (#544), plus the index bookkeeping `Model_to_str` and the planner's DROP INDEX path
read from `cache`. `convertSQLToModel` and `convert_schema_to_models` are this function applied to
what the readers return.
"""
function model_from_live(table::LiveTable, conn::Union{PormGPostgres, PormGSQLite})::PormGModel
  fields = OrderedDict{String, PormGField}()
  for (col, spec) in table.columns
    fields[col] = field_from_spec(spec, table, conn)
  end
  model = Models.Model(table.name, fields)
  named = Dict{String, Any}(col => name for (col, name) in table.indexes if name !== nothing)
  isempty(named) || (model.cache["index"] = named)
  _attach_composite_indexes!(model, table.composites)
  return model
end
