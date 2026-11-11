# ==============================================================================
# Configuration is read at run time: nothing from `config` survives an image build (#1606)
#
# A heap image (a sysimage, a `juliac` executable) saves every global as the build left it. A
# configuration loaded while one is written travelled in it, the database password included, and at
# run time `load` found the key and returned early, serving the build machine's settings. Measured on a
# `juliac` executable whose entry loaded at its top level: the password was in the artifact, and the key
# was in `config` when `main` started. These tests pin the three halves of the contract without
# building an image: the refusal while one is written, the drop at `__init__`, and the latch reset.
#
# Run: julia --project=test/integration test/unit/test_image_build_config.jl
# ==============================================================================

using Test
using PormG
using PormG: Configuration, ConnectionPool
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

@testset "Configuration is read at run time (#1606)" begin

  # What: whether this process is writing a heap image.
  # Expected: `false` in a test run (it generates no output); the stand-in `_BUILDING` answers when set.
  # Why: the refusal below keys on it, and a wrong answer would refuse every `load` of a normal process.
  @testset "a test process is not building an image" begin
    @test Configuration._BUILDING[] === nothing
    @test Configuration._building_image() === false
    # The rule: only output that is not incremental is a heap image. A package's precompile is
    # incremental, and dropping that half would refuse every `load` in a package's module body.
    @test Configuration._heap_image(true, false) === true    # sysimage, juliac
    @test Configuration._heap_image(true, true) === false    # a package image
    @test Configuration._heap_image(false, false) === false  # a normal process
    @test Configuration._heap_image(false, true) === false
    Configuration._BUILDING[] = true
    try
      @test Configuration._building_image() === true
    finally
      Configuration._BUILDING[] = nothing
    end
  end

  # What: `load`, `register_connection` and `register_offline` while an image is being written.
  # Expected: each raises `InvalidConfigurationError` naming the call and where to move it, before it
  #   reads a file or registers anything: `config` is unchanged, and the message carries no path, URL
  #   or credential.
  # Why: what these calls store is what the image would carry. Refusing before the read is the one way
  #   a password never reaches the artifact (a drop at start-up would leave it in the file's bytes).
  @testset "the three entry points refuse while an image is built" begin
    before = sort!(collect(keys(PormG.config)))
    Configuration._BUILDING[] = true
    try
      err = try
        Configuration.load("/nonexistent/pormg-1606/db"; env = "dev"); nothing
      catch e
        e
      end
      @test err isa PormG.InvalidConfigurationError
      msg = sprint(showerror, err)
      @test occursin("PormG.Configuration.load", msg)
      @test occursin("is being built", msg) && occursin("__init__", msg)
      @test !occursin("nonexistent", msg)
      @test_throws PormG.InvalidConfigurationError Configuration.register_connection(
        "pormg_1606_dyn", "postgresql://u:secret_1606@127.0.0.1:5999/f1"; env = "dev")
      e2 = try
        Configuration.register_connection("pormg_1606_dyn", "postgresql://u:secret_1606@127.0.0.1:5999/f1"; env = "dev"); nothing
      catch e
        e
      end
      @test !occursin("secret_1606", sprint(showerror, e2))
      @test_throws PormG.InvalidConfigurationError Configuration.register_offline("pormg_1606_off")
      @test_throws PormG.InvalidConfigurationError Configuration.load_many(["/nonexistent/pormg-1606/db"]; env = "dev")
      # The hooks: a closure set while building would travel in the image with what it captured.
      resolver, hook = Configuration._CONNECTION_RESOLVER[], Configuration._BEFORE_CONNECT_HOOK[]
      @test_throws PormG.InvalidConfigurationError Configuration.set_connection_resolver(k -> nothing)
      @test_throws PormG.InvalidConfigurationError Configuration.set_before_connect_hook((k, s) -> true)
      @test Configuration._CONNECTION_RESOLVER[] === resolver
      @test Configuration._BEFORE_CONNECT_HOOK[] === hook
    finally
      Configuration._BUILDING[] = nothing
    end
    @test sort!(collect(keys(PormG.config))) == before
  end

  # What: `_drop_image_entries!`, which `Configuration.__init__` runs on `config`.
  # Expected: every entry is removed and counted, with one warning that lists the keys (never a
  #   setting's value); an empty registry is left alone, silently.
  # Why: an entry present when the module starts can only have come from the image, so its pool's
  #   handles belong to the build process. Keeping it would serve the build machine's settings.
  @testset "__init__ drops the entries an image carries" begin
    cfg = Dict{String, Configuration.Settings}(
      "db" => Configuration.Settings(db_def_folder = "db",
                                     db_config_settings = Dict{String,Any}("password" => "pw_1606")),
      "other" => Configuration.Settings(db_def_folder = "other"))
    n = @test_logs (:warn, r"dropped the connections this image was built with") Configuration._drop_image_entries!(cfg)
    @test n == 2
    @test isempty(cfg)
    logs = mktemp() do path, io
      Base.CoreLogging.with_logger(Base.CoreLogging.SimpleLogger(io, Base.CoreLogging.Warn)) do
        Configuration._drop_image_entries!(Dict{String, Configuration.Settings}("db" => Configuration.Settings(
          db_config_settings = Dict{String,Any}("password" => "pw_1606"))))
      end
      close(io); read(path, String)
    end
    @test occursin("db", logs) && !occursin("pw_1606", logs)
    @test (@test_logs Configuration._drop_image_entries!(Dict{String, Configuration.Settings}())) == 0
  end

  # What: the module initializers, run in a fresh process on state an image could carry: an entry in
  #   `config` and the "started" flags of the SQLite worker and the reaper, with no task behind them.
  # Expected: `Configuration.__init__` empties `config`; `ConnectionPool.__init__` clears both flags
  #   and the monitor switches, so the run-time process starts its own tasks.
  # Why: no task survives an image. A "started" flag kept from the build would stop the worker from
  #   ever starting again, and every SQLite statement would wait on a queue nothing reads. A child
  #   process, because the suite's own worker and reaper are live in this one.
  # What: a plain `using PormG` in a fresh process.
  # Expected: `config` is empty and nothing is logged.
  # Why: PormG's own precompile workload writes `config` and cleans up after itself; if that cleanup
  #   regressed, its entries would be in the package image, and `__init__` would log the drop warning
  #   at the start of every process.
  @testset "a fresh process starts with an empty registry and no warning (child process)" begin
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e "using PormG; print(isempty(PormG.config))"`
    err = IOBuffer()
    out = read(pipeline(cmd; stderr = err), String)
    @test out == "true"
    @test !occursin("dropped", String(take!(err)))
  end

  @testset "the initializers reset what an image would carry (child process)" begin
    script = """
    using PormG
    const CP = PormG.ConnectionPool
    PormG.config["from_build"] = PormG.Configuration.Settings(db_def_folder = "from_build")
    CP._reaper_started[] = true
    CP._sqlite_async_worker_started[] = true
    CP._MONITOR_ANY[] = true
    CP._LEAK_ANY[] = true
    redirect_stderr(devnull) do
      PormG.Configuration.__init__()
    end
    CP.__init__()
    print(isempty(PormG.config), " ", CP._reaper_started[], " ", CP._sqlite_async_worker_started[], " ",
          CP._MONITOR_ANY[], " ", CP._LEAK_ANY[])
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $(script)`
    out = read(cmd, String)
    @test out == "true false false false false"
  end
end
