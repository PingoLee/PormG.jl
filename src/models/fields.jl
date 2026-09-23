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

# #420, the declaration-time arm of the reverse-accessor separator rule. The registration funnel
# `_reverse_accessor_for` in `Models.jl` sees more than this can — derived accessors, which no
# constructor can know about — but it does not run until `set_models`, so on its own it reports the
# name from a file away from where the user wrote it. This reports at the field. (Neither is the
# whole rule: `_register_many_to_many_relation!` re-checks at the write, for an accessor
# `_relation_from_many_to_many` derives without passing through the funnel.)
#
# Until #420, `related_name` was the one relation kwarg with no shape validation at all: `pk_field`,
# `source_field` and `target_field` have all gone through `format_fild_name` since #317, and
# `related_name` lands in the very same path namespace they do.
#
# `FieldValidationError` rather than the funnel's `ModelDefinitionError`, per this file's one-category
# rule above: here the caller got a field CONSTRUCTOR argument wrong. Both are `<: DefinitionError`,
# so a `catch DefinitionError` covers either route.
function _validate_related_name(related_name, field_type::AbstractString)::Union{String, Nothing}
  related_name === nothing && return nothing
  name = String(related_name)
  _illegal_accessor_name(name) &&
    throw(_fielderr("$(field_type): the 'related_name' \e[4m\e[31m$(name)\e[0m cannot contain " *
                    "\e[1m__\e[0m or \e[1m@\e[0m, nor end with \e[1m_\e[0m. " *
                    "$(_accessor_illegality_reason(name))"))
  return name
end

# ── BinaryField `default=` helpers (#296) ───────────────────────────────────
# `_binary_default_bytes` is handed to `validate_default`, which only calls it when the value is
# not already `Union{Vector{UInt8}, Nothing}` — so it normalizes the other byte-vector spellings
# (`codeunits`, reinterpreted buffers, views) into a plain `Vector{UInt8}`. It throws rather than
# returning a wrong type: before #296 `validate_default` did not re-check its converter's result,
# and that hole let a `Vector{UInt8}` through into a `Union{String,Nothing}` field, surfacing as a
# raw `MethodError` outside the error taxonomy. #631 closed the hole itself — `validate_default`
# now re-checks — so this throw is no longer the only thing standing between here and a
# `MethodError`. It stays because throwing HERE keeps the message below, which names the byte
# spellings; the generic re-check can only say that the converter returned the wrong type.
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

# ── Text `default=` policy (#612) ───────────────────────────────────────────
# One policy for every plain-text field. Before #612 the accepted spelling was decided by whichever
# converter lambda each constructor happened to carry, which split the family FIVE ways for the same
# keyword — and the two extremes were both wrong:
#
#   `parse(String, x)`  TextField, EmailField, FileField, ImageField. DEAD CODE: `parse(String, …)`
#                       has no method, so the converter could never run. Every non-`String` default
#                       was refused, blaming the value's type for what was a missing conversion.
#   `string(x)`         URLField, SlugField. The opposite failure — `string` has a method for
#                       everything, so nothing was ever refused: `URLField(default = :nope)` stored
#                       `"nope"`, and `URLField(default = CharField())` stored `"CharField()"`.
#   an inline ladder    CharField. The only one that was right, and written where nothing could
#                       reuse it.
#
# `String(x)`, not `string(x)` (#598): `string` is the IDENTITY for a `LazyString`, so the `string`
# spelling only ever produced a `String` because the field structs' `Union{String, Nothing}` slot
# re-converts on the way in. Normalizing here means the concrete type is decided at the seam rather
# than two frames later, which is the shape `_str_or_nothing` and the #603 constructors follow.
#
# `Integer` rides through as its decimal text — not new latitude, but CharField's own
# `default isa Int && (default = string(default))`, generalized off `Int64`. `Bool` is excluded
# deliberately, exactly as CharField excluded it: `true` in a text column is far likelier to be a
# mistake than an intent, and `"true"` is not a useful thing to have stored silently.
#
# Called DIRECTLY rather than handed to `validate_default`, which is why the message below is the
# one the user sees. `validate_default` wraps its converter in a bare `catch` that replaces any
# message with "Expected type: Union{Nothing, String}" — accurate before #612, misleading now that
# an `Integer` is accepted, and it is the layer whose relabelling hid the dead `parse` for this
# long. Nothing here can throw from inside a slow call, so the #472 `InterruptException` carve-out
# that `catch` exists for has nothing to guard.
#
# `UUIDField` and `JSONField` are deliberately NOT routed here: `format_uuid_sql` / `format_json_sql`
# validate the value's SHAPE, a stronger contract than this one, and both were measured already
# clean for every `AbstractString` spelling.
function _default_string(field_type::AbstractString, value)
  value === nothing && return nothing
  value isa AbstractString && return String(value)
  value isa Integer && !(value isa Bool) && return string(value)
  throw(_fielderr("$(field_type): 'default' must be a String, an Integer or nothing, got $(typeof(value))."))
end

# ── Integer width keywords (#614) ───────────────────────────────────────────
# `max_length` is declared `::Int` on four field structs (`Union{Int, Nothing}` on `sBinaryField`),
# and the guards in front of those slots were written to match the ANNOTATION rather than the
# concept: `max_length isa Int`. That is the same concrete-where-abstract naming #614 found in
# `format2int64`, one keyword over, and the refusal it produced said something that was simply not
# true — `CharField(max_length = Int32(50))` was rejected with "The max_length must be an integer".
#
# Every integer width keyword goes through here: the five `max_length` sites (#614) and, since #646,
# `DecimalField`'s `max_digits` / `decimal_places`. Those two, and `BinaryField`'s String branch,
# went through `validate_default(x, Int, …, format2int64)` instead, and that pairing is wrong on a
# 32-bit build: `format2int64` returns `Int64`, `Int === Int32` there, so #631's result re-check
# refused a valid width as "a PormG bug" — and spelling `Int64` instead lets an out-of-range width
# reach the `::Int` slot as a raw `InexactError`. Converting to `Int` HERE, inside the `try`, is what
# makes the word size irrelevant.
#
# `strings = true` is how a site keeps the numeric-String spelling it already took — `CharField`,
# `URLField`, `SlugField`, `BinaryField` and `DecimalField` opt in, `PasswordField` (integer only)
# does not. It replaced a bare `parse(Int, …)` pre-step at three sites, which let a non-numeric
# String escape as a raw `ArgumentError`. It is still `parse(Int, …)` — the parser every site used —
# with its two failures told apart by exception type: `OverflowError` gets the range message (on
# either word size), anything else "not a number". NOT `tryparse(BigInt, …)`, which looks
# equivalent and is not: GMP skips interior whitespace, so `"8 8"` parsed as a width of 88 (caught
# in review). Nothing here makes a new spelling legal at a site that did not already take it;
# `BinaryField` still maps a digit-free String to `nothing` before calling in.
#
# `Bool` is excluded exactly as `_default_string` excludes it: `Bool <: Integer`, so without the
# carve-out `max_length = true` would silently become a one-character column.
#
# Called directly rather than through `validate_default` — same reason as `_default_string`. These
# messages name the keyword and the type that arrived; `validate_default`'s bare `catch` would
# replace them with "Expected type: Int64", which is the wording this fix exists to stop producing.
function _int_kwarg(field_type::AbstractString, name::AbstractString, value; strings::Bool = false)
  # The bound is `Int`'s, which is word-size dependent, so the message names both ends rather than
  # asserting a width (#646).
  throw_out_of_range() = throw(_fielderr("$(field_type): '$(name)' is out of range, got $(value) " *
                                         "(it must fit in an Int, $(typemin(Int)) to $(typemax(Int)))."))
  if strings && value isa AbstractString
    value = try
      parse(Int, value)
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()   # #472
      # `OverflowError` is a well-formed number too wide for `Int`; anything else is not a number.
      e isa OverflowError && throw_out_of_range()
      throw(_fielderr("$(field_type): '$(name)' must be an Integer or a numeric String, got $(repr(value))."))
    end
  end
  (value isa Integer && !(value isa Bool)) ||
    throw(_fielderr("$(field_type): '$(name)' must be an Integer$(strings ? " or a numeric String" : ""), got $(typeof(value))."))
  try
    return Int(value)
  catch e
    # The `try` is not decoration: `Int(big(2)^70)` and `Int(typemax(UInt64))` raise `InexactError`,
    # which would leave the field constructor as a raw `InexactError` — outside the #231/#239
    # taxonomy. (This helper is called DIRECTLY, not through `validate_default`, so #631's
    # return-type re-check does not cover it; the sibling hole that comment describes is closed,
    # this one is still guarded here.)
    (e isa InterruptException || e isa StackOverflowError) && rethrow()   # #472
    throw_out_of_range()
  end
end

# ── Common keyword handling (#260) ──────────────────────────────────────────
# Every field constructor used to open with the same four blocks copy-pasted: an `accepted` Set, an
# unexpected-keyword `@warn` loop, a `get(kwargs, :x, default)` per keyword, and a type guard per
# keyword. Across the 27 constructors that existed then (26 now — #408 retired `AutoField`) that was
# 27 accepted-sets, 27 warn loops, 254 extractions and 187 guards — roughly a fifth of this file, and
# the reason a single wording fix had to be applied by hand in 26 places (which is how three
# different messages for the same check arose).
#
# `_common_kwargs` does all four jobs once and returns the extracted values.
#
# ## Defaults are NOT uniform — this is the part that bites
#
# Four keywords carry a different default in some constructors, so the helper takes overrides rather
# than assuming the majority:
#
#     unique       true in IDField, OneToOneField
#     db_index     true in IDField, OneToOneField, SlugField, ForeignKey
#     editable     true in CharField, PasswordField, FileField, UUIDField, URLField, SlugField, JSONField
#     primary_key  true in IDField                 (`nothing` = the constructor does not accept it)
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
# #516 is the one deliberate exception, and it is what the contract is FOR. `on_update`, `deferrable`
# and `initially_deferred` were dropped from `ForeignKey`/`OneToOneField` — and because generated
# files reload through this form, dropping them into the `@warn "Unexpected parameter"` arm below
# would have loaded an old generated file as a quietly different model (the #501 silent-drop shape).
# So the names stay recognized here for the sole purpose of REFUSING them, the way #408 retired
# `AutoField`. `_RETIRED_FK_KWARGS` is that refusal; deleting an accepted keyword without one is
# still forbidden.
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
const _COMMON_FIELD_KWARGS = (:verbose_name, :unique, :blank, :null, :db_index, :db_column, :default,
                              :db_default, :editable)

# The engines a `db_default` can be pinned to, in the order a normalised NamedTuple lists them.
# ORDER IS LOAD-BEARING: `(postgres = "x", sqlite = "y")` and `(sqlite = "y", postgres = "x")` are
# NOT `==` in Julia, so without a canonical order two identical declarations would compare unequal
# in `_model_to_str_general`'s struct diff (emitting a spurious kwarg) and in the column IR
# (planning a migration that changes nothing).
const _DB_DEFAULT_ENGINES = (:postgres, :sqlite)

"""
    DbDefault

The type of a `db_default` slot: a portable `String`, a `NamedTuple` pinning the expression per
engine, or `nothing`. See [`_db_default_kwarg`](@ref) for why the pin is encoded in the value's type
rather than in a second slot.

The slot is **appended last** on every struct that has it, and that placement is load-bearing rather
than lazy: ten of the 23 declare `default::Union{String, Nothing}`, so a `db_default` sitting beside
it would type-check if the two positional arguments were ever swapped. Appending also means no
existing positional argument moves, which is what `Models.field_without_db_column` (it rebuilds a
field by walking `1:fieldcount(T)`) and every hand-written constructor call depend on.
"""
const DbDefault = Union{String, NamedTuple, Nothing}

"""
    _db_default_kwarg(field_type, value) -> Union{String, NamedTuple, Nothing}

Validate and normalise a `db_default=` keyword (#496). The VALUE'S TYPE is the engine pin:

  * a `String` asserts the expression renders on **both** engines, and is therefore accepted only
    for the closed vocabulary in `PORTABLE_DB_DEFAULTS`;
  * a `NamedTuple` over `(:postgres, :sqlite)` pins it, and an explicit `nothing` for an engine is
    the deliberate "no database default on this one" opt-out.

Encoding the pin in the type rather than in a second `db_default_engine` slot makes three bad states
unrepresentable instead of validated: an engine with no text, text with no engine, and an unknown
engine name. It also keeps `Model_to_str` free — a NamedTuple interpolates into valid Julia source
and Julia's own `show` escapes the strings inside it, so the round trip needs no new escaper.

Every accepted expression is stored in its [`canonical_db_default`](@ref) form, which is what the
live side is also stored in; that shared normalisation is what makes a column converge with itself.
"""
function _db_default_kwarg(field_type::AbstractString, value)
  value === nothing && return nothing

  _one(engine, sql) = begin
    sql isa AbstractString || throw(_fielderr(
      "$field_type: 'db_default' entry for `$engine` must be a String or nothing, got $(typeof(sql))"))
    is_valid_db_default_sql(sql) || throw(_fielderr(
      "$field_type: 'db_default' for `$engine` is not a well-formed column default expression: " *
      "$(repr(String(sql))). It is rendered verbatim into DDL, so it may not contain a bare `;` or " *
      "`,`, a `--` or `/*` comment, an unterminated quote, or unbalanced parentheses or brackets " *
      "— each of those silently changes the statement around it rather than failing. Quote them " *
      "if they are data (`'a;b'` and `'a,b'` are both fine)."))
    return canonical_db_default(sql)
  end

  if value isa AbstractString
    is_valid_db_default_sql(value) || return _one(:both, value)   # reuse the message
    db_default_is_portable(value) || throw(_fielderr(
      "$field_type: db_default = $(repr(String(value))) is not one of the expressions PormG can " *
      "render on both engines ($(join(PORTABLE_DB_DEFAULTS, ", "))), so PormG cannot know which " *
      "engine it is valid on. Name the engine: " *
      "db_default = (postgres = $(repr(String(value))),). A pinned expression renders on that " *
      "engine and raises on the other, so a models file can never emit DDL the database will " *
      "reject. Add a `sqlite = …` entry (or `sqlite = nothing`) to cover both."))
    return canonical_db_default(value)
  end

  if value isa NamedTuple
    ks = keys(value)
    isempty(ks) && throw(_fielderr(
      "$field_type: 'db_default' must name at least one engine, e.g. " *
      "db_default = (postgres = \"now()\",). Pass `nothing` for no database default."))
    for k in ks
      k in _DB_DEFAULT_ENGINES || throw(_fielderr(
        "$field_type: 'db_default' has no engine named `$k`. The engines are " *
        "$(join(("`$e`" for e in _DB_DEFAULT_ENGINES), " and ")); a bare String is the portable " *
        "form."))
    end
    # Normalised in `_DB_DEFAULT_ENGINES` order, and only over the keys actually given — see the
    # constant's comment for why an omitted key must stay omitted rather than become `nothing`.
    present = Tuple(k for k in _DB_DEFAULT_ENGINES if k in ks)
    normalised = NamedTuple{present}(Tuple(
      value[k] === nothing ? nothing : _one(k, value[k]) for k in present))
    all(v -> v === nothing, values(normalised)) && throw(_fielderr(
      "$field_type: 'db_default' declares no expression for any engine — every entry is `nothing`. " *
      "Pass `db_default = nothing` (or omit it) if the column has no database default."))
    return normalised
  end

  throw(_fielderr(
    "$field_type: 'db_default' must be a String (one of $(join(PORTABLE_DB_DEFAULTS, ", "))), a " *
    "NamedTuple naming the engine (e.g. `(postgres = \"now()\",)`), or nothing — got $(typeof(value))"))
end

# #516: the three keywords `ForeignKey`/`OneToOneField` accepted and no renderer ever emitted. Each
# group maps to why the declared value and the emitted DDL were unrelated in BOTH directions — a user
# who wrote `deferrable = true` got `DEFERRABLE` because it is hardcoded, not because they asked, and
# one who left the default got it anyway.
#
# Grouped by REASON rather than one entry per keyword: `deferrable` and `initially_deferred` share an
# explanation, and a field declaring both should read it once instead of twice verbatim.
const _RETIRED_FK_KWARGS = (
  (:on_update,) => "no `ON UPDATE` clause is rendered on either backend",
  (:deferrable, :initially_deferred) =>
      "PostgreSQL emits every foreign-key constraint `DEFERRABLE INITIALLY DEFERRED` regardless " *
      "of what is declared, and SQLite renders no deferrability clause at all",
)

# Refuse a retired keyword instead of dropping it into the `@warn "Unexpected parameter"` arm — see
# the frozen-names contract above for why silence is the wrong failure here. Scoped to the two
# constructors that accepted them, so `CharField(deferrable = true)` keeps its old "unexpected
# parameter" warning rather than gaining an error this issue never argued for.
function _reject_retired_fk_kwargs(field_type::AbstractString, kwargs)
  field_type in ("ForeignKey", "OneToOneField") || return nothing
  # Cheap early-out FIRST. This runs on every `ForeignKey`/`OneToOneField` construction and the
  # answer is almost always "none declared", so the common path must allocate nothing.
  any(g -> any(k -> k in keys(kwargs), first(g)), _RETIRED_FK_KWARGS) || return nothing

  # ALL of them, not the first: a field declaring two retired keywords should take one edit to fix,
  # not one edit per re-run. Iterating `_RETIRED_FK_KWARGS` rather than `keys(kwargs)` keeps the
  # order deterministic for the test that pins this message.
  named = String[]
  reasons = String[]
  for (ks, why) in _RETIRED_FK_KWARGS
    hit = [k for k in ks if k in keys(kwargs)]
    isempty(hit) && continue
    append!(named, ("`$k`" for k in hit))
    push!(reasons, join(("`$k`" for k in hit), ", ") * " — " * why)
  end

  # The tail agrees with the head in number: a message that pluralizes "were removed" and then says
  # "delete the keyword … without it" reads as though only one of the two needs deleting.
  one = length(named) == 1
  throw(_fielderr(
    "$field_type: $(join(named, ", ", " and ")) $(one ? "was" : "were") removed in #516 — " *
    "accepted but never rendered ($(join(reasons, "; "))). The declared " *
    "$(one ? "value" : "values") could not reach the database and $(one ? "was" : "were") not read " *
    "back by either schema reader. Delete the $(one ? "keyword" : "keywords"): the emitted DDL is " *
    "byte-identical without $(one ? "it" : "them"), so this changes no schema and forces no " *
    "migration. If $(one ? "it appears" : "they appear") in a GENERATED models file, PormG wrote " *
    "$(one ? "it" : "them") there from the SQLite catalog — re-run `generate_models_from_db` to " *
    "regenerate, or delete the $(one ? "keyword" : "keywords") by hand. See UPGRADING.md and " *
    "`PormG.upgrade_guide`."))
end

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

  _reject_retired_fk_kwargs(field_type, kwargs)

  for (k, v) in kwargs
    if !(k in accepted)
      @warn "Unexpected parameter for $field_type. It will be ignored." field=field_type param=k value=v
    end
  end

  _bool(name::Symbol, value) = value isa Bool ? value :
    throw(_fielderr("$field_type: '$name' must be a Boolean, got $(typeof(value))"))
  # #603: `AbstractString`, normalized to `String` on the way out. This one helper gates
  # `verbose_name` and `db_column` on EVERY field constructor, so a `SubString` from a generated
  # model file or a web layer was refused across the whole field surface at once. The return stays
  # concrete so the field structs keep `String` slots and no view reaches the DDL path.
  _str_or_nothing(name::Symbol, value) = value isa Nothing ? value :
    value isa AbstractString ? String(value) :
    throw(_fielderr("$field_type: '$name' must be a String or nothing, got $(typeof(value))"))

  # Read a keyword from kwargs ONLY if this constructor accepts it. An unaccepted keyword was
  # warned about above and must be GENUINELY ignored — the pre-#260 preambles never extracted it,
  # so even a wrongly-typed value slid by with just the warning. Consulting kwargs here would turn
  # "warn and ignore" into "warn then throw", making the warning a lie
  # (test_field_kwargs_equivalence.jl pins this).
  _take(key::Symbol, default) = key in accepted ? get(kwargs, key, default) : default

  # #496. Extracted HERE rather than by each constructor the way `:default` is, because unlike
  # `default` — whose accepted Julia type varies per field (`Int64`, `Date`, `Vector{UInt8}`, …) —
  # a `db_default` is raw schema text with one contract for every field type. One validator, not 23.
  db_default = _db_default_kwarg(field_type, _take(:db_default, nothing))
  # `default` and `db_default` are mutually exclusive, which is a departure from Django and the
  # reason is PormG-specific. Django's `default` never touches DDL, so the two are orthogonal there.
  # PormG's `default` is BOTH rendered into the column definition and filled in Julia on the insert
  # path — so a field carrying both would emit one `DEFAULT` clause while every PormG-written INSERT
  # supplied the other value, and the `db_default` would be exercised only by rows some other client
  # wrote. That is a silent trap, not a feature. Refusing also keeps `_column_default` total: the IR
  # has one `default` slot and never needs a precedence rule.
  if db_default !== nothing && :default in accepted && get(kwargs, :default, nothing) !== nothing
    throw(_fielderr(
      "$field_type: 'default' and 'db_default' cannot both be set. `default` is applied by PormG " *
      "when it writes the row AND rendered into the column definition; `db_default` is applied by " *
      "the database. Declaring both means the database's expression would never be exercised by a " *
      "PormG insert. Keep `default` for a value PormG should write, or `db_default` for one the " *
      "database should compute."))
  end

  common = (
    verbose_name = _str_or_nothing(:verbose_name, _take(:verbose_name, nothing)),
    unique       = _bool(:unique,   _take(:unique,   unique)),
    blank        = _bool(:blank,    _take(:blank,    false)),
    null         = _bool(:null,     _take(:null,     false)),
    db_index     = _bool(:db_index, _take(:db_index, db_index)),
    db_column    = _str_or_nothing(:db_column, _take(:db_column, nothing)),
    editable     = _bool(:editable, _take(:editable, editable)),
    primary_key  = _bool(:primary_key, _take(:primary_key, primary_key === nothing ? false : primary_key)),
    db_default   = db_default,
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
    id::PormGField = IDField()
    name::PormGField = CharField(max_length=100)
    email::PormGField = EmailField()
)
```

Using GENERATED ALWAYS (stricter identity):
```julia
Order = Models.Model(
    id::PormGField = IDField(generated_always=true)
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
      # `db_default` is excluded, and it is FORCED rather than chosen (#496). `sIDField` renders
      # `GENERATED … AS IDENTITY` on PostgreSQL (`Dialect.field_to_column`), and PostgreSQL rejects
      # a column that is both an identity column and carries a `DEFAULT`. Accepting the keyword
      # here would make invalid DDL *declarable*, which is the one outcome #496's design forbids —
      # so `sIDField` has no slot either, and the two agree by construction. The schema readers
      # never populate one for this arm for the same reason (`_integer_key_arm`), and
      # `Migrations.check` keeps its matching carve-out.
      exclude = (:db_default,),
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
  how::Union{String, Nothing}  # INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN used in _build_row_join
  related_name::Union{String, Nothing}
  type::String
  formatter::Function
  db_constraint::Bool
  # Physical parent TABLE this key points at, when `.to` came from introspection (#360). NOT declared
  # API: no constructor kwarg accepts it, `Model_to_str` never emits it, and the migration planner
  # reads it only to resolve the parent table, never as a difference of its own
  # (`Migrations.SCHEMA_ATTRS`, #507). It exists so the inspectdb
  # importers can rewrite `.to` to the target's FINAL, collision-deduped binding before rendering —
  # `uppercasefirst` is lossy (`Driver` and `driver` both produce `Driver`), so the physical table
  # cannot be recovered from `.to` afterwards. Set post-construction; see `_plan_inspectdb_bindings!`.
  #
  # INVARIANT (#390): when set, this is the CANONICAL table name — the spelling the catalog itself
  # uses, not whatever a `REFERENCES` clause happened to say. The planner compares it EXACTLY (case
  # included) through `_fk_targets_equal` (#390), which is only correct while its producers honor that.
  # Three write here, and one of them does NOT:
  #
  #   * the PostgreSQL reader — `cf.relname` from `pg_class`, canonical by construction;
  #   * the SQLite PRAGMA reader — resolves `PRAGMA foreign_key_list`'s REFERENCES spelling through
  #     `Migrations._sqlite_canonical_table_name`, EXCEPT for a parent that is not in `sqlite_master`
  #     at read time (a dangling foreign key, which SQLite permits). That one keeps the REFERENCES
  #     spelling. Self-healing rather than perpetual: the first `migrate` creates the parent and the
  #     next read canonicalizes it;
  #   * `convertSQLToModel(::String)` — since #522 it executes the statement in a throwaway SQLite
  #     file and runs the PRAGMA reader over it. The parent table never exists in that file, so the
  #     resolver falls back to the REFERENCES spelling: for this entry point the outcome is the same
  #     as the regex reader it replaced, and it stays off the live route.
  #
  # A NEW producer that writes a non-canonical name here reintroduces #390's churn.
  to_table::Union{String, Nothing}
  db_default::DbDefault
end

"""
    ForeignKey(to::Union{AbstractString, PormGModel}; kwargs...)

A field that creates a many-to-one relationship to another model, similar to Django's ForeignKey.

The `ForeignKey` field represents a relationship where many records in the current model can reference a single record in the target model. It creates a foreign key constraint in the database and enables efficient querying of related data.

# Required Arguments
- `to::Union{AbstractString, PormGModel}`: The target model that this field references. Can be either:
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = false`: Whether the field should be editable in forms
- `pk_field::Union{String, Symbol, Nothing} = nothing`: Which field in the target model to reference (defaults to primary key)
- `on_delete::Union{Function, String, Nothing} = nothing`: Action when the referenced object is deleted
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
    id = IDField()
    title = CharField(max_length=200)
    author = ForeignKey("User")
    category = ForeignKey("Category", on_delete=CASCADE)
)
```

Foreign key allowing NULL values:
```julia
Product = Models.Model(
    id = IDField()
    name = CharField(max_length=100)
    category = ForeignKey("Category", null=true, blank=true, on_delete=SET_NULL)
)
```

Multiple foreign keys to the same model — `related_name` is optional, but recommended:
```julia
Message = Models.Model(
    id = IDField()
    sender = ForeignKey("User", related_name="sent_messages")
    recipient = ForeignKey("User", related_name="received_messages")
    content = TextField()
)
```

# Related Names and Reverse Relations
- If `related_name` is not specified, PormG derives one and logs it at `@info`
- The derivation counts **every** relation this model declares to that target — `ForeignKey`,
  `OneToOneField` and `ManyToManyField` alike: the lowercase model name when it is the only one,
  `<model>_<field>` for **every** member of a group of two or more (#396)
- A derived name is never written back onto the field, so `related_name` stays `nothing` unless you set it
- The reverse accessor must not match a field name on the model it lands on, or another accessor
  already registered there; either raises `ModelDefinitionError` at `set_models`
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
- Unrecognized parameters trigger a warning and are ignored — except `on_update`, `deferrable` and
  `initially_deferred`, retired in #516, which raise `FieldValidationError` (see the upgrade log)

# Notes
- The field stores the primary key value of the referenced object
- Uses BIGINT type to match IDField primary keys
- Deferrability is not configurable (#516): PostgreSQL emits every foreign-key constraint
  `DEFERRABLE INITIALLY DEFERRED`, and SQLite renders no deferrability clause at all
- No `ON UPDATE` clause is rendered on either backend

# See Also
- Django's ForeignKey documentation for conceptual understanding
"""
function ForeignKey(to::Union{AbstractString, PormGModel}; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, db_constraint, db_default) =
    _common_kwargs("ForeignKey", kwargs; primary_key = false, db_index = true,
      bools = (db_constraint = true,),
      extra = (:pk_field, :on_delete, :how, :related_name))

  default = get(kwargs, :default, nothing)
  pk_field = get(kwargs, :pk_field, nothing)
  on_delete = get(kwargs, :on_delete, nothing)
  how = get(kwargs, :how, nothing)
  related_name = get(kwargs, :related_name, nothing)

  # Validate 'to' parameter
  !(to isa Union{AbstractString, PormGModel}) && throw(_fielderr("The 'to' parameter must be a String or PormGModel"))
  to isa AbstractString && (to = String(to))   # #603

  # Validate boolean parameters

  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "ForeignKey", format2int64)

  # Validate optional string parameters
  !(pk_field isa Union{Nothing, AbstractString, Symbol}) &&
    throw(_fielderr("The 'pk_field' must be a String, Symbol, or nothing"))
  on_delete = _get_on_delete_mode(on_delete)
  !(how isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'how' must be a String or nothing"))
  # #603: the guard here already said `AbstractString`, but nothing converted — so a `SubString`
  # passed validation and then died inside `sForeignKey`'s `Union{String,Nothing}` slot with a raw
  # `MethodError`. Same shape as the bulk-filter escape; same fix.
  how isa AbstractString && (how = String(how))
  !(related_name isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'related_name' must be a String or nothing"))
  related_name = _validate_related_name(related_name, "ForeignKey")

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
    how,
    related_name,
    "BIGINT",
    format_number_sql,
    db_constraint,
    nothing,  # to_table — introspection-only breadcrumb (#360), never set from a declaration
    db_default
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
    ManyToManyField(to::Union{AbstractString, PormGModel}; kwargs...)

Declare a many-to-many relationship without adding a physical column to the
owning model table. When `through` is omitted, migrations synthesize a join
table with two foreign keys and a composite unique index.

# Keyword Arguments
- `through::Union{String, PormGModel, Nothing} = nothing`: explicit through model; skips auto table synthesis.
- `related_name::Union{String, Nothing} = nothing`: reverse accessor on the target model. Omitted, it is derived like a `ForeignKey`'s — the lowercase model name, or `<model>_<field>` when the model declares two or more relations to that target, many-to-many and foreign key counted together (#396).
- `db_table::Union{String, Nothing} = nothing`: auto-through table name override. Ignored when `through` is given — the join table is then the through model's own table (its `db_table` if it declares one).
- `source_field::Union{String, Nothing} = nothing`: the join key pointing at the source model. With an explicit `through`, it names a **field** on that model and the physical column is resolved from the field's `db_column` (#377); on the auto-synthesized table it names the column directly, since PormG creates it.
- `target_field::Union{String, Nothing} = nothing`: the same, for the target model.

Both pins exist to disambiguate **which** foreign key is which end — required when the through model
has two pointing at the same model, as on a self-relation. A `through` model whose foreign keys simply
map to differently-named columns needs no pin: `db_column` is resolved on its own.
"""
function ManyToManyField(to::Union{AbstractString, PormGModel}; kwargs...)
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

  !(to isa Union{AbstractString, PormGModel}) && throw(_fielderr("The 'to' parameter must be a String or PormGModel"))
  to isa AbstractString && (to = String(to))   # #603
  !(verbose_name isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'verbose_name' must be a String or nothing"))
  verbose_name isa AbstractString && (verbose_name = String(verbose_name))   # #603
  !(through isa Union{Nothing, AbstractString, PormGModel}) && throw(_fielderr("The 'through' parameter must be a String, PormGModel, or nothing"))
  through isa AbstractString && (through = String(through))                  # #603
  !(related_name isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'related_name' must be a String or nothing"))
  related_name = _validate_related_name(related_name, "ManyToManyField")
  !(db_table isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'db_table' must be a String or nothing"))
  !(source_field isa Union{Nothing, AbstractString, Symbol}) && throw(_fielderr("The 'source_field' must be a String, Symbol, or nothing"))
  !(target_field isa Union{Nothing, AbstractString, Symbol}) && throw(_fielderr("The 'target_field' must be a String, Symbol, or nothing"))

  return sManyToManyField(
    verbose_name,
    false,
    to,
    through,
    related_name,  # already normalized to String/nothing by `_validate_related_name` (#420)
    # Case-PRESERVING (#59): this used to run through `format_model_name`, which silently lowercased
    # a user-supplied physical through-table name (and, until #317, stripped a leading underscore) — the
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
  how::Union{String, Nothing}  # INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN used in _build_row_join
  related_name::Union{String, Nothing}
  type::String
  formatter::Function
  db_constraint::Bool
  # See `sForeignKey.to_table` above for why this slot exists and why it is not declared API (#360).
  # It must exist on BOTH structs: since #417 BOTH schema readers emit a `OneToOneField` whenever
  # the foreign key column is also UNIQUE, or is itself the primary key (#409).
  to_table::Union{String, Nothing}
  db_default::DbDefault
end

# The two field types that declare a physical relational column on their OWN table: a foreign key,
# and a one-to-one (which IS a foreign key carrying a UNIQUE constraint). Neither subtypes the other
# — `PormGField` is the only abstract type above them — so `isa sForeignKey` silently misses a
# one-to-one, and `::sForeignKey` throws on one. That single defect was found once per subsystem:
# #408 in the DDL renderer and the planner guard, #409 in the schema readers, #418 in the query
# builder. Spelling the pair ONCE is what stops a fourth.
#
# NOT the same set as a bare `hasfield(typeof(f), :to)`, which also admits `sManyToManyField`. An
# M2M declares no column here — no `pk_field`, no `on_delete`, no `null` — so widening one of these
# gates to that test would trade a `MethodError` for a crash one field access later. When a gate
# genuinely wants "any relation, M2M included", the existing spelling is
# `Models.foreign_keys_in_model`'s: `hasfield(typeof(f), :to)` paired with `!is_many_to_many_field(f)`.
# (`Dialect._is_relational_field` was that bare test, and is gone with #507's column IR.)
#
# The `s` prefix follows the field-struct family this aliases, but it is a `Union`, not a struct:
# `subtypes(PormGField)` never yields it, and `Model_to_str`'s `nameof(typeof(f))[2:end]` constructor-
# name recovery never sees it either. Nothing enumerates field types by prefix, so the parallel
# spelling costs nothing — but do not reach for it where a concrete struct is required.
const sRelationalColumn = Union{sForeignKey, sOneToOneField}

"""
    OneToOneField(to::Union{AbstractString, PormGModel}; kwargs...)

A field that creates a one-to-one relationship to another model, similar to Django's OneToOneField.

The `OneToOneField` represents a strict one-to-one relationship where each record in the current model corresponds to exactly one record in the target model, and vice versa. It's essentially a ForeignKey with a unique constraint that ensures no two records can reference the same target record.

# Required Arguments
- `to::Union{AbstractString, PormGModel}`: The target model that this field references. Can be either:
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = false`: Whether the field should be editable in forms
- `pk_field::Union{String, Symbol, Nothing} = nothing`: Which field in the target model to reference (defaults to primary key)
- `on_delete::Union{Function, String, Nothing} = nothing`: Action when the referenced object is deleted
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
    id = IDField()
    username = CharField(max_length=150, unique=true)
    email = EmailField()
)

UserProfile = Models.Model(
    id = IDField()
    user = OneToOneField("User", on_delete=CASCADE)
    bio = TextField(blank=true)
    avatar = ImageField(blank=true)
    birth_date = DateField(null=true, blank=true)
)
```

One-to-one with null values allowed:
```julia
Employee = Models.Model(
    id = IDField()
    name = CharField(max_length=100)
    department = CharField(max_length=50)
)

EmployeeSettings = Models.Model(
    id = IDField()
    employee = OneToOneField("Employee", null=true, blank=true, on_delete=SET_NULL)
    email_notifications = BooleanField(default=true)
    theme_preference = CharField(max_length=20, default="light")
)
```

Extending a model without modifying it:
```julia
Product = Models.Model(
    id = IDField()
    name = CharField(max_length=200)
    price = DecimalField(max_digits=10, decimal_places=2)
)

ProductDetails = Models.Model(
    id = IDField()
    product = OneToOneField("Product", on_delete=CASCADE, related_name="details")
    detailed_description = TextField()
    technical_specs = TextField()
    warranty_info = TextField()
)
```

# Database Constraints vs. Unique ForeignKey
The two spellings produce the same physical column:
```julia
# The same column: the referenced key's type, UNIQUE, plus the foreign-key constraint.
user = OneToOneField("User")
user = ForeignKey("User", unique=true)
```

`OneToOneField` is nonetheless the spelling to prefer, for readability and because it is what
**introspection reports** for such a column, on both PostgreSQL and SQLite (#417).

It is a preference, not a requirement. Since #437 the migration planner converges the two spellings
against the same live column — it diffs them attribute by attribute rather than by struct type — so
an existing `ForeignKey(..., unique=true)` declaration needs no rewrite and proposes no migration.
(Before #437 it proposed one on every `makemigrations` as soon as any other column in that table
changed: an `ALTER` that re-rendered the column unchanged, and a full table rebuild on SQLite.)

# Validation
- The `to` parameter must be a valid model name or PormGModel instance
- All boolean parameters are validated for type safety
- The `on_delete` parameter is validated against allowed values
- Uniqueness is automatically enforced at the database level
- Unrecognized parameters trigger a warning and are ignored — except `on_update`, `deferrable` and
  `initially_deferred`, retired in #516, which raise `FieldValidationError` (see the upgrade log)

# Notes
- Deferrability is not configurable (#516): PostgreSQL emits every foreign-key constraint
  `DEFERRABLE INITIALLY DEFERRED`, and SQLite renders no deferrability clause at all
- No `ON UPDATE` clause is rendered on either backend

# See Also
- Django's OneToOneField documentation for conceptual understanding
- Database normalization principles for when to use one-to-one relationships
"""
function OneToOneField(to::Union{AbstractString, PormGModel}; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, db_constraint, db_default) =
    _common_kwargs("OneToOneField", kwargs; primary_key = false, unique = true, db_index = true,
      bools = (db_constraint = true,),
      extra = (:pk_field, :on_delete, :how, :related_name))

  default = get(kwargs, :default, nothing)
  pk_field = get(kwargs, :pk_field, nothing)
  on_delete = get(kwargs, :on_delete, nothing)
  how = get(kwargs, :how, nothing)
  related_name = get(kwargs, :related_name, nothing)

  # Validate 'to' parameter
  !(to isa Union{AbstractString, PormGModel}) && throw(_fielderr("The 'to' parameter must be a String or PormGModel"))
  to isa AbstractString && (to = String(to))   # #603

  # Validate boolean parameters

  # Validate default
  default = validate_default(default, Union{Int64, Nothing}, "OneToOneField", format2int64)

  # Validate optional string parameters
  # #603: these three were `String`-only while `ForeignKey`'s own siblings were already
  # `AbstractString` — one family, two spellings. Aligned on the wider one.
  !(pk_field isa Union{Nothing, AbstractString, Symbol}) && throw(_fielderr("The 'pk_field' must be a String, Symbol, or nothing"))
  !(how isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'how' must be a String or nothing"))
  how isa AbstractString && (how = String(how))
  !(related_name isa Union{Nothing, AbstractString}) && throw(_fielderr("The 'related_name' must be a String or nothing"))
  related_name = _validate_related_name(related_name, "OneToOneField")

  # Resolve on_delete using similar logic as ForeignKey
  on_delete = _get_on_delete_mode(on_delete)

  # Resolve db_index based on db_constraint
  db_index = db_index || !db_constraint
  # Validate pk_field, matching ForeignKey. It is a REFERENCE to a key on the parent model, so
  # `format_fild_name` returns it verbatim since #317 — that is what lets it name a `_id`-style key
  # on a model built by introspection (#50).
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
    how,
    related_name,
    "BIGINT",
    format_number_sql,
    db_constraint,
    nothing,  # to_table — introspection-only breadcrumb (#360), never set from a declaration
    db_default
  )
end

"""
    AutoField(; kwargs...)

**Retired (#408). Use [`IDField`](@ref).** Calling this raises `FieldValidationError`.

`AutoField` was documented as a 32-bit auto-incrementing integer primary key — "INTEGER with SERIAL
auto-increment". It never was one. `Dialect._get_column_type` had no `sAutoField` branch on either
backend, so the field fell through to the `else` and emitted a **`TEXT`** column, on PostgreSQL and
SQLite alike, with no sequence, identity, or `AUTOINCREMENT` behind it. A model keyed on it produced
a text primary key that nothing could allocate, and `makemigrations` could never converge, because
what the field declared and what introspection read back could not agree.

It is retired rather than repaired because repairing it buys almost nothing and costs a whole class
of defect (#409). `IDField` is the only integer key type PormG's introspection reads back, so any
other one is condemned to a perpetual `ALTER` on every `makemigrations`. On SQLite the distinction is
not even physical: `INTEGER PRIMARY KEY` is a 64-bit rowid alias, so an `AutoField` column and an
`IDField` column are byte-identical. The saving was four bytes per row, on one backend, for a type
that had never worked — and the Django importer had already been routed away from it for exactly
these reasons (#399, `DJANGO_AUTO_KEY_TYPES`).

This stub exists so a consuming app fails at the declaration with an actionable message instead of an
`UndefVarError` from a generated models file. It is a pre-publish migration aid and is removed before
the first General-registry release; see the upgrade log (`PormG.upgrade_guide`).

# Migration

```julia
# before
Part_category = Models.Model(
    id   = Models.AutoField(),
    name = Models.CharField(max_length = 100)
)

# after
Part_category = Models.Model(
    id   = Models.IDField(),
    name = Models.CharField(max_length = 100)
)
```

`IDField` is BIGINT rather than INTEGER, but an existing PostgreSQL table whose key really is
`integer` keeps that column: PormG compares the field's declared `type` slot, not the rendered width.
Two caveats, both covered in the upgrade log — a key that is not an IDENTITY column still attracts an
`ADD GENERATED BY DEFAULT AS IDENTITY` (a pre-existing `:generated` mismatch), and a column a real
`AutoField` created is `text`. PostgreSQL refuses that as an identity column, so the migration
errors; **SQLite does not refuse it** — it rebuilds the table into `INTEGER PRIMARY KEY
AUTOINCREMENT`, which aborts on a non-numeric key and silently renumbers a zero-padded one
(`'0042'` becomes `42`). Re-type such a column by hand.
"""
function AutoField(; kwargs...)
  throw(_fielderr(
    "AutoField was retired in #408 — use IDField() instead. It never rendered an INTEGER column: " *
    "`Dialect._get_column_type` had no branch for it, so it emitted TEXT on both backends with no " *
    "auto-increment, and a model keyed on it could never converge under `makemigrations`. " *
    "IDField is BIGINT and is the only integer key type PormG's introspection reads back. " *
    "See UPGRADING.md and `PormG.upgrade_guide`."))
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
  db_default::DbDefault
end


function parse_choices(choices_str::AbstractString)
  # Parse a string into a tuple of tuples. `::AbstractString` because the `CharField` guard admits any
  # AbstractString and used to hand a `SubString` to a `::String`-only method (#602). The regex needs a
  # real `String` — `String(x)`, not `string(x)`, which is the identity for a `LazyString` (#598).
  choices = ()
  pattern = r"\(([^()]+)\)"
  for m in eachmatch(pattern, String(choices_str))
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
    id = IDField(),
    username = CharField(max_length=150, unique=true),
    first_name = CharField(max_length=50),
    last_name = CharField(max_length=50)
)
```

String field with choices (enumeration):
```julia
Order = Models.Model(
    id = IDField()
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
    id = IDField(),
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
    id = IDField(),
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
    id = IDField(),
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
- **Changing Column Name**: the physical column is `db_column` when set, else the field name, and `db_column` is authoritative across DDL, queries and the migration diff (#50). The diff compares physical columns, so renaming the field while `db_column` pins the old name plans nothing. Changing the physical name — renaming an unpinned field, or changing `db_column` — reads as one column gone and another added: interactive `makemigrations` asks whether they are the same field and plans a `RENAME COLUMN` if you say so; otherwise it plans `ADD COLUMN` plus `DROP COLUMN`, which loses the column's data. See *Renaming a field* in the migrations guide

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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, db_default) =
    _common_kwargs("CharField", kwargs; primary_key = false, editable = true, extra = (:max_length, :choices))

  max_length = get(kwargs, :max_length, 250)
  default = get(kwargs, :default, nothing)
  choices = get(kwargs, :choices, nothing)

  max_length = _int_kwarg("CharField", "max_length", max_length; strings = true)   # #614, #646
  # No upper bound (#325). The old 255 ceiling was a MySQL-ism — PostgreSQL's `varchar` takes up to
  # 10,485,760 characters and SQLite ignores the declared length. Worse, it was LOSSY on read-back:
  # introspecting a live `varchar(500)` had to retype the column to TextField and drop the length,
  # so the declared model never matched its own table and `makemigrations` churned forever. A future
  # MySQL backend enforces its own limit at render time (#60), not here.
  max_length < 1 && throw(_fielderr("The max_length must be greater than 1"))
  # #612: was an inline `isa Int` coercion plus an `isa AbstractString` guard — correct, but the
  # only correct one in the family and unreachable from the six constructors that needed it. The
  # shared helper is that same ladder, so CharField's accepted set does not move; what moves is
  # that the other plain-text fields now agree with it.
  default = _default_string("CharField", default)
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
  return sCharField(verbose_name, primary_key, max_length, unique, blank, null, db_index, db_column, default, editable, "VARCHAR", format_text_sql, choices, db_default)
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = false`: Whether the field should be editable in forms

# Examples

Basic integer field:
```julia
Product = Models.Model(
    id = IDField(),
    name = CharField(max_length=200),
    quantity = IntegerField(default=0),
    price_cents = IntegerField()  # Store price in cents to avoid decimals
)
```

Integer field with constraints:
```julia
User = Models.Model(
    id = IDField(),
    username = CharField(max_length=150, unique=true),
    age = IntegerField(null=true, blank=true),
    score = IntegerField(default=0, db_index=true)
)
```

Rating system:
```julia
Review = Models.Model(
    id = IDField(),
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
    _common_kwargs("IntegerField", kwargs)

  default = validate_default(get(kwargs, :default, nothing), Union{Int64, Nothing}, "IntegerField", format2int64)

  return sIntegerField(
    verbose_name, false, unique, blank, null, db_index, db_column, default, editable,
    "INTEGER", format_number_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = false`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: SMALLINT + `CHECK ("col" >= 0)`
- **SQLite Type**: SMALLINT (INTEGER affinity) + `CHECK ("col" >= 0)`
- **Range**: 0 to 32767

# Examples
```julia
Standing = Models.Model(
    id = IDField(),
    position = PositiveSmallIntegerField(default=1),
    points = PositiveSmallIntegerField(default=0)
)
```
"""
function PositiveSmallIntegerField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
    format_number_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = false`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: INTEGER + `CHECK ("col" >= 0)`
- **SQLite Type**: INTEGER UNSIGNED (INTEGER affinity) + `CHECK ("col" >= 0)`
- **Range**: 0 to 2147483647

# Examples
```julia
Lap_times = Models.Model(
    id = IDField(),
    lap = PositiveIntegerField(default=1),
    milliseconds = PositiveIntegerField()
)
```
"""
function PositiveIntegerField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
    format_number_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
    id = IDField(),
    user_id = BigIntegerField(db_index=true),
    session_id = BigIntegerField(),
    timestamp_ms = BigIntegerField()  # Unix timestamp in milliseconds
)
```

Population and statistics:
```julia
Country = Models.Model(
    id = IDField(),
    name = CharField(max_length=100),
    population = BigIntegerField(null=true),
    gdp_usd = BigIntegerField(null=true),  # GDP in USD cents
    area_sq_meters = BigIntegerField()
)
```

Large external identifiers:
```julia
SocialMedia = Models.Model(
    id = IDField(),
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
    format_number_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = false`: Whether the field should be editable in forms

# Examples

Basic boolean flags:
```julia
User = Models.Model(
    id = IDField(),
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
    format_bool_sql, db_default
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
  db_default::DbDefault
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
- `default::Union{Date, Nothing} = nothing`: Default value for the field. The four accepted input spellings are listed under *Date Input Formats* below; all of them are stored as a `Date`
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = false`: Whether the field should be editable in forms
- `auto_now::Bool = false`: Whether to automatically set to current date on every save
- `auto_now_add::Bool = false`: Whether to automatically set to current date on creation only

# Examples

Basic date fields:
```julia
User = Models.Model(
    id = IDField(),
    username = CharField(max_length=150),
    birth_date = DateField(null=true, blank=true),
    join_date = DateField(auto_now_add=true),
    last_login_date = DateField(null=true)
)
```

Event and scheduling:
```julia
Event = Models.Model(
    id = IDField(),
    title = CharField(max_length=200),
    event_date = DateField(db_index=true),
    registration_deadline = DateField(),
    created_date = DateField(auto_now_add=true)
)
```

Business dates:
```julia
Invoice = Models.Model(
    id = IDField(),
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
`default=` accepts all four spellings and stores a `Date` for every one of them (#631 — three of
these raised a raw `MethodError` until the `default=` converter stopped being the SQL formatter):
- **Julia Date**: `Date(2024, 7, 28)`
- **DateTime**: `DateTime(2024, 7, 28, 10, 30)` — the time is dropped
- **ZonedDateTime**: its LOCAL calendar date
- **String**: anything `Date(::AbstractString)` parses, i.e. `"2024-07-28"`. A malformed separator or
  an impossible calendar date (`"2023-02-29"`) raises [`FieldValidationError`](@ref)
"""
function DateField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, auto_now, auto_now_add, db_default) =
    _common_kwargs("DateField", kwargs; bools = (auto_now = false, auto_now_add = false))

  default = get(kwargs, :default, nothing)

  # Validate default. `normalize_date_default`, NOT the `format_date_sql` formatter passed below:
  # the formatter renders a value into SQL text and returns a String, which is not what this slot
  # holds (#631). The two roles are separate on purpose — see that function's docstring.
  default = validate_default(default, Union{Date, Nothing}, "DateField", normalize_date_default)
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
    format_date_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, auto_now, auto_now_add, db_default) =
    _common_kwargs("DateTimeField", kwargs; bools = (auto_now = false, auto_now_add = false), extra = (:type,))

  default = get(kwargs, :default, nothing)
  #TIMESTAMPTZ
  type = get(kwargs, :type, "TIMESTAMPTZ") |> uppercase

  # Validate default
  default = validate_default(default, Union{ZonedDateTime, DateTime, Nothing}, "DateTimeField", normalize_datetime_default)
  # #603: the `!(type isa String)` guard that stood here is gone, because the two lines around it
  # already cover everything it did. `type` is piped through `uppercase` above, which returns a
  # plain `String` for ANY `AbstractString` — so no string spelling could ever reach the guard.
  #
  # It was NOT unreachable for every input, and the distinction is worth recording: `uppercase` has
  # an `AbstractChar` method, so `DateTimeField(type = 'T')` produced `'T'::Char` and the guard DID
  # fire on it. The shape check immediately below absorbs that case unchanged — a `Char` is not
  # `== "TIMESTAMPTZ"` — so the same `FieldValidationError` is still raised, only naming the
  # supported values instead of the type. Anything `uppercase` has no method for (a `Symbol`, an
  # `Int`) raises there, one line earlier, and never reached the guard either.
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
    format_timezone_sql, db_default
  )  
end

"""
    normalize_date_default(value)

The converter every `DateField` default goes through: a `Date` as it is, a `DateTime` or
`ZonedDateTime` reduced to its calendar date, a string parsed by `Date(::AbstractString)`.

Module-level for `normalize_datetime_default`'s reason (#522) — `Migrations._coerce_default`'s
`CDate` arm calls THIS function, so the live side lands on the value a declaration stores. Until
#631 that arm open-coded the same three lines, and its docstring said so.

It exists at all because `DateField` used to hand `validate_default` the field's **formatter**,
`format_date_sql`, which is the right function for a different job: it renders a value into SQL
text, so every one of its arms returns a `String`. The `default` slot is `Union{Date, Nothing}`, and
`validate_default` did not re-check its converter's result — so `DateField(default = "2024-01-01")`,
the spelling `docs/src/fields.md` advertises, put a `String` into a `Date` slot and died with a raw
`MethodError` outside the #231/#239 taxonomy. The two roles have incompatible codomains; the
formatter slot still holds `format_date_sql` (that part was never wrong) and the `default=` converter
is this.

`DateTime`/`ZonedDateTime` drop the time rather than refusing it, which is the contract
`docs/src/fields.md` states and what `format_date_sql` did before. A `ZonedDateTime` yields its
LOCAL calendar date — `Date(::ZonedDateTime)` — matching both the old converter and the `CDate` arm.
"""
function normalize_date_default(value)
  if value === nothing
    nothing
  elseif value isa Date
    value
  elseif value isa Union{DateTime, ZonedDateTime}
    Date(value)
  elseif value isa AbstractString
    try
      Date(String(value))
    catch e
      # #472, as in `normalize_datetime_default` below: a program-state failure is not "this value
      # is not a valid default". `DateField` is exercised by every expression-default fixture
      # (`d DATE DEFAULT CURRENT_DATE`), so this sits squarely on the path introspection's
      # warn-and-drop guard depends on not disguising a cancelled import.
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      throw(_fielderr("Invalid default value for DateField. The date $(value) is invalid: " *
                      "$(_one_line_date_error(e))"))
    end
  else
    throw(_fielderr("Invalid default value for DateField. Expected a Date, DateTime, " *
                    "ZonedDateTime, or a parseable date string such as \"2024-07-28\"."))
  end
end

# Kept beside the only caller: the message above quotes the parse failure so a wrong SEPARATOR and a
# wrong CALENDAR DATE ("2023-02-29") read differently, and `sprint(showerror, e)` on an
# `ArgumentError` can carry a newline that would break the single-line error convention.
#
# That message is NOT what a `DateField(default = "nope")` caller sees — `validate_default` wraps
# the converter in a bare `catch` and substitutes its own "Expected type: …" text, the same known
# imprecision the `format2int64` block in `Models.jl` records. It is written for the caller that
# does see it: `Migrations._coerce_default` invokes this directly, and `_default_or_drop` logs the
# message into its warn-and-drop line, where naming the offending date is the whole value.
_one_line_date_error(e)::String = replace(sprint(showerror, e), r"\s*\n\s*" => " ")

"""
    normalize_datetime_default(value)

The converter every `DateTimeField` default goes through: a `DateTime` or `ZonedDateTime` as it is, a
string parsed as `DATETIME_FORMAT` with an offset, then without, then as a plain ISO datetime.

Module-level since #522 rather than a closure inside the constructor, because the introspection
readers coerce a live column's default with the SAME converter (`Migrations._coerce_default`) so the
live side lands on the value a declaration stores. One definition, or the two sides drift on exactly
the strings a catalog hands back.
"""
function normalize_datetime_default(value)
  if value === nothing
    nothing
  elseif value isa Union{ZonedDateTime, DateTime}
    value
  elseif value isa AbstractString
    try
      ZonedDateTime(value, DATETIME_FORMAT)
    catch e
      # #472: these were bare `catch`es, so an interrupt raised mid-parse was absorbed here and
      # the next attempt simply ran — `validate_default`'s carve-out never saw it. This is the
      # converter EVERY DateTimeField default goes through, i.e. the `DEFAULT now()` path that
      # introspection's warn-and-drop guard depends on not disguising a cancelled import.
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      try
        DateTime(value, DATETIME_FORMAT)
      catch e2
        (e2 isa InterruptException || e2 isa StackOverflowError) && rethrow()
        DateTime(value)
      end
    end
  else
    throw(_fielderr("Invalid default value for DateTimeField. Expected a DateTime, ZonedDateTime, or parseable datetime string."))
  end
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, db_default) =
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
  # #646: width keywords, not defaults — `validate_default` paired `Int` with an `Int64` converter.
  max_digits = _int_kwarg("DecimalField", "max_digits", max_digits; strings = true)
  decimal_places = _int_kwarg("DecimalField", "decimal_places", decimal_places; strings = true)
  
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
    format_number_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
    _common_kwargs("EmailField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = _default_string("EmailField", default)   # #612
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
    format_text_sql, db_default
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
  db_default::DbDefault
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
    id = Models.IDField(),
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
  (; verbose_name, blank, null, db_column, editable, auto_hash, db_default) =
    _common_kwargs("PasswordField", kwargs; editable = true, exclude = (:unique, :db_index, :default, :db_default), extra = (:max_length,), bools = (auto_hash = true,))

  max_length = get(kwargs, :max_length, 128)

  max_length = _int_kwarg("PasswordField", "max_length", max_length)   # #614
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
    auto_hash, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, db_default) =
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
    format_number_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
    _common_kwargs("ImageField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = _default_string("ImageField", default)   # #612
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
    format_text_sql, db_default
  )  
end

"""
    FileField(; kwargs...)

Django-compatibility alias for storing file upload paths. Behaves identically to `ImageField`.
Accepted kwargs: `verbose_name`, `unique`, `blank`, `null`, `db_index`, `default`, `editable`, `upload_to`, `max_length`.
"""
function FileField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
    _common_kwargs("FileField", kwargs; editable = true, extra = (:upload_to, :max_length))

  default = get(kwargs, :default, nothing)
  default = _default_string("FileField", default)    # #612

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
    format_text_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
    _common_kwargs("TextField", kwargs)

  default = get(kwargs, :default, nothing)

  # Validate default
  default = _default_string("TextField", default)    # #612
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
    format_text_sql, db_default
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
  db_default::DbDefault
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
    format_text_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
  # A String with no digit in it means "no limit". One WITH a digit is parsed by `_int_kwarg` below
  # (#646 — it went through `validate_default(…, Int, …, format2int64)`, wrong on a 32-bit build).
  max_length isa AbstractString && !occursin(r"\d", max_length) && (max_length = nothing)
  # #614: `nothing` is still the no-limit spelling; anything else goes through the shared integer
  # keyword policy. This was an `isa Int` check, so `BinaryField(max_length = Int32(50))` was
  # refused as "not an integer or nothing" — about a value that is plainly an integer.
  max_length === nothing || (max_length = _int_kwarg("BinaryField", "max_length", max_length; strings = true))
  if max_length isa Int && max_length <= 0
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
    max_length, db_default
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
  db_default::DbDefault
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
    format_duration_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = true`: Whether the field should be editable in forms
- `auto_add::Bool = false`: If true, automatically generates a UUID (`uuid4()`) when creating a new record without a provided value.

# Database Mapping
- **PostgreSQL Type**: UUID
- **SQLite Type**: TEXT

# Examples
```julia
using UUIDs

Session = Models.Model(
    id = IDField(),
    session_token = UUIDField(unique=true, db_index=true),
    user_id = ForeignKey("User")
)
```
"""
function UUIDField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, primary_key, auto_add, db_default) =
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
    auto_add, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = true`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: VARCHAR(max_length)
- **SQLite Type**: TEXT(max_length)

# Examples
```julia
Circuit = Models.Model(
    id = IDField(),
    name = CharField(max_length=200),
    wiki_url = URLField(null=true, blank=true, verbose_name="Wikipedia Link")
)
```
"""
function URLField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
    _common_kwargs("URLField", kwargs; editable = true, extra = (:max_length,))

  max_length = get(kwargs, :max_length, 200)
  default = get(kwargs, :default, nothing)

  max_length = _int_kwarg("URLField", "max_length", max_length; strings = true)   # #614, #646
  max_length < 1 && throw(_fielderr("The max_length must be greater than 0"))

  default = _default_string("URLField", default)     # #612

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
    format_text_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = true`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: VARCHAR(max_length)
- **SQLite Type**: TEXT(max_length)

# Examples
```julia
Race = Models.Model(
    id = IDField(),
    name = CharField(max_length=200),
    slug = SlugField(unique=true, verbose_name="URL Slug")
)
```
"""
function SlugField(; kwargs...)
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
    _common_kwargs("SlugField", kwargs; db_index = true, editable = true, extra = (:max_length,))

  max_length = get(kwargs, :max_length, 50)
  default = get(kwargs, :default, nothing)

  max_length = _int_kwarg("SlugField", "max_length", max_length; strings = true)   # #614, #646
  max_length > 255 && throw(_fielderr("The max_length must be less than or equal to 255"))
  max_length < 1 && throw(_fielderr("The max_length must be greater than 0"))

  default = _default_string("SlugField", default)    # #612

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
    format_text_sql, db_default
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
  db_default::DbDefault
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
- `db_default::Union{String, NamedTuple, Nothing} = nothing`: A database-side expression default, rendered verbatim into the DDL (#496). `"CURRENT_TIMESTAMP"` and `"CURRENT_DATE"` render on both engines; any other expression must name its engine — `(postgres = "now()",)` — and raises `BackendCapabilityError` on the other one rather than emitting DDL it would reject. Mutually exclusive with `default`. Full rules: the *Column defaults* section of the Schema Conventions guide
- `editable::Bool = true`: Whether the field should be editable in forms

# Database Mapping
- **PostgreSQL Type**: JSONB
- **SQLite Type**: TEXT

# Examples
```julia
Race = Models.Model(
    id = IDField(),
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
  (; verbose_name, unique, blank, null, db_index, db_column, editable, db_default) =
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
    format_json_sql, db_default
  )
end

