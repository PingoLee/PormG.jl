"""
Unit coverage for #487: `instruct.row_join` holds typed `JoinRow` entries, one kind per join shape.

Before #487 every materialized join was a `Dict{String,Union{String,Vector{FilterType}}}` whose KIND
— model hop, keyed CTE, cross-joined CTE, anchor-less `cjoin_on` — was a set of string booleans
(`"no_anchor" => "1"`, `"cte" => "1"`, `"cross" => "1"`, `"to_many" => "1"`) read with three
different idioms across four files. The rows are now `ModelJoin` / `CteJoin` / `CrossJoin` /
`AnchorlessJoin` (`src/querybuilder/types.jl`), and the render path is selected by `isa`.

This file pins the PRODUCER side: which kind each join shape builds, and which slots it carries.
Every assertion reads `PormG.QueryBuilder.build(q.object; connection = mock).row_join` directly —
the SQL text those rows render into is pinned by the join renderers' own files (see below), so a
kind mismatch here fails even when the rendered text happens to agree. It also pins the four
helpers the readers dispatch through (`_dedup_key`, `_with_config`, `_flag_to_many!`, `_prev_how`),
because their contract is what makes the refactor behavior-preserving:

  - the dedup key is kind-AGNOSTIC and shaped like the old `(a, b, key_a, key_b, alias_a)` tuple,
    with the same sentinels the dict rows carried (#479 says why the kind must stay out of it);
  - `to_many` is stamped onto the dedup SURVIVOR, by slot replacement, not set at construction;
  - a `cjoin`/`on()` override is applied by copy, and only a `ModelJoin` can receive one.

All assertions render through mock connections — no live database.

Sibling coverage:
  - `test_identifier_quoting.jl`   -> the #394 correlated-UPDATE refusals, now on typed rows.
  - `test_db_column_deep_joins.jl` -> the ON text at depth 2 (#68), same producer code.
  - `test_order_by_joins.jl`       -> `build_row_join_sql_text` Phases 1-2 (the CONSUMER side).
  - `test_cte_ergonomics.jl`       -> CTE join shapes (#44) as SQL text.
  - `test_cjoin_on.jl`             -> anchor-less joins (#45) as SQL text.
  - `test_aggregate_fanout.jl`     -> the #74 guard that reads `to_many`.
"""

using Test
using PormG
using PormG.Models

# Dedicated mock connections + config key: `runtests.jl` includes ~50 files into one `Main`, so a
# shared name would let another file's settings decide this file's dialect.
struct JoinRowsMockSQLite <: PormG.PormGSQLite end
struct JoinRowsMockPostgres <: PormG.PormGPostgres end
const _JR_SL = JoinRowsMockSQLite()
const _JR_PG = JoinRowsMockPostgres()
PormG.backend_sqlite_version(::JoinRowsMockSQLite) = 3045000

PormG.config["join_rows_mock"] = PormG.Configuration.Settings(
  connections = _JR_PG, change_data = true, db_def_folder = "join_rows_mock",
)

# Inline fixtures in their own module: `set_models` is REQUIRED (not a style choice), because
# `_build_row_join` reads `instruct.object.model._module::Module`.
module JoinRowsModels
import PormG
import PormG.Models

Jr_team = Models.Model("jr_team",
  id   = Models.IDField(),
  name = Models.CharField(null = true),
)

Jr_sponsor = Models.Model("jr_sponsor",
  id   = Models.IDField(),
  name = Models.CharField(null = true),
)

# A forward FK (`team`, nullable so it renders LEFT) and a many-to-many with an auto through table.
Jr_driver = Models.Model("jr_driver",
  id       = Models.IDField(),
  code     = Models.CharField(),
  team     = Models.ForeignKey(Jr_team, on_delete = "CASCADE", related_name = "drivers", null = true),
  sponsors = Models.ManyToManyField(Jr_sponsor, related_name = "drivers_sponsored"),
)

# A NON-nullable FK, so its forward join renders INNER and the reverse accessor `results` exists.
Jr_result = Models.Model("jr_result",
  id     = Models.IDField(),
  driver = Models.ForeignKey(Jr_driver, on_delete = "CASCADE", related_name = "results"),
  points = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "join_rows_mock")
end

const JR = JoinRowsModels
import PormG.QueryBuilder: F, Joined, CTE, FilterType,
  JoinRow, ModelJoin, CteJoin, CrossJoin, AnchorlessJoin,
  _dedup_key, _with_config, _flag_to_many!, _prev_how, _on_conditions, _to_many, _joins_cte

# The rows a query materializes, straight off the instruction object `build` returns. Mirrors the
# preamble of `query()` (`execution.jl`): the WITH clause is built BEFORE `build`, on the same
# parameter collector and alias generator, and it is the only writer of `cte_dict["model"]` —
# skipping it makes every CTE reference (correctly, #433) refused as "emits no WITH clause".
function _jr_rows(q; conn = _JR_SL)
  table_alias = PormG.QueryBuilder.SQLTbAlias()
  parameters = PormG.QueryBuilder.get_parameter(conn)
  PormG.QueryBuilder.set_context!(parameters, :cte)
  PormG.QueryBuilder.build_cte_clause(q.object.ctes, conn, parameters, table_alias)
  instruc = PormG.QueryBuilder.build(q.object; table_alias = table_alias, connection = conn,
                                     parameters = parameters)
  return instruc.row_join
end

# A CTE body reused across the CTE cases: SELECT id, code FROM jr_driver.
_jr_driver_cte() = (c = JR.Jr_driver.objects; c.values("id", "code"); c)

# ─────────────────────────────────────────────────────────────────────────────
# Producer kinds: a forward ForeignKey hop is a `ModelJoin`
# One row, keyed on the FK column and the referenced PK, `to_many == false` (the joined side is
# the "one" side), no ON predicates. `how` is "INNER" because the FK is not nullable.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a forward FK hop materializes as ModelJoin (#487)" begin
  for (label, conn) in (("PostgreSQL", _JR_PG), ("SQLite", _JR_SL))
    @testset "$label" begin
      q = JR.Jr_result.objects
      q.values("points")
      q.filter("driver__code" => "SEN")
      rows = _jr_rows(q; conn = conn)

      @test length(rows) == 1
      row = rows[1]
      @test row isa ModelJoin
      @test row.a == "jr_result" && row.alias_a == "Tb"
      @test row.b == "jr_driver" && row.alias_b == "Tb_1"
      @test row.key_a == "driver" && row.key_b == "id"
      @test row.how == "INNER"
      @test row.to_many == false
      @test isempty(row.on_conditions)
      # The generic helpers agree with the slots.
      @test !_to_many(row) && !_joins_cte(row) && isempty(_on_conditions(row))
      @test _prev_how(row) == "INNER"
      @test _dedup_key(row) == ("jr_result", "jr_driver", "driver", "id", "Tb")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Producer kinds: a reverse-relation hop is a `ModelJoin` with `to_many == true`
# The ON sides swap (parent PK on `a`, child FK on `b`) and the child is the many-side, which is
# the fact the #74 fan-out guard reads. A nullable-FK reverse renders LEFT.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a reverse hop materializes as a to-many ModelJoin (#487)" begin
  q = JR.Jr_driver.objects
  q.values("code")
  q.filter("results__points" => 25)
  rows = _jr_rows(q)

  @test length(rows) == 1
  row = rows[1]
  @test row isa ModelJoin
  @test row.a == "jr_driver" && row.b == "jr_result"
  @test row.key_a == "id" && row.key_b == "driver"
  @test row.to_many == true
  @test _to_many(row)
end

# ─────────────────────────────────────────────────────────────────────────────
# Producer kinds: a many-to-many hop is TWO ModelJoins, and only the related one is to-many
# The through-table hop chains off the base alias; the related hop chains off the through alias.
# `to_many` is stamped onto the RELATED row after insertion (by `_flag_to_many!`), never onto the
# through row — a base-column aggregate multiplies over the related rows, not the link rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a many-to-many hop materializes as through + related ModelJoins (#487)" begin
  q = JR.Jr_driver.objects
  q.values("code")
  q.filter("sponsors__name" => "Marlboro")
  rows = _jr_rows(q)

  @test length(rows) == 2
  through, related = rows
  @test through isa ModelJoin && related isa ModelJoin
  # The chain: base -> through -> related. The through table's name is PormG-generated, so pin the
  # LINKAGE rather than the spelling.
  @test through.a == "jr_driver" && through.alias_a == "Tb"
  @test related.a == through.b && related.alias_a == through.alias_b
  @test related.b == "jr_sponsor"
  @test through.to_many == false
  @test related.to_many == true
end

# ─────────────────────────────────────────────────────────────────────────────
# Producer kinds: a keyed `.with(... join_field = ...)` hop is a `CteJoin`
# `b` is the CTE NAME (not a table), `key_b` its projection alias, and `how` is the declared join
# type ("LEFT" by default). It carries no ON predicates — a CTE has no `custom_join` entry (#474).
# ─────────────────────────────────────────────────────────────────────────────
@testset "a keyed CTE hop materializes as CteJoin (#487)" begin
  q = JR.Jr_result.objects
  q.with("dc" => _jr_driver_cte(), join_field = "driver" => "id")
  q.values("points", "c" => CTE("dc", "code"))
  rows = _jr_rows(q)

  @test length(rows) == 1
  row = rows[1]
  @test row isa CteJoin
  @test row.a == "jr_result" && row.key_a == "driver"
  @test row.b == "dc" && row.key_b == "id"
  @test row.how == "LEFT"
  @test _joins_cte(row)
  @test isempty(_on_conditions(row))
  @test _prev_how(row) == "LEFT"
  @test _dedup_key(row) == ("jr_result", "dc", "driver", "id", row.alias_a)
end

# ─────────────────────────────────────────────────────────────────────────────
# Producer kinds: an unkeyed `.with(...)` referenced twice is ONE `CrossJoin`
# The kind has no key columns and no join type. Its dedup key contributes the empty-string
# sentinels the dict row carried, which is exactly what collapses two references to the same CTE
# onto a single CROSS JOIN (`test_cte_ergonomics.jl` pins the SQL; this pins the mechanism).
# `_prev_how` is `nothing`: the old `"CROSS"` sentinel existed only to reach the loop's error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unkeyed CTE referenced twice materializes as one CrossJoin (#487)" begin
  q = JR.Jr_result.objects
  q.with("dc" => _jr_driver_cte())
  q.values("points", "c" => CTE("dc", "code"), "i" => CTE("dc", "id"))
  rows = _jr_rows(q)

  @test length(rows) == 1
  row = rows[1]
  @test row isa CrossJoin
  @test row.a == "jr_result" && row.b == "dc"
  @test _joins_cte(row)
  @test _prev_how(row) === nothing
  @test _dedup_key(row) == ("jr_result", "dc", "", "", row.alias_a)
  @test isempty(_on_conditions(row)) && !_to_many(row)
end

# ─────────────────────────────────────────────────────────────────────────────
# A deep path after an unkeyed CTE still fails with the keyed path's message
# The `CrossJoin` carries no `how`; the loop reads `_prev_how(::CrossJoin) === nothing` and then
# reaches the "not a foreign key" guard on the CTE model's column. Pinned as the TYPED error —
# `test_cte_ergonomics.jl` only asserts `!(err isa KeyError)`, which any typed row passes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an over-long unkeyed-CTE path is a QueryBuildError, not a missing slot (#487)" begin
  q = JR.Jr_result.objects
  q.with("dc" => _jr_driver_cte())
  q.values("x" => CTE("dc", "code__more"))
  err = try
    _jr_rows(q)
    nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError
  @test occursin("does not have a foreign key", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# Producer kinds: `cjoin_on` materializes as `AnchorlessJoin`
# `alias_b` is the USER's alias, `on_conditions` is the whole ON clause, and there are no key
# columns. Two `cjoin_on` to the same target both survive dedup because `_dedup_key` puts the alias
# in the `key_a` position — the discriminator the dict row spelled as `"key_a" => user_alias`
# (`test_cjoin_on.jl` pins the two-join SQL; this pins why the second is not dropped).
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin_on materializes as AnchorlessJoin and two to one target both survive (#487)" begin
  q = JR.Jr_result.objects
  q.cjoin_on("Jr_driver"; alias = "d", on = [Joined("d", "id") == F("driver")])
  q.cjoin_on("Jr_driver"; alias = "e", join_type = "LEFT", on = [Joined("e", "id") == F("driver")])
  q.values("points")
  rows = _jr_rows(q)

  @test length(rows) == 2
  d, e = rows
  @test d isa AnchorlessJoin && e isa AnchorlessJoin
  @test d.a == "jr_result" && d.alias_a == "Tb"
  @test d.b == "jr_driver" && d.alias_b == "d"
  @test d.how == "INNER" && e.how == "LEFT"
  @test length(d.on_conditions) == 1 && length(_on_conditions(d)) == 1
  @test !_joins_cte(d) && !_to_many(d)
  # Same target, same source: only the alias in the key_a position tells them apart.
  @test _dedup_key(d) == ("jr_result", "jr_driver", "d", "", "Tb")
  @test _dedup_key(e) == ("jr_result", "jr_driver", "e", "", "Tb")
end

# ─────────────────────────────────────────────────────────────────────────────
# A `cjoin` / `on()` entry lands in `how` and `on_conditions` of the hop's ModelJoin
# The shared tail of `_build_row_join` folds the path's config into the row by copy
# (`_with_config`); the slots are what Phase 1/2 of the renderer read.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an on() entry is folded into the hop's ModelJoin by _with_config (#487)" begin
  q = JR.Jr_result.objects
  q.on("driver", "code" => "SEN", join_type = "LEFT")
  q.values("points", "driver__code")
  rows = _jr_rows(q)

  @test length(rows) == 1
  row = rows[1]
  @test row isa ModelJoin
  @test row.how == "LEFT"                 # the override, not the FK's own INNER
  @test length(row.on_conditions) == 1    # the on() predicate
end

# ─────────────────────────────────────────────────────────────────────────────
# `_with_config`: by copy, and only a ModelJoin can receive a config
# The original row is untouched (immutability is the contract, not a convention), and a config on
# a CTE row is a `MethodError` — the type-level form of the `cte ? nothing : …` gate in the tail.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_with_config copies a ModelJoin and refuses a config on a CTE row (#487)" begin
  base = ModelJoin(a = "jr_result", alias_a = "Tb", key_a = "driver",
                   b = "jr_driver", alias_b = "Tb_1", key_b = "id", how = "INNER")
  filters = FilterType[PormG.QueryBuilder._check_filter("code" => "SEN")]

  # Nothing to fold: a slot-for-slot equal row comes back (compared by slots — `==` on the struct
  # would fall back to identity and pass only while the vector object happens to be shared).
  same = _with_config(base, nothing, nothing)
  @test same isa ModelJoin
  @test all(getfield(same, f) == getfield(base, f) for f in fieldnames(ModelJoin))
  # Override only.
  left = _with_config(base, "LEFT", nothing)
  @test left.how == "LEFT" && isempty(left.on_conditions)
  # Filters only; an EMPTY vector is "nothing to fold", matching the old `!isempty` guard.
  withf = _with_config(base, nothing, filters)
  @test withf.how == "INNER" && length(withf.on_conditions) == 1
  @test isempty(_with_config(base, nothing, FilterType[]).on_conditions)
  # The input never changed.
  @test base.how == "INNER" && isempty(base.on_conditions)

  cte = CteJoin(a = "jr_result", alias_a = "Tb", key_a = "driver",
                b = "dc", alias_b = "Tb_1", key_b = "id", how = "LEFT")
  cross = CrossJoin(a = "jr_result", alias_a = "Tb", b = "dc", alias_b = "Tb_1")
  @test _with_config(cte, nothing, nothing) === cte
  @test _with_config(cross, nothing, nothing) === cross
  @test_throws MethodError _with_config(cte, "LEFT", nothing)
  @test_throws MethodError _with_config(cross, nothing, filters)
end

# ─────────────────────────────────────────────────────────────────────────────
# `_flag_to_many!` stamps the SURVIVOR by slot replacement
# The M2M related row is constructed with `to_many == false`; the stamp goes onto whatever row
# holds the alias after dedup — which is why a constructor flag would have changed behavior when
# dedup keeps a row an earlier traversal produced. Idempotent, and fail-closed on an unknown alias.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_flag_to_many! replaces the slot of the row holding the alias (#487)" begin
  first = ModelJoin(a = "jr_driver", alias_a = "Tb", key_a = "id",
                    b = "jr_driver_sponsors", alias_b = "Tb_1", key_b = "driver_id", how = "INNER")
  second = ModelJoin(a = "jr_driver_sponsors", alias_a = "Tb_1", key_a = "sponsor_id",
                     b = "jr_sponsor", alias_b = "Tb_2", key_b = "id", how = "INNER")
  rows = JoinRow[first, second]

  stamped = _flag_to_many!(rows, "Tb_2")
  @test stamped isa ModelJoin && stamped.to_many
  @test rows[2] === stamped                 # the slot was replaced …
  @test rows[1] === first && !first.to_many # … and nothing else moved
  @test second.to_many == false             # the original value is untouched
  # Stamping again returns the already-stamped row without allocating a new one.
  @test _flag_to_many!(rows, "Tb_2") === stamped
  # An alias no row holds is an internal error, never a silent no-op — and it is the "not found"
  # arm of that error, not the "wrong kind" one.
  missing_err = try
    _flag_to_many!(rows, "Tb_9")
    nothing
  catch e
    e
  end
  @test missing_err isa ErrorException
  @test occursin("was not found in row_join", sprint(showerror, missing_err))
end

# ─────────────────────────────────────────────────────────────────────────────
# The dead `SQLObjectQuery.row_join` slot is gone
# It was a `Vector{Dict{String,Any}}` with no writer and no reader (the instruction object owns
# the real one); #487 deleted it rather than retyping a field nothing ever populated.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLObjectQuery no longer carries a row_join slot (#487)" begin
  @test !hasfield(PormG.QueryBuilder.SQLObjectQuery, :row_join)
  @test hasfield(PormG.QueryBuilder.InstructionObject, :row_join)
  @test fieldtype(PormG.QueryBuilder.InstructionObject, :row_join) == Vector{JoinRow}
end

# ─────────────────────────────────────────────────────────────────────────────
# Display: each kind shows as one short line naming the kind
# `display.jl` owns every model-bearing `show`; these rows hold only Strings and a predicate
# vector, so the point is legibility of a `row_join` dump, not a size ceiling.
# ─────────────────────────────────────────────────────────────────────────────
@testset "JoinRow kinds show as one line each (#487)" begin
  q = JR.Jr_driver.objects
  q.values("code")
  q.filter("sponsors__name" => "M")
  q.cjoin_on("Jr_team"; alias = "t", on = [Joined("t", "id") == F("team")])
  rows = _jr_rows(q)
  for row in rows
    s = sprint(show, row)
    @test startswith(s, string(nameof(typeof(row)), "("))
    @test !occursin('\n', s) && length(s) < 200
  end
  @test sprint(show, CrossJoin(a = "x", alias_a = "Tb", b = "dc", alias_b = "Tb_1")) == "CrossJoin(dc AS Tb_1)"
end
