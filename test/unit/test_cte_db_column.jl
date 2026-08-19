"""
Unit coverage for #376: a CTE's columns are its `values()` projection ALIASES, never the source
model's `db_column`.

A CTE (or any projected subquery) is a DERIVED table. The physical column name is consumed INSIDE
the body — `SELECT "Tb"."product_sku" as "sku"` — and the only name it exposes to the outer query
is `sku`. Before #376 the synthesized CTE model stored the SOURCE model's field objects verbatim,
`db_column` and all, so every outer reference resolved through `Models.field_db_column` and named a
column the CTE does not have (`column R1_1.product_sku does not exist` / `no such column`).

The fix strips `db_column` at CTE-model construction (`Models.field_without_db_column`, applied in
`_build_cte_custom_model`), so the model stops misdescribing itself and THREE reference sites become
correct with no CTE branch in any of them:
  - the terminal column of every dotted path (`filter` / `values` / `order_by` / annotate / `F()`),
  - the deep-path join key when a CTE projects a ForeignKey and the path continues,
  - the JSON-lookup base column when a CTE projects a JSONField.

It also keeps #373's sargable date-bucket rewrite landing on the right column. That rewrite is gated
by a drift guard which recomputes `field_db_column` from the cached terminal field and refuses to
fire unless it matches the rendered column. Pre-#376 the guard matched — both sides read the same
field object — and the rewrite fired onto the nonexistent physical column. Stripping at construction
keeps them matching, now on the alias. Resolving the alias at the REFERENCE site instead would have
made them disagree, failing the guard closed and silently dropping the rewrite; the `#373` testset
below is what discriminates between the two fixes.

All assertions render via mock PostgreSQL/SQLite connections — no live database.

Sibling coverage:
  - `test_db_column.jl` → the `field_without_db_column` helper itself, and the #50 base contract.
  - `test_alignment_sqlite.jl` → the #64 CTE/M2M join-KEY half of the same rule.
  - `test_cte_ergonomics.jl` → CTE join shapes (#44), no db_column involved.
  - `test/integration/test_db_column_db.jl` → the same queries executed on both backends.
"""

using Test
using PormG
using PormG.Models

# Dedicated mock connections + config key so this file cannot contaminate (or be contaminated by)
# other unit files sharing Main in runtests.jl. Only the connection TYPE matters — dispatch selects
# SQLite `?`/`json_extract` vs PostgreSQL `$N`/`#>>` rendering.
struct CteDbColMockSQLite <: PormG.PormGSQLite end
struct CteDbColMockPostgres <: PormG.PormGPostgres end
const _CDC_SL = CteDbColMockSQLite()
const _CDC_PG = CteDbColMockPostgres()
# ORDER BY renders NULL placement via a library-version probe (#75); pin a modern version so
# order_by works on the mock without a live driver (same pattern as test_alignment_sqlite.jl).
PormG.backend_sqlite_version(::CteDbColMockSQLite) = 3045000

PormG.config["cte_dbcol_mock"] = PormG.Configuration.Settings(
  connections = _CDC_PG, change_data = true, db_def_folder = "cte_dbcol_mock",
)

# Inline fixtures in their own module: `set_models` is REQUIRED here (not a style choice), because
# `_build_row_join` reads `instruct.object.model._module::Module` — a bare `Model(...)` leaves
# `_module === nothing` and TypeErrors the moment a join renders.
module CteDbColModels
import PormG
import PormG.Models

# Every mapped field's PHYSICAL name differs from its FIELD name, so any assertion that sees a
# physical name outside the CTE body is a real failure and not a naming coincidence.
Cdc_parent = Models.Model("cdc_parent",
  id   = Models.IDField(),
  sku  = Models.CharField(db_column = "product_sku"),
  seen = Models.DateField(db_column = "seen_on", null = true),
  meta = Models.JSONField(db_column = "meta_json", null = true),
  name = Models.CharField(null = true),
)

Cdc_child = Models.Model("cdc_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Cdc_parent, db_column = "parent_fk", on_delete = "CASCADE", null = true),
  note   = Models.CharField(null = true),
)

# Control model: no db_column anywhere. A CTE over this must render exactly as it did pre-#376 —
# the fix has to be a strict no-op when nothing is renamed.
Cdc_plain = Models.Model("cdc_plain",
  id   = Models.IDField(),
  sku  = Models.CharField(),
  note = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "cte_dbcol_mock")
end

const CDC = CteDbColModels
import PormG.QueryBuilder: inspect_query

# Count occurrences of a physical column name in the rendered SQL. The contract is positional as
# well as textual: a physical name may appear EXACTLY ONCE (inside the CTE body's `as` projection)
# and never again, so a plain `occursin` would not catch a leak into the outer query. `count` over a
# literal String, not a Regex — a needle carrying regex syntax would otherwise silently change what
# is matched. Prefixed like the mocks above: `runtests.jl` includes ~50 files into one `Main`.
_cdc_hits(sql::AbstractString, needle::AbstractString) = count(needle, sql)

# The `sku` CTE reused across cases: SELECT "Tb"."product_sku" as "sku" FROM cdc_parent.
_cdc_sku_cte() = (c = CDC.Cdc_parent.objects; c.values("id", "sku"); c)

@testset "CTE columns are projection aliases, not db_column (#376)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # CTE reference: filter on a CTE-projected db_column field
  # `.with("ev" => cte).filter("ev__sku" => …)` must render `"R1_1"."sku"` — the alias the CTE
  # exposes. Pre-#376 it rendered `"R1_1"."product_sku"`, which no backend can resolve.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "filter on a CTE-projected db_column field uses the alias" begin
    q = CDC.Cdc_parent.objects
    q.with("ev" => _cdc_sku_cte(), join_field = "id" => "id")
    q.filter("ev__sku" => "ABC")
    q.values("id")

    insp = inspect_query(q)
    sql = insp[:sql_text]

    # The outer predicate names the ALIAS ...
    @test occursin("\"R1_1\".\"sku\" = \$1", sql)
    # ... and the physical name appears exactly once, in the CTE BODY's projection — nowhere else.
    @test occursin("\"Tb\".\"product_sku\" as \"sku\"", sql)
    @test _cdc_hits(sql, "product_sku") == 1
    @test insp[:parameters] == ["ABC"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CTE reference: cross-dialect parity on SQLite
  # The bug is a column-NAME defect, not a rendering one, so the alias contract must hold
  # identically under `?` placeholders.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite renders the same alias contract" begin
    q = CDC.Cdc_parent.objects
    q.with("ev" => _cdc_sku_cte(), join_field = "id" => "id")
    q.filter("ev__sku" => "ABC")
    q.values("id")

    sql = inspect_query(q; connection = _CDC_SL)[:sql_text]
    @test occursin("\"R1_1\".\"sku\" = ?", sql)
    @test _cdc_hits(sql, "product_sku") == 1
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CTE reference: values() / SELECT on a CTE-projected db_column field
  # The select path funnels through the same terminal resolution as filter; asserting it separately
  # is what the issue's acceptance list asks for (filter / values / order_by each covered).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "values() projects the CTE alias" begin
    q = CDC.Cdc_parent.objects
    q.with("ev" => _cdc_sku_cte(), join_field = "id" => "id")
    q.values("name", "s" => "ev__sku")

    sql = inspect_query(q)[:sql_text]
    @test occursin("\"R1_1\".\"sku\" as \"s\"", sql)
    @test _cdc_hits(sql, "product_sku") == 1
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CTE reference: order_by() on a CTE-projected db_column field
  # ORDER BY must resolve the CTE column FRESHLY, so the ordered column is deliberately neither
  # projected nor filtered: `get_order_query` reuses `instruc.cache` when the same path was already
  # resolved (build_query.jl:138), and `get_filter_query` runs first — so filtering `ev__seen` here
  # would silently test the filter's selector instead. `ev__sku` is filtered only to emit the JOIN:
  # a CTE column referenced ONLY by order_by registers the alias without emitting one, a separate
  # pre-#376 defect that also hits plain FK paths (`order_by("fk__col")`) on models with no
  # db_column at all — this file must not depend on it, so the join is asserted too.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "order_by() sorts on the CTE alias" begin
    cte = CDC.Cdc_parent.objects
    cte.values("id", "sku", "seen")

    q = CDC.Cdc_parent.objects
    q.with("ev" => cte, join_field = "id" => "id")
    q.filter("ev__sku" => "ABC")     # emits the join, and caches "ev__sku" — NOT "ev__seen"
    q.values("id")
    q.order_by("ev__seen")           # ... so this path is resolved here for the first time

    sql = inspect_query(q)[:sql_text]
    @test occursin("JOIN \"ev\" AS \"R1_1\" ON \"R1\".\"id\" = \"R1_1\".\"id\"", sql)
    @test occursin(r"ORDER BY\s+\"R1_1\"\.\"seen\" ASC", sql)
    @test _cdc_hits(sql, "seen_on") == 1     # physical name only in the CTE body
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CTE reference: a CUSTOM projection alias is what the outer query must name
  # `values("psku" => "sku")` makes the CTE expose `psku`. This is the sharpest form of the bug:
  # pre-#376 the outer query rendered `"R1_1"."product_sku"` — a name that appears NOWHERE in the
  # emitted statement, since the body aliased the column to `psku`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a custom projection alias is the outer name" begin
    cte = CDC.Cdc_parent.objects
    cte.values("id", "psku" => "sku")

    q = CDC.Cdc_parent.objects
    q.with("ev" => cte, join_field = "id" => "id")
    q.filter("ev__psku" => "ABC")
    q.values("id")

    sql = inspect_query(q)[:sql_text]
    @test occursin("\"Tb\".\"product_sku\" as \"psku\"", sql)   # the body aliases to psku ...
    @test occursin("\"R1_1\".\"psku\" = \$1", sql)              # ... so the outer query names psku
    @test _cdc_hits(sql, "product_sku") == 1
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CTE reference: a ForeignKey projected in a CTE, referenced terminally
  # An FK field carries `db_column` for its LOCAL column ("parent_fk"). Projected into a CTE it is
  # exposed as `parent`, so an outer reference to it is the alias like any other column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a projected ForeignKey is referenced by its alias" begin
    cte = CDC.Cdc_child.objects
    cte.values("id", "parent")

    q = CDC.Cdc_child.objects
    q.with("ev" => cte, join_field = "id" => "id")
    q.values("note", "p" => "ev__parent")

    sql = inspect_query(q)[:sql_text]
    @test occursin("\"R1_1\".\"parent\" as \"p\"", sql)
    @test _cdc_hits(sql, "parent_fk") == 1                          # only the CTE body's projection
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Sibling site: a projected ForeignKey TRAVERSED further (the deep-path join key)
  # `ev__parent__sku` builds a second join FROM the CTE alias. Its `key_a` is a CTE column and must
  # be the alias; `key_b` and the terminal column belong to the REAL target table and must keep
  # their physical names — both halves of the contract asserted in one query.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "traversing a projected ForeignKey joins on the alias" begin
    cte = CDC.Cdc_child.objects
    cte.values("id", "parent")

    q = CDC.Cdc_child.objects
    q.with("ev" => cte, join_field = "id" => "id")
    q.values("note", "s" => "ev__parent__sku")

    sql = inspect_query(q)[:sql_text]
    # The join OUT of the CTE keys on the alias the CTE exposes ...
    @test occursin("\"R1_1\".\"parent\" = \"R1_2\".\"id\"", sql)
    @test !occursin("\"R1_1\".\"parent_fk\"", sql)
    # ... while the joined REAL table still resolves its own db_column (#50 is not weakened).
    @test occursin("\"R1_2\".\"product_sku\" as \"s\"", sql)
    @test _cdc_hits(sql, "parent_fk") == 1
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Sibling site: a projected JSONField extracted through
  # A non-terminal JSONField is a value EXTRACTION on the joined alias (#27). The base column it
  # extracts from is a CTE column, so it too must be the alias, not "meta_json".
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a projected JSONField extracts from the alias" begin
    cte = CDC.Cdc_parent.objects
    cte.values("id", "meta")

    q = CDC.Cdc_parent.objects
    q.with("ev" => cte, join_field = "id" => "id")
    q.filter("ev__meta__driver" => "senna")
    q.values("id")

    sql = inspect_query(q)[:sql_text]
    @test occursin("\"R1_1\".\"meta\"", sql)      # extraction targets the alias
    @test _cdc_hits(sql, "meta_json") == 1            # physical name only in the CTE body
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #373 crossover: the sargable date-bucket rewrite lands on the CTE's alias
  # `_checked_bucket_column` refuses the rewrite unless the cached terminal field's resolved column
  # matches the rendered one. That matched BEFORE #376 as well — both sides read the same field
  # object, agreed on the physical name, and the rewrite fired onto a column the CTE does not
  # expose. What changed is WHICH name they agree on. Resolving the alias at the reference site
  # instead would have made them disagree, failing the guard closed and silently dropping the #352
  # rewrite; so this testset discriminates between the two candidate fixes, not fix vs. no-fix.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "sargable date-bucket rewrite survives a CTE (#373)" begin
    cte = CDC.Cdc_parent.objects
    cte.values("id", "seen")

    q = CDC.Cdc_parent.objects
    q.with("ev" => cte, join_field = "id" => "id")
    q.filter("ev__seen__@yyyy_mm__@lte" => "1991-10")
    q.values("id")

    insp = inspect_query(q)
    sql = insp[:sql_text]
    # Rewritten to a half-open range on the raw column — no to_char wrapper ...
    @test !occursin("to_char", lowercase(sql))
    # ... asserted on the FULL predicate, never a bare "<" (which also matches "<=").
    @test occursin(" < \$1", sql) && !occursin(" <= \$1", sql)
    @test insp[:parameters] == ["1991-11-01"]     # @lte "1991-10" → strictly before 1991-11-01
    # And it ranges on the CTE's alias column, not the physical name.
    @test occursin("\"R1_1\".\"seen\"", sql)
    @test _cdc_hits(sql, "seen_on") == 1
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Premise guard: a CTE body never exposes bare PHYSICAL names
  # The fix assumes every CTE column has an alias `key_new` agrees with. Two shapes could break
  # that by rendering `SELECT *`, and BOTH are pinned here because the src comment now relies on
  # both: `values("*")` is rejected outright, and a CTE with no `.values()` at all renders `*` in
  # the body but yields a ZERO-field model, so every outer reference fails closed. The second is
  # the drift path that matters — `_subquery_projection_labels` already defaults an empty `values`
  # to `model.field_names` for SUBqueries, and doing that "helpfully" here would hand the CTE model
  # FIELD names while the body emits PHYSICAL ones: #376 reintroduced silently, suite still green.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a CTE body cannot expose physical names (premise guard)" begin
    # (a) values("*") is rejected when the CTE model is built.
    star = CDC.Cdc_parent.objects
    star.values("*")

    q = CDC.Cdc_parent.objects
    q.with("ev" => star, join_field = "id" => "id")
    q.values("id")

    # Asserted on the CAUSE, not just the type: UnknownFieldError is raised from ~8 sites across
    # build_joins.jl/ctes.jl, so a type-only check would stay green if this query later failed for
    # an unrelated reason and stopped guarding the premise at all.
    err = try inspect_query(q); nothing catch e; e end
    @test err isa PormG.UnknownFieldError
    err isa PormG.UnknownFieldError &&
      @test occursin("_set_field_from_sql_function", PormG.error_message(err))

    # (b) No `.values()` at all: the body renders `SELECT *`, but the CTE model has no fields, so
    # referencing ANY column of it fails closed rather than resolving to a physical name.
    bare = CDC.Cdc_parent.objects        # deliberately no .values()

    q2 = CDC.Cdc_parent.objects
    q2.with("ev" => bare, join_field = "id" => "id")
    q2.values("id", "s" => "ev__sku")

    err2 = try inspect_query(q2); nothing catch e; e end
    @test err2 isa PormG.UnknownFieldError
    # The trailing empty "available fields:" list IS the mechanism: zero fields on the CTE model.
    # If an empty `values` ever defaulted to the model's field names, this list would be populated
    # and the reference would resolve — to a name the `SELECT *` body does not expose.
    err2 isa PormG.UnknownFieldError &&
      @test endswith(PormG.error_message(err2), "available fields: ")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The worst form: a collision that returned WRONG DATA rather than erroring
  # When the CTE aliases some OTHER field to the physical name (`"product_sku" => "name"`), the
  # pre-#376 resolution of `ev__sku` to `"R1_1"."product_sku"` named a column that DOES exist on
  # the CTE — carrying `name`'s values. No backend error, no failed query: silently wrong rows.
  # Every other case in this file fails loudly; this one is why the fix is a correctness fix and
  # not merely a "query used to error" fix.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a colliding alias returned wrong data, not an error" begin
    cte = CDC.Cdc_parent.objects
    cte.values("sku", "product_sku" => "name")   # exposes "sku" (=sku) AND "product_sku" (=name)

    q = CDC.Cdc_parent.objects
    q.with("ev" => cte, join_field = "sku" => "sku")
    q.values("id", "x" => "ev__sku")

    sql = inspect_query(q)[:sql_text]
    # The CTE really does expose a "product_sku" column carrying `name` — without this the rest of
    # the testset would pass vacuously if the body ever stopped emitting that projection.
    @test occursin("\"Tb\".\"name\" as \"product_sku\"", sql)
    # The outer projection reads the CTE's `sku` column ...
    @test occursin("\"R1_1\".\"sku\" as \"x\"", sql)
    # ... and NOT its `product_sku` column, which here holds `name` — the silent-wrong-data path.
    @test !occursin("\"R1_1\".\"product_sku\"", sql)
    # The main-table side of the join key is a real physical column and still resolves (#64).
    @test occursin("\"R1\".\"product_sku\" = \"R1_1\".\"sku\"", sql)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Control: a CTE over a model with NO db_column is untouched
  # `field_without_db_column` returns the identical object when there is nothing to strip, so the
  # overwhelmingly common case must render exactly as before — this guards against the fix
  # "fixing" queries that were already correct.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a db_column-free CTE renders unchanged" begin
    cte = CDC.Cdc_plain.objects
    cte.values("id", "sku")

    q = CDC.Cdc_plain.objects
    q.with("ev" => cte, join_field = "id" => "id")
    q.filter("ev__sku" => "ABC")
    q.values("id", "s" => "ev__sku")

    sql = inspect_query(q)[:sql_text]
    @test occursin("\"Tb\".\"sku\" as \"sku\"", sql)     # body: column == field name
    @test occursin("\"R1_1\".\"sku\" = \$1", sql)        # outer filter
    @test occursin("\"R1_1\".\"sku\" as \"s\"", sql)     # outer projection
  end

end
