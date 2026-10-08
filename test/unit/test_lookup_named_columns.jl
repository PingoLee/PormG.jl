"""
A column named like a lookup operator, filtered on by its bare name (#1030).

`_check_filter` splits a key on `__@` and the `_get_pair_to_oper` arms read the LAST segment as the
lookup when it is a `PormGsuffix` key. With a one-segment key nothing precedes that "lookup", so
`filter("search" => "monaco")` on a `search` column built the column from `path[1:end-1] ==
String[]` and raised a raw `BoundsError` — for every column named `search`, `in`, `contains`,
`regex`, … . A transform name (`year`) was never affected: it is not a `PormGsuffix` key.

A lookup needs a column before it, so a one-segment key is now always the column, whatever its name —
as `values(...)` and `order_by(...)` already read it. The `__@`-less spelling `search__in` keeps its
missing-`@` hint.

Pinned on mock PostgreSQL and SQLite connections (no live database):

julia --project=test/integration test/unit/test_lookup_named_columns.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, F, Q, Qor, Subquery
using PormG.Functions: Case, When, Lower, SearchQuery
import Logging

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct LncMockSQLite <: PormG.PormGSQLite end
struct LncMockPostgres <: PormG.PormGPostgres end
const _LNC_SL = LncMockSQLite()
const _LNC_PG = LncMockPostgres()
PormG.backend_sqlite_version(::LncMockSQLite) = 3045000

PormG.config["lnc_mock"] = PormG.Configuration.Settings(
  connections = _LNC_SL, change_data = true, db_def_folder = "lnc_mock",
)

# A race note whose columns are named after lookups — `search` as Django's own `SearchVectorField`
# convention names it, `in`/`contains`/`regex` as the operators every PormG release has had — plus
# `year`, a transform name, as the control that always worked.
module LncModels
import PormG
import PormG.Models

Lnc_note = Models.Model("lnc_note",
  id       = Models.IDField(),
  search   = Models.CharField(max_length = 50, null = true),
  in       = Models.IntegerField(null = true),
  contains = Models.CharField(max_length = 50, null = true),
  regex    = Models.CharField(max_length = 50, null = true),
  year     = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "lnc_mock")
end

const LNC = LncModels
const _LNC_BACKENDS = (("PostgreSQL", _LNC_PG), ("SQLite", _LNC_SL))
const _LNC_OPERATOR_COLUMNS = ("search", "in", "contains", "regex")

_lnc_notes() = LNC.Lnc_note.objects
# The SQL on one line, without PostgreSQL's `::type` bind casts and with every placeholder spelled `?`,
# so one needle serves both engines.
function _lnc_sql(q, conn)
  sql = inspect_query(q; connection = conn)[:sql_text]
  return replace(replace(replace(sql, r"\s+" => " "), r"::\w+" => ""), r"\$\d+" => "?")
end

# Build AND render, returning the exception or `nothing`. `_check_filter` logs every parse failure at
# `@error` before rethrowing; the refusals below are expected, so that log is silenced.
function _lnc_err(build, conn)
  Logging.with_logger(Logging.NullLogger()) do
    try
      inspect_query(build(); connection = conn)
      nothing
    catch e
      e
    end
  end
end
# The message without ANSI colour: several refusals colour the token a needle spans, and a colour
# code inside it makes the needle match off a TTY only.
function _lnc_msg(err)
  msg = err isa PormG.PormGError ? PormG.error_message(err) : err === nothing ? "" : sprint(showerror, err)
  return replace(msg, r"\e\[[0-9;]*m" => "")
end

# ─────────────────────────────────────────────────────────────────────────────
# #1030: a bare operator-named column is an equality, on every scalar spelling
# `filter("search" => "monaco")` raised `BoundsError: attempt to access 0-element Vector{String}`.
# It renders `"Tb"."search" = ?` on both engines now, through `filter`, `Q`, `Qor` and a `When`
# condition alike — the four routes share `_check_filter`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1030: a bare operator-named column is an equality" begin
  values_by_column = Dict("search" => "monaco", "in" => 3, "contains" => "x", "regex" => "x")
  for (backend, conn) in _LNC_BACKENDS
    @testset "$backend" begin
      for col in _LNC_OPERATOR_COLUMNS
        @testset "$col" begin
          v = values_by_column[col]
          needle = "\"Tb\".\"$(col)\" = ?"

          q = _lnc_notes(); q.filter(col => v).values("id")
          @test occursin(needle, _lnc_sql(q, conn))
          # One bound parameter: the value itself, not a lookup's wrapped form (`%x%`).
          @test inspect_query(q; connection = conn)[:parameters] == Any[v]

          q = _lnc_notes(); q.filter(Q(col => v)).values("id")
          @test occursin(needle, _lnc_sql(q, conn))

          q = _lnc_notes(); q.filter(Qor(col => v, "year" => 2009)).values("id")
          @test occursin(needle, _lnc_sql(q, conn))

          # A `When` condition reaches the same ladder from a projection.
          q = _lnc_notes(); q.values("id", "flag" => Case([When(col => v, then = 1)], default = 0))
          @test occursin("WHEN $(needle)", _lnc_sql(q, conn))
        end
      end

      # The control: a transform name was never misread, and still is not.
      q = _lnc_notes(); q.filter("year" => 2009).values("id")
      @test occursin("\"Tb\".\"year\" = ?", _lnc_sql(q, conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1030: a real lookup on an operator-named column still is one
# Two segments mean column then lookup, whatever the column is called: `search__@icontains` is a LIKE
# on `search`, `in__@in` a membership test on `in`. The fix must not turn these into equalities.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1030: a lookup on an operator-named column" begin
  for (backend, conn) in _LNC_BACKENDS
    @testset "$backend" begin
      q = _lnc_notes(); q.filter("search__@icontains" => "mon").values("id")
      sql = _lnc_sql(q, conn)
      @test occursin("\"search\"", sql)
      @test !occursin("\"Tb\".\"search\" = ?", sql)
      @test inspect_query(q; connection = conn)[:parameters] == Any["%mon%"]

      q = _lnc_notes(); q.filter("in__@in" => [1, 2]).values("id")
      # Membership in each engine's own spelling: PostgreSQL binds the list as one array, SQLite expands it.
      @test occursin(r"\"Tb\"\.\"in\" (= ANY\(\?\)|IN \(\?, \?\))", _lnc_sql(q, conn))

      q = _lnc_notes(); q.filter("contains__@gte" => "m").values("id")
      @test occursin("\"Tb\".\"contains\" >= ?", _lnc_sql(q, conn))

      q = _lnc_notes(); q.filter("regex__@isnull" => true).values("id")
      @test occursin("\"Tb\".\"regex\" IS NULL", _lnc_sql(q, conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1030: a column-expression right-hand side on a bare operator-named column
# The `F`, function and scalar-`Subquery` arms read the last segment as the lookup too. `"search" =>
# F("year")` was refused as "'search' takes the search text", and `"in" => Subquery(…)` as "'in' takes
# the query itself" — both blaming a lookup nobody wrote. Each is a column comparison now.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1030: a column expression on a bare operator-named column" begin
  for (backend, conn) in _LNC_BACKENDS
    # One testset per arm: each is a separate `_get_pair_to_oper` method, and an error in one must
    # not hide whether the next one was fixed.
    @testset "$backend F" begin
      q = _lnc_notes(); q.filter("search" => F("contains")).values("id")
      @test occursin("\"Tb\".\"search\" = \"Tb\".\"contains\"", _lnc_sql(q, conn))
    end
    @testset "$backend function" begin
      q = _lnc_notes(); q.filter("contains" => Lower("search")).values("id")
      @test occursin("\"Tb\".\"contains\" = LOWER(", _lnc_sql(q, conn))
    end
    @testset "$backend Subquery" begin
      sub = Subquery(LNC.Lnc_note.objects.filter("year" => 2009).values("in"))
      q = _lnc_notes(); q.filter("in" => sub).values("id")
      @test occursin("\"Tb\".\"in\" = (SELECT", _lnc_sql(q, conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1030: the remaining right-hand-side arms read a bare operator-named key as the column
# `Joined`, `CTE`, a flat byte payload and a list of query nodes each have their own `_get_pair_to_oper`
# method, and each read the last segment as the lookup too. Checked at PARSE time, through the
# `_check_filter` every pair spelling shares: a `Joined`/`CTE` handle only renders inside a query that
# declares it, and the arm under test has already decided by then. Before the fix `"search" =>
# Joined(…)` was refused as "'search' takes the search text", `"in" => CTE(…)` as "'in' takes a list",
# and `"in" => UInt8[…]` raised the empty-column `BoundsError`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1030: Joined, CTE, bytes and node-list arms on a bare operator-named key" begin
  check(pair) = Logging.with_logger(Logging.NullLogger()) do
    try
      PormG.QueryBuilder._check_filter(pair)
    catch e
      e
    end
  end

  # One testset per arm, so an error in one does not hide the next.
  @testset "Joined" begin
    oper = check("search" => PormG.Joined("n2", "contains"))
    @test oper isa PormG.QueryBuilder.OperObject
    @test oper.operator == "="
    @test oper.column.field == "search"
  end
  @testset "CTE" begin
    oper = check("in" => PormG.CTE("c", "x"))
    @test oper isa PormG.QueryBuilder.OperObject
    @test oper.operator == "="
    @test oper.column.field == "in"
  end
  @testset "Vector{UInt8}" begin
    # A flat byte vector is ONE payload: the binary equality, not an `in` list of two numbers.
    oper = check("in" => UInt8[1, 2])
    @test oper isa PormG.QueryBuilder.OperObject
    @test oper.operator == "="
    @test oper.column.field == "in"
    @test oper.values == UInt8[1, 2]
  end
  @testset "list of query nodes" begin
    # No lookup was written, so the refusal is the generic one — not the `@in` hint, which used to
    # build its example from the empty column (`F("")`).
    err = check("in" => [F("id")])
    @test err isa PormG.FilterError
    @test occursin("is not a filter value", _lnc_msg(err))
    @test !occursin("takes a list of values", _lnc_msg(err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1030: the refusals a bare operator-named column reaches are typed, and about the column
# A shape no column takes is still refused, but as a `FilterError` that reads the key as a column —
# never the raw `BoundsError` the empty column path used to raise. `"search" => SearchQuery(…)` is the
# one that changed meaning: it used to pass the full-text check as if `@search` were written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1030: refusals on a bare operator-named column are FilterErrors" begin
  for (backend, conn) in _LNC_BACKENDS
    @testset "$backend" begin
      # A full-text query compared to a column, not matched against it.
      err = _lnc_err(() -> (q = _lnc_notes(); q.filter("search" => SearchQuery("monaco")); q), conn)
      @test err isa PormG.FilterError
      @test occursin("not a value to compare", _lnc_msg(err))
      # The fix it names is the lookup on the caller's own column, not a placeholder one.
      @test occursin("\"search__@search\" => SearchQuery", _lnc_msg(err))

      # A list and a subquery each want a lookup; the message says none was given.
      err = _lnc_err(() -> (q = _lnc_notes(); q.filter("in" => [1, 2]); q), conn)
      @test err isa PormG.FilterError
      @test occursin("no operator", _lnc_msg(err))

      sub = LNC.Lnc_note.objects.filter("year" => 2009).values("id")
      err = _lnc_err(() -> (q = _lnc_notes(); q.filter("in" => sub); q), conn)
      @test err isa PormG.FilterError
      @test occursin("no operator", _lnc_msg(err))

      # A Julia Regex on a column named `regex` is not the pattern lookup: no `@regex` suggestion.
      err = _lnc_err(() -> (q = _lnc_notes(); q.filter("regex" => r"^mon"); q), conn)
      @test err isa PormG.FilterError
      @test occursin("Pass the value as a String", _lnc_msg(err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1030: a `__@`-less lookup spelling keeps its missing-`@` hint
# `search__in` never reached the operator ladder — `__@` does not split it — so it is the field path
# `search` → `in`, and the shared hint names the `@` it lacks. The fix must not change that.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1030: a __@-less spelling keeps the missing-@ hint" begin
  for (backend, conn) in _LNC_BACKENDS
    @testset "$backend" begin
      err = _lnc_err(() -> (q = _lnc_notes(); q.filter("search__in" => 3).values("id"); q), conn)
      @test err isa PormG.FilterError
      @test occursin("requires '@' prefix", _lnc_msg(err))

      # The vector spelling keeps the parse-time "no operator" message, which names the field path.
      err = _lnc_err(() -> (q = _lnc_notes(); q.filter("search__in" => [1, 2]); q), conn)
      @test err isa PormG.FilterError
      @test occursin("search__in", _lnc_msg(err))
      @test occursin("no operator", _lnc_msg(err))
    end
  end
end
