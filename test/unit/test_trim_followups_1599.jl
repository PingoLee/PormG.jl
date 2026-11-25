# ============================================================
# test/unit/test_trim_followups_1599.jl
#
# CONTRACT being tested:
#   Three paths retyped so a trimmed binary runs them (#1599; #1838's and #1839's decisions) answer what the code they
#   replace answered:
#     - `exists()` builds its statement once (`_exists_statement`) and answers from one of two bodies chosen before the
#       connection closure (`_exists_show`, `_exists_run`): the same SQL and parameters in every inspection mode, the
#       same value, and the same refusal, now with its answer inferred `Bool`;
#     - the JSON, array and network lookup renderers take the engine `@nospecialize` and refuse through
#       `Dialect._capability_error_at` in place of a direct `_capability_error` call: the same error type and text on
#       every engine without the feature (and on a backend with no rows yet), and the same SQL on PostgreSQL;
#     - `Q`/`Qor` from 32 arguments on check each argument through a walk over the types they take (`_q_term_known`)
#       in place of a dynamic `_q_term` call: the same terms in the same order, the same SQL, and the same first refusal
#       from any position.
#   The old expressions are written out here as the oracle.
#
# Hermetic: mock connections and an in-memory SQLite pool, no database server.
#
# Run: julia --project=test/integration test/unit/test_trim_followups_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG: Q, Qor, F
using Dates

const _TF_QB = PormG.QueryBuilder
const _TF_D = PormG.Dialect

struct TfMockSQLite <: PormG.PormGSQLite end
struct TfMockPostgres <: PormG.PormGPostgres end
struct TfMockMySQL <: PormG.PormGMySQL end
struct TfMockOther <: PormG.PormGBackend end   # a backend with no rows yet, as a new one starts (#1130)
PormG.backend_sqlite_version(::TfMockSQLite) = 3045000
PormG.config["tf_mock"] = PormG.Configuration.Settings(connections = TfMockSQLite(), change_data = true,
                                                       db_def_folder = "tf_mock")
const _TF_POOL = PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config["tf_live"] = PormG.Configuration.Settings(connections = _TF_POOL, change_data = true,
                                                       db_def_folder = "tf_live")

module TfModels
import PormG
import PormG.Models
Tf_race::Models.ModelType = Models.Model("tf_race",
  raceid  = Models.IDField(),
  year    = Models.IntegerField(),
  round   = Models.IntegerField(),
  name    = Models.CharField(max_length = 80),
  date    = Models.DateField(),
)
# The three column kinds the lookups need, on one model queried without being migrated: the refusals come before SQL.
Tf_telemetry::Models.ModelType = Models.Model("tf_telemetry",
  id      = Models.IDField(),
  payload = Models.JSONField(null = true),
  laps    = Models.ArrayField(Models.IntegerField()),
  pit_ip  = Models.GenericIPAddressField(),
)
Models.@models Tf_race Tf_telemetry
PormG.Models.set_models(@__MODULE__, "tf_mock")
end
module TfLive
import PormG
import PormG.Models
Tf_race::Models.ModelType = Models.Model("tf_race",
  raceid  = Models.IDField(),
  year    = Models.IntegerField(),
  name    = Models.CharField(max_length = 80),
)
Models.@models Tf_race
PormG.Models.set_models(@__MODULE__, "tf_live")
end
const _TF_RACE = TfModels.Tf_race
const _TF_TEL = TfModels.Tf_telemetry
const _TF_ENGINES = (TfMockSQLite(), TfMockPostgres(), TfMockMySQL())

_tf_strip(s) = replace(s, r"\e\[[0-9;]*m" => "")
# Run `f`, and name what it raised (its text without colour codes: CI runs with colour on), so an oracle and its
# replacement are compared on refusals as well as values.
_tf_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), _tf_strip(sprint(showerror, e)))
end
_tf_render(q, conn; mode = :dict) = _tf_outcome(() -> _TF_QB.query(q; connection = conn, show_query = mode))
# The same, with a value compared by its printed form, term by term: a term (`OperObject`, `QorObject`) compares by
# identity, and the old comprehension narrowed its vector's element type, where `_q_terms_of` returns
# `Vector{FilterType}` (since #1838).
_tf_outcome_repr(f) = (r = _tf_outcome(f); r[1] === :value ? (:value, r[2] isa AbstractVector ? map(repr, r[2]) : repr(r[2])) : r)

# ── the oracles: the code each path replaced ───────────────────────────────────────────────────────────────────────

# `exists()` as it was: the old closure's body up to its `show_query` branch, on the connection given.
function _tf_old_exists_statement(oq, connection)
  QB = _TF_QB
  q = QB._terminal_copy(oq)
  keep_values = QB._projection_shapes_rows(q.object; distinct = q.object.distinct && q.object.offset > 0, clear_degenerate = false)
  QB._keeps_order(q.object, keep_values) || (q.object.order = [])
  keep_values || (q.object.values = QB.ProjectionNode[])
  table_alias = QB.SQLTbAlias()
  parameters = QB.get_parameter(connection)
  QB.set_context!(parameters, :cte)
  with_clause, cte_state = QB.build_cte_clause(q.object.ctes, connection, parameters, table_alias)
  instruction = QB.build(q.object, table_alias = table_alias, connection = connection, parameters = parameters,
                         cte_state = cte_state, semi_join = q.object.offset <= 0,
                         declared_paths = keep_values ? String[] : QB._projected_paths(oq.object.values))
  QB._refuse_constant_terminal(instruction, keep_values, "exists()")
  limit_clause = QB._probe_limit(q.object.limit, 1) == 0 ? "LIMIT 0" : "LIMIT 1"
  offset_clause = q.object.offset > 0 ?
    QB.with_bucket(() -> "OFFSET " * QB.add_parameter!(parameters, q.object.offset), parameters, :limit) : ""
  safe_table_name = QB.safe_table_identifier(PormG.Models.model_table_name(q.object.model), instruction.connection)
  safe_alias = QB.quote_identifier(instruction.alias, instruction.connection)
  sql = """
  $(with_clause)SELECT $(QB._exists_projection(q.object, instruction, keep_values))
  FROM $safe_table_name as $safe_alias
  $(join(instruction.join, "\n"))
  $(isempty(instruction._where) ? "" : "WHERE " * join(instruction._where, " AND \n   "))
  $(instruction.aggregate && !isempty(instruction.group) ? "GROUP BY $(join(instruction.group, ", "))" : "")$(isempty(instruction.having) ? "" : "\nHAVING " * join(instruction.having, " AND \n   "))$(isempty(instruction.order) ? "" : "\nORDER BY " * join(instruction.order, ", "))
  $limit_clause
  $offset_clause
  """
  return (sql = sql, instruction = instruction, model_name = q.object.model.name)
end
# What an inspection mode returns for a statement.
_tf_show(st, mode) = _TF_QB._show_query_result(mode, st.sql, st.instruction.connection, st.model_name, :select;
                                               parameters = st.instruction.parameters)

# The comprehension `Q`/`Qor` used before #1838 (#863): the oracle for `_q_terms_of` at every length. It is one version
# back: #1838 replaced it with the recursion and the `Any32` loop this change types, and its own equivalence test
# (`test_app_reads_trim_1599.jl`) holds the comprehension as the oracle too.
_tf_old_terms(x...) = [isa(v, Pair) ? _TF_QB._check_filter(v) : isa(v, _TF_QB.FilterType) ? _TF_QB._check_filter_node(v) :
                       throw(PormG.FilterError("Invalid argument: a $(typeof(v)); please use a pair (key => value).")) for v in x]

# The fourteen lookups: renderer, feature, the text its refusal names, PostgreSQL's SQL over `col`/`$1`, a filter key
# on `Tf_telemetry` and a value for it.
const _TF_LOOKUPS = (
  (_TF_D.jcontains,              :jsonb_operators, "The @jcontains lookup (JSONB @>)",             "col @> \$1",         "payload__@jcontains",              Dict("a" => 1)),
  (_TF_D.has_key,                :jsonb_operators, "The @has_key lookup (JSONB ?)",                "col ? \$1",          "payload__@has_key",                "a"),
  (_TF_D.has_any_keys,           :jsonb_operators, "The @has_any_keys lookup (JSONB ?|)",          "col ?| \$1",         "payload__@has_any_keys",           ["a", "b"]),
  (_TF_D.has_keys,               :jsonb_operators, "The @has_keys lookup (JSONB ?&)",              "col ?& \$1",         "payload__@has_keys",               ["a", "b"]),
  (_TF_D.acontains,              :arrays,          "The @acontains lookup (array @>)",             "col @> \$1",         "laps__@acontains",                 [1, 2]),
  (_TF_D.contained_by,           :arrays,          "The @contained_by lookup (array <@)",          "col <@ \$1",         "laps__@contained_by",              [1, 2]),
  (_TF_D.overlap,                :arrays,          "The @overlap lookup (array &&)",               "col && \$1",         "laps__@overlap",                   [1, 2]),
  (_TF_D.net_contained,          :network_types,   "The @net_contained lookup (inet <<)",          "col << \$1",         "pit_ip__@net_contained",           "10.0.0.0/8"),
  (_TF_D.net_contained_or_equal, :network_types,   "The @net_contained_or_equal lookup (inet <<=)", "col <<= \$1",       "pit_ip__@net_contained_or_equal",  "10.0.0.0/8"),
  (_TF_D.net_contains,           :network_types,   "The @net_contains lookup (inet >>)",           "col >> \$1",         "pit_ip__@net_contains",            "10.0.0.1"),
  (_TF_D.net_contains_or_equals, :network_types,   "The @net_contains_or_equals lookup (inet >>=)", "col >>= \$1",       "pit_ip__@net_contains_or_equals",  "10.0.0.1"),
  (_TF_D.net_overlaps,           :network_types,   "The @net_overlaps lookup (inet &&)",           "col && \$1",         "pit_ip__@net_overlaps",            "10.0.0.0/8"),
  (_TF_D.family,                 :network_types,   "The @family lookup (inet family())",           "family(col) = \$1",  "pit_ip__@family",                  4),
  (_TF_D.prefixlen,              :network_types,   "The @prefixlen lookup (inet masklen())",       "masklen(col) = \$1", "pit_ip__@prefixlen",               32),
)

@testset "exists(), the lookup refusals and Q/Qor from 32 arguments answer as before (#1599)" begin

  # What: `exists()` in every inspection mode, against the old body, on three mock engines, plus its value and its
  #   inferred type on an in-memory SQLite pool.
  # Expected: the same SQL and parameters (and the same refusal for a constant projection) in each mode; `true`/`false`
  #   as the rows say; the answer inferred `Bool` through the fluent call.
  # Why: the build moved into `_exists_statement` and the inspection and execution became two bodies; a different
  #   statement would change what `exists()` asks, and the inferred `Bool` is what a trimmed program relies on.
  @testset "exists() keeps its statement and value, now inferred Bool" begin
    qs = (() -> _TF_RACE.objects.filter("year" => 2008),
          () -> _TF_RACE.objects.filter("year__@gte" => 2008).order_by("round").offset(2),
          () -> _TF_RACE.objects.filter("year" => 2008).limit(0),
          () -> _TF_RACE.objects.values("year").distinct().offset(1),
          () -> _TF_RACE.objects.values("name", "year").filter("round__@lt" => 3),
          () -> _TF_RACE.objects.values("k" => PormG.QueryBuilder.Value(1)))   # a constant projection: refused
    # Each engine's statement, both ways, in each inspection mode; a refusal is compared as raised.
    for conn in _TF_ENGINES, mk in qs, mode in (:sql, :dict, :params)
      new = _tf_outcome(() -> _tf_show(_TF_QB._exists_statement(mk(), conn, nothing), mode))
      old = _tf_outcome(() -> _tf_show(_tf_old_exists_statement(mk(), conn), mode))
      @test (nameof(typeof(conn)), mode, new) == (nameof(typeof(conn)), mode, old)
    end
    # The public spelling, through the configured (SQLite mock) connection: the whole `_exists_show` path.
    for mk in qs, mode in (:sql, :dict, :params)
      new = _tf_outcome(() -> mk().exists(show_query = mode))
      old = _tf_outcome(() -> _tf_show(_tf_old_exists_statement(mk(), TfMockSQLite()), mode))
      @test (mode, new) == (mode, old)
    end
    # The value, on a live pool.
    PormG.fetch(PormG.config["tf_live"], "CREATE TABLE tf_race (raceid INTEGER PRIMARY KEY, year INTEGER, name TEXT)")
    PormG.fetch(PormG.config["tf_live"], "INSERT INTO tf_race (raceid, year, name) VALUES (1, 2008, 'Monaco'), (2, 2009, 'Monza')")
    L = TfLive.Tf_race
    @test L.objects.filter("year" => 2008).exists() === true
    @test L.objects.filter("year" => 1900).exists() === false
    @test L.objects.filter("year__@gte" => 2008).limit(0).exists() === false
    @test L.objects.order_by("raceid").offset(1).exists() === true
    @test L.objects.order_by("raceid").offset(2).exists() === false
    OH = typeof(L.objects)
    @test only(Base.return_types(h -> h.exists(), (OH,))) === Bool
    @test only(Base.return_types(_TF_QB._exists, (OH,))) === Bool
    @test (@inferred (h -> h.exists())(L.objects.filter("year" => 2008))) === true
    @test (@inferred _TF_QB._exists(L.objects.filter("year" => 2008))) === true
    # An inspection mode still returns its shape.
    @test L.objects.filter("year" => 2008).exists(show_query = :sql) isa String
  end

  # What: the fourteen JSON, array and network lookup renderers on each engine, against a direct `_capability_error`
  #   call (the old refusal) and PostgreSQL's SQL; and the same lookups through a filter, on each engine.
  # Expected: on SQLite, MySQL and a backend with no rows, a `BackendCapabilityError` with the old text; on PostgreSQL,
  #   the SQL each renderer returned. Through a filter: the same refusal on SQLite and MySQL, and SQL on PostgreSQL.
  # Why: the renderers take the engine `@nospecialize` and refuse through the barrier so a trimmed image has code for
  #   both; the error's type and text are what a caller reads and what the trimmed fixture's lines compare.
  @testset "the JSON, array and network refusals keep their type and text" begin
    for conn in (TfMockSQLite(), TfMockMySQL(), TfMockOther()), (f, feature, what, _, _, _) in _TF_LOOKUPS
      old = PormG._capability_error(conn, feature, what)
      @test (nameof(typeof(conn)), nameof(f), _tf_outcome(() -> f(conn, "col", "\$1"))) ==
            (nameof(typeof(conn)), nameof(f), (:raised, PormG.BackendCapabilityError, _tf_strip(sprint(showerror, old))))
    end
    for (f, _, _, sql, _, _) in _TF_LOOKUPS
      @test (nameof(f), f(TfMockPostgres(), "col", "\$1")) == (nameof(f), sql)
    end
    # Through a filter: the query builder's operator functions (`_json_operator_sql`, …) reach the JSON and network
    # renderers. An array lookup's value is refused by its bind first, before the renderer, as it was: an array value
    # has no representation on an engine without array types.
    engine_name = Dict(:TfMockSQLite => "SQLite", :TfMockMySQL => "MySQL")
    for (f, feature, what, sql, key, value) in _TF_LOOKUPS
      for conn in (TfMockSQLite(), TfMockMySQL())
        r = _tf_render(_TF_TEL.objects.filter(key => value).values("id"), conn)
        E = engine_name[nameof(typeof(conn))]
        old = feature === :arrays ?
          "An ArrayField value cannot be bound on $(E): $(E) has no array type, and PormG does not emulate one. Run this model on PostgreSQL." :
          _tf_strip(sprint(showerror, PormG._capability_error(conn, feature, what)))
        @test (nameof(typeof(conn)), key, r) == (nameof(typeof(conn)), key, (:raised, PormG.BackendCapabilityError, old))
      end
      r = _tf_render(_TF_TEL.objects.filter(key => value).values("id"), TfMockPostgres())
      @test (key, r[1]) == (key, :value)
    end
  end

  # What: `Q`/`Qor` from 32 arguments on (`Base.Any32`), against the comprehension they used, over mixed argument types.
  # Expected: the same terms (type, and SQL on every engine) in the same order; the same first refusal wherever an
  #   invalid argument sits; the same for a splatted `Vector`.
  # Why: the loop now checks each argument through a walk over the types `Q`/`Qor` take, so a trimmed image has code
  #   for it; a different term, order or refusal would change the SQL or the error a caller sees.
  @testset "Q and Qor from 32 arguments collect the same terms as the comprehension did" begin
    node_q = Q("year" => 2008)
    node_qor = Qor("round" => 6, "round" => 18)
    pick(i) = (i % 9 == 0) ? ("round" => i) :
              (i % 9 == 1) ? ("name__@icontains" => "gp$(i)") :
              (i % 9 == 2) ? ("year__@gte" => Float64(i)) :
              (i % 9 == 3) ? ("date" => Date(2008, 1, 1) + Day(i)) :
              (i % 9 == 4) ? node_q :
              (i % 9 == 5) ? node_qor :
              (i % 9 == 6) ? ("round__@in" => [i, i + 1]) :
              (i % 9 == 7) ? ("name__@in" => ["a$(i)", "b$(i)"]) :
                             ("year__@isnull" => false)
    sets = (Tuple(("round" => i) for i in 1:32), Tuple(("round" => i) for i in 1:40), Tuple(("round" => i) for i in 1:100),
            Tuple(pick(i) for i in 1:40), Tuple(pick(i) for i in 1:81),
            Tuple(Pair{String, Any}("round", i) for i in 1:40),                       # values typed Any, as a mixed Vector
            Tuple((i % 2 == 0 ? Pair{String, Any}("round", i) : Pair{String, Any}("name", "n$(i)")) for i in 1:40),
            Tuple((i == 20 ? (SubString("round__x", 1, 5) => 3) : ("round" => i)) for i in 1:40),  # a SubString key: the open arm
            Tuple((i == 33 ? ("date__@lt" => DateTime(2009, 1, 1)) : ("year" => i)) for i in 1:40),
            Tuple((i == 33 ? ("round" => Int32(3)) : ("year" => i)) for i in 1:40))   # a value type outside the walk
    for args in sets
      @test (length(args), map(typeof, _TF_QB._q_terms_of(args))) == (length(args), map(typeof, _tf_old_terms(args...)))
      for conn in _TF_ENGINES, (mk, wrap) in ((Q, :q), (Qor, :qor))
        new_q = _TF_RACE.objects.filter(mk(args...)).values("name")
        old_terms = _tf_old_terms(args...)
        old_node = wrap === :q ? _TF_QB.QObject(filters = old_terms) : _TF_QB.QorObject(or = old_terms)
        @test (length(args), nameof(typeof(conn)), wrap, _tf_render(new_q, conn)) ==
              (length(args), nameof(typeof(conn)), wrap, _tf_render(_TF_RACE.objects.filter(old_node).values("name"), conn))
      end
    end
    # A splatted Vector, the way an application builds a Qor from a list (run-time length).
    for v in (Pair{String, Int64}[("round" => i) for i in 1:40],
              Pair{String, Any}[(isodd(i) ? ("round" => i) : ("name" => "n$(i)")) for i in 1:40],
              Pair[(isodd(i) ? ("round" => i) : ("name__@icontains" => "n$(i)")) for i in 1:50],
              Pair{String, Int64}[("round" => i) for i in 1:5])
      @test (eltype(v), map(typeof, Qor(v...).or)) == (eltype(v), map(typeof, _tf_old_terms(v...)))
      for conn in _TF_ENGINES
        @test (eltype(v), _tf_render(_TF_RACE.objects.filter(Qor(v...)).values("name"), conn)) ==
              (eltype(v), _tf_render(_TF_RACE.objects.filter(_TF_QB.QorObject(or = _tf_old_terms(v...))).values("name"), conn))
      end
    end
    # The first refusal, from the head, the middle and the tail of a 40-argument tuple, for each kind of invalid argument.
    base = Tuple(("round" => i) for i in 1:40)
    bads = (5, :k => 1, "round__@nosuchop" => 1, "name" => r"a", "nosuchfield" => 1, F("round") + 1, "round" => nothing)
    for bad in bads, pos in (1, 20, 40)
      args = Tuple(i == pos ? bad : base[i] for i in 1:40)
      @test (bad, pos, _tf_outcome_repr(() -> _TF_QB._q_terms_of(args))) == (bad, pos, _tf_outcome_repr(() -> _tf_old_terms(args...)))
      @test (bad, pos, _tf_outcome_repr(() -> Qor(args...))) ==
            (bad, pos, _tf_outcome_repr(() -> _TF_QB.QorObject(or = _tf_old_terms(args...))))
    end
    # Two invalid arguments in both orders: the first in argument order is the one raised.
    for (a, b) in ((5, "nosuchfield" => 1), ("nosuchfield" => 1, 5), (:k => 1, "round__@nosuchop" => 1), ("round__@nosuchop" => 1, :k => 1))
      for (i, j) in ((3, 36), (36, 3))
        args = Tuple(k == i ? a : k == j ? b : base[k] for k in 1:40)
        @test (a, b, i, _tf_outcome_repr(() -> Q(args...))) == (a, b, i, _tf_outcome_repr(() -> _TF_QB.QObject(filters = _tf_old_terms(args...))))
      end
    end
  end
end
