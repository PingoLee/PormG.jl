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
const _ADM = AdmMockSQLite()
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
)
PormG.Models.set_models(@__MODULE__, "adm_mock")
end

const AD = AdmModels
const QBA = PormG.QueryBuilder
import PormG.QueryBuilder: F, inspect_query, Joined, CTE, SQLOrder, SQLField, Value, Sum, Rank,
                           WindowOver, Lower, Lag, OP, Subquery, Exists, OuterRef, Q, Qor

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

  # Probed through `OP(...)`, the real public constructor, and DECLARED as `SQLTypeFunction` — what
  # `OP` accepts beyond a `String`. An earlier draft declared the struct's own `ColumnPart` here and
  # handed `filter` a hand-built `OperObject`; that reported six offenders which were the probe's own
  # unrealism, so the draft after it made the slot construction-only and justified that with "there
  # is no public entry point". Both were wrong: `OP(::SQLTypeFunction, ::Any)` is public, documented,
  # and raises a raw `FieldError` at render (#537).
  #
  # `ColumnPart` is genuinely wider than any public entry point, and reconciling the two widths is
  # #537's to settle rather than this file's to assert. Narrowing the declared type here is what
  # keeps the report honest: it probes the spelling a user can actually write.
  ("OperObject.column via OP()", PormG.SQLTypeFunction,
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("note"); q.filter(OP(v, "x")); _adm_render(q))),

  ("Lower(x) — the functions.jl family",
   Union{String,PormG.SQLTypeField,PormG.SQLTypeText,PormG.SQLTypeFunction,PormG.SQLTypeF,PormG.SQLTypeCTE,PormG.SQLTypeJoined},
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "l" => Lower(v)); _adm_render(q))),

  ("SQLObjectQuery.values", eltype(fieldtype(QBA.SQLObjectQuery, :values)),
   v -> (q = _with_cte(AD.Adm_child.objects); q.values("id", "x" => v); _adm_render(q))),
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
  # (#535 — `OuterRefObject` in `WindowFunction.column` and the `functions.jl` family — was pinned
  # here until `_check_function` gained its `::OuterRefObject` arm; `test_outer_ref_in_functions.jl`
  # owns that spelling now, and the invariant covers it unconditionally.)

  # #537 — `OP(::SQLTypeFunction, value)` is a public constructor whose result nothing renders: the
  # path reads `.field` off the column, which only an `SQLField` has. Pre-existing on origin/main;
  # measured identically on both trees.
  QBA.FObject        => ["OperObject.column via OP()"],
  QBA.WindowFunction => ["OperObject.column via OP()"],
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

  # And the pin is exact, so fixing #535 without deleting its pin fails here.
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

  # The duration operands stay OUT of the comparison union: `F("seen") + Day(1)` is arithmetic, and
  # conflating the two was the whole of #494.
  @test !(Dates.Period <: QBA._CompareOperand)
  @test Dates.Period <: slot
end
