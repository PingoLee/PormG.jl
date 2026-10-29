"""
Unit coverage for the connection registry's public names (#1229): `Configuration.loaded_keys`,
`Configuration.register_offline`, `Models.connection_key` and `Configuration.close_all!`.

Before these, the registry had no public names: asking which keys are loaded meant iterating
`PormG.config`, rendering SQL with no database meant defining a backend type and building a
`Settings` by hand, and asking which connection a model uses meant reading a struct field. Those
were the layout of `Settings` and `Model_Type`, not an API. No live database; every connection here is offline or SQLite `:memory:`.
"""

using Test
using PormG
import PormG: Configuration, Models
import JSON
using SQLite   # the #1451 testset's last `load` builds a live SQLite pool, which needs the extension
using DataFrames: DataFrame

# A throwaway models module with one F1 model, exactly what `@import_models` would evaluate.
function _reg1229_models(name::Symbol)
  mod = Module(name)
  Core.eval(mod, :(import PormG.Models))
  Core.eval(mod, :(Driver = Models.Model("drivers",
                                         driverid = Models.IDField(),
                                         surname  = Models.CharField(max_length = 50))))
  return mod, Base.invokelatest(getfield, mod, :Driver)
end

# ─────────────────────────────────────────────────────────────────────────────
# register_offline renders SQL on each dialect and never connects
# What it tests: an offline key binds models like a loaded folder (`set_models(mod, key)`),
#   `inspect_query` renders the dialect's SQL — PostgreSQL:
#     SELECT\n    *\nFROM "drivers" as "Tb"\nWHERE "Tb"."surname" = $1\n
#   SQLite: the same with `?` — and running the query raises `InvalidConfigurationError` naming
#   `register_offline` before any driver sees the placeholder connection string.
#   `Models.connection_key` reads the binding: `nothing` before, the key after.
# Why it matters: rendering SQL with no database otherwise means defining a backend type and
#   writing a hand-built `Settings` into `PormG.config`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "register_offline renders SQL and never connects (#1229)" begin
  expected = Dict(
    :postgres => "SELECT\n    *\nFROM \"drivers\" as \"Tb\"\nWHERE \"Tb\".\"surname\" = \$1\n",
    :sqlite   => "SELECT\n    *\nFROM \"drivers\" as \"Tb\"\nWHERE \"Tb\".\"surname\" = ?\n",
  )
  for adapter in (:postgres, :sqlite)
    key = "reg1229_offline_$(adapter)"
    try
      @test Configuration.register_offline(key; adapter = adapter) == key
      mod, driver = _reg1229_models(Symbol("Reg1229Offline", adapter))
      @test Models.connection_key(driver) === nothing
      Base.invokelatest(Models.set_models, mod, key)
      @test Models.connection_key(driver) == key

      q = driver.objects
      q.filter("surname" => "Senna")
      info = PormG.inspect_query(q)
      @test info[:sql_text] == expected[adapter]
      @test info[:parameters] == Any["Senna"]

      q2 = driver.objects
      q2.filter("surname" => "Senna")
      err = try
        q2.list()
        nothing
      catch e
        e
      end
      @test err isa PormG.InvalidConfigurationError
      @test occursin("registered with `register_offline`", sprint(showerror, err))
    finally
      Configuration.unregister_connection(key)
    end
    @test !Configuration.is_loaded(key)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# register_offline: arguments, replacing, and refusing a live key
# What it tests: `adapter` other than :postgres/:sqlite is refused; `django_prefix`/`change_data`
#   land on the entry; registering the same key again replaces the offline entry; a key that
#   `register_connection` (or `load`) registered is refused, not overwritten. The offline entry's
#   2-arg `show` and JSON form stay small (the #534/#643 bounds) and carry no connection string.
# Why it matters: an offline helper that could silently replace a live connection would turn a test
#   helper into a way to lose the application's database binding.
# ─────────────────────────────────────────────────────────────────────────────
@testset "register_offline: arguments, replace, refuse a live key (#1229)" begin
  key = "reg1229_args"
  live = "reg1229_live"
  try
    @test_throws PormG.InvalidConfigurationError Configuration.register_offline(key; adapter = :mysql)
    Configuration.register_offline(key; adapter = :sqlite, django_prefix = "f1_", change_data = false)
    s = PormG.config[key]
    @test s.django_prefix == "f1_"
    @test s.change_data == false
    @test s.connections isa PormG.PormGSQLite

    Configuration.register_offline(key)                    # replaces the offline entry
    @test PormG.config[key].connections isa PormG.PormGPostgres
    @test PormG.config[key].django_prefix === nothing

    @test length(sprint(show, PormG.config[key])) < 200
    @test length(JSON.json(PormG.config[key])) < 1000
    @test !occursin("pormg-offline", JSON.json(PormG.config[key]))

    Configuration.register_connection(live, ":memory:"; adapter = "SQLite", env = "test")
    err = try
      Configuration.register_offline(live)
      nothing
    catch e
      e
    end
    @test err isa PormG.InvalidConfigurationError
    @test occursin("already registered as a live connection", sprint(showerror, err))
    @test !(PormG.config[live].connections isa PormG.PormGPostgres)   # untouched
  finally
    Configuration.unregister_connection(key)
    Configuration.unregister_connection(live)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# load refuses a key register_offline holds
# What it tests: `load` of an offline key raises `InvalidConfigurationError` naming
#   `unregister_connection`, under the key itself (`load("db"; root)`), with `force = true`, and under
#   another spelling of the same folder (the absolute path, from the folder's parent). Each refusal
#   leaves the offline entry in place, same pool object; an alias whose folder does not exist is refused
#   the same way, with `scaffold = true`, and writes nothing. After `unregister_connection` the same `load`
#   registers a live SQLite pool. No SQL is involved; the folder holds a SQLite `:memory:` yml.
# Why it matters: an application's `__init__` runs `load("db"; env = …)`, and before #1451 that
#   replaced a golden-SQL suite's offline entry with a live pool with only a reload warning, so the
#   suite that believed itself offline reached a database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "load refuses a key register_offline holds (#1451)" begin
  mktempdir() do root
    db_dir = joinpath(root, "db"); mkpath(db_dir)
    write(joinpath(db_dir, "connection.yml"),
          "dev:\n  adapter: SQLite\n  database: \":memory:\"\n  config:\n    change_db: false\n    change_data: false\n")
    key = "db"
    # Alone in `config`: in the suite, other files leave hand-built entries whose default folder is
    # "db" too, and an alias spelling resolves to whichever the folder lookup meets first — not
    # necessarily the offline one (#550 keeps one entry per folder; the suite breaks that by hand).
    saved = copy(PormG.config)
    empty!(PormG.config)
    try
      Configuration.register_offline(key)
      pool = PormG.config[key].connections
      refused(f) = try f(); nothing catch e; e end

      for (label, call) in (("the key", () -> Configuration.load(key; root = root, env = "dev")),
                            ("force", () -> Configuration.load(key; root = root, env = "dev", force = true)),
                            ("another spelling", () -> cd(() -> Configuration.load(db_dir; env = "dev"), root)))
        err = refused(call)
        @test err isa PormG.InvalidConfigurationError
        @test err !== nothing && occursin("registered offline", sprint(showerror, err))
        @test err !== nothing && occursin("unregister_connection(\"db\")", sprint(showerror, err))
        @test Configuration._is_offline(PormG.config[key])
        @test PormG.config[key].connections === pool
      end

      # Another spelling whose folder does not exist: refused as offline, and nothing is scaffolded.
      mktempdir() do elsewhere
        err = refused(() -> cd(() -> Configuration.load(joinpath(elsewhere, "db"); env = "dev", scaffold = true), elsewhere))
        @test err isa PormG.InvalidConfigurationError
        @test err !== nothing && occursin("registered offline", sprint(showerror, err))
        @test !isdir(joinpath(elsewhere, "db"))
      end

      Configuration.unregister_connection(key)
      @test Configuration.load(key; root = root, env = "dev") == key
      @test !Configuration._is_offline(PormG.config[key])
      @test PormG.config[key].connections isa PormG.PormGSQLite
    finally
      haskey(PormG.config, key) && Configuration.unregister_connection(key)
      empty!(PormG.config)
      merge!(PormG.config, saved)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# delete(show_query) renders its cascade on an offline key
# What it tests: an F1 `Race` with a CASCADE `Result` on an offline key, `filter("year" => 1991)`.
#   `delete(show_query = :dict)` returns three steps instead of raising: the root-key read, then the
#   result and race DELETEs, scoped by the empty key list no read produced:
#     PostgreSQL: lock   SELECT "Tb"."raceid" FROM "race" AS "Tb" WHERE "Tb"."year" = $1 FOR UPDATE  [1991]
#                 delete … WHERE "Tb"."raceid" IN (SELECT … WHERE "R1"."raceid" = ANY($1) )   [[]]
#                 delete DELETE FROM "race" AS "Tb" WHERE "Tb"."raceid" = ANY($1)              [[]]
#     SQLite:     select … WHERE "Tb"."year" = ?  [1991]; then both DELETEs with `(1 = 0)`, no parameters
#   The same steps as the plan on a mock backend (`connection =` a marker struct), the path the planner
#   has always taken without a database. `delete()` itself still raises the offline refusal. A
#   `PROTECT` relation (an F1 `Standing` on the race) refuses the dry run with `ProtectedError`: with no
#   rows to read, the plan assumes related rows exist, as the mock does.
# Why it matters: the planner asked `_is_live_pool` by pool type, and an offline entry holds a real
#   pool, so it ran the root-key read and hit the offline refusal (#1453): the documented golden-SQL
#   fixture could pin every terminal except `delete()`, which a hand-written mock could.
# ─────────────────────────────────────────────────────────────────────────────
struct Reg1453MockPg <: PormG.PormGPostgres end
struct Reg1453MockSQLite <: PormG.PormGSQLite end

@testset "delete(show_query) renders its cascade on an offline key (#1453)" begin
  squash(sql) = strip(replace(sql, r"\s+" => " "))
  steps(r) = [(s[:operation], s[:model], squash(s[:sql_text]), s[:parameters]) for s in (r isa Vector ? r : [r])]
  expected = Dict(
    :postgres => [
      (:lock, "race", "SELECT \"Tb\".\"raceid\" FROM \"race\" AS \"Tb\" WHERE \"Tb\".\"year\" = \$1 FOR UPDATE", Any[1991]),
      (:delete, "result", "DELETE FROM \"result\" AS \"Tb\" WHERE \"Tb\".\"raceid\" IN (SELECT \"R1\".\"raceid\" as \"raceid\" FROM \"race\" as \"R1\" WHERE \"R1\".\"raceid\" = ANY(\$1) )", Any[Any[]]),
      (:delete, "race", "DELETE FROM \"race\" AS \"Tb\" WHERE \"Tb\".\"raceid\" = ANY(\$1)", Any[Any[]]),
    ],
    :sqlite => [
      (:select, "race", "SELECT \"Tb\".\"raceid\" FROM \"race\" AS \"Tb\" WHERE \"Tb\".\"year\" = ?", Any[1991]),
      (:delete, "result", "DELETE FROM \"result\" AS \"Tb\" WHERE \"Tb\".\"raceid\" IN (SELECT \"R1\".\"raceid\" as \"raceid\" FROM \"race\" as \"R1\" WHERE (1 = 0) )", Any[]),
      (:delete, "race", "DELETE FROM \"race\" AS \"Tb\" WHERE (1 = 0)", Any[]),
    ],
  )
  for (adapter, mock) in ((:postgres, Reg1453MockPg()), (:sqlite, Reg1453MockSQLite()))
    key = "reg1453_offline_$(adapter)"
    try
      Configuration.register_offline(key; adapter = adapter)
      mod = Module(Symbol("Reg1453", adapter))
      Core.eval(mod, :(import PormG.Models))
      Core.eval(mod, :(Race = Models.Model("race", raceid = Models.IDField(), year = Models.IntegerField())))
      Core.eval(mod, :(Result = Models.Model("result", resultid = Models.IDField(), points = Models.FloatField(),
                                             raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"))))
      Base.invokelatest(Models.set_models, mod, key)
      race = Base.invokelatest(getfield, mod, :Race)

      offline = steps(race.objects.filter("year" => 1991).delete(show_query = :dict))
      @test offline == expected[adapter]
      @test offline == steps(race.objects.filter("year" => 1991).delete(show_query = :dict, connection = mock))

      err = try
        race.objects.filter("year" => 1991).delete()
        nothing
      catch e
        e
      end
      @test err isa PormG.InvalidConfigurationError
      @test err !== nothing && occursin("registered with `register_offline`", sprint(showerror, err))

      Core.eval(mod, :(Standing = Models.Model("standing", standingid = Models.IDField(),
                                               raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "PROTECT"))))
      Base.invokelatest(Models.set_models, mod, key)
      race = Base.invokelatest(getfield, mod, :Race)
      @test_throws PormG.ProtectedError race.objects.filter("year" => 1991).delete(show_query = :dict)
    finally
      Configuration.unregister_connection(key)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# an offline SQLite key renders for the version it states
# What it tests: `register_offline(key; adapter = :sqlite, server_version)` renders the version-gated
#   clauses for that version, whatever library this process links (asserted newer than 3.30.0 first):
#     3.29.0  order_by("-points") → ORDER BY ("Tb"."points" IS NULL) DESC, "Tb"."points" DESC
#     3.30.0  order_by("-points") → ORDER BY "Tb"."points" DESC NULLS FIRST
#     3.24.0  ROW_NUMBER() OVER (…) → BackendCapabilityError naming 3.25.0 and 3.24.0
#   and `bulk_insert(show_query = :dict)` of 1000 one-parameter rows is two statements at 3.24.0 (the
#   999 bind limit below 3.32.0) and one at 3.45.0. With no `server_version`, a gated clause, and a
#   one-row bulk insert, raise `InvalidConfigurationError` naming `server_version`; an ungated query
#   renders. `server_version` with `:postgres`, or not positive, is refused at registration.
# Why it matters: an offline SQLite key asked the host's SQLite library (#1452), so it raised without
#   `using SQLite` and, with it, pinned SQL that differs between two CI images for the same query.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an offline SQLite key renders for the version it states (#1452)" begin
  @test Int(SQLite.C.sqlite3_libversion_number()) > 3_032_000   # the library is newer than every version below
  squash(sql) = strip(replace(sql, r"\s+" => " "))
  function offline_result(key; kw...)
    Configuration.register_offline(key; adapter = :sqlite, kw...)
    mod = Module(Symbol("Reg1452_", key))
    Core.eval(mod, :(import PormG.Models))
    Core.eval(mod, :(Result = Models.Model("result", resultid = Models.IDField(), points = Models.FloatField(null = true))))
    Base.invokelatest(Models.set_models, mod, key)
    return Base.invokelatest(getfield, mod, :Result)
  end
  ordered(r) = squash(PormG.inspect_query(r.objects.order_by("-points"))[:sql_text])
  windowed(r) = r.objects.values("resultid", "rn" => PormG.QueryBuilder.RowNumber(over = PormG.QueryBuilder.WindowOver(order_by = ["-points"])))
  refused(f) = try f(); nothing catch e; e end
  keys = String[]
  try
    for (v, sql) in ((3_029_000, "SELECT * FROM \"result\" as \"Tb\" ORDER BY (\"Tb\".\"points\" IS NULL) DESC, \"Tb\".\"points\" DESC"),
                     (3_030_000, "SELECT * FROM \"result\" as \"Tb\" ORDER BY \"Tb\".\"points\" DESC NULLS FIRST"))
      push!(keys, "reg1452_v$(v)")
      @test ordered(offline_result(last(keys); server_version = v)) == sql
    end

    push!(keys, "reg1452_v3024000")
    old = offline_result(last(keys); server_version = 3_024_000)
    err = refused(() -> PormG.inspect_query(windowed(old)))
    @test err isa PormG.BackendCapabilityError
    @test err !== nothing && occursin("3.25.0", sprint(showerror, err)) && occursin("3.24.0", sprint(showerror, err))
    @test PormG.QueryBuilder._backend_parameter_limit(PormG.config[last(keys)].connections) == 999
    # The public path: 1000 one-parameter rows are two statements under 3.32.0's 999 limit, one from it.
    rows = DataFrame(points = Float64.(1:1000))
    statements(r) = r isa Vector ? length(r) : 1   # one statement comes back as its Dict, not a vector
    @test statements(PormG.QueryBuilder.bulk_insert(old.objects, rows; show_query = :dict)) == 2
    push!(keys, "reg1452_v3045000")
    @test statements(PormG.QueryBuilder.bulk_insert(offline_result(last(keys); server_version = 3_045_000).objects, rows;
                                                    show_query = :dict)) == 1

    push!(keys, "reg1452_unset")
    unset = offline_result(last(keys))
    @test squash(PormG.inspect_query(unset.objects.filter("points" => 1.0))[:sql_text]) ==
          "SELECT * FROM \"result\" as \"Tb\" WHERE \"Tb\".\"points\" = ?"
    for f in (() -> ordered(unset), () -> PormG.inspect_query(windowed(unset)),
              () -> PormG.QueryBuilder.bulk_insert(unset.objects, DataFrame(points = [1.0]); show_query = :dict),
              () -> PormG.QueryBuilder._backend_parameter_limit(PormG.config[last(keys)].connections))
      err = refused(f)
      @test err isa PormG.InvalidConfigurationError
      @test err !== nothing && occursin("server_version", sprint(showerror, err))
    end

    @test_throws PormG.InvalidConfigurationError Configuration.register_offline("reg1452_pg"; server_version = 160_000)
    @test_throws PormG.InvalidConfigurationError Configuration.register_offline("reg1452_zero"; adapter = :sqlite, server_version = 0)
    @test !haskey(PormG.config, "reg1452_pg") && !haskey(PormG.config, "reg1452_zero")
  finally
    foreach(Configuration.unregister_connection, keys)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# loaded_keys and close_all!
# What it tests: `loaded_keys()` lists static and dynamic entries, sorted; `close_all!()` closes
#   every pool and keeps every entry registered, returning `nothing`.
# Why it matters: "which keys are loaded?" was `for (k, s) in PormG.config`, in Dict order; the
#   atexit cleanup scripts called was `__cleanup__()`, an internal name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "loaded_keys and close_all! (#1229)" begin
  saved = copy(PormG.config)
  try
    empty!(PormG.config)
    @test Configuration.loaded_keys() == String[]
    Configuration.register_offline("reg1229_b")
    Configuration.register_connection("reg1229_a", ":memory:"; adapter = "SQLite", env = "test")
    @test Configuration.loaded_keys() == ["reg1229_a", "reg1229_b"]

    pool = PormG.config["reg1229_a"].connections
    conn = PormG.ConnectionPool.acquire_connection(pool)        # open a physical connection
    PormG.ConnectionPool.release_connection(pool, conn)
    @test any(!isnothing, pool.connections)
    @test Configuration.close_all!() === nothing
    @test all(isnothing, pool.connections)
    @test Configuration.loaded_keys() == ["reg1229_a", "reg1229_b"]   # entries stay
  finally
    for k in collect(keys(PormG.config))
      try Configuration.unregister_connection(k) catch end
    end
    empty!(PormG.config)
    merge!(PormG.config, saved)
  end
end
