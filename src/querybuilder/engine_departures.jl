# #1147 — the MEANING departures: where one engine computes a different VALUE from the one an
# expression means, so PormG refuses the expression on that engine and builds it on the others.
#
# The reference is the meaning, never another engine. Before this table every cross-engine refusal
# compared the two engines ("PostgreSQL gives X, SQLite gives Y") and fired on both, so a PostgreSQL
# connection refused `Cast(<decimal>, "integer")` because SQLite would truncate it. With a third engine
# (#1130) such a pairwise rule makes every engine refuse what any engine gets wrong.
#
# Four categories decide what a divergence is (the 2026-10-10 decision on #1147):
# - MEANING: a different value or row set. One row here per (target, operand kind): the engine that
#   departs refuses, or PormG normalizes it on that engine and it needs no row (`Sum` of a `bigint`,
#   `Floor`/`Ceil`/`Abs` over an integer: #1147, `_sums_bigint`, `_integer_operand_kind`).
# - REPRESENTATION: the same value written differently (the text of a float, a decimal, a timestamp,
#   an interval, a JSON document): no row, so a cast to text builds everywhere.
# - EXPLICIT INTENT: the query does not say what it means — a `Concat` over a number, a boolean or a
#   date, `Round` over text. Refused on every engine, naming the explicit spelling, with no
#   connection read (`_concat_textless_refusal`, `_round_text_refusal`). Not here.
# - FEATURE: a capability the backend lacks (`src/capabilities.jl`). Not here.
#
# A row is DATA rather than an `if` at the refusal site, so #1034's phase 3 can compute the departing
# engine from `_computed_kind` against `_result_rule` and delete the table. `engine` is an abstract
# backend type; a backend with no row for a kind is taken to keep the meaning, so a new backend adds
# its rows when it is checked against them. `targets` are the sites that ask: `:text` and `:integer`
# (a declared cast to one), `:scale` (`numeric(p, s)`), `:precision` (a literal `numeric(p, s)` cannot
# hold) and `:concat` (a `Concat` operand). `kinds` are the operand classes the classifiers in
# `projection_types.jl` name. `meaning`, `computes` and `fix` take the declared type, and `fix` also
# the operand's flag, the path a suggestion can name.
const _MEANING_DEPARTURES = (
  # #1028: a boolean's text is the word. SQLite has no boolean and stores 1 / 0.
  (targets = (:text,), kinds = (:bool,), engine = PormGSQLite, issue = "#1028",
   meaning = _ -> "its text, `true` or `false`",
   computes = _ -> "`1` or `0`, the integer it stores",
   fix = (flag, _) -> "Write the text you mean: \e[32mCase(When(\"$(flag)\" => true, then = Value(\"true\")), default = \"false\")\e[0m."),
  # #1028: a fractional number cast to an integer is the nearest one; SQLite's cast truncates.
  (targets = (:integer,), kinds = (:float, :decimal, :numeric), engine = PormGSQLite, issue = "#1028",
   meaning = _ -> "the nearest integer (`1.5` → `2`)",
   computes = _ -> "the truncated one (`1`)",
   fix = (_, _) -> "Say how to round it: \e[32mCast(Round(x), IntegerField())\e[0m, \e[32mFloor(x)\e[0m or \e[32mCeil(x)\e[0m."),
  # #1040: a cast to `numeric(p, s)` rounds to `s` places. SQLite reads the type name as NUMERIC
  # affinity and keeps every digit; text is parsed and rounded by PostgreSQL, kept by SQLite.
  (targets = (:scale,), kinds = (:float, :decimal, :numeric, :text), engine = PormGSQLite, issue = "#1040",
   meaning = declared -> "the value rounded to the scale of $(declared)",
   computes = _ -> "every digit of it",
   fix = (_, declared) -> "Round it to the scale first (\e[32mCast(Round(x, $(something(_numeric_cast_scale(declared), 0))), \"$(declared)\")\e[0m, #1061), or cast to an unscaled \e[32m\"numeric\"\e[0m, which keeps the value."),
  # #1087: a literal the declared type cannot hold overflows: the cast is an error. SQLite stores it as it is,
  # a silent different answer (the tie-breaker: an error on one engine is left to raise when the
  # engines that answer give the meaning; SQLite does not).
  (targets = (:precision,), kinds = (:overflow,), engine = PormGSQLite, issue = "#1087",
   meaning = declared -> "a numeric field overflow, since $(declared) cannot hold it",
   computes = _ -> "the value as it is",
   fix = (_, declared) -> "Declare a precision that holds it (\e[32mCast(x, \"numeric(p, $(something(_numeric_cast_scale(declared), 0)))\")\e[0m with a larger p), or cast to an unscaled \e[32m\"numeric\"\e[0m."),
  # #1111: an integer quotient — a `Floor`/`Ceil`/`Abs` over a whole number PormG does not type, which
  # `Dialect` renders over `(x)::numeric`, or a `sum(bigint)` the walk cannot name — is a `numeric` on
  # PostgreSQL, which keeps the half.
  (targets = (:text, :integer, :scale, :concat), kinds = (:numeric_whole_division,), engine = PormGPostgres, issue = "#1111",
   meaning = _ -> "an integer quotient (`15 / 2` is `7`)",
   computes = _ -> "a `numeric` one (`7.5`)",
   fix = (_, _) -> "Say which division you mean: cast the dividend to an integer first, \e[32mCast(x, BigIntegerField()) / 2\e[0m, which divides as integers on every engine, or divide by a float, \e[32mx / 2.0\e[0m, to keep the fraction."),
  # #1087: a `DecimalField` (any scale), or a declared decimal over an integer, divided is a decimal
  # quotient. SQLite stores a whole decimal value as INTEGER and divides it as an integer.
  (targets = (:text, :integer, :scale), kinds = (:decimal_whole_division,), engine = PormGSQLite, issue = "#1087",
   meaning = _ -> "a decimal quotient (`15 / 2` is `7.5`)",
   computes = _ -> "an integer one (`7`), since it stores a whole decimal as an integer",
   fix = (_, _) -> "Divide by a float to keep the fraction on every engine (\e[32mx / 2.0\e[0m), or fetch the number and divide it in Julia."),
  # #1147 step 2: a value that is one of several, some whole and some fractional (`Coalesce("grid",
  # 0.5)`, a `Case` with an integer and a float branch, a `Lag`/`Lead` with a fractional `default`) is
  # a float or a `numeric` to PostgreSQL, so its quotient keeps the fraction; SQLite returns each
  # row's own value, an integer on the rows the whole one supplies, and divides those as integers.
  (targets = (:text, :integer, :scale), kinds = (:mixed_whole_division,), engine = PormGSQLite, issue = "#1147",
   meaning = _ -> "a quotient with its fraction (`15 / 2` is `7.5`), since one of its values has a fraction",
   computes = _ -> "an integer one (`7`) on every row that holds an integer",
   fix = (_, _) -> "Divide by a float to keep the fraction on every engine (\e[32mx / 2.0\e[0m), or make every value a whole number."),
)

"""
    _departure(conn, target, kind) -> Union{NamedTuple, Nothing}

The `_MEANING_DEPARTURES` row by which `conn`'s engine departs from what `target` over an operand of
`kind` means, or `nothing` when it keeps the meaning (and the expression builds).
"""
function _departure(conn, target::Symbol, kind::Symbol)
  for row in _MEANING_DEPARTURES
    target in row.targets && kind in row.kinds && conn isa row.engine && return row
  end
  return nothing
end

# Whether some engine departs for `(target, kind)`: a `Concat` operand of such a kind is a meaning
# question, refused only where it departs; any other kind is explicit intent, refused everywhere.
_meaning_kind(target::Symbol, kind::Symbol) =
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
