"""
Unit coverage for #533 — a declared type must not admit a value no consumer handles.

Three issues reported one defect each, and all three were the same defect:

  - **#528** — `SQLOrder.field` was `Union{SQLTypeField,String}`, so a bare `String` type-checked at
    construction and then died in `get_order_query` with a raw `FieldError` naming the internal
    `._as` slot.
  - **#529** — `SQLTypeOrder <: SQLTypeField` (`Kernel.jl`), so an `SQLOrder` satisfied
    `WindowPartitionPart` and reached the renderer with no `_get_select_query` method — a raw
    `MethodError`.
  - **#530** — `_CompareOperand` did not admit `ZonedDateTime`, so `F("ts") == zdt` fell through to
    `Base.==` and evaluated to a bare `Bool`.

Two of the three were **inherited** admissions rather than written ones: one subtype relation put
`SQLOrder` into ~26 declared unions at once. That is why this is one invariant and not three guards.

**The invariant:** for every concrete node type a declared slot admits, the slot's entry point must
either accept it (build and render) or refuse it with a `PormGError` naming the supported spelling.
A raw `MethodError`, a raw `FieldError`, or a silently-returned `Bool` is the defect class.

Three design choices, all load-bearing:

  - **Offenders are grouped by admitted TYPE, not by slot.** One inherited admission is ONE cause
    with ONE remedy; reporting it once per slot would bury that under 26 identical lines.
  - **The probe runs the real entry point rather than asking `hasmethod`.** `hasmethod` cannot answer
    this question: `_resolve_window_expression` (`build_helpers.jl`) takes its argument untyped and
    branches on `isa`, so `hasmethod` is `true` for every type including the ones that die. What is
    asserted is the OUTCOME, which is #533's acceptance criterion executed rather than restated.
  - **A type with no specimen is itself an offender.** Adding a node type forces declaring how to
    build one, instead of letting the walk quietly skip it and stay green.

**Scope, precisely:** this file walks NODE types (`<: SQLType`, owned by `QueryBuilder`). The literal
half of an operand union — `Date`, `ZonedDateTime`, `Bool` — is not a node and is not covered here;
`test_f_date_operands.jl` owns the `_CompareOperand` / `FExpression.operand` derivation. Two files,
one invariant, split by what is reflectable.

Everything renders through mock connections — no live database.

**#867 extended it to function operands.** Two slots take their operand untyped and so admit every
node: the aggregates (`Sum`/`Avg`/`Count`/`Max`/`Min`, straight into `FObject.column`) and the
variadic family behind `_function_operand` (`Coalesce`, `Greatest`, `Power`, …). Probing both found
`Max(Subquery(…))` dying in `convert` and `Coalesce(SQLOrder(…), 0)` in the build walk. Both are
now refused at the constructor, and a `Subquery` operand of the variadic family renders.

Sibling coverage:
  - `test_memo_interface.jl`  → the same discipline as a TEXT scan over `src/`/`ext/` (#478).
  - `test_column_spec.jl`     → the same discipline as type reflection over `PormGField` slots (#507).
"""

using Test
using PormG
using PormG.Models
using InteractiveUtils: subtypes
import Dates
import TimeZones

struct AdmMockSQLite <: PormG.PormGSQLite end
struct AdmMockPostgres <: PormG.PormGPostgres end
const _ADM = AdmMockSQLite()
const _ADM_PG = AdmMockPostgres()
PormG.backend_sqlite_version(::AdmMockSQLite) = 3045000

PormG.config["adm_mock"] = PormG.Configuration.Settings(
  connections = _ADM, change_data = true, db_def_folder = "adm_mock",
)

module AdmModels
import PormG
import PormG.Models

Adm_parent = Models.Model("adm_parent", id = Models.IDField(), sku = Models.CharField())
Adm_child = Models.Model("adm_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Adm_parent, on_delete = "CASCADE", related_name = "adm_kids", null = true),
  note   = Models.CharField(null = true),
  qty    = Models.IntegerField(null = true),
  day    = Models.DateField(null = true),   # #878: a date operand for the transforms' subquery
)
PormG.Models.set_models(@__MODULE__, "adm_mock")
end

const AD = AdmModels
const QBA = PormG.QueryBuilder
import PormG.QueryBuilder: F, inspect_query, Joined, CTE, SQLOrder, SQLField, Value, Sum, Rank,
                           WindowOver, Lower, Lag, Lead, FirstValue, LastValue, NthValue, OP, Subquery, Exists, OuterRef, Q, Qor,
                           Max, Min, Avg, Count, Coalesce, Greatest, NullIf, Power,
                           Abs, Round, Cast, Extract, ToChar, Upper, Length, Trim, LTrim, RTrim,
                           Floor, Ceil, Sqrt, Exp, Ln

_adm_render(q) = inspect_query(q; connection = _ADM)[:sql_text]

# ─────────────────────────────────────────────────────────────────────────────
# Leaf expansion: a declared slot type → the concrete node types it admits.
#
# `Base.uniontypes` only splits a Union; an ABSTRACT member (`SQLTypeField`, `SQLTypeF`, …) still
# stands for every concrete subtype, which is exactly how #529 and #535 happened. So abstract members
# are expanded through `subtypes` too, recursively.
#
# The filter is the one `test_column_spec.jl` uses for `PormGField`: concrete, and owned by the module
# under test — otherwise a throwaway struct from another unit file joins the walk.
# ─────────────────────────────────────────────────────────────────────────────
function _node_leaves(T)
  out = Set{Type}()
  seen = Set{Any}()
  function walk(t)
    t in seen && return
    push!(seen, t)
    if t isa UnionAll
      walk(Base.unwrap_unionall(t)); return
    end
    if t isa Union
      for m in Base.uniontypes(t); walk(m); end
      return
    end
    t isa DataType || return
    t <: PormG.SQLType || return
    if isconcretetype(t)
      parentmodule(t) === QBA && push!(out, t)
    else
      for s in subtypes(t); walk(s); end
    end
  end
  walk(T)
  return out
end

_inner() = (s = AD.Adm_child.objects; s.filter("parent" => OuterRef("id")); s.values("qty"); s)

const SPECIMENS = Dict{Type,Any}(
  QBA.SQLField        => SQLField("note", "note"),
  QBA.SQLText         => Value("x"),
  QBA.SQLOrder        => SQLOrder(SQLField("note", "note")),
  QBA.FExpression     => F("note"),
  QBA.FObject         => Sum("qty"),
  QBA.WindowFunction  => Rank(over = WindowOver(partition_by = "note")),
  QBA.OperObject      => OP("note", "x"),
  QBA.CTEReference    => CTE("ev", "sku"),
  QBA.JoinedReference => Joined("d", "sku"),
  QBA.OuterRefObject  => OuterRef("id"),
  QBA.SubqueryObject  => Subquery(_inner()),
  QBA.ExistsObject    => Exists(_inner()),
  QBA.QObject         => Q("note" => "x"),
  QBA.QorObject       => Qor("note" => "x", "note" => "y"),
  # #867: the operand slots are declared as wide as `SQLType`, so they reach these two as well.
  QBA.WindowSpec      => WindowOver(partition_by = "note"),
  QBA.SQLArrays       => QBA.SQLArrays(),
)

_with_cte(q) = (c = AD.Adm_parent.objects; c.values("id", "sku");
                q.with("ev" => c, join_field = "parent" => "id"); q)

# Each entry: a label, the DECLARED type of the slot, and the entry point a caller actually writes.
# The entry point must build AND render — a slot that accepts a value and dies at render is the
# defect, so stopping at construction would miss #529 entirely.
const SLOTS = Tuple{String,Any,Function}[
  ("WindowSpec.partition_by", QBA.WindowPartitionPart,
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "r" => Rank(over = WindowOver(partition_by = v))); _adm_render(q))),

  ("WindowSpec.order_by", QBA.WindowOrderPart,
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "r" => Rank(over = WindowOver(order_by = v))); _adm_render(q))),

  ("WindowFunction.column", QBA.WindowColumnPart,
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "p" => Lag(v, over = WindowOver(order_by = "id"))); _adm_render(q))),

  # Each of these RENDERS, not merely constructs — the rule stated in the header. Review caught three
  # of them stopping at construction, which would have missed #529 (a slot that accepts a value and
  # dies at render is the whole defect class).
  ("SQLOrder.field", fieldtype(QBA.SQLOrder, :field),
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "note"); q.order_by(SQLOrder(v)); _adm_render(q))),

  ("SQLField.field", fieldtype(QBA.SQLField, :field),
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "x" => SQLField(v, "x")); _adm_render(q))),

  ("FExpression.operand", fieldtype(QBA.FExpression, :operand),
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id"); q.filter(F("note") == v); _adm_render(q))),

  ("FExpression.column", fieldtype(QBA.FExpression, :column),
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id");
         q.filter(QBA.FExpression(field_name = "note", operation = "=", operand = "x", column = v));
         _adm_render(q))),

  # Declared from the struct's own slot. Until #537 this was narrowed to `PormG.SQLTypeFunction` —
  # what `OP` accepts beyond a `String` — because `ColumnPart` was wider than any entry point could
  # construct (`String`, `SQLTypeF`, CTE / joined handles, a `Vector` member), and probing those
  # reported offenders that were the probe's own unrealism. #537 narrowed `ColumnPart` to exactly
  # what is built — `SQLTypeField` or `SQLTypeFunction` — so the real width IS the honest probe now,
  # and the node is handed to `filter` directly so every admitted member (a field, an aggregate, a
  # window) is exercised rather than only the ones `OP` can spell. `OP(...)` itself is exercised by
  # `test_op_function_column.jl`.
  ("OperObject.column", fieldtype(QBA.OperObject, :column),
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("note");
         q.filter(QBA.OperObject(operator = "=", values = "x", column = v)); _adm_render(q))),

  # #878: declared from the signature's own union, which `Lower` and the thirteen other one-argument
  # functions share. It was a hand-copied literal here, so a member added to the signature — the
  # `SubqueryObject` #878 admitted — would never have been probed.
  ("Lower(x) — the functions.jl family", QBA._ScalarOperand,
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "l" => Lower(v)); _adm_render(q))),

  ("Extract(x, part) / ToChar(x, format)", QBA._TemporalOperand,
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "y" => Extract(v, "year")); _adm_render(q))),

  ("SQLObjectQuery.values", eltype(fieldtype(QBA.SQLObjectQuery, :values)),
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "x" => v); _adm_render(q))),

  # #867 — the two operand slots that take their argument UNTYPED, so the declared type is every
  # node there is. The aggregates hand it to `FObject.column`; the variadic family hands it to
  # `_function_operand`, whose node arm stood at `Union{SQLType,SQLObject}` before #867 narrowed it.
  # (The `SQLObject` half — a bare query handler — is not a node, so the testset below covers it.)
  ("aggregate operand — Sum/Avg/Count/Max/Min", PormG.SQLType,
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "x" => Max(v)); _adm_render(q))),

  ("function operand — Coalesce/Greatest/… (_function_operand)", Union{PormG.SQLType,PormG.SQLObject},
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "x" => Coalesce(v, 0)); _adm_render(q))),

  # #878 — the `__@date`/`__@quarter`/`__@quadrimester` targets take `x` untyped too, and handed it
  # straight to `FObject.column`: `DATE(Subquery(…))` died in `convert`. `_transform_operand` gates it.
  ("transform operand — DATE/QUARTER/QUADRIMESTER", Union{PormG.SQLType,PormG.SQLObject},
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "x" => QBA.DATE(v)); _adm_render(q))),
]

# A TYPED refusal is a pass: admission was decided, loudly, by the taxonomy. Anything else — a raw
# MethodError, a raw FieldError, a `convert` error — is the defect this file exists to find.
_probe_ok(entry, v) = try
  entry(v)
  true
catch e
  e isa PormG.PormGError
end

# Known gaps: PINNED, not exempted. Each names an open issue, and the assertion below is EXACT — a
# new gap fails, and so does a FIXED one, which forces the pin to be removed alongside the fix. Same
# discipline as `test_memo_interface.jl`'s allowed-hit counts: "pinned, not bounded".
const KNOWN_GAPS = Dict{Type,Vector{String}}(
  # Empty since Session 28 closed both pins, and kept as an empty Dict on purpose — the EXACT
  # equality below is the discipline, and a new gap must land here with its issue number rather
  # than as an untracked failure:
  #   - #535 — `OuterRefObject` in `WindowFunction.column` and the `functions.jl` family — until
  #     `_check_function` gained its `::OuterRefObject` arm (`test_outer_ref_in_functions.jl`).
  #   - #537 — `FObject` / `WindowFunction` in `OperObject.column` via `OP()` — until the render path
  #     refused them with a typed error instead of reading `.field` (`test_op_function_column.jl`).
)

@testset "#533: every admitted node type has a consumer" begin
  offenders = Dict{Type,Vector{String}}()

  for (label, declared, entry) in SLOTS
    for T in _node_leaves(declared)
      if !haskey(SPECIMENS, T)
        push!(get!(offenders, T, String[]), "$label (no specimen declared)")
        continue
      end
      _probe_ok(entry, SPECIMENS[T]) || push!(get!(offenders, T, String[]), label)
    end
  end

  # The real assertion: nothing NEW.
  new_gaps = Dict{Type,Vector{String}}()
  for (T, labels) in offenders
    unpinned = filter(l -> !(l in get(KNOWN_GAPS, T, String[])), labels)
    isempty(unpinned) || (new_gaps[T] = unpinned)
  end
  if !isempty(new_gaps)
    @error """
    A declared slot admits a node type no consumer handles (#533).

    Fix it ONE of two ways: give the type a consumer arm, or stop admitting it. If ONE type lists
    MANY slots, the cause is an inherited subtype relation (`Kernel.jl`), not the slots — fix the
    relation, not 26 signatures. That is what #533 was filed for.
    """ new_gaps
  end
  @test isempty(new_gaps)

  # And the pin is exact, so fixing a pinned gap without deleting its pin fails here — as #535 and
  # #537 each did when they landed.
  @test offenders == KNOWN_GAPS

  # ── guard the guard ────────────────────────────────────────────────────────
  # Without these, a narrowed union or an empty walk makes the loop above vacuously green.
  #
  # The empty-leaves check is the one review found missing: `_node_leaves` returns ∅ for a slot whose
  # declared type is a `UnionAll` (`FObject.column` and `OperObject.values` both are), so adding such
  # a slot would contribute ZERO probes and still read as covered. A slot that probes nothing is a
  # slot that is not tested, and it must say so rather than pass.
  empty_slots = [label for (label, declared, _) in SLOTS if isempty(_node_leaves(declared))]
  isempty(empty_slots) || @error """
  A slot in SLOTS expands to no node types, so it probes nothing and passes vacuously.
  `_node_leaves` returns ∅ for a `UnionAll` declared type — unwrap it, or drop the slot.
  """ empty_slots
  @test isempty(empty_slots)

  @test length(SLOTS) >= 10
  @test haskey(SPECIMENS, QBA.SQLOrder)
  @test QBA.SQLField in _node_leaves(QBA.WindowPartitionPart)    # the walk descends ABSTRACT members
  @test QBA.CTEReference in _node_leaves(QBA.WindowPartitionPart)
  @test QBA.FExpression in _node_leaves(fieldtype(QBA.FExpression, :operand))

  # The probe must DISCRIMINATE. Without this the whole file could be green because `_probe_ok`
  # answers `true` unconditionally.
  @test !_probe_ok(v -> getfield(v, :no_such_slot), 1)          # raw error   → offender
  @test  _probe_ok(v -> throw(PormG.QueryBuildError("x")), 1)   # typed refusal → fine
  @test  _probe_ok(v -> "rendered", 1)                          # success     → fine
end

# ─────────────────────────────────────────────────────────────────────────────
# #533 change 1 — an ordering term is no longer a field expression.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#533: SQLTypeOrder is not a SQLTypeField" begin
  # The one line that closes ~26 admission sites. Asserted directly so a future refactor that
  # "tidies" the hierarchy has to argue with a test rather than rediscover why.
  @test !(PormG.SQLTypeOrder <: PormG.SQLTypeField)
  @test QBA.SQLOrder <: PormG.SQLTypeOrder
  @test !(QBA.SQLOrder <: PormG.SQLTypeField)

  # The consequences, spot-checked at the seams the superseded issues named.
  @test !(QBA.SQLOrder <: QBA.WindowPartitionPart)   # #529
  @test !(QBA.SQLOrder <: QBA.ColumnPart)
  # #537 — and `ColumnPart` itself is exactly what an `OperObject` is ever built with.
  @test fieldtype(QBA.OperObject, :column) === Union{PormG.SQLTypeField,PormG.SQLTypeFunction}
  @test QBA.SQLOrder <: QBA.WindowOrderPart          # …but ordering still belongs in ORDER BY

  # #529's own repro, now a typed refusal that names the spellings that work.
  err = try
    Rank(over = WindowOver(partition_by = [SQLOrder(SQLField("note", "note"))]))
    nothing
  catch e; e end
  @test err isa PormG.QueryBuildError
  @test occursin("ordering term", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# #533 change 2 — SQLOrder.field is narrowed, and every path runs through one funnel.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#533: SQLOrder.field admits only what its readers handle" begin
  @test fieldtype(QBA.SQLOrder, :field) === PormG.SQLTypeField

  # #528's repro. It used to construct and then raise a raw `FieldError` naming `._as`.
  q = AD.Adm_child.objects
  q.values("id", "note")
  q.order_by(SQLOrder("note"))
  sql = _adm_render(q)
  @test occursin("ORDER BY", sql)
  @test occursin("\"note\"", sql)

  # The String is NORMALIZED, not stored — that is what makes the readers' invariant hold.
  @test SQLOrder("note").field isa SQLField

  # A leading `-` is the fluent spelling's marker and has no meaning here: one direction, one slot.
  err = try; SQLOrder("-note"); nothing; catch e; e end
  @test err isa PormG.QueryBuildError
  @test occursin("orientation", err.msg)

  # An ordering term is not a column, and was constructible before the reparent.
  err2 = try; SQLOrder(SQLOrder(SQLField("note", "note"))); nothing; catch e; e end
  @test err2 isa PormG.QueryBuildError

  # An unsupported type reaches the funnel's typed refusal rather than a bare MethodError.
  err3 = try; SQLOrder(42); nothing; catch e; e end
  @test err3 isa PormG.QueryBuildError
  @test occursin("SQLField", err3.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# #533 change 3 — the operand vocabulary is named once and composed on both sides.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#533: the compare signature and the operand slot are one declaration" begin
  slot = fieldtype(QBA.FExpression, :operand)

  # Not "they agree" — they are BUILT from the same pieces, so they cannot disagree.
  for member in Base.uniontypes(QBA._CompareOperand)
    @test member <: slot
  end

  # #530's type, admitted now, with the render arm that makes admitting it honest.
  @test TimeZones.ZonedDateTime <: QBA._CompareOperand
  @test TimeZones.ZonedDateTime <: slot

  # The abstract `SQLTypeF` is gone from both slots — that is what closed the `OuterRefObject`
  # binds-raw hole (see #533's comment thread), and #535 is the same pattern one level out.
  @test !(QBA.OuterRefObject <: slot)
  @test !(QBA.OuterRefObject <: fieldtype(QBA.FExpression, :field_name))
  @test QBA.FExpression <: slot

  # #814 admitted `Period`/`CompoundPeriod` as COMPARISON literals — `(F(ts) - F(ts2)) > Hour(1)` —
  # with their own consumer (the literal arm binds `format_duration_sql`, and refuses a duration
  # against a non-interval) and oracle rows. What #494 forbade was the two unions drifting, which
  # composition still rules out. The arithmetic wrapper `Interval` stays out: it has no comparison
  # consumer.
  @test Dates.Period <: QBA._CompareOperand
  @test !(QBA.Interval <: QBA._CompareOperand)
  @test Dates.Period <: slot
end

# ─────────────────────────────────────────────────────────────────────────────
# #867 — shared helper: a refusal's message with the ANSI stripped, or whatever else was thrown.
# ─────────────────────────────────────────────────────────────────────────────
_adm_867_msg(f) = try
  f()
  nothing
catch e
  e isa PormG.QueryBuildError ? replace(e.msg, r"\e\[[0-9;]*m" => "") : e
end

# ─────────────────────────────────────────────────────────────────────────────
# #867 — the aggregates refuse a node `FObject.column` cannot hold, from the constructor.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#867: an aggregate refuses a node it cannot hold, at construction" begin
  # Each is raised by the constructor itself, before any `values()`. That is where the raw
  # `convert` error used to come from, and a refusal there points at the line the user wrote.
  for (name, agg) in (("Sum", Sum), ("Avg", Avg), ("Count", Count), ("Max", Max), ("Min", Min))
    msg = _adm_867_msg(() -> agg(Subquery(_inner())))
    @test msg isa String
    # The spelling that works: aggregate INSIDE the subquery, with this constructor's own name.
    @test occursin("s.values(\"t\" => $(name)(\"col\")); q.values(\"x\" => Subquery(s))", msg)
  end

  @test occursin("Sum(Case([When(Q(Exists(s)), then = 1)], default = 0))", _adm_867_msg(() -> Max(Exists(_inner()))))
  @test occursin("Subquery(s)", _adm_867_msg(() -> Count(_inner())))
  @test occursin("order_by", _adm_867_msg(() -> Min(SQLOrder(SQLField("note", "note")))))
  # The fallback names the type and never `repr`s the node: an `SQLArrays` has `undef` slots.
  @test occursin("`SQLArrays`", _adm_867_msg(() -> Sum(QBA.SQLArrays())))
  @test occursin("`$(nameof(Int))`", _adm_867_msg(() -> Sum(1)))

  # The Exists hint the refusal prints is a real query, not prose.
  q = AD.Adm_parent.objects
  q.values("id", "n" => Sum(PormG.Functions.Case([PormG.Functions.When(Q(Exists(_inner())), then = 1)], default = 0)))
  @test occursin(r"SUM\(CASE\s+WHEN \(EXISTS \(SELECT 1", _adm_render(q))
end

# ─────────────────────────────────────────────────────────────────────────────
# #867 — the aggregate gate passes what the slot holds, and the SQL is unchanged from main.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#867: what the aggregate gate admits renders as before" begin
  # A string, a CTE handle and a nested function all sit inside `FObject.column`'s own union, so
  # the gate returns them untouched. The SQL is pinned exactly, not by fragment.
  q = AD.Adm_child.objects
  q.values("note", "m" => Max("qty"), "c" => Count("id"; distinct = true), "s" => Sum(Coalesce("qty", 0)))
  @test _adm_render(q) == "SELECT\n    \"Tb\".\"note\" as \"note\", \n  MAX(\"Tb\".\"qty\") as \"m\", \n  COUNT(DISTINCT \"Tb\".\"id\") as \"c\", \n  SUM(COALESCE(\"Tb\".\"qty\", ?)) as \"s\"\nFROM \"adm_child\" as \"Tb\"\nGROUP BY 1 \n"   # rendered on main @ d43337df

  q = _with_cte(AD.Adm_child.objects)
  q.values("note", "m" => Max(CTE("ev", "sku")))
  @test occursin("MAX(", _adm_render(q))
  @test Max(CTE("ev", "sku")).column isa QBA.CTEReference
end

# ─────────────────────────────────────────────────────────────────────────────
# #867 — the variadic family: every consumed node is still admitted, the rest is refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#867: the variadic family refuses a query and an ordering term" begin
  # The positive half, so the refusal cannot grow past what the walk consumes: every leaf of the
  # consumer union must still CONSTRUCT. The #533 probe above cannot see an over-narrowing, because a
  # typed refusal is a pass there; this is the assertion that can.
  for T in _node_leaves(QBA._FunctionOperandNode)
    @test (Coalesce(SPECIMENS[T], 0); true)
  end
  @test length(_node_leaves(QBA._FunctionOperandNode)) >= 13

  # `Coalesce(qs, 0)` is the natural slip: the query, with `Subquery(...)` forgotten.
  @test occursin("Coalesce(Subquery(s), 0)", _adm_867_msg(() -> Coalesce(_inner(), 0)))
  @test occursin("order_by", _adm_867_msg(() -> Greatest(SQLOrder(SQLField("note", "note")), 1)))
  @test occursin("`WindowSpec`", _adm_867_msg(() -> Power(WindowOver(partition_by = "note"), 2)))
end

# ─────────────────────────────────────────────────────────────────────────────
# #867 — the half #863 fixed, pinned: a Subquery operand's SQL and parameters on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#867: a Subquery operand renders on both engines, with its parameters in place" begin
  # The parameter vector is pinned EXACTLY on both engines. On SQLite `Greatest` renders one
  # COALESCE per rotation (#844), so the subquery appears twice and its own parameter binds once
  # per copy, in text order with the literal between them. A misbind here is silent wrong data,
  # which is why a fragment check would not do.
  sub() = (s = AD.Adm_child.objects; s.filter("parent" => OuterRef("id"), "qty__@gt" => 3); s.values("t" => Max("qty")); s)
  build(f) = (q = AD.Adm_parent.objects; q.filter("sku" => "A"); q.values("id", "x" => f(Subquery(sub()))); q)

  for (backend, conn, greatest, coalesce, nullif) in (
      ("SQLite", _ADM, Any[3, 7.0, 7.0, 3, "A"], Any[3, 0, "A"], Any[3, 0, "A"]),
      ("PostgreSQL", _ADM_PG, Any[3, 7.0, "A"], Any[3, 0, "A"], Any[3, 0, "A"]))
    @testset "$backend" begin
      for (label, f, expected) in (("Greatest", s -> Greatest(s, 7.0), greatest),
                                   ("Coalesce", s -> Coalesce(s, 0), coalesce),
                                   ("NullIf",   s -> NullIf(s, 0), nullif))
        r = inspect_query(build(f); connection = conn)
        @test occursin("(SELECT", r[:sql_text])
        @test r[:parameters] == expected
      end
    end
  end

  # The rotation is visible in the SQLite text: two copies, each with its own alias.
  sql = inspect_query(build(s -> Greatest(s, 7.0)); connection = _ADM)[:sql_text]
  @test count("(SELECT", sql) == 2
  @test occursin("MAX(COALESCE((SELECT", sql)
  pg = inspect_query(build(s -> Greatest(s, 7.0)); connection = _ADM_PG)[:sql_text]
  @test occursin("GREATEST((SELECT", pg)
end

# ─────────────────────────────────────────────────────────────────────────────
# #878 — a Subquery operand of a one-argument function or a date transform: SQL and parameters.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#878: a Subquery operand of a single-operand function or a transform renders on both engines" begin
  # The #867 shape: the inner query binds its own `3`, the outer one binds `"A"`. The subquery's text
  # sits in the SELECT list, so its parameter comes first, then anything the function itself binds
  # (`Round`'s precision, which renders after the operand), then the outer WHERE. Pinned EXACTLY on
  # both engines — a misbind is silent wrong data, and a fragment check could not see one.
  nsub() = (s = AD.Adm_child.objects; s.filter("parent" => OuterRef("id"), "qty__@gt" => 3); s.values("t" => Max("qty")); s)
  dsub() = (s = AD.Adm_child.objects; s.filter("parent" => OuterRef("id"), "qty__@gt" => 3); s.values("t" => Max("day")); s)
  build(f, sub) = (q = AD.Adm_parent.objects; q.filter("sku" => "A"); q.values("id", "x" => f(Subquery(sub()))); q)

  cases = (
    ("Lower",    Lower,                     nsub, Any[3, "A"],    ("LOWER((SELECT",            "LOWER((SELECT")),
    ("Abs",      Abs,                       nsub, Any[3, "A"],    ("ABS((SELECT",              "ABS(((SELECT")),
    ("Round",    s -> Round(s, 2),          nsub, Any[3, 2, "A"], ("ROUND((SELECT",            "ROUND(((SELECT")),
    ("Cast",     s -> Cast(s, "integer"),   nsub, Any[3, "A"],    ("CAST((SELECT",             "((SELECT")),
    ("Extract",  s -> Extract(s, "year"),   dsub, Any[3, "A"],    ("strftime('%Y', (SELECT",   "EXTRACT(YEAR FROM (SELECT")),
    ("ToChar",   s -> ToChar(s, "YYYY-MM"), dsub, Any[3, "A"],    ("strftime('%Y-%m', (SELECT", "to_char((SELECT")),
    ("DATE",     QBA.DATE,                  dsub, Any[3, "A"],    ("strftime('%Y-%m-%d', (SELECT", "((SELECT")),
    ("QUARTER",  QBA.QUARTER,               dsub, Any[3, "A"],    ("strftime('%m', (SELECT",   "EXTRACT(QUARTER FROM (SELECT")),
  )
  for (backend, conn, i) in (("SQLite", _ADM, 1), ("PostgreSQL", _ADM_PG, 2))
    @testset "$backend" begin
      for (label, f, sub, params, needle) in cases
        r = inspect_query(build(f, sub); connection = conn)
        @test occursin(needle[i], r[:sql_text])
        @test r[:parameters] == params
      end
    end
  end
  # PostgreSQL's spellings that the needles above stop short of: the casts close AFTER the subquery.
  pg(f, sub) = inspect_query(build(f, sub); connection = _ADM_PG)[:sql_text]
  @test occursin(r"\)\)::integer as \"x\"", pg(s -> Cast(s, "integer"), nsub))
  @test occursin(r"\)\)::date as \"x\"", pg(QBA.DATE, dsub))

  # Every one-argument constructor shares `_ScalarOperand`, but a signature re-narrowed by hand would
  # only show up here: each must hold the subquery and render it, on both engines.
  unary = (Lower, Upper, Length, Abs, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln)
  @test length(unary) == 12          # + `Round` and `Cast`, pinned above = the 14 of the issue
  for ctor in unary, conn in (_ADM, _ADM_PG)
    @test ctor(Subquery(nsub())).column isa QBA.SubqueryObject
    r = inspect_query(build(ctor, nsub); connection = conn)
    @test occursin("(SELECT", r[:sql_text]) && r[:parameters] == Any[3, "A"]
  end

  # In an AGGREGATED outer query a wrapped subquery is a grouped expression — unlike a bare one,
  # which #92 keeps out of GROUP BY. It is grouped by ordinal, so nothing renders or binds twice.
  for conn in (_ADM, _ADM_PG)
    q = AD.Adm_parent.objects
    q.filter("sku" => "A")
    q.values("id", "n" => Count("adm_kids__id"), "x" => Lower(Subquery(nsub())))
    r = inspect_query(q; connection = conn)
    @test occursin(r"GROUP BY 1, 3\s*$", r[:sql_text])
    @test count("(SELECT", r[:sql_text]) == 1
    @test r[:parameters] == Any[3, "A"]
  end

  # A CTE body can type a subquery column through `Cast`, and a filter on that column binds after
  # the body's own parameter. A BARE subquery there is refused with this spelling as the fix
  # (`test_window_functions.jl`, #823).
  for conn in (_ADM, _ADM_PG)
    body = AD.Adm_parent.objects
    body.values("id", "m" => Cast(Subquery(nsub()), "integer"))
    q = AD.Adm_child.objects
    q.with("ev" => body, join_field = "parent" => "id")
    q.filter(CTE("ev", "m") => 7)
    q.values("id", CTE("ev", "m"))
    r = inspect_query(q; connection = conn)
    @test occursin("WITH", r[:sql_text]) && occursin("(SELECT", r[:sql_text])
    @test r[:parameters] == Any[3, 7]
  end

  # The transform keeps its read formatter with a subquery inside, which is what reads the value back
  # as a date (`_function_projection_kind` answers `CDate()` for a `DATE` node whatever its operand).
  @test QBA.DATE(Subquery(dsub())).formatter === PormG.Models.format_date_sql
  @test QBA.QUARTER(Subquery(dsub())).formatter === PormG.Models.format_quarter_sql
  @test QBA.QUADRIMESTER(Subquery(dsub())).formatter === PormG.Models.format_quadrimester_sql
  # …and the ladder's own input, a split path, still passes the gate unchanged.
  @test QBA.DATE(["day"]).column == ["day"]

  # The slot holds a `SubqueryObject` now, so the aggregate refusal no longer comes from the slot
  # leaving it out. It must still be refused, by the gate, for every aggregate.
  @test fieldtype(QBA.FObject, :column) >: QBA.SubqueryObject
  for agg in (Sum, Avg, Count, Max, Min)
    @test _adm_867_msg(() -> agg(Subquery(nsub()))) isa String
  end

  # What the transform gate refuses, it refuses by type name, with the path spelling that works.
  msg = _adm_867_msg(() -> QBA.DATE(SQLOrder(SQLField("day", "day"))))
  @test msg isa String
  @test occursin("`SQLOrder`", msg)
  @test occursin("\"col__@date\"", msg)
  @test occursin("`ExistsObject`", _adm_867_msg(() -> QBA.QUARTER(Exists(nsub()))))
  @test occursin("\"col__@quadrimester\"", _adm_867_msg(() -> QBA.QUADRIMESTER(1)))
  # The slot's `Vector{T}` admits any vector, but only a split path has a consumer: a vector of
  # anything else used to pass the gate and die in the build walk as a raw `MethodError`.
  @test occursin("\"col__@date\"", _adm_867_msg(() -> QBA.DATE([1, 2])))
  @test occursin("`$(Vector{Int})`", _adm_867_msg(() -> QBA.DATE([1, 2])))   # the vector's own type, not `Array`
  @test occursin("\"col__@quarter\"", _adm_867_msg(() -> QBA.QUARTER(Any["day"])))
end

# ─────────────────────────────────────────────────────────────────────────────
# #887 — a Subquery operand of the window value functions: SQL and parameters.
# `Lag`, `Lead`, `FirstValue`, `LastValue` and `NthValue` dispatched on `WindowColumnArg`, which left
# `SubqueryObject` out, so each raised a raw `MethodError` — #878's defect one family over. The SLOTS
# probe above now drives `WindowFunction.column` with a subquery too; this pins what it renders.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#887: a Subquery operand of a window value function renders on both engines" begin
  nsub() = (s = AD.Adm_child.objects; s.filter("parent" => OuterRef("id"), "qty__@gt" => 3); s.values("t" => Max("qty")); s)
  over = WindowOver(order_by = "id")
  build(w) = (q = AD.Adm_parent.objects; q.filter("sku" => "A"); q.values("id", "p" => w); q)

  @test QBA.SubqueryObject <: QBA.WindowColumnPart
  @test QBA.WindowColumnArg === Union{QBA.WindowColumnPart,AbstractString}   # still derived (#603)

  # The column renders first, so the subquery's own `3` binds first, then what the function binds
  # (`Lag`/`Lead`'s offset and default), then the outer WHERE. `NthValue`'s `n` is a literal in the
  # SQL. Pinned EXACTLY on both engines — a misbind is silent wrong data.
  cases = (
    ("Lag",        Lag(Subquery(nsub()); offset = 2, default = 99, over = over), Any[3, 2, 99, "A"], "LAG((SELECT"),
    ("Lead",       Lead(Subquery(nsub()); over = over),                          Any[3, 1, "A"],     "LEAD((SELECT"),
    ("FirstValue", FirstValue(Subquery(nsub()); over = over),                    Any[3, "A"],        "FIRST_VALUE((SELECT"),
    ("LastValue",  LastValue(Subquery(nsub()); over = over),                     Any[3, "A"],        "LAST_VALUE((SELECT"),
    ("NthValue",   NthValue(Subquery(nsub()), 2; over = over),                   Any[3, "A"],        "NTH_VALUE((SELECT"),
  )
  for (backend, conn) in (("SQLite", _ADM), ("PostgreSQL", _ADM_PG))
    @testset "$backend" begin
      for (label, w, params, needle) in cases
        @test w.column isa QBA.SubqueryObject
        r = inspect_query(build(w); connection = conn)
        @test occursin(needle, r[:sql_text])
        @test occursin("OVER (ORDER BY", r[:sql_text])
        @test r[:parameters] == params
      end
    end
  end

  # In an AGGREGATED outer query the window stays out of GROUP BY, and the subquery's correlation is
  # checked by #194 like any projected subquery's: on a grouped column it builds, on an ungrouped one
  # it is refused, naming the projection the caller wrote. The refused shape orders the window by
  # `sku`: a window ORDER BY term joins the group set (#789), so ordering by `id` would group the very
  # column the subquery correlates on, and that query is legal.
  for conn in (_ADM, _ADM_PG)
    q = AD.Adm_parent.objects
    q.values("id", "n" => Count("adm_kids__id"), "p" => Lag(Subquery(nsub()), over = over))
    r = inspect_query(q; connection = conn)
    @test occursin(r"GROUP BY 1\s*$", r[:sql_text])
    @test r[:parameters] == Any[3, 1]

    q = AD.Adm_parent.objects
    q.values("n" => Count("adm_kids__id"), "p" => Lag(Subquery(nsub()), over = WindowOver(order_by = "sku")))
    msg = _adm_867_msg(() -> inspect_query(q; connection = conn))
    @test msg isa String
    @test occursin("#194", msg)
    @test occursin("correlated column p correlates", msg)   # the alias, not "Subquery(…)"
  end

  # Inside another subquery it builds, like a bare nested `Subquery` (#938): the window's subquery
  # correlates to the child row around it, never past it to the parent.
  outer_sub = AD.Adm_child.objects
  outer_sub.filter("parent" => OuterRef("id"))
  outer_sub.values("t" => Lag(Subquery(nsub()), over = over))
  q = AD.Adm_parent.objects
  q.values("id", "x" => Subquery(outer_sub))
  @test _adm_867_msg(() -> _adm_render(q)) === nothing
  @test occursin(r"\"R2\"\.\"parent(_id)?\" = \"R1\"\.\"id\"", _adm_render(q))

  # A CTE body cannot type a window over a bare subquery (#878's reason), and says how to: a `Cast`
  # inside the window, which builds, and whose filter binds after the body's own parameters.
  body = AD.Adm_parent.objects
  body.values("id", "p" => Lag(Subquery(nsub()), over = over))
  q = AD.Adm_child.objects
  q.with("ev" => body, join_field = "parent" => "id")
  q.values("id", CTE("ev", "p"))
  msg = _adm_867_msg(() -> _adm_render(q))
  @test msg isa String
  @test occursin("LAG over Subquery(…)", msg)
  @test occursin("Lag(Cast(Subquery(…), \"integer\"), over = …)", msg)
  for conn in (_ADM, _ADM_PG)
    body = AD.Adm_parent.objects
    body.values("id", "p" => Lag(Cast(Subquery(nsub()), "integer"), over = over))
    q = AD.Adm_child.objects
    q.with("ev" => body, join_field = "parent" => "id")
    q.filter(CTE("ev", "p") => 7)
    q.values("id", CTE("ev", "p"))
    r = inspect_query(q; connection = conn)
    @test occursin("LAG(", r[:sql_text]) && occursin("(SELECT", r[:sql_text])
    @test r[:parameters] == Any[3, 1, 7]
  end

  # #508: one window node reused across two builds renders the same SQL and binds the same values,
  # and the caller's subquery is still the node it holds.
  sq = Subquery(nsub())
  w = Lag(sq, over = over)
  first_run = inspect_query(build(w); connection = _ADM)
  second_run = inspect_query(build(w); connection = _ADM)
  @test first_run[:sql_text] == second_run[:sql_text]
  @test first_run[:parameters] == second_run[:parameters] == Any[3, 1, "A"]
  @test w.column === sq
end
