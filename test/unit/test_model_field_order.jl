"""
Regression (#544): `Model_Type.fields` must preserve the order its source supplied, because that
order IS the physical column order of every table PormG creates.

`fields` was a plain `Dict{String, PormGField}`, so the order came from hashing the FIELD NAMES.
Six render sites read it directly — `Dialect.create_table` and the SQLite table rebuild's
`CREATE TABLE …_new` / FK clause / `INSERT … SELECT` column lists — which meant a model emitted its
columns in an order nobody chose, and two Julia versions disagreed about it:

| | field order for `Model("child_t"; id=…, note=…, col=…)` |
|---|---|
| declared | `["id", "note", "col"]` |
| Julia 1.12.7 | `["note", "id", "col"]` |
| Julia 1.13.0 | `["col", "note", "id"]` |

Neither matched declaration, and Julia 1.13 changed string hashing, so identical models rendered
different DDL on different Julia versions. That is what kept CI red on 1.13.

Fixing `fields` alone is not sufficient, which is why the third testset below exists: the planner
rebuilt its own maps with `Dict(...)` and `Set(keys(...))` immediately afterwards, re-hashing the
order two lines after it was preserved. That makes the class FIVE instances deep — `insert` (#97),
`custom_join`/`alias_join` (#449), `ctes` (#543), `fields`, and the planner's `Set` — and the last
is the first where the order-losing container was not a `Dict`.

These tests therefore pin the PROPERTY (insertion order is preserved) rather than any one hash
outcome. A test that hard-coded
`["id", "note", "col"]` for one specific model would pass vacuously on a future Julia whose hashing
happens to agree; the cases below use field names chosen at runtime to invert under the running
Julia's hash, and assert that such a set was actually found.

DB-free: no connection, no fixture.
"""

using Test
using PormG

# Uniquely-named aliases rather than `import PormG.Models`. Every unit file is `include`d into
# `Main`, so a top-level `import` binds the name there for the WHOLE run — and
# `test_field_validation_and_operations.jl` later does `const Models = PormG.Models`, which is a
# `cannot declare Main.Models constant; it was already declared as an import` error that aborts the
# rest of the suite. Files that import `Models` unqualified do it inside a `module` block.
const M544 = PormG.Models
const OC544 = PormG.OrderedCollections

# Find a field-name set that a plain `Dict` iterates AGAINST insertion order under the running
# Julia. Without this the assertions below could pass by luck rather than by the fix.
function _hash_inverting_names(n::Int = 3)
    for attempt in 1:4000
        names = ["f$(attempt)_$(i)" for i in 1:n]
        d = Dict{String, Int}()
        for (i, nm) in enumerate(names)
            d[nm] = i
        end
        collect(keys(d)) != names && return names
    end
    return nothing
end

# ── #544: declared field order survives into `fields` ──────────────────────────────────────────
# The kwargs path is the one users write. `pairs` over the kwargs NamedTuple yields them in source
# order, so the order is available at construction — it was the `Dict` that discarded it.
@testset "Model kwargs declaration order is preserved (#544)" begin
    names = _hash_inverting_names(3)
    @test names !== nothing   # the corpus must contain a discriminating case, or this file proves nothing

    # (1) The issue's own repro, pinned literally: three fields, declared id/note/col.
    m = M544.Model("child_t";
        id   = M544.IDField(),
        note = M544.CharField(max_length = 40),
        col  = M544.CharField(max_length = 80),
    )
    @test collect(keys(m.fields)) == ["id", "note", "col"]

    # (2) `field_names` was already ordered (it is a Vector built by `push!` in the same loop), so
    #     the two representations agreeing is the real invariant — they used to disagree, and every
    #     renderer had to pick one.
    @test collect(keys(m.fields)) == m.field_names

    # (3) The property, on names selected to defeat a plain `Dict` under THIS Julia. Built through
    #     `Model(; ...)` kwargs by splatting, so it exercises the same path a user's model does.
    kw = [Symbol(nm) => M544.CharField(max_length = 10) for nm in names]
    m2 = M544.Model("ordered_t"; kw...)
    @test collect(keys(m2.fields)) == names
    @test m2.field_names == names
end

# ── #544: a caller that already knows the column order can hand it over ────────────────────────
# `Model(name, ::AbstractDict)` is the introspection / Django-importer path. Both readers know the
# physical order (PostgreSQL aggregates `ORDER BY a.attnum`; SQLite reads `PRAGMA table_info` in
# `cid` order), so the signature must accept an ordered map and keep it — while a plain `Dict` keeps
# working exactly as before, since there is no order in one to preserve.
@testset "Model accepts an ordered field map and keeps the order (#544)" begin
    names = _hash_inverting_names(3)
    @test names !== nothing

    ordered = OC544.OrderedDict{String, PormG.PormGField}()
    for nm in names
        ordered[nm] = M544.CharField(max_length = 10)
    end

    m = M544.Model("introspected_t", ordered)
    @test collect(keys(m.fields)) == names
    @test m.field_names == names

    # A plain `Dict` must still be accepted — this method is the #317 import path and its callers
    # pass one. The only promise is that it does not THROW and that the two views agree with each
    # other; a `Dict` has no order to promise.
    plain = Dict{String, PormG.PormGField}(nm => M544.CharField(max_length = 10) for nm in names)
    m3 = M544.Model("plain_t", plain)
    @test collect(keys(m3.fields)) == m3.field_names
    @test sort(m3.field_names) == sort(names)
end

# ── #544: the planner path must not re-hash the order at the last step ─────────────────────────
# `strip_many_to_many_fields` rebuilds a model field by field, and EVERY model reaching the
# migration planner passes through it. A plain `Dict` there would undo the fix for exactly the path
# it exists to fix — DDL rendering — while every test above still passed.
@testset "strip_many_to_many_fields preserves column order (#544)" begin
    names = _hash_inverting_names(4)
    @test names !== nothing

    kw = [Symbol(nm) => M544.CharField(max_length = 10) for nm in names]
    m = M544.Model("m2m_host"; kw...)
    stripped = M544.strip_many_to_many_fields(m)

    @test collect(keys(stripped.fields)) == names
    @test stripped.field_names == names
end
