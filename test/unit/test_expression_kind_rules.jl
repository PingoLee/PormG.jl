"""
The function result rules (#1034).

"What type does a function's value have?" used to be answered by four name lists kept apart from the
functions they named (`_KIND_PRESERVING_FUNCTIONS`, `_AGREEING_OPERAND_FUNCTIONS`,
`_FRACTIONAL_FUNCTIONS`, `_NUMERIC_OPERAND_FUNCTIONS`), each read by one consumer. A new function was
typed in whichever list its author remembered. Each function now states its rule beside its
constructor (`_result_rule`, `src/querybuilder/functions.jl`), and the readers consult that.

Pinned here:

  1. **The enumeration guard.** Every function name a constructor builds has its own `_result_rule`
     method, `:unknown` included, and every method names a function that exists. A new function fails
     here until its rule is stated.
  2. **The vocabulary.** Every rule is one the readers know.
  3. **The lists it replaced.** Each former list is exactly one rule group, so moving the readers to
     the table changed no answer; `test_expression_kind_matrix.jl` pins the answers themselves.
  4. **The walk's pure helpers** (`src/querybuilder/expression_kind.jl`): how two candidate values'
     kinds combine under each policy, the kind a declared type names (size included), and a computed
     number's type on each engine.
     What `_expression_kind` answers per shape is the matrix's `kind` channel.

DB-free: no connection is opened.

julia --project=test/integration test/unit/test_expression_kind_rules.jl
"""

using Test
using PormG

const _EKR_QB = PormG.QueryBuilder

# Dispatch-only engines: the per-engine kinds below key on the connection's type, never open one.
struct EkrMockPostgres <: PormG.PormGPostgres end
struct EkrMockSQLite <: PormG.PormGSQLite end

# Every function name a constructor builds, read from the source: `function_name = "X"` (the
# `FObject`/`WindowFunction` constructors) and `_pad_function("X", …)` (`LPad`/`RPad`, which pass the
# name through). `F` is `FExpression`'s name, an expression rather than a SQL function, and has no rule.
function _ekr_built_names()
  names = Set{String}()
  src = joinpath(pkgdir(PormG), "src")
  for (root, _, files) in walkdir(src), file in files
    endswith(file, ".jl") || continue
    text = read(joinpath(root, file), String)
    for m in eachmatch(r"function_name\s*=\s*\"([A-Z_]+)\"", text)
      push!(names, m.captures[1])
    end
    for m in eachmatch(r"_pad_function\(\"([A-Z_]+)\"", text)
      push!(names, m.captures[1])
    end
  end
  delete!(names, "F")
  return names
end

# The names that have a `_result_rule` method of their own, as opposed to the `::Val` fallback.
function _ekr_stated_names()
  stated = Set{String}()
  for m in methods(_EKR_QB._result_rule)
    arg = m.sig.parameters[2]
    arg isa DataType && arg <: Val && !isempty(arg.parameters) && arg.parameters[1] isa Symbol &&
      push!(stated, String(arg.parameters[1]))
  end
  return stated
end

# ─────────────────────────────────────────────────────────────────────────────
# Function result rules: every built function states one
# A name with no method falls to the `:unknown` fallback, which the readers treat as untyped — the
# silent shape #1034 was filed for. So every name a constructor builds must have its own method, and
# a method for a name nothing builds is a typo that types nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: every built function name states a result rule" begin
  built, stated = _ekr_built_names(), _ekr_stated_names()
  # Guard of the guard: the scan sees the constructors at all (aggregates, windows, the pads).
  @test length(built) >= 45
  @test all(n -> n in built, ("SUM", "LAG", "LPAD", "CAST", "DATE"))
  # Unstated names are the failure this file exists for; stale methods are typos.
  @test setdiff(built, stated) == Set{String}()
  @test setdiff(stated, built) == Set{String}()
end

# ─────────────────────────────────────────────────────────────────────────────
# Function result rules: every rule is one the readers know
# `_infer_function_kind`, `_textless_number` and `_zero_scale_decimal` branch on these symbols;
# a misspelt rule would match none of their branches and silently read as untyped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: every result rule is in the vocabulary" begin
  vocabulary = (:operand, :one_of, :first_operand, :promoting, :numeric, :declared, :unknown)
  for name in _ekr_stated_names()
    rule = _EKR_QB._result_rule(Val(Symbol(name)))
    @test rule in vocabulary || rule isa PormG.CanonicalType
  end
  # The fallback is the fail-open answer, and a node reaches its rule through its name.
  @test _EKR_QB._result_rule(Val(:NOT_A_FUNCTION)) === :unknown
  @test _EKR_QB._result_rule(PormG.Functions.Max("points")) === :operand
end

# ─────────────────────────────────────────────────────────────────────────────
# Function result rules: each former name list is one rule group
# The four lists the table replaced, restated as they were on `main` before #1034. Each is exactly one
# group of rules, so the readers that now ask the rule give every function the answer the list gave.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: the replaced name lists are rule groups" begin
  group(pred) = Set(n for n in _ekr_stated_names() if pred(_EKR_QB._result_rule(Val(Symbol(n)))))
  @test group(==(:operand)) == Set(["MAX", "MIN", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE"])
  @test group(==(:one_of)) == Set(["COALESCE", "GREATEST", "LEAST"])
  @test group(==(:numeric)) == Set(["AVG", "ROUND", "MOD", "SQRT", "EXP", "LN", "POWER"])
  @test group(r -> r in _EKR_QB._OPERAND_TYPED_RULES) ==
        Set(["MAX", "MIN", "SUM", "ABS", "FLOOR", "CEIL", "COALESCE", "GREATEST", "LEAST", "NULLIF",
             "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE"])
  # The declared-date read (#822, #852) applied to these five by name.
  @test group(r -> r in (:declared, :one_of)) == Set(["CAST", "CASE", "COALESCE", "GREATEST", "LEAST"])
  @test group(r -> r isa PormG.CDate) == Set(["DATE"])
end

# ─────────────────────────────────────────────────────────────────────────────
# Expression kind: two operands' kinds as one value's, per policy
# `Coalesce`/`Greatest`/`Least` and an untyped `Case` have a kind only when their candidate values
# agree. The READ policy demands the same kind, because a read parser runs per column; every-kind
# follows PostgreSQL's resolution — integers widen, integer < numeric < double, text is text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: _unify_kinds, read vs every kind" begin
  unify = _EKR_QB._unify_kinds
  read, all = _EKR_QB._ReadKinds(), _EKR_QB._AllKinds()
  # Read: the same kind or none, even where the families are compatible.
  @test unify(PormG.CDate(), PormG.CDate(), read) == PormG.CDate()
  @test unify(PormG.CInt32(), PormG.CInt64(), read) === nothing
  @test unify(PormG.CDecimal(10, 2), PormG.CDecimal(12, 2), read) === nothing
  # Every kind: numeric promotion, and a width the operands do not share is dropped.
  @test unify(PormG.CInt32(), PormG.CInt64(), all) == PormG.CInt64()
  @test unify(PormG.CInt32(), PormG.CFloat64(), all) == PormG.CFloat64()
  @test unify(PormG.CInt64(), PormG.CDecimal(10, 2), all) == PormG.CDecimal(nothing, nothing)
  @test unify(PormG.CDecimal(10, 2), PormG.CDecimal(10, 2), all) == PormG.CDecimal(10, 2)
  @test unify(PormG.CVarChar(250), PormG.CText(), all) == PormG.CText()
  # Kinds with no common type stay unknown under either policy: a date and a timestamp, a text and a number.
  @test unify(PormG.CDate(), PormG.CDateTime(true), all) === nothing
  @test unify(PormG.CText(), PormG.CInt32(), all) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Expression kind: a declared type keeps its size
# `_sql_type_field` maps a type NAME to a field and drops its size, so a `Cast(x, "numeric(10,2)")`
# would be typed a default-width decimal. `_declared_kind` reads the size from the name itself.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: _declared_kind reads the declared size" begin
  dk(t, conn = EkrMockPostgres()) = _EKR_QB._declared_kind(t, conn)
  @test dk("numeric(10,2)") == PormG.CDecimal(10, 2)
  @test dk("numeric(5)") == PormG.CDecimal(5, 0)
  @test dk("numeric") == PormG.CDecimal(nothing, nothing)
  @test dk("varchar(20)") == PormG.CVarChar(20)
  @test dk("text") == PormG.CText()
  @test dk("integer") == PormG.CInt32()
  @test dk("smallint") == PormG.CInt16()
  @test dk("bigint") == PormG.CInt64()
  @test dk("double precision") == PormG.CFloat64()
  @test dk("boolean") == PormG.CBool()
  @test dk("date") == PormG.CDate()
  # A type `_sql_type_field` cannot name has no kind (an array cast, an unknown name).
  @test dk("integer[]") === nothing
  # On SQLite a uuid or network cast renders `CAST(x AS TEXT)`, so it is text there and a uuid here.
  @test dk("uuid") == PormG.CUUID()
  @test dk("uuid", EkrMockSQLite()) == PormG.CText()
  @test dk("numeric(10,2)", EkrMockSQLite()) == PormG.CDecimal(10, 2)
end

# ─────────────────────────────────────────────────────────────────────────────
# Expression kind: a computed number's type on each engine
# The engine-dependent results #1034 states once. PostgreSQL: `Dialect` casts `Abs`/`Floor`/`Ceil` and
# every `:numeric` function to `numeric`; `Sum` and `Avg` render bare and take PostgreSQL's aggregate
# types (`sum(integer)` is `bigint`, `sum(bigint)` and `avg(integer)` `numeric`, `avg(double)` a
# double). SQLite: a `:promoting` function keeps an integer an integer, a `:numeric` one is a REAL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: _computed_kind, per engine" begin
  ck(name, k, conn) = _EKR_QB._computed_kind(Val(name), _EKR_QB._result_rule(Val(name)), k, conn)
  pg, sl = EkrMockPostgres(), EkrMockSQLite()
  int, big, flt, dec, ivl = PormG.CInt32(), PormG.CInt64(), PormG.CFloat64(), PormG.CDecimal(10, 2), PormG.CInterval()
  numeric = PormG.CDecimal(nothing, nothing)
  # PostgreSQL: the `::numeric` cast decides whatever the operand.
  @test ck(:ABS, int, pg) == numeric
  @test ck(:FLOOR, flt, pg) == numeric
  @test ck(:ROUND, flt, pg) == numeric
  @test ck(:MOD, int, pg) == numeric
  # PostgreSQL's own aggregate types.
  @test ck(:SUM, int, pg) == PormG.CInt64()
  @test ck(:SUM, big, pg) == numeric
  @test ck(:SUM, flt, pg) == flt
  @test ck(:SUM, dec, pg) == numeric
  @test ck(:SUM, ivl, pg) == ivl
  @test ck(:AVG, flt, pg) == flt
  @test ck(:AVG, int, pg) == numeric
  @test ck(:AVG, ivl, pg) == ivl
  @test ck(:AVG, nothing, pg) === nothing   # an operand PormG cannot type: a numeric, a double or an interval
  # SQLite: no cast, so the operand's number type, or a REAL.
  @test ck(:ABS, int, sl) == PormG.CInt64()
  @test ck(:FLOOR, flt, sl) == flt
  @test ck(:SUM, dec, sl) == numeric
  @test ck(:SUM, ivl, sl) == ivl
  @test ck(:ROUND, dec, sl) == flt
  @test ck(:AVG, int, sl) == flt
  @test ck(:AVG, ivl, sl) == ivl
end
