using PrecompileTools

@setup_workload begin
  # Mock settings to allow Model and QueryBuilder compilation Without actual DB connection
  # We use a dummy PostgresConnectionPool as it's a common target
  mock_pool = ConnectionPool.PostgresConnectionPool(
    Any[],
    Bool[],
    "dummy_connection_string",
    0,
    DEFAULT_POOL_TIMEOUT,   # pool_timeout (#126, #179)
    true,                   # fail_fast_on_connect (#72)
    ReentrantLock()
  )

  mock_settings = Configuration.Settings(
    app_env = "dev",
    db_def_folder = "precompile",
    model_file = "models.jl",
    db_config_settings = Dict{String, Any}(),
    change_db = false,
    change_data = false,
    connections = mock_pool,
    time_zone = "UTC",
    django_prefix = nothing,
    implicit = false
  )

  # Register the mock settings in the global config
  config["precompile"] = mock_settings

  # Create mock environment for Configuration.load
  mktempdir() do tmpdir
    original_dir = pwd()
    cd(tmpdir) do
      # Create dummy connection files so load doesn't error or trigger Generator's interactive/long errors.
      # `adapter:`/`database:` must sit inside an environment block: written at the top level they
      # belong to no environment, so `load()` threw `MissingConfigurationError` into the `try` below
      # and this workload only ever warmed the *failure* path (#348).
      for d in ["db", "db_myapp"]
        mkdir(d)
        open(joinpath(d, "connection.yml"), "w") do f
          write(f, """
          dev:
            adapter: SQLite
            database: ":memory:"
          """)
        end
      end

      @compile_workload begin
        # 0. Precompile Configuration Loading (Mocked environment)
        try
          # `env=` explicitly: `_effective_env` lets `ENV["PORMG_ENV"]` outrank the file, so a
          # maintainer precompiling with PORMG_ENV=test exported would otherwise miss the `dev:`
          # block and land back on the swallowed-error path this fixture exists to avoid.
          Configuration.load(; env="dev")
          Configuration.load("db_myapp"; env="dev")
        catch
          # swallows any error: a precompile workload must never fail the package build, and a
          # miss here only costs compile time later.
        end

        # 1. Precompile Model Construction
        PrecompileDriver = Models.Model(
          driverId = Models.IDField(),
          forename = Models.CharField(max_length=100),
          surname = Models.CharField(max_length=100),
          points = Models.FloatField(null=true),
          dob = Models.DateField(null=true)
        )

        PrecompileConstructor = Models.Model(
          constructorId = Models.IDField(),
          name = Models.CharField(max_length=100)
        )

        PrecompileResult = Models.Model(
          resultId = Models.IDField(),
          driverId = Models.ForeignKey(PrecompileDriver, pk_field="driverId", on_delete="CASCADE"),
          constructorId = Models.ForeignKey(PrecompileConstructor, pk_field="constructorId", on_delete="RESTRICT"),
          points = Models.FloatField()
        )

        # 2. Precompile Model Setup (set_models logic)
        # We manually simulate the binding to our "precompile" config
        for m in [PrecompileDriver, PrecompileConstructor, PrecompileResult]
          m.connect_key = "precompile"
          m._module = @__MODULE__
        end

        # 3. Precompile Query Building (Expressive API)
        # `PrecompileDriver` only: the chain filters on `forename`, which `PrecompileResult` has not,
        # so its pass only ever reached the "unknown field" error inside a catch-all (#1702). The joined
        # reads over `Result` are `_offline_postgres_workload`'s, run by the PostgreSQL extensions (#1732).
        for model in [PrecompileDriver]
          # Handler creation
          q = object(model)

          # Filtering with various operators
          q.filter("forename" => "Ayrton")
          q.filter("points__@gte" => 10.0)
          q.filter(Qor("surname" => "Senna", "surname" => "Prost"))

          # Selection and Aggregation
          q.values("forename", "surname")
          q.values("forename", "count" => Functions.Count("driverId"))
          q.values("points_sum" => Functions.Sum("points"))

          # Ordering and pagination
          q.order_by("-points")
          q.limit(5).offset(10)

          # 4. Precompile SQL Generation (Internal build calls). Not in a `try`: a catch-all here
          # would keep the build green while this step warmed only an error path (#348).
          q |> show_query
        end

        # 5. Precompile Dict{Symbol,String} display path + F() expression types
        # SnoopCompile: show(Dict{Symbol,String}) hit 0.29s on cold start.
        # F() and F()*Float64 are exported and quick to trigger here.
        show(devnull, Dict{Symbol, String}(:name => "precompile"))
        F("points")
        F("points") * 1.0
      end
    end
  end

  # Cleanup mock config after precompilation is done. "db"/"db_myapp" are registered by the
  # `Configuration.load` calls above and point at a now-deleted tmpdir, so they must not be
  # serialized into the cache image alongside their pools.
  for k in ("precompile", "db", "db_myapp")
    s = get(config, k, nothing)
    s === nothing && continue
    s.connections === nothing || close_pool!(s.connections)
    delete!(config, k)
  end
end

# ── The PostgreSQL terminals, warmed from the driver extensions (#1702, #1732) ─
#
# Since #1693 a terminal infers its body once per concrete pool. This function compiles a PostgreSQL
# pool's terminals: it renders each one with `show_query = :sql` on an offline key, which opens no
# connection and needs no database. PormG's own workload above does NOT call it: `PormGPostgresExt`
# and `PormGLibPQExt` call it from their workloads, once each, on their own pool type.
#
# Why there and not here (#1732): code compiled in PormG's image, before any driver loads, is
# invalidated when one loads. The driver's dependencies (DBInterface, DataDecimals, Reseau,
# ConcurrentUtilities for Postgres.jl; Intervals and Infinity for LibPQ) add methods to functions
# PormG's code calls with abstract arguments, and the extension adds the `backend_*` methods. #1712
# ran this as step 6 of PormG's workload: a Nitro app's first `list` then cost 17.9 s and its first
# `validate_field_data` about 0.5 s, both tagged `# recompile`. Inside an extension's workload it
# compiles after the driver and its dependencies have loaded, so the code lands in the extension's
# image, valid against the final method table. `PormGSQLiteExt` has always worked that way.
#
# The price: an offline `:postgres` key with no driver loaded (`register_offline`, docs/src/testing.md)
# runs its first calls on run-time inference again, as it did before #1712.
#
# `mod` is a submodule of the calling extension: `set_models` needs the models as globals of a module,
# and precompilation refuses `Core.eval` into a module outside the package being compiled. The
# `finally` leaves the module inert and removes the key from `config`, so no model, no registration
# record (#1607) and no offline entry reaches the extension's image.
#
# Each entry is the `Settings` `register_offline` builds, written out: `register_offline` builds the
# LibPQ pool only, and it refuses to run while a non-incremental image (a sysimage, a `juliac` build)
# is being built, which also runs extension workloads.
#
# test/performance/offline_first_calls.jl measures the first calls this is for.
function _offline_postgres_workload(mod::Module, key::String, driver::Symbol)
  config[key] = Configuration.Settings(
    app_env = Configuration.DEV, db_def_folder = key,
    db_config_settings = Configuration._offline_config_settings(:postgres, nothing),
    change_data = true,
    connections = ConnectionPool.PostgresConnectionPool(Configuration._OFFLINE_CONNECTION;
                                                        pool_size = 1, driver = driver))
  try
    # Plain globals, unlike an application's typed ones (#1650): the `finally` resets them to
    # `nothing`, and `set_models` does not warn while output is being generated.
    Core.eval(mod, quote
      import PormG.Models
      Driver = Models.Model("driver",
        driverid = Models.IDField(),
        code = Models.CharField(max_length = 3, null = true),
        forename = Models.CharField(max_length = 255),
        surname = Models.CharField(max_length = 255),
        dob = Models.DateField(null = true))
      Constructor = Models.Model("constructor",
        constructorid = Models.IDField(),
        name = Models.CharField(max_length = 255))
      Race = Models.Model("race",
        raceid = Models.IDField(),
        year = Models.IntegerField(),
        name = Models.CharField(max_length = 255),
        date = Models.DateField(),
        start_at = Models.DateTimeField(null = true))
      Result = Models.Model("result",
        resultid = Models.IDField(),
        raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
        driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "CASCADE"),
        constructorid = Models.ForeignKey(Constructor, pk_field = "constructorid", on_delete = "RESTRICT"),
        grid = Models.IntegerField(),
        points = Models.FloatField())
      # #1602: the set `set_models` reads, interpolated (the block's macros expand before its
      # `import` runs).
      $(Models._model_set_declaration([:Driver, :Constructor, :Race, :Result]))
    end)
    # `invokelatest`: the bindings are newer than this code's world (#211).
    Base.invokelatest(Models.set_models, mod, key)
    Driver, Race, Result = (Base.invokelatest(getglobal, mod, n) for n in (:Driver, :Race, :Result))

    joined = Result.objects.filter("driverid__surname" => "Senna", "points__@gte" => 1.0).
      values("resultid", "driverid__forename", "driverid__dob", "constructorid__name", "points")
    rendered = (
      Driver.objects.create("driverid" => 1, "code" => "SEN", "forename" => "Ayrton",
                            "surname" => "Senna", "dob" => Dates.Date(1960, 3, 21); show_query = :sql),
      Result.objects.create("resultid" => 1, "raceid" => 1, "driverid" => 1, "constructorid" => 1, "grid" => 1,
                            "points" => 9.0; show_query = :sql),
      # A `DateTime` through `validate_field_data`, on insert and on update (#1732).
      Race.objects.create("raceid" => 1, "year" => 1988, "name" => "Japanese Grand Prix",
                          "date" => Dates.Date(1988, 10, 30), "start_at" => Dates.DateTime(1988, 10, 30, 4, 0);
                          show_query = :sql),
      Race.objects.filter("raceid" => 1).update("start_at" => Dates.DateTime(1988, 10, 30, 5, 0); show_query = :sql),
      Driver.objects.filter("driverid" => 1).update("code" => "PRO"; show_query = :sql),
      Result.objects.filter("resultid" => 1).update("points" => F("points") + 1; show_query = :sql),
      # Through the collector: `Result` cascades from `Driver`.
      Driver.objects.filter("driverid" => 2).delete(; show_query = :sql),
      # `defaults` as a literal of strings makes a `Vector{Pair{String,String}}`; built at run time,
      # it is a `Vector{Pair{String,Any}}` (#1732). Each is its own specialization, and so is the
      # lookup's value type: a text key and an integer one.
      Driver.objects.get_or_create("code" => "HAM";
        defaults = ["forename" => "Lewis", "surname" => "Hamilton"], show_query = :sql),
      Driver.objects.get_or_create("code" => "HAM";
        defaults = Pair{String, Any}["forename" => "Lewis", "surname" => "Hamilton", "dob" => Dates.Date(1985, 1, 7)],
        show_query = :sql),
      Driver.objects.get_or_create("driverid" => 1;
        defaults = Pair{String, Any}["forename" => "Lewis", "surname" => "Hamilton", "dob" => Dates.Date(1985, 1, 7)],
        show_query = :sql),
      inspect_query(joined),
      Driver.objects.filter("forename__@icontains" => "ayr").count(; show_query = :sql),
      Result.objects.exists(; show_query = :sql),
    )
    # Checked, not just called: a call that rendered nothing warmed nothing (#348).
    for r in rendered
      r isa Union{String, Dict, Vector} || throw(AssertionError(
        "PormG precompile workload: a show_query = :sql call on $(key) rendered a $(typeof(r))"))
    end
  finally
    Core.eval(mod, :(Driver = Constructor = Race = Result = nothing))
    record = Base.invokelatest(Models._model_set, mod)
    if record !== nothing
      record.key = record.load_root = record.folder = nothing
      empty!(record.models)
      empty!(record.bindings)
    end
    s = get(config, key, nothing)
    s === nothing || close_pool!(s.connections)
    delete!(config, key)
  end
  return nothing
end

# ── Snoop-generated precompile hints ─────────────────────────────────────────
#
# Named-method directives from a SnoopCompile run (test/performance/snoop_compile.jl) for inference
# the workload above does not reach. Statement EXECUTION is not this file's job any more: the
# SQLite extension runs a real end-to-end workload (the workload at the end of `ext/PormGSQLiteExt.jl`), because only an
# extension has a driver loaded at precompile time.
#
# Only directives that name a method belong here, and even those go stale quietly: `Base.precompile`
# returns `false` on a signature that no longer matches rather than throwing. So
# `test/unit/test_precompile_hints.jl` evaluates every one of them and fails when it stops matching.
# The same test keeps out the shape this file used to carry — six directives naming anonymous
# closures by generated number (`Symbol("#106#107")`, worth 3.13 s when snooped) behind an
# `isdefined` guard. Those numbers shift whenever a closure is added above them, the guard turned
# every stale one into a no-op, and by the time they were removed three no longer existed and the
# fourth named a different closure.
#
# Regenerate with:
#   julia -t auto --project=@pormg-snoop test/performance/snoop_compile.jl
# (that script's header has the one-off recipe for building @pormg-snoop — the package env
#  carries neither the profiling [extras] nor a SQL driver, #624)
if ccall(:jl_generating_output, Cint, ()) == 1
  let QB = QueryBuilder
    Base.precompile(Tuple{typeof(QB._get_filter_query), QB.QorObject, QB.InstructionObject})  # 0.11 s
    Base.precompile(Tuple{typeof(QB.deepcopy), QB.QObject})                       # 0.08 s
    Base.precompile(Tuple{QB.ChainCaller{typeof(QB._order_by!), QB.ObjectHandler}, String, Vararg{String}})  # 0.04 s
    Base.precompile(Tuple{typeof(QB.F), String})                                  # 0.01 s
    Base.precompile(Tuple{typeof(*), QB.FExpression, Float64})                    # 0.02 s
    # add_parameter! bodyfunction forms (snoop run 2 — 0.05s combined)
    # swallows `which` finding no method: the signature moved, so this precompile is skipped
    let fbody = try Base.bodyfunction(which(QB.add_parameter!, (QB.InstructionObject, Int64,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Bool, String, Nothing, typeof(QB.add_parameter!), QB.InstructionObject, Int64,))
    end
    # swallows `which` finding no method: the signature moved, so this precompile is skipped
    let fbody = try Base.bodyfunction(which(QB.add_parameter!, (QB.SQLiteParameterizedQuery, Float64,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Bool, String, Nothing, typeof(QB.add_parameter!), QB.SQLiteParameterizedQuery, Float64,))
    end
    # swallows `which` finding no method: the signature moved, so this precompile is skipped
    let fbody = try Base.bodyfunction(which(QB.add_parameter!, (QB.SQLiteParameterizedQuery, Int64,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Bool, String, Nothing, typeof(QB.add_parameter!), QB.SQLiteParameterizedQuery, Int64,))
    end
    # _determine_join_type bodyfunction forms (0.018s combined). The body function takes the keywords
    # in declaration order — `previus_how`, `second_fild_name`, `column_name` (#28) — then the function
    # and the field; the forward-FK hop passes all three.
    # swallows `which` finding no method: the signature moved, so this precompile is skipped
    let fbody = try Base.bodyfunction(which(QB._determine_join_type, (QB.sForeignKey,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Nothing, String, String, typeof(QB._determine_join_type), QB.sForeignKey,))
      ismissing(fbody) || precompile(fbody, (String,  String, String, typeof(QB._determine_join_type), QB.sForeignKey,))
    end
  end

  # Base Dict row-assembly (triggered by Tables.rowtable → Dict{Symbol,Any}) ---
  Base.precompile(Tuple{typeof(merge!), Dict{Symbol, Real},                  Dict{Symbol, Float64}})               # 0.10 s
  Base.precompile(Tuple{typeof(merge!), Dict{Symbol, Union{Missing, Int64}}, Dict{Symbol, Int64}})                 # 0.10 s
  Base.precompile(Tuple{typeof(merge!), Dict{Symbol, Union{Missing, String}},Dict{Symbol, Missing}})               # 0.10 s
  Base.precompile(Tuple{typeof(setindex!), Dict{Symbol, Missing},            Missing, Symbol})                     # 0.07 s
  Base.precompile(Tuple{typeof(setindex!), Dict{Symbol, Float64},            Float64, Symbol})                     # 0.07 s
  Base.precompile(Tuple{typeof(merge!), Dict{Symbol, Any}, Dict{Symbol, Union{Missing, String}}})                  # 0.03 s
  Base.precompile(Tuple{typeof(merge!), Dict{Symbol, Any}, Dict{Symbol, Real}})                                    # 0.03 s
  Base.precompile(Tuple{typeof(merge!), Dict{Symbol, Any}, Dict{Symbol, Int64}})                                   # 0.03 s
  Base.precompile(Tuple{typeof(merge!), Dict{Symbol, Any}, Dict{Symbol, Union{Missing, Int64}}})                   # 0.03 s

  # SQLite parameter binding is compiled for real by the extension's workload (the workload at the end of ext/PormGSQLiteExt.jl).
end
