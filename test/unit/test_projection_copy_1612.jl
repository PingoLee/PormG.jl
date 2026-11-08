# =============================================================================
# The build copies a projection one level, per concrete type, not through Base.deepcopy (#1612)
#
# `get_select_query` renders each projection into a copy of its node, because the node is the caller's
# (#43, #1624: the build writes nothing into the handler). It called `deepcopy(values[i])` on the
# vector's abstract element type `Union{SQLTypeText,SQLTypeField}`: a dynamic call with Base's run-time
# walk behind it. The `juliac --trim` verifier reached it from `list(T)` (#1600's scratch app, after
# #1615), and a trimmed build has no compiled target for it. `_projection_copy` makes the same copy
# `Base.deepcopy(::SQLTypeField)` always made: one level, every slot kept. A `Value(x)` literal
# (`SQLText`) is immutable and only read, so it is returned as is. `get_order_query` and the CTE path
# binder copy an ORDER BY field the same way (`_field_copy`).
#
# Hermetic: a mock SQLite connection and an inline model module. No database.
# =============================================================================
# julia --project=test/integration test/unit/test_projection_copy_1612.jl

using Test
using PormG
import PormG: Configuration, Models

const _PC_QB = PormG.QueryBuilder
const _PC_KEY = normpath(joinpath(@__DIR__, "pormg1612_copy"))
PormG.Configuration.register_offline(_PC_KEY; adapter = :sqlite, server_version = 3_045_000)

PormG.@models_module ProjCopy1612 "pormg1612_copy" begin
    Driver::Models.ModelType = Models.Model("pc1612_driver",
        driverid = Models.IDField(),
        surname  = Models.CharField(max_length = 40),
        code     = Models.CharField(max_length = 3, null = true))
end
import .ProjCopy1612 as PC

# ─────────────────────────────────────────────────────────────────────────────
# Tests: `_projection_copy` / `_field_copy` on each node kind.
# Expected: an `SQLField` comes back as a NEW `SQLField` with all five slots equal (`field`, `_as`,
# `custom_as`, `root`, `memo_as`); an `SQLText` comes back as the same object.
# Matters: this is the copy `Base.deepcopy(::SQLTypeField)` made, so the render's write lands on the
# copy and every slot the memo keys read (`root`, `memo_as`) survives it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a projection copy is one level and keeps every slot (#1612)" begin
    f = _PC_QB.SQLField("driverid__surname", "surname", "who", :cte, "driverid__@surname")
    c = _PC_QB._projection_copy(f)
    @test c isa _PC_QB.SQLField
    @test c !== f
    @test (c.field, c._as, c.custom_as, c.root, c.memo_as) == (f.field, f._as, f.custom_as, f.root, f.memo_as)
    c.field = "rendered"
    @test f.field == "driverid__surname"          # the write lands on the copy
    t = _PC_QB.SQLText(42, "answer")
    @test _PC_QB._projection_copy(t) === t
    @test _PC_QB._field_copy(f) !== f
    @test only(Base.return_types(_PC_QB._field_copy, (_PC_QB.SQLField,))) === _PC_QB.SQLField
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: a build leaves the handler's projection nodes as they were.
# Expected: after `show_query = :sql` (a full build), each `values()` node is the same object with the
# same `field` and `_as` as before the build; the SQL selects the joined column.
# Matters: #1624's invariant (the build writes nothing into the handler), now kept by `_projection_copy`
# instead of `deepcopy`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the build writes nothing into the handler's projections (#1612)" begin
    q = PC.Driver.objects.values("driverid", "surname", "code").order_by("-surname")
    before = [(objectid(v), v.field, v._as) for v in q.object.values]
    order_before = [(objectid(o.field), o.field.field) for o in q.object.order]
    sql = q.list(show_query = :sql)
    @test occursin("\"surname\"", sql)
    @test [(objectid(v), v.field, v._as) for v in q.object.values] == before
    @test [(objectid(o.field), o.field.field) for o in q.object.order] == order_before
end
