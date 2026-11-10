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
function _dynamic_calls_deep(f, argtypes::Tuple; depth::Int = 6)::Vector{String}
  found = String[]
  seen = Set{Any}()
  walk(tt, d) = begin
    tt in seen && return
    push!(seen, tt)
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

# Every statement of the optimized `f(argtypes...)` that calls `with_scope` (#1711), with whether the
# compiler resolved it, its result type and its argument types. A resolved call is an `:invoke` whose
# method instance takes `typeof(with_scope)`: the keyword wrapper (`Core.kwcall`), or the keyword body
# `#with_scope#N` once the wrapper is inlined. An unresolved one is a `:call` with `with_scope` among its
# arguments.
function _with_scope_stmts(f, argtypes::Tuple)
  ws = PormG.QueryBuilder.with_scope
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
struct _TspFakeError <: Exception end
# A pool nothing but the registry refers to, for the weak-key check (#1706).
@noinline _tsp_insert_unreferenced!(r) = (r[PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)] = [5]; nothing)
PormG.backend_error_fields(::_TspFakeError) =
  (sqlstate = "XX000", constraint = "fake_c", table = "fake_t", column = nothing, message = "fake")
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

  # What: the pool's calls into code that may be defined later than the task making them (the SQLite
  #   worker's `backend_execute`, a deferred or reaped `close`).
  # Expected: ConnectionPool.jl spells `invokelatest(` once, in `_call_latest`; the helper forwards its
  #   arguments and result and holds no dynamic call (the builtin is not one).
  # Why: six call sites each carried their own copy of the world-age reason (#1609, I11). One owner
  #   keeps the reason in one place, and the one place a trimmed build would change: `juliac --trim`
  #   does not verify the `invokelatest` builtin (#1609's trim item, still open).
  @testset "invokelatest has one owner in ConnectionPool.jl (#1609)" begin
    path = joinpath(pkgdir(PormG), "src", "ConnectionPool.jl")
    sites = [l for l in eachline(path) if occursin("invokelatest(", l) && !startswith(lstrip(l), "#")]
    @test length(sites) == 1
    @test occursin("_call_latest(", only(sites))
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

  # What: the `with_scope` calls in the SELECT list's and the ORDER BY's builders (`get_select_query`,
  #   `get_order_query`): each renders a clause under a changed `RenderScope`, in a closure.
  # Expected: no call takes its closure as a `Function`, every keyword set is a concrete type, and every
  #   call in `get_select_query` is resolved. What remains is the reviewed residue below, counted exactly
  #   (a fall fails as well as a rise, so the change that removes an entry records it). `with_scope` and
  #   `_join_scope` take the closure at a type parameter.
  # Why: `with_scope`'s keyword wrapper only passes `f` on, so Julia compiled it for `f::Function`; and
  #   `get_select_query`'s label is `Union{Nothing,String}`, which made its keyword `NamedTuple` abstract
  #   and the call fully dynamic. The trimmed fixture's `list(RaceRow)` aborted there, in a run-time type
  #   inference of that `kwcall`, once #1698 phase 1 had closed the query-state slots (#1711).
  @testset "with_scope is specialized on its closure, with a concrete keyword set (#1711)" begin
    QB = PormG.QueryBuilder
    # (unresolved calls, calls whose result is `Any`), reviewed; `with_scope` itself adds none.
    residue = Dict(
      # `build_select.jl`, the projection render (both arms of the split on the label): the closure
      # returns `_read_kind(original)`, and `original` is the projection's `SQLField.field::FieldPart`,
      # the field #1698 phase 2 closes (`_read_kind(::FieldPart)` infers `Any`).
      "get_select_query" => (0, 2),
      # the ORDER BY term's two renders (`_render_interval_operand`, `_get_select_query`). Every argument
      # of both keyword calls is concrete, and the same call inferred on its own resolves, so the
      # compiler leaves them unresolved because of where they sit; not attributed (likely inference
      # cutting short the recursion through a subquery's `build`; rebinding `order_node` in a `let`
      # changes nothing). The closures hold `order_node` in an `Any` field, so the
      # `_get_select_query(order_node, …)` render also returns `Any`.
      "get_order_query" => (2, 1),
    )
    for (f, sig) in ((QB.get_select_query, (Vector{QB.ProjectionNode}, QB.InstructionObject)),
                     (QB.get_order_query, (QB.SQLObjectQuery, QB.InstructionObject)))
      name = string(nameof(f))
      stmts = _with_scope_stmts(f, sig)
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
    # The signatures: `with_scope` and the one wrapper that only passes `f` on to it (`_join_scope`)
    # take the closure at a type parameter, so each compiles per closure type. A wrapper that calls
    # `f()` in a branch (`_on_join_right`, `_or_arm`, `_in_clause_phase`) is specialized by Julia anyway.
    for g in (QB.with_scope, QB._join_scope)
      sig = Base.unwrap_unionall(only(methods(g)).sig)
      @test sig.parameters[2] isa TypeVar
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
    # spawned task): by source, every driver call on a handle in ConnectionPool.jl and Configuration.jl
    # goes through `_with_handle`, and `close` on a handle only through its named helpers. The SQLite
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
    # Every file in src/ except AdvisoryLock.jl, whose handle calls are #1708.
    files = sort!([joinpath(root, f) for (root, _, fs) in walkdir(joinpath(pkgdir(PormG), "src")) for f in fs
                   if endswith(f, ".jl") && f != "AdvisoryLock.jl"])
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

  # What: the detector itself, on a function that does make a dynamic call.
  # Expected: it reports the call.
  # Why: a detector that never finds anything would pass every pin above for the wrong reason.
  @testset "the detector finds a call on a Function-typed value" begin
    box = Ref{Function}(isinteractive)
    f = () -> box[]()
    @test !isempty(_dynamic_calls(f, ()))
  end
end
