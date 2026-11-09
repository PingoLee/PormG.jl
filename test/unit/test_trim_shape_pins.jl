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

# A settings type of its own, which `config` no longer accepts (#1622).
struct _TspOtherSettings <: PormG.PormGSettings end
# A test's own stand-in pool, which `with_pool` hands on through its open arm.
struct _TspStandInPool <: PormG.PormGSQLite end
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

  # What: the detector itself, on a function that does make a dynamic call.
  # Expected: it reports the call.
  # Why: a detector that never finds anything would pass every pin above for the wrong reason.
  @testset "the detector finds a call on a Function-typed value" begin
    box = Ref{Function}(isinteractive)
    f = () -> box[]()
    @test !isempty(_dynamic_calls(f, ()))
  end
end
