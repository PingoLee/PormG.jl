"""
`OuterRef` inside a scalar function or a window column (#535).

`OuterRefObject <: SQLTypeF`, so every union that names the abstract `SQLTypeF` admits it: the
~18 scalar-function signatures in `functions.jl` (`Lower`, `Upper`, `Cast`, `Length`, `Round`, …)
and `WindowColumnPart` (`Lag`, `Lead`, `FirstValue`, …). The RENDER side always had a consumer —
`_get_select_query(::OuterRefObject)` resolves the reference against the enclosing query's
`instruc.outer`, or throws `QueryBuildError` when there is none — but the BUILD side did not:
`_check_function` had no `::OuterRefObject` arm, so the projection path (`values("l" =>
Lower(OuterRef("surname")))`, which walks every function's `column` through `_check_function`) died
with a raw `MethodError` outside the #231 taxonomy before any SQL existed.

The fix is one identity arm, which makes `Lower(OuterRef("surname"))` inside a correlated subquery
render as `LOWER("Tb"."surname")` — legitimate SQL, and Django's spelling too (`OuterRef` subclasses
`F` there, so wrapping it in `Lower(...)` has always worked). Two things are pinned:

  1. **Inside a correlated build it renders**, resolving the outer alias exactly as a bare
     `OuterRef` does — through `Exists(...)`, through a projected `Subquery(...)`, wrapped in a
     scalar function and wrapped in a window column.
  2. **Outside one it refuses**, with the same typed `QueryBuildError` a bare `OuterRef` raises,
     rather than the raw `MethodError` the missing arm produced.

The filter-side spelling (`filter("body" => Lower(OuterRef("surname")))`) worked before the fix —
`_get_pair_to_oper` stores a function RHS unchecked — and is kept as the control that separates
"the render side was always fine" from "the build side was the gap".

Everything renders through mock connections — no live database. The live round-trip is in
`test/integration/test_exists_correlated.jl`.

Sibling coverage:
  - `test_node_admission.jl` → the invariant that found this; its `KNOWN_GAPS` pin for #535 is gone.
  - `test_exists_correlated.jl` (integration) → the driver round-trip against the F1 fixture.

julia --project=. test/unit/test_outer_ref_in_functions.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
using PormG.Functions: Lower, Cast, Lag, WindowOver

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct OrfMockSQLite <: PormG.PormGSQLite end
struct OrfMockPostgres <: PormG.PormGPostgres end
const _ORF_SL = OrfMockSQLite()
const _ORF_PG = OrfMockPostgres()
PormG.backend_sqlite_version(::OrfMockSQLite) = 3045000

PormG.config["orf_mock"] = PormG.Configuration.Settings(
  connections = _ORF_SL, change_data = true, db_def_folder = "orf_mock",
)

# A parent with a text column to wrap, and a child with a ForeignKey to correlate on.
module OrfModels
import PormG
import PormG.Models

Orf_driver = Models.Model("orf_driver",
  id      = Models.IDField(),
  surname = Models.CharField(),
)

Orf_note = Models.Model("orf_note",
  id     = Models.IDField(),
  driver = Models.ForeignKey(Orf_driver, on_delete = "CASCADE", related_name = "orf_notes", null = true),
  body   = Models.CharField(),
)

PormG.Models.set_models(@__MODULE__, "orf_mock")
end

const ORF = OrfModels

_orf_sql(q; conn = _ORF_SL) = inspect_query(q; connection = conn)[:sql_text]

const _ORF_BACKENDS = (("PostgreSQL", _ORF_PG), ("SQLite", _ORF_SL))

# `LOWER(...)` on PostgreSQL, and a Unicode-aware spelling on SQLite (#78) — so match the function
# name case-insensitively with any prefix, and pin the ARGUMENT exactly: it is the outer alias that
# proves the reference resolved against the enclosing query rather than the inner one.
_lower_of(col::String) = Regex("\\w*LOWER\\(\"Tb\"\\.\"$(col)\"\\)", "i")

# ─────────────────────────────────────────────────────────────────────────────
# Control: the FILTER-side spelling never broke. `_get_pair_to_oper` stores a function RHS without
# walking it, so `filter("body" => Lower(OuterRef("surname")))` reached the render side directly —
# which is what proves the render side was always able to resolve a wrapped outer reference. Kept so
# the regression testsets below are measured against a working baseline, not assumed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#535 control: a wrapped OuterRef as a filter VALUE already rendered" begin
  for (backend, conn) in _ORF_BACKENDS
    note = ORF.Orf_note.objects
    note.filter("driver" => OuterRef("id"), "body" => Lower(OuterRef("surname")))
    q = ORF.Orf_driver.objects
    q.values("id")
    q.filter(Exists(note))
    sql = _orf_sql(q; conn = conn)
    # The inner alias on the left, the OUTER alias inside the function on the right.
    @test occursin(Regex("\"R1\"\\.\"body\" = \\w*LOWER\\(\"Tb\"\\.\"surname\"\\)", "i"), sql)
    @test occursin("\"R1\".\"driver\" = \"Tb\".\"id\"", sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The regression: a wrapped OuterRef in a PROJECTION inside a correlated subquery. Before the fix
# `inner.values(...)` itself threw `MethodError: no method matching _check_function(::OuterRefObject)`
# — at construction, before any SQL existed, outside the taxonomy.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#535: a scalar function over an OuterRef renders inside a projected Subquery" begin
  for (backend, conn) in _ORF_BACKENDS
    inner = ORF.Orf_note.objects
    inner.filter("driver" => OuterRef("id"))
    inner.values("l" => Lower(OuterRef("surname")))

    q = ORF.Orf_driver.objects
    q.values("id", "x" => Subquery(inner))
    sql = _orf_sql(q; conn = conn)
    @test occursin(_lower_of("surname"), sql)
    # Correlated on the outer row, as the bare spelling is.
    @test occursin("\"R1\".\"driver\" = \"Tb\".\"id\"", sql)
  end

  # `Cast` is the other signature shape in the family (two positional arguments) — same arm.
  for (backend, conn) in _ORF_BACKENDS
    inner = ORF.Orf_note.objects
    inner.filter("driver" => OuterRef("id"))
    inner.values("c" => Cast(OuterRef("id"), "text"))
    q = ORF.Orf_driver.objects
    q.values("id", "x" => Subquery(inner))
    sql = _orf_sql(q; conn = conn)
    @test occursin("\"Tb\".\"id\"", sql)
    @test occursin(r"CAST\(|::text"i, sql)
  end
end

@testset "#535: a window column over an OuterRef renders inside a projected Subquery" begin
  for (backend, conn) in _ORF_BACKENDS
    inner = ORF.Orf_note.objects
    inner.filter("driver" => OuterRef("id"))
    inner.values("p" => Lag(OuterRef("id"), over = WindowOver(order_by = "id")))

    q = ORF.Orf_driver.objects
    q.values("id", "x" => Subquery(inner))
    sql = _orf_sql(q; conn = conn)
    @test occursin("LAG(\"Tb\".\"id\"", sql)
    @test occursin("OVER (ORDER BY \"R1\".\"id\"", sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `OuterRef("pk")` resolves to the outer model's primary key through the wrapper too — the
# resolution happens in `_get_filter_query(::OuterRefObject)`, which the wrapper now reaches.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#535: OuterRef(\"pk\") still auto-resolves when wrapped" begin
  for (backend, conn) in _ORF_BACKENDS
    inner = ORF.Orf_note.objects
    inner.filter("driver" => OuterRef("pk"))
    inner.values("l" => Lower(OuterRef("pk")))
    q = ORF.Orf_driver.objects
    q.values("id", "x" => Subquery(inner))
    sql = _orf_sql(q; conn = conn)
    @test occursin(_lower_of("id"), sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Outside a correlated build there is no outer row to resolve against, so the wrapped reference
# refuses with the SAME typed error a bare `OuterRef` raises — naming `Exists`, the place it is
# valid. Before the fix this was the raw `MethodError` at `values()` time; a bare `OuterRef` in the
# same position already raised the typed error, and the two must not differ.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#535: outside a correlated build a wrapped OuterRef raises QueryBuildError" begin
  for (backend, conn) in _ORF_BACKENDS
    for build in (
        () -> (q = ORF.Orf_driver.objects; q.values("l" => Lower(OuterRef("surname"))); q),
        () -> (q = ORF.Orf_driver.objects; q.values("p" => Lag(OuterRef("id"), over = WindowOver(order_by = "id"))); q),
        # The filter-side spelling (the control above) refuses at top level too — same error.
        () -> (q = ORF.Orf_driver.objects; q.values("id"); q.filter("surname" => Lower(OuterRef("surname"))); q),
      )
      err = try
        _orf_sql(build(); conn = conn)
        nothing
      catch e
        e
      end
      @test err isa PormG.QueryBuildError
      @test err !== nothing && occursin("Exists", PormG.error_message(err))
    end
  end
end
