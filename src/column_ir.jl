# ==============================================================================
# CANONICAL COLUMN IR (#507) — THE NOUNS
#
# What a database column IS, and how two of them differ. Nothing here knows what a `PormGField`
# is: compiling one into a `ColumnSpec` is the other half of #507 and lives in
# `src/migrations/column_spec.jl`, next to the renderer it calls.
#
# WHY THIS IS LAYER 1, when phase 1 deliberately put it at layer 3. Phase 1 sited the IR in
# `Migrations` under a stated condition — *"`Dialect` does not render from it in phase 1, so nothing
# earlier in the include chain needs to name it"* — and #507 phase 2 is exactly what breaks that
# condition: `Dialect.alter_field` now takes a `ColumnDelta` and decides which fragments to emit
# from it. `Dialect` is include step 10 and `Migrations` is step 11, and each submodule resolves
# `import PormG: …` at include time, so a type defined in `Migrations` simply does not exist yet
# when `Dialect` is compiled. That is the #239 failure verbatim (the error taxonomy defined at step
# 11, unusable by `Models` / `Configuration` / `Dialect`), and the rule it produced is the one
# followed here: **Kernel holds the nouns, `PormG` keeps the verbs.**
#
# The split is by DEPENDENCY, not by taste. Everything in this file needs nothing but itself; the
# compiler needs `Models` and `Dialect`, so it stays where they are reachable.
#
# `CUnsupported` is the degradation path throughout, and it is what makes the IR safe: a rendered
# type nothing here recognises keeps its lower-cased raw string and compares by that — which is
# EXACTLY what `Dialect._column_signature` did for every type before #507. So the worst case of an
# unrecognised type is the behaviour that shipped before this file existed, never an abort.
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
# hash(b)` contract and misbehaves the moment one lands in a `Set` or a `Dict` key. Phase 1 wrote
# these while nothing hashed a spec; phase 2 keys plan actions off the delta, so they now earn it.
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
it reaches the plan as DROP + ADD CONSTRAINT, planned by `Migrations._fk_constraint_action` off the
`:reference` slot. `Dialect.alter_field` has no branch for that slot and needs none, which is how
#507 phase 2 replaced a filter someone had to remember (`_FK_IDENTITY_ATTRS`) with an absence that
cannot be forgotten.

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
[`_fk_targets_equal`](@ref), the single definition `Models._compare_field_foreign_key` also calls, so
no two places can answer "same parent?" differently. Two copies of that rule drifting apart is the
defect class #507 exists to end; introducing one here to build the thing that ends it would have been
the same mistake in a new place.

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
  _fk_targets_equal(a.table, a.binding, b.table, b.binding) || push!(deltas, :to)
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


# ── Same parent? ─────────────────────────────────────────────────────────────────────────────────

"""
    _fk_targets_equal(new_table, new_binding, old_table, old_binding) -> Bool

Whether two foreign keys point at the same parent, given each side's resolved physical table (or
`nothing` when it cannot be named) and its folded Julia binding.

**The one definition of that rule.** [`reference_delta`](@ref) calls it with the two `ForeignKeyRef`s
a [`ColumnSpec`](@ref) carries, and `Models._compare_field_foreign_key` calls it with two fields'
resolutions. Holding one copy each would let two answers to "same parent?" drift apart, and that
drift is precisely the defect class #507 exists to end — so the rule is stated here and nowhere else.

When BOTH sides can name their physical table, that is the comparison (#360). Only when one cannot —
an unresolved String target — does it fall back to the binding axis.

It lives in `Kernel` rather than in `Models` because `ForeignKeyRef`'s equality is built on it and
the IR is layer 1 (see this file's header). It needs nothing from `Models` to say what it says: four
already-resolved names in, one Bool out.
"""
_fk_targets_equal(new_table::Union{String, Nothing}, new_binding::Union{String, Nothing},
                  old_table::Union{String, Nothing}, old_binding::Union{String, Nothing})::Bool =
  (new_table !== nothing && old_table !== nothing) ? new_table == old_table :
                                                     new_binding == old_binding

# ── The diff ─────────────────────────────────────────────────────────────────────────────────────

_references_equal(a::Nothing, b::Nothing)::Bool = true
_references_equal(a::ForeignKeyRef, b::ForeignKeyRef)::Bool = a == b
_references_equal(a, b)::Bool = false

"""
    COLUMN_DELTA_COMPARATORS

The facets of a column, each with the predicate that decides whether two `ColumnSpec`s agree on it.

**This table is the closed slot set.** [`column_delta`](@ref) emits nothing that is not a key here,
and [`COLUMN_DELTA_SLOTS`](@ref) is derived from it rather than written beside it — so "every slot a
delta can carry" is a fact one edit maintains, not two. `Dialect.alter_field` is required to have a
rendering branch for each (or, for `:reference`, a documented reason not to), and
`test/unit/test_plan_actions_golden.jl` asserts that against this constant. Before #507 phase 2 the
equivalent guarantee was a hand-transcribed copy of `alter_field`'s implemented list inside a test —
which passed while the renderer raised, because membership in a list is not a rendering branch.

The order is the order deltas are reported in, and it is the order the pre-#507 planner reported
attributes in; the golden-plan corpus pins it.
"""
const COLUMN_DELTA_COMPARATORS = (
  :type        => (new_spec, old_spec) -> new_spec.type == old_spec.type,
  :nullable    => (new_spec, old_spec) -> new_spec.nullable == old_spec.nullable,
  :primary_key => (new_spec, old_spec) -> new_spec.primary_key == old_spec.primary_key,
  :unique      => (new_spec, old_spec) -> new_spec.unique == old_spec.unique,
  :default     => (new_spec, old_spec) -> new_spec.default == old_spec.default,
  :reference   => (new_spec, old_spec) -> _references_equal(new_spec.reference, old_spec.reference),
  :checks      => (new_spec, old_spec) -> new_spec.checks == old_spec.checks,
  :identity    => (new_spec, old_spec) -> new_spec.identity == old_spec.identity,
)

"""
    COLUMN_DELTA_SLOTS

Every facet name a [`column_delta`](@ref) can report, derived from
[`COLUMN_DELTA_COMPARATORS`](@ref) so the two cannot disagree.
"""
const COLUMN_DELTA_SLOTS = map(first, COLUMN_DELTA_COMPARATORS)

"""
    column_delta(new_spec, old_spec) -> Vector{Symbol}

Which facets of the column differ, as IR-level names — a subset of [`COLUMN_DELTA_SLOTS`](@ref), in
that order.

This is the typed delta every plan action derives from since #507 phase 2. Phase 1 handed it to an
`alter_attrs` adapter that translated it back into field-attribute symbols; that adapter is gone, and
with it the possibility of an action site holding its own opinion of a fact decided here.
"""
function column_delta(new_spec::ColumnSpec, old_spec::ColumnSpec)::Vector{Symbol}
  deltas = Symbol[]
  for (slot, same) in COLUMN_DELTA_COMPARATORS
    same(new_spec, old_spec) || push!(deltas, slot)
  end
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

# ── ColumnDelta ──────────────────────────────────────────────────────────────────────────────────

"""
    ColumnDelta(new_spec, old_spec, changed)

One column's difference: both sides' [`ColumnSpec`](@ref) and the facets that differ (#507 phase 2).

**Every plan action is a function of this and nothing else.** The two specs are carried, not just the
symbol list, because an action needs the *direction* as well as the fact — `SET NOT NULL` vs
`DROP NOT NULL`, `ADD` vs `DROP CONSTRAINT`, add-an-identity vs drop-one — and reading that direction
back off the `PormGField` structs is what phase 2 removes. #498, #504, #514 and #515 were four
action sites doing exactly that, each with its own answer.

Rendering may still read a field for the SQL **text** (a cast expression, a column type). What it may
not do is re-decide *whether* to emit a statement; that comes from `changed`.

`changed` is validated against [`COLUMN_DELTA_SLOTS`](@ref) at construction. A delta is small and
built once per column, so the check is free, and it is what makes "the slot set is closed" true at
runtime rather than only in a comment — a typo'd slot is then a loud error instead of a fragment that
silently never renders.
"""
struct ColumnDelta
  new_spec::ColumnSpec
  old_spec::ColumnSpec
  changed::Vector{Symbol}

  function ColumnDelta(new_spec::ColumnSpec, old_spec::ColumnSpec, changed::Vector{Symbol})
    for slot in changed
      slot in COLUMN_DELTA_SLOTS ||
        throw(InvalidMigrationError("`$(slot)` is not a column-delta facet; the closed set is " *
                                    "$(COLUMN_DELTA_SLOTS) (see COLUMN_DELTA_COMPARATORS)"))
    end
    return new(new_spec, old_spec, changed)
  end
end

"""
    isempty(delta::ColumnDelta) -> Bool

Whether the two columns are the same column. This is the planner's "nothing changed" answer since
#507 phase 2 retired the whole-model early-out: an empty delta means no column action at all, on
either engine.
"""
Base.isempty(delta::ColumnDelta)::Bool = isempty(delta.changed)

# Set membership reads better at the action sites than `slot in delta.changed`, and it keeps them from
# reaching into the vector to do anything else with it.
Base.in(slot::Symbol, delta::ColumnDelta)::Bool = slot in delta.changed
