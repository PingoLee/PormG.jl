"""
Unit tests for #696: the SQL type name in `Cast(x, type)` and every `output_field=` is validated.

A type name is a keyword position in the SQL, so it cannot be a bind parameter — the same defect
class as #691's `Extract` part. Until #696 the caller's string reached the SQL verbatim at four
places, on both engines: the `CAST` arms, PostgreSQL's `(CASE … END)::type` and
`(COALESCE(…))::type`, and the PostgreSQL bind cast `\$n::type` that `Case`'s `default=` takes from
`output_field`. `Dialect.cast_type_name` is the one grammar; `Dialect.cast_type_sql` adds the
engine's spelling.

Hermetic: mock connections and an inline model module, no live database.

Sibling coverage:
  - `test_date_functions_sql.jl` → `Cast(Extract(…), "bigint")`, the retype path #691 points at.
  - `test_constructor_abstractstring.jl` → a `SubString` type is stored as a `String`.
  - `test/integration/test_sql_functions.jl` → the accepted spellings return rows on a real engine.
"""

using Test
using PormG
import PormG.Dialect
using PormG.QueryBuilder: inspect_query, FObject
using PormG.Functions: Cast, Case, When, Coalesce, Concat, Greatest, Least, Value
using PormG.Models: IntegerField, CharField, BinaryField, PositiveIntegerField, BigIntegerField,
  BooleanField, DateField, DateTimeField, DecimalField, DurationField, EmailField, FileField,
  FloatField, ForeignKey, IDField, ImageField, JSONField, PasswordField, PositiveSmallIntegerField,
  SlugField, TextField, TimeField, URLField, UUIDField

# Mock connections — only their type matters (dispatch selects the PG vs SQLite body).
struct _PgCastConn <: PormG.PormGPostgres end
struct _SlCastConn <: PormG.PormGSQLite end
const _CPG = _PgCastConn()
const _CSL = _SlCastConn()
PormG.backend_sqlite_version(::_SlCastConn) = 3045000
PormG.config["cast696_mock"] = PormG.Configuration.Settings(
  connections = _CSL, change_data = true, db_def_folder = "cast696_mock",
)

module Cast696Models
import PormG
import PormG.Models
Cast696_result = Models.Model("cast696_result", id = Models.IDField(),
  points = Models.FloatField(null = true), positionorder = Models.IntegerField(null = true))
PormG.Models.set_models(@__MODULE__, "cast696_mock")
end

const _HOSTILE = [
  "int); DROP TABLE race; --",   # the issue's own repro
  "integer OR TRUE",             # no `;` and no `--`, and still rewrites a WHERE
  "text' --",
  "integer/**/",
  "\"integer\"",                 # a quoted identifier
  "ınteger",                     # dotless ı — non-ASCII look-alike
  "numeric(10,2), 1",
  "integer[]; x",
  "numeric(10,-2)",
  "int\ninteger",                # two words, not a multi-word type
  "interval year to month",      # legal PostgreSQL, outside the grammar on purpose (documented)
  "double(3) precision",         # words after a modifier are only `with/without time zone`
  "timestamp with(3) time zone",
  "integer(3) OR TRUE",
  repeat("a", 129),              # over the length cap, though a single identifier
]

_c696_sql(q, conn) = inspect_query(q; connection = conn)[:sql_text]
_c696_q() = Cast696Models.Cast696_result.objects

# ─────────────────────────────────────────────────────────────────────────────
# #835: Concat's output_field must be a text type
# `CONCAT(…)` / `a || b` is text on both engines and renders no cast, so a declared number or date
# was a type the SQL never applied — the CTE typing believed it while the alias filter checked text.
# A non-text type is now refused when the expression is built, on both engines alike (nothing here
# renders), and the message names the explicit spelling, `Cast(Concat(…), type)`. Text types still
# build and still render no cast: the value already is text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#835: Concat refuses a non-text output_field" begin
  # An integer operand: `points` is a FloatField here, and since #1027 a float operand is refused when
  # the query renders (`'25'` on PostgreSQL, `'25.0'` on SQLite), which is not what this testset is about.
  parts = ["positionorder", Value("-")]
  # Every non-text family `_sql_type_field` names, as a string and as a field object, plus types it
  # names no family for at all (a timestamp, a user enum) and arrays — of text too: `_sql_type_field`
  # reads `"varchar(20)[]"` as `varchar`, which the guard must not take for text.
  for t in ("integer", IntegerField(), "bigint", BigIntegerField(), "float8", FloatField(),
            "numeric(10,2)", DecimalField(), "boolean", BooleanField(), "date", DateField(),
            "timestamptz", DateTimeField(), "integer[]", "text[]", "varchar(20)[]", "char(3)[]", "mood")
    @testset "$(t isa AbstractString ? repr(t) : nameof(typeof(t)))" begin
      err = try Concat(parts; output_field = t); nothing catch e; e end
      @test err isa PormG.InvalidValueError
      # Names the cast that does what the caller asked for, spelled with the type they gave.
      msg = replace(PormG.error_message(err), r"\e\[[0-9;]*m" => "")
      want = lowercase(t isa AbstractString ? t : Dialect.cast_type_name(t.type))
      @test occursin("Cast(Concat(…), \"$(want)\")", msg)
      # The variadic spelling is the same constructor.
      @test_throws PormG.InvalidValueError Concat("points", Value("-"); output_field = t)
    end
  end

  # Text builds — the shipped `@yyyy_q` label passes `CharField()` — and renders no cast on either
  # engine, because there is nothing to cast. `""` keeps meaning "no type" as on every function.
  for t in (CharField(), TextField(), "text", "varchar(20)", "character varying", "char(3)", "TEXT", "")
    @testset "accepted: $(t isa AbstractString ? repr(t) : nameof(typeof(t)))" begin
      q = _c696_q(); q.values("c" => Concat(parts; output_field = t))
      for conn in (_CPG, _CSL)
        sql = _c696_sql(q, conn)
        # A cast on the RESULT. (`Value("-")` binds as `$1::text` on PostgreSQL — an operand's
        # bind cast, preceded by the marker, not by the closing parenthesis of the call.)
        @test !occursin(r"\)\s*::"s, sql)
        @test !occursin(r"CAST\("i, sql)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #696: a hostile type string is refused when the expression is BUILT
# Every public entry point that takes a type string raises `InvalidValueError` before any SQL exists,
# so the refusal does not depend on which engine eventually renders the node.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#696: constructors refuse a type string outside the grammar" begin
  for t in _HOSTILE
    @testset "$(repr(t))" begin
      @test_throws PormG.InvalidValueError Cast("points", t)
      @test_throws PormG.InvalidValueError Case([When("positionorder" => 1, then = 1)]; output_field = t)
      @test_throws PormG.InvalidValueError Case(When("positionorder" => 1, then = 1); output_field = t)
      @test_throws PormG.InvalidValueError Coalesce("points", Value(0); output_field = t)
      @test_throws PormG.InvalidValueError Concat(["points", Value("x")]; output_field = t)
      @test_throws PormG.InvalidValueError Greatest("points", Value(0); output_field = t)
      @test_throws PormG.InvalidValueError Least("points", Value(0); output_field = t)
    end
  end
  # `Cast` has no "no cast" meaning, so an empty type is refused; `output_field = ""` has always
  # meant "no cast" to `CASE`, and still does.
  @test_throws PormG.InvalidValueError Cast("points", "")
  @test Coalesce("points", Value(0); output_field = "").kwargs["output_field"] === nothing

  # The message echoes the caller's text escaped, so a newline or a terminal sequence in it cannot
  # split a log line, and it names the way out.
  err = try Cast("points", "a\e[31mb\nc"); nothing catch e; e end
  @test err isa PormG.InvalidValueError
  msg = PormG.error_message(err)
  @test !occursin('\e', msg) && !occursin('\n', msg)
  @test occursin("double precision", msg) && occursin("IntegerField()", msg)
  err = try Coalesce("points", 0; output_field = "x y"); nothing catch e; e end   # two operands (#859)
  @test startswith(PormG.error_message(err), "output_field:")

  # A long input fails as `InvalidValueError`, not as PCRE's `match limit exceeded`
  # `ErrorException` — the grammar used to backtrack O(n²) over the word groups (review of #696).
  # The message quotes only the start of it.
  for long in (repeat("a ", 2000) * ";", "integer" * repeat(" ", 20000) * "x;", repeat("a", 100_000))
    err = try Cast("points", long); nothing catch e; e end
    @test err isa PormG.InvalidValueError
    @test length(PormG.error_message(err)) < 1000
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #696: every Dialect sink refuses on its own
# A node built without a constructor (or a future constructor that forgets the check) must still
# not reach the SQL text: each of the four sinks validates through `cast_type_sql`. The first case
# is the issue's exact reproduction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#696: Dialect sinks refuse a hostile type" begin
  bad = "int); DROP TABLE race; --"
  @test_throws PormG.InvalidValueError Dialect.CAST("x", Dict{String,Any}("type" => bad), _CPG)
  @test_throws PormG.InvalidValueError Dialect.CAST("x", Dict{String,Any}("type" => bad), _CSL)
  whens = Any["WHEN a THEN 1"]
  @test_throws PormG.InvalidValueError Dialect.CASE(whens, Dict{String,Any}("else" => "0", "output_field" => bad), _CPG)
  @test_throws PormG.InvalidValueError Dialect.CASE(whens, Dict{String,Any}("else" => "0", "output_field" => bad), _CSL)
  # #852: the three operand-typed functions cast on both engines now, so each is a sink on each.
  for f in (Dialect.COALESCE, Dialect.GREATEST, Dialect.LEAST), conn in (_CPG, _CSL)
    @test_throws PormG.InvalidValueError f(Any["a", "b"], Dict{String,Any}("output_field" => bad), conn)
  end

  # The bind cast: `Case`'s `default=` value is a parameter, cast to `output_field` on PostgreSQL.
  # Hand-built so the constructor's own check is bypassed. The bind path only runs when the CASE
  # renderer also casts, so this pins the BUILD as a whole; the bind sink's own mapping is pinned by
  # the `ELSE \$n::integer` assertion in "output_field renders through the build".
  node = FObject(function_name = "CASE", column = [When("positionorder" => 1, then = 1)],
                 kwargs = Dict{String,Any}("else" => 7, "output_field" => bad))
  q = _c696_q(); q.values("c" => node)
  @test_throws PormG.InvalidValueError _c696_sql(q, _CPG)
  # `$n::integer OR TRUE` — the words-only shape that carries no `;` or `--`.
  node2 = FObject(function_name = "CASE", column = [When("positionorder" => 1, then = 1)],
                  kwargs = Dict{String,Any}("else" => 7, "output_field" => "integer OR TRUE"))
  q2 = _c696_q(); q2.values("c" => node2)
  @test_throws PormG.InvalidValueError _c696_sql(q2, _CPG)
  # The bind sink ALONE: a WHEN carrying `output_field` inside a CASE that carries none. The WHEN
  # renderer ignores `output_field`, so only the `then` bind cast can refuse it.
  when = FObject(function_name = "WHEN", column = "positionorder",
                 kwargs = Dict{String,Any}("then" => 5, "else" => missing, "output_field" => "integer OR TRUE"))
  node3 = FObject(function_name = "CASE", column = [when], kwargs = Dict{String,Any}("else" => "NULL"))
  q3 = _c696_q(); q3.values("c" => node3)
  @test_throws PormG.InvalidValueError _c696_sql(q3, _CPG)
end

# ─────────────────────────────────────────────────────────────────────────────
# #696: the accepted grammar still renders, on both engines
# Every spelling the issue names as real renders exactly. The name keeps the caller's case, the
# modifier is normalized, and SQLite keeps its reverse-map spelling (upper-case, `VARCHAR` → `TEXT`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#696: accepted type strings render on both engines" begin
  cases = [
    # input                            PostgreSQL                     SQLite
    ("integer",                        "integer",                     "INTEGER"),
    ("INTEGER",                        "integer",                     "INTEGER"),
    ("bigint",                         "bigint",                      "INTEGER"),
    ("text",                           "text",                        "TEXT"),
    # A SIZED name is not mapped: a map value is an alias of the bare key only.
    ("numeric(10,2)",                  "numeric(10,2)",               "NUMERIC(10,2)"),
    ("numeric( 10 , 2 )",              "numeric(10,2)",               "NUMERIC(10,2)"),
    ("varchar(20)",                    "varchar(20)",                 "VARCHAR(20)"),
    ("DOUBLE_PRECISION(3)",            "DOUBLE_PRECISION(3)",         "DOUBLE_PRECISION(3)"),   # not `float(3)`, which is `real`
    ("double precision",               "double precision",            "DOUBLE PRECISION"),
    ("DOUBLE   PRECISION",             "DOUBLE PRECISION",            "DOUBLE PRECISION"),
    ("character varying(20)",          "character varying(20)",       "CHARACTER VARYING(20)"),
    ("mood",                           "mood",                        "MOOD"),   # a user-defined type
  ]
  for (input, pg, sl) in cases
    @testset "$(repr(input))" begin
      @test Dialect.CAST("x", Dict{String,Any}("type" => input), _CPG) == "(x)::" * pg
      @test Dialect.CAST("x", Dict{String,Any}("type" => input), _CSL) == "CAST(x AS " * sl * ")"
    end
  end

  # Arrays are PostgreSQL-only: SQLite has no array type, so it is a capability error, not a
  # syntax error at execution.
  @test Dialect.CAST("x", Dict{String,Any}("type" => "integer[]"), _CPG) == "(x)::integer[]"
  @test Dialect.CAST("x", Dict{String,Any}("type" => "integer [ 3 ]"), _CPG) == "(x)::integer[3]"
  @test_throws PormG.BackendCapabilityError Dialect.CAST("x", Dict{String,Any}("type" => "integer[]"), _CSL)
  # The name maps, the suffix stays: a field type in an array is the engine's array type.
  @test Dialect.CAST("x", Dict{String,Any}("type" => "BLOB[]"), _CPG) == "(x)::bytea[]"

  # The constructor stores the validated spelling, not the caller's text.
  @test Cast("points", "numeric( 10 , 2 )").kwargs["type"] == "numeric(10,2)"
  @test Cast("points", "INTEGER").kwargs["type"] == "INTEGER"
end

# ─────────────────────────────────────────────────────────────────────────────
# #696: every field object renders in the engine's own spelling
# A field object contributes its canonical `type`. On PostgreSQL that used to reach the SQL
# verbatim, so `Cast(x, BinaryField())` rendered `::BLOB` and `PositiveIntegerField()` rendered
# `::INTEGER UNSIGNED` — neither is a PostgreSQL type. Both now map through the reverse type map.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#696: field objects map to each engine's type" begin
  fields = [BigIntegerField(), BinaryField(), BooleanField(), CharField(), DateField(),
            DateTimeField(), DecimalField(), DurationField(), EmailField(), FileField(), FloatField(),
            ForeignKey("x"), IDField(), ImageField(), IntegerField(), JSONField(), PasswordField(),
            PositiveIntegerField(), PositiveSmallIntegerField(), SlugField(), TextField(),
            TimeField(), URLField(), UUIDField()]
  for f in fields
    t = getfield(f, :type)
    @testset "$(nameof(typeof(f))) ($t)" begin
      # Every canonical type is a key of both maps, so none falls through to the raw spelling.
      @test haskey(PormG.postgres_type_map_reverse, t)
      @test haskey(PormG.sqlite_type_map_reverse, t)
      node = Cast("points", f)
      @test Dialect.CAST("x", node.kwargs, _CPG) == "(x)::" * PormG.postgres_type_map_reverse[t]
      # The temporal fields are #822's, below: SQLite has no time types to cast to.
      t in ("DATE", "TIMESTAMPTZ", "TIME", "INTERVAL") && continue
      @test Dialect.CAST("x", node.kwargs, _CSL) == "CAST(x AS " * PormG.sqlite_type_map_reverse[t] * ")"
    end
  end
  @test Dialect.CAST("x", Cast("points", BinaryField()).kwargs, _CPG) == "(x)::bytea"
  @test Dialect.CAST("x", Cast("points", PositiveIntegerField()).kwargs, _CPG) == "(x)::integer"
end

# ─────────────────────────────────────────────────────────────────────────────
# #696: output_field through the full build, both engines
# `Case` casts the whole expression and its `default=` bind parameter on PostgreSQL; SQLite wraps
# the CASE in `CAST(… AS …)`. `Coalesce`, `Greatest` and `Least` cast the same way on both engines
# since #852 — SQLite ignored their `output_field`, and `Greatest`/`Least` cast on neither.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#696: output_field renders through the build" begin
  q = _c696_q(); q.values("c" => Case([When("positionorder" => 1, then = 1)]; default = 0, output_field = IntegerField()))
  pg = _c696_sql(q, _CPG)
  @test occursin("END)::integer", pg)            # the expression cast
  @test occursin(r"ELSE \$\d+::integer", pg)     # the bind cast on the default
  @test occursin(r"CAST\(CASE.*END\s+AS INTEGER\)"s, _c696_sql(q, _CSL))

  # SQLite keeps the sized spelling: an unsized name goes through the reverse type map, a sized one
  # is upper-cased as written (`Dialect._map_cast_name`).
  for (ctor, pg_fn, sl_fn) in ((Coalesce, "COALESCE(", "COALESCE("), (Greatest, "GREATEST(", "MAX("),
                               (Least, "LEAST(", "MIN("))
    # #1040: over an integer column — a float cast to a scaled numeric is refused.
    q = _c696_q(); q.values("c" => ctor("positionorder", Value(0); output_field = "numeric(10,2)"))
    pg = _c696_sql(q, _CPG)
    @test occursin("($(pg_fn)", pg) && occursin(")::numeric(10,2)", pg)
    @test occursin("CAST($(sl_fn)", _c696_sql(q, _CSL)) && occursin("AS NUMERIC(10,2))", _c696_sql(q, _CSL))
    # No `output_field`: no expression cast, on either engine. (PostgreSQL still types the literal's
    # bind parameter, `$1::bigint`, which is not a cast of the result.)
    q = _c696_q(); q.values("c" => ctor("points", Value(0)))
    @test !occursin(")::", _c696_sql(q, _CPG)) && !occursin("CAST(", _c696_sql(q, _CSL))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #822: SQLite has no time types — a `date` cast is `date(x)`, the other temporal targets refuse
# Every temporal type name has NUMERIC affinity on SQLite, so `CAST('2020-03-29' AS DATE)` was the
# integer 2020 and a date filter on it matched nothing. These rows used to sit in the two tables
# above with `CAST(x AS DATE)` / `CAST(x AS DATETIME)` as the expected SQLite spelling: that pinned
# the defect, which `sqlite3` shows directly (`SELECT CAST('2020-03-29' AS DATE)` → `2020`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#822: SQLite renders a date cast as date(), and refuses the other temporal casts" begin
  _sl_cast(type) = Dialect.CAST("x", Dict{String,Any}("type" => type), _CSL)

  @testset "date" begin
    for type in ("date", "DATE", Cast("points", DateField()).kwargs["type"])
      @test _sl_cast(type) == "date(x)"
    end
    # PostgreSQL is unchanged — it has a real date type.
    @test Dialect.CAST("x", Dict{String,Any}("type" => "date"), _CPG) == "(x)::date"
  end

  @testset "the other temporal targets are a capability error" begin
    for type in ("timestamp", "timestamptz", "TIMESTAMPTZ", "datetime", "time", "timetz", "interval",
                 "timestamp with time zone", "timestamp without time zone", "timestamp(3) with time zone",
                 "time with time zone", "time without time zone", "timestamp(3)", "date(3)",
                 Cast("points", DateTimeField()).kwargs["type"],
                 Cast("points", TimeField()).kwargs["type"],
                 Cast("points", DurationField()).kwargs["type"])
      @testset "$(repr(type))" begin
        err = try _sl_cast(type); nothing catch e; e end
        @test err isa PormG.BackendCapabilityError
        @test occursin("SQLite", err.msg) && occursin("#822", err.msg)
      end
    end
    # A name that only STARTS like a temporal word is not classified as one: it renders as before.
    # (Not a claim that the SQLite cast is useful — any unknown type name has NUMERIC affinity there.)
    @test _sl_cast("timestamp_ms") == "CAST(x AS TIMESTAMP_MS)"
    @test _sl_cast("text") == "CAST(x AS TEXT)"
  end

  @testset "output_field = date through the build" begin
    q = _c696_q(); q.values("c" => Case([When("positionorder" => 1, then = "2020-03-29")]; default = "NULL", output_field = DateField()))
    sl = _c696_sql(q, _CSL)
    @test occursin(r"date\(CASE.*END\s*\)"s, sl)
    @test !occursin("AS DATE", sl)
    @test occursin("END)::date", _c696_sql(q, _CPG))

    q = _c696_q(); q.values("c" => Case([When("positionorder" => 1, then = "x")]; output_field = TimeField()))
    @test_throws PormG.BackendCapabilityError _c696_sql(q, _CSL)

    # A single bare `When` takes the same cast — it rendered none on either engine before.
    q = _c696_q(); q.values("c" => Case(When("positionorder" => 1, then = "2020-03-29"); output_field = DateField()))
    @test occursin(r"date\(CASE WHEN .* END\)"s, _c696_sql(q, _CSL))
    @test occursin(r"\(CASE WHEN .* END\)::date"s, _c696_sql(q, _CPG))
    q = _c696_q(); q.values("c" => Case(When("positionorder" => 1, then = 1); default = 0, output_field = IntegerField()))
    @test occursin(r"CAST\(CASE WHEN .* END AS INTEGER\)"s, _c696_sql(q, _CSL))
    q = _c696_q(); q.values("c" => Case(When("positionorder" => 1, then = 1); default = 0))
    @test !occursin(r"CAST|::"s, _c696_sql(q, _CSL))
  end

  # The array refusal names the array, not SQLite's missing time types.
  @testset "date[] is an array error" begin
    err = try _sl_cast("date[]"); nothing catch e; e end
    @test err isa PormG.BackendCapabilityError
    @test occursin("array", err.msg)
  end

  # The renderer's output, executed: SQLite returns the date text, where the old spelling returned a
  # number. A timestamp is cut to its date, as PostgreSQL's `::date` does.
  @testset "SQLite returns the date, not a number" begin
    isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
    db = Main.SQLite.DB()
    # Read inside the iteration: a SQLite row is a view of the cursor, gone once it advances.
    function _run(sql)
      for row in Main.SQLite.DBInterface.execute(db, "SELECT " * sql * " AS v")
        return row.v
      end
    end
    try
      @test _run(Dialect.CAST("'2020-03-29'", Dict{String,Any}("type" => "date"), _CSL)) == "2020-03-29"
      @test _run(Dialect.CAST("'2020-03-29T10:11:12.000+00:00'", Dict{String,Any}("type" => "date"), _CSL)) == "2020-03-29"
      @test _run(Dialect.CAST("'2020-03-29 10:11:12'", Dict{String,Any}("type" => "date"), _CSL)) == "2020-03-29"
      # The comparison a filter makes: date text against date text, so it can match.
      @test _run(Dialect.CAST("'2020-03-29'", Dict{String,Any}("type" => "date"), _CSL) * " = '2020-03-29'") == 1
    finally
      close(db)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #852: Coalesce/Greatest/Least cast to their output_field on SQLite too
# Both type readers believe a declared `output_field`, but SQLite rendered no cast for these three
# (and PostgreSQL none for `Greatest`/`Least`), so a filter typed by the declaration compared the
# operand's text with a number and matched nothing. They now cast through `sqlite_cast_sql`, so the
# #822 temporal rules apply to them exactly as to `Cast` and `Case`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#852: Coalesce/Greatest/Least render their output_field cast on SQLite" begin
  ctors = ((Coalesce, "COALESCE("), (Greatest, "MAX("), (Least, "MIN("))

  @testset "a date is date(…) on SQLite, ::date on PostgreSQL" for (ctor, sl_fn) in ctors
    q = _c696_q(); q.values("c" => ctor("positionorder", Value(0); output_field = DateField()))
    @test occursin("date($(sl_fn)", _c696_sql(q, _CSL))
    @test !occursin("AS DATE", _c696_sql(q, _CSL))
    @test occursin(")::date", _c696_sql(q, _CPG))
  end

  @testset "another temporal type or an array is a capability error on SQLite" for (ctor, _) in ctors
    for type in ("timestamp", "time", DateTimeField(), "integer[]", "numeric(10,2)[]")
      q = _c696_q(); q.values("c" => ctor("positionorder", Value(0); output_field = type))
      @test_throws PormG.BackendCapabilityError _c696_sql(q, _CSL)
    end
    # PostgreSQL has every one of them, so the same projection renders there.
    q = _c696_q(); q.values("c" => ctor("positionorder", Value(0); output_field = "timestamp"))
    @test occursin(")::timestamp", _c696_sql(q, _CPG))
  end

  # The issue's point, executed: the operand's own text never equals a number, the cast does.
  @testset "SQLite: the cast is what makes the comparison match" begin
    isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
    db = Main.SQLite.DB()
    # Read inside the iteration: a SQLite row is a view of the cursor, gone once it advances.
    value(sql) = only([row.v for row in Main.SQLite.DBInterface.execute(db, "SELECT " * sql * " AS v")])
    try
      before = "COALESCE(NULL, '7')"   # what SQLite rendered for output_field = "integer"
      after = Dialect.COALESCE(Any["NULL", "'7'"], Dict{String,Any}("output_field" => "integer"), _CSL)
      @test after == "CAST(COALESCE(NULL, '7') AS INTEGER)"
      @test value(before * " = 7") == 0
      @test value(after * " = 7") == 1
    finally
      close(db)
    end
  end

  # The "Related" half: an array is not a scalar to either reader, whatever its element.
  @testset "_sql_type_field answers nothing for an array" begin
    for type in ("integer[]", "text[]", "numeric(10,2)[]", "varchar(20)[]", "char(3)[]")
      @test PormG.QueryBuilder._sql_type_field(type) === nothing
    end
    # The scalar spellings are unchanged.
    @test PormG.QueryBuilder._sql_type_field("numeric(10,2)") isa PormG.Models.sDecimalField
    @test PormG.QueryBuilder._sql_type_field("varchar(20)") isa PormG.Models.sCharField
  end
end
