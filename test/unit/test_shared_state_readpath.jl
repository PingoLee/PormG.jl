"""
Unit coverage for the shared-mutable-state read/copy contract (#43).

A query object is a value the caller can hold, re-execute, and `.copy()`. Two defects
broke that:

1. The read path (`query()` → `query_list`) wrote `q.object.parameters` back onto the
   caller and materialized the per-build CTE `"model"` into the caller's `ctes` dict — so
   a plain `.list()` had a hidden write side effect (`do_count`/`do_exists`/`get` already
   `deepcopy` first; `.list()` did not).
2. `deepcopy(::SQLObjectQuery)` shallow-copied `ctes` (`copy(obj.ctes)`), so `.copy()` and
   its inner `CTEDict` values were shared by reference — materializing the CTE model on one
   copy clobbered the other.

The fix builds the read path on a copy (`query_list`, `inspect_query`) and makes `deepcopy`
clone CTE state independently (`_copy_ctes`), dropping the transient `"model"`. These
deterministic checks pin both directions without a live database, using `show_query`
(`:sql`/`:dict`) and inspection modes that short-circuit before any fetch.
"""

using Test
using PormG
using PormG.Models

import PormG: PormGModel
import PormG.QueryBuilder: Count

struct SharedStateMockPostgres <: PormG.PormGPostgres end

PormG.config["ss_mock"] = PormG.Configuration.Settings(
  connections = SharedStateMockPostgres(),
  change_data = true,
  db_def_folder = "ss_mock",
)

module SharedStateReadPathModels
import PormG
import PormG.Models

Result = Models.Model("ss_results",
  id = Models.IDField(),
  driverid = Models.IntegerField(),
  points = Models.IntegerField(null=true),
)

PormG.Models.set_models(@__MODULE__, "ss_mock")
end

const SS = SharedStateReadPathModels

# Build a fresh CTE query each time so one testset can't leak state into the next.
function _cte_query()
  agg = SS.Result.objects
  agg.values("driverid", "total" => Count("id"))

  q = SS.Result.objects
  q.with("agg" => agg, join_field = "driverid" => "driverid")
  q.filter("id__@lte" => 100)
  q.values("id", "driverid", "agg__total")
  q.order_by("id")
  return q
end

@testset "Shared-state read/copy path (#43)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # AC1: executing the read path must NOT mutate the caller. Pre-fix, query() wrote
  # q.object.parameters and materialized q.object.ctes["agg"]["model"] onto the caller.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "read path does not mutate the caller" begin
    q = _cte_query()

    # Guard: a freshly-built query has not collected parameters yet.
    @test q.object.parameters === nothing
    @test !haskey(q.object.ctes["agg"], "model")

    sql1 = q.list(show_query = :sql)
    @test sql1 isa String
    @test occursin("WITH", sql1)

    # The write-backs must have landed on the internal build copy, not on `q`.
    @test q.object.parameters === nothing          # pre-fix: became a param collector
    @test !haskey(q.object.ctes["agg"], "model")   # pre-fix: "model" leaked onto caller
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # AC4: re-executing the same query renders identical SQL (no accumulation / drift).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "re-execution is idempotent" begin
    q = _cte_query()
    sql1 = q.list(show_query = :sql)
    sql2 = q.list(show_query = :sql)
    @test sql1 == sql2
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # AC2: `.copy()` must produce an independent query — its inner CTEDict values are
  # fresh objects, not aliases. Pre-fix (`copy(obj.ctes)`), they were the SAME object.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "copy produces independent CTE state" begin
    q = _cte_query()
    q2 = q.copy()

    # Distinct outer dict AND distinct inner CTEDict (the #43 aliasing signal).
    @test q2.object.ctes !== q.object.ctes
    @test q2.object.ctes["agg"] !== q.object.ctes["agg"]
    # The transient per-build "model" is not carried into the copy.
    @test !haskey(q2.object.ctes["agg"], "model")

    # AC3 (deterministic form): a divergent filter on the copy renders its own SQL,
    # and rendering the copy leaves the original untouched.
    sql_before = q.list(show_query = :sql)
    q2.filter("id__@lte" => 10)
    sql_copy = q2.list(show_query = :sql)
    sql_after = q.list(show_query = :sql)

    @test sql_copy != sql_before        # copy diverged
    @test sql_after == sql_before       # original unchanged by building the copy
    @test q.object.parameters === nothing
    @test !haskey(q.object.ctes["agg"], "model")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The inspection API must also leave the caller untouched. inspect_query() /
  # show_query() call query() directly (not via query_list), so they need their own
  # copy — otherwise `q.inspect()` writes back parameters + the CTE "model" onto `q`
  # while `q.list(show_query=:dict)` (through query_list) does not.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "inspection API does not mutate the caller" begin
    q = _cte_query()
    @test q.object.parameters === nothing
    @test !haskey(q.object.ctes["agg"], "model")

    insp = q.inspect()          # .inspect terminal → inspect_query(q)
    @test insp isa Dict
    @test occursin("WITH", insp[:sql_text])
    @test q.object.parameters === nothing          # pre-fix: leaked a param collector
    @test !haskey(q.object.ctes["agg"], "model")   # pre-fix: leaked the transient "model"

    # The show_query() free helper builds on a copy too.
    sql = PormG.QueryBuilder.show_query(q, :sql)
    @test sql isa String && occursin("WITH", sql)
    @test q.object.parameters === nothing
    @test !haskey(q.object.ctes["agg"], "model")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # count()/exists() build the CTE via build_cte_clause on their OWN deepcopy
  # (do_count/do_exists), a DIFFERENT path than query_list. Pre-#43 that deepcopy was
  # shallow for ctes, so _build_cte_custom_model still wrote the transient "model" into
  # the caller's shared inner CTEDict. :dict mode short-circuits before fetch, so this
  # is deterministic without a live database.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "count()/exists() do not mutate the caller (CTE)" begin
    q = _cte_query()
    @test !haskey(q.object.ctes["agg"], "model")

    q.count(show_query = :dict)                     # builds the CTE, returns metadata (no fetch)
    @test !haskey(q.object.ctes["agg"], "model")   # pre-fix: "model" leaked onto the caller
    @test q.object.parameters === nothing

    q.exists(show_query = :dict)
    @test !haskey(q.object.ctes["agg"], "model")
    @test q.object.parameters === nothing
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # AC1 names .first() explicitly. Post-#199 it is copy-first like every read terminal:
  # limit(1) is applied to an internal copy only, so the caller's limit / parameters /
  # CTE "model" are all left untouched. .first() funnels through query_list, so the
  # read-path copy covers it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "first() does not mutate the caller (copy-first, #199)" begin
    q = _cte_query()
    @test q.object.parameters === nothing
    @test !haskey(q.object.ctes["agg"], "model")

    limit_before = q.object.limit
    sql = q.first(show_query = :sql)
    @test sql isa String && occursin("WITH", sql)
    @test occursin("LIMIT 1", sql)                 # first() applied limit(1) to its internal copy
    @test q.object.limit == limit_before            # #199: copy-first — caller's limit is untouched
    @test q.object.parameters === nothing           # parameters did NOT leak
    @test !haskey(q.object.ctes["agg"], "model")    # and the CTE "model" did NOT leak
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Positive control: the non-CTE read path is likewise non-mutating and stable, so
  # the guarantees above are not specific to CTE queries.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "plain (non-CTE) read path is non-mutating" begin
    q = SS.Result.objects
    q.filter("driverid" => 44)
    q.values("id", "driverid")

    sql1 = q.list(show_query = :sql)
    sql2 = q.list(show_query = :sql)
    @test sql1 == sql2
    @test q.object.parameters === nothing   # pre-fix: write-back set this to a collector
  end

end
