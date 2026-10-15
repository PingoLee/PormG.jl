# #1147 — the MEANING departures: where one engine computes a different VALUE from the one an
# expression means, so PormG refuses the expression on that engine and builds it on the others.
#
# The reference is the meaning, never another engine. Before this table every cross-engine refusal
# compared the two engines ("PostgreSQL gives X, SQLite gives Y") and fired on both, so a PostgreSQL
# connection refused `Cast(<decimal>, "integer")` because SQLite would truncate it. With a third engine
# (#1130) such a pairwise rule makes every engine refuse what any engine gets wrong.
#
# Four categories decide what a divergence is (the 2026-10-10 decision on #1147):
# - MEANING: a different value or row set. One row here per (target, operand kind) where a fixed
#   operand type decides it: the engine that departs refuses, or PormG normalizes it on that engine
#   and it needs no row (`Sum` of a `bigint`, `Floor`/`Ceil`/`Abs` over an integer: #1147,
#   `_sums_bigint`, `_integer_operand_kind`; a decimal or float quotient, which SQLite divides as REAL:
#   #1150, `_division_sql`). An integer quotient over a `Sum` the walk cannot type is no row but an
#   engine fact (`_INTEGER_QUOTIENT_DEPARTURE`, `_untyped_sum_departs`, #1034 phase 3 step 2a).
# - REPRESENTATION: the same value written differently (the text of a float, a decimal, a timestamp,
#   an interval, a JSON document): no row, so a cast to text builds everywhere.
# - EXPLICIT INTENT: the query does not say what it means — a `Concat` over a number, a boolean or a
#   date, `Round` over text. Refused on every engine, naming the explicit spelling, with no
#   connection read (`_concat_textless_refusal`, `_round_text_refusal`). Not here.
# - FEATURE: a capability the backend lacks (`src/capabilities.jl`). Not here.
#
# A row is DATA rather than an `if` at the refusal site. Each row classifies EVERY backend in
# `_BACKENDS` (#1170): `departs` lists the abstract backend types that compute another value, which
# refuse, and `keeps` those that compute the meaning, which build. A backend in neither list is a
# decision nobody made; `test/unit/test_meaning_departures.jl` fails on it, so a new backend (#1130)
# gets one failing line per row instead of inheriting "keeps the meaning". `targets` are the sites
# that ask: `:text` and `:integer`
# (a declared cast to one), `:number` (a cast to any number type, #1259), `:scale` (`numeric(p, s)`), `:precision` (a literal `numeric(p, s)` cannot
# hold), `:single_precision` (`real`, #1215) and `:concat` (a `Concat` operand). `kinds` are the
# operand classes the classifiers in `projection_types.jl` name. `meaning`, `computes` and `fix` take the declared type, and `fix` also
# the operand's flag, the path a suggestion can name.
const _MEANING_DEPARTURES = (
  # #1028: a boolean's text is the word. SQLite has no boolean and stores 1 / 0.
  (targets = (:text,), kinds = (:bool,), departs = (PormGSQLite,), keeps = (PormGPostgres,), issue = "#1028",
   meaning = _ -> "its text, `true` or `false`",
   computes = _ -> "`1` or `0`, the integer it stores",
   fix = (flag, _) -> "Write the text you mean: \e[32mCase(When(\"$(flag)\" => true, then = Value(\"true\")), default = \"false\")\e[0m."),
  # #1028: a fractional number cast to an integer is the nearest one; SQLite's cast truncates.
  (targets = (:integer,), kinds = (:float, :decimal, :numeric), departs = (PormGSQLite,), keeps = (PormGPostgres,), issue = "#1028",
   meaning = _ -> "the nearest integer (`1.5` → `2`)",
   computes = _ -> "the truncated one (`1`)",
   fix = (_, _) -> "Say how to round it: \e[32mCast(Round(x), IntegerField())\e[0m, \e[32mFloor(x)\e[0m or \e[32mCeil(x)\e[0m."),
  # #1259: an interval is no number, so its cast to an integer, a float or a `numeric` is an error (the
  # tie-breaker: an error on one engine is left to raise when the engines that answer give the
  # meaning). SQLite casts the stored `HH:MM:SS.sss` text and reads its leading digits, the hours: a
  # silent different answer.
  (targets = (:integer, :number), kinds = (:interval,), departs = (PormGSQLite,), keeps = (PormGPostgres,), issue = "#1259",
   meaning = _ -> "an error, since an interval has no numeric value",
   computes = _ -> "the leading digits of its `HH:MM:SS` text, the hours",
   fix = (flag, _) -> "Fetch the duration and take the number you mean in Julia, or ask for its text, \e[32mCast(\"$(flag)\", \"text\")\e[0m, which each engine writes in its own form."),
  # #1040: a cast to `numeric(p, s)` rounds to `s` places. SQLite reads the type name as NUMERIC
  # affinity and keeps every digit; text is parsed and rounded by PostgreSQL, kept by SQLite.
  (targets = (:scale,), kinds = (:float, :decimal, :numeric, :text), departs = (PormGSQLite,), keeps = (PormGPostgres,), issue = "#1040",
   meaning = declared -> "the value rounded to the scale of $(declared)",
   computes = _ -> "every digit of it",
   fix = (_, declared) -> "Round it to the scale first (\e[32mCast(Round(x, $(something(_numeric_cast_scale(declared), 0))), \"$(declared)\")\e[0m, #1061), or cast to an unscaled \e[32m\"numeric\"\e[0m, which keeps the value."),
  # #1087: a literal the declared type cannot hold overflows: the cast is an error. SQLite stores it as it is,
  # a silent different answer (the tie-breaker: an error on one engine is left to raise when the
  # engines that answer give the meaning; SQLite does not).
  (targets = (:precision,), kinds = (:overflow,), departs = (PormGSQLite,), keeps = (PormGPostgres,), issue = "#1087",
   meaning = declared -> "a numeric field overflow, since $(declared) cannot hold it",
   computes = _ -> "the value as it is",
   fix = (_, declared) -> "Declare a precision that holds it (\e[32mCast(x, \"numeric(p, $(something(_numeric_cast_scale(declared), 0)))\")\e[0m with a larger p), or cast to an unscaled \e[32m\"numeric\"\e[0m."),
  # #1215: a single-precision float (`real`, `float4`, `float(p)` for p ≤ 24) is the value rounded to a
  # 4-byte float, which reads back as a `Float32`. SQLite has no 4-byte REAL: its cast keeps the
  # 8-byte double, so `0.1` stays `0.1` where single precision holds `0.10000000149011612`. The
  # operand does not decide it, so the one kind is `:value`, any operand.
  (targets = (:single_precision,), kinds = (:value,), departs = (PormGSQLite,), keeps = (PormGPostgres,), issue = "#1215",
   meaning = _ -> "the value rounded to single precision, a `Float32`",
   computes = _ -> "the 8-byte double, every digit of it",
   fix = (_, _) -> "Cast to a double, which is a `Float64` on every engine: \e[32mCast(x, \"float8\")\e[0m or \e[32mCast(x, FloatField())\e[0m."),
)

# #1111 — an integer quotient over a `Sum` the type walk cannot name (`_DIVISION_KINDS`, classified by
# `_whole_numeric_operand`). Not a row of the table above: which engine departs is not a fixed type
# but an engine fact, `_untyped_sum_departs` (#1034 phase 3 step 2a), so a backend that has not decided
# it gets a `MethodError` rather than the meaning by default (#1170). This holds the message only.
const _INTEGER_QUOTIENT_DEPARTURE = (
  targets = (:text, :integer, :scale, :concat), issue = "#1111",
  meaning = _ -> "an integer quotient (`15 / 2` is `7`) when the sum is whole",
  computes = _ -> "a `numeric` one (`7.5`) for a `bigint` or `numeric` sum",
  fix = (_, _) -> "Say which division you mean: cast the dividend to an integer first, \e[32mCast(x, BigIntegerField()) / 2\e[0m, which divides as integers on every engine, or divide by a float, \e[32mx / 2.0\e[0m, to keep the fraction.")

"""
    _departure(conn, target, kind) -> Union{NamedTuple, Nothing}

The `_MEANING_DEPARTURES` row by which `conn`'s engine departs from what `target` over an operand of
`kind` means, or `nothing` when it keeps the meaning (and the expression builds). An integer quotient
(`_DIVISION_KINDS`) departs where the engine fact `_untyped_sum_departs` says it does.
"""
function _departure(conn, target::Symbol, kind::Symbol)
  if kind in _DIVISION_KINDS
    row = _INTEGER_QUOTIENT_DEPARTURE
    return target in row.targets && _untyped_sum_departs(conn) ? row : nothing
  end
  for row in _MEANING_DEPARTURES
    target in row.targets && kind in row.kinds && any(T -> conn isa T, row.departs) && return row
  end
  return nothing
end

# Whether some engine departs for `(target, kind)`: a `Concat` operand of such a kind is a meaning
# question, refused only where it departs; any other kind is explicit intent, refused everywhere.
_meaning_kind(target::Symbol, kind::Symbol) =
  kind in _DIVISION_KINDS ? target in _INTEGER_QUOTIENT_DEPARTURE.targets :
  any(row -> target in row.targets && kind in row.kinds, _MEANING_DEPARTURES)

# The one message for a meaning departure: the expression, what it means, what the engine at hand
# computes, and the explicit spelling. It names that engine only — never a pair (#1129 item 3).
# RETURNS the exception; the call site throws it.
function _meaning_refusal(fname::AbstractString, what::AbstractString, row, conn;
                          flag::AbstractString = "<flag>", declared = nothing)
  engine = _backend_name(conn)
  return QueryBuildError(
    "\e[4m\e[31m$(fname)\e[0m of $(what) means $(row.meaning(declared)); $(engine) computes " *
    "$(row.computes(declared)), so PormG refuses it on $(engine) ($(row.issue)). $(row.fix(flag, declared))")
end
