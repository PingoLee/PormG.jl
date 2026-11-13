"""
The pool through the terminals (#1693).

`Settings.connections` is an open `Union{Nothing, _SQLEngine}` on purpose (#1685 kept it open for
the unit suite's stand-in pools), so a pool read from it is abstract, and every call a terminal made
on it was a dispatch at run time — a call a `juliac --trim` image had compiled nothing for (round 4
of #1600: `create` stopped at `_prepare_row_insert!`, `delete` at `build_cte_clause`). Since #1693 a
terminal enters the closed pool dispatch (`ConnectionPool._with_terminal_pool`) once, through
`_with_connection` (or the many-to-many manager's `_with_m2m_connection`), and runs its body with the
pool at its concrete type.

That is a rule, not a shape: a terminal written later that reads the pool itself reopens the wall,
and nothing says so until the next trimmed build. This file is what says so. Four invariants:

1. **`get_settings(` is called only in `_with_connection`** in src/querybuilder/, and
   `get_configuration_settings(` only in `build_helpers.jl` (`get_settings` and the m2m helper).
2. **`.connections` is read in src/querybuilder/ only at the reviewed sites below**, each with its
   reason. The three in `delete` read the SETTINGS' pool on purpose, even under a `connection =`
   override — a pre-existing asymmetry #1693 did not change.
3. **No new `Core.Box`** in src/querybuilder/'s lowered code, closures included. A closure that
   reassigns a variable it captures boxes it, and a box is an `Any` again: the round-4 verifier's
   `_close_pool_slots!` failure. Every terminal body is a closure now, so this is where it would happen.
4. **`_with_connection` hands the body the pool `get_settings` resolves, the same object**: the
   settings' pool, or the `connection =` the caller passed; a pool-less entry raises `get_settings`'
   own refusal. A transaction is found by the pool's identity, so this is what keeps a query on the
   transaction's connection (the integration side is in `test_transactions.jl`).

Static text scan plus reflection and a stand-in pool — no database.
"""
# julia --project=test/integration test/unit/test_terminal_pool_barrier.jl

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Models, InvalidConfigurationError
import PormG.ConnectionPool: SQLiteConnectionPool

const _TPB_QB = PormG.QueryBuilder
const _TPB_SRC = joinpath(pkgdir(PormG), "src")
const _TPB_QB_DIR = joinpath(_TPB_SRC, "querybuilder")

# `.jl` is not pinned to LF in `.gitattributes`, so a Windows checkout yields CRLF.
_tpb_lines(path) = split(replace(read(path, String), "\r\n" => "\n"), '\n')

_tpb_files() = sort!([joinpath(root, f) for (root, _, files) in walkdir(_TPB_QB_DIR)
                      for f in files if endswith(f, ".jl")])

_tpb_rel(path) = replace(relpath(path, _TPB_QB_DIR), '\\' => '/')

# Code lines only: `#` lines and docstrings dropped (this repo documents the rules it enforces, and the
# helpers' own comments name `get_settings` and `.connections`). Comment lines are dropped BEFORE the
# `"""` markers are counted — the order `test_memo_interface.jl` explains.
function _tpb_code_lines(path)
  out = Tuple{Int,String}[]
  in_docstring = false
  for (i, line) in enumerate(_tpb_lines(path))
    startswith(strip(line), "#") && continue
    markers = length(collect(eachmatch(r"\"\"\"", line)))
    was_in = in_docstring
    isodd(markers) && (in_docstring = !in_docstring)
    (was_in || in_docstring) && continue
    push!(out, (i, line))
  end
  return out
end

# The function a source line belongs to: the line itself when it is a one-line method
# (`name(args) = …`), otherwise the nearest `function name(` above it, or an inner constructor's
# `Name(args) = new…` line. Good enough for src/querybuilder/'s layout, and checked below against the
# reviewed sites, so a layout it misreads fails rather than passes.
function _tpb_enclosing(lines, i)
  m = match(r"^\s*([A-Za-z_][\w!]*)\(.*\)(::\S+)?\s*=[^=]", lines[i])
  m !== nothing && return String(m.captures[1])
  for k in i:-1:1
    m = match(r"^function\s+([A-Za-z_][\w!.]*)\(", lines[k])
    m !== nothing && return String(m.captures[1])
    m = match(r"^\s*([A-Za-z_][\w!]*)\(.*\)\s*=\s*new", lines[k])
    m !== nothing && return String(m.captures[1])
  end
  return "(top level)"
end

# Every code line in src/querybuilder/ that matches `pattern`, as (file, enclosing function) => count.
function _tpb_sites(pattern::Regex; skip = (rel, line) -> false)
  sites = Dict{Tuple{String,String},Int}()
  for path in _tpb_files()
    lines = _tpb_lines(path)
    rel = _tpb_rel(path)
    for (i, line) in _tpb_code_lines(path)
      n = length(collect(eachmatch(pattern, line)))
      (n == 0 || skip(rel, line)) && continue
      key = (rel, _tpb_enclosing(lines, i))
      sites[key] = get(sites, key, 0) + n
    end
  end
  return sites
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 1: one way to the settings and the pool (#1693)
# Expected: `get_settings(` is called once in src/querybuilder/, in `_with_connection`; its definition
#   is the only other mention. `get_configuration_settings(` (the by-key read) is called in
#   `get_settings` and `_with_m2m_connection` only.
# Why: a terminal that calls `get_settings` itself takes the pool from the open slot, abstract, and
#   reopens #1693's wall. The maintainer chose the barrier at the terminals (shape (a)) with this scan
#   as its guard (#1693's decision comment).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1693: get_settings is called only by _with_connection" begin
  calls = _tpb_sites(r"\bget_settings\("; skip = (rel, line) -> occursin(r"^function get_settings\(", line))
  @test calls == Dict(("build_helpers.jl", "_with_connection") => 1)
  calls == Dict(("build_helpers.jl", "_with_connection") => 1) || @info "get_settings( calls" calls

  reads = _tpb_sites(r"\bget_configuration_settings\(")
  @test reads == Dict(("build_helpers.jl", "get_settings") => 1,
                      ("build_helpers.jl", "_with_m2m_connection") => 1)
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 2: `.connections` is read only at the reviewed sites (#1693)
# Expected: exactly these reads in src/querybuilder/, by (file, function):
#   - build_helpers.jl `get_settings` (1): the resolution itself;
#   - build_helpers.jl `_with_m2m_connection` (2): the manager's transaction-scope check, then the pool
#     it hands `_with_terminal_pool`;
#   - deletion.jl `delete` (1): `with_tx_context(settings.connections, conn)` — the transaction context
#     of the delete's own transaction, which opens on the settings' pool;
#   - deletion.jl `should_check_related_existence` (1): whether the settings' pool is live;
#   - types.jl `DeletionCollector` (1): the collector's `connection` slot, the settings' pool.
#   A `getfield(…, :connections)` would bypass the dot form, so it is refused anywhere.
# Why: the three `delete` reads take the settings' pool even when `connection =` overrides it, and
#   changing that is a behavior change #1693 does not make; everything else reaches the pool through
#   the helpers.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1693: .connections is read only at the reviewed sites" begin
  reads = _tpb_sites(r"\.connections\b")
  reviewed = Dict(("build_helpers.jl", "get_settings") => 1,
                  ("build_helpers.jl", "_with_m2m_connection") => 2,
                  ("deletion.jl", "delete") => 1,
                  ("deletion.jl", "should_check_related_existence") => 1,
                  ("types.jl", "DeletionCollector") => 1)
  @test reads == reviewed
  reads == reviewed || @info ".connections reads (reviewed → now)" reviewed reads
  @test isempty(_tpb_sites(r":connections\b"))
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 3: no new Core.Box in src/querybuilder/ (#1693)
# Expected: the `Core.Box` constructions in the lowered code of every method defined in
#   src/querybuilder/ — functions, keyword bodies and closures — match the reviewed count per file.
#   A rise fails; a fall fails too, until the count is lowered here in the same change.
# Why: since #1693 every terminal's body is a closure, and a closure that reassigns a variable it
#   captures boxes it: the variable becomes an `Any`, a dispatch per use under the JIT and a verifier
#   row or a run-time `MethodError` in a trimmed image (the round-4 `_close_pool_slots!` failure). The
#   #1693 conversion moved the terminals' existing boxes into their closures one for one and added
#   none (30 before and after); those boxes are older than #1693 and are counted here, not fixed.
# ─────────────────────────────────────────────────────────────────────────────
const _TPB_REVIEWED_BOXES = Dict(
  "build_query.jl" => 1,       # _check_mixed_grouping; #1599 layer 5 removed build_row_join_sql_text's (`keyed`)
  "build_select.jl" => 1,      # get_order_query; #1711 removed get_select_query's (`local kind` in its render closure)
  "deletion.jl" => 4,          # delete's body (2); topological_sort; _collector_predicate
  "execution_bulk.jl" => 7,    # bulk_insert (4: keyword body, body, its insert loop); _bulk_update (3)
  "execution_read.jl" => 1,    # a closure in _filters_name_alias (`mkey`); #1698 removed the `hit` box (a RefValue now)
  "execution_write.jl" => 5,   # _get_or_create's body (2); _run_update_or_create (2); _refuse_update_non_number
                               # (insert's body: 6 → 5 with #1697, its thunk's `result` renamed)
  "expression_render.jl" => 1, # _refuse_unnamed_temporal
  "join_conditions.jl" => 2,   # _bind_cjoin_on_conditions!; _join_scope
  # #1599 layer 5 removed `filter_nodes.jl`'s (`_format_filter_value`, the formatter bound once) and
  # `projection_types.jl`'s (`_reads_alias`, a `RefValue{Bool}` now).
  "sql_format.jl" => 2,        # _format_sql
)

# The detector is shared with test_type_ratchet.jl (#1697), which counts the rest of src/ and ext/.
include(joinpath(@__DIR__, "helper_core_box.jl"))

# Every method defined in a src/querybuilder/ file, keyed by its path from that folder.
_tpb_box_sites() = core_box_sites(f -> startswith(f, _TPB_QB_DIR), _tpb_rel)

@testset "#1693: no new Core.Box in src/querybuilder/, closures included" begin
  sites = _tpb_box_sites()
  counts = Dict(k => length(v) for (k, v) in sites)
  @test counts == _TPB_REVIEWED_BOXES
  counts == _TPB_REVIEWED_BOXES || @info "Core.Box per file (reviewed → now)" _TPB_REVIEWED_BOXES counts sites

  # The detector finds a box, and only where there is one, so the table cannot pass by finding nothing.
  @test core_boxes(Base.uncompressed_ast(only(methods(_core_box_boxing)))) == 1
  @test core_boxes(Base.uncompressed_ast(only(methods(_core_box_not_boxing)))) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# Invariant 4: the pool `_with_connection` hands a terminal (#1693)
# Expected: the body receives `(settings, pool, conn_key)` where `pool` is the settings' pool itself
#   (`===`), or the `connection =` the caller passed (`===`: handed to the body as it is, with no
#   dispatch; a stand-in through `_with_terminal_pool`'s open arm is pinned in test_trim_shape_pins.jl);
#   a pool-less entry raises `get_settings`' own `InvalidConfigurationError`, word for word.
# Why: a transaction is found by the pool's identity (`_tx_context_for`), so the barrier must hand on
#   the same object, never a copy; and #1693 changes no error a terminal raises.
# ─────────────────────────────────────────────────────────────────────────────
struct _TpbStandInPool <: PormG.PormGSQLite end

@testset "#1693: _with_connection hands the body the pool get_settings resolves" begin
  key = "pormg1693_barrier"
  bare = "pormg1693_barrier_poolless"
  pool = SQLiteConnectionPool(":memory:"; pool_size = 1)
  PormG.config[key] = Configuration.Settings(connections = pool, change_data = true, db_def_folder = key)
  PormG.config[bare] = Configuration.Settings(connections = nothing, change_data = true, db_def_folder = bare)
  try
    model = Models.Model("tpb1693_driver", driverid = Models.IDField(), surname = Models.CharField())
    h = _TPB_QB.ObjectHandler(object = _TPB_QB.SQLObjectQuery(model = model, connect_key = key))

    s, p, k = _TPB_QB._with_connection(h) do settings, connection, conn_key
      (settings, connection, conn_key)
    end
    @test s === PormG.config[key]
    @test p === pool && p === PormG.config[key].connections
    @test k == key

    stand_in = _TpbStandInPool()
    p2 = _TPB_QB._with_connection(h; connection = stand_in) do _, connection, _
      connection
    end
    @test p2 === stand_in

    # The query object alone resolves the same way as its handler.
    @test _TPB_QB._with_connection((_, c, _) -> c, h.object) === pool

    hb = _TPB_QB.ObjectHandler(object = _TPB_QB.SQLObjectQuery(model = model, connect_key = bare))
    expected = try
      _TPB_QB.get_settings(hb); nothing
    catch e
      e
    end
    got = try
      _TPB_QB._with_connection((_, c, _) -> c, hb); nothing
    catch e
      e
    end
    @test expected isa InvalidConfigurationError
    @test got isa InvalidConfigurationError && got.msg == expected.msg
  finally
    delete!(PormG.config, key)
    delete!(PormG.config, bare)
  end
end
