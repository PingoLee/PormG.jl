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
      end
    end
  end

  # Cleanup mock config after precompilation is done
  delete!(config, "precompile")
end
