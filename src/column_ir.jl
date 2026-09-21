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

**Reachable from both sides of the diff since #496**, which is what this variant was defined ahead
of. The declared side produces one from a field's `db_default` slot (`Migrations._column_default`);
the live side produces one in `Migrations._default_or_drop`, which before #496 dropped an expression
default it could not represent (#472/#475) and now carries it.

`sql` is the **canonical** form — [`canonical_db_default`](@ref) — never the raw text, and both
construction sites are required to go through it. That is not tidiness: the two sides are compared
as strings, so a column whose declared spelling normalised differently from its live one would
differ from itself on every run, which is the #325 churn class. One normaliser, applied twice.

Equality is plain `String` comparison and is left that way on purpose — the IR must not claim two
different expressions are the same. The one place the diff is lenient is the `NoDefault` /
`ExpressionDefault` pair, and that lives in `_defaults_equal` beside the comparator table, where it
is visible as an action rule rather than hidden in a type's `==`.
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

# True when `s` is ONE parenthesized group, i.e. the outer `(` closes on the final character.
# Balance-checked rather than regex-anchored: the `r"^\((.+)\)$"` this replaces rewrote `(a) + (b)`
# to `a) + (b`. Parens inside a string literal do not count.
#
# Third home, same reason each time — it keeps moving to the lowest layer that needs it. It was
# `_pg_wrapped_in_parens`, beside the PostgreSQL cleaner it was written for, until the SQLite
# default reader needed the identical predicate (#472); it moved here in #496, because
# `canonical_db_default` normalises the DECLARED side of a `db_default` and layer 1 is the only
# place `Models`, `Dialect` and `Migrations` can all reach. It is plain string logic; neither
# backend is in it, which is what has made every move safe.
#
# It skips `"…"` as well as `'…'` since #496, matching `is_valid_db_default_sql` twenty lines below.
# Two scanners in one file with different ideas of what a literal is is the shape that gets copied
# wrong later, and the divergence was reachable rather than theoretical: a quoted identifier
# containing a `)` — `("a)b")` — made the old version answer `false`, so `canonical_db_default` left
# the wrapper on, SQLite's renderer added a second one, and `PRAGMA table_info` reported back a
# different string than was declared. That is a permanent `:default` delta, the exact churn class
# this file exists to prevent. Found in review.
function _wrapped_in_parens(s::AbstractString)::Bool
  (ncodeunits(s) >= 2 && first(s) == '(' && last(s) == ')') || return false
  depth = 0
  in_literal = false          # '…'
  in_ident = false            # "…"
  last_i = lastindex(s)
  i = firstindex(s)
  while i <= last_i
    ch = s[i]
    if in_literal
      if ch == '\''
        j = nextind(s, i)
        if j <= last_i && s[j] == '\''   # `''` is an escaped quote, not the end of the literal
          i = nextind(s, j); continue
        end
        in_literal = false
      end
    elseif in_ident
      if ch == '"'
        j = nextind(s, i)
        if j <= last_i && s[j] == '"'    # `""` is an escaped quote inside an identifier
          i = nextind(s, j); continue
        end
        in_ident = false
      end
    elseif ch == '\''
      in_literal = true
    elseif ch == '"'
      in_ident = true
    elseif ch == '('
      depth += 1
    elseif ch == ')'
      depth -= 1
      depth == 0 && return i == last_i
    end
    i = nextind(s, i)
  end
  return false
end

# ── db_default: the declarable expression default (#496) ─────────────────────────────────────────
#
# #475 chose to DROP a non-literal column DEFAULT uniformly; #496 is the other half it named — a
# `db_default` slot on the field structs, after Django's `Field.db_default`, so the expression is
# stored verbatim and rendered verbatim. Everything in this block is LAYER 1 for the #239 reason:
# the vocabulary is read by `Models` (the field constructors, include step 107), by `Dialect` (the
# two `field_to_column` renderers, step 118) and by `Migrations` (the compiler and the schema
# readers, step 226). A constant defined part-way down that chain cannot be named by the steps
# above it.
#
# WHERE PORMG DEPARTS FROM DJANGO, deliberately. Django's `db_default` takes an expression OBJECT
# (`Now()`, `TruncMonth(…)`) compiled per backend, so portability falls out by construction and the
# diff compares objects rather than text. PormG takes the raw string, which is LESS magic — nothing
# is inferred — but it cannot know which engines a given expression is valid on. Hence the two
# shapes: a bare `String` asserts portability and is checked against the vocabulary below; a
# `NamedTuple` names its engines.

"""
    PORTABLE_DB_DEFAULTS

The expressions PormG will render on **both** engines from a bare-`String` `db_default`.

Exactly two, and the shortness is the point rather than an accident of effort. An entry has to
survive the full round trip — PormG renders it, the engine stores it, the schema reader reads it
back — *identically on both backends*, or a column carrying it would churn forever on one of them.
These two qualify because they are `literal-value` keywords in SQLite's `DEFAULT` grammar (so they
render bare, with no parentheses, and `PRAGMA table_info` echoes them verbatim) and
`SQLValueFunction` nodes in PostgreSQL (so the deparser prints them back as themselves).

`now()` is deliberately **not** folded in as a synonym for `CURRENT_TIMESTAMP`. The rule
`parse_canonical_type` states for types applies here verbatim: collapse two spellings only when
PormG *renders* them identically, so the database cannot tell them apart. PormG renders `now()` as
`now()`, so a user who declares one against a database that reports the other genuinely disagrees
with it, and folding would hide a real (one-off) rewrite.

Anything outside this tuple must name its engine — see [`canonical_db_default`](@ref).
"""
const PORTABLE_DB_DEFAULTS = ("CURRENT_TIMESTAMP", "CURRENT_DATE")

"""
    canonical_db_default(sql) -> String

The comparison form of a `db_default` expression: whitespace trimmed, balanced outer parentheses
removed, and a [`PORTABLE_DB_DEFAULTS`](@ref) spelling folded to upper case.

**Applied to both sides of the diff, through this one function**, which is the whole reason it lives
here rather than in either caller. The declared side goes through it in the field constructor; the
live side goes through it in `Migrations._default_or_drop`. If only one side normalised, a column
would differ from itself forever — the #325 churn class in a new costume.

Each step is FORCED by something measured, not chosen for tidiness:

  * **outer parens** — SQLite's grammar requires `DEFAULT (expr)` for anything outside its
    `literal-value` set, so PormG adds a layer when it renders; `PRAGMA table_info` then reports the
    text back with that layer *already removed* (measured on SQLite 3.53.4:
    `DEFAULT (abs(random()) % 10)` reads back as `abs(random()) % 10`, and the bare form is a syntax
    error). Stripping here makes the renderer's addition and the catalog's removal exact inverses.
    `_pg_clean_default` strips a layer on the PostgreSQL side for its own reasons, so the same
    normalisation keeps the two engines describing one expression the same way.
  * **case** — SQLite echoes the source text including its case; PostgreSQL's deparser always prints
    these two keywords upper case. Folding the vocabulary is what lets `db_default =
    "current_timestamp"` converge against either catalog.
  * **whitespace** — `Model_to_str` → reload → re-canonicalise is a real cycle, so this must be
    idempotent: `canonical_db_default(canonical_db_default(x)) == canonical_db_default(x)`.

Only the vocabulary is case-folded. An opaque expression keeps its case, because a `"MyCol"` inside
it may be a quoted identifier, where case is significant on both engines.
"""
function canonical_db_default(sql::AbstractString)::String
  s = String(strip(sql))
  # UNBOUNDED, unlike `_pg_strip_trailing_casts`'s `for _ in 1:8`, and the difference is deliberate.
  # Each pass removes at least the two parentheses it matched, so the loop is strictly decreasing
  # and cannot spin — there is nothing for a bound to protect against. A bound would instead COST
  # the idempotence this function promises: `((((((((( 1 )))))))))` would stop at `(1)` on the first
  # call and reduce further on the second, so `canonical(canonical(x)) != canonical(x)` for a deep
  # enough nesting. Found in review.
  while _wrapped_in_parens(s)
    inner = String(strip(s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]))
    isempty(inner) && break
    s = inner
  end
  up = uppercase(s)
  return up in PORTABLE_DB_DEFAULTS ? up : s
end

"""
    db_default_is_portable(sql) -> Bool

Whether this expression renders on both engines, i.e. whether its canonical form is in
[`PORTABLE_DB_DEFAULTS`](@ref). A `db_default` that is not portable must name the engine it belongs
to; the field constructors refuse a bare string that fails this.
"""
db_default_is_portable(sql::AbstractString)::Bool = canonical_db_default(sql) in PORTABLE_DB_DEFAULTS

"""
    is_valid_db_default_sql(sql) -> Bool

Whether `sql` is *well-formed enough* to be rendered into a column definition.

**This is not a security boundary and does not pretend to be one.** The trust question for #496 was
settled explicitly: a `db_default` is author-supplied schema text, the same category as `db_table`
and `db_column`, which PormG already renders verbatim. Someone who can write a models file can
already run arbitrary Julia.

What it is, is a guard against three ways a *typo* stops being a typo and silently changes a schema,
all of them invisible in the generated DDL:

  * a `--`, or a `/*`, outside a string literal **comments out the rest of the column list**, so a
    `CREATE TABLE` quietly loses every column after this one;
  * an unterminated `'` swallows the remainder of the statement the same way;
  * a top-level `;` splits one DDL statement into two, and PostgreSQL's simple query protocol —
    which is what a parameterless `execute` uses — runs both;
  * a top-level `,` **injects an entire extra column** into the `CREATE TABLE` it sits in
    (`db_default = "0, evil TEXT DEFAULT 'x'"`). Added in review: it is at least as easy to type as
    a stray `;`, and it was the one statement-breaking character the first version of this scanner
    let through.

`depth` counts **both** `()` and `[]`, and the brackets are not decoration. A comma at depth 0 is
never valid in a column default, but "depth" has to include an array constructor or the rule
misfires on `ARRAY['a'::text, 'b'::text]` — which is precisely what PostgreSQL's deparser prints for
`DEFAULT ARRAY['a','b']`, so the first version of the comma rule refused a value a real catalog
produces. Found in the delta review, after the docstring had claimed every legitimate comma lives
inside a function call's parentheses. It does not; some live inside brackets.

Parentheses are balance-checked for the same reason [`_wrapped_in_parens`](@ref) balance-checks
rather than regex-matching: the renderer adds a paren layer on SQLite, and an unbalanced expression
would make that layer land in the wrong place.

Every one of these stays legal *inside* a literal, which is what makes the guard usable at all:
`'a;b'`, `'--'`, `'a,b'` and `'it''s'` all pass.

`(` and `[` share one counter, so mismatched delimiters balance against each other and `(a]` is
accepted. That is deliberate rather than overlooked: it is a typo both engines reject loudly when
the DDL is applied, which puts it in the "fails at the database" category this guard already leaves
alone — the guard exists for text that changes the statement *silently*, not for text that is
merely wrong. Known false rejections, all conservative and all
rare: a PostgreSQL dollar-quoted body containing any of them, a `/* … */` comment that IS closed
(every `/*` is refused, not only an unterminated one), and the backslash-escape spellings `E'\\''`
and `'a\\'b'`, which this walk reads as an unterminated literal because standard SQL escapes a
quote by doubling it.

Two callers, two policies, and the split is deliberate: a field constructor treats `false` as a
`FieldValidationError` (the user wrote it; the remedy is one edit), while the schema readers treat it
as drop-and-warn. A reader that threw would abort an entire `convert_schema_to_models` run over one
column — the #472 failure this codebase spent an issue removing.
"""
function is_valid_db_default_sql(sql::AbstractString)::Bool
  s = strip(sql)
  isempty(s) && return false
  depth = 0
  in_single = false          # '…'  — a SQL string literal; '' escapes a quote
  in_double = false          # "…"  — a quoted identifier on both engines
  last_i = lastindex(s)
  i = firstindex(s)
  while i <= last_i
    ch = s[i]
    if in_single
      if ch == '\''
        j = nextind(s, i)
        if j <= last_i && s[j] == '\''
          i = nextind(s, j); continue
        end
        in_single = false
      end
    elseif in_double
      if ch == '"'
        j = nextind(s, i)
        if j <= last_i && s[j] == '"'
          i = nextind(s, j); continue
        end
        in_double = false
      end
    elseif ch == '\''
      in_single = true
    elseif ch == '"'
      in_double = true
    elseif ch == ';'
      return false
    elseif ch == ',' && depth == 0
      return false          # injects a whole extra column definition — see the docstring
    elseif ch == '(' || ch == '['
      depth += 1
    elseif ch == ')' || ch == ']'
      depth -= 1
      depth < 0 && return false
    elseif ch == '-' || ch == '/'
      j = nextind(s, i)
      j <= last_i && s[j] == (ch == '-' ? '-' : '*') && return false
    end
    i = nextind(s, i)
  end
  return !in_single && !in_double && depth == 0
end

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

The value stored is the **rendered** clause, produced by `Models._foreign_key_on_delete_sql`, so
comparing two stored values with `==` compares what the database would be told, by construction. It
is what folds the pairs that mean the same clause: `PROTECT` ≡ `RESTRICT`, `DO_NOTHING` ≡ `nothing` ≡
`NO ACTION` (#498). On the introspected side the readers normalise the raw catalog value through
`_normalize_introspected_on_delete` and render it through the same function (#522), so both sides
reach this slot from the same vocabulary.

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
[`_fk_targets_equal`](@ref), the single definition of it, so no two places can answer "same parent?"
differently. Two copies of that rule drifting apart is the defect class #507 exists to end;
introducing one here to build the thing that ends it would have been the same mistake in a new place.

Both axes have to be carried into the `ForeignKeyRef` because the two sides are asymmetric by
construction — introspection sets `to_table` to the live parent table while `Model_to_str` never
emits it, and a declared `.to` may still be an unresolved binding string.

Similarly, `on_delete` is compared with `==` on values both sides rendered through
`Models._foreign_key_on_delete_sql`; the rendering happens once at compile time instead of on every
comparison.

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
a [`ColumnSpec`](@ref) carries; it used to have a second caller, `Models._compare_field_foreign_key`,
which #522 retired with the field-pair comparison it served. Holding one copy per caller would let
two answers to "same parent?" drift apart, and that drift is precisely the defect class #507 exists
to end — so the rule is stated here and nowhere else.

When BOTH sides can name their physical table, that is the comparison (#360). Only when one cannot —
an unresolved String target — does it fall back to the binding axis.

The table is compared EXACTLY, case included (#390). It was folded to lower case once, because
SQLite's `PRAGMA foreign_key_list` reports a parent as the `REFERENCES` clause spelled it, and that
fold was safe on SQLite and WRONG on PostgreSQL, where `Driver` and `driver` can be two tables in one
schema — a key repointed between them went undetected. Fixed at the source instead: the SQLite reader
canonicalises the `REFERENCES` spelling through `_sqlite_canonical_table_name`, the PostgreSQL reader
has always returned the catalog spelling, and `get_migration_plan` keys tables by exact name — so an
exact comparison here is the one that agrees with how table identity is decided everywhere else.
(Prior art: SQLAlchemy puts identifier-case knowledge in the dialect at reflection time, so nothing
above the reflection layer has to know which engine it is on. Same shape.)

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

# Do the two sides of the diff agree about the column's DEFAULT?
#
# Plain `==` for every pair but one. The exception is the #496 upgrade path, and it is the single
# deliberate asymmetry in this file:
#
#     declared NoDefault  vs  live ExpressionDefault  ⇒  AGREE
#
# Before #496 the schema readers DROPPED an expression default, so the live side of such a column
# read back as `NoDefault` and a model declaring nothing converged. `docs/src/schema_conventions.md`
# promises exactly that, in as many words — *"PormG will not propose dropping a default it cannot
# see … no `DROP DEFAULT` is generated against your live `now()`"*. #496 makes the reader CARRY the
# expression, so without this arm that same model would suddenly differ from its own table and
# `makemigrations` would plan `ALTER COLUMN … DROP DEFAULT` against a real database default — on
# every existing app, on its first run after upgrading, and unprompted on PostgreSQL because
# `DROP DEFAULT` is not classified destructive. This keeps the promise now that PormG *can* see it.
#
# The cost, stated rather than hidden: declaring a `db_default` and later deleting the keyword also
# plans nothing. A state-based engine cannot tell "never declared" from "deliberately removed" —
# there is no migration history to consult — so one of the two has to be silent, and silence on the
# destructive one is the only defensible choice. `Migrations.check` reports the column either way,
# which is what keeps it visible; removing a database default stays a by-hand operation.
#
# Every OTHER pairing still plans, and that is what stops this being a hole:
#   NoDefault      → ExpressionDefault   adding one is planned (SET DEFAULT)
#   ExpressionDefault → other expression  changing one is planned
#   ExpressionDefault → LiteralDefault    #475's quoting distinction survives
#   LiteralDefault → ExpressionDefault    ditto, in the other direction
_defaults_equal(a::ColumnDefault, b::ColumnDefault)::Bool = a == b
_defaults_equal(::NoDefault, ::ExpressionDefault)::Bool = true

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
  # `_defaults_equal`, not `==` — see its comment above for the one asymmetric pair (#496). The
  # precedent for a custom predicate in this table is `:reference`, two lines down.
  :default     => (new_spec, old_spec) -> _defaults_equal(new_spec.default, old_spec.default),
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
#
# BOTH DIRECTIONS, since #496. `column_delta` is directional by construction — its arguments are
# `(new_spec, old_spec)` and it answers *"what must change to get from old to new"* — and
# `_defaults_equal` adds one genuinely one-way rule to it: a live expression default the declared
# side does not mention is not a change, while declaring one where the database has none is. An
# `==` defined as `isempty(column_delta(a, b))` would inherit that and stop being symmetric — and
# `hash` (below, unchanged, which folds `s.default` strictly) would then disagree with it on
# exactly that pair.
#
# Asking the table twice keeps `==` symmetric AND strict on that pair, without a second hand-written
# copy of the facet list — which is the whole reason `COLUMN_DELTA_SLOTS` is derived rather than
# written beside the table. Every other comparator is already symmetric, so the second call is
# redundant for them and cheap.
Base.:(==)(a::ColumnSpec, b::ColumnSpec)::Bool =
  isempty(column_delta(a, b)) && isempty(column_delta(b, a))

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
