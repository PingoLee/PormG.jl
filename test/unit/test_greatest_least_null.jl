"""
`Greatest` / `Least` skip a NULL argument on SQLite, as they do on PostgreSQL (#844).

PostgreSQL's `GREATEST`/`LEAST` ignore NULL arguments: the result is NULL only when every argument
is. SQLite has neither function, and PormG rendered its scalar `MAX(a, b)` / `MIN(a, b)`, which
return NULL when ANY argument is NULL. The same query answered differently per engine, silently:
race 1000 on the F1 fixture has a `date` and no `fp1_date`, and `Greatest("date", "fp1_date")` was
`missing` on SQLite and the race date on PostgreSQL.

On SQLite the operands are now rewritten into one COALESCE per rotation:

    GREATEST(a, b, c)  →  MAX(COALESCE(a, b, c), COALESCE(b, c, a), COALESCE(c, a, b))

Four things are pinned:

  1. **The SQL.** SQLite renders the rotations; PostgreSQL is unchanged.
  2. **The parameters.** A literal operand appears once per rotation, and each appearance binds its
     own `?` in text order — including a later WHERE value, and a HAVING that re-renders the alias.
     Repeating a RENDERED string instead would have repeated a `?` bound once: a misbind.
  3. **The answer.** The rendered statement, executed on an in-memory SQLite, skips NULLs and gives
     NULL only when every argument is NULL.
  4. **One operand is untouched.** `Greatest(x)` is left as it was; it is a separate question.

Everything renders through mock connections; the execution uses `SQLite.DB()` in memory — no live
database.

julia --project=test/integration test/unit/test_greatest_least_null.jl
"""

using Test
using Dates
using PormG
using PormG.Models: Model, IDField, FloatField, CharField, DateField
using PormG.QueryBuilder: inspect_query
using PormG.Functions: Greatest, Least, Sum

include("helper_marker_alignment.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Fixtures: one model per mock backend, with nullable numeric and date columns. The same model name
# on both, so the two renders differ only by dialect.
# ─────────────────────────────────────────────────────────────────────────────
struct GlNullMockPostgres <: PormG.PormGPostgres end
struct GlNullMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::GlNullMockSQLite) = 3045000

PormG.config["gl_null_pg"] = PormG.Configuration.Settings(connections = GlNullMockPostgres(), change_data = true)
PormG.config["gl_null_sl"] = PormG.Configuration.Settings(connections = GlNullMockSQLite(), change_data = true)

function _gl_model(key)
  m = Model("gl_rows", id = IDField(), grp = CharField(),
            a = FloatField(null = true), b = FloatField(null = true), c = FloatField(null = true),
            d1 = DateField(null = true), d2 = DateField(null = true))
  m.connect_key = key
  return m
end
const _GL_PG = _gl_model("gl_null_pg")
const _GL_SL = _gl_model("gl_null_sl")

# Build a query on one backend's model and inspect it.
function _gl_inspect(build!::Function, model)
  q = model.objects
  build!(q)
  return inspect_query(q)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQL shape: SQLite renders one COALESCE per rotation; PostgreSQL is unchanged
# Two and three operands, for both functions. The rotation order is the operand list shifted left
# by one each time, so every operand leads exactly one COALESCE.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#844: SQLite renders NULL-skipping rotations, PostgreSQL its own function" begin
  sl = _gl_inspect(q -> q.values("g" => Greatest("a", "b")), _GL_SL)[:sql_text]
  @test occursin("MAX(COALESCE(\"Tb\".\"a\", \"Tb\".\"b\"), COALESCE(\"Tb\".\"b\", \"Tb\".\"a\"))", sl)

  sl = _gl_inspect(q -> q.values("l" => Least("a", "b", "c")), _GL_SL)[:sql_text]
  @test occursin("MIN(COALESCE(\"Tb\".\"a\", \"Tb\".\"b\", \"Tb\".\"c\"), " *
                 "COALESCE(\"Tb\".\"b\", \"Tb\".\"c\", \"Tb\".\"a\"), " *
                 "COALESCE(\"Tb\".\"c\", \"Tb\".\"a\", \"Tb\".\"b\"))", sl)

  # PostgreSQL's GREATEST/LEAST already skip NULLs, so its SQL does not move.
  pg = _gl_inspect(q -> q.values("g" => Greatest("a", "b"), "l" => Least("a", "b", "c")), _GL_PG)[:sql_text]
  @test occursin("GREATEST(\"Tb\".\"a\", \"Tb\".\"b\")", pg)
  @test occursin("LEAST(\"Tb\".\"a\", \"Tb\".\"b\", \"Tb\".\"c\")", pg)
  @test !occursin("COALESCE", pg)

  # One operand is left alone: SQLite's coalesce needs two arguments, and `Greatest(x)` is not
  # what #844 is about.
  sl = _gl_inspect(q -> q.values("g" => Greatest("a")), _GL_SL)[:sql_text]
  @test !occursin("COALESCE", sl)
end

# ─────────────────────────────────────────────────────────────────────────────
# Parameters: a literal binds once per appearance, in text order
# `Greatest("a", 101.0, 202.0)` puts each literal in all three rotations, so SQLite binds six values
# for the projection. A WHERE value follows them. Distinct sentinels make any misbind visible.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#844: literal operands bind once per rotation, in text order" begin
  insp = _gl_inspect(_GL_SL) do q
    q.values("g" => Greatest("a", 101.0, 202.0))
    q.filter("b__@gt" => 303.0)
  end
  assert_marker_count(insp, :sqlite)
  # Rotations: (a, 101, 202), (101, 202, a), (202, a, 101); then the WHERE value. The WHERE value is
  # whatever the field formatter binds — read it back rather than restating the formatter here.
  where_value = insp[:parameters][end]
  assert_bound_in_text_order(insp, Any[101.0, 202.0, 101.0, 202.0, 202.0, 101.0, where_value])

  # PostgreSQL binds each literal once; `$N` travels with the text.
  pg = _gl_inspect(_GL_PG) do q
    q.values("g" => Greatest("a", 101.0, 202.0))
    q.filter("b__@gt" => 303.0)
  end
  assert_marker_count(pg, :postgres)
  @test pg[:parameters][1:2] == Any[101.0, 202.0]
end

# ─────────────────────────────────────────────────────────────────────────────
# Aggregate operand under GROUP BY / HAVING
# A filter on the alias re-renders the expression in HAVING. Each render goes through the rewrite,
# so HAVING carries the same rotations and binds its own copy of the literal, before the compared
# value.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#844: an aggregate operand groups, and HAVING re-renders the rotations" begin
  insp = _gl_inspect(_GL_SL) do q
    q.values("grp", "g" => Greatest(Sum("a"), 5.0))
    q.filter("g__@gt" => 7.0)
  end
  sql = insp[:sql_text]
  @test occursin("GROUP BY", sql)
  rotations = "MAX(COALESCE(SUM(\"Tb\".\"a\"), ?), COALESCE(?, SUM(\"Tb\".\"a\")))"
  @test occursin(rotations, sql)
  @test occursin("HAVING " * rotations, sql)
  assert_marker_count(insp, :sqlite)
  # SELECT's two, HAVING's two, then the compared value.
  compared = insp[:parameters][end]
  assert_bound_in_text_order(insp, Any[5.0, 5.0, 5.0, 5.0, compared])
end

# ─────────────────────────────────────────────────────────────────────────────
# Execution: the rendered statement, run on an in-memory SQLite, skips NULLs
# The mock renders the SQL; a real SQLite database with the same table runs it. Before #844 the
# first and third rows gave NULL (MAX/MIN saw a NULL argument). Now only the all-NULL row is NULL,
# which is PostgreSQL's answer. The date pair is the issue's own case: a date and no second date.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#844: executed on SQLite, NULL arguments are skipped" begin
  isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
  db = Main.SQLite.DB()
  try
    Main.SQLite.DBInterface.execute(db, """CREATE TABLE gl_rows (id INTEGER PRIMARY KEY, grp TEXT,
        a REAL, b REAL, c REAL, d1 TEXT, d2 TEXT)""")
    # id 1: one NULL among numbers; id 2: all NULL; id 3: the race-1000 shape (a date, no second).
    Main.SQLite.DBInterface.execute(db, """INSERT INTO gl_rows VALUES
        (1, 'x', 1.0, NULL, 3.0, '2018-07-29', NULL),
        (2, 'x', NULL, NULL, NULL, NULL, NULL),
        (3, 'y', 2.0, 5.0, NULL, NULL, '2018-07-27')""")

    insp = _gl_inspect(_GL_SL) do q
      q.values("id", "g" => Greatest("a", "b", "c"), "l" => Least("a", "b", "c"),
               "gd" => Greatest("d1", "d2"), "ld" => Least("d1", "d2"))
      q.order_by("id")
    end
    # Read inside the iteration: a SQLite row is a view of the cursor, gone once it advances.
    rows = Dict{Int,Any}()
    for r in Main.SQLite.DBInterface.execute(db, insp[:sql_text], insp[:parameters])
      rows[r.id] = (g = r.g, l = r.l, gd = r.gd, ld = r.ld)
    end

    # `isequal`, not `==`: before the fix these were `missing`, and `missing == x` is `missing`, which
    # `@test` reports as an error rather than a failure.
    @test isequal((rows[1].g, rows[1].l), (3.0, 1.0))     # the NULL `b` is skipped
    @test isequal((rows[3].g, rows[3].l), (5.0, 2.0))     # the NULL `c` is skipped
    @test all(ismissing, values(rows[2]))                 # every argument NULL → NULL
    @test isequal((rows[1].gd, rows[1].ld), ("2018-07-29", "2018-07-29"))
    @test isequal((rows[3].gd, rows[3].ld), ("2018-07-27", "2018-07-27"))

    # A literal in the rotations executes with its parameters in the right slots: the larger of `a`
    # and 1.5. Each row discriminates — `a` wins on row 3, the literal on row 1, and the NULL `a` on
    # row 2 is skipped rather than nulling the result.
    insp = _gl_inspect(_GL_SL) do q
      q.values("id", "g" => Greatest("a", 1.5))
      q.order_by("id")
    end
    got = Dict{Int,Any}()
    for r in Main.SQLite.DBInterface.execute(db, insp[:sql_text], insp[:parameters])
      got[r.id] = r.g
    end
    @test isequal(got, Dict(1 => 1.5, 2 => 1.5, 3 => 2.0))
  finally
    close(db)
  end
end
