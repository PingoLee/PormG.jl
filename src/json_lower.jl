# ── Layer 4: JSON lowering for the model graph (#643) ────────────────────────
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
# redaction. That arm closes this type's path. It does NOT close the others — `JSON.json` on a pool,
# on a `Settings`, or on `PormG.config` never touches the model graph and so reaches none of these
# methods. That is a separate issue, deliberately not fixed here.
#
# ## Why `PormGRow`'s hook is NOT here
#
# It stays in `src/querybuilder/execution.jl`, beside `_json_row` and `_json_value`. The split is by
# job, not by accident: that method SHAPES DATA — it emits the row's columns, through the one row
# shape `list(:json)` also uses — while everything here BOUNDS THE SCHEMA GRAPH and emits no data at
# all. Moving it would also change its defining module, and the two gates that keep a revert from
# hanging the test runner key on exactly that
# (`test/unit/test_json_serialization.jl`, `test/integration/test_row_and_get.jl`).

# The model name, defensively. Rule-1 content is one `getfield` away in every case, but a
# `SQLObjectQuery` reaches it in two hops through a slot typed on an abstract (`model::PormGModel`),
# so a half-built or introspection-time handle is worth surviving rather than asserting. `"?"` keeps
# the document well-formed and the key present, which is what a reader needs from a marker.
function _jl_name(x, slot::Symbol)
  try
    v = getfield(x, slot)
    v === nothing && return "?"
    return v isa AbstractString ? String(v) : string(v)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    return "?"
  end
end

_jl_query_model(q) = _jl_name(try getfield(q, :model) catch; nothing end, :name)

# A one-key object rather than a bare string, because additive later is cheap and removing is
# breaking: this can grow a second key without breaking a consumer, where a string could not grow at
# all. The `pormg_` prefix is what makes it unmistakably a marker PormG inserted, rather than data a
# consumer could mistake for their own — and it refuses to look like the schema-export API this has
# not promised to be.
JSON.StructUtils.lower(::JSON.JSONStyle, m::Models.Model_Type) =
  Dict("pormg_model" => _jl_name(m, :name))

# On the ABSTRACT type, so all 24 field structs are covered by one method — and so a field struct
# added later cannot reintroduce the dump by forgetting one. The constructor name, never a slot
# value: `sCharField` -> `CharField`, via the same helper `show` uses. That is a two-line name strip
# with no truncation and no user data in it, which is the one thing worth sharing with `display.jl`.
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
  Dict("pormg_instruction" => _jl_query_model(try getfield(i, :object) catch; nothing end))
