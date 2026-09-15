"""
`OP(<function>, …)` — the aggregate/window arms of an internal constructor (#537).

`OP` has four methods (`types.jl`); the two `SQLTypeFunction` arms build an `OperObject` whose
`column` is an `FObject` or a `WindowFunction`. Rendering served exactly the functions whose
formatter it could name — `EXTRACT`, `TO_CHAR`, `COUNT`, the `PormGTypeField` set — and PormG's own
`Y_Q` / `Y_QUAD` label transforms depend on that (`When(OP(MONTH(x), "<=", N))`, `functions.jl`),
which is why the arms cannot be deleted. (#579 moved that expansion off `@quarter`/`@quadrimester`,
which now extract the period number through one dialect function, onto the label keys.) Every OTHER function fell to the `else` ladder of
`_get_filter_query(::SQLTypeOper)` and died reading `.field` off a node that has no such slot: a raw
`FieldError` outside the #231 taxonomy. And an AGGREGATE column that happened to be served
(`OP(Count("id"), ">", 3)`) rendered `WHERE COUNT(...)`, which is invalid SQL, and failed at the
database instead of at build time.

The decision (#537, option A): `OP` is intentionally internal — unexported, undocumented, the
string-lookup form is the public spelling — so the fix REFUSES with a typed error naming the
spellings that work, rather than growing a consumer for a surface users are steered away from.
Django's documented answer is the same shape: annotate the aggregate, then filter on the alias.

Three things are pinned:

  1. **An aggregate or window predicate in WHERE is refused** wherever it sits — bare, inside `Q`,
     inside `Qor` — naming the alias spelling (`values("total" => Sum("qty")); filter("total__@gt"
     => 1)`, which renders as HAVING) or, for a window, the CTE spelling.
  2. **A scalar function with no formatter route is refused** naming the alias and transform-suffix
     spellings, instead of the raw `FieldError`.
  3. **The served spellings still render** — `OP(Extract(...))`, the `QUADRIMESTER` composite, the
     suffix form — so the refusal is exactly as wide as the gap.

`OperObject.column`'s declared `ColumnPart` is narrowed to what is actually constructed
(`SQLTypeField` or `SQLTypeFunction`); the dead admissions are asserted gone, and
`test_node_admission.jl` probes the real width from the struct's own slot.

Everything renders through mock connections — no live database.

julia --project=. test/unit/test_op_function_column.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, OP
using PormG.Functions: Sum, Count, Lower, Abs, Extract, Rank, WindowOver, Case, When
import PormG.QueryBuilder as QB

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct OpfMockSQLite <: PormG.PormGSQLite end
struct OpfMockPostgres <: PormG.PormGPostgres end
const _OPF_SL = OpfMockSQLite()
const _OPF_PG = OpfMockPostgres()
PormG.backend_sqlite_version(::OpfMockSQLite) = 3045000

PormG.config["opf_mock"] = PormG.Configuration.Settings(
  connections = _OPF_SL, change_data = true, db_def_folder = "opf_mock",
)

# One integer column to aggregate, one date column for the served `EXTRACT` route and the composite
# transforms, one text column for the unserved scalar case.
module OpfModels
import PormG
import PormG.Models

Opf_row = Models.Model("opf_row",
  id   = Models.IDField(),
  qty  = Models.IntegerField(null = true),
  seen = Models.DateField(null = true),
  note = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "opf_mock")
end

const OPF = OpfModels

_opf_sql(q; conn = _OPF_SL)    = inspect_query(q; connection = conn)[:sql_text]
_opf_params(q; conn = _OPF_SL) = inspect_query(q; connection = conn)[:parameters]

# Build AND render, returning the exception or `nothing` — a refusal must happen by render time at
# the latest, and construction alone proves nothing (#533's whole lesson).
_opf_err(build; conn) = try
  _opf_sql(build(); conn = conn)
  nothing
catch e
  e
end

const _OPF_BACKENDS = (("PostgreSQL", _OPF_PG), ("SQLite", _OPF_SL))

_msg(err) = err === nothing ? "" : PormG.error_message(err)

# ─────────────────────────────────────────────────────────────────────────────
# An aggregate predicate in WHERE, in every position a filter entry can occupy. Before the fix
# `Sum` raised a raw `FieldError` and `Count` — served by the formatter map — rendered
# `WHERE COUNT(...)` silently, to fail at the database. Both now refuse at build time and name the
# HAVING spelling. `Q`/`Qor` are walked recursively: `functions.jl` admits an `OperObject` into
# either directly, so a flat check on the top-level entry would let `Q(OP(Count(...)))` through.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#537: an aggregate OP predicate in WHERE is refused with the alias spelling" begin
  for (backend, conn) in _OPF_BACKENDS
    for build in (
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(OP(Sum("qty"), 1)); q),
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(OP(Sum("qty"), ">", 1)); q),
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(OP(Count("id"), ">", 3)); q),
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(Q(OP(Sum("qty"), ">", 1))); q),
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(Qor(OP(Count("id"), ">", 3), "qty" => 1)); q),
        # Two levels down — the walk recurses, it does not stop at the first container.
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(Q("qty" => 1, Qor(OP(Sum("qty"), ">", 1), "qty" => 2))); q),
      )
      err = _opf_err(build; conn = conn)
      @test err isa PormG.QueryBuildError
      @test occursin("values(", _msg(err))
      @test occursin("__@gt", _msg(err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A window function in WHERE. `_is_agg(::WindowFunction)` is `false` by design — a window is not an
# aggregate — so gating on `.aggregate` alone would let `OP(Rank(...), 1)` through to the raw
# `FieldError`. It is refused on its own type, naming the CTE spelling: SQL evaluates windows after
# WHERE, so the only way to filter on one is to materialize it first.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#537: a window OP predicate in WHERE is refused with the CTE spelling" begin
  for (backend, conn) in _OPF_BACKENDS
    for build in (
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(OP(Rank(over = WindowOver(order_by = "id")), 1)); q),
        () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(Q(OP(Rank(over = WindowOver(order_by = "id")), "<=", 3))); q),
      )
      err = _opf_err(build; conn = conn)
      @test err isa PormG.QueryBuildError
      @test occursin(".with(", _msg(err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A scalar function with no formatter route. Neither `LOWER` nor `ABS` is in `PormGTypeField`, and a
# bare function column's own `.formatter` was never consulted on this path, so both fell to the
# `else` ladder and the `.field` read. Now: a typed refusal that names BOTH working spellings —
# the projection alias and the `col__@<transform>__@<op>` suffix — and the function it refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#537: a scalar-function OP predicate with no formatter route is refused" begin
  for (backend, conn) in _OPF_BACKENDS
    for (fn_name, build) in (
        ("LOWER", () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(OP(Lower("note"), "x")); q)),
        ("ABS",   () -> (q = OPF.Opf_row.objects; q.values("note"); q.filter(OP(Abs("qty"), ">", 5)); q)),
        # The same refusal reaches a SELECT-side CASE: `When(OP(Sum(...)))` renders its condition
        # through the same `_get_filter_query(::SQLTypeOper)`, and was the same raw `FieldError`.
        ("SUM",   () -> (q = OPF.Opf_row.objects;
                         q.values("flag" => Case(When(OP(Sum("qty"), ">", 0), then = 1), default = 0)); q)),
      )
      err = _opf_err(build; conn = conn)
      @test err isa PormG.QueryBuildError
      @test occursin(fn_name, _msg(err))
      @test occursin("values(", _msg(err))
      @test occursin("__@", _msg(err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: the served spellings render exactly as before. These are the reason the arms stay —
# `QUADRIMESTER` / `QUARTER` are built from `When(OP(MONTH(x), "<=", N))` — and the reason the
# refusal must be no wider than the gap.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#537 controls: the served OP spellings still render" begin
  for (backend, conn) in _OPF_BACKENDS
    # `OP` over a served function (EXTRACT) as a WHERE predicate: non-aggregate, formatter known.
    # Upper-case part, as `MONTH(x)` itself passes it — the SQLite renderer accepts nothing else.
    q1 = OPF.Opf_row.objects
    q1.values("note")
    q1.filter(OP(Extract("seen", "MONTH"), "<=", 4))
    sql1 = _opf_sql(q1; conn = conn)
    @test occursin(" <= ", sql1)
    @test 4 in _opf_params(q1; conn = conn)

    # The composite transform PormG itself builds over `OP(MONTH(x), "<=", N)` (functions.jl).
    # `@yyyy_quad`, not `@quadrimester`: #579 moved the `Concat`/`Case` expansion to the label key,
    # and the number key no longer reaches `OP` at all.
    q2 = OPF.Opf_row.objects
    q2.values("note", "seen__@yyyy_quad")
    sql2 = _opf_sql(q2; conn = conn)
    @test occursin("CASE", sql2)
    @test all(n in _opf_params(q2; conn = conn) for n in (4, 8, 12))

    # The public transform-suffix spelling the refusal points at.
    q3 = OPF.Opf_row.objects
    q3.values("note")
    q3.filter("seen__@month__@lte" => 4)
    @test occursin(" <= ", _opf_sql(q3; conn = conn))
    @test 4 in _opf_params(q3; conn = conn)

    # The `String` arms of `OP` — the half the issue says was always fine.
    q4 = OPF.Opf_row.objects
    q4.values("note")
    q4.filter(OP("qty", ">", 3))
    @test occursin("\"Tb\".\"qty\" > ", _opf_sql(q4; conn = conn))
    @test _opf_params(q4; conn = conn) == Any[3]

    # And the alias spelling the refusal recommends renders as HAVING, so the advice is executable.
    q5 = OPF.Opf_row.objects
    q5.values("note", "total" => Sum("qty"))
    q5.filter("total__@gt" => 1)
    sql5 = _opf_sql(q5; conn = conn)
    @test occursin("HAVING", sql5)
    @test occursin("SUM(", sql5)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The two widths are reconciled (#537's second acceptance item). Every site that constructs an
# `OperObject` produces an `SQLTypeField` or an `SQLTypeFunction` column; `String`, `SQLTypeF`,
# `SQLTypeCTE`, `SQLTypeJoined` and the `Vector` member were admissions nothing ever built.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#537: OperObject.column admits exactly what is constructed" begin
  @test fieldtype(QB.OperObject, :column) === Union{PormG.SQLTypeField,PormG.SQLTypeFunction}
  @test QB.ColumnPart === Union{PormG.SQLTypeField,PormG.SQLTypeFunction}
  @test !(String <: QB.ColumnPart)
  @test !(PormG.SQLTypeF <: QB.ColumnPart)
  @test !(PormG.SQLTypeCTE <: QB.ColumnPart)
  @test !(PormG.SQLTypeJoined <: QB.ColumnPart)
end
