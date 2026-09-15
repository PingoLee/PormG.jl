"""
Unit coverage for #68: `db_column` join-key resolution at hop TWO and beyond.

`_build_row_join` (`src/querybuilder/build_joins.jl`) resolves a Django-style path in two places
that implement the same four cases: a first-hop `if/elseif` chain, and a near-identical chain inside
the `while` loop that handles every later segment. The forward-FK key resolution
(`fk_target_column` / `field_db_column`) and the reverse one (`model_column` on each side) each
exist in BOTH copies — and before this file nothing in the suite intersected the two:

  - every `db_column` join test (`test/integration/test_db_column_db.jl`, the #64 section of
    `test_alignment_sqlite.jl`) is depth-1, so it only ever ran the FIRST-hop copy;
  - every 3+-segment path (`test_deep_fk_traversal.jl`, `raceid__circuitid__name`, …) traverses
    plain columns, so a `key_a`/`key_b` swap or a `model_column`-for-`field_db_column` substitution
    in the LOOP copy rendered exactly the same text.

The hole sat directly under the code #68 collapses. These testsets close it BEFORE the refactor, so
that both the typed-row change (#487) and the extraction (#68) are made against a suite that can
tell the loop copy from the first-hop copy. Every physical name here differs from its field name
(the `test_cte_db_column.jl` discipline), so a passing assertion cannot be a naming coincidence.

All assertions render through mock PostgreSQL/SQLite connections — no live database.

Sibling coverage:
  - `test/integration/test_db_column_db.jl` -> the depth-1 forms, executed on both backends.
  - `test_deep_fk_traversal.jl`             -> 3-hop shape over plain columns.
  - `test_cte_db_column.jl`                 -> a CTE's columns are projection aliases (#376).
  - `test_join_rows.jl`                     -> the typed `row_join` entries themselves (#487).
"""

using Test
using PormG
using PormG.Models

# Dedicated mock connections + config key: `runtests.jl` includes ~50 files into one `Main`, so a
# shared name would let another file's settings decide this file's dialect. Only the connection TYPE
# matters — dispatch picks SQLite vs PostgreSQL rendering.
struct Dc2MockSQLite <: PormG.PormGSQLite end
struct Dc2MockPostgres <: PormG.PormGPostgres end
const _DC2_SL = Dc2MockSQLite()
const _DC2_PG = Dc2MockPostgres()
PormG.backend_sqlite_version(::Dc2MockSQLite) = 3045000

PormG.config["dc2_mock"] = PormG.Configuration.Settings(
  connections = _DC2_PG, change_data = true, db_def_folder = "dc2_mock",
)

# Inline fixtures in their own module: `set_models` is REQUIRED here (not a style choice), because
# `_build_row_join` reads `instruct.object.model._module::Module` — a bare `Model(...)` leaves
# `_module === nothing` and TypeErrors the moment a join renders.
module Dc2Models
import PormG
import PormG.Models

# A three-level chain, Top <- Mid <- Leaf, where EVERY key column is renamed: both primary keys
# and both foreign keys carry a `db_column` that differs from the field name. A forward path from
# Leaf (`mid__top__label`) and a reverse path from Top (`mids__leaves__tag`) each cross two hops,
# so hop 2 is resolved by the loop copy of `_build_row_join` and hop 1 by the first-hop copy.
Dc2_top = Models.Model("dc2_top",
  code  = Models.IDField(db_column = "top_pk"),
  label = Models.CharField(null = true),
)

Dc2_mid = Models.Model("dc2_mid",
  code = Models.IDField(db_column = "mid_pk"),
  top  = Models.ForeignKey(Dc2_top, pk_field = "code", db_column = "top_fk",
                           on_delete = "CASCADE", related_name = "mids", null = true),
)

Dc2_leaf = Models.Model("dc2_leaf",
  id  = Models.IDField(),
  mid = Models.ForeignKey(Dc2_mid, pk_field = "code", db_column = "mid_fk",
                          on_delete = "CASCADE", related_name = "leaves", null = true),
  tag = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "dc2_mock")
end

const DC2 = Dc2Models
import PormG.QueryBuilder: inspect_query, CTE

# `count` over a literal String, not a Regex. "JOIN" is a substring of "LEFT JOIN", so this counts
# joins of any type.
_dc2_joins(sql::AbstractString) = count("JOIN", sql)

# The field names that must NEVER render as a column: each is mapped to a physical name above, so
# `"<alias>"."code"` (or `top` / `mid`) in the output means a hop resolved the FIELD name instead
# of the column. Checked as `"."<name>"` so a table name like "dc2_mid" does not match.
const _DC2_FIELD_NAMES = ("code", "top", "mid")
_dc2_leaks(sql::AbstractString) = [n for n in _DC2_FIELD_NAMES if occursin("\".\"$(n)\"", sql)]

# ─────────────────────────────────────────────────────────────────────────────
# db_column join keys, forward FK at depth 2: `mid__top__label` from Leaf
# Hop 1 (`Tb` -> `Tb_1`) is the first-hop forward arm; hop 2 (`Tb_1` -> `Tb_2`) is the LOOP's
# forward arm — the copy no earlier test reached with a renamed key. Both ON clauses must name the
# physical columns on both sides: the local FK column via `field_db_column`, the referenced parent
# PK via `fk_target_column`. The exact string is asserted so a `key_a`/`key_b` swap fails.
# ─────────────────────────────────────────────────────────────────────────────
@testset "forward FK at depth 2 resolves db_column on both sides of hop 2 (#68)" begin
  for (label, conn) in (("PostgreSQL", _DC2_PG), ("SQLite", _DC2_SL))
    @testset "$label" begin
      q = DC2.Dc2_leaf.objects
      q.values("tag")
      q.filter("mid__top__label" => "x")
      sql = inspect_query(q; connection = conn)[:sql_text]

      # Hop 1: Leaf.mid (physical "mid_fk") -> Mid.code (physical "mid_pk").
      @test occursin("JOIN \"dc2_mid\" AS \"Tb_1\" ON \"Tb\".\"mid_fk\" = \"Tb_1\".\"mid_pk\"", sql)
      # Hop 2: Mid.top (physical "top_fk") -> Top.code (physical "top_pk"). This is the loop copy.
      @test occursin("JOIN \"dc2_top\" AS \"Tb_2\" ON \"Tb_1\".\"top_fk\" = \"Tb_2\".\"top_pk\"", sql)
      # Exactly the two hops the path needs — no duplicate, no missing join.
      @test _dc2_joins(sql) == 2
      # The terminal column belongs to the SECOND hop's alias.
      @test occursin("\"Tb_2\".\"label\"", sql)
      # No field name leaked as a column anywhere in the statement.
      @test _dc2_leaks(sql) == String[]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# db_column join keys, reverse relation at depth 2: `mids__leaves__tag` from Top
# The mirror image: hop 1 is the first-hop reverse arm, hop 2 is the LOOP's reverse arm (the one
# that advances `vector` in-arm). A reverse join puts the parent's PK on the `a` side and the
# child's FK on the `b` side, each resolved through its own model's `model_column`, so the ON
# clause reads `"parent"."<pk_physical>" = "child"."<fk_physical>"` at both depths.
# ─────────────────────────────────────────────────────────────────────────────
@testset "reverse relation at depth 2 resolves db_column on both sides of hop 2 (#68)" begin
  for (label, conn) in (("PostgreSQL", _DC2_PG), ("SQLite", _DC2_SL))
    @testset "$label" begin
      q = DC2.Dc2_top.objects
      q.values("label")
      q.filter("mids__leaves__tag" => "x")
      sql = inspect_query(q; connection = conn)[:sql_text]

      # Hop 1: Top.code (physical "top_pk") <- Mid.top (physical "top_fk").
      @test occursin("JOIN \"dc2_mid\" AS \"Tb_1\" ON \"Tb\".\"top_pk\" = \"Tb_1\".\"top_fk\"", sql)
      # Hop 2: Mid.code (physical "mid_pk") <- Leaf.mid (physical "mid_fk"). This is the loop copy.
      @test occursin("JOIN \"dc2_leaf\" AS \"Tb_2\" ON \"Tb_1\".\"mid_pk\" = \"Tb_2\".\"mid_fk\"", sql)
      @test _dc2_joins(sql) == 2
      @test occursin("\"Tb_2\".\"tag\"", sql)
      @test _dc2_leaks(sql) == String[]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# db_column join keys, hop 2 out of a KEYED CTE: `CTE("ev", "top__label")`
# A CTE hop is first-hop only; the path continues through the CTE's projected ForeignKey, which is
# the loop's forward arm again — but with a CTE model as the source. #376 strips `db_column` from a
# CTE model's fields, so `key_a` must be the projection ALIAS the CTE exposes (`top`) while `key_b`
# still reads the real target model and keeps its physical column (`top_pk`). One ON clause, two
# different naming rules; the refactor must keep both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "forward FK at depth 2 out of a keyed CTE keeps the #376 split (#68)" begin
  for (label, conn) in (("PostgreSQL", _DC2_PG), ("SQLite", _DC2_SL))
    @testset "$label" begin
      # The CTE projects Mid's PK and its FK to Top; the outer query joins it on the PK.
      ev = DC2.Dc2_mid.objects
      ev.values("code", "top")
      q = DC2.Dc2_leaf.objects
      q.with("ev" => ev, join_field = "mid" => "code")
      q.values("tag", "lbl" => CTE("ev", "top__label"))
      sql = inspect_query(q; connection = conn)[:sql_text]

      # Inside the body the physical names are consumed and aliased away.
      @test occursin("\"Tb\".\"top_fk\" as \"top\"", sql)
      # Hop 2, CTE -> Top: alias on the CTE side, physical column on the model side.
      @test occursin("JOIN \"dc2_top\" AS \"R1_2\" ON \"R1_1\".\"top\" = \"R1_2\".\"top_pk\"", sql)
      # The projected column comes from the second hop's alias.
      @test occursin("\"R1_2\".\"label\" as \"lbl\"", sql)
      # `top_fk` appears exactly once — inside the CTE body — never on the outer join.
      @test count("top_fk", sql) == 1
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE name is a ROOT, never a mid-path segment
# The CTE arm of `_build_row_join` exists only in the first-hop chain; #68 lists that asymmetry as
# undocumented. This pins the current behavior so the extraction cannot silently widen it: a
# declared CTE name in segment two is an unknown column on the model reached by segment one, with
# the same `UnknownFieldError` any other unknown column gets.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a CTE name mid-path is an unknown column, not a join (#68)" begin
  ev = DC2.Dc2_top.objects
  ev.values("code", "label")
  q = DC2.Dc2_leaf.objects
  q.with("ev" => ev, join_field = "id" => "code")
  q.values("tag")
  q.filter("mid__ev__label" => "x")
  err = try
    inspect_query(q; connection = _DC2_SL)
    nothing
  catch e
    e
  end
  @test err isa PormG.UnknownFieldError
  # The message blames the segment on the model it was looked up on, not the CTE registry.
  @test occursin("ev", sprint(showerror, err))
  @test occursin("dc2_mid", sprint(showerror, err))
end
