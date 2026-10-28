"""
`update` writes a `Joined(…)` column, a `Subquery(…)` and a `Value(…)` into any field, number fields
included, and its type checks read them as they read an `F` expression (#1320).

Before #1320, step 4 of `_validate_field_value` let only an `F` expression or a SQL function through
under `update`; everything else reached step 5's literal checks. So:

- `update("grid" => Joined("d", "driverid"))` raised `InvalidValueError` ("expected Int64, … got
  JoinedReference") into a number field, where the same handle into a text field built;
- a bare `Subquery(…)` and a `Value(x)` were refused into every field, text included: the SET loop had
  no arm for either and bound them through the field's formatter.

Now a `Joined` column and a `Subquery` render as SQL in SET, past the literal checks and into the
write path's own: #1297's refusal of a non-number into a number field and #1279's scale guard. A
`Value(x)` wraps a literal, so `update` writes `x`: the same checks, formatter and bind as
`update(field => x)`. The other writers still refuse a `Joined` column and a `Subquery` (#1283).

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_update_set_expressions.jl
"""

using Test
using Dates
using DataFrames
using PormG
using PormG.Models
import PormG: QueryBuildError, InvalidValueError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct UseMockSQLite <: PormG.PormGSQLite end
struct UseMockPostgres <: PormG.PormGPostgres end
struct UseMockMySQL <: PormG.PormGMySQL end
const _USE_SL = UseMockSQLite()
const _USE_PG = UseMockPostgres()
const _USE_MY = UseMockMySQL()
PormG.backend_sqlite_version(::UseMockSQLite) = 3045000
const _USE_ENGINES = ((_USE_PG, "PostgreSQL"), (_USE_SL, "SQLite"), (_USE_MY, "MySQL"))

PormG.config["use_mock"] = PormG.Configuration.Settings(
  connections = _USE_SL, change_data = true, db_def_folder = "use_mock",
)

# The F1 driver and result, with a column of each type under test.
module UseModels
import PormG
import PormG.Models

Use_driver = Models.Model("use_driver",
  driverid = Models.IDField(),
  code     = Models.CharField(null = true),
  number   = Models.IntegerField(null = true),
  token    = Models.UUIDField(null = true),
  dob      = Models.DateField(null = true),
  height   = Models.DecimalField(max_digits = 10, decimal_places = 3, null = true),
)
Use_result = Models.Model("use_result",
  resultid     = Models.IDField(),
  driverid     = Models.ForeignKey(Use_driver, on_delete = "CASCADE", null = true),
  grid         = Models.IntegerField(null = true),
  points       = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  positiontext = Models.CharField(null = true),
  racedate     = Models.DateField(null = true),
)

PormG.Models.set_models(@__MODULE__, "use_mock")
end

const USE = UseModels
const _UseFn = PormG.Functions
# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _UF = PormG.QueryBuilder.F
const _UJoined = PormG.QueryBuilder.Joined
const _USubquery = PormG.QueryBuilder.Subquery
const _UOuterRef = PormG.QueryBuilder.OuterRef

# The statement `update` builds for `pairs`, on `conn`, filtered by `filters`; `joined` adds the
# `cjoin_on` copy of the driver as "d".
function _use_update(pairs::Pair...; conn, joined::Bool = false, filters = ("resultid" => 1,))
  q = USE.Use_result.objects
  q.filter(filters...)
  joined && q.cjoin_on("Use_driver", alias = "d", on = [_UJoined("d", "driverid") == _UF("driverid")])
  for (k, v) in pairs
    q.object.insert[k] = v
  end
  res = PormG.QueryBuilder.update(q.object; connection = conn, show_query = :dict)
  return replace(res[:sql_text], r"\s+" => " ") |> strip, res[:parameters]
end
_use_refusal(f) = try f(); nothing catch e; e end
_use_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# The driver's `col`, for the result's driver whose code is "HAM": one value per row.
function _use_subquery(col::String)
  s = USE.Use_driver.objects
  s.filter("driverid" => _UOuterRef("driverid"), "code" => "HAM")
  s.values(col)
  s.limit(1)
  return _USubquery(s)
end

# The engine's identifier quote and its parameter marker for the `n`th bind (PostgreSQL numbers).
_use_q(conn, s) = conn === _USE_MY ? "`$(s)`" : "\"$(s)\""
_use_p(conn, n) = conn === _USE_PG ? "\$$(n)" : "?"

@testset "update: a joined number column into a number field builds (#1320)" begin
  # What: `cjoin_on("Use_driver", alias = "d", …)` + `update("grid" => Joined("d", "driverid"))`
  # builds `SET "grid" = "d"."driverid"` through UPDATE … FROM on PostgreSQL and SQLite, and through
  # MySQL's multi-table UPDATE. Why: step 4 let only an `F` expression or a function through, so the
  # number field's literal check refused the handle ("expected Int64, … got JoinedReference"), while
  # the same handle into a text field built.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      sql, params = _use_update("grid" => _UJoined("d", "driverid"); conn = conn, joined = true)
      if conn === _USE_MY
        @test sql == "UPDATE `use_result` AS `Tb`, `use_driver` AS `d` SET `Tb`.`grid` = `d`.`driverid` " *
                     "WHERE (`d`.`driverid` = `Tb`.`driverid`) AND `Tb`.`resultid` = ?"
      else
        @test sql == "UPDATE \"use_result\" AS \"Tb\" SET \"grid\" = \"d\".\"driverid\" FROM \"use_driver\" AS \"d\" " *
                     "WHERE (\"d\".\"driverid\" = \"Tb\".\"driverid\") AND \"Tb\".\"resultid\" = $(_use_p(conn, 1))"
      end
      @test params == [1]
      # The same column into a DecimalField with more places than it: integer, so no scale departs.
      sql, _ = _use_update("points" => _UJoined("d", "number"); conn = conn, joined = true)
      @test occursin("$(_use_q(conn, "d")).$(_use_q(conn, "number"))", sql)
    end
  end
end

@testset "update: a Subquery into any field builds, its values bound in SET (#1320)" begin
  # What: `update("grid" => Subquery(<driver number>))` builds
  # `SET "grid" = (SELECT "R1"."number" … WHERE "R1"."driverid" = "Tb"."driverid" AND "R1"."code" = ? LIMIT ?)`
  # on every engine, with the subquery's values bound ahead of the WHERE's: `["HAM", 1, 1]` in text
  # order on SQLite and MySQL, `$2` for "HAM" and `$3` for the limit on PostgreSQL. A text column into `positiontext` builds the
  # same way. Why: a bare `Subquery` had no SET arm and reached the literal checks, refused into
  # every field; a misplaced bind here would be silent wrong data on the engines that bind by position.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      Q(s) = _use_q(conn, s)
      for (field, col) in (("grid", "number"), ("positiontext", "code"))
        sql, params = _use_update(field => _use_subquery(col); conn = conn)
        hit, lim = conn === _USE_PG ? ("\$2", "\$3") : ("?", "?")
        @test occursin("SET $(Q(field)) = (SELECT $(Q("R1")).$(Q(col)) as $(Q(col)) FROM $(Q("use_driver")) as $(Q("R1")) " *
                       "WHERE $(Q("R1")).$(Q("driverid")) = $(Q("Tb")).$(Q("driverid")) AND $(Q("R1")).$(Q("code")) = $(hit) LIMIT $(lim)", sql)
        @test endswith(sql, "WHERE $(Q("Tb")).$(Q("resultid")) = $(_use_p(conn, 1))")
        @test params == (conn === _USE_PG ? Any[1, "HAM", 1] : Any["HAM", 1, 1])
      end
    end
  end
end

@testset "update: a Subquery beside literals and an outer joined filter binds in text order (#1320)" begin
  # What: `update("points" => 5, "grid" => Subquery(…), "positiontext" => Value("x"))` filtered by
  # `driverid__code` (an outer join) binds `[5, "HAM", 1, "x", <WHERE values>]` in text order on SQLite
  # and MySQL, and on PostgreSQL every `$N` names the value at its place. The subquery's own "R1" is
  # not the outer join's alias ("Tb_1"), so the statement keeps the key-selection shape. Why: the
  # subquery's values join the `:update` bucket mid-SET; one out of place is a positional misbind.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      sql, params = _use_update("points" => 5, "grid" => _use_subquery("number"),
                                "positiontext" => _UseFn.Value("x");
                                conn = conn, filters = ("resultid" => 1, "driverid__code" => "VER"))
      @test occursin("IN (SELECT", sql)
      @test !occursin("FROM $(_use_q(conn, "use_driver")) AS", sql)   # no UPDATE … FROM
      in_text_order = conn === _USE_PG ?
        [params[parse(Int, m.captures[1])] for m in eachmatch(r"\$(\d+)", sql)] : params
      @test in_text_order == Any[5, "HAM", 1, "x", 1, "VER", 1, "VER"]
      conn === _USE_PG || @test count("?", sql) == length(params)
    end
  end
end

@testset "update: a Subquery beside a joined column binds in text order through UPDATE … FROM (#1320)" begin
  # What: `update("points" => 7, "grid" => Subquery(…), "positiontext" => Joined("d", "code"))` on a
  # `cjoin_on` whose ON clause binds "VER" builds UPDATE … FROM (MySQL: the multi-table UPDATE) and
  # binds `[7, "HAM", 1, "VER", 1]` in text order: SET, then the ON clause, then the filter. Why: the
  # ON clause renders once in `build()` and is placed after SET, so the subquery's values must land
  # between them; one out of place is a positional misbind on SQLite and MySQL.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      q = USE.Use_result.objects
      q.filter("resultid" => 1)
      q.cjoin_on("Use_driver", alias = "d",
                 on = [_UJoined("d", "driverid") == _UF("driverid"), _UJoined("d", "code") => "VER"])
      for (k, v) in ("points" => 7, "grid" => _use_subquery("number"), "positiontext" => _UJoined("d", "code"))
        q.object.insert[k] = v
      end
      res = PormG.QueryBuilder.update(q.object; connection = conn, show_query = :dict)
      sql, params = res[:sql_text], res[:parameters]
      @test occursin(conn === _USE_MY ? "`use_driver` AS `d`" : "FROM \"use_driver\" AS \"d\"", sql)
      in_text_order = conn === _USE_PG ?
        [params[parse(Int, m.captures[1])] for m in eachmatch(r"\$(\d+)", sql)] : params
      @test in_text_order == Any[7, "HAM", 1, "VER", 1]
      conn === _USE_PG || @test count("?", sql) == length(params)
    end
  end
end

@testset "update: on MySQL a Subquery reading a column the same SET writes earlier is refused (#1320)" begin
  # What: `update("driverid" => 5, "grid" => Subquery(<OuterRef("driverid")>))` raises MySQL's
  # SET-order `QueryBuildError` and builds on PostgreSQL and SQLite; in the other order it builds on
  # all three. Why: MySQL assigns SET items in order, so the subquery would read the new `driverid`
  # where the update means the row as it was (#1130); a bare Subquery reaches that check now.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      err = _use_refusal(() -> _use_update("driverid" => 5, "grid" => _use_subquery("number"); conn = conn))
      if conn === _USE_MY
        @test err isa QueryBuildError
        @test occursin("update(\"grid\" => …) reads `driverid`, which the same update() also writes", _use_msg(err))
      else
        @test err === nothing
      end
      @test _use_refusal(() -> _use_update("grid" => _use_subquery("number"), "driverid" => 5; conn = conn)) === nothing
    end
  end
end

@testset "update: a Value around an expression is refused, not written as SQL (#1320)" begin
  # What: `Value(F("grid"))`, `Value(Subquery(…))` and `Value(Coalesce("driverid__dob__@year", 0))`
  # into `grid` raise `InvalidValueError` of kind `:type`, naming the wrapped type, through the
  # fluent `update` on every engine. Why: `Value` wraps a literal; unwrapped, these rendered as SQL in
  # `update` only (a projection binds them), and the path inside the `Coalesce` was never walked, so
  # it failed with a misleading join error.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      for (inner, type) in ((_UF("grid"), "FExpression"), (_use_subquery("number"), "SubqueryObject"),
                            (_UseFn.Coalesce("driverid__dob__@year", 0), "FObject"))
        err = _use_refusal(() -> _use_update("grid" => _UseFn.Value(inner); conn = conn))
        @test err isa InvalidValueError
        err isa InvalidValueError && @test err.kind === :type
        @test occursin("Value(…) wraps a literal, and this one wraps an expression ($(type))", _use_msg(err))
      end
    end
  end
  q = USE.Use_result.objects
  q.filter("resultid" => 1)
  err = _use_refusal(() -> q.update("grid" => _UseFn.Value(_UseFn.Coalesce("driverid__dob__@year", 0)); show_query = :sql))
  @test err isa InvalidValueError
  # The field's own checks come first, as for a bare expression: an unknown name is an
  # `UnknownFieldError` (#462), and a primary key is refused as one.
  @test _use_refusal(() -> _use_update("nope" => _UseFn.Value(_UF("grid")); conn = _USE_SL)) isa PormG.UnknownFieldError
  pk = _use_refusal(() -> _use_update("resultid" => _UseFn.Value(_UF("grid")); conn = _USE_SL))
  @test pk isa InvalidValueError
  @test occursin("primary keys cannot be modified", _use_msg(pk))
end

@testset "update: Value(x) writes x, exactly as the bare literal (#1320)" begin
  # What: `update(field => Value(x))` builds the same SQL and binds the same value as
  # `update(field => x)` — `SET "grid" = ?` with 3, a DecimalField, a text, a date (bound as its
  # canonical text "2021-03-28") and `Value(nothing)` as NULL — on every engine. Why: `Value` was
  # refused into every field, and `Value` wraps a literal, so `update` writes the literal: rendered as
  # SQL, `Value("abc")` or `Value(3.7)` into an IntegerField would reach the column past every check.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      for (field, x) in (("grid", 3), ("points", 3), ("positiontext", "P1"),
                         ("racedate", Date(2021, 3, 28)), ("grid", nothing))
        wrapped = _use_update(field => _UseFn.Value(x); conn = conn)
        @test isequal(wrapped, _use_update(field => x; conn = conn))
        @test wrapped[1] == "UPDATE $(_use_q(conn, "use_result")) AS $(_use_q(conn, "Tb")) " *
                            "SET $(_use_q(conn, field)) = $(_use_p(conn, 2)) WHERE $(_use_q(conn, "Tb")).$(_use_q(conn, "resultid")) = $(_use_p(conn, 1))"
      end
      @test _use_update("racedate" => _UseFn.Value(Date(2021, 3, 28)); conn = conn)[2] ==
            (conn === _USE_PG ? Any[1, "2021-03-28"] : Any["2021-03-28", 1])
    end
  end
end

@testset "update: Value(x) is checked as x is (#1320)" begin
  # What: `Value(Date(…))`, `Value("abc")` and `Value(3.7)` into the IntegerField `grid` raise the
  # same `InvalidValueError` as the bare literal, with the same message, on every engine. Why: the
  # literal checks are what keep a date, text or fraction out of an integer column; SQLite would
  # store any of them as given.
  for (conn, engine) in _USE_ENGINES, x in (Date(2021, 3, 28), "abc", 3.7)
    @testset "$engine $(typeof(x))" begin
      wrapped = _use_refusal(() -> _use_update("grid" => _UseFn.Value(x); conn = conn))
      bare = _use_refusal(() -> _use_update("grid" => x; conn = conn))
      @test wrapped isa InvalidValueError
      @test bare isa InvalidValueError
      @test _use_msg(wrapped) == _use_msg(bare)
    end
  end
end

@testset "update: a non-number Joined column or Subquery into a number field is #1297's refusal (#1320)" begin
  # What: `Joined("d", "token")` (a UUID), `Joined("d", "dob")` (a date) and a `Subquery` over the
  # driver's token into `grid` raise `QueryBuildError` with #1297's text on every engine, never
  # `InvalidValueError`. Why: past the literal check these reach the SET branch, and a UUID or a date
  # is no number on any engine; SQLite would store its text in the INTEGER column, as it did for
  # `F("driverid__token")` before #1297.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      for (value, joined, named, what) in ((_UJoined("d", "token"), true, "`Joined(\"d\", \"token\")`", "a UUID"),
                                           (_UJoined("d", "dob"), true, "`Joined(\"d\", \"dob\")`", "a date"),
                                           (_use_subquery("token"), false, "the expression", "a UUID"))
        err = _use_refusal(() -> _use_update("grid" => value; conn = conn, joined = joined))
        @test err isa QueryBuildError
        @test !(err isa InvalidValueError)
        @test occursin("update(\"grid\" => …) writes $(named), which is $(what), into the IntegerField `grid`", _use_msg(err))
        @test occursin("(#1297)", _use_msg(err))
      end
    end
  end
end

@testset "update: a 3-place Joined column or Subquery into a 2-place DecimalField is #1279's (#1320)" begin
  # What: `Joined("d", "height")` and a `Subquery` over `height` (DecimalField(10, 3)) into `points`
  # (DecimalField(10, 2)) raise #1279's `QueryBuildError` on SQLite, which keeps every digit, and build
  # on PostgreSQL and MySQL, whose column rounds to the scale. Why: the scale guard reads the operand
  # in the SET branch, which these never reached before.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      for (value, joined) in ((_UJoined("d", "height"), true), (_use_subquery("height"), false))
        err = _use_refusal(() -> _use_update("points" => value; conn = conn, joined = joined))
        if conn === _USE_SL
          @test err isa QueryBuildError
          @test occursin("so PormG refuses it on SQLite (#1279)", _use_msg(err))
        else
          @test err === nothing
        end
      end
    end
  end
end

@testset "update: a CTE column into a number field reaches update's own refusal (#1320)" begin
  # What: `update("grid" => CTE("ev", "grid"))` on a query that declares `ev` raises update's
  # `QueryBuildError` that it emits no WITH clause (#433), not the literal check's
  # `InvalidValueError`. Why: the handle already took the SET branch into a text field; into a number
  # field the literal check refused it first, with a message about the value's type.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      q = USE.Use_result.objects
      q.with("ev" => USE.Use_result.objects.values("resultid", "grid"), join_field = "resultid" => "resultid")
      q.filter("resultid" => 1)
      q.object.insert["grid"] = PormG.QueryBuilder.CTE("ev", "grid")
      err = _use_refusal(() -> PormG.QueryBuilder.update(q.object; connection = conn, show_query = :sql))
      @test err isa QueryBuildError
      @test !(err isa InvalidValueError)
      err === nothing || @test occursin("emits no WITH clause — so the CTE would never be declared", _use_msg(err)) && occursin("(#433)", _use_msg(err))
    end
  end
end

@testset "create, validate_value, bulk_insert, bulk_update: still refuse a Joined column, a Subquery and a Value (#1320)" begin
  # What: `create(field => x)`, `validate_value` and a `bulk_insert`/`bulk_update` cell raise `InvalidValueError`
  # for each of the three into `grid` and `positiontext`; a `Joined` column and a `Subquery` with
  # #1283's text, naming the type. Why: only `update` writes an expression as SQL; the other writers
  # bind values, and a CharField's value check alone let the two handles through.
  for (field, value, noun, type) in (("grid", _UJoined("d", "number"), "a joined column", "JoinedReference"),
                                     ("positiontext", _UJoined("d", "code"), "a joined column", "JoinedReference"),
                                     ("grid", _use_subquery("number"), "a subquery", "SubqueryObject"),
                                     ("positiontext", _use_subquery("code"), "a subquery", "SubqueryObject"),
                                     ("grid", _UseFn.Value(3), nothing, nothing),
                                     ("positiontext", _UseFn.Value("x"), nothing, nothing))
    @testset "$field <= $(nameof(typeof(value)))" begin
      for (op, run) in (("insert", () -> USE.Use_result.objects.create(field => value; show_query = :params)),
                        ("validate_value", () -> PormG.validate_value(USE.Use_result, field, value)),
                        ("bulk_insert", () -> PormG.bulk_insert(USE.Use_result.objects,
                                                                DataFrame(:resultid => [1], Symbol(field) => Any[value]);
                                                                show_query = :params)),
                        ("bulk_update", () -> PormG.bulk_update(USE.Use_result.objects,
                                                                DataFrame(:resultid => [1], Symbol(field) => Any[value]);
                                                                columns = [field], match_on = ["resultid"], show_query = :params)))
        err = _use_refusal(run)
        @test err isa InvalidValueError
        if noun !== nothing && err !== nothing
          @test occursin("$(noun) ($(type)) is not a value: `update` writes one into the column as SQL, and $(op) takes values only", _use_msg(err))
        end
      end
    end
  end
end

# ── #1414: the statement shape follows the aliases SET reads, not an alias name in its text ──────────
const _UCase = PormG.QueryBuilder.Case
const _UWhen = PormG.QueryBuilder.When

# The `_use_update` statement with the driver's `cjoin_on` copy under `alias`, joined `join_type`.
function _use_update_aliased(pairs::Pair...; conn, alias::String, join_type::String = "LEFT")
  q = USE.Use_result.objects
  q.filter("resultid" => 1)
  q.cjoin_on("Use_driver", alias = alias, on = [_UJoined(alias, "driverid") == _UF("driverid")], join_type = join_type)
  for (k, v) in pairs
    q.object.insert[k] = v
  end
  res = PormG.QueryBuilder.update(q.object; connection = conn, show_query = :dict)
  return replace(res[:sql_text], r"\s+" => " ") |> strip, res[:parameters]
end

@testset "update: a cjoin_on alias named like a Subquery's own alias keeps the key-selection shape (#1414)" begin
  # What: a `cjoin_on` copy aliased "R1" — the name the SET `Subquery`'s own table renders under — beside
  # `update("grid" => Subquery(<driver number>))` builds exactly the statement alias "d" builds, with
  # "d" spelled "R1": `… WHERE "Tb"."resultid" IN (SELECT DISTINCT … JOIN "use_driver" AS "R1" …) AND
  # EXISTS (…)`, the same values, LEFT and INNER alike, on every engine. Why: the shape was chosen by
  # searching the SET text for `"R1".`, which the subquery's own columns matched. A LEFT copy was refused
  # (#174: UPDATE … FROM cannot carry a LEFT join), and an INNER one switched the statement to UPDATE …
  # FROM (MySQL: the multi-table UPDATE), decided by a name chosen for an unrelated reason. The wrapped
  # form `Coalesce(Subquery(…), 0)` is the one that reached it before #1320 admitted a bare Subquery.
  for (conn, engine) in _USE_ENGINES, join_type in ("LEFT", "INNER"), wrapped in (false, true)
    @testset "$engine $join_type$(wrapped ? " Coalesce" : "")" begin
      sub = wrapped ? _UseFn.Coalesce(_use_subquery("number"), 0) : _use_subquery("number")
      d_sql, d_params = _use_update_aliased("grid" => sub; conn = conn, alias = "d", join_type = join_type)
      r1_sql, r1_params = _use_update_aliased("grid" => sub; conn = conn, alias = "R1", join_type = join_type)
      @test occursin("IN (SELECT", d_sql)
      @test r1_sql == replace(d_sql, _use_q(conn, "d") => _use_q(conn, "R1"))
      @test r1_params == d_params
    end
  end
end

@testset "update: a Joined column of the aliased copy still takes UPDATE … FROM (#1414)" begin
  # What: `update("grid" => Joined("R1", "number"))` on an INNER copy aliased "R1" builds
  # `UPDATE "use_result" AS "Tb" SET "grid" = "R1"."number" FROM "use_driver" AS "R1" WHERE (…)` (MySQL:
  # `UPDATE … AS `Tb`, `use_driver` AS `R1``), and on a LEFT copy it is still #174's refusal. Why: the
  # SET does read that join here, so the statement must carry it; deciding from what SET reads must not
  # lose the case the text search got right.
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      sql, params = _use_update_aliased("grid" => _UJoined("R1", "number"); conn = conn, alias = "R1", join_type = "INNER")
      if conn === _USE_MY
        @test sql == "UPDATE `use_result` AS `Tb`, `use_driver` AS `R1` SET `Tb`.`grid` = `R1`.`number` " *
                     "WHERE (`R1`.`driverid` = `Tb`.`driverid`) AND `Tb`.`resultid` = ?"
      else
        @test sql == "UPDATE \"use_result\" AS \"Tb\" SET \"grid\" = \"R1\".\"number\" FROM \"use_driver\" AS \"R1\" " *
                     "WHERE (\"R1\".\"driverid\" = \"Tb\".\"driverid\") AND \"Tb\".\"resultid\" = $(_use_p(conn, 1))"
      end
      @test params == [1]
      err = _use_refusal(() -> _use_update_aliased("grid" => _UJoined("R1", "number"); conn = conn, alias = "R1"))
      @test err isa QueryBuildError
      err === nothing || @test occursin("cjoin_on alias \"R1\" is a LEFT join", _use_msg(err))
    end
  end
end

@testset "update: an OuterRef path inside a SET Subquery reads the outer join, so UPDATE … FROM (#1414)" begin
  # What: `update("grid" => Subquery(Driver.filter("code" => OuterRef("driverid__code"))…))` builds
  # UPDATE … FROM "use_driver" AS "Tb_1" (MySQL: the multi-table UPDATE), the subquery comparing
  # `"R1"."code" = "Tb_1"."code"`. Why: an `OuterRef` path joins the OUTER statement, so this SET reads a
  # join of the statement from inside the subquery. Skipping a subquery's contents would build the
  # key-selection shape and leave "Tb_1" out of scope; the reads are recorded on the instruction a
  # column resolves on, which for an `OuterRef` is the outer one. The second filter set joins "Tb_1" in
  # the WHERE first, so the `OuterRef` adds no join and only that record can say the SET reads it.
  for (conn, engine) in _USE_ENGINES, filters in (("resultid" => 1,), ("resultid" => 1, "driverid__code" => "HAM"))
    @testset "$engine $(length(filters)) filter(s)" begin
      Q(s) = _use_q(conn, s)
      s = USE.Use_driver.objects
      s.filter("code" => _UOuterRef("driverid__code"))
      s.values("number")
      s.limit(1)
      sql, params = _use_update("grid" => _USubquery(s); conn = conn, filters = filters)
      @test occursin("WHERE $(Q("R1")).$(Q("code")) = $(Q("Tb_1")).$(Q("code"))", sql)
      @test occursin(conn === _USE_MY ? "UPDATE `use_result` AS `Tb`, `use_driver` AS `Tb_1` SET" :
                                        "FROM \"use_driver\" AS \"Tb_1\" WHERE", sql)
      @test !occursin("IN (SELECT", sql)
      @test length(params) == length(filters) + 1
    end
  end
end

@testset "update: a When condition on a path the WHERE already rendered still reads its join (#1414)" begin
  # What: `filter("driverid__code" => "HAM").update("grid" => Case([When("driverid__code" => "HAM",
  # then = 1)], default = 0))` builds UPDATE … FROM "use_driver" AS "Tb_1" (MySQL: the multi-table
  # UPDATE), its CASE reading `"Tb_1"."code"`. Why: the WHERE memoized that path's column, and a reused
  # memo returns its text without rendering the column again, so its join would go unrecorded and the
  # key-selection shape would leave "Tb_1" out of scope. SET renders it afresh, as an ON clause does (#985).
  for (conn, engine) in _USE_ENGINES
    @testset "$engine" begin
      Q(s) = _use_q(conn, s)
      sql, params = _use_update("grid" => _UCase([_UWhen("driverid__code" => "HAM", then = 1)], default = 0);
                                conn = conn, filters = ("driverid__code" => "HAM",))
      @test occursin("CASE WHEN $(Q("Tb_1")).$(Q("code")) = ", sql)
      @test occursin(conn === _USE_MY ? "UPDATE `use_result` AS `Tb`, `use_driver` AS `Tb_1` SET" :
                                        "FROM \"use_driver\" AS \"Tb_1\" WHERE", sql)
      @test !occursin("IN (SELECT", sql)
      @test count(==("HAM"), params) == 2
    end
  end
end
