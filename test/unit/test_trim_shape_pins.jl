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

# The calls in `f(argtypes...)`'s unoptimized typed body that hand a FUNCTION at its concrete type to a
# callee whose compileable signature widens that argument (to `Function`), as "<callee>: arg <i> <T> -> <W>"
# (#1599 layer 4). Julia does not specialize a method on a function argument it only passes on, so
# `juliac` compiles the callee for `Function` and the call the callee makes with it is dynamic. The JIT's
# inference keeps the concrete type and inlines the callee, so neither `_dynamic_calls` nor the `:invoke`
# walks above see it: the verifier listed `with_collector(…, ::Function, …)` while both came back empty.
# Two blind spots: a call whose argument types match more than one method is skipped, and in a signature
# that ends in a `Vararg` only the positions before it are compared.
function _widened_function_args(f, argtypes::Tuple)::Vector{String}
  ci, _ = only(code_typed(f, argtypes; optimize = false))
  typ(x) = x isa Core.SSAValue ? ci.ssavaluetypes[x.id] :
           x isa Core.Argument ? ci.slottypes[x.n] :
           x isa Core.SlotNumber ? ci.slottypes[x.id] :
           x isa GlobalRef ? (isdefined(x.mod, x.name) ? Core.Typeof(getglobal(x.mod, x.name)) : Any) :
           x isa QuoteNode ? Core.Typeof(x.value) : Core.Typeof(x)
  found = String[]
  for stmt in ci.code
    (stmt isa Expr && stmt.head === :call) || continue
    ts = map(a -> Core.Compiler.widenconst(typ(a)), stmt.args)
    ts[1] <: Core.Builtin && continue
    tt = Tuple{ts...}
    ms = Base._methods_by_ftype(tt, -1, Base.get_world_counter())
    (ms isa Vector && length(ms) == 1) || continue
    m = only(ms)
    sig = Core.Compiler.get_compileable_sig(m.method, tt, m.sparams)
    sig === nothing && continue
    wide = Base.unwrap_unionall(sig).parameters
    for (i, T) in enumerate(tt.parameters)
      i <= length(wide) || break
      (T <: Function && isconcretetype(T) && !isconcretetype(wide[i])) &&
        push!(found, "$(m.method.name): arg $(i) $(T) -> $(wide[i])")
    end
  end
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
# A caller's own `SQLTypeFunction`, its `aggregate` not a `Bool` (#1599 layer 4): the aggregate walks read
# it as they always did, through their open arm.
struct _TspUserAgg <: PormG.SQLTypeFunction
  aggregate::Int
end
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
    @test isempty(_dynamic_calls(CP.with_pool, (CP._Atomic{typeof(identity)}, Any)))
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
    # #1614: a trimmed MySQL app boots through `register_connection` with a `mysql://` URL, so its parse
    # is on the boot path, and so is the typed tail each adapter's branch hands its pool to.
    @test isempty(_dynamic_calls(Configuration._mysql_url_block, (String,)))
    @test isempty(_dynamic_calls(Configuration._url_unescape, (SubString{String}, String)))
    reg_pools = (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
                 CP.MySQLConnectionPool)
    for P in reg_pools
      @test isempty(_dynamic_calls(Configuration._install_registered_pool!, (String, S, NTuple{3, Float64}, P)))
    end
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
    # Each branch reaches the tail at its pool's concrete type: one pool union across the branches is
    # wider than inference keeps, and widened to the abstract type every monitor call is dynamic (#1622).
    rc_tails = [T.parameters[end] for T in invokes_in(rc_body)
                if T.parameters[1] === typeof(Configuration._install_registered_pool!)]
    @test Set(rc_tails) == Set(reg_pools)
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

  # What: `load`'s extension probe counts the rows of its `pg_extension` query inside `with_pool`'s
  #   callee (`_count_rows_on`), not by passing the driver's result through `with_pool`.
  # Expected: no dynamic call in `_check_configured_extensions!`'s keyword body (base had two:
  #   `with_pool(backend_num_rows, pool, result)` with the result untyped, and the `> 0` on its answer),
  #   and none in `_count_rows_on` at any pool type. The Postgres.jl pool's count was one until its method
  #   took the result `@nospecialize` (#1771's residue, closed in the extension; its own pin is the
  #   "a Postgres.jl result's row count is a static call" testset). The query, `fetch` and the count are
  #   the ones base ran; the probe's answers (installed, not installed) are pinned with a stand-in pool
  #   in test_configuration_api.jl, and its "Could not verify" warning by the #1570 testset there.
  # Why: the driver's result is untyped (#1770, decision 2), and `with_pool`'s vararg specialized on
  #   it, a dynamic call on the boot path a trimmed image takes when `extensions:` is set (#1599, layer 1).
  @testset "the extension probe counts inside the pool callee (#1770, decision 2)" begin
    S = Configuration.Settings
    CP = PormG.ConnectionPool
    body = Base.bodyfunction(only(methods(Configuration._check_configured_extensions!)))
    @test isempty(_dynamic_calls(body, (Bool, typeof(Configuration._check_configured_extensions!), S)))
    for P in (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
              CP.MySQLConnectionPool)
      @test (P, _dynamic_calls(Configuration._count_rows_on, (P, String))) == (P, String[])
    end
  end

  # What: `_warn_pool_takeover`, the line `load` logs before it replaces an entry's pool, and its count.
  # Expected: no dynamic call in either; the count is `with_pool(_takeover_in_use, pool)`.
  # Why: it called a `pool_stats` not bound in Configuration, a dynamic call that raised `UndefVarError`
  #   under a bare `catch` (#1756, decision 1); its log line is pinned by test_configuration_api.jl.
  @testset "the pool takeover reads its in-use count through the pool (#1756, decision 1)" begin
    S = Configuration.Settings
    CP = PormG.ConnectionPool
    @test isempty(_dynamic_calls(Configuration._warn_pool_takeover, (String, String, String, Dict{String,S})))
    for P in (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
              CP.MySQLConnectionPool)
      @test isempty(_dynamic_calls(Configuration._takeover_in_use, (P,)))
    end
  end

  # What: the pool's calls into code that may be defined later than the task making them (a deferred or
  #   reaped `close`; the SQLite worker reaches the latest world through a `@cfunction`, pinned below).
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

  # What: the SQLite worker, the one task every SQLite statement runs on (#1599 layer 2).
  # Expected: `_ensure_sqlite_async_worker!` spawns the named loop `_sqlite_worker_loop` with the queue as a
  #   captured argument, never a `begin … end` body; the loop makes no dynamic call (the statement runs
  #   through a `ccall` of the pointer the caller took); the statement's runner, the method that pointer
  #   names, makes no dynamic call over a concrete pool with a plain statement or a typed read's decoder;
  #   and the caller takes that pointer with no dynamic call.
  # Why: a `juliac --trim` image compiles a spawned body only when the closure `@spawn` builds captures a
  #   value. The worker's body read only globals, so it was never compiled: its task died with a
  #   `MethodError` at its first call, and the trimmed SQLite read waited on the queue until it was killed
  #   (#1599, round on 089f8fe). And a statement the worker called through its `Any` slot had no compiled
  #   target for the typed read's row type; a `@cfunction` taken by the caller at the statement's type is
  #   reached statically. Both measured in a minimal trimmed program first.
  @testset "the SQLite worker starts and runs its statements in a trimmed image (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    src = read(joinpath(pkgdir(PormG), "src", "ConnectionPool.jl"), String)
    i = findfirst("function _ensure_sqlite_async_worker!()", src)
    j = findfirst("function _sqlite_worker_loop(", src)
    @test i !== nothing && j !== nothing && first(j) > last(i)
    starter = src[last(i):first(j)]
    spawns = [l for l in split(starter, '\n') if occursin("@spawn", l) && !startswith(lstrip(l), "#")]
    @test length(spawns) == 1
    @test occursin("@spawn _sqlite_worker_loop(queue)", only(spawns))
    @test occursin("queue = _sqlite_async_work_queue", starter)

    @test isempty(_dynamic_calls(CP._sqlite_worker_loop, (Channel{CP.SQLiteAsyncWorkItem},)))

    QB = PormG.QueryBuilder
    D = QB._RowDecoder{NamedTuple{(:surname,), Tuple{String}}, Tuple{PormG.ReadParser}}
    for S in (CP._SQLiteStatement{CP.SQLiteConnectionPool, Nothing, Nothing},
              CP._SQLiteStatement{CP.SQLiteConnectionPool, Vector{Any}, Nothing},
              CP._SQLiteStatement{CP.SQLiteConnectionPool, Nothing, D})
      @test isempty(_dynamic_calls(CP._run_sqlite_statement, (S, Any)))
      @test isempty(_dynamic_calls(CP._sqlite_statement_runner, (S,)))
    end
    # One method, so the pointer names one target.
    @test length(methods(CP._run_sqlite_statement)) == 1
  end

  # What: the pool reaper's sweeper task (#125, #1599 layer 2).
  # Expected: `_ensure_reaper!` spawns the named loop `_reaper_loop` with the monitor registry as a
  #   captured argument (`registry = _POOL_MONITOR`), never a `begin … end` body; the loop, the sweep over
  #   the registry and `_reap_pool!` over each concrete pool make no dynamic call.
  # Why: a `juliac --trim` image compiles a spawned body only when it sees the closure `@spawn` builds
  #   constructed. The sweeper's `begin … end` body read only globals, so it was never compiled: in a
  #   trimmed long-running application its task died at its first call and no idle or over-lifetime
  #   connection was ever reaped (the read-only fixture's `reap` step: no connection closed in 40 s). The
  #   verifier reports no row for such a body, so only the shape can be pinned. A capture of a constant
  #   bits value (`interval = _REAP_INTERVAL`) is folded the same way, which is why the capture is the
  #   registry; both measured in a minimal trimmed program.
  @testset "the pool reaper's sweeper starts in a trimmed image (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    src = read(joinpath(pkgdir(PormG), "src", "ConnectionPool.jl"), String)
    i = findfirst("function _ensure_reaper!(", src)
    j = findfirst("function _reaper_loop(", src)
    @test i !== nothing && j !== nothing && first(j) > last(i)
    starter = src[last(i):first(j)]
    spawns = [l for l in split(starter, '\n') if occursin("@spawn", l) && !startswith(lstrip(l), "#")]
    @test length(spawns) == 1
    @test occursin("@spawn _reaper_loop(registry)", only(spawns))
    @test occursin("registry = _POOL_MONITOR", starter)
    # A bits capture would be folded into a constant. A proxy: whether the body is compiled is measured
    # by the read-only fixture's `tasks` run (test/trim/README.md), not by this file.
    @test !isbitstype(typeof(CP._POOL_MONITOR))

    R = CP._PoolRegistry{CP.PoolMonitorState}
    @test isempty(_dynamic_calls(CP._reaper_loop, (R,)))
    @test isempty(_dynamic_calls(CP._reap_all_pools!, (R,)))
    for P in (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
              CP.MySQLConnectionPool)
      @test (P, _dynamic_calls(CP._reap_pool!, (P,))) == (P, String[])
    end
  end

  # What: the deferred SQLite close (#327), the task that closes a handle once the worker has finished
  #   every statement it still holds for it (#1599 layer 2).
  # Expected: the task waits through `_wait_settled(_sqlite_drained_probe(conn), close_seconds)`; the probe
  #   has one concrete type with no parameters, the same for any handle, and answers whether the ledger
  #   holds work for that handle; `_wait_settled` over it makes no dynamic call.
  # Why: the task built its probe as `() -> _sqlite_outstanding(conn) == 0`, capturing `conn` from the task's
  #   own untyped field, so the closure's type was computed from the handle at run time
  #   (`#87#88{SQLite.DB}`). A `juliac --trim` image had no `timedwait` for that type: the task died at the
  #   call and the handle was never closed (the read-only fixture's `tasks` run: still open after 60 s).
  @testset "the deferred SQLite close waits on a probe whose type does not depend on the handle (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    src = read(joinpath(pkgdir(PormG), "src", "ConnectionPool.jl"), String)
    i = findfirst("function _close_driver_handle!(", src)
    @test i !== nothing
    j = findnext("\nend\n", src, last(i))
    @test occursin("_wait_settled(_sqlite_drained_probe(conn), close_seconds)", src[first(i):last(j)])

    db = SQLite.DB()
    p = CP._sqlite_drained_probe(db)
    @test typeof(p) === typeof(CP._sqlite_drained_probe(:not_a_handle))
    @test isconcretetype(typeof(p)) && isempty(typeof(p).parameters)
    @test p() === true
    CP._sqlite_pending_inc!(db)
    try
      @test p() === false
    finally
      CP._sqlite_pending_dec!(db)
    end
    @test p() === true
    # Not what tells the old shape from the new (given a concrete probe type, the wait was static before
    # too); the type assertions above are.
    @test isempty(_dynamic_calls(CP._wait_settled, (typeof(p), Float64)))
    @test CP._wait_settled(p, 1.0) === true
    close(db)
  end

  # What: the SQLite extension's statement parameters, its typed read's cursor and its retry's lock check
  #   (#1599 layer 2).
  # Expected: a `Vector{Any}` of parameters reaches SQLite.jl wrapped in `_SQLiteBinds`, whose `bind!`
  #   binds each value of the types `sqlite_bind_value` hands over with a static call (any other value
  #   through one `@noinline` open arm), with the rows, the count check and its message unchanged; the
  #   typed read steps SQLite.jl's cursor at its concrete type; the lock check takes the caught exception
  #   unspecialized and reads SQLite.jl's error at its type.
  # Why: SQLite.jl binds a vector with one `bind!(stmt, i, values[i])` per value, a call on an `Any`, and
  #   the trimmed read stopped at `bind!(::Stmt, ::Int64, ::String)`; its cursor comes back as an abstract
  #   `Query`, and the read then stopped at the row walk; the retry's `_is_sqlite_locked_error(e)` was
  #   compiled per exception type, and the trimmed binary had none for the one it caught.
  @testset "the SQLite extension binds, steps its cursor and checks a lock without a dynamic call (#1599 layer 2)" begin
    X = Base.get_extension(PormG, :PormGSQLiteExt)
    @test isempty(_dynamic_calls(X._sqlite_bind_one!, (SQLite.Stmt, Int, Any)))
    # The count of placeholders is SQLite.jl's own call on its statement handle. Where SQLite.jl infers
    # that handle concretely (current releases, which a trimmed build resolves) the method makes no
    # dynamic call; at the 1.6.1 floor `_get_stmt_handle` reads an abstract `Ref`, and that count is the
    # one call left, the same one SQLite.jl's own positional `bind!` makes there.
    bind_calls = _dynamic_calls(SQLite.bind!, (SQLite.Stmt, X._SQLiteBinds{Vector{Any}}))
    if isconcretetype(only(Base.return_types(SQLite._get_stmt_handle, (SQLite.Stmt,))))
      @test isempty(bind_calls)
    else
      @test !isempty(bind_calls) && all(c -> occursin("sqlite3_bind_parameter_count", c), bind_calls)
    end
    @test isempty(_dynamic_calls(X._is_sqlite_locked_error, (Any,)))
    # The cursor SQLite.jl returns is narrowed to `Query{false}`, so the rows are stepped by a static call
    # (the trimmed read stopped at `_sqlite_rows_into(::DataType, ::Query{false}, …)`).
    Dsl = PormG.QueryBuilder._RowDecoder{NamedTuple{(:surname,), Tuple{String}}, Tuple{PormG.ReadParser}}
    @test isempty(_dynamic_calls(X._sqlite_decode_rows, (SQLite.DB, String, Vector{Any}, Dsl)))
    @test X._sqlite_binds(Any[1]) isa X._SQLiteBinds{Vector{Any}}
    @test X._sqlite_binds((1,)) === (1,)          # a tuple is handed over as it was
    @test X._sqlite_binds(nothing) === nothing

    db = SQLite.DB()
    SQLite.execute(db, "CREATE TABLE t (a, b, c, d, e, f, g)")
    vals = Any["Senna", Int64(3), 1.5, true, missing, Int32(7), UInt8[0x01, 0x02]]
    SQLite.execute(db, "INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?)", vals)
    stmt = SQLite.Stmt(db, "SELECT * FROM t WHERE a = ? AND b = ? AND f = ? AND g = ?"; register = false)
    probe = Any["Senna", Int64(3), Int32(7), UInt8[0x01, 0x02]]
    rows_plain = X.Tables.rowtable(SQLite.DBInterface.execute(stmt, probe))
    cursor = SQLite.DBInterface.execute(stmt, X._sqlite_binds(probe))
    @test cursor isa SQLite.Query{false}      # the type `_sqlite_decode_rows` narrows the cursor to
    rows_typed = X.Tables.rowtable(cursor)
    @test isequal(rows_plain, rows_typed) && length(rows_typed) == 1
    # A value outside the arms takes SQLite.jl's own method (here `Float32`, an `AbstractFloat`).
    rows_open = X.Tables.rowtable(SQLite.DBInterface.execute(
      SQLite.Stmt(db, "SELECT ? AS x"; register = false), X._sqlite_binds(Any[Float32(2.5)])))
    @test rows_open[1].x == 2.5
    short = try
      SQLite.DBInterface.execute(stmt, X._sqlite_binds(Any["Senna"])); nothing
    catch e
      e
    end
    @test short isa SQLite.SQLiteException && short.msg == "values should be provided for all query placeholders"
    SQLite.DBInterface.close!(stmt)
    close(db)

    @test X._is_sqlite_locked_error(SQLite.SQLiteException("database is locked"))
    @test X._is_sqlite_locked_error(SQLite.SQLiteException("DATABASE TABLE IS LOCKED: drivers"))
    @test X._is_sqlite_locked_error(ErrorException("database is locked"))   # read at its type since #1599
    @test !X._is_sqlite_locked_error(SQLite.SQLiteException("no such table: drivers"))
    @test !X._is_sqlite_locked_error(InterruptException())
    # A message with invalid UTF-8 answers as `string(e)` does, where `lowercase` on the message would throw.
    @test !X._is_sqlite_locked_error(SQLite.SQLiteException("no such table: t\xff"))
    @test X._is_sqlite_locked_error(SQLite.SQLiteException("database is locked \xff"))
  end

  # What: the SQLite extension's materialization of a non-typed statement's result
  #   (`_sqlite_execute_materialized`, with and without parameters), the construction it calls on the
  #   cursor PormG builds (`_sqlite_rowtable`), and the typed vector it fills (`_sqlite_typed_vector`).
  # Expected: no dynamic call in any of them; `Tables.rowtable` is reached only through the `@noinline`
  #   open arm for a cursor that is not `Query{false}`. That the result is `Tables.rowtable`'s, type and
  #   values, is pinned in `test_sqlite_materialize.jl`.
  # Why: `Tables.rowtable(cursor)` builds each row as a `NamedTuple` of a type known only at run time, and
  #   a trimmed image had no code for it, so every non-typed SQLite statement raised `MethodError` there:
  #   the full fixture's write stopped at its INSERT (#1599 layer 2, #1797's hand-off).
  @testset "the SQLite extension materializes a result without a dynamic call (#1599 layer 2)" begin
    X = Base.get_extension(PormG, :PormGSQLiteExt)
    # No dynamic call at any SQLite.jl the floor admits: the handle is read at its type, so the 1.6.1
    # floor's abstract `Ref` does not leave the cell reads untyped (CI's floor-resolve job caught it).
    @test isdefined(X, :_sqlite_rowtable) && _dynamic_calls(X._sqlite_rowtable, (SQLite.Query{false},)) == String[]
    @test isdefined(X, :_sqlite_typed_vector) && _dynamic_calls(X._sqlite_typed_vector, (Type, Vector{Any})) == String[]
    for P in (Nothing, Vector{Any})
      @test (P, _dynamic_calls(X._sqlite_execute_materialized, (SQLite.DB, String, P))) == (P, String[])
    end
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

  # What: `add_parameter!` on a PostgreSQL collector, for each kind of value a statement binds, and the helper
  #   every push onto `PgParameterizedQuery.parameters` goes through (`_push_parameter!`).
  # Expected: no dynamic call; the value is appended and the placeholder numbered as before; a collector
  #   built over a `Tuple` raises the `MethodError` of `push!` on it, as before.
  # Why: the slot is `Union{AbstractVector,Tuple}`, so `push!(pq.parameters, value)` dispatched at run time:
  #   28 verifier rows (one per value type, two per build entry), each a `MethodError` in a trimmed binary
  #   that binds on PostgreSQL (#1599 layer 4).
  @testset "a PostgreSQL collector appends without a dynamic call (#1599 layer 4)" begin
    QB = PormG.QueryBuilder
    for T in (Int64, Float64, String, Nothing, Dates.Date, Dates.DateTime, Vector{Int64}, PormG.PormGBytes)
      @test isempty(_dynamic_calls_kw(QB.add_parameter!, (QB.PgParameterizedQuery, T)))
    end
    @test isdefined(QB, :_push_parameter!)
    isdefined(QB, :_push_parameter!) && @test isempty(_dynamic_calls(QB._push_parameter!, (QB.PgParameterizedQuery, Any)))
    pq = QB.PgParameterizedQuery("", Any[], 0)
    @test QB.add_parameter!(pq, 44) == "\$1"
    @test QB.add_parameter!(pq, "Monaco"; sql_type = "text") == "\$2::text"
    @test QB.add_parameter!(pq, [1, 2]) == "\$3"
    @test QB.add_parameter!(pq, PormG.PormGBytes(UInt8[0x01, 0x02])) == "\$4"
    @test pq.parameters == Any[44, "Monaco", [1, 2], "\\x0102"] && pq.parameter_count == 4
    @test pq.parameters[3] isa Vector{Int64}   # the list is pushed untouched, element type included
    @test_throws MethodError QB.add_parameter!(QB.PgParameterizedQuery("", (), 0), 1)
  end

  # What: `with_bucket(f, instruc, context)`, which opens a clause's parameter bucket around `f` on an
  #   instruction, read with its closure at a concrete type.
  # Expected: no callee compiled with the closure widened to `Function` (`_widened_function_args`) and no
  #   dynamic call; on a positional collector the bucket is `context` while `f` runs and the previous one
  #   after, on PostgreSQL and without a collector `f` just runs.
  # Why: the instruction form went through `with_collector`, whose `Vararg` passes the closure on, so Julia
  #   compiled it for `Function` and the call into `_with_bucket_on` dispatched at run time: 6 verifier rows
  #   on the typed read's WHERE and SELECT clauses (#1599 layer 4).
  @testset "with_bucket on an instruction calls its closure statically (#1599 layer 4)" begin
    QB = PormG.QueryBuilder
    probe = () -> 7
    @test isempty(_widened_function_args(QB.with_bucket, (typeof(probe), QB.InstructionObject, Symbol)))
    # The control: the call the instruction form made before, which the detector must see.
    # (Spelled through the global `PormG`: a captured `QB` would hide the callee from the typed code.)
    old_form(f) = PormG.QueryBuilder.with_collector(PormG.QueryBuilder._with_bucket_on,
                                                    PormG.QueryBuilder.SQLiteParameterizedQuery(), f, :where)
    @test any(s -> startswith(s, "with_collector: arg 4"), _widened_function_args(old_form, (typeof(probe),)))
    @test isempty(_dynamic_calls_deep(QB.with_bucket, (typeof(probe), QB.InstructionObject, Symbol); depth = 2))
    model = PormG.Models.Model("tsp_bucket_race", raceid = PormG.Models.IDField())
    instruction(params) = QB.InstructionObject(text = "", table_alias = QB.SQLTbAlias(), alias = "Tb",
                                               object = QB.SQLObjectQuery(model = model), parameters = params)
    sq = QB.SQLiteParameterizedQuery()
    before = sq.current_context
    seen = QB.with_bucket(() -> sq.current_context, instruction(sq), :where)
    @test seen === :where && sq.current_context === before
    @test QB.with_bucket(probe, instruction(QB.PgParameterizedQuery("", Any[], 0)), :where) == 7
    @test QB.with_bucket(probe, instruction(nothing), :where) == 7
    # The walk names every collector, as `with_collector` does: one list in two places, so a collector added
    # to `ParamCollector` and not here fails this rather than raising on every query that binds through it.
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "parameters.jl"), String)
    start = findfirst("function with_bucket(f::F, instruc::SQLInstruction", src)
    @test start !== nothing
    if start !== nothing
      body = src[start[1]:findnext("\nend", src, start[1])[end]]
      members = Base.uniontypes(QB.ParamCollector)
      for T in members
        @test occursin("p isa $(nameof(T)) && return with_bucket(f, p, context)", body)
      end
      @test count("p isa ", body) == length(members)
    end
  end

  # What: the aggregate walks, `_holds_agg` (the flag a wrapper stores) and `_contains_agg` (does the
  #   statement aggregate), over the abstract slots they read, and `_is_agg_any`, `_is_agg` for a value of any type.
  # Expected: one compiled body each, with no dynamic call; `_is_agg` keeps its four methods, so the closed
  #   arms cover it; the answers are the ones before, through vectors, keyword values, windows and the depth cap.
  # Why: `FExpression.field_name`/`operand`, `FObject.column` and `WindowFunction.column` are unions over
  #   abstract families, so a call on them dispatched at run time, and `any(v -> …, x)` over a `Vector{Any}`
  #   compiles the closure as `Function` (16 verifier rows, among them the two `_holds_agg` rows the ORDER
  #   BY render reached after #1770; #1599 layer 4).
  @testset "the aggregate walks make no dynamic call (#1599 layer 4)" begin
    QB = PormG.QueryBuilder
    @test isempty(_dynamic_calls(QB._holds_agg, (Any, Int)))
    @test isempty(_dynamic_calls(QB._contains_agg, (Any, Int)))
    # Out of line, so the recursion always reaches the one `(Any, Int)` body: inlined into a caller that
    # knows the argument's type, it became calls on instances `juliac` does not compile ("unresolved invoke").
    for f in (QB._holds_agg, QB._contains_agg)
      @test only(code_lowered(f, (Any, Int))).inlining == 2   # `@noinline`
    end
    # The closed arms cover `_is_agg`'s methods, these four.
    @test Set(string(m.sig) for m in methods(QB._is_agg)) == Set(string(Tuple{typeof(QB._is_agg), T})
                                                                for T in (QB.FExpression, PormG.SQLTypeFunction, Any, QB.WindowFunction))
    s = QB.Sum("points")
    lag = QB.Lag(s)
    @test QB._holds_agg(s) && QB._contains_agg(s)
    @test !QB._holds_agg(lag) && QB._contains_agg(lag)              # a window over an aggregate
    @test QB._holds_agg(Any["x", s]) && !QB._holds_agg(Any["x", 1])
    @test QB._contains_agg(QB.F("grid") + s) && !QB._contains_agg(QB.F("grid") + 1)
    @test QB._contains_agg(QB.Coalesce(lag, QB.Value(0)))
    @test !QB._holds_agg(QB.Coalesce(lag, QB.Value(0)))
    @test QB._holds_agg(QB.Coalesce(s, QB.Value(0)))
    @test QB._contains_agg(QB.Case([QB.When("grid__@gte" => 1, then = s)]))
    @test !QB._contains_agg(QB.Case([QB.When("grid__@gte" => 1, then = 1)]))
    @test !QB._holds_agg(Any[s], 32) && !QB._contains_agg(Any[s], 32)   # the depth cap
    @test QB._contains_agg(QB.ProjectionNode[QB.SQLField("raceid"), QB.SQLField(s)]) ==
          QB._contains_agg(QB.SQLField(s))                            # a query's projection
    # The open arms: a vector type no arm names, and a caller's own `SQLTypeFunction`, whose `aggregate`
    # each walk reads as it always did (`_holds_agg` converts it to `Bool`, `_contains_agg` tests it).
    @test !QB._holds_agg([1, 2]) && QB._holds_agg(view(Any[s], 1:1)) && QB._contains_agg(view(Any[s], 1:1))
    @test QB._holds_agg(_TspUserAgg(1)) && !QB._holds_agg(_TspUserAgg(0))
    @test_throws InexactError QB._holds_agg(_TspUserAgg(2))
    @test_throws TypeError QB._contains_agg(_TspUserAgg(1))
    @test QB._holds_agg(Any[_TspUserAgg(1)])
    @test isdefined(QB, :_is_agg_any)
    if isdefined(QB, :_is_agg_any)
      @test isempty(_dynamic_calls(QB._is_agg_any, (Any,)))
      for x in (s, lag, QB.F("grid"), QB.Rank(), "points", 1, nothing)
        @test QB._is_agg_any(x) === QB._is_agg(x)
      end
    end
  end

  # What: `_is_window_expr` over the abstract slots it reads (`FExpression`'s two sides, `FObject.column`
  #   and its keyword values), through `_is_window_expr_any`.
  # Expected: no dynamic call in the `FExpression` and `FObject` methods, the list methods or the walk; the
  #   walk's arms cover `_is_window_expr`'s nine methods; the answers are the ones before.
  # Why: a call on those slots dispatched at run time over nine methods, and `any(f, x)` over an array widens
  #   `f` to `Function` in Base: 7 verifier rows on the WHERE guard's path (#1599 layer 4).
  @testset "the window question makes no dynamic call on an abstract slot (#1599 layer 4)" begin
    QB = PormG.QueryBuilder
    for T in (QB.FExpression, QB.FObject, Vector{QB.FExpression}, Vector{Any}, QB.QObject, QB.QorObject)
      @test isempty(_dynamic_calls(QB._is_window_expr, (T,)))
    end
    @test Set(string(m.sig) for m in methods(QB._is_window_expr)) ==
          Set(string(Tuple{typeof(QB._is_window_expr), T}) for T in (QB.WindowFunction, QB.FExpression, QB.FObject,
              Vector, QB.QObject, QB.QorObject, QB.OperObject, QB.SQLField, Any))
    rank = QB.Rank()
    @test QB._is_window_expr(QB.F("grid") + 1) == false
    @test QB._is_window_expr(QB.Coalesce(rank, QB.Value(0)))
    @test QB._is_window_expr(QB.Case([QB.When("grid__@gte" => 1, then = rank)]))
    @test !QB._is_window_expr(QB.Case([QB.When("grid__@gte" => 1, then = 1)]))
    @test QB._is_window_expr(QB.Case([QB.When(rank > 1, then = 1)]))
    @test isdefined(QB, :_is_window_expr_any)
    if isdefined(QB, :_is_window_expr_any)
      @test isempty(_dynamic_calls(QB._is_window_expr_any, (Any,)))
      for x in (rank, QB.Sum("points"), QB.F("grid"), QB.Q("grid" => 1), [rank], Any["x", rank], Any[], "points", 1,
                [QB.Case([QB.When("grid__@gte" => 1, then = rank)])], view(Any[rank], 1:1))
        @test QB._is_window_expr_any(x) === QB._is_window_expr(x)
      end
    end
  end

  # What: `FExpression`'s two sides as the build and render read them (#1599 layer 5): the accessors
  #   `_fexpr_left`/`_fexpr_right`, the interval, duration, date-shift and kind readers that take a side, and
  #   the closed walks they call (`_is_bare_column_any`, `_has_window_function_any`, `_infer_kind_any`,
  #   `_arithmetic_side_kind_any`, `_side_kind_any`, `_whole_kind_any`, `_period_nanoseconds`).
  # Expected:
  #   - the accessors hand on the slot's own value, untyped;
  #   - the converted readers read the sides only through them, and make no dynamic call to a callee that
  #     takes a side;
  #   - each walk's arms cover its function's methods and answer what the function answers;
  #   - `_decompose_period` gives the components it gave, and refuses a component it does not know.
  # Why: a side read at the slot's union (`Integer`, `Dates.Period`, `SQLTypeFunction`, … beside concrete
  #   types) made every call on it a run-time dispatch, even to a callee with one method: 358 verifier rows on
  #   main read a side, 16 of them attributed to layer-4 helpers (#1773's residue). Measured on main
  #   67ac61865: the accessor and walk checks fail (not defined), and the named-call checks find the calls.
  @testset "FExpression's sides are read untyped, and their callees take them statically (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    K = PormG.Kernel
    I = QB.InstructionObject
    has(n) = isdefined(QB, n)
    for n in (:_fexpr_left, :_fexpr_right, :_is_bare_column_any, :_has_window_function_any, :_infer_kind_any,
              :_arithmetic_side_kind_any, :_side_kind_any, :_whole_kind_any, :_period_nanoseconds,
              :_may_hold_calendar_part_any, :_whole_days)
      @test has(n)
    end
    e = QB.F("grid") * 2
    if has(:_fexpr_left) && has(:_fexpr_right)
      @test QB._fexpr_left(e) === e.field_name && QB._fexpr_right(e) === e.operand
      @test only(Base.return_types(QB._fexpr_left, (QB.FExpression,))) === Any
      @test only(Base.return_types(QB._fexpr_right, (QB.FExpression,))) === Any
    end

    # The readers: no dynamic call to a callee that takes a side. `_duration_units`, `_duration_value_units` and
    # `_unordered_interval_error` are not listed: they take the instruction's connection too, an abstract
    # engine type, which is a separate cause.
    side_callees = ("_interval_ms_sql", "_calendar_scale_refused", "_refuse_window_in_interval",
                    "_is_number_side", "_has_calendar_part", "_decompose_period", "_render_left_typed",
                    "_render_side_kind", "_render_duration_value", "_integer_side_kind", "_arithmetic_side_kind",
                    "_refuse_bitwise_interval", "_day_count_column_kind", "_is_bare_column", "_has_window_function",
                    "_infer_kind", "_side_kind", "_operand_column_field", "_projection_column_kind", "getproperty",
                    "Dates.Day", "_period_nanoseconds")
    CK = Union{K.CanonicalType, Nothing}
    readers = (Tuple{typeof(QB._render_interval_left), QB.FExpression, String, K.CInterval, I},
               Tuple{typeof(QB._render_interval_left), QB.FExpression, String, QB._IntervalMs, I},
               Tuple{typeof(QB._render_interval_right), QB.FExpression, String, CK, String, K.CInterval, I},
               Tuple{typeof(QB._render_date_period_arithmetic), QB.FExpression, I},
               Tuple{typeof(QB._render_duration_product), QB.FExpression, I},
               Tuple{typeof(QB._temporal_result_kind), QB.FExpression, CK, CK, I},
               Tuple{typeof(QB._interval_left_kind), QB.FExpression, K.CInterval, CK, I},
               Tuple{typeof(QB._temporal_arith_kind), QB.FExpression, I},
               Tuple{typeof(QB._operation_kind), QB.FExpression, I, QB._AllKinds},
               Tuple{typeof(QB._calendar_scale_refused), Any, String, Any, I},
               Tuple{typeof(QB._render_left_typed), Any, String, I},
               Tuple{typeof(QB._render_side_kind), Any, I},
               Tuple{typeof(QB._has_window_function), QB.FExpression},
               Tuple{typeof(QB._is_bare_column), QB.FExpression},
               Tuple{typeof(QB._infer_kind), QB.FExpression, I, QB._AllKinds})
    for tt in readers
      calls = _named_dynamic_calls(tt, side_callees; depth = 2)
      @test isempty(calls)
      isempty(calls) || @info "a dynamic call takes an FExpression side" tt calls
    end
    # `_render_expr_node_sql` keeps the calls whose callees are not converted (the operand renderers, the JSON-key
    # and date-part walks); the ones listed above are gone from it too.
    calls = _named_dynamic_calls(Tuple{typeof(QB._render_expr_node_sql), QB.FExpression, I},
                                 ("_interval_ms_sql", "_render_left_typed", "_refuse_bitwise_interval",
                                  "_day_count_column_kind", "_refuse_window_in_interval", "Dates.Day", "_side_kind(");
                                 depth = 1)
    @test isempty(calls)
    isempty(calls) || @info "a dynamic call takes an FExpression side" calls

    # The readers above read the sides through the accessors, never off the slot.
    src(file) = read(joinpath(pkgdir(PormG), "src", "querybuilder", file), String)
    body(text, header) = (s = findfirst(header, text); s === nothing ? "" : text[s[1]:findnext("\nend\n", text, s[1])[end]])
    for (file, header) in (("expression_render.jl", "function _render_interval_left(v::FExpression"),
                           ("expression_render.jl", "function _render_interval_right(v::FExpression"),
                           ("expression_render.jl", "function _render_date_period_arithmetic(v::FExpression"),
                           ("expression_render.jl", "function _render_duration_product(v::FExpression"),
                           ("expression_render.jl", "function _render_expr_node_sql(v::FExpression"),
                           ("expression_kind.jl", "function _temporal_result_kind(p::FExpression"),
                           ("expression_kind.jl", "function _interval_left_kind(p::FExpression"),
                           ("expression_kind.jl", "function _temporal_arith_kind(p::FExpression"),
                           ("expression_kind.jl", "function _operation_kind(p::FExpression"))
      # Code, not comments. A `#` inside a string cuts its line short too, which only ever drops text.
      b = join((replace(l, r"#.*$" => "") for l in split(body(src(file), header), '\n')), '\n')
      @test !isempty(strip(b))
      @test !occursin(r"\b(v|p)\.(field_name|operand)\b", b)
    end

    # The walks: one arm per method of the function each stands for, and the same answers.
    sigs(f) = Set(string(m.sig) for m in methods(f))
    sig(f, Ts...) = string(Tuple{typeof(f), Ts...})
    @test sigs(QB._is_bare_column) == Set(sig(QB._is_bare_column, T)
                                          for T in (String, QB.JoinedReference, QB.FExpression, QB.CTEReference, Any))
    @test sigs(QB._has_window_function) ==
          Set(sig(QB._has_window_function, T) for T in (QB.WindowFunction, QB.FExpression, QB.FObject, QB.SQLField,
                                                        AbstractVector, Any))
    @test sigs(QB._arithmetic_side_kind) ==
          Set([sig(QB._arithmetic_side_kind, Integer, K.SQLInstruction, QB._EveryKind),
               sig(QB._arithmetic_side_kind, Union{AbstractFloat, PormG.Decimals.Decimal}, K.SQLInstruction, QB._EveryKind),
               sig(QB._arithmetic_side_kind, Any, K.SQLInstruction, QB._EveryKind)])
    @test length(methods(QB._infer_kind)) == 10
    @test length(methods(QB._side_kind)) == 6
    @test sigs(QB._whole_kind) == Set(sig(QB._whole_kind, T) for T in (Union{K.CInt16, K.CInt32, K.CInt64}, K.CDecimal, Any))

    rank = QB.Rank()
    cte = QB.CTE("g", "v")
    joined = QB.Joined("d", "driverid")
    if has(:_is_bare_column_any)
      @test isempty(_dynamic_calls(QB._is_bare_column_any, (Any,)))
      for x in ("grid", "date__@year", QB.F("grid"), QB.F("grid") + 1, QB.F("date__@year"), cte, joined, 1, nothing,
                Dates.Hour(1), rank)
        @test QB._is_bare_column_any(x) === QB._is_bare_column(x)
      end
    end
    if has(:_has_window_function_any)
      @test isempty(_dynamic_calls(QB._has_window_function_any, (Any,)))
      for x in (rank, QB.Lag("grid"), QB.F("grid") + rank, QB.F("grid") + 1, QB.Sum("points"),
                QB.Coalesce(rank, QB.Value(0)), QB.Case([QB.When("grid__@gte" => 1, then = rank)]),
                QB.SQLField(rank), Any[rank], Any[1, "x"], [1], "grid", 1, nothing)
        @test QB._has_window_function_any(x) === QB._has_window_function(x)
      end
    end
    if has(:_whole_kind_any)
      for k in (K.CInt16(), K.CInt32(), K.CInt64(), K.CDecimal(10, 0), K.CDecimal(10, 2), K.CDecimal(nothing, nothing),
                K.CFloat64(), K.CText(), nothing)
        @test QB._whole_kind_any(k) === QB._whole_kind(k)
      end
    end
    if has(:_period_nanoseconds)
      @test isempty(_dynamic_calls(QB._period_nanoseconds, (Any,)))
      for p in (Dates.Hour(1), Dates.Day(2), Dates.Week(1), Dates.Nanosecond(5), Dates.Millisecond(7),
                Dates.Microsecond(3), Dates.Second(9), Dates.Minute(4), Dates.Hour(1) + Dates.Minute(30))
        @test QB._period_nanoseconds(p) === PormG.Models._duration_to_nanoseconds(p)
      end
      for p in (Dates.Month(1), Dates.Year(1), Dates.Quarter(1), Dates.Month(1) + Dates.Day(1))
        @test_throws PormG.InvalidValueError QB._period_nanoseconds(p)
        @test_throws PormG.InvalidValueError PormG.Models._duration_to_nanoseconds(p)
      end
      @test_throws MethodError QB._period_nanoseconds("01:00:00")   # what `_duration_to_nanoseconds` raises
    end
    # `_decompose_period`: the components, largest first, sub-second parts folded into seconds.
    @test QB._decompose_period(Dates.Hour(1) + Dates.Minute(30)) == [(:hour, 1), (:minute, 30)]
    @test QB._decompose_period(Dates.Day(1) + Dates.Millisecond(500)) == [(:day, 1), (:second, 0.5)]
    @test QB._decompose_period(Dates.Quarter(1) + Dates.Month(1)) == [(:month, 4)]
    @test QB._decompose_period(Dates.Year(2)) == [(:year, 2)]
    @test QB._decompose_period(Dates.Second(0)) == Tuple{Symbol, Real}[]
    # A `Period` Dates does not define: its value is read, then it is refused, as before. Defined here rather
    # than with the file's test types at the top, which other slices edit too.
    isdefined(Main, :_TspPeriod) || Core.eval(Main, :(struct _TspPeriod <: $(Dates.Period); value::Int64; end))
    @test_throws PormG.InvalidValueError QB._decompose_period(Base.invokelatest(getglobal(Main, :_TspPeriod), 1))
    @test isempty(_named_dynamic_calls(Tuple{typeof(QB._decompose_period), Dates.Hour}, ("Dates.value", "getproperty");
                                       depth = 1))

    # The kind walks, against the functions they stand for, on an instruction over a two-field model.
    model = PormG.Models.Model("tsp_side_race", raceid = PormG.Models.IDField(), points = PormG.Models.IntegerField(),
                               date = PormG.Models.DateField())
    instruc = QB.InstructionObject(text = "", table_alias = QB.SQLTbAlias(), alias = "Tb",
                                   object = QB.SQLObjectQuery(model = model))
    corpus = ("points", "date", "nope", QB.F("points"), QB.F("points") + 1, QB.Q("points" => 1), QB.Qor("points" => 1),
              QB.Sum("points"), QB.Max("date"), rank, QB.Lag("points"), QB.SQLField("points"), QB.Value(1), cte, joined,
              1, Int8(1), UInt64(1), big(1), true, 1.5, Float32(1.5), big(1.5), PormG.Decimals.Decimal(1), nothing,
              Dates.Hour(1), Dates.Date(2009, 5, 24), _TspUserAgg(0))
    for policy in (QB._AllKinds(), QB._MeaningKinds()), x in corpus
      if has(:_infer_kind_any)
        @test isequal(QB._infer_kind_any(x, instruc, policy), QB._infer_kind(x, instruc, policy))
      end
      if has(:_arithmetic_side_kind_any)
        @test isequal(QB._arithmetic_side_kind_any(x, instruc, policy), QB._arithmetic_side_kind(x, instruc, policy))
      end
    end
    if has(:_may_hold_calendar_part_any)
      for x in (Dates.Month(1), Dates.Hour(1), Dates.Month(1) + Dates.Day(1), QB.Interval(Dates.Day(1)), "points",
                QB.F("points"), QB.Sum("points"), 1, nothing)
        @test QB._may_hold_calendar_part_any(x, instruc) === QB._may_hold_calendar_part(x, instruc)
      end
    end
    if has(:_whole_days)
      for n in (1, -3, Int8(2), UInt16(4), big(5))
        @test QB._whole_days(n) === Dates.Day(n)
      end
      @test_throws InexactError QB._whole_days(typemax(UInt64))   # what `Day(n)` raises
    end
    if has(:_side_kind_any)
      for x in ("points", "date", "nope", QB.F("points"), Dates.Date(2009, 5, 24), Dates.DateTime(2009, 5, 24),
                Dates.Hour(1), Dates.Month(1), QB.Interval(Dates.Day(1)), Dates.Hour(1) + Dates.Minute(2), 1,
                QB.Sum("points"), QB.Max("date"), rank, cte, joined,
                PormG.QueryBuilder.TimeZones.ZonedDateTime(2009, 5, 24, PormG.QueryBuilder.TimeZones.tz"UTC"),
                _TspUserAgg(0))   # the open arm: a function type PormG does not define
        outcome(f) = try f() catch e; typeof(e) end
        @test isequal(outcome(() -> QB._side_kind_any(x, instruc)), outcome(() -> QB._side_kind(x, instruc)))
      end
    end
  end

  # What: the trimmed read's run-time walls on the WHERE path past `_get_alias_name` (#1599 layer 5, PR 2):
  #   the join alias allocator, the relation walk (`_relation_step`, `_relation_to`, `_relation_target`), the
  #   filter operand's field and formatter (`_operand_field`, `_field_formatter`), the pattern operand
  #   (`_pattern_operand`, now positional, `_pattern_text_kind`, `_pattern_kind_read_any`) and the format guard
  #   (`_guarded_format`, `_format_filter_value`, `_locate_filter_refusal`).
  # Expected: each call the trimmed binary missed is static under the JIT, and each closed walk answers what
  #   the call it stands for answered.
  # Why: the trimmed `list(RaceRow)` stopped at each of these in turn, with a `MethodError` (a
  #   `MissingCodeError` once) on a call with no compiled target: an untyped comprehension whose element type
  #   the image could not infer (`vcat` on two `Vector{Any}`), a model held at the abstract `PormGModel`,
  #   `hasproperty`/`getproperty` on the 29-member `AnyField`, a keyword set with no concrete type, and a
  #   formatter held at the abstract `Function`. It now stops at the call through a field's
  #   `formatter::Function` (layer 3). Measured on PR 1's head 8966ecc90: every check below that names a new
  #   helper fails (not defined), and the dynamic-call checks find the calls.
  @testset "the trimmed read's WHERE path past the join alias makes its calls statically (#1599 layer 5, walls 1-7)" begin
    QB = PormG.QueryBuilder
    M = PormG.Models
    K = PormG.Kernel
    I = QB.InstructionObject
    has(n) = isdefined(QB, n)
    for n in (:_join_alias_a, :_join_alias_b, :_relation_step_at, :_relation_to, :_field_formatter,
              :_pattern_kind_read_any)
      @test has(n)
    end
    # The pattern operand takes no keyword: its keyword set had no concrete type, and a keyword call could not
    # be compiled.
    @test length(methods(QB._pattern_operand)) == 1
    @test isempty(Base.kwarg_decl(only(methods(QB._pattern_operand))))
    # Wall 1: the aliases a join row takes, read at the row's kind, in element-typed vectors.
    @test isempty(_dynamic_calls(QB._get_alias_name, (Vector{QB.JoinRow}, String, Vector{String})))
    if has(:_join_alias_a)
      rows = QB.JoinRow[QB.ModelJoin(a = "t", alias_a = "Tb", key_a = "k", b = "u", alias_b = "Tb_1", key_b = "id", how = "INNER"),
                        QB.CteJoin(a = "t", alias_a = "Tb", key_a = "k", b = "c", alias_b = "c_1", key_b = "v", how = "LEFT"),
                        QB.CrossJoin(a = "t", alias_a = "Tb", b = "c", alias_b = "c_2"),
                        QB.AnchorlessJoin(a = "t", alias_a = "Tb", b = "d", alias_b = "dd", how = "LEFT",
                                          on_conditions = QB.FilterType[], to_many = false)]
      for r in rows
        @test QB._join_alias_a(r) === r.alias_a && QB._join_alias_b(r) === r.alias_b
      end
      @test QB._get_alias_name(rows, "Tb", ["Tb_2"]) == "Tb_3"
      @test QB._get_alias_name(QB.JoinRow[], "Tb") == "Tb_1"
    end
    # Walls 2-4: one relation hop, with the model the previous hop reached and a `SubString` segment.
    @test isempty(_named_dynamic_calls(Tuple{typeof(QB._relation_run), QB.SQLObjectQuery, Vector{SubString{String}}},
                                       ("_relation_step",); depth = 1))
    if has(:_relation_step_at)
      calls = _named_dynamic_calls(Tuple{typeof(QB._relation_step_at), QB.SQLObjectQuery, M.ModelType, String, Bool},
                                   ("hasproperty", "_relation_target", "getproperty(%"); depth = 1)
      @test isempty(calls)
      isempty(calls) || @info "dynamic calls in one relation hop" calls
    end
    # Of the model fields PormG defines, exactly the three relations have a `to` slot, and no field type
    # overloads `getproperty`/`propertynames`: what `_relation_to` and `_field_formatter` rely on.
    members = Base.uniontypes(M.AnyField)
    @test Set(T for T in members if hasfield(T, :to)) == Set([M.sForeignKey, M.sOneToOneField, M.sManyToManyField])
    for T in members
      @test which(getproperty, (T, Symbol)).module === Base
      @test which(propertynames, (T,)).module === Base
      @test hasfield(T, :formatter) && fieldtype(T, :formatter) === Function
    end
    if has(:_relation_to)
      isdefined(Main, :_TspLinkField) ||
        Core.eval(Main, :(struct _TspLinkField <: $(PormG.PormGField); to::String; end))   # a caller's own link type
      for f in (M.ForeignKey("Circuit"), M.OneToOneField("Circuit"), M.ManyToManyField("Circuit"),
                M.CharField(max_length = 5), M.IntegerField(), nothing,
                Base.invokelatest(getglobal(Main, :_TspLinkField), "Circuit"))
        @test QB._relation_to(f) === (hasproperty(f, :to) ? f.to : nothing)
      end
    end
    @test isempty(_dynamic_calls(QB._relation_target, (M.ModelType, Any)))
    # A relation hop answers the same for a `SubString` segment and its `String`, and a `String` target
    # resolves to the bound model, on a model with a ForeignKey to one bound beside it.
    # A module must be a top-level expression, so it is parsed whole and evaluated in `Main`, after the mock
    # connection and the configuration `set_models` binds it to (as `test_array_lookups.jl` does).
    isdefined(Main, :TspHopModels) || Core.eval(Main, Meta.parseall("""
      struct _TspHopSQLite <: PormG.PormGSQLite end
      PormG.config["tsp_hop_models"] = PormG.Configuration.Settings(connections = _TspHopSQLite(),
                                                                    change_data = true, db_def_folder = "tsp_hop_models")
      module TspHopModels
        import PormG
        import PormG: Models
        Circuit = Models.Model("tsp_hop_circuit", circuitid = Models.IDField(), country = Models.CharField(max_length = 20))
        Race = Models.Model("tsp_hop_race", raceid = Models.IDField(), circuitid = Models.ForeignKey("Circuit"))
        Models.@models Circuit Race
        PormG.Models.set_models(@__MODULE__, "tsp_hop_models")
      end"""))
    hop_models = Base.invokelatest(getglobal, Main, :TspHopModels)
    race = Base.invokelatest(getglobal, hop_models, :Race)
    q = QB.SQLObjectQuery(model = race)
    step_s = QB._relation_step(q, race, "circuitid", true)
    step_sub = QB._relation_step(q, race, SubString("circuitid__country", 1, 9), true)
    @test step_s !== nothing && step_s == step_sub
    circuit = Base.invokelatest(getglobal, hop_models, :Circuit)
    @test step_s !== nothing && step_s[2] === circuit && step_s[3] === :forward
    @test QB._relation_target(race, "Circuit") === circuit
    # Wall 5: the operand's field typed, its formatter read without dispatch.
    # (Inference widens a tuple holding the 29-member union to `Tuple{Any, String}` whatever is declared, so
    # the check is that the body makes no dynamic call: on the base, the name read again off the slot did.)
    @test isempty(_dynamic_calls(QB._operand_field, (QB.OperObject, I)))
    if has(:_field_formatter)
      f = M.CharField(max_length = 5)
      @test QB._field_formatter(f) === f.formatter
      @test isempty(_dynamic_calls(QB._field_formatter, (M.AnyField,)))
    end
    # Walls 6-7: the pattern operand, the format guard and its catch path, called statically from the
    # filter render.
    # (Its other `.formatter` reads, on a range bound, a transform node or a joined column, are off the walls'
    # path and stay; the operand's own goes through `_field_formatter`, which inlines to the builtin `getfield`.)
    calls = _named_dynamic_calls(Tuple{typeof(QB._render_filter_oper), QB.OperObject, I},
                                 ("_pattern_operand(", "_guarded_format", "_operand_field",
                                  "_field_formatter"); depth = 1)
    @test isempty(calls)
    isempty(calls) || @info "dynamic calls in the filter render" calls
    @test occursin("operand_formatter = operand_field !== nothing ? _field_formatter(operand_field) :",
                   read(joinpath(pkgdir(PormG), "src", "querybuilder", "filter_nodes.jl"), String))
    @test isempty(_named_dynamic_calls(Tuple{typeof(QB._guarded_format), Function, Any, String, Any, Any},
                                       ("_locate_filter_refusal", "_format_filter_value"); depth = 2))
    @test isempty(_dynamic_calls(QB._pattern_text_kind, (Any,)))
    if has(:_pattern_kind_read_any)
      @test length(methods(QB._pattern_kind_read)) == 9
      for k in (K.CInt16(), K.CInt32(), K.CInt64(), K.CFloat64(), K.CDecimal(10, 2), K.CDate(), K.CTime(),
                K.CDateTime(false), K.CInterval(), K.CBool(), K.CBytes(), K.CText(), nothing)
        @test QB._pattern_kind_read_any(k) === QB._pattern_kind_read(k)
      end
    end
    # The answers the pattern walk gives, across the formatters it names (the period formatters by `===`).
    for (fmt, kind, want) in ((M.format_text_sql, nothing, nothing), (M.format_uuid_sql, nothing, :uuid),
                              (M.format_date_sql, nothing, :date), (M.format_number_sql, K.CInt32(), :integer),
                              (M.format_number_sql, nothing, :inexact_number), (M.format_hour_sql, nothing, :integer),
                              (M.format_bool_sql, nothing, :boolean), (M.format_text_sql, K.CTime(), :time))
      @test QB._pattern_text_kind(fmt; kind = kind) === want
    end
  end

  # What: three layer-5 groups by cause (#1599 layer 5, PR 3): closures over a local that is reassigned
  #   (`_reads_alias`, `build_row_join_sql_text`, `_format_filter_value`), the kind memo's
  #   `get!` (`_memo_kind`), and the FROM-column walk's `Iterators.flatten` (`_from_column_names`).
  # Expected: no `Core.Box` in the three functions or the closures they build (the shared detector,
  #   `helper_core_box.jl`, which walks every method, closures included); `_memo_kind` specialized on its closure, with
  #   no dynamic call; `_from_column_names` walks its three sources through `_add_hop_tables!`, with no
  #   `flatten`.
  # Why: every read of a box, a `get!` through a closure compiled as `Function` on a memo read as `Any`, and
  #   each step of a `flatten` over generators of different types is a run-time call, an unresolved row in a
  #   trimmed build: 88 + 32 + 6 verifier rows on the read-only entry. Measured on PR 2's head feb29214b: the
  #   three box checks, the two `_memo_kind` checks, the widened-argument check and the three `_add_hop_tables!`
  #   checks fail. (`_render_order_terms`' null-flag
  #   closure keeps its box: rebound, it captures the term's node at its union and the scope call is left
  #   unresolved instead, the #1711 residue below.)
  @testset "layer-5 groups: no boxed capture, the kind memo static, the FROM walk unflattened (#1599 layer 5, PR 3)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    isdefined(Main, :core_box_sites) || include(joinpath(@__DIR__, "helper_core_box.jl"))
    sites = Base.invokelatest(getglobal(Main, :core_box_sites), f -> occursin(joinpath("src", "querybuilder"), f), basename)
    boxed(name) = any(s -> occursin(name, s), reduce(vcat, collect(values(sites)); init = String[]))
    @test !boxed("_reads_alias")
    @test !boxed("build_row_join_sql_text")   # the box was in its `with_bucket` do-block closure
    @test !boxed("_format_filter_value")
    # `_memo_kind` is specialized on its closure, so `get!` takes it at its concrete type, and the memo is read
    # back at the type it is stored.
    m = only(methods(QB._memo_kind))
    @test Base.unwrap_unionall(m.sig).parameters[2] isa TypeVar
    probe = () -> nothing
    @test isempty(_dynamic_calls(QB._memo_kind, (typeof(probe), Any, I, Symbol)))
    @test isempty(_widened_function_args(QB._temporal_inside, (QB.FExpression, I)))
    # The FROM-column walk: three loops over its sources, in the order `flatten` gave them.
    @test isdefined(QB, :_add_hop_tables!)
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "select_nodes.jl"), String)
    s = findfirst("function _from_column_names(", src)
    @test s !== nothing
    if s !== nothing
      fbody = join((replace(l, r"#.*$" => "") for l in split(src[s[1]:findnext("\nend\n", src, s[1])[end]], '\n')), '\n')
      @test !occursin("Iterators.flatten", fbody)
      @test count("_add_hop_tables!(tables, object, ", fbody) == 3
    end
  end

  # What: the trimmed read's filter value, from the field formatter to the join scope (#1599 layer 5, read):
  #   the formatter call (`_format_filter_value` → `_format_literal_value` → `_apply_lookup_formatter` →
  #   `Models.apply_formatter`, #1781's hand-off), the bind (`_bind_formatted_value`), the predicate
  #   (`_render_predicate_any`), the unnamed-temporal queue, the outer-join check (`_join_how`,
  #   `_require_outer_join`), a join row's ON conditions (`_join_row_conditions`) and its scope
  #   (`_join_scope`, `_join_render_scope`, `_with_render_scope`'s positional method).
  # Expected: no dynamic call in each walk (one open arm each, an `:invoke`), the open arms' one dynamic call
  #   each, `_queue_unnamed_temporal!` and `_require_outer_join` unspecialized on their union arguments, no
  #   `==` or `_with_render_scope` kwcall left dynamic in `_join_scope`; the same value and type, or the same
  #   error and text, as the old `_format_filter_value` over formatters x values x operators, empty lists
  #   included; the join scope built positionally equal to the keyword one; and every direct formatter call
  #   #1781 lists outside the write path made through `Models.apply_formatter`.
  # Why: each was the read's run-time wall, one after the other: a call on an untyped value, or a keyword call
  #   whose keyword set has no concrete type, has no compiled target in a trimmed image, and raises
  #   `MethodError` (or `MissingCodeError`) when the read reaches it. Measured on main a3b3492b2: the walls'
  #   functions are missing, `_queue_unnamed_temporal!` and `_require_outer_join` are specialized, and the
  #   formatter call sites call the slot directly.
  @testset "the trimmed read formats, binds and joins its filter at concrete types (#1599 layer 5, read walls)" begin
    QB = PormG.QueryBuilder
    M = PormG.Models
    I = QB.InstructionObject
    has(n) = isdefined(QB, n)
    for n in (:_format_literal_value, :_format_literal_other, :_apply_lookup_formatter, :_format_empty_list,
              :_bind_formatted_value, :_bind_formatted_other, :_render_predicate_any, :_render_predicate_other,
              :_join_how, :_require_outer_join_feature, :_join_row_conditions, :_join_render_scope)
      @test has(n)
    end
    # Wall 1, the formatter: the literal is walked to its type, then the formatter to its own.
    literal_types = (String, Int64, Float64, Bool, SubString{String}, Dates.Date, Dates.DateTime, Dates.Time,
                     M.ZonedDateTime, M.Decimals.Decimal, M.UUIDs.UUID, Int32, Nothing, Missing)
    if has(:_format_literal_value)
      @test isempty(_dynamic_calls(QB._format_literal_value, (Function, Any, Bool)))
      for T in literal_types
        @test isempty(_dynamic_calls(QB._apply_lookup_formatter, (Function, T, Bool)))
        @test isempty(_dynamic_calls(QB._format_filter_value, (Function, T, String)))
      end
      # The open arm is the one dynamic call: on the value, at the formatter it was handed.
      @test length(_dynamic_calls(QB._format_literal_other, (Function, Any, Bool))) == 1
    end
    # The same answer as the old `_format_filter_value`, which called the formatter value directly.
    old_ffv(@nospecialize(formatter), @nospecialize(values), operator::AbstractString) = begin
      f = operator in QB._RANGE_CHECKED_OPERATORS ? formatter : M.unranged_formatter(formatter)
      operator in QB._ITERABLE_LOOKUP_OPERATORS && values isa AbstractArray ? [f(v) for v in values] : f(values)
    end
    outcome(g) = try
      r = g(); (:ok, typeof(r), r)
    catch e
      (:err, typeof(e), sprint(showerror, e))
    end
    samevalue(x, y) = isequal(x, y) || (typeof(x) === typeof(y) && isstructtype(typeof(x)) && nfields(x) > 0 &&
                                        all(i -> samevalue(getfield(x, i), getfield(y, i)), 1:nfields(x)))
    same(a, b) = a[1] === b[1] && a[2] === b[2] && samevalue(a[3], b[3])
    formatters = Any[M.format_number_sql, M.format_text_sql, M.format_date_sql, M.format_timezone_sql, M.format_bool_sql,
                     M.format_uuid_sql, M.format_json_sql, M.format_inet_sql, M.format_year_sql, M.format_month_sql,
                     M.format_yyyy_mm, QB.format_pattern_text_sql, QB.format_pattern_number_sql,
                     M.ArrayField(M.IntegerField()).formatter, v -> string("user:", v), identity, nothing]
    values = Any[7, Int32(7), 13, 2.5, true, "abc", "2009-05", SubString("2009-05-24", 1, 10), Dates.Date(2009, 5, 24),
                 Dates.DateTime(2009, 5, 24, 14), Dates.Time(10, 30), M.ZonedDateTime(2009, 5, 24, 14, M.TimeZone("UTC")),
                 M.Decimals.Decimal(0, 150, -2), M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), nothing, missing,
                 Int16(3), :sym, Dict("a" => 1),
                 Int[], Any[], String[], Dates.Date[], Float64[], [1, 2], ["a", "b"], Any[1, "a"], [Dates.Date(2009, 5, 24)]]
    if has(:_format_literal_value)
      for f in formatters, v in values, op in ("=", "IN", "NOT IN", "BETWEEN", ">", "LIKE")
        @test same(outcome(() -> QB._format_filter_value(f, v, op)), outcome(() -> old_ffv(f, v, op)))
      end
    end

    # Walls 2 and 3, the bind and the predicate: the formatted value and the placeholders, each at its type.
    if has(:_bind_formatted_value)
      @test isempty(_dynamic_calls(QB._bind_formatted_value, (I, Any, Bool, String)))
      @test length(_dynamic_calls(QB._bind_formatted_other, (I, Any, Bool, String))) == 1
      @test isempty(_dynamic_calls(QB._render_predicate_any, (String, String, Any, I, Bool)))
      @test length(_dynamic_calls(QB._render_predicate_other, (String, String, Any, I, Bool))) == 1
    end

    # Wall 4: one body for the queue, whatever its two sides are.
    @test only(methods(QB._queue_unnamed_temporal!)).nospecialize != 0

    # Wall 5, the outer-join check: the join type read at the row's kind, the connection unspecialized, and the
    # capability asked of the pool at its concrete type.
    @test only(methods(QB._require_outer_join)).nospecialize != 0
    rows = QB.JoinRow[QB.ModelJoin(a = "t", alias_a = "Tb", key_a = "k", b = "u", alias_b = "Tb_1", key_b = "id", how = "INNER"),
                      QB.CteJoin(a = "t", alias_a = "Tb", key_a = "k", b = "c", alias_b = "c_1", key_b = "v", how = "LEFT"),
                      QB.AnchorlessJoin(a = "t", alias_a = "Tb", b = "d", alias_b = "dd", how = "RIGHT",
                                        on_conditions = QB.FilterType[], to_many = false)]
    if has(:_join_how)
      for r in rows
        @test QB._join_how(r) === r.how
      end
      @test isempty(_dynamic_calls(QB._join_how, (QB.JoinRow,)))
      @test isempty(_dynamic_calls(QB._require_outer_join, (Any, String)))
      # The pool arm is static; anything that is not a pool makes the one call it made before.
      @test length(_dynamic_calls(QB._require_outer_join_feature, (Any, Symbol, String))) == 1
      sl = PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)
      @test QB._require_outer_join(sl, "INNER") === nothing
      @test QB._require_outer_join(sl, "LEFT") === nothing
      @test outcome(() -> QB._require_outer_join(sl, "FULL")) == outcome(() -> PormG._require_feature(sl, :full_joins, "join_type = \"FULL\""))
    end

    # Walls 6 to 8, a join row's ON conditions: the row walked to its kind before the closure is built, the
    # earlier rows' aliases read typed and compared without a box, and the scope built positionally.
    if has(:_join_row_conditions)
      @test isempty(_dynamic_calls(QB._join_row_conditions, (I, Int, QB.JoinRow)))
      probe = () -> String[]
      for R in (QB.ModelJoin, QB.CteJoin, QB.AnchorlessJoin)
        dyn = _dynamic_calls(QB._join_scope, (typeof(probe), I, Int, R))
        @test !any(c -> occursin("_with_render_scope", c) || occursin(r"(^|\W)==\(", replace(c, r"^\d+: " => "")), dyn)
      end
    end
    if has(:_join_render_scope)
      base = QB.RenderScope(label = "x", group_key = true)
      for (left, right) in ((("Tb",), ("Tb", "Tb_1")), (("Tb", "R1", "dd"), ("Tb", "R1", "dd")), ((), ()))
        @test QB._join_render_scope(base, "Tb_1", left, right) ===
              QB._with_scope(base; join_hop = "Tb_1", join_side = :none, join_left = left, join_right = right)
      end
      @test length(_dynamic_calls(QB._join_render_scope, (QB.RenderScope, String, Tuple{Vararg{String}}, Tuple{Vararg{String}}))) == 0
    end

    # #1781's hand-off: every direct formatter call outside the write path goes through `apply_formatter`.
    qb_src(f) = read(joinpath(pkgdir(PormG), "src", "querybuilder", f), String)
    code(f) = join((replace(l, r"#.*$" => "") for l in split(qb_src(f), '\n')), '\n')
    @test count("Models.apply_formatter(", code("many_to_many.jl")) == 2
    @test count("Models.apply_formatter(", code("deletion.jl")) == 1
    @test count("Models.apply_formatter(", code("value_validation.jl")) == 2   # + the write's format step (#1694)
    @test count("Models.apply_formatter(", code("expression_render.jl")) == 2
    @test !occursin(".formatter(", code("many_to_many.jl")) && !occursin(".formatter(", code("deletion.jl"))
    # And the WHERE path's three direct binds go through the walk, beside `_bind_predicate_value`'s.
    @test count("_bind_formatted_value(instruc,", code("filter_nodes.jl")) == 4
  end

  # What: the single-row write's run-time walls (#1599 layer 7, #1694), one per step of the full fixture
  #   entry's `create`: the value checks (`validate_field_data` → `_validate_field_value_at`) and the format
  #   step's keyword call (`_format_single` → `_format_single_at`), the formatter call (`Models.apply_formatter`),
  #   the formatted value's collection and NUL checks (`_checked_formatted`), the bind (`_bind_written_value!`),
  #   the statement's column and placeholder lists (`_prepare_row_insert!`).
  # Expected: `validate_field_data` and `_format_single` take their value unspecialized, and neither their
  #   keyword bodies nor the walks make a dynamic call (each open arm makes one, whatever the field's type);
  #   each returns the same value, or raises the same error type with the same text, as the code it
  #   replaces, over fields x values x operations (x connections for the format step).
  # Why: a write's values come out of `SQLObjectQuery.insert::OrderedDict{String,Any}`, so each call on one is
  #   a run-time dispatch, and a trimmed image raises `MethodError` when nothing was compiled for the type it
  #   meets. Measured on main 4384550db: the full entry's binary stopped at the `validate_field_data` keyword
  #   call with an `Int64`; the method is specialized and its keyword body calls `_validate_field_value`
  #   dynamically.
  @testset "the single-row write checks its values at their concrete types (#1599 layer 7, write walls)" begin
    QB = PormG.QueryBuilder
    M = PormG.Models
    has(n) = isdefined(QB, n)
    for n in (:_validate_field_value_at, :_validate_field_value_other)
      @test has(n)
    end
    literal_types = (String, Int64, Float64, Bool, SubString{String}, Dates.Date, Dates.DateTime, Dates.Time,
                     M.ZonedDateTime, M.Decimals.Decimal, M.UUIDs.UUID, Int32, Nothing, Missing)

    # The callee names a function's optimized code `:invoke`s. A walk that lost an arm still makes no dynamic
    # call (its value goes to the `@noinline` open arm, an `:invoke` too), so each arm is pinned by what it
    # does NOT invoke: at a type with an arm the open arm is dead code, and without the arm it is called.
    # (The leaf is no pin: it is inlined at some types.)
    invoked(f, tt) = [string((s.args[1] isa Core.CodeInstance ? s.args[1].def : s.args[1]).def.name)
                      for s in only(code_typed(f, tt; optimize = true))[1].code if s isa Expr && s.head === :invoke]
    not_open(f, tt, open) = !(open in invoked(f, tt))

    # Wall 1, the value checks.
    @test only(methods(QB.validate_field_data)).nospecialize != 0
    @test isempty(_dynamic_calls_kw(QB.validate_field_data, (M.ModelType, String, Any, String)))
    if has(:_validate_field_value_at)
      @test isempty(_dynamic_calls(QB._validate_field_value_at, (M.ModelType, String, M.AnyField, Any, String)))
      @test length(_dynamic_calls(QB._validate_field_value_other, (M.ModelType, String, M.AnyField, Any, String))) == 1
      for T in literal_types
        @test isempty(_dynamic_calls(QB._validate_field_value_at, (M.ModelType, String, M.sIntegerField, T, String)))
        @test not_open(QB._validate_field_value_at, (M.ModelType, String, M.sIntegerField, T, String), "_validate_field_value_other")
      end
    end

    # The same answer as the direct call: the value, or the error's type and text.
    outcome(g) = try
      r = g(); (:ok, typeof(r), r)
    catch e
      (:err, typeof(e), sprint(showerror, e))
    end
    # `PormGBytes` defines no `isequal`: two payloads are the same when their bytes are.
    samevalue(x, y) = isequal(x, y) || (typeof(x) === typeof(y) && isstructtype(typeof(x)) && nfields(x) > 0 &&
                                        all(i -> samevalue(getfield(x, i), getfield(y, i)), 1:nfields(x)))
    same(a, b) = a[1] === b[1] && a[2] === b[2] && samevalue(a[3], b[3])
    model = M.Model("tsp_write_race", raceid = M.IDField(), year = M.IntegerField(), name = M.CharField(max_length = 8),
      notes = M.TextField(null = true), points = M.FloatField(), price = M.DecimalField(max_digits = 5, decimal_places = 2),
      date = M.DateField(), start_at = M.DateTimeField(null = true), lap = M.TimeField(), uid = M.UUIDField(),
      done = M.BooleanField(), data = M.JSONField(), blob = M.BinaryField(max_length = 4), lap_time = M.DurationField(),
      ip = M.GenericIPAddressField(), tags = M.ArrayField(M.CharField(max_length = 3)))
    values = Any["abc", "123456789", "12.5", "2009-05-24", "10:30", "1:27.452", "550e8400-e29b-41d4-a716-446655440000",
                 "10.0.0.1", "{\"a\":1}", "{1,2}", SubString("2009-05-24", 1, 10), 7, Int32(7), 0, 123456, 2.5, NaN, true,
                 Dates.Date(2009, 5, 24), Dates.DateTime(2009, 5, 24, 14), Dates.Time(10, 30),
                 M.ZonedDateTime(2009, 5, 24, 14, M.TimeZone("UTC")), M.Decimals.Decimal(0, 150, -2),
                 M.Decimals.Decimal(0, 123456, -2), M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), nothing, missing,
                 Int16(3), :sym, Dict("a" => 1), ["ab", "c"], ["abcd"], UInt8[1, 2, 3, 4, 5], Dates.Minute(1), [1, 2]]
    old(f, v, op) = QB._validate_field_value(model, f, QB._validate_field_name(model, f, op), v, op)
    for f in model.field_names, v in values, op in ("insert", "update")
      @test same(outcome(() -> QB.validate_field_data(model, f, v, op)), outcome(() -> old(f, v, op)))
    end

    # Wall 2, the format step's keyword call: the value unspecialized, the field's two facts read before the
    # walk, so the body is compiled per value type only.
    for n in (:_format_single_at, :_format_single_other, :_format_single_value)
      @test has(n)
    end
    @test only(methods(QB._format_single)).nospecialize != 0
    if has(:_format_single_at)
      @test isempty(_dynamic_calls_kw(QB._format_single, (M.sIntegerField, String, Any, String)))
      @test isempty(_dynamic_calls(QB._format_single_at, (Function, Bool, String, Any, String)))
      @test length(_dynamic_calls(QB._format_single_other, (Function, Bool, String, Any, String))) == 1
      @test only(methods(QB._format_single_value)).nospecialize != 0
      for T in literal_types
        @test not_open(QB._format_single_at, (Function, Bool, String, T, String), "_format_single_other")
      end
      # Wall 3, the formatter: called through `Models.apply_formatter`, never through the slot's `Function`.
      for T in literal_types
        @test isempty(_dynamic_calls(QB._format_single_value, (Function, Bool, String, T, String)))
      end
    end
    # Walls 4 and 5, the formatted value's collection and NUL checks: walked to its type, one dynamic call in
    # the open arm.
    for n in (:_checked_formatted, :_checked_formatted_other, :_checked_formatted_value)
      @test has(n)
    end
    if has(:_checked_formatted)
      @test isempty(_dynamic_calls(QB._checked_formatted, (Any, String, String)))
      @test length(_dynamic_calls(QB._checked_formatted_other, (Any, String, String))) == 1
      for T in (literal_types..., PormG.PormGBytes, PormG.PormGArrayLiteral)
        @test isempty(_dynamic_calls(QB._checked_formatted_value, (T, String, String)))
        @test not_open(QB._checked_formatted, (T, String, String), "_checked_formatted_other")
      end
    end
    # The same answer as the old body, which read the field inside it.
    old_fs(f_meta, field, value, op, conn) = begin
      QB._refuse_collection(f_meta, field, value, op)
      formatted = try
        QB._write_formatter(f_meta, conn)(value)
      catch e
        e isa PormG.InvalidValueError && throw(QB.with_location(e; op = op, field = field))
        rethrow()
      end
      formatted = QB._single_value(formatted, field, op)
      QB._contains_nul(formatted) && throw(PormG.InvalidValueError(
        "The value contains a NUL character (\\0). " * QB.NUL_REFUSAL_REASON, :nul; op = op, field = field))
      formatted
    end
    CP = PormG.ConnectionPool
    conns = Any[nothing, CP.SQLiteConnectionPool(":memory:"; pool_size = 1), CP.MySQLConnectionPool("host='x'"; pool_size = 1)]
    fs_values = vcat(values, Any["a\0b", Any["a", 1], (1, 2), Dates.Second(3), Int64[]])
    for f in model.field_names, v in fs_values, c in conns
      f_meta = model.fields[f]
      @test same(outcome(() -> QB._format_single(f_meta, f, v, "insert"; conn = c)),
                    outcome(() -> old_fs(f_meta, f, v, "insert", c)))
    end

    # Wall 6, the bind: the formatted value walked to its type on each engine's collector, one dynamic call in
    # the open arm, and the same placeholder and the same collected parameter as the direct call.
    for n in (:_bind_written_value!, :_bind_written_other!)
      @test has(n)
    end
    collectors = (() -> QB.SQLiteParameterizedQuery(), () -> QB.PgParameterizedQuery("", Any[], 0),
                  () -> QB.MySQLParameterizedQuery())
    if has(:_bind_written_value!)
      for mk in collectors
        C = typeof(mk())
        @test isempty(_dynamic_calls(QB._bind_written_value!, (C, Any)))
        @test length(_dynamic_calls(QB._bind_written_other!, (C, Any))) == 1
        for T in (literal_types..., PormG.PormGBytes, PormG.PormGArrayLiteral)
          @test not_open(QB._bind_written_value!, (C, T), "_bind_written_other!")
        end
      end
      bound = Any["abc", 7, Int32(7), 2.5, true, nothing, missing, Dates.Date(2009, 5, 24), M.Decimals.Decimal(0, 150, -2),
                  M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), SubString("abc", 1, 2),
                  PormG.PormGBytes(UInt8[1, 2]), PormG.PormGArrayLiteral("{1,2}"), Int16(3)]
      for mk in collectors, v in bound
        a, b = mk(), mk()
        ra = outcome(() -> QB._bind_written_value!(a, v))
        rb = outcome(() -> QB.add_parameter!(b, v))
        @test same(ra, rb) && samevalue(a, b)
      end
    end
    # The insert's row marshalling makes none of these calls dynamically any more.
    insert_calls = _dynamic_calls(QB._prepare_row_insert!, (QB.SQLObjectQuery, M.ModelType, PormG.Kernel.Settings,
                                                           CP.SQLiteConnectionPool, QB.SQLiteParameterizedQuery))
    @test !any(c -> occursin(r"validate_field_data|_format_single|add_parameter!|kwcall", c), insert_calls)
    # Wall 7, the statement text: the column and placeholder lists are `String` vectors, so `join` prints each
    # element statically (over a `Vector{Any}` the trimmed binary raised `MissingCodeError`).
    @test only(Base.return_types(QB._prepare_row_insert!, (QB.SQLObjectQuery, M.ModelType, PormG.Kernel.Settings,
                                 CP.SQLiteConnectionPool, QB.SQLiteParameterizedQuery))) ==
          Tuple{Vector{String}, Vector{String}, Bool, Vector{String}}
    # and a placeholder goes into its `String` vector asserted, not converted (a dynamic `convert` in the verifier).
    ew_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_write.jl"), String)
    @test occursin("push!(param_values, _bind_written_value!(parameters, formatted)::String)", ew_src)
    # and the primary-key list is built typed: `pk_field::Vector{String} = []` converted a `Vector{Any}` (4 rows).
    @test occursin("pk_field = String[]", ew_src) && !occursin("pk_field::Vector{String} = []", ew_src)
    foreach(c -> c === nothing || CP.close_pool!(c), conns)
  end

  # What: the single-row write's error paths (#1599 layer 7, #1694): the formatter refusal every validator's
  #   `catch` calls (`_formatter_refusal`), and the format step's located refusal (`with_location`).
  # Expected: no validator calls `_formatter_refusal` dynamically (it takes the caught exception unspecialized),
  #   and `with_location`'s keyword body makes no dynamic call at the types its callers pass; each raises the
  #   same error type with the same text as the code it replaces.
  # Why: each is a keyword call whose arguments have no concrete type (the caught exception; the located parts'
  #   run-time types), a run-time dispatch that a trimmed image cannot make where nothing was compiled, so a
  #   refused value raises `MethodError` in place of its refusal. Measured on #1797's head 4279d9785 with the full
  #   fixture entry's refusal step: the create with a `Bool` for a text column raised `MethodError` at
  #   `with_location`'s keyword call in the trimmed binary, and the verifier listed 28 rows at the validators'
  #   calls (the date refusal printed: the image had compiled that call for an `InvalidValueError`).
  @testset "the single-row write's refusals run at concrete types (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    M = PormG.Models
    IVE = PormG.InvalidValueError
    @test isdefined(QB, :_formatter_refusal_other)
    outcome(g) = try
      r = g(); (:ok, typeof(r), r)
    catch e
      (:err, typeof(e), e isa IVE ? (e.msg, e.kind, e.reason, e.op, e.model, e.field, e.field_type, e.row) :
                                    sprint(showerror, e))
    end
    model = M.Model("tsp_refusal_race", raceid = M.IDField(), year = M.IntegerField(), name = M.CharField(),
      price = M.DecimalField(max_digits = 5, decimal_places = 2), date = M.DateField(), lap = M.TimeField(),
      start_at = M.DateTimeField(), uid = M.UUIDField(), data = M.JSONField(), lap_time = M.DurationField(),
      ip = M.GenericIPAddressField(), tags = M.ArrayField(M.IntegerField()))

    # The validators' catch arms: the keyword call on the caught exception is static.
    @test only(methods(QB._formatter_refusal)).nospecialize != 0
    refusal_call(c) = occursin("_formatter_refusal", c)
    for v in (QB._validate_decimal_value, QB._validate_date_value, QB._validate_time_value, QB._validate_duration_value,
              QB._validate_datetime_value, QB._validate_uuid_value, QB._validate_json_value),
        T in (String, SubString{String})
      @test !any(refusal_call, _dynamic_calls(v, (M.ModelType, String, T, String)))
    end
    for (v, F) in ((QB._validate_network_value, M.sGenericIPAddressField), (QB._validate_array_value, M.sArrayField))
      @test !any(refusal_call, _dynamic_calls(v, (M.ModelType, String, F, String, String)))
    end
    @test isempty(_dynamic_calls_kw(QB._formatter_refusal, (Any, String, M.ModelType, String)))
    # The refusal is the one the old body raised, for each kind of caught error; Ctrl-C and a stack overflow
    # are rethrown as they were.
    old_refusal(e, op, model, field; suggestion = nothing) = begin
      (e isa InterruptException || e isa StackOverflowError) && rethrow(e)
      e isa IVE || QB._validation_error(op, model, field, "the value could not be formatted ($(typeof(e)))";
                                         suggestion = suggestion)
      QB._validation_error(op, model, field, e.reason; suggestion = suggestion, kind = e.kind)
    end
    caught = Any[IVE("not a date", :format), IVE("too long", :range; op = "inner", field = "x"), ArgumentError("bad"),
                 MethodError(+, ("a", 1)), InexactError(:Int64, Int64, 1.5), InterruptException(), StackOverflowError()]
    for e in caught, s in (nothing, "pass a Date")
      @test outcome(() -> QB._formatter_refusal(e, "insert", model, "date"; suggestion = s)) ==
            outcome(() -> old_refusal(e, "insert", model, "date"; suggestion = s))
    end
    # And through the validators, end to end: a refused string on each field with a catch arm.
    for (f, v) in (("price", "12,5"), ("price", "abc"), ("date", "2009-02-30"), ("date", "not a date"), ("lap", "25:61"),
                   ("start_at", "yesterday"), ("uid", "not-a-uuid"), ("data", "{bad"), ("lap_time", "fast"),
                   ("ip", "10.0.0.300"), ("tags", "{1,"))
      r = outcome(() -> QB.validate_field_data(model, f, v, "insert"))
      @test r[1] === :err && r[2] === IVE && r[3][6] == f
    end

    # The format step's located refusal: `with_location`'s keyword body, at the types its callers pass (the format
    # step: op and field; a bulk cell: op, model, field and row; a filter: op, field and field type).
    # Followed four calls down (`_dynamic_calls_deep`): the keyword sorter, the constructor and `_render_refusal`
    # are each one call below the last, and a one-level scan saw the sorter's call into the keyword body resolved
    # while the body it called was picked at run time (the second wall: `MethodError(var"#_#2#3", …)`).
    wl_step(e, op::String, field::String) = PormG.with_location(e; op = op, field = field)
    wl_cell(e, op::String, model::String, field::String, row::Int) =
      PormG.with_location(e; op = op, model = model, field = field, row = row)
    wl_filter(e, op::String, field::String, t::Union{Nothing, String}) =
      PormG.with_location(e; op = op, field = field, field_type = t)
    @test isempty(_dynamic_calls_deep(wl_step, (IVE, String, String); depth = 4))
    @test isempty(_dynamic_calls_deep(wl_cell, (IVE, String, String, String, Int); depth = 4))   # static before: one open part
    @test isempty(_dynamic_calls_deep(wl_filter, (IVE, String, String, Union{Nothing, String}); depth = 4))
    # The same refusal as the keyword spelling it replaces: a part the error carries is kept, the others filled,
    # each converted as the constructor converts it (a `Symbol`, a `SubString`, an `Int32` row).
    old_wl(e; op = nothing, model = nothing, field = nothing, field_type = nothing, row = nothing) =
      IVE(e.reason, e.kind; op = something(e.op, op, Some(nothing)), model = something(e.model, model, Some(nothing)),
          field = something(e.field, field, Some(nothing)), field_type = something(e.field_type, field_type, Some(nothing)),
          row = something(e.row, row, Some(nothing)))
    errs = (IVE("bad", :format), IVE("bad", :range; op = "inner", field = "a"), IVE("bad", :type; row = 3),
            IVE("plain message"))
    parts = ((;), (; op = "insert", field = "date"), (; op = "bulk_insert", model = "Race", field = "date", row = 7),
             (; op = :filter, field = SubString("date", 1, 4), field_type = "DATE"), (; row = Int32(2)), (; row = 2.0),
             (; op = "update", row = typemax(UInt64)))
    for e in errs, kw in parts
      @test outcome(() -> PormG.with_location(e; kw...)) == outcome(() -> old_wl(e; kw...))
    end

  end

  # What: the single-row write's default fill (#1599 layer 7, #1694): the value of an `auto_now`/`auto_now_add`/
  #   `auto_add` field (`_fill_formatted!`, and `_now_in` for a timestamp's current time), and the SQLite id
  #   reservation `create` reads inside a transaction (`_allocate_sqlite_ids`), both stored in
  #   `SQLObjectQuery.insert::OrderedDict{String,Any}`.
  # Expected: the fill makes no dynamic call (its open arm makes one) and stores what the slot call stored,
  #   `_now_in` makes none and gives `now(TimeZone(zone))`'s zone, the insert's marshalling stores nothing and
  #   calls no formatter dynamically, and the reservation infers `Vector{Int64}`.
  # Why: the fill called the field's `Function` slot and stored its untyped result, parsed the connection's zone
  #   name at run time, and the reservation's ids were `Any`: code a trimmed image cannot run. Measured on
  #   #1797's head 4279d9785: 52 verifier rows at the three fills and the reservation in the full fixture entry,
  #   and with the fixture's three auto-filled fields the binary's `create` raised
  #   `MethodError(!=, (SubString, SubString))` in `TimeZone("UTC")`.
  @testset "the single-row write's default fill runs at concrete types (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    M = PormG.Models
    CP = PormG.ConnectionPool
    has(n) = isdefined(QB, n)
    for n in (:_fill_formatted!, :_fill_other!, :_now_in)
      @test has(n)
    end
    outcome(g) = try
      r = g(); (:ok, typeof(r), r)
    catch e
      (:err, typeof(e), sprint(showerror, e))
    end
    model = M.Model("tsp_fill_race", raceid = M.IDField(), year = M.IntegerField(),
      created_at = M.DateTimeField(auto_now_add = true), updated_on = M.DateField(auto_now = true),
      token = M.UUIDField(auto_add = true))

    # The default fill: the formatter at its own type, the text stored at its type, one dynamic call in the open
    # arm, and the same insert as the slot call.
    OD = QB.OrderedCollections.OrderedDict{String, Any}
    if has(:_fill_formatted!)
      for (F, V) in ((typeof(M.format_timezone_sql), M.ZonedDateTime), (typeof(M.format_date_sql), Dates.Date),
                     (typeof(M.format_uuid_sql), M.UUIDs.UUID), (Function, M.ZonedDateTime), (Function, Dates.Date),
                     (Function, M.UUIDs.UUID))
        @test isempty(_dynamic_calls(QB._fill_formatted!, (OD, String, F, V)))
      end
      @test length(_dynamic_calls(QB._fill_other!, (OD, String, Any))) == 1
      fills = Any[("created_at", M.ZonedDateTime(2009, 5, 24, 14, M.TimeZone("UTC"))), ("updated_on", Dates.Date(2009, 5, 24)),
                  ("token", M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"))]
      for (f, v) in fills, other in (identity, x -> missing, x -> error("refused"))
        for g in (model.fields[f].formatter, other)
          a = OD("year" => 2009); b = OD("year" => 2009)
          ra = outcome(() -> QB._fill_formatted!(a, f, g, v))
          rb = outcome(() -> (b[f] = g(v); nothing))
          @test isequal(ra, rb) && isequal(collect(a), collect(b)) && all(k -> typeof(a[k]) === typeof(b[k]), keys(a))
        end
      end
    end
    # The current time: UTC is the constant `TimeZone("UTC")` returns, so no zone name is parsed; any other zone is
    # `TimeZone(zone)`'s, as before.
    if has(:_now_in)
      @test isempty(_dynamic_calls(QB._now_in, (String,)))
      @test only(Base.return_types(QB._now_in, (String,))) === M.ZonedDateTime
      @test QB._now_in("UTC").timezone === M.TimeZone("UTC") === M._DATETIME_UTC_TZ
      # and the UTC branch is the constant in the code, not a parse: `now(TimeZone(zone))` gives the same zone
      # and has no dynamic call under the JIT, so only the constant's presence tells the two apart.
      holds_utc(x) = x === M._DATETIME_UTC_TZ || (x isa QuoteNode && x.value === M._DATETIME_UTC_TZ) ||
                     (x isa GlobalRef && x.name === :_DATETIME_UTC_TZ) || (x isa Expr && any(holds_utc, x.args))
      @test any(holds_utc, only(code_typed(QB._now_in, (String,); optimize = true))[1].code)
      # The zone, or the same refusal (a legacy name, an unknown one).
      for zone in ("America/Sao_Paulo", "Europe/Paris", "UTC+3", "Europe/Monaco", "Mars/Olympus")
        @test isequal(outcome(() -> QB._now_in(zone).timezone), outcome(() -> M.TimeZone(zone)))
      end
      t0 = M.now(M.TimeZone("UTC")); t = QB._now_in("UTC"); t1 = M.now(M.TimeZone("UTC"))
      @test t0 <= t <= t1
    end
    # and both fills take it from there, the insert's and `update`'s (#1694's update step): no zone is parsed
    # in the file.
    ew_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_write.jl"), String)
    @test count("now(TimeZone(settings.time_zone))", ew_src) == 0 && count("_now_in(settings.time_zone)", ew_src) == 2
    @test count("_fill_formatted!(objct.insert, field, model.fields[field].formatter", ew_src) == 2
    # The insert's marshalling stores nothing in the insert through a dynamic call, and calls no formatter slot.
    insert_calls = _dynamic_calls(QB._prepare_row_insert!, (QB.SQLObjectQuery, M.ModelType, PormG.Kernel.Settings,
                                                           CP.SQLiteConnectionPool, QB.SQLiteParameterizedQuery))
    @test !any(c -> occursin("setindex!", c), insert_calls)
    @test !any(c -> occursin(r"^\d+: \(%\d+\)\(", c), insert_calls)
    # The SQLite id reservation infers its ids: `create` reads the first and stores it in the insert.
    @test only(Base.return_types(QB._allocate_sqlite_ids, (M.ModelType, CP.SQLiteConnectionPool, String, Int,
                                 PormG.Kernel.Settings))) == Vector{Int64}
  end

  # What: the insert's read-back (#1599 layer 7, #1694): the decoder that carries each column's field and read
  #   parser to `fetch` (`QueryBuilder._FieldRowDecoder`), the read-back's fetch (`_read_back_rows`), and the SQLite
  #   extension's `backend_execute_rows` method that steps the statement into the field-keyed Dicts.
  # Expected: the decoder is a concrete type with concrete fields, and none of these makes a dynamic call; the
  #   read-back's rows infer `Vector{Dict{Symbol,Any}}`; `insert` reads its row back through them.
  # Why: the read-back was `fetch(…) |> Tables.rowtable` and `pairs(row)` on a row type decided at run time.
  #   Measured on main e875884: the full fixture entry's `create` raised `MethodError(|>, (Vector{NamedTuple{…}},
  #   typeof(Tables.rowtable)))` there, after its INSERT; with the decoder the write completes and the read after
  #   it returns the new row (`test/unit/test_insert_read_back_decoder.jl` holds the equivalence).
  @testset "the insert's read-back is decoded on SQLite's worker at concrete types (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    CP = PormG.ConnectionPool
    X = Base.get_extension(PormG, :PormGSQLiteExt)
    has = isdefined(QB, :_FieldRowDecoder) && isdefined(QB, :_read_back_rows) && isdefined(X, :_sqlite_field_rows)
    @test has
    if has
      D = QB._FieldRowDecoder
      @test isconcretetype(D) && all(isconcretetype, fieldtypes(D))
      @test isempty(_dynamic_calls(QB._FieldRowDecoder, (PormG.Models.ModelType, CP.SQLiteConnectionPool)))
      for P in (Nothing, QB.SQLiteParameterizedQuery)
        @test (P, _dynamic_calls(QB._read_back_rows, (PormG.Kernel.Settings, String, P, D))) == (P, String[])
        @test only(Base.return_types(QB._read_back_rows, (PormG.Kernel.Settings, String, P, D))) ==
              Vector{Dict{Symbol, Any}}
      end
      @test isempty(_dynamic_calls_kw(PormG.backend_execute_rows, (CP.SQLiteConnectionPool, SQLite.DB, String, Nothing, D)))
      for P in (Nothing, Vector{Any})
        @test (P, _dynamic_calls(X._sqlite_field_rows, (SQLite.DB, String, P, D))) == (P, String[])
      end
      @test isempty(_dynamic_calls(X._sqlite_field_rows_into, (SQLite.Query{false}, D)))
      @test isempty(_dynamic_calls(X._sqlite_field_cell, (Ptr{SQLite.C.sqlite3_stmt}, Int, PormG.ReadParser)))
    end
    ew_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_write.jl"), String)
    @test occursin("_read_back_rows(settings, read_back[1], read_back[2], decoder)", ew_src)
    @test !occursin("fetch(settings, read_back[1])", ew_src)
  end

  # What: the untyped read (#1599 layer 6): the decoder that carries each projection's read parser to `fetch`
  #   (`QueryBuilder._ProjectionRowDecoder`), its fetch (`_fetch_projection_rows`), and the SQLite extension's
  #   `backend_execute_rows` method, shared with the insert's read-back, that steps the statement into the rows.
  # Expected: the decoder is a concrete type with concrete fields; none of these makes a dynamic call; the rows
  #   infer `Vector{Dict{Symbol,Any}}`; `_list_raw` reads through them and no longer builds its rows after `fetch`.
  # Why: `_list_raw` handed `fetch`'s result, typed `Any`, to `_rows_from_result`, whose SQLite method walks a
  #   `NamedTuple` per row whose type the statement decides; a trimmed image has no code for it.
  #   `test/integration/test_untyped_read_equivalence_1599.jl` holds the equivalence against the old read.
  @testset "the untyped read is decoded on SQLite's worker at concrete types (#1599 layer 6)" begin
    QB = PormG.QueryBuilder
    CP = PormG.ConnectionPool
    X = Base.get_extension(PormG, :PormGSQLiteExt)
    has = isdefined(QB, :_ProjectionRowDecoder) && isdefined(QB, :_fetch_projection_rows)
    @test has
    if has
      D = QB._ProjectionRowDecoder
      @test isconcretetype(D) && all(isconcretetype, fieldtypes(D))
      @test isempty(_dynamic_calls(QB._ProjectionRowDecoder, (QB.InstructionObject, CP.SQLiteConnectionPool)))
      for P in (Nothing, QB.SQLiteParameterizedQuery)
        @test (P, _dynamic_calls(QB._fetch_projection_rows, (PormG.Kernel.Settings, String, P, D))) == (P, String[])
        @test only(Base.return_types(QB._fetch_projection_rows, (PormG.Kernel.Settings, String, P, D))) ==
              Vector{Dict{Symbol, Any}}
      end
      @test isempty(_dynamic_calls_kw(PormG.backend_execute_rows, (CP.SQLiteConnectionPool, SQLite.DB, String, Nothing, D)))
      @test isempty(_dynamic_calls(X._sqlite_field_rows_into, (SQLite.Query{false}, D)))
    end
    er_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_read.jl"), String)
    @test occursin("_fetch_projection_rows(settings, rendered.sql, rendered.instruction.parameters, decoder)", er_src)
    @test !occursin("return _rows_from_result(result, _projection_parsers(built, connection))", er_src)
  end

  # What: `list(q, format::Symbol)` (#1599 layer 6), which `q.list()` and `q.list(:dict)` reach with the format as a
  #   run-time `Symbol`.
  # Expected: the keyword body makes no dynamic call: `:row`, `:dict` and `:json` call their `Val` methods
  #   statically, and any other format goes to `_list_other_format`, the barrier that keeps the old dispatch.
  # Why: `list(objct, Val(format); kwargs...)` built the `Val` at run time, and the trimmed `list()` raised
  #   `MethodError` on that keyword call (`Core.kwcall(…, list, ObjectHandler, Val{:row})`).
  @testset "list(q, format) calls the format's method statically (#1599 layer 6)" begin
    QB = PormG.QueryBuilder
    @test isdefined(QB, :_list_other_format)
    @test isempty(_dynamic_calls_kw(QB.list, (QB.ObjectHandler, Symbol)))   # the concrete handler a terminal holds
  end

  # What: an ORDER BY term rendered in its interval form (#1599 layer 6): the term's operand and its NULL flag, each
  #   rendered in the term's render scope.
  # Expected: each is rendered through `_with_field_part_open`, with the term at its member's type, by a helper that
  #   builds its closure over that concrete node and makes no dynamic call; no closure over the term's union-typed
  #   slot is left at either site.
  # Why: the closure over `order_node` (and `interval_node`) had a type with an unbound parameter, and the verifier
  #   could not resolve the call that took it; the trimmed untyped `list()` with an `order_by` raised
  #   `MissingCodeError` there, first in the keyword form and then in the positional one.
  @testset "the ORDER BY interval form is rendered at the term's member type (#1599 layer 6)" begin
    QB = PormG.QueryBuilder
    bs_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "build_select.jl"), String)
    @test occursin("_with_field_part_open(_interval_operand_scoped, order_node, instruc,", bs_src)
    @test occursin("_with_field_part_open(_interval_ms_flag_scoped, interval_node, instruc,", bs_src)
    @test !occursin("() -> _render_interval_operand(order_node, instruc)", bs_src)
    @test !occursin("() -> first(_render_interval_ms(interval_node, instruc))", bs_src)
    has = isdefined(QB, :_interval_operand_scoped) && isdefined(QB, :_interval_ms_flag_scoped)
    @test has
    if has
      for f in (QB._interval_operand_scoped, QB._interval_ms_flag_scoped), N in (String, QB.FObject)
        @test (f, N, _dynamic_calls(f, (N, QB.InstructionObject, QB.RenderScope))) == (f, N, String[])
      end
    end
  end

  # What: the ORDER BY render's check for an interval with no millisecond form (#1599 layer 6), which negates the
  #   `_interval_ms_candidate` walk's answer.
  # Expected: the walk's answer is asserted `Bool` before `!`; every `_interval_ms_candidate` method returns a `Bool`.
  # Why: the walk's open arm is untyped, so `!` was a run-time dispatch (`!(::Bool)` with no compiled target), and the
  #   trimmed untyped `list()` with an `order_by` raised `MethodError` there.
  @testset "the ORDER BY interval check negates a Bool (#1599 layer 6)" begin
    QB = PormG.QueryBuilder
    bs_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "build_select.jl"), String)
    @test occursin("!(_with_field_part_open(_interval_ms_candidate, order_node)::Bool)", bs_src)
    @test !occursin(r"!_with_field_part_open\(_interval_ms_candidate, order_node\)", bs_src)
    # The leaves infer `Bool`; `SQLField`'s and `FObject`'s recurse into an untyped slot, so they infer `Any` and return
    # what a leaf returns.
    for N in (String, QB.FExpression, QB.JoinedReference, QB.CTEReference, QB.SubqueryObject)
      @test (N, Base.return_types(QB._interval_ms_candidate, (N,))) == (N, Any[Bool])
    end
  end

  # What: `get_or_create`'s lookup values (#1599 layer 6), captured from the insert before any marshalling.
  # Expected: filled key by key into a `Dict{String,Any}`; no `f => real_obj.insert[f]` generator is left.
  # Why: the generator built a `Pair{String,T}` with `T` known only at run time; the trimmed `get_or_create` raised
  #   `MethodError` calling `Pair` (a `UnionAll`) with `(String, Int64)`.
  @testset "get_or_create captures its lookup values at their types (#1599 layer 6)" begin
    ew_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_write.jl"), String)
    @test !occursin("Dict{String,Any}(f => real_obj.insert[f] for f in target_fields)", ew_src)
    @test occursin("target_values[f] = real_obj.insert[f]", ew_src)
    # The hit's lookup filter: each pair built at its value's type, behind the walk.
    QB = PormG.QueryBuilder
    @test isdefined(QB, :_filter_lookup!) && !occursin("    q.filter(f => v)\n  end\n  return q", ew_src)
    isdefined(QB, :_filter_lookup!) &&
      @test isempty(_dynamic_calls(QB._filter_lookup!, (QB.ObjectHandler, String, Any)))
    # The miss's parameters: a variable of the closure's own, not the boxed `parameters` the show branch also assigns.
    @test occursin("miss_params = get_parameter(connection)", ew_src) && occursin("miss_sql = build_insert(miss_params)", ew_src)
    # The lookup's locking and read-back reads: decoded as read, into rows sized as `_row_to_field_keyed_dict` sized them.
    @test occursin("rows = _read_back_rows(settings, sql, params, _FieldRowDecoder(model, connection; sized = true))", ew_src)
    @test !occursin("lock = lock)...) |> Tables.rowtable", ew_src)
    @test fieldtype(QB._FieldRowDecoder, :sized) === Bool
    # PostgreSQL's miss: PormG's own pool decodes its `RETURNING` row as it is read (the trimmed Postgres.jl job stopped
    # at `Tables.rowtable` there); another pool keeps the old read.
    @test occursin("fetch(settings, exec_sql, parameters; _decode = _FieldRowDecoder(model, connection; sized = true))", ew_src)
    @test !occursin("      parameters = get_parameter(connection)\n      insert_sql = build_insert(parameters)\n      return _create_on_miss", ew_src)
  end

  # What: `first()` and `last()` on the untyped read (#1599 layer 6): the step that takes the first of their rows.
  # Expected: `_first_of` takes the untyped read's rows, untyped, without a dynamic call.
  # Why: `_first`'s rows come from `_list_owned`, whose result depends on `show_query`; a trimmed image compiles the
  #   keyword body for any `show_query`, where the rows are untyped, and the trimmed `first()` raised
  #   `MissingCodeError` at `isempty(::Vector{PormGRow})` inside `_first` until the rows were asserted at their type.
  @testset "first() and last() take the untyped rows at their type (#1599 layer 6)" begin
    QB = PormG.QueryBuilder
    @test isdefined(QB, :_first_of)
    isdefined(QB, :_first_of) && @test isempty(_dynamic_calls(QB._first_of, (Any, Val{:row})))
  end

  # What: the full entry's `update` and `delete` (#1599 layer 7, #1694, after the write completed): the walls
  #   each verb hits in a trimmed image, one per commit. `update`'s query copy (`_mutation_copy`).
  # Expected: `update` builds from a shallow copy of the caller's query with `values` emptied and `filter` and
  #   `order` fresh, every other slot shared, made without a dynamic call; no `deepcopy` of the query is left
  #   in `update`.
  # Why: `deepcopy(real_obj)` walks the query's object graph by run-time dispatch; the trimmed full entry's
  #   `update` raised `MissingCodeError` at `deepcopy_internal(::Vector{Int32}, ::IdDict)`. The build writes
  #   nothing into the query (#1624): `update(…; show_query = :dict)` over 231 shapes x engines rendered the
  #   same SQL, parameters and refusals as main's deep copy, twice on one handler (PR body).
  @testset "update and delete run at concrete types in the full entry (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    @test isdefined(QB, :_mutation_copy)
    if isdefined(QB, :_mutation_copy)
      @test isempty(_dynamic_calls(QB._mutation_copy, (QB.SQLObjectQuery,)))
      model = PormG.Models.Model("tsp_mutation_race", raceid = PormG.Models.IDField(), year = PormG.Models.IntegerField(),
                                 name = PormG.Models.CharField())
      q = QB.SQLObjectQuery(model = model)
      QB._values!(q, ("name",))
      QB._filter!(q, ("year" => 2009,))
      QB._order_by!(q, ("-year",))
      c = QB._mutation_copy(q)
      @test isempty(c.values) && length(q.values) == 1
      @test c.filter == q.filter && c.filter !== q.filter && c.order !== q.order
      @test all(f -> getfield(c, f) === getfield(q, f),
                (:model, :connect_key, :insert, :limit, :offset, :group, :having, :list_joins, :distinct, :for_update,
                 :ctes, :custom_join, :alias_join, :projection_kinds))
      @test c.parameters === nothing
    end
    ew_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_write.jl"), String)
    @test !occursin("work = deepcopy(", ew_src) && count("_mutation_copy(real_obj)", ew_src) == 2

    # The filter literal's node (`_literal_value_node`): `update`'s temporal check took `_filter_value_node` on the
    # untyped literal, a run-time dispatch (`MethodError(_filter_value_node, (Int64,))` in the trimmed binary).
    # Each arm is the call or the value `_filter_value_node` gives at that type; anything else, the open arm.
    @test isdefined(QB, :_literal_value_node)
    if isdefined(QB, :_literal_value_node)
      @test isempty(_dynamic_calls(QB._oper_value_check_node, (QB.OperObject,)))
      @test isempty(_dynamic_calls(QB._literal_value_node, (Any,)))
      @test length(_dynamic_calls(QB._literal_value_node_other, (Any,))) == 1
      invoked(f, tt) = [string((s.args[1] isa Core.CodeInstance ? s.args[1].def : s.args[1]).def.name)
                        for s in only(code_typed(f, tt; optimize = true))[1].code if s isa Expr && s.head === :invoke]
      M = PormG.Models
      for T in (String, SubString{String}, Int64, Int32, Float64, Bool, Nothing, Missing, Dates.Date, Dates.DateTime,
                Dates.Time, M.ZonedDateTime, M.Decimals.Decimal, M.UUIDs.UUID)
        @test (T, "_literal_value_node_other" in invoked(QB._literal_value_node, (T,))) == (T, false)
      end
      lits = Any["Monaco", SubString("Monaco", 1, 3), 2009, Int32(6), 1.5, true, nothing, missing, Dates.Date(2009, 5, 24),
                 Dates.DateTime(2009, 5, 24, 14), Dates.Time(14), M.ZonedDateTime(2009, 5, 24, 14, M.TimeZone("UTC")),
                 M.Decimals.Decimal(0, 150, -2), M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), [1, 2], ["a", "b"],
                 ("a", 1), Int16(3), :sym, 2:3]
      for x in lits
        a, b = QB._literal_value_node(x), QB._filter_value_node(x)
        @test typeof(a) === typeof(b) && (a isa QB.SQLText ? a.field == b.field : isequal(a, b) ||
              (a isa AbstractArray && all(i -> (a[i] isa QB.SQLText ? a[i].field == b[i].field : isequal(a[i], b[i])), eachindex(a))) ||
              (a isa Tuple && all(i -> (a[i] isa QB.SQLText ? a[i].field == b[i].field : isequal(a[i], b[i])), 1:length(a))))
      end
    end

    # The SET clause's collector: the instruction holds it in a union slot, and `update`'s SET closure captured it
    # there, so the closure was no concrete type and the `with_scope(instruction; set_reads) do … end` keyword call
    # had no target in the trimmed binary. `_engine_collector` asserts it at the type `get_parameter` makes.
    @test isdefined(QB, :_engine_collector)
    if isdefined(QB, :_engine_collector)
      slot = fieldtype(QB.InstructionObject, :parameters)
      for (E, C) in ((PormG.PormGPostgres, QB.PgParameterizedQuery), (PormG.PormGSQLite, QB.SQLiteParameterizedQuery),
                     (PormG.PormGMySQL, QB.MySQLParameterizedQuery))
        @test only(Base.return_types(QB._engine_collector, (E, slot))) === C
        @test typeof(QB.get_parameter(E === PormG.PormGPostgres ? PormG.ConnectionPool.PostgresConnectionPool("host=x dbname=y") :
                                      E === PormG.PormGSQLite ? PormG.ConnectionPool.SQLiteConnectionPool(":memory:") :
                                      PormG.ConnectionPool.MySQLConnectionPool("host='x'"))) === C
      end
    end
    @test occursin("parameters = _engine_collector(connection, instruction.parameters)", ew_src)
    # The SET value's bind, through `create`'s typed walk (`_bind_written_value!`, pinned arm by arm above): it was
    # `add_parameter!(parameters, formatted_value)` on the untyped formatted value.
    @test occursin("placeholder = _bind_written_value!(parameters, formatted_value)::String", ew_src)
    @test !occursin("add_parameter!(parameters, formatted_value)", ew_src)
    # SQLite's row count, `SELECT changes()`, read as a typed read into a row type named for its column: piped
    # through `Tables.rowtable` its row type was decided at run time (`MethodError(|>, …)` in the binary).
    @test isdefined(QB, :_changes_decoder)
    if isdefined(QB, :_changes_decoder)
      @test QB._changes_decoder() isa QB._RowDecoder{QB._ChangesRow} && fieldnames(QB._ChangesRow) == (Symbol("changes()"),)
      @test fieldtypes(QB._ChangesRow) == (Int64,)
    end
    ef_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "engine_facts.jl"), String)
    @test !occursin("fetch(settings, \"SELECT changes()\") |> Tables.rowtable", ef_src)
    @test occursin("fetch(settings, \"SELECT changes()\"; _decode = _changes_decoder())::Vector{_ChangesRow}", ef_src)

    # `exists()`, which `delete` probes with, counts its rows where the result is concrete (`_RowCounter`): it was
    # `fetch(…) |> Tables.rowtable` and `length` on a row type decided at run time (its projection is `1` or a kept
    # projection). The SQLite extension steps and counts, reading each cell as its materialization does.
    X = Base.get_extension(PormG, :PormGSQLiteExt)
    CP = PormG.ConnectionPool
    @test isdefined(QB, :_RowCounter) && isdefined(X, :_sqlite_count_rows)
    if isdefined(QB, :_RowCounter) && isdefined(X, :_sqlite_count_rows)
      S = PormG.Kernel.Settings
      for P in (Nothing, QB.SQLiteParameterizedQuery, QB.PgParameterizedQuery, QB.MySQLParameterizedQuery)
        @test (P, _dynamic_calls(QB._fetch_row_count, (S, String, P))) == (P, String[])
        @test only(Base.return_types(QB._fetch_row_count, (S, String, P))) === Int
      end
      @test isempty(_dynamic_calls_kw(PormG.backend_execute_rows, (CP.SQLiteConnectionPool, SQLite.DB, String, Nothing, QB._RowCounter)))
      @test isempty(_dynamic_calls(X._sqlite_count_rows, (SQLite.DB, String, Nothing)))
      @test isempty(_dynamic_calls(X._sqlite_count_rows_in, (SQLite.Query{false},)))
      # The same count as the rows the materialization built, or the same refusal.
      db = SQLite.DB()
      SQLite.execute(db, "CREATE TABLE t (a INTEGER, b TEXT, c BLOB)")
      SQLite.execute(db, "INSERT INTO t VALUES (1, 'x', x'0102'), (2, NULL, NULL), (3, 'z', x'')")
      count_of(f) = try; (:ok, f()); catch e; (:err, typeof(e), sprint(showerror, e)); end
      for (sql, params) in (("SELECT 1 FROM t LIMIT 1", nothing), ("SELECT * FROM t", nothing), ("SELECT 1 FROM t WHERE a > 9", nothing),
                            ("SELECT a, c FROM t WHERE a >= ?", Any[2]), ("SELECT DISTINCT b FROM t", nothing), ("SELECT nope FROM t", nothing))
        @test count_of(() -> X._sqlite_count_rows(db, sql, params)) == count_of(() -> length(X._sqlite_execute_materialized(db, sql, params)))
      end
      close(db)
    end
    er_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_read.jl"), String)
    @test occursin("n = _fetch_row_count(settings, sql, instruction.parameters)", er_src)

    # `delete()`'s own transaction lifecycle. Its terminal finalize: the keyword call on the two caught errors (`Any`)
    # had no target, and the trimmed binary raised that `MethodError` in place of the delete's own error.
    # `_finalize_with` on the settings walks the pool as `with_pool` does; its one dynamic call is the open arm.
    S = PormG.Kernel.Settings
    @test hasmethod(CP._finalize_with, (S, Any, Any, Bool, Any, Bool))
    if hasmethod(CP._finalize_with, (S, Any, Any, Bool, Any, Bool))
      @test length(_dynamic_calls(CP._finalize_with, (S, Any, Any, Bool, Any, Bool))) == 1
    end
    del_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "deletion.jl"), String)
    @test occursin("_finalize_with(settings, conn, rollback_error, false, body_error, false)", del_src)
    @test !occursin("finalize_transaction_connection!(settings, conn; rollback_error=rollback_error", del_src)
    # Its statements on the transaction's connection: `with_transaction(…; conn = conn)` with `conn` untyped built an
    # abstract keyword `NamedTuple` (`MethodError(kwcall, …with_transaction…)`); `_with_transaction_with` writes the
    # type out, and `with_transaction`'s `conn` is unspecialized, so the sorter's call into its body is static too.
    @test isdefined(CP, :_with_transaction_with)
    if isdefined(CP, :_with_transaction_with)
      for P in (Nothing, QB.SQLiteParameterizedQuery)
        @test (P, _dynamic_calls(CP._with_transaction_with, (CP.SQLiteConnectionPool, String, Any, Bool, P))) == (P, String[])
        @test length(_dynamic_calls(CP._with_transaction_with, (S, String, Any, Bool, P))) == 1   # the open arm
        # The call, not the method a row names: each row is "<method signature>: <dynamic statement>".
        @test !any(c -> occursin("#with_transaction#", last(split(c, ": "; limit = 2))),
                   _dynamic_calls_deep(CP._with_transaction_with, (CP.SQLiteConnectionPool, String, Any, Bool, P); depth = 2))
      end
    end
    @test !occursin(r"with_transaction\((settings|connection), [^)\n]*conn=conn", del_src)
    # One more since #1599 layer 7 (the key read's, with its decoder), and one more since #1694 (the self-referential
    # children's read, with the same decoder).
    @test count("_with_transaction_with(", del_src) == 12
    # The deletions run in the transaction's context: `with_tx_context(settings.connections, conn) do … end` took the
    # pool at its union type and a closure capturing the untyped `conn`, so neither was concrete. The pool is walked
    # (`_with_tx_context_on`, one dynamic call: its open arm), and `conn` goes in a typed box.
    @test isdefined(CP, :_with_tx_context_on)
    if isdefined(CP, :_with_tx_context_on)
      g = () -> 1
      @test length(_dynamic_calls(CP._with_tx_context_on, (typeof(g), S, Any))) == 1
    end
    @test occursin("conn_box = Base.RefValue{Any}(conn)", del_src) && occursin("_with_tx_context_on(settings, conn) do", del_src)
    @test occursin("run_deletions = function(@nospecialize(conn),)", del_src)
    @test !occursin("with_tx_context(settings.connections, conn) do", del_src)
    # The planner's copies of the query: four `deepcopy`s, each a walk of the query's object graph by run-time
    # dispatch (the trimmed binary stopped in one). The build writes nothing into a query (#1624): three are a read
    # terminal's shallow copy, whose `values` the planner replaces, and the entry predicate's is `update`'s copy.
    @test !occursin("deepcopy(", del_src)
    # (Four calls since #1599 layer 7: `prepare_related_query` copies a parent's query in its `ObjectHandler` arm, and
    # its open arm makes the same call.)
    @test count("_terminal_copy(", del_src) == 4 && occursin("work = _mutation_copy(key[:objct].object)", del_src)
    # `plan` and `run_plan` are defined before `run_deletions`, which calls them: defined after, each was captured
    # in a `Core.Box` and called by run-time dispatch on the boxed value.
    @test findfirst("    plan = function", del_src).start < findfirst("    run_deletions = function", del_src).start
    @test findfirst("    run_plan = function", del_src).start < findfirst("    run_deletions = function", del_src).start
    # A collected entry at the collector's element type, its two slots assigned: built from pairs it was a
    # `Dict{Symbol,Any}` that `push!` converted value by value, and the typed `Pair` constructor's stores had no target.
    @test isdefined(QB, :_collector_entry)
    if isdefined(QB, :_collector_entry)
      @test isempty(_dynamic_calls(QB._collector_entry, (String, QB.ObjectHandler)))
      e = QB._collector_entry("raceid", QB.ObjectHandler(object = QB.SQLObjectQuery(model = PormG.Models.Model("tsp_entry", raceid = PormG.Models.IDField()))))
      @test e isa Dict{Symbol, Union{String, PormG.SQLObjectHandler}} && Set(keys(e)) == Set([:key, :objct]) && e[:key] == "raceid"
    end
    @test !occursin(r"Dict\(:key => \w", del_src) && !occursin(r"SQLObjectHandler}}\(\s*:key => \w", del_src)   # code, not the comment
    # The seed model at its concrete type: read out of the collector's `Dict{PormGModel,…}` it is abstract.
    @test occursin("find_related_objects!(collector, model::Models.ModelType, copy(keys))", del_src)
    # The planner's sets queried at the model's concrete type: `collect_fast_deletes!` and `topological_sort`, whose
    # self-recursive inner closure was also boxed, so `in(::ModelType, ::Set{PormGModel})` had no target. The visit
    # is `_topological_visit!`; the sort keeps its abstract signature (test_alignment_sqlite.jl pins it).
    G = PormG.PormGModel
    MT = PormG.Models.ModelType
    @test isdefined(QB, :_topological_visit!)
    if isdefined(QB, :_topological_visit!)
      @test isempty(_dynamic_calls(QB.topological_sort, (Dict{G, Set{G}},)))
      @test isempty(_dynamic_calls(QB._topological_visit!, (MT, Dict{G, Set{G}}, Vector{G}, Set{G}, Set{G}, Vector{G})))
      @test isempty(_dynamic_calls(QB.collect_fast_deletes!, (QB.DeletionCollector{Union{String, PormG.SQLObjectHandler}},)))
      # The same order, or the same refusal, as the closure it replaces, over acyclic and cyclic graphs.
      old_topo(dependencies) = begin
        result = Vector{G}(); temp_mark = Set{G}(); perm_mark = Set{G}(); path = Vector{G}()
        function visit(node)
          if node in temp_mark
            cycle = G[path[findfirst(m -> m === node, path):end]..., node]
            throw(PormG.QueryBuildError(QB._delete_cycle_message(cycle)))
          end
          if !(node in perm_mark)
            push!(temp_mark, node); push!(path, node)
            for dep in get(dependencies, node, Set{G}()); visit(dep); end
            pop!(path); delete!(temp_mark, node); push!(perm_mark, node); push!(result, node)
          end
        end
        for node in keys(dependencies); node in perm_mark || visit(node); end
        reverse(result)
      end
      mk(n) = PormG.Models.Model("tsp_topo_$(n)", id = PormG.Models.IDField())
      A, B, C, D, E = mk("a"), mk("b"), mk("c"), mk("d"), mk("e")
      graphs = [Dict{G, Set{G}}(), Dict{G, Set{G}}(A => Set{G}()), Dict{G, Set{G}}(A => Set{G}([B]), B => Set{G}([C])),
                Dict{G, Set{G}}(A => Set{G}([B, C]), B => Set{G}([D]), C => Set{G}([D]), E => Set{G}([A])),
                Dict{G, Set{G}}(A => Set{G}([B]), B => Set{G}([A])), Dict{G, Set{G}}(A => Set{G}([A])),
                Dict{G, Set{G}}(A => Set{G}([B]), B => Set{G}([C]), C => Set{G}([A]), D => Set{G}([A]))]
      topo_outcome(f) = try; (:ok, f()); catch e; (:err, typeof(e), sprint(showerror, e)); end
      for g in graphs
        @test topo_outcome(() -> QB.topological_sort(g)) == topo_outcome(() -> old_topo(g))
      end
    end
    # `run_plan` takes its connection unspecialized, as `run_deletions` does: specialized, each call with the untyped
    # connection dispatched at run time.
    @test occursin("run_plan = function(@nospecialize(conn), collector::DeletionCollector, root_locked::Bool)", del_src)
    # The statement functions take the connection unspecialized, and `run_plan` hands each its model at its type.
    for f in (QB.delete_objects, QB.update_field, QB.lock_objects, QB._require_statement_conn)
      @test (f, only(methods(f)).nospecialize != 0) == (f, true)
    end
    @test occursin("delete_objects(connection, fast_model::Models.ModelType,", del_src) &&
          occursin("update_field(connection, affected_model::Models.ModelType,", del_src) &&
          occursin("delete_objects(connection, model_to_delete::Models.ModelType,", del_src) &&
          occursin("lock_model = m::Models.ModelType", del_src) && occursin("lock_objects(connection, lock_model,", del_src)
    # The entry predicate's alias in a typed holder: reassigned in the closure it was a `Core.Box`, and the tuple
    # `_collector_predicate` returns was untyped (the DELETE text built from it had no target).
    @test only(Base.return_types(QB._collector_predicate, (CP.SQLiteConnectionPool, Vector{Dict{Symbol, Union{String, PormG.SQLObjectHandler}}}))) ==
          Tuple{String, QB.SQLiteParameterizedQuery, String}
    # The affected-row count takes the statement's result unspecialized, and SQLite's `SELECT changes();` is read at
    # its row type; any other result (a stand-in pool's) takes the old read, in the open arm.
    @test all(m -> m.nospecialize != 0, methods(QB._affected_row_count)) && isdefined(QB, :_affected_rows_other)
    if isdefined(QB, :_affected_rows_other)
      @test isempty(_dynamic_calls(QB._affected_row_count, (CP.SQLiteConnectionPool, Any, Any)))
      @test QB._affected_rows_other([(var"changes()" = 3,)]) == 3
    end
    # The count `delete()` returns, stored at its type (`_count_deleted!`): the sum read out of the `Integer`-valued
    # `Dict` was untyped, and its store had no target.
    @test isdefined(QB, :_count_deleted!)
    if isdefined(QB, :_count_deleted!)
      @test isempty(_dynamic_calls(QB._count_deleted!, (Dict{String, Integer}, String, Int)))
      c = Dict{String, Integer}()
      QB._count_deleted!(c, "race", 2); QB._count_deleted!(c, "race", 3); QB._count_deleted!(c, "result", 0)
      @test c == Dict{String, Integer}("race" => 5, "result" => 0) && all(v -> v isa Int, values(c))
    end
    @test !occursin("deleted_counter[model.name] = get(deleted_counter, model.name, 0) +", del_src)
    # The sorted deletes look each model up at its type, with a typed empty default.
    @test occursin("get(collector.objects, model_to_delete::Models.ModelType, Dict{Symbol, Union{String, SQLObjectHandler}}[])", del_src)
    # The total `delete()` returns, an `Int` as `sum` gave it, `0` for none.
    @test isdefined(QB, :_deleted_total)
    if isdefined(QB, :_deleted_total)
      @test isempty(_dynamic_calls(QB._deleted_total, (Dict{String, Integer},)))
      for d in (Dict{String, Integer}(), Dict{String, Integer}("race" => 1), Dict{String, Integer}("race" => 2, "result" => 5))
        @test QB._deleted_total(d) === sum(values(d))
      end
    end
  end

  # What: the timestamp parser for the text PormG writes (`Models.parse_zoned_timestamp`), on the write path's
  #   validation (`validate_timezone`) and the SQLite read parser (`Dialect._parse_sqlite_timestamp`).
  # Expected: the canonical text is read without a dynamic call, and both sites call the parser; any other text
  #   takes TimeZones' parse, in the open arm (test_timestamp_parser.jl holds the equivalence).
  # Why: `ZonedDateTime(text, DateFormat)` is TimeZones' parser, which a trimmed image has no code for
  #   (`tryparsenext_internal(ZonedDateTime, …)`, an unresolved invoke). Measured on #1694's update/delete head:
  #   with an auto-filled `DateTimeField` in the fixture, the binary's create stopped there validating the
  #   timestamp it had filled, before its INSERT.
  @testset "a timestamp in PormG's text is parsed at concrete types (#1599 layer 7, #1694)" begin
    M = PormG.Models
    @test isdefined(M, :parse_zoned_timestamp) && isdefined(M, :_canonical_zoned)
    if isdefined(M, :_canonical_zoned)
      @test isempty(_dynamic_calls(M._canonical_zoned, (String,)))
      for T in (String, SubString{String})
        @test (T, _dynamic_calls(M.parse_zoned_timestamp, (T,))) == (T, String[])
        @test only(Base.return_types(M.parse_zoned_timestamp, (T,))) === M.ZonedDateTime
      end
    end
    m_src = read(joinpath(pkgdir(PormG), "src", "Models.jl"), String)
    d_src = read(joinpath(pkgdir(PormG), "src", "Dialect.jl"), String)
    @test occursin("zdt = parse_zoned_timestamp(normalize_sqlite_datetime_string(s))", m_src)
    @test occursin("return parse_zoned_timestamp(normalized)", d_src)
    @test !occursin("ZonedDateTime(normalized, dateformat", d_src)
    # and the text a timestamp is written as, by hand for years 0-9999: `Dates.format` padded a field through code a
    # trimmed image had no code for (`repeat(::Char, ::Int)` from `rpad`), so a filled timestamp with a field that
    # needed a leading zero raised `MissingCodeError`.
    @test isdefined(M, :_canonicalize_datetime_other)
    if isdefined(M, :_canonicalize_datetime_other)
      @test isempty(_dynamic_calls(M._canonicalize_datetime_utc, (M.ZonedDateTime,)))
      @test isempty(_dynamic_calls(M._print_zero_padded, (Base.IOBuffer, Int, Int)))
    end
    # The reflection above passes on `Dates.format` too (its wall shows only in a trimmed image), so the body is
    # pinned by its text: the fields written by hand, `Dates.format` only in the open arm.
    @test occursin("function _canonicalize_datetime_utc(value::ZonedDateTime)::String\n  dt = value.utc_datetime", m_src)
    @test occursin("_print_zero_padded(io, millisecond(dt), 3)", m_src)
    # and a non-UTC offset's zone name is built from bytes, without `print_to_string`. (Followed deeper, the
    # parser reaches two calls inside `print_to_string`, from the error messages `Dates.validargs` and TimeZones'
    # `FixedTimeZone` constructor build: upstream code, on their refusal branches.)
    if isdefined(M, :_utc_offset_name)
      @test isempty(_dynamic_calls(M._utc_offset_name, (Base.CodeUnits{UInt8, String},)))
      @test M._utc_offset_name(codeunits("2009-05-24T14:00:00.000-03:30")) == "UTC-03:30"
    end
  end

  # What: `bulk_insert`'s path in the full fixture entry (#1599 layer 7, #1694), one assertion group per wall the
  #   trimmed binary stopped at: the frame built at the source's type, the fill column built and stored at its type,
  #   the absent-column timestamp fill, the field metadata and source columns collected at declared types, each cell
  #   read, validated, formatted and bound through a typed walk or one compiled method, the collector, the columns=
  #   argument and the RETURNING clause unboxed, and the chunk counts summed at their type.
  # Expected: each helper exists; each walk makes no dynamic call outside its one open arm; the unspecialized
  #   arguments carry their `nospecialize` bit; the source reads the typed forms and none of the old ones; and
  #   `_bulk_insert_frame` boxes none of `columns`, `parameters`, `returning_sql`.
  # Why: each was a call with no compiled target in a trimmed image, and the binary stopped there (21 walls, the
  #   PR's table). Under the JIT each was a dynamic dispatch per cell or per call. Red on the base (`d51cfe5a1`):
  #   the helpers are missing and the source has every old form.
  @testset "bulk_insert runs at concrete types in the full entry (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    eb_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_bulk.jl"), String)
    # The insert body alone: `_bulk_update` keeps its own `columns` accumulator and `results` sum, untouched here.
    bi_at = findfirst("function _bulk_insert_frame(", eb_src)
    bi_src = bi_at === nothing ? "" : eb_src[first(bi_at):first(something(findnext("\nend\n", eb_src, last(bi_at)), bi_at))]
    @test !isempty(bi_src)
    nospec(m::Method, i::Int) = (m.nospecialize >> (i - 1)) & 1 == 1
    only_method(f, tt) = only(methods(f, tt))

    # The frame at the source's type: `bulk_insert`, `_bulk_frame` and `_refuse_non_table` specialize on the
    # source; `_bulk_insert_frame`, the body after the frame, takes it unspecialized (compiled once).
    @test !nospec(only_method(QB.bulk_insert, (QB.SQLObjectHandler, Any)), 2)
    @test !nospec(only_method(QB._bulk_frame, (Any, AbstractString)), 1)
    @test !nospec(only_method(QB._refuse_non_table, (Any, AbstractString)), 1)
    @test isdefined(QB, :_bulk_insert_frame)
    if isdefined(QB, :_bulk_insert_frame)
      m = only(methods(QB._bulk_insert_frame))
      @test nospec(m, 5) && count(i -> nospec(m, i), 1:(m.nargs - 1)) == 1   # `src`, the fifth argument, alone
      # Inference shares the body across table types too: without it, each new table type re-inferred the body
      # once per pool type (the PR's JIT measurement).
      @test m.nospecializeinfer
    end
    # The fixture's row type, and one with more column types than inference splits (six): neither makes a dynamic
    # Tables.jl call, a dynamic `length` or a dynamic store.
    for NT in (Vector{NamedTuple{(:year, :name), Tuple{Int64, String}}},
               Vector{NamedTuple{(:year, :name, :date, :points, :sprint, :round),
                                 Tuple{Int64, String, Dates.Date, Float64, Bool, Int32}}})
      @test (NT, filter(s -> occursin("Tables", s) || occursin("length", s) || occursin("setindex!", s),
                        _dynamic_calls(QB._bulk_frame, (NT, String)))) == (NT, String[])
    end
    @test occursin("_store_bulk_column!(columns, key, column)", eb_src) && occursin("lengths[key] = _bulk_length(column)", eb_src)
    @test !occursin("row_count = length(columns[names[1]])", eb_src)

    # The fill: the zone through `_now_in`, the formatter through `apply_formatter`, the closure's value
    # unspecialized, the column built (`_fill_bulk_column`) and stored (`_store_bulk_column!`) at its type.
    @test !occursin("TimeZone(settings.time_zone)", eb_src)
    @test count("Models.apply_formatter(f_meta.formatter, _now_in(settings.time_zone))", eb_src) == 2
    @test occursin("function inject_fill_column!(field::String, f_meta, @nospecialize(fill_value), per_row::Bool)", eb_src)
    @test occursin("_fill_bulk_column(fill_value, df.row_count))::AbstractVector", eb_src)
    @test nospec(only(methods(QB._add_bulk_column!)), 3)
    walks = ((:_fill_bulk_column, :_fill_bulk_column_other, (Any, Int)),
             (:_store_bulk_column!, nothing, (Dict{String, AbstractVector}, String, AbstractVector)),
             (:_bulk_cell, :_bulk_cell_other, (AbstractVector, Int)),
             (:_bulk_length, :_bulk_length_other, (AbstractVector,)),
             (:_bulk_count_total, :_bulk_count_total_other, (Vector{Any},)))
    for (name, other, tt) in walks
      @test (name, isdefined(QB, name)) == (name, true)
      isdefined(QB, name) || continue
      f = getglobal(QB, name)
      if other === nothing
        # The store's open arm is the store itself, written inline: one dynamic `setindex!`.
        @test length(_dynamic_calls(f, tt)) == 1
      else
        @test (name, _dynamic_calls(f, tt)) == (name, String[])
        o = getglobal(QB, other)
        ott = other === :_bulk_count_total_other ? (Vector{Any}, Int, Int) : tt
        # The open arm: the one call the walk leaves dynamic (and, for `_bulk_length_other`, the conversion its
        # `::Int` return type adds to that call's result).
        @test length(filter(s -> !occursin("convert(", s), _dynamic_calls(o, ott))) == 1
      end
    end
    if isdefined(QB, :_bulk_cell)
      invoked(f, tt) = [string((s.args[1] isa Core.CodeInstance ? s.args[1].def : s.args[1]).def.name)
                        for s in only(code_typed(f, tt; optimize = true))[1].code if s isa Expr && s.head === :invoke]
      for T in (Int64, String, Float64, Bool, Dates.Date, Union{Missing, Int64}, Union{Missing, String})
        @test (T, "_bulk_cell_other" in invoked(QB._bulk_cell, (Vector{T}, Int))) == (T, false)
      end
    end

    # The metadata and the source columns at declared types; the formatted cells as `Any`.
    @test occursin("metas = Models.AnyField[_validate_field_name(model, field, \"bulk_insert\"", bi_src)
    @test occursin("sources = AbstractVector[_bulk_column(df, mapping[field]) for field in fields_df]", bi_src)
    @test occursin("cells = Any[_format_bulk_cell(model, field, metas[j], _bulk_cell(sources[j], index)", bi_src)
    @test !occursin("sources[j][index]", bi_src)

    # Validate, format and bind: one compiled method each, through `create`'s walks.
    vm = only(methods(QB._validate_bulk_cell))
    @test nospec(vm, 4) && occursin("_validate_field_value_at(model, String(field), f_meta, value, String(op))", eb_src)
    @test nospec(only(methods(QB._format_bulk_cell)), 4)
    @test occursin("push!(placeholders, _bind_written_value!(parameters, cell)::String)", bi_src)
    @test !occursin("add_parameter!(parameters, cell)", bi_src)

    # No box: the chunk accumulator is not `columns`, the chunk statement takes its collector as an argument, and
    # the RETURNING clause is assigned once.
    @test count("chunk_columns = new_columns()", bi_src) == 2 && !occursin(r"\n\s+columns = new_columns\(\)", bi_src)
    @test occursin("run_chunk(params) = _bulk_insert(", bi_src) && !occursin("run_chunk()", bi_src)
    @test occursin("returning_sql = if _returning !== nothing && _insert_returns_rows(connection)", bi_src)
    isdefined(Main, :core_boxed_vars) || include(joinpath(@__DIR__, "helper_core_box.jl"))
    if isdefined(QB, :_bulk_insert_frame)
      boxed = Symbol[]
      Base.visit(Core.methodtable) do m
        m isa Method || return
        endswith(string(m.file), joinpath("querybuilder", "execution_bulk.jl")) || return
        occursin("_bulk_insert_frame", string(m.name)) || return
        append!(boxed, Base.invokelatest(getglobal(Main, :core_boxed_vars), Base.uncompressed_ast(m)))
      end
      @test isempty(intersect(boxed, [:columns, :parameters, :returning_sql]))
    end

    # The total at its type, through `_bulk_result_at` since #1614 (the call on the untyped total was dynamic).
    @test count("_bulk_result_at(_bulk_count_total(results)", bi_src) == 2 && !occursin("sum(results", bi_src)
  end

  # What: the single-row write's path on MySQL and on PostgreSQL through Postgres.jl (#1599 layer 7, #1614), one group
  #   per wall the server entries' trimmed binaries stopped at: the read-back query takes the INSERT's result
  #   unspecialized, the MySQL read-back binds its key through `create`'s walk, PostgreSQL's RETURNING row and both
  #   drivers' read-backs are decoded at each cell's type, both drivers' results are counted at their type, and
  #   delete's lock planning reads its models at their type.
  # Expected: the `nospecialize` bit on every engine's `_inserted_row_query`; the typed forms in the source and none of
  #   the old ones; no dynamic call in the extensions' decode and count methods or in `_models_to_lock`.
  # Why: each was a call with no compiled target in a trimmed image, and the server binaries stopped there (the
  #   PR's table). Red on the base (#1814's head): the methods are missing, the source has the old forms, and
  #   `_models_to_lock` calls its comprehension's filter on an abstract model.
  @testset "the single-row write runs at concrete types on MySQL and Postgres.jl (#1599 layer 7, #1614)" begin
    QB = PormG.QueryBuilder
    for m in methods(QB._inserted_row_query)
      @test (m.sig, (m.nospecialize >> 3) & 1) == (m.sig, 1)   # `result`, the fourth argument
    end
    ef_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "engine_facts.jl"), String)
    @test occursin("marker = _bind_written_value!(params, value)::String", ef_src)
    @test !occursin("marker = add_parameter!(params, value)", ef_src)
    ew_src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_write.jl"), String)
    @test occursin("returned = fetch(settings, exec_sql, parameters; _decode = _FieldRowDecoder(model, connection))::Vector{Dict{Symbol, Any}}", ew_src)
    # The old read stays for a pool that is not PormG's own (a test double), behind the type check, and nowhere else.
    @test occursin("if settings.connections isa PostgresConnectionPool", ew_src)
    @test count("Tables.rowtable(result) |> Base.first, model, connection), model)", ew_src) == 1
    @test findfirst("if settings.connections isa PostgresConnectionPool", ew_src) <
          findfirst("Tables.rowtable(result) |> Base.first, model, connection), model)", ew_src)

    PG = Base.get_extension(PormG, :PormGPostgresExt)
    MY = Base.get_extension(PormG, :PormGMySQLExt)
    model = PormG.Models.Model("tsp_srv_race", raceid = PormG.Models.IDField(), year = PormG.Models.IntegerField())
    for (label, pool, R) in (("Postgres.jl", PormG.ConnectionPool.PostgresConnectionPool("host=x dbname=y"; driver = :postgres),
                              PG === nothing ? Nothing : PG.Postgres.Result),
                             ("MySQL", PormG.ConnectionPool.MySQLConnectionPool("host='x'"), MY === nothing ? Nothing : MY.MySQLResult))
      @test (label, R !== Nothing) == (label, true)
      R === Nothing && continue
      dec = QB._FieldRowDecoder(model, pool)
      # The extension's own method, not the generic call through `Tables.rowtable`.
      @test (label, which(dec, (R,)).module) == (label, label == "MySQL" ? MY : PG)
      @test (label, _dynamic_calls(dec, (R,))) == (label, String[])
      @test (label, which(QB._RowCounter(), (R,)).module) == (label, label == "MySQL" ? MY : PG)
      @test (label, _dynamic_calls(QB._RowCounter(), (R,))) == (label, String[])
    end
    @test isempty(_dynamic_calls(QB._models_to_lock, (QB.DeletionCollector{Union{String, PormG.SQLObjectHandler}},)))
  end

  # What: the render sites that read `SQLField.field` at its `FieldPart` union (#1599 layer 5, #1780's group 6):
  #   the walk with an open arm (`_with_field_part_open`), its `string` (`_field_part_text`), the transform
  #   formatter reader (`_part_formatter`), and the readers that now ask their question at the member's type
  #   or read the field once.
  # Expected: the open walk has `with_field_part`'s ten arms and an open arm that makes the call (where
  #   `with_field_part` raises), with no dynamic call itself; `_field_part_text` is `string`; `_part_formatter`
  #   is the slot read; the converted readers make no dynamic call (16 of them), and the ORDER BY render, the
  #   interval-side check and the WHERE render no longer dispatch the calls they walked.
  # Why: each was a call on the slot's union, a run-time dispatch that a trimmed image cannot make: 153
  #   verifier rows on the read-only entry at PR 1's head. Measured on PR 1's head 3b6cd6062: all 16 readers
  #   below make the dynamic calls this pin forbids, and the four helpers are missing (24 failures).
  @testset "SQLField.field is read at its member type at the render sites (#1599 layer 5, group 6)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    has(n) = isdefined(QB, n)
    for n in (:_with_field_part_open, :_with_field_part_other, :_field_part_text, :_part_formatter)
      @test has(n)
    end
    if has(:_with_field_part_open)
      members = Set{Any}(Base.uniontypes(QB.FieldPartNode))
      src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "types.jl"), String)
      start = findfirst("function _with_field_part_open(", src)[1]
      body = join(filter(l -> !startswith(lstrip(l), "#"),
                         split(src[start:findnext("\nend", src, start)[end]], '\n')), '\n')
      for T in members
        @test occursin("part isa $(nameof(T)) && return f(part, args...)", body)
      end
      @test count("part isa ", body) == length(members)
      @test occursin("return _with_field_part_other(f, part, args...)", body)
      @test QB._with_field_part_open(typeof, "raceid") === String
      @test QB._with_field_part_open((p, x) -> (typeof(p), x), QB.SQLText(1), 7) === (QB.SQLText, 7)
      # Where `with_field_part` refuses, the open arm makes the call.
      @test_throws MethodError QB.with_field_part(typeof, QB.SQLField("raceid"))
      @test QB._with_field_part_open(typeof, QB.SQLField("raceid")) === QB.SQLField
      @test isempty(_dynamic_calls(QB._with_field_part_open, (typeof(_tsp_visit), Any)))
      @test length(_dynamic_calls(QB._with_field_part_other, (typeof(string), Any))) == 1
      for x in ("raceid", QB.SQLText(1), QB.SQLText("a"), PormG.F("points") + 1, QB.SQLField("raceid"))
        @test QB._field_part_text(x) == string(x)
      end
      @test QB._part_formatter("raceid") === nothing
      fo = QB.FObject(function_name = "EXTRACT", column = "date", formatter = PormG.Models.format_year_sql)
      @test QB._part_formatter(fo) === PormG.Models.format_year_sql
    end
    S = QB.SQLField
    P = PormG.ConnectionPool.SQLiteConnectionPool
    for tt in (Tuple{typeof(QB._group_role), S, I}, Tuple{typeof(QB._grouped_expressions), I},
               Tuple{typeof(QB._query_select), IOBuffer, Vector{S}, P}, Tuple{typeof(QB._describe_projection), S},
               Tuple{typeof(QB._projects_column), S, String}, Tuple{typeof(QB._is_wildcard_projection), S},
               Tuple{typeof(QB._is_labelled_term), S}, Tuple{typeof(QB._is_null_propagating_label), S},
               Tuple{typeof(QB._orders_as_sqlite_interval), S, I}, Tuple{typeof(QB._projected_interval_source), String, I},
               Tuple{typeof(QB._projected_unordered_interval), String, I},
               Tuple{typeof(QB._infer_kind), S, I, QB._AllKinds}, Tuple{typeof(QB._expression_formatter), S, I},
               Tuple{typeof(QB._having_alias_formatter), QB.MemoKey, I},
               Tuple{typeof(QB._guard_window_alias_predicate), S, String, I},
               Tuple{typeof(QB._collect_projected_paths!), Vector{String}, S, Int})
      calls = _named_dynamic_calls(tt, ("",); depth = 0)
      @test isempty(calls)
      isempty(calls) || @info "dynamic calls at a group-6 site" tt calls
    end
    @test isempty(_named_dynamic_calls(Tuple{typeof(QB._render_order_terms), QB.OrderTermView, QB.SQLObjectQuery, I},
                                       ("_resolved_contains_agg", "_resolved_window", "_interval_ms_candidate",
                                        "_expression_kind", "_render_order_term(", "QueryBuilder.string(")))
    @test isempty(_named_dynamic_calls(Tuple{typeof(QB._is_interval_operand_side), QB.OperObject, I}, ("_expression_kind",)))
    @test count(c -> occursin(":formatter", c),
                _named_dynamic_calls(Tuple{typeof(QB._render_filter_oper), QB.OperObject, I}, (":formatter",); depth = 0)) <= 1
    # `_filter_path_label` reads the field once (its dynamic call was inlined into its callers).
    fsrc = read(joinpath(pkgdir(PormG), "src", "querybuilder", "filter_nodes.jl"), String)
    @test !occursin("isa(col.field, String) && return col.field", fsrc)
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
    # The CTE column store (#1599 layer 5) has the same arms.
    for fname in ("_store_projection_kind!", "_store_cte_kind!")
      start = findfirst("function $(fname)(", src)[1]
      body = join(filter(l -> !startswith(lstrip(l), "#"),
                         split(src[start:findnext("\nend", src, start)[end]], '\n')), '\n')
      for T in concrete
        @test (fname, occursin("kind isa $(nameof(T)) && return (d[name] = kind; nothing)", body)) == (fname, true)
      end
      @test (fname, count("kind isa ", body)) == (fname, length(concrete))
    end
    # Every arm names a kind the module can see, statically: an arm naming an unimported kind is a global
    # read typed `Any`, so its `isa` and store dispatch at run time (and the name would throw if reached).
    @test isempty(_dynamic_calls(QB._store_projection_kind!, (QB.InstructionObject, Symbol, Any)))
    @test filter(x -> !occursin("_store_cte_kind_other!", x), _dynamic_calls(QB._store_cte_kind!, (Dict{String,PormG.CanonicalType}, String, Any))) == String[]
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

  # What: `Models.fk_target_column`, the referenced column of a `ForeignKey` / `OneToOneField`, which the
  #   join walk (`_forward_fk_hop`), the DDL renderer and the migration planner read.
  # Expected: no dynamic call for either field type; the answers are the ones before: the target field's
  #   `db_column` when the target model declares one, its name otherwise, `"id"` when `pk_field` is unset,
  #   and the `pk_field` text verbatim for a `String` target or a name the target model does not have.
  # Why: the target was narrowed only to the abstract `PormGModel`, so `haskey`, `getindex` and
  #   `field_db_column` on its `fields` dispatched at run time: 12 verifier rows on the read-only entry
  #   (6 per FK type) once the join walk became static, each a `MethodError` in a trimmed binary whose
  #   query crosses a foreign key. Reading the target at `ModelType` closes them.
  @testset "fk_target_column reads the target model at its concrete type (#1599, layer 3)" begin
    M = PormG.Models
    # Followed into `_fk_target_lookup`, where the work is; the open arm for another `PormGModel` is skipped,
    # its one dynamic call is the point. That arm is covered by equivalence (the same lookup), not by a model
    # type defined here, which would change inference for the other pins in this process.
    for T in (M.sForeignKey, M.sOneToOneField)
      @test isempty(_dynamic_calls_deep(M.fk_target_column, (T,); skip = (M._fk_target_column_other,)))
    end
    circuit = M.Model("tsp_fk_circuit", circuitid = M.IDField(), ref = M.CharField(db_column = "circuit_ref"),
                      name = M.CharField())
    @test M.fk_target_column(M.ForeignKey(circuit; pk_field = "ref")) == "circuit_ref"
    @test M.fk_target_column(M.ForeignKey(circuit; pk_field = :name)) == "name"
    @test M.fk_target_column(M.OneToOneField(circuit; pk_field = "ref")) == "circuit_ref"
    @test M.fk_target_column(M.ForeignKey(circuit; pk_field = "missing")) == "missing"
    @test M.fk_target_column(M.ForeignKey(circuit)) == "id"
    @test M.fk_target_column(M.ForeignKey("Circuit"; pk_field = "circuitref")) == "circuitref"
    @test M.fk_target_column(M.OneToOneField("Circuit")) == "id"
    unresolved = M.ForeignKey("Circuit"; pk_field = "circuitref")
    unresolved.to = nothing
    @test M.fk_target_column(unresolved) == "circuitref"
  end

  # What: `Models.apply_formatter(f, value, ranged)`, the call through a field's `formatter::Function` slot
  #   (and the date-part formatters a filter transform takes), walked over PormG's own formatters.
  # Expected: for a value of a concrete type, no dynamic call in either method; every formatter a field
  #   constructor stores, and every member of `FIELD_FORMATTERS`, `PERIOD_FORMATTERS` and `format_yyyy_mm`,
  #   has an arm; the open arm is the old call; every answer — value, type, or exception type and message —
  #   is the direct call's (`f(v)`, or `unranged_formatter(f)(v)` when `ranged` is false).
  # Why: `field.formatter(value)` dispatches at run time whatever the value, because the slot is typed
  #   `Function`; in a trimmed binary that is a `MethodError` wherever nothing was compiled for the target.
  #   The filter path's `_format_filter_value` is such a call (the layer-5 session's finding). With the
  #   function known, what stays dynamic is the value, `OperObject.values`' untyped literal (#1754, round
  #   11's decision), which a typed literal closes. A formatter a field stores that has no arm here would
  #   send every value of that field through the open arm.
  @testset "a field formatter is called at its concrete type through apply_formatter (#1599, layer 3)" begin
    M = PormG.Models
    # 1. Static for a concrete value, through both methods (the 2-argument one defaults `ranged`).
    for T in (Int64, Float64, Bool, String, SubString{String}, Dates.Date, Dates.DateTime,
              M.ZonedDateTime, M.Decimals.Decimal, M.UUIDs.UUID, Nothing, Missing, Vector{Int64})
      @test isempty(_dynamic_calls(M.apply_formatter, (Function, T, Bool)))
    end
    # With an untyped value, each arm is a call on the value at a known function: no call on `f` itself
    # but the `ArrayFormatter` arm's (a call on the struct, whose one method takes the value untyped).
    # The open arm takes the value `@nospecialize` (#1599 layer 3), so it is an `:invoke`, not a call.
    # That residue is the literal's, not the formatter's.
    on_any = [replace(c, r"^\d+: " => "") for c in _dynamic_calls(M.apply_formatter, (Function, Any, Bool))]
    @test count(c -> startswith(c, "PormG.Models._apply_formatter_other("), on_any) == 0
    @test count(c -> occursin(r"^\(%\d+\)\(_3\)$", c), on_any) == 1
    @test all(c -> occursin(r"^(PormG\.Models\.(format_\w+|identity)\(|Core\.kwcall\(%\d+, PormG\.Models\.format_\w+, _3\)$|\(%\d+\)\(_3\)$)", c), on_any)
    # 2. The open arm is exactly the call a user's formatter made before: one dynamic call per branch.
    @test length(_dynamic_calls(M._apply_formatter_other, (Function, Any, Bool))) == 2

    # 3. Every formatter a field type stores is a member, and every member has an arm.
    target = M.Model("tsp_fmt_circuit", circuitid = M.IDField(), name = M.CharField())
    stored = Any[]
    for T in Base.uniontypes(M.AnyField)
      ctor = getfield(M, Symbol(string(nameof(T))[2:end]))
      fld = T in (M.sForeignKey, M.sOneToOneField, M.sManyToManyField) ? ctor(target) :
            T === M.sArrayField ? ctor(M.IntegerField()) : ctor()
      push!(stored, fld.formatter)
    end
    push!(stored, M.GenericIPAddressField(unpack_ipv4 = true).formatter)
    for E in (M.CharField, M.TextField, M.IntegerField, M.BigIntegerField, M.FloatField, M.BooleanField,
              M.DateField, M.DateTimeField, M.UUIDField)
      push!(stored, M.ArrayField(E()).formatter.base.formatter)
    end
    for f in stored
      @test f isa M.ArrayFormatter || f in M.FIELD_FORMATTERS
    end
    # An arm per member: the walk names each one (`isa typeof(member)`), read from its lowered code.
    named = Set{Symbol}()
    # Lowered code holds a global as a statement of its own (or, in older lowerings, as a call's argument).
    for stmt in only(code_lowered(M.apply_formatter, (Function, Any, Bool))).code,
        a in (stmt isa Expr ? stmt.args : (stmt,))
      a isa GlobalRef && a.mod === M && push!(named, a.name)
    end
    for f in (M.FIELD_FORMATTERS..., M.PERIOD_FORMATTERS..., M.format_yyyy_mm)
      @test nameof(f) in named
    end
    # And each arm calls the function it tests for: in the lowered code, after `typeof(X)` the next global
    # of `Models` that is not `isa`/`typeof` is `X` itself (the call), so two swapped arms fail here.
    refs = Symbol[]
    for stmt in only(code_lowered(M.apply_formatter, (Function, Any, Bool))).code,
        a in (stmt isa Expr ? stmt.args : (stmt,))
      a isa GlobalRef && a.mod === M && push!(refs, a.name)
    end
    for (k, r) in enumerate(refs)
      (r === :typeof && k < length(refs)) || continue
      tested = refs[k + 1]
      called = something(findfirst(x -> !(x in (:isa, :typeof)), refs[k + 2:end]), 0)
      @test called > 0 && refs[k + 1 + called] === tested
    end

    # 4. The same answer as the direct call, value by value, ranged and unranged.
    direct(f, v, ranged) = ranged ? f(v) : M.unranged_formatter(f)(v)
    outcome(g) = try
      r = g(); (:ok, typeof(r), r)
    catch e
      (:err, typeof(e), sprint(showerror, e))
    end
    # A wrapper the formatters return (`PormGBytes`, `PormGArrayLiteral`) has no `isequal` of its own, so
    # it is compared slot by slot.
    samevalue(x, y) = isequal(x, y) || (typeof(x) === typeof(y) && isstructtype(typeof(x)) && nfields(x) > 0 &&
                                        all(i -> samevalue(getfield(x, i), getfield(y, i)), 1:nfields(x)))
    same(a, b) = a[1] === b[1] && a[2] === b[2] && samevalue(a[3], b[3])
    values = Any[7, -1, 13, 0, 2.5, true, "abc", "2009-05", "12", SubString("2009-05-24", 1, 10), Dates.Date(2009, 5, 24),
                 Dates.DateTime(2009, 5, 24, 14), M.ZonedDateTime(2009, 5, 24, 14, M.TimeZone("UTC")),
                 M.Decimals.Decimal(0, 150, -2), M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), nothing, missing,
                 [1, 2], ["a", "b"], Dates.Time(10, 30), Dates.Second(90), "10.0.0.1", "10.0.0.0/8",
                 Dict("a" => 1), :sym, 2009_05, UInt8[1, 2],
                 "::ffff:10.0.0.1"]   # the one value the inet and the unpacked-inet formatters answer differently
    user = v -> string("user:", v)
    for f in (M.FIELD_FORMATTERS..., M.PERIOD_FORMATTERS..., M.format_yyyy_mm, unique(filter(x -> x isa M.ArrayFormatter, stored))...,
              user, M.unranged_formatter(M.format_month_sql)), v in values, ranged in (true, false)
      @test same(outcome(() -> M.apply_formatter(f, v, ranged)), outcome(() -> direct(f, v, ranged)))
    end
    @test M.apply_formatter(user, 3) == "user:3"
  end

  # What: the layer-3 residue a trimmed build compiled once per literal type, or read through a boxed
  #   variable: `apply_formatter`'s open arm, the PostgreSQL array-literal parser and the SQLite
  #   timestamp normalizer (#1599 layer 3).
  # Expected: `_apply_formatter_other` takes both the formatter and the value `@nospecialize`, and every
  #   `apply_formatter` instance invokes its one `(Any, Any, Bool)` copy; `parse_pg_array_literal` and
  #   `normalize_sqlite_datetime_string` make no dynamic call; their answers are unchanged.
  # Why: `apply_formatter` is compiled per value type, and each instance carried its own copy of the open
  #   arm (84 verifier rows on the read-only fixture). `parse_pg_array_literal`'s `skip_ws()` closure
  #   reassigned the index it captured, which boxed it (192 rows). The timestamp normalizer joined
  #   captures typed `Union{Nothing, SubString}`, a dynamic call on the SQLite read path.
  @testset "apply_formatter's open arm, the array-literal parser and the timestamp normalizer are compiled once, statically (#1599 layer 3)" begin
    M = PormG.Models
    m = only(methods(M._apply_formatter_other))
    @test m.nospecialize == 0b011   # `f` and `value`; `ranged` is a `Bool`
    other_mi(tt) = [s.args[1] for (ci, _) in Base.code_typed_by_type(tt; optimize = true) for s in ci.code
                    if s isa Expr && s.head === :invoke &&
                       occursin("_apply_formatter_other", string(s.args[1]))]
    for T in (Int64, String, Float64, Bool, Dates.Date, Vector{Int64}, Missing)
      sites = other_mi(Tuple{typeof(M.apply_formatter), Function, T, Bool})
      @test !isempty(sites)
      for ci in sites
        mi = ci isa Core.CodeInstance ? ci.def : ci
        @test mi.specTypes == Tuple{typeof(M._apply_formatter_other), Any, Any, Bool}
      end
    end
    user = v -> string("user:", v)
    @test M.apply_formatter(user, 3) == "user:3" && M.apply_formatter(user, "x", false) == "user:x"

    for S in (String, SubString{String})
      @test isempty(_dynamic_calls(M.parse_pg_array_literal, (S,)))
    end
    # An escaped unquoted element keeps its surrounding spaces, as before.
    @test M.parse_pg_array_literal(" { 1 , \"a b\" ,NULL, \"NULL\" , \\\"q } ") ==
          Union{Nothing, String}["1", "a b", nothing, "NULL", "\"q "]
    @test M.parse_pg_array_literal(SubString("x{}", 2)) == Union{Nothing, String}[]
    @test_throws PormG.InvalidValueError M.parse_pg_array_literal("{1,{2}}")

    @test isempty(_dynamic_calls(M.normalize_sqlite_datetime_string, (String,)))
    @test M.normalize_sqlite_datetime_string("2009-05-24T14:00:00.1Z") == "2009-05-24T14:00:00.100Z"
    @test M.normalize_sqlite_datetime_string("2009-05-24T14:00:00.123456+02:00") == "2009-05-24T14:00:00.123+02:00"
    @test M.normalize_sqlite_datetime_string("2009-05-24T14:00:00-03:00") == "2009-05-24T14:00:00.000-03:00"
    @test M.normalize_sqlite_datetime_string("2009-05-24") == "2009-05-24"
  end

  # What: `Models._pg_decimal_text`, the plain text of a `Decimal` that MySQL's binding sends
  #   (`_bind_value(::Decimal)`) and a PostgreSQL array literal prints.
  # Expected: no dynamic call under either Decimals major (0.4 declares the `s` and `q` slots `Integer`,
  #   0.5 `Bool`/`Int64`), no `:invoke` that an `@invoke` redirects, two levels down, and the text the old
  #   formula gave for every coefficient, exponent and sign, or the same error at the largest lengths.
  # Why: `repeat("0", n)` hands on to another method through an `@invoke`, which a trimmed build cannot
  #   compile: 4 verifier rows on the MySQL fixture, each a MethodError when a query binds a `Decimal`.
  #   Under 0.4 (the unit suite's resolution), `d.s == 1` on the `Integer` slot was a dynamic call too,
  #   and `Int(d.q)` once the drivers' `Int64` constructors are loaded, as they are here.
  @testset "a Decimal's text is built without a dynamic or redirected call (#1599, layer 3)" begin
    M = PormG.Models
    D = M.Decimals.Decimal
    @test isempty(_dynamic_calls(M._pg_decimal_text, (D,)))
    for f in (M._decimal_exponent, M._decimal_negative)
      @test isempty(_dynamic_calls(f, (D,)))
    end
    @test isempty(_dynamic_calls(M._zeros_text, (Int,)))
    # The open arms are one dynamic call each, for an `Integer` slot of another type (Decimals 0.4 only).
    @test length(_dynamic_calls(M._decimal_negative_other, (Any,))) == 1
    redirected(tt, d) = [string(mi.specTypes) for (ci, _) in Base.code_typed_by_type(tt; optimize = true)
                         for st in ci.code if st isa Expr && st.head === :invoke
                         for mi in ((st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]),)
                         if mi isa Core.MethodInstance && mi.def isa Method
                         for T in (which(mi.specTypes) !== mi.def ? (string(mi.specTypes),) :
                                   d > 1 ? redirected(mi.specTypes, d - 1) : ())]
    @test isempty(redirected(Base.signature_type(M._pg_decimal_text, (D,)), 2))

    # The text, against the formula it replaces (`repeat`, `Int(d.q)`, `d.s == 1`).
    function old_text(d)
      c, q = BigInt(d.c), Int(d.q)
      iszero(c) && return "0"
      digits = string(c)
      text = q >= 0 ? digits * repeat("0", q) :
             length(digits) > -q ? digits[1:end + q] * "." * digits[end + q + 1:end] :
             "0." * repeat("0", -q - length(digits)) * digits
      occursin('.', text) && (text = rstrip(rstrip(text, '0'), '.'))
      return (d.s == 1 ? "-" : "") * text
    end
    for s in (0, 1), c in (0, 1, 5, 150, 123456789, big(10)^30 + 7), q in (-40, -12, -3, -2, -1, 0, 1, 2, 9)
      d = D(s, c, q)
      @test M._pg_decimal_text(d) == old_text(d)
    end
    @test M._pg_decimal_text(D(0, 150, -2)) == "1.5"
    @test M._pg_decimal_text(D(1, 1, -3)) == "-0.001"
    @test M._pg_decimal_text(D(0, 12, 3)) == "12000"
    @test M._zeros_text(0) == "" && M._zeros_text(3) == "000"
    # The largest exponents: the same error as `repeat` (an `OutOfMemoryError`, not `fill`'s `ArgumentError`).
    errtype(g) = try g(); nothing catch e; typeof(e) end
    for q in (typemax(Int), typemax(Int) - 1)
      d = D(0, 1, q)
      @test errtype(() -> M._pg_decimal_text(d)) === errtype(() -> old_text(d)) === OutOfMemoryError
    end
  end

  # What: the Dialect renderers a query reaches with the instruction's connection (`_array_slice_expr`,
  #   `_array_index_expr`, `for_update_clause`, `cast_type_sql`, `search`, `ts_vector_sql`, and
  #   `_check_fts_cast` / `fts_capability_error` below them), each called with the connection as the query
  #   builder holds it: `QueryBuilder.ConnType`, a union of the three ABSTRACT engine types; and the two
  #   barriers they reach the capability table through (`_capability_error_at`, `_supports_at`).
  # Expected: every method takes the engine argument `@nospecialize`; a call over `ConnType` makes no
  #   dynamic call; the real call sites in the query builder call these names statically; each engine
  #   reaches the arm it reached before (PostgreSQL renders; SQLite and MySQL refuse, naming themselves);
  #   the table's helpers keep specializing on a concrete pool (#1682's pin, above, still holds).
  # Why: a method specialized on the engine argument is compiled for `PormGSQLite`, an abstract type, which
  #   is not a compileable signature, so the call stayed a dynamic dispatch: 58 trimmed-build rows for the
  #   array slice alone, through `_render_array_subscript` (#1780's survey, group 3). Compiled at the
  #   declared type, each arm is invoked statically. A new engine arm added without `@nospecialize` would
  #   make every call to its function dynamic again, which only the next fixture build would show; the
  #   bit check catches it here.
  @testset "the Dialect renderers take the abstract engine connection statically (#1599 layer 5, group 3)" begin
    D = PormG.Dialect; QB = PormG.QueryBuilder
    CT = QB.ConnType
    # 1. Every method takes its engine argument `@nospecialize`. `fts_capability_error` and the barriers
    #    take an untyped connection as their first argument.
    @test isdefined(D, :_capability_error_at) && isdefined(D, :_supports_at)
    untyped_first = Tuple(getglobal(D, n) for n in (:fts_capability_error, :_capability_error_at, :_supports_at)
                          if isdefined(D, n))
    for f in (D._array_slice_expr, D._array_index_expr, D.for_update_clause, D.cast_type_sql, D.search,
              D.ts_vector_sql, D._check_fts_cast, untyped_first...), m in methods(f)
      params = collect(Base.unwrap_unionall(m.sig).parameters[2:end])
      i = f in untyped_first ? 1 : findfirst(T -> T !== Any && T isa Type && T <: PormG.PormGAbstractType, params)
      @test i !== nothing
      @test (m.nospecialize >> (i - 1)) & 1 == 1
    end
    # 2. A call over `ConnType` resolves: no dynamic call in the caller. The closures name the functions
    #    through `PormG.Dialect` (a constant), not through the local `D`, which they would capture.
    calls = (
      (c, s) -> PormG.Dialect._array_slice_expr(c, s, 1, 2),
      (c, s) -> PormG.Dialect._array_index_expr(c, s, 1),
      (c, s) -> PormG.Dialect.for_update_clause(false, false, false, [s], c),
      (c, s) -> PormG.Dialect.cast_type_sql(s, c),
      (c, s) -> PormG.Dialect.cast_type_sql(s, c; context = s),
      (c, s) -> PormG.Dialect.search(c, s, s),
      (c, s) -> PormG.Dialect.ts_vector_sql(s, "english", c),
      (c, s) -> PormG.Dialect.fts_capability_error(c, s),
      (c, s) -> PormG.Dialect._check_fts_cast(c, s, s, s),
    )
    for g in calls
      @test isempty(_dynamic_calls(g, (CT, String)))
    end
    # Inside each barrier, its own call is the only dynamic one. Read at `Any`, the instance the callers
    #    invoke (the connection is `@nospecialize` and untyped there).
    barriers = isdefined(D, :_capability_error_at) ?
      ((Tuple{typeof(getglobal(D, :_capability_error_at)), Any, Symbol, String}, 1),
       (Tuple{typeof(getglobal(D, :_capability_error_at)), Any, Symbol, String, String}, 1),
       (Tuple{typeof(getglobal(D, :_supports_at)), Any, Symbol}, 1)) : ()
    for (tt, n) in barriers
      ci, _ = only(Base.code_typed_by_type(tt; optimize = true))
      dyn = [s for s in ci.code if s isa Expr && s.head === :call && !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin)]
      @test length(dyn) == n
    end
    # 3. The real call sites, read from the query builder without changing it. (`cast_type_sql`'s and
    #    `ts_vector_sql`'s sites pass a value read from a `Dict{String,Any}` as well, so they stay dynamic
    #    until that value is typed: the PR's hand-off.)
    for (tt, names) in (
        (Tuple{typeof(QB._render_array_subscript), QB.InstructionObject, String, PormG.Models.sArrayField,
               String, Vector{String}, Vector{String}}, ("_array_slice_expr", "_array_index_expr")),
        (Tuple{typeof(QB._render_search_operator), QB.OperObject, String, QB.InstructionObject},
         ("Dialect.search", "fts_capability_error")))
      @test isempty(_named_dynamic_calls(tt, names))
    end
    # 4. Each engine reaches the arm it reached before: PostgreSQL renders, SQLite and MySQL refuse with
    #    their own backend named, and SQLite's FOR UPDATE is empty. The full messages below were read from
    #    the base commit (a3b3492b2), so the text is pinned, not sampled.
    pg, sl, my = _TspStandInPGPool(), _TspStandInPool(), _TspStandInMyPool()
    @test D._array_slice_expr(pg, "t.tags", 1, 2) == "t.tags[1:2]"
    @test D._array_index_expr(pg, "t.tags", 3) == "t.tags[3]"
    for (c, name) in ((sl, "SQLite"), (my, "MySQL"))
      e = try D._array_slice_expr(c, "t.tags", 1, 2); nothing catch err; err end
      @test e isa PormG.BackendCapabilityError
      @test occursin("An ArrayField slice (`__0_2`)", e.msg) && occursin(name, e.msg)
      e = try D.search(c, "v", "q"); nothing catch err; err end
      @test e isa PormG.BackendCapabilityError && occursin("The @search lookup", e.msg) && occursin(name, e.msg)
      @test occursin("PormG does not emulate full-text search (#31).", e.msg)
      e = try D.cast_type_sql("tsvector", c); nothing catch err; err end
      @test e isa PormG.BackendCapabilityError && occursin("Cast: a cast to \"tsvector\"", e.msg)
    end
    @test D.for_update_clause(true, false, false, String[], pg) == "FOR UPDATE NOWAIT \n"
    @test D.for_update_clause(true, false, false, String[], sl) == ""
    @test_throws PormG.BackendCapabilityError D.for_update_clause(false, false, true, String[], my)
    @test D.cast_type_sql("tsvector", pg) == "tsvector"
    msg(f) = try f(); "" catch err; err isa PormG.BackendCapabilityError ? err.msg : "not a refusal" end
    @test msg(() -> D._array_slice_expr(sl, "t.tags", 1, 2)) == "An ArrayField slice (`__0_2`) needs array types " *
      "(`ArrayField`, `integer[]`), which SQLite does not support (supported on PostgreSQL)."
    @test msg(() -> D.search(sl, "v", "q")) == "The @search lookup needs full-text search (`tsvector`, `tsquery`), " *
      "which SQLite does not support (supported on PostgreSQL). PormG does not emulate full-text search (#31)."
    @test msg(() -> D.cast_type_sql("tsvector", sl)) == "Cast: a cast to \"tsvector\" needs full-text search " *
      "(`tsvector`, `tsquery`), which SQLite does not support (supported on PostgreSQL). PormG does not emulate " *
      "full-text search (#31)."
    @test msg(() -> D.cast_type_sql("inet", my)) == "Cast: a cast to \"inet\" needs network address types " *
      "(`inet`, `cidr`), which MySQL does not support (supported on PostgreSQL)."
    @test msg(() -> D.for_update_clause(false, false, true, String[], my)) == "select_for_update(no_key = true) " *
      "needs a row lock weaker than `FOR UPDATE` that leaves foreign-key checks free (`FOR NO KEY UPDATE`), which " *
      "MySQL does not support (supported on PostgreSQL)."
  end

  # What: the Dialect renderers the query builder reaches through a dispatcher of its own: every renderer
  #   `_dialect_function_sql` names (`QueryBuilder._FN_OPTIONS_RENDERERS`, read from Dialect's method table),
  #   the window renderers `_window_no_column_sql` / `_window_column_sql` and the offset sites call
  #   (`RANK`, `DENSE_RANK`, `ROW_NUMBER`, `FIRST_VALUE`, `LAST_VALUE`, `LAG`, `LEAD`, `NTH_VALUE`), and
  #   the helpers their arms pass the connection to (`sqlite_cast_sql`, `_assert_sqlite_window_support`,
  #   through the `_require_feature_at` barrier).
  # Expected: every method takes the engine argument `@nospecialize`; the three dispatchers, called over
  #   `_SQLEngine` (with a `String` and with a list column), make no dynamic call; the window renderers
  #   and `_assert_sqlite_window_support` called over `ConnType` make none, nor does `sqlite_cast_sql`
  #   read at `PormGSQLite` with its keyword body; each engine renders, or refuses with, what it did
  #   before (the literals were read from the commit before this change).
  # Why: the dispatchers' callers (`_function_sql`, the window render) are themselves dynamic calls
  #   today, so a trimmed build never compiles into them and their Dialect calls are not yet fixture
  #   rows. Read by reflection, 16 of the 48 renderer calls in `_dialect_function_sql` and all 5 in the
  #   window dispatchers were dynamic, for #1780's group-3 reason; they would surface as rows the moment
  #   the query-builder hand-off makes their callers static. A renderer added to Dialect later joins
  #   `_FN_OPTIONS_RENDERERS` by itself, so the bit check covers it.
  @testset "the renderers behind the query builder's dispatchers take the engine connection statically (#1599 layer 5, group 3)" begin
    D = PormG.Dialect; QB = PormG.QueryBuilder
    windows = ("RANK", "DENSE_RANK", "ROW_NUMBER", "FIRST_VALUE", "LAST_VALUE", "LAG", "LEAD", "NTH_VALUE")
    fs = Any[getglobal(D, Symbol(n)) for n in unique(vcat(collect(QB._FN_OPTIONS_RENDERERS), collect(windows)))]
    push!(fs, D.sqlite_cast_sql, D._assert_sqlite_window_support)
    @test length(fs) >= 50   # the pin cannot pass by finding no renderer
    # 1. Every method takes its engine argument `@nospecialize`.
    for f in fs, m in methods(f)
      m.module === D || continue
      params = collect(Base.unwrap_unionall(m.sig).parameters[2:end])
      i = findfirst(T -> T !== Any && T isa Type && T <: PormG.PormGAbstractType, params)
      @test i !== nothing
      i === nothing || @test (m.nospecialize >> (i - 1)) & 1 == 1
    end
    @test isdefined(D, :_require_feature_at)
    if isdefined(D, :_require_feature_at)
      @test getglobal(D, :_require_feature_at) |> methods |> only |> (m -> m.nospecialize & 1) == 1
    end
    # 2. The dispatchers resolve every renderer call.
    @test isempty(_dynamic_calls(QB._dialect_function_sql, (String, String, D.FnOptions, QB._SQLEngine)))
    # A list column reaches the renderers that take one (`COALESCE`, `CONCAT`, `GREATEST`, `LEAST`, the list
    #   `CASE` and `SEARCH_*` arms), which a `String` column skips as `MethodError` arms.
    @test isempty(_dynamic_calls(QB._dialect_function_sql, (String, Vector{Any}, D.FnOptions, QB._SQLEngine)))
    @test isempty(_dynamic_calls(QB._window_no_column_sql, (String, String, QB._SQLEngine)))
    @test isempty(_dynamic_calls(QB._window_column_sql, (String, String, String, QB._SQLEngine)))
    # 3. The renderers the dispatchers do not reach and the window check, called over `ConnType`.
    calls = (
      (c, s) -> PormG.Dialect.LAG(s, s, Dict{String,Any}(), c),
      (c, s) -> PormG.Dialect.LEAD(s, s, Dict{String,Any}(), c),
      (c, s) -> PormG.Dialect.NTH_VALUE(s, 2, s, c),
      (c, s) -> PormG.Dialect._assert_sqlite_window_support(c),
    )
    for g in calls
      @test isempty(_dynamic_calls(g, (QB.ConnType, String)))
    end
    # `sqlite_cast_sql` keeps its code in its keyword body, which the `_kw` reader follows.
    @test isempty(_dynamic_calls_kw(D.sqlite_cast_sql, (String, String, PormG.PormGSQLite)))
    # 4. What each engine renders or refuses, unchanged.
    pg, sl, my = _TspStandInPGPool(), _TspStandInPool(), _TspStandInMyPool()
    fo = D.FnOptions()
    msg(f) = try f(); "" catch err; err isa PormG.BackendCapabilityError ? err.msg : "not a refusal" end
    @test D.ARRAY_LEN("t.tags", fo, pg) == "cardinality(t.tags)"
    @test msg(() -> D.ARRAY_LEN("t.tags", fo, sl)) == "The @len transform (array cardinality) needs array types " *
      "(`ArrayField`, `integer[]`), which SQLite does not support (supported on PostgreSQL)."
    @test msg(() -> D.ARRAY_LEN("t.tags", fo, my)) == "The @len transform (array cardinality) needs array types " *
      "(`ArrayField`, `integer[]`), which MySQL does not support (supported on PostgreSQL)."
    @test D.RANK("ORDER BY x", pg) == "RANK() OVER (ORDER BY x)"
    @test D.RANK("ORDER BY x", my) == "CAST(RANK() OVER (ORDER BY x) AS SIGNED)"
    @test D.FIRST_VALUE("t.a", "ORDER BY x", pg) == "FIRST_VALUE(t.a) OVER (ORDER BY x)"
    @test D.FIRST_VALUE("t.a", "ORDER BY x", my) == "FIRST_VALUE(t.a) OVER (ORDER BY x)"
    @test D.sqlite_cast_sql("x", "date", sl) == "date(x)"
    @test D.sqlite_cast_sql("x", "integer", sl) == "CAST(x AS INTEGER)"
    @test msg(() -> D.sqlite_cast_sql("x", "date[]", sl)) == "Cast: a cast to \"date[]\" needs array types " *
      "(`ArrayField`, `integer[]`), which SQLite does not support (supported on PostgreSQL)."
  end

  # What: the query builder's own share of group 3 (#1785's hand-off): the four dispatchers, the callees
  #   that take the engine connection, the callees those forward it to, and every engine fact.
  # Expected: the engine argument of every method of each is named and `@nospecialize` (read live from the
  #   method tables, so a method added later is covered); a call over the engine union makes no dynamic
  #   call, for the dispatchers, the read path's callees and every one-argument engine fact; the
  #   write-path facts that forward the connection to a statement keep their specialization.
  # Why: the query builder holds the connection as a union of the three abstract engine types. Inference
  #   splits the union, but each arm's method specialized on an abstract type is not a compileable
  #   signature, so the call stayed a dynamic dispatch: about 60 verifier rows on each fixture, and a
  #   `MethodError` in a trimmed image for any arm no static call compiled. `@nospecialize` compiles each
  #   method once at its declared type, which every arm invokes. Julia ignores it on an unnamed argument.
  @testset "the query builder's callees take the engine connection statically (#1599 layer 5, group 3)" begin
    QB = PormG.QueryBuilder; K = PormG.Kernel
    is_engine(T) = T isa Type && T !== Any && T !== Union{} &&
      (T <: K.PormGBackend || (T isa Union && T <: Union{K._SQLEngine, Nothing}))
    facts = Set{Symbol}(m.name for name in names(QB; all = true) if isdefined(QB, name)
                        for m in (let f = getglobal(QB, name); f isa Function ? methods(f) : () end)
                        if m.module === QB && endswith(string(m.file), "engine_facts.jl"))
    # The write path's facts that hand the connection on to a statement (layer 7, #1694): unchanged.
    write_facts = (:_allocate_ids, :_inserted_row_query, :_update_row_count)
    callees = (:_function_sql, :_dialect_function_sql, :_window_no_column_sql, :_window_column_sql,
               :_limit_offset_sql, :_declared_kind, :_unordered_interval_error, :_duration_math_refusal,
               :_duration_value_units, :_temporal_shift_sql, :_computed_kind, :_departure,
               :_guarded_integer_type, :_interval_round_sql, :_division_sql, :_as_interval_text,
               :_duration_units, :_predicate_duration_units, :_split_qualified_column, :_order_term_sql,
               :_duration_part_refusal, :_time_arithmetic_refusal, :_unnamed_temporal_refusal,
               :_bitwise_not_sql, :_xor_sql, :_untyped_date_refusal, :_day_count_shift_sql,
               :_duration_operand_units, :_duration_value_sql, :_json_document_marker, :_meaning_refusal,
               # the callees the ones above hand the connection to
               :_computes, :_interval_ms_as_text, :_duration_values_units,
               # (`_unnamed_temporal_remedy` was listed here until #1599 layer 5: it no longer takes the
               # connection, so the refusals read `_timestamp_remedy` instead, listed below)
               :_interval_error,
               # the engine's timestamp remedy, read by the refusals at the engine's type (#1599 layer 5)
               :_timestamp_remedy,
               # an ORDER BY term's render at concrete types, and its open arm (#1599 layer 5)
               :_order_term_at, :_order_term_other)
    checked = 0
    for name in union(Set(callees), setdiff(facts, write_facts))
      f = getglobal(QB, name)
      for m in methods(f)
        m.module === QB || continue
        params = collect(Base.unwrap_unionall(m.sig).parameters[2:end])
        argn = Base.method_argnames(m)[2:end]
        for (i, T) in enumerate(params)
          (is_engine(T) || (T === Any && i <= length(argn) && argn[i] in (:conn, :connection))) || continue
          checked += 1
          @test (name, m.line, i, (m.nospecialize >> (i - 1)) & 1) == (name, m.line, i, 1)
        end
      end
    end
    # The exact count records the set: a method added, removed or renamed in it changes it.
    @test checked == 195
    # Their engine argument, the first, stays specialized. `_inserted_row_query`'s `result` (its fourth, bit 3) is
    # unspecialized since #1614; nothing else is, on any of the three.
    for name in write_facts, m in methods(getglobal(QB, name))
      @test (name, m.nospecialize) == (name, name === :_inserted_row_query ? 8 : 0)
    end

    # A call over the engine union resolves. The closures name the functions through the module (a
    # constant), so they capture nothing but what they are given.
    E = K._SQLEngine
    @test isempty(_dynamic_calls(c -> PormG.QueryBuilder._function_sql("UPPER", "t.a", Dict{String,Any}(), c), (E,)))
    @test isempty(_dynamic_calls(c -> PormG.QueryBuilder._dialect_function_sql("ROUND", "t.a",
                                        PormG.Dialect.FnOptions(Dict{String,Any}()), c), (E,)))
    @test isempty(_dynamic_calls(c -> PormG.QueryBuilder._window_no_column_sql("RANK", "ORDER BY x", c), (E,)))
    @test isempty(_dynamic_calls(c -> PormG.QueryBuilder._window_column_sql("FIRST_VALUE", "t.a", "ORDER BY x", c), (E,)))
    @test isempty(_dynamic_calls((p, c) -> PormG.QueryBuilder._limit_offset_sql(10, 0, p, c),
                                 (PormG.QueryBuilder.SQLiteParameterizedQuery, E)))
    @test isempty(_dynamic_calls(c -> PormG.QueryBuilder._split_qualified_column("t.a", "a", c), (E,)))
    @test isempty(_dynamic_calls(c -> PormG.QueryBuilder._declared_kind("integer", c), (QB.ConnType,)))
    @test isempty(_dynamic_calls(c -> PormG.QueryBuilder._departure(c, :text, :integer), (QB.ConnType,)))
    for name in setdiff(facts, write_facts)
      f = getglobal(QB, name)
      all(m -> m.nargs == 2, methods(f)) || continue   # the facts that take only the engine
      @test (name, _dynamic_calls(c -> f(c), (E,))) == (name, String[])
    end
  end

  # What: group 3's second half: the capability lookups the query builder makes, and the Dialect calls a
  #   value left dynamic (#1599 layer 5, group 3).
  # Expected:
  #   - the three Dialect barriers reach a pool PormG builds at its concrete type through `with_pool`
  #     (a static call per pool type) and keep exactly one dynamic call, for anything else;
  #   - every capability lookup in src/querybuilder/ goes through them, except the write path's
  #     (execution_write.jl and execution_bulk.jl, not scanned, the bulk key allocation fact and the
  #     deferred-foreign-key delete check; layer 7, #1694) and `_require_outer_join_feature`'s, which walks
  #     to the pool itself (#1784);
  #   - the run-time `Val`, the cast's type name, the full-text configuration and NTH_VALUE's column are
  #     typed at the call site (no dynamic call in the helpers), `_pattern_text_operand` and `SUBSTR`
  #     take the engine `@nospecialize`;
  #   - every answer, render and refusal equals the direct call's.
  # Why: inside a function that holds the instruction the connection is a union of abstract engine
  #   types, and the capability table specializes on it (#1682), so each lookup was a dynamic call: about
  #   27 verifier rows on each fixture, and with a barrier alone, still one dynamic call at run time.
  @testset "the query builder's capability lookups reach the pool's concrete type, and its Dialect values are typed (#1599 layer 5, group 3)" begin
    QB = PormG.QueryBuilder; D = PormG.Dialect; K = PormG.Kernel; CP = PormG.ConnectionPool
    # 1. The barriers: one dynamic call each (the open arm, for a value that is no engine); an engine
    #    goes through `with_pool`, whose closed set calls the table at each concrete pool (pinned by the
    #    #1622 testset), where the lookup makes no dynamic call (#1682).
    for (f, tt) in ((D._supports_at, (Any, Symbol)), (D._capability_error_at, (Any, Symbol, String)),
                    (D._capability_error_at, (Any, Symbol, String, String)),
                    (D._require_feature_at, (Any, Symbol, String)))
      @test length(_dynamic_calls(f, tt)) == 1
    end
    dialect_src = read(joinpath(pkgdir(PormG), "src", "Dialect.jl"), String)
    @test count("conn isa _SQLEngine && return with_pool(", dialect_src) == 4
    @test isempty(_dynamic_calls(K._supports, (CP.SQLiteConnectionPool, Symbol)))
    # 2. No bare capability lookup left in the query builder but the write path's, and
    #    `_require_outer_join_feature`'s (its own `with_pool` walk). Each exemption names its line.
    reviewed = ("engine_facts.jl" => "_capability_error(conn, :preallocated_keys",
                "deletion.jl" => "_supports(connection, :deferred_foreign_keys)",
                "deletion.jl" => "_capability_error(connection, :deferred_foreign_keys",
                "build_query.jl" => "_require_feature_on(pool, feature::Symbol, what::String)::Nothing = _require_feature(pool, feature, what)",
                "build_query.jl" => "return _require_feature(conn, feature, what)")
    bare = String[]
    for f in sort(readdir(joinpath(pkgdir(PormG), "src", "querybuilder"); join = true))
      endswith(f, ".jl") || continue
      (endswith(f, "execution_write.jl") || endswith(f, "execution_bulk.jl")) && continue   # layer 7, #1694
      lines = split(read(f, String), '\n')
      for (i, l) in enumerate(lines)
        s = strip(l); startswith(s, "#") && continue
        occursin(r"(?<![\w.])(?:(?:PormG|Kernel)\.)?(_supports|_capability_error|_require_feature)\(", l) || continue
        any(r -> endswith(f, r.first) && occursin(r.second, l), reviewed) && continue
        push!(bare, "$(basename(f)):$(i): $(s)")
      end
    end
    @test bare == String[]
    # 3. The value sites, typed: no dynamic call in the helpers, and the Dialect methods despecialized.
    @test isempty(_dynamic_calls(QB._pattern_text_operand_at, (QB.ConnType, Symbol, String)))
    @test isempty(_dynamic_calls(QB._cast_type_sql_at, (AbstractString, QB.ConnType, String)))
    @test isempty(_dynamic_calls(QB._ts_vector_sql_at, (String, Any, QB.ConnType)))
    @test isempty(_dynamic_calls(QB._emulates_nulls_order, (K.PormGSQLite,)))
    @test isempty(_dynamic_calls(c -> PormG.Dialect.SUBSTR(Any["t.a", 2], c), (K._SQLEngine,)))
    # NTH_VALUE's typed arm (`_get_select_query(::WindowFunction)`): a `String` column and an `Int` n.
    @test isempty(_dynamic_calls(c -> PormG.Dialect.NTH_VALUE("t.a", 2, "ORDER BY x", c), (QB.ConnType,)))
    @test occursin("resolved_column isa String && n isa Int &&",
                   read(joinpath(pkgdir(PormG), "src", "querybuilder", "select_nodes.jl"), String))
    # the dynamic calls that take the engine (argument 2 of the method's code: the function is argument 1)
    dyn_in(ci) = [string(s) for s in ci.code if s isa Expr && s.head === :call &&
                  !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin) && Core.Argument(2) in s.args[2:end]]
    for m in methods(D._pattern_text_operand)
      @test m.nospecialize & 1 == 1   # the engine is the first argument
      # and the body, at its declared types, passes the engine to no dynamic call (it refuses through the
      # barrier, not the table directly)
      @test (m.sig, [c for (ci, _) in Base.code_typed_by_type(m.sig; optimize = true) for c in
                     dyn_in(ci)]) == (m.sig, String[])
    end
    for m in methods(D.SUBSTR)
      @test m.nospecialize & 2 == 2   # and SUBSTR's second
    end
    # 4. The same answers, renders and refusals as the direct calls.
    pg, sl, my = _TspStandInPGPool(), _TspStandInPool(), _TspStandInMyPool()
    real = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    function outcome(f)
      try
        return (:ok, f())
      catch e
        return (:err, typeof(e), sprint(showerror, e))
      end
    end
    for c in (pg, sl, my, real), feat in (:full_text_search, :network_types, :nulls_order,
                                           :negative_round_precision, :window_groups_frame, :explain_options)
      @test D._supports_at(c, feat) == K._supports(c, feat)
      @test outcome(() -> sprint(showerror, D._capability_error_at(c, feat, "what", "why text"))) ==
            outcome(() -> sprint(showerror, K._capability_error(c, feat, "what"; why = "why text")))
    end
    @test outcome(() -> D._supports_at(nothing, :full_text_search)) == outcome(() -> K._supports(nothing, :full_text_search))
    for c in (pg, sl, my), kind in (:integer, :date, :time, :uuid, :inet, :cidr, :text)
      @test outcome(() -> QB._pattern_text_operand_at(c, kind, "t.a")) ==
            outcome(() -> D._pattern_text_operand(c, Val(kind), "t.a"))
    end
    for c in (pg, sl, my), t in ("integer", "varchar(10)", "date[]", "nope"), ctx in ("Cast", "output_field")
      @test outcome(() -> QB._cast_type_sql_at(t, c, ctx)) == outcome(() -> D.cast_type_sql(t, c; context = ctx))
      @test outcome(() -> QB._cast_type_sql_at(SubString(t), c, ctx)) == outcome(() -> D.cast_type_sql(SubString(t), c; context = ctx))
    end
    for c in (pg, sl, my), cfg in ("english", nothing, :simple)
      @test outcome(() -> QB._ts_vector_sql_at("t.a", cfg, c)) == outcome(() -> D.ts_vector_sql("t.a", cfg, c))
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
      # the ORDER BY term's render: none left. Its interval render's closure captured `order_node`, a
      # `FieldPart`, and its scope call was left unresolved until the term went to `_with_field_part_open`
      # and a helper that builds the closure over the member (#1599 layer 6, `_interval_operand_scoped`).
      # The term's plain render walks `order_node` behind a `@noinline` barrier (`_render_order_term`,
      # #1698 phase 2). The body is `_render_order_terms` since #1599 slice C.
      "_render_order_terms" => (0, 0),
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
    # `_with_render_scope` has two methods since #1599 layer 5 (keywords, or a scope the caller built).
    for g in (QB.with_scope, QB._with_render_scope, QB._join_scope), m in methods(g)
      sig = Base.unwrap_unionall(m.sig)
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
    # `close` on a handle only through its named helpers. The SQLite worker's two statement calls go
    # through `_with_handle` too, in `_sqlite_statement_call` (#1599 layer 2; they ran through
    # `_call_latest` before and were reviewed here as an exception).
    # Driver generics that take a handle, called directly or handed on as a value (`_call_latest(f, …)`,
    # `invokelatest(f, …)`), and `close` on a handle, called or broadcast.
    generic = raw"backend_(?:is_alive|renew_connection|execute_async|execute_rows|execute|cancel_query!|drain_connection!|copy_in!|ping)"
    driver_call = Regex(raw"\b(" * generic * raw")\(|(?:_call_latest|invokelatest)\((" * generic * raw"|close),")
    close_call = r"(?<!\w)close\.?\((?:conn|retired|dead|new_conn|handle|handles|h|old|pool\.connections)\b"
    # The named helpers the barrier calls, by their exact definitions, each expected exactly once.
    helpers = ("_handle_close(pool, conn) = close(conn)", "_handle_close_latest(pool, conn) = _call_latest(close, conn)",
               "_handle_renew(pool, conn) = backend_renew_connection(pool, conn)",
               "_handle_renew(pool, conn, read_only::Bool) = backend_renew_connection(pool, conn; read_only = read_only)")
    # Backend.jl's default `backend_execute_rows` (a driver without a typed read) is reached only from the
    # SQLite worker, through `_with_handle`, with the handle it was given: the reviewed exception.
    reviewed = ("backend_execute_rows(pool::PormGBackend, conn, sql::String, params, decode) =",
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
    # And the terminal that holds the lease: `with_advisory_lock` on a concrete pool makes no dynamic call.
    # #1708 left one, the abandon-only renewal, which passes the abandoned statement's handle that
    # `_LockAwaitState` holds as `Any`. #1599 layer 2 took that handle `@nospecialize` in
    # `_recover_abandoned_connection!`, and the recovery's `wait` on it names a `Task` (`_wait_handle`), so
    # the callers that pass it concretely still make a static call there.
    body = () -> nothing
    for P in (CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres}, CP.MySQLConnectionPool)
      dyn = _dynamic_calls_kw(PormG.AdvisoryLock.with_advisory_lock, (typeof(body), P, String))
      @test (P, "with_advisory_lock", dyn) == (P, "with_advisory_lock", String[])
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

  # What: `await_result` on a `FetchTask` (which holds its pool typed `_SQLEngine`), the body it runs per
  #   pool type, and the handle helpers it reaches (`_fetch_interruptible`, `_settle_probe`, the
  #   abandoned-await recovery) with the handle typed `Any`, as `FetchTask` holds it.
  # Expected: no dynamic call: `await_result` enters `with_pool`'s closed set once, so the release, the
  #   error wrapping and the recovery take the pool at its concrete type (the stand-in pools' open arm,
  #   `_with_unlisted_pool`, is the reviewed exception), and the handle's `fetch`/`wait` names a `Task` and
  #   leaves any other handle to one open arm. `FetchTask` itself is unchanged, and awaits as before.
  # Why: every call on the abstract `FetchTask.pool`, and the handle helpers specialized on an `Any`
  #   handle, were dispatched at run time: 10 rows of the trimmed fixture's read (#1599 layer 2).
  @testset "await_result reaches the pool at its concrete type (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    @test _dynamic_calls_deep(CP.await_result, (CP.FetchTask,); depth = 1, skip = (CP._with_unlisted_pool,)) == String[]
    for P in (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
              CP.MySQLConnectionPool)
      @test (P, _dynamic_calls(CP._await_on, (P, CP.FetchTask))) == (P, String[])
      @test (P, _dynamic_calls_kw(CP._recover_abandoned_connection!, (P, Any, Any))) == (P, String[])
    end
    @test _dynamic_calls(CP._fetch_interruptible, (Any,)) == String[]
    @test _dynamic_calls(CP._settle_probe, (Any,)) == String[]
    @test isconcretetype(CP.FetchTask) && fieldtype(CP.FetchTask, :pool) === PormG.Kernel._SQLEngine
    sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    ft = CP.FetchTask(Threads.@spawn(41 + 1), sl, nothing, true)   # in a transaction: nothing is released
    @test typeof(ft) === CP.FetchTask
    @test CP.await_result(ft) == 42
    @test CP.await_result(ft) == 42                                 # cached, as before
  end

  # What: the park branch of both `acquire_connection` twins (the wait for a handed slot), and the
  #   handoff that delivers one (`_handoff_or_free!`), on each pool type.
  # Expected: the waiter is read at `PoolWaiter`, so its `take!` is static; the delivered pair is a
  #   `_Handed` (`slot`, `handle`), a concrete type, so the handoff's `put!` is static.
  # Why: the waiter came out of the outcome tuple as `Any` (4 rows), and the pair was a `Tuple{Int,Any}`,
  #   an abstract type that `put!` specializes on (8 rows of the trimmed fixture, #1599 layer 2).
  @testset "the waiter's take! and the handoff's put! are static (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    owned = Base.RefValue{Union{Nothing, Tuple{Int, Any}}}
    waits(dyn) = filter(s -> occursin("take!", s) || occursin(":chan", s), dyn)
    @test waits(_dynamic_calls(CP._acquire_connection!, (CP.SQLiteConnectionPool, owned, Nothing, Int, Symbol))) == String[]
    for P in (CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres}, CP.MySQLConnectionPool)
      @test (P, waits(_dynamic_calls(CP._acquire_connection!, (P, owned, Nothing, Int)))) == (P, String[])
    end
    for P in (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
              CP.MySQLConnectionPool)
      @test (P, _dynamic_calls_kw(CP._handoff_or_free!, (P, Int))) == (P, String[])
    end
    @test isconcretetype(CP._Handed)
  end

  # What: `run_in_transaction` entered with a settings entry (`with_pool`'s closed set), the transaction
  #   body, its rollback classifier and the slot-membership check, on each pool type.
  # Expected: no dynamic call: the block reaches `with_pool` as the callee (`_InTransaction`), the
  #   terminal release is a keyword call on the public `finalize_transaction_connection!` with a
  #   `NamedTuple` whose type is written out (`_finalize_with`), the SQLite rollback test reads the text through
  #   `_unowned_string`, and the membership check is a named function. `with_pool`'s open arm
  #   (`_with_unlisted_pool`) is the reviewed exception. The answers are the ones before.
  # Why: eight `with_pool` rows (a vararg slot holding a `Function` is not specialized), four `kwcall` rows
  #   (a keyword call carrying two `Any` errors), eight in `_is_benign_rollback_error` and its callers' `!`,
  #   and two on a `lock` closure capturing an untyped handle (#1599 layer 2, the fixture's write).
  @testset "a transaction is entered and finished without a dynamic call (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    body = () -> 1
    # `atomic` on a key or a settings entry, a user's `atomic(key) do … end`: the block reaches `with_pool` as the
    # callee (`_Atomic`), not in its vararg slot (eight rows once the fixture ran one, #1599 layer 2).
    for D in (String, PormG.Kernel.Settings)
      @test (D, _dynamic_calls_deep(CP.atomic, (typeof(body), D); depth = 2, skip = (CP._with_unlisted_pool,))) == (D, String[])
    end
    @test _dynamic_calls_deep(CP.run_in_transaction, (typeof(body), PormG.Kernel.Settings); depth = 1,
                              skip = (CP._with_unlisted_pool,)) == String[]
    for P in (CP.SQLiteConnectionPool, CP.PostgresConnectionPool{:libpq}, CP.PostgresConnectionPool{:postgres},
              CP.MySQLConnectionPool)
      @test (P, _dynamic_calls(CP._run_in_transaction_impl, (typeof(body), P))) == (P, String[])
      @test (P, _dynamic_calls(CP._is_benign_rollback_error, (P, Any))) == (P, String[])
      @test (P, _dynamic_calls(CP._slot_holds, (P, Any))) == (P, String[])
      # one level into the keyword sorter: the keyword body it calls takes the two errors `@nospecialize`
      @test (P, _dynamic_calls_deep(CP._finalize_with, (P, Any, Any, Bool, Any, Bool); depth = 1)) == (P, String[])
    end
    sl = CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
    @test CP._is_benign_rollback_error(sl, ErrorException("cannot rollback - no transaction is active"))
    @test !CP._is_benign_rollback_error(sl, ErrorException("disk I/O error"))
    c = CP.acquire_connection(sl)
    @test CP._slot_holds(sl, c) && !CP._slot_holds(sl, :not_a_handle)
    CP.release_connection(sl, c)
  end

  # What: the cause walks a classifier runs on a caught exception (`backend_is_cancellation` over a
  #   `CompositeException`, `_unowned_inner`, the Postgres.jl extension's interrupt walk) and that
  #   extension's parameter binding (`_bind`) on each collector type.
  # Expected: no dynamic call but the reviewed ones: `backend_is_cancellation`'s recursion on an untyped
  #   inner exception (a method per driver, so a dispatch by design), and the open arms (`_unowned_field`,
  #   `_bind_other`, `_bind_value_other`), which are not walked. The answers are the ones before.
  # Why: Base does not specialize `any` on a function argument (2 rows), a specializing walk called with an
  #   `Any` exception is a dispatch per call (2 rows of the Postgres.jl fixture), and `_bind` mapped over
  #   the abstract `parameters` slot (10 rows of the Postgres.jl fixture) (#1599 layer 2).
  @testset "the cause walks and the Postgres.jl binding make no dynamic call (#1599 layer 2)" begin
    QB = PormG.QueryBuilder
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    stmt(s) = split(s, "}: "; limit = 2)[end]
    found = _dynamic_calls_deep(PormG.backend_is_cancellation, (CompositeException,); depth = 2)
    @test filter(s -> !startswith(stmt(s), "PormG.backend_is_cancellation("), found) == String[]
    @test !PormG.backend_is_cancellation(CompositeException(Any[ErrorException("x")]))
    @test PormG.backend_is_cancellation(CompositeException(Any[ErrorException("x"),
      CompositeException(Any[MySQL.Protocol.Error(UInt32(1317), "Query execution was interrupted", "70100")])]))
    @test _dynamic_calls(PormG._unowned_inner, (Any,)) == String[]
    @test PormG._unowned_inner(_TspWrap(ErrorException("x"))) isa ErrorException
    @test PormG._unowned_inner(_TspWrapErr(ErrorException("x"))) isa ErrorException
    @test PormG._unowned_inner(_TspWrap("not an exception")) === nothing
    @test PormG._unowned_inner(ErrorException("x")) === nothing
    @test _dynamic_calls(pgx._interrupt_in_causes, (Any, Int)) == String[]
    @test pgx._interrupt_in_causes(InterruptException())
    @test pgx._interrupt_in_causes(_TspWrap(_TspWrap(InterruptException())))
    @test !pgx._interrupt_in_causes(_TspWrap(ErrorException("x")))
    @test !pgx._interrupt_in_causes(foldl((e, _) -> _TspWrap(e), 1:5; init = InterruptException()))   # past 4 levels
    for T in (QB.PgParameterizedQuery, QB.SQLiteParameterizedQuery, QB.MySQLParameterizedQuery, Nothing)
      @test (T, _dynamic_calls(pgx._bind, (T,))) == (T, String[])
    end
    for vals in (Any[UInt8[1, 2], "Monaco", 3], Any[1, 2], Any["Spa", nothing])
      bound = pgx._bind(QB.PgParameterizedQuery("", vals, length(vals)))
      # The text Postgres.jl binds (#1599 layer 2, below): what the driver makes of the vector `_bind`
      # returned before, which `test_postgres_ext.jl` checks over every kind.
      @test isequal(Postgres.build_unchecked_params(bound), Postgres.build_unchecked_params(map(pgx._bind_value, vals)))
    end
    @test pgx._bind((UInt8[7], "Imola")) == ([7], "Imola")
    @test pgx._bind(nothing) === nothing
  end

  # What: the Postgres.jl extension's wire text for a `Vector{Any}` of parameters (`_wire_texts`, the
  #   per-value walk `_wire_text`), and Postgres.jl's two bindings (`bind_params!` for a prepared statement,
  #   `build_unchecked_params` for an unnamed one) over the `Vector{_PgBound}` `_bind` returns, six calls
  #   deep, through the extension's `_param(::_PgBound)`.
  # Expected: no dynamic call but the open arm `_wire_text_other`, which is not walked, and the spelling of
  #   a value inside `print` (Decimals' `print`, which `_param(::Decimal)` reaches through `string`, as
  #   before). That it binds what Postgres.jl bound before, and fails where it failed, is pinned in
  #   `test_postgres_ext.jl`.
  # Why: Postgres.jl calls `_param` on each value, a dispatch per value on a `Vector{Any}`, and `map` over
  #   one sized its result from the first value's type at run time: with the connect typed, the trimmed
  #   Postgres.jl fixture raised `MethodError` on `Vector{T}(undef, n)`, then on `_param(::String)`, at
  #   its first statement (#1599 layer 2, #1614).
  @testset "the Postgres.jl parameters reach the driver as wire text, statically (#1599 layer 2)" begin
    QB = PormG.QueryBuilder
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    @test isdefined(pgx, :_wire_texts) && _dynamic_calls(pgx._wire_texts, (Vector{Any},)) == String[]
    @test isdefined(pgx, :_wire_text) && _dynamic_calls(pgx._wire_text, (Any,)) == String[]
    @test pgx._bind(QB.PgParameterizedQuery("", Any["Monaco", 2008], 2)) isa Vector{pgx._PgBound}
    W = Vector{pgx._PgBound}
    @test _dynamic_calls(Postgres._param, (pgx._PgBound,)) == String[]
    spelling(s) = occursin(r"^Tuple\{typeof\((Base\.)?print(_to_string)?\), ", s)
    for (f, tt) in ((Postgres.build_unchecked_params, (W,)),
                    (Postgres.bind_params!, (Vector{Union{String, Missing}}, W, String)))
      found = _dynamic_calls_deep(f, tt; depth = 6, skip = (pgx._wire_text_other, Postgres.param_mismatch))
      @test (f, filter(!spelling, found)) == (f, String[])
    end
  end

  # What: the Postgres.jl extension's async statement, `backend_execute_async`, on each collector type, and
  #   `_statement_on`, which builds the task's closure, at the two bound types `_bind` returns concretely.
  # Expected: no dynamic call; the open arm `_statement_on_other` is a static call into a `@nospecialize`
  #   barrier.
  # Why: the closure captures the bound parameters, so its type carried `_bind`'s inferred result, which is
  #   not concrete, and the `_statement_task` call was dynamic: with the parameters typed, the trimmed
  #   Postgres.jl fixture raised `MethodError` on `_statement_task` at its first statement (#1599 layer 2,
  #   #1614).
  @testset "the Postgres.jl statement task is started without a dynamic call (#1599 layer 2)" begin
    QB = PormG.QueryBuilder
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    P = PormG.ConnectionPool.PostgresConnectionPool{:postgres}
    for T in (QB.PgParameterizedQuery, QB.SQLiteParameterizedQuery, QB.MySQLParameterizedQuery, Nothing)
      @test (T, _dynamic_calls(PormG.backend_execute_async, (P, pgx._Conn, String, T))) == (T, String[])
    end
    for B in (Vector{pgx._PgBound}, Nothing)
      @test isdefined(pgx, :_statement_on) &&
            (B, _dynamic_calls(pgx._statement_on, (P, pgx._Conn, String, B))) == (B, String[])
    end
    # The collector's values take the typed arm, not the open one.
    @test typeof(pgx._bind(QB.PgParameterizedQuery("", Any["Monaco"], 1))) === Vector{pgx._PgBound}
  end

  # What: the MySQL extension's result cursor, `_materialize`, at the two cursors `_run` hands it (a
  #   prepared statement's binary cursor with its charset flags, the text protocol's without), followed
  #   six calls deep. The open arms (`_push_other_cell!`, a column type outside MySQL.jl's set;
  #   `_store_other!`, a column the walk cannot name) are the reviewed dynamic calls, and
  #   `print_to_string` is MySQL.jl's own error text (a conversion error, a stale row), not walked into.
  # Expected: no dynamic call.
  # Why: the cell's type is a run-time `Type`, so `getcolumn(row, j)` returned `Any` and the read value,
  #   the charset swap, the push and the column's `identity.` narrowing were dispatched per cell: 148
  #   verifier rows in the MySQL trim fixture (#1599 layer 2, #1614). Each cell now reads through a walk
  #   over MySQL.jl's column types with the typed `getcolumn(row, T, j, name)`.
  @testset "the MySQL result cursor reads each cell at its concrete type (#1599 layer 2)" begin
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    skip = (myx._push_other_cell!, myx._store_other!, Base.print_to_string)
    for tt in ((MySQL.Cursor{true, true}, Vector{Bool}), (MySQL.Cursor{false, true}, Nothing))
      @test (tt, _dynamic_calls_deep(myx._materialize, tt; skip)) == (tt, String[])
    end
  end

  # What: the MySQL extension's `_bind` at each collector, raw values and `nothing`, and the statement
  #   paths that call it (`backend_execute`, `backend_execute_async` and its statement closure); then what
  #   it binds, against the comprehension it replaced: a `Vector{Any}` of `_bind_value` over the values.
  # Expected: no dynamic call (the open arms for another collector or container are skipped), and the
  #   same values of the same types (in a `Vector{_BoundValue}` since #1599's MySQL statement wall, below),
  #   `nothing` for no values, the same refusal past the limit.
  # Why: the collector's `parameters` slot is `Union{AbstractVector, Tuple}`, so `isempty`, `length` and
  #   the comprehension over `_bind_value`'s three methods were dispatched at run time, and the statement
  #   closure captured `_bind`'s `Any`: 26 rows in the MySQL trim fixture (#1599 layer 2).
  @testset "the MySQL binding reads the collector and its values at their types (#1599 layer 2)" begin
    QB = PormG.QueryBuilder
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    P = PormG.ConnectionPool.MySQLConnectionPool
    skip = (myx._other_param_values, myx._bind_other, PormG.Models._pg_decimal_text, Base.print_to_string)
    in_ext(s) = occursin("PormGMySQLExt.", first(split(s, "}: "; limit = 2)))
    # `Any` is the signature `@nospecialize` compiles; the collectors are what the statement paths pass.
    for T in (Any, QB.PgParameterizedQuery, QB.MySQLParameterizedQuery, QB.SQLiteParameterizedQuery, Vector{Any}, Nothing)
      @test (T, filter(in_ext, _dynamic_calls_deep(myx._bind, (P, T); depth = 3, skip))) == (T, String[])
    end
    for T in (QB.PgParameterizedQuery, QB.MySQLParameterizedQuery)
      @test (T, _dynamic_calls(PormG.backend_execute_async, (P, MySQL.Connection, String, T))) == (T, String[])
      @test (T, _dynamic_calls(PormG.backend_execute, (P, MySQL.Connection, String, T))) == (T, String[])
    end
    pool = P("host='127.0.0.1' user='u' password='p' dbname='f1'"; pool_size = 1)
    TZ, Dec = myx.TimeZones, myx.Decimals   # the extension's own imports
    zdt = TZ.ZonedDateTime(Dates.DateTime(1991, 3, 10, 14, 30), TZ.TimeZone("America/Sao_Paulo"))
    for vals in (Any[Dec.Decimal(0, 255, -1), zdt, "Senna", 3, missing, nothing], Any[1, 2], Any["Spa"])
      expected = Any[myx._bind_value(v) for v in vals]
      for params in (QB.PgParameterizedQuery("", vals, length(vals)), copy(vals))
        bound = myx._bind(pool, params)
        @test isequal(bound, expected) && map(typeof, bound) == map(typeof, expected)
      end
      mq = QB.MySQLParameterizedQuery(); append!(mq.where_params, vals)
      @test isequal(myx._bind(pool, mq), expected)
    end
    @test myx._bind(pool, nothing) === nothing
    @test myx._bind(pool, Any[]) === nothing
    @test myx._bind(pool, QB.MySQLParameterizedQuery()) === nothing
    @test myx._bind(pool, ("Imola", 1)) == Any["Imola", 1]   # a tuple takes the open arm, as before
    @test myx._bind(pool, ()) === nothing
    # The open arm is one dynamic call (#1735), into the body that specializes on the container.
    @test length(_dynamic_calls(myx._bind_other, (P, Any))) == 1
  end

  # What: `backend_mysql_version` and the reader of its result, `_version_text`, then what the reader
  #   returns for the results it can get, against the read it replaced (`String(only(collect(r))[1])`).
  # Expected: no dynamic call (the open arm, `_version_text_other`, is that read, kept for any other
  #   result); the same text for one row, and the same error for none or two.
  # Why: `fetch` returns the driver's result untyped, so `collect`, `only` and `String` on it were
  #   dispatched at run time: 22 rows in the MySQL trim fixture (#1599 layer 2).
  @testset "the MySQL server version is read from the result at its type (#1599 layer 2)" begin
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    P = PormG.ConnectionPool.MySQLConnectionPool
    @test _dynamic_calls(PormG.backend_mysql_version, (P,)) == String[]
    @test _dynamic_calls(myx._version_text, (Any,)) == String[]
    @test length(_dynamic_calls(myx._version_text_other, (Any,))) == 1   # the open arm (#1735)
    R = myx.MySQLResult
    old(r) = String(only(collect(r))[1])
    err(f, r) = try f(r); nothing catch e; (typeof(e), sprint(showerror, e)) end
    one = R([:v], AbstractVector[["8.4.11-log"]], 1, 0, UInt64(0), "")
    @test myx._version_text(one) == old(one) == "8.4.11-log"
    two_cols = R([:v, :w], AbstractVector[["8.4.0"], [1]], 1, 0, UInt64(0), "")
    @test myx._version_text(two_cols) == old(two_cols)
    for r in (R([:v], AbstractVector[String[]], 0, 0, UInt64(0), ""),
              R([:v], AbstractVector[["8.4.0", "8.4.1"]], 2, 0, UInt64(0), ""),
              R([:v], AbstractVector[Union{Missing, String}[missing]], 1, 0, UInt64(0), ""))
      @test err(myx._version_text, r) == err(old, r)
    end
  end

  # What: `_run` at both bound shapes, and the cause walk `_with_bare_interrupt` uses.
  # Expected: no dynamic call in `_run` or its closures (`_materialize` is pinned above; the server-error
  #   open arm, #1714, is skipped), none in `_interrupt_in_causes`.
  # Why: `_run` read `e.errno` through the abstract `ServerError`, and `_interrupt_in_causes` read
  #   `.cause` by name on an `Any`: 6 rows in the MySQL trim fixture (#1599 layer 2). MySQL.jl's own `param_code` over the bound `Vector{Any}`
  #   stays: typing what MySQL.jl receives is a maintainer decision.
  @testset "the MySQL statement runner and its cause walk make no dynamic call (#1599 layer 2)" begin
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    skip = (myx._materialize, myx._other_server_errno, PormG._unowned_field, Base.print_to_string)
    in_ext(s) = occursin("PormGMySQLExt.", first(split(s, "}: "; limit = 2)))
    for B in (Nothing, Vector{Any})
      @test (B, filter(in_ext, _dynamic_calls_deep(myx._run, (MySQL.Connection, String, B); depth = 3, skip))) ==
            (B, String[])
    end
    @test _dynamic_calls(myx._interrupt_in_causes, (Any, Int)) == String[]
  end

  # What: the row count core asks of a Postgres.jl result it holds untyped (`fetch`'s), at the call site
  #   (`backend_num_rows(pool, fetch(pool, sql))`, the extension probe's shape, #1771) and in the method's
  #   body; then the count itself, for the driver's `Result` and for any other value (the open arm).
  # Expected: no dynamic call at the call site or in the body, the open arm one; the same count.
  #   Also: `backend_execute` still returns the driver's `Result`, the type the fast arm names, and the
  #   affected-row count at the same call shape is static.
  # Why: the method specialized on an `Any` result and was not inlined (its own `length` was dynamic), so
  #   the call stayed a dispatch although it is the only method that matches (#1771's residue, #1599
  #   layer 2). If the statement path stopped returning `Postgres.Result`, every count would take the open
  #   arm again with no other test noticing.
  @testset "a Postgres.jl result's row count is a static call (#1599 layer 2)" begin
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    P = PormG.ConnectionPool.PostgresConnectionPool{:postgres}
    count_on(pool::Q, sql::String) where {Q} =
      PormG.backend_num_rows(pool, PormG.ConnectionPool.fetch(pool, sql))::Int
    @test _dynamic_calls(count_on, (P, String)) == String[]
    @test _dynamic_calls(PormG.backend_num_rows, (P, Any)) == String[]
    @test length(_dynamic_calls(pgx._num_rows_other, (Any,))) == 1
    @test Base.return_types(PormG.backend_execute, (P, PormG.backend_handle_type(P), String, Any)) == [Postgres.Result]
    @test _dynamic_calls(PormG.backend_num_affected_rows, (P, Any)) == String[]
    pool = PormG.ConnectionPool.PostgresConnectionPool("host=127.0.0.1 port=1 dbname=f1"; pool_size = 1, driver = :postgres)
    @test PormG.backend_num_rows(pool, [(1, "Senna"), (2, "Prost")]) == 2   # the open arm, as before
  end

  # What: the MySQL connect, `_dial`: the keywords `_connect_args` builds and the `DBInterface.connect`
  #   call that takes them.
  # Expected: the keywords are `_ConnectKeywords` (one concrete type) for every conninfo, and `_dial` makes
  #   no dynamic call. That the fixed shape builds the options the present keys built is pinned in
  #   `test_mysql_ext.jl`.
  # Why: the keywords were a `NamedTuple` built from the keys the conninfo holds, so the keyword call was
  #   dynamic, and the trimmed MySQL fixture raised `MethodError` on `kwcall` at every connect (wrapped in
  #   `PoolConnectError`, which read like a refused port): the read had never reached the server (#1599
  #   layer 2, #1775's decision 2).
  @testset "the MySQL connect hands DBInterface.connect one keyword shape (#1599 layer 2)" begin
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    P = PormG.ConnectionPool.MySQLConnectionPool
    @test isdefined(myx, :_ConnectKeywords) && isconcretetype(myx._ConnectKeywords)
    kwtypes = unique(map(T -> fieldtype(T, 4), Base.return_types(myx._connect_args, (Dict{String, String},))))
    @test isdefined(myx, :_ConnectKeywords) && kwtypes == [myx._ConnectKeywords]
    @test _dynamic_calls(myx._dial, (P,)) == String[]
  end

  # What: what MySQL.jl does with the values the MySQL extension binds: `_run` over a `Vector{_BoundValue}`,
  #   the container `_bind` returns when every value is of a kind PormG binds, followed eight calls deep,
  #   against the same over a `Vector{Any}`.
  # Expected: no dynamic call on a parameter's type (`param_code`, `param_type`, `encode_param_value!`, the
  #   long-data check) over the union, while a `Vector{Any}` still has them, which is why the union is
  #   there; a collector of such values comes back in it. That the values and their types, so the bytes
  #   MySQL.jl sends, are the same is pinned in `test_mysql_ext.jl`.
  # Why: MySQL.jl encodes each value by its type, one value at a time, so over a `Vector{Any}` every one of
  #   those calls was a dispatch per value: with the connect typed, the trimmed MySQL fixture raised
  #   `MethodError` on `param_code(::String)` at its first statement (#1599 layer 2, #1614).
  @testset "the MySQL parameters reach MySQL.jl in a closed union (#1599 layer 2)" begin
    QB = PormG.QueryBuilder
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    P = PormG.ConnectionPool.MySQLConnectionPool
    param_call(s) = occursin(r"param_code|param_type|encode_param_value!|indexed_iterate|== 0xf", s)
    @test isdefined(myx, :_BoundValue)
    B = isdefined(myx, :_BoundValue) ? Vector{myx._BoundValue} : Vector{Any}
    @test filter(param_call, _dynamic_calls_deep(myx._run, (MySQL.Connection, String, B); depth = 8)) == String[]
    @test !isempty(filter(param_call, _dynamic_calls_deep(myx._run, (MySQL.Connection, String, Vector{Any}); depth = 8)))
    pool = P("host='127.0.0.1' user='u' password='p' dbname='f1'"; pool_size = 1)
    @test typeof(myx._bind(pool, QB.PgParameterizedQuery("", Any["Monaco", 2008, nothing], 3))) === B
  end

  # What: the Postgres.jl connect, `_dial`, and its four typed arms (`_dial_shape`: a password or none,
  #   an `sslmode` or none, `options` always set).
  # Expected: `_dial` and every arm make no dynamic call, while the driver's own
  #   `DBInterface.connect(Connection, params)`, which the open arm `_dial_open` keeps for any other
  #   shape, still makes one. That the arms pass the driver's values is pinned in `test_postgres_ext.jl`.
  # Why: the driver's connect hands the keyword-only constructor `Union{Nothing, …}` values, so its
  #   keyword call was dynamic, and the trimmed Postgres.jl fixture raised `MethodError` on `kwcall` at
  #   every connect, wrapped in `PoolConnectError` (#1599 layer 2, #1614).
  @testset "the Postgres.jl connect calls the constructor at concrete keyword types (#1599 layer 2)" begin
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    CParams = Postgres.ConnectionParams
    @test isdefined(pgx, :_dial) && _dynamic_calls(pgx._dial, (CParams,)) == String[]
    @test isdefined(pgx, :_dial) &&
          _dynamic_calls(pgx._dial, (CParams, typeof(pgx._dial_shape), typeof(pgx._dial_open))) == String[]
    for pw in (String, Nothing), sm in (String, Nothing)
      @test isdefined(pgx, :_dial_shape) &&
            (pw, sm, _dynamic_calls(pgx._dial_shape, (CParams, pw, String, sm))) == (pw, sm, String[])
    end
    @test !isempty(_dynamic_calls_kw(Postgres.DBInterface.connect, (Type{Postgres.Connection}, CParams)))
  end

  # What: the result types the Postgres.jl extension registers on each new connection
  #   (`_register_types!`), followed four calls deep.
  # Expected: no dynamic call. That each entry matches what `Postgres.register_type!` builds is pinned in
  #   `test_postgres_ext.jl`.
  # Why: `register_type!` takes its parser as `Union{Function, Nothing}` and only passes it on, so it is
  #   compiled for `Function`, and the `CastFn(parser)` it builds was dynamic: once the connect was typed,
  #   the trimmed Postgres.jl fixture authenticated and then raised `MethodError` on `CastFn` while
  #   registering `_pg_numeric` (#1599 layer 2, #1614).
  @testset "the Postgres.jl result types are registered without a dynamic call (#1599 layer 2)" begin
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    @test isdefined(pgx, :_parser_entry) && _dynamic_calls_deep(pgx._register_types!, (pgx._Conn,); depth = 4) == String[]
  end

  # What: `fetch` handing a typed read's driver result to the read's decoder (`_decoded`), on a MySQL and
  #   a Postgres.jl pool: the keyword body `fetch(pool, sql; _decode = decoder)` runs.
  # Expected: each of the two extensions registers a concrete result type (`backend_result_type`), and
  #   the body makes no dynamic call to `_decoded`: it reaches `_typed_rows_decoded` at that type. A
  #   result of another type (a stand-in's) reaches `_decoded` unchanged through the open arm, and a
  #   pool whose driver is not loaded keeps the default `Any`.
  # Why: `await_result` returns the result untyped, so `_decoded(connection, raw, decode)` dispatched at
  #   run time, and against a real server the trimmed MySQL and Postgres.jl reads ran their statement
  #   and raised `MethodError: _decoded(::MySQLConnectionPool, ::MySQLResult, ::_RowDecoder{…})`
  #   (#1599 layer 2, #1614; the hand-off of #1795 and #1796).
  @testset "fetch hands a driver's result to the typed read at its concrete type (#1599 layer 2)" begin
    CP = PormG.ConnectionPool
    QB = PormG.QueryBuilder
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    T = @NamedTuple{raceid::Int64, name::String}
    D = QB._RowDecoder{T, NTuple{2, PormG.ReadParser}}
    # The dynamic calls naming `_decoded` in `fetch`'s keyword body, and how many bodies were read.
    function decode_calls(P)
      found, bodies = String[], 0
      tt = Tuple{typeof(Core.kwcall), NamedTuple{(:_decode,), Tuple{D}}, typeof(CP.fetch), P, String}
      for (ci, _) in Base.code_typed_by_type(tt; optimize = true), st in ci.code
        (st isa Expr && st.head === :invoke) || continue
        mi = st.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        startswith(string(mi.def.name), "#fetch#") || continue
        bodies += 1
        for (ci2, _) in Base.code_typed_by_type(mi.specTypes; optimize = true), (i, s2) in enumerate(ci2.code)
          (s2 isa Expr && s2.head === :call && !(_tsp_callee_type(ci2, s2.args[1]) <: Core.Builtin)) || continue
          occursin("_decoded", string(s2)) && push!(found, "$(i): $(s2)")
        end
      end
      return found, bodies
    end
    for (P, R) in ((CP.MySQLConnectionPool, myx.MySQLResult), (CP.PostgresConnectionPool{:postgres}, Postgres.Result))
      @test isdefined(PormG, :backend_result_type) && (P, PormG.backend_result_type(P)) == (P, R)
      @test isconcretetype(R)
      @test (P, decode_calls(P)) == (P, (String[], 1))
    end
    @test isdefined(PormG, :backend_result_type) && PormG.backend_result_type(_TspStandInPool) === Any
    @test isdefined(PormG, :backend_result_type) && PormG.backend_result_type(CP.SQLiteConnectionPool) === Any
    my = CP.MySQLConnectionPool("host='x'"; pool_size = 1)
    result = myx.MySQLResult(Symbol[], AbstractVector[], 0, 0, UInt64(0), "")
    boxed = Any[result, :stand_in_result]
    @test isdefined(CP, :_decoded_typed) && CP._decoded_typed(my, boxed[1], nothing) === result
    @test isdefined(CP, :_decoded_typed) && CP._decoded_typed(my, boxed[2], nothing) === :stand_in_result
  end

  # What: the typed read's decode of a MySQL result (`MySQLResult`) and a Postgres.jl one
  #   (`Postgres.Result`): `_typed_rows_decoded`, the row walk over the cells (`_typed_rows_by_cell`) and
  #   each driver's cell reader (`_MySQLCells`, `_PgCells`), followed four calls deep.
  # Expected: no dynamic call in the walk and the readers, down to the parse walks (`_mysql_parsed`,
  #   `_pg_parsed`). Not followed, so not claimed: the open arms (the column walk a result takes when its
  #   names do not hold each field once, a column or cell of a type no walk names), and the cell rules a
  #   reader hands a cell to (`_mysql_cell_at`, `_pg_cell_at`, `_typed_cell_any`), whose own rows (a
  #   refusal's text, an untyped cell's rarer conversions) are the cell rules', not this walk's. The
  #   parse walks are read one level: their parser calls are static, the parsers' bodies not claimed.
  #   That the rows, and a refusal's cell, are the column walk's is pinned in `test_mysql_ext.jl` and
  #   `test_postgres_ext.jl`.
  # Why: the column walk read the result through `Tables.columntable`, whose `NamedTuple` type is decided
  #   at run time, so the walk over it was dynamic: once the pool handed the result on typed, the trimmed
  #   reads stopped at `Tables.rowcount` (MySQL) and `Tables.buildcolumns` (Postgres.jl) (#1599 layer 6,
  #   #1614).
  @testset "a MySQL or Postgres.jl result is decoded into the row type without a dynamic call (#1599 layer 6)" begin
    QB = PormG.QueryBuilder
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    T = @NamedTuple{raceid::Int64, year::Int64, name::String, date::Dates.Date, note::Union{Nothing, String}}
    Ps = NTuple{5, PormG.ReadParser}
    skip = Any[getfield(m, n) for (m, n) in ((QB, :_typed_rows_from_table_open), (QB, :_typed_cell_any),
                                            (myx, :_mysql_cell_at), (myx, :_mysql_parsed),
                                            (pgx, :_pg_cell_at), (pgx, :_pg_parsed))
               if isdefined(m, n)]
    for R in (myx.MySQLResult, Postgres.Result)
      @test (R, _dynamic_calls_deep(QB._typed_rows_decoded, (Type{T}, R, Ps, QB._TypedReadSite);
                                    depth = 4, skip = Tuple(skip))) == (R, String[])
    end
    # The parse walks themselves, one level: each arm's parser call is static; the open arm is an `invoke`.
    @test isdefined(myx, :_mysql_parsed) && _dynamic_calls(myx._mysql_parsed, (AbstractVector, Int, PormG.ReadParser)) == String[]
    @test isdefined(pgx, :_pg_parsed) && _dynamic_calls(pgx._pg_parsed, (Any, PormG.ReadParser)) == String[]
  end

  # What: the cause walks' field read, `_unowned_field(e, field)`, and `_unowned_inner(e)` over it, on an
  #   exception typed `Any`; each type `_KNOWN_EXCEPTIONS` lists; the open arm.
  # Expected: neither makes a dynamic call (the open arm `_unowned_field_open` is an `invoke`, and it
  #   still calls `hasproperty`). Every listed type keeps Base's `getproperty` and `propertynames`, so
  #   its properties are its fields, and `_unowned_field` answers what `hasproperty`/`getproperty`
  #   answer, for a listed type and for any other.
  # Why: `hasproperty` on an untyped exception had no compiled target in a trimmed image, so a statement
  #   that failed on the server surfaced as `MethodError: hasproperty(::MethodError, ::Symbol)`, which
  #   replaced the error being reported (#1599 layer 2; the residue of #1795 and #1796).
  @testset "the cause walk reads a known exception's field without a dynamic call (#1599 layer 2)" begin
    @test _dynamic_calls(PormG._unowned_field, (Any, Symbol)) == String[]
    @test _dynamic_calls(PormG._unowned_inner, (Any,)) == String[]
    @test isdefined(PormG, :_unowned_field_open) &&
          !isempty(_dynamic_calls(PormG._unowned_field_open, (Any, Symbol)))
    known = isdefined(PormG, :_KNOWN_EXCEPTIONS) ? PormG._KNOWN_EXCEPTIONS : ()
    @test !isempty(known)
    for T in known
      @test (T, isconcretetype(T), which(getproperty, Tuple{T, Symbol}).module,
             which(propertynames, Tuple{T}).module) == (T, true, Base, Base)
    end
    old(e, f) = hasproperty(e, f) ? getproperty(e, f) : nothing
    driver = ErrorException("server closed the connection")
    samples = Any[PormG.StatementError("SQLite", driver), PormG.OperationalError("PostgreSQL", driver),
                  PormG.IntegrityError("MySQL", driver), PormG.QueryBuildError("no field"),
                  MethodError(+, (1, "a")), driver, ArgumentError("x"), InterruptException(), EOFError(),
                  Base.IOError("closed", -104), CapturedException(driver, Any[]),
                  PormG.PoolConnectError("SQLite", driver, "f1", 1, 0.0),   # defined after Backend.jl: the open arm
                  (cause = driver,)]                                   # not an exception at all: the open arm
    for e in samples, f in (:cause, :err, :msg, :adapter)
      @test (typeof(e), f, PormG._unowned_field(e, f) === old(e, f)) == (typeof(e), f, true)
    end
    @test PormG._unowned_inner(PormG.StatementError("SQLite", driver)) === driver
  end

  # What: each driver extension's interrupt walk (`_interrupt_in_causes`), on an exception typed `Any`,
  #   followed four calls deep, core's open arm `_unowned_field_open` not followed; and the SQLite lock
  #   check (`_is_sqlite_locked_error`) on an exception typed `Any`.
  # Expected: no dynamic call in either walk: the driver's own errors (`MySQL.Protocol.Error`,
  #   `StmtError`, `ProtocolError`, `TimeoutError`; `Postgres.Error`, `PostgresInterfaceError`) are read at
  #   their types (`_driver_cause`), and the lock check reads any exception SQLite does not own through
  #   core's `_unowned_string` (pinned below), answering as `string(e)` did over messages that test the
  #   escape rule (a newline, a quote, a `$`, an invalid byte, a tab, an escape whose hex digits start the
  #   phrase), and `false` for a `MethodError` (decided on #1799).
  # Why: core's walk does not know the driver's errors, so a statement the server refused reached its open
  #   arm's `hasproperty`, which had no code in a trimmed image: the trimmed MySQL and Postgres.jl reads
  #   surfaced a missing table as `StatementError(cause = MethodError: hasproperty(::StmtError, …))`. The
  #   lock check's `string(e)` had none either, so a non-SQLite error on SQLite's worker became a
  #   `MethodError` (#1599, #1794's residue).
  @testset "the drivers' error paths read their own exceptions at their types (#1599 layer 2)" begin
    myx = Base.get_extension(PormG, :PormGMySQLExt)
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    slx = Base.get_extension(PormG, :PormGSQLiteExt)
    skip = isdefined(PormG, :_unowned_field_open) ? (PormG._unowned_field_open,) : ()
    for X in (myx, pgx)
      @test (X, _dynamic_calls_deep(X._interrupt_in_causes, (Any, Int); depth = 4, skip = skip)) == (X, String[])
    end
    @test !isdefined(slx, :_error_text)          # the lock check's own `string` arm is gone
    @test !slx._is_sqlite_locked_error(InterruptException())
    @test !slx._is_sqlite_locked_error(MethodError(identity, ("database is locked",)))   # decided on #1799
    for m in ("database is locked", "DATABASE TABLE IS LOCKED: drivers", "no such table: drivers",
              "database is\nlocked", "database is \"locked\"", "\$database is locked", "database is locked \xff",
              "database\tis locked", "database is lock\x65d", "",
              # an escape's hex digits supply the phrase's first letters in `string(e)`'s text
              "\xdatabase is locked", "\u009database is locked", "\x1database is locked")
      for e in (ErrorException(m), ArgumentError(m))
        @test (e, slx._is_sqlite_locked_error(e)) == (e, slx._is_locked_text(lowercase(string(e))))
      end
    end
  end

  # What: the classifiers' text for a value they do not own, `_unowned_string(x)` (and
  #   `_unowned_error_text` over it), on a value typed `Any`.
  # Expected: no dynamic call (the open arm `_unowned_string_open` is an `invoke`, and it still calls
  #   `string`). Every typed arm returns `string(x)` exactly (a `String`, a `SubString`, a `Symbol`, an
  #   `InterruptException`, an `ErrorException`/`ArgumentError` with a `String` message, escapes included),
  #   and so does the open arm; a `MethodError` returns `"MethodError"`, so no classifier phrase matches it
  #   (decided on #1799: its `string` prints the function and arguments through untyped `show` calls).
  # Why: `string` on an untyped value had no code in a trimmed image, so a statement-path `MethodError`
  #   reaching a classifier (SQLite's `backend_is_connection_error`, the lock check, LibPQ's, the pool's
  #   inactive-transaction check) was replaced by the classifier's own `MethodError` (#1599, #1797's
  #   hand-off).
  @testset "the classifiers read an unowned value's text at its type (#1599 layer 2)" begin
    @test _dynamic_calls(PormG._unowned_string, (Any,)) == String[]
    @test _dynamic_calls(PormG._unowned_error_text, (Any,)) == String[]
    @test isdefined(PormG, :_unowned_string_open) && !isempty(_dynamic_calls(PormG._unowned_string_open, (Any,)))
    samples = Any["Senna", SubString("Monaco GP", 1, 6), :drivers, InterruptException(),
                  ErrorException("database is closed"), ErrorException("\xdatabase is closed\n\$x"),
                  ArgumentError("disk I/O error"), ArgumentError(""),
                  PormG.QueryBuildError("no field"), 42, nothing]                     # the last three: the open arm
    for x in samples
      @test (x, PormG._unowned_string(x)) == (x, string(x))
    end
    me = MethodError(identity, ("database is closed", "disk i/o error"))
    @test PormG._unowned_string(me) == "MethodError"
    @test PormG._unowned_error_text(me) == "methoderror"
  end

  # What: the unnamed-temporal check (#1310) a comparison filter runs on SQLite and MySQL
  #   (`_refuse_unnamed_temporal` over the queue `_checking_unnamed_temporal` fills), its side walks, and the
  #   refusals it raises.
  # Expected: the queue is a `Vector{Tuple{Any,Any,String}}`, and the check over it makes no dynamic call down to
  #   the functions its walks name at a side's concrete type (`_side_walk_kind`, `_temporal_inside`,
  #   `_unnamed_side_label`, `_is_null_literal`), whose own bodies are not claimed here; each walk's one open arm
  #   is an `invoke`. The two side questions and the refusal builders take their untyped arguments
  #   unspecialized, and the remedy reads `_timestamp_remedy` at the engine's type, in the refusal.
  # Why: the queue was an `Any[]`, so each queued comparison was read back untyped and destructured through
  #   `indexed_iterate`, which a trimmed image had no code for: a `date__@gte` filter raised
  #   `MissingCodeError` in the trimmed SQLite and MySQL reads (#1599 layer 5, #1814 wall 21).
  @testset "a comparison filter's unnamed-temporal check runs at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder; K = PormG.Kernel
    @test isdefined(QB, :_PendingTemporal) && QB._PendingTemporal === Vector{Tuple{Any,Any,String}}
    skip = (QB._side_walk_kind_other, QB._null_literal_other, QB._unnamed_side_label_other,
            QB._side_walk_kind, QB._temporal_inside, QB._unnamed_side_label, QB._is_null_literal)
    @test _dynamic_calls_deep(QB._refuse_unnamed_temporal, (QB._PendingTemporal, QB.InstructionObject);
                              depth = 4, skip = skip) == String[]
    I = QB.InstructionObject
    for (f, tt) in ((QB._side_walk_kind_any, (Any, I)), (QB._null_literal_any, (Any,)), (QB._null_side, (Any,)),
                    (QB._unnamed_side, (Any, I)), (QB._temporal_inside_any, (Any, I)), (QB._held_temporal, (Any, I)),
                    (QB._unnamed_side_label_any, (Any,)), (QB._unnamed_temporal_side, (Any, Any, I)),
                    (QB._time_arithmetic_side, (Any, Any, String, I)), (QB._is_temporal_kind, (Any,)),
                    (QB._unnamed_temporal_remedy, (Any, String)), (QB._temporal_beside, (Any,)))
      @test (nameof(f), _dynamic_calls(f, tt)) == (nameof(f), String[])
    end
    @test (only(methods(QB._unnamed_temporal_side)).nospecialize, only(methods(QB._time_arithmetic_side)).nospecialize) == (3, 3)
    for name in (:_unnamed_temporal_refusal, :_time_arithmetic_refusal, :_timestamp_remedy), m in methods(getglobal(QB, name))
      # The connection (bit 0) everywhere, and the kind (bit 3) where there is one.
      @test (name, m.nospecialize) == (name, name === :_unnamed_temporal_refusal ? 9 : 1)
    end
    for C in (K.PormGSQLite, K.PormGMySQL)
      @test _dynamic_calls_deep(QB._unnamed_temporal_refusal, (C, String, String, Any); depth = 3) == String[]
      @test _dynamic_calls_deep(QB._time_arithmetic_refusal, (C, String, String); depth = 3) == String[]
    end
    # The queue's one writer stores the concrete vector, and the found answer is built without a splat.
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "expression_render.jl"), String)
    body = src[findfirst("function _checking_unnamed_temporal", src).start:findfirst("function _queue_unnamed_temporal!", src).start]
    @test occursin("pending = _PendingTemporal()", body) && !occursin("Any[]", body)
    refuse = src[findfirst("function _refuse_unnamed_temporal", src).start:findfirst("function _time_arithmetic_side", src).start]
    @test occursin("(hit[1], hit[2], op, false)", refuse) && !occursin("hit...", refuse)
  end

  # What: a bound literal's kind (`_infer_kind(::SQLText, …)`), which the check asks of a filter's value side.
  # Expected: no dynamic call: the null test and the literal's kind go through walks over the slot (`_null_literal_any`,
  #   `_literal_kind_any`), whose open arms are `invoke`s.
  # Why: called on the `Any` slot, `_is_null_literal` dispatched at run time to a body a trimmed image never compiled
  #   (it is always inlined): the trimmed SQLite and MySQL `date__@gte` reads raised `MethodError` on
  #   `_is_null_literal(::String)` once the queue was typed (#1599 layer 5).
  @testset "a bound literal's kind is read without a dynamic call (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    for P in (QB._AllKinds, QB._MeaningKinds)
      @test (P, _dynamic_calls(QB._infer_kind, (QB.SQLText, QB.InstructionObject, P))) == (P, String[])
      @test (P, _dynamic_calls(QB._literal_kind_any, (Any, P))) == (P, String[])
    end
  end

  # What: the projected-path walk over an ORDER BY term (`_collect_projected_paths!` on an `SQLOrder`), which
  #   MySQL's ordering reads for its NULL sort key (`_from_column_names`).
  # Expected: no dynamic call, and no call into the field-part walk's open arm (`_with_field_part_other`): the
  #   term's slot, an `SQLField`, is walked at its type.
  # Why: the term went through `_with_field_part_open`, which has no arm for an `SQLField`, so it reached the open
  #   arm, whose dynamic call had no compiled target: the trimmed MySQL `order_by` raised `MissingCodeError` on
  #   `_collect_part_paths!(::SQLField, …)` (#1599 layer 5). The open arm's call is behind an `invoke`, so a
  #   one-level scan alone passes on the old code; the pin reads the invoked methods too.
  @testset "an order_by term's paths are walked at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    tt = (Vector{String}, QB.SQLOrder, Int)
    @test _dynamic_calls(QB._collect_projected_paths!, tt) == String[]
    ci, _ = only(code_typed(QB._collect_projected_paths!, tt; optimize = true))
    invoked = Symbol[]
    for st in ci.code
      (st isa Expr && st.head === :invoke) || continue
      mi = st.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
      mi isa Core.MethodInstance && mi.def isa Method && push!(invoked, mi.def.name)
    end
    @test !(:_with_field_part_other in invoked) && !(:_with_field_part_open in invoked)
  end

  # What: the FROM tables' columns a MySQL `order_by` reads for its NULL sort key (`_from_column_names`): the table of
  #   a model held untyped (`_model_table_at`), a relation path's hops (`_add_hop_tables!`) and one candidate model's
  #   columns and relations (`_add_from_model!`, at `ModelType`).
  # Expected: no dynamic call in any of them; `_from_column_names` reads a candidate through the split, never through
  #   `model_table_name` on the abstract `PormGModel`.
  # Why: `model_table_name` on an abstract model dispatched at run time to a body a trimmed image never compiled (it is
  #   inlined everywhere): the trimmed MySQL `order_by` raised `MethodError` on `model_table_name(::ModelType)`
  #   (#1599 layer 5).
  @testset "the FROM columns of a MySQL order_by are read at ModelType (#1599 layer 5)" begin
    QB = PormG.QueryBuilder; K = PormG.Kernel
    @test _dynamic_calls(QB._model_table_at, (Any,)) == String[]
    @test _dynamic_calls_deep(QB._add_from_model!, (Set{String}, Vector{K.PormGModel}, PormG.Models.ModelType, Set{String});
                              depth = 3) == String[]
    for V in (Vector{SubString{String}}, Vector{String})
      @test (V, _dynamic_calls(QB._add_hop_tables!, (Set{String}, QB.SQLObjectQuery, V))) == (V, String[])
    end
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "select_nodes.jl"), String)
    body = src[findfirst("function _from_column_names", src).start:findfirst("function _add_from_model!", src).start]
    @test !occursin("Models.model_table_name(", body) && occursin("_add_from_model!(cols, candidates, m, tables)", body)
  end

  # What: an ORDER BY term's render call (`_order_term_at`, which `_render_order_terms` calls for every term).
  # Expected: both calls from `_render_order_terms` (with and without a NULL flag) and the helper's calls of
  #   `_order_term_sql` resolve statically; the helper takes the term, the connection and the flag
  #   unspecialized (bits 0, 3 and 4), and its one open arm, for a term that is not text, is an `invoke`.
  # Why: the term is held in a slot typed as a union of node types, and the keyword call built a `NamedTuple`
  #   whose type was a `UnionAll`, so both calls dispatched at run time: the trimmed Postgres.jl read's
  #   `order_by` raised `MethodError` on `_order_term_sql(::String, ::String, ::Symbol, ::PostgresConnectionPool)`
  #   (#1599 layer 5).
  @testset "an order_by term is rendered at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder; K = PormG.Kernel
    CT = fieldtype(QB.InstructionObject, :connection)
    # Skipped: the open arm, and the capability barriers MySQL's refusal reaches (`Dialect._supports_at`,
    # `_capability_error_at`), whose one dynamic call each is reviewed in their own pin. With inlining off (CI's coverage
    # run) the walk reaches them; inlined, it does not.
    D = PormG.Dialect
    @test _dynamic_calls_deep(QB._order_term_at, (Any, String, Symbol, CT, Union{Nothing,String});
                              depth = 1, skip = (QB._order_term_other, D._supports_at, D._capability_error_at)) == String[]
    @test only(methods(QB._order_term_at)).nospecialize == 1 | 8 | 16
    for V in (QB.OrderTermView, Vector{K.SQLTypeOrder})
      calls = _dynamic_calls(QB._render_order_terms, (V, QB.SQLObjectQuery, QB.InstructionObject))
      @test (V, filter(c -> occursin("_order_term", c), calls)) == (V, String[])
    end
  end

  # What: the bulk writers' error pass (`_depuration_values_bulk_insert`), which runs in the row loop's `catch` when a row
  #   fails and names the cell that cannot be formatted.
  # Expected: it reads its cell through the frame's column walk (`_bulk_cell`), never by indexing the untyped column.
  # Why: indexed directly, the column was read untyped, and a trimmed image had no code for the call: the full
  #   fixture entry's failing row raised `MethodError(getindex, (Vector{Int64}, Int64))` in place of its refusal
  #   (#1599 layer 7, #1814's residue).
  @testset "the bulk error pass runs at concrete types (#1599 layer 7, #1694)" begin
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_bulk.jl"), String)
    body = src[findfirst("function _depuration_values_bulk_insert", src).start:findfirst("function _normalize_on_conflict", src).start]
    @test occursin("_bulk_cell(_bulk_column(df, col_name), Int(index))", body)
    @test !occursin("_bulk_column(df, col_name)[index]", body)
    # The field's formatter is called through the value walk (wall 2), never through its `Function` slot on the
    # untyped cell; the walk makes no dynamic call (its open arm is an `invoke`).
    QB = PormG.QueryBuilder
    @test occursin("_depuration_format_at(model.fields[field].formatter, value)", body) && !occursin(".formatter(value)", body)
    @test _dynamic_calls(QB._depuration_format_at, (Any, Any)) == String[]
    # The refusals it raises take the cell unspecialized (wall 3). The pass's keyword body makes no dynamic call, and
    # neither do the two checks it hands a failing cell to, followed down: the expression refusal (its type name and
    # message included) and the collection refusal (into `_single_value`'s collection method).
    @test (only(methods(QB._refuse_expression_value)).nospecialize, only(methods(QB._refuse_collection)).nospecialize) == (4, 4)
    for m in methods(QB._expression_noun)
      @test (m.sig, m.nospecialize) == (m.sig, 1)
    end
    # The type's name and text go through `_type_name`/`_type_text` (their open arms, for a `Type` that is not a
    # `DataType`, are the dynamic calls they replace, and are skipped); Base's printing inside `string` is not claimed.
    open_arms = (QB._type_name_other, QB._type_text_other)
    @test _dynamic_calls_deep(QB._refuse_expression_value, (PormG.Models.ModelType, String, Any, String);
                              depth = 2, skip = open_arms) == String[]
    for F in (PormG.Models.sDateField, PormG.Models.sCharField, PormG.Models.sJSONField)
      @test (F, _dynamic_calls_deep(QB._refuse_collection, (F, String, Any, String); depth = 2, skip = open_arms)) == (F, String[])
    end
    @test (_dynamic_calls(QB._type_name, (Any,)), _dynamic_calls(QB._type_text, (Any,))) == (String[], String[])
    @test _dynamic_calls_kw(QB._depuration_values_bulk_insert,
                            (Vector{String}, Dict{String,String}, PormG.Models.ModelType, QB._BulkFrame, Int)) == String[]
  end

  # What: the bulk writers' total (`_bulk_result_at`, what `bulk_insert` returns its count through).
  # Expected: no dynamic call; `bulk_insert`'s body calls it, never `_bulk_result` on the untyped total.
  # Why: `_bulk_count_total`'s open arm makes its result untyped, so `_bulk_result` on it was a dynamic call: the trimmed
  #   MySQL `bulk_insert` raised `MethodError(_bulk_result, (Int64,))` (#1599 layer 7, #1614).
  @testset "bulk_insert on the servers runs at concrete types (#1599 layer 7, #1614)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._bulk_result_at, (Any, Nothing)) == String[]
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "execution_bulk.jl"), String)
    @test !occursin("_bulk_result(_bulk_count_total(results)", src) && occursin("_bulk_result_at(_bulk_count_total(results), nothing)", src)
    # PostgreSQL's column arrays (wall 2 on Postgres.jl): filled by a loop through `_pg_array_element_at`, never by a
    # `foreach` closure called with each cell's run-time type; the walk makes no dynamic call.
    @test !occursin("foreach((column, cell) -> push!(column, _pg_array_element(cell))", src)
    @test occursin("push!(chunk_columns[j], _pg_array_element_at(cells[j]))", src)
    @test _dynamic_calls(QB._pg_array_element_at, (Any,)) == String[]
    # Postgres.jl binds each column array (wall 3 on Postgres.jl): handed over at a concrete element type, so its
    # per-element rendering makes no dynamic call (the open arm, a vector of another kind, is skipped).
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    @test _dynamic_calls_deep(pgx._wire_array, (Vector{Any},); depth = 3, skip = (pgx._wire_text_other,)) == String[]
    @test _dynamic_calls(pgx._wire_text, (Any,)) == String[]
  end

  # What: the Postgres.jl extension's read of a timestamp's milliseconds (`_ms`), under every `timestamp`/`timestamptz`
  #   value a Postgres.jl result returns, the `RETURNING` row of a `create` included.
  # Expected: no `rpad` in it (a source pin: under the JIT the call inside `rpad` resolves, so a reflection pin passes on
  #   the old body too), and no dynamic call in its own body.
  # Why: `rpad` pads with a `Char` its signature types abstractly, and its `repeat` call had no compiled target in a
  #   trimmed image. PostgreSQL drops a fraction's trailing zeros, so a timestamp whose milliseconds ended in 0 needed the
  #   pad: the trimmed Postgres.jl `create` failed on about one write in ten, and `bulk_insert`'s step on the next
  #   (#1599 layer 2, #1614).
  @testset "the Postgres.jl timestamp read pads its milliseconds without rpad (#1599 layer 2, #1614)" begin
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    src = read(joinpath(pkgdir(PormG), "ext", "PormGPostgresExt.jl"), String)
    body = src[findfirst("_ms(fraction)", src).start:findfirst("_datetime(m) =", src).start]   # either form's definition
    @test !occursin("rpad(", body) && occursin("10^(3 - k)", body)
    @test _dynamic_calls(pgx._ms, (SubString{String},)) == String[]
  end

  # What: the cause walk (`_unowned_field`) on a `Core.MissingCodeError`, what a trimmed image raises for a call it has
  #   no code for.
  # Expected: it is one of the walk's known exceptions, so its field is read statically, never through the open arm's
  #   `hasproperty`.
  # Why: through the open arm, `hasproperty` had no compiled target either, and that `MethodError` replaced the error
  #   being reported: the trimmed Postgres.jl `create` above surfaced as `cause missed: hasproperty` (#1599, #1614).
  @testset "the cause walk reads a MissingCodeError statically (#1599, #1614)" begin
    @test Core.MissingCodeError in PormG._KNOWN_EXCEPTIONS
    @test _dynamic_calls(PormG._unowned_field, (Any, Symbol)) == String[]
  end

  # What: the WHERE `BETWEEN` arm of `_render_filter_oper` (`"date__@range" => [d1, d2]` on a model field), and the
  #   helper that binds the formatted pair (`_bind_range_value`) at the vector types a column formatter returns.
  # Expected: no dynamic `getproperty` of `:formatter` or `:type` in `_render_filter_oper` (the field is asserted out of
  #   `_operand_field`'s `Union{Nothing,AnyField}`), no dynamic `_bind_predicate_value` call there, and none in the
  #   helper or in `_bind_predicate_value` at `Vector{String}` / `Vector{Int64}`.
  # Why: over the 31-member union both slot reads were dynamic, and the formatted pair reached `_bind_predicate_value`
  #   untyped: the trimmed read stopped at `__@range` with `MethodError: getproperty(::sDateField, ::Symbol)`
  #   (#1599 layer 5).
  @testset "a __@range filter on a model field binds at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    calls = _dynamic_calls(QB._render_filter_oper, (QB.OperObject, QB.InstructionObject))
    @test !any(s -> occursin("getproperty", s) && (occursin(":formatter", s) || occursin(":type)", s)), calls)
    @test !any(s -> occursin("_bind_predicate_value", s), calls)
    @test _dynamic_calls(QB._bind_range_value, (QB.InstructionObject, String, Any)) == String[]
    @test _dynamic_calls(QB._bind_predicate_value, (QB.InstructionObject, String, Vector{String})) == String[]
    @test _dynamic_calls(QB._bind_predicate_value, (QB.InstructionObject, String, Vector{Int64})) == String[]
  end

  # What: a membership or range list's formatting (`_format_filter_value` → `_format_list_value`), over the lists a
  #   filter commonly holds, and the vector it builds from the formatted values (`_formatted_list`).
  # Expected: no dynamic call in `_format_filter_value`, in the walk, in `_format_list_at` at each list type it names,
  #   in `_formatted_list` or in `_narrowed_list` at the types it names.
  # Why: over the untyped list, `isempty` and the comprehension's iteration and `collect` dispatched at run time: the
  #   trimmed read stopped at `__@range` over a `Vector{Date}` in `isempty` (#1599 layer 5).
  @testset "a membership or range list is formatted at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._format_filter_value, (Any, Any, String)) == String[]
    @test _dynamic_calls(QB._format_list_value, (Any, Any, Bool)) == String[]
    for L in (Vector{String}, Vector{Int64}, Vector{Float64}, Vector{Dates.Date}, Vector{Dates.DateTime}, Vector{Any})
      @test (L, _dynamic_calls(QB._format_list_at, (Any, L, Bool))) == (L, String[])
    end
    @test _dynamic_calls(QB._formatted_list, (Vector{Any},)) == String[]
    for T in (String, Int64, Float64)
      @test (T, _dynamic_calls(QB._narrowed_list, (Type{T}, Vector{Any}))) == (T, String[])
    end
  end

  # What: a filter's value node for the unnamed-temporal check (`_literal_value_node`) when the value is a membership or
  #   range list.
  # Expected: no dynamic call in `_literal_value_node`, none in `_filter_value_node` at the list types it names, and an
  #   arm for each of those lists in its source (the reflection checks alone pass on the base, whose open arm is a
  #   static call too).
  # Why: a list took the open arm's run-time call to `_filter_value_node`, which a trimmed image had no target for: the
  #   read stopped at `MethodError(_filter_value_node, (Vector{Date},))` on `__@range` (#1599 layer 5).
  @testset "a filter's list value is checked at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._literal_value_node, (Any,)) == String[]
    for L in (Vector{String}, Vector{Int64}, Vector{Float64}, Vector{Dates.Date}, Vector{Dates.DateTime})
      @test (L, _dynamic_calls(QB._filter_value_node, (L,))) == (L, String[])
    end
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "filter_nodes.jl"), String)
    body = src[findfirst("function _literal_value_node(", src).start:findfirst("_literal_value_node_other(@nospecialize", src).start]
    # The open arm is a static call into `_literal_value_node_other` on the base too, so the arms are pinned by source.
    for L in ("Vector{String}", "Vector{Int64}", "Vector{Float64}", "Vector{Dates.Date}", "Vector{Dates.DateTime}")
      @test (L, occursin("x isa $(L) && return _filter_value_node(x)", body)) == (L, true)
    end
  end

  # What: queuing a `@range` filter's two bounds for the unnamed-temporal check (`_queue_unnamed_temporal!` →
  #   `_queue_range_bounds!`).
  # Expected: no dynamic call in either, nor in `_queue_range_at!` at each list type the walk names.
  # Why: `foreach` over the untyped list dispatched at run time, a call a trimmed image has no target for, on every
  #   `__@range` filter after its value node (#1599 layer 5).
  @testset "a @range filter's bounds are queued at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    P = Vector{Tuple{Any,Any,String}}
    # Only the range arm changed: with inlining off the other arm's `push!` is a call too (#1816's coverage lesson).
    @test !any(s -> occursin("foreach", s), _dynamic_calls(QB._queue_unnamed_temporal!, (P, Any, Any, String)))
    @test _dynamic_calls(QB._queue_range_bounds!, (P, Any, Any)) == String[]
    for L in (Vector{QB.SQLText}, Vector{Int64}, Vector{Float64}, Vector{Dates.Date}, Vector{Dates.DateTime})
      @test (L, _dynamic_calls(QB._queue_range_at!, (P, Any, L))) == (L, String[])
    end
  end

  # What: the kind of a pattern lookup's operand (`_pattern_operand_kind`), from `_render_filter_oper`, with the field
  #   `_operand_field` resolved (`Union{Nothing,AnyField}`) and the alias slot's union.
  # Expected: `_render_filter_oper` calls it statically; its field and alias arguments are unspecialized (bits 2 and 3);
  #   `_operand_field_kind` makes no dynamic call, and neither the field's kind nor the alias's memo key is read through
  #   one. (The CTE arm's `allequal`/`getindex` over its candidates' kinds are dynamic, and with inlining off so are a
  #   few `Base` calls on the two unspecialized arguments; neither is on a model column's path.)
  # Why: specialized on the two unions the call had no compiled target: the trimmed read stopped at `name__@icontains`
  #   with `MethodError(_pattern_operand_kind, (OperObject, sCharField, Nothing, InstructionObject))` (#1599 layer 5).
  @testset "a pattern lookup's operand kind is read at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    calls = _dynamic_calls(QB._render_filter_oper, (QB.OperObject, QB.InstructionObject))
    @test !any(s -> occursin("_pattern_operand_kind", s), calls)
    m = only(methods(QB._pattern_operand_kind))
    @test m.nospecialize & 0b0110 == 0b0110
    @test _dynamic_calls(QB._operand_field_kind, (Any,)) == String[]
    inner = _dynamic_calls(QB._pattern_operand_kind, (QB.OperObject, Any, Any, QB.InstructionObject))
    @test !any(s -> occursin("_field_kind", s) || occursin("memo_key", s) || occursin("_having_alias_kind", s), inner)
  end

  # What: a pattern lookup's render (`_render_predicate` → `_pattern_operator_sql` → the `Dialect` renderer the operator
  #   names), for every operator in `PATTERN_LOOKUP_OPERATORS`.
  # Expected: no dynamic call in `_render_predicate` (keyword body included) or in `_pattern_operator_sql` at the split
  #   engine union; `_pattern_operator_sql`'s engine argument is unspecialized (bit 2), and so is every `Dialect` method
  #   of every pattern renderer (bit 1), so a method added later without it fails here.
  # Why: specialized on the engine, `_pattern_operator_sql(::String, ::SQLiteConnectionPool, …)` had no compiled target:
  #   the trimmed read stopped at `name__@icontains` (#1599 layer 5).
  @testset "a pattern lookup renders at the split engine union (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls_kw(QB._render_predicate, (String, String, String, QB.InstructionObject)) == String[]
    @test _dynamic_calls(QB._pattern_operator_sql, (String, QB.ConnType, String, String)) == String[]
    @test only(methods(QB._pattern_operator_sql)).nospecialize & 0b10 == 0b10
    for op in QB.PATTERN_LOOKUP_OPERATORS
      f = getglobal(PormG.Dialect, Symbol(op))
      for m in methods(f)
        m.module === PormG.Dialect || continue
        @test (op, string(m.sig), m.nospecialize & 0b1) == (op, string(m.sig), 0b1)
      end
    end
  end

  # What: the SQLite extension's `pormg_lower` function, which every case-insensitive pattern lookup on SQLite calls in
  #   its SQL (`pormg_lower(col) LIKE pormg_lower(?)`): its registration and the callback SQLite calls per value.
  # Expected: `_create_sqlite_connection` registers it through `_register_pormg_lower!`, not `SQLite.register`; no dynamic
  #   call in the registration or the callback; in `_pormg_lower_return`, only the open arm's two (a value of a type
  #   the walk does not name); the callback's error path follows the loaded SQLite.jl (`udf_error` from 1.10).
  # Why: SQLite.jl's scalar callback calls the function through a `Function` slot over a `Vector{Any}`, and its error
  #   report is specialized on the error: in a trimmed image both raised, the read stopped at `name__@icontains` with a
  #   `StatementError` whose cause was `MethodError(udf_error, …)`, and the binary hung at exit (#1599 layer 5).
  @testset "pormg_lower runs at concrete types on SQLite (#1599 layer 5)" begin
    sx = Base.get_extension(PormG, :PormGSQLiteExt)
    src = read(joinpath(pkgdir(PormG), "ext", "PormGSQLiteExt.jl"), String)
    @test !occursin("SQLite.register(new_conn, _pormg_lower;", src) && occursin("_register_pormg_lower!(new_conn)", src)
    @test _dynamic_calls(sx._pormg_lower_callback, (Ptr{Cvoid}, Cint, Ptr{Ptr{Cvoid}})) == String[]
    @test _dynamic_calls(sx._register_pormg_lower!, (SQLite.DB,)) == String[]
    @test sx._SQLITE_REPORTS_UDF_ERRORS === isdefined(SQLite, :udf_error)
    open_arm = _dynamic_calls(sx._pormg_lower_return, (Ptr{Cvoid}, Any))
    @test length(open_arm) == 2 && occursin("_pormg_lower(", open_arm[1]) && occursin("sqlreturn", open_arm[2])
  end

  # What: the condition walk (`_each_condition_leaf`), which every projection and filter value is asked through (an
  #   alias, an aggregate, a window), and its vector arm (`_each_condition_leaf_in`).
  # Expected: the node argument is unspecialized (bit 2), no dynamic call in the walk but the vector arm's open
  #   `foreach`, and that one call only (the vectors it names are static).
  # Why: specialized on the node, each recursive call into an `Any` slot had no compiled target: the trimmed read
  #   stopped at `_each_condition_leaf(…, ::Int64, …)` on `"year__@gt" => F("round") + 2000` (#1599 layer 5).
  @testset "the condition walk recurses at one compiled body (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    m = only(methods(QB._each_condition_leaf, (Function, Any, Int)))
    @test m.nospecialize & 0b10 == 0b10
    @test _dynamic_calls(QB._each_condition_leaf, (typeof(identity), Any)) == String[]
    walk = _dynamic_calls(QB._each_condition_leaf, (typeof(identity), Any, Int))
    @test isempty(walk) || all(s -> occursin("foreach", s), walk)
    inner = _dynamic_calls(QB._each_condition_leaf_in, (typeof(identity), Any, Int))
    @test length(inner) == 1 && occursin("foreach", only(inner))
  end

  # What: a column right side of a filter (`"year__@gt" => F("round") + 2000`, a CTE or joined column, an `OuterRef`),
  #   rendered through `_column_rhs_sql` and joined by `_render_column_rhs`.
  # Expected: `_render_filter_oper` calls neither `_on_join_right` nor `_render_column_rhs` dynamically; neither helper
  #   makes a dynamic call; `_render_column_rhs`'s right side is unspecialized (bit 3).
  # Why: a closure over the right side's four-member union had no concrete type, and the right side's render answers
  #   untyped for an `OuterRef`: the trimmed read stopped at `_on_join_right(::var"#…"{…, FExpression}, …)` (#1599 layer 5).
  @testset "a column right side renders at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    calls = _dynamic_calls(QB._render_filter_oper, (QB.OperObject, QB.InstructionObject))
    @test !any(s -> occursin("_on_join_right", s) || occursin("_render_column_rhs", s), calls)
    U = Union{QB.FExpression,QB.OuterRefObject,QB.CTEReference,QB.JoinedReference}
    @test _dynamic_calls(QB._column_rhs_sql, (U, QB.InstructionObject)) == String[]
    @test _dynamic_calls(QB._render_column_rhs, (String, QB.OperObject, Any, QB.InstructionObject)) == String[]
    @test only(methods(QB._render_column_rhs)).nospecialize & 0b100 == 0b100
  end

  # What: an expression's left side (`_render_left_typed` → `_set_update_query_left_at` → `_set_update_query_left`).
  # Expected: no dynamic call to `_set_update_query_left` from `_render_left_typed`, none in the walk, and none in the
  #   callee at `String` (a column, the left side of `F("round") + 2000`).
  # Why: the left side arrives unspecialized, so the call dispatched at run time: the trimmed read stopped at
  #   `_set_update_query_left(::String, ::String, …)` (#1599 layer 5).
  @testset "an expression's left side renders at its type (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test !any(s -> occursin("_set_update_query_left", s),
               _dynamic_calls(QB._render_left_typed, (Any, String, QB.InstructionObject)))
    @test _dynamic_calls(QB._set_update_query_left_at, (Any, String, QB.InstructionObject)) == String[]
    @test _dynamic_calls(QB._set_update_query_left, (String, String, QB.InstructionObject)) == String[]
  end

  # What: an expression's right operand (`_render_operand_typed_at` / `_set_update_query_operand_at` → the positional
  #   bodies), and their ON-clause re-entry (`_render_operand_on_join`, `_set_update_query_operand_on_join`).
  # Expected: no dynamic call in either walk; none in the positional bodies at an `Int64` operand and a column or an
  #   expression on the left; the ON-clause re-entry calls `_on_join_right` behind `Base.inferencebarrier` (a source pin:
  #   that call is dynamic by design, so a static one cannot nest `_with_render_scope` in itself).
  # Why: the sides are untyped `FExpression` slots and `left_kind` is the `TemporalKind` union: the trimmed read stopped at
  #   the keyword calls into both bodies, and, once those were static, at an "unresolved invoke" of
  #   `_render_operand_typed(::Int64, …)`, a frame in the `_with_render_scope` recursion (#1711's class) (#1599 layer 5).
  @testset "an expression's right operand renders at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._render_operand_typed_at, (Any, Any, String, QB.InstructionObject, Any)) == String[]
    @test _dynamic_calls(QB._set_update_query_operand_at, (Any, Any, String, QB.InstructionObject, Any)) == String[]
    # (`!==` is a call too with inlining off, the coverage lesson of #1816; it is no dispatch.)
    for L in (String, QB.FExpression)
      calls = filter(s -> !occursin(" !== ", s), _dynamic_calls(QB._set_update_query_operand, (Int64, L, String, QB.InstructionObject, Nothing)))
      @test (L, calls) == (L, String[])
    end
    # The ON-clause branch's result is converted to the declared return type, the one call left (as in `_render_left_typed`).
    @test all(s -> occursin("Base.convert(Tuple{String", s),
              _dynamic_calls(QB._render_operand_typed, (Int64, String, String, QB.InstructionObject, Nothing)))
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "expression_render.jl"), String)
    @test count("Base.inferencebarrier(_on_join_right)", src) == 2
    @test !occursin("_on_join_right(() -> _render_operand_typed(", src) && !occursin("_on_join_right(() -> _set_update_query_operand(", src)
  end

  # What: an operand's bind (`_add_typed_parameter!`, `_add_formatted_parameter!`) and the formatter family it reads
  #   (`_unranged`), the label a refusal names (`_formatter_type_label`, `_formatter_name`), a kind's numeric rank
  #   (`_numeric_rank`), and a function's column render (`_get_select_query_at`).
  # Expected: no dynamic call in any of them (`_unranged`, `_formatter_type_label`, `_formatter_name` and
  #   `_numeric_rank` take their argument unspecialized: one method each).
  # Why: each was a run-time dispatch on the trimmed read of `F("round") + 2000`, `F("round") + 1 == 19` and
  #   `Extract("date", "month") == 11`: the `sql_type` keyword's union, a `Function`-typed formatter, the abstract
  #   `CanonicalType`, a function's untyped column (#1599 layer 5).
  @testset "an expression's bind, kind and column render at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._add_typed_parameter!, (QB.InstructionObject, Int64, Union{Nothing,String})) == String[]
    @test _dynamic_calls(QB._add_formatted_parameter!, (QB.InstructionObject, Any, Union{Nothing,String})) == String[]
    for f in (QB._unranged, QB._formatter_type_label, QB._formatter_name, QB._numeric_rank)
      @test (nameof(f), length(methods(f)), _dynamic_calls(f, (Any,))) == (nameof(f), 1, String[])
    end
    @test _dynamic_calls(QB._get_select_query_at, (Any, QB.InstructionObject, Union{Nothing,String})) == String[]
  end

  # What: the uncast-JSON-key refusal over an arithmetic node's two sides and over a comparison's right operand
  #   (`_refuse_uncast_json_key`, `_refuse_json_key_right_operand`), and the carrier probe's walk (`_json_number_side_at`)
  #   with the probe's own recursion into an `FExpression` or an `SQLField`.
  # Expected: no dynamic call in the tuple and single-operand refusals, the walk, or the probe at `FExpression`/`SQLField`;
  #   the walk names every method of the probe (a method added later without an arm fails here).
  # Why: every arithmetic node and comparison asks this after it renders, over untyped sides: the trimmed read stopped at
  #   `_refuse_uncast_json_key(_JSONKeyArithmetic, ::Tuple{String,Int64}, …)` and `_json_number_side(::Int64, …)` (#1599 layer 5).
  @testset "the uncast-JSON-key refusal asks its probe at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._refuse_uncast_json_key, (QB._JSONKeyArithmetic, Tuple, QB.InstructionObject)) == String[]
    @test _dynamic_calls(QB._json_number_side_at, (Any, QB.InstructionObject)) == String[]
    for T in (QB.FExpression, QB.SQLField)
      @test (T, _dynamic_calls(QB._json_number_side, (T, QB.InstructionObject))) == (T, String[])
    end
    # Every method's operand type has its arm (by source: a small method is inlined into the walk, so no `invoke` shows it).
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "json_key_refusal.jl"), String)
    walk = src[findfirst("function _json_number_side_at(", src).start:end]
    walk = walk[1:findfirst("\nend", walk).start]
    for m in methods(QB._json_number_side)
      P = m.sig.parameters[2]
      P === Any && continue
      for T in Base.uniontypes(P)
        @test (T, occursin("x isa $(nameof(T)) && return _json_number_side(x, instruc)", walk)) == (T, true)
      end
    end
  end

  # What: a date part's name read from a node (`_extract_part_at`), and the values a node's `kwargs` hold compared with a
  #   string (`_kwarg_is`).
  # Expected: no dynamic call in either, and none in `_temporal_row_of` (the `Extract` arm: the part's row and name).
  # Why: `Dialect.extract_part` over the untyped part, the `lowercase` of its answer, and `==` over an untyped value
  #   dispatched at run time: `Extract("date", "month") == 11` and `"date__@year" => 2008` stopped there (#1599 layer 5).
  @testset "a node's part and keyword values are read at their types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._extract_part_at, (Any,)) == String[]
    @test _dynamic_calls(QB._kwarg_is, (Dict{String,Any}, String, String)) == String[]
    @test all(s -> occursin("\"YYYY-MM\"", s), _dynamic_calls(QB._temporal_row_of, (QB.FObject,)))
  end

  # What: an expression's kind (`_expression_kind`), and the readers that took `_infer_kind` on an untyped value: they
  #   call the walk (`_infer_kind_any`) now; and the kind classifiers asked of an abstract kind (`_temporal_hint`,
  #   `_temporal_mix_class`, `_kind_formatter_at`).
  # Expected: `_expression_kind` is one unspecialized method with no dynamic call; no `_infer_kind(` call outside its
  #   methods and the walk but the one open arm (`_agreeing_kind_other`), by source; the classifiers make none.
  # Why: a function's untyped column and an abstract `CanonicalType` reached them from every function render:
  #   `_expression_kind(::String, …)`, `_temporal_hint(::CDate)`, `_infer_kind(::SQLText, …)`,
  #   `_temporal_mix_class(::CInt64)` and `_kind_formatter(::CInt64, …)` each stopped the trimmed read (#1599 layer 5).
  @testset "an expression's kind is read through the walks (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    m = only(methods(QB._expression_kind))
    @test m.nospecialize & 0b1 == 0b1
    @test _dynamic_calls(QB._expression_kind, (Any, QB.InstructionObject)) == String[]
    for (f, tt) in ((QB._temporal_hint, (Any,)), (QB._temporal_mix_class, (Any,)), (QB._kind_formatter_at, (Any, QB.InstructionObject)))
      @test (nameof(f), _dynamic_calls(f, tt)) == (nameof(f), String[])
    end
    @test length(methods(QB._temporal_hint)) == 1 && length(methods(QB._temporal_mix_class)) == 1
    direct = String[]
    for f in readdir(joinpath(pkgdir(PormG), "src", "querybuilder"); join = true)
      for (i, line) in enumerate(eachline(f))
        occursin(r"(?<![A-Za-z_])_infer_kind\(", line) || continue
        occursin(r"_infer_kind\((p|x)?::|function _infer_kind|x isa .* && return _infer_kind\(x", line) && continue
        occursin(r"^\s*#", line) && continue
        push!(direct, string(basename(f), ":", i))
      end
    end
    @test length(direct) == 1 && startswith(only(direct), "expression_kind.jl")
  end

  # What: a function's render: its column handed to the renderer ladder (`_function_sql`), its options read
  #   (`Dialect.FnOptions`), its rules by name (`_result_rule_by_name`, `_operand_domain_by_name`), its column rendered
  #   (`_get_select_query_at`), and a `Case`'s branches (`_render_case_branches_at`).
  # Expected: no dynamic call in any; the rule ladders name every rule a `Val` method states.
  # Why: a column held untyped, an option read as an abstract `AbstractString`, a `Val` built from a name at run time:
  #   each stopped the trimmed read of `Extract("date", "month") == 11` or a `Case` (#1599 layer 5).
  @testset "a function renders at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._function_sql, (String, Any, Dict{String,Any}, QB._SQLEngine)) == String[]
    @test _dynamic_calls(PormG.Dialect.FnOptions, (Dict{String,Any},)) == String[]
    for (f, rule) in ((QB._result_rule_by_name, QB._result_rule), (QB._operand_domain_by_name, QB._operand_domain))
      @test (nameof(f), _dynamic_calls(f, (String,))) == (nameof(f), String[])
      for m in methods(rule)
        P = Base.unwrap_unionall(m.sig).parameters
        (length(P) == 2 && P[2] isa DataType && P[2] <: Val && length(P[2].parameters) == 1) || continue
        n = String(P[2].parameters[1])
        @test (n, f(n)) == (n, rule(Val(Symbol(n))))
      end
    end
    @test _dynamic_calls(QB._render_case_branches_at, (Any, QB.InstructionObject, Union{Nothing,String})) == String[]
  end

  # What: a filter's construction over a function (`_check_function` on an `FObject` and an `OperObject`, through the
  #   column walk `_check_operands_at`) and the error a pair raises (`_in_pair`).
  # Expected: no dynamic call in any of them; `_in_pair`'s error argument is unspecialized.
  # Why: `_fresh_operands` and `_check_function` over an untyped column, and the keyword constructors over untyped
  #   values, dispatched at run time; `_in_pair` specialized on the caught error raised its own `MethodError`, which
  #   replaced the one being reported (`"date__@year" => 2008`, `Case(When(…))`) (#1599 layer 5).
  @testset "a filter over a function is built at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._check_operands_at, (Any,)) == String[]
    @test _dynamic_calls(QB._check_function, (QB.FObject,)) == String[]
    @test _dynamic_calls(QB._check_function, (QB.OperObject,)) == String[]
    @test only(methods(QB._in_pair)).nospecialize & 0b1 == 0b1
    @test _dynamic_calls(QB._in_pair, (Any, String)) == String[]
  end

  # What: the sargable rewrite of a date bucket (`"date__@year" => 2008`): its field, its binds (`_bucket_bind`,
  #   `_add_parameter_at`) and its bounds (`_bucket_bounds_at`).
  # Expected: no dynamic call in the rewrite or its helpers.
  # Why: the field came back untyped from the resolvers, the binds went through a closure over a union, and the bounds
  #   helpers were called on the untyped value: each dispatched at run time (#1599 layer 5).
  @testset "a date bucket's sargable rewrite runs at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._render_sargable_date_range, (QB.OperObject, QB.InstructionObject)) == String[]
    @test _dynamic_calls(QB._bucket_bind, (QB.InstructionObject, PormG.Models.AnyField, Any, Any)) == String[]
    @test _dynamic_calls(QB._add_parameter_at, (QB.InstructionObject, Any)) == String[]
    @test _dynamic_calls(QB._bucket_bounds_at, (typeof(QB._year_bucket_bounds), Any, Bool)) == String[]
  end

  # What: a `Case`'s kind and values (`_case_kind`, `_case_then_values`, `_case_values`, `_agreeing_kind`), a null
  #   literal's test (`_is_null_literal`), a branch value's bind type (`_infer_parameter_sql_type`), and the JSON probe
  #   over a function's values (`_json_number_side(::FObject)`).
  # Expected: no dynamic call in the `Case` readers or `_is_null_literal` (its open arm's `==` over a non-`String` text
  #   excepted); `_is_null_literal` and `_infer_parameter_sql_type` take their value unspecialized; the probe iterates no
  #   untyped value.
  # Why: each read a `Case`'s untyped column or values, a run-time dispatch the trimmed read stopped at in turn
  #   (#1599 layer 5).
  @testset "a Case is read at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    for P in (QB._AllKinds, QB._MeaningKinds)
      @test (P, _dynamic_calls(QB._case_kind, (QB.FObject, QB.InstructionObject, P))) == (P, String[])
      @test (P, _dynamic_calls(QB._agreeing_kind, (QB.FObject, QB.InstructionObject, P))) == (P, String[])
    end
    @test _dynamic_calls(QB._case_then_values, (Any,)) == String[]
    @test _dynamic_calls(QB._case_values, (QB.FObject,)) == String[]
    @test all(s -> occursin("== \"NULL\"", s), _dynamic_calls(QB._is_null_literal, (Any,)))
    @test only(methods(QB._is_null_literal)).nospecialize & 0b1 == 0b1
    @test !any(s -> occursin("iterate", s), _dynamic_calls(QB._json_number_side, (QB.FObject, QB.InstructionObject)))
  end

  # What: the Postgres.jl extension's wire text for a bound membership list (`_wire_text`), which PostgreSQL binds as
  #   one array (`"name__@in" => [...]` renders `= ANY($1)`).
  # Expected: a static `invoke` of `Postgres._param` at `Vector{String}` and at `Vector{Float64}`, as at `Vector{Int64}`,
  #   and no dynamic call. (The open arm, `_wire_text_other`, is itself a static call, so "no dynamic call" alone passes
  #   on the base: the invokes are what show the arms.)
  # Why: a text list took the open arm, whose `_param(::Vector{String})` had no code in a trimmed image: the Trim
  #   workflow's Postgres.jl binary stopped at `name__@in` with `StatementError`, cause `MissingCodeError` (#1599
  #   layer 5, #1614).
  @testset "a membership list binds at its type on Postgres.jl (#1599 layer 5, #1614)" begin
    pgx = Base.get_extension(PormG, :PormGPostgresExt)
    ci, _ = only(InteractiveUtils.code_typed(pgx._wire_text, (Any,); optimize = true))
    invoked = Set{Any}()
    for st in ci.code
      (st isa Expr && st.head === :invoke) || continue
      mi = st.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
      push!(invoked, mi.specTypes)
    end
    for L in (Vector{Int64}, Vector{String}, Vector{Float64})
      @test (L, Tuple{typeof(Postgres._param), L} in invoked) == (L, true)
    end
    @test _dynamic_calls(pgx._wire_text, (Any,)) == String[]
  end

  # What: the MySQL declared-output check (`_mysql_declared_output`), which every `Case`, `Coalesce`, `Greatest`, `Least`,
  #   `NullIf` and `Cast` render asks on an engine that stores an interval as its count or casts to no boolean (MySQL).
  # Expected: no dynamic `collect`, `any` or `all` over the operand kinds; the kinds walk itself makes no dynamic call.
  #   (What stays dynamic, `isempty`/`_declared_kind` over an untyped declared type, is after the early return for an
  #   undeclared node.)
  # Why: the filtered comprehension built `Iterators.Filter` at run time: the trimmed MySQL binary stopped at
  #   `"round__@gte" => Case(…)` with `MethodError`, missed `UnionAll` (#1599 layer 5, Trim run 44290558739).
  @testset "the MySQL declared-output check reads its operand kinds at one type (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    calls = _dynamic_calls(QB._mysql_declared_output, (QB.FObject, QB.InstructionObject))
    @test !any(s -> occursin(r"collect|Filter|\.any\(|\.all\(", s), calls)
    @test _dynamic_calls(QB._non_null_operand_kinds, (Any, QB.InstructionObject)) == String[]
  end

  # What: the insert map of a copied query (`_copy_insert`), which every copying terminal (`bulk_update`'s `deepcopy` of
  #   its handler) goes through.
  # Expected: `deepcopy(::SQLObjectQuery)` copies the map through `_copy_insert` (only its open arm, `_copy_insert_other`,
  #   deep-copies it), and `_copy_insert` makes no dynamic call. Since #1599 layer 5 (the joins slice) the copy's body
  #   is `_query_copy`, which `.with()`'s one-level copy shares, so the map's copy is read there.
  # Why: `deepcopy` walked the map's fields generically: the trimmed `bulk_update` stopped at
  #   `deepcopy_internal(::Vector{Int32}, …)` (#1599 layer 7, #1694).
  @testset "a copied query's insert map is copied without the generic walk (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    OD = PormG.OrderedCollections.OrderedDict{String,Any}
    invokes(f, T) = begin
      ci, _ = only(InteractiveUtils.code_typed(f, T; optimize = true))
      invoked = Any[]
      for st in ci.code
        (st isa Expr && st.head === :invoke) || continue
        mi = st.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
        push!(invoked, mi.specTypes)
      end
      invoked
    end
    # `_query_copy` takes the copied ORDER BY terms as an optional third argument since #1599 layer 5 (`nothing`: copied here).
    @test Tuple{typeof(QB._query_copy), QB.SQLObjectQuery, Nothing, Nothing} in invokes(Base.deepcopy, (QB.SQLObjectQuery,))
    # the base reached the map through `deepcopy_internal(::Any, …)`
    @test Tuple{typeof(QB._copy_insert), OD} in invokes(QB._query_copy, (QB.SQLObjectQuery, Nothing, Nothing))
    @test _dynamic_calls(QB._copy_insert, (OD,)) == String[]
  end

  # What: `bulk_update`'s pipeline after its frame (`_bulk_update_frame`), at the types the call hands it, and the
  #   duplicate-key check (`_ensure_unique_bulk_update_keys!`).
  # Expected: no dynamic call in either; and in the frame pipeline's callees, two levels down, no untyped
  #   comprehension, no `push!` on a boxed vector and no untyped total. (What stays dynamic there is off the fixture's
  #   path: a static `filters=` pair and the dry-run `show_query` arm.)
  # Why: over an unspecialized source the frame call, then the chunk loop's open closure type (abstract comprehensions,
  #   a boxed `columns`/`rows`, a captured three-way collector), then the tuple keys were walls one after another in the
  #   trimmed `bulk_update` (#1599 layer 7, #1694).
  @testset "bulk_update's frame pipeline and key check make their calls statically (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    tt = (QB.ObjectHandler, PormG.Models.ModelType, PormG.Configuration.Settings, PormG.ConnectionPool.SQLiteConnectionPool,
          QB._BulkFrame, Vector{Union{String, Pair{String, String}}}, Vector{String},
          Vector{Union{String, Pair{String, <:Any}}}, Symbol, Int)
    @test _dynamic_calls(QB._bulk_update_frame, tt) == String[]
    deep = _dynamic_calls_deep(QB._bulk_update_frame, tt; depth = 2, skip = (Base.deepcopy_internal,))
    @test !any(s -> !occursin("_bulk_result_other", s) &&   # the designed open arm of `_bulk_result_at`
                    occursin(r"_array_for|collect_to|_bulk_result\(|run_in_transaction|_fork_parameters", s), deep)
    # A `push!` (or any call) on a boxed capture in the pipeline's own closures: the deep list names each callee, so the
    # chunk loop's lines are the ones whose caller is a `_bulk_update_frame` closure (the review's scoping: an
    # unrelated `QueryBuilder.push!` elsewhere in the callees is not this pipeline's).
    @test !any(s -> occursin(r"^Tuple\{PormG\.QueryBuilder\.var\"#_bulk_update_frame", s) && occursin(r"push!|getfield\(.*:contents", s), deep)
    @test _dynamic_calls(QB._fork_parameters, (QB.PgParameterizedQuery,)) == String[]
    @test _dynamic_calls(QB._ensure_unique_bulk_update_keys!, (QB._BulkFrame, Dict{String,String}, Vector{String})) == String[]
  end

  # What: the upserts' lookup and defaults pairs (`_normalize_uoc_pairs`) and their fill of the insert map
  #   (`_put_insert!`), and the two entry points' bodies.
  # Expected: the pairs come back as `Vector{Pair{String,Any}}`; the fill and both keyword bodies make no dynamic call.
  # Why: a `Vector{Pair}` held keys and values untyped, so `k => v` was a `UnionAll` call and `insert[k] = v` a dynamic
  #   `setindex!`: the trimmed `update_or_create`/`get_or_create` stopped at each (#1599 layer 7, #1694).
  @testset "an upsert's pairs and insert map are read and filled at their types (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    @test Base.return_types(QB._normalize_uoc_pairs, (Tuple{Pair{String,Int64}}, String)) == Any[Vector{Pair{String,Any}}]
    @test _dynamic_calls(QB._put_insert!, (PormG.OrderedCollections.OrderedDict{String,Any}, String, Any)) == String[]
    @test _dynamic_calls_kw(QB._update_or_create!, (QB.SQLObjectQuery, Tuple{Pair{String,Int64}})) == String[]
    @test _dynamic_calls_kw(QB._get_or_create!, (QB.SQLObjectQuery, Tuple{Pair{String,Int64}})) == String[]
  end

  # What: `update_or_create`'s run per engine (`_run_update_or_create`) and the sentinel it reads on PostgreSQL.
  # Expected: no dynamic call on SQLite and MySQL (the reads decoded as they are read, the binds and the formatter at
  #   their types, the closure's result asserted); on PostgreSQL only the stand-in pool's arm (the old read, by design)
  #   is dynamic, and `_created_flag` makes no dynamic call.
  # Why: `Tables.rowtable` on a driver result, `|>` through an untyped formatter, destructuring `run_in_transaction`'s
  #   untyped result and `false == 1` were walls in the trimmed `update_or_create` (#1599 layer 7, #1694).
  @testset "update_or_create runs at concrete types on every engine (#1599 layer 7, #1694)" begin
    QB = PormG.QueryBuilder
    rest = (PormG.Configuration.Settings, QB.SQLObjectQuery, PormG.Models.ModelType, String)
    tail = (String, Vector{String}, Symbol)
    @test _dynamic_calls(QB._run_update_or_create, (PormG.ConnectionPool.SQLiteConnectionPool, rest..., QB.SQLiteParameterizedQuery, tail...)) == String[]
    @test _dynamic_calls(QB._run_update_or_create, (PormG.ConnectionPool.MySQLConnectionPool, rest..., QB.MySQLParameterizedQuery, tail...)) == String[]
    # MySQL's reads and its zero-key check (found by the Trim workflow's MySQL job: `iszero(::Int64)`; the probe then
    # found the local closure the reads went through, called dynamically and with a `kwcall`).
    @test _dynamic_calls(QB._writes_zero_key, (PormG.OrderedCollections.OrderedDict{String,Any}, PormG.Models.ModelType, String)) == String[]
    @test _dynamic_calls(QB._mysql_target_rows, (PormG.Configuration.Settings, QB.SQLObjectQuery, PormG.Models.ModelType, Vector{String},
                                                 String, PormG.ConnectionPool.MySQLConnectionPool, QB._FieldRowDecoder, String, Bool)) == String[]
    pg = _dynamic_calls(QB._run_update_or_create, (PormG.ConnectionPool.PostgresConnectionPool{:postgres}, rest..., QB.PgParameterizedQuery, tail...))
    @test all(s -> occursin(r"rowtable|\|> first|_row_to_field_keyed_dict", s), pg)
    @test _dynamic_calls(QB._created_flag, (Any,)) == String[]
  end

  # What: a function's kind by its name (`_computed_kind_by_name` through the engine and kind walks, `_output_kind_by_name`),
  #   the operand kinds a computed number's meaning reads (`_operand_kinds_at`, `_operand_meaning`), and `_number_kind`
  #   under both policies.
  # Expected: no dynamic call in any; the ladders name every function a `Val` method of either rule states, and the
  #   kind walk names every concrete kind a `_computed_kind` method states.
  # Why: `_computed_kind(Val(Symbol(name)), …)` and `_output_kind(Val(Symbol(name)), …)` built a type from a name at run
  #   time, the meaning's operands were iterated untyped, and `_operand_meaning` dispatched on an untyped kind: each
  #   stopped the trimmed read of `Abs(F("round") - 10)` (#1599 layer 5).
  @testset "a function's kind is read by its name at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._computed_kind_by_name, (String, Symbol, Any, Any)) == String[]
    @test _dynamic_calls(QB._output_kind_by_name, (String, Symbol, Vector{Any})) == String[]
    @test _dynamic_calls(QB._operand_kinds_at, (Any, QB.InstructionObject, QB._MeaningKinds)) == String[]
    @test _dynamic_calls(QB._operand_meaning, (Any,)) == String[]
    for P in (QB._AllKinds, QB._MeaningKinds)
      @test (P, _dynamic_calls(QB._number_kind, (QB.FObject, Symbol, QB.InstructionObject, P))) == (P, String[])
    end
    stated(rule) = Set(String(Base.unwrap_unionall(m.sig).parameters[2].parameters[1]) for m in methods(rule)
                       if (V = Base.unwrap_unionall(m.sig).parameters[2]) isa DataType && V <: Val && length(V.parameters) == 1)
    names = union(stated(QB._computed_kind), stated(QB._output_kind))
    for n in names
      V = Val{Symbol(n)}
      @test (n, _dynamic_calls(QB._computed_kind_at, (V, Symbol, Any, Any))) == (n, String[])
      for E in (PormG.PormGPostgres, PormG.PormGSQLite, PormG.PormGMySQL)
        @test (n, E, _dynamic_calls(QB._computed_kind_kinds, (V, Symbol, Any, Any, Type{E}))) == (n, E, String[])
      end
    end
    # Every concrete kind a method states is walked, so no named kind falls to the `invoke` on `Any`.
    kinds = Set{Any}()
    for m in methods(QB._computed_kind)
      K = Base.unwrap_unionall(m.sig).parameters[4]
      K === Any || union!(kinds, Base.uniontypes(K))
    end
    @test kinds == Set{Any}(QB._COMPUTED_KIND_TYPES)
    # Each ladder branches on every stated name (a name with no branch would answer the fallback's kind).
    for (ladder, rule) in ((QB._computed_kind_by_name, QB._computed_kind), (QB._output_kind_by_name, QB._output_kind))
      src = string(only(code_lowered(ladder)))
      for n in stated(rule)
        @test (nameof(ladder), n, occursin("\"$(n)\"", src)) == (nameof(ladder), n, true)
      end
    end
  end

  # What: a number function's operand check (`_check_operand_domain`) over its untyped column, and the keyword calls a
  #   function's render makes at run time over a nested `F` or function, which a trimmed build roots
  #   (`_trim_render_roots`).
  # Expected: no dynamic call in the check on its success path (the refusal's label and message over the untyped operand
  #   stay run-time calls, as before); every root names exactly one method.
  # Why: the check iterated `(p.column,)` untyped (MySQL's trimmed `Abs(F("round") - 10)` stopped there); and a static
  #   call into a nested node closes the render's recursion, which inference limits, so a limited cycle kept no code for
  #   reads that ran before (`Core.MissingCodeError`, the #1711 class): those calls stay dynamic, into rooted methods
  #   (#1599 layer 5).
  @testset "a function's operands are checked at concrete types, and its nested re-entry is rooted (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._check_operand_domain, (QB.FObject, QB.InstructionObject)) == String[]
    for D in (Tuple{Symbol}, Tuple{Symbol,Symbol})
      @test (D, _dynamic_calls(QB._check_operand_domain_at, (Any, QB.FObject, D, QB.InstructionObject))) == (D, String[])
      d = _dynamic_calls(QB._check_operand_domain_one, (Any, QB.FObject, D, QB.InstructionObject))
      @test all(x -> occursin(r"_concat_operand_label|_non_number_math_refusal", x), d)
    end
    roots = QB._trim_render_roots()
    @test length(roots) == 26   # 24, and a window function's two keyword roots (#1599 layer 5, the joins slice)
    for (f, T) in roots
      @test (T, length(methods(f, Tuple{T...}))) == (T, 1)
    end
  end

  # What: `Round`'s precision read from its options (`_check_round_precision`, `_negative_places`, `_zero_places`,
  #   `_places_within`) and an aggregate's row phase (`_render_function_typed`).
  # Expected: no dynamic call in the precision checks for an `Int64` precision (any other `Integer` behind its
  #   `@noinline` arm); `_render_function_typed` opens the row phase through `_render_function_body_row`, no closure.
  # Why: `digits < 0` over the untyped precision dispatched at run time (`<(::Int64, ::Int64)`, the trimmed
  #   `Round(F("round"))`), and the row phase through `_with_render_scope` re-entered that helper from the render's own
  #   scopes, a limited call the trimmed `Count("raceid")` stopped in (#1599 layer 5).
  @testset "Round's precision and an aggregate's row phase are read at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._check_round_precision, (QB.FObject, Any, QB.InstructionObject)) == String[]
    @test _dynamic_calls(QB._check_round_precision_at, (QB.FObject, Int64, QB.InstructionObject)) |>
          d -> all(x -> occursin(r"_scale_divergent_operand|_non_number_operand|_round_text_refusal|_capability_error_at", x), d)
    for f in (QB._negative_places, QB._zero_places)
      @test (nameof(f), _dynamic_calls(f, (Any,))) == (nameof(f), String[])
    end
    @test _dynamic_calls(QB._places_within, (Any, Int)) == String[]
    # An aggregate's column: whether it can have a millisecond form (`Sum("round")` stopped at
    # `_interval_ms_candidate(::String)` over the untyped column).
    @test _dynamic_calls(QB._interval_ms_candidate_at, (Any,)) == String[]
    # The aggregate arm is static; the variadic arm (`Greatest`/`Coalesce` over intervals) keeps its two run-time calls.
    @test all(x -> occursin(r"== \"\"|all\(", x), _dynamic_calls(QB._interval_ms_candidate, (QB.FObject,)))
    # An operand's formatter over the untyped column (`Sum("round")`'s boolean-aggregate check).
    @test _dynamic_calls(QB._expression_formatter_at, (Any, QB.InstructionObject)) == String[]
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "select_nodes.jl"), String)
    body = src[findfirst("function _render_function_typed(", src).start:end]
    body = body[1:findfirst("\nend\n", body).stop]
    @test !occursin("_with_render_scope(", body)
    @test occursin("_render_function_body_row(v, instruc, _as)", body)
  end

  # What: an aggregate query's mixed-grouping check (`_check_mixed_grouping`), its fingerprint (`_mixed_node_signature`)
  #   and its column walk (`_each_bare_column_at`).
  # Expected: no dynamic call in the check; the fingerprint is a `String` and dispatches only on the rare shapes it
  #   spells with `repr` or a non-`String` text; the walk only on a non-`String` text and a list of no known element.
  # Why: the fingerprint dispatched on each untyped slot and was stored as tuples in a `Set{Any}`, and the walk's
  #   keyword call took a closure per re-entry: each stopped the trimmed `values("year", "n" => Count(…))`
  #   (#1599 layer 5).
  @testset "an aggregate query's mixed-grouping check runs at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    @test _dynamic_calls(QB._check_mixed_grouping, (QB.InstructionObject,)) == String[]
    @test Base.return_types(QB._mixed_node_signature, (Any, Int)) == Any[Union{Nothing,String}]
    @test all(x -> occursin(r"repr|String\(", x), _dynamic_calls(QB._mixed_node_signature, (Any, Int)))
    g = (c, l) -> nothing
    d = _dynamic_calls(QB._each_bare_column_at, (typeof(g), Any, QB.InstructionObject, String, Int, Union{Nothing,Set{String}}))
    @test all(x -> occursin(r"String\(|_mixed_leaf|iterate", x), d)
    @test _dynamic_calls(QB._bare_covered, (Union{Nothing,Set{String}}, Any)) == String[]
  end

  # What: a scalar `Subquery`'s render (`_render_scalar_subquery`), the readers its `built` callback runs and the two
  #   callbacks (`_ScalarSubqueryBuilt`, `_MembershipBuilt`), `Exists`' render (`_build_exists_query`), an `OuterRef`'s
  #   column (`_get_filter_query(::OuterRefObject, …)`, `_render_outer_ref_column`) and the multi-row warning's
  #   aggregate test (`_projection_is_aggregate`).
  # Expected: no dynamic call, except the nested builds' keyword calls (`query`; `build_cte_clause` and `build`), which
  #   stay run-time calls into the methods `_trim_render_roots(P)` names: every root one method, for each pool type.
  # Why: the nested builds took closures and were reached from inside the render's recursion, which inference limits
  #   (the #1711 class, so they stay dynamic, into rooted methods); and the readers, the `OuterRef` scopes, the `Exists`
  #   results and the aggregate test each dispatched on an untyped value, a call the trimmed `__@in` a queryset,
  #   `Exists(… OuterRef(…) …)` and `Subquery(… OuterRef(…) …)` stopped at (#1599 layer 5).
  @testset "a subquery's read runs at concrete types, and its nested builds are rooted (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    tt_calls(tt) = [string(i, ": ", s) for (ci, _) in Base.code_typed_by_type(tt; optimize = true) for (i, s) in enumerate(ci.code)
                    if s isa Expr && s.head === :call && !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin)]
    d = _dynamic_calls(QB._render_scalar_subquery, (QB.SubqueryObject, I))
    @test map(x -> occursin(r"Core\.kwcall\(.*QueryBuilder\.query,", x), d) == [true]
    d = _dynamic_calls(QB._build_exists_query, (QB.ObjectHandler, I))
    @test map(x -> occursin(r"Core\.kwcall\(.*QueryBuilder\.(build_cte_clause|build),", x), d) == [true, true]
    for f in (QB._subquery_projection_textless, QB._subquery_projection_whole_numeric, QB._subquery_projection_json_key,
              QB._subquery_projection_kind, QB._subquery_projection_unapplied, QB._subquery_projection_formatter)
      @test (nameof(f), _dynamic_calls(f, (QB.ObjectHandler, I))) == (nameof(f), String[])
    end
    for B in (QB._ScalarSubqueryBuilt{QB.ObjectHandler}, QB._MembershipBuilt{QB.ObjectHandler})
      @test (B, tt_calls(Tuple{B, I})) == (B, String[])
    end
    @test _dynamic_calls(QB._get_filter_query, (QB.OuterRefObject, I)) == String[]
    @test _dynamic_calls(QB._render_outer_ref_column, (String, I)) == String[]
    @test _dynamic_calls(QB._projection_is_aggregate, (Any,)) == String[]
    for P in (PormG.ConnectionPool.SQLiteConnectionPool, PormG.ConnectionPool.MySQLConnectionPool,
              PormG.ConnectionPool.PostgresConnectionPool{:postgres})
      roots = QB._trim_render_roots(P)
      @test (P, length(roots)) == (P, length(QB._trim_render_roots()) + 11)
      for (f, T) in roots
        @test (P, T, length(methods(f, Tuple{T...}))) == (P, T, 1)
        # `Core.kwcall` has one method for any `NamedTuple`, so a keyword root is also checked against its target: one
        # method for the positional arguments, declaring every keyword the root names.
        f === Core.kwcall || continue
        target = T[2].instance
        m = only(methods(target, Tuple{T[3:end]...}))
        @test (P, nameof(target), any(k -> endswith(string(k), "..."), Base.kwarg_decl(m))) == (P, nameof(target), false)
        declared = Set(Base.kwarg_decl(m))
        @test (P, nameof(target), setdiff(fieldnames(T[1]), declared)) == (P, nameof(target), Symbol[])
      end
    end
  end

  # What: `trim_entrypoints(P...)`, the one public call a trimmed app makes at its entry's top level (#1599): what it
  #   roots for each pool type (the render's roots, the driver's own, the LazyJLLWrappers roots when one is loaded), that
  #   every root names a method that exists, and that every `test/trim/` entry calls it and nothing there roots by hand.
  # Expected: `_trim_roots(P)` holds every `_trim_render_roots(P)` signature and `backend_trim_roots(P)`'s; each root
  #   resolves to a method (`which`), a keyword root to its target's positional method; Postgres.jl's SCRAM roots come
  #   from its extension and no other pool has driver roots; the entries call `PormG.trim_entrypoints(` and none of
  #   `test/trim/**/*.jl` calls `Base.Experimental.entrypoint`, `_trim_render_roots` or includes `upstream_roots`.
  # Why: a root naming a method that is gone fails silently in the build (the binary then stops at
  #   `Core.MissingCodeError`), and an entry rooting by hand would hide that the public call misses something an app
  #   needs: the fixture must build with exactly what an app gets.
  @testset "trim_entrypoints roots what the fixture rooted by hand, and only it does (#1599)" begin
    QB = PormG.QueryBuilder
    CPm = PormG.ConnectionPool
    @test :trim_entrypoints in names(PormG)
    @test PormG.trim_entrypoints(CPm.SQLiteConnectionPool) === nothing   # a no-op under the JIT
    # Refused, under the JIT too: each would build and then stop at `MissingCodeError` at run time.
    @test_throws ArgumentError PormG.trim_entrypoints()
    @test_throws ArgumentError PormG.trim_entrypoints(Int)
    @test_throws ArgumentError PormG.trim_entrypoints(CPm.PostgresConnectionPool)   # no driver parameter: no SCRAM roots
    @test_throws ArgumentError PormG.trim_entrypoints(PormG.PormGPostgres)
    lazy = Base.PkgId(Base.UUID("21706172-204c-4d4f-5420-656854206f44"), "LazyJLLWrappers")
    upstream = PormG._trim_upstream_roots()
    @test length(upstream) == 1 + haskey(Base.loaded_modules, lazy)
    @test (string, (Base.Libc.Libdl.LazyLibraryPath,)) in upstream
    for P in (CPm.SQLiteConnectionPool, CPm.MySQLConnectionPool, CPm.PostgresConnectionPool{:postgres},
              CPm.PostgresConnectionPool{:libpq})
      roots = PormG._trim_roots(P)
      @test (P, setdiff(collect(QB._trim_render_roots(P)), roots)) == (P, [])
      @test (P, setdiff(collect(PormG.backend_trim_roots(P)), roots)) == (P, [])
      @test (P, setdiff(upstream, roots)) == (P, [])
      @test (P, length(roots)) == (P, length(unique(roots)))
      for (f, T) in roots
        # A keyword root names its keywords too: a renamed keyword leaves the root on a signature no call has.
        ok = f === Core.kwcall ? hasmethod(T[2].instance, Tuple{T[3:end]...}, fieldnames(T[1])) : hasmethod(f, Tuple{T...})
        @test (P, f, T, ok) == (P, f, T, true)
      end
    end
    @test length(PormG._trim_roots(CPm.SQLiteConnectionPool, CPm.MySQLConnectionPool)) <
          length(PormG._trim_roots(CPm.SQLiteConnectionPool)) + length(PormG._trim_roots(CPm.MySQLConnectionPool))
    scram = PormG.backend_trim_roots(CPm.PostgresConnectionPool{:postgres})
    @test length(scram) == 5 && all(r -> IOBuffer in r[2], scram)
    for P in (CPm.SQLiteConnectionPool, CPm.MySQLConnectionPool, CPm.PostgresConnectionPool{:libpq})
      @test (P, PormG.backend_trim_roots(P)) == (P, ())
    end
    trim = joinpath(pkgdir(PormG), "test", "trim")
    for entry in ("main.jl", "read.jl", "fail.jl", joinpath("mysql", "main.jl"), joinpath("postgres", "main.jl"))
      @test (entry, occursin("PormG.trim_entrypoints(", read(joinpath(trim, entry), String))) == (entry, true)
    end
    by_hand = String[]
    for (dir, _, files) in walkdir(trim), f in files
      endswith(f, ".jl") || continue
      code = join((l for l in eachline(joinpath(dir, f)) if !startswith(lstrip(l), "#")), "\n")   # a comment may name them
      occursin(r"Base\.Experimental\.entrypoint|_trim_render_roots|upstream_roots|\bprecompile\(", code) &&
        push!(by_hand, relpath(joinpath(dir, f), trim))
    end
    @test by_hand == String[]
  end

  # What: the typed copy of a CTE body's tree (`_tree_copy` and its walks, #1599 layer 5), and `.with()`'s stored copy
  #   (`_cte_query_copy`) with the nested CTE bodies (`_copy_ctes`) going through it.
  # Expected: no dynamic call in any node's copy or in the walks over an untyped value; and from `_cte_query_copy` down,
  #   no call into `deepcopy`'s generic walk, except the open arm (`_tree_copy_other`, the designed dynamic call for a
  #   type outside the set) and the filter slot's own copy, unchanged here (`Base.deepcopy(::Vector{FilterNode})`, #1684).
  # Why: a CTE body projecting a `Subquery`, an `Exists`, a window, a `Case` or a mutable literal took `deepcopy`, whose
  #   walk visits each field by run-time dispatch: the trimmed `.with()` over such a body stopped inside
  #   `deepcopy_internal` (#1828 wall 4).
  @testset "a CTE body's tree is copied at each node's type (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    for T in (QB.SQLField, QB.SQLText, QB.FObject, QB.WindowFunction, QB.FExpression, QB.WindowSpec, QB.SQLOrder,
              QB.SubqueryObject, QB.ExistsObject, QB.OperObject, QB.QObject, QB.QorObject, QB.Interval)
      @test (T, _dynamic_calls(QB._tree_copy, (T,))) == (T, String[])
    end
    for (f, T) in ((QB._tree_copy_part, Any), (QB._tree_copy_value, Any), (QB._tree_copy_node, Any),
                   (QB._tree_copy_kwargs, Dict{String,Any}), (QB._tree_copy_filters, Vector{QB.FilterType}),
                   (QB._tree_copy_handler, QB.ObjectHandler), (QB._tree_copy_handler, QB.SQLObjectHandler),
                   (QB._tree_copy_order, QB.SQLObjectQuery))
      @test (nameof(f), T, _dynamic_calls(f, (T,))) == (nameof(f), T, String[])
    end
    # PormG's own frames on the way down: none dispatches at run time (Base's logging on `_query_copy`'s error path and
    # the open arms are outside the pin).
    reached = _dynamic_calls_deep(QB._cte_query_copy, (QB.ObjectHandler,); depth = 8,
                                  skip = (QB._tree_copy_other, QB._copy_insert_other, QB._store_cte_other!, Base.deepcopy))
    @test filter(x -> startswith(x, "Tuple{typeof(PormG.QueryBuilder."), reached) == String[]
    # No `deepcopy` of a projection, an ORDER BY or a nested CTE body is left on the path: the generic walk is reached
    # only through the filter slot (`deepcopy(obj.filter)`, its own typed hook) and the `Vector{String}` slots.
    calls = String[]
    for (ci, _) in Base.code_typed_by_type(Tuple{typeof(QB._query_copy), QB.SQLObjectQuery, Vector{QB.ProjectionNode},
                                                 Vector{QB.SQLTypeOrder}}; optimize = true), s in ci.code
      s isa Expr && s.head === :invoke && occursin("deepcopy", string(s.args[1])) && push!(calls, string(s.args[1]))
    end
    @test filter(c -> occursin(r"SQLTypeOrder|SQLOrder|ProjectionNode|SQLField|SQLText|ObjectHandler|CTEDict", c), calls) == String[]
    @test _dynamic_calls(QB._copy_ctes, (QB.OrderedCollections.OrderedDict{String,QB.CTEDict},)) == String[]
  end

  # What: the CTE column typing chain for a `Cast`, a `Case` and a computed column (`_declared_type`, `_case_output_field`
  #   and its branch walk, `_unify_case_fields`, `F` arithmetic's operands, `_walked_field`'s refusals, a window's
  #   column), and the kind-to-field map it ends in.
  # Expected: no dynamic call in each, at the types the chain reaches them with: the declared name read at `String`
  #   (`_declared_string`), each untyped value through a walk (`_case_value_field_at`, `_f_operand_field_at`), a field's
  #   formatter and key target read at the field's type, the refusal reasons callable structs (`_Reason`, `_TypeReason`,
  #   `_RefuseWithHint`), the engine fact through `with_pool`, and `_kind_field`'s keyword constructors at `Int`.
  # Why: the trimmed CTE read over a `Subquery` column stopped at `_kind_field(::CInt32)` (a kind held at the abstract
  #   type), and every other column shape reached one of these calls on an untyped value (#1599 layer 5).
  @testset "a CTE column is typed without a dynamic call (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    for (f, T) in ((QB._case_output_field, (QB.FObject, String, I)), (QB._case_value_field_at, (Any, String, I)),
                   (QB._f_operand_field_at, (Any, String, I, typeof(QB._refuse_case_type))),
                   (QB._f_operand_field_at, (Any, String, I, typeof(QB._no_refusal))),
                   (QB._f_expression_field, (QB.FExpression, String, I, typeof(QB._refuse_projection_type))),
                   (QB._unify_case_fields, (Vector{PormG.PormGField}, String)), (QB._is_number_field, (PormG.PormGField,)),
                   (QB._same_key_target, (PormG.PormGField, PormG.PormGField)), (QB._declared_type, (QB.FObject, I)),
                   (QB._set_field_from_sql_function, (QB.WindowFunction, String, I)),
                   (QB._set_field_from_sql_function, (QB.JoinedReference, String, I)),
                   (QB._set_field_from_sql_function, (QB.SubqueryObject, String, I)),
                   (QB._set_field_from_sql_function, (QB.FObject, String, I)),
                   (QB._walked_field, (Any, String, I, typeof(QB._refuse_case_type), QB._TypeReason)),
                   (QB._walked_field, (Any, String, I, QB._RefuseWithHint, QB._Reason)),
                   (QB._kind_field, (PormG.Kernel.CDecimal,)), (QB._kind_field, (PormG.Kernel.CVarChar,)),
                   (QB._cast_renders_text_in, (PormG.PormGField, Any)), (QB._cast_renders_text_at, (PormG.Models.sCharField, Any)), (QB._declared_string, (Any,)))
      @test (nameof(f), T, _dynamic_calls(f, T)) == (nameof(f), T, String[])
    end
    for R in (QB._TypeReason, QB._Reason)
      @test (R, [string(s) for (ci, _) in Base.code_typed_by_type(Tuple{R}; optimize = true) for s in ci.code
                 if s isa Expr && s.head === :call && !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin)]) == (R, String[])
    end
  end

  # What: what a CTE column's text is made of (`_concat_textless_operand`'s readers) for the column shapes the fixture
  #   reads: a `Case`'s branches weighed (`_case_textless_branch`), a `Value`'s literal (`_textless_literal_at`), `F`
  #   arithmetic's operands (`_textless_number_at`, `_whole_numeric_operand_at`), a function's whole operand, its declared
  #   formatter, a JSON key's side through an `OuterRef`, and `_is_null_literal`'s answer.
  # Expected: no dynamic call in each: the answers gathered into a typed vector before they are weighed, each untyped
  #   value through its walk, the declared names at `String`; the open arms (a float type PormG does not bind, another
  #   string or instruction type) behind their designed call.
  # Why: the trimmed CTE read of a `Case` column stopped at the closure of the generator `_case_textless_branch` handed
  #   `_division_first` (a `MethodError` with an `SQLText`), and the `Cast` and `F` columns reach the other calls on an
  #   untyped value (#1599 layer 5).
  @testset "a CTE column's text is read at its types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    for (f, T) in ((QB._case_textless_branch, (QB.FObject, I)), (QB._textless_literal_at, (Any,)),
                   (QB._textless_number_at, (Any, I)), (QB._whole_numeric_operand_at, (Any, I)),
                   (QB._textless_number, (QB.FExpression, I)), (QB._textless_number, (QB.FObject, I)),
                   (QB._textless_number, (QB.SQLText, I)), (QB._whole_numeric_operand, (QB.FExpression, I)),
                   (QB._whole_numeric_operand, (QB.FObject, I)), (QB._whole_numeric_operand, (QB.WindowFunction, I)),
                   (QB._concat_textless_operand, (QB.SQLText, I)), (QB._expression_formatter, (QB.FObject, I)),
                   (QB._json_number_side, (QB.OuterRefObject, I)), (QB._json_number_side, (QB.WindowFunction, I)),
                   (QB._is_null_literal, (Any,)), (QB._unapplied_declared_decimal, (Any, I)))
      @test (nameof(f), T, _dynamic_calls(f, T)) == (nameof(f), T, String[])
    end
  end

  # What: the sites that gathered a function's operands or a `Case`'s branches as `column isa AbstractVector ? column :
  #   (column,)` (#1827's list): `_all_boolean`'s caller (`_is_boolean_valued`), `_computes_number`,
  #   `_declared_stored_decimal`, `_case_default_bind_type`, `_case_output_field`, `_cast_divergent_operand`,
  #   `_scale_divergent_operand`'s scale-preserving arm, `_zero_scale_cast_textless`, `_mysql_declared_output`, and
  #   `_render_function_body`'s `Greatest`/`Least` and `NullIf` checks; and the first operand (`_first_of`).
  # Expected: no `iterate`/`_apply_iterate` over a tuple or an untyped column left in any of them: each gathers through
  #   `_append_operands!` (or reads `_first_of`), and each branch's `then` at the node's type. The per-operand checks
  #   after the gather keep their own dispatch (out of this pin).
  # Why: iterating `(column,)` or a column held untyped is a run-time `iterate`, which a trimmed image has no code for
  #   (#1827: `iterate(::Tuple{String})`).
  @testset "the operand gathers read a column at its type (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    iterates(f, T) = filter(x -> occursin(r"\biterate\(|_apply_iterate|\bfirst\(", x), _dynamic_calls(f, T))
    for (f, T) in ((QB._is_boolean_valued, (QB.FObject, I)), (QB._computes_number, (QB.FObject, I)),
                   (QB._computes_number, (QB.WindowFunction, I)), (QB._computes_number_at, (Any, I)),
                   (QB._declared_stored_decimal, (Any, I)), (QB._case_default_bind_type, (QB.FObject, Any, I)),
                   (QB._case_output_field, (QB.FObject, String, I)), (QB._cast_divergent_operand, (QB.FObject, I)),
                   (QB._zero_scale_cast_textless, (QB.FObject, String, I)), (QB._mysql_declared_output, (QB.FObject, I)),
                   (QB._infer_function_kind, (QB.FObject, I, QB._MeaningKinds)), (QB._first_of, (Any,)))
      @test (nameof(f), T, iterates(f, T)) == (nameof(f), T, String[])
    end
    # Each of these reads its operands' kinds only through the walks; no dynamic call is left at all.
    for (f, T) in ((QB._computes_number, (QB.FObject, I)), (QB._computes_number_at, (Any, I)),
                   (QB._declared_stored_decimal, (Any, I)), (QB._mysql_declared_output, (QB.FObject, I)),
                   (QB._declares_decimal, (QB.FObject, I)), (QB._function_held_temporal, (QB.FObject, I)))
      @test (nameof(f), T, _dynamic_calls(f, T)) == (nameof(f), T, String[])
    end
    # `_scale_divergent_operand`'s scale-preserving arm and `_render_function_body`'s two checks: no tuple iterated.
    src = read(joinpath(pkgdir(PormG), "src", "querybuilder", "projection_types.jl"), String) *
          read(joinpath(pkgdir(PormG), "src", "querybuilder", "select_nodes.jl"), String) *
          read(joinpath(pkgdir(PormG), "src", "querybuilder", "expression_kind.jl"), String) *
          read(joinpath(pkgdir(PormG), "src", "querybuilder", "field_resolution.jl"), String) *
          read(joinpath(pkgdir(PormG), "src", "querybuilder", "ctes.jl"), String)
    code = join((l for l in split(src, '\n') if !startswith(lstrip(l), "#")), "\n")
    # Only the two `@noinline` open arms keep the idiom (`_case_values_other!`, `_case_then_values_other`), behind their
    # designed dynamic call.
    @test length(collect(eachmatch(r"isa AbstractVector \? [a-z_.]*column : \([a-z_.]*column,\)", code))) == 2
  end

  # What: the Postgres.jl connect's URL check for a spilled password (`_checked_params`), over a URL with a query
  #   (`?sslmode=disable`), and the masking of a driver's refusal (`_mask_quoted`).
  # Expected: no `findlast`/`findprev` left on either path (a typed scan, `_last_char_index`), and the scan itself makes
  #   no dynamic call.
  # Why: Base's `findlast(c, s)` forwards to `findlast(::Function, s)`, which is not specialized on its predicate: the
  #   trimmed connect through a URL with an `sslmode` raised `MethodError` on `findprev(==('@'), ::SubString, ::Int)`
  #   (#1599 layer 2, the connection-shape step).
  @testset "a Postgres.jl URL's query is checked without a dynamic findlast (#1599 layer 2)" begin
    PG = Base.get_extension(PormG, :PormGPostgresExt)
    for T in (String, SubString{String})
      @test (T, _dynamic_calls(PG._last_char_index, (T, Char))) == (T, String[])
    end
    for (f, T) in ((PG._checked_params, (String,)), (PG._mask_quoted, (String,)))
      d = _dynamic_calls_deep(f, T; depth = 3)
      @test (nameof(f), filter(x -> occursin(r"findlast|findprev", x), d)) == (nameof(f), String[])
    end
  end

  # What: layer 7's residue (#1694): the self-referential children read from decoded rows and its key conversion, the
  #   self-referential CASCADE keys, `SET_DEFAULT`'s value, and a two-column `bulk_update` key.
  # Expected: no dynamic call in each, at the types they are reached with; the open arms (another key type, another
  #   model type, a formatted value that is not a `String`) behind their designed call.
  # Why: `_read_self_children!` read its two columns through `Tables.columntable` over an untyped result (#1377),
  #   `_self_cascade_fields` and `update_field` read `on_delete` and `formatter` on the field union, and two match
  #   columns made a tuple of a run-time length (#1599 layer 7).
  @testset "the write residue runs at its types (#1694, #1599 layer 7)" begin
    QB = PormG.QueryBuilder
    for K in (Int64, Int32, String)
      @test (K, _dynamic_calls(QB._self_children_rows, (Vector{Dict{Symbol,Any}}, Symbol, Symbol, Type{K}))) == (K, String[])
      @test (K, _dynamic_calls(QB._key_as, (Type{K}, Any))) == (K, String[])
    end
    @test _dynamic_calls(QB._self_cascade_fields, (PormG.Models.ModelType,)) == String[]
    @test _dynamic_calls(QB._value_sql, (Any,)) == String[]
    for (A, B) in ((Int64, Int64), (Int64, String), (String, Int64), (String, String))
      @test ((A, B), _dynamic_calls(QB._ensure_unique_bulk_update_key2, (Vector{A}, Vector{B}, Int, Vector{String}))) == ((A, B), String[])
    end
    # A NULL cell in the Postgres.jl decoded rows a key read takes is parsed by a static call at `Missing` (the open arm
    # called the parser at run time: `MissingCodeError` on `ReadParser(::Missing)` in the trimmed `SET_DEFAULT` delete).
    PG = Base.get_extension(PormG, :PormGPostgresExt)
    stmts = [string(st) for (ci, _) in code_typed(PG._pg_parsed, (Any, PormG.ReadParser); optimize = true) for st in ci.code]
    @test any(x -> occursin(r"===\s.*missing", x), stmts)   # the NULL arm, inlined: base had none
    d = _dynamic_calls(QB.update_field, (PormG.ConnectionPool.SQLiteConnectionPool, PormG.Models.ModelType, String,
                                         Union{Nothing,Int64}, Vector{Dict{Symbol, Union{String, PormG.SQLObjectHandler}}},
                                         Symbol, Any))
    @test filter(x -> occursin(r"formatter|getproperty|string\(", x), d) == String[]
    # The bulk writers' typed paths: a constant `filters=` predicate applied at its value's type, behind the one open
    # arm; a `columns=` entry normalized without the closure; the `filters=` loop and the work handler's copy.
    @test all(x -> occursin("_apply_static_filter_other!", x),
              _dynamic_calls(QB._apply_static_filter!, (PormG.SQLObjectHandler, Pair{String,Any})))
    @test all(x -> occursin("_norm_bulk_column_other", x), _dynamic_calls(QB._norm_bulk_column, (Any,)))
    @test filter(x -> occursin(r"_normalize_filter_pair|_check_filter|Pair\{|push!", x),
                 _dynamic_calls(QB._resolve_bulk_update_keys!, (QB._BulkFrame, PormG.PormGModel, Dict{String,String},
                                Vector{String}, Vector{String}, Vector{Union{String, Pair{String, <:Any}}}, Vector{String}))) == String[]
    @test _dynamic_calls(QB._tree_copy_handler, (PormG.SQLObjectHandler,)) == String[]
  end

  # What: the function readers a subquery's one projection reaches: its formatter over its operands
  #   (`_expression_formatter(::FObject, …)` through `_first_operand_formatter`), what `Concat` and a division make of
  #   it (`_textless_number`, `_whole_numeric_operand`) and whether it holds a temporal value (`_function_held_temporal`).
  # Expected: no dynamic call over the function's column: the one operand is read at its type and a list at its element
  #   type (`_append_operands!`); what remains is a declared type's formatter and a list of no element type the walks
  #   name, iterated at run time as before.
  # Why: each wrapped the untyped column as `(p.column,)` (or splatted it into `Any[…]`) and iterated it at run time;
  #   the trimmed `Subquery(… values("n" => Max("name")))` stopped at `iterate(::Tuple{String})`,
  #   `getindex(::Type, ::String)` and `_division_first(::Generator, …)` (#1599 layer 5).
  @testset "a function's operands are read at their types in a subquery's projection (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    @test all(x -> occursin("_declared_type_formatter", x), _dynamic_calls(QB._expression_formatter, (QB.FObject, I)))
    d = _dynamic_calls(QB._first_operand_formatter, (AbstractVector, I))
    @test map(x -> occursin("Base.iterate(", x), d) == [true, true]
    # A splat is `Core._apply_iterate`, a builtin the detector skips, so it is looked for by name.
    splats(f, T) = [s for s in only(code_typed(f, (T, I); optimize = true))[1].code
                    if s isa Expr && s.head === :call && occursin("_apply_iterate", string(s.args[1]))]
    for f in (QB._textless_number, QB._function_held_temporal), T in (QB.FObject, QB.WindowFunction)
      @test (nameof(f), T, splats(f, T)) == (nameof(f), T, Any[])
    end
    for T in (QB.FObject, QB.WindowFunction)
      @test (T, filter(x -> occursin(r"_division_first|iterate", x), _dynamic_calls(QB._textless_number, (T, I)))) == (T, String[])
      @test (T, filter(x -> occursin("iterate", x), _dynamic_calls(QB._whole_numeric_operand, (T, I)))) == (T, String[])
    end
  end

  # What: the join, CTE and window read's typed forms (#1599 layer 5): `_insert_join`'s dedup, MySQL's ORDER BY column
  #   set (`_from_column_names`, a row's `b` by `_join_b`, a CTE's columns by `_add_cte_columns!`), the CTE-name shadow check, `.with()`'s stored copy (`_preset_cte_fields`, `_cte_query_copy`),
  #   the CTE body render (`_CteBodyRender`) and its column fields (`_meant_column_field`, `field_without_db_column`).
  # Expected: no dynamic call in each, except the open arms that hand a caller's own row, handler or model type to the
  #   call it made before (`_dedup_key_other`, `_join_b_other`); the CTE body's `with_bucket` call is the render's
  #   designed dynamic re-entry and is rooted (the roots pin above), so nothing here crosses it.
  # Why: each was a run-time call the trimmed `.with(…)`/`order_by` read stopped at: the `filter` closure over the
  #   abstract rows, `hasproperty(rj, :b)`, the splatted `KeySet`, `setindex!(::CTEDict, ::Pair, …)`, `deepcopy`'s
  #   `TypeError`, the `do` closure, `_meant_column_field(::sForeignKey, …)` and `field_without_db_column(::sForeignKey)`.
  @testset "a join, a CTE and its body render at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    H = QB.ObjectHandler
    # The dedup key is read at each row's kind, a call down (the old `filter` closure made it inside `filter`).
    # The walk starts at the keyword body (`Base.bodyfunction`), where the code is; it must name exactly one method, or
    # the empty answer below would pass for the wrong reason.
    kwbody = Base.bodyfunction(only(methods(QB._insert_join)))
    kwargs_tt = (Bool, typeof(QB._insert_join), Vector{QB.JoinRow}, QB.JoinRow, I, String)
    @test length(Base.code_typed_by_type(Base.signature_type(kwbody, kwargs_tt))) == 1
    d = _dynamic_calls_deep(kwbody, kwargs_tt; depth = 4, skip = (QB._dedup_key_other, QB._dedup_alias_b_other))
    @test filter(x -> occursin(r"_dedup_key\(|\bfilter\(", x), d) == String[]
    @test filter(x -> occursin(r"hasproperty|getproperty|_add_cte_columns", x), _dynamic_calls(QB._from_column_names, (QB.SQLObject, I))) == String[]
    @test _dynamic_calls(QB._add_cte_columns!, (Set{String}, H)) == String[]
    @test filter(x -> occursin(r"hasproperty|_cte_shadow_in|_holds_identical|_push_module!|model_table_name", x),
                 _dynamic_calls(QB._cte_name_shadowed_model, (String, QB.SQLObject, H))) == String[]
    @test _dynamic_calls(QB._cte_shadow_in, (PormG.Models.ModelType, String)) == String[]
    # Each key stored at its value's type: built from three `Pair`s, the store was a run-time call inside `CTEDict`'s
    # constructor (the query's copy is pinned on its own below, so its walk is skipped, and so is the copy of the query's
    # own CTEs, `_copy_ctes`, whose store is unchanged and not this pin's).
    @test length(Base.code_typed_by_type(Base.signature_type(QB._preset_cte_fields, (String, H)))) == 1
    d = _dynamic_calls_deep(QB._preset_cte_fields, (String, H); depth = 4, skip = (Base.deepcopy, QB._cte_query_copy, QB._copy_ctes))
    @test filter(x -> occursin("setindex!", x), d) == String[]
    @test _dynamic_calls(QB._cte_query_copy, (H,)) == String[]
    # Whether the projection can be shared one level is read at each node's type.
    @test _dynamic_calls(QB._copy_shares_safely, (Any,)) == String[]
    for T in (QB.SQLField, QB.SQLText)
      @test (T, _dynamic_calls(QB._projection_shares_safely, (T,))) == (T, String[])
    end
    @test _dynamic_calls(QB._query_copy, (QB.SQLObjectQuery, Vector{QB.ProjectionNode})) == String[]
    # A CTE column's field, kind and records: the loop makes no dynamic call, and the column's record is made at its
    # expression's type (`_cte_column!`), whose readers make none either.
    @test _dynamic_calls(QB._build_cte_custom_model, (I,)) == String[]
    for T in (String, QB.FObject, QB.WindowFunction, QB.SQLText, QB.FExpression)
      @test (T, _dynamic_calls(QB._cte_column!, (T, QB._CteColumn, I))) == (T, String[])
      @test (T, _dynamic_calls(QB._record_cte_division!, (Dict{String,QB.CTEDivision}, String, T, I))) == (T, String[])
    end
    @test _dynamic_calls(QB._cte_column_path, (Any,)) == String[]
    @test _dynamic_calls(QB._meant_column_field, (PormG.PormGField, Any, Any, I)) == String[]
    @test _dynamic_calls(QB._kind_family_at, (Any,)) == String[]
    @test _dynamic_calls(QB._kind_field_at, (Any,)) == String[]
    @test filter(x -> !occursin("_with_any_field_other", x), _dynamic_calls(PormG.Models._with_any_field, (typeof(QB._field_kind), PormG.PormGField))) == String[]
    @test _dynamic_calls(PormG.Models.field_without_db_column, (PormG.PormGField,)) == String[]
    # The walk has one arm per member of the closed field set, each a static call into that type's rebuild.
    for T in Base.uniontypes(PormG.Models.AnyField)
      @test (T, _dynamic_calls(PormG.Models._field_rebuilt_without_db_column, (T,))) == (T, String[])
    end
    @test _dynamic_calls(QB._dedup_key_at, (QB.JoinRow,)) == String[]
    # What remains in `_dedup_key_equal` and `_join_b` is the open arm's comparison and its result's conversion.
    @test filter(x -> !occursin(r"==", x), _dynamic_calls(QB._dedup_key_equal, (QB.JoinRow, Any))) == String[]
    @test filter(x -> !occursin("_dedup_alias_b_other", x), _dynamic_calls(QB._dedup_alias_b, (QB.JoinRow,))) == String[]
    @test filter(x -> !occursin("Base.convert", x), _dynamic_calls(QB._join_b, (QB.JoinRow,))) == String[]
    # A window function's projection render is entered from the projection walk's recursion, so it is rooted, with
    # either keyword type, as a function's is (the trimmed `values("rk" => RowNumber(…))` had no code for it).
    for A in (Nothing, String)
      @test (A, (Core.kwcall, (NamedTuple{(:_as,),Tuple{A}}, typeof(QB._get_select_query), QB.WindowFunction, I)) in QB._trim_render_roots()) == (A, true)
    end
    for (P, Q) in ((PormG.ConnectionPool.SQLiteConnectionPool, QB.SQLiteParameterizedQuery),
                   (PormG.ConnectionPool.MySQLConnectionPool, QB.MySQLParameterizedQuery),
                   (PormG.ConnectionPool.PostgresConnectionPool{:postgres}, QB.PgParameterizedQuery))
      B = QB._CteBodyRender{H,P,Q,QB.SQLTbAlias}
      @test (P, length(Base.code_typed_by_type(Tuple{B}))) == (P, 1)
      @test (P, [string(s) for (ci, _) in Base.code_typed_by_type(Tuple{B}; optimize = true) for s in ci.code
                 if s isa Expr && s.head === :call && !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin)]) == (P, String[])
    end
  end

  # What: a cascading delete's typed forms (#1599 layer 7, #1694): whether the root has something to cascade to
  #   (`_cascade_writes`, a field's action by `_relation_on_delete`), the key read (`_resolve_root_keys!` through the
  #   untyped read's decoder, `_key_vector_rows`) and the steps after it at the keys' vector type (`_with_root_keys`,
  #   `_run_root_keys!`, `_root_key_chunks`), the collector's walk (`_find_related_objects!`, `handle_on_delete!` at the
  #   field's type, `prepare_related_query`, `_filter_in_parent!`), its model sets (`collect_fast_deletes!`,
  #   `_models_to_lock`), `delete()`'s plan runner and key step, and MySQL's derived table around a mutation's subquery.
  # Expected: no dynamic call in each, except the open arms that hand anything else to the call it made before; the
  #   nested `query` a membership filter opens is the render's designed run-time call (rooted, the roots pin above),
  #   so nothing here crosses it: the pin is on the text built from its answer.
  # Why: each was a run-time call the trimmed fixture's delete stopped at once the race had children: `fields[…]` on
  #   the abstract child model, `Tables.columntable` over the key read's result, the keys as an `AbstractVector`, the
  #   context `NamedTuple` holding `conn` at its run-time type, the plans' nested comprehension, `push!` on a set of
  #   models, and on MySQL `string("SELECT * FROM (", <nested query>, …)`.
  @testset "a cascading delete plans, reads its keys and runs at concrete types (#1599 layer 7)" begin
    QB = PormG.QueryBuilder
    MT = PormG.Models.ModelType
    PM = PormG.PormGModel
    H = QB.ObjectHandler
    E = Dict{Symbol, Union{String, QB.SQLObjectHandler}}
    K = Vector{E}
    DC = QB.DeletionCollector{Union{String, QB.SQLObjectHandler}}
    @test _dynamic_calls(QB._cascade_writes, (MT,)) == String[]
    @test filter(x -> !occursin("_relation_on_delete_other", x), _dynamic_calls(QB._relation_on_delete, (Any,))) == String[]
    # The walk: the child's query, its scope, its action and the call into `handle_on_delete!` at the field's type. What
    # stays is the multi-path `Qor` and the error messages, not this pin's.
    d = _dynamic_calls(QB._find_related_objects!, (DC, MT, K))
    @test filter(x -> occursin(r"handle_on_delete!|on_delete|_orders_deletes|resolve_delete_key|object\b|_filter_in_parent!|get!", x), d) == String[]
    for F in (PormG.Models.sForeignKey, PormG.Models.sOneToOneField)
      @test (F, _dynamic_calls(QB.handle_on_delete!, (DC, Symbol, F, PM, E, MT))) == (F, String[])
    end
    @test _dynamic_calls(QB.prepare_related_query, (E, MT, Symbol)) == String[]
    @test filter(x -> !occursin("_filter_in_parent_other!", x), _dynamic_calls(QB._filter_in_parent!, (H, String, Any))) == String[]
    @test filter(x -> occursin("push!", x), _dynamic_calls_deep(QB.collect_fast_deletes!, (DC,); depth = 2)) == String[]
    @test filter(x -> occursin("push!", x), _dynamic_calls_deep(QB._models_to_lock, (DC,); depth = 2)) == String[]
    @test filter(x -> !occursin("_narrowed_keys_other", x), _dynamic_calls(QB._key_vector_rows, (Vector{Dict{Symbol, Any}},))) == String[]
    for P in (PormG.ConnectionPool.SQLiteConnectionPool, PormG.ConnectionPool.MySQLConnectionPool,
              PormG.ConnectionPool.PostgresConnectionPool{:postgres})
      PT = Base.typesplit(only(Base.return_types(QB._root_key_plan, (P, MT, H))), Nothing)
      # The key read: one `Tables.columntable` is left, the inspection read's (`show_query`), which no trimmed fixture
      # runs; the executed read decodes its rows.
      d = _dynamic_calls(QB._resolve_root_keys!, (Vector{Any}, P, MT, PT, Symbol, Any))
      @test (P, count(x -> occursin("columntable", x), d), filter(x -> occursin("_key_vector_rows", x), d)) == (P, 1, String[])
      @test (P, only(Base.return_types(QB._root_key_chunks, (P, Vector{Int64}))), _dynamic_calls(QB._root_key_chunks, (P, Vector{Int64}))) ==
            (P, Vector{Vector{Int64}}, String[])
      # `delete()`'s closures, found by what they capture: the plan, the plan runner and the deletions.
      closure(want) = only(T for n in names(QB; all = true) if isdefined(QB, n)
                           for T in (getglobal(QB, n),) if T isa UnionAll && Base.unwrap_unionall(T) <: Function &&
                           Set(fieldnames(Base.unwrap_unionall(T))) == Set(keys(want)))
      at(T, want) = (U = Base.unwrap_unionall(T);
                     T{[want[fieldnames(U)[findfirst(t -> t === v, collect(U.types))]] for v in U.parameters]...})
      plan = at(closure(Dict(:settings => 0, :show_query => 0, :model => 0)),
                Dict(:settings => PormG.Configuration.Settings, :show_query => Symbol, :model => MT))
      run_plan = at(closure(Dict(:connection => 0, :results => 0, :deleted_counter => 0, :show_query => 0, :model => 0)),
                    Dict(:connection => P, :results => Vector{Any}, :deleted_counter => Dict{String, Integer},
                         :show_query => Symbol, :model => MT))
      deletions = at(closure(Dict(:connection => 0, :run_plan => 0, :plan => 0, :results => 0, :deleted_counter => 0,
                                  :show_query => 0, :objct => 0, :model => 0)),
                     Dict(:connection => P, :run_plan => run_plan, :plan => plan, :results => Vector{Any},
                          :deleted_counter => Dict{String, Integer}, :show_query => Symbol, :objct => H, :model => MT))
      # The plan runner reads each model to lock at `ModelType` before `objects` is read by it (the engines that lock;
      # SQLite's runner has no lock loop).
      if P !== PormG.ConnectionPool.SQLiteConnectionPool
        d = [string(s) for (ci, _) in Base.code_typed_by_type(Tuple{run_plan, Any, DC, Bool}; optimize = true) for s in ci.code
             if s isa Expr && s.head === :call && !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin)]
        @test (P, filter(x -> occursin("getindex", x), d)) == (P, String[])
      end
      # The deletions call the key step and the keyed steps at concrete types.
      d = [string(s) for (ci, _) in Base.code_typed_by_type(Tuple{deletions, Any}; optimize = true) for s in ci.code
           if s isa Expr && s.head === :call && !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin)]
      @test (P, filter(x -> occursin(r"_resolve_root_keys!|_with_root_keys", x), d)) == (P, String[])
      ctx = NamedTuple{(:results, :connection, :model, :key_plan, :objct, :show_query, :conn_box, :plan, :run_plan,
                        :deleted_counter),
                       Tuple{Vector{Any}, P, MT, PT, H, Symbol, Base.RefValue{Any}, plan, run_plan, Dict{String, Integer}}}
      @test (P, _dynamic_calls(QB._run_root_keys!, (Vector{Int64}, ctx))) == (P, String[])
      # `with_transaction` decodes a statement's rows when a caller hands it a decoder.
      Q = P === PormG.ConnectionPool.SQLiteConnectionPool ? QB.SQLiteParameterizedQuery :
          P === PormG.ConnectionPool.MySQLConnectionPool ? QB.MySQLParameterizedQuery : QB.PgParameterizedQuery
      @test (P, _dynamic_calls(QB._with_transaction_with, (P, String, Any, Bool, Q, QB._ProjectionRowDecoder))) == (P, String[])
    end
    # MySQL's derived table around a mutation's subquery: the nested `query` keyword call's answer is asserted `String`,
    # so the text built from it is static. Read in the lowered code: the pin process infers the nested build on its own
    # and finds the call static either way, where a trimmed image, which reaches it only at run time, did not.
    ci = only(code_lowered(QB._render_filter_oper, (QB.OperObject, QB.InstructionObject)))
    resolve(x) = x isa Core.SSAValue ? resolve(ci.code[x.id]) : x
    named(x, n) = (r = resolve(x); r isa GlobalRef && r.name === n)
    call(st) = st isa Expr && st.head === :call ? st : st isa Expr && st.head === :(=) ? call(st.args[2]) : nothing
    queries = [i for (i, st) in enumerate(ci.code) if (c = call(st)) !== nothing && length(c.args) >= 3 &&
               named(c.args[1], :kwcall) && named(c.args[3], :query)]
    asserted = [i for i in queries if any((c = call(st)) !== nothing && length(c.args) == 3 && named(c.args[1], :typeassert) &&
                                          c.args[2] == Core.SSAValue(i) && named(c.args[3], :String) for st in ci.code)]
    @test length(queries) == 1 && asserted == queries
  end

  # What: the SELECT render's `build` call (#1599 layer 5) and the bulk writers' upsert and returning
  #   paths (#1694, #1599 layer 7): a `bulk_insert` with its key column, `on_conflict=` and `returning=`.
  # Expected: the render asserts `build`'s answer, so its instruction is `InstructionObject` under any Julia release;
  #   the blank-key mask is read at the column's type.
  # Why: `build_cte_clause` returns `nothing` for a query without CTEs, so `build(…; cte_state = cte_state)` built a
  #   keyword tuple of a non-concrete type. Julia 1.13.3 inferred through it, 1.13.4 did not for MySQL, and every call on
  #   the render's instruction was then dynamic there (`_CteBodyRender` above failed under 1.13.4). The fixture's
  #   upsert step stopped at `map(_is_blank_bulk_primary_key_value, ::Vector{Int64})`.
  @testset "the render's build call and the bulk upsert paths run at their types (#1599 layers 5 and 7)" begin
    QB = PormG.QueryBuilder
    I = QB.InstructionObject
    D = Dict{String, QB.CTEState}
    pools = ((PormG.ConnectionPool.SQLiteConnectionPool, QB.SQLiteParameterizedQuery),
             (PormG.ConnectionPool.MySQLConnectionPool, QB.MySQLParameterizedQuery),
             (PormG.ConnectionPool.PostgresConnectionPool{:postgres}, QB.PgParameterizedQuery))
    for (P, Q) in pools
      kw = NamedTuple{(:table_alias, :connection, :parameters, :cte_body, :cte_body_correlated), Tuple{QB.SQLTbAlias, P, Q, String, Bool}}
      @test (P, Base.return_types(Core.kwcall, (kw, typeof(QB._render_select), QB.ObjectHandler))) ==
            (P, Any[NamedTuple{(:sql, :instruction), Tuple{String, I}}])
      # The render's `build` call has its answer asserted `InstructionObject`, read in the unoptimized code so the pin
      # does not depend on the release's inference or inlining: the shape 1.13.4 needs, whatever it infers for `build`.
      kwbody = Base.bodyfunction(only(methods(QB._render_select)))
      body, _ = only(Base.code_typed_by_type(Tuple{typeof(kwbody), QB.SQLTbAlias, P, Q, Nothing, Symbol, Nothing, Bool, String,
                                                   Bool, typeof(QB._render_select), QB.ObjectHandler}; optimize = false))
      closures = unique([t for t in body.ssavaluetypes if t isa DataType && t <: Function && t.name.module === QB &&
                                                         fieldcount(t) > 0 && startswith(string(t.name.name), "#")])
      @test length(closures) == 1
      m = only(Base._methods_by_ftype(Tuple{only(closures), PormG.Kernel.Settings, P, String}, -1, Base.get_world_counter())).method
      closure = Base.uncompressed_ir(m)   # the lowered body: what the source says, before any inference
      resolve(x) = x isa Core.SSAValue ? resolve(closure.code[x.id]) : x
      named(x, n) = (r = resolve(x); r isa GlobalRef && r.name === n)
      callexpr(st) = st isa Expr && st.head === :(=) ? callexpr(st.args[2]) : (st isa Expr && st.head === :call ? st : nothing)
      builds = [i for (i, st) in enumerate(closure.code) if (c = callexpr(st)) !== nothing && length(c.args) >= 3 &&
                named(c.args[1], :kwcall) && named(c.args[3], :build)]
      asserted = [i for i in builds if any((c = callexpr(st)) !== nothing && length(c.args) == 3 && named(c.args[1], :typeassert) &&
                                           c.args[2] == Core.SSAValue(i) && named(c.args[3], :InstructionObject) for st in closure.code)]
      @test (P, length(builds), asserted) == (P, 1, builds)
    end
    # The blank-key mask: no dynamic `map`/`all`/`any` in `_drop_blank_auto_primary_keys!`, and none in the mask's arms.
    @test filter(x -> occursin(r"\bmap\(|\ball\(|\bany\(", x),
                 _dynamic_calls(QB._drop_blank_auto_primary_keys!,
                                (QB._BulkFrame, PormG.Models.ModelType, Vector{String}, Dict{String, String}, Symbol))) == String[]
    for T in (Vector{Int64}, Vector{String}, Vector{Any}, Vector{Union{Missing, Int64}})
      @test (T, filter(x -> !occursin("_blank_primary_key_mask_other", x), _dynamic_calls(QB._blank_primary_key_mask, (T,)))) == (T, String[])
    end
    # The sequence reads after a write with explicit keys: each a typed read, so no `Tables.rowtable` on a result whose row
    # type is decided at run time, and SQLite's `MAX(pk)` read at its type.
    S = PormG.Kernel.Settings
    MT = PormG.Models.ModelType
    SQ = PormG.ConnectionPool.SQLiteConnectionPool
    untyped_read = r"rowtable|\|>|\bfloor\(|\btryparse\(|\bisinteger\(|\bInt64\(|\bget\("
    @test filter(x -> occursin(untyped_read, x), _dynamic_calls(QB._sqlite_has_sequence_table, (S,))) == String[]
    @test filter(x -> occursin(untyped_read, x), _dynamic_calls(QB._update_sequence, (MT, SQ, Vector{String}, S))) == String[]
    for P in (PormG.ConnectionPool.PostgresConnectionPool{:postgres}, PormG.ConnectionPool.PostgresConnectionPool{:libpq})
      @test (P, filter(x -> occursin(untyped_read, x), _dynamic_calls_kw(QB._get_owned_sequence_name, (P, MT, String)))) == (P, String[])
      @test (P, filter(x -> occursin(untyped_read, x), _dynamic_calls_kw(QB._update_sequence, (MT, P, Vector{String}, S)))) == (P, String[])
    end
    # MySQL's conflict reading of a frame: the two predicates read a column and a field at their types, and
    # `_can_conflict` calls them, not `any`/`all` over a `Function`.
    H, Mi = only(Base.return_types(QB._frame_conflict_reading, (MT, Vector{String}, Dict{String, String}, QB._BulkFrame))).parameters
    @test isconcretetype(H) && isconcretetype(Mi)
    calls_of(tt) = [string(s) for (ci, _) in Base.code_typed_by_type(tt; optimize = true) for s in ci.code
                    if s isa Expr && s.head === :call && !(_tsp_callee_type(ci, s.args[1]) <: Core.Builtin)]
    @test length(Base.code_typed_by_type(Tuple{H, String})) == 1 && length(Base.code_typed_by_type(Tuple{Mi, String})) == 1
    @test filter(x -> occursin(r"\bany\(|_has_db_default|_is_minted_value", x), calls_of(Tuple{H, String})) == String[]
    @test filter(x -> occursin(r"_is_minted_value|_is_injected_fill_column", x), calls_of(Tuple{Mi, String})) == String[]
    K = @NamedTuple{fields::Vector{String}, kind::Symbol}
    @test _dynamic_calls(QB._can_conflict, (K, H, Mi)) == String[]
    for T in (Vector{Int64}, Vector{String}, Vector{Any}, Vector{Union{Missing, Int64}})
      @test (T, filter(x -> !occursin("_bulk_column_holds_value_other", x), _dynamic_calls(QB._bulk_column_holds_value, (T,)))) == (T, String[])
    end
  end

  # What: `Q` and `Qor` over arguments of mixed types, a pair beside a nested `Q` (#1599 layer 5), and the collection of
  #   their terms (`_q_terms_of`).
  # Expected: no dynamic call in either constructor or in the collection, for each mix of argument types.
  # Why: the comprehension they used collected over a tuple of mixed types, a `Generator`/`collect` a trimmed image had no
  #   code for: the trimmed `Qor("round__@lt" => 3, Q(…))` stopped there with a `MethodError` on the `Generator`.
  @testset "Q and Qor collect their terms at each argument's type (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    # The mixes with a node beside a pair: the ones the old comprehension could not infer (a pair-only mix inferred).
    mixes = ((Pair{String, Int64}, QB.QObject), (QB.QObject, QB.QorObject, Pair{String, Int64}))
    for f in (QB.Q, QB.Qor), args in mixes
      @test (nameof(f), args, _dynamic_calls(f, args)) == (nameof(f), args, String[])
    end
    for args in mixes
      @test (args, _dynamic_calls_deep(QB._q_terms_of, (Tuple{args...},); depth = 3,
                                       skip = (QB._check_filter, QB._check_filter_node))) == (args, String[])
    end
  end

  # What: `ToChar`'s date-of-time check (`_check_tochar_date_of_time`) and the regex and unaccent renderers on an engine
  #   held `@nospecialize` (#1599 layer 5).
  # Expected: the check calls `Dialect._tochar_reads_date` at a concrete type; each renderer reaches its refusal through
  #   the barrier (`_capability_error_at`), with no dynamic call to `_capability_error` or `_regex_capability_error`.
  # Why: the check narrowed the format to `AbstractString` only, and the renderers called the capability helpers with
  #   the engine at its abstract type: a trimmed image had no code for either call, so `ToChar(…, "YYYY-MM")` stopped
  #   before any SQL, and `__@regex`/`__@iunaccent_contains` on SQLite or MySQL raised `MissingCodeError` in place of
  #   the `BackendCapabilityError` the JIT raises.
  @testset "ToChar's format check and the regex/unaccent refusals call at concrete types (#1599 layer 5)" begin
    QB = PormG.QueryBuilder
    D = PormG.Dialect
    @test filter(x -> occursin("_tochar_reads_date", x),
                 _dynamic_calls(QB._check_tochar_date_of_time, (QB.FObject, QB.InstructionObject))) == String[]
    # An engine without the feature, at its abstract type, as the renderers hold it (the PostgreSQL method is not
    # applicable, so each call has one body). The regex renderers call `_regex_capability_error`, whose own body is
    # pinned below; the unaccent renderers call the capability helper themselves.
    for E in (PormG.PormGSQLite, PormG.PormGMySQL)
      for f in (D.iunaccent_contains, D.iunaccent_exact, D.niunaccent_contains, D.niunaccent_exact)
        @test (E, nameof(f), filter(x -> occursin("capability_error", x), _dynamic_calls(f, (E, String, String)))) ==
              (E, nameof(f), String[])
      end
      @test (E, filter(x -> occursin(r"\b_capability_error\b|kwcall", x),
                       _dynamic_calls(D._regex_capability_error, (E, String)))) == (E, String[])
    end
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
