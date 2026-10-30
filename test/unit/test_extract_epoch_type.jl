using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, DateTimeField, DurationField
using PormG.QueryBuilder: inspect_query, F, Sum
using PormG.Functions: Extract

# ─────────────────────────────────────────────────────────────────────────────
# #1457: `Extract(x, "EPOCH")` is a decimal, on every engine that has the part.
#
# `EPOCH` was the one date part with no stated type: `_result_rule(EXTRACT)` is `:unknown` and the
# integer parts' list leaves it out, since it is fractional. So the type walk named nothing for it, and
# three readers felt that: MySQL refused its quotient as "a side whose type PormG cannot name" though
# its `EPOCH` is a DECIMAL; the #1111 classifier flagged a `Sum` over it as a sum it cannot type; and the
# filter formatter typed it by a fallback. The walk now names it a width-less decimal on PostgreSQL and
# MySQL, and PostgreSQL renders `EXTRACT(EPOCH FROM x)::numeric`, so the type holds below 14 too, where
# `extract` is a `double precision`. SQLite has no `EPOCH` part (a capability, unchanged).
# ─────────────────────────────────────────────────────────────────────────────
struct EpochMockPostgres <: PormG.PormGPostgres end
struct EpochMockMySQL <: PormG.PormGMySQL end
struct EpochMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::EpochMockSQLite) = 3045000

PormG.config["epoch_pg"] = PormG.Configuration.Settings(connections = EpochMockPostgres(), change_data = true)
PormG.config["epoch_my"] = PormG.Configuration.Settings(connections = EpochMockMySQL(), change_data = true)
PormG.config["epoch_sl"] = PormG.Configuration.Settings(connections = EpochMockSQLite(), change_data = true)

function _epoch_model(key)
  m = Model("epoch_races", raceid = IDField(), year = IntegerField(), start_at = DateTimeField(null = true),
            fastestlaptime = DurationField(null = true))
  m.connect_key = key; m._module = Main   # a CTE resolves its model through the module (#1034 testset below)
  return m
end
const _EPOCH_PG = _epoch_model("epoch_pg")
const _EPOCH_MY = _epoch_model("epoch_my")
const _EPOCH_SL = _epoch_model("epoch_sl")

# The built instruction of `values("v" => expr)` and the projected node, for asking the walk about it.
function _epoch_built(m, expr)
  QB = PormG.QueryBuilder
  q = m.objects
  q.values("v" => expr)
  instr = QB.build(q.object)
  return instr, QB._projected_source(QB.memo_key(:base, "v"), instr).field
end

_epoch_sql(m, expr, conn) = (q = m.objects; q.values("v" => expr); inspect_query(q; connection = conn)[:sql_text])

# ─────────────────────────────────────────────────────────────────────────────
# The walk names `EPOCH` a decimal, and PostgreSQL casts it to one.
# Expected: `_expression_kind(Extract("start_at", "EPOCH"))` is `CDecimal(nothing, nothing)` on
# PostgreSQL and MySQL, over a timestamp and over a duration; PostgreSQL renders
# `EXTRACT(EPOCH FROM "Tb"."start_at")::numeric`. Why it matters: every reader of the walk (the #1111
# division check, the formatter, a CTE column's field) sees the seconds as the decimal they are.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1457: the walk names Extract(x, \"EPOCH\") a decimal on PostgreSQL and MySQL" begin
  for (engine, m) in ((:postgres, _EPOCH_PG), (:mysql, _EPOCH_MY)), field in ("start_at", "fastestlaptime")
    @testset "$engine: $field" begin
      instr, node = _epoch_built(m, Extract(field, "EPOCH"))
      @test PormG.QueryBuilder._expression_kind(node, instr) == PormG.CDecimal(nothing, nothing)
    end
  end
  @test occursin("EXTRACT(EPOCH FROM \"Tb\".\"start_at\")::numeric as \"v\"",
                 _epoch_sql(_EPOCH_PG, Extract("start_at", "EPOCH"), EpochMockPostgres()))
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL builds the quotient of an `EPOCH` and of a `Sum` over one.
# Expected: `values("v" => Extract("start_at", "EPOCH") / 2)` and `Sum(Extract("fastestlaptime",
# "EPOCH")) / 2` build on MySQL. Before #1457 both raised `QueryBuildError` ("`/` over a side whose type
# PormG cannot name"), though MySQL's `EPOCH` is a DECIMAL and divides keeping the fraction, as
# PostgreSQL's does. Why it matters: the refusal was false, so a correct query could not be written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1457: MySQL builds a quotient over Extract(x, \"EPOCH\")" begin
  for expr in (Extract("start_at", "EPOCH") / 2, Sum(Extract("fastestlaptime", "EPOCH")) / 2)
    sql = _epoch_sql(_EPOCH_MY, expr, EpochMockMySQL())
    @test occursin(" / ?", sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A `Sum` over `EPOCH` arithmetic is a sum the walk types, and its formatter is the walk's.
# Expected, on PostgreSQL: `_whole_numeric_operand(Sum(F("year") + Extract("start_at", "EPOCH")) / 2)`
# is `nothing` (it was `:numeric_whole_division`, the fail-closed "sum the walk cannot type", #1111), the
# walk names the quotient a decimal, and the formatter a filter on it uses is the walk's number
# formatter, not the fallback arm that typed it before. Why it matters: these were the false flags and
# the fallback hits the #1034 scoreboard attributed to `EPOCH`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1457: a Sum over EPOCH arithmetic is typed by the walk" begin
  QB = PormG.QueryBuilder
  instr, node = _epoch_built(_EPOCH_PG, Sum(F("year") + Extract("start_at", "EPOCH")) / 2)
  @test QB._whole_numeric_operand(node, instr) === nothing
  @test QB._expression_kind(node, instr) == PormG.CDecimal(nothing, nothing)
  @test QB._kind_formatter(QB._expression_kind(node, instr), instr) === QB._expression_formatter(node, instr)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite has no `EPOCH` part.
# Expected: `Extract("start_at", "EPOCH")` raises `BackendCapabilityError` on SQLite, as before #1457.
# Why it matters: stating a type for the part must not turn a missing feature into a build.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1457: SQLite still has no EPOCH part" begin
  @test_throws PormG.BackendCapabilityError _epoch_sql(_EPOCH_SL, Extract("start_at", "EPOCH"), EpochMockSQLite())
end

# ─────────────────────────────────────────────────────────────────────────────
# #1034 (the #1457 leftover): `Concat` reads `EPOCH`'s kind from the walk, alone as under a CTE
# `_concat_textless_operand` gave `Extract(x, "EPOCH")` alone no class, while the same expression as a
# CTE column (a `DecimalField` since #1460) was a decimal: `Concat` over it built alone and was refused
# under a CTE. The classifier's leaf reads the walk now. Expected on PostgreSQL and MySQL: the class is
# `:decimal` alone and as a CTE column; `Concat(Value("t="), Extract("start_at", "EPOCH"))` raises the
# #1027 explicit-intent refusal, naming `Cast(…, "text")`; with the cast it builds
# (`CONCAT($1::text, (EXTRACT(EPOCH FROM "Tb"."start_at")::numeric)::text)` on PostgreSQL, `CONCAT_WS`
# on MySQL). An integer part
# (`YEAR`) still passes. Why it matters: one answer in every context, and a decimal's text is the
# engine's own (its places differ), which `Concat` does not choose for the caller.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: Concat over Extract(x, \"EPOCH\") is a decimal's text, alone as under a CTE" begin
  QB = PormG.QueryBuilder
  Fn = PormG.Functions
  for (m, conn) in ((_EPOCH_PG, EpochMockPostgres()), (_EPOCH_MY, EpochMockMySQL()))
    engine = nameof(typeof(conn))
    @testset "$engine" begin
      instr, node = _epoch_built(m, Extract("start_at", "EPOCH"))
      @test QB._concat_textless_operand(node, instr) == (:decimal, "`EXTRACT(…)`")
      # The CTE column agrees.
      body = m.objects; body.values("raceid", "e" => Extract("start_at", "EPOCH"))
      outer = m.objects; outer.with("c" => body, join_field = "raceid" => "raceid"); outer.values("w" => PormG.CTE("c", "e"))
      r = Ref{Any}()
      QB.query(outer; connection = conn, show_query = :sql,
               built = i -> (r[] = QB._concat_textless_operand(QB._projected_source(QB.memo_key(:base, "w"), i).field, i)))
      @test r[] !== nothing && r[][1] === :decimal
      err = try _epoch_sql(m, Fn.Concat(Fn.Value("t="), Extract("start_at", "EPOCH")), conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
      @test occursin("(#1027)", msg) && occursin("Cast(", msg)
      cast_sql = _epoch_sql(m, Fn.Concat(Fn.Value("t="), Fn.Cast(Extract("start_at", "EPOCH"), "text")), conn)
      @test occursin(r"CONCAT(_WS)?\(", cast_sql)   # MySQL: `CONCAT_WS`
      conn isa PormG.PormGPostgres && @test occursin("(EXTRACT(EPOCH FROM \"Tb\".\"start_at\")::numeric)::text)", cast_sql)
      @test occursin(r"CONCAT(_WS)?\(", _epoch_sql(m, Fn.Concat(Fn.Value("y="), Extract("start_at", "YEAR")), conn))
    end
  end
end
