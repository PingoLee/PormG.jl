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

# A network address (#28): `GenericIPAddressField` renders `inet`, `CIDRField` renders `cidr`. Two
# singletons rather than one `CNetwork(kind)`, by the rule the set already follows: a PostgreSQL
# type with its own input function, output text and casts gets its own kind (`CUUID`, `CJSON`),
# and a parameter is a MODIFIER of one base type (`CVarChar(len)`, `CDecimal(p, s)`). Folding the
# two into a flag would invite the branch-on-a-field mistake `value_repr.jl` warns about.
#
# The template for the next PostgreSQL-native type (an array is #28's other half): the kind is
# PostgreSQL's alone. SQLite has no column for such a field — `Dialect.field_to_column` refuses it
# there — so the SQLite parser never produces these kinds.
struct CInet    <: CanonicalType end
struct CCidr    <: CanonicalType end
# A stored full-text document (#1021): `SearchVectorField` renders `tsvector`. The same template.
struct CTsVector <: CanonicalType end

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

# A one-dimensional PostgreSQL array of `element` (#28, `ArrayField`) — the first kind that holds
# another kind. A parameterized kind rather than a family of singletons (`CIntArray`, …) because the
# element is a full kind in its own right, modifiers included: `varchar(10)[]` and `varchar(20)[]`
# differ exactly as `varchar(10)` and `varchar(20)` do, and the retype rules for the elements are
# the scalar ones.
#
# PostgreSQL-only, like `CInet`: the SQLite parser never produces it. Default `==`/`hash` are right
# — the struct is immutable and `element` is itself compared field-wise — so it carries no custom
# pair. A declared size or dimension count is NOT here, and cannot be: `format_type` prints
# `integer[3]` and `integer[][]` both as `integer[]`, so a kind that carried either would differ
# from the catalog on every run.
struct CArray <: CanonicalType
  element::CanonicalType
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

Equality is plain comparison of both slots and is left that way on purpose — the IR must not claim
two different expressions are the same. The places the diff is lenient live in `_defaults_equal`
beside the comparator table, where they are visible as action rules rather than hidden in a type's
`==`: the `NoDefault` / `ExpressionDefault` pair (#496), and the ownership marker below (#1037).

`owned` is set on the **live** side only, and only by the PostgreSQL reader: it is the declared hash
of a valid [`DB_DEFAULT_MARKER_PREFIX`](@ref) marker on the column, the record that PormG applied a
declaration hashing to it and that the default has not changed since ([`db_default_owner`](@ref)).
It is evidence about a history, not a claim that two texts mean the same: PostgreSQL re-prints a
stored default through its deparser (`lower('OPEN')` reads back `lower('OPEN'::text)`), so the text
alone cannot say whether the live default is the declared one, and the marker can.
"""
struct ExpressionDefault <: ColumnDefault
  sql::String
  owned::Union{Nothing, String}
end
ExpressionDefault(sql::AbstractString) = ExpressionDefault(String(sql), nothing)

Base.:(==)(a::ExpressionDefault, b::ExpressionDefault)::Bool = a.sql == b.sql && a.owned == b.owned
# Coarser than `==` on purpose: `ColumnSpec`'s `==` asks `_defaults_equal`, which calls a declared
# `lower('OPEN')` equal to an owned live `lower('OPEN'::text)` (#1037), and for that pair two specs it
# calls equal must hash equal. Folding the text in would break it. (The #496 `NoDefault` /
# `ExpressionDefault` pair is not one: `ColumnSpec`'s `==` asks in both directions, so it is unequal.)
Base.hash(::ExpressionDefault, h::UInt) = hash(:ExpressionDefault, h)

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
#
# #934 taught `is_valid_db_default_sql` to REFUSE more spellings (`E'…'`, `\'`, dollar quotes,
# backticks, SQLite's `[…]` reading) and left this scanner alone on purpose: it feeds the CHECK and
# index hashes stored in databases, and on every text the validator still accepts the two agree.
# Teach it a new quote only together with a validator that accepts that quote.
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
merely wrong.

**Two readings, both must pass (#934).** The text is sent verbatim to whichever engine the model
migrates on, and the engines do not agree on where a quote ends. A walk that knows only `'…'` and
`"…"` accepted `x = E'\\'' ; DROP TABLE result ; SELECT E'\\''` — one literal to it, three
statements to PostgreSQL — and a SQLite `[…]` identifier could hide a top-level `,` from the
bracket counter. So the text is scanned twice: once with `[`/`]` as PostgreSQL's array brackets,
once with `[` opening SQLite's bracket identifier that ends at the first `]`. Both readings refuse
the spellings whose end only one engine can find, rather than lex them:

  * an `E'…'` escape string (an `E` or `e` that starts a token, right before the quote);
  * a backslash right before a quote inside a literal — an escape under
    `standard_conforming_strings = off`, a literal backslash then the closing quote under `on`;
  * a dollar quote opener, `\$\$` or `\$tag\$` (not `\$1`, and not a `\$` inside an identifier);
  * a backtick, anywhere outside a literal or an identifier.

A backslash anywhere else in a literal stays legal, so a regex CHECK such as `code ~ '^\\d{3}\$'`
passes — PostgreSQL's deparser prints backslashes inside a plain `'…'` and never writes `E'…'` or a
dollar quote, so no catalog text the readers see is refused by these rules.

Known false rejections, all conservative and all rare: a `/* … */` comment that IS closed (every
`/*` is refused, not only an unterminated one); a literal ending in a backslash (`'C:\\'`); a
`'` or `]` inside a literal inside brackets (`ARRAY['a]']`), which SQLite's reading ends early; and
a PostgreSQL two-dimensional array (`ARRAY[ARRAY[1, 2], ARRAY[3, 4]]`), whose inner `,` is top-level
on SQLite's reading. Arrays are not a column type SQLite can hold, so the last one costs nothing a
portable model could have declared.

Not modeled, deliberately: SQLite's TCL-style parameters (`:a(…)`, `\$a(…)`, `@a(…)`), each one token
that can swallow a `'` up to its `)`. SQLite refuses a parameter at prepare time in every place this
text lands — a column DEFAULT, a CHECK, an index member, a partial index's `WHERE` — so the statement
fails loudly before anything after it could run.

Only this validator applies the two readings. [`_wrapped_in_parens`](@ref), which feeds the CHECK and
index hashes stored in databases, is deliberately unchanged: for every text this function accepts,
the two scanners already agree, so no stored marker moves.

Two callers, two policies, and the split is deliberate: a field constructor treats `false` as a
`FieldValidationError` (the user wrote it; the remedy is one edit), while the schema readers treat it
as drop-and-warn. A reader that threw would abort an entire `convert_schema_to_models` run over one
column — the #472 failure this codebase spent an issue removing.
"""
function is_valid_db_default_sql(sql::AbstractString)::Bool
  s = strip(sql)
  isempty(s) && return false
  return _sql_text_scan(s, false) && _sql_text_scan(s, true)
end

# PostgreSQL's identifier characters (`_pg_ident_char` in `src/migrations/runner.jl`, restated here
# because this file is layer 1): an `E` or a `$` right after one belongs to that identifier, so it
# opens no escape string and no dollar quote.
_sql_ident_start(c::Char) = isletter(c) || c == '_' || c > '\x7f'
_sql_ident_char(c::Char) = _sql_ident_start(c) || isdigit(c) || c == '$'

# Whether the `$` at `s[i]` opens a dollar quote (`$$`, `$tag$`) — not a positional parameter (`$1`).
# The caller has already ruled out a `$` inside an identifier (`a$b`). The shape of `_pg_dollar_tag`.
function _sql_opens_dollar_quote(s::AbstractString, i::Int)::Bool
  j = nextind(s, i)
  j <= lastindex(s) || return false
  s[j] == '$' && return true
  _sql_ident_start(s[j]) || return false
  while j <= lastindex(s) && _sql_ident_char(s[j]) && s[j] != '$'
    j = nextind(s, j)
  end
  return j <= lastindex(s) && s[j] == '$'
end

# One reading of `is_valid_db_default_sql`'s text — see its docstring. `sqlite_brackets` selects
# SQLite's: `[` opens an identifier that ends at the first `]`, with no escape. Otherwise `[`/`]`
# are PostgreSQL's array brackets and count toward `depth` beside the parentheses.
function _sql_text_scan(s::AbstractString, sqlite_brackets::Bool)::Bool
  depth = 0
  in_single = false          # '…'  — a SQL string literal; '' escapes a quote
  in_double = false          # "…"  — a quoted identifier on both engines
  in_bracket = false         # […]  — a quoted identifier, on SQLite's reading only
  prev = nothing             # the previous character outside a quote, for the `E'` rule
  # Whether the run of identifier characters `s[i]` continues began with an identifier START — so a `$`
  # here is part of an identifier (`a$b`). A run that began with a digit or a `$` is a number or a
  # parameter (`1`, `$1`), after which PostgreSQL reads `$$` as a dollar quote (found in review).
  word = false
  last_i = lastindex(s)
  i = firstindex(s)
  while i <= last_i
    ch = s[i]
    if in_single
      if ch == '\\'
        # A backslash right before a quote is an escape under `standard_conforming_strings = off`
        # (and in an `E'…'`), and a literal backslash followed by the closing quote under `on`: the
        # two readings end the literal in different places (#934).
        j = nextind(s, i)
        j <= last_i && s[j] == '\'' && return false
      elseif ch == '\''
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
    elseif in_bracket
      ch == ']' && (in_bracket = false)
    elseif ch == '\''
      # `E'…'` is PostgreSQL's escape string: a backslash escapes the quote, which this walk cannot
      # follow — so the prefix is refused rather than lexed (#934).
      prev !== nothing && (prev == 'E' || prev == 'e') && return false
      in_single = true
    elseif ch == '"'
      in_double = true
    elseif ch == '`'
      return false          # SQLite's (and MySQL's) identifier quote; PostgreSQL has none (#934)
    elseif ch == '$' && !word && _sql_opens_dollar_quote(s, i)
      return false          # a dollar-quoted body ends wherever its tag says, not at a `'` (#934)
    elseif ch == ';'
      return false
    elseif ch == ',' && depth == 0
      return false          # injects a whole extra column definition — see the docstring
    elseif ch == '[' && sqlite_brackets
      in_bracket = true
    elseif ch == '(' || ch == '['
      depth += 1
    elseif ch == ')' || ch == ']'
      depth -= 1
      depth < 0 && return false
    elseif ch == '-' || ch == '/'
      j = nextind(s, i)
      j <= last_i && s[j] == (ch == '-' ? '-' : '*') && return false
    end
    word = (in_single || in_double || in_bracket || !_sql_ident_char(ch)) ? false :
           (prev !== nothing && _sql_ident_char(prev)) ? word : _sql_ident_start(ch)
    # The `E` of `E'` must start a token: `xE'…'` is the identifier `xE` and a standard literal.
    prev = (in_single || in_double || in_bracket) ? nothing :
           (ch == 'E' || ch == 'e') && prev !== nothing && _sql_ident_char(prev) ? 'x' : ch
    i = nextind(s, i)
  end
  return !in_single && !in_double && !in_bracket && depth == 0
end

# ── Reading a column DEFAULT back (#475, moved here in #1033) ────────────────────────────────────
#
# The two cleaners that reduce a catalog's DEFAULT text — `pg_get_expr`'s on PostgreSQL, `PRAGMA
# table_info`'s on SQLite — to a literal value or an `_ExpressionDefault` tag, and the helpers they
# share. They lived in `migrations/introspection.jl` beside their only caller until #1033, which gave
# them a second one: `Models._db_default_kwarg` refuses a declared `db_default` that the catalog would
# read back as a LITERAL, because the live side then compiles to a `LiteralDefault`, the declared side
# to an `ExpressionDefault`, and `_defaults_equal` keeps those apart on purpose (#475) — so the column
# never converged with its own declaration. The judgement is only sound if it is THE READER'S, applied
# to the declared text: a second classifier would drift from this one, and drift here is the churn.
# The field constructors are include step 107 and `Migrations` is step 226, so the reader moved down —
# the journey `_wrapped_in_parens` made in #496. Plain string logic; neither backend is in it.

# A column DEFAULT that is a SQL EXPRESSION rather than a literal value, carried out of the two
# cleaners as its own type so the reader arms can route on it (#475).
#
# WHY A TYPE, AND NOT A CLASSIFIER OVER THE CLEANED STRING. Both cleaners UNQUOTE a literal, and
# after that step an expression and a literal are the same bytes: `_pg_clean_default` turns BOTH
# `'now()'::text` and `now()` into `"now()"`, and `_normalize_sqlite_default` turns both
# `'CURRENT_TIMESTAMP'` and `CURRENT_TIMESTAMP` into `"CURRENT_TIMESTAMP"`. A classifier applied to
# the RESULT is therefore forced to be wrong in one direction or the other — keep a real expression,
# or drop the string a user deliberately quoted. The quoting is visible only INSIDE the cleaner, so
# that is where the question has to be answered.
#
# Returned INSTEAD of the value rather than tagging every value with a `(value, kind)` pair: a
# literal then flows through byte-for-byte unchanged, and no call site that handles one needs to
# know this type exists.
struct _ExpressionDefault
  sql::String
end

# `string` so both `@warn ... default = string(default_val)` sites keep printing the expression text
# with no change. `==`/`hash` so tests can compare tags directly. `==` is deliberately NOT defined
# against `AbstractString`: a tag must never silently satisfy an assertion written for the old
# string-returning behaviour.
Base.string(d::_ExpressionDefault) = d.sql
Base.:(==)(a::_ExpressionDefault, b::_ExpressionDefault) = a.sql == b.sql
Base.hash(d::_ExpressionDefault, h::UInt) = hash(d.sql, hash(:_ExpressionDefault, h))
Base.show(io::IO, d::_ExpressionDefault) = print(io, "_ExpressionDefault(", repr(d.sql), ")")

# True when `s` is ONE `q`-quoted literal — every interior quote doubled. The `r"^'(.+)'$"` this
# replaces also matched `'a' || 'b'`, which is a concatenation of two.
#
# Shared by BOTH engines and therefore kept with the other cross-backend helpers (#475) — the same
# journey `_wrapped_in_parens` made in #472, and the same defect at the end of it. SQLite tested
# `startswith(s, "'") && endswith(s, "'")`, which is true of `'a' || 'b'`, so a CONCATENATION was
# read as one literal and unquoted to the mangled `a' || 'b`. A textual column then KEPT that value
# and `Model_to_str` wrote it into the generated models file, where it re-renders as
# `DEFAULT 'a'' || ''b'`. PostgreSQL has used this predicate since #455 and never had the bug, so
# the two engines disagreed on exactly the shape #475 exists to make them agree on.
#
# UTF-8 safe: it walks with `nextind` rather than indexing bytes.
function _quoted_literal(s::AbstractString, q::Char)::Bool
  (ncodeunits(s) >= 2 && first(s) == q && last(s) == q) || return false
  last_i = lastindex(s)
  i = nextind(s, firstindex(s))
  while i < last_i
    if s[i] == q
      j = nextind(s, i)
      (j <= last_i && s[j] == q) || return false
      i = nextind(s, j); continue
    end
    i = nextind(s, i)
  end
  return true
end

# The content of a `q`-quoted literal, with doubled interior quotes collapsed.
#
# `nextind`/`prevind`, never `s[2:end-1]` (#475). Those are BYTE offsets, so `end-1` lands on a
# UTF-8 continuation byte whenever the character before the closing quote is multibyte — and
# `DEFAULT 'São José'` then raised `StringIndexError` from inside the SQLite cleaner, aborting the
# WHOLE `convert_schema_to_models` read over one ordinary column. That is precisely the failure
# mode #472 exists to eliminate, and the PostgreSQL cleaner had always used the safe form.
function _unquote_literal(s::AbstractString, q::Char)::String
  inner = ncodeunits(s) == 2 ? "" : s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]
  return replace(inner, string(q, q) => string(q))
end

const _SQL_NUMERIC_LITERAL = r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"

# Is `s` one unquoted SQL literal — a number, or a boolean keyword?
#
# Deliberately narrow, and sound ONLY because of where it is called: both cleaners run it on their
# final fallthrough, after every quoted form, bare `NULL`, the SQLite `X'…'` blob literal and the
# SQLite boolean keywords have already been claimed by a branch above. The only inputs it ever
# judges are therefore BARE tokens, where the whole literal vocabulary is a number or `TRUE`/`FALSE`.
# It is not a general SQL-literal test and must not be reused as one.
#
# Its existence is the reason the fix is not "drop the fallthrough": that branch carries unquoted
# LITERALS too. `DEFAULT 5` reaches `IntegerField` as the *string* `"5"` and only becomes `5`
# because the converter is `format2int64`; `DEFAULT true` reaches `BooleanField` as `"true"` and is
# parsed there. Dropping the branch wholesale would take both with it.
#
# `0x1F`, `1_000` and other non-decimal or separated spellings are classified as EXPRESSIONS.
# `parse(Int64, "0x1F")` happens to succeed in Julia, but the same token on a `FloatField` or
# `DecimalField` column does not, and reject-rather-than-reinterpret is the rule at every other
# introspection boundary (#296's blob literals, #455's identifiers). A dropped default is reported
# and recoverable; silently importing 31 as a default the user never wrote is neither.
function _is_sql_literal_token(s::AbstractString)::Bool
  t = strip(s)
  lowercase(t) in ("true", "false") && return true
  return occursin(_SQL_NUMERIC_LITERAL, t)
end

function _strip_sqlite_default_wrapper(default_val)
  default_val === nothing && return nothing
  ismissing(default_val) && return nothing

  stripped = strip(String(default_val))
  # `_wrapped_in_parens` rather than `startswith("(") && endswith(")")` (#472). The textual test
  # is true for `(a) + (b)`, where the opening paren does NOT close on the final character, so it
  # unwrapped to `a) + (b` — two unbalanced fragments. That was survivable only while such a value
  # went on to throw: SQLite defaults now degrade to a `String` and a text column KEEPS the value,
  # so a mangled one would be written into the generated model as a literal default and re-rendered
  # as `DEFAULT 'a) + (b'`. The PostgreSQL cleaner hit this exact bug and fixed it with this
  # predicate; the SQLite twin was left behind.
  while _wrapped_in_parens(stripped)
    inner = strip(stripped[nextind(stripped, firstindex(stripped)):prevind(stripped, lastindex(stripped))])
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
    bytes = _sqlite_blob_literal_bytes(stripped)
    bytes !== nothing && return bytes
    # #475: an UNQUOTED token that is not blob syntax is an EXPRESSION (`(randomblob(16))`, which
    # `_strip_sqlite_default_wrapper` has already unwrapped), and gets the same drop-and-warn as
    # every other column type — otherwise the "uniform on every column type" rule this issue
    # establishes would have a silent hole on exactly the engine that cannot express it either.
    #
    # A LITERAL that simply is not valid blob syntax still degrades to "no default" with no warning:
    # a quoted string, and equally an `X'…'`-shaped token that is malformed (odd-length or non-hex,
    # which `_sqlite_blob_literal_bytes` rejects). Both are literals the field type cannot take,
    # which is #296's axis and contract, not #475's — reporting `X'010'` as "a SQL expression" would
    # be a false diagnosis in a warning the user cannot check.
    #
    # The `X'…'` test is ANCHORED and forbids an interior quote, matching
    # `_sqlite_blob_literal_bytes`'s own regex. `startswith(s, "X'") && endswith(s, "'")` is the
    # naive shape this whole issue exists to remove: it is equally true of
    # `X'0102' || X'03'` — a CONCATENATION, and a genuine expression — which it would then swallow
    # in silence. Found in review, after that exact bug was introduced here by the first draft.
    (_quoted_literal(stripped, '\'') || _quoted_literal(stripped, '"')) && return nothing
    occursin(r"^[Xx]'[^']*'$", stripped) && return nothing
    return _is_sql_literal_token(stripped) ? nothing : _ExpressionDefault(String(stripped))
  end

  if type_sym == :BooleanField
    lowered = lowercase(replace(stripped, "'" => "", "\"" => ""))
    lowered in ["1", "true", "t"] && return true
    lowered in ["0", "false", "f"] && return false
  end

  # BALANCED, not `startswith`/`endswith` (#475). The textual test is true for `'a' || 'b'` — a
  # CONCATENATION of two literals, whose first and last characters merely happen to be quotes — and
  # unquoting it produced the mangled `a' || 'b`, which a textual column then KEPT. PostgreSQL has
  # used the balanced predicate since #455; this is the same fix on the other engine.
  if _quoted_literal(stripped, '\'')
    return _unquote_literal(stripped, '\'')
  elseif _quoted_literal(stripped, '"')
    return _unquote_literal(stripped, '"')
  end

  # `String`, not the `SubString` `strip` produced (#472). `TextField`/`EmailField`/`ImageField`/
  # `FileField` validate against `Union{String, Nothing}` and their converter is `parse(String, x)`,
  # which has NO method for any input — so a `SubString` reached the throw path and an UNQUOTED
  # default aborted the read even on a text column. The two branches above already widen to `String`
  # (via `replace`), which is why every quoted-literal fixture passed and this went unnoticed.
  # Widening here makes the engines agree: `_pg_clean_default` reduces a quoted literal the same way.
  s = String(stripped)

  # …and whatever is left UNQUOTED is either a bare literal or a SQL EXPRESSION (#475). Until this,
  # the whole fallthrough returned a String, so whether an expression survived was decided by the
  # FIELD TYPE rather than by the schema: `TextField` validates against `Union{String, Nothing}` and
  # accepts anything, so `TEXT DEFAULT CURRENT_TIMESTAMP` was kept as a 17-character literal and
  # `Model_to_str` wrote it into the generated models file — where re-applying it renders
  # `DEFAULT 'CURRENT_TIMESTAMP'` and stores that text in every new row. The SAME expression on a
  # DATETIME column was dropped with a warning. Tagging here is what makes the two agree.
  return _is_sql_literal_token(s) ? s : _ExpressionDefault(s)
end

_pg_single_quoted_literal(s::AbstractString)::Bool = _quoted_literal(s, '\'')

# A cast at the END of an expression: `::text`, `::character varying`, `::numeric(10,2)`,
# `::integer[]`, `::"MyEnum"`, `::public.my_enum`. ANCHORED on purpose — the global
# `r"::[a-zA-Z_]+"` this replaces turned `'{1,2}'::integer[]` into `'{1,2}'[]`, silently losing an
# array default.
const _PG_TRAILING_CAST = r"::(?:\"[^\"]*\"|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?(?:\s+[A-Za-z_][A-Za-z0-9_]*)*)(?:\s*\(\s*\d+(?:\s*,\s*\d+)?\s*\))?(?:\s*\[\s*\])*\s*$"

function _pg_strip_trailing_casts(s::AbstractString)::String
  out = String(strip(s))
  for _ in 1:8   # `((x)::text)::varchar` — bounded so a pathological string cannot spin
    stripped = String(strip(replace(out, _PG_TRAILING_CAST => "")))
    stripped == out && break
    out = stripped
  end
  return out
end

# Undo `pg_get_expr`'s rendering of a column DEFAULT.
#
# Takes the WHOLE expression. The regex this replaces was WHITESPACE-TERMINATED
# (`r"DEFAULT\s+((?:\([^)]+\)|[^:\s]+)(?:::[a-zA-Z_]+)?)"`), so any default containing a space was
# truncated before the unwrapping below ever saw it — `DEFAULT 'Ferrari, Scuderia'::text` cleaned to
# `'Ferrari`. That is a SEPARATE defect from the aggregate tear #455 is about, and it survives the
# JSON move on its own: fixing where the string comes from does not fix a parser that stops at the
# first space.
#
# An expression this cannot reduce to a literal (`concat('a', 'b')`, `nextval('s'::regclass)`,
# `now()`, `now() - '1 day'::interval`) is returned WHOLE, which is what the field constructors then
# judge. "Whole" is load-bearing and is the reason the inner re-strip below is conditional — see
# there.
#
# A bare `NULL` (`DEFAULT NULL::character varying`, which pg_dump emits routinely) is "no default",
# not the four-character string `"NULL"`. That is the answer `_normalize_sqlite_default` already
# gives for the same input, and the engines have to agree.
const _PG_NEGATED = r"^-\s*(.+)$"s

function _pg_clean_default(expr)::Union{String, Nothing, _ExpressionDefault}
  expr === nothing && return nothing
  s = _pg_strip_trailing_casts(String(expr))
  isempty(s) && return nothing
  # `(0)::numeric` → strip the cast → `(0)` → unwrap → `0`.
  #
  # The inner value may carry its OWN cast (`('x'::text)`), but re-stripping unconditionally is
  # wrong: `pg_get_expr` parenthesizes every non-trivial expression, so the inner text is usually a
  # COMPOUND expression whose trailing cast belongs to its last OPERAND. Stripping it there turns
  # `('x'::text || 'y'::text)` into `'x'::text || 'y'` — a mangled expression rather than an
  # unrecognized one. So the re-stripped form is kept only when it actually reduced to a literal.
  if _wrapped_in_parens(s)
    inner = s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]
    stripped = _pg_strip_trailing_casts(inner)
    s = _pg_single_quoted_literal(stripped) ? stripped : String(strip(inner))
  end
  if _pg_single_quoted_literal(s)
    # Shared with the SQLite cleaner (#475). Both engines unquote identically, and keeping two
    # copies of the logic is how they drifted apart twice already — once on the balanced-quote
    # test, once on byte-vs-character slicing.
    return _unquote_literal(s, '\'')
  end
  uppercase(s) == "NULL" && return nothing
  # A minus applied to a number is a constant too (#1033). PostgreSQL folds a bare `- 1` into
  # `'-1'::integer` itself, but stores `-1::integer` (which parses as `-(1::integer)`) as the operator
  # and prints it `(- 1)`; measured on PostgreSQL 16. Both are the value -1, and reading the second
  # as an expression made `inspectdb` write a `db_default` the constructor refuses. A unary `+` is
  # never folded (`+1` is stored as `(+ 1)`), so it stays an expression on both sides.
  # The operand's own casts and quotes are the constant's spelling, not an operation on it:
  # `(- (1)::bigint)` and `(- '1'::integer)` are -1 too, and stripping them is also what keeps the
  # reader idempotent on its own output (`- (1)::bigint` re-read would otherwise fold where the
  # parenthesised form did not; found in delta review).
  # Matched on the canonical form, so a negation that kept its own parentheses through the single
  # unwrap above (`((- 1))::bigint` → `(- 1)`) folds too and the reader stays idempotent on it.
  m = match(_PG_NEGATED, canonical_db_default(s))
  if m !== nothing
    number = canonical_db_default(_pg_strip_trailing_casts(m.captures[1]))
    _pg_single_quoted_literal(number) && (number = _unquote_literal(number, '\''))
    (occursin(_SQL_NUMERIC_LITERAL, number) && !startswith(number, ('+', '-'))) && return "-" * number
  end
  # Whatever did not reduce to a literal above is a SQL EXPRESSION — `now()`, `nextval('s')`,
  # `'x'::text || 'y'::text`. Tagged rather than returned as a bare String so the reader arms route
  # on the SCHEMA rather than on whether the target field type happens to refuse the value (#475).
  # See `_ExpressionDefault` for why this cannot be decided from the returned value afterwards.
  return _is_sql_literal_token(s) ? s : _ExpressionDefault(s)
end

# The spellings of a constant that PostgreSQL's deparser rewrites into a form `_pg_clean_default`
# reads as a literal. Measured on PostgreSQL 16 (#1033), declared → `pg_get_expr`:
#
#   CAST(0 AS integer)               → 0                       CAST((0) AS integer)  → 0
#   CAST(CAST(0 AS int) AS bigint)   → (0)::bigint
#   DATE '2024-01-01'                → '2024-01-01'::date      pg_catalog.date '…'   → '…'::date
#   varchar(10) 'x'                  → 'x'::character varying(10)
#   double precision '1.5'           → '1.5'::double precision "char" 'x'           → 'x'::"char"
#   INTERVAL '1' DAY                 → 'P1D'::interval
#
# Applied to the DECLARED text only, because the catalog never hands the reader any of these
# spellings — so this is the deparser's rewrite, not a second classifier, and anything it does not
# recognise is returned unchanged for `_pg_clean_default` to judge. SQLite needs no twin: `PRAGMA
# table_info` echoes the declared text, so `CAST(0 AS integer)` reads back as that expression and
# converges as one.
#
# The type name is PostgreSQL's own grammar for a typed literal (`ConstTypename`) — one name, possibly
# schema-qualified or quoted, with a type modifier, or one of the fixed multi-word names — and NOT
# "any words before a quote". That looser shape read `CURRENT_TIMESTAMP AT TIME ZONE 'UTC'` as a
# typed literal of type `CURRENT_TIMESTAMP AT TIME ZONE` and refused an expression; found in review.
# `NOT 'f'` is the one single-word operator with the same shape, hence its exclusion.
const _PG_TYPMOD = raw"(?:\s*\(\s*\d+(?:\s*,\s*\d+)?\s*\))?"
const _PG_MULTIWORD_TYPE = raw"double\s+precision|(?:character|char|bit)\s+varying|" *
                           raw"national\s+(?:character|char)(?:\s+varying)?|" *
                           raw"(?:time|timestamp)(?:\s*\(\s*\d+\s*\))?\s+with(?:out)?\s+time\s+zone"
const _PG_ONEWORD_TYPE = raw"(?:[A-Za-z_][A-Za-z0-9_]*\.)?(?:\"(?:[^\"]|\"\")+\"|[A-Za-z_][A-Za-z0-9_]*)"
const _PG_INTERVAL_FIELD = raw"(?:year|month|day|hour|minute|second)(?:\s*\(\s*\d+\s*\))?"
# The literal is matched as `'.*'` and then checked with `_pg_single_quoted_literal`, rather than with
# a repeated `(?:[^']|'')*` group, which costs PCRE's JIT stack per character.
const _PG_TYPED_LITERAL = Regex(
  "^((?:$_PG_MULTIWORD_TYPE)$_PG_TYPMOD|$_PG_ONEWORD_TYPE$_PG_TYPMOD)\\s*('.*')" *
  "(\\s+$_PG_INTERVAL_FIELD(?:\\s+to\\s+$_PG_INTERVAL_FIELD)?)?\$", "is")
const _PG_CAST_CALL = r"^CAST\s*\((.*)\)$"is
# GREEDY operand, so the split is at the LAST ` AS `: an ` AS ` inside a quoted operand is data, and
# a nested `CAST(… AS …)` stays whole for the recursion below.
const _PG_CAST_BODY = r"^\s*(.+)\s+AS\s+(.+?)\s*$"is

function _pg_deparse_literal_forms(sql::AbstractString, depth::Int = 0)::String
  s = String(strip(sql))
  # Bounded: a CAST nested deeper than any real default is left for the reader to judge, rather than
  # recursing until the stack overflows (found in review, at ~10,000 levels).
  depth > 8 && return s
  m = match(_PG_CAST_CALL, s)
  # The parenthesis after `CAST` must close on the final character: `CAST(0 AS int) + CAST(1 AS int)`
  # matches the regex too, and is a sum.
  if m !== nothing && _wrapped_in_parens(String(strip(s[nextind(s, firstindex(s), 4):end])))
    body = match(_PG_CAST_BODY, m.captures[1])
    body === nothing && return s
    # The operand is judged by the same rewrite, so `(0)` and a nested `CAST` reduce too.
    operand = _pg_deparse_literal_forms(canonical_db_default(body.captures[1]), depth + 1)
    _pg_clean_default(operand) isa _ExpressionDefault && return s
    return string(operand, "::", body.captures[2])
  end
  m = match(_PG_TYPED_LITERAL, s)
  m === nothing && return s
  type_name = m.captures[1]
  uppercase(type_name) == "NOT" && return s
  _pg_single_quoted_literal(m.captures[2]) || return s
  m.captures[3] === nothing && return string(m.captures[2], "::", type_name)
  # A field qualifier (`DAY`, `YEAR TO MONTH`) belongs to `INTERVAL` alone, and it is part of the
  # value: `INTERVAL '1' DAY` is one day. It is kept inside the literal (`'1 DAY'::interval`) so the
  # value the refusal quotes back is not the bare `1`.
  lowercase(type_name) == "interval" || return s
  return string(chop(m.captures[2]), " ", strip(m.captures[3]), "'::", type_name)
end

"""
    _db_default_read_back(sql, engine::Symbol, field_type) -> Union{_ExpressionDefault, Any}

What the schema reader on `engine` (`:postgres` or `:sqlite`) makes of the column default a declared
`db_default` renders: an `_ExpressionDefault` when it stays an expression, otherwise the LITERAL the
reader reduces it to — a `String`, a `Bool`, bytes, or `nothing` when it reads back as no default
(#1033).

`Models._db_default_kwarg` refuses everything but the first. A literal read back compiles to a
`LiteralDefault` on the live side while the declaration compiles to an `ExpressionDefault`, and
`_defaults_equal` keeps those apart on purpose (#475), so such a column replanned `SET DEFAULT` (and,
on SQLite, a whole table rebuild) on every `makemigrations`. It is the reader's own cleaner applied to
the declared text, so the two cannot drift apart. `field_type` is the public field name; it selects
the readers' bytes and boolean arms exactly as `Migrations._clean_default` does from the column's
canonical type.
"""
function _db_default_read_back(sql::AbstractString, engine::Symbol, field_type::AbstractString)
  text = canonical_db_default(sql)
  if engine === :postgres
    cleaned = _pg_clean_default(_pg_deparse_literal_forms(text))
    # `_clean_default`'s bytea step: the hex text decoded, or "no default" when it is not hex.
    (cleaned isa AbstractString && field_type == "BinaryField") && return _pg_bytea_literal_bytes(cleaned)
    return cleaned
  end
  type_sym = field_type == "BinaryField" ? :BinaryField : field_type == "BooleanField" ? :BooleanField : :TextField
  return _normalize_sqlite_default(text, type_sym)
end

# ── Table-level CHECK constraints (#742) ─────────────────────────────────────────────────────────
#
# A declared `Models.CheckConstraint` is identified by its NAME, and whether the live constraint
# still says what the declaration says is answered by a MARKER PormG stores beside every CHECK it
# creates: `pormg:check:<hash>`, the hash of the declared condition. PostgreSQL cannot be asked
# directly — `pg_get_constraintdef` re-parenthesises and re-casts the condition (`grid >= 0 AND grid
# <= 40` comes back `((grid >= 0) AND (grid <= 40))`), so a text compare would plan a replace on
# every run. The marker lives in `COMMENT ON CONSTRAINT` there and in an SQL comment inside the
# CHECK's parentheses on SQLite, which keeps its `CREATE TABLE` text verbatim (comments included,
# through `RENAME TO` and `RENAME COLUMN` alike). It is also the ownership record: a live CHECK that
# carries one was created by PormG from a declaration, so one no declaration names any more is
# PormG's to drop, while a hand-written CHECK — no marker — is never planned away.
#
# Nouns only, and here rather than beside the planner because `Dialect` (include step 10) renders
# the marker and `Migrations` (step 11) compares it — the #239 shape.
import SHA

"""
    CHECK_MARKER_PREFIX

The text every ownership marker starts with: `pormg:check:` followed by 16 lower-case hex digits
(see [`check_marker`](@ref)).
"""
const CHECK_MARKER_PREFIX = "pormg:check:"

"""
    canonical_check_condition(sql) -> String

The comparison form of a CHECK condition: leading and trailing whitespace trimmed and balanced outer
parentheses removed — nothing else. Interior whitespace is left alone because it may sit inside a
string literal, and case because it may sit inside a quoted identifier. Idempotent, like
[`canonical_db_default`](@ref), whose paren loop it shares.
"""
function canonical_check_condition(sql::AbstractString)::String
  s = String(strip(sql))
  while _wrapped_in_parens(s)
    inner = String(strip(s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]))
    isempty(inner) && break
    s = inner
  end
  return s
end

"""
    check_condition_hash(sql) -> String

The first 16 hex digits of the SHA-256 of [`canonical_check_condition`](@ref)`(sql)` — stable across
Julia versions and processes, unlike `Base.hash`, because it is persisted in the database.
"""
check_condition_hash(sql::AbstractString)::String = bytes2hex(SHA.sha256(canonical_check_condition(sql)))[1:16]

"""
    check_marker(sql) -> String

The ownership marker PormG stores beside a CHECK it creates from a declared condition:
`pormg:check:<`[`check_condition_hash`](@ref)`>`.
"""
check_marker(sql::AbstractString)::String = CHECK_MARKER_PREFIX * check_condition_hash(sql)

# The marker as it may be READ back: anywhere in a PostgreSQL comment (a user may append to it), and
# the whole of the trailing SQL comment on SQLite. One pattern, so the two readers cannot disagree
# about what a marker looks like. Bounded on both sides like `INDEX_MARKER_RE` below (#934): an
# unbounded pattern read `xpormg:check:<hash>` and a 17-digit hash as owned, and the marker is the
# only thing between a hand-made CHECK and a planned DROP. Same PostgreSQL/PCRE subset, because
# `_PG_UNMARKED_CHECK` interpolates it into SQL.
const CHECK_MARKER_RE = Regex("(?<![0-9A-Za-z_:])" * CHECK_MARKER_PREFIX * "[0-9a-f]{16}(?![0-9A-Za-z_:])")

# ── Expression column defaults (#1037) ───────────────────────────────────────────────────────────
#
# The third catalog object whose text PostgreSQL's deparser rewrites. A `db_default` expression is
# stored as a parse tree and `pg_get_expr` prints it back with casts the declaration did not have —
# `lower('OPEN')` reads back `lower('OPEN'::text)`, `to_tsvector('simple', '')` reads back
# `to_tsvector('simple'::regconfig, ''::text)` — so the text compare planned `SET DEFAULT` on every
# run. Emulating the deparser in Julia means re-implementing PostgreSQL's type resolution for
# function arguments; the CHECK (#742) and index (#29/#934) markers already answer the same question
# without one, by recording what PormG applied instead of comparing what the catalog prints.
#
# A default needs TWO hashes where a CHECK needs one. A CHECK edited by hand is dropped and recreated
# and loses its comment; `ALTER COLUMN … SET DEFAULT` by hand KEEPS the column comment, so a marker
# holding only the declared hash would read a hand change as converged. The second hash is of the
# deparsed text PostgreSQL printed right after PormG applied the default — computed by the server,
# in the same plan entry (`Dialect.stamp_db_default`) — and it is honoured only while the live
# default still prints to it. PostgreSQL only: SQLite keeps the declared text verbatim, so its text
# compare already converges.

"""
    DB_DEFAULT_MARKER_PREFIX

The text the ownership marker of an expression column default starts with: `pormg:default:`, then
the 16-hex-digit hash of the declared expression ([`db_default_hash`](@ref)), a `:`, and the
16-hex-digit hash of the text `pg_get_expr` printed right after PormG applied it
([`live_default_hash`](@ref)). It lives in `COMMENT ON COLUMN`, anywhere in the comment.
"""
const DB_DEFAULT_MARKER_PREFIX = "pormg:default:"

"""
    db_default_hash(sql) -> String

The first 16 hex digits of the SHA-256 of [`canonical_db_default`](@ref)`(sql)` — the declared half
of the marker. Canonicalised first, so the spellings the declared side already calls equal hash
equal.
"""
db_default_hash(sql::AbstractString)::String = bytes2hex(SHA.sha256(canonical_db_default(sql)))[1:16]

"""
    live_default_hash(raw) -> String

The first 16 hex digits of the SHA-256 of `raw`, the text `pg_get_expr` prints — **not**
canonicalised, because the server computes the same digest in SQL when it stamps the marker
(`left(encode(sha256(convert_to(…, 'UTF8')), 'hex'), 16)`), and SQL has no `canonical_db_default`.
"""
live_default_hash(raw::AbstractString)::String = bytes2hex(SHA.sha256(String(raw)))[1:16]

# Bounded on both sides like `CHECK_MARKER_RE`, and in the same PostgreSQL/PCRE subset, because
# `Dialect.stamp_db_default` interpolates it into SQL to strip a previous marker from the comment.
const DB_DEFAULT_MARKER_RE = Regex("(?<![0-9A-Za-z_:])" * DB_DEFAULT_MARKER_PREFIX *
                                   "([0-9a-f]{16}):([0-9a-f]{16})(?![0-9A-Za-z_:])")

"""
    db_default_owner(comment, raw_default) -> Union{String, Nothing}

The declared hash a live column's marker vouches for, or `nothing` when it vouches for none: no
comment, no marker in it, no default, or a default that no longer prints to the text the marker was
stamped against (changed by hand, or re-printed differently by a newer server). `nothing` is the
safe answer every time — the diff then compares the text, as it did before #1037, and plans one
`SET DEFAULT` that re-stamps the marker.
"""
function db_default_owner(comment, raw_default)::Union{String, Nothing}
  comment isa AbstractString && raw_default isa AbstractString || return nothing
  m = match(DB_DEFAULT_MARKER_RE, comment)
  m === nothing && return nothing
  return m.captures[2] == live_default_hash(raw_default) ? String(m.captures[1]) : nothing
end

# ── Index access methods, operator classes and ownership (#29) ───────────────────────────────────
#
# A plain `Models.Index` — b-tree, ascending, default operator classes — is owned the way every
# composite is (#161): the models file is the schema, so an undeclared one is dropped. An ADVANCED
# one (another access method, a `DESC` member or an explicit operator class) is owned the way a
# table CHECK is (#742): PormG stores `pormg:index` beside every one it creates — `COMMENT ON INDEX`
# on PostgreSQL, an SQL comment inside the column list on SQLite — and only an index carrying it is
# ever planned away. A hand-made GIN index, which `docs/src/migrations/advanced.md` recommends
# writing by hand, is read and can be adopted, but is never dropped for being undeclared.
#
# Nouns only, here for the #239 reason the CHECK marker is: `Models` validates against them,
# `Dialect` renders them and `Migrations` reads them back.

"""
    INDEX_METHODS

The PostgreSQL index access methods a `Models.Index` may declare through `method=`: `"btree"` (the
default, and the only one SQLite has), `"hash"`, `"gist"`, `"spgist"`, `"gin"` and `"brin"`. An
extension's method (`bloom`, `rum`) is not one of them, so an index using it is never read.
"""
const INDEX_METHODS = ("btree", "hash", "gist", "spgist", "gin", "brin")

"""
    INDEX_OPCLASS_RE

What an operator class named in `Models.Index(opclasses = …)` must look like: a lower-case,
unqualified SQL identifier. It is rendered unquoted — `jsonb_path_ops` is an operator class, while
`"jsonb_path_ops"` would also be one but read back unquoted — so this pattern is both the injection
guard and the reason a declared name compares equal to the catalog's `opcname`.
"""
const INDEX_OPCLASS_RE = r"^[a-z_][a-z0-9_]*$"

"""
    INDEX_MARKER

The ownership marker PormG stores beside every advanced index it creates (see [`INDEX_METHODS`](@ref)).
An index whose definition holds SQL text — `expressions =` or `condition =` — carries the longer
`pormg:index:<16 hex>` instead ([`index_text_marker`](@ref)); [`INDEX_MARKER_RE`](@ref) reads both
forms as owned.
"""
const INDEX_MARKER = "pormg:index"

"""
    canonical_index_text(expressions, condition) -> String

The comparison form of the SQL text an expression or partial index declares: every expression, then
the condition, each through [`canonical_check_condition`](@ref) and each length-prefixed — `e<n>:` for
an expression, `w<n>:` for the condition, `n` its byte count — so no two different definitions can
encode alike (`("a, b",)` against `("a", "b")`, or a condition against a last expression).

Only the TEXT is encoded. The columns, their direction, the method and the operator classes of an
`Index(fields = …, condition = …)` are read back from the catalog exactly and compared as a shape, so
renaming a plain member column does not make the marker stale (#29).
"""
function canonical_index_text(expressions::AbstractVector{<:AbstractString},
                              condition::Union{AbstractString, Nothing})::String
  io = IOBuffer()
  for e in expressions
    c = canonical_check_condition(e)
    print(io, "e", ncodeunits(c), ":", c)
  end
  if condition !== nothing
    c = canonical_check_condition(condition)
    print(io, "w", ncodeunits(c), ":", c)
  end
  return String(take!(io))
end

"""
    index_text_hash(expressions, condition) -> String

The first 16 hex digits of the SHA-256 of [`canonical_index_text`](@ref) — persisted in the database,
so stable across processes and Julia versions, as [`check_condition_hash`](@ref) is.
"""
index_text_hash(expressions::AbstractVector{<:AbstractString}, condition::Union{AbstractString, Nothing})::String =
  bytes2hex(SHA.sha256(canonical_index_text(expressions, condition)))[1:16]

"""
    index_text_marker(expressions, condition) -> String

The ownership marker of an index whose definition holds SQL text:
`pormg:index:<`[`index_text_hash`](@ref)`>`. The hash is how `makemigrations` sees a changed
expression or condition, since PostgreSQL stores a rewritten form of the text (#29).
"""
index_text_marker(expressions::AbstractVector{<:AbstractString}, condition::Union{AbstractString, Nothing})::String =
  INDEX_MARKER * ":" * index_text_hash(expressions, condition)

# The marker as it may be READ back — anywhere in a PostgreSQL comment, and the whole of the comment
# closing an SQLite column list. It is the only thing between a hand-made index and a planned DROP, so
# it is bounded on both sides: the look-behind keeps `xpormg:index` from counting, the look-ahead
# `pormg:indexes` or a longer hash. Written in the subset PostgreSQL's regex engine shares with PCRE
# (look-behind is PostgreSQL 9.6+; the floor is 11), because the readers interpolate it into SQL
# (`_PG_MARKED_INDEX` / `_PG_UNMARKED_INDEX`).
const INDEX_MARKER_RE = Regex("(?<![0-9A-Za-z_:])" * INDEX_MARKER * "(?::[0-9a-f]{16})?(?![0-9A-Za-z_:])")

# ── Full-text search document text (#31, #1021) ──────────────────────────────────────────────────
#
# The ONE writer of `to_tsvector(…)`. PostgreSQL serves a query from an expression index only when
# the query's expression is the index's, so the `@search` lookup and `SearchVector` (`Dialect`, step
# 118) and `Models.search_vector_expression` (step 107, which writes the index) all render through
# these. Two copies of the text are how an index silently stops serving its lookup — a wrong config or
# a missing cast is still a valid index and a valid query (#1021). Layer 1 for the #239 reason: `Models`
# is included before `Dialect`.
#
# The config is a LITERAL, `'english'::regconfig`, not a bound parameter — the maintainer's call on
# #31, because an index matches by text and a parameter has none. It is safe to print because it is a
# NAME, checked against an identifier pattern that admits no quote, space or semicolon, and checked
# again at every render, since a query node's `kwargs` is a mutable Dict.

const TS_CONFIG_RE = r"\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z"

"""
    ts_config_name(config) -> Union{Nothing,String}

The validated text-search config (`"english"`, `"pg_catalog.portuguese"`), or `nothing` for none.
Anything that is not a plain or schema-qualified identifier raises `InvalidValueError`.
"""
function ts_config_name(config)::Union{Nothing,String}
  config === nothing && return nothing
  (config isa AbstractString && occursin(TS_CONFIG_RE, config)) && return String(config)
  throw(InvalidValueError(
    "A text-search config is the name of one, such as \"english\" or \"pg_catalog.portuguese\": " *
    "letters, digits and underscores, optionally schema-qualified (#31).", :format))
end

# `'english'::regconfig, ` — the leading argument of every config-taking text-search function.
ts_config_prefix(config)::String = (c = ts_config_name(config); c === nothing ? "" : "'$(c)'::regconfig, ")

"""
    ts_lookup_document_sql(column, config) -> String

The left side of the `@search` lookup on a text column: `to_tsvector('cfg'::regconfig, column)`. No
`COALESCE` and no cast — a NULL document makes the predicate NULL, which drops the row exactly as
`false` would, and the bare call is what an expression index is written with.
"""
ts_lookup_document_sql(column::AbstractString, config)::String = "to_tsvector($(ts_config_prefix(config))$(column))"

"""
    ts_vector_document_sql(columns, config) -> String

`SearchVector`'s document — Django's: every operand cast to text and NULL-safe, joined by a space, so a
row whose `forename` is NULL still matches on its `surname`.
"""
function ts_vector_document_sql(columns::AbstractVector, config)::String
  document = join(("COALESCE(($(c))::text, '')" for c in columns), " || ' ' || ")
  return "to_tsvector($(ts_config_prefix(config))$(document))"
end

# The four labels `setweight` takes. Printed into the SQL, so checked against this list at every
# render as the config is — never a bound parameter, for the config's reason: an index matches by text.
const TS_WEIGHTS = ("A", "B", "C", "D")

"""
    ts_weight_name(weight) -> Union{Nothing,String}

The validated `setweight` label (`"A"` to `"D"`), or `nothing` for none. Anything else raises
`InvalidValueError`.
"""
function ts_weight_name(weight)::Union{Nothing,String}
  weight === nothing && return nothing
  (weight isa AbstractString && weight in TS_WEIGHTS) && return String(weight)
  throw(InvalidValueError("A SearchVector's weight is \"A\", \"B\", \"C\" or \"D\" (#1021).", :format))
end

# `document` labelled with `weight`: `setweight(document, 'A')`, or `document` itself for none.
ts_weighted_sql(document::AbstractString, weight)::String =
  (w = ts_weight_name(weight); w === nothing ? String(document) : "setweight($(document), '$(w)')")

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
#
# And one lenient arm between two expressions (#1037): they agree when the text does, OR when one
# side is a live default whose ownership marker vouches for the other's declaration — PormG applied
# exactly that declaration and the default has not changed since. A marker that vouches for nothing
# (`owned === nothing`) leaves the text compare as it was, which is what keeps a column PormG never
# stamped planning exactly what it planned before.
_defaults_equal(a::ColumnDefault, b::ColumnDefault)::Bool = a == b
_defaults_equal(::NoDefault, ::ExpressionDefault)::Bool = true
_defaults_equal(a::ExpressionDefault, b::ExpressionDefault)::Bool =
  a.sql == b.sql || _vouches_for(a, b) || _vouches_for(b, a)
_vouches_for(live::ExpressionDefault, declared::ExpressionDefault)::Bool =
  live.owned !== nothing && live.owned == db_default_hash(declared.sql)

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
