# ============================================================
# test/unit/test_read_joins_trim_1599.jl
#
# CONTRACT being tested:
#   The typed forms a join, a CTE and a window read now go through in a trimmed read (#1599 layer 5) answer what the
#   forms they replaced answered, value for value, and raise what those raised:
#     - `_insert_join`'s dedup (a loop over `_dedup_key_at`/`_dedup_key_equal`) against the `filter` closure it
#       replaces: the same alias returned, the same rows and paths recorded, the same error on a duplicated row;
#     - `_join_b` against `hasproperty(r, :b) ? String(r.b) : nothing`, for every row kind and a caller's own;
#     - `_cte_name_shadowed_model` (its modules gathered in typed loops, a field's target read by `_relation_to`)
#       against a copy of the old code, over every name a CTE could shadow;
#     - `_from_column_names` (MySQL's ORDER BY column set) against a copy of the old code;
#     - the CTE's stored copy of its query (`_cte_query_copy`, its projection copied one level) against `deepcopy`:
#       the same SQL and parameters, and the caller's later calls on the source query reach neither copy;
#   each on every engine. What the reads render end to end is pinned by the render suites, the CTE and join
#   integration files and the base-vs-branch differential.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_read_joins_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.QueryBuilder: F, Count, Max, CTE
using PormG.Functions: Rank, RowNumber, WindowOver

const _RJN_QB = PormG.QueryBuilder

struct RjnMockSQLite <: PormG.PormGSQLite end
struct RjnMockPostgres <: PormG.PormGPostgres end
struct RjnMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::RjnMockSQLite) = 3045000
PormG.config["rjn_mock"] = PormG.Configuration.Settings(connections = RjnMockSQLite(), change_data = true,
                                                        db_def_folder = "rjn_mock")

module RjnModels
import PormG
import PormG.Models
Rjn_circuit::Models.ModelType = Models.Model("rjn_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
  country   = Models.CharField(max_length = 80),
)
Rjn_sponsor::Models.ModelType = Models.Model("rjn_sponsor",
  sponsorid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
)
Rjn_race::Models.ModelType = Models.Model("rjn_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  circuitid = Models.ForeignKey("Rjn_circuit", pk_field = "circuitid"),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(null = true),
  sponsors  = Models.ManyToManyField("Rjn_sponsor", related_name = "races"),
)
Models.@models Rjn_circuit Rjn_sponsor Rjn_race
PormG.Models.set_models(@__MODULE__, "rjn_mock")
end
const _RJN_CIRCUIT = RjnModels.Rjn_circuit
const _RJN_RACE = RjnModels.Rjn_race
const _RJN_CONNS = (RjnMockSQLite(), RjnMockPostgres(), RjnMockMySQL())

_rjn_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# A caller's own join row kinds: one with a `b` slot, one without.
struct RjnOwnRow <: _RJN_QB.JoinRow
  a::String
  alias_a::String
  b::String
  alias_b::String
end
struct RjnOwnRowNoB <: _RJN_QB.JoinRow
  a::String
  alias_a::String
  alias_b::String
end
_RJN_QB._key_a(::Union{RjnOwnRow,RjnOwnRowNoB}) = ""
_RJN_QB._key_b(::Union{RjnOwnRow,RjnOwnRowNoB}) = ""
# Two more a caller could define: one whose `alias_b` is not a `String`, and one whose key's `==` answers no `Bool`.
struct RjnOwnRowSub <: _RJN_QB.JoinRow
  a::String
  alias_a::String
  b::String
  alias_b::SubString{String}
end
_RJN_QB._key_a(::RjnOwnRowSub) = ""
_RJN_QB._key_b(::RjnOwnRowSub) = ""
struct RjnOddKey end
Base.:(==)(::RjnOddKey, ::RjnOddKey) = 1
struct RjnOwnRowOddKey <: _RJN_QB.JoinRow
  a::String
  alias_a::String
  b::String
  alias_b::String
end
_RJN_QB._dedup_key(::RjnOwnRowOddKey) = RjnOddKey()

# ── The old forms, copied from the code before #1599 layer 5's join slice ─────────────────────────────────────────
function _old_insert_join(row_join, row, instruct, join_path; track_path::Bool = true)
  if size(row_join, 1) == 0
    push!(row_join, row)
    track_path && push!(_RJN_QB._row_path!(instruct), join_path)
    return row.alias_b
  else
    key = _RJN_QB._dedup_key(row)
    check = filter(r -> _RJN_QB._dedup_key(r) == key, row_join)
    if size(check, 1) == 0
      push!(row_join, row)
      track_path && push!(_RJN_QB._row_path!(instruct), join_path)
      return row.alias_b
    else
      if size(check, 1) > 1
        error(PormG.Kernel._emsg("PormG internal error in _insert_join: duplicate deduplicated join rows for $(row.a) → $(row.b) (alias $(row.alias_a)) — please report this."))
      end
      return check[1].alias_b::String
    end
  end
end

_old_join_b(rj) = hasproperty(rj, :b) ? String(getproperty(rj, :b)) : nothing

function _old_cte_name_shadowed_model(name::String, q, query)
  modules = Module[]
  own_key = get(PormG.Models.REGISTERED_MODULES, q.model._module, nothing)
  same_db = own_key === nothing ? keys(PormG.Models.REGISTERED_MODULES) :
    (mod for (mod, key) in PormG.Models.REGISTERED_MODULES if key == own_key)
  for mod in (q.model._module, query.object.model._module, same_db...)
    mod isa Module && !(mod in modules) && push!(modules, mod)
  end
  for base in (q.model, query.object.model), (_, field) in base.fields
    hasproperty(field, :to) || continue
    to = getproperty(field, :to)
    to isa PormG.PormGModel && hasproperty(to, :_module) || continue
    mod = to._module
    mod isa Module && !(mod in modules) && push!(modules, mod)
  end
  candidates = PormG.PormGModel[q.model, query.object.model]
  for mod in modules, m in PormG.Models.get_all_models(mod)
    m isa PormG.PormGModel && !any(c === m for c in candidates) && push!(candidates, m)
  end
  for m in candidates
    PormG.Models.model_table_name(m) == name && return (m, nothing)
    m2m = m.cache.many_to_many
    if m2m isa AbstractDict
      for (field_name, rel) in m2m
        rel isa PormG.Models.ManyToManyRelation && rel.through_table == name && return (m, String(field_name))
      end
    end
    for (accessor, rel) in m.related_objects
      rel isa PormG.Models.ManyToManyRelation && rel.through_table == name && return (m, String(accessor))
    end
  end
  return nothing
end

# `_from_column_names` as it was: the rows' relations, the fields' targets and the CTE columns read untyped.
function _old_from_column_names(object, instruc)
  QB = _RJN_QB
  tables = Set{String}([QB._model_table_at(object.model)])
  for rj in instruc.row_join
    hasproperty(rj, :b) && push!(tables, String(getproperty(rj, :b)))
  end
  column_hops(path) = (segs = split(String(first(split(lstrip(path, '-'), "__@"))), "__"); segs[1:end-1])
  for p in keys(object.custom_join)
    QB._add_hop_tables!(tables, object, split(p, "__"))
  end
  for p in QB.with_order_terms(QB._projected_paths, object)::Vector{String}
    QB._add_hop_tables!(tables, object, column_hops(p))
  end
  for segs in something(instruc.cjoin_on_paths, ())
    QB._add_hop_tables!(tables, object, segs[1:end-1])
  end
  QB.with_order_terms(QB._order_cte_names_of!, object, tables)
  candidates = PormG.PormGModel[object.model]
  for aj in values(object.alias_join)
    push!(tables, QB._model_table_at(aj.target))
    push!(candidates, aj.target)
  end
  mod = isdefined(object.model, :_module) ? object.model._module : nothing
  if mod isa Module
    for n in names(mod; all = true)
      isdefined(mod, n) && (m = getfield(mod, n)) isa PormG.PormGModel && push!(candidates, m)
    end
  end
  cols = Set{String}()
  seen = Base.IdSet{PormG.PormGModel}()
  while !isempty(candidates)
    m = pop!(candidates)
    m in seen && continue
    push!(seen, m)
    in_from = QB._model_table_at(m) in tables
    for (k, fld) in m.fields
      in_from && push!(cols, PormG.Models.field_db_column(fld, k))
      to = hasproperty(fld, :to) ? getproperty(fld, :to) : nothing
      to isa PormG.PormGModel && push!(candidates, to)
    end
    for rel in values(m.related_objects)
      for name in propertynames(rel)
        target = getproperty(rel, name)
        target isa PormG.PormGModel && push!(candidates, target)
      end
    end
  end
  for (name, cte) in object.ctes
    name in tables || continue
    for v in values(cte)
      v isa PormG.SQLObjectHandler || continue
      for p in v.object.values
        p isa QB.SQLField && push!(cols, something(p.custom_as, p._as))
      end
    end
  end
  return cols
end

# The rows `_insert_join` dedups, of every kind, with their join paths.
function _rjn_rows()
  QB = _RJN_QB
  return Any[
    (QB.ModelJoin(a = "rjn_race", alias_a = "Tb", key_a = "circuitid", b = "rjn_circuit", alias_b = "Tb_1", key_b = "circuitid", how = "INNER"), "circuitid"),
    (QB.ModelJoin(a = "rjn_race", alias_a = "Tb", key_a = "circuitid", b = "rjn_circuit", alias_b = "Tb_9", key_b = "circuitid", how = "LEFT"), "circuitid"),
    (QB.ModelJoin(a = "rjn_race", alias_a = "Tb_1", key_a = "circuitid", b = "rjn_circuit", alias_b = "Tb_2", key_b = "circuitid", how = "INNER"), "x__circuitid"),
    (QB.CteJoin(a = "rjn_race", alias_a = "Tb", key_a = "circuitid", b = "st", alias_b = "st", key_b = "circuitid", how = "LEFT"), "st"),
    (QB.CteJoin(a = "rjn_race", alias_a = "Tb", key_a = "circuitid", b = "st", alias_b = "st_2", key_b = "circuitid", how = "INNER"), "st"),
    (QB.CrossJoin(a = "rjn_race", alias_a = "Tb", b = "st", alias_b = "st"), "st"),
    (QB.AnchorlessJoin(a = "rjn_race", alias_a = "Tb", b = "rjn_circuit", alias_b = "Tb_3", how = "LEFT", on_conditions = QB.FilterType[], to_many = false), "c"),
    (RjnOwnRow("rjn_race", "Tb", "rjn_circuit", "Tb_4"), "own"),
    (RjnOwnRow("rjn_race", "Tb", "rjn_circuit", "Tb_5"), "own"),
  ]
end

# The `build_cte_clause` this branch replaced (PR 2 head), its body rendered by the `do` closure `with_bucket` called.
function _old_build_cte_clause(ctes, connection, parameters, table_alias; correlated::Bool = false)
  QB = _RJN_QB
  isempty(ctes) && return ("", nothing)
  cte_parts = String[]
  state = Dict{String,QB.CTEState}()
  for (cte_name, cte_fields) in ctes
    haskey(cte_fields, "query") || continue
    cte_query = cte_fields["query"]
    cte_sql = QB.with_bucket(parameters, :cte) do
      nested_mark = QB.nested_parameter_mark(parameters)
      rendered = QB._render_select(cte_query, table_alias=table_alias, connection=connection, parameters=parameters,
                                   cte_body=cte_name, cte_body_correlated=correlated)
      state[cte_name] = QB._build_cte_custom_model(rendered.instruction)
      QB._refuse_lock_outside_transaction(cte_query, rendered.instruction)
      QB.reattach_parameters!(parameters, QB.detach_nested_run!(parameters, nested_mark))
      rendered.sql
    end
    push!(cte_parts, "$(QB.quote_identifier(cte_name, connection)) AS (\n  $cte_sql\n)")
  end
  return ("WITH " * join(cte_parts, ",\n") * "\n", state)
end
_rjn_params(p) = p isa _RJN_QB.PgParameterizedQuery ? collect(Any, p.parameters) : _RJN_QB.get_final_parameters(p)
# A CTE's recorded state as plain values: each column's field type and attributes, the kinds, the divisions.
_rjn_state(st) = st === nothing ? nothing :
  sort([(k, sort([(f, string(typeof(v)), sprint(show, v)) for (f, v) in v.model.fields]), sort(collect(v.kinds), by = first),
         sort(collect(v.divisions), by = first), sort(collect(v.unapplied)), sort(collect(v.body_kinds), by = first))
        for (k, v) in st], by = first)

@testset "Join, CTE and window reads in a trimmed build answer as before (#1599 layer 5)" begin

  # What: `_insert_join` over every sequence of two and three rows of every kind, against the old dedup.
  # Expected: the same alias returned for each insertion, the same rows and recorded paths after, and the same error
  #   when the vector already holds two rows with the row's key.
  # Why: the dedup handed `filter` a closure called on each abstract row at run time, a call the trimmed
  #   `values("name", "cn" => "circuitid__name")` stopped at; its replacement must dedup exactly as it did.
  @testset "_insert_join dedups as the filter closure did" begin
    rows = _rjn_rows()
    for conn in _RJN_CONNS, i in eachindex(rows), j in eachindex(rows), k in (0, eachindex(rows)...)
      seq = k == 0 ? (rows[i], rows[j]) : (rows[i], rows[j], rows[k])
      run(f) = begin
        instruc = _RJN_QB.build(_RJN_RACE.objects.filter("year" => 2008).object; connection = conn)
        rj = _RJN_QB.JoinRow[]
        out = Any[]
        for (row, path) in seq, track in (true,)
          push!(out, _rjn_outcome(() -> f(rj, row, instruc, path; track_path = track)))
        end
        (out, map(r -> (typeof(r), r.alias_b), rj), copy(something(instruc.row_path, String[])))
      end
      @test (typeof(conn), i, j, k, run(_RJN_QB._insert_join)) == (typeof(conn), i, j, k, run(_old_insert_join))
    end
    # A vector already holding two rows with one key: the duplicate error, as before.
    r1, r2 = rows[1][1], rows[2][1]
    instruc = _RJN_QB.build(_RJN_RACE.objects.object; connection = _RJN_CONNS[1])
    @test _rjn_outcome(() -> _RJN_QB._insert_join(_RJN_QB.JoinRow[r1, r2], r1, instruc, "p")) ==
          _rjn_outcome(() -> _old_insert_join(_RJN_QB.JoinRow[r1, r2], r1, instruc, "p"))
    @test _rjn_outcome(() -> _old_insert_join(_RJN_QB.JoinRow[r1, r2], r1, instruc, "p"))[1] === :raised
    for (r, _) in rows, (s, _) in rows
      @test _RJN_QB._dedup_key_equal(r, _RJN_QB._dedup_key(s)) == (_RJN_QB._dedup_key(r) == _RJN_QB._dedup_key(s))
      @test _RJN_QB._dedup_key_at(r) == _RJN_QB._dedup_key(r)
    end
  end

  # What: `_join_b` against the `hasproperty` form.
  # Expected: the same relation name, or `nothing`, for every row kind and a caller's own with and without `b`.
  # Why: MySQL's ORDER BY column check asked `hasproperty(rj, :b)` of the abstract row (`hasproperty(::ModelJoin, :b)`
  #   in the trimmed `order_by("-cn")`).
  @testset "_join_b reads what hasproperty read" begin
    for (r, _) in vcat(_rjn_rows(), Any[(RjnOwnRowNoB("rjn_race", "Tb", "Tb_6"), "")])
      @test (typeof(r), _RJN_QB._join_b(r)) == (typeof(r), _old_join_b(r))
    end
  end

  # What: `_cte_name_shadowed_model` against a copy of the old code, over every name a CTE could shadow.
  # Expected: the same model (by identity) and many-to-many accessor, or `nothing`, for each table name, through table
  #   name and unrelated name, from each base model.
  # Why: the check splatted a `KeySet` or a filtered generator, asked `hasproperty` of the field union and read
  #   the abstract `PormGModel`, each a run-time call the trimmed `.with(…)` stopped at.
  @testset "_cte_name_shadowed_model answers what the old check answered" begin
    names = String["rjn_race", "rjn_circuit", "rjn_sponsor", "st", "race", "x"]
    for m in (_RJN_RACE, _RJN_CIRCUIT), rel in values(m.related_objects)
      rel isa PormG.Models.ManyToManyRelation && push!(names, rel.through_table)
    end
    for (_, rel) in _RJN_RACE.cache.many_to_many
      push!(names, rel.through_table)
    end
    for base in (_RJN_RACE, _RJN_CIRCUIT), cte_model in (_RJN_RACE, _RJN_CIRCUIT), name in unique(names)
      q = base.objects.object
      sub = cte_model.objects
      new = _rjn_outcome(() -> _RJN_QB._cte_name_shadowed_model(name, q, sub))
      old = _rjn_outcome(() -> _old_cte_name_shadowed_model(name, q, sub))
      @test (base.name, cte_model.name, name, new) == (base.name, cte_model.name, name, old)
    end
    @test any(n -> _RJN_QB._cte_name_shadowed_model(n, _RJN_RACE.objects.object, _RJN_CIRCUIT.objects) !== nothing, names)
  end

  # What: MySQL's ORDER BY column set (`_from_column_names`) against a copy of the old code.
  # Expected: the same set of names for a join ordered by its path and by its alias, a window and a many-to-many path;
  #   the same columns for a CTE's projection.
  # Why: three of its reads (a row's relation, a field's target, a CTE's projection) dispatched at run time.
  @testset "_from_column_names gives the set the old walk gave" begin
    conn = RjnMockMySQL()
    shapes = Any[
      () -> _RJN_RACE.objects.filter("circuitid__country__@in" => ["Monaco", "Brazil"]).values("name", "cn" => "circuitid__name").order_by("circuitid__name"),
      () -> _RJN_RACE.objects.values("name", "cn" => "circuitid__name").order_by("-cn"),
      () -> _RJN_RACE.objects.values("name", "rk" => Rank(over = WindowOver(order_by = ["-round"]))).order_by("-round"),
      () -> _RJN_RACE.objects.values("name", "sponsors__name").order_by("sponsors__name"),
    ]
    for (i, mk) in enumerate(shapes)
      h = mk()
      instruc = _RJN_QB.build(getfield(h, :object); connection = conn)
      new = _rjn_outcome(() -> _RJN_QB._from_column_names(getfield(h, :object), instruc))
      old = _rjn_outcome(() -> _old_from_column_names(getfield(h, :object), instruc))
      @test (i, new) == (i, old)
      @test old[1] === :value && !isempty(old[2])
    end
    # A CTE's columns (the walk's last part; a CTE query is built with its WITH state, so it is checked here alone):
    # `_add_cte_columns!` against the old loop over the handler's projection.
    for src in (_RJN_RACE.objects.values("circuitid", "n" => Count("raceid")), _RJN_RACE.objects.values("cn" => "circuitid__name", "name"),
                _RJN_RACE.objects)
      new, old = Set{String}(), Set{String}()
      _RJN_QB._add_cte_columns!(new, src)
      for p in src.object.values
        p isa _RJN_QB.SQLField && push!(old, something(p.custom_as, p._as))
      end
      @test new == old
    end
  end

  # What: the CTE's stored copy of its query (`_cte_query_copy`) against `deepcopy`, which it replaces in `.with()`.
  # Expected: on every engine the main query renders the same SQL and binds the same parameters either way; and
  #   calls on the source query after `.with()` (a projection, a filter, an order) change neither the CTE nor the
  #   SQL, either way.
  # Why: the deep copy walked each projection node by run-time dispatch (a `TypeError` inside `deepcopy_internal`
  #   in the trimmed `.with(…)`); the one-level copy must isolate the CTE from its source exactly as the deep one did.
  @testset "the CTE's copy of its query renders and isolates as the deep copy did" begin
    sources = Any[
      () -> _RJN_RACE.objects.values("circuitid", "n" => Count("raceid")),
      () -> _RJN_RACE.objects.filter("year" => 2008).values("circuitid", "n" => Count("raceid")),
      () -> _RJN_RACE.objects.filter("round__@gt" => 3).values("circuitid", "m" => Max(F("round") + 1)).order_by("circuitid"),
      () -> _RJN_RACE.objects.values("circuitid", "rk" => RowNumber(over = WindowOver(partition_by = ["year"], order_by = ["date"]))),
    ]
    render(conn, mksrc, copier, mutate) = begin
      src = mksrc()
      cte = _RJN_QB._preset_cte_fields("st", src; join_field = "circuitid" => "circuitid")
      cte["query"] = copier(src)   # the copy `.with()` stores, by each copier
      before = _RJN_QB.query(cte["query"]; connection = conn, show_query = :dict)
      if mutate
        src.values("name"); src.filter("year" => 1999); src.order_by("-round")
      end
      after = _RJN_QB.query(cte["query"]; connection = conn, show_query = :dict)
      (before, after, length(getfield(cte["query"], :object).values), length(getfield(cte["query"], :object).filter))
    end
    for conn in _RJN_CONNS, (i, mk) in enumerate(sources), mutate in (false, true)
      new = _rjn_outcome(() -> render(conn, mk, _RJN_QB._cte_query_copy, mutate))
      old = _rjn_outcome(() -> render(conn, mk, deepcopy, mutate))
      @test (typeof(conn), i, mutate, new) == (typeof(conn), i, mutate, old)
      @test old[1] === :value && old[2][1] == old[2][2]
    end
    # The whole read through `.with()`, as the fixture spells it.
    for conn in _RJN_CONNS
      q = _RJN_RACE.objects
      q.with("st" => _RJN_RACE.objects.values("circuitid", "n" => Count("raceid")), join_field = "circuitid" => "circuitid")
      d = _rjn_outcome(() -> q.values("name", "n" => "st__n").order_by("date").list(show_query = :dict))
      @test d[1] === :value && occursin("WITH", string(d[2][:sql_text]))
    end
  end

  # What: `build_cte_clause`, whose body render is now the callable struct `_CteBodyRender` (and whose column fields
  #   go through the unspecialized `_meant_column_field`), against a copy of the version with the `do` closure.
  # Expected: on every engine, for one and two CTEs, correlated or not, with bound values in the body: the same WITH
  #   text, the same values bound in the same order, the same state per CTE (each column's field, kind, division,
  #   unapplied declaration); a body that takes a row lock is refused with the same error either way.
  # Why: the struct must do the closure's steps in the closure's order, or a positional engine binds values out of
  #   order (#432) and the declaring query reads another column type (#1624).
  @testset "build_cte_clause renders, binds and records as the closure did" begin
    QB = _RJN_QB
    bodies = Any[
      () -> _RJN_RACE.objects.values("circuitid", "n" => Count("raceid")),
      () -> _RJN_RACE.objects.filter("year" => 2008, "name__@contains" => "Grand").values("circuitid", "n" => Count("raceid"), "m" => Max("date")),
      () -> _RJN_RACE.objects.filter("round__@gt" => 3).values("circuitid", "m" => Max(F("round") + 1), "x" => Max(F("round") / 2)),
      () -> _RJN_RACE.objects.values("circuitid", "rk" => RowNumber(over = WindowOver(partition_by = ["year"], order_by = ["date"]))),
      () -> _RJN_RACE.objects.filter("year" => 2008).values("circuitid", "name", "date"),
    ]
    mkctes(ix) = begin
      ctes = PormG.OrderedCollections.OrderedDict{String,QB.CTEDict}()
      for (j, i) in enumerate(ix)
        ctes["st$(j)"] = QB._preset_cte_fields("st$(j)", bodies[i](); join_field = "circuitid" => "circuitid")
      end
      ctes
    end
    run(f, conn, ix, correlated) = begin
      params = QB.get_parameter(conn)
      QB.set_context!(params, :cte)
      sql, st = f(mkctes(ix), conn, params, QB.SQLTbAlias(); correlated = correlated)
      (sql, _rjn_params(params), _rjn_state(st))
    end
    for conn in _RJN_CONNS, ix in ([1], [2], [3], [4], [5], [2, 3], [5, 2]), correlated in (false, true)
      new = _rjn_outcome(() -> run(QB.build_cte_clause, conn, ix, correlated))
      old = _rjn_outcome(() -> run(_old_build_cte_clause, conn, ix, correlated))
      @test (typeof(conn), ix, correlated, new) == (typeof(conn), ix, correlated, old)
      @test old[1] === :value
    end
    # A locking body, refused the same way.
    for conn in _RJN_CONNS
      locked() = (ctes = PormG.OrderedCollections.OrderedDict{String,QB.CTEDict}();
                  ctes["st1"] = QB._preset_cte_fields("st1", _RJN_RACE.objects.filter("year" => 2008).values("circuitid").select_for_update();
                                                       join_field = "circuitid" => "circuitid"); ctes)
      new = _rjn_outcome(() -> (p = QB.get_parameter(conn); QB.set_context!(p, :cte); QB.build_cte_clause(locked(), conn, p, QB.SQLTbAlias())[1]))
      old = _rjn_outcome(() -> (p = QB.get_parameter(conn); QB.set_context!(p, :cte); _old_build_cte_clause(locked(), conn, p, QB.SQLTbAlias())[1]))
      @test (typeof(conn), new) == (typeof(conn), old)
    end
  end

  # What: the CTE column helpers this branch adds, each against the form it replaces: the column's path
  #   (`_cte_column_path` vs the old ternary), a kind's family and field (`_kind_family_at`/`_kind_field_at` vs
  #   `_kind_family`/`_kind_field`), the kind store (`_store_cte_kind!` vs `d[k] = v`) and the closed-set field walk
  #   (`Models._with_any_field(f, field)` vs `f(field)`, through `field_without_db_column`).
  # Expected: the same value, or the same error, for every kind PormG names, every member of the closed field set and
  #   a value of none of them.
  # Why: each was a run-time call in the trimmed `.with(…)` read; the typed form must answer what that call answered.
  @testset "the CTE column's typed readers answer what the calls they replace answered" begin
    QB = _RJN_QB
    M = PormG.Models
    old_path(source) = source isa AbstractString ? String(source) :
      source isa QB.SQLField && source.field isa AbstractString ? String(source.field) :
      source isa QB.FExpression && source.operation === nothing && source.field_name isa String ? source.field_name :
      nothing
    sources = Any["name", SubString("circuitid__name", 1, 9), QB.SQLField("year", "year"), QB.SQLField(Count("raceid"), "n"),
                  F("round"), F("round") + 1, Count("raceid"), QB.SQLText(3), nothing, 3, QB.CTEReference(name = "st", path = "n")]
    for x in sources
      @test (x, _rjn_outcome(() -> QB._cte_column_path(x))) == (x, _rjn_outcome(() -> old_path(x)))
    end
    kinds = Any[PormG.CInt16(), PormG.CInt32(), PormG.CInt64(), PormG.CFloat64(), PormG.CBool(), PormG.CText(), PormG.CDate(),
                PormG.CTime(), PormG.CUUID(), PormG.CJSON(), PormG.CBytes(), PormG.CInet(), PormG.CCidr(), PormG.CTsVector(),
                PormG.CVarChar(80), PormG.CVarChar(nothing), PormG.CDecimal(6, 2), PormG.CDecimal(nothing, nothing),
                PormG.CDateTime(true), PormG.CDateTime(false), PormG.CInterval(false), PormG.CInterval(true),
                PormG.CArray(PormG.CInt64()), PormG.CUnsupported("money"), QB.CJSONValue()]
    shown(v) = v isa PormG.PormGField ? (typeof(v), sprint(show, v)) : v
    for k in Any[kinds..., nothing, 3, "text"]
      @test (k, _rjn_outcome(() -> QB._kind_family_at(k))) == (k, _rjn_outcome(() -> QB._kind_family(k)))
      @test (k, _rjn_outcome(() -> shown(QB._kind_field_at(k)))) == (k, _rjn_outcome(() -> shown(QB._kind_field(k))))
    end
    for k in kinds
      d_new = Dict{String,PormG.CanonicalType}(); d_old = Dict{String,PormG.CanonicalType}()
      QB._store_cte_kind!(d_new, "c", k); d_old["c"] = k
      @test (k, d_new) == (k, d_old)
    end
    fields = Any[M.IDField(), M.CharField(max_length = 10, db_column = "nm"), M.IntegerField(db_column = ""), M.ForeignKey("Rjn_circuit"),
                 M.DateTimeField(), M.DecimalField(max_digits = 6, decimal_places = 2, db_column = "amt"), M.JSONField(), M.TextField(),
                 M.BooleanField(), M.ManyToManyField("Rjn_sponsor")]
    for f in fields
      @test (typeof(f), _rjn_outcome(() -> M._with_any_field(QB._field_kind, f))) == (typeof(f), _rjn_outcome(() -> QB._field_kind(f)))
      @test (typeof(f), _rjn_outcome(() -> M._with_any_field(string, f, "!"))) == (typeof(f), _rjn_outcome(() -> string(f, "!")))
    end
    @test _rjn_outcome(() -> M._with_any_field(string, 3, "!")) == _rjn_outcome(() -> string(3, "!"))
    # `field_without_db_column` against its old body: the same rebuilt field, and the identical object where nothing changes.
    old_strip(field) = begin
      T = typeof(field)
      idx = findfirst(==(:db_column), fieldnames(T))
      idx === nothing && return field
      dbc = getfield(field, idx)
      (dbc isa AbstractString && !isempty(dbc)) || return field
      T((i == idx ? nothing : getfield(field, i) for i in 1:fieldcount(T))...)
    end
    for f in fields
      new, old = M.field_without_db_column(f), old_strip(f)
      @test (typeof(f), typeof(new), sprint(show, new), new === f) == (typeof(f), typeof(old), sprint(show, old), old === f)
    end
  end

  # What: `_insert_join`'s dedup hit for a caller's own row kinds the open arms read: an `alias_b` that is not a
  #   `String`, and a key whose `==` answers `1`.
  # Expected: the old code's error, a `TypeError` from its typeassert, either way.
  # Why: the open arms assert what the replaced reads asserted (`check[1].alias_b::String`, `filter`'s `f(x)::Bool`);
  #   a conversion there would accept the `SubString` and read `1` as a match.
  @testset "a caller's own row is asserted as the dedup asserted it" begin
    QB = _RJN_QB
    for (r1, r2) in ((RjnOwnRowSub("rjn_race", "Tb", "rjn_circuit", SubString("Tbx", 1, 2)), RjnOwnRowSub("rjn_race", "Tb", "rjn_circuit", SubString("Tbx", 1, 2))),
                     (RjnOwnRowOddKey("rjn_race", "Tb", "rjn_circuit", "Tc"), RjnOwnRowOddKey("rjn_race", "Tb", "rjn_circuit", "Tc")))
      run(f) = (instruc = QB.build(_RJN_RACE.objects.object; connection = _RJN_CONNS[1]);
                rows = QB.JoinRow[r1]; f(rows, r2, instruc, "p"))
      new = _rjn_outcome(() -> run(QB._insert_join))
      old = _rjn_outcome(() -> run(_old_insert_join))
      @test (typeof(r1), new) == (typeof(r1), old)
      @test old[1] === :raised && old[2] === TypeError
    end
  end

  # What: `.with()`'s stored copy when the projection holds what a caller can change after `.with()`: a `Subquery` or
  #   `Exists` over a handler the caller keeps, and a window over a `WindowSpec` the caller keeps; and whether the
  #   fixture's projection takes the one-level copy.
  # Expected: on every engine the stored CTE renders, after the caller's change, what the deep copy rendered (the
  #   change does not reach it); `values("circuitid", "n" => Count("raceid"))` is shared one level, the others not.
  # Why: the one-level copy shares the wrapped node, so it is used only when no part of it can change (a review
  #   finding: a shared `Subquery` handler took the caller's later `.filter`).
  @testset "the CTE's copy isolates nested handlers and window specs as the deep copy did" begin
    QB = _RJN_QB
    C = RjnModels.Rjn_circuit
    shapes = Any[
      ("Subquery handler", () -> (inner = _RJN_RACE.objects.filter("circuitid" => QB.OuterRef("circuitid")).values("round");
                                  (C.objects.values("circuitid", "r" => QB.Subquery(inner)), () -> inner.filter("year" => 1999)))),
      ("Exists handler", () -> (inner = _RJN_RACE.objects.filter("circuitid" => QB.OuterRef("circuitid"));
                                (C.objects.values("circuitid", "e" => QB.Exists(inner)), () -> inner.filter("year" => 1999)))),
      ("window partition", () -> (w = WindowOver(partition_by = ["year"], order_by = ["date"]);
                                  (_RJN_RACE.objects.values("circuitid", "rk" => RowNumber(over = w)), () -> push!(w.partition_by, "round")))),
      ("window frame", () -> (w = WindowOver(order_by = ["date"]);
                              (_RJN_RACE.objects.values("circuitid", "rk" => RowNumber(over = w)),
                               () -> (w.frame = "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW")))),
    ]
    for conn in _RJN_CONNS, (name, mk) in shapes
      run(copier) = begin
        src, change = mk()
        stored = copier(src)
        before = _rjn_outcome(() -> QB.query(stored; connection = conn, show_query = :dict))
        change()
        (before, _rjn_outcome(() -> QB.query(stored; connection = conn, show_query = :dict)))
      end
      @test (typeof(conn), name, run(QB._cte_query_copy)) == (typeof(conn), name, run(deepcopy))
    end
    shares(h) = all(QB._projection_shares_safely, getfield(h, :object).values)
    @test shares(_RJN_RACE.objects.values("circuitid", "n" => Count("raceid")))
    @test shares(_RJN_RACE.objects.values("circuitid", "n" => Max(F("round") + 1), "m" => Max("date")))
    for (name, mk) in shapes
      @test (name, shares(first(mk()))) == (name, false)
    end
  end
end
