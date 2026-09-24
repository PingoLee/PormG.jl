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
  err = try Coalesce("points"; output_field = "x y"); nothing catch e; e end
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
  @test_throws PormG.InvalidValueError Dialect.COALESCE(Any["a", "b"], Dict{String,Any}("output_field" => bad), _CPG)

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
    ("timestamptz",                    "timestamptz",                 "DATETIME"),
    ("timestamp with time zone",       "timestamp with time zone",    "TIMESTAMP WITH TIME ZONE"),
    ("timestamp(3) with time zone",    "timestamp(3) with time zone", "TIMESTAMP(3) WITH TIME ZONE"),
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
      @test Dialect.CAST("x", node.kwargs, _CSL) == "CAST(x AS " * PormG.sqlite_type_map_reverse[t] * ")"
    end
  end
  @test Dialect.CAST("x", Cast("points", BinaryField()).kwargs, _CPG) == "(x)::bytea"
  @test Dialect.CAST("x", Cast("points", PositiveIntegerField()).kwargs, _CPG) == "(x)::integer"
end

# ─────────────────────────────────────────────────────────────────────────────
# #696: output_field through the full build, both engines
# `Case` casts the whole expression and its `default=` bind parameter on PostgreSQL; SQLite wraps
# the CASE in `CAST(… AS …)`. `Coalesce` casts on PostgreSQL only (SQLite ignores `output_field`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#696: output_field renders through the build" begin
  q = _c696_q(); q.values("c" => Case([When("positionorder" => 1, then = 1)]; default = 0, output_field = IntegerField()))
  pg = _c696_sql(q, _CPG)
  @test occursin("END)::integer", pg)            # the expression cast
  @test occursin(r"ELSE \$\d+::integer", pg)     # the bind cast on the default
  @test occursin(r"CAST\(CASE.*END\s+AS INTEGER\)"s, _c696_sql(q, _CSL))

  q = _c696_q(); q.values("c" => Coalesce("points", Value(0); output_field = "numeric(10,2)"))
  @test occursin(")::numeric(10,2)", _c696_sql(q, _CPG))
  @test !occursin(r"(?i)numeric|decimal", _c696_sql(q, _CSL))
end
