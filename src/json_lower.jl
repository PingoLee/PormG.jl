# ── Layer 4: JSON lowering for the model graph and the credential types (#643, #649) ─────────
#
# Four rules, shared by every method here. They are written down together because #534 found the
# failure mode: shared rules that live nowhere break one method at a time, and each break
# type-checks.
#
#   1. **Every lowered value is a LEAF.** A `String`, a number, a `Bool`, or a `Dict`/`Vector` of
#      those — never a value that holds a PormG type. This single rule is what closes the defect
#      rather than shrinking it: a path explosion needs an EDGE to traverse, and if nothing returned
#      from here can hold a PormG type, the serializer has no edge left anywhere on the graph.
#   2. **No user payload.** The content is model names, field TYPE names, relation names. All of it
#      is bounded by database identifier limits and none of it is data a user stored. In particular
#      never a `default=`, never rendered SQL, never a memo dict, and never the `connection`.
#   3. **No truncation and no `repr`.** Both are display contracts. In a wire format a truncation
#      marker is indistinguishable from real data, and `repr` is a second escaping grammar that JSON
#      then escapes again. This is why these methods are NOT `sprint(show, x)`, which was the obvious
#      first idea: `show(::PormGField)` renders the constructor call the user typed, so it would put
#      `default=` values into the document, `repr`-escaped and cut at 40 columns
#      (`src/display.jl`, `_d_field_args` / `_d_value`).
#   4. **Read slots with `getfield`.** `Model_Type`, `ObjectHandler` and `PormGRow` all overload
#      `Base.getproperty`, so property access from inside a serializer would run
#      `ensure_model_initialized` or the many-to-many / lazy-traversal dispatch.
#
# ## Why the file exists at all
#
# `JSON.json` reflects over any struct it has no method for. The model graph is a dense cyclic DAG —
# `Model_Type.fields` -> `sForeignKey.to` -> `Model_Type.related_objects` ->
# `ReverseRelation.model_resolved` -> ... . JSON.jl breaks true cycles with an ancestor stack, so it
# terminates, but it memoizes nothing: every distinct PATH through the graph is serialized again,
# which is exponential in the schema's density. Measured on the 14-model F1 fixture, before these
# methods:
#
#   JSON.json(M.Driver)                      2,175,304 chars   3.6 s
#   JSON.json(M.Result.fields["driverid"])   2,158,654 chars          (ONE sForeignKey)
#   JSON.json(a ReverseRelation)             3,087,881 chars          (the worst node)
#   JSON.json(M.Driver.objects)              2,175,569 chars   2.4 s
#   JSON.json(build(query))                  2,177,351 chars
#   JSON.json(M.Driver.fields["surname"])          245 chars          (the control: no model ref)
#
# #641/#642 fixed `PormGRow`, the one a web handler hits by accident. These types have to be typed on
# purpose, which is why they were left to a follow-up rather than folded in.
#
# **The `InstructionObject` arm is not a size fix.** It holds a live `connection`, so reflection
# walks into the pool and out through `connection_string` — measured, the 2.18 MB document above
# contains `password`. `Configuration.redact_secret` exists precisely because that string is a
# secret, and it is applied at every logging site; struct reflection was the same egress with no
# redaction. That arm closes this type's path.
#
# ## The credential family (#649)
#
# #643 closed that leak for the path THROUGH THE MODEL GRAPH, and only that path: `JSON.json` on a
# pool, on a `Settings`, or on `PormG.config` reaches none of the methods above. #649 closes the
# rest, and the two halves are different defects wearing one file:
#
#   * The model-graph methods answer a SIZE. Reverted, they measure megabytes.
#   * The credential methods answer a LEAK, and nothing more. Reverted, they measure 355 characters
#     for a pool and 616 for a `Settings` — so a ceiling assertion passes against completely
#     unpatched code, and only PER-TOKEN ABSENCE discriminates. `test/unit/test_json_serialization.jl`
#     keeps the two case lists separate for exactly that reason.
#
# **These methods emit no connection string at all, not even a redacted one** — the one place this
# file is stricter than `src/display.jl`, which renders `redact_secret(connection_string)` on a
# card. That is not an inconsistency, it is rule 3's display/wire line applied to a secret:
#
#   * A `show` is read by a human who asked for it, at a terminal. "Which database is this pointed
#     at?" is the only reason to type a pool, so the card answers it, redacted.
#   * A JSON document TRAVELS — to a debug endpoint, an error reporter, a log aggregator, a third
#     party. `redact_secret` is a denylist, and a denylist is one unfamiliar DSN dialect away from
#     emitting a password. That is an acceptable risk on a terminal and not on a wire.
#
# A caller who genuinely wants the DSN in a document asks for it:
# `Configuration.redact_secret(pool.connection_string)`, which is public API.
#
# ## Why `PormGRow`'s hook is NOT here
#
# It stays in `src/querybuilder/execution.jl`, beside `_json_row` and `_json_value`. The split is by
# job, not by accident: that method SHAPES DATA — it emits the row's columns, through the one row
# shape `list(:json)` also uses — while everything here BOUNDS THE SCHEMA GRAPH and emits no data at
# all. Moving it would also change its defining module, and the two gates that keep a revert from
# hanging the test runner key on exactly that
# (`test/unit/test_json_serialization.jl`, `test/integration/test_row_and_get.jl`).

# One guarded slot read, shared by every hop below.
function _jl_slot(x, slot::Symbol)
  try
    return getfield(x, slot)
  catch e
    # The two this repo always rethrows. Swallowing an `InterruptException` here would turn a Ctrl-C
    # into a marker reading `"?"` — a wrong answer that looks like a legitimate one.
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    return nothing
  end
end

# `"?"` rather than a throw or a missing key: a marker's job is to be a well-formed leaf naming what
# the value was, and a reader can act on `"?"` where an exception from inside a serializer helps
# nobody. Reachable only from a genuinely incomplete handle — the exact-document tests pin every
# marker's real content, so a renamed slot cannot quietly start answering `"?"` everywhere.
function _jl_name(x, slot::Symbol)
  v = _jl_slot(x, slot)
  v === nothing && return "?"
  return v isa AbstractString ? String(v) : string(v)
end

# Two hops, both guarded the same way — `SQLObjectQuery.model` is typed on an abstract
# (`model::PormGModel`), so a half-built or introspection-time handle is worth surviving.
_jl_query_model(q) = _jl_name(_jl_slot(q, :model), :name)

# A `Bool` slot, kept as a JSON boolean rather than stringified through `_jl_name` — `"false"` and
# `false` are different values to a consumer, and the second is what the slot holds. `nothing` (an
# unreadable slot) stays `nothing`, which is JSON `null`: a missing flag must not read as `false`.
_jl_flag(x, slot::Symbol) = (v = _jl_slot(x, slot); v === nothing ? nothing : v === true)

# A one-key object rather than a bare string, because additive later is cheap and removing is
# breaking: this can grow a second key without breaking a consumer, where a string could not grow at
# all. The `pormg_` prefix is what makes it unmistakably a marker PormG inserted, rather than data a
# consumer could mistake for their own — and it refuses to look like the schema-export API this has
# not promised to be.
JSON.StructUtils.lower(::JSON.JSONStyle, m::Models.Model_Type) =
  Dict("pormg_model" => _jl_name(m, :name))

# On the ABSTRACT type, so EVERY field struct is covered by one method — 25 of them today, and the
# point is that a struct added later cannot reintroduce the dump by forgetting one, so the count is a
# snapshot rather than the claim. (`src/display.jl` makes the same argument for `show` and still says
# 24; it was right when written.) The constructor name, never a slot value: `sCharField` ->
# `CharField`, via the same helper `show` uses — a two-line name strip with no truncation and no user
# data in it, which is the one thing worth sharing with `display.jl`.
JSON.StructUtils.lower(::JSON.JSONStyle, f::Kernel.PormGField) =
  Dict("pormg_field" => _d_field_type_name(f))

# `model_name.fk_field` — "the `pit_stops` model's `driverid` column points at me". Not
# `model_name.binding`, which was the first spelling and reads as a qualified name while actually
# saying the same thing twice (`pit_stops.Pit_stops`): the binding is the Julia const for the same
# model. The FK column is the half that is not already in the other half.
JSON.StructUtils.lower(::JSON.JSONStyle, r::Models.ReverseRelation) =
  Dict("pormg_reverse_relation" => string(_jl_name(r, :model_name), ".", _jl_name(r, :fk_field)))

# Qualified by its owner, because `field_name` alone ("drivers") repeats across models and a marker
# that cannot be told apart from another model's is not identifying anything.
JSON.StructUtils.lower(::JSON.JSONStyle, r::Models.ManyToManyRelation) =
  Dict("pormg_many_to_many" => string(_jl_name(r, :owner_model), ".", _jl_name(r, :field_name)))

JSON.StructUtils.lower(::JSON.JSONStyle, q::QueryBuilder.SQLObjectQuery) =
  Dict("pormg_query" => _jl_query_model(q))

# Delegates to the query it wraps, mirroring `show(::ObjectHandler)` in `src/display.jl`: the handler
# is a one-slot envelope and a reader gains nothing from seeing the envelope named separately.
JSON.StructUtils.lower(s::JSON.JSONStyle, h::QueryBuilder.ObjectHandler) =
  JSON.StructUtils.lower(s, getfield(h, :object))

# The model only. NOT `text` — rendered SQL in a document by default is a surprise — and not the
# memo dicts, and above all not `connection`.
JSON.StructUtils.lower(::JSON.JSONStyle, i::QueryBuilder.InstructionObject) =
  Dict("pormg_instruction" => _jl_query_model(_jl_slot(i, :object)))

# ── The credential family (#649) ─────────────────────────────────────────────

# On `PormGBackend`, the parent of `PormGPostgres` and `PormGSQLite`, so ONE method covers both pool
# structs, the `_PostgresEngine`/`_SQLiteEngine` dispatch markers, every pool-shaped test mock, and
# any pool type added later — the argument the `PormGField` arm above makes, applied to the family
# whose slots are the credential. The label comes from `src/display.jl` so the two serializers agree
# on what to call a backend, the same sharing `_d_field_type_name` already gets.
#
# A one-key marker, and nothing else: not `pool_size`, not `available`, and above all not
# `connection_string` in any form. Every slot left out is a slot that cannot regress into a
# document later.
JSON.StructUtils.lower(::JSON.JSONStyle, b::Kernel.PormGBackend) =
  Dict("pormg_connection" => _d_backend_label(b))

# `Settings` carries real configuration a health check has a legitimate reason to serialize, so this
# is the one marker in the file with a body rather than a name — the issue asked for the non-secret
# fields. Nested under a single `pormg_settings` key to keep the marker convention: a consumer can
# be given another field later, where a bare string could not grow at all.
#
# Two slots are absent, and both are deliberate:
#
#   * `connections` — replaced by the backend label. See the file header for why no DSN travels.
#   * `db_config_settings` — the raw parsed YAML environment block, stored with no copy and no
#     sanitisation. Its documented keys include `password`, `url` (an entire DSN) and
#     `sslkey`/`sslcert`, plus the `pass`/`passwd`/`pwd` aliases and two nested blocks. It is a
#     USER-SUPPLIED dict, so there is nothing to redact it with: `redact_secret` reads a connection
#     string and cannot see a raw `password:` key. An allowlist over it would have to track
#     `VALID_CONNECTION_KEYS` forever, and its one useful value — `adapter` — is already the
#     backend label. Emitting nothing is the answer; do not turn this into a denylist.
#
# Every leaf is a `String`, `Bool` or `nothing`, so rule 1 holds and the `leaves_only` invariant
# test covers this arm unchanged.
function JSON.StructUtils.lower(::JSON.JSONStyle, s::Kernel.PormGSettings)
  conn = _jl_slot(s, :connections)
  return Dict("pormg_settings" => Dict{String, Any}(
    "app_env"       => _jl_name(s, :app_env),
    "db_def_folder" => _jl_name(s, :db_def_folder),
    "model_file"    => _jl_name(s, :model_file),
    "time_zone"     => _jl_name(s, :time_zone),
    # `nothing` is a legitimate value here, not a missing slot, so it lowers to JSON `null` rather
    # than to `_jl_name`'s `"?"` — the marker for a slot that could not be read at all.
    "django_prefix" => (v = _jl_slot(s, :django_prefix); v === nothing ? nothing : string(v)),
    "change_db"     => _jl_flag(s, :change_db),
    "change_data"   => _jl_flag(s, :change_data),
    "implicit"      => _jl_flag(s, :implicit),
    "connection"    => conn === nothing ? nothing : _d_backend_label(conn),
  ))
end
