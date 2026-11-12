# ==============================================================================
# Shape pins for a trimmed build: no dynamic call where one was removed (#1599)
#
# A dynamic call is one dispatch per call under the JIT, and under `juliac --trim` it is a verifier
# row and, at run time, a `MethodError` when nothing was compiled for the target (the #1600 rounds
# on #1599). When a change removes one, a pin here keeps it removed: it reads the function's
# OPTIMIZED code by reflection, the way `test_type_ratchet.jl` reads struct fields, and fails on any
# call the compiler could not resolve.
#
# In optimized code a call whose target is known becomes `Expr(:invoke, …)`, or is inlined. What is
# left as `Expr(:call, f, …)` is either a builtin (`getfield`, `===`, an intrinsic) or a dynamic
# dispatch: a callee held in a value (an `SSAValue` typed `Function`, or anything else that is not
# a builtin's singleton type) or a generic function the compiler left unresolved. That holds with
# inlining off too (`--inline=no`, coverage runs), since a resolved call is still an `:invoke`.
#
# A pin is added when a trim row is fixed. Each one names the row and the issue.
#
# Run: julia --project=test/integration test/unit/test_trim_shape_pins.jl
# ==============================================================================

using Test
using PormG
using PormG: Configuration
using InteractiveUtils: InteractiveUtils
using Dates: Dates
# The #1683 pins read the handle type each driver extension registers; the suite loads all four.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# The type of the callee of `stmt` (an `Expr(:call, …)`) in the optimized `ci`.
function _tsp_callee_type(ci::Core.CodeInfo, callee)::Type
  callee isa GlobalRef && return isdefined(callee.mod, callee.name) ?
                                 Core.Typeof(getglobal(callee.mod, callee.name)) : Any
  callee isa Core.SSAValue && return Core.Compiler.widenconst(ci.ssavaluetypes[callee.id])
  callee isa Core.Argument && return Any
  return Core.Typeof(callee)
end

# Every statement of the optimized `f(argtypes...)` that is a dynamic call, as "<index>: <stmt>".
function _dynamic_calls(f, argtypes::Tuple)::Vector{String}
  ci, _ = only(code_typed(f, argtypes; optimize = true))
  found = String[]
  for (i, stmt) in enumerate(ci.code)
    (stmt isa Expr && stmt.head === :call) || continue
    T = _tsp_callee_type(ci, stmt.args[1])
    T <: Core.Builtin && continue
    push!(found, "$(i): $(stmt)")
  end
  return found
end

# The same over `tt` (a signature type) and over the keyword body it calls: a function with keyword
# arguments lowers to a thin method that `:invoke`s `#f#N`, where the code is, so a pin on it reads both.
function _dynamic_calls_kw(f, argtypes::Tuple)::Vector{String}
  found = String[]
  fname = string(nameof(f))
  walk(tt, depth) = for (ci, _) in Base.code_typed_by_type(tt; optimize = true)
    for (i, stmt) in enumerate(ci.code)
      stmt isa Expr || continue
      if stmt.head === :call
        _tsp_callee_type(ci, stmt.args[1]) <: Core.Builtin && continue
        push!(found, "$(i): $(stmt)")
      elseif stmt.head === :invoke && depth > 0
        mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        (mi isa Core.MethodInstance && mi.def isa Method) || continue
        startswith(string(mi.def.name), "#$(fname)#") && walk(mi.specTypes, depth - 1)
      end
    end
  end
  walk(Base.signature_type(f, argtypes), 1)
  return found
end

# The same, following every `:invoke` `depth` levels down (#1706): a dynamic call inside a callee —
# `WeakKeyDict`'s `isequal(pool, ::WeakRef)` under a registry lookup — is invisible to the one-level
# scans above, which see only the resolved call into it.
# `skip` names functions not walked into: a reviewed open arm, whose dynamic call is the point (#1714).
function _dynamic_calls_deep(f, argtypes::Tuple; depth::Int = 6, skip = ())::Vector{String}
  found = String[]
  seen = Set{Any}()
  walk(tt, d) = begin
    tt in seen && return
    push!(seen, tt)
    F = Base.unwrap_unionall(tt).parameters[1]
    (isdefined(F, :instance) && F.instance in skip) && return
    for (ci, _) in Base.code_typed_by_type(tt; optimize = true), stmt in ci.code
      stmt isa Expr || continue
      if stmt.head === :call
        _tsp_callee_type(ci, stmt.args[1]) <: Core.Builtin && continue
        push!(found, "$(tt): $(stmt)")
      elseif stmt.head === :invoke && d > 0
        mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        mi isa Core.MethodInstance && walk(mi.specTypes, d - 1)
      end
    end
  end
  walk(Base.signature_type(f, argtypes), depth)
  return found
end

# The dynamic calls of `tt`'s optimized code (a signature type; a keyword body is followed as in
# `_dynamic_calls_kw`) that take an ELEMENT OF A QUERY-STATE SLOT at an abstract type (#1698): an argument
# whose type is not concrete and is a supertype of a slot's closed set (`ProjectionNode`, `FilterNode`,
# `ParamCollector`) or of `SQLObjectQuery` (`object`), or is `SQLTypeField` itself (`select`'s old element
# type). That is the shape every such element had while the slots were typed by the abstract `SQLType*`
# families. A call on a phase-2 field (`SQLField.field`'s `FieldPart`, `OperObject.column`'s
# `ColumnPart`) is not one, and neither is a call taking an `Any` (a literal's value), so a pin on a
# reader holds what #1698 closed and no more.
function _slot_element_calls(@nospecialize(tt))::Vector{String}
  QB = PormG.QueryBuilder
  sets = (QB.ProjectionNode, QB.FilterNode, QB.ParamCollector, QB.SQLObjectQuery)
  slot_arg(@nospecialize(T)) = T === PormG.SQLTypeField ||
                               (T !== Any && !isconcretetype(T) && any(U -> U <: T, sets))
  argtype(ci, a) = a isa Core.SSAValue ? Core.Compiler.widenconst(ci.ssavaluetypes[a.id]) :
                   a isa Core.Argument ? Core.Compiler.widenconst(ci.slottypes[a.n]) : Core.Typeof(a)
  F1 = Base.unwrap_unionall(tt).parameters[1]
  fname = isdefined(F1, :instance) ? string(nameof(F1.instance)) : ""
  found = String[]
  walk(tt, depth) = for (ci, _) in Base.code_typed_by_type(tt; optimize = true)
    for (i, stmt) in enumerate(ci.code)
      stmt isa Expr || continue
      if stmt.head === :call
        _tsp_callee_type(ci, stmt.args[1]) <: Core.Builtin && continue
        any(a -> slot_arg(argtype(ci, a)), stmt.args) && push!(found, "$(i): $(stmt)")
      elseif stmt.head === :invoke && depth > 0
        mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        (mi isa Core.MethodInstance && mi.def isa Method) || continue
        startswith(string(mi.def.name), "#$(fname)#") && walk(mi.specTypes, depth - 1)
      end
    end
  end
  walk(tt, 1)
  return found
end

# Every statement of the optimized `f(argtypes...)` that calls `scope` (#1711): `with_scope`, or the
# render scopes' `_with_render_scope` (#1728). Each comes with whether the compiler resolved it, its result
# type and its argument types. A resolved call is an `:invoke` whose method instance takes `typeof(scope)`:
# the keyword wrapper (`Core.kwcall`), or the keyword body (`#with_scope#N`) once the wrapper is inlined.
# An unresolved one is a `:call` with `scope` among its arguments.
function _with_scope_stmts(f, argtypes::Tuple; scope = PormG.QueryBuilder.with_scope)
  ws = scope
  ci, _ = only(code_typed(f, argtypes; optimize = true))
  argtype(a) = a isa Core.SSAValue ? Core.Compiler.widenconst(ci.ssavaluetypes[a.id]) :
               a isa Core.Argument ? Core.Compiler.widenconst(ci.slottypes[a.n]) :
               a isa GlobalRef ? (isdefined(a.mod, a.name) ? Core.Typeof(getglobal(a.mod, a.name)) : Any) :
               a isa QuoteNode ? Core.Typeof(a.value) : Core.Typeof(a)
  found = @NamedTuple{stmt::String, resolved::Bool, result::Type, args::Vector{Any}}[]
  for (i, stmt) in enumerate(ci.code)
    stmt isa Expr || continue
    result = Core.Compiler.widenconst(ci.ssavaluetypes[i])
    if stmt.head === :invoke
      mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
      mi isa Core.MethodInstance || continue
      args = collect(Any, Base.unwrap_unionall(mi.specTypes).parameters)
      any(T -> T === typeof(ws), args) || continue
      push!(found, (stmt = "$(i): $(stmt)", resolved = true, result = result, args = args))
    elseif stmt.head === :call
      args = Any[argtype(a) for a in stmt.args]
      any(T -> T === typeof(ws), args) || continue
      push!(found, (stmt = "$(i): $(stmt)", resolved = false, result = result, args = args))
    end
  end
  return found
end

# The dynamic calls (non-builtin `:call`s) to one of `names` in the optimized code of `tt` (a signature
# type), following the `:invoke`s into the function's own keyword body and closures and into the scope
# methods' bodies (`#with_scope#N`, `#_with_render_scope#N`), `depth` levels down (#1698 phase 2): two of
# the reads it pins sit inside a render closure that a scope method calls.
function _named_dynamic_calls(@nospecialize(tt), names; depth::Int = 4)
  F1 = Base.unwrap_unionall(tt).parameters[1]
  fname = isdefined(F1, :instance) ? string(nameof(F1.instance)) : ""
  follow(n) = startswith(n, "#$(fname)#") || startswith(n, "#_with_render_scope#") ||
              startswith(n, "#with_scope#")
  found = String[]
  seen = Set{Any}()
  walk(tt, d) = begin
    tt in seen && return
    push!(seen, tt)
    for (ci, _) in Base.code_typed_by_type(tt; optimize = true), (i, stmt) in enumerate(ci.code)
      stmt isa Expr || continue
      if stmt.head === :call
        _tsp_callee_type(ci, stmt.args[1]) <: Core.Builtin && continue
        str = string(stmt)
        any(n -> occursin(n, str), names) && push!(found, "$(i): $(str)")
      elseif stmt.head === :invoke && d > 0
        mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        (mi isa Core.MethodInstance && mi.def isa Method) || continue
        follow(string(mi.def.name)) && walk(mi.specTypes, d - 1)
      end
    end
  end
  walk(tt, depth)
  return found
end

# Every struct PormG or one of its loaded driver extensions defines below one of `roots`, found by walking
# `subtypes` down from each root (#1698): the concrete ones, and the ones a type parameter leaves open
# (`struct Foo{T} <: SQLTypeF`), which no closed union can list and which the pin therefore refuses. A
# struct a test file defines is not PormG's and is skipped.
function _node_subtypes(roots::Tuple)
  # Every extension `Project.toml` declares, so one added later is counted without editing this list.
  # Read section-aware without a TOML dependency, as `test_compat_guards.jl` does: the `test` target
  # does not carry the TOML stdlib.
  owners = Module[PormG]
  section = ""
  for raw in eachline(joinpath(pkgdir(PormG), "Project.toml"))
    line = strip(raw)
    startswith(line, "[") && (section = line; continue)
    (section == "[extensions]" && occursin('=', line)) || continue
    ext = Base.get_extension(PormG, Symbol(strip(first(split(line, '=')))))
    ext === nothing || push!(owners, ext)
  end
  ours(@nospecialize(T)) = Base.moduleroot(parentmodule(T)) in owners
  concrete = Set{DataType}(); open = Set{Any}(); seen = Set{Any}()
  stack = Any[roots...]
  while !isempty(stack)
    T = pop!(stack)
    T in seen && continue
    push!(seen, T)
    if T isa UnionAll
      ours(T) && push!(open, T)
    elseif T isa DataType && isconcretetype(T)
      ours(T) && push!(concrete, T)
    elseif T isa DataType && isabstracttype(T)
      append!(stack, InteractiveUtils.subtypes(T))
    end
  end
  return concrete, open
end
_concrete_subtypes(roots::Tuple)::Set{DataType} = first(_node_subtypes(roots))

# Every read of a node slot pinned to its accessors, in the query builder: `OperObject.column` / `.values`
# (#1599 round 10), `QObject.filters` / `QorObject.or` (#1599 slice B, #1698 phase 2), `SQLObjectQuery.order`
# and `SQLOrder.field` read off a receiver that is not an `SQLOrder` (#1599 slice C; the slot is `SQLField`, so a
# read at `SQLOrder` is concrete and needs no accessor: each rule's third entry exempts it). It reads each
# method's optimized code with inlining off, so an accessor stays a call and a read is a `getproperty` or
# `getfield` whose receiver is inferred as the slot's family (`SQLTypeOper`, `SQLTypeQ`, `SQLTypeQor`, each with
# one concrete member) or as a union that reaches into it (`Union{QObject,QorObject}`); the IR carries the
# narrowing an `isa` test gives, which the unoptimized code does not.
# The methods are every function the module names, plus the module's own methods of `Base.deepcopy` and
# `Base.push!` (`names` does not list a `Base` function the module extends, and those two read the slots).
# Not covered: a closure body (its methods belong to the closure's type), another `Base` function the module
# extends, and a receiver typed `Any` at the read. One pass serves both pins (`_tsp_slot_reads`, memoized).
const _TSP_OPER_ACCESSORS = (:_oper_column, :_oper_value_node, :with_oper_value_node, :_oper_literal,
                             :_oper_holds_expression, :_oper_holds_node)
const _TSP_Q_ACCESSORS = (:_q_terms,)
const _TSP_ORDER_ACCESSORS = (:_order_terms,)
const _TSP_SLOT_RULES = ((:column, PormG.SQLTypeOper, Union{}), (:values, PormG.SQLTypeOper, Union{}),
                         (:filters, PormG.SQLTypeQ, Union{}), (:or, PormG.SQLTypeQor, Union{}),
                         (:order, PormG.QueryBuilder.SQLObjectQuery, Union{}),
                         (:field, PormG.SQLTypeOrder, PormG.QueryBuilder.SQLOrder))
function _tsp_ir_type(ci::Core.CodeInfo, @nospecialize(x))
  x isa Core.SSAValue && return Core.Compiler.widenconst(ci.ssavaluetypes[x.id])
  x isa Core.Argument && return Core.Compiler.widenconst(ci.slottypes[x.n])
  x isa Core.SlotNumber && return Core.Compiler.widenconst(ci.slottypes[x.id])
  return Core.Typeof(x)
end
const _TSP_SLOT_READS = Base.RefValue{Union{Nothing, Vector{@NamedTuple{fn::Symbol, slot::Symbol, text::String}}}}(nothing)
function _tsp_slot_reads_all()
  _TSP_SLOT_READS[] === nothing || return _TSP_SLOT_READS[]
  QB = PormG.QueryBuilder
  CC = Core.Compiler
  interp = CC.NativeInterpreter(; opt_params = CC.OptimizationParams(; inlining = false))
  found = @NamedTuple{fn::Symbol, slot::Symbol, text::String}[]
  fs = Any[getglobal(QB, name) for name in names(QB; all = true) if isdefined(QB, name)]
  push!(fs, Base.deepcopy, Base.push!)
  for f in fs
    f isa Function || continue
    for m in methods(f)
      (m.module === QB && occursin("querybuilder", String(m.file))) || continue
      for (ci, _) in Base.code_typed_by_type(m.sig; optimize = true, interp = interp)
        ci isa Core.CodeInfo || continue
        for stmt in ci.code
          stmt isa Expr || continue
          args = stmt.head === :invoke ? stmt.args[2:end] : stmt.head === :call ? stmt.args : continue
          length(args) >= 3 || continue
          (args[1] isa GlobalRef && args[1].name in (:getproperty, :getfield)) || continue
          slot = args[3] isa QuoteNode ? args[3].value : args[3]
          T = _tsp_ir_type(ci, args[2])
          T === Union{} && continue
          # A receiver within the family, or a union reaching into it (`Union{QObject,QorObject}`); `Any`
          # is left out, since every untyped read would match.
          any(r -> slot === r[1] && T !== Any && typeintersect(T, r[2]) !== Union{} && !(T <: r[3]),
              _TSP_SLOT_RULES) || continue
          push!(found, (fn = m.name, slot = slot,
                        text = "$(m.name) $(basename(String(m.file))):$(m.line) .$(slot) on $(nameof(T))"))
        end
      end
    end
  end
  return _TSP_SLOT_READS[] = found
end
# The reads of `slots` outside `accessors`, as "<function> <file>:<line> .<slot> on <receiver type>".
_tsp_slot_reads(slots::Tuple, accessors::Tuple)::Vector{String} =
  unique(String[r.text for r in _tsp_slot_reads_all() if r.slot in slots && !(r.fn in accessors)])
_oper_slot_reads()::Vector{String} = _tsp_slot_reads((:column, :values), _TSP_OPER_ACCESSORS)
_q_slot_reads()::Vector{String} = _tsp_slot_reads((:filters, :or), _TSP_Q_ACCESSORS)
_order_slot_reads()::Vector{String} = _tsp_slot_reads((:order, :field), _TSP_ORDER_ACCESSORS)

# The dynamic calls in `tt`'s optimized code, following every `:invoke` `depth` levels down (closures, the
# `any`/`foreach`/`collect` a reader hands a term to, keyword bodies), that take an argument `term_arg` accepts:
# a node read off a slot at its abstract type. With `getfields`, a `getfield` on such a value counts too (a slot of
# an ordering term read off an abstract receiver comes back as `Any`, so the call it feeds names no term type).
function _term_calls(term_arg::Function, @nospecialize(tt); depth::Int = 5, getfields::Bool = false)::Vector{String}
  found = String[]
  seen = Set{Any}()
  walk(tt, d) = begin
    tt in seen && return
    push!(seen, tt)
    for (ci, _) in Base.code_typed_by_type(tt; optimize = true), stmt in ci.code
      stmt isa Expr || continue
      if stmt.head === :call
        C = _tsp_callee_type(ci, stmt.args[1])
        if C <: Core.Builtin
          getfields && C === typeof(getfield) && length(stmt.args) >= 2 &&
            term_arg(_tsp_ir_type(ci, stmt.args[2])) && push!(found, "$(tt): $(stmt)")
          continue
        end
        any(a -> term_arg(_tsp_ir_type(ci, a)), stmt.args) && push!(found, "$(tt): $(stmt)")
      elseif stmt.head === :invoke && d > 0
        mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        mi isa Core.MethodInstance && walk(mi.specTypes, d - 1)
      end
    end
  end
  walk(tt, depth)
  return found
end
# A `Q`/`Qor` term at an abstract type (#1599 slice B): an argument typed within `Union{Nothing, FilterType}` but
# not within `Union{Nothing, FilterNode}`, which is what an element read off `QObject.filters` / `QorObject.or` is
# until it is narrowed. Calls on other slots' unions (`FieldPart`, `ColumnPart`) are not counted.
_q_term_calls(@nospecialize(tt); depth::Int = 5)::Vector{String} =
  _term_calls(T -> T !== Union{} && T <: Union{Nothing, PormG.QueryBuilder.FilterType} &&
                   !(T <: Union{Nothing, PormG.QueryBuilder.FilterNode}), tt; depth = depth)
# An ORDER BY term at an abstract type (#1599 slice C): an argument typed within `Union{Nothing, SQLTypeOrder}` but
# not within `Union{Nothing, SQLOrder}` (an element read off `SQLObjectQuery.order` before it is narrowed), a
# `getfield` on one, or an argument typed `SQLTypeField`, which is what `SQLOrder.field` was declared as.
_order_term_calls(@nospecialize(tt); depth::Int = 5)::Vector{String} =
  _term_calls(T -> T === PormG.SQLTypeField ||
                   (T !== Union{} && T <: Union{Nothing, PormG.SQLTypeOrder} && !(T <: Union{Nothing, PormG.QueryBuilder.SQLOrder})),
              tt; depth = depth, getfields = true)

# A visitor for the walk pins (#1698): a real call, not a builtin and not inlined, so a walk that reaches
# it statically shows an `:invoke`.
@noinline _tsp_visit(@nospecialize(n)) = 1
@noinline _tsp_visit(@nospecialize(n), x::Int) = x
# A reader holding a projection at the old abstract element type, for the detector's own check (#1698).
_tsp_old_reader(v::Base.RefValue{Union{PormG.SQLTypeText, PormG.SQLTypeField}}) =
  PormG.QueryBuilder._describe_projection(v[])

# A settings type of its own, which `config` no longer accepts (#1622).
struct _TspOtherSettings <: PormG.PormGSettings end
# A test's own stand-in pool, which `with_pool` hands on through its open arm.
struct _TspStandInPool <: PormG.PormGSQLite end
# A stand-in under the PostgreSQL marker, and a test's own error with a one-argument reader (#1696).
struct _TspStandInPGPool <: PormG.PormGPostgres end
# And under the MySQL marker, for the missing-driver fallbacks (#1599 layer 2).
struct _TspStandInMyPool <: PormG.PormGMySQL end
struct _TspFakeError <: Exception end
# Exceptions no driver owns, for the open-arm rows (#1714): a text, and wrappers keeping a cause.
struct _TspPlainError <: Exception; msg::String; end
Base.showerror(io::IO, e::_TspPlainError) = print(io, e.msg)
struct _TspWrap <: Exception; cause::Any; end
struct _TspWrapErr <: Exception; err::Any; end
# A pool nothing but the registry refers to, for the weak-key check (#1706).
@noinline _tsp_insert_unreferenced!(r) = (r[PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)] = [5]; nothing)
PormG.backend_error_fields(::_TspFakeError) =
  (sqlstate = "XX000", constraint = "fake_c", table = "fake_t", column = nothing, message = "fake")
# An `F` node PormG does not define, for the Q/Qor view's refusal (#1599 slice B). `_node_subtypes` skips it:
# it is not PormG's.
struct _TspOutsiderF <: PormG.SQLTypeF end
# An ordering term PormG does not define, for the ORDER BY view's refusal (#1599 slice C); skipped the same way.
struct _TspOutsiderOrder <: PormG.SQLTypeOrder end
# A visitor taking an `OuterRef`'s two parts, for `_each_outer_ref` (#1599 slice C).
@noinline _tsp_visit_ref(@nospecialize(r), @nospecialize(s)) = nothing
# A typed-read row type, for the projection pin (#1695).
struct _TspRaceRow
  raceid::Int64
  year::Int64
  name::String
end

@testset "Trim shape pins (#1599)" begin

  # What: `_is_interactive()`, the bootstrap's one input on whether the process is a REPL, read by
  #   `load` (the env fallback) and as `set_models`' `implicit` default.
  # Expected: its optimized code holds no dynamic call, and it infers `Bool`.
  # Why: the seam was `Ref{Function}(isinteractive)`, and `_INTERACTIVE[]()` was a call on a
  #   `Function`-typed value, the second wall at run time in #1600's trimmed binary (row 12, #1667).
  #   The seam now holds a `Union{Nothing, Bool}`.
  @testset "_is_interactive has no dynamic call (#1667, row 12)" begin
    calls = _dynamic_calls(Configuration._is_interactive, ())
    @test isempty(calls)
    isempty(calls) || @info "dynamic calls in _is_interactive" calls
    @test only(Base.return_types(Configuration._is_interactive, ())) === Bool
    # The seam still answers: a stored Bool wins, `nothing` asks `isinteractive()`.
    previous = Configuration._INTERACTIVE[]
    try
      Configuration._INTERACTIVE[] = true
      @test Configuration._is_interactive() === true
      Configuration._INTERACTIVE[] = false
      @test Configuration._is_interactive() === false
      Configuration._INTERACTIVE[] = nothing
      @test Configuration._is_interactive() === isinteractive()
    finally
      Configuration._INTERACTIVE[] = previous
    end
  end

  # What: the registry of loaded connections and its accessor, `config` and `get_settings(key)`.
  # Expected: `config` is a `Dict{String,Settings}`, `get_settings` infers `Settings`, and a field read
  #   through it infers the field's declared type (`implicit::Bool`, `connections`' union).
  # Why: `config` was a `Dict{String,PormGSettings}` of the abstract type, so every
  #   `get_settings(key).x` was an `Any`: the read in `_register_models!`, `load` and `close_pool!(key)`
  #   was #1600's row 2 in the verifier and a `MethodError` at run time in both boot paths (#1622 wall 1).
  @testset "get_settings returns the concrete Settings (#1622 wall 1, row 2)" begin
    @test PormG.config isa Dict{String, Configuration.Settings}
    @test isconcretetype(Configuration.Settings)
    @test Configuration.Settings === PormG.Kernel.Settings
    @test only(Base.return_types(Configuration.get_settings, (String,))) === Configuration.Settings
    read_implicit(k::String) = Configuration.get_settings(k).implicit
    @test only(Base.return_types(read_implicit, (String,))) === Bool
    read_pool(k::String) = Configuration.get_settings(k).connections
    @test only(Base.return_types(read_pool, (String,))) === fieldtype(Configuration.Settings, :connections)
    # A settings type of one's own can no longer be registered (the upgrade entry's case).
    @test_throws MethodError (PormG.config["_tsp_other"] = _TspOtherSettings())
    @test !haskey(PormG.config, "_tsp_other")
  end

  # What: a PostgreSQL pool built for a driver named at run time (`postgres_driver:`, `register_connection`).
  # Expected: the constructor infers a union of the concrete pool types, one per driver of
  #   `_PG_DRIVER_PACKAGES`, with no dynamic call; each driver builds its own type.
  # Why: `PostgresConnectionPool{driver}(…)` from a run-time Symbol was a `UnionAll` to inference, a
  #   dynamic constructor call, and the boot failure of #1600's PostgreSQL round (row 11, #1622 wall 2).
  @testset "PostgresConnectionPool builds a concrete type per driver (#1622 wall 2)" begin
    CP = PormG.ConnectionPool
    # Qualified, not through the local `CP`: a closure over a local Module value would not fold.
    build(d::Symbol) = PormG.ConnectionPool.PostgresConnectionPool("host=x"; pool_size = 1, driver = d)
    @test isempty(_dynamic_calls_kw(CP.PostgresConnectionPool, (String,)))
    rt = only(Base.return_types(build, (Symbol,)))
    @test all(isconcretetype, Base.uniontypes(rt))
    for d in keys(PormG._PG_DRIVER_PACKAGES)
      @test build(d) isa CP.PostgresConnectionPool{d}
      @test CP.PostgresConnectionPool{d} <: rt
    end
    @test_throws PormG.InvalidConfigurationError build(:nodriver)
  end

  # What: the refusal for a PostgreSQL driver no arm lists, and `_symbol_text`, which spells its names.
  # Expected: the same text as before #1613's change, word for word (`unknown PostgreSQL driver :pgx;
  #   expected one of :libpq, :postgres`); `_symbol_text(s) == repr(s)` for an identifier, a keyword, an
  #   operator, a symbol Base parenthesizes, and symbols only `Symbol("…")` can spell (escapes included);
  #   and no `repr(` left in the refusal's source.
  # Why: Base shows a `Symbol` through `show_unquoted(::Any)`, which a trimmed build cannot resolve: one
  #   `repr(driver::Symbol)` was 290 of the fixture's 1,132 verifier rows in round 4 of #1600. The
  #   message is user-facing, so the spelling changes and the text does not.
  @testset "the unknown-driver refusal spells Symbols without repr (#1613)" begin
    CP = PormG.ConnectionPool
    err = try
      CP._unknown_postgres_driver(:pgx)
    catch e
      e
    end
    @test err isa PormG.InvalidConfigurationError
    @test err.msg == "unknown PostgreSQL driver :pgx; expected one of :libpq, :postgres"
    @test_throws PormG.InvalidConfigurationError CP.PostgresConnectionPool("host=x"; pool_size = 1, driver = :pgx)
    for s in (:libpq, :postgres, :pgx, :x!, :α, :end, :var, :+, :*, :(==), :(:), :(=>), :(::), :(===),
              Symbol(""), Symbol("lib pq"), Symbol("lib-pq"), Symbol("1x"), Symbol("a\"b"),
              Symbol("a\$b"), Symbol("a\nb"), Symbol("'"), Symbol("'ᵀ"), Symbol("'²"), :.+, :∘, :≤)
      @test (s, CP._symbol_text(s)) == (s, repr(s))
    end
    src = read(joinpath(pkgdir(PormG), "src", "ConnectionPool.jl"), String)
    start = findfirst("_unknown_postgres_driver(driver::Symbol) =", src)[1]
    body = src[start:findnext("\n\n", src, start)[1]]   # the definition, up to its blank line
    @test !occursin("repr(", body)
  end

  # What: `with_pool`, the closed dispatch over the pools PormG builds.
  # Expected: every concrete pool type PormG or a driver extension defines has an `isa` arm (a
  #   `PostgresConnectionPool{D}` per driver); `f` is called with the pool at its concrete type; a
  #   `Settings` entry is unwrapped; an entry with no pool raises `InvalidConfigurationError`; a test's
  #   own stand-in pool still reaches `f` (the open arm).
  # Why: a pool kept in an untyped place (`Settings.connections`) made every call on it dynamic, a
  #   `MethodError` at run time in a trimmed image (#1599 row 11). A pool type added without an arm
  #   would fall back to that dynamic call silently.
  @testset "with_pool lists every concrete pool type (#1622 wall 2)" begin
    CP = PormG.ConnectionPool
    src = read(joinpath(pkgdir(PormG), "src", "ConnectionPool.jl"), String)
    body = src[findfirst("function with_pool(", src)[1]:findfirst("function _with_unlisted_pool(", src)[1]]
    listed = String[]
    for T in (CP.SQLiteConnectionPool, CP.MySQLConnectionPool)
      push!(listed, string(nameof(T)))
    end
    for d in keys(PormG._PG_DRIVER_PACKAGES)
      push!(listed, "PostgresConnectionPool{$(repr(d))}")
    end
    for name in listed
      @test occursin("pool isa $(name) &&", body)
    end
    # Every concrete pool struct PormG's modules define is one of them.
    defined = Set{String}()
    for M in (PormG.ConnectionPool,), n in names(M; all = true)
      isdefined(M, n) || continue
      x = getglobal(M, n); x isa Type || continue
      d = Base.unwrap_unionall(x)
      (d isa DataType && !isabstracttype(d) && d <: PormG.Kernel._SQLEngine) && push!(defined, string(nameof(d)))
    end
    @test defined == Set(["SQLiteConnectionPool", "MySQLConnectionPool", "PostgresConnectionPool"])
    sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    @test CP.with_pool(typeof, sl) === CP.SQLiteConnectionPool
    @test CP.with_pool((p, x) -> (typeof(p), x), sl, 7) === (CP.SQLiteConnectionPool, 7)
    @test CP.with_pool(typeof, Configuration.Settings(connections = sl)) === CP.SQLiteConnectionPool
    @test_throws PormG.InvalidConfigurationError CP.with_pool(typeof, Configuration.Settings())
    @test CP.with_pool(typeof, _TspStandInPool()) === _TspStandInPool
    @test_throws PormG.InvalidConfigurationError CP.with_pool(typeof, 42)
    # `pool` is `@nospecialize`, so the instance that runs is the one for `Any`: every arm is a static
    # call there (the four `isa` arms, the `Settings` unwrap, the open arm's `_with_unlisted_pool`).
    @test isempty(_dynamic_calls(CP.with_pool, (typeof(CP._fetch_on), Any, String, Nothing, Nothing, Bool, Nothing)))
    # The typed read's form (#1605): the last argument is its row decoder, concrete per `T`.
    @test isempty(_dynamic_calls(CP.with_pool, (typeof(CP._fetch_on), Any, String, Nothing, Nothing, Bool,
                                                PormG.QueryBuilder._RowDecoder{NamedTuple{(:a,),Tuple{Int}},Tuple{PormG.ReadParser}})))
    @test isempty(_dynamic_calls(CP.with_pool, (typeof(CP._atomic_on), Any, typeof(identity), Bool)))
    # A settings entry with no pool built yet: every call that needs the pool refuses it the same way.
    PormG.config["_tsp_nopool"] = Configuration.Settings()
    try
      s0 = PormG.config["_tsp_nopool"]
      @test_throws PormG.InvalidConfigurationError CP.atomic(() -> 1, "_tsp_nopool")
      @test_throws PormG.InvalidConfigurationError CP.run_in_transaction(() -> 1, s0)
      @test_throws PormG.InvalidConfigurationError CP.fetch(s0, "SELECT 1")
      @test_throws PormG.InvalidConfigurationError CP.with_savepoint(() -> 1, s0, "sp_tsp")
    finally
      delete!(PormG.config, "_tsp_nopool")
    end
  end

  # What: `_with_terminal_pool`, the query builder terminals' entry (`QueryBuilder._with_connection`).
  # Expected: it lists the same concrete pool types as `with_pool`, calls `f(settings, pool, conn_key)`
  #   with the pool at its concrete type (the same object), hands a stand-in pool to `f` through the open
  #   arm, and its `Any` instance makes no dynamic call.
  # Why: it is `with_pool`'s closed set as a method of its own, because a terminal's body runs its
  #   statements through `with_pool` and a `with_pool` frame nested in another is recursion that inference
  #   limits and a trimmed image cannot compile (#1693: 34 unresolved `with_pool` invokes and an abort in
  #   `delete` when the terminals entered `with_pool` itself). Two lists of one set drift apart unless a
  #   test reads both.
  @testset "_with_terminal_pool lists every concrete pool type (#1693)" begin
    CP = PormG.ConnectionPool
    src = read(joinpath(pkgdir(PormG), "src", "ConnectionPool.jl"), String)
    start = findfirst("function _with_terminal_pool(", src)[1]
    body = src[start:findnext("\nend", src, start)[end]]
    for name in ("SQLiteConnectionPool", "MySQLConnectionPool")
      @test occursin("pool isa $(name) && return f(settings, pool, conn_key)", body)
    end
    for d in keys(PormG._PG_DRIVER_PACKAGES)
      @test occursin("pool isa PostgresConnectionPool{$(repr(d))} && return f(settings, pool, conn_key)", body)
    end
    s = Configuration.Settings()
    sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    got = CP._with_terminal_pool((st, p, k) -> (st, p, typeof(p), k), sl, s, "key")
    @test got[1] === s && got[2] === sl && got[3] === CP.SQLiteConnectionPool && got[4] == "key"
    stand_in = _TspStandInPool()
    @test CP._with_terminal_pool((st, p, k) -> p, stand_in, s, "key") === stand_in
    body_f = (st, p, k) -> nothing
    @test isempty(_dynamic_calls(CP._with_terminal_pool, (typeof(body_f), Any, Configuration.Settings, String)))
  end

  # What: the pool-identity calls the query builder makes on the pool it holds, which it types as the
  #   abstract `_SQLEngine` or `Union{Nothing,_SQLEngine}` (`ensure_transaction_scope(model, connection)`,
  #   `transaction_connection_for(instruction.connection)`), and the two calls an app makes by key.
  # Expected: no dynamic call, at the caller and in the callee.
  # Why: #1600's round 3 reached the write path and stopped at `ensure_transaction_scope` with no method
  #   instance for the concrete pool (row 11); `close_pool!(key)` and `ping(key)` missed in Nitro's pools
  #   probe (#1622). The callees are `@nospecialize` barriers, or reach the pool through `with_pool`.
  @testset "the pool-identity and by-key calls resolve (#1622 wall 2)" begin
    E = PormG.Kernel._SQLEngine
    scope(m::Base.RefValue{PormG.PormGModel}, p::Base.RefValue{E}) = Configuration.ensure_transaction_scope(m[], p[])
    txfor(p::Base.RefValue{Union{Nothing, E}}) = Configuration.transaction_connection_for(p[])
    @test isempty(_dynamic_calls(scope, (Base.RefValue{PormG.PormGModel}, Base.RefValue{E})))
    @test isempty(_dynamic_calls(Configuration.ensure_transaction_scope, (PormG.PormGModel, E)))
    @test isempty(_dynamic_calls(txfor, (Base.RefValue{Union{Nothing, E}},)))
    # On a concrete pool: over the abstract union, a test file's own method on its stand-in adds matches.
    @test isempty(_dynamic_calls(Configuration.transaction_connection_for, (PormG.ConnectionPool.SQLiteConnectionPool,)))
    @test Configuration.transaction_connection_for(nothing) === nothing
    # A nested block on the same database (`atomic(key) do; atomic(key) do …`): the savepoint runs in
    # a transaction context entered with the caller's concrete pool and the untyped `conn`.
    @test isempty(_dynamic_calls(PormG.ConnectionPool._nested_savepoint,
                                 (typeof(identity), PormG.ConnectionPool.SQLiteConnectionPool, Configuration.Settings)))
    @test isempty(_dynamic_calls_kw(Configuration.close_pool!, (String,)))
    @test isempty(_dynamic_calls(Configuration.ping, (String,)))
    # #1622 wall 3: the lease path's offline check, on the key `ensure_before_connect!` resolves.
    @test isempty(_dynamic_calls(Configuration._is_offline_key, (String,)))
  end

  # What: the typed reads of a connection's configuration block (`db_config_settings`, a
  #   `Dict{String,Any}`): the seconds, boolean, integer and text readers, the `config:` key setter and
  #   the PostgreSQL driver name.
  # Expected: no dynamic call in any of them, and each answers as the untyped read did: a number from
  #   a string, an `Int`, a `Float64`, a `Bool` or another `Real`; the truthy strings; `parse(Int, …)`
  #   raising on a non-integer; a `config:` value of the wrong type raising `TypeError` (the
  #   `setfield!` it replaces did).
  # Why: every read of the block was an `Any`, and every use of it a dynamic call (#1599 row 4, the
  #   typing half of #1606), in `read_db_connection_data`, `_build_connection_pool!` and the pool
  #   settings. `setfield!(settings, Symbol(key), v)` set a field by a name read at run time.
  @testset "the configuration block reads are typed (#1606, row 4)" begin
    S = Configuration.Settings
    @test isempty(_dynamic_calls(Configuration._config_secs, (S, String, Float64)))
    @test isempty(_dynamic_calls(Configuration._config_bool, (S, String, Bool)))
    @test isempty(_dynamic_calls(Configuration._cfg_int, (S, String, Int)))
    @test isempty(_dynamic_calls(Configuration._cfg_string, (S, String)))
    @test isempty(_dynamic_calls(Configuration._set_config_key!, (S, String, Any)))
    @test isempty(_dynamic_calls_kw(Configuration._resolve_postgres_driver, (Any,)))
    s = S(db_config_settings = Dict{String,Any}("a" => "5", "b" => 5, "c" => 2.5, "d" => true,
          "e" => 1//2, "f" => "x", "g" => "yes", "h" => "0", "i" => nothing, "j" => "7", "k" => :SQLite))
    @test Configuration._config_secs(s, "a") === 5.0
    @test Configuration._config_secs(s, "b") === 5.0
    @test Configuration._config_secs(s, "c") === 2.5
    @test Configuration._config_secs(s, "d") === 1.0
    @test Configuration._config_secs(s, "e") === 0.5
    @test Configuration._config_secs(s, "f", 3.0) === 3.0
    @test Configuration._config_secs(s, "absent", 4.0) === 4.0
    @test Configuration._config_bool(s, "g", false) === true
    @test Configuration._config_bool(s, "h", true) === false
    @test Configuration._config_bool(s, "i", true) === false
    @test Configuration._config_bool(s, "absent", true) === true
    @test Configuration._cfg_int(s, "j", 3) === 7
    @test Configuration._cfg_int(s, "b", 3) === 5
    @test Configuration._cfg_int(s, "absent", 3) === 3
    @test_throws ArgumentError Configuration._cfg_int(s, "f", 3)
    @test Configuration._cfg_string(s, "k") == "SQLite"
    @test Configuration._cfg_string(s, "absent") === nothing
    Configuration._set_config_key!(s, "change_data", true)
    Configuration._set_config_key!(s, "time_zone", "America/Sao_Paulo")
    Configuration._set_config_key!(s, "django_prefix", nothing)
    @test s.change_data === true && s.time_zone == "America/Sao_Paulo" && s.django_prefix === nothing
    @test_throws TypeError Configuration._set_config_key!(s, "change_db", "yes")
    @test_throws TypeError Configuration._set_config_key!(s, "model_file", ":models")
    @test Configuration._resolve_postgres_driver(:Postgres; source = "test") === :postgres
    @test Configuration._resolve_postgres_driver("libpq"; source = "test") === :libpq
  end

  # What: the boot path of a configuration built in code, and the readers `load` shares with it (#1599
  #   layer 1): `register_connection`'s block, a resolver's `Dict` answer (`_register_resolved!`),
  #   `_build_connection_pool!` and the monitors it wires, `_is_unset`, `_conninfo_value` and the MySQL
  #   conninfo, the list settings (`extensions:`, `ignore_tables:`), the adapter comparison, the older
  #   `options:` spelling, and the capability table's `_supporting_backends`.
  # Expected: no dynamic call in any of them, at the types they receive (a value read from the
  #   `Dict{String,Any}` block is an `Any`). `ensure_before_connect!` keeps exactly one, the call on the
  #   user's hook (as each per-pool copy did before), and is `@nospecialize`, so one compiled body serves
  #   every pool type: the `nospecialize` assertion is the one that tells the two apart. The answers are the untyped code's,
  #   including for a resolver `Dict` and a list of a type no branch names (the one dynamic arm each
  #   keeps) and for an entry `String` cannot convert, which still raises `MethodError`.
  # Why: each was a verifier row of the trimmed fixture (#1599, layer 1: a call on an `Any` value or on
  #   an abstract `Pair`/`AbstractDict`/`AbstractVector`/`DataType`, and the monitor calls on a pool
  #   union that inference widened to the abstract `PostgresConnectionPool`), and a dispatch per call
  #   under the JIT. The hook and the resolver are the user's functions, so their one call stays.
  @testset "the configuration built in code and the readers load shares are typed (#1599, layer 1)" begin
    S = Configuration.Settings
    CP = PormG.ConnectionPool
    # The methods the code of signature type `tt` `:invoke`s, as signature types.
    invokes_in(tt) = [mi.specTypes for (ci, _) in Base.code_typed_by_type(tt; optimize = true)
                      for st in ci.code if st isa Expr && st.head === :invoke
                      for mi in ((st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]),)
                      if mi isa Core.MethodInstance]
    # The reviewed open arms: the one dynamic call each keeps for a type no branch names.
    open_arms = Tuple(getfield(Configuration, n) for n in (:_options_split_read_write_other, :_config_entries_other,
                      :_entry_string_other, :_cfg_text_other, :_is_blank_other) if isdefined(Configuration, n))
    @test isempty(_dynamic_calls(Configuration._is_unset, (Any,)))
    @test isempty(_dynamic_calls(Configuration._conninfo_value, (String, Any)))
    @test isempty(_dynamic_calls(Configuration._mysql_conninfo, (Dict{String,Any},)))
    @test isempty(_dynamic_calls_deep(Configuration._options_split_read_write, (Any,); depth = 1, skip = open_arms))
    @test isempty(_dynamic_calls(Configuration._configured_extensions, (S,)))
    # Its keyword body, read directly (`what`, `blank`, the function, then the positional arguments): it
    # has no defaults for its keywords, so a call without them never reaches the body.
    prefix_body = Base.bodyfunction(only(methods(Configuration._configured_prefix_list)))
    @test isempty(_dynamic_calls(prefix_body, (String, String, typeof(Configuration._configured_prefix_list), S, String)))
    @test isempty(_dynamic_calls(Configuration._builtin_ignores_for_adapter, (Any,)))
    @test isempty(_dynamic_calls(Configuration._build_connection_pool!, (S, String)))
    @test isempty(_dynamic_calls(Configuration._register_resolved!, (String, Any)))
    # The helpers those call, pinned directly: a pin reads one body, not its callees'.
    @test isempty(_dynamic_calls(Configuration._register_resolved_dict!, (String, Dict{String,Any})))
    @test isempty(_dynamic_calls(Configuration._register_resolved_dict!, (String, Dict{String,String})))
    @test isempty(_dynamic_calls(Configuration._push_extension_name!, (Vector{String}, Any)))
    @test isempty(_dynamic_calls(Configuration._push_prefix_entry!, (Vector{String}, AbstractString, String, String)))
    # `register_connection` builds its block with one `setindex!` per entry, not `Dict(pairs...)`.
    rc_body = only(T for T in invokes_in(Base.signature_type(Configuration.register_connection, (String, String)))
                   if occursin("#register_connection#", string(T.parameters[1])))
    @test !any(T -> T <: Tuple{Type{<:Dict}, Vararg{Pair}}, invokes_in(rc_body))
    @test isempty(_dynamic_calls_deep(PormG.Kernel._supporting_backends, (Symbol,); depth = 2))
    for P in (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.MySQLConnectionPool)
      @test length(_dynamic_calls(Configuration.ensure_before_connect!, (P,))) == 1
      @test only(methods(Configuration.ensure_before_connect!, (P,))).nospecialize != 0
    end

    # The answers. `_is_unset`: blank text of any string type is unset, a non-string never is.
    for v in (nothing, "", "  ", SubString(" x ", 1, 1), Test.GenericString(" "))
      @test Configuration._is_unset(v) === true
    end
    for v in ("x", SubString("ax", 2), Test.GenericString("x"), 0, false, :x)
      @test Configuration._is_unset(v) === false
    end
    # `_conninfo_value` spells a value as `string(v)` did, quoted.
    for v in ("a b", :sym, 7, 2.5, true, nothing, 1//2, SubString("xy", 2))
      @test Configuration._conninfo_value("k", v) == "'" * string(v) * "'"
    end
    @test Configuration._mysql_conninfo(Dict{String,Any}("host" => "127.0.0.1", "port" => 3307,
                                                         "username" => "f1", "database" => "f1")) ==
          "host='127.0.0.1' port='3307' user='f1' dbname='f1'"
    # The list settings: the YAML `Vector{Any}`, a `Vector{String}`, another `AbstractVector`, a bare string.
    ext(v) = Configuration._configured_extensions(S(db_config_settings = Dict{String,Any}("extensions" => v)))
    @test ext(Any["unaccent", nothing, " UnAccent ", ""]) == ["unaccent"]
    @test ext(view(["Unaccent", "x"], 1:1)) == ["unaccent"]
    @test ext(SubString(" Unaccent ", 1)) == ["unaccent"]
    @test_throws MethodError ext(Any["unaccent", 1])
    ign(v) = Configuration._configured_ignore_tables(S(db_config_settings = Dict{String,Any}("ignore_tables" => v)))
    @test ign(Any["legacy_", nothing, " etl_ ", "legacy_"]) == ["legacy_", "etl_"]
    @test ign(view(["legacy_"], 1:1)) == ["legacy_"]
    @test ign(Test.GenericString("legacy_")) == ["legacy_"]
    @test_throws PormG.InvalidConfigurationError ign(Any["legacy_", 3])
    @test_throws PormG.InvalidConfigurationError ign(("legacy_",))
    # The adapter comparison: text of either string type matches, a `Symbol` does not (as `==` said).
    @test Configuration._builtin_ignores_for_adapter(SubString("xSQLite", 2)) === PormG.sqlite_ignore_schema
    @test_throws PormG.InvalidConfigurationError Configuration._builtin_ignores_for_adapter(:SQLite)
    # `options:`: a YAML mapping, the placeholder, a block in code, another dict type, no block.
    @test Configuration._options_split_read_write(Dict{Any,Any}("sqlite_split_read_write" => "yes")) === true
    @test Configuration._options_split_read_write(Dict{String,String}()) === false
    @test Configuration._options_split_read_write(IdDict{String,Any}("sqlite_split_read_write" => true)) === true
    @test Configuration._options_split_read_write(nothing) === false

    # `register_connection` stores the block it always stored, and a resolver's `Dict` of a type no branch
    # names still registers (through `_register_resolved_other!`).
    key = "_tsp_layer1_res"
    try
      Configuration._register_resolved!(key, IdDict{String,Any}("url" => ":memory:", "adapter" => "SQLite",
                                                                "pool_size" => 1, "env" => "test",
                                                                "change_data" => true))
      settings = PormG.config[key]
      @test settings.connections isa CP.SQLiteConnectionPool
      @test settings.change_data === true && settings.app_env == "test"
      block = settings.db_config_settings
      @test sort!(collect(keys(block))) == sort!(["adapter", "url", "pool_size", "sqlite_split_read_write",
        "idle_timeout", "max_lifetime", "pool_timeout", "leak_detection_threshold", "fail_fast_on_connect"])
      @test block["adapter"] == "SQLite" && block["url"] == ":memory:" && block["pool_size"] === 1
      @test block["idle_timeout"] === 0 && block["pool_timeout"] === Float64(PormG.DEFAULT_POOL_TIMEOUT)
      @test block["fail_fast_on_connect"] === true && block["sqlite_split_read_write"] === false
    finally
      haskey(PormG.config, key) && Configuration.unregister_connection(key)
    end
  end

  # What: the pool's calls into code that may be defined later than the task making them (the SQLite
  #   worker's `backend_execute`, a deferred or reaped `close`).
  # Expected: ConnectionPool.jl spells `invokelatest(` once, in `_call_latest`; the helper forwards its
  #   arguments and result and holds no dynamic call (the builtin is not one).
  # Why: six call sites each carried their own copy of the world-age reason (#1609, I11). One owner
  #   keeps the reason in one place, and it is the one method JuliaC's `--trim` rebinding of
  #   `Base.invokelatest` has to reach (pinned by the #1609 testset after the #1714 one).
  @testset "invokelatest has one owner in ConnectionPool.jl (#1609)" begin
    path = joinpath(pkgdir(PormG), "src", "ConnectionPool.jl")
    sites = [l for l in eachline(path) if occursin("invokelatest(", l) && !startswith(lstrip(l), "#")]
    @test length(sites) == 1
    @test occursin("_call_latest(", only(sites))
    @test occursin("@noinline", only(sites))   # the build reaches it only out of line (#1609)
    @test PormG.ConnectionPool._call_latest(+, 1, 2) === 3
    @test isempty(_dynamic_calls(PormG.ConnectionPool._call_latest, (typeof(+), Int, Int)))
  end

  # What: the capability lookup by a feature name, `_has_feature(T, ::Symbol)` /
  #   `_feature_since(T, ::Symbol)`, and its callers `_supports` and `_supporting_backends`.
  # Expected: the same answer as the table's `Val` method for every feature on every backend; an
  #   unknown name raises `InvalidValueError`; no dynamic call in the lookup or in `_supports` on a
  #   concrete pool.
  # Why: the callers built `Val(feature)` from a run-time Symbol, which names no method: a dynamic
  #   call per lookup, 10 verifier rows in #1600's round 3 (row 14, #1682).
  @testset "the capability lookup is a closed dispatch (#1682, row 14)" begin
    K = PormG.Kernel
    for T in (PormG.PormGPostgres, PormG.PormGSQLite, PormG.PormGMySQL, PormG.ConnectionPool.SQLiteConnectionPool),
        f in K._FEATURE_NAMES
      @test K._has_feature(T, f) === K._has_feature(T, Val(f))
      @test K._feature_since(T, f) === K._feature_since(T, Val(f))
    end
    @test_throws PormG.InvalidValueError K._has_feature(PormG.PormGSQLite, :no_such_feature)
    @test_throws PormG.InvalidValueError K._feature_since(PormG.PormGSQLite, :no_such_feature)
    @test K._supporting_backends(:arrays) == ["PostgreSQL"]
    @test isempty(_dynamic_calls(K._has_feature, (Type{PormG.ConnectionPool.SQLiteConnectionPool}, Symbol)))
    @test isempty(_dynamic_calls(K._feature_since, (Type{PormG.ConnectionPool.SQLiteConnectionPool}, Symbol)))
    @test isempty(_dynamic_calls_kw(K._supports, (PormG.ConnectionPool.SQLiteConnectionPool, Symbol)))
  end

  # What: the typed read's projection (`list(T)` with no `values(...)`), `_typed_projection!` and
  #   the `_values!` it calls.
  # Expected: `_typed_projection!` calls a `_values!` whose optimized code makes no dynamic call to
  #   `_values_field`, and it calls at least one (the pin cannot pass by finding nothing).
  # Why: the projection was an `Any[...]` list, so the general `_values!` called `_values_field` on an
  #   abstract element: a dispatch per element under the JIT, and `MethodError: _values_field(::String)`
  #   at run time in the trimmed fixture's `list(T)` (round 4 of #1600, #1695).
  @testset "the typed read's projection calls _values_field statically (#1695)" begin
    QB = PormG.QueryBuilder
    ci, _ = only(code_typed(QB._typed_projection!, (QB.ObjectHandler, Type{_TspRaceRow}); optimize = true))
    callees = Any[]
    for stmt in ci.code
      (stmt isa Expr && stmt.head === :invoke) || continue
      mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
      (mi isa Core.MethodInstance && mi.def isa Method && mi.def.name === :_values!) || continue
      push!(callees, mi.specTypes)
    end
    @test !isempty(callees)
    for tt in callees
      dyn = String[]
      for (vci, _) in Base.code_typed_by_type(tt; optimize = true), (i, stmt) in enumerate(vci.code)
        (stmt isa Expr && stmt.head === :call) || continue
        _tsp_callee_type(vci, stmt.args[1]) <: Core.Builtin && continue
        occursin("_values_field", string(stmt)) && push!(dyn, "$(i): $(stmt)")
      end
      @test isempty(dyn)
      isempty(dyn) || @info "dynamic _values_field calls" tt dyn
    end
  end

  # What: the query state's node slots (#1698 phase 1): `SQLObjectQuery.values`/`filter`/`parameters` and
  #   `InstructionObject.object`/`select`/`cache`/`ungrouped_order_terms`/`parameters`, and the walk each
  #   closed set is read through.
  # Expected: each slot is typed by its closed union; every concrete struct PormG defines under the
  #   abstract families the slot used to name is a member of that union AND has an `isa` arm in its walk,
  #   and the walk has no other arm.
  # Why: the slots were typed by the abstract `SQLType*` families, so every element read out of one was
  #   abstract: a dispatch per call under the JIT, and in the trimmed fixture's `list(T)` a `MethodError`
  #   at the next read of a slot (`==(::Any, "*")`, round 4 of #1600). A node type added later that joins
  #   neither the union nor the walk would bring that back silently; a member missing from the walk would
  #   raise a `MethodError` on every query that used it.
  @testset "the query state's node slots are closed unions, each with one walk (#1698)" begin
    QB = PormG.QueryBuilder
    @test fieldtype(QB.SQLObjectQuery, :values) === Vector{QB.ProjectionNode}
    @test fieldtype(QB.SQLObjectQuery, :filter) === Vector{QB.FilterNode}
    @test fieldtype(QB.SQLObjectQuery, :parameters) === Union{Nothing, QB.ParamCollector}
    @test fieldtype(QB.InstructionObject, :parameters) === Union{Nothing, QB.ParamCollector}
    @test fieldtype(QB.InstructionObject, :object) === QB.SQLObjectQuery
    @test fieldtype(QB.InstructionObject, :select) === Vector{QB.SQLField}
    @test fieldtype(QB.InstructionObject, :cache) === Union{Nothing, Dict{QB.MemoKey, QB.SQLField}}
    @test fieldtype(QB.InstructionObject, :ungrouped_order_terms) === Union{Nothing, Vector{QB.SQLField}}
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "types.jl"), String)
    # The walk's body without its comment lines, so a commented-out arm does not count as one.
    function walk_body(name)
      start = findfirst("function $(name)(", src)[1]
      body = src[start:findnext("\nend", src, start)[end]]
      return join(filter(l -> !startswith(lstrip(l), "#"), split(body, '\n')), '\n')
    end
    for (union, roots, walk, var) in (
        (QB.ProjectionNode, (PormG.SQLTypeText, PormG.SQLTypeField), "with_projection_node", "node"),
        (QB.FilterNode, Tuple(Base.uniontypes(QB.FilterType)), "with_filter_node", "node"),
        (QB.ParamCollector, (PormG.AbstractPormGParam,), "with_collector", "params"))
      members = Set{DataType}(Base.uniontypes(union))
      @test all(isconcretetype, members)
      concrete, open = _node_subtypes(roots)
      @test concrete == members
      @test isempty(open)   # a parametric node struct cannot be listed in a closed union
      body = walk_body(walk)
      for T in members
        @test occursin("$(var) isa $(nameof(T)) && return f($(var), args...)", body)
      end
      @test count("$(var) isa ", body) == length(members)
    end
    # `select` and its memo hold the rendered projections: `SQLField` is the only `SQLTypeField`.
    @test _concrete_subtypes((PormG.SQLTypeField,)) == Set([QB.SQLField])
  end

  # What: the three walks (`with_projection_node`, `with_filter_node`, `with_collector`).
  # Expected: each calls `f(node, args...)` with the node at its concrete type; a value outside the set
  #   raises `MethodError`; the instance for an `Any` node makes no dynamic call.
  # Why: the walk is what lets a reader holding a slot element call on it statically (#1698). Its refusal
  #   is the `MethodError` a dispatch with no method raised before, so no caller sees a different error,
  #   and it adds no verifier row.
  @testset "the slot walks route at the concrete type and refuse the rest (#1698)" begin
    QB = PormG.QueryBuilder
    q = QB.QObject(filters = QB.FilterType[])
    @test QB.with_filter_node(typeof, q) === QB.QObject
    @test QB.with_filter_node((n, x) -> (typeof(n), x), q, 7) === (QB.QObject, 7)
    @test QB.with_projection_node(typeof, QB.SQLText(1)) === QB.SQLText
    @test QB.with_projection_node(typeof, QB.SQLField("raceid")) === QB.SQLField
    @test QB.with_collector(typeof, QB.SQLiteParameterizedQuery()) === QB.SQLiteParameterizedQuery
    @test QB.with_collector(typeof, QB.PgParameterizedQuery("", Any[], 0)) === QB.PgParameterizedQuery
    @test QB.with_collector(typeof, QB.MySQLParameterizedQuery()) === QB.MySQLParameterizedQuery
    @test_throws MethodError QB.with_filter_node(typeof, QB.SQLField("raceid"))
    @test_throws MethodError QB.with_projection_node(typeof, "raceid")
    @test_throws MethodError QB.with_collector(typeof, nothing)
    for walk in (QB.with_projection_node, QB.with_filter_node, QB.with_collector)
      @test isempty(_dynamic_calls(walk, (typeof(_tsp_visit), Any)))
      @test isempty(_dynamic_calls(walk, (typeof(_tsp_visit), Any, Int)))
    end
  end

  # What: the readers of the slots the trimmed fixture's `list(T)` reaches: the duplicate-name check and
  #   its label, the WHERE loop, the alias scans of the filters, the typed read's output name, and the
  #   instruction-level parameter verbs (`with_bucket`, `set_context!`, `add_parameter!`, the marks).
  # Expected: no dynamic call taking a slot element at an abstract type (`_slot_element_calls`). Measured
  #   on main (7c02952) with the same detector: `_reject_duplicate_projection_names`, `get_filter_query`,
  #   `_first_projection_alias_filter`, `with_bucket`, `set_context!`, `_positional_bucket` and
  #   `add_parameter!` each made such a call there. `_filters_name_alias` passed on main too: its element
  #   was narrowed by `f isa ExistsObject && continue` to a union the detector does not flag. The
  #   `_describe_projection` and `_typed_output_name` rows and the two marks were not in that measurement;
  #   with those four they guard against a regression rather than prove the change.
  # Why: `_reject_duplicate_projection_names` and `_describe_projection` were the two reads round 4 of
  #   #1600 stopped at (`==(::Any, "*")`, then `_describe_projection(::SQLField)`), and
  #   `with_bucket(f, instruc.parameters, …)` was the call site above 469 verifier rows: the build ran in
  #   a closure called through a dynamic dispatch (#1698).
  @testset "the slot readers on the typed read's path make no call on an abstract element (#1698)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    body_f = () -> nothing
    for tt in (Tuple{typeof(QB._reject_duplicate_projection_names), QB.SQLObjectQuery},
               Tuple{typeof(QB._describe_projection), QB.SQLField},
               Tuple{typeof(QB._describe_projection), QB.SQLText},
               Tuple{typeof(QB.get_filter_query), QB.SQLObjectQuery, I},
               Tuple{typeof(QB._filters_name_alias), QB.SQLObjectQuery},
               Tuple{typeof(QB._first_projection_alias_filter), QB.SQLObjectQuery},
               Tuple{typeof(QB._typed_output_name), QB.ProjectionNode},
               Tuple{typeof(QB.with_bucket), typeof(body_f), I, Symbol},
               Tuple{typeof(QB.set_context!), I, Symbol},
               Tuple{typeof(QB._positional_bucket), I},
               Tuple{typeof(QB.nested_parameter_mark), I},
               Tuple{typeof(QB.detach_nested_run!), I, QB.NestedMark},
               Tuple{typeof(QB.add_parameter!), I, String})
      calls = _slot_element_calls(tt)
      @test isempty(calls)
      isempty(calls) || @info "calls on an abstract slot element" tt calls
    end
    # The detector, on the shape it looks for: a call taking an element at the old abstract type.
    # Measured, not vacuous: green on CI run 42505770103 (ubuntu and windows), and the reader pin above
    # finds calls in 7 of its readers on main 7c02952.
    @test !isempty(_slot_element_calls(Tuple{typeof(_tsp_old_reader), Base.RefValue{Union{PormG.SQLTypeText, PormG.SQLTypeField}}}))
  end

  # What: `OperObject.column` as the WHERE readers see it (#1599 round 9, row 32): its closed set of concrete
  #   structs (`ColumnPartNode`) and the typed read (`_oper_column`).
  # Expected: `ColumnPartNode` equals the concrete subtypes of `ColumnPart`'s two families (none parametric);
  #   `_oper_column` infers it; and `_guard_field_alias_collision` and `_where_node!` make no dynamic
  #   `_model_filter_key` / `_alias_filter_key` call.
  # Why: the slot is a union of two abstract families (`OperObject` is defined before `FObject` and
  #   `WindowFunction`), which is never a compileable signature, so the trimmed read's WHERE clause stopped
  #   at a `MethodError` on `_model_filter_key(::SQLField, …)`, then on `_alias_filter_key`. Over three
  #   concrete types a one-method callee is split statically (#1735, refined in round 9): no walk. Measured
  #   on main 438294f06, both readers make the dynamic call.
  @testset "OperObject.column is read as its concrete structs (#1599 round 9, row 32)" begin
    QB = PormG.QueryBuilder
    concrete, open = _node_subtypes(Tuple(Base.uniontypes(QB.ColumnPart)))
    @test isempty(open)
    @test concrete == Set{DataType}(Base.uniontypes(QB.ColumnPartNode))
    @test only(Base.return_types(QB._oper_column, (QB.OperObject,))) === QB.ColumnPartNode
    I = QB.InstructionObject
    for tt in (Tuple{typeof(QB._guard_field_alias_collision), QB.OperObject, I, Int},
               Tuple{typeof(QB._where_node!), QB.FilterNode, I})
      calls = _named_dynamic_calls(tt, ("_model_filter_key", "_alias_filter_key"))
      @test isempty(calls)
      isempty(calls) || @info "dynamic column-key calls" tt calls
    end
  end

  # What: `OperObject.values` as its readers see it (#1599 round 10, row 33): the node half (`OperValueNode`,
  #   `OperValueNodes`), read through `_oper_value_node` (scalars) or the walk `with_oper_value_node` (both);
  #   the literal half through `_oper_literal`; and `_expression_operand`, asked of the comparison.
  # Expected: `OperValueNode` equals the concrete subtypes of the slot's node families (none parametric); the
  #   walk has one arm per node member and per node vector, and makes no dynamic call for its visitor; the
  #   scalar view infers its declared union (two vector members would widen to the abstract `Vector`); and
  #   on every value kind a filter pair builds, `_expression_operand` and the view give the answer the old
  #   `_expression_operand(values)` gave. An empty node vector is a node to the walk and not an expression,
  #   as before. A vector holding an `F` that only a hand-built node holds (`Vector{SQLTypeF}`) reads as a
  #   literal now; `ObjectHandler` and `SubqueryObject` are checked by the family test, not built here.
  # Why: the slot's type is a `UnionAll`, so every call on it dispatched at run time, even to a one-method
  #   callee (probed with `code_typed` on main e9f05d70f); the trimmed read stopped at a `MethodError` on
  #   `_expression_operand(::String)` in `_guard_where_operand`. The literal half is open (`Number`,
  #   `TimeType`, `Period`, `Vector{T}`) and feeds `formatter::Function`, so it stays untyped by decision
  #   (round 11). On main the names do not exist, so this testset errors there.
  @testset "OperObject.values: a closed node view, the literal half through one accessor (#1599 round 10, row 33)" begin
    QB = PormG.QueryBuilder
    roots = (PormG.SQLTypeF, PormG.SQLTypeFunction, PormG.SQLTypeCTE, PormG.SQLTypeJoined,
             PormG.Kernel.SQLObjectHandler, QB.SubqueryObject)
    concrete, open = _node_subtypes(roots)
    @test isempty(open)
    @test concrete == Set{DataType}(Base.uniontypes(QB.OperValueNode))
    @test Set{Any}(Base.uniontypes(QB.OperValueNodes)) == Set{Any}([Vector{QB.FExpression}, Vector{QB.OuterRefObject}])
    @test only(Base.return_types(QB._oper_value_node, (QB.OperObject,))) === Union{Nothing, QB.OperValueNode}
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "types.jl"), String)
    start = findfirst("function with_oper_value_node(", src)[1]
    body = join(filter(l -> !startswith(lstrip(l), "#"),
                       split(src[start:findnext("\nend", src, start)[end]], '\n')), '\n')
    for T in Base.uniontypes(QB.OperValueNode)
      @test occursin("v isa $(nameof(T)) && return f(v, args...)", body)
    end
    for T in (QB.FExpression, QB.OuterRefObject)
      @test occursin("v isa Vector{$(nameof(T))} && return f(v, args...)", body)
    end
    @test count("v isa ", body) == length(Base.uniontypes(QB.OperValueNode)) + 2
    @test isempty(_dynamic_calls(QB.with_oper_value_node, (typeof(_tsp_visit), QB.OperObject, Int)))
    # The old question, over every kind of value the slot holds.
    old(x) = x isa AbstractVector ? any(old, x) :
             x isa Union{PormG.SQLTypeF, PormG.SQLTypeFunction, PormG.SQLTypeCTE, PormG.SQLTypeJoined,
                         PormG.Kernel.SQLObjectHandler, QB.SubqueryObject}
    values = Any["Monaco", 1, 1.5, true, Dates.Date(2009, 5, 24), Dates.DateTime(2009, 5, 24, 14),
                 Dates.Hour(1), Dates.Time(14, 0), Dates.CompoundPeriod(Dates.Hour(1), Dates.Minute(2)),
                 Base.UUID(1), ["a", "b"], [1, 2], UInt8[1, 2], [UInt8[1], UInt8[2]], [Base.UUID(1)],
                 Union{Missing, String}["a", missing], QB.FExpression[], QB.OuterRefObject[],
                 QB.F("grid"), QB.OuterRef("raceid"), QB.Sum("points"), QB.Rank(over = QB.WindowOver(order_by = "points")),
                 QB.CTE("c", "x"), QB.Joined("d", "x"), [QB.F("a"), QB.F("b")], [QB.OuterRef("a"), QB.OuterRef("b")]]
    for x in values
      o = QB.OperObject(operator = "=", values = x, column = QB.SQLField("grid"))
      @test QB._expression_operand(o) == old(x)
      @test QB._oper_value_node(o) === (old(x) && !(x isa AbstractVector) ? x : nothing)
      @test QB._oper_literal(o) === x
      @test QB.with_oper_value_node(typeof, o, :literal) === (old(x) || x isa QB.OperValueNodes ? typeof(x) : :literal)
    end
  end

  # What: the readers of `OperObject`'s two slots on the WHERE, HAVING and `Q` paths: the row-33 guard, the
  #   operand test, the leaf renderer, the alias routings and the aggregate refusal.
  # Expected: no dynamic call to the questions they ask of either slot (`_named_dynamic_calls`).
  # Why: each asked them of `filter.values` (a `UnionAll`) or `filter.column` (two abstract families), so
  #   each call dispatched at run time; the trimmed read stopped at the first, `_expression_operand` in
  #   `_guard_where_operand` (row 33). Measured on main e9f05d70f: the dynamic calls are there.
  @testset "the OperObject slot readers ask their questions statically (#1599 round 10, row 33)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    O = QB.OperObject
    questions = ("_expression_operand", "_resolved_window", "_resolved_contains_agg", "_alias_filter_key",
             "_model_filter_key", "_plain_filter_key", "_oper_column", "_oper_value_node", "_holds_agg",
             "_contains_agg", "_is_window_expr")
    for tt in (Tuple{typeof(QB._guard_where_operand), O, I},
               Tuple{typeof(QB._compared_operand), O},
               Tuple{typeof(QB._aggregate_alias_leaf), O, I},
               Tuple{typeof(QB._row_alias_leaf), O, I},
               Tuple{typeof(QB._guard_window_alias_in_q), O, I, Int},
               Tuple{typeof(QB._guard_no_aggregate_predicate), O, I, Int},
               Tuple{typeof(QB._get_having_query), O, I},
               Tuple{typeof(QB._render_filter_oper), O, I},
               Tuple{typeof(QB._holds_agg), O, Int},
               Tuple{typeof(QB._contains_agg), O, Int},
               Tuple{typeof(QB._is_window_expr), O})
      calls = _named_dynamic_calls(tt, questions)
      @test isempty(calls)
      isempty(calls) || @info "dynamic OperObject slot questions" tt calls
    end
  end

  # What: every read of `OperObject.column` and `.values` in `src/querybuilder/` (`_oper_slot_reads`).
  # Expected: none outside the accessors (`_oper_column`, `_oper_value_node`, `with_oper_value_node`,
  #   `_oper_literal`, `_oper_holds_expression`, `_oper_holds_node`).
  # Why: round 10's decision is "every reader, not only the ones the run meets": a raw read left on a path
  #   the fixture does not take is the next wall on a query that does. Measured on main e9f05d70f with the
  #   same scan: about 80 reads in 12 files.
  @testset "every OperObject slot read goes through an accessor (#1599 round 10)" begin
    reads = _oper_slot_reads()
    @test isempty(reads)
    isempty(reads) || @info "raw OperObject slot reads" reads
  end

  # What: the closed view over a `Q`/`Qor` group's terms (#1599 slice B, #1698 phase 2): `_q_nodes` (an
  #   `AbstractVector{FilterNode}` over the slot), `_q_terms` (the slot itself, for the writers) and
  #   `_filter_node` (one element), and the rewritten readers whose result or copy changed shape: the HAVING
  #   split's parts, the deep copy of a term vector, the window and aggregate questions.
  # Expected: the slots keep their declared `Vector{FilterType}` (closing them is a reorder of `types.jl`, a
  #   maintainer decision); the view infers `FilterNode` per element and yields the slot's own elements, in
  #   order, identical; an element outside it raises `MethodError`, as the slot walks refuse one;
  #   `deepcopy` gives a `Vector{FilterType}` of fresh copies; `_split_having` infers the
  #   concrete `HavingSplit`; and the window and aggregate questions over a group give the answer they gave over
  #   the slot.
  # Why: an element read at `FilterType` (four abstract families and `ExistsObject`) was a run-time dispatch
  #   on every reader and a call with no compiled target in a trimmed image: the verifier counted 60 rows on
  #   these slots at 765139bf9. `FilterNode` is every concrete member, so the view refuses nothing PormG
  #   builds, and a call over it splits statically. On 765139bf9 the names do not exist, so this testset
  #   errors there.
  @testset "QObject.filters / QorObject.or: a closed view over the terms (#1599 slice B, #1698 phase 2)" begin
    QB = PormG.QueryBuilder
    @test fieldtype(QB.QObject, :filters) === Vector{QB.FilterType}
    @test fieldtype(QB.QorObject, :or) === Vector{QB.FilterType}
    @test eltype(QB.QTermView) === QB.FilterNode
    @test isconcretetype(QB.QTermView)
    for G in (QB.QObject, QB.QorObject)
      @test only(Base.return_types(QB._q_nodes, (G,))) === QB.QTermView
      @test only(Base.return_types(QB._q_terms, (G,))) === Vector{QB.FilterType}
    end
    @test only(Base.return_types(getindex, (QB.QTermView, Int))) === QB.FilterNode
    @test only(Base.return_types(QB._filter_node, (QB.FilterType,))) === QB.FilterNode
    # A group holding five of the six members (an `Exists` needs a model; the family test covers it).
    inner_or = QB.Qor("points__@gt" => 10, "grid" => 1)
    inner_q = QB.Q("raceid" => 18, "statusid" => 1)
    q = QB.Q("grid" => 1, inner_or, inner_q, QB.F("grid") > 3, QB.OuterRef("raceid"))
    qor = QB.Qor(inner_q, "grid" => 2, QB.F("points") >= 1)
    for g in (q, qor)
      terms = QB._q_terms(g)
      @test terms === (g isa QB.QObject ? g.filters : g.or)   # the slot itself, not a copy
      nodes = QB._q_nodes(g)
      @test length(nodes) == length(terms)
      @test all(i -> nodes[i] === terms[i], eachindex(terms))
      @test all(x -> QB._filter_node(x) === x, terms)
      # The deep copy: the slot's own type, fresh elements of the same types.
      c = deepcopy(terms)
      @test c isa Vector{QB.FilterType}
      @test map(typeof, c) == map(typeof, terms)
      @test all(i -> !ismutable(terms[i]) || c[i] !== terms[i], eachindex(terms))   # `OuterRefObject` is immutable
      cg = deepcopy(g)
      @test typeof(cg) === typeof(g) && QB._q_terms(cg) !== terms && length(QB._q_terms(cg)) == length(terms)
    end
    @test map(typeof, QB._q_nodes(q)) == [QB.OperObject, QB.QorObject, QB.QObject, QB.FExpression, QB.OuterRefObject]
    # An element outside `FilterNode` (a subtype of the families PormG does not define) is refused with a
    # `MethodError`, the class a dispatch with no method raised and the slot walks' refusal (#1698): naming
    # `_filter_node`, through the view and through the copy alike.
    outsider = QB.QObject(filters = QB.FilterType[_TspOutsiderF()])
    @test_throws MethodError QB._filter_node(_TspOutsiderF())
    @test_throws MethodError QB._q_nodes(outsider)[1]
    @test_throws MethodError deepcopy(QB._q_terms(outsider))
    err = try QB._filter_node(_TspOutsiderF()) catch e; e end
    @test err isa MethodError && err.f === QB._filter_node && err.args == (_TspOutsiderF(),)
    # `push!` writes through the slot.
    g = QB.Q("grid" => 1)
    push!(g, "raceid" => 18)
    @test length(g.filters) == 2 && g.filters[2] isa QB.OperObject
    # The split's parts are typed (`HavingSplit`, a concrete struct), whatever the term.
    @test isconcretetype(QB.HavingSplit)
    @test fieldtype(QB.HavingSplit, :where_part) === Union{Nothing, QB.FilterNode}
    @test fieldtype(QB.HavingSplit, :having_part) === Union{Nothing, QB.FilterNode}
    for G in (QB.QObject, QB.QorObject, QB.OperObject, QB.FilterNode)
      @test only(Base.return_types(QB._split_having, (G, QB.InstructionObject, Int))) === QB.HavingSplit
    end
    # The window and aggregate questions, over a group, give the answer the old formula gave over the slot
    # (`any` over the elements, each asked at its own type; `_holds_agg`/`_contains_agg` through the vector
    # arm, which still counts the group's depth).
    win = QB.Q(QB.OP(QB.Sum("points"), ">", 1), QB.Qor(QB.F("grid") > 1))
    for g in (q, qor, win, QB.Q(), QB.Qor())
      terms = QB._q_terms(g)
      @test QB._is_window_expr(g) == any(x -> QB._is_window_expr(x), terms)
      @test QB._holds_agg(g, 0) == any(x -> QB._holds_agg(x, 2), terms)
      @test QB._contains_agg(g, 0) == any(x -> QB._contains_agg(x, 2), terms)
    end
    @test QB._holds_agg(win, 0) && QB._contains_agg(win, 0)
    # Past the depth cap the vector arm answers `false` before reading the terms, as it did.
    @test !QB._holds_agg(win, 32) && !QB._contains_agg(win, 32)
  end

  # What: every reader of a `Q`/`Qor` group's terms: the WHERE, HAVING and `Q` guards and renders, the
  #   SELECT-side render, the join-condition and CTE walks, the grouping and path collectors, the copy, the
  #   write-back and `push!`.
  # Expected: no dynamic call taking a term at an abstract type, following every resolved call five levels
  #   down (`_q_term_calls`); and the five main render readers make no dynamic call to the render or guard
  #   they hand a term to, nor to `with_bucket` or `_or_arm` with a closure over one (`_named_dynamic_calls`):
  #   a closure capturing a term at the `FilterNode` union gets its type at run time (measured on 87cbf874b:
  #   the `Qor` arms of `_get_filter_query` and `_get_select_query` made a dynamic `_or_arm` call).
  # Why: each read `q.filters` / `q.or` and called on the element at `FilterType`, a dispatch per call under
  #   the JIT and a verifier row in a trimmed build (60 rows on 765139bf9, 12 of them `_split_having`'s
  #   parts). Measured on 765139bf9 with the same detector: most of these readers make such a call there.
  @testset "the Q / Qor term readers make no call on a term at its abstract type (#1599 slice B)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    Q = QB.QObject
    R = QB.QorObject
    SQ = QB.SQLObjectQuery
    MT = PormG.Models.ModelType
    tts = (Tuple{typeof(QB._guard_field_alias_collision), Q, I, Int},
           Tuple{typeof(QB._each_condition_leaf), typeof(_tsp_visit), R, Int},
           Tuple{typeof(QB._guard_no_aggregate_predicate), R, I, Int},
           Tuple{typeof(QB._guard_no_aggregate_on_condition), Q, QB.ModelJoin, I, Int},
           Tuple{typeof(QB._guard_window_alias_in_q), Q, I, Int},
           Tuple{typeof(QB._split_having), R, I, Int},
           Tuple{typeof(QB._having_leaf_label), R},
           Tuple{typeof(QB._get_having_query), Q, I},
           Tuple{typeof(QB._get_where_query), R, I},
           Tuple{typeof(QB._where_node!), QB.FilterNode, I},
           Tuple{typeof(QB._push_having_part!), Union{QB.OperObject, Q, R}, I},
           Tuple{typeof(QB._check_function), Q},
           Tuple{typeof(QB._collect_projected_paths!), Vector{String}, Q, Int},
           Tuple{typeof(QB._mixed_node_signature), R, Int},
           Tuple{typeof(QB._each_bare_column), typeof(_tsp_visit), Q, I, String, Int},
           Tuple{typeof(QB._refuse_cte_string_in_join), Q, SQ, String, Int},
           Tuple{typeof(QB._bind_cte_filter), R, SQ, Int},
           Tuple{typeof(QB._get_filter_repr), Q},
           Tuple{typeof(QB._projection_alias_in_filter), Q, Set{String}, Int},
           Tuple{typeof(QB._get_filter_query), R, I},
           Tuple{typeof(Core.kwcall), NamedTuple{(:_as,), Tuple{Nothing}}, typeof(QB._get_select_query), Q, I},
           Tuple{typeof(Core.kwcall), NamedTuple{(:_as,), Tuple{Nothing}}, typeof(QB._get_select_query), R, I},
           Tuple{typeof(QB._order_cte_names!), Set{String}, Q},
           Tuple{typeof(QB._cjoin_on_keyed!), Set{String}, Q, String, I, Int},
           Tuple{typeof(QB._refuse_lhs_past_hop), Q, SQ, String, String, Int},
           Tuple{typeof(QB._guard_no_handle), R, Type{QB.CTEReference}, typeof(QB._reject_cte_in_join), String, Int},
           Tuple{typeof(QB._off_path_rhs_condition), Q, SQ, String, Int},
           Tuple{typeof(QB._each_condition_column), typeof(_tsp_visit), Q, Int},
           Tuple{typeof(QB._collect_outer_refs!), Vector{String}, R, Int},
           Tuple{typeof(Core.kwcall), NamedTuple{(:base,), Tuple{MT}}, typeof(QB._prefix_join_filter), R, String, MT},
           Tuple{typeof(QB._holds_agg), Q, Int},
           Tuple{typeof(QB._contains_agg), R, Int},
           Tuple{typeof(QB._is_window_expr), Q},
           Tuple{typeof(deepcopy), R},
           Tuple{typeof(deepcopy), Vector{QB.FilterType}},
           Tuple{typeof(push!), Q, Pair{String,Int}})
    for tt in tts
      calls = _q_term_calls(tt)
      @test isempty(calls)
      isempty(calls) || @info "calls on a Q/Qor term at an abstract type" tt calls
    end
    renders = ("_get_where_query", "_get_having_query", "_get_filter_query", "_get_select_query",
               "_split_having", "_having_leaf_label", "_guard_no_aggregate_predicate",
               "_guard_field_alias_collision", "_guard_window_alias_in_q", "with_bucket", "_push_having_part!",
               "_or_arm")
    for tt in (Tuple{typeof(QB._where_node!), QB.FilterNode, I},
               Tuple{typeof(QB._get_where_query), R, I},
               Tuple{typeof(QB._get_having_query), Q, I},
               Tuple{typeof(QB._get_filter_query), R, I},
               # The positional method, which `_named_dynamic_calls` follows into the keyword body.
               Tuple{typeof(QB._get_select_query), R, I})
      calls = _named_dynamic_calls(tt, renders)
      @test isempty(calls)
      isempty(calls) || @info "dynamic calls on a Q/Qor term" tt calls
    end
    # The `Qor` arm barriers themselves, at each term type: `_named_dynamic_calls` does not step into them,
    # so if one stopped inlining, a dynamic `_or_arm` would move inside it and the checks above stay green.
    for T in Base.uniontypes(QB.FilterNode)
      for tt in (Tuple{typeof(QB._or_arm_filter), T, I}, Tuple{typeof(QB._or_arm_select), T, I, Nothing})
        calls = _named_dynamic_calls(tt, ("_or_arm",))
        @test isempty(calls)
        isempty(calls) || @info "dynamic _or_arm in a Qor arm barrier" tt calls
      end
    end
  end

  # What: every read of `QObject.filters` and `QorObject.or` in `src/querybuilder/`, `Base.deepcopy` and
  #   `Base.push!` included (`_q_slot_reads`).
  # Expected: none outside the slot's accessor, `_q_terms` (the view `_q_nodes` reads through it).
  # Why: as for `OperObject` (round 10): a raw read left on a path the fixture does not take is the next wall
  #   on a query that does. Measured on 765139bf9 with the same scan: the reads are there in every file the
  #   readers live in.
  @testset "every QObject.filters / QorObject.or read goes through the accessor (#1599 slice B)" begin
    reads = _q_slot_reads()
    @test isempty(reads)
    isempty(reads) || @info "raw Q/Qor slot reads" reads
  end

  # What: `SQLObjectQuery.order` and `SQLOrder.field` (#1698 phase 2): the slot types, the split the query's
  #   terms are read through (`with_order_terms`: the closed view `OrderTermView`, or the slot through the open
  #   arm), the one-term split (`with_order_term`), and the writers.
  # Expected: `SQLOrder.field` is `SQLField`, which every constructor spelling stores; the query slot stays
  #   `Vector{SQLTypeOrder}`, and `SQLOrder` is the one concrete `SQLTypeOrder` PormG and its extensions define;
  #   the view yields the slot's own terms, in order, at `SQLOrder`; a query holding a caller's own
  #   `SQLTypeOrder` hands the slot itself to the reader (its rendering is pinned against the base in
  #   `test_sqlorder_orientation.jl`), while `order_by` still stores it; `last()`'s inversion through the view
  #   gives what the old in-place `map!` over the slot gave.
  # Why: an element read at `SQLTypeOrder` and a field read at `SQLTypeField` made every call on them a run-time
  #   dispatch, and a verifier row in a trimmed build (10 rows on 7720d2b45, in `get_order_query` and the
  #   projected-path walk). A second concrete `SQLTypeOrder` would bring the abstract element back silently.
  @testset "SQLObjectQuery.order / SQLOrder.field: a closed view over the terms, the field closed (#1599 slice C, #1698 phase 2)" begin
    QB = PormG.QueryBuilder
    @test fieldtype(QB.SQLOrder, :field) === QB.SQLField
    @test fieldtype(QB.SQLObjectQuery, :order) === Vector{PormG.SQLTypeOrder}
    concrete, open = _node_subtypes((PormG.SQLTypeOrder,))
    @test concrete == Set{DataType}([QB.SQLOrder])
    @test isempty(open)
    @test eltype(QB.OrderTermView) === QB.SQLOrder
    @test isconcretetype(QB.OrderTermView)
    # No accessor hands out the view without the check (#1599 slice C review): only `with_order_terms` builds it.
    @test !isdefined(QB, :_order_nodes)
    @test only(Base.return_types(QB._order_terms, (QB.SQLObjectQuery,))) === Vector{PormG.SQLTypeOrder}
    @test only(Base.return_types(getindex, (QB.OrderTermView, Int))) === QB.SQLOrder
    @test only(Base.return_types(QB._order_node, (PormG.SQLTypeOrder,))) === QB.SQLOrder
    # Every constructor spelling stores an `SQLField`, which is why the narrower slot admits all of them.
    for o in (QB.SQLOrder("points"), QB.SQLOrder("raceid__year"), QB.SQLOrder(QB.SQLField("grid", "grid")),
              QB.SQLOrder(QB.CTE("ev", "seen")), QB.SQLOrder(QB.Joined("d", "surname"); orientation = "DESC"),
              QB.SQLOrder(QB.SQLField("grid", "grid"), nothing, "asc", nothing, :first))
      @test o.field isa QB.SQLField
    end
    @test_throws PormG.QueryBuildError QB.SQLOrder(42)
    @test_throws PormG.QueryBuildError QB.SQLOrder(QB.SQLOrder("points"))
    # The writers and the view, on a query of a model of the test's own (no database).
    model = PormG.Models.Model("tsp_order_race", raceid = PormG.Models.IDField(),
                               points = PormG.Models.IntegerField(), grid = PormG.Models.IntegerField())
    q = QB.SQLObjectQuery(model = model)
    @test isempty(QB.OrderTermView(QB._order_terms(q))) && QB._order_terms(q) === q.order
    explicit = QB.SQLOrder("grid"; nulls = :first)
    QB._order_by!(q, ("-points", explicit, "raceid"))
    terms = QB._order_terms(q)
    @test terms === q.order && length(terms) == 3   # the slot itself, not a copy
    nodes = QB.OrderTermView(QB._order_terms(q))
    @test length(nodes) == 3 && all(i -> nodes[i] === terms[i], eachindex(terms))
    @test nodes[2] === explicit
    @test [(n.field._as, n.orientation, n.nulls) for n in nodes] ==
          [("points", "DESC", nothing), ("grid", "ASC", :first), ("raceid", "ASC", nothing)]
    # `last()`'s inversion, through the view into the slot, against the old formula over the slot.
    old = map(QB._invert_order, copy(terms))
    map!(QB._invert_order, QB._order_terms(q), QB.OrderTermView(QB._order_terms(q)))
    @test [(n.field, n.orientation, n.nulls) for n in QB.OrderTermView(QB._order_terms(q))] == [(n.field, n.orientation, n.nulls) for n in old]
    # The copies keep the slot's type.
    @test deepcopy(q).order isa Vector{PormG.SQLTypeOrder} && length(deepcopy(q).order) == 3
    # The split: the view for `SQLOrder` terms, the slot itself (the open arm) for a caller's own `SQLTypeOrder`.
    @test QB._all_sqlorder(QB._order_terms(q))
    @test QB.with_order_terms((t, x) -> (typeof(t), x), q, 7) === (QB.OrderTermView, 7)
    @test QB.with_order_term((t, x) -> (typeof(t), x), explicit, 7) === (QB.SQLOrder, 7)
    QB._order_by!(q, ("grid", _TspOutsiderOrder()))
    @test q.order[2] === _TspOutsiderOrder() && !QB._all_sqlorder(QB._order_terms(q))
    @test QB.with_order_terms((t, x) -> (t, x), q, 7) === (q.order, 7)   # the slot itself, not a copy
    @test QB.with_order_term((t, x) -> (t, x), _TspOutsiderOrder(), 7) === (_TspOutsiderOrder(), 7)
    # The view is for `SQLOrder` terms only: read directly, an outsider is refused (`_order_node`, #1698).
    @test_throws MethodError QB.OrderTermView(QB._order_terms(q))[2]
    err = try QB._order_node(_TspOutsiderOrder()) catch e; e end
    @test err isa MethodError && err.f === QB._order_node && err.args == (_TspOutsiderOrder(),)
    # Each open arm makes exactly one dynamic call, the reader's own, so an outsider runs the old formula. One
    # method per arity, every argument unspecialized: read at `Any`, the one instance each compiles.
    for open in (QB._order_terms_open, QB._order_term_open)
      @test length(methods(open)) == 3
      for m in methods(open)
        @test m.nospecialize == 2^(m.nargs - 1) - 1   # every argument `@nospecialize`d
        calls = _dynamic_calls(open, Tuple(Any for _ in 2:m.nargs))
        @test length(calls) == 1
        length(calls) == 1 || @info "an open arm's dynamic calls" open calls
      end
    end
    # The NULL-placement refusal, reached statically now: the text `repr` gave, spelled without it (#1613).
    for s in (:middle, :end, :+, Symbol("a b"), Symbol(""))
      err = try QB._nulls_placement("ASC", s) catch e; e end
      @test err isa PormG.QueryBuildError && err.msg == "Invalid nulls placement $(repr(s)); use :first or :last"
    end
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "build_select.jl"), String)
    start = findfirst("function _nulls_placement(", src)[1]
    @test !occursin("repr(", src[start:findnext("\n\n", src, start)[1]])
  end

  # What: every reader of the query's ORDER BY terms and of an ordering term's field: the ORDER BY render, the
  #   FROM-column look-ahead and the projected-path walk, the CTE binding, the degenerate-aggregate check, the
  #   `OuterRef` collector, the terminal copy, `order_by`, `last()`, the mutation guard, the copy, and the window
  #   readers that take an `SQLOrder` entry (`_each_bare_column`, `_build_over_clause`, `_resolve_window_order`,
  #   `_retag_cte_string_window_order`).
  # Expected: no dynamic call taking a term at `SQLTypeOrder` or a field at `SQLTypeField`, and no slot read off an
  #   abstract term, following every resolved call five levels down (`_order_term_calls`); and the main readers
  #   make no dynamic call to the callee they hand a term or its field to (`_named_dynamic_calls`).
  # Why: those were dynamic calls (10 verifier rows on 7720d2b45: `_field_copy`, `_nulls_placement`,
  #   `_order_term_sql`'s orientation and `_collect_projected_paths!`). Measured on 7720d2b45 with the same
  #   detector: most of these readers make such a call there.
  @testset "the ORDER BY term readers make no call on a term at its abstract type (#1599 slice C)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    SQ = QB.SQLObjectQuery
    O = QB.SQLOrder
    TO = PormG.SQLTypeOrder
    tts = (Tuple{typeof(QB.get_order_query), SQ, I},
           Tuple{typeof(QB._from_column_names), SQ, I},
           Tuple{typeof(QB._projected_paths), QB.OrderTermView},
           Tuple{typeof(QB._order_cte_names!), Set{String}, QB.OrderTermView},
           Tuple{typeof(QB._resolve_cte_string_paths), SQ},
           Tuple{typeof(QB._bind_cte_order), O, SQ},
           Tuple{typeof(QB._degenerate_aggregate), SQ},
           Tuple{typeof(QB._each_outer_ref), typeof(_tsp_visit_ref), SQ},
           Tuple{typeof(QB._terminal_copy), QB.ObjectHandler},
           Tuple{typeof(QB._order_by!), SQ, Tuple{String}},
           Tuple{typeof(QB._order_by!), SQ, Tuple{O}},
           Tuple{typeof(QB._reject_unsafe_mutation_shape), SQ, String},
           Tuple{typeof(QB._each_bare_column), typeof(_tsp_visit), QB.WindowFunction, I, String, Int},
           Tuple{typeof(QB._build_over_clause), QB.WindowSpec, I},
           Tuple{typeof(QB._resolve_window_order), TO, I},
           Tuple{typeof(QB._retag_cte_string_window_order), TO, SQ, Set{String}},
           Tuple{typeof(QB._collect_projected_paths!), Vector{String}, O, Int},
           Tuple{typeof(QB._contains_agg), O, Int},
           Tuple{typeof(QB._each_condition_leaf), typeof(_tsp_visit), O, Int},
           Tuple{typeof(QB._order_cte_names!), Set{String}, O},
           Tuple{typeof(QB._invert_order), O},
           # The bodies `with_order_terms` / `with_order_term` hand the terms to, at the view (the typed path).
           Tuple{typeof(QB._render_order_terms), QB.OrderTermView, SQ, I},
           Tuple{typeof(QB._bind_cte_orders), QB.OrderTermView, SQ},
           Tuple{typeof(QB._orders_name_projections), QB.OrderTermView, Vector{String}},
           Tuple{typeof(QB._invert_orders_into!), QB.OrderTermView, Vector{TO}},
           Tuple{typeof(QB._order_fields), QB.OrderTermView},
           Tuple{typeof(QB._order_cte_names_of!), QB.OrderTermView, Set{String}},
           Tuple{typeof(QB._resolve_window_order_term), O, I},
           Tuple{typeof(QB._retag_window_order_term), O, SQ, Set{String}})
    for tt in tts
      calls = _order_term_calls(tt)
      @test isempty(calls)
      isempty(calls) || @info "calls on an ORDER BY term at an abstract type" tt calls
    end
    # Two readers whose callees reach most of the read path: two levels, so the walk stays on the readers.
    for tt in (Tuple{typeof(deepcopy), SQ},
               Tuple{typeof(Core.kwcall), NamedTuple{(:show_query,), Tuple{Symbol}}, typeof(QB._last), QB.ObjectHandler, Val{:row}})
      calls = _order_term_calls(tt; depth = 2)
      @test isempty(calls)
      isempty(calls) || @info "calls on an ORDER BY term at an abstract type" tt calls
    end
    # The open arms (`_order_terms_open`, `_order_term_open`) are not followed: their one dynamic call is the point
    # (pinned in the testset above). A body named here called dynamically from the typed path would be one again.
    callees = ("_field_copy", "_nulls_placement", "_projected_paths", "_collect_projected_paths!", "_order_cte_names!",
               "_bind_cte_order", "_invert_order", "_is_labelled_term", "_orders_as_sqlite_interval", "_order_node",
               "_render_order_terms", "_bind_cte_orders", "_orders_name_projections", "_invert_orders_into!",
               "_order_cte_names_of!", "_order_fields", "_resolve_window_order_term", "_retag_window_order_term",
               "_order_term_field")
    for tt in (Tuple{typeof(QB.get_order_query), SQ, I},
               Tuple{typeof(QB._from_column_names), SQ, I},
               Tuple{typeof(QB._resolve_cte_string_paths), SQ},
               Tuple{typeof(QB._degenerate_aggregate), SQ},
               Tuple{typeof(QB._each_outer_ref), typeof(_tsp_visit_ref), SQ},
               Tuple{typeof(QB._render_order_terms), QB.OrderTermView, SQ, I},
               Tuple{typeof(QB._build_over_clause), QB.WindowSpec, I},
               Tuple{typeof(QB._resolve_window_order), TO, I},
               Tuple{typeof(QB._retag_cte_string_window_order), TO, SQ, Set{String}},
               Tuple{typeof(QB._each_bare_column), typeof(_tsp_visit), QB.WindowFunction, I, String, Int},
               Tuple{typeof(Core.kwcall), NamedTuple{(:show_query,), Tuple{Symbol}}, typeof(QB._last), QB.ObjectHandler, Val{:row}})
      calls = _named_dynamic_calls(tt, callees)
      @test isempty(calls)
      isempty(calls) || @info "dynamic calls on an ORDER BY term" tt calls
      # The open arm is reached at its one unspecialized instance, never one compiled for this reader.
      for (ci, _) in Base.code_typed_by_type(tt; optimize = true), stmt in ci.code
        (stmt isa Expr && stmt.head === :invoke) || continue
        mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        (mi isa Core.MethodInstance && mi.def isa Method && mi.def.name in (:_order_terms_open, :_order_term_open)) || continue
        @test all(T -> T === Any, Base.unwrap_unionall(mi.specTypes).parameters[2:end])
      end
    end
  end

  # What: every read of `SQLObjectQuery.order` in `src/querybuilder/`, and every read of `SQLOrder.field` off a
  #   receiver that is not an `SQLOrder` (`_order_slot_reads`).
  # Expected: none outside the slot's accessor, `_order_terms` (the view `with_order_terms` builds reads through it).
  # Why: as for `OperObject` and `Q`/`Qor`: a raw read left on a path the fixture does not take is the next wall on
  #   a query that does. Measured on 7720d2b45 with the same scan: the reads are there in nine files.
  @testset "every SQLObjectQuery.order read goes through the accessor, every SQLOrder.field read is at SQLOrder (#1599 slice C)" begin
    reads = _order_slot_reads()
    @test isempty(reads)
    isempty(reads) || @info "raw ORDER BY slot reads" reads
  end

  # What: how `get_select_query` records each projection's kind (#1599 round 8, row 31): `_read_kind`'s
  #   declared answer and the store into `projection_kinds` (`_store_projection_kind!`).
  # Expected: `_read_kind` infers `Union{Nothing, CanonicalType}`; the store has one `isa` arm per concrete
  #   `CanonicalType` (none parametric) and no other; and `get_select_query` makes no dynamic `setindex!`
  #   or store call.
  # Why: the kind reached the three stores as `Any`, then as the abstract `CanonicalType`; either way
  #   `setindex!(::Dict{Symbol,CanonicalType}, kind, ::Symbol)` is not a compileable call (the callee
  #   specializes on the value and has 98 methods), and the trimmed read aborted inferring
  #   `setindex!(Dict{Symbol,CanonicalType}, CDate, Symbol)` at run time (round 8, row 31). Measured on
  #   main ea768c047, `get_select_query` makes the dynamic `setindex!` call and `_read_kind` over a `FieldPart`
  #   infers `Any`.
  @testset "a projection's kind is typed where it is made and stored at its concrete type (#1599 round 8, row 31)" begin
    QB = PormG.QueryBuilder
    @test only(Base.return_types(QB._read_kind, (QB.FieldPart, QB.InstructionObject))) <:
          Union{Nothing, PormG.CanonicalType}
    calls = _named_dynamic_calls(Tuple{typeof(QB.get_select_query), Vector{QB.ProjectionNode}, QB.InstructionObject},
                                 ("setindex!", "_store_projection_kind!"))
    @test isempty(calls)
    isempty(calls) || @info "dynamic kind stores in get_select_query" calls
    concrete, open = _node_subtypes((PormG.CanonicalType,))
    @test isempty(open)
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "expression_kind.jl"), String)
    start = findfirst("function _store_projection_kind!(", src)[1]
    body = join(filter(l -> !startswith(lstrip(l), "#"),
                       split(src[start:findnext("\nend", src, start)[end]], '\n')), '\n')
    for T in concrete
      @test occursin("kind isa $(nameof(T)) && return (d[name] = kind; nothing)", body)
    end
    @test count("kind isa ", body) == length(concrete)
    # Every arm names a kind the module can see, statically: an arm naming an unimported kind is a global
    # read typed `Any`, so its `isa` and store dispatch at run time (and the name would throw if reached).
    @test isempty(_dynamic_calls(QB._store_projection_kind!, (QB.InstructionObject, Symbol, Any)))
  end

  # What: the model field as the query builder reads it (#1599 round 7, row 30): the field memo's value
  #   type, what `_alias_column_field` answers, and the kind lookup's three readers of that answer.
  # Expected: the memo holds #1604's closed `AnyField`; `_alias_column_field` infers
  #   `Union{Nothing, AnyField}`; and `_infer_kind(::String)`, `_infer_kind(::JoinedReference)` and
  #   `_cte_column_kind` make no dynamic call to the field's kind (`_column_kind`, `_json_key_value`,
  #   `_field_kind`).
  # Why: the memo was typed with the abstract `PormGField`, so `_alias_column_field` answered it and the kind
  #   lookup's `_column_kind(field, policy)` dispatched at run time: the trimmed typed read stopped at a
  #   `MethodError` on `_column_kind(::sIDField, ::_MeaningKinds)` (round 7, row 30). Typed `AnyField`, the
  #   call is split over the union statically, because `_column_kind` has one method: union splitting is
  #   bounded by the callee's methods, not the union's 29 members, so no walk is needed here (measured: a
  #   walk gave the same trimmed build). Measured on main 6a41f54b5, the reader detector finds the dynamic
  #   call in each of the three, and the two type checks fail.
  @testset "the query builder reads a model field as AnyField, never PormGField (#1599 round 7, row 30)" begin
    QB = PormG.QueryBuilder
    M = PormG.Models
    @test fieldtype(QB.InstructionObject, :tab_field_cache) === Union{Nothing, Dict{QB.MemoKey, M.AnyField}}
    @test only(Base.return_types(QB._alias_column_field, (String, QB.InstructionObject))) ==
          Union{Nothing, M.AnyField}
    @test only(Base.return_types(QB._alias_column_field, (QB.CTEReference, QB.InstructionObject))) ==
          Union{Nothing, M.AnyField}
    I = QB.InstructionObject
    for tt in (Tuple{typeof(QB._infer_kind), String, I, QB._MeaningKinds},
               Tuple{typeof(QB._infer_kind), String, I, QB._AllKinds},
               Tuple{typeof(QB._infer_kind), QB.JoinedReference, I, QB._MeaningKinds},
               Tuple{typeof(QB._cte_column_kind), QB.CTEReference, I, QB._AllKinds})
      calls = _named_dynamic_calls(tt, ("_column_kind", "_json_key_value", "_field_kind"))
      @test isempty(calls)
      isempty(calls) || @info "dynamic field-kind calls" tt calls
    end
  end

  # What: the join walk (`_build_row_join`), its three hops (`_forward_fk_hop`, `_reverse_hop`,
  #   `_apply_many_to_many_branch`), `_insert_join`'s alias, and the date-part check's key field
  #   (`_relation_key_field`, `_temporal_reads`, read from `_check_temporal_operand`). These are the query
  #   builder's statements that passed a model field on as the abstract `PormGField`, or that a static
  #   first hop reaches next.
  # Expected:
  #   - each hop infers its tuple with `ModelType` for the model it reaches and `<: Union{Nothing, AnyField}`
  #     for the last field;
  #   - `_relation_key_field` infers a subtype of `Union{Nothing, AnyField}`;
  #   - `_insert_join` infers `String`;
  #   - none of them makes a dynamic call to the names listed for it below;
  #   - `_temporal_reads` makes no dynamic call, and answers as the `in` formula it replaced did, over a
  #     matrix of fields and part rows.
  # Why: the trimmed typed read stopped at row 34, a `kwcall` to `_forward_fk_hop` whose field came from
  #   `_segment_field(…)::PormGField`.
  #   - The call is now static over the ForeignKey and the OneToOneField, the two fields with a join
  #     type (one method, so no walk, #1735). Any other model field gets the hop's refusal, raised
  #     without the field.
  #   - A `cjoin` link whose type is a `PormGField` subtype of the caller's own takes an open arm.
  #     `cjoin` still accepts such a link, and closing it would change what a public call accepts.
  #   Once the first hop was static, the verifier read the code behind it:
  #   - each `Union` keyword value (`prev_how`, the segment after the hop) made its call dynamic, so those
  #     values are positional now;
  #   - `last_field` was declared `PormGField`;
  #   - the hops' targets were the abstract `PormGModel`;
  #   - `_insert_join`'s dedup branch read `alias_b` off the abstract `JoinRow`.
  #   `_relation_key_field`, untyped, merged its 28 split answers into `PormGField`. Measured on main
  #   0b5a460d4: the `_relation_key_field`, `_insert_join`, both name checks and the `_temporal_reads` check
  #   fail, and the hop checks error (their signatures differ).
  @testset "the join walk and the date-part check hand on a model field as AnyField (#1599 slice A, row 34)" begin
    QB = PormG.QueryBuilder
    M = PormG.Models
    I = QB.InstructionObject
    @test only(Base.return_types(QB._relation_key_field, (M.AnyField, I))) <: Union{Nothing, M.AnyField}
    @test only(Base.return_types(QB._insert_join, (Vector{QB.JoinRow}, QB.ModelJoin, I, String))) === String
    # Two answers stated `PormGField` though every value is a model's field or one PormG builds. Inference
    # already saw through the annotation on main, so these two guard the retype rather than prove it.
    @test only(Base.return_types(QB._operand_column_field, (String, I))) <: Union{Nothing, M.AnyField}
    @test only(Base.return_types(QB._sql_type_field, (String,))) <: Union{Nothing, M.AnyField}
    for (tt, names) in (
        (Tuple{typeof(QB._build_row_join), Vector{String}, I},
         ("_forward_fk_hop", "_reverse_hop", "_apply_many_to_many_branch", "_hop_join_type", "_refuse_not_a_relation",
          "memo_field!", "_finish_hop!")),
        (Tuple{typeof(QB._check_temporal_operand), QB.FObject, I},
         ("_relation_key_field", "_temporal_reads", "hasproperty", "_field_label")))
      calls = _named_dynamic_calls(tt, names)
      @test isempty(calls)
      isempty(calls) || @info "dynamic field-hop calls" tt calls
    end
    @test isempty(_dynamic_calls(QB._temporal_reads, (M.AnyField, Tuple{Vararg{Symbol}})))
    # The answer `in` gave: the field's temporal kind is among the part's reads, or the part reads only a
    # zoned timestamp and the field is one.
    old_reads(f, reads) = QB._temporal_kind(f) in reads || (:timestamptz in reads && f.type == "TIMESTAMPTZ")
    fields = (M.DateField(), M.DateTimeField(), M.DateTimeField(type = "TIMESTAMP"), M.TimeField(),
              M.DurationField(), M.IntegerField(), M.CharField())
    rows = ((:date, :datetime), (:datetime, :time), (:timestamptz,), (:interval,), (:date,), ())
    for f in fields, reads in rows
      @test QB._temporal_reads(f, reads) === old_reads(f, reads)
    end
    # Last, because the hops' signatures have `prev_how` positional, which is how they are found. The
    # forward hop's keyword body is read at one of the two field types its callers pass.
    Reached = Union{Nothing, M.AnyField}
    hop = Base.bodyfunction(which(QB._forward_fk_hop, (I, M.ModelType, String, String, String, M.sForeignKey, Vector{String}, Nothing)))
    m2m = Base.bodyfunction(which(QB._apply_many_to_many_branch, (M.ManyToManyRelation, I, String, String, String, Vector{String}, Nothing)))
    for (tt, expected, names) in (
        (Tuple{typeof(hop), String, typeof(QB._forward_fk_hop), I, M.ModelType, String, String, String, M.sForeignKey,
               Vector{String}, Union{Nothing, String}},
         Tuple{QB.ModelJoin, M.ModelType, Reached},
         ("_hop_join_type", "_forward_join_model", "_forward_target_not_unique", "ModelJoin")),
        (Tuple{typeof(QB._reverse_hop), I, M.ModelType, String, String, M.ReverseRelation, Vector{String}, Union{Nothing, String}},
         Tuple{QB.ModelJoin, M.ModelType, Reached},
         ("_hop_join_type", "_no_how_join_type", "_child_key_unique", "_reverse_join_table", "model_column", "ModelJoin")),
        (Tuple{typeof(m2m), Bool, typeof(QB._apply_many_to_many_branch), M.ManyToManyRelation, I, String, String, String,
               Vector{String}, Union{Nothing, String}},
         Tuple{String, QB.ModelJoin, M.ModelType, Reached},
         ("_insert_many_to_many_joins", "_flag_to_many!", "get")))
      rt = only(Base.return_types(Base.unwrap_unionall(tt).parameters[1].instance, Tuple(tt.parameters[2:end])))
      @test rt <: expected
      rt <: expected || @info "hop return type" tt rt
      calls = _named_dynamic_calls(tt, names)
      @test isempty(calls)
      isempty(calls) || @info "dynamic calls in a hop" tt calls
    end
  end

  # What: `Models._relation_from_many_to_many`, which builds a many-to-many relation at registration and
  #   in the migration planner, read as both callers specialize it: `set_models` passes `_module`, the
  #   planner's `synthesize_many_to_many_through_models` passes `model_map`.
  # Expected: its keyword body makes no dynamic call. The explicit-`through` branch types the through
  #   model `ModelType` at each of its arms and reads `source_field`/`target_field` once, so
  #   `model_table_name`, `_infer_through_field`, `_is_through_pin_for`, the `fields[…]` reads with their
  #   `.pk_field`, `model_column` and the refusal's keyword call all resolve.
  # Why: once #1685 made the settings concrete, the `juliac --trim` verifier followed registration into
  #   this branch and found it untyped: 34 rows on main, each a run-time `MethodError` in a trimmed binary
  #   whose models declare an explicit `through` (#1690). A `through` or a `.to` left at a type holding the
  #   abstract `PormGModel`, the slot's union or a re-read of it, brings them back.
  @testset "_relation_from_many_to_many makes no dynamic call, explicit through included (#1690)" begin
    M = PormG.Models
    f = M._relation_from_many_to_many
    # The keyword wrapper `Core.kwcall` and the body it `:invoke`s (`#_relation_from_many_to_many#N`).
    function kw_body_calls(nt)
      tt = Tuple{typeof(Core.kwcall), nt, typeof(f), M.ModelType, String, String, M.sManyToManyField,
                 M.ModelType, String, PormG.Kernel.Settings}
      found = String[]
      walk(tt, d) = for (ci, _) in Base.code_typed_by_type(tt; optimize = true), (i, stmt) in enumerate(ci.code)
        stmt isa Expr || continue
        if stmt.head === :call
          _tsp_callee_type(ci, stmt.args[1]) <: Core.Builtin && continue
          push!(found, "$(i): $(stmt)")
        elseif stmt.head === :invoke && d > 0
          mi = stmt.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
          (mi isa Core.MethodInstance && mi.def isa Method) || continue
          startswith(string(mi.def.name), "#_relation_from_many_to_many#") && walk(mi.specTypes, d - 1)
        end
      end
      walk(tt, 2)
      return found
    end
    schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.Kernel.PormGModel}}}
    for nt in (NamedTuple{(:_module, :reverse_accessor), Tuple{Module, Union{Nothing, String}}},
               NamedTuple{(:model_map,), Tuple{schema}})
      calls = kw_body_calls(nt)
      @test isempty(calls)
      isempty(calls) || @info "dynamic calls in _relation_from_many_to_many" nt calls
    end
    # The two helpers that compare a through foreign key's target, one level down: each passed `.to`
    # at the slot's whole type, `Nothing` included (`_through_fk_for` re-read it after its `isa` test),
    # which `_same_model_reference`'s one method does not accept.
    pin_calls = _dynamic_calls_deep(M._is_through_pin_for, (M.ModelType, String, M.ModelType))
    @test isempty(pin_calls)
    isempty(pin_calls) || @info "dynamic calls under _is_through_pin_for" pin_calls
    infer_calls = _named_dynamic_calls(Tuple{typeof(M._infer_through_field), M.ModelType, M.ModelType, String},
                                       ("_same_model_reference",))
    @test isempty(infer_calls)
    isempty(infer_calls) || @info "dynamic calls in _infer_through_field" infer_calls
  end

  # What: `ModelType.cache`, the metadata a model derives (#1687), and the functions that read it: the
  #   constraint and auto-join readers the write path calls (`_unique_keys`), the many-to-many lookups
  #   the query builder calls, and the planner's `declared_composites` / `live_table`.
  # Expected: the slot is a `ModelCache` whose every field is concrete (or `nothing` or one concrete
  #   type); each reader infers a concrete result and makes no dynamic call, three levels down;
  #   `live_table` makes no dynamic call on what it reads from the cache.
  # Why: the cache was a `Dict{String, Dict{String, Any}}`, so every read returned `Any` and each
  #   consumer dispatched on it at run time — 87 dynamic calls under these readers on main, each a
  #   `juliac --trim` verifier row once a trimmed app reaches the write, query or migration path (#1599).
  #   A slot typed `Any`, or a reader that goes back to a string-keyed lookup, brings them back.
  @testset "ModelType.cache is a typed ModelCache, read without a dynamic call (#1687)" begin
    M = PormG.Models
    MT = M.ModelType
    @test fieldtype(MT, :cache) === M.ModelCache
    # Concrete all the way down: a `Dict{String, Any}` or a `Vector{Any}` is a concrete type, and its
    # reads still return `Any`, so a container's key, value and element types are checked too.
    closed(T) = T isa Union ? all(closed, Base.uniontypes(T)) :
                T <: Tuple ? all(closed, fieldtypes(T)) :
                T <: AbstractDict ? isconcretetype(T) && closed(keytype(T)) && closed(valtype(T)) :
                T <: AbstractVector ? isconcretetype(T) && closed(eltype(T)) :
                isconcretetype(T)
    @test !closed(Dict{String, Any}) && !closed(Vector{Any})    # the check itself discriminates
    for name in fieldnames(M.ModelCache)
      @test closed(fieldtype(M.ModelCache, name))
    end
    readers = ((M.declared_check_constraints, (MT,), Vector{M.CheckConstraint}),
               (M._declared_unique_constraints, (MT,), Vector{M.UniqueConstraint}),
               (M._auto_join_unique_columns, (MT,), Union{Nothing, Tuple{String, String}}),
               (M.get_many_to_many_relation, (MT, String), M.ManyToManyRelation),
               (M.has_many_to_many_accessor, (MT, String), Bool),
               (PormG.Migrations.declared_composites, (MT,), Vector{PormG.Migrations.DeclaredComposite}),
               (PormG.QueryBuilder._unique_keys, (MT,), Vector{@NamedTuple{fields::Vector{String}, kind::Symbol}}))
    for (f, args, rt) in readers
      @test only(Base.return_types(f, args)) == rt
      calls = _dynamic_calls_deep(f, args; depth = 3)
      @test isempty(calls)
      isempty(calls) || @info "dynamic calls under a cache reader" f calls
    end
    # `live_table` makes no dynamic call on what it reads from `cache.index`: the lookups and the
    # name-list conversion take it. The check names those calls rather than asserting the function has
    # none at all, because the rest of it depends on dependency versions: at the `OrderedCollections`
    # floor (1.0), iterating `model.fields` infers `Pair{String}`, losing the field type, so the
    # `field_db_column` call in the column loop dispatches there and nowhere else (the floor-resolve CI
    # job showed it). That loop reads `fields`, not the cache, and is not this pin's.
    live = _named_dynamic_calls(Tuple{typeof(PormG.Migrations.live_table), MT, PormG.Kernel.PormGSQLite},
                                ("Migrations.get(", "Base.get(", "_index_name_list(", "haskey(", "getindex("))
    @test isempty(live)
    isempty(live) || @info "dynamic calls in live_table on the cache's values" live
    # Its `composite_index_owners` read reaches `LiveComposite` through a splat (`ownership(d)...`). The
    # scans above skip builtins, and a splat the compiler cannot resolve stays a `Core._apply_iterate`
    # builtin call, so that read is held by there being none left in `live_table`'s own code.
    ci, _ = only(code_typed(PormG.Migrations.live_table, (MT, PormG.Kernel.PormGSQLite); optimize = true))
    @test !any(s -> s isa Expr && s.head === :call && s.args[1] == GlobalRef(Core, :_apply_iterate), ci.code)
  end

  # What: the model-field code a trimmed build reaches below the query builder (#1599, layer 3):
  #   `ArrayField`'s element slots (`sArrayField.base_field`, `ArrayFormatter.base`/`.kind`) and their
  #   reader `array_element_kind`; `_accepted_field_kwargs`, which every field constructor calls; the
  #   duration text `_duration_nanoseconds_to_string`; and #1250's per-model scan record, which
  #   `ensure_model_initialized` reads on every `.objects`.
  # Expected: the three slots are closed unions of concrete types, the element fields a subset of
  #   `AnyField` and exactly the fields `array_element_kind` gives a kind; `field_canonical_kind` over an
  #   `sArrayField`, `array_element_kind` over its element and the array-subscript memo write make no
  #   dynamic call; `_accepted_field_kwargs` makes none and answers each row's set as it did; the duration
  #   text invokes no method on an abstract signature; `ensure_model_initialized` reaches no `WeakKeyDict`.
  #   The answers (element kinds, the importer's element check, keyword sets, duration texts, the scan
  #   record) are the ones the code gave before.
  # Why: each was a verifier row with its innermost frame in src/Models.jl or src/models/: the element
  #   slot typed `PormGField` made `array_element_kind(f.base_field)` and `memo_field!` dynamic (class D);
  #   the keyword row looked up by a run-time name typed the row as a union, so 16 rows read it; `lpad`
  #   with a `Char` reaches `@invoke repeat(::Char, ::Integer)` (4 rows); the `WeakKeyDict` hashed and
  #   compared its `WeakRef` keys as `Any` and registered a finalizer (7 rows). Measured on c60160d96
  #   (#1599 slice A's head), every static check below fails.
  @testset "the model-field code below the query builder is typed: ArrayField's element, keyword sets, durations, the scan record (#1599, layer 3)" begin
    M = PormG.Models
    QB = PormG.QueryBuilder
    closed_union(T) = all(isconcretetype, Base.uniontypes(T))
    base_t = fieldtype(M.sArrayField, :base_field)
    @test closed_union(base_t)
    @test closed_union(fieldtype(M.ArrayFormatter, :base))
    @test closed_union(fieldtype(M.ArrayFormatter, :kind))
    @test base_t <: M.AnyField && fieldtype(M.ArrayFormatter, :base) === base_t
    # The element set is what `array_element_kind` answers a kind for: the same table `ArrayField`
    # refuses from. Each field type built with no argument (the relations and `ArrayField` take one).
    for T in Base.uniontypes(M.AnyField)
      T in (M.sForeignKey, M.sOneToOneField, M.sManyToManyField, M.sArrayField) && continue
      inst = getfield(M, Symbol(chopprefix(String(nameof(T)), "s")))()
      @test (T, M.array_element_kind(inst) !== nothing) == (T, T <: base_t)
    end
    @test M.array_element_kind(M.ArrayField(M.IntegerField())) === nothing
    @test M.array_element_kind(M.ForeignKey("Driver")) === nothing
    @test M.array_element_kind(M.CharField(max_length = 12)) == PormG.CVarChar(12)
    @test M.array_element_kind(M.DateTimeField(type = "TIMESTAMPTZ")) == PormG.CDateTime(true)
    # The Django importer's element check asks which method a type reaches; its answers hold.
    @test PormG.Migrations._array_element_kind_defined("CharField")
    @test PormG.Migrations._array_element_kind_defined("UUIDField")
    @test !PormG.Migrations._array_element_kind_defined("JSONField")
    @test !PormG.Migrations._array_element_kind_defined("PositiveIntegerField")
    # The readers. `value_repr.jl`'s `field_canonical_kind(::sArrayField)` and `build_joins.jl`'s memo write
    # of the element, which take the slot as it is typed.
    @test isempty(_dynamic_calls(PormG.field_canonical_kind, (M.sArrayField,)))
    @test only(Base.return_types(M.array_element_kind, (base_t,))) <: PormG._ArrayElementKind
    @test isempty(_dynamic_calls_deep(M.array_element_kind, (base_t,); depth = 2))
    subscript_body = Base.bodyfunction(only(methods(QB._render_array_subscript)))
    @test isempty(_named_dynamic_calls(Tuple{typeof(subscript_body), Bool, typeof(QB._render_array_subscript),
                                             QB.InstructionObject, String, M.sArrayField, String,
                                             Vector{String}, Vector{String}}, ("memo_field!",)))

    # `_accepted_field_kwargs`: no dynamic call, the same set per row as the row's formula, a set of the
    # caller's own, and the error a name that is no field type always raised.
    no_spec = Tuple(getfield(M, n) for n in (:_no_field_kwarg_spec,) if isdefined(M, n))
    @test isempty(_dynamic_calls_deep(M._accepted_field_kwargs, (String,); depth = 2, skip = no_spec))
    for (name, spec) in pairs(M._FIELD_KWARG_SPECS)
      want = Set{Symbol}(k for k in M._COMMON_FIELD_KWARGS if !(k in get(spec, :exclude, ())))
      haskey(spec, :primary_key) && push!(want, :primary_key)
      union!(want, keys(get(spec, :bools, NamedTuple())), get(spec, :extra, ()))
      @test (name, M._accepted_field_kwargs(String(name))) == (name, want)
    end
    @test M._accepted_field_kwargs(SubString("xCharField", 2)) == M._accepted_field_kwargs("CharField")
    @test M._accepted_field_kwargs("CharField") !== M._accepted_field_kwargs("CharField")
    @test M._accepted_field_kwargs("ManyToManyField") == Set{Symbol}(M._M2M_KWARGS)
    @test_throws FieldError M._accepted_field_kwargs("NoSuchField")

    # The duration text: no `:invoke` that an `@invoke` redirected, two levels down, and the texts `lpad`
    # gave. `lpad` with a `Char` pad holds `@invoke repeat(c::Char, r::Integer)`: the statement names
    # `repeat(::Char, ::Int64)`, a signature its own dispatch sends to another method, so no code is
    # compiled for it.
    redirected(tt, d) = [string(mi.specTypes) for (ci, _) in Base.code_typed_by_type(tt; optimize = true)
                         for st in ci.code if st isa Expr && st.head === :invoke
                         for mi in ((st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]),)
                         if mi isa Core.MethodInstance && mi.def isa Method
                         for T in (which(mi.specTypes) !== mi.def ? (string(mi.specTypes),) :
                                   d > 1 ? redirected(mi.specTypes, d - 1) : ())]
    dur_tt = Base.signature_type(M._duration_nanoseconds_to_string, (Int64,))
    @test isempty(redirected(dur_tt, 2))
    function lpad_text(n)
      s = n < 0 ? "-" : ""
      h, r = divrem(abs(n), 3_600_000_000_000)
      m, r = divrem(r, 60_000_000_000)
      sec, ns = divrem(r, 1_000_000_000)
      f = ns == 0 ? "" : "." * rstrip(lpad(string(ns), 9, '0'), '0')
      return "$(s)$(lpad(string(h), 2, '0')):$(lpad(string(m), 2, '0')):$(lpad(string(sec), 2, '0'))$(f)"
    end
    for n in (Int64(0), Int64(1), Int64(1_500_000_000), Int64(3_723_000_000_123), -Int64(59_999_999_999),
              Int64(360_000) * 1_000_000_000_000, typemax(Int64), typemin(Int64))
      @test (n, M._duration_nanoseconds_to_string(n)) == (n, lpad_text(n))
    end
    @test M._duration_nanoseconds_to_string(Int64(3_723_000_000_123)) == "01:02:03.000000123"

    # #1250's record: kept on the model, under a lock, so no `WeakKeyDict` (its `WeakRef` hash and
    # compare, its finalizer) is reached from `ensure_model_initialized`.
    weak_mis(tt, d) = [string(mi.specTypes) for (ci, _) in Base.code_typed_by_type(tt; optimize = true)
                       for st in ci.code if st isa Expr && st.head === :invoke
                       for mi in ((st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]),)
                       if mi isa Core.MethodInstance
                       for s in (occursin(r"WeakKeyDict|WeakRef", string(mi.specTypes)) ? (string(mi.specTypes),) :
                                 d > 1 ? weak_mis(mi.specTypes, d - 1) : ())]
    @test isempty(weak_mis(Base.signature_type(M.ensure_model_initialized, (M.ModelType,)), 2))
    # The module-level `WeakKeyDict` is gone (an inlined lookup would leave no `:invoke` to find).
    @test !isdefined(M, :_UNBOUND_SCAN)
    # A generated `SearchVectorField`'s expression (#1032) copies its two `Tuple{Vararg{String}}` slots
    # into vectors before the writer is called; the text is the one the comprehension built.
    @test isempty(_dynamic_calls(M.generated_sql, (M.sSearchVectorField,)))
    gen = M.SearchVectorField(generated_from = ("name", "surname"), config = "simple", weights = ("A", "B"))
    @test M.generated_sql(gen) == "setweight(to_tsvector('simple'::regconfig, COALESCE((\"name\")::text, '')), 'A') || " *
                                  "setweight(to_tsvector('simple'::regconfig, COALESCE((\"surname\")::text, '')), 'B')"
    @test M.generated_sql(M.SearchVectorField(generated_from = ("name",), config = "english")) ==
          "to_tsvector('english'::regconfig, COALESCE((\"name\")::text, ''))"
    @test M.generated_sql(M.SearchVectorField()) === nothing
    @test isdefined(M, :_unbound_scan_recorded) && isdefined(M, :_record_unbound_scan!)
    if isdefined(M, :_record_unbound_scan!)
      @test isempty(_dynamic_calls_deep(M._unbound_scan_recorded, (M.ModelType,); depth = 3))
      @test isempty(_dynamic_calls_deep(M._record_unbound_scan!, (M.ModelType, Tuple{Int, Int}); depth = 3))
      bare = M.Model("tsp_layer3_scan", id = M.IDField())
      @test M._unbound_scan_recorded(bare) === nothing
      M._record_unbound_scan!(bare, (3, 4))
      @test M._unbound_scan_recorded(bare) === (3, 4)
      @test copy(getfield(bare, :cache)).unbound_scan === nothing    # a copy is another model
    end
  end

  # What: `SQLField.field` (#1698 phase 2, first slice): the closed set of what it holds (`FieldPartNode`)
  #   and the walk it is read through (`with_field_part`).
  # Expected: the slot is still typed `FieldPart` (its members are defined after `SQLField`); every
  #   concrete struct PormG defines under `FieldPart`'s abstract families, plus `String`, is a member of
  #   `FieldPartNode` and has an `isa` arm in the walk, which has no other arm; the walk routes each member
  #   at its concrete type, refuses anything else with a `MethodError`, and makes no dynamic call itself.
  # Why: a call on a `FieldPart` value dispatches at run time, and in a trimmed image finds nothing
  #   compiled for the member it meets: the typed read stopped at `_get_select_query(original; _as)` with a
  #   `String` (#1599 round 6, row 27). A node struct added later that joins neither the set nor the walk
  #   would bring that back; one missing from the walk would raise on every query that holds it.
  @testset "SQLField.field is a closed set read through one walk (#1698 phase 2)" begin
    QB = PormG.QueryBuilder
    @test fieldtype(QB.SQLField, :field) === QB.FieldPart
    members = Set{Any}(Base.uniontypes(QB.FieldPartNode))
    @test all(T -> T <: QB.FieldPart && isconcretetype(T), members)
    roots = Tuple(T for T in Base.uniontypes(QB.FieldPart) if T !== String)
    concrete, open = _node_subtypes(roots)
    @test union(Set{Any}(concrete), Set{Any}([String])) == members
    @test isempty(open)
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "types.jl"), String)
    start = findfirst("function with_field_part(", src)[1]
    body = join(filter(l -> !startswith(lstrip(l), "#"),
                       split(src[start:findnext("\nend", src, start)[end]], '\n')), '\n')
    for T in members
      @test occursin("part isa $(nameof(T)) && return f(part, args...)", body)
    end
    @test count("part isa ", body) == length(members)
    @test QB.with_field_part(typeof, "raceid") === String
    @test QB.with_field_part(typeof, QB.SQLText(1)) === QB.SQLText
    @test QB.with_field_part((p, x) -> (typeof(p), x), "raceid", 7) === (String, 7)
    @test_throws MethodError QB.with_field_part(typeof, QB.SQLField("raceid"))
    @test isempty(_dynamic_calls(QB.with_field_part, (typeof(_tsp_visit), Any)))
    @test isempty(_dynamic_calls(QB.with_field_part, (typeof(_tsp_visit), Any, Int)))
  end

  # What: the readers that hand an `SQLField.field` value to `_get_select_query` or `_read_kind`: the
  #   projection render and its reuse branch (`get_select_query`), the ORDER BY term's render
  #   (`get_order_query`), `_get_select_query(::SQLField)`, the predicate's left side
  #   (`_get_filter_query(::SQLField)`) and the alias left side (`_alias_lhs`).
  # Expected: no dynamic call to either function in their optimized code, their closures, keyword bodies
  #   and the scope bodies that run them (`_named_dynamic_calls`): each goes through `with_field_part`.
  # Why: those were dynamic calls on the abstract `FieldPart` (#1599 round 6, row 27, the first of them
  #   at run time). Measured on main fc3e2e918, the detector finds them in four of these readers. The
  #   fifth, `get_order_query`, passed there only because its render sits behind an unresolved keyword
  #   call the detector cannot follow (the #1711 residue), so its row guards rather than proves.
  @testset "the SQLField.field readers call _get_select_query and _read_kind statically (#1698 phase 2)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    for tt in (Tuple{typeof(QB.get_select_query), Vector{QB.ProjectionNode}, I},
               # The ORDER BY render's body since #1599 slice C (`get_order_query` hands it the terms).
               Tuple{typeof(QB._render_order_terms), QB.OrderTermView, QB.SQLObjectQuery, I},
               Tuple{typeof(QB._get_select_query), QB.SQLField, I},
               Tuple{typeof(QB._get_filter_query), QB.SQLField, I},
               Tuple{typeof(QB._alias_lhs), QB.MemoKey, QB.SQLField, I})
      calls = _named_dynamic_calls(tt, ("_get_select_query", "_read_kind", "with_field_part", "_order_term_select"))
      @test isempty(calls)
      isempty(calls) || @info "dynamic _get_select_query/_read_kind calls" tt calls
    end
  end

  # What: the scope calls in the SELECT list's and the ORDER BY's builders (`get_select_query`,
  #   `get_order_query`): each renders a term under a changed `RenderScope`, in a closure, through the
  #   render scopes' `_with_render_scope` since #1728.
  # Expected: no call takes its closure as a `Function`, every keyword set is a concrete type, and every
  #   call in `get_select_query` is resolved. What remains is the reviewed residue below, counted exactly
  #   (a fall fails as well as a rise, so the change that removes an entry records it). `with_scope`,
  #   `_with_render_scope` and `_join_scope` take the closure at a type parameter.
  # Why: `with_scope`'s keyword wrapper only passes `f` on, so Julia compiled it for `f::Function`; and
  #   `get_select_query`'s label is `Union{Nothing,String}`, which made its keyword `NamedTuple` abstract
  #   and the call fully dynamic. The trimmed fixture's `list(RaceRow)` aborted there, in a run-time type
  #   inference of that `kwcall`, once #1698 phase 1 had closed the query-state slots (#1711).
  @testset "with_scope is specialized on its closure, with a concrete keyword set (#1711)" begin
    QB = PormG.QueryBuilder
    # (unresolved calls, calls whose result is `Any`), reviewed; the scope method itself adds none.
    residue = Dict(
      # `build_select.jl`, the projection render: none left. Its two `Any` results (the render returning
      # `_read_kind(original)` over a `FieldPart`) went when `_read_kind` declared its answer (#1599 round 8,
      # row 31).
      "get_select_query" => (0, 0),
      # the ORDER BY term's interval render (`_render_interval_operand`): its closure captures
      # `order_node`, a `FieldPart`, so the scope call is left unresolved (not attributed further; a
      # `let` rebinding changes nothing). The term's plain render walks `order_node` before its closure
      # is built, behind a `@noinline` barrier (`_render_order_term`, #1698 phase 2), so its scope calls
      # are not in this function's code. The body is `_render_order_terms` since #1599 slice C.
      "_render_order_terms" => (1, 0),
    )
    for (f, sig) in ((QB.get_select_query, (Vector{QB.ProjectionNode}, QB.InstructionObject)),
                     (QB._render_order_terms, (QB.OrderTermView, QB.SQLObjectQuery, QB.InstructionObject)))
      name = string(nameof(f))
      stmts = _with_scope_stmts(f, sig; scope = QB._with_render_scope)
      @test !isempty(stmts)
      takes_function = filter(s -> any(T -> T === Function, s.args), stmts)
      abstract_kw = filter(s -> any(T -> T isa Type && (T <: NamedTuple || T <: Base.Pairs) &&
                                         !isconcretetype(T), s.args), stmts)
      @test isempty(takes_function)
      @test isempty(abstract_kw)
      name == "get_select_query" && @test all(s -> s.resolved, stmts)
      measured = (count(s -> !s.resolved, stmts), count(s -> s.result === Any, stmts))
      @test measured == residue[name]
      (isempty(takes_function) && isempty(abstract_kw) && measured == residue[name]) ||
        @info "with_scope statements in $(name)" measured stmts = [s.stmt for s in stmts]
    end
    # The signatures: the two scope methods and the one wrapper that only passes `f` on (`_join_scope`)
    # take the closure at a type parameter, so each compiles per closure type. A wrapper that calls
    # `f()` in a branch (`_on_join_right`, `_or_arm`, `_in_clause_phase`) is specialized by Julia anyway.
    for g in (QB.with_scope, QB._with_render_scope, QB._join_scope)
      sig = Base.unwrap_unionall(only(methods(g)).sig)
      @test sig.parameters[2] isa TypeVar
    end
  end

  # What: where the clause-level `with_scope` is called: the clauses `build` and `update` open, and not a
  #   render below them, which opens its scopes through `_with_render_scope`.
  # Expected: in `src/` and `ext/`, `with_scope(` appears only at the reviewed clause sites (`build`'s
  #   SELECT, WHERE, ORDER BY and join-condition scopes; `update`'s SET clause) and at its own docstring
  #   and definition; the optimized code of `get_select_query` and `get_order_query`, each run inside a
  #   clause scope, makes no call to it. A nested `build()` (a `Subquery`) entering `with_scope` from
  #   inside a render is NOT covered here: it is open (#1599 round 6).
  # Why: specialized on its closure (#1711), `with_scope` re-entered from inside one of its own closures
  #   with another closure type is treated by inference as recursion and limited, and the limited result
  #   is never compiled: the trimmed read aborted in a run-time type inference of `get_select_query`, which
  #   the verifier listed as an unresolved invoke, with 49 `#with_scope#11` bodies (#1728, the class #1693
  #   measured with `with_pool`). A render that opens its scope through `with_scope` brings that back.
  @testset "the clause-level with_scope is not called by a render function (#1728)" begin
    QB = PormG.QueryBuilder
    clause_sites = Dict("src/querybuilder/build_query.jl" => 4, "src/querybuilder/execution_write.jl" => 1,
                        # its docstring's signature line and its definition
                        "src/querybuilder/types.jl" => 2)
    root = pkgdir(PormG)
    found = Dict{String,Int}()
    for top in ("src", "ext"), (dir, _, files) in walkdir(joinpath(root, top)), f in files
      endswith(f, ".jl") || continue
      path = joinpath(dir, f)
      n = count(m -> true, eachmatch(r"(?<![\w_])with_scope\(", read(path, String)))
      n > 0 && (found[replace(relpath(path, root), '\\' => '/')] = n)
    end
    @test found == clause_sites
    found == clause_sites || @info "with_scope( call sites outside types.jl" found
    for (f, sig) in ((QB.get_select_query, (Vector{QB.ProjectionNode}, QB.InstructionObject)),
                     (QB._render_order_terms, (QB.OrderTermView, QB.SQLObjectQuery, QB.InstructionObject)))
      @test isempty(_with_scope_stmts(f, sig))
    end
  end

  # What: the calls that hand a driver handle, read from a pool's untyped `Vector{Any}` slot, to the
  #   driver: release (and its retire-on-return close), the liveness probe, renewal, close, the
  #   transaction's finalize, and the statement dispatch, on each pool type PormG builds.
  # Expected: every driver extension registers a CONCRETE handle type (`backend_handle_type`); with the
  #   handle typed `Any`, as it comes out of a slot, none of those functions makes a dynamic call; a
  #   handle of the registered type reaches the callee at that type, and a stand-in handle (the unit
  #   suite's mocks) takes the open arm and reaches it unchanged.
  # Why: the slots are `Vector{Any}` because core never names a driver type, so each of these calls
  #   dispatched at run time, and in a trimmed image found nothing compiled: the Nitro pools probe's
  #   `lease` missed `release_connection(pool, conn::Any)` (#1683, round 4 of #1600). A registered type
  #   that is not concrete (`Postgres.Connection` is a `UnionAll`) would leave the call dynamic again.
  @testset "a handle from an untyped slot reaches the driver at its concrete type (#1683)" begin
    CP = PormG.ConnectionPool
    pools = (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
             CP.MySQLConnectionPool)
    for P in pools
      H = PormG.backend_handle_type(P)
      @test (P, isconcretetype(H)) == (P, true)
      for (name, f, args) in (("release_connection", CP.release_connection, (P, Any)),
                              ("_renew_or_discard_connection!", CP._renew_or_discard_connection!, (P, Any)),
                              ("_with_handle(backend_is_alive)", CP._with_handle, (typeof(PormG.backend_is_alive), P, Any)),
                              ("_with_handle(_handle_close)", CP._with_handle, (typeof(CP._handle_close), P, Any)),
                              ("_with_handle(_handle_close_latest)", CP._with_handle, (typeof(CP._handle_close_latest), P, Any)),
                              ("_cancel_abandoned_statement!", CP._cancel_abandoned_statement!, (P, Any)),
                              # both arities: on PostgreSQL and MySQL the 5-argument method forwards to
                              # the 4-argument one, whose body the detector does not follow
                              ("_execute_async/4", CP._execute_async, (P, Any, String, Nothing)),
                              ("_execute_async/5", CP._execute_async, (P, Any, String, Nothing, Nothing)))
        dyn = _dynamic_calls(f, args)
        @test (P, name, dyn) == (P, name, String[])
      end
      for (name, f) in (("_close_driver_handle!", CP._close_driver_handle!),
                        ("finalize_transaction_connection!", CP.finalize_transaction_connection!),
                        ("_discard_connection!", CP._discard_connection!))
        dyn = _dynamic_calls_kw(f, (P, Any))
        @test (P, name, dyn) == (P, name, String[])
      end
    end
    # The caller's side, which is where the probe's row was: a call with the handle typed `Any` (what
    # `acquire_connection` returns) resolves only because the callee takes it `@nospecialize`.
    rel(p, r::Base.RefValue{Any}) = PormG.ConnectionPool.release_connection(p, r[])
    cls(p, r::Base.RefValue{Any}) = PormG.ConnectionPool._close_driver_handle!(p, r[])
    fin(p, r::Base.RefValue{Any}) = PormG.ConnectionPool.finalize_transaction_connection!(p, r[]; renew = true)
    ren(p, r::Base.RefValue{Any}) = PormG.ConnectionPool.reconnect_db(p, r[])
    for P in pools, (name, caller) in (("release_connection", rel), ("_close_driver_handle!", cls),
                                       ("finalize_transaction_connection!", fin), ("reconnect_db", ren))
      dyn = _dynamic_calls(caller, (P, Base.RefValue{Any}))
      @test (P, name, dyn) == (P, name, String[])
    end
    # The barrier hands the callee the handle at the registered type, or a stand-in as it is.
    sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    db = SQLite.DB()
    boxed = Any[db]
    @test CP._with_handle((p, c) -> (p, typeof(c)), sl, boxed[1]) === (sl, SQLite.DB)
    stand_in = Ref(:stand_in_handle)
    @test CP._with_handle((p, c, x) -> (c, x), sl, stand_in, 7) === (stand_in, 7)
    close(db)
    # A driver that is not loaded registers nothing: the default is `Any`, and every handle passes.
    @test PormG.backend_handle_type(_TspStandInPool) === Any
    # Postgres.jl's `Connection` is a `UnionAll`; the type the extension registers must be the one its
    # connect builds, or every handle takes the open arm (a `MethodError` in a trimmed image). No server:
    # the type inference gives the connect call the extension makes.
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    built = Base.return_types(Core.kwcall, (NamedTuple{(:style,), Tuple{pgx._PormGStyle}},
                                            typeof(Postgres.DBInterface.connect), Type{Postgres.Connection},
                                            Postgres.ConnectionParams))
    @test built == Any[PormG.backend_handle_type(CP.PostgresConnectionPool{:postgres})]

    # The sites the reflection above cannot reach (inside a `lock` closure, an `invoke`d callee, a
    # spawned task): by source, every driver call on a handle in `src/` goes through `_with_handle`, and
    # `close` on a handle only through its named helpers. The SQLite
    # worker's two statement calls are the reviewed exception: they run through `_call_latest`, the
    # world-age helper #1609 owns, and are not a #1683 site.
    # Driver generics that take a handle, called directly or handed on as a value (`_call_latest(f, …)`,
    # `invokelatest(f, …)`), and `close` on a handle, called or broadcast.
    generic = raw"backend_(?:is_alive|renew_connection|execute_async|execute_rows|execute|cancel_query!|drain_connection!|copy_in!|ping)"
    driver_call = Regex(raw"\b(" * generic * raw")\(|(?:_call_latest|invokelatest)\((" * generic * raw"|close),")
    close_call = r"(?<!\w)close\.?\((?:conn|retired|dead|new_conn|handle|handles|h|old|pool\.connections)\b"
    # The named helpers the barrier calls, by their exact definitions, and the SQLite worker's two
    # statement calls (#1609's `_call_latest`), each expected exactly once.
    helpers = ("_handle_close(pool, conn) = close(conn)", "_handle_close_latest(pool, conn) = _call_latest(close, conn)",
               "_handle_renew(pool, conn) = backend_renew_connection(pool, conn)",
               "_handle_renew(pool, conn, read_only::Bool) = backend_renew_connection(pool, conn; read_only = read_only)")
    # Backend.jl's default `backend_execute_rows` (a driver without a typed read) is reached only from that
    # worker, so it is the same exception.
    reviewed = ("_call_latest(backend_execute_rows, item.pool, item.conn", "_call_latest(backend_execute, item.pool, item.conn",
                "backend_execute_rows(pool::PormGBackend, conn, sql::String, params, decode) =",
                "decode_on_worker(decode, backend_execute(pool, conn, sql, params))")
    # Every file in src/, AdvisoryLock.jl included since #1708.
    files = sort!([joinpath(root, f) for (root, _, fs) in walkdir(joinpath(pkgdir(PormG), "src")) for f in fs
                   if endswith(f, ".jl")])
    seen = Dict{String,Int}()
    bare = String[]
    for path in files
      file = relpath(path, pkgdir(PormG))
      in_doc = false
      for (i, line) in enumerate(split(replace(read(path, String), "\r\n" => "\n"), '\n'))
        s = strip(line)
        startswith(s, "#") && continue
        isodd(count("\"\"\"", line)) && (in_doc = !in_doc; continue)
        in_doc && continue
        h = findfirst(x -> startswith(s, x), helpers)
        h === nothing || (seen[helpers[h]] = get(seen, helpers[h], 0) + 1; continue)
        r = findfirst(x -> occursin(x, line), reviewed)
        r === nothing || (seen[reviewed[r]] = get(seen, reviewed[r], 0) + 1; continue)
        for m in eachmatch(driver_call, line)
          # handed to the barrier: `_with_handle(` right before the callee
          m.offset > 13 && line[prevind(line, m.offset, 13):prevind(line, m.offset)] == "_with_handle(" && continue
          push!(bare, "$(file):$(i): $(s)")
        end
        occursin(close_call, line) && push!(bare, "$(file):$(i): $(s)")
      end
    end
    @test bare == String[]
    for x in (helpers..., reviewed...)
      @test (x, get(seen, x, 0)) == (x, 1)
    end
  end

  # What: the advisory lock's statements (`with_advisory_lock`, which migrations serialize on), run on
  #   the handle `acquire_connection` leases: the lock and unlock query, the holder read, the
  #   `lock_timeout` probe, set and restore, on each pool type that takes a real lock.
  # Expected: with the handle typed `Any`, as it comes out of a slot, no function that runs them makes a
  #   dynamic driver call or a dynamic call that takes the handle (at the callee, and at a caller): each
  #   statement goes through `_with_handle`. The rows the driver answers are still read as `Any` (the
  #   awaited result is untyped), which is not a handle call and is not pinned here.
  # Why: they called `backend_execute_async(pool, conn::Any, …)` directly, the call shape #1683 removed
  #   from the pool: one dispatch per call under the JIT, and in a trimmed image a call nothing was
  #   compiled for, on the path a trimmed app that migrates at start meets first (#1708).
  @testset "the advisory lock's statements reach the driver at the handle's concrete type (#1708)" begin
    CP = PormG.ConnectionPool
    AL = PormG.AdvisoryLock
    S = AL._LockAwaitState
    R = Base.RefValue{Any}
    # The calls that take the handle: the driver generic, the barrier, and the lock helpers themselves
    # (`_block_lock!` calls `_exec_lock_query`).
    handle_calls = ("backend_execute_async", "_with_handle", "_with_unlisted_handle", "_exec_lock_query")
    # MySQL's `_restore_block_timeout!` is a no-op (nothing is set on its session), so it is not listed.
    for P in (CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres}, CP.MySQLConnectionPool)
      for (name, f, args) in (("_exec_lock_query", AL._exec_lock_query, (P, Any, String, String, S)),
                              ("_lock_holder_text", AL._lock_holder_text, (P, Any, String, S)),
                              ("_block_lock!", AL._block_lock!, (P, Any, String, Int, S, R)),
                              ("_restore_block_timeout!", AL._restore_block_timeout!, (P, Any, Any, Symbol, S)))
        P === CP.MySQLConnectionPool && f === AL._restore_block_timeout! && continue
        dyn = _named_dynamic_calls(Base.signature_type(f, args), handle_calls)
        @test (P, name, dyn) == (P, name, String[])
      end
    end
    # The caller's side: `with_advisory_lock` holds the leased handle as `Any` (and, in its `finally`, the
    # saved `lock_timeout` too), and each call resolves only because the callee takes them `@nospecialize`.
    exq(p, r::Base.RefValue{Any}, s) = PormG.AdvisoryLock._exec_lock_query(p, r[], "SELECT 1", "k", s)
    hld(p, r::Base.RefValue{Any}, s) = PormG.AdvisoryLock._lock_holder_text(p, r[], "k", s)
    blk(p, r::Base.RefValue{Any}, s) = PormG.AdvisoryLock._block_lock!(p, r[], "k", 5, s, Ref{Any}(nothing))
    rst(p, r::Base.RefValue{Any}, s) = PormG.AdvisoryLock._restore_block_timeout!(p, r[], r[], :block, s)
    for P in (CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres}, CP.MySQLConnectionPool),
        (name, caller) in (("_exec_lock_query", exq), ("_lock_holder_text", hld), ("_block_lock!", blk),
                           ("_restore_block_timeout!", rst))
      P === CP.MySQLConnectionPool && caller === rst && continue   # the no-op, as above
      dyn = _dynamic_calls(caller, (P, Base.RefValue{Any}, S))
      @test (P, name, dyn) == (P, name, String[])
    end
    # And the terminal that holds the lease: `with_advisory_lock` on a concrete pool makes one dynamic call,
    # the abandon-only renewal (before #1708 it made one at each call that handed the leased handle on).
    # That call passes the abandoned statement's handle, which `_LockAwaitState` holds as `Any`. Taking it
    # `@nospecialize` in `_recover_abandoned_connection!` would move a dynamic call into the recovery's
    # spawned task for two of the pool's callers, which pass it concretely; typing the state is not #1708's.
    body = () -> nothing
    for P in (CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres}, CP.MySQLConnectionPool)
      dyn = _dynamic_calls_kw(PormG.AdvisoryLock.with_advisory_lock, (typeof(body), P, String))
      renewal = filter(d -> occursin("_recover_abandoned_connection!", d), dyn)
      @test (P, "with_advisory_lock", setdiff(dyn, renewal)) == (P, "with_advisory_lock", String[])
      # present, so the exception above is the one the code has (one call; the `finally` is lowered twice)
      @test (P, "the abandon-only renewal", !isempty(renewal)) == (P, "the abandon-only renewal", true)
    end
  end

  # What: the pool's error path, which receives the failure from a `catch e` (typed `Any`) and classifies
  #   it: `_as_database_error` and the helpers it and `fetch`'s retry decision call, and the extension
  #   classifiers they reach (`backend_classify_error`, `backend_is_connection_error`,
  #   `backend_is_retry_safe`, `backend_is_permanent_connect_error`, `backend_error_fields(pool, e)`).
  # Expected: a caller holding the exception as `Any` makes no dynamic call into any of them, on each
  #   pool type PormG builds; and for a driver-shaped exception on each pool type, the error built is the
  #   one built before #1696 — type, the five fields and the `showerror` text, recorded on the parent
  #   commit — including an exception the extension does not know, the async envelope, the fields LibPQ
  #   hands in itself (`SubString`s, stored as `String`), and a PormG error passed through.
  # Why: each of these dispatched on the exception's run-time type, and a trimmed image had compiled
  #   nothing for a driver's exception type, so a failing statement raised a `MethodError` in place of
  #   the `IntegrityError` (#1696; 208 verifier rows at `fetch_async`'s and `fetch`'s catch sites on the
  #   fixture). The classification itself must not move: apps `catch IntegrityError`.
  @testset "a caught exception is classified without dispatching on its type (#1696)" begin
    CP = PormG.ConnectionPool
    pools = (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
             CP.MySQLConnectionPool)
    callers = (
      ("_as_database_error", (p, r::Base.RefValue{Any}) -> PormG.ConnectionPool._as_database_error(p, r[])),
      ("_driver_cause", (p, r::Base.RefValue{Any}) -> PormG.ConnectionPool._driver_cause(r[])),
      ("_unwrap_async_exception", (p, r::Base.RefValue{Any}) -> PormG.ConnectionPool._unwrap_async_exception(r[])),
      ("_await_abandoned", (p, r::Base.RefValue{Any}) -> PormG.ConnectionPool._await_abandoned(r[])),
      ("_is_benign_rollback_error", (p, r::Base.RefValue{Any}) -> PormG.ConnectionPool._is_benign_rollback_error(p, r[])),
      ("_lost_connection_error", (p, r::Base.RefValue{Any}) -> PormG.ConnectionPool._lost_connection_error(p, r[])),
      ("backend_classify_error", (p, r::Base.RefValue{Any}) -> PormG.backend_classify_error(p, r[])),
      ("backend_is_connection_error", (p, r::Base.RefValue{Any}) -> PormG.backend_is_connection_error(p, r[])),
      ("backend_is_retry_safe", (p, r::Base.RefValue{Any}) -> PormG.backend_is_retry_safe(p, r[])),
      ("backend_is_permanent_connect_error", (p, r::Base.RefValue{Any}) -> PormG.backend_is_permanent_connect_error(p, r[])),
      ("backend_error_fields", (p, r::Base.RefValue{Any}) -> PormG.backend_error_fields(p, r[])))
    for P in pools, (name, caller) in callers
      dyn = _dynamic_calls(caller, (P, Base.RefValue{Any}))
      @test (P, name, dyn) == (P, name, String[])
    end

    # The error built, before and after #1696 (recorded on the parent commit with the same inputs).
    E = LibPQ.Errors
    sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    lp = CP.PostgresConnectionPool("host=x"; pool_size = 1, driver = :libpq)
    pj = CP.PostgresConnectionPool("host=x"; pool_size = 1, driver = :postgres)
    my = CP.MySQLConnectionPool("host='x'"; pool_size = 1)
    pgjl(code, msg; constraint = nothing, table = nothing, column = nothing) = Postgres.Error("ERROR", code, msg,
      "Key (code)=(x) already exists.", nothing, nothing, nothing, nothing, nothing, "public", table, column,
      nothing, constraint, nothing, nothing, nothing)
    task_failed(e) = try; fetch(Threads.@spawn throw(e)); catch t; t; end
    tail = " (the driver's full text is in `.cause`)"
    N = nothing
    cases = (
      (sl, SQLite.SQLiteException("UNIQUE constraint failed: driver.code"), PormG.IntegrityError,
       (N, N, N, N, "UNIQUE constraint failed: driver.code"),
       "IntegrityError: SQLite rejected the statement — a constraint was violated: UNIQUE constraint failed: driver.code" * tail),
      (sl, SQLite.SQLiteException("no such table: circuit"), PormG.StatementError, (N, N, N, N, "no such table: circuit"),
       "StatementError: the SQLite statement could not be executed: no such table: circuit" * tail),
      (sl, SQLite.SQLiteException("database is locked"), PormG.OperationalError, (N, N, N, N, "database is locked"),
       "OperationalError: the SQLite operation could not complete and may succeed on retry: database is locked" * tail),
      (sl, SQLite.SQLiteException("integer overflow"), PormG.StatementError, ("22003", N, N, N, "integer overflow"),
       "StatementError: the SQLite statement could not be executed (SQLSTATE 22003): integer overflow" * tail),
      (sl, ErrorException("boom"), PormG.StatementError, (N, N, N, N, N),
       "StatementError: the SQLite statement could not be executed: ErrorException" * tail),
      (sl, task_failed(SQLite.SQLiteException("UNIQUE constraint failed: driver.code")), PormG.IntegrityError,
       (N, N, N, N, "UNIQUE constraint failed: driver.code"),
       "IntegrityError: SQLite rejected the statement — a constraint was violated: UNIQUE constraint failed: driver.code" * tail),
      (lp, E.PQResultError{E.C23, E.E23505}("ERROR:  duplicate key value violates unique constraint \"driver_code_key\"\nDETAIL:  Key (code)=(x) already exists.\n"),
       PormG.IntegrityError, ("23505", N, N, N, "duplicate key value violates unique constraint \"driver_code_key\""),
       "IntegrityError: PostgreSQL rejected the statement — a constraint was violated (SQLSTATE 23505): duplicate key value violates unique constraint \"driver_code_key\"" * tail),
      (lp, E.PQResultError{E.C42, E.E42703}("ERROR:  column \"nickname\" does not exist\nLINE 1: SELECT nickname\n"),
       PormG.StatementError, ("42703", N, N, N, "column \"nickname\" does not exist"),
       "StatementError: the PostgreSQL statement could not be executed (SQLSTATE 42703): column \"nickname\" does not exist" * tail),
      (lp, E.PQResultError{E.CUN, E.EUNOWN}("server closed the connection unexpectedly"), PormG.OperationalError,
       (N, N, N, N, N), "OperationalError: the PostgreSQL operation could not complete and may succeed on retry: PQResultError" * tail),
      (lp, E.PQConnectionError("no connection to the server"), PormG.OperationalError, (N, N, N, N, N),
       "OperationalError: the PostgreSQL operation could not complete and may succeed on retry: PQConnectionError" * tail),
      (lp, ErrorException("boom"), PormG.StatementError, (N, N, N, N, N),
       "StatementError: the PostgreSQL statement could not be executed: ErrorException" * tail),
      (pj, pgjl("23505", "duplicate key value violates unique constraint \"driver_code_key\""; constraint = "driver_code_key",
                table = "driver", column = "code"), PormG.IntegrityError,
       ("23505", "driver_code_key", "driver", "code", "duplicate key value violates unique constraint \"driver_code_key\""),
       "IntegrityError: PostgreSQL rejected the statement — a constraint was violated (SQLSTATE 23505, constraint \"driver_code_key\", table \"driver\", column \"code\"): duplicate key value violates unique constraint \"driver_code_key\"" * tail),
      (pj, pgjl("40P01", "deadlock detected"), PormG.OperationalError, ("40P01", N, N, N, "deadlock detected"),
       "OperationalError: the PostgreSQL operation could not complete and may succeed on retry (SQLSTATE 40P01): deadlock detected" * tail),
      (pj, EOFError(), PormG.OperationalError, (N, N, N, N, N),
       "OperationalError: the PostgreSQL operation could not complete and may succeed on retry: EOFError" * tail),
      (pj, ArgumentError("boom"), PormG.StatementError, (N, N, N, N, N),
       "StatementError: the PostgreSQL statement could not be executed: ArgumentError" * tail),
      (my, EOFError(), PormG.OperationalError, (N, N, N, N, N),
       "OperationalError: the MySQL operation could not complete and may succeed on retry: EOFError" * tail),
      (my, ErrorException("boom"), PormG.StatementError, (N, N, N, N, N),
       "StatementError: the MySQL statement could not be executed: ErrorException" * tail),
      (my, ArgumentError("boom"), PormG.StatementError, (N, N, N, N, N),
       "StatementError: the MySQL statement could not be executed: ArgumentError" * tail))
    # Stand-in pools under the PostgreSQL and SQLite markers keep reading any driver's exception, and a
    # test's own reader, through the one-argument form; MySQL's server errors; Postgres.jl's coded drop.
    mockpg, mocksl = _TspStandInPGPool(), _TspStandInPool()
    my_dup = MySQL.Protocol.Error(UInt32(1062), "Duplicate entry 'monaco' for key 'circuit.circuitref'", "23000")
    my_syntax = MySQL.Protocol.Error(UInt32(1064), "You have an error in your SQL syntax near 'x'", "42000")
    pgjl_shutdown = pgjl("57P01", "terminating connection due to administrator command")
    more = (
      (mockpg, cases[12][2], PormG.StatementError,
       ("23505", "driver_code_key", "driver", "code", "duplicate key value violates unique constraint \"driver_code_key\""),
       "StatementError: the PostgreSQL statement could not be executed (SQLSTATE 23505, constraint \"driver_code_key\", table \"driver\", column \"code\"): duplicate key value violates unique constraint \"driver_code_key\"" * tail),
      (mockpg, SQLite.SQLiteException("integer overflow"), PormG.StatementError, ("22003", N, N, N, "integer overflow"),
       "StatementError: the PostgreSQL statement could not be executed (SQLSTATE 22003): integer overflow" * tail),
      (mockpg, _TspFakeError(), PormG.StatementError, ("XX000", "fake_c", "fake_t", N, "fake"),
       "StatementError: the PostgreSQL statement could not be executed (SQLSTATE XX000, constraint \"fake_c\", table \"fake_t\"): fake" * tail),
      (mocksl, cases[12][2], PormG.StatementError,
       ("23505", "driver_code_key", "driver", "code", "duplicate key value violates unique constraint \"driver_code_key\""),
       "StatementError: the SQLite statement could not be executed (SQLSTATE 23505, constraint \"driver_code_key\", table \"driver\", column \"code\"): duplicate key value violates unique constraint \"driver_code_key\"" * tail),
      (mocksl, _TspFakeError(), PormG.StatementError, ("XX000", "fake_c", "fake_t", N, "fake"),
       "StatementError: the SQLite statement could not be executed (SQLSTATE XX000, constraint \"fake_c\", table \"fake_t\"): fake" * tail),
      (my, my_dup, PormG.IntegrityError, ("23000", "circuitref", "circuit", N, N),
       "IntegrityError: MySQL rejected the statement — a constraint was violated (SQLSTATE 23000, constraint \"circuitref\", table \"circuit\"): Error" * tail),
      (my, my_syntax, PormG.StatementError, ("42000", N, N, N, N),
       "StatementError: the MySQL statement could not be executed (SQLSTATE 42000): Error" * tail),
      (pj, pgjl_shutdown, PormG.OperationalError, ("57P01", N, N, N, "terminating connection due to administrator command"),
       "OperationalError: the PostgreSQL operation could not complete and may succeed on retry (SQLSTATE 57P01): terminating connection due to administrator command" * tail))
    for (pool, cause, T, fields, text) in (cases..., more...)
      err = CP._as_database_error(pool, cause)
      @test typeof(err) === T
      @test (err.sqlstate, err.constraint, err.table, err.column, err.message) == fields
      @test sprint(showerror, err) == text
    end
    refused = PormG.InvalidValueError("refused")
    @test CP._as_database_error(sl, refused) === refused
    # LibPQ reads the fields off the failed result itself and hands them in (#1000), as `SubString`s.
    given = (sqlstate = SubString("23505x", 1, 5), constraint = "driver_code_key", table = "driver", column = nothing,
             message = SubString("duplicate key!", 1, 13))
    err = CP._as_database_error(lp, cases[7][2]; fields = given)
    @test err isa PormG.IntegrityError
    @test (err.sqlstate, err.constraint, err.table, err.column, err.message) == ("23505", "driver_code_key", "driver", N, "duplicate key")
    @test err.sqlstate isa String && err.message isa String
    # The retry gate keeps its answers: a codeless drop is not retried; a coded one in a composite is.
    @test !PormG.backend_is_retry_safe(lp, cases[9][2])
    @test !PormG.backend_is_retry_safe(lp, ErrorException("x"))
    @test PormG.backend_is_retry_safe(lp, CompositeException([E.PQConnectionError("no connection to the server")]))
    @test !PormG.backend_is_retry_safe(pj, EOFError())
    @test !PormG.backend_is_retry_safe(sl, ErrorException("x"))
    @test PormG.backend_is_retry_safe(pj, pgjl_shutdown)          # the server said the statement never ran
    @test !PormG.backend_is_retry_safe(my, my_dup)
    @test !PormG.backend_is_retry_safe(my, ErrorException("x"))
    # A fields record that leaves a key out reads `nothing` for it, as the keyword constructors did.
    short = CP._as_database_error(lp, cases[7][2]; fields = (sqlstate = "23505", message = "duplicate key"))
    @test (short.sqlstate, short.constraint, short.table, short.column, short.message) == ("23505", N, N, N, "duplicate key")
  end

  # What: the bodies the #1696 testset above reaches, followed three `:invoke`s down (#1714): the five
  #   extension classifiers and `_as_database_error`, at `(pool, Any)` on each pool type PormG builds,
  #   and how they classify an exception their driver does not own.
  # Expected: no dynamic call anywhere in them, except inside the named open arms (`_unowned_string`,
  #   `_unowned_error_text`, `_unowned_inner`, MySQL's `_other_server_*`), which are not walked into: each
  #   reads an exception the driver does not own the only way it can be read, by `string` or by a field
  #   looked up by name. And the answers for such exceptions are the ones main gave (recorded there): a
  #   foreign error's text still matches a phrase, LibPQ's `verbose_msg` is still read, a wrapper's
  #   `.cause`/`.err` is still opened, four levels deep and no more.
  # Why: #1696 made the calls INTO these bodies static; their own calls on the exception, or on a driver
  #   field typed abstract (`SQLiteException.msg::AbstractString`, MySQL's abstract `ServerError`), were
  #   still dynamic (23/21/4/14 on SQLite/LibPQ/Postgres.jl/MySQL), so a failing statement in a trimmed
  #   image could end in a `MethodError` from the classification in place of the `IntegrityError`.
  @testset "the classifier bodies make no dynamic call on the exception (#1714)" begin
    CP = PormG.ConnectionPool
    pools = (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
             CP.MySQLConnectionPool)
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    open_arms = (PormG._unowned_string, PormG._unowned_error_text, PormG._unowned_inner,
                 myx._other_server_errno, myx._other_server_text, myx._other_server_fields)
    for P in pools, f in (CP._as_database_error, PormG.backend_classify_error, PormG.backend_is_connection_error,
                          PormG.backend_is_retry_safe, PormG.backend_is_permanent_connect_error, PormG.backend_error_fields)
      dyn = _dynamic_calls_deep(f, (P, Any); depth = 3, skip = open_arms)
      @test (P, nameof(f), dyn) == (P, nameof(f), String[])
    end
    # Every reader on a pool PormG builds returns the one record type, so `_as_database_error`'s
    # constructors are static calls.
    for P in pools
      @test (P, Base.return_types(PormG.backend_error_fields, (P, Any))) == (P, Any[PormG._ErrorFields])
    end

    # The open arm is for what the driver does NOT own: at an owned exception type the text helpers do not
    # reach it (a body that sent its own exceptions back through `string(e)` would pass the walk above,
    # which does not look inside the open arms). At a foreign type they do, so the check can fail.
    lpx = Base.get_extension(PormG, :PormGLibPQExt)
    slx = Base.get_extension(PormG, :PormGSQLiteExt)
    # The types of what the text helper hands to an open arm (`_unowned_*`): at an owned type only a message
    # string may go there (SQLite's `msg` when it is not a `String`), never the exception itself.
    function open_arm_args(f, T)
      ci = only(code_typed(f, (T,); optimize = true))[1]
      argtype(a) = a isa Core.SSAValue ? Core.Compiler.widenconst(ci.ssavaluetypes[a.id]) :
                   a isa Core.Argument ? Core.Compiler.widenconst(ci.slottypes[a.n]) : Core.Typeof(a)
      found = Any[]
      for st in ci.code
        (st isa Expr && st.head in (:invoke, :call) && occursin("_unowned_", string(st))) || continue
        push!(found, argtype(st.args[end]))
      end
      return found
    end
    for (f, T) in ((slx._sqlite_text, SQLite.SQLiteException), (lpx._libpq_text, LibPQ.Errors.PQConnectionError),
                   (lpx._libpq_text, LibPQ.Errors.PQResultError), (lpx._libpq_text, LibPQ.Errors.ConninfoParseError))
      @test (nameof(f), T, all(A -> A <: AbstractString, open_arm_args(f, T))) == (nameof(f), T, true)
    end
    @test isempty(open_arm_args(lpx._libpq_text, LibPQ.Errors.PQConnectionError))
    @test any(A -> !(A <: AbstractString), open_arm_args(slx._sqlite_text, ErrorException)) &&
          any(A -> !(A <: AbstractString), open_arm_args(lpx._libpq_text, ErrorException))

    # The answers for what a driver does not own, and for the shapes the narrowing reads, as main gave them.
    sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    lp = CP.PostgresConnectionPool("host=x"; pool_size = 1, driver = :libpq)
    pj = CP.PostgresConnectionPool("host=x"; pool_size = 1, driver = :postgres)
    my = CP.MySQLConnectionPool("host='x'"; pool_size = 1)
    E = LibPQ.Errors
    wrap(e, n = 1) = n == 0 ? e : wrap(_TspWrap(e), n - 1)
    conn(p, e) = PormG.backend_is_connection_error(p, e)
    perm(p, e) = PormG.backend_is_permanent_connect_error(p, e)
    # SQLite: a foreign error's text, a message that is not a `String`, a message `show` would escape.
    @test conn(sl, ErrorException("database is closed"))
    @test perm(sl, _TspPlainError("unable to open database file"))
    @test conn(sl, SQLite.SQLiteException("say \"database is closed\" twice\n"))
    locked = SQLite.SQLiteException(SubString("xdatabase is lockedx", 2, 19))
    @test PormG.backend_classify_error(sl, locked) === :operational
    @test PormG.backend_error_fields(sl, locked) == (sqlstate = nothing, constraint = nothing, table = nothing,
                                                    column = nothing, message = "database is locked")
    # LibPQ: a foreign error's text; `verbose_msg` read; the codeless empty `UnknownError`, and not one with
    # an empty `verbose_msg`; a phrase split between `msg` and `verbose_msg` matches neither.
    @test conn(lp, ErrorException("server closed the connection unexpectedly"))
    @test conn(lp, _TspPlainError("SSL SYSCALL error: EOF detected"))
    @test perm(lp, ErrorException("password authentication failed for user x"))
    @test conn(lp, E.PQResultError{E.CUN, E.EUNOWN}("x", "SSL connection has been closed unexpectedly"))
    @test conn(lp, E.PQResultError{E.CUN, E.EUNOWN}(""))
    @test !conn(lp, E.PQResultError{E.CUN, E.EUNOWN}("", ""))
    @test !conn(lp, E.PQResultError{E.CUN, E.EUNOWN}("server closed the", "connection"))
    # A malformed character (a server message in a LATIN1 locale) is classified, never raised: `lowercase`
    # throws on one, and the classification must not replace the failure it reports (review).
    latin1 = E.PQConnectionError("FATAL:  password authentication failed for user \"jos\xe7\"")
    @test perm(lp, latin1)
    @test conn(lp, E.PQResultError{E.CUN, E.EUNOWN}("server closed the connection unexpectedly \xe7"))
    @test CP._as_database_error(lp, latin1) isa PormG.OperationalError
    @test !PormG.backend_is_retry_safe(lp, latin1)
    @test PormG.backend_error_fields(sl, SQLite.SQLiteException("database is locked \xe7")).message == "database is locked \xe7"
    @test conn(sl, SQLite.SQLiteException("database is closed \xe7"))
    @test PormG.backend_classify_error(sl, SQLite.SQLiteException("UNIQUE constraint failed: x \xe7")) === :integrity
    # Postgres.jl and MySQL: wrappers opened four levels deep and no more; a socket error by name; a
    # multi-result failure; MySQL.jl's own text when its message is not a `String`; the server errors.
    for p in (pj, my)
      @test conn(p, wrap(EOFError()))
      @test conn(p, _TspWrapErr(SystemError("read", Libc.EPIPE)))
      @test conn(p, wrap(EOFError(), 4)) && !conn(p, wrap(EOFError(), 5))
      @test !conn(p, wrap(ErrorException("x"))) && !conn(p, wrap(1))
      @test conn(p, CompositeException([ErrorException("a"), EOFError()]))
    end
    @test conn(my, ErrorException(SubString("xmysql connection has been closed or disconnected", 2)))
    @test PormG.backend_classify_error(my, MySQL.Protocol.StmtError(UInt32(1205), "Lock wait timeout exceeded", "HY000")) === :operational
    @test PormG.backend_classify_error(my, MySQL.Protocol.Error(UInt32(9999), "x", "40001")) === :operational
    @test PormG.backend_classify_error(pj, Postgres.Error("ERROR", "4", "one char", nothing, nothing, nothing,
      nothing, nothing, nothing, "public", nothing, nothing, nothing, nothing, nothing, nothing, nothing)) === :statement
  end

  # What: `_call_latest`, the pool's one call into the latest world (the SQLite worker's statements, a
  #   deferred, reaped, retired or abandoned close), under the JIT and under a simulation of the build
  #   `juliac --trim` makes: JuliaC rebinds `Base.invokelatest` to a direct call (`juliac-trim-base.jl`)
  #   before it compiles, which invalidates nothing, so stored IR keeps the builtin.
  # Expected: no caller holds an inlined copy of it (the close helper `:invoke`s it). In a child process,
  #   the package image stores no IR for `_call_latest(close, SQLite.DB)`, and after JuliaC's two lines the
  #   walk (stored IR where there is some, a fresh inference where there is none) finds the builtin in no
  #   PormG function `_call_latest` is reached through. Under the JIT it still calls the builtin, and a
  #   method defined after a task started is seen from that task.
  # Why: the verifier does not accept the builtin on any signature. With `@inline _call_latest`, 13 rows
  #   at four of the six sites in the trimmed fixture on main named it, every one through stored IR that
  #   held an inlined copy; with `@noinline`, none (#1609). The pin simulates the build, it does not run
  #   it: the `test/trim` fixture build is the measurement.
  @testset "a trimmed build calls _call_latest's function directly; the JIT keeps the latest world (#1609)" begin
    CP = PormG.ConnectionPool
    P = CP.SQLiteConnectionPool
    code(f, tt) = only(code_typed(f, tt; optimize = true))[1].code
    builtin(st) = st isa Expr && st.head === :call && (st.args[1] === Core.invokelatest ||
      (st.args[1] isa GlobalRef && isdefined(st.args[1].mod, st.args[1].name) &&
       getglobal(st.args[1].mod, st.args[1].name) === Core.invokelatest))
    calls(f, tt, g) = any(st -> st isa Expr && st.head === :invoke &&
      (mi = st.args[1]; mi isa Core.CodeInstance ? mi.def : mi).def === only(methods(g)), code(f, tt))
    # The JIT: the builtin is in `_call_latest`, and the close helper calls it rather than inlining it.
    # With `--inline=no` every caller calls it whatever the annotation, so those two checks say nothing
    # there and are skipped (coverage and `-O0` keep inlining on).
    @test any(builtin, code(CP._call_latest, (typeof(close), SQLite.DB)))
    if Base.JLOptions().can_inline == 0
      @test_skip calls(CP._handle_close_latest, (P, SQLite.DB), CP._call_latest)
      @test_skip !any(builtin, code(CP._handle_close_latest, (P, SQLite.DB)))
    else
      @test calls(CP._handle_close_latest, (P, SQLite.DB), CP._call_latest)
      @test !any(builtin, code(CP._handle_close_latest, (P, SQLite.DB)))
    end
    # The latest world, from a task started before the method existed.
    late = Core.eval(Main, :(function $(gensym(:tsp_late)) end))
    go = Channel{Nothing}(1)
    t = Threads.@spawn (take!(go); (CP._call_latest(late, 1), try late(1) catch e; e end))
    Core.eval(Main, :($(nameof(late))(x::Int) = x + 41))
    put!(go, nothing)
    via_helper, direct = fetch(t)
    @test via_helper === 42
    @test direct isa MethodError   # the task's own world predates the method, so the check has teeth

    # The trimmed build, simulated in a child: what the image stored, then JuliaC's two lines verbatim.
    script = """
      using PormG, SQLite
      const CP = PormG.ConnectionPool
      const P = CP.SQLiteConnectionPool
      # What the image stored for `_call_latest(close, SQLite.DB)`, before anything here infers it: "ir"
      # (IR a build would reuse, builtin included), "nothing" (a build re-infers it), or "none" (no entry).
      function stored(mi)
        ci = isdefined(mi, :cache) ? mi.cache : nothing
        ci === nothing && return "none"
        while ci !== nothing
          (ci.inferred isa String || ci.inferred isa Core.CodeInfo) && return "ir"
          ci = isdefined(ci, :next) ? ci.next : nothing
        end
        return "nothing"
      end
      println("stored=", stored(Base.method_instance(CP._call_latest, (typeof(close), SQLite.DB))))
      builtin(st) = st isa Expr && st.head === :call && (st.args[1] === Core.invokelatest ||
        (st.args[1] isa GlobalRef && isdefined(st.args[1].mod, st.args[1].name) &&
         getglobal(st.args[1].mod, st.args[1].name) === Core.invokelatest))
      # The PormG methods whose optimized code holds the builtin, following `:invoke`s four levels down.
      # `code_typed` returns the stored IR where there is some and infers afresh where there is none.
      function holders(tt, d = 4, seen = Set{Any}())
        tt in seen && return String[]
        push!(seen, tt)
        out = String[]
        for (ci, _) in Base.code_typed_by_type(tt; optimize = true), st in ci.code
          builtin(st) && push!(out, string(tt))
          (st isa Expr && st.head === :invoke && d > 0) || continue
          mi = st.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
          (mi isa Core.MethodInstance && mi.def isa Method && PormG in (mi.def.module, parentmodule(mi.def.module))) &&
            append!(out, holders(mi.specTypes, d - 1, seen))
        end
        return out
      end
      sigs = (Tuple{typeof(CP.release_connection), P, Any},
              Tuple{typeof(CP._with_handle), typeof(CP._handle_close_latest), P, Any},
              Tuple{typeof(CP._handle_close_latest), P, SQLite.DB},
              Tuple{typeof(CP._call_latest), typeof(close), SQLite.DB})
      before = [!isempty(holders(s)) for s in sigs]
      @eval Base begin
        invokelatest_trimmed(f, args...; kwargs...) = f(args...; kwargs...)
        const invokelatest = invokelatest_trimmed
      end
      after = unique!(reduce(vcat, [holders(s) for s in sigs]))
      println("before=", join(before, ","))
      println("after=", join(after, ";"))
      """
    out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`, String)
    # A Julia that stores IR for a `@noinline` method turns this red: a build would reuse it, builtin included.
    @test occursin(r"^stored=(nothing|none)$"m, out)
    @test occursin("before=true,true,true,true", out)   # the walk sees the builtin before the rebinding
    @test occursin(r"^after=$"m, out)
  end

  # What: the pool-keyed registries, the waiter queues (`_POOL_WAITERS`, #124) and the monitor state
  #   (`_POOL_MONITOR`, #125/#127/#1548), which hold per-pool state outside the pool structs.
  # Expected: a lookup, a `get!` and `release_connection` (which reads the waiter queue on every
  #   return) make no dynamic call on each pool type PormG builds; the registry is keyed by identity (two
  #   pools with the same settings are two entries) and weak (a collected pool's entry goes, and it holds
  #   no pool alive); `getindex` of a missing pool is a `KeyError`; `get!`, `haskey`, `delete!`, `empty!`
  #   behave as a `Dict`'s; a stand-in pool is a key like any other.
  # Why: both were `WeakKeyDict{Any,…}`, which hashes its key through `hash(::WeakRef)`, a dynamic
  #   `hash(::Any)`: with the handle calls resolved (#1683), every trimmed lease ended in a `MethodError`
  #   on `hash` in `release_connection` (#1706). The tests and the sweeper use the `Dict`-shaped methods.
  @testset "the pool-keyed registries key on identity, without hashing (#1706)" begin
    CP = PormG.ConnectionPool
    pools = (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
             CP.MySQLConnectionPool)
    waiters(p) = PormG.ConnectionPool._waiters_for(p)
    monitor(p) = PormG.ConnectionPool._monitor_state(p)
    peek(p) = get(PormG.ConnectionPool._POOL_WAITERS, p, PormG.ConnectionPool.PoolWaiter[])
    rel(p, r::Base.RefValue{Any}) = PormG.ConnectionPool.release_connection(p, r[])
    for P in pools
      @test (P, "release_connection", _dynamic_calls(rel, (P, Base.RefValue{Any}))) == (P, "release_connection", String[])
      # The lookups themselves, all the way down: the `WeakKeyDict` they replace resolved at this level and
      # dispatched inside, on `WeakRef` (`hash`/`isequal` in `rehash!` under `get!` every session; in some
      # sessions `isequal(pool, ::WeakRef)` on every lookup too), which only the deep walk sees.
      for (name, f) in (("_waiters_for", waiters), ("_monitor_state", monitor), ("get(_POOL_WAITERS, …)", peek))
        # depth 12: the `WeakKeyDict`'s `hash`/`isequal` on `WeakRef` sit under `lock` → closure → `get!`
        # → `lock` → closure → `rehash!`; how much of that inference folds varies by session, and at 6
        # one run of the parent's registry showed nothing.
        dyn = _dynamic_calls_deep(f, (P,); depth = 12)
        @test (P, name, dyn) == (P, name, String[])
      end
    end
    @test CP._POOL_WAITERS isa CP._PoolRegistry && CP._POOL_MONITOR isa CP._PoolRegistry
    src = read(joinpath(pkgdir(PormG), "src", "ConnectionPool.jl"), String)
    @test !occursin(r"^const .*WeakKeyDict"m, src)

    R = CP._PoolRegistry{Vector{Int}}()
    a = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    b = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)   # the same settings: another pool, another key
    @test !haskey(R, a) && get(R, a, :none) === :none && isempty(R)
    @test_throws KeyError R[a]
    R[a] = [1]
    @test R[a] == [1] && haskey(R, a) && !haskey(R, b) && length(R) == 1
    @test get!(() -> [2], R, b) == [2] && get!(() -> [3], R, b) == [2]   # created once, then found
    @test length(R) == 2 && Set(map(objectid, CP._registry_pools(R))) == Set(objectid.((a, b)))
    delete!(R, a)
    @test !haskey(R, a) && haskey(R, b)
    stand_in = _TspStandInPool()
    R[stand_in] = [4]
    @test R[stand_in] == [4]
    empty!(R)
    @test isempty(R) && !haskey(R, b)
    # Weak: an entry does not keep its pool alive, and a collected pool's entry is gone.
    weak = CP._PoolRegistry{Vector{Int}}()
    _tsp_insert_unreferenced!(weak)
    GC.gc(true); GC.gc(true)
    @test isempty(CP._registry_pools(weak))
    weak[b] = [6]                                       # an insert purges what was collected
    @test length(weak.entries) == 1
  end

  # What: the "load the driver" fallbacks of the backend generics (Backend.jl's loop), called the way the
  #   pool calls them: with a handle or a caught exception typed `Any`, positionally and with a keyword.
  # Expected: on a pool type whose driver method does not apply (the three stand-ins), each call is
  #   static, and it raises the `InvalidConfigurationError` it always raised, keyword or not.
  # Why: a vararg method specializes on each argument, so a call with an `Any` argument dispatched at run
  #   time: 54 rows of the SQLite fixture, on MySQL and PostgreSQL pools whose driver that binary does not
  #   load (`_with_handle`'s execute and liveness probe, the classifiers). The keyword form is its own
  #   `Core.kwcall` method, since `; kwargs...` on the positional one splats the untyped vararg into the
  #   keyword body, a dynamic `_apply_iterate` (#1599 layer 2).
  @testset "a missing driver's fallback is a static call, with and without keywords (#1599 layer 2)" begin
    fns = (PormG.backend_connect, PormG.backend_renew_connection, PormG.backend_is_alive, PormG.backend_execute,
           PormG.backend_execute_async, PormG.backend_is_connection_error, PormG.backend_is_permanent_connect_error,
           PormG.backend_cancel_query!, PormG.backend_drain_connection!, PormG.backend_num_affected_rows,
           PormG.backend_num_rows, PormG.backend_last_insert_id, PormG.backend_copy_in!, PormG.backend_insert_report,
           PormG.backend_is_duplicate_key, PormG.backend_sqlite_version, PormG.backend_mysql_version)
    checked = 0
    for S in (_TspStandInPool, _TspStandInPGPool, _TspStandInMyPool), fn in fns
      # Only where core's fallback is the one method that applies: the extensions define some generics on
      # the markers themselves (`PormGSQLite`, `PormGPostgres`), and those answer for a stand-in.
      # Each shape pinned below: only core's method may apply to it.
      core_only(sig) = (ms = methods(fn, sig); length(ms) == 1 && only(ms).module === PormG)
      (core_only((S, Any)) && core_only((S, Any, Any, String))) || continue
      checked += 1
      one(p, r::Base.RefValue{Any}) = fn(p, r[])
      four(p, r::Base.RefValue{Any}) = fn(p, r[], r[], "SELECT 1")
      kw(p, r::Base.RefValue{Any}) = fn(p, r[]; read_only = true)
      for (shape, caller) in (("one", one), ("four", four), ("keyword", kw))
        @test (S, fn, shape, _dynamic_calls(caller, (S, Base.RefValue{Any}))) == (S, fn, shape, String[])
      end
      @test_throws PormG.InvalidConfigurationError fn(S(), :handle)
      @test_throws PormG.InvalidConfigurationError fn(S(), :handle, :x, "SELECT 1")
      @test_throws PormG.InvalidConfigurationError fn(S(), :handle; read_only = true)
    end
    @test checked >= 30
  end

  # What: the NUL check at the execution funnel (`_refuse_nul`, #951) over each collector's values.
  # Expected: no dynamic call in it, in the typed loop or in the walk it calls, for each collector type;
  #   the walk answers what `_contains_nul` answers for every value shape a statement binds, and a NUL
  #   in a raw-params tuple or a nested value is still refused with the parameter's position.
  # Why: `_contains_nul` has seven methods and a collected value is typed `Any`, so the loop dispatched on
  #   every value at run time: 12 rows of the trimmed fixture, one set per collector type (#1599 layer 2).
  @testset "the NUL check walks the collected values without a dynamic call (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    QB = PormG.QueryBuilder
    for T in (QB.PgParameterizedQuery, QB.SQLiteParameterizedQuery, QB.MySQLParameterizedQuery, Vector{Any})
      @test (T, _dynamic_calls(CP._refuse_nul, (String, T))) == (T, String[])
    end
    @test _dynamic_calls(CP._refuse_nul_values, (Vector{Any},)) == String[]
    @test _dynamic_calls(CP._contains_nul_value, (Any,)) == String[]
    values = Any["Senna", SubString("Ayrton Senna", 8), 'x', '\0', 44, 1.5, true, nothing, missing, Int32(7), :monaco,
                 PormG.PormGBytes(UInt8[0x00]), PormG.PormGArrayLiteral("{\"Monza\0\"}"), UInt8[0x00, 0x01], [1, 2],
                 ["Monaco", "Monza\0"], Any["Spa", Any["Imola\0"]], ("Silverstone", "Suzuka\0"), "Interlagos\0"]
    for v in values
      @test (string(typeof(v)), CP._contains_nul_value(v)) == (string(typeof(v)), CP._contains_nul(v))
    end
    err = try CP._refuse_nul("SELECT ?, ?", ("Monaco", Any["Monza\0"])); nothing catch e; e end
    @test err isa PormG.InvalidValueError && occursin("Parameter 2 contains a NUL", sprint(showerror, err))
    err = try CP._refuse_nul("SELECT ?, ?", Any[1, "Imola\0"]); nothing catch e; e end
    @test err isa PormG.InvalidValueError && occursin("Parameter 2 contains a NUL", sprint(showerror, err))
    @test CP._refuse_nul("SELECT ?, ?", Any[1, "Imola"]) === nothing
    # The open arm: a collector whose `parameters` is a tuple or a typed vector, checked in iteration order.
    err = try CP._refuse_nul("SELECT ?, ?", QB.PgParameterizedQuery("", ("Monaco", "Monza\0"), 2)); nothing catch e; e end
    @test err isa PormG.InvalidValueError && occursin("Parameter 2 contains a NUL", sprint(showerror, err))
    @test CP._refuse_nul("SELECT ?, ?", QB.PgParameterizedQuery("", ["Monaco", "Monza"], 2)) === nothing
  end

  # What: the detector itself, on a function that does make a dynamic call.
  # Expected: it reports the call.
  # Why: a detector that never finds anything would pass every pin above for the wrong reason.
  @testset "the detector finds a call on a Function-typed value" begin
    box = Ref{Function}(isinteractive)
    f = () -> box[]()
    @test !isempty(_dynamic_calls(f, ()))
  end
end
