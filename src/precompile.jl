using PrecompileTools
import Logging

@setup_workload begin
  # Mock settings to allow Model and QueryBuilder compilation Without actual DB connection
  # We use a dummy PostgresConnectionPool as it's a common target
  mock_pool = ConnectionPool.PostgresConnectionPool(
    Union{Nothing, LibPQ.Connection}[],
    Bool[],
    "dummy_connection_string",
    0,
    ReentrantLock()
  )

  mock_settings = Configuration.Settings(
    app_env = "dev",
    db_def_folder = "precompile",
    model_file = "models.jl",
    db_config_settings = Dict{String, Any}(),
    log_queries = false,
    log_level = Logging.Error,
    log_to_file = false,
    change_db = false,
    change_data = false,
    connections = mock_pool,
    time_zone = "UTC",
    django_prefix = nothing
  )

  # Register the mock settings in the global config
  config["precompile"] = mock_settings

  # Create mock environment for Configuration.load
  mktempdir() do tmpdir
    original_dir = pwd()
    cd(tmpdir) do
      # Create dummy connection files so load doesn't error or trigger Generator's interactive/long errors
      for d in ["db", "db_sch"]
        mkdir(d)
        open(joinpath(d, "connection.yml"), "w") do f
          write(f, """
          adapter: SQLite
          database: ":memory:"
          """)
        end
      end

      @compile_workload begin
        # 0. Precompile Configuration Loading (Mocked environment)
        try
          Configuration.load()
          Configuration.load("db_sch")
        catch
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
        for model in [PrecompileDriver, PrecompileResult]
          # Handler creation
          q = object(model)

          # Filtering with various operators
          q.filter("forename" => "Ayrton")
          q.filter("points__gte" => 10.0)
          q.filter(Qor("surname" => "Senna", "surname" => "Prost"))

          # Selection and Aggregation
          q.values("forename", "surname")
          q.values("forename", "count" => Count("driverId"))
          q.values("points_sum" => Sum("points"))

          # Ordering and pagination
          q.order_by("-points")
          q.limit(5).offset(10)

          # 4. Precompile SQL Generation (Internal build calls)
          try
            # This triggers the core SQL generation logic
            q |> show_query
          catch e
            # Fallback if internal state is too mocked
          end
        end

        # 5. Precompile Password Utilities
        try
          p = "precompile_secret"
          h = make_password(p)
          check_password(p, h)
        catch
        end

        # 6. Precompile Dict{Symbol,String} display path + F() expression types
        # SnoopCompile: show(Dict{Symbol,String}) hit 0.29s on cold start.
        # F() and F()*Float64 are exported and quick to trigger here.
        show(devnull, Dict{Symbol, String}(:name => "precompile"))
        F("points")
        F("points") * 1.0
      end
    end
  end

  # Cleanup mock config after precompilation is done
  delete!(config, "precompile")
end

# ── Snoop-generated precompile hints ─────────────────────────────────────────
#
# These directives cover the execution-path inference gaps that @compile_workload
# cannot reach because it uses a mock pool (no live DB → no .list() execution).
#
# SnoopCompile (test/performance/snoop_compile.jl, full mode) identified ~6.7 s
# of cold-start inference here:
#   • QueryBuilder execution closures — 5.7s (anonymous closures + filter/join helpers)
#   • Base Dict row-assembly — 0.67s  (merge!/setindex! on typed Symbol dicts)
#   • SQLite bind — 0.05s             (parameter binding for Float64/Int64)
#
# FRAGILE: anonymous closure numbers (#98#99, #106#107, etc.) change whenever a
# new closure is added or removed ABOVE them in QueryBuilder. The isdefined guard
# makes stale entries safe — they silently become no-ops. Regenerate by running:
#   julia -t auto --project=. test/performance/snoop_compile.jl
if ccall(:jl_generating_output, Cint, ()) == 1
  let QB = QueryBuilder
    # QueryBuilder execution closures -----------------------------------------
    isdefined(QB, Symbol("#106#107")) &&
      Base.precompile(Tuple{getfield(QB, Symbol("#106#107"))})                    # 3.13 s
    isdefined(QB, Symbol("#98#99")) &&
      Base.precompile(Tuple{getfield(QB, Symbol("#98#99"))})                      # 1.68 s
    isdefined(QB, Symbol("#9#10")) &&
      Base.precompile(Tuple{getfield(QB, Symbol("#9#10")), QB.SQLTypeQor})        # 0.18 s
    isdefined(QB, Symbol("#9#10")) &&
      Base.precompile(Tuple{getfield(QB, Symbol("#9#10")), QB.OperObject})        # 0.15 s
    isdefined(QB, Symbol("#100#101")) &&
      Base.precompile(Tuple{getfield(QB, Symbol("#100#101"))})                    # 0.12 s
    isdefined(QB, Symbol("#9#10")) &&
      Base.precompile(Tuple{getfield(QB, Symbol("#9#10")), QB.SQLTypeQ})          # 0.09 s
    Base.precompile(Tuple{typeof(QB._get_filter_query), QB.QorObject, QB.InstrucObject})  # 0.11 s
    Base.precompile(Tuple{typeof(QB.deepcopy), QB.QObject})                       # 0.08 s
    Base.precompile(Tuple{QB.ChainCaller{typeof(QB.order_by!), QB.ObjectHandler}, String, Vararg{String}})  # 0.04 s
    Base.precompile(Tuple{typeof(QB.F), String})                                  # 0.01 s
    Base.precompile(Tuple{typeof(*), QB.FExpression, Float64})                    # 0.02 s
    Base.precompile(Tuple{typeof(QB._get_join_filters), QB.SQLObjectQuery, String})       # 0.005 s
    Base.precompile(Tuple{typeof(QB._get_join_type_override), QB.SQLObjectQuery, String}) # 0.005 s
    # add_parameter! bodyfunction forms (snoop run 2 — 0.05s combined)
    let fbody = try Base.bodyfunction(which(QB.add_parameter!, (QB.InstrucObject, Int64,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Bool, String, Nothing, typeof(QB.add_parameter!), QB.InstrucObject, Int64,))
    end
    let fbody = try Base.bodyfunction(which(QB.add_parameter!, (QB.SQLiteParameterizedQuery, Float64,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Bool, String, Nothing, typeof(QB.add_parameter!), QB.SQLiteParameterizedQuery, Float64,))
    end
    let fbody = try Base.bodyfunction(which(QB.add_parameter!, (QB.SQLiteParameterizedQuery, Int64,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Bool, String, Nothing, typeof(QB.add_parameter!), QB.SQLiteParameterizedQuery, Int64,))
    end
    # _determine_join_type bodyfunction forms (0.018s combined)
    let fbody = try Base.bodyfunction(which(QB._determine_join_type, (QB.sForeignKey,))) catch; missing end
      ismissing(fbody) || precompile(fbody, (Nothing, String, typeof(QB._determine_join_type), QB.sForeignKey,))
      ismissing(fbody) || precompile(fbody, (String,  String, typeof(QB._determine_join_type), QB.sForeignKey,))
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

  # SQLite parameter binding ---------------------------------------------------
  Base.precompile(Tuple{typeof(SQLite.bind!), SQLite.Stmt, Int64, Float64})      # 0.025 s
  Base.precompile(Tuple{typeof(SQLite.bind!), SQLite.Stmt, Int64, Int64})        # 0.024 s
end
