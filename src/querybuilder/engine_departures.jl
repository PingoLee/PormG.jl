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
# (a declared cast to one), `:number` (a cast to any number type, #1259, #1260; to a float or a `numeric`, #1319), `:date` (a cast to a date, #1325, #1417), `:scale` (`numeric(p, s)`), `:precision` (a literal `numeric(p, s)` cannot
# hold), `:single_precision` (`real`, #1215), `:sized_text` (a text type of a declared length, #1252), `:concat` (a `Concat` operand) and `:division` (a side of `/`, #1471). `kinds` are the
# operand classes the classifiers in `projection_types.jl` name. `meaning`, `computes` and `fix` take the declared type, and `fix` also
# the operand's flag, the path a suggestion can name. `computes` is per departing engine (`Backend =>
# text`), since two engines can depart from one meaning with different values; `_computes` picks the
# one for the engine at hand, and `test_meaning_departures.jl` fails on a `departs` engine without one.
const _MEANING_DEPARTURES = (
  # #1028: a boolean's text is the word. SQLite has no boolean and stores 1 / 0; MySQL's is a
  # `TINYINT(1)`, and a comparison is an integer there too (measured on 8.4: `CAST(TRUE AS CHAR)` is `'1'`).
  (targets = (:text,), kinds = (:bool,), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1028",
   meaning = _ -> "its text, `true` or `false`",
   computes = (PormGSQLite => _ -> "`1` or `0`, the integer it stores",
               PormGMySQL => _ -> "`1` or `0`, the integer it stores"),
   fix = (flag, _) -> "Write the text you mean: \e[32mCase(When(\"$(flag)\" => true, then = Value(\"true\")), default = \"false\")\e[0m."),
  # #1028: a fractional number cast to an integer is the nearest one; SQLite's cast truncates. MySQL's
  # `CAST(… AS SIGNED)` rounds (measured: `1.5` → `2`, `-1.5` → `-2`; a double's tie to even, `2.5E0` →
  # `2`, as PostgreSQL's `float8`), so it keeps the meaning.
  # D5 (#1034): a zero-scale cast over a value that is not an integer is that value on SQLite, which
  # does not round it (`:zero_scale_decimal`), so the same truncation reaches it there.
  (targets = (:integer,), kinds = (:float, :decimal, :numeric, :zero_scale_decimal), departs = (PormGSQLite,), keeps = (PormGPostgres, PormGMySQL), issue = "#1028",
   meaning = _ -> "the nearest integer (`1.5` → `2`)",
   computes = (PormGSQLite => _ -> "the truncated one (`1`)",),
   fix = (_, _) -> "Say how to round it: \e[32mCast(Round(x), IntegerField())\e[0m, \e[32mFloor(x)\e[0m or \e[32mCeil(x)\e[0m."),
  # #1259: an interval is no number, so its cast to an integer, a float or a `numeric` is an error (the
  # tie-breaker: an error on one engine is left to raise when the engines that answer give the
  # meaning). SQLite casts the stored `HH:MM:SS.sss` text and reads its leading digits, the hours: a
  # silent different answer. MySQL stores a `DurationField` as its microseconds (#1130), a BIGINT, and
  # an interval PormG computes there is the same count, so its cast is that count, where the meaning is
  # an error.
  (targets = (:integer, :number), kinds = (:interval,), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1259",
   meaning = _ -> "an error, since an interval has no numeric value",
   computes = (PormGSQLite => _ -> "the leading digits of its `HH:MM:SS` text, the hours",
               PormGMySQL => _ -> "a number it does not mean: the duration's count of microseconds, which is how MySQL stores it"),
   fix = (flag, _) -> "Fetch the duration and take the number you mean in Julia, or ask for its text, \e[32mCast(\"$(flag)\", \"text\")\e[0m, which each engine writes in its own form."),
  # #1260: a date, a timestamp or a time is no number either, so its cast is an error by the same
  # tie-breaker. SQLite casts the stored text (`2009-03-29`, `2009-03-29T06:00:00.000+00:00`,
  # `06:00:00`) and reads its leading digits: the year, or a time's hour. A part names the number.
  # MySQL casts a temporal value to the number its digits spell (measured: `DATE '2009-03-29'` →
  # `20090329`, a `DATETIME` → `20090329060000`, `TIME '06:00:00'` → `60000`).
  (targets = (:integer, :number), kinds = (:date, :timestamp), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1260",
   meaning = _ -> "an error, since a date or a timestamp has no numeric value",
   computes = (PormGSQLite => _ -> "the leading digits of its text, the year",
               PormGMySQL => _ -> "its digits read as one number (`2009-03-29` → `20090329`)"),
   fix = (flag, _) -> "Name the number you mean with a part: its year, $(_temporal_part_spelling(flag, "year")), or another part \e[32mExtract\e[0m names."),
  (targets = (:integer, :number), kinds = (:time,), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1260",
   meaning = _ -> "an error, since a time has no numeric value",
   computes = (PormGSQLite => _ -> "the leading digits of its `HH:MM:SS` text, the hour",
               PormGMySQL => _ -> "its digits read as one number (`06:00:00` → `60000`)"),
   fix = (flag, _) -> "Name the number you mean with a part: its hour, $(_temporal_part_spelling(flag, "hour")), or another part \e[32mExtract\e[0m names."),
  # #1319: a boolean is a number only as the integer `1` or `0`, which every engine casts alike
  # (PostgreSQL has `boolean::integer`), so that cast has no row. Its cast to a float or a `numeric`
  # is an error by the #1259 tie-breaker: PostgreSQL has no such cast. SQLite stores a boolean as
  # `1` / `0` and casts that integer (measured on 3.45.1: `CAST(1 AS FLOAT8)` is `1.0`, `CAST(1 AS
  # NUMERIC)` stays `1`); MySQL's is a `TINYINT(1)`, cast as the integer (`1`).
  (targets = (:number,), kinds = (:bool,), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1319",
   meaning = _ -> "an error, since a boolean is a number only as the integer `1` or `0`",
   computes = (PormGSQLite => _ -> "the integer it stores, `1` or `0` (`1.0` as a float)",
               PormGMySQL => _ -> "`1` or `0`, the integer it stores"),
   fix = (flag, declared) -> "Cast it to the integer first, which every engine computes alike: \e[32mCast(Cast(\"$(flag)\", IntegerField()), \"$(something(declared, "float8"))\")\e[0m, or say the values: \e[32mCase([When(\"$(flag)\" => true, then = Value(1.0)), When(\"$(flag)\" => false, then = Value(0.0))])\e[0m."),
  # #1325: a duration and a time of day have no calendar date, so their cast to a date is an error:
  # PostgreSQL has no `interval::date` and no `time::date`. SQLite's `date()` reads the stored
  # `HH:MM:SS` text as a time on 2000-01-01 (measured on 3.45.1: `date('01:23:45')` is `2000-01-01`,
  # `date('24:00:00')` `2000-01-02`, `date('25:00:00')` NULL). MySQL holds a duration as its count of
  # microseconds, whose digits its cast reads as a date, and gives a time today's date.
  (targets = (:date,), kinds = (:interval,), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1325",
   meaning = _ -> "an error, since a duration has no calendar date",
   computes = (PormGSQLite => _ -> "a day in January 2000, its `HH:MM:SS` text read as a time on `2000-01-01`, or NULL past 24 hours",
               PormGMySQL => _ -> "the digits of its count of microseconds, which is how MySQL stores it, read as a date"),
   fix = (flag, _) -> "A duration places a date only from another one: add it to a date, \e[32mF(\"date\") + F(\"$(flag)\")\e[0m."),
  (targets = (:date,), kinds = (:time,), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1325",
   meaning = _ -> "an error, since a time of day has no date",
   computes = (PormGSQLite => _ -> "`2000-01-01`, the date it gives a time of day",
               PormGMySQL => _ -> "today's date, which changes every day"),
   fix = (_, _) -> "Take the date from a date or a timestamp column, or project the time itself."),
  # #1417: a number has no date either, so its cast to one is an error: PostgreSQL has no
  # `integer::date`, `float8::date` or `numeric::date`. SQLite's `date()` reads a number as a Julian
  # day (measured on 3.54.0: `date(5)` is `-4713-11-29`, `date(5.5)` `-4713-11-30`, `date(2455000)`
  # `2009-06-17`, `date(20090329)` NULL). MySQL reads the digits as a date, `YYYYMMDD` or `YYMMDD`,
  # and NULL where they spell none: its documented number-to-date rule, not measured here (no 8.4
  # server reachable when this row was written). Each answers silently, so both depart.
  (targets = (:date,), kinds = (:integer, :float, :decimal), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1417",
   meaning = _ -> "an error, since a number has no calendar date",
   computes = (PormGSQLite => _ -> "the Julian day it counts (`5` is `-4713-11-29`)",
               PormGMySQL => _ -> "the date its digits spell (`20090329` is `2009-03-29`), or NULL"),
   fix = (_, _) -> "A number places a date only from another one: add days to a date, \e[32mF(\"date\") + Day(1)\e[0m, or build the Date in Julia and bind it."),
  # #1040: a cast to `numeric(p, s)` rounds to `s` places. SQLite reads the type name as NUMERIC
  # affinity and keeps every digit; text is parsed and rounded by PostgreSQL, kept by SQLite. MySQL's
  # `DECIMAL(p, s)` rounds a decimal, a double and text alike (measured: `1.235` → `1.24`).
  # D5 (#1034): so is a zero-scale cast SQLite did not round (`:zero_scale_decimal`), wherever the walk
  # does not carry its scale (a `Subquery`'s record).
  (targets = (:scale,), kinds = (:float, :decimal, :numeric, :text, :zero_scale_decimal), departs = (PormGSQLite,), keeps = (PormGPostgres, PormGMySQL), issue = "#1040",
   meaning = declared -> "the value rounded to the scale of $(declared)",
   computes = (PormGSQLite => _ -> "every digit of it",),
   fix = (_, declared) -> "Round it to the scale first (\e[32mCast(Round(x, $(something(_numeric_cast_scale(declared), 0))), \"$(declared)\")\e[0m, #1061), or cast to an unscaled \e[32m\"numeric\"\e[0m, which keeps the value."),
  # #1087: a literal the declared type cannot hold overflows: the cast is an error. SQLite stores it as it is,
  # a silent different answer (the tie-breaker: an error on one engine is left to raise when the
  # engines that answer give the meaning; SQLite does not). Nor does MySQL: in a `SELECT` its own
  # `DECIMAL(p, s)` clamps the value to the largest the type holds, with only a warning (measured:
  # `CAST(123456 AS DECIMAL(4,2))` is `99.99`, warning 1264), so PormG computes the cast at
  # `DECIMAL(65, s)` (#1110), and there the value is what it is wherever the cast is not read back.
  (targets = (:precision,), kinds = (:overflow,), departs = (PormGSQLite, PormGMySQL), keeps = (PormGPostgres,), issue = "#1087",
   meaning = declared -> "a numeric field overflow, since $(declared) cannot hold it",
   computes = (PormGSQLite => _ -> "the value as it is",
               PormGMySQL => _ -> "the value as it is wherever the cast is not read back"),
   fix = (_, declared) -> "Declare a precision that holds it (\e[32mCast(x, \"numeric(p, $(something(_numeric_cast_scale(declared), 0)))\")\e[0m with a larger p), or cast to an unscaled \e[32m\"numeric\"\e[0m."),
  # #1215: a single-precision float (`real`, `float4`, `float(p)` for p ≤ 24) is the value rounded to a
  # 4-byte float, which reads back as a `Float32`. SQLite has no 4-byte REAL: its cast keeps the
  # 8-byte double, so `0.1` stays `0.1` where single precision holds `0.10000000149011612`. The
  # operand does not decide it, so the one kind is `:value`, any operand. MySQL's `CAST(… AS FLOAT)` is
  # single precision and reads back as a `Float32` (measured), so it keeps the meaning.
  (targets = (:single_precision,), kinds = (:value,), departs = (PormGSQLite,), keeps = (PormGPostgres, PormGMySQL), issue = "#1215",
   meaning = _ -> "the value rounded to single precision, a `Float32`",
   computes = (PormGSQLite => _ -> "the 8-byte double, every digit of it",),
   fix = (_, _) -> "Cast to a double, which is a `Float64` on every engine: \e[32mCast(x, \"float8\")\e[0m or \e[32mCast(x, FloatField())\e[0m."),
  # #1252: a declared length (`varchar(n)`, `char(n)`, a `CharField(max_length = n)`) is the text cut
  # to n characters. PostgreSQL's cast cuts it and so does MySQL's `CHAR(n)`; SQLite enforces no length,
  # so its cast keeps every character. The operand does not decide it, so the one kind is `:value`.
  (targets = (:sized_text,), kinds = (:value,), departs = (PormGSQLite,), keeps = (PormGPostgres, PormGMySQL), issue = "#1252",
   meaning = declared -> "the text cut to $(something(_sized_text_length(declared), 0)) characters",
   computes = (PormGSQLite => _ -> "every character of it, since it enforces no length",),
   fix = (_, _) -> "Cast to text of no declared length, \e[32mCast(x, \"text\")\e[0m or \e[32mCast(x, CharField())\e[0m, and cut the fetched value in Julia (\e[32mfirst(s, n)\e[0m)."),
  # #1471: a JSON number has no integer type, so its quotient keeps the fraction. SQLite's
  # `json_extract` hands over the integer the document holds, and `FLOOR`, `ABS`, `SUM`, `MAX` keep
  # it, so `/` divides as integers there (measured on 3.54.0: `{"n": 7}` gives `3`). PostgreSQL
  # computes the fraction where it builds (`FLOOR((x)::numeric) / 2` is `3.5`), and raises at the
  # server where it reads the key as text (`#>>` over `+` or `SUM`), an error the tie-breaker leaves
  # to raise. MySQL's `/` keeps the fraction (it refuses a side PormG cannot type before this row
  # is read, #1130). The operand decides nothing beyond holding a key, so the one kind is `:json_number`.
  (targets = (:division,), kinds = (:json_number,), departs = (PormGSQLite,), keeps = (PormGPostgres, PormGMySQL), issue = "#1471",
   meaning = _ -> "one that keeps its fraction, since a JSON number has no integer type",
   computes = (PormGSQLite => _ -> "an integer quotient when the key holds a whole number (`7 / 2` is `3`)",),
   fix = (flag, _) -> "Say the number type you mean: \e[32mCast(\"$(flag)\", \"numeric\")\e[0m keeps the fraction on every engine, and \e[32mCast(\"$(flag)\", BigIntegerField())\e[0m divides as integers."),
  # D5 (#1034): a zero-scale cast (`numeric(p,0)`) is a whole number, and its text is the integer's:
  # PostgreSQL and MySQL round the value and write `15`, or `14` for a whole float (measured on 18.6 and
  # 8.4). SQLite's cast to NUMERIC keeps a REAL as it is, so it writes `14.0` (measured on 3.54.0); over
  # an integer it writes `14` too, and the classifier names no kind there (`_zero_scale_cast_textless`).
  (targets = (:concat,), kinds = (:zero_scale_decimal,), departs = (PormGSQLite,), keeps = (PormGPostgres, PormGMySQL), issue = "#1034",
   meaning = _ -> "the whole number it rounds to, written as an integer (`14`)",
   computes = (PormGSQLite => _ -> "the operand's own text, since its cast to NUMERIC keeps a REAL as it is (`14.0`)",),
   fix = (_, _) -> "Cast it to an integer, which writes `14` on every engine: \e[32mCast(x, IntegerField())\e[0m over the zero-scale cast."),
)

# #1260 — the spelling of a temporal part for the operand a refusal names: a path takes the transform
# or `Extract` over it; any other operand (`Max("born")`, a `Case`, a literal) only `Extract`, since a
# transform applies to a path.
_temporal_part_spelling(flag::AbstractString, part::AbstractString) =
  flag == "<flag>" ? "\e[32mExtract(x, \"$(part)\")\e[0m" :
  "\e[32m\"$(flag)__@$(part)\"\e[0m or \e[32mExtract(\"$(flag)\", \"$(part)\")\e[0m"

# #1111 — an integer quotient over a `Sum` the type walk cannot name (`_DIVISION_KINDS`, classified by
# `_whole_numeric_operand`). Not a row of the table above: which engine departs is not a fixed type
# but an engine fact, `_untyped_sum_departs` (#1034 phase 3 step 2a), so a backend that has not decided
# it gets a `MethodError` rather than the meaning by default (#1170). This holds the message only.
const _INTEGER_QUOTIENT_DEPARTURE = (
  targets = (:text, :integer, :scale, :concat), issue = "#1111",
  meaning = _ -> "an integer quotient (`15 / 2` is `7`) when the sum is whole",
  computes = (PormGPostgres => _ -> "a `numeric` one (`7.5`) for a `bigint` or `numeric` sum",
              PormGMySQL => _ -> "a `DECIMAL` one (`7.5`), since its `SUM` is one"),
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
    "$(_computes(row, conn)(declared)), so PormG refuses it on $(engine) ($(row.issue)). $(row.fix(flag, declared))")
end

# What `conn`'s engine computes instead, from the row's per-engine `computes` pairs. Asked only of an
# engine the row departs on, so a missing pair is a row written wrong, which the departure test catches.
_computes(row, conn) = last(row.computes[findfirst(p -> conn isa first(p), row.computes)])
