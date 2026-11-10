## First calls on an offline key, per driver session (#1702)
##
## One `show_query = :sql` call each to `create`, `update`, `delete`, `inspect_query` and `list`, plus
## the two shapes #1732 added (`get_or_create` with `defaults::Vector{Pair{String,Any}}`, and a
## `DateTime` value through `create`), on
## F1 models declared at run time and bound to a `register_offline` key, in a FRESH process. No
## database is involved: an offline key renders SQL and never opens a connection. What it measures
## is how much of a first call runs on the package image and how much on run-time inference.
##
## The session is chosen by `PORMG_FC_SESSION`:
##
##   nodriver  `using PormG` alone, an offline :postgres key. The PostgreSQL pool path with no driver
##             extension loaded: nothing can invalidate the image, so what is slow here is what no
##             workload compiled. Since #1732 the PostgreSQL terminals are compiled by the driver
##             extensions' workloads, so this session runs them on run-time inference.
##   libpq     `using PormG, LibPQ`, an offline :postgres key (`PostgresConnectionPool{:libpq}`).
##   postgres  `using PormG, Postgres`, an offline-shaped key on `PostgresConnectionPool{:postgres}`
##             (`register_offline` builds the LibPQ pool only, so this one is assembled the way it
##             assembles its own).
##   sqlite    `using PormG, SQLite`, an offline :sqlite key with `server_version = 3_045_000`.
##
## Timing, one fresh process per run (the first run after a source change also builds the caches;
## discard it):
##
##   PORMG_FC_SESSION=libpq julia --project=test/integration test/performance/offline_first_calls.jl
##
## Snooping (`PORMG_FC_SNOOP=invalidations` or `inference`) needs SnoopCompile, which neither the
## package env nor the integration env carries. Build a throwaway shared env once (no tracked file
## changes), as test/performance/snoop_compile.jl does:
##
##   julia --project=@pormg-snoop -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.add(["SnoopCompile", "SnoopCompileCore", "SQLite", "LibPQ", "Postgres"])'
##   PORMG_FC_SESSION=libpq PORMG_FC_SNOOP=invalidations julia --project=@pormg-snoop test/performance/offline_first_calls.jl
##
##   invalidations  `@snoop_invalidations` around `using PormG, <driver>`; with `PORMG_FC_DRIVER_ONLY=1`,
##                  PormG is loaded first and only the driver is inside (what the driver, its
##                  dependencies and its extension invalidate in PormG's image). Prints the top 20
##                  invalidating methods, the PormG instances below each, and the PormG methods hit.
##   inference      `@snoop_inference` around the first `create` and, separately, the first `update`:
##                  inference time per root module (PormG / Base+Core / other) and the top roots.
##                  In a driver session the snoop itself inflates the wall time (about 3x on Julia
##                  1.13.3, with SnoopCompileCore 3.1.4), so read the shares there, and the costs from
##                  the timing mode.

const SESSION = get(ENV, "PORMG_FC_SESSION", "libpq")
const SNOOP = get(ENV, "PORMG_FC_SNOOP", "")
SESSION in ("nodriver", "libpq", "postgres", "sqlite") ||
  throw(ArgumentError("PORMG_FC_SESSION must be nodriver, libpq, postgres or sqlite, got $(repr(SESSION))"))
SNOOP in ("", "invalidations", "inference") ||
  throw(ArgumentError("PORMG_FC_SNOOP must be empty, invalidations or inference, got $(repr(SNOOP))"))
delete!(ENV, "PORMG_POSTGRES_DRIVER")

const DRIVER = Dict("nodriver" => nothing, "libpq" => :LibPQ, "postgres" => :Postgres, "sqlite" => :SQLite)[SESSION]
const LOAD = DRIVER === nothing ? :(using PormG) : :(using PormG, $DRIVER)

SNOOP == "" || Core.eval(Main, :(using SnoopCompileCore))

# ── Load ──────────────────────────────────────────────────────────────────────
invs_all = nothing
invs_driver = nothing
t_load = if SNOOP == "invalidations"
  # One variant per process: in one process the first would absorb the second. `PORMG_FC_DRIVER_ONLY=1`
  # selects the PormG-first one.
  if get(ENV, "PORMG_FC_DRIVER_ONLY", "0") == "1"
    Core.eval(Main, :(using PormG))
    DRIVER === nothing && error("PORMG_FC_DRIVER_ONLY needs a driver session")
    @elapsed (global invs_driver = Core.eval(Main, :(SnoopCompileCore.@snoop_invalidations using $DRIVER)))
  else
    @elapsed (global invs_all = Core.eval(Main, :(SnoopCompileCore.@snoop_invalidations $LOAD)))
  end
else
  @elapsed Core.eval(Main, LOAD)
end

# ── Model + key ───────────────────────────────────────────────────────────────
const KEY = "fc1702"
const FcModels = Module(:FcModels)
# Not the models a precompile workload defines (`ext/PormGSQLiteExt.jl` and
# `_offline_postgres_workload` in `src/precompile.jl` declare their own, in their own modules), so the
# numbers are what carries over to an application's own models rather than what a workload replayed;
# `time_to_first_query.jl` makes the same choice.
t_model = @elapsed Core.eval(FcModels, quote
  import PormG, PormG.Models
  Circuit::Models.ModelType = Models.Model("circuit",
    circuitid = Models.IDField(),
    name = Models.CharField(max_length = 255),
    country = Models.CharField(max_length = 255),
    lat = Models.FloatField(null = true))
  Race::Models.ModelType = Models.Model("race",
    raceid = Models.IDField(),
    year = Models.IntegerField(),
    name = Models.CharField(max_length = 255),
    date = Models.DateField(null = true),
    start_at = Models.DateTimeField(null = true),
    circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"))
  $(Base.invokelatest(PormG.Models._model_set_declaration, [:Circuit, :Race]))
end)

function register_key()
  C = PormG.Configuration
  if SESSION == "sqlite"
    C.register_offline(KEY; adapter = :sqlite, server_version = 3_045_000)
  elseif SESSION == "postgres"
    # `register_offline`'s own entry, on the Postgres.jl pool.
    PormG.config[KEY] = C.Settings(
      app_env = C.DEV, db_def_folder = KEY,
      db_config_settings = C._offline_config_settings(:postgres, nothing),
      change_data = true,
      connections = PormG.ConnectionPool.PostgresConnectionPool(C._OFFLINE_CONNECTION; pool_size = 1, driver = :postgres))
  else
    C.register_offline(KEY; adapter = :postgres)
  end
  PormG.Models.set_models(FcModels, KEY)
end
t_key = @elapsed Base.invokelatest(register_key)
const Circuit = Base.invokelatest(getglobal, FcModels, :Circuit)
const Race = Base.invokelatest(getglobal, FcModels, :Race)

# ── The five first calls ─────────────────────────────────────────────────────
calls = Pair{String, Function}[
  "create" => () -> Circuit.objects.create("circuitid" => 1, "name" => "Monza", "country" => "Italy", "lat" => 45.6; show_query = :sql),
  "update" => () -> Race.objects.filter("raceid" => 1).update("name" => "Gran Premio d'Italia"; show_query = :sql),
  "delete" => () -> Circuit.objects.filter("circuitid" => 1).delete(; show_query = :sql),
  "inspect_query" => () -> inspect_query(Race.objects.filter("circuitid__country" => "Italy").values("name", "circuitid__name")),
  "list" => () -> Race.objects.filter("year__@gte" => 2020, "circuitid__country" => "Italy").
    values("raceid", "name", "date", "circuitid__name").list(; show_query = :sql),
  # #1732: `defaults` built at run time is a `Vector{Pair{String,Any}}`, not the
  # `Vector{Pair{String,String}}` a literal of strings makes.
  "get_or_create" => () -> Circuit.objects.get_or_create("circuitid" => 2;
    defaults = Pair{String, Any}["name" => "Spa-Francorchamps", "country" => "Belgium", "lat" => 50.44], show_query = :sql),
  # #1732: a `DateTime` value through `validate_field_data` (a `DateTimeField`, the fixture's `start_at`).
  "create datetime" => () -> Race.objects.create("raceid" => 1, "year" => 2008, "name" => "Australian Grand Prix",
    "date" => PormG.Dates.Date(2008, 3, 16), "start_at" => PormG.Dates.DateTime(2008, 3, 16, 5, 30),
    "circuitid" => 1; show_query = :sql),
]

pool_type = string(typeof(PormG.config[KEY].connections))

# The root module that owns a method instance: PormG, Base+Core, or another package.
function _owner(mi)
  d = mi.def
  r = Base.moduleroot(d isa Method ? d.module : d)
  r === Main.PormG && return "PormG"
  (r === Base || r === Core) && return "Base+Core"
  return string(r)
end

if SNOOP == "inference"
  # Both snoops run before SnoopCompile itself loads: its dependencies invalidate PormG's image too,
  # and loaded first they turned every first call into a full re-inference (7 s for a 0.7 s create).
  snooped = map(calls[1:2]) do (name, f)
    t = @elapsed (tinf = Base.invokelatest(() -> Core.eval(Main, :(SnoopCompileCore.@snoop_inference $f()))))
    (name, t, tinf)
  end
  Core.eval(Main, :(using SnoopCompile))
  Base.invokelatest() do
    SC = Main.SnoopCompile
    for (name, wall, tinf) in snooped
      by = Dict{String, Float64}()
      for t in SC.flatten(tinf)
        mi = SC.MethodInstance(t)
        mi.def === Core.Compiler.Timings.ROOTmi.def && continue   # ROOT: time outside inference
        k = _owner(mi)
        by[k] = get(by, k, 0.0) + SC.exclusive(t)
      end
      total = sum(values(by); init = 0.0)
      println("\n── @snoop_inference: first $name ($SESSION, $pool_type) ──")
      println("wall: ", round(wall; digits = 3), " s; inference (incl. LLVM): ", round(total; digits = 3), " s")
      for (k, v) in sort!(collect(by); by = last, rev = true)
        v < 0.001 && continue
        println("  ", rpad(k, 24), lpad(string(round(v; digits = 3)), 8), " s  ", round(Int, 100v / max(total, eps())), "%")
      end
      println("  top roots (inclusive):")
      for r in first(sort(tinf.children; by = SC.inclusive, rev = true), 15)
        mi = SC.MethodInstance(r)
        loc = mi.def isa Method ? "$(mi.def.file):$(mi.def.line)" : ""
        println("    ", lpad(string(round(SC.inclusive(r); digits = 3)), 7), " s  ", _owner(mi), "  ", mi, "  ", loc)
      end
    end
  end
  exit(0)
end

results = Tuple{String, Float64, Float64}[]
for (name, f) in calls
  s = Base.invokelatest(() -> Base.@timed f())
  s.value isa Union{String, Dict, Vector} || error("$name did not render: got $(typeof(s.value))")
  push!(results, (name, s.time, s.compile_time))
end

if SNOOP == "invalidations"
  Core.eval(Main, :(using SnoopCompile))
  Base.invokelatest() do
    SC = Main.SnoopCompile
    invs = something(invs_all, invs_driver)
    label = invs_all === nothing ? "using $DRIVER (PormG already loaded)" : string(LOAD)
    trees = SC.invalidation_trees(invs)
    # PormG instances anywhere in a tree, not just at its roots: `filtermod` matches roots only, and
    # a PormG caller of an invalidated Base method sits below that method's instance.
    function pormg_nodes!(acc, node)
      _owner(node.mi) == "PormG" && push!(acc, node.mi)
      foreach(c -> pormg_nodes!(acc, c), node.children)
      return acc
    end
    tree_roots(t) = vcat([last(p) for p in t.mt_backedges], t.backedges)
    pormg_in(t) = foldl(pormg_nodes!, tree_roots(t); init = Set{Core.MethodInstance}())
    describe(m) = m isa Method ? "$(m.module).$(m.name)  $(m.file):$(m.line)" : string(m)
    all_pormg = filter(mi -> mi isa Core.MethodInstance && _owner(mi) == "PormG", collect(SC.uinvalidated(invs)))
    println("\n── @snoop_invalidations: $label ──")
    println("unique invalidated method instances: ", length(SC.uinvalidated(invs)), "; PormG's: ", length(all_pormg),
            "; trees: ", length(trees))
    counted = [(t, length(pormg_in(t))) for t in trees]
    println("\ntop 20 invalidating methods (all instances | PormG instances below):")
    for (t, n) in first(sort(counted; by = x -> SC.countchildren(x[1]), rev = true), 20)
      println("  ", lpad(string(SC.countchildren(t)), 6), " | ", lpad(string(n), 4), "  ", describe(t.method), "  [", t.reason, "]")
    end
    println("\ntop 20 invalidating methods by PormG instances below:")
    for (t, n) in first(sort(counted; by = last, rev = true), 20)
      n == 0 && break
      println("  ", lpad(string(n), 4), "  ", describe(t.method))
      t.method isa Method && println("          ", t.method.sig)
    end
    byfn = Dict{String, Int}()
    for mi in all_pormg
      k = describe(mi.def)
      byfn[k] = get(byfn, k, 0) + 1
    end
    println("\nPormG methods with invalidated instances (top 25):")
    for (k, v) in first(sort!(collect(byfn); by = last, rev = true), 25)
      println("  ", lpad(string(v), 4), "  ", k)
    end
  end
end

println("\nsession=$SESSION pool=$pool_type")
println(rpad("load", 16), lpad(string(round(t_load; digits = 3)), 8), " s")
println(rpad("model def", 16), lpad(string(round(t_model; digits = 3)), 8), " s")
println(rpad("key + set_models", 16), lpad(string(round(t_key; digits = 3)), 8), " s")
for (n, t, c) in results
  println(rpad(n, 16), lpad(string(round(t; digits = 3)), 8), " s  (compile ", round(c; digits = 3), " s)")
end
println(rpad("first calls", 16), lpad(string(round(sum(r[2] for r in results); digits = 3)), 8), " s")
println(rpad("script total", 16), lpad(string(round(t_load + t_model + t_key + sum(r[2] for r in results); digits = 3)), 8), " s")
