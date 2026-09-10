# ── Layer 4: REPL display (#534) ─────────────────────────────────────────────
#
# Every `Base.show` PormG defines for a MODEL-BEARING type lives here, in one file, because the
# rules they share are the whole point and are easy to break one method at a time:
#
#   1. **A `show` never throws.** A display method that raises poisons the REPL for every value
#      printed afterwards, including the exception you were trying to read. Anything that could
#      fail on a half-built or introspected object is guarded and degrades to a shorter rendering.
#   2. **A `show` never takes a connection.** `show_query`/`inspect_query` reach `get_settings`,
#      which checks a connection out of the pool. Typing a variable name at the REPL must not do
#      that — see *Query display* below.
#   3. **A `show` reads slots with `getfield`.** `Model_Type`, `ObjectHandler` and `PormGRow` all
#      overload `Base.getproperty` (`src/querybuilder/object_manager.jl`, `src/querybuilder/types.jl`);
#      `m.objects` from inside a display call would run `ensure_model_initialized`, and `row.x`
#      would run the many-to-many/lazy-traversal dispatch.
#
# ## Why the file exists at all
#
# Julia's `show_default` walks a struct's slots with the **2-argument** `show(io, x)`. PormG's model
# graph is cyclic and total: `Model_Type.fields` holds an `sForeignKey`, whose `.to` is another
# `Model_Type`, whose `related_objects` hold a `ReverseRelation`, whose `model_resolved` is another
# `Model_Type`. With no 2-arg method anywhere on that cycle, printing ANY handle serialized the
# entire schema. Measured on the 14-model F1 fixture before this file existed: `M.Driver` rendered
# 1,623,608 characters on one line, a single `PormGRow` 1,623,696, a filtered query 1,356,112. The
# `sCharField` control came out at 146 — the one struct in the group holding no model reference.
#
# The corollary is what makes the fix cheap: because `show_default` calls the 2-arg method, a
# one-line `show` on `Model_Type` and on `PormGField` bounds the output of every container that
# holds one, whether or not that container has a method here.
#
# ## Query display: structural, never a database round-trip
#
# Django's `QuerySet.__repr__` executes the query and prints the first rows. PormG deliberately does
# not: that would make typing a variable name open a pooled connection and hit the database — a
# hidden side effect inside a display call, which the *prefer less magic than Django* half of the
# design stance exists to refuse, and which sits badly with the async-first contract. Ecto's
# `Inspect` implementation prints the query rather than the rows, and SQLAlchemy's `str()` gives SQL
# only when you ask for it. `show(::ObjectHandler)` therefore renders structure and NAMES the
# explicit escapes (`.list()`, `show_query(q)`) instead of performing them.

# ── Shared primitives ────────────────────────────────────────────────────────

# Hard ceiling for any single rendered fragment. Everything user-supplied — a column name from an
# introspected schema, a filter value, a default — passes through here, so no one value can blow up
# a line however pathological the source data is.
#
# Measured in `textwidth`, not `length`: the callers below pad columns with `rpad`, which is
# width-based, so truncating by codepoint count lets a CJK name 20 characters long occupy 40 columns
# and blow the alignment it was supposed to protect.
# Bounded twice, and the second bound is not belt-and-braces — it is the fix for a measured stall.
#
# Width alone is not a bound on WORK, because `textwidth` is **zero** for newline, tab, NUL and
# combining marks. A `TextField` holding `"\n"^1_000_000` has textwidth 0, so a `textwidth(s) <= n`
# early return handed the whole megabyte back and `repr` then escaped all of it: measured at 3.8 s
# for one 20-row `list()`, over this file's own timing budget by 3.7x. Merely *measuring*
# `textwidth(s)` is O(len) too, so even the guard was proportional to the data.
#
# So both passes stop at `n` display columns OR `4n` characters, whichever comes first, and neither
# ever converts or scans more than that. `4n` because nothing legible needs four characters per
# column; a longer run is combining marks or control characters, which is exactly the case above.
function _d_trunc(s::AbstractString, n::Integer)
  n = Int(n)
  n <= 0 && return ""
  charcap = 4n

  # Pass 1 — does the whole thing fit? Bounded, so a huge string exits after `charcap` characters
  # rather than being measured end to end.
  w = 0
  i = 0
  fits = true
  for c in s
    w += textwidth(c)
    i += 1
    if w > n || i > charcap
      fits = false
      break
    end
  end
  fits && return String(s)

  # Pass 2 — keep `n - 1` columns and mark the cut. The `i >= charcap` guard is what stops a run of
  # zero-width characters from looping to the end of a megabyte while `w` never advances.
  out = IOBuffer()
  w = 0
  i = 0
  for c in s
    cw = textwidth(c)
    (w + cw > n - 1 || i >= charcap) && break
    print(out, c)
    w += cw
    i += 1
  end
  return String(take!(out)) * "…"
end

# ── Bounded rendering ────────────────────────────────────────────────────────
#
# Truncating the RESULT of `show` bounds the characters printed; it does not bound the work done to
# produce them. That distinction is not academic — measured on this file's first two versions, all
# rendering under 90 characters of output:
#
#                                                    v1        v2 (width guard)   now
#     PormGRow, 1 MB BinaryField cell                730 ms    0.07 ms            0.07 ms
#     PormGRow, 1 MB text cell                       —         0.11 ms            0.06 ms
#     PormGRow, 1 MB of newlines                     —         3,804 ms           0.01 ms
#     PormGRow, 1 MB of tabs                         —         3,697 ms           0.01 ms
#     20 such rows (a `list()`)                      11,045 ms —                  1.81 ms
#     filter("id__@in" => collect(1:1_000_000))      177 ms    —                  0.08 ms
#
# v1 used `sprint(show, x)`, which materialized the entire rendering and then threw all but 40
# characters away, so a display was as expensive as the data behind it. That is the ORIGINAL defect
# wearing different clothes — a REPL that stalls for eleven seconds is unusable whether or not it
# also floods.
#
# v2 added the cap below but guarded the STRING arm by display width, and `textwidth` is **zero** for
# newline, tab, NUL and combining marks: a text column full of them measured 0 columns wide at any
# length and was handed to `repr` whole. Hence the character bound in `_d_trunc` above — the two
# bounds are not redundant, they cover different inputs, and the second one is the one a real ETL
# payload hits.
#
# `_d_render` bounds the work instead: it writes into an IO that refuses more than `cap` bytes and
# aborts the walk the moment it is full. Structural rather than per-type — it holds for a value type
# this file has never heard of, which is the property `:limit => true` alone cannot give (that flag
# is honoured by `Base`'s array and dict `show` methods, and by nothing a downstream package
# defines). It sets `:limit` too, so the built-in methods elide early and the abort is rarely
# reached.
struct _DFull <: Exception end

mutable struct _DCapIO <: IO
  buf::IOBuffer
  cap::Int
end

# Enough of the `IO` interface that a `show` method probing the stream gets an answer instead of a
# `MethodError`. Without these, a downstream `show` calling `position`/`isopen` would raise inside
# `_d_render`, be swallowed by its catch, and degrade the rendering SILENTLY — the failure mode is
# the problem, not the failure. `write`/`unsafe_write` are the cap; the rest forward to the buffer.
Base.iswritable(::_DCapIO) = true
Base.isreadable(::_DCapIO) = false
Base.isopen(::_DCapIO) = true
Base.position(io::_DCapIO) = position(io.buf)
Base.flush(::_DCapIO) = nothing

function Base.write(io::_DCapIO, b::UInt8)
  io.buf.size >= io.cap && throw(_DFull())
  return write(io.buf, b)
end

function Base.unsafe_write(io::_DCapIO, p::Ptr{UInt8}, n::UInt)
  room = io.cap - io.buf.size
  room <= 0 && throw(_DFull())
  # The partial chunk is DROPPED rather than written: writing it is what splits a multi-byte UTF-8
  # character across the cap and leaves the buffer holding an invalid `String`. Dropping costs at
  # most the tail of one already-truncated fragment. (`write(io, ::Char)` still goes byte by byte
  # through the method above, so `_d_valid_prefix` below is still needed.)
  n > room && throw(_DFull())
  return unsafe_write(io.buf, p, n)
end

# The cap can still land mid-character via the byte-at-a-time path, which leaves a `String` that is
# not valid UTF-8. Nothing downstream tolerates that as a guarantee, so trim to the last whole
# character. Bounded by `cap`, so this is a few hundred bytes at worst.
function _d_valid_prefix(s::String)
  isvalid(s) && return s
  out = IOBuffer()
  for c in s
    isvalid(c) || break
    print(out, c)
  end
  return String(take!(out))
end

# Render `x` with `show`, spending at most `cap` bytes of work. `cap` is generous relative to the
# `_d_trunc` width that follows, so a multi-byte or escaped rendering still has room to reach the
# characters that survive.
function _d_render(x, cap::Integer = 400)
  io = _DCapIO(IOBuffer(), Int(cap))
  cut = false
  try
    show(IOContext(io, :compact => true, :limit => true), x)
  catch e
    # `InterruptException`/`StackOverflowError` escape: a display long enough to be worth Ctrl-C is
    # exactly the case this section exists for. Everything else is either the cap (content WAS
    # dropped) or a broken `show` on the VALUE — not on PormG's types — which rule 1 says may not
    # reach the REPL. Both leave an incomplete rendering, so both get the marker.
    #
    # These two were the wrong way round once: `e isa _DFull || return … * "…"` short-circuited on
    # the cap — the one case where content is definitely missing — and returned it unmarked.
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    cut = true
  end
  s = _d_valid_prefix(String(take!(io.buf)))
  return cut ? s * "…" : s
end

# Join `items`, keeping at most `cap` of them and reporting the remainder. Used for every unbounded
# collection on a card (fields, filters, projections, reverse accessors) so width stays a property
# of the renderer rather than of the schema.
function _d_join_capped(items, cap::Integer; sep::AbstractString = ", ")
  items = collect(items)
  length(items) <= cap && return join(items, sep)
  return join(view(items, 1:Int(cap)), sep) * sep * "+$(length(items) - Int(cap)) more"
end

# The constructor name a user would have typed, recovered from the struct name: `sCharField` →
# `CharField`. Same `x[2:end]` idiom as `Models._model_to_str` and the `LazyTraversalError` message
# in `types.jl` — the `s` prefix marks the storage struct, never the public constructor.
function _d_field_type_name(f)
  n = String(nameof(typeof(f)))
  return startswith(n, "s") ? n[2:end] : n
end

# A function slot (`on_delete`, `formatter`) renders as its name, not as its type. `nameof` does NOT
# throw on an anonymous function — it answers `Symbol("#7")` — so the guard is for a callable whose
# `nameof` is genuinely undefined, and an anonymous `on_delete` renders as its gensym rather than
# reaching the fallback.
_d_func_name(f::Function) = try String(nameof(f)) catch e; (e isa InterruptException || e isa StackOverflowError) && rethrow(); "#anonymous" end
_d_func_name(::Nothing) = "nothing"

# One slot value, short. Every arm ends at a bounded leaf, and — since the `_d_render` note above —
# in bounded WORK as well: the string arm truncates BEFORE `repr` rather than after, because `repr`
# on a 4 MB text column is the same stall as `show` on a 4 MB blob.
_d_value(x::AbstractString) = _d_trunc(repr(_d_trunc(String(x), 40)), 40)
_d_value(x::Function) = _d_func_name(x)
_d_value(x::Models.Model_Type) = repr(_d_trunc(getfield(x, :name), 40))
_d_value(x) = _d_trunc(_d_render(x), 40)

# ── Models.Model_Type ────────────────────────────────────────────────────────

# The 2-arg method. This is the one that bounds every container: `show_default` on
# `SQLObjectQuery`, `PathJoin`, `AliasJoin`, `ReverseRelation` and `PormGRow` reaches a model
# through it, so those types need no method of their own to stop dumping the schema.
function Base.show(io::IO, m::Models.Model_Type)
  n = length(getfield(m, :fields))
  print(io, "Model(", repr(getfield(m, :name)), ", ", n, " field", n == 1 ? "" : "s", ")")
end

# The card: what you get when you type `M.Driver` at the REPL.
function Base.show(io::IO, ::MIME"text/plain", m::Models.Model_Type)
  name       = getfield(m, :name)
  db_table   = getfield(m, :db_table)
  fields     = getfield(m, :fields)
  order      = getfield(m, :field_names)
  reverse    = getfield(m, :related_objects)
  connect    = getfield(m, :connect_key)

  print(io, "PormG model · ", name)
  # Only when it differs: repeating `tb_driver (tb_driver)` on every model is noise, and the whole
  # reason `db_table` exists (#59) is the case where it does NOT match.
  db_table !== nothing && db_table != name && print(io, " → table ", repr(db_table))
  connect !== nothing && print(io, " · db ", repr(connect))
  println(io)

  # `field_names` is the deterministic order the query builder uses, and it is the ORDER — but it is
  # NOT the membership. It is documented as "the subset that owns a real column", and `Model(...)`
  # fills it with `!is_many_to_many_field(field) && push!(...)` (`Models.jl:2146`), so a
  # `ManyToManyField` is in `fields` and never in `field_names`.
  #
  # Iterating `field_names` alone therefore DROPPED every m2m field from the card — silently, with no
  # `⋮ N more` to hint at it, while the compact `show` above counted `length(fields)` and reported a
  # number the card could not account for. The forward accessor (`row.tags`) was invisible while its
  # reverse half showed up on the other model's `reverse:` line.
  #
  # So: `field_names` for order, then whatever else `fields` holds, sorted. Anything the vector does
  # not name still appears, which also covers a `field_names` gone stale against `fields`.
  # `seen` dedupes BOTH halves: `field_names` is a plain vector with nothing stopping a duplicate
  # entry, and one listed the same field twice on the card while the compact `show` counted it once.
  seen = Set{String}()
  names = String[]
  for n in order
    k = String(n)
    haskey(fields, k) && !(k in seen) && (push!(names, k); push!(seen, k))
  end
  append!(names, sort!(String[k for k in keys(fields) if !(k in seen)]))

  # Fit the field table to the terminal when the REPL asked for a limited display (`:limit` is what
  # `display` sets; a `sprint`/`repr` call does not, and then nothing is elided).
  cap = if get(io, :limit, false)
    max(displaysize(io)[1] - 6, 5)
  else
    typemax(Int)
  end
  shown = min(length(names), cap)

  namew = isempty(names) ? 0 : min(maximum(textwidth, view(names, 1:shown)), 28)
  typew = 0
  rendered = Vector{Tuple{String,String,String}}(undef, shown)
  for i in 1:shown
    fname = names[i]
    f = fields[fname]
    tname = _d_field_type_name(f)
    typew = max(typew, textwidth(tname))
    rendered[i] = (fname, tname, _d_field_detail(fname, f))
  end
  typew = min(typew, 22)

  for (fname, tname, detail) in rendered
    print(io, "  ", rpad(_d_trunc(fname, namew), namew), "  ", rpad(_d_trunc(tname, typew), typew))
    isempty(detail) || print(io, "  ", detail)
    println(io)
  end
  shown < length(names) && println(io, "  ⋮ ", length(names) - shown, " more field", length(names) - shown == 1 ? "" : "s")

  if !isempty(reverse)
    println(io, "  reverse: ", _d_join_capped(sort!(collect(keys(reverse))), 6))
  end
  print(io, "  query: ", name, ".objects.filter(…)")
end

# ── PormGField ───────────────────────────────────────────────────────────────

# Defined on the ABSTRACT type, so all 24 field structs are covered by one method — and so a field
# struct added later cannot reintroduce the dump by forgetting to add one.
function Base.show(io::IO, f::Kernel.PormGField)
  print(io, _d_field_type_name(f))
  # Guarded per rule 1: a field carrying an introspected value this renderer did not anticipate must
  # still print its TYPE. Degrading to `CharField(…)` is a worse display; raising here would break
  # every later value in the session.
  args = try _d_field_args(f) catch e; (e isa InterruptException || e isa StackOverflowError) && rethrow(); nothing end
  args === nothing ? print(io, "(…)") : print(io, "(", _d_join_capped(args, 6), ")")
end

# The relational fields are rendered from a fixed slot list rather than by diffing against a
# default-constructed instance (below), for one reason: their constructors REQUIRE the target
# (`ForeignKey(to; …)`), so producing a default means calling `ForeignKey("")` — construction of a
# throwaway, inside a display method, on a code path whose validation is free to warn or throw. The
# slots that matter for a relation are few and stable enough to name.
function _d_field_args(f::Models.sForeignKey)
  args = String[_d_value(getfield(f, :to))]
  _d_push_relational_args!(args, f)
  return args
end
function _d_field_args(f::Models.sOneToOneField)
  args = String[_d_value(getfield(f, :to))]
  _d_push_relational_args!(args, f)
  return args
end
function _d_field_args(f::Models.sManyToManyField)
  args = String[_d_value(getfield(f, :to))]
  for slot in (:through, :related_name, :db_table, :source_field, :target_field)
    hasfield(typeof(f), slot) || continue
    v = getfield(f, slot)
    v === nothing && continue
    push!(args, "$slot=$(_d_value(v))")
  end
  return args
end

function _d_push_relational_args!(args::Vector{String}, f)
  od = getfield(f, :on_delete)
  od === nothing || push!(args, "on_delete=" * _d_func_name(od))
  for slot in (:related_name, :db_column, :how)
    hasfield(typeof(f), slot) || continue
    v = getfield(f, slot)
    v === nothing && continue
    push!(args, "$slot=$(_d_value(v))")
  end
  for slot in (:null, :unique, :primary_key)
    hasfield(typeof(f), slot) && getfield(f, slot) === true && push!(args, "$slot=true")
  end
  return args
end

# Every non-relational field renders as the difference from a default-constructed instance of its
# own type — so it prints as the constructor call the user would have typed, and a slot added later
# is covered without editing this file. Same idea as `Models._model_to_str_general`, which already
# calls the zero-argument constructor of exactly these types on the code-generation path, so the
# construction is known to be quiet and cheap.
function _d_field_args(f::Kernel.PormGField)
  default = _d_field_default(typeof(f))
  args = String[]
  for slot in fieldnames(typeof(f))
    # `formatter` is a function slot fixed by the field type, `type` is the rendered SQL type
    # derived from it — neither is something a user sets, and both are noise on every line.
    slot === :formatter && continue
    slot === :type && continue
    v = getfield(f, slot)
    default === nothing || v != getfield(default, slot) || continue
    push!(args, "$slot=$(_d_value(v))")
  end
  return args
end

# One default instance per field type, built once. `IdDict` keyed by the concrete type; the lock
# keeps two threads from racing the constructor, which is cheap but not documented as reentrant.
const _D_FIELD_DEFAULTS = IdDict{DataType,Any}()
const _D_FIELD_DEFAULTS_LOCK = ReentrantLock()

function _d_field_default(T::DataType)
  lock(_D_FIELD_DEFAULTS_LOCK) do
    get!(_D_FIELD_DEFAULTS, T) do
      name = String(nameof(T))
      ctor_name = Symbol(startswith(name, "s") ? name[2:end] : name)
      isdefined(Models, ctor_name) || return nothing
      # `nothing` on any failure means "render every slot" rather than "render none": a field whose
      # constructor moved is still worth displaying, just more verbosely.
      try
        return getfield(Models, ctor_name)()
      catch e
        (e isa InterruptException || e isa StackOverflowError) && rethrow()
        return nothing
      end
    end
  end
end

# The right-hand column of the model card. NOT `_d_field_args` minus the type name: browsing a model
# is the `\d <table>` question ("what is this column in the database?"), not the "what did I type?"
# question `show(::PormGField)` answers. So it leads with the RENDERED SQL type and the schema flags
# a reader scans for, and the declaration form stays on the field's own one-line `show`.
#
# Concretely, this is the difference between a card whose every CharField line reads `CharField()` —
# true, and useless — and one that reads `VARCHAR(250)  null`.
function _d_field_detail(fname::AbstractString, f::Kernel.PormGField)
  try
    parts = String[]

    # A many-to-many owns NO column, and its `type` slot holds the sentinel `"MANYTOMANY"`. Printing
    # that in the SQL-type position asserts a column type for a field the table does not have — on a
    # card whose whole premise is "the column as the database holds it". It says where it points and
    # through what instead; the join table is the physical thing, and it is what a reader needs.
    sqltype = if Models.is_many_to_many_field(f)
      ""
    elseif hasfield(typeof(f), :type)
      String(getfield(f, :type))
    else
      ""
    end
    # The declared length belongs with the type, the way the database reports it.
    if hasfield(typeof(f), :max_length) && getfield(f, :max_length) isa Integer
      sqltype *= "($(getfield(f, :max_length)))"
    elseif hasfield(typeof(f), :max_digits) && getfield(f, :max_digits) isa Integer
      dp = hasfield(typeof(f), :decimal_places) ? getfield(f, :decimal_places) : nothing
      sqltype *= dp isa Integer ? "($(getfield(f, :max_digits)),$(dp))" : "($(getfield(f, :max_digits)))"
    end
    isempty(sqltype) || push!(parts, sqltype)

    # A relation says where it points before it says anything else.
    if hasfield(typeof(f), :to)
      to = getfield(f, :to)
      target = to isa Models.Model_Type ? getfield(to, :name) : (to === nothing ? "?" : String(to))
      pkf = hasfield(typeof(f), :pk_field) ? getfield(f, :pk_field) : nothing
      push!(parts, "→ " * _d_trunc(target, 28) * (pkf === nothing ? "" : "." * String(pkf)))
      od = hasfield(typeof(f), :on_delete) ? getfield(f, :on_delete) : nothing
      od === nothing || push!(parts, _d_func_name(od))
    end

    hasfield(typeof(f), :primary_key) && getfield(f, :primary_key) === true && push!(parts, "pk")
    hasfield(typeof(f), :null) && getfield(f, :null) === true && push!(parts, "null")
    hasfield(typeof(f), :unique) && getfield(f, :unique) === true && push!(parts, "unique")
    hasfield(typeof(f), :db_index) && getfield(f, :db_index) === true && push!(parts, "index")
    if hasfield(typeof(f), :default) && getfield(f, :default) !== nothing
      push!(parts, "default=" * _d_value(getfield(f, :default)))
    end
    # Only when it actually renames something — `db_column` equal to the field name is the norm and
    # says nothing (#317).
    if hasfield(typeof(f), :db_column)
      dbc = getfield(f, :db_column)
      dbc isa AbstractString && dbc != fname && push!(parts, "column=" * repr(String(dbc)))
    end

    return _d_join_capped(parts, 6; sep = "  ")
  catch e
    # Rule 1: a card that loses one column's detail beats a REPL that cannot print the model.
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    return ""
  end
end

# ── Relations ────────────────────────────────────────────────────────────────

# `model_resolved` is a full model; without this method a reverse accessor rendered 2,310,027
# characters — the worst of the group, because it reaches the child model AND is itself reached
# from every parent.
function Base.show(io::IO, r::Models.ReverseRelation)
  print(io, "ReverseRelation(", getfield(r, :model_name), ".", getfield(r, :fk_field),
        " → ", getfield(r, :target_pk), ")")
end

function Base.show(io::IO, r::Models.ManyToManyRelation)
  print(io, "ManyToManyRelation(", repr(getfield(r, :field_name)), " via ", repr(getfield(r, :through_table)), ")")
end

function Base.show(io::IO, d::QueryBuilder.ManyToManyDescriptor)
  print(io, "ManyToManyDescriptor(", repr(_d_m2m_accessor(d)), ")")
end
# Read through `getfield` and tolerate a renamed slot: this descriptor is constructed in two places
# and a display method is not worth coupling to its layout.
function _d_m2m_accessor(d)
  for slot in (:accessor, :field_name, :name)
    hasfield(typeof(d), slot) && return String(getfield(d, slot))
  end
  return "?"
end

# ── Query objects ────────────────────────────────────────────────────────────

# `SQLObjectQuery.model` and `AliasJoin.target` are typed `PormGModel`, and `Model_Type` is its sole
# concrete subtype today — but "today" is not a bound. The fallback goes through `_d_trunc` rather
# than bare `string(m)`, which would call `show` on an unknown model type and reintroduce exactly the
# unbounded rendering this file exists to prevent.
_d_model_name(m::Models.Model_Type) = getfield(m, :name)
_d_model_name(m) = _d_trunc(_d_render(m), 40)

# Column/label rendering for the query card. Each of these can hold a model or a nested handler, so
# every arm ends at a bounded leaf.
_d_col(x::AbstractString) = _d_trunc(String(x), 40)
_d_col(x::QueryBuilder.SQLField) = _d_col(getfield(x, :field))
_d_col(x::QueryBuilder.FObject) = string(getfield(x, :function_name), "(", _d_col(getfield(x, :column)), ")")
_d_col(x::Vector) = _d_join_capped((_d_col(v) for v in x), 3)
_d_col(x) = _d_trunc(_d_render(x), 40)

# A filter term as close to what the caller typed as the parsed form allows.
_d_filter(x::QueryBuilder.OperObject) =
  string(_d_col(getfield(x, :column)),
         getfield(x, :operator) == "=" ? " => " : " $(getfield(x, :operator)) ",
         _d_value(getfield(x, :values)))
_d_filter(x::QueryBuilder.QObject) = "Q(" * _d_join_capped((_d_filter(v) for v in getfield(x, :filters)), 4) * ")"
_d_filter(x::QueryBuilder.QorObject) = "Qor(" * _d_join_capped((_d_filter(v) for v in getfield(x, :or)), 4; sep = " | ") * ")"
_d_filter(x) = _d_trunc(_d_render(x, 600), 60)

# The OUTPUT COLUMN NAME of a projection — the name the row/DataFrame will actually carry.
#
# `custom_as` before `_as`, which is not a preference: it is the rule `_reject_duplicate_projection_names`
# already enforces (`object_manager.jl`, #441), and the two must agree or the card names columns the
# result does not have. The split is real — `values("year" => "raceid__year")` puts the alias in
# `custom_as` and leaves the PATH in `_as`, while `values("max" => Max("points"))` puts the alias in
# `_as` — so reading `_as` alone renders `raceid__year` for a column that comes back as `year`.
# `!== nothing`, NOT `!isempty`: the #441 rule is `custom_as !== nothing ? custom_as : _as`, and
# `values("" => "surname")` is accepted today — an EMPTY alias. Skipping it here fell through to
# `_as` and named the column `surname`, while the rule names it `""`. Divergence on the one input
# the comment above promises agreement on.
function _d_projection(v)
  for slot in (:custom_as, :_as)
    hasfield(typeof(v), slot) || continue
    as = getfield(v, slot)
    as isa AbstractString && return _d_trunc(as, 40)
  end
  hasfield(typeof(v), :field) && return _d_col(getfield(v, :field))
  hasfield(typeof(v), :column) && return _d_col(getfield(v, :column))
  return _d_trunc(_d_render(v), 40)
end

function Base.show(io::IO, q::QueryBuilder.SQLObjectQuery)
  model = getfield(q, :model)
  print(io, "Query(", repr(_d_model_name(model)))
  nf = length(getfield(q, :filter))
  nv = length(getfield(q, :values))
  nf == 0 || print(io, ", ", nf, " filter", nf == 1 ? "" : "s")
  nv == 0 || print(io, ", ", nv, " value", nv == 1 ? "" : "s")
  print(io, ")")
end

Base.show(io::IO, h::QueryBuilder.ObjectHandler) = show(io, getfield(h, :object))

function Base.show(io::IO, ::MIME"text/plain", h::QueryBuilder.ObjectHandler)
  q     = getfield(h, :object)
  model = getfield(q, :model)
  name  = _d_model_name(model)

  print(io, "PormG query · ", name)
  if model isa Models.Model_Type
    db_table = getfield(model, :db_table)
    db_table !== nothing && db_table != name && print(io, " (", db_table, ")")
  end
  ck = getfield(q, :connect_key)
  ck === nothing || print(io, " · db ", repr(ck))
  println(io)

  # `lbl` keeps the clause column aligned without a second pass over the clauses.
  lbl(k) = "  " * rpad(k, 9) * " "

  filters = getfield(q, :filter)
  isempty(filters) || println(io, lbl("filter"), _d_join_capped((_d_filter(f) for f in filters), 6))

  vals = getfield(q, :values)
  isempty(vals) || println(io, lbl("values"), _d_join_capped((_d_projection(v) for v in vals), 8))

  ins = getfield(q, :insert)
  isempty(ins) || println(io, lbl("set"), _d_join_capped(("$k=$(_d_value(v))" for (k, v) in ins), 6))

  ord = getfield(q, :order)
  isempty(ord) || println(io, lbl("order_by"),
    _d_join_capped((string(getfield(o, :orientation) == "DESC" ? "-" : "", _d_col(getfield(o, :field))) for o in ord), 6))

  # No `group_by` line: `SQLObjectQuery.group` and `.having` have NO writer anywhere in `src/` —
  # every `push!` targets the per-build `SQLInstruction` instead (`build_query.jl:42,52,314`), and
  # the query object's own slots appear only inside `deepcopy` (`types.jl:473`). A clause line for
  # them would be dead code that reads as coverage. Grouping is derived at build time from the
  # projection, so the `values` line above is where an aggregating query shows itself.

  ctes = getfield(q, :ctes)
  isempty(ctes) || println(io, lbl("with"), _d_join_capped(sort!(collect(keys(ctes))), 6))

  joins = collect(keys(getfield(q, :custom_join)))
  append!(joins, keys(getfield(q, :alias_join)))
  isempty(joins) || println(io, lbl("cjoin"), _d_join_capped(joins, 6))

  # `limit == 0` is PormG's NO-LIMIT sentinel (`build_helpers.jl`: `has_limit = …limit != 0`), while
  # in SQL `LIMIT 0` means zero rows. Rendering the sentinel printed `limit 0, offset 25` for an
  # offset-only query — a limit the query does not have, spelled as the one value that would mean
  # something else. Each half is now printed only when it is set.
  lim, off = getfield(q, :limit), getfield(q, :offset)
  if lim != 0 || off != 0
    parts = String[]
    lim == 0 || push!(parts, "limit $(lim)")
    off == 0 || push!(parts, "offset $(off)")
    println(io, lbl("page"), join(parts, ", "))
  end
  getfield(q, :distinct) && println(io, lbl("distinct"), "true")
  getfield(q, :for_update) === nothing || println(io, lbl("lock"), "select_for_update")

  # The closing hint is the whole reason this method refuses to touch the database: it names the
  # two calls that legitimately do, instead of performing either.
  print(io, "  not executed — .list() · .count() · DataFrame(q) · SQL: show_query(q)")
end

# `PathJoin.field` holds a `PormGField` and `AliasJoin.target` a full model, so both were part of
# the dump. Their own methods (rather than relying on the field/model methods alone) keep a query
# card's `cjoin` line readable.
function Base.show(io::IO, p::QueryBuilder.PathJoin)
  f = getfield(p, :field)
  print(io, "PathJoin(", f === nothing ? "on-only" : _d_field_type_name(f))
  jt = getfield(p, :join_type)
  jt === nothing || print(io, ", ", jt)
  nfil = length(getfield(p, :filters))
  nfil == 0 || print(io, ", ", nfil, " ON predicate", nfil == 1 ? "" : "s")
  print(io, ")")
end

function Base.show(io::IO, a::QueryBuilder.AliasJoin)
  t = getfield(a, :target)
  print(io, "AliasJoin(", repr(_d_model_name(t)),
        ", ", getfield(a, :join_type), ", ", length(getfield(a, :filters)), " ON)")
end

Base.show(io::IO, f::QueryBuilder.SQLField) = print(io, "SQLField(", _d_col(getfield(f, :field)), ")")

function Base.show(io::IO, o::QueryBuilder.SQLOrder)
  print(io, "SQLOrder(", _d_col(getfield(o, :field)), " ", getfield(o, :orientation))
  n = getfield(o, :nulls)
  n === nothing || print(io, " NULLS ", uppercase(String(n)))
  print(io, ")")
end

# ── PormGRow ─────────────────────────────────────────────────────────────────

# The severe case: `_model` is a full model, and `Vector` display calls the 2-arg `show` once per
# element — so a 100-row `list()` rendered ~160 MB before this method existed. There is deliberately
# NO method for `Vector{PormGRow}`: standard Julia vector display, one compact row per line, is
# bounded, idiomatic, and honours `:limit` on its own. `DataFrame(q)` is the tabular view.
function Base.show(io::IO, row::PormGRow)
  data = getfield(row, :_data)
  model = getfield(row, :_model)
  print(io, "Row(", model isa Models.Model_Type ? getfield(model, :name) : "?", ": ")
  print(io, _d_join_capped(("$k=$(_d_value(v))" for (k, v) in _d_row_pairs(data, model)), 6))
  print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", row::PormGRow)
  data = getfield(row, :_data)
  model = getfield(row, :_model)
  println(io, "PormG row · ", model isa Models.Model_Type ? getfield(model, :name) : "?",
          " · ", length(data), " column", length(data) == 1 ? "" : "s")
  pairs_ = _d_row_pairs(data, model)
  isempty(pairs_) && return print(io, "  (no columns projected)")
  w = min(maximum(p -> textwidth(String(first(p))), pairs_), 28)
  # `join` rather than a loop with a last-element branch: the card must not end in a newline, which
  # the REPL would render as a blank line under every row.
  print(io, join(("  " * rpad(_d_trunc(String(k), w), w) * "  " * _d_value(v) for (k, v) in pairs_), "\n"))
end

# `_data` is a `Dict`, so its iteration order is hash order and a row would render its columns in a
# different order than the `values(...)` call that produced it — and differently again on the next
# session. Sort by name for determinism, with the primary key first because that is the column a
# reader looks for.
function _d_row_pairs(data::Dict{Symbol,Any}, model)
  ks = sort!(collect(keys(data)); by = String)
  pkname = _d_pk_name(model)
  if pkname !== nothing
    i = findfirst(==(pkname), ks)
    if i !== nothing
      pk = ks[i]
      deleteat!(ks, i)
      pushfirst!(ks, pk)
    end
  end
  return [(k, data[k]) for k in ks]
end

# `fields` is a `Dict`, so iterating it to find the primary key would pick a different winner per
# session on the (legal) model that marks two columns `primary_key`. Sorted keys make the choice
# deterministic — a display that reorders itself between runs is its own small defect.
function _d_pk_name(model)
  model isa Models.Model_Type || return nothing
  fields = getfield(model, :fields)
  for fname in sort!(collect(keys(fields)))
    f = fields[fname]
    hasfield(typeof(f), :primary_key) && getfield(f, :primary_key) === true && return Symbol(fname)
  end
  return nothing
end
