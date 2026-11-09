using Test
using PormG
using PormG.Models: Model, CharField, IDField, DateTimeField

# ─────────────────────────────────────────────────────────────────────────────
# Row-level update_or_create (#30)
#
# DB-free: `show_query=:sql`/`:dict` render the full statement before any DB call, so the
# ON CONFLICT target/SET, the PG xmax created-sentinel, the SQLite RETURNING-avoidance, the
# db_column mapping, the auto_now-on-update refresh, and every validation error are all
# assertable against bare mock connections. Mirrors test_bulk_on_conflict.jl.
# ─────────────────────────────────────────────────────────────────────────────

# db_column-mapped model (team -> team_name) proves the clause renders physical names.
UocConstructor = Model("constructor",
  id = IDField(),
  constructorref = CharField(),
  team = CharField(db_column = "team_name"),
)
UocConstructor.connect_key = "uoc_pg"

UocConstructorSl = Model("constructor",
  id = IDField(),
  constructorref = CharField(),
  team = CharField(db_column = "team_name"),
)
UocConstructorSl.connect_key = "uoc_sqlite"

# Model with an auto_now field, to prove auto_now is refreshed on the DO UPDATE arm.
UocEvt = Model("evt",
  id = IDField(),
  name = CharField(),
  updated_at = DateTimeField(auto_now = true),
)
UocEvt.connect_key = "uoc_pg"

struct MockPgUOC <: PormG.PormGPostgres end
struct MockSqliteUOC <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::MockSqliteUOC) = 3045000

PormG.config["uoc_pg"] = PormG.Configuration.Settings(connections = MockPgUOC(), change_data = true)
PormG.config["uoc_sqlite"] = PormG.Configuration.Settings(connections = MockSqliteUOC(), change_data = true)

@testset "update_or_create SQL rendering (PostgreSQL mock)" begin
  sql = UocConstructor.objects.update_or_create("id" => 1;
    defaults = ["constructorref" => "mclaren", "team" => "McLaren"], show_query = :sql)

  # ON CONFLICT on the lookup field; SET lists only the defaults.
  @test occursin("ON CONFLICT (\"id\") DO UPDATE SET \"constructorref\" = EXCLUDED.\"constructorref\", \"team_name\" = EXCLUDED.\"team_name\"", sql)
  # db_column mapping: logical team renders as physical team_name in the SET.
  @test !occursin("\"team\" = EXCLUDED", sql)
  # PG created-detection sentinel on RETURNING.
  # #1490: the declared columns (physical `team_name`), never `*`, then the sentinel.
  @test occursin("RETURNING \"id\", \"constructorref\", \"team_name\", (xmax = 0) AS \"__pormg_created\"", sql)
  # The lookup field is NOT in the SET (it's the match key, not an updated column).
  @test !occursin("\"id\" = EXCLUDED", sql)

  # Multi-column lookup → composite conflict target.
  sql_multi = UocConstructor.objects.update_or_create("id" => 1, "constructorref" => "mclaren";
    defaults = ["team" => "X"], show_query = :sql)
  @test occursin("ON CONFLICT (\"id\", \"constructorref\") DO UPDATE SET \"team_name\" = EXCLUDED.\"team_name\"", sql_multi)

  # db_column field as the conflict target resolves to the physical column too.
  sql_dbcol_target = UocConstructor.objects.update_or_create("team" => "McLaren";
    defaults = ["constructorref" => "mclaren"], show_query = :sql)
  @test occursin("ON CONFLICT (\"team_name\") DO UPDATE SET \"constructorref\" = EXCLUDED.\"constructorref\"", sql_dbcol_target)
end

@testset "update_or_create refreshes auto_now on the update arm" begin
  # updated_at (auto_now) is filled into the INSERT AND appended to the SET, so a conflict
  # refreshes it — matching update()'s auto_now behavior.
  sql = UocEvt.objects.update_or_create("id" => 1; defaults = ["name" => "x"], show_query = :sql)
  @test occursin("\"updated_at\"", sql)                              # in the INSERT column list
  @test occursin("\"updated_at\" = EXCLUDED.\"updated_at\"", sql)    # refreshed in the SET
  @test occursin("\"name\" = EXCLUDED.\"name\"", sql)

  # An auto_now field used as the lookup (conflict target) must NOT be auto-added to the SET —
  # the match key is never updated. Only the default (name) is in the SET.
  sql_ts_lookup = UocEvt.objects.update_or_create("updated_at" => "2024-01-01"; defaults = ["name" => "x"], show_query = :sql)
  @test occursin("ON CONFLICT (\"updated_at\") DO UPDATE SET \"name\" = EXCLUDED.\"name\"", sql_ts_lookup)
  @test !occursin("\"updated_at\" = EXCLUDED", sql_ts_lookup)        # target not written into SET
end

@testset "update_or_create parameters cover the merged insert values" begin
  res = UocConstructor.objects.update_or_create("id" => 1;
    defaults = ["constructorref" => "mclaren", "team" => "McLaren"], show_query = :dict)
  @test res isa Dict
  @test haskey(res, :sql_text)
  # VALUES binds one param per participating column (lookup ∪ defaults): id, constructorref, team.
  @test length(res[:parameters]) == 3
  @test 1 in res[:parameters]
  @test "mclaren" in res[:parameters]
  @test "McLaren" in res[:parameters]
end

@testset "update_or_create SQLite avoids RETURNING" begin
  sql = UocConstructorSl.objects.update_or_create("id" => 1;
    defaults = ["constructorref" => "mclaren", "team" => "McLaren"], show_query = :sql)
  @test occursin("ON CONFLICT (\"id\") DO UPDATE SET \"constructorref\" = EXCLUDED.\"constructorref\", \"team_name\" = EXCLUDED.\"team_name\"", sql)
  # SQLite path deliberately avoids RETURNING (created detection is out-of-band).
  @test !occursin("RETURNING", sql)
  @test !occursin("__pormg_created", sql)
  @test !occursin("xmax", sql)
end

# Runs update_or_create with :dict (validation fires before any DB call) and returns the message.
function _uoc_error(f)
  err = try
    f()
    nothing
  catch e
    e
  end
  @test err isa PormGError
  # Strip ANSI so the content assertions are color-agnostic: CI runs --color=yes, which bakes the
  # field-name highlight (\e[4m\e[31m…\e[0m) into the message via the subtype constructor's _emsg. Reuse the repo's own
  # stripper so the assertions still check the message TEXT (incl. the offending field name), not TTY state.
  return err === nothing ? "" : PormG._emsg(sprint(showerror, err); color = false)
end

@testset "update_or_create validation errors" begin
  @test occursin("at least one lookup pair",
    _uoc_error(() -> UocConstructor.objects.update_or_create(; defaults = ["constructorref" => "x"], show_query = :dict)))
  @test occursin("`defaults` must be non-empty",
    _uoc_error(() -> UocConstructor.objects.update_or_create("id" => 1; show_query = :dict)))
  @test occursin("must be a `field => value` pair",
    _uoc_error(() -> UocConstructor.objects.update_or_create("id" => 1; defaults = ["constructorref"], show_query = :dict)))
  @test occursin("lookup field nope is not a field",
    _uoc_error(() -> UocConstructor.objects.update_or_create("nope" => 1; defaults = ["constructorref" => "x"], show_query = :dict)))
  @test occursin("defaults field nope is not a field",
    _uoc_error(() -> UocConstructor.objects.update_or_create("id" => 1; defaults = ["nope" => "x"], show_query = :dict)))
  @test occursin("appear in both lookup and defaults",
    _uoc_error(() -> UocConstructor.objects.update_or_create("id" => 1; defaults = ["id" => 2, "constructorref" => "x"], show_query = :dict)))
  @test occursin("duplicate lookup field",
    _uoc_error(() -> UocConstructor.objects.update_or_create("id" => 1, "id" => 2; defaults = ["constructorref" => "x"], show_query = :dict)))
  @test occursin("duplicate defaults field",
    _uoc_error(() -> UocConstructor.objects.update_or_create("id" => 1; defaults = ["constructorref" => "a", "constructorref" => "b"], show_query = :dict)))
end
