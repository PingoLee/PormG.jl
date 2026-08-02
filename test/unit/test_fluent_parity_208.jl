using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
using PormG.Functions: Sum, Count, Avg
using PormG.QueryBuilder: SQLOrder, SQLField

# ─────────────────────────────────────────────────────────────────────────────
# Fluent parity gaps (#208, #272): get_or_create, last(), aggregate(), page()
#
# DB-free: `show_query=:sql`/`:dict` render the full statement before any DB round-trip, so the
# get_or_create ON CONFLICT DO NOTHING clause, the last() ORDER-BY inversion + pk fallback, the
# aggregate() no-GROUP-BY projection, the page() LIMIT/OFFSET arities, and every validation error
# are all assertable against bare mock connections. Mirrors test_update_or_create.jl. (Row
# correctness lives in the integration suite, which needs a live DB.)
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
  # #268 audit: get_or_create's unknown-field check now matches update_or_create's type —
  # UnknownFieldError, so `catch FieldAccessError` sees both. A PormGError assertion alone
  # would also pass for the pre-audit QueryBuildError.
  @test_throws PormG.UnknownFieldError GocPg.objects.get_or_create("nope" => 1; show_query = :dict)
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

@testset "page() fluent arities render LIMIT/OFFSET (#272)" begin
  # The `page` docstring had always advertised `query.page(20)`, but only
  # page!(::SQLObject, ::Tuple{Integer, Integer}) existed, so the single-argument form raised a bare
  # MethodError. Asserted on the rendered statement, not just the handler field, because
  # execution.jl only emits each clause when the field is non-zero.
  q2 = GocPg.objects
  q2.page(20, 10)
  @test q2.object.limit == 20
  @test q2.object.offset == 10
  sql2 = q2.list(show_query = :sql)
  @test occursin("LIMIT 20", sql2)
  @test occursin("OFFSET 10", sql2)

  # One-argument form: LIMIT only. offset stays 0, so NO OFFSET clause is emitted at all.
  q1 = GocPg.objects
  q1.page(20)
  @test q1.object.limit == 20
  @test q1.object.offset == 0
  sql1 = q1.list(show_query = :sql)
  @test occursin("LIMIT 20", sql1)
  @test !occursin("OFFSET", sql1)

  # page(n) is limit-only, NOT a pagination reset: an offset already on the handler survives it.
  # This is the contract that separates it from page(limit, offset).
  q3 = GocPg.objects
  q3.offset(30)
  q3.page(5)
  @test q3.object.limit == 5
  @test q3.object.offset == 30
  @test occursin("OFFSET 30", q3.list(show_query = :sql))

  # Chainable: the ChainCaller returns the handler, so page() composes like every other mutator.
  q4 = GocPg.objects
  @test q4.page(7).order_by("points") === q4
  @test q4.object.limit == 7
end

@testset "fluent .page(...) and the internal page() stay in lockstep (#272)" begin
  # ROOT CAUSE GUARD. `page` (SQLObjectHandler, functions.jl) and `page!` (SQLObject, behind the
  # ChainCaller) are two parallel implementations of one contract, and #272 *was* them drifting:
  # the free function grew a limit-only arity, the fluent one did not, and only the docstring
  # noticed. Nothing but this test ties them together — assert equal end state from equal start,
  # so touching one side alone fails here instead of shipping.
  for (label, args) in (("limit only", (20,)), ("limit and offset", (20, 40)))
    for preset_offset in (0, 30)   # 30 proves the limit-only arity preserves an existing offset
      qf = GocPg.objects           # fluent: query.page(args...)
      qi = GocPg.objects           # internal: page(handler, args...)
      qf.offset(preset_offset)
      qi.offset(preset_offset)

      qf.page(args...)
      PormG.QueryBuilder.page(qi, args...)

      @test (qf.object.limit, qf.object.offset) == (qi.object.limit, qi.object.offset)
      # Pin the absolute value too, so the pair agreeing on a WRONG answer still fails.
      expected_offset = length(args) == 2 ? args[2] : preset_offset
      @test (qf.object.limit, qf.object.offset) == (args[1], expected_offset)
    end
  end
end

@testset "page()/limit()/offset() reject non-Integer and wrong-arity arguments (#272)" begin
  # #231/#239: every PormG domain failure is a PormGError. `page!` had no ::Any fallback, so
  # query.page("20","10"), query.page() and query.page(1,2,3) all escaped as raw MethodErrors
  # naming a `page!` and a Tuple that appear nowhere in the caller's code.
  q = GocPg.objects

  @test_throws PormG.QueryBuildError q.page("20", "10")
  @test_throws PormG.QueryBuildError q.page()
  @test_throws PormG.QueryBuildError q.page(1, 2, 3)
  @test_throws PormG.QueryBuildError q.page(20, 10.5)
  @test_throws PormG.PormGError      q.page("20")  # …and QueryBuildError <: the documented catch-all

  # Message, not only type: a bare type assertion passes for ANY QueryBuildError, including one from
  # an unrelated validator. Pin the tokens that identify THIS guard.
  msg = _p208_error(() -> q.page("20", "10"))
  @test occursin("page()", msg)
  @test occursin("Tuple{String", msg)     # echoes what was actually passed
  @test occursin("page(20)", msg)         # names the one-argument arity…
  @test occursin("page(20, 40)", msg)     # …and the two-argument one

  # Sibling mutators share the contract and had NO coverage at all before #272 — their messages used
  # to say "Error in page" even though they are thrown by limit!/offset!.
  @test occursin("limit()",  _p208_error(() -> q.limit("20")))
  @test occursin("offset()", _p208_error(() -> q.offset("40")))
  @test_throws PormG.QueryBuildError q.limit()
  @test_throws PormG.QueryBuildError q.offset(1, 2)

  # A rejected call must not half-apply — the handler is untouched by every throw above.
  @test q.object.limit == 0
  @test q.object.offset == 0
end

@testset "ChainCaller rejects keyword arguments as a PormGError (#272)" begin
  # The docs name the parameters (`.page(limit = 20)`) and five sibling fluent methods (.with,
  # .cjoin, .cjoin_on, .on, .select_for_update) are closures that DO take keywords — so a keyword
  # call on a ChainCaller method is a natural user mistake. It used to die on the functor itself
  # with a MethodError naming `ChainCaller{typeof(page!), ObjectHandler}`, outside the taxonomy and
  # unrecognizable to the caller. Every ChainCaller-backed method shares the one functor, so this
  # is asserted across the family, not just page.
  qk = GocPg.objects
  @test_throws PormG.QueryBuildError qk.page(limit = 20)
  @test_throws PormG.QueryBuildError qk.page(20; offset = 10)
  @test_throws PormG.QueryBuildError qk.limit(n = 20)
  @test_throws PormG.QueryBuildError qk.offset(n = 20)
  @test_throws PormG.QueryBuildError qk.order_by(field = "points")
  @test_throws PormG.QueryBuildError qk.filter(code = "HAM")

  # The message names the offending keyword(s) — without that it cannot tell the user which
  # argument to move, and any unrelated QueryBuildError would satisfy a type-only assertion.
  # Assert the INTERPOLATED segment, not the bare words: "limit" also appears in the static
  # `e.g. … limit(20) …` tail, and the pre-fix MethodError text contained both names too, so
  # `occursin("limit") && occursin("offset")` would have passed before and after the fix.
  # Keys follow call order, so this is deterministic.
  msg = _p208_error(() -> qk.page(limit = 20, offset = 40))
  @test occursin("got: limit, offset", msg)
  @test occursin("positional", msg)

  # …and it names the method the CALLER typed, recovered from the internal helper (#281). Before
  # this the message could only say "here", leaving the user to find which link of a long chain it
  # meant. Cover both prefix shapes: `.filter`/`.values` go through `up_*!` helpers, `.order_by`
  # and `.page` do not — a strip that handled only one would pass on half the family.
  @test occursin("page()", _p208_error(() -> qk.page(limit = 20)))
  @test occursin("filter()", _p208_error(() -> qk.filter(code = "HAM")))
  @test occursin("values()", _p208_error(() -> qk.values(fields = "code")))
  @test occursin("order_by()", _p208_error(() -> qk.order_by(field = "points")))
  # The internal spelling must NOT leak — that is the whole point (`up_filter`, `filter!`).
  # Match the exact internal spellings, not a bare "!": punctuation added to the sentence later
  # would fail that without anything being wrong.
  fmsg = _p208_error(() -> qk.filter(code = "HAM"))
  @test !occursin("up_", fmsg)
  @test !occursin("filter!", fmsg)

  # Rejected before the mutator runs: nothing is half-applied.
  @test qk.object.limit == 0
  @test qk.object.offset == 0
  @test isempty(qk.object.filter)

  # The positional path is untouched by the kwargs slurp.
  @test qk.page(20, 40) === qk
  @test (qk.object.limit, qk.object.offset) == (20, 40)
end
