# =============================================================================
# The joined-copy reference — Joined(alias, path) (#481)
# =============================================================================
#
# `cjoin_on` used to reference its joined copy with a DOTTED STRING, `F("d.surname")`. #481 replaces
# that with a typed handle, the same move #444 made one level down for CTE columns. What the string
# spelling cost, all of it measured before the change:
#
#   * it resolved FAIL-OPEN — `_get_filter_query(::String)` tried the alias branch and, when the
#     prefix matched no declared alias, fell through to ordinary field resolution, so `F("typo.col")`
#     reported an unknown FIELD named `"typo.col"` rather than an unknown alias;
#   * it existed on the FILTER resolver only, so the BARE string could not be projected —
#     `values("d.surname")` raised, though `values("x" => F("d.surname"))` worked, since `F` routes
#     through that resolver;
#   * it could not carry an operator suffix, so `"d.points__@gte" => 3` was unsupported (#174);
#   * and a reference to ANOTHER cjoin_on's alias had no way to resolve (#174).
#
# All four fall out of the handle rather than needing four fixes. What is pinned here is the new
# surface AND the shape of every refusal, because a typed handle that fails open would be strictly
# worse than the string it replaced.
#
# Everything renders through mock connections — no live database.
#
# Sibling coverage:
#   - `test_cjoin_on.jl`                 → the #45 surface itself, now spelled with handles.
#   - `test_order_by_joins.jl`           → #435/#448/#449, the emission-order rules a reference to
#                                          another alias obeys.
#   - `test_cte_reference.jl`            → `CTE(name, path)`, the same move one level down.
#   - `test_relation_alias_namespace.jl` → #474: which names may coexist, and the memo namespaces.
#
# julia --project=. test/unit/test_joined_reference.jl

using Test
using PormG
using PormG.Models
using PormG.Functions: Lower, Max, Count, Value, When, Case

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct JnMockSQLite <: PormG.PormGSQLite end
struct JnMockPostgres <: PormG.PormGPostgres end
const _JN_SL = JnMockSQLite()
const _JN_PG = JnMockPostgres()
PormG.backend_sqlite_version(::JnMockSQLite) = 3045000

PormG.config["jn_mock"] = PormG.Configuration.Settings(
  connections = _JN_SL, change_data = true, db_def_folder = "jn_mock",
)

module JnModels
import PormG
import PormG.Models

Jn_driver = Models.Model("jn_driver",
  id      = Models.IDField(),
  # `db_column` on purpose: every assertion below reads `family_name`, so a reference that silently
  # resolved against the base model (or against the wrong alias) would spell `surname` and fail.
  surname = Models.CharField(db_column = "family_name"),
  points  = Models.IntegerField(null = true),
  seen    = Models.DateField(null = true),
)

Jn_result = Models.Model("jn_result",
  id     = Models.IDField(),
  driver = Models.ForeignKey(Jn_driver, on_delete = "CASCADE", related_name = "jn_results", null = true),
  points = Models.IntegerField(null = true),
  note   = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "jn_mock")
end

const JN = JnModels
import PormG.QueryBuilder: F, inspect_query
using PormG: CTE, Joined

_jn_sql(q; conn = _JN_SL) = inspect_query(q; connection = conn)[:sql_text]
_jn_params(q; conn = _JN_SL) = inspect_query(q; connection = conn)[:parameters]
_jn_no_ansi(s::AbstractString) = replace(s, r"\e\[[0-9;]*m" => "")

# A query with one declared joined copy under `alias`, ready for the clause under test.
function _jn_query(; alias::String = "d")
  q = JN.Jn_result.objects
  q.cjoin_on("Jn_driver", alias = alias, on = [Joined(alias, "id") == F("driver")])
  q
end

function _jn_catch(f)
  try
    f()
    nothing
  catch e
    e
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The constructor: what a handle accepts, and what it refuses before any SQL exists
# `desc` is meaningful in exactly two places (the fluent `order_by` and a window's `order_by`), so
# every other consumer refuses it at the call rather than silently dropping an ordering the caller
# asked for.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Joined(...) construction and display (#481)" begin
  ref = Joined("d", "surname")
  @test ref.alias == "d"
  @test ref.path == "surname"
  @test ref.desc == false
  @test Joined("d", "surname"; desc = true).desc

  # Shown as the caller wrote it — a bare `JoinedReference` in an error message would be the
  # useless bare-type-name every diagnostic in this repo exists to avoid.
  @test sprint(show, ref) == "Joined(\"d\", \"surname\")"

  # Both halves are required, refused at the call rather than at build time.
  @test _jn_catch(() -> Joined("", "surname")) isa PormG.QueryBuildError
  @test _jn_catch(() -> Joined("d", "")) isa PormG.QueryBuildError

  # A handle is immutable, so a deepcopy is a fresh equal value and nothing can rewrite it in place.
  copied = deepcopy(ref)
  @test copied.alias == ref.alias && copied.path == ref.path && copied.desc == ref.desc

  # `==` on this type builds a PREDICATE, not a Bool — that is the point of the comparison methods
  # below. Without an `isequal` method the generic fallback calls `==` and expects a Bool, so every
  # hash-based collection would throw a TypeError on a collision. `isequal` is `===`, which on an
  # immutable struct is field-wise, so two separately constructed equal handles are one value.
  @test (ref == Joined("d", "surname")) isa PormG.QueryBuilder.FExpression
  @test isequal(ref, Joined("d", "surname"))
  @test !isequal(ref, Joined("d", "points"))
  @test length(unique([ref, Joined("d", "surname")])) == 1
  @test haskey(Dict(ref => 1), Joined("d", "surname"))
  @test length(Set([ref, Joined("d", "surname")])) == 1
  # ...and against a different type, so a heterogeneous container cannot throw on a collision.
  @test !isequal(ref, "d__surname")
  @test !isequal(ref, CTE("d", "surname"))
  # `missing` needs its own method — Base owns `isequal(::Any, ::Missing)`, so the `::Any` arm
  # alone is an ambiguity (Aqua fails the build on it), not merely a style question.
  @test !isequal(ref, missing)
  # `in`/`findfirst` over a plain Vector use `==`, so they build a predicate rather than answering
  # a Bool. That is inherent to a comparison-overloading handle — `FExpression` behaves the same —
  # and it is pinned here so the behavior is a decision on record rather than a surprise.
  @test_throws TypeError (ref in [Joined("d", "surname")])
end

for (backend, conn) in (("PostgreSQL", _JN_PG), ("SQLite", _JN_SL))
  @testset "$backend" begin

    # ─────────────────────────────────────────────────────────────────────────
    # The ON clause: the reference convention `cjoin_on` was built for
    # A bare `F("col")` is the BASE table; a `Joined(alias, col)` is the joined copy. This is the
    # spelling that replaces `F("d.col")`, and it is unambiguous in a self-join where both sides
    # carry every column name.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "the ON clause names both sides (#481)" begin
      q = JN.Jn_result.objects
      q.cjoin_on("Jn_driver", alias = "d", on = [Joined("d", "id") == F("driver")])
      q.values("points")
      sql = _jn_sql(q; conn = conn)
      @test occursin("INNER JOIN \"jn_driver\" AS \"d\" ON (\"d\".\"id\" = \"Tb\".\"driver\")", sql)

      # A self-join: the base model joined to itself, which is the shape the whole convention exists
      # for — `Joined("b2", "note")` and a bare `F("note")` are the same column on two relations.
      s = JN.Jn_result.objects
      s.cjoin_on("Jn_result", alias = "b2", on = [Joined("b2", "note") == F("note")])
      s.values("id")
      ssql = _jn_sql(s; conn = conn)
      @test occursin("INNER JOIN \"jn_result\" AS \"b2\" ON (\"b2\".\"note\" = \"Tb\".\"note\")", ssql)
    end

    @testset "a comparison against a literal renders on the joined side (#481)" begin
      q = JN.Jn_result.objects
      q.cjoin_on("Jn_driver", alias = "d",
                 on = [Joined("d", "id") == F("driver"), Joined("d", "points") == 7])
      q.filter("note" => "z")
      q.values("id")
      sql = _jn_sql(q; conn = conn)
      @test occursin("\"d\".\"points\" = ", sql)
      @test 7 in _jn_params(q; conn = conn)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Projection: new capability, not a re-spelling
    # `values("d.surname")` never worked — the dotted branch lived on the FILTER resolver only, so
    # the string reached `_solve_field` and raised. A projected handle also has to carry the
    # `db_column` of the JOINED model, not of the base model.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "a joined column can be projected (#481)" begin
      q = _jn_query()
      q.values("points", "who" => Joined("d", "surname"))
      sql = _jn_sql(q; conn = conn)
      @test occursin("\"d\".\"family_name\" as \"who\"", sql)

      # Unaliased, the output column is `alias__path` — the same shape `CTE(...)` produces.
      bare = _jn_query()
      bare.values("points", Joined("d", "surname"))
      @test occursin("\"d\".\"family_name\" as \"d__surname\"", _jn_sql(bare; conn = conn))

      # Through a SQL function, which reaches the handle at the leaf.
      fn = _jn_query()
      fn.values("points", "lo" => Lower(Joined("d", "surname")))
      @test occursin("LOWER(\"d\".\"family_name\") as \"lo\"", _jn_sql(fn; conn = conn))
    end

    @testset "two projections may not share an output name (#441 still applies)" begin
      # The #441 duplicate-projection guard keys on the OUTPUT name, and a bare handle's is
      # `alias__path` — so it composes with the guard rather than sidestepping it.
      q = _jn_query()
      err = _jn_catch() do
        q.values("d__surname" => "note", Joined("d", "surname"))
      end
      @test err isa PormG.QueryBuildError
      # Names the colliding output name, not merely "something is wrong".
      @test occursin("d__surname", _jn_no_ansi(sprint(showerror, err)))
    end

    # ─────────────────────────────────────────────────────────────────────────
    # filter(): the alias-qualified operator pair #174 listed as unsupported
    # `"d.points__@gte" => 3` could not work: the Pair path resolves its column through
    # `_get_select_query(::String)`, which has no dot branch. Delegating on `ref.path` runs the whole
    # `__@` peel and the RHS-typed `_get_pair_to_oper` ladder, so every operator works by
    # construction rather than one at a time.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "alias-qualified operator pairs (#174 edge 1, closed by #481)" begin
      q = _jn_query()
      q.values("points")
      q.filter(Joined("d", "points__@gte") => 3)
      sql = _jn_sql(q; conn = conn)
      @test occursin("WHERE \"d\".\"points\" >= ", sql)
      @test _jn_params(q; conn = conn) == Any[3]

      # A plain equality pair, and a membership list, take the same route.
      eq = _jn_query()
      eq.values("points")
      eq.filter(Joined("d", "surname") => "Senna")
      @test occursin("WHERE \"d\".\"family_name\" = ", _jn_sql(eq; conn = conn))

      # Membership goes through the same ladder. The RENDER is a documented dialect split — one
      # array parameter on PostgreSQL (`= ANY($1)`), N placeholders on SQLite — so what is pinned
      # per backend is that the joined column is the one being tested.
      inl = _jn_query()
      inl.values("points")
      inl.filter(Joined("d", "points__@in") => [1, 2])
      insql = _jn_sql(inl; conn = conn)
      @test occursin("\"d\".\"points\"", insql)
      @test occursin(conn === _JN_PG ? "= ANY(" : "IN (", insql)
    end

    @testset "a handle on the RHS is a column comparison, never a bound value (#481)" begin
      q = _jn_query()
      q.values("id")
      q.filter("points" => Joined("d", "points"))
      sql = _jn_sql(q; conn = conn)
      @test occursin("\"Tb\".\"points\" = \"d\".\"points\"", sql)
      @test isempty(_jn_params(q; conn = conn))
    end

    # ─────────────────────────────────────────────────────────────────────────
    # order_by(): the second site where `desc` is meaningful
    # A reference object cannot carry the string form's leading `-`, so the direction is a keyword
    # on the constructor — exactly as `CTE(...; desc = true)` does.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "order_by over a joined column, both directions (#481)" begin
      asc = _jn_query()
      asc.values("points")
      asc.order_by(Joined("d", "surname"))
      @test occursin("ORDER BY \"d\".\"family_name\" ASC", _jn_sql(asc; conn = conn))

      desc = _jn_query()
      desc.values("points")
      desc.order_by(Joined("d", "surname"; desc = true))
      @test occursin("ORDER BY \"d\".\"family_name\" DESC", _jn_sql(desc; conn = conn))
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Third-table references (#174 edge 2, closed by #481)
    # `_resolve_cjoin_on_alias_column` matched only the SINGLE owning entry, so one cjoin_on's ON
    # could not name another's alias. A handle resolves from `alias_join` by alias, so it can — and
    # the #449 declaration-order rule then decides which join carries the predicate.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "one cjoin_on may reference another's alias (#174 edge 2)" begin
      q = JN.Jn_result.objects
      q.cjoin_on("Jn_driver", alias = "d1", on = [Joined("d1", "id") == F("driver")])
      q.cjoin_on("Jn_driver", alias = "d2", on = [Joined("d2", "surname") == Joined("d1", "surname")])
      q.values("points")
      sql = _jn_sql(q; conn = conn)
      # Both joins are emitted, in declaration order (#449), each with its own ON clause.
      @test occursin("INNER JOIN \"jn_driver\" AS \"d1\" ON (\"d1\".\"id\" = \"Tb\".\"driver\")", sql)
      @test occursin("INNER JOIN \"jn_driver\" AS \"d2\" ON (\"d2\".\"family_name\" = \"d1\".\"family_name\")", sql)
      @test findfirst("AS \"d1\"", sql).start < findfirst("AS \"d2\"", sql).start
    end

    @testset "a forward reference still relocates, and #435 still fires (#481)" begin
      # Declaring the pair the other way round makes d1's only predicate name a join emitted AFTER
      # it. Phase 1b moves that predicate onto d2, which leaves d1 with no ON clause of its own —
      # the #435 refusal, unchanged by the handle. Pinned because the guards work by substring-
      # matching the rendered `"alias".` text, which the handle deliberately keeps byte-identical.
      q = JN.Jn_result.objects
      q.cjoin_on("Jn_driver", alias = "d1", on = [Joined("d1", "surname") == Joined("d2", "surname")])
      q.cjoin_on("Jn_driver", alias = "d2", on = [Joined("d2", "id") == F("driver")])
      q.values("points")
      err = _jn_catch(() -> _jn_sql(q; conn = conn))
      @test err isa PormG.QueryBuildError
      @test occursin("d1", _jn_no_ansi(sprint(showerror, err)))
    end

    @testset "an ON clause that never names its own alias is still refused (#448)" begin
      q = JN.Jn_result.objects
      q.cjoin_on("Jn_driver", alias = "d", on = [F("note") == F("note")])
      q.values("points")
      err = _jn_catch(() -> _jn_sql(q; conn = conn))
      @test err isa PormG.QueryBuildError
      # Pin the CAUSE, not a single letter: `occursin("d", msg)` is unfalsifiable, since the
      # message contains a bare `d` whatever the alias is.
      @test occursin("never references", _jn_no_ansi(sprint(showerror, err)))
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Transforms over a joined column, including the COMPOSITE ones
    # `@year` builds one function over the column; `@quarter` and `@quadrimester` expand to a
    # `Concat([Cast(Year(x)), Value("-Q"), Case([When(...)])])`, so the retag walk meets a literal,
    # a field wrapper and an operator object on the way down. A walk that handled only functions
    # raised "Internal … please report" for a documented transform — a regression against the
    # dotted spelling, which rendered all three.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "transforms over a joined column, simple and composite (#481)" begin
      simple = _jn_query()
      simple.values("points", "y" => Joined("d", "seen__@year"))
      ysql = _jn_sql(simple; conn = conn)
      @test occursin(conn === _JN_PG ? "EXTRACT(YEAR FROM \"d\".\"seen\")" : "strftime('%Y', \"d\".\"seen\")", ysql)

      # A SELF-join, so `seen` exists on BOTH sides and "reads the joined copy, not the base table"
      # is actually falsifiable — on the base model `Jn_result` there is no `seen` at all, so the
      # negative half would hold no matter what the retag did.
      for key in ("quarter", "quadrimester")
        composite = JN.Jn_driver.objects
        composite.cjoin_on("Jn_driver", alias = "d2", on = [Joined("d2", "id") == F("id")])
        composite.values("surname", "b" => Joined("d2", "seen__@$(key)"))
        csql = _jn_sql(composite; conn = conn)
        @test occursin("\"d2\".\"seen\"", csql)
        # Every reference the transform emits is on the joined copy; the base alias contributes
        # only its own projection.
        @test !occursin("\"Tb\".\"seen\"", csql)
        @test occursin("as \"b\"", csql)
      end

      # In an ON clause, which is where the dotted form was pinned before.
      on_side = JN.Jn_result.objects
      on_side.cjoin_on("Jn_driver", alias = "d", on = [Joined("d", "seen__@year") == F("id")])
      on_side.values("points")
      @test occursin("\"d\".\"seen\"", _jn_sql(on_side; conn = conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Parameter alignment: measured, not asserted
# A build binds joins LAST and renders them FIRST, which is what the parameter buckets reconcile —
# so "is this order right?" cannot be answered by eye. The oracle is the cross-backend differential
# (`pormg-querybuilder-internals` → *Parameter routing*): PostgreSQL numbers placeholders as it
# binds, so walking its `$N` markers left to right through its own parameter vector recovers the
# true TEXT order, and SQLite's flattened vector must equal that.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a joined-side literal aligns across both backends (#481)" begin
  build() = begin
    q = JN.Jn_result.objects
    q.cjoin_on("Jn_driver", alias = "d",
               on = [Joined("d", "id") == F("driver"), Joined("d", "points") == 7])
    q.filter("note" => "z")
    q.values("id")
    q
  end
  pg = inspect_query(build(); connection = _JN_PG)
  sl = inspect_query(build(); connection = _JN_SL)
  idx = [parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", pg[:sql_text])]
  text_order = [pg[:parameters][i] for i in idx]
  @test sl[:parameters] == text_order
  # Both values reach the statement exactly once.
  @test sort(string.(sl[:parameters])) == sort(string.(Any[7, "z"]))
end

# ─────────────────────────────────────────────────────────────────────────────
# Refusals: every way a handle can be wrong, and the message it gets
# A typed handle that failed open would be strictly worse than the dotted string it replaces, so
# each of these pins that the failure is loud AND that it names what the caller can act on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Joined(...) refusals are loud and name the cause (#481)" begin

  @testset "an alias no cjoin_on declared" begin
    q = _jn_query()
    q.values("x" => Joined("typo", "surname"))
    err = _jn_catch(() -> _jn_sql(q))
    @test err isa PormG.QueryBuildError
    msg = _jn_no_ansi(sprint(showerror, err))
    @test occursin("Joined(\"typo\"", msg)
    # It lists what IS declared — the fail-open string reported an unknown FIELD named "typo.col",
    # which sent the reader looking for a column that was never the problem.
    @test occursin("Declared aliases: d", msg)
  end

  @testset "an alias on a query with no cjoin_on at all" begin
    q = JN.Jn_result.objects
    q.values("x" => Joined("d", "surname"))
    err = _jn_catch(() -> _jn_sql(q))
    @test err isa PormG.QueryBuildError
    @test occursin("no cjoin_on at all", _jn_no_ansi(sprint(showerror, err)))
  end

  @testset "a column the joined model does not have" begin
    q = _jn_query()
    q.values("x" => Joined("d", "nope"))
    err = _jn_catch(() -> _jn_sql(q))
    @test err isa PormG.UnknownFieldError
    msg = _jn_no_ansi(sprint(showerror, err))
    # Named against the JOINED model, listing its fields — not against the base model.
    @test occursin("jn_driver", msg)
    @test occursin("nope", msg)
  end

  @testset "a relation hop through a joined copy" begin
    # A joined copy is ONE table; the next hop needs its own cjoin_on.
    q = _jn_query()
    q.values("x" => Joined("d", "driver__surname"))
    err = _jn_catch(() -> _jn_sql(q))
    @test err isa PormG.QueryBuildError
    @test occursin("cannot traverse a relation", _jn_no_ansi(sprint(showerror, err)))
  end

  @testset "desc = true outside an ordering" begin
    for (context, build) in (
        ("values", () -> begin q = _jn_query(); q.values("x" => Joined("d", "surname"; desc = true)); _jn_sql(q) end),
        ("filter", () -> begin q = _jn_query(); q.values("id"); q.filter(Joined("d", "surname"; desc = true) => "x"); _jn_sql(q) end),
        ("comparison", () -> Joined("d", "surname"; desc = true) == F("note")),
      )
      err = _jn_catch(build)
      @test err isa PormG.QueryBuildError
      # "only" alone matches most messages in this file; pin the sentence.
      @test occursin("only meaningful in", _jn_no_ansi(sprint(showerror, err)))
    end
  end

  @testset "a handle in on() or cjoin(), which target a relation's own join" begin
    err = _jn_catch() do
      q = JN.Jn_result.objects
      q.on("driver", Joined("d", "surname") == F("note"))
      _jn_sql(q)
    end
    @test err isa PormG.FilterError
    @test occursin("cannot be used in a join ON clause", _jn_no_ansi(sprint(showerror, err)))
  end

  @testset "Value(...) wraps a literal, not a column" begin
    err = _jn_catch(() -> Value(Joined("d", "surname")))
    @test err isa PormG.QueryBuildError
    @test occursin("wraps a literal", _jn_no_ansi(sprint(showerror, err)))
  end

  @testset "an UPDATE cannot SET a column from a joined copy" begin
    # The common update path scopes rows with a subquery, so the joined copy is not visible to SET.
    # That is #174's fourth deferred edge; what is pinned here is that it fails with an accurate
    # typed error rather than a MethodError out of the field formatter.
    q = _jn_query()
    q.filter("id" => 1)
    err = _jn_catch(() -> q.update("note" => Joined("d", "surname"), show_query = :sql))
    @test err isa PormG.QueryBuildError
    @test occursin("not supported", _jn_no_ansi(sprint(showerror, err)))
  end

  @testset "a CTE handle is still refused inside a cjoin_on ON clause (#444)" begin
    # The two handles are opposites at exactly one place: a joined reference belongs in an ON
    # clause and a CTE reference never does. Pinned together so neither refusal drifts.
    err = _jn_catch() do
      ev = JN.Jn_driver.objects
      ev.values("id", "surname")
      q = JN.Jn_result.objects
      q.with("ev" => ev)
      q.cjoin_on("Jn_driver", alias = "d", on = [Joined("d", "surname") == CTE("ev", "surname")])
      q.values("points")
      _jn_sql(q)
    end
    @test err isa PormG.FilterError
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The dotted string is gone, and says so
# Every spelling that used to reach the removed branch now resolves as an ordinary field name and
# raises `UnknownFieldError` naming the dotted text — which is what the hint in `_unknown_field`
# keys on, and what the UPGRADING entry tells readers to grep for.
# ─────────────────────────────────────────────────────────────────────────────
@testset "F(\"alias.col\") no longer resolves (#481)" begin
  shapes = (
    ("in a cjoin_on ON clause", () -> begin
       q = JN.Jn_result.objects
       q.cjoin_on("Jn_driver", alias = "d", on = [F("d.surname") == F("note")])
       q.values("points"); _jn_sql(q) end),
    ("in a filter", () -> begin
       q = _jn_query(); q.values("id"); q.filter(F("d.surname") == F("note")); _jn_sql(q) end),
    ("in values", () -> begin
       q = _jn_query(); q.values("points", "x" => "d.surname"); _jn_sql(q) end),
  )
  for (label, build) in shapes
    @testset "$label" begin
      err = _jn_catch(build)
      @test err isa PormG.UnknownFieldError
      @test occursin("d.surname", _jn_no_ansi(sprint(showerror, err)))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The memo namespace: a joined column and a like-named field path stay separate (#474/#481)
# A `cjoin_on` alias may equal a CTE name, so a projected `Joined("ev","surname")` and a
# `CTE("ev","surname")` both spell `ev__surname` as their OUTPUT name. Before the `MemoKey` tag was
# widened to a Symbol, whichever rendered first claimed the memo entry for both — the #474 defect,
# one namespace over.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a joined column and a CTE column may share a name (#481)" begin
  ev = JN.Jn_driver.objects
  ev.values("id", "surname")

  q = JN.Jn_result.objects
  q.with("ev" => ev, join_field = "driver" => "id", join_type = "INNER")
  q.cjoin_on("Jn_driver", alias = "ev", on = [Joined("ev", "id") == F("driver")])
  q.values("points", "from_cte" => CTE("ev", "surname"), "from_join" => Joined("ev", "surname"))
  sql = _jn_sql(q)

  # The CTE is joined under a GENERATED alias and projects its own column name; the joined copy is
  # the range variable `ev` itself and projects the model's physical column. Two relations, two
  # namespaces, both addressable in one query.
  @test occursin("\"R1_1\".\"surname\" as \"from_cte\"", sql)
  @test occursin("\"ev\".\"family_name\" as \"from_join\"", sql)
  @test occursin("INNER JOIN \"ev\" AS \"R1_1\"", sql)
  @test occursin("INNER JOIN \"jn_driver\" AS \"ev\" ON (\"ev\".\"id\" = \"R1\".\"driver\")", sql)
end
