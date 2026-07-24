using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
using PormG.Functions: Sum, Count, Avg
using PormG.QueryBuilder: SQLOrder, SQLField

# ─────────────────────────────────────────────────────────────────────────────
# Fluent parity gaps (#208): get_or_create, last(), aggregate()
#
# DB-free: `show_query=:sql`/`:dict` render the full statement before any DB round-trip, so the
# get_or_create ON CONFLICT DO NOTHING clause, the last() ORDER-BY inversion + pk fallback, the
# aggregate() no-GROUP-BY projection, and every validation error are all assertable against bare
# mock connections. Mirrors test_update_or_create.jl. (Row correctness lives in the integration
# suite, which needs a live DB.)
# ─────────────────────────────────────────────────────────────────────────────

struct MockPg208 <: PormG.PormGPostgres end
struct MockSqlite208 <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::MockSqlite208) = 3045000

PormG.config["p208_pg"] = PormG.Configuration.Settings(connections = MockPg208(), change_data = true)
PormG.config["p208_sqlite"] = PormG.Configuration.Settings(connections = MockSqlite208(), change_data = true)

# db_column-mapped field (surname -> family_name) proves the ON CONFLICT target renders the physical column.
GocPg = Model("goc_driver",
  id = IDField(),
  code = CharField(),
  surname = CharField(db_column = "family_name", null = true),
  points = IntegerField(null = true),
)
GocPg.connect_key = "p208_pg"

GocSl = Model("goc_driver",
  id = IDField(),
  code = CharField(),
  surname = CharField(db_column = "family_name", null = true),
  points = IntegerField(null = true),
)
GocSl.connect_key = "p208_sqlite"

# Runs a terminal with :dict (validation fires before any DB call) and returns the stripped message.
function _p208_error(f)
  err = try
    f(); nothing
  catch e
    e
  end
  @test err isa PormGError
  return err === nothing ? "" : PormG._emsg(sprint(showerror, err); color = false)
end

@testset "get_or_create SQL rendering (PostgreSQL mock)" begin
  # No-update match-or-insert: DO NOTHING (never DO UPDATE), and the :sql form has no RETURNING
  # (the created-flag + read-back are out-of-band on the execute path).
  sql = GocPg.objects.get_or_create("code" => "HAM"; defaults = ["surname" => "Hamilton"], show_query = :sql)
  @test occursin("ON CONFLICT (\"code\") DO NOTHING", sql)
  @test !occursin("DO UPDATE", sql)
  @test !occursin("RETURNING", sql)
  # defaults are create-only extras merged into the INSERT column list (physical db_column name).
  @test occursin("\"family_name\"", sql)

  # Multi-column lookup → composite conflict target; db_column field resolves physically.
  sql_multi = GocPg.objects.get_or_create("code" => "HAM", "surname" => "Hamilton"; show_query = :sql)
  @test occursin("ON CONFLICT (\"code\", \"family_name\") DO NOTHING", sql_multi)

  # defaults are OPTIONAL for get_or_create (unlike update_or_create) — pure get-or-create renders fine.
  sql_nodef = GocPg.objects.get_or_create("code" => "HAM"; show_query = :sql)
  @test occursin("ON CONFLICT (\"code\") DO NOTHING", sql_nodef)
end

@testset "get_or_create SQLite avoids RETURNING" begin
  sql = GocSl.objects.get_or_create("code" => "HAM"; defaults = ["surname" => "Hamilton"], show_query = :sql)
  @test occursin("ON CONFLICT (\"code\") DO NOTHING", sql)
  @test !occursin("RETURNING", sql)
  @test !occursin("DO UPDATE", sql)
end

@testset "get_or_create validation errors" begin
  @test occursin("at least one lookup pair",
    _p208_error(() -> GocPg.objects.get_or_create(; defaults = ["surname" => "x"], show_query = :dict)))
  @test occursin("must be a `field => value` pair",
    _p208_error(() -> GocPg.objects.get_or_create("code"; show_query = :dict)))
  @test occursin("lookup field nope is not a field",
    _p208_error(() -> GocPg.objects.get_or_create("nope" => 1; show_query = :dict)))
  @test occursin("defaults field nope is not a field",
    _p208_error(() -> GocPg.objects.get_or_create("code" => "x"; defaults = ["nope" => 1], show_query = :dict)))
  @test occursin("appear in both lookup and defaults",
    _p208_error(() -> GocPg.objects.get_or_create("code" => "x"; defaults = ["code" => "y"], show_query = :dict)))
  @test occursin("duplicate lookup field",
    _p208_error(() -> GocPg.objects.get_or_create("code" => "x", "code" => "y"; show_query = :dict)))
  # Error messages are attributed to get_or_create, not update_or_create.
  @test occursin("Error in get_or_create",
    _p208_error(() -> GocPg.objects.get_or_create("nope" => 1; show_query = :dict)))
end

@testset "last() inverts ordering and falls back to primary key" begin
  # Explicit ASC ordering → last() renders DESC + LIMIT 1.
  q = GocPg.objects
  q.order_by("points")
  sql = q.last(show_query = :sql)
  @test occursin("DESC", sql)
  @test occursin("LIMIT 1", sql)

  # Explicit DESC ordering ("-points") → last() renders ASC.
  q2 = GocPg.objects
  q2.order_by("-points")
  @test occursin("ASC", q2.last(show_query = :sql))

  # No ordering → falls back to primary-key DESC so last() is well-defined (Django parity).
  sql_pk = GocPg.objects.last(show_query = :sql)
  @test occursin("\"id\" DESC", sql_pk)
  @test occursin("LIMIT 1", sql_pk)

  # NULLS placement must invert together with the direction: ASC NULLS FIRST → DESC NULLS LAST.
  # (Guards the _invert_order! bug where two sequential `&&` swaps left :first unchanged.)
  qn = GocPg.objects
  qn.order_by(SQLOrder(SQLField("points", "points"); orientation = "ASC", nulls = :first))
  sqln = qn.last(show_query = :sql)
  @test occursin("DESC", sqln)
  @test occursin("NULLS LAST", sqln)
  @test !occursin("NULLS FIRST", sqln)

  # last() does NOT leak its ordering flip / limit into the caller's handler (#199 copy-first).
  q3 = GocPg.objects
  q3.order_by("points")
  q3.last(show_query = :sql)
  @test isempty(q3.object.filter)          # untouched
  @test q3.object.limit == 0               # limit(1) applied only to the internal copy
  @test length(q3.object.order) == 1 && q3.object.order[1].orientation == "ASC"  # still ASC
end

@testset "aggregate() renders a whole-queryset aggregate with no GROUP BY" begin
  sql = GocPg.objects.aggregate("total" => Sum("points"), "n" => Count("id"), show_query = :sql)
  @test occursin("SUM(", sql)
  @test occursin("COUNT(", sql)
  @test occursin("total", sql) && occursin("n", sql)   # aliases present
  @test !occursin("GROUP BY", sql)                     # whole-queryset: no grouping
end

@testset "aggregate() validation errors" begin
  @test occursin("requires at least one",
    _p208_error(() -> GocPg.objects.aggregate(show_query = :dict)))
  # A non-aggregate value is rejected (would otherwise return N rows, not one scalar row).
  @test occursin("must be an aggregate function",
    _p208_error(() -> GocPg.objects.aggregate("x" => 5, show_query = :dict)))
  # Refuses to silently discard values() grouping columns.
  qv = GocPg.objects
  qv.values("code")
  @test occursin("cannot combine with values() grouping",
    _p208_error(() -> qv.aggregate("total" => Sum("points"), show_query = :dict)))
end
