## Time-to-first-query benchmark — the number behind the SQLite precompile workload
##
## Usage (from the repo root), ONE fresh process per measurement:
##
##   julia --project=test/integration test/performance/time_to_first_query.jl
##
## Run it once first and discard the result: that run also builds the precompile cache, whose cost
## is not what this measures. A warm REPL tells you nothing either — every step below is a FIRST
## call, and a second call in the same process is already compiled.
##
## It prints the package load time and, per operation, the wall time and the share of it that was
## compilation. On a cold cache the two are nearly equal, which is the point: this is latency an
## application pays on its first request, not query cost.
##
## The models are deliberately NOT the ones `ext/PormGSQLiteExt.jl`'s workload defines
## (Circuit/Race here, Driver/Constructor/Result there), so the number is what carries over to an
## application's own models rather than what the workload happened to replay. The tables are
## created by hand-written DDL for the same reason. The models ARE registered the way an
## application registers them — in a module, through `set_models`, which is what `@import_models`
## runs — because that is what wires reverse relations, and without it the cascading delete below
## would never reach the deletion collector.
t_load = @elapsed begin
  using PormG, SQLite, Dates
end
import PormG.Models: set_models
import PormG.ConnectionPool: fetch, SQLiteConnectionPool, close_pool!
import PormG.QueryBuilder: Count, Sum

results = Pair{String,Any}[]
macro step(name, ex)
  quote
    local s = Base.@timed $(esc(ex))
    push!(results, $(esc(name)) => (round(s.time; digits = 3), round(s.compile_time; digits = 3)))
    s.value
  end
end

mktempdir() do dir
  pool = SQLiteConnectionPool(joinpath(dir, "ttfq.sqlite"); pool_size = 1)
  PormG.config[dir] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
  try
    @step "ddl (fetch)" begin
      fetch(pool, "CREATE TABLE circuit (circuitid INTEGER PRIMARY KEY, name TEXT NOT NULL, country TEXT NOT NULL, lat REAL)")
      fetch(pool, "CREATE TABLE race (raceid INTEGER PRIMARY KEY, year INTEGER NOT NULL, name TEXT NOT NULL, date DATE, circuitid INTEGER NOT NULL REFERENCES circuit(circuitid))")
    end
    # An application's models module, as `@import_models` would load it.
    AppModels = Module(:AppModels)
    @step "model def" Core.eval(AppModels, quote
      import PormG.Models: Model, IDField, CharField, IntegerField, FloatField, DateField, ForeignKey
      Circuit = Model("circuit", circuitid = IDField(), name = CharField(max_length = 255),
                      country = CharField(max_length = 255), lat = FloatField(null = true))
      Race = Model("race", raceid = IDField(), year = IntegerField(), name = CharField(max_length = 255),
                   date = DateField(null = true), circuitid = ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"))
    end)
    @step "register (set_models)" Base.invokelatest(set_models, AppModels, dir)
    Circuit = Base.invokelatest(getglobal, AppModels, :Circuit)
    Race = Base.invokelatest(getglobal, AppModels, :Race)

    @step "create" Circuit.objects.create("circuitid" => 1, "name" => "Monza", "country" => "Italy", "lat" => 45.6)
    @step "create (FK, Date)" Race.objects.create("raceid" => 1, "year" => 2021, "name" => "Italian GP",
                                                 "date" => Date(2021, 9, 12), "circuitid" => 1)
    @step "filter.list (row)" Race.objects.filter("year" => 2021).list()
    @step "join values list(:dict)" Race.objects.filter("circuitid__country" => "Italy").values("name", "circuitid__name", "date").list(:dict)
    @step "aggregate" Race.objects.values("circuitid__country", "n" => Count("raceid")).list()
    @step "get" Circuit.objects.get("circuitid" => 1)
    @step "count / exists" (Race.objects.filter("year__@gte" => 2020).count(), Race.objects.exists())
    @step "list(:json)" Race.objects.values("raceid", "name", "date").list(:json)
    @step "update" Race.objects.filter("raceid" => 1).update("name" => "Gran Premio d'Italia")
    @step "integrity error" try Circuit.objects.create("circuitid" => 1, "name" => "Dup", "country" => "X") catch e; e end
    @step "delete" Race.objects.filter("raceid" => 1).delete()
    Race.objects.create("raceid" => 2, "year" => 2022, "name" => "Italian GP", "circuitid" => 1)
    @step "delete (cascade)" Circuit.objects.filter("circuitid" => 1).delete()
  finally
    delete!(PormG.config, dir)
    close_pool!(pool)
  end
end

total = sum(r.second[1] for r in results)
println("load  $(round(t_load; digits = 2))s")
for (k, (t, c)) in results
  println(rpad(k, 26), lpad(string(t), 7), "s  (compile ", c, "s)")
end
println(rpad("TOTAL first-use", 26), lpad(string(round(total; digits = 2)), 7), "s")
