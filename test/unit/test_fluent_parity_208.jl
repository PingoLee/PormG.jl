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
  # No-update match-or-insert: DO NOTHING (never DO UPDATE). On PostgreSQL a miss sends the INSERT
  # with `RETURNING *` — an empty result is how a lost insert race is detected — so since #48 the
  # :sql form shows it too: inspection shows the statement that executes. (It used to assert the
  # opposite, which was true only of SQLite's plain INSERT + out-of-band read-back, below.)
  sql = GocPg.objects.get_or_create("code" => "HAM"; defaults = ["surname" => "Hamilton"], show_query = :sql)
  @test occursin("ON CONFLICT (\"code\") DO NOTHING", sql)
  @test !occursin("DO UPDATE", sql)
  @test endswith(rstrip(sql), "DO NOTHING RETURNING *;")
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

# ─────────────────────────────────────────────────────────────────────────────
# A missing conflict target is recognized by SQLSTATE on PostgreSQL (#1001)
# `42P10` is the signal there, because the server localizes the message: a `pt_BR` one still gets
# the actionable error, and English "on conflict … unique" text under another SQLSTATE does not.
# SQLite has no SQLSTATE and does not localize, so its message stays the signal.
# ─────────────────────────────────────────────────────────────────────────────
# What `_rethrow_conflict_target_error` raises for `e` — it rethrows, so it must run inside a catch.
function _conflict_target_outcome(e)
  try
    try
      throw(e)
    catch caught
      PormG.QueryBuilder._rethrow_conflict_target_error(caught, GocPg, ["code"])
    end
  catch out
    out
  end
end

@testset "get_or_create's missing conflict target is recognized by SQLSTATE (#1001)" begin
  pt_br = PormG.StatementError("PostgreSQL", ErrorException("mock"); sqlstate = "42P10",
    message = "não há restrição de unicidade ou de exclusão que corresponda à especificação ON CONFLICT")
  @test _conflict_target_outcome(pt_br) isa PormG.QueryBuildError

  english_other = PormG.StatementError("PostgreSQL", ErrorException("mock"); sqlstate = "42601",
    message = "there is no unique or exclusion constraint matching the ON CONFLICT specification")
  @test _conflict_target_outcome(english_other) === english_other

  sqlite = PormG.StatementError("SQLite", ErrorException("mock");
    message = "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint")
  @test _conflict_target_outcome(sqlite) isa PormG.QueryBuildError
end

@testset "last() inverts ordering and falls back to primary key" begin
  # Explicit ASC ordering → last() renders DESC + LIMIT 1.
  q = GocPg.objects
  q.order_by("points")
  sql = q.last(show_query = :sql)
  @test occursin("DESC", sql)
  @test occursin("LIMIT \$1", sql)
  @test q.last(show_query = :params) == [1]   # the LIMIT binds (#46)

  # Explicit DESC ordering ("-points") → last() renders ASC.
  q2 = GocPg.objects
  q2.order_by("-points")
  @test occursin("ASC", q2.last(show_query = :sql))

  # No ordering → falls back to primary-key DESC so last() is well-defined (Django parity).
  sql_pk = GocPg.objects.last(show_query = :sql)
  @test occursin("\"id\" DESC", sql_pk)
  @test occursin("LIMIT \$1", sql_pk)

  # NULLS placement must invert together with the direction: ASC NULLS FIRST → DESC NULLS LAST.
  # (Guards the `_invert_order` bug — `_invert_order!` before #540 — where two sequential `&&`
  # swaps left :first unchanged.)
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
  @test q3.object.limit === nothing         # limit(1) applied only to the internal copy
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
  # _page!(::SQLObject, ::Tuple{Integer, Integer}) existed, so the single-argument form raised a bare
  # MethodError. Asserted on the rendered statement, not just the handler field, because
  # execution_read.jl only emits each clause when the field is set.
  q2 = GocPg.objects
  q2.page(20, 10)
  @test q2.object.limit == 20
  @test q2.object.offset == 10
  sql2 = q2.list(show_query = :sql)
  @test occursin("LIMIT \$1", sql2)
  @test occursin("OFFSET \$2", sql2)
  @test q2.list(show_query = :params) == [20, 10]   # bound, LIMIT first (#46)

  # One-argument form: LIMIT only. offset stays 0, so NO OFFSET clause is emitted at all.
  q1 = GocPg.objects
  q1.page(20)
  @test q1.object.limit == 20
  @test q1.object.offset == 0
  sql1 = q1.list(show_query = :sql)
  @test occursin("LIMIT \$1", sql1)
  @test !occursin("OFFSET", sql1)
  @test q1.list(show_query = :params) == [20]

  # page(n) is limit-only, NOT a pagination reset: an offset already on the handler survives it.
  # This is the contract that separates it from page(limit, offset).
  q3 = GocPg.objects
  q3.offset(30)
  q3.page(5)
  @test q3.object.limit == 5
  @test q3.object.offset == 30
  @test occursin("OFFSET \$2", q3.list(show_query = :sql))
  @test q3.list(show_query = :params) == [5, 30]

  # Chainable: the ChainCaller returns the handler, so page() composes like every other mutator.
  q4 = GocPg.objects
  @test q4.page(7).order_by("points") === q4
  @test q4.object.limit == 7
end

@testset "fluent .page(...) and the internal page() stay in lockstep (#272)" begin
  # ROOT CAUSE GUARD. `page` (SQLObjectHandler, object_manager.jl) and `_page!` (SQLObject, behind the
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
  # #231/#239: every PormG domain failure is a PormGError. `_page!` had no ::Any fallback, so
  # query.page("20","10"), query.page() and query.page(1,2,3) all escaped as raw MethodErrors
  # naming a `page!` (its spelling before #281) and a Tuple that appear nowhere in the caller's code.
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
  # to say "Error in page" even though they are thrown by _limit!/_offset!.
  @test occursin("limit()",  _p208_error(() -> q.limit("20")))
  @test occursin("offset()", _p208_error(() -> q.offset("40")))
  @test_throws PormG.QueryBuildError q.limit()
  @test_throws PormG.QueryBuildError q.offset(1, 2)

  # A rejected call must not half-apply — the handler is untouched by every throw above.
  @test q.object.limit === nothing
  @test q.object.offset == 0
end

# #1049: a negative or `Bool` LIMIT / OFFSET reached the SQL, where the engines disagree — PostgreSQL
# raises, SQLite reads a negative LIMIT as "no limit" (every row) and binds `true` as 1. Confirmed
# live on both engines before the fix. Refused at the call instead, on both mocks alike.
@testset "limit()/offset()/page() refuse a negative or Bool value (#1049)" begin
  for model in (GocPg, GocSl)
    refused = (
      "limit(-1)"         => q -> q.limit(-1),
      "limit(true)"       => q -> q.limit(true),
      "limit(false)"      => q -> q.limit(false),
      "offset(-1)"        => q -> q.offset(-1),
      "offset(false)"     => q -> q.offset(false),
      "page(-1)"          => q -> q.page(-1),
      "page(true)"        => q -> q.page(true),
      "page(10, -1)"      => q -> q.page(10, -1),
      "page(10, true)"    => q -> q.page(10, true),
      "page(-1, 10)"      => q -> q.page(-1, 10),
      # the un-exported function forms, which test_fluent_parity pins to the fluent ones
      "page(h, -1)"       => q -> PormG.QueryBuilder.page(q, -1),
      "page(h, 10, -1)"   => q -> PormG.QueryBuilder.page(q, 10, -1),
      "page(h; offset=-1)" => q -> PormG.QueryBuilder.page(q; limit = 10, offset = -1),
      "page(h; limit=true)" => q -> PormG.QueryBuilder.page(q; limit = true),
    )
    for (label, call) in refused
      q = model.objects
      q.limit(7).offset(3)
      err = try
        call(q); nothing
      catch e
        e
      end
      @test err isa PormG.QueryBuildError
      # Nothing half-applies: page(10, -1) must not leave limit 10 behind its refused offset.
      @test (q.object.limit, q.object.offset) == (7, 3)
    end

    # Message, not only type — the tokens that identify THIS guard and its value.
    q = model.objects
    neg = _p208_error(() -> q.limit(-5))
    @test occursin("limit() must not be negative, got -5", neg)
    @test occursin("limit(nothing)", neg)                       # names the no-limit spelling
    off = _p208_error(() -> q.page(5, -2))
    @test occursin("page()'s offset must not be negative, got -2", off)
    @test occursin("For no offset, pass 0", off)                # an offset's own fix…
    @test !occursin("limit(nothing)", off)                      # …not the limit's
    @test occursin("offset() takes an Integer row count, got the Bool true", _p208_error(() -> q.offset(true)))
  end
end

# #1049: `0` used to be the no-limit sentinel, so `limit(0)` — a page size computed as zero —
# returned every row, where SQL's LIMIT 0 and Django's `qs[:0]` return none. It now binds 0, and
# "no limit" is `nothing`.
@testset "limit(0) is zero rows; limit(nothing) is no limit (#1049)" begin
  for (model, marker) in ((GocPg, "\$1"), (GocSl, "?"))
    q0 = model.objects
    q0.limit(0)
    @test q0.object.limit == 0
    @test occursin("LIMIT $(marker)", q0.list(show_query = :sql))
    @test q0.list(show_query = :params) == [0]

    # Any zero Integer — #46 had briefly made Int32(0) the sentinel too.
    qi = model.objects
    qi.limit(Int32(0))
    @test qi.list(show_query = :params) == [0]

    # limit(nothing) clears a limit already set, and binds nothing.
    qn = model.objects
    qn.limit(5).limit(nothing)
    @test qn.object.limit === nothing
    @test !occursin("LIMIT", qn.list(show_query = :sql))
    @test isempty(qn.list(show_query = :params))

    # page(0, n) is a real zero-row page, both values bound.
    qp = model.objects
    qp.page(0, 20)
    @test qp.list(show_query = :params) == [0, 20]

    # #1053: an aggregate on a sliced handler is refused. It used to drop the slice on its copy and
    # aggregate every row, which is not what a `limit(0)` asked for (see the #1053 testset below).
    @test occursin("aggregate() cannot run on a query with limit() or offset() set",
      _p208_error(() -> model.objects.limit(0).aggregate("n" => Count("id"), show_query = :sql)))
  end

  # An offset with no limit keeps SQLite's no-limit spelling (#46): the `nothing` limit, not 0.
  qo = GocSl.objects
  qo.offset(5)
  @test occursin("LIMIT -1 \nOFFSET ?", qo.list(show_query = :sql))
  @test qo.list(show_query = :params) == [5]
  @test !occursin("LIMIT", GocPg.objects.offset(5).list(show_query = :sql))
end

# #1053: the read terminals run on a copy, and each one used to overwrite the copy's limit with its
# own probe size, or clear it. After #1049 made `limit(0)` zero rows, `q.limit(0).list()` returned
# nothing while `exists()` said rows existed and `first()`/`get()` returned one. They now combine
# their probe with the caller's slice the way Django's `set_limits` does (the smaller limit, the
# caller's offset kept), and the terminals that cannot honor a slice refuse it.
@testset "read terminals honor a user slice (#1053)" begin
  for (model, m) in ((GocPg, i -> "\$$(i)"), (GocSl, _ -> "?"))
    # exists(): LIMIT 0 under a limit(0), LIMIT 1 otherwise; the offset still binds (#46).
    @test occursin("LIMIT 0", model.objects.limit(0).exists(show_query = :sql))
    @test isempty(model.objects.limit(0).exists(show_query = :params))
    @test occursin("LIMIT 1", model.objects.limit(5).exists(show_query = :sql))
    @test !occursin("LIMIT 0", model.objects.limit(5).exists(show_query = :sql))
    qe = model.objects.filter("code" => "HAM").limit(0).offset(4)
    @test occursin(Regex("LIMIT 0\\s+OFFSET \\Q$(m(2))\\E"), qe.exists(show_query = :sql))
    @test qe.exists(show_query = :params) == Any["HAM", 4]
    # An unsliced exists() is unchanged.
    @test occursin("LIMIT 1", model.objects.exists(show_query = :sql))

    # first(): the smaller of the caller's limit and 1, the caller's offset kept.
    @test model.objects.limit(0).first(show_query = :params) == [0]
    @test model.objects.limit(5).first(show_query = :params) == [1]
    @test model.objects.offset(10).first(show_query = :params) == [1, 10]

    # get(): the smaller of the caller's limit and 2; inline filters join WHERE ahead of the slice.
    @test model.objects.limit(0).get(show_query = :params) == [0]
    @test model.objects.limit(1).get(show_query = :params) == [1]
    @test model.objects.limit(5).offset(3).get("code" => "HAM"; show_query = :params) == Any["HAM", 2, 3]

    # count(): COUNT(*) over the sliced rows, the tail bound last inside the subquery.
    qc = model.objects.filter("code" => "HAM").limit(5).offset(10)
    sql_c = qc.count(show_query = :sql)
    @test occursin("SELECT COUNT(*) FROM (", sql_c)
    @test occursin(Regex("LIMIT \\Q$(m(2))\\E\\s+OFFSET \\Q$(m(3))\\E\\s*\\) as \"__pormg_sliced_count\""), sql_c)
    @test qc.count(show_query = :params) == Any["HAM", 5, 10]
    @test model.objects.limit(0).count(show_query = :params) == [0]
    # distinct: the slice applies after DISTINCT, so it goes inside the same subquery.
    sql_d = model.objects.limit(5).count(distinct = true, show_query = :sql)
    @test occursin(Regex("SELECT DISTINCT \\*[\\s\\S]*LIMIT \\Q$(m(1))\\E\\s*\\) as \"__pormg_distinct_count\""), sql_d)
    # An unsliced count() is the plain COUNT(*), no subquery.
    @test !occursin("FROM (", model.objects.count(show_query = :sql))
    @test isempty(model.objects.count(show_query = :params))

    # Exists(sub): the subquery keeps its slice. Its OFFSET binds inside the nested run, so the
    # outer value after it still binds last on both engines.
    sub = model.objects.filter("code" => "X").limit(0).offset(2)
    qx = model.objects.filter("points" => 7, Exists(sub)).filter("surname" => "S")
    sql_x = qx.list(show_query = :sql)
    @test occursin(Regex("LIMIT 0 OFFSET \\Q$(m(3))\\E\\)"), sql_x)
    @test qx.list(show_query = :params) == Any[7, "X", 2, "S"]
    # The same run in a projection binds under SELECT, ahead of the outer WHERE value, and inside a
    # Qor it stays between the values written either side of it.
    qp = model.objects.values("code", "x" => Exists(model.objects.filter("code" => "Y").offset(2)))
    qp.filter("points" => 7)
    @test qp.list(show_query = :params) == Any["Y", 2, 7]
    qo = model.objects.filter(Qor("points" => 1, Exists(model.objects.filter("code" => "Z").offset(3))), "surname" => "S")
    @test qo.list(show_query = :params) == Any[1, "Z", 3, "S"]
    @test occursin("LIMIT 1)", model.objects.filter(Exists(model.objects.filter("code" => "X").limit(5))).list(show_query = :sql))
    @test occursin("LIMIT 1)", model.objects.filter(Exists(model.objects.filter("code" => "X"))).list(show_query = :sql))

    # The caller's handler keeps its slice; the probe lives on the copy only (#199).
    qh = model.objects.limit(3)
    qh.first(show_query = :params); qh.get(show_query = :params); qh.exists(show_query = :params); qh.count(show_query = :params)
    @test qh.object.limit == 3
  end
end

@testset "terminals that reorder or aggregate refuse a sliced query (#1053)" begin
  for slice! in (q -> q.limit(5), q -> q.limit(0), q -> q.offset(1))
    q = slice!(GocPg.objects)
    @test occursin("last() cannot run on a query with limit() or offset() set",
      _p208_error(() -> q.last(show_query = :sql)))
    @test occursin("earliest() cannot run on a query with limit() or offset() set",
      _p208_error(() -> q.earliest("points"; show_query = :sql)))
    @test occursin("latest() cannot run on a query with limit() or offset() set",
      _p208_error(() -> q.latest("points"; show_query = :sql)))
    @test occursin("count(column) cannot run on a query with limit() or offset() set",
      _p208_error(() -> q.count("points"; show_query = :sql)))
    @test occursin("aggregate() cannot run on a query with limit() or offset() set",
      _p208_error(() -> q.aggregate("n" => Count("id"); show_query = :sql)))
  end
  # Cleared slices are not slices: limit(nothing) and offset(0) lift the refusal.
  q = GocPg.objects.limit(5).offset(1)
  q.limit(nothing).offset(0)
  @test occursin("LIMIT", q.last(show_query = :sql))
  @test occursin("COUNT(", q.count("points"; show_query = :sql))
end

@testset "ChainCaller rejects keyword arguments as a PormGError (#272)" begin
  # The docs name the parameters (`.page(limit = 20)`) and five sibling fluent methods (.with,
  # .cjoin, .cjoin_on, .on, .select_for_update) are closures that DO take keywords — so a keyword
  # call on a ChainCaller method is a natural user mistake. It used to die on the functor itself
  # with a MethodError naming `ChainCaller{typeof(page!), ObjectHandler}` (the pre-#281 spelling of
  # `_page!`), outside the taxonomy and
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
  # meant.
  #
  # Both halves run over the SAME four methods, and the negative half is the load-bearing one.
  # Since #281 every helper is spelled `_verb!`, so the positive assertion alone is nearly blind:
  # deleting the `^_` strip leaves `_page()` in the message, which still contains "page()" and still
  # passes. Only the negative assertion catches it. Assert the full internal spellings (`_page`,
  # `page!`) rather than a bare "_" or "!" — punctuation added to the sentence later would trip
  # those without anything being wrong.
  for (call, name) in ((() -> qk.page(limit = 20),        "page"),
                       (() -> qk.filter(code = "HAM"),    "filter"),
                       (() -> qk.values(fields = "code"), "values"),
                       (() -> qk.order_by(field = "pts"), "order_by"))
    msg_i = _p208_error(call)
    @test occursin("$(name)()", msg_i)
    @test !occursin("_$(name)", msg_i)
    @test !occursin("$(name)!", msg_i)
  end

  # Rejected before the mutator runs: nothing is half-applied.
  @test qk.object.limit === nothing
  @test qk.object.offset == 0
  @test isempty(qk.object.filter)

  # The positional path is untouched by the kwargs slurp.
  @test qk.page(20, 40) === qk
  @test (qk.object.limit, qk.object.offset) == (20, 40)
end
